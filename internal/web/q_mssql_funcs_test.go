package web

import (
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"testing"
	"time"
)

// The Procedures API's parts: the procedures' own as before, the functions' and the triggers' grids, and the
// functions' collection state in a part of its own - the page reads the procedures' state as the first row of
// 'state', so that part keeps naming mssql_procstats alone.
func TestProcsParts(t *testing.T) {
	now := time.Now()
	ps := procsParts(7, now.Add(-time.Hour), now, nil)
	var names []string
	state := map[string]any{}
	for _, p := range ps {
		names = append(names, p.name)
		if strings.HasSuffix(p.name, "state") {
			state[p.name] = p.args[1]
		}
	}
	if got, want := strings.Join(names, " "), "state reads databases totals procs series func_state functions triggers"; got != want {
		t.Errorf("parts %q, want %q", got, want)
	}
	if !reflect.DeepEqual(state["state"], []string{"mssql_procstats"}) || !reflect.DeepEqual(state["func_state"], []string{"mssql_funcstats"}) {
		t.Errorf("the state parts name %v, want state = mssql_procstats alone and func_state = mssql_funcstats", state)
	}
}

// funcImp is one read of the collection mssql_funcstats (0343's payload): the state row names the views read.
func funcImp(s *pcStore, id int, at time.Time, rows ...map[string]any) {
	s.t.Helper()
	state := map[string]any{"kind": "state", "server_utc": at.UTC().Format(time.RFC3339), "server_start": "2026-01-01T00:00:00Z",
		"server_local": pcLocal(at), "capped": false, "kinds": []string{"function", "trigger"}}
	b, err := json.Marshal(append([]map[string]any{state}, rows...))
	if err != nil {
		s.t.Fatal(err)
	}
	if _, err := s.pool.Exec(s.ctx, `SELECT pgvigil.import_mssql_funcstats($1, $2, $3::jsonb)`, id, at, string(b)); err != nil {
		s.t.Fatalf("import_mssql_funcstats at %s: %v", at.Format(time.RFC3339), err)
	}
}

// funcRow is one cached plan of a function or a trigger as the collector sends it; more holds the extremes.
func funcRow(kind string, db int, obj int64, name string, execs, cpu int64, more map[string]any) map[string]any {
	r := map[string]any{"kind": kind, "plan_handle": fmt.Sprintf("0x07%04d", obj), "cached_time": "2026-01-02T00:00:00.000",
		"database_id": db, "object_id": obj, "database_name": fmt.Sprintf("db%d", db), "schema_name": "dbo", "object_name": name,
		"type_desc": "SQL_SCALAR_FUNCTION", "execution_count": execs, "worker_us": cpu, "elapsed_us": 2 * cpu, "logical_reads": execs,
		"physical_reads": 0, "logical_writes": 0, "spills": nil}
	if kind == "trigger" {
		r["type_desc"] = "SQL_TRIGGER"
	}
	for k, v := range more {
		r[k] = v
	}
	return r
}

