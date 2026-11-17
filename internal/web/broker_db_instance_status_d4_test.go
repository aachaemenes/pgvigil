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
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestBrokerDatabaseInstanceStatusD4a (control audit D4 a; DBA Dash's ServiceBrokerDatabaseInfo L109-120 and
// ServiceBrokerInstanceInfo L65-103, its root-default thresholds: the transmission queue's oldest message 15 / 60
// minutes, 100,000 open conversations a warning): part=broker_databases gives each database's transmission queue,
// conversations by state, activation tasks aborted in the newest hour of counter samples and database_status (the worst
// of the transmission age, the conversation count, error conversations and aborted activations; 4 when none); part=
// broker_instance gives the endpoint, the Broker Statistics' growth in that hour, the queues' and databases' worst and
// counts, endpoint_status (3 none, 2 not STARTED or failed logins), error_status (2 corrupted messages in the hour, 4
// traffic, else 3) and service_broker_status - the worst of the four, 3 with nothing to report - with its issues.
func TestBrokerDatabaseInstanceStatusD4a(t *testing.T) {
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
		fmt.Sprintf("bdbstat-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_broker_queue WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_broker_transmission WHERE instance_id = $1`,
			`DELETE FROM pgvigil.mssql_broker_conversation WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_broker_endpoint WHERE instance_id = $1`,
			`DELETE FROM pgvigil.mssql_broker_counter_sample WHERE instance_id = $1`, `DELETE FROM pgvigil.mssql_broker_read WHERE instance_id = $1`,
			`DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	at := time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_broker_counter_sample', $1)`, at)
	for _, db := range []string{"Sales", "HR", "Ledger", "Empty"} {
		exec(`INSERT INTO pgvigil.mssql_broker_read (instance_id, database_name, read_at, snapshot_at) VALUES ($1, $2, $3, $3)`, id, db, at)
	}
	// Sales: a message waiting 70 minutes to be sent (critical) and a disabled queue (critical)
	exec(`INSERT INTO pgvigil.mssql_broker_transmission (instance_id, database_name, to_service_name, transmission_status, message_count, oldest_enqueue_at, snapshot_at)
	      VALUES ($1, 'Sales', '//target', '', 3, $2, $3)`, id, at.Add(-70*time.Minute), at)
	exec(`INSERT INTO pgvigil.mssql_broker_queue (instance_id, database_name, schema_name, queue_name, is_receive_enabled, is_enqueue_enabled, message_count, first_seen, snapshot_at)
	      VALUES ($1, 'Sales', 'dbo', 'q1', false, true, 0, $2, $2)`, id, at)
	// HR: two conversations in error among five (warning)
	exec(`INSERT INTO pgvigil.mssql_broker_conversation (instance_id, database_name, state, conversation_count, snapshot_at)
	      VALUES ($1, 'HR', 'CO', 3, $2), ($1, 'HR', 'ER', 2, $2)`, id, at)
	// Ledger: activation tasks aborted in the hour (3 -> 5: warning); Broker Statistics: 2 corrupted messages and 10 sends in the hour
	for i, v := range []int64{3, 5} {
		ts := at.Add(time.Duration(i-1) * 30 * time.Minute)
		exec(`INSERT INTO pgvigil.mssql_broker_counter_sample (instance_id, snapshot_at, object, instance_name, counter_name, cntr_value)
		      VALUES ($1, $2, 'Broker Activation', 'Ledger', 'Tasks Aborted/sec', $3),
		             ($1, $2, 'Broker Statistics', '', 'Corrupted Messages Total', $4), ($1, $2, 'Broker Statistics', '', 'SQL SEND Total', $5)`,
			id, ts, v, 10+int64(i)*2, 100+int64(i)*10)
	}
	exec(`INSERT INTO pgvigil.mssql_broker_endpoint (instance_id, endpoint_name, state_desc, port, login_failed_count, snapshot_at)
	      VALUES ($1, 'BrokerEndpoint', 'STOPPED', 4022, 0, $2)`, id, at)
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(part string) []map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		s.MSSQLChecks(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/checks?"+url.Values{"instance": {fmt.Sprint(id)}, "part": {part}}.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", part, rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		var out []map[string]any
		if tb := raw[part]; tb != nil {
			for _, r := range tb.Rows {
				m := map[string]any{}
				for i, c := range tb.Columns {
					m[c] = r[i]
				}
				out = append(out, m)
			}
		}
		return out
	}
	dbs := map[string]string{}
	for _, r := range call("broker_databases") {
		dbs[fmt.Sprint(r["database_name"])] = fmt.Sprint(r["database_status"], " tq ", r["transmission_status"], " cv ", r["conversation_count"], "/", r["error_count"],
			" aborted ", r["tasks_aborted_1hr"])
	}
	for db, want := range map[string]string{"Sales": "1 tq 1 cv <nil>/<nil> aborted <nil>", "HR": "2 tq 4 cv 5/2 aborted <nil>",
		"Ledger": "2 tq 4 cv <nil>/<nil> aborted 2", "Empty": "4 tq 4 cv <nil>/<nil> aborted <nil>"} {
		if dbs[db] != want {
			t.Errorf("broker_databases %s: %q, want %q", db, dbs[db], want)
		}
	}
	in := call("broker_instance")
	if len(in) != 1 {
		t.Fatalf("broker_instance: %d rows, want 1", len(in))
	}
	r := in[0]
	if got := fmt.Sprint(r["endpoint_status"], " ", r["error_status"], " ", r["queue_status"], " ", r["database_status"], " ", r["service_broker_status"], " ",
		r["corrupted_messages_1hr"], " ", r["sends_1hr"], " ", r["issues"] != nil); got != "2 2 1 1 1 2 10 true" {
		t.Errorf("broker_instance: %s, want endpoint 2, error 2, queues 1, databases 1, overall 1, 2 corrupted, 10 sends, with issues", got)
	}
}
