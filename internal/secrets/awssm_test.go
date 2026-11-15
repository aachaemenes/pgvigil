package secrets

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
)

// a stand-in Secrets Manager: GetSecretValue answers the current value of each secret id, counts its calls, and
// fails on demand
type fakeSM struct {
	mu      sync.Mutex
	values  map[string][2]string // id -> SecretString, VersionId
	status  int                  // 0 = answer; else the HTTP status with errType
	errType string
	calls   atomic.Int64
	delay   time.Duration
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
	var in struct{ SecretId string }
	_ = json.NewDecoder(r.Body).Decode(&in)
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.status != 0 {
		w.WriteHeader(f.status)
		_, _ = w.Write([]byte(`{"__type":"` + f.errType + `","message":"refused for the test"}`))
		return
	}
	v, ok := f.values[in.SecretId]
	if !ok {
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte(`{"__type":"ResourceNotFoundException","message":"no such secret"}`))
		return
	}
	_ = json.NewEncoder(w).Encode(map[string]any{"Name": in.SecretId, "SecretString": v[0], "VersionId": v[1], "VersionStages": []string{"AWSCURRENT"}})
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
	r.endpoint = func(string, bool) string { return srv.URL }
	r.creds = func(context.Context, Ref) (aws.CredentialsProvider, error) {
		return credentials.NewStaticCredentialsProvider("AKIDTEST", "secret-for-the-test", ""), nil
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
	for _, bad := range []string{"pgvigil/read", "aws-secretsmanager:", "aws-secretsmanager:x#"} {
		if _, err := ParseRef(bad, "us-east-2", ""); err == nil {
			t.Errorf("%q accepted", bad)
		}
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
	if v, err := r.Get(ctx, Ref{ID: "keyed", Region: "us-east-2", Key: "pw"}); err != nil || v.Password != "k1" {
		t.Fatalf("keyed: %+v %v", v, err)
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
