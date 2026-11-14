-- 0147: the restore chain of a SQL Server database (task 304): the backup sets a restore needs, read from each server's
-- msdb by the collection mssql_restore_chain (internal/mssql/restore_chain.go), and the chain the repository decides from
-- them - one rule for a standalone server and for an availability group whose replicas each hold part of the log.
--   mssql_restore_sets    per instance and backup set (by backup_set_uuid): the start-set candidates and the logs since the
--                         start set, upserted by each read and pruned below it (never rewritten whole)
--   mssql_restore_files   every media family and mirror of a set
--   mssql_restore_reads   per instance and database: the read's time, the logs since its start set, how many it sent, and the
--                         server's own gap count (a standalone database's: a group's replicas fill each other's gaps)
-- pgvigil never takes or restores a backup: nothing here writes a statement for one.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_restore_sets (
  instance_id              int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  backup_set_uuid          text NOT NULL,
  database_name            text NOT NULL,
  backup_set_id            bigint NOT NULL,
  set_type                 text NOT NULL,     -- msdb's type: D full, I differential, L log
  role                     text NOT NULL CHECK (role IN ('full', 'copy_full', 'diff', 'log')),
  sink                     text NOT NULL,     -- 'backup' or 'nul' (the NUL device: nothing was kept)
  is_copy_only             boolean,
  media_position           int,       -- the set's place on its media (FILE = n)
  is_snapshot              boolean,
  has_bulk_logged_data     boolean,
  is_damaged               boolean,
  begins_log_chain         boolean,
  first_lsn                numeric(25,0),
  last_lsn                 numeric(25,0),
  checkpoint_lsn           numeric(25,0),
  database_backup_lsn      numeric(25,0),
  differential_base_lsn    numeric(25,0),
  differential_base_guid   text,
  fork_point_lsn           numeric(25,0),
  database_guid            text,
  family_guid              text,
  first_recovery_fork_guid text,
  last_recovery_fork_guid  text,
  recovery_model           text,
  user_name                text,
  size_bytes               bigint,
  compressed_bytes         bigint,
  start_at                 timestamptz,
  finish_at                timestamptz,
  last_valid_restore_at    timestamptz,
  software_name            text,
  family_count             int,
  mirror_count             int,
  db_created_at            timestamptz,
  seen_at                  timestamptz NOT NULL,   -- the read that last listed it
  PRIMARY KEY (instance_id, backup_set_uuid)
);
CREATE INDEX IF NOT EXISTS mssql_restore_sets_db_idx ON pgvigil.mssql_restore_sets (database_name, last_lsn);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_restore_files (
  instance_id      int NOT NULL,
  backup_set_uuid  text NOT NULL,
  family           int NOT NULL,
  mirror           int NOT NULL,
  device_kind      text,
  path             text NOT NULL,
  PRIMARY KEY (instance_id, backup_set_uuid, family, mirror),
  FOREIGN KEY (instance_id, backup_set_uuid) REFERENCES pgvigil.mssql_restore_sets (instance_id, backup_set_uuid) ON DELETE CASCADE
);

-- the verdict of each database's chain, decided at each import (for the instance read and for the other members of the
-- database's group, whose verdict the new sets may change): the page and the findings read it without walking the chain
CREATE TABLE IF NOT EXISTS pgvigil.mssql_restore_verdicts (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  verdict        text NOT NULL,
  restorable_to  timestamptz,
  steps          int,
  state          text NOT NULL CHECK (state IN ('whole', 'broken', 'held', 'no full', 'none')),
  decided_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name)
);

