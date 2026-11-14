package web

// Query Store and plans (task 406): the reads of a SQL Server instance's plans that go past what the collections
// store.
//   GET /api/mssql/plancache/entries?instance=N&db=D&key=K   the cache entries the last plan cache read held for one
//        row of the Plan cache tab (database id and query key): each plan handle with its statement offsets, plan
//        hash, SQL handle and compile time, and whether a plan can be read on demand here (and why not)
//                                                                                      -> Server.MSSQLPlanCacheEntries
//   GET /api/mssql/plancache/plan?instance=N&handle=0x..&start=S&end=E[&hash=0x..]  one cached plan read on demand
//        through the instance's read login (sys.dm_exec_text_query_plan at the statement's offsets; 0 and -1 = the
//        batch): {state, words, plan_hash, objtype, database, object, bytes, file, plan}. The plan follows the
//        instance's query_text policy as a stored Query Store plan does: read under "full" only, else refused with the
//        words; under full its T-SQL password forms are masked (mssql.MaskPlanXML).
//                                                                                        -> Server.MSSQLPlanCachePlan
// Nothing here writes on the monitored server: one SELECT of two DMVs per call.

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
	"github.com/jackc/pgx/v5"
)

// planReadBudget bounds one read on demand: the connection, the two statements and the transfer of the XML.
const planReadBudget = 30 * time.Second

var planHashForm = regexp.MustCompile(`^0x[0-9A-Fa-f]{1,16}$`)

var queryKeyForm = regexp.MustCompile(`^(0x[0-9A-Fa-f]{1,16}|0x[0-9A-Fa-f]{2,128}:-?[0-9]{1,10})$`)

// mssqlPlanPolicy is the instance's query_text policy (the file's when the instance has none).
func (s *Server) mssqlPlanPolicy(name string) string {
	c := s.plansConfig()
	if qt, ok := c.QueryText[name]; ok && qt != "" {
		return qt
	}
	if c.DefaultQueryText != "" {
		return c.DefaultQueryText
	}
	return "full"
}

// planFetchOff is why a plan cannot be read on demand for the instance here, or "".
func (s *Server) planFetchOff(name string) string {
	if qt := s.mssqlPlanPolicy(name); qt != "full" {
		return fmt.Sprintf("not read: this instance's query_text policy is %q, and a plan carries the statement's text and its compiled parameter values, so plans are read under \"full\" only", qt)
	}
	if _, why := s.msRunLogin(name); why != "" {
		return "not read: " + why
	}
	return ""
}

// mssqlInstanceName is the SQL Server instance's name, or a 400 / 404 already written.
func (s *Server) mssqlInstanceName(w http.ResponseWriter, r *http.Request, id int) (string, bool) {
	name, engine, err := s.communityInstance(r.Context(), id)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, fmt.Errorf("no instance %d", id))
		return "", false
	}
	if err != nil {
		s.reply(w, r, nil, err)
		return "", false
	}
	if engine != "sqlserver" {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("instance %d is not a SQL Server instance", id))
		return "", false
	}
	return name, true
}

const sqlMSSQLPCEntries = `
SELECT l.plan_handle, l.stmt_start, l.stmt_end, l.creation_time, h.plan_hash, h.sql_handle,
       l.execution_count, round(l.worker_us / 1000.0, 3) AS cpu_ms, round(l.elapsed_us / 1000.0, 3) AS duration_ms,
       l.logical_reads, s.snapshot_at AS read_at
  FROM pgvigil.mssql_pc_last l
  LEFT JOIN pgvigil.mssql_pc_handles h ON h.instance_id = l.instance_id AND h.plan_handle = l.plan_handle AND h.stmt_start = l.stmt_start
                                      AND h.stmt_end = l.stmt_end AND h.creation_time = l.creation_time
  LEFT JOIN pgvigil.mssql_pc_state s ON s.instance_id = l.instance_id
 WHERE l.instance_id = $1 AND l.database_id = $2 AND l.query_key = $3
 ORDER BY l.worker_us DESC, l.plan_handle, l.stmt_start
 LIMIT 50`

// MSSQLPlanCacheEntries is GET /api/mssql/plancache/entries.
func (s *Server) MSSQLPlanCacheEntries(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	db, err := strconv.Atoi(q.Get("db"))
	if err != nil || db < 0 {
		writeErr(w, http.StatusBadRequest, errors.New("db must be a database id"))
		return
	}
	key := q.Get("key")
	if !queryKeyForm.MatchString(key) {
		writeErr(w, http.StatusBadRequest, errors.New("key must be a query key of the Plan cache tab (a query hash, or handle:offset)"))
		return
	}
	name, ok := s.mssqlInstanceName(w, r, id)
	if !ok {
		return
	}
	t, err := s.query(r.Context(), sqlMSSQLPCEntries, id, db, key)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	s.reply(w, r, map[string]any{"entries": t, "fetch_off": s.planFetchOff(name), "policy": s.mssqlPlanPolicy(name)}, nil)
}

