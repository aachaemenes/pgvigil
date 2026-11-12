-- 0103 the PostgreSQL twins of DBA Dash's backup, role-change and state cells (task 162; the mirror rows D12, D14, D17,
-- D18, E118, E203, E301, E302, E304, E305, E307, E308).
--   1. pg_thresholds: thresholds set from the UI at four levels (root, a tag, an instance, a database), one live row per
--      place and key; an edit ends the row and writes its successor (import_pg_threshold, the actions door's audit
--      login). pg_threshold_keys names each key, its unit, its direction and its built-in default; pg_threshold()
--      resolves an instance's (and a database's) value: database, instance, tag (the first of the instance's tags in
--      sort order that has a row), root, the default.
--   2. The backup_tools collection (internal/collect/backups_tools.go): pg_backup_detect (what the server's commands
--      name, the standby's receiver), pg_backup_tools (one row per tool and stanza or server read), pg_base_backups
--      (each backup listed, absent once a read no longer lists it), pg_wal_replay (a standby's replay, the newest read).
--   3. The rolechange collection (internal/collect/rolechange.go): pg_role_state (the newest role, timeline and system
--      identifier), pg_role_changes (one row per change, kept whole like the audits), pg_patroni_members / pg_patroni_read.
--   4. Views: pg_base_backup_status (per instance and tool), pg_crashes (one row per crash restart from the log's crash
--      events, with the acknowledgement that covers it), pg_stmt_store_state (pg_stat_statements' state), pg_amcheck_age
--      (the last clean amcheck per database), pg_uptime_state, pg_replication_links (the fleet's primaries and standbys by
--      system identifier); pg_backups_checks (the Summary's rows, check_group named) and pg_backups_findings (the join
--      UNION ALLs it into pgvigil.findings).
--   5. backup_status, backup_rule_hits and backup_findings (0022) again, the archive-age and retention thresholds taken
--      from pg_thresholds when the UI set one (the config file's backups.archive_warn_minutes otherwise, as before).
-- Retention: pg_role_changes and pg_thresholds hold a row per change and are not purged; the current tables lose their
-- absent rows past the retention (the purge lines are the join's: docs/backups-postgres.md).

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Thresholds
CREATE TABLE IF NOT EXISTS pgvigil.pg_threshold_keys (
  key          text PRIMARY KEY,
  label        text NOT NULL,
  unit         text NOT NULL CHECK (unit IN ('minutes', 'hours', 'days')),
  direction    text NOT NULL CHECK (direction IN ('over', 'under')),   -- over: the value past warn is bad; under: below it
  warn_default numeric,
  crit_default numeric,
  levels       text[] NOT NULL,
  max_value    numeric NOT NULL
);
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('uptime',          'Uptime: time since the server started',                'hours',   'under', 48,   12,   '{root,tag,instance}', 87600),
  ('full_backup_age', 'Base backups: the newest full backup''s age',          'hours',   'over',  192,  360,  '{root,tag,instance}', 87600),
  ('backup_age',      'Base backups: the newest backup''s age (any kind)',     'hours',   'over',  NULL, NULL, '{root,tag,instance}', 87600),
  ('archive_age',     'WAL archive: the last archived file''s age while WAL waits', 'minutes', 'over', 60, NULL, '{root,tag,instance}', 525600),
  ('retention',       'RDS / Aurora: the backup retention',                    'days',    'under', 7,    0,    '{root,tag,instance}', 35),
  ('replay_delay',    'Log shipping: a file-fed standby''s replay delay',      'minutes', 'over',  60,   240,  '{root,tag,instance}', 525600),
  ('amcheck_age',     'amcheck: the last clean run''s age per database',      'days',    'over',  7,    14,   '{root,tag,instance,database}', 3650),
  ('crash',           'Crashes: time since the last crash restart',           'hours',   'under', 168,  24,   '{root,tag,instance}', 87600)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

CREATE TABLE IF NOT EXISTS pgvigil.pg_thresholds (
  threshold_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  key           text NOT NULL REFERENCES pgvigil.pg_threshold_keys(key),
  level         text NOT NULL CHECK (level IN ('root', 'tag', 'instance', 'database')),
  instance_id   int REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  tag           text CHECK (length(tag) BETWEEN 1 AND 200),        -- the written form: prod, env:prod
  datname       text CHECK (length(datname) BETWEEN 1 AND 63),
  warn          numeric CHECK (warn >= 0),
  crit          numeric CHECK (crit >= 0),
  created_by    text NOT NULL,
  created_at    timestamptz NOT NULL,
  client        text,
  replaces      bigint,
  ended_by      text,
  ended_at      timestamptz,
  CONSTRAINT "the root level names nothing" CHECK (level <> 'root' OR (instance_id IS NULL AND tag IS NULL AND datname IS NULL)),
  CONSTRAINT "a tag level names its tag only" CHECK (level <> 'tag' OR (tag IS NOT NULL AND instance_id IS NULL AND datname IS NULL)),
  CONSTRAINT "an instance level names its instance only" CHECK (level <> 'instance' OR (instance_id IS NOT NULL AND tag IS NULL AND datname IS NULL)),
  CONSTRAINT "a database level names its instance and database" CHECK (level <> 'database' OR (instance_id IS NOT NULL AND datname IS NOT NULL AND tag IS NULL))
);
CREATE UNIQUE INDEX IF NOT EXISTS pg_thresholds_live_idx
  ON pgvigil.pg_thresholds (key, level, coalesce(instance_id, 0), coalesce(tag, ''), coalesce(datname, '')) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.pg_thresholds IS 'PostgreSQL state thresholds at the root, tag, instance and database level; written through import_pg_threshold only, a change ends the row and writes its successor.';

-- import_pg_threshold: one attempt from the UI. p_payload: {op: set | inherit, key, level, instance_id, tag, datname,
-- warn, crit, ui_user, client}. A warn or crit left out or null is not judged at that level (a key whose default has
-- both, set with one, judges only that one). Answers {outcome: done | refused, detail, threshold_id}; a refusal writes
-- nothing.
CREATE OR REPLACE FUNCTION pgvigil.import_pg_threshold(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_key   text := p_payload->>'key';
  v_level text := p_payload->>'level';
  v_inst  int;
  v_tag   text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_db    text := nullif(p_payload->>'datname', '');
  v_k     pgvigil.pg_threshold_keys%ROWTYPE;
  v_warn  numeric;
  v_crit  numeric;
  v_why   text;
  v_old   bigint;
  v_new   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_pg_threshold: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
  END IF;
  SELECT * INTO v_k FROM pgvigil.pg_threshold_keys WHERE key = v_key;
  IF v_op IS NULL OR v_op NOT IN ('set', 'inherit') THEN
    v_why := 'op must be set or inherit';
  ELSIF v_k.key IS NULL THEN
    v_why := format('no threshold key %s (known: %s)', coalesce(v_key, '(none)'), (SELECT string_agg(key, ', ' ORDER BY key) FROM pgvigil.pg_threshold_keys));
  ELSIF v_level IS NULL OR NOT (v_level = ANY (v_k.levels)) THEN
    v_why := format('%s is set at the levels %s', v_key, array_to_string(v_k.levels, ', '));
  ELSIF v_level IN ('instance', 'database') AND (v_inst IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = v_inst AND i.engine = 'postgres')) THEN
    v_why := format('no PostgreSQL instance %s', coalesce(p_payload->>'instance_id', '(none)'));
  ELSIF v_level = 'tag' AND (v_tag IS NULL OR length(v_tag) > 200) THEN
    v_why := 'a tag level names its tag (200 characters at most)';
  ELSIF v_level = 'database' AND (v_db IS NULL OR length(v_db) > 63) THEN
    v_why := 'a database level names its database (63 characters at most)';
  ELSIF v_op = 'set' THEN
    FOR i IN 1..2 LOOP
      DECLARE v text := p_payload->>(CASE i WHEN 1 THEN 'warn' ELSE 'crit' END);
      BEGIN
        IF v IS NOT NULL AND v !~ '^[0-9]{1,7}(\.[0-9]{1,2})?$' THEN
          v_why := format('%s must be a number from 0 to %s (%s), or null', CASE i WHEN 1 THEN 'warn' ELSE 'crit' END, v_k.max_value, v_k.unit);
        ELSIF v IS NOT NULL AND v::numeric > v_k.max_value THEN
          v_why := format('%s must be a number from 0 to %s (%s), or null', CASE i WHEN 1 THEN 'warn' ELSE 'crit' END, v_k.max_value, v_k.unit);
        ELSIF v IS NOT NULL AND v_key = 'archive_age' AND (v !~ '^[0-9]+$' OR v::numeric < 1) THEN
          -- 0022's rule takes whole minutes (archive_warn_minutes is an int column there)
          v_why := format('archive_age takes whole minutes from 1 to %s, or null', v_k.max_value);
        END IF;
      END;
      EXIT WHEN v_why IS NOT NULL;
    END LOOP;
    IF v_why IS NULL THEN
      v_warn := (p_payload->>'warn')::numeric;
      v_crit := (p_payload->>'crit')::numeric;
      IF v_warn IS NULL AND v_crit IS NULL THEN
        v_why := 'no threshold is set: to take the level above, inherit';
      ELSIF v_warn IS NOT NULL AND v_crit IS NOT NULL AND v_k.direction = 'over' AND v_crit < v_warn THEN
        v_why := format('%s: critical (%s) must be at or past warning (%s): the value grows toward it', v_key, v_crit, v_warn);
      ELSIF v_warn IS NOT NULL AND v_crit IS NOT NULL AND v_k.direction = 'under' AND v_crit > v_warn THEN
        v_why := format('%s: critical (%s) must be at or under warning (%s): the value falls toward it', v_key, v_crit, v_warn);
      END IF;
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_level = 'root' THEN v_inst := NULL; v_tag := NULL; v_db := NULL;
  ELSIF v_level = 'tag' THEN v_inst := NULL; v_db := NULL;
  ELSIF v_level = 'instance' THEN v_tag := NULL; v_db := NULL;
  ELSE v_tag := NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.pg_thresholds'), hashtext(v_key || '|' || v_level || '|' || coalesce(v_inst, 0) || '|' || coalesce(v_tag, '') || '|' || coalesce(v_db, '')));
  SELECT t.threshold_id INTO v_old FROM pgvigil.pg_thresholds t
   WHERE t.ended_at IS NULL AND t.key = v_key AND t.level = v_level AND coalesce(t.instance_id, 0) = coalesce(v_inst, 0)
     AND coalesce(t.tag, '') = coalesce(v_tag, '') AND coalesce(t.datname, '') = coalesce(v_db, '');
  IF v_op = 'inherit' AND v_old IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this level has no threshold of its own: it inherits already');
  END IF;
  UPDATE pgvigil.pg_thresholds SET ended_by = v_user, ended_at = p_at WHERE threshold_id = v_old;
  IF v_op = 'inherit' THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the level above applies', 'threshold_id', v_old);
  END IF;
  INSERT INTO pgvigil.pg_thresholds (key, level, instance_id, tag, datname, warn, crit, created_by, created_at, client, replaces)
  VALUES (v_key, v_level, v_inst, v_tag, v_db, v_warn, v_crit, v_user, p_at, nullif(p_payload->>'client', ''), v_old)
  RETURNING threshold_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'threshold_id', v_new);
END $$;

-- pg_threshold: the value in force for an instance (and a database): its level and the row that set it (NULL = the
-- built-in default). One row always.
CREATE OR REPLACE FUNCTION pgvigil.pg_threshold(p_instance_id int, p_key text, p_datname text DEFAULT NULL)
RETURNS TABLE (warn numeric, crit numeric, level text, tag text, threshold_id bigint) LANGUAGE sql STABLE AS $$
  SELECT x.warn, x.crit, x.level, x.tag, x.threshold_id
    FROM (
      SELECT t.warn, t.crit, t.level, t.tag, t.threshold_id,
             CASE t.level WHEN 'database' THEN 1 WHEN 'instance' THEN 2 WHEN 'tag' THEN 3 ELSE 4 END AS rank
        FROM pgvigil.pg_thresholds t
       WHERE t.ended_at IS NULL AND t.key = p_key
         AND (t.level = 'root'
              OR (t.level = 'instance' AND t.instance_id = p_instance_id)
              OR (t.level = 'database' AND t.instance_id = p_instance_id AND t.datname = p_datname)
              OR (t.level = 'tag' AND t.tag = ANY ((SELECT m.tags FROM pgvigil.instance_tags_merged m WHERE m.instance_id = p_instance_id)::text[])))
      UNION ALL
      SELECT k.warn_default, k.crit_default, 'default', NULL, NULL, 9 FROM pgvigil.pg_threshold_keys k WHERE k.key = p_key
    ) x
   ORDER BY x.rank, x.tag NULLS LAST
   LIMIT 1
$$;

-- pg_threshold_rows: every live threshold row with its instance's name, for the Thresholds page.
CREATE OR REPLACE VIEW pgvigil.pg_threshold_rows AS
SELECT t.threshold_id, t.key, k.label, k.unit, k.direction, t.level, t.instance_id, i.name AS instance, t.tag, t.datname,
       t.warn, t.crit, t.created_by, t.created_at, t.replaces
  FROM pgvigil.pg_thresholds t
  JOIN pgvigil.pg_threshold_keys k USING (key)
  LEFT JOIN pgvigil.instances i ON i.instance_id = t.instance_id
 WHERE t.ended_at IS NULL;

-- ---------------------------------------------------------------------------------------------------------------
-- 2. The backup_tools collection
CREATE TABLE IF NOT EXISTS pgvigil.pg_backup_detect (
  instance_id          int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at          timestamptz NOT NULL,
  is_replica           boolean,
  archive_mode         text,
  archive_command_set  boolean,
  restore_command_set  boolean,
  has_receiver         boolean,
  wal_segment_bytes    bigint,
  tools                int
);

CREATE TABLE IF NOT EXISTS pgvigil.pg_backup_tools (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  tool            text NOT NULL CHECK (tool IN ('pgbackrest', 'barman', 'barman-cloud')),
  name            text NOT NULL,          -- the stanza (pgBackRest) or the server (barman)
  snapshot_at     timestamptz NOT NULL,
  named_by        text,                   -- archive_command | restore_command
  state           text NOT NULL CHECK (state IN ('ok', 'error', 'no_binary')),
  message         text,
  status_code     int,
  status_message  text,
  backup_count    int,
  archive_min     text,
  archive_max     text,
  system_id       text,
  db_version      text,
  read_ms         bigint,
  is_present      boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, tool, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.pg_base_backups (
  instance_id        int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  tool               text NOT NULL,
  name               text NOT NULL,
  label              text NOT NULL,
  snapshot_at        timestamptz NOT NULL,
  first_seen         timestamptz NOT NULL,
  backup_type        text,               -- pgBackRest full | diff | incr; barman full | incremental | rsync | snapshot
  status             text NOT NULL CHECK (status IN ('ok', 'error', 'running')),
  tool_status        text,               -- barman's own word (DONE, FAILED, ...)
  retention_status   text,
  started_at         timestamptz,
  stopped_at         timestamptz,
  db_size_bytes      bigint,             -- the cluster's size the backup holds
  backup_bytes       bigint,             -- what this backup copied (pgBackRest delta)
  repo_bytes         bigint,             -- its size in the repository (compressed)
  repo_delta_bytes   bigint,
  wal_start          text,
  wal_stop           text,
  wal_since_segments bigint,             -- the WAL archived after the backup's last segment (pgBackRest)
  wal_since_bytes    bigint,             -- ... in bytes; barman: the WAL belonging to this backup
  prior              text,
  is_present         boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, tool, name, label)
);
CREATE INDEX IF NOT EXISTS pg_base_backups_stop_idx ON pgvigil.pg_base_backups (instance_id, stopped_at DESC);

CREATE TABLE IF NOT EXISTS pgvigil.pg_wal_replay (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at        timestamptz NOT NULL,
  has_receiver       boolean,
  last_replay_at     timestamptz,
  server_now         timestamptz,
  replay_delay_secs  double precision,
  replay_lsn         pg_lsn,
  receive_lsn        pg_lsn,
  replay_paused      boolean,
  is_present         boolean NOT NULL DEFAULT true   -- false once the server is no longer a standby
);

-- payload rows: {kind:'detect'}, {kind:'tool'} per tool, {kind:'backup'} per backup, {kind:'replay'} on a standby,
-- {kind:'collector_error'} (not stored). A tool read that answered marks its stanza's unlisted backups absent; a tool
-- read that failed or a tool no longer named leaves its backups as they were (the tool row says why).
CREATE OR REPLACE FUNCTION pgvigil.import_backup_tools(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_backup_tools'), p_instance_id);
  INSERT INTO pgvigil.pg_backup_detect AS d (instance_id, snapshot_at, is_replica, archive_mode, archive_command_set, restore_command_set, has_receiver, wal_segment_bytes, tools)
  SELECT p_instance_id, p_snapshot_at, (r->>'is_replica')::boolean, r->>'archive_mode', (r->>'archive_command_set')::boolean,
         (r->>'restore_command_set')::boolean, (r->>'has_receiver')::boolean, (r->>'wal_segment_bytes')::bigint, (r->>'tools')::int
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'detect'
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, is_replica = EXCLUDED.is_replica, archive_mode = EXCLUDED.archive_mode,
    archive_command_set = EXCLUDED.archive_command_set, restore_command_set = EXCLUDED.restore_command_set, has_receiver = EXCLUDED.has_receiver,
    wal_segment_bytes = EXCLUDED.wal_segment_bytes, tools = EXCLUDED.tools;

  -- tools the detect row no longer names go absent (only when a detect row came: a failed read keeps them)
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'detect') THEN
    UPDATE pgvigil.pg_backup_tools t SET is_present = false
     WHERE t.instance_id = p_instance_id AND t.is_present
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'tool' AND r->>'tool' = t.tool AND r->>'name' = t.name);
  END IF;

  INSERT INTO pgvigil.pg_backup_tools AS t (instance_id, tool, name, snapshot_at, named_by, state, message, status_code, status_message, backup_count,
                                             archive_min, archive_max, system_id, db_version, read_ms, is_present)
  SELECT p_instance_id, r->>'tool', r->>'name', p_snapshot_at, r->>'named_by', r->>'state', left(r->>'message', 1000), (r->>'status_code')::int,
         left(r->>'status_message', 1000), (r->>'backup_count')::int, r->>'archive_min', r->>'archive_max', r->>'system_id', r->>'db_version',
         (r->>'read_ms')::bigint, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'tool'
  ON CONFLICT (instance_id, tool, name) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, named_by = EXCLUDED.named_by, state = EXCLUDED.state,
    message = EXCLUDED.message, status_code = EXCLUDED.status_code, status_message = EXCLUDED.status_message,
    -- a failed read keeps what the last good read said of the archive and the backups
    backup_count = CASE WHEN EXCLUDED.state = 'ok' OR EXCLUDED.status_code IN (0, 2) THEN EXCLUDED.backup_count ELSE t.backup_count END,
    archive_min = CASE WHEN EXCLUDED.state = 'ok' OR EXCLUDED.status_code IN (0, 2) THEN EXCLUDED.archive_min ELSE t.archive_min END,
    archive_max = CASE WHEN EXCLUDED.state = 'ok' OR EXCLUDED.status_code IN (0, 2) THEN EXCLUDED.archive_max ELSE t.archive_max END,
    system_id = coalesce(EXCLUDED.system_id, t.system_id), db_version = coalesce(EXCLUDED.db_version, t.db_version),
    read_ms = EXCLUDED.read_ms, is_present = true;

  INSERT INTO pgvigil.pg_base_backups AS b (instance_id, tool, name, label, snapshot_at, first_seen, backup_type, status, tool_status, retention_status,
                                             started_at, stopped_at, db_size_bytes, backup_bytes, repo_bytes, repo_delta_bytes, wal_start, wal_stop,
                                             wal_since_segments, wal_since_bytes, prior, is_present)
  SELECT p_instance_id, r->>'tool', r->>'name', r->>'label', p_snapshot_at, p_snapshot_at, r->>'backup_type', coalesce(r->>'status', 'ok'), r->>'tool_status',
         r->>'retention_status', (r->>'started_at')::timestamptz, (r->>'stopped_at')::timestamptz, (r->>'db_size_bytes')::bigint, (r->>'backup_bytes')::bigint,
         (r->>'repo_bytes')::bigint, (r->>'repo_delta_bytes')::bigint, r->>'wal_start', r->>'wal_stop', (r->>'wal_since_segments')::bigint,
         (r->>'wal_since_bytes')::bigint, r->>'prior', true
    FROM (SELECT DISTINCT ON (r->>'tool', r->>'name', r->>'label') r FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'backup' AND coalesce(r->>'label', '') <> '') x
  ON CONFLICT (instance_id, tool, name, label) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, backup_type = EXCLUDED.backup_type, status = EXCLUDED.status,
    tool_status = EXCLUDED.tool_status, retention_status = EXCLUDED.retention_status, started_at = EXCLUDED.started_at, stopped_at = EXCLUDED.stopped_at,
    db_size_bytes = EXCLUDED.db_size_bytes, backup_bytes = EXCLUDED.backup_bytes, repo_bytes = EXCLUDED.repo_bytes, repo_delta_bytes = EXCLUDED.repo_delta_bytes,
    wal_start = EXCLUDED.wal_start, wal_stop = EXCLUDED.wal_stop, wal_since_segments = EXCLUDED.wal_since_segments, wal_since_bytes = EXCLUDED.wal_since_bytes,
    prior = EXCLUDED.prior, is_present = true;

  -- a tool that answered (state ok, or pgBackRest's status 0, or 2 = no valid backup) names every label it lists
  -- (the tool row's labels; the backup rows are the newest of them): the rest of its stanza's are gone, expired by its
  -- retention. Any other status (1 missing stanza path, 99 other: an unreadable repository) keeps them.
  UPDATE pgvigil.pg_base_backups b SET is_present = false
   WHERE b.instance_id = p_instance_id AND b.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r
                  WHERE r->>'kind' = 'tool' AND r->>'tool' = b.tool AND r->>'name' = b.name
                    AND (r->>'state' = 'ok' OR (r->>'status_code')::int IN (0, 2))
                    AND NOT coalesce(r->'labels' ? b.label, false)
                    AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x
                                     WHERE x->>'kind' = 'backup' AND x->>'tool' = b.tool AND x->>'name' = b.name AND x->>'label' = b.label));

  INSERT INTO pgvigil.pg_wal_replay AS w (instance_id, snapshot_at, has_receiver, last_replay_at, server_now, replay_delay_secs, replay_lsn, receive_lsn, replay_paused, is_present)
  SELECT p_instance_id, p_snapshot_at, (r->>'has_receiver')::boolean, (r->>'last_replay_at')::timestamptz, (r->>'server_now')::timestamptz,
         (r->>'replay_delay_secs')::float8, (r->>'replay_lsn')::pg_lsn, (r->>'receive_lsn')::pg_lsn, (r->>'replay_paused')::boolean, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'replay'
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, has_receiver = EXCLUDED.has_receiver, last_replay_at = EXCLUDED.last_replay_at,
    server_now = EXCLUDED.server_now, replay_delay_secs = EXCLUDED.replay_delay_secs, replay_lsn = EXCLUDED.replay_lsn, receive_lsn = EXCLUDED.receive_lsn,
    replay_paused = EXCLUDED.replay_paused, is_present = true;
  -- a detect row that says primary ends the standby's replay row
  UPDATE pgvigil.pg_wal_replay w SET is_present = false, snapshot_at = p_snapshot_at
   WHERE w.instance_id = p_instance_id AND w.is_present
     AND EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'detect' AND NOT (r->>'is_replica')::boolean);
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The rolechange collection
CREATE TABLE IF NOT EXISTS pgvigil.pg_role_state (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  read_at            timestamptz NOT NULL,
  server_now         timestamptz,
  is_replica         boolean NOT NULL,
  timeline_id        bigint,
  timeline_source    text,
  system_identifier  text,
  postmaster_start   timestamptz,
  cluster_name       text,
  history_file       text,
  history_at         timestamptz,
  since              timestamptz,            -- when the current role and timeline began (NULL: before the first read)
  since_source       text,
  first_read_at      timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.pg_role_changes (
  change_id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  instance_id          int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  changed_at           timestamptz NOT NULL,
  changed_at_source    text NOT NULL CHECK (changed_at_source IN ('history file', 'postmaster start', 'read')),
  detected_at          timestamptz NOT NULL,       -- the read that saw it
  prev_read_at         timestamptz NOT NULL,       -- the read before: the change lies between the two
  change               text NOT NULL CHECK (change IN ('promotion', 'demotion', 'timeline', 'another cluster')),
  from_role            text NOT NULL,
  to_role              text NOT NULL,
  from_timeline        bigint,
  to_timeline          bigint,
  from_system_identifier text,
  to_system_identifier text,
  postmaster_restarted boolean NOT NULL,
  held_secs            bigint                      -- how long the role before it was held (NULL: since before the first read)
);
CREATE INDEX IF NOT EXISTS pg_role_changes_idx ON pgvigil.pg_role_changes (instance_id, changed_at DESC);
COMMENT ON TABLE pgvigil.pg_role_changes IS 'Every promotion, demotion, timeline change and system-identifier change pgvigil saw, with its time; not purged.';

CREATE TABLE IF NOT EXISTS pgvigil.pg_patroni_read (
  instance_id  int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at  timestamptz NOT NULL,
  url          text,
  ok           boolean NOT NULL,
  message      text,
  scope        text,
  members      int
);
CREATE TABLE IF NOT EXISTS pgvigil.pg_patroni_members (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  member       text NOT NULL,
  snapshot_at  timestamptz NOT NULL,
  scope        text,
  role         text,
  state        text,
  host         text,
  port         int,
  timeline     bigint,
  lag_bytes    bigint,
  lag_text     text,
  api_url      text,
  is_present   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, member)
);

-- payload rows: {kind:'role'} once, {kind:'patroni_read'} and {kind:'patroni'} per member when Patroni was asked.
CREATE OR REPLACE FUNCTION pgvigil.import_rolechange(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r       jsonb;
  o       pgvigil.pg_role_state%ROWTYPE;
  v_rep   boolean;
  v_tl    bigint;
  v_sys   text;
  v_pm    timestamptz;
  v_now   timestamptz;
  v_hat   timestamptz;
  v_htl   bigint;
  v_kind  text;
  v_at    timestamptz;
  v_src   text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_rolechange'), p_instance_id);
  SELECT x INTO r FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'role' LIMIT 1;
  IF r IS NOT NULL THEN
    v_rep := (r->>'is_replica')::boolean;
    v_tl := (r->>'timeline_id')::bigint;
    v_sys := r->>'system_identifier';
    v_pm := (r->>'postmaster_start')::timestamptz;
    v_now := coalesce((r->>'server_now')::timestamptz, p_snapshot_at);
    v_hat := (r->>'history_at')::timestamptz;
    v_htl := (r->>'history_timeline')::bigint;
    SELECT * INTO o FROM pgvigil.pg_role_state WHERE instance_id = p_instance_id FOR UPDATE;
    IF o.instance_id IS NULL THEN
      INSERT INTO pgvigil.pg_role_state (instance_id, read_at, server_now, is_replica, timeline_id, timeline_source, system_identifier, postmaster_start,
                                         cluster_name, history_file, history_at, since, since_source, first_read_at)
      VALUES (p_instance_id, p_snapshot_at, v_now, v_rep, v_tl, r->>'timeline_source', v_sys, v_pm, r->>'cluster_name', r->>'history_file', v_hat,
              -- a primary on a timeline above 1 was promoted when its history file was written
              CASE WHEN NOT v_rep AND v_htl IS NOT NULL AND v_htl = v_tl THEN v_hat END,
              CASE WHEN NOT v_rep AND v_htl IS NOT NULL AND v_htl = v_tl THEN 'history file' END, p_snapshot_at);
    ELSE
      v_kind := CASE
        WHEN v_sys IS NOT NULL AND o.system_identifier IS NOT NULL AND v_sys <> o.system_identifier THEN 'another cluster'
        WHEN o.is_replica AND NOT v_rep THEN 'promotion'
        WHEN NOT o.is_replica AND v_rep THEN 'demotion'
        -- a standby's checkpoint timeline trails its replay: only a rise counts (from any source: the receiver restarts
        -- in a failover, so the source flips exactly then); a lower reading is the trailing one and is not kept
        WHEN v_tl IS NOT NULL AND o.timeline_id IS NOT NULL AND v_tl > o.timeline_id THEN 'timeline'
      END;
      IF v_kind IS NOT NULL THEN
        -- the time: the new timeline's history file when it was written between the two reads (the server's clock),
        -- else the postmaster's start when the server restarted between them, else this read
        IF v_kind IN ('promotion', 'timeline') AND v_htl IS NOT NULL AND v_htl = v_tl AND v_hat > coalesce(o.server_now, o.read_at) - interval '1 minute'
           AND v_hat <= v_now + interval '1 minute' THEN
          v_at := v_hat; v_src := 'history file';
        ELSIF v_pm IS DISTINCT FROM o.postmaster_start AND v_pm > coalesce(o.server_now, o.read_at) - interval '1 minute' AND v_pm <= v_now THEN
          v_at := v_pm; v_src := 'postmaster start';
        ELSE
          v_at := p_snapshot_at; v_src := 'read';
        END IF;
        INSERT INTO pgvigil.pg_role_changes (instance_id, changed_at, changed_at_source, detected_at, prev_read_at, change, from_role, to_role,
                                             from_timeline, to_timeline, from_system_identifier, to_system_identifier, postmaster_restarted, held_secs)
        VALUES (p_instance_id, v_at, v_src, p_snapshot_at, o.read_at, v_kind,
                CASE WHEN o.is_replica THEN 'standby' ELSE 'primary' END, CASE WHEN v_rep THEN 'standby' ELSE 'primary' END,
                o.timeline_id, v_tl, o.system_identifier, v_sys, v_pm IS DISTINCT FROM o.postmaster_start,
                CASE WHEN o.since IS NOT NULL THEN greatest(0, extract(epoch FROM v_at - o.since))::bigint END);
      END IF;
      UPDATE pgvigil.pg_role_state SET read_at = p_snapshot_at, server_now = v_now, is_replica = v_rep,
             timeline_id = CASE WHEN v_kind IN ('promotion', 'demotion', 'another cluster') THEN coalesce(v_tl, o.timeline_id) ELSE greatest(o.timeline_id, v_tl) END,
             timeline_source = r->>'timeline_source', system_identifier = coalesce(v_sys, o.system_identifier), postmaster_start = v_pm,
             cluster_name = r->>'cluster_name', history_file = r->>'history_file', history_at = v_hat,
             since = CASE WHEN v_kind IS NOT NULL THEN v_at ELSE o.since END,
             since_source = CASE WHEN v_kind IS NOT NULL THEN v_src ELSE o.since_source END
       WHERE instance_id = p_instance_id;
    END IF;
  END IF;

  INSERT INTO pgvigil.pg_patroni_read AS p (instance_id, snapshot_at, url, ok, message, scope, members)
  SELECT p_instance_id, p_snapshot_at, x->>'url', coalesce((x->>'ok')::boolean, false), left(x->>'message', 500), x->>'scope', (x->>'members')::int
    FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'patroni_read'
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, url = EXCLUDED.url, ok = EXCLUDED.ok, message = EXCLUDED.message,
    scope = EXCLUDED.scope, members = EXCLUDED.members;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'patroni_read' AND (x->>'ok')::boolean) THEN
    INSERT INTO pgvigil.pg_patroni_members AS m (instance_id, member, snapshot_at, scope, role, state, host, port, timeline, lag_bytes, lag_text, api_url, is_present)
    SELECT p_instance_id, x->>'member', p_snapshot_at, x->>'scope', x->>'role', x->>'state', x->>'host', (x->>'port')::int, (x->>'timeline')::bigint,
           (x->>'lag_bytes')::bigint, x->>'lag_text', x->>'api_url', true
      FROM (SELECT DISTINCT ON (x->>'member') x FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'patroni') y
    ON CONFLICT (instance_id, member) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, scope = EXCLUDED.scope, role = EXCLUDED.role, state = EXCLUDED.state,
      host = EXCLUDED.host, port = EXCLUDED.port, timeline = EXCLUDED.timeline, lag_bytes = EXCLUDED.lag_bytes, lag_text = EXCLUDED.lag_text,
      api_url = EXCLUDED.api_url, is_present = true;
    UPDATE pgvigil.pg_patroni_members m SET is_present = false
     WHERE m.instance_id = p_instance_id AND m.is_present AND m.snapshot_at < p_snapshot_at;
  ELSIF r IS NOT NULL THEN
    -- Patroni did not answer (the read row says why) or no Patroni session any more: the members read before are not
    -- shown as its state
    UPDATE pgvigil.pg_patroni_members m SET is_present = false WHERE m.instance_id = p_instance_id AND m.is_present;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'patroni_read') THEN
      DELETE FROM pgvigil.pg_patroni_read WHERE instance_id = p_instance_id;
    END IF;
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Views
-- pg_base_backup_status: per instance and tool read, the newest backup that ended well, the newest full, their ages at
-- the read, the WAL since the newest, the thresholds in force.
CREATE OR REPLACE VIEW pgvigil.pg_base_backup_status AS
SELECT t.instance_id, i.name AS instance, t.tool, t.name, t.state, t.message, t.status_code, t.status_message, t.named_by, t.backup_count,
       t.archive_min, t.archive_max, t.system_id, t.db_version, t.snapshot_at AS read_at,
       nb.label AS last_label, nb.backup_type AS last_type, nb.started_at AS last_started_at, nb.stopped_at AS last_stopped_at,
       nb.db_size_bytes AS last_db_size_bytes, nb.backup_bytes AS last_backup_bytes, nb.repo_bytes AS last_repo_bytes,
       nb.wal_since_segments, nb.wal_since_bytes,
       round(extract(epoch FROM t.snapshot_at - nb.stopped_at)::numeric / 3600, 1) AS last_age_h,
       nf.label AS full_label, nf.stopped_at AS full_stopped_at, nf.db_size_bytes AS full_db_size_bytes,
       round(extract(epoch FROM t.snapshot_at - nf.stopped_at)::numeric / 3600, 1) AS full_age_h,
       (SELECT count(*) FROM pgvigil.pg_base_backups e WHERE e.instance_id = t.instance_id AND e.tool = t.tool AND e.name = t.name AND e.is_present AND e.status = 'error') AS failed_listed,
       fa.warn AS full_warn_h, fa.crit AS full_crit_h, fa.level AS full_level, ba.warn AS any_warn_h, ba.crit AS any_crit_h, ba.level AS any_level,
       -- the ages unrounded: the rules compare these (a tenth of an hour rounds a small threshold away)
       extract(epoch FROM t.snapshot_at - nb.stopped_at) AS last_age_s, extract(epoch FROM t.snapshot_at - nf.stopped_at) AS full_age_s
  FROM pgvigil.pg_backup_tools t
  JOIN pgvigil.instances i ON i.instance_id = t.instance_id AND i.is_active
  LEFT JOIN LATERAL (SELECT b.* FROM pgvigil.pg_base_backups b WHERE b.instance_id = t.instance_id AND b.tool = t.tool AND b.name = t.name AND b.is_present AND b.status = 'ok'
                      ORDER BY b.stopped_at DESC NULLS LAST LIMIT 1) nb ON true
  LEFT JOIN LATERAL (SELECT b.* FROM pgvigil.pg_base_backups b WHERE b.instance_id = t.instance_id AND b.tool = t.tool AND b.name = t.name AND b.is_present AND b.status = 'ok'
                        AND b.backup_type IN ('full', 'rsync', 'snapshot') ORDER BY b.stopped_at DESC NULLS LAST LIMIT 1) nf ON true
  CROSS JOIN LATERAL pgvigil.pg_threshold(t.instance_id, 'full_backup_age') fa
  CROSS JOIN LATERAL pgvigil.pg_threshold(t.instance_id, 'backup_age') ba
 WHERE t.is_present;

