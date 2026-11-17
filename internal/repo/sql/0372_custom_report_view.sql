-- 0372 (parity set 3, the custom report view; the lead 11-17 03:15, brief L174): the view's own settings of a custom
-- report in ONE jsonb column.
--
--   custom_reports.view        NEW jsonb NOT NULL DEFAULT '{}', CHECK an object: who sees the report (visibility
--                              {engines, tags, include, exclude}; access, a LIST of role names - Allen's Q160, the
--                              per-feature roles or the three, is open and either answer fits this column), its result
--                              sets [{set, name, in_all}], its pair, url / url_label, status_from_messages, collections,
--                              the saved layout, links and charts - each key validated in Go (internal/web
--                              q_customreports.go validReport) as params / columns / rules are. An existing report holds
--                              '{}' and renders exactly as before this file.
--   import_custom_report       re-made WHOLE from its only text, 0106_custom_reports.sql:88-267 (e2ae04dd; no branch
--                              re-creates it - git log --all -S on 11-17): 'view is an object' refused like the arrays,
--                              view written on add and edit, nothing else changed. JOIN LINE (j17): a branch that
--                              re-creates import_custom_report after this conflicts here and keeps 'view'.
--
-- Locks: ADD COLUMN with a constant default and a CHECK takes ACCESS EXCLUSIVE on custom_reports for the column and the
-- CHECK's scan (a small table: one row per report); CREATE OR REPLACE FUNCTION locks the function only.

ALTER TABLE pgvigil.custom_reports ADD COLUMN IF NOT EXISTS view jsonb NOT NULL DEFAULT '{}';
ALTER TABLE pgvigil.custom_reports DROP CONSTRAINT IF EXISTS custom_reports_view_check;
ALTER TABLE pgvigil.custom_reports ADD CONSTRAINT custom_reports_view_check CHECK (jsonb_typeof(view) = 'object');
COMMENT ON COLUMN pgvigil.custom_reports.view IS 'The view''s own settings (visibility, access as a list of role names, result sets, pair, url, layout, links, charts): an object, ''{}'' = as before 0372.';

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
    ELSIF coalesce(jsonb_typeof(p_payload->'view'), 'object') <> 'object' THEN
      v_why := 'view is an object';
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
      INSERT INTO pgvigil.custom_reports (name, description, folder, engine, kind, body, params, columns, rules, view, timeout_secs,
                                          max_rows, created_by, created_at, updated_by, updated_at)
      VALUES (v_name, nullif(btrim(coalesce(p_payload->>'description', '')), ''), v_folder, p_payload->>'engine',
              p_payload->>'kind', p_payload->>'body', coalesce(p_payload->'params', '[]'), coalesce(p_payload->'columns', '[]'),
              coalesce(p_payload->'rules', '[]'), coalesce(p_payload->'view', '{}'), v_timeout, v_rows, v_user, p_at, v_user, p_at)
      RETURNING report_id, version INTO v_id, v_ver;
      v_done := format('report %s %L added', v_id, v_name);
    WHEN 'edit' THEN
      UPDATE pgvigil.custom_reports
         SET name = v_name, description = nullif(btrim(coalesce(p_payload->>'description', '')), ''), folder = v_folder,
             engine = p_payload->>'engine', kind = p_payload->>'kind', body = p_payload->>'body',
             params = coalesce(p_payload->'params', '[]'), columns = coalesce(p_payload->'columns', '[]'),
             rules = coalesce(p_payload->'rules', '[]'), view = coalesce(p_payload->'view', '{}'), timeout_secs = v_timeout, max_rows = v_rows,
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
