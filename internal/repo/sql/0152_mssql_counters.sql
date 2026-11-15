-- 0152: the SQL Server counter list made configurable, the base arithmetic, the counters the tools agree pgvigil
-- lacks (task 401, B3). The reads are internal/mssql/counters.go's: mssql_counters (the instance objects every
-- minute), mssql_counters_db (the per-database objects every 5 minutes), mssql_counter_catalog (every counter the server
-- has, once a day). Nothing is created, changed or switched on on the monitored server.
--
-- The store is 0124's (mssql_counter_series, mssql_counter_sample, mssql_counter_last, mssql_counter_read), with:
--   series.kind        the arithmetic: 'gauge' (a value as it stands), 'rate' (a count since the start: the change per
--                      second), 'count' (a count since the start the server types 65792: the change per read, and its
--                      rate), 'fraction' (100 * value / base at the read), 'average' (the change in value over the change
--                      in base between two reads), 'unpaired' (a fraction or an average read without its base: as read)
--   sample.base        the base at the read (fraction, average)
--   sample.dvalue, dbase  the change in value and in base since the series' read before, when that read was the scope's
--                      read before in the same run of the server; NULL otherwise (no rate across a restart, a counter that
--                      went down, a first read, or a counter read again after a gap)
--   read.zero_series   the series of the read whose raw value is 0 (a rate, count or average that never counted since
--                      the start): no row is stored for them (0124's rule), the read says they were read, so a figure of
--                      0 stands for them (a rule clears, a healthy server shows a green 0). A counter flat above 0 keeps
--                      its row with a change of 0.
--
--   mssql_counter_defaults   the list a new instance starts with: 0124's 61 (sp_PressureDetector's and
--                            PerformanceMonitor's) and B3's additions, each with the rows it answers and what reads it
--                            (used_by: a counter a page or a rule reads is never removed).
--   mssql_counter_config     Admin's rows: add or remove a counter at the fleet, a tag or one instance. Never updated
--                            in place: an edit ends the row and writes its successor (replaces), as alert_rules.
--   mssql_counter_config_log every attempt from the UI, done or refused.
--   mssql_counter_list(i, yaml)  the instance's list: per counter (object, counter, instance) the narrowest scope's
--                            word wins - instance (Admin over pgvigil.yaml's instance lines) > tag (Admin) > fleet (Admin
--                            over pgvigil.yaml's root lines) > the defaults; a removal of a counter in use is ignored
--                            (and refused at the door: Admin, the config's validation).
--   mssql_counter_catalog    every (object, counter) the server has, its type, instance count, first and last instance.
--   mssql_counter_newest / mssql_counter_series_between  0124's, made again with the kind, the base and the figure.
--   mssql_counter_values     the listed series' rows of every read of a scope over a window, the zero_series as 0.
--   mssql_counter_metrics / mssql_counter_points  the family 'counters' of the metric catalogue: the named rates, the
--                            ratios of one read (with a floor on each denominator), the averages, the hit ratio, page
--                            life expectancy per 4 GB of each memory node, the SQL Agent job counts (G329, from the job
--                            history FLEET already stores: nothing is read from msdb again). The join file adds the
--                            family to metric_catalog and metric_points (WIRING).
--   mssql_counter_histogram  the Batch Resp Statistics buckets over a window (T41).
--   mssql_clerk_names        a friendly name per memory clerk type (T24): Telegraf 1.40.3's 82 names
--                            (plugins/inputs/sqlserver/sqlserverqueries.go, which credits Bob Ward and Opserver's list).
--
-- Sources (MIT): Telegraf 1.40.3 (InfluxData Inc.): the base rule (sqlserverqueries.go, SQLServerPerformanceCounters)
-- and the clerk names. Microsoft's counter types: sys.dm_os_performance_counters' cntr_type and 'Interpreting the
-- counter values from sys.dm_os_performance_counters'.
-- Rows (clickthrough/audit-sqltools-join.md B3): Telegraf T20 T24 T41-T45; Zabbix Z3 Z30 Z37 Z55 Z56 Z94 Z95 Z132;
-- Prometheus S19 S20 S36 S37 S49 A11 A12 D24 W119 W155 W156 W202 W208 W219 W220 WD12 WD13 WD16; SQLWATCH COL#2-#4 INV#5
-- CTR#3 #5-#7 #30 #32 #33 #35 #37 #39 #40 #52 #54 #55 #57-#59 #61 #64 #65 OVW#9 #12 #16 #40 #43 #51 #54 #58 #67 #72-#74
-- #145 PBI#2 #6; SQLMonitor C43 C79 G287 G288 G290 G298 G302-G304 G317 G320 G323 G324 G329.

ALTER TABLE pgvigil.mssql_counter_series ADD COLUMN IF NOT EXISTS kind text;
ALTER TABLE pgvigil.mssql_counter_sample ADD COLUMN IF NOT EXISTS base bigint;
ALTER TABLE pgvigil.mssql_counter_sample ADD COLUMN IF NOT EXISTS dvalue bigint;
ALTER TABLE pgvigil.mssql_counter_sample ADD COLUMN IF NOT EXISTS dbase bigint;
ALTER TABLE pgvigil.mssql_counter_last ADD COLUMN IF NOT EXISTS base bigint;
ALTER TABLE pgvigil.mssql_counter_read ADD COLUMN IF NOT EXISTS zero_series int[];

-- the import's delete, the newest read and every window read go by instance and read time; the series last
-- (an estimate until the proof measures it: about 340 series a minute and 60 per database every 5 minutes on a
-- server with 8 databases, about 600,000 rows and 60 MB a day per instance with this index)
CREATE INDEX IF NOT EXISTS mssql_counter_sample_read_idx ON pgvigil.mssql_counter_sample (instance_id, snapshot_at, series_id);

-- 0124's series rows get their kind from their type (a 65792 count since the start gets 'count' at its next read)
UPDATE pgvigil.mssql_counter_series
   SET kind = CASE WHEN cntr_type IN (272696576, 272696320) THEN 'rate' WHEN cntr_type = 537003264 THEN 'unpaired'
                   WHEN cntr_type = 1073874176 THEN 'unpaired' ELSE 'gauge' END
 WHERE kind IS NULL;

CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_defaults (
  object    text NOT NULL,
  counter   text NOT NULL,
  inst      text NOT NULL DEFAULT '',      -- '' = every instance of the counter
  kind      text NOT NULL DEFAULT '' CHECK (kind IN ('', 'count', 'rate', 'gauge')),
  used_by   text,                          -- what reads it: never removed while a page or a rule reads it
  source    text NOT NULL,                 -- the rows it answers
  PRIMARY KEY (object, counter, inst)
);

-- the defaults are this file's: a rerun makes them again whole
DELETE FROM pgvigil.mssql_counter_defaults;
INSERT INTO pgvigil.mssql_counter_defaults (object, counter, kind, source) VALUES
  -- task 177 D14 (0124): sp_PressureDetector's and PerformanceMonitor 3.12.0's 61 names, each in the one object SQL
  -- Server 2022 CU28 has it in (read on the lab box 2026-11-14)
  ('Access Methods', 'Forwarded Records/sec', '', 'D14'), ('Access Methods', 'Table Lock Escalations/sec', '', 'D14'),
  ('Access Methods', 'Full Scans/sec', '', 'D14'), ('Access Methods', 'Index Searches/sec', '', 'D14'),
  ('Access Methods', 'Page Splits/sec', '', 'D14'), ('Access Methods', 'Workfiles Created/sec', '', 'D14'),
  ('Access Methods', 'Worktables Created/sec', '', 'D14'),
  ('Buffer Manager', 'Page reads/sec', '', 'D14'), ('Buffer Manager', 'Page writes/sec', '', 'D14'),
  ('Buffer Manager', 'Checkpoint pages/sec', '', 'D14'), ('Buffer Manager', 'Page lookups/sec', '', 'D14'),
  ('Buffer Manager', 'Background writer pages/sec', '', 'D14'), ('Buffer Manager', 'Lazy writes/sec', '', 'D14'),
  ('Buffer Manager', 'Readahead pages/sec', '', 'D14'), ('Buffer Manager', 'Free list stalls/sec', '', 'D14'),
  ('Databases', 'Transactions/sec', '', 'D14'), ('Databases', 'Log Flushes/sec', '', 'D14'),
  ('Databases', 'Log Bytes Flushed/sec', '', 'D14'), ('Databases', 'Log Flush Write Time (ms)', '', 'D14'),
  ('Database Replica', 'Transaction Delay', '', 'D14'), ('Database Replica', 'Mirrored Write Transactions/sec', '', 'D14'),
  -- the same two names under Database Mirroring, which 0124's every-minute read took too (a mirroring site keeps them)
  ('Database Mirroring', 'Transaction Delay', '', 'D14'), ('Database Mirroring', 'Mirrored Write Transactions/sec', '', 'D14'),
  ('General Statistics', 'Active Temp Tables', '', 'D14'), ('General Statistics', 'Processes blocked', '', 'D14'),
  ('General Statistics', 'Temp Tables Creation Rate', '', 'D14'),
  ('Locks', 'Lock Requests/sec', '', 'D14'), ('Locks', 'Lock Wait Time (ms)', '', 'D14'), ('Locks', 'Lock Waits/sec', '', 'D14'),
  ('Locks', 'Number of Deadlocks/sec', '', 'D14'), ('Locks', 'Lock Timeouts/sec', '', 'D14'),
  ('Memory Manager', 'Granted Workspace Memory (KB)', '', 'D14'), ('Memory Manager', 'Lock Memory (KB)', '', 'D14'),
  ('Memory Manager', 'Memory Grants Pending', '', 'D14'), ('Memory Manager', 'SQL Cache Memory (KB)', '', 'D14'),
  ('Memory Manager', 'Stolen Server Memory (KB)', '', 'D14'), ('Memory Manager', 'Target Server Memory (KB)', '', 'D14'),
  ('Memory Manager', 'Total Server Memory (KB)', '', 'D14'),
  ('SQL Statistics', 'Batch Requests/sec', '', 'D14'), ('SQL Statistics', 'SQL Compilations/sec', '', 'D14'),
  ('SQL Statistics', 'SQL Re-Compilations/sec', '', 'D14'),
  ('Transactions', 'Longest Transaction Running Time', '', 'D14'), ('Transactions', 'Version Store Size (KB)', '', 'D14'),
  ('Transactions', 'Free Space in tempdb (KB)', '', 'D14'), ('Transactions', 'Version Generation rate (KB/s)', '', 'D14'),
  ('Transactions', 'Version Cleanup rate (KB/s)', '', 'D14'),
  ('Wait Statistics', 'Lock waits', '', 'D14'), ('Wait Statistics', 'Log buffer waits', '', 'D14'),
  ('Wait Statistics', 'Log write waits', '', 'D14'), ('Wait Statistics', 'Memory grant queue waits', '', 'D14'),
  ('Wait Statistics', 'Network IO waits', '', 'D14'), ('Wait Statistics', 'Non-Page latch waits', '', 'D14'),
  ('Wait Statistics', 'Page IO latch waits', '', 'D14'), ('Wait Statistics', 'Page latch waits', '', 'D14'),
  ('Wait Statistics', 'Thread-safe memory objects waits', '', 'D14'), ('Wait Statistics', 'Wait for the worker', '', 'D14'),
  ('Workload Group Stats', 'Active parallel threads', '', 'D14'), ('Workload Group Stats', 'Active requests', '', 'D14'),
  ('Workload Group Stats', 'Blocked tasks', '', 'D14'), ('Workload Group Stats', 'Queued requests', '', 'D14'),
  ('Workload Group Stats', 'Query optimizations/sec', '', 'D14'), ('Workload Group Stats', 'Reduced memory grants/sec', '', 'D14'),
  ('Workload Group Stats', 'Requests completed/sec', '', 'D14'),
  -- B3
  ('General Statistics', 'Logins/sec', '', 'Z37 T43 S36 W155 WD13 CTR#35 OVW#12 OVW#40 G317'),
  ('General Statistics', 'Logouts/sec', '', 'Z37 T43 S36 W156 WD13 G317'),
  ('General Statistics', 'User Connections', '', 'CTR#37 OVW#12 OVW#40'),
  ('General Statistics', 'Connection Reset/sec', '', 'WD13'),
  ('SQL Errors', 'Errors/sec', '', 'Z30 T42 S19 S20 A11 A12 W202 WD12 CTR#57-#59 OVW#58 G303'),
  ('Databases', 'Log Flush Wait Time', '', 'Z132 T45 G287'),
  ('Databases', 'Log Flush Waits/sec', '', 'Z132 G288'),
  ('Databases', 'Write Transactions/sec', '', 'W119 CTR#30'),
  ('Databases', 'Log Truncations', 'count', 'CTR#32'),
  ('Databases', 'Log Shrinks', 'count', 'CTR#33'),
  ('Databases', 'Log Growths', 'count', '402 CHK#33 CTR#28'),
  ('Databases', 'Percent Log Used', '', 'WD23 (407)'),
  ('Databases', 'Active Transactions', '', 'WD25 (407)'),
  ('SQL Statistics', 'Misguided plan executions/sec', '', 'W208'),
  ('SQL Statistics', 'Guided plan executions/sec', '', 'W208'),
  ('SQL Statistics', 'Auto-Param Attempts/sec', '', 'CTR#65 OVW#54 G290'),
  ('SQL Statistics', 'Failed Auto-Params/sec', '', 'CTR#61 OVW#54 G290'),
  ('SQL Statistics', 'Safe Auto-Params/sec', '', 'OVW#54 G290'),
  ('SQL Statistics', 'Unsafe Auto-Params/sec', '', 'OVW#54 G290'),
  ('SQL Statistics', 'Forced Parameterizations/sec', '', 'CTR#64 OVW#54'),
  ('Locks', 'Lock Timeouts (timeout > 0)/sec', '', 'T44'),
  ('Locks', 'Average Wait Time (ms)', '', 'WD16 CTR#40 OVW#67 G320 Z3'),
  ('Latches', 'Latch Waits/sec', '', 'CTR#39 G323 PBI#6'),
  ('Latches', 'Total Latch Wait Time (ms)', '', 'G323 G324'),
  ('Latches', 'Average Latch Wait Time (ms)', '', 'Z3'),
  ('Transactions', 'Update conflict ratio', '', 'W219 W220'),
  ('Resource Pool Stats', 'CPU usage %', '', 'S37 S49 CTR#55 C43 C79'),
  ('Resource Pool Stats', 'Active memory grant amount (KB)', '', 'C43'),
  ('Resource Pool Stats', 'Active memory grants count', '', 'C43'),
  ('Workload Group Stats', 'CPU usage %', '', 'S37 S49 C79'),
  ('Access Methods', 'Pages Allocated/sec', '', 'CTR#3 PBI#6'),
  ('Access Methods', 'Page Deallocations/sec', '', 'CTR#5 PBI#6'),
  ('Access Methods', 'Page compression attempts/sec', '', 'CTR#6 PBI#6'),
  ('Access Methods', 'Pages compressed/sec', '', 'CTR#7 PBI#6'),
  ('Memory Manager', 'Connection Memory (KB)', '', 'CTR#52 OVW#12 OVW#16 OVW#73 OVW#74 OVW#145'),
  ('Memory Manager', 'Optimizer Memory (KB)', '', 'CTR#54 OVW#12 OVW#16 OVW#73 OVW#74 OVW#145'),
  ('Memory Manager', 'Free Memory (KB)', '', 'G298'),
  ('Buffer Manager', 'Database pages', '', 'G298'),
  ('Buffer Manager', 'Target pages', '', 'G298'),
  ('Buffer Manager', 'Buffer cache hit ratio', '', '402 CHK#29 CTR#10 OVW#93 PBI#5'),
  ('Buffer Node', 'Page life expectancy', '', '402 CHK#30 (per node)'),
  ('Buffer Node', 'Database pages', '', '402 CHK#30 (per node)'),
  ('Plan Cache', 'Cache Hit Ratio', '', 'C43'), ('Plan Cache', 'Cache Object Counts', '', 'C43'), ('Plan Cache', 'Cache Pages', '', 'C43'),
  ('Cursor Manager by Type', 'Active cursors', '', 'G302'), ('Cursor Manager by Type', 'Cursor Requests/sec', '', 'G302'),
  ('Cursor Manager by Type', 'Cursor memory usage', '', 'G302'),
  ('Deprecated Features', 'Usage', 'count', 'C43 G304'),
  ('sys.dm_os_schedulers', 'failed_to_create_worker', 'gauge', 'COL#3 OVW#51'),
  ('sys.dm_os_schedulers', 'context_switches_count', 'rate', 'COL#3'),
  ('sys.dm_os_schedulers', 'preemptive_switches_count', 'rate', 'COL#3'),
  ('sys.dm_os_schedulers', 'idle_switches_count', 'rate', 'COL#3'),
  ('sys.dm_os_schedulers', 'yield_count', 'rate', 'COL#3'),
  ('sys.dm_os_process_memory', 'physical_memory_in_use_kb', 'gauge', 'COL#4 OVW#9 OVW#72'),
  ('sys.dm_os_process_memory', 'large_page_allocations_kb', 'gauge', 'COL#4'),
  ('sys.dm_os_process_memory', 'locked_page_allocations_kb', 'gauge', 'COL#4'),
  ('sys.dm_os_process_memory', 'total_virtual_address_space_kb', 'gauge', 'COL#4'),
  ('sys.dm_os_process_memory', 'virtual_address_space_reserved_kb', 'gauge', 'COL#4'),
  ('sys.dm_os_process_memory', 'virtual_address_space_committed_kb', 'gauge', 'COL#4'),
  ('sys.dm_os_process_memory', 'virtual_address_space_available_kb', 'gauge', 'COL#4'),
  ('sys.dm_os_process_memory', 'page_fault_count', 'rate', 'COL#4'),
  ('sys.dm_os_process_memory', 'memory_utilization_percentage', 'gauge', 'COL#4'),
  ('sys.dm_os_process_memory', 'available_commit_limit_kb', 'gauge', 'COL#4 OVW#9 OVW#72'),
  ('sys.dm_os_process_memory', 'process_physical_memory_low', 'gauge', 'COL#4 OVW#72'),
  ('sys.dm_os_process_memory', 'process_virtual_memory_low', 'gauge', 'COL#4 OVW#9 OVW#72');
-- T41: the Batch Resp Statistics buckets, each a count since the start the server types 65792
INSERT INTO pgvigil.mssql_counter_defaults (object, counter, kind, source)
SELECT 'Batch Resp Statistics', b, 'count', 'T41'
  FROM unnest(ARRAY['Batches >=000000ms & <000001ms', 'Batches >=000001ms & <000002ms', 'Batches >=000002ms & <000005ms',
                    'Batches >=000005ms & <000010ms', 'Batches >=000010ms & <000020ms', 'Batches >=000020ms & <000050ms',
                    'Batches >=000050ms & <000100ms', 'Batches >=000100ms & <000200ms', 'Batches >=000200ms & <000500ms',
                    'Batches >=000500ms & <001000ms', 'Batches >=001000ms & <002000ms', 'Batches >=002000ms & <005000ms',
                    'Batches >=005000ms & <010000ms', 'Batches >=010000ms & <020000ms', 'Batches >=020000ms & <050000ms',
                    'Batches >=050000ms & <100000ms', 'Batches >=100000ms']) b;
-- what reads a counter (internal/mssql/counters.go countersInUse holds the same; counters_test.go keeps them equal)
UPDATE pgvigil.mssql_counter_defaults d SET used_by = u.why
  FROM (VALUES
    ('Workload Group Stats', 'Active requests', 'the CPU page''s thread use'),
    ('Workload Group Stats', 'Queued requests', 'the CPU page''s thread use and its scheduler level'),
    ('Workload Group Stats', 'Blocked tasks', 'the CPU page''s thread use'),
    ('Workload Group Stats', 'Active parallel threads', 'the CPU page''s thread use'),
    ('Databases', 'Log Bytes Flushed/sec', 'the File IO page''s log flushes'),
    ('SQL Statistics', 'Batch Requests/sec', 'the counters metrics (compilations, page splits and page lookups per batch)'),
    ('SQL Statistics', 'SQL Compilations/sec', 'the counters metrics (compilations per batch, re-compilations per compilation)'),
    ('SQL Statistics', 'SQL Re-Compilations/sec', 'the counters metric re-compilations per compilation'),
    ('SQL Statistics', 'Misguided plan executions/sec', 'the counters metric misguided plan executions'),
    ('General Statistics', 'Logins/sec', 'the counters metric logins/sec'),
    ('General Statistics', 'Logouts/sec', 'the counters metric logouts/sec'),
    ('General Statistics', 'User Connections', 'the counters metric user connections'),
    ('SQL Errors', 'Errors/sec', 'the counters metrics errors/sec by kind'),
    ('Locks', 'Lock Timeouts (timeout > 0)/sec', 'the counters metric lock timeouts (timeout > 0)'),
    ('Locks', 'Lock Waits/sec', 'the counters metric lock waits/sec'),
    ('Locks', 'Lock Requests/sec', 'the counters metric lock requests/sec'),
    ('Locks', 'Average Wait Time (ms)', 'the counters metric average lock wait'),
    ('Latches', 'Latch Waits/sec', 'the counters metric latch waits/sec'),
    ('Latches', 'Average Latch Wait Time (ms)', 'the counters metric average latch wait'),
    ('Access Methods', 'Full Scans/sec', 'the counters metric full scans per index search'),
    ('Access Methods', 'Index Searches/sec', 'the counters metric full scans per index search'),
    ('Access Methods', 'Page Splits/sec', 'the counters metric page splits per batch'),
    ('Buffer Manager', 'Page lookups/sec', 'the counters metric page lookups per batch'),
    ('Buffer Manager', 'Page reads/sec', 'the counters metrics page reads/sec and read-ahead share'),
    ('Buffer Manager', 'Page writes/sec', 'the counters metric page writes/sec'),
    ('Buffer Manager', 'Readahead pages/sec', 'the counters metric read-ahead share'),
    ('Buffer Manager', 'Lazy writes/sec', 'the counters metric lazy writes/sec'),
    ('Buffer Manager', 'Free list stalls/sec', 'the counters metric free list stalls/sec'),
    ('Buffer Manager', 'Buffer cache hit ratio', 'the counters metric buffer cache hit ratio'),
    ('Buffer Node', 'Page life expectancy', 'the counters metric page life expectancy per 4 GB'),
    ('Buffer Node', 'Database pages', 'the counters metric page life expectancy per 4 GB'),
    ('Transactions', 'Update conflict ratio', 'the counters metric update conflicts'),
    ('Databases', 'Write Transactions/sec', 'the counters metric write transactions/sec and the storage pages'),
    ('Databases', 'Log Flush Waits/sec', 'the counters metric log flush waits/sec'),
    ('Databases', 'Log Flush Wait Time', 'the counters metric log flush wait time'),
    ('Databases', 'Log Growths', 'the counters metric log growths'),
    ('Databases', 'Percent Log Used', 'the counters metric percent log used and the storage pages'),
    ('Databases', 'Active Transactions', 'the counters metric active transactions and the storage pages'),
    ('sys.dm_os_process_memory', 'physical_memory_in_use_kb', 'the counters metric memory in use of the commit limit'),
    ('sys.dm_os_process_memory', 'available_commit_limit_kb', 'the counters metric memory in use of the commit limit'),
    ('sys.dm_os_schedulers', 'failed_to_create_worker', 'the counters metric failed to create a worker')
  ) AS u(object, counter, why)
 WHERE d.object = u.object AND d.counter = u.counter;

-- the objects read by mssql_counters_db (a database or a database's replica is the instance); any case, as the
-- collector matches names (a yaml line 'databases' is the Databases object)
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_scope(p_object text) RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN lower(p_object) IN ('databases', 'database replica') THEN 'database' ELSE 'instance' END
$$;

-- ---- Admin's rows -------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_config (
  config_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  scope          text NOT NULL CHECK (scope IN ('fleet', 'tag', 'instance')),
  tag            text CHECK (length(tag) BETWEEN 1 AND 200),
  instance_name  text CHECK (length(instance_name) BETWEEN 1 AND 200),
  object         text NOT NULL CHECK (length(object) BETWEEN 1 AND 128),
  counter        text NOT NULL CHECK (length(counter) BETWEEN 1 AND 128),
  inst           text NOT NULL DEFAULT '' CHECK (length(inst) <= 128),
  action         text NOT NULL CHECK (action IN ('add', 'remove')),
  kind           text NOT NULL DEFAULT '' CHECK (kind IN ('', 'count', 'rate', 'gauge')),
  note           text CHECK (length(note) BETWEEN 1 AND 500),
  replaces       bigint,
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  client         text,
  ended_by       text,
  ended_at       timestamptz,
  CONSTRAINT "a tag row names its tag, an instance row its instance" CHECK (
    (scope = 'fleet' AND tag IS NULL AND instance_name IS NULL) OR (scope = 'tag' AND tag IS NOT NULL AND instance_name IS NULL)
    OR (scope = 'instance' AND tag IS NULL AND instance_name IS NOT NULL))
);
-- one live row per counter and scope: a second one is an edit of the first
CREATE UNIQUE INDEX IF NOT EXISTS mssql_counter_config_live_uq ON pgvigil.mssql_counter_config
  (object, counter, inst, scope, coalesce(tag, ''), coalesce(instance_name, '')) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.mssql_counter_config IS 'Admin''s additions and removals of SQL Server counters; written through import_mssql_counter_config only.';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_config_log (
  log_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at         timestamptz NOT NULL,
  ui_user    text NOT NULL,
  client     text,
  op         text,
  config_id  bigint,
  outcome    text NOT NULL CHECK (outcome IN ('done', 'refused')),
  detail     text,
  payload    jsonb
);
CREATE INDEX IF NOT EXISTS mssql_counter_config_log_at_idx ON pgvigil.mssql_counter_config_log (at DESC);

-- import_mssql_counter_config: one edit from the Admin page (through the actions door's audit login, behind the UI
-- login): op 'add' (scope, tag | instance_name, object, counter, inst, action add | remove, kind, note), 'end'
-- (config_id). A removal of a counter in use is refused with what reads it; a counter the store has never seen on any
-- instance and no default names is accepted (a server may have it) and said so.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_counter_config(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_scope   text := p_payload->>'scope';
  v_tag     text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_inst    text := nullif(p_payload->>'instance_name', '');
  v_object  text := nullif(btrim(coalesce(p_payload->>'object', '')), '');
  v_counter text := nullif(btrim(coalesce(p_payload->>'counter', '')), '');
  v_cinst   text := coalesce(btrim(p_payload->>'inst'), '');
  v_action  text := p_payload->>'action';
  v_kind    text := coalesce(p_payload->>'kind', '');
  v_note    text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_id      bigint;
  v_new     bigint;
  v_why     text;
  v_done    text;
  v_used    text;
  v_known   boolean;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_mssql_counter_config: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('add', 'end') THEN
    v_why := 'op must be add or end';
  ELSIF v_op = 'end' THEN
    IF coalesce(p_payload->>'config_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'config_id')::bigint;
    END IF;
    IF v_id IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.mssql_counter_config WHERE config_id = v_id AND ended_at IS NULL) THEN
      v_why := format('no live row %s', coalesce(p_payload->>'config_id', '(none)'));
    END IF;
  ELSE
    IF v_scope IS NULL OR v_scope NOT IN ('fleet', 'tag', 'instance') THEN
      v_why := 'scope must be fleet, tag or instance';
    ELSIF v_scope = 'tag' AND v_tag IS NULL THEN
      v_why := 'a tag row names its tag';
    ELSIF v_scope = 'instance' AND NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.name = v_inst AND i.is_active AND i.engine = 'sqlserver') THEN
      v_why := format('no active SQL Server instance %L', v_inst);
    ELSIF v_object IS NULL OR v_counter IS NULL OR length(v_object) > 128 OR length(v_counter) > 128 OR length(v_cinst) > 128 THEN
      v_why := 'a row names its object and counter (128 characters at most each)';
    ELSIF v_action IS NULL OR v_action NOT IN ('add', 'remove') THEN
      v_why := 'action must be add or remove';
    ELSIF v_kind NOT IN ('', 'count', 'rate', 'gauge') THEN
      v_why := 'kind must be empty (from the type read), count, rate or gauge';
    ELSIF v_object LIKE 'sys.dm_os_%' AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_counter_defaults d WHERE d.object = v_object AND d.counter = v_counter) THEN
      v_why := format('%s has no column %s pgvigil reads', v_object, v_counter);
    ELSIF v_object LIKE 'sys.dm_os_%' AND v_kind <> '' THEN
      -- a DMV column's arithmetic is pgvigil's own (pseudoRows): a kind would be ignored, so it is refused in words
      v_why := format('%s / %s is a DMV column: its kind is fixed by pgvigil, leave kind empty', v_object, v_counter);
    END IF;
    -- a counter a page or a rule reads is never removed, and its kind is never overridden (the figure that reads it
    -- needs the arithmetic its type gives: a gauge kind on Errors/sec would store no rate)
    IF v_why IS NULL AND (v_action = 'remove' OR v_kind <> '') THEN
      SELECT d.used_by INTO v_used FROM pgvigil.mssql_counter_defaults d
       WHERE lower(d.object) = lower(v_object) AND lower(d.counter) = lower(v_counter) AND d.used_by IS NOT NULL LIMIT 1;
      IF v_used IS NOT NULL THEN
        v_why := CASE WHEN v_action = 'remove' THEN format('%s / %s is read by %s: it stays in the list', v_object, v_counter, v_used)
                      ELSE format('%s / %s is read by %s: its kind stays as SQL Server types it', v_object, v_counter, v_used) END;
      END IF;
    END IF;
    IF v_scope <> 'tag' THEN v_tag := NULL; END IF;
    IF v_scope <> 'instance' THEN v_inst := NULL; END IF;
  END IF;
  IF v_why IS NULL THEN
    BEGIN
      IF v_op = 'end' THEN
        UPDATE pgvigil.mssql_counter_config SET ended_by = v_user, ended_at = p_at WHERE config_id = v_id;
        v_done := 'ended';
      ELSE
        -- a live row for the same counter and scope is ended and replaced
        UPDATE pgvigil.mssql_counter_config c SET ended_by = v_user, ended_at = p_at
         WHERE c.ended_at IS NULL AND c.object = v_object AND c.counter = v_counter AND c.inst = v_cinst AND c.scope = v_scope
           AND coalesce(c.tag, '') = coalesce(v_tag, '') AND coalesce(c.instance_name, '') = coalesce(v_inst, '')
        RETURNING c.config_id INTO v_id;
        INSERT INTO pgvigil.mssql_counter_config (scope, tag, instance_name, object, counter, inst, action, kind, note, replaces,
                                                  created_by, created_at, client)
        VALUES (v_scope, v_tag, v_inst, v_object, v_counter, v_cinst, v_action, v_kind, v_note, v_id, v_user, p_at, v_client)
        RETURNING config_id INTO v_new;
        SELECT EXISTS (SELECT 1 FROM pgvigil.mssql_counter_defaults d WHERE lower(d.object) = lower(v_object) AND lower(d.counter) = lower(v_counter))
            OR EXISTS (SELECT 1 FROM pgvigil.mssql_counter_catalog k WHERE lower(k.object) = lower(v_object) AND lower(k.counter) = lower(v_counter))
          INTO v_known;
        v_done := CASE WHEN v_id IS NOT NULL THEN format('row %s replaced by row %s', v_id, v_new) ELSE 'added' END
               || CASE WHEN v_action = 'add' AND NOT v_known
                       THEN ': no server read so far has this counter (a server that has it reads it from its next read)' ELSE '' END;
      END IF;
    EXCEPTION
      WHEN unique_violation THEN
        v_why := 'a live row already holds this counter and scope';
        v_new := NULL;
      WHEN check_violation OR invalid_text_representation OR string_data_right_truncation THEN
        v_why := 'refused by the store: ' || SQLERRM;
        v_new := NULL;
    END;
  END IF;
  INSERT INTO pgvigil.mssql_counter_config_log (at, ui_user, client, op, config_id, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, v_op, coalesce(v_new, v_id), CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
          coalesce(v_why, v_done), p_payload);
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, v_done), 'config_id', coalesce(v_new, v_id));
END $$;

-- ---- the list --------------------------------------------------------------------------------------------------------

-- mssql_counter_layers: every word on every counter for one instance, with its level (the narrowest scope wins: 1 the
-- defaults, 2 pgvigil.yaml's root, 3 Admin's fleet, 4 Admin's tag, 5 pgvigil.yaml's instance, 6 Admin's instance).
-- p_yaml: the runner's copy of pgvigil.yaml's lines, [{layer root|instance, action add|remove, object, counter, inst,
-- kind}]. The Admin page reads it whole to show where each word comes from.
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_layers(p_instance_id int, p_yaml jsonb)
RETURNS TABLE (object text, counter text, inst text, action text, kind text, level int, source text, config_id bigint, used_by text)
LANGUAGE sql STABLE AS $$
  WITH me AS (SELECT i.name, coalesce(t.tags, '{}'::text[]) AS tags FROM pgvigil.instances i
                LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id WHERE i.instance_id = p_instance_id),
  y AS (SELECT btrim(e->>'object') AS object, btrim(e->>'counter') AS counter, coalesce(btrim(e->>'inst'), '') AS inst,
               e->>'action' AS action, coalesce(e->>'kind', '') AS kind, e->>'layer' AS layer
          FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_yaml) = 'array' THEN p_yaml ELSE '[]'::jsonb END) e
         WHERE e->>'action' IN ('add', 'remove') AND e->>'layer' IN ('root', 'instance')
           AND coalesce(btrim(e->>'object'), '') <> '' AND coalesce(btrim(e->>'counter'), '') <> ''
           AND coalesce(e->>'kind', '') IN ('', 'count', 'rate', 'gauge'))
  SELECT d.object, d.counter, d.inst, 'add', d.kind, 1, 'default', NULL::bigint, d.used_by FROM pgvigil.mssql_counter_defaults d
  UNION ALL
  SELECT y.object, y.counter, y.inst, y.action, y.kind, CASE y.layer WHEN 'root' THEN 2 ELSE 5 END,
         'pgvigil.yaml (' || y.layer || ')', NULL, NULL FROM y
  UNION ALL
  SELECT c.object, c.counter, c.inst, c.action, c.kind, CASE c.scope WHEN 'fleet' THEN 3 WHEN 'tag' THEN 4 ELSE 6 END,
         'Admin (' || c.scope || coalesce(' ' || c.tag, '') || ')', c.config_id, NULL
    FROM pgvigil.mssql_counter_config c, me
   WHERE c.ended_at IS NULL
     AND (c.scope = 'fleet' OR (c.scope = 'tag' AND c.tag = ANY (me.tags)) OR (c.scope = 'instance' AND c.instance_name = me.name))
