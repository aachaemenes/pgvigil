package web

import (
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
)

// The Jobs pages of both engines in DBA Dash's shape (task 110; DBA Dash 4.24.1's Agent Jobs grid, Job History and
// Job DDL History): one line per job, then the picked job's runs and the changes to its definition.
//
// GET /api/jobs/history?engine=pg|mssql&instance=<id>&from=&to=[&scheduler=&job=] (Server.JobsHistory):
//   jobs     one row per job: name, enabled, schedule, the last run and its outcome, the last failure (when, the
//            step that failed, its whole message: the page cuts the line), the next run, runs and failures in the
//            range, the changes in the range, a job no longer on the server with the time it was seen dropped
//   with scheduler and job, the picked job's:
//   runs     each run that started in the range, newest first (at most 1,000): start, duration, outcome, the step
//            that failed, the message, msdb's message id, severity and retries; a running SQL Server job as a row
//   counts   succeeded, failed, cancelled, running and running long (a finished run over twice the median of the
//            job's successful runs in the range), and that median
//   changes  every version kept of the job's definition, newest first: when, the version, dropped, the fields that
//            changed (old against new) and the whole definition
//   stats    (task 132; DBA Dash's Job Stats grid) one row per step of the job with a run in the range, the job's own
//            outcome row first: failed, succeeded, retry and cancelled runs, the average, longest, shortest and total
//            seconds. SQL Server stores msdb's step rows; pg_cron has no steps and pgAgent's step log rides on the
//            run, so a PostgreSQL job has the outcome row alone
//   series   the range in buckets (series_meta: their width), every bucket a row, an empty one with zero counts:
//            runs, succeeded, failed, other, and the average and longest seconds of the finished runs (NULL without
//            one), so the chart has a point where every run took 0 s
//   &step=<n> (SQL Server; n > 0) cuts runs, counts and series to that step's own rows (a run's failed_step is then
//            filled only where that step failed); engine=pg with step is 400

// pgOutcome is a pg_cron or pgAgent run's status as one of succeeded, failed, cancelled, running.
const pgOutcome = `CASE WHEN r.status = 'succeeded' THEN 'succeeded'
            WHEN r.status IN ('failed', 'internal error') THEN 'failed'
            WHEN r.status = 'aborted' THEN 'cancelled'
            WHEN r.end_time IS NULL THEN 'running'
            ELSE r.status END`

// msOutcome is sysjobhistory's run_status as a word.
const msOutcome = `CASE r.run_status WHEN 0 THEN 'failed' WHEN 1 THEN 'succeeded' WHEN 2 THEN 'retry' WHEN 3 THEN 'cancelled'
                         WHEN 4 THEN 'running' END`

const sqlJobsGridPG = `
SELECT j.scheduler, j.job_id::text AS job_id, coalesce(j.job_name, j.job_id::text) AS name, j.active AS enabled, j.schedule,
       j.datname, j.run_as, left(j.command, 1000) AS command,
       lr.start_time AS last_run_at, lr.outcome AS last_outcome, lr.duration_secs AS last_duration_s,
       lf.start_time AS last_failed_at, lf.failed_step, left(lf.return_message, 4000) AS last_failure,
       CASE WHEN j.is_present AND coalesce(j.active, true) THEN j.next_run END AS next_run,
       coalesce(c.runs, 0) AS runs, coalesce(c.failures, 0) AS failures, c.avg_s, c.max_s,
       (SELECT count(*) FROM pgvigil.job_versions v
         WHERE v.instance_id = $1 AND v.scheduler = j.scheduler AND v.job_id = j.job_id::text AND v.version_no > 1
           AND v.valid_from > $2 AND v.valid_from <= $3) AS changes,
       (SELECT max(v.valid_from) FROM pgvigil.job_versions v
         WHERE v.instance_id = $1 AND v.scheduler = j.scheduler AND v.job_id = j.job_id::text AND v.version_no > 1) AS last_change_at,
       CASE WHEN NOT j.is_present THEN coalesce(
         (SELECT max(v.valid_from) FROM pgvigil.job_versions v
           WHERE v.instance_id = $1 AND v.scheduler = j.scheduler AND v.job_id = j.job_id::text AND v.dropped), j.snapshot_at) END AS dropped_at
  FROM pgvigil.jobs j
  LEFT JOIN LATERAL (SELECT r.start_time, r.duration_secs, ` + pgOutcome + ` AS outcome
                       FROM pgvigil.job_runs r
                      WHERE r.instance_id = j.instance_id AND r.scheduler = j.scheduler AND r.job_id = j.job_id
                      ORDER BY r.start_time DESC NULLS LAST LIMIT 1) lr ON true
  LEFT JOIN LATERAL (SELECT r.start_time, r.failed_step, r.return_message
                       FROM pgvigil.job_runs r
                      WHERE r.instance_id = j.instance_id AND r.scheduler = j.scheduler AND r.job_id = j.job_id
                        AND r.status IN ('failed', 'internal error')
                      ORDER BY r.start_time DESC NULLS LAST LIMIT 1) lf ON true
  LEFT JOIN LATERAL (SELECT count(*) AS runs, count(*) FILTER (WHERE r.status IN ('failed', 'internal error')) AS failures,
                            round(avg(r.duration_secs) FILTER (WHERE r.status = 'succeeded')::numeric, 1) AS avg_s,
                            round(max(r.duration_secs)::numeric, 1) AS max_s
                       FROM pgvigil.job_runs r
                      WHERE r.instance_id = j.instance_id AND r.scheduler = j.scheduler AND r.job_id = j.job_id
                        AND r.start_time > $2 AND r.start_time <= $3) c ON true
 WHERE j.instance_id = $1
 ORDER BY j.is_present DESC, (lr.outcome = 'failed') DESC NULLS LAST, name`

