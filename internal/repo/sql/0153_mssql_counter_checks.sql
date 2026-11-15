-- 0153: checks over SQL Server's performance counters (task 402, B4): twenty fleet alert rules on the 'counters'
-- metrics of 0152, seeded OFF. Each is a rule of 0085 like any other: a DBA switches it on (the Alert rules page,
-- or an enabled rule at a tag or an instance that is narrower), edits its thresholds or ends it, every step audited.
-- Until then the Metrics grid colours the counter by the seeded thresholds (the join file's metric_rule: a seeded
-- rule colours whether it is on or off; it notifies only when on).
--
-- Sources (clickthrough/audit-sqltools-join.md B4): SQLWATCH's default checks (Script.PostDeployment-
-- CreateDefaultChecks.sql L456-1127: CHK#12-#25, CHK#29-#33; CTR#10, CTR#28, OVW#93, PBI#5) and Zabbix's MSSQL
-- template (zbx:873-881 FREE_LIST_STALLS.MAX 2, zbx:1061-1069 LAZY_WRITES.MAX 20: Z92, Z93). The departures:
--   - 'above' is strictly greater (0085): SQLWATCH's '>= 1' lock waits become above 0.999 (CHK#24).
--   - lock timeouts judge 'Lock Timeouts (timeout > 0)/sec': a NOWAIT or LOCK_TIMEOUT 0 probe is not a fault (F18).
--   - read-ahead is a percentage of page reads (SQLWATCH compares a 0-1 fraction with 20 / 25 and never fires: D3).
--   - the buffer cache hit ratio warns under 90 with no critical (a weak signal: D4).
--   - page life expectancy is judged per 4 GB of the lowest memory node's database pages (300 s per 4 GB, D5 / F19).
--   - a ratio under its denominator's floor is 0 (0152's metric_points): a quiet server never trips a ratio (F21).
--   - page reads, page writes and lock requests measure volume, not a fault: their notes say so (F21).
--
-- The seed (F22): a rule is written only when the fleet has never had a rule on that metric, live or ended - an
-- upgrade never brings back a rule a DBA ended or replaced, and a re-run adds nothing. created_by 'pgvigil' with the
-- client '0153 seed' marks a seeded row (the join file's metric_rule reads that mark); each seed writes one
-- alert_rule_log row. The metric keys are frozen: a rule names its metric by key.

WITH seed (name, metric, op, warning, critical, for_minutes, note) AS (VALUES
  ('SQL Server: full scans per index search', 'counters.full_scans_per_search', 'above', 0.001, 0.01, 15,
   'SQLWATCH CHK#12. Full scans per index search, 0 under 10 index searches a second.'),
  ('SQL Server: compilations per 100 batches', 'counters.compiles_per_100_batches', 'above', 10, 15, 15,
   'SQLWATCH CHK#13. SQL Compilations per 100 Batch Requests, 0 under 1 batch a second.'),
  ('SQL Server: re-compilations per 100 compilations', 'counters.recompiles_per_100_compiles', 'above', 10, 15, 15,
   'SQLWATCH CHK#14. SQL Re-Compilations per 100 SQL Compilations, 0 under 1 compilation a second.'),
  ('SQL Server: page splits per 100 batches', 'counters.page_splits_per_100_batches', 'above', 20, 25, 15,
   'SQLWATCH CHK#15. Page Splits per 100 Batch Requests, 0 under 1 batch a second.'),
  ('SQL Server: free list stalls', 'counters.free_list_stalls_s', 'above', 2, 5, 5,
   'SQLWATCH CHK#16, Zabbix FREE_LIST_STALLS.MAX 2. Requests that waited for a free buffer page, per second.'),
  ('SQL Server: lazy writes', 'counters.lazy_writes_s', 'above', 20, 25, 5,
   'SQLWATCH CHK#17, Zabbix LAZY_WRITES.MAX 20. Buffers the lazy writer flushed to free memory, per second.'),
  ('SQL Server: page reads', 'counters.page_reads_s', 'above', 90, 120, 15,
   'SQLWATCH CHK#18. Measures volume, not a fault: switch it on with a threshold fitted to this server.'),
  ('SQL Server: page lookups per batch', 'counters.page_lookups_per_batch', 'above', 100, 120, 15,
   'SQLWATCH CHK#19. Buffer page lookups per Batch Request, 0 under 1 batch a second.'),
  ('SQL Server: page writes', 'counters.page_writes_s', 'above', 90, 120, 15,
   'SQLWATCH CHK#20. Measures volume, not a fault: switch it on with a threshold fitted to this server.'),
  ('SQL Server: average lock wait', 'counters.avg_lock_wait_ms', 'above', 500, 1000, 15,
   'SQLWATCH CHK#21. Locks _Total Average Wait Time over its base: ms per lock wait, 0 with no wait in the read.'),
  ('SQL Server: lock requests', 'counters.lock_requests_s', 'above', 1000, 1200, 15,
   'SQLWATCH CHK#22. Measures volume, not a fault: switch it on with a threshold fitted to this server.'),
  ('SQL Server: lock timeouts', 'counters.lock_timeouts_gt0_s', 'above', 0, 1, 15,
   'SQLWATCH CHK#23 on Lock Timeouts (timeout > 0)/sec: a NOWAIT or LOCK_TIMEOUT 0 probe is not counted.'),
  ('SQL Server: lock waits', 'counters.lock_waits_s', 'above', 0.1, 0.999, 15,
   'SQLWATCH CHK#24 (its critical is 1 or more a second; a rule''s above is strict, so 0.999).'),
  ('SQL Server: read-ahead share of page reads', 'counters.readahead_pct', 'above', 20, 25, 15,
   'SQLWATCH CHK#25 as a percentage. Read-ahead is most reads during scans; for a DBA who wants to see scans.'),
  ('SQL Server: buffer cache hit ratio', 'counters.buffer_cache_hit_pct', 'below', 90, NULL, 15,
   'SQLWATCH CHK#29, CTR#10, OVW#93, PBI#5. A weak signal on its own: read it beside page life expectancy.'),
  ('SQL Server: page life expectancy per 4 GB', 'counters.ple_per_4gb', 'below', 300, 200, 15,
   'SQLWATCH CHK#30 scaled: seconds per 4 GB of the lowest memory node''s database pages (300 s per 4 GB).'),
  ('SQL Server: logins', 'counters.logins_s', 'above', 2, 5, 15,
   'SQLWATCH CHK#31. Logins a second; a pool that does not reuse its connections shows here.'),
  ('SQL Server: kill-connection errors', 'counters.errors_kill_s', 'above', 0, 1, 0,
   'SQLWATCH CHK#32, Prometheus S20. Errors severe enough to end the connection (severity 20 and up).'),
  ('SQL Server: database offline errors', 'counters.errors_offline_s', 'above', 0, 1, 0,
   'SQLWATCH CHK#32. Errors that took a database offline.'),
  ('SQL Server: log growths', 'counters.log_growths', 'above', 0, NULL, 0,
   'SQLWATCH CHK#33, CTR#28. A transaction log grew in the read (every database summed); presize the log.')
), made AS (
  INSERT INTO pgvigil.alert_rules (name, metric, op, warning, critical, for_minutes, scope, note, enabled, created_by,
                                   created_at, client)
  SELECT s.name, s.metric, s.op, s.warning, s.critical, s.for_minutes, 'fleet', s.note, false, 'pgvigil', now(), '0153 seed'
    FROM seed s
   -- 0152's metric list (the join file adds it to metric_catalog, after this file): a key it lacks is never seeded
   WHERE EXISTS (SELECT 1 FROM pgvigil.mssql_counter_metrics m WHERE m.family || '.' || m.metric = s.metric)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_rules r WHERE r.metric = s.metric AND r.scope = 'fleet')
  RETURNING rule_id, metric, name
)
INSERT INTO pgvigil.alert_rule_log (at, ui_user, client, op, rule_id, metric, outcome, detail)
SELECT now(), 'pgvigil', '0153 seed', 'seed', m.rule_id, m.metric, 'done', m.name || ': seeded off (task 402)'
  FROM made m;
