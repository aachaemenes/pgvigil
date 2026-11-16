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
--   B2a (0145): mssql_azuredb_minute among purge()'s monthly partition parents (an Azure SQL Database's minutes).
--   task 406 B12 (0157): no findings arm here (mssql_querystore_findings is 0083's view, re-created by 0157); purge() calls
--     pgvigil.mssql_qs_plans_purge(p_days); apply_roles() (0110's) keeps mssql_qs_plans_purge, mssql_plan_stats_store and
--     mssql_plans_policy_drop owner only.
--   task 301 (0140): the mssql_backup_loc_findings arm; purge() keeps mssql_backup_roots_seen 400 days at least.
--   task 304 (0147): the mssql_restore_findings arm; nothing for purge() (its tables are current state, cascaded).
--   SLOW-CONNECT (0121): alert_due's slow-connect terms; the 'connect_time' threshold key (and 'seconds' in
--     pg_threshold_keys' unit check, which also takes the HA files' 'MB' and 'count'); import_pg_threshold is 0117's
--     with 0142's engines rule (pg_threshold_keys.engines), connect_time's row naming both engines.
--   HA join (0141-0144, 0150): purge()'s monthly partition parents gain mssql_repl_sample (0142) and
--     mssql_ag_replica_sample, mssql_ag_dbcounter_sample, mssql_mirroring_sample, mssql_logrestore_sample (0143);
--     mssql_mirroring_role_changes, mssql_fci_owner_changes and mssql_ag_seeding (0143) go by their time, as
--     mssql_ag_failovers (mssql_ag_seeding holds current rows, replaced whole by each newest read of its instance -
--     0143's import_mssql_ag - so its line only takes the last rows of an instance no read reaches any more: not
--     needed, kept as a bound); mssql_repl_hourly (0142) loses the hours past a year of an instance no import
--     reaches (a live instance's are trimmed by its import); purge()'s last block calls
--     pgvigil.replication_hourly_purge() (0150) beside 0139's. No line, on purpose: mssql_logship_foreign_logs and
--     mssql_logship_errors (current rows of 24 hours) and mssql_logship_idle, each replaced by every newest read
--     of its instance whose part did not fail (0143 L602-627: a read older than the state, or a failed part, leaves
--     the rows); replication_hourly_dirty (working ranges a heal removes). The threshold keys' unit check and
--     import_pg_threshold: at their lines below.
--   HA join, 376 (0144): the pg_patroni_findings arm of the findings view (0144 L19-20 leaves it to this file).
--   HA join (rel-hadr-s1, the lead's call #4 on Q7): backup_status (0103's) gains cluster_backups_on and
--     backup_rule_hits (0103's) raises 'retention under N days' and 'no snapshot in 24 h' once per Aurora cluster
--     (backup_cluster_holders, new: the cluster keyed by its ARN, backup_state.arn; import_backups is 0022's with it),
--     at the end of this file.
-- The view is 0110's with the new arms; purge() is 0110's with the new parents and lines; apply_roles() is not here
-- (0110's, its owner-only list extended in 0110 itself).
--   INVALID DATABASES (rel-invxid): pg_db_options is 0104's view REPLACED WHOLE here (an invalid database's xid cell grey
--     'not judged'; the rest 0104's text), and the findings view's 'database xid age' arm leaves an invalid database out.

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
       AND coalesce(d.conn_limit, 0) <> -2   -- an invalid database (an interrupted DROP): autovacuum skips it, its age is no risk
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
    -- task 376 (0144): Patroni - no leader, a member down, paused, a pending restart, the DCS not reached, the API
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pg_patroni_findings
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
    UNION ALL
    -- task 301 (0140): a backup on the database's own volume, log backups to two destinations, a destination not seen before
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_backup_loc', at FROM pgvigil.mssql_backup_loc_findings
    UNION ALL
    -- task 304 (0147): the log chain is broken (never for a gap a replica's late read may fill)
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_restore_chain', at FROM pgvigil.mssql_restore_findings
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
                         'mssql_session_tempdb', 'mssql_activity_read', 'mssql_pool_minute', 'mssql_azuredb_minute',
                         'mssql_repl_sample', 'mssql_ag_replica_sample', 'mssql_ag_dbcounter_sample', 'mssql_mirroring_sample',
                         'mssql_logrestore_sample')
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
  n := n + pgvigil.mssql_qs_plans_purge(p_days);   -- task 406 (0157): running plans, live captures, plan statistics, forced-plan failures
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
  -- the HA join (0143): a mirrored database's role changes and a failover cluster instance's owner changes are history
  -- as the failovers above are, and go by the same age. The seeding rows are current rows that each read replaces
  -- whole: one older than the age belongs to an instance no read has reached for the whole window, as with
  -- mssql_xe_state above
  DELETE FROM pgvigil.mssql_mirroring_role_changes WHERE at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_fci_owner_changes WHERE at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_ag_seeding WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- the HA join (0142): the replication hours keep a year - the import trims them per instance; this takes the rest
  -- of an instance no import reaches any more (as pgaudit_count_secs below), never under that year
  DELETE FROM pgvigil.mssql_repl_hourly WHERE hour < now() - make_interval(days => greatest(p_days, 366));
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
  -- task 301 (0140): the backup destinations seen are kept 400 days at least (the info finding 'a backup destination
  -- not seen before' needs the earlier ones; one row per database, type and root); 0140's other tables and 0147's are
  -- current state and go with their instance (ON DELETE CASCADE)
  DELETE FROM pgvigil.mssql_backup_roots_seen WHERE last_seen < now() - make_interval(days => greatest(p_days, 400));
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- 0139 (FLEET STATS ROLLUP): the hours tables last, each by its own age in pgvigil.hours_retention (not p_days), so
  -- no runs table is locked after an hours parent; the months dropped join this run's partitions_dropped. The hours'
  -- heals are not here (one transaction for all): 'pgvigil purge' runs them after this, one instance per transaction
  IF to_regprocedure('pgvigil.job_stats_hourly_purge()') IS NOT NULL THEN
    n := n - cardinality(v_dropped);
    v_dropped := v_dropped || pgvigil.job_stats_hourly_purge();
    n := n + cardinality(v_dropped);
  END IF;
  -- 0150 (the HA join): replication_hourly the same way, by its own hours_retention row
  IF to_regprocedure('pgvigil.replication_hourly_purge()') IS NOT NULL THEN
    n := n - cardinality(v_dropped);
    v_dropped := v_dropped || pgvigil.replication_hourly_purge();
    n := n + cardinality(v_dropped);
  END IF;
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
  ), slow_folds AS MATERIALIZED (  -- the slow-connect tier: the standing folds, read once a pass (0121 collector_slow_folds)
    SELECT kind, value, under_host, held FROM pgvigil.collector_slow_folds
  ), slow_held AS MATERIALIZED (   -- the members a standing fold holds (those at or under its level)
    SELECT DISTINCT m.instance_id FROM slow_folds f CROSS JOIN LATERAL unnest(f.held) AS m(instance_id)
  ), slow_under AS MATERIALIZED (  -- a server's fold under its collector's standing fold: held (a server two collectors
    -- fold - one alert key - only when it is under the fold of every one of them)
    SELECT value FROM slow_folds WHERE kind = 'target' GROUP BY value HAVING bool_and(under_host)
  ), slow_forming AS MATERIALIZED (  -- 3 or more of a collector's instances crossed in its newest minute: new ones wait
    SELECT instance_id FROM pgvigil.collector_slow_forming
  ), ch AS (
    SELECT c.name, pgvigil.severity_rank(c.min_severity) AS floor, coalesce(c.instances, '{}') AS instances,
           coalesce(c.tags, '{}') AS tags, coalesce(c.repeat_secs, 0) AS repeat_secs,
           coalesce(c.clear_after_secs, 600) AS clear_after_secs, coalesce(c.recovery, true) AS recovery,
           coalesce(c.repo_wide, true) AS repo_wide
      FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
           AS c(name text, min_severity text, instances text[], tags text[], repeat_secs int, clear_after_secs int, recovery boolean,
                repo_wide boolean)
  ), sc AS (   -- every finding in a channel's scope, any severity (a repository-wide one: every channel but a route's,
               -- task 310 - an application contact's route says repo_wide false)
    SELECT DISTINCT ON (ch.name, f.finding_key) ch.name AS channel, ch.floor, f.*
      FROM ch JOIN pgvigil.alert_findings f
        ON pgvigil.alert_in_scope(f.instance, f.tags, ch.instances, ch.tags) OR (f.source = 'pgvigil repository' AND ch.repo_wide)
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
     -- a collector's 'slow connects' is not 'resolved' while that collector's own 'collector or network' stands (its
     -- connects stopped being judged because it stopped, not because they got faster)
     AND NOT (s.source = 'pgvigil repository' AND s.setting = 'slow connects'
              AND EXISTS (SELECT 1 FROM pgvigil.collector_parent p WHERE p.host = s.value))
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

-- pg_db_options (0104's, replaced whole here: 0104 is not edited in place): an invalid database (datconnlimit -2, an
-- interrupted DROP DATABASE) gets no xid verdict - autovacuum and the clog truncation skip it (13.12 / 14.9 / 15.4 / 16+),
-- so its frozen-xid age only grows and holds nothing back; its connection cell already says DROP DATABASE.
CREATE OR REPLACE VIEW pgvigil.pg_db_options AS
WITH n0 AS (    -- the newest connections read of each instance in the last 10 minutes (the collection runs every minute)
  SELECT c.instance_id, max(c.snapshot_at) AS at
    FROM pgvigil.conn_sources c
   WHERE c.snapshot_at > now() - interval '10 minutes'
   GROUP BY 1
), n AS (       -- folded: the read put its smallest sources under '(other sources)', so a database's count is a floor
  SELECT n0.instance_id, n0.at,
         EXISTS (SELECT 1 FROM pgvigil.conn_sources c WHERE c.instance_id = n0.instance_id AND c.snapshot_at = n0.at
                    AND c.datname = '(other sources)') AS folded
    FROM n0
), cs AS (
  SELECT c.instance_id, c.datname, sum(c.total)::int AS sessions
    FROM pgvigil.conn_sources c JOIN n ON n.instance_id = c.instance_id AND n.at = c.snapshot_at
   GROUP BY 1, 2
), b AS (
  SELECT d.instance_id, d.dbid, d.datname, d.is_template, d.allow_conn, d.conn_limit, d.encoding, d.xid_age, d.snapshot_at,
         st.platform, st.server_version_num, st.data_checksums, n.at AS sessions_at, coalesce(n.folded, false) AS folded,
         CASE WHEN n.at IS NOT NULL THEN coalesce(cs.sessions, 0) END AS sessions,
         fm.v AS freeze_max_age,
         co.dbid IS NOT NULL AS collation_read, co.provider, co.locale, co.recorded_version, co.actual_version
    FROM pgvigil.databases d
    JOIN pgvigil.instance_state st ON st.instance_id = d.instance_id
    LEFT JOIN n ON n.instance_id = d.instance_id
    LEFT JOIN cs ON cs.instance_id = d.instance_id AND cs.datname = d.datname
    LEFT JOIN LATERAL (SELECT CASE WHEN x->>'value' ~ '^[0-9]+$' THEN (x->>'value')::bigint END AS v
                         FROM jsonb_array_elements(coalesce(st.non_default_settings, '[]'::jsonb)) x
                        WHERE x->>'name' = 'autovacuum_freeze_max_age' LIMIT 1) fx ON true
    CROSS JOIN LATERAL (SELECT coalesce(fx.v, 200000000) AS v) fm
    LEFT JOIN pgvigil.database_collations co ON co.instance_id = d.instance_id AND co.dbid = d.dbid AND co.is_present
   WHERE d.is_present
), j AS (
  SELECT b.*,
    -- the connection limit against the sessions now (a superuser is not held to it; the count is every client session
    -- of the newest read but the collector's own)
    -- datconnlimit -2 (PostgreSQL 13.12, 14.9, 15.4, 16 and later): an interrupted DROP DATABASE left it invalid
    CASE WHEN b.conn_limit = -2 THEN 'crit' WHEN NOT coalesce(b.allow_conn, true) OR b.conn_limit IS NULL THEN 'none'
         WHEN b.conn_limit < 0 THEN 'ok' WHEN b.conn_limit = 0 THEN 'warn'
         WHEN b.sessions IS NULL THEN 'none' WHEN b.sessions >= b.conn_limit THEN 'crit'
         WHEN b.folded THEN 'none' WHEN b.sessions >= 0.8 * b.conn_limit THEN 'warn' ELSE 'ok' END AS conn_status,
    CASE WHEN b.conn_limit = -2 THEN 'invalid: an interrupted DROP DATABASE left it; no session can connect and only DROP DATABASE removes it'
         WHEN NOT coalesce(b.allow_conn, true) THEN 'not judged: connections are not allowed'
         WHEN b.conn_limit IS NULL THEN 'not read' WHEN b.conn_limit < 0 THEN 'no limit'
         WHEN b.conn_limit = 0 THEN 'closed: CONNECTION LIMIT 0 lets only a superuser in'
         WHEN b.sessions IS NULL THEN 'sessions not read in the last 10 minutes (the connections collection)'
         WHEN b.sessions >= b.conn_limit THEN 'reached: a new session of a login that is not a superuser is refused'
         WHEN b.folded THEN 'not judged: the read folded its smallest connection sources into (other sources), so the count is a floor'
         WHEN b.sessions >= 0.8 * b.conn_limit THEN 'near: 80 % or more of the limit in use' ELSE 'room' END AS conn_note,
    -- allow connections
    CASE WHEN b.allow_conn IS NULL OR b.conn_limit = -2 THEN 'none' WHEN coalesce(b.is_template, false) THEN 'none' WHEN b.allow_conn THEN 'ok' ELSE 'warn' END AS allow_status,
    CASE WHEN b.allow_conn IS NULL THEN 'not read' WHEN b.conn_limit = -2 THEN 'an invalid database: not judged'
         WHEN coalesce(b.is_template, false) THEN 'a template: not judged'
         WHEN b.allow_conn THEN 'allowed' ELSE 'not allowed: no session can use the database (ALTER DATABASE ... ALLOW_CONNECTIONS true opens it)' END AS allow_note,
    -- encoding
    -- template0's encoding binds nothing: CREATE DATABASE ... TEMPLATE template0 takes any encoding
    CASE WHEN b.encoding IS NULL OR b.datname = 'template0' THEN 'none' WHEN b.encoding = 'UTF8' THEN 'ok' ELSE 'warn' END AS encoding_status,
    CASE WHEN b.encoding IS NULL THEN 'not read' WHEN b.datname = 'template0' THEN b.encoding || ' (template0: CREATE DATABASE ... TEMPLATE template0 takes any encoding)'
         WHEN b.encoding = 'UTF8' THEN 'UTF8'
         WHEN b.encoding = 'SQL_ASCII' THEN 'SQL_ASCII stores bytes unchecked: no character is validated or converted'
         ELSE 'not UTF8: characters outside ' || b.encoding || ' cannot be stored' END AS encoding_note,
    -- the collation version (PostgreSQL 15+)
    CASE WHEN b.server_version_num < 150000 THEN 'none' WHEN NOT b.collation_read THEN 'none'
         WHEN b.recorded_version IS NULL OR b.actual_version IS NULL THEN 'none'
         WHEN b.recorded_version <> b.actual_version THEN 'warn' ELSE 'ok' END AS collation_status,
    CASE WHEN b.server_version_num < 150000 THEN 'PostgreSQL 15+ records it'
         WHEN NOT b.collation_read THEN 'not read (the versions collection reads the databases the login may connect to)'
         WHEN b.recorded_version IS NULL OR b.actual_version IS NULL THEN 'the locale has no version (C, POSIX or the builtin provider)'
         WHEN b.recorded_version <> b.actual_version THEN 'recorded ' || b.recorded_version || ', the library now ' || b.actual_version
              || ': text indexes may be out of order; REINDEX them, then ALTER DATABASE ... REFRESH COLLATION VERSION'
         ELSE 'recorded ' || b.recorded_version || ' = the library''s' END AS collation_note,
    -- data checksums (the cluster's): the severity is corruption_findings'
    CASE WHEN b.data_checksums IS NULL OR b.platform = 'aurora' THEN 'none' WHEN b.data_checksums = 'on' THEN 'ok' ELSE 'warn' END AS checksums_status,
    CASE WHEN b.data_checksums IS NULL THEN 'not read' WHEN b.platform = 'aurora' THEN 'Aurora''s storage checks its own pages: not judged'
         WHEN b.data_checksums = 'on' THEN 'on'
         WHEN b.platform = 'onprem' THEN 'off: a damaged page is read as good data (pg_checksums --enable on the stopped cluster)'
         ELSE 'off: a damaged page is read as good data; the platform cannot turn them on in place' END AS checksums_note,
    -- age(datfrozenxid) against autovacuum_freeze_max_age
    CASE WHEN b.conn_limit = -2 THEN 'none' WHEN b.xid_age IS NULL THEN 'none' WHEN b.xid_age >= 1000000000 THEN 'crit' WHEN b.xid_age >= b.freeze_max_age THEN 'warn' ELSE 'ok' END AS xid_status,
    CASE WHEN b.conn_limit = -2 THEN 'an invalid database: not judged (autovacuum and the clog truncation skip it, so its age only grows; DROP DATABASE removes it)'
         WHEN b.xid_age IS NULL THEN 'not read' WHEN b.xid_age >= 1000000000 THEN 'past 1 billion: find what holds vacuum back before the 2 billion stop'
         WHEN b.xid_age >= b.freeze_max_age THEN 'past autovacuum_freeze_max_age (' || b.freeze_max_age || '): the anti-wraparound vacuum is due; staying here means it is held back'
         ELSE 'under autovacuum_freeze_max_age (' || b.freeze_max_age || ')' END AS xid_note
    FROM b
)
SELECT j.instance_id, j.dbid, j.datname, j.is_template, j.snapshot_at, j.platform, j.server_version_num,
       j.conn_limit, j.sessions, j.sessions_at, j.conn_status, CASE j.conn_status WHEN 'crit' THEN 'critical' WHEN 'warn' THEN 'warning' END AS conn_severity, j.conn_note,
       j.allow_conn, j.allow_status, CASE WHEN j.allow_status = 'warn' THEN 'warning' END AS allow_severity, j.allow_note,
       j.encoding, j.encoding_status, CASE WHEN j.encoding_status = 'warn' THEN 'info' END AS encoding_severity, j.encoding_note,
       j.provider AS collation_provider, j.locale AS collation_locale, j.recorded_version, j.actual_version,
       j.collation_status, CASE WHEN j.collation_status = 'warn' THEN 'warning' END AS collation_severity, j.collation_note,
       j.data_checksums, j.checksums_status,
       CASE WHEN j.checksums_status = 'warn' THEN CASE WHEN j.platform = 'onprem' THEN 'warning' ELSE 'info' END END AS checksums_severity, j.checksums_note,
       j.xid_age, j.freeze_max_age, j.xid_status,
       CASE j.xid_status WHEN 'crit' THEN 'critical' WHEN 'warn' THEN 'warning' END AS xid_severity, j.xid_note,
       (j.conn_status IN ('warn', 'crit'))::int + (j.allow_status = 'warn')::int + (j.encoding_status = 'warn')::int
         + (j.collation_status = 'warn')::int + (j.checksums_status = 'warn')::int + (j.xid_status IN ('warn', 'crit'))::int AS deviations,
       CASE WHEN 'crit' IN (j.conn_status, j.xid_status) THEN 'crit'
            WHEN 'warn' IN (j.conn_status, j.allow_status, j.encoding_status, j.collation_status, j.checksums_status, j.xid_status) THEN 'warn'
            ELSE 'ok' END AS worst
  FROM j;

-- ===== the slow-connect tier's WIRING (another file's objects: 0103's threshold keys, 0117's import_pg_threshold;
-- the tier itself is 0121's) =====
-- the 'connect_time' threshold: an instance's average connect over its last 5 written minutes, in seconds, over 1.00 /
-- 2.50 by default, at the root, a tag or an instance - both engines at the instance level (as 'uptime'); a unit of
-- 'seconds' joins the keys' check. This file runs after 0141 and 0150 (the HA join), whose keys are stored in 'MB' and
-- as a 'count' by then: the list is every unit a file below this one stores, or the check fails on those rows
ALTER TABLE pgvigil.pg_threshold_keys DROP CONSTRAINT IF EXISTS pg_threshold_keys_unit_check;
ALTER TABLE pgvigil.pg_threshold_keys ADD CONSTRAINT pg_threshold_keys_unit_check CHECK (unit IN ('seconds', 'minutes', 'hours', 'days', 'MB', 'count'));
-- the engines whose instances take a key at the instance and database level: pg_threshold_keys.engines (the HA join;
-- 0142's column and 0142's two lines, repeated here so this file stands on a tree without 0142). connect_time is both
-- engines', as uptime
ALTER TABLE pgvigil.pg_threshold_keys ADD COLUMN IF NOT EXISTS engines text[] NOT NULL DEFAULT '{postgres}';
UPDATE pgvigil.pg_threshold_keys SET engines = '{postgres,sqlserver}' WHERE key = 'uptime';
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value, engines) VALUES
  ('connect_time', 'Connect time: an instance''s average connect over its last 5 written minutes', 'seconds', 'over', 1.00, 2.50, '{root,tag,instance}', 60, '{postgres,sqlserver}')
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value,
  engines = EXCLUDED.engines;

-- import_pg_threshold: 0117's with 0142's one change (the HA join: this file runs after 0142 and would undo it) - a key
-- is taken at the instance and database level by an instance of the key's engines; 'connect_time' is both engines'
-- by its row above, as 'uptime'
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
                                                  AND i.engine = ANY (v_k.engines))) THEN
    -- the key's engines take it (0142): uptime (DBA Dash's Instance Uptime dialog, task 176b) and the slow-connect
    -- tier's connect_time both engines', the replication and HA keys SQL Server's, every other key PostgreSQL's
    v_why := format(CASE WHEN v_k.engines = '{postgres}' THEN 'no PostgreSQL instance %s' WHEN v_k.engines = '{sqlserver}' THEN 'no SQL Server instance %s'
                         ELSE 'no instance %s' END, coalesce(p_payload->>'instance_id', '(none)'));
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

-- An Aurora cluster's backups are the cluster's: every instance with an aws: block reads the same cluster (its
-- retention and snapshots), so 0103's two cloud rules fired on the writer and again on each reader; now once, on the
-- cluster's holder (a stable member: backup_cluster_holders). backup_status is
-- 0103's with cluster_backups_on at the end: the instance that holds the cluster's backups when it is another one
-- (NULL: not a cluster, or this instance holds them); backup_rule_hits is 0103's with the two cloud arms held to the
-- holder (backup_cluster_holders). A cluster's key is its lower-cased DBClusterArn (backup_state.arn, read since this
-- file); a row with no ARN (a collector before it, one read after the upgrade) takes the one ARN its identifier carries
-- among the rows, else keeps its identifier: two clusters of one name, neither read with an ARN, read as one. One
-- holder per key, so a mix of rows never silences a cluster (it may raise twice until the next read). import_backups
-- is 0022's with arn stored.
ALTER TABLE pgvigil.backup_state ADD COLUMN IF NOT EXISTS arn text;   -- cloud: a cluster's DBClusterArn

CREATE OR REPLACE FUNCTION pgvigil.import_backups(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_backups'), p_instance_id);
  PERFORM pgvigil.ensure_month_partition('backup_sample', p_snapshot_at);

  INSERT INTO pgvigil.backup_state AS s (instance_id, kind, name, snapshot_at, archive_mode, archive_timeout, archive_set, archived_count,
                                         last_archived_wal, last_archived_time, failed_count, last_failed_wal, last_failed_time, stats_reset,
                                         is_replica, wal_segment_bytes, current_lsn, archive_lag_bytes, archive_warn_minutes, resource_kind,
                                         retention_days, latest_restorable_time, earliest_restorable_time, backup_window, snapshot_type,
                                         status, created_at, allocated_gib, encrypted, first_seen, is_present, arn)
  SELECT p_instance_id, r->>'kind', r->>'name', p_snapshot_at, r->>'archive_mode', r->>'archive_timeout', (r->>'archive_set')::boolean,
         (r->>'archived_count')::bigint, r->>'last_archived_wal', (r->>'last_archived_time')::timestamptz, (r->>'failed_count')::bigint,
         r->>'last_failed_wal', (r->>'last_failed_time')::timestamptz, (r->>'stats_reset')::timestamptz, (r->>'is_replica')::boolean,
         (r->>'wal_segment_bytes')::bigint, r->>'current_lsn', (r->>'archive_lag_bytes')::bigint,
         coalesce((r->>'archive_warn_minutes')::int, CASE WHEN r->>'kind' = 'archiver' THEN 60 END), r->>'resource_kind',
         (r->>'retention_days')::int, (r->>'latest_restorable_time')::timestamptz, (r->>'earliest_restorable_time')::timestamptz,
         r->>'backup_window', r->>'snapshot_type', r->>'status', (r->>'created_at')::timestamptz, (r->>'allocated_gib')::int,
         (r->>'encrypted')::boolean, p_snapshot_at, true, nullif(r->>'arn', '')
    FROM (SELECT DISTINCT ON (r->>'kind', r->>'name') r FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' IN ('archiver', 'cloud', 'snapshot') AND r->>'name' IS NOT NULL) x
  ON CONFLICT (instance_id, kind, name) DO UPDATE SET
    snapshot_at = EXCLUDED.snapshot_at, archive_mode = EXCLUDED.archive_mode, archive_timeout = EXCLUDED.archive_timeout,
    archive_set = EXCLUDED.archive_set, archived_count = EXCLUDED.archived_count, last_archived_wal = EXCLUDED.last_archived_wal,
    last_archived_time = EXCLUDED.last_archived_time, failed_count = EXCLUDED.failed_count, last_failed_wal = EXCLUDED.last_failed_wal,
    last_failed_time = EXCLUDED.last_failed_time, stats_reset = EXCLUDED.stats_reset, is_replica = EXCLUDED.is_replica,
    wal_segment_bytes = EXCLUDED.wal_segment_bytes, current_lsn = EXCLUDED.current_lsn, archive_lag_bytes = EXCLUDED.archive_lag_bytes,
    archive_warn_minutes = EXCLUDED.archive_warn_minutes, resource_kind = EXCLUDED.resource_kind, retention_days = EXCLUDED.retention_days,
    latest_restorable_time = EXCLUDED.latest_restorable_time, earliest_restorable_time = EXCLUDED.earliest_restorable_time,
    backup_window = EXCLUDED.backup_window, snapshot_type = EXCLUDED.snapshot_type, status = EXCLUDED.status,
    created_at = EXCLUDED.created_at, allocated_gib = EXCLUDED.allocated_gib, encrypted = EXCLUDED.encrypted, is_present = true,
    arn = EXCLUDED.arn;

  -- absence: a cloud resource no longer named (the config moved to another), a snapshot no longer listed by a
  -- list that was read in full this run
  UPDATE pgvigil.backup_state s SET is_present = false
   WHERE s.instance_id = p_instance_id AND s.is_present AND s.kind IN ('cloud', 'archiver')
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = s.kind)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = s.kind AND r->>'name' = s.name);
  UPDATE pgvigil.backup_state s SET is_present = false
   WHERE s.instance_id = p_instance_id AND s.is_present AND s.kind = 'snapshot'
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'snapshots_read')
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'snapshot' AND r->>'name' = s.name);

  INSERT INTO pgvigil.backup_sample (instance_id, snapshot_at, archived_count, failed_count, archive_lag_bytes, last_archived_time, restorable_age_s)
  SELECT p_instance_id, p_snapshot_at, (a->>'archived_count')::bigint, (a->>'failed_count')::bigint, (a->>'archive_lag_bytes')::bigint,
         (a->>'last_archived_time')::timestamptz,
         round(extract(epoch FROM p_snapshot_at - (c->>'latest_restorable_time')::timestamptz)::numeric, 0)
    FROM (SELECT (SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'archiver' LIMIT 1) AS a,
                 (SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cloud' LIMIT 1) AS c) x
   WHERE x.a IS NOT NULL OR x.c IS NOT NULL;
END $$;

-- backup_cluster_holders: per active instance with a cluster cloud row, the instance that holds its cluster's backups -
-- a STABLE member (the lead's call): the lowest instance id among the cluster's active instances read in the last hour
-- (the lowest id when none is), not necessarily the writer, so a failover neither moves, resolves nor reopens the
-- cluster's findings; cluster_backups_on is the holder's name when it is another instance (backup_status and the
-- Summary's row).
CREATE OR REPLACE VIEW pgvigil.backup_cluster_holders AS
WITH cl AS (
  SELECT c.instance_id, lower(c.name) AS cname, lower(c.arn) AS arn, c.snapshot_at > now() - interval '1 hour' AS fresh
    FROM pgvigil.backup_state c
    JOIN pgvigil.instances i ON i.instance_id = c.instance_id AND i.is_active
   WHERE c.kind = 'cloud' AND c.is_present AND c.resource_kind = 'cluster'
), ck AS (
  SELECT cl.*, coalesce(cl.arn, n.arn, 'id:' || cl.cname) AS ckey
    FROM cl LEFT JOIN (SELECT cname, min(arn) AS arn FROM cl GROUP BY cname HAVING count(DISTINCT arn) = 1) n USING (cname)
), hold AS (
  SELECT DISTINCT ON (ckey) ckey, instance_id AS holder_id FROM ck ORDER BY ckey, fresh DESC, instance_id
)
SELECT ck.instance_id, ck.ckey AS cluster_key, h.holder_id, hi.name AS holder,
       CASE WHEN h.holder_id <> ck.instance_id THEN hi.name END AS cluster_backups_on
  FROM ck JOIN hold h USING (ckey) JOIN pgvigil.instances hi ON hi.instance_id = h.holder_id;

CREATE OR REPLACE VIEW pgvigil.backup_status AS
WITH snap AS (
  SELECT instance_id,
         max(created_at) FILTER (WHERE snapshot_type = 'automated' AND status = 'available') AS newest_automated_at,
         max(created_at) FILTER (WHERE snapshot_type = 'manual' AND status = 'available') AS newest_manual_at,
         max(created_at) FILTER (WHERE status = 'available') AS newest_snapshot_at,
         count(*) FILTER (WHERE snapshot_type = 'automated') AS automated_count,
         count(*) FILTER (WHERE snapshot_type = 'manual') AS manual_count
    FROM pgvigil.backup_state WHERE kind = 'snapshot' AND is_present GROUP BY instance_id
)
SELECT i.instance_id, i.name AS instance, i.platform,
       a.archive_mode, a.archive_set, a.is_replica,
       (a.archive_set AND (a.archive_mode = 'always' OR (a.archive_mode = 'on' AND NOT a.is_replica))) AS archiving,
       a.archived_count, a.failed_count, a.last_archived_wal, a.last_archived_time, a.last_failed_wal, a.last_failed_time,
       a.stats_reset, a.archive_lag_bytes, a.wal_segment_bytes,
       CASE WHEN aw.level <> 'default' AND aw.warn IS NOT NULL THEN aw.warn::int ELSE a.archive_warn_minutes END AS archive_warn_minutes,
       round(extract(epoch FROM a.snapshot_at - a.last_archived_time)::numeric, 0) AS archive_age_s,
       (a.archive_set AND (a.archive_mode = 'always' OR (a.archive_mode = 'on' AND NOT a.is_replica))
        AND a.last_failed_time IS NOT NULL AND (a.last_archived_time IS NULL OR a.last_failed_time > a.last_archived_time)) AS archiver_failing,
       (a.archive_lag_bytes > a.wal_segment_bytes) AS wal_waiting,
       a.snapshot_at AS archiver_read_at,
       c.name AS cloud_resource, c.resource_kind, c.retention_days, c.latest_restorable_time, c.earliest_restorable_time, c.backup_window,
       round(extract(epoch FROM c.snapshot_at - c.latest_restorable_time)::numeric, 0) AS restorable_age_s,
       c.snapshot_at AS cloud_read_at,
       s.newest_automated_at, s.newest_manual_at, s.newest_snapshot_at,
       round(extract(epoch FROM c.snapshot_at - s.newest_snapshot_at)::numeric, 0) AS newest_snapshot_age_s,
       coalesce(s.automated_count, 0) AS automated_count, coalesce(s.manual_count, 0) AS manual_count,
       h.cluster_backups_on
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.backup_state a ON a.instance_id = i.instance_id AND a.kind = 'archiver' AND a.is_present
  LEFT JOIN pgvigil.backup_state c ON c.instance_id = i.instance_id AND c.kind = 'cloud' AND c.is_present
  LEFT JOIN snap s ON s.instance_id = i.instance_id
  LEFT JOIN pgvigil.backup_cluster_holders h ON h.instance_id = i.instance_id
  CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'archive_age') aw
 WHERE i.is_active AND (a.instance_id IS NOT NULL OR c.instance_id IS NOT NULL);


CREATE OR REPLACE VIEW pgvigil.backup_rule_hits AS
SELECT b.instance_id, 'critical' AS severity, 'archiver failing' AS check_name, coalesce(b.last_failed_wal, 'pg_stat_archiver') AS object,
       b.archiver_read_at AS at,
       'archive of ' || coalesce(b.last_failed_wal, '?') || ' failed at ' || to_char(b.last_failed_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
       || coalesce(', after the last success at ' || to_char(b.last_archived_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', ', no success since the stats reset')
       || ' (' || b.failed_count || ' failed, ' || b.archived_count || ' archived)' AS detail
  FROM pgvigil.backup_status b
 WHERE b.archiver_failing AND b.platform <> 'aurora'
UNION ALL
SELECT b.instance_id, 'warning', 'last archive older than ' || b.archive_warn_minutes || ' min', coalesce(b.last_archived_wal, 'pg_stat_archiver'), b.archiver_read_at,
       coalesce('last archived ' || round(b.archive_age_s / 60) || ' min before the read', 'nothing archived since the stats reset')
       || '; ' || pg_size_pretty(b.archive_lag_bytes) || ' of WAL waiting'
  FROM pgvigil.backup_status b
 WHERE b.archiving AND b.wal_waiting AND b.platform <> 'aurora'
   AND (b.last_archived_time IS NULL OR b.archive_age_s > b.archive_warn_minutes * 60)
UNION ALL
SELECT b.instance_id, CASE WHEN r.crit_days IS NOT NULL AND b.retention_days <= r.crit_days THEN 'critical' ELSE 'warning' END,
       CASE WHEN r.warn_days IS NOT NULL THEN 'retention under ' || trim_scale(r.warn_days) || ' days'
            ELSE 'retention at or under ' || trim_scale(r.crit_days) || ' days' END, b.cloud_resource, b.cloud_read_at,
       CASE WHEN b.retention_days = 0 THEN 'automated backups are off (retention 0 days)'
            ELSE 'backup retention ' || b.retention_days || ' days' END
  FROM pgvigil.backup_status b JOIN pgvigil.backup_retention r USING (instance_id)
 WHERE ((r.warn_days IS NOT NULL AND b.retention_days < r.warn_days) OR (r.crit_days IS NOT NULL AND b.retention_days <= r.crit_days))
   AND NOT (b.platform = 'rds' AND coalesce(b.is_replica, false) AND b.retention_days = 0)
   AND b.cluster_backups_on IS NULL
UNION ALL
SELECT b.instance_id, 'warning', 'no snapshot in 24 h', b.cloud_resource, b.cloud_read_at,
       coalesce('newest snapshot ' || to_char(b.newest_snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC, '
                || round(b.newest_snapshot_age_s / 3600) || ' h before the read', 'no available snapshot listed')
  FROM pgvigil.backup_status b
 WHERE b.cloud_resource IS NOT NULL AND (b.newest_snapshot_at IS NULL OR b.newest_snapshot_age_s > 86400)
   AND NOT (b.platform = 'rds' AND coalesce(b.is_replica, false) AND b.retention_days = 0)
   AND b.cluster_backups_on IS NULL;

-- ---- task 401 (0152, B3): the SQL Server counters --------------------------------------------------------------------
-- mssql_cpu_newest is 0124's with its Workload Group Stats taken from the instance counter read nearest the scheduler
-- read (the counters are mssql_counters' own read since 401: an exact match on mssql_cpu's read time would never find
-- them). metric_catalog and metric_points with the family 'counters' are 0300's (the j16 join file: no j16 hunk of an
-- object 0300 re-creates goes into an earlier file).

CREATE OR REPLACE FUNCTION pgvigil.mssql_cpu_newest(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (snapshot_at timestamptz, schedulers int, cpu_count int, runnable_tasks int, work_queue int, current_workers int,
               active_workers int, max_workers int, offline_cpus int, nodes_total int, nodes_online int,
               level text, verdict text, pm_level text, pm_recommendation text,
               rg_active_requests bigint, rg_queued_requests bigint, rg_blocked_tasks bigint, rg_parallel_threads bigint,
               requests_at timestamptz, requests bigint, runnable_requests bigint, runnable_pct numeric,
               threadpool_at timestamptz, threadpool int, threadpool_longest_ms bigint, cpu_info jsonb)
LANGUAGE sql STABLE AS $$
  WITH s AS (SELECT * FROM pgvigil.mssql_sched_sample x WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
              ORDER BY x.snapshot_at DESC LIMIT 1),
  -- task 401: the counters are mssql_counters' own read now (not mssql_cpu's): the instance counter read nearest the
  -- scheduler read within 30 s, as rq and tp take theirs
  cr AS (SELECT c.snapshot_at FROM s, pgvigil.mssql_counter_read c
          WHERE c.instance_id = p_instance_id AND c.scope = 'instance'
            AND c.snapshot_at BETWEEN s.snapshot_at - interval '30 seconds' AND s.snapshot_at + interval '30 seconds'
          ORDER BY abs(extract(epoch FROM c.snapshot_at - s.snapshot_at)) LIMIT 1),
  wg AS (SELECT sum(c.value) FILTER (WHERE k.counter = 'Active requests') AS act, sum(c.value) FILTER (WHERE k.counter = 'Queued requests') AS q,
                sum(c.value) FILTER (WHERE k.counter = 'Blocked tasks') AS blk, sum(c.value) FILTER (WHERE k.counter = 'Active parallel threads') AS par
           FROM cr JOIN pgvigil.mssql_counter_sample c ON c.instance_id = p_instance_id AND c.snapshot_at = cr.snapshot_at
           JOIN pgvigil.mssql_counter_series k ON k.series_id = c.series_id AND k.object = 'Workload Group Stats'),
  rq AS (SELECT q.snapshot_at FROM s, pgvigil.mssql_requests_summary q
          WHERE q.instance_id = p_instance_id AND q.snapshot_at BETWEEN s.snapshot_at - interval '30 seconds' AND s.snapshot_at + interval '30 seconds'
          ORDER BY abs(extract(epoch FROM q.snapshot_at - s.snapshot_at)) LIMIT 1),
  rc AS (SELECT count(*) AS n, count(*) FILTER (WHERE r.status = 'runnable') AS runnable
           FROM rq JOIN pgvigil.mssql_requests r ON r.instance_id = p_instance_id AND r.snapshot_at = rq.snapshot_at
          WHERE r.session_id > 50 AND coalesce(r.status, '') NOT IN ('background', 'sleeping')),
  tp AS (SELECT w.snapshot_at, w.threadpool, w.threadpool_longest_ms FROM s, pgvigil.mssql_waiting_summary w
          WHERE w.instance_id = p_instance_id AND w.snapshot_at BETWEEN s.snapshot_at - interval '30 seconds' AND s.snapshot_at + interval '30 seconds'
          ORDER BY abs(extract(epoch FROM w.snapshot_at - s.snapshot_at)) LIMIT 1)
  SELECT s.snapshot_at, s.schedulers, s.cpu_count, s.runnable_tasks, s.work_queue, s.current_workers, s.active_workers, s.max_workers,
         s.offline_cpus, s.nodes_total, s.nodes_online, l.level, l.verdict, l.pm_level, l.pm_recommendation,
         wg.act, wg.q, wg.blk, wg.par,
         rq.snapshot_at, rc.n, rc.runnable, CASE WHEN rc.n > 0 THEN round(100.0 * rc.runnable / rc.n, 2) END,
         tp.snapshot_at, tp.threadpool, tp.threadpool_longest_ms,
         (SELECT i.info FROM pgvigil.mssql_cpu_info i WHERE i.instance_id = p_instance_id)
    FROM s
    LEFT JOIN wg ON true LEFT JOIN rq ON true LEFT JOIN rc ON rq.snapshot_at IS NOT NULL LEFT JOIN tp ON true
    CROSS JOIN LATERAL pgvigil.mssql_sched_levels(s.runnable_tasks, s.schedulers, s.work_queue, s.current_workers, s.max_workers,
                                                  s.cpu_count, wg.q::int) l
$$;
