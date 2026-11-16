package web

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// TestProbeImportFoldOnAStore (the B24h-1 fold F3: the review of 60991f0e part a #1 and part b #6 / #7 / #9; a box row:
// PGVIGIL_REPO_TEST_DSN): import_collector_probe on a migrated repository, one transaction rolled back -
//   - an address a connection opened to (the beat's 'opened') is the host's last answer, probed or not (part a #1, the
//     lead's 12:4x (a): 'never answered' never stands for a server a connection reached);
//   - a probe row keeps its mode ('scheduled': a round of probe_every_minute, part b #7);
//   - a probe row older than 8 days goes at the next import (part b #9: no purge() until the join) - the trim reads from
//     the table's mark (TRIMMARK), so the transaction first clears the probe rows older than 7 days and sets the mark to
//     '-infinity' (a store with a committed mark would otherwise leave a row planted below it: the review of TRIMMARK
//     #3; no import writes one there);
//   - collector_target_host files a SQL Server named instance under its box ('mssql:sql01\a:0' -> 'sql01', part b #6) and
//     a bare IPv6 literal without its port (part a #4's SQL half).
func TestProbeImportFoldOnAStore(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	col := fmt.Sprintf("pf-%d", time.Now().UnixNano()%1000000000)
	now := time.Now().UTC().Truncate(time.Minute)
	if _, err := tx.Exec(ctx, `DELETE FROM pgvigil.collector_probe WHERE minute < now() - interval '7 days'`); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `DO $m$ BEGIN IF to_regclass('pgvigil.collector_trim_mark') IS NOT NULL THEN
	    UPDATE pgvigil.collector_trim_mark SET trimmed_to = '-infinity' WHERE tbl = 'collector_probe'; END IF; END $m$`); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_probe (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max)
	                           VALUES ($1, $2, 'old', '10.9.9.7:5432', 'tcp', 1, 1, 2, 2)`, now.Add(-9*24*time.Hour), col); err != nil {
		t.Fatalf("the old probe row: %v", err)
	}
	beat := fmt.Sprintf(`{"load": [], "opened": [{"host": "db1", "address": "10.9.9.9:5432", "at": %q}],
	  "probes": [{"host": "db2", "address": "10.9.9.8:5432", "method": "tcp", "at": %q, "sent": 1, "answered": 1, "ms_sum": 3, "ms_max": 3, "scheduled": true},
	             {"host": "db3", "address": "10.9.9.6:5432", "method": "tcp", "at": %q, "sent": 1, "answered": 0, "ms_sum": 0, "ms_max": 0, "scheduled": false}]}`,
		now.Format(time.RFC3339), now.Format(time.RFC3339), now.Format(time.RFC3339))
	if _, err := tx.Exec(ctx, `SELECT pgvigil.import_collector_probe($1, $2, $3::jsonb)`, col, now, beat); err != nil {
		t.Fatalf("import_collector_probe: %v", err)
	}
	var opened, sched, unsched, old string
	if err := tx.QueryRow(ctx, `SELECT coalesce((SELECT host || '|' || (last_answered IS NOT NULL)::text || '|' || last_method FROM pgvigil.collector_probe_host WHERE collector_id = $1 AND address = '10.9.9.9:5432'), 'no row'),
	         coalesce((SELECT scheduled::text FROM pgvigil.collector_probe WHERE collector_id = $1 AND address = '10.9.9.8:5432'), 'no row'),
	         coalesce((SELECT scheduled::text FROM pgvigil.collector_probe WHERE collector_id = $1 AND address = '10.9.9.6:5432'), 'no row'),
	         (SELECT count(*)::text FROM pgvigil.collector_probe WHERE collector_id = $1 AND address = '10.9.9.7:5432')`, col).Scan(&opened, &sched, &unsched, &old); err != nil {
		t.Fatalf("the reads: %v", err)
	}
	if opened != "db1|true|tcp" {
		t.Errorf("an opened connection's address: %q, want 'db1|true|tcp' (its last answer the opened time)", opened)
	}
	if sched != "true" || unsched != "false" {
		t.Errorf("the probe rows' mode: scheduled %q / %q, want true / false", sched, unsched)
	}
	if old != "0" {
		t.Errorf("a probe row 9 days old: %s left, want 0", old)
	}
	for in, want := range map[string]string{`mssql:sql01\a:0`: "sql01", `mssql:sql01.corp\INST2:0`: "sql01.corp", "postgres:2001:db8::1:5432": "2001:db8::1",
		"postgres:[2001:db8::1]:5432": "2001:db8::1", "postgres:db1:5432,db2:5433": "db1"} {
		var got string
		if err := tx.QueryRow(ctx, `SELECT pgvigil.collector_target_host($1)`, in).Scan(&got); err != nil || got != want {
			t.Errorf("collector_target_host(%q) = %q (%v), want %q", in, got, err, want)
		}
	}
}

// TestCollectorLoadProbeHourOnAStore (the review of B24h-1 part b #15): the Collector page reads an hour of probes, so
// it maps an instance to its probed host over the hour's load rows too - an instance whose collector last wrote 30
// minutes ago (outside collector_instance_hosts' 20) still shows the probe rounds the hour holds.
func TestCollectorLoadProbeHourOnAStore(t *testing.T) {
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
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	sfx := time.Now().UnixNano() % 1000000000
	var id int
	if err := tx.QueryRow(ctx, `INSERT INTO pgvigil.instances (name, platform) VALUES ($1, 'self-managed') RETURNING instance_id`,
		fmt.Sprintf("probehour-%d", sfx)).Scan(&id); err != nil {
		t.Fatal(err)
	}
	coll := fmt.Sprintf("probehour-%d", sfx)
	if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
		VALUES ($1, $1, 'linux', 'console', 'x', 1, now() - interval '2 hours', now() - interval '30 minutes')`, coll); err != nil {
		t.Fatal(err)
	}
	target := fmt.Sprintf("postgres:dbh-%d:5432", sfx)
	for m := 30; m <= 32; m++ {
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, target)
			VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, 1, 1, 1, 0, 0, $4)`, m, id, coll, target); err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO pgvigil.collector_probe (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max)
			VALUES (date_trunc('minute', now()) - make_interval(mins => $1), $2, $3, '10.9.3.1:5432', 'tcp', 1, 1, 4, 4)`, m, coll, fmt.Sprintf("dbh-%d", sfx)); err != nil {
			t.Fatal(err)
		}
	}
	var rounds int
	if err := tx.QueryRow(ctx, `SELECT coalesce(probe_rounds_1h, 0)::int FROM (`+sqlCollectorLoad+`) x`, id).Scan(&rounds); err != nil {
		t.Fatalf("the Collector page's load query: %v", err)
	}
	if rounds != 3 {
		t.Errorf("an instance last written 30 minutes ago: %d probe round(s) over the hour, want 3", rounds)
	}
}
