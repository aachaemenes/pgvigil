package web

// The actions door, the SQL Server side: POST /api/mssql/actions/preview reads the target of an action (a session
// with its login, host, program, open transaction count and last statement; an Agent job with its name, owner and
// state) through the instance's read login, POST /api/mssql/actions/run sends KILL, sp_start_job or sp_stop_job
// through the instance's actions login when the target is still the one shown, GET /api/mssql/actions/state says
// which actions are on for an instance (and why not) with its audit rows. The work and its checks are
// internal/mssql (actions.go); this file is the HTTP side, in the shape of actions.go: the UI login, the
// X-Pgvigil header, the typed confirmation, and the audit row of every attempt in pgvigil.actions_log.
//
// It stands on the PostgreSQL door's state (the UI login and the audit pool of *Actions): one audit login, one
// audit table, one rule for who may act.

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

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// MSSQLActions is the SQL Server side of the door. Never nil after NewMSSQLActions; without doors every action is
// off with the reason.
type MSSQLActions struct {
	a       *Actions
	doors   map[string]mssql.Door
	preview func(ctx context.Context, d mssql.Door, instance string, k mssql.ActionKind, sessionID int, jobID string) (mssql.Target, string)
	run     func(ctx context.Context, d mssql.Door, r mssql.ActionRequest) mssql.ActionResult
}

// NewMSSQLActions builds the SQL Server side on the server's actions door (s.actions: call it after NewActions).
// doors maps a configured SQL Server instance's name to its connection strings and allow list.
func (s *Server) NewMSSQLActions(doors map[string]mssql.Door) *MSSQLActions {
	return &MSSQLActions{a: s.actions, doors: doors, preview: mssql.Preview, run: mssql.Execute}
}

// mssqlActions keeps each server's SQL Server door (serve calls SetMSSQLActions after Open), as plansConfigs does.
var mssqlActions sync.Map // *Server -> *MSSQLActions

// SetMSSQLActions gives the server its SQL Server doors: per configured SQL Server instance the read dsn, the
// actions dsn and the allow list.
func (s *Server) SetMSSQLActions(doors map[string]mssql.Door) {
	mssqlActions.Store(s, s.NewMSSQLActions(doors))
}

// mssqlDoor is the server's SQL Server door; without SetMSSQLActions every action is off with the reason.
func (s *Server) mssqlDoor() *MSSQLActions {
	if v, ok := mssqlActions.Load(s); ok {
		return v.(*MSSQLActions)
	}
	return s.NewMSSQLActions(nil)
}

// MSSQLActionPreview is POST /api/mssql/actions/preview.
func (s *Server) MSSQLActionPreview(w http.ResponseWriter, r *http.Request) {
	s.mssqlDoor().Preview(w, r)
}

// MSSQLActionRun is POST /api/mssql/actions/run.
func (s *Server) MSSQLActionRun(w http.ResponseWriter, r *http.Request) { s.mssqlDoor().Run(w, r) }

// MSSQLActionState is GET /api/mssql/actions/state.
func (s *Server) MSSQLActionState(w http.ResponseWriter, r *http.Request) { s.mssqlDoor().State(w, r) }

type mssqlActionBody struct {
	InstanceID int    `json:"instance_id"`
	Action     string `json:"action"`
	SessionID  int    `json:"session_id"`
	LoginTime  string `json:"login_time"`
	Login      string `json:"login"`
	JobID      string `json:"job_id"`
	JobName    string `json:"job_name"`
	Reason     string `json:"reason"`
	Confirm    string `json:"confirm"`
}

func (b mssqlActionBody) hasNUL() bool {
	for _, v := range []string{b.Action, b.LoginTime, b.Login, b.JobID, b.JobName, b.Reason, b.Confirm} {
		if strings.ContainsRune(v, 0) {
			return true
		}
	}
	return false
}

// gate is the part of a POST both routes share: the door on this server, the header, the UI user, the body, the
// instance (a SQL Server one). ok false = the reply is written.
func (m *MSSQLActions) gate(w http.ResponseWriter, r *http.Request) (in mssqlActionBody, user, name string, ok bool) {
	if m == nil || m.a == nil {
		writeErr(w, http.StatusForbidden, errors.New("actions are off on this server"))
		return in, "", "", false
	}
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return in, "", "", false
	}
	if m.a.off != "" {
		writeErr(w, http.StatusForbidden, errors.New(m.a.off))
		return in, "", "", false
	}
	if user = m.a.s.sessionUser(r); user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return in, "", "", false
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return in, "", "", false
	}
	if in.hasNUL() {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was sent"))
		return in, "", "", false
	}
	if in.InstanceID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance_id"))
		return in, "", "", false
	}
	if !mssql.ValidAction(in.Action) {
		writeErr(w, http.StatusBadRequest, errors.New("action must be one of kill, job_start, job_stop"))
		return in, "", "", false
	}
	var engine string
	if err := m.a.s.pool.QueryRow(r.Context(), `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1`, in.InstanceID).Scan(&name, &engine); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", in.InstanceID))
		return in, "", "", false
	}
	if engine != "sqlserver" {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %s is not a SQL Server instance", name))
		return in, "", "", false
	}
	return in, user, name, true
}

