package web

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestRetentionRowsOfTheHAJoinOnAStore: the Data Retention page reads its rows from the text of pgvigil.purge() and of
// the *_purge functions it calls, as the store holds them. On a migrated repository (PGVIGIL_REPO_TEST_DSN, skipped
// without it; a store migrated by this binary: an older 0190 is never run again) the HA join's tables read as the
// page says them: the five sample parents of 0142 and 0143 'monthly partitions', the role changes, the owner changes
// and the seeding rows 'rows older than the age' by their time column and judged against the age, and
// replication_hourly_purge among the functions purge() calls (0150's hours, kept by their own age).
func TestRetentionRowsOfTheHAJoinOnAStore(t *testing.T) {
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
	var main string
	if err := pool.QueryRow(ctx, `SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	   WHERE n.nspname = 'pgvigil' AND p.proname = 'purge' ORDER BY p.oid DESC LIMIT 1`).Scan(&main); err != nil {
		t.Fatalf("purge(): %v", err)
	}
	var called []string
	hours := false
	for _, m := range reCalled.FindAllStringSubmatch(main, -1) {
		called = append(called, m[1])
		hours = hours || m[1] == "replication_hourly_purge"
	}
	if !hours {
		t.Errorf("purge() does not call replication_hourly_purge(): it calls %v", called)
	}
	rows, err := pool.Query(ctx, sqlRetentionSource, called)
	if err != nil {
		t.Fatal(err)
	}
	var srcs []string
	for rows.Next() {
		var name, src string
		if err := rows.Scan(&name, &src); err != nil {
			t.Fatal(err)
		}
		srcs = append(srcs, src)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	rules := purgeRules(srcs)
	for _, p := range []string{"mssql_repl_sample", "mssql_ag_replica_sample", "mssql_ag_dbcounter_sample", "mssql_mirroring_sample", "mssql_logrestore_sample"} {
		if words, _, _, judged := retentionWords(rules[p]); words != "monthly partitions" || !judged {
			t.Errorf("%s: the page says %q (judged %v); want monthly partitions, judged", p, words, judged)
		}
	}
	for _, c := range [][2]string{{"mssql_mirroring_role_changes", "at"}, {"mssql_fci_owner_changes", "at"}, {"mssql_ag_seeding", "snapshot_at"}} {
		if words, column, _, judged := retentionWords(rules[c[0]]); words != "rows older than the age" || column != c[1] || !judged {
			t.Errorf("%s: the page says %q by %q (judged %v); want rows older than the age by %s, judged", c[0], words, column, judged, c[1])
		}
	}
}