-- pg_wal_replay_status: a standby's replay with its threshold; caught_up when the fleet holds its primary (the same
-- system identifier, not in recovery) and the standby has replayed past the end of the primary's last archived file:
-- behind an idle primary the last replayed commit's time does not move, which is not a delay.
CREATE OR REPLACE VIEW pgvigil.pg_wal_replay_status AS
SELECT w.instance_id, i.name AS instance, w.snapshot_at AS read_at, w.has_receiver, w.last_replay_at, w.server_now, w.replay_delay_secs,
       w.replay_lsn, w.receive_lsn, w.replay_paused, d.restore_command_set,
       p.instance_id AS primary_id, p.instance AS primary_instance, p.last_archived_wal AS primary_last_archived,
       (p.archived_end IS NOT NULL AND w.replay_lsn IS NOT NULL AND (w.replay_lsn - '0/0'::pg_lsn) >= p.archived_end) AS caught_up,
       th.warn AS warn_min, th.crit AS crit_min, th.level AS threshold_level
  FROM pgvigil.pg_wal_replay w
  JOIN pgvigil.instances i ON i.instance_id = w.instance_id AND i.is_active
  LEFT JOIN pgvigil.pg_backup_detect d ON d.instance_id = w.instance_id
  LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = w.instance_id
  LEFT JOIN LATERAL (
    SELECT ps.instance_id, pi.name AS instance, a.last_archived_wal,
           CASE WHEN a.last_archived_wal ~ '^[0-9A-F]{24}' AND a.wal_segment_bytes > 0
                THEN ('x' || substr(a.last_archived_wal, 9, 8))::bit(32)::bigint * 4294967296
                     + ('x' || substr(a.last_archived_wal, 17, 8))::bit(32)::bigint * a.wal_segment_bytes + a.wal_segment_bytes END::numeric AS archived_end
      FROM pgvigil.pg_role_state ps
      JOIN pgvigil.instances pi ON pi.instance_id = ps.instance_id AND pi.is_active
      LEFT JOIN pgvigil.backup_state a ON a.instance_id = ps.instance_id AND a.kind = 'archiver' AND a.is_present
     WHERE ps.system_identifier = rs.system_identifier AND NOT ps.is_replica AND ps.instance_id <> w.instance_id
     -- after a failover two primaries can share the identifier: the one on the standby's timeline first
     ORDER BY (ps.timeline_id = rs.timeline_id) DESC NULLS LAST, ps.read_at DESC LIMIT 1) p ON true
  CROSS JOIN LATERAL pgvigil.pg_threshold(w.instance_id, 'replay_delay') th
 WHERE w.is_present;

