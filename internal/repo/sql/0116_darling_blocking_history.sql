-- 0116: blocking over the range in Erik Darling's shape (task 177, darling-open D04).
--
-- The blocked-process reports keep what sp_HumanEventsBlockViewer 5.11 reads from each (both sides' isolation level,
-- lock mode, status, transaction count and name, last batch started and completed, last transaction started, log
-- used, priority, client options; the event's transaction id, object id, resource owner type and the report's monitor
-- loop), and its findings are made here from the stored reports with its own rules and wording:
--   mssql_lock_object(instance, wait_resource, at)  the contended object of a lock resource, schema.object, from
--                                pgvigil's own minute decode of the same lock (mssql_waiting_tasks, migration 0108),
--                                NULL when no read decoded it (the proc asks the server's catalog; pgvigil never runs
--                                a catalog query for a report)
--   mssql_blocks(instance, from, to)          the proc's #blocks: two rows per report (the blocked side and the
--                                blocking side), the event's database and transaction id on both; the reports of
--                                pgvigil's own capture, else (no such report in the window) system_health's
--   mssql_block_findings(instance, from, to)  the proc's #block_findings: checks 1-10, 1000 and 1001 with its words
--   mssql_block_rollup(instance, from, to)    the blocked wait per lead blocker, object, database and login / app /
--                                host (the victim rows, each blocked transaction's longest wait once, as the proc)
--   mssql_block_pairs(instance, from, to)     the blocked / blocking pairs of the minute snapshots (mssql_requests)
-- system_health's QUERY_PROCESSING results carry blockingTasks when no capture of pgvigil runs: the syshealth reader
-- hands them over in a component row's detail (pgvigil_blocked_reports) and a trigger stores them here with source
-- 'system_health' and keeps the detail without them.
--
-- Ported from sp_HumanEventsBlockViewer 5.11 and sp_HealthParser 3.11, Copyright 2026 Darling Data, LLC
-- (https://github.com/erikdarlingdata/DarlingData), MIT License:
-- Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
-- documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
-- rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
-- permit persons to whom the Software is furnished to do so, subject to the following conditions: The above copyright
-- notice and this permission notice shall be included in all copies or substantial portions of the Software.
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
-- WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
-- COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
-- OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

ALTER TABLE pgvigil.mssql_blocked_reports
  ADD COLUMN IF NOT EXISTS source                         text NOT NULL DEFAULT 'product',   -- product | system_health
  ADD COLUMN IF NOT EXISTS transaction_id                 bigint,   -- the event's (system_health: the blocked xactid)
  ADD COLUMN IF NOT EXISTS object_id                      bigint,
  ADD COLUMN IF NOT EXISTS database_id                    int,
  ADD COLUMN IF NOT EXISTS resource_owner_type            text,
  ADD COLUMN IF NOT EXISTS monitor_loop                   bigint,
  ADD COLUMN IF NOT EXISTS blocked_wait_ms                bigint,   -- the blocked process's waittime as the report gives it
  ADD COLUMN IF NOT EXISTS blocked_ecid                   int,
  ADD COLUMN IF NOT EXISTS blocked_status                 text,
  ADD COLUMN IF NOT EXISTS blocked_isolation              text,
  ADD COLUMN IF NOT EXISTS blocked_lock_mode              text,
  ADD COLUMN IF NOT EXISTS blocked_trancount              int,
  ADD COLUMN IF NOT EXISTS blocked_transaction_name       text,
  ADD COLUMN IF NOT EXISTS blocked_last_batch             text,     -- the server's own clock, no zone, as the report
  ADD COLUMN IF NOT EXISTS blocked_last_batch_completed   text,
  ADD COLUMN IF NOT EXISTS blocked_last_tran_started      text,
  ADD COLUMN IF NOT EXISTS blocked_log_used               bigint,
  ADD COLUMN IF NOT EXISTS blocked_priority               int,
  ADD COLUMN IF NOT EXISTS blocked_clientoption1          bigint,
  ADD COLUMN IF NOT EXISTS blocked_clientoption2          bigint,
  ADD COLUMN IF NOT EXISTS blocked_xactid                 bigint,
  ADD COLUMN IF NOT EXISTS blocked_currentdb              text,
  ADD COLUMN IF NOT EXISTS blocking_ecid                  int,
  ADD COLUMN IF NOT EXISTS blocking_isolation             text,
  ADD COLUMN IF NOT EXISTS blocking_lock_mode             text,
  ADD COLUMN IF NOT EXISTS blocking_transaction_name      text,
  ADD COLUMN IF NOT EXISTS blocking_last_batch_completed  text,
  ADD COLUMN IF NOT EXISTS blocking_last_tran_started     text,
  ADD COLUMN IF NOT EXISTS blocking_log_used              bigint,
  ADD COLUMN IF NOT EXISTS blocking_priority              int,
  ADD COLUMN IF NOT EXISTS blocking_clientoption1         bigint,
  ADD COLUMN IF NOT EXISTS blocking_clientoption2         bigint,
  ADD COLUMN IF NOT EXISTS blocking_xactid                bigint,
  ADD COLUMN IF NOT EXISTS blocking_currentdb             text,
  ADD COLUMN IF NOT EXISTS blocking_wait_resource         text,
  ADD COLUMN IF NOT EXISTS blocking_wait_ms               bigint,
  ADD COLUMN IF NOT EXISTS blocking_sql_handle            text,     -- the first frame with a handle: the lead's identity
  ADD COLUMN IF NOT EXISTS blocking_stmtstart             int,
  ADD COLUMN IF NOT EXISTS blocking_stmtend               int;

-- the columns 0116 adds, from one payload row (the importer's UPDATE and the system_health trigger's INSERT share it)
CREATE OR REPLACE FUNCTION pgvigil.mssql_blocked_extra(r jsonb)
RETURNS TABLE (source text, transaction_id bigint, object_id bigint, database_id int, resource_owner_type text, monitor_loop bigint,
               blocked_wait_ms bigint, blocked_ecid int, blocked_status text, blocked_isolation text, blocked_lock_mode text,
               blocked_trancount int, blocked_transaction_name text, blocked_last_batch text, blocked_last_batch_completed text,
               blocked_last_tran_started text, blocked_log_used bigint, blocked_priority int, blocked_clientoption1 bigint,
               blocked_clientoption2 bigint, blocked_xactid bigint, blocked_currentdb text, blocking_ecid int,
               blocking_isolation text, blocking_lock_mode text, blocking_transaction_name text,
               blocking_last_batch_completed text, blocking_last_tran_started text, blocking_log_used bigint,
               blocking_priority int, blocking_clientoption1 bigint, blocking_clientoption2 bigint, blocking_xactid bigint,
               blocking_currentdb text, blocking_wait_resource text, blocking_wait_ms bigint, blocking_sql_handle text,
               blocking_stmtstart int, blocking_stmtend int)
LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(r->>'source', 'product'), (r->>'transaction_id')::bigint, (r->>'object_id')::bigint, (r->>'database_id')::int,
         r->>'resource_owner_type', (r->>'monitor_loop')::bigint, (r->>'blocked_wait_ms')::bigint, (r->>'blocked_ecid')::int,
         r->>'blocked_status', r->>'blocked_isolation', r->>'blocked_lock_mode', (r->>'blocked_trancount')::int,
         r->>'blocked_transaction_name', r->>'blocked_last_batch', r->>'blocked_last_batch_completed', r->>'blocked_last_tran_started',
         (r->>'blocked_log_used')::bigint, (r->>'blocked_priority')::int, (r->>'blocked_clientoption1')::bigint,
         (r->>'blocked_clientoption2')::bigint, (r->>'blocked_xactid')::bigint, r->>'blocked_currentdb', (r->>'blocking_ecid')::int,
         r->>'blocking_isolation', r->>'blocking_lock_mode', r->>'blocking_transaction_name', r->>'blocking_last_batch_completed',
         r->>'blocking_last_tran_started', (r->>'blocking_log_used')::bigint, (r->>'blocking_priority')::int,
         (r->>'blocking_clientoption1')::bigint, (r->>'blocking_clientoption2')::bigint, (r->>'blocking_xactid')::bigint,
         r->>'blocking_currentdb', r->>'blocking_wait_resource', (r->>'blocking_wait_ms')::bigint, r->>'blocking_sql_handle',
         (r->>'blocking_stmtstart')::int, (r->>'blocking_stmtend')::int
$$;

-- The importer: 0065's, renamed import_mssql_xe_base and called first, then the new columns of the reports this import
-- stored (a second import of an old event stores nothing and changes nothing). Renamed once: a rerun finds the base.
DO $$
BEGIN
  IF to_regprocedure('pgvigil.import_mssql_xe_base(integer, timestamp with time zone, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_xe(int, timestamptz, jsonb) RENAME TO import_mssql_xe_base;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_xe(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.import_mssql_xe_base(p_instance_id, p_snapshot_at, p_payload);
  UPDATE pgvigil.mssql_blocked_reports b
     SET (source, transaction_id, object_id, database_id, resource_owner_type, monitor_loop, blocked_wait_ms, blocked_ecid,
          blocked_status, blocked_isolation, blocked_lock_mode, blocked_trancount, blocked_transaction_name, blocked_last_batch,
          blocked_last_batch_completed, blocked_last_tran_started, blocked_log_used, blocked_priority, blocked_clientoption1,
          blocked_clientoption2, blocked_xactid, blocked_currentdb, blocking_ecid, blocking_isolation, blocking_lock_mode,
          blocking_transaction_name, blocking_last_batch_completed, blocking_last_tran_started, blocking_log_used,
          blocking_priority, blocking_clientoption1, blocking_clientoption2, blocking_xactid, blocking_currentdb,
          blocking_wait_resource, blocking_wait_ms, blocking_sql_handle, blocking_stmtstart, blocking_stmtend)
       = (SELECT * FROM pgvigil.mssql_blocked_extra(r))
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'blocked' AND r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL
     AND b.instance_id = p_instance_id AND b.event_at = (r->>'event_at')::timestamptz AND b.event_key = r->>'event_key'
     AND b.snapshot_at = p_snapshot_at;
END $$;

-- system_health's blocked reports, handed over in a QUERY_PROCESSING component row's detail: stored as reports of
-- source 'system_health' (a report already stored is kept), the detail kept without them.
CREATE OR REPLACE FUNCTION pgvigil.mssql_health_blocked_move()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NOT (NEW.detail ? 'pgvigil_blocked_reports') THEN
    RETURN NEW;
  END IF;
  -- the months were opened and the parent locked by import_mssql_readers before its own parents (purge()'s name order)
  IF jsonb_typeof(NEW.detail -> 'pgvigil_blocked_reports') = 'array' THEN
    INSERT INTO pgvigil.mssql_blocked_reports (instance_id, event_at, event_key, snapshot_at, session_name, database_name,
        wait_resource, wait_ms, lock_mode, blocked_spid, blocked_login, blocked_host, blocked_program, blocked_statement,
        blocking_spid, blocking_status, blocking_trancount, blocking_login, blocking_host, blocking_program,
        blocking_statement, blocking_last_batch, head_key, report,
        source, transaction_id, object_id, database_id, resource_owner_type, monitor_loop, blocked_wait_ms, blocked_ecid,
        blocked_status, blocked_isolation, blocked_lock_mode, blocked_trancount, blocked_transaction_name, blocked_last_batch,
        blocked_last_batch_completed, blocked_last_tran_started, blocked_log_used, blocked_priority, blocked_clientoption1,
        blocked_clientoption2, blocked_xactid, blocked_currentdb, blocking_ecid, blocking_isolation, blocking_lock_mode,
        blocking_transaction_name, blocking_last_batch_completed, blocking_last_tran_started, blocking_log_used,
        blocking_priority, blocking_clientoption1, blocking_clientoption2, blocking_xactid, blocking_currentdb,
        blocking_wait_resource, blocking_wait_ms, blocking_sql_handle, blocking_stmtstart, blocking_stmtend)
    SELECT NEW.instance_id, (r->>'event_at')::timestamptz, r->>'event_key', NEW.snapshot_at, r->>'session_name', r->>'database_name',
           r->>'wait_resource', (r->>'wait_ms')::bigint, r->>'lock_mode', (r->>'blocked_spid')::int, r->>'blocked_login',
           r->>'blocked_host', r->>'blocked_program', r->>'blocked_statement', (r->>'blocking_spid')::int, r->>'blocking_status',
           (r->>'blocking_trancount')::int, r->>'blocking_login', r->>'blocking_host', r->>'blocking_program', r->>'statement',
           r->>'blocking_last_batch', r->>'head_key', r->>'report', x.*
      FROM jsonb_array_elements(NEW.detail -> 'pgvigil_blocked_reports') r
     CROSS JOIN LATERAL pgvigil.mssql_blocked_extra(r || '{"source": "system_health"}'::jsonb) x
     WHERE r->>'event_at' IS NOT NULL AND r->>'event_key' IS NOT NULL
    ON CONFLICT DO NOTHING;
  END IF;
  NEW.detail := NEW.detail - 'pgvigil_blocked_reports';
  RETURN NEW;
END $$;

-- The readers' importer (0091), renamed import_mssql_readers_base and called after mssql_blocked_reports is ready: the
-- months its QUERY_PROCESSING rows' reports need are opened and the parent locked FIRST, so its parents are taken in
-- purge()'s name order (mssql_blocked_reports, then mssql_errorlog, mssql_health_components, mssql_trace_events) and
-- a purge and an import cannot each hold one and wait for the other.
DO $$
BEGIN
  IF to_regprocedure('pgvigil.import_mssql_readers_base(integer, timestamp with time zone, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_readers(int, timestamptz, jsonb) RENAME TO import_mssql_readers_base;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_readers(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_m record;
BEGIN
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
              WHERE r->>'kind' = 'component' AND jsonb_typeof(r->'detail'->'pgvigil_blocked_reports') = 'array') THEN
    FOR v_m IN
      SELECT DISTINCT date_trunc('month', (x->>'event_at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC' AS month_at
        FROM jsonb_array_elements(p_payload) r, jsonb_array_elements(r->'detail'->'pgvigil_blocked_reports') x
       WHERE r->>'kind' = 'component' AND jsonb_typeof(r->'detail'->'pgvigil_blocked_reports') = 'array' AND x->>'event_at' IS NOT NULL
       ORDER BY 1
    LOOP
      PERFORM pgvigil.mssql_event_partition('mssql_blocked_reports', v_m.month_at);
    END LOOP;
    LOCK TABLE ONLY pgvigil.mssql_blocked_reports IN ROW EXCLUSIVE MODE;
  END IF;
  PERFORM pgvigil.import_mssql_readers_base(p_instance_id, p_snapshot_at, p_payload);
END $$;

DROP TRIGGER IF EXISTS mssql_health_blocked_move ON pgvigil.mssql_health_components;
CREATE TRIGGER mssql_health_blocked_move BEFORE INSERT ON pgvigil.mssql_health_components
  FOR EACH ROW EXECUTE FUNCTION pgvigil.mssql_health_blocked_move();

-- The contended object of a lock resource as the proc decodes it (KEY db:hobt, OBJECT db:objid, PAGE / RID
-- db:file:page; an embedded KEY / PAGE token of a compound resource first), named by pgvigil's own minute decode of the
-- same lock: the waiting-tasks read nearest the moment that decoded that database's hobt, object or page, its name
-- without the database part (schema.object, as the proc writes it).
CREATE OR REPLACE FUNCTION pgvigil.mssql_lock_type(p_wait_resource text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
           WHEN coalesce(p_wait_resource, '') = '' THEN NULL
           WHEN p_wait_resource LIKE '%KEY: %' THEN 'KEY'
           WHEN p_wait_resource LIKE '%OBJECT: %' THEN 'OBJECT'
           WHEN p_wait_resource LIKE '%RID: %' THEN 'RID'
           WHEN p_wait_resource LIKE '%PAGE: %' THEN 'PAGE'
           ELSE left(upper(split_part(p_wait_resource, ':', 1)), 32)
         END
$$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_lock_object(p_instance_id int, p_wait_resource text, p_at timestamptz)
RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_type text := pgvigil.mssql_lock_type(p_wait_resource);
  v_frag text;
  v_parts text[];
  v_pat text;
  v_name text;
BEGIN
  IF v_type IS NULL OR v_type NOT IN ('KEY', 'OBJECT', 'RID', 'PAGE') THEN
    RETURN NULL;
  END IF;
  v_frag := substr(p_wait_resource, strpos(p_wait_resource, v_type || ': ') + length(v_type) + 2);
  v_parts := string_to_array(split_part(v_frag, ' ', 1), ':');
  IF coalesce(v_parts[1], '') !~ '^\d+$' OR coalesce(v_parts[2], '') !~ '^\d+$' THEN
    RETURN NULL;
  END IF;
  -- the resource's own id as D01's waiting-tasks read keeps it (keylock hobtid=, objectlock objid=, pagelock / ridlock
  -- fileid= pageid=), the database by its dbid=: the fields' order in resource_description varies
  v_pat := CASE v_type
             WHEN 'KEY' THEN '\mhobtid=' || v_parts[2] || '\M'
             WHEN 'OBJECT' THEN '\mobjid=' || v_parts[2] || '\M'
             ELSE '\mfileid=' || v_parts[2] || '\M'
           END;
  -- the waiting-tasks read keeps database.schema.object (0108); the procedure names schema.object
  SELECT CASE WHEN wt.database_name IS NOT NULL AND left(wt.object_name, length(wt.database_name) + 1) = wt.database_name || '.'
              THEN substr(wt.object_name, length(wt.database_name) + 2) ELSE wt.object_name END INTO v_name
    FROM pgvigil.mssql_waiting_tasks wt
   WHERE wt.instance_id = p_instance_id
     AND wt.snapshot_at > p_at - interval '1 day' AND wt.snapshot_at < p_at + interval '1 day'
     AND wt.object_name IS NOT NULL
     AND wt.resource_description ~ ('\mdbid=' || v_parts[1] || '\M')
     AND wt.resource_description ~ v_pat
     AND (v_type IN ('KEY', 'OBJECT') OR (v_parts[3] ~ '^\d+$' AND wt.resource_description ~ ('\mpageid=' || v_parts[3] || '\M')))
   ORDER BY abs(extract(epoch FROM wt.snapshot_at - p_at))
   LIMIT 1;
  RETURN v_name;
END $$;

-- The proc's #blocks: two rows per report, the blocked side ('blocked') and the blocking side ('blocking'); the
-- event's database and transaction id on both (its findings count blocked transactions). The reports of pgvigil's own
-- capture; system_health's only where the window holds none of them. contentious_object: the row's own wait resource
-- decoded, else the other side's of the same report, else the proc's sentinel 'Unresolved: <type> lock, database: <db>'.
CREATE OR REPLACE FUNCTION pgvigil.mssql_blocks(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (event_at timestamptz, event_key text, source text, activity text, database_name text, contentious_object text,
               spid int, ecid int, blocking_desc text, blocked_desc text, monitor_loop bigint, transaction_id bigint,
               status text, isolation_level text, lock_mode text, resource_owner_type text, transaction_count int,
               transaction_name text, last_transaction_started text, last_transaction_completed text, wait_resource text,
               wait_time_ms bigint, priority int, log_used bigint, client_app text, host_name text, login_name text,
               query_text text, sql_handle text, stmtstart int, stmtend int, victim_wait_ms bigint)
LANGUAGE sql STABLE AS $$
  WITH r AS (
    SELECT b.*
      FROM pgvigil.mssql_blocked_reports b
     WHERE b.instance_id = p_instance_id AND b.event_at > p_from AND b.event_at <= p_to
       AND (b.source = 'product'
            OR NOT EXISTS (SELECT 1 FROM pgvigil.mssql_blocked_reports p
                            WHERE p.instance_id = p_instance_id AND p.event_at > p_from AND p.event_at <= p_to AND p.source = 'product'))
  ), objs AS (   -- each lock resource decoded once (a long block repeats the same resource in every report)
    SELECT x.w, pgvigil.mssql_lock_object(p_instance_id, x.w, min(x.at)) AS obj
      FROM (SELECT r.wait_resource AS w, r.event_at AS at FROM r
            UNION ALL SELECT r.blocking_wait_resource, r.event_at FROM r) x
     WHERE x.w IS NOT NULL AND pgvigil.mssql_lock_type(x.w) IN ('KEY', 'OBJECT', 'RID', 'PAGE')
     GROUP BY x.w
  ), d AS (
    SELECT r.*,
           '(' || r.blocking_spid || ':' || coalesce(r.blocking_ecid, 0) || ')' AS bg_desc,
           '(' || r.blocked_spid || ':' || coalesce(r.blocked_ecid, 0) || ')' AS bd_desc,
           (SELECT o.obj FROM objs o WHERE o.w = r.wait_resource) AS bd_obj,
           (SELECT o.obj FROM objs o WHERE o.w = r.blocking_wait_resource) AS bg_obj,
           -- a report stored before 0116 has no event transaction id: the blocked xactid, else the blocked session
           coalesce(r.transaction_id, r.blocked_xactid, -r.blocked_spid) AS tx,
           coalesce(r.blocked_wait_ms, r.wait_ms) AS bd_wait,
           -- system_health's reports carry no monitor loop of their own (0): each component result is its own loop
           CASE WHEN r.source = 'system_health' THEN extract(epoch FROM r.event_at)::bigint ELSE coalesce(r.monitor_loop, 0) END AS loop_
      FROM r
  )
  SELECT d.event_at, d.event_key, d.source, s.activity, d.database_name,
         coalesce(s.obj, s.other_obj,
                  'Unresolved: ' || CASE WHEN pgvigil.mssql_lock_type(s.wait_resource) IS NULL THEN ''
                                         ELSE lower(pgvigil.mssql_lock_type(s.wait_resource)) || ' lock, ' END
                  || 'database: ' || coalesce(d.database_name, 'unknown')),
         s.spid, s.ecid, coalesce(d.bg_desc, 'unresolved process'), d.bd_desc, d.loop_, d.tx,
         s.status, s.isolation, s.lock_mode, d.resource_owner_type, s.trancount, s.transaction_name, s.last_batch, s.last_done,
         s.wait_resource, s.wait_ms, s.priority, s.log_used, s.program, s.host, s.login, s.statement,
         d.blocking_sql_handle, d.blocking_stmtstart, d.blocking_stmtend, coalesce(d.bd_wait, 0)
    FROM d
   CROSS JOIN LATERAL (VALUES
     ('blocked', d.bd_obj, d.bg_obj, d.blocked_spid, d.blocked_ecid, d.blocked_status, d.blocked_isolation, d.blocked_lock_mode,
      d.blocked_trancount, d.blocked_transaction_name, d.blocked_last_tran_started, d.blocked_last_batch_completed, d.wait_resource,
      d.bd_wait, d.blocked_priority, d.blocked_log_used, d.blocked_program, d.blocked_host, d.blocked_login, d.blocked_statement),
     ('blocking', d.bg_obj, d.bd_obj, d.blocking_spid, d.blocking_ecid, d.blocking_status, d.blocking_isolation, d.blocking_lock_mode,
      d.blocking_trancount, d.blocking_transaction_name, d.blocking_last_batch, d.blocking_last_batch_completed, d.blocking_wait_resource,
      d.blocking_wait_ms, d.blocking_priority, d.blocking_log_used, d.blocking_program, d.blocking_host, d.blocking_login, d.blocking_statement)
   ) s(activity, obj, other_obj, spid, ecid, status, isolation, lock_mode, trancount, transaction_name, last_batch, last_done,
       wait_resource, wait_ms, priority, log_used, program, host, login, statement)
$$;

-- The lead blocker's name as the proc's per_victim_named makes it: an input buffer 'Proc [Database Id = N Object Id = M]'
-- (a procedure call) becomes schema.procedure, here from pgvigil's own procedure reads (mssql_proc_sample, the newest
-- with a name); anything else, or a procedure no read named, stays the input buffer as it is.
CREATE OR REPLACE FUNCTION pgvigil.mssql_lead_name(p_instance_id int, p_text text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce(
           (SELECT ps.schema_name || '.' || ps.object_name
              FROM pgvigil.mssql_proc_sample ps
             WHERE ps.instance_id = p_instance_id
               AND ps.database_id = (substring(ltrim(p_text, chr(65279)) FROM '^Proc \[Database Id = (\d+)'))::int
               AND ps.object_id = (substring(ltrim(p_text, chr(65279)) FROM '^Proc \[Database Id = \d+ Object Id = (\d+)'))::bigint
               AND ps.schema_name IS NOT NULL AND ps.object_name IS NOT NULL
             ORDER BY ps.snapshot_at DESC
             LIMIT 1),
           p_text)
$$;

-- '<days> <hh:mi:ss:mmm>' as the proc writes a wait sum: CONVERT(nvarchar(30), ms / 1000 / 86400) + ' ' +
-- CONVERT(nvarchar(30), DATEADD(SECOND, ms / 1000 % 86400, '19000101'), 14)
CREATE OR REPLACE FUNCTION pgvigil.mssql_block_dhms(p_ms bigint)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT (p_ms / 1000 / 86400)::text || ' '
         || to_char(timestamp '1900-01-01' + make_interval(secs => (p_ms / 1000 % 86400)::float8), 'HH24:MI:SS:MS')
$$;

-- The proc's findings over the stored reports, its check ids, groups and words (checks 1-10, 1000, 1001; its header
-- row -1 and its closing row are its own). Ordered as it orders them: check, group, the rank within the group.
CREATE OR REPLACE FUNCTION pgvigil.mssql_block_findings(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (check_id int, database_name text, object_name text, finding_group text, finding text, sort_order bigint)
LANGUAGE sql STABLE AS $$
  WITH b AS (SELECT * FROM pgvigil.mssql_blocks(p_instance_id, p_from, p_to)),
  rcsi AS (
    SELECT o.database_name, o.options->>'rcsi' = 'on' AS on_
      FROM pgvigil.mssql_database_option o WHERE o.instance_id = p_instance_id AND o.is_present
  ),
  by_status(grp, word, cond) AS (VALUES
    ('Sleeping Query Blocking', ' sleeping queries involved in blocking sessions in ', 'sleeping'),
    ('Background Query Blocking', ' background queries involved in blocking sessions in ', 'background'),
    ('Done Query Blocking', ' done queries involved in blocking sessions in ', 'done')
  ),
  by_tran(grp, word, cond) AS (VALUES
    ('Implicit Transaction Blocking', ' implicit transaction queries involved in blocking sessions in ', 'implicit_transaction'),
    ('User Transaction Blocking', ' user transaction queries involved in blocking sessions in ', 'user_transaction'),
    ('Auto-Stats Update Blocking', ' auto stats updates involved in blocking sessions in ', 'sqlsource_transform')
  ),
  -- the lead blocker of each session per monitor loop (the proc's #session_leads): the top of its chain, the cycle
  -- fallback its own lead
  pairs AS (SELECT DISTINCT b.monitor_loop, b.blocking_desc, b.blocked_desc FROM b),
  walk AS (
    WITH RECURSIVE w(monitor_loop, lead_desc, session_desc, lead_path) AS (
      SELECT p.monitor_loop, p.blocking_desc, p.blocking_desc, p.blocking_desc
        FROM pairs p
       WHERE NOT EXISTS (SELECT 1 FROM pairs p2 WHERE p2.monitor_loop = p.monitor_loop AND p2.blocked_desc = p.blocking_desc)
      UNION ALL
      SELECT w.monitor_loop, w.lead_desc, n.blocked_desc, w.lead_path || ' ' || n.blocked_desc
        FROM w JOIN pairs n ON n.monitor_loop = w.monitor_loop AND n.blocking_desc = w.session_desc
       WHERE strpos(w.lead_path, n.blocked_desc) = 0
    )
    SELECT DISTINCT monitor_loop, lead_desc, session_desc FROM w
  ),
  leads AS (
    SELECT * FROM walk
    UNION
    SELECT DISTINCT p.monitor_loop, p.blocking_desc, p.blocking_desc
      FROM pairs p
     WHERE NOT EXISTS (SELECT 1 FROM walk w WHERE w.monitor_loop = p.monitor_loop AND w.session_desc = p.blocking_desc)
  ),
  rep AS (SELECT * FROM b WHERE b.activity = 'blocking'),   -- one row per report (the proc's #blocking)
  bpr_with_lead AS (
    SELECT l.lead_desc, r.monitor_loop, r.database_name, r.blocked_desc, r.transaction_id, r.victim_wait_ms
      FROM rep r JOIN leads l ON l.monitor_loop = r.monitor_loop AND l.session_desc = r.blocking_desc
  ),
  lead_sql AS (
    SELECT r.monitor_loop, r.blocking_desc AS lead_desc, max(r.sql_handle) AS sql_handle,
           coalesce(max(r.stmtstart), 0) AS stmtstart, coalesce(max(r.stmtend), -1) AS stmtend, max(r.query_text) AS query_text
      FROM rep r
     WHERE EXISTS (SELECT 1 FROM leads l WHERE l.monitor_loop = r.monitor_loop AND l.lead_desc = r.blocking_desc)
     GROUP BY r.monitor_loop, r.blocking_desc
  ),
  per_victim AS (
    SELECT bl.database_name, ls.sql_handle, ls.stmtstart, ls.stmtend, bl.transaction_id, max(bl.victim_wait_ms) AS wait_time_ms,
           max(pgvigil.mssql_lead_name(p_instance_id, ls.query_text)) AS lead_object_name
      FROM bpr_with_lead bl JOIN lead_sql ls ON ls.monitor_loop = bl.monitor_loop AND ls.lead_desc = bl.lead_desc
     WHERE ls.sql_handle IS NOT NULL
     GROUP BY bl.database_name, ls.sql_handle, ls.stmtstart, ls.stmtend, bl.transaction_id
  ),
  victim AS (   -- checks 1000 / 1001: the victim rows, each blocked transaction's longest wait
    SELECT b.database_name, b.contentious_object, b.transaction_id, max(b.wait_time_ms) AS wait_time_ms
      FROM b WHERE b.activity = 'blocked'
     GROUP BY b.database_name, b.contentious_object, b.transaction_id
  ),
  victim_db AS (
    SELECT b.database_name, b.transaction_id, max(b.wait_time_ms) AS wait_time_ms
      FROM b WHERE b.activity = 'blocked'
     GROUP BY b.database_name, b.transaction_id
  )
  SELECT * FROM (
    SELECT 1, b.database_name, '-', 'Database Locks',
           'The database ' || coalesce(b.database_name, 'unknown') || ' has been involved in ' || count(DISTINCT b.transaction_id) || ' blocking sessions.',
           row_number() OVER (ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b WHERE b.resource_owner_type = 'LOCK' OR b.resource_owner_type IS NULL
     GROUP BY b.database_name
    UNION ALL
    SELECT 2, b.database_name, b.contentious_object, 'Object Locks',
           'The object ' || b.contentious_object
           || CASE WHEN b.contentious_object LIKE 'Unresolved%' THEN '' ELSE ' in database ' || b.database_name END
           || ' has been involved in ' || count(DISTINCT b.transaction_id) || ' blocking sessions.',
           row_number() OVER (ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b WHERE b.resource_owner_type = 'LOCK' OR b.resource_owner_type IS NULL
     GROUP BY b.database_name, b.contentious_object
    UNION ALL
    SELECT 3, b.database_name,
           CASE WHEN (SELECT bool_or(x.on_) FROM rcsi x WHERE x.database_name = b.database_name) THEN 'You already enabled RCSI, but...'
                ELSE 'You Might Need RCSI' END,
           'Blocking Involving Selects',
           'There have been ' || count(DISTINCT b.transaction_id) || ' select queries involved in blocking sessions in ' || coalesce(b.database_name, 'unknown') || '.',
           row_number() OVER (ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b WHERE b.lock_mode IN ('S', 'IS')
     GROUP BY b.database_name HAVING count(DISTINCT b.transaction_id) > 1
    UNION ALL
    SELECT 4, b.database_name, '-', 'Repeatable Read Blocking',
           'There have been ' || count(DISTINCT b.transaction_id) || ' repeatable read queries involved in blocking sessions in ' || coalesce(b.database_name, 'unknown') || '.',
           row_number() OVER (ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b WHERE b.isolation_level LIKE 'repeatable%'
     GROUP BY b.database_name
    UNION ALL
    SELECT 5, b.database_name, '-', 'Serializable Blocking',
           'There have been ' || count(DISTINCT b.transaction_id) || ' serializable queries involved in blocking sessions in ' || coalesce(b.database_name, 'unknown') || '.',
           row_number() OVER (ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b WHERE b.isolation_level LIKE 'serializable%'
     GROUP BY b.database_name
    UNION ALL
    SELECT 6, b.database_name, '-', s.grp,
           'There have been ' || count(DISTINCT b.transaction_id) || s.word || coalesce(b.database_name, 'unknown') || '.',
           row_number() OVER (PARTITION BY s.grp ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b JOIN by_status s ON b.status = s.cond
     GROUP BY s.grp, s.word, b.database_name
    UNION ALL
    SELECT 6, b.database_name, '-', 'Compile Lock Blocking',
           'There have been ' || count(DISTINCT b.transaction_id) || ' compile locks blocking sessions in ' || coalesce(b.database_name, 'unknown') || '.',
           row_number() OVER (ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b WHERE b.wait_resource LIKE '%COMPILE%'
     GROUP BY b.database_name
    UNION ALL
    SELECT 6, b.database_name, '-', 'Application Lock Blocking',
           'There have been ' || count(DISTINCT b.transaction_id) || ' application locks blocking sessions in ' || coalesce(b.database_name, 'unknown') || '.',
           row_number() OVER (ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b WHERE b.wait_resource LIKE 'APPLICATION%'
     GROUP BY b.database_name
    UNION ALL
    SELECT 7, b.database_name, '-', t.grp,
           'There have been ' || count(DISTINCT b.transaction_id) || t.word || coalesce(b.database_name, 'unknown') || '.',
           row_number() OVER (PARTITION BY t.grp ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b JOIN by_tran t ON b.transaction_name = t.cond
     GROUP BY t.grp, t.word, b.database_name
    UNION ALL
    SELECT 8, b.database_name, '-', 'Login, App, and Host blocking',
           'This database has had ' || count(DISTINCT b.transaction_id) || ' instances of blocking involving the login '
           || coalesce(b.login_name, 'UNKNOWN') || ' from the application ' || coalesce(b.client_app, 'UNKNOWN')
           || ' on host ' || coalesce(b.host_name, 'UNKNOWN') || '.',
           row_number() OVER (ORDER BY count(DISTINCT b.transaction_id) DESC)
      FROM b
     GROUP BY b.database_name, b.login_name, b.client_app, b.host_name
    UNION ALL
    SELECT 9, pv.database_name,
           left(replace(replace(coalesce(max(pv.lead_object_name), '[Unknown]'), chr(13), ' '), chr(10), ' '), 200),
           'Top Lead Blocker',
           'This lead blocker accounted for ' || pgvigil.mssql_block_dhms(coalesce(sum(pv.wait_time_ms), 0)::bigint) || ' of blocking wait time ('
           || coalesce(round(100.0 * sum(pv.wait_time_ms) / nullif((SELECT sum(x.wait_time_ms) FROM per_victim x), 0), 1)::text, '0.0')
           || '% of total) across ' || count(DISTINCT pv.transaction_id) || ' blocked sessions in its chain.',
           row_number() OVER (ORDER BY sum(pv.wait_time_ms) DESC)
      FROM per_victim pv
     GROUP BY pv.database_name, pv.sql_handle, pv.stmtstart, pv.stmtend
    HAVING sum(pv.wait_time_ms) * 10 >= (SELECT sum(x.wait_time_ms) FROM per_victim x)
    UNION ALL
    SELECT 10, coalesce(b.database_name, 'unknown'), '-', 'Non-Lock and Self Blocking',
           'The database ' || coalesce(b.database_name, 'unknown') || ' has had ' || count(DISTINCT b.event_at)
           || ' blocked process report(s) for non-lock waits such as memory grants, parallelism, or other non-lock resources. '
           || 'The blocked process monitor fires for any task that waits longer than the configured blocked process threshold, not only lock waits, '
           || 'so these frequently show a session blocking itself and do not indicate lock contention.',
           row_number() OVER (ORDER BY count(DISTINCT b.event_at) DESC)
      FROM b WHERE b.resource_owner_type <> 'LOCK'
     GROUP BY b.database_name
    UNION ALL
    SELECT 1000, v.database_name, '-', 'Total database block wait time',
           'This database has had ' || pgvigil.mssql_block_dhms(coalesce(sum(v.wait_time_ms), 0)::bigint) || ' [dd hh:mm:ss] of lock wait time.',
           row_number() OVER (ORDER BY sum(v.wait_time_ms) DESC)
      FROM victim_db v
     GROUP BY v.database_name
    UNION ALL
    SELECT 1001, v.database_name, v.contentious_object, 'Total database and object block wait time',
           'This object has had ' || pgvigil.mssql_block_dhms(coalesce(sum(v.wait_time_ms), 0)::bigint) || ' [dd hh:mm:ss] of lock wait time in database '
           || coalesce(v.database_name, 'unknown'),
           row_number() OVER (ORDER BY sum(v.wait_time_ms) DESC)
      FROM victim v
     GROUP BY v.database_name, v.contentious_object
  ) f(check_id, database_name, object_name, finding_group, finding, sort_order)
  ORDER BY f.check_id, f.finding_group, f.sort_order
$$;

-- The blocked wait over the window by lead blocker, object, database and login / application / host: the victim rows,
-- each blocked transaction's longest wait counted once (as the proc's checks 1000 and 1001), the reports and the
-- blocked transactions behind each; each dimension's 200 largest.
CREATE OR REPLACE FUNCTION pgvigil.mssql_block_rollup(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (dimension text, database_name text, name text, reports bigint, blocked_sessions bigint, total_wait_ms bigint,
               longest_wait_ms bigint, first_at timestamptz, last_at timestamptz)
LANGUAGE sql STABLE AS $$
  WITH b AS (SELECT * FROM pgvigil.mssql_blocks(p_instance_id, p_from, p_to)),
  v AS (
    SELECT bd.event_at, bd.event_key, bd.database_name, bd.contentious_object, bd.transaction_id, bd.wait_time_ms,
           bg.query_text AS lead_text, bg.login_name, bg.client_app, bg.host_name
      FROM b bd JOIN b bg ON bg.event_key = bd.event_key AND bg.event_at = bd.event_at AND bg.activity = 'blocking'
     WHERE bd.activity = 'blocked'
  ),
  dims AS (
    SELECT 'lead' AS dimension, v.database_name, coalesce(left(v.lead_text, 400), '[Unknown]') AS name, v.transaction_id,
           v.wait_time_ms, v.event_at FROM v
    UNION ALL SELECT 'object', v.database_name, v.contentious_object, v.transaction_id, v.wait_time_ms, v.event_at FROM v
    UNION ALL SELECT 'database', v.database_name, coalesce(v.database_name, 'unknown'), v.transaction_id, v.wait_time_ms, v.event_at FROM v
    UNION ALL SELECT 'login', v.database_name,
                     coalesce(v.login_name, 'UNKNOWN') || ' / ' || coalesce(v.client_app, 'UNKNOWN') || ' / ' || coalesce(v.host_name, 'UNKNOWN'),
                     v.transaction_id, v.wait_time_ms, v.event_at FROM v
  ),
  per_tx AS (
    SELECT d.dimension, d.database_name, d.name, d.transaction_id, max(d.wait_time_ms) AS wait_ms, count(*) AS reports,
           min(d.event_at) AS first_at, max(d.event_at) AS last_at
      FROM dims d
     GROUP BY d.dimension, d.database_name, d.name, d.transaction_id
  )
  SELECT g.dimension, g.database_name, g.name, g.reports, g.blocked_sessions, g.total_wait_ms, g.longest_wait_ms, g.first_at, g.last_at
    FROM (SELECT p.dimension, p.database_name, p.name, sum(p.reports)::bigint AS reports, count(DISTINCT p.transaction_id) AS blocked_sessions,
                 coalesce(sum(p.wait_ms), 0)::bigint AS total_wait_ms, max(p.wait_ms) AS longest_wait_ms, min(p.first_at) AS first_at,
                 max(p.last_at) AS last_at,
                 row_number() OVER (PARTITION BY p.dimension ORDER BY sum(p.wait_ms) DESC NULLS LAST) AS rank_
            FROM per_tx p
           GROUP BY p.dimension, p.database_name, p.name) g
   WHERE g.rank_ <= 200   -- each dimension's 200 largest: one dimension's many names never empty another's grid
   ORDER BY g.dimension, g.rank_
$$;

-- The blocked / blocking pairs of the minute snapshots over the window (mssql_requests, migration 0064): one row per
-- pair of sessions, in how many snapshots it was seen, first and last, the longest wait, the wait types and resources,
-- the blocked side's database, login and program and the blocking side's as the same snapshot read them.
CREATE OR REPLACE FUNCTION pgvigil.mssql_block_pairs(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (blocked_session_id int, blocking_session_id int, snapshots bigint, first_at timestamptz, last_at timestamptz,
               longest_wait_ms bigint, wait_types text, wait_resources text, database_name text, blocked_login text,
               blocked_program text, blocking_login text, blocking_program text, blocking_status text, head_session_id int)
LANGUAGE sql STABLE AS $$
  SELECT q.session_id, q.blocking_session_id, count(*), min(q.snapshot_at), max(q.snapshot_at), max(q.wait_ms),
         string_agg(DISTINCT q.wait_type, ', '), left(string_agg(DISTINCT q.wait_resource, ', '), 400),
         (array_agg(q.database_name ORDER BY q.snapshot_at DESC))[1], (array_agg(q.login_name ORDER BY q.snapshot_at DESC))[1],
         (array_agg(q.program_name ORDER BY q.snapshot_at DESC))[1],
         (array_agg(h.login_name ORDER BY q.snapshot_at DESC))[1], (array_agg(h.program_name ORDER BY q.snapshot_at DESC))[1],
         (array_agg(h.status ORDER BY q.snapshot_at DESC))[1], (array_agg(q.head_session_id ORDER BY q.snapshot_at DESC))[1]
    FROM pgvigil.mssql_requests q
    LEFT JOIN LATERAL (SELECT h.login_name, h.program_name, h.status
                         FROM pgvigil.mssql_requests h
                        WHERE h.instance_id = q.instance_id AND h.snapshot_at = q.snapshot_at AND h.session_id = q.blocking_session_id
                        LIMIT 1) h ON true
   WHERE q.instance_id = p_instance_id AND q.snapshot_at > p_from AND q.snapshot_at <= p_to
     AND q.blocking_session_id IS NOT NULL AND q.blocking_session_id > 0 AND q.blocking_session_id <> q.session_id
   GROUP BY q.session_id, q.blocking_session_id
   ORDER BY max(q.wait_ms) DESC NULLS LAST, count(*) DESC
$$;
