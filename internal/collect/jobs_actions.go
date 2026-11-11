package collect

// Two things the Jobs page of a PostgreSQL instance needs beyond the jobs collection (task 161):
//
//   - the collection job_steps: pgAgent's step log (pgagent.pga_jobsteplog), one row per step run, so a step has its
//     own outcomes and durations (DBA Dash's per-step job stats) and the Running now grid its current step;
//   - the job actions of the actions door: Stop a running pg_cron or pgAgent run (pg_cancel_backend on the backend that
//     runs it) and Run now for a pgAgent job (jobnextrun = now(), what pgAdmin's Run now does). pg_cron has no run-now
//     call. Both are checked through the instance's monitoring login and sent through the actions login
//     (pgvigil_actions), as cancel and terminate are (internal/actions); the HTTP side and the audit row are
//     internal/web/q_jobs_actions.go.
//
// Finding the backend of a run: pg_cron records it (cron.job_run_details.job_pid; the backend is a client backend with
// application_name 'pg_cron', the job's user and database). pgAgent records no pid: a step runs on a connection of the
// pgAgent daemon with no application_name, so the backend is the one active session of the step's database whose
// statement is the step's code and started no earlier than the step; none or several = refused, nothing is sent.

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/platform"
)

type jobStepsCollector struct{}

func init() { Register(jobStepsCollector{}) }

func (jobStepsCollector) Name() string                   { return "job_steps" }
func (jobStepsCollector) DefaultInterval() time.Duration { return time.Minute }
func (jobStepsCollector) Applies(info platform.Info) (bool, string) {
	if !info.HasPgAgent {
		return false, "pgAgent is not installed in the connected database (pg_cron jobs have no steps)"
	}
	return true, ""
}

// pgAgent's step runs of the last day and the ones still running; a step's output masked as a run's message is.
// jslstatus: r running, s succeeded, f failed, i a failure the step's 'on error = ignore' passed over, d aborted.
const jobStepsSQL = `
SELECT l.jlgjobid::bigint AS job_id, sl.jsljlgid::bigint AS run_id, sl.jslid::bigint AS step_log_id, sl.jsljstid::bigint AS step_id,
       st.jstname AS step_name,
       CASE sl.jslstatus WHEN 's' THEN 'succeeded' WHEN 'f' THEN 'failed' WHEN 'i' THEN 'ignored' WHEN 'd' THEN 'aborted'
                         WHEN 'r' THEN 'running' ELSE sl.jslstatus::text END AS status,
       sl.jslresult AS result, sl.jslstart AS start_time,
       CASE WHEN sl.jslstatus = 'r' THEN NULL ELSE sl.jslstart + sl.jslduration END AS end_time,
       extract(epoch FROM sl.jslduration) AS duration_secs, left(%s, 4000) AS output
  FROM pgagent.pga_jobsteplog sl
  JOIN pgagent.pga_joblog l ON l.jlgid = sl.jsljlgid
  LEFT JOIN pgagent.pga_jobstep st ON st.jstid = sl.jsljstid
 WHERE sl.jslstart > now() - interval '1 day' OR sl.jslstatus = 'r'`

func (jobStepsCollector) Run(ctx context.Context, conn *pgx.Conn, _ platform.Info) ([]Row, error) {
	rows, err := conn.Query(ctx, fmt.Sprintf(jobStepsSQL, maskSQL("sl.jsloutput")))
	if err != nil {
		return nil, fmt.Errorf("pgagent.pga_jobsteplog: %w", err)
	}
	out, err := rowsToMaps(rows)
	if err != nil {
		return nil, fmt.Errorf("pgagent.pga_jobsteplog: %w", err)
	}
	for _, r := range out {
		if t, ok := r["output"].(string); ok {
			r["output"] = MaskJobText(t)
		}
	}
	return out, nil
}

// The job actions.
const (
	JobStop  = "job_stop"  // cancel the backend of a running run
	JobStart = "job_start" // pgAgent: run now
)

// JobActionRequest is one job action as the UI sent it: the job and, for a stop, the run as the Running now grid
// showed it.
type JobActionRequest struct {
	InstanceID int
	Instance   string
	Kind       string // JobStop or JobStart
	Scheduler  string // pg_cron or pgagent
	JobID      int64
	JobName    string // as shown: a job renamed since is refused
	RunID      int64  // stop: the run
	PID        int    // stop, pg_cron: the run's job_pid as shown
	Reason     string
	User       string
	Client     string
}