-- pg_crashes: one row per crash restart in the log of the last 30 days: the first crash event (a backend killed by a
-- signal, the restart of the others, the kernel's kill -9) with no other within the minute before it; acked = a live
-- Summary acknowledgement of the instance's Crashes cell (check_key 'dumps', the column it shares with SQL Server's
-- memory dumps) made at or after the crash.
CREATE OR REPLACE VIEW pgvigil.pg_crashes AS
WITH e AS (
  SELECT l.instance_id, l.snapshot_at AS at, l.pid, l.detail, l.source,
         substring(l.detail FROM 'terminated by signal ([0-9]+)')::int AS signal
    FROM pgvigil.log_events l
   WHERE l.snapshot_at > now() - interval '30 days'
     AND (l.kind = 'crash' OR (l.kind = 'out_of_memory' AND l.detail ~ 'terminated by signal 9'))
), c AS (
  SELECT DISTINCT ON (e.instance_id, e.at) e.*
    FROM e
   WHERE NOT EXISTS (SELECT 1 FROM e e2 WHERE e2.instance_id = e.instance_id AND e2.at < e.at AND e2.at >= e.at - interval '1 minute')
   ORDER BY e.instance_id, e.at, (e.signal IS NOT NULL) DESC, e.detail
)
SELECT c.instance_id, i.name AS instance, c.at, c.pid, c.signal, c.detail, c.source,
       (SELECT count(*) FROM e e3 WHERE e3.instance_id = c.instance_id AND e3.at >= c.at AND e3.at < c.at + interval '1 minute') AS lines,
       a.ack_id, a.created_by AS acked_by, a.created_at AS acked_at
  FROM c
  JOIN pgvigil.instances i ON i.instance_id = c.instance_id
  LEFT JOIN LATERAL (SELECT k.ack_id, k.created_by, k.created_at FROM pgvigil.acks k
                      WHERE k.kind = 'ack' AND k.check_key = 'dumps' AND k.instance_name = i.name AND k.created_at >= c.at
                        AND pgvigil.ack_live(k.ended_at, k.starts_at, k.until, now())
                      ORDER BY k.created_at DESC LIMIT 1) a ON true;

