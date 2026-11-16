package web

// The PostgreSQL Jobs page's twins of DBA Dash's Running Jobs, Agent Job Actions, job exclusions and per-step job
// stats (task 161):
//
//   GET  /api/jobs/running?instance=N        the runs still running at the newest read (pg_jobs_running, 0102), which
//                                            job actions are on and why not, and the job actions' audit rows
//   POST /api/jobs/actions/stop              cancel the backend of a running pg_cron or pgAgent run
//   POST /api/jobs/actions/start             pgAgent's Run now (jobnextrun = now())
//   POST /api/jobs/actions/enable|disable    (B9c) a pgAgent job's jobenabled, a pg_cron job's active (cron.alter_job,
//                                            the actions login's own jobs only)
//   GET  /api/jobs/steps?instance=N&job=J[&run=R]   pgAgent's step log: per step its outcomes and durations in the
//                                            range, and the step runs (of one run with run=)
//   GET  /api/jobs/exclusions?instance=N     the live exclusions that take the instance's jobs, and whether they can be
//                                            written; POST: add one or end one (import_job_exclusion)
//
// The job actions are off by default: a PostgreSQL instance's 'actions:' list names job_stop, job_start, job_enable and
// job_disable, each on its own (the
// config's allow list, as a SQL Server instance's), on top of the actions_dsn that turns cancel and terminate on. The
// checks and the signal are internal/collect/jobs_actions.go; this file is the HTTP side, in the shape of actions.go:
// the UI login, the X-Pgvigil header, the typed confirmation (the job's name), and one audit row per attempt in
// pgvigil.actions_log through import_pg_job_actions_log.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/collect"
)

// pgJobAllow keeps each server's allow lists (serve calls SetPgJobActions after Open), as mssqlActions does.
var pgJobAllow sync.Map // *Server -> map[string]map[string]bool

// pgJobRun is the job actions' executor; a test or a proof may stand another in.
var pgJobRun = collect.ExecuteJobAction

// SetPgJobActions gives the server the job actions each PostgreSQL instance allows: its name -> the 'actions:' list
// (job_stop, job_start, job_enable, job_disable; anything else is ignored here: the config refuses it).
func (s *Server) SetPgJobActions(allow map[string][]string) {
	m := map[string]map[string]bool{}
	for name, list := range allow {
		m[name] = map[string]bool{}
		for _, a := range list {
			if a == collect.JobStop || a == collect.JobStart || a == collect.JobEnable || a == collect.JobDisable {
				m[name][a] = true
			}
		}
	}
	pgJobAllow.Store(s.self(), m)
}

// pgJobAllowed: the instance's actions: list in pgvigil.yaml names the job action (the set's copy of the lists)
func (ds *doorSet) pgJobAllowed(instance, kind string) bool { return ds.PgJobs[instance][kind] }

// pgJobAuditOff is why the audit cannot take a job action's row, or "" when it can.
func (s *Server) pgJobAuditOff(ctx context.Context) string {
	var may bool
	if err := s.actions.audit.QueryRow(ctx, `SELECT coalesce(has_function_privilege(to_regprocedure('pgvigil.import_pg_job_actions_log(int, timestamptz, jsonb)'), 'EXECUTE'), false)`).Scan(&may); err != nil {
		return "the actions log could not be checked: " + err.Error()
	} else if !may {
		return "the actions log cannot take a job action: the repository has no pgvigil.import_pg_job_actions_log the audit login may call (run 'pgvigil migrate': 0102)"
	}
	return ""
}

// sqlToggleAuditReady: the repository takes an enable / disable audit row - actions_log's CHECK names both kinds (0194)
// and, for PostgreSQL, import_pg_job_actions_log accepts them (0194 replaced 0102's, which raises on any kind but
// job_stop and job_start). serve does not check the schema's version (only run does), so an install of this binary on a
// repository not yet migrated would otherwise send the statement and then fail its audit row.
const sqlToggleAuditReady = `SELECT EXISTS (SELECT 1 FROM pg_constraint c
                WHERE c.conrelid = to_regclass('pgvigil.actions_log') AND c.conname = 'actions_log_action_check'
                  AND pg_get_constraintdef(c.oid) LIKE '%job_enable%' AND pg_get_constraintdef(c.oid) LIKE '%job_disable%')
       AND (NOT $1::bool OR coalesce((SELECT position('job_enable' IN p.prosrc) > 0 AND position('job_disable' IN p.prosrc) > 0 FROM pg_proc p
                                      WHERE p.oid = to_regprocedure('pgvigil.import_pg_job_actions_log(int, timestamptz, jsonb)')), false))`

