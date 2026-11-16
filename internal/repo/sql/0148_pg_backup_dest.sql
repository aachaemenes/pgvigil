-- 0148: where a self-managed PostgreSQL server's WAL and base backups go (task 302), read by the collection backup_dest
-- (internal/collect/backup_dest.go) from the server's archive_command, archive_library and restore_command and, with the
-- instance's `backups: read_tools: true`, from the backup tool's configuration on the collector's host; and a person's
-- own entry where nothing can be read. No command text is ever stored: a destination is built from checked pieces.
--   pg_backup_dest           the destinations of the instance's newest read (replaced whole by each read)
--   pg_backup_dest_settings  that read's settings (archive_mode, what is set, a standby that does not archive)
--   pg_backup_dest_reads     the opt-in tool reads: off | ok | no_binary | error, in fixed words
--   pg_backup_dest_entered   the destinations a person entered, with their history (a row ended, its successor written)
-- And the one change to an older object: 0103's pg_backup_tools.state takes 'not_read' (the tool read is off for the
-- instance: F1 of 302's fold). 0190 does not recreate that constraint (its pg_backup_tools lines are the purge only).

ALTER TABLE pgvigil.pg_backup_tools DROP CONSTRAINT IF EXISTS pg_backup_tools_state_check;
ALTER TABLE pgvigil.pg_backup_tools ADD CONSTRAINT pg_backup_tools_state_check CHECK (state IN ('ok', 'error', 'no_binary', 'not_read'));

CREATE TABLE IF NOT EXISTS pgvigil.pg_backup_dest (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  source       text NOT NULL CHECK (source IN ('archive_mode', 'archive_command', 'archive_library', 'restore_command', 'pgbackrest configuration', 'barman')),
  role         text NOT NULL CHECK (role IN ('wal', 'base', 'restore')),
  seq          int NOT NULL,
  tool         text,
  dest_kind    text,          -- posix | s3 | gcs | azure | https | sftp | host | rsync-module | rclone-remote | mc-alias | discard
  host         text,
  container    text,          -- a bucket, a blob container, an rsync module, an rclone remote, an mc alias
  path         text,
  repo_key     text,          -- pgBackRest's repo1 ...
  detail       text,          -- pgvigil's own words
  secret_seen  boolean NOT NULL DEFAULT false,
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, source, role, seq)
);

CREATE TABLE IF NOT EXISTS pgvigil.pg_backup_dest_settings (
  instance_id          int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at          timestamptz NOT NULL,
  is_replica           boolean,
  archive_mode         text,
  archive_command_set  boolean,
  archive_library_set  boolean,
  restore_command_set  boolean,
  standby_archives     boolean       -- false: a standby with archive_mode on (only 'always' archives in recovery)
);

