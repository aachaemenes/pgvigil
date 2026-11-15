-- 0261: Admin > Instances' 'Check all' (the ServiceConfig takes, ST1): the last connection test of an instance that
-- lives in pgvigil.yaml; and the audit row of a Rights read (ST2: import_admin_rights_read, below).
--
-- The page's own instances keep their last test on their row (admin_instances.tested_at / tested_ok / tested_detail,
-- 0122). An instance of the file has no row there: its last test is kept here, by its name, so 'Check all' shows the
-- same 'last test' for both tables and the result is still there after the page is read again. It is written by
-- serve through import_admin_file_test on the actions door's audit login (SECURITY DEFINER through apply_roles, as
-- every import_ function) and audited as the page's own tests are ('instance tested', done, connected or failed).
-- The payload names the file's instances as serve holds them: a name that is not among them is refused, and a name
-- the page owns is refused (its test is import_admin_instance's). Nothing is pruned: two serve processes with
-- different files may share a repository, and the page reads the rows of its own file's names only. A test older
-- than the stored one is audited and not stored ('not kept').
--
-- JOIN NOTE: nothing here touches a joined object (no arm of pgvigil.findings, of a purge or of a cursor). A name the
-- file no longer lists keeps its row (one small row per name ever tested; the page does not show it).
-- Lock footprint: one new table.

CREATE TABLE IF NOT EXISTS pgvigil.admin_file_tests (
  name          text PRIMARY KEY,
  tested_at     timestamptz NOT NULL,
  tested_ok     boolean NOT NULL,
  tested_detail text,
  tested_by     text NOT NULL
);
COMMENT ON TABLE pgvigil.admin_file_tests IS 'The last connection test of each instance of pgvigil.yaml (Admin > Instances, Check all); written by import_admin_file_test only.';

-- import_admin_file_test: payload ui_user, client, name, ok, detail, file_names (the file's instance names now).
CREATE OR REPLACE FUNCTION pgvigil.import_admin_file_test(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli   text := p_payload->>'client';
  v_name  text := btrim(coalesce(p_payload->>'name', ''));
  v_ok    boolean := (p_payload->>'ok')::boolean;
  v_names text[];
  v_why   text;
  v_n     int;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_file_test: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_payload->'file_names') = 'array' THEN
    SELECT coalesce(array_agg(t), '{}') INTO v_names FROM jsonb_array_elements_text(p_payload->'file_names') t;
  END IF;
  IF v_names IS NULL THEN
    v_why := 'file_names must list the instances of pgvigil.yaml';
  ELSIF v_name = '' OR NOT (v_name = ANY (v_names)) THEN
    v_why := 'not an instance of pgvigil.yaml';
  ELSIF EXISTS (SELECT 1 FROM pgvigil.admin_instances a WHERE a.name = v_name) THEN
    v_why := 'an instance added in the page: its test is kept on its own row';
  ELSIF v_ok IS NULL THEN
    v_why := 'ok must be true or false';
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'instance tested', v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  INSERT INTO pgvigil.admin_file_tests AS t (name, tested_at, tested_ok, tested_detail, tested_by)
  VALUES (v_name, p_at, v_ok, left(p_payload->>'detail', 1000), v_user)
  ON CONFLICT (name) DO UPDATE SET tested_at = excluded.tested_at, tested_ok = excluded.tested_ok,
        tested_detail = excluded.tested_detail, tested_by = excluded.tested_by
    WHERE t.tested_at <= excluded.tested_at;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM pgvigil.admin_log(v_user, v_cli, 'instance tested', v_name, 'done',
    CASE WHEN v_ok THEN 'connected' ELSE 'failed: ' || left(coalesce(p_payload->>'detail', ''), 500) END
      || CASE WHEN v_n = 0 THEN ' (not kept: a newer test is stored)' ELSE '' END);
  IF v_n = 0 THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'not kept: a newer test of ' || v_name || ' is stored');
  END IF;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'tested ' || v_name);
END $$;

-- import_admin_rights_read (ST2): one audit row for a Rights read of an instance - serve connected to that server as
-- its monitoring login on a user's click and read which rights it holds; nothing is stored but the audit row (the
-- answer is the page's). Payload: ui_user, client, name, ok, detail (how many rights are missing, or why not read).
CREATE OR REPLACE FUNCTION pgvigil.import_admin_rights_read(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_name text := btrim(coalesce(p_payload->>'name', ''));
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_rights_read: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_name = '' THEN
    PERFORM pgvigil.admin_log(v_user, p_payload->>'client', 'instance rights', v_name, 'refused', 'no instance named');
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'no instance named');
  END IF;
  PERFORM pgvigil.admin_log(v_user, p_payload->>'client', 'instance rights', v_name, 'done',
    CASE WHEN (p_payload->>'ok')::boolean THEN 'read: ' ELSE 'not read: ' END || left(coalesce(p_payload->>'detail', ''), 500));
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'rights read of ' || v_name);
END $$;

SELECT pgvigil.apply_roles();