const sqlJobsGridMS = `
WITH ver AS (
  SELECT DISTINCT ON (v.job_id) v.job_id, v.job_name, v.dropped, v.valid_from, v.definition
    FROM pgvigil.job_versions v
   WHERE v.instance_id = $1 AND v.scheduler = 'sqlagent'
   ORDER BY v.job_id, v.valid_from DESC
), jobs AS (
  SELECT j.job_id, j.name, j.enabled, coalesce(j.schedule_text, j.schedule_names) AS schedule, j.last_run_at, j.last_duration_s,
         CASE WHEN j.running_since IS NOT NULL THEN 'running'
              ELSE CASE j.last_outcome WHEN 0 THEN 'failed' WHEN 1 THEN 'succeeded' WHEN 2 THEN 'retry' WHEN 3 THEN 'cancelled'
                                       WHEN 5 THEN 'never run' END END AS last_outcome,
         j.next_run_at AS next_run, NULL::timestamptz AS dropped_at, j.owner, j.category
    FROM pgvigil.mssql_jobs j WHERE j.instance_id = $1
  UNION ALL
  SELECT ver.job_id, ver.job_name, (ver.definition->>'enabled')::boolean,
         (SELECT string_agg(x.value->>'runs', '; ' ORDER BY x.key) FROM jsonb_each(ver.definition->'schedules') x), NULL, NULL, NULL, NULL, ver.valid_from,
         ver.definition->>'owner', ver.definition->>'category'
    FROM ver WHERE ver.dropped AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_jobs j WHERE j.instance_id = $1 AND j.job_id = ver.job_id)
)
SELECT 'sqlagent' AS scheduler, j.job_id, j.name, j.enabled, j.schedule,
       coalesce(j.last_run_at, lr.snapshot_at) AS last_run_at, coalesce(j.last_outcome, lr.outcome) AS last_outcome,
       coalesce(j.last_duration_s, lr.duration_s) AS last_duration_s,
       lf.snapshot_at AS last_failed_at,
       CASE WHEN lf.failed_step_id IS NOT NULL THEN lf.failed_step_id || ' ' || coalesce(lf.failed_step_name, '') END AS failed_step,
       coalesce(lf.failed_message, lf.message) AS last_failure, lf.failed_sql_message_id AS last_failure_error,
       j.next_run, coalesce(c.runs, 0) AS runs, coalesce(c.failures, 0) AS failures, c.avg_s, c.max_s, j.owner, j.category,
       (SELECT count(*) FROM pgvigil.job_versions v
         WHERE v.instance_id = $1 AND v.scheduler = 'sqlagent' AND v.job_id = j.job_id AND v.version_no > 1
           AND v.valid_from > $2 AND v.valid_from <= $3) AS changes,
       (SELECT max(v.valid_from) FROM pgvigil.job_versions v
         WHERE v.instance_id = $1 AND v.scheduler = 'sqlagent' AND v.job_id = j.job_id AND v.version_no > 1) AS last_change_at,
       j.dropped_at
  FROM jobs j
  -- a dropped job's last run comes from its history (mssql_jobs no longer has it)
  LEFT JOIN LATERAL (SELECT r.snapshot_at, r.duration_s, ` + msOutcome + ` AS outcome
                       FROM pgvigil.mssql_job_runs r
                      WHERE j.dropped_at IS NOT NULL AND r.instance_id = $1 AND r.job_id = j.job_id AND r.step_id = 0
                      ORDER BY r.snapshot_at DESC LIMIT 1) lr ON true
  LEFT JOIN LATERAL (SELECT r.snapshot_at, r.failed_step_id, r.failed_step_name, r.failed_message, r.message, r.failed_sql_message_id
                       FROM pgvigil.mssql_job_runs r
                      WHERE r.instance_id = $1 AND r.job_id = j.job_id AND r.step_id = 0 AND r.run_status = 0
                      ORDER BY r.snapshot_at DESC LIMIT 1) lf ON true
  LEFT JOIN LATERAL (SELECT count(*) AS runs, count(*) FILTER (WHERE r.run_status = 0) AS failures,
                            round(avg(r.duration_s) FILTER (WHERE r.run_status = 1)) AS avg_s, max(r.duration_s) AS max_s
                       FROM pgvigil.mssql_job_runs r
                      WHERE r.instance_id = $1 AND r.job_id = j.job_id AND r.step_id = 0
                        AND r.snapshot_at > $2 AND r.snapshot_at <= $3) c ON true
 ORDER BY (j.dropped_at IS NULL) DESC, (j.last_outcome = 'failed') DESC NULLS LAST, j.name`

