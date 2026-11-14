package web

import (
	"errors"
	"net/http"
	"strconv"
	"strings"
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

// sqlJobStatusFleet is the fleet Jobs page's 'Job status' grid (DBA Dash's root Jobs, AgentJobsReport_Get): every job
// of the instances $1 (NULL = every active instance) judged by job_status_view (0137: DBA Dash's default rule with no
// threshold row), with the job's own columns (enabled, category, description) and, for a SQL Agent job, the step of its
// newest failure inside the horizon (the failed rows' index). Ordered as DBA Dash orders it: the last run failed first,
// then the newest failure, then critical, warning.
const sqlJobStatusFleet = `
SELECT v.instance_id, i.name AS instance, i.engine, i.platform, v.scheduler, v.job_id, v.job_name,
       coalesce(m.enabled, g.active) AS enabled, m.category, m.description,
       v.status, v.reason, v.level, v.threshold_id, v.last_outcome, v.last_outcome = 'failed' AS last_run_failed,
       v.last_failed_at, v.last_succeeded_at, v.fail_24h, v.fail_7d, v.step_fail_24h, v.step_fail_7d, fs.step_id AS failed_step_id,
       fs.step_name AS failed_step, v.horizon_min
  FROM pgvigil.job_status_view(coalesce($1::int[], ARRAY(SELECT x.instance_id FROM pgvigil.instances x WHERE x.is_active))) v
  JOIN pgvigil.instances i ON i.instance_id = v.instance_id AND i.is_active
  LEFT JOIN pgvigil.mssql_jobs m ON v.scheduler = 'sqlagent' AND m.instance_id = v.instance_id AND m.job_id = v.job_id
  LEFT JOIN pgvigil.jobs g ON v.scheduler <> 'sqlagent' AND g.instance_id = v.instance_id AND g.scheduler = v.scheduler AND g.job_id::text = v.job_id
  LEFT JOIN LATERAL (SELECT r.step_id, r.step_name FROM pgvigil.mssql_job_runs r
                      WHERE v.scheduler = 'sqlagent' AND v.last_failed_at IS NOT NULL AND r.instance_id = v.instance_id AND r.job_id = v.job_id
                        AND r.run_status = 0 AND r.step_id > 0 AND r.snapshot_at > now() - make_interval(mins => v.horizon_min)
                      ORDER BY r.snapshot_at DESC LIMIT 1) fs ON true
 ORDER BY (v.last_outcome = 'failed') DESC, v.last_failed_at DESC NULLS LAST,
          CASE v.status WHEN 'crit' THEN 0 WHEN 'warn' THEN 1 ELSE 2 END, i.name, v.scheduler, v.job_name`

// sqlJobStatsFleet is the four columns of DBA Dash's root Jobs that need every run of 7 days (Succeed Count 24 h and
// 7 days, Max and Avg Duration over AgentJob7Day's 7 days), per job of the instances $1 (NULL = every active instance):
// its own part, read after the status grid is drawn, so its cost never holds the grid (the lead's 05:4x, (a)). SQL
// Agent: the job outcome rows (step 0); PostgreSQL: the runs with a start, their durations where they ended.
const sqlJobStatsFleet = `
WITH ids AS (SELECT unnest(coalesce($1::int[], ARRAY(SELECT x.instance_id FROM pgvigil.instances x WHERE x.is_active))) AS instance_id)
SELECT m.instance_id, 'sqlagent'::text AS scheduler, m.job_id,
       a.ok_24h, a.ok_7d, a.max_secs_7d, a.avg_secs_7d
  FROM pgvigil.mssql_jobs m JOIN ids USING (instance_id)
  CROSS JOIN LATERAL (SELECT count(*) FILTER (WHERE r.run_status = 1 AND r.snapshot_at > now() - interval '24 hours') AS ok_24h,
                             count(*) FILTER (WHERE r.run_status = 1) AS ok_7d,
                             max(r.duration_s) AS max_secs_7d, round(avg(r.duration_s)::numeric, 1) AS avg_secs_7d
                        FROM pgvigil.mssql_job_runs r
                       WHERE r.instance_id = m.instance_id AND r.job_id = m.job_id AND r.step_id = 0
                         AND r.snapshot_at > now() - interval '7 days' AND r.snapshot_at <= now()) a
UNION ALL
SELECT g.instance_id, g.scheduler, g.job_id::text,
       a.ok_24h, a.ok_7d, a.max_secs_7d, a.avg_secs_7d
  FROM pgvigil.jobs g JOIN ids USING (instance_id)
  CROSS JOIN LATERAL (SELECT count(*) FILTER (WHERE r.status = 'succeeded' AND r.start_time > now() - interval '24 hours') AS ok_24h,
                             count(*) FILTER (WHERE r.status = 'succeeded') AS ok_7d,
                             round(max(r.duration_secs)::numeric, 1) AS max_secs_7d, round(avg(r.duration_secs)::numeric, 1) AS avg_secs_7d
                        FROM pgvigil.job_runs r
                       WHERE r.instance_id = g.instance_id AND r.scheduler = g.scheduler AND r.job_id = g.job_id
                         AND r.start_time > now() - interval '7 days' AND r.start_time <= now()) a
 WHERE g.is_present`

// idsParam reads ?ids=1,2,3 (the instances of the page's view): nil when absent, an error on anything but positive ids.
func idsParam(r *http.Request) ([]int32, error) {
	v := r.URL.Query().Get("ids")
	if v == "" {
		return nil, nil
	}
	parts := strings.Split(v, ",")
	if len(parts) > 10000 {
		return nil, errors.New("ids: at most 10000 instances")
	}
	ids := make([]int32, 0, len(parts))
	for _, p := range parts {
		n, err := strconv.ParseInt(strings.TrimSpace(p), 10, 32)
		if err != nil || n <= 0 {
			return nil, errors.New("ids must be positive instance ids separated by commas")
		}
		ids = append(ids, int32(n))
	}
	return ids, nil
}

// JobsReport is one instance's job report (?instance=) or, without it, the fleet's problem jobs.
func (s *Server) JobsReport(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("instance") == "" {
		ids, err := idsParam(r)
		if err != nil {
			writeErr(w, http.StatusBadRequest, err)
			return
		}
		var idsArg any // a nil []int32 is sent as an empty array, not NULL
		if ids != nil {
			idsArg = ids
		}
		// 'status' (job_status_view, both engines) is its own part: the page asks for it alone (?part=status), so a slow
		// status read never takes PostgreSQL's schedule checks down with it, nor they it
		s.multiPart(w, r, []part{
			{"counts", sqlJobFleetCounts, nil},
			{"jobs", sqlJobFleet, nil},
			{"status", sqlJobStatusFleet, []any{idsArg}},
			{"stats", sqlJobStatsFleet, []any{idsArg}},
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