-- pg_crash_state: per active PostgreSQL instance the newest crash not acknowledged and its age against the thresholds
-- (critical within crit hours, warning within warn hours).
CREATE OR REPLACE VIEW pgvigil.pg_crash_state AS
SELECT i.instance_id, i.name AS instance,
       (SELECT count(*) FROM pgvigil.pg_crashes c WHERE c.instance_id = i.instance_id) AS crashes_30d,
       (SELECT count(*) FROM pgvigil.pg_crashes c WHERE c.instance_id = i.instance_id AND c.ack_id IS NULL) AS open_30d,
       (SELECT max(c.at) FROM pgvigil.pg_crashes c WHERE c.instance_id = i.instance_id) AS last_crash_at,
       o.at AS open_crash_at, o.detail AS open_detail,
       round(extract(epoch FROM now() - o.at)::numeric / 3600, 1) AS open_age_h,
       th.warn AS warn_h, th.crit AS crit_h, th.level AS threshold_level,
       CASE WHEN o.at IS NULL THEN 'ok'
            WHEN th.crit IS NOT NULL AND now() - o.at < make_interval(secs => th.crit * 3600) THEN 'critical'
            WHEN th.warn IS NOT NULL AND now() - o.at < make_interval(secs => th.warn * 3600) THEN 'warning'
            ELSE 'ok' END AS status
  FROM pgvigil.instances i
  LEFT JOIN LATERAL (SELECT c.at, c.detail FROM pgvigil.pg_crashes c WHERE c.instance_id = i.instance_id AND c.ack_id IS NULL ORDER BY c.at DESC LIMIT 1) o ON true
  CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'crash') th
 WHERE i.is_active AND i.engine = 'postgres';