// JobActionResult is the outcome with what the check learnt about the target.
type JobActionResult struct {
	Outcome      actions.Outcome `json:"outcome"`
	Detail       string          `json:"detail"`
	PID          int             `json:"pid,omitempty"`
	BackendStart *time.Time      `json:"backend_start,omitempty"`
	TargetUser   string          `json:"target_user,omitempty"`
	TargetApp    string          `json:"target_app,omitempty"`
	Datname      string          `json:"datname,omitempty"`
	Statement    string          `json:"statement,omitempty"`
}

// ValidateJobAction checks the request's own shape (no connection needed).
func ValidateJobAction(r JobActionRequest) error {
	switch {
	case r.Kind != JobStop && r.Kind != JobStart:
		return fmt.Errorf("unknown job action %q", r.Kind)
	case r.Scheduler != "pg_cron" && r.Scheduler != "pgagent":
		return errors.New("scheduler must be pg_cron or pgagent")
	case r.Kind == JobStart && r.Scheduler == "pg_cron":
		return errors.New("pg_cron has no run-now call: a pg_cron job runs at its schedule only")
	case r.JobID <= 0:
		return errors.New("job_id must be a positive job id")
	case strings.TrimSpace(r.JobName) == "" || len(r.JobName) > 300:
		return errors.New("the job's name as shown is required (300 characters at most)")
	case r.Kind == JobStop && r.RunID <= 0:
		return errors.New("a stop names the run (run_id)")
	case r.Kind == JobStop && r.Scheduler == "pg_cron" && r.PID <= 0:
		return errors.New("a pg_cron stop names the run's job_pid as shown")
	case len([]rune(strings.TrimSpace(r.Reason))) < actions.MinReason:
		return fmt.Errorf("a reason of at least %d characters is required", actions.MinReason)
	case len([]rune(r.Reason)) > actions.MaxReason:
		return fmt.Errorf("the reason is longer than %d characters", actions.MaxReason)
	case strings.ContainsRune(r.Reason, 0) || strings.ContainsRune(r.JobName, 0):
		return errors.New("the request holds a NUL character")
	case strings.TrimSpace(r.User) == "":
		return errors.New("no UI user: actions need the UI login")
	}
	return nil
}

func jobRefused(format string, a ...any) JobActionResult {
	return JobActionResult{Outcome: actions.Refused, Detail: fmt.Sprintf(format, a...)}
}

// jobConn opens a short-lived connection that cannot hang on a busy server; readOnly for every connection but the
// one that writes pgAgent's jobnextrun.
func jobConn(ctx context.Context, dsn, app string, readOnly bool) (*pgx.Conn, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, err
	}
	if cfg.ConnectTimeout == 0 || cfg.ConnectTimeout > 10*time.Second {
		cfg.ConnectTimeout = 10 * time.Second
	}
	rp := cfg.RuntimeParams
	rp["application_name"] = app
	rp["statement_timeout"] = "5000"
	rp["lock_timeout"] = "1000"
	if readOnly {
		rp["default_transaction_read_only"] = "on"
	} else {
		delete(rp, "default_transaction_read_only")
	}
	return pgx.ConnectConfig(ctx, cfg)
}

