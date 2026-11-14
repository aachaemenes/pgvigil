-- 0134: the move from DBA Dash (task 206). A server DBA Dash monitors is added to pgvigil from Admin > Instances
-- ('Move from DBA Dash'), pgvigil collects it, and DBA Dash's history of it is imported up to pgvigil's first read,
-- so no minute is stored twice and nothing between DBA Dash's last row and pgvigil's first is lost.
--
--   dbadash_moves     one row per moved server (DBA Dash's Instance, its @@SERVERNAME): the pgvigil instance it was
--                     added as, who added it and with which sign-in, collect_from (the collector's first read of it
--                     after the add: set by dbadash_move_first_read, the trigger below, never by a caller), the dry
--                     run's counts, the history import's run marker and outcome, the checklist ticks.
--   dbadash_move_ids  every DBA Dash InstanceID of that server (DBA Dash lists a server twice when it was added under
--                     two names, and keeps an old id when it was re-added): the import of any of them fills the moved
--                     instance, and the DBA Dash door matches the server through it (its display name may hold a '\',
--                     which a pgvigil name may not).
--
-- The import's writes are functions, SECURITY DEFINER by apply_roles' import_ prefix and granted to pgvigil_collector:
-- the web process imports through the actions door's audit login and the CLI through any collector-member login; no
-- login but the owner may write the history tables themselves. Each import function takes the instance's import lock
-- (two imports of one server at once store each row once) and, for a moved server, refuses until the collector has
-- read it (collect_from), drops every row at or after collect_from whatever bound its caller gave, and waits for the
-- collector's own CPU and Agent job reads, so the collector's rows are stored first and the import's key skips them
-- (the collector's job key carries msdb's run_date and run_time, which DBA Dash does not keep). A server imported
-- without a move (pgvigil import dbadash on its own) is imported as before: the caller's bounds, no wait.

CREATE TABLE IF NOT EXISTS pgvigil.dbadash_moves (
  instance_id   int PRIMARY KEY REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  repository    text NOT NULL,                 -- the dbadash: repository's name in pgvigil.yaml
  server        text NOT NULL,                 -- DBA Dash's Instance (@@SERVERNAME) of the server moved
  auth          text NOT NULL,                 -- the sign-in it was added with (sql, windows, entra, entra-identity)
  added_at      timestamptz NOT NULL,
  added_by      text NOT NULL,
  collect_from  timestamptz,                   -- the collector's first read OF THIS SERVER after the add (dbadash_move_first_read)
  cpu_read_at   timestamptz,                   -- the collector's first ok mssql_cpu / mssql_jobs read at or after collect_from
  jobs_read_at  timestamptz,                   -- (dbadash_move_reads): the import of cpu / jobruns waits for it
  counted_at    timestamptz,                   -- the last dry run ('Count'): its counts per mapping and its bound
  counted_by    text,
  counts        jsonb,
  run_id        bigint NOT NULL DEFAULT 0,     -- the history import: the run's number (beat and ended name it), who
  run_by        text,                          -- started it, when, its last progress, how it ended and what it stored
  run_started   timestamptz,                   -- per mapping
  run_beat      timestamptz,
  run_ended     timestamptz,
  run_outcome   text CHECK (run_outcome IN ('ok', 'partial', 'failed')),
  imported      jsonb,
  imported_at   timestamptz,                   -- the last run that ended ok in all four mappings
  ticks         jsonb NOT NULL DEFAULT '{}'    -- the checklist: {"<step>": {"done": bool, "at": ..., "by": ...}}
);
CREATE UNIQUE INDEX IF NOT EXISTS dbadash_moves_server ON pgvigil.dbadash_moves (repository, upper(server));
COMMENT ON TABLE pgvigil.dbadash_moves IS 'Servers moved from DBA Dash to pgvigil (task 206): the instance, collect_from, the import and the checklist.';

CREATE TABLE IF NOT EXISTS pgvigil.dbadash_move_ids (
  repository   text NOT NULL,
  dbadash_id   int NOT NULL,                   -- DBA Dash's InstanceID
  instance_id  int NOT NULL REFERENCES pgvigil.dbadash_moves (instance_id) ON DELETE CASCADE,
  PRIMARY KEY (repository, dbadash_id)
);
CREATE INDEX IF NOT EXISTS dbadash_move_ids_instance ON pgvigil.dbadash_move_ids (instance_id);

-- collect_from: the first mssql_instance write after the add (one row per instance, written only by the collector's
-- read of a server it reached; the import never writes it) that read THE MOVED SERVER (its @@SERVERNAME is DBA Dash's
-- Instance: a host that reaches another server sets nothing, and the import says which server it reaches) and was
-- read after the add (a read in flight across a remove and a quick move sets nothing). An UPDATE fires it too: a
-- server collected before, removed and moved again keeps its mssql_instance row, and its next read is its first since
-- the move.
CREATE OR REPLACE FUNCTION pgvigil.dbadash_move_first_read() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE pgvigil.dbadash_moves SET collect_from = NEW.snapshot_at
   WHERE instance_id = NEW.instance_id AND collect_from IS NULL
     AND upper(server) = upper(NEW.server_name) AND NEW.snapshot_at >= added_at;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS dbadash_move_first_read ON pgvigil.mssql_instance;
CREATE TRIGGER dbadash_move_first_read AFTER INSERT OR UPDATE ON pgvigil.mssql_instance
  FOR EACH ROW EXECUTE FUNCTION pgvigil.dbadash_move_first_read();

-- cpu_read_at / jobs_read_at: the collector's first ok CPU and Agent job reads at or after collect_from, kept (a later
-- failed read does not hold an import back again). 'skipped' is not ok: a job read is skipped when the login cannot
-- read msdb, and its first read after the right is granted goes back days with the collector's own key, which would
-- store a second copy of a run the import stored first.
CREATE OR REPLACE FUNCTION pgvigil.dbadash_move_reads() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE pgvigil.dbadash_moves
     SET cpu_read_at = CASE WHEN NEW.collection = 'mssql_cpu' THEN coalesce(cpu_read_at, NEW.snapshot_at) ELSE cpu_read_at END,
         jobs_read_at = CASE WHEN NEW.collection = 'mssql_jobs' THEN coalesce(jobs_read_at, NEW.snapshot_at) ELSE jobs_read_at END
   WHERE instance_id = NEW.instance_id AND collect_from IS NOT NULL AND NEW.snapshot_at >= collect_from
     AND ((NEW.collection = 'mssql_cpu' AND cpu_read_at IS NULL) OR (NEW.collection = 'mssql_jobs' AND jobs_read_at IS NULL));
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS dbadash_move_reads ON pgvigil.collection_dates;
CREATE TRIGGER dbadash_move_reads AFTER INSERT OR UPDATE ON pgvigil.collection_dates
  FOR EACH ROW WHEN (NEW.status = 'ok' AND NEW.collection IN ('mssql_cpu', 'mssql_jobs'))
  EXECUTE FUNCTION pgvigil.dbadash_move_reads();

