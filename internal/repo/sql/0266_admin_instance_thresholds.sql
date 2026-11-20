-- 0266: Admin > Instances' Settings, part two (the ServiceConfig takes, ST5b): a SQL Server page instance's own
-- thresholds, a paused collection's own interval, and a write that names what it read.
--
-- admin_instances.settings (0263) gains three keys, all written by import_admin_instance_settings alone:
--   thresholds  {"<name>": <number 0 or more>, ..., "backup_exclude": ["<LIKE pattern>", ...]} - what pgvigil.yaml's
--               mssql_thresholds: is for an instance of the file (the 11 names of mssql.HADRThresholds); a SQL Server
--               instance's only;
--   paused      {"<collection>": <seconds, 60 to 30 days>} - the instance's own interval of a collection the tree's
--               Pause Collections set off (its schedule 0), written back by Resume;
-- and the payload (not the settings) may carry expect: the settings as the editor read them; a write over settings that
-- changed since is refused ('changed since they were read'), so the panel and the tree's two dialogs never undo each
-- other's change unseen.
-- Serve judges the names, the engine and the floor first (engines.CheckPageSettings, mssql.ThresholdRows) and sends a
-- refusal as the verdict; this function judges the shape itself as strictly (the collector stores nothing it refuses).
--
-- JOIN NOTE: no joined object is re-made; 0263's two functions are re-made with their signatures; the table's CHECK
-- (an object) stands. Lock footprint: none on a table (two CREATE OR REPLACE FUNCTION).

-- admin_settings_words: the audit's words ('mssql_jobs off; thresholds redo_queue_kb 512000; backup_exclude tmp%;
-- paused mssql_jobs (its own 600 s kept)')
CREATE OR REPLACE FUNCTION pgvigil.admin_settings_words(p_settings jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(concat_ws('; ',
           (SELECT string_agg(k || CASE WHEN v::text = '0' THEN ' off' ELSE ' every ' || v::text || ' s' END, ', ' ORDER BY k)
              FROM jsonb_each(coalesce(p_settings->'schedules', '{}'::jsonb)) AS e(k, v)),
           CASE WHEN p_settings ? 'query_text' THEN 'query_text ' || (p_settings->>'query_text') END,
           (SELECT 'thresholds ' || string_agg(k || ' ' || v::text, ', ' ORDER BY k)
              FROM jsonb_each(CASE WHEN jsonb_typeof(p_settings->'thresholds') = 'object' THEN p_settings->'thresholds' ELSE '{}'::jsonb END) AS e(k, v)
             WHERE k <> 'backup_exclude'),
           (SELECT 'backup_exclude ' || string_agg(x, ', ' ORDER BY o)
              FROM jsonb_array_elements_text(CASE WHEN jsonb_typeof(p_settings->'thresholds'->'backup_exclude') = 'array'
                                                  THEN p_settings->'thresholds'->'backup_exclude' ELSE '[]'::jsonb END) WITH ORDINALITY AS a(x, o)),
           (SELECT 'paused ' || string_agg(k || ' (its own ' || v::text || ' s kept)', ', ' ORDER BY k)
              FROM jsonb_each(CASE WHEN jsonb_typeof(p_settings->'paused') = 'object' THEN p_settings->'paused' ELSE '{}'::jsonb END) AS e(k, v))), ''),
         'every setting at its default')
$$;

