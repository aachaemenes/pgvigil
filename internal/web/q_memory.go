package web

import (
	"net/http"
)

// The Memory and Pooler tabs of an instance (task 62).
//
// GET /api/memory?instance=<id>&[from=&to=] (Server.Memory): the buffer cache (the latest buffercache read's state
// and its 50 relations, and the share of shared_buffers used, dirty and held by the largest relation over the window),
// the temp-file spills of the window by statement (temp_sample's statement rows summed, with the statement's text) and
// by hour (the log's temporary-file lines and the statements' written bytes, beside the data size), the temp files by
// database over the window from the database statistics (the TempDB-shaped view: pg_stat_database's temp_files and
// temp_bytes, which count every temp file whatever log_temp_files says), and the instance's memory findings.
//
// GET /api/pooler?instance=<id>&[from=&to=] (Server.Pooler): the last pgbouncer read's state (no row: the instance
// has no pgbouncer: DSN, and the shell shows no Pooler tab), the pools as last read, the clients and servers over the
// window summed over the pools, the per-database rates of the last read, SHOW DATABASES and SHOW CONFIG as read, and
// the pooler findings. ?part=state reads the state alone (the shell's check before it shows the tab).

const sqlMemoryBufferState = `
SELECT snapshot_at, status, reason, total_buffers, used_buffers, dirty_buffers, block_size,
       total_buffers::numeric * block_size AS total_bytes
  FROM pgvigil.buffercache_sample
 WHERE instance_id = $1 AND kind = 'total' AND snapshot_at <= $2
 ORDER BY snapshot_at DESC LIMIT 1`

const sqlMemoryBufferRels = `
WITH t AS (SELECT snapshot_at, total_buffers, block_size FROM pgvigil.buffercache_sample
            WHERE instance_id = $1 AND kind = 'total' AND status = 'ok' AND snapshot_at <= $2
            ORDER BY snapshot_at DESC LIMIT 1)
SELECT r.datname, r.schemaname, r.relname, r.relkind, r.relfilenode, r.buffers, r.buffers::numeric * t.block_size AS bytes,
       round(100.0 * r.buffers / nullif(t.total_buffers, 0), 2) AS share_pct, r.dirty,
       round(100.0 * r.dirty / nullif(r.buffers, 0), 1) AS dirty_pct, round(r.usage_avg::numeric, 2) AS usage_avg, r.usage_hot
  FROM t JOIN pgvigil.buffercache_sample r ON r.instance_id = $1 AND r.snapshot_at = t.snapshot_at AND r.kind = 'rel'
 ORDER BY r.buffers DESC`

const sqlMemoryBufferSeries = `
SELECT t.snapshot_at, round(100.0 * t.used_buffers / nullif(t.total_buffers, 0), 2) AS used_pct,
       round(100.0 * t.dirty_buffers / nullif(t.total_buffers, 0), 2) AS dirty_pct,
       round(100.0 * (SELECT max(r.buffers) FROM pgvigil.buffercache_sample r
                       WHERE r.instance_id = t.instance_id AND r.snapshot_at = t.snapshot_at AND r.kind = 'rel')
             / nullif(t.total_buffers, 0), 2) AS top_rel_pct
  FROM pgvigil.buffercache_sample t
 WHERE t.instance_id = $1 AND t.kind = 'total' AND t.status = 'ok' AND t.snapshot_at > $2 AND t.snapshot_at <= $3
 ORDER BY t.snapshot_at`

// the hour rows start at their hour: an hour that began before the window's start but ends inside it is in
const sqlMemoryTempStatements = `
SELECT s.queryid, max(s.datname) AS datname, max(s.usename) AS usename, sum(s.temp_written_bytes) AS temp_written_bytes,
       sum(s.temp_read_bytes) AS temp_read_bytes, max(s.temp_written_bytes) AS worst_hour_bytes, count(*) AS hours,
       (SELECT x.query FROM pgvigil.statement_text x WHERE x.instance_id = $1 AND x.queryid = s.queryid) AS query
  FROM pgvigil.temp_sample s
 WHERE s.instance_id = $1 AND s.source = 'statement' AND s.snapshot_at > $2::timestamptz - interval '1 hour' AND s.snapshot_at <= $3
 GROUP BY s.queryid
 ORDER BY sum(s.temp_written_bytes) DESC NULLS LAST
 LIMIT 100`