// The functions' and the triggers' parts on a store: the window's differences per object, the busiest CPU first;
// the functions' mark from mssql_func_inline in its four forms ('not read' with no row, 'not inlineable',
// 'inlining off', none); no spills column at all on the functions; the triggers' spills and scope; the database
// filter; the minutes over the seconds the functions' own reads cover.
func TestFuncPartsOnAStore(t *testing.T) {
	s := newPCStore(t)
	id := s.instance("d467-parts")
	t.Cleanup(func() {
		for _, q := range []string{`DELETE FROM pgvigil.mssql_func_sample WHERE instance_id = ANY($1)`, `DELETE FROM pgvigil.mssql_func_read WHERE instance_id = ANY($1)`} {
			if _, err := s.pool.Exec(s.ctx, q, s.made); err != nil {
				t.Logf("cleanup: %v", err)
			}
		}
	})
	now := time.Now().UTC().Truncate(time.Second)
	at := func(minAgo int) time.Time { return now.Add(-time.Duration(minAgo) * time.Minute) }
	ext := map[string]any{"min_worker_us": 40, "max_worker_us": 9000, "min_elapsed_us": 50, "max_elapsed_us": 12000, "min_logical_reads": 1,
		"max_logical_reads": 9, "min_physical_reads": 0, "max_physical_reads": 3, "min_logical_writes": 0, "max_logical_writes": 1}
	read := func(step int64) []map[string]any {
		return []map[string]any{
			funcRow("function", 5, 200, "f_noread", 10*step, 3000*step, ext),
			funcRow("function", 5, 201, "f_notinl", 10*step, 1000*step, ext),
			funcRow("function", 6, 202, "f_off", 10*step, 9000*step, ext),
			funcRow("function", 6, 203, "f_plain", 10*step, 5000*step, ext),
			funcRow("trigger", 5, 300, "tr_orders_ins", 2*step, 800*step, map[string]any{"spills": 3 * step, "min_spills": 0, "max_spills": 6,
				"min_worker_us": 70, "max_worker_us": 700, "min_elapsed_us": 80, "max_elapsed_us": 800, "min_logical_reads": 2, "max_logical_reads": 20,
				"min_physical_reads": 0, "max_physical_reads": 0, "min_logical_writes": 1, "max_logical_writes": 4}),
			funcRow("trigger", 1, 301, "ddl_audit", 1*step, 400*step, map[string]any{"type_desc": "SQL_TRIGGER", "trigger_scope": "server", "schema_name": nil,
				"database_name": "master"}),
		}
	}
	funcImp(s, id, at(12), read(1)...)
	inline := []map[string]any{{"kind": "inline_read", "database_id": 5}, {"kind": "inline_read", "database_id": 6},
		{"kind": "inline", "database_id": 5, "object_id": 201, "is_inlineable": false, "inline_type": false},
		{"kind": "inline", "database_id": 6, "object_id": 202, "is_inlineable": true, "inline_type": false},
		{"kind": "inline", "database_id": 6, "object_id": 203, "is_inlineable": true, "inline_type": true}}
	funcImp(s, id, at(7), append(read(3), inline...)...)

	check := func(name string, row map[string]string, want map[string]string) {
		t.Helper()
		for k, v := range want {
			if row[k] != v {
				t.Errorf("%s: %s = %s, want %s", name, k, row[k], v)
			}
		}
	}
	from, to := at(15), now
	fns := s.rows(sqlMSSQLFuncs, id, from, to, nil)
	var order []string
	for _, r := range fns {
		order = append(order, r["object_name"]+"="+r["inline_mark"])
	}
	if got, want := strings.Join(order, " "), "f_off=inlining off f_plain= f_noread=not read f_notinl=not inlineable"; got != want {
		t.Errorf("the functions part: %q, want %q (the busiest CPU first, each with its mark)", got, want)
	}
	if len(fns) == 4 {
		// f_off: 20 executions and 18000 us of CPU between the two reads, 300 s apart
		check("f_off", fns[0], map[string]string{"database": "db6", "executions": "20", "executions_min": "4.00", "cpu_ms": "18.0",
			"avg_cpu_ms": "0.900", "duration_ms": "36.0", "min_cpu_ms": "0.040", "max_cpu_ms": "9.000", "min_duration_ms": "0.050", "max_duration_ms": "12.000",
			"min_logical_reads": "1", "max_logical_reads": "9", "max_physical_reads": "3", "max_logical_writes": "1", "intervals": "1"})
		for _, k := range []string{"spills", "avg_spills", "spill_reads", "min_spills", "max_spills"} {
			if _, ok := fns[0][k]; ok {
				t.Errorf("the functions part has a %s column: the function view has no spills at all", k)
			}
		}
		if fns[2]["inline_read_at"] != "NULL" || fns[0]["inline_read_at"] != at(7).Format(time.RFC3339) {
			t.Errorf("inline_read_at: f_noread %s (want NULL), f_off %s (want the read's server clock %s)", fns[2]["inline_read_at"],
				fns[0]["inline_read_at"], at(7).Format(time.RFC3339))
		}
	}
	if got := s.rows(sqlMSSQLFuncs, id, from, to, 6); len(got) != 2 || got[0]["object_name"] != "f_off" || got[1]["object_name"] != "f_plain" {
		t.Errorf("the functions of database 6: %v, want f_off then f_plain", got)
	}

	trs := s.rows(sqlMSSQLTriggers, id, from, to, nil)
	if len(trs) != 2 {
		t.Fatalf("the triggers part: %d rows, want 2", len(trs))
	}
	check("tr_orders_ins", trs[0], map[string]string{"object_name": "tr_orders_ins", "database": "db5", "type_desc": "SQL_TRIGGER",
		"trigger_scope": "NULL", "executions": "4", "cpu_ms": "1.6", "spills": "6", "avg_spills": "1.5", "spill_reads": "1",
		"min_spills": "0", "max_spills": "6", "min_logical_writes": "1", "max_logical_writes": "4"})
	check("ddl_audit", trs[1], map[string]string{"object_name": "ddl_audit", "database": "master", "trigger_scope": "server",
		"schema_name": "NULL", "executions": "2", "spills": "NULL", "spill_reads": "0", "max_spills": "NULL", "min_cpu_ms": "NULL"})
	if got := s.rows(sqlMSSQLTriggers, id, from, to, 5); len(got) != 1 || got[0]["object_name"] != "tr_orders_ins" {
		t.Errorf("the triggers of database 5: %v, want tr_orders_ins alone", got)
	}
}
