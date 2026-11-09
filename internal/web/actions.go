package web

// The actions door: POST /api/actions/cancel and /api/actions/terminate send pg_cancel_backend or
// pg_terminate_backend to one pid of a monitored server, GET /api/actions/log reads an instance's audit
// and whether its buttons are on. The work and its checks are internal/actions; this file is the HTTP
// side: the UI login, the X-Pgvigil header, the typed confirmation, and the audit row of every attempt.
//
// The rest of the server stays read-only: the audit is written through a second, small pool on the
// repository login that may call pgvigil.import_actions_log (the collector login, the config's
// repository dsn), never through the UI's read-only pool.

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
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ActionsConfig turns the actions door on: LogDSN is the repository login that writes the audit (it
// must be allowed to EXECUTE pgvigil.import_actions_log), Doors the configured instances' logins.
type ActionsConfig struct {
	LogDSN string
	Doors  map[string]actions.Door
}

// Actions holds the door's state; a nil config leaves it off with the reason, and every route still
// answers (the log stays readable, the buttons say why they are disabled).
type Actions struct {
	s     *Server
	audit *pgxpool.Pool
	doors map[string]actions.Door
	off   string // why the door is off on this server; "" = on
	run   func(ctx context.Context, d actions.Door, r actions.Request) actions.Result

	mu      sync.Mutex
	suCache map[string]suEntry // the superuser roles per instance, a minute old at most
}

// NewActions builds the door for s. It never returns nil: an error leaves the door off with the reason
// the routes then give, and is returned so serve can log it.
func (s *Server) NewActions(ctx context.Context, c *ActionsConfig) (*Actions, error) {
	a := &Actions{s: s, run: actions.Execute, suCache: map[string]suEntry{}}
	switch {
	case c == nil:
		a.off = "actions are off on this server (no actions configuration)"
		return a, nil
	case s.auth == nil:
		a.off = "actions need the UI login: this server runs with -no-login"
		return a, nil
	case strings.TrimSpace(c.LogDSN) == "":
		a.off = "actions need the repository login that writes the audit (the config's repository dsn)"
		return a, nil
	}
	a.doors = c.Doors
	pc, err := pgxpool.ParseConfig(c.LogDSN)
	if err != nil {
		a.off = "the audit login's dsn does not parse"
		return a, fmt.Errorf("actions audit dsn: %w", err)
	}
	pc.ConnConfig.ConnectTimeout = 10 * time.Second
	rp := pc.ConnConfig.RuntimeParams
	rp["application_name"] = "pgvigil-serve-audit"
	rp["statement_timeout"] = "5000"
	rp["lock_timeout"] = "2000"
	pc.MaxConns = 2
	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		a.off = "the audit login could not connect"
		return a, fmt.Errorf("actions audit: %w", err)
	}
	var may bool
	err = pool.QueryRow(ctx, `SELECT coalesce(has_function_privilege(to_regprocedure('pgvigil.import_actions_log(int, timestamptz, jsonb)'), 'EXECUTE'), false)`).Scan(&may)
	switch {
	case err != nil:
		pool.Close()
		a.off = "the audit login could not connect"
		return a, fmt.Errorf("actions audit: %w", err)
	case !may:
		pool.Close()
		a.off = "the audit login may not write the actions log: run 'pgvigil migrate' (0028) and give the config's repository dsn a login IN ROLE pgvigil_collector"
		return a, errors.New(a.off)
	}
	a.audit = pool
	return a, nil
}

// Close releases the audit pool.
func (a *Actions) Close() {
	if a != nil && a.audit != nil {
		a.audit.Close()
	}
}

// Cancel is POST /api/actions/cancel.
func (a *Actions) Cancel(w http.ResponseWriter, r *http.Request) { a.act(w, r, actions.Cancel) }

// Terminate is POST /api/actions/terminate.
func (a *Actions) Terminate(w http.ResponseWriter, r *http.Request) { a.act(w, r, actions.Terminate) }

type actionBody struct {
	InstanceID   int    `json:"instance_id"`
	PID          int    `json:"pid"`
	BackendStart string `json:"backend_start"`
	Reason       string `json:"reason"`
	Confirm      string `json:"confirm"`
}

