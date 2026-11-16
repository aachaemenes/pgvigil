-- 0259: saved page views and dashboards in one store (VIEWS slice A: DBA Dash's saved views and Erik Darling's custom
-- views; internal/web/q_views.go, GET / POST /api/views).
--
--   ui_views      a named view: kind 'page' (one page's state: its address parameters and its grid layouts, page =
--                 'root:<tab>' or 'instance:<tab>') or 'dashboard' (panels over a range and a scope, page = 'dashboard');
--                 personal (its owner's alone) or shared (every signed-in user reads it); at most one default per owner
--                 and page among personal views and one per page among shared ones; a version each write moves (a
--                 save names the version it read: a stale one is refused); the state a JSON object of at most 64 KB.
--   ui_view_log   every write attempt from the UI that reaches the store, done or refused, who and from where; never purged.
--
-- Owner-only BY NAME: apply_roles() grants a reader login every relation not named ui_* and EXECUTE on every function
-- not named ui_* or import_*, and a store custom report or a Grafana login is a reader: a personal view would leak.
-- Reads go through ui_view_list / ui_view_get (SECURITY DEFINER, the UI's door pgvigil_auth, on serve's read-only
-- pool); writes through import_view_save / import_view_delete on the actions door's audit login (serve's read pool is
-- read-only: a write there fails), the session's user and client in the payload, as import_alert_rule (0085) does.
-- A shared write needs serve's shared_ok: the admin role (B24f's 'change shared views' right). The store refuses one without it and
-- logs the attempt as it logs every refusal; serve answers that refusal in the role's words.
-- A removed user's personal views go with it (UIUserRemove deletes them first, in its transaction); a shared view stays
-- with no owner (ON DELETE SET NULL; the CHECK refuses a personal view without one, so a bare DELETE of a user who still
-- owns personal views fails rather than leaving them ownerless).
SET LOCAL lock_timeout = '20s';

CREATE TABLE IF NOT EXISTS pgvigil.ui_views (
  view_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind           text NOT NULL CHECK (kind IN ('page', 'dashboard')),
  page           text NOT NULL CHECK ((kind = 'page' AND page ~ '^(root|instance):[a-z][a-z0-9_]{0,39}$')
                                      OR (kind = 'dashboard' AND page = 'dashboard')),
  name           text NOT NULL CHECK (name = btrim(name) AND length(name) BETWEEN 1 AND 100),
  description    text NOT NULL DEFAULT '' CHECK (length(description) <= 1000),
  folder         text NOT NULL DEFAULT '' CHECK (folder = btrim(folder) AND length(folder) <= 100),
  owner_user_id  int REFERENCES pgvigil.ui_users (user_id) ON DELETE SET NULL,
  shared         boolean NOT NULL DEFAULT false,
  is_default     boolean NOT NULL DEFAULT false,
  state          jsonb NOT NULL CHECK (jsonb_typeof(state) = 'object' AND octet_length(state::text) <= 65536),
  version        int NOT NULL DEFAULT 1 CHECK (version >= 1),
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  updated_by     text NOT NULL,
  updated_at     timestamptz NOT NULL,
  CHECK (shared OR owner_user_id IS NOT NULL)
);
-- names and defaults: PostgreSQL 13 has no NULLS NOT DISTINCT, so page is NOT NULL and each rule a partial index
CREATE UNIQUE INDEX IF NOT EXISTS ui_views_personal_name ON pgvigil.ui_views (owner_user_id, page, lower(name)) WHERE NOT shared;
CREATE UNIQUE INDEX IF NOT EXISTS ui_views_shared_name ON pgvigil.ui_views (page, lower(name)) WHERE shared;
CREATE UNIQUE INDEX IF NOT EXISTS ui_views_personal_default ON pgvigil.ui_views (owner_user_id, page) WHERE is_default AND NOT shared;
CREATE UNIQUE INDEX IF NOT EXISTS ui_views_shared_default ON pgvigil.ui_views (page) WHERE is_default AND shared;
COMMENT ON TABLE pgvigil.ui_views IS 'Saved page views and dashboards (0259). Owner only: the UI reads through ui_view_list / ui_view_get and writes through import_view_save / import_view_delete.';