// ExecuteJobAction runs the checks and, when they pass, sends the action. It never returns an error: every way out
// is a result the caller writes to the audit table.
func ExecuteJobAction(ctx context.Context, d actions.Door, r JobActionRequest) JobActionResult {
	if err := ValidateJobAction(r); err != nil {
		return jobRefused("%s", err.Error())
	}
	if off := d.Off(r.Instance); off != "" {
		return jobRefused("%s", strings.Replace(off, "cancel and terminate are off", "job actions are off", 1))
	}
	if d.Monitor == "" {
		return jobRefused("instance %s: the monitoring dsn resolved to an empty string", r.Instance)
	}
	mon, err := jobConn(ctx, d.Monitor, "pgvigil-actions-check", true)
	if err != nil {
		return jobRefused("the monitoring login could not connect to check the target: %v", err)
	}
	defer func() { _ = mon.Close(context.WithoutCancel(ctx)) }()
	var canWatch bool
	if err := mon.QueryRow(ctx, `SELECT pg_has_role(current_user, 'pg_read_all_stats', 'USAGE')`).Scan(&canWatch); err != nil {
		return jobRefused("the target check failed: %v", err)
	}
	if !canWatch {
		return jobRefused("the monitoring login cannot read every session (it needs pg_monitor or pg_read_all_stats): the target cannot be checked")
	}
	if r.Kind == JobStart {
		return runNow(ctx, mon, d, r)
	}
	var res JobActionResult
	if r.Scheduler == "pg_cron" {
		res = cronTarget(ctx, mon, r)
	} else {
		res = agentTarget(ctx, mon, r)
	}
	if res.Outcome != "" {
		return res
	}
	// the signal, through the actions login
	act, fail := actionsLogin(ctx, mon, d, false)
	if fail != nil {
		fail.PID, fail.BackendStart, fail.TargetUser, fail.TargetApp, fail.Datname = res.PID, res.BackendStart, res.TargetUser, res.TargetApp, res.Datname
		fail.Statement = res.Statement
		return *fail
	}
	defer func() { _ = act.Close(context.WithoutCancel(ctx)) }()
	var ok bool
	if err := act.QueryRow(ctx, `SELECT pg_cancel_backend($1)`, res.PID).Scan(&ok); err != nil {
		res.Outcome, res.Detail = actions.Failed, fmt.Sprintf("pg_cancel_backend(%d) failed: %v", res.PID, err)
		return res
	}
	if !ok {
		res.Outcome, res.Detail = actions.Failed, fmt.Sprintf("pg_cancel_backend(%d) returned false: the backend had already exited", res.PID)
		return res
	}
	res.Outcome = actions.Done
	res.Detail = fmt.Sprintf("pg_cancel_backend(%d) sent: the run's statement is cancelled and the run ends failed", res.PID)
	if r.Scheduler == "pgagent" {
		res.Detail = fmt.Sprintf("pg_cancel_backend(%d) sent: the step fails, and the job goes on or fails by the step's 'on error'", res.PID)
	}
	return res
}

// backendSQL is a session as the monitoring login reads it.
const backendSQL = `
SELECT a.backend_start, a.usename, a.application_name, a.backend_type, a.datname, coalesce(r.rolsuper, false), a.query_start, a.state,
       left(a.query, 200)
  FROM pg_stat_activity a LEFT JOIN pg_roles r ON r.oid = a.usesysid
 WHERE a.pid = $1`

// cronTarget checks a pg_cron run: still running, the job_pid shown, and that pid's backend the one the run started
// (no later backend that reused the pid, the run's user and database, application_name pg_cron, no superuser).
func cronTarget(ctx context.Context, mon *pgx.Conn, r JobActionRequest) JobActionResult {
	var (
		status, user, db, name *string
		pid                    *int
		start, end             *time.Time
	)
	err := mon.QueryRow(ctx, `
SELECT d.status, d.job_pid, d.start_time, d.end_time, d.username::text, d.database::text,
       (SELECT j.jobname::text FROM cron.job j WHERE j.jobid = d.jobid)
  FROM cron.job_run_details d WHERE d.jobid = $1 AND d.runid = $2`, r.JobID, r.RunID).Scan(&status, &pid, &start, &end, &user, &db, &name)
	if errors.Is(err, pgx.ErrNoRows) {
		return jobRefused("run %d of pg_cron job %d is not in cron.job_run_details (purged, or the monitoring login does not see it: pg_cron's row security shows a login its own jobs only)", r.RunID, r.JobID)
	}
	if err != nil {
		return jobRefused("the run check failed: %v", err)
	}
	switch {
	case deref(name) != r.JobName && deref(name) != "":
		return jobRefused("pg_cron job %d is now named %q, not %q as shown: nothing was sent", r.JobID, deref(name), r.JobName)
	case end != nil || (deref(status) != "running" && deref(status) != "starting" && deref(status) != "sending" && deref(status) != "connecting"):
		return jobRefused("run %d has ended (%s): nothing to stop", r.RunID, orDash(status))
	case pid == nil || *pid != r.PID:
		return jobRefused("run %d's job_pid is %s, not %d as shown: nothing was sent", r.RunID, intOrNone(pid), r.PID)
	}
	var (
		bs                    *time.Time
		bu, ba, bt, bd, st, q *string
		super                 bool
		qs                    *time.Time
	)
	err = mon.QueryRow(ctx, backendSQL, r.PID).Scan(&bs, &bu, &ba, &bt, &bd, &super, &qs, &st, &q)
	if errors.Is(err, pgx.ErrNoRows) {
		return jobRefused("pid %d is not running any more: nothing to stop", r.PID)
	}
	if err != nil {
		return jobRefused("the target check failed: %v", err)
	}
	res := JobActionResult{PID: r.PID, BackendStart: bs, TargetUser: deref(bu), TargetApp: deref(ba), Datname: deref(bd),
		Statement: fmt.Sprintf("SELECT pg_cancel_backend(%d)", r.PID)}
	slack := 2 * time.Second
	switch {
	case bs == nil || start == nil || bs.After(start.Add(slack)):
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("pid %d belongs to a backend that started %s, after the run (%s): the run's backend has ended and the pid was reused",
			r.PID, fmtTime(bs), fmtTime(start))
	case deref(bt) != "client backend":
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("pid %d is a %s, not the client backend pg_cron opens for a job (cron.use_background_workers = on is not supported by this action)", r.PID, orDash(bt))
	case deref(ba) != "pg_cron":
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("pid %d's application_name is %q, not pg_cron: it is not the run's session", r.PID, deref(ba))
	case deref(bu) != deref(user) || deref(bd) != deref(db):
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("pid %d is %s on %s, the run is %s on %s: it is not the run's session", r.PID, orDash(bu), orDash(bd), orDash(user), orDash(db))
	case super:
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("the run's backend %d belongs to the superuser %s: the actions login holds pg_signal_backend only and a superuser's backend stays out of its reach", r.PID, deref(bu))
	}
	return res
}

