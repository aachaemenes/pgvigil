package web

// sqlInstances lists the active instances with their state and the latest session summary.
// $1 = the stale check's expectations: a collection disabled or gated off for an instance (0) is not
// counted as failing there, so an error row an earlier build left behind does not alarm for ever.
const sqlInstances = `
SELECT i.instance_id, i.name, i.platform, i.server_version, i.is_replica, i.tags, i.last_seen,
       st.postmaster_start, st.max_connections, st.data_checksums, st.has_pg_stat_statements,
       a.snapshot_at AS activity_at, a.total, a.active, a.idle_in_txn, a.waiting_lock,
       a.longest_active_secs, a.longest_idle_txn_secs, a.oldest_xmin_age, h.snapshot_at AS host_at,
       (SELECT count(*) FROM pgvigil.collection_dates c
         WHERE c.instance_id = i.instance_id AND c.status = 'error'
           AND coalesce(($1::jsonb -> 'instances' -> i.name ->> c.collection)::int,
                        ($1::jsonb -> 'defaults' ->> c.collection)::int, -1) <> 0) AS collections_failing
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.instance_state st ON st.instance_id = i.instance_id
  LEFT JOIN pgvigil.host_state h ON h.instance_id = i.instance_id
  LEFT JOIN LATERAL (SELECT * FROM pgvigil.activity_summary x
                      WHERE x.instance_id = i.instance_id
                      ORDER BY x.snapshot_at DESC LIMIT 1) a ON true
 WHERE i.is_active
 ORDER BY i.name`

// overviewChecks are the daily checks, each its own statement so a slow or failing check
// costs only its own rows. Every one returns instance_id, severity, check_name, object, at, detail.
// $1 (stale only) = {"defaults": {collection: secs}, "instances": {name: {collection: secs}}};
// an interval of 0 = disabled there. $2 = the age used when neither names the collection.
var overviewChecks = []struct{ name, sql string }{
	{"collection failing", `
SELECT c.instance_id, 'critical' AS severity, 'collection failing' AS check_name, c.collection AS object,
       c.snapshot_at AS at, c.note AS detail
  FROM pgvigil.collection_dates c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND c.status = 'error'
   AND coalesce(($1::jsonb -> 'instances' -> i.name ->> c.collection)::int,
                ($1::jsonb -> 'defaults' ->> c.collection)::int, -1) <> 0`},
	{"collection stale", `
SELECT instance_id, 'warning', 'collection stale', collection, snapshot_at,
       'last ' || to_char(now() - snapshot_at, 'DD"d" HH24"h" MI"m"') || ' ago'
  FROM (SELECT c.*, coalesce(($1::jsonb -> 'instances' -> i.name ->> c.collection)::int,
                             ($1::jsonb -> 'defaults' ->> c.collection)::int) AS iv
          FROM pgvigil.collection_dates c JOIN pgvigil.instances i USING (instance_id)
         WHERE i.is_active AND c.status <> 'error') x
 WHERE coalesce(iv, -1) <> 0
   AND now() - snapshot_at > make_interval(secs => CASE WHEN iv IS NULL THEN $2::int ELSE greatest(300, 3 * iv) END)`},
	{"replication", `
SELECT r.instance_id, CASE WHEN r.check_name LIKE 'slot WAL status%' THEN 'critical' ELSE 'warning' END,
       r.check_name, r.object, r.snapshot_at,
       r.value::text || ' ' || r.unit || coalesce(' (' || r.state || ')', '')
  FROM pgvigil.replication_checks r JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active`},
	{"jobs", `
SELECT f.instance_id, 'critical', 'job failed', f.scheduler || ' ' || coalesce(f.job_name, f.job_id::text), f.start_time,
       left(f.return_message, 300)
  FROM pgvigil.job_failures f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active`},
	{"dms", `
SELECT d.instance_id, d.severity, d.check_name, d.object, d.at, d.detail
  FROM pgvigil.dms_checks d JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active`},
	{"tables", `
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.table_checks c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active`},
	// the import starts a new epoch when stats_reset moves or a counter falls (a crash or a failover
	// restarts them under the same stats_reset), so within one epoch max minus min is the rise, as a hash
	// aggregate: an ordered array_agg or lag() sorts the whole day (21 s / 27 s at 5.76 M rows, 1 s this way)
	{"deadlocks and checksums", `
SELECT instance_id, CASE WHEN ck > 0 THEN 'critical' ELSE 'warning' END,
       CASE WHEN ck > 0 THEN 'checksum failures (24 h)' ELSE 'deadlocks (24 h)' END,
       datname, last_at,
       CASE WHEN ck > 0 THEN ck::text || ' checksum failure(s); ' ELSE '' END || dl::text || ' deadlock(s)'
  FROM (SELECT instance_id, datname, sum(dl) AS dl, sum(ck) AS ck, max(last_at) AS last_at
          FROM (SELECT d.instance_id, d.dbid, max(d.datname) AS datname, max(d.snapshot_at) AS last_at,
                       greatest(0, max(d.deadlocks) - min(d.deadlocks)) AS dl,
                       greatest(0, max(d.checksum_failures) - min(d.checksum_failures)) AS ck
                  FROM pgvigil.dbstats d JOIN pgvigil.instances i USING (instance_id)
                 WHERE i.is_active AND d.snapshot_at > now() - interval '1 day'
                 GROUP BY d.instance_id, d.dbid, d.stats_reset, d.epoch) e
         GROUP BY instance_id, datname) x
 WHERE dl > 0 OR ck > 0`},
}

