package repo

import (
	"encoding/json"
	"testing"
	"time"
)

// funcImp imports one mssql_funcstats read: its state row names the kinds the read held.
func (s *spreadStore) funcImp(at time.Time, kinds []string, rows ...map[string]any) {
	s.t.Helper()
	state := map[string]any{"kind": "state", "server_utc": at.UTC().Format(time.RFC3339), "server_start": "2026-01-01T00:00:00Z",
		"server_local": localOf(at), "capped": false, "kinds": kinds}
	b, err := json.Marshal(append([]map[string]any{state}, rows...))
	if err != nil {
		s.t.Fatal(err)
	}
	if _, err := s.pool.Exec(s.ctx, `SELECT pgvigil.import_mssql_funcstats($1, $2, $3::jsonb)`, s.id, at, string(b)); err != nil {
		s.t.Fatalf("import_mssql_funcstats at %s: %v", at.Format(time.RFC3339), err)
	}
}

// fn is one 'function' or 'trigger' row: a plan's counters since it was cached, with its extremes (lo / hi CPU).
func fn(kind, handle string, object int64, cached time.Time, execs, cpu int64, spills any, lo, hi int64) map[string]any {
	return map[string]any{"kind": kind, "plan_handle": handle, "cached_time": localOf(cached), "database_id": 5, "object_id": object,
		"database_name": "appdb", "schema_name": "dbo", "object_name": "o" + handle[len(handle)-2:], "type_desc": "SQL_SCALAR_FUNCTION",
		"execution_count": execs, "worker_us": cpu, "elapsed_us": cpu, "logical_reads": execs, "physical_reads": 0, "logical_writes": 0,
		"spills": spills, "min_worker_us": lo, "max_worker_us": hi, "min_elapsed_us": lo, "max_elapsed_us": hi,
		"min_logical_reads": 1, "max_logical_reads": 1, "min_physical_reads": 0, "max_physical_reads": 0,
		"min_logical_writes": 0, "max_logical_writes": 0, "min_spills": nil, "max_spills": nil}
}

// The functions' and triggers' intervals on a store (0343): the first read sets the counters; the next stores what
// each object added, kind by kind, with the extremes of the plans that ran and the functions' spills NULL (their
// view has no such column); a DDL trigger's scope as the collector named it; a read that did not hold one kind's
// view leaves that kind's counters as they were, so the read after it takes a difference, not the whole count.
func TestFuncStatsOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	now := time.Now().UTC().Truncate(time.Second)
	at := func(minAgo int) time.Time { return now.Add(-time.Duration(minAgo) * time.Minute) }
	old := at(600)
	both := []string{"function", "trigger"}
	row := func(kind string, minAgo int) string {
		t.Helper()
		return s.vals(`SELECT executions, cpu_us, spills, min_cpu_us, max_cpu_us, trigger_scope
		                 FROM pgvigil.mssql_func_sample WHERE instance_id = $1 AND snapshot_at = $2 AND kind = $3 ORDER BY database_id, object_id`, s.id, at(minAgo), kind)
	}
	ddl := func(execs, cpu int64) map[string]any {
		r := fn("trigger", "0x07DD", 900, old, execs, cpu, int64(0), 30, 90)
		r["database_id"], r["object_name"], r["trigger_scope"], r["type_desc"] = 1, "srv_ddl", "server", "SQL_TRIGGER"
		return r
	}
	s.funcImp(at(20), both, fn("function", "0x06A1", 100, old, 10, 1000, nil, 50, 300), ddl(2, 100))
	if got := s.vals(`SELECT count(*) FROM pgvigil.mssql_func_sample WHERE instance_id = $1`, s.id); got != "0" {
		t.Fatalf("the first read stored %s samples", got)
	}
	s.funcImp(at(15), both, fn("function", "0x06A1", 100, old, 14, 1800, nil, 50, 400), ddl(3, 160),
		fn("trigger", "0x07B2", 200, at(16), 5, 500, int64(4), 80, 120))
	if got, want := row("function", 15), "4 800 NULL 50 400 NULL"; got != want {
		t.Errorf("the function's interval:\n got %s\nwant %s", got, want)
	}
	if got, want := row("trigger", 15), "1 60 0 30 90 server | 5 500 4 80 120 NULL"; got != want {
		t.Errorf("the triggers' interval (the DDL trigger by difference, the new DML trigger whole):\n got %s\nwant %s", got, want)
	}
	if got, want := s.vals(`SELECT functions, triggers FROM pgvigil.mssql_func_read WHERE instance_id = $1 AND snapshot_at = $2`, s.id, at(15)), "1 2"; got != want {
		t.Errorf("the read's counts: got %s, want %s", got, want)
	}
	// a read without the triggers' view: the function's interval stored, the triggers' last counters kept
	s.funcImp(at(10), []string{"function"}, fn("function", "0x06A1", 100, old, 16, 2000, nil, 50, 400))
	if got := s.vals(`SELECT count(*) FROM pgvigil.mssql_func_last WHERE instance_id = $1 AND kind = 'trigger'`, s.id); got != "2" {
		t.Errorf("a read without the triggers' view left %s trigger plans, want 2", got)
	}
	s.funcImp(at(5), both, fn("function", "0x06A1", 100, old, 16, 2000, nil, 50, 400), ddl(4, 200),
		fn("trigger", "0x07B2", 200, at(16), 6, 600, int64(4), 80, 120))
	if got, want := row("trigger", 5), "1 40 0 30 90 server | 1 100 0 80 120 NULL"; got != want {
		t.Errorf("after a read without the triggers' view, a difference:\n got %s\nwant %s", got, want)
	}
	if got := row("function", 5); got != "" {
		t.Errorf("an idle function stored a sample: %s", got)
	}
}