// agentTarget checks a pgAgent run: still running, its running step a SQL step on the monitored server, and exactly
// one active backend whose statement is the step's code.
func agentTarget(ctx context.Context, mon *pgx.Conn, r JobActionRequest) JobActionResult {
	var (
		status, name *string
	)
	err := mon.QueryRow(ctx, `SELECT l.jlgstatus::text, j.jobname FROM pgagent.pga_joblog l JOIN pgagent.pga_job j ON j.jobid = l.jlgjobid
 WHERE l.jlgid = $1 AND l.jlgjobid = $2`, r.RunID, r.JobID).Scan(&status, &name)
	if errors.Is(err, pgx.ErrNoRows) {
		return jobRefused("run %d of pgAgent job %d is not in pgagent.pga_joblog", r.RunID, r.JobID)
	}
	if err != nil {
		return jobRefused("the run check failed: %v", err)
	}
	if deref(name) != r.JobName {
		return jobRefused("pgAgent job %d is now named %q, not %q as shown: nothing was sent", r.JobID, deref(name), r.JobName)
	}
	if deref(status) != "r" {
		return jobRefused("run %d has ended (status %s): nothing to stop", r.RunID, orDash(status))
	}
	var (
		stepName, kind, db, conn, code *string
		stepStart                      *time.Time
	)
	err = mon.QueryRow(ctx, `
SELECT st.jstname, st.jstkind::text, st.jstdbname, st.jstconnstr, st.jstcode, sl.jslstart
  FROM pgagent.pga_jobsteplog sl JOIN pgagent.pga_jobstep st ON st.jstid = sl.jsljstid
 WHERE sl.jsljlgid = $1 AND sl.jslstatus = 'r'
 ORDER BY sl.jslstart DESC LIMIT 1`, r.RunID).Scan(&stepName, &kind, &db, &conn, &code, &stepStart)
	if errors.Is(err, pgx.ErrNoRows) {
		return jobRefused("no step of run %d is running now (pgAgent is between two steps): try again", r.RunID)
	}
	if err != nil {
		return jobRefused("the step check failed: %v", err)
	}
	switch {
	case deref(kind) == "b":
		return jobRefused("step %q is a batch step: it runs in the pgAgent host's shell, not in a backend, and cannot be stopped from SQL", deref(stepName))
	case strings.TrimSpace(deref(conn)) != "":
		return jobRefused("step %q connects through its own connection string: its session may be on another server, and is not looked for", deref(stepName))
	case strings.TrimSpace(deref(code)) == "":
		return jobRefused("step %q has no code to find its session by", deref(stepName))
	}
	// the step's session: active, on the step's database, running the step's code (pg_stat_activity cuts the text at
	// track_activity_query_size: a cut text counts when the code starts with it; current_setting() gives that size with
	// its unit, '1kB', so the bytes come from pg_settings), started no earlier than the step
	rows, err := mon.Query(ctx, `
SELECT a.pid, a.backend_start, a.usename, a.application_name, coalesce(r.rolsuper, false)
  FROM pg_stat_activity a LEFT JOIN pg_roles r ON r.oid = a.usesysid
 WHERE a.backend_type = 'client backend' AND a.state = 'active' AND a.pid <> pg_backend_pid()
   AND a.datname = $1 AND a.query_start >= $2::timestamptz - interval '2 seconds'
   AND (a.query = $3 OR (octet_length(a.query) >= (SELECT s.setting::int FROM pg_settings s WHERE s.name = 'track_activity_query_size') - 4
        AND starts_with($3, a.query)))`,
		deref(db), stepStart, deref(code))
	if err != nil {
		return jobRefused("the session search failed: %v", err)
	}
	type cand struct {
		pid       int
		start     *time.Time
		user, app *string
		super     bool
	}
	var found []cand
	for rows.Next() {
		var c cand
		if err := rows.Scan(&c.pid, &c.start, &c.user, &c.app, &c.super); err != nil {
			rows.Close()
			return jobRefused("the session search failed: %v", err)
		}
		found = append(found, c)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return jobRefused("the session search failed: %v", err)
	}
	switch len(found) {
	case 0:
		return jobRefused("no active session on %s runs step %q's code now: the step may have just ended, or runs a statement its code calls", orDash(db), deref(stepName))
	case 1:
	default:
		return jobRefused("%d active sessions on %s run step %q's code: the step's own cannot be told apart, nothing was sent (stop it from Running queries)", len(found), orDash(db), deref(stepName))
	}
	c := found[0]
	res := JobActionResult{PID: c.pid, BackendStart: c.start, TargetUser: deref(c.user), TargetApp: deref(c.app), Datname: deref(db),
		Statement: fmt.Sprintf("SELECT pg_cancel_backend(%d)", c.pid)}
	if c.super {
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("step %q runs as the superuser %s (pid %d): the actions login holds pg_signal_backend only and a superuser's backend stays out of its reach (run pgAgent as a login of its own)", deref(stepName), deref(c.user), c.pid)
	}
	return res
}

