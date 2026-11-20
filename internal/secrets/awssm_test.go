package secrets

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/jackc/pgx/v5"
)

// a stand-in Secrets Manager: GetSecretValue answers the current value of each secret id, counts its calls, and
// fails on demand
type fakeSM struct {
	mu      sync.Mutex
	values  map[string][2]string // id -> SecretString, VersionId
	status  int                  // 0 = answer; else the HTTP status with errType
	errType string
	calls   atomic.Int64
	loads   atomic.Int64
	delay   time.Duration
	header  string // X-Amzn-ErrorType on a failure, with no JSON body when set
}

func (f *fakeSM) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.calls.Add(1)
	if r.Header.Get("X-Amz-Target") != "secretsmanager.GetSecretValue" || !strings.HasPrefix(r.Header.Get("Authorization"), "AWS4-HMAC-SHA256 ") {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if f.delay > 0 {
		time.Sleep(f.delay)
	}
	var in struct {
		SecretID string `json:"SecretId"`
	}
	_ = json.NewDecoder(r.Body).Decode(&in)
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.status != 0 {
		if f.header != "" {
			w.Header().Set("X-Amzn-ErrorType", f.header)
			w.WriteHeader(f.status)
			return
		}
		w.WriteHeader(f.status)
		if f.errType != "" {
			_, _ = w.Write([]byte(`{"__type":"` + f.errType + `","message":"refused for the test"}`))
		} else {
			_, _ = w.Write([]byte("<html>proxy authentication required</html>"))
		}
		return
	}
	v, ok := f.values[in.SecretID]
	if !ok {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"__type":"ResourceNotFoundException","message":"no such secret"}`))
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"Name": in.SecretID, "SecretString": v[0], "VersionId": v[1], "VersionStages": []string{"AWSCURRENT"}})
}

func (f *fakeSM) set(id, value, version string) {
	f.mu.Lock()
	f.values[id] = [2]string{value, version}
	f.mu.Unlock()
}

func newTestReader(t *testing.T) (*Reader, *fakeSM, *time.Time) {
	t.Helper()
	f := &fakeSM{values: map[string][2]string{}}
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	now := time.Date(2026, 11, 14, 22, 0, 0, 0, time.UTC)
	r := NewReader()
	r.load = func(context.Context, string, string) (aws.Config, error) {
		f.loads.Add(1)
		return aws.Config{Credentials: credentials.NewStaticCredentialsProvider("AKIDTEST", "secret-for-the-test", ""), BaseEndpoint: aws.String(srv.URL)}, nil
	}
	r.now = func() time.Time { return now }
	return r, f, &now
}

// The reference: aws-secretsmanager:<name or ARN>[#key], an ARN's region winning over the configured one.
func TestParseRef(t *testing.T) {
	r, err := ParseRef("aws-secretsmanager:pgvigil/read#pw", "us-east-2", "lab")
	if err != nil || r.ID != "pgvigil/read" || r.Key != "pw" || r.Region != "us-east-2" || r.Profile != "lab" {
		t.Fatalf("%+v %v", r, err)
	}
	r, err = ParseRef("aws-secretsmanager:arn:aws:secretsmanager:eu-west-1:123456789012:secret:x-AbCdEf", "us-east-2", "")
	if err != nil || r.Region != "eu-west-1" {
		t.Fatalf("an ARN's region: %+v %v", r, err)
	}
	for _, bad := range []string{"pgvigil/read", "aws-secretsmanager:", "aws-secretsmanager:x#", "aws-secretsmanager:#k",
		"aws-secretsmanager:arn:aws:s3:::bucket", "aws-secretsmanager:arn:aws:secretsmanager"} {
		_, err := ParseRef(bad, "us-east-2", "")
		var re *ReadError
		if !errors.As(err, &re) || re.Code != "BadReference" || !re.Refused {
			t.Errorf("%q: %v, want a *ReadError BadReference (never counted as the server's failure)", bad, err)
		}
	}
	// an ARN with an empty region field and no region configured
	if _, err := ParseRef("aws-secretsmanager:arn:aws:secretsmanager::123456789012:secret:x", "", ""); err == nil {
		t.Error("an ARN with no region and no region configured accepted")
	}
	if _, err := ParseRef("aws-secretsmanager:x", "", ""); err == nil {
		t.Error("no region and no ARN accepted")
	}
}

// RDS's JSON (username and password), a #key, a plain string; only the extracted value is kept; a binary secret in words.
func TestGetShapes(t *testing.T) {
	r, f, _ := newTestReader(t)
	f.set("rds", `{"engine":"postgres","host":"h","username":"pgv","password":"p@ss:w/rd%;}","dbname":"x","other":"not-kept"}`, "v1")
	f.set("plain", "plain-pw", "v1")
	f.set("keyed", `{"pw":"k1","username":"u"}`, "v1")
	ctx := context.Background()
	v, err := r.Get(ctx, Ref{ID: "rds", Region: "us-east-2"})
	if err != nil || v.User != "pgv" || v.Password != "p@ss:w/rd%;}" || v.Version != "v1" {
		t.Fatalf("rds: %+v %v", v, err)
	}
	if v, err := r.Get(ctx, Ref{ID: "plain", Region: "us-east-2"}); err != nil || v.Password != "plain-pw" || v.User != "" {
		t.Fatalf("plain: %+v %v", v, err)
	}
	// with #key the key's value is a password alone - the login is the connection string's, never username
	if v, err := r.Get(ctx, Ref{ID: "keyed", Region: "us-east-2", Key: "pw"}); err != nil || v.Password != "k1" || v.User != "" {
		t.Fatalf("keyed: %+v %v (want k1 and no user)", v, err)
	}
	if _, err := r.Get(ctx, Ref{ID: "plain", Region: "us-east-2", Key: "pw"}); err == nil {
		t.Error("a #key on a plain string accepted")
	}
	r.mu.Lock()
	for _, e := range r.entries {
		if e.val != nil && strings.Contains(e.val.User+e.val.Password, "not-kept") {
			t.Error("the whole SecretString is kept")
		}
	}
	r.mu.Unlock()
}

// One read a secret per 5 minutes; K concurrent cold reads = 1 call; one name under two profiles = 2 calls.
func TestCacheAndKey(t *testing.T) {
	r, f, now := newTestReader(t)
	f.set("s", "pw1", "v1")
	ctx := context.Background()
	var wg sync.WaitGroup
	f.delay = 50 * time.Millisecond
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _, _ = r.Get(ctx, Ref{ID: "s", Region: "us-east-2", Profile: "a"}) }()
	}
	wg.Wait()
	f.delay = 0
	if n := f.calls.Load(); n != 1 {
		t.Errorf("8 concurrent cold reads made %d calls, want 1", n)
	}
	_, _ = r.Get(ctx, Ref{ID: "s", Region: "us-east-2", Profile: "b"})
	if n := f.calls.Load(); n != 2 {
		t.Errorf("another profile: %d calls, want 2 (one entry a secret, region and profile)", n)
	}
	*now = now.Add(4 * time.Minute)
	_, _ = r.Get(ctx, Ref{ID: "s", Region: "us-east-2", Profile: "a"})
	if n := f.calls.Load(); n != 2 {
		t.Errorf("inside 5 minutes: %d calls, want 2", n)
	}
	*now = now.Add(2 * time.Minute)
	_, _ = r.Get(ctx, Ref{ID: "s", Region: "us-east-2", Profile: "a"})
	if n := f.calls.Load(); n != 3 {
		t.Errorf("past 5 minutes: %d calls, want 3", n)
	}
}

// After a refused sign-in: one re-read; a retry only when the VersionId changed; else no new read for 60 s.
func TestRefreshAfterAuthFailure(t *testing.T) {
	r, f, now := newTestReader(t)
	ref := Ref{ID: "s", Region: "us-east-2"}
	f.set("s", "old", "v1")
	ctx := context.Background()
	v, _ := r.Get(ctx, ref)
	before := f.calls.Load()
	// the database's password changed, the secret not yet (a single-user rotation's window)
	if _, retry, _ := r.Refresh(ctx, ref, v.Version); retry {
		t.Error("a re-read giving the same VersionId asked for a retry")
	}
	if _, retry, _ := r.Refresh(ctx, ref, v.Version); retry || f.calls.Load() != before+1 {
		t.Errorf("a second refused sign-in inside the back-off: calls %d, want %d (no new read)", f.calls.Load(), before+1)
	}
	*now = now.Add(61 * time.Second)
	f.set("s", "new", "v2")
	nv, retry, err := r.Refresh(ctx, ref, v.Version)
	if err != nil || !retry || nv.Password != "new" || nv.Version != "v2" {
		t.Fatalf("after the back-off with a new version: %+v %v %v", nv, retry, err)
	}
	// a caller whose sign-in failed on v1 after another already read v2: it retries with v2, and no new read is made
	calls := f.calls.Load()
	if nv2, retry, _ := r.Refresh(ctx, ref, "v1"); !retry || nv2.Version != "v2" || f.calls.Load() != calls {
		t.Errorf("a failure on an older version: %+v retry %v, calls %d (want v2, a retry, no new call)", nv2, retry, f.calls.Load()-calls)
	}
}

// A refused read drops the value (a revoke takes effect); a transient error keeps it one more bound and says so.
func TestRefusedAndTransient(t *testing.T) {
	r, f, now := newTestReader(t)
	ref := Ref{ID: "s", Region: "us-east-2"}
	f.set("s", "pw", "v1")
	ctx := context.Background()
	if _, err := r.Get(ctx, ref); err != nil {
		t.Fatal(err)
	}
	*now = now.Add(6 * time.Minute)
	f.status, f.errType = http.StatusServiceUnavailable, "InternalServiceError"
	v, err := r.Get(ctx, ref)
	if err != nil || v.Password != "pw" || !v.Stale {
		t.Errorf("a transient error: %+v %v, want the value kept and marked stale", v, err)
	}
	*now = now.Add(6 * time.Minute)
	f.status, f.errType = http.StatusBadRequest, "InvalidRequestException"
	_, err = r.Get(ctx, ref)
	var re *ReadError
	if !errors.As(err, &re) || !re.Refused || re.Code != "InvalidRequestException" || !strings.Contains(err.Error(), "s") {
		t.Fatalf("a refused read: %v", err)
	}
	if strings.Contains(err.Error(), "pw") {
		t.Error("the error carries the value")
	}
	r.mu.Lock()
	for _, e := range r.entries {
		if e.val != nil {
			t.Error("a refused read kept the value")
		}
	}
	r.mu.Unlock()
}

// The read gives up within its 5 s and at most 2 attempts.
func TestReadDeadline(t *testing.T) {
	r, f, _ := newTestReader(t)
	f.set("s", "pw", "v1")
	f.delay = 6 * time.Second // past the read's 5 s: the endpoint never answers in time
	start := time.Now()
	_, err := r.Get(context.Background(), Ref{ID: "s", Region: "us-east-2"})
	if err == nil || time.Since(start) > 5500*time.Millisecond || f.calls.Load() > 2 {
		t.Errorf("a slow endpoint: %v after %v and %d calls (want a failure within about 5 s, 2 calls at most)", err, time.Since(start), f.calls.Load())
	}
}

// A version the server refused is held - no caller gets it during its back-off (no dial, no lockout), then
// one probe a back-off; a sign-in that works with it, or a new version, ends the hold.
func TestRefusedVersionHeld(t *testing.T) {
	r, f, now := newTestReader(t)
	ref := Ref{ID: "s", Region: "us-east-2"}
	f.set("s", "old", "v1")
	ctx := context.Background()
	v, _ := r.Get(ctx, ref)
	if _, retry, _ := r.Refresh(ctx, ref, v.Version); retry {
		t.Fatal("the same version asked for a retry")
	}
	calls := f.calls.Load()
	for i := 0; i < 5; i++ {
		_, err := r.Get(ctx, ref)
		var re *ReadError
		if !errors.As(err, &re) || re.Code != "LoginRefused" || re.Refused {
			t.Fatalf("Get %d inside the back-off: %v, want a *ReadError LoginRefused (transient, no dial)", i, err)
		}
	}
	if f.calls.Load() != calls {
		t.Errorf("the held version made %d calls inside its back-off, want 0", f.calls.Load()-calls)
	}
	*now = now.Add(61 * time.Second)
	if p, err := r.Get(ctx, ref); err != nil || p.Version != "v1" {
		t.Fatalf("after the back-off: %+v %v, want the one probe with v1", p, err)
	}
	if _, err := r.Get(ctx, ref); err == nil {
		t.Error("a second caller right after the probe got the refused version (one probe a back-off)")
	}
	r.Accepted(ctx, ref, "v1")
	if p, err := r.Get(ctx, ref); err != nil || p.Version != "v1" {
		t.Errorf("after the probe signed in: %+v %v, want v1 handed out again", p, err)
	}
	// a new version ends the hold
	_, _, _ = r.Refresh(ctx, ref, "v1")
	*now = now.Add(61 * time.Second)
	f.set("s", "new", "v2")
	if p, err := r.Get(ctx, ref); err != nil || p.Version != "v2" {
		t.Fatalf("a new version after the back-off: %+v %v", p, err)
	}
	if p, err := r.Get(ctx, ref); err != nil || p.Version != "v2" {
		t.Errorf("v2 held: %+v %v", p, err)
	}
}

// A failed read is answered from the entry until the back-off ends (refused or a cold transient); a waiter
// on a read in flight leaves with its own context.
func TestFailureKept(t *testing.T) {
	r, f, now := newTestReader(t)
	ctx := context.Background()
	f.status, f.errType = http.StatusBadRequest, "AccessDeniedException"
	ref := Ref{ID: "s", Region: "us-east-2"}
	for i := 0; i < 10; i++ {
		if _, err := r.Get(ctx, ref); err == nil {
			t.Fatal("a refused read answered")
		}
	}
	if n := f.calls.Load(); n != 1 {
		t.Errorf("10 connects on a refused secret made %d calls, want 1 inside the back-off", n)
	}
	*now = now.Add(61 * time.Second)
	_, _ = r.Get(ctx, ref)
	if n := f.calls.Load(); n != 2 {
		t.Errorf("past the back-off: %d calls, want 2", n)
	}
	f.status, f.errType = http.StatusServiceUnavailable, "InternalServiceError"
	cold := Ref{ID: "cold", Region: "us-east-2"}
	_, _ = r.Get(ctx, cold)
	before := f.calls.Load()
	_, _ = r.Get(ctx, cold)
	if f.calls.Load() != before {
		t.Error("a cold transient failure was not kept for its back-off")
	}
	f.status = 0
	f.set("slow", "pw", "v1")
	f.delay = 2 * time.Second
	slow := Ref{ID: "slow", Region: "us-east-2"}
	go func() { _, _ = r.Get(context.Background(), slow) }()
	time.Sleep(100 * time.Millisecond)
	wctx, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := r.Get(wctx, slow)
	var re *ReadError
	if !errors.As(err, &re) || re.Code != "Waiting" || re.Refused || time.Since(start) > time.Second {
		t.Errorf("a waiter on a slow read: %v after %v, want a transient Waiting within its own 100 ms", err, time.Since(start))
	}
}

// Only the design's four codes drop a kept value; an expired credential, a proxy's non-JSON 407 and a code
// carried only in X-Amzn-ErrorType are read as such.
func TestRefusedCodes(t *testing.T) {
	r, f, now := newTestReader(t)
	ctx := context.Background()
	ref := Ref{ID: "s", Region: "us-east-2"}
	f.set("s", "pw", "v1")
	if _, err := r.Get(ctx, ref); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		status            int
		typ, header, code string
	}{
		{http.StatusBadRequest, "ExpiredTokenException", "", "ExpiredTokenException"},
		{http.StatusForbidden, "UnrecognizedClientException", "", "UnrecognizedClientException"},
		{http.StatusProxyAuthRequired, "", "", "HTTP 407"},
	} {
		*now = now.Add(6 * time.Minute)
		f.status, f.errType, f.header = c.status, c.typ, c.header
		v, err := r.Get(ctx, ref)
		if err != nil || v.Password != "pw" || !v.Stale {
			t.Errorf("%s: %+v %v, want the kept value (transient)", c.code, v, err)
		}
	}
	*now = now.Add(6 * time.Minute)
	f.status, f.errType, f.header = http.StatusForbidden, "", "AccessDeniedException:http://internal.amazon.com/coral/com.amazonaws.secretsmanager/"
	_, err := r.Get(ctx, ref)
	var re *ReadError
	if !errors.As(err, &re) || re.Code != "AccessDeniedException" || !re.Refused {
		t.Errorf("a code in the header alone: %v, want AccessDeniedException refused", err)
	}
}

// A stale value served is logged, with the secret and the code, never the value.
func TestStaleLogged(t *testing.T) {
	r, f, now := newTestReader(t)
	var buf bytes.Buffer
	r.SetLog(slog.New(slog.NewTextHandler(&buf, nil)))
	ctx := context.Background()
	ref := Ref{ID: "s", Region: "us-east-2"}
	f.set("s", "pw-not-logged", "v1")
	_, _ = r.Get(ctx, ref)
	*now = now.Add(6 * time.Minute)
	f.status, f.errType = http.StatusServiceUnavailable, "InternalServiceError"
	_, _ = r.Get(ctx, ref)
	out := buf.String()
	if !strings.Contains(out, "kept") || !strings.Contains(out, "InternalServiceError") || !strings.Contains(out, "secret=s") {
		t.Errorf("the stale value was not logged: %q", out)
	}
	if strings.Contains(out, "pw-not-logged") {
		t.Error("the log carries the value")
	}
}

// One login rule for every path - the string's login wins and must be the secret's username; else the
// secret's; neither = refused.
func TestLogin(t *testing.T) {
	for _, c := range []struct {
		dsn, secret string
		fold        bool
		want, code  string
	}{
		{"", "u", false, "u", ""},
		{"u", "u", false, "u", ""},
		{"mon", "", false, "mon", ""},
		{"mon", "u", false, "", "LoginMismatch"},
		{"U", "u", false, "", "LoginMismatch"},
		{"U", "u", true, "U", ""},
		{"", "", false, "", "NoLogin"},
	} {
		got, err := Login(c.dsn, Value{User: c.secret}, c.fold)
		var re *ReadError
		switch {
		case c.code == "" && (err != nil || got != c.want):
			t.Errorf("%q / %q: %q %v, want %q", c.dsn, c.secret, got, err, c.want)
		case c.code != "" && (!errors.As(err, &re) || re.Code != c.code || !re.Refused):
			t.Errorf("%q / %q: %v, want %s refused", c.dsn, c.secret, err, c.code)
		}
	}
}

// The settings as libpq reads them - spaces around '=', quoted values, the URL's ?user= - never
// strings.Fields.
func TestPGSettings(t *testing.T) {
	for _, c := range []struct{ dsn, key, want string }{
		{"host=h user = pgvigil dbname=d", "user", "pgvigil"},
		{"host=h password = p dbname=d", "password", "p"},
		{`host=h user='mon itor' application_name='a\'b'`, "user", "mon itor"},
		{`host=h application_name='a\'b' user=x`, "application_name", "a'b"},
		{"postgres://h:5432/d?user=mon&sslmode=require", "user", "mon"},
		{"postgresql://u%40x:p@h/d", "user", "u@x"},
		{"postgresql://u%40x:p@h/d", "password", "p"},
	} {
		m, err := PGSettings(c.dsn)
		if err != nil || m[c.key] != c.want {
			t.Errorf("%s: %s = %q (%v), want %q", c.dsn, c.key, m[c.key], err, c.want)
		}
	}
	if _, err := PGSettings("host=h user"); err == nil {
		t.Error("a key without '=' accepted")
	}
}

// The password goes on the parsed config, never into a string: the config's string carries none (a
// password with a quote and a space - pgx's redaction stops at an escaped quote), and a multi-host URL keeps it.
func TestFillPG(t *testing.T) {
	r, f, _ := newTestReader(t)
	pw := "ab'cd ef"
	f.set("s", `{"username":"pgv","password":"ab'cd ef"}`, "v1")
	ref := &Ref{ID: "s", Region: "us-east-2"}
	ctx := context.Background()
	for _, dsn := range []string{"host=h dbname=d sslmode=disable", "postgres://h1:5432,h2:5432/db?sslmode=disable"} {
		cfg, err := pgx.ParseConfig(dsn)
		if err != nil {
			t.Fatal(err)
		}
		if err := r.FillPG(ctx, cfg, dsn, ref); err != nil {
			t.Fatalf("%s: %v", dsn, err)
		}
		if cfg.User != "pgv" || cfg.Password != pw || strings.Contains(cfg.ConnString(), "cd ef") {
			t.Errorf("%s: user %q, password set %v, string %q", dsn, cfg.User, cfg.Password == pw, cfg.ConnString())
		}
	}
	cfg, _ := pgx.ParseConfig("host=h user=other dbname=d")
	err := r.FillPG(ctx, cfg, "host=h user=other dbname=d", ref)
	var re *ReadError
	if !errors.As(err, &re) || re.Code != "LoginMismatch" || re.Secret != "s" {
		t.Errorf("a string's user other than the secret's: %v, want LoginMismatch naming the secret", err)
	}
}

// A configured endpoint (AWS_ENDPOINT_URL_SECRETS_MANAGER, a profile's use_fips_endpoint), the China
// partition's domain.
func TestEndpoint(t *testing.T) {
	dir := t.TempDir()
	conf := dir + "/config"
	if err := os.WriteFile(conf, []byte("[profile fips]\nregion = us-east-2\nuse_fips_endpoint = true\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AWS_CONFIG_FILE", conf)
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", dir+"/none")
	t.Setenv("AWS_ACCESS_KEY_ID", "AKIDTEST")
	t.Setenv("AWS_SECRET_ACCESS_KEY", "x")
	ctx := context.Background()
	if got, _ := NewReader().Endpoint(ctx, Ref{ID: "s", Region: "cn-north-1"}); got != "https://secretsmanager.cn-north-1.amazonaws.com.cn/" {
		t.Errorf("cn: %s", got)
	}
	if got, _ := NewReader().Endpoint(ctx, Ref{ID: "s", Region: "us-east-2", Profile: "fips"}); got != "https://secretsmanager-fips.us-east-2.amazonaws.com/" {
		t.Errorf("a profile's use_fips_endpoint: %s", got)
	}
	// the host is the service's own endpoint resolver's for the region's partition (task 205's rule: pgvigil writes no
	// partition's domain): GovCloud, and an isolated partition whose domain is not amazonaws.com at all
	if got, _ := NewReader().Endpoint(ctx, Ref{ID: "s", Region: "us-gov-west-1"}); got != "https://secretsmanager.us-gov-west-1.amazonaws.com/" {
		t.Errorf("GovCloud: %s", got)
	}
	if got, _ := NewReader().Endpoint(ctx, Ref{ID: "s", Region: "us-iso-east-1"}); got != "https://secretsmanager.us-iso-east-1.c2s.ic.gov/" {
		t.Errorf("an isolated partition: %s", got)
	}
	t.Setenv("AWS_ENDPOINT_URL_SECRETS_MANAGER", "https://vpce-1.secretsmanager.us-east-2.vpce.amazonaws.com")
	if got, _ := NewReader().Endpoint(ctx, Ref{ID: "s", Region: "us-east-2"}); got != "https://vpce-1.secretsmanager.us-east-2.vpce.amazonaws.com/" {
		t.Errorf("AWS_ENDPOINT_URL_SECRETS_MANAGER: %s", got)
	}
}

// The SDK's configuration (an assumed role's credentials cache with it) is loaded once a region and
// profile, not once a read.
func TestSiteLoadedOnce(t *testing.T) {
	r, f, now := newTestReader(t)
	f.set("s", "pw", "v1")
	ctx := context.Background()
	for i := 0; i < 3; i++ {
		_, _ = r.Get(ctx, Ref{ID: "s", Region: "us-east-2", Profile: "a"})
		*now = now.Add(6 * time.Minute)
	}
	if n := f.loads.Load(); n != 1 {
		t.Errorf("3 reads loaded the SDK's configuration %d times, want 1", n)
	}
}
