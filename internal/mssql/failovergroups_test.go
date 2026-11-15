package mssql

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/config"
)

// mssql_failover_groups (task 390a G2): the server's failover groups from Resource Manager's List By Server
// (2025-01-01), its failover operations from the Activity Log (a trial), one read a server an interval, a refusal and
// a throttle in words.
func TestFailoverGroupsRead(t *testing.T) {
	var lists, logs int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch {
		case strings.Contains(r.URL.Path, "/providers/Microsoft.Sql/servers/pgv-a/failoverGroups"):
			lists++
			if r.URL.Query().Get("api-version") != "2025-01-01" {
				t.Errorf("api-version %q", r.URL.Query().Get("api-version"))
			}
			_, _ = w.Write([]byte(`{"value":[{"name":"fg1","properties":{"replicationRole":"Primary","replicationState":"CATCH_UP",
				"secondaryType":"Geo","readWriteEndpoint":{"failoverPolicy":"Automatic","failoverWithDataLossGracePeriodMinutes":60},
				"readOnlyEndpoint":{"failoverPolicy":"Disabled","targetServer":""},
				"partnerServers":[{"id":"/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-b","location":"East US","replicationRole":"Secondary"}],
				"databases":["/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-a/databases/db1"]}}]}`))
		case strings.Contains(r.URL.Path, "/providers/Microsoft.Insights/eventtypes/management/values"):
			logs++
			_, _ = w.Write([]byte(`{"value":[{"eventDataId":"e1","eventTimestamp":"2026-11-14T10:00:00Z",
				"operationName":{"value":"Microsoft.Sql/servers/failoverGroups/failover/action"},"status":{"value":"Succeeded"},
				"resourceId":"/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-a/failoverGroups/fg1","caller":"someone@example.com"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	fg := failoverGroupsCollector{}
	in := config.Instance{Name: "db1-a", Engine: config.EngineSQLServer, DSNRaw: "env:X",
		Azure: &config.Azure{Subscription: "s", ResourceGroup: "g", Server: "pgv-a"}}
	d := fgDoor{arm: srv.URL, token: func(context.Context, string, string) (string, error) { return "tok", nil }, http: srv.Client(), now: time.Now}
	rows, err := d.read(context.Background(), in)
	if err != nil {
		t.Fatal(err)
	}
	var group, op, read map[string]any
	for _, r := range rows {
		switch r["kind"] {
		case "group":
			group = r
		case "operation":
			op = r
		case "read":
			read = r
		}
	}
	if read == nil || read["server_key"] != "s/g/pgv-a" {
		t.Fatalf("read row %v", read)
	}
	if group == nil || group["group_name"] != "fg1" || group["role"] != "Primary" || group["rw_policy"] != "Automatic" ||
		group["grace_minutes"] != 60.0 || group["secondary_type"] != "Geo" || !strings.Contains(group["partners"].(string), "pgv-b") {
		t.Fatalf("group row %v", group)
	}
	if op == nil || op["event_id"] != "e1" || op["operation"] != "failover" || op["status"] != "Succeeded" {
		t.Fatalf("operation row %v", op)
	}
	for _, r := range rows {
		for _, v := range r {
			if s, ok := v.(string); ok && strings.Contains(s, "someone@example.com") {
				t.Fatal("the Activity Log's caller is kept: it names a person")
			}
		}
	}
	// one read a server an interval: a second database of the same server in the same interval is skipped
	in2 := in
	in2.Name = "db2-a"
	if !fgGate.take(in.Azure.ServerKey(), in.Name, time.Now(), 5*time.Minute) {
		t.Fatal("the first take of the gate was refused")
	}
	if fgGate.take(in2.Azure.ServerKey(), in2.Name, time.Now(), 5*time.Minute) {
		t.Fatal("a second database of the same server read it in the same interval")
	}
	if ok, why := fg.Configured(config.Instance{Name: "x"}); ok || !strings.Contains(why, "azure:") {
		t.Errorf("no azure: block: %v %q", ok, why)
	}
	if ok, _ := fg.Applies(Info{Kind: KindServer}); ok {
		t.Error("applies on a server")
	}
	_ = lists + logs
}

// A refusal names Resource Manager's code and the right; a throttle (429) is a skip until its Retry-After.
func TestFailoverGroupsRefusals(t *testing.T) {
	status := http.StatusForbidden
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if status == http.StatusTooManyRequests {
			w.Header().Set("Retry-After", "120")
		}
		w.WriteHeader(status)
		_, _ = w.Write([]byte(`{"error":{"code":"AuthorizationFailed","message":"no access"}}`))
	}))
	defer srv.Close()
	in := config.Instance{Name: "db1", Engine: config.EngineSQLServer, DSNRaw: "env:X", Azure: &config.Azure{Subscription: "s", ResourceGroup: "g", Server: "pgv-z"}}
	d := fgDoor{arm: srv.URL, token: func(context.Context, string, string) (string, error) { return "tok", nil }, http: srv.Client(), now: time.Now}
	if _, err := d.read(context.Background(), in); err == nil || !strings.Contains(err.Error(), "AuthorizationFailed") || !strings.Contains(err.Error(), "failoverGroups/read") {
		t.Errorf("403: %v", err)
	}
	status = http.StatusTooManyRequests
	if _, err := d.read(context.Background(), in); err == nil || !strings.Contains(err.Error(), "throttled") {
		t.Errorf("429: %v", err)
	}
}
