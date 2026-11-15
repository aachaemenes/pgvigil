package web

// The actions door's verify_backup (task 301b, Database#6): POST /api/mssql/actions/verify/preview reads one backup set
// by its backup_set_uuid through the instance's read login; POST /api/mssql/actions/verify/run checks it again, audits
// 'started' and runs RESTORE VERIFYONLY detached from the request (a verify outlives the request's 30 seconds), its end
// audited when it returns - 'cut by shutdown' when serve stops under it (StopVerifies); at serve's start a 'started'
// row older than verify_timeout with no end gets 'ended unknown: serve stopped' (SweepVerifies). One verify per
// instance: a session-level advisory lock on the repository, held for the run. The checks are internal/mssql
// (verify_backup.go); the routes, the action's place in the allow list and serve's two hooks are the WIRING patch's
// (scripts/inv-301b-wiring.patch).

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/mssql"
)

// verifyLockClass is the advisory lock's first key (the second is the instance_id): one verify per instance.
const verifyLockClass = 30117

// verifyRuns is a server's detached verifies: serve's context for them, its cancel and the runs in flight.
type verifyRuns struct {
	ctx     context.Context
	cancel  context.CancelFunc
	wg      sync.WaitGroup
	timeout time.Duration
}

var verifyState sync.Map // *Server -> *verifyRuns

// verifies is the server's verify state (made on first use, verify_timeout VerifyTimeoutDefault until SetVerifyTimeout).
func (s *Server) verifies() *verifyRuns {
	if v, ok := verifyState.Load(s); ok {
		return v.(*verifyRuns)
	}
	ctx, cancel := context.WithCancel(context.Background())
	v, _ := verifyState.LoadOrStore(s, &verifyRuns{ctx: ctx, cancel: cancel, timeout: mssql.VerifyTimeoutDefault})
	return v.(*verifyRuns)
}

// SetVerifyTimeout bounds each verify (the config's verify_timeout; serve calls it at start).
func (s *Server) SetVerifyTimeout(d time.Duration) {
	if d > 0 {
		s.verifies().timeout = d
	}
}

// StopVerifies cancels every running verify and waits for their end rows, at most limit (serve's shutdown).
func (s *Server) StopVerifies(limit time.Duration) {
	v := s.verifies()
	v.cancel()
	done := make(chan struct{})
	go func() { v.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(limit):
		s.log.Warn("actions: verifies still running at shutdown; their end rows are written by the next start's sweep")
	}
}

// sqlVerifySweep writes 'ended unknown' for each 'started' verify older than the timeout with no later row of the same
// set on the instance (serve stopped under it without writing its end).
const sqlVerifySweep = `
SELECT pgvigil.import_mssql_actions_log(a.instance_id, now(), jsonb_build_array(jsonb_build_object(
         'instance_name', a.instance_name, 'ui_user', a.ui_user, 'client', a.client, 'action', 'verify_backup',
         'target', a.target, 'target_id', a.target_id, 'reason', a.reason, 'outcome', 'ended unknown',
         'detail', 'ended unknown: serve stopped (no end was written for the verify started ' || to_char(a.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC)',
         'statement', a.statement)))
  FROM pgvigil.actions_log a
 WHERE a.engine = 'sqlserver' AND a.action = 'verify_backup' AND a.outcome = 'started' AND a.at < now() - make_interval(secs => $1)
   AND NOT EXISTS (SELECT 1 FROM pgvigil.actions_log e
                    WHERE e.instance_id = a.instance_id AND e.action = 'verify_backup' AND e.target_id = a.target_id
                      AND e.at >= a.at AND e.action_id <> a.action_id AND e.outcome <> 'started')`

// SweepVerifies is serve's start: the verifies a stopped serve left without an end row.
func (s *Server) SweepVerifies(ctx context.Context) error {
	m := s.mssqlDoor()
	if m == nil || m.a == nil || m.a.audit == nil {
		return nil
	}
	_, err := m.a.audit.Exec(ctx, sqlVerifySweep, s.verifies().timeout.Seconds())
	return err
}

type verifyBody struct {
	InstanceID int             `json:"instance_id"`
	UUID       string          `json:"backup_set_uuid"`
	Shown      mssql.VerifySet `json:"shown"`
	Reason     string          `json:"reason"`
	Confirm    string          `json:"confirm"`
}

