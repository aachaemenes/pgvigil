package demo

// Job report rows for the demo fleet (task 38): the pg_cron jobs of jobRows, three more jobs whose story the
// report tells, and the two values the jobs collection's own schedule parser adds (next_run where the row has
// none, prior_due), so the Job report tab, the fleet Jobs root and the Summary's Jobs column show them.
//
// Step adds these rows under the jobs collection (gen.go: add("jobs", g.jobReportRows(t, prev))); Collections is
// unchanged: the rows ride on "jobs".
//
// The stories, all at the anchor (g.end):
//   - aurora-crm01 (CronFail): sync-contacts '*/20 * * * *' failed its last four runs (from 80 minutes before
//     the anchor) -> "job failing repeatedly" (critical)
//   - rds-billing01 (Cron, not CronFail): export-ledger '15 * * * *' runs 30 s, its run of the last hour took
//     3 minutes and is its latest stored run at the anchor -> "job run over twice its average" (warning; once
//     the live demo runs past the anchor the next normal run ends it). No scheduled start is ever dropped, so
//     the missed rule never sees a gap on this job.; rollup-invoices '*/10 * * * *' stopped running
//     50 minutes before the anchor -> "job schedule missed" (critical)

// The definitions' history (task 110), a day before the anchor: sync-contacts' schedule is rewritten from
// '*/20 * * * *' to '0,20,40 * * * *' (the same minutes: its runs and its stories do not move) and export-ledger's
// command gains an argument. The failed runs carry pg_cron's own return_message.

import (
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

type reportJob struct {
	cronJob
	failFrom time.Duration // a run that starts this long before the anchor or later fails (0: none)
	stopAt   time.Duration // no run starts this long before the anchor or later (0: never stops)
	slowLast bool          // every run from the last one that ends by the anchor up to the anchor takes 6x its duration
}

func (g *Gen) reportJobs() []reportJob {
	switch {
	case g.Spec.CronFail:
		return []reportJob{{cronJob: cronJob{4, "sync-contacts", "*/20 * * * *", "CALL crm.sync_contacts()", 20 * time.Minute, 0, 12 * time.Second},
			failFrom: 80 * time.Minute}}
	case g.Spec.App == "billing":
		return []reportJob{
			{cronJob: cronJob{3, "export-ledger", "15 * * * *", "CALL billing.export_ledger()", time.Hour, 15 * time.Minute, 30 * time.Second},
				slowLast: true},
			{cronJob: cronJob{4, "rollup-invoices", "*/10 * * * *", "CALL billing.rollup_invoices()", 10 * time.Minute, 0, 4 * time.Second},
				stopAt: 50 * time.Minute},
		}
	}
	return nil
}

func (g *Gen) jobReportRows(t, prev time.Time) []Row {
	s := g.Spec
	out := g.jobRows(t, prev)
	changed := !t.Before(g.end.Add(-24 * time.Hour))
	for _, j := range g.reportJobs() {
		if changed && j.name == "sync-contacts" {
			j.schedule = "0,20,40 * * * *"
		}
		if changed && j.name == "export-ledger" {
			j.command = "CALL billing.export_ledger(full_refresh => false)"
		}
		out = append(out, Row{"kind": "job", "scheduler": "pg_cron", "job_id": j.id, "job_name": j.name, "schedule": j.schedule,
			"command": j.command, "datname": s.DBs[0], "run_as": "postgres", "active": true, "nodename": "localhost", "nodeport": 5432})
		// the slow run: the latest scheduled start whose 6x run still ends by the anchor
		slowAt := g.end.Add(-6 * j.dur).Truncate(j.every).Add(j.offset)
		if slowAt.After(g.end.Add(-6 * j.dur)) {
			slowAt = slowAt.Add(-j.every)
		}
		// runs that ended in (prev, t], as jobRows
		for st := prev.Add(-6 * j.dur).Truncate(j.every).Add(j.offset); !st.After(t); st = st.Add(j.every) {
			if st.Before(g.start) || (j.stopAt > 0 && !st.Before(g.end.Add(-j.stopAt))) {
				continue
			}
			d := j.dur + time.Duration(noise(s.Name+j.name, st)*float64(j.dur)/10)
			failed := j.failFrom > 0 && !st.Before(g.end.Add(-j.failFrom))
			if failed {
				d = time.Second
			}
			if j.slowLast && !st.Before(slowAt) && !st.After(g.end) {
				d = 6 * j.dur
			}
			en := st.Add(d)
			if !en.After(prev) || en.After(t) {
				continue
			}
			g.runID++
			status, msg := "succeeded", "CALL"
			if failed {
				status, msg = "failed", `ERROR:  could not connect to server: Connection timed out (sync target crm-api)`
			}
			out = append(out, Row{"kind": "run", "scheduler": "pg_cron", "job_id": j.id, "run_id": g.runID,
				"job_pid": 3000 + int(noise(s.Name+j.name+"pid", st)*50000), "datname": s.DBs[0], "run_as": "postgres", "command": j.command,
				"status": status, "return_message": msg, "start_time": st, "end_time": en, "duration_secs": d.Seconds()})
		}
	}
	// the collector's own parser: next_run where jobRows left none, prior_due on every pg_cron job (pg_cron's GMT)
	collect.AddCronTimes(out, t, collect.CronSettings{Timezone: "GMT"})
	return out
}