// sqlSessions is one activity snapshot with statement text and ages at the snapshot.
const sqlSessions = `
SELECT s.pid, s.leader_pid, s.backend_type, s.datname, s.usename, s.application_name, s.client, s.state,
       s.wait_event_type, s.wait_event, s.blocking_pids, s.is_blocker,
       extract(epoch FROM s.snapshot_at - s.query_start)::int AS query_secs,
       extract(epoch FROM s.snapshot_at - s.xact_start)::int  AS xact_secs,
       extract(epoch FROM s.snapshot_at - s.state_change)::int AS state_secs,
       s.backend_xmin_age, s.xid_assigned, s.query_id, q.query
  FROM pgvigil.activity_sample s
  LEFT JOIN pgvigil.query_text q ON q.query_hash = s.query_hash
 WHERE s.instance_id = $1 AND s.snapshot_at = $2
 ORDER BY s.is_blocker DESC, cardinality(s.blocking_pids) > 0 DESC, s.query_start NULLS LAST`

// sqlCounters are per-second rates per snapshot, summed over databases (db) or IO rows (io).
var sqlCounters = map[string]string{
	"db": `
SELECT snapshot_at,
       round(sum(xact_commit)::numeric   / max(interval_secs), 2) AS commits_s,
       round(sum(xact_rollback)::numeric / max(interval_secs), 2) AS rollbacks_s,
       round(sum(blks_read)::numeric     / max(interval_secs), 2) AS blks_read_s,
       round(sum(blks_hit)::numeric      / max(interval_secs), 2) AS blks_hit_s,
       round(sum(tup_returned + tup_fetched)::numeric / max(interval_secs), 2) AS tup_read_s,
       round(sum(tup_inserted + tup_updated + tup_deleted)::numeric / max(interval_secs), 2) AS tup_written_s,
       round(sum(temp_bytes)::numeric    / max(interval_secs), 0) AS temp_bytes_s,
       sum(deadlocks) AS deadlocks, sum(numbackends) AS backends
  FROM pgvigil.dbstats_rate($1, $2, $3, make_interval(secs => $4))
 WHERE interval_secs > 0
 GROUP BY snapshot_at
HAVING NOT bool_or(reset)                -- a database reset in this interval: no point, not a dip
 ORDER BY snapshot_at`,
	"server": `
SELECT snapshot_at,
       checkpoints_timed + checkpoints_req AS checkpoints, checkpoints_req,
       round((coalesce(buffers_checkpoint, 0) + coalesce(buffers_clean, 0) + coalesce(buffers_backend, 0))::numeric / interval_secs, 2) AS buffers_written_s,
       round(buffers_alloc::numeric / interval_secs, 2) AS buffers_alloc_s,
       round(wal_bytes / interval_secs, 0) AS wal_bytes_s,
       round(wal_records::numeric / interval_secs, 2) AS wal_records_s,
       wal_buffers_full
  FROM pgvigil.serverstats_rate($1, $2, $3, make_interval(secs => $4))
 WHERE interval_secs > 0
 ORDER BY snapshot_at`,
	"io": `
SELECT snapshot_at,
       round(sum(read_bytes)   / max(interval_secs), 0) AS read_bytes_s,
       round(sum(write_bytes)  / max(interval_secs), 0) AS write_bytes_s,
       round(sum(extend_bytes) / max(interval_secs), 0) AS extend_bytes_s,
       round(sum(hits)::numeric / max(interval_secs), 2) AS hits_s,
       round(sum(fsyncs)::numeric / max(interval_secs), 2) AS fsyncs_s
  FROM pgvigil.iostats_rate($1, $2, $3, make_interval(secs => $4))
 WHERE interval_secs > 0
 GROUP BY snapshot_at
HAVING NOT bool_or(reset)                -- an IO row reset in this interval: no point, not a dip
 ORDER BY snapshot_at`,
	"sessions": `
SELECT snapshot_at, total, active, idle_in_txn, waiting_lock, active_client_wait,
       longest_active_secs, longest_idle_txn_secs, oldest_xmin_age
  FROM pgvigil.activity_summary
 WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3
 ORDER BY snapshot_at`,
}

