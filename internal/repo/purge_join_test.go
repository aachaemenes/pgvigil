package repo

import (
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestPurgeTakesTheJoinedRetentionOnAStore: 0151 (geo-replication and the provider replicas) and 0162 (the optional
// Extended Events captures) leave their retention to the join's purge() - their partition parents, their events and
// warning tables, the two hour tables' own purges. On a migrated store, a partition four months old in each of the
// four parents is gone after purge(30), and purge() names each table and hour purge it must reach (a store that is
// never purged of them grows without end).
func TestPurgeTakesTheJoinedRetentionOnAStore(t *testing.T) {
	ctx, r, _, _ := throwawayRepo(t)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	old := time.Now().UTC().AddDate(0, -4, 0)
	from := time.Date(old.Year(), old.Month(), 1, 0, 0, 0, 0, time.UTC)
	parents := []string{"cloud_replica_sample", "mssql_georepl_sample", "mssql_xe_waits", "mssql_xe_modules"}
	var made []string
	for _, p := range parents {
		name := p + "_" + from.Format("200601")
		if _, err := r.pool.Exec(ctx, `CREATE TABLE IF NOT EXISTS `+pgx.Identifier{"pgvigil", name}.Sanitize()+` PARTITION OF `+
			pgx.Identifier{"pgvigil", p}.Sanitize()+` FOR VALUES FROM ('`+from.Format(time.RFC3339)+`') TO ('`+from.AddDate(0, 1, 0).Format(time.RFC3339)+`')`); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		made = append(made, name)
	}
	if _, err := r.pool.Exec(ctx, `SELECT pgvigil.purge(30)`); err != nil {
		t.Fatalf("purge(30): %v", err)
	}
	for _, name := range made {
		var left bool
		if err := r.pool.QueryRow(ctx, `SELECT to_regclass('pgvigil.' || $1) IS NOT NULL`, name).Scan(&left); err != nil {
			t.Fatal(err)
		}
		if left {
			t.Errorf("%s (four months old) is still there after purge(30): purge() does not take its parent", name)
		}
	}
	var def string
	if err := r.pool.QueryRow(ctx, `SELECT pg_get_functiondef('pgvigil.purge(int)'::regprocedure)`).Scan(&def); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"pgvigil.mssql_georepl_events", "pgvigil.mssql_failover_group_events", "pgvigil.cloud_replica_events",
		"pgvigil.cloud_failover_events", "pgvigil.mssql_xe_warning_hours", "pgvigil.mssql_xe_warning_samples",
		"pgvigil.mssql_xe_warning_keys", "pgvigil.mssql_xe_warning_counts", "pgvigil.cloud_replica_hour_purge()", "pgvigil.mssql_georepl_hour_purge()"} {
		if !strings.Contains(def, want) {
			t.Errorf("purge() does not reach %s", want)
		}
	}
}

// TestPurgeReadsNoMonthFromAnOddHourChild: 0151's two hour tables are purged by hour_purge_0151, which purge() calls
// (the join's arm): a child whose name ends in six digits that are no month (a table named after an OID past 100,000)
// is left alone - never 22008 from parsing '_100017' as 1000-17, which would fail the whole purge (0167's fix,
// 86a9a924, in the same shape).
func TestPurgeReadsNoMonthFromAnOddHourChild(t *testing.T) {
	ctx, r, _, _ := throwawayRepo(t)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	var odd []string
	for _, p := range []string{"cloud_replica_hour", "mssql_georepl_hour"} {
		name := p + "_odd_100017"
		if _, err := r.pool.Exec(ctx, `CREATE TABLE `+pgx.Identifier{"pgvigil", name}.Sanitize()+` PARTITION OF `+
			pgx.Identifier{"pgvigil", p}.Sanitize()+` FOR VALUES FROM ('2201-01-01 00:00+00') TO ('2201-02-01 00:00+00')`); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		odd = append(odd, name)
	}
	for _, q := range []string{`SELECT pgvigil.cloud_replica_hour_purge()`, `SELECT pgvigil.mssql_georepl_hour_purge()`, `SELECT pgvigil.purge(30)`} {
		if _, err := r.pool.Exec(ctx, q); err != nil {
			t.Errorf("%s with children named %v (six digits, no month): %v", q, odd, err)
		}
	}
	for _, name := range odd {
		var left bool
		if err := r.pool.QueryRow(ctx, `SELECT to_regclass('pgvigil.' || $1) IS NOT NULL`, name).Scan(&left); err != nil {
			t.Fatal(err)
		}
		if !left {
			t.Errorf("%s was dropped: a name ending in no month", name)
		}
	}
}
