package cloudrepl

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/rds"
	rdstypes "github.com/aws/aws-sdk-go-v2/service/rds/types"
	"github.com/aws/smithy-go"
	"golang.org/x/oauth2"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// Google's replica_lag below 0 ('replication is inactive', its metrics page)
// is no lag point; the byte lag's replica_name is matched whole or after its last ':'; a series naming no replica
// leaves one note; a 401 is a refused or expired sign-in, never a missing right.
func TestGCPFoldA(t *testing.T) {
	adminStatus := http.StatusOK
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/sql/") && adminStatus != http.StatusOK:
			w.WriteHeader(adminStatus)
			_, _ = w.Write([]byte(`{"error":{"code":401,"message":"Request had invalid authentication credentials.","status":"UNAUTHENTICATED"}}`))
		case r.URL.Path == "/sql/v1/projects/p1/instances/pg-a":
			_, _ = w.Write([]byte(`{"name":"pg-a","project":"p1","region":"us-central1","state":"RUNNABLE","replicaNames":["pg-a-r1"]}`))
		case r.URL.Path == "/sql/v1/projects/p1/instances/pg-a-r1":
			_, _ = w.Write([]byte(`{"name":"pg-a-r1","project":"p1","region":"us-central1","state":"RUNNABLE","masterInstanceName":"p1:pg-a"}`))
		case r.URL.Path == "/mon/v3/projects/p1/timeSeries":
			f := r.URL.Query().Get("filter")
			switch {
			case strings.Contains(f, `database/replication/replica_lag"`):
				_, _ = w.Write([]byte(`{"timeSeries":[{"resource":{"labels":{"database_id":"p1:pg-a-r1"}},"points":[
					{"interval":{"endTime":"2026-11-14T09:58:00Z"},"value":{"doubleValue":-1}},
					{"interval":{"endTime":"2026-11-14T09:57:00Z"},"value":{"doubleValue":2}}]}]}`))
			case strings.Contains(f, `replica_byte_lag"`):
				_, _ = w.Write([]byte(`{"timeSeries":[{"metric":{"labels":{"replica_name":"p1:pg-a-r1","replica_lag_type":"replay_location"}},
					"points":[{"interval":{"endTime":"2026-11-14T09:58:00Z"},"value":{"int64Value":"4096"}}]},
					{"metric":{"labels":{"replica_name":"ghost-r9","replica_lag_type":"replay_location"}},
					"points":[{"interval":{"endTime":"2026-11-14T09:58:00Z"},"value":{"int64Value":"1"}}]}]}`))
			default:
				_, _ = w.Write([]byte(`{}`))
			}
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	now := time.Date(2026, 11, 14, 10, 0, 0, 0, time.UTC)
	g := &GCPReader{HTTP: srv.Client(), AdminURL: srv.URL + "/sql", MonitoringURL: srv.URL + "/mon", Now: func() time.Time { return now }}
	_, pts, notes, err := g.Read(context.Background(), "p1", "pg-a")
	if err != nil {
		t.Fatal(err)
	}
	lag, bytes := 0, 0
	for _, p := range pts {
		switch {
		case p.Metric == "replica_lag" && p.Value < 0:
			t.Errorf("a negative replica_lag stored as lag: %+v", p)
		case p.Metric == "replica_lag":
			lag++
		case p.Metric == "replica_byte_lag" && p.ResourceID == "p1:pg-a-r1":
			bytes++
		}
	}
	if lag != 1 || bytes != 1 {
		t.Errorf("points: %d lag (want 1: the -1 dropped), %d byte lag (want 1: the label 'p1:pg-a-r1' matched)", lag, bytes)
	}
	if len(notes) != 1 || !strings.Contains(notes[0], "ghost-r9") {
		t.Errorf("notes %v, want one naming the byte-lag series that matches no replica", notes)
	}
	adminStatus = http.StatusUnauthorized
	_, _, notes, err = g.Read(context.Background(), "p1", "pg-a")
	words := strings.Join(notes, " ")
	if err != nil {
		words += " " + err.Error()
	}
	if !strings.Contains(words, "sign-in was refused or has expired") || strings.Contains(words, "the identity needs") {
		t.Errorf("a 401: %q, want the sign-in named, not a right", words)
	}
}

// a domain-scoped project ('example.com:proj') is split at the LAST colon
func TestGCPRefDomainScoped(t *testing.T) {
	if p, n := gcpRef("example.com:proj:primary", "x"); p != "example.com:proj" || n != "primary" {
		t.Errorf("gcpRef: %q %q", p, n)
	}
	if p, n := gcpRef("p1:pg-a", "x"); p != "p1" || n != "pg-a" {
		t.Errorf("gcpRef: %q %q", p, n)
	}
}