func (a *Actions) act(w http.ResponseWriter, r *http.Request, kind actions.Kind) {
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
	user := a.s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	var in actionBody
	if err := json.NewDecoder(io.LimitReader(r.Body, 8192)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	if strings.ContainsRune(in.Reason, 0) || strings.ContainsRune(in.Confirm, 0) || strings.ContainsRune(in.BackendStart, 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was sent"))
		return
	}
	if in.InstanceID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance_id"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	var name string
	if err := a.s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, in.InstanceID).Scan(&name); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", in.InstanceID))
		return
	}
	// the audit door first: an attempt that cannot be written is not made
	if err := a.audit.Ping(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the actions log cannot be written (%v): nothing was sent", err))
		return
	}
	req := actions.Request{InstanceID: in.InstanceID, Instance: name, Kind: kind, PID: in.PID, Reason: in.Reason,
		User: user, Client: clientIP(r)}
	var res actions.Result
	if bs, err := time.Parse(time.RFC3339Nano, in.BackendStart); err != nil {
		res = actions.Result{Outcome: actions.Refused, Detail: "backend_start of the row shown is missing or not a timestamp"}
	} else if req.BackendStart = bs; strings.TrimSpace(in.Confirm) != strconv.Itoa(in.PID) {
		res = actions.Result{Outcome: actions.Refused, Detail: fmt.Sprintf("the typed confirmation is not the pid %d", in.PID)}
	} else {
		res = a.run(ctx, a.doors[name], req)
	}
	at := time.Now()
	payload, err := actions.Payload(actions.Row(at, req, res))
	if err == nil {
		_, err = a.audit.Exec(context.WithoutCancel(ctx), actions.ImportSQL, in.InstanceID, at, string(payload))
	}
	if err != nil {
		a.s.log.Error("actions: the audit row was not written", "instance", name, "action", kind, "pid", in.PID, "user", user,
			"outcome", res.Outcome, "detail", res.Detail, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s: %s; the audit row could not be written: %v", res.Outcome, res.Detail, err))
		return
	}
	a.s.log.Info("actions: attempt", "instance", name, "action", kind, "pid", in.PID, "user", user, "outcome", res.Outcome, "detail", res.Detail)
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
	out := map[string]string{"outcome": string(res.Outcome), "detail": res.Detail}
	if code != http.StatusOK {
		out["error"] = res.Detail
	}
	_ = json.NewEncoder(w).Encode(out)
}

// sqlActionsLog is one instance's audit, newest first.
const sqlActionsLog = `
SELECT action_id, at, ui_user, client, action, pid, backend_start, target_user, target_app, reason, outcome, detail
  FROM pgvigil.actions_log
 WHERE instance_id = $1
 ORDER BY at DESC, action_id DESC
 LIMIT 500`

// Log is GET /api/actions/log?instance=N: whether the instance's buttons are on (and why not), the
// superuser roles of the server (their sessions' buttons stay disabled), and the audit rows.
func (a *Actions) Log(w http.ResponseWriter, r *http.Request) {
	if a == nil {
		writeErr(w, http.StatusForbidden, errors.New("actions are off on this server"))
		return
	}
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx := r.Context()
	out := struct {
		Enabled    bool     `json:"enabled"`
		Reason     string   `json:"reason,omitempty"`
		Superusers []string `json:"superusers"`
		Log        *table   `json:"log"`
	}{Superusers: []string{}}
	var name string
	if err := a.s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	door := a.doors[name]
	switch {
	case a.off != "":
		out.Reason = a.off
	case door.Off(name) != "":
		out.Reason = door.Off(name)
	default:
		out.Enabled = true
		su, err := a.superusers(ctx, name, door.Monitor)
		if err != nil {
			out.Enabled, out.Reason = false, "the monitoring login could not read the server's roles: "+err.Error()
		} else {
			out.Superusers = su
		}
	}
	out.Log, err = a.s.query(ctx, sqlActionsLog, id)
	a.s.reply(w, r, out, err)
}

// superusers lists the server's superuser roles through the monitoring login (pg_roles is readable by any
// login), kept a minute per instance: the Running queries page asks on every refresh.
func (a *Actions) superusers(ctx context.Context, instance, dsn string) ([]string, error) {
	a.mu.Lock()
	if c, ok := a.suCache[instance]; ok && time.Since(c.at) < time.Minute {
		a.mu.Unlock()
		return c.names, nil
	}
	a.mu.Unlock()
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, errors.New("the monitoring dsn does not parse")
	}
	cfg.ConnectTimeout = 10 * time.Second
	cfg.RuntimeParams["application_name"] = "pgvigil-actions-check"
	cfg.RuntimeParams["statement_timeout"] = "5000"
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	defer func() { _ = conn.Close(context.WithoutCancel(ctx)) }()
	rows, err := conn.Query(ctx, `SELECT rolname FROM pg_roles WHERE rolsuper ORDER BY rolname`)
	if err != nil {
		return nil, err
	}
	names, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return nil, err
	}
	if names == nil {
		names = []string{}
	}
	a.mu.Lock()
	a.suCache[instance] = suEntry{at: time.Now(), names: names}
	a.mu.Unlock()
	return names, nil
}

type suEntry struct {
	at    time.Time
	names []string
}
