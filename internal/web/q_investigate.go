package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

// The agent door's pages (migration 0268; docs/agents.md). A person asks for an investigation of a finding (the
// Investigate button) or asks a question (the Ask box); the site's own agent claims it through `pgvigil mcp` and
// reports; the Investigations page shows the report as the agent's own unreviewed words, and an answered ask's one
// SELECT runs here, on Run, as the custom reports' store login (reports_dsn) - never serve's login, which holds
// pgvigil_auth - so the rows shown are pgvigil's own read, not the agent's.
//
//   GET  /api/investigations          the requests (their effective state); ?id= one with its texts (a signed-in user)
//   POST /api/investigations          {kind: finding, instance_id, setting, note} or {kind: ask, question, instance_id?}
//   POST /api/investigations/close    {id, reason}
//   POST /api/investigations/run      {id}: the stored SQL of an answered ask, audited before its rows are shown
//
// Off unless the config's agents.enabled: the four answer 404 with agentsOff. The writes ride the acknowledgements'
// path: the UI login's session user, the X-Pgvigil header, the actions door's audit login, one import function that
// writes the row and its journal line. With the request queue (migrations 0200-0209): investigations are not offered in
// queue mode (investigationOff), as a queue-mode serve holds no write login to the repository; writing them through
// pgvigil_requester (scripts/agent-join-lines.sql 3) is for a later release.

// agentsOff is the words of the door when the config leaves it off (docs/agents.md quotes them).
const agentsOff = "agents.enabled is off: the agent door (the Investigate button, the Ask box and the Investigations page) is turned on in serve's pgvigil.yaml with agents: {enabled: true} (docs/agents.md)"

const (
	runRows    = 1000
	runBytes   = 4 << 20
	runTimeout = 30 * time.Second
)

func (s *Server) agentsGate(w http.ResponseWriter) bool {
	if !s.agents {
		writeErr(w, http.StatusNotFound, errors.New(agentsOff))
		return false
	}
	return true
}

// investigationOff says why requests cannot be written on this server, "" when they can.
func (s *Server) investigationOff() string {
	switch {
	case s.demo != nil:
		return "investigations are not written on a demo server"
	case s.auth == nil:
		return "investigations need the UI login: this server runs with -no-login"
	case s.queue() != nil: // q_requests.go: a queue-mode serve holds no write login to the repository
		return "investigations are not offered in queue mode (actions.via queue in pgvigil.yaml): this serve holds no " +
			"write login to the repository, and in this release only the community tools go through the queue to a collector"
	case s.actions == nil || s.actions.audit == nil:
		if s.actions != nil && s.actions.off != "" {
			return "investigations are written through the actions door's audit login, and it is off: " + s.actions.off
		}
		return "investigations are written through the actions door's audit login, and it is not connected"
	}
	return ""
}

// runOff says why an ask's Run is off here, "" when it may run.
func (s *Server) runOff(ctx context.Context) string {
	if s.reports == nil || s.reports.cfg == nil {
		if s.reports != nil && s.reports.off != "" {
			return s.reports.off
		}
		return storeNoKey
	}
	return s.reports.state(ctx)
}

// listMax is the most requests the list answers (the newest), said when cut.
const listMax = 500

// sqlInvestigations: the newest requests, each with its finding's row (value, source) or its question's start, and the
// agent that last claimed it (kept after the report: the view's claimed_by says only who holds it now).
const sqlInvestigations = `
SELECT n.id, n.kind, n.instance_id, n.instance_name AS instance, n.setting, n.finding_value AS value, n.finding_source AS source,
       CASE WHEN n.kind = 'ask' THEN pgvigil.ui_investigation_question(n.id) END AS question, n.severity, n.state, n.asked_by, n.asked_at, n.expires_at, n.claimed_by,
       n.last_agent AS agent, n.lease_until, n.claims, n.verdict, n.reported_at, n.closed_by, n.closed_at
  FROM pgvigil.investigations_now n
 WHERE ($1::text IS NULL OR n.state = $1) AND ($2::int IS NULL OR n.instance_id = $2)
 ORDER BY n.id DESC
 LIMIT 501`