$$;

-- mssql_counter_list: the instance's list as counters.go reads it ([{object, counter, inst, scope, kind, except}]): per
-- counter the word of the highest level; a removal of a counter in use never wins (the defaults keep it). A removal of
-- one instance of a counter (a feature of Deprecated Features / Usage) names that instance in its every-instance line's
-- except list, so the line that reads the others leaves it out.
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_list(p_instance_id int, p_yaml jsonb DEFAULT '[]'::jsonb)
RETURNS jsonb LANGUAGE sql STABLE AS $$
  WITH l AS (SELECT * FROM pgvigil.mssql_counter_layers(p_instance_id, p_yaml)),
  inuse AS (SELECT lower(d.object) AS o, lower(d.counter) AS c FROM pgvigil.mssql_counter_defaults d WHERE d.used_by IS NOT NULL),
  w AS (SELECT DISTINCT ON (lower(l.object), lower(l.counter), l.inst) l.*
          FROM l
         WHERE NOT (l.action = 'remove' AND (lower(l.object), lower(l.counter)) IN (SELECT o, c FROM inuse))
         ORDER BY lower(l.object), lower(l.counter), l.inst, l.level DESC),
  x AS (SELECT lower(w.object) AS o, lower(w.counter) AS c, jsonb_agg(w.inst ORDER BY w.inst) AS insts
          FROM w WHERE w.action = 'remove' AND w.inst <> '' GROUP BY 1, 2)
  SELECT coalesce(jsonb_agg(jsonb_build_object('object', w.object, 'counter', w.counter, 'inst', w.inst,
                                               'scope', pgvigil.mssql_counter_scope(w.object), 'kind', w.kind)
                            || CASE WHEN w.inst = '' AND x.insts IS NOT NULL THEN jsonb_build_object('except', x.insts) ELSE '{}'::jsonb END
                            ORDER BY w.object, w.counter, w.inst), '[]'::jsonb)
    FROM w LEFT JOIN x ON x.o = lower(w.object) AND x.c = lower(w.counter)
   WHERE w.action = 'add'
