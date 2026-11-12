-- 0106_custom_reports: custom reports (task 170; DBA Dash's custom reports: the DBA's own SQL or procedure saved as a
-- report with parameters, column formats, colour rules and folders shared by all users) and the audit of every run of
-- a custom report or a community tool (internal/web/q_customreports.go, q_community.go).
--
--   custom_report_folders  the folders of the Custom reports tree: a path of parts joined by '/' (Ops/Daily), made by
--                          a user or by the first report moved into it; an empty folder stays until it is deleted.
--   custom_reports         one row per report: its name (unique among the live reports, any case), description,
--                          folder ('' = the top of the tree), engine (store: the repository itself; postgres or
--                          sqlserver: the monitored instances of that engine), kind (sql: the SQL text; procedure: a
--                          procedure or function name the server calls with the parameters by name), body, params,
--                          columns (formats per result set and column), rules (colour rules: ok / warn / crit by a
--                          column's value), the run's timeout and row cap, who made and changed it, version (raised by
--                          each edit: an edit made against an older version is refused), and deleted_at / deleted_by
--                          (a deleted report is kept for its log, never shown).
--   custom_report_log      the audit: every save, move, delete and folder change, and every run of a custom report or
--                          a community tool (who, from where, on which instance or the store, the statement sent, the
--                          outcome, the rows and the time it took). An audit like actions_log: never purged.
--   custom_report_folder_norm(text)  a folder path trimmed part by part, empty parts dropped ('' = the top).
--   import_custom_report(at, payload) -> jsonb {outcome, detail, report_id, version}: add | edit | delete | move |
--                          folder_add | folder_rename | folder_delete, with its log row; refused = nothing changed.
--   import_custom_report_run(at, payload) -> bigint: one run's log row (a custom report run or a community tool run).
--
-- Writes go through the actions door's audit login (pgvigil_collector: apply_roles makes every import_* SECURITY
-- DEFINER and grants it there), behind the UI login; the UI's read-only pool reads the tables.

CREATE TABLE IF NOT EXISTS pgvigil.custom_report_folders (
  folder      text PRIMARY KEY CHECK (length(folder) BETWEEN 1 AND 400 AND folder !~ '(^/|/$|//)'),
  created_by  text NOT NULL,
  created_at  timestamptz NOT NULL
);
COMMENT ON TABLE pgvigil.custom_report_folders IS 'The Custom reports tree''s folders (path parts joined by /); written through import_custom_report only.';

CREATE TABLE IF NOT EXISTS pgvigil.custom_reports (
  report_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name          text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
  description   text CHECK (length(description) <= 4000),
  folder        text NOT NULL DEFAULT '' CHECK (length(folder) <= 400 AND folder !~ '(^/|/$|//)'),
  engine        text NOT NULL CHECK (engine IN ('store', 'postgres', 'sqlserver')),
  kind          text NOT NULL CHECK (kind IN ('sql', 'procedure')),
  body          text NOT NULL CHECK (length(body) BETWEEN 1 AND 200000),
  params        jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(params) = 'array'),
  columns       jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(columns) = 'array'),
  rules         jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(rules) = 'array'),
  timeout_secs  int NOT NULL DEFAULT 30 CHECK (timeout_secs BETWEEN 1 AND 60),
  max_rows      int NOT NULL DEFAULT 5000 CHECK (max_rows BETWEEN 1 AND 50000),
  created_by    text NOT NULL,
  created_at    timestamptz NOT NULL,
  updated_by    text NOT NULL,
  updated_at    timestamptz NOT NULL,
  version       int NOT NULL DEFAULT 1,
  deleted_by    text,
  deleted_at    timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS custom_reports_name_live ON pgvigil.custom_reports (lower(btrim(name))) WHERE deleted_at IS NULL;
COMMENT ON TABLE pgvigil.custom_reports IS 'Custom reports: the DBA''s own SQL or procedure with its parameters, formats and colour rules; written through import_custom_report only.';