// Inlineability (0343's mssql_func_inline): the databases a read asked replace their rows; a database not asked
// keeps its own; the purge drops the rows of an instance not read within the window.
func TestFuncInlineOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	now := time.Now().UTC().Truncate(time.Second)
	inl := func(db, object int64, ok, on bool) map[string]any {
		return map[string]any{"kind": "inline", "database_id": db, "object_id": object, "is_inlineable": ok, "inline_type": on}
	}
	asked := func(db int64) map[string]any { return map[string]any{"kind": "inline_read", "database_id": db} }
	s.funcImp(now.Add(-10*time.Minute), []string{"function"}, asked(5), inl(5, 100, true, true), inl(5, 101, false, false), asked(6), inl(6, 200, true, false))
	s.funcImp(now.Add(-5*time.Minute), []string{"function"}, asked(5), inl(5, 101, true, false))
	if got, want := s.vals(`SELECT database_id, object_id, is_inlineable, inline_type FROM pgvigil.mssql_func_inline WHERE instance_id = $1 ORDER BY 1, 2`, s.id),
		"5 101 true false | 6 200 true false"; got != want {
		t.Errorf("the inline rows:\n got %s\nwant %s", got, want)
	}
	if _, err := s.pool.Exec(s.ctx, `UPDATE pgvigil.mssql_func_state SET snapshot_at = now() - interval '40 days' WHERE instance_id = $1;
	                                  UPDATE pgvigil.mssql_func_inline SET read_at = now() - interval '40 days' WHERE instance_id = $1`, s.id); err != nil {
		t.Fatal(err)
	}
	var n int64
	if err := s.pool.QueryRow(s.ctx, `SELECT pgvigil.mssql_func_purge(30)`).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if got := s.vals(`SELECT (SELECT count(*) FROM pgvigil.mssql_func_inline WHERE instance_id = $1) + (SELECT count(*) FROM pgvigil.mssql_func_state WHERE instance_id = $1)`, s.id); got != "0" || n < 3 {
		t.Errorf("the purge removed %d rows and left %s", n, got)
	}
}
