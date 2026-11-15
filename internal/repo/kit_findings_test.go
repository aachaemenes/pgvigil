package repo

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// KITWATCH K4.2 (F15, F16): pgvigil.kit_findings, a view of its own in the findings shape - 'sp_WhoIsActive
// unusable' (warning) on an instance whose newest mssql_requests runs are a streak of at least 5 partial runs over at
// least 5 minutes with the collector's fallback note AND a shape-class error (207 invalid column, 8144 / 8145 too many
// or unknown parameters, 213 the column count, 2812 no such procedure); a streak of any other error (a deadlock
// victim, a lock timeout) is an info 'sp_WhoIsActive failing'; a run that is not the fallback clears it; a shorter or
// briefer streak raises nothing. collector_findings (0121, another owner's, edited in place) is not redefined: 0139's
// arm still answers through it. On a migrated store (PGVIGIL_REPO_TEST_DSN, skipped without it).
func TestKitFindingsOnAStore(t *testing.T) {
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
	t.Cleanup(pool.Close)
	sfx := time.Now().UnixNano() % 1000000000
	ids := make([]int, 6)
	for i := range ids {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("kitfind-%d-%d", i, sfx)).Scan(&ids[i]); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		if _, err := pool.Exec(c, `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, ids); err != nil {
			t.Logf("cleanup: %v", err)
		}
	})
	logRow := func(inst int, ago time.Duration, status, note string) {
		t.Helper()
		if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
		                             VALUES ($1, 'mssql_requests', now() - $2::interval, $3, $4)`, inst, fmt.Sprintf("%d seconds", int(ago.Seconds())), status, note); err != nil {
			t.Fatal(err)
		}
	}
	// the collector's own note (mssql.go: '<source>: <message>'; requests.go's message with the error's number)
	fallback := func(msg string, num int) string {
		return fmt.Sprintf("sp_WhoIsActive: mssql: %s (error %d); the DMV read ran instead", msg, num)
	}
	streak := func(inst, n int, every time.Duration, note string) {
		for i := n; i >= 1; i-- {
			logRow(inst, time.Duration(i)*every, "partial", note)
		}
	}
	shape, deadlock := fallback("Invalid column name 'tempdb_current'.", 207), fallback("Transaction (Process ID 61) was deadlocked on lock resources with another process and has been chosen as the deadlock victim.", 1205)
	streak(ids[0], 6, time.Minute, shape)    // a shape-class streak: warning
	streak(ids[1], 4, time.Minute, shape)    // too few runs: none
	streak(ids[2], 6, time.Minute, deadlock) // another class: info
	streak(ids[3], 6, time.Minute, shape)    // then a good run: cleared
	logRow(ids[3], 10*time.Second, "ok", "") //
	streak(ids[4], 6, 20*time.Second, shape) // 6 runs inside 2 minutes: too brief, none
	if _, err := pool.Exec(ctx, `INSERT INTO pgvigil.collection_log (instance_id, collection, snapshot_at, status, note)
	                             VALUES ($1, 'job_stats_hourly', now() - interval '30 minutes', 'error',
	                                     'rollup failed for the mssql_job_runs hours 2026-11-14 10:00 to 2026-11-14 11:00 UTC (the runs are stored; the hours are rebuilt by the next import or purge): x')`, ids[5]); err != nil {
		t.Fatal(err)
	}
	got := func(inst int) string {
		t.Helper()
		var s string
		if err := pool.QueryRow(ctx, `SELECT coalesce(string_agg(format('%s|%s|%s', severity, setting, source), ', '), 'none') FROM pgvigil.kit_findings WHERE instance_id = $1`, inst).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	for _, c := range []struct {
		what string
		inst int
		want string
	}{
		{"a shape-class streak of 6 over 6 minutes", ids[0], "warning|sp_WhoIsActive unusable|pgvigil collector"},
		{"4 runs", ids[1], "none"},
		{"a deadlock-victim streak", ids[2], "info|sp_WhoIsActive failing|pgvigil collector"},
		{"a good run after the streak", ids[3], "none"},
		{"6 runs inside 2 minutes", ids[4], "none"},
	} {
		if g := got(c.inst); g != c.want {
			t.Errorf("%s: %s, want %s", c.what, g, c.want)
		}
	}
	var detail string
	if err := pool.QueryRow(ctx, `SELECT detail FROM pgvigil.kit_findings WHERE instance_id = $1`, ids[0]).Scan(&detail); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(detail, "tempdb_current") || !strings.Contains(detail, "207") {
		t.Errorf("the finding's detail %q does not carry the server's error", detail)
	}
	// 0121's view is the owner's: its 0139 arm still answers (this task never redefines collector_findings)
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.collector_findings WHERE instance_id = $1 AND setting = 'job statistics not rolled up'`, ids[5]).Scan(&n); err != nil || n != 1 {
		t.Errorf("collector_findings' 0139 arm: %d row(s) %v, want 1", n, err)
	}
}

// K4.3: import_mssql_kits keeps an instance's kits as last read (each read replaces the last), and
// pgvigil.kit_versions_fleet counts the instances per procedure and version - one line per tool version for the
// fleet, never a finding per instance (F14).
func TestKitVersionsOnAStore(t *testing.T) {
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
	t.Cleanup(pool.Close)
	sfx := time.Now().UnixNano() % 1000000000
	ids := make([]int, 2)
	for i := range ids {
		if err := pool.QueryRow(ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
			fmt.Sprintf("kitver-%d-%d", i, sfx)).Scan(&ids[i]); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		_, _ = pool.Exec(c, `DELETE FROM pgvigil.instances WHERE instance_id = ANY ($1)`, ids)
	})
	imp := func(id int, payload string) {
		t.Helper()
		if _, err := pool.Exec(ctx, `SELECT pgvigil.import_mssql_kits($1, now(), $2::jsonb)`, id, payload); err != nil {
			t.Fatal(err)
		}
	}
	proc := func(name, ver, date string) string {
		return fmt.Sprintf(`{"kind":"proc","database_name":"master","procedure_name":%q,"version":%q,"version_date":%q,"modify_date":"2026-11-01T00:00:00","readable":true}`, name, ver, date)
	}
	imp(ids[0], `[{"kind":"read"},`+proc("sp_Blitz", "8.34", "20260702")+`,`+proc("sp_WhoIsActive", "v2200.20260409", "20260409")+`]`)
	imp(ids[1], `[{"kind":"read"},`+proc("sp_Blitz", "8.35", "20261114")+`]`)
	imp(ids[0], `[{"kind":"read"},`+proc("sp_Blitz", "8.35", "20261114")+`]`) // the next read replaces the last
	var n int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.mssql_kit_versions WHERE instance_id = $1`, ids[0]).Scan(&n); err != nil || n != 1 {
		t.Errorf("after the second read: %d row(s) %v, want 1 (sp_WhoIsActive gone)", n, err)
	}
	// the fleet line counts every instance of the store holding that version (another test's rows included)
	var fleet, direct int
	if err := pool.QueryRow(ctx, `SELECT coalesce((SELECT instances FROM pgvigil.kit_versions_fleet WHERE procedure_name = 'sp_Blitz' AND version = '8.35'), 0),
	                                     (SELECT count(DISTINCT instance_id) FROM pgvigil.mssql_kit_versions WHERE procedure_name = 'sp_Blitz' AND version = '8.35')`).Scan(&fleet, &direct); err != nil {
		t.Fatal(err)
	}
	if fleet != direct || direct < 2 {
		t.Errorf("the fleet line for sp_Blitz 8.35: %d instance(s), the rows hold %d (want equal, at least this test's 2)", fleet, direct)
	}
}
