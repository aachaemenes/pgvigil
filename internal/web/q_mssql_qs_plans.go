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

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/mssql"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// sqlMSSQLSearch: the statements of one source whose text holds the pattern; a 'none' instance is skipped ($4), each
// row's statement under its instance's policy now (the marker; reply applies it)
const sqlMSSQLSearch = `SELECT * FROM pgvigil.mssql_statement_search($1, $2, $3, 200, $4) /* text: statement=stmt, instance_id=inst */`

// sqlMSSQLSearchNorm: the statements of the instances read as normalized ($3), out of sqlMSSQLSearch's limited read,
// matched on their WHOLE stored text (up to $4 characters) and at most searchNormRead per source: MSSQLSearch keeps
// those whose shown, normalized text holds the searched text BEFORE any cut, then cuts the statement to the 400
// characters the function shows. The function's columns, in its order.
const sqlMSSQLSearchNorm = `SELECT t.instance_id, i.name AS instance, 'plan cache'::text AS source, d.database_name AS database,
       t.query_key AS statement_key, t.object_name, left(t.query, $4) AS statement, t.seen_at
  FROM pgvigil.mssql_pc_text t JOIN pgvigil.instances i ON i.instance_id = t.instance_id
  LEFT JOIN pgvigil.mssql_pc_database d ON d.instance_id = t.instance_id AND d.database_id = t.database_id
 WHERE $2 = 'plan cache' AND t.instance_id = ANY($3) AND t.query ILIKE $1 ESCAPE '\'
UNION ALL
SELECT q.instance_id, i.name, 'Query Store', q.database_name, q.query_hash, q.object_name, left(q.query_text, $4), q.last_execution
  FROM pgvigil.mssql_qs_query q JOIN pgvigil.instances i ON i.instance_id = q.instance_id
 WHERE $2 = 'Query Store' AND q.instance_id = ANY($3) AND q.query_text ILIKE $1 ESCAPE '\'
 LIMIT 2000 /* text: statement=stmt, instance_id=inst */`

// the statement search's bounds: the rows a source shows, the characters of a shown statement (the function's
// left(.., 400)), and for the instances read as normalized the characters of a stored text matched in Go (a match
// past it is not found) - their stored matches are read up to sqlMSSQLSearchNorm's LIMIT 2000 per source, a cut
// said nowhere (a note would say how many stored texts matched)
const (
	searchRows      = 200
	searchShowChars = 400
	searchNormChars = 8000
)

// planReadBudget bounds one read on demand: the connection, the two statements and the transfer of the XML.
const planReadBudget = 30 * time.Second

var planHashForm = regexp.MustCompile(`^0x[0-9A-Fa-f]{1,16}$`)

var queryKeyForm = regexp.MustCompile(`^(0x[0-9A-Fa-f]{1,16}|0x[0-9A-Fa-f]{2,128}:-?[0-9]{1,10})$`)

// planPolicy is the instance's query_text policy as this request's door set holds it (the file's when the instance has
// none): the policy and the read login come from one generation of the doors (TestDoorsReadOnce).
func (ds *doorSet) planPolicy(name string) string {
	if qt := ds.QueryText[name]; qt != "" {
		return qt
	}
	if ds.DefaultQT != "" {
		return ds.DefaultQT
	}
	return "full"
}

// planFetchOff is why a plan cannot be read on demand for the instance on this door set, or "".
func (ds *doorSet) planFetchOff(name string) string {
	if qt := ds.planPolicy(name); qt != "full" {
		return fmt.Sprintf("not read: this instance's query_text policy is %q, and a plan carries the statement's text and its compiled parameter values, so plans are read under \"full\" only", qt)
	}
	if _, _, no := ds.readLogin("sqlserver", name); no.Why != "" {
		return "not read: " + no.Why
	}
	return ""
}