// openPlanRead opens one short connection on the read login for a read on demand. Unlike a custom report's, the
// statements are pgvigil's own fixed reads, so a read login in sysadmin is not refused here (the collections use it).
func openPlanRead(ctx context.Context, dsn string) (*sql.DB, *sql.Conn, error) {
	db, err := mssqlopen.Open(mssqlApp(dsn, "pgvigil-plan"))
	if err != nil {
		return nil, nil, fmt.Errorf("dsn: %w", err)
	}
	db.SetMaxOpenConns(1)
	conn, err := db.Conn(ctx)
	if err != nil {
		_ = db.Close()
		return nil, nil, fmt.Errorf("connect: %w", err)
	}
	if _, err := conn.ExecContext(ctx, "SET NOCOUNT ON; SET LOCK_TIMEOUT 2000; SET DEADLOCK_PRIORITY LOW;"); err != nil {
		_ = conn.Close()
		_ = db.Close()
		return nil, nil, err
	}
	return db, conn, nil
}

// planFileName is the .sqlplan's name: the instance, the database and the plan hash (or the handle's last digits).
func planFileName(instance string, f mssql.PlanFetch, handle string) string {
	tag := strings.TrimPrefix(strings.ToLower(f.PlanHash), "0x")
	if tag == "" {
		h := strings.ToLower(strings.TrimPrefix(strings.TrimPrefix(handle, "0x"), "0X"))
		if len(h) > 16 {
			h = h[len(h)-16:]
		}
		tag = "h" + h
	}
	parts := []string{"plan", safeFileName(instance)}
	if f.Database != "" {
		parts = append(parts, safeFileName(f.Database))
	}
	return strings.Join(append(parts, tag), "-") + ".sqlplan"
}

// MSSQLPlanCachePlan is GET /api/mssql/plancache/plan.
func (s *Server) MSSQLPlanCachePlan(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	handleText := q.Get("handle")
	handle, err := mssql.ParsePlanHandle(handleText)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	start, end := 0, -1
	if v := q.Get("start"); v != "" {
		if start, err = strconv.Atoi(v); err != nil || start < 0 {
			writeErr(w, http.StatusBadRequest, errors.New("start must be a statement's start offset (0 or more)"))
			return
		}
	}
	if v := q.Get("end"); v != "" {
		if end, err = strconv.Atoi(v); err != nil || end < -1 || (end >= 0 && end < start) {
			writeErr(w, http.StatusBadRequest, errors.New("end must be the statement's end offset (-1 = the end of the batch)"))
			return
		}
	}
	want := q.Get("hash")
	if want != "" && !planHashForm.MatchString(want) {
		writeErr(w, http.StatusBadRequest, errors.New("hash must be a plan hash (0x and up to 16 hex digits)"))
		return
	}
	name, ok := s.mssqlInstanceName(w, r, id)
	if !ok {
		return
	}
	if why := s.planFetchOff(name); why != "" {
		s.reply(w, r, map[string]any{"state": "off", "words": why}, nil)
		return
	}
	dsn, _ := s.msRunLogin(name)
	ctx, cancel := context.WithTimeout(r.Context(), planReadBudget)
	defer cancel()
	db, conn, err := openPlanRead(ctx, dsn)
	if err != nil {
		s.reply(w, r, map[string]any{"state": "error", "words": "the read login could not connect: " + err.Error()}, nil)
		return
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()
	f, err := mssql.PlanByHandle(ctx, conn, handle, start, end, want)
	if err != nil {
		s.reply(w, r, map[string]any{"state": "error", "words": "the plan was not read: " + err.Error()}, nil)
		return
	}
	out := map[string]any{"state": f.State, "words": f.Words, "plan_hash": f.PlanHash, "objtype": f.ObjType, "database": f.Database,
		"object": f.Object, "bytes": f.Bytes, "policy": "full"}
	if f.XML != "" && (f.State == "ok" || f.State == "changed") {
		out["plan"] = f.XML // masked by PlanByHandle (MaskPlanXML)
		out["file"] = planFileName(name, f, handleText)
	}
	if f.State == "gone" {
		out["error"] = f.Words // the 404's reason, as writeErr gives it
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusNotFound)
		_ = json.NewEncoder(w).Encode(out)
		return
	}
	s.reply(w, r, out, nil)
}

// ---- the plans of running queries (mssql_running_plans, mssql_live_plans) ------------------------------------------
//   GET /api/mssql/runningplans?instance=N[&from=&to=]   the plans kept for running queries last seen in the window,
//        with their live captures counted, and the two collections' last runs (off by default: no row = never run)
//                                                                                        -> Server.MSSQLRunningPlans
//   GET /api/mssql/runningplans/plan?instance=N&qh=0x..&ph=0x..&start=S&end=E[&live=ID]   one kept plan (or one live
//        capture) as {state, words, plan, file}                                        -> Server.MSSQLRunningPlan