// the picked job's runs in the range, one shape for both engines ($4 scheduler, $5 job id as text, $6 the step or
// NULL), no limit: the runs part takes the newest 1,000 of them (jobRunsLimit), the counts part all of them. The
// PostgreSQL text names $6 too (always NULL there: the handler refuses a step), or the server could not type it.
const sqlJobRunsPG = `
SELECT r.start_time, r.duration_secs AS duration_s, ` + pgOutcome + ` AS outcome, r.failed_step,
       left(r.return_message, 4000) AS message, NULL::int AS sql_message_id, NULL::int AS sql_severity, NULL::int AS retries,
       r.run_id::text AS run_id
  FROM pgvigil.job_runs r
 WHERE r.instance_id = $1 AND r.scheduler = $4 AND r.job_id::text = $5 AND r.start_time > $2 AND r.start_time <= $3
   AND $6::int IS NULL`

const sqlJobRunsMS = `
SELECT j.running_since AS start_time, extract(epoch FROM j.snapshot_at - j.running_since)::bigint AS duration_s, 'running' AS outcome,
       CASE WHEN j.running_after_step > 0 THEN 'after step ' || j.running_after_step END AS failed_step,
       NULL::text AS message, NULL::int AS sql_message_id, NULL::int AS sql_severity, NULL::int AS retries, NULL::text AS run_id
  FROM pgvigil.mssql_jobs j
 WHERE j.instance_id = $1 AND $4 = 'sqlagent' AND j.job_id = $5 AND j.running_since > $2 AND j.running_since <= $3
   AND $6::int IS NULL
UNION ALL
-- the job's outcome rows (step 0) with the step that failed, or with a step picked that step's own rows (the
-- 'step that failed' cell then only on the rows where that step failed)
SELECT r.snapshot_at, r.duration_s, ` + msOutcome + `,
       CASE WHEN r.step_id > 0 THEN CASE WHEN r.run_status = 0 THEN r.step_id || ' ' || coalesce(r.step_name, '') END
            WHEN r.failed_step_id IS NOT NULL THEN r.failed_step_id || ' ' || coalesce(r.failed_step_name, '') END,
       CASE WHEN r.step_id > 0 THEN r.message ELSE coalesce(r.failed_message, r.message) END,
       CASE WHEN r.step_id > 0 THEN r.sql_message_id ELSE r.failed_sql_message_id END,
       CASE WHEN r.step_id > 0 THEN r.sql_severity ELSE r.failed_sql_severity END,
       CASE WHEN r.step_id > 0 THEN r.retries ELSE r.step_retries END, r.history_id::text
  FROM pgvigil.mssql_job_runs r
 WHERE r.instance_id = $1 AND $4 = 'sqlagent' AND r.job_id = $5 AND r.step_id = coalesce($6::int, 0)
   AND r.snapshot_at > $2 AND r.snapshot_at <= $3`