// planReadOff is why a plan cannot be read by its handle for the instance on this server and door set, or "": the
// policy and the read login (planFetchOff), then the audit door every read writes its row through (serverOff, and
// whether the audit login may call import_custom_report_run). The entries and plan sources replies carry it, so the
// buttons are off with these words before a click.
func (s *Server) planReadOff(ctx context.Context, ds *doorSet, name string) string {
	if why := ds.planFetchOff(name); why != "" {
		return why
	}
	if why := s.serverOff(); why != "" {
		return "Reading a plan by its handle needs " + why + "."
	}
	actx, cancel := context.WithTimeout(context.WithoutCancel(ctx), auditBudget)
	defer cancel()
	if err := s.mayAudit(actx); err != nil {
		return strings.Replace(err.Error(), "nothing was run", "no plan is read", 1)
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
	ds := s.doorsNow()
	s.reply(w, r, map[string]any{"entries": t, "fetch_off": s.planReadOff(r.Context(), ds, name), "policy": ds.planPolicy(name)}, nil)
}

// openPlanRead opens one short connection on the read login for a read on demand. Unlike a custom report's, the
// statements are pgvigil's own fixed reads, so a read login in sysadmin is not refused here (the collections use it;
// a departure from task 406's design).
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
	ds := s.doorsNow() // the request's one door set: the policy, the read login and the generation the audit names
	// a plan carries the statement's literals: every read is audited (op plan_read in the custom reports' log, as a
	// community tool's run), the row written before the answer; a server without the audit door sends nothing
	if why := s.planReadOff(r.Context(), ds, name); why != "" {
		s.reply(w, r, map[string]any{"state": "off", "words": why}, nil)
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	// each audit row gets its own budget, made when it is written: the read before it may take up to planReadBudget
	auditRow := func(row map[string]any) error {
		actx, acancel := context.WithTimeout(context.WithoutCancel(r.Context()), auditBudget)
		defer acancel()
		return s.auditRun(actx, row)
	}
	// a sysadmin read login is not refused: these are pgvigil's own fixed reads, the ones the
	// collectors already make on that login; openMS refuses one because a custom report runs the DBA's own SQL
	dsn, kind, _ := ds.readLogin("sqlserver", name)
	row := (&instanceRun{Door: kind, DoorGen: ds.Gen}).audit(map[string]any{"op": "plan_read", "ui_user": user, "client": clientIP(r),
		"instance_id": id, "instance": name, "params": map[string]any{"plan_handle": handleText, "start": start, "end": end, "plan_hash": want}})
	ctx, cancel := context.WithTimeout(r.Context(), planReadBudget)
	defer cancel()
	t0 := time.Now()
	db, conn, err := openPlanRead(ctx, dsn)
	if err != nil {
		row["outcome"], row["detail"], row["duration_ms"] = "failed", "the read login could not connect: "+err.Error(), time.Since(t0).Milliseconds()
		if aerr := auditRow(row); aerr != nil {
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
		if aerr := auditRow(row); aerr != nil {
			writeErr(w, http.StatusInternalServerError, fmt.Errorf("the read's audit row could not be written: %v", aerr))
			return
		}
		s.reply(w, r, map[string]any{"state": "error", "words": "the plan was not read: " + err.Error()}, nil)
		return
	}
	// the row names what was read (the state, the plan's hash, object and size), never the plan
	row["outcome"], row["duration_ms"] = "done", time.Since(t0).Milliseconds()
	row["detail"] = fmt.Sprintf("%s: %s (plan hash %s, %s %s, %d bytes)", f.State, f.Words, f.PlanHash, f.ObjType, f.Object, f.Bytes)
	if err := auditRow(row); err != nil {
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
       t.object_name, left(t.query, 400) AS "query@stmt"
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
SELECT p.plan_xml, p.plan_state, p.database_name, i.name, p.plan_note
  FROM pgvigil.mssql_running_plan p JOIN pgvigil.instances i USING (instance_id)
 WHERE p.instance_id = $1 AND p.query_hash = $2 AND p.plan_hash = $3 AND p.stmt_start = $4 AND p.stmt_end = $5`

const sqlMSSQLLivePlanXML = `
SELECT l.live_xml, l.plan_state, l.database_name, i.name, NULL::text AS plan_note
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
	var xml, state, db, inst, note *string
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
	if qt := s.doorsNow().planPolicy(name); qt != "full" {
		s.reply(w, r, map[string]any{"state": "none", "words": fmt.Sprintf("not shown: this instance's query_text policy is %q, and a plan carries the statement's text and its compiled values, so plans are shown under \"full\" only", qt)}, nil)
		return
	}
	err = s.pool.QueryRow(r.Context(), query, args...).Scan(&xml, &state, &db, &inst, &note)
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
		switch st := deref(state); {
		case st == "policy":
			words = "not kept: this instance's query_text policy is not \"full\", and a plan carries the statement's text and its compiled values"
		case st == "too large":
			words = "no plan is kept for it: it is over the 4 MB a plan may take"
		case st != "":
			words = "no plan is kept for it: " + st
		}
		s.reply(w, r, map[string]any{"state": "none", "words": words}, nil)
		return
	}
	file := fmt.Sprintf("plan-%s-%s-%s-%s.sqlplan", safeFileName(deref(inst)), safeFileName(deref(db)), tag, strings.ToLower(strings.TrimPrefix(ph, "0x")))
	// the stored note rides with the plan: a later read that failed keeps the plan read before it (0157's import) and
	// says why; the demo's plans say they are demo data
	words := "the plan kept for this running query"
	switch n := strings.TrimSpace(deref(note)); {
	case strings.HasPrefix(n, "the plan was not read: "):
		words += "; a later read failed (" + strings.TrimPrefix(n, "the plan was not read: ") + "), so this is the plan read before it"
	case n != "":
		words += "; " + n
	}
	s.reply(w, r, map[string]any{"state": "ok", "words": words, "plan": mssql.MaskPlanXML(*xml), "file": file}, nil)
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
	// the instances whose policy keeps no text, or only normalized text, by the policy NOW (the request's one door set):
	// a 'none' instance is not searched and its stored texts are never returned, whatever policy they were sent under
	// (a policy change clears no stored text)
	var noText, normalized []string
	skip, normIDs, normIn := []int{}, map[int]bool{}, []int{}
	ds := s.doorsNow()
	r = pinDoors(r, ds) // the reply's rule reads this door set too
	pol, err := s.pool.Query(ctx, `SELECT name, instance_id FROM pgvigil.instances WHERE engine = 'sqlserver' ORDER BY name`)
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	for pol.Next() {
		var n string
		var id int
		if err := pol.Scan(&n, &id); err != nil {
			pol.Close()
			s.reply(w, r, nil, err)
			return
		}
		switch ds.planPolicy(n) {
		case "none":
			skip = append(skip, id)
			if inst == nil || inst == id {
				noText = append(noText, n)
			}
		case "normalized":
			// out of the function's limited read: read apart, judged on the shown text before any cut
			normIDs[id] = true
			skip = append(skip, id)
			if inst == nil || inst == id {
				normalized = append(normalized, n)
				normIn = append(normIn, id)
			}
		}
	}
	pol.Close()
	if err := pol.Err(); err != nil {
		s.reply(w, r, nil, err)
		return
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
			var t, nt *table
			t, err = scanTable(tx.Query(ctx, sqlMSSQLSearch, pattern, name, inst, skip))
			if err == nil && len(normIn) > 0 {
				// TEXT-NOW-L: a normalized instance's row only where its shown text holds the searched text, judged on
				// the whole stored text before any cut, then cut to the 400 characters shown
				nt, err = scanTable(tx.Query(ctx, sqlMSSQLSearchNorm, pattern, name, normIn, searchNormChars))
				if err == nil {
					keepShown(nt, text, normIDs, searchShowChars)
					t, one.Note, err = mergeSearch(t, nt, searchRows)
				}
			}
			if err == nil {
				markText(sqlMSSQLSearch, t) // TEXT-NOW: a normalized instance's statements shown normalized (textread.go)
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
	out := map[string]any{"sources": sources, "text_indexes": idx, "no_text": noText, "normalized": normalized}
	if inst == nil && s.pgInstances(ctx) > 0 {
		out["note"] = pgNotHere
	}
	s.reply(w, r, out, nil)
}

// searchShown drops from a statement search's rows those of an instance read as normalized whose shown (normalized)
// statement does not hold the searched text, and gives the count dropped (TEXT-NOW-L row 3): the repository matches
// the stored text, and a stored full text's literal would otherwise answer a search the page then shows normalized - a
// side channel. Case-insensitive, as the repository's ILIKE; % and _ as they are. The count is not shown to the caller
// (it too would say a literal matched).
func searchShown(t *table, text string, normalized map[int]bool) int {
	if t == nil || len(normalized) == 0 {
		return 0
	}
	si, ii := -1, -1
	for i, c := range t.Columns {
		switch c {
		case "statement":
			si = i
		case "instance_id":
			ii = i
		}
	}
	if si < 0 || ii < 0 {
		// no statement or instance column to judge a row by while an instance is read as normalized: fails closed
		n := len(t.Rows)
		t.Rows = t.Rows[:0]
		return n
	}
	want := strings.ToLower(text)
	kept, n := t.Rows[:0], 0
	for _, r := range t.Rows {
		var id int
		switch v := r[ii].(type) {
		case int:
			id = v
		case int16:
			id = int(v)
		case int32:
			id = int(v)
		case int64:
			id = int(v)
		}
		if normalized[id] {
			if st, _ := r[si].(string); !strings.Contains(strings.ToLower(collect.NormalizeSQL(st)), want) {
				n++
				continue
			}
		}
		kept = append(kept, r)
	}
	t.Rows = kept
	return n
}

// keepShown keeps a normalized read's rows whose shown text holds the searched text, judged on the whole stored text,
// and only then cuts each statement to the cut characters shown; the count dropped is not shown.
func keepShown(t *table, text string, normalized map[int]bool, cut int) int {
	n := searchShown(t, text, normalized)
	cutStatement(t, cut)
	return n
}

// scanTable reads a query's rows into a table, the columns by their names.
func scanTable(rows pgx.Rows, err error) (*table, error) {
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	t := &table{Rows: [][]any{}}
	for _, f := range rows.FieldDescriptions() {
		t.Columns = append(t.Columns, f.Name)
	}
	for rows.Next() {
		v, err := rows.Values()
		if err != nil {
			return nil, err
		}
		t.Rows = append(t.Rows, v)
	}
	return t, rows.Err()
}

// cutStatement cuts each row's statement to its first n characters (as the function's left(statement, 400) does).
func cutStatement(t *table, n int) {
	if t == nil {
		return
	}
	si := -1
	for i, c := range t.Columns {
		if c == "statement" {
			si = i
		}
	}
	if si < 0 {
		return
	}
	for _, r := range t.Rows {
		if s, ok := r[si].(string); ok {
			if rs := []rune(s); len(rs) > n {
				r[si] = string(rs[:n])
			}
		}
	}
}

// mergeSearch merges a source's full instances' rows (the function's read, its LIMIT over them alone) and its
// normalized instances' kept rows (read apart, judged before any cut), full rows first, and cuts at limit with a note
// that counts shown rows only.
func mergeSearch(full, norm *table, limit int) (*table, string, error) {
	if norm != nil && len(norm.Columns) > 0 && strings.Join(full.Columns, ",") != strings.Join(norm.Columns, ",") {
		return nil, "", fmt.Errorf("the statement search's two reads differ in their columns: %v and %v", full.Columns, norm.Columns)
	}
	out := &table{Columns: full.Columns, Rows: append([][]any{}, full.Rows...)}
	if norm != nil {
		out.Rows = append(out.Rows, norm.Rows...)
	}
	if len(out.Rows) <= limit {
		return out, "", nil
	}
	out.Rows = out.Rows[:limit]
	return out, fmt.Sprintf("the first %d statements are shown: name an instance or search a longer text to narrow it", limit), nil
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
	name, ok := s.mssqlInstanceName(w, r, id)
	if !ok {
		return
	}
	up := func(h string) string { return "0x" + strings.ToUpper(h[2:]) }
	t, err := s.query(r.Context(), `SELECT * FROM pgvigil.mssql_plan_sources($1, $2, $3, $4)`, id, db, up(qh), up(ph))
	if err != nil {
		s.reply(w, r, nil, err)
		return
	}
	ds := s.doorsNow()
	// fetch_off: the plan cache's entries are read on demand (the policy, the read login, the audit door); running_off:
	// a kept running plan is shown under the policy full only
	runningOff := ""
	if qt := ds.planPolicy(name); qt != "full" {
		runningOff = fmt.Sprintf("not shown: this instance's query_text policy is %q", qt)
	}
	s.reply(w, r, map[string]any{"sources": t, "fetch_off": s.planReadOff(r.Context(), ds, name), "running_off": runningOff}, nil)
}