-- pg_stmt_store_state: pg_stat_statements per instance (DBA Dash's Query Store state): available, preloaded, created in a
-- database read, track, max, the entries kept, the evictions (dealloc) in 24 h and since the last reset, the last reset.
CREATE OR REPLACE VIEW pgvigil.pg_stmt_store_state AS
SELECT i.instance_id, i.name AS instance,
       coalesce(e.available, false) AS available,
       coalesce('shared' = ANY (e.preloaded_via), false) AS preloaded,
       EXISTS (SELECT 1 FROM pgvigil.database_extensions d WHERE d.instance_id = i.instance_id AND d.name = 'pg_stat_statements' AND d.is_present) AS created,
       (SELECT s.setting FROM pgvigil.instance_extension_settings s WHERE s.instance_id = i.instance_id AND s.name = 'pg_stat_statements.track' AND s.is_present) AS track,
       (SELECT s.setting FROM pgvigil.instance_extension_settings s WHERE s.instance_id = i.instance_id AND s.name = 'pg_stat_statements.max' AND s.is_present)::bigint AS max_entries,
       (SELECT s.setting FROM pgvigil.instance_extension_settings s WHERE s.instance_id = i.instance_id AND s.name = 'pg_stat_statements.track_utility' AND s.is_present) AS track_utility,
       (SELECT count(*) FROM pgvigil.statements_current c WHERE c.instance_id = i.instance_id
           AND c.snapshot_at = (SELECT max(c2.snapshot_at) FROM pgvigil.statements_current c2 WHERE c2.instance_id = i.instance_id)) AS entries,
       n.dealloc, n.stats_reset, n.snapshot_at AS info_at,
       -- the evictions in 24 h: the rise of dealloc within the newest reset's reads
       (SELECT greatest(0, max(x.dealloc) - min(x.dealloc)) FROM pgvigil.statements_info x
         WHERE x.instance_id = i.instance_id AND x.snapshot_at > now() - interval '1 day' AND x.stats_reset IS NOT DISTINCT FROM n.stats_reset) AS dealloc_24h,
       e.snapshot_at AS ext_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.instance_extensions e ON e.instance_id = i.instance_id AND e.name = 'pg_stat_statements' AND e.is_present
  LEFT JOIN LATERAL (SELECT x.dealloc, x.stats_reset, x.snapshot_at FROM pgvigil.statements_info x WHERE x.instance_id = i.instance_id
                      ORDER BY x.snapshot_at DESC LIMIT 1) n ON true
 WHERE i.is_active AND i.engine = 'postgres';

-- pg_amcheck_age: per database present (not a template) the newest clean amcheck run (status ok) of any check, its age
-- and the thresholds in force (a database level, else the instance's, ...); amcheck_runs_any = the instance has an
-- amcheck run stored at all (the collection is opt-in: a server never scheduled has none).
CREATE OR REPLACE VIEW pgvigil.pg_amcheck_age AS
SELECT d.instance_id, i.name AS instance, d.datname,
       r.last_ok_at, round(extract(epoch FROM now() - r.last_ok_at)::numeric / 86400, 1) AS age_days,
       r.last_run_at, r.last_status,
       EXISTS (SELECT 1 FROM pgvigil.amcheck_runs a WHERE a.instance_id = d.instance_id) AS amcheck_runs_any,
       th.warn AS warn_days, th.crit AS crit_days, th.level AS threshold_level,
       extract(epoch FROM now() - r.last_ok_at) AS age_s   -- unrounded: the rule compares this
  FROM pgvigil.databases d
  JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
  LEFT JOIN LATERAL (SELECT max(a.snapshot_at) FILTER (WHERE a.status = 'ok') AS last_ok_at, max(a.snapshot_at) AS last_run_at,
                            (array_agg(a.status ORDER BY a.snapshot_at DESC))[1] AS last_status
                       FROM pgvigil.amcheck_runs a WHERE a.instance_id = d.instance_id AND a.datname = d.datname) r ON true
  CROSS JOIN LATERAL pgvigil.pg_threshold(d.instance_id, 'amcheck_age', d.datname) th
 WHERE d.is_present AND NOT coalesce(d.is_template, false);

-- pg_uptime_state: the postmaster's start against the uptime thresholds (critical under crit hours, warning under warn).
CREATE OR REPLACE VIEW pgvigil.pg_uptime_state AS
SELECT i.instance_id, i.name AS instance, s.postmaster_start,
       round(extract(epoch FROM now() - s.postmaster_start)::numeric / 3600, 1) AS uptime_h,
       th.warn AS warn_h, th.crit AS crit_h, th.level AS threshold_level,
       CASE WHEN s.postmaster_start IS NULL THEN NULL
            WHEN th.crit IS NOT NULL AND now() - s.postmaster_start < make_interval(secs => th.crit * 3600) THEN 'critical'
            WHEN th.warn IS NOT NULL AND now() - s.postmaster_start < make_interval(secs => th.warn * 3600) THEN 'warning'
            ELSE 'ok' END AS status
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.instance_state s ON s.instance_id = i.instance_id
  CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'uptime') th
 WHERE i.is_active AND i.engine = 'postgres';

-- pg_replication_links: the fleet's clusters by system identifier, one row per member (the primary first), each standby
-- with the primary's sender row that serves it (matched by the standby's address or cluster_name as application_name),
-- its slot, lag and sync state, and Patroni's view of the member when Patroni answered.
CREATE OR REPLACE VIEW pgvigil.pg_replication_links AS
SELECT rs.system_identifier, coalesce(pr.scope, rs.cluster_name) AS cluster, rs.instance_id, i.name AS instance,
       CASE WHEN rs.is_replica THEN 'standby' ELSE 'primary' END AS role, rs.timeline_id, rs.since AS role_since, rs.read_at,
       w.has_receiver, w.replay_delay_secs, w.last_replay_at,
       rcv.state AS receiver_status, rcv.detail->>'sender_host' AS sender_host, rcv.detail->>'slot_name' AS slot_name, rcv.lag_secs AS receiver_delay_secs,
       snd.key AS sender_key, snd.state AS sender_state, snd.detail->>'sync_state' AS sync_state, snd.lag_bytes AS replay_lag_bytes,
       snd.lag_secs AS replay_lag_secs, sl.lag_bytes AS slot_retained_bytes, sl.active AS slot_active,
       pm.role AS patroni_role, pm.state AS patroni_state, pm.lag_bytes AS patroni_lag_bytes,
       (SELECT count(*) FROM pgvigil.pg_role_changes c WHERE c.instance_id = rs.instance_id AND c.changed_at > now() - interval '30 days') AS changes_30d
  FROM pgvigil.pg_role_state rs
  JOIN pgvigil.instances i ON i.instance_id = rs.instance_id AND i.is_active
  LEFT JOIN pgvigil.pg_wal_replay w ON w.instance_id = rs.instance_id AND w.is_present
  LEFT JOIN LATERAL (SELECT r.* FROM pgvigil.replication_latest r WHERE r.instance_id = rs.instance_id AND r.kind = 'receiver' LIMIT 1) rcv ON true
  LEFT JOIN LATERAL (SELECT p.instance_id FROM pgvigil.pg_role_state p WHERE p.system_identifier = rs.system_identifier AND NOT p.is_replica
                      AND p.instance_id <> rs.instance_id ORDER BY (p.timeline_id = rs.timeline_id) DESC NULLS LAST, p.read_at DESC LIMIT 1) pri ON rs.is_replica
  LEFT JOIN LATERAL (SELECT r.* FROM pgvigil.replication_latest r WHERE r.instance_id = pri.instance_id AND r.kind = 'sender'
                        AND (r.detail->>'application_name' = rs.cluster_name OR r.detail->>'application_name' = i.name
                             OR (rcv.detail->>'slot_name' IS NOT NULL AND r.detail->>'application_name' = rcv.detail->>'slot_name'))
                      LIMIT 1) snd ON true
  LEFT JOIN LATERAL (SELECT r.* FROM pgvigil.replication_latest r WHERE r.instance_id = pri.instance_id AND r.kind = 'slot'
                        AND r.key = rcv.detail->>'slot_name' LIMIT 1) sl ON true
  LEFT JOIN LATERAL (SELECT m.* FROM pgvigil.pg_patroni_members m WHERE m.is_present
                        AND (m.instance_id = rs.instance_id OR m.instance_id = pri.instance_id)
                        AND (m.member = rs.cluster_name OR m.member = i.name) ORDER BY m.snapshot_at DESC LIMIT 1) pm ON true
  LEFT JOIN pgvigil.pg_patroni_read pr ON pr.instance_id = rs.instance_id AND pr.ok;