-- import_admin_instance_settings: payload {op 'settings', ui_user, client, name, settings, expect (optional), verdict
-- (serve's refusal or absent), file_names}; the answer {outcome, detail, generation}.
CREATE OR REPLACE FUNCTION pgvigil.import_admin_instance_settings(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli   text := p_payload->>'client';
  v_name  text := btrim(coalesce(p_payload->>'name', ''));
  v_set   jsonb := p_payload->'settings';
  v_have  pgvigil.admin_instances%ROWTYPE;
  v_why   text;
  v_gen   bigint;
  v_th    jsonb;
  v_k     text;
  v_v     jsonb;
  -- mssql.HADRThresholds' names (TestAdminInstanceThresholdsOnAStore names them; engines' test holds the Go list equal)
  c_known text[] := ARRAY['diff_backup_hours', 'full_backup_hours', 'job_failed_hours', 'job_long_factor', 'job_long_min_seconds',
                          'log_backup_minutes', 'log_send_queue_kb', 'new_database_hours', 'nul_backup_days', 'redo_queue_kb',
                          'repl_undistributed_commands'];
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_instance_settings: no ui_user' USING ERRCODE = '22023';
  END IF;
  -- FOR UPDATE: a second editor's write with the same expect waits here for the first and
  -- then reads its settings, so the expect check refuses it - never a write over another unseen
  SELECT * INTO v_have FROM pgvigil.admin_instances WHERE name = v_name FOR UPDATE;
  v_th := CASE WHEN jsonb_typeof(v_set) = 'object' THEN v_set->'thresholds' END;
  IF coalesce(p_payload->>'op', '') <> 'settings' THEN
    v_why := 'op must be settings';
  ELSIF nullif(btrim(coalesce(p_payload->>'verdict', '')), '') IS NOT NULL THEN
    v_why := btrim(p_payload->>'verdict');
  ELSIF jsonb_typeof(p_payload->'file_names') = 'array' AND p_payload->'file_names' ? v_name THEN
    v_why := format('%s is an instance of pgvigil.yaml: its schedules:, disabled: and query_text: in the file are its settings', v_name);
  ELSIF v_have.name IS NULL THEN
    v_why := format('no instance %s was added here', v_name);
  ELSIF v_set IS NULL OR jsonb_typeof(v_set) <> 'object' THEN
    v_why := 'settings must be an object';
  ELSIF EXISTS (SELECT 1 FROM jsonb_object_keys(v_set) k WHERE k NOT IN ('schedules', 'query_text', 'thresholds', 'paused')) THEN
    v_why := 'settings hold schedules, query_text, thresholds and paused only';
  ELSIF v_set ? 'schedules' AND jsonb_typeof(v_set->'schedules') <> 'object' THEN
    v_why := 'schedules must be an object of a collection and its seconds';
  ELSIF EXISTS (SELECT 1 FROM jsonb_each(coalesce(v_set->'schedules', '{}'::jsonb)) AS e(k, v)
                 WHERE jsonb_typeof(v) <> 'number' OR v::text !~ '^[0-9]+$' OR v::text::numeric > 2592000) THEN
    v_why := 'each schedule must be whole seconds from 0 (off) to 2592000 (30 days)';
  ELSIF v_set ? 'query_text' AND coalesce(v_set->>'query_text', '') NOT IN ('full', 'normalized', 'none') THEN
    v_why := 'query_text must be full, normalized or none';
  ELSIF v_th IS NOT NULL AND v_have.engine <> 'sqlserver' THEN
    v_why := format('thresholds are a SQL Server instance''s (mssql_thresholds): %s is a PostgreSQL instance', v_name);
  ELSIF v_th IS NOT NULL AND jsonb_typeof(v_th) <> 'object' THEN
    v_why := 'thresholds must be an object of a threshold and its number';
  ELSIF v_set ? 'paused' AND jsonb_typeof(v_set->'paused') <> 'object' THEN
    v_why := 'paused must be an object of a collection and its seconds';
  ELSIF EXISTS (SELECT 1 FROM jsonb_each(coalesce(v_set->'paused', '{}'::jsonb)) AS e(k, v)
                 WHERE CASE WHEN jsonb_typeof(v) <> 'number' OR v::text !~ '^[0-9]+$' THEN true ELSE v::text::numeric NOT BETWEEN 60 AND 2592000 END) THEN
    v_why := 'each paused interval must be whole seconds from 60 to 2592000 (30 days)';
  END IF;
  IF v_why IS NULL AND v_th IS NOT NULL THEN
    SELECT k INTO v_k FROM jsonb_object_keys(v_th) k WHERE k <> 'backup_exclude' AND k <> ALL (c_known) ORDER BY k LIMIT 1;
    IF v_k IS NOT NULL THEN
      v_why := format('threshold %s is not known; known: %s, backup_exclude', v_k, array_to_string(c_known, ', '));
    END IF;
  END IF;
  IF v_why IS NULL AND v_th IS NOT NULL THEN
    SELECT e.k, e.v INTO v_k, v_v FROM jsonb_each(v_th) AS e(k, v)
     WHERE e.k <> 'backup_exclude' AND CASE WHEN jsonb_typeof(e.v) <> 'number' THEN true ELSE e.v::text::numeric < 0 END ORDER BY e.k LIMIT 1;
    IF v_k IS NOT NULL THEN
      v_why := format('each threshold must be a number of 0 or more (%s %s)', v_k, v_v::text);
    ELSIF v_th ? 'backup_exclude' AND (jsonb_typeof(v_th->'backup_exclude') <> 'array'
          OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_th->'backup_exclude') x WHERE jsonb_typeof(x) <> 'string' OR btrim(x #>> '{}', E' \t\n\x0B\f\r') = '')) THEN
      v_why := 'backup_exclude must be a list of database name patterns, none blank';
    END IF;
  END IF;
  IF v_why IS NULL AND p_payload ? 'expect' AND v_have.settings IS DISTINCT FROM p_payload->'expect' THEN
    v_why := format('the settings of %s changed since they were read: read them again', v_name);
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'instance settings', v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_have.settings = v_set THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'instance settings', v_name, 'done', 'unchanged: ' || pgvigil.admin_settings_words(v_set));
    RETURN jsonb_build_object('outcome', 'done', 'detail', format('the settings of %s are unchanged', v_name), 'thresholds_changed', false);
  END IF;
  UPDATE pgvigil.admin_instances SET settings = v_set, updated_at = p_at, updated_by = v_user WHERE name = v_name;
  v_gen := pgvigil.admin_bump();
  PERFORM pgvigil.admin_log(v_user, v_cli, 'instance settings', v_name, 'done', pgvigil.admin_settings_words(v_set));
  -- thresholds_changed: serve says the thresholds wait for the next HA/DR, jobs or backups read only when they changed
  RETURN jsonb_build_object('outcome', 'done', 'detail', format('settings of %s saved: %s', v_name, pgvigil.admin_settings_words(v_set)), 'generation', v_gen,
                            'thresholds_changed', (v_have.settings -> 'thresholds') IS DISTINCT FROM (v_set -> 'thresholds'));
END $$;

SELECT pgvigil.apply_roles();