// jobRunsLimit is the most runs the history grid lists (the newest); the counts cover every run of the range
const jobRunsLimit = `
SELECT * FROM (%s) x ORDER BY x.start_time DESC LIMIT 1000`

// the counts over every run of the range (the runs query is wrapped around it)
const sqlJobCounts = `
WITH x AS (%s), m AS (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_s) AS median FROM x WHERE outcome = 'succeeded')
SELECT count(*) AS runs, count(*) FILTER (WHERE outcome = 'succeeded') AS succeeded,
       count(*) FILTER (WHERE outcome = 'failed') AS failed, count(*) FILTER (WHERE outcome = 'cancelled') AS cancelled,
       count(*) FILTER (WHERE outcome = 'running') AS running,
       count(*) FILTER (WHERE outcome <> 'running' AND duration_s > 2 * m.median) AS running_long,
       round(m.median::numeric, 1) AS median_s
  FROM x, m GROUP BY m.median`

// the job's runs per step over the range (DBA Dash's Job Stats grid): SQL Server from msdb's rows, step 0 being the
// job's own outcome; PostgreSQL the outcome row alone
const sqlJobStatsMS = `
SELECT r.step_id, CASE WHEN r.step_id = 0 THEN '(job outcome)' ELSE max(r.step_name) END AS step_name,
       count(*) FILTER (WHERE r.run_status = 0) AS failed, count(*) FILTER (WHERE r.run_status = 1) AS succeeded,
       count(*) FILTER (WHERE r.run_status = 2) AS retry, count(*) FILTER (WHERE r.run_status = 3) AS cancelled,
       round(avg(r.duration_s)::numeric, 1) AS avg_s, max(r.duration_s) AS max_s, min(r.duration_s) AS min_s,
       sum(r.duration_s) AS total_s, max(r.snapshot_at) AS last_run_at
  FROM pgvigil.mssql_job_runs r
 WHERE r.instance_id = $1 AND $4 = 'sqlagent' AND r.job_id = $5 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
 GROUP BY r.step_id
 ORDER BY r.step_id`

const sqlJobStatsPG = `
SELECT 0 AS step_id, '(job outcome)' AS step_name,
       count(*) FILTER (WHERE x.outcome = 'failed') AS failed, count(*) FILTER (WHERE x.outcome = 'succeeded') AS succeeded,
       0::bigint AS retry, count(*) FILTER (WHERE x.outcome = 'cancelled') AS cancelled,
       round(avg(x.duration_s)::numeric, 1) AS avg_s, round(max(x.duration_s)::numeric, 1) AS max_s,
       round(min(x.duration_s)::numeric, 1) AS min_s, round(sum(x.duration_s)::numeric, 1) AS total_s,
       max(x.start_time) AS last_run_at
  FROM (SELECT r.start_time, r.duration_secs AS duration_s, ` + pgOutcome + ` AS outcome
          FROM pgvigil.job_runs r
         WHERE r.instance_id = $1 AND r.scheduler = $4 AND r.job_id::text = $5 AND r.start_time > $2 AND r.start_time <= $3) x
HAVING count(*) > 0`

