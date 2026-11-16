package repo

import (
	"context"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestAzureDBHoursWiringOnAStore (B2a-N2's WIRING, the review's finding 6): on a migrated store (PGVIGIL_REPO_TEST_DSN,
// skipped without it) purge() itself drops an hours month of mssql_azuredb_hour older than its 730 days, the month in
// the run's partitions_dropped (a purge() that never calls mssql_azuredb_hour_purge keeps it: 'kept 730 days' false);
// purge runs with 36,500 days so nothing else of the store goes; and apply_roles() keeps 0167's writers from the
// reader while the readers' window function stays the reader's.
func TestAzureDBHoursWiringOnAStore(t *testing.T) {
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
	old := time.Now().UTC().AddDate(-3, 0, 0)
	name := "mssql_azuredb_hour_" + old.Format("200601")
	if _, err := pool.Exec(ctx, `SELECT pgvigil.mssql_azuredb_hour_partition($1)`, old); err != nil {
		t.Fatal(err)
	}
	defer func() { _, _ = pool.Exec(context.Background(), `DROP TABLE IF EXISTS pgvigil.`+name) }()
	if _, err := pool.Exec(ctx, `SELECT pgvigil.purge(36500)`); err != nil {
		t.Fatal(err)
	}
	var gone bool
	var dropped []string
	if err := pool.QueryRow(ctx, `SELECT to_regclass('pgvigil.' || $1) IS NULL,
	       (SELECT partitions_dropped FROM pgvigil.purge_runs ORDER BY started_at DESC LIMIT 1)`, name).Scan(&gone, &dropped); err != nil {
		t.Fatal(err)
	}
	if !gone || !slices.Contains(dropped, name) {
		t.Errorf("purge(): %s gone %v, in the run's partitions_dropped %v (want both)", name, gone, dropped)
	}
	for fn, want := range map[string]bool{
		"pgvigil.mssql_azuredb_hour_heal_one(int)": false, "pgvigil.mssql_azuredb_hour_failed(int, timestamptz, timestamptz, text)": false,
		"pgvigil.mssql_azuredb_hour_purge()": false, "pgvigil.mssql_azuredb_hour_partition(timestamptz)": false,
		"pgvigil.mssql_azuredb_hour_pending()": false, "pgvigil.mssql_azuredb_window(int[], timestamptz, timestamptz)": true,
		"pgvigil.mssql_azuredb_hour_built(int, timestamptz)": true,
	} {
		var may bool
		if err := pool.QueryRow(ctx, `SELECT has_function_privilege('pgvigil_reader', $1::regprocedure, 'EXECUTE')`, fn).Scan(&may); err != nil {
			t.Fatal(err)
		}
		if may != want {
			t.Errorf("pgvigil_reader may execute %s: %v, want %v", fn, may, want)
		}
	}
}
