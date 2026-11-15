// Package secrets reads a login's password from AWS Secrets Manager (task B24e, Prometheus sql_exporter's S11): a
// reference aws-secretsmanager:<name or ARN>[#key] on an instance, read through the site's own AWS credentials (the
// SDK's usual chain: the environment, a profile, an `aws login` session, the instance role; nothing stored by pgvigil).
//
// The secret is RDS's JSON (username and password; Secrets Manager documents engine, host, username, password,
// dbname, port) or a plain string that is the password; #key names another JSON key, whose value is then a password
// alone (the login comes from the connection string). Only the extracted password and username are kept, in memory,
// never the whole SecretString, and never written, logged or sent anywhere.
//
// The read: GetSecretValue (AWSCURRENT) as one signed POST through the SDK core pgvigil already links (its v4
// signer): no new Go module. It is kept 5 minutes a secret (a departure from 'read at each connect': a read per
// connect at 1,819 databases and 5 connects a minute would be about USD 65 a day at USD 0.05 per 10,000 calls), one
// read in flight a secret (a waiter gives up with its own context).
//
// A refused sign-in (28P01 / 18456): the caller asks Refresh once. It reads again only when the entry still holds
// the version that failed and the version's back-off (60 s) is over, and says retry only when the read gives ANOTHER
// VersionId. A version the server refused is HELD: while its back-off runs, Get hands it to no one (a *ReadError
// LoginRefused, no dial); once the back-off is over the next Get reads again and, on the same version, lets that one
// caller try it (a probe) and starts the next back-off; a sign-in that works with it (Accepted) ends the hold. So
// after a rotation's first refusal the connects already dialling fail once each, and then one try a minute a secret.
//
// A failed read is kept until the back-off ends (no call to AWS meanwhile). A refused one (AccessDeniedException,
// ResourceNotFoundException, InvalidRequestException such as 'scheduled for deletion', DecryptionFailure) drops the
// value, so a revoke takes effect within the 5 minutes; any other (throttling, an expired or unrecognised credential,
// a 5xx, a proxy's answer, a timeout) keeps a value already read one more bound, marked stale and logged. One read
// gives up within 5 s and 2 attempts.
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
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	v4 "github.com/aws/aws-sdk-go-v2/aws/signer/v4"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
)

// Prefix is the reference's scheme.
const Prefix = "aws-secretsmanager:"

// sdkID is Secrets Manager's SDK id, which names its configured endpoint (AWS_ENDPOINT_URL_SECRETS_MANAGER, a
// profile's services section) [inferred: the SDK's normalisation of the id, config env_config.go normalizeEnv]
const sdkID = "Secrets Manager"

// Ref names one secret, the key to take and where to read it.
type Ref struct {
	ID      string // the secret's name or ARN
	Key     string // the JSON key of the password ("" = password, or the whole string)
	Region  string
	Profile string
	// Invalid is why a configured block did not parse (config.Instance.SecretRef past Validate): every read refuses it
	Invalid string
}

// ParseRef reads "aws-secretsmanager:<name or ARN>[#key]"; an ARN's own region wins over region. Its refusals are
// *ReadError (code BadReference), so a caller never counts them as the server's failure.
func ParseRef(raw, region, profile string) (Ref, error) {
	bad := func(msg string) (Ref, error) {
		return Ref{}, &ReadError{Secret: strings.TrimSpace(raw), Code: "BadReference", Message: msg, Refused: true}
	}
	rest, ok := strings.CutPrefix(strings.TrimSpace(raw), Prefix)
	if !ok {
		return bad("a password_secret reference starts with " + Prefix)
	}
	id, key, hasKey := strings.Cut(rest, "#")
	if id == "" || (hasKey && key == "") {
		return bad("a password_secret reference names the secret (and a key after # when one is written)")
	}
	r := Ref{ID: id, Key: key, Region: strings.TrimSpace(region), Profile: strings.TrimSpace(profile)}
	if strings.HasPrefix(id, "arn:") {
		p := strings.Split(id, ":")
		if len(p) < 7 || p[2] != "secretsmanager" {
			return bad("an ARN reference is arn:<partition>:secretsmanager:<region>:<account>:secret:<name>")
		}
		if p[3] != "" {
			r.Region = p[3]
		}
	}
	if r.Region == "" {
		return bad("a password_secret needs its region (password_secret.region, or an ARN that names one)")
	}
	return r, nil
}

