// Package secrets reads a login's password from AWS Secrets Manager (task B24e, Prometheus sql_exporter's S11): a
// reference aws-secretsmanager:<name or ARN>[#key] on an instance, read through the site's own AWS credentials (the
// SDK's usual chain: the environment, a profile, an `aws login` session, the instance role; nothing stored by pgvigil).
//
// The secret is RDS's JSON (username and password; Secrets Manager documents engine, host, username, password,
// dbname, port) or a plain string that is the password; #key names another JSON key. Only the extracted password
// and username are kept, in memory, never the whole SecretString, and never written, logged or sent anywhere.
//
// The read: GetSecretValue (AWSCURRENT) as one signed POST through the SDK core pgvigil already links (its v4
// signer): no new Go module. It is kept 5 minutes a secret (a departure from 'read at each connect': a read per
// connect at 1,819 databases and 5 connects a minute would be about USD 65 a day at USD 0.05 per 10,000 calls), one
// read in flight a secret. After a refused sign-in (28P01 / 18456) the caller asks Refresh once: a new read only if
// the entry still holds the version that failed and its back-off (60 s) is over, and a retry only when the read gives
// ANOTHER VersionId - so pgvigil adds at most one failed login a secret a minute and never drives a lockout. A
// refused read (AccessDenied, ResourceNotFound, InvalidRequest such as 'scheduled for deletion', DecryptionFailure)
// drops the value, so a revoke takes effect within the 5 minutes; a transient one (throttling, 5xx, a timeout) keeps
// the value one more bound and marks it stale. One read gives up within 5 s and 2 attempts.
package secrets

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
)

// Prefix is the reference's scheme.
const Prefix = "aws-secretsmanager:"

// Ref names one secret, the key to take and where to read it.
type Ref struct {
	ID      string // the secret's name or ARN
	Key     string // the JSON key of the password ("" = password, or the whole string)
	Region  string
	Profile string
}

// ParseRef reads "aws-secretsmanager:<name or ARN>[#key]"; an ARN's own region wins over region.
func ParseRef(raw, region, profile string) (Ref, error) {
	rest, ok := strings.CutPrefix(strings.TrimSpace(raw), Prefix)
	if !ok {
		return Ref{}, fmt.Errorf("a password_secret reference starts with %s", Prefix)
	}
	id, key, hasKey := strings.Cut(rest, "#")
	if id == "" || (hasKey && key == "") {
		return Ref{}, errors.New("a password_secret reference names the secret (and a key after # when one is written)")
	}
	r := Ref{ID: id, Key: key, Region: strings.TrimSpace(region), Profile: strings.TrimSpace(profile)}
	if strings.HasPrefix(id, "arn:") {
		if p := strings.Split(id, ":"); len(p) >= 4 && p[3] != "" {
			r.Region = p[3]
		}
	}
	if r.Region == "" {
		return Ref{}, errors.New("a password_secret needs its region (password_secret.region, or an ARN)")
	}
	return r, nil
}

// Value is a read secret: the login and its password as extracted, the version they came from.
type Value struct {
	User, Password string
	Version        string
	Stale          bool // a refresh failed transiently: the value is the last one read
}

// ReadError is a read that failed; it names the secret and AWS's code, never the value.
type ReadError struct {
	Secret, Code, Message string
	Refused               bool // AWS refused (the secret, the right or its key): the value is dropped
}

func (e *ReadError) Error() string {
	return fmt.Sprintf("the password could not be read from AWS Secrets Manager: %s, %s (%s)", e.Code, e.Secret, e.Message)
}

type cacheKey struct{ id, region, profile, key string }

type entry struct {
	mu        sync.Mutex // one read in flight a secret
	val       *Value
	readAt    time.Time
	backoffTo time.Time
}

// Reader is the process's cache of secrets.
type Reader struct {
	mu      sync.Mutex
	entries map[cacheKey]*entry
	// the endpoint, the credentials and the clock (tests stand their own in)
	endpoint func(region string, fips bool) string
	creds    func(ctx context.Context, r Ref) (aws.CredentialsProvider, error)
	now      func() time.Time
	client   *http.Client
}

const (
	bound    = 5 * time.Minute
	backoff  = 60 * time.Second
	readTime = 5 * time.Second
)

