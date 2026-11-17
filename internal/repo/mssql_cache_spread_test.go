package repo

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// 0342 re-creates 0092's plan cache import and 0126's procedure import whole, each with D421's arms between the
// marker lines '-- [D421' and '-- D421]'. With the arms taken out, each function is the base's, character for
// character: an edit of either that the other does not carry fails here. The delta rule's mode (diff, whole, none)
// stands twice in each function, word for word: once in the base's statement, once in the arm that keeps the
// extremes of the plans that ran.
func TestImports0342AreTheBasePlusTheD421Arms(t *testing.T) {
	read := func(file string) string {
		t.Helper()
		b, err := migrations.ReadFile("sql/" + file)
		if err != nil {
			t.Fatal(err)
		}
		return string(b)
	}
	body := func(file, src, head string) string {
		t.Helper()
		i := strings.Index(src, head)
		if i < 0 {
			t.Fatalf("%s: no %s", file, head)
		}
		j := strings.Index(src[i:], "END $$;")
		if j < 0 {
			t.Fatalf("%s: %s has no end", file, head)
		}
		return src[i : i+j]
	}
	strip := func(fn string) (string, int) {
		t.Helper()
		var out []string
		in, arms := false, 0
		for _, l := range strings.Split(fn, "\n") {
			tr := strings.TrimSpace(l)
			switch {
			case strings.HasPrefix(tr, "-- [D421"):
				if in {
					t.Fatal("an arm opens inside an arm")
				}
				in = true
				arms++
			case tr == "-- D421]":
				if !in {
					t.Fatal("an arm closes that was not opened")
				}
				in = false
			case !in:
				out = append(out, l)
			}
		}
		if in {
			t.Fatal("an arm is not closed")
		}
		return strings.Join(out, "\n"), arms
	}
	const file = "0342_mssql_cache_spread.sql"
	src := read(file)
	if strings.Contains(src, "FUNCTION pgvigil.import_mssql_plancache(") {
		t.Error("0342 must leave 0126's wrapper import_mssql_plancache alone")
	}
	for _, c := range []struct {
		name, baseFile, baseHead, head string
		arms                           int
	}{
		{"the plan cache import", "0092_mssql_plancache_indexes.sql", "CREATE OR REPLACE FUNCTION pgvigil.import_mssql_plancache(",
			"CREATE OR REPLACE FUNCTION pgvigil.import_mssql_plancache_0092(", 4},
		{"the procedures' import", "0126_darling_queries.sql", "CREATE OR REPLACE FUNCTION pgvigil.import_mssql_procstats(",
			"CREATE OR REPLACE FUNCTION pgvigil.import_mssql_procstats(", 2},
	} {
		full := body(file, src, c.head)
		got, arms := strip(full)
		base := body(c.baseFile, read(c.baseFile), c.baseHead)
		want := strings.Replace(base, c.baseHead, c.head, 1)
		if arms != c.arms {
			t.Errorf("%s: %d arms, want %d", c.name, arms, c.arms)
		}
		if got != want {
			gl, wl := strings.Split(got, "\n"), strings.Split(want, "\n")
			for k := 0; k < len(gl) && k < len(wl); k++ {
				if gl[k] != wl[k] {
					t.Fatalf("%s differs from the base beyond the arms at its line %d:\n0342: %s\nbase: %s", c.name, k+1, gl[k], wl[k])
				}
			}
			t.Fatalf("%s has %d lines without its arms, the base %d", c.name, len(gl), len(wl))
		}
		i := strings.Index(base, "CROSS JOIN LATERAL (SELECT CASE WHEN l.instance_id IS NOT NULL")
		j := strings.Index(base, "END AS mode) g) d")
		if i < 0 || j < i {
			t.Fatalf("%s: the base's mode was not found", c.name)
		}
		if n := strings.Count(full, base[i:j+len("END AS mode) g) d")]); n != 2 {
			t.Errorf("%s holds the base's mode %d times, want 2 (the base's statement and the arm)", c.name, n)
		}
	}
}

type spreadStore struct {
	t    *testing.T
	ctx  context.Context
	pool *pgxpool.Pool
	id   int
}

