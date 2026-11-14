-- 0190 the second join file of the release (v0.4.0): what the slices numbered after 0110 leave to the lead's join. It
-- sorts after every slice migration of the release (they take 0111-0189) and each later join of the release extends it
-- in place, as 0110 was (nothing of either has been released yet).
--   task 177 D02 (0114): pgvigil.findings gains the mssql_blocking_findings arm; nothing for purge() (no table added).
--   task 177 D03 (0115): the mssql_waits_findings arm; mssql_memory_pool among purge()'s monthly partition parents.
--   task 177 D04 (0116): nothing here (its findings are the Blocked reports tab's own; mssql_blocked_reports is purged).
--   task 177 D13 (0119): the mssql_memory_findings arm; mssql_memory_rmon, mssql_memory_cache, mssql_plancache_type and
--     mssql_memory_grant_query among purge()'s monthly partition parents.
--   task 177 D30 (0118): the darling_alert_findings arm; nothing for purge().
--   task 177 D15 (0120): the mssql_sysevents_findings arm; nothing for purge() (the events live in mssql_health_components, already a monthly parent).
--   task 177 D14 (0124): the mssql_cpu_findings arm; mssql_counter_sample, mssql_counter_read, mssql_session_summary,
--     mssql_session_group, mssql_session_tempdb and mssql_activity_read among purge()'s monthly partition parents.
--   CLOUDSQL C4 (0128): mssql_pool_minute among purge()'s monthly partition parents (an elastic pool's minutes).
-- The view is 0110's with the new arms; purge() is 0110's with the new parent; apply_roles() is 0110's, unchanged.

CREATE OR REPLACE VIEW pgvigil.findings AS
SELECT DISTINCT ON (x.instance_id, x.setting, x.value, x.detail) x.*
  FROM (
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at
      FROM pgvigil.setting_rules WHERE hit
    UNION ALL
    -- task 201 (0121): the collector's own findings; instance_id NULL for the repository-wide ones
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.collector_findings
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
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_waiting', at FROM pgvigil.mssql_waiting_findings
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
    UNION ALL
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pgaudit_findings
    UNION ALL
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pg_override_findings
    UNION ALL
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pg_dboption_findings
    UNION ALL
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pg_depth_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_audit', at FROM pgvigil.mssql_audit_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_plancache', at FROM pgvigil.mssql_plancache_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_indexes', at FROM pgvigil.mssql_indexes_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_stats', at FROM pgvigil.mssql_stats_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_checks', at FROM pgvigil.mssql_checks_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_readers', at FROM pgvigil.mssql_readers_findings
    UNION ALL
    -- task 162 (0103): base backups, log shipping, crash restarts, the statement store, amcheck age
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pg_backups_findings
    UNION ALL
    -- task 177 D02 (0114): an implicit transaction blocking, sessions in implicit transactions, a lead blocker's share
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_blocking', at FROM pgvigil.mssql_blocking_findings
    UNION ALL
    -- task 177 D03 (0115): the wait findings of sp_PerfCheck, sp_BlitzFirst and sp_Blitz over the stored wait differences
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_waits', at FROM pgvigil.mssql_waits_findings
    UNION ALL
    -- task 177 D15 (0120): other processes at 50 % CPU or more, memory utilization 50 or less, a cut ring buffer
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_sysevents', at FROM pgvigil.mssql_sysevents_findings
    UNION ALL
    -- task 177 D13 (0119): grant timeouts, sp_Blitz 145 / 146, sp_BlitzFirst 45 / 46, the plan cache's bloat
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_memory', at FROM pgvigil.mssql_memory_findings
    UNION ALL
    -- task 177 D30 (0118): Darling's alert thresholds (PerformanceMonitor's alert set) over the stored reads
    SELECT d.instance_id, d.severity, d.setting, d.value, d.is_set, d.suggested, d.platforms, d.detail, d.source, d.at FROM pgvigil.darling_alert_findings d
     -- task 201 (the join fold): an instance has ONE 'server unreachable'. Where a collector that beats covers the failed
     -- read (0121's collector_covers) the connect failure is 0121's to report - 'authentication failing' for a refused
     -- login, 'server unreachable' after 3 failed connects in a row - with its streak and its place under 'collector or
     -- network'; 0118's own stays for an instance no heartbeat covers (a `pgvigil collect` on a schedule)
     WHERE NOT (d.source = 'collector' AND d.setting = 'server unreachable' AND pgvigil.collector_covers(d.instance_id, d.at))
    UNION ALL
    -- task 177 D14 (0124): other processes holding the CPU, a transaction open for a long time, slow data file writes
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_cpu', at FROM pgvigil.mssql_cpu_findings
  ) x
 ORDER BY x.instance_id, x.setting, x.value, x.detail;

