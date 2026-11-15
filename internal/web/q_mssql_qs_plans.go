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
	"github.com/jackc/pgx/v5/pgconn"
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
	if _, _, no := s.doorsNow().readLogin("sqlserver", name); no.Why != "" {
		return "not read: " + no.Why
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
// statements are pgvigil's own fixed reads, so a read login in sysadmin is not refused here (the collections use it;
// task 406's FOLD records the departure from its design).
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
	// a plan carries the statement's literals: every read is audited (op plan_read in the custom reports' log, as a
	// community tool's run), the row written before the answer; a server without the audit door sends nothing
	if why := s.serverOff(); why != "" {
		s.reply(w, r, map[string]any{"state": "off", "words": "Reading a plan by its handle needs " + why + "."}, nil)
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	actx, acancel := context.WithTimeout(context.WithoutCancel(r.Context()), auditBudget)
	defer acancel()
	if err := s.mayAudit(actx); err != nil {
		s.reply(w, r, map[string]any{"state": "off", "words": strings.Replace(err.Error(), "nothing was run", "the plan was not read", 1)}, nil)
		return
	}
	// a sysadmin read login is not refused (task 406's FOLD): these are pgvigil's own fixed reads, the ones the
	// collectors already make on that login; openMS refuses one because a custom report runs the DBA's own SQL
	ds := s.doorsNow()
	dsn, kind, _ := ds.readLogin("sqlserver", name)
	row := (&instanceRun{Door: kind, DoorGen: ds.Gen}).audit(map[string]any{"op": "plan_read", "ui_user": user, "client": clientIP(r),
		"instance_id": id, "instance": name, "params": map[string]any{"plan_handle": handleText, "start": start, "end": end, "plan_hash": want}})
	ctx, cancel := context.WithTimeout(r.Context(), planReadBudget)
	defer cancel()
	t0 := time.Now()
	db, conn, err := openPlanRead(ctx, dsn)
	if err != nil {
		row["outcome"], row["detail"], row["duration_ms"] = "failed", "the read login could not connect: "+err.Error(), time.Since(t0).Milliseconds()
		if aerr := s.auditRun(actx, row); aerr != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the read's audit row could not be written: %v", aerr))
			return
		}
		s.reply(w, r, map[string]any{"state": "error", "words": "the read login could not connect: " + err.Error()}, nil)
		return
	}
	defer func() { _ = conn.Close(); _ = db.Close() }()
	f, err := mssql.PlanByHandle(ctx, conn, handle, start, end, want)
	if err != nil {
		row["outcome"], row["detail"], row["duration_ms"] = "failed", "the plan was not read: "+err.Error(), time.Since(t0).Milliseconds()
		if aerr := s.auditRun(actx, row); aerr != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the read's audit row could not be written: %v", aerr))
			return
		}
		s.reply(w, r, map[string]any{"state": "error", "words": "the plan was not read: " + err.Error()}, nil)
		return
	}
	// the row names what was read (the state, the plan's hash, object and size), never the plan
	row["outcome"], row["duration_ms"] = "done", time.Since(t0).Milliseconds()
	row["detail"] = fmt.Sprintf("%s: %s (plan hash %s, %s %s, %d bytes)", f.State, f.Words, f.PlanHash, f.ObjType, f.Object, f.Bytes)
	if err := s.auditRun(actx, row); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("the read's audit row could not be written (%v): its plan is withheld", err))
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
	name, ok := s.mssqlInstanceName(w, r, id)
	if !ok {
		return
	}
	// the policy as this serve reads it now: a plan kept under 'full' is not served once the policy is narrower (the
	// collectors' policy row then drops what is kept, at their next run)
	if qt := s.mssqlPlanPolicy(name); qt != "full" {
		s.reply(w, r, map[string]any{"state": "none", "words": fmt.Sprintf("not shown: this instance's query_text policy is %q, and a plan carries the statement's text and its compiled values, so plans are shown under \"full\" only", qt)}, nil)
		return
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
		} else if deref(state) == "too large" {
			words = "no plan is kept for it: it is over the 4 MB a plan may take"
		} else if deref(state) != "" {
			words = "no plan is kept for it: " + deref(state)
		}
		s.reply(w, r, map[string]any{"state": "none", "words": words}, nil)
		return
	}
	file := fmt.Sprintf("plan-%s-%s-%s-%s.sqlplan", safeFileName(deref(inst)), safeFileName(deref(db)), tag, strings.ToLower(strings.TrimPrefix(ph, "0x")))
	s.reply(w, r, map[string]any{"state": "ok", "words": "the plan kept for this running query", "plan": mssql.MaskPlanXML(*xml), "file": file}, nil)
}

// ---- the statistics a plan was compiled with; a forced plan's failures ----------------------------------------------
//   GET /api/mssql/planstats?instance=N&source=qs&db=D&plan=P | &source=running&qh=..&ph=..&start=S&end=E
//        the plan's statistics as it saw them at compile (mssql_plan_stat_status)          -> Server.MSSQLPlanStats
//   GET /api/mssql/forcefail?instance=N   each forced plan's failures since its last reset, paged or held, and the
//        reads that saw them                                                                 -> Server.MSSQLForceFail