// Investigations is GET /api/investigations: the list (?state=, ?instance=), or ?id= one request with its texts.
func (s *Server) Investigations(w http.ResponseWriter, r *http.Request) {
	if !s.agentsGate(w) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()
	q := r.URL.Query()
	if v := q.Get("id"); v != "" {
		id, err := strconv.ParseInt(v, 10, 64)
		if err != nil || id <= 0 {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("id: want a positive number, got %q", v))
			return
		}
		if s.auth == nil || s.sessionUser(r) == "" {
			writeErr(w, http.StatusForbidden, errors.New("a request's texts are shown to a signed-in user: this server runs with -no-login"))
			return
		}
		var text *string
		if err := s.pool.QueryRow(ctx, `SELECT pgvigil.ui_investigation_read($1)::text`, id).Scan(&text); err != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the request could not be read: %v", err))
			return
		}
		if text == nil {
			writeErr(w, http.StatusNotFound, fmt.Errorf("no investigation %d", id))
			return
		}
		var out map[string]any
		if err := json.Unmarshal([]byte(*text), &out); err != nil {
			writeErr(w, http.StatusInternalServerError, err)
			return
		}
		// Run's check (the reports login, cached a minute) only here: the list, read on every findings page, never waits on it
		run := map[string]any{"enabled": true, "said": ""}
		if why := s.runOff(ctx); why != "" {
			run = map[string]any{"enabled": false, "said": why}
		}
		out["enabled"], out["run"] = true, run
		out["writable"], out["said"] = s.investigationOff() == "", s.investigationOff()
		writeJSONNoStore(w, http.StatusOK, out)
		return
	}
	var state *string
	if v := q.Get("state"); v != "" {
		switch v {
		case "open", "claimed", "reported", "closed", "expired":
			state = &v
		default:
			writeErr(w, http.StatusBadRequest, errors.New("state must be open, claimed, reported, closed or expired"))
			return
		}
	}
	var inst *int
	if v := q.Get("instance"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("instance: want a positive number, got %q", v))
			return
		}
		inst = &n
	}
	rows, err := s.pool.Query(ctx, sqlInvestigations, state, inst)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	list, err := pgx.CollectRows(rows, pgx.RowToMap)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	if list == nil {
		list = []map[string]any{}
	}
	cut := len(list) > listMax
	if cut {
		list = list[:listMax]
	}
	writeJSONNoStore(w, http.StatusOK, map[string]any{"enabled": true, "rows": list, "cut": cut,
		"writable": s.investigationOff() == "", "said": s.investigationOff()})
}

func writeJSONNoStore(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// readBody reads a write's JSON body (8 KB, no NUL).
func readBody(w http.ResponseWriter, r *http.Request, v any) bool {
	raw, err := io.ReadAll(io.LimitReader(r.Body, 8193))
	if err != nil || len(raw) > 8192 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 8 KB"))
		return false
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return false
	}
	if err := json.Unmarshal(raw, v); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return false
	}
	return true
}

