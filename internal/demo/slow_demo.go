package demo

// Slow statements of the on-prem demo servers read from their server-log files (the serverlog collection, task
// 36): the shape import_serverlog takes (import_logs' rows). The RDS and Aurora servers keep their CloudWatch
// rows (logRows). The standby (onprem-erp02) has no read grant: its collection log says skipped, with the
// collector's reason.
//
// The lead's lines (internal/demo/<slice>_demo.go is this file):
//   Step (gen.go, after the logs line):
//     if g.Spec.Platform == "onprem" && !g.Spec.Replica {
//         add("serverlog", g.serverlogRows(t, prev))
//     }
//   Collections (gen.go, before the return):
//     if g.Spec.Platform == "onprem" {
//         c = append(c, "serverlog")
//     }
//   logCollections (seed.go, beside the vacuum skip):
//     if c == "serverlog" && g.Spec.Replica {
//         status, note = "skipped", serverlogSkipNote
//     }

import (
	"fmt"
	"math"
	"regexp"
	"strconv"
	"time"
)

// serverlogSkipNote is the collection log's note without the read grant, in the collector's words (serverlogSettings.check).
const serverlogSkipNote = "the monitoring login may not read the log files: the client DBA's opt-in is the function pgvigil_read_log " +
	"(SECURITY DEFINER, serves only the log files; its text is in the README), or the wide door GRANT EXECUTE ON FUNCTION " +
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
	return append(out, Row{"kind": "cursor", "source": "serverlog:log", "read_to": t})
}
