-- 0038: the wave A join for the extensions (0019) and versions (0035) collections. The findings view gains the
-- extension rules (outdated, pg_stat_statements not preloaded or absent, pg_hint_plan created but not preloaded,
-- auto_explain at 0 ms, and the rest) and the version rules (a deprecated engine version, maintenance AWS applies
-- on its own or that waits undated, a changed collation version; the end-of-life and minors-behind readings come
-- from the release table through the Versions API and the Summary's Version cell, not this view); purge() gains the
-- rows of extensions, settings, pending actions and collations no longer present (the three change logs
-- extension_history, instance_setting_history and version_history stay whole: one row per real change; neither
-- migration partitions a table). Both bodies are 0037's with the additions (a frozen file is never edited; a later join re-creates
-- them again with its own).

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
                         'vacuum_sample')
       AND c.relname ~ '_[0-9]{6}$'
       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)
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
  RETURN n;
END $$;
