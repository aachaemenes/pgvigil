package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The PostgreSQL depth reads of task 155 (migration 0095): GET /api/pgdepth?instance=<id>&part=<part>[&from=&to=]
// [&order=&limit=] (Server.PgDepth). One part per page section:
//
//	statements  pgvigil.statement_depth over the window: planning, JIT, WAL / full-page images, workers, generic and
//	            custom plans, local and temp blocks per statement (order plan, time, jit, wal, fpi, workers)
//	functions   pgvigil.function_top over the window (order total, self, calls, mean) and each database's track_functions
//	wal         the newest server state with its cells (wal_state_latest) and the state over the window, bucketed
//	slru        the SLRU caches over the window: per cache the totals, and per read the differences (slru_rate)
//	sequences   every sequence the dbchecks collection read, the fullest first
//	bloat       the btree estimates of the index_bloat collection, the most bloat first
//	checks      the dbchecks collection's catalog findings (SECURITY DEFINER, NOT VALID, DEFAULT partitions, CREATE on
//	            public, MD5)
//	findings    pgvigil.pg_depth_findings of the instance
// Every part is a read of the repository's own tables: nothing reaches the monitored server.

const sqlPgDepthStatements = `SELECT * FROM pgvigil.statement_depth($1, $2, $3, $4, $5)`

const sqlPgDepthFunctions = `SELECT * FROM pgvigil.function_top($1, $2, $3, $4, $5)`

const sqlPgDepthFunctionDBs = `
SELECT d.datname, d.track_functions, d.snapshot_at
  FROM pgvigil.depth_databases d
 WHERE d.instance_id = $1 AND d.collection = 'functions' AND d.is_present
 ORDER BY d.datname`

const sqlPgDepthWalLatest = `
SELECT w.snapshot_at, w.in_recovery, w.checkpoint_time, w.checkpoint_age_s, w.checkpoint_timeout_s, w.timeline_id,
       w.prev_timeline_id, w.timeline_changed_at, w.redo_lsn, w.wal_since_redo, w.system_identifier, w.prev_system_identifier,
       w.system_identifier_changed_at, w.client_backends, w.client_limit, w.connections_pct, w.max_connections,
       w.superuser_reserved, w.reserved_connections, w.standbys, w.archive_mode, w.archive_ready, w.archive_oldest_ready,
       w.archive_oldest_age_s, w.wal_files, w.wal_dir_bytes, w.wal_note
  FROM pgvigil.wal_state_latest w
 WHERE w.instance_id = $1`