// newSpreadStore: a migrated database of its own (throwawayRepo) with one SQL Server instance.
func newSpreadStore(t *testing.T) *spreadStore {
	t.Helper()
	ctx, r, pool, _ := throwawayRepo(t)
	if _, err := r.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	s := &spreadStore{t: t, ctx: ctx, pool: pool}
	s.id = s.instance("a")
	return s
}

func (s *spreadStore) instance(name string) int {
	s.t.Helper()
	var id int
	if err := s.pool.QueryRow(s.ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}', 'sqlserver')`, "spread-"+name).Scan(&id); err != nil {
		s.t.Fatal(err)
	}
	return id
}

func (s *spreadStore) imp(fn string, id int, at time.Time, rows ...map[string]any) {
	s.t.Helper()
	state := map[string]any{"kind": "state", "server_utc": at.UTC().Format(time.RFC3339), "server_start": "2026-01-01T00:00:00Z",
		"server_local": localOf(at), "capped": false, "cached": len(rows)}
	b, err := json.Marshal(append([]map[string]any{state}, rows...))
	if err != nil {
		s.t.Fatal(err)
	}
	if _, err := s.pool.Exec(s.ctx, fmt.Sprintf(`SELECT pgvigil.%s($1, $2, $3::jsonb)`, fn), id, at, string(b)); err != nil {
		s.t.Fatalf("%s at %s: %v", fn, at.Format(time.RFC3339), err)
	}
}

// vals reads one row as text values ('NULL' for a NULL): q selects the columns, in order.
func (s *spreadStore) vals(q string, args ...any) string {
	s.t.Helper()
	rows, err := s.pool.Query(s.ctx, q, args...)
	if err != nil {
		s.t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		v, err := rows.Values()
		if err != nil {
			s.t.Fatal(err)
		}
		cells := make([]string, len(v))
		for i, c := range v {
			if c == nil {
				cells[i] = "NULL"
			} else {
				cells[i] = fmt.Sprint(c)
			}
		}
		out = append(out, strings.Join(cells, " "))
	}
	if err := rows.Err(); err != nil {
		s.t.Fatal(err)
	}
	return strings.Join(out, " | ")
}

// stmt is one 'stmt' row of the plan cache payload: a plan's statement with its counters since compile; more holds
// the keys D421 added (or none: an older collector's row).
func stmt(handle, key string, compiled time.Time, execs, cpu, physical int64, more map[string]any) map[string]any {
	r := map[string]any{"kind": "stmt", "plan_handle": handle, "sql_handle": "0x02" + handle[4:], "stmt_start": 0, "stmt_end": -1,
		"creation_time": localOf(compiled), "query_key": key, "database_id": 5, "database_name": "appdb", "execution_count": execs,
		"worker_us": cpu, "elapsed_us": cpu, "logical_reads": execs * 10, "physical_reads": physical, "logical_writes": 0,
		"row_count": execs, "spills": 0, "max_grant_kb": nil, "max_used_grant_kb": nil, "max_dop": 1,
		"last_execution": localOf(compiled), "last_elapsed_us": 1000}
	for k, v := range more {
		r[k] = v
	}
	return r
}

const extremeCols = `e.executions, e.cpu_us, e.interval_secs::int, e.min_cpu_us, e.max_cpu_us, e.min_rows, e.max_rows, e.max_used_threads,
       e.plan_generation, e.clr_us, e.life_executions, e.life_cpu_us, e.life_physical_reads`