$$;

-- mssql_counter_yaml: pgvigil.yaml's mssql_counters lines as the runner last handed them over for an instance (the
-- Admin page shows them beside Admin's rows: the serve process does not read the collector's file)
CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_yaml (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  lines        jsonb NOT NULL,
  read_at      timestamptz NOT NULL
);

-- import_mssql_counter_list: the runner's door to the list (the collector login holds no SELECT: apply_roles makes every
-- import_* function SECURITY DEFINER and grants the collector EXECUTE on it). It keeps the yaml lines it was handed
-- (mssql_counter_yaml) and answers the list.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_counter_list(p_instance_id int, p_yaml jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_yaml jsonb := CASE WHEN jsonb_typeof(p_yaml) = 'array' THEN p_yaml ELSE '[]'::jsonb END;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_counter_list: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  INSERT INTO pgvigil.mssql_counter_yaml AS y (instance_id, lines, read_at) VALUES (p_instance_id, v_yaml, now())
  ON CONFLICT (instance_id) DO UPDATE SET lines = EXCLUDED.lines, read_at = EXCLUDED.read_at
   WHERE y.lines IS DISTINCT FROM EXCLUDED.lines OR y.read_at < now() - interval '1 hour';
  RETURN pgvigil.mssql_counter_list(p_instance_id, v_yaml);
END $$;

-- the yaml lines the runner last used for an instance ('[]' before its first run)
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_yaml_of(p_instance_id int) RETURNS jsonb LANGUAGE sql STABLE AS $$
  SELECT coalesce((SELECT y.lines FROM pgvigil.mssql_counter_yaml y WHERE y.instance_id = p_instance_id), '[]'::jsonb)
$$;

-- ---- the catalogue -----------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_counter_catalog (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  object          text NOT NULL,
  counter         text NOT NULL,
  cntr_type       bigint,
  instances       int,
  first_instance  text,
  last_instance   text,
  read_at         timestamptz NOT NULL,
  PRIMARY KEY (instance_id, object, counter)
);

-- one read replaces the instance's catalogue whole (a counter a new version dropped leaves it)
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_counter_catalog(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_counter_catalog: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cat') THEN RETURN; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_counter_catalog'), p_instance_id);
  DELETE FROM pgvigil.mssql_counter_catalog WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_counter_catalog (instance_id, object, counter, cntr_type, instances, first_instance, last_instance, read_at)
  SELECT DISTINCT ON (r->>'object', r->>'counter') p_instance_id, r->>'object', r->>'counter', (r->>'type')::bigint,
         (r->>'instances')::int, r->>'first_instance', r->>'last_instance', p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'cat' AND coalesce(r->>'object', '') <> '' AND coalesce(r->>'counter', '') <> '';
