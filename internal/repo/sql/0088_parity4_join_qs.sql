-- 0088: the join of parity4, second part (task 129, Query Store on SQL Server: 0083), built from 0087's purge() and
-- 0077's pgvigil.findings (never edited by hand).
-- pgvigil.findings re-created with one more arm, mssql_querystore_findings (a store in ERROR, read-only, off though
-- asked for or near its size limit; a forced plan SQL Server fails to use), mapped as the other SQL Server arms are:
-- check_name and object to setting and value, no suggested value and no platform list.
-- purge() re-created with 0083's two monthly partition parents (mssql_qs_interval, mssql_qs_runtime) and three
-- retention steps: mssql_qs_plan and mssql_qs_query rows no read has listed within the window, once no kept runtime
-- row (and, for a query, no kept plan) names them; mssql_qs_tuning rows not listed within the window.
-- apply_roles() is unchanged: 0083 adds two collector doors (import_mssql_querystore by its prefix, mssql_hadr_cursor
-- already on the list) and one function a reader may call (mssql_qs_readonly_reasons).

CREATE OR REPLACE VIEW pgvigil.findings AS
WITH v AS (
  SELECT instance_id, snapshot_at, platform, server_version_num, is_replica, name, value, is_set,
         CASE WHEN value ~ '^-?[0-9]+(\.[0-9]+)?$' THEN value::numeric END AS num
    FROM pgvigil.instance_settings
), r(instance_id, name, severity, suggested, platforms, detail, hit) AS (
  SELECT instance_id, name, 'critical', 'on', 'all', 'autovacuum is off: no dead-row cleanup and no anti-wraparound vacuum beyond the forced one',
         value <> 'on' FROM v WHERE name = 'autovacuum'
  UNION ALL SELECT instance_id, name, 'warning', '2', 'all', 'autovacuum_vacuum_cost_delay outside 2-20 ms: 0 (or -1, which takes vacuum_cost_delay, 0 by default) lets autovacuum saturate I/O, above 20 it crawls',
         num > 20 OR num = 0 OR num = -1 FROM v WHERE name = 'autovacuum_vacuum_cost_delay'
  UNION ALL SELECT instance_id, name, 'info', '3', 'self-managed', 'more autovacuum workers share one cost limit, so each runs slower',
         num > 3 AND platform = 'onprem' FROM v WHERE name = 'autovacuum_max_workers'
  UNION ALL SELECT instance_id, name, 'warning', '200000000', 'all', 'autovacuum_freeze_max_age above 800 million leaves little room before wraparound',
         num > 800000000 FROM v WHERE name = 'autovacuum_freeze_max_age'
  UNION ALL SELECT instance_id, name, 'warning', '0.9', 'not aurora', 'a low checkpoint_completion_target writes each checkpoint in a burst (I/O spikes)',
         num < 0.7 AND platform <> 'aurora' FROM v WHERE name = 'checkpoint_completion_target'
  UNION ALL SELECT instance_id, name, 'info', '1800', 'not aurora', 'checkpoints closer than 20 minutes apart: more full-page writes and WAL',
         num < 1200 AND platform <> 'aurora' FROM v WHERE name = 'checkpoint_timeout'
  UNION ALL SELECT instance_id, name, 'info', 'lz4', 'all', 'lz4 compresses TOAST faster than pglz',
         value <> 'lz4' AND server_version_num >= 140000 FROM v WHERE name = 'default_toast_compression'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'self-managed', 'huge pages are not required: a large shared_buffers pays for its page tables in memory and TLB misses',
         value <> 'on' AND platform = 'onprem' FROM v WHERE name = 'huge_pages'
  UNION ALL SELECT instance_id, name, 'warning', '0', 'all', 'idle_session_timeout ends idle pooled connections the application still holds',
         num > 0 FROM v WHERE name = 'idle_session_timeout'
  UNION ALL SELECT instance_id, name, 'info', '5min', 'all', 'no limit on idle-in-transaction sessions: one forgotten transaction holds its locks and pins vacuum',
         num = 0 FROM v WHERE name = 'idle_in_transaction_session_timeout'
  UNION ALL SELECT instance_id, name, 'info', 'off', 'all', 'JIT on globally: short OLTP statements pay compile time; enable it per session for analytics',
         value = 'on' FROM v WHERE name = 'jit'
  UNION ALL SELECT instance_id, name, 'info', 'off', 'all', 'log_hostname makes a DNS lookup per connection',
         value = 'on' FROM v WHERE name = 'log_hostname'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'all', 'lock waits past deadlock_timeout are not logged: blocking leaves no trace in the log',
         value = 'off' FROM v WHERE name = 'log_lock_waits'
  UNION ALL SELECT instance_id, name, 'info', '500', 'self-managed', 'more than 500 connections: use a pooler; every backend costs memory and snapshot work',
         num > 500 AND platform = 'onprem' FROM v WHERE name = 'max_connections'
  UNION ALL SELECT instance_id, name, 'warning', '30000', 'replica', 'under 30 s: queries on the standby are cancelled by replay conflicts',
         num >= 0 AND num < 30000 AND is_replica FROM v WHERE name IN ('max_standby_streaming_delay', 'max_standby_archive_delay')
  UNION ALL SELECT instance_id, name, 'info', '30000', 'replica', 'over 5 min (or -1, unlimited): a long standby query holds replay back and the standby lags',
         (num > 300000 OR num = -1) AND is_replica FROM v WHERE name IN ('max_standby_streaming_delay', 'max_standby_archive_delay')
  UNION ALL SELECT instance_id, name, 'info', '8192', 'not aurora', 'max_wal_size under 8 GB: checkpoints forced by WAL volume under load',
         num < 8192 AND platform <> 'aurora' FROM v WHERE name = 'max_wal_size'
  UNION ALL SELECT instance_id, name, 'info', '2048', 'not aurora', 'min_wal_size under 2 GB: WAL segments removed and re-created between bursts',
         num < 2048 AND platform <> 'aurora' FROM v WHERE name = 'min_wal_size'
  UNION ALL SELECT instance_id, name, 'info', '1.1', 'managed', 'managed storage is SSD-backed: random reads cost about what sequential ones do',
         num > 1.2 AND platform <> 'onprem' FROM v WHERE name = 'random_page_cost'
  UNION ALL SELECT instance_id, name, 'warning', '1', 'all', 'seq_page_cost is the unit every other cost is relative to; change random_page_cost instead',
         num <> 1 FROM v WHERE name = 'seq_page_cost'
  UNION ALL SELECT v.instance_id, v.name, 'warning', 'local', 'all', 'synchronous_standby_names is set with synchronous_commit on / remote_write / remote_apply: every commit waits for a standby (hangs when it is gone)',
         v.value <> '' AND c.value IN ('on', 'remote_write', 'remote_apply') FROM v JOIN v c ON c.instance_id = v.instance_id AND c.name = 'synchronous_commit'
   WHERE v.name = 'synchronous_standby_names'
  UNION ALL SELECT instance_id, name, 'info', 'on', 'all', 'without I/O timing, statement and database read times are not measured',
         value = 'off' FROM v WHERE name = 'track_io_timing'
  UNION ALL SELECT instance_id, name, 'info', CASE WHEN server_version_num >= 150000 THEN 'lz4' ELSE 'on' END, 'not aurora',
         'full-page images go to WAL uncompressed', value = 'off' AND platform <> 'aurora' FROM v WHERE name = 'wal_compression'
  UNION ALL SELECT instance_id, name, 'info', 'fdatasync', 'self-managed', 'fdatasync or open_datasync is the safe and fast choice on Linux',
         value NOT IN ('fdatasync', 'open_datasync') AND platform = 'onprem' FROM v WHERE name = 'wal_sync_method'
  UNION ALL SELECT instance_id, name, 'warning', '60000', 'all', 'wal_sender_timeout 0: a dead standby connection is never noticed',
         num = 0 FROM v WHERE name = 'wal_sender_timeout'
  UNION ALL SELECT instance_id, name, 'warning', '65536', 'all', 'a global work_mem above 96 MB is multiplied by every sort and hash of every session',
         num > 98304 FROM v WHERE name = 'work_mem'
  UNION ALL SELECT instance_id, name, 'critical', 'off', 'all', 'zero_damaged_pages hides corruption by zeroing the damaged page (silent data loss)',
         value = 'on' FROM v WHERE name = 'zero_damaged_pages'
), c(instance_id, name, severity, suggested, platforms, detail, hit) AS (
  -- pg-collector's observations on settings (its autovacuum-off one is pg_gather's above)
  SELECT instance_id, name, 'critical', 'on', 'all', 'track_counts is off: autovacuum cannot see which tables need it and pg_stat_* stay empty',
         value <> 'on' FROM v WHERE name = 'track_counts'
  UNION ALL SELECT instance_id, name, 'warning', 'on', 'all', 'a planner method is switched off for every session: plans that need it degrade',
         value <> 'on' FROM v WHERE name IN ('enable_indexscan', 'enable_indexonlyscan')
  UNION ALL SELECT instance_id, name, 'warning', 'on', 'all', 'synchronous_commit off: the last commits are lost on a crash',
         value = 'off' FROM v WHERE name = 'synchronous_commit'
  UNION ALL SELECT instance_id, name, 'warning', 'none', 'all', 'log_statement all / mod logs every statement or every write: log volume and I/O',
         value IN ('all', 'mod') FROM v WHERE name = 'log_statement'
  UNION ALL SELECT instance_id, name, 'warning', '-1', 'all', 'log_min_duration_statement 0 logs every statement with its duration',
         num = 0 FROM v WHERE name = 'log_min_duration_statement'
  UNION ALL SELECT instance_id, name, 'warning', 'warning', 'all', 'a debug log level writes internal detail for every operation',
         value LIKE 'debug%' FROM v WHERE name = 'log_min_messages'
  UNION ALL SELECT instance_id, name, 'warning', 'off', 'all', 'per-statement parser / planner / executor statistics or parse-tree dumps go to the log',
         value = 'on' FROM v WHERE name IN ('log_parser_stats', 'log_planner_stats', 'log_executor_stats', 'log_statement_stats',
                                            'debug_print_parse', 'debug_print_rewritten', 'debug_print_plan')
  UNION ALL SELECT instance_id, name, 'info', '200000000', 'all', 'autovacuum_freeze_max_age above the 200 million default: anti-wraparound vacuums start later and do more at once',
         num > 200000000 AND num <= 800000000 FROM v WHERE name = 'autovacuum_freeze_max_age'
)
SELECT DISTINCT ON (x.instance_id, x.setting, x.value, x.detail) x.*
  FROM (
    SELECT v.instance_id, r.severity, r.name AS setting, v.value, v.is_set, r.suggested, r.platforms, r.detail,
           'pg_gather' AS source, v.snapshot_at AS at
      FROM r JOIN v ON v.instance_id = r.instance_id AND v.name = r.name AND r.hit
    UNION ALL
    SELECT v.instance_id, c.severity, c.name, v.value, v.is_set, c.suggested, c.platforms, c.detail, 'pg-collector', v.snapshot_at
      FROM c JOIN v ON v.instance_id = c.instance_id AND v.name = c.name AND c.hit
    UNION ALL
    -- pg-collector: a database's frozen-xid age past 300 million (the databases collection's xid_age)
    SELECT d.instance_id, CASE WHEN d.xid_age >= 1000000000 THEN 'critical' ELSE 'warning' END, 'database xid age',
           d.datname || ': ' || d.xid_age::text, true, 'under 300000000', 'all',
           'the oldest unfrozen transaction in the database is over 300 million old: find what holds vacuum back (a long transaction, a slot, a prepared transaction)',
           'pg-collector', d.snapshot_at
      FROM pgvigil.databases d
     WHERE d.is_present AND NOT coalesce(d.is_template, false) AND d.xid_age >= 300000000
    UNION ALL
    -- pg-collector: an inactive replication slot (the replication collection's latest read)
    SELECT s.instance_id, 'warning', 'inactive replication slot', s.key, true, 'drop it or reconnect its consumer', 'all',
           'an inactive slot keeps WAL and, for a logical slot, the catalog xmin: disk fills and vacuum is held back',
           'pg-collector', s.snapshot_at
      FROM pgvigil.replication_latest s
     WHERE s.kind = 'slot' AND NOT coalesce(s.active, false) AND NOT coalesce((s.detail->>'synced')::boolean, false)
    UNION ALL
    -- the host collection (0021): CPU over 90 % for 10 minutes, swap used, a disk under 10 % free
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.host_findings
    UNION ALL
    -- the storage forecast (0033): a volume full within 30 days (the free-% rule is host_findings', above)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.storage_findings
    UNION ALL
    -- the vacuum collections (0024): over the threshold for hours, wraparound, a long or lock-waiting vacuum
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.vacuum_findings
     WHERE setting <> 'autovacuum off'
    UNION ALL
    -- the extensions collection (0019): outdated, preload and setting rules per extension
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.extension_findings
    UNION ALL
    -- the versions collection (0035): a deprecated engine version, pending maintenance, a changed collation version
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.version_findings
    UNION ALL
    -- the IO collection (0031): burst balance, queue depth, latency, the DMS instance's IO
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.io_findings
    UNION ALL
    -- the job report (0027): failing repeatedly, a run over twice its average, a missed schedule
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.job_report_findings
    UNION ALL
    -- the roles collection (0020): a superuser beyond the platform's own, CREATEROLE / BYPASSRLS on an application role, the monitoring login without pg_monitor, a role granted on every database, a login without a way in
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.role_findings
    UNION ALL
    -- the backups collection (0022): the archiver failing, the last archive older than the threshold while WAL waits, retention under 7 days, no snapshot in 24 h
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.backup_findings
    UNION ALL
    -- the corruption column (0023): checksums off, ignore_checksum_failure on, a corruption event in 24 h, amcheck damage
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.corruption_findings WHERE setting <> 'zero_damaged_pages'
    UNION ALL
    -- the plans slice (0029): estimates off by 10x, spills, a nested loop over a large outer, a filter removing most rows, a lossy bitmap scan, index-only heap fetches, JIT, trigger time, workers not launched, a CTE scanned twice
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.plan_findings
    UNION ALL
    -- the indexes collection (0030): invalid and duplicate indexes (warning), redundant and unused ones (info)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.index_findings
    UNION ALL
    -- Performance Insights and the Serverless cache rule (0053): cache starved by the ACU floor
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pi_findings
    UNION ALL
    -- baseline compare (0054): a tenfold rise against the same window one or seven days earlier, from the hourly cache
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.compare_findings
    UNION ALL
    -- session SETs (0055): a planner setting changed by the application's sessions
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.sessionsets_findings
    UNION ALL
    -- memory and poolers (0061): the pooler's waiting clients and full pools, temp-file spills, one relation over half of shared_buffers
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.memory_findings
    UNION ALL
    -- custom checks (0060): a threshold crossed, a failed run, not run in two cadences while the collection visits
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.custom_findings
    UNION ALL
    -- schema snapshots (0058): an object dropped in the last 24 hours, a definition changed
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.schema_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_running', at FROM pgvigil.mssql_running_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_xe', at FROM pgvigil.mssql_xe_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_hadr', at FROM pgvigil.mssql_hadr_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_jobs', at FROM pgvigil.mssql_jobs_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_storage', at FROM pgvigil.mssql_storage_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_perf', at FROM pgvigil.mssql_perf_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_querystore', at FROM pgvigil.mssql_querystore_findings
  ) x
 ORDER BY x.instance_id, x.setting, x.value, x.detail;

CREATE OR REPLACE FUNCTION pgvigil.purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n       bigint := 0;
  v_rows  bigint;
  v_part  record;
BEGIN
  FOR v_part IN
    SELECT c.relname
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class p ON p.oid = i.inhparent
      JOIN pg_namespace ns ON ns.oid = p.relnamespace
     WHERE ns.nspname = 'pgvigil'
       AND p.relname IN ('activity_sample', 'statements_delta', 'dbstats', 'serverstats', 'iostats', 'replication_sample', 'database_sizes',
                         'log_events', 'dms_task_sample', 'table_sizes',
                         'host_sample', 'host_disk_history', 'host_io', 'storage_sample',
                         'vacuum_sample', 'cloud_io_sample', 'dms_ri_sample', 'backup_sample', 'amcheck_runs', 'wait_sample', 'index_usage_daily', 'pi_load', 'serverless_sample', 'buffercache_sample', 'temp_sample', 'pooler_sample', 'custom_results', 'schema_changes', 'schema_ddl_log', 'alert_log', 'mssql_blocking', 'mssql_wait_sample', 'mssql_deadlocks', 'mssql_blocked_reports', 'mssql_slow_events', 'mssql_attentions', 'mssql_ag_events', 'mssql_ag_sample', 'mssql_job_runs', 'mssql_volume_sample', 'mssql_database_size', 'mssql_versionstore_sample',
                         'mssql_cpu_sample', 'mssql_sched_sample', 'mssql_memory_sample', 'mssql_memory_clerk', 'mssql_fileio_read', 'mssql_fileio_sample',
                         'table_activity', 'conn_sources', 'pooler_conn_sample',
                         'mssql_indexlock_read', 'mssql_indexlock_sample', 'mssql_proc_read', 'mssql_proc_sample',
                         'mssql_qs_interval', 'mssql_qs_runtime')
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)
     -- by parent, then partition: the order the imports take their parents in (a DROP takes the partition, then
     -- ACCESS EXCLUSIVE on its parent)
     ORDER BY p.relname, c.relname
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    n := n + 1;
  END LOOP;
  DELETE FROM pgvigil.job_runs WHERE start_time < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.activity_summary WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statements_info WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statements_current WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.query_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.activity_sample s WHERE s.query_hash = t.query_hash);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.statement_text t
   WHERE t.last_seen < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.statements_delta d WHERE d.instance_id = t.instance_id AND d.queryid = t.queryid);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.collection_log WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_table_stats WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_tasks WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dms_instances WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- tables out of the top N (or dropped) and databases gone, for longer than the retention
  DELETE FROM pgvigil.tables WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.table_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- volumes and storage objects no longer present, for longer than the retention (0021, 0033)
  DELETE FROM pgvigil.host_disks WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.storage_state WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- vacuum runs last seen before the retention, and the tables and databases no longer present (0024)
  DELETE FROM pgvigil.vacuum_runs WHERE last_seen < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.vacuum_tables WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.vacuum_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- extensions, their settings and per-database rows no longer present (0019; extension_history stays whole)
  DELETE FROM pgvigil.instance_extensions WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.instance_extension_settings WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.database_extensions WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- pending maintenance actions and database collations no longer present (0035)
  DELETE FROM pgvigil.version_pending WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.database_collations WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- the roles collection (0020): the current tables lose their absent rows after the retention; role_history,
  -- role_state and role_member_closure stay whole
  DELETE FROM pgvigil.role_attributes WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.role_members WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.role_databases WHERE NOT is_present AND read_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.acl_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.acl_schemas WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.acl_default_privileges WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.hba_rules WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- backup rows no longer present (0022: a snapshot AWS aged out, an archiver or cloud row of a resource the config no longer names; backup_sample is a partition parent above)
  DELETE FROM pgvigil.backup_state WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- plans older than the window (0029: a current table, one row per plan_key updated in place)
  DELETE FROM pgvigil.plans WHERE captured_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- indexes and their databases no longer present (0030; wait_profile_current, statements_monitor_total and statements_monitor_seen stay whole)
  DELETE FROM pgvigil.index_state WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.index_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- pg_stat_monitor totals whose statements_current row is gone (0030: one row per key, as statements_current)
  DELETE FROM pgvigil.statements_monitor_total t WHERE NOT EXISTS (SELECT 1 FROM pgvigil.statements_current c WHERE c.instance_id = t.instance_id AND c.dbid = t.dbid AND c.userid = t.userid AND c.queryid = t.queryid AND c.toplevel = t.toplevel);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- databases gone longer than the retention (0046: a dropped database goes absent at the next hourly read)
  DELETE FROM pgvigil.databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- the index inventory's rows gone longer than the retention (0056; its day rows go with their partitions)
  DELETE FROM pgvigil.index_inventory WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- wave E (0057): the PI top SQL texts, the DBADash history (each instance's newest row kept: the current status reads from it),
  -- the DBADash instances gone from their repository, the session SETs' samples and rows, the compare cache
  DELETE FROM pgvigil.pi_sql WHERE last_seen < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dbadash_summary_history h
   WHERE h.snapshot_at < now() - make_interval(days => p_days)
     AND h.snapshot_at < (SELECT max(h2.snapshot_at) FROM pgvigil.dbadash_summary_history h2
                           WHERE h2.repository = h.repository AND h2.instance_id = h.instance_id);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.dbadash_instances WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.session_sets_sample WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.session_sets WHERE last_seen < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.compare_findings_cache WHERE computed_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- wave F (0062): the pooler's state rows; every custom check not listed within the window, present or not (a collection
  -- switched off lists nothing, so its rows would otherwise stay present for ever); the schema objects and databases absent
  -- past the window and the event-trigger log cursors of databases no longer present; the alerts' state rows cleared past
  -- the window or open for a channel no longer configured, and the channels no longer configured
  DELETE FROM pgvigil.pooler_state WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.custom_checks WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.schema_objects WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.schema_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.log_cursor c
   WHERE c.source LIKE 'schema_ddl:%'
     AND NOT EXISTS (SELECT 1 FROM pgvigil.schema_databases d
                      WHERE d.instance_id = c.instance_id AND 'schema_ddl:' || d.datname = c.source);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.alert_state WHERE cleared_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.alert_state s
   WHERE s.cleared_at IS NULL AND s.last_sent_at < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_channels c WHERE c.name = s.channel AND c.is_configured);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.alert_channels WHERE NOT is_configured AND updated_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  n := n + pgvigil.mssql_running_purge(p_days);
  n := n + pgvigil.mssql_reads_purge(p_days);
  DELETE FROM pgvigil.mssql_xe_state WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- a cursor goes only with an instance no collection has reached for the whole window: a quiet source (no deadlock
  -- in a month) of a server still read keeps its place, or its file would be read again from the start
  DELETE FROM pgvigil.mssql_cursor c WHERE c.updated_at < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.collection_log l WHERE l.instance_id = c.instance_id AND l.snapshot_at >= now() - make_interval(days => p_days));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_ag_failovers WHERE at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- Query Store (0083): a query or a plan no read has listed within the window goes once no kept runtime row names it
  -- (the runtime partitions go by whole months, so a query's text stays as long as a runtime row of it does); a
  -- tuning recommendation no read has listed within the window goes; mssql_qs_store (each database's read cursor)
  -- and mssql_qs_tuning_option (current state) go with their instance only
  DELETE FROM pgvigil.mssql_qs_plan p
   WHERE p.snapshot_at < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_qs_runtime r
                      WHERE r.instance_id = p.instance_id AND r.database_name = p.database_name AND r.query_id = p.query_id AND r.plan_id = p.plan_id);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_qs_query q
   WHERE q.snapshot_at < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_qs_runtime r
                      WHERE r.instance_id = q.instance_id AND r.database_name = q.database_name AND r.query_id = q.query_id)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_qs_plan p
                      WHERE p.instance_id = q.instance_id AND p.database_name = q.database_name AND p.query_id = q.query_id);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_qs_tuning WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
