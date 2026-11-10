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
	"time"
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
	return append(out, Row{"kind": "cursor", "source": "serverlog:log", "read_to": t})
}
