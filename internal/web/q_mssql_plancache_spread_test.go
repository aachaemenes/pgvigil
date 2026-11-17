package web

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
)

// The filter's three values: each optional, each refused outside its range.
func TestPCFilterOf(t *testing.T) {
	f, err := pcFilterOf(url.Values{})
	if err != nil || f.set() {
		t.Errorf("no value: %+v, %v, want an unset filter", f, err)
	}
	f, err = pcFilterOf(url.Values{"min_avg_cpu_ms": {"500"}, "min_executions": {"100"}, "per_db": {"100"}})
	if err != nil || f.minAvgCPUms != 500.0 || f.minExecutions != int64(100) || f.perDB != 100 || !f.set() {
		t.Errorf("dbatools' defaults: %+v, %v", f, err)
	}
	if f, err = pcFilterOf(url.Values{"per_db": {"7"}}); err != nil || f.minAvgCPUms != nil || f.minExecutions != nil || f.perDB != 7 {
		t.Errorf("one value: %+v, %v, want the two others nil", f, err)
	}
	for _, bad := range []url.Values{{"min_avg_cpu_ms": {"-1"}}, {"min_avg_cpu_ms": {"x"}}, {"min_avg_cpu_ms": {"NaN"}}, {"min_executions": {"0"}},
		{"min_executions": {"1.5"}}, {"per_db": {"0"}}, {"per_db": {"1001"}}} {
		if _, err := pcFilterOf(bad); err == nil {
			t.Errorf("%v was taken", bad)
		}
	}
}

// The filtered statements are the unfiltered ones with the filter put in: the three values, the rank within the
// database and the count the filter kept; the unfiltered ones name none of them.
func TestPCFilteredStatements(t *testing.T) {
	for name, pair := range map[string][2]string{"top": {sqlMSSQLPCTop, sqlMSSQLPCTopFiltered}, "extremes": {sqlMSSQLPCExtremes, sqlMSSQLPCExtremesFiltered}} {
		plain, filtered := pair[0], pair[1]
		for _, want := range []string{"), f AS (", "$6::numeric IS NULL", "$7::bigint IS NULL", "$8::int IS NULL OR f.db_rank <= $8",
			"PARTITION BY p.database_id", "p.cpu_us::numeric / nullif(p.executions, 0) DESC NULLS LAST", "SELECT p.matched, p.database_id,",
			"ORDER BY p.cpu_us DESC, p.query_key, p.database_id\n LIMIT 1000"} {
			if !strings.Contains(filtered, want) {
				t.Errorf("%s filtered lacks %q", name, want)
			}
		}
		for _, not := range []string{"$6", "$7", "$8", "db_rank", "matched"} {
			if strings.Contains(plain, not) {
				t.Errorf("%s without a filter names %s", name, not)
			}
		}
		if !strings.HasSuffix(plain, "ORDER BY p.cpu_us DESC, p.query_key, p.database_id\n LIMIT 1000") {
			t.Errorf("%s does not end in top's order and cap", name)
		}
	}
}

type pcStore struct {
	t    *testing.T
	ctx  context.Context
	pool *pgxpool.Pool
	made []int
}