// The plan cache's extremes on a store: one row per key the interval's sample holds, over the plans of the key that
// RAN in the interval (an idle plan's extremes stay out), with the counts since compile of those plans; the CLR time
// is the interval's own - a difference only where the read before had the figure, never a 0 where it had none - and
// a payload without the new keys stores NULL.
func TestPlanCacheExtremesOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	now := time.Now().UTC().Truncate(time.Second)
	at := func(minAgo int) time.Time { return now.Add(-time.Duration(minAgo) * time.Minute) }
	old := at(600)
	a := func(execs, cpu, clr int64) map[string]any {
		return stmt("0x06AA", "K1", old, execs, cpu, 7, map[string]any{"min_worker_us": 50, "max_worker_us": 400, "min_rows": 1, "max_rows": 1000,
			"max_used_threads": 0, "plan_generation": 3, "clr_us": clr})
	}
	// the same key's second plan: idle after the first read, its extremes far larger
	b := stmt("0x06BB", "K1", old, 5, 50000, 900, map[string]any{"min_worker_us": 8000, "max_worker_us": 9000, "min_rows": 1, "max_rows": 1,
		"max_used_threads": 16, "plan_generation": 9, "clr_us": 4000})
	extreme := func(minAgo int, key string) string {
		t.Helper()
		return s.vals(`SELECT `+extremeCols+` FROM pgvigil.mssql_pc_extreme e WHERE e.instance_id = $1 AND e.snapshot_at = $2 AND e.query_key = $3`, s.id, at(minAgo), key)
	}
	counts := func(minAgo int) string {
		t.Helper()
		return s.vals(`SELECT (SELECT count(*) FROM pgvigil.mssql_pc_sample WHERE instance_id = $1 AND snapshot_at = $2),
		                      (SELECT count(*) FROM pgvigil.mssql_pc_extreme WHERE instance_id = $1 AND snapshot_at = $2)`, s.id, at(minAgo))
	}

	// the first read sets the counters: no interval, no row
	s.imp("import_mssql_plancache", s.id, at(25), a(10, 1000, 100), b)
	if got := counts(25); got != "0 0" {
		t.Fatalf("the first read stored samples and extremes: %s, want 0 0", got)
	}
	if got := s.vals(`SELECT plan_handle, clr_us FROM pgvigil.mssql_pc_last WHERE instance_id = $1 ORDER BY 1`, s.id); got != "0x06AA 100 | 0x06BB 4000" {
		t.Fatalf("the CLR time as last read: %s", got)
	}

	// the second: plan A ran 4 times, plan B did not run, a new statement was compiled and ran 3 times
	c := stmt("0x06CC", "K2", at(22), 3, 300, 0, map[string]any{"min_worker_us": 90, "max_worker_us": 110, "min_rows": 2, "max_rows": 2,
		"max_used_threads": 4, "plan_generation": 1, "clr_us": 30})
	s.imp("import_mssql_plancache", s.id, at(20), a(14, 1800, 160), b, c)
	if got := counts(20); got != "2 2" {
		t.Fatalf("samples and extremes of the second read: %s, want 2 2", got)
	}
	if got, want := extreme(20, "K1"), "4 800 300 50 400 1 1000 0 3 60 14 1800 7"; got != want {
		t.Errorf("K1 (plan A ran, plan B idle):\n got %s\nwant %s", got, want)
	}
	if got, want := extreme(20, "K2"), "3 300 300 90 110 2 2 4 1 30 3 300 0"; got != want {
		t.Errorf("K2 (a statement new to the read, whole):\n got %s\nwant %s", got, want)
	}

	// as after the migration: the last-read rows hold no CLR time yet - the interval's is unknown, never 0, and
	// the next one is a difference again
	if _, err := s.pool.Exec(s.ctx, `UPDATE pgvigil.mssql_pc_last SET clr_us = NULL WHERE instance_id = $1`, s.id); err != nil {
		t.Fatal(err)
	}
	s.imp("import_mssql_plancache", s.id, at(15), a(20, 2400, 250), b, c)
	if got, want := extreme(15, "K1"), "6 600 300 50 400 1 1000 0 3 NULL 20 2400 7"; got != want {
		t.Errorf("K1 after a read without the figure:\n got %s\nwant %s", got, want)
	}
	s.imp("import_mssql_plancache", s.id, at(10), a(25, 2900, 300), b, c)
	if got, want := extreme(10, "K1"), "5 500 300 50 400 1 1000 0 3 50 25 2900 7"; got != want {
		t.Errorf("K1 with the figure in both reads:\n got %s\nwant %s", got, want)
	}

	// both plans of the key ran: the smallest of the smallest, the largest of the largest, the counts of both
	b2 := stmt("0x06BB", "K1", old, 6, 59000, 950, map[string]any{"min_worker_us": 8000, "max_worker_us": 9000, "min_rows": 1, "max_rows": 1,
		"max_used_threads": 16, "plan_generation": 9, "clr_us": 4500})
	s.imp("import_mssql_plancache", s.id, at(5), a(26, 3000, 310), b2, c)
	if got, want := extreme(5, "K1"), "2 9100 300 50 9000 1 1000 16 9 510 32 62000 957"; got != want {
		t.Errorf("K1 with both plans running:\n got %s\nwant %s", got, want)
	}

	// an older collector's rows: the counts as before, every new figure NULL
	s.imp("import_mssql_plancache", s.id, at(2), stmt("0x06AA", "K1", old, 30, 3400, 7, nil), stmt("0x06BB", "K1", old, 6, 59000, 950, nil), c)
	if got, want := extreme(2, "K1"), "4 400 180 NULL NULL NULL NULL NULL NULL NULL 30 3400 7"; got != want {
		t.Errorf("K1 from a payload without the new keys:\n got %s\nwant %s", got, want)
	}
	if got := s.vals(`SELECT count(*) FROM pgvigil.mssql_pc_extreme e WHERE e.instance_id = $1
	                     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_pc_sample m WHERE m.instance_id = e.instance_id AND m.snapshot_at = e.snapshot_at
	                                        AND m.database_id = e.database_id AND m.query_key = e.query_key AND m.executions = e.executions AND m.cpu_us = e.cpu_us)`, s.id); got != "0" {
		t.Errorf("%s extreme rows have no sample row of the same key, executions and CPU", got)
	}
}