-- ---------------------------------------------------------------------------------------------------------------
-- The Summary's rows (instance_id, severity, check_name, object, at, detail, check_group): warning and critical only.
--   check_group 'base backups'  a tool read failing or its stanza's status not ok (critical); the newest full or any
--                               backup past its threshold; the newest backup failed (warning)
--   check_group 'log shipping'  a standby without a WAL receiver whose replay delay is past its threshold and that has
--                               not caught up with its primary's archive
--   check_group 'crashes'       the newest crash restart not acknowledged within the thresholds
--   check_group 'statement store' pg_stat_statements evicting entries (24 h), track = none
--   check_group 'uptime'        the start within the thresholds
--   check_group 'amcheck age'   a database whose last clean amcheck is past its threshold, or that never had one on an
--                               instance where amcheck runs
CREATE OR REPLACE VIEW pgvigil.pg_backups_checks AS
SELECT b.instance_id, 'critical' AS severity, b.tool || ' read failing' AS check_name, b.name AS object, b.read_at AS at,
       coalesce(b.status_message, b.message, b.state) AS detail, 'base backups' AS check_group
  FROM pgvigil.pg_base_backup_status b
 WHERE b.state = 'error' AND b.read_at > now() - interval '1 day'
UNION ALL
SELECT b.instance_id, CASE WHEN b.full_age_s IS NULL OR (b.full_crit_h IS NOT NULL AND b.full_age_s > b.full_crit_h * 3600) THEN 'critical' ELSE 'warning' END,
       'full backup older than ' || coalesce(b.full_warn_h, b.full_crit_h) || ' h', b.name, b.read_at,
       coalesce('the newest full backup ' || b.full_label || ' ended ' || b.full_age_h || ' h before the read', 'no full backup is listed')
       || ' (' || concat_ws(', ', 'warning ' || b.full_warn_h || ' h', 'critical ' || b.full_crit_h || ' h', b.full_level) || ')', 'base backups'
  FROM pgvigil.pg_base_backup_status b
 WHERE b.state = 'ok' AND coalesce(b.full_warn_h, b.full_crit_h) IS NOT NULL
   AND (b.full_age_s IS NULL OR b.full_age_s > coalesce(b.full_warn_h, b.full_crit_h) * 3600) AND b.read_at > now() - interval '1 day'
