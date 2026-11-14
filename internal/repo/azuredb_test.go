package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it), 0145's Azure SQL Database rows (B2a):
//   - mssql_azuredb_resources: minutes stored once (a second read of a stored minute changes nothing), the bucket
//     arrays and figures as sent, a gap row kept, the cursor 'azdb_since' the newest minute's start in epoch seconds
//     and never moved back by an older read; mssql_azuredb_minute in purge()'s partition parents;
//   - mssql_azuredb_governance: the first read opens a history row and writes the Properties rows without a change
//     row; a read whose only difference is user_data_directory_space_usage_mb or a column outside DBA Dash's 54 opens
//     none; a DTU limit and a service objective change close the open row, open a new one and log both changes.
func TestAzureDBOnAStore(t *testing.T) {
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
	if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'azuresqldb', '12.0', 120000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("azdb-%d", time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
		if _, err := pool.Exec(context.Background(), `DELETE FROM pgvigil.instances WHERE instance_id = $1`, id); err != nil {
			t.Error(err)
		}
	}()
	imp := func(fn string, at time.Time, rows ...map[string]any) {
		t.Helper()
		p, _ := json.Marshal(rows)
		if _, err := pool.Exec(ctx, fmt.Sprintf(`SELECT pgvigil.import_%s($1, $2, $3::jsonb)`, fn), id, at, string(p)); err != nil {
			t.Fatal(err)
		}
	}
	cursor := func() *int64 {
		t.Helper()
		var n *int64
		if err := pool.QueryRow(ctx, `SELECT pgvigil.mssql_hadr_cursor($1, 'azdb_since')`, id).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if c := cursor(); c != nil {
		t.Fatalf("cursor before any read: %d, want NULL", *c)
	}

	base := time.Date(2026, 11, 14, 12, 0, 0, 0, time.UTC)
	minute := func(m int, cpu float64) map[string]any {
		return map[string]any{"kind": "minute", "minute": base.Add(time.Duration(m) * time.Minute).Format(time.RFC3339), "samples": 4,
			"avg_cpu_percent": cpu, "max_cpu_percent": 90.0, "avg_data_io_percent": 100.0 / 3, "max_data_io_percent": 100.0,
			"avg_log_write_percent": nil, "max_log_write_percent": nil, "dtu_limit": 5.0, "cpu_limit": nil, "replica_role": 0.0,
			"avg_dtu_percent": 60.0025, "max_dtu_percent": 100.0, "avg_dtu": 3.000125, "max_dtu": 5.0,
			"dtu_buckets": []int{0, 0, 1, 1, 0, 0, 0, 0, 0, 2}, "cpu_buckets": []int{1, 1, 0, 1, 0, 0, 0, 0, 0, 1},
			"data_buckets": []int{2, 0, 0, 0, 0, 0, 0, 0, 0, 1}, "log_buckets": []int{0, 0, 0, 0, 0, 0, 0, 0, 0, 0}}
	}
	imp("mssql_azuredb_resources", base.Add(2*time.Minute), minute(0, 35), minute(1, 36))
	imp("mssql_azuredb_resources", base.Add(3*time.Minute), minute(1, 99), minute(2, 37), // 12:01 again: the first stays
		map[string]any{"kind": "gap", "gap_from": base.Add(-time.Hour).Format(time.RFC3339), "gap_to": base.Format(time.RFC3339), "oldest_end": base.Add(-30 * time.Second).Format(time.RFC3339)})
	imp("mssql_azuredb_resources", base.Add(4*time.Minute), minute(0, 1)) // an older read: the cursor stays
	var n, gaps int
	var cpu1, data0, dtuAvg float64
	var buckets string
	if err := pool.QueryRow(ctx, `SELECT count(*), max(avg_cpu_percent) FILTER (WHERE snapshot_at = $2)::float8,
	     max(avg_data_io_percent) FILTER (WHERE snapshot_at = $3)::float8, max(avg_dtu_percent) FILTER (WHERE snapshot_at = $3)::float8,
	     max(dtu_buckets::text) FILTER (WHERE snapshot_at = $3),
	     (SELECT count(*) FROM pgvigil.mssql_azuredb_gap g WHERE g.instance_id = $1)
	   FROM pgvigil.mssql_azuredb_minute WHERE instance_id = $1`, id, base.Add(time.Minute), base).Scan(&n, &cpu1, &data0, &dtuAvg, &buckets, &gaps); err != nil {
		t.Fatal(err)
	}
	if n != 3 || cpu1 != 36 || data0 != 33.3333 || dtuAvg != 60.0025 || buckets != "{0,0,1,1,0,0,0,0,0,2}" || gaps != 1 {
		t.Errorf("minutes %d (want 3), 12:01 cpu %v (want 36: the first read's), 12:00 data %v (want 33.3333), dtu %v (want 60.0025), buckets %s, gaps %d (want 1)",
			n, cpu1, data0, dtuAvg, buckets, gaps)
	}
	if c := cursor(); c == nil || *c != base.Add(2*time.Minute).Unix() {
		t.Errorf("cursor %v, want 12:02's start %d (an older read never moves it back)", c, base.Add(2*time.Minute).Unix())
	}
	var inPurge bool
	if err := pool.QueryRow(ctx, `SELECT bool_or(prosrc LIKE '%''mssql_azuredb_minute''%') FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	   WHERE n.nspname = 'pgvigil' AND p.proname = 'purge'`).Scan(&inPurge); err != nil || !inPurge {
		t.Errorf("mssql_azuredb_minute in purge()'s parents: %v %v", inPurge, err)
	}

	// N2
	gov := func(so string, dtu any, usage int, other int) map[string]any {
		return map[string]any{"kind": "governance", "edition": "Basic", "service_objective": so, "max_size_bytes": 2147483648.0,
			"pool": nil, "pool_from": nil, "pool_note": nil,
			"gov": map[string]any{"database_id": 5.0, "slo_name": "SQLDB_" + so, "dtu_limit": dtu, "cpu_limit": nil, "max_sessions": 30000.0,
				"primary_group_max_workers": 30.0, "primary_max_log_rate": 2621440.0, "max_dop": 1.0,
				"user_data_directory_space_usage_mb": usage, "a_column_azure_added": other}}
	}
	t0 := base.Add(time.Hour)
	imp("mssql_azuredb_governance", t0, gov("Basic", 5, 10, 1))
	imp("mssql_azuredb_governance", t0.Add(time.Hour), gov("Basic", 5, 99, 2))                                                     // usage and an unknown column only
	imp("mssql_azuredb_governance", t0.Add(2*time.Hour), gov("S0", 10, 99, 2))                                                     // the tier changed
	imp("mssql_azuredb_governance", t0.Add(3*time.Hour), map[string]any{"kind": "collector_error", "source": "x", "message": "y"}) // nothing
	var hist, open, changes, props int
	var usage int64
	var since time.Time
	var dtuNow, logRate, soNow string
	if err := pool.QueryRow(ctx, `SELECT (SELECT count(*) FROM pgvigil.mssql_azuredb_governance_history h WHERE h.instance_id = $1),
	     (SELECT count(*) FROM pgvigil.mssql_azuredb_governance_history h WHERE h.instance_id = $1 AND h.valid_to = 'infinity' AND h.valid_from = $2),
	     (SELECT count(*) FROM pgvigil.mssql_property_change c WHERE c.instance_id = $1),
	     (SELECT count(*) FROM pgvigil.mssql_property p WHERE p.instance_id = $1 AND p.grp = 'Azure SQL Database'),
	     g.usage_mb, g.since,
	     (SELECT value FROM pgvigil.mssql_property p WHERE p.instance_id = $1 AND p.name = 'azure_dtu_limit'),
	     (SELECT value FROM pgvigil.mssql_property p WHERE p.instance_id = $1 AND p.name = 'azure_max_log_rate'),
	     (SELECT value FROM pgvigil.mssql_property p WHERE p.instance_id = $1 AND p.name = 'azure_service_objective')
	   FROM pgvigil.mssql_azuredb_governance g WHERE g.instance_id = $1`, id, t0.Add(2*time.Hour)).Scan(
		&hist, &open, &changes, &props, &usage, &since, &dtuNow, &logRate, &soNow); err != nil {
		t.Fatal(err)
	}
	if hist != 2 || open != 1 || changes != 2 || props != 11 || usage != 99 || !since.Equal(t0.Add(2*time.Hour)) || dtuNow != "10" || logRate != "2.50" || soNow != "S0" {
		t.Errorf("history %d (want 2), open from the change %d (want 1), changes %d (want 2: service objective, DTU limit), properties %d (want 11), usage %d (want 99), since %v, DTU %s, log rate %s MB/s (want 2.50), objective %s",
			hist, open, changes, props, usage, since, dtuNow, logRate, soNow)
	}
	var closedAt time.Time
	if err := pool.QueryRow(ctx, `SELECT valid_to FROM pgvigil.mssql_azuredb_governance_history WHERE instance_id = $1 AND valid_from = $2`, id, t0).Scan(&closedAt); err != nil || !closedAt.Equal(t0.Add(2*time.Hour)) {
		t.Errorf("the first tier's row closed at %v (%v), want the change's read", closedAt, err)
	}
}
