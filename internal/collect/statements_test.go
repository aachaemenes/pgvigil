package collect

import (
	"context"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/repo"
)

// TestStatementsDuplicateKeyImport: a statements payload that names one (dbid, userid, queryid, toplevel)
// twice (two readings of pg_stat_statements while the counters moved; the collector now reads the view
// once, and the repository guards against any client anyway: migration 0017) imports whole, the reading
// with the most calls is kept, and the next cycle's delta counts from it. PGVIGIL_REPO_DSN names a
// throwaway repository; skipped without it.
func TestStatementsDuplicateKeyImport(t *testing.T) {
	dsn := os.Getenv("PGVIGIL_REPO_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_DSN not set")
	}
	ctx := context.Background()
	r, err := repo.Open(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	name := "stmt-dup-" + time.Now().UTC().Format("150405.000")
	id, err := r.EnsureInstance(ctx, name, "onprem", "fixture", 160000, false, []string{"fixture"})
	if err != nil {
		t.Fatal(err)
	}
	stmt := func(calls int64, ms float64) map[string]any {
		return map[string]any{
			"kind": "stmt", "dbid": 1, "datname": "d", "userid": 1, "usename": "u", "queryid": 434343, "toplevel": true,
			"calls": calls, "total_exec_ms": ms, "rows": 1,
			"shared_blks_hit": 0, "shared_blks_read": 0, "shared_blks_dirtied": 0, "shared_blks_written": 0,
			"temp_blks_read": 0, "temp_blks_written": 0, "blk_read_ms": 0, "blk_write_ms": 0,
			"temp_read_ms": 0, "temp_write_ms": 0, "wal_bytes": 0, "query": "fixture-dup",
		}
	}
	info := map[string]any{"kind": "info", "dealloc": 0, "stats_reset": "2026-01-01T00:00:00Z"}
	at := time.Now().UTC().Add(-2 * time.Minute)
	if err := r.Import(ctx, id, "statements", at, []map[string]any{stmt(50, 5), stmt(60, 6), info}); err != nil {
		t.Fatalf("a payload naming one statement twice did not import: %v", err)
	}
	if err := r.Import(ctx, id, "statements", at.Add(time.Minute), []map[string]any{stmt(70, 7), stmt(65, 6.5), info}); err != nil {
		t.Fatalf("the second duplicate payload did not import: %v", err)
	}
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(ctx) }()
	var cur int64
	if err := conn.QueryRow(ctx, `SELECT calls FROM pgvigil.statements_current WHERE instance_id = $1 AND queryid = 434343`, id).Scan(&cur); err != nil {
		t.Fatal(err)
	}
	if cur != 70 {
		t.Errorf("statements_current calls %d, want 70 (the reading with the most calls of the second payload)", cur)
	}
	var deltas string
	if err := conn.QueryRow(ctx, `SELECT string_agg(calls || '/' || reset, ' ' ORDER BY snapshot_at) FROM pgvigil.statements_delta WHERE instance_id = $1 AND queryid = 434343`, id).Scan(&deltas); err != nil {
		t.Fatal(err)
	}
	if deltas != "10/false" {
		t.Errorf("statements_delta %q, want one row 10/false (70 of the second payload minus 60 kept from the first)", deltas)
	}
}