// proc is one 'proc' row of the procedure payload; more holds D421's keys.
func proc(handle string, cached time.Time, execs, cpu int64, more map[string]any) map[string]any {
	r := map[string]any{"kind": "proc", "plan_handle": handle, "cached_time": localOf(cached), "database_id": 5, "object_id": 100,
		"database_name": "appdb", "schema_name": "dbo", "object_name": "p_orders", "type_desc": "SQL_STORED_PROCEDURE",
		"execution_count": execs, "worker_us": cpu, "elapsed_us": cpu, "logical_reads": execs * 10, "physical_reads": 0,
		"logical_writes": 0, "spills": nil}
	for k, v := range more {
		r[k] = v
	}
	return r
}

// The procedures' extremes on a store: on the interval's own row, over the plans of the procedure that ran in it;
// a column the server lacks (the spills pair) and an older collector's payload store NULL.
func TestProcExtremesOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	now := time.Now().UTC().Truncate(time.Second)
	at := func(minAgo int) time.Time { return now.Add(-time.Duration(minAgo) * time.Minute) }
	old := at(600)
	ext := func(lo, hi int64) map[string]any {
		return map[string]any{"min_worker_us": lo, "max_worker_us": hi, "min_elapsed_us": lo + 1, "max_elapsed_us": hi + 1,
			"min_logical_reads": 3, "max_logical_reads": 30, "min_physical_reads": 0, "max_physical_reads": 12,
			"min_logical_writes": 0, "max_logical_writes": 2, "min_spills": nil, "max_spills": nil}
	}
	row := func(minAgo int) string {
		t.Helper()
		return s.vals(`SELECT executions, min_cpu_us, max_cpu_us, min_duration_us, max_duration_us, min_logical_reads, max_logical_reads,
		                      min_physical_reads, max_physical_reads, min_logical_writes, max_logical_writes, min_spills, max_spills
		                 FROM pgvigil.mssql_proc_sample WHERE instance_id = $1 AND snapshot_at = $2`, s.id, at(minAgo))
	}
	idle := proc("0x05BB", old, 5, 50000, ext(8000, 9000))
	s.imp("import_mssql_procstats", s.id, at(15), proc("0x05AA", old, 10, 1000, ext(50, 400)), idle)
	if got := row(15); got != "" {
		t.Fatalf("the first read stored a sample: %s", got)
	}
	s.imp("import_mssql_procstats", s.id, at(10), proc("0x05AA", old, 14, 1800, ext(50, 400)), idle)
	if got, want := row(10), "4 50 400 51 401 3 30 0 12 0 2 NULL NULL"; got != want {
		t.Errorf("one plan ran, the other idle:\n got %s\nwant %s", got, want)
	}
	s.imp("import_mssql_procstats", s.id, at(5), proc("0x05AA", old, 16, 2000, ext(50, 400)), proc("0x05BB", old, 6, 59000, ext(8000, 9000)))
	if got, want := row(5), "3 50 9000 51 9001 3 30 0 12 0 2 NULL NULL"; got != want {
		t.Errorf("both plans ran:\n got %s\nwant %s", got, want)
	}
	s.imp("import_mssql_procstats", s.id, at(2), proc("0x05AA", old, 20, 2400, nil), proc("0x05BB", old, 6, 59000, nil))
	if got, want := row(2), "4 NULL NULL NULL NULL NULL NULL NULL NULL NULL NULL NULL NULL"; got != want {
		t.Errorf("a payload without the new keys:\n got %s\nwant %s", got, want)
	}
}

