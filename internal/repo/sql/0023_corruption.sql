-- 0023_corruption: the Corruption column (phase 2, task 34).
--   log_events kinds      'plan' (an auto_explain entry: the plan text in statement, its duration) and 'corruption'
--                         (a damaged page, file, TOAST value or commit log status: the message with its DETAIL /
--                         CONTEXT in detail, the statement that met it), both from internal/logparse
--   amcheck_runs          the opt-in amcheck collection: per run, database and check (bt_index_check,
--                         verify_heapam) the relations checked, the corrupt ones and their messages; monthly partitions
--   amcheck_latest        the newest run per instance, database and check (what the tab shows)
--   amcheck_state         the newest run per instance, database and check that is complete or found damage: a run
--                         cut short by its budget, or failing, neither clears nor hides an earlier finding
--   corruption_class      the class of a corruption message (checksum, invalid page, short read, missing file,
--                         commit log, toast, freeze)
--   corruption_events     the log's corruption events with their class and relation path
--   corruption_settings   per instance the three settings that decide whether damage is seen: data_checksums,
--                         ignore_checksum_failure, zero_damaged_pages
--   corruption_findings   in pgvigil.findings' ten columns: checksums off, ignore_checksum_failure on,
--                         zero_damaged_pages on, a corruption message in the last 24 h, amcheck damage
--   corruption_summary    one row per active instance for the tab's header and the fleet
--
-- The kind CHECK: 0024 drops and re-adds log_events_kind_check without these two kinds, and on a fresh install it
-- runs after this file; the wave's join migration re-adds the constraint with every kind. Here the constraint is
-- widened for a repository that applied 0024 before this file existed (an upgrade from v0.2).

ALTER TABLE pgvigil.log_events DROP CONSTRAINT IF EXISTS log_events_kind_check;
ALTER TABLE pgvigil.log_events ADD CONSTRAINT log_events_kind_check
  CHECK (kind IN ('slow', 'lock_wait', 'deadlock', 'auth_fail', 'autovacuum', 'plan', 'corruption'));

CREATE INDEX IF NOT EXISTS log_events_corruption ON pgvigil.log_events (instance_id, snapshot_at) WHERE kind = 'corruption';

CREATE TABLE IF NOT EXISTS pgvigil.amcheck_runs (
  instance_id   int NOT NULL,
  snapshot_at   timestamptz NOT NULL,   -- the run's start
  datname       text NOT NULL,
  check_name    text NOT NULL,          -- bt_index_check | verify_heapam
  status        text NOT NULL CHECK (status IN ('ok', 'corrupt', 'error', 'partial', 'skipped')),
  checked       int NOT NULL DEFAULT 0, -- relations checked to the end
  total         int NOT NULL DEFAULT 0, -- relations the check applies to in the database
  corrupt       int NOT NULL DEFAULT 0, -- relations the check reported damage in
  errors        int NOT NULL DEFAULT 0, -- relations the check could not finish (a timeout, a lock, a privilege)
  problems      jsonb,                  -- [{relation, message}], the first 50
  note          text,                   -- a skip's reason, the budget reached
  duration_ms   int
) PARTITION BY RANGE (snapshot_at);
CREATE INDEX IF NOT EXISTS amcheck_runs_idx ON pgvigil.amcheck_runs (instance_id, datname, check_name, snapshot_at);

-- payload: rows {kind:'run', datname, check_name, status, checked, total, corrupt, errors, problems, note, duration_ms}
-- and {kind:'collector_error', source, message} (not stored here: RunOnce records the run as partial). A run moves the
-- cursor 'amcheck' in log_cursor to its start: the collector reads it and skips until its interval has passed.
CREATE OR REPLACE FUNCTION pgvigil.import_amcheck(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'run') THEN
    RETURN;
  END IF;
  INSERT INTO pgvigil.log_cursor AS c (instance_id, source, read_to, updated_at)
  VALUES (p_instance_id, 'amcheck', p_snapshot_at, now())
  ON CONFLICT (instance_id, source) DO UPDATE SET read_to = greatest(c.read_to, EXCLUDED.read_to), updated_at = now();
  PERFORM pgvigil.ensure_month_partition('amcheck_runs', p_snapshot_at);
  INSERT INTO pgvigil.amcheck_runs (instance_id, snapshot_at, datname, check_name, status, checked, total, corrupt, errors,
                                    problems, note, duration_ms)
  SELECT p_instance_id, p_snapshot_at, r->>'datname', r->>'check_name', r->>'status',
         coalesce((r->>'checked')::int, 0), coalesce((r->>'total')::int, 0), coalesce((r->>'corrupt')::int, 0),
         coalesce((r->>'errors')::int, 0), nullif(r->'problems', 'null'::jsonb), r->>'note', (r->>'duration_ms')::int
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'run';
END $$;

