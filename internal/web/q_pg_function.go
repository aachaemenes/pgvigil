package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The object page's PostgreSQL twin (OBJ: one function of pg_stat_user_functions, web/src/mssql_object.ts
// pgFunctionView) reads GET /api/pgfunction?instance=N&from=&to=&db=<dbid>&fn=<funcid>[&part=function|history|schema].

// sqlPGFunction: the function's newest read (0095's function_stats): its database, schema, name and arguments
const sqlPGFunction = `
SELECT f.datname, f.schema_name, f.func_name, f.args, f.snapshot_at
  FROM pgvigil.function_stats f
 WHERE f.instance_id = $1 AND f.dbid = $2 AND f.funcid = $3
 ORDER BY f.snapshot_at DESC
 LIMIT 1`

// sqlPGFunctionHistory: each read of the window against the read before it (up to a day earlier), function_top's rule
// (0095): a counter that went backwards - a stats reset, a restart - counts its value since then; newest first, with
// its seconds, its time per call and its time per second.
const sqlPGFunctionHistory = `
WITH s AS (
  SELECT f.snapshot_at, f.calls, f.total_ms, f.self_ms,
         lag(f.calls) OVER w AS p_calls, lag(f.total_ms) OVER w AS p_total, lag(f.self_ms) OVER w AS p_self, lag(f.snapshot_at) OVER w AS p_at
    FROM pgvigil.function_stats f
   WHERE f.instance_id = $1 AND f.dbid = $4 AND f.funcid = $5 AND f.snapshot_at > $2::timestamptz - interval '1 day' AND f.snapshot_at <= $3
  WINDOW w AS (ORDER BY f.snapshot_at)
), d AS (
  SELECT s.snapshot_at, extract(epoch FROM s.snapshot_at - s.p_at)::float8 AS interval_secs,
         CASE WHEN s.calls >= s.p_calls AND s.total_ms >= s.p_total THEN s.calls - s.p_calls ELSE s.calls END AS calls,
         CASE WHEN s.calls >= s.p_calls AND s.total_ms >= s.p_total THEN s.total_ms - s.p_total ELSE s.total_ms END AS total_ms,
         CASE WHEN s.calls >= s.p_calls AND s.total_ms >= s.p_total THEN s.self_ms - s.p_self ELSE s.self_ms END AS self_ms
    FROM s
   WHERE s.p_calls IS NOT NULL AND s.snapshot_at > $2
)
SELECT d.snapshot_at, d.interval_secs, d.calls, d.total_ms, d.self_ms, d.total_ms / nullif(d.calls, 0) AS mean_ms,
       d.total_ms / nullif(d.interval_secs, 0) AS total_ms_s
  FROM d
 ORDER BY d.snapshot_at DESC
 LIMIT 1000`

// sqlPGFunctionSchema: 0058's schema_changes of the function's name in its schema and database (its newest read names
// them; an overload shares the name, so each row carries its identity), every stored change, newest first, 200 at
// most, cut as the Schema tab's for its compare
const sqlPGFunctionSchema = `
WITH f AS (
  SELECT f.schema_name, f.func_name FROM pgvigil.function_stats f
   WHERE f.instance_id = $1 AND f.dbid = $2 AND f.funcid = $3
   ORDER BY f.snapshot_at DESC
   LIMIT 1
)
SELECT w.snapshot_at, w.prev_at, w.dbid, w.datname, w.kind, w.identity, w.schema_name, w.object_name, w.parent, w.change, w.attribute,
       ` + schemaChangeCut + `
  FROM f JOIN pgvigil.schema_changes w ON w.instance_id = $1 AND w.dbid = $2 AND w.kind IN ('function', 'procedure')
                                     AND w.schema_name = f.schema_name AND w.object_name = f.func_name
 ORDER BY w.snapshot_at DESC
 LIMIT 200`

// PGFunction is GET /api/pgfunction: db= and fn= are the function's database oid and function oid.
func (s *Server) PGFunction(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	db, err1 := strconv.ParseInt(q.Get("db"), 10, 64)
	fn, err2 := strconv.ParseInt(q.Get("fn"), 10, 64)
	if err1 != nil || err2 != nil {
		writeErr(w, http.StatusBadRequest, errors.New("db and fn must be the function's database oid and function oid"))
		return
	}
	s.multiPart(w, r, []part{
		{"function", sqlPGFunction, []any{id, db, fn}},
		{"history", sqlPGFunctionHistory, []any{id, from, to, db, fn}},
		{"schema", sqlPGFunctionSchema, []any{id, db, fn}},
	})
}