// The grant finding on a store: one info row per instance under a constant name while a statement that ran in the
// last three hours holds a grant over 1 MB with under 10 % of it used; the count and the largest are in its words,
// which name the window; a grant of exactly 1 MB, a use of exactly 10 % and an interval older than three hours raise
// nothing.
func TestGrantFindingOnAStore(t *testing.T) {
	s := newSpreadStore(t)
	now := time.Now().UTC().Truncate(time.Second)
	at := func(minAgo int) time.Time { return now.Add(-time.Duration(minAgo) * time.Minute) }
	grant := func(handle, key string, compiled time.Time, kb, used int64) map[string]any {
		return stmt(handle, key, compiled, 2, 200, 0, map[string]any{"max_grant_kb": kb, "max_used_grant_kb": used})
	}
	finding := func(id int) string {
		t.Helper()
		return s.vals(`SELECT severity, check_name, object, detail FROM pgvigil.mssql_plancache_grant_findings WHERE instance_id = $1`, id)
	}
	rows := func(compiled time.Time) []map[string]any {
		return []map[string]any{grant("0x0601", "K-big", compiled, 512000, 1000), grant("0x0602", "K-small", compiled, 2048, 100),
			grant("0x0603", "K-1mb", compiled, 1024, 0), grant("0x0604", "K-10pct", compiled, 4000, 400)}
	}
	s.imp("import_mssql_plancache", s.id, at(12))
	if got := finding(s.id); got != "" {
		t.Fatalf("a finding before any statement: %s", got)
	}
	db := map[string]any{"kind": "database", "database_id": 5, "database_name": "appdb", "query_store_on": 0, "database_state": "ONLINE"}
	s.imp("import_mssql_plancache", s.id, at(7), append(rows(at(9)), db)...)
	got := finding(s.id)
	for _, want := range []string{"info wasteful memory grants plan cache 2 cached statement(s) that ran in the last 3 hours ",
		"The largest: appdb K-big (500.0 MB granted, 0.2 % used); appdb K-small (2.0 MB granted, 4.9 % used). "} {
		if !strings.Contains(got, want) {
			t.Errorf("the finding lacks %q:\n%s", want, got)
		}
	}
	if strings.Contains(got, "K-1mb") || strings.Contains(got, "K-10pct") || strings.Contains(got, " | ") {
		t.Errorf("a grant of exactly 1 MB or a use of exactly 10 %% is named, or more than one row:\n%s", got)
	}
	// the same statements on another instance, their one interval over three hours old
	late := s.instance("b")
	s.imp("import_mssql_plancache", late, at(192))
	s.imp("import_mssql_plancache", late, at(187), rows(at(189))...)
	if n := s.vals(`SELECT count(*) FROM pgvigil.mssql_pc_extreme WHERE instance_id = $1 AND max_grant_kb > 1024`, late); n != "3" {
		t.Fatalf("the older instance's intervals were not stored: %s rows with a grant over 1 MB, want 3", n)
	}
	if got := finding(late); got != "" {
		t.Errorf("an interval older than three hours raised: %s", got)
	}
}

// The diagnostics read no table and call only built-in functions that are parallel safe (format() and concat_ws() are
// STABLE, so the diagnostics are too): they are marked PARALLEL SAFE, or every statement that calls them - the Plan
// cache page's extremes over a week of reads among them - is planned with no parallel worker at all (the proof's C11).
func TestPCDiagnosticsParallelSafe(t *testing.T) {
	s := newSpreadStore(t)
	if got := s.vals(`SELECT p.provolatile::text, p.proparallel::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
	                   WHERE n.nspname = 'pgvigil' AND p.proname = 'mssql_pc_diagnostics'`); got != "s s" {
		t.Errorf("mssql_pc_diagnostics: volatility and parallel safety %q, want \"s s\" (STABLE PARALLEL SAFE)", got)
	}
}
