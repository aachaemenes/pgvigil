package web

// The Plan page's API (task 40):
//   GET  /api/plans?instance=N[&queryid=Q][&shape=K][&q=<statement>][&from=&to=]  an instance's captured plans, newest
//        first (with queryid, shape or q: the plans of that statement), each with its rule hits counted, and whether the
//        two EXPLAIN buttons are on (and why not)                                                       -> Server.Plans
//   GET  /api/plan?id=N                       one plan: the plan as captured (the viewer draws plan_text), its notes,
//                                             and its rule hits with why each matters                   -> Server.Plan
//   POST /api/plans/explain                   {instance_id, datname, statement}: EXPLAIN (FORMAT JSON) without
//                                             execution through the monitoring login (the generic form for a $n
//                                             statement), stored as a plan                       -> Actions.Explain
//   POST /api/plans/analyze                   {instance_id, datname, statement, reason, confirm: "analyze"}: EXPLAIN
//                                             ANALYZE through the actions door (internal/actions/explain.go), audited
//                                             in actions_log, the plan stored                    -> Actions.ExplainAnalyze
// The two POSTs need the UI login and the X-Pgvigil header, as cancel and terminate do; they store the plan through the
// actions door's repository login (it may call every import_*). The demo serve (no login) refuses them with the reason.
// The per-instance EXPLAIN ANALYZE switch and query-text policy come from the config through SetPlans.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/actions"
	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/plans"
)

// PlansConfig is what the Plan page needs from the config, by instance name: the EXPLAIN ANALYZE gate (off when
// absent) and the query-text policy a stored plan follows (full when absent).
type PlansConfig struct {
	Gates     map[string]actions.ExplainGate
	QueryText map[string]string
}

var plansConfigs sync.Map // *Server -> PlansConfig

// SetPlans gives the server its Plan page configuration (serve calls it after Open).
func (s *Server) SetPlans(c PlansConfig) { plansConfigs.Store(s, c) }

func (s *Server) plansConfig() PlansConfig {
	if v, ok := plansConfigs.Load(s); ok {
		return v.(PlansConfig)
	}
	return PlansConfig{}
}

var shapeKeyRE = regexp.MustCompile(`^[0-9a-f]{32}$`)

// sqlPlansList: an instance's plans in the window (or every plan of one statement, any age), with their rule hits.
const sqlPlansList = `
SELECT p.plan_id, p.source, p.captured_at, p.first_seen, p.queryid, p.datname, p.usename, p.duration_ms, p.calls, p.total_ms,
       p.analyzed, p.format, left(coalesce(p.query, st.query, ''), 300) AS query, p.plan_note,
       (SELECT count(*) FROM pgvigil.plan_rules(p.plan)) AS hits,
       (SELECT string_agg(DISTINCT r.rule, ', ') FROM pgvigil.plan_rules(p.plan) r) AS rules
  FROM pgvigil.plans p
  LEFT JOIN LATERAL (SELECT t.query FROM pgvigil.statement_text t WHERE t.instance_id = p.instance_id AND t.queryid = p.queryid LIMIT 1) st ON p.query IS NULL
 WHERE p.instance_id = $1
   AND CASE WHEN $4::bigint IS NOT NULL THEN p.queryid = $4
            WHEN $5::text IS NOT NULL THEN p.shape_key = $5
            ELSE p.captured_at > $2 AND p.captured_at <= $3 END
 ORDER BY p.captured_at DESC, p.plan_id DESC
 LIMIT 200`

const sqlPlanOne = `
SELECT p.plan_id, p.instance_id, i.name AS instance, p.source, p.captured_at, p.first_seen, p.queryid, p.planid, p.datname, p.usename,
       coalesce(p.query, (SELECT t.query FROM pgvigil.statement_text t WHERE t.instance_id = p.instance_id AND t.queryid = p.queryid LIMIT 1)) AS query,
       p.duration_ms, p.calls, p.total_ms, p.analyzed, p.format, p.plan_text, p.plan_note, p.shape_key,
       (p.plan->>'Planning Time')::float8 AS planning_ms, (p.plan->>'Execution Time')::float8 AS execution_ms
  FROM pgvigil.plans p JOIN pgvigil.instances i USING (instance_id)
 WHERE p.plan_id = $1`

const sqlPlanHits = `
SELECT r.rule, r.severity, r.node_path, r.node_type, r.object, r.value, r.why, r.suggested
  FROM pgvigil.plans p CROSS JOIN LATERAL pgvigil.plan_rules(p.plan) r
 WHERE p.plan_id = $1
 ORDER BY r.severity = 'warning' DESC, r.node_path, r.rule`