// Value is a read secret: the login and its password as extracted, the version they came from.
type Value struct {
	User, Password string
	Version        string
	Stale          bool // a refresh failed transiently: the value is the last one read (logged as it is served)
}

// ReadError is a read (or a use) of a secret that failed; it names the secret and the code, never the value.
type ReadError struct {
	Secret, Code, Message string
	Refused               bool // AWS refused (the secret, the right or its key), or the configuration: not transient
}

func (e *ReadError) Error() string {
	return fmt.Sprintf("the password could not be read from AWS Secrets Manager: %s, %s (%s)", e.Code, e.Secret, e.Message)
}

// refusedCodes are AWS's answers that drop a kept value (the design's list); every other code is transient
var refusedCodes = map[string]bool{
	"AccessDeniedException":     true,
	"ResourceNotFoundException": true,
	"InvalidRequestException":   true,
	"DecryptionFailure":         true,
}

type cacheKey struct{ id, region, profile, key string }

type entry struct {
	sem       chan struct{} // one read in flight a secret; a waiter leaves with its own context
	val       *Value
	readAt    time.Time
	err       error // a failed read, answered until errUntil without a call
	errUntil  time.Time
	refused   string    // the version a server refused (held until backoffTo, then one probe a back-off)
	backoffTo time.Time // the end of the refused version's back-off
	held      atomic.Bool
}

