-- REMOTE's join draft: scripts/REMOTE-join-lines.sql lines 1-3 applied to their objects as 0300 (rel-j16-joinfix 9594d9f4)
-- defines them, for the proofs only (never `pgvigil migrate`: scripts/ is not embedded). Each object is 0300's text whole
-- with its REMOTE line marked; the join re-creates them with these lines in place. Apply after 0329.

CREATE OR REPLACE VIEW pgvigil.findings AS
SELECT DISTINCT ON (x.instance_id, x.setting, x.value, x.detail) x.*
  FROM (
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at
      FROM pgvigil.setting_rules WHERE hit
    UNION ALL
    -- task 201 (0121): the collector's own findings; instance_id NULL for the repository-wide ones
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.collector_findings
    -- [#8 KITWATCH 32460ec2]
    UNION ALL
    -- KITWATCH (0253): the collector's sp_WhoIsActive call seen - unusable (warning) or failing (info)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.kit_findings
    -- [#9 B24e f6f83845]
    UNION ALL
    -- [#12 the join 0300 --------]
    -- B24e (0192): a password secret the collector could not read or the server refused - its own view, so the
    -- Collector page reads it by name
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.collector_secret_findings
    -- [#10 B24H-STREAKS c937e891]
    UNION ALL
    -- B24h (0254): the probe's findings (b24h-join-lines.sql line 1)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.collector_probe_findings
    -- [#5 B6G-N 17e6d3f7]
    UNION ALL
    -- B6.4 (0166, WIRING): pgvigil's own health - a collection that runs long, the alert sender idle (shown, never sent:
    -- alert_findings below leaves it out), the repository's autovacuum behind
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.collection_runs_long_findings
    UNION ALL
    -- B6.4 #4 (0166, WIRING): a collector host whose runs run long, one alert for its instances (its members held)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.collection_runs_long_fold
    UNION ALL
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.alert_sender_idle_findings
    UNION ALL
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.repository_autovacuum_findings
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
    -- [#2 S2 09661906]
    -- task 411 (0162): an optional capture's session stopped
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_xe_captures', at FROM pgvigil.mssql_xe_captures_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_waiting', at FROM pgvigil.mssql_waiting_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_hadr', at FROM pgvigil.mssql_hadr_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_jobs', at FROM pgvigil.mssql_jobs_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_storage', at FROM pgvigil.mssql_storage_findings
    UNION ALL
    -- [#4 409-410 03f74d79]
    -- task 407 (0158): storage depth - days until a volume is full, tempdb filling, dbachecks' file and path rules
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_storage_depth', at FROM pgvigil.mssql_storage_depth_findings
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
    -- [#1 S2 09661906]
    -- task 408 (0159): the SQL Server security rules in force that hit
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_security', at FROM pgvigil.mssql_security_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_plancache', at FROM pgvigil.mssql_plancache_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_indexes', at FROM pgvigil.mssql_indexes_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_stats', at FROM pgvigil.mssql_stats_findings
    UNION ALL
    -- [#11 409-410 03f74d79]
    -- (task 409: mssql_checks_findings leaves out a server option an expected value judges; 0190's mssql_checks_findings)
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_checks', at FROM pgvigil.mssql_checks_findings
    -- [#4 409-410 03f74d79]
    UNION ALL
    -- task 409 (0160): the configuration checks against the expected values
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_config_checks', at FROM pgvigil.mssql_config_check_findings
    UNION ALL
    -- task 410 (0161): Ola Hallengren's maintenance solution, its jobs, its history, data purity
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_maintenance', at FROM pgvigil.mssql_maintenance_findings
    UNION ALL
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_readers', at FROM pgvigil.mssql_readers_findings
    UNION ALL
    -- task 162 (0103): base backups, log shipping, crash restarts, the statement store, amcheck age
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pg_backups_findings
    UNION ALL
    -- [#7 INV(302) 4c155a56]
    -- task 302 (0148): a credential in the archiver's command, WAL discarded (warnings); the tool read off and 162's
    -- base backups not read (info: the Summary's Backup FULL cell maps 'base backups not read' to grey, never green)
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'backup_dest', at FROM pgvigil.pg_backup_dest_findings
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
    -- [#6 INV(301b) 4c155a56]
    -- task 301b (0191): a backup file not where msdb says, pseudo-simple, the default backup path not reachable
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_backup_check', at FROM pgvigil.mssql_backup_check_findings
    UNION ALL
    -- task 304 (0147): the log chain is broken (never for a gap a replica's late read may fill)
    SELECT instance_id, severity, check_name, object, NULL::boolean, NULL::text, NULL::text, detail, 'mssql_restore_chain', at FROM pgvigil.mssql_restore_findings
    -- [#3 404 1cb5f703]
    UNION ALL
    -- task 404 (0155): a restart, a failover, a crash restart or a build change in the last 24 hours (info)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.restart_findings
    -- REMOTE line 1 (0329): a remote site, and each of its instances, gone quiet past 2 x expected_every
    UNION ALL
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.remote_silence_findings
  ) x
 ORDER BY x.instance_id, x.setting, x.value, x.detail;

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
  -- [#2 B6G-N 17e6d3f7]
  ), long_held AS MATERIALIZED (   -- B6.4 #4 (0166, WIRING): the members of a standing 'collections run long' fold, the
    -- collections that run long on its host (B6f7 #6) and the severity at or under which their own 'collection runs long'
    -- of those is held
    SELECT instance_id, collection, severity FROM pgvigil.collection_runs_long_held
  ), long_forming AS MATERIALIZED (  -- B6f7 #2 (0166, WIRING): 3 or more of a host's instances long within its span and
    -- a minute: new ones wait
    SELECT DISTINCT instance_id FROM pgvigil.collection_runs_long_forming
  -- [#3 B24H-STREAKS c937e891]
  ), probe_state AS MATERIALIZED (   -- B24h line 3: the judged instances and their collector's fold, read ONCE a pass
    -- (the review of the fold #1; #b4's attempt 3: collector_probe_state reads the judged view once)
    SELECT collector_host, instance_id, host, ping_slow, not_answering, folded, host_crossed, crossed_hosts FROM pgvigil.collector_probe_state
  ), probe_held AS MATERIALIZED (     -- B24h line 3: as collector_probe_held, from the one read
    SELECT p.instance_id || E'\x1f' || s.setting AS k
      FROM probe_state p CROSS JOIN (VALUES ('query round trip slow'), ('ping slow'), ('host not answering ping')) s(setting)
     WHERE p.folded OR (s.setting = 'ping slow' AND p.ping_slow) OR (s.setting = 'host not answering ping' AND p.not_answering)
  ), probe_held_hosts AS MATERIALIZED (   -- B24h line 3: as collector_probe_held_hosts; and the hosts of instances held
    -- under 'collector or network' (the B24h-1 review part b #2: a host row has no instance id)
    SELECT host FROM probe_state WHERE folded
    UNION SELECT host FROM probe_state WHERE instance_id IN (SELECT instance_id FROM held)
  ), probe_under_slow AS MATERIALIZED (   -- B24h line 3: instances judged from a collector whose slow-connect host fold
    -- stands (kind 'host': its value is the collector host)
    SELECT instance_id FROM probe_state WHERE collector_host IN (SELECT value FROM slow_folds WHERE kind = 'host')
  ), probe_forming AS MATERIALIZED (  -- B24h line 3: 3 or more of a collector's instances crossed a slow round trip
    SELECT instance_id FROM pgvigil.collector_probe_forming
  ), probe_forming_hosts AS MATERIALIZED (   -- B24h line 3: as collector_probe_forming_hosts, from the one read
    SELECT host FROM probe_state WHERE host_crossed AND crossed_hosts >= 3
  ), probe_parents AS MATERIALIZED (   -- B24h line 3: the collector hosts whose 'collector or network' stands for the
    -- collector itself - not seen, or its instances failing together (the review of F9 #1: a 'server not answering'
    -- parent is one server's; the collector still probes the rest, and its fold is news)
    SELECT host FROM pgvigil.collector_parent WHERE why IN ('collector not seen', 'instances failing together')
  ), probe_stopped AS MATERIALIZED (   -- B24h line 3: the collector hosts not seen - their probes stopped with them (the
    -- resolve guards: a host was not seen to recover; the review of F9 #1)
    SELECT host FROM pgvigil.collector_parent WHERE why = 'collector not seen'
  ), ch AS (
    SELECT c.name, pgvigil.severity_rank(c.min_severity) AS floor, coalesce(c.instances, '{}') AS instances,
           coalesce(c.tags, '{}') AS tags, coalesce(c.repeat_secs, 0) AS repeat_secs,
           coalesce(c.clear_after_secs, 600) AS clear_after_secs, coalesce(c.recovery, true) AS recovery,
           coalesce(c.repo_wide, true) AS repo_wide,
           -- [#1 S2 09661906]
           coalesce(c.checks, '{}') AS checks, coalesce(c.digest, false) AS digest   -- task 403a (0154: A31, the digest hold)
      FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
           AS c(name text, min_severity text, instances text[], tags text[], repeat_secs int, clear_after_secs int, recovery boolean,
                -- [#1 S2 09661906]
                repo_wide boolean, checks text[], digest boolean)
  -- [#3 B24H-STREAKS c937e891]
  ), af AS MATERIALIZED (   -- B24h line 3 (the review of F9 #3): alert_findings read ONCE a pass - line 1 puts the
    -- judged rows in it, and 0190's form read it twice (sc, and s's EXISTS once alerts are open)
    SELECT * FROM pgvigil.alert_findings
  ), sc AS (   -- every finding in a channel's scope, any severity (a repository-wide one: every channel but a route's,
               -- task 310 - an application contact's route says repo_wide false)
    -- [#1 S2 09661906]
    SELECT DISTINCT ON (ch.name, f.finding_key) ch.name AS channel, ch.floor, ch.clear_after_secs AS ch_clear_after,
           coalesce(ch.digest, false) AS ch_digest, f.*
      -- [#3 B24H-STREAKS c937e891]
      FROM ch JOIN af f   -- B24h line 3: the one read (was pgvigil.alert_findings)
        -- [#1 S2 09661906]
        ON (pgvigil.alert_in_scope(f.instance, f.tags, ch.instances, ch.tags) OR (f.source = 'pgvigil repository' AND ch.repo_wide))
       AND pgvigil.alert_checks_match(ch.checks, f.source, f.setting)   -- task 403a: a channel's checks: list (A31, 0154)
     ORDER BY ch.name, f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC
  ), m AS (    -- the ones at or above its floor that nothing holds
    SELECT * FROM sc WHERE pgvigil.severity_rank(sc.severity) >= sc.floor
       -- [#1 S2 09661906]
       AND pgvigil.alert_hold(p_at, sc.channel, sc.instance, sc.tags, sc.finding_key, sc.source, sc.setting, sc.value,
                              sc.severity, sc.ch_clear_after, sc.ch_digest) IS NULL   -- task 403a: every hold (0154), acks first
       AND NOT (pgvigil.collector_shared_cause(sc.source, sc.setting)
                AND EXISTS (SELECT 1 FROM held WHERE held.instance_id = sc.instance_id))
       AND NOT (sc.source = 'pgvigil collector' AND sc.setting = 'slow connect'
                AND EXISTS (SELECT 1 FROM slow_held WHERE slow_held.instance_id = sc.instance_id))
       -- [#2 B6G-N 17e6d3f7]
       AND NOT (sc.source = 'pgvigil collector' AND sc.setting = 'collection runs long'
                AND EXISTS (SELECT 1 FROM long_held WHERE long_held.instance_id = sc.instance_id AND long_held.collection = sc.value
                               AND pgvigil.severity_rank(sc.severity) <= pgvigil.severity_rank(long_held.severity)))
       AND NOT (sc.source = 'pgvigil repository' AND sc.setting = 'slow connects'
                AND EXISTS (SELECT 1 FROM slow_under WHERE slow_under.value = sc.value))
       -- [#3 B24H-STREAKS c937e891]
       -- B24h line 3: an instance's probe finding while probe_held names it (under its collector's fold, or its ping rows
       -- under its host's row) or it is judged from a collector under slow-connect's host fold; a host's row while a
       -- standing fold holds the host or its instances are held under 'collector or network'; B24h's fold while its
       -- collector's parent or slow-connect's host fold stands (one alert, not three: part b #8). Each an uncorrelated IN
       -- on a CTE (hashed once a pass: the review of the fold #1), never a correlated EXISTS per row
       AND NOT (sc.source = 'pgvigil collector' AND sc.setting IN ('query round trip slow', 'ping slow', 'host not answering ping')
                AND (sc.instance_id || E'\x1f' || sc.setting IN (SELECT k FROM probe_held)
                     OR sc.instance_id IN (SELECT instance_id FROM probe_under_slow)))
       AND NOT (sc.source = 'pgvigil repository' AND sc.setting IN ('ping slow', 'host not answering ping')
                AND sc.value IN (SELECT host FROM probe_held_hosts))
       AND NOT (sc.source = 'pgvigil repository' AND sc.setting = 'network slow from this collector'
                AND (sc.value IN (SELECT host FROM probe_parents) OR sc.value IN (SELECT value FROM slow_folds WHERE kind = 'host')))
  ), s AS (
    -- REMOTE line 2 (0329): an instance a site owns clears no sooner than its bundle interval + its site's expected_every
    SELECT st.*, ch.repeat_secs, ch.recovery,
           greatest(ch.clear_after_secs, coalesce((SELECT r.interval_secs + r.expected_every_secs FROM pgvigil.remote_instance_state r
                                                   WHERE r.instance_id = st.instance_id), 0)) AS clear_after_secs,
           (i.is_active IS TRUE OR st.source = 'pgvigil repository') AS instance_active,
           -- [#3 B24H-STREAKS c937e891]
           -- B24h line 3: on the one read, hashed (was EXISTS on pgvigil.alert_findings per open alert)
           st.finding_key IN (SELECT af.finding_key FROM af WHERE af.finding_key IS NOT NULL) AS present
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
                   -- [#2 B6G-N 17e6d3f7]
                   AND NOT (m.source = 'pgvigil collector' AND m.setting = 'collection runs long'
                            AND EXISTS (SELECT 1 FROM long_forming WHERE long_forming.instance_id = m.instance_id))
                   -- [#3 B24H-STREAKS c937e891]
                   -- B24h line 3: a new round trip or host ping row waits while B24h's fold may be forming (part b #5,
                   -- the review of the fold #4: the host row is the ping alert sent)
                   AND NOT (m.source = 'pgvigil collector' AND m.setting = 'query round trip slow'
                            AND m.instance_id IN (SELECT instance_id FROM probe_forming))
                   AND NOT (m.source = 'pgvigil repository' AND m.setting = 'ping slow'
                            AND m.value IN (SELECT host FROM probe_forming_hosts))
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
     -- [#2 B6G-N 17e6d3f7]
     -- connects stopped being judged because it stopped, not because they got faster); its 'collections run long' alike
     -- (B6.4 #4: its runs stopped being judged, they did not get shorter)
     AND NOT (s.source = 'pgvigil repository' AND s.setting IN ('slow connects', 'collections run long')
              AND EXISTS (SELECT 1 FROM pgvigil.collector_parent p WHERE p.host = s.value))
     -- [#3 B24H-STREAKS c937e891]
     -- B24h line 3: B24h's fold, and a host's rows of a collector whose parent stands, are not 'resolved' (part b #2,
     -- the review of the fold #3: the probes stopped with the collector, the host was not seen to recover)
     AND NOT (s.source = 'pgvigil repository' AND s.setting = 'network slow from this collector'
              AND s.value IN (SELECT host FROM probe_stopped))
     AND NOT (s.source = 'pgvigil repository' AND s.setting IN ('ping slow', 'host not answering ping')
              AND s.value IN (SELECT ph.host FROM pgvigil.collector_probe_host ph JOIN pgvigil.collector_heartbeat h USING (collector_id)
                               WHERE h.host IN (SELECT host FROM probe_stopped)))
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
                         -- [#12 the join 0300 --------]
                         'mssql_database_space', 'mssql_table_sample',   -- task 407, 0158
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
                         'mssql_logrestore_sample',
                         -- [#2 413 7184f8ea]
                         'mssql_index_usage_read',
                         -- [#3 413 7184f8ea]
                         'mssql_session_count', 'mssql_session_by',
                         -- [#4 S2 09661906]
                         'findings_history',
                         -- [#13 the join 0300 --------]
                         -- 0151 and 0162 leave their retention to the join: geo-replication's and the provider replicas'
                         -- samples, the optional captures' waits and modules - by month with the rest
                         'mssql_georepl_sample', 'cloud_replica_sample', 'mssql_xe_waits', 'mssql_xe_modules')
       -- [#8 N4 280368a5]
       -- a name ending in a month (YYYYMM), parsed inside a CASE: the server may test these conditions on every pg_class
       -- row before the join, in any order, and a TOAST table pg_toast_<six digits> ending in no month (a database past
       -- OID 100,000) failed the whole purge with 22008 (proof-purge's OID row)
       AND c.relname ~ '_[0-9]{4}(0[1-9]|1[0-2])$'
       AND (CASE WHEN c.relname ~ '_[0-9]{4}(0[1-9]|1[0-2])$' THEN to_date(right(c.relname, 6) || '01', 'YYYYMMDD') END
            + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days =>
             -- task 403a: the alert log and the findings history are kept 90 days at least (PM Added 20's three months)
             -- [#4 S2 09661906]
             CASE p.relname WHEN 'alert_log' THEN greatest(p_days, 90)
                            WHEN 'findings_history' THEN greatest(p_days, pgvigil.findings_history_days()) ELSE p_days END)
     -- by parent, then partition: the order the imports take their parents in (a DROP takes the partition, then
     -- ACCESS EXCLUSIVE on its parent)
     ORDER BY p.relname, c.relname
  LOOP
    EXECUTE format('DROP TABLE pgvigil.%I', v_part.relname);
    v_dropped := v_dropped || v_part.relname::text;
    n := n + 1;
  END LOOP;
  -- [#13 the join 0300 --------]
  -- 0151: geo-replication's and the provider replicas' events past the history's window; the provider failover
  -- events 14 days, RDS's own keep and the window 0151's read looks back over
  DELETE FROM pgvigil.mssql_georepl_events WHERE at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_failover_group_events WHERE at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.cloud_replica_events WHERE at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.cloud_failover_events WHERE at < now() - interval '14 days';
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- 0162: the optional captures' warning tables past the window, as an event table
  DELETE FROM pgvigil.mssql_xe_warning_samples WHERE hour_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_xe_warning_keys WHERE hour_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_xe_warning_hours WHERE hour_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_xe_warning_counts WHERE snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.job_runs WHERE start_time < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- [#4 S2 09661906]
  n := n + pgvigil.alert_threads_purge();   -- task 403b K2 (0154): the Slack bot's threads of closed occurrences, after 90 days
  -- [#6 404 1cb5f703]
  -- task 404 (0155): restarts and build changes keep 365 days, the longest chart range, whatever p_days says
  DELETE FROM pgvigil.instance_events WHERE at < now() - interval '365 days';
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
  -- [#7 409-410 03f74d79]
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- task 407 (0158): SQL Server tables and fixed drives no longer present, for longer than the retention
  DELETE FROM pgvigil.mssql_tables WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_fixed_drives WHERE NOT is_present AND snapshot_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- task 410 (0161): Ola's CommandLog rows started before the retention
  DELETE FROM pgvigil.mssql_ola_commandlog WHERE start_at < now() - make_interval(days => p_days);
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
  -- [#2 413 7184f8ea]
  n := n + pgvigil.mssql_index_depth_purge(p_days);   -- task 414 (0164)
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
  -- [#5 402 0d029a1a]
  -- task 402 (0153, B24 Fixed 1): the attention capture's reads, a plain table (no partition is made inside 0065's import)
  DELETE FROM pgvigil.mssql_attention_reads WHERE snapshot_at < now() - make_interval(days => p_days);
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
  -- [#9 B24H-STREAKS c937e891]
  -- B24h (0254): a retired collector's collector_probe_host rows, with its heartbeat row (collector_probe's 8 days are
  -- import_collector_probe's own trim)
  DELETE FROM pgvigil.collector_probe_host ph WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat h WHERE h.collector_id = ph.collector_id);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  -- [#10 81-AGENT 654a9cd5]
  -- the agent door (0268): requests that ended more than 90 days after they were asked (an open or claimed one
  -- never; the journal and the texts go with them through ON DELETE CASCADE)
  PERFORM pgvigil.investigations_purge(90);
  -- [#11 CQ-A 322675cc]
  -- 0200 (CQ): the request queue's read kinds after 7 days (a read's result is cleared within the hour by the sweep;
  -- the row's ask and end go with it), and a refused ask of any kind after 7 days (nothing ran: a requester must not
  -- grow the table without bound); the action kinds that ran are an audit, kept whole as actions_log is; a worker
  -- stopped or silent for 8 days goes with its doors and tool lists
  DELETE FROM pgvigil.action_requests WHERE (class <> 'action' OR state = 'refused') AND state NOT IN ('waiting', 'running')
     AND asked_at < now() - interval '7 days';
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.cq_workers WHERE coalesce(beat_at, stopped_at, started_at) < now() - interval '8 days';
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
  -- [#1 B2a-N2 8aecbb2b]
  -- B2a-N2 (0167): the Azure SQL Database hours by their own age (its heals and the month ahead are 'pgvigil purge''s,
  -- after this: AzureDBHourMonths, AzureDBHoursHeal)
  IF to_regprocedure('pgvigil.mssql_azuredb_hour_purge()') IS NOT NULL THEN
    n := n - cardinality(v_dropped);
    v_dropped := v_dropped || pgvigil.mssql_azuredb_hour_purge();
    n := n + cardinality(v_dropped);
  END IF;
  -- [#13 the join 0300 --------]
  -- 0151: geo-replication's and the provider replicas' hours by their own age (hour_purge_0151, hours_retention);
  -- a pending key is rebuilt by its next import (0151's rollup)
  IF to_regprocedure('pgvigil.cloud_replica_hour_purge()') IS NOT NULL THEN
    n := n - cardinality(v_dropped);
    v_dropped := v_dropped || pgvigil.cloud_replica_hour_purge();
    n := n + cardinality(v_dropped);
  END IF;
  IF to_regprocedure('pgvigil.mssql_georepl_hour_purge()') IS NOT NULL THEN
    n := n - cardinality(v_dropped);
    v_dropped := v_dropped || pgvigil.mssql_georepl_hour_purge();
    n := n + cardinality(v_dropped);
  END IF;
  -- REMOTE line 3 (0329): the remote ledgers past 90 days (each stream's high-water and an uncleared mark kept)
  IF to_regprocedure('pgvigil.remote_purge(integer)') IS NOT NULL THEN
    n := n + pgvigil.remote_purge(90);
  END IF;
  -- task 201: the run recorded (the Collector page's last purge, the 'purge not run in 2 days' finding)
  INSERT INTO pgvigil.purge_runs (started_at, finished_at, days, partitions_dropped, rows_deleted, total)
  VALUES (v_started, clock_timestamp(), p_days, v_dropped, n - cardinality(v_dropped), n);
  RETURN n;
END $$;

-- pgvigil.apply_roles: 0300's, whole, with REMOTE line 4 (the ingest door), then run so the grants take
CREATE OR REPLACE FUNCTION pgvigil.apply_roles()
 RETURNS void
 LANGUAGE plpgsql
AS $$
DECLARE
  f record;
  t record;
BEGIN
  REVOKE ALL ON SCHEMA pgvigil FROM PUBLIC;
  -- REMOTE line 4 (0329): pgvigil_ingest's USAGE beside the others
  GRANT USAGE ON SCHEMA pgvigil TO pgvigil_collector, pgvigil_reader, pgvigil_auth, pgvigil_ingest;

  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgvigil'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF f.proname IN ('remote_site_sync', 'remote_sites_retire', 'remote_ensure_instance', 'remote_seen', 'remote_newest',
                     'remote_recorded', 'remote_retries', 'remote_retry', 'remote_bundle_begin', 'remote_batch',
                     'remote_bundle_done', 'remote_mark', 'remote_purge') THEN
      -- REMOTE line 4 (0329): the ingest door - runs as the owner, pgvigil_ingest's alone (never the collector's, never the reader's)
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM pgvigil_reader, pgvigil_collector', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_ingest', f.sig);
    ELSIF f.proname LIKE 'import\_%' OR f.proname IN ('ensure_instance', 'log_collection', 'schema_latest', 'schema_missing', 'log_cursor', 'mssql_hadr_cursor') THEN
      -- the collector's door: runs as the owner, sees only its arguments
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_collector', f.sig);
    ELSIF f.proname LIKE 'ui\_%' THEN
      -- the UI login's door: one named user's hash and the user count, never the table
      EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM pgvigil_reader', f.sig);
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_auth', f.sig);
    ELSIF f.proname IN ('apply_roles', 'purge', 'ensure_month_partition', 'mssql_running_purge', 'mssql_ensure_day_partition',
                        'mssql_event_partition', 'mssql_hadr_read', 'mssql_reads_purge', 'mssql_plancache_purge', 'mssql_errorlog_search_set',
                        -- task 406, 0157: they delete or write for the imports, and the reader never calls them
                        'mssql_qs_plans_purge', 'mssql_plan_stats_store', 'mssql_plans_policy_drop',
                        -- [#6 the join 0300 --------]
                        -- B2a-N2, 0167: the Azure SQL Database hours' writers - the import's trigger and 'pgvigil purge' run them as the owner
                        -- [#1 B2a-N2 8aecbb2b]
                        'mssql_azuredb_hour_partition', 'mssql_azuredb_hour_recompute', 'mssql_azuredb_hour_rebuild', 'mssql_azuredb_hour_heal',
                        'mssql_azuredb_hour_failed', 'mssql_azuredb_hour_pending', 'mssql_azuredb_hour_heal_one', 'mssql_azuredb_hour_tg',
                        'mssql_azuredb_hour_purge',
                        -- [#2 413 7184f8ea]
                        'mssql_index_depth_purge', 'mssql_fragmentation_stale',
                        -- [#6 the join 0300 --------]
                        -- the Parquet export, 0256: the exporter's door, not the reader's
                        -- [#3 PARQUET 16659e64]
                        'export_run_record', 'export_off',
                        -- [#6 the join 0300 --------]
                        -- the agent door, 0268: the agent's functions, not the reader's
                        -- [#4 81-AGENT 654a9cd5]
                        'agent_investigation_list', 'agent_investigation_claim', 'agent_investigation_renew', 'agent_investigation_release',
                        'agent_investigation_report', 'agent_investigation_journal_select', 'agent_investigation_journal_done',
                        'investigations_purge', 'investigations_settle', 'investigation_journal_add', 'agent_claim_row',
                        -- [#6 the join 0300 --------]
                        -- 403a, 0154: the history's month partition, made as the owner for the alert sender, which keeps
                        -- 0154's own grant - this branch takes back only the reader's
                        'findings_history_partition') THEN
      -- owner only; a grant an earlier run of this function gave the reader (the name was not on the list then) is taken back
      EXECUTE format('REVOKE ALL ON FUNCTION %s FROM pgvigil_reader', f.sig);
    ELSE
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_reader', f.sig);
    END IF;
  END LOOP;
-- [#3 PARQUET 16659e64]

  -- the Parquet export (0256): its two functions are the exporter's (parquet-join-lines.sql 1)
  GRANT EXECUTE ON FUNCTION pgvigil.export_run_record(text, text, timestamptz, timestamptz, text, timestamptz, text, int, int, bigint, bigint, text) TO pgvigil_exporter;
  GRANT EXECUTE ON FUNCTION pgvigil.export_off(text) TO pgvigil_exporter;
-- [#4 81-AGENT 654a9cd5]

  -- the agent door (0268): the seven agent_investigation_* are the agent's (0268's own GRANT, kept; agent-join-lines.sql 1)
  GRANT EXECUTE ON FUNCTION pgvigil.agent_investigation_list(text, text, int), pgvigil.agent_investigation_claim(bigint, text),
    pgvigil.agent_investigation_renew(bigint, text), pgvigil.agent_investigation_release(bigint, text, text),
    pgvigil.agent_investigation_report(bigint, text, text, text, text, jsonb, jsonb, text),
    pgvigil.agent_investigation_journal_select(bigint, text, text),
    pgvigil.agent_investigation_journal_done(bigint, bigint, int, text) TO pgvigil_agent;

  -- [#5 81-AGENT 654a9cd5]
  -- the agent door x the request queue (0268 x 0200): a queue-mode serve writes the asks through pgvigil_requester
  -- (agent-join-lines.sql 3); apply_roles revokes a function's grants only from PUBLIC and the reader, so this grant stands
  GRANT EXECUTE ON FUNCTION pgvigil.import_investigation_request(timestamptz, jsonb),
    pgvigil.import_investigation_event(timestamptz, jsonb) TO pgvigil_requester;

  FOR t IN
    SELECT c.oid::regclass AS rel, c.relname
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'p', 'v')
  LOOP
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, pgvigil_collector, pgvigil_auth', t.rel);
    IF t.relname LIKE 'ui\_%' THEN
      EXECUTE format('REVOKE ALL ON %s FROM pgvigil_reader', t.rel);
    ELSE
      EXECUTE format('GRANT SELECT ON %s TO pgvigil_reader', t.rel);
    END IF;
  END LOOP;
END $$;
SELECT pgvigil.apply_roles();
