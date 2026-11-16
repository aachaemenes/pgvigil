-- 0161 SQL Server maintenance (task 410, build B17 of the SQL Server tools audit, with B24b's data purity): Ola
-- Hallengren's maintenance solution - where it is installed, its objects and their version, its jobs judged from what
-- mssql_jobs stores (each step's command, masked), the maintenance history in its CommandLog - and each database's
-- data purity flag.
--
--   mssql_maint_part         which part of the hourly read (mssql_maintenance) was read, or why not
--   mssql_maint_database     per database the login could or could not look into: the solution's objects seen
--                            there and their versions, whether its CommandLog may be read, the purity flag
--   mssql_ola_commandlog     the CommandLog rows read, per database holding one, by its ID (an epoch per reset of
--                            the table: a truncated CommandLog numbers its rows from 1 again)
--   mssql_maint_last         per database worked on, the newest successful command of each kind (full, diff, log,
--                            integrity, index) as the import met it: the Maintenance tab's last part, never a scan
--   mssql_maintenance_checks_of(instance) / mssql_maintenance_checks: every rule, met or not
--   mssql_maintenance_findings: its warning and critical rows
--
-- Read here, written elsewhere: mssql_jobs (0066 / 0094: each job, its schedules, its last outcome and its steps with
-- their commands), mssql_config_expect_in_force (0160: kind 'job', keys expected and not_expected), mssql_confcheck_fact
-- (0160: host_platform), instances.platform. The jobs Ola makes depend on the platform: Windows eleven; Linux ten (no
-- 'Output File Cleanup', a PowerShell step); Azure SQL Managed Instance six; Amazon RDS three.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_maint_part (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  part         text NOT NULL,
  is_read      boolean NOT NULL,
  note         text,
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, part)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_maint_database (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name     text NOT NULL,
  install_read      boolean NOT NULL,       -- the login could see the database's procedures (VIEW DEFINITION)
  note              text,                   -- why not
  objects           text[] NOT NULL DEFAULT '{}',   -- the solution's objects seen in schema dbo
  versions          jsonb NOT NULL DEFAULT '{}',    -- procedure -> its '--// Version:' line
  commandlog_note   text,                   -- why its CommandLog is not read (SELECT on it)
  commandlog_epoch  int NOT NULL DEFAULT 0, -- one more at each reset of the table (its IDs start again)
  purity_read       boolean NOT NULL DEFAULT false,
  purity_note       text,
  create_version    int,
  dbcc_flags        int,
  purity_on         boolean,
  purity_at         timestamptz,            -- when the flags were last read or refused (once a day: a read between keeps them)
  commandlog_behind bigint,                 -- the rows the last read of its CommandLog left behind the table's end
  snapshot_at       timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_ola_commandlog (
  instance_id       int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name     text NOT NULL,          -- the database holding the CommandLog
  epoch             int NOT NULL,
  id                bigint NOT NULL,
  db                text,                   -- the database the command worked on
  schema_name       text,
  object_name       text,
  object_type       text,
  index_name        text,
  statistics_name   text,
  partition_number  int,
  command_type      text,
  backup_kind       text,                   -- full | diff | log, told by the collector on the server from the whole command
  start_at          timestamptz,
  end_at            timestamptz,
  error_number      int,
  error_message     text,
  command           text,                   -- masked by the collector, cut at 4,000 characters
  status            text NOT NULL,          -- ok | failed | running | never closed
  snapshot_at       timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, epoch, id)
);
CREATE INDEX IF NOT EXISTS mssql_ola_commandlog_start_idx ON pgvigil.mssql_ola_commandlog (instance_id, start_at);
CREATE INDEX IF NOT EXISTS mssql_ola_commandlog_failed_idx ON pgvigil.mssql_ola_commandlog (instance_id, db) WHERE status = 'failed';

CREATE TABLE IF NOT EXISTS pgvigil.mssql_maint_last (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,             -- the database holding the CommandLog
  db             text NOT NULL,             -- the database the command worked on
  kind           text NOT NULL,             -- full | diff | log | integrity (the CHECKDB family) | index (ALTER_INDEX, UPDATE_STATISTICS)
  last_at        timestamptz NOT NULL,      -- the newest successful command's start
  seconds        numeric(12, 1),            -- its duration
  PRIMARY KEY (instance_id, database_name, db, kind)
);
COMMENT ON TABLE pgvigil.mssql_ola_commandlog IS 'Ola Hallengren''s CommandLog as read forward (task 410); purged past the retention by purge().';

-- import_mssql_maintenance: one batch of mssql_maintenance. payload: {kind:'part', part:'install', read, note};
-- {kind:'database', database_name, install_read, note, objects [...], versions {...}, commandlog_note, purity_read,
-- purity_note, create_version, dbcc_flags, purity_on, purity_kept} (with the 'install' part: the databases are
-- replaced; purity_kept = the flags were not read again today: the day's are kept);
-- {kind:'reset', database_name} (the CommandLog was emptied or truncated: a new epoch); {kind:'commandlog',
-- database_name, id, db, schema_name, object_name, object_type, index_name, statistics_name, partition_number,
-- command_type, backup_kind, start_utc, end_utc, error_number, error_message, command, status} (a row read again
-- replaces its earlier read); {kind:'commandlog_read', database_name, behind}; {kind:'cursor', source, last_seq,
-- last_event_at} (stamped with the read's own time: the rules compare it with the read's, never with this clock);
-- {kind:'collector_error', source, message}.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_maintenance(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_maintenance: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_maintenance'), p_instance_id);
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'part') THEN
    IF EXISTS (SELECT 1 FROM pgvigil.mssql_maint_part s WHERE s.instance_id = p_instance_id AND s.snapshot_at > p_snapshot_at) THEN
      RETURN;  -- an older read arriving late
    END IF;
    INSERT INTO pgvigil.mssql_maint_part AS t (instance_id, part, is_read, note, snapshot_at)
    SELECT DISTINCT ON (r->>'part') p_instance_id, r->>'part', coalesce(r->>'read' = '1', false), r->>'note', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'part' AND r->>'part' IS NOT NULL
    ON CONFLICT (instance_id, part) DO UPDATE SET is_read = EXCLUDED.is_read, note = EXCLUDED.note, snapshot_at = EXCLUDED.snapshot_at;
    -- the databases: replaced, each keeping its CommandLog epoch
    CREATE TEMP TABLE IF NOT EXISTS pgv_mt_epoch (database_name text PRIMARY KEY, epoch int, purity_read boolean, purity_note text,
        create_version int, dbcc_flags int, purity_on boolean, purity_at timestamptz, behind bigint) ON COMMIT DROP;
    DELETE FROM pgv_mt_epoch;
    INSERT INTO pgv_mt_epoch SELECT d.database_name, d.commandlog_epoch, d.purity_read, d.purity_note, d.create_version, d.dbcc_flags, d.purity_on,
           d.purity_at, d.commandlog_behind
      FROM pgvigil.mssql_maint_database d WHERE d.instance_id = p_instance_id;
    DELETE FROM pgvigil.mssql_maint_database d WHERE d.instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_maint_database (instance_id, database_name, install_read, note, objects, versions, commandlog_note, commandlog_epoch,
        purity_read, purity_note, create_version, dbcc_flags, purity_on, purity_at, commandlog_behind, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', coalesce(r->>'install_read' = '1', false), r->>'note',
           coalesce(ARRAY(SELECT jsonb_array_elements_text(CASE WHEN jsonb_typeof(r->'objects') = 'array' THEN r->'objects' ELSE '[]' END)), '{}'),
           CASE WHEN jsonb_typeof(r->'versions') = 'object' THEN r->'versions' ELSE '{}' END, r->>'commandlog_note',
           coalesce(e.epoch, 0),
           -- the flags read today kept (purity_kept and a read before), else as read now
           CASE WHEN k.kept THEN e.purity_read ELSE coalesce(r->>'purity_read' = '1', false) END,
           CASE WHEN k.kept THEN e.purity_note ELSE r->>'purity_note' END,
           CASE WHEN k.kept THEN e.create_version ELSE (r->>'create_version')::int END,
           CASE WHEN k.kept THEN e.dbcc_flags ELSE (r->>'dbcc_flags')::int END,
           CASE WHEN k.kept THEN e.purity_on WHEN r->>'purity_on' IS NULL THEN NULL ELSE r->>'purity_on' = '1' END,
           CASE WHEN k.kept THEN e.purity_at WHEN coalesce(r->>'purity_kept', '') <> '1' THEN p_snapshot_at END,
           e.behind, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
      LEFT JOIN pg_temp.pgv_mt_epoch e ON e.database_name = r->>'database_name'
      CROSS JOIN LATERAL (SELECT r->>'purity_kept' = '1' AND e.purity_at IS NOT NULL AS kept) k
     WHERE r->>'kind' = 'database' AND r->>'database_name' IS NOT NULL
     ORDER BY r->>'database_name';
    -- a database gone takes its CommandLog rows and their last runs with it
    DELETE FROM pgvigil.mssql_ola_commandlog c WHERE c.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_maint_database d WHERE d.instance_id = c.instance_id AND d.database_name = c.database_name);
    DELETE FROM pgvigil.mssql_maint_last l WHERE l.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_maint_database d WHERE d.instance_id = l.instance_id AND d.database_name = l.database_name);
  END IF;
  -- a CommandLog emptied or truncated: its rows from here on are a new epoch (the rows already read stay)
  UPDATE pgvigil.mssql_maint_database d SET commandlog_epoch = d.commandlog_epoch + 1
   WHERE d.instance_id = p_instance_id AND d.database_name IN (SELECT r->>'database_name' FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'reset');
  INSERT INTO pgvigil.mssql_ola_commandlog AS c (instance_id, database_name, epoch, id, db, schema_name, object_name, object_type, index_name,
      statistics_name, partition_number, command_type, backup_kind, start_at, end_at, error_number, error_message, command, status, snapshot_at)
  SELECT DISTINCT ON (r->>'database_name', (r->>'id')::bigint) p_instance_id, r->>'database_name',
         coalesce((SELECT d.commandlog_epoch FROM pgvigil.mssql_maint_database d WHERE d.instance_id = p_instance_id AND d.database_name = r->>'database_name'), 0),
         (r->>'id')::bigint, r->>'db', r->>'schema_name', r->>'object_name', r->>'object_type', r->>'index_name', r->>'statistics_name',
         (r->>'partition_number')::int, r->>'command_type', CASE WHEN r->>'backup_kind' IN ('full', 'diff', 'log') THEN r->>'backup_kind' END,
         (r->>'start_utc')::timestamptz, (r->>'end_utc')::timestamptz,
         (r->>'error_number')::int, left(r->>'error_message', 2000), left(r->>'command', 4000),
         CASE WHEN r->>'status' IN ('ok', 'failed', 'running', 'never closed') THEN r->>'status' ELSE 'ok' END, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'commandlog' AND r->>'database_name' IS NOT NULL AND r->>'id' ~ '^[0-9]{1,18}$'
     -- a CommandLog restored from an older backup (its IDs under the cursor: a new epoch) gives back rows already
     -- stored: one of an earlier epoch with the same ID and start is that row, not a new one
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_ola_commandlog o
                      WHERE o.instance_id = p_instance_id AND o.database_name = r->>'database_name' AND o.id = (r->>'id')::bigint
                        AND o.start_at IS NOT DISTINCT FROM (r->>'start_utc')::timestamptz
                        AND o.epoch < coalesce((SELECT d.commandlog_epoch FROM pgvigil.mssql_maint_database d
                                                 WHERE d.instance_id = p_instance_id AND d.database_name = r->>'database_name'), 0))
   ORDER BY r->>'database_name', (r->>'id')::bigint
  ON CONFLICT (instance_id, database_name, epoch, id) DO UPDATE SET
      db = EXCLUDED.db, schema_name = EXCLUDED.schema_name, object_name = EXCLUDED.object_name, object_type = EXCLUDED.object_type,
      index_name = EXCLUDED.index_name, statistics_name = EXCLUDED.statistics_name, partition_number = EXCLUDED.partition_number,
      command_type = EXCLUDED.command_type, backup_kind = EXCLUDED.backup_kind, start_at = EXCLUDED.start_at, end_at = EXCLUDED.end_at, error_number = EXCLUDED.error_number,
      error_message = EXCLUDED.error_message, command = EXCLUDED.command, status = EXCLUDED.status, snapshot_at = EXCLUDED.snapshot_at;
  -- the newest successful command of each kind per database worked on (the last part: a row per kind, not a scan)
  INSERT INTO pgvigil.mssql_maint_last AS l (instance_id, database_name, db, kind, last_at, seconds)
  SELECT p_instance_id, x.database_name, x.db, x.kind, max(x.start_at), (array_agg(x.seconds ORDER BY x.start_at DESC))[1]
    FROM (SELECT r->>'database_name' AS database_name, r->>'db' AS db, (r->>'start_utc')::timestamptz AS start_at,
                 extract(epoch FROM (r->>'end_utc')::timestamptz - (r->>'start_utc')::timestamptz)::numeric(12, 1) AS seconds,
                 CASE WHEN r->>'backup_kind' IN ('full', 'diff', 'log') THEN r->>'backup_kind'
                      WHEN r->>'command_type' IN ('DBCC_CHECKDB', 'DBCC_CHECKALLOC', 'DBCC_CHECKTABLE', 'DBCC_CHECKCATALOG', 'DBCC_CHECKFILEGROUP') THEN 'integrity'
                      WHEN r->>'command_type' IN ('ALTER_INDEX', 'UPDATE_STATISTICS') THEN 'index' END AS kind
            FROM jsonb_array_elements(p_payload) r
           WHERE r->>'kind' = 'commandlog' AND r->>'status' = 'ok' AND r->>'database_name' IS NOT NULL AND r->>'db' IS NOT NULL
             AND r->>'start_utc' IS NOT NULL) x
   WHERE x.kind IS NOT NULL
   GROUP BY x.database_name, x.db, x.kind
  ON CONFLICT (instance_id, database_name, db, kind) DO UPDATE SET last_at = EXCLUDED.last_at, seconds = EXCLUDED.seconds
   WHERE EXCLUDED.last_at >= l.last_at;
  -- how far each CommandLog's read stayed behind the table's end
  UPDATE pgvigil.mssql_maint_database d SET commandlog_behind = (r->>'behind')::bigint
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'commandlog_read' AND d.instance_id = p_instance_id AND d.database_name = r->>'database_name' AND r->>'behind' ~ '^[0-9]{1,18}$';
  -- where each CommandLog's next read starts, its open rows and the purity reads (0065's mssql_cursor), stamped with
  -- the read's own time (p_snapshot_at): the 'not read' rule compares it with the install part's, the same clock
  INSERT INTO pgvigil.mssql_cursor AS c (instance_id, source, last_seq, last_event_at, updated_at)
  SELECT DISTINCT ON (r->>'source') p_instance_id, r->>'source', (r->>'last_seq')::bigint, (r->>'last_event_at')::timestamptz, p_snapshot_at
    FROM jsonb_array_elements(p_payload) WITH ORDINALITY AS t(r, n)
   WHERE r->>'kind' = 'cursor' AND r->>'source' IS NOT NULL
   ORDER BY r->>'source', n DESC
  ON CONFLICT (instance_id, source) DO UPDATE SET last_seq = EXCLUDED.last_seq, last_event_at = EXCLUDED.last_event_at, updated_at = EXCLUDED.updated_at;