// investigationImport runs one import function on the audit login and answers its {outcome, detail, id}.
func (s *Server) investigationImport(r *http.Request, seat writeSeat, fn string, pay map[string]any) (outcome, detail string, id *int64, err error) {
	b, _ := json.Marshal(pay)
	wctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer cancel()
	pool, why, err := seat.pool(wctx, writeScope{})
	if err != nil {
		return "", "", nil, err
	}
	if pool == nil {
		return "refused", why, nil, nil
	}
	var out []byte
	if err := pool.QueryRow(wctx, `SELECT pgvigil.`+fn+`($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		return "", "", nil, err
	}
	var res struct {
		Outcome string `json:"outcome"`
		Detail  string `json:"detail"`
		ID      *int64 `json:"id"`
	}
	if err := json.Unmarshal(out, &res); err != nil {
		return "", "", nil, fmt.Errorf("%s answered %q", fn, out)
	}
	return res.Outcome, res.Detail, res.ID, nil
}

func (s *Server) answerImport(w http.ResponseWriter, fn, outcome, detail string, id *int64, err error) {
	if err != nil {
		s.log.Error("investigation: not written", "fn", fn, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	code := http.StatusOK
	o := map[string]any{"outcome": outcome, "detail": detail, "id": id}
	if outcome != "done" {
		code = http.StatusConflict
		o["error"] = detail
	}
	writeJSONNoStore(w, code, o)
}

// InvestigationAsk is POST /api/investigations: a request (a finding of one instance, or a question). The finding's
// snapshot is read by the import function itself from the findings, never taken from the body.
func (s *Server) InvestigationAsk(w http.ResponseWriter, r *http.Request) {
	if !s.agentsGate(w) {
		return
	}
	seat, ok := s.seat(w, r, s.investigationOff())
	if !ok {
		return
	}
	var in struct {
		Kind       string `json:"kind"`
		InstanceID int    `json:"instance_id"`
		Setting    string `json:"setting"`
		Value      string `json:"value"`
		Source     string `json:"source"`
		Note       string `json:"note"`
		Question   string `json:"question"`
	}
	if !readBody(w, r, &in) {
		return
	}
	pay := map[string]any{"ui_user": seat.user, "client": seat.client, "kind": in.Kind}
	if in.InstanceID > 0 {
		pay["instance_id"] = in.InstanceID
	}
	for k, v := range map[string]string{"setting": in.Setting, "value": in.Value, "source": in.Source, "note": in.Note, "question": in.Question} {
		if v != "" {
			pay[k] = v
		}
	}
	o, d, id, err := s.investigationImport(r, seat, "import_investigation_request", pay)
	s.log.Info("investigation: asked", "user", seat.user, "kind", in.Kind, "outcome", o, "detail", d)
	s.answerImport(w, "import_investigation_request", o, d, id, err)
}

// InvestigationClose is POST /api/investigations/close {id, reason}.
func (s *Server) InvestigationClose(w http.ResponseWriter, r *http.Request) {
	if !s.agentsGate(w) {
		return
	}
	seat, ok := s.seat(w, r, s.investigationOff())
	if !ok {
		return
	}
	var in struct {
		ID     int64  `json:"id"`
		Reason string `json:"reason"`
	}
	if !readBody(w, r, &in) {
		return
	}
	if in.ID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("id must be a positive investigation id"))
		return
	}
	o, d, id, err := s.investigationImport(r, seat, "import_investigation_event", map[string]any{"op": "close", "id": in.ID, "ui_user": seat.user, "reason": in.Reason})
	s.answerImport(w, "import_investigation_event", o, d, id, err)
}

// InvestigationRun is POST /api/investigations/run {id}: an answered ask's STORED SQL (a statement in the body is never
// read), run as reports_dsn through the custom reports' runner, audited through the audit login before its rows are
// shown - a refused audit (the request's record full) withholds them.
func (s *Server) InvestigationRun(w http.ResponseWriter, r *http.Request) {
	if !s.agentsGate(w) {
		return
	}
	seat, ok := s.seat(w, r, s.investigationOff())
	if !ok {
		return
	}
	var in struct {
		ID int64 `json:"id"`
	}
	if !readBody(w, r, &in) {
		return
	}
	if in.ID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("id must be a positive investigation id"))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), runTimeout+15*time.Second)
	defer cancel()
	if why := s.runOff(ctx); why != "" {
		writeErr(w, http.StatusConflict, errors.New(why))
		return
	}
	var kind, sql *string
	err := s.pool.QueryRow(ctx, `SELECT x->'row'->>'kind', x->'report'->>'sql' FROM (SELECT pgvigil.ui_investigation_read($1) AS x) q`, in.ID).Scan(&kind, &sql)
	switch {
	case err != nil:
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the request could not be read: %v", err))
		return
	case kind == nil:
		writeErr(w, http.StatusNotFound, fmt.Errorf("no investigation %d", in.ID))
		return
	case *kind != "ask":
		writeErr(w, http.StatusConflict, errors.New("only an ask has a SELECT to run"))
		return
	case sql == nil || strings.TrimSpace(*sql) == "":
		writeErr(w, http.StatusConflict, errors.New("no SELECT to run: the ask has no answer yet"))
		return
	}
	t0 := time.Now()
	res, why, rerr := StoreSelect(ctx, s.reports.cfg, "pgvigil-ask-run", *sql, runTimeout, runRows, runBytes, s.reports.refusal)
	ms := time.Since(t0).Milliseconds()
	outcome := "done"
	switch {
	case why != "":
		outcome = "refused: " + why
	case rerr != nil:
		outcome = "failed: " + rerr.Error()
	case res.Cut:
		outcome = fmt.Sprintf("done (cut at %d rows or 4 MB)", runRows)
	}
	o, d, _, aerr := s.investigationImport(r, seat, "import_investigation_event", map[string]any{"op": "run", "id": in.ID, "ui_user": seat.user,
		"rows": len(res.Rows), "ms": ms, "outcome": outcome, "sql": *sql})
	if aerr != nil {
		s.log.Error("investigation run: the audit was not written: the rows are withheld", "id", in.ID, "err", aerr)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the run's audit was not written: the rows are withheld (%v)", aerr))
		return
	}
	if o != "done" {
		writeErr(w, http.StatusConflict, errors.New(d))
		return
	}
	switch {
	case why != "":
		writeErr(w, http.StatusConflict, errors.New(why))
	case rerr != nil:
		writeErr(w, http.StatusConflict, rerr)
	default:
		writeJSONNoStore(w, http.StatusOK, map[string]any{"columns": res.Columns, "types": res.Types, "rows": res.Rows,
			"cut": res.Cut, "ms": ms, "sql": *sql})
	}
}