// the runs of the range in buckets of $7 seconds (the runs query is wrapped around it), every bucket of the range a
// row: a bucket without a run counts 0 and has no duration. snapshot_at is the bucket's start (the chart's x). Each
// run is given its bucket first and the buckets are joined on equality: one pass over the runs, whatever their
// number. A run still going (a SQL Server job running at the read) counts in 'other' and stays out of the
// durations: its time so far is not a duration.
const sqlJobSeries = `
WITH x AS (%s), g AS (
  SELECT to_timestamp(floor(extract(epoch FROM x.start_time) / $7::int) * $7::int) AS snapshot_at,
         count(*) AS runs,
         count(*) FILTER (WHERE x.outcome = 'succeeded') AS succeeded,
         count(*) FILTER (WHERE x.outcome = 'failed') AS failed,
         count(*) FILTER (WHERE coalesce(x.outcome, '') NOT IN ('succeeded', 'failed')) AS other,
         round(avg(x.duration_s) FILTER (WHERE coalesce(x.outcome, '') <> 'running')::numeric, 1) AS avg_s,
         round(max(x.duration_s) FILTER (WHERE coalesce(x.outcome, '') <> 'running')::numeric, 1) AS max_s
    FROM x
   WHERE x.start_time IS NOT NULL
   GROUP BY 1
), b AS (
  SELECT k AS snapshot_at
    FROM generate_series(to_timestamp(floor(extract(epoch FROM $2::timestamptz) / $7::int) * $7::int), $3::timestamptz,
                         make_interval(secs => $7::int)) k
)
SELECT b.snapshot_at, coalesce(g.runs, 0) AS runs, coalesce(g.succeeded, 0) AS succeeded, coalesce(g.failed, 0) AS failed,
       coalesce(g.other, 0) AS other, g.avg_s, g.max_s
  FROM b
  LEFT JOIN g ON g.snapshot_at = b.snapshot_at
 ORDER BY b.snapshot_at`

// jobSeriesStep is the series' bucket width in seconds: about 120 buckets over the range, a whole number of minutes.
func jobSeriesStep(rangeSecs float64) int {
	step := int(math.Ceil(rangeSecs/120/60)) * 60
	if step < 60 {
		step = 60
	}
	return step
}

const sqlJobChanges = `
SELECT v.valid_from, v.version_no, v.dropped, v.job_name, v.changes, v.definition
  FROM pgvigil.job_versions v
 WHERE v.instance_id = $1 AND v.scheduler = $2 AND v.job_id = $3
 ORDER BY v.valid_from DESC
 LIMIT 200`

// JobsHistory serves the Jobs grid of one instance of either engine and, with ?scheduler=&job=, the job's runs,
// their counts and the changes to its definition.
func (s *Server) JobsHistory(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	grid, runs, stats := sqlJobsGridPG, sqlJobRunsPG, sqlJobStatsPG
	mssql := false
	switch q.Get("engine") {
	case "pg", "":
	case "mssql":
		grid, runs, stats, mssql = sqlJobsGridMS, sqlJobRunsMS, sqlJobStatsMS, true
	default:
		writeErr(w, http.StatusBadRequest, errors.New("engine must be pg or mssql"))
		return
	}
	parts := []part{{"jobs", grid, []any{id, from, to}}}
	if sch, job := q.Get("scheduler"), q.Get("job"); sch != "" || job != "" {
		if sch == "" || job == "" || len(sch) > 16 || len(job) > 64 {
			writeErr(w, http.StatusBadRequest, errors.New("scheduler and job go together"))
			return
		}
		// the step cut: SQL Server only (msdb's step rows are stored; a PostgreSQL scheduler's are not)
		var step *int
		if v := q.Get("step"); v != "" {
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 || n > 100000 {
				writeErr(w, http.StatusBadRequest, errors.New("step must be a step id (1 or more)"))
				return
			}
			if !mssql {
				writeErr(w, http.StatusBadRequest, errors.New("step needs engine=mssql: the repository holds no step rows of a PostgreSQL scheduler"))
				return
			}
			step = &n
		}
		bucket := jobSeriesStep(to.Sub(from).Seconds())
		parts = append(parts,
			part{"runs", fmt.Sprintf(jobRunsLimit, runs), []any{id, from, to, sch, job, step}},
			part{"counts", fmt.Sprintf(sqlJobCounts, runs), []any{id, from, to, sch, job, step}},
			part{"changes", sqlJobChanges, []any{id, sch, job}},
			part{"stats", stats, []any{id, from, to, sch, job}},
			part{"series", fmt.Sprintf(sqlJobSeries, runs), []any{id, from, to, sch, job, step, bucket}},
			part{"series_meta", `SELECT $1::int AS step_secs, $2::int AS step`, []any{bucket, step}})
	} else if q.Get("step") != "" {
		writeErr(w, http.StatusBadRequest, errors.New("step needs scheduler and job"))
		return
	}
	s.multiPart(w, r, parts)
}
