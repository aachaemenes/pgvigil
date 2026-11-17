package web

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestMSSQLPoolFindingsOnAStore (Alerts row 30, refwalk-s3's F34; the lead's 11-17 13:42): DBA Dash's ElasticPoolSpace
// rule in its default form (Use Critical Status on, the allocated measure; ElasticPoolSpaceRule.cs L11-21) is the view
// pgvigil.mssql_pool_findings: an elastic pool whose newest minute's allocated storage is over the pool's warning or
// critical threshold (0128's mssql_pool_storage_status, DBA Dash's AzureDBElasticPoolStorageStatus; the default 0.8 /
// 0.9), ONE finding a pool - on the database instance that read that minute, not on each of its databases; an OK pool
// and a pool with no minute in 5 minutes (N/A) give none.
func TestMSSQLPoolFindingsOnAStore(t *testing.T) {
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
	server := fmt.Sprintf("pf-%d", sfx)
	ids := map[string]int{}
	for _, n := range []string{"a", "b", "c", "d"} {
		var id int
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("%s-%s", server, n)).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[n] = id
	}
	defer func() {
		_, _ = pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_pool_minute WHERE server = $1`, server)
		for _, id := range ids {
			if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
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
	now := time.Now().UTC().Truncate(time.Minute)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_pool_minute', $1)`, now)
	exec(`SELECT pgvigil.ensure_month_partition('mssql_pool_minute', $1)`, now.Add(-10*time.Minute))
	// p1: a and b in it, its newest minute 95 % allocated, read through b; p2: c, 50 %; p3: d, 99 % but 10 minutes old
	for _, m := range []struct {
		inst, pool string
		alloc      float64
		age        time.Duration
	}{{"a", "p1", 0, -1}, {"b", "p1", 95, time.Minute}, {"c", "p2", 50, time.Minute}, {"d", "p3", 99, 10 * time.Minute}} {
		exec(`INSERT INTO pgvigil.mssql_pool_member (instance_id, server, pool, seen_at) VALUES ($1, $2, $3, now())`, ids[m.inst], server, m.pool)
		if m.age < 0 {
			continue
		}
		exec(`INSERT INTO pgvigil.mssql_pool_minute (server, pool, snapshot_at, samples, avg_cpu_percent, max_cpu_percent, avg_edtu_percent, max_worker_percent,
		        allocated_storage_percent, used_storage_percent, instance_id, name_from) VALUES ($1, $2, $3, 4, 1, 1, 1, 1, $4, 40, $5, 'tag')`,
			server, m.pool, now.Add(-m.age), m.alloc, ids[m.inst])
	}
	rows, err := pool.Query(ctx, `SELECT instance_id, severity, check_name, object, detail FROM pgvigil.mssql_pool_findings WHERE object LIKE '%' || $1 || '%' ORDER BY object`, server)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var got []string
	for rows.Next() {
		var id int
		var sev, check, obj, detail string
		if err := rows.Scan(&id, &sev, &check, &obj, &detail); err != nil {
			t.Fatal(err)
		}
		got = append(got, fmt.Sprintf("%d %s %s | %s", id, sev, obj, detail))
		if !strings.Contains(detail, "95 %") || !strings.Contains(detail, "critical over 90 %") {
			t.Errorf("the finding's detail %q does not name 95 %% allocated and the critical threshold over 90 %%", detail)
		}
	}
	if len(got) != 1 || !strings.HasPrefix(got[0], fmt.Sprintf("%d critical pool p1 on %s", ids["b"], server)) {
		t.Errorf("mssql_pool_findings: %q, want one critical finding 'pool p1 on %s' on b (instance %d)", got, server, ids["b"])
	}
}