CREATE OR REPLACE VIEW pgvigil.amcheck_latest AS
SELECT DISTINCT ON (r.instance_id, r.datname, r.check_name) r.*
  FROM pgvigil.amcheck_runs r
 ORDER BY r.instance_id, r.datname, r.check_name, r.snapshot_at DESC;

CREATE OR REPLACE VIEW pgvigil.amcheck_state AS
SELECT DISTINCT ON (r.instance_id, r.datname, r.check_name) r.*
  FROM pgvigil.amcheck_runs r
 WHERE r.status = 'ok' OR r.corrupt > 0
 ORDER BY r.instance_id, r.datname, r.check_name, r.snapshot_at DESC;

-- the class of a corruption message (logparse.corruptionRE's families); NULL when the instance's query_text policy
-- kept no detail
CREATE OR REPLACE FUNCTION pgvigil.corruption_class(p_detail text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_detail IS NULL THEN 'unknown'
    WHEN p_detail ~ '^(page verification failed|ignoring checksum failure|ignoring [0-9]+ checksum failures)' THEN 'checksum'
    WHEN p_detail ~ '^(invalid page in block|[0-9]+ invalid pages among blocks|zeroing out [0-9]+ invalid pages|zeroing [0-9]+ page)' THEN 'invalid page'
    WHEN p_detail ~ '^index ".*" contains (unexpected zero|corrupted) page' THEN 'index page'
    WHEN p_detail ~ '^MultiXactId [0-9]+ ' THEN 'multixact'
    WHEN p_detail ~ '^could not read block' THEN 'short read'
    WHEN p_detail ~ '^could not open file' THEN 'missing file'
    WHEN p_detail ~ '^could not access status of transaction' THEN 'commit log'
    WHEN p_detail ~ '^(unexpected|missing) chunk number' THEN 'toast'
    WHEN p_detail ~ '^(found (xmin|xmax|multixact|update xid)|uncommitted xmin) ' THEN 'freeze'
    ELSE 'other' END
$$;

CREATE OR REPLACE VIEW pgvigil.corruption_events AS
SELECT e.instance_id, e.snapshot_at AS at, pgvigil.corruption_class(e.detail) AS class,
       split_part(e.detail, E'\n', 1) AS message,
       substring(e.detail FROM '"?((?:base|global|pg_tblspc)/[0-9/_a-zA-Z.]+)"?') AS relation_path,
       e.datname, e.usename, e.pid, e.statement, e.detail, e.source
  FROM pgvigil.log_events e
 WHERE e.kind = 'corruption';

-- the three settings per instance: data_checksums from the instance read; the two developer settings from the
-- server-level non-default settings (a session or role SET of them is not seen)
CREATE OR REPLACE VIEW pgvigil.corruption_settings AS
SELECT s.instance_id, s.platform, s.snapshot_at, s.data_checksums,
       coalesce((SELECT x->>'value' FROM jsonb_array_elements(coalesce(s.non_default_settings, '[]'::jsonb)) x
                  WHERE x->>'name' = 'ignore_checksum_failure' LIMIT 1), 'off') AS ignore_checksum_failure,
       coalesce((SELECT x->>'value' FROM jsonb_array_elements(coalesce(s.non_default_settings, '[]'::jsonb)) x
                  WHERE x->>'name' = 'zero_damaged_pages' LIMIT 1), 'off') AS zero_damaged_pages
  FROM pgvigil.instance_state s;

-- ---------------------------------------------------------------------------------------------------------
-- the corruption rules, in pgvigil.findings' columns: instance_id, severity, setting, value, is_set, suggested,
-- platforms, detail, source, at. The zero_damaged_pages row repeats the settings rule of pgvigil.findings for the
-- Corruption tab; the join's arm for this view leaves it out of pgvigil.findings.
-- ---------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.corruption_findings AS
-- checksums off: a damaged page is read as good data. Self-managed: a warning with the way to turn them on. A managed
-- platform (RDS, Azure, Cloud SQL) sets them when it creates the instance and offers no way to change them in place:
-- an info line. Aurora's storage checks its own pages, so it is left out.
SELECT c.instance_id, 'warning' AS severity, 'data_checksums' AS setting, c.data_checksums AS value, true AS is_set,
       'on' AS suggested, 'self-managed' AS platforms,
       'data checksums are off: a page damaged by the disk, the controller or the file system is read as good data and '
       || 'nothing in the log says so; turn them on with pg_checksums --enable on the stopped cluster (initdb -k for a new '
       || 'one; on by default from PostgreSQL 18)' AS detail,
       'pgvigil' AS source, c.snapshot_at AS at
  FROM pgvigil.corruption_settings c
 WHERE c.data_checksums = 'off' AND c.platform = 'onprem'
UNION ALL
SELECT c.instance_id, 'info', 'data_checksums', c.data_checksums, true, 'on', 'managed',
       'data checksums are off: a damaged page is read as good data; the platform sets them when it creates the instance '
       || 'and cannot turn them on in place - a new instance with them on (a dump and restore, or logical replication into it) '
       || 'is the way, where the platform offers it',
       'pgvigil', c.snapshot_at
  FROM pgvigil.corruption_settings c
 WHERE c.data_checksums = 'off' AND c.platform NOT IN ('onprem', 'aurora')
UNION ALL
SELECT c.instance_id, 'critical', 'ignore_checksum_failure', c.ignore_checksum_failure, true, 'off', 'all',
       'ignore_checksum_failure is on at the server: a page that fails its checksum is read anyway (a WARNING instead of '
       || 'an ERROR), so damaged data reaches queries, backups and replicas; it belongs in one session of a recovery, never in the configuration',
       'pgvigil', c.snapshot_at
  FROM pgvigil.corruption_settings c
 WHERE c.ignore_checksum_failure = 'on'
UNION ALL
SELECT c.instance_id, 'critical', 'zero_damaged_pages', c.zero_damaged_pages, true, 'off', 'all',
       'zero_damaged_pages is on at the server: a damaged page header is replaced by zeros and the rows on it are lost '
       || 'without an error; it belongs in one session of a recovery, never in the configuration',
       'pgvigil', c.snapshot_at
  FROM pgvigil.corruption_settings c
 WHERE c.zero_damaged_pages = 'on'
UNION ALL
-- a corruption message in the server log in the last 24 hours (one row per instance). Messages, not damaged reads:
-- one read can write two (the checksum line and the invalid page ERROR beside it).
SELECT e.instance_id, 'critical', 'corruption in the log',
       count(*) || ' message(s): ' || string_agg(DISTINCT pgvigil.corruption_class(e.detail), ', '), true,
       'read the Corruption tab: find the relation, run amcheck on it, restore or rebuild it from a good copy', 'all',
       'the server log reported damage in the last 24 hours, the newest: '
       || coalesce((array_agg(split_part(e.detail, E'\n', 1) ORDER BY e.snapshot_at DESC))[1],
                   '(the message is not stored: the instance''s query_text policy keeps no log detail)'),
       'pgvigil', max(e.snapshot_at)
  FROM pgvigil.log_events e
 WHERE e.kind = 'corruption' AND e.snapshot_at > now() - interval '24 hours'
 GROUP BY e.instance_id
UNION ALL
-- amcheck's newest complete or damage-finding run of a database and check found damage
SELECT a.instance_id, 'critical', 'amcheck ' || a.check_name, a.datname || ': ' || a.corrupt || ' of ' || a.checked || ' relation(s)', true,
       'rebuild the damaged index (REINDEX CONCURRENTLY) or restore the table from a good copy; check the storage', 'all',
       'amcheck ' || a.check_name || ' reported damage in ' || a.datname || ', the first: '
       || coalesce((a.problems->0->>'relation') || ': ' || (a.problems->0->>'message'), '?'),
       'pgvigil', a.snapshot_at
  FROM pgvigil.amcheck_state a
 WHERE a.corrupt > 0;

-- one row per active instance: the settings, the log's corruption events in 24 h and 7 days, amcheck's newest state
CREATE OR REPLACE VIEW pgvigil.corruption_summary AS
SELECT i.instance_id, i.name AS instance, i.platform, c.data_checksums, c.ignore_checksum_failure, c.zero_damaged_pages,
       (SELECT count(*) FROM pgvigil.log_events e WHERE e.instance_id = i.instance_id AND e.kind = 'corruption'
           AND e.snapshot_at > now() - interval '24 hours') AS events_24h,
       (SELECT count(*) FROM pgvigil.log_events e WHERE e.instance_id = i.instance_id AND e.kind = 'corruption'
           AND e.snapshot_at > now() - interval '7 days') AS events_7d,
       (SELECT max(e.snapshot_at) FROM pgvigil.log_events e WHERE e.instance_id = i.instance_id AND e.kind = 'corruption') AS last_event,
       (SELECT max(a.snapshot_at) FROM pgvigil.amcheck_latest a WHERE a.instance_id = i.instance_id AND a.status <> 'skipped') AS amcheck_last_run,
       (SELECT coalesce(sum(a.corrupt), 0) FROM pgvigil.amcheck_state a WHERE a.instance_id = i.instance_id) AS amcheck_corrupt,
       (SELECT coalesce(sum(a.checked), 0) FROM pgvigil.amcheck_latest a WHERE a.instance_id = i.instance_id) AS amcheck_checked,
       (SELECT count(*) FROM pgvigil.amcheck_latest a WHERE a.instance_id = i.instance_id AND a.status = 'skipped') AS amcheck_skipped,
       c.snapshot_at
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.corruption_settings c ON c.instance_id = i.instance_id
 WHERE i.is_active;