END $$;

-- ---- the import ----------------------------------------------------------------------------------------------------

-- mssql_import_counters: the 'ctr' rows of one read of a scope ('instance' every minute, 'database' every 5 minutes).
-- The caller holds the scope's import lock and has made and locked the month's partitions.
CREATE OR REPLACE FUNCTION pgvigil.mssql_import_counters(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb, p_scope text,
                                                          p_now timestamptz, p_start timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_n      int;
  v_prev   timestamptz;
  v_prev_iv real;
  v_gap    boolean;
  v_zero   int[];
BEGIN
  SELECT count(*) INTO v_n FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'ctr';
  -- an older read arriving late: its scope's newest read is already stored
  SELECT c.server_utc, c.interval_secs INTO v_prev, v_prev_iv FROM pgvigil.mssql_counter_read c
   WHERE c.instance_id = p_instance_id AND c.scope = p_scope
   ORDER BY c.snapshot_at DESC LIMIT 1;
  IF v_prev IS NOT NULL AND v_prev >= p_now THEN RETURN; END IF;
  -- F15: no change and no rate after a gap in time - the scope's read before is older than twice its interval (the
  -- read before's own interval, else the scope's default: 60 s, 300 s per database); a schedule made longer costs one
  -- read's rates, a collector stopped for hours never puts its hours on one point
  v_gap := v_prev IS NOT NULL AND extract(epoch FROM p_now - v_prev)
             > 2 * greatest(coalesce(v_prev_iv, 0), CASE p_scope WHEN 'database' THEN 300 ELSE 60 END);

  INSERT INTO pgvigil.mssql_counter_series AS k (instance_id, object, counter, inst, cntr_type, kind)
  SELECT DISTINCT ON (r->>'object', r->>'counter', r->>'instance') p_instance_id, r->>'object', r->>'counter', r->>'instance',
         (r->>'type')::bigint, r->>'ckind'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'ctr' AND r->>'object' IS NOT NULL AND r->>'counter' IS NOT NULL AND r->>'instance' IS NOT NULL
  ON CONFLICT (instance_id, object, counter, inst) DO UPDATE SET cntr_type = EXCLUDED.cntr_type, kind = EXCLUDED.kind
   WHERE k.cntr_type IS DISTINCT FROM EXCLUDED.cntr_type OR k.kind IS DISTINCT FROM EXCLUDED.kind;

  CREATE TEMP TABLE IF NOT EXISTS pgv_ctr_x (series_id int, kind text, value bigint, base bigint, dvalue bigint, dbase bigint,
                                             rate real) ON COMMIT DROP;
  TRUNCATE pgv_ctr_x;
  INSERT INTO pgv_ctr_x
  SELECT k.series_id, k.kind, x.value, x.base, d.dvalue, d.dbase,
         CASE WHEN k.kind IN ('rate', 'count') AND d.dvalue IS NOT NULL
              THEN round((d.dvalue / extract(epoch FROM p_now - l.server_utc))::numeric, 3)::real END
    FROM (SELECT DISTINCT ON (r->>'object', r->>'counter', r->>'instance') r->>'object' AS object, r->>'counter' AS counter,
                 r->>'instance' AS inst, (r->>'value')::bigint AS value, (r->>'base')::bigint AS base
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'ctr' AND r->>'value' IS NOT NULL) x
    JOIN pgvigil.mssql_counter_series k ON k.instance_id = p_instance_id AND k.object = x.object AND k.counter = x.counter AND k.inst = x.inst
    LEFT JOIN pgvigil.mssql_counter_last l ON l.instance_id = p_instance_id AND l.series_id = k.series_id
    -- a change only from the scope's read before, in the same run of the server, never going down: no rate across a
    -- restart, a reset, or a gap in which the counter was not listed
    CROSS JOIN LATERAL (SELECT CASE WHEN ok THEN x.value - l.value END AS dvalue,
                               CASE WHEN ok AND x.base IS NOT NULL AND l.base IS NOT NULL AND x.base >= l.base THEN x.base - l.base END AS dbase
                          FROM (SELECT l.series_id IS NOT NULL AND v_prev IS NOT NULL AND NOT v_gap AND l.server_utc = v_prev AND p_now > l.server_utc
                                       AND pgvigil.mssql_same_run(l.server_start, p_start) AND x.value >= l.value AS ok) o) d;

  -- a rate, count or average at raw 0 (never counted since the start): the read names it, no row is stored
  SELECT array_agg(series_id ORDER BY series_id) INTO v_zero FROM pgv_ctr_x
   WHERE kind IN ('rate', 'count', 'average') AND value = 0 AND coalesce(base, 0) = 0;

  DELETE FROM pgvigil.mssql_counter_sample s
   WHERE s.instance_id = p_instance_id AND s.snapshot_at = p_snapshot_at AND s.series_id IN (SELECT series_id FROM pgv_ctr_x);
  INSERT INTO pgvigil.mssql_counter_sample (instance_id, snapshot_at, series_id, value, rate, base, dvalue, dbase)
  SELECT p_instance_id, p_snapshot_at, x.series_id, x.value, x.rate, x.base, x.dvalue, x.dbase
    FROM pgv_ctr_x x
   WHERE NOT (x.kind IN ('rate', 'count', 'average') AND x.value = 0 AND coalesce(x.base, 0) = 0);

  INSERT INTO pgvigil.mssql_counter_last AS l (instance_id, series_id, value, base, server_utc, server_start)
  SELECT p_instance_id, x.series_id, x.value, x.base, p_now, p_start FROM pgv_ctr_x x
  ON CONFLICT (instance_id, series_id) DO UPDATE SET value = EXCLUDED.value, base = EXCLUDED.base, server_utc = EXCLUDED.server_utc,
                                                     server_start = EXCLUDED.server_start;

  DELETE FROM pgvigil.mssql_counter_read WHERE instance_id = p_instance_id AND snapshot_at = p_snapshot_at AND scope = p_scope;
  INSERT INTO pgvigil.mssql_counter_read (instance_id, snapshot_at, scope, server_utc, rows_read, interval_secs, zero_series)
  VALUES (p_instance_id, p_snapshot_at, p_scope, p_now, v_n, extract(epoch FROM p_now - v_prev)::real, coalesce(v_zero, '{}'));