END $$;

-- 0160's mssql_config_expect_keys with kind 'job' (task 410): the maintenance jobs a site expects or does not
CREATE OR REPLACE FUNCTION pgvigil.mssql_config_expect_keys()
RETURNS TABLE (kind text, key text, vtype text, choices text[], takes_exclusions boolean, default_exclusions jsonb,
               default_on boolean, source text, rule text, label text, vmin bigint, vmax bigint)
LANGUAGE sql IMMUTABLE AS $$
  SELECT v.*, r.vmin, r.vmax FROM (VALUES
    ('database', 'recovery_model', 'choice', ARRAY['FULL', 'SIMPLE', 'BULK_LOGGED'], true, '["master", "tempdb", "model", "msdb"]'::jsonb, false, 'dbachecks policy', 'Database#13', 'recovery model'),
    ('database', 'scoped_maxdop', 'number', NULL, true, '[]'::jsonb, false, 'dbachecks policy', 'Database#43', 'database-scoped MAXDOP'),
    ('database', 'state', 'choice', ARRAY['on'], true, '[]'::jsonb, false, 'dbachecks policy', 'Database#44', 'databases restoring, read-only or in standby'),
    ('database', 'expected', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Database#45', 'expected databases'),
    ('database', 'query_store', 'choice', ARRAY['on', 'off'], true, '["master", "tempdb", "model"]'::jsonb, false, 'dbachecks policy', 'Database#52', 'Query Store'),
    ('service', 'engine_start_mode', 'choice', ARRAY['Automatic', 'Manual', 'Disabled', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#6', 'engine start mode'),
    ('service', 'agent_start_mode', 'choice', ARRAY['Automatic', 'Manual', 'Disabled', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#6', 'SQL Server Agent start mode'),
    ('instance', 'server_name', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#22', 'server name'),
    ('instance', 'max_memory', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'dbatools formula', 'Instance#20', 'max server memory'),
    ('instance', 'maxdop', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'dbatools formula', 'Instance#47', 'max degree of parallelism'),
    ('instance', 'startup_procs', 'choice', ARRAY['on', 'off'], false, '[]'::jsonb, true, 'Microsoft', 'Instance#55', 'scan for startup procs'),
    ('instance', 'errorlog_files', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#46', 'error log files kept'),
    ('xe', 'stopped', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#31', 'event sessions expected stopped'),
    ('xe', 'running', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#32', 'event sessions expected running'),
    ('xe', 'allowed', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#33', 'event sessions allowed to run'),
    ('xe', 'exists', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instancev5#46', 'event sessions expected to exist'),
    ('traceflag', 'expected', 'numlist', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#49', 'trace flags expected'),
    ('traceflag', 'not_expected', 'numlist', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Instance#50', 'trace flags not expected'),
    ('network', 'tcp_port', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#8', 'TCP port'),
    ('network', 'protocols', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#9', 'network protocols enabled'),
    ('network', 'cpu_priority', 'number', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Server#6', 'Windows processor scheduling (Win32PrioritySeparation)'),
    ('agent', 'operators', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'Agent operators expected'),
    ('agent', 'failsafe_operator', 'text', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'Agent fail-safe operator'),
    ('agent', 'job_owner_allow', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'job owners allowed'),
    ('agent', 'job_owner_deny', 'list', NULL, false, '[]'::jsonb, false, 'dbachecks policy', 'Agent', 'job owners not allowed'),
    -- task 410 (0161): the maintenance jobs a site expects, or does not, by the role's name (Ola's job name). A list of
    -- its own type, 'joblist': 0160's grid leaves it to 0161's rules
    ('job', 'expected', 'joblist', ARRAY['DatabaseBackup - SYSTEM_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - DIFF', 'DatabaseBackup - USER_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - LOG', 'DatabaseIntegrityCheck - SYSTEM_DATABASES', 'DatabaseIntegrityCheck - USER_DATABASES', 'IndexOptimize - USER_DATABASES', 'CommandLog Cleanup', 'sp_delete_backuphistory', 'sp_purge_jobhistory', 'Output File Cleanup'], false, '[]'::jsonb, false, 'dbachecks policy', 'MaintenanceSolution', 'maintenance jobs expected'),
    ('job', 'not_expected', 'joblist', ARRAY['DatabaseBackup - SYSTEM_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - DIFF', 'DatabaseBackup - USER_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - LOG', 'DatabaseIntegrityCheck - SYSTEM_DATABASES', 'DatabaseIntegrityCheck - USER_DATABASES', 'IndexOptimize - USER_DATABASES', 'CommandLog Cleanup', 'sp_delete_backuphistory', 'sp_purge_jobhistory', 'Output File Cleanup'], false, '[]'::jsonb, false, 'dbachecks policy', 'MaintenanceSolution', 'maintenance jobs not expected')
  ) v (kind, key, vtype, choices, takes_exclusions, default_exclusions, default_on, source, rule, label)
  -- a number key's range: what the server itself takes for the setting (MAXDOP 0 to 32767, 6 to 99 error log files, a
  -- TCP port, the six bits of Win32PrioritySeparation)
  LEFT JOIN (VALUES ('database', 'scoped_maxdop', 0::bigint, 32767::bigint), ('instance', 'errorlog_files', 6, 99),
                    ('network', 'tcp_port', 1, 65535), ('network', 'cpu_priority', 0, 63)) r (kind, key, vmin, vmax)
    ON r.kind = v.kind AND r.key = v.key
$$;

-- mssql_ola_roles: the jobs Ola's solution makes, by role (its job name), each with the platforms it is made on, the
-- procedure its step calls and the clean-up age it carries ('hours': @CleanupTime, 192 at least; 'days': a DATEADD
-- of days, 30 at least; NULL: none).
-- 409's import of an expectation, made again here with one more check: a list key with choices (the job names of
-- mssql_config_expect_keys above) takes only those. Here and not in 0160: a repository that ran 409's 0160 applies
-- a migration once by its name and would never get a change made to that file.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_config_expect(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op    text := p_payload->>'op';
  v_user  text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_level text := p_payload->>'level';
  v_inst  int;
  v_tag   text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_kind  text := lower(btrim(coalesce(p_payload->>'kind', '')));
  v_key   text := btrim(coalesce(p_payload->>'key', ''));
  v_raw   jsonb := p_payload->'value';
  v_excl  jsonb := p_payload->'exclusions';
  v_type  text;
  v_choices text[];
  v_min   bigint;       -- a number key's range (a server option: sys.configurations holds no value under 0 or over an int)
  v_max   bigint;
  v_takes boolean;      -- the key takes a list of databases left out
  v_defex jsonb;        -- ... and this list when the attempt names none
  v_val   jsonb;
  v_items text[];
  v_why   text;
  v_old   bigint;
  v_new   bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_mssql_config_expect: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'instance_id', '') ~ '^[0-9]{1,9}$' THEN
    v_inst := (p_payload->>'instance_id')::int;
  END IF;
  IF v_kind = 'config' THEN
    v_key := lower(v_key);
    v_type := 'number';
    v_min := 0;
    v_max := 2147483647;
  ELSE
    -- plain variables, not a record: a record no row was read into has no fields to ask (a 'config' attempt reads none)
    SELECT k.vtype, k.choices, k.takes_exclusions, k.default_exclusions, k.vmin, k.vmax INTO v_type, v_choices, v_takes, v_defex, v_min, v_max
      FROM pgvigil.mssql_config_expect_keys() k WHERE k.kind = v_kind AND k.key = v_key;
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('set', 'inherit') THEN
    v_why := 'op must be set or inherit';
  ELSIF v_level IS NULL OR v_level NOT IN ('root', 'tag', 'instance') THEN
    v_why := 'level must be root, tag or instance';
  ELSIF v_level = 'instance' AND (v_inst IS NULL OR NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = v_inst AND i.engine = 'sqlserver')) THEN
    v_why := 'an instance level names a SQL Server instance that exists';
  ELSIF v_level = 'tag' AND (v_tag IS NULL OR length(v_tag) > 200) THEN
    v_why := 'a tag level names its tag (200 characters at most)';
  ELSIF v_type IS NULL OR v_key = '' OR length(v_key) > 128 THEN
    v_why := 'no expectation can be set for this kind and key';
  ELSIF v_op = 'set' THEN
    IF v_raw IS NULL OR jsonb_typeof(v_raw) = 'null' THEN
      v_why := 'set takes a value';
    ELSIF v_kind = 'agent' AND v_key IN ('operators', 'failsafe_operator') AND v_raw::text LIKE '%@%' THEN
      -- an operator's name, never its address; a login's name may hold '@' (an Entra ID login owning a job)
      v_why := 'an e-mail address is never stored: name the operator, not its address';
    ELSIF v_type = 'number' THEN
      -- inside the key's range only: a value the server could never hold is refused here, not judged later
      IF (v_raw #>> '{}') ~ '^-?[0-9]{1,10}$' AND (v_raw #>> '{}')::bigint BETWEEN coalesce(v_min, 0) AND coalesce(v_max, 2147483647) THEN
        v_val := to_jsonb((v_raw #>> '{}')::bigint);
      ELSE
        v_why := format('the value must be a whole number from %s to %s', coalesce(v_min, 0), coalesce(v_max, 2147483647));
      END IF;
    ELSIF v_type = 'text' THEN
      IF jsonb_typeof(v_raw) = 'string' AND btrim(v_raw #>> '{}') <> '' AND length(v_raw #>> '{}') <= 200 THEN v_val := to_jsonb(btrim(v_raw #>> '{}'));
      ELSE v_why := 'the value must be a name (200 characters at most)'; END IF;
    ELSIF v_type = 'choice' THEN
      IF jsonb_typeof(v_raw) = 'string' AND (v_raw #>> '{}') = ANY (v_choices) THEN v_val := v_raw;
      ELSE v_why := 'the value must be one of: ' || array_to_string(v_choices, ', '); END IF;
    ELSE  -- list | numlist
      IF jsonb_typeof(v_raw) = 'array' THEN
        v_items := ARRAY(SELECT btrim(x) FROM jsonb_array_elements_text(v_raw) x WHERE btrim(x) <> '');
      ELSIF jsonb_typeof(v_raw) = 'string' THEN
        v_items := ARRAY(SELECT btrim(x) FROM unnest(string_to_array(v_raw #>> '{}', ',')) x WHERE btrim(x) <> '');
      END IF;
      IF v_items IS NULL OR cardinality(v_items) = 0 THEN
        v_why := 'the value must be a list with at least one name (inherit takes the expectation away)';
      ELSIF cardinality(v_items) > 500 OR EXISTS (SELECT 1 FROM unnest(v_items) x WHERE length(x) > 200) THEN
        v_why := 'a list holds 500 names at most, each 200 characters at most';
      ELSIF v_type = 'numlist' AND EXISTS (SELECT 1 FROM unnest(v_items) x WHERE x !~ '^[0-9]{1,9}$') THEN
        v_why := 'the value must be a list of whole numbers';
      ELSIF v_type = 'numlist' THEN
        v_val := (SELECT jsonb_agg(x::bigint ORDER BY x::bigint) FROM (SELECT DISTINCT x FROM unnest(v_items) x) s);
      ELSIF v_choices IS NOT NULL AND EXISTS (SELECT 1 FROM unnest(v_items) x WHERE NOT (x = ANY (v_choices))) THEN
        -- a list key with choices (0161's job names) takes only those
        v_why := 'the value must be a list of: ' || array_to_string(v_choices, ', ');
      ELSIF v_kind = 'network' AND v_key = 'protocols' AND EXISTS (SELECT 1 FROM unnest(v_items) x WHERE lower(x) NOT IN ('tcp', 'np', 'sm')) THEN
        v_why := 'the value must be a list of the protocols as SQL Server names them: Tcp, Np, Sm';
      ELSIF v_kind = 'network' AND v_key = 'protocols' THEN
        v_val := (SELECT jsonb_agg(DISTINCT CASE lower(x) WHEN 'tcp' THEN 'Tcp' WHEN 'np' THEN 'Np' ELSE 'Sm' END) FROM unnest(v_items) x);
      ELSE
        v_val := to_jsonb(v_items);
      END IF;
    END IF;
    IF v_why IS NULL THEN
      IF coalesce(v_takes, false) THEN
        IF v_excl IS NULL OR jsonb_typeof(v_excl) = 'null' THEN
          v_excl := coalesce(v_defex, '[]'::jsonb);
        ELSIF jsonb_typeof(v_excl) <> 'array' OR jsonb_array_length(v_excl) > 2000
              OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_excl) x WHERE jsonb_typeof(x) <> 'string' OR length(x #>> '{}') NOT BETWEEN 1 AND 128) THEN
          v_why := 'exclusions must be a list of database names';
        END IF;
      ELSIF v_excl IS NOT NULL AND jsonb_typeof(v_excl) = 'array' AND jsonb_array_length(v_excl) > 0 THEN
        v_why := 'this key takes no exclusions';
      ELSE
        v_excl := '[]'::jsonb;
      END IF;
    END IF;
  END IF;
  IF v_why IS NOT NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', v_why);
  END IF;
  IF v_level = 'root' THEN v_inst := NULL; v_tag := NULL;
  ELSIF v_level = 'tag' THEN v_inst := NULL;
  ELSE v_tag := NULL; END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_config_expect'), hashtext(v_level || '|' || coalesce(v_inst, 0) || '|' || coalesce(v_tag, '') || '|' || v_kind || '|' || v_key));
  SELECT t.expect_id INTO v_old FROM pgvigil.mssql_config_expect t
   WHERE t.ended_at IS NULL AND t.level = v_level AND coalesce(t.instance_id, 0) = coalesce(v_inst, 0)
     AND coalesce(t.tag, '') = coalesce(v_tag, '') AND t.kind = v_kind AND t.key = v_key;
  IF v_op = 'inherit' AND v_old IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this level has no expectation of its own: it inherits already');
  END IF;
  UPDATE pgvigil.mssql_config_expect SET ended_by = v_user, ended_at = p_at WHERE expect_id = v_old;
  IF v_op = 'inherit' THEN
    RETURN jsonb_build_object('outcome', 'done', 'detail', 'ended: the level above applies', 'expect_id', v_old);
  END IF;
  INSERT INTO pgvigil.mssql_config_expect (level, instance_id, tag, kind, key, value, exclusions, created_by, created_at, client, replaces)
  VALUES (v_level, v_inst, v_tag, v_kind, v_key, v_val, v_excl, v_user, p_at, nullif(p_payload->>'client', ''), v_old)
  RETURNING expect_id INTO v_new;
  RETURN jsonb_build_object('outcome', 'done', 'detail', 'set', 'expect_id', v_new);
END $$;

CREATE OR REPLACE FUNCTION pgvigil.mssql_ola_roles()
RETURNS TABLE (role text, platforms text[], pattern text, age_kind text, age_floor int)
LANGUAGE sql IMMUTABLE AS $$
  VALUES
    ('DatabaseBackup - SYSTEM_DATABASES - FULL', ARRAY['Windows', 'Linux'], '^(?=.*DatabaseBackup)(?=.*@Databases\s*=\s*N?''SYSTEM_DATABASES)(?=.*@BackupType\s*=\s*N?''FULL'')', 'hours', 192),
    ('DatabaseBackup - USER_DATABASES - DIFF', ARRAY['Windows', 'Linux'], '^(?=.*DatabaseBackup)(?=.*@Databases\s*=\s*N?''USER_DATABASES)(?=.*@BackupType\s*=\s*N?''DIFF'')', 'hours', 192),
    ('DatabaseBackup - USER_DATABASES - FULL', ARRAY['Windows', 'Linux'], '^(?=.*DatabaseBackup)(?=.*@Databases\s*=\s*N?''USER_DATABASES)(?=.*@BackupType\s*=\s*N?''FULL'')', 'hours', 192),
    ('DatabaseBackup - USER_DATABASES - LOG', ARRAY['Windows', 'Linux'], '^(?=.*DatabaseBackup)(?=.*@Databases\s*=\s*N?''USER_DATABASES)(?=.*@BackupType\s*=\s*N?''LOG'')', 'hours', 192),
    ('DatabaseIntegrityCheck - SYSTEM_DATABASES', ARRAY['Windows', 'Linux', 'Managed Instance'], 'DatabaseIntegrityCheck.*@Databases\s*=\s*N?''SYSTEM_DATABASES', NULL, NULL),
    ('DatabaseIntegrityCheck - USER_DATABASES', ARRAY['Windows', 'Linux', 'Managed Instance', 'RDS'], 'DatabaseIntegrityCheck.*@Databases\s*=\s*N?''USER_DATABASES', NULL, NULL),
    ('IndexOptimize - USER_DATABASES', ARRAY['Windows', 'Linux', 'Managed Instance', 'RDS'], 'IndexOptimize', NULL, NULL),
    ('CommandLog Cleanup', ARRAY['Windows', 'Linux', 'Managed Instance', 'RDS'], 'DELETE\s+FROM\s+\[?dbo\]?\.\[?CommandLog', 'days', 30),
    ('sp_delete_backuphistory', ARRAY['Windows', 'Linux', 'Managed Instance'], 'sp_delete_backuphistory', 'days', 30),
    ('sp_purge_jobhistory', ARRAY['Windows', 'Linux', 'Managed Instance'], 'sp_purge_jobhistory', 'days', 30),
    ('Output File Cleanup', ARRAY['Windows'], '(Get-ChildItem|ForFiles).*\*_\*_\*_\*\.txt', 'days', 30)
$$;

-- mssql_ola_age: the clean-up age a step's command carries, or NULL when the command names none the parser knows.
-- 'hours': DatabaseBackup's @CleanupTime (a word on its own: @MirrorCleanupTime is not it); absent or NULL = the
-- files are never removed, -1. 'days': DATEADD(dd, -N, ...) or AddDays(-N).
CREATE OR REPLACE FUNCTION pgvigil.mssql_ola_age(p_command text, p_kind text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_kind
    WHEN 'hours' THEN CASE
      WHEN p_command ~* '(^|[^A-Za-z_])@CleanupTime\s*=\s*NULL\M' THEN -1
      WHEN p_command ~* '(^|[^A-Za-z_])@CleanupTime\s*=\s*[0-9]+' THEN
        (SELECT CASE WHEN length(n) <= 9 THEN n::int END FROM substring(p_command FROM '(?i)(?:^|[^A-Za-z_])@CleanupTime\s*=\s*([0-9]+)') n)
      -- present but not a number or NULL (a text, a variable): not read
      WHEN p_command ~* '(^|[^A-Za-z_])@CleanupTime\s*=' THEN NULL
      -- absent from a step cut at the 8,000 characters the jobs collection keeps: not read
      WHEN length(p_command) >= 8000 THEN NULL
      WHEN p_command ~* 'DatabaseBackup' THEN -1
      END
    WHEN 'days' THEN CASE
      WHEN p_command ~* 'DATEADD\s*\(\s*(dd|d|day)\s*,\s*-\s*[0-9]+' THEN
        (SELECT CASE WHEN length(n) <= 9 THEN n::int END FROM substring(p_command FROM '(?i)DATEADD\s*\(\s*(?:dd|d|day)\s*,\s*-\s*([0-9]+)') n)
      WHEN p_command ~* 'AddDays\s*\(\s*-\s*[0-9]+' THEN
        (SELECT CASE WHEN length(n) <= 9 THEN n::int END FROM substring(p_command FROM '(?i)AddDays\s*\(\s*-\s*([0-9]+)') n)
      END
  END
$$;

-- mssql_maint_closed: a database the read could not enter at all (the login has no access, the database is not
-- online, a secondary replica: read on the primary), by the note the collector wrote
CREATE OR REPLACE FUNCTION pgvigil.mssql_maint_closed(p_note text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(p_note LIKE 'not read: no access%' OR p_note LIKE 'not read: the database is %' OR p_note LIKE 'not read: a secondary replica%', false)
$$;

-- mssql_ola_matched_jobs: the jobs of one instance that run the solution, each with its role - by what a step calls,
-- else Ola's description and the role's name, else the name alone (the history clean-ups only where the solution may
-- be) - its role's command, and the expectation in force for the role. The rules and the Maintenance tab's Jobs grid
-- read the same match.
CREATE OR REPLACE FUNCTION pgvigil.mssql_ola_matched_jobs(p_instance_id integer)
RETURNS TABLE (role text, job_id text, name text, enabled boolean, enabled_schedules int, last_outcome int, last_run_at timestamptz,
               command text, verdict text, verdict_at text)
LANGUAGE sql STABLE AS $$
WITH x AS (
  SELECT i.instance_id,
         CASE WHEN i.platform = 'rdssqlserver' THEN 'RDS' WHEN i.platform = 'azuresqlmi' THEN 'Managed Instance'
              WHEN (SELECT f.value #>> '{}' FROM pgvigil.mssql_confcheck_fact f WHERE f.instance_id = i.instance_id AND f.key = 'host_platform') = 'Linux' THEN 'Linux'
              ELSE 'Windows' END AS plat,
         (SELECT p.is_read FROM pgvigil.mssql_maint_part p WHERE p.instance_id = i.instance_id AND p.part = 'install') AS part_read,
         (SELECT p.note FROM pgvigil.mssql_maint_part p WHERE p.instance_id = i.instance_id AND p.part = 'install') AS note,
         (SELECT p.snapshot_at FROM pgvigil.mssql_maint_part p WHERE p.instance_id = i.instance_id AND p.part = 'install') AS at,
         (SELECT c.snapshot_at FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id AND c.collection = 'mssql_jobs') AS jobs_at,
         EXISTS (SELECT 1 FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id AND c.collection = 'mssql_jobs' AND c.status = 'ok') AS jobs_read
    FROM pgvigil.instances i
   WHERE i.instance_id = p_instance_id AND i.engine = 'sqlserver' AND i.platform IS DISTINCT FROM 'azuresqldb'
), d AS (
  SELECT * FROM pgvigil.mssql_maint_database m WHERE m.instance_id = p_instance_id
), inst AS (   -- the databases holding the whole solution (only where the login could see the procedures)
  SELECT d.database_name, d.versions FROM d WHERE d.install_read AND d.objects @> ARRAY['CommandExecute', 'CommandLog', 'DatabaseBackup', 'DatabaseIntegrityCheck', 'IndexOptimize']
), e AS (
  SELECT * FROM pgvigil.mssql_config_expect_in_force(p_instance_id) WHERE kind = 'job'
), r AS (
  SELECT ro.*, x.plat = ANY (ro.platforms) AS made_here,
         ro.role IN ('sp_delete_backuphistory', 'sp_purge_jobhistory', 'Output File Cleanup') AS generic
    FROM pgvigil.mssql_ola_roles() ro CROSS JOIN x
), jx AS (     -- each role's expectation in force: the more specific level between expected and not_expected
  SELECT DISTINCT ON (r.role) r.role, e.key AS verdict, e.set_at
    FROM r JOIN e ON pgvigil.mssql_cc_in(e.value, r.role)
   ORDER BY r.role, CASE WHEN e.set_at = 'instance' THEN 1 WHEN e.set_at LIKE 'tag:%' THEN 2 ELSE 3 END, e.key
), ola AS (    -- the solution is installed, or a database the login could enter was not looked into
  SELECT EXISTS (SELECT 1 FROM inst) OR EXISTS (SELECT 1 FROM d WHERE NOT d.install_read AND NOT pgvigil.mssql_maint_closed(d.note)) AS maybe
), jc AS (     -- each job once, its steps' commands in step order
  SELECT j.job_id, j.name, j.enabled, j.enabled_schedules, j.description, j.last_outcome, j.last_run_at,
         coalesce((SELECT jsonb_agg(coalesce(s->>'command', '') ORDER BY (s->>'step_id')::int)
                     FROM jsonb_array_elements(CASE WHEN jsonb_typeof(j.steps) = 'array' THEN j.steps ELSE '[]' END) s), '[]'::jsonb) AS cmds
    FROM pgvigil.mssql_jobs j WHERE j.instance_id = p_instance_id
), m0 AS (     -- each role's jobs: by what a step calls (the history clean-ups only where the solution may be, or by its
               -- description or name), else Ola's description and the name, else the name alone; the role's own steps
  SELECT r.role, jc.job_id, jc.name, jc.enabled, jc.enabled_schedules, jc.last_outcome, jc.last_run_at,
         (SELECT string_agg(c, ' ' ORDER BY n) FROM jsonb_array_elements_text(jc.cmds) WITH ORDINALITY t(c, n) WHERE c ~* r.pattern) AS own,
         (SELECT string_agg(c, ' ' ORDER BY n) FROM jsonb_array_elements_text(jc.cmds) WITH ORDINALITY t(c, n)) AS everything,
         jc.description = 'Source: https://ola.hallengren.com' AS ola_made, r.generic
    FROM r CROSS JOIN jc
), m AS (
  SELECT m0.role, m0.job_id, m0.name, m0.enabled, m0.enabled_schedules, m0.last_outcome, m0.last_run_at, coalesce(m0.own, m0.everything, '') AS command,
         jx.verdict, jx.set_at AS verdict_at
    FROM m0 CROSS JOIN ola LEFT JOIN jx ON jx.role = m0.role
   WHERE (m0.own IS NOT NULL AND (NOT m0.generic OR ola.maybe OR m0.ola_made OR m0.name = m0.role))
      OR (m0.name = m0.role AND (m0.ola_made OR coalesce(m0.everything, '') !~* '(DatabaseBackup|DatabaseIntegrityCheck|IndexOptimize|CommandLog|sp_delete_backuphistory|sp_purge_jobhistory)'))
)
SELECT m.role, m.job_id, m.name, m.enabled, m.enabled_schedules, m.last_outcome, m.last_run_at, m.command, m.verdict, m.verdict_at FROM m
$$;

-- mssql_maintenance_checks_of: every maintenance rule of one SQL Server instance, met or not.
-- status: ok | info | warning | critical | off | not read | not applicable. info is shown amber and raises no finding.
CREATE OR REPLACE FUNCTION pgvigil.mssql_maintenance_checks_of(p_instance_id integer)
RETURNS TABLE (rule text, check_name text, object text, value text, expected text, set_at text, source text, status text, detail text, at timestamptz)
LANGUAGE sql STABLE AS $$
WITH x AS (
  SELECT i.instance_id,
         CASE WHEN i.platform = 'rdssqlserver' THEN 'RDS' WHEN i.platform = 'azuresqlmi' THEN 'Managed Instance'
              WHEN (SELECT f.value #>> '{}' FROM pgvigil.mssql_confcheck_fact f WHERE f.instance_id = i.instance_id AND f.key = 'host_platform') = 'Linux' THEN 'Linux'
              ELSE 'Windows' END AS plat,
         (SELECT p.is_read FROM pgvigil.mssql_maint_part p WHERE p.instance_id = i.instance_id AND p.part = 'install') AS part_read,
         (SELECT p.note FROM pgvigil.mssql_maint_part p WHERE p.instance_id = i.instance_id AND p.part = 'install') AS note,
         (SELECT p.snapshot_at FROM pgvigil.mssql_maint_part p WHERE p.instance_id = i.instance_id AND p.part = 'install') AS at,
         (SELECT c.snapshot_at FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id AND c.collection = 'mssql_jobs') AS jobs_at,
         EXISTS (SELECT 1 FROM pgvigil.collection_dates c WHERE c.instance_id = i.instance_id AND c.collection = 'mssql_jobs' AND c.status = 'ok') AS jobs_read
    FROM pgvigil.instances i
   WHERE i.instance_id = p_instance_id AND i.engine = 'sqlserver' AND i.platform IS DISTINCT FROM 'azuresqldb'
), d AS (
  SELECT * FROM pgvigil.mssql_maint_database m WHERE m.instance_id = p_instance_id
), inst AS (   -- the databases holding the whole solution (only where the login could see the procedures)
  SELECT d.database_name, d.versions FROM d WHERE d.install_read AND d.objects @> ARRAY['CommandExecute', 'CommandLog', 'DatabaseBackup', 'DatabaseIntegrityCheck', 'IndexOptimize']
), e AS (
  SELECT * FROM pgvigil.mssql_config_expect_in_force(p_instance_id) WHERE kind = 'job'
), r AS (
  SELECT ro.*, x.plat = ANY (ro.platforms) AS made_here,
         ro.role IN ('sp_delete_backuphistory', 'sp_purge_jobhistory', 'Output File Cleanup') AS generic
    FROM pgvigil.mssql_ola_roles() ro CROSS JOIN x
), jx AS (     -- each role's expectation in force: the more specific level between expected and not_expected
  SELECT DISTINCT ON (r.role) r.role, e.key AS verdict, e.set_at
    FROM r JOIN e ON pgvigil.mssql_cc_in(e.value, r.role)
   ORDER BY r.role, CASE WHEN e.set_at = 'instance' THEN 1 WHEN e.set_at LIKE 'tag:%' THEN 2 ELSE 3 END, e.key
), m AS (
  SELECT * FROM pgvigil.mssql_ola_matched_jobs(p_instance_id)
)
-- 1. the solution installed: in each database holding it whole, its version; a part of it is a warning
SELECT 'MaintenanceSolution#1-2', 'maintenance solution installed', i.database_name,
       coalesce((SELECT string_agg(DISTINCT v, ', ') FROM jsonb_each_text(i.versions) t(k, v)), 'version not read'), NULL::text, NULL::text,
       'Ola Hallengren', 'ok', format('the solution is in %s: the four procedures and dbo.CommandLog', i.database_name), x.at
  FROM inst i CROSS JOIN x
UNION ALL
-- a part: at least one of the four procedures (an application's own dbo.CommandLog alone is no install)
SELECT 'MaintenanceSolution#1-2', 'maintenance solution installed', d.database_name, array_to_string(d.objects, ', '), NULL, NULL, 'Ola Hallengren', 'warning',
       'a part of the solution: missing ' || array_to_string(ARRAY(SELECT o FROM unnest(ARRAY['CommandExecute', 'CommandLog', 'DatabaseBackup', 'DatabaseIntegrityCheck', 'IndexOptimize']) o
                                                                WHERE NOT (o = ANY (d.objects))), ', '), x.at
  FROM d CROSS JOIN x
 WHERE d.install_read AND d.objects && ARRAY['CommandExecute', 'DatabaseBackup', 'DatabaseIntegrityCheck', 'IndexOptimize']
   AND NOT EXISTS (SELECT 1 FROM inst i WHERE i.database_name = d.database_name)
UNION ALL
-- a database the login could enter but not look into (no VIEW DEFINITION, an error, the run's deadline) holds the row
-- 'not read'; one it cannot enter at all (no access, not online) is named, and does not
SELECT 'MaintenanceSolution#1-2', 'maintenance solution installed', '', NULL, NULL, NULL, 'Ola Hallengren',
       CASE WHEN x.part_read IS NULL THEN 'not read' WHEN EXISTS (SELECT 1 FROM d WHERE NOT d.install_read AND NOT pgvigil.mssql_maint_closed(d.note)) THEN 'not read' ELSE 'info' END,
       CASE WHEN x.part_read IS NULL THEN 'not read yet (mssql_maintenance)'
            WHEN EXISTS (SELECT 1 FROM d WHERE NOT d.install_read AND NOT pgvigil.mssql_maint_closed(d.note))
              THEN format('not found in the databases read; not read in %s: %s', (SELECT count(*) FROM d WHERE NOT d.install_read AND NOT pgvigil.mssql_maint_closed(d.note)),
                          (SELECT string_agg(DISTINCT coalesce(d.note, 'not read'), '; ') FROM d WHERE NOT d.install_read AND NOT pgvigil.mssql_maint_closed(d.note)))
            ELSE 'not installed: no database read holds the solution (another maintenance tool may be in use)'
                 || coalesce('; not looked into: ' || (SELECT string_agg(d.database_name || ' (' || CASE WHEN d.note LIKE 'not read: no access%' THEN 'no access' ELSE replace(d.note, 'not read: ', '') END || ')', ', ' ORDER BY d.database_name)
                                                        FROM d WHERE NOT d.install_read AND pgvigil.mssql_maint_closed(d.note)), '') END,
       x.at
  FROM x
 WHERE NOT EXISTS (SELECT 1 FROM d WHERE d.install_read AND d.objects && ARRAY['CommandExecute', 'DatabaseBackup', 'DatabaseIntegrityCheck', 'IndexOptimize'])
UNION ALL
-- 2. each job the solution makes on this platform: present, enabled, scheduled, its clean-up age; a role in force as
--    not expected is off on every row (its job may stay, disabled)
SELECT 'MaintenanceSolution#3-13', 'maintenance job', r.role, NULL, NULL,
       (SELECT CASE jx.verdict WHEN 'expected' THEN 'expected' ELSE 'not expected' END || ' (set at ' || jx.set_at || ')' FROM jx WHERE jx.role = r.role),
       'dbachecks policy',
       CASE WHEN NOT x.jobs_read THEN 'not read'
            WHEN (SELECT jx.verdict FROM jx WHERE jx.role = r.role) = 'not_expected' THEN 'off'
            WHEN (SELECT jx.verdict FROM jx WHERE jx.role = r.role) = 'expected' THEN 'warning' ELSE 'info' END,
       CASE WHEN NOT x.jobs_read THEN 'the jobs were not read yet (mssql_jobs)'
            WHEN (SELECT jx.verdict FROM jx WHERE jx.role = r.role) = 'not_expected' THEN 'not expected here'
            ELSE 'not present: no job runs it' END,
       x.jobs_at
  FROM r CROSS JOIN x
 WHERE (r.made_here OR EXISTS (SELECT 1 FROM jx WHERE jx.role = r.role AND jx.verdict = 'expected'))
   AND EXISTS (SELECT 1 FROM inst) AND NOT EXISTS (SELECT 1 FROM m WHERE m.role = r.role)
UNION ALL
SELECT 'MaintenanceSolution#3-13', 'maintenance job enabled', m.role || ': ' || m.name, CASE WHEN m.enabled THEN 'enabled' ELSE 'disabled' END, 'enabled',
       CASE WHEN m.verdict IS NOT NULL THEN replace(m.verdict, '_', ' ') || ' (set at ' || m.verdict_at || ')' END, 'dbachecks policy',
       CASE WHEN m.verdict = 'not_expected' THEN 'off' WHEN m.enabled THEN 'ok' ELSE 'warning' END,
       CASE WHEN m.verdict = 'not_expected' THEN 'not expected here: not judged'
            WHEN m.enabled THEN 'the job is enabled' ELSE 'the job is disabled: the maintenance it runs does not happen' END, x.jobs_at
  FROM m CROSS JOIN x
UNION ALL
SELECT 'MaintenanceSolution#3-13', 'maintenance job scheduled', m.role || ': ' || m.name, coalesce(m.enabled_schedules, 0)::text, 'at least 1',
       CASE WHEN m.verdict IS NOT NULL THEN replace(m.verdict, '_', ' ') || ' (set at ' || m.verdict_at || ')' END, 'dbachecks policy',
       CASE WHEN m.verdict = 'not_expected' THEN 'off' WHEN coalesce(m.enabled_schedules, 0) > 0 THEN 'ok' ELSE 'warning' END,
       CASE WHEN m.verdict = 'not_expected' THEN 'not expected here: not judged'
            WHEN coalesce(m.enabled_schedules, 0) > 0 THEN format('%s enabled schedule(s)', m.enabled_schedules)
            ELSE 'no enabled schedule: the job runs only when started by hand (the solution makes its jobs without schedules)' END, x.jobs_at
  FROM m CROSS JOIN x
UNION ALL
SELECT 'MaintenanceSolution#3-13', 'maintenance clean-up age', m.role || ': ' || m.name,
       CASE WHEN a.age = -1 THEN 'never removed' WHEN a.age IS NULL THEN NULL ELSE a.age::text || ' ' || r.age_kind END,
       'at least ' || r.age_floor || ' ' || r.age_kind,
       CASE WHEN m.verdict IS NOT NULL THEN replace(m.verdict, '_', ' ') || ' (set at ' || m.verdict_at || ')' END, 'dbachecks policy',
       CASE WHEN m.verdict = 'not_expected' THEN 'off' WHEN a.age IS NULL THEN 'not read' WHEN a.age = -1 OR a.age >= r.age_floor THEN 'ok' ELSE 'info' END,
       CASE WHEN m.verdict = 'not_expected' THEN 'not expected here: not judged'
            WHEN a.age IS NULL THEN 'age not read: the step names no clean-up age the check knows'
            WHEN a.age = -1 THEN 'the backup files are never removed by the job'
            WHEN a.age >= r.age_floor THEN format('%s %s kept', a.age, r.age_kind)
            ELSE format('%s %s kept: under the %s %s dbachecks asks for', a.age, r.age_kind, r.age_floor, r.age_kind) END, x.jobs_at
  FROM m JOIN r ON r.role = m.role CROSS JOIN x
  CROSS JOIN LATERAL (SELECT pgvigil.mssql_ola_age(m.command, r.age_kind) AS age) a
 WHERE r.age_kind IS NOT NULL
UNION ALL
-- 3. the maintenance history, read at the install part's time (a closed row is read once; the rule keeps it 24 hours)
SELECT 'MaintenanceSolution#1', 'maintenance command failed', c.database_name || ': ' || coalesce(c.db, '') || coalesce('.' || c.object_name, '') || ' ' || coalesce(c.command_type, '') || ' #' || c.id,
       c.error_number::text, '0', NULL, 'Ola Hallengren',
       -- a deadlock victim, a lock timeout or a page lock wait: info once a job of the command's own role (an index
       -- or statistics command: IndexOptimize's; a DBCC: an integrity check's; a backup: a backup's) succeeded since
       CASE WHEN c.error_number IN (1205, 1222, 5245)
                 AND EXISTS (SELECT 1 FROM m WHERE m.last_outcome = 1 AND m.last_run_at > c.start_at
                                AND m.role LIKE CASE WHEN c.command_type IN ('ALTER_INDEX', 'UPDATE_STATISTICS') THEN 'IndexOptimize%'
                                                     WHEN c.command_type LIKE 'DBCC%' THEN 'DatabaseIntegrityCheck%'
                                                     WHEN c.backup_kind IS NOT NULL OR c.command_type IN ('BACKUP_DATABASE', 'BACKUP_LOG', 'xp_backup_database', 'xp_backup_log', 'sqlbackup', 'xp_ss_backup', 'emc_run_backup') THEN 'DatabaseBackup%'
                                                     ELSE '%' END) THEN 'info' ELSE 'warning' END,
       format('error %s at %s UTC: %s', c.error_number, to_char(c.start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
              coalesce(c.error_message, 'the message is not in CommandLog (see the job''s history)')), x.at
  FROM pgvigil.mssql_ola_commandlog c CROSS JOIN x
 WHERE c.instance_id = p_instance_id AND c.status = 'failed' AND c.start_at > now() - interval '24 hours'
UNION ALL
SELECT 'MaintenanceSolution#1', 'maintenance command never closed', c.database_name || ': ' || coalesce(c.command_type, '') || ' #' || c.id, NULL, NULL, NULL, 'Ola Hallengren', 'info',
       format('started %s UTC and never ended (no EndTime after %s days): the command was cut or its session ended', to_char(c.start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), 7), x.at
  FROM pgvigil.mssql_ola_commandlog c CROSS JOIN x
 WHERE c.instance_id = p_instance_id AND c.status = 'never closed' AND c.start_at > now() - interval '8 days'
UNION ALL
SELECT 'MaintenanceSolution#1', 'maintenance history read', d.database_name, NULL, NULL, NULL, 'Ola Hallengren', 'not read', d.commandlog_note, x.at
  FROM d CROSS JOIN x WHERE d.commandlog_note IS NOT NULL
UNION ALL
-- a CommandLog the login may read that the last read did not reach (a read error, the run's deadline): not read
SELECT 'MaintenanceSolution#1', 'maintenance history read', d.database_name, NULL, NULL, NULL, 'Ola Hallengren', 'not read',
       'not read: the last read did not reach this CommandLog (a read error or the run''s deadline; the collection''s log says which)', x.at
  FROM d CROSS JOIN x
 WHERE d.commandlog_note IS NULL AND d.install_read AND d.objects @> ARRAY['CommandExecute', 'CommandLog']
   AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_cursor u WHERE u.instance_id = p_instance_id AND u.source = 'mssql_maintenance:' || d.database_name AND u.updated_at >= x.at)
UNION ALL
-- a CommandLog read that ended behind the table's end (the run's deadline or its cap): info, how far (the next runs
-- read on)
SELECT 'MaintenanceSolution#1', 'maintenance history read', d.database_name, d.commandlog_behind::text, '0', NULL, 'Ola Hallengren', 'info',
       format('the last read stayed %s rows behind the table''s end (the run''s deadline or its cap of 50,000 rows): the next runs read on', d.commandlog_behind), x.at
  FROM d CROSS JOIN x
 WHERE d.commandlog_note IS NULL AND d.commandlog_behind > 0 AND d.objects @> ARRAY['CommandExecute', 'CommandLog']
UNION ALL
-- 4. data purity (Database#11): off only for a database made before SQL Server 2005 whose DBCC flags are 0
SELECT 'Database#11', 'data purity checks', d.database_name, d.create_version::text || '/' || d.dbcc_flags::text, 'on', NULL, 'dbachecks policy', 'warning',
       format('data purity checks are off: the database was made before SQL Server 2005 (create version %s) and no CHECKDB WITH DATA_PURITY has run (flags %s)', d.create_version, d.dbcc_flags), x.at
  FROM d CROSS JOIN x WHERE d.purity_read AND d.purity_on IS FALSE
UNION ALL
SELECT 'Database#11', 'data purity checks', d.database_name, NULL, 'on', NULL, 'dbachecks policy', 'not read', coalesce(d.purity_note, 'not read'), x.at
  FROM d CROSS JOIN x WHERE NOT d.purity_read
UNION ALL
-- the rule's own row: never ok with no flag read
SELECT 'Database#11', 'data purity checks', '', (SELECT count(*) FROM d WHERE d.purity_read AND d.purity_on)::text || ' database(s)', 'on', NULL, 'dbachecks policy',
       CASE WHEN x.part_read IS NULL OR NOT EXISTS (SELECT 1 FROM d WHERE d.purity_read) THEN 'not read' ELSE 'ok' END,
       CASE WHEN x.part_read IS NULL THEN 'not read yet (mssql_maintenance)'
            WHEN NOT EXISTS (SELECT 1 FROM d WHERE d.purity_read) THEN 'no database''s purity flag was read (each database says why)'
            ELSE format('on in %s database(s) read', (SELECT count(*) FROM d WHERE d.purity_read AND d.purity_on)) END, x.at
  FROM x WHERE NOT EXISTS (SELECT 1 FROM d WHERE d.purity_read AND d.purity_on IS FALSE)
$$;

CREATE OR REPLACE VIEW pgvigil.mssql_maintenance_checks AS
SELECT i.instance_id, c.rule, c.check_name, c.object, c.value, c.expected, c.set_at, c.source, c.status, c.detail, c.at
  FROM pgvigil.instances i
  CROSS JOIN LATERAL pgvigil.mssql_maintenance_checks_of(i.instance_id) c
 WHERE i.is_active AND i.engine = 'sqlserver' AND i.platform IS DISTINCT FROM 'azuresqldb';

-- the findings: the warning and critical rows read in the last three hours (the jobs' time is mssql_jobs')
CREATE OR REPLACE VIEW pgvigil.mssql_maintenance_findings AS
SELECT c.instance_id, c.status AS severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.mssql_maintenance_checks c
 WHERE c.status IN ('warning', 'critical') AND c.at > now() - interval '3 hours';