// sqlPgDepthWalSeries: the state per $4-second bucket of the window (the bucket's highest checkpoint age, WAL since the
// redo point, sessions, .ready files and pg_wal size), at most about 600 points.
const sqlPgDepthWalSeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       max(extract(epoch FROM s.snapshot_at - s.checkpoint_time))::bigint AS checkpoint_age_s,
       max(s.wal_since_redo) AS wal_since_redo, max(s.client_backends) AS client_backends,
       max(s.max_connections - coalesce(s.superuser_reserved, 0) - coalesce(s.reserved_connections, 0)) AS client_limit,
       max(s.archive_ready) AS archive_ready, max(s.wal_dir_bytes) AS wal_dir_bytes, max(s.standbys) AS standbys,
       max(s.timeline_id) AS timeline_id
  FROM pgvigil.wal_state_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY 1
 ORDER BY 1`

const sqlPgDepthSlruTotals = `
SELECT r.family, min(r.name) AS name, sum(r.blks_hit) AS blks_hit, sum(r.blks_read) AS blks_read,
       sum(r.blks_written) AS blks_written, sum(r.blks_zeroed) AS blks_zeroed, sum(r.blks_exists) AS blks_exists,
       sum(r.flushes) AS flushes, sum(r.truncates) AS truncates,
       round(100.0 * sum(r.blks_hit) / nullif(sum(r.blks_hit) + sum(r.blks_read), 0), 1) AS hit_pct,
       count(*) FILTER (WHERE r.blks_read > 0) AS reads_with_disk
  FROM pgvigil.slru_rate($1, $2, $3) r
 GROUP BY r.family
 ORDER BY sum(r.blks_read) DESC NULLS LAST, r.family`

const sqlPgDepthSlruSeries = `
SELECT r.snapshot_at, r.family, r.interval_secs, r.blks_hit, r.blks_read, r.blks_written, r.hit_pct
  FROM pgvigil.slru_rate($1, $2, $3) r
 ORDER BY r.snapshot_at, r.family
 LIMIT 20000`

const sqlPgDepthSequences = `
SELECT q.datname, q.schema_name, q.seq_name, q.data_type, q.last_value, q.max_value, q.increment_by, q.cycles, q.readable,
       q.col_table, q.col_name, q.col_type, q.col_max, q.pct_used, q.blks_read, q.blks_hit, q.first_seen, q.snapshot_at
  FROM pgvigil.sequence_state q
 WHERE q.instance_id = $1 AND q.is_present
 ORDER BY q.pct_used DESC NULLS LAST, q.datname, q.schema_name, q.seq_name
 LIMIT $2`

const sqlPgDepthBloat = `
SELECT b.datname, b.schema_name, b.table_name, b.index_name, b.index_bytes, b.est_bytes, b.bloat_bytes, b.bloat_pct,
       b.fillfactor, b.tuples, b.partial, b.est_note, b.reindex_sql, b.first_seen, b.snapshot_at
  FROM pgvigil.index_bloat b
 WHERE b.instance_id = $1 AND b.is_present
 ORDER BY b.bloat_bytes DESC NULLS LAST, b.index_bytes DESC, b.datname, b.schema_name, b.index_name
 LIMIT $2`

const sqlPgDepthChecks = `
SELECT k.check_kind, k.datname, k.object, k.figure, k.detail, k.fix_sql, k.first_seen, k.snapshot_at
  FROM pgvigil.db_checks k
 WHERE k.instance_id = $1 AND k.is_present
 ORDER BY k.check_kind, k.datname NULLS FIRST, k.object
 LIMIT $2`

const sqlPgDepthFindings = `
SELECT f.severity, f.setting, f.value, f.suggested, f.detail, f.at
  FROM pgvigil.pg_depth_findings f
 WHERE f.instance_id = $1
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.setting, f.value`

// pgDepthOrders are the sorts of the two ordered parts.
var pgDepthOrders = map[string]map[string]bool{
	"statements": {"plan": true, "time": true, "jit": true, "wal": true, "fpi": true, "workers": true},
	"functions":  {"total": true, "self": true, "calls": true, "mean": true},
}

// PgDepth serves GET /api/pgdepth.
func (s *Server) PgDepth(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	q := r.URL.Query()
	part := q.Get("part")
	limit := 100
	if v := q.Get("limit"); v != "" {
		if limit, err = strconv.Atoi(v); err != nil || limit < 1 || limit > 2000 {
			writeErr(w, http.StatusBadRequest, errors.New("limit must be 1..2000"))
			return
		}
	}
	order := q.Get("order")
	if orders, ok := pgDepthOrders[part]; ok {
		if order == "" {
			order = map[string]string{"statements": "plan", "functions": "total"}[part]
		}
		if !orders[order] {
			writeErr(w, http.StatusBadRequest, errors.New("order is not one of this part's sorts"))
			return
		}
	}
	ctx := r.Context()
	out := map[string]*table{}
	one := func(key, sql string, args ...any) bool {
		t, err := s.query(ctx, sql, args...)
		if err != nil {
			s.reply(w, r, nil, err)
			return false
		}
		out[key] = t
		return true
	}
	switch part {
	case "statements":
		if !one("rows", sqlPgDepthStatements, id, from, to, order, limit) {
			return
		}
	case "functions":
		if !one("rows", sqlPgDepthFunctions, id, from, to, order, limit) || !one("databases", sqlPgDepthFunctionDBs, id) {
			return
		}
	case "wal":
		if !one("latest", sqlPgDepthWalLatest, id) || !one("series", sqlPgDepthWalSeries, id, from, to, ioBucket(from, to, 60)) {
			return
		}
	case "slru":
		if !one("totals", sqlPgDepthSlruTotals, id, from, to) || !one("series", sqlPgDepthSlruSeries, id, from, to) {
			return
		}
	case "sequences":
		if !one("rows", sqlPgDepthSequences, id, limit) {
			return
		}
	case "bloat":
		if !one("rows", sqlPgDepthBloat, id, limit) {
			return
		}
	case "checks":
		if !one("rows", sqlPgDepthChecks, id, limit) {
			return
		}
	case "findings":
		if !one("rows", sqlPgDepthFindings, id) {
			return
		}
	default:
		writeErr(w, http.StatusBadRequest, errors.New("part must be statements, functions, wal, slru, sequences, bloat, checks or findings"))
		return
	}
	s.reply(w, r, out, nil)
}
