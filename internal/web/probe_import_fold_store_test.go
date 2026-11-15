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
//   - a probe row older than 8 days goes at the next import (part b #9: no purge() until the join);
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
