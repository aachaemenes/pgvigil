-- 0079_log_groups: the server log's events grouped by message, and the log's checkpoint lines (parity3 task 126;
-- pgBadger's Events, Checkpoints and Temp Files tabs).
--
--   1. log_events gains level (the entry's level as logged: LOG, WARNING, ERROR, FATAL, PANIC) and message (the shape
--      of its first message line, internal/logparse MessageShape: quoted names, literals, tuple ids, LSNs and numbers
--      as ..., so it carries no value of the message and is stored under every query-text policy). Both are NULL on
--      the rows read before 0079; the Logs page then takes the shape of the detail's first line where the detail is
--      the server's own message (log_message_shape below), the kind's own wording where it has one, and says so
--      otherwise. No backfill: an UPDATE of every stored event would rewrite every partition.
--   2. two new kinds: 'error' (a WARNING, ERROR, FATAL or PANIC entry no other rule takes; its detail can quote row
--      values, so the query-text policy governs it) and 'checkpoint' (log_checkpoints' 'checkpoint|restartpoint
--      starting|complete' lines; the IO page pairs a complete line with its start for the cause).
--   3. pgvigil.log_message_shape(text): MessageShape in SQL, for the rows read before 0079 (proof-log-groups.sh
--      checks the two agree on every message of its sandbox log).
--   4. import_logs (0013's) stores level and message, and fills them in on a re-read like the statement and detail.
--   5. log_events_at (instance_id, snapshot_at): the Logs pages, the groups and the import's duplicate check read an
--      instance's window; until now only the slow and corruption kinds had an index of their own.

-- 1.
ALTER TABLE pgvigil.log_events ADD COLUMN IF NOT EXISTS level text;
ALTER TABLE pgvigil.log_events ADD COLUMN IF NOT EXISTS message text;

-- 2. every kind of 0045's list plus the two of this file; NOT VALID then VALIDATE as 0045 does (the old list is a
-- subset, so the scan proves nothing new and runs under SHARE UPDATE EXCLUSIVE only)
ALTER TABLE pgvigil.log_events DROP CONSTRAINT IF EXISTS log_events_kind_check;
ALTER TABLE pgvigil.log_events ADD CONSTRAINT log_events_kind_check CHECK (kind IN ('slow', 'lock_wait', 'deadlock', 'auth_fail', 'autovacuum', 'plan', 'corruption',
  'connection_limit', 'connection_lost', 'timeout', 'canceled', 'autovacuum_cancel', 'vacuum_skipped', 'wraparound', 'checkpoint_frequent', 'crash', 'out_of_memory',
  'archive_failed', 'standby_conflict', 'serialization_failure', 'temp_file', 'error', 'checkpoint')) NOT VALID;
ALTER TABLE pgvigil.log_events VALIDATE CONSTRAINT log_events_kind_check;

-- 3. the same rules in the same order as logparse.MessageShape: "..." names, '...' literals, LSNs, tuple ids, block
-- ranges, numbers not inside a name; white space folded; cut at 300 characters
CREATE OR REPLACE FUNCTION pgvigil.log_message_shape(p_msg text)
RETURNS text LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT left(btrim(regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(
                 regexp_replace(
                   regexp_replace(
                     regexp_replace(p_msg, '"(?:[^"]|"")*"', '"..."', 'g'),
                   $re$'(?:[^']|'')*'$re$, $re$'...'$re$, 'g'),
                 '\m[0-9A-F]+/[0-9A-F]+\M', '.../...', 'g'),
               '\(\d+(?:,\d+)*\)', '(...)', 'g'),
             '(^|[^[:alnum:]_.$])\d+\.\.\d+(?![[:alnum:]_])', '\1...', 'g'),
           '(^|[^[:alnum:]_.$])\d+(?:\.\d+)?(?![[:alnum:]_])', '\1...', 'g'),
         '\s+', ' ', 'g')), 300)
$$;

-- 4. 0013's import with the two new columns
CREATE OR REPLACE FUNCTION pgvigil.import_logs(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  m timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_logs'), p_instance_id);
  FOR m IN SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
             FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'event'
  LOOP
    PERFORM pgvigil.ensure_month_partition('log_events', m);
  END LOOP;

  CREATE TEMP TABLE pgv_log_in ON COMMIT DROP AS
  SELECT DISTINCT ON (r->>'at', r->>'event_key')
         (r->>'at')::timestamptz AS at, r->>'kind_of' AS kind, (r->>'pid')::int AS pid, r->>'client' AS client,
         r->>'usename' AS usename, r->>'datname' AS datname, (r->>'duration_ms')::float8 AS duration_ms,
         r->>'statement' AS statement, r->>'detail' AS detail, r->>'source' AS source, r->>'event_key' AS event_key,
         r->>'level' AS level, r->>'message' AS message
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'event'
   ORDER BY r->>'at', r->>'event_key', length(coalesce(r->>'statement', '') || coalesce(r->>'detail', '')) DESC;

  UPDATE pgvigil.log_events e
     SET statement = CASE WHEN length(coalesce(i.statement, '')) > length(coalesce(e.statement, '')) THEN i.statement ELSE e.statement END,
         detail    = CASE WHEN length(coalesce(i.detail, ''))    > length(coalesce(e.detail, ''))    THEN i.detail    ELSE e.detail END,
         level     = coalesce(e.level, i.level),
         message   = coalesce(e.message, i.message)
    FROM pgv_log_in i
   WHERE e.instance_id = p_instance_id AND e.snapshot_at = i.at AND e.event_key = i.event_key
     AND (length(coalesce(i.statement, '')) > length(coalesce(e.statement, ''))
       OR length(coalesce(i.detail, ''))    > length(coalesce(e.detail, ''))
       OR (e.level IS NULL AND i.level IS NOT NULL)
       OR (e.message IS NULL AND i.message IS NOT NULL));

  INSERT INTO pgvigil.log_events (instance_id, snapshot_at, kind, pid, client, usename, datname, duration_ms, statement, detail, source, event_key, level, message)
  SELECT p_instance_id, i.at, i.kind, i.pid, i.client, i.usename, i.datname, i.duration_ms, i.statement, i.detail, i.source, i.event_key, i.level, i.message
    FROM pgv_log_in i
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.log_events e
                      WHERE e.instance_id = p_instance_id AND e.snapshot_at = i.at AND e.event_key = i.event_key);
  DROP TABLE pgv_log_in;

  INSERT INTO pgvigil.log_cursor AS c (instance_id, source, read_to)
  SELECT p_instance_id, r->>'source', (r->>'read_to')::timestamptz
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cursor'
  ON CONFLICT (instance_id, source) DO UPDATE SET read_to = greatest(c.read_to, EXCLUDED.read_to), updated_at = now();
END $$;

-- 5.
CREATE INDEX IF NOT EXISTS log_events_at ON pgvigil.log_events (instance_id, snapshot_at);

SELECT pgvigil.apply_roles();
