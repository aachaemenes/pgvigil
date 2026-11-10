package web

import (
	"errors"
	"fmt"
	"net/http"
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
       coalesce(c.runs, 0) AS runs, coalesce(c.failures, 0) AS failures,
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
  LEFT JOIN LATERAL (SELECT count(*) AS runs, count(*) FILTER (WHERE r.status IN ('failed', 'internal error')) AS failures
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
         j.next_run_at AS next_run, NULL::timestamptz AS dropped_at
    FROM pgvigil.mssql_jobs j WHERE j.instance_id = $1
  UNION ALL
  SELECT ver.job_id, ver.job_name, (ver.definition->>'enabled')::boolean, NULL, NULL, NULL, NULL, NULL, ver.valid_from
    FROM ver WHERE ver.dropped AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_jobs j WHERE j.instance_id = $1 AND j.job_id = ver.job_id)
)
SELECT 'sqlagent' AS scheduler, j.job_id, j.name, j.enabled, j.schedule, j.last_run_at, j.last_outcome, j.last_duration_s,
       lf.snapshot_at AS last_failed_at,
       CASE WHEN lf.failed_step_id IS NOT NULL THEN lf.failed_step_id || ' ' || coalesce(lf.failed_step_name, '') END AS failed_step,
       coalesce(lf.failed_message, lf.message) AS last_failure, lf.failed_sql_message_id AS last_failure_error,
       j.next_run, coalesce(c.runs, 0) AS runs, coalesce(c.failures, 0) AS failures,
       (SELECT count(*) FROM pgvigil.job_versions v
         WHERE v.instance_id = $1 AND v.scheduler = 'sqlagent' AND v.job_id = j.job_id AND v.version_no > 1
           AND v.valid_from > $2 AND v.valid_from <= $3) AS changes,
       (SELECT max(v.valid_from) FROM pgvigil.job_versions v
         WHERE v.instance_id = $1 AND v.scheduler = 'sqlagent' AND v.job_id = j.job_id AND v.version_no > 1) AS last_change_at,
       j.dropped_at
  FROM jobs j
  LEFT JOIN LATERAL (SELECT r.snapshot_at, r.failed_step_id, r.failed_step_name, r.failed_message, r.message, r.failed_sql_message_id
                       FROM pgvigil.mssql_job_runs r
                      WHERE r.instance_id = $1 AND r.job_id = j.job_id AND r.step_id = 0 AND r.run_status = 0
                      ORDER BY r.snapshot_at DESC LIMIT 1) lf ON true
  LEFT JOIN LATERAL (SELECT count(*) AS runs, count(*) FILTER (WHERE r.run_status = 0) AS failures
                       FROM pgvigil.mssql_job_runs r
                      WHERE r.instance_id = $1 AND r.job_id = j.job_id AND r.step_id = 0
                        AND r.snapshot_at > $2 AND r.snapshot_at <= $3) c ON true
 ORDER BY (j.dropped_at IS NULL) DESC, (j.last_outcome = 'failed') DESC NULLS LAST, j.name`

// the picked job's runs, one shape for both engines ($4 scheduler, $5 job id as text)
const sqlJobRunsPG = `
SELECT r.start_time, r.duration_secs AS duration_s, ` + pgOutcome + ` AS outcome, r.failed_step,
       left(r.return_message, 4000) AS message, NULL::int AS sql_message_id, NULL::int AS sql_severity, NULL::int AS retries,
       r.run_id::text AS run_id
  FROM pgvigil.job_runs r
 WHERE r.instance_id = $1 AND r.scheduler = $4 AND r.job_id::text = $5 AND r.start_time > $2 AND r.start_time <= $3
 ORDER BY r.start_time DESC
 LIMIT 1000`

const sqlJobRunsMS = `
SELECT j.running_since AS start_time, extract(epoch FROM j.snapshot_at - j.running_since)::bigint AS duration_s, 'running' AS outcome,
       CASE WHEN j.running_after_step > 0 THEN 'after step ' || j.running_after_step END AS failed_step,
       NULL::text AS message, NULL::int AS sql_message_id, NULL::int AS sql_severity, NULL::int AS retries, NULL::text AS run_id
  FROM pgvigil.mssql_jobs j
 WHERE j.instance_id = $1 AND $4 = 'sqlagent' AND j.job_id = $5 AND j.running_since > $2 AND j.running_since <= $3
UNION ALL
(SELECT r.snapshot_at, r.duration_s, ` + msOutcome + `,
       CASE WHEN r.failed_step_id IS NOT NULL THEN r.failed_step_id || ' ' || coalesce(r.failed_step_name, '') END,
       coalesce(r.failed_message, r.message), r.failed_sql_message_id, r.failed_sql_severity, r.step_retries, r.history_id::text
  FROM pgvigil.mssql_job_runs r
 WHERE r.instance_id = $1 AND $4 = 'sqlagent' AND r.job_id = $5 AND r.step_id = 0 AND r.snapshot_at > $2 AND r.snapshot_at <= $3
 ORDER BY r.snapshot_at DESC
 LIMIT 1000)
 ORDER BY 1 DESC`

// the counts over the runs part's rows (the query is wrapped around it)
const sqlJobCounts = `
WITH x AS (%s), m AS (SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_s) AS median FROM x WHERE outcome = 'succeeded')
SELECT count(*) AS runs, count(*) FILTER (WHERE outcome = 'succeeded') AS succeeded,
       count(*) FILTER (WHERE outcome = 'failed') AS failed, count(*) FILTER (WHERE outcome = 'cancelled') AS cancelled,
       count(*) FILTER (WHERE outcome = 'running') AS running,
       count(*) FILTER (WHERE outcome <> 'running' AND duration_s > 2 * m.median) AS running_long,
       round(m.median::numeric, 1) AS median_s
  FROM x, m GROUP BY m.median`

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
	grid, runs := sqlJobsGridPG, sqlJobRunsPG
	switch q.Get("engine") {
	case "pg", "":
	case "mssql":
		grid, runs = sqlJobsGridMS, sqlJobRunsMS
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
		parts = append(parts,
			part{"runs", runs, []any{id, from, to, sch, job}},
			part{"counts", fmt.Sprintf(sqlJobCounts, runs), []any{id, from, to, sch, job}},
			part{"changes", sqlJobChanges, []any{id, sch, job}})
	}
	s.multiPart(w, r, parts)
}