// Preview is POST /api/mssql/actions/preview: the target as the read login sees it now. Nothing is sent to the
// server but that read, and nothing is written to the audit: an attempt is the run.
func (m *MSSQLActions) Preview(w http.ResponseWriter, r *http.Request) {
	in, _, name, ok := m.gate(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	t, why := m.preview(ctx, m.doors[name], name, mssql.ActionKind(in.Action), in.SessionID, in.JobID)
	out := struct {
		OK        bool         `json:"ok"`
		Reason    string       `json:"reason,omitempty"`
		Statement string       `json:"statement"`
		Target    mssql.Target `json:"target"`
	}{OK: why == "", Reason: why, Statement: mssql.Statement(mssql.ActionKind(in.Action), in.SessionID, in.JobID), Target: t}
	m.a.s.reply(w, r, out, nil)
}

// Run is POST /api/mssql/actions/run: the confirm step. Every way out past the gate writes one audit row.
func (m *MSSQLActions) Run(w http.ResponseWriter, r *http.Request) {
	in, user, name, ok := m.gate(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	// the audit door first: an attempt that cannot be written is not made
	if err := m.a.audit.Ping(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the actions log cannot be written (%v): nothing was sent", err))
		return
	}
	kind := mssql.ActionKind(in.Action)
	req := mssql.ActionRequest{Instance: name, Kind: kind, SessionID: in.SessionID, LoginTime: in.LoginTime, Login: in.Login,
		JobID: in.JobID, JobName: in.JobName, Reason: in.Reason, User: user, Client: clientIP(r)}
	var res mssql.ActionResult
	want, what := strconv.Itoa(in.SessionID), "the session id "+strconv.Itoa(in.SessionID)
	if kind != mssql.ActionKill {
		want, what = in.JobName, "the job's name"
	}
	if strings.TrimSpace(in.Confirm) != want || want == "" {
		res = mssql.ActionResult{Outcome: mssql.OutcomeRefused, Detail: "the typed confirmation is not " + what,
			Statement: mssql.Statement(kind, in.SessionID, in.JobID)}
	} else {
		res = m.run(ctx, m.doors[name], req)
	}
	at := time.Now()
	payload, err := mssql.ActionPayload(mssql.ActionRow(at, req, res))
	if err == nil {
		_, err = m.a.audit.Exec(context.WithoutCancel(ctx), mssql.ActionImportSQL, in.InstanceID, at, string(payload))
	}
	log := m.a.s.log
	if err != nil {
		log.Error("actions: the audit row was not written", "instance", name, "action", kind, "session", in.SessionID, "job", in.JobID,
			"user", user, "outcome", res.Outcome, "detail", res.Detail, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s: %s; the audit row could not be written: %v", res.Outcome, res.Detail, err))
		return
	}
	log.Info("actions: attempt", "instance", name, "action", kind, "session", in.SessionID, "job", in.JobID, "user", user,
		"outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	switch res.Outcome {
	case mssql.OutcomeRefused:
		code = http.StatusConflict
	case mssql.OutcomeFailed:
		code = http.StatusBadGateway
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	out := map[string]string{"outcome": res.Outcome, "detail": res.Detail, "statement": res.Statement, "server_message": res.ServerMessage}
	if code != http.StatusOK {
		out["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(out)
}

// sqlMSSQLActionsLog is one SQL Server instance's audit, newest first.
const sqlMSSQLActionsLog = `
SELECT action_id, at, ui_user, client, action, outcome, pid AS session_id, backend_start AS login_time, target_user, target_app,
       target_host, target AS job_name, target_id AS job_id, statement, server_message, reason, detail
  FROM pgvigil.actions_log
 WHERE instance_id = $1 AND engine = 'sqlserver'
 ORDER BY at DESC, action_id DESC
 LIMIT 500`

// State is GET /api/mssql/actions/state?instance=N: per action whether its button is on (and why not), and the
// instance's audit rows.
func (m *MSSQLActions) State(w http.ResponseWriter, r *http.Request) {
	if m == nil || m.a == nil {
		writeErr(w, http.StatusForbidden, errors.New("actions are off on this server"))
		return
	}
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	type onOff struct {
		Enabled bool   `json:"enabled"`
		Reason  string `json:"reason,omitempty"`
	}
	out := struct {
		Actions map[string]onOff `json:"actions"`
		Log     *table           `json:"log"`
	}{Actions: map[string]onOff{}}
	var name, engine string
	if err := m.a.s.pool.QueryRow(r.Context(), `SELECT name, engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name, &engine); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	door := m.doors[name]
	for _, k := range mssql.ActionKinds {
		why := m.a.off
		if why == "" && engine != "sqlserver" {
			why = "instance " + name + " is not a SQL Server instance"
		}
		if why == "" {
			why = door.Off(name, k)
		}
		out.Actions[string(k)] = onOff{Enabled: why == "", Reason: why}
	}
	out.Log, err = m.a.s.query(r.Context(), sqlMSSQLActionsLog, id)
	m.a.s.reply(w, r, out, err)
}