-- a move ends with its page row: a remove (a read instance stays, inactive, with its history) takes the move, so the
-- name can be added or moved again from the start (a new move: collect_from from its own first read)
CREATE OR REPLACE FUNCTION pgvigil.dbadash_move_end() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM pgvigil.dbadash_moves m USING pgvigil.instances i WHERE i.name = OLD.name AND m.instance_id = i.instance_id;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS dbadash_move_end ON pgvigil.admin_instances;
CREATE TRIGGER dbadash_move_end AFTER DELETE ON pgvigil.admin_instances
  FOR EACH ROW EXECUTE FUNCTION pgvigil.dbadash_move_end();

-- dbadash_import_wait: why a moved server's mapping (or a run, p_key 'run') cannot be imported now, or NULL: before
-- collect_from (saying which server pgvigil reaches at the address when it read another one), cpu before the
-- collector's first ok CPU read since, jobruns before its first ok job read since (each with that collection's last
-- word: a missing right says which).
CREATE OR REPLACE FUNCTION pgvigil.dbadash_import_wait(p_instance_id int, p_key text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT CASE
    WHEN m.collect_from IS NULL AND r.server_name IS NOT NULL AND upper(r.server_name) <> upper(m.server) AND r.snapshot_at >= m.added_at THEN
      format('pgvigil reaches %s at this address, not %s: correct the host on Admin > Instances (the import waits for a read of %s)',
             r.server_name, m.server, m.server)
    WHEN m.collect_from IS NULL THEN
      'collect it first: pgvigil has not read this server since it was moved (the import takes DBA Dash''s history up to pgvigil''s first read)'
    WHEN p_key = 'cpu' AND m.cpu_read_at IS NULL THEN
      'the collector''s first CPU read since the move is not stored yet: the import waits for it, so no minute is stored twice'
        || coalesce(format(' (its last read: %s%s)', c.status, coalesce(': ' || left(c.note, 300), '')), '')
    WHEN p_key = 'jobruns' AND m.jobs_read_at IS NULL THEN
      'the collector''s first Agent job read since the move is not stored yet: the import waits for it, so no job outcome is stored twice'
        || coalesce(format(' (its last read: %s%s)', j.status, coalesce(': ' || left(j.note, 300), '')), '')
  END
    FROM pgvigil.dbadash_moves m
    LEFT JOIN pgvigil.mssql_instance r ON r.instance_id = m.instance_id
    LEFT JOIN pgvigil.collection_dates c ON c.instance_id = m.instance_id AND c.collection = 'mssql_cpu'
    LEFT JOIN pgvigil.collection_dates j ON j.instance_id = m.instance_id AND j.collection = 'mssql_jobs'
   WHERE m.instance_id = p_instance_id
$$;

-- dbadash_import_gate: the instance's import lock to the commit, then the bound of a moved server (rows at or after
-- it are not imported) or NULL (no move: the caller's own bounds); a mapping that must wait raises its reason.
CREATE OR REPLACE FUNCTION pgvigil.dbadash_import_gate(p_instance_id int, p_key text)
RETURNS timestamptz LANGUAGE plpgsql AS $$
DECLARE
  v_from timestamptz;
  v_moved boolean;
  v_why text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.dbadash_import'), p_instance_id);
  -- the collector's own doors write SQL Server history under a SQL Server instance only (0074)
  IF NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = p_instance_id AND i.engine = 'sqlserver') THEN
    RAISE EXCEPTION 'dbadash import: instance % is not a SQL Server instance of pgvigil', p_instance_id USING ERRCODE = '55000';
  END IF;
  SELECT true, m.collect_from INTO v_moved, v_from FROM pgvigil.dbadash_moves m WHERE m.instance_id = p_instance_id;
  IF v_moved IS NULL THEN
    RETURN NULL;
  END IF;
  v_why := pgvigil.dbadash_import_wait(p_instance_id, p_key);
  IF v_why IS NOT NULL THEN
    RAISE EXCEPTION 'dbadash import: %', v_why USING ERRCODE = '55000';
  END IF;
  RETURN v_from;
END $$;