// sqlDMSTasks lists the replication tasks of every instance ($1 NULL) or one, newest state first.
const sqlDMSTasks = `
SELECT t.instance_id, i.name AS instance, t.task_id, t.task_arn, t.migration_type, t.status, t.stop_reason,
       t.progress_pct, t.tables_loaded, t.tables_loading, t.tables_queued, t.tables_errored,
       t.latency_source_s, t.latency_target_s, t.incoming_changes, t.latency_at, t.latency_warn_secs,
       round(t.elapsed_ms / 1000.0) AS elapsed_secs, t.start_date, t.stop_date, t.full_load_start, t.full_load_finish,
       t.cdc_start_position, t.recovery_checkpoint, ri.ri_id, t.ri_arn, left(t.last_failure, 1000) AS last_failure,
       t.snapshot_at, t.is_present, t.tables_partial,
       (SELECT count(*) FROM pgvigil.dms_table_stats s
         WHERE s.instance_id = t.instance_id AND s.task_arn = t.task_arn AND s.is_present) AS tables
  FROM pgvigil.dms_tasks t
  JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN pgvigil.dms_instances ri ON ri.instance_id = t.instance_id AND ri.ri_arn = t.ri_arn
 WHERE i.is_active AND ($1::int IS NULL OR t.instance_id = $1)
 ORDER BY t.is_present DESC, i.name, t.task_id`

// sqlDMSInstances lists the replication instances the tasks run on with their host metrics.
const sqlDMSInstances = `
SELECT r.instance_id, i.name AS instance, r.ri_id, r.ri_arn, r.status, r.class, r.engine_version, r.allocated_gb,
       r.multi_az, r.public, r.az, r.created, r.pending, r.cpu_pct, r.freeable_bytes, r.free_storage_bytes, r.swap_bytes,
       r.snapshot_at, r.is_present,
       (SELECT count(*) FROM pgvigil.dms_tasks t WHERE t.instance_id = r.instance_id AND t.ri_arn = r.ri_arn AND t.is_present) AS tasks
  FROM pgvigil.dms_instances r
  JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND ($1::int IS NULL OR r.instance_id = $1)
 ORDER BY r.is_present DESC, i.name, r.ri_id`

// sqlDMSTables is one task's table statistics ($2 = the task ARN), errors and validation failures first.
const sqlDMSTables = `
SELECT s.schema_name, s.table_name, s.table_state, s.full_load_rows, s.full_load_error_rows, s.full_load_cond_failed_rows,
       s.inserts, s.updates, s.deletes, s.ddls, s.applied_inserts, s.applied_updates, s.applied_deletes, s.applied_ddls,
       s.full_load_start, s.full_load_end, s.last_update, s.validation_state, s.validation_pending, s.validation_failed,
       s.validation_suspended, left(s.validation_detail, 500) AS validation_detail, s.full_load_reloaded, s.is_present
  FROM pgvigil.dms_table_stats s
  JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND ($1::int IS NULL OR s.instance_id = $1) AND s.task_arn = $2
 ORDER BY s.is_present DESC, (s.table_state ILIKE '%error%') DESC, s.validation_failed DESC NULLS LAST, s.schema_name, s.table_name`

// sqlReplLatest is the newest replication snapshot of one instance (replication_latest: the last day).
const sqlReplLatest = `
SELECT kind, key, state, lag_bytes, lag_secs, active, snapshot_at, detail
  FROM pgvigil.replication_latest
 WHERE instance_id = $1
 ORDER BY CASE kind WHEN 'sender' THEN 1 WHEN 'receiver' THEN 2 WHEN 'aurora_replica' THEN 3 WHEN 'slot' THEN 4
                    WHEN 'subscription' THEN 5 WHEN 'publication' THEN 6 ELSE 7 END, key`

// sqlReplChecks are the replication daily checks of one instance.
const sqlReplChecks = `
SELECT check_name, object, value, unit, state, snapshot_at
  FROM pgvigil.replication_checks
 WHERE instance_id = $1
 ORDER BY check_name, object`

