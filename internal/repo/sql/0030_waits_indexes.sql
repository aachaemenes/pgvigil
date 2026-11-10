-- 0030_waits_indexes: the gurus' tools (phase 2c, task 41).
--   1. waits: the wait-event profile of pg_wait_sampling (Postgres Professional, PostgreSQL licence), diffed per
--      (event type, event, queryid) between two reads into wait_sample; Azure's pgms_wait_sampling buckets stored
--      as they come. Where neither extension is installed the Waits tab reads the activity samples (0002): one
--      sample per active session per minute, so its numbers are session-minutes, not 10 ms samples.
--      lock_tree(): the blocking tree of one activity snapshot, after postgres_dba's l2_lock_trees.sql (BSD-3,
--      Copyright (c) 2017, Nikolay Samokhvalov), read from the stored samples instead of pg_stat_activity.
--   2. statements from pg_stat_monitor (Percona, PostgreSQL licence) where pg_stat_statements is absent: the
--      collector sends the finished time buckets, this import adds each bucket once to a running total per
--      statement and hands the totals to import_statements (0017), so the Statements tab reads the same rows.
--   3. indexes: unused, redundant, duplicate and invalid indexes per database (hourly). The redundant and invalid
--      reads are postgres_dba's i2_redundant_indexes.sql and i4_invalid_indexes.sql (BSD-3, as above) in the
--      collector; the unused rule is pgvigil's own (postgres_dba's i1 comes from pgx_scripts, whose licence was
--      not read). index_findings: the findings view's ten columns (the join puts them under pgvigil.findings).
-- Retention: wait_sample is monthly partitions (its name joins pgvigil.purge's list at the join); index_state and
-- index_databases rows no longer present are deleted after the retention (the join's purge deletes);
-- statements_monitor_seen keeps two days of bucket keys and trims itself; statements_monitor_total is one row per
-- statement, like statements_current.

-- ---------------------------------------------------------------------------------------------------------
-- 1. waits
-- ---------------------------------------------------------------------------------------------------------

-- the last cumulative profile count per key; queryid 0 = none (a background process, or query ids off)
CREATE TABLE IF NOT EXISTS pgvigil.wait_profile_current (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  event_type   text NOT NULL,
  event        text NOT NULL,
  queryid      bigint NOT NULL,
  count        bigint NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, event_type, event, queryid)
);

-- one row per key and read: the samples taken between two reads (pg_wait_sampling) or in one bucket (pgms);
-- wait_secs = samples x the profile period (NULL when the period is unknown); event_type 'CPU' = no wait event
CREATE TABLE IF NOT EXISTS pgvigil.wait_sample (
  instance_id    int NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  interval_secs  int,
  source         text NOT NULL,          -- pg_wait_sampling | pgms_wait_sampling
  event_type     text NOT NULL,
  event          text NOT NULL,
  queryid        bigint NOT NULL,
  samples        bigint NOT NULL,
  wait_secs      double precision
) PARTITION BY RANGE (snapshot_at);
CREATE UNIQUE INDEX IF NOT EXISTS wait_sample_key ON pgvigil.wait_sample (instance_id, snapshot_at, source, event_type, event, queryid);

-- payload: {kind:'profile', event_type, event, queryid, count} (summed over pids), {kind:'period', ms},
-- {kind:'pgms', start_time, end_time, event_type, event, queryid, calls}.
-- The first read of an instance only sets the baseline (its counts run since the server started); a count
-- below the stored one (pg_wait_sampling_reset_profile, a restart) starts again from that count.
CREATE OR REPLACE FUNCTION pgvigil.import_waits(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_first   boolean;
  v_period  float8;
  v_month   timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_waits'), p_instance_id);
  SELECT (r->>'ms')::float8 INTO v_period FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'period' LIMIT 1;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'profile') THEN
    v_first := NOT EXISTS (SELECT 1 FROM pgvigil.wait_profile_current WHERE instance_id = p_instance_id);
    PERFORM pgvigil.ensure_month_partition('wait_sample', p_snapshot_at);
    CREATE TEMP TABLE pgv_wait_in ON COMMIT DROP AS
    SELECT coalesce(r->>'event_type', 'CPU') AS event_type, coalesce(r->>'event', 'CPU') AS event,
           coalesce((r->>'queryid')::bigint, 0) AS queryid, sum((r->>'count')::bigint)::bigint AS count
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'profile'
     GROUP BY 1, 2, 3;
    IF NOT v_first THEN
      INSERT INTO pgvigil.wait_sample (instance_id, snapshot_at, interval_secs, source, event_type, event, queryid, samples, wait_secs)
      SELECT p_instance_id, p_snapshot_at, greatest(1, extract(epoch FROM p_snapshot_at - coalesce(c.snapshot_at, l.at)))::int,
             'pg_wait_sampling', i.event_type, i.event, i.queryid, d.samples, d.samples * v_period / 1000.0
        FROM pgv_wait_in i
        LEFT JOIN pgvigil.wait_profile_current c
          ON c.instance_id = p_instance_id AND c.event_type = i.event_type AND c.event = i.event AND c.queryid = i.queryid
        CROSS JOIN (SELECT max(snapshot_at) AS at FROM pgvigil.wait_profile_current WHERE instance_id = p_instance_id) l
        CROSS JOIN LATERAL (SELECT CASE WHEN c.count IS NULL OR i.count < c.count THEN i.count ELSE i.count - c.count END AS samples) d
       WHERE d.samples > 0 AND p_snapshot_at > coalesce(c.snapshot_at, l.at)
      ON CONFLICT (instance_id, snapshot_at, source, event_type, event, queryid) DO NOTHING;
    END IF;
    INSERT INTO pgvigil.wait_profile_current AS c (instance_id, event_type, event, queryid, count, snapshot_at)
    SELECT p_instance_id, event_type, event, queryid, count, p_snapshot_at FROM pgv_wait_in
    ON CONFLICT (instance_id, event_type, event, queryid) DO UPDATE SET count = EXCLUDED.count, snapshot_at = EXCLUDED.snapshot_at
     WHERE c.snapshot_at <= EXCLUDED.snapshot_at;
    -- a key no longer in the profile (its backends ended and the profile was reset) is dropped, so it starts again
    DELETE FROM pgvigil.wait_profile_current c
     WHERE c.instance_id = p_instance_id AND c.snapshot_at < p_snapshot_at
       AND NOT EXISTS (SELECT 1 FROM pgv_wait_in i WHERE i.event_type = c.event_type AND i.event = c.event AND i.queryid = c.queryid);
  END IF;

  FOR v_month IN
    SELECT DISTINCT date_trunc('month', (r->>'end_time')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'pgms' AND r->>'end_time' IS NOT NULL
  LOOP
    PERFORM pgvigil.ensure_month_partition('wait_sample', v_month);
  END LOOP;
  INSERT INTO pgvigil.wait_sample AS s (instance_id, snapshot_at, interval_secs, source, event_type, event, queryid, samples, wait_secs)
  SELECT p_instance_id, (r->>'end_time')::timestamptz,
         greatest(1, extract(epoch FROM (r->>'end_time')::timestamptz - (r->>'start_time')::timestamptz))::int,
         'pgms_wait_sampling', coalesce(r->>'event_type', 'CPU'), coalesce(r->>'event', 'CPU'), coalesce((r->>'queryid')::bigint, 0),
         sum((r->>'calls')::bigint), NULL
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'pgms' AND r->>'end_time' IS NOT NULL AND r->>'start_time' IS NOT NULL
   GROUP BY 2, 3, 5, 6, 7
  ON CONFLICT (instance_id, snapshot_at, source, event_type, event, queryid) DO UPDATE SET samples = EXCLUDED.samples;
END $$;

-- lock_tree: the blocking tree of one activity snapshot (the newest at or before p_at). After postgres_dba's
-- l2_lock_trees.sql (BSD-3, Copyright (c) 2017, Nikolay Samokhvalov): the heads are sessions some waiter names
-- in its blocking pids that wait on no one; each level below waits on a session of the level above; blocked =
-- how many sessions wait under it, directly or not. Read from activity_sample (only Lock waiters carry
-- blocking_pids, and every named blocker is stored: 0002), so the tree is the one the collector saw.
CREATE OR REPLACE FUNCTION pgvigil.lock_tree(p_instance_id int, p_at timestamptz DEFAULT now())
RETURNS TABLE (snapshot_at timestamptz, top_blocker int, level int, pid int, blocked_by int[], blocked int, state text,
               wait text, xact_start timestamptz, query_start timestamptz, state_change timestamptz, datname text,
               usename text, application_name text, query_hash bigint, path int[])
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE snap AS (
    SELECT max(s.snapshot_at) AS at FROM pgvigil.activity_sample s
     WHERE s.instance_id = p_instance_id AND s.snapshot_at <= p_at AND s.snapshot_at > p_at - interval '1 day'
  ), a AS (
    SELECT s.*, coalesce(s.blocking_pids, '{}') AS bb
      FROM pgvigil.activity_sample s, snap
     WHERE s.instance_id = p_instance_id AND s.snapshot_at = snap.at
  ), blockers AS (
    SELECT coalesce(array_agg(DISTINCT b), '{}') AS pids FROM a, unnest(a.bb) b
  ), tree AS (
    SELECT a.pid, a.pid AS top_blocker, 1 AS level, ARRAY[a.pid] AS path
      FROM a, blockers WHERE a.pid = ANY (blockers.pids) AND a.bb = '{}'
    UNION ALL
    SELECT a.pid, t.top_blocker, t.level + 1, t.path || a.pid
      FROM tree t JOIN a ON t.pid = ANY (a.bb) AND NOT a.pid = ANY (t.path)
     WHERE t.level < 20
  ), first AS (
    SELECT DISTINCT ON (pid) * FROM tree ORDER BY pid, level
  )
  SELECT a.snapshot_at, f.top_blocker, f.level, a.pid, nullif(a.bb, '{}'),
         (SELECT count(DISTINCT t.pid)::int FROM tree t WHERE f.pid = ANY (t.path) AND t.pid <> f.pid),
         CASE WHEN a.wait_event_type = 'Lock' THEN 'waiting' ELSE a.state END,
         CASE WHEN a.wait_event_type IS NOT NULL THEN a.wait_event_type || ':' || a.wait_event ELSE 'CPU*' END,
         a.xact_start, a.query_start, a.state_change, a.datname, a.usename, a.application_name, a.query_hash, f.path
    FROM first f JOIN a ON a.pid = f.pid
   ORDER BY f.top_blocker, f.path
$$;

-- ---------------------------------------------------------------------------------------------------------
-- 2. statements from pg_stat_monitor
-- ---------------------------------------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.statements_monitor_seen (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  bucket_start  timestamptz NOT NULL,
  added_at      timestamptz NOT NULL,
  PRIMARY KEY (instance_id, bucket_start)
);

-- the running total per statement since pgvigil first read the instance's pg_stat_monitor
CREATE TABLE IF NOT EXISTS pgvigil.statements_monitor_total (
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid                 bigint NOT NULL,
  userid               bigint NOT NULL,
  queryid              bigint NOT NULL,
  toplevel             boolean NOT NULL,
  datname              text,
  usename              text,
  query                text,
  first_bucket         timestamptz NOT NULL,
  calls                bigint NOT NULL DEFAULT 0,
  total_exec_ms        float8 NOT NULL DEFAULT 0,
  rows                 bigint NOT NULL DEFAULT 0,
  shared_blks_hit      bigint NOT NULL DEFAULT 0,
  shared_blks_read     bigint NOT NULL DEFAULT 0,
  shared_blks_dirtied  bigint NOT NULL DEFAULT 0,
  shared_blks_written  bigint NOT NULL DEFAULT 0,
  temp_blks_read       bigint NOT NULL DEFAULT 0,
  temp_blks_written    bigint NOT NULL DEFAULT 0,
  blk_read_ms          float8 NOT NULL DEFAULT 0,
  blk_write_ms         float8 NOT NULL DEFAULT 0,
  temp_read_ms         float8 NOT NULL DEFAULT 0,
  temp_write_ms        float8 NOT NULL DEFAULT 0,
  wal_bytes            numeric NOT NULL DEFAULT 0,
  PRIMARY KEY (instance_id, dbid, userid, queryid, toplevel)
);

-- payload: {kind:'bucket', bucket_start, dbid, datname, userid, usename, queryid, toplevel, calls, total_exec_ms, rows,
-- shared_blks_*, temp_blks_*, blk_read_ms, blk_write_ms, temp_read_ms, temp_write_ms, wal_bytes, query} per finished
-- bucket and statement. A bucket already added is skipped; the totals of the statements a new bucket touched go to
-- import_statements as cumulative rows, the 'info' row's stats_reset fixed at the instance's first bucket, so the
-- statements import never reads a reset. A statement seen for the first time is first entered at zero, at the start
-- of its first bucket, so its first bucket becomes a delta row and not a baseline.
CREATE OR REPLACE FUNCTION pgvigil.import_statements_monitor(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_epoch  timestamptz;
  v_zero   jsonb;
  v_new    jsonb;
  v_start  timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_statements_monitor'), p_instance_id);
  CREATE TEMP TABLE pgv_pgsm_in ON COMMIT DROP AS
  SELECT (r->>'bucket_start')::timestamptz AS bucket_start, (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname,
         (r->>'userid')::bigint AS userid, r->>'usename' AS usename, (r->>'queryid')::bigint AS queryid,
         coalesce((r->>'toplevel')::boolean, true) AS toplevel, r->>'query' AS query,
         coalesce((r->>'calls')::bigint, 0) AS calls, coalesce((r->>'total_exec_ms')::float8, 0) AS total_exec_ms,
         coalesce((r->>'rows')::bigint, 0) AS rows,
         coalesce((r->>'shared_blks_hit')::bigint, 0) AS shared_blks_hit, coalesce((r->>'shared_blks_read')::bigint, 0) AS shared_blks_read,
         coalesce((r->>'shared_blks_dirtied')::bigint, 0) AS shared_blks_dirtied, coalesce((r->>'shared_blks_written')::bigint, 0) AS shared_blks_written,
         coalesce((r->>'temp_blks_read')::bigint, 0) AS temp_blks_read, coalesce((r->>'temp_blks_written')::bigint, 0) AS temp_blks_written,
         coalesce((r->>'blk_read_ms')::float8, 0) AS blk_read_ms, coalesce((r->>'blk_write_ms')::float8, 0) AS blk_write_ms,
         coalesce((r->>'temp_read_ms')::float8, 0) AS temp_read_ms, coalesce((r->>'temp_write_ms')::float8, 0) AS temp_write_ms,
         coalesce((r->>'wal_bytes')::numeric, 0) AS wal_bytes
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'bucket' AND r->>'bucket_start' IS NOT NULL AND r->>'queryid' IS NOT NULL
     AND r->>'dbid' IS NOT NULL AND r->>'userid' IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM pgvigil.statements_monitor_seen s
                      WHERE s.instance_id = p_instance_id AND s.bucket_start = (r->>'bucket_start')::timestamptz);
  IF NOT EXISTS (SELECT 1 FROM pgv_pgsm_in) THEN
    RETURN;
  END IF;
  INSERT INTO pgvigil.statements_monitor_seen (instance_id, bucket_start, added_at)
  SELECT DISTINCT p_instance_id, bucket_start, p_snapshot_at FROM pgv_pgsm_in
  ON CONFLICT DO NOTHING;
  DELETE FROM pgvigil.statements_monitor_seen WHERE instance_id = p_instance_id AND bucket_start < p_snapshot_at - interval '2 days';

  SELECT coalesce(min(first_bucket), (SELECT min(bucket_start) FROM pgv_pgsm_in)) INTO v_epoch
    FROM pgvigil.statements_monitor_total WHERE instance_id = p_instance_id;

  -- statements new to the totals: entered at zero first, at the start of their earliest bucket
  SELECT coalesce(jsonb_agg(jsonb_build_object('kind', 'stmt', 'dbid', n.dbid, 'datname', n.datname, 'userid', n.userid,
           'usename', n.usename, 'queryid', n.queryid, 'toplevel', n.toplevel, 'calls', 0, 'total_exec_ms', 0, 'rows', 0,
           'shared_blks_hit', 0, 'shared_blks_read', 0, 'shared_blks_dirtied', 0, 'shared_blks_written', 0,
           'temp_blks_read', 0, 'temp_blks_written', 0, 'blk_read_ms', 0, 'blk_write_ms', 0, 'temp_read_ms', 0,
           'temp_write_ms', 0, 'wal_bytes', 0, 'query', n.query)), '[]'), min(n.first_bucket)
    INTO v_zero, v_start
    FROM (SELECT DISTINCT ON (dbid, userid, queryid, toplevel) dbid, datname, userid, usename, queryid, toplevel, query,
                 min(bucket_start) OVER (PARTITION BY dbid, userid, queryid, toplevel) AS first_bucket
            FROM pgv_pgsm_in i
           WHERE NOT EXISTS (SELECT 1 FROM pgvigil.statements_monitor_total t
                              WHERE t.instance_id = p_instance_id AND t.dbid = i.dbid AND t.userid = i.userid
                                AND t.queryid = i.queryid AND t.toplevel = i.toplevel)
           ORDER BY dbid, userid, queryid, toplevel, bucket_start) n;
  IF jsonb_array_length(v_zero) > 0 THEN
    PERFORM pgvigil.import_statements(p_instance_id, least(v_start, p_snapshot_at - interval '1 second'), v_zero);
  END IF;

  INSERT INTO pgvigil.statements_monitor_total AS t (instance_id, dbid, userid, queryid, toplevel, datname, usename, query, first_bucket,
    calls, total_exec_ms, rows, shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written,
    temp_blks_read, temp_blks_written, blk_read_ms, blk_write_ms, temp_read_ms, temp_write_ms, wal_bytes)
  SELECT p_instance_id, dbid, userid, queryid, toplevel, max(datname), max(usename), max(query), min(bucket_start),
         sum(calls), sum(total_exec_ms), sum(rows), sum(shared_blks_hit), sum(shared_blks_read), sum(shared_blks_dirtied),
         sum(shared_blks_written), sum(temp_blks_read), sum(temp_blks_written), sum(blk_read_ms), sum(blk_write_ms),
         sum(temp_read_ms), sum(temp_write_ms), sum(wal_bytes)
    FROM pgv_pgsm_in
   GROUP BY dbid, userid, queryid, toplevel
  ON CONFLICT (instance_id, dbid, userid, queryid, toplevel) DO UPDATE SET
    datname = coalesce(EXCLUDED.datname, t.datname), usename = coalesce(EXCLUDED.usename, t.usename),
    query = coalesce(t.query, EXCLUDED.query),
    calls = t.calls + EXCLUDED.calls, total_exec_ms = t.total_exec_ms + EXCLUDED.total_exec_ms, rows = t.rows + EXCLUDED.rows,
    shared_blks_hit = t.shared_blks_hit + EXCLUDED.shared_blks_hit, shared_blks_read = t.shared_blks_read + EXCLUDED.shared_blks_read,
    shared_blks_dirtied = t.shared_blks_dirtied + EXCLUDED.shared_blks_dirtied,
    shared_blks_written = t.shared_blks_written + EXCLUDED.shared_blks_written,
    temp_blks_read = t.temp_blks_read + EXCLUDED.temp_blks_read, temp_blks_written = t.temp_blks_written + EXCLUDED.temp_blks_written,
    blk_read_ms = t.blk_read_ms + EXCLUDED.blk_read_ms, blk_write_ms = t.blk_write_ms + EXCLUDED.blk_write_ms,
    temp_read_ms = t.temp_read_ms + EXCLUDED.temp_read_ms, temp_write_ms = t.temp_write_ms + EXCLUDED.temp_write_ms,
    wal_bytes = t.wal_bytes + EXCLUDED.wal_bytes;

  SELECT jsonb_agg(jsonb_build_object('kind', 'stmt', 'dbid', t.dbid, 'datname', t.datname, 'userid', t.userid, 'usename', t.usename,
           'queryid', t.queryid, 'toplevel', t.toplevel, 'calls', t.calls, 'total_exec_ms', t.total_exec_ms, 'rows', t.rows,
           'shared_blks_hit', t.shared_blks_hit, 'shared_blks_read', t.shared_blks_read, 'shared_blks_dirtied', t.shared_blks_dirtied,
           'shared_blks_written', t.shared_blks_written, 'temp_blks_read', t.temp_blks_read, 'temp_blks_written', t.temp_blks_written,
           'blk_read_ms', t.blk_read_ms, 'blk_write_ms', t.blk_write_ms, 'temp_read_ms', t.temp_read_ms,
           'temp_write_ms', t.temp_write_ms, 'wal_bytes', t.wal_bytes, 'query', t.query))
         || jsonb_build_array(jsonb_build_object('kind', 'info', 'dealloc', NULL, 'stats_reset', v_epoch))
    INTO v_new
    FROM pgvigil.statements_monitor_total t
   WHERE t.instance_id = p_instance_id
     AND EXISTS (SELECT 1 FROM pgv_pgsm_in i WHERE i.dbid = t.dbid AND i.userid = t.userid AND i.queryid = t.queryid AND i.toplevel = t.toplevel);
  PERFORM pgvigil.import_statements(p_instance_id, p_snapshot_at, v_new);
END $$;

-- ---------------------------------------------------------------------------------------------------------
-- 3. indexes
-- ---------------------------------------------------------------------------------------------------------

-- one row per database read: how many indexes it has and how long its usage counters have counted
CREATE TABLE IF NOT EXISTS pgvigil.index_databases (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid           bigint NOT NULL,
  datname        text NOT NULL,
  snapshot_at    timestamptz NOT NULL,
  indexes        int,
  index_bytes    bigint,
  stats_since    timestamptz,      -- the database's stats_reset, else the server's start: idx_scan counts from here
  is_replica     boolean,
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid)
);

-- one row per index and problem: unused | redundant | duplicate | invalid
CREATE TABLE IF NOT EXISTS pgvigil.index_state (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid             bigint NOT NULL,
  indexrelid       bigint NOT NULL,
  problem          text NOT NULL CHECK (problem IN ('unused', 'redundant', 'duplicate', 'invalid')),
  datname          text NOT NULL,
  schema_name      text,
  table_name       text,
  index_name       text,
  access_method    text,
  index_bytes      bigint,
  table_bytes      bigint,
  idx_scan         bigint,
  covered_by       text,             -- redundant / duplicate: the index (or indexes) that make it so
  covered_by_def   text,
  index_def        text,
  supports_fk      boolean,          -- redundant: a foreign key's referencing columns lead it
  drop_sql         text,             -- the DO line, shown as text, never run by pgvigil
  undo_sql         text,             -- its UNDO line
  first_seen       timestamptz NOT NULL,
  snapshot_at      timestamptz NOT NULL,
  is_present       boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, dbid, indexrelid, problem)
);

-- payload: {kind:'db', dbid, datname, indexes, index_bytes, stats_since, is_replica} per database read,
-- {kind:'index', dbid, indexrelid, problem, ...} per finding, {kind:'collector_error', source:'indexes:<db>'} per database
-- that could not be read (its rows are kept as they were). An index of a database read and not in the payload, and every
-- row of a database no longer listed and not in error, is no longer present.
CREATE OR REPLACE FUNCTION pgvigil.import_indexes(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_indexes'), p_instance_id);
  INSERT INTO pgvigil.index_databases AS d (instance_id, dbid, datname, snapshot_at, indexes, index_bytes, stats_since, is_replica, is_present)
  SELECT p_instance_id, (r->>'dbid')::bigint, r->>'datname', p_snapshot_at, (r->>'indexes')::int, (r->>'index_bytes')::bigint,
         (r->>'stats_since')::timestamptz, (r->>'is_replica')::boolean, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND r->>'dbid' IS NOT NULL
  ON CONFLICT (instance_id, dbid) DO UPDATE SET datname = EXCLUDED.datname, snapshot_at = EXCLUDED.snapshot_at,
    indexes = EXCLUDED.indexes, index_bytes = EXCLUDED.index_bytes, stats_since = EXCLUDED.stats_since,
    is_replica = EXCLUDED.is_replica, is_present = true;

  INSERT INTO pgvigil.index_state AS s (instance_id, dbid, indexrelid, problem, datname, schema_name, table_name, index_name,
    access_method, index_bytes, table_bytes, idx_scan, covered_by, covered_by_def, index_def, supports_fk, drop_sql, undo_sql,
    first_seen, snapshot_at, is_present)
  SELECT DISTINCT ON ((r->>'dbid')::bigint, (r->>'indexrelid')::bigint, r->>'problem')
         p_instance_id, (r->>'dbid')::bigint, (r->>'indexrelid')::bigint, r->>'problem', r->>'datname', r->>'schema_name',
         r->>'table_name', r->>'index_name', r->>'access_method', (r->>'index_bytes')::bigint, (r->>'table_bytes')::bigint,
         (r->>'idx_scan')::bigint, r->>'covered_by', r->>'covered_by_def', r->>'index_def', (r->>'supports_fk')::boolean,
         r->>'drop_sql', r->>'undo_sql', p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'index' AND r->>'dbid' IS NOT NULL AND r->>'indexrelid' IS NOT NULL
     AND r->>'problem' IN ('unused', 'redundant', 'duplicate', 'invalid')
  ON CONFLICT (instance_id, dbid, indexrelid, problem) DO UPDATE SET datname = EXCLUDED.datname, schema_name = EXCLUDED.schema_name,
    table_name = EXCLUDED.table_name, index_name = EXCLUDED.index_name, access_method = EXCLUDED.access_method,
    index_bytes = EXCLUDED.index_bytes, table_bytes = EXCLUDED.table_bytes, idx_scan = EXCLUDED.idx_scan,
    covered_by = EXCLUDED.covered_by, covered_by_def = EXCLUDED.covered_by_def, index_def = EXCLUDED.index_def,
    supports_fk = EXCLUDED.supports_fk, drop_sql = EXCLUDED.drop_sql, undo_sql = EXCLUDED.undo_sql,
    first_seen = CASE WHEN s.is_present THEN s.first_seen ELSE EXCLUDED.first_seen END,
    snapshot_at = EXCLUDED.snapshot_at, is_present = true;

  -- a database read now: its findings not in this read are gone
  UPDATE pgvigil.index_state s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = s.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'index' AND (r->>'dbid')::bigint = s.dbid AND (r->>'indexrelid')::bigint = s.indexrelid
                        AND r->>'problem' = s.problem);
  -- a database neither read nor in error: dropped, or no longer connectable
  UPDATE pgvigil.index_databases d SET is_present = false, snapshot_at = p_snapshot_at
   WHERE d.instance_id = p_instance_id AND d.is_present
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'db' AND (r->>'dbid')::bigint = d.dbid)
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                      WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'indexes:' || d.datname);
  UPDATE pgvigil.index_state s SET is_present = false, snapshot_at = p_snapshot_at
   WHERE s.instance_id = p_instance_id AND s.is_present
     AND EXISTS (SELECT 1 FROM pgvigil.index_databases d WHERE d.instance_id = s.instance_id AND d.dbid = s.dbid AND NOT d.is_present);
