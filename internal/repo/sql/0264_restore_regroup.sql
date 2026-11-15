-- 0264: task 304b - a backups import whose group rows changed decides the restore chain again.
--
-- 0147 decides a database's restore chain from the members of its availability group (mssql_restore_members) and finds
-- the members through mssql_backup_state's group rows, which 0066's import_mssql_backups writes. The collector reads
-- mssql_restore_chain in its own hourly loop, so a replica's chain read can come before the backups read that names its
-- group (a new replica, an instance's first hour), and a group's membership can change between two chain reads (a
-- replica that leaves or joins, a database gone from one replica). The stored verdict then stood on the members of the
-- chain read's moment for up to an hour: a new replica's 'no full' while its primary held the full.
--
-- Here: a statement trigger on mssql_backup_state, after an INSERT and after an UPDATE, finds each row whose group
-- membership changed - a new present row with a group, or an update whose effective group (ag_group_id while the row is
-- present, else none) differs - and decides that database again for the row's own instance and for every instance with
-- a row of that database in the old or the new group, each one that has a chain read of it, in database-then-instance
-- order. The decision is 0147's own, moved into mssql_restore_decide_one (one instance and database);
-- mssql_restore_decide is re-made with the same signature, its loop calling it (the same results). Each decision of the
-- trigger runs in a sub-block: a unique violation or a deadlock against a concurrent chain import deciding the same pair
-- leaves the old verdict (the next chain read decides it, as before this file) and never fails the backups import.
--
-- Not covered: an instance made inactive or deleted (mssql_restore_members reads instances.is_active) leaves its group's
-- verdicts until their next chain read.
--
-- JOIN NOTE: 0264 re-makes 0147's mssql_restore_decide (304's own; no other file re-makes it) and adds two triggers on
-- 0066's mssql_backup_state (no other file has a trigger there); nothing in 0190 or a join-lines file re-creates either.
-- Lock footprint: CREATE TRIGGER takes a SHARE ROW EXCLUSIVE lock on mssql_backup_state for the migration's transaction.

-- mssql_restore_decide_one: the steps and the verdict of one instance's database, from mssql_restore_chain (0147's
-- decide loop body, unchanged).
CREATE OR REPLACE FUNCTION pgvigil.mssql_restore_decide_one(p_instance_id int, p_database text, p_at timestamptz)
RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE
  v record;
BEGIN
  DELETE FROM pgvigil.mssql_restore_steps x WHERE x.instance_id = p_instance_id AND x.database_name = p_database;
  INSERT INTO pgvigil.mssql_restore_steps (instance_id, database_name, step, role, backup_set_uuid, from_instance, start_at, finish_at,
      first_lsn, last_lsn, family_count, mirror_count, media_position, user_name, marks, restorable_to)
  SELECT p_instance_id, p_database, c.* FROM pgvigil.mssql_restore_chain(p_instance_id, p_database) c;
  SELECT max(x.marks) FILTER (WHERE x.step = 0) AS marks, max(x.restorable_to) FILTER (WHERE x.step = 0) AS restorable_to,
         count(*) FILTER (WHERE x.step > 0)::int AS steps
    INTO v FROM pgvigil.mssql_restore_steps x WHERE x.instance_id = p_instance_id AND x.database_name = p_database;
  INSERT INTO pgvigil.mssql_restore_verdicts AS x (instance_id, database_name, verdict, restorable_to, steps, state, decided_at)
  VALUES (p_instance_id, p_database, v.marks, v.restorable_to, v.steps,
          CASE WHEN v.marks LIKE 'broken before%' OR v.marks LIKE 'went to NUL%' THEN 'broken'
               WHEN v.marks LIKE 'not yet read from%' OR v.marks LIKE 'not read whole%' OR v.marks LIKE 'not judged%' THEN 'held'
               WHEN v.marks LIKE 'no full backup%' THEN 'no full'
               WHEN v.marks LIKE 'restorable%' THEN 'whole' ELSE 'none' END, p_at)
  ON CONFLICT (instance_id, database_name) DO UPDATE SET verdict = EXCLUDED.verdict, restorable_to = EXCLUDED.restorable_to,
      steps = EXCLUDED.steps, state = EXCLUDED.state, decided_at = EXCLUDED.decided_at;