// sqlReplSeries is the lag of every lag-bearing object over the window, the max per $4-second bucket
// (the handler picks about 600 buckets per window), and when even that passes the cap the NEWEST rows
// are kept: a lag chart that loses its end loses the point the page is opened for.
const sqlReplSeries = `
SELECT * FROM (
  SELECT to_timestamp(floor(extract(epoch FROM snapshot_at) / $4) * $4) AS snapshot_at, kind, key,
         max(lag_bytes) AS lag_bytes, max(lag_secs) AS lag_secs
    FROM pgvigil.replication_sample
   WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3
     AND kind IN ('sender', 'receiver', 'slot', 'aurora_replica')
   GROUP BY 1, 2, 3
   ORDER BY 1 DESC
   LIMIT 20000) x
 ORDER BY snapshot_at, kind, key`

// replSeriesCap is sqlReplSeries's LIMIT: the page says so when a reply holds this many rows.
const replSeriesCap = 20000

// sqlJobs is the job list of one instance with its newest run's status.
const sqlJobs = `
SELECT j.scheduler, j.job_id, j.job_name, j.schedule, j.datname, j.run_as, j.active, j.next_run, j.last_run,
       lr.status AS last_status, lr.start_time AS last_start, lr.duration_secs AS last_duration_secs,
       j.command, j.is_present, j.snapshot_at
  FROM pgvigil.jobs j
  LEFT JOIN LATERAL (SELECT r.status, r.start_time, r.duration_secs FROM pgvigil.job_runs r
                      WHERE r.instance_id = j.instance_id AND r.scheduler = j.scheduler AND r.job_id = j.job_id
                      ORDER BY r.start_time DESC NULLS LAST LIMIT 1) lr ON true
 WHERE j.instance_id = $1
 ORDER BY j.is_present DESC, j.scheduler, j.job_name NULLS LAST, j.job_id`

// sqlJobRuns are the runs that started in the window, newest first.
const sqlJobRuns = `
SELECT r.start_time, r.end_time, r.duration_secs, r.scheduler, r.job_id, j.job_name, r.run_id, r.status,
       r.datname, r.run_as, left(r.return_message, 1000) AS return_message, left(r.command, 1000) AS command
  FROM pgvigil.job_runs r
  LEFT JOIN pgvigil.jobs j ON j.instance_id = r.instance_id AND j.scheduler = r.scheduler AND j.job_id = r.job_id
 WHERE r.instance_id = $1 AND r.start_time > $2 AND r.start_time <= $3
 ORDER BY r.start_time DESC
 LIMIT 1000`

// sqlLogCounts is the number of log events per kind in the window.
const sqlLogCounts = `
SELECT kind, count(*) AS events, max(snapshot_at) AS last_at
  FROM pgvigil.log_events
 WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3
 GROUP BY kind
 ORDER BY kind`

// sqlLogEvents are the window's log events ($4 = one kind or NULL), newest first.
const sqlLogEvents = `
SELECT snapshot_at AS at, kind, pid, datname, usename, client, duration_ms,
       left(statement, 2000) AS statement, left(detail, 1000) AS detail, source
  FROM pgvigil.log_events
 WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3 AND ($4::text IS NULL OR kind = $4)
 ORDER BY snapshot_at DESC
 LIMIT 1000`

// sqlConfigState is the instance_state row without its two JSON lists.
const sqlConfigState = `
SELECT snapshot_at, platform, server_version, server_version_num, is_replica, postmaster_start, server_now,
       time_zone, connected_database, connected_user, server_addr, server_port, data_checksums, shared_buffers,
       max_connections, work_mem, wal_level, track_io_timing, log_min_duration_statement, database_count,
       has_pg_stat_statements, has_pg_cron, has_pgagent, has_wait_sampling, has_log_fdw
  FROM pgvigil.instance_state
 WHERE instance_id = $1`

// sqlConfigSettings unpacks the non-default settings (a JSON array of {name, value}).
const sqlConfigSettings = `
SELECT x ->> 'name' AS name, x ->> 'value' AS value
  FROM pgvigil.instance_state st,
       jsonb_array_elements(CASE WHEN jsonb_typeof(st.non_default_settings) = 'array' THEN st.non_default_settings ELSE '[]' END) x
 WHERE st.instance_id = $1
 ORDER BY lower(x ->> 'name')`