CREATE TABLE IF NOT EXISTS pgvigil.pg_backup_dest_reads (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  tool         text NOT NULL,
  name         text NOT NULL,
  state        text NOT NULL CHECK (state IN ('off', 'ok', 'no_binary', 'error')),
  message      text,
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, tool, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.pg_backup_dest_entered (
  entry_id     bigserial PRIMARY KEY,
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  role         text NOT NULL CHECK (role IN ('wal', 'base', 'restore')),
  dest_text    text NOT NULL CHECK (length(dest_text) BETWEEN 1 AND 500),
  note         text CHECK (note IS NULL OR length(note) <= 500),
  entered_by   text NOT NULL,
  entered_at   timestamptz NOT NULL DEFAULT now(),
  ended_at     timestamptz,        -- NULL = the entry in force; a later entry or a clear ends it
  ended_by     text,
  read_at_entry text               -- what the read named for the role when the entry was made (F10: a read that changed after it is marked)
);
CREATE UNIQUE INDEX IF NOT EXISTS pg_backup_dest_entered_now ON pgvigil.pg_backup_dest_entered (instance_id, role) WHERE ended_at IS NULL;

-- import_backup_dest: a read with its settings row replaces the instance's destinations and reads whole (a read that
-- failed before the settings sent nothing and changes nothing).
CREATE OR REPLACE FUNCTION pgvigil.import_backup_dest(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_backup_dest'), p_instance_id);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'settings') THEN
    RETURN;
  END IF;
  INSERT INTO pgvigil.pg_backup_dest_settings AS s (instance_id, snapshot_at, is_replica, archive_mode, archive_command_set, archive_library_set,
      restore_command_set, standby_archives)
  SELECT p_instance_id, p_snapshot_at, (r->>'is_replica')::boolean, r->>'archive_mode', (r->>'archive_command_set')::boolean,
         (r->>'archive_library_set')::boolean, (r->>'restore_command_set')::boolean, (r->>'standby_archives')::boolean
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'settings' LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, is_replica = EXCLUDED.is_replica, archive_mode = EXCLUDED.archive_mode,
      archive_command_set = EXCLUDED.archive_command_set, archive_library_set = EXCLUDED.archive_library_set,
      restore_command_set = EXCLUDED.restore_command_set, standby_archives = EXCLUDED.standby_archives;
  DELETE FROM pgvigil.pg_backup_dest WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.pg_backup_dest (instance_id, source, role, seq, tool, dest_kind, host, container, path, repo_key, detail, secret_seen, snapshot_at)
  SELECT DISTINCT ON (r->>'source', r->>'role', (r->>'seq')::int)
         p_instance_id, r->>'source', r->>'role', (r->>'seq')::int, left(r->>'tool', 64), left(r->>'dest_kind', 32), left(r->>'host', 260),
         left(r->>'container', 260), left(r->>'path', 1024), left(r->>'repo_key', 16), left(r->>'detail', 1000), coalesce((r->>'secret_seen')::boolean, false),
         p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'dest';
  DELETE FROM pgvigil.pg_backup_dest_reads WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.pg_backup_dest_reads (instance_id, tool, name, state, message, snapshot_at)
  SELECT DISTINCT ON (r->>'tool', r->>'name') p_instance_id, r->>'tool', r->>'name', r->>'state', left(r->>'message', 300), p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'read';
END $$;

-- pg_backup_dest_text: one destination in words, built from its checked pieces.
CREATE OR REPLACE FUNCTION pgvigil.pg_backup_dest_text(d pgvigil.pg_backup_dest)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT concat_ws(' ', d.tool,
           CASE d.dest_kind WHEN 's3' THEN 's3://' || coalesce(d.container, '') || coalesce(d.path, '')
                            WHEN 'gcs' THEN 'gs://' || coalesce(d.container, '') || coalesce(d.path, '')
                            WHEN 'rclone-remote' THEN d.container || ':' || coalesce(ltrim(d.path, '/'), '')
                            WHEN 'mc-alias' THEN d.container || coalesce(d.path, '')
                            WHEN 'rsync-module' THEN d.host || '::' || coalesce(d.container, '') || coalesce(d.path, '')
                            WHEN 'host' THEN d.host || coalesce(':' || d.path, '')
                            WHEN 'discard' THEN NULL
                            ELSE nullif(concat_ws('', d.host, d.path), '') END,
           CASE WHEN d.dest_kind = 's3' AND d.host IS NOT NULL THEN '(endpoint ' || d.host || ')' END,
           CASE WHEN d.repo_key IS NOT NULL THEN d.repo_key END,
           CASE WHEN d.detail IS NOT NULL THEN '- ' || d.detail END)
$$;

-- pg_backup_destinations: per instance and role ('base backups to', 'WAL to', 'restore from') what the newest read named
-- (each destination with its source), what a person entered (who, when) and whether the two differ - an entry is shown
-- beside a read value, never over it. 'confirmed' (F2) only when the tool's own info answered for the stanza with the
-- instance's system identifier. Managed platforms carry the service's line instead.
CREATE OR REPLACE VIEW pgvigil.pg_backup_destinations AS
WITH roles(role, label, ord) AS (VALUES ('base', 'base backups to', 1), ('wal', 'WAL to', 2), ('restore', 'restore from', 3)),
read AS (
  SELECT d.instance_id, d.role,
         string_agg(pgvigil.pg_backup_dest_text(d) || ' [' || d.source || ']', '; ' ORDER BY CASE WHEN d.source IN ('pgbackrest configuration', 'barman') THEN 0 ELSE 1 END, d.source, d.seq) AS read_text,
         bool_or(d.secret_seen) AS secret_seen, max(d.snapshot_at) AS read_at,
         bool_or(d.tool = 'pgbackrest' AND EXISTS (
           SELECT 1 FROM pgvigil.pg_backup_tools t
            WHERE t.instance_id = d.instance_id AND t.tool = 'pgbackrest' AND t.is_present AND t.state = 'ok' AND split_part(split_part(d.detail, ';', 1), ':', 1) = 'stanza ' || t.name
              AND t.system_id IS NOT NULL
              AND t.system_id = (SELECT w.system_identifier FROM pgvigil.wal_state_sample w WHERE w.instance_id = d.instance_id ORDER BY w.snapshot_at DESC LIMIT 1))) AS confirmed
    FROM pgvigil.pg_backup_dest d
   GROUP BY d.instance_id, d.role
)
SELECT i.instance_id, r.role, r.label, r.ord,
       CASE WHEN i.platform IN ('rds', 'aurora') THEN
              (SELECT 'kept by ' || CASE WHEN i.platform = 'aurora' THEN 'Aurora' ELSE 'RDS' END || ': automated backups'
                      || coalesce(', retention ' || c.retention_days || ' days', '')
                      || coalesce(', restorable ' || to_char(c.earliest_restorable_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' to '
                                  || to_char(c.latest_restorable_time AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', '')
                      || coalesce(', window ' || c.backup_window, '')
                 FROM pgvigil.backup_state c WHERE c.instance_id = i.instance_id AND c.kind = 'cloud' ORDER BY c.snapshot_at DESC LIMIT 1)
            WHEN i.platform IN ('azure', 'cloudsql', 'alloydb') THEN 'kept by the service (not read by pgvigil)'
       END AS platform_line,
       rd.read_text, rd.read_at, coalesce(rd.secret_seen, false) AS secret_seen, coalesce(rd.confirmed, false) AS confirmed,
       CASE WHEN rd.read_text IS NULL AND i.platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb') THEN 'not known' END AS not_known,
       e.dest_text AS entered_text, e.note AS entered_note, e.entered_by, e.entered_at,
       (e.dest_text IS NOT NULL AND rd.read_text IS NOT NULL) AS entered_beside_read,
       (e.dest_text IS NOT NULL AND e.read_at_entry IS DISTINCT FROM rd.read_text) AS read_changed_since_entry
  FROM pgvigil.instances i
 CROSS JOIN roles r
  LEFT JOIN read rd ON rd.instance_id = i.instance_id AND rd.role = r.role
  LEFT JOIN pgvigil.pg_backup_dest_entered e ON e.instance_id = i.instance_id AND e.role = r.role AND e.ended_at IS NULL
 WHERE i.is_active AND i.engine = 'postgres';

-- import_backup_dest_entry: a person's destination, on the audit login (F10): length capped, no control characters, never
-- a URL with a user:password@ or a signature, never a secret-shaped word; the entry in force is ended, its successor
-- written (history kept). An empty text ends the entry. Who may call it is the API's (admin once the roles join).
CREATE OR REPLACE FUNCTION pgvigil.import_backup_dest_entry(p_instance_id int, p_role text, p_text text, p_note text, p_by text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  v_id bigint;
BEGIN
  IF p_role NOT IN ('wal', 'base', 'restore') THEN
    RAISE EXCEPTION 'the role is base, wal or restore';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pgvigil.instances WHERE instance_id = p_instance_id AND engine = 'postgres') THEN
    RAISE EXCEPTION 'not a PostgreSQL instance';
  END IF;
  IF p_by IS NULL OR btrim(p_by) = '' THEN
    RAISE EXCEPTION 'an entry names who made it';
  END IF;
  p_text := btrim(coalesce(p_text, '')); p_note := nullif(btrim(coalesce(p_note, '')), '');
  IF length(p_text) > 500 OR length(coalesce(p_note, '')) > 500 THEN
    RAISE EXCEPTION 'at most 500 characters';
  END IF;
  IF p_text ~ '[[:cntrl:]]' OR coalesce(p_note, '') ~ '[[:cntrl:]]' THEN
    RAISE EXCEPTION 'no control characters';
  END IF;
  -- the second gate (the API checks every word with the collector's secret rule first); 'sas', 'pwd' and the key names
  -- as whole words only ('kansas:/srv' is a place)
  IF p_text || ' ' || coalesce(p_note, '') ~* '://[^/@[:space:]]*:[^/@[:space:]]*@|[?&](sig|signature|x-amz-signature|x-amz-credential|sv|se|sp)=|(password|passwd|secret|token)[[:space:]]*[=:]|\m(sas|pwd|access[_-]?key|account[_-]?key)[[:space:]]*[=:]' THEN
    RAISE EXCEPTION 'an entry never holds a credential: name where the backups go, not how to reach it';
  END IF;
  UPDATE pgvigil.pg_backup_dest_entered SET ended_at = now(), ended_by = p_by
   WHERE instance_id = p_instance_id AND role = p_role AND ended_at IS NULL;
  IF p_text = '' THEN
    RETURN NULL;
  END IF;
  INSERT INTO pgvigil.pg_backup_dest_entered (instance_id, role, dest_text, note, entered_by, read_at_entry)
  VALUES (p_instance_id, p_role, p_text, p_note, p_by,
          (SELECT v.read_text FROM pgvigil.pg_backup_destinations v WHERE v.instance_id = p_instance_id AND v.role = p_role))
  RETURNING entry_id INTO v_id;
  RETURN v_id;
END $$;

-- pg_backup_dest_findings (the findings columns): a credential written in archive_command or restore_command (warning:
-- every role that logs in reads both with SHOW, F5); WAL thrown away while archive_mode is on (warning, F6); the tool read
-- off for an instance whose commands name a tool (info), for its configuration and for 162's base-backup listing. Their pgvigil.findings arm and the purge lines are the lead's
-- WIRING for 0190's successor (scripts/inv-302-join-lines.sql).
CREATE OR REPLACE VIEW pgvigil.pg_backup_dest_findings AS
SELECT d.instance_id, 'warning'::text AS severity, 'a credential is written in the archiver''s command' AS check_name, d.source AS object,
       d.source || ' holds a password, a key or a token (its value is not stored): every role that logs in reads it with SHOW - move it to the tool''s own configuration or a password file' AS detail,
       max(d.snapshot_at) AS at
  FROM pgvigil.pg_backup_dest d JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
 WHERE d.secret_seen AND d.source IN ('archive_command', 'restore_command')
 GROUP BY d.instance_id, d.source
UNION ALL
SELECT d.instance_id, 'warning', 'WAL is discarded', d.source,
       coalesce(d.detail, 'the archiver keeps nothing') || ': archive_mode is ' || s.archive_mode || ', so the server recycles WAL no backup holds', d.snapshot_at
  FROM pgvigil.pg_backup_dest d
  JOIN pgvigil.pg_backup_dest_settings s ON s.instance_id = d.instance_id AND s.archive_mode IN ('on', 'always')
  JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
 WHERE d.dest_kind = 'discard' AND d.role = 'wal'
UNION ALL
SELECT r.instance_id, 'info', 'backup tool read off', r.tool || ' ' || r.name,
       'the server names ' || r.tool || ' ' || r.name || '; its storage and retention are in the tool''s configuration, read only with backups: read_tools: true', r.snapshot_at
  FROM pgvigil.pg_backup_dest_reads r JOIN pgvigil.instances i ON i.instance_id = r.instance_id AND i.is_active
 WHERE r.state = 'off'
UNION ALL
-- 162's base-backup listing kept off by the same opt-in (F1): its tool row is 'not_read', so the base backups are not
-- judged - the Summary's Backup cell maps this info finding to grey, never green (the agreed map)
SELECT t.instance_id, 'info', 'base backups not read', t.tool || ' ' || t.name,
       'the server names ' || t.tool || ' ' || t.name || '; its base backups are listed only with backups: read_tools: true, so they are not judged', t.snapshot_at
  FROM pgvigil.pg_backup_tools t JOIN pgvigil.instances i ON i.instance_id = t.instance_id AND i.is_active
 WHERE t.is_present AND t.state = 'not_read';
