package demo

// Slow statements of the on-prem demo servers read from their server-log files (the serverlog collection, task
// 36): the shape import_serverlog takes (import_logs' rows). The RDS and Aurora servers keep their CloudWatch
// rows (logRows). The standby (onprem-erp02) has no read grant: its collection log says skipped, with the
// collector's reason.
//
// Step adds these rows under the serverlog collection on an on-prem primary (gen.go), Collections lists serverlog
// on every on-prem instance, and logCollections (seed.go) marks the standby's run skipped with serverlogSkipNote.

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/logparse"
)

// serverlogSkipNote is the collection log's note without the read grant, in the collector's words (serverlogSettings.check).
const serverlogSkipNote = "the monitoring login may not read the log files: the client DBA's opt-in is the function pgvigil_read_log " +
	"(SECURITY DEFINER, serves only the log files; `pgvigil roles` prints it), or the wide door GRANT EXECUTE ON FUNCTION " +
	"pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) TO <login>, which also opens every file under the data directory " +
	"(pg_hba.conf, server.key, pg_authid's password hashes); pg_read_server_files alone opens neither"

var demoParamRE = regexp.MustCompile(`\$[0-9]+`)

// serverlogRows: slow statements over the instance's log_min_duration_statement, more under load, with the literals
// the simple query protocol logs (so one shape gathers many texts), and one long report each night at 02:00 UTC
// from a file named for the day it was written in, and the cursor row.
func (g *Gen) serverlogRows(t, prev time.Time) []Row {
	s := g.Spec
	var out []Row
	ev := func(at time.Time, pid int, text string, ms float64) {
		file := "postgresql-" + at.UTC().Format("2006-01-02") + "_000000.log"
		out = append(out, Row{"kind": "event", "kind_of": "slow", "at": at, "pid": pid, "client": fmt.Sprintf("10.20.%d.%d(%d)", pid%5, 40+pid%150, 40000+pid%20000),
			"usename": "app_" + s.App, "datname": s.DBs[0], "duration_ms": math.Round(ms*1000) / 1000, "statement": text,
			"source": "serverlog:log:" + file, "event_key": fmt.Sprintf("%016x", hash64(fmt.Sprintf("%s|serverlog|%d|%d", s.Name, at.UnixNano(), pid)))})
	}
	literal := func(text string) string {
		return demoParamRE.ReplaceAllStringFunc(text, func(string) string { return strconv.Itoa(1 + g.rng.IntN(90000)) })
	}
	dt := t.Sub(prev).Hours()
	n := int(math.Floor(6*s.Load*(0.2+curve(t))*dt + g.rng.Float64()))
	for i := 0; i < n; i++ {
		pick := []int{stReport, 1, 9, 4, stUpdate}[g.rng.IntN(5)]
		st := g.stmts[pick]
		at := prev.Add(time.Duration(g.rng.Float64() * float64(t.Sub(prev))))
		ms := 1000 + g.rng.Float64()*4000
		if pick == stReport {
			ms = 8000 + g.rng.Float64()*40000
		}
		ev(at, 2000+g.rng.IntN(60000), literal(st.text), ms)
	}
	if night := t.UTC().Truncate(24 * time.Hour).Add(2 * time.Hour); night.After(prev) && !night.After(t) {
		ev(night, 2000+int(noise(s.Name+"night", night)*60000), literal(g.stmts[stReport].text), 95000+noise(s.Name+"nightms", night)*60000)
	}
	if g.is("onprem-erp01") { // the nightly report's temporary files, one every 10 minutes from 01:00 to 03:00 UTC (memory_demo.go: the hour rows' log_files)
		for at := prev.Truncate(10 * time.Minute).Add(10 * time.Minute); !at.After(t); at = at.Add(10 * time.Minute) {
			if h := at.UTC().Hour(); h >= 1 && h < 3 {
				size := 200<<20 + int64(noise(s.Name+"tmp", at)*60*(1<<20))
				pid := 2000 + int(noise(s.Name+"tmppid", at)*60000)
				file := "postgresql-" + at.UTC().Format("2006-01-02") + "_000000.log"
				out = append(out, Row{"kind": "event", "kind_of": "temp_file", "at": at, "pid": pid, "client": fmt.Sprintf("10.20.%d.%d(%d)", pid%5, 40+pid%150, 40000+pid%20000),
					"usename": "app_" + s.App, "datname": s.DBs[0], "statement": g.stmts[stReport].text,
					"detail": fmt.Sprintf("temporary file: path \"base/pgsql_tmp/pgsql_tmp%d.%d\", size %d", pid, at.Hour(), size),
					"source": "serverlog:log:" + file, "event_key": fmt.Sprintf("%016x", hash64(fmt.Sprintf("%s|serverlog|tmp|%d|%d", s.Name, at.UnixNano(), pid)))})
			}
		}
	}
	out = append(out, g.serverlogErrors(t, prev)...)
	return append(out, Row{"kind": "cursor", "source": "serverlog:log", "read_to": t})
}

