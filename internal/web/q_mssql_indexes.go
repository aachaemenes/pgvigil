package web

import (
	"net/http"
)

// The Indexes tab of a SQL Server instance (task 150; sp_IndexCleanup's and sp_BlitzIndex's reads): the index
// inventory of every user database with the rules' verdicts, the usage window and its guard, the missing-index
// requests as hints, and the statistics' health (mssql_indexes and mssql_stats, every six hours; 0092).
//
//	GET /api/mssql/indexes?instance=N[&db=<database id>][&part=...]
//	  state      the two collections' last runs
//	  databases  each database's usage window, its guard ('too early' under 7 days) and its read
//	  indexes    one row per index (db= one database's; 5,000 at most, the largest first): definition, size, rows,
//	             reads, writes, and the rule that names it with its text (never run); the object type (V an indexed
//	             view), the data space and partition function, the partitioning column, the table's create date, the
//	             operational counters and the filter columns (D404; NULL: not read)
//	  heaps      one row per heap of a user table (db= one database's; 5,000 at most, the largest first): size, rows,
//	             reads, writes, forwarded fetches, deletes, the table's create date (D404)
//	  verdicts   only the indexes a rule names, the warnings first
//	  missing    the missing-index requests, the most benefit first, with the benefit per day of uptime: hints
//	  statsdbs   each database's statistics summary
//	  stats      the statistics with a flag (stale, low sample, persisted sample, NORECOMPUTE, filtered, not incremental)
//	  findings   the index and statistics findings of the instance

const sqlMSSQLIxDatabases = `
SELECT b.database_id, b.database_name AS database, b.read_at, b.note, b.usage_since, b.usage_reason, round(b.usage_days::numeric, 1) AS usage_days,
       b.judged, b.guard, b.readable_secondary, b.restore_read, b.auto_close, b.reset_at, b.indexes, b.capped, b.server_start, b.created_at, b.last_restore,
       p.parts_read, p.parts_capped, p.note AS parts_note
  FROM pgvigil.mssql_index_db_status b
  LEFT JOIN pgvigil.mssql_index_parts p ON p.instance_id = b.instance_id AND p.database_name = b.database_name
 WHERE b.instance_id = $1
 ORDER BY b.database_name`

const sqlMSSQLIxIndexes = `
SELECT x.database_id, x.database_name AS database, x.object_id, x.index_id, x.schema_name, x.table_name, x.index_name, x.index_type,
       x.is_unique, x.is_primary_key, x.is_unique_constraint, x.fk_referenced, x.is_disabled, x.ignore_dup_key, x.fill_factor, x.compression, x.partitions,
       array_to_string(x.key_columns, ', ') AS keys, array_to_string(x.include_columns, ', ') AS includes, x.filter_definition,
       x.row_count, round(x.size_kb / 1024.0, 1) AS size_mb, x.user_seeks, x.user_scans, x.user_lookups,
       x.user_seeks + x.user_scans + x.user_lookups AS reads, x.user_updates AS writes, x.last_read, x.last_write,
       x.table_created, x.object_type, x.data_space_name, x.data_space_type, x.partition_function, x.pf_type, x.pf_partitions, x.pf_range,
       x.partition_column, x.any_uncompressed, array_to_string(x.filter_columns, ', ') AS filter_columns,
       array_to_string(x.cs_rebuild_columns, ', ') AS cs_rebuild_columns, x.row_lock_wait_count, x.row_lock_wait_ms, x.page_lock_wait_count,
       x.page_lock_wait_ms, x.page_latch_wait_count, x.page_latch_wait_ms, x.page_io_latch_wait_count, x.page_io_latch_wait_ms,
       x.forwarded_fetch_count, x.leaf_delete_count,
       v.rule, v.severity, v.detail, v.script, v.keeper,
       pgvigil.mssql_index_definition(x.index_type, x.is_unique, x.is_primary_key, x.is_unique_constraint, x.schema_name, x.table_name, x.index_name,
                                      x.key_columns, x.include_columns, x.filter_definition, x.fill_factor, x.compression, x.ignore_dup_key,
                                      x.allow_row_locks, x.allow_page_locks, x.no_recompute, b.online_index_builds, false) AS definition
  FROM pgvigil.mssql_index x
  JOIN pgvigil.mssql_index_db b ON b.instance_id = x.instance_id AND b.database_name = x.database_name
  LEFT JOIN pgvigil.mssql_index_verdicts($1) v ON v.database_name = x.database_name AND v.object_id = x.object_id AND v.index_id = x.index_id
 WHERE x.instance_id = $1 AND ($2::int IS NULL OR x.database_id = $2)
 ORDER BY x.size_kb DESC NULLS LAST, x.database_name, x.object_id, x.index_id
 LIMIT 5000`