const sqlMSSQLRunningPlans = `
SELECT p.database_name AS database, p.query_hash, p.plan_hash, p.stmt_start, p.stmt_end, p.first_seen, p.last_seen, p.reads,
       p.max_requests, p.max_cpu_ms, p.max_grant_kb, p.max_longest_ms, p.reasons, p.plan_state, p.plan_note, p.plan_bytes,
       p.plan_read_at, (p.plan_xml IS NOT NULL) AS has_plan,
       (SELECT count(*) FROM pgvigil.mssql_live_plan l WHERE l.instance_id = p.instance_id AND l.query_hash = p.query_hash
           AND l.plan_hash = p.plan_hash AND l.stmt_start = p.stmt_start AND l.stmt_end = p.stmt_end) AS live_captures,
       (SELECT max(l.live_id) FROM pgvigil.mssql_live_plan l WHERE l.instance_id = p.instance_id AND l.query_hash = p.query_hash
           AND l.plan_hash = p.plan_hash AND l.stmt_start = p.stmt_start AND l.stmt_end = p.stmt_end AND l.live_xml IS NOT NULL) AS live_newest,
       t.object_name, left(t.query, 400) AS query
  FROM pgvigil.mssql_running_plan p
  LEFT JOIN pgvigil.mssql_pc_text t ON t.instance_id = p.instance_id AND t.query_key = p.query_hash
 WHERE p.instance_id = $1 AND p.last_seen > $2 AND p.first_seen <= $3
 ORDER BY p.max_cpu_ms DESC NULLS LAST, p.last_seen DESC
 LIMIT 500`

const sqlMSSQLLiveRead = `SELECT snapshot_at, asked, read, note FROM pgvigil.mssql_live_read WHERE instance_id = $1`

// MSSQLRunningPlans is GET /api/mssql/runningplans.
func (s *Server) MSSQLRunningPlans(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"plans", sqlMSSQLRunningPlans, []any{id, from, to}},
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_running_plans", "mssql_live_plans"}}},
		{"live_read", sqlMSSQLLiveRead, []any{id}},
	})
}

const sqlMSSQLRunningPlanXML = `
SELECT p.plan_xml, p.plan_state, p.database_name, i.name
  FROM pgvigil.mssql_running_plan p JOIN pgvigil.instances i USING (instance_id)
 WHERE p.instance_id = $1 AND p.query_hash = $2 AND p.plan_hash = $3 AND p.stmt_start = $4 AND p.stmt_end = $5`

const sqlMSSQLLivePlanXML = `
SELECT l.live_xml, l.plan_state, l.database_name, i.name
  FROM pgvigil.mssql_live_plan l JOIN pgvigil.instances i USING (instance_id)
 WHERE l.instance_id = $1 AND l.query_hash = $2 AND l.plan_hash = $3 AND l.stmt_start = $4 AND l.stmt_end = $5 AND l.live_id = $6`

// MSSQLRunningPlan is GET /api/mssql/runningplans/plan.
func (s *Server) MSSQLRunningPlan(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	qh, ph := q.Get("qh"), q.Get("ph")
	if !planHashForm.MatchString(qh) || !planHashForm.MatchString(ph) {
		writeErr(w, http.StatusBadRequest, errors.New("qh and ph must be a query hash and a plan hash (0x and up to 16 hex digits)"))
		return
	}
	start, err1 := strconv.Atoi(q.Get("start"))
	end, err2 := strconv.Atoi(q.Get("end"))
	if err1 != nil || err2 != nil {
		writeErr(w, http.StatusBadRequest, errors.New("start and end must be the statement's offsets"))
		return
	}
	var xml, state, db, inst *string
	args := []any{id, qh, ph, start, end}
	query, tag := sqlMSSQLRunningPlanXML, "running"
	if v := q.Get("live"); v != "" {
		lid, err := strconv.ParseInt(v, 10, 64)
		if err != nil || lid <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("live must be a live capture's id"))
			return
		}
		query, tag, args = sqlMSSQLLivePlanXML, "live", append(args, lid)
	}
	err = s.pool.QueryRow(r.Context(), query, args...).Scan(&xml, &state, &db, &inst)
	if errors.Is(err, pgx.ErrNoRows) {
		writeErr(w, http.StatusNotFound, errors.New("no such plan is kept"))
		return
	}
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	if xml == nil || *xml == "" {
		words := "no plan is kept for it"
		if deref(state) == "policy" {
			words = "not kept: this instance's query_text policy is not \"full\", and a plan carries the statement's text and its compiled values"
		} else if deref(state) != "" {
			words = "no plan is kept for it: " + deref(state)
		}
		s.reply(w, r, map[string]any{"state": "none", "words": words}, nil)
		return
	}
	name := fmt.Sprintf("plan-%s-%s-%s-%s.sqlplan", safeFileName(deref(inst)), safeFileName(deref(db)), tag, strings.ToLower(strings.TrimPrefix(ph, "0x")))
	s.reply(w, r, map[string]any{"state": "ok", "words": "the plan kept for this running query", "plan": mssql.MaskPlanXML(*xml), "file": name}, nil)
}
