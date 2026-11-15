-- 0153: checks over SQL Server's performance counters (task 402, B4): twenty fleet alert rules on the 'counters'
-- metrics of 0152, seeded OFF; and B24 Fixed 1 (the section at the end): the attention capture's client timeouts rate,
-- its reads table and its rule, seeded OFF too. Each is a rule of 0085 like any other: a DBA switches it on (the Alert rules page,
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
--   - client timeouts (B24 Fixed 1): PerformanceMonitor's '>= 10' / '>= 60' a minute become above 9.999 / 59.999 on a
--     rate rounded to 2 places as it rounds it; the rate counts the rows the reads stored, not its event_counter
--     change scaled by the stored share (a full ring buffer undercounts a storm); the floors only, no per-server
--     baseline; pgvigil's own reads left out (the section at the end names each).
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

-- ---- B24 Fixed 1: client timeouts (attentions) -----------------------------------------------------------------------
-- PerformanceMonitor 3.13.0 (MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC): the Client Timeouts alert's rate
-- (PerformanceMonitor.Alerting/AttentionEvaluator.cs L136-141, L311-325, L417-421) and its left-out events
-- (PerformanceMonitor.Common/AttentionWindowSql.cs L44-114; CHANGELOG #7061, #6552, #6856), over 0065's attention capture.
--   mssql_attention_reads  one row per mssql_xe read of the attention capture, written by a trigger on mssql_xe_state:
--     read_done when the read took the session's events (new_events set; a run whose time was up before the read, or a
--     failed read, sets none), the session's state at that read, its event_counter and the events it missed. A plain
--     table, purged by snapshot_at (purge(): WIRING): a monthly partition made inside 0065's import, after the import has
--     locked its five partitioned parents, could deadlock with purge()'s drops.
--   mssql_attention_left_out(program, statement, interrupt_us)  NULL = the event counts, else the reason, in
--     PerformanceMonitor's order: SSMS IntelliSense and the VS Code mssql metadata names first; then a cancel under 1 ms
--     (a NULL duration counts) of any other application; then Azure Data Studio's two metadata statement shapes of an
--     event not already short; then pgvigil's own reads (the collector's app name 'pgvigil', a pgvigil departure).
--   mssql_attention_points(instance, from, to)  per done read R of a running session in (from, to]: the base B = the
--     newest done read at or before R - 3 minutes, else the oldest done read before R (a short history), both within
--     the 60 minutes before R (PerformanceMonitor's ReadLookbackMinutes: after a gap the first read back gives no point
--     and the next one's base is it); none = no point. client_timeouts_per_min = the counted rows stored in (B, R] over
--     greatest(1, the minutes from B to R), rounded to 2 places; client_timeouts_left_out_per_min the same for the
--     rows left out. Each stored row is judged once, its counts summed per read that stored it, then per span. A read
--     that was not done only widens the next span; its stored rows count there.
-- The departures: a rule's 'above' is strict and PerformanceMonitor's bars are '>=' (the seed's 9.999 / 59.999, on a
-- rate rounded to 2 places as PerformanceMonitor rounds it: 9.995 reads 10.00 and fires); the
-- rate counts the rows the reads stored (a ring buffer that dropped events between reads undercounts; missed_events
-- keeps the count per read); the floors only (PerformanceMonitor's 3 x / 10 x a server's p99.9 needs a baseline the
-- rule engine has not); pgvigil's own reads are left out.
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_attention_reads (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at    timestamptz NOT NULL,
  state          text NOT NULL,
  read_done      boolean NOT NULL,
  new_events     bigint,
  counter        bigint,
  missed_events  bigint,
  PRIMARY KEY (instance_id, snapshot_at)
);

-- purge() deletes the reads by snapshot_at alone (the key leads with instance_id)
CREATE INDEX IF NOT EXISTS mssql_attention_reads_at_idx ON pgvigil.mssql_attention_reads (snapshot_at);

-- the rows of a span by the read that stored them (mssql_attentions is partitioned by event_at; its key leads with it)
CREATE INDEX IF NOT EXISTS mssql_attentions_read_idx ON pgvigil.mssql_attentions (instance_id, snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.mssql_attention_read_log() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- one row per read: 0065's upsert keeps only a newer read, so a second import of one read's state row changes
  -- nothing and fires no trigger (ON CONFLICT is a guard only)
  INSERT INTO pgvigil.mssql_attention_reads AS a (instance_id, snapshot_at, state, read_done, new_events, counter, missed_events)
  VALUES (NEW.instance_id, NEW.snapshot_at, NEW.state, NEW.new_events IS NOT NULL, NEW.new_events, NEW.counter, NEW.missed_events)
  ON CONFLICT (instance_id, snapshot_at) DO UPDATE
     SET state = EXCLUDED.state, read_done = EXCLUDED.read_done, new_events = EXCLUDED.new_events,
         counter = EXCLUDED.counter, missed_events = EXCLUDED.missed_events;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS mssql_attention_read_log ON pgvigil.mssql_xe_state;
CREATE TRIGGER mssql_attention_read_log AFTER INSERT OR UPDATE ON pgvigil.mssql_xe_state
  FOR EACH ROW WHEN (NEW.capture = 'attention') EXECUTE FUNCTION pgvigil.mssql_attention_read_log();

CREATE OR REPLACE FUNCTION pgvigil.mssql_attention_left_out(p_program text, p_statement text, p_interrupt_us bigint)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    -- ExcludedAppPredicate: SSMS starts with the prefix and, trailing blanks ignored, ends with the suffix, any case
    WHEN p_program ILIKE 'Microsoft SQL Server Management Studio%' AND rtrim(p_program) ILIKE '%IntelliSense'
      THEN 'SSMS IntelliSense'
    -- VsCodeMetadataApps: a closed list, trimmed, any case ('vscode-mssql' itself stays counted)
    WHEN lower(trim(p_program)) IN ('vscode-mssql-generalconnection', 'vscode-mssql-generalconnection-languageservice',
                                    'vscode-mssql-objectexplorer', 'vscode-mssql-objectexplorer-languageservice',
                                    'vscode-mssql-languageservice')
      THEN 'VS Code mssql metadata'
    -- MinInterruptDurationUs 1000: a NULL duration is not under it
    WHEN p_interrupt_us < 1000 THEN 'under 1 ms'
    -- AzdataMetadataPredicate: azdata's query editor shares the name, so only the two SMO shapes
    WHEN lower(trim(p_program)) = 'azdata' AND (ltrim(p_statement) ILIKE 'create table #sver%' OR p_statement ILIKE '% as clmns%')
      THEN 'Azure Data Studio metadata'
    -- pgvigil's own: the collector connects as 'pgvigil' (internal/mssql/mssql.go), its run timeouts send attentions too
    WHEN lower(trim(p_program)) = 'pgvigil' THEN 'pgvigil''s own reads'
  END
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_attention_points(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (at timestamptz, metric text, value double precision)
LANGUAGE sql STABLE AS $$
  WITH r AS (
    SELECT a.snapshot_at AS at
      FROM pgvigil.mssql_attention_reads a
     WHERE a.instance_id = p_instance_id AND a.snapshot_at > p_from AND a.snapshot_at <= p_to
       AND a.read_done AND a.state = 'running'),
  b AS (
    -- OldestTaken: the reads newest first until the span from the read before the oldest taken one reaches 3 minutes,
    -- over the 60 minutes before R that PerformanceMonitor reads back (ReadLookbackMinutes)
    SELECT r.at,
           coalesce((SELECT max(x.snapshot_at) FROM pgvigil.mssql_attention_reads x
                      WHERE x.instance_id = p_instance_id AND x.read_done
                        AND x.snapshot_at <= r.at - interval '3 minutes' AND x.snapshot_at >= r.at - interval '60 minutes'),
                    (SELECT min(x.snapshot_at) FROM pgvigil.mssql_attention_reads x
                      WHERE x.instance_id = p_instance_id AND x.read_done
                        AND x.snapshot_at < r.at AND x.snapshot_at >= r.at - interval '60 minutes')) AS base_at
      FROM r),
  -- each stored row judged once, its counts per read that stored it, over the reach of every span; an event stored
  -- more than a day before its read's span begins (a ring buffer kept it that long) is not a client timeout of it
  s AS (
    SELECT e.snapshot_at,
           count(*) FILTER (WHERE w.why IS NULL) AS counted,
           count(*) FILTER (WHERE w.why IS NOT NULL) AS left_out
      FROM pgvigil.mssql_attentions e
      CROSS JOIN LATERAL (SELECT pgvigil.mssql_attention_left_out(e.program_name, e.statement, e.interrupt_us) AS why) w
     WHERE e.instance_id = p_instance_id
       AND e.snapshot_at > (SELECT min(b.base_at) FROM b) AND e.snapshot_at <= (SELECT max(b.at) FROM b)
       AND e.event_at > (SELECT min(b.base_at) FROM b) - interval '1 day' AND e.event_at <= (SELECT max(b.at) FROM b)
     GROUP BY e.snapshot_at),
  c AS (
    SELECT b.at, b.base_at, coalesce(sum(s.counted), 0) AS counted, coalesce(sum(s.left_out), 0) AS left_out
      FROM b LEFT JOIN s ON s.snapshot_at > b.base_at AND s.snapshot_at <= b.at
     WHERE b.base_at IS NOT NULL
     GROUP BY b.at, b.base_at)
  SELECT c.at, m.metric,
         round((m.n / greatest(1.0, extract(epoch FROM c.at - c.base_at) / 60.0))::numeric, 2)::double precision
    FROM c CROSS JOIN LATERAL (VALUES ('client_timeouts_per_min', c.counted::numeric),
                                      ('client_timeouts_left_out_per_min', c.left_out::numeric)) AS m(metric, n)
   ORDER BY 1, 2
$$;

-- the seed: its own statement (the counters' list above is guarded by 0152's metric list), the same rule: only when the
-- fleet never had a rule on the metric, live or ended; one log row
WITH made AS (
  INSERT INTO pgvigil.alert_rules (name, metric, op, warning, critical, for_minutes, scope, note, enabled, created_by,
                                   created_at, client)
  SELECT 'SQL Server: client timeouts (attentions)', 'xe.client_timeouts_per_min', 'above', 9.999, 59.999, 0, 'fleet',
         'PerformanceMonitor 3.13.0''s Client Timeouts floors: 10 a minute warning, 60 critical, over the newest 3 minutes '
         || 'of reads (its bars are >=; a rule''s above is strict, so 9.999 / 59.999). SSMS IntelliSense, the VS Code mssql '
         || 'metadata connections, cancels under 1 ms, Azure Data Studio''s metadata statements and pgvigil''s own reads '
         || 'are left out. Seeded off: PerformanceMonitor turned it on after a measured week of field data and a per-server '
         || 'baseline; pgvigil has neither.',
         false, 'pgvigil', now(), '0153 seed'
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.alert_rules r WHERE r.metric = 'xe.client_timeouts_per_min' AND r.scope = 'fleet')
  RETURNING rule_id, metric, name
)
INSERT INTO pgvigil.alert_rule_log (at, ui_user, client, op, rule_id, metric, outcome, detail)
SELECT now(), 'pgvigil', '0153 seed', 'seed', m.rule_id, m.metric, 'done', m.name || ': seeded off by the upgrade (0153)'
  FROM made m;