// newPCStore: the migrated repository of PGVIGIL_REPO_TEST_DSN; the instances a test makes go with it.
func newPCStore(t *testing.T) *pcStore {
	t.Helper()
	dsn := os.Getenv("PGVIGIL_REPO_TEST_DSN")
	if dsn == "" {
		t.Skip("PGVIGIL_REPO_TEST_DSN is not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	t.Cleanup(cancel)
	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	s := &pcStore{t: t, ctx: ctx, pool: pool}
	t.Cleanup(func() {
		c, stop := context.WithTimeout(context.Background(), 20*time.Second)
		defer stop()
		for _, q := range []string{`DELETE FROM pgvigil.mssql_pc_extreme WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.mssql_pc_sample WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_pc_read WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.mssql_proc_sample WHERE instance_id = ANY($1)`,
			`DELETE FROM pgvigil.mssql_proc_read WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.instances WHERE instance_id = ANY($1)`} {
			if _, err := pool.Exec(c, q, s.made); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
		pool.Close()
	})
	return s
}

func (s *pcStore) instance(name string) int {
	s.t.Helper()
	var id int
	if err := s.pool.QueryRow(s.ctx, `SELECT pgvigil.ensure_instance($1, 'sqlserver', '16.0', 160000, false, '{}'::text[], 'sqlserver')`,
		fmt.Sprintf("%s-%d", name, time.Now().UnixNano()%1000000000)).Scan(&id); err != nil {
		s.t.Fatal(err)
	}
	s.made = append(s.made, id)
	return id
}

func pcLocal(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000") }

func (s *pcStore) imp(fn string, id int, at time.Time, rows ...map[string]any) {
	s.t.Helper()
	state := map[string]any{"kind": "state", "server_utc": at.UTC().Format(time.RFC3339), "server_start": "2026-01-01T00:00:00Z",
		"server_local": pcLocal(at), "capped": false, "cached": len(rows)}
	b, err := json.Marshal(append([]map[string]any{state}, rows...))
	if err != nil {
		s.t.Fatal(err)
	}
	if _, err := s.pool.Exec(s.ctx, fmt.Sprintf(`SELECT pgvigil.%s($1, $2, $3::jsonb)`, fn), id, at, string(b)); err != nil {
		s.t.Fatalf("%s at %s: %v", fn, at.Format(time.RFC3339), err)
	}
}

// rows runs a part's statement and returns its rows as text by column name ('NULL' for a NULL), in its order.
func (s *pcStore) rows(sql string, args ...any) []map[string]string {
	s.t.Helper()
	rs, err := s.pool.Query(s.ctx, sql, args...)
	if err != nil {
		s.t.Fatalf("%v\n%s", err, sql)
	}
	defer rs.Close()
	var out []map[string]string
	for rs.Next() {
		vals, err := rs.Values()
		if err != nil {
			s.t.Fatal(err)
		}
		m := map[string]string{}
		for i, f := range rs.FieldDescriptions() {
			switch v := vals[i].(type) {
			case nil:
				m[f.Name] = "NULL"
			case pgtype.Numeric:
				d, err := v.Value()
				if err != nil {
					s.t.Fatal(err)
				}
				m[f.Name] = fmt.Sprint(d)
			case time.Time:
				m[f.Name] = v.UTC().Format(time.RFC3339)
			default:
				m[f.Name] = fmt.Sprint(v)
			}
		}
		out = append(out, m)
	}
	if err := rs.Err(); err != nil {
		s.t.Fatalf("%v\n%s", err, sql)
	}
	return out
}

func pcKeysOf(rows []map[string]string) string {
	k := make([]string, len(rows))
	for i, r := range rows {
		k[i] = r["query_key"]
	}
	return strings.Join(k, " ")
}

// pcStmt is one 'stmt' row of the plan cache payload; more holds the keys 0342 reads beside the counters.
func pcStmt(handle, key string, db int, compiled time.Time, execs, cpu int64, more map[string]any) map[string]any {
	r := map[string]any{"kind": "stmt", "plan_handle": handle, "sql_handle": "0x02" + handle[4:], "stmt_start": 0, "stmt_end": -1,
		"creation_time": pcLocal(compiled), "query_key": key, "database_id": db, "database_name": fmt.Sprintf("db%d", db),
		"execution_count": execs, "worker_us": cpu, "elapsed_us": cpu, "logical_reads": execs, "physical_reads": 0, "logical_writes": 0,
		"row_count": execs, "spills": 0, "max_grant_kb": nil, "max_used_grant_kb": nil, "max_dop": 1,
		"last_execution": pcLocal(compiled), "last_elapsed_us": 1000}
	for k, v := range more {
		r[k] = v
	}
	return r
}

// sp_QuickieCache's rules at their edges (0342's mssql_pc_diagnostics): 100 times the rows and not 99.9; more than 3
// executions; under 0.70 or over 1.30 of the average and not at them; no CPU at all leaves the physical reads' form,
// which wants an average over 1,000 (a whole number); a grant over 1 MB used under 10 %.
func TestPCDiagnosticsOnAStore(t *testing.T) {
	s := newPCStore(t)
	// executions, cpu_us, min_cpu_us, max_cpu_us, physical_reads, min_physical_reads, max_physical_reads, min_rows, max_rows, max_grant_kb, max_used_grant_kb
	for _, c := range []struct{ name, args, want string }{
		{"nothing read", "NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL", "NULL"},
		{"rows 1 to 100", "1, 10, 10, 10, 0, 0, 0, 1, 100, NULL, NULL", "Row count variance (1 to 100)"},
		{"rows 1 to 99", "1, 10, 10, 10, 0, 0, 0, 1, 99, NULL, NULL", "NULL"},
		{"rows 10 to 999 (99.9 times)", "1, 10, 10, 10, 0, 0, 0, 10, 999, NULL, NULL", "NULL"},
		{"rows 10 to 1000", "1, 10, 10, 10, 0, 0, 0, 10, 1000, NULL, NULL", "Row count variance (10 to 1000)"},
		{"rows 0 to 1000 (no row at the least)", "1, 10, 10, 10, 0, 0, 0, 0, 1000, NULL, NULL", "NULL"},
		{"CPU: 3 executions, any spread", "3, 300000, 1000, 290000, 0, 0, 0, 1, 1, NULL, NULL", "NULL"},
		{"CPU: 4 executions, the least under 0.70 (the words truncate)", "4, 400000, 69999, 100000, 0, 0, 0, 1, 1, NULL, NULL", "Parameter sniffing (CPU 69-100 ms, avg 100 ms)"},
		{"CPU: the least at 0.70, the most at 1.30", "4, 400000, 70000, 130000, 0, 0, 0, 1, 1, NULL, NULL", "NULL"},
		{"CPU: the most over 1.30", "4, 400000, 100000, 130001, 0, 0, 0, 1, 1, NULL, NULL", "Parameter sniffing (CPU 100-130 ms, avg 100 ms)"},
		{"CPU: an extreme not read", "4, 400000, NULL, 900000, 0, 0, 0, 1, 1, NULL, NULL", "NULL"},
		{"no CPU at all: the reads' form", "4, 0, 0, 0, 4004, 0, 4004, 1, 1, NULL, NULL", "Parameter sniffing (physical reads 0-4004, avg 1001)"},
		{"reads: an average of 1000", "4, 0, 0, 0, 4003, 0, 4003, 1, 1, NULL, NULL", "NULL"},
		{"reads: 3 executions, any spread (the gate holds both forms)", "3, 0, 0, 0, 30000, 0, 30000, 1, 1, NULL, NULL", "NULL"},
		{"reads: the CPU form first", "4, 400000, 1000, 100000, 4004, 0, 4004, 1, 1, NULL, NULL", "Parameter sniffing (CPU 1-100 ms, avg 100 ms)"},
		{"reads: CPU inside the band", "4, 400000, 90000, 110000, 23284, 0, 11642, 1, 1, NULL, NULL", "Parameter sniffing (physical reads 0-11642, avg 5821)"},
		{"a grant of 1 MB", "1, 10, 10, 10, 0, 0, 0, 1, 1, 1024, 0", "NULL"},
		{"a grant over 1 MB used under 10 %", "1, 10, 10, 10, 0, 0, 0, 1, 1, 1030, 102", "Wasteful grant (1.0 MB granted, 9.9 % used)"},
		{"a grant used 10 %", "1, 10, 10, 10, 0, 0, 0, 1, 1, 4000, 400", "NULL"},
		{"a grant whose use was not read", "1, 10, 10, 10, 0, 0, 0, 1, 1, 4000, NULL", "NULL"},
		{"all three", "200, 200000000, 100, 5000000, 0, 0, 0, 1, 1000, 512000, 1000",
			"Row count variance (1 to 1000); Parameter sniffing (CPU 0-5000 ms, avg 1000 ms); Wasteful grant (500.0 MB granted, 0.2 % used)"},
	} {
		got := s.rows(`SELECT pgvigil.mssql_pc_diagnostics(` + c.args + `) AS d`)
		if len(got) != 1 || got[0]["d"] != c.want {
			t.Errorf("%s: %v, want %s", c.name, got, c.want)
		}
	}
}

// The statements' two parts and the findings part on a store: extremes names top's keys in top's order, with and
// without the filter; the filter is dbatools' (an average CPU floor, an executions floor, the first of each database
// by average CPU) and says how many rows it kept; the extremes are the window's, the diagnostics the newest read's;
// the grant finding shows on the page; the procedures carry their extremes.
func TestPlanCacheSpreadPartsOnAStore(t *testing.T) {
	s := newPCStore(t)
	id := s.instance("d421-parts")
	now := time.Now().UTC().Truncate(time.Second)
	at := func(minAgo int) time.Time { return now.Add(-time.Duration(minAgo) * time.Minute) }
	dbs := []map[string]any{
		{"kind": "database", "database_id": 5, "database_name": "db5", "query_store_on": 0, "database_state": "ONLINE"},
		{"kind": "database", "database_id": 6, "database_name": "db6", "query_store_on": 0, "database_state": "ONLINE"}}
	s.imp("import_mssql_plancache", id, at(12), dbs...)
	ka := pcStmt("0x06A1", "K-a", 5, at(9), 200, 200000000, map[string]any{"min_worker_us": 100, "max_worker_us": 5000000,
		"min_elapsed_us": 150, "max_elapsed_us": 6000000, "min_physical_reads": 0, "max_physical_reads": 0, "min_rows": 1, "max_rows": 1000,
		"min_spills": 0, "max_spills": 7, "max_grant_kb": 512000, "max_used_grant_kb": 1000, "min_grant_kb": 1024, "min_ideal_grant_kb": 2048,
		"max_ideal_grant_kb": 600000, "min_dop": 1, "min_reserved_threads": 0, "max_reserved_threads": 8, "min_used_threads": 0,
		"max_used_threads": 4, "plan_generation": 2, "clr_us": 1500})
	even := map[string]any{"min_worker_us": 590000, "max_worker_us": 610000, "min_rows": 1, "max_rows": 1, "plan_generation": 1, "clr_us": 0}
	rest := []map[string]any{
		pcStmt("0x06B1", "K-b", 5, at(9), 150, 90000000, even),
		pcStmt("0x06C1", "K-c", 5, at(9), 50, 50000000, nil),
		pcStmt("0x06D1", "K-d", 5, at(9), 1000, 100000000, nil),
		pcStmt("0x06E1", "K-e", 6, at(9), 100, 50000000, nil),
		pcStmt("0x06F1", "K-f", 6, at(9), 100, 49999900, nil)}
	s.imp("import_mssql_plancache", id, at(7), append(append([]map[string]any{ka}, rest...), dbs...)...)
	// K-a recompiled since (the same plan handle under a later compile time): ten even runs, no grant
	ka2 := pcStmt("0x06A1", "K-a", 5, at(4), 10, 10000000, map[string]any{"min_worker_us": 900000, "max_worker_us": 1100000,
		"min_rows": 5, "max_rows": 6, "plan_generation": 3, "clr_us": 100})
	s.imp("import_mssql_plancache", id, at(2), append(append([]map[string]any{ka2}, rest...), dbs...)...)

	from, to := at(15), now
	plain := []any{id, from, to, nil, false}
	filt := func(avg, execs, perDB any) []any { return append(append([]any{}, plain...), avg, execs, perDB) }
	for _, c := range []struct {
		name    string
		args    []any
		want    string
		matched string
	}{
		{"no filter", nil, "K-a K-d K-b K-c K-e K-f", ""},
		{"500 ms over 100 executions", filt(500.0, int64(100), nil), "K-a K-b K-e", "3"},
		{"the same, the first of each database", filt(500.0, int64(100), 1), "K-a K-e", "2"},
		{"the first of each database alone (a tie on the average goes by key)", filt(nil, nil, 1), "K-a K-e", "2"},
		{"1000 executions alone", filt(nil, int64(1000), nil), "K-d", "1"},
		{"an average no statement has", filt(5000.0, nil, nil), "", ""},
	} {
		topSQL, extSQL, args := sqlMSSQLPCTop, sqlMSSQLPCExtremes, plain
		if c.args != nil {
			topSQL, extSQL, args = sqlMSSQLPCTopFiltered, sqlMSSQLPCExtremesFiltered, c.args
		}
		top, ext := s.rows(topSQL, args...), s.rows(extSQL, args...)
		if got := pcKeysOf(top); got != c.want {
			t.Errorf("%s: top %q, want %q", c.name, got, c.want)
		}
		if got := pcKeysOf(ext); got != c.want {
			t.Errorf("%s: extremes %q, want top's %q", c.name, got, c.want)
		}
		for _, r := range append(top, ext...) {
			if c.matched != "" && r["matched"] != c.matched {
				t.Errorf("%s: matched %s on %s, want %s", c.name, r["matched"], r["query_key"], c.matched)
			}
		}
	}

	byKey := func(rows []map[string]string) map[string]map[string]string {
		m := map[string]map[string]string{}
		for _, r := range rows {
			m[r["query_key"]] = r
		}
		return m
	}
	check := func(name string, row map[string]string, want map[string]string) {
		t.Helper()
		for k, v := range want {
			if row[k] != v {
				t.Errorf("%s: %s = %s, want %s", name, k, row[k], v)
			}
		}
	}
	// the whole window: both compiles' extremes; the diagnostics judge the newest read (the recompiled, even plan)
	ext := byKey(s.rows(sqlMSSQLPCExtremes, plain...))
	check("K-a over both reads", ext["K-a"], map[string]string{"min_cpu_ms": "0.100", "max_cpu_ms": "5000.000", "min_duration_ms": "0.150",
		"max_duration_ms": "6000.000", "min_rows": "1", "max_rows": "1000", "min_spills": "0", "max_spills": "7", "min_grant_kb": "1024",
		"min_ideal_grant_kb": "2048", "max_ideal_grant_kb": "600000", "min_dop": "1", "max_reserved_threads": "8", "max_used_threads": "4",
		"plan_generation": "3", "clr_ms": "1.6", "clr_reads": "2", "intervals": "2", "peak_cpu_ms_s": "666.7",
		"judged_at": at(2).Format(time.RFC3339), "life_executions": "10", "diagnostics": "NULL"})
	check("K-c, nothing read beside the counters", ext["K-c"], map[string]string{"min_cpu_ms": "NULL", "max_rows": "NULL", "plan_generation": "NULL",
		"clr_ms": "NULL", "clr_reads": "0", "intervals": "1", "peak_cpu_ms_s": "166.7", "diagnostics": "NULL"})
	// the window that ends before the recompile: the first compile's read is the newest
	early := byKey(s.rows(sqlMSSQLPCExtremes, id, from, at(5), nil, false))
	check("K-a before its recompile", early["K-a"], map[string]string{"plan_generation": "2", "judged_at": at(7).Format(time.RFC3339), "life_executions": "200",
		"diagnostics": "Row count variance (1 to 1000); Parameter sniffing (CPU 0-5000 ms, avg 1000 ms); Wasteful grant (500.0 MB granted, 0.2 % used)"})
	check("K-b, an even statement", early["K-b"], map[string]string{"min_cpu_ms": "590.000", "max_cpu_ms": "610.000", "diagnostics": "NULL"})

	// the page's findings part reads the grant finding beside 0092's
	var grant []map[string]string
	for _, f := range s.rows(sqlMSSQLPCFindings, id) {
		if f["check_name"] == "wasteful memory grants" {
			grant = append(grant, f)
		}
	}
	if len(grant) != 1 || grant[0]["severity"] != "info" || grant[0]["object"] != "plan cache" ||
		!strings.Contains(grant[0]["detail"], "1 cached statement(s) that ran in the last 3 hours ") ||
		!strings.Contains(grant[0]["detail"], "db5 K-a (500.0 MB granted, 0.2 % used)") {
		t.Errorf("the findings part's grant finding: %v", grant)
	}

	// the procedures: the extremes of the plans that ran, in milliseconds
	proc := func(execs, cpu int64, more map[string]any) map[string]any {
		r := map[string]any{"kind": "proc", "plan_handle": "0x05AA", "cached_time": pcLocal(at(600)), "database_id": 5, "object_id": 100,
			"database_name": "db5", "schema_name": "dbo", "object_name": "p_orders", "type_desc": "SQL_STORED_PROCEDURE",
			"execution_count": execs, "worker_us": cpu, "elapsed_us": cpu, "logical_reads": execs, "physical_reads": 0, "logical_writes": 0, "spills": nil}
		for k, v := range more {
			r[k] = v
		}
		return r
	}
	px := map[string]any{"min_worker_us": 50, "max_worker_us": 400000, "min_elapsed_us": 60, "max_elapsed_us": 500000, "min_logical_reads": 3,
		"max_logical_reads": 30, "min_physical_reads": 0, "max_physical_reads": 12, "min_logical_writes": 0, "max_logical_writes": 2,
		"min_spills": nil, "max_spills": nil}
	s.imp("import_mssql_procstats", id, at(12), proc(10, 1000, px))
	s.imp("import_mssql_procstats", id, at(7), proc(14, 1800, px))
	procs := s.rows(sqlMSSQLProcs, id, from, to, nil)
	if len(procs) != 1 {
		t.Fatalf("the procedures part: %d rows, want 1", len(procs))
	}
	check("the procedure", procs[0], map[string]string{"executions": "4", "min_cpu_ms": "0.050", "max_cpu_ms": "400.000", "min_duration_ms": "0.060",
		"max_duration_ms": "500.000", "min_logical_reads": "3", "max_logical_reads": "30", "min_physical_reads": "0", "max_physical_reads": "12",
		"min_logical_writes": "0", "max_logical_writes": "2", "min_spills": "NULL", "max_spills": "NULL"})
}
