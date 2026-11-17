package web

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestServiceBrokerTabOnAStore (P25 row 73: DBA Dash's database Service Broker tab): on a store (PGVIGIL_REPO_TEST_DSN,
// skipped without it) /api/mssql/checks gives, for one database (db=), its queues as last read, the depth of each
// queue over the window, its transmission groups and conversations, the instance's broker endpoint, and the Broker
// counters as rates over the window (each sample's difference from the one before, per second; none across a restart).
func TestServiceBrokerTabOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("sbtab-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	now := time.Now().UTC().Truncate(time.Minute)
	imp := func(m int, rows ...map[string]any) {
		t.Helper()
		js, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_service_broker($1, $2, $3::jsonb)`, id, now.Add(time.Duration(m)*time.Minute), string(js)); err != nil {
			t.Fatal(err)
		}
	}
	q := func(depth int) map[string]any {
		return map[string]any{"kind": "queue", "database_name": "Sales", "schema_name": "dbo", "queue_name": "OrderQueue", "object_id": 11,
			"is_receive_enabled": true, "message_count": depth}
	}
	counter := func(v int) map[string]any {
		return map[string]any{"kind": "counter", "object": "Broker Statistics", "instance_name": "", "counter_name": "SQL SEND Total", "cntr_value": v}
	}
	ep := map[string]any{"kind": "endpoint", "endpoint_name": "BrokerEndpoint", "state_desc": "STARTED", "port": 4022}
	imp(-10, map[string]any{"kind": "database", "database_name": "Sales"}, q(4), counter(100), ep,
		map[string]any{"kind": "transmission", "database_name": "Sales", "to_service_name": "//t", "transmission_status": "", "message_count": 2},
		map[string]any{"kind": "conversation", "database_name": "Sales", "state": "CO", "conversation_count": 3})
	imp(-5, map[string]any{"kind": "database", "database_name": "Sales"}, q(1), counter(400), ep,
		map[string]any{"kind": "transmission", "database_name": "Sales", "to_service_name": "//t", "transmission_status": "", "message_count": 2},
		map[string]any{"kind": "conversation", "database_name": "Sales", "state": "CO", "conversation_count": 3})
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	get := func(part string) []map[string]any {
		t.Helper()
		v := url.Values{"instance": {fmt.Sprint(id)}, "db": {"Sales"}, "part": {part},
			"from": {now.Add(-time.Hour).Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}}
		rec := httptest.NewRecorder()
		s.MSSQLChecks(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/checks?"+v.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("part=%s: %d %s", part, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[part]; tb != nil {
			for _, r := range tb.Rows {
				x := map[string]any{}
				for i, c := range tb.Columns {
					x[c] = r[i]
				}
				out = append(out, x)
			}
		}
		return out
	}
	line := func(rows []map[string]any, keys ...string) string {
		var all []string
		for _, r := range rows {
			var f []string
			for _, k := range keys {
				f = append(f, fmt.Sprint(r[k]))
			}
			all = append(all, strings.Join(f, " "))
		}
		return strings.Join(all, " | ")
	}
	if got, want := line(get("broker_queues"), "schema_name", "queue_name", "message_count", "is_receive_enabled"), "dbo OrderQueue 1 true"; got != want {
		t.Errorf("broker_queues %q, want %q (as last read)", got, want)
	}
	if got, want := line(get("broker_depth"), "queue_name", "message_count"), "OrderQueue 4 | OrderQueue 1"; got != want {
		t.Errorf("broker_depth %q, want %q (the window's samples, oldest first)", got, want)
	}
	if got, want := line(get("broker_transmission"), "to_service_name", "message_count"), "//t 2"; got != want {
		t.Errorf("broker_transmission %q, want %q", got, want)
	}
	if got, want := line(get("broker_conversations"), "state", "conversation_count"), "CO 3"; got != want {
		t.Errorf("broker_conversations %q, want %q", got, want)
	}
	if got, want := line(get("broker_endpoint"), "endpoint_name", "state_desc", "port"), "BrokerEndpoint STARTED 4022"; got != want {
		t.Errorf("broker_endpoint %q, want %q", got, want)
	}
	// 300 sends in the 5 minutes between the two samples: 1 a second
	if got, want := line(get("broker_counters"), "counter_name", "per_sec"), "SQL SEND Total 1"; got != want {
		t.Errorf("broker_counters %q, want %q (the difference over the seconds between samples)", got, want)
	}
}

// TestServiceBrokerTabIsWired (P25 row 73): the database page's last tab is Service Broker (DBA Dash appends it last,
// web/src/mssql_db.ts), drawn from the parts above with the depth as a chart, and words when the database has none.
func TestServiceBrokerTabIsWired(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, w := range []string{"['tuning', 'Tuning Recommendations'], ['servicebroker', 'Service Broker']", "case 'servicebroker':",
		"part('broker_queues')", "part('broker_depth', true)", "part('broker_transmission')", "part('broker_conversations')", "part('broker_endpoint')",
		"part('broker_counters', true)", "lineChart(", "mssql_service_broker"} {
		if !strings.Contains(src, w) {
			t.Errorf("mssql_db.ts has no %s", w)
		}
	}
}
