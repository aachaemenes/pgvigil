-- 0090: the SQL Server day-one checks (collections mssql_checks, hourly, and mssql_identity, every six hours:
-- internal/mssql/checks.go, dboptions.go, agentalerts.go). The collector judges every value against its rule and
-- the repository stores the value WITH its verdict, so a page can show every option a rule covers, met or not
-- (DBA Dash colours its Configuration and DB Options grids this way; pgvigil.setting_rules, 0099, is the
-- PostgreSQL side).
--   mssql_check_area       per area of the read, whether it was read and why not: config, build, dboptions,
--                          dbstate, logspace, checkdb, corruption, alerts (mssql_checks), identity (mssql_identity),
--                          traceflags (mssql_traceflags: 0094's import_mssql_traceflags writes its row and findings)
--   mssql_check_finding    every rule that is broken now, with its rule (the source tool and its check) and number
--   mssql_server_option    every sys.configurations option: value in use, default, advised value, verdict
--   mssql_database_option  every database: each option's value (options) and the options that deviate (deviations)
--   mssql_build            the instance's build against the catalogue: updates behind, support ends
--   mssql_suspect_page     msdb.dbo.suspect_pages as last read
--   mssql_agent_alert, mssql_agent_operator, mssql_agent_alerting   SQL Server Agent's alerts, operators, fail-safe
--   mssql_identity_column, mssql_identity_scan   the identity columns at 10 per cent of their range or more, and
--                          per database whether it was scanned
-- Views: mssql_checks_findings (the findings columns: the join adds the arm to pgvigil.findings),
-- mssql_checks_status (one Summary cell per area), mssql_option_risks (the fleet's risk counts per instance).
-- The trace flags have one store, 0094's mssql_trace_flags and mssql_trace_flag_history (the collection
-- mssql_traceflags, judged by checks.go's rules); the checks' grid of them is 0094's view mssql_trace_flag_checks.
-- An area the login could not read keeps what an earlier read stored: its rows, its findings and the time of the
-- last read that did read it. No table grows by the month: each holds the current state, and a row no longer present
-- (an option, a database) is kept marked so for 30 days and then deleted by the import itself; purge() has nothing
-- to do here.

CREATE TABLE IF NOT EXISTS pgvigil.mssql_check_area (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  area         text NOT NULL,
  is_read      boolean NOT NULL,
  note         text,                      -- why not read, or what the read left out
  snapshot_at  timestamptz NOT NULL,      -- the last run that covered the area, read or not
  read_at      timestamptz,               -- the last run that read it
  PRIMARY KEY (instance_id, area)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_check_finding (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  area         text NOT NULL,
  check_name   text NOT NULL,
  object       text NOT NULL,             -- the option, the database, the flag, the alert
  rule         text NOT NULL,             -- the source tool and its check: sp_Blitz 12, dbachecks AutoClose
  severity     text NOT NULL CHECK (severity IN ('critical', 'warning', 'info')),
  value        text,                      -- the number that broke the rule
  detail       text,
  first_seen   timestamptz NOT NULL,      -- the first read of the run of reads that raised it
  snapshot_at  timestamptz NOT NULL,
  PRIMARY KEY (instance_id, area, check_name, object, rule)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_server_option (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name           text NOT NULL,
  value_in_use   bigint,
  value_set      bigint,
  default_value  bigint,                  -- NULL = no default known
  advised        text,                    -- the value the broken rule asks for
  status         text NOT NULL CHECK (status IN ('ok', 'warn', 'crit', 'none')),
  severity       text,                    -- of the broken rule: critical, warning, info
  rule           text,
  detail         text,
  snapshot_at    timestamptz NOT NULL,
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_database_option (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  database_id    int,
  state          text,
  is_system      boolean NOT NULL DEFAULT false,
  is_snapshot    boolean NOT NULL DEFAULT false,
  options        jsonb NOT NULL DEFAULT '{}',   -- option key -> value as read (a bit as on / off)
  deviations     jsonb NOT NULL DEFAULT '{}',   -- option key -> {status, severity, rule, explain} of the broken rule
  snapshot_at    timestamptz NOT NULL,
  is_present     boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, database_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_build (
  instance_id          int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at          timestamptz NOT NULL,
  known                boolean NOT NULL,   -- the catalogue has the major version and the build is the customer's to choose
  exact                boolean NOT NULL,   -- the catalogue lists this very build
  newer                boolean NOT NULL,   -- the instance is newer than the catalogue's newest build
  status               text NOT NULL,
  branch               text,               -- CU14, SP3, RTM
  update_name          text,
  release_date         date,
  mainstream_end       date,
  extended_end         date,
  newest_build         int,
  newest_branch        text,
  newest_release_date  date,
  behind               int,                -- builds of the catalogue newer than the instance's
  cus_behind           int,                -- of them, cumulative updates
  catalogue            text,               -- the catalogue's source and date
  note                 text
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_suspect_page (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_id     int NOT NULL,
  file_id         int NOT NULL,
  page_id         bigint NOT NULL,
  event_type      int NOT NULL,
  database_name   text,
  event           text,
  error_count     int,
  last_update_at  timestamptz,
  snapshot_at     timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_id, file_id, page_id, event_type)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_agent_alert (
  instance_id                int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name                       text NOT NULL,
  message_id                 int,
  severity                   int,
  enabled                    boolean,
  delay_s                    int,
  include_event_description  boolean,
  occurrence_count           int,
  last_occurrence_at         timestamptz,
  has_job                    boolean,
  notifies                   int,          -- operators the alert notifies
  snapshot_at                timestamptz NOT NULL,
  PRIMARY KEY (instance_id, name)
);

-- An operator's addresses are never stored: has_email says whether one is set.
CREATE TABLE IF NOT EXISTS pgvigil.mssql_agent_operator (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  name           text NOT NULL,
  enabled        boolean,
  has_email      boolean,
  last_email_at  timestamptz,
  snapshot_at    timestamptz NOT NULL,
  PRIMARY KEY (instance_id, name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_agent_alerting (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  failsafe_read      boolean NOT NULL DEFAULT false,
  failsafe_operator  text,
  snapshot_at        timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_identity_column (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  schema_name    text NOT NULL,
  table_name     text NOT NULL,
  column_name    text NOT NULL,
  type_name      text,
  last_value     numeric,
  max_value      numeric,
  pct_used       numeric(9, 2),
  status         text NOT NULL DEFAULT 'ok',
  -- the rate: the value at the anchor read (moved up once it is over seven days old) against the value now
  anchor_value   numeric,
  anchor_at      timestamptz,
  per_day        numeric,                 -- NULL until two reads an hour apart or more
  days_left      numeric,                 -- NULL without a rate
  snapshot_at    timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, schema_name, table_name, column_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.mssql_identity_scan (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database_name  text NOT NULL,
  scanned        boolean NOT NULL,
  columns_total  int,                     -- identity columns of the database's user tables
  listed         int,                     -- of them, at the floor or over
  note           text,                    -- why not scanned
  snapshot_at    timestamptz NOT NULL,
  scanned_at     timestamptz,             -- the last read that scanned it
  PRIMARY KEY (instance_id, database_name)
);

-- payload of mssql_checks, by row kind: 'area' {area, read, note}; 'finding' {area, check_name, object, severity,
-- rule, value, explain}; 'server_option' {name, value_in_use, value_set, default_value, advised, status, severity,
-- rule, explain}; 'database' {database_id, database_name, state, is_system, is_snapshot, options, deviations};
-- 'build' {known, exact, newer, status, branch, update_name, release_date, mainstream_end, extended_end,
-- newest_build, newest_branch, newest_release_date, behind, cus_behind, catalogue, note}; 'suspect_page'
-- {database_id, database_name, file_id, page_id, event_type, event, error_count, last_update_utc}; 'alert',
-- 'operator', 'agent_alerting'. A read older than the newest one stored
-- changes nothing; the same read twice leaves the same rows.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_checks(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  -- traceflags is mssql_traceflags' (0094): a payload's rows of it are not this import's
  v_areas CONSTANT text[] := ARRAY['config', 'build', 'dboptions', 'dbstate', 'logspace', 'checkdb', 'corruption', 'alerts'];
  v_read text[];
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_checks: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_checks'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_check_area a
              WHERE a.instance_id = p_instance_id AND a.area = ANY (v_areas) AND a.snapshot_at > p_snapshot_at) THEN
    RETURN;  -- an older read arriving late
  END IF;
  -- the 'area' rows; then the findings of the areas this payload READ are replaced (an area not read keeps its
  -- findings; a finding still raised keeps its first_seen)
  INSERT INTO pgvigil.mssql_check_area AS a (instance_id, area, is_read, note, snapshot_at, read_at)
  SELECT DISTINCT ON (r->>'area') p_instance_id, r->>'area', coalesce((r->>'read')::int, 0) = 1, r->>'note', p_snapshot_at,
         CASE WHEN coalesce((r->>'read')::int, 0) = 1 THEN p_snapshot_at END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'area' AND r->>'area' = ANY (v_areas)
   ORDER BY r->>'area'
  ON CONFLICT (instance_id, area) DO UPDATE SET
      is_read = EXCLUDED.is_read, note = EXCLUDED.note, snapshot_at = EXCLUDED.snapshot_at,
      read_at = coalesce(EXCLUDED.read_at, a.read_at);
  SELECT coalesce(array_agg(a.area), '{}') INTO v_read
    FROM pgvigil.mssql_check_area a
   WHERE a.instance_id = p_instance_id AND a.area = ANY (v_areas) AND a.is_read AND a.snapshot_at = p_snapshot_at;

  INSERT INTO pgvigil.mssql_check_finding AS f (instance_id, area, check_name, object, rule, severity, value, detail, first_seen, snapshot_at)
  SELECT DISTINCT ON (r->>'area', r->>'check_name', coalesce(r->>'object', ''), coalesce(r->>'rule', ''))
         p_instance_id, r->>'area', r->>'check_name', coalesce(r->>'object', ''), coalesce(r->>'rule', ''), r->>'severity',
         r->>'value', r->>'explain', p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'finding' AND r->>'area' = ANY (v_read) AND r->>'check_name' IS NOT NULL
     AND r->>'severity' IN ('critical', 'warning', 'info')
   ORDER BY r->>'area', r->>'check_name', coalesce(r->>'object', ''), coalesce(r->>'rule', ''),
            CASE r->>'severity' WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END
  ON CONFLICT (instance_id, area, check_name, object, rule) DO UPDATE SET
      severity = EXCLUDED.severity, value = EXCLUDED.value, detail = EXCLUDED.detail, snapshot_at = EXCLUDED.snapshot_at;
  DELETE FROM pgvigil.mssql_check_finding f
   WHERE f.instance_id = p_instance_id AND f.area = ANY (v_read) AND f.snapshot_at < p_snapshot_at;

  IF 'config' = ANY (v_read) THEN
    INSERT INTO pgvigil.mssql_server_option AS o (instance_id, name, value_in_use, value_set, default_value, advised, status, severity, rule, detail, snapshot_at)
    SELECT DISTINCT ON (r->>'name') p_instance_id, r->>'name', (r->>'value_in_use')::bigint, (r->>'value_set')::bigint,
           (r->>'default_value')::bigint, r->>'advised', coalesce(r->>'status', 'none'), r->>'severity', r->>'rule', r->>'explain', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'server_option' AND r->>'name' IS NOT NULL
     ORDER BY r->>'name'
    ON CONFLICT (instance_id, name) DO UPDATE SET
        value_in_use = EXCLUDED.value_in_use, value_set = EXCLUDED.value_set, default_value = EXCLUDED.default_value,
        advised = EXCLUDED.advised, status = EXCLUDED.status, severity = EXCLUDED.severity, rule = EXCLUDED.rule,
        detail = EXCLUDED.detail, snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.mssql_server_option o SET is_present = false
     WHERE o.instance_id = p_instance_id AND o.is_present AND o.snapshot_at < p_snapshot_at;
    DELETE FROM pgvigil.mssql_server_option o
     WHERE o.instance_id = p_instance_id AND NOT o.is_present AND o.snapshot_at < p_snapshot_at - interval '30 days';
  END IF;

  IF 'dboptions' = ANY (v_read) THEN
    INSERT INTO pgvigil.mssql_database_option AS d (instance_id, database_name, database_id, state, is_system, is_snapshot, options, deviations, snapshot_at)
    SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', (r->>'database_id')::int, r->>'state',
           coalesce((r->>'is_system')::int, 0) = 1, coalesce((r->>'is_snapshot')::int, 0) = 1,
           coalesce(nullif(r->'options', 'null'), '{}'), coalesce(nullif(r->'deviations', 'null'), '{}'), p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'database' AND r->>'database_name' IS NOT NULL
     ORDER BY r->>'database_name'
    ON CONFLICT (instance_id, database_name) DO UPDATE SET
        database_id = EXCLUDED.database_id, state = EXCLUDED.state, is_system = EXCLUDED.is_system, is_snapshot = EXCLUDED.is_snapshot,
        -- a read that could not read the logs keeps the log values and their cells an earlier read stored
        options = CASE WHEN 'logspace' = ANY (v_read) THEN EXCLUDED.options
                       ELSE EXCLUDED.options || coalesce((SELECT jsonb_object_agg(e.key, e.value) FROM jsonb_each(d.options) e
                                                           WHERE e.key IN ('log_size_mb', 'log_used_pct', 'vlf_count') AND NOT EXCLUDED.options ? e.key), '{}') END,
        deviations = CASE WHEN 'logspace' = ANY (v_read) THEN EXCLUDED.deviations
                          ELSE EXCLUDED.deviations || coalesce((SELECT jsonb_object_agg(e.key, e.value) FROM jsonb_each(d.deviations) e
                                                                 WHERE e.key IN ('log_used_pct', 'vlf_count') AND NOT EXCLUDED.deviations ? e.key), '{}') END,
        snapshot_at = EXCLUDED.snapshot_at, is_present = true;
    UPDATE pgvigil.mssql_database_option d SET is_present = false
     WHERE d.instance_id = p_instance_id AND d.is_present AND d.snapshot_at < p_snapshot_at;
    DELETE FROM pgvigil.mssql_database_option d
     WHERE d.instance_id = p_instance_id AND NOT d.is_present AND d.snapshot_at < p_snapshot_at - interval '30 days';
  END IF;

  INSERT INTO pgvigil.mssql_build AS b (instance_id, snapshot_at, known, exact, newer, status, branch, update_name, release_date,
      mainstream_end, extended_end, newest_build, newest_branch, newest_release_date, behind, cus_behind, catalogue, note)
  SELECT p_instance_id, p_snapshot_at, coalesce((r->>'known')::int, 0) = 1, coalesce((r->>'exact')::int, 0) = 1,
         coalesce((r->>'newer')::int, 0) = 1, coalesce(r->>'status', 'none'), r->>'branch', r->>'update_name', (r->>'release_date')::date,
         (r->>'mainstream_end')::date, (r->>'extended_end')::date, (r->>'newest_build')::int, r->>'newest_branch',
         (r->>'newest_release_date')::date, (r->>'behind')::int, (r->>'cus_behind')::int, r->>'catalogue', r->>'note'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'build'
   LIMIT 1
  ON CONFLICT (instance_id) DO UPDATE SET
      snapshot_at = EXCLUDED.snapshot_at, known = EXCLUDED.known, exact = EXCLUDED.exact, newer = EXCLUDED.newer, status = EXCLUDED.status,
      branch = EXCLUDED.branch, update_name = EXCLUDED.update_name, release_date = EXCLUDED.release_date,
      mainstream_end = EXCLUDED.mainstream_end, extended_end = EXCLUDED.extended_end, newest_build = EXCLUDED.newest_build,
      newest_branch = EXCLUDED.newest_branch, newest_release_date = EXCLUDED.newest_release_date, behind = EXCLUDED.behind,
      cus_behind = EXCLUDED.cus_behind, catalogue = EXCLUDED.catalogue, note = EXCLUDED.note;

  IF 'corruption' = ANY (v_read) THEN
    DELETE FROM pgvigil.mssql_suspect_page s WHERE s.instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_suspect_page (instance_id, database_id, file_id, page_id, event_type, database_name, event, error_count, last_update_at, snapshot_at)
    SELECT DISTINCT ON ((r->>'database_id')::int, (r->>'file_id')::int, (r->>'page_id')::bigint, (r->>'event_type')::int)
           p_instance_id, (r->>'database_id')::int, (r->>'file_id')::int, (r->>'page_id')::bigint, (r->>'event_type')::int,
           r->>'database_name', r->>'event', (r->>'error_count')::int, (r->>'last_update_utc')::timestamptz, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'suspect_page' AND r->>'database_id' IS NOT NULL AND r->>'file_id' IS NOT NULL
       AND r->>'page_id' IS NOT NULL AND r->>'event_type' IS NOT NULL
     ORDER BY 2, 3, 4, 5, (r->>'last_update_utc')::timestamptz DESC NULLS LAST;
  END IF;

  IF 'alerts' = ANY (v_read) THEN
    DELETE FROM pgvigil.mssql_agent_alert a WHERE a.instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_agent_alert (instance_id, name, message_id, severity, enabled, delay_s, include_event_description,
        occurrence_count, last_occurrence_at, has_job, notifies, snapshot_at)
    SELECT DISTINCT ON (r->>'name') p_instance_id, r->>'name', (r->>'message_id')::int, (r->>'severity')::int, (r->>'enabled')::int = 1,
           (r->>'delay_s')::int, (r->>'include_event_description')::int <> 0, (r->>'occurrence_count')::int,
           (r->>'last_occurrence_utc')::timestamptz, (r->>'has_job')::int = 1, (r->>'notifies')::int, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'alert' AND r->>'name' IS NOT NULL
     ORDER BY r->>'name';
    DELETE FROM pgvigil.mssql_agent_operator o WHERE o.instance_id = p_instance_id;
    INSERT INTO pgvigil.mssql_agent_operator (instance_id, name, enabled, has_email, last_email_at, snapshot_at)
    SELECT DISTINCT ON (r->>'name') p_instance_id, r->>'name', (r->>'enabled')::int = 1, (r->>'has_email')::int = 1,
           (r->>'last_email_utc')::timestamptz, p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'operator' AND r->>'name' IS NOT NULL
     ORDER BY r->>'name';
    INSERT INTO pgvigil.mssql_agent_alerting AS g (instance_id, failsafe_read, failsafe_operator, snapshot_at)
    SELECT p_instance_id, coalesce((r->>'failsafe_read')::int, 0) = 1, r->>'failsafe_operator', p_snapshot_at
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'agent_alerting'
     LIMIT 1
    ON CONFLICT (instance_id) DO UPDATE SET
        failsafe_read = EXCLUDED.failsafe_read, failsafe_operator = EXCLUDED.failsafe_operator, snapshot_at = EXCLUDED.snapshot_at;
  END IF;
END $$;

-- payload of mssql_identity: 'area' {area 'identity', read, note}; 'identity_scan' {database_name, scanned,
-- columns_total, listed, note}; 'identity' {database_name, schema_name, table_name, column_name, type_name,
-- last_value, max_value, pct_used, status}; 'finding'. The columns of a database this read scanned are replaced
-- by the read's; a database not scanned keeps its columns and their findings. The rate: the anchor is the value of
-- the first read (moved to the read before once it is over seven days old; to the new value when the value went
-- down: a reseed); per_day and days_left need an anchor an hour old or more.
CREATE OR REPLACE FUNCTION pgvigil.import_mssql_identity(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_scanned text[];
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_identity: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_mssql_identity'), p_instance_id);
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_check_area a
              WHERE a.instance_id = p_instance_id AND a.area = 'identity' AND a.snapshot_at > p_snapshot_at) THEN
    RETURN;  -- an older read arriving late
  END IF;

  INSERT INTO pgvigil.mssql_identity_scan AS s (instance_id, database_name, scanned, columns_total, listed, note, snapshot_at, scanned_at)
  SELECT DISTINCT ON (r->>'database_name') p_instance_id, r->>'database_name', coalesce((r->>'scanned')::int, 0) = 1,
         (r->>'columns_total')::int, (r->>'listed')::int, r->>'note', p_snapshot_at,
         CASE WHEN coalesce((r->>'scanned')::int, 0) = 1 THEN p_snapshot_at END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'identity_scan' AND r->>'database_name' IS NOT NULL
   ORDER BY r->>'database_name'
  ON CONFLICT (instance_id, database_name) DO UPDATE SET
      scanned = EXCLUDED.scanned, note = EXCLUDED.note, snapshot_at = EXCLUDED.snapshot_at,
      columns_total = CASE WHEN EXCLUDED.scanned THEN EXCLUDED.columns_total ELSE s.columns_total END,
      listed = CASE WHEN EXCLUDED.scanned THEN EXCLUDED.listed ELSE s.listed END,
      scanned_at = coalesce(EXCLUDED.scanned_at, s.scanned_at);
  -- a database the server no longer lists: its scan row and its columns go
  DELETE FROM pgvigil.mssql_identity_scan s WHERE s.instance_id = p_instance_id AND s.snapshot_at < p_snapshot_at;
  DELETE FROM pgvigil.mssql_identity_column c
   WHERE c.instance_id = p_instance_id
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_identity_scan s WHERE s.instance_id = c.instance_id AND s.database_name = c.database_name);
  SELECT coalesce(array_agg(s.database_name), '{}') INTO v_scanned
    FROM pgvigil.mssql_identity_scan s
   WHERE s.instance_id = p_instance_id AND s.scanned AND s.snapshot_at = p_snapshot_at;

  INSERT INTO pgvigil.mssql_identity_column AS c (instance_id, database_name, schema_name, table_name, column_name, type_name,
      last_value, max_value, pct_used, status, anchor_value, anchor_at, snapshot_at)
  SELECT DISTINCT ON (r->>'database_name', r->>'schema_name', r->>'table_name', r->>'column_name')
         p_instance_id, r->>'database_name', r->>'schema_name', r->>'table_name', r->>'column_name', r->>'type_name',
         (r->>'last_value')::numeric, (r->>'max_value')::numeric, (r->>'pct_used')::numeric(9, 2), coalesce(r->>'status', 'ok'),
         (r->>'last_value')::numeric, p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'identity' AND r->>'database_name' = ANY (v_scanned) AND r->>'schema_name' IS NOT NULL
     AND r->>'table_name' IS NOT NULL AND r->>'column_name' IS NOT NULL
   ORDER BY r->>'database_name', r->>'schema_name', r->>'table_name', r->>'column_name'
  ON CONFLICT (instance_id, database_name, schema_name, table_name, column_name) DO UPDATE SET
      type_name = EXCLUDED.type_name, max_value = EXCLUDED.max_value, pct_used = EXCLUDED.pct_used, status = EXCLUDED.status,
      -- a value that went down (a reseed) anchors at the new value; an anchor over seven days old moves to the read before
      anchor_value = CASE WHEN EXCLUDED.last_value < c.last_value THEN EXCLUDED.last_value
                          WHEN c.anchor_at < EXCLUDED.snapshot_at - interval '7 days' THEN c.last_value ELSE c.anchor_value END,
      anchor_at = CASE WHEN EXCLUDED.last_value < c.last_value THEN EXCLUDED.snapshot_at
                       WHEN c.anchor_at < EXCLUDED.snapshot_at - interval '7 days' THEN c.snapshot_at ELSE c.anchor_at END,
      last_value = EXCLUDED.last_value, snapshot_at = EXCLUDED.snapshot_at;
  -- a column of a scanned database that this read no longer lists (dropped, reseeded under the floor)
  DELETE FROM pgvigil.mssql_identity_column c
   WHERE c.instance_id = p_instance_id AND c.database_name = ANY (v_scanned) AND c.snapshot_at < p_snapshot_at;
  UPDATE pgvigil.mssql_identity_column c SET
      per_day = x.per_day,
      days_left = CASE WHEN x.per_day > 0 THEN round((c.max_value - c.last_value) / x.per_day, 1) END
    FROM (SELECT i.database_name, i.schema_name, i.table_name, i.column_name,
                 CASE WHEN i.snapshot_at - i.anchor_at >= interval '1 hour' AND i.last_value >= i.anchor_value
                      THEN round((i.last_value - i.anchor_value) / (extract(epoch FROM i.snapshot_at - i.anchor_at)::numeric / 86400), 2) END AS per_day
            FROM pgvigil.mssql_identity_column i
           WHERE i.instance_id = p_instance_id AND i.snapshot_at = p_snapshot_at) x
   WHERE c.instance_id = p_instance_id AND c.database_name = x.database_name AND c.schema_name = x.schema_name
     AND c.table_name = x.table_name AND c.column_name = x.column_name;

  -- the findings follow the columns: one whose column is gone, or no longer past a threshold, is deleted; a database
  -- not scanned keeps its columns and so its findings; a dropped database's went with its columns above. The read's
  -- own findings are upserted below.
  DELETE FROM pgvigil.mssql_check_finding f
   WHERE f.instance_id = p_instance_id AND f.area = 'identity'
     AND NOT EXISTS (SELECT 1 FROM pgvigil.mssql_identity_column c
                      WHERE c.instance_id = f.instance_id AND c.status <> 'ok'
                        AND c.database_name || '.' || c.schema_name || '.' || c.table_name || '.' || c.column_name = f.object);
  INSERT INTO pgvigil.mssql_check_finding AS f (instance_id, area, check_name, object, rule, severity, value, detail, first_seen, snapshot_at)
  SELECT DISTINCT ON (r->>'check_name', r->>'object', coalesce(r->>'rule', ''))
         p_instance_id, 'identity', r->>'check_name', r->>'object', coalesce(r->>'rule', ''), r->>'severity', r->>'value', r->>'explain',
         p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'finding' AND r->>'area' = 'identity' AND r->>'check_name' IS NOT NULL AND r->>'object' IS NOT NULL
     AND r->>'severity' IN ('critical', 'warning', 'info')
   ORDER BY r->>'check_name', r->>'object', coalesce(r->>'rule', '')
  ON CONFLICT (instance_id, area, check_name, object, rule) DO UPDATE SET
      severity = EXCLUDED.severity, value = EXCLUDED.value, detail = EXCLUDED.detail, snapshot_at = EXCLUDED.snapshot_at;

  INSERT INTO pgvigil.mssql_check_area AS a (instance_id, area, is_read, note, snapshot_at, read_at)
  SELECT p_instance_id, 'identity', coalesce((r->>'read')::int, 0) = 1, r->>'note', p_snapshot_at,
         CASE WHEN coalesce((r->>'read')::int, 0) = 1 THEN p_snapshot_at END
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'area' AND r->>'area' = 'identity'
   LIMIT 1
  ON CONFLICT (instance_id, area) DO UPDATE SET
      is_read = EXCLUDED.is_read, note = EXCLUDED.note, snapshot_at = EXCLUDED.snapshot_at, read_at = coalesce(EXCLUDED.read_at, a.read_at);
END $$;

-- The findings of the two collections in the findings columns (check_name, object, at, detail as the other SQL
-- Server arms have them; rule and value beside them). A collection whose last run covering the area is older than
-- three of its intervals raises nothing: the Collections page says the collection is stale (three hours for the
-- hourly checks, eighteen for the six-hourly identity scan). A finding of an area the last run could not read stays:
-- it is the last thing known, and the area's cell says it is not read now. The detail ends with the rule and the
-- number, so every page that lists a finding shows both.
CREATE OR REPLACE VIEW pgvigil.mssql_checks_findings AS
SELECT f.instance_id, f.severity, f.check_name, f.object, f.snapshot_at AS at,
       f.detail || ' [rule: ' || f.rule || coalesce('; value: ' || nullif(f.value, ''), '') || ']' AS detail,
       f.area, f.rule, f.value, f.first_seen
  FROM pgvigil.mssql_check_finding f
  JOIN pgvigil.mssql_check_area a ON a.instance_id = f.instance_id AND a.area = f.area
 WHERE a.snapshot_at > now() - CASE WHEN f.area = 'identity' THEN interval '18 hours' ELSE interval '3 hours' END;

-- One Summary cell per area and instance, in the shape of mssql_health_status (0070): sampled = the area has been
-- read, critical and warning = the count of findings at that level, value the cell's word, detail the sentences
-- behind it (twelve at most).
CREATE OR REPLACE VIEW pgvigil.mssql_checks_status AS
SELECT a.instance_id, a.area AS key, a.read_at IS NOT NULL AS sampled,
       coalesce(x.critical, 0) AS critical, coalesce(x.warning, 0) AS warning,
       CASE WHEN a.read_at IS NULL THEN NULL
            WHEN a.area = 'identity' THEN (SELECT count(*) FROM pgvigil.mssql_identity_column c WHERE c.instance_id = a.instance_id AND c.status <> 'ok')::text || ' of '
                 || (SELECT coalesce(sum(s.columns_total), 0) FROM pgvigil.mssql_identity_scan s WHERE s.instance_id = a.instance_id AND s.scanned)::text || ' columns'
            WHEN a.area = 'checkdb' THEN coalesce(x.n, 0)::text || ' of ' || (SELECT count(*) FROM pgvigil.mssql_database_option d
                   WHERE d.instance_id = a.instance_id AND d.is_present AND d.options ? 'last_good_checkdb')::text || ' databases'
            WHEN a.area = 'logspace' THEN coalesce((SELECT max((d.options->>'log_used_pct')::numeric) FROM pgvigil.mssql_database_option d
                   WHERE d.instance_id = a.instance_id AND d.is_present AND d.options ? 'log_used_pct')::text || ' % at most', 'no log read')
            WHEN a.area = 'corruption' THEN (SELECT count(*) FROM pgvigil.mssql_suspect_page s WHERE s.instance_id = a.instance_id AND s.event_type IN (1, 2, 3))::text || ' pages'
            WHEN a.area = 'alerts' THEN (SELECT count(*) FILTER (WHERE g.enabled) FROM pgvigil.mssql_agent_alert g WHERE g.instance_id = a.instance_id)::text || ' alerts'
            WHEN a.area = 'build' THEN (SELECT CASE WHEN NOT b.known THEN 'not weighed' WHEN b.newer THEN 'newer than the catalogue'
                                                    WHEN b.behind = 0 THEN 'newest' ELSE b.behind::text || ' behind' END
                                          FROM pgvigil.mssql_build b WHERE b.instance_id = a.instance_id)
            ELSE coalesce(x.n, 0)::text || ' deviation' || CASE WHEN coalesce(x.n, 0) = 1 THEN '' ELSE 's' END END AS value,
       CASE WHEN NOT a.is_read AND a.note IS NOT NULL THEN ARRAY['not read now: ' || a.note] || coalesce(x.detail, '{}'::text[])
            ELSE coalesce(x.detail, '{}'::text[]) END AS detail,
       a.is_read, a.note, a.snapshot_at, a.read_at
  FROM pgvigil.mssql_check_area a
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE f.severity = 'critical')::int AS critical,
           count(*) FILTER (WHERE f.severity = 'warning')::int AS warning, count(*)::int AS n,
           (array_agg(f.detail ORDER BY CASE f.severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, f.check_name, f.object)
              FILTER (WHERE f.severity <> 'info'))[1:12] AS detail
      FROM pgvigil.mssql_checks_findings f
     WHERE f.instance_id = a.instance_id AND f.area = a.area) x ON true;

-- The fleet's risk counts, one row per instance (DBA Dash's DB Options summary): the databases with each risky
-- option, the largest count of virtual log files, and the server options that deviate. A count is the number of
-- present databases whose cell for that option deviates.
CREATE OR REPLACE VIEW pgvigil.mssql_option_risks AS
SELECT i.instance_id, i.name AS instance_name,
       d.snapshot_at AS databases_read_at, coalesce(d.databases, 0) AS databases, coalesce(d.user_databases, 0) AS user_databases,
       coalesce(d.page_verify, 0) AS page_verify, coalesce(d.auto_close, 0) AS auto_close, coalesce(d.auto_shrink, 0) AS auto_shrink,
       coalesce(d.stats_off, 0) AS stats_off, coalesce(d.old_compat, 0) AS old_compat, coalesce(d.trustworthy, 0) AS trustworthy,
       coalesce(d.no_indirect_checkpoint, 0) AS no_indirect_checkpoint, coalesce(d.delayed_durability, 0) AS delayed_durability,
       coalesce(d.not_online, 0) AS not_online, coalesce(d.not_multi_user, 0) AS not_multi_user,
       d.max_vlf, coalesce(d.vlf_high, 0) AS vlf_high,
       o.snapshot_at AS options_read_at, coalesce(o.critical, 0) AS option_critical, coalesce(o.warning, 0) AS option_warning,
       coalesce(o.advice, 0) AS option_advice, coalesce(o.options, 0) AS options
  FROM pgvigil.instances i
  LEFT JOIN LATERAL (
    SELECT max(x.snapshot_at) AS snapshot_at, count(*)::int AS databases,
           count(*) FILTER (WHERE NOT x.is_system AND NOT x.is_snapshot)::int AS user_databases,
           count(*) FILTER (WHERE x.deviations ? 'page_verify')::int AS page_verify,
           count(*) FILTER (WHERE x.deviations ? 'auto_close')::int AS auto_close,
           count(*) FILTER (WHERE x.deviations ? 'auto_shrink')::int AS auto_shrink,
           count(*) FILTER (WHERE x.deviations ?| ARRAY['auto_create_stats', 'auto_update_stats'])::int AS stats_off,
           count(*) FILTER (WHERE x.deviations ? 'compatibility_level')::int AS old_compat,
           count(*) FILTER (WHERE x.deviations ? 'trustworthy')::int AS trustworthy,
           count(*) FILTER (WHERE x.deviations ? 'target_recovery_secs' AND x.options->>'target_recovery_secs' = '0')::int AS no_indirect_checkpoint,
           count(*) FILTER (WHERE x.deviations ? 'delayed_durability')::int AS delayed_durability,
           count(*) FILTER (WHERE x.deviations ? 'state')::int AS not_online,
           count(*) FILTER (WHERE x.deviations ? 'user_access')::int AS not_multi_user,
           max((x.options->>'vlf_count')::bigint) AS max_vlf,
           count(*) FILTER (WHERE x.deviations ? 'vlf_count')::int AS vlf_high
      FROM pgvigil.mssql_database_option x
     WHERE x.instance_id = i.instance_id AND x.is_present) d ON true
  LEFT JOIN LATERAL (
    SELECT max(s.snapshot_at) AS snapshot_at, count(*)::int AS options,
           count(*) FILTER (WHERE s.status = 'crit')::int AS critical,
           count(*) FILTER (WHERE s.status = 'warn' AND s.severity = 'warning')::int AS warning,
           count(*) FILTER (WHERE s.status = 'warn' AND s.severity = 'info')::int AS advice
      FROM pgvigil.mssql_server_option s
     WHERE s.instance_id = i.instance_id AND s.is_present) o ON true
 WHERE i.engine = 'sqlserver' AND i.is_active;