END $$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_import_counters_scope(p_fn text, p_scope text, p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s jsonb := pgvigil.mssql_perf_check(p_fn, p_instance_id, p_payload);
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.' || p_fn), p_instance_id);
  -- the parents in name order (0067's lock-order note)
  PERFORM pgvigil.ensure_month_partition('mssql_counter_read', p_snapshot_at);
  PERFORM pgvigil.ensure_month_partition('mssql_counter_sample', p_snapshot_at);
  LOCK TABLE ONLY pgvigil.mssql_counter_read, ONLY pgvigil.mssql_counter_sample IN ROW EXCLUSIVE MODE;
  PERFORM pgvigil.mssql_import_counters(p_instance_id, p_snapshot_at, p_payload, p_scope,
                                        (v_s->>'server_utc')::timestamptz, (v_s->>'server_start')::timestamptz);
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_counters(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  SELECT pgvigil.mssql_import_counters_scope('import_mssql_counters', 'instance', p_instance_id, p_snapshot_at, p_payload)
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_counters_db(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  SELECT pgvigil.mssql_import_counters_scope('import_mssql_counters_db', 'database', p_instance_id, p_snapshot_at, p_payload)
$$;

-- ---- the figure ----------------------------------------------------------------------------------------------------

-- mssql_counter_figure: one read's figure of a series by its kind
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_figure(p_kind text, p_value bigint, p_base bigint, p_rate real, p_dvalue bigint, p_dbase bigint)
RETURNS double precision LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_kind
           WHEN 'gauge' THEN p_value::double precision
           WHEN 'rate' THEN p_rate::double precision
           WHEN 'count' THEN p_dvalue::double precision
           WHEN 'fraction' THEN 100.0 * p_value / nullif(p_base, 0)
           WHEN 'average' THEN p_dvalue::double precision / nullif(p_dbase, 0)
         END
$$;

-- the Metrics page's counters: the newest read of each scope in a window, a row per series read (the zero_series as 0),
-- each with its kind, base and figure (0124's columns first, as before)
DROP FUNCTION IF EXISTS pgvigil.mssql_counter_newest(int, timestamptz, timestamptz);
CREATE FUNCTION pgvigil.mssql_counter_newest(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (series_id int, scope text, snapshot_at timestamptz, object text, counter text, inst text, cntr_type bigint,
               cumulative boolean, value bigint, rate real, interval_secs real, kind text, base bigint, dvalue bigint, dbase bigint,
               figure double precision)
LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT DISTINCT ON (c.scope) c.scope, c.snapshot_at, c.interval_secs, c.zero_series FROM pgvigil.mssql_counter_read c
              WHERE c.instance_id = p_instance_id AND c.snapshot_at > p_from AND c.snapshot_at <= p_to
              ORDER BY c.scope, c.snapshot_at DESC),
  v AS (SELECT r.scope, r.snapshot_at, r.interval_secs, s.series_id, s.value, s.rate, s.base, s.dvalue, s.dbase
          FROM r JOIN pgvigil.mssql_counter_sample s ON s.instance_id = p_instance_id AND s.snapshot_at = r.snapshot_at
        UNION ALL
        SELECT r.scope, r.snapshot_at, r.interval_secs, z.id, 0, 0, 0, 0, 0 FROM r CROSS JOIN LATERAL unnest(coalesce(r.zero_series, '{}')) z(id))
  SELECT k.series_id, v.scope, v.snapshot_at, k.object, k.counter, k.inst, k.cntr_type, coalesce(k.kind, '') IN ('rate', 'count'),
         v.value, v.rate, v.interval_secs, coalesce(k.kind, 'gauge'), v.base, v.dvalue, v.dbase,
         pgvigil.mssql_counter_figure(coalesce(k.kind, 'gauge'), v.value, v.base, v.rate, v.dvalue, v.dbase)
    FROM v JOIN pgvigil.mssql_counter_series k ON k.series_id = v.series_id
   WHERE (v.scope = 'database') = (k.object IN ('Databases', 'Database Replica'))
   ORDER BY k.object, k.counter, k.inst
$$;

-- a series per id over a window in steps of p_step seconds: a rate's average per second (a read with the series at
-- raw 0 counts as 0), a count's change summed per step, a gauge's average value, a fraction's base-weighted share,
-- an average's summed change in value over summed change in base (never an average of averages)
DROP FUNCTION IF EXISTS pgvigil.mssql_counter_series_between(int, timestamptz, timestamptz, int, int[]);
CREATE FUNCTION pgvigil.mssql_counter_series_between(p_instance_id int, p_from timestamptz, p_to timestamptz, p_step int, p_series int[])
RETURNS TABLE (snapshot_at timestamptz, series_id int, value double precision)
LANGUAGE sql STABLE AS $$
  WITH ids AS (SELECT unnest(p_series[1:10]) AS id),
  v AS (SELECT s.snapshot_at, s.series_id, s.value, s.base, s.rate, s.dvalue, s.dbase
          FROM pgvigil.mssql_counter_sample s
         WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_from AND s.snapshot_at <= p_to AND s.series_id IN (SELECT id FROM ids)
        UNION ALL
        SELECT c.snapshot_at, z.id, 0, 0, 0, 0, 0
          FROM pgvigil.mssql_counter_read c CROSS JOIN LATERAL unnest(coalesce(c.zero_series, '{}')) z(id)
         WHERE c.instance_id = p_instance_id AND c.snapshot_at > p_from AND c.snapshot_at <= p_to AND z.id IN (SELECT id FROM ids))
  SELECT to_timestamp(floor(extract(epoch FROM v.snapshot_at) / p_step) * p_step), v.series_id,
         CASE coalesce(k.kind, 'gauge')
           WHEN 'rate' THEN avg(v.rate)
           WHEN 'count' THEN sum(v.dvalue)::double precision
           WHEN 'fraction' THEN 100.0 * sum(v.value) / nullif(sum(v.base), 0)
           WHEN 'average' THEN sum(v.dvalue)::double precision / nullif(sum(v.dbase), 0)
           ELSE avg(v.value) END
    FROM v JOIN pgvigil.mssql_counter_series k ON k.series_id = v.series_id
   GROUP BY 1, 2, k.kind ORDER BY 1, 2
$$;

-- mssql_counter_values: the listed series' rows at every read of one scope in (p_from, p_to], the zero_series as 0
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_values(p_instance_id int, p_from timestamptz, p_to timestamptz, p_scope text)
RETURNS TABLE (snapshot_at timestamptz, object text, counter text, inst text, kind text, value bigint, base bigint, rate real,
               dvalue bigint, dbase bigint)
LANGUAGE sql STABLE AS $$
  WITH r AS (SELECT c.snapshot_at, c.zero_series FROM pgvigil.mssql_counter_read c
              WHERE c.instance_id = p_instance_id AND c.scope = p_scope AND c.snapshot_at > p_from AND c.snapshot_at <= p_to)
  SELECT r.snapshot_at, k.object, k.counter, k.inst, coalesce(k.kind, 'gauge'), s.value, s.base, s.rate, s.dvalue, s.dbase
    FROM r JOIN pgvigil.mssql_counter_sample s ON s.instance_id = p_instance_id AND s.snapshot_at = r.snapshot_at
    JOIN pgvigil.mssql_counter_series k ON k.series_id = s.series_id
  UNION ALL
  SELECT r.snapshot_at, k.object, k.counter, k.inst, coalesce(k.kind, 'gauge'), 0, 0, 0, 0, 0
    FROM r CROSS JOIN LATERAL unnest(coalesce(r.zero_series, '{}')) z(id)
    JOIN pgvigil.mssql_counter_series k ON k.series_id = z.id
$$;

-- ---- the metrics family 'counters' ----------------------------------------------------------------------------------

-- mssql_counter_metrics: the metrics of the family in metric_catalog's columns (the join file adds them to the
-- catalogue). A ratio's label says its floor: under it the point is 0 (an idle server's own reads are not a ratio).
CREATE OR REPLACE VIEW pgvigil.mssql_counter_metrics AS
SELECT v.engine, v.family, v.family_label, v.family_sort, v.metric, v.label, v.unit, v.per_database, v.fresh_secs, v.sort
  FROM (VALUES
    ('sqlserver', 'counters', 'Counters', 50, 'logins_s',                   'logins/sec',                                      'per_s', false,  600,  1),
    ('sqlserver', 'counters', 'Counters', 50, 'logouts_s',                  'logouts/sec',                                     'per_s', false,  600,  2),
    ('sqlserver', 'counters', 'Counters', 50, 'connection_resets_s',        'connection resets/sec',                           'per_s', false,  600,  3),
    ('sqlserver', 'counters', 'Counters', 50, 'user_connections',           'user connections',                                'count', false,  600,  4),
    ('sqlserver', 'counters', 'Counters', 50, 'errors_user_s',              'user errors/sec',                                 'per_s', false,  600,  5),
    ('sqlserver', 'counters', 'Counters', 50, 'errors_kill_s',              'kill connection errors/sec',                      'per_s', false,  600,  6),
    ('sqlserver', 'counters', 'Counters', 50, 'errors_offline_s',           'DB offline errors/sec',                           'per_s', false,  600,  7),
    ('sqlserver', 'counters', 'Counters', 50, 'errors_info_s',              'info errors/sec',                                 'per_s', false,  600,  8),
    ('sqlserver', 'counters', 'Counters', 50, 'errors_total_s',             'errors/sec (all)',                                'per_s', false,  600,  9),
    ('sqlserver', 'counters', 'Counters', 50, 'compiles_per_100_batches',   'compilations per 100 batch requests (0 under 1 batch/s)', 'pct', false, 600, 10),
    ('sqlserver', 'counters', 'Counters', 50, 'recompiles_per_100_compiles','re-compilations per 100 compilations (0 under 1 compilation/s)', 'pct', false, 600, 11),
    ('sqlserver', 'counters', 'Counters', 50, 'page_splits_per_100_batches','page splits per 100 batch requests (0 under 1 batch/s)', 'count', false, 600, 12),
    ('sqlserver', 'counters', 'Counters', 50, 'page_lookups_per_batch',     'page lookups per batch request (0 under 1 batch/s)', 'count', false, 600, 13),
    ('sqlserver', 'counters', 'Counters', 50, 'full_scans_per_search',      'full scans per index search (0 under 10 searches/s)', 'count', false, 600, 14),
    ('sqlserver', 'counters', 'Counters', 50, 'readahead_pct',              'read-ahead pages per 100 page reads (0 under 1 read/s)', 'pct', false, 600, 15),
    ('sqlserver', 'counters', 'Counters', 50, 'page_reads_s',               'page reads/sec (volume)',                         'per_s', false,  600, 16),
    ('sqlserver', 'counters', 'Counters', 50, 'page_writes_s',              'page writes/sec (volume)',                        'per_s', false,  600, 17),
    ('sqlserver', 'counters', 'Counters', 50, 'lazy_writes_s',              'lazy writes/sec',                                 'per_s', false,  600, 18),
    ('sqlserver', 'counters', 'Counters', 50, 'free_list_stalls_s',         'free list stalls/sec',                            'per_s', false,  600, 19),
    ('sqlserver', 'counters', 'Counters', 50, 'lock_requests_s',            'lock requests/sec (volume)',                      'per_s', false,  600, 20),
    ('sqlserver', 'counters', 'Counters', 50, 'lock_waits_s',               'lock waits/sec',                                  'per_s', false,  600, 21),
    ('sqlserver', 'counters', 'Counters', 50, 'lock_timeouts_gt0_s',        'lock timeouts (timeout > 0)/sec',                 'per_s', false,  600, 22),
    ('sqlserver', 'counters', 'Counters', 50, 'avg_lock_wait_ms',           'average lock wait (0 with no wait in the read)',  'ms',    false,  600, 23),
    ('sqlserver', 'counters', 'Counters', 50, 'latch_waits_s',              'latch waits/sec',                                 'per_s', false,  600, 24),
    ('sqlserver', 'counters', 'Counters', 50, 'avg_latch_wait_ms',          'average latch wait (0 with no wait in the read)', 'ms',    false,  600, 25),
    ('sqlserver', 'counters', 'Counters', 50, 'buffer_cache_hit_pct',       'buffer cache hit ratio',                          'pct',   false,  600, 26),
    ('sqlserver', 'counters', 'Counters', 50, 'ple_per_4gb',                'page life expectancy per 4 GB of buffer pool (the lowest memory node)', 'secs', false, 600, 27),
    ('sqlserver', 'counters', 'Counters', 50, 'misguided_plans_s',          'misguided plan executions/sec',                   'per_s', false,  600, 28),
    ('sqlserver', 'counters', 'Counters', 50, 'update_conflict_pct',        'snapshot update conflicts per 100 snapshot updates', 'pct', false,  600, 29),
    ('sqlserver', 'counters', 'Counters', 50, 'memory_commit_pct',          'memory in use of the commit limit',               'pct',   false,  600, 30),
    ('sqlserver', 'counters', 'Counters', 50, 'failed_to_create_worker',    'schedulers that failed to create a worker',       'count', false,  600, 31),
    ('sqlserver', 'counters', 'Counters', 50, 'agent_active_jobs',          'SQL Agent jobs running',                          'count', false,  900, 32),
    ('sqlserver', 'counters', 'Counters', 50, 'agent_jobs_started',         'SQL Agent jobs started per read',                 'count', false,  900, 33),
    ('sqlserver', 'counters', 'Counters', 50, 'agent_jobs_failed',          'SQL Agent jobs failed or cancelled per read',     'count', false,  900, 34),
    ('sqlserver', 'counters', 'Counters', 50, 'agent_jobs_succeeded',       'SQL Agent jobs succeeded per read',               'count', false,  900, 35),
    ('sqlserver', 'counters', 'Counters', 50, 'write_transactions_s',       'write transactions/sec',                          'per_s', true,  1800, 36),
    ('sqlserver', 'counters', 'Counters', 50, 'log_flush_waits_s',          'log flush waits/sec',                             'per_s', true,  1800, 37),
    ('sqlserver', 'counters', 'Counters', 50, 'log_flush_wait_ms_s',        'log flush wait time per second',                  'ms',    true,  1800, 38),
    ('sqlserver', 'counters', 'Counters', 50, 'percent_log_used',           'log used',                                        'pct',   true,  1800, 39),
    ('sqlserver', 'counters', 'Counters', 50, 'active_transactions',        'active transactions',                             'count', true,  1800, 40),
    ('sqlserver', 'counters', 'Counters', 50, 'log_growths',                'log growths per read',                            'count', true,  1800, 41)
  ) AS v(engine, family, family_label, family_sort, metric, label, unit, per_database, fresh_secs, sort);

-- mssql_counter_points: the family's samples in (p_from, p_to] as (at, metric, value), for metric_points. p_database
-- names one database's series of the per-database metrics; NULL = the server's _Total. A rate read at raw 0 is 0 (the
-- read's zero_series); an average with no event in the read is 0; a ratio under its floor is 0.
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_points(p_instance_id int, p_from timestamptz, p_to timestamptz,
                                                         p_lookback interval DEFAULT interval '15 minutes', p_database text DEFAULT NULL)
RETURNS TABLE (at timestamptz, metric text, value double precision)
LANGUAGE sql STABLE SET jit = off AS $$
  WITH iv AS (SELECT * FROM pgvigil.mssql_counter_values(p_instance_id, p_from, p_to, 'instance')),
  i AS (
    SELECT v.snapshot_at,
      max(v.rate) FILTER (WHERE v.object = 'General Statistics' AND v.counter = 'Logins/sec') AS logins,
      max(v.rate) FILTER (WHERE v.object = 'General Statistics' AND v.counter = 'Logouts/sec') AS logouts,
      max(v.rate) FILTER (WHERE v.object = 'General Statistics' AND v.counter = 'Connection Reset/sec') AS resets,
      max(v.value) FILTER (WHERE v.object = 'General Statistics' AND v.counter = 'User Connections') AS user_conn,
      max(v.rate) FILTER (WHERE v.object = 'SQL Errors' AND v.inst = 'User Errors') AS err_user,
      max(v.rate) FILTER (WHERE v.object = 'SQL Errors' AND v.inst = 'Kill Connection Errors') AS err_kill,
      max(v.rate) FILTER (WHERE v.object = 'SQL Errors' AND v.inst = 'DB Offline Errors') AS err_offline,
      max(v.rate) FILTER (WHERE v.object = 'SQL Errors' AND v.inst = 'Info Errors') AS err_info,
      max(v.rate) FILTER (WHERE v.object = 'SQL Errors' AND v.inst = '_Total') AS err_total,
      max(v.rate) FILTER (WHERE v.object = 'SQL Statistics' AND v.counter = 'Batch Requests/sec') AS batch,
      max(v.rate) FILTER (WHERE v.object = 'SQL Statistics' AND v.counter = 'SQL Compilations/sec') AS compiles,
      max(v.rate) FILTER (WHERE v.object = 'SQL Statistics' AND v.counter = 'SQL Re-Compilations/sec') AS recompiles,
      max(v.rate) FILTER (WHERE v.object = 'SQL Statistics' AND v.counter = 'Misguided plan executions/sec') AS misguided,
      max(v.rate) FILTER (WHERE v.object = 'Access Methods' AND v.counter = 'Full Scans/sec') AS full_scans,
      max(v.rate) FILTER (WHERE v.object = 'Access Methods' AND v.counter = 'Index Searches/sec') AS searches,
      max(v.rate) FILTER (WHERE v.object = 'Access Methods' AND v.counter = 'Page Splits/sec') AS splits,
      max(v.rate) FILTER (WHERE v.object = 'Buffer Manager' AND v.counter = 'Page lookups/sec') AS lookups,
      max(v.rate) FILTER (WHERE v.object = 'Buffer Manager' AND v.counter = 'Page reads/sec') AS preads,
      max(v.rate) FILTER (WHERE v.object = 'Buffer Manager' AND v.counter = 'Page writes/sec') AS pwrites,
      max(v.rate) FILTER (WHERE v.object = 'Buffer Manager' AND v.counter = 'Readahead pages/sec') AS readahead,
      max(v.rate) FILTER (WHERE v.object = 'Buffer Manager' AND v.counter = 'Lazy writes/sec') AS lazy,
      max(v.rate) FILTER (WHERE v.object = 'Buffer Manager' AND v.counter = 'Free list stalls/sec') AS stalls,
      max(v.value) FILTER (WHERE v.object = 'Buffer Manager' AND v.counter = 'Buffer cache hit ratio') AS bchr_v,
      max(v.base) FILTER (WHERE v.object = 'Buffer Manager' AND v.counter = 'Buffer cache hit ratio') AS bchr_b,
      max(v.rate) FILTER (WHERE v.object = 'Locks' AND v.inst = '_Total' AND v.counter = 'Lock Requests/sec') AS lock_req,
      max(v.rate) FILTER (WHERE v.object = 'Locks' AND v.inst = '_Total' AND v.counter = 'Lock Waits/sec') AS lock_waits,
      max(v.rate) FILTER (WHERE v.object = 'Locks' AND v.inst = '_Total' AND v.counter = 'Lock Timeouts (timeout > 0)/sec') AS lock_to,
      max(v.dvalue) FILTER (WHERE v.object = 'Locks' AND v.inst = '_Total' AND v.counter = 'Average Wait Time (ms)') AS lw_dv,
      max(v.dbase) FILTER (WHERE v.object = 'Locks' AND v.inst = '_Total' AND v.counter = 'Average Wait Time (ms)') AS lw_db,
      max(v.rate) FILTER (WHERE v.object = 'Latches' AND v.counter = 'Latch Waits/sec') AS latch_waits,
      max(v.dvalue) FILTER (WHERE v.object = 'Latches' AND v.counter = 'Average Latch Wait Time (ms)') AS la_dv,
      max(v.dbase) FILTER (WHERE v.object = 'Latches' AND v.counter = 'Average Latch Wait Time (ms)') AS la_db,
      max(v.dvalue) FILTER (WHERE v.object = 'Transactions' AND v.counter = 'Update conflict ratio') AS uc_dv,
      max(v.dbase) FILTER (WHERE v.object = 'Transactions' AND v.counter = 'Update conflict ratio') AS uc_db,
      max(v.value) FILTER (WHERE v.object = 'sys.dm_os_process_memory' AND v.counter = 'physical_memory_in_use_kb') AS in_use_kb,
      max(v.value) FILTER (WHERE v.object = 'sys.dm_os_process_memory' AND v.counter = 'available_commit_limit_kb') AS commit_kb,
      max(v.value) FILTER (WHERE v.object = 'sys.dm_os_schedulers' AND v.counter = 'failed_to_create_worker') AS failed_worker
      FROM iv v GROUP BY v.snapshot_at),
  -- page life expectancy per 4 GB of each memory node's buffer pool (a node under 4 GB is judged as 4 GB): the lowest node
  n AS (SELECT v.snapshot_at, v.inst, max(v.value) FILTER (WHERE v.counter = 'Page life expectancy') AS ple,
               max(v.value) FILTER (WHERE v.counter = 'Database pages') AS pages
          FROM iv v WHERE v.object = 'Buffer Node' GROUP BY v.snapshot_at, v.inst),
  nn AS (SELECT n.snapshot_at, min(n.ple / greatest(1.0, coalesce(n.pages, 0) * 8.0 / 1048576 / 4)) AS ple4
           FROM n WHERE n.ple IS NOT NULL GROUP BY n.snapshot_at),
  d AS (
    SELECT v.snapshot_at,
      max(v.rate) FILTER (WHERE v.counter = 'Write Transactions/sec') AS wtx,
      max(v.rate) FILTER (WHERE v.counter = 'Log Flush Waits/sec') AS lfw,
      max(v.rate) FILTER (WHERE v.counter = 'Log Flush Wait Time') AS lfwt,
      max(v.value) FILTER (WHERE v.counter = 'Percent Log Used') AS plu,
      max(v.value) FILTER (WHERE v.counter = 'Active Transactions') AS atx,
      max(v.dvalue) FILTER (WHERE v.counter = 'Log Growths') AS growths
      FROM pgvigil.mssql_counter_values(p_instance_id, p_from, p_to, 'database') v
     WHERE v.object = 'Databases' AND v.inst = coalesce(p_database, '_Total')
     GROUP BY v.snapshot_at),
  -- SQL Agent's jobs at each instance read, from the job history FLEET stores (mssql_job_runs step 0, mssql_jobs'
  -- running_since): running at the read, started, and ended failed / cancelled or succeeded since the read before
  rd AS (SELECT c.snapshot_at, lag(c.snapshot_at) OVER (ORDER BY c.snapshot_at) AS prev
           FROM pgvigil.mssql_counter_read c
          WHERE c.instance_id = p_instance_id AND c.scope = 'instance' AND c.snapshot_at > p_from - p_lookback AND c.snapshot_at <= p_to),
  ag AS (SELECT rd.snapshot_at,
           (SELECT count(*) FROM pgvigil.mssql_job_runs j
             WHERE j.instance_id = p_instance_id AND j.step_id = 0 AND j.snapshot_at > rd.snapshot_at - interval '7 days'
               AND j.snapshot_at <= rd.snapshot_at AND j.snapshot_at + make_interval(secs => coalesce(j.duration_s, 0)) > rd.snapshot_at)
           + (SELECT count(*) FROM pgvigil.mssql_jobs m
               WHERE m.instance_id = p_instance_id AND m.running_since IS NOT NULL AND m.running_since <= rd.snapshot_at) AS active,
           (SELECT count(*) FROM pgvigil.mssql_job_runs j
             WHERE j.instance_id = p_instance_id AND j.step_id = 0 AND j.snapshot_at > rd.prev AND j.snapshot_at <= rd.snapshot_at) AS started,
           (SELECT count(*) FROM pgvigil.mssql_job_runs j
             WHERE j.instance_id = p_instance_id AND j.step_id = 0 AND j.run_status IN (0, 3) AND j.snapshot_at > rd.prev - interval '7 days'
               AND j.snapshot_at + make_interval(secs => coalesce(j.duration_s, 0)) > rd.prev
               AND j.snapshot_at + make_interval(secs => coalesce(j.duration_s, 0)) <= rd.snapshot_at) AS failed,
           (SELECT count(*) FROM pgvigil.mssql_job_runs j
             WHERE j.instance_id = p_instance_id AND j.step_id = 0 AND j.run_status = 1 AND j.snapshot_at > rd.prev - interval '7 days'
               AND j.snapshot_at + make_interval(secs => coalesce(j.duration_s, 0)) > rd.prev
               AND j.snapshot_at + make_interval(secs => coalesce(j.duration_s, 0)) <= rd.snapshot_at) AS succeeded
           FROM rd WHERE rd.prev IS NOT NULL AND rd.snapshot_at > p_from)
  SELECT i.snapshot_at, x.metric, x.value
    FROM i CROSS JOIN LATERAL (VALUES
      ('logins_s', i.logins::double precision), ('logouts_s', i.logouts::double precision),
      ('connection_resets_s', i.resets::double precision), ('user_connections', i.user_conn::double precision),
      ('errors_user_s', i.err_user::double precision), ('errors_kill_s', i.err_kill::double precision),
      ('errors_offline_s', i.err_offline::double precision), ('errors_info_s', i.err_info::double precision),
      ('errors_total_s', i.err_total::double precision),
      ('compiles_per_100_batches', CASE WHEN i.batch IS NULL OR i.compiles IS NULL THEN NULL WHEN i.batch < 1 THEN 0 ELSE 100.0 * i.compiles / i.batch END),
      ('recompiles_per_100_compiles', CASE WHEN i.compiles IS NULL OR i.recompiles IS NULL THEN NULL WHEN i.compiles < 1 THEN 0 ELSE 100.0 * i.recompiles / i.compiles END),
      ('page_splits_per_100_batches', CASE WHEN i.batch IS NULL OR i.splits IS NULL THEN NULL WHEN i.batch < 1 THEN 0 ELSE 100.0 * i.splits / i.batch END),
      ('page_lookups_per_batch', CASE WHEN i.batch IS NULL OR i.lookups IS NULL THEN NULL WHEN i.batch < 1 THEN 0 ELSE i.lookups / i.batch END),
      ('full_scans_per_search', CASE WHEN i.searches IS NULL OR i.full_scans IS NULL THEN NULL WHEN i.searches < 10 THEN 0 ELSE i.full_scans / i.searches END),
      ('readahead_pct', CASE WHEN i.preads IS NULL OR i.readahead IS NULL THEN NULL WHEN i.preads < 1 THEN 0 ELSE 100.0 * i.readahead / i.preads END),
      ('page_reads_s', i.preads::double precision), ('page_writes_s', i.pwrites::double precision),
      ('lazy_writes_s', i.lazy::double precision), ('free_list_stalls_s', i.stalls::double precision),
      ('lock_requests_s', i.lock_req::double precision), ('lock_waits_s', i.lock_waits::double precision),
      ('lock_timeouts_gt0_s', i.lock_to::double precision),
      ('avg_lock_wait_ms', CASE WHEN i.lw_db IS NULL THEN NULL WHEN i.lw_db = 0 THEN 0 ELSE i.lw_dv::double precision / i.lw_db END),
      ('latch_waits_s', i.latch_waits::double precision),
      ('avg_latch_wait_ms', CASE WHEN i.la_db IS NULL THEN NULL WHEN i.la_db = 0 THEN 0 ELSE i.la_dv::double precision / i.la_db END),
      ('buffer_cache_hit_pct', 100.0 * i.bchr_v / nullif(i.bchr_b, 0)),
      ('misguided_plans_s', i.misguided::double precision),
      ('update_conflict_pct', CASE WHEN i.uc_db IS NULL THEN NULL WHEN i.uc_db = 0 THEN 0 ELSE 100.0 * i.uc_dv / i.uc_db END),
      ('memory_commit_pct', 100.0 * i.in_use_kb / nullif(i.in_use_kb + i.commit_kb, 0)),
      ('failed_to_create_worker', i.failed_worker::double precision)) AS x(metric, value)
   WHERE x.value IS NOT NULL
  UNION ALL
  SELECT nn.snapshot_at, 'ple_per_4gb', nn.ple4::double precision FROM nn WHERE nn.ple4 IS NOT NULL
  UNION ALL
  SELECT d.snapshot_at, x.metric, x.value
    FROM d CROSS JOIN LATERAL (VALUES
      ('write_transactions_s', d.wtx::double precision), ('log_flush_waits_s', d.lfw::double precision),
      ('log_flush_wait_ms_s', d.lfwt::double precision), ('percent_log_used', d.plu::double precision),
      ('active_transactions', d.atx::double precision), ('log_growths', d.growths::double precision)) AS x(metric, value)
   WHERE x.value IS NOT NULL
  UNION ALL
  SELECT ag.snapshot_at, x.metric, x.value
    FROM ag CROSS JOIN LATERAL (VALUES
      ('agent_active_jobs', ag.active::double precision), ('agent_jobs_started', ag.started::double precision),
      ('agent_jobs_failed', ag.failed::double precision), ('agent_jobs_succeeded', ag.succeeded::double precision)) AS x(metric, value)
$$;

-- ---- the Counters page's other reads ----------------------------------------------------------------------------------

-- mssql_counter_histogram: the Batch Resp Statistics buckets over a window (T41): per bucket the batches and their
-- total time by elapsed and by CPU time, the changes summed over the window's reads
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_histogram(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (bucket text, lo_ms int, hi_ms int, elapsed_batches bigint, elapsed_total_ms bigint, cpu_batches bigint, cpu_total_ms bigint, reads bigint)
LANGUAGE sql STABLE AS $$
  SELECT v.counter, substring(v.counter FROM '>=0*([0-9]+)ms')::int, substring(v.counter FROM '<0*([0-9]+)ms')::int,
         sum(v.dvalue) FILTER (WHERE v.inst = 'Elapsed Time:Requests'), sum(v.dvalue) FILTER (WHERE v.inst = 'Elapsed Time:Total(ms)'),
         sum(v.dvalue) FILTER (WHERE v.inst = 'CPU Time:Requests'), sum(v.dvalue) FILTER (WHERE v.inst = 'CPU Time:Total(ms)'),
         count(DISTINCT v.snapshot_at) FILTER (WHERE v.dvalue IS NOT NULL)
    FROM pgvigil.mssql_counter_values(p_instance_id, p_from, p_to, 'instance') v
   WHERE v.object = 'Batch Resp Statistics'
   GROUP BY v.counter
   ORDER BY 2
$$;

-- mssql_counter_absent: the instance's listed counters with no series at its scope's newest read, and why: the
-- server has no such counter (the catalogue read says so, or has not been read), or it was listed after that read
CREATE OR REPLACE FUNCTION pgvigil.mssql_counter_absent(p_instance_id int, p_yaml jsonb DEFAULT '[]'::jsonb)
RETURNS TABLE (object text, counter text, inst text, scope text, why text)
LANGUAGE sql STABLE AS $$
  WITH l AS (SELECT e->>'object' AS object, e->>'counter' AS counter, coalesce(e->>'inst', '') AS inst, e->>'scope' AS scope
               FROM jsonb_array_elements(pgvigil.mssql_counter_list(p_instance_id, p_yaml)) e),
  r AS (SELECT DISTINCT ON (c.scope) c.scope, c.server_utc FROM pgvigil.mssql_counter_read c
         WHERE c.instance_id = p_instance_id ORDER BY c.scope, c.snapshot_at DESC),
  cat AS (SELECT max(k.read_at) AS read_at FROM pgvigil.mssql_counter_catalog k WHERE k.instance_id = p_instance_id)
  SELECT l.object, l.counter, l.inst, l.scope,
         CASE WHEN l.object LIKE 'sys.dm_os_%' THEN 'the DMV read did not give this column (see the collection''s log)'
              WHEN (SELECT read_at FROM cat) IS NULL THEN 'not in the newest read; the server''s counter catalogue has not been read yet'
              WHEN NOT EXISTS (SELECT 1 FROM pgvigil.mssql_counter_catalog k WHERE k.instance_id = p_instance_id
                                AND lower(k.object) = lower(l.object) AND lower(k.counter) = lower(l.counter))
                THEN 'this server has no such counter (its version or edition)'
              ELSE 'listed after the newest read, or no instance of it matched' END
    FROM l JOIN r ON r.scope = l.scope
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_counter_series k JOIN pgvigil.mssql_counter_last t ON t.series_id = k.series_id
                      WHERE k.instance_id = p_instance_id AND lower(k.object) = lower(l.object) AND lower(k.counter) = lower(l.counter)
                        AND (l.inst = '' OR k.inst = l.inst) AND t.server_utc = r.server_utc)
   ORDER BY l.object, l.counter, l.inst
$$;

-- ---- the memory clerks' friendly names (T24) ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.mssql_clerk_names (
  clerk_type  text PRIMARY KEY,
  name        text NOT NULL
);
DELETE FROM pgvigil.mssql_clerk_names;
-- Telegraf 1.40.3, plugins/inputs/sqlserver/sqlserverqueries.go (sqlServerMemoryClerks), MIT, Copyright (c) 2015-2025
-- InfluxData Inc.; its list thanks Bob Ward and Opserver's SQLInstance.Memory.cs
INSERT INTO pgvigil.mssql_clerk_names (clerk_type, name) VALUES
  ('CACHESTORE_BROKERDSH', 'Service Broker Dialog Security Header Cache'),
  ('CACHESTORE_BROKERKEK', 'Service Broker Key Exchange Key Cache'),
  ('CACHESTORE_BROKERREADONLY', 'Service Broker (Read-Only)'),
  ('CACHESTORE_BROKERRSB', 'Service Broker Null Remote Service Binding Cache'),
  ('CACHESTORE_BROKERTBLACS', 'Broker dormant rowsets'),
  ('CACHESTORE_BROKERTO', 'Service Broker Transmission Object Cache'),
  ('CACHESTORE_BROKERUSERCERTLOOKUP', 'Service Broker user certificates lookup result cache'),
  ('CACHESTORE_CLRPROC', 'CLR Procedure Cache'),
  ('CACHESTORE_CLRUDTINFO', 'CLR UDT Info'),
  ('CACHESTORE_COLUMNSTOREOBJECTPOOL', 'Column Store Object Pool'),
  ('CACHESTORE_CONVPRI', 'Conversation Priority Cache'),
  ('CACHESTORE_EVENTS', 'Event Notification Cache'),
  ('CACHESTORE_FULLTEXTSTOPLIST', 'Full Text Stoplist Cache'),
  ('CACHESTORE_NOTIF', 'Notification Store'),
  ('CACHESTORE_OBJCP', 'Object Plans'),
  ('CACHESTORE_PHDR', 'Bound Trees'),
  ('CACHESTORE_SEARCHPROPERTYLIST', 'Search Property List Cache'),
  ('CACHESTORE_SEHOBTCOLUMNATTRIBUTE', 'SE Shared Column Metadata Cache'),
  ('CACHESTORE_SQLCP', 'SQL Plans'),
  ('CACHESTORE_STACKFRAMES', 'SOS_StackFramesStore'),
  ('CACHESTORE_SYSTEMROWSET', 'System Rowset Store'),
  ('CACHESTORE_TEMPTABLES', 'Temporary Tables & Table Variables'),
  ('CACHESTORE_VIEWDEFINITIONS', 'View Definition Cache'),
  ('CACHESTORE_XML_SELECTIVE_DG', 'XML DB Cache (Selective)'),
  ('CACHESTORE_XMLDBATTRIBUTE', 'XML DB Cache (Attribute)'),
  ('CACHESTORE_XMLDBELEMENT', 'XML DB Cache (Element)'),
  ('CACHESTORE_XMLDBTYPE', 'XML DB Cache (Type)'),
  ('CACHESTORE_XPROC', 'Extended Stored Procedures'),
  ('MEMORYCLERK_FILETABLE', 'Memory Clerk (File Table)'),
  ('MEMORYCLERK_FSCHUNKER', 'Memory Clerk (FS Chunker)'),
  ('MEMORYCLERK_FULLTEXT', 'Full Text'),
  ('MEMORYCLERK_FULLTEXT_SHMEM', 'Full-text IG'),
  ('MEMORYCLERK_HADR', 'HADR'),
  ('MEMORYCLERK_HOST', 'Host'),
  ('MEMORYCLERK_LANGSVC', 'Language Service'),
  ('MEMORYCLERK_LWC', 'Light Weight Cache'),
  ('MEMORYCLERK_QSRANGEPREFETCH', 'QS Range Prefetch'),
  ('MEMORYCLERK_SERIALIZATION', 'Serialization'),
  ('MEMORYCLERK_SNI', 'SNI'),
  ('MEMORYCLERK_SOSMEMMANAGER', 'SOS Memory Manager'),
  ('MEMORYCLERK_SOSNODE', 'SOS Node'),
  ('MEMORYCLERK_SOSOS', 'SOS Memory Clerk'),
  ('MEMORYCLERK_SQLBUFFERPOOL', 'Buffer Pool'),
  ('MEMORYCLERK_SQLCLR', 'CLR'),
  ('MEMORYCLERK_SQLCLRASSEMBLY', 'CLR Assembly'),
  ('MEMORYCLERK_SQLCONNECTIONPOOL', 'Connection Pool'),
  ('MEMORYCLERK_SQLGENERAL', 'General'),
  ('MEMORYCLERK_SQLHTTP', 'HTTP'),
  ('MEMORYCLERK_SQLLOGPOOL', 'Log Pool'),
  ('MEMORYCLERK_SQLOPTIMIZER', 'SQL Optimizer'),
  ('MEMORYCLERK_SQLQERESERVATIONS', 'SQL Reservations'),
  ('MEMORYCLERK_SQLQUERYCOMPILE', 'SQL Query Compile'),
  ('MEMORYCLERK_SQLQUERYEXEC', 'SQL Query Exec'),
  ('MEMORYCLERK_SQLQUERYPLAN', 'SQL Query Plan'),
  ('MEMORYCLERK_SQLSERVICEBROKER', 'SQL Service Broker'),
  ('MEMORYCLERK_SQLSERVICEBROKERTRANSPORT', 'Unified Communication Stack'),
  ('MEMORYCLERK_SQLSOAP', 'SQL SOAP'),
  ('MEMORYCLERK_SQLSOAPSESSIONSTORE', 'SQL SOAP (Session Store)'),
  ('MEMORYCLERK_SQLSTORENG', 'SQL Storage Engine'),
  ('MEMORYCLERK_SQLUTILITIES', 'SQL Utilities'),
  ('MEMORYCLERK_SQLXML', 'SQL XML'),
  ('MEMORYCLERK_SQLXP', 'SQL XP'),
  ('MEMORYCLERK_TRACE_EVTNOTIF', 'Trace Event Notification'),
  ('MEMORYCLERK_XE', 'XE Engine'),
  ('MEMORYCLERK_XE_BUFFER', 'XE Buffer'),
  ('MEMORYCLERK_XTP', 'In-Memory OLTP'),
  ('OBJECTSTORE_LBSS', 'Lbss Cache (Object Store)'),
  ('OBJECTSTORE_LOCK_MANAGER', 'Lock Manager (Object Store)'),
  ('OBJECTSTORE_SECAUDIT_EVENT_BUFFER', 'Audit Event Buffer (Object Store)'),
  ('OBJECTSTORE_SERVICE_BROKER', 'Service Broker (Object Store)'),
  ('OBJECTSTORE_SNI_PACKET', 'SNI Packet (Object Store)'),
  ('OBJECTSTORE_XACT_CACHE', 'Transactions Cache (Object Store)'),
  ('USERSTORE_DBMETADATA', 'DB Metadata (User Store)'),
  ('USERSTORE_OBJPERM', 'Object Permissions (User Store)'),
  ('USERSTORE_SCHEMAMGR', 'Schema Manager (User Store)'),
  ('USERSTORE_SXC', 'SXC (User Store)'),
  ('USERSTORE_TOKENPERM', 'Token Permissions (User Store)'),
  ('USERSTORE_QDSSTMT', 'QDS Statement Buffer (Pre-persist)'),
  ('CACHESTORE_QDSRUNTIMESTATS', 'QDS Runtime Stats (Pre-persist)'),
  ('CACHESTORE_QDSCONTEXTSETTINGS', 'QDS Unique Context Settings'),
  ('MEMORYCLERK_QUERYDISKSTORE', 'QDS General'),
  ('MEMORYCLERK_QUERYDISKSTORE_HASHMAP', 'QDS Query/Plan Hash Table');