CREATE TABLE IF NOT EXISTS pgvigil.ui_view_log (
  log_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at       timestamptz NOT NULL,
  ui_user  text NOT NULL,
  client   text,
  op       text NOT NULL,
  view_id  bigint,
  name     text,
  outcome  text NOT NULL CHECK (outcome IN ('done', 'refused', 'forbidden', 'conflict')),
  detail   text
);
CREATE INDEX IF NOT EXISTS ui_view_log_at_idx ON pgvigil.ui_view_log (at DESC);
COMMENT ON TABLE pgvigil.ui_view_log IS 'Every write attempt on ui_views from the UI that reaches the store, done or refused (0259); never purged. Owner only.';

-- ui_view_list: the user's personal views and every shared one (p_page NULL = every page), without their state;
-- loads_by_default marks the one a page opens with: the user's default for the page, else the shared one.
CREATE OR REPLACE FUNCTION pgvigil.ui_view_list(p_user text, p_page text)
RETURNS TABLE (view_id bigint, kind text, page text, name text, description text, folder text, shared boolean,
               mine boolean, is_default boolean, loads_by_default boolean, owner text, version int, updated_by text,
               updated_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
  WITH me AS (SELECT u.user_id FROM pgvigil.ui_users u WHERE u.username = lower(p_user) AND NOT u.is_disabled),
  v AS (
    SELECT w.*, coalesce(w.owner_user_id = (SELECT me.user_id FROM me), false) AS mine
      FROM pgvigil.ui_views w
     WHERE (p_page IS NULL OR w.page = p_page)
       AND (w.shared OR w.owner_user_id = (SELECT me.user_id FROM me))),
  d AS (
    SELECT DISTINCT ON (v.page) v.view_id FROM v
     WHERE v.is_default AND v.kind = 'page'
     ORDER BY v.page, v.shared, v.view_id)            -- a personal default (shared false) before the shared one
  SELECT v.view_id, v.kind, v.page, v.name, v.description, v.folder, v.shared, v.mine, v.is_default,
         v.view_id IN (SELECT d.view_id FROM d), u.username, v.version, v.updated_by, v.updated_at
    FROM v LEFT JOIN pgvigil.ui_users u ON u.user_id = v.owner_user_id
   ORDER BY v.page, NOT v.mine, lower(v.folder), lower(v.name), v.view_id
$$;

-- ui_view_get: one view with its state, when it is shared or the user's own; no row otherwise.
CREATE OR REPLACE FUNCTION pgvigil.ui_view_get(p_user text, p_view_id bigint)
RETURNS TABLE (view_id bigint, kind text, page text, name text, description text, folder text, shared boolean,
               mine boolean, is_default boolean, owner text, version int, created_by text, created_at timestamptz,
               updated_by text, updated_at timestamptz, state jsonb)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
  WITH me AS (SELECT u.user_id FROM pgvigil.ui_users u WHERE u.username = lower(p_user) AND NOT u.is_disabled)
  SELECT w.view_id, w.kind, w.page, w.name, w.description, w.folder, w.shared,
         coalesce(w.owner_user_id = (SELECT me.user_id FROM me), false), w.is_default, u.username, w.version,
         w.created_by, w.created_at, w.updated_by, w.updated_at, w.state
    FROM pgvigil.ui_views w LEFT JOIN pgvigil.ui_users u ON u.user_id = w.owner_user_id
   WHERE w.view_id = p_view_id AND (w.shared OR w.owner_user_id = (SELECT me.user_id FROM me))
$$;

-- import_view_save: create or change one view; every attempt leaves a ui_view_log row, a refused one changes nothing
-- else. payload: ui_user, client, shared_ok, view_id (absent = create), version (the one read; required to change),
-- kind, page, name, description, folder, shared, is_default, state. Returns {outcome, detail, view_id, version}:
-- outcome done | refused (the request's shape) | forbidden (the right) | conflict (a stale version, a taken name).
CREATE OR REPLACE FUNCTION pgvigil.import_view_save(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
DECLARE
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_ok      boolean := coalesce(p_payload->>'shared_ok', '') = 'true';
  v_kind    text := p_payload->>'kind';
  v_page    text := coalesce(p_payload->>'page', CASE WHEN p_payload->>'kind' = 'dashboard' THEN 'dashboard' END);
  v_name    text := btrim(coalesce(p_payload->>'name', ''));
  v_desc    text := coalesce(p_payload->>'description', '');
  v_folder  text := btrim(coalesce(p_payload->>'folder', ''));
  v_shared  boolean := coalesce(p_payload->>'shared', '') = 'true';
  v_def     boolean := coalesce(p_payload->>'is_default', '') = 'true';
  v_state   jsonb := p_payload->'state';
  v_uid     int;
  v_id      bigint;
  v_owner   int;
  v_old     pgvigil.ui_views;
  v_out     text;
  v_why     text;
  v_new     bigint;
  v_ver     int;
  v_con     text;
  v_op      text := CASE WHEN p_payload->>'view_id' IS NOT NULL THEN 'save' ELSE 'create' END;
  v_req     bigint := CASE WHEN coalesce(p_payload->>'view_id', '') ~ '^[0-9]{1,18}$' THEN (p_payload->>'view_id')::bigint END;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_view_save: no ui_user' USING ERRCODE = '22023';
  END IF;
  SELECT u.user_id INTO v_uid FROM pgvigil.ui_users u WHERE u.username = lower(v_user) AND NOT u.is_disabled;
  IF v_uid IS NULL THEN
    v_out := 'forbidden'; v_why := format('no active user %L', v_user);
  ELSIF v_kind IS NULL OR v_kind NOT IN ('page', 'dashboard') THEN
    v_out := 'refused'; v_why := 'kind must be page or dashboard';
  ELSIF v_kind = 'page' AND (v_page IS NULL OR v_page !~ '^(root|instance):[a-z][a-z0-9_]{0,39}$') THEN
    v_out := 'refused'; v_why := format('page %L is not a page key (root:<tab> or instance:<tab>)', v_page);
  ELSIF v_kind = 'dashboard' AND v_page <> 'dashboard' THEN
    v_out := 'refused'; v_why := 'a dashboard''s page is ''dashboard''';
  ELSIF length(v_name) NOT BETWEEN 1 AND 100 THEN
    v_out := 'refused'; v_why := 'a view''s name is 1 to 100 characters';
  ELSIF length(v_desc) > 1000 OR length(v_folder) > 100 THEN
    v_out := 'refused'; v_why := 'a description is at most 1,000 characters and a folder at most 100';
  ELSIF v_state IS NULL OR jsonb_typeof(v_state) <> 'object' THEN
    v_out := 'refused'; v_why := 'state must be a JSON object';
  ELSIF v_kind = 'page' AND (EXISTS (SELECT 1 FROM jsonb_object_keys(v_state) k WHERE k NOT IN ('params', 'layouts', 'range'))
        OR jsonb_typeof(coalesce(v_state->'params', '{}'::jsonb)) <> 'object'
        OR EXISTS (SELECT 1 FROM jsonb_each(coalesce(v_state->'params', '{}'::jsonb)) e WHERE jsonb_typeof(e.value) <> 'string')
        OR jsonb_typeof(coalesce(v_state->'layouts', '[]'::jsonb)) <> 'array'
        OR jsonb_typeof(coalesce(v_state->'range', '{}'::jsonb)) <> 'object') THEN
    v_out := 'refused'; v_why := 'a page view''s state is {params, layouts, range}: params an object of text values, layouts a list, range an object';
  ELSIF v_kind = 'dashboard' AND coalesce(jsonb_typeof(v_state->'panels'), 'array') <> 'array' THEN
    v_out := 'refused'; v_why := 'a dashboard''s panels are a list';
  ELSIF v_kind = 'dashboard' AND jsonb_array_length(coalesce(v_state->'panels', '[]'::jsonb)) > 12 THEN
    v_out := 'refused'; v_why := format('a dashboard holds at most 12 panels (this one %s): each panel is a read of its own', jsonb_array_length(v_state->'panels'));
  ELSIF octet_length(v_state::text) > 65536 THEN
    v_out := 'refused'; v_why := format('the view''s state is %s KB: a view holds at most 64 KB', octet_length(v_state::text) / 1024);
  ELSIF v_shared AND NOT v_ok THEN
    v_out := 'forbidden'; v_why := 'changing a shared view needs the admin role';
  END IF;
  IF v_out IS NULL AND p_payload->>'view_id' IS NOT NULL THEN
    IF p_payload->>'view_id' ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'view_id')::bigint;
      SELECT * INTO v_old FROM pgvigil.ui_views w WHERE w.view_id = v_id FOR UPDATE;
    END IF;
    IF v_id IS NULL OR v_old.view_id IS NULL THEN
      v_out := 'refused'; v_why := format('no view %s', p_payload->>'view_id'); v_id := NULL;
    ELSIF v_old.kind <> v_kind THEN
      v_out := 'refused'; v_why := format('view %s is a %s view: a view keeps its kind', v_id, v_old.kind);
    ELSIF v_old.shared AND NOT v_ok THEN
      v_out := 'forbidden'; v_why := 'changing a shared view needs the admin role';
    ELSIF NOT v_old.shared AND v_old.owner_user_id IS DISTINCT FROM v_uid THEN
      v_out := 'forbidden'; v_why := 'only its owner changes a personal view';
    ELSIF (CASE WHEN coalesce(p_payload->>'version', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'version')::int END) IS DISTINCT FROM v_old.version THEN
      v_out := 'conflict';
      v_why := format('view %s was changed elsewhere: version %s is stored, this save read version %s - reload it',
                      v_id, v_old.version, coalesce(p_payload->>'version', 'none'));
    END IF;
  END IF;
  IF v_out IS NULL THEN
    -- a new view is the user's; a view keeps its owner, shared or not (an editor who un-shares another's view leaves it
    -- its owner's); an ownerless shared view (its owner removed) becomes the user's
    v_owner := CASE WHEN v_id IS NULL THEN v_uid ELSE coalesce(v_old.owner_user_id, v_uid) END;
    BEGIN
      IF v_def THEN   -- one default per owner and page (personal) or per page (shared): the old one cleared, its version moved
        UPDATE pgvigil.ui_views w SET is_default = false, version = w.version + 1, updated_by = v_user, updated_at = p_at
         WHERE w.is_default AND w.page = v_page AND w.view_id IS DISTINCT FROM v_id
           AND ((v_shared AND w.shared) OR (NOT v_shared AND NOT w.shared AND w.owner_user_id = v_owner));
      END IF;
      IF v_id IS NULL THEN
        INSERT INTO pgvigil.ui_views (kind, page, name, description, folder, owner_user_id, shared, is_default, state,
                                      created_by, created_at, updated_by, updated_at)
        VALUES (v_kind, v_page, v_name, v_desc, v_folder, v_owner, v_shared, v_def, v_state, v_user, p_at, v_user, p_at)
        RETURNING view_id, version INTO v_new, v_ver;
      ELSE
        UPDATE pgvigil.ui_views w
           SET page = v_page, name = v_name, description = v_desc, folder = v_folder, owner_user_id = v_owner,
               shared = v_shared, is_default = v_def, state = v_state, version = w.version + 1,
               updated_by = v_user, updated_at = p_at
         WHERE w.view_id = v_id
        RETURNING view_id, version INTO v_new, v_ver;
      END IF;
    EXCEPTION
      WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_con = CONSTRAINT_NAME;
        v_out := 'conflict';
        v_why := CASE WHEN v_con LIKE '%default' THEN format('another default for %s was set at the same moment: reload and save again', v_page)
                      ELSE format('a view named %L already exists among %s on %s', v_name,
                                  CASE WHEN v_shared THEN 'the shared views' ELSE 'your views' END, v_page) END;
        v_new := NULL; v_ver := NULL;
      WHEN check_violation OR foreign_key_violation OR string_data_right_truncation THEN
        v_out := 'refused'; v_why := 'refused by the store: ' || SQLERRM; v_new := NULL; v_ver := NULL;
    END;
  END IF;
  INSERT INTO pgvigil.ui_view_log (at, ui_user, client, op, view_id, name, outcome, detail)
  VALUES (p_at, v_user, v_client, v_op, coalesce(v_new, v_id, v_req),
          left(v_name, 100), coalesce(v_out, 'done'), coalesce(v_why, format('saved, version %s', v_ver)));
  RETURN jsonb_build_object('outcome', coalesce(v_out, 'done'), 'detail', coalesce(v_why, format('saved, version %s', v_ver)),
                            'view_id', coalesce(v_new, v_id), 'version', v_ver);
END $$;

-- import_view_delete: delete one view; payload ui_user, client, shared_ok, view_id, version. One ui_view_log row.
CREATE OR REPLACE FUNCTION pgvigil.import_view_delete(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
DECLARE
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_ok      boolean := coalesce(p_payload->>'shared_ok', '') = 'true';
  v_uid     int;
  v_id      bigint;
  v_old     pgvigil.ui_views;
  v_out     text;
  v_why     text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_view_delete: no ui_user' USING ERRCODE = '22023';
  END IF;
  SELECT u.user_id INTO v_uid FROM pgvigil.ui_users u WHERE u.username = lower(v_user) AND NOT u.is_disabled;
  IF coalesce(p_payload->>'view_id', '') ~ '^[0-9]{1,18}$' THEN
    v_id := (p_payload->>'view_id')::bigint;
    SELECT * INTO v_old FROM pgvigil.ui_views w WHERE w.view_id = v_id FOR UPDATE;
  END IF;
  IF v_uid IS NULL THEN
    v_out := 'forbidden'; v_why := format('no active user %L', v_user);
  ELSIF v_old.view_id IS NULL THEN
    v_out := 'refused'; v_why := format('no view %s', coalesce(p_payload->>'view_id', 'named'));
  ELSIF v_old.shared AND NOT v_ok THEN
    v_out := 'forbidden'; v_why := 'changing a shared view needs the admin role';
  ELSIF NOT v_old.shared AND v_old.owner_user_id IS DISTINCT FROM v_uid THEN
    v_out := 'forbidden'; v_why := 'only its owner deletes a personal view';
  ELSIF (CASE WHEN coalesce(p_payload->>'version', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'version')::int END) IS DISTINCT FROM v_old.version THEN
    v_out := 'conflict';
    v_why := format('view %s was changed elsewhere: version %s is stored, this delete read version %s - reload it',
                    v_id, v_old.version, coalesce(p_payload->>'version', 'none'));
  ELSE
    DELETE FROM pgvigil.ui_views w WHERE w.view_id = v_id;
  END IF;
  INSERT INTO pgvigil.ui_view_log (at, ui_user, client, op, view_id, name, outcome, detail)
  VALUES (p_at, v_user, v_client, 'delete', v_id, v_old.name, coalesce(v_out, 'done'), coalesce(v_why, 'deleted'));
  RETURN jsonb_build_object('outcome', coalesce(v_out, 'done'), 'detail', coalesce(v_why, 'deleted'), 'view_id', v_id);
END $$;

SELECT pgvigil.apply_roles();