CREATE TABLE IF NOT EXISTS pgvigil.custom_report_log (
  log_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at           timestamptz NOT NULL,
  ui_user      text NOT NULL,
  client       text,
  op           text NOT NULL CHECK (op IN ('add', 'edit', 'delete', 'move', 'folder_add', 'folder_rename', 'folder_delete',
                                           'run', 'community_run', 'community_help')),
  report_id    bigint,
  report_name  text,
  tool         text,
  instance_id  int,           -- no reference: the audit outlives the instance
  instance     text,          -- the instance's name, or 'store' for a run on the repository
  outcome      text NOT NULL CHECK (outcome IN ('done', 'refused', 'failed')),
  detail       text,
  rows         int,
  duration_ms  int,
  statement    text,
  payload      jsonb
);
CREATE INDEX IF NOT EXISTS custom_report_log_at ON pgvigil.custom_report_log (at DESC);
CREATE INDEX IF NOT EXISTS custom_report_log_report ON pgvigil.custom_report_log (report_id, at DESC) WHERE report_id IS NOT NULL;
COMMENT ON TABLE pgvigil.custom_report_log IS 'The audit of every custom report change and of every custom report or community tool run; never purged.';

-- custom_report_folder_norm: each part trimmed, empty parts dropped, '\' read as '/' (DBA Dash's NormalizeFolder)
CREATE OR REPLACE FUNCTION pgvigil.custom_report_folder_norm(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(string_agg(btrim(x.part), '/' ORDER BY x.n), '')
    FROM regexp_split_to_table(replace(coalesce(p, ''), E'\\', '/'), '/') WITH ORDINALITY AS x(part, n)
   WHERE btrim(x.part) <> ''
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_custom_report(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_name    text := nullif(btrim(coalesce(p_payload->>'name', '')), '');
  v_folder  text := pgvigil.custom_report_folder_norm(p_payload->>'folder');
  v_new     text := pgvigil.custom_report_folder_norm(p_payload->>'new_folder');
  v_id      bigint;
  v_ver     int;
  v_old     pgvigil.custom_reports;
  v_why     text;
  v_done    text;
  v_n       bigint;
  v_timeout int;
  v_rows    int;
  v_paths   text[];
BEGIN
  -- one write at a time: the name check, the version check and a folder rename see what the one before them wrote
  -- (two adds of one name at once would both pass the check, and the second fail on the unique index unlogged)
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_custom_report'));
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_custom_report: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('add', 'edit', 'delete', 'move', 'folder_add', 'folder_rename', 'folder_delete') THEN
    RAISE EXCEPTION 'import_custom_report: op % is not add, edit, delete, move, folder_add, folder_rename or folder_delete', v_op
      USING ERRCODE = '22023';
  END IF;
  -- the report an edit, a delete or a move names, live
  IF v_why IS NULL AND v_op IN ('edit', 'delete', 'move') THEN
    IF coalesce(p_payload->>'report_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'report_id')::bigint;
      SELECT * INTO v_old FROM pgvigil.custom_reports WHERE report_id = v_id FOR UPDATE;
    END IF;
    IF v_id IS NULL THEN
      v_why := format('report_id %L is not a report id', p_payload->>'report_id');
    ELSIF v_old.report_id IS NULL THEN
      v_why := format('no report %s', v_id);
    ELSIF v_old.deleted_at IS NOT NULL THEN
      v_why := format('report %s was deleted by %s at %s', v_id, v_old.deleted_by, v_old.deleted_at);
    ELSIF v_op = 'edit' THEN
      IF coalesce(p_payload->>'version', '') !~ '^[0-9]{1,9}$' THEN
        v_why := 'an edit names the version it was made on';
      ELSIF (p_payload->>'version')::int <> v_old.version THEN
        v_why := format('report %s was changed by %s at %s since this edit began (version %s, the edit''s %s): reopen it',
                        v_id, v_old.updated_by, v_old.updated_at, v_old.version, p_payload->>'version');
      END IF;
    END IF;
  END IF;
  -- the definition of an add or an edit
  IF v_why IS NULL AND v_op IN ('add', 'edit') THEN
    IF v_name IS NULL OR length(v_name) > 200 THEN
      v_why := 'a report has a name of 1 to 200 characters';
    ELSIF EXISTS (SELECT 1 FROM pgvigil.custom_reports r WHERE r.deleted_at IS NULL AND lower(btrim(r.name)) = lower(v_name)
                     AND r.report_id IS DISTINCT FROM v_id) THEN
      v_why := format('a report named %L exists already', v_name);
    ELSIF coalesce(p_payload->>'engine', '') NOT IN ('store', 'postgres', 'sqlserver') THEN
      v_why := 'engine must be store, postgres or sqlserver';
    ELSIF coalesce(p_payload->>'kind', '') NOT IN ('sql', 'procedure') THEN
      v_why := 'kind must be sql or procedure';
    ELSIF length(btrim(coalesce(p_payload->>'body', ''))) = 0 OR length(p_payload->>'body') > 200000 THEN
      v_why := 'the report''s SQL (or procedure name) is 1 to 200000 characters';
    ELSIF coalesce(jsonb_typeof(p_payload->'params'), 'array') <> 'array'
          OR coalesce(jsonb_typeof(p_payload->'columns'), 'array') <> 'array'
          OR coalesce(jsonb_typeof(p_payload->'rules'), 'array') <> 'array' THEN
      v_why := 'params, columns and rules are arrays';
    ELSIF length(v_folder) > 400 THEN
      v_why := 'a folder path is at most 400 characters';
    ELSIF length(p_payload->>'description') > 4000 THEN
      v_why := 'a description is at most 4000 characters';
    ELSIF coalesce(p_payload->>'timeout_secs', '30') !~ '^[0-9]{1,2}$' OR coalesce(p_payload->>'timeout_secs', '30')::int NOT BETWEEN 1 AND 60 THEN
      v_why := 'timeout_secs is a whole number of seconds, 1 to 60';
    ELSIF coalesce(p_payload->>'max_rows', '5000') !~ '^[0-9]{1,5}$' OR coalesce(p_payload->>'max_rows', '5000')::int NOT BETWEEN 1 AND 50000 THEN
      v_why := 'max_rows is a whole number, 1 to 50000';
    ELSE
      v_timeout := coalesce(p_payload->>'timeout_secs', '30')::int;
      v_rows := coalesce(p_payload->>'max_rows', '5000')::int;
    END IF;
  END IF;
  IF v_why IS NULL AND v_op = 'move' AND length(v_folder) > 400 THEN
    v_why := 'a folder path is at most 400 characters';
  END IF;
  IF v_why IS NULL AND v_op IN ('folder_add', 'folder_rename', 'folder_delete') THEN
    IF v_folder = '' THEN
      v_why := 'name the folder';
    ELSIF length(v_folder) > 400 THEN
      v_why := 'a folder path is at most 400 characters';
    ELSIF v_op = 'folder_add' AND EXISTS (SELECT 1 FROM pgvigil.custom_report_folders f WHERE f.folder = v_folder) THEN
      v_why := format('the folder %s exists already', v_folder);
    ELSIF v_op IN ('folder_rename', 'folder_delete')
          AND NOT EXISTS (SELECT 1 FROM pgvigil.custom_report_folders f WHERE f.folder = v_folder OR starts_with(f.folder, v_folder || '/'))
          AND NOT EXISTS (SELECT 1 FROM pgvigil.custom_reports r WHERE r.deleted_at IS NULL AND (r.folder = v_folder OR starts_with(r.folder, v_folder || '/'))) THEN
      v_why := format('no folder %s', v_folder);
    ELSIF v_op = 'folder_rename' AND (v_new = '' OR length(v_new) > 400) THEN
      v_why := 'the new folder path is 1 to 400 characters';
    ELSIF v_op = 'folder_rename' AND (v_new = v_folder OR starts_with(v_new, v_folder || '/')) THEN
      v_why := format('the folder %s cannot move into itself (%s)', v_folder, v_new);
    ELSIF v_op = 'folder_rename' AND (
          EXISTS (SELECT 1 FROM pgvigil.custom_report_folders f WHERE (f.folder = v_folder OR starts_with(f.folder, v_folder || '/'))
                     AND length(v_new) + length(f.folder) - length(v_folder) > 400)
       OR EXISTS (SELECT 1 FROM pgvigil.custom_reports r WHERE r.deleted_at IS NULL AND (r.folder = v_folder OR starts_with(r.folder, v_folder || '/'))
                     AND length(v_new) + length(r.folder) - length(v_folder) > 400)) THEN
      v_why := format('renamed %s, a folder under %s would be longer than 400 characters', v_new, v_folder);
    ELSIF v_op = 'folder_delete' AND EXISTS (SELECT 1 FROM pgvigil.custom_reports r WHERE r.deleted_at IS NULL
                                               AND (r.folder = v_folder OR starts_with(r.folder, v_folder || '/'))) THEN
      v_why := format('the folder %s holds reports: move them out first', v_folder);
    END IF;
  END IF;

  IF v_why IS NULL THEN
    CASE v_op
    WHEN 'add' THEN
      INSERT INTO pgvigil.custom_reports (name, description, folder, engine, kind, body, params, columns, rules, timeout_secs,
                                          max_rows, created_by, created_at, updated_by, updated_at)
      VALUES (v_name, nullif(btrim(coalesce(p_payload->>'description', '')), ''), v_folder, p_payload->>'engine',
              p_payload->>'kind', p_payload->>'body', coalesce(p_payload->'params', '[]'), coalesce(p_payload->'columns', '[]'),
              coalesce(p_payload->'rules', '[]'), v_timeout, v_rows, v_user, p_at, v_user, p_at)
      RETURNING report_id, version INTO v_id, v_ver;
      v_done := format('report %s %L added', v_id, v_name);
    WHEN 'edit' THEN
      UPDATE pgvigil.custom_reports
         SET name = v_name, description = nullif(btrim(coalesce(p_payload->>'description', '')), ''), folder = v_folder,
             engine = p_payload->>'engine', kind = p_payload->>'kind', body = p_payload->>'body',
             params = coalesce(p_payload->'params', '[]'), columns = coalesce(p_payload->'columns', '[]'),
             rules = coalesce(p_payload->'rules', '[]'), timeout_secs = v_timeout, max_rows = v_rows,
             updated_by = v_user, updated_at = p_at, version = version + 1
       WHERE report_id = v_id
      RETURNING version INTO v_ver;
      v_done := format('report %s %L saved as version %s', v_id, v_name, v_ver);
    WHEN 'delete' THEN
      UPDATE pgvigil.custom_reports SET deleted_by = v_user, deleted_at = p_at WHERE report_id = v_id;
      v_name := v_old.name;
      v_done := format('report %s %L deleted', v_id, v_old.name);
    WHEN 'move' THEN
      UPDATE pgvigil.custom_reports SET folder = v_folder, updated_by = v_user, updated_at = p_at, version = version + 1
       WHERE report_id = v_id
      RETURNING version INTO v_ver;
      v_name := v_old.name;
      v_done := format('report %s %L moved to %s', v_id, v_old.name, CASE WHEN v_folder = '' THEN 'the top' ELSE v_folder END);
    WHEN 'folder_add' THEN
      NULL;   -- the folder row below
      v_done := format('folder %s added', v_folder);
    WHEN 'folder_rename' THEN
      -- the folder and every folder under it take the new path; so do their reports. The new paths are read before the
      -- old tree is deleted and written after it: a new path can lie under the old folder (A/B renamed A keeps A/B/x
      -- as A/x, and A/B/B/x as A/B/x)
      SELECT array_agg(v_new || substr(f.folder, length(v_folder) + 1)) INTO v_paths
        FROM pgvigil.custom_report_folders f WHERE f.folder = v_folder OR starts_with(f.folder, v_folder || '/');
      DELETE FROM pgvigil.custom_report_folders f WHERE f.folder = v_folder OR starts_with(f.folder, v_folder || '/');
      INSERT INTO pgvigil.custom_report_folders (folder, created_by, created_at)
      SELECT DISTINCT x, v_user, p_at FROM unnest(coalesce(v_paths, '{}')) x
      ON CONFLICT (folder) DO NOTHING;
      UPDATE pgvigil.custom_reports r SET folder = v_new || substr(r.folder, length(v_folder) + 1), version = version + 1,
                                          updated_by = v_user, updated_at = p_at
       WHERE r.deleted_at IS NULL AND (r.folder = v_folder OR starts_with(r.folder, v_folder || '/'));
      GET DIAGNOSTICS v_n = ROW_COUNT;
      v_done := format('folder %s renamed %s (%s reports)', v_folder, v_new, v_n);
    WHEN 'folder_delete' THEN
      DELETE FROM pgvigil.custom_report_folders f WHERE f.folder = v_folder OR starts_with(f.folder, v_folder || '/');
      v_done := format('folder %s deleted', v_folder);
    END CASE;
    -- a report's folder, a new folder and a renamed one exist as rows, and so does each folder above them (an empty
    -- parent stays visible in the tree after its last child is moved)
    INSERT INTO pgvigil.custom_report_folders (folder, created_by, created_at)
    SELECT DISTINCT array_to_string(p.parts[1:n], '/'), v_user, p_at
      FROM (SELECT string_to_array(CASE WHEN v_op = 'folder_rename' THEN v_new
                                        WHEN v_op IN ('add', 'edit', 'move', 'folder_add') THEN v_folder END, '/') AS parts) p
      CROSS JOIN LATERAL generate_series(1, coalesce(cardinality(p.parts), 0)) n
     WHERE p.parts IS NOT NULL
    ON CONFLICT (folder) DO NOTHING;
  END IF;

  INSERT INTO pgvigil.custom_report_log (at, ui_user, client, op, report_id, report_name, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, v_op,
          v_id, coalesce(v_name, v_old.name), CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, coalesce(v_why, v_done),
          p_payload - 'ui_user' - 'client');
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, 'detail', coalesce(v_why, v_done),
                            'report_id', v_id, 'version', v_ver);
END $$;

-- import_custom_report_run: one run's audit row (the server writes it after the run, before it answers)
CREATE OR REPLACE FUNCTION pgvigil.import_custom_report_run(p_at timestamptz, p_payload jsonb)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_user text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_op   text := p_payload->>'op';
  v_out  text := p_payload->>'outcome';
  v_id   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_custom_report_run: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('run', 'community_run', 'community_help') THEN
    RAISE EXCEPTION 'import_custom_report_run: op % is not run, community_run or community_help', v_op USING ERRCODE = '22023';
  END IF;
  IF v_out IS NULL OR v_out NOT IN ('done', 'refused', 'failed') THEN
    RAISE EXCEPTION 'import_custom_report_run: outcome % is not done, refused or failed', v_out USING ERRCODE = '22023';
  END IF;
  INSERT INTO pgvigil.custom_report_log (at, ui_user, client, op, report_id, report_name, tool, instance_id, instance, outcome,
                                         detail, rows, duration_ms, statement, payload)
  VALUES (p_at, v_user, nullif(p_payload->>'client', ''), v_op,
          CASE WHEN coalesce(p_payload->>'report_id', '') ~ '^[0-9]{1,18}$' THEN (p_payload->>'report_id')::bigint END,
          nullif(p_payload->>'report_name', ''), nullif(p_payload->>'tool', ''),
          CASE WHEN coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'instance_id')::int END,
          nullif(p_payload->>'instance', ''), v_out, left(p_payload->>'detail', 4000),
          CASE WHEN coalesce(p_payload->>'rows', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'rows')::int END,
          CASE WHEN coalesce(p_payload->>'duration_ms', '') ~ '^[0-9]{1,9}$' THEN (p_payload->>'duration_ms')::int END,
          left(p_payload->>'statement', 200000), p_payload->'params')
  RETURNING log_id INTO v_id;
  RETURN v_id;
END $$;