// toggleAuditOff is why the repository cannot take an enable / disable audit row ("" when it can); pg = the PostgreSQL
// door (its import function checked too).
func toggleAuditOff(ctx context.Context, q rowQuerier, pg bool) string {
	var ok bool
	if err := q.QueryRow(ctx, sqlToggleAuditReady, pg).Scan(&ok); err != nil {
		return "the actions log could not be checked for job_enable / job_disable: " + err.Error()
	}
	if !ok {
		return "the actions log cannot take job_enable / job_disable yet: the repository is not migrated to 0194 (run 'pgvigil migrate')"
	}
	return ""
}

// pgJobOff is why a job action is off on an instance, or "" when it is on; auditOff is pgJobAuditOff's answer, read once
// per request (for job_enable / job_disable it carries toggleAuditOff's too: see toggleOffFor).
func (s *Server) pgJobOff(ds *doorSet, instance, kind, auditOff string) string {
	a := s.actions
	switch {
	case a == nil:
		return "actions are off on this server"
	case a.off != "":
		return a.off
	}
	if off := ds.PG[instance].Off(instance); off != "" {
		return strings.Replace(off, "cancel and terminate are off", "job actions are off", 1)
	}
	if !ds.pgJobAllowed(instance, kind) {
		return fmt.Sprintf("instance %s's actions: list does not name %s: the job actions are off by default (add it to the instance's actions: in the config)", instance, kind)
	}
	return auditOff
}

// toggleOffFor: auditOff for kind - for job_enable / job_disable also the repository's readiness for their rows.
func (s *Server) toggleOffFor(ctx context.Context, kind, auditOff string) string {
	if auditOff != "" || (kind != collect.JobEnable && kind != collect.JobDisable) || s.actions == nil || s.actions.audit == nil {
		return auditOff
	}
	return toggleAuditOff(ctx, s.actions.audit, true)
}

const sqlJobsRunning = `SELECT * FROM pgvigil.pg_jobs_running($1)`

const sqlJobActionsLog = `
SELECT action_id, at, ui_user, client, action, target AS job, target_id, pid, backend_start, target_user, reason, outcome, detail, statement
  FROM pgvigil.actions_log
 WHERE instance_id = $1 AND engine = 'postgres' AND action IN ('job_stop', 'job_start', 'job_enable', 'job_disable')
 ORDER BY at DESC, action_id DESC
 LIMIT 200`