// runNow is pgAgent's Run now: the job exists under the name shown, is enabled, is not running, and a pgAgent that may
// take it is connected; then jobnextrun = now() through the actions login.
func runNow(ctx context.Context, mon *pgx.Conn, d actions.Door, r JobActionRequest) JobActionResult {
	var (
		name, host *string
		enabled    bool
		agent      *int
		agents     int
		hostOK     bool
	)
	err := mon.QueryRow(ctx, `
SELECT j.jobname, j.jobenabled, j.jobagentid, j.jobhostagent,
       (SELECT count(*) FROM pgagent.pga_jobagent)::int,
       (j.jobhostagent = '' OR EXISTS (SELECT 1 FROM pgagent.pga_jobagent a WHERE a.jagstation = j.jobhostagent))
  FROM pgagent.pga_job j WHERE j.jobid = $1`, r.JobID).Scan(&name, &enabled, &agent, &host, &agents, &hostOK)
	stmt := fmt.Sprintf("UPDATE pgagent.pga_job SET jobnextrun = now() WHERE jobid = %d", r.JobID)
	if errors.Is(err, pgx.ErrNoRows) {
		return jobRefused("pgAgent job %d is not in pgagent.pga_job", r.JobID)
	}
	if err != nil {
		return jobRefused("the job check failed: %v", err)
	}
	res := JobActionResult{Statement: stmt}
	switch {
	case deref(name) != r.JobName:
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("pgAgent job %d is now named %q, not %q as shown: nothing was sent", r.JobID, deref(name), r.JobName)
	case !enabled:
		res.Outcome, res.Detail = actions.Refused, "the job is disabled: pgAgent runs no disabled job"
	case agent != nil:
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("the job is running now (pgAgent %d holds it): stop it first or wait for the run to end", *agent)
	case agents == 0:
		res.Outcome, res.Detail = actions.Refused, "no pgAgent is connected (pgagent.pga_jobagent is empty): nothing would run the job"
	case !hostOK:
		res.Outcome, res.Detail = actions.Refused, fmt.Sprintf("the job runs on host agent %q only, and no pgAgent of that host is connected", deref(host))
	}
	if res.Outcome != "" {
		return res
	}
	act, fail := actionsLogin(ctx, mon, d, true)
	if fail != nil {
		fail.Statement = stmt
		return *fail
	}
	defer func() { _ = act.Close(context.WithoutCancel(ctx)) }()
	var may bool
	if err := act.QueryRow(ctx, `SELECT coalesce(has_column_privilege(to_regclass('pgagent.pga_job'), 'jobnextrun', 'UPDATE'), false)
	   AND coalesce(has_column_privilege(to_regclass('pgagent.pga_job'), 'jobid', 'SELECT'), false)`).Scan(&may); err != nil {
		res.Outcome, res.Detail = actions.Failed, fmt.Sprintf("the actions login's grant check failed: %v", err)
		return res
	}
	if !may {
		res.Outcome, res.Detail = actions.Refused, "the actions login may not set jobnextrun (GRANT USAGE ON SCHEMA pgagent TO pgvigil_actions; GRANT SELECT (jobid, jobenabled, jobagentid), UPDATE (jobnextrun) ON pgagent.pga_job TO pgvigil_actions)"
		return res
	}
	tag, err := act.Exec(ctx, `UPDATE pgagent.pga_job SET jobnextrun = now() WHERE jobid = $1 AND jobenabled AND jobagentid IS NULL`, r.JobID)
	if err != nil {
		res.Outcome, res.Detail = actions.Failed, fmt.Sprintf("the update failed: %v", err)
		return res
	}
	if tag.RowsAffected() != 1 {
		res.Outcome, res.Detail = actions.Failed, "the job changed between the check and the update (disabled, started or dropped): nothing was set"
		return res
	}
	res.Outcome, res.Detail = actions.Done, "jobnextrun set to now(): pgAgent starts the job at its next poll (within a minute)"
	return res
}

