package collect

import (
	"context"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/platform"
)

// jobsCollector is the Agent Jobs page of Postgres: pg_cron's job table and its
// run history, and pgAgent's jobs and log where that is installed instead. It
// applies only where one of them exists in the connected database; OS cron is
// invisible to SQL and stays out of scope. Every minute, so a failed run shows
// within the minute; run rows are stored once by (jobid, runid) and the import
// skips the ones already there.
type jobsCollector struct{}

func init() { Register(jobsCollector{}) }

func (jobsCollector) Name() string                   { return "jobs" }
func (jobsCollector) DefaultInterval() time.Duration { return time.Minute }
func (jobsCollector) Applies(info platform.Info) (bool, string) {
	if !info.HasPgCron && !info.HasPgAgent {
		return false, "neither pg_cron nor pgAgent is installed in the connected database (pg_cron lives in cron.database_name, usually postgres)"
	}
	return true, ""
}

// pg_cron: cron.job (jobname from 1.3) and cron.job_run_details (1.4+); the
// last day of runs, so a run that started over an hour ago and then ends is
// still read once more and closed; the import de-duplicates.
// pg_cron's row-level security shows a non-superuser only its own jobs: the
// monitoring login needs bypassrls or superuser-equivalent rights to see all.
const cronJobsSQL = `
SELECT 'job' AS kind, 'pg_cron' AS scheduler, j.jobid::bigint AS job_id, %s AS job_name, j.schedule, j.command,
       j.database::text AS datname, j.username::text AS run_as, j.active, j.nodename, j.nodeport
  FROM cron.job j`

const cronRunsSQL = `
SELECT 'run' AS kind, 'pg_cron' AS scheduler, r.jobid::bigint AS job_id, r.runid::bigint AS run_id, r.job_pid,
       r.database::text AS datname, r.username::text AS run_as, r.command, r.status, r.return_message,
       r.start_time, r.end_time, extract(epoch FROM r.end_time - r.start_time) AS duration_secs
  FROM cron.job_run_details r
 WHERE r.start_time > now() - interval '1 day' OR r.end_time IS NULL`

const pgagentJobsSQL = `
SELECT 'job' AS kind, 'pgagent' AS scheduler, j.jobid::bigint AS job_id, j.jobname AS job_name,
       NULL::text AS schedule, NULL::text AS command, NULL::text AS datname, NULL::text AS run_as,
       j.jobenabled AS active, j.jobhostagent AS nodename, NULL::int AS nodeport,
       j.jobnextrun AS next_run, j.joblastrun AS last_run
  FROM pgagent.pga_job j`

const pgagentRunsSQL = `
SELECT 'run' AS kind, 'pgagent' AS scheduler, l.jlgjobid::bigint AS job_id, l.jlgid::bigint AS run_id, NULL::int AS job_pid,
       NULL::text AS datname, NULL::text AS run_as, NULL::text AS command,
       CASE l.jlgstatus WHEN 's' THEN 'succeeded' WHEN 'f' THEN 'failed' WHEN 'i' THEN 'internal error'
                        WHEN 'd' THEN 'aborted' WHEN 'r' THEN 'running' ELSE l.jlgstatus END AS status,
       NULL::text AS return_message, l.jlgstart AS start_time,
       CASE WHEN l.jlgstatus = 'r' THEN NULL ELSE l.jlgstart + l.jlgduration END AS end_time,
       extract(epoch FROM l.jlgduration) AS duration_secs
  FROM pgagent.pga_joblog l
 WHERE l.jlgstart > now() - interval '1 day' OR l.jlgstatus = 'r'`

func (jobsCollector) Run(ctx context.Context, conn *pgx.Conn, info platform.Info) ([]Row, error) {
	out := []Row{}
	run := func(label, sql string) error {
		rows, err := conn.Query(ctx, sql)
		if err != nil {
			return fmt.Errorf("%s: %w", label, err)
		}
		r, err := rowsToMaps(rows)
		if err != nil {
			return fmt.Errorf("%s: %w", label, err)
		}
		out = append(out, r...)
		return nil
	}
	if info.HasPgCron {
		cols, err := viewColumns(ctx, conn, "cron.job")
		if err != nil {
			return nil, err
		}
		if err := run("cron.job", fmt.Sprintf(cronJobsSQL, col(cols, "j", "jobname", "text"))); err != nil {
			return nil, err
		}
		if err := run("cron.job_run_details", cronRunsSQL); err != nil {
			return nil, err
		}
	}
	if info.HasPgAgent {
		if err := run("pgagent.pga_job", pgagentJobsSQL); err != nil {
			return nil, err
		}
		if err := run("pgagent.pga_joblog", pgagentRunsSQL); err != nil {
			return nil, err
		}
	}
	return out, nil
}
