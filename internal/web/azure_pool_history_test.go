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

// TestAzurePoolHistoryOnAStore (P25 task 9b: DBA Dash's Pool history): on a migrated repository
// (PGVIGIL_REPO_TEST_DSN, skipped without it) /api/azuredb/summary part=pool_history lists each change of an elastic
// pool's DTU or storage limit once - however many of its databases keep a copy of its periods (0395), the copies'
// differing first starts no change - with the old and the new limits and when it changed; never the CPU limit
// (Microsoft: informational, not supported). part=pool_history_state says per pool of the scope when one of its
// databases last read master's view, or the skip's words (no dbmanager, no master) - the page's words when nothing
// was read. Both follow the scope and task 7's node cut.
func TestAzurePoolHistoryOnAStore(t *testing.T) {
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
	sfx := time.Now().UnixNano() % 1000000000
	tag := fmt.Sprintf("azph:%d", sfx)
	server := fmt.Sprintf("srvp-%d", sfx)
	ids := map[string]int{}
	var all []int
	for _, n := range []string{"a", "b", "c", "d"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, ARRAY[$2]::text[], 'sqlserver')`,
			fmt.Sprintf("azph-%s-%d", n, sfx), tag).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
		all = append(all, id)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, all); err != nil {
			t.Error(err)
		}
	}()
	exec := func(q string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	now := time.Now().UTC().Truncate(time.Minute)
	h := func(n int) time.Time { return now.Add(time.Duration(n) * time.Hour) }
	exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $4, 'pool1', $5), ($2, $4, 'pool1', $5), ($3, $4, 'pool2', $5),
	      ($6, $4, 'pool3', $5)`, ids["a"], ids["b"], ids["c"], server, now, ids["d"])
	// a and b keep their copies of pool1's periods (b first read an hour later: its first period starts later), the
	// CPU limit changed once on its own (informational: no change of the pool's limits)
	for _, x := range []struct {
		id    int
		first int
	}{{ids["a"], -300}, {ids["b"], -299}} {
		exec(`INSERT INTO pgvigil.mssql_pool_limit_history (instance_id, server, pool, valid_from, valid_to, dtu_limit, storage_limit_mb, cpu_limit)
		      VALUES ($1, $2, 'pool1', $3, $4, 50, 5120, NULL), ($1, $2, 'pool1', $4, $5, 100, 10240, NULL), ($1, $2, 'pool1', $5, $6, 100, 10240, 2.00)`,
			x.id, server, h(x.first), h(-100), h(-50), h(-1))
	}
	exec(`INSERT INTO pgvigil.mssql_pool_limit_read (instance_id, server, pool, read_at, state) VALUES ($1, $2, 'pool1', $3, 'read')`, ids["a"], server, h(-1))
	// d read pool3 until 30 hours ago; its runs since are skipped (dbmanager taken away: review t11-1 SHOULD 1)
	exec(`INSERT INTO pgvigil.mssql_pool_limit_read (instance_id, server, pool, read_at, state) VALUES ($1, $2, 'pool3', $3, 'read')`, ids["d"], server, h(-30))
	exec(`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status, note) VALUES ($1, 'mssql_pool_limits', $2, 'skipped', $3)`,
		ids["d"], h(-1), "Pool history is not read: the login is not a member of dbmanager in the logical server's master - an opt-in")
	// c's read was skipped: no dbmanager
	exec(`INSERT INTO pgvigil.collection_dates (instance_id, collection, snapshot_at, status, note) VALUES ($1, 'mssql_pool_limits', $2, 'skipped', $3)`,
		ids["c"], h(-1), "Pool history is not read: the login is not a member of dbmanager in the logical server's master - an opt-in")

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	call := func(extra url.Values) map[string]*table {
		t.Helper()
		q := url.Values{"from": {h(-2).Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}, "tag": {tag}}
		for k, v := range extra {
			q[k] = v
		}
		rec := httptest.NewRecorder()
		s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s: %d %s", q.Encode(), rec.Code, rec.Body.String())
		}
		raw := map[string]*table{}
		if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
			t.Fatal(err)
		}
		return raw
	}
	rows := func(tb *table) []map[string]any {
		var out []map[string]any
		if tb == nil {
			return nil
		}
		for _, r := range tb.Rows {
			m := map[string]any{}
			for i, c := range tb.Columns {
				m[c] = r[i]
			}
			out = append(out, m)
		}
		return out
	}
	got := call(nil)
	hist := rows(got["pool_history"])
	if len(hist) != 1 {
		t.Fatalf("pool_history: %v, want pool1's one change (two copies, one change; the CPU limit's own change none)", hist)
	}
	c := hist[0]
	if fmt.Sprint(c["server"] == server, " ", c["pool"], " ", c["old_dtu_limit"], " ", c["new_dtu_limit"], " ", c["old_storage_limit_mb"], " ", c["new_storage_limit_mb"]) != "true pool1 50 100 5120 10240" {
		t.Errorf("the change: %v, want pool1 50 -> 100 DTUs, 5120 -> 10240 MB", c)
	}
	if at, _ := time.Parse(time.RFC3339, fmt.Sprint(c["changed_at"])); !at.Equal(h(-100)) {
		t.Errorf("changed at %v, want %v", c["changed_at"], h(-100))
	}
	if tb := got["pool_history"]; tb != nil {
		for _, col := range tb.Columns {
			if strings.Contains(col, "cpu") {
				t.Errorf("pool_history has a CPU column %q (Microsoft: informational, not supported)", col)
			}
		}
	}
	state := map[string]map[string]any{}
	for _, r := range rows(got["pool_history_state"]) {
		state[fmt.Sprint(r["pool"])] = r
	}
	if p1 := state["pool1"]; p1 == nil || p1["last_read"] == nil || p1["skip_note"] != nil {
		t.Errorf("pool1's state %v: want its last read and no skip", p1)
	}
	if p2 := state["pool2"]; p2 == nil || p2["last_read"] != nil || !strings.Contains(fmt.Sprint(p2["skip_note"]), "dbmanager") {
		t.Errorf("pool2's state %v: want no read and the skip's words", p2)
	}
	// pool3: read until 30 hours ago, skipped since - no current read, the read's time and the skip's words
	if p3 := state["pool3"]; p3 == nil || p3["last_read"] != nil || p3["read_until"] == nil || !strings.Contains(fmt.Sprint(p3["skip_note"]), "dbmanager") {
		t.Errorf("pool3's state %v: want no current read, read_until its old read, and the skip's words", p3)
	}
	// the node: pool2 of the server - no change, its state alone
	n := call(url.Values{"server": {server}, "pool": {"pool2"}})
	if h2 := rows(n["pool_history"]); len(h2) != 0 {
		t.Errorf("server=&pool=pool2: changes %v, want none", h2)
	}
	if st := rows(n["pool_history_state"]); len(st) != 1 || st[0]["pool"] != "pool2" {
		t.Errorf("server=&pool=pool2: state %v, want pool2's alone", st)
	}
	// another tag: nothing
	o := call(url.Values{"tag": {"azph:none"}})
	if len(rows(o["pool_history"])) != 0 || len(rows(o["pool_history_state"])) != 0 {
		t.Errorf("another tag: %v %v, want nothing", rows(o["pool_history"]), rows(o["pool_history_state"]))
	}
}