const sqlMemoryTempHours = `
SELECT snapshot_at, temp_written_bytes, log_files, log_bytes, log_max_file_bytes, data_bytes,
       round(100.0 * greatest(coalesce(log_bytes, 0), coalesce(temp_written_bytes, 0)) / nullif(data_bytes, 0), 2) AS data_pct
  FROM pgvigil.temp_sample
 WHERE instance_id = $1 AND source = 'hour' AND snapshot_at > $2::timestamptz - interval '1 hour' AND snapshot_at <= $3
 ORDER BY snapshot_at`

const sqlMemoryTempDatabases = `
SELECT datname, sum(temp_files)::bigint AS temp_files, sum(temp_bytes)::bigint AS temp_bytes,
       max(temp_bytes::float8 / nullif(interval_secs, 0)) AS peak_bytes_s
  FROM pgvigil.dbstats_rate($1, $2, $3)
 WHERE NOT reset
 GROUP BY datname
 ORDER BY sum(temp_bytes) DESC NULLS LAST`

const sqlMemoryFindings = `
SELECT severity, setting, value, suggested, detail, at FROM pgvigil.memory_findings
 WHERE instance_id = $1 AND setting NOT IN ('clients waiting on the pooler', 'a pool at its size')
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, at DESC`

// Memory serves the Memory tab of one instance.
func (s *Server) Memory(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multi(w, r, []part{
		{"buffer_state", sqlMemoryBufferState, []any{id, to}},
		{"buffer_rels", sqlMemoryBufferRels, []any{id, to}},
		{"buffer_series", sqlMemoryBufferSeries, []any{id, from, to}},
		{"temp_statements", sqlMemoryTempStatements, []any{id, from, to}},
		{"temp_hours", sqlMemoryTempHours, []any{id, from, to}},
		{"temp_databases", sqlMemoryTempDatabases, []any{id, from, to}},
		{"findings", sqlMemoryFindings, []any{id}},
	})
}

const sqlPoolerState = `
SELECT snapshot_at, status, reason, version, last_ok, databases, config FROM pgvigil.pooler_state WHERE instance_id = $1`

const sqlPoolerPools = `
SELECT p.database, p.usr AS "user", p.cl_active, p.cl_waiting, p.sv_active, p.sv_idle, p.sv_used, p.sv_tested, p.sv_login,
       p.maxwait_ms, p.pool_mode, p.pool_size, p.snapshot_at
  FROM pgvigil.pooler_sample p
 WHERE p.instance_id = $1 AND p.kind = 'pool'
   AND p.snapshot_at = (SELECT max(x.snapshot_at) FROM pgvigil.pooler_sample x
                         WHERE x.instance_id = $1 AND x.kind = 'pool' AND x.snapshot_at <= $2)
 ORDER BY p.cl_waiting DESC NULLS LAST, p.database, p.usr`

const sqlPoolerSeries = `
SELECT snapshot_at, sum(cl_active) AS cl_active, sum(cl_waiting) AS cl_waiting, sum(sv_active) AS sv_active,
       sum(sv_idle) AS sv_idle, max(maxwait_ms) AS maxwait_ms
  FROM pgvigil.pooler_sample
 WHERE instance_id = $1 AND kind = 'pool' AND snapshot_at > $2 AND snapshot_at <= $3
 GROUP BY snapshot_at
 ORDER BY snapshot_at`

const sqlPoolerStats = `
SELECT p.database, p.xact_rate, p.query_rate, p.avg_wait_us, p.avg_query_us, p.total_xact_count, p.total_query_count,
       p.total_wait_us, p.snapshot_at
  FROM pgvigil.pooler_sample p
 WHERE p.instance_id = $1 AND p.kind = 'stats'
   AND p.snapshot_at = (SELECT max(x.snapshot_at) FROM pgvigil.pooler_sample x
                         WHERE x.instance_id = $1 AND x.kind = 'stats' AND x.snapshot_at <= $2)
 ORDER BY p.query_rate DESC NULLS LAST, p.database`

const sqlPoolerFindings = `
SELECT severity, setting, value, suggested, detail, at FROM pgvigil.memory_findings
 WHERE instance_id = $1 AND setting IN ('clients waiting on the pooler', 'a pool at its size')
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, at DESC`

// Pooler serves the Pooler tab of one instance (?part=state: the state alone).
func (s *Server) Pooler(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlPoolerState, []any{id}},
		{"pools", sqlPoolerPools, []any{id, to}},
		{"series", sqlPoolerSeries, []any{id, from, to}},
		{"stats", sqlPoolerStats, []any{id, to}},
		{"findings", sqlPoolerFindings, []any{id}},
	})
}
