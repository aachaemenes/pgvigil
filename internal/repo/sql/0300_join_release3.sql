-- 0300 the third join file of the release (v0.4.0): each object that two or more slices change, re-created WHOLE here,
-- after every slice migration. The rule of a join file: no slice's change of an object this file re-creates goes into
-- 0085 or an earlier join file (0110, 0190); it arrives here as an arm (a slice's own file may create the object first:
-- this file runs after every one, so its text is the one that stays). Base: each object's text at 40762a29. Each object =
-- the base's effective text, then every writer's arm in order as a three-way merge (T a slice's tree, P its wiring
-- patch, D its draft) or a hand placement from its join-lines file (H); every line an arm brought is under its marker
-- '-- [#<n> <item> <sha>]', and the arm list heads each object; the table changes (#E) close the file. Migrate calls
-- apply_roles() after every file, this one too.

-- ====================================================================================================================
-- pgvigil.collector_shared_cause: base 0121_collector_health.sql L657
--   #1 T B6G-N 17e6d3f7: 0121_collector_health.sql L659 (merge-base e4af7c3e 0121_collector_health.sql) - in place (0121 / 0190)
--   #2 H B24H-STREAKS c937e891: scripts/b24h-join-lines.sql L9-11 (line 2) - the three probe settings join the collector's list (with B6G-N's collection runs long)
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.collector_shared_cause(p_source text, p_setting text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  -- [#1 B6G-N 17e6d3f7]
  -- B6.4 (WIRING): 'collection runs long' with the collector's own kinds - held while a parent stands for its instance (a
  -- cut or a host down slows the runs it does not fail); a host that is slow while its runs succeed forms no parent:
  -- its instances fold into ONE 'collections run long' of the host instead (0166 collection_runs_long_fold, B6.4 #4)
  SELECT coalesce((p_source = 'pgvigil collector' AND p_setting IN ('authentication failing', 'collection failing', 'server unreachable', 'slow connect',
                                                                    -- [#1 B6G-N 17e6d3f7]
                                                                    'collection runs long',
                                                                    -- [#2 B24H-STREAKS c937e891]
                                                                    -- B24h (0254): the probe's settings (b24h-join-lines.sql line 2)
                                                                    'query round trip slow', 'ping slow', 'host not answering ping'))
      OR (p_source = 'collector' AND p_setting = 'server unreachable')   -- 0118's (task 177 D30), where no heartbeat covers the instance
      OR (p_source = 'pgvigil' AND p_setting IN ('job run over twice its average', 'job schedule missed'))
      OR (p_source = 'mssql_jobs' AND p_setting = 'a job runs far longer than its average')
      OR (p_source = 'pg-backups' AND p_setting LIKE 'amcheck older than %')
      OR (p_source = 'pgvigil indexes' AND p_setting = 'unused index'), false)
$$;

-- ====================================================================================================================
-- pgvigil.alert_key: base 0121_collector_health.sql L702
--   #1 T B6G-N 17e6d3f7: 0121_collector_health.sql L708 (merge-base e4af7c3e 0121_collector_health.sql) - in place (0121 / 0190)
--   #2 H B24H-STREAKS c937e891: scripts/b24h-join-lines.sql L50-55 (line 7) - host-valued probe rows keep their host whole
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.alert_key(p_instance_id int, p_source text, p_setting text, p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  -- [#2 B24H-STREAKS c937e891]
  SELECT CASE WHEN p_instance_id IS NULL AND p_source = 'pgvigil repository' AND p_setting IN ('collector or network', 'slow connects', 'collections run long', 'ping slow', 'host not answering ping',
                                                                                       'network slow from this collector')
              THEN md5('0' || E'\x1f' || p_source || E'\x1f' || p_setting || E'\x1f' || coalesce(p_value, ''))
              ELSE pgvigil.alert_finding_key(coalesce(p_instance_id, 0), p_source, p_setting, p_value) END
$$;

-- ====================================================================================================================
-- pgvigil.collector_findings: base 0121_collector_health.sql L1142
--   #1 T B6G-N 17e6d3f7: 0121_collector_health.sql L1160 (merge-base e4af7c3e 0121_collector_health.sql) - in place (0121 / 0190)
--   #2 P N4 280368a5: 280368a5:scripts/n4-wiring.patch (0121_collector_health.sql hunks, pre blob 6ff25302)
--   #3 H B24H-STREAKS c937e891: scripts/b24h-join-lines.sql L41-49 (line 6) - the probe's newest answer ends 'server not answering' (the parent) and 'server unreachable'; the two placeholders filled by this pane: the collector host = collector_parent.host / collector_streaks_now.host, the instance's host = 0254's collector_instance_hosts
-- ====================================================================================================================
CREATE OR REPLACE VIEW pgvigil.collector_findings AS
-- the parent: its value is the host alone (one alert per collector, whatever its why: a restart inside the hold, or a
-- cut that turns into a host not seen, is the same alert, repeated once with its new why - alert_due); the claim
-- leads the detail (collector_claim reads it): the why, and for 'instances failing together' the start of the host's
-- newest event in UTC minutes (a new cut while one stands is one repeat; UTC: one session stores the claim, another
-- compares it)
SELECT NULL::int AS instance_id, 'critical'::text AS severity, 'collector or network'::text AS setting, p.host AS value,
       true AS is_set, 'the collector beating and its instances read'::text AS suggested, 'all'::text AS platforms,
       CASE WHEN p.why = 'server not answering' THEN 'server ' || p.server || ' not answering'
                 || coalesce(' from ' || to_char(p.event AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
            ELSE p.why || coalesce(' from ' || to_char(p.event AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
                 || coalesce(' on server ' || p.server, '') END || ': '
       || p.detail || '; the alerts of its instances not read since are held until this clears'
       || coalesce((SELECT '; it covers ' || count(*) || ' open alert(s): ' || string_agg(o.x, ', ' ORDER BY o.x)
                           -- N7: a forming wait that stopped before this parent rose sent these as they came - the
                           -- ones first sent from the wait's stop to the parent's own first send (nit 6), its time in UTC (nit 5)
                           || coalesce('; the forming wait had stopped at ' || to_char(st.at AT TIME ZONE 'UTC', 'HH24:MI') || ' UTC: '
                                       || count(*) FILTER (WHERE o.first_sent >= st.at AND o.first_sent < coalesce(ps.first, now())) || ' of these went out before this parent', '')
                      FROM (SELECT format('%s %s (%s)', a.instance_name, a.setting, a.value) AS x, min(a.first_sent_at) AS first_sent
                              FROM pgvigil.alert_state a
                             WHERE a.cleared_at IS NULL AND a.instance_id = ANY (p.instances)   -- held: collector_held_instances
                               AND pgvigil.collector_shared_cause(a.source, a.setting)
                             GROUP BY 1) o
                      CROSS JOIN (SELECT pgvigil.collector_forming_stopped(p.host, p.since) AS at) st
                      CROSS JOIN (SELECT min(s.first_sent_at) AS first FROM pgvigil.alert_state s
                                   WHERE s.cleared_at IS NULL AND s.source = 'pgvigil repository'
                                     AND s.setting = 'collector or network' AND s.value = p.host) ps
                    GROUP BY st.at, ps.first
                    -- [#3 B24H-STREAKS c937e891]
                    HAVING count(*) > 0), '')
       -- B24h line 6: a 'server not answering' parent ends with the probe's newest answer for its server's host (5 minutes;
       -- nothing when not probed)
       || CASE WHEN p.why = 'server not answering' THEN coalesce((SELECT CASE WHEN pr.answered > 0 THEN '; the host answers (tcp): the service is down, not the host'
                                  ELSE '; the host does not answer either (tcp): the host or the network' END
                        FROM pgvigil.collector_probe pr JOIN pgvigil.collector_heartbeat hb USING (collector_id)
                        JOIN pgvigil.collector_instance_hosts ih ON ih.collector_host = hb.host AND ih.host = pr.host
                       WHERE hb.host = p.host AND ih.instance_id = ANY (p.instances) AND pr.answered IS NOT NULL
                         AND pr.minute > now() - interval '5 minutes'
                       ORDER BY pr.minute DESC LIMIT 1), '') ELSE '' END AS detail,
       'pgvigil repository'::text AS source, p.since AS at
  FROM pgvigil.collector_parent p
UNION ALL
SELECT NULL::int, 'warning', 'purge not run in 2 days',
       CASE WHEN p.finished_at IS NULL THEN 'never' ELSE 'last ' || to_char(p.finished_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' END,
       true, 'pgvigil purge daily (the installer''s timer or a scheduled task)', 'all',
       'the repository keeps every row until purge() runs: it grows by the day', 'pgvigil repository',
       coalesce(p.finished_at, now())
  FROM (SELECT max(finished_at) AS finished_at FROM pgvigil.purge_runs) p
 WHERE (p.finished_at IS NULL OR p.finished_at < now() - interval '2 days')
   AND EXISTS (SELECT 1 FROM pgvigil.instances WHERE first_seen < now() - interval '2 days')
-- [#2 N4 280368a5]
UNION ALL
-- N4: next month's partitions missing in a month's last three days (UTC) - 0271's partitions_ahead_finding (the stub
-- above until 0271 gives it its body)
SELECT * FROM pgvigil.partitions_ahead_finding(now())
UNION ALL
SELECT s.instance_id, 'critical', 'collection failing', s.collection, true, 'the collection runs', 'all',
       format('%s runs in a row failed since %s: %s', s.fail_streak, s.failing_since, coalesce(s.last_error, 'no error text')),
       'pgvigil collector', s.last_run_at
  FROM pgvigil.collector_streaks_now s JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND s.collection <> '(connect)' AND s.fail_streak >= 3 AND s.last_run_at > now() - interval '1 day'
   -- [#1 B6G-N 17e6d3f7]
   AND NOT pgvigil.collection_dont_monitor(s.instance_id, s.collection)   -- B6g-2: Don't monitor (its Collection Health threshold)
   -- it stands during an outage too (the page shows it); alert_due (0190) decides the send: held while 'collector or
   -- network' stands, and after it one failed run past its window (collector_in_window)
   -- a streak speaks only while a beating collector still names the instance (collector_covers): only such a run ends
   -- it. An instance moved to a `pgvigil collect` on a schedule, or one whose collector died, leaves this view 20
   -- [#1 B6G-N 17e6d3f7]
   -- minutes after its last naming; the Summary's Collection Health column reads the scheduled collect's errors
   AND pgvigil.collector_covers(s.instance_id, now())
UNION ALL
-- the instance's own connect failing, the server not answering (not a refused login: that is 'authentication
-- failing'): 3 attempts in a row over a minute or more (heartbeat.go's '(connect)' streak); a run that fails there
-- builds no 'collection failing'
SELECT s.instance_id, 'critical', 'server unreachable', 'no connection', true, 'the server answering the collector', 'all',
       format('%s connection attempts in a row failed since %s: %s', s.fail_streak, s.failing_since, coalesce(s.last_error, 'no error text'))
       -- [#3 B24H-STREAKS c937e891]
       -- B24h line 6: the probe's newest answer for the instance's host from this collector (5 minutes; nothing when not probed)
       || coalesce((SELECT CASE WHEN pr.answered > 0 THEN '; the host answers (tcp): the service is down, not the host'
                                  ELSE '; the host does not answer either (tcp): the host or the network' END
                        FROM pgvigil.collector_probe pr JOIN pgvigil.collector_heartbeat hb USING (collector_id)
                        JOIN pgvigil.collector_instance_hosts ih ON ih.collector_host = hb.host AND ih.host = pr.host
                       WHERE hb.host = s.host AND ih.instance_id = s.instance_id AND pr.answered IS NOT NULL
                         AND pr.minute > now() - interval '5 minutes'
                       ORDER BY pr.minute DESC LIMIT 1), ''),
       'pgvigil collector', s.last_run_at
  FROM pgvigil.collector_streaks_now s JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND s.collection = '(connect)' AND s.fail_streak >= 3
   AND s.last_run_at - s.failing_since >= interval '60 seconds' AND s.last_run_at > now() - interval '1 day'
   -- while a beating collector names the instance (as 'collection failing'); past that 0118's own speaks for it (0190
   -- lets it through for a read no heartbeat covers): one finding for the server, never two. Its open alert is not
   -- resolved by leaving (0059 resolves on an ok read only); a move to a scheduled collect while it fails is announced
   -- again by 0118's (another source: the docs say it)
   AND pgvigil.collector_covers(s.instance_id, now())
UNION ALL
-- per host it stands until a minute after the last refusal opened a connection (the login works again); the instance's
-- finding stands at the LOWEST of the hosts still reading it, as the streaks' (a host refused beside one reading fine
-- is no finding)
SELECT a.instance_id, 'critical', 'authentication failing', 'login refused', true, 'the login the collector uses works', 'all',
       format('%s login(s) refused in 15 minutes (a per-database connect included): a changed password or pg_hba? each run retries it and can lock the login out',
              min(a.n)),
       'pgvigil collector', max(a.at)
  FROM (SELECT h.host, l.instance_id,
               CASE WHEN sum(l.auth_failures) > 0
                     AND max(l.minute) FILTER (WHERE l.auth_failures > 0) >= coalesce(max(l.minute) FILTER (WHERE l.opened > 0 AND l.auth_failures = 0), '-infinity')
                    THEN sum(l.auth_failures) ELSE 0 END AS n,
               max(l.minute) FILTER (WHERE l.auth_failures > 0) AS at
          FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id) JOIN pgvigil.instances i USING (instance_id)
         WHERE i.is_active AND l.minute > now() - interval '15 minutes'
         GROUP BY h.host, l.instance_id) a
  JOIN pgvigil.collector_reading r ON r.host = a.host AND r.instance_id = a.instance_id
 GROUP BY a.instance_id
HAVING min(a.n) > 0
UNION ALL
-- two runs of `pgvigil run` live at once collecting one instance in the same minute, in at least 2 of the last 10
-- complete minutes: both write every collection, cursor imports twice. A run whose stop mark is at or before the
-- other's start is a restart, not a second collector (two clean restarts in 10 minutes raise nothing); a crash
-- (no stop mark) overlaps its replacement for one minute at most
SELECT d.instance_id, 'critical', 'collected by more than one collector', d.collectors::text || ' collectors', true,
       'one collector per instance', 'all',
       'the same minutes from ' || hh.hosts || ': each collection is written twice (logs, job history and every cursor import twice)',
       'pgvigil collector', d.last_minute
  FROM (SELECT x.instance_id, max(x.n) AS collectors, max(x.minute) AS last_minute
          FROM (SELECT l.instance_id, l.minute, count(DISTINCT l.collector_id) AS n
                  FROM pgvigil.collector_load l
                  JOIN pgvigil.collector_heartbeat ha ON ha.collector_id = l.collector_id
                 WHERE l.minute >= now() - interval '10 minutes' AND l.minute < date_trunc('minute', now())
                   AND EXISTS (SELECT 1 FROM pgvigil.collector_load o
                                 JOIN pgvigil.collector_heartbeat hb ON hb.collector_id = o.collector_id
                                WHERE o.instance_id = l.instance_id AND o.minute = l.minute AND o.collector_id <> l.collector_id
                                  AND NOT coalesce(ha.stopped_at <= hb.started_at, false)
                                  AND NOT coalesce(hb.stopped_at <= ha.started_at, false))
                 GROUP BY l.instance_id, l.minute
                HAVING count(DISTINCT l.collector_id) > 1) x
         GROUP BY x.instance_id
        HAVING count(*) >= 2) d
  JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
  CROSS JOIN LATERAL (SELECT string_agg(DISTINCT format('%s (pid %s)', h.host, h.pid), ', ') AS hosts
                        FROM pgvigil.collector_load l2 JOIN pgvigil.collector_heartbeat h USING (collector_id)
                       WHERE l2.instance_id = d.instance_id AND l2.minute = d.last_minute) hh
UNION ALL
-- FLEET STATS ROLLUP (0139): an instance's jobs' hourly statistics not rolled up - per source, its newest 'rollup
-- failed' row of the last day (collection_log, collection 'job_stats_hourly') with no 'rollup healed' row of that
-- source after it (the heal writes one when it rebuilds a range that was logged). The runs are stored and the alerting
-- grid reads them; the fleet Jobs page's 7-day columns are behind. A failing range is logged once an hour, so the
-- newest row stands for the whole fault and the heal clears it (not 'the last hour': that would drop between rows).
-- 'After' is by log_id: both writers hold the instance's lock, so log_id follows their order, while snapshot_at is the
-- transaction's start (a heal and a failure of one statement share it). collection_log_job_stats_idx (below) serves both reads
SELECT f.instance_id, 'warning', 'job statistics not rolled up', f.src, true, 'the hours rebuilt by the next import or pgvigil purge', 'all',
       f.note, 'pgvigil collector', f.snapshot_at
  FROM (SELECT DISTINCT ON (l.instance_id, substring(l.note FROM '^rollup failed for the ([a-z_]+) hours'))
               l.instance_id, substring(l.note FROM '^rollup failed for the ([a-z_]+) hours') AS src, l.note, l.snapshot_at, l.log_id
          FROM pgvigil.collection_log l
         WHERE l.collection = 'job_stats_hourly' AND l.status = 'error' AND l.note LIKE 'rollup failed for the %'
           AND l.snapshot_at > now() - interval '1 day'
         ORDER BY l.instance_id, substring(l.note FROM '^rollup failed for the ([a-z_]+) hours'), l.log_id DESC) f
  JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.is_active
 WHERE f.src IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM pgvigil.collection_log h
                    WHERE h.instance_id = f.instance_id AND h.collection = 'job_stats_hourly' AND h.status = 'ok'
                      AND h.note LIKE 'rollup healed: the ' || f.src || ' hours %' AND h.log_id > f.log_id)
UNION ALL
-- HA join (0150): an instance's replication hours not rolled up - its newest 'rollup failed' row of the last day
-- (collection_log, collection 'replication_hourly') with no 'rollup healed' row after it. An arm of its own, not a
-- name in the arm above: 0150's notes name no source ('rollup failed for the hours X to Y ...', 'rollup healed: the
-- hours X to Y rebuilt' - an instance has ONE range to rebuild, its trigger's), so the arm above, which parses the
-- source out of the note and requires it, gives no row for them. The value is the samples' table, fixed while the
-- fault lasts (an alert is keyed by its finding's value); the detail is the row's note. The samples are stored and
-- the Replication page's charts read them; only a chart over the hours is behind. 'After' is by log_id, as above
SELECT f.instance_id, 'warning', 'replication hours not rolled up', 'replication_sample', true, 'the hours rebuilt by the next import or pgvigil purge', 'all',
       f.note, 'pgvigil collector', f.snapshot_at
  FROM (SELECT DISTINCT ON (l.instance_id) l.instance_id, l.note, l.snapshot_at, l.log_id
          FROM pgvigil.collection_log l
         WHERE l.collection = 'replication_hourly' AND l.status = 'error' AND l.note LIKE 'rollup failed for the hours %'
           AND l.snapshot_at > now() - interval '1 day'
         ORDER BY l.instance_id, l.log_id DESC) f
  JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.is_active
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collection_log h
                    WHERE h.instance_id = f.instance_id AND h.collection = 'replication_hourly' AND h.status = 'ok'
                      AND h.note LIKE 'rollup healed: the hours %' AND h.log_id > f.log_id)
UNION ALL
-- the slow-connect tier: an instance whose connects average over its own warning (collector_connects); its value the
-- average in seconds (alert_finding_key reads its digits as '#': one alert while it stays slow)
SELECT c.instance_id, CASE WHEN c.level = 2 THEN 'critical' ELSE 'warning' END, 'slow connect', to_char(c.avg_s, 'FM9990.00') || ' s', true,
       format('connects under %s s on average', coalesce(c.warn, c.crit)), 'all',
       format('its connects from %s averaged %s s over its last 5 written minutes (%s timed, the longest %s s; warning %s, critical %s): the time includes DNS, the TLS handshake and the login, and the collector''s own CPU',
              c.host, c.avg_s, c.timed, c.max_s, coalesce(c.warn || ' s', 'none'), coalesce(c.crit || ' s', 'none')),
       'pgvigil collector', c.newest
  FROM pgvigil.collector_connects c
 WHERE c.level >= 1
UNION ALL
-- a slowdown most of a server's or a collector's instances share: ONE alert (collector_slow_folds), its members held
SELECT NULL::int, CASE WHEN f.level = 2 THEN 'critical' ELSE 'warning' END, 'slow connects', f.value, true,
       'connects under their warning', 'all', f.detail, 'pgvigil repository', f.since
  FROM pgvigil.collector_slow_folds f;

-- ====================================================================================================================
-- pgvigil.darling_alert_findings: base 0118_darling_alerts.sql L58
--   #1 P 405 2370bd1c: 2370bd1c:scripts/proof-pm313-rules-wiring.patch (0190_join_release2.sql hunks, pre blob 40526c2)
--   merge conflict at arm #1 (405), block 1, resolved by hand: 405's runnable arm; 0118's AG-secondary arm that 405's copy carries left out (the HA candidate's L1 dropped it)
-- ====================================================================================================================
CREATE OR REPLACE VIEW pgvigil.darling_alert_findings AS
SELECT t.instance_id, CASE WHEN t.n_dead_tup >= 10000000 THEN 'critical' ELSE 'warning' END AS severity,
       'dead tuples piling up'::text AS setting, t.datname || '.' || t.schema_name || '.' || t.table_name AS value, true AS is_set,
       'under 1000000 dead tuples'::text AS suggested, 'all'::text AS platforms,
       format('%s dead tuples beside %s live ones at the last read; the last autovacuum %s: autovacuum is behind on this table (a long transaction, an idle-in-transaction session or a slot can hold its cleanup back)',
              t.n_dead_tup, coalesce(t.n_live_tup, 0), coalesce(to_char(t.last_autovacuum, 'YYYY-MM-DD HH24:MI'), 'never')) AS detail,
       'pg-collector'::text AS source, t.snapshot_at AS at
  FROM pgvigil.tables t
 WHERE t.is_present AND t.n_dead_tup >= 1000000 AND t.snapshot_at > now() - interval '1 day'
UNION ALL
SELECT s.instance_id, CASE WHEN s.lag_bytes >= 50 * 1073741824::bigint THEN 'critical' ELSE 'warning' END, 'replication slot retaining WAL', s.key, true,
       'under 10 GB', 'all',
       format('the slot %s retains %s of WAL and %s: WAL a slot keeps is unbounded unless max_slot_wal_keep_size is set, so it fills the volume; a slot whose consumer is gone is dropped',
              s.key, pg_size_pretty(s.lag_bytes), CASE WHEN coalesce(s.active, false) THEN 'its consumer is connected' ELSE 'its consumer is not connected' END),
       'pg-collector', s.snapshot_at
  FROM pgvigil.replication_latest s
 WHERE s.kind = 'slot' AND s.lag_bytes >= 10 * 1073741824::bigint AND s.snapshot_at > now() - interval '15 minutes'
UNION ALL
SELECT v.instance_id, CASE WHEN v.free_bytes <= 2 * 1073741824::bigint THEN 'critical' ELSE 'warning' END, 'a volume under 5 GB free', v.drive, true,
       'over 5 GB free', 'all',
       format('%s free of %s (%s %%); %s database file(s) sit on it; its percent threshold (warning under %s %%, critical under %s %%) raises nothing, so the 5 GB floor judges it',
              pg_size_pretty(v.free_bytes), pg_size_pretty(v.total_bytes), v.free_pct, v.files, v.warn_pct, v.crit_pct),
       'mssql_storage', v.snapshot_at
  FROM pgvigil.drives_now v
 WHERE v.source = 'dm_os_volume_stats' AND v.status = 'ok' AND v.free_bytes < 5 * 1073741824::bigint
   AND v.snapshot_at > now() - interval '3 hours' AND v.total_bytes > 10 * 1073741824::bigint
UNION ALL
-- [#1 405 2370bd1c]
SELECT i.instance_id, CASE WHEN q.per_sched >= 16 THEN 'critical' ELSE 'warning' END, 'runnable queue per scheduler', 'schedulers', true,
       'under 8 per scheduler', 'all',
       -- [#1 405 2370bd1c]
       format('runnable tasks averaged %s per scheduler over %s (%s schedulers): work waits for a CPU',
              round(q.per_sched, 1), q.window_text, q.schedulers),
       'mssql_perf', q.at
  -- [#1 405 2370bd1c]
  FROM pgvigil.instances i
  CROSS JOIN LATERAL pgvigil.mssql_runnable_queue(i.instance_id, now()) q
 WHERE i.engine = 'sqlserver' AND q.per_sched >= 8
UNION ALL
SELECT l.instance_id, 'warning', 'long-running requests', 'requests', true, 'under 30 minutes', 'all',
       format('%s request(s) running 30 minutes or more, the longest %s min: session %s (%s, login %s, program %s)', l.n, l.longest_min, l.session_id,
              coalesce(l.command, 'command unknown'), coalesce(l.login_name, '(unknown)'), coalesce(nullif(l.program_name, ''), '(none)')),
       'mssql_running', l.snapshot_at
  FROM (SELECT r.instance_id, r.snapshot_at, count(*) OVER (PARTITION BY r.instance_id) AS n, r.elapsed_ms / 60000 AS longest_min,
               r.session_id, r.command, r.login_name, r.program_name,
               row_number() OVER (PARTITION BY r.instance_id ORDER BY r.elapsed_ms DESC) AS k
          FROM pgvigil.mssql_requests r
          JOIN (SELECT instance_id, max(snapshot_at) AS at FROM pgvigil.mssql_requests_summary WHERE snapshot_at > now() - interval '10 minutes' GROUP BY instance_id) m
            ON m.instance_id = r.instance_id AND m.at = r.snapshot_at
         WHERE r.snapshot_at > now() - interval '10 minutes'      -- the day partitions pruned whatever the join's plan
           AND r.request_id IS NOT NULL AND r.session_id > 50 AND r.elapsed_ms >= 1800000
           AND coalesce(upper(r.command), '') NOT LIKE 'BACKUP%' AND coalesce(upper(r.command), '') NOT LIKE 'RESTORE%'
           AND coalesce(upper(r.wait_type), '') NOT IN ('BACKUPTHREAD', 'BACKUPIO', 'SP_SERVER_DIAGNOSTICS_SLEEP', 'WAITFOR', 'BROKER_RECEIVE_WAITFOR', 'XE_LIVE_TARGET_TVF')
           AND coalesce(upper(r.wait_type), '') NOT LIKE '%SP_SERVER_DIAGNOSTICS%'
           AND coalesce(r.program_name, '') NOT LIKE 'SQLAgent - TSQL JobStep%'
           AND coalesce(upper(r.login_name), '') NOT IN ('NT AUTHORITY\SYSTEM', 'NT AUTHORITY\NETWORK SERVICE')) l
 WHERE l.k = 1
UNION ALL
SELECT c.instance_id, 'critical', 'server unreachable', i.name, true, 'answering and accepting the collector''s login', 'all',
       format('the newest read of %s (%s, %s) could not connect: %s', i.name, c.collection, to_char(c.snapshot_at, 'YYYY-MM-DD HH24:MI:SS'), substr(c.note, 10)),
       'collector', c.snapshot_at
  FROM (SELECT DISTINCT ON (d.instance_id) d.* FROM pgvigil.collection_dates d ORDER BY d.instance_id, d.snapshot_at DESC) c
  JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND c.status = 'error' AND c.snapshot_at > now() - interval '30 minutes'
   -- [#1 405 2370bd1c]
   AND c.note LIKE 'connect: %'
UNION ALL
-- task 405 (Changed 19): the PostgreSQL poison wait (0156's pg_poison_wait_findings, wait_sample only), its info row
-- 'not judged: needs pg_wait_sampling' too: an info finding on the Findings page and for a channel set to info (405
-- review part A, finding 4); the top statements (its query column) have no reader yet
SELECT i.instance_id, p.severity, 'poison wait', p.object, true, 'under 1.0 waiting backends on average', 'all', p.detail, 'pg-collector', p.at
  FROM pgvigil.instances i
  CROSS JOIN LATERAL pgvigil.pg_poison_wait_findings(i.instance_id, now()) p
 WHERE i.engine = 'postgres' AND i.is_active AND p.severity IN ('info', 'warning', 'critical');

-- ====================================================================================================================
-- pgvigil.collector_secret_findings: base none (new in a slice of this file)
--   #1 H the join 0300 --------: the 18 tests: TestCollectorFindingsReadsItsArms - B24e's inline arm of findings as its own view (b24e-join-lines.sql L5-11), an own source the Collector page reads by name
-- ====================================================================================================================
-- [#1 the join 0300 --------]
CREATE OR REPLACE VIEW pgvigil.collector_secret_findings AS
SELECT s.instance_id, s.severity, s.check_name AS setting, s.object AS value, true AS is_set,
       'the login''s password readable from AWS Secrets Manager by the collector host''s identity'::text AS suggested,
       'all'::text AS platforms, s.detail, 'pgvigil collector'::text AS source, s.at
  FROM pgvigil.secret_findings s;

-- ====================================================================================================================
-- pgvigil.findings: base 0190_join_release2.sql L45
--   #1 P S2 09661906: 09661906:scripts/proof-mssql-security-wiring.patch (0190_join_release2.sql hunks, pre blob 40526c2)
--   #2 P S2 09661906: 09661906:scripts/proof-mssql-xe-captures-wiring.patch (0190_join_release2.sql hunks, pre blob a994399)
--   #3 P 404 1cb5f703: 1cb5f703:scripts/proof-restart-marker-wiring.patch (0190_join_release2.sql hunks, pre blob 40526c2)
--   #4 P 409-410 03f74d79: aa8265de:scripts/sqltb-s4-wiring.patch (item 03f74d79; 0190_join_release2.sql hunks, pre blob 40526c28)
--   #5 T B6G-N 17e6d3f7: 0190_join_release2.sql L22 (merge-base e4af7c3e 0190_join_release2.sql) - in place (0121 / 0190)
--   #6 H INV(301b) 4c155a56: scripts/inv-301b-join-lines.sql L15-19 (line 2) - after task 301's mssql_backup_loc arm (the mssql_* arms' shape)
--   #7 H INV(302) 4c155a56: scripts/inv-302-join-lines.sql L5-9 (line 1) - beside the pg_* arms: after pg_backups_findings
--   #8 H KITWATCH 32460ec2: scripts/kitwatch-join-lines.sql L6-10 - after collector_findings' arm
--   #9 H B24e f6f83845: scripts/b24e-join-lines.sql L5-11 - after collector_findings' arm (after KITWATCH's)
--   #10 H B24H-STREAKS c937e891: scripts/b24h-join-lines.sql L5-7 (line 1) - after B24e's (the collector's own arms)
--   #11 H 409-410 03f74d79: review A #9 - the comment names 0190's mssql_checks_findings
--   #12 H the join 0300 --------: the 18 tests: TestCollectorFindingsReadsItsArms - B24e's arm reads its own view (collector_secret_findings) in place of the inline source
--   merge conflict at arm #3 (404), block 1, resolved by hand: both arms: the base's 301 / 304 arms, then 404's
-- ====================================================================================================================
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
  ) x
 ORDER BY x.instance_id, x.setting, x.value, x.detail;

-- ====================================================================================================================
-- pgvigil.alert_rule_findings: base 0085_alert_rules.sql L646
--   #1 T S2 09661906: 0154_alert_scope.sql L958 (merge-base ebf9a9c2 0085_alert_rules.sql) - 403a: 0154 re-creates 0085's view whole
--   #2 D B6G-N 17e6d3f7: scripts/b6g-join-draft-arf.sql against scripts/b6g-join-draft-arf-base.sql - b6g-join-lines.sql line 1: the worst collection of the newest hour
--   merge conflict at arm #2 (B6G-N), block 1, resolved by hand: S2's 0154 text with B6G-N's worst-collection CASE before the held part (b6g-join-lines.sql line 1's place)
-- ====================================================================================================================
CREATE OR REPLACE VIEW pgvigil.alert_rule_findings AS
SELECT s.instance_id, s.state AS severity,
       c.family_label || ': ' || c.label || CASE WHEN s.database <> '' THEN ' [' || s.database || ']' ELSE '' END AS setting,
       -- [#1 S2 09661906]
       CASE s.op_family
         WHEN 'rise' THEN 'rises ' || pgvigil.metric_num(s.threshold) || ' between two samples for ' || r.for_minutes
                          || ' min; last rise ' || coalesce(pgvigil.metric_num(s.value), 'none')
         WHEN 'baseline' THEN 'above baseline for ' || r.for_minutes || ' min; last sample ' || coalesce(pgvigil.metric_num(s.value), 'none')
         ELSE r.op || ' ' || pgvigil.metric_num(s.threshold) || ' for ' || r.for_minutes || ' min; last sample '
              || coalesce(pgvigil.metric_num(s.value), 'none') END AS value,
       NULL::boolean AS is_set, NULL::text AS suggested, NULL::text AS platforms,
       'alert rule ' || r.rule_id || coalesce(' "' || r.name || '"', '') || ' ('
         -- [#1 S2 09661906]
         || CASE r.scope WHEN 'fleet' THEN 'every instance' WHEN 'tag' THEN 'tag ' || r.tag
                         WHEN 'tags' THEN 'tags ' || pgvigil.alert_scope_text(r.scope_tags) ELSE 'instance ' || r.instance_name END
         || '): ' || r.metric || ' '
         || CASE s.op_family
              WHEN 'rise' THEN 'rises more than ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || ') between two samples'
              WHEN 'baseline' THEN CASE WHEN coalesce(s.baseline_days, 0) = 7 AND s.baseline IS NOT NULL
                                        THEN 'above ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || '): the greater of the rule''s value and this hour''s baseline '
                                             || pgvigil.metric_num(s.baseline) || ' + ' || pgvigil.metric_num(r.band_pct) || ' % (' || r.zone || ')'
                                        ELSE 'above ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || '): no baseline yet ('
                                             || coalesce(s.baseline_days, 0) || ' of 7 days), the rule''s value alone' END
              ELSE r.op || ' ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || ')' END
         || ' since ' || to_char(s.beyond_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
         -- [#2 B6G-N 17e6d3f7]
         -- B6G-N (scripts/b6g-join-lines.sql line 1): a Collection-family rule naming no collection names the worst
         -- collection of its newest hour (the detail is outside alert_finding_key: one alert as the worst passes)
         || CASE WHEN c.family = 'collection' AND s.database = '' AND s.sample_at IS NOT NULL
                 THEN coalesce('; the worst collection of its newest hour: ' || pgvigil.collection_worst(s.instance_id, c.metric, s.sample_at), '')
                 ELSE '' END
         -- [#1 S2 09661906]
         || CASE WHEN s.held THEN '; no fresh sample since ' || to_char(s.sample_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: the alert is held' ELSE '' END
         || CASE WHEN s.flapping_since IS NOT NULL
                 THEN '; flapping since ' || to_char(s.flapping_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')
                      || ' UTC (4 to 7 changes in its last 12 results): sent once, its repeats held' ELSE '' END AS detail,
       'alert rule'::text AS source, coalesce(s.sample_at, s.evaluated_at) AS at,
       -- [#1 S2 09661906]
       s.rule_id, s.op_family, s.flapping_since, s.value AS metric_value
  FROM pgvigil.alert_rule_state s
  JOIN pgvigil.alert_rules r ON r.rule_id = s.rule_id
  JOIN pgvigil.metric_catalog c ON c.key = s.metric
 WHERE s.state IN ('warning', 'critical');

-- ====================================================================================================================
-- pgvigil.alert_findings: base 0190_join_release2.sql L499
--   #1 P S2 09661906: 09661906:scripts/proof-alert-scope-wiring.patch (0190_join_release2.sql hunks, pre blob a994399a)
--   #2 T B6G-N 17e6d3f7: 0190_join_release2.sql L462 (merge-base e4af7c3e 0190_join_release2.sql) - in place (0121 / 0190)
--   #3 H the join 0300 --------: the 18 tests: TestCollectorFindingsOwnShapes - K3's comment names the source without quotes (a quoted own source in the view reads as an inline arm)
-- ====================================================================================================================
CREATE OR REPLACE VIEW pgvigil.alert_findings AS
SELECT pgvigil.alert_key(f.instance_id, f.source, f.setting, f.value) AS finding_key,
       f.instance_id, coalesce(i.name, 'pgvigil') AS instance, coalesce(t.tags, '{}'::text[]) AS tags,
       f.severity, f.setting, f.value, f.suggested, f.detail, f.source, f.at
  FROM (SELECT x.instance_id, x.severity, x.setting, x.value, x.suggested, x.detail, x.source, x.at FROM pgvigil.findings x
        UNION ALL
        -- [#1 S2 09661906]
        SELECT y.instance_id, y.severity, y.setting, y.value, y.suggested, y.detail, y.source, y.at FROM pgvigil.alert_rule_findings y
        -- [#3 the join 0300 --------]
        UNION ALL   -- tasks 403b / B24k (0154): the alert channels' own findings (failing, quota low; the repository's own source, no instance)
        -- [#1 S2 09661906]
        SELECT z.instance_id, z.severity, z.setting, z.value, z.suggested, z.detail, z.source, z.at FROM pgvigil.alert_channel_findings z) f
  LEFT JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN pgvigil.instance_tags_merged t USING (instance_id)
 -- [#2 B6G-N 17e6d3f7]
 WHERE (i.is_active OR f.source = 'pgvigil repository')
   -- B6.4 (WIRING): 'alert sender idle' is shown, never sent (an idle sender cannot send its own news)
   AND NOT (f.source = 'pgvigil repository' AND f.setting = 'alert sender idle');

-- ====================================================================================================================
-- pgvigil.alert_due: base 0190_join_release2.sql L519
--   #1 P S2 09661906: 09661906:scripts/proof-alert-scope-wiring.patch (0190_join_release2.sql hunks, pre blob a994399a)
--   #2 T B6G-N 17e6d3f7: 0190_join_release2.sql L519 (merge-base e4af7c3e 0190_join_release2.sql) - in place (0121 / 0190)
--   #3 D B24H-STREAKS c937e891: scripts/b24h-join-draft-alertdue.sql against 0190's alert_due at df95d278 (the file's own named pre) - b24h-join-lines.sql line 3: the probe terms
--   merge conflict at arm #3 (B24H-STREAKS), block 1, resolved by hand: both CTE lists: B6G-N's long_held / long_forming, then B24H's probe_*
--   merge conflict at arm #3 (B24H-STREAKS), block 2, resolved by hand: S2's channel columns (checks, digest) and checks filter, read from B24H's af CTE
--   merge conflict at arm #3 (B24H-STREAKS), block 3, resolved by hand: both waits: B6G-N's long_forming, then B24H's probe_forming / probe_forming_hosts
-- ====================================================================================================================
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
    SELECT st.*, ch.repeat_secs, ch.recovery, ch.clear_after_secs,
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

-- ====================================================================================================================
-- pgvigil.alert_mark: base 0073_ack.sql L138
--   #1 T S2 09661906: 0154_alert_scope.sql L225 (merge-base ebf9a9c2 0073_ack.sql) - 403a / 403b: the holds (B1)
--   #2 T B6G-N 17e6d3f7: 0190_join_release2.sql L479 (merge-base e4af7c3e 0073_ack.sql) - in place (0121 / 0190)
--   merge conflict at arm #2 (B6G-N), block 1, resolved by hand: S2's 0154 text (the holds) with B6G-N's repo_wide scope in its first read (B1)
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.alert_mark(p_at timestamptz, p_channels jsonb)
RETURNS void LANGUAGE plpgsql SET jit = off AS $$
DECLARE
  v_names text[] := ARRAY(SELECT e->>'name' FROM jsonb_array_elements(coalesce(p_channels, '[]'::jsonb)) e);
  -- [#1 S2 09661906]
  v_attach jsonb;
BEGIN
  UPDATE pgvigil.alert_state s SET missing_since = p_at
   WHERE s.cleared_at IS NULL AND s.missing_since IS NULL AND s.channel = ANY (v_names)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = s.finding_key);
  UPDATE pgvigil.alert_state s SET missing_since = NULL
   WHERE s.cleared_at IS NULL AND s.missing_since IS NOT NULL AND s.channel = ANY (v_names)
     AND EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = s.finding_key);
  -- [#1 S2 09661906]
  -- the carry-over's clock: a digest row whose finding is gone is marked at the first pass that no longer sees it
  UPDATE pgvigil.alert_held d SET missing_since = p_at
   WHERE d.hold_kind = 'digest' AND d.missing_since IS NULL AND d.channel = ANY (v_names)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = d.finding_key);

  -- every hold but 'attached' first: an anchor counts only while it holds nothing this pass (alert_anchor reads
  -- alert_held_all at p_at), and inside one statement the rows it writes are not seen. The alerts this first read
  -- finds attached are kept in v_attach and judged again by the second statement, which sees this one's rows.
  WITH h AS MATERIALIZED (
    SELECT x.channel, x.finding_key, x.instance_id, x.instance, x.tags, x.severity, x.source, x.setting, x.value, x.detail,
           x.clear_after_secs, x.digest,
           (x.hold).kind AS kind, (x.hold).hold_id AS hold_id, (x.hold).via AS via, (x.hold).anchor AS anchor
      FROM (SELECT DISTINCT ON (c.name, f.finding_key) c.name AS channel, f.finding_key, f.instance_id, f.instance,
                   f.tags, f.severity, f.source, f.setting, f.value, f.detail, c.clear_after_secs,
                   coalesce(c.digest, false) AS digest,
                   pgvigil.alert_hold(p_at, c.name, f.instance, f.tags, f.finding_key, f.source, f.setting, f.value,
                                      f.severity, c.clear_after_secs, coalesce(c.digest, false)) AS hold
              FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
                   AS c(name text, min_severity text, instances text[], tags text[], clear_after_secs int, checks text[],
                        -- [#2 B6G-N 17e6d3f7]
                        digest boolean, repo_wide boolean)
              JOIN pgvigil.alert_findings f
                ON (pgvigil.alert_in_scope(f.instance, f.tags, coalesce(c.instances, '{}'), coalesce(c.tags, '{}'))
                    OR (f.source = 'pgvigil repository' AND coalesce(c.repo_wide, true)))
             -- [#1 S2 09661906]
             WHERE pgvigil.severity_rank(f.severity) >= pgvigil.severity_rank(c.min_severity)
               AND pgvigil.alert_checks_match(c.checks, f.source, f.setting)
               -- a failing channel's own 'alert channel failing' is never sent to it (alerts.go), so it is never held
               -- there either: no 'why held' line of an acknowledgement on it (task 403b; a window, a digest's too,
               -- never holds a repository-wide alert: alert_window_matches)
               AND NOT (f.source = 'pgvigil repository' AND f.setting = 'alert channel failing' AND f.value = c.name)
             ORDER BY c.name, f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC) x
     WHERE (x.hold).kind IS NOT NULL   -- never 'x.hold IS NOT NULL': a row is NOT NULL only when every field is, and
                                       -- a hold's anchor is NULL but an attached one's
  ), a AS (
    INSERT INTO pgvigil.ack_suppressed AS s (ack_id, channel, finding_key, instance_id, instance_name, severity, source,
                                             setting, value, first_at, last_at, passes)
    SELECT h.hold_id, h.channel, h.finding_key, h.instance_id, h.instance, h.severity, h.source, h.setting, h.value, p_at, p_at, 1
      FROM h WHERE h.via = 'ack'
    ON CONFLICT (ack_id, channel, finding_key) DO UPDATE SET last_at = EXCLUDED.last_at, passes = s.passes + 1,
      severity = EXCLUDED.severity, value = EXCLUDED.value
  ), w AS (
    INSERT INTO pgvigil.alert_held AS y (hold_kind, hold_id, channel, finding_key, instance_id, instance_name, severity,
                                         source, setting, value, detail, first_at, last_at, passes)
    SELECT h.kind, h.hold_id, h.channel, h.finding_key, h.instance_id, h.instance, h.severity, h.source, h.setting,
           h.value, h.detail, p_at, p_at, 1
      FROM h WHERE h.via NOT IN ('ack', 'anchor')
    ON CONFLICT (hold_kind, hold_id, channel, finding_key) DO UPDATE SET last_at = EXCLUDED.last_at,
      passes = y.passes + 1, severity = EXCLUDED.severity, value = EXCLUDED.value, detail = EXCLUDED.detail,
      missing_since = NULL
  )
  SELECT coalesce(jsonb_agg(jsonb_build_object('channel', h.channel, 'finding_key', h.finding_key,
           'instance_id', h.instance_id, 'instance', h.instance, 'tags', h.tags, 'severity', h.severity,
           'source', h.source, 'setting', h.setting, 'value', h.value, 'detail', h.detail,
           'clear_after_secs', h.clear_after_secs, 'digest', h.digest)), '[]'::jsonb)
    INTO v_attach
    FROM h WHERE h.via = 'anchor';

  -- then 'attached', judged again now that this pass's other holds are written (an anchor muted or in a window this
  -- pass anchors nothing). A hold is one anchor post's (hold_id: its first send): two anchors sent in one post share
  -- it, and the row names the anchor that holds it now.
  WITH x AS MATERIALIZED (
    SELECT c.*, pgvigil.alert_hold(p_at, c.channel, c.instance, c.tags, c.finding_key, c.source, c.setting, c.value,
                                   c.severity, c.clear_after_secs, c.digest) AS hold
      FROM jsonb_to_recordset(v_attach)
           AS c(channel text, finding_key text, instance_id int, instance text, tags text[], severity text, source text,
                setting text, value text, detail text, clear_after_secs int, digest boolean)
  )
  INSERT INTO pgvigil.alert_held AS y (hold_kind, hold_id, channel, finding_key, instance_id, instance_name, severity,
                                       source, setting, value, detail, first_at, last_at, passes, anchor_key,
                                       anchor_first_sent_at)
  SELECT (x.hold).kind, (x.hold).hold_id, x.channel, x.finding_key, x.instance_id, x.instance, x.severity, x.source,
         x.setting, x.value, x.detail, p_at, p_at, 1, (x.hold).anchor,
         timestamptz 'epoch' + (x.hold).hold_id * interval '1 microsecond'
    FROM x WHERE (x.hold).via = 'anchor'
  ON CONFLICT (hold_kind, hold_id, channel, finding_key) DO UPDATE SET last_at = EXCLUDED.last_at,
    passes = y.passes + 1, severity = EXCLUDED.severity, value = EXCLUDED.value, detail = EXCLUDED.detail,
    missing_since = NULL, anchor_key = EXCLUDED.anchor_key, anchor_first_sent_at = EXCLUDED.anchor_first_sent_at;
END $$;

-- ====================================================================================================================
-- pgvigil.import_collector_beat: base 0121_collector_health.sql L257
--   #1 T B6G-N 17e6d3f7: 0121_collector_health.sql L258 (merge-base e4af7c3e 0121_collector_health.sql) - in place (0121 / 0190)
--   #2 T B24H-STREAKS c937e891: 0121_collector_health.sql L321 (merge-base 539172c9 0121_collector_health.sql) - in place (0121)
--   #3 P N4 280368a5: 280368a5:scripts/n4-wiring.patch (0121_collector_health.sql hunks, pre blob 6ff25302)
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.import_collector_beat(p_id text, p_minute timestamptz, p_beat jsonb)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  v_conns int;
  v_host  text;
BEGIN
  SELECT host INTO v_host FROM pgvigil.collector_heartbeat WHERE collector_id = p_id;
  IF v_host IS NULL THEN
    RETURN false;
  END IF;
  SELECT count(*) INTO v_conns FROM pg_stat_activity
   WHERE datname = current_database() AND application_name LIKE 'pgvigil%';
  UPDATE pgvigil.collector_heartbeat
     SET beat_at = now(), mem_bytes = (p_beat->>'mem_bytes')::bigint, goroutines = (p_beat->>'goroutines')::int,
         instances = (p_beat->>'instances')::int, repo_conns = v_conns,
         beat_minute = greatest(beat_minute, p_minute),
         -- [#1 B6G-N 17e6d3f7]
         sends_alerts = coalesce((p_beat->>'sends_alerts')::boolean, sends_alerts),
         -- a run still beating 2 minutes after it was retired was retired by mistake (a second host of that name, the
         -- door run for a host that is not gone): the mark goes. A beat sooner than that is a stopping service's last
         -- one and must not undo its uninstall's retire
         retired_at = CASE WHEN retired_at < now() - interval '2 minutes' THEN NULL ELSE retired_at END
   WHERE collector_id = p_id;
  INSERT INTO pgvigil.collector_runs (minute, collector_id, engine, collection, runs, failures, rows_written, dur_ms_sum, dur_ms_max, dur_hist,
                                      -- [#3 N4 280368a5]
                                      retries)
  SELECT p_minute, p_id, coalesce(nullif(r.engine, ''), 'postgres'), r.collection, r.runs, r.failures, r.rows, r.dur_sum, r.dur_max,
         -- [#3 N4 280368a5]
         ARRAY(SELECT jsonb_array_elements_text(r.hist)::int), greatest(coalesce(r.retries, 0), 0)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'runs') = 'array' THEN p_beat->'runs' ELSE '[]'::jsonb END)) AS r(engine text, collection text, runs int, failures int, rows bigint,
                                                                  -- [#3 N4 280368a5]
                                                                  dur_sum bigint, dur_max int, hist jsonb, retries int)
  ON CONFLICT (minute, collector_id, engine, collection) DO UPDATE
     SET runs = collector_runs.runs + EXCLUDED.runs, failures = collector_runs.failures + EXCLUDED.failures,
         -- [#3 N4 280368a5]
         retries = collector_runs.retries + EXCLUDED.retries,
         rows_written = collector_runs.rows_written + EXCLUDED.rows_written, dur_ms_sum = collector_runs.dur_ms_sum + EXCLUDED.dur_ms_sum,
         dur_ms_max = greatest(collector_runs.dur_ms_max, EXCLUDED.dur_ms_max),
         dur_hist = ARRAY(SELECT coalesce(a, 0) + coalesce(b, 0) FROM unnest(collector_runs.dur_hist, EXCLUDED.dur_hist) AS u(a, b));
  INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, interval_s, noanswer, target,
                                      timed, connect_ms_sum, connect_ms_max)
  SELECT p_minute, i.instance_id, p_id, l.attempts, l.opened, l.runs, l.failures, l.auth, nullif(l.interval_s, 0), coalesce(l.noanswer, 0), nullif(l.target, ''),
         coalesce(l.timed, 0), coalesce(l.connect_ms_sum, 0), coalesce(l.connect_ms_max, 0)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'load') = 'array' THEN p_beat->'load' ELSE '[]'::jsonb END)) AS l(instance text, attempts int, opened int, runs int, failures int, auth int, interval_s int, noanswer int, target text, timed int, connect_ms_sum bigint, connect_ms_max int)
    JOIN pgvigil.instances i ON i.name = l.instance
  ON CONFLICT (minute, instance_id, collector_id) DO UPDATE
     SET attempts = collector_load.attempts + EXCLUDED.attempts, opened = collector_load.opened + EXCLUDED.opened,
         runs = collector_load.runs + EXCLUDED.runs,
         failures = collector_load.failures + EXCLUDED.failures, auth_failures = collector_load.auth_failures + EXCLUDED.auth_failures,
         interval_s = least(collector_load.interval_s, EXCLUDED.interval_s),
         noanswer = collector_load.noanswer + EXCLUDED.noanswer, target = coalesce(EXCLUDED.target, collector_load.target),
         -- a minute written twice (a beat retried): the timed connects and their time summed, the longest kept
         timed = collector_load.timed + EXCLUDED.timed, connect_ms_sum = collector_load.connect_ms_sum + EXCLUDED.connect_ms_sum,
         connect_ms_max = greatest(collector_load.connect_ms_max, EXCLUDED.connect_ms_max);
  PERFORM pgvigil.collector_spells_take(p_id, p_minute);
  PERFORM pgvigil.collector_span_take(p_id, p_minute);
  -- the beat names the instances it loaded (collector_instances): seen at the minute's end
  INSERT INTO pgvigil.collector_instances (collector_id, instance, seen_at, interval_s)
  SELECT p_id, l.instance, p_minute + interval '1 minute', nullif(l.interval_s, 0)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'load') = 'array' THEN p_beat->'load' ELSE '[]'::jsonb END)) AS l(instance text, interval_s int)
   WHERE l.instance IS NOT NULL
  ON CONFLICT (collector_id, instance) DO UPDATE SET seen_at = greatest(collector_instances.seen_at, EXCLUDED.seen_at),
                                                    interval_s = coalesce(EXCLUDED.interval_s, collector_instances.interval_s);
  -- a streak whose beat carries its first failure ('since') takes it, whatever start is stored (a streak that ended
  -- and began again inside one beat never wrote its 0)
  UPDATE pgvigil.collector_streaks cs SET failing_since = NULL
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'streaks') = 'array' THEN p_beat->'streaks' ELSE '[]'::jsonb END)) AS s(instance text, collection text, since timestamptz)
    JOIN pgvigil.instances i ON i.name = s.instance
   WHERE cs.instance_id = i.instance_id AND cs.collection = s.collection AND cs.host = v_host AND s.since IS NOT NULL;
  INSERT INTO pgvigil.collector_streaks (instance_id, collection, host, fail_streak, last_error, last_run_at, failing_since)
  SELECT i.instance_id, s.collection, v_host, s.fails, nullif(s.error, ''), s.at, CASE WHEN s.fails > 0 THEN coalesce(s.since, s.at) END
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'streaks') = 'array' THEN p_beat->'streaks' ELSE '[]'::jsonb END)) AS s(instance text, collection text, fails int, error text, at timestamptz, since timestamptz)
    JOIN pgvigil.instances i ON i.name = s.instance
  ON CONFLICT (instance_id, collection, host) DO UPDATE
     SET fail_streak = EXCLUDED.fail_streak, last_error = EXCLUDED.last_error, last_run_at = EXCLUDED.last_run_at,
         failing_since = CASE WHEN EXCLUDED.fail_streak = 0 THEN NULL
                              ELSE coalesce(collector_streaks.failing_since, EXCLUDED.failing_since) END;
  INSERT INTO pgvigil.collector_beats (at, collector_id, mem_bytes, goroutines, repo_conns, repo_bytes, runs, failures, rows_written)
  SELECT now(), p_id, (p_beat->>'mem_bytes')::bigint, (p_beat->>'goroutines')::int, v_conns, pg_database_size(current_database()),
         coalesce(sum(r.runs), 0), coalesce(sum(r.failures), 0), coalesce(sum(r.rows), 0)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'runs') = 'array' THEN p_beat->'runs' ELSE '[]'::jsonb END)) AS r(runs int, failures int, rows bigint);
  -- [#2 B24H-STREAKS c937e891]
  -- the history this file keeps: 8 days (the page reads 24 h and 7 days); the two minute-led tables by their marks
  -- (collector_trim), and a beat whose own minute is already past 8 days (a collector clock that far behind) takes its
  -- rows back at once - they sit below the mark, where no trim reaches (the old whole-key trim removed them here too)
  DELETE FROM pgvigil.collector_beats WHERE at < now() - interval '8 days';
  -- [#2 B24H-STREAKS c937e891]
  PERFORM pgvigil.collector_trim('collector_runs');
  PERFORM pgvigil.collector_trim('collector_load');
  IF p_minute < now() - interval '8 days' THEN
    DELETE FROM pgvigil.collector_runs WHERE minute = p_minute AND collector_id = p_id;
    DELETE FROM pgvigil.collector_load WHERE minute = p_minute AND collector_id = p_id;
  END IF;
  DELETE FROM pgvigil.collector_spells WHERE coalesce(ended_at, last) < now() - interval '8 days';
  DELETE FROM pgvigil.collector_instances WHERE seen_at < now() - interval '8 days';
  -- this host's streaks of an instance it has not named for 8 days, written 8 days ago or more (never by the streak's
  -- own time alone: a streak at 0 is not written again while it stays 0, and a host still reading must keep counting
  -- as 0; never by the naming alone: a streak just written stays)
  DELETE FROM pgvigil.collector_streaks s
   WHERE s.host = v_host AND s.last_run_at < now() - interval '8 days'
     AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_instances ci JOIN pgvigil.collector_heartbeat h USING (collector_id)
                       JOIN pgvigil.instances i ON i.name = ci.instance
                      WHERE h.host = s.host AND i.instance_id = s.instance_id);
  -- [#2 B24H-STREAKS c937e891]
  -- a host gone 8 days - every run of it last beat 8 days ago or more: uninstalled, renamed, its machine gone - loses
  -- its streak rows when its last run's row goes below (the trim above takes only the beating
  -- host's rows, so a host that never beat again kept them for good; a host back after 8 days counts from 0 - with no
  -- other collector beating meanwhile its rows stay, and import_collector_streaks leaves them out). The guard reads only
  -- the heartbeat rows, so a beat with no host leaving pays nothing for it. The beats of the minute the guard turns
  -- true take one lock in turn (the STREAKS review's #2: two DELETEs of one host's rows by synchronized seq scans can
  -- deadlock and lose a beat's minute); a beat after the first finds the rows gone. Never a try-lock: a beat that
  -- skipped would still delete the host's heartbeat rows below, and if the holder then failed the streaks would stay
  IF EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat g WHERE g.beat_at < now() - interval '8 days'
              AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat f WHERE f.host = g.host AND f.beat_at >= now() - interval '8 days')) THEN
    PERFORM pg_advisory_xact_lock(31638955663386483);   -- 0x7067766961_6773: "pgvia" "gs" (alerts.go and deliver.go's form)
    DELETE FROM pgvigil.collector_streaks s
     WHERE s.host IN (SELECT g.host FROM pgvigil.collector_heartbeat g WHERE g.beat_at < now() - interval '8 days'
                        AND NOT EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat f WHERE f.host = g.host AND f.beat_at >= now() - interval '8 days'));
  END IF;
  DELETE FROM pgvigil.collector_heartbeat WHERE beat_at < now() - interval '8 days';
  RETURN true;
END $$;

-- ====================================================================================================================
-- pgvigil.import_pg_threshold: base 0190_join_release2.sql L820
--   #1 H B24H-STREAKS c937e891: scripts/b24h-join-lines.sql L34-35 (line 4) and L56-63 (line 8) - line 8: seconds to three places, both values empty for the two keys; line 4 as data (the UPDATE in the extra block)
-- ====================================================================================================================
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
    -- [#1 B24H-STREAKS c937e891]
    -- tier's connect_time both engines', the replication and HA keys SQL Server's, every other key PostgreSQL's;
    -- B24h's round_trip_time and ping_time both engines' (b24h-join-lines.sql L34-35, line 4: the UPDATE at the end of this file)
    v_why := format(CASE WHEN v_k.engines = '{postgres}' THEN 'no PostgreSQL instance %s' WHEN v_k.engines = '{sqlserver}' THEN 'no SQL Server instance %s'
                         ELSE 'no instance %s' END, coalesce(p_payload->>'instance_id', '(none)'));
  ELSIF v_level = 'tag' AND (v_tag IS NULL OR length(v_tag) > 200) THEN
    v_why := 'a tag level names its tag (200 characters at most)';
  ELSIF v_level = 'database' AND (v_db IS NULL OR length(v_db) > 63) THEN
    v_why := 'a database level names its database (63 characters at most)';
  ELSIF v_op = 'set' THEN
    FOR i IN 1..2 LOOP
      DECLARE v text := p_payload->>(CASE i WHEN 1 THEN 'warn' ELSE 'crit' END);
              -- [#1 B24H-STREAKS c937e891]
              -- B24h line 8: a key in seconds takes three places (0.025, 0.005); set here, never a CASE inside the
              -- IF's condition (PL/pgSQL ends an IF's condition at its first THEN - rel-b6g vis-b6g0166)
              v_re text := CASE WHEN v_k.unit = 'seconds' THEN '^[0-9]{1,7}(\.[0-9]{1,3})?$' ELSE '^[0-9]{1,7}(\.[0-9]{1,2})?$' END;
      BEGIN
        -- [#1 B24H-STREAKS c937e891]
        IF v IS NOT NULL AND v !~ v_re THEN
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
      -- [#1 B24H-STREAKS c937e891]
      IF v_warn IS NULL AND v_crit IS NULL AND v_key NOT IN ('uptime', 'crash', 'round_trip_time', 'ping_time') THEN   -- B24h line 8: its two keys settable empty (off)
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

-- ====================================================================================================================
-- pgvigil.purge: base 0190_join_release2.sql L198
--   #1 P B2a-N2 8aecbb2b: 8aecbb2b:scripts/azuredb-hour-wiring.patch (0190_join_release2.sql hunks, pre blob 9dbcf660)
--   #2 P 413 7184f8ea: 7184f8ea:scripts/proof-mssql-index-depth-wiring.patch (0190_join_release2.sql hunks, pre blob 40526c2)
--   #3 P 413 7184f8ea: 7184f8ea:scripts/proof-mssql-sessions-wiring.patch (0190_join_release2.sql hunks, pre blob 40526c28)
--   #4 P S2 09661906: 09661906:scripts/proof-alert-scope-wiring.patch (0190_join_release2.sql hunks, pre blob a994399a)
--   #5 P 402 0d029a1a: 0d029a1a:scripts/proof-mssql-counter-checks-wiring.patch (0190_join_release2.sql hunks, pre blob 2ea63181)
--   #6 P 404 1cb5f703: 1cb5f703:scripts/proof-restart-marker-wiring.patch (0190_join_release2.sql hunks, pre blob 40526c2)
--   #7 P 409-410 03f74d79: aa8265de:scripts/sqltb-s4-wiring.patch (item 03f74d79; 0190_join_release2.sql hunks, pre blob 40526c28)
--   #8 P N4 280368a5: 280368a5:scripts/n4-wiring.patch (0190_join_release2.sql hunks, pre blob 9dbcf660)
--   #9 H B24H-STREAKS c937e891: scripts/b24h-join-lines.sql L37-39 (line 5) - collector_probe_host rows of a retired collector
--   #10 H 81-AGENT 654a9cd5: scripts/agent-join-lines.sql L20-23 (line 2) - beside the other self-trimming tables
--   #11 H CQ-A 322675cc: scripts/cq-join-lines.sql L9-17 - before the hours tables (0139's block)
--   #12 H the join 0300 --------: the 18 tests: TestRetentionRowsOfTheHAJoin - no bracket in a comment inside the parent list (the Retention page reads the list up to its first closing bracket)
--   #13 H the join 0300 --------: the purge proof's red: TestPurgeTakesTheJoinedRetentionOnAStore - 0151's and 0162's retention: four partition parents, 0151's events, 0162's warning tables, 0151's two hour purges
--   merge conflict at arm #1 (B2a-N2), block 1, resolved by hand: both blocks: the replication hours' (0150), then B2a-N2's mssql_azuredb_hour (0167)
--   merge conflict at arm #2 (413), block 1, resolved by hand: parents list = the union (mssql_index_usage_read added)
--   merge conflict at arm #2 (413), block 2, resolved by hand: both lines: the current text's, then 413's
--   merge conflict at arm #3 (413), block 1, resolved by hand: parents list = the union (mssql_session_count, mssql_session_by added)
--   merge conflict at arm #4 (S2), block 1, resolved by hand: parents list = the union (findings_history added)
--   merge conflict at arm #6 (404), block 1, resolved by hand: both lines: the current text's, then 404's
--   merge conflict at arm #8 (N4), block 1, resolved by hand: N4-P10's strict month pattern with S2's per-parent retention CASE (403a) under it
-- ====================================================================================================================
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
  -- task 201: the run recorded (the Collector page's last purge, the 'purge not run in 2 days' finding)
  INSERT INTO pgvigil.purge_runs (started_at, finished_at, days, partitions_dropped, rows_deleted, total)
  VALUES (v_started, clock_timestamp(), p_days, v_dropped, n - cardinality(v_dropped), n);
  RETURN n;
END $$;

-- ====================================================================================================================
-- pgvigil.partition_parents: base none (new in a slice of this file)
--   #1 T N4 280368a5: 0271_partitions_ahead.sql L28 (merge-base d04bc70a none) - 0271: new in N4
--   #2 H the join 0300 --------: the 18 tests: TestPartitionsAhead, TestPartitionsAheadHourTables - the hour tables of 0151 and 0167 take their own makers
-- ====================================================================================================================
-- [#1 N4 280368a5]
CREATE OR REPLACE FUNCTION pgvigil.partition_parents()
RETURNS TABLE (parent text, maker text, unit text) LANGUAGE sql STABLE AS $$
  SELECT c.relname::text,
         -- [#2 the join 0300 --------]
         CASE WHEN c.relname = 'mssql_requests' THEN 'day'
              -- the hour tables' own makers, 0151's and 0167's: fillfactor 80, no second index - cloud_replica_hour has no
              -- instance_id for ensure_month_partition's index
              WHEN c.relname IN ('cloud_replica_hour', 'mssql_georepl_hour') THEN 'hour_0151'
              WHEN c.relname = 'mssql_azuredb_hour' THEN 'azuredb_hour'
              WHEN a.attname = 'snapshot_at' THEN 'month' ELSE 'event' END,
         -- [#1 N4 280368a5]
         CASE WHEN c.relname = 'mssql_requests' THEN 'day' ELSE 'month' END
    FROM pg_partitioned_table pt
    JOIN pg_class c ON c.oid = pt.partrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = pt.partattrs[0]
   WHERE n.nspname = 'pgvigil' AND NOT c.relispartition AND pt.partstrat = 'r' AND pt.partnatts = 1
$$;

-- ====================================================================================================================
-- pgvigil.import_partition_make: base none (new in a slice of this file)
--   #1 T N4 280368a5: 0271_partitions_ahead.sql L60 (merge-base d04bc70a none) - 0271: new in N4
--   #2 H the join 0300 --------: the 18 tests: TestPartitionsAhead, TestPartitionsAheadHourTables - the two hour makers called by name
-- ====================================================================================================================
-- [#1 N4 280368a5]
CREATE OR REPLACE FUNCTION pgvigil.import_partition_make(p_parent text, p_at timestamptz)
RETURNS text LANGUAGE plpgsql SET lock_timeout = '450ms' AS $$
DECLARE
  v_maker text;
  v_unit  text;
  v_start timestamptz;
  v_name  text;
  v_dl    int := (SELECT s.setting::int FROM pg_settings s WHERE s.name = 'deadlock_timeout');   -- milliseconds
BEGIN
  IF v_dl IS NOT NULL AND v_dl / 2 < 450 THEN
    PERFORM set_config('lock_timeout', greatest(v_dl / 2, 1)::text || 'ms', true);
  END IF;
  SELECT p.maker, p.unit INTO v_maker, v_unit FROM pgvigil.partition_parents() p WHERE p.parent = p_parent;
  IF v_maker IS NULL THEN
    RAISE EXCEPTION 'import_partition_make: % is not a partitioned table of schema pgvigil', p_parent USING ERRCODE = '22023';
  END IF;
  IF p_at IS NULL THEN
    RAISE EXCEPTION 'import_partition_make: no time given' USING ERRCODE = '22023';
  END IF;
  v_start := date_trunc(v_unit, p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  IF v_start > now() + interval '62 days' THEN
    RAISE EXCEPTION 'import_partition_make: % starts %, more than 62 days ahead', p_parent, v_start USING ERRCODE = '22023';
  END IF;
  IF p_parent = 'alert_log' AND v_start < date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
     AND NOT pg_has_role(session_user, (SELECT n.nspowner FROM pg_namespace n WHERE n.nspname = 'pgvigil'), 'MEMBER') THEN
    RAISE EXCEPTION 'import_partition_make: an earlier month of alert_log is the owner''s (0059)' USING ERRCODE = '42501';
  END IF;
  v_name := p_parent || '_' || to_char(v_start AT TIME ZONE 'UTC', CASE v_unit WHEN 'day' THEN 'YYYYMMDD' ELSE 'YYYYMM' END);
  IF to_regclass('pgvigil.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN 'exists';
  END IF;
  BEGIN
    CASE v_maker
      WHEN 'month' THEN PERFORM pgvigil.ensure_month_partition(p_parent, v_start);
      WHEN 'day'   THEN PERFORM pgvigil.mssql_ensure_day_partition(p_parent, v_start);
      -- [#2 the join 0300 --------]
      WHEN 'hour_0151'    THEN PERFORM pgvigil.hour_partition_0151(p_parent, v_start);
      WHEN 'azuredb_hour' THEN PERFORM pgvigil.mssql_azuredb_hour_partition(v_start);
      -- [#1 N4 280368a5]
      ELSE              PERFORM pgvigil.mssql_event_partition(p_parent, v_start);
    END CASE;
  EXCEPTION WHEN lock_not_available OR deadlock_detected THEN
    RETURN 'busy';   -- the block's locks went with it; the next pass tries again
  END;
  RETURN 'made';   -- this call ran the maker: two passes at once may both count one partition (the maker takes the other's)
END $$;

-- ====================================================================================================================
-- pgvigil.mssql_hadr_cursor: base 0145_mssql_azuredb.sql L290
--   #1 D INV(301b) 4c155a56: scripts/inv-301b-joined-cursor.sql against 0140's function in its tree - inv-301b-join-lines.sql 1: the backup_history cursors
--   merge conflict at arm #1 (INV(301b)), block 1, resolved by hand: both arms: 0145's azdb_since, then INV's backup_history / restore_history (its line 1: beside it)
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.mssql_hadr_cursor(p_instance_id int, p_source text)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN p_source IN ('jobs', 'jobs_mark') THEN
      (SELECT CASE p_source WHEN 'jobs' THEN c.last_history_id ELSE c.mark END
         FROM pgvigil.mssql_jobs_cursor c WHERE c.instance_id = p_instance_id)
    WHEN left(p_source, 9) = 'qs_since:' THEN
      (SELECT floor(extract(epoch FROM s.newest_interval))::bigint
         FROM pgvigil.mssql_qs_store s
        WHERE s.instance_id = p_instance_id AND s.database_name = substr(p_source, 10))
    WHEN p_source ~ '^qs_plan:[0-9]{1,18}:' THEN
      (SELECT p.plan_hash_n
         FROM pgvigil.mssql_qs_plan p
        WHERE p.instance_id = p_instance_id AND p.plan_id = split_part(p_source, ':', 2)::bigint
          AND p.database_name = substr(p_source, length(split_part(p_source, ':', 2)) + 10)
          AND (p.xml_state = 'stored' OR (p.xml_state = 'policy' AND p.xml_checked_at > now() - interval '24 hours')))
    WHEN p_source IN ('backup_sets', 'backup_sets_mark') THEN
      (SELECT CASE p_source WHEN 'backup_sets' THEN c.last_set_id ELSE c.mark END
         FROM pgvigil.mssql_backup_files_cursor c WHERE c.instance_id = p_instance_id)
    WHEN p_source = 'azdb_since' THEN
      (SELECT floor(extract(epoch FROM a.newest_minute))::bigint
         FROM pgvigil.mssql_azuredb_read a WHERE a.instance_id = p_instance_id)
    -- [#1 INV(301b) 4c155a56]
    WHEN p_source IN ('backup_history', 'backup_history_mark', 'restore_history', 'restore_history_mark') THEN
      (SELECT CASE p_source WHEN 'backup_history' THEN c.last_set_id WHEN 'backup_history_mark' THEN c.set_mark
                            WHEN 'restore_history' THEN c.last_restore_id ELSE c.restore_mark END
         FROM pgvigil.mssql_backup_history_cursor c WHERE c.instance_id = p_instance_id)
  END
$$;

-- ====================================================================================================================
-- pgvigil.metric_na_reasons: base none (new in a slice of this file)
--   #1 T 402 0d029a1a: 0152_mssql_counters.sql L857 (merge-base f8e89d2e none) - 0152: new in 402, 412's row in it
-- ====================================================================================================================
-- [#1 402 0d029a1a]
CREATE OR REPLACE VIEW pgvigil.metric_na_reasons AS
SELECT v.key, v.why FROM (VALUES
    ('waits.wait_s_per_core_min'::text,
     'not judged: no scheduler count (the mssql_cpu collection is off, or Azure SQL Database)'::text)
  ) AS v(key, why);

-- ====================================================================================================================
-- pgvigil.metric_catalog: base 0085_alert_rules.sql L43
--   #1 P 402(401) 0d029a1a: 0d029a1a:scripts/proof-mssql-counters-wiring.patch (0190_join_release2.sql hunks, pre blob 40526c2)
--   #2 P 402 0d029a1a: 0d029a1a:scripts/proof-mssql-counter-checks-wiring.patch (0190_join_release2.sql hunks, pre blob 2ea63181)
--   #3 P 402(412) 0d029a1a: 0d029a1a:scripts/proof-mssql-waits-percore-wiring.patch (0190_join_release2.sql hunks, pre blob 75f3d046)
--   #4 D VIEWS 4db89778: scripts/views-join-lines.sql against 0085's view at its merge-base 75c72186 - the grain column
--   #5 H B6G-N 17e6d3f7: 0166_collection_health.sql L792-796 (its DO block's VALUES) - the Collection family's five rows, inside v so grain covers them
--   merge conflict at arm #4 (VIEWS), block 1, resolved by hand: VIEWS' grain column (its select list) over 401's FROM (the union of sources)
-- ====================================================================================================================
CREATE OR REPLACE VIEW pgvigil.metric_catalog AS
SELECT v.family || '.' || v.metric AS key, v.engine, v.family, v.family_label, v.family_sort, v.metric, v.label, v.unit,
       v.per_database, v.fresh_secs, v.sort,
       -- [#4 VIEWS 4db89778]
       -- grain (views slice C): how a panel rolls a metric up within a time bucket before its aggregate across
       -- instances: a rate or a gauge is averaged, a count per collection interval summed, a ratio averaged and
       -- never summed; a new metric names its grain here (gauge is the default)
       CASE WHEN v.unit IN ('per_s', 'bytes_per_s') THEN 'rate'
            WHEN v.unit = 'pct' THEN 'ratio'
            WHEN v.family || '.' || v.metric IN ('database.deadlocks', 'server.checkpoints', 'server.checkpoints_req') THEN 'interval_count'
            ELSE 'gauge' END AS grain
  -- [#1 402(401) 0d029a1a]
  FROM (SELECT * FROM (VALUES
    ('postgres',  'sessions',  'Sessions',          10, 'total',                 'sessions',                          'count',       false,  600,  1),
    ('postgres',  'sessions',  'Sessions',          10, 'active',                'active sessions',                   'count',       false,  600,  2),
    ('postgres',  'sessions',  'Sessions',          10, 'idle_in_txn',           'idle in transaction',               'count',       false,  600,  3),
    ('postgres',  'sessions',  'Sessions',          10, 'waiting_lock',          'waiting on a lock',                 'count',       false,  600,  4),
    ('postgres',  'sessions',  'Sessions',          10, 'connections_pct',       'connections used',                  'pct',         false,  600,  5),
    ('postgres',  'sessions',  'Sessions',          10, 'longest_active_secs',   'longest active statement',          'secs',        false,  600,  6),
    ('postgres',  'sessions',  'Sessions',          10, 'longest_idle_txn_secs', 'longest idle in transaction',       'secs',        false,  600,  7),
    ('postgres',  'sessions',  'Sessions',          10, 'oldest_xmin_age',       'oldest xmin age',                   'xids',        false,  600,  8),
    ('postgres',  'database',  'Database',          20, 'commits_s',             'commits',                           'per_s',       true,   600,  1),
    ('postgres',  'database',  'Database',          20, 'rollbacks_s',           'rollbacks',                         'per_s',       true,   600,  2),
    ('postgres',  'database',  'Database',          20, 'blks_read_s',           'blocks read',                       'per_s',       true,   600,  3),
    ('postgres',  'database',  'Database',          20, 'blks_hit_s',            'blocks hit',                        'per_s',       true,   600,  4),
    ('postgres',  'database',  'Database',          20, 'cache_hit_pct',         'buffer cache hit ratio',            'pct',         true,   600,  5),
    ('postgres',  'database',  'Database',          20, 'tup_read_s',            'tuples read',                       'per_s',       true,   600,  6),
    ('postgres',  'database',  'Database',          20, 'tup_written_s',         'tuples written',                    'per_s',       true,   600,  7),
    ('postgres',  'database',  'Database',          20, 'temp_bytes_s',          'temp bytes',                        'bytes_per_s', true,   600,  8),
    ('postgres',  'database',  'Database',          20, 'deadlocks',             'deadlocks per interval',            'count',       true,   600,  9),
    ('postgres',  'database',  'Database',          20, 'backends',              'backends',                          'count',       true,   600, 10),
    ('postgres',  'server',    'Server',            30, 'checkpoints',           'checkpoints per interval',          'count',       false,  600,  1),
    ('postgres',  'server',    'Server',            30, 'checkpoints_req',       'requested checkpoints per interval', 'count',      false,  600,  2),
    ('postgres',  'server',    'Server',            30, 'buffers_written_s',     'buffers written',                   'per_s',       false,  600,  3),
    ('postgres',  'server',    'Server',            30, 'buffers_alloc_s',       'buffers allocated',                 'per_s',       false,  600,  4),
    ('postgres',  'server',    'Server',            30, 'wal_bytes_s',           'WAL bytes',                         'bytes_per_s', false,  600,  5),
    ('postgres',  'server',    'Server',            30, 'wal_records_s',         'WAL records',                       'per_s',       false,  600,  6),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'read_bytes_s',          'read bytes',                        'bytes_per_s', false, 1800,  1),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'write_bytes_s',         'write bytes',                       'bytes_per_s', false, 1800,  2),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'extend_bytes_s',        'extend bytes',                      'bytes_per_s', false, 1800,  3),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'hits_s',                'buffer hits',                       'per_s',       false, 1800,  4),
    ('postgres',  'io',        'IO (pg_stat_io)',   40, 'fsyncs_s',              'fsyncs',                            'per_s',       false, 1800,  5),
    ('sqlserver', 'requests',  'Requests',          10, 'sessions',              'sessions',                          'count',       false,  600,  1),
    ('sqlserver', 'requests',  'Requests',          10, 'requests',              'requests running',                  'count',       false,  600,  2),
    ('sqlserver', 'requests',  'Requests',          10, 'blocked',               'processes blocked',                 'count',       false,  600,  3),
    ('sqlserver', 'requests',  'Requests',          10, 'heads',                 'blocking chain heads',              'count',       false,  600,  4),
    ('sqlserver', 'requests',  'Requests',          10, 'longest_wait_ms',       'longest wait',                      'ms',          false,  600,  5),
    ('sqlserver', 'cpu',       'CPU',               20, 'sql_pct',               'SQL Server CPU',                    'pct',         false,  600,  1),
    ('sqlserver', 'cpu',       'CPU',               20, 'other_pct',             'other processes CPU',               'pct',         false,  600,  2),
    ('sqlserver', 'cpu',       'CPU',               20, 'total_pct',             'machine CPU',                       'pct',         false,  600,  3),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'batch_s',               'batch requests',                    'per_s',       false,  600,  1),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'transactions_s',        'transactions',                      'per_s',       false,  600,  2),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'compiles_s',            'SQL compilations',                  'per_s',       false,  600,  3),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'recompiles_s',          'SQL re-compilations',               'per_s',       false,  600,  4),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'runnable_tasks',        'runnable tasks',                    'count',       false,  600,  5),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'work_queue',            'work queue',                        'count',       false,  600,  6),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'pending_io',            'pending disk IO',                   'count',       false,  600,  7),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'active_workers',        'active workers',                    'count',       false,  600,  8),
    ('sqlserver', 'scheduler', 'Scheduler',         30, 'current_workers',       'current workers',                   'count',       false,  600,  9),
    ('sqlserver', 'memory',    'Memory',            40, 'ple',                   'page life expectancy',              'secs',        false,  600,  1),
    ('sqlserver', 'memory',    'Memory',            40, 'grants_pending',        'memory grants pending',             'count',       false,  600,  2),
    ('sqlserver', 'memory',    'Memory',            40, 'grants_outstanding',    'memory grants outstanding',         'count',       false,  600,  3),
    ('sqlserver', 'memory',    'Memory',            40, 'total_mb',              'total server memory',               'mb',          false,  600,  4),
    ('sqlserver', 'memory',    'Memory',            40, 'target_mb',             'target server memory',              'mb',          false,  600,  5),
    ('sqlserver', 'memory',    'Memory',            40, 'buffer_pool_mb',        'database cache memory',             'mb',          false,  600,  6),
    ('sqlserver', 'memory',    'Memory',            40, 'plan_cache_mb',         'plan cache memory',                 'mb',          false,  600,  7),
    ('sqlserver', 'memory',    'Memory',            40, 'stolen_mb',             'stolen server memory',              'mb',          false,  600,  8),
    ('sqlserver', 'memory',    'Memory',            40, 'available_mb',          'available physical memory',         'mb',          false,  600,  9),
    ('sqlserver', 'memory',    'Memory',            40, 'os_used_pct',           'physical memory used',              'pct',         false,  600, 10),
    ('any',       'host',      'Host',              90, 'cpu_pct',               'host CPU',                          'pct',         false,  900,  1),
    ('any',       'host',      'Host',              90, 'cpu_iowait_pct',        'host CPU in IO wait',               'pct',         false,  900,  2),
    ('any',       'host',      'Host',              90, 'mem_used_pct',          'host memory used',                  'pct',         false,  900,  3),
    ('any',       'host',      'Host',              90, 'mem_free',              'host memory free',                  'bytes',       false,  900,  4),
    ('any',       'host',      'Host',              90, 'swap_used',             'host swap used',                    'bytes',       false,  900,  5),
    ('any',       'host',      'Host',              90, 'load1',                 'load average (1 min)',              'count',       false,  900,  6)
  -- [#1 402(401) 0d029a1a]
  ) AS v(engine, family, family_label, family_sort, metric, label, unit, per_database, fresh_secs, sort)
  -- task 401 (0152): the SQL Server counters family
  UNION ALL
  SELECT m.engine, m.family, m.family_label, m.family_sort, m.metric, m.label, m.unit, m.per_database, m.fresh_secs, m.sort
    -- [#2 402 0d029a1a]
    FROM pgvigil.mssql_counter_metrics m
  -- task 402 (0153, B24 Fixed 1): the attention capture's client timeouts rate (mssql_attention_points); fresh 10
  -- minutes, so an mssql_xe interval up to 5 minutes keeps its points fresh
  UNION ALL
  SELECT * FROM (VALUES
    ('sqlserver', 'xe', 'Extended Events', 55, 'client_timeouts_per_min',
     'client timeouts per minute (tools, pgvigil and cancels under 1 ms with no statement left out)', 'per_min', false, 600, 1),
    ('sqlserver', 'xe', 'Extended Events', 55, 'client_timeouts_left_out_per_min',
     'attentions left out per minute (SSMS IntelliSense, VS Code metadata, under 1 ms with no statement, Azure Data Studio metadata, pgvigil)',
     'per_min', false, 600, 2),
    -- [#3 402(412) 0d029a1a]
    -- task 412 (0152, B19): SQLMonitor's wait seconds per core per minute (mssql_wait_core_points); a point per wait
    -- read spanning its newest five minutes, so fresh as the per-minute families
    ('sqlserver', 'waits', 'Waits', 56, 'wait_s_per_core_min',
     'wait seconds per core per minute (benign waits and SQLMonitor''s per-core list left out)', 's_core_min', false, 600, 1)
  -- [#5 B6G-N 17e6d3f7]
  ) AS x(engine, family, family_label, family_sort, metric, label, unit, per_database, fresh_secs, sort)
  -- B6G (0166): the Collection family (0166 appends these rows to the live view; 0300 holds them in its text)
  UNION ALL
  SELECT * FROM (VALUES
    ('any', 'collection', 'Collection', 95, 'duration_ms',   'collection duration',        'ms',    true, 7200, 1),
    ('sqlserver', 'collection', 'Collection', 95, 'cpu_ms',        'collection CPU',           'ms',    true, 7200, 2),
    ('sqlserver', 'collection', 'Collection', 95, 'logical_reads', 'collection logical reads', 'count', true, 7200, 3),
    ('any', 'collection', 'Collection', 95, 'failed_pct',    'collection failed',          'pct',   true, 7200, 4),
    ('any', 'collection', 'Collection', 95, 'import_ms',     'collection import duration', 'ms',    true, 7200, 5)
  ) AS y(engine, family, family_label, family_sort, metric, label, unit, per_database, fresh_secs, sort)) AS v;

-- ====================================================================================================================
-- pgvigil.metric_points_0085: base the base's metric_points (0085_alert_rules.sql L115) under the name 0166 gives it (B6G-N's rename)
--   #1 P 402(401) 0d029a1a: 0d029a1a:scripts/proof-mssql-counters-wiring.patch (0190_join_release2.sql hunks, pre blob 40526c2) as pgvigil.metric_points_0085
--   #2 P 402 0d029a1a: 0d029a1a:scripts/proof-mssql-counter-checks-wiring.patch (0190_join_release2.sql hunks, pre blob 2ea63181) as pgvigil.metric_points_0085
--   #3 P 402(412) 0d029a1a: 0d029a1a:scripts/proof-mssql-waits-percore-wiring.patch (0190_join_release2.sql hunks, pre blob 75f3d046) as pgvigil.metric_points_0085
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.metric_points_0085(p_instance_id int, p_family text, p_from timestamptz, p_to timestamptz,
                                                 p_lookback interval DEFAULT interval '15 minutes', p_database text DEFAULT NULL)
RETURNS TABLE (at timestamptz, metric text, value double precision)
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
BEGIN
  IF p_family = 'sessions' THEN
    RETURN QUERY
    SELECT s.snapshot_at, v.metric, v.value
      FROM pgvigil.activity_summary s
      CROSS JOIN LATERAL (VALUES
        ('total', s.total::double precision), ('active', s.active::double precision),
        ('idle_in_txn', s.idle_in_txn::double precision), ('waiting_lock', s.waiting_lock::double precision),
        ('connections_pct', (100.0 * s.total / nullif(s.max_connections, 0))::double precision),
        ('longest_active_secs', s.longest_active_secs::double precision),
        ('longest_idle_txn_secs', s.longest_idle_txn_secs::double precision),
        ('oldest_xmin_age', s.oldest_xmin_age::double precision)) AS v(metric, value)
     WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to AND v.value IS NOT NULL;
  ELSIF p_family = 'database' AND p_database IS NOT NULL THEN
    -- one database's series reads that database's rows alone (dbstats_rate reads every database of the instance
    -- before a filter on the name can apply: 150 databases over 31 days ran past the page's 15 s). The same rule as
    -- dbstats_rate: a delta per read (pgvigil.delta), an interval with a reset gives no point.
    RETURN QUERY
    WITH w AS (
      SELECT d.snapshot_at, d.numbackends,
             extract(epoch FROM d.snapshot_at - lag(d.snapshot_at) OVER k)::int AS interval_secs,
             (d.stats_reset IS DISTINCT FROM lag(d.stats_reset) OVER k) AS reset,
             d.xact_commit, lag(d.xact_commit) OVER k AS p1, d.xact_rollback, lag(d.xact_rollback) OVER k AS p2,
             d.blks_read, lag(d.blks_read) OVER k AS p3, d.blks_hit, lag(d.blks_hit) OVER k AS p4,
             d.tup_returned, lag(d.tup_returned) OVER k AS p5, d.tup_fetched, lag(d.tup_fetched) OVER k AS p6,
             d.tup_inserted, lag(d.tup_inserted) OVER k AS p7, d.tup_updated, lag(d.tup_updated) OVER k AS p8,
             d.tup_deleted, lag(d.tup_deleted) OVER k AS p9, d.temp_bytes, lag(d.temp_bytes) OVER k AS p12,
             d.deadlocks, lag(d.deadlocks) OVER k AS p13
        FROM pgvigil.dbstats d
       WHERE d.instance_id = p_instance_id AND d.datname = p_database
         AND d.snapshot_at > p_from - p_lookback AND d.snapshot_at <= p_to
      WINDOW k AS (PARTITION BY d.dbid ORDER BY d.snapshot_at)
    ), r AS (
      SELECT w.snapshot_at, max(w.interval_secs) AS secs,
             sum(pgvigil.delta(w.xact_commit, w.p1, w.reset)) AS c, sum(pgvigil.delta(w.xact_rollback, w.p2, w.reset)) AS rb,
             sum(pgvigil.delta(w.blks_read, w.p3, w.reset)) AS br, sum(pgvigil.delta(w.blks_hit, w.p4, w.reset)) AS bh,
             sum(pgvigil.delta(w.tup_returned, w.p5, w.reset) + pgvigil.delta(w.tup_fetched, w.p6, w.reset)) AS tr,
             sum(pgvigil.delta(w.tup_inserted, w.p7, w.reset) + pgvigil.delta(w.tup_updated, w.p8, w.reset)
                 + pgvigil.delta(w.tup_deleted, w.p9, w.reset)) AS tw,
             sum(pgvigil.delta(w.temp_bytes, w.p12, w.reset)) AS tb, sum(pgvigil.delta(w.deadlocks, w.p13, w.reset)) AS dl,
             sum(w.numbackends) AS nb
        FROM w
       WHERE w.interval_secs > 0 AND w.snapshot_at > p_from
       GROUP BY w.snapshot_at
      HAVING NOT bool_or(w.reset)
    )
    SELECT r.snapshot_at, v.metric, v.value
      FROM r
      CROSS JOIN LATERAL (VALUES
        ('commits_s', (r.c / r.secs)::double precision), ('rollbacks_s', (r.rb / r.secs)::double precision),
        ('blks_read_s', (r.br / r.secs)::double precision), ('blks_hit_s', (r.bh / r.secs)::double precision),
        ('cache_hit_pct', (100.0 * r.bh / nullif(r.bh + r.br, 0))::double precision),
        ('tup_read_s', (r.tr / r.secs)::double precision), ('tup_written_s', (r.tw / r.secs)::double precision),
        ('temp_bytes_s', (r.tb / r.secs)::double precision), ('deadlocks', r.dl::double precision),
        ('backends', r.nb::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'database' THEN
    RETURN QUERY
    WITH r AS (
      SELECT d.snapshot_at, max(d.interval_secs) AS secs,
             sum(d.xact_commit) AS c, sum(d.xact_rollback) AS rb, sum(d.blks_read) AS br, sum(d.blks_hit) AS bh,
             sum(d.tup_returned + d.tup_fetched) AS tr, sum(d.tup_inserted + d.tup_updated + d.tup_deleted) AS tw,
             sum(d.temp_bytes) AS tb, sum(d.deadlocks) AS dl, sum(d.numbackends) AS nb
        FROM pgvigil.dbstats_rate(p_instance_id, p_from, p_to, p_lookback) d
       WHERE d.interval_secs > 0
       GROUP BY d.snapshot_at
      HAVING NOT bool_or(d.reset)              -- a database reset in this interval: no point, not a dip
    )
    SELECT r.snapshot_at, v.metric, v.value
      FROM r
      CROSS JOIN LATERAL (VALUES
        ('commits_s', (r.c / r.secs)::double precision), ('rollbacks_s', (r.rb / r.secs)::double precision),
        ('blks_read_s', (r.br / r.secs)::double precision), ('blks_hit_s', (r.bh / r.secs)::double precision),
        ('cache_hit_pct', (100.0 * r.bh / nullif(r.bh + r.br, 0))::double precision),
        ('tup_read_s', (r.tr / r.secs)::double precision), ('tup_written_s', (r.tw / r.secs)::double precision),
        ('temp_bytes_s', (r.tb / r.secs)::double precision), ('deadlocks', r.dl::double precision),
        ('backends', r.nb::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'server' THEN
    RETURN QUERY
    SELECT s.snapshot_at, v.metric, v.value
      FROM pgvigil.serverstats_rate(p_instance_id, p_from, p_to, p_lookback) s
      CROSS JOIN LATERAL (VALUES
        ('checkpoints', (s.checkpoints_timed + s.checkpoints_req)::double precision),
        ('checkpoints_req', s.checkpoints_req::double precision),
        -- a version without one of the three counters stores it NULL; all three NULL = no figure, not 0
        ('buffers_written_s', (CASE WHEN num_nonnulls(s.buffers_checkpoint, s.buffers_clean, s.buffers_backend) > 0 THEN
            (coalesce(s.buffers_checkpoint, 0) + coalesce(s.buffers_clean, 0) + coalesce(s.buffers_backend, 0))::numeric / s.interval_secs END)::double precision),
        ('buffers_alloc_s', (s.buffers_alloc::numeric / s.interval_secs)::double precision),
        ('wal_bytes_s', (s.wal_bytes / s.interval_secs)::double precision),
        ('wal_records_s', (s.wal_records::numeric / s.interval_secs)::double precision)) AS v(metric, value)
     WHERE s.interval_secs > 0 AND s.reset IS NOT TRUE AND v.value IS NOT NULL;
  ELSIF p_family = 'io' THEN
    RETURN QUERY
    WITH r AS (
      SELECT o.snapshot_at, max(o.interval_secs) AS secs, sum(o.read_bytes) AS rb, sum(o.write_bytes) AS wb,
             sum(o.extend_bytes) AS eb, sum(o.hits) AS h, sum(o.fsyncs) AS f
        FROM pgvigil.iostats_rate(p_instance_id, p_from, p_to, p_lookback) o
       WHERE o.interval_secs > 0
       GROUP BY o.snapshot_at
      HAVING NOT bool_or(o.reset)              -- an IO row reset in this interval: no point, not a dip
    )
    SELECT r.snapshot_at, v.metric, v.value
      FROM r
      CROSS JOIN LATERAL (VALUES
        ('read_bytes_s', (r.rb / r.secs)::double precision), ('write_bytes_s', (r.wb / r.secs)::double precision),
        ('extend_bytes_s', (r.eb / r.secs)::double precision), ('hits_s', (r.h / r.secs)::double precision),
        ('fsyncs_s', (r.f / r.secs)::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'host' THEN
    RETURN QUERY
    WITH h AS (                                 -- one row per read (two sources of one instance: the higher figure)
      SELECT x.snapshot_at, max(x.cpu_pct) AS cpu_pct, max(x.cpu_iowait_pct) AS cpu_iowait_pct,
             max(100.0 * x.mem_used / nullif(x.mem_total, 0)) AS mem_used_pct, min(x.mem_free) AS mem_free,
             max(x.swap_used) AS swap_used, max(x.load1) AS load1
        FROM pgvigil.host_sample x
       WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
       GROUP BY x.snapshot_at
    )
    SELECT h.snapshot_at, v.metric, v.value
      FROM h
      CROSS JOIN LATERAL (VALUES
        ('cpu_pct', h.cpu_pct::double precision), ('cpu_iowait_pct', h.cpu_iowait_pct::double precision),
        ('mem_used_pct', h.mem_used_pct::double precision), ('mem_free', h.mem_free::double precision),
        ('swap_used', h.swap_used::double precision), ('load1', h.load1::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'requests' THEN
    RETURN QUERY
    SELECT s.snapshot_at, v.metric, v.value
      FROM pgvigil.mssql_requests_summary s
      CROSS JOIN LATERAL (VALUES
        ('sessions', s.sessions::double precision), ('requests', s.requests::double precision),
        ('blocked', s.blocked::double precision), ('heads', s.heads::double precision),
        ('longest_wait_ms', s.longest_wait_ms::double precision)) AS v(metric, value)
     WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to AND v.value IS NOT NULL;
  ELSIF p_family = 'cpu' THEN
    RETURN QUERY
    WITH c AS (                                 -- one row per record time
      SELECT x.snapshot_at, max(x.sql_pct) AS sql_pct, max(x.other_pct) AS other_pct, max(100 - x.idle_pct) AS total_pct
        FROM pgvigil.mssql_cpu_sample x
       WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
       GROUP BY x.snapshot_at
    )
    SELECT c.snapshot_at, v.metric, v.value
      FROM c
      CROSS JOIN LATERAL (VALUES
        ('sql_pct', c.sql_pct::double precision), ('other_pct', c.other_pct::double precision),
        ('total_pct', c.total_pct::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'scheduler' THEN
    RETURN QUERY
    WITH c AS (
      SELECT x.snapshot_at, max(x.batch_s) AS batch_s, max(x.transactions_s) AS transactions_s, max(x.compiles_s) AS compiles_s,
             max(x.recompiles_s) AS recompiles_s, max(x.runnable_tasks) AS runnable_tasks, max(x.work_queue) AS work_queue,
             max(x.pending_io) AS pending_io, max(x.active_workers) AS active_workers, max(x.current_workers) AS current_workers
        FROM pgvigil.mssql_sched_sample x
       WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
       GROUP BY x.snapshot_at
    )
    SELECT c.snapshot_at, v.metric, v.value
      FROM c
      CROSS JOIN LATERAL (VALUES
        ('batch_s', c.batch_s::double precision), ('transactions_s', c.transactions_s::double precision),
        ('compiles_s', c.compiles_s::double precision), ('recompiles_s', c.recompiles_s::double precision),
        ('runnable_tasks', c.runnable_tasks::double precision), ('work_queue', c.work_queue::double precision),
        ('pending_io', c.pending_io::double precision), ('active_workers', c.active_workers::double precision),
        ('current_workers', c.current_workers::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  ELSIF p_family = 'memory' THEN
    RETURN QUERY
    WITH c AS (
      SELECT x.snapshot_at, max(x.ple) AS ple, max(x.grants_pending) AS grants_pending, max(x.grants_outstanding) AS grants_outstanding,
             max(x.total_kb) AS total_kb, max(x.target_kb) AS target_kb, max(x.buffer_pool_kb) AS buffer_pool_kb,
             max(x.plan_cache_kb) AS plan_cache_kb, max(x.stolen_kb) AS stolen_kb, min(x.available_kb) AS available_kb,
             max(x.physical_kb) AS physical_kb
        FROM pgvigil.mssql_memory_sample x
       WHERE x.instance_id = p_instance_id AND x.snapshot_at > p_from AND x.snapshot_at <= p_to
       GROUP BY x.snapshot_at
    )
    SELECT c.snapshot_at, v.metric, v.value
      FROM c
      CROSS JOIN LATERAL (VALUES
        ('ple', c.ple::double precision), ('grants_pending', c.grants_pending::double precision),
        ('grants_outstanding', c.grants_outstanding::double precision),
        ('total_mb', (c.total_kb / 1024.0)::double precision), ('target_mb', (c.target_kb / 1024.0)::double precision),
        ('buffer_pool_mb', (c.buffer_pool_kb / 1024.0)::double precision),
        ('plan_cache_mb', (c.plan_cache_kb / 1024.0)::double precision), ('stolen_mb', (c.stolen_kb / 1024.0)::double precision),
        ('available_mb', (c.available_kb / 1024.0)::double precision),
        ('os_used_pct', (100.0 * (c.physical_kb - c.available_kb) / nullif(c.physical_kb, 0))::double precision)) AS v(metric, value)
     WHERE v.value IS NOT NULL;
  -- [#1 402(401) 0d029a1a]
  ELSIF p_family = 'counters' THEN
    -- task 401 (0152): the SQL Server counters family
    RETURN QUERY SELECT * FROM pgvigil.mssql_counter_points(p_instance_id, p_from, p_to, p_lookback, p_database);
  -- [#2 402 0d029a1a]
  ELSIF p_family = 'xe' THEN
    -- task 402 (0153, B24 Fixed 1): a point per done read of the attention capture, PerformanceMonitor's 3-minute rate
    RETURN QUERY SELECT * FROM pgvigil.mssql_attention_points(p_instance_id, p_from, p_to);
  -- [#3 402(412) 0d029a1a]
  ELSIF p_family = 'waits' THEN
    -- task 412 (0152, B19): a point per stored wait read over its newest five minutes of reads; no scheduler count =
    -- a point with no value (metric_na_reasons says why)
    RETURN QUERY SELECT * FROM pgvigil.mssql_wait_core_points(p_instance_id, p_from, p_to);
  ELSE
    RAISE EXCEPTION 'metric_points: no metric family %', p_family USING ERRCODE = '22023';
  END IF;
END $$;

-- ====================================================================================================================
-- pgvigil.metric_points: base 0085_alert_rules.sql L115
--   #1 T B6G-N 17e6d3f7: 0166_collection_health.sql L838 (merge-base e4af7c3e 0085_alert_rules.sql) - 0166: the wrapper (the collection family; every other family to metric_points_0085)
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.metric_points(p_instance_id int, p_family text, p_from timestamptz, p_to timestamptz,
                                                 p_lookback interval DEFAULT interval '15 minutes', p_database text DEFAULT NULL)
RETURNS TABLE (at timestamptz, metric text, value double precision)
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
BEGIN
  -- [#1 B6G-N 17e6d3f7]
  IF p_family = 'collection' THEN
    -- p_database: one collection's series; NULL = the instance's: each hour's worst collection, per metric (every
    -- metric of the family is worse higher). Each point stamped at its hour's end: an open hour has no point yet.
    RETURN QUERY
    -- [#1 B6G-N 17e6d3f7]
    SELECT v.hour + interval '1 hour', v.metric, max(v.value)
      FROM pgvigil.collection_metric_values(p_instance_id, p_from, p_to, p_database) v
     GROUP BY v.hour, v.metric;
  ELSE
    -- [#1 B6G-N 17e6d3f7]
    RETURN QUERY SELECT x.at, x.metric, x.value FROM pgvigil.metric_points_0085(p_instance_id, p_family, p_from, p_to, p_lookback, p_database) x;
  END IF;
END $$;

-- ====================================================================================================================
-- pgvigil.metric_rule: base 0085_alert_rules.sql L415
--   #1 T S2 09661906: 0154_alert_scope.sql L684 (merge-base ebf9a9c2 0085_alert_rules.sql) - 403a: 0154 re-creates it whole
--   #2 P 402 0d029a1a: 0d029a1a:scripts/proof-mssql-counter-checks-wiring.patch (0190_join_release2.sql hunks, pre blob 2ea63181)
--   #3 H the join (0300) --------: the review's #3 - S2 x 402: 0154 L631-634 dropped alert_rules_live_uq for alert_rules_live_family_uq (op_family), so o takes the threshold family (else a disabled fleet rise / baseline rule is a second off row)
--   merge conflict at arm #2 (402), block 1, resolved by hand: 402's form (the 0153 seed's off fleet rule) with S2's scope-tags text and op_family filter in its e CTE
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.metric_rule(p_instance_id int, p_key text, p_database text DEFAULT NULL)
RETURNS TABLE (rule_id bigint, rule_name text, op text, warning double precision, critical double precision, for_minutes int,
               rule_scope text, rule_target text, rule_database text)
LANGUAGE sql STABLE AS $$
  -- [#2 402 0d029a1a]
  WITH RECURSIVE e AS (
    SELECT e.rule_id, e.name, e.op, e.warning, e.critical, e.for_minutes, e.scope, coalesce(e.tag, e.instance_name, pgvigil.alert_scope_text(e.scope_tags)), e.database
      FROM pgvigil.alert_rules_effective e
     WHERE e.instance_id = p_instance_id AND e.metric = p_key AND e.database IS NOT DISTINCT FROM p_database
       AND e.op_family = 'threshold'   -- S2 (403a, 0154 L692)
     ),
  o AS (       -- the series' live, off fleet rule (one at most: alert_rules_live_uq)
    SELECT r.rule_id, r.name, r.metric, r.op, r.warning, r.critical, r.for_minutes, r.scope, r.database, r.replaces,
           r.created_by, r.client
      FROM pgvigil.alert_rules r
     WHERE r.metric = p_key AND r.scope = 'fleet' AND r.ended_at IS NULL AND NOT r.enabled
       -- [#3 the join (0300) --------]
       AND r.op_family = 'threshold'   -- S2's 0154 L631-634: one live rule per family (alert_rules_live_family_uq)
       -- [#2 402 0d029a1a]
       AND r.database IS NOT DISTINCT FROM p_database),
  ch AS (      -- that rule and each rule it replaces, back to the first (a successor's id is always the higher)
    SELECT o.rule_id, o.replaces, o.created_by, o.client, o.metric FROM o
    UNION ALL
    SELECT a.rule_id, a.replaces, a.created_by, a.client, a.metric
      FROM ch JOIN pgvigil.alert_rules a ON a.rule_id = ch.replaces AND a.rule_id < ch.rule_id)
  SELECT * FROM e
  UNION ALL
  SELECT o.rule_id, coalesce(o.name, o.metric) || ' (off: colours only, no alert)', o.op, o.warning, o.critical,
         o.for_minutes, o.scope, NULL::text, o.database
    FROM o
    JOIN pgvigil.instances i ON i.instance_id = p_instance_id AND i.is_active
    JOIN pgvigil.metric_catalog c ON c.key = o.metric AND c.engine IN (i.engine, 'any')
   WHERE NOT EXISTS (SELECT 1 FROM e)
     AND (   (o.created_by = 'pgvigil' AND o.client = '0153 seed')
          OR (    EXISTS (SELECT 1 FROM ch WHERE ch.replaces IS NULL AND ch.created_by = 'pgvigil' AND ch.client = '0153 seed'
                             AND ch.metric = p_key)
              AND NOT EXISTS (SELECT 1 FROM ch JOIN pgvigil.alert_rule_log l ON l.rule_id = ch.rule_id
                               WHERE l.op = 'enable' AND l.outcome = 'done')))
$$;

-- ====================================================================================================================
-- pgvigil.alert_rule_eval: base 0085_alert_rules.sql L499
--   #1 T S2 09661906: 0154_alert_scope.sql L777 (merge-base ebf9a9c2 0085_alert_rules.sql) - 403a: 0154 re-creates it whole
--   #2 P 402 0d029a1a: 0d029a1a:scripts/proof-mssql-counter-checks-wiring.patch (0190_join_release2.sql hunks, pre blob 2ea63181)
--   #3 H the join (0300) --------: the join file - 0154 drops and creates it (three more columns); 0300 keeps S2's return type, so OR REPLACE (a bare CREATE fails: the function exists after 0154)
--   #4 H the join (0300) --------: the join file - S2 x 402: S2's p holds a level and a rise row per metric and time, so 402's na lookup takes the level row (else 'more than one row returned by a subquery' at every na state)
--   #5 H s2 A17 --------: A17 - the rise arm carries p0.value AS v0 and keeps a row where the point itself has no value
--   merge conflict at arm #2 (402), block 1, resolved by hand: 402's change 1 (a NULL point breaks a run) on S2's read of the kind's points
--   merge conflict at arm #2 (402), block 2, resolved by hand: 402's change 2 (the na state from the floors) with S2's three columns (fam, base, base_days)
-- ====================================================================================================================
-- [#3 the join (0300) --------]
CREATE OR REPLACE FUNCTION pgvigil.alert_rule_eval(p_at timestamptz)
RETURNS TABLE (rule_id bigint, instance_id int, metric text, database text, state text, value double precision,
               threshold double precision, sample_at timestamptz, beyond_since timestamptz,
               crit_beyond boolean, crit_within_at timestamptz, warn_beyond boolean, warn_within_at timestamptz,
               -- [#1 S2 09661906]
               op_family text, baseline double precision, baseline_days int)
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
DECLARE
  g record;
BEGIN
  FOR g IN
    SELECT e.instance_id, c.family, e.database, max(e.for_minutes) AS max_for
      FROM pgvigil.alert_rules_effective e JOIN pgvigil.metric_catalog c ON c.key = e.metric
     GROUP BY e.instance_id, c.family, e.database
  LOOP
    RETURN QUERY
    -- [#1 S2 09661906]
    WITH p0 AS MATERIALIZED (
      SELECT x.at, x.metric, x.value
        FROM pgvigil.metric_points(g.instance_id, g.family, p_at - make_interval(mins => g.max_for + 60), p_at,
                                   interval '1 hour', g.database) x
    -- [#1 S2 09661906]
    ), p AS MATERIALIZED (   -- every sample as a level, and as the rise from the sample before it
      SELECT 'level'::text AS kind, p0.at, p0.metric, p0.value FROM p0
      UNION ALL
      SELECT 'rise'::text, d.at, d.metric, d.value
        -- [#5 s2 A17 --------]
        FROM (SELECT p0.at, p0.metric, p0.value - lag(p0.value) OVER (PARTITION BY p0.metric ORDER BY p0.at) AS value,
                     p0.value AS v0 FROM p0) d
       -- A17: a floored point (no value) keeps its rise row, NULL,
       -- so 'na' and change 1 reach a rises rule; a first point and a point after a floored one still give none
       WHERE d.value IS NOT NULL OR d.v0 IS NULL
    ), lv AS (          -- each rule of this instance, family and series at each level it sets
      -- [#1 S2 09661906]
      SELECT e.rule_id, e.metric AS key, c.metric AS m, CASE e.op WHEN 'below' THEN 'below' ELSE 'above' END AS op,
             CASE e.op_family WHEN 'rise' THEN 'rise' ELSE 'level' END AS kind, e.op_family AS fam,
             e.for_minutes, c.fresh_secs, l.sev,
             CASE WHEN e.op_family = 'baseline' AND b.days = 7 AND b.base IS NOT NULL
                  THEN greatest(l.thr, b.base * (1 + e.band_pct / 100.0)) ELSE l.thr END AS thr,
             CASE WHEN e.op_family = 'baseline' THEN b.base END AS base,
             CASE WHEN e.op_family = 'baseline' THEN coalesce(b.days, 0) END AS base_days
        FROM pgvigil.alert_rules_effective e
        JOIN pgvigil.metric_catalog c ON c.key = e.metric
        -- [#1 S2 09661906]
        LEFT JOIN pgvigil.alert_rule_baseline b
          ON b.rule_id = e.rule_id AND b.instance_id = e.instance_id AND b.database = coalesce(e.database, '')
        CROSS JOIN LATERAL (VALUES ('critical', e.critical), ('warning', e.warning)) AS l(sev, thr)
       WHERE e.instance_id = g.instance_id AND c.family = g.family AND e.database IS NOT DISTINCT FROM g.database
         AND l.thr IS NOT NULL
    ), j AS (
      SELECT lv.*, z.last_at, z.last_value, z.last_within,
             (SELECT min(p2.at) FROM p p2
               -- [#1 S2 09661906]
               WHERE p2.kind = lv.kind AND p2.metric = lv.m AND (z.last_within IS NULL OR p2.at > z.last_within)) AS run_from
        FROM lv
        LEFT JOIN LATERAL (
          SELECT max(p1.at) AS last_at, (array_agg(p1.value ORDER BY p1.at DESC))[1] AS last_value,
                 -- [#2 402 0d029a1a]
                 -- task 402 change 1 of 2: a point with no value (a floored ratio under its floor) is inside every level,
                 -- so it breaks a run beyond (0085 counted it beyond: NOT alert_beyond(op, NULL, thr) is NULL)
                 max(p1.at) FILTER (WHERE p1.value IS NULL OR NOT pgvigil.alert_beyond(lv.op, p1.value, lv.thr)) AS last_within
            -- [#1 S2 09661906]
            FROM p p1 WHERE p1.kind = lv.kind AND p1.metric = lv.m) z ON true
    ), k AS (
      SELECT j.*,
             (j.last_at IS NOT NULL AND p_at - j.last_at <= make_interval(secs => j.fresh_secs)) AS fresh,
             (j.run_from IS NOT NULL AND j.last_at - j.run_from >= make_interval(mins => j.for_minutes)) AS long_enough
        FROM j
    ), x AS (
      -- [#1 S2 09661906]
      SELECT k.rule_id, k.key, k.fam,
             CASE WHEN NOT bool_or(k.fresh) THEN 'nodata'
                  -- [#2 402 0d029a1a]
                  -- task 402 change 2 of 2: the newest fresh point has no value (a floored ratio under its floor,
                  -- 0152's metric_floors): not judged, 'na', before the levels
                  WHEN bool_or(k.fresh AND k.last_value IS NULL) THEN 'na'
                  WHEN bool_or(k.fresh AND k.long_enough) FILTER (WHERE k.sev = 'critical') THEN 'critical'
                  WHEN bool_or(k.fresh AND k.long_enough) FILTER (WHERE k.sev = 'warning') THEN 'warning'
                  WHEN bool_or(k.run_from IS NOT NULL) THEN 'pending'
                  ELSE 'ok' END AS st,
             max(k.last_value) AS last_value, max(k.last_at) AS last_at,
             max(k.thr) FILTER (WHERE k.sev = 'critical') AS crit_thr, max(k.thr) FILTER (WHERE k.sev = 'warning') AS warn_thr,
             min(k.run_from) FILTER (WHERE k.sev = 'critical') AS crit_from, min(k.run_from) FILTER (WHERE k.sev = 'warning') AS warn_from,
             bool_or(k.run_from IS NOT NULL) FILTER (WHERE k.sev = 'critical') AS crit_run,
             max(k.last_within) FILTER (WHERE k.sev = 'critical') AS crit_in,
             bool_or(k.run_from IS NOT NULL) FILTER (WHERE k.sev = 'warning') AS warn_run,
             max(k.last_within) FILTER (WHERE k.sev = 'warning') AS warn_in,
             -- [#1 S2 09661906]
             max(k.base) AS base, max(k.base_days) AS base_days
        FROM k
       -- [#1 S2 09661906]
       GROUP BY k.rule_id, k.key, k.fam
    )
    -- [#2 402 0d029a1a]
    SELECT x.rule_id, g.instance_id, x.key, g.database, x.st,
           -- 'na' (change 2): the value is the floor's input at the same read and the threshold the floor (no floor
           -- row: both NULL)
           CASE WHEN x.st = 'na' THEN (SELECT p3.value FROM p p3 WHERE p3.metric = split_part(f.input_key, '.', 2) AND p3.at = x.last_at
                                                      -- [#4 the join (0300) --------]
                                                      AND p3.kind = 'level')   -- S2's p: a level and a rise row per point
                -- [#2 402 0d029a1a]
                ELSE x.last_value END,
           -- the value and the run of the level the state names (no level reached: the lower one set)
           CASE x.st WHEN 'na' THEN f.floor WHEN 'critical' THEN x.crit_thr WHEN 'warning' THEN x.warn_thr ELSE coalesce(x.warn_thr, x.crit_thr) END,
           x.last_at,
           -- [#2 402 0d029a1a]
           CASE x.st WHEN 'na' THEN NULL WHEN 'critical' THEN x.crit_from WHEN 'warning' THEN x.warn_from ELSE coalesce(x.warn_from, x.crit_from) END,
           -- [#1 S2 09661906]
           x.crit_run, x.crit_in, x.warn_run, x.warn_in, x.fam, x.base, x.base_days
      -- [#2 402 0d029a1a]
      FROM x LEFT JOIN pgvigil.metric_floors f ON f.key = x.key;
  END LOOP;
END $$;

-- ====================================================================================================================
-- pgvigil.metrics_sample_times: base none (new in a slice of this file)
--   #1 T B24d 9bd7f716: 0196_metrics_newest.sql L265 (merge-base ebf9a9c2 none) - 0196: new in B24d
--   #2 D B24d 16d67e88: scripts/b24d-join-lines.sql against 0196 at 9bd7f716 - A15: the counters / xe / waits / collection arms
-- ====================================================================================================================
-- [#1 B24d 9bd7f716]
CREATE OR REPLACE FUNCTION pgvigil.metrics_sample_times(p_ids int[] DEFAULT NULL)
RETURNS TABLE (instance_id int, family text, at timestamptz)
LANGUAGE sql STABLE SET jit = off AS $$
  SELECT i.instance_id, f.family, t.at
    FROM pgvigil.instances i
    CROSS JOIN LATERAL (SELECT DISTINCT c.family FROM pgvigil.metric_catalog c WHERE c.engine IN (i.engine, 'any')) f
    CROSS JOIN LATERAL (SELECT CASE f.family
             -- [#2 B24d 16d67e88]
             WHEN 'sessions'   THEN (SELECT max(x.snapshot_at) FROM pgvigil.activity_summary x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'database'   THEN (SELECT max(x.snapshot_at) FROM pgvigil.dbstats x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'server'     THEN (SELECT max(x.snapshot_at) FROM pgvigil.serverstats x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'io'         THEN (SELECT max(x.snapshot_at) FROM pgvigil.iostats x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'host'       THEN (SELECT max(x.snapshot_at) FROM pgvigil.host_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'requests'   THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_requests_summary x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'cpu'        THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_cpu_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'scheduler'  THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_sched_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'memory'     THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_memory_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'counters'   THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_counter_read x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'xe'         THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_attention_reads x WHERE x.instance_id = i.instance_id AND x.read_done AND x.state = 'running' AND x.snapshot_at <= now())
             WHEN 'waits'      THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_wait_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'collection' THEN (SELECT max(x.hour) + interval '1 hour' FROM pgvigil.collection_health_hour x WHERE x.instance_id = i.instance_id AND x.hour + interval '1 hour' <= now())
           -- [#1 B24d 9bd7f716]
           END AS at) t
   WHERE i.instance_id = ANY (coalesce(p_ids, ARRAY(SELECT x.instance_id FROM pgvigil.instances x WHERE x.is_active)))
     AND t.at IS NOT NULL
$$;

-- ====================================================================================================================
-- pgvigil.import_schema: base 0058_schema.sql L121
--   #1 T A26 5b6bcff0: 0267_mssql_schema.sql L127 (merge-base 32c7aace 0058_schema.sql) - a26-join-lines.sql: the 'end' arm
--   #2 T A26-PG 24b477f4: 0275_schema_sqlbody.sql L26 (merge-base 32c7aace 0058_schema.sql) - a26pg-join-lines.sql (1) hash_prev, (2) the baseline arm
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.import_schema(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  d        record;
  v_db     pgvigil.schema_databases%ROWTYPE;
  v_found  boolean;
  v_base   boolean;
  m        timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_schema'), p_instance_id);

  -- the event trigger's rows: kept once (the read overlaps by an hour); the cursor moves forward only
  FOR m IN SELECT DISTINCT date_trunc('month', (r->>'logged_at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
             FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ddl' AND r->>'logged_at' IS NOT NULL LOOP
    PERFORM pgvigil.ensure_month_partition('schema_ddl_log', m);
  END LOOP;
  INSERT INTO pgvigil.schema_ddl_log (instance_id, snapshot_at, dbid, log_id, datname, event, command_tag, object_type,
                                      schema_name, object_identity, role_name, statement)
  SELECT p_instance_id, (r->>'logged_at')::timestamptz, (r->>'dbid')::bigint, (r->>'log_id')::bigint, r->>'datname',
         r->>'event', r->>'command_tag', r->>'object_type', r->>'schema_name', r->>'object_identity', r->>'role_name',
         r->>'statement'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'ddl' AND r->>'logged_at' IS NOT NULL AND r->>'log_id' IS NOT NULL AND r->>'dbid' IS NOT NULL
  ON CONFLICT DO NOTHING;
  INSERT INTO pgvigil.log_cursor AS c (instance_id, source, read_to)
  SELECT p_instance_id, 'schema_ddl:' || (r->>'datname'),
         max(CASE r->>'kind' WHEN 'ddl' THEN (r->>'logged_at')::timestamptz ELSE (r->>'read_to')::timestamptz END)
    FROM jsonb_array_elements(p_payload) r
   WHERE ((r->>'kind' = 'ddl' AND r->>'logged_at' IS NOT NULL) OR (r->>'kind' = 'ddl_cursor' AND r->>'read_to' IS NOT NULL))
     AND r->>'datname' IS NOT NULL
   GROUP BY r->>'datname'
  ON CONFLICT (instance_id, source) DO UPDATE SET read_to = greatest(c.read_to, EXCLUDED.read_to), updated_at = now();

  CREATE TEMP TABLE pgv_schema_in ON COMMIT DROP AS
  SELECT DISTINCT ON (dbid, kind, identity)
         (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, r->>'object_kind' AS kind, r->>'identity' AS identity,
         r->>'schema_name' AS schema_name, r->>'object_name' AS object_name, r->>'parent' AS parent,
         r->>'definition' AS definition, r->>'owner' AS owner, r->>'acl' AS acl, r->>'hash' AS hash,
         -- [#2 A26-PG 24b477f4]
         r->>'def_hash' AS def_hash, r->>'hash_prev' AS hash_prev
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'obj' AND r->>'dbid' IS NOT NULL AND r->>'object_kind' IS NOT NULL AND r->>'identity' IS NOT NULL
     AND r->>'hash' IS NOT NULL
   ORDER BY dbid, kind, identity;
  -- a new database's objects are not in schema_objects' statistics yet: without these the diff's joins run as nested
  -- loops over the whole snapshot (minutes at the object cap)
  CREATE INDEX ON pgv_schema_in (dbid, kind, identity);
  ANALYZE pgv_schema_in;
  CREATE TEMP TABLE pgv_schema_diff (LIKE pgvigil.schema_changes) ON COMMIT DROP;

  FOR d IN SELECT (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, (r->>'read_at')::timestamptz AS read_at,
                  (r->>'objects')::int AS objects,
                  coalesce(r->>'ddl_log', 'not installed') AS ddl_log, r->>'ddl_log_table' AS ddl_log_table,
                  r->>'ddl_log_note' AS ddl_log_note
             FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'dbid' IS NOT NULL LOOP
    SELECT * INTO v_db FROM pgvigil.schema_databases s WHERE s.instance_id = p_instance_id AND s.dbid = d.dbid;
    v_found := FOUND;
    IF v_found AND v_db.snapshot_at >= p_snapshot_at THEN
      CONTINUE;   -- a late or repeated read: the snapshot is newer already
    END IF;
    v_base := NOT v_found OR NOT v_db.is_present;
    INSERT INTO pgvigil.schema_databases AS s (instance_id, dbid, datname, snapshot_at, read_at, first_read, objects,
                                               ddl_log, ddl_log_table, ddl_log_note, is_present)
    VALUES (p_instance_id, d.dbid, d.datname, p_snapshot_at, d.read_at, p_snapshot_at, d.objects, d.ddl_log,
            d.ddl_log_table, d.ddl_log_note, true)
    ON CONFLICT (instance_id, dbid) DO UPDATE SET datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at,
      read_at = EXCLUDED.read_at,
      first_read = CASE WHEN v_base THEN EXCLUDED.first_read ELSE s.first_read END, objects = EXCLUDED.objects,
      ddl_log = EXCLUDED.ddl_log, ddl_log_table = EXCLUDED.ddl_log_table, ddl_log_note = EXCLUDED.ddl_log_note,
      is_present = true;

    IF NOT v_base THEN
      -- [#2 A26-PG 24b477f4]
      -- A26-PG (0275): a PostgreSQL 14+ SQL-standard body read for the first time (the code before it hashed the
      -- function's empty prosrc): a present stored row whose hash is the read's hash_prev, and not the read's hash,
      -- takes the read's definition, hash and def_hash here, so the diff below records no change for it and the
      -- upsert keeps its last_changed - the upgrade's first read is the body's baseline. Any other difference of the
      -- row (owner, ACL, settings) leaves hash_prev unequal: its change rows are recorded as before.
      UPDATE pgvigil.schema_objects o SET definition = i.definition, hash = i.hash, def_hash = i.def_hash
        FROM pgv_schema_in i
       WHERE o.instance_id = p_instance_id AND o.dbid = d.dbid AND o.is_present
         AND i.dbid = o.dbid AND i.kind = o.kind AND i.identity = o.identity
         AND i.hash_prev IS NOT NULL AND o.hash = i.hash_prev AND o.hash <> i.hash;
      TRUNCATE pgv_schema_diff;
      -- added: not in the stored snapshot, or stored as dropped
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, i.dbid, i.datname, i.kind, i.identity, i.schema_name,
             i.object_name, i.parent, 'added', NULL, NULL, i.definition
        FROM pgv_schema_in i
        LEFT JOIN pgvigil.schema_objects o
          ON o.instance_id = p_instance_id AND o.dbid = i.dbid AND o.kind = i.kind AND o.identity = i.identity
       WHERE i.dbid = d.dbid AND (o.identity IS NULL OR NOT o.is_present);
      -- dropped: present in the stored snapshot, not in this read
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, o.dbid, coalesce(d.datname, o.datname), o.kind, o.identity,
             o.schema_name, o.object_name, o.parent, 'dropped', NULL, o.definition, NULL
        FROM pgvigil.schema_objects o
       WHERE o.instance_id = p_instance_id AND o.dbid = d.dbid AND o.is_present
         AND NOT EXISTS (SELECT 1 FROM pgv_schema_in i WHERE i.dbid = o.dbid AND i.kind = o.kind AND i.identity = o.identity);
      -- changed: one row per attribute that differs
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, i.dbid, i.datname, i.kind, i.identity, i.schema_name,
             i.object_name, i.parent, 'changed', a.attribute, a.before, a.after
        FROM pgv_schema_in i
        JOIN pgvigil.schema_objects o
          ON o.instance_id = p_instance_id AND o.dbid = i.dbid AND o.kind = i.kind AND o.identity = i.identity AND o.is_present
        CROSS JOIN LATERAL (VALUES ('definition', o.definition, i.definition), ('owner', o.owner, i.owner),
                                   ('acl', o.acl, i.acl)) a(attribute, before, after)
       WHERE i.dbid = d.dbid AND o.hash <> i.hash AND a.before IS DISTINCT FROM a.after;
      -- a definition past the cut changed beyond the stored text: its own hash differs, its text does not (whatever
      -- the owner and ACL did); a row stored without def_hash falls back to the whole hash with owner and ACL equal
      INSERT INTO pgv_schema_diff (instance_id, snapshot_at, prev_at, read_at, prev_read_at, dbid, datname, kind, identity, schema_name,
                                   object_name, parent, change, attribute, before, after)
      SELECT p_instance_id, p_snapshot_at, v_db.snapshot_at, d.read_at, v_db.read_at, i.dbid, i.datname, i.kind, i.identity, i.schema_name,
             i.object_name, i.parent, 'changed', 'definition', o.definition, i.definition
        FROM pgv_schema_in i
        JOIN pgvigil.schema_objects o
          ON o.instance_id = p_instance_id AND o.dbid = i.dbid AND o.kind = i.kind AND o.identity = i.identity AND o.is_present
       WHERE i.dbid = d.dbid AND o.hash <> i.hash AND o.definition IS NOT DISTINCT FROM i.definition
         AND CASE WHEN o.def_hash IS NOT NULL AND i.def_hash IS NOT NULL THEN o.def_hash <> i.def_hash
                  ELSE o.owner IS NOT DISTINCT FROM i.owner AND o.acl IS NOT DISTINCT FROM i.acl END;
      -- a table's columns, indexes, constraints, triggers and owned sequences, a view's triggers and a materialized
      -- view's indexes come and go with it: one row, the parent's
      DELETE FROM pgv_schema_diff c
       WHERE c.change IN ('added', 'dropped') AND c.parent IS NOT NULL
         AND EXISTS (SELECT 1 FROM pgv_schema_diff t WHERE t.kind IN ('table', 'view', 'materialized view')
                        AND t.identity = c.parent AND t.change = c.change);
      IF EXISTS (SELECT 1 FROM pgv_schema_diff) THEN
        PERFORM pgvigil.ensure_month_partition('schema_changes', p_snapshot_at);
        INSERT INTO pgvigil.schema_changes SELECT * FROM pgv_schema_diff;
      END IF;
    END IF;

    INSERT INTO pgvigil.schema_objects AS o (instance_id, dbid, kind, identity, datname, schema_name, object_name, parent,
                                             definition, owner, acl, hash, def_hash, first_seen, last_changed, snapshot_at, is_present)
    SELECT p_instance_id, i.dbid, i.kind, i.identity, i.datname, i.schema_name, i.object_name, i.parent, i.definition,
           i.owner, i.acl, i.hash, i.def_hash, p_snapshot_at, CASE WHEN v_base THEN NULL ELSE p_snapshot_at END, p_snapshot_at, true
      FROM pgv_schema_in i WHERE i.dbid = d.dbid
    ON CONFLICT (instance_id, dbid, kind, identity) DO UPDATE SET datname = EXCLUDED.datname,
      schema_name = EXCLUDED.schema_name, object_name = EXCLUDED.object_name, parent = EXCLUDED.parent,
      definition = EXCLUDED.definition, owner = EXCLUDED.owner, acl = EXCLUDED.acl,
      first_seen = CASE WHEN o.is_present AND NOT v_base THEN o.first_seen ELSE EXCLUDED.first_seen END,
      last_changed = CASE WHEN v_base THEN o.last_changed
                          WHEN NOT o.is_present OR o.hash <> EXCLUDED.hash THEN EXCLUDED.snapshot_at
                          ELSE o.last_changed END,
      hash = EXCLUDED.hash, def_hash = EXCLUDED.def_hash, snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.schema_objects o SET is_present = false, snapshot_at = p_snapshot_at
     WHERE o.instance_id = p_instance_id AND o.dbid = d.dbid AND o.is_present
       AND NOT EXISTS (SELECT 1 FROM pgv_schema_in i WHERE i.dbid = o.dbid AND i.kind = o.kind AND i.identity = o.identity);
  END LOOP;

  -- the run's last call ('end'): a database neither read nor in error is dropped, or no longer connectable; its next
  -- read is a new baseline (a database imported by this run's earlier call carries this snapshot_at already)
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'end') THEN
    RETURN;
  END IF;
  UPDATE pgvigil.schema_databases s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present AND s.snapshot_at < p_snapshot_at
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' IN ('db', 'seen') AND (r->>'dbid')::bigint = s.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'schema:' || s.datname);
  -- [#1 A26 5b6bcff0]
  -- A26 (0267): the objects of a database gone from the read go with it (0058 marked the database row only, so its
  -- objects stayed present on the page and purge's NOT is_present line never took them)
  UPDATE pgvigil.schema_objects o SET is_present = false, snapshot_at = p_snapshot_at
    FROM pgvigil.schema_databases sd
   WHERE sd.instance_id = p_instance_id AND NOT sd.is_present
     AND o.instance_id = sd.instance_id AND o.dbid = sd.dbid AND o.is_present;
END $$;

-- ====================================================================================================================
-- pgvigil.import_cq_verify_open, pgvigil.import_cq_verify_sweep: base none (new in the join file)
--   #1 the join 0300 --------: J16-SWEEP - serve's verify sweep (internal/web/actions_verify.go
--      SweepVerifies, at serve's start and hourly; 301b 462531e9) read pgvigil.actions_log directly on the actions door's
--      audit pool, whose login is a member of pgvigil_collector, which apply_roles takes every pgvigil table from: 42501
--      at every start and every hour, and a stopped serve's 'started' verify never ended. Its two reads are the
--      collector's door here, both named import_* so apply_roles makes them SECURITY DEFINER with search_path pinned and
--      grants EXECUTE to pgvigil_collector only. The instance's verify lock stays in Go (SweepVerifies takes it on a
--      session of its own around each instance's sweep). import_cq_verify_sweep has the name and signature a
--      collector-queue verify will re-create (CREATE OR REPLACE ... RETURNS integer): its text then replaces this one
--      with its request-id pairing.
-- ====================================================================================================================
-- [#1 the join 0300 --------]
-- import_cq_verify_open: the SQL Server instances with a 'started' verify and no end of its own - an end: a later row
-- of the same set on the instance with an end's outcome (a 'refused' second click is none) and no other 'started' row
-- of the instance between them (one verify per instance). A row whose instance was removed since (instance_id NULL) is
-- left alone: it cannot be imported.
CREATE OR REPLACE FUNCTION pgvigil.import_cq_verify_open()
RETURNS SETOF integer LANGUAGE sql STABLE AS $$
  SELECT DISTINCT a.instance_id FROM pgvigil.actions_log a
   WHERE a.engine = 'sqlserver' AND a.action = 'verify_backup' AND a.outcome = 'started' AND a.instance_id IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.actions_log e
                      WHERE e.instance_id = a.instance_id AND e.action = 'verify_backup' AND e.target_id = a.target_id
                        AND e.at >= a.at AND e.action_id <> a.action_id
                        AND e.outcome IN ('done', 'failed', 'cut by shutdown', 'ended unknown')
                        AND NOT EXISTS (SELECT 1 FROM pgvigil.actions_log o
                                         WHERE o.instance_id = a.instance_id AND o.action = 'verify_backup'
                                           AND o.outcome = 'started' AND o.action_id <> a.action_id
                                           AND o.at > a.at AND o.at <= e.at))
   ORDER BY 1
$$;

-- import_cq_verify_sweep: for one SQL Server instance, an 'ended unknown' row for each 'started' verify with no end of
-- its own (import_cq_verify_open's pairing), written through import_mssql_actions_log; how many. The caller holds the
-- instance's verify lock, so no verify runs there (whatever the row's age). An instance removed since the open read
-- (its rows' instance_id is NULL now) has nothing to end: 0, no error.
CREATE OR REPLACE FUNCTION pgvigil.import_cq_verify_sweep(p_instance_id integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  v_engine text;
  v_rows   jsonb;
BEGIN
  SELECT engine INTO v_engine FROM pgvigil.instances WHERE instance_id = p_instance_id;
  IF NOT FOUND THEN
    RETURN 0;
  END IF;
  IF v_engine IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_cq_verify_sweep: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  SELECT jsonb_agg(jsonb_build_object(
           'instance_name', a.instance_name, 'ui_user', a.ui_user, 'client', a.client, 'action', 'verify_backup',
           'target', a.target, 'target_id', a.target_id, 'reason', a.reason, 'outcome', 'ended unknown',
           'detail', 'ended unknown: serve stopped (no end was written for the verify started '
                     || to_char(a.at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')
                     || ' UTC, and no verify holds the instance''s lock)',
           'statement', a.statement) ORDER BY a.at, a.action_id)
    INTO v_rows
    FROM pgvigil.actions_log a
   WHERE a.instance_id = p_instance_id AND a.engine = 'sqlserver' AND a.action = 'verify_backup' AND a.outcome = 'started'
     AND NOT EXISTS (SELECT 1 FROM pgvigil.actions_log e
                      WHERE e.instance_id = a.instance_id AND e.action = 'verify_backup' AND e.target_id = a.target_id
                        AND e.at >= a.at AND e.action_id <> a.action_id
                        AND e.outcome IN ('done', 'failed', 'cut by shutdown', 'ended unknown')
                        AND NOT EXISTS (SELECT 1 FROM pgvigil.actions_log o
                                         WHERE o.instance_id = a.instance_id AND o.action = 'verify_backup'
                                           AND o.outcome = 'started' AND o.action_id <> a.action_id
                                           AND o.at > a.at AND o.at <= e.at));
  IF v_rows IS NULL THEN
    RETURN 0;
  END IF;
  PERFORM pgvigil.import_mssql_actions_log(p_instance_id, now(), v_rows);
  RETURN jsonb_array_length(v_rows);
END $$;

-- ====================================================================================================================
-- pgvigil.apply_roles: base 0110_join_release.sql L401
--   #1 P B2a-N2 8aecbb2b: 8aecbb2b:scripts/azuredb-hour-wiring.patch (0110_join_release.sql hunks, pre blob dc6e79e2)
--   #2 P 413 7184f8ea: 7184f8ea:scripts/proof-mssql-index-depth-wiring.patch (0110_join_release.sql hunks, pre blob 68128c5)
--   #3 H PARQUET 16659e64: scripts/parquet-join-lines.sql L4-10 (line 1) - export_run_record / export_off owner-only, then their GRANT to pgvigil_exporter
--   #4 H 81-AGENT 654a9cd5: scripts/agent-join-lines.sql L4-18 (line 1) - the agent's eleven owner-only, then the seven agent_investigation_* to pgvigil_agent (renamed pgvigil_investigator at AGENTROLE 44c8c56f)
--   #5 H 81-AGENT 654a9cd5: scripts/agent-join-lines.sql L25-30 (line 3); CQ-A 322675cc 0200 L36-37 makes pgvigil_requester - the queue-mode serve writes investigation asks through pgvigil_requester (the review's #2)
--   #6 H the join 0300 --------: the 18 tests: TestSchemaMissingIsTheCollectorsDoor, TestReaderRunsNoOtherSecurityDefiner - no bracket in a comment inside the owner-only list; findings_history_partition owner-only (its DDL is the owner's; the alerter keeps its grant)
--   merge conflict at arm #2 (413), block 1, resolved by hand: owner-only list = the union (mssql_index_depth_purge, mssql_fragmentation_stale added)
-- ====================================================================================================================
CREATE OR REPLACE FUNCTION pgvigil.apply_roles()
 RETURNS void
 LANGUAGE plpgsql
AS $$
DECLARE
  f record;
  t record;
BEGIN
  REVOKE ALL ON SCHEMA pgvigil FROM PUBLIC;
  GRANT USAGE ON SCHEMA pgvigil TO pgvigil_collector, pgvigil_reader, pgvigil_auth;

  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'pgvigil'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', f.sig);
    IF f.proname LIKE 'import\_%' OR f.proname IN ('ensure_instance', 'log_collection', 'schema_latest', 'schema_missing', 'log_cursor', 'mssql_hadr_cursor') THEN
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
    pgvigil.agent_investigation_journal_done(bigint, bigint, int, text) TO pgvigil_investigator;

  -- [#5 81-AGENT 654a9cd5]
  -- the agent door x the request queue (0268 x 0200): agent-join-lines.sql 3 granted the request queue's role
  -- pgvigil_requester import_investigation_request and import_investigation_event for a queue-mode serve's asks. NOT IN
  -- j16 (J16-RUNGUARD OP CLOSE, the join's review 6 #2): a queue-mode serve offers no investigations (q_investigate.go
  -- investigationOff), and with them that role could file asks under any ui_user (the repository's ask limits used up
  -- for every user) and close another user's ask under any closed_by; a later release grants the queue's ask path with
  -- guards of its own. 0268's import_investigation_event writes run lines for a member of pgvigil_collector only (the
  -- actions door's audit login; J16-RUNGUARD).

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

-- ====================================================================================================================
-- pg_threshold_keys: B24h's two keys at a SQL Server instance (b24h-join-lines.sql line 4, in the engines model)
--   #E2 H B24H-STREAKS c937e891: scripts/b24h-join-lines.sql L34-35 (line 4). B24H's 0254 inserts round_trip_time and
--       ping_time with no engines value (its branch has no 0142); on the joined tree 0142's DEFAULT '{postgres}' applies, so
--       import_pg_threshold refuses them at a SQL Server instance ('no PostgreSQL instance'). Line 4 asked for them there
--       (at the instance level); in the HA candidate's engines model that is this row, not a code line (taken).
--       The engines list from B24h's own code and docs (c937e891): b24h-join-lines.sql L34-35 ('a SQL Server instance's own
--       level takes B24h's keys too'); internal/repo/sql/0254_probe.sql L136 + L144 (collector_probe_thresholds: the two keys in
--       force for EVERY active instance, read from pgvigil.instances with no engine filter); docs/alerts.md L102-103 (settable per
--       root, tag or instance, no engine named); the keys' levels {root,tag,instance} (0254 L112-113), so no database level.
--       proof row: B24h's two keys accepted on a SQL Server instance
-- ====================================================================================================================
UPDATE pgvigil.pg_threshold_keys SET engines = '{postgres,sqlserver}' WHERE key IN ('round_trip_time', 'ping_time');

-- ====================================================================================================================
-- 402's two statements beside metric_rule and alert_rule_eval in its 0190 block (the review's #1): the na state's CHECK and the enable index
--   #E3 P 402 0d029a1a: scripts/proof-mssql-counter-checks-wiring.patch, its 0190 hunk @@ -1021,3 +1037,136 (the block's lines 17 and 59-61): alert_rule_eval returns 'na' (change 2) and S2's alert_rules_run stores it (0154 ELSE
--       j.state): without the CHECK every rule pass with a floored metric under its floor fails; the index serves metric_rule's
--       alert_rule_log reads. No 0300 object: they may stay in 0190 instead (the amendment drops only 0300 objects' hunks)
-- ====================================================================================================================
-- [#E3 402 0d029a1a]
CREATE INDEX IF NOT EXISTS alert_rule_log_enable_idx ON pgvigil.alert_rule_log (rule_id) WHERE op = 'enable' AND outcome = 'done';
ALTER TABLE pgvigil.alert_rule_state DROP CONSTRAINT IF EXISTS alert_rule_state_state_check;
ALTER TABLE pgvigil.alert_rule_state ADD CONSTRAINT alert_rule_state_state_check
  CHECK (state IN ('ok', 'pending', 'warning', 'critical', 'nodata', 'na'));

-- ====================================================================================================================
-- darling_alert_findings' comment (the review's #5)
--   #E4 base 40762a29 0118_darling_alerts.sql L154 (L1 left out replay lag and the AG secondary) + 405 2370bd1c
--       proof-pm313-rules-wiring.patch L222 ('task 405', the PostgreSQL poison wait); its 'replay lag' / 'an AG secondary behind' left out (F4)
-- ====================================================================================================================
-- [#E4 405 2370bd1c]
COMMENT ON VIEW pgvigil.darling_alert_findings IS 'PerformanceMonitor''s alert defaults as findings (task 177 D30, task 405): dead tuples, slot WAL, a volume under 5 GB free, the runnable queue per scheduler, long-running requests, a server unreachable, the PostgreSQL poison wait.';

-- ====================================================================================================================
-- actions_log's three CHECKs, re-created once with every slice's kinds
--   #E1 base 40762a29 0157_qs_plans.sql L454-459: postgres cancel terminate explain_analyze hypo_index job_stop job_start;
--       sqlserver kill job_start job_stop plan_evict; no pid explain_analyze hypo_index job_start job_stop plan_evict
--   #E1 H INV(301b) 4c155a56: 0191_backup_history.sql L413-420 and scripts/inv-301b-join-lines.sql L21-25 (line 3):
--       sqlserver verify_backup; no pid verify_backup; outcome started, cut by shutdown, ended unknown
--   #E1 H B9c e001dd80: 0194_job_enable_disable.sql L47-52 and scripts/b9c-join-lines.sql L6-11: job_enable, job_disable on
--       both engines and among the no-pid kinds
--   #E1 CQ-A 322675cc: scripts/cq-join-lines.sql L19-22: no kind (its audit rows are action_requests')
-- ====================================================================================================================
-- [#E1 INV(301b) 4c155a56 + B9c e001dd80] ACCESS EXCLUSIVE on actions_log while each CHECK is checked (as 0191 / 0194)
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_action_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_action_check CHECK (
     (engine = 'postgres' AND action IN ('cancel', 'terminate', 'explain_analyze', 'hypo_index', 'job_stop', 'job_start', 'job_enable', 'job_disable'))
  OR (engine = 'sqlserver' AND action IN ('kill', 'job_start', 'job_stop', 'plan_evict', 'verify_backup', 'job_enable', 'job_disable')));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_pid_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_pid_check CHECK (pid IS NOT NULL OR action IN ('explain_analyze', 'hypo_index', 'job_start', 'job_stop', 'plan_evict', 'verify_backup', 'job_enable', 'job_disable'));
ALTER TABLE pgvigil.actions_log DROP CONSTRAINT IF EXISTS actions_log_outcome_check;
ALTER TABLE pgvigil.actions_log ADD CONSTRAINT actions_log_outcome_check CHECK (outcome IN ('done', 'refused', 'failed', 'started', 'cut by shutdown', 'ended unknown'));