END $$;

-- index_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms, detail,
-- source, at). An invalid index and an exact duplicate warn; a redundant index and an unused one of 10 MB or more are info,
-- the unused one only once the usage counters have counted for 7 days and not on a replica (its own counters see only its
-- own reads; an index the primary uses reads as unused there).
CREATE OR REPLACE VIEW pgvigil.index_findings AS
WITH k AS (SELECT 10485760::bigint AS unused_bytes_min, interval '7 days' AS unused_window_min)
SELECT s.instance_id, CASE WHEN s.problem IN ('invalid', 'duplicate') THEN 'warning' ELSE 'info' END AS severity,
       s.problem || ' index' AS setting,
       s.datname || ': ' || coalesce(s.schema_name || '.', '') || coalesce(s.index_name, s.indexrelid::text) AS value,
       true AS is_set,
       CASE s.problem WHEN 'invalid' THEN 'drop it (DROP INDEX CONCURRENTLY) or rebuild it'
                      WHEN 'duplicate' THEN 'drop one of the two'
                      WHEN 'redundant' THEN 'drop it, after checking the covering index serves the same queries'
                      ELSE 'drop it, after checking replicas and rare jobs do not use it' END AS suggested,
       'all' AS platforms,
       CASE s.problem
         WHEN 'invalid' THEN 'an invalid index (a failed CREATE INDEX CONCURRENTLY or REINDEX) is never read but is still written on every change to its table'
         WHEN 'duplicate' THEN 'the same columns, operator classes, expressions and predicate as ' || coalesce(s.covered_by, 'another index') || ': every write maintains both and only one is read'
         WHEN 'redundant' THEN 'its columns lead ' || coalesce(s.covered_by, 'another index') || ', which serves the same lookups; it costs writes and memory'
                               || CASE WHEN s.supports_fk THEN ' (it may serve a foreign key: check before dropping)' ELSE '' END
         ELSE 'no index scan since ' || coalesce(to_char(d.stats_since, 'YYYY-MM-DD'), 'the statistics reset') || ', '
              || pg_size_pretty(s.index_bytes) || ': it costs every write and is never read' END AS detail,
       CASE WHEN s.problem = 'unused' THEN 'pgvigil indexes' ELSE 'postgres_dba' END AS source, s.snapshot_at AS at
  FROM pgvigil.index_state s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
  LEFT JOIN pgvigil.index_databases d ON d.instance_id = s.instance_id AND d.dbid = s.dbid
  CROSS JOIN k
 WHERE s.is_present
   AND (s.problem <> 'unused'
        OR (coalesce(s.index_bytes, 0) >= k.unused_bytes_min AND NOT coalesce(d.is_replica, false)
            AND d.stats_since IS NOT NULL AND d.stats_since < now() - k.unused_window_min));
