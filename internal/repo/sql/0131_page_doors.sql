-- 0131: the read door of an instance added in Admin > Instances (Community tools and custom reports on serve).
--   admin_inventory()        gains auth and options (the door's words for a sign-in it never opens: serve's own
--                            identity, an option outside its list); same name, a new shape: dropped and made again,
--                            its two readers (the collector's repo.go Inventory, serve's door watcher) read the new
--                            columns
--   pgvigil_reader           may call admin_inventory() and admin_inventory_generation() (as apply_roles has granted
--                            after every migration since 0122: written here too, so the file stands on its own):
--                            serve's UI pool, which already reads pgvigil.admin_instances, reads the same rows
--   custom_report_log        gains door ('file': pgvigil.yaml's instance; 'page': Admin > Instances'; 'store': the
--                            repository) and door_generation (the inventory generation the run's door was built
--                            from: repository-wide, one number for the whole list); op 'community_form' (the tool's
--                            form, refused before anything is sent)
--   import_custom_report_run the same signature, writing them

DROP FUNCTION IF EXISTS pgvigil.admin_inventory();
CREATE FUNCTION pgvigil.admin_inventory()
RETURNS TABLE (name text, engine text, platform text, dsn_ref text, tags text[], disabled boolean, auth text, options text, generation bigint)
LANGUAGE sql STABLE AS $$
  SELECT a.name, a.engine, a.platform, a.dsn_ref, a.tags, a.disabled, a.auth, a.options, s.generation
    FROM pgvigil.admin_inventory_state s LEFT JOIN pgvigil.admin_instances a ON true
   WHERE s.one
   ORDER BY a.name
$$;
ALTER FUNCTION pgvigil.admin_inventory() SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_collector') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory() TO pgvigil_collector;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_reader') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory() TO pgvigil_reader;
    GRANT EXECUTE ON FUNCTION pgvigil.admin_inventory_generation() TO pgvigil_reader;
  END IF;
END $$;

ALTER TABLE pgvigil.custom_report_log ADD COLUMN IF NOT EXISTS door text CHECK (door IN ('file', 'page', 'store'));
ALTER TABLE pgvigil.custom_report_log ADD COLUMN IF NOT EXISTS door_generation bigint;
ALTER TABLE pgvigil.custom_report_log DROP CONSTRAINT IF EXISTS custom_report_log_op_check;
ALTER TABLE pgvigil.custom_report_log ADD CONSTRAINT custom_report_log_op_check
  CHECK (op IN ('add', 'edit', 'delete', 'move', 'folder_add', 'folder_rename', 'folder_delete',
                'run', 'community_run', 'community_help', 'community_form'));

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
  IF v_op IS NULL OR v_op NOT IN ('run', 'community_run', 'community_help', 'community_form') THEN
    RAISE EXCEPTION 'import_custom_report_run: op % is not run, community_run, community_help or community_form', v_op USING ERRCODE = '22023';
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
