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

// TestBrokerQueueStatusD4a (control audit D4 a; DBA Dash's ServiceBrokerQueueInfo L71-145, its thresholds at the root
// defaults Script.PostDeployment1.sql L2188-2210 until D4 b's table: depth 10,000 a warning, the oldest message 15 /
// 60 minutes): part=broker_queues carries each queue's queue_status (1 Critical, 2 Warning, 4 OK - DBA Dash's
// numbers), its readers_status and its issues - a disabled queue, a missing activation procedure with messages, the
// oldest message at the critical age: Critical; a missing procedure without messages, activation off with messages,
// activation notified 10 minutes or more with nothing received, the depth or the age at the warning: Warning; a
// RETENTION queue's unread depth is not a status. The tab shows the status first and the issues.
func TestBrokerQueueStatusD4a(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"{ key: 'queue_status', label: 'status', fmt: brokerStatus }", "{ key: 'issues', wide: true }", "const brokerStatus ="} {
		if !strings.Contains(string(b), w) {
			t.Errorf("mssql_db.ts lacks %s", w)
		}
	}
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
		fmt.Sprintf("bqstat-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_broker_queue WHERE instance_id = $1`, `DELETE FROM pgvigil.instances WHERE instance_id = $1`} {
			if _, err := pool.Exec(context.Background(), q, id); err != nil {
				t.Error(err)
			}
		}
	}()
	at := time.Date(2026, 11, 17, 12, 0, 0, 0, time.UTC)
	type qrow struct {
		name                       string
		recv, act                  bool
		proc                       any // the activation procedure
		exists                     any // activation_procedure_exists
		msgs                       any
		monitor                    string
		activatedAgo, oldestAgo    time.Duration // 0: none
		retention                  bool
		maxReaders, activatedTasks int
	}
	for _, q := range []qrow{
		{name: "q_disabled", recv: false, msgs: int64(0)},
		{name: "q_proc_gone_msgs", recv: true, act: true, proc: "dbo.p", exists: false, msgs: int64(3)},
		{name: "q_proc_gone_empty", recv: true, act: true, proc: "dbo.p", exists: false, msgs: int64(0)},
		{name: "q_act_off_msgs", recv: true, act: false, proc: "dbo.p", exists: true, msgs: int64(2)},
		{name: "q_notified", recv: true, act: true, proc: "dbo.p", exists: true, msgs: int64(5), monitor: "NOTIFIED", activatedAgo: 12 * time.Minute},
		{name: "q_deep", recv: true, msgs: int64(12000), oldestAgo: time.Minute},
		{name: "q_old", recv: true, msgs: int64(4), oldestAgo: 70 * time.Minute},
		{name: "q_oldish", recv: true, msgs: int64(4), oldestAgo: 20 * time.Minute},
		{name: "q_retained", recv: true, retention: true},
		{name: "q_ok", recv: true, act: true, proc: "dbo.p", exists: true, msgs: int64(1), oldestAgo: time.Minute, maxReaders: 2, activatedTasks: 2},
	} {
		var mon, act, oldest any
		if q.monitor != "" {
			mon = q.monitor
		}
		if q.activatedAgo > 0 {
			act = at.Add(-q.activatedAgo)
		}
		if q.oldestAgo > 0 {
			oldest = at.Add(-q.oldestAgo)
		}
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_broker_queue (instance_id, database_name, schema_name, queue_name, is_receive_enabled, is_enqueue_enabled,
		        is_retention_enabled, is_activation_enabled, activation_procedure, activation_procedure_exists, max_readers, message_count, activated_tasks,
		        monitor_state, monitor_last_activated, oldest_message_at, first_seen, snapshot_at)
		      VALUES ($1, 'Sales', 'dbo', $2, $3, true, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $14)`,
			id, q.name, q.recv, q.retention, q.act, q.proc, q.exists, q.maxReaders, q.msgs, q.activatedTasks, mon, act, oldest, at); err != nil {
			t.Fatal(err)
		}
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	rec := httptest.NewRecorder()
	s.MSSQLChecks(rec, httptest.NewRequest(http.MethodGet, "/api/mssql/checks?"+url.Values{"instance": {fmt.Sprint(id)}, "part": {"broker_queues"}, "db": {"Sales"}}.Encode(), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("broker_queues: %d %s", rec.Code, rec.Body.String())
	}
	raw := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	if tb := raw["broker_queues"]; tb != nil {
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			got[fmt.Sprint(m["queue_name"])] = fmt.Sprint(m["queue_status"], " ", m["readers_status"], " ", m["issues"] != nil)
		}
	}
	for name, want := range map[string]string{
		"q_disabled": "1 4 true", "q_proc_gone_msgs": "1 4 true", "q_proc_gone_empty": "2 4 true", "q_act_off_msgs": "2 4 true", "q_notified": "2 4 true",
		"q_deep": "2 4 true", "q_old": "1 4 true", "q_oldish": "2 4 true", "q_retained": "4 4 false", "q_ok": "4 2 false",
	} {
		if got[name] != want {
			t.Errorf("%s: status / readers / issues %q, want %q", name, got[name], want)
		}
	}
}
