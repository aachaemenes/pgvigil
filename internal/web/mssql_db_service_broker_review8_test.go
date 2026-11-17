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

// TestServiceBrokerReview8TabOnAStore (review t11-8's fold, P25 row 73): /api/mssql/checks for the Service Broker tab -
//   - 3 / 4: part=broker_read gives the database's read state (when it was last read, and why not or what was left out);
//   - 12: part=broker_queues carries each queue's oldest_note;
//   - 6: the depth and the counters keep the window's NEWEST samples when the cap cuts (oldest first in the reply);
//   - 14: a counter that fell (a restart) gives no rate for that sample;
//   - 15: part=broker_counters without a database (the Checks page's empty db=) reads nothing.
func TestServiceBrokerReview8TabOnAStore(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	var id int
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("sbr8-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_broker_queue_sample WHERE instance_id = $1`, id)
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_broker_counter_sample WHERE instance_id = $1`, id)
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
	counter := func(v int) map[string]any {
		return map[string]any{"kind": "counter", "object": "Broker Statistics", "instance_name": "", "counter_name": "SQL SEND Total", "cntr_value": v}
	}
	queue := map[string]any{"kind": "queue", "database_name": "Sales", "schema_name": "dbo", "queue_name": "OrderQueue", "object_id": 11,
		"is_receive_enabled": true, "message_count": 1, "oldest_note": "the read of its oldest message was refused: SELECT on the queue"}
	imp(-10, map[string]any{"kind": "database", "database_name": "Sales", "note": "the queues' readers were not read: VIEW SERVER STATE"}, queue, counter(100))
	imp(-5, map[string]any{"kind": "database", "database_name": "Sales", "note": "the queues' readers were not read: VIEW SERVER STATE"}, queue, counter(400))
	imp(-1, map[string]any{"kind": "database", "database_name": "Sales", "note": "the queues' readers were not read: VIEW SERVER STATE"}, queue, counter(50))
	// 20,010 depth samples of one more queue in the window, the newest 100 ms before the window's end
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.mssql_broker_queue_sample (instance_id, snapshot_at, database_name, schema_name, queue_name, message_count, activated_tasks)
	                              SELECT $1, $2::timestamptz - g * interval '100 milliseconds', 'Sales', 'dbo', 'Big', g, 0 FROM generate_series(1, 20010) g`, id, now); err != nil {
		t.Fatal(err)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	get := func(part, db string) []map[string]any {
		t.Helper()
		v := url.Values{"instance": {fmt.Sprint(id)}, "db": {db}, "part": {part},
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
	if rd := get("broker_read", "Sales"); len(rd) != 1 || !strings.Contains(fmt.Sprint(rd[0]["note"]), "VIEW SERVER STATE") || rd[0]["read_at"] == nil {
		t.Errorf("broker_read %v, want Sales read with the readers' words", rd)
	}
	if qs := get("broker_queues", "Sales"); len(qs) != 1 || !strings.Contains(fmt.Sprint(qs[0]["oldest_note"]), "SELECT on the queue") {
		t.Errorf("broker_queues %v, want OrderQueue with its oldest_note", qs)
	}
	depth := get("broker_depth", "Sales")
	newest := ""
	for _, r := range depth {
		if r["queue_name"] == "Big" {
			newest = fmt.Sprint(r["message_count"])
		}
	}
	if newest != "1" {
		t.Errorf("broker_depth: Big's last sample in the reply is %q, want 1 (the newest: the cap keeps the newest samples)", newest)
	}
	var rates []string
	for _, r := range get("broker_counters", "Sales") {
		rates = append(rates, fmt.Sprint(r["per_sec"]))
	}
	if strings.Join(rates, " ") != "1" {
		t.Errorf("broker_counters' rates %q, want only 1 (the fall to 50 is a restart: no rate)", rates)
	}
	if got := get("broker_counters", ""); len(got) != 0 {
		t.Errorf("broker_counters without a database: %d row(s), want none", len(got))
	}
}

// TestServiceBrokerReview8TabIsWired (review t11-8's fold): the tab shows the database's read state (part broker_read),
// each queue's oldest_note in its oldest-message cell, and says when the depth or the counters were cut to the newest.
func TestServiceBrokerReview8TabIsWired(t *testing.T) {
	b, err := os.ReadFile("../../web/src/mssql_db.ts")
	if err != nil {
		t.Fatal(err)
	}
	src := string(b)
	for _, w := range []string{"part('broker_read')", "oldest_note", "the newest 20,000"} {
		if !strings.Contains(src, w) {
			t.Errorf("mssql_db.ts has no %s", w)
		}
	}
}
