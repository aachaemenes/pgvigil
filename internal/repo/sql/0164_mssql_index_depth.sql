-- 0164: indexes and statistics on demand (task 414, B23; internal/mssql/indexes.go, stats.go;
-- internal/web/q_mssql_index_depth.go).
--
-- Index usage and missing-index requests kept per read (SQLWATCH PBI#12, #13). import_mssql_indexes is 0092's, renamed
-- import_mssql_indexes_0092 and called unchanged by a new one: before the call it copies the stored rows of the
-- databases the batch reads (0092's import DELETEs and INSERTs them), after it writes one history row per index whose
-- counters or usage window differ from the copy, with what the interval added (no trigger: the old rows are gone when
-- a trigger on the new ones fires):
--   mssql_index_usage_read    one row per index and read that moved (monthly partitions): the counters, and the
--                             delta since the read before (that read's time in prev_at). A database's usage window
--                             that began again (usage_since moved, or a counter went down: 0092's reset) gives the
--                             whole count (reset = true); an index seen for the first time is a baseline (deltas
--                             NULL). An index that did not move keeps no row. The delta is counted against the stored
--                             row, never an older history row, so the purge never makes a false spike.
--                             Volume: rows a day = instances x (indexes that moved per read) x 4 reads; at most
--                             instances x indexes x 4 (every index of a table written in each 6 h moves its updates).
--   mssql_missing_index_read  one row per missing-index request and read whose seeks or scans moved: a request's
--                             identity across reads is md5 of the jsonb array [database, table, equality, inequality,
--                             included] (a NULL keeps its own place: equality NULL / inequality [a] is not equality [a]
--                             / inequality NULL); the server's handle changes at a restart.
-- The lock order of the wrapper: mssql_index (0092's DELETE and INSERT), then mssql_index_usage_read's parent
-- (ensure_month_partition after the old import): purge()'s DROP order must take them in that order.
--
-- Untrusted keys and constraints (dbachecks Database#41, #42; the collection mssql_constraints, every 6 hours, not on
-- Azure SQL Database):
--   mssql_constraint_db         per database, its read: the untrusted foreign keys and check constraints counted.
--   mssql_untrusted_constraint  per database, as last read: the foreign keys with is_not_trusted = 1 and not NOT FOR
--                               REPLICATION (disabled ones too: a disabled key is not trusted), the check constraints
--                               with is_not_trusted = 1, enabled and not NOT FOR REPLICATION (dbachecks 3.0.2's two
--                               predicates); the disabled check constraints are counted apart, never named.
-- mssql_indexes_findings is 0092's with three arms more (its columns are unchanged, so pgvigil.findings' arm is too):
--   'disabled indexes' (info), 'a disabled index that blocks its table' (warning: a disabled clustered index - the
--   table cannot be read or written, its nonclustered indexes and foreign keys are disabled with it - or a disabled
--   primary key or unique index a foreign key references - those foreign keys are disabled; Learn, 'Disable Indexes
--   and Constraints'), and 'untrusted foreign keys and check constraints' (info). The text is for a DBA to read:
--   pgvigil runs none of it.
--
-- Fragmentation on demand (SQLWATCH REP#1) is a job of serve's, never a collection:
--   mssql_fragmentation_read  one row per read asked for: who, the database, the mode (LIMITED | SAMPLED), the state
--                             (running | done | failed | cancelled | stopped), the job's beat (every 10 s; a running
--                             row with no beat for 60 s is stopped: serve restarted or the job died), and where a read
--                             that failed stopped. One running row per instance at a time (a unique index).
--   mssql_fragmentation_row   its rows (indexes and heaps of 1,000 pages or more), kept with the read.
-- Written through the actions door's audit login by import_mssql_fragmentation_start / _beat / _finish / _stop.
--
-- A histogram read on demand is audited as a plan read is (custom_report_log op 'histogram': who, the client, the
-- instance, the database, the statistic, the step count - never a key value); 0157's CHECK and
-- import_custom_report_run with the op added (a join that adds another op merges the lists).
--
-- For the release migration: mssql_index_usage_read among purge()'s monthly partition parents (after mssql_index in
-- the lock order above), n := n + pgvigil.mssql_index_depth_purge(p_days) for the rest, and 'mssql_index_depth_purge'
-- on apply_roles()' owner-only list (it deletes).
SET LOCAL lock_timeout = '20s';

-- ---------------------------------------------------------------------------------------------------------------
-- index usage and missing-index requests per read
-- ---------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.mssql_index_usage_read (
  instance_id     int NOT NULL,
  database_name   text NOT NULL,
  object_id       bigint NOT NULL,
  index_id        int NOT NULL,
  snapshot_at     timestamptz NOT NULL,
  prev_at         timestamptz,            -- the read the deltas count from; NULL = the index's first read (a baseline)
  schema_name     text,
  table_name      text,
  index_name      text,                   -- kept per row: an index dropped and another made with its index_id are told apart
  index_type      text,
  usage_since     timestamptz,            -- the database's usage window at this read (0092's)
  user_seeks      bigint NOT NULL,
  user_scans      bigint NOT NULL,
  user_lookups    bigint NOT NULL,
  user_updates    bigint NOT NULL,
  seeks_delta     bigint,                 -- NULL at a baseline
  scans_delta     bigint,
  lookups_delta   bigint,
  updates_delta   bigint,
  reset           boolean NOT NULL DEFAULT false,   -- the window began again: the deltas are the whole counts
  PRIMARY KEY (instance_id, database_name, object_id, index_id, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_missing_index_read (
  instance_id         int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  ident               text NOT NULL,      -- pgvigil.mssql_missing_ident()
  snapshot_at         timestamptz NOT NULL,
  prev_at             timestamptz,        -- NULL = the request's first read (a baseline)
  database_name       text,
  table_ref           text,
  equality_columns    text,
  inequality_columns  text,
  included_columns    text,
  user_seeks          bigint,
  user_scans          bigint,
  seeks_delta         bigint,
  scans_delta         bigint,
  avg_cost            float8,
  avg_impact          float8,
  benefit             float8,
  server_start        timestamptz,
  reset               boolean NOT NULL DEFAULT false,   -- the server started again: the deltas are the whole counts
  PRIMARY KEY (instance_id, ident, snapshot_at)
);
CREATE INDEX IF NOT EXISTS mssql_missing_index_read_at ON pgvigil.mssql_missing_index_read (snapshot_at);

-- a missing-index request's identity: its five fields as a jsonb array (a NULL keeps its place), hashed
CREATE OR REPLACE FUNCTION pgvigil.mssql_missing_ident(p_database text, p_table text, p_eq text, p_ineq text, p_incl text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT md5(jsonb_build_array(p_database, p_table, p_eq, p_ineq, p_incl)::text)
$$;

DO $$ BEGIN
  IF to_regprocedure('pgvigil.import_mssql_indexes_0092(int, timestamptz, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_indexes(int, timestamptz, jsonb) RENAME TO import_mssql_indexes_0092;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_indexes(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_dbs     text[];
  v_missing boolean;
BEGIN
  -- 0092's own lock, taken first: the copy below and its import see one instance's rows alone
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_indexes'), p_instance_id);
  -- the databases this batch reads (an older read arriving late changes nothing, as in 0092)
  SELECT array_agg(r->>'database_name') INTO v_dbs
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'db' AND r->>'database_name' IS NOT NULL AND coalesce((r->>'read')::boolean, false)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_index_db b
                      WHERE b.instance_id = p_instance_id AND b.database_name = r->>'database_name' AND b.snapshot_at > p_snapshot_at);
  v_missing := EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'missing_read')
               AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_missing_index m WHERE m.instance_id = p_instance_id AND m.snapshot_at > p_snapshot_at);
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_ix_prev (
    database_name text, object_id bigint, index_id int, user_seeks bigint, user_scans bigint, user_lookups bigint, user_updates bigint,
    snapshot_at timestamptz, usage_since timestamptz, PRIMARY KEY (database_name, object_id, index_id)) ON COMMIT DROP;
  CREATE TEMP TABLE IF NOT EXISTS pgv_mssql_mi_prev (
    ident text PRIMARY KEY, user_seeks bigint, user_scans bigint, server_start timestamptz, snapshot_at timestamptz) ON COMMIT DROP;
  TRUNCATE pgv_mssql_ix_prev;
  TRUNCATE pgv_mssql_mi_prev;
  IF v_dbs IS NOT NULL THEN
    INSERT INTO pgv_mssql_ix_prev
    SELECT x.database_name, x.object_id, x.index_id, x.user_seeks, x.user_scans, x.user_lookups, x.user_updates, x.snapshot_at, b.usage_since
      FROM pgvigil.mssql_index x
      JOIN pgvigil.mssql_index_db b ON b.instance_id = x.instance_id AND b.database_name = x.database_name
     WHERE x.instance_id = p_instance_id AND x.database_name = ANY (v_dbs);
  END IF;
  IF v_missing THEN
    INSERT INTO pgv_mssql_mi_prev
    SELECT pgvigil.mssql_missing_ident(m.database_name, m.table_ref, m.equality_columns, m.inequality_columns, m.included_columns),
           sum(m.user_seeks), sum(m.user_scans), max(m.server_start), max(m.snapshot_at)
      FROM pgvigil.mssql_missing_index m
     WHERE m.instance_id = p_instance_id
     GROUP BY 1;
  END IF;

  PERFORM pgvigil.import_mssql_indexes_0092(p_instance_id, p_snapshot_at, p_payload);

  IF v_dbs IS NOT NULL THEN
    PERFORM pgvigil.ensure_month_partition('mssql_index_usage_read', p_snapshot_at);
    INSERT INTO pgvigil.mssql_index_usage_read (instance_id, database_name, object_id, index_id, snapshot_at, prev_at, schema_name, table_name,
        index_name, index_type, usage_since, user_seeks, user_scans, user_lookups, user_updates, seeks_delta, scans_delta, lookups_delta,
        updates_delta, reset)
    SELECT x.instance_id, x.database_name, x.object_id, x.index_id, p_snapshot_at, p.snapshot_at, x.schema_name, x.table_name, x.index_name,
           x.index_type, b.usage_since, x.user_seeks, x.user_scans, x.user_lookups, x.user_updates,
           CASE WHEN p.object_id IS NULL THEN NULL WHEN z.again THEN x.user_seeks ELSE x.user_seeks - p.user_seeks END,
           CASE WHEN p.object_id IS NULL THEN NULL WHEN z.again THEN x.user_scans ELSE x.user_scans - p.user_scans END,
           CASE WHEN p.object_id IS NULL THEN NULL WHEN z.again THEN x.user_lookups ELSE x.user_lookups - p.user_lookups END,
           CASE WHEN p.object_id IS NULL THEN NULL WHEN z.again THEN x.user_updates ELSE x.user_updates - p.user_updates END,
           coalesce(z.again, false)
      FROM pgvigil.mssql_index x
      JOIN pgvigil.mssql_index_db b ON b.instance_id = x.instance_id AND b.database_name = x.database_name
      LEFT JOIN pgv_mssql_ix_prev p ON p.database_name = x.database_name AND p.object_id = x.object_id AND p.index_id = x.index_id
     CROSS JOIN LATERAL (SELECT p.object_id IS NOT NULL
                                AND (b.usage_since IS DISTINCT FROM p.usage_since OR x.user_seeks < p.user_seeks OR x.user_scans < p.user_scans
                                     OR x.user_lookups < p.user_lookups OR x.user_updates < p.user_updates) AS again) z
     WHERE x.instance_id = p_instance_id AND x.database_name = ANY (v_dbs) AND x.snapshot_at = p_snapshot_at
       AND (p.object_id IS NULL OR z.again OR x.user_seeks <> p.user_seeks OR x.user_scans <> p.user_scans
            OR x.user_lookups <> p.user_lookups OR x.user_updates <> p.user_updates)
    ON CONFLICT DO NOTHING;
  END IF;

  IF v_missing THEN
    INSERT INTO pgvigil.mssql_missing_index_read (instance_id, ident, snapshot_at, prev_at, database_name, table_ref, equality_columns,
        inequality_columns, included_columns, user_seeks, user_scans, seeks_delta, scans_delta, avg_cost, avg_impact, benefit, server_start, reset)
    SELECT p_instance_id, n.ident, p_snapshot_at, p.snapshot_at, n.database_name, n.table_ref, n.equality_columns, n.inequality_columns,
           n.included_columns, n.seeks, n.scans,
           CASE WHEN p.ident IS NULL THEN NULL WHEN z.again THEN n.seeks ELSE n.seeks - p.user_seeks END,
           CASE WHEN p.ident IS NULL THEN NULL WHEN z.again THEN n.scans ELSE n.scans - p.user_scans END,
           n.avg_cost, n.avg_impact, n.benefit, n.server_start, coalesce(z.again, false)
      FROM (SELECT pgvigil.mssql_missing_ident(m.database_name, m.table_ref, m.equality_columns, m.inequality_columns, m.included_columns) AS ident,
                   m.database_name, m.table_ref, m.equality_columns, m.inequality_columns, m.included_columns,
                   sum(coalesce(m.user_seeks, 0)) AS seeks, sum(coalesce(m.user_scans, 0)) AS scans, max(m.avg_cost) AS avg_cost,
                   max(m.avg_impact) AS avg_impact, sum(m.benefit) AS benefit, max(m.server_start) AS server_start
              FROM pgvigil.mssql_missing_index m
             WHERE m.instance_id = p_instance_id AND m.snapshot_at = p_snapshot_at
             GROUP BY 1, 2, 3, 4, 5, 6) n
      LEFT JOIN pgv_mssql_mi_prev p ON p.ident = n.ident
     CROSS JOIN LATERAL (SELECT p.ident IS NOT NULL
                                AND (n.server_start IS DISTINCT FROM p.server_start OR n.seeks < p.user_seeks OR n.scans < p.user_scans) AS again) z
     WHERE p.ident IS NULL OR z.again OR n.seeks <> p.user_seeks OR n.scans <> p.user_scans
    ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- untrusted keys and constraints (mssql_constraints)
-- ---------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.mssql_constraint_db (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name     text NOT NULL,
  database_id       int,
  snapshot_at       timestamptz NOT NULL,   -- the read that last listed the database
  read_at           timestamptz,            -- the read that last read its constraints; NULL = never
  database_state    text,
  note              text,
  untrusted_fk      int,
  untrusted_check   int,
  disabled_check    int,                    -- disabled check constraints: counted, never named (dbachecks leaves them out)
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_untrusted_constraint (
  instance_id        int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name      text NOT NULL,
  object_id          bigint NOT NULL,       -- the constraint's
  kind               text NOT NULL CHECK (kind IN ('foreign key', 'check')),
  schema_name        text,
  table_name         text,
  constraint_name    text,
  is_disabled        boolean NOT NULL DEFAULT false,   -- a foreign key disabled (NOCHECK, or with the index it references)
  ref_object_id      bigint,                -- a foreign key's referenced table
  ref_schema         text,
  ref_table          text,
  snapshot_at        timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, object_id)
);

-- payload, one call per batch, every batch with the run's {kind:'state', server_utc, server_start}:
--   a database's batch: {kind:'db', database_id, database_name, database_state, read, note, untrusted_fk, untrusted_check,
--     disabled_check} and, when read is true, its 'constraint' rows (mssql_untrusted_constraint's columns); a batch that
--     read the database replaces its rows and writes the cursor 'ct:<database>'; one that did not keeps them and takes
--     the note.
--   the run's last batch: {kind:'databases', names:[...]}: a stored database the server no longer lists goes.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_constraints(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_s    jsonb := pgvigil.mssql_perf_check('import_mssql_constraints', p_instance_id, p_payload);
  v_db   jsonb;
  v_name text;
  v_prev timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_constraints'), p_instance_id);
  FOR v_db IN SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'database_name' IS NOT NULL LOOP
    v_name := v_db->>'database_name';
    SELECT b.snapshot_at INTO v_prev FROM pgvigil.mssql_constraint_db b WHERE b.instance_id = p_instance_id AND b.database_name = v_name;
    CONTINUE WHEN v_prev > p_snapshot_at;
    IF NOT coalesce((v_db->>'read')::boolean, false) THEN
      INSERT INTO pgvigil.mssql_constraint_db AS b (instance_id, database_name, database_id, snapshot_at, database_state, note)
      VALUES (p_instance_id, v_name, (v_db->>'database_id')::int, p_snapshot_at, v_db->>'database_state', v_db->>'note')
      ON CONFLICT (instance_id, database_name) DO UPDATE SET database_id = EXCLUDED.database_id, snapshot_at = EXCLUDED.snapshot_at,
          database_state = EXCLUDED.database_state, note = EXCLUDED.note;
      CONTINUE;
    END IF;
    INSERT INTO pgvigil.mssql_constraint_db AS b (instance_id, database_name, database_id, snapshot_at, read_at, database_state, note,
        untrusted_fk, untrusted_check, disabled_check)
    VALUES (p_instance_id, v_name, (v_db->>'database_id')::int, p_snapshot_at, p_snapshot_at, v_db->>'database_state', v_db->>'note',
            (v_db->>'untrusted_fk')::int, (v_db->>'untrusted_check')::int, (v_db->>'disabled_check')::int)
    ON CONFLICT (instance_id, database_name) DO UPDATE SET database_id = EXCLUDED.database_id, snapshot_at = EXCLUDED.snapshot_at,
        read_at = EXCLUDED.read_at, database_state = EXCLUDED.database_state, note = EXCLUDED.note, untrusted_fk = EXCLUDED.untrusted_fk,
        untrusted_check = EXCLUDED.untrusted_check, disabled_check = EXCLUDED.disabled_check;
    DELETE FROM pgvigil.mssql_untrusted_constraint WHERE instance_id = p_instance_id AND database_name = v_name;
    INSERT INTO pgvigil.mssql_untrusted_constraint (instance_id, database_name, object_id, kind, schema_name, table_name, constraint_name,
        is_disabled, ref_object_id, ref_schema, ref_table, snapshot_at)
    SELECT DISTINCT ON ((r->>'object_id')::bigint)
           p_instance_id, v_name, (r->>'object_id')::bigint, r->>'constraint_kind', r->>'schema_name', r->>'table_name', r->>'constraint_name',
           coalesce((r->>'is_disabled')::int, 0) = 1, (r->>'ref_object_id')::bigint, r->>'ref_schema', r->>'ref_table', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'constraint' AND r->>'database_name' = v_name AND r->>'object_id' IS NOT NULL
       AND r->>'constraint_kind' IN ('foreign key', 'check')
     ORDER BY (r->>'object_id')::bigint;
    INSERT INTO pgvigil.mssql_cursor AS c (instance_id, source, last_event_at, updated_at)
    VALUES (p_instance_id, 'ct:' || v_name, p_snapshot_at, now())
    ON CONFLICT (instance_id, source) DO UPDATE SET last_event_at = EXCLUDED.last_event_at, updated_at = EXCLUDED.updated_at;
  END LOOP;
  SELECT r INTO v_db FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'databases' AND jsonb_typeof(r->'names') = 'array' LIMIT 1;
  IF v_db IS NOT NULL THEN
    DELETE FROM pgvigil.mssql_untrusted_constraint x
     WHERE x.instance_id = p_instance_id AND NOT (v_db->'names') ? x.database_name
       AND EXISTS (SELECT 1 FROM pgvigil.mssql_constraint_db b WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name AND b.snapshot_at < p_snapshot_at);
    DELETE FROM pgvigil.mssql_cursor c
     WHERE c.instance_id = p_instance_id AND c.source LIKE 'ct:%' AND NOT (v_db->'names') ? substr(c.source, 4);
    DELETE FROM pgvigil.mssql_constraint_db b
     WHERE b.instance_id = p_instance_id AND b.snapshot_at < p_snapshot_at AND NOT (v_db->'names') ? b.database_name;
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- the findings: 0092's with three arms more
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.mssql_indexes_findings AS
WITH v AS (
  SELECT n.instance_id, t.database_name, t.rule, x.size_kb, b.read_at, b.usage_days, b.usage_reason
    FROM (SELECT DISTINCT b.instance_id FROM pgvigil.mssql_index_db b WHERE b.read_at > now() - interval '13 hours') n
   CROSS JOIN LATERAL pgvigil.mssql_index_verdicts(n.instance_id) t
    JOIN pgvigil.mssql_index_db_status b ON b.instance_id = n.instance_id AND b.database_name = t.database_name
    JOIN pgvigil.mssql_index x ON x.instance_id = n.instance_id AND x.database_name = t.database_name AND x.object_id = t.object_id AND x.index_id = t.index_id
   WHERE b.read_at > now() - interval '13 hours'
), vc AS (
  SELECT v.*, CASE WHEN v.rule = 'exact duplicate' THEN 'exact duplicate indexes'
                   WHEN v.rule = 'unused, written' THEN 'unused indexes that are written'
                   WHEN v.rule = 'unused' THEN 'unused indexes'
                   WHEN v.rule IN ('key subset', 'same keys, other includes', 'constraint doubled') THEN 'redundant indexes' END AS check_name
    FROM v
), g AS (
  SELECT vc.instance_id, vc.database_name, vc.check_name, max(vc.read_at) AS read_at, max(vc.usage_days) AS usage_days,
         max(vc.usage_reason) AS usage_reason, count(*) AS n, coalesce(sum(vc.size_kb), 0) AS size_kb
    FROM vc
   GROUP BY vc.instance_id, vc.database_name, vc.check_name
)
SELECT g.instance_id, CASE WHEN g.check_name IN ('exact duplicate indexes', 'unused indexes that are written') THEN 'warning' ELSE 'info' END::text AS severity,
       g.check_name::text, g.database_name::text AS object, g.read_at AS at,
       (CASE g.check_name
          WHEN 'exact duplicate indexes' THEN format('%s index(es), %s MB, have the same key columns, included columns and filter as another index of their table: every write maintains both.', g.n, round(g.size_kb / 1024.0, 1))
          WHEN 'unused indexes that are written' THEN format('%s nonclustered index(es), %s MB, had no read in the %s day(s) since %s and 10,000 or more writes each.', g.n, round(g.size_kb / 1024.0, 1), round(g.usage_days::numeric, 1), g.usage_reason)
          WHEN 'unused indexes' THEN format('%s nonclustered index(es), %s MB, had no read in the %s day(s) since %s.', g.n, round(g.size_kb / 1024.0, 1), round(g.usage_days::numeric, 1), g.usage_reason)
          ELSE format('%s index(es), %s MB, are covered by another index of their table (a key subset, the same keys with other included columns, or a unique constraint doubled).', g.n, round(g.size_kb / 1024.0, 1))
        END || ' The Indexes page lists them with the text to review.')::text AS detail
  FROM g
 WHERE g.check_name IS NOT NULL
UNION ALL
SELECT m.instance_id, 'info', 'a high-value missing-index request', coalesce(m.database_name, 'database ' || m.database_id) || ': ' || coalesce(m.table_ref, 'object ' || m.object_id),
       m.snapshot_at,
       format('the optimizer asked %s time(s) for an index on equality (%s), inequality (%s), included (%s): benefit %s a day of uptime (cost %s, expected saving %s %%). '
              || 'A hint from one query shape: it knows nothing of the indexes that exist or of the other requests.',
              coalesce(m.user_seeks, 0) + coalesce(m.user_scans, 0), coalesce(m.equality_columns, 'none'), coalesce(m.inequality_columns, 'none'),
              coalesce(m.included_columns, 'none'), round(u.per_day::numeric), round(m.avg_cost::numeric, 2), round(m.avg_impact::numeric, 1))
  FROM pgvigil.mssql_missing_index m
 CROSS JOIN LATERAL (SELECT m.benefit / greatest(extract(epoch FROM m.snapshot_at - m.server_start) / 86400.0, 1) AS per_day) u
 WHERE m.snapshot_at > now() - interval '13 hours' AND m.ord <= 20 AND u.per_day >= 100000
UNION ALL
-- disabled indexes (dbachecks Database#16): per database, the warning cases apart (F9)
SELECT g.instance_id, g.severity::text, g.check_name::text, g.database_name::text, g.read_at,
       (CASE WHEN g.blocks
             THEN g.n || ' disabled index(es) block their table: ' || g.lines
                  || ' (Learn: Disable Indexes and Constraints.) The text is for review; pgvigil runs none of it.'
             ELSE format('%s disabled index(es): %s. A disabled index is neither kept up to date nor used; ALTER INDEX ... REBUILD brings it back, DROP INDEX removes it (text to review; pgvigil runs none of it).',
                         g.n, g.names) END)::text
  FROM (SELECT d.instance_id, d.database_name, d.blocks, max(b.read_at) AS read_at, count(*) AS n,
               CASE WHEN d.blocks THEN 'warning' ELSE 'info' END AS severity,
               CASE WHEN d.blocks THEN 'a disabled index that blocks its table' ELSE 'disabled indexes' END AS check_name,
               array_to_string((array_agg(d.qname ORDER BY d.qname))[1:10], ', ')
                 || CASE WHEN count(*) > 10 THEN format(' and %s more', count(*) - 10) ELSE '' END AS names,
               string_agg(d.line, ' ' ORDER BY d.qname) AS lines
          FROM (SELECT x.instance_id, x.database_name, x.object_id, x.index_id,
                       pgvigil.mssql_qname(coalesce(x.schema_name, 'dbo')) || '.' || pgvigil.mssql_qname(x.table_name) || '.' || pgvigil.mssql_qname(x.index_name) AS qname,
                       (x.index_id = 1 OR ((x.is_primary_key OR x.is_unique_constraint OR x.is_unique) AND x.fk_referenced)) AS blocks,
                       bool_or(x.index_id = 1) OVER (PARTITION BY x.instance_id, x.database_name, x.object_id) AS table_blocked,
                       CASE WHEN x.index_id = 1
                            THEN format('%s.%s: its clustered index %s is disabled, so the table can be neither read nor written, and its nonclustered indexes and foreign keys are disabled with it; ALTER INDEX ALL ON %s.%s REBUILD enables them (offline).',
                                        pgvigil.mssql_qname(coalesce(x.schema_name, 'dbo')), pgvigil.mssql_qname(x.table_name), pgvigil.mssql_qname(x.index_name),
                                        pgvigil.mssql_qname(coalesce(x.schema_name, 'dbo')), pgvigil.mssql_qname(x.table_name))
                            ELSE format('%s.%s: %s is disabled and a foreign key references it, so the foreign keys that do are disabled with it; ALTER INDEX %s ON %s.%s REBUILD enables it.',
                                        pgvigil.mssql_qname(coalesce(x.schema_name, 'dbo')), pgvigil.mssql_qname(x.table_name), pgvigil.mssql_qname(x.index_name),
                                        pgvigil.mssql_qname(x.index_name), pgvigil.mssql_qname(coalesce(x.schema_name, 'dbo')), pgvigil.mssql_qname(x.table_name)) END
                       || CASE WHEN x.fk_referenced OR x.index_id = 1
                               THEN ' The foreign keys are not enabled by the rebuild: each takes ALTER TABLE ... WITH CHECK CHECK CONSTRAINT'
                                    || coalesce(' (' || (SELECT string_agg(format('ALTER TABLE %s.%s WITH CHECK CHECK CONSTRAINT %s;', pgvigil.mssql_qname(coalesce(c.schema_name, 'dbo')),
                                                                                  pgvigil.mssql_qname(c.table_name), pgvigil.mssql_qname(c.constraint_name)), ' ' ORDER BY c.constraint_name)
                                                           FROM pgvigil.mssql_untrusted_constraint c
                                                          WHERE c.instance_id = x.instance_id AND c.database_name = x.database_name AND c.kind = 'foreign key'
                                                            AND (c.ref_object_id = x.object_id OR (x.index_id = 1 AND c.object_id IS NOT NULL AND c.table_name = x.table_name
                                                                                                   AND c.schema_name IS NOT DISTINCT FROM x.schema_name))) || ')', '')
                                    || '.'
                               ELSE '' END AS line
                  FROM pgvigil.mssql_index x
                 WHERE x.is_disabled AND NOT x.is_hypothetical) d
          JOIN pgvigil.mssql_index_db b ON b.instance_id = d.instance_id AND b.database_name = d.database_name
         WHERE b.read_at > now() - interval '13 hours'
           AND (d.blocks OR NOT d.table_blocked)   -- the nonclustered indexes a disabled clustered index took with it are in its line
         GROUP BY d.instance_id, d.database_name, d.blocks) g
UNION ALL
-- untrusted foreign keys and check constraints (dbachecks Database#41, #42)
SELECT b.instance_id, 'info'::text, 'untrusted foreign keys and check constraints'::text, b.database_name::text, b.read_at,
       format('%s foreign key(s) and %s check constraint(s) are not trusted (re-enabled without WITH CHECK, or disabled): the optimizer does not use them to simplify a plan, and rows written while they were off were never checked: %s. '
              || 'Text to review: %s (it reads the whole table and fails on a row that breaks the rule; pgvigil runs none of it).',
              coalesce(b.untrusted_fk, 0), coalesce(b.untrusted_check, 0), u.names, u.first_line)::text
  FROM pgvigil.mssql_constraint_db b
  CROSS JOIN LATERAL (
    SELECT array_to_string((array_agg(pgvigil.mssql_qname(coalesce(c.schema_name, 'dbo')) || '.' || pgvigil.mssql_qname(c.table_name) || '.' || pgvigil.mssql_qname(c.constraint_name)
                                      ORDER BY c.table_name, c.constraint_name))[1:10], ', ')
             || CASE WHEN count(*) > 10 THEN format(' and %s more', count(*) - 10) ELSE '' END AS names,
           (array_agg(format('ALTER TABLE %s.%s WITH CHECK CHECK CONSTRAINT %s;', pgvigil.mssql_qname(coalesce(c.schema_name, 'dbo')), pgvigil.mssql_qname(c.table_name),
                             pgvigil.mssql_qname(c.constraint_name)) ORDER BY c.table_name, c.constraint_name))[1] AS first_line,
           count(*) AS n
      FROM pgvigil.mssql_untrusted_constraint c
     WHERE c.instance_id = b.instance_id AND c.database_name = b.database_name) u
 WHERE b.read_at > now() - interval '13 hours' AND u.n > 0;

-- ---------------------------------------------------------------------------------------------------------------
-- fragmentation on demand: a job of serve's
-- ---------------------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.mssql_fragmentation_read (
  read_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  instance       text NOT NULL,
  database_name  text NOT NULL,
  mode           text NOT NULL CHECK (mode IN ('LIMITED', 'SAMPLED')),
  ui_user        text NOT NULL,
  client         text,
  serve_id       text,                     -- the serve that runs it
  started_at     timestamptz NOT NULL,
  beat_at        timestamptz NOT NULL,     -- the job's last beat (every 10 s)
  ended_at       timestamptz,
  state          text NOT NULL CHECK (state IN ('running', 'done', 'failed', 'cancelled', 'stopped')),
  note           text,                     -- why it failed, where it stopped, what was left out
  objects_read   int,                      -- rows the server returned (every index and heap, before the 1,000-page cut)
  rows_kept      int,
  heap_pages     bigint,                   -- the database's heap pages at the start (sys.dm_db_partition_stats)
  duration_ms    int
);
CREATE UNIQUE INDEX IF NOT EXISTS mssql_fragmentation_running ON pgvigil.mssql_fragmentation_read (instance_id) WHERE state = 'running';
CREATE INDEX IF NOT EXISTS mssql_fragmentation_read_inst ON pgvigil.mssql_fragmentation_read (instance_id, started_at DESC);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_fragmentation_row (
  read_id          bigint NOT NULL REFERENCES pgvigil.mssql_fragmentation_read(read_id) ON DELETE CASCADE,
  ord              int NOT NULL,
  object_id        bigint,
  index_id         int,
  partition_number int,
  schema_name      text,
  table_name       text,
  index_name       text,                   -- NULL: the heap
  index_type       text,                   -- HEAP | CLUSTERED INDEX | NONCLUSTERED INDEX | ...
  alloc_unit       text,                   -- IN_ROW_DATA | ROW_OVERFLOW_DATA | LOB_DATA
  page_count       bigint,
  fragment_pct     float8,                 -- avg_fragmentation_in_percent
  fragment_count   bigint,
  page_density     float8,                 -- avg_page_space_used_in_percent: SAMPLED only (NULL in LIMITED)
  record_count     bigint,                 -- SAMPLED only
  forwarded        bigint,                 -- a heap's forwarded records: SAMPLED only
  marked           boolean NOT NULL DEFAULT false,   -- over 30 % and over 1,000 pages (SQLWATCH's line)
  PRIMARY KEY (read_id, ord)
);

-- the running rows of an instance with no beat for 60 s: stopped (serve restarted, or the job is gone)
CREATE OR REPLACE FUNCTION pgvigil.mssql_fragmentation_stale(p_instance_id int, p_at timestamptz)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  n int;
BEGIN
  UPDATE pgvigil.mssql_fragmentation_read
     SET state = 'stopped', ended_at = p_at,
         note = coalesce(note || ' ', '') || format('No beat since %s UTC: pgvigil serve restarted or the read''s job ended without its answer; the read is stopped.',
                                                    to_char(beat_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'))
   WHERE instance_id = p_instance_id AND state = 'running' AND beat_at < p_at - interval '60 seconds';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

-- payload {ui_user, client, instance_id, instance, database, mode, serve_id, heap_pages}: {outcome done, read_id} or
-- {outcome refused, detail} while another read of the instance runs
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_fragmentation_start(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_inst int := (p_payload->>'instance_id')::int;
  v_mode text := upper(coalesce(p_payload->>'mode', ''));
  v_run  pgvigil.mssql_fragmentation_read%ROWTYPE;
  v_id   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_mssql_fragmentation_start: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_mode NOT IN ('LIMITED', 'SAMPLED') THEN
    RAISE EXCEPTION 'import_mssql_fragmentation_start: mode % is not LIMITED or SAMPLED', v_mode USING ERRCODE = '22023';
  END IF;
  PERFORM pgvigil.mssql_fragmentation_stale(v_inst, p_at);
  SELECT * INTO v_run FROM pgvigil.mssql_fragmentation_read WHERE instance_id = v_inst AND state = 'running';
  IF v_run.read_id IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'read_id', v_run.read_id,
      'detail', format('a fragmentation read of %s (%s) asked by %s at %s UTC is running on this instance: one at a time per instance', v_run.database_name,
                       v_run.mode, v_run.ui_user, to_char(v_run.started_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')));
  END IF;
  BEGIN
    INSERT INTO pgvigil.mssql_fragmentation_read (instance_id, instance, database_name, mode, ui_user, client, serve_id, started_at, beat_at, state, heap_pages)
    VALUES (v_inst, p_payload->>'instance', p_payload->>'database', v_mode, v_user, nullif(p_payload->>'client', ''), p_payload->>'serve_id', p_at, p_at,
            'running', (p_payload->>'heap_pages')::bigint)
    RETURNING read_id INTO v_id;
  EXCEPTION WHEN unique_violation THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'another fragmentation read of this instance started a moment ago: one at a time per instance');
  END;
  RETURN jsonb_build_object('outcome', 'done', 'read_id', v_id);
END $$;

-- payload {read_id, objects_read}: the job's beat; answers the row's state (a row stopped meanwhile says so)
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_fragmentation_beat(p_at timestamptz, p_payload jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_state text;
BEGIN
  UPDATE pgvigil.mssql_fragmentation_read SET beat_at = p_at, objects_read = coalesce((p_payload->>'objects_read')::int, objects_read)
   WHERE read_id = (p_payload->>'read_id')::bigint AND state = 'running'
  RETURNING state INTO v_state;
  IF v_state IS NULL THEN
    SELECT state INTO v_state FROM pgvigil.mssql_fragmentation_read WHERE read_id = (p_payload->>'read_id')::bigint;
  END IF;
  RETURN v_state;
END $$;

-- payload {read_id, state (done | failed | cancelled), note, objects_read, duration_ms, rows:[...]}: the read's end and
-- its rows; a row already stopped (no beat for 60 s) takes them too, its state kept stopped with the end's note added
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_fragmentation_finish(p_at timestamptz, p_payload jsonb)
RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  v_id    bigint := (p_payload->>'read_id')::bigint;
  v_state text := p_payload->>'state';
  v_was   text;
BEGIN
  IF v_state NOT IN ('done', 'failed', 'cancelled') THEN
    RAISE EXCEPTION 'import_mssql_fragmentation_finish: state % is not done, failed or cancelled', v_state USING ERRCODE = '22023';
  END IF;
  SELECT state INTO v_was FROM pgvigil.mssql_fragmentation_read WHERE read_id = v_id FOR UPDATE;
  IF v_was IS NULL OR v_was NOT IN ('running', 'stopped') THEN
    RETURN coalesce(v_was, 'gone');
  END IF;
  DELETE FROM pgvigil.mssql_fragmentation_row WHERE read_id = v_id;
  INSERT INTO pgvigil.mssql_fragmentation_row (read_id, ord, object_id, index_id, partition_number, schema_name, table_name, index_name, index_type,
      alloc_unit, page_count, fragment_pct, fragment_count, page_density, record_count, forwarded, marked)
  SELECT v_id, n::int, (r->>'object_id')::bigint, (r->>'index_id')::int, (r->>'partition_number')::int, r->>'schema_name', r->>'table_name',
         r->>'index_name', r->>'index_type', r->>'alloc_unit', (r->>'page_count')::bigint, (r->>'fragment_pct')::float8, (r->>'fragment_count')::bigint,
         (r->>'page_density')::float8, (r->>'record_count')::bigint, (r->>'forwarded')::bigint,
         coalesce((r->>'fragment_pct')::float8, 0) > 30 AND coalesce((r->>'page_count')::bigint, 0) > 1000
    FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_payload->'rows') = 'array' THEN p_payload->'rows' ELSE '[]' END) WITH ORDINALITY AS e(r, n);
  UPDATE pgvigil.mssql_fragmentation_read
     SET state = CASE WHEN v_was = 'stopped' THEN 'stopped' ELSE v_state END, ended_at = p_at, beat_at = p_at,
         note = CASE WHEN v_was = 'stopped' THEN coalesce(note || ' ', '') || 'Its job ended afterwards: ' || v_state || coalesce('; ' || (p_payload->>'note'), '') || '.'
                     ELSE left(p_payload->>'note', 4000) END,
         objects_read = coalesce((p_payload->>'objects_read')::int, objects_read),
         rows_kept = (SELECT count(*) FROM pgvigil.mssql_fragmentation_row WHERE read_id = v_id),
         duration_ms = (p_payload->>'duration_ms')::int
   WHERE read_id = v_id;
  RETURN v_state;
END $$;

-- payload {read_id, ui_user}: Cancel on a read whose job this serve does not hold: stopped when it has no beat for 60 s,
-- else refused (another serve runs it)
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_fragmentation_stop(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_run pgvigil.mssql_fragmentation_read%ROWTYPE;
BEGIN
  SELECT * INTO v_run FROM pgvigil.mssql_fragmentation_read WHERE read_id = (p_payload->>'read_id')::bigint;
  IF v_run.read_id IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'no such fragmentation read');
  END IF;
  IF v_run.state <> 'running' THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('the read is %s already', v_run.state));
  END IF;
  IF pgvigil.mssql_fragmentation_stale(v_run.instance_id, p_at) > 0 THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'stopped: it had no beat for 60 s');
  END IF;
  RETURN jsonb_build_object('outcome', 'refused', 'detail', format('the read runs in another pgvigil serve (%s): Cancel it there', coalesce(v_run.serve_id, 'unnamed')));
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- a histogram read is audited (op 'histogram'): 0157's CHECK and function with the op added
-- ---------------------------------------------------------------------------------------------------------------
ALTER TABLE pgvigil.custom_report_log DROP CONSTRAINT IF EXISTS custom_report_log_op_check;
ALTER TABLE pgvigil.custom_report_log ADD CONSTRAINT custom_report_log_op_check
  CHECK (op IN ('add', 'edit', 'delete', 'move', 'folder_add', 'folder_rename', 'folder_delete',
                'run', 'community_run', 'community_help', 'community_form', 'plan_read', 'histogram'));

CREATE OR REPLACE FUNCTION pgvigil.import_custom_report_run(p_at timestamptz, p_payload jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_op   text := p_payload->>'op';
  v_out  text := p_payload->>'outcome';
  v_door text := nullif(p_payload->>'door', '');
  v_id   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_custom_report_run: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('run', 'community_run', 'community_help', 'community_form', 'plan_read', 'histogram') THEN
    RAISE EXCEPTION 'import_custom_report_run: op % is not run, community_run, community_help, community_form, plan_read or histogram', v_op USING ERRCODE = '22023';
  END IF;
  IF v_out IS NULL OR v_out NOT IN ('done', 'refused', 'failed') THEN
    RAISE EXCEPTION 'import_custom_report_run: outcome % is not done, refused or failed', v_out USING ERRCODE = '22023';
  END IF;
  IF v_door IS NOT NULL AND v_door NOT IN ('file', 'page', 'store') THEN
    RAISE EXCEPTION 'import_custom_report_run: door % is not file, page or store', v_door USING ERRCODE = '22023';
  END IF;
  INSERT INTO pgvigil.custom_report_log (at, ui_user, client, op, report_id, report_name, tool, instance_id, instance, outcome,
                                         detail, rows, duration_ms, statement, payload, door, door_generation)
  VALUES (p_at, v_user, nullif(p_payload->>'client', ''), v_op,
          CASE WHEN coalesce(p_payload->>'report_id', '') ~ '^[0-9]{1,18}$' THEN (p_payload->>'report_id')::bigint END,
          nullif(p_payload->>'report_name', ''), nullif(p_payload->>'tool', ''),
          CASE WHEN coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'instance_id')::int END,
          nullif(p_payload->>'instance', ''), v_out, left(p_payload->>'detail', 4000),
          CASE WHEN coalesce(p_payload->>'rows', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'rows')::int END,
          CASE WHEN coalesce(p_payload->>'duration_ms', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'duration_ms')::int END,
          left(p_payload->>'statement', 200000), p_payload->'params', v_door,
          CASE WHEN coalesce(p_payload->>'door_generation', '') ~ '^-?[0-9]{1,18}$' THEN (p_payload->>'door_generation')::bigint END)
  RETURNING log_id INTO v_id;
  RETURN v_id;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- the purge (the usage parent's partitions go through purge()'s DROP; this is the rest)
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgvigil.mssql_index_depth_purge(p_days int DEFAULT 30)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_old  timestamptz := now() - make_interval(days => p_days);
  n      bigint := 0;
  v_rows bigint;
BEGIN
  DELETE FROM pgvigil.mssql_missing_index_read WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_fragmentation_read WHERE coalesce(ended_at, beat_at) < v_old AND state <> 'running';
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_untrusted_constraint x
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_constraint_db b WHERE b.instance_id = x.instance_id AND b.database_name = x.database_name AND b.read_at >= v_old);
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  DELETE FROM pgvigil.mssql_constraint_db WHERE snapshot_at < v_old;
  GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
  RETURN n;
END $$;