// JobsRunning is GET /api/jobs/running?instance=N.
func (s *Server) JobsRunning(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx := r.Context()
	var name, engine string
	if err := s.pool.QueryRow(ctx, `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name, &engine); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	if engine != "postgres" {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %s is a %s instance: its running jobs are on its own Jobs tab", name, engine))
		return
	}
	type state struct {
		On     bool   `json:"on"`
		Reason string `json:"reason,omitempty"`
	}
	out := map[string]any{}
	acts := map[string]state{}
	auditOff := ""
	if s.actions != nil && s.actions.off == "" {
		auditOff = s.pgJobAuditOff(ctx)
	}
	ds := s.doorsNow()
	toggleOff := ""
	if s.actions != nil && s.actions.off == "" && auditOff == "" {
		toggleOff = s.toggleOffFor(ctx, collect.JobEnable, auditOff)
	}
	for _, k := range []string{collect.JobStop, collect.JobStart, collect.JobEnable, collect.JobDisable} {
		off := auditOff
		if k == collect.JobEnable || k == collect.JobDisable {
			off = toggleOff
		}
		why := s.pgJobOff(ds, name, k, off)
		acts[k] = state{On: why == "", Reason: why}
	}
	out["actions"] = acts
	// the role the actions login connects as: the page offers a pg_cron job's Enable and Disable only where the job's
	// owner (its run_as) is that role - the server checks it again before anything is sent
	if d, ok := ds.PG[name]; ok && d.Actions != "" && (acts[collect.JobEnable].On || acts[collect.JobDisable].On) {
		if who := collect.ActionsLoginName(d.Actions); who != "" {
			out["actions_login"] = who
		}
	}
	if out["running"], err = s.query(ctx, sqlJobsRunning, id); err != nil {
		s.reply(w, r, nil, fmt.Errorf("running: %w", err))
		return
	}
	if out["log"], err = s.query(ctx, sqlJobActionsLog, id); err != nil {
		s.reply(w, r, nil, fmt.Errorf("log: %w", err))
		return
	}
	s.reply(w, r, out, nil)
}

type jobActionBody struct {
	InstanceID int    `json:"instance_id"`
	Scheduler  string `json:"scheduler"`
	JobID      int64  `json:"job_id"`
	JobName    string `json:"job_name"`
	RunID      int64  `json:"run_id"`
	PID        int    `json:"job_pid"`
	Reason     string `json:"reason"`
	Confirm    string `json:"confirm"`
}

// JobStop is POST /api/jobs/actions/stop.
func (s *Server) JobStop(w http.ResponseWriter, r *http.Request) { s.jobAction(w, r, collect.JobStop) }

// JobStart is POST /api/jobs/actions/start.
func (s *Server) JobStart(w http.ResponseWriter, r *http.Request) {
	s.jobAction(w, r, collect.JobStart)
}

// JobEnable is POST /api/jobs/actions/enable (B9c; its route is a WIRING line of web.go).
func (s *Server) JobEnable(w http.ResponseWriter, r *http.Request) {
	s.jobAction(w, r, collect.JobEnable)
}

// JobDisable is POST /api/jobs/actions/disable (B9c; its route is a WIRING line of web.go).
func (s *Server) JobDisable(w http.ResponseWriter, r *http.Request) {
	s.jobAction(w, r, collect.JobDisable)
}

func (s *Server) jobAction(w http.ResponseWriter, r *http.Request, kind string) {
	a := s.actions
	if a == nil {
		writeErr(w, http.StatusForbidden, errors.New("actions are off on this server"))
		return
	}
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if a.off != "" {
		writeErr(w, http.StatusForbidden, errors.New(a.off))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	var in jobActionBody
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	for _, v := range []string{in.Scheduler, in.JobName, in.Reason, in.Confirm} {
		if strings.ContainsRune(v, 0) {
			writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was sent"))
			return
		}
	}
	if in.InstanceID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance_id"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	var name, engine string
	if err := s.pool.QueryRow(ctx, `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1`, in.InstanceID).Scan(&name, &engine); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", in.InstanceID))
		return
	}
	if engine != "postgres" {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %s is a %s instance: its jobs are started, stopped, enabled and disabled through the SQL Server actions; nothing was sent", name, engine))
		return
	}
	// the audit door first: an attempt that cannot be written is not made
	if err := a.audit.Ping(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the actions log cannot be written (%v): nothing was sent", err))
		return
	}
	if off := s.toggleOffFor(ctx, kind, s.pgJobAuditOff(ctx)); off != "" {
		writeErr(w, http.StatusServiceUnavailable, errors.New(off+"; nothing was sent"))
		return
	}
	req := collect.JobActionRequest{InstanceID: in.InstanceID, Instance: name, Kind: kind, Scheduler: in.Scheduler, JobID: in.JobID,
		JobName: in.JobName, RunID: in.RunID, PID: in.PID, Reason: in.Reason, User: user, Client: clientIP(r)}
	var res collect.JobActionResult
	// the statement a refusal here would have sent (a pgAgent stop's pid is not known before its checks)
	would := collect.JobStatement(kind, in.Scheduler, in.JobID, in.PID)
	ds := s.doorsNow() // the request's one door set
	switch {
	case ds.remoteWhy(name) != "":
		// an instance a remote collector reads: no connection of any kind
		res = collect.JobActionResult{Outcome: actions.Refused, Statement: would, Detail: ds.remoteWhy(name)}
	case ds.PG[name].Page:
		// an instance added in Admin > Instances: no action of any kind
		res = collect.JobActionResult{Outcome: actions.Refused, Statement: would, Detail: actions.PageOff(name)}
	case !ds.pgJobAllowed(name, kind):
		res = collect.JobActionResult{Outcome: actions.Refused, Statement: would,
			Detail: fmt.Sprintf("instance %s's actions: list does not name %s: the job actions are off by default", name, kind)}
	case strings.TrimSpace(in.Confirm) != strings.TrimSpace(in.JobName) || strings.TrimSpace(in.JobName) == "":
		res = collect.JobActionResult{Outcome: actions.Refused, Statement: would, Detail: "the typed confirmation is not the job's name"}
	default:
		res = pgJobRun(ctx, ds.PG[name], req)
	}
	at := time.Now()
	// the audit row outlives a client that hangs up, never 15 s
	actx, acancel := context.WithTimeout(context.WithoutCancel(ctx), 15*time.Second)
	defer acancel()
	if err := s.writeJobAudit(actx, at, req, res); err != nil {
		s.log.Error("job actions: the audit row was not written", "instance", name, "action", kind, "job", in.JobID, "user", user,
			"outcome", res.Outcome, "detail", res.Detail, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s: %s; the audit row could not be written: %v", res.Outcome, res.Detail, err))
		return
	}
	s.log.Info("job actions: attempt", "instance", name, "action", kind, "job", in.JobID, "run", in.RunID, "user", user,
		"outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	switch res.Outcome {
	case actions.Refused:
		code = http.StatusConflict
	case actions.Failed:
		code = http.StatusBadGateway
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "pid": res.PID, "statement": res.Statement}
	if code != http.StatusOK {
		o["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(o)
}

// writeJobAudit writes the audit row of one job action.
func (s *Server) writeJobAudit(ctx context.Context, at time.Time, req collect.JobActionRequest, res collect.JobActionResult) error {
	nul := func(v string) string { return strings.ReplaceAll(v, "\x00", "") }
	reason := strings.TrimSpace(req.Reason)
	if reason == "" {
		reason = "(no reason given)"
	}
	if rs := []rune(reason); len(rs) > actions.MaxReason {
		reason = string(rs[:actions.MaxReason])
	}
	var bs *string
	if res.BackendStart != nil {
		v := res.BackendStart.UTC().Format(time.RFC3339Nano)
		bs = &v
	}
	row := map[string]any{
		"instance_name": req.Instance, "at": at, "ui_user": nul(req.User), "client": nul(req.Client), "action": req.Kind,
		"pid": res.PID, "backend_start": bs, "target_user": nul(res.TargetUser), "target_app": nul(res.TargetApp),
		"target": nul(req.JobName), "target_id": req.Scheduler + ":" + strconv.FormatInt(req.JobID, 10) + runSuffix(req.RunID),
		"reason": nul(reason), "outcome": string(res.Outcome), "detail": nul(res.Detail), "datname": nul(res.Datname),
		"statement": nul(res.Statement),
	}
	b, err := json.Marshal([]any{row})
	if err != nil {
		return err
	}
	_, err = s.actions.audit.Exec(ctx, `SELECT pgvigil.import_pg_job_actions_log($1, $2, $3::jsonb)`, req.InstanceID, at, string(b))
	return err
}

func runSuffix(run int64) string {
	if run <= 0 {
		return ""
	}
	return " run " + strconv.FormatInt(run, 10)
}

const sqlJobStepStats = `
SELECT s.step_id, (array_agg(s.step_name ORDER BY s.start_time DESC))[1] AS step_name, count(*) AS runs,
       count(*) FILTER (WHERE s.status = 'succeeded') AS succeeded, count(*) FILTER (WHERE s.status = 'failed') AS failed,
       count(*) FILTER (WHERE s.status = 'ignored') AS ignored, count(*) FILTER (WHERE s.status = 'aborted') AS aborted,
       count(*) FILTER (WHERE s.status = 'running') AS running,
       round(avg(s.duration_secs)::numeric, 1) AS avg_secs, round(max(s.duration_secs)::numeric, 1) AS max_secs,
       (array_agg(s.status ORDER BY s.start_time DESC))[1] AS last_status, max(s.start_time) AS last_start
  FROM pgvigil.job_step_runs s
 WHERE s.instance_id = $1 AND s.job_id = $4 AND s.start_time >= $2 AND s.start_time < $3
 GROUP BY s.step_id
 ORDER BY s.step_id`

const sqlJobStepRuns = `
SELECT s.run_id, s.step_log_id, s.step_id, s.step_name, s.status, s.result, s.start_time, s.end_time, s.duration_secs, s.output
  FROM pgvigil.job_step_runs s
 WHERE s.instance_id = $1 AND s.job_id = $4
   AND CASE WHEN $5::bigint IS NULL THEN s.start_time >= $2 AND s.start_time < $3 ELSE s.run_id = $5 END
 ORDER BY s.start_time DESC, s.step_log_id DESC
 LIMIT 1000`

// JobSteps is GET /api/jobs/steps?instance=N&job=J[&run=R]: a pgAgent job's step log.
func (s *Server) JobSteps(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	job, err := strconv.ParseInt(q.Get("job"), 10, 64)
	if err != nil || job <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("job must be a pgAgent job id"))
		return
	}
	var run *int64
	if v := q.Get("run"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("run must be a run id"))
			return
		}
		run = &n
	}
	s.multiPart(w, r, []part{
		{"steps", sqlJobStepStats, []any{id, from, to, job}},
		{"step_runs", sqlJobStepRuns, []any{id, from, to, job, run}},
	})
}

// JobExclusions is GET (the list) and POST (add or end) /api/jobs/exclusions.
func (s *Server) JobExclusions(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		s.jobExclusionWrite(w, r)
		return
	}
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	out := map[string]any{}
	why := s.ackOff()
	out["writable"] = why == ""
	if why != "" {
		out["reason"] = s.offWords(why, "job exclusions")
		out["demo"] = s.demo != nil // the page reads the door from GET /api/ack; this says which reason it lacks when that read fails
	}
	out["can"] = s.roleCan(r) // the session's role (B24f): a job exclusion needs admin
	out["exclusions"], err = s.query(r.Context(), `SELECT * FROM pgvigil.job_exclusion_rows($1)`, id)
	s.reply(w, r, out, err)
}

func (s *Server) jobExclusionWrite(w http.ResponseWriter, r *http.Request) {
	seat, ok := s.seat(w, r, strings.Replace(s.ackOff(), "acknowledgements", "job exclusions", 1))
	if !ok {
		return
	}
	user := seat.user
	raw, err := io.ReadAll(io.LimitReader(r.Body, 8193))
	if err != nil || len(raw) > 8192 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 8 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	var in map[string]any
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	// only the named keys travel on; who and from where are the server's to say
	pay := map[string]any{"ui_user": user, "client": seat.client}
	for _, k := range []string{"op", "level", "instance_id", "match_on", "pattern", "note", "exclusion_id"} {
		if v, ok := in[k]; ok && v != nil {
			pay[k] = v
		}
	}
	b, _ := json.Marshal(pay)
	var res struct {
		Outcome     string `json:"outcome"`
		Detail      string `json:"detail"`
		ExclusionID *int64 `json:"exclusion_id"`
	}
	var out []byte
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	pool, ok := seat.poolFor(wctx, w, scopeOfExclusion(pay))
	if !ok {
		return
	}
	if err := pool.QueryRow(wctx, `SELECT pgvigil.import_job_exclusion($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("job exclusion: not written", "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_job_exclusion answered %q", out))
		return
	}
	s.log.Info("job exclusion: attempt", "op", pay["op"], "level", pay["level"], "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	o := map[string]any{"outcome": res.Outcome, "detail": res.Detail, "exclusion_id": res.ExclusionID}
	if code != http.StatusOK {
		o["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(o)
}