-- the steps of each chain as mssql_restore_chain decided them at the import (serve's pool is read only: the chain, which
-- works through a temp table, is walked where the repository is written, never by a page)
CREATE TABLE IF NOT EXISTS pgvigil.mssql_restore_steps (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name   text NOT NULL,
  step            int NOT NULL,
  role            text,
  backup_set_uuid text,
  from_instance   text,
  start_at        timestamptz,
  finish_at       timestamptz,
  first_lsn       text,
  last_lsn        text,
  family_count    int,
  mirror_count    int,
  media_position  int,
  user_name       text,
  marks           text,
  restorable_to   timestamptz,
  PRIMARY KEY (instance_id, database_name, step)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_restore_reads (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  read_at        timestamptz NOT NULL,
  logs_since     int,          -- the log backups since the start set this server holds
  logs_sent      int,          -- the ones the read sent (at most the collector's keep)
  server_gaps    int,          -- the server's own count of gaps among them (a standalone database's verdict reads it)
  PRIMARY KEY (instance_id, database_name)
);

-- payload: 'database' rows (the databases the server lists), 'set' rows (role full / copy_full / diff / log, sink backup
-- or nul), 'file' rows by backup_set_id, one 'read' row. 0066's two rules: a set only of a database the read lists and
-- only when it finished after the database was created (an hour of slack); a database created anew under its name loses
-- the sets stored for the old one; a database no longer listed loses its sets. Per database the read's sets are upserted
-- by backup_set_uuid; a log this read did not send is kept when it lies inside the range the read covers (above the
-- lowest last_lsn it sent: a set of another read's overlap), pruned below it; a candidate this read did not send goes.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_restore_chain(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := pgvigil.mssql_rows(p_payload);
  v_dbs int;
BEGIN
  v_dbs := (SELECT count(*)::int FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'database');
  IF NOT pgvigil.mssql_hadr_read(p_instance_id, 'mssql_restore_chain', p_snapshot_at, v_dbs) THEN
    RETURN;
  END IF;
  CREATE TEMP TABLE IF NOT EXISTS pgv_rc_db (database_name text PRIMARY KEY, created_at timestamptz) ON COMMIT DROP;
  TRUNCATE pgv_rc_db;
  INSERT INTO pgv_rc_db SELECT DISTINCT ON (r->>'database_name') r->>'database_name', (r->>'created_utc')::timestamptz
    FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'database' AND r->>'database_name' IS NOT NULL;
  IF v_dbs > 0 THEN
    DELETE FROM pgvigil.mssql_restore_sets s
     WHERE s.instance_id = p_instance_id
       AND (NOT EXISTS (SELECT 1 FROM pgv_rc_db d WHERE d.database_name = s.database_name)
            OR EXISTS (SELECT 1 FROM pgv_rc_db d WHERE d.database_name = s.database_name AND pgvigil.mssql_recreated(s.db_created_at, d.created_at)));
    DELETE FROM pgvigil.mssql_restore_reads x
     WHERE x.instance_id = p_instance_id AND NOT EXISTS (SELECT 1 FROM pgv_rc_db d WHERE d.database_name = x.database_name);
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pgv_rc_set (r jsonb, database_name text, uuid text, role text, last_lsn numeric) ON COMMIT DROP;
  TRUNCATE pgv_rc_set;
  INSERT INTO pgv_rc_set
  SELECT r, r->>'database_name', lower(r->>'backup_set_uuid'), r->>'role', (r->>'last_lsn')::numeric
    FROM jsonb_array_elements(v_rows) r
    JOIN pgv_rc_db d ON d.database_name = r->>'database_name'
   WHERE r->>'kind' = 'set' AND r->>'backup_set_uuid' IS NOT NULL AND r->>'role' IN ('full', 'copy_full', 'diff', 'log')
     AND (d.created_at IS NULL OR (r->>'finish_utc')::timestamptz >= d.created_at - interval '1 hour');

  -- what this read no longer lists: a candidate goes; a log goes when it lies below the lowest log the read sent for
  -- its database (the range moved on), or when the read sent no log of the database at all
  DELETE FROM pgvigil.mssql_restore_sets s
   WHERE s.instance_id = p_instance_id AND EXISTS (SELECT 1 FROM pgv_rc_db d WHERE d.database_name = s.database_name)
     AND NOT EXISTS (SELECT 1 FROM pgv_rc_set x WHERE x.uuid = s.backup_set_uuid)
     AND (s.role <> 'log'
          OR s.last_lsn < coalesce((SELECT min(x.last_lsn) FROM pgv_rc_set x WHERE x.database_name = s.database_name AND x.role = 'log'), 'infinity'::numeric));

  INSERT INTO pgvigil.mssql_restore_sets AS t (instance_id, backup_set_uuid, database_name, backup_set_id, set_type, role, sink,
      is_copy_only, media_position, is_snapshot, has_bulk_logged_data, is_damaged, begins_log_chain, first_lsn, last_lsn, checkpoint_lsn,
      database_backup_lsn, differential_base_lsn, differential_base_guid, fork_point_lsn, database_guid, family_guid,
      first_recovery_fork_guid, last_recovery_fork_guid, recovery_model, user_name, size_bytes, compressed_bytes, start_at,
      finish_at, last_valid_restore_at, software_name, family_count, mirror_count, db_created_at, seen_at)
  SELECT p_instance_id, x.uuid, x.database_name, (x.r->>'backup_set_id')::bigint, x.r->>'set_type', x.role, coalesce(x.r->>'sink', 'backup'),
         (x.r->>'is_copy_only')::int = 1, (x.r->>'position')::int, (x.r->>'is_snapshot')::int = 1, (x.r->>'has_bulk_logged_data')::int = 1,
         (x.r->>'is_damaged')::int = 1, (x.r->>'begins_log_chain')::int = 1, (x.r->>'first_lsn')::numeric, x.last_lsn,
         (x.r->>'checkpoint_lsn')::numeric, (x.r->>'database_backup_lsn')::numeric, (x.r->>'differential_base_lsn')::numeric,
         lower(x.r->>'differential_base_guid'), (x.r->>'fork_point_lsn')::numeric, lower(x.r->>'database_guid'), lower(x.r->>'family_guid'),
         lower(x.r->>'first_recovery_fork_guid'), lower(x.r->>'last_recovery_fork_guid'), x.r->>'recovery_model', x.r->>'user_name',
         (x.r->>'size_bytes')::bigint, (x.r->>'compressed_bytes')::bigint, (x.r->>'start_utc')::timestamptz, (x.r->>'finish_utc')::timestamptz,
         (x.r->>'last_valid_restore_utc')::timestamptz, x.r->>'software_name', (x.r->>'family_count')::int, (x.r->>'mirror_count')::int,
         d.created_at, p_snapshot_at
    FROM pgv_rc_set x JOIN pgv_rc_db d ON d.database_name = x.database_name
  ON CONFLICT (instance_id, backup_set_uuid) DO UPDATE SET
      backup_set_id = EXCLUDED.backup_set_id, role = EXCLUDED.role, sink = EXCLUDED.sink, is_damaged = EXCLUDED.is_damaged,
      last_valid_restore_at = EXCLUDED.last_valid_restore_at, seen_at = EXCLUDED.seen_at, db_created_at = EXCLUDED.db_created_at;

  DELETE FROM pgvigil.mssql_restore_files f USING pgv_rc_set x
   WHERE f.instance_id = p_instance_id AND f.backup_set_uuid = x.uuid;
  INSERT INTO pgvigil.mssql_restore_files (instance_id, backup_set_uuid, family, mirror, device_kind, path)
  SELECT p_instance_id, x.uuid, (f->>'family')::int, (f->>'mirror')::int, f->>'device_kind', f->>'path'
    FROM pgv_rc_set x
    JOIN jsonb_array_elements(v_rows) f ON f->>'kind' = 'file' AND (f->>'backup_set_id')::bigint = (x.r->>'backup_set_id')::bigint AND f->>'path' IS NOT NULL
  ON CONFLICT DO NOTHING;

  INSERT INTO pgvigil.mssql_restore_reads AS t (instance_id, database_name, read_at, logs_since, logs_sent, server_gaps)
  SELECT p_instance_id, d.database_name, p_snapshot_at,
         max((x.r->>'logs_since')::int) FILTER (WHERE x.role = 'log'), count(*) FILTER (WHERE x.role = 'log')::int,
         max((x.r->>'gaps')::int) FILTER (WHERE x.role = 'log')
    FROM pgv_rc_db d LEFT JOIN pgv_rc_set x ON x.database_name = d.database_name
   GROUP BY d.database_name
  ON CONFLICT (instance_id, database_name) DO UPDATE SET read_at = EXCLUDED.read_at, logs_since = EXCLUDED.logs_since,
      logs_sent = EXCLUDED.logs_sent, server_gaps = EXCLUDED.server_gaps;
  PERFORM pgvigil.mssql_restore_decide(p_instance_id, p_snapshot_at);
END $$;

-- mssql_restore_members: the instances whose sets make one database's chain - the instance itself and, for a database
-- of an availability group, every active instance that lists it under the same group (0066's merge key).
CREATE OR REPLACE FUNCTION pgvigil.mssql_restore_members(p_instance_id int, p_database text)
RETURNS TABLE (instance_id int, instance text, read_at timestamptz) LANGUAGE sql STABLE AS $$
  SELECT i.instance_id, i.name, r.read_at
    FROM pgvigil.instances i
    LEFT JOIN pgvigil.mssql_restore_reads r ON r.instance_id = i.instance_id AND r.database_name = p_database
   WHERE i.is_active AND (i.instance_id = p_instance_id
          OR i.instance_id IN (SELECT x.instance_id FROM pgvigil.mssql_backup_state x JOIN pgvigil.mssql_backup_state me
                                 ON me.instance_id = p_instance_id AND me.database_name = p_database AND me.ag_group_id IS NOT NULL
                                WHERE x.ag_group_id = me.ag_group_id AND x.database_name = p_database AND x.is_present))
$$;

-- mssql_restore_chain: the steps a restore of the database takes, in order, with pgvigil's marks (task 304's fold):
--   the sets of the members (a set once by backup_set_uuid), of the recovery fork of the newest set; a set of the parent
--   fork counts when it ends at or before the fork point (F2);
--   the START SET = the greatest last_lsn among (the newest full that is not copy-only, or its differential when that
--   follows it: differential_base_guid = the full's backup_set_uuid, else dbatools' LSN test) and (the newest copy-only
--   full) - a copy-only full restores like any full (F1);
--   the logs by LSN only (a copy-only log is listed, never a step; a database_backup_lsn other than the start's
--   checkpoint is a mark, never a filter), walked from the start's last_lsn: a log ending at or before it 'not needed', a
--   log to NUL a hole, a first_lsn past the LSN reached a BREAK - unless a member's read is older than the finish of the
--   set after the gap: then 'not yet read from <instance> (last read <t>)' (F3).
-- step 0 is the verdict row (its role 'verdict', its marks the words).
CREATE OR REPLACE FUNCTION pgvigil.mssql_restore_chain(p_instance_id int, p_database text)
RETURNS TABLE (step int, role text, backup_set_uuid text, from_instance text, start_at timestamptz, finish_at timestamptz,
               first_lsn text, last_lsn text, family_count int, mirror_count int, media_position int, user_name text, marks text,
               restorable_to timestamptz)
LANGUAGE plpgsql VOLATILE AS $$   -- volatile: it fills a temp table of the members' sets
DECLARE
  v_fork text; v_fork_parent text; v_fork_point numeric;
  s record; st record; nf record; nd record; cf record;
  v_reached numeric; v_step int := 0; v_to timestamptz; v_broken text; v_held text; v_logs int := 0; v_model text;
  v_marks text;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS pgv_rcx (LIKE pgvigil.mssql_restore_sets) ON COMMIT DROP;
  ALTER TABLE pgv_rcx ADD COLUMN IF NOT EXISTS from_instance text;
  TRUNCATE pgv_rcx;
  INSERT INTO pgv_rcx
  SELECT DISTINCT ON (x.backup_set_uuid) x.*, m.instance
    FROM pgvigil.mssql_restore_sets x JOIN pgvigil.mssql_restore_members(p_instance_id, p_database) m ON m.instance_id = x.instance_id
   WHERE x.database_name = p_database
   ORDER BY x.backup_set_uuid, (x.instance_id = p_instance_id) DESC;
  -- each record shaped once (a SELECT INTO that finds no row leaves it NULL, never unassigned)
  SELECT * INTO nf FROM pgv_rcx WHERE false; nd := nf; cf := nf; st := nf;
  -- the newest set's fork; its parent where the fork changed inside the sets read (F2)
  SELECT x.last_recovery_fork_guid, x.recovery_model INTO v_fork, v_model FROM pgv_rcx x WHERE x.sink = 'backup' ORDER BY x.last_lsn DESC NULLS LAST LIMIT 1;
  IF v_fork IS NULL THEN
    RETURN QUERY SELECT 0, 'verdict', NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text, NULL::int, NULL::int, NULL::int, NULL::text,
                        'no backup of this database in the msdb history read'::text, NULL::timestamptz;
    RETURN;
  END IF;
  SELECT x.first_recovery_fork_guid, x.fork_point_lsn INTO v_fork_parent, v_fork_point FROM pgv_rcx x
   WHERE x.last_recovery_fork_guid = v_fork AND x.first_recovery_fork_guid IS DISTINCT FROM v_fork AND x.fork_point_lsn IS NOT NULL
   ORDER BY x.last_lsn LIMIT 1;
  DELETE FROM pgv_rcx x WHERE NOT (x.last_recovery_fork_guid = v_fork
                                   OR (v_fork_parent IS NOT NULL AND x.last_recovery_fork_guid = v_fork_parent AND x.last_lsn <= v_fork_point));
  SELECT * INTO nf FROM pgv_rcx x WHERE x.role = 'full' AND x.sink = 'backup' ORDER BY x.last_lsn DESC LIMIT 1;
  IF nf.backup_set_uuid IS NOT NULL THEN
    SELECT * INTO nd FROM pgv_rcx x WHERE x.role = 'diff' AND x.sink = 'backup' AND x.last_lsn > nf.last_lsn
       AND (x.differential_base_guid = nf.backup_set_uuid OR x.database_backup_lsn = nf.checkpoint_lsn)
     ORDER BY x.last_lsn DESC LIMIT 1;
  END IF;
  SELECT * INTO cf FROM pgv_rcx x WHERE x.role = 'copy_full' AND x.sink = 'backup' ORDER BY x.last_lsn DESC LIMIT 1;
  IF nf.backup_set_uuid IS NULL AND cf.backup_set_uuid IS NULL THEN
    RETURN QUERY SELECT 0, 'verdict', NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::text, NULL::text, NULL::int, NULL::int, NULL::int, NULL::text,
      CASE WHEN v_fork_parent IS NOT NULL OR EXISTS (SELECT 1 FROM pgvigil.mssql_restore_sets y WHERE y.database_name = p_database AND y.role IN ('full', 'copy_full')
                                                      AND y.instance_id IN (SELECT m.instance_id FROM pgvigil.mssql_restore_members(p_instance_id, p_database) m))
           THEN 'no full backup on the current recovery fork; the earlier full is on a previous fork - not judged'
           ELSE 'no full backup of this database in the msdb history read' END::text, NULL::timestamptz;
    RETURN;
  END IF;
  -- the start set: the greatest last_lsn among the two kinds (a differential stands for its full)
  IF cf.backup_set_uuid IS NOT NULL AND (nf.backup_set_uuid IS NULL OR cf.last_lsn > coalesce(nd.last_lsn, nf.last_lsn)) THEN
    st := cf;
  ELSE
    st := nf;
  END IF;
  -- the start: the full, then its differential when it is the start
  v_step := 1;
  RETURN QUERY SELECT v_step, st.role, st.backup_set_uuid, st.from_instance, st.start_at, st.finish_at, st.first_lsn::text, st.last_lsn::text,
                      st.family_count, st.mirror_count, st.media_position, st.user_name,
                      concat_ws('; ', CASE WHEN st.role = 'copy_full' THEN 'a copy-only full: no differential can follow it' END,
                                CASE WHEN st.is_damaged THEN 'damaged' END,
                                CASE WHEN st.is_snapshot THEN 'a snapshot backup: restored through its tool' END,
                                CASE WHEN st.media_position > 1 THEN 'file ' || st.media_position || ' of its media' END), NULL::timestamptz;
  v_reached := st.last_lsn; v_to := st.finish_at;
  IF st.role = 'full' AND nd.backup_set_uuid IS NOT NULL THEN
    v_step := v_step + 1;
    RETURN QUERY SELECT v_step, nd.role, nd.backup_set_uuid, nd.from_instance, nd.start_at, nd.finish_at, nd.first_lsn::text, nd.last_lsn::text,
                        nd.family_count, nd.mirror_count, nd.media_position, nd.user_name,
                        concat_ws('; ', CASE WHEN nd.is_damaged THEN 'damaged' END, CASE WHEN nd.media_position > 1 THEN 'file ' || nd.media_position || ' of its media' END), NULL::timestamptz;
    v_reached := nd.last_lsn; v_to := nd.finish_at;
  END IF;
  -- the logs
  FOR s IN SELECT * FROM pgv_rcx x WHERE x.role = 'log' AND x.last_lsn > st.first_lsn ORDER BY x.last_lsn, x.backup_set_id LOOP
    v_marks := NULL;
    IF s.is_copy_only THEN CONTINUE; END IF;   -- a copy-only log keeps the regular sequence untouched: never a step
    IF s.last_lsn <= v_reached THEN CONTINUE; END IF;   -- covered by the start set or an earlier log: not needed
    IF s.sink = 'nul' THEN
      v_broken := coalesce(v_broken, 'went to NUL at ' || to_char(s.finish_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: the log from LSN '
                  || s.first_lsn || ' to ' || s.last_lsn || ' was not kept');
      EXIT;
    END IF;
    IF s.first_lsn > v_reached THEN
      -- a gap: a BREAK only when every member read its msdb after this set finished (F3)
      SELECT string_agg(m.instance || ' (last read ' || coalesce(to_char(m.read_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never') || ')', ', ')
        INTO v_held FROM pgvigil.mssql_restore_members(p_instance_id, p_database) m WHERE m.read_at IS NULL OR m.read_at < s.finish_at;
      IF v_held IS NOT NULL THEN
        v_broken := 'not yet read from ' || v_held || ': the log from LSN ' || v_reached || ' to ' || s.first_lsn || ' may be there';
      ELSE
        v_broken := 'broken before the log of ' || to_char(s.finish_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: the log from LSN ' || v_reached
                    || ' to ' || s.first_lsn || ' is in no msdb read' || CASE WHEN s.begins_log_chain THEN ' (that log begins a new log chain)' ELSE '' END;
      END IF;
      EXIT;
    END IF;
    v_step := v_step + 1; v_logs := v_logs + 1;
    RETURN QUERY SELECT v_step, s.role, s.backup_set_uuid, s.from_instance, s.start_at, s.finish_at, s.first_lsn::text, s.last_lsn::text,
                        s.family_count, s.mirror_count, s.media_position, s.user_name,
                        concat_ws('; ', CASE WHEN s.database_backup_lsn IS DISTINCT FROM st.checkpoint_lsn AND st.role = 'full'
                                             THEN 'its full is another than the start set''s (database_backup_lsn ' || s.database_backup_lsn || ')' END,
                                  CASE WHEN s.has_bulk_logged_data THEN 'bulk-logged: no point in time inside it' END,
                                  CASE WHEN s.is_damaged THEN 'damaged' END,
                                  CASE WHEN s.media_position > 1 THEN 'file ' || s.media_position || ' of its media' END), NULL::timestamptz;
    v_reached := s.last_lsn; v_to := coalesce(s.last_valid_restore_at, s.finish_at);
  END LOOP;
  RETURN QUERY SELECT 0, 'verdict', NULL::text, NULL::text, NULL::timestamptz, NULL::timestamptz, NULL::text, v_reached::text, NULL::int, NULL::int, NULL::int, NULL::text,
    CASE WHEN v_broken IS NOT NULL THEN v_broken || '; restorable to ' || to_char(v_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
         WHEN v_model = 'SIMPLE' OR v_logs = 0 THEN 'restorable to the ' || CASE WHEN st.role = 'full' AND nd.backup_set_uuid IS NOT NULL THEN 'differential' ELSE 'full' END
              || ' of ' || to_char(v_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC only'
         ELSE 'restorable from these backups to ' || to_char(v_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC; later than that needs a tail-log backup' END,
    v_to;
END $$;

-- mssql_restore_decide: the verdicts of an instance's databases and of the same databases on the other members of their
-- groups, from mssql_restore_chain's verdict row.
CREATE OR REPLACE FUNCTION pgvigil.mssql_restore_decide(p_instance_id int, p_at timestamptz)
RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE
  t record; v record;
BEGIN
  DELETE FROM pgvigil.mssql_restore_verdicts x WHERE x.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_restore_reads r WHERE r.instance_id = x.instance_id AND r.database_name = x.database_name);
  DELETE FROM pgvigil.mssql_restore_steps x WHERE x.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_restore_reads r WHERE r.instance_id = x.instance_id AND r.database_name = x.database_name);
  FOR t IN SELECT DISTINCT m.instance_id, r.database_name
             FROM pgvigil.mssql_restore_reads r
             CROSS JOIN LATERAL pgvigil.mssql_restore_members(p_instance_id, r.database_name) m
            WHERE r.instance_id = p_instance_id
              AND EXISTS (SELECT 1 FROM pgvigil.mssql_restore_reads y WHERE y.instance_id = m.instance_id AND y.database_name = r.database_name) LOOP
    DELETE FROM pgvigil.mssql_restore_steps x WHERE x.instance_id = t.instance_id AND x.database_name = t.database_name;
    INSERT INTO pgvigil.mssql_restore_steps (instance_id, database_name, step, role, backup_set_uuid, from_instance, start_at, finish_at,
        first_lsn, last_lsn, family_count, mirror_count, media_position, user_name, marks, restorable_to)
    SELECT t.instance_id, t.database_name, c.* FROM pgvigil.mssql_restore_chain(t.instance_id, t.database_name) c;
    SELECT max(x.marks) FILTER (WHERE x.step = 0) AS marks, max(x.restorable_to) FILTER (WHERE x.step = 0) AS restorable_to,
           count(*) FILTER (WHERE x.step > 0)::int AS steps
      INTO v FROM pgvigil.mssql_restore_steps x WHERE x.instance_id = t.instance_id AND x.database_name = t.database_name;
    INSERT INTO pgvigil.mssql_restore_verdicts AS x (instance_id, database_name, verdict, restorable_to, steps, state, decided_at)
    VALUES (t.instance_id, t.database_name, v.marks, v.restorable_to, v.steps,
            CASE WHEN v.marks LIKE 'broken before%' OR v.marks LIKE 'went to NUL%' THEN 'broken'
                 WHEN v.marks LIKE 'not yet read from%' THEN 'held'
                 WHEN v.marks LIKE 'no full backup%' THEN 'no full'
                 WHEN v.marks LIKE 'restorable%' THEN 'whole' ELSE 'none' END, p_at)
    ON CONFLICT (instance_id, database_name) DO UPDATE SET verdict = EXCLUDED.verdict, restorable_to = EXCLUDED.restorable_to,
        steps = EXCLUDED.steps, state = EXCLUDED.state, decided_at = EXCLUDED.decided_at;
  END LOOP;
END $$;

-- mssql_restore_findings (the findings columns): 'the log chain is broken' (warning) on a database judged for its log
-- backups (mssql_backup_judged: log_status not 'not judged'), whose replicas are all monitored, not on Amazon RDS or Managed
-- Instance (the service keeps their backups: 301's platform line instead), and only for a break - a gap a replica's late
-- read may fill is held, never raised. Its pgvigil.findings arm and the Summary's map are the lead's wiring.
CREATE OR REPLACE VIEW pgvigil.mssql_restore_findings AS
SELECT v.instance_id, 'warning'::text AS severity, 'the log chain is broken' AS check_name, v.database_name AS object,
       v.verdict || ' (a restore from these backups stops there; a new full or differential backup starts a whole chain again)' AS detail,
       v.decided_at AS at
  FROM pgvigil.mssql_restore_verdicts v
  JOIN pgvigil.mssql_backup_judged b ON b.instance_id = v.instance_id AND b.database_name = v.database_name
  JOIN pgvigil.instances i ON i.instance_id = v.instance_id AND i.is_active
 WHERE v.state = 'broken' AND b.log_status <> 'not judged' AND NOT b.replicas_unseen
   AND i.platform NOT IN ('rdssqlserver', 'azuresqlmi');