// actionsLogin connects the actions login and checks it: the same server as the monitoring login, no superuser, and
// for a stop pg_signal_backend. A non-nil result is the refusal or failure to return.
func actionsLogin(ctx context.Context, mon *pgx.Conn, d actions.Door, write bool) (*pgx.Conn, *JobActionResult) {
	act, err := jobConn(ctx, d.Actions, "pgvigil-actions", !write)
	if err != nil {
		return nil, &JobActionResult{Outcome: actions.Failed, Detail: fmt.Sprintf("the actions login could not connect: %v", err)}
	}
	closeIt := func(res JobActionResult) (*pgx.Conn, *JobActionResult) {
		_ = act.Close(context.WithoutCancel(ctx))
		return nil, &res
	}
	var monStart, actStart time.Time
	if err := mon.QueryRow(ctx, `SELECT pg_postmaster_start_time()`).Scan(&monStart); err != nil {
		return closeIt(JobActionResult{Outcome: actions.Refused, Detail: fmt.Sprintf("the server check failed: %v", err)})
	}
	if err := act.QueryRow(ctx, `SELECT pg_postmaster_start_time()`).Scan(&actStart); err != nil {
		return closeIt(JobActionResult{Outcome: actions.Failed, Detail: fmt.Sprintf("the actions login's server check failed: %v", err)})
	}
	if !monStart.Equal(actStart) {
		return closeIt(JobActionResult{Outcome: actions.Refused, Detail: fmt.Sprintf("actions_dsn reaches another server than the instance's dsn (server started %s vs %s): nothing was sent",
			actStart.UTC().Format(time.RFC3339), monStart.UTC().Format(time.RFC3339))})
	}
	var super, signal bool
	if err := act.QueryRow(ctx, `SELECT r.rolsuper, pg_has_role(current_user, 'pg_signal_backend', 'USAGE') FROM pg_roles r WHERE r.rolname = current_user`).Scan(&super, &signal); err != nil {
		return closeIt(JobActionResult{Outcome: actions.Failed, Detail: fmt.Sprintf("the actions login's role check failed: %v", err)})
	}
	if super {
		return closeIt(JobActionResult{Outcome: actions.Refused, Detail: "the actions login is a superuser: pgvigil refuses it (create pgvigil_actions with pg_signal_backend only; pgvigil roles prints it)"})
	}
	if !write && !signal {
		return closeIt(JobActionResult{Outcome: actions.Refused, Detail: "the actions login does not hold pg_signal_backend (GRANT pg_signal_backend TO pgvigil_actions)"})
	}
	return act, nil
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func orDash(p *string) string {
	if p == nil || *p == "" {
		return "-"
	}
	return *p
}

func intOrNone(p *int) string {
	if p == nil {
		return "none"
	}
	return fmt.Sprint(*p)
}

func fmtTime(t *time.Time) string {
	if t == nil {
		return "unknown"
	}
	return t.UTC().Format(time.RFC3339Nano)
}