// demoError is one error a server log carries, as the server writes it: its level, its message, the DETAIL line and
// the statement; kind is the kind logparse gives that line (a cancel by user request is 'canceled', not 'error').
type demoError struct {
	kind, level, msg, detail, stmt string
	weight                         float64
}

// demoErrors: the errors an application's server log carries, weighted so a few groups dominate as they do in a real
// log (pgBadger's Events tab). TestDemoErrorsParse holds each to what logparse makes of the same line.
var demoErrors = []demoError{
	{"error", "ERROR", `duplicate key value violates unique constraint "order_lines_pkey"`, `Key (order_id, line_no)=(%d, 1) already exists.`, `INSERT INTO order_lines (order_id, line_no, sku, qty) VALUES ($1, 1, $2, $3)`, 0.38},
	{"canceled", "ERROR", `canceling statement due to user request`, ``, `SELECT * FROM orders WHERE customer_id = $1 ORDER BY created_at DESC`, 0.18},
	{"error", "ERROR", `relation "staging_import_%d" does not exist`, ``, `INSERT INTO staging_import_%d SELECT * FROM orders WHERE created_at > $1`, 0.14},
	{"error", "WARNING", `there is no transaction in progress`, ``, `COMMIT`, 0.12},
	{"error", "ERROR", `null value in column "sku" of relation "order_lines" violates not-null constraint`, `Failing row contains (%d, 2, null, 1).`, `INSERT INTO order_lines (order_id, line_no, sku, qty) VALUES ($1, 2, $2, $3)`, 0.1},
	{"error", "ERROR", `permission denied for table payroll`, ``, `SELECT * FROM payroll`, 0.05},
	{"error", "ERROR", `invalid input syntax for type integer: "%d-A"`, ``, `SELECT * FROM orders WHERE id = $1`, 0.03},
}

// render: the message line, the DETAIL line ("" when none) and the statement for the number n.
func (e demoError) render(n int) (raw, detailLine, stmt string) {
	raw, stmt = e.msg, e.stmt
	if strings.Contains(raw, "%d") {
		raw = fmt.Sprintf(raw, n%40)
	}
	if strings.Contains(stmt, "%d") {
		stmt = fmt.Sprintf(stmt, n%40)
	}
	if e.detail != "" {
		detailLine = fmt.Sprintf(e.detail, n)
	}
	return raw, detailLine, stmt
}

// serverlogErrors: one chance of an error event in each 5-minute slot, more under load, chosen by noise (not the
// generator's random stream, so the rest of the demo's rows stay as they were), stored as the serverlog collector
// stores an event of its kind: its level and its message shape (logparse.MessageShape), the DETAIL line in detail
// (a 'canceled' event keeps the message alone, as ClassifyMore does). An event's time stays inside the slot and never
// passes the reading's own cursor t: a collector stores nothing beyond read_to.
func (g *Gen) serverlogErrors(t, prev time.Time) []Row {
	s := g.Spec
	var out []Row
	for at := prev.Truncate(5 * time.Minute).Add(5 * time.Minute); !at.After(t); at = at.Add(5 * time.Minute) {
		if noise(s.Name+"err", at) > 0.15+0.35*curve(at) {
			continue
		}
		r, pick := noise(s.Name+"errkind", at), 0
		for acc := 0.0; pick < len(demoErrors)-1; pick++ {
			if acc += demoErrors[pick].weight; r < acc {
				break
			}
		}
		e := demoErrors[pick]
		pid := 2000 + int(noise(s.Name+"errpid", at)*60000)
		n := 100000 + int(noise(s.Name+"errn", at)*900000)
		raw, detailLine, stmt := e.render(n)
		var detail any = raw
		if detailLine != "" && e.kind == "error" {
			detail = raw + "\nDETAIL: " + detailLine
		}
		ts := at.Add(time.Duration(noise(s.Name+"errs", at)*290) * time.Second)
		if ts.After(t) {
			ts = t
		}
		file := "postgresql-" + at.UTC().Format("2006-01-02") + "_000000.log"
		out = append(out, Row{"kind": "event", "kind_of": e.kind, "at": ts, "pid": pid,
			"client": fmt.Sprintf("10.20.%d.%d(%d)", pid%5, 40+pid%150, 40000+pid%20000), "usename": "app_" + s.App, "datname": s.DBs[0],
			"statement": stmt, "detail": detail, "level": e.level, "message": logparse.MessageShape(raw),
			"source": "serverlog:log:" + file, "event_key": fmt.Sprintf("%016x", hash64(fmt.Sprintf("%s|serverlog|err|%d|%d", s.Name, at.UnixNano(), pid)))})
	}
	return out
}