const sqlMSSQLPlanStats = `
SELECT stmt, stat_database AS database, stat_schema AS schema, stat_table AS "table", stat_name AS statistic, modification_count,
       table_rows, modified_pct, update_line, stale_at_compile, not_judged, sampling_pct, last_update, compatibility_level, rows_read_at, captured_at
  FROM pgvigil.mssql_plan_stat_status
 WHERE instance_id = $1 AND source = $2 AND plan_key = $3
 ORDER BY stale_at_compile DESC NULLS LAST, modification_count DESC NULLS LAST, stmt, stat_table, stat_name`

// MSSQLPlanStats is GET /api/mssql/planstats.
func (s *Server) MSSQLPlanStats(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	var key string
	switch q.Get("source") {
	case "qs":
		db, plan := q.Get("db"), q.Get("plan")
		if db == "" || len(db) > 128 {
			writeErr(w, http.StatusBadRequest, errors.New("db must be a database name"))
			return
		}
		if _, err := strconv.ParseInt(plan, 10, 64); err != nil {
			writeErr(w, http.StatusBadRequest, errors.New("plan must be a Query Store plan id"))
			return
		}
		key = db + ":" + plan
	case "running":
		qh, ph := q.Get("qh"), q.Get("ph")
		start, err1 := strconv.Atoi(q.Get("start"))
		end, err2 := strconv.Atoi(q.Get("end"))
		if !planHashForm.MatchString(qh) || !planHashForm.MatchString(ph) || err1 != nil || err2 != nil {
			writeErr(w, http.StatusBadRequest, errors.New("qh, ph, start and end must name a kept running plan"))
			return
		}
		key = fmt.Sprintf("%s|%s|%d|%d", qh, ph, start, end)
	default:
		writeErr(w, http.StatusBadRequest, errors.New("source must be qs or running"))
		return
	}
	s.multi(w, r, []part{{"stats", sqlMSSQLPlanStats, []any{id, q.Get("source"), key}}})
}

const sqlMSSQLForceFail = `
SELECT f.database_name AS database, f.plan_id, p.query_id, f.failures, f.failure_reads, f.first_failure, f.last_failure,
       f.two_in_one_read, f.two_in_24h, f.paged, p.is_forced, p.force_failure_count, p.force_failure_reason
  FROM pgvigil.mssql_qs_force_fail_status f
  LEFT JOIN pgvigil.mssql_qs_plan p ON p.instance_id = f.instance_id AND p.database_name = f.database_name AND p.plan_id = f.plan_id
 WHERE f.instance_id = $1
 ORDER BY f.paged DESC, f.last_failure DESC`

const sqlMSSQLForceFailReads = `
SELECT database_name AS database, plan_id, seen_at, count_before, count_after, rise, reset
  FROM pgvigil.mssql_qs_force_fail WHERE instance_id = $1 ORDER BY seen_at DESC LIMIT 200`

// MSSQLForceFail is GET /api/mssql/forcefail.
func (s *Server) MSSQLForceFail(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{{"plans", sqlMSSQLForceFail, []any{id}}, {"reads", sqlMSSQLForceFailReads, []any{id}}})
}

// ---- one statement on every instance; statements containing a text (PerformanceMonitor 3.13 Added 14 and 15) -------
//   GET /api/mssql/everywhere?hash=0x..[&from=&to=]   one query hash on every SQL Server instance the repository holds:
//        per instance, database and source (plan cache, Query Store) its executions, CPU, duration and reads in the
//        window, the most CPU first                                                         -> Server.MSSQLEverywhere
//   GET /api/mssql/search?q=<text>[&instance=N]   the stored SQL Server statement texts holding the text (case
//        ignored, % and _ taken as they are), per source, with each source's time bound, the trigram indexes' state
//        and the instances whose query_text policy keeps no text to search                  -> Server.MSSQLSearch
// SQL Server only: a PostgreSQL statement's queryid is not comparable across servers (to PostgreSQL 17 it hashes the
// tables' object ids; 18 hashes their names but still the server's own object ids and its build), so those
// instances are not compared or searched here, and the reply says so when the repository holds any.

const sqlMSSQLEverywhere = `SELECT * FROM pgvigil.mssql_statement_everywhere($1, $2, $3)`

const pgNotHere = "PostgreSQL instances are not compared or searched here: a PostgreSQL statement's identifier is its own server's, not one every server shares"

// pgInstances counts the PostgreSQL instances the repository holds (the reply's note when there are any).
func (s *Server) pgInstances(ctx context.Context) int {
	var n int
	_ = s.pool.QueryRow(ctx, `SELECT count(*) FROM pgvigil.instances WHERE engine = 'postgres'`).Scan(&n)
	return n
}

