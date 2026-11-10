package web

import (
	"errors"
	"net/http"
)

// The jobs timeline on both engines (parity2 task 121; DBA Dash 71 and 90): every run that overlaps the window as a
// bar, one row per job; the page draws the bars, the failed runs in red with a count, the 'running at once' lane with
// its peak and the time cursor.
//
// GET /api/jobs/timeline?[instance=<id>]&[from=&to=]&[scheduler=&job=] (Server.JobsTimeline); without instance the
// fleet's active instances of both engines:
//   runs   instance_id, instance, engine, scheduler, job_id, job (name), start_time, end_time (NULL = still running),
//          duration_s, outcome (succeeded / failed / cancelled / retry / running), failed_step, message (300
//          characters), run_id; a run that started before the window and was still running in it is included. At
//          most 5,000 runs, the newest first; meta says when there were more.
//   steps  with scheduler=sqlagent&job=<id> (DBA Dash 90, one job): its runs' step rows in the window (step id and
//          name, start, duration, outcome) - pg_cron has no steps and pgAgent's step log is not stored per run
//   meta   the runs that matched and the runs listed
//
// A SQL Server run's start is msdb's run_date and run_time as the collector converted it (mssql_job_runs.snapshot_at,
// 0066); its end is that start plus the duration. A pg_cron or pgAgent run's start and end are its own. The route is
// the lead's line in web.go.

// sqlTimelineRuns: $1 instance (NULL = the fleet), $2 from, $3 to, $4 scheduler (NULL = all), $5 job id as text
// (NULL = all). A run is in the window when it started at or before its end and had not ended at its start; the
// start is looked up no further than a day before the window (a job run longer than a day is cut there).
const sqlTimelineRuns = `
WITH runs AS (
  SELECT r.instance_id, 'postgres'::text AS engine, r.scheduler, r.job_id::text AS job_id,
         coalesce(j.job_name, r.job_id::text) AS job, r.start_time,
         CASE WHEN r.end_time IS NOT NULL THEN r.end_time
              WHEN r.duration_secs IS NOT NULL AND r.status IS DISTINCT FROM 'running' THEN r.start_time + make_interval(secs => r.duration_secs) END AS end_time,
         r.duration_secs AS duration_s, ` + pgOutcome + ` AS outcome, r.failed_step,
         left(r.return_message, 300) AS message, r.run_id::text AS run_id
    FROM pgvigil.job_runs r
    LEFT JOIN pgvigil.jobs j ON j.instance_id = r.instance_id AND j.scheduler = r.scheduler AND j.job_id = r.job_id
   WHERE ($1::int IS NULL OR r.instance_id = $1)
     AND r.start_time > $2::timestamptz - interval '1 day' AND r.start_time <= $3
     AND ($4::text IS NULL OR r.scheduler = $4) AND ($5::text IS NULL OR r.job_id::text = $5)
  UNION ALL
  SELECT r.instance_id, 'sqlserver', 'sqlagent', r.job_id, coalesce(r.job_name, r.job_id), r.snapshot_at,
         r.snapshot_at + make_interval(secs => coalesce(r.duration_s, 0)), r.duration_s::float8, ` + msOutcome + `,
         CASE WHEN r.failed_step_id IS NOT NULL THEN r.failed_step_id || ' ' || coalesce(r.failed_step_name, '') END,
         left(coalesce(r.failed_message, r.message), 300), r.history_id::text
    FROM pgvigil.mssql_job_runs r
   WHERE ($1::int IS NULL OR r.instance_id = $1) AND r.step_id = 0
     AND r.snapshot_at > $2::timestamptz - interval '1 day' AND r.snapshot_at <= $3
     AND ($4::text IS NULL OR $4 = 'sqlagent') AND ($5::text IS NULL OR r.job_id = $5)
  UNION ALL
  SELECT j.instance_id, 'sqlserver', 'sqlagent', j.job_id, j.name, j.running_since, NULL::timestamptz,
         extract(epoch FROM j.snapshot_at - j.running_since)::float8, 'running',
         CASE WHEN j.running_after_step > 0 THEN 'after step ' || j.running_after_step END, NULL::text, NULL::text
    FROM pgvigil.mssql_jobs j
   WHERE ($1::int IS NULL OR j.instance_id = $1) AND j.running_since IS NOT NULL AND j.running_since <= $3
     AND ($4::text IS NULL OR $4 = 'sqlagent') AND ($5::text IS NULL OR j.job_id = $5)
), w AS (
  SELECT x.*, i.name AS instance
    FROM runs x
    JOIN pgvigil.instances i USING (instance_id)
   WHERE ($1::int IS NOT NULL OR i.is_active)
     AND (x.end_time IS NULL OR x.end_time >= $2)
)`

const sqlTimelineList = sqlTimelineRuns + `
SELECT instance_id, instance, engine, scheduler, job_id, job, start_time, end_time, duration_s, outcome, failed_step,
       message, run_id
  FROM w
 ORDER BY start_time DESC
 LIMIT 5000`

const sqlTimelineMeta = sqlTimelineRuns + `
SELECT count(*) AS matched, least(count(*), 5000) AS listed FROM w`

// the step rows of one SQL Server job's runs in the window ($1 instance, $2 from, $3 to, $4 job id)
const sqlTimelineSteps = `
SELECT r.step_id, r.step_name, r.snapshot_at AS start_time,
       r.snapshot_at + make_interval(secs => coalesce(r.duration_s, 0)) AS end_time, r.duration_s,
       ` + msOutcome + ` AS outcome, left(r.message, 300) AS message
  FROM pgvigil.mssql_job_runs r
 WHERE r.instance_id = $1 AND r.job_id = $4 AND r.step_id > 0
   AND r.snapshot_at > $2::timestamptz - interval '1 day' AND r.snapshot_at <= $3
   AND r.snapshot_at + make_interval(secs => coalesce(r.duration_s, 0)) >= $2
 ORDER BY r.snapshot_at, r.step_id
 LIMIT 5000`

// JobsTimeline serves the jobs timeline of one instance, or of the fleet without ?instance=.
func (s *Server) JobsTimeline(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	fleet := q.Get("instance") == ""
	id, from, to, err := params(r, !fleet)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var inst, sch, job any
	if !fleet {
		inst = id
	}
	if vs, vj := q.Get("scheduler"), q.Get("job"); vs != "" || vj != "" {
		switch {
		case vs == "" || vj == "":
			writeErr(w, http.StatusBadRequest, errors.New("scheduler and job go together"))
			return
		case fleet:
			writeErr(w, http.StatusBadRequest, errors.New("a job is picked on one instance: instance goes with job"))
			return
		case vs != "pg_cron" && vs != "pgagent" && vs != "sqlagent":
			writeErr(w, http.StatusBadRequest, errors.New("scheduler must be pg_cron, pgagent or sqlagent"))
			return
		case len(vj) > 64:
			writeErr(w, http.StatusBadRequest, errors.New("job must be at most 64 characters"))
			return
		}
		sch, job = vs, vj
	}
	args := []any{inst, from, to, sch, job}
	parts := []part{
		{"runs", sqlTimelineList, args},
		{"meta", sqlTimelineMeta, args},
	}
	if sch == "sqlagent" {
		parts = append(parts, part{"steps", sqlTimelineSteps, []any{id, from, to, job}})
	}
	s.multi(w, r, parts)
}