const sqlMSSQLIxHeaps = `
SELECT h.database_id, h.database_name AS database, h.object_id, h.schema_name, h.table_name, h.row_count, round(h.size_kb / 1024.0, 1) AS size_mb,
       h.partitions, h.compression, h.data_space_name, h.data_space_type, h.partition_column, h.user_seeks, h.user_scans, h.user_lookups,
       h.user_seeks + h.user_scans + h.user_lookups AS reads, h.user_updates AS writes, h.last_read, h.last_write, h.table_created,
       h.forwarded_fetch_count, h.leaf_delete_count
  FROM pgvigil.mssql_heap h
 WHERE h.instance_id = $1 AND ($2::int IS NULL OR h.database_id = $2)
 ORDER BY h.size_kb DESC NULLS LAST, h.database_name, h.schema_name, h.table_name
 LIMIT 5000`

const sqlMSSQLIxVerdicts = `
SELECT x.database_id, v.database_name AS database, x.schema_name, x.table_name, x.index_name, v.rule, v.severity, v.detail, v.script, v.keeper,
       round(x.size_kb / 1024.0, 1) AS size_mb, x.user_seeks + x.user_scans + x.user_lookups AS reads, x.user_updates AS writes
  FROM pgvigil.mssql_index_verdicts($1) v
  JOIN pgvigil.mssql_index x ON x.instance_id = $1 AND x.database_name = v.database_name AND x.object_id = v.object_id AND x.index_id = v.index_id
 WHERE $2::int IS NULL OR x.database_id = $2
 ORDER BY CASE v.severity WHEN 'warning' THEN 0 ELSE 1 END, v.rule, x.size_kb DESC NULLS LAST, v.database_name, x.table_name, x.index_name`

const sqlMSSQLIxMissing = `
SELECT m.ord, m.database_id, coalesce(m.database_name, 'database ' || m.database_id) AS database, m.table_ref, m.equality_columns, m.inequality_columns,
       m.included_columns, m.user_seeks, m.user_scans, m.compiles, round(m.avg_cost::numeric, 2) AS avg_cost, round(m.avg_impact::numeric, 1) AS avg_impact,
       m.last_request, round(m.benefit::numeric) AS benefit,
       round((m.benefit / greatest(extract(epoch FROM m.snapshot_at - m.server_start) / 86400.0, 1))::numeric) AS benefit_per_day, m.snapshot_at
  FROM pgvigil.mssql_missing_index m
 WHERE m.instance_id = $1 AND ($2::int IS NULL OR m.database_id = $2)
 ORDER BY m.ord`

const sqlMSSQLIxStatsDBs = `
SELECT b.database_id, b.database_name AS database, b.read_at, b.note, b.statistics, b.statistics_with_props, b.never_updated, b.oldest_update,
       b.newest_update, round(b.avg_modified_pct::numeric, 1) AS avg_modified_pct, b.listed, b.capped
  FROM pgvigil.mssql_stats_db b
 WHERE b.instance_id = $1 AND ($2::int IS NULL OR b.database_id = $2)
 ORDER BY b.database_name`

const sqlMSSQLIxStats = `
SELECT t.database_id, t.database_name AS database, t.schema_name, t.table_name, t.stats_name, array_to_string(t.stat_columns, ', ') AS columns,
       t.severity, array_to_string(t.flags, ', ') AS flags, t.last_updated, t.row_count, t.rows_sampled, t.sampled_pct, t.modifications, t.modified_pct,
       t.persisted_sample_pct, t.no_recompute, t.has_filter, t.filter_definition, t.is_incremental, t.partitioned, t.props_read, t.auto_created
  FROM pgvigil.mssql_stat_status t
 WHERE t.instance_id = $1 AND ($2::int IS NULL OR t.database_id = $2) AND t.severity IS NOT NULL
 ORDER BY CASE t.severity WHEN 'warning' THEN 0 ELSE 1 END, t.modifications DESC NULLS LAST, t.database_name, t.table_name, t.stats_name
 LIMIT 5000`

const sqlMSSQLIxFindings = `
SELECT f.severity, f.check_name, f.object, f.at, f.detail, 'mssql_indexes' AS source FROM pgvigil.mssql_indexes_findings f WHERE f.instance_id = $1
UNION ALL
SELECT f.severity, f.check_name, f.object, f.at, f.detail, 'mssql_stats' FROM pgvigil.mssql_stats_findings f WHERE f.instance_id = $1
 ORDER BY 1 DESC, 2, 3`

// MSSQLIndexes is GET /api/mssql/indexes.
func (s *Server) MSSQLIndexes(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	database, err := dbFilter(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"state", sqlMssqlRunningState, []any{id, []string{"mssql_indexes", "mssql_stats"}}},
		{"databases", sqlMSSQLIxDatabases, []any{id}},
		{"indexes", sqlMSSQLIxIndexes, []any{id, database}},
		{"heaps", sqlMSSQLIxHeaps, []any{id, database}},
		{"verdicts", sqlMSSQLIxVerdicts, []any{id, database}},
		{"missing", sqlMSSQLIxMissing, []any{id, database}},
		{"statsdbs", sqlMSSQLIxStatsDBs, []any{id, database}},
		{"stats", sqlMSSQLIxStats, []any{id, database}},
		{"findings", sqlMSSQLIxFindings, []any{id}},
	})
}
