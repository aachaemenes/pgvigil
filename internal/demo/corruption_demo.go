package demo

// Corruption rows for the demo fleet (task 34): the server log's corruption events (the serverlog collection's
// event rows, kind_of 'corruption'), amcheck's daily runs (the shape import_amcheck takes) and the two instance
// values the Corruption column reads (data_checksums, the developer settings).
//
// Wiring (the lead's, in gen.go):
//   Step:        in the serverlog branch, after serverlogRows:   add("serverlog", g.corruptionLogRows(t, prev))
//                (or append its rows to the serverlog batch: one batch per collection and step is the usual shape)
//                after the storage block:  if g.amcheckOn() && (first || (t.Hour() == 3 && t.Minute() == 0)) { add("amcheck", g.amcheckRows(t)) }
//   instanceRows: "data_checksums": g.dataChecksums(),   (in place of the fixed "on")
//   settings:    before the return:  g.corruptionSettings(vals)
//   Collections: append "amcheck" on the instances where g.amcheckOn() (onprem-erp01, onprem-hr01)
//   seed.go:     no skip line: amcheck is listed only where it runs (it is opt-in, off elsewhere)
//
// The scenario: onprem-hr01 read a damaged page 6 hours before the anchor (the checksum line and the ERROR, inside
// the 24 h finding) and its nightly amcheck reports one damaged index of hr from the run of the day before (the
// last run at 03:00 UTC within 36 h of the anchor); onprem-erp01 logged a missing TOAST
// chunk 5 days before the anchor (in the 7-day count, not the finding) and its amcheck is clean, with postgres
// skipped (no extension there); azure-portal02 runs without data checksums; cloudsql-analytics02 kept
// ignore_checksum_failure = on after a recovery.

import (
	"fmt"
	"strings"
	"time"
)

// is: the instance is the walk-through's name (the names carry the -prefix, demo- by default; a scale run adds -NNN copies
// that keep their own story out of this one).
func (g *Gen) is(name string) bool { return strings.HasSuffix(g.Spec.Name, name) }

func (g *Gen) amcheckOn() bool {
	return g.is("onprem-erp01") || g.is("onprem-hr01")
}

func (g *Gen) dataChecksums() string {
	if g.is("azure-portal02") {
		return "off"
	}
	return "on"
}

func (g *Gen) corruptionSettings(vals map[string]string) {
	if g.is("cloudsql-analytics02") {
		vals["ignore_checksum_failure"] = "on"
	}
}

// corruptionLogRows: the events whose time falls in (prev, t].
func (g *Gen) corruptionLogRows(t, prev time.Time) []Row {
	s := g.Spec
	var out []Row
	ev := func(at time.Time, pid int, user, db, level, detail, stmt string) {
		if !at.After(prev) || at.After(t) {
			return
		}
		file := "postgresql-" + at.UTC().Format("2006-01-02") + "_000000.log"
		out = append(out, Row{"kind": "event", "kind_of": "corruption", "at": at, "pid": pid, "client": nil,
			"usename": user, "datname": db, "duration_ms": nil, "statement": stmt, "detail": detail,
			"source":    "serverlog:log:" + file,
			"event_key": fmt.Sprintf("%016x", hash64(fmt.Sprintf("%s|corruption|%s|%d|%s", s.Name, level, at.UnixNano(), detail)))})
	}
	switch {
	case g.is("onprem-hr01"):
		at := g.end.Add(-6 * time.Hour)
		ev(at, 41877, "", "", "LOG", "page verification failed, calculated checksum 49361 but expected 16954\nCONTEXT: I/O worker executing I/O on behalf of process 41902", "")
		ev(at.Add(time.Millisecond), 41902, "app_hr", "hr", "ERROR", `invalid page in block 1873 of relation "base/16401/16533"`,
			"select * from timesheet where emp_id = 4411 order by week desc")
	case g.is("onprem-erp01"):
		at := g.end.Add(-5 * 24 * time.Hour)
		ev(at, 22051, "app_erp", "erp", "ERROR", "unexpected chunk number 1 (expected 0) for toast value 88213 in pg_toast_16620",
			"select body from invoice_doc where invoice_id = 99172")
	}
	return out
}

// amcheckRows: the nightly run, the shape amcheck.go returns.
func (g *Gen) amcheckRows(t time.Time) []Row {
	s := g.Spec
	run := func(db, check, status string, checked, total, corrupt int, problems []map[string]string, note any, ms int) Row {
		if problems == nil {
			problems = []map[string]string{}
		}
		return Row{"kind": "run", "datname": db, "check_name": check, "status": status, "checked": checked, "total": total,
			"corrupt": corrupt, "errors": 0, "problems": problems, "note": note, "duration_ms": ms}
	}
	none := "the amcheck extension is not installed in this database (CREATE EXTENSION amcheck)"
	out := []Row{run("postgres", "bt_index_check", "skipped", 0, 0, 0, nil, none, 0), run("postgres", "verify_heapam", "skipped", 0, 0, 0, nil, none, 0)}
	for i, db := range s.DBs {
		idx, tab := 180+40*i, 120+25*i
		if g.is("onprem-hr01") && i == 0 && !t.Before(g.end.Add(-36*time.Hour)) {
			out = append(out, run(db, "bt_index_check", "corrupt", idx, idx, 1, []map[string]string{{"relation": "public.timesheet_emp_idx",
				"message": `item order invariant violated for index "timesheet_emp_idx"`}}, nil, 48211))
		} else {
			out = append(out, run(db, "bt_index_check", "ok", idx, idx, 0, nil, nil, 41000+900*i))
		}
		out = append(out, run(db, "verify_heapam", "ok", tab, tab, 0, nil, nil, 96000+1500*i))
	}
	return out
}
