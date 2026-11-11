package web

// The PostgreSQL Jobs page's twins of DBA Dash's Running Jobs, Agent Job Actions, job exclusions and per-step job
// stats (task 161):
//
//   GET  /api/jobs/running?instance=N        the runs still running at the newest read (pg_jobs_running, 0102), which
//                                            job actions are on and why not, and the job actions' audit rows
//   POST /api/jobs/actions/stop              cancel the backend of a running pg_cron or pgAgent run
//   POST /api/jobs/actions/start             pgAgent's Run now (jobnextrun = now())
//   GET  /api/jobs/steps?instance=N&job=J[&run=R]   pgAgent's step log: per step its outcomes and durations in the
//                                            range, and the step runs (of one run with run=)
//   GET  /api/jobs/exclusions?instance=N     the live exclusions that take the instance's jobs, and whether they can be
//                                            written; POST: add one or end one (import_job_exclusion)
//
// The job actions are off by default: a PostgreSQL instance's 'actions:' list names job_stop and / or job_start (the
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
// (job_stop, job_start; anything else is ignored here: the config refuses it).
func (s *Server) SetPgJobActions(allow map[string][]string) {
	m := map[string]map[string]bool{}
	for name, list := range allow {
		m[name] = map[string]bool{}
		for _, a := range list {
			if a == collect.JobStop || a == collect.JobStart {
				m[name][a] = true
			}
		}
	}
	pgJobAllow.Store(s, m)
}

func (s *Server) pgJobAllowed(instance, kind string) bool {
	v, ok := pgJobAllow.Load(s)
	if !ok {
		return false
	}
	return v.(map[string]map[string]bool)[instance][kind]
}

// pgJobOff is why a job action is off on an instance, or "" when it is on.
func (s *Server) pgJobOff(ctx context.Context, instance, kind string) string {
	a := s.actions
	switch {
	case a == nil:
		return "actions are off on this server"
	case a.off != "":
		return a.off
	}
	if off := a.doors[instance].Off(instance); off != "" {
		return strings.Replace(off, "cancel and terminate are off", "job actions are off", 1)
	}
	if !s.pgJobAllowed(instance, kind) {
		return fmt.Sprintf("instance %s's actions: list does not name %s: the job actions are off by default (add it to the instance's actions: in the config)", instance, kind)
	}
	var may bool
	if err := a.audit.QueryRow(ctx, `SELECT coalesce(has_function_privilege(to_regprocedure('pgvigil.import_pg_job_actions_log(int, timestamptz, jsonb)'), 'EXECUTE'), false)`).Scan(&may); err != nil || !may {
		return "the actions log cannot take a job action: the repository has no pgvigil.import_pg_job_actions_log the audit login may call (run 'pgvigil migrate': 0102)"
	}
	return ""
}

const sqlJobsRunning = `SELECT * FROM pgvigil.pg_jobs_running($1)`

const sqlJobActionsLog = `
SELECT action_id, at, ui_user, client, action, target AS job, target_id, pid, backend_start, target_user, reason, outcome, detail, statement
  FROM pgvigil.actions_log
 WHERE instance_id = $1 AND engine = 'postgres' AND action IN ('job_stop', 'job_start')
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
	for _, k := range []string{collect.JobStop, collect.JobStart} {
		why := s.pgJobOff(ctx, name, k)
		acts[k] = state{On: why == "", Reason: why}
	}
	out["actions"] = acts
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
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %s is a %s instance: its jobs are started and stopped through the SQL Server actions; nothing was sent", name, engine))
		return
	}
	// the audit door first: an attempt that cannot be written is not made
	if err := a.audit.Ping(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the actions log cannot be written (%v): nothing was sent", err))
		return
	}
	var may bool
	if err := a.audit.QueryRow(ctx, `SELECT coalesce(has_function_privilege(to_regprocedure('pgvigil.import_pg_job_actions_log(int, timestamptz, jsonb)'), 'EXECUTE'), false)`).Scan(&may); err != nil || !may {
		writeErr(w, http.StatusServiceUnavailable, errors.New("the actions log cannot be written: the repository has no pgvigil.import_pg_job_actions_log the audit login may call (run 'pgvigil migrate': 0102); nothing was sent"))
		return
	}
	req := collect.JobActionRequest{InstanceID: in.InstanceID, Instance: name, Kind: kind, Scheduler: in.Scheduler, JobID: in.JobID,
		JobName: in.JobName, RunID: in.RunID, PID: in.PID, Reason: in.Reason, User: user, Client: clientIP(r)}
	var res collect.JobActionResult
	switch {
	case !s.pgJobAllowed(name, kind):
		res = collect.JobActionResult{Outcome: actions.Refused,
			Detail: fmt.Sprintf("instance %s's actions: list does not name %s: the job actions are off by default", name, kind)}
	case strings.TrimSpace(in.Confirm) != in.JobName || in.JobName == "":
		res = collect.JobActionResult{Outcome: actions.Refused, Detail: "the typed confirmation is not the job's name"}
	default:
		res = pgJobRun(ctx, a.doors[name], req)
	}
	at := time.Now()
	if err := s.writeJobAudit(context.WithoutCancel(ctx), at, req, res); err != nil {
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
		out["reason"] = strings.Replace(why, "acknowledgements", "job exclusions", 1)
	}
	out["exclusions"], err = s.query(r.Context(), `SELECT * FROM pgvigil.job_exclusion_rows($1)`, id)
	s.reply(w, r, out, err)
}

func (s *Server) jobExclusionWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.ackOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(strings.Replace(why, "acknowledgements", "job exclusions", 1)))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
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
	pay := map[string]any{"ui_user": user, "client": clientIP(r)}
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
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_job_exclusion($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
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