END $$;

-- mssql_restore_decide (0147's, re-made: the same signature and results): the verdicts of an instance's databases and
-- of the same databases on the other members of their groups.
CREATE OR REPLACE FUNCTION pgvigil.mssql_restore_decide(p_instance_id int, p_at timestamptz)
RETURNS void LANGUAGE plpgsql VOLATILE AS $$
DECLARE
  t record;
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
    PERFORM pgvigil.mssql_restore_decide_one(t.instance_id, t.database_name, p_at);
  END LOOP;
END $$;

-- mssql_restore_regroup: the statement trigger (header). Its transition tables are new_rows (INSERT, UPDATE) and
-- old_rows (UPDATE). decided_at is the newest snapshot of the changed rows' instances: the backups read's time (a row
-- marked gone keeps the snapshot it was last listed in; the read's other rows carry the read's own).
CREATE OR REPLACE FUNCTION pgvigil.mssql_restore_regroup()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  v_ch jsonb;
  v_at timestamptz;
  t record;
BEGIN
  IF TG_OP = 'INSERT' THEN
    SELECT jsonb_agg(jsonb_build_object('i', n.instance_id, 'd', n.database_name, 'o', NULL, 'n', n.ag_group_id))
      INTO v_ch FROM new_rows n WHERE n.is_present AND n.ag_group_id IS NOT NULL;
  ELSE
    SELECT jsonb_agg(jsonb_build_object('i', n.instance_id, 'd', n.database_name,
                                        'o', CASE WHEN o.is_present THEN o.ag_group_id END, 'n', CASE WHEN n.is_present THEN n.ag_group_id END))
      INTO v_ch
      FROM new_rows n JOIN old_rows o ON o.instance_id = n.instance_id AND o.database_name = n.database_name
     WHERE (CASE WHEN o.is_present THEN o.ag_group_id END) IS DISTINCT FROM (CASE WHEN n.is_present THEN n.ag_group_id END);
  END IF;
  IF v_ch IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT max(b.snapshot_at) INTO v_at FROM pgvigil.mssql_backup_state b
   WHERE b.instance_id IN (SELECT (c->>'i')::int FROM jsonb_array_elements(v_ch) c);
  FOR t IN
    WITH ch AS (SELECT (c->>'i')::int AS instance_id, c->>'d' AS database_name, c->>'o' AS old_group, c->>'n' AS new_group
                  FROM jsonb_array_elements(v_ch) c),
    pairs AS (
      SELECT ch.instance_id, ch.database_name FROM ch
      UNION
      SELECT b.instance_id, b.database_name
        FROM ch JOIN pgvigil.mssql_backup_state b ON b.database_name = ch.database_name AND b.ag_group_id IN (ch.old_group, ch.new_group))
    SELECT pr.instance_id, pr.database_name
      FROM pairs pr JOIN pgvigil.instances i ON i.instance_id = pr.instance_id AND i.is_active
     WHERE EXISTS (SELECT 1 FROM pgvigil.mssql_restore_reads r WHERE r.instance_id = pr.instance_id AND r.database_name = pr.database_name)
     ORDER BY pr.database_name, pr.instance_id
  LOOP
    BEGIN
      PERFORM pgvigil.mssql_restore_decide_one(t.instance_id, t.database_name, v_at);
    EXCEPTION WHEN unique_violation OR deadlock_detected THEN
      -- a chain import of the same pair decides it at the same moment: its verdict stands (the next chain read decides)
      NULL;
    END;
  END LOOP;
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS mssql_backup_state_regroup_ins ON pgvigil.mssql_backup_state;
CREATE TRIGGER mssql_backup_state_regroup_ins AFTER INSERT ON pgvigil.mssql_backup_state
  REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.mssql_restore_regroup();
DROP TRIGGER IF EXISTS mssql_backup_state_regroup_upd ON pgvigil.mssql_backup_state;
CREATE TRIGGER mssql_backup_state_regroup_upd AFTER UPDATE ON pgvigil.mssql_backup_state
  REFERENCING OLD TABLE AS old_rows NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION pgvigil.mssql_restore_regroup();