-- dbadash_import_months: the months of a batch's rows before the bound, oldest first, each one's partition made
CREATE OR REPLACE FUNCTION pgvigil.dbadash_import_months(p_table text, p_rows jsonb, p_to timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_month timestamptz;
BEGIN
  FOR v_month IN SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
                   FROM jsonb_array_elements(coalesce(p_rows, '[]')) r
                  WHERE r->>'at' IS NOT NULL AND (p_to IS NULL OR (r->>'at')::timestamptz < p_to)
                  ORDER BY 1 LOOP
    PERFORM pgvigil.ensure_month_partition(p_table, v_month);
  END LOOP;
END $$;

-- The four mappings (internal/dbadash/import.go reads DBA Dash's rows; these write them): p_rows is a batch as JSON
-- records named as the T-SQL aliases them ('at' the row's UTC time), p_facts the instance's facts ({"linux": bool});
-- each returns the rows it inserted.

-- cpu: the record number is the time's negative milliseconds (a live read's ring-buffer numbers are positive, so an
-- imported row never stands for a live one); a DBA Dash minute within 30 s of a stored row (the collector's read of
-- the same ring-buffer record: DBA Dash timed it with GETUTCDATE, the collector with SYSUTCDATETIME) is skipped; SQL
-- Server on Linux writes no idle figure: other and idle stay NULL there, as the collector stores them. The collector's
-- own CPU lock (0074's import_mssql_cpu) is taken too, so a live read and an import of one server never interleave.
CREATE OR REPLACE FUNCTION pgvigil.import_dbadash_cpu(p_instance_id int, p_rows jsonb, p_facts jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_to timestamptz := pgvigil.dbadash_import_gate(p_instance_id, 'cpu');
  v_linux boolean := coalesce((p_facts->>'linux')::boolean, false);
  v_n bigint;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_cpu'), p_instance_id);
  PERFORM pgvigil.dbadash_import_months('mssql_cpu_sample', p_rows, v_to);
  WITH x AS (SELECT * FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(at timestamptz, sql_pct int, idle_pct int)
              WHERE r.at IS NOT NULL AND r.sql_pct IS NOT NULL AND (v_to IS NULL OR r.at < v_to)),
  ins AS (
    INSERT INTO pgvigil.mssql_cpu_sample (instance_id, snapshot_at, record_id, sql_pct, other_pct, idle_pct)
    SELECT p_instance_id, x.at, -(extract(epoch FROM x.at) * 1000)::bigint, least(greatest(x.sql_pct, 0), 100),
           CASE WHEN v_linux THEN NULL ELSE least(greatest(100 - x.sql_pct - x.idle_pct, 0), 100) END,
           CASE WHEN v_linux THEN NULL ELSE least(greatest(x.idle_pct, 0), 100) END
      FROM x
     WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_cpu_sample c
                        WHERE c.instance_id = p_instance_id AND c.snapshot_at BETWEEN x.at - interval '30 seconds' AND x.at + interval '30 seconds')
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END $$;

-- volumes: DBA Dash keeps a mount point in capitals (UPPER(volume_mount_point)): a volume pgvigil already lists keeps
-- its own spelling; the key is the instance, the time and the volume
CREATE OR REPLACE FUNCTION pgvigil.import_dbadash_volumes(p_instance_id int, p_rows jsonb, p_facts jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_to timestamptz := pgvigil.dbadash_import_gate(p_instance_id, 'volumes');
  v_n bigint;
BEGIN
  PERFORM pgvigil.dbadash_import_months('mssql_volume_sample', p_rows, v_to);
  WITH x AS (SELECT * FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(at timestamptz, volume text, total_bytes bigint, free_bytes bigint)
              WHERE r.at IS NOT NULL AND r.volume IS NOT NULL AND (v_to IS NULL OR r.at < v_to)),
  ins AS (
    INSERT INTO pgvigil.mssql_volume_sample (instance_id, snapshot_at, volume, total_bytes, free_bytes)
    SELECT p_instance_id, x.at, n.volume, x.total_bytes, x.free_bytes
      FROM x
     CROSS JOIN LATERAL (SELECT coalesce((SELECT v.volume FROM pgvigil.mssql_volumes v WHERE v.instance_id = p_instance_id AND upper(v.volume) = upper(x.volume)
                                           ORDER BY v.is_present DESC, v.volume LIMIT 1), x.volume) AS volume) n
     WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_volume_sample v WHERE v.instance_id = p_instance_id AND v.snapshot_at = x.at AND upper(v.volume) = upper(x.volume))
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END $$;

-- dbsize: one row per snapshot and database (the T-SQL sums the files by the collector's rule, 0067)
CREATE OR REPLACE FUNCTION pgvigil.import_dbadash_dbsize(p_instance_id int, p_rows jsonb, p_facts jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_to timestamptz := pgvigil.dbadash_import_gate(p_instance_id, 'dbsize');
  v_n bigint;
BEGIN
  PERFORM pgvigil.dbadash_import_months('mssql_database_size', p_rows, v_to);
  WITH x AS (SELECT * FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(at timestamptz, database_name text, data_bytes bigint, log_bytes bigint,
                                                                          data_used_bytes bigint, log_used_bytes bigint, files int)
              WHERE r.at IS NOT NULL AND r.database_name IS NOT NULL AND (v_to IS NULL OR r.at < v_to)),
  ins AS (
    INSERT INTO pgvigil.mssql_database_size (instance_id, snapshot_at, database_name, data_bytes, log_bytes, data_used_bytes, log_used_bytes, files)
    SELECT p_instance_id, x.at, x.database_name, x.data_bytes, x.log_bytes, x.data_used_bytes, x.log_used_bytes, x.files
      FROM x
     WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_database_size d WHERE d.instance_id = p_instance_id AND d.snapshot_at = x.at AND d.database_name = x.database_name)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END $$;

-- jobruns: DBA Dash keeps a run's start in UTC; msdb's run_date / run_time (the server's local clock) are rebuilt by
-- the T-SQL with the instance's CURRENT offset (local_at). The key is the collector's without msdb's date and time:
-- the history id, job and step within 3 hours (a restored msdb starts its ids again; 3 hours keeps such a run apart).
-- For a moved server the collector's rows are stored first (dbadash_import_wait), so this key skips them whatever
-- hour the rebuilt local time shows.
CREATE OR REPLACE FUNCTION pgvigil.import_dbadash_jobruns(p_instance_id int, p_rows jsonb, p_facts jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_to timestamptz := pgvigil.dbadash_import_gate(p_instance_id, 'jobruns');
  v_n bigint;
BEGIN
  PERFORM pgvigil.dbadash_import_months('mssql_job_runs', p_rows, v_to);
  WITH x AS (SELECT * FROM jsonb_to_recordset(coalesce(p_rows, '[]')) AS r(at timestamptz, history_id bigint, job_id text, job_name text, step_id int,
                                                                          step_name text, run_status int, duration_s bigint, sql_message_id int,
                                                                          sql_severity int, retries int, message text, local_at timestamp)
              WHERE r.at IS NOT NULL AND r.history_id IS NOT NULL AND r.job_id IS NOT NULL AND r.step_id IS NOT NULL
                AND (v_to IS NULL OR r.at < v_to)),
  ins AS (
    INSERT INTO pgvigil.mssql_job_runs (instance_id, snapshot_at, history_id, job_id, job_name, step_id, step_name, run_date, run_time,
                                        run_status, duration_s, sql_message_id, sql_severity, retries, message)
    SELECT p_instance_id, x.at, x.history_id, upper(x.job_id), x.job_name, x.step_id, x.step_name,
           to_char(x.local_at, 'YYYYMMDD')::int, to_char(x.local_at, 'HH24MISS')::int,
           x.run_status, x.duration_s, x.sql_message_id, x.sql_severity, x.retries, x.message
      FROM x
     WHERE NOT EXISTS (SELECT 1 FROM pgvigil.mssql_job_runs j
                        WHERE j.instance_id = p_instance_id AND j.snapshot_at BETWEEN x.at - interval '3 hours' AND x.at + interval '3 hours'
                          AND j.history_id = x.history_id AND j.job_id = upper(x.job_id) AND j.step_id = x.step_id)
    RETURNING 1)
  SELECT count(*) INTO v_n FROM ins;
  RETURN v_n;
END $$;

-- dbadash_import_stored: the rows pgvigil holds for one instance, mapping and window (the import's 'stored'). A read,
-- granted to the reader by apply_roles and to the collector here: SECURITY DEFINER, so a collector-member login, which
-- has no SELECT on any table, can read the counts of what it imported.
CREATE OR REPLACE FUNCTION pgvigil.dbadash_import_stored(p_instance_id int, p_key text, p_from timestamptz, p_to timestamptz)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
  SELECT CASE p_key
    WHEN 'cpu' THEN (SELECT count(*) FROM pgvigil.mssql_cpu_sample WHERE instance_id = p_instance_id AND snapshot_at >= p_from AND snapshot_at < p_to)
    WHEN 'volumes' THEN (SELECT count(*) FROM pgvigil.mssql_volume_sample WHERE instance_id = p_instance_id AND snapshot_at >= p_from AND snapshot_at < p_to)
    WHEN 'dbsize' THEN (SELECT count(*) FROM pgvigil.mssql_database_size WHERE instance_id = p_instance_id AND snapshot_at >= p_from AND snapshot_at < p_to)
    WHEN 'jobruns' THEN (SELECT count(*) FROM pgvigil.mssql_job_runs WHERE instance_id = p_instance_id AND snapshot_at >= p_from AND snapshot_at < p_to)
  END
$$;
GRANT EXECUTE ON FUNCTION pgvigil.dbadash_import_stored(int, text, timestamptz, timestamptz) TO pgvigil_collector;

-- dbadash_import_target: which pgvigil instance a DBA Dash instance's history goes to, and what holds it back, read
-- only (the dry run's; import_dbadash_instance is the run's). p: repository, dbadash_id, name (the name a run without a
-- move would use). Answers {instance_id (null: none yet), name, moved, collect_from, skipped (the whole instance),
-- wait: {mapping: why}}. A moved server: its move, whatever the name; else the SQL Server instance of that name.
CREATE OR REPLACE FUNCTION pgvigil.dbadash_import_target(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
DECLARE
  v_id int;
  v_name text;
  v_eng text;
  v_from timestamptz;
  v_wait jsonb := '{}';
  v_key text;
  v_why text;
BEGIN
  SELECT m.instance_id, i.name, m.collect_from INTO v_id, v_name, v_from
    FROM pgvigil.dbadash_move_ids mi
    JOIN pgvigil.dbadash_moves m ON m.instance_id = mi.instance_id
    JOIN pgvigil.instances i ON i.instance_id = m.instance_id
   WHERE mi.repository = p->>'repository' AND mi.dbadash_id = (p->>'dbadash_id')::int;
  IF v_id IS NULL THEN
    -- an InstanceID not in a move whose name is a moved instance's (the server re-added in DBA Dash after the move):
    -- that move too, never the name path, which would change a moved instance
    SELECT m.instance_id, i.name, m.collect_from INTO v_id, v_name, v_from
      FROM pgvigil.instances i JOIN pgvigil.dbadash_moves m ON m.instance_id = i.instance_id
     WHERE i.name = p->>'name';
  END IF;
  IF v_id IS NOT NULL THEN
    FOREACH v_key IN ARRAY ARRAY['cpu', 'volumes', 'dbsize', 'jobruns'] LOOP
      v_why := pgvigil.dbadash_import_wait(v_id, v_key);
      IF v_why IS NOT NULL THEN
        v_wait := v_wait || jsonb_build_object(v_key, v_why);
      END IF;
    END LOOP;
    RETURN jsonb_build_object('instance_id', v_id, 'name', v_name, 'moved', true, 'collect_from', v_from, 'wait', v_wait);
  END IF;
  SELECT i.instance_id, i.engine INTO v_id, v_eng FROM pgvigil.instances i WHERE i.name = p->>'name';
  IF v_id IS NOT NULL AND v_eng <> 'sqlserver' THEN
    RETURN jsonb_build_object('name', p->>'name', 'moved', false, 'wait', v_wait,
      'skipped', format('pgvigil stores %s as a %s instance: give the SQL Server its own name (the import''s name map)', p->>'name', v_eng));
  END IF;
  RETURN jsonb_build_object('instance_id', v_id, 'name', p->>'name', 'moved', false, 'wait', v_wait);
END $$;
GRANT EXECUTE ON FUNCTION pgvigil.dbadash_import_target(jsonb) TO pgvigil_collector;

-- import_dbadash_instance: the run's dbadash_import_target, then the instance made when there is none (DBA Dash's
-- version, platform and tags: ensure_instance), or a page instance never read given DBA Dash's version and, when the
-- page left it 'auto', its platform (it is seen now: the fleet no longer says 'not read yet'). p as above plus
-- platform, version, version_num, tags (array). A moved server is never made or changed here: the collector reads it.
CREATE OR REPLACE FUNCTION pgvigil.import_dbadash_instance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_t jsonb := pgvigil.dbadash_import_target(p);
  v_id int;
  v_tags text[];
BEGIN
  IF (v_t->>'moved')::boolean OR v_t ? 'skipped' THEN
    RETURN v_t;
  END IF;
  v_id := (v_t->>'instance_id')::int;
  IF v_id IS NOT NULL THEN
    UPDATE pgvigil.instances i SET platform = CASE WHEN i.platform = 'auto' THEN coalesce(nullif(p->>'platform', ''), i.platform) ELSE i.platform END,
           server_version = nullif(p->>'version', ''), server_version_num = (p->>'version_num')::int, last_seen = now()
     WHERE i.instance_id = v_id AND i.server_version IS NULL
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_instance m WHERE m.instance_id = i.instance_id);
    RETURN v_t || jsonb_build_object('never_read', FOUND);
  END IF;
  IF jsonb_typeof(p->'tags') = 'array' THEN
    SELECT coalesce(array_agg(t ORDER BY t), '{}') INTO v_tags FROM jsonb_array_elements_text(p->'tags') t;
  END IF;
  v_id := pgvigil.ensure_instance(p->>'name', coalesce(nullif(p->>'platform', ''), 'sqlserver'), nullif(p->>'version', ''),
                                  (p->>'version_num')::int, false, coalesce(v_tags, '{}'), 'sqlserver');
  RETURN v_t || jsonb_build_object('instance_id', v_id, 'added', true);
END $$;

-- import_dbadash_move: the page's writes, each audited (refused ones too). p_payload: ui_user, client, op and:
--   add     repository, server (DBA Dash's Instance), dbadash_ids (array: every InstanceID of the server; their
--           ConnectionIDs, for 204's proposals, are read from dbadash_instances), and import_admin_instance's add keys (name, platform,
--           dsn_ref, auth, host, port, dbname, login, options, tags, file_names). Refused, with no row written, when
--           the server is moved already, pgvigil collects it already (an active instance read under that @@SERVERNAME),
--           Admin > Instances holds its host and port, or a DBA Dash source of this repository has it approved; then
--           import_admin_instance's add, the move rows, and a proposal of this repository still 'proposed' marked
--           approved under the instance's name - one transaction.
--   count   name, counts (the dry run's: {mapping: n, ..., "to": <bound>})
--   run     name: the import's start, refused while another run of it is marked (its beat within 15 minutes) or
--           before the collector's first read; answers run_id
--   beat    name, run_id, imported (so far): the run goes on (refused for a run taken over: another run_id)
--   ended   name, run_id, outcome (ok | partial | failed), imported, detail
--   tick    name, step, done (the checklist; the DBA's record)
-- One server's adds, and one move's ops, are one at a time (an advisory lock; the move row FOR UPDATE).
-- Answers {outcome, detail, generation (add), run_id (run)}.
CREATE OR REPLACE FUNCTION pgvigil.import_dbadash_move(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli   text := p_payload->>'client';
  v_repo  text := btrim(coalesce(p_payload->>'repository', ''));
  v_srv   text := btrim(coalesce(p_payload->>'server', ''));
  v_name  text := btrim(coalesce(p_payload->>'name', ''));
  v_ids   int[];
  v_conns text[];
  v_m     pgvigil.dbadash_moves%ROWTYPE;
  v_why   text;
  v_hit   text;
  v_res   jsonb;
  v_id    int;
  v_n     int;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_dbadash_move: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('add', 'count', 'run', 'beat', 'ended', 'tick') THEN
    v_why := 'op must be add, count, run, beat, ended or tick';
  ELSIF v_op = 'add' THEN
    PERFORM pg_advisory_xact_lock(hashtext('pgvigil.dbadash_move:' || v_repo || ':' || upper(v_srv)));
    IF jsonb_typeof(p_payload->'dbadash_ids') = 'array'
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements_text(p_payload->'dbadash_ids') x
                        WHERE CASE WHEN x ~ '^[0-9]{1,10}$' THEN x::bigint NOT BETWEEN 1 AND 2147483647 ELSE true END) THEN
      SELECT array_agg(DISTINCT x::int) INTO v_ids FROM jsonb_array_elements_text(p_payload->'dbadash_ids') x;
    END IF;
    SELECT array_agg(DISTINCT d.connection_id) FILTER (WHERE d.connection_id IS NOT NULL) INTO v_conns
      FROM pgvigil.dbadash_instances d WHERE d.repository = v_repo AND d.instance_id = ANY (coalesce(v_ids, '{}'));
    IF NOT EXISTS (SELECT 1 FROM pgvigil.dbadash_repositories r WHERE r.repository = v_repo AND r.is_configured) THEN
      v_why := format('no DBA Dash repository %s in this server''s configuration', v_repo);
    ELSIF v_srv = '' OR v_ids IS NULL THEN
      v_why := 'a move names the server and its DBA Dash InstanceIDs (each 1 to 2147483647)';
    ELSIF EXISTS (SELECT 1 FROM pgvigil.instances i JOIN pgvigil.dbadash_moves m ON m.instance_id = i.instance_id WHERE i.name = v_name) THEN
      v_why := format('%s holds a move already (of %s)', v_name,
                      (SELECT m.server FROM pgvigil.instances i JOIN pgvigil.dbadash_moves m ON m.instance_id = i.instance_id WHERE i.name = v_name));
    ELSIF EXISTS (SELECT 1 FROM unnest(v_ids) x WHERE NOT EXISTS (SELECT 1 FROM pgvigil.dbadash_instances d
                    WHERE d.repository = v_repo AND d.instance_id = x AND upper(d.instance) = upper(v_srv))) THEN
      v_why := format('an InstanceID given is not %s in repository %s', v_srv, v_repo);
    ELSE
      SELECT i.name INTO v_hit FROM pgvigil.dbadash_moves m JOIN pgvigil.instances i ON i.instance_id = m.instance_id
       WHERE m.repository = v_repo AND upper(m.server) = upper(v_srv);
      IF v_hit IS NOT NULL THEN
        v_why := format('%s was moved already, as %s', v_srv, v_hit);
      END IF;
      IF v_why IS NULL THEN
        SELECT i.name INTO v_hit FROM pgvigil.dbadash_move_ids mi JOIN pgvigil.instances i ON i.instance_id = mi.instance_id
         WHERE mi.repository = v_repo AND mi.dbadash_id = ANY (v_ids) LIMIT 1;
        IF v_hit IS NOT NULL THEN
          v_why := format('an InstanceID of %s was moved already, as %s', v_srv, v_hit);
        END IF;
      END IF;
      IF v_why IS NULL THEN
        SELECT i.name INTO v_hit FROM pgvigil.instances i JOIN pgvigil.mssql_instance m ON m.instance_id = i.instance_id
         WHERE i.engine = 'sqlserver' AND i.is_active AND upper(m.server_name) = upper(v_srv) ORDER BY i.instance_id LIMIT 1;
        IF v_hit IS NOT NULL THEN
          v_why := format('pgvigil collects %s already, as %s', v_srv, v_hit);
        END IF;
      END IF;
      IF v_why IS NULL THEN
        SELECT a.name INTO v_hit FROM pgvigil.admin_instances a
         WHERE a.engine = 'sqlserver' AND lower(a.host) = lower(btrim(coalesce(p_payload->>'host', '')))
           AND coalesce(a.port, 1433) = coalesce(CASE WHEN p_payload->>'port' ~ '^[0-9]{1,5}$' THEN (p_payload->>'port')::int END, 1433)
         ORDER BY a.name LIMIT 1;
        IF v_hit IS NOT NULL THEN
          v_why := format('Admin > Instances has %s already, as %s', btrim(p_payload->>'host') || coalesce(',' || nullif(p_payload->>'port', ''), ''), v_hit);
        END IF;
      END IF;
      IF v_why IS NULL THEN
        SELECT p.source || ' as ' || coalesce(p.instance_name, '?') INTO v_hit FROM pgvigil.admin_proposals p
          JOIN pgvigil.admin_sources s ON s.name = p.source AND s.kind = 'dbadash' AND s.ref = v_repo
         WHERE p.state = 'approved' AND p.server = ANY (coalesce(v_conns, '{}')) ORDER BY p.proposal_id LIMIT 1;
        IF v_hit IS NOT NULL THEN
          v_why := format('%s is approved already from the source %s', v_srv, v_hit);
        END IF;
      END IF;
    END IF;
  ELSE
    SELECT m.* INTO v_m FROM pgvigil.dbadash_moves m JOIN pgvigil.instances i ON i.instance_id = m.instance_id WHERE i.name = v_name
       FOR UPDATE OF m;
    IF v_m.instance_id IS NULL THEN
      v_why := format('%s is not a server moved from DBA Dash', v_name);
    ELSIF v_op = 'run' AND v_m.collect_from IS NULL THEN
      v_why := pgvigil.dbadash_import_wait(v_m.instance_id, 'run');
    ELSIF v_op = 'run' AND v_m.run_started IS NOT NULL AND v_m.run_ended IS NULL AND v_m.run_beat > p_at - interval '15 minutes' THEN
      v_why := format('an import of %s runs already: started by %s at %s', v_name, v_m.run_by,
                      to_char(v_m.run_started AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC');
    ELSIF v_op IN ('beat', 'ended') AND (v_m.run_started IS NULL OR v_m.run_ended IS NOT NULL) THEN
      v_why := format('no import of %s is running', v_name);
    ELSIF v_op IN ('beat', 'ended') AND coalesce(p_payload->>'run_id', '') IS DISTINCT FROM v_m.run_id::text THEN
      v_why := format('run %s of %s was taken over: run %s is the current one', coalesce(p_payload->>'run_id', '?'), v_name, v_m.run_id);
    ELSIF v_op = 'ended' AND coalesce(p_payload->>'outcome', '') NOT IN ('ok', 'partial', 'failed') THEN
      v_why := 'outcome is ok, partial or failed';
    ELSIF v_op = 'tick' AND coalesce(p_payload->>'step', '') !~ '^[a-z_]{1,40}$' THEN
      v_why := 'a checklist step is a word of lower-case letters and _';
    ELSIF v_op = 'count' AND jsonb_typeof(p_payload->'counts') IS DISTINCT FROM 'object' THEN
      v_why := 'counts is an object';
    END IF;
  END IF;

  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'dbadash move ' || coalesce(v_op, '?'), coalesce(nullif(v_name, ''), v_srv), 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;

  IF v_op = 'add' THEN
    v_res := pgvigil.import_admin_instance(p_at, (p_payload - 'repository' - 'server' - 'dbadash_ids' - 'connection_ids')
                                                 || jsonb_build_object('op', 'add', 'engine', 'sqlserver', 'source', 'dbadash:' || v_repo));
    IF v_res->>'outcome' <> 'done' THEN
      RETURN v_res;   -- refused and audited by import_admin_instance; no move row
    END IF;
    SELECT instance_id INTO v_id FROM pgvigil.instances WHERE name = v_name;
    INSERT INTO pgvigil.dbadash_moves (instance_id, repository, server, auth, added_at, added_by)
    VALUES (v_id, v_repo, v_srv, p_payload->>'auth', p_at, v_user);
    INSERT INTO pgvigil.dbadash_move_ids (repository, dbadash_id, instance_id) SELECT v_repo, x, v_id FROM unnest(v_ids) x;
    UPDATE pgvigil.admin_proposals p SET state = 'approved', instance_name = v_name, decided_at = p_at, decided_by = v_user
      FROM pgvigil.admin_sources s
     WHERE s.name = p.source AND s.kind = 'dbadash' AND s.ref = v_repo AND p.state = 'proposed' AND p.server = ANY (coalesce(v_conns, '{}'));
    GET DIAGNOSTICS v_n = ROW_COUNT;
    PERFORM pgvigil.admin_log(v_user, v_cli, 'dbadash move add', v_name, 'done',
      format('%s of DBA Dash repository %s (InstanceID %s) as %s, sign-in %s%s', v_srv, v_repo, array_to_string(v_ids, ', '), v_name,
             p_payload->>'auth', CASE WHEN v_n > 0 THEN format('; %s proposal(s) of the repository approved', v_n) ELSE '' END));
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'moved ' || v_srv || ' as ' || v_name, 'generation', v_res->'generation');
  ELSIF v_op = 'count' THEN
    UPDATE pgvigil.dbadash_moves SET counted_at = p_at, counted_by = v_user, counts = p_payload->'counts' WHERE instance_id = v_m.instance_id;
  ELSIF v_op = 'run' THEN
    UPDATE pgvigil.dbadash_moves SET run_id = run_id + 1, run_by = v_user, run_started = p_at, run_beat = p_at, run_ended = NULL, run_outcome = NULL
     WHERE instance_id = v_m.instance_id;
  ELSIF v_op = 'beat' THEN
    UPDATE pgvigil.dbadash_moves SET run_beat = p_at, imported = coalesce(p_payload->'imported', imported) WHERE instance_id = v_m.instance_id;
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'beat ' || v_name);   -- progress, not a step: not audited
  ELSIF v_op = 'ended' THEN
    UPDATE pgvigil.dbadash_moves SET run_ended = p_at, run_beat = p_at, run_outcome = p_payload->>'outcome',
           imported = coalesce(p_payload->'imported', imported),
           imported_at = CASE WHEN p_payload->>'outcome' = 'ok' THEN p_at ELSE imported_at END
     WHERE instance_id = v_m.instance_id;
  ELSIF v_op = 'tick' THEN
    UPDATE pgvigil.dbadash_moves
       SET ticks = ticks || jsonb_build_object(p_payload->>'step', jsonb_build_object('done', coalesce((p_payload->>'done')::boolean, true), 'at', p_at, 'by', v_user))
     WHERE instance_id = v_m.instance_id;
  END IF;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'dbadash move ' || v_op, v_name, 'done',
    CASE v_op WHEN 'count' THEN 'counted: ' || (p_payload->'counts')::text
              WHEN 'run' THEN format('history import run %s started', v_m.run_id + 1)
              WHEN 'ended' THEN format('history import %s: %s%s', p_payload->>'outcome', coalesce((p_payload->'imported')::text, '{}'),
                                       coalesce('; ' || nullif(p_payload->>'detail', ''), ''))
              WHEN 'tick' THEN format('%s %s', p_payload->>'step', CASE WHEN coalesce((p_payload->>'done')::boolean, true) THEN 'done' ELSE 'not done' END)
    END);
  RETURN jsonb_build_object('outcome', 'done', 'detail', v_op || ' ' || v_name)
         || CASE WHEN v_op = 'run' THEN jsonb_build_object('run_id', v_m.run_id + 1) ELSE '{}' END;
END $$;

-- DBA Dash's own Extended Events sessions on a server (DBADash_%), as the collector's XE read saw them (task 206, W8):
-- the move's checklist lists them, each with the DROP EVENT SESSION line for the server's DBA (pgvigil reads none of
-- their events and drops none). A read that listed the sessions replaces the instance's list whole (an older read
-- arriving late replaces nothing); a read that failed before the list leaves the last one. mssql_xe_foreign_read keeps
-- when the list was last read, also when it held none.
CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_foreign (
  instance_id  int NOT NULL REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  name         text NOT NULL,
  running      boolean NOT NULL,
  targets      text[] NOT NULL DEFAULT '{}',
  read_at      timestamptz NOT NULL,
  PRIMARY KEY (instance_id, name)
);
CREATE TABLE IF NOT EXISTS pgvigil.mssql_xe_foreign_read (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances (instance_id) ON DELETE CASCADE,
  read_at      timestamptz NOT NULL,
  sessions     int NOT NULL
);

-- The importer: 0116's wrapper renamed import_mssql_xe_w0116 and called first (renamed once: a rerun finds it), then
-- the list of DBA Dash's sessions this read carries ('foreign_session' rows, the 'sessions_read' marker)
DO $$
BEGIN
  IF to_regprocedure('pgvigil.import_mssql_xe_w0116(integer, timestamp with time zone, jsonb)') IS NULL THEN
    ALTER FUNCTION pgvigil.import_mssql_xe(int, timestamptz, jsonb) RENAME TO import_mssql_xe_w0116;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_xe(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_n int;
BEGIN
  PERFORM pgvigil.import_mssql_xe_w0116(p_instance_id, p_snapshot_at, p_payload);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'sessions_read') THEN
    RETURN;
  END IF;
  -- the instance's row first (its lock orders two reads of one instance); an older read arriving late changes nothing
  INSERT INTO pgvigil.mssql_xe_foreign_read AS f (instance_id, read_at, sessions) VALUES (p_instance_id, p_snapshot_at, 0)
  ON CONFLICT (instance_id) DO UPDATE SET read_at = EXCLUDED.read_at WHERE f.read_at <= EXCLUDED.read_at;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  IF v_n = 0 THEN
    RETURN;
  END IF;
  DELETE FROM pgvigil.mssql_xe_foreign WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_xe_foreign (instance_id, name, running, targets, read_at)
  SELECT DISTINCT ON (left(r->>'name', 128)) p_instance_id, left(r->>'name', 128), coalesce((r->>'running')::boolean, false),
         coalesce(ARRAY(SELECT left(x, 60) FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(r->'targets') = 'array' THEN r->'targets' ELSE '[]' END) x), '{}'),
         p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'foreign_session' AND coalesce(r->>'name', '') <> '' AND upper(r->>'name') LIKE 'DBADASH\_%'
   ORDER BY left(r->>'name', 128);
  GET DIAGNOSTICS v_n = ROW_COUNT;
  UPDATE pgvigil.mssql_xe_foreign_read SET sessions = v_n WHERE instance_id = p_instance_id;
END $$;

-- dbadash_move_list: the page's list for one repository (W2): one row per server - DBA Dash's present instances
-- grouped by their Instance (@@SERVERNAME), so a server DBA Dash lists twice is one move - with its InstanceIDs,
-- ConnectionIDs and display names, the move if there is one (its instance, sign-in, collect_from, the collector's first
-- CPU / job reads, the dry run's counts, the run, the checklist), the instance pgvigil collects it as without a move,
-- the instance an import made of it, and the state:
--   'not yet'               neither collected nor imported by pgvigil
--   'imported only'         pgvigil import dbadash made an instance under its display name, pgvigil does not collect it
--   'collected by pgvigil'  an active instance read under that @@SERVERNAME, not moved here
--   'moving'                moved, pgvigil has not read it yet (no collect_from)
--   'collecting'            moved and read, its history not imported (or not yet ended ok)
--   'importing'             a history import runs now (its beat within 15 minutes)
--   'partial' / 'import failed'  the last import's outcome
--   'ready to switch'       collecting and its history imported (a run that ended ok)
--   'disabled'              moved, then disabled on Admin > Instances
CREATE OR REPLACE FUNCTION pgvigil.dbadash_move_list(p_repository text)
RETURNS TABLE (server text, dbadash_ids int[], connection_ids text[], display_names text[], last_collection timestamptz,
               state text, instance_id int, instance_name text, auth text, added_at timestamptz, added_by text,
               collect_from timestamptz, cpu_read_at timestamptz, jobs_read_at timestamptz,
               counted_at timestamptz, counted_by text, counts jsonb,
               run_id bigint, run_by text, run_started timestamptz, run_beat timestamptz, run_ended timestamptz, run_outcome text,
               imported jsonb, imported_at timestamptz, ticks jsonb,
               collected_as text, imported_as text)
LANGUAGE sql STABLE AS $$
  WITH g AS (
    SELECT min(d.instance) AS server, upper(d.instance) AS key,
           array_agg(d.instance_id ORDER BY d.instance_id) AS ids,
           array_agg(DISTINCT d.connection_id) FILTER (WHERE d.connection_id IS NOT NULL) AS conns,
           array_agg(DISTINCT d.display_name) AS names, max(d.last_collection) AS last_collection
      FROM pgvigil.dbadash_instances d
     WHERE d.repository = p_repository AND d.is_present
     GROUP BY upper(d.instance))
  SELECT g.server, g.ids, coalesce(g.conns, '{}'), g.names, g.last_collection,
         CASE
           WHEN m.instance_id IS NOT NULL AND NOT i.is_active THEN 'disabled'
           WHEN m.instance_id IS NOT NULL AND m.collect_from IS NULL THEN 'moving'
           WHEN m.instance_id IS NOT NULL AND m.run_started IS NOT NULL AND m.run_ended IS NULL AND m.run_beat > now() - interval '15 minutes' THEN 'importing'
           WHEN m.instance_id IS NOT NULL AND m.imported_at IS NOT NULL THEN 'ready to switch'
           WHEN m.instance_id IS NOT NULL AND m.run_outcome = 'partial' THEN 'partial'
           WHEN m.instance_id IS NOT NULL AND m.run_outcome = 'failed' THEN 'import failed'
           WHEN m.instance_id IS NOT NULL THEN 'collecting'
           WHEN c.name IS NOT NULL THEN 'collected by pgvigil'
           WHEN imp.name IS NOT NULL THEN 'imported only'
           ELSE 'not yet'
         END,
         m.instance_id, i.name, m.auth, m.added_at, m.added_by, m.collect_from, m.cpu_read_at, m.jobs_read_at,
         m.counted_at, m.counted_by, m.counts, m.run_id, m.run_by, m.run_started, m.run_beat, m.run_ended, m.run_outcome,
         m.imported, m.imported_at, m.ticks, c.name, imp.name
    FROM g
    LEFT JOIN pgvigil.dbadash_moves m ON m.repository = p_repository AND upper(m.server) = g.key
    LEFT JOIN pgvigil.instances i ON i.instance_id = m.instance_id
    LEFT JOIN LATERAL (SELECT ci.name FROM pgvigil.instances ci JOIN pgvigil.mssql_instance mi ON mi.instance_id = ci.instance_id
                        WHERE ci.engine = 'sqlserver' AND ci.is_active AND upper(mi.server_name) = g.key
                        ORDER BY ci.instance_id LIMIT 1) c ON true
    -- the door's imported match (sqlDBADashImported): an active SQL Server instance under a display name, never read
    LEFT JOIN LATERAL (SELECT ii.name FROM pgvigil.instances ii
                        WHERE ii.engine = 'sqlserver' AND ii.is_active AND upper(ii.name) = ANY (SELECT upper(n) FROM unnest(g.names) n)
                          AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_instance x WHERE x.instance_id = ii.instance_id)
                        ORDER BY ii.instance_id LIMIT 1) imp ON true
   ORDER BY g.server
$$;
