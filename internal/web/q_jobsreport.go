package web

import (
	"net/http"
	"time"
)

// The job report's API (task 38; DBADash's Jobs tab): GET /api/jobsreport?instance=<id>&from=&to= is one
// instance's report (every job with its last run, the 7- and 30-day runs, failures and durations, the
// failures in a row, the next run, and a duration trend over the window); without instance it is the fleet
// root (every failing, missed or over-average job). The existing jobs handler (/api/jobs: the job list and the
// window's runs) stays as it is. The overview check below feeds the Summary column Jobs beside the "jobs"
// check (check_group 'jobs report': the Jobs group takes both).

func init() {
	overviewChecks = append(overviewChecks, struct{ name, sql string }{"jobs report", `
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.job_report_checks c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active`})
}

// jobReportCols are the job report's columns, shared by the instance and the fleet grids.
const jobReportCols = `
       r.scheduler, r.job_id, r.job_name, r.schedule, r.active, r.is_present, r.datname, r.run_as,
       r.last_status, r.last_start, r.last_end, r.last_duration_secs, r.last_running, r.last_message,
       r.runs_7d, r.failures_7d, r.avg_7d_secs, r.max_7d_secs, r.runs_30d, r.failures_30d, r.avg_30d_secs, r.max_30d_secs,
       r.last_ok, r.fail_streak, r.base_avg_secs, r.over_average, r.missed, r.next_run, r.prior_due, r.schedule_note,
       left(r.command, 1000) AS command, r.snapshot_at`

// sqlJobReport is one instance's jobs, the ones with a problem first.
const sqlJobReport = `
SELECT` + jobReportCols + `
  FROM pgvigil.job_report r
 WHERE r.instance_id = $1
 ORDER BY r.is_present DESC, (coalesce(r.active, true) AND (r.fail_streak >= 3 OR r.missed OR r.over_average)) DESC,
          r.scheduler, r.job_name NULLS LAST, r.job_id`

// sqlJobTrend is each job's runs per $4-second bucket of the window: the count, failures, average and maximum.
const sqlJobTrend = `
SELECT to_timestamp(floor(extract(epoch FROM r.start_time) / $4) * $4) AS snapshot_at, r.scheduler, r.job_id,
       coalesce(j.job_name, r.job_id::text) AS job_name, count(*) AS runs,
       count(*) FILTER (WHERE r.status IN ('failed', 'internal error', 'aborted')) AS failures,
       round(avg(r.duration_secs)::numeric, 1) AS avg_secs, round(max(r.duration_secs)::numeric, 1) AS max_secs
  FROM pgvigil.job_runs r
  LEFT JOIN pgvigil.jobs j ON j.instance_id = r.instance_id AND j.scheduler = r.scheduler AND j.job_id = r.job_id
 WHERE r.instance_id = $1 AND r.start_time > $2 AND r.start_time <= $3
 GROUP BY 1, 2, 3, 4
 ORDER BY 1, 2, 3`

// sqlJobReportChecks are the instance's job report checks now.
const sqlJobReportChecks = `
SELECT severity, check_name, object, at, detail FROM pgvigil.job_report_checks WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 ELSE 1 END, check_name, object`

// sqlJobFleet is every active instance's job with a problem: failing now (the last finished run failed),
// missed or over its average; the worst first.
const sqlJobFleet = `
SELECT r.instance_id, r.instance, r.platform,` + jobReportCols + `
  FROM pgvigil.job_report r JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND r.is_present AND coalesce(r.active, true) AND (r.fail_streak > 0 OR r.missed OR r.over_average)
 ORDER BY (r.fail_streak >= 3 OR r.missed) DESC, r.fail_streak DESC, r.instance, r.scheduler, r.job_name NULLS LAST`

// sqlJobFleetCounts is the fleet's jobs in four numbers.
const sqlJobFleetCounts = `
SELECT count(*) AS jobs, count(*) FILTER (WHERE r.fail_streak > 0) AS failing,
       count(*) FILTER (WHERE r.missed) AS missed, count(*) FILTER (WHERE r.over_average) AS over_average,
       count(DISTINCT r.instance_id) AS instances
  FROM pgvigil.job_report r JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND r.is_present AND coalesce(r.active, true)`

// JobsReport is one instance's job report (?instance=) or, without it, the fleet's problem jobs.
func (s *Server) JobsReport(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("instance") == "" {
		s.multi(w, r, []part{
			{"counts", sqlJobFleetCounts, nil},
			{"jobs", sqlJobFleet, nil},
		})
		return
	}
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// an hourly trend up to three days, daily beyond
	bucket := 3600
	if to.Sub(from) > 72*time.Hour {
		bucket = 86400
	}
	s.multi(w, r, []part{
		{"jobs", sqlJobReport, []any{id}},
		{"trend", sqlJobTrend, []any{id, from, to, bucket}},
		{"checks", sqlJobReportChecks, []any{id}},
	})
}