// NewReader is a reader on AWS's own endpoints and the SDK's credential chain.
func NewReader() *Reader {
	return &Reader{entries: map[cacheKey]*entry{}, now: time.Now, client: &http.Client{},
		endpoint: func(region string, fips bool) string {
			if fips {
				return "https://secretsmanager-fips." + region + ".amazonaws.com/"
			}
			return "https://secretsmanager." + region + ".amazonaws.com/"
		},
		creds: func(ctx context.Context, r Ref) (aws.CredentialsProvider, error) {
			opts := []func(*awsconfig.LoadOptions) error{awsconfig.WithRegion(r.Region)}
			if r.Profile != "" {
				opts = append(opts, awsconfig.WithSharedConfigProfile(r.Profile))
			}
			cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
			if err != nil {
				return nil, err
			}
			return cfg.Credentials, nil
		}}
}

// Default is the process's one reader.
var Default = NewReader()

func (r *Reader) entryFor(ref Ref) *entry {
	k := cacheKey{ref.ID, ref.Region, ref.Profile, ref.Key}
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entries[k]
	if !ok {
		e = &entry{}
		r.entries[k] = e
	}
	return e
}

// Get returns the secret's value, read again when the kept one is 5 minutes old.
func (r *Reader) Get(ctx context.Context, ref Ref) (Value, error) {
	e := r.entryFor(ref)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.val != nil && r.now().Sub(e.readAt) < bound {
		return *e.val, nil
	}
	return r.readInto(ctx, ref, e)
}

// Refresh is the caller's step after a refused sign-in with the value of version failed: it reads again only when
// the entry still holds that version and its back-off is over, and says retry only when the new read gives another
// VersionId.
func (r *Reader) Refresh(ctx context.Context, ref Ref, failed string) (Value, bool, error) {
	e := r.entryFor(ref)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.val != nil && e.val.Version != failed {
		return *e.val, true, nil // another caller read a newer version meanwhile
	}
	if r.now().Before(e.backoffTo) {
		if e.val != nil {
			return *e.val, false, nil
		}
		return Value{}, false, &ReadError{Secret: ref.ID, Code: "BackOff", Message: "a re-read after a refused sign-in waits a minute"}
	}
	e.backoffTo = r.now().Add(backoff)
	v, err := r.readInto(ctx, ref, e)
	if err != nil {
		return v, false, err
	}
	return v, v.Version != failed, nil
}

// readInto reads the secret into the entry (the caller holds e.mu)
func (r *Reader) readInto(ctx context.Context, ref Ref, e *entry) (Value, error) {
	v, err := r.read(ctx, ref)
	var re *ReadError
	switch {
	case err == nil:
		e.val, e.readAt = &v, r.now()
		return v, nil
	case errors.As(err, &re) && re.Refused:
		e.val = nil // a revoke takes effect
		return Value{}, err
	case e.val != nil:
		kept := *e.val
		kept.Stale = true
		e.readAt = r.now() // kept one more bound
		e.val = &kept
		return kept, nil
	}
	return Value{}, err
}

func (r *Reader) read(ctx context.Context, ref Ref) (Value, error) {
	ctx, cancel := context.WithTimeout(ctx, readTime)
	defer cancel()
	prov, err := r.creds(ctx, ref)
	if err != nil {
		return Value{}, &ReadError{Secret: ref.ID, Code: "Credentials", Message: err.Error()}
	}
	body, _ := json.Marshal(map[string]string{"SecretId": ref.ID})
	fips := strings.EqualFold(os.Getenv("AWS_USE_FIPS_ENDPOINT"), "true")
	var last error
	for attempt := 0; attempt < 2; attempt++ {
		out, err := r.call(ctx, prov, ref, body, fips)
		if err == nil {
			return extract(ref, out)
		}
		last = err
		var re *ReadError
		if (errors.As(err, &re) && re.Refused) || ctx.Err() != nil {
			break
		}
	}
	return Value{}, last
}

type getOut struct {
	SecretString *string `json:"SecretString"`
	VersionID    string  `json:"VersionId"`
}

