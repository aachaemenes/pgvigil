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

// TestAzurePoolMembershipOnAStore (the review t11-2: BLOCKER 1, SHOULD 3, NIT 6, NIT 7; P25 tasks 7 and 8): on a store
// (PGVIGIL_REPO_TEST_DSN, skipped without it) a database's elastic pool is its pool member row's while that row is
// current - read before the database's governance row, or the governance row says ElasticPool - so a database that
// left the pool for a single tier (its member row stays behind; its newer governance row: S2, no pool) is in no pool
// on the Azure Summary and is not counted in the pool; the member row comes before the governance row's own words;
// one pool named in two letter cases (a tag's 'Pool1', a read's 'pool1') is one row of the Elastic Pool grid, its
// minutes together; and the pool page's summary weighs each minute by its samples, as its buckets and the grid do.
func TestAzurePoolMembershipOnAStore(t *testing.T) {
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
	tag, server := fmt.Sprintf("azmem:%d", sfx), fmt.Sprintf("srvm-%d", sfx)
	ids := map[string]int{}
	var all []int
	for _, n := range []string{"a", "b", "c", "d"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, ARRAY[$2]::text[], 'sqlserver')`,
			fmt.Sprintf("azmem-%s-%d", n, sfx), tag).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
		all = append(all, id)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`, server); err != nil {
			t.Error(err)
		}
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
	m := func(n int) time.Time { return now.Add(time.Duration(n) * time.Minute) }
	exec(`SELECT pgvigil.ensure_month_partition('mssql_pool_minute', $1)`, m(-30))
	// a and b read the pool as 'Pool1' (a's governance row names another server and pool: the member row comes first);
	// c reads it as 'pool1'; d was in it and left for S2 an hour ago (its member row two days old)
	exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $5, 'Pool1', $6), ($2, $5, 'Pool1', $6), ($3, $5, 'pool1', $6),
	      ($4, $5, 'pool1', $7)`, ids["a"], ids["b"], ids["c"], ids["d"], server, now, now.Add(-48*time.Hour))
	exec(`INSERT INTO pgvigil.mssql_azuredb_governance (instance_id, snapshot_at, since, edition, service_objective, pool, gov)
	      VALUES ($1, $3, $3, 'Basic', 'ElasticPool', 'poolX', '{"server_name": "other"}'::jsonb), ($2, $4, $4, 'Standard', 'S2', NULL, '{}'::jsonb)`,
		ids["a"], ids["d"], now.Add(-5*time.Minute), now.Add(-time.Hour))
	// the minutes: 'Pool1' two (4 samples CPU 20, 2 samples CPU 60), 'pool1' one (4 samples CPU 30)
	for _, x := range []struct {
		pl      string
		at      time.Time
		samples int
		cpu     float64
		inst    int
	}{{"Pool1", m(-20), 4, 20, ids["a"]}, {"Pool1", m(-19), 2, 60, ids["a"]}, {"pool1", m(-18), 4, 30, ids["c"]}} {
		exec(`INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, avg_edtu_percent, instance_id, name_from)
		      VALUES ($1, $2, $3, $4, $5::numeric, $5::numeric + 5, $5::numeric, $6, 'service objectives')`, server, x.pl, x.at, x.samples, x.cpu, x.inst)
	}
	s := &Server{pool: pool, log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	get := func(h func(http.ResponseWriter, *http.Request), path string, q url.Values, part string) []map[string]any {
		t.Helper()
		q.Set("from", m(-60).Format(time.RFC3339))
		q.Set("to", now.Format(time.RFC3339))
		q.Set("part", part)
		rec := httptest.NewRecorder()
		h(rec, httptest.NewRequest(http.MethodGet, path+"?"+q.Encode(), nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s %s: %d %s", path, q.Encode(), rec.Code, rec.Body.String())
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
	byID := map[string]map[string]any{}
	for _, r := range get(s.AzureDBSummary, "/api/azuredb/summary", url.Values{"tag": {tag}}, "databases") {
		for n, id := range ids {
			if fmt.Sprint(r["instance_id"]) == fmt.Sprint(id) {
				byID[n] = r
			}
		}
	}
	if a := byID["a"]; a == nil || a["pool"] != "Pool1" || a["server"] != server {
		t.Errorf("a: %v, want the member row's server and pool (Pool1 on %s), not its governance row's", a, server)
	}
	if d := byID["d"]; d == nil || d["pool"] != nil {
		t.Errorf("d: %v, want no pool (it left pool1 for S2: its governance row is newer than its member row)", d)
	}
	pools := get(s.AzureDBSummary, "/api/azuredb/summary", url.Values{"tag": {tag}}, "pools")
	if len(pools) != 1 || fmt.Sprint(pools[0]["databases"], " ", pools[0]["minutes"], " ", pools[0]["avg_cpu_percent"]) != "3 3 32" {
		t.Errorf("pools %v, want one row - 3 databases (a, b, c; not d), 3 minutes, CPU avg 32 weighed by samples", pools)
	}
	sum := get(s.MSSQLPool, "/api/mssql/pool", url.Values{"instance": {fmt.Sprint(ids["a"])}}, "summary")
	if len(sum) != 1 || fmt.Sprint(sum[0]["minutes"], " ", sum[0]["avg_cpu_percent"]) != "2 33.33" {
		t.Errorf("a's pool page summary %v, want 2 minutes, CPU avg 33.33 (weighed by samples: (20x4 + 60x2) / 6)", sum)
	}
}