func (e *entry) lock(ctx context.Context) error {
	select {
	case e.sem <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (e *entry) unlock() { <-e.sem }

// site is what the SDK's chain resolved for one region and profile: the credentials, the FIPS choice and a
// configured endpoint ("" = AWS's own)
type site struct {
	creds aws.CredentialsProvider
	fips  bool
	base  string
}

// Reader is the process's cache of secrets.
type Reader struct {
	mu      sync.Mutex
	entries map[cacheKey]*entry
	sites   map[[2]string]site // one SDK configuration a region and profile (an assumed role is not re-assumed a read)
	// load is the SDK's configuration for a region and profile; now the clock (tests stand their own in)
	load   func(ctx context.Context, region, profile string) (aws.Config, error)
	now    func() time.Time
	client *http.Client
	log    atomic.Pointer[slog.Logger]
}

const (
	bound    = 5 * time.Minute
	backoff  = 60 * time.Second
	readTime = 5 * time.Second
)

// NewReader is a reader on AWS's own endpoints and the SDK's credential chain.
func NewReader() *Reader {
	r := &Reader{entries: map[cacheKey]*entry{}, sites: map[[2]string]site{}, now: time.Now, client: &http.Client{},
		load: func(ctx context.Context, region, profile string) (aws.Config, error) {
			opts := []func(*awsconfig.LoadOptions) error{awsconfig.WithRegion(region)}
			if profile != "" {
				opts = append(opts, awsconfig.WithSharedConfigProfile(profile))
			}
			return awsconfig.LoadDefaultConfig(ctx, opts...)
		}}
	r.log.Store(slog.Default())
	return r
}

// Default is the process's one reader.
var Default = NewReader()

// SetLog gives the reader the process's logger (a read, a stale value served).
func (r *Reader) SetLog(l *slog.Logger) {
	if l != nil {
		r.log.Store(l)
	}
}

func (r *Reader) entryFor(ref Ref) *entry {
	k := cacheKey{ref.ID, ref.Region, ref.Profile, ref.Key}
	r.mu.Lock()
	defer r.mu.Unlock()
	e, ok := r.entries[k]
	if !ok {
		e = &entry{sem: make(chan struct{}, 1)}
		r.entries[k] = e
	}
	return e
}

// siteFor is the SDK's configuration for the reference's region and profile, loaded once (a failure is not kept)
func (r *Reader) siteFor(ctx context.Context, ref Ref) (site, error) {
	k := [2]string{ref.Region, ref.Profile}
	r.mu.Lock()
	s, ok := r.sites[k]
	r.mu.Unlock()
	if ok {
		return s, nil
	}
	cfg, err := r.load(ctx, ref.Region, ref.Profile)
	if err != nil {
		return site{}, err
	}
	s = site{creds: cfg.Credentials}
	type fipsSource interface {
		GetUseFIPSEndpoint(context.Context) (aws.FIPSEndpointState, bool, error)
	}
	type baseSource interface {
		GetServiceBaseEndpoint(context.Context, string) (string, bool, error)
	}
	type ignoreSource interface {
		GetIgnoreConfiguredEndpoints(context.Context) (bool, bool, error)
	}
	ignore := false
	for _, src := range cfg.ConfigSources {
		if p, ok := src.(ignoreSource); ok {
			if v, found, _ := p.GetIgnoreConfiguredEndpoints(ctx); found {
				ignore = v
				break
			}
		}
	}
	for _, src := range cfg.ConfigSources {
		if p, ok := src.(fipsSource); ok {
			if v, found, _ := p.GetUseFIPSEndpoint(ctx); found {
				s.fips = v == aws.FIPSEndpointStateEnabled
				break
			}
		}
	}
	if !ignore {
		for _, src := range cfg.ConfigSources {
			if p, ok := src.(baseSource); ok {
				if v, found, _ := p.GetServiceBaseEndpoint(ctx, sdkID); found && v != "" {
					s.base = v
					break
				}
			}
		}
		if s.base == "" && cfg.BaseEndpoint != nil {
			s.base = *cfg.BaseEndpoint
		}
	}
	r.mu.Lock()
	r.sites[k] = s
	r.mu.Unlock()
	return s, nil
}

// endpointOf is the URL a read posts to: a configured endpoint, else AWS's own host (FIPS when asked; the China
// partition's domain for a cn- region)
func endpointOf(region string, s site) string {
	if s.base != "" {
		return strings.TrimRight(s.base, "/") + "/"
	}
	host := "secretsmanager"
	if s.fips {
		host += "-fips"
	}
	domain := ".amazonaws.com"
	if strings.HasPrefix(region, "cn-") {
		domain = ".amazonaws.com.cn"
	}
	return "https://" + host + "." + region + domain + "/"
}

// Endpoint is the URL this reader reads the reference from (the collector prints it at start).
func (r *Reader) Endpoint(ctx context.Context, ref Ref) (string, error) {
	if ref.Invalid != "" {
		return "", invalid(ref)
	}
	s, err := r.siteFor(ctx, ref)
	if err != nil {
		return "", err
	}
	return endpointOf(ref.Region, s), nil
}

func invalid(ref Ref) error {
	return &ReadError{Secret: ref.ID, Code: "BadReference", Message: ref.Invalid, Refused: true}
}

func waiting(ref Ref, err error) error {
	return &ReadError{Secret: ref.ID, Code: "Waiting", Message: "another read of this secret had not ended: " + err.Error()}
}

// Get returns the secret's value, read again when the kept one is 5 minutes old; a version the server refused is
// held until its back-off ends (module comment).
func (r *Reader) Get(ctx context.Context, ref Ref) (Value, error) {
	if ref.Invalid != "" {
		return Value{}, invalid(ref)
	}
	e := r.entryFor(ref)
	if err := e.lock(ctx); err != nil {
		return Value{}, waiting(ref, err)
	}
	defer e.unlock()
	now := r.now()
	if e.val != nil && e.refused != "" && e.val.Version == e.refused {
		if now.Before(e.backoffTo) {
			return Value{}, &ReadError{Secret: ref.ID, Code: "LoginRefused", Message: fmt.Sprintf(
				"the server refused the secret's version %s: no sign-in with it until %s", e.refused, e.backoffTo.UTC().Format(time.TimeOnly)+" UTC")}
		}
		v, err := r.readInto(ctx, ref, e)
		if err != nil {
			return v, err
		}
		if v.Version == e.refused {
			e.backoffTo = now.Add(backoff) // this caller's sign-in is the one probe of the next back-off
		} else {
			e.refused = ""
			e.held.Store(false)
		}
		return v, nil
	}
	if e.val != nil && now.Sub(e.readAt) < bound {
		return *e.val, nil
	}
	if e.err != nil && now.Before(e.errUntil) {
		return Value{}, e.err
	}
	return r.readInto(ctx, ref, e)
}

// Refresh is the caller's step after a refused sign-in with the value of version failed: the version is held (no
// one gets it during its back-off); a new read is made only when the entry still holds that version and the back-off
// is over, and retry only when the new read gives another VersionId.
func (r *Reader) Refresh(ctx context.Context, ref Ref, failed string) (Value, bool, error) {
	if ref.Invalid != "" {
		return Value{}, false, invalid(ref)
	}
	e := r.entryFor(ref)
	if err := e.lock(ctx); err != nil {
		return Value{}, false, waiting(ref, err)
	}
	defer e.unlock()
	if e.val != nil && e.val.Version != failed {
		return *e.val, true, nil // another caller read a newer version meanwhile
	}
	now := r.now()
	e.refused = failed
	e.held.Store(true)
	if now.Before(e.backoffTo) {
		return Value{}, false, nil
	}
	e.backoffTo = now.Add(backoff)
	v, err := r.readInto(ctx, ref, e)
	if err != nil {
		return v, false, err
	}
	if v.Version != failed {
		e.refused = ""
		e.held.Store(false)
		return v, true, nil
	}
	return v, false, nil
}

// Accepted is the caller's step after a sign-in that worked with version: a held version is released.
func (r *Reader) Accepted(ctx context.Context, ref Ref, version string) {
	e := r.entryFor(ref)
	if !e.held.Load() || e.lock(ctx) != nil {
		return
	}
	defer e.unlock()
	if e.refused == version {
		e.refused, e.backoffTo = "", time.Time{}
		e.held.Store(false)
	}
}

// readInto reads the secret into the entry (the caller holds e's slot)
func (r *Reader) readInto(ctx context.Context, ref Ref, e *entry) (Value, error) {
	v, err := r.read(ctx, ref)
	now := r.now()
	var re *ReadError
	switch {
	case err == nil:
		e.val, e.readAt, e.err = &v, now, nil
		r.log.Load().Info("password secret read", "secret", ref.ID, "region", ref.Region, "version", v.Version)
		return v, nil
	case errors.As(err, &re) && re.Refused:
		e.val = nil // a revoke takes effect
		e.err, e.errUntil = err, now.Add(backoff)
		return Value{}, err
	case e.val != nil:
		kept := *e.val
		kept.Stale = true
		e.readAt = now // kept one more bound
		e.val = &kept
		r.log.Load().Warn("the password secret's re-read failed: the last value read is kept one more 5 minutes",
			"secret", ref.ID, "region", ref.Region, "version", kept.Version, "err", err)
		return kept, nil
	}
	e.err, e.errUntil = err, now.Add(backoff)
	return Value{}, err
}

func (r *Reader) read(ctx context.Context, ref Ref) (Value, error) {
	ctx, cancel := context.WithTimeout(ctx, readTime)
	defer cancel()
	s, err := r.siteFor(ctx, ref)
	if err != nil {
		return Value{}, &ReadError{Secret: ref.ID, Code: "Credentials", Message: err.Error()}
	}
	body, _ := json.Marshal(map[string]string{"SecretId": ref.ID})
	var last error
	for attempt := 0; attempt < 2; attempt++ {
		out, err := r.call(ctx, s, ref, body)
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

func (r *Reader) call(ctx context.Context, s site, ref Ref, body []byte) (getOut, error) {
	if s.creds == nil {
		return getOut{}, &ReadError{Secret: ref.ID, Code: "Credentials", Message: "the SDK's chain found no credentials"}
	}
	creds, err := s.creds.Retrieve(ctx)
	if err != nil {
		return getOut{}, &ReadError{Secret: ref.ID, Code: "Credentials", Message: err.Error()}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpointOf(ref.Region, s), bytes.NewReader(body))
	if err != nil {
		return getOut{}, &ReadError{Secret: ref.ID, Code: "Endpoint", Message: err.Error()}
	}
	req.Header.Set("Content-Type", "application/x-amz-json-1.1")
	req.Header.Set("X-Amz-Target", "secretsmanager.GetSecretValue")
	sum := sha256.Sum256(body)
	if err := v4.NewSigner().SignHTTP(ctx, creds, req, hex.EncodeToString(sum[:]), "secretsmanager", ref.Region, r.now()); err != nil {
		return getOut{}, &ReadError{Secret: ref.ID, Code: "Signature", Message: err.Error()}
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
		if code == "" {
			// AWS's JSON protocol also names the error in a header; a proxy's answer names none
			code, _, _ = strings.Cut(resp.Header.Get("X-Amzn-ErrorType"), ":")
		}
		if i := strings.LastIndex(code, "#"); i >= 0 {
			code = code[i+1:]
		}
		if code == "" {
			code = fmt.Sprintf("HTTP %d", resp.StatusCode)
		}
		if e.Message == "" {
			e.Message = http.StatusText(resp.StatusCode)
		}
		return getOut{}, &ReadError{Secret: ref.ID, Code: code, Message: e.Message, Refused: refusedCodes[code]}
	}
	var out getOut
	if err := json.Unmarshal(b, &out); err != nil {
		return getOut{}, &ReadError{Secret: ref.ID, Code: "BadAnswer", Message: "the answer is not GetSecretValue's"}
	}
	return out, nil
}

// extract takes the login and the password out of the SecretString; nothing else of it is kept. With #key the value
// of that key is a password alone: the login is the connection string's (no username is read).
func extract(ref Ref, out getOut) (Value, error) {
	if out.SecretString == nil {
		return Value{}, &ReadError{Secret: ref.ID, Code: "SecretBinary", Message: "a binary secret holds no password string", Refused: true}
	}
	s := *out.SecretString
	var obj map[string]any
	if json.Unmarshal([]byte(s), &obj) == nil && obj != nil {
		if ref.Key != "" {
			pw, ok := obj[ref.Key].(string)
			if !ok {
				return Value{}, &ReadError{Secret: ref.ID, Code: "NoKey", Message: fmt.Sprintf("the secret's JSON has no string %q", ref.Key), Refused: true}
			}
			return Value{Password: pw, Version: out.VersionID}, nil
		}
		pw, ok := obj["password"].(string)
		if !ok {
			return Value{}, &ReadError{Secret: ref.ID, Code: "NoKey", Message: `the secret's JSON has no string "password"`, Refused: true}
		}
		user, _ := obj["username"].(string)
		return Value{User: user, Password: pw, Version: out.VersionID}, nil
	}
	if ref.Key != "" {
		return Value{}, &ReadError{Secret: ref.ID, Code: "NoKey", Message: "a #key needs a JSON secret", Refused: true}
	}
	return Value{Password: s, Version: out.VersionID}, nil
}

// Login is the sign-in name for a connect with v (one rule for every path, both engines): the connection string's
// own login when it names one - it must then be the secret's username when the secret has one (fold: SQL Server's
// names compare without case) -, else the secret's username; neither = refused (pgx would sign in as PGUSER or the
// OS account, go-mssqldb as the service account or an empty SQL login).
func Login(dsnUser string, v Value, fold bool) (string, error) {
	same := dsnUser == v.User
	if fold {
		same = strings.EqualFold(dsnUser, v.User)
	}
	switch {
	case dsnUser != "" && v.User != "" && !same:
		return "", &ReadError{Code: "LoginMismatch", Message: fmt.Sprintf("the connection string's login %q is not the secret's username %q", dsnUser, v.User), Refused: true}
	case dsnUser != "":
		return dsnUser, nil
	case v.User != "":
		return v.User, nil
	}
	return "", &ReadError{Code: "NoLogin", Message: "neither the connection string nor the secret names the login (with #key the connection string names it)", Refused: true}
}