// sqlConfigExtensions unpacks the installed extensions (a JSON array of {name, version}).
const sqlConfigExtensions = `
SELECT x ->> 'name' AS name, x ->> 'version' AS version
  FROM pgvigil.instance_state st,
       jsonb_array_elements(CASE WHEN jsonb_typeof(st.extensions) = 'array' THEN st.extensions ELSE '[]' END) x
 WHERE st.instance_id = $1
 ORDER BY x ->> 'name'`

// sqlConfigHistory is the setting changes of the window, newest first.
const sqlConfigHistory = `
SELECT h.changed_at, h.name, h.old_value, h.new_value
  FROM pgvigil.instance_setting_history h
 WHERE h.instance_id = $1 AND h.changed_at > $2 AND h.changed_at <= $3
 ORDER BY h.changed_at DESC, h.name
 LIMIT 1000`

// sqlConfigHistoryTotal is the change count over all time and the newest change.
const sqlConfigHistoryTotal = `
SELECT count(*) AS changes, max(changed_at) AS last_change
  FROM pgvigil.instance_setting_history
 WHERE instance_id = $1`

// sqlDatabases is one instance's database inventory, present and largest first.
const sqlDatabases = `
SELECT datname, owner, encoding, size_bytes, xid_age, mxid_age, can_connect, allow_conn, conn_limit,
       is_template, tablespace, first_seen, snapshot_at, is_present
  FROM pgvigil.databases
 WHERE instance_id = $1
 ORDER BY is_present DESC, size_bytes DESC NULLS LAST, datname`

// sqlTables is one instance's tables in the latest top N per database, the ones with a check first. The
// checks view (a fleet-wide CTE) is read once per request through the aggregated join, never per table row.
const sqlTables = `
SELECT t.datname, t.schema_name, t.table_name, t.total_bytes, t.heap_bytes, t.toast_bytes, t.index_bytes,
       t.n_live_tup, t.n_dead_tup,
       round(100.0 * t.n_dead_tup / nullif(t.n_live_tup + t.n_dead_tup, 0), 1) AS dead_pct,
       round(100.0 * t.relallvisible / nullif(t.relpages, 0), 1) AS all_visible_pct,
       t.bloat_pct, t.bloat_bytes, t.last_vacuum, t.last_analyze, t.n_mod_since_analyze, t.n_ins_since_vacuum,
       t.vacuums, t.analyzes, t.seq_scan, t.idx_scan, t.xid_age, t.mxid_age, t.autovacuum_off, t.stats_readable,
       t.snapshot_at, c.checks
  FROM pgvigil.tables t
  LEFT JOIN (SELECT object, count(*) AS n, string_agg(check_name, ', ' ORDER BY check_name) AS checks
               FROM pgvigil.table_checks WHERE instance_id = $1 GROUP BY object) c
    ON c.object = t.datname || '.' || t.schema_name || '.' || t.table_name
 WHERE t.instance_id = $1 AND t.is_present
 ORDER BY coalesce(c.n, 0) DESC, t.total_bytes DESC NULLS LAST`

// sqlTableDatabases is the per-database summary of one instance's table read.
const sqlTableDatabases = `
SELECT d.datname, d.user_tables, d.never_vacuumed, d.never_analyzed, d.big_tables, d.big_never_vacuumed,
       d.big_under_half_visible, round(100.0 * d.big_visible_pages / nullif(d.big_pages, 0), 1) AS big_visible_pct,
       d.stats_reset, d.snapshot_at
  FROM pgvigil.table_databases d
 WHERE d.instance_id = $1 AND d.is_present
 ORDER BY d.datname`

// sqlFindings lists the findings of every instance ($1 NULL) or one, the most severe first.
const sqlFindings = `
SELECT f.instance_id, i.name AS instance, i.platform, f.severity, f.setting, f.value, f.is_set, f.suggested, f.platforms,
       f.detail, f.source, f.at
  FROM pgvigil.findings f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND ($1::int IS NULL OR f.instance_id = $1)
 ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, i.name, f.setting`

// sqlDMSDrain is the drain readout of every task ($1 NULL) or one instance's.
const sqlDMSDrain = `
SELECT d.instance_id, i.name AS instance, d.task_id, d.task_arn, d.status, d.latency_target_s, d.reader_at, d.speed_x,
       d.eta_secs, d.rows_behind, d.rows_in_s, d.rows_out_s, d.eta_rows_secs, d.disk_source, d.disk_target, d.spilling,
       d.tables, d.validated, d.pending, d.never_validated, d.failed, d.suspended, d.pending_records, d.failed_records
  FROM pgvigil.dms_drain d JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND ($1::int IS NULL OR d.instance_id = $1)
 ORDER BY i.name, d.task_id`