CREATE OR REPLACE FUNCTION pgvigil.purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n         bigint := 0;
  v_rows    bigint;
  v_part    record;
  v_started timestamptz := clock_timestamp();   -- task 201: purge_runs
  v_dropped text[] := '{}';
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
                         'mssql_qs_interval', 'mssql_qs_runtime',
                         'pgaudit_events', 'pgaudit_counts', 'mssql_audit_counts', 'mssql_audit_events',
                         'mssql_pc_read', 'mssql_pc_sample', 'mssql_errorlog', 'mssql_health_components', 'mssql_trace_events',
                         'wal_state_sample', 'function_stats', 'slru_sample',
                         'mssql_waiting_summary', 'mssql_waiting_tasks', 'mssql_memory_pool',
                         'mssql_memory_rmon', 'mssql_memory_cache', 'mssql_plancache_type', 'mssql_memory_grant_query',
                         'mssql_counter_sample', 'mssql_counter_read', 'mssql_session_summary', 'mssql_session_group',
                         'mssql_session_tempdb', 'mssql_activity_read', 'mssql_pool_minute')
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)
     -- by parent, then partition: the order the imports take their parents in (a DROP takes the partition, then
     -- ACCESS EXCLUSIVE on its parent)
     ORDER BY p.relname, c.relname
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    v_dropped := v_dropped || v_part.relname::text;
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
  n := n + pgvigil.mssql_plancache_purge(p_days);
  -- the PostgreSQL job step runs (161, 0102) past the retention, as job_runs
  DELETE FROM pgvigil.job_step_runs WHERE start_time < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- alert test sends (151) past the retention (alert_dismissals and the acks columns are an audit: kept)
  DELETE FROM pgvigil.alert_tests WHERE requested_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- PostgreSQL depth (0095): rows no longer present past the retention
  DELETE FROM pgvigil.sequence_state WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.db_checks WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.index_bloat WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.depth_databases WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_xe_state WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- a cursor goes only with an instance no collection has reached for the whole window: a quiet source (no deadlock
  -- in a month) of a server still read keeps its place, or its file would be read again from the start
  -- the instance's own error-log search strings ('errorlog:search', 0091) are a setting, not a place in a file: they
  -- go with their instance by the foreign key, never with the window
  DELETE FROM pgvigil.mssql_cursor c WHERE c.updated_at < now() - make_interval(days => p_days) AND c.source <> 'errorlog:search'
     AND NOT EXISTS (SELECT 1 FROM pgvigil.collection_log l WHERE l.instance_id = c.instance_id AND l.snapshot_at >= now() - make_interval(days => p_days));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_ag_failovers WHERE at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- Query Store (0083): a query or a plan no read has listed within the window goes once no kept runtime row names it
  -- (the runtime partitions go by whole months, so a query's text stays as long as a runtime row of it does); a
  -- tuning recommendation no read has listed within the window goes; mssql_qs_store (each database's read cursor)
  -- and mssql_qs_tuning_option (current state) go with their instance only. A forced plan and a recommendation still
  -- marked present stay while their database's store row does: a store the collector no longer reads (OFF, ERROR, a
  -- database the login cannot enter) keeps listing them on its pages, and the ERROR state is when they matter most;
  -- a query named by such a plan or recommendation keeps its text
  DELETE FROM pgvigil.mssql_qs_plan p
   WHERE p.snapshot_at < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_qs_runtime r
                      WHERE r.instance_id = p.instance_id AND r.database_name = p.database_name AND r.query_id = p.query_id AND r.plan_id = p.plan_id)
     AND NOT (p.is_forced AND EXISTS (SELECT 1 FROM pgvigil.mssql_qs_store s
                                       WHERE s.instance_id = p.instance_id AND s.database_name = p.database_name));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_qs_query q
   WHERE q.snapshot_at < now() - make_interval(days => p_days)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_qs_runtime r
                      WHERE r.instance_id = q.instance_id AND r.database_name = q.database_name AND r.query_id = q.query_id)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_qs_plan p
                      WHERE p.instance_id = q.instance_id AND p.database_name = q.database_name AND p.query_id = q.query_id)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_qs_tuning t
                      WHERE t.instance_id = q.instance_id AND t.database_name = q.database_name AND t.query_id = q.query_id AND t.is_present
                        AND EXISTS (SELECT 1 FROM pgvigil.mssql_qs_store s WHERE s.instance_id = t.instance_id AND s.database_name = t.database_name));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_qs_tuning t
   WHERE t.snapshot_at < now() - make_interval(days => p_days)
     AND NOT (t.is_present AND EXISTS (SELECT 1 FROM pgvigil.mssql_qs_store s
                                        WHERE s.instance_id = t.instance_id AND s.database_name = t.database_name));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- pgaudit (0100): the per-second counts past the retention (the import trims them per instance; this takes a retired
  -- instance's rest), the health rows of instances no longer read, and the log cursors pgaudit no longer moves
  DELETE FROM pgvigil.pgaudit_count_secs WHERE sec < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.pgaudit_state s WHERE s.snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.log_cursor WHERE source LIKE 'pgaudit:%' AND updated_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- task 162 (0103): base backups, tool reads, Patroni members and standby replay rows absent past the retention
  -- (pg_role_changes and pg_thresholds are kept whole, like the audits)
  DELETE FROM pgvigil.pg_base_backups WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.pg_backup_tools WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.pg_patroni_members WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.pg_wal_replay WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  -- task 171: the mails asked (report_mail_schedules and report_mail_log are an audit, kept whole)
  DELETE FROM pgvigil.report_mail_sends WHERE requested_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- task 169: the Reports tree's SQL Server rows (mssql_table_size_at_idx and mssql_failed_logins_at_idx serve them)
  DELETE FROM pgvigil.mssql_table_size WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_failed_logins WHERE logged_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- task 201: the run recorded (the Collector page's last purge, the 'purge not run in 2 days' finding)
  INSERT INTO pgvigil.purge_runs (started_at, finished_at, days, partitions_dropped, rows_deleted, total)
  VALUES (v_started, clock_timestamp(), p_days, v_dropped, n - cardinality(v_dropped), n);
  RETURN n;
END $$;

-- task 201 (0121): alert_findings with the repository-wide findings (source 'pgvigil repository', no instance: each
-- collector's 'collector or network', 'purge not run in 2 days'), keyed as instance 0 (alert_finding_key of a NULL
-- instance is NULL) and named 'pgvigil'. The key is pgvigil.alert_key (0121): 0059's, but for 'collector or network',
-- whose value names a host and keeps its digits (the parents of 'pgv-1' and 'pgv-2' shared one key).
CREATE OR REPLACE VIEW pgvigil.alert_findings AS
SELECT pgvigil.alert_key(f.instance_id, f.source, f.setting, f.value) AS finding_key,
       f.instance_id, coalesce(i.name, 'pgvigil') AS instance, coalesce(t.tags, '{}'::text[]) AS tags,
       f.severity, f.setting, f.value, f.suggested, f.detail, f.source, f.at
  FROM (SELECT x.instance_id, x.severity, x.setting, x.value, x.suggested, x.detail, x.source, x.at FROM pgvigil.findings x
        UNION ALL
        SELECT y.instance_id, y.severity, y.setting, y.value, y.suggested, y.detail, y.source, y.at FROM pgvigil.alert_rule_findings y) f
  LEFT JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN pgvigil.instance_tags_merged t USING (instance_id)
 WHERE i.is_active OR f.source = 'pgvigil repository';

-- task 201: alert_due is 0073's with these changes: a repository-wide finding (source 'pgvigil repository') goes to
-- every channel past its severity floor, scoped channels too; an alert of a kind a shared cause explains
-- (pgvigil.collector_shared_cause) is held - it neither fires, repeats nor resolves - while a 'collector or network' of
-- its collector stands and the instance has had no ok collection since it began (collector_held_instances); a NEW
-- alert of such a kind waits while its instance is in a parent that may be forming (collector_forming: until the next
-- minute is written, 3 minutes at most) and, for the collector's own kinds, while its newest failure is inside an
-- 'instances failing together' window of the instance (collector_in_window: one failure past it after the parent
-- clears; an open one's repeat waits the same way, its escalation never); every other finding is sent as it is; a repository-wide alert is never 'the instance left' and resolves
-- once its finding has been gone for the channel's clear_after. held and forming are read once per pass.
CREATE OR REPLACE FUNCTION pgvigil.alert_due(p_at timestamptz, p_channels jsonb)
RETURNS TABLE (channel text, event text, finding_key text, instance_id int, instance text, severity text, source text,
               setting text, value text, detail text, suggested text, finding_at timestamptz, first_sent_at timestamptz,
               send_count int)
LANGUAGE sql STABLE SET jit = off AS $$
  WITH held AS MATERIALIZED (   -- task 201: the instances held under their collector's 'collector or network'
    SELECT instance_id FROM pgvigil.collector_held_instances
  ), forming AS MATERIALIZED (  -- task 201: the instances of a parent that may be forming
    SELECT DISTINCT instance_id FROM pgvigil.collector_forming
  ), slow_held AS MATERIALIZED (   -- the slow-connect tier: the members a standing fold holds (0121 collector_slow_held)
    SELECT instance_id FROM pgvigil.collector_slow_held
  ), slow_under AS MATERIALIZED (  -- a server's fold under its collector's standing fold: held
    SELECT value FROM pgvigil.collector_slow_folds WHERE kind = 'target' AND under_host
  ), slow_forming AS MATERIALIZED (  -- 3 or more of a collector's instances crossed in its newest minute: new ones wait
    SELECT instance_id FROM pgvigil.collector_slow_forming
  ), ch AS (
    SELECT c.name, pgvigil.severity_rank(c.min_severity) AS floor, coalesce(c.instances, '{}') AS instances,
           coalesce(c.tags, '{}') AS tags, coalesce(c.repeat_secs, 0) AS repeat_secs,
           coalesce(c.clear_after_secs, 600) AS clear_after_secs, coalesce(c.recovery, true) AS recovery
      FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
           AS c(name text, min_severity text, instances text[], tags text[], repeat_secs int, clear_after_secs int, recovery boolean)
  ), sc AS (   -- every finding in a channel's scope, any severity
    SELECT DISTINCT ON (ch.name, f.finding_key) ch.name AS channel, ch.floor, f.*
      FROM ch JOIN pgvigil.alert_findings f
        ON pgvigil.alert_in_scope(f.instance, f.tags, ch.instances, ch.tags) OR f.source = 'pgvigil repository'
     ORDER BY ch.name, f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC
  ), m AS (    -- the ones at or above its floor that nothing holds
    SELECT * FROM sc WHERE pgvigil.severity_rank(sc.severity) >= sc.floor
       AND pgvigil.ack_hold(p_at, sc.instance, sc.tags, sc.finding_key, sc.source, sc.setting, sc.value) IS NULL
       AND NOT (pgvigil.collector_shared_cause(sc.source, sc.setting)
                AND EXISTS (SELECT 1 FROM held WHERE held.instance_id = sc.instance_id))
       AND NOT (sc.source = 'pgvigil collector' AND sc.setting = 'slow connect'
                AND EXISTS (SELECT 1 FROM slow_held WHERE slow_held.instance_id = sc.instance_id))
       AND NOT (sc.source = 'pgvigil repository' AND sc.setting = 'slow connects'
                AND EXISTS (SELECT 1 FROM slow_under WHERE slow_under.value = sc.value))
  ), s AS (
    SELECT st.*, ch.repeat_secs, ch.recovery, ch.clear_after_secs,
           (i.is_active IS TRUE OR st.source = 'pgvigil repository') AS instance_active,
           EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = st.finding_key) AS present
      FROM pgvigil.alert_state st JOIN ch ON ch.name = st.channel
      LEFT JOIN pgvigil.instances i ON i.instance_id = st.instance_id
     WHERE st.cleared_at IS NULL
  )
  SELECT m.channel,
         CASE WHEN s.channel IS NULL THEN 'firing'
              WHEN pgvigil.severity_rank(m.severity) > pgvigil.severity_rank(s.severity) THEN 'escalated'
              ELSE 'repeat' END,
         m.finding_key, m.instance_id, m.instance, m.severity, m.source, m.setting, m.value, m.detail, m.suggested, m.at,
         s.first_sent_at, coalesce(s.send_count, 0)
    FROM m LEFT JOIN s ON s.channel = m.channel AND s.finding_key = m.finding_key
   WHERE CASE WHEN s.channel IS NULL   -- new: it waits while its instance's parent may be forming, or inside its window
              THEN NOT (pgvigil.collector_shared_cause(m.source, m.setting)
                        AND (EXISTS (SELECT 1 FROM forming WHERE forming.instance_id = m.instance_id)
                             OR (m.source = 'pgvigil collector' AND pgvigil.collector_in_window(m.instance_id, m.at))))
                   AND NOT (m.source = 'pgvigil collector' AND m.setting = 'slow connect'
                            AND EXISTS (SELECT 1 FROM slow_forming WHERE slow_forming.instance_id = m.instance_id))
              -- open: an escalation always; a repeat of a collector kind waits like a new one while its newest failure
              -- is inside a failing-together window (the instance released by an ok read, its finding standing until
              -- the next clean minute is written: a stale repeat just before its recovery) - deferred, never dropped
              ELSE pgvigil.severity_rank(m.severity) > pgvigil.severity_rank(s.severity)
                   OR (s.repeat_secs > 0 AND p_at - s.last_sent_at >= make_interval(secs => s.repeat_secs)
                       AND NOT pgvigil.ack_alert_acked(p_at, m.finding_key, s.first_sent_at)
                       AND NOT (m.source = 'pgvigil collector' AND pgvigil.collector_shared_cause(m.source, m.setting)
                                AND pgvigil.collector_in_window(m.instance_id, m.at)))
                   -- task 201 DONE-2 (N6): a repository-wide alert whose claim changed since its last send (a cut that
                   -- turned into a host not seen; a new cut while one stands): ONE repeat - alert_record stores the claim
                   -- it sent. An acknowledgement holds it, but for a NEWER event (collector_claim_newer), which passes
                   -- the ack as an escalation does
                   OR (m.source = 'pgvigil repository' AND s.why IS NOT NULL AND s.why IS DISTINCT FROM pgvigil.collector_claim(m.detail)
                       AND (NOT pgvigil.ack_alert_acked(p_at, m.finding_key, s.first_sent_at)
                            OR pgvigil.collector_claim_newer(pgvigil.collector_claim(m.detail), s.why))) END
  UNION ALL
  SELECT s.channel,
         CASE WHEN NOT s.instance_active OR s.present THEN 'cleared'          -- the instance left, or out of scope now
              WHEN s.recovery THEN 'resolved' ELSE 'cleared' END,
         s.finding_key, s.instance_id, s.instance_name, s.severity, s.source, s.setting, s.value, NULL, NULL, NULL,
         s.first_sent_at, s.send_count
    FROM s
   WHERE NOT EXISTS (SELECT 1 FROM sc WHERE sc.channel = s.channel AND sc.finding_key = s.finding_key)
     AND (NOT s.instance_active OR s.present
          OR (s.missing_since IS NOT NULL AND p_at - s.missing_since >= make_interval(secs => s.clear_after_secs)
              AND s.source = 'pgvigil repository')
          OR (s.missing_since IS NOT NULL AND p_at - s.missing_since >= make_interval(secs => s.clear_after_secs)
              AND NOT (pgvigil.collector_shared_cause(s.source, s.setting)
                       AND EXISTS (SELECT 1 FROM held WHERE held.instance_id = s.instance_id))
              AND EXISTS (SELECT 1 FROM pgvigil.collection_dates d
                           WHERE d.instance_id = s.instance_id AND d.status = 'ok' AND d.snapshot_at > s.missing_since)))
  ORDER BY 1, 2, 6, 5
$$;

-- task 201, the join fold (review 201a finding 5): a rule that names an instance never matches a repository-wide
-- alert. Those rows have no instance (source 'pgvigil repository': each collector's 'collector or network', 'purge not
-- run in 2 days') and are shown under the name 'pgvigil', which a real instance may carry too - the repository's own
-- server, monitored: a blackout for its maintenance held the parent on every channel. No name is impossible for an
-- instance of pgvigil.yaml but a blank one, so the test is bound to the row, not to a name. 0073's function with that
-- one change; alert_due, ack_hold and the alert page's matches all go through it.
CREATE OR REPLACE FUNCTION pgvigil.ack_rule_matches(a pgvigil.acks, p_instance text, p_tags text[], p_finding_key text,
                                                    p_source text, p_setting text, p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT (a.instance_name IS NULL OR (a.instance_name = p_instance AND p_source IS DISTINCT FROM 'pgvigil repository'))
     AND (a.tag IS NULL OR a.tag = ANY (coalesce(p_tags, '{}')))
     AND (a.finding_key IS NULL OR a.finding_key = p_finding_key)
     AND (a.check_key IS NULL OR lower(a.check_key) = lower(coalesce(p_source, '')) OR lower(a.check_key) = lower(coalesce(p_setting, '')))
     AND (a.match_text IS NULL
          OR strpos(lower(concat_ws(' ', p_source, p_setting, p_value)), lower(a.match_text)) > 0)
$$;

-- task 201 DONE-2 (N6): alert_record is 0059's with one change - at a send (firing, escalated, repeat) of a
-- repository-wide 'collector or network' it stores the claim it sent (collector_claim of the item's own detail, as the
-- sender sent it - never a read at record time: the claim may have changed since alert_due, or the parent left; a
-- read now only for an item without its detail) in alert_state.why (0121 adds the column), so alert_due sends ONE
-- repeat when the claim changes and none after it.
CREATE OR REPLACE FUNCTION pgvigil.alert_record(p_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_outcome text := p_payload->>'outcome';
  v_chan    text := nullif(p_payload->>'channel', '');
  v_items   jsonb := coalesce(p_payload->'items', '[]'::jsonb);
BEGIN
  IF to_regclass('pgvigil.alert_log_' || to_char(date_trunc('month', p_at AT TIME ZONE 'UTC'), 'YYYYMM')) IS NULL THEN
    PERFORM pgvigil.alert_log_partition(p_at);   -- a past month's partition is the owner's to make (the demo's history)
  END IF;
  WITH i AS (
    SELECT x.event, x.finding_key, x.instance_id
      FROM jsonb_to_recordset(v_items) AS x(event text, finding_key text, instance_id int)
     WHERE x.finding_key IS NOT NULL AND x.event IN ('firing', 'escalated', 'repeat', 'resolved', 'cleared')
  ), insts AS (SELECT array_agg(DISTINCT i.instance_id) AS a FROM i WHERE i.instance_id IS NOT NULL)
  INSERT INTO pgvigil.alert_log (snapshot_at, instance_id, channel, kind, destination, n_firing, n_repeat, n_resolved,
                                 outcome, error, keys)
  SELECT p_at, CASE WHEN cardinality((SELECT a FROM insts)) = 1 THEN (SELECT a[1] FROM insts) END, v_chan,
         nullif(p_payload->>'kind', ''), nullif(p_payload->>'destination', ''),
         (SELECT count(*) FROM i WHERE i.event IN ('firing', 'escalated')), (SELECT count(*) FROM i WHERE i.event = 'repeat'),
         (SELECT count(*) FROM i WHERE i.event IN ('resolved', 'cleared')), v_outcome,
         left(nullif(p_payload->>'error', ''), 2000),
         coalesce((SELECT array_agg(i.finding_key ORDER BY i.finding_key) FROM i), '{}');
  IF v_chan IS NULL OR v_outcome NOT IN ('sent', 'cleared') THEN
    RETURN;   -- a failed or refused attempt moves nothing: the next pass owes the same alerts
  END IF;
  INSERT INTO pgvigil.alert_state AS s (channel, finding_key, instance_id, instance_name, source, setting, value, severity,
                                        first_sent_at, last_sent_at, send_count, why)
  SELECT v_chan, x.finding_key, x.instance_id, coalesce(x.instance, ''), x.source, x.setting, x.value, x.severity, p_at, p_at, 1,
         CASE WHEN x.source = 'pgvigil repository' AND x.setting = 'collector or network'
              THEN coalesce(pgvigil.collector_claim(x.detail),   -- the claim SENT; a read now only for an item without its detail
                            (SELECT pgvigil.collector_claim(f.detail) FROM pgvigil.collector_findings f
                              WHERE f.source = x.source AND f.setting = x.setting AND f.value = x.value LIMIT 1)) END
    FROM jsonb_to_recordset(v_items) AS x(event text, finding_key text, instance_id int, instance text, severity text,
                                          source text, setting text, value text, detail text)
   WHERE x.event = 'firing' AND x.finding_key IS NOT NULL
  ON CONFLICT (channel, finding_key) WHERE cleared_at IS NULL DO UPDATE SET
    last_sent_at = EXCLUDED.last_sent_at, send_count = s.send_count + 1, severity = EXCLUDED.severity, value = EXCLUDED.value,
    missing_since = NULL, why = coalesce(EXCLUDED.why, s.why);
  UPDATE pgvigil.alert_state s SET last_sent_at = p_at, send_count = s.send_count + 1, severity = x.severity,
         value = x.value, missing_since = NULL,
         why = CASE WHEN s.source = 'pgvigil repository' AND s.setting = 'collector or network'
                    THEN coalesce(pgvigil.collector_claim(x.detail),   -- the claim SENT; a read now only for an item without its detail
                                  (SELECT pgvigil.collector_claim(f.detail) FROM pgvigil.collector_findings f
                                    WHERE f.source = s.source AND f.setting = s.setting AND f.value = x.value LIMIT 1), s.why)
                    ELSE s.why END
    FROM jsonb_to_recordset(v_items) AS x(event text, finding_key text, severity text, value text, detail text)
   WHERE x.event IN ('escalated', 'repeat') AND s.channel = v_chan AND s.finding_key = x.finding_key AND s.cleared_at IS NULL;
  UPDATE pgvigil.alert_state s SET cleared_at = p_at, recovery_sent_at = CASE WHEN x.event = 'resolved' THEN p_at END
    FROM jsonb_to_recordset(v_items) AS x(event text, finding_key text)
   WHERE x.event IN ('resolved', 'cleared') AND s.channel = v_chan AND s.finding_key = x.finding_key AND s.cleared_at IS NULL;
END $$;

-- ===== the slow-connect tier's WIRING (another file's objects: 0103's threshold keys, 0117's import_pg_threshold;
-- the tier itself is 0121's) =====
-- the 'connect_time' threshold: an instance's average connect over its last 5 written minutes, in seconds, over 1.00 /
-- 2.50 by default, at the root, a tag or an instance - both engines at the instance level (as 'uptime'); a unit of
-- 'seconds' joins the keys' check
ALTER TABLE pgvigil.pg_threshold_keys DROP CONSTRAINT IF EXISTS pg_threshold_keys_unit_check;
ALTER TABLE pgvigil.pg_threshold_keys ADD CONSTRAINT pg_threshold_keys_unit_check CHECK (unit IN ('seconds', 'minutes', 'hours', 'days'));
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('connect_time', 'Connect time: an instance''s average connect over its last 5 written minutes', 'seconds', 'over', 1.00, 2.50, '{root,tag,instance}', 60)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- import_pg_threshold: 0117's, with one change - 'connect_time' is both engines' at the instance level, as 'uptime'
CREATE OR REPLACE FUNCTION pgvigil.import_pg_threshold(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_key   text := p_payload->>'key';
  v_level text := p_payload->>'level';
  v_inst  int;
  v_tag   text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_db    text := nullif(p_payload->>'datname', '');
  v_k     pgvigil.pg_threshold_keys%ROWTYPE;
  v_warn  numeric;
  v_crit  numeric;
  v_why   text;
  v_old   bigint;
  v_new   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_pg_threshold: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
  END IF;
  SELECT * INTO v_k FROM pgvigil.pg_threshold_keys WHERE key = v_key;
  IF v_op IS NULL OR v_op NOT IN ('set', 'inherit') THEN
    v_why := 'op must be set or inherit';
  ELSIF v_k.key IS NULL THEN
    v_why := format('no threshold key %s (known: %s)', coalesce(v_key, '(none)'), (SELECT string_agg(key, ', ' ORDER BY key) FROM pgvigil.pg_threshold_keys));
  ELSIF v_level IS NULL OR NOT (v_level = ANY (v_k.levels)) THEN
    v_why := format('%s is set at the levels %s', v_key, array_to_string(v_k.levels, ', '));
  ELSIF v_level IN ('instance', 'database') AND (v_inst IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = v_inst
                                                  AND (i.engine = 'postgres' OR (v_key IN ('uptime', 'connect_time') AND v_level = 'instance')))) THEN
    -- the uptime key is both engines' (DBA Dash's Instance Uptime dialog, task 176b), and the slow-connect tier's
    -- connect_time: a SQL Server instance takes them
    v_why := format(CASE WHEN v_key IN ('uptime', 'connect_time') THEN 'no instance %s' ELSE 'no PostgreSQL instance %s' END, coalesce(p_payload->>'instance_id', '(none)'));
  ELSIF v_level = 'tag' AND (v_tag IS NULL OR length(v_tag) > 200) THEN
    v_why := 'a tag level names its tag (200 characters at most)';
  ELSIF v_level = 'database' AND (v_db IS NULL OR length(v_db) > 63) THEN
    v_why := 'a database level names its database (63 characters at most)';
  ELSIF v_op = 'set' THEN
    FOR i IN 1..2 LOOP
      DECLARE v text := p_payload->>(CASE i WHEN 1 THEN 'warn' ELSE 'crit' END);
      BEGIN
        IF v IS NOT NULL AND v !~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' THEN
          v_why := format('%s must be a number from 0 to %s (%s), or null', CASE i WHEN 1 THEN 'warn' ELSE 'crit' END, v_k.max_value, v_k.unit);
        ELSIF v IS NOT NULL AND v::numeric > v_k.max_value THEN
          v_why := format('%s must be a number from 0 to %s (%s), or null', CASE i WHEN 1 THEN 'warn' ELSE 'crit' END, v_k.max_value, v_k.unit);
        ELSIF v IS NOT NULL AND v_key = 'archive_age' AND (v !~ '^[0-9]+$' OR v::numeric < 1) THEN
          -- 0022's rule takes whole minutes (archive_warn_minutes is an int column there)
          v_why := format('archive_age takes whole minutes from 1 to %s, or null', v_k.max_value);
        END IF;
      END;
      EXIT WHEN v_why IS NOT NULL;
    END LOOP;
    IF v_why IS NULL THEN
      v_warn := (p_payload->>'warn')::numeric;
      v_crit := (p_payload->>'crit')::numeric;
      -- uptime and crash take a level with neither (DBA Dash's Enabled box off: not judged there, task P08)
      IF v_warn IS NULL AND v_crit IS NULL AND v_key NOT IN ('uptime', 'crash') THEN
        v_why := 'no threshold is set: to take the level above, inherit';
      ELSIF v_warn IS NOT NULL AND v_crit IS NOT NULL AND v_k.direction = 'over' AND v_crit < v_warn THEN
        v_why := format('%s: critical (%s) must be at or past warning (%s): the value grows toward it', v_key, v_crit, v_warn);
      ELSIF v_warn IS NOT NULL AND v_crit IS NOT NULL AND v_k.direction = 'under' AND v_crit > v_warn THEN
        v_why := format('%s: critical (%s) must be at or under warning (%s): the value falls toward it', v_key, v_crit, v_warn);
      END IF;
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_level = 'root' THEN v_inst := NULL; v_tag := NULL; v_db := NULL;
  ELSIF v_level = 'tag' THEN v_inst := NULL; v_db := NULL;
  ELSIF v_level = 'instance' THEN v_tag := NULL; v_db := NULL;
  ELSE v_tag := NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.pg_thresholds'), hashtext(v_key || '|' || v_level || '|' || coalesce(v_inst, 0) || '|' || coalesce(v_tag, '') || '|' || coalesce(v_db, '')));
  SELECT t.threshold_id INTO v_old FROM pgvigil.pg_thresholds t
   WHERE t.ended_at IS NULL AND t.key = v_key AND t.level = v_level AND coalesce(t.instance_id, 0) = coalesce(v_inst, 0)
     AND coalesce(t.tag, '') = coalesce(v_tag, '') AND coalesce(t.datname, '') = coalesce(v_db, '');
  IF v_op = 'inherit' AND v_old IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this level has no threshold of its own: it inherits already');
  END IF;
  UPDATE pgvigil.pg_thresholds SET ended_by = v_user, ended_at = p_at WHERE threshold_id = v_old;
  IF v_op = 'inherit' THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the level above applies', 'threshold_id', v_old);
  END IF;
  INSERT INTO pgvigil.pg_thresholds (key, level, instance_id, tag, datname, warn, crit, created_by, created_at, client, replaces)
  VALUES (v_key, v_level, v_inst, v_tag, v_db, v_warn, v_crit, v_user, p_at, nullif(p_payload->>'client', ''), v_old)
  RETURNING threshold_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'threshold_id', v_new);
END $$;