UNION ALL
SELECT b.instance_id, CASE WHEN b.last_age_s IS NULL OR (b.any_crit_h IS NOT NULL AND b.last_age_s > b.any_crit_h * 3600) THEN 'critical' ELSE 'warning' END,
       'backup older than ' || coalesce(b.any_warn_h, b.any_crit_h) || ' h', b.name, b.read_at,
       coalesce('the newest backup ' || b.last_label || ' ended ' || b.last_age_h || ' h before the read', 'no backup is listed'), 'base backups'
  FROM pgvigil.pg_base_backup_status b
 WHERE b.state = 'ok' AND coalesce(b.any_warn_h, b.any_crit_h) IS NOT NULL
   AND (b.last_age_s IS NULL OR b.last_age_s > coalesce(b.any_warn_h, b.any_crit_h) * 3600) AND b.read_at > now() - interval '1 day'
UNION ALL
SELECT x.instance_id, 'warning', 'newest backup failed', x.name, x.snapshot_at, x.label || ' (' || coalesce(x.tool_status, x.status) || ')', 'base backups'
  FROM (SELECT DISTINCT ON (b.instance_id, b.tool, b.name) b.* FROM pgvigil.pg_base_backups b
          JOIN pgvigil.instances i ON i.instance_id = b.instance_id AND i.is_active
         WHERE b.is_present AND b.status <> 'running' ORDER BY b.instance_id, b.tool, b.name, coalesce(b.stopped_at, b.started_at) DESC NULLS LAST) x
 WHERE x.status = 'error' AND x.snapshot_at > now() - interval '1 day'
UNION ALL
SELECT w.instance_id, CASE WHEN w.crit_min IS NOT NULL AND w.replay_delay_secs > w.crit_min * 60 THEN 'critical' ELSE 'warning' END,
       'replay delay over ' || coalesce(w.warn_min, w.crit_min) || ' min', 'restore_command', w.read_at,
       'last replayed commit ' || round((w.replay_delay_secs / 60)::numeric) || ' min before the read, no WAL receiver (file shipping)'
       || CASE WHEN w.primary_id IS NULL THEN '; its primary is not in the fleet: an idle primary also reads as a delay' ELSE '' END
       || CASE WHEN w.replay_paused THEN '; replay is paused' ELSE '' END, 'log shipping'
  FROM pgvigil.pg_wal_replay_status w
 WHERE NOT coalesce(w.has_receiver, false) AND coalesce(w.warn_min, w.crit_min) IS NOT NULL AND w.replay_delay_secs > coalesce(w.warn_min, w.crit_min) * 60
   AND NOT coalesce(w.caught_up, false)
   AND w.read_at > now() - interval '1 hour'
UNION ALL
SELECT c.instance_id, c.status, 'crash restart', 'log', c.open_crash_at,
       c.open_detail || ' (' || c.open_age_h || ' h ago; ' || c.open_30d || ' not acknowledged in 30 days)', 'crashes'
  FROM pgvigil.pg_crash_state c
 WHERE c.status IN ('warning', 'critical')
UNION ALL
SELECT s.instance_id, 'warning', 'statements evicted', 'pg_stat_statements', s.info_at,
       s.dealloc_24h || ' eviction(s) in 24 h: pg_stat_statements.max (' || coalesce(s.max_entries::text, '?') || ') is too small for the statements run', 'statement store'
  FROM pgvigil.pg_stmt_store_state s
 WHERE s.dealloc_24h > 0
UNION ALL
SELECT s.instance_id, 'warning', 'statement tracking off', 'pg_stat_statements', s.ext_at, 'pg_stat_statements.track = none: nothing is recorded', 'statement store'
  FROM pgvigil.pg_stmt_store_state s
 WHERE s.track = 'none'
