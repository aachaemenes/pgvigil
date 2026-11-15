-- 0263: Admin > Instances' Settings (the ServiceConfig takes, ST5a): a page instance's own schedules - a collection's
-- interval, or off - and its statement-text policy (query_text), set in the page as pgvigil.yaml sets them for its own
-- instances (an instance's schedules:, disabled: and query_text:).
--
-- admin_instances.settings holds them: {"schedules": {"<collection>": <seconds, 0 = off>}, "query_text": "full" |
-- "normalized" | "none"}; a key left out keeps the default (pgvigil.yaml's global schedules: and query_text:, else the
-- collection's own). It is written only by import_admin_instance_settings, on the actions door's audit login (SECURITY
-- DEFINER through apply_roles), which audits every outcome as the page's other changes ('instance settings') and moves
-- the inventory's generation on a change, so the collector and every serve read the list again within their poll.
-- Serve judges the collection names, the 1-minute floor and the engine (engines.CheckPageSettings) and sends its verdict
-- in the payload: a verdict is refused and audited here, so a refusal of serve's has its audit row too. This function
-- judges the shape alone (an object of whole seconds from 0 to 30 days, query_text's three words).
--
-- admin_instance_settings() is the read: (name, settings) per page instance, SECURITY DEFINER (the collector holds no
-- SELECT on admin_instances), granted here to the collector and the reader; both readers LEFT JOIN it to
-- admin_inventory() in one statement (one snapshot: a generation never pairs with settings of another moment).
--
-- JOIN NOTE: no joined object is re-made (admin_inventory() stays 0157's); one column, two functions. Lock footprint:
-- ADD COLUMN with a constant default (a catalog change; no rewrite) and its CHECK (a scan of admin_instances' rows).

ALTER TABLE pgvigil.admin_instances ADD COLUMN IF NOT EXISTS settings jsonb NOT NULL DEFAULT '{}'::jsonb;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'admin_instances_settings_object' AND conrelid = 'pgvigil.admin_instances'::regclass) THEN
    ALTER TABLE pgvigil.admin_instances ADD CONSTRAINT admin_instances_settings_object CHECK (jsonb_typeof(settings) = 'object');
  END IF;
END $$;
COMMENT ON COLUMN pgvigil.admin_instances.settings IS 'A page instance''s own schedules (seconds, 0 = off) and query_text (Admin > Instances, Settings); written by import_admin_instance_settings only.';

-- admin_settings_words: the audit's words for a settings object ('statements every 60 s, activity off; query_text none')
CREATE OR REPLACE FUNCTION pgvigil.admin_settings_words(p_settings jsonb)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(nullif(concat_ws('; ',
           (SELECT string_agg(k || CASE WHEN v::text = '0' THEN ' off' ELSE ' every ' || v::text || ' s' END, ', ' ORDER BY k)
              FROM jsonb_each(coalesce(p_settings->'schedules', '{}'::jsonb)) AS e(k, v)),
           CASE WHEN p_settings ? 'query_text' THEN 'query_text ' || (p_settings->>'query_text') END), ''), 'every setting at its default')
$$;

-- import_admin_instance_settings: payload {op 'settings', ui_user, client, name, settings, verdict (serve's refusal or
-- absent), file_names}; the answer as import_admin_instance's ({outcome, detail, generation}).
CREATE OR REPLACE FUNCTION pgvigil.import_admin_instance_settings(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_cli  text := p_payload->>'client';
  v_name text := btrim(coalesce(p_payload->>'name', ''));
  v_set  jsonb := p_payload->'settings';
  v_have pgvigil.admin_instances%ROWTYPE;
  v_why  text;
  v_gen  bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_admin_instance_settings: no ui_user' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_have FROM pgvigil.admin_instances WHERE name = v_name;
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
  ELSIF EXISTS (SELECT 1 FROM jsonb_object_keys(v_set) k WHERE k NOT IN ('schedules', 'query_text')) THEN
    v_why := 'settings hold schedules and query_text only';
  ELSIF v_set ? 'schedules' AND jsonb_typeof(v_set->'schedules') <> 'object' THEN
    v_why := 'schedules must be an object of a collection and its seconds';
  ELSIF EXISTS (SELECT 1 FROM jsonb_each(coalesce(v_set->'schedules', '{}'::jsonb)) AS e(k, v)
                 WHERE jsonb_typeof(v) <> 'number' OR v::text !~ '^[0-9]+$' OR v::text::numeric > 2592000) THEN
    v_why := 'each schedule must be whole seconds from 0 (off) to 2592000 (30 days)';
  ELSIF v_set ? 'query_text' AND coalesce(v_set->>'query_text', '') NOT IN ('full', 'normalized', 'none') THEN
    v_why := 'query_text must be full, normalized or none';
  END IF;
  IF v_why IS NOT NULL THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'instance settings', v_name, 'refused', v_why);
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_have.settings = v_set THEN
    PERFORM pgvigil.admin_log(v_user, v_cli, 'instance settings', v_name, 'done', 'unchanged: ' || pgvigil.admin_settings_words(v_set));
    RETURN jsonb_build_object('outcome', 'done', 'detail', format('the settings of %s are unchanged', v_name));
  END IF;
  UPDATE pgvigil.admin_instances SET settings = v_set, updated_at = p_at, updated_by = v_user WHERE name = v_name;
  v_gen := pgvigil.admin_bump();
  PERFORM pgvigil.admin_log(v_user, v_cli, 'instance settings', v_name, 'done', pgvigil.admin_settings_words(v_set));
  RETURN jsonb_build_object('outcome', 'done', 'detail', format('settings of %s saved: %s', v_name, pgvigil.admin_settings_words(v_set)), 'generation', v_gen);
END $$;

-- admin_instance_settings: the settings of every page instance (the readers LEFT JOIN it to admin_inventory()).
CREATE OR REPLACE FUNCTION pgvigil.admin_instance_settings()
RETURNS TABLE (name text, settings jsonb) LANGUAGE sql STABLE AS $$
  SELECT a.name, a.settings FROM pgvigil.admin_instances a ORDER BY a.name
$$;
ALTER FUNCTION pgvigil.admin_instance_settings() SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp;
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_collector') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_instance_settings() TO pgvigil_collector;
  END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_reader') THEN
    GRANT EXECUTE ON FUNCTION pgvigil.admin_instance_settings() TO pgvigil_reader;
  END IF;
END $$;

SELECT pgvigil.apply_roles();