// AWS: an expired or unknown token is a refused sign-in, never a missing right
func TestAWSSignInWords(t *testing.T) {
	for _, code := range []string{"ExpiredToken", "ExpiredTokenException", "InvalidClientTokenId", "UnrecognizedClientException"} {
		err := awsErr("rds:DescribeDBInstances", "us-east-2", &smithy.GenericAPIError{Code: code, Message: "x"})
		if !strings.Contains(err.Error(), "sign-in was refused or has expired") || strings.Contains(err.Error(), "the identity needs") {
			t.Errorf("%s: %v", code, err)
		}
	}
	if err := awsErr("rds:DescribeDBInstances", "us-east-2", &smithy.GenericAPIError{Code: "AccessDenied", Message: "x"}); !strings.Contains(err.Error(), "the identity needs") {
		t.Errorf("AccessDenied: %v", err)
	}
}

// the token fetch carries a 30 s client (the token source keeps this context for every refresh)
func TestGCPTokenContextTimeout(t *testing.T) {
	c, ok := gcpTokenContext().Value(oauth2.HTTPClient).(*http.Client)
	if !ok || c.Timeout != 30*time.Second {
		t.Errorf("the token context's client: %+v %v, want a 30 s timeout", c, ok)
	}
}

// the credentials file's type gate - only a service account key or a workload identity federation file
func TestGCPCredentialsGate(t *testing.T) {
	dir := t.TempDir()
	for name, body := range map[string]string{"authorized_user": `{"type":"authorized_user"}`, "impersonated_service_account": `{"type":"impersonated_service_account"}`, "not JSON": `not json`} {
		f := filepath.Join(dir, strings.ReplaceAll(name, " ", "_")+".json")
		if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := NewGCPReader(f); err == nil {
			t.Errorf("%s: taken, want refused", name)
		}
	}
}

// a rotated key file (a new modification time) builds a new reader; the same file keeps its reader
func TestGCPReaderRotation(t *testing.T) {
	f := filepath.Join(t.TempDir(), "sa.json")
	if err := os.WriteFile(f, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	built := 0
	d := &Door{NewGCP: func(string) (*GCPReader, error) { built++; return &GCPReader{}, nil }}
	for range 2 {
		if _, err := d.gcpReader(f); err != nil {
			t.Fatal(err)
		}
	}
	later := time.Now().Add(time.Hour)
	if err := os.Chtimes(f, later, later); err != nil {
		t.Fatal(err)
	}
	if _, err := d.gcpReader(f); err != nil {
		t.Fatal(err)
	}
	if built != 2 {
		t.Errorf("readers built: %d, want 2 (once, then again after the file changed)", built)
	}
}

type refusedEvents struct{}

func (refusedEvents) DescribeEvents(context.Context, *rds.DescribeEventsInput, ...func(*rds.Options)) (*rds.DescribeEventsOutput, error) {
	return nil, &smithy.GenericAPIError{Code: "AccessDenied", Message: "not authorized to perform rds:DescribeEvents"}
}

// AWS: ReplicaLag below 0 is no point; a refused DescribeEvents under the Door leaves the read
// standing with a note; GetMetricData's pages are all read and its window is the last 20 minutes
func TestDoorFoldA(t *testing.T) {
	now := time.Date(2026, 11, 15, 10, 0, 0, 0, time.UTC)
	east := &fakeRDS{list: []rdstypes.DBInstance{db("db1", "available", "", []string{"db1-r1"}), db("db1-r1", "available", "db1", nil, replicating("replicating"))}}
	cw := &fakeCW{lag: map[string][]float64{"db1-r1": {-1, 4}}, pages: true}
	d := &Door{
		Now: func() time.Time { return now },
		NewAWS: func(string) *AWSReader {
			return &AWSReader{
				RDS:    func(context.Context, string) (RDSAPI, error) { return east, nil },
				CW:     func(context.Context, string) (CWAPI, error) { return cw, nil },
				Events: func(context.Context, string) (RDSEventsAPI, error) { return refusedEvents{}, nil },
				Now:    func() time.Time { return now },
			}
		},
	}
	rows, err := d.Rows(context.Background(), config.Instance{Name: "pg1", AWS: &config.AWS{Region: "us-east-2", DBInstance: "db1", Replicas: true}})
	if err != nil {
		t.Fatal(err)
	}
	points, resources := 0, 0
	for _, r := range rows {
		switch r["kind"] {
		case "point":
			points++
			if v, _ := r["value"].(float64); v < 0 {
				t.Errorf("a negative ReplicaLag stored: %v", r)
			}
		case "resource":
			resources++
		}
	}
	notes, _ := rows[0]["notes"].([]string)
	if resources != 2 || !strings.Contains(strings.Join(notes, " "), "DescribeEvents") {
		t.Errorf("a refused DescribeEvents: %d resources, notes %v - want the read standing (2 resources) and the refusal noted", resources, notes)
	}
	if points != 1 || cw.calls < 2 {
		t.Errorf("%d points over %d GetMetricData call(s), want 1 (the -1 on the first page dropped, the 4 read from the second)", points, cw.calls)
	}
	if cw.window != 20*time.Minute {
		t.Errorf("GetMetricData's window %v, want 20m", cw.window)
	}
}