UNION ALL
SELECT u.instance_id, u.status, 'uptime under ' || CASE WHEN u.status = 'critical' THEN u.crit_h ELSE u.warn_h END || ' h', 'postmaster', u.postmaster_start,
       'started ' || to_char(u.postmaster_start AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC, ' || u.uptime_h || ' h ago (critical under '
       || coalesce(u.crit_h::text, '-') || ' h, warning under ' || coalesce(u.warn_h::text, '-') || ' h, ' || u.threshold_level || ')', 'uptime'
  FROM pgvigil.pg_uptime_state u
 WHERE u.status IN ('warning', 'critical')
UNION ALL
SELECT a.instance_id, CASE WHEN a.last_ok_at IS NULL OR (a.crit_days IS NOT NULL AND a.age_s > a.crit_days * 86400) THEN 'critical' ELSE 'warning' END,
       CASE WHEN a.last_ok_at IS NULL THEN 'amcheck never clean' ELSE 'amcheck older than ' || coalesce(a.warn_days, a.crit_days) || ' d' END, a.datname, coalesce(a.last_run_at, now()),
       coalesce('the last clean run ' || a.age_days || ' d ago', 'no clean run stored') || coalesce(' (the newest run: ' || a.last_status || ')', '')
       || ' (' || concat_ws(', ', 'warning ' || a.warn_days || ' d', 'critical ' || a.crit_days || ' d', a.threshold_level) || ')', 'amcheck age'
  FROM pgvigil.pg_amcheck_age a
 WHERE a.amcheck_runs_any AND coalesce(a.warn_days, a.crit_days) IS NOT NULL
   AND (a.last_ok_at IS NULL OR a.age_s > coalesce(a.warn_days, a.crit_days) * 86400);

-- The findings arm (the findings columns): the checks above but uptime (a state, not a finding), plus two info rows:
-- a tool the server names that the collector's host lacks, and amcheck never run on an instance.
CREATE OR REPLACE VIEW pgvigil.pg_backups_findings AS
SELECT c.instance_id, c.severity, c.check_name AS setting, c.object || ': ' || c.detail AS value, true AS is_set,
       CASE c.check_group
         WHEN 'base backups' THEN 'read the tool''s log and its last backup; a stanza status other than ok names what is missing'
         WHEN 'log shipping' THEN 'check restore_command on the standby and archiving on the primary; set archive_timeout so a quiet primary still ships'
         WHEN 'crashes' THEN 'read the server log around the crash (the backend''s last statement, the signal) and acknowledge it on the Summary'
         WHEN 'statement store' THEN 'raise pg_stat_statements.max (a restart) or turn tracking back on'
         ELSE 'schedule the amcheck collection for the database (README: the amcheck collection)'
       END AS suggested, 'self-managed' AS platforms,
       CASE c.check_group
         WHEN 'base backups' THEN 'without a recent base backup a restore replays more WAL, or has nothing to start from'
         WHEN 'log shipping' THEN 'a standby that falls behind loses what it has not replayed if it must take over'
         WHEN 'crashes' THEN 'a crash restart ends every session and replays WAL from the last checkpoint'
         WHEN 'statement store' THEN 'evicted statements drop out of the statement history'
         ELSE 'damage in an index or a table is only found by a check that reads it'
       END AS detail, 'pg-backups' AS source, c.at
  FROM pgvigil.pg_backups_checks c
 WHERE c.check_group <> 'uptime'
UNION ALL
SELECT t.instance_id, 'info', t.tool || ' not on the collector host', t.name || ': ' || t.message, true,
       'install ' || t.tool || ' on the collector host with read access to the repository (docs/backups-postgres.md)', 'self-managed',
       'the server archives with ' || t.tool || ' but its backups cannot be read from here', 'pg-backups', t.snapshot_at
  FROM pgvigil.pg_backup_tools t JOIN pgvigil.instances i ON i.instance_id = t.instance_id AND i.is_active
 WHERE t.is_present AND t.state = 'no_binary'
UNION ALL
SELECT i.instance_id, 'info', 'amcheck never run', i.name, true, 'schedule the amcheck collection (README: the amcheck collection)', 'all',
       'no amcheck run is stored for the instance: damage in an index or a table goes unseen until a query reads it', 'pg-backups', now()
  FROM pgvigil.instances i
 WHERE i.is_active AND i.engine = 'postgres'
   AND EXISTS (SELECT 1 FROM pgvigil.databases d WHERE d.instance_id = i.instance_id AND d.is_present)
   AND NOT EXISTS (SELECT 1 FROM pgvigil.amcheck_runs a WHERE a.instance_id = i.instance_id);

-- ---------------------------------------------------------------------------------------------------------------
-- 5. 0022's views again, the archive-age and retention thresholds from pg_thresholds when the UI set one at any level
-- (the config file's archive_warn_minutes, as stored with the archiver row, otherwise). The columns are 0022's.
CREATE OR REPLACE VIEW pgvigil.backup_status AS
WITH snap AS (
  SELECT instance_id,
         max(created_at) FILTER (WHERE snapshot_type = 'automated' AND status = 'available') AS newest_automated_at,
         max(created_at) FILTER (WHERE snapshot_type = 'manual' AND status = 'available') AS newest_manual_at,
         max(created_at) FILTER (WHERE status = 'available') AS newest_snapshot_at,
         count(*) FILTER (WHERE snapshot_type = 'automated') AS automated_count,
         count(*) FILTER (WHERE snapshot_type = 'manual') AS manual_count
    FROM pgvigil.backup_state WHERE kind = 'snapshot' AND is_present GROUP BY instance_id
)
SELECT i.instance_id, i.name AS instance, i.platform,
       a.archive_mode, a.archive_set, a.is_replica,
       (a.archive_set AND (a.archive_mode = 'always' OR (a.archive_mode = 'on' AND NOT a.is_replica))) AS archiving,
       a.archived_count, a.failed_count, a.last_archived_wal, a.last_archived_time, a.last_failed_wal, a.last_failed_time,
       a.stats_reset, a.archive_lag_bytes, a.wal_segment_bytes,
       CASE WHEN aw.level <> 'default' AND aw.warn IS NOT NULL THEN aw.warn::int ELSE a.archive_warn_minutes END AS archive_warn_minutes,
       round(extract(epoch FROM a.snapshot_at - a.last_archived_time)::numeric, 0) AS archive_age_s,
       (a.archive_set AND (a.archive_mode = 'always' OR (a.archive_mode = 'on' AND NOT a.is_replica))
        AND a.last_failed_time IS NOT NULL AND (a.last_archived_time IS NULL OR a.last_failed_time > a.last_archived_time)) AS archiver_failing,
       (a.archive_lag_bytes > a.wal_segment_bytes) AS wal_waiting,
       a.snapshot_at AS archiver_read_at,
       c.name AS cloud_resource, c.resource_kind, c.retention_days, c.latest_restorable_time, c.earliest_restorable_time, c.backup_window,
       round(extract(epoch FROM c.snapshot_at - c.latest_restorable_time)::numeric, 0) AS restorable_age_s,
       c.snapshot_at AS cloud_read_at,
       s.newest_automated_at, s.newest_manual_at, s.newest_snapshot_at,
       round(extract(epoch FROM c.snapshot_at - s.newest_snapshot_at)::numeric, 0) AS newest_snapshot_age_s,
       coalesce(s.automated_count, 0) AS automated_count, coalesce(s.manual_count, 0) AS manual_count
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.backup_state a ON a.instance_id = i.instance_id AND a.kind = 'archiver' AND a.is_present
  LEFT JOIN pgvigil.backup_state c ON c.instance_id = i.instance_id AND c.kind = 'cloud' AND c.is_present
  LEFT JOIN snap s ON s.instance_id = i.instance_id
  CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'archive_age') aw
 WHERE i.is_active AND (a.instance_id IS NOT NULL OR c.instance_id IS NOT NULL);

-- backup_retention: the retention thresholds in force per instance (default warning under 7 days, critical at 0).
CREATE OR REPLACE VIEW pgvigil.backup_retention AS
SELECT i.instance_id, t.warn AS warn_days, t.crit AS crit_days, t.level
  FROM pgvigil.instances i CROSS JOIN LATERAL pgvigil.pg_threshold(i.instance_id, 'retention') t;

CREATE OR REPLACE VIEW pgvigil.backup_rule_hits AS
SELECT b.instance_id, 'critical' AS severity, 'archiver failing' AS check_name, coalesce(b.last_failed_wal, 'pg_stat_archiver') AS object,
       b.archiver_read_at AS at,
       'archive of ' || coalesce(b.last_failed_wal, '?') || ' failed at ' || to_char(b.last_failed_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
       || coalesce(', after the last success at ' || to_char(b.last_archived_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', ', no success since the stats reset')
       || ' (' || b.failed_count || ' failed, ' || b.archived_count || ' archived)' AS detail
  FROM pgvigil.backup_status b
 WHERE b.archiver_failing AND b.platform <> 'aurora'
UNION ALL
SELECT b.instance_id, 'warning', 'last archive older than ' || b.archive_warn_minutes || ' min', coalesce(b.last_archived_wal, 'pg_stat_archiver'), b.archiver_read_at,
       coalesce('last archived ' || round(b.archive_age_s / 60) || ' min before the read', 'nothing archived since the stats reset')
       || '; ' || pg_size_pretty(b.archive_lag_bytes) || ' of WAL waiting'
  FROM pgvigil.backup_status b
 WHERE b.archiving AND b.wal_waiting AND b.platform <> 'aurora'
   AND (b.last_archived_time IS NULL OR b.archive_age_s > b.archive_warn_minutes * 60)
UNION ALL
SELECT b.instance_id, CASE WHEN r.crit_days IS NOT NULL AND b.retention_days <= r.crit_days THEN 'critical' ELSE 'warning' END,
       CASE WHEN r.warn_days IS NOT NULL THEN 'retention under ' || trim_scale(r.warn_days) || ' days'
            ELSE 'retention at or under ' || trim_scale(r.crit_days) || ' days' END, b.cloud_resource, b.cloud_read_at,
       CASE WHEN b.retention_days = 0 THEN 'automated backups are off (retention 0 days)'
            ELSE 'backup retention ' || b.retention_days || ' days' END
  FROM pgvigil.backup_status b JOIN pgvigil.backup_retention r USING (instance_id)
 WHERE ((r.warn_days IS NOT NULL AND b.retention_days < r.warn_days) OR (r.crit_days IS NOT NULL AND b.retention_days <= r.crit_days))
   AND NOT (b.platform = 'rds' AND coalesce(b.is_replica, false) AND b.retention_days = 0)
UNION ALL
SELECT b.instance_id, 'warning', 'no snapshot in 24 h', b.cloud_resource, b.cloud_read_at,
       coalesce('newest snapshot ' || to_char(b.newest_snapshot_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC, '
                || round(b.newest_snapshot_age_s / 3600) || ' h before the read', 'no available snapshot listed')
  FROM pgvigil.backup_status b
 WHERE b.cloud_resource IS NOT NULL AND (b.newest_snapshot_at IS NULL OR b.newest_snapshot_age_s > 86400)
   AND NOT (b.platform = 'rds' AND coalesce(b.is_replica, false) AND b.retention_days = 0);

CREATE OR REPLACE VIEW pgvigil.backup_findings AS
SELECT h.instance_id, h.severity, h.check_name AS setting, h.object || ': ' || h.detail AS value, true AS is_set,
       CASE WHEN h.check_name = 'archiver failing' THEN 'read the server log for the archive_command error and fix the destination; WAL stays in pg_wal until it succeeds'
            WHEN h.check_name LIKE 'retention under %' THEN 'raise the backup retention period to ' || substring(h.check_name FROM 'under ([0-9.]+) days') || ' days or more'
            WHEN h.check_name LIKE 'retention at or under %' THEN 'raise the backup retention period above ' || substring(h.check_name FROM 'under ([0-9.]+) days') || ' days'
            WHEN h.check_name = 'no snapshot in 24 h' THEN 'check the backup window and the automated backups; take a manual snapshot'
            ELSE 'check archive_command and its destination; set archive_timeout so a quiet server still archives'
       END AS suggested,
       CASE WHEN h.check_name LIKE 'retention %' OR h.check_name = 'no snapshot in 24 h' THEN 'managed' ELSE 'not aurora' END AS platforms,
       CASE WHEN h.check_name = 'archiver failing' THEN 'a failing archiver leaves no point-in-time recovery past the last archived file and fills pg_wal'
            WHEN h.check_name LIKE 'retention %' THEN 'a short retention leaves a narrow window to restore from (0 = no automated backups and no point-in-time restore)'
            WHEN h.check_name = 'no snapshot in 24 h' THEN 'a missed daily snapshot widens the replay a restore needs, or there is nothing to restore from'
            ELSE 'WAL waits to be archived: a point-in-time recovery would lose what is not yet archived'
       END AS detail,
       'pgvigil backups' AS source, h.at
  FROM pgvigil.backup_checks h;