// MSSQLEverywhere is GET /api/mssql/everywhere.
func (s *Server) MSSQLEverywhere(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	hash := r.URL.Query().Get("hash")
	if !planHashForm.MatchString(hash) || strings.Trim(hash[2:], "0") == "" {
		writeErr(w, http.StatusBadRequest, errors.New("hash must be a query hash (0x and up to 16 hex digits, not zero)"))
		return
	}
	t, err := s.query(r.Context(), sqlMSSQLEverywhere, "0x"+strings.ToUpper(hash[2:]), from, to)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	out := map[string]any{"rows": t}
	if s.pgInstances(r.Context()) > 0 {
		out["note"] = pgNotHere
	}
	s.reply(w, r, out, nil)
}

// searchBudget is one source's time bound without a trigram index (PerformanceMonitor's 4 s per source).
const searchBudget = "4s"

var likeEscaper = strings.NewReplacer(`\`, `\\`, `%`, `\%`, `_`, `\_`)

// MSSQLSearch is GET /api/mssql/search.
func (s *Server) MSSQLSearch(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	text := strings.TrimSpace(q.Get("q"))
	if len([]rune(text)) < 3 || len(text) > 400 {
		writeErr(w, http.StatusBadRequest, errors.New("the text to find must be 3 to 400 characters"))
		return
	}
	var inst any
	if v := q.Get("instance"); v != "" {
		id, err := strconv.Atoi(v)
		if err != nil || id <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
			return
		}
		if _, ok := s.mssqlInstanceName(w, r, id); !ok {
			return
		}
		inst = id
	}
	pattern := "%" + likeEscaper.Replace(text) + "%"
	ctx := r.Context()
	type src struct {
		Source string `json:"source"`
		Rows   *table `json:"rows"`
		Note   string `json:"note,omitempty"`
	}
	var sources []src
	for _, name := range []string{"plan cache", "Query Store"} {
		one := src{Source: name}
		tx, err := s.pool.Begin(ctx)
		if err != nil {
			s.reply(w, r, nil, err)
			return
		}
		_, err = tx.Exec(ctx, "SET LOCAL statement_timeout = '"+searchBudget+"'")
		if err == nil {
			var rows pgx.Rows
			rows, err = tx.Query(ctx, `SELECT * FROM pgvigil.mssql_statement_search($1, $2, $3, 200)`, pattern, name, inst)
			if err == nil {
				t := &table{Rows: [][]any{}}
				for _, f := range rows.FieldDescriptions() {
					t.Columns = append(t.Columns, f.Name)
				}
				for rows.Next() {
					v, verr := rows.Values()
					if verr != nil {
						err = verr
						break
					}
					t.Rows = append(t.Rows, v)
				}
				rows.Close()
				if err == nil {
					err = rows.Err()
				}
				one.Rows = t
			}
		}
		_ = tx.Rollback(context.WithoutCancel(ctx))
		var pe *pgconn.PgError
		switch {
		case errors.As(err, &pe) && pe.Code == "57014":
			one.Rows, one.Note = nil, fmt.Sprintf("not searched to the end: the %s texts took longer than %s without the trigram index (docs/sqlserver-querystore.md, 'Finding statements by their text', has the DBA's statements that build it)", name, searchBudget)
		case err != nil:
			s.reply(w, r, nil, fmt.Errorf("%s: %w", name, err))
			return
		}
		sources = append(sources, one)
	}
	idx, err := s.query(ctx, `SELECT * FROM pgvigil.mssql_text_index_state()`)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	// the instances whose policy keeps no text, or only normalized text
	var noText, normalized []string
	if pol, err := s.pool.Query(ctx, `SELECT name, instance_id FROM pgvigil.instances WHERE engine = 'sqlserver' ORDER BY name`); err == nil {
		for pol.Next() {
			var n string
			var id int
			if pol.Scan(&n, &id) == nil && (inst == nil || inst == id) {
				switch s.mssqlPlanPolicy(n) {
				case "none":
					noText = append(noText, n)
				case "normalized":
					normalized = append(normalized, n)
				}
			}
		}
		pol.Close()
	}
	out := map[string]any{"sources": sources, "text_indexes": idx, "no_text": noText, "normalized": normalized}
	if inst == nil && s.pgInstances(ctx) > 0 {
		out["note"] = pgNotHere
	}
	s.reply(w, r, out, nil)
}

// ---- the plans of one statement's hashes (SQLWATCH COL#27) ----------------------------------------------------------
//   GET /api/mssql/plansources?instance=N&db=D&qh=0x..&ph=0x..   the Query Store plan, the running query's kept plan and
//        the plan cache's entries of a statement, for a slow or long-wait event's Plan button  -> Server.MSSQLPlanSources

// MSSQLPlanSources is GET /api/mssql/plansources.
func (s *Server) MSSQLPlanSources(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	db, qh, ph := q.Get("db"), q.Get("qh"), q.Get("ph")
	if db == "" || len(db) > 128 || !planHashForm.MatchString(qh) || !planHashForm.MatchString(ph) {
		writeErr(w, http.StatusBadRequest, errors.New("db, qh and ph must be a database name, a query hash and a plan hash"))
		return
	}
	up := func(h string) string { return "0x" + strings.ToUpper(h[2:]) }
	s.multi(w, r, []part{{"sources", `SELECT * FROM pgvigil.mssql_plan_sources($1, $2, $3, $4)`, []any{id, db, up(qh), up(ph)}}})
}
