package collect

import (
	"context"
	"fmt"
	"regexp"
	"strings"
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
       j.jobnextrun AS next_run, j.joblastrun AS last_run,
       -- the definition whose versions are kept (task 110): the job, each schedule and each step; a step's code
       -- and connection string masked as a statement's text is
       jsonb_build_object('name', j.jobname, 'enabled', j.jobenabled, 'description', nullif(j.jobdesc, ''),
         'host agent', nullif(j.jobhostagent, ''),
         'schedules', coalesce((SELECT jsonb_object_agg(sc.jscname || ' #' || sc.jscid, jsonb_build_object(
             'enabled', sc.jscenabled, 'start', to_char(sc.jscstart AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC',
             'end', to_char(sc.jscend AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC',
             'minutes', pgvigil_bits(sc.jscminutes, 0), 'hours', pgvigil_bits(sc.jschours, 0),
             'weekdays', pgvigil_bits(sc.jscweekdays, 1), 'month days', regexp_replace(pgvigil_bits(sc.jscmonthdays, 1), '(^|,)32$', '\1last'),
             'months', pgvigil_bits(sc.jscmonths, 1)))
           FROM pgagent.pga_schedule sc WHERE sc.jscjobid = j.jobid), '{}'::jsonb),
         'steps', coalesce((SELECT jsonb_object_agg(st.jstname || ' #' || st.jstid, jsonb_build_object(
             'enabled', st.jstenabled, 'kind', CASE st.jstkind WHEN 's' THEN 'SQL' WHEN 'b' THEN 'batch' ELSE st.jstkind::text END,
             'database', nullif(st.jstdbname, ''), 'connection', nullif(%[1]s, ''),
             'on error', CASE st.jstonerror WHEN 'f' THEN 'fail' WHEN 's' THEN 'succeed' WHEN 'i' THEN 'ignore' ELSE st.jstonerror::text END,
             'command', %[2]s))
           FROM pgagent.pga_jobstep st WHERE st.jstjobid = j.jobid), '{}'::jsonb)) AS definition
  FROM pgagent.pga_job j`

// Masking of a job's text (a step's command or code, a connection string, a run's output), both engines: the value
// of every password-shaped item is replaced by <masked> before the row leaves the collector. Covered: T-SQL
// PASSWORD = '...' / SECRET = '...' and any @...password / @passwd / @...pwd / @...secret parameter; key = value
// pairs whose key holds password, passwd, pwd or secret (a connection string, libpq's keywords, quoted or not); the
// user:password@ of a URI; the -P of sqlcmd and bcp and -Password / -pw / -pwd of a command line; the string given
// to ConvertTo-SecureString; the password of 'net use \\host\share <password>'; dtexec's /DE and /Decrypt.
var (
	maskTSQLRE   = regexp.MustCompile(`(?i)((?:\bPASSWORD|\bSECRET|@\w*(?:password|passwd|pwd|secret)\w*)\s*=\s*)(N?'(?:[^']|'')*')`)
	maskKVRE     = regexp.MustCompile(`(?i)(\b\w*(?:password|passwd|pwd|secret)\w*\s*[=:]\s*)("[^"]*"|'(?:[^']|'')*'|[^;\s,)'"]+)`)
	maskURIRE    = regexp.MustCompile(`(://[^:/@\s]+:)([^@\s/]+)(@)`)
	maskArgRE    = regexp.MustCompile(`((?:^|\s)(?:(?i:-Password|-pwd|-pw)\b|-P)\s*)("[^"]*"|'[^']*'|\S+)`)
	maskSecureRE = regexp.MustCompile(`(?i)(ConvertTo-SecureString\s+(?:-String\s+)?)("[^"]*"|'[^']*'|\S+)`)
	maskNetUseRE = regexp.MustCompile(`(?i)(\bnet\s+use\s+\S+\s+)([^/\s]\S*)`)
	maskDtsRE    = regexp.MustCompile(`(?i)(/(?:DE|Decrypt)\s+)("[^"]*"|\S+)`)
)

// MaskJobText is a job's text with every password it carries, in the forms above, replaced by <masked>.
func MaskJobText(s string) string {
	s = maskTSQLRE.ReplaceAllString(s, "${1}'<masked>'")
	s = maskURIRE.ReplaceAllString(s, "${1}<masked>${3}")
	s = maskKVRE.ReplaceAllStringFunc(s, func(m string) string {
		g := maskKVRE.FindStringSubmatch(m)
		if strings.Contains(g[2], "<masked>") {
			return m
		}
		return g[1] + "<masked>"
	})
	s = maskArgRE.ReplaceAllString(s, "${1}<masked>")
	s = maskSecureRE.ReplaceAllString(s, "${1}<masked>")
	s = maskNetUseRE.ReplaceAllString(s, "${1}<masked>")
	return maskDtsRE.ReplaceAllString(s, "${1}<masked>")
}

// maskTree masks every string of a decoded jsonb value (a job's definition) in place.
func maskTree(v any) any {
	switch x := v.(type) {
	case string:
		return MaskJobText(x)
	case map[string]any:
		for k, e := range x {
			x[k] = maskTree(e)
		}
	case []any:
		for i, e := range x {
			x[i] = maskTree(e)
		}
	}
	return v
}

// pgagentBits is the positions of the true elements of a pgAgent schedule array, from base, as text (” = all
// false: pgAgent reads an all-false array as "any").
func pgagentBits(s string) string {
	return bitsRE.ReplaceAllStringFunc(s, func(m string) string {
		parts := bitsRE.FindStringSubmatch(m)
		return "(SELECT coalesce(string_agg((i - 1 + " + parts[2] + ")::text, ',' ORDER BY i), 'any') FROM unnest(" + parts[1] + ") WITH ORDINALITY u(b, i) WHERE b)"
	})
}

var bitsRE = regexp.MustCompile(`pgvigil_bits\(([a-z.]+), ([01])\)`)

// pgAgent's runs with the step that ended the run: a failed run's first failed step (its result and output), else
// the last step that ran.
const pgagentRunsSQL = `
SELECT 'run' AS kind, 'pgagent' AS scheduler, l.jlgjobid::bigint AS job_id, l.jlgid::bigint AS run_id, NULL::int AS job_pid,
       NULL::text AS datname, NULL::text AS run_as, NULL::text AS command,
       CASE l.jlgstatus WHEN 's' THEN 'succeeded' WHEN 'f' THEN 'failed' WHEN 'i' THEN 'internal error'
                        WHEN 'd' THEN 'aborted' WHEN 'r' THEN 'running' ELSE l.jlgstatus END AS status,
       left(fs.jsloutput, 4000) AS return_message, fs.jstname AS failed_step, fs.jslresult AS step_result, l.jlgstart AS start_time,
       CASE WHEN l.jlgstatus = 'r' THEN NULL ELSE l.jlgstart + l.jlgduration END AS end_time,
       extract(epoch FROM l.jlgduration) AS duration_secs
  FROM pgagent.pga_joblog l
  LEFT JOIN LATERAL (SELECT st.jstname, sl.jslresult, %s AS jsloutput
                       FROM pgagent.pga_jobsteplog sl
                       LEFT JOIN pgagent.pga_jobstep st ON st.jstid = sl.jsljstid
                      WHERE sl.jsljlgid = l.jlgid
                      ORDER BY (sl.jslstatus IN ('f', 'i')) DESC, sl.jslstart DESC LIMIT 1) fs
         ON l.jlgstatus IN ('f', 'i', 'd')
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
		cs := ReadCronSettings(ctx, conn) // the server's clock rides in cs.Now: the runs' start_time is on it
		AddCronTimes(out, cs.Now, cs)
	}
	defer func() {
		for _, r := range out {
			for _, k := range []string{"command", "return_message"} {
				if t, ok := r[k].(string); ok {
					r[k] = MaskJobText(t)
				}
			}
			if d, ok := r["definition"]; ok {
				r["definition"] = maskTree(d)
			}
		}
	}()
	if info.HasPgAgent {
		if err := run("pgagent.pga_job", pgagentBits(fmt.Sprintf(pgagentJobsSQL, maskSQL("st.jstconnstr"), maskSQL("st.jstcode")))); err != nil {
			return nil, err
		}
		if err := run("pgagent.pga_joblog", fmt.Sprintf(pgagentRunsSQL, maskSQL("sl.jsloutput"))); err != nil {
			return nil, err
		}
	}
	return out, nil
}
