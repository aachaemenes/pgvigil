-- 0395: an elastic pool's limits over time (P25 task 9b, DBA Dash's Pool history). The hourly read mssql_pool_limits
-- of an Azure SQL Database in an elastic pool opens its own connection to the logical server's master and, where the
-- login holds dbmanager there (or is the server admin), reads sys.elastic_pool_resource_stats for its own pool: the
-- view keeps 15-second rows for 14 days, and the read sends them collapsed into periods of equal limits - one
-- 'limit_period' row each (its first row's start, its last row's end, elastic_pool_dtu_limit,
-- elastic_pool_storage_limit_mb, and elastic_pool_cpu_limit, which Microsoft calls 'informational purposes only. Not
-- supported.': stored, never shown as a supported figure) - and one 'limit_read' row: the state 'read' with its words
-- and the window the view held (its oldest row's start, its newest row's end). The import also takes the states
-- 'no_right' (the login is not in dbmanager) and 'no_master' (it could not sign in to master), but the collector never
-- sends them: without the right or master its run is SKIPPED with those words, kept in collection_dates (where the page
-- reads them), and sends no row.
--   mssql_pool_limit_history   per pooled database (the reading instance: the instance scope's policy follows it),
--                              its pool's periods; each member database keeps its own copy of the same history
--   mssql_pool_limit_read      per instance: the last read's state and words (the page's and the rights row's)
-- The reads overlap (14 days, every hour): a read rewrites the periods that start inside its window; the period that
-- started before it (master no longer holds its start) is continued by the read's first period when their limits are
-- the same - it only ends later - and else ends where that period starts. The same read twice stores nothing twice.
--
-- THE JOIN-FILE RULE: 0395 sorts after the join file and creates only its own objects. Its lines for the join are in
-- scripts/PARITY-S3-join-lines.sql: both tables under the instance scope's policy (the join's scope tests name them).

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pool_limit_history (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  server            text NOT NULL,
  pool              text NOT NULL,
  valid_from        timestamptz NOT NULL,     -- the period's first 15-second row's start
  valid_to          timestamptz NOT NULL,     -- its last row's end as last read
  dtu_limit         int,
  storage_limit_mb  bigint,
  cpu_limit         numeric(7,2),             -- elastic_pool_cpu_limit: informational, not supported (Microsoft)
  PRIMARY KEY (instance_id, server, pool, valid_from)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_pool_limit_read (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  server       text,
  pool         text,
  read_at      timestamptz NOT NULL,
  state        text NOT NULL CHECK (state IN ('read', 'no_right', 'no_master')),
  note         text
);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_pool_limits(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_read      jsonb;
  v_from      timestamptz;
  f_from      timestamptz;                 -- the read's first period
  f_to        timestamptz;
  f_dtu       int;
  f_storage   bigint;
  f_cpu       numeric(7,2);
  v_has_first boolean;
  v_prev      record;
  v_merged    boolean;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_pool_limits: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  FOR v_read IN SELECT r FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'limit_read' LOOP
    INSERT INTO pgvigil.mssql_pool_limit_read AS x (instance_id, server, pool, read_at, state, note)
    VALUES (p_instance_id, v_read->>'server', v_read->>'pool', p_snapshot_at, v_read->>'state', v_read->>'note')
    ON CONFLICT (instance_id) DO UPDATE
       SET server = EXCLUDED.server, pool = EXCLUDED.pool, read_at = EXCLUDED.read_at, state = EXCLUDED.state, note = EXCLUDED.note;
    -- a read without the right or without master changes no period; a read of an empty view has no window
    CONTINUE WHEN v_read->>'state' IS DISTINCT FROM 'read' OR v_read->>'window_from' IS NULL;
    v_from := (v_read->>'window_from')::timestamptz;
    -- one import of a database's pool history at a time: two runs' deletes and merges would interleave
    PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_pool_limits'), p_instance_id);
    -- master holds the window whole: the periods that start inside it are written again from the read
    DELETE FROM pgvigil.mssql_pool_limit_history h
     WHERE h.instance_id = p_instance_id AND h.server = v_read->>'server' AND h.pool = v_read->>'pool' AND h.valid_from >= v_from;
    SELECT (r->>'valid_from')::timestamptz, (r->>'valid_to')::timestamptz, (r->>'dtu_limit')::int,
           (r->>'storage_limit_mb')::bigint, (r->>'cpu_limit')::numeric(7,2)
      INTO f_from, f_to, f_dtu, f_storage, f_cpu
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'limit_period' AND r->>'server' = v_read->>'server' AND r->>'pool' = v_read->>'pool'
     ORDER BY (r->>'valid_from')::timestamptz
     LIMIT 1;
    v_has_first := FOUND;
    v_merged := false;
    SELECT h.valid_from, h.valid_to, h.dtu_limit, h.storage_limit_mb, h.cpu_limit INTO v_prev
      FROM pgvigil.mssql_pool_limit_history h
     WHERE h.instance_id = p_instance_id AND h.server = v_read->>'server' AND h.pool = v_read->>'pool'
     ORDER BY h.valid_from DESC
     LIMIT 1;
    -- the period that started before the window: continued by the read's first period with the same limits (it only
    -- ends later; a gap in the reads between them is no change of the limits), else ended where that period starts
    IF FOUND AND v_has_first THEN
      IF (v_prev.dtu_limit, v_prev.storage_limit_mb, v_prev.cpu_limit) IS NOT DISTINCT FROM (f_dtu, f_storage, f_cpu) THEN
        UPDATE pgvigil.mssql_pool_limit_history h SET valid_to = greatest(h.valid_to, f_to)
         WHERE h.instance_id = p_instance_id AND h.server = v_read->>'server' AND h.pool = v_read->>'pool' AND h.valid_from = v_prev.valid_from;
        v_merged := true;
      ELSE
        UPDATE pgvigil.mssql_pool_limit_history h SET valid_to = least(h.valid_to, f_from)
         WHERE h.instance_id = p_instance_id AND h.server = v_read->>'server' AND h.pool = v_read->>'pool' AND h.valid_from = v_prev.valid_from;
      END IF;
    END IF;
    INSERT INTO pgvigil.mssql_pool_limit_history AS h (instance_id, server, pool, valid_from, valid_to, dtu_limit, storage_limit_mb, cpu_limit)
    SELECT p_instance_id, r->>'server', r->>'pool', (r->>'valid_from')::timestamptz, (r->>'valid_to')::timestamptz, (r->>'dtu_limit')::int,
           (r->>'storage_limit_mb')::bigint, (r->>'cpu_limit')::numeric(7,2)
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'limit_period' AND r->>'server' = v_read->>'server' AND r->>'pool' = v_read->>'pool'
       AND NOT (v_merged AND (r->>'valid_from')::timestamptz = f_from)
    ON CONFLICT (instance_id, server, pool, valid_from) DO UPDATE
       SET valid_to = EXCLUDED.valid_to, dtu_limit = EXCLUDED.dtu_limit, storage_limit_mb = EXCLUDED.storage_limit_mb, cpu_limit = EXCLUDED.cpu_limit;
  END LOOP;
END $$;
