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

// TestAzurePoolHistoryAcrossAGap (P25 task 9b, the review t11-1 SHOULD 3, NIT 5 and NIT 9): on a store
// (PGVIGIL_REPO_TEST_DSN, skipped without it) part=pool_history lists each change of a pool's limits once and at its
// time even where a database's reads stopped for more than master's 14 days. A copy whose reads had a gap holds the
// change at the first period it read after the gap (its period before ends earlier): that change is known only as
// 'between the end of the period before and that start' (changed_after) - left out where another copy of the pool
// holds the same change inside the gap, shown with changed_after where none does. A database's copy of a pool counts
// only while the database is in that pool: one now in another pool (its member row) or one that left the pool (its
// governance row newer than its member row and in no pool) lists none of it.
func TestAzurePoolHistoryAcrossAGap(t *testing.T) {
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
	tag, server := fmt.Sprintf("azgap:%d", sfx), fmt.Sprintf("srvg-%d", sfx)
	ids := map[string]int{}
	var all []int
	for _, n := range []string{"x", "y", "z", "w", "v"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, ARRAY[$2]::text[], 'sqlserver')`,
			fmt.Sprintf("azgap-%s-%d", n, sfx), tag).Scan(&id); err != nil {
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
	// x, y in pool1; z in pool2; w in pool2 now (it keeps an old copy of pool1); v left pool1 for a single tier (its
	// member row two days old, its governance row an hour old and in no pool)
	exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $6, 'pool1', $7), ($2, $6, 'pool1', $7), ($3, $6, 'pool2', $7),
	      ($4, $6, 'pool2', $7), ($5, $6, 'pool1', $8)`, ids["x"], ids["y"], ids["z"], ids["w"], ids["v"], server, now, h(-48))
	exec(`INSERT INTO pgvigil.mssql_azuredb_governance (instance_id, snapshot_at, since, edition, service_objective, pool, gov)
	      VALUES ($1, $2, $2, 'Standard', 'S0', NULL, '{}'::jsonb)`, ids["v"], h(-1))
	period := func(id int, pl string, from, to time.Time, dtu, mb int) {
		t.Helper()
		exec(`INSERT INTO pgvigil.mssql_pool_limit_history (instance_id, server, pool, valid_from, valid_to, dtu_limit, storage_limit_mb, cpu_limit)
		      VALUES ($1, $2, $3, $4, $5, $6, $7, NULL)`, id, server, pl, from, to, dtu, mb)
	}
	period(ids["x"], "pool1", h(-300), h(-100), 50, 5120) // x read through the change at h(-100)
	period(ids["x"], "pool1", h(-100), h(-1), 100, 10240)
	period(ids["y"], "pool1", h(-300), h(-110), 50, 5120) // y's reads stopped at h(-110) and came back at h(-90)
	period(ids["y"], "pool1", h(-90), h(-1), 100, 10240)
	period(ids["z"], "pool2", h(-300), h(-200), 50, 5120) // z alone in pool2, its reads stopped at h(-200), back at h(-150)
	period(ids["z"], "pool2", h(-150), h(-1), 100, 10240)
	period(ids["w"], "pool1", h(-300), h(-60), 50, 5120) // w's old copy of pool1 (it is in pool2 now)
	period(ids["w"], "pool1", h(-60), h(-50), 200, 10240)
	period(ids["v"], "pool1", h(-300), h(-70), 50, 5120) // v left pool1
	period(ids["v"], "pool1", h(-70), h(-49), 300, 10240)

	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	q := url.Values{"from": {h(-2).Format(time.RFC3339)}, "to": {now.Format(time.RFC3339)}, "tag": {tag}}
	rec := httptest.NewRecorder()
	s.AzureDBSummary(rec, httptest.NewRequest(http.MethodGet, "/api/azuredb/summary?"+q.Encode(), nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("%d %s", rec.Code, rec.Body.String())
	}
	raw := map[string]*table{}
	if err := json.Unmarshal(rec.Body.Bytes(), &raw); err != nil {
		t.Fatal(err)
	}
	tb := raw["pool_history"]
	if tb == nil {
		t.Fatal("no pool_history part")
	}
	at := func(v any) string {
		if v == nil {
			return "-"
		}
		x, err := time.Parse(time.RFC3339, fmt.Sprint(v))
		if err != nil {
			return fmt.Sprint(v)
		}
		return fmt.Sprintf("%+.0fh", x.Sub(now).Hours())
	}
	var got []string
	for _, r := range tb.Rows {
		m := map[string]any{}
		for i, c := range tb.Columns {
			m[c] = r[i]
		}
		got = append(got, fmt.Sprintf("%v %v->%v %s after %s", m["pool"], m["old_dtu_limit"], m["new_dtu_limit"], at(m["changed_at"]), at(m["changed_after"])))
	}
	want := []string{"pool1 50->100 -100h after -", "pool2 50->100 -150h after -200h"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("pool_history:\n got %v\nwant %v (pool1's change once at its time, y's gap copy left out; pool2's known only between -200h and -150h; w's and v's copies of pool1 listed nowhere)", got, want)
	}
}