// planButtons says whether the two EXPLAIN buttons work for an instance, and why not.
type planButtons struct {
	Explain       bool   `json:"explain"`
	ExplainReason string `json:"explain_reason,omitempty"`
	Analyze       bool   `json:"analyze"`
	AnalyzeReason string `json:"analyze_reason,omitempty"`
}

func (s *Server) planButtons(name string) planButtons {
	a := s.actions
	var b planButtons
	switch {
	case a == nil:
		b.ExplainReason = "actions are off on this server"
	case a.off != "":
		b.ExplainReason = a.off
	case a.doors[name].Monitor == "":
		b.ExplainReason = fmt.Sprintf("instance %s has no monitoring dsn in this server's config", name)
	default:
		b.Explain = true
	}
	switch g := s.plansConfig().Gates[name]; {
	case !b.Explain:
		b.AnalyzeReason = b.ExplainReason
	case g.Off(name) != "":
		b.AnalyzeReason = g.Off(name)
	default:
		b.Analyze = true
	}
	return b
}

// Plans is GET /api/plans.
func (s *Server) Plans(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	var queryid, shape any
	if v := q.Get("queryid"); v != "" {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil {
			writeErr(w, http.StatusBadRequest, errors.New("queryid must be a number"))
			return
		}
		queryid = n
	}
	if v := q.Get("shape"); v != "" {
		if !shapeKeyRE.MatchString(v) {
			writeErr(w, http.StatusBadRequest, errors.New("shape must be a shape_key (32 hex characters)"))
			return
		}
		shape = v
	}
	ctx := r.Context()
	if v := q.Get("q"); v != "" && queryid == nil && shape == nil {
		if len(v) > plans.MaxStatement {
			writeErr(w, http.StatusBadRequest, errors.New("q is too long"))
			return
		}
		var k string
		if err := s.pool.QueryRow(ctx, `SELECT md5(pgvigil.slow_shape($1))`, v).Scan(&k); err != nil {
			s.reply(w, r, nil, err)
			return
		}
		shape = k
	}
	var name string
	if err := s.pool.QueryRow(ctx, `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&name); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return
	}
	out := struct {
		Buttons planButtons `json:"buttons"`
		Shape   any         `json:"shape"`
		Plans   *table      `json:"plans"`
	}{Buttons: s.planButtons(name), Shape: shape}
	out.Plans, err = s.query(ctx, sqlPlansList, id, from, to, queryid, shape)
	s.reply(w, r, out, err)
}

// Plan is GET /api/plan?id=N.
func (s *Server) Plan(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(r.URL.Query().Get("id"), 10, 64)
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("id must be a positive plan_id"))
		return
	}
	ctx := r.Context()
	plan, err := s.query(ctx, sqlPlanOne, id)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if len(plan.Rows) == 0 {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no plan %d", id))
		return
	}
	hits, err := s.query(ctx, sqlPlanHits, id)
	name, _ := plan.Rows[0][2].(string)
	s.reply(w, r, map[string]any{"plan": plan, "hits": hits, "buttons": s.planButtons(name)}, err)
}

type explainBody struct {
	InstanceID int    `json:"instance_id"`
	Datname    string `json:"datname"`
	Statement  string `json:"statement"`
	Reason     string `json:"reason"`
	Confirm    string `json:"confirm"`
}

// door checks what both POSTs need: the header, the door on, the login, the body, the instance.
func (a *Actions) planRequest(w http.ResponseWriter, r *http.Request) (in explainBody, name, user string, ok bool) {
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
	if user = a.s.sessionUser(r); user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 2*plans.MaxStatement)).Decode(&in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	if in.InstanceID <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance_id must be a positive instance_id"))
		return
	}
	if strings.ContainsRune(in.Statement, 0) || strings.ContainsRune(in.Datname, 0) || strings.ContainsRune(in.Reason, 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was run"))
		return
	}
	if len(in.Datname) > 63 {
		writeErr(w, http.StatusBadRequest, errors.New("datname is longer than a database name can be"))
		return
	}
	if err := a.s.pool.QueryRow(r.Context(), `SELECT name FROM pgvigil.instances WHERE instance_id = $1`, in.InstanceID).Scan(&name); err != nil {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", in.InstanceID))
		return
	}
	return in, name, user, true
}

// storePlan writes a plan row through the door's repository login, after the instance's query-text policy, and
// returns its plan_id (0 when the policy keeps no plan).
func (a *Actions) storePlan(ctx context.Context, instanceID int, name string, row plans.Row) (int64, string, error) {
	if !collect.MaskPlan(&row, a.s.plansConfig().QueryText[name]) {
		return 0, "the instance's query_text policy is none: the plan was not stored", nil
	}
	payload, err := json.Marshal([]plans.Row{row})
	if err != nil {
		return 0, "", err
	}
	if _, err := a.audit.Exec(ctx, `SELECT pgvigil.import_plans($1, $2, $3::jsonb)`, instanceID, row.CapturedAt, string(payload)); err != nil {
		return 0, "", fmt.Errorf("the plan could not be stored: %w", err)
	}
	var id int64
	err = a.s.pool.QueryRow(ctx, `SELECT plan_id FROM pgvigil.plans WHERE instance_id = $1 AND plan_key = $2`, instanceID, row.PlanKey).Scan(&id)
	return id, "", err
}

// Explain is POST /api/plans/explain: the plan without execution, through the monitoring login.
func (a *Actions) Explain(w http.ResponseWriter, r *http.Request) {
	in, name, user, ok := a.planRequest(w, r)
	if !ok {
		return
	}
	if b := a.s.planButtons(name); !b.Explain {
		writeErr(w, http.StatusForbidden, errors.New(b.ExplainReason))
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), plans.ExplainTimeout+20*time.Second)
	defer cancel()
	row, err := plans.Explain(ctx, a.doors[name].Monitor, in.Datname, in.Statement)
	a.s.log.Info("plans: explain", "instance", name, "datname", in.Datname, "user", user, "err", err)
	if err != nil {
		writeErr(w, http.StatusConflict, err)
		return
	}
	id, note, err := a.storePlan(ctx, in.InstanceID, name, row)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	a.s.reply(w, r, map[string]any{"plan_id": id, "note": note, "plan_note": row.PlanNote, "plan_text": row.PlanText}, nil)
}

// ExplainAnalyze is POST /api/plans/analyze: EXPLAIN ANALYZE through the actions door, every attempt audited.
func (a *Actions) ExplainAnalyze(w http.ResponseWriter, r *http.Request) {
	in, name, user, ok := a.planRequest(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), actions.MaxExplainTimeout+time.Minute)
	defer cancel()
	if err := a.audit.Ping(ctx); err != nil {
		writeErr(w, http.StatusServiceUnavailable, fmt.Errorf("the actions log cannot be written (%v): nothing was run", err))
		return
	}
	req := actions.ExplainRequest{InstanceID: in.InstanceID, Instance: name, Datname: in.Datname, Statement: in.Statement,
		Reason: in.Reason, User: user, Client: clientIP(r)}
	var res actions.Result
	var row *plans.Row
	if strings.TrimSpace(strings.ToLower(in.Confirm)) != "analyze" {
		res = actions.Result{Outcome: actions.Refused, Detail: `the typed confirmation is not "analyze"`}
	} else {
		res, row = actions.ExplainAnalyze(ctx, a.doors[name], a.s.plansConfig().Gates[name], req)
	}
	at := time.Now()
	audited := req
	audited.Statement = collect.PolicyText(req.Statement, a.s.plansConfig().QueryText[name]) // the audit follows the query-text policy
	payload, err := json.Marshal([]actions.ExplainLogRow{actions.ExplainRow(at, audited, res)})
	if err == nil {
		_, err = a.audit.Exec(context.WithoutCancel(ctx), actions.ImportSQL, in.InstanceID, at, string(payload))
	}
	if err != nil {
		a.s.log.Error("plans: the EXPLAIN ANALYZE audit row was not written", "instance", name, "user", user, "outcome", res.Outcome, "detail", res.Detail, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("%s: %s; the audit row could not be written: %v", res.Outcome, res.Detail, err))
		return
	}
	a.s.log.Info("plans: explain analyze", "instance", name, "datname", in.Datname, "user", user, "outcome", res.Outcome, "detail", res.Detail)
	out := map[string]any{"outcome": string(res.Outcome), "detail": res.Detail}
	code := http.StatusOK
	switch res.Outcome {
	case actions.Refused:
		code = http.StatusConflict
	case actions.Failed:
		code = http.StatusBadGateway
	}
	if row != nil {
		id, note, err := a.storePlan(ctx, in.InstanceID, name, *row)
		switch {
		case err != nil:
			out["note"] = err.Error()
		default:
			out["plan_id"], out["note"] = id, note
		}
	}
	if code != http.StatusOK {
		out["error"] = res.Detail
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(out)
}