// verifyGate is the part both routes share, in the door's shape: the door on this server, the header, the UI user, the
// body, a SQL Server instance. ok false = the reply is written.
func (m *MSSQLActions) verifyGate(w http.ResponseWriter, r *http.Request) (in verifyBody, user, name string, ok bool) {
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
	if err := json.NewDecoder(io.LimitReader(r.Body, 16384)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return in, "", "", false
	}
	for _, v := range append([]string{in.UUID, in.Reason, in.Confirm, in.Shown.UUID, in.Shown.Database}, in.Shown.Paths...) {
		if strings.ContainsRune(v, 0) {
			writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was sent"))
			return in, "", "", false
		}
	}
	if in.InstanceID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance_id"))
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

// MSSQLVerifyPreview is POST /api/mssql/actions/verify/preview: the set as the read login sees it, what would be sent,
// or why it is not offered. Nothing is written to the audit.
func (s *Server) MSSQLVerifyPreview(w http.ResponseWriter, r *http.Request) {
	m := s.mssqlDoor()
	in, _, name, ok := m.verifyGate(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()
	set, stmt, why := mssql.VerifyPreview(ctx, m.doors[name], name, in.UUID)
	s.reply(w, r, struct {
		OK        bool            `json:"ok"`
		Reason    string          `json:"reason,omitempty"`
		Statement string          `json:"statement,omitempty"`
		Set       mssql.VerifySet `json:"set"`
	}{OK: why == "", Reason: why, Statement: stmt, Set: set}, nil)
}

// MSSQLVerifyRun is POST /api/mssql/actions/verify/run: the confirm step (the typed confirmation is the database's
// name). Every way out past the gate writes one audit row; a verify that starts writes 'started', then its end.
func (s *Server) MSSQLVerifyRun(w http.ResponseWriter, r *http.Request) {
	m := s.mssqlDoor()
	in, user, name, ok := m.verifyGate(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	var may bool
	if err := m.a.audit.QueryRow(ctx, sqlMSSQLAuditCheck).Scan(&may); err != nil || !may {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the actions log cannot be written (%v): nothing was sent", err))
		return
	}
	req := mssql.VerifyRequest{Instance: name, UUID: in.UUID, Shown: in.Shown, Reason: in.Reason, User: user, Client: clientIP(r)}
	audit := func(c context.Context, res mssql.VerifyResult) error {
		at := time.Now()
		payload, err := mssql.ActionPayload(mssql.VerifyRow(at, req, res))
		if err == nil {
			_, err = m.a.audit.Exec(context.WithoutCancel(c), mssql.ActionImportSQL, in.InstanceID, at, string(payload))
		}
		if err != nil {
			s.log.Error("actions: the verify's audit row was not written", "instance", name, "set", in.UUID, "user", user, "outcome", res.Outcome, "err", err)
		}
		return err
	}
	reply := func(code int, res mssql.VerifyResult) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(code)
		out := map[string]string{"outcome": res.Outcome, "detail": res.Detail, "statement": res.Statement, "server_message": res.ServerMessage}
		if code >= 400 {
			out["error"] = res.Detail
		}
		_ = json.NewEncoder(w).Encode(out)
	}
	if strings.TrimSpace(in.Confirm) == "" || strings.TrimSpace(in.Confirm) != in.Shown.Database {
		res := mssql.VerifyResult{Outcome: mssql.OutcomeRefused, Detail: "the typed confirmation is not the database's name", Set: in.Shown}
		if audit(ctx, res) != nil {
			writeErr(w, http.StatusInternalServerError, errors.New("refused; the audit row could not be written"))
			return
		}
		reply(http.StatusConflict, res)
		return
	}
	// one verify per instance: a session-level advisory lock, held by its own repository connection for the run
	lockConn, err := s.pool.Acquire(ctx)
	if err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the repository cannot hold the verify's lock (%v): nothing was sent", err))
		return
	}
	var locked bool
	if err := lockConn.QueryRow(ctx, `SELECT pg_try_advisory_lock($1, $2)`, verifyLockClass, in.InstanceID).Scan(&locked); err != nil || !locked {
		lockConn.Release()
		res := mssql.VerifyResult{Outcome: mssql.OutcomeRefused, Detail: "a verify of this pgvigil is running on " + name + ": one at a time", Set: in.Shown}
		if err != nil {
			res.Detail = fmt.Sprintf("the verify's lock could not be taken: %v", err)
		}
		_ = audit(ctx, res)
		reply(http.StatusConflict, res)
		return
	}
	unlock := func() {
		_, _ = lockConn.Exec(context.Background(), `SELECT pg_advisory_unlock($1, $2)`, verifyLockClass, in.InstanceID)
		lockConn.Release()
	}
	job, res := mssql.VerifyPrepare(ctx, m.doors[name], req)
	if res.Outcome != mssql.OutcomeStarted {
		unlock()
		_ = audit(ctx, res)
		code := http.StatusConflict
		if res.Outcome == mssql.OutcomeFailed {
			code = http.StatusBadGateway
		}
		reply(code, res)
		return
	}
	// 'started' before the goroutine: a verify whose start cannot be written is not made
	if err := audit(ctx, res); err != nil {
		unlock()
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the verify's start could not be written (%v): nothing was sent", err))
		return
	}
	v := s.verifies()
	v.wg.Add(1)
	door := m.doors[name]
	go func() {
		defer v.wg.Done()
		defer unlock()
		rctx, rcancel := context.WithTimeout(v.ctx, v.timeout)
		defer rcancel()
		end := mssql.VerifyRun(rctx, door, job)
		if v.ctx.Err() != nil {
			end.Outcome, end.Detail = mssql.OutcomeCutByShutdown, "cut by shutdown: serve stopped under the verify"
		}
		_ = audit(context.Background(), end)
		s.log.Info("actions: verify", "instance", name, "set", in.UUID, "user", user, "outcome", end.Outcome, "detail", end.Detail)
	}()
	reply(http.StatusAccepted, res)
}