func (r *Reader) call(ctx context.Context, prov aws.CredentialsProvider, ref Ref, body []byte, fips bool) (getOut, error) {
	creds, err := prov.Retrieve(ctx)
	if err != nil {
		return getOut{}, &ReadError{Secret: ref.ID, Code: "Credentials", Message: err.Error()}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, r.endpoint(ref.Region, fips), bytes.NewReader(body))
	if err != nil {
		return getOut{}, err
	}
	req.Header.Set("Content-Type", "application/x-amz-json-1.1")
	req.Header.Set("X-Amz-Target", "secretsmanager.GetSecretValue")
	sum := sha256.Sum256(body)
	if err := v4.NewSigner().SignHTTP(ctx, creds, req, hex.EncodeToString(sum[:]), "secretsmanager", ref.Region, r.now()); err != nil {
		return getOut{}, err
	}
	resp, err := r.client.Do(req)
	if err != nil {
		return getOut{}, &ReadError{Secret: ref.ID, Code: "Unreachable", Message: err.Error()}
	}
	defer func() { _ = resp.Body.Close() }()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Type    string `json:"__type"`
			Message string `json:"message"`
		}
		_ = json.Unmarshal(b, &e)
		code := e.Type
		if i := strings.LastIndex(code, "#"); i >= 0 {
			code = code[i+1:]
		}
		refused := resp.StatusCode < 500 && code != "ThrottlingException" && code != "TooManyRequestsException"
		return getOut{}, &ReadError{Secret: ref.ID, Code: code, Message: e.Message, Refused: refused}
	}
	var out getOut
	if err := json.Unmarshal(b, &out); err != nil {
		return getOut{}, &ReadError{Secret: ref.ID, Code: "BadAnswer", Message: "the answer is not GetSecretValue's"}
	}
	return out, nil
}

// extract takes the login and the password out of the SecretString; nothing else of it is kept
func extract(ref Ref, out getOut) (Value, error) {
	if out.SecretString == nil {
		return Value{}, &ReadError{Secret: ref.ID, Code: "SecretBinary", Message: "a binary secret holds no password string", Refused: true}
	}
	s := *out.SecretString
	var obj map[string]any
	if json.Unmarshal([]byte(s), &obj) == nil && obj != nil {
		key := ref.Key
		if key == "" {
			key = "password"
		}
		pw, ok := obj[key].(string)
		if !ok {
			return Value{}, &ReadError{Secret: ref.ID, Code: "NoKey", Message: fmt.Sprintf("the secret's JSON has no string %q", key), Refused: true}
		}
		user, _ := obj["username"].(string)
		return Value{User: user, Password: pw, Version: out.VersionID}, nil
	}
	if ref.Key != "" {
		return Value{}, &ReadError{Secret: ref.ID, Code: "NoKey", Message: "a #key needs a JSON secret", Refused: true}
	}
	return Value{Password: s, Version: out.VersionID}, nil
}

// PGWithSecret returns a libpq string with the password (and, when the string names no user, the login) of a
// password_secret set, for a connect that takes a string (the actions door's monitoring login, EXPLAIN's check, the
// job actions; task B24e). The string lives only for that connect: it is never logged or stored (pgx redacts a
// password in its errors). ps nil = the string as it is.
func PGWithSecret(ctx context.Context, dsn, ref, region, profile string) (string, error) {
	if strings.TrimSpace(ref) == "" {
		return dsn, nil
	}
	r, err := ParseRef(ref, region, profile)
	if err != nil {
		return "", err
	}
	v, err := Default.Get(ctx, r)
	if err != nil {
		return "", err
	}
	return withLibpqPassword(dsn, v.User, v.Password), nil
}

// withLibpqPassword sets password (and user when the string names none) on a libpq keyword or URL string
func withLibpqPassword(dsn, user, password string) string {
	if strings.Contains(dsn, "://") {
		if u, err := url.Parse(dsn); err == nil {
			name := ""
			if u.User != nil {
				name = u.User.Username()
			}
			if name == "" {
				name = user
			}
			u.User = url.UserPassword(name, password)
			return u.String()
		}
		return dsn
	}
	q := func(v string) string { return "'" + strings.NewReplacer(`\`, `\\`, `'`, `\'`).Replace(v) + "'" }
	out := dsn + " password=" + q(password)
	hasUser := false
	for _, f := range strings.Fields(dsn) {
		if k, _, ok := strings.Cut(f, "="); ok && strings.EqualFold(k, "user") {
			hasUser = true
		}
	}
	if !hasUser && user != "" {
		out += " user=" + q(user)
	}
	return out
}
