package mssql

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
)

// mssql_failover_groups (task 390a G2): the server's failover groups from Resource Manager's List By Server
// (2025-01-01), its failover operations from the Activity Log (a trial) - read per GROUP on this server and on each
// partner (a failover is logged on the group resource, and a planned one on the new primary's), paged by nextLink,
// the group's operations matched by their prefix (a link's own failover/action is not one) - one read a server an
// interval, a refusal and a throttle in words.
func TestFailoverGroupsRead(t *testing.T) {
	var lists, logs int
	var filters []string
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
		case strings.Contains(r.URL.Path, "/providers/Microsoft.Insights/eventtypes/management/values") && r.URL.Query().Get("page") == "2":
			logs++
			_, _ = w.Write([]byte(`{"value":[{"eventDataId":"e3","correlationId":"c1","eventTimestamp":"2026-11-14T10:02:00Z",
				"operationName":{"value":"Microsoft.Sql/servers/failoverGroups/failover/action"},"status":{"value":"Succeeded"},
				"resourceId":"/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-b/failoverGroups/fg1"}]}`))
		case strings.Contains(r.URL.Path, "/providers/Microsoft.Insights/eventtypes/management/values"):
			logs++
			f := r.URL.Query().Get("$filter")
			filters = append(filters, f)
			if strings.Contains(f, "/servers/pgv-b/failoverGroups/fg1'") {
				// the partner's group: the planned failover's Started on page 1, its Succeeded on page 2; a link's own
				// failover (a database's replicationLinks) and a try-planned-before-forced
				_, _ = w.Write([]byte(`{"value":[{"eventDataId":"e2","correlationId":"c1","eventTimestamp":"2026-11-14T10:00:00Z",
					"operationName":{"value":"Microsoft.Sql/servers/failoverGroups/failover/action"},"status":{"value":"Started"},
					"resourceId":"/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-b/failoverGroups/fg1","caller":"someone@example.com"},
					{"eventDataId":"e4","correlationId":"c2","eventTimestamp":"2026-11-14T10:05:00Z",
					"operationName":{"value":"Microsoft.Sql/servers/databases/replicationLinks/failover/action"},"status":{"value":"Succeeded"},
					"resourceId":"/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-b/databases/db1/replicationLinks/0f0e"},
					{"eventDataId":"e5","correlationId":"c3","eventTimestamp":"2026-11-14T10:06:00Z",
					"operationName":{"value":"Microsoft.Sql/servers/failoverGroups/tryPlannedBeforeForcedFailover/action"},"status":{"value":"Succeeded"},
					"resourceId":"/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-b/failoverGroups/fg1"}],
					"nextLink":"` + "http://" + r.Host + r.URL.Path + `?page=2"}`))
				return
			}
			_, _ = w.Write([]byte(`{"value":[]}`))
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
	var group, read map[string]any
	ops := map[string]map[string]any{}
	for _, r := range rows {
		switch r["kind"] {
		case "group":
			group = r
		case "operation":
			ops[r["event_id"].(string)] = r
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
	// one Activity Log read per group on this server and per partner: resourceUri eq the GROUP's id (an exact match: a
	// server's id never returns its groups' events)
	wantFilters := []string{"resourceUri eq '/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-a/failoverGroups/fg1'",
		"resourceUri eq '/subscriptions/s/resourceGroups/g/providers/Microsoft.Sql/servers/pgv-b/failoverGroups/fg1'"}
	if lists != 1 || logs != 3 || len(filters) != 2 {
		t.Errorf("calls: %d lists, %d log pages, %d log filters %q; want 1, 3 (two groups' reads and one next page), 2", lists, logs, len(filters), filters)
	}
	for i, w := range wantFilters {
		if i >= len(filters) || !strings.Contains(filters[i], w) {
			t.Errorf("log filter %d: %q, want it to hold %q", i, filters, w)
		}
	}
	// the events of one operation (its correlationId) are each a row; the store keeps one per operation; a link's own
	// failover is not a group's; try-planned-before-forced is its own kind
	if len(ops) != 3 || ops["e2"]["correlation_id"] != "c1" || ops["e2"]["status"] != "Started" || ops["e3"]["status"] != "Succeeded" ||
		ops["e3"]["group_name"] != "fg1" || ops["e5"]["operation"] != "planned before forced failover" || ops["e4"] != nil {
		t.Fatalf("operation rows %v", ops)
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
}

// A failed read gives the server's slot back, so another database of the server reads it in
// the same interval (an identity without the right never holds the server for good); a good read keeps it.
func TestFailoverGroupsGateGivesBack(t *testing.T) {
	fail := true
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if fail {
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"error":{"code":"AuthorizationFailed","message":"no access"}}`))
			return
		}
		_, _ = w.Write([]byte(`{"value":[]}`))
	}))
	defer srv.Close()
	d := fgDoor{arm: srv.URL, token: func(context.Context, string, string) (string, error) { return "tok", nil }, http: srv.Client(), now: time.Now}
	az := &config.Azure{Subscription: "s", ResourceGroup: "g", Server: fmt.Sprintf("pgv-gate-%d", time.Now().UnixNano())}
	x := config.Instance{Name: "x", Engine: config.EngineSQLServer, DSNRaw: "env:X", Azure: az}
	y := config.Instance{Name: "y", Engine: config.EngineSQLServer, DSNRaw: "env:Y", Azure: az}
	c := failoverGroupsCollector{}
	if _, err := c.runDoor(context.Background(), x, d); err == nil || errors.Is(err, collect.ErrSkip) {
		t.Fatalf("x's refused read: %v, want the refusal", err)
	}
	fail = false
	if _, err := c.runDoor(context.Background(), y, d); err != nil {
		t.Fatalf("y after x's failed read, in the same interval: %v, want a read", err)
	}
	if _, err := c.runDoor(context.Background(), x, d); err == nil || !errors.Is(err, collect.ErrSkip) {
		t.Errorf("x after y's good read: %v, want a skip naming y", err)
	}
}

// A refusal names Resource Manager's code and the right; a throttle (429) is a skip until its Retry-After.
func TestFailoverGroupsRefusals(t *testing.T) {
	status := http.StatusForbidden
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
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
