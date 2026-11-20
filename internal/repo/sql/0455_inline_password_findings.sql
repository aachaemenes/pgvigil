-- 0455_inline_password_findings: L9 - an inline PostgreSQL password in pgvigil.yaml as a finding on the instance (the
-- lead's 17:32 (1) a; migration number the lead's 15:25).
--
-- A PostgreSQL instance whose dsn in pgvigil.yaml holds its password inline keeps loading: the collector warns at its
-- start, 'pgvigil check' lists it, and this file makes it a finding on the instance, so the instance's page, the
-- Findings page and the alert channels show it with the fix in words. The collector's start hands the repository the
-- names of those instances (config.InlinePasswordInstances; collect.NoteInlinePasswords through the heartbeat's own run
-- id) - never the connection string, never the password. Each run keeps its own list (rn-l9 S1: a console run
-- started beside the service - 0121's named case - neither replaces nor hides the service's), and a run's next
-- start replaces its own, so a fixed configuration clears the finding at the next start; a run that stopped cleanly
-- or was retired lists nothing, and its rows go with its heartbeat row (N9). A page instance (Admin > Instances) never
-- has an inline form: its credential is a file: or dpapi: reference.
--
-- Above 0300, so this file makes only its own objects (the join-file rule): the table, its import, and the finding's
-- own view in the findings shape; the arm that puts the view into pgvigil.findings is line 1 of
-- scripts/RELNOTES-S3-join-lines.sql.

CREATE TABLE IF NOT EXISTS pgvigil.collector_inline_password (
  collector_id  text NOT NULL REFERENCES pgvigil.collector_heartbeat (collector_id) ON DELETE CASCADE, -- the run whose list it is
  instance      text NOT NULL,                  -- the instance's name as pgvigil.yaml gives it
  host          text NOT NULL,                  -- the run's host (collector_heartbeat.host), for the detail
  seen_at       timestamptz NOT NULL,
  PRIMARY KEY (collector_id, instance)
);
COMMENT ON TABLE pgvigil.collector_inline_password IS 'L9: per collector run, the file instances whose dsn in pgvigil.yaml carries an inline PostgreSQL password, as that run''s start listed them (import_collector_inline_passwords).';

-- import_collector_inline_passwords: run p_id lists p_instances (its whole list: a name left out is fixed); the
-- host's runs that are over (a clean stop, retired) leave their lists; an unknown run is refused in words. A late
-- write of an older run touches its own rows alone.
CREATE OR REPLACE FUNCTION pgvigil.import_collector_inline_passwords(p_id text, p_instances text[])
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_host text;
BEGIN
  SELECT host INTO v_host FROM pgvigil.collector_heartbeat WHERE collector_id = p_id;
  IF v_host IS NULL THEN
    RAISE EXCEPTION 'import_collector_inline_passwords: no collector run %', p_id;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.collector_inline_password'), hashtext(v_host));
  DELETE FROM pgvigil.collector_inline_password
   WHERE collector_id = p_id AND NOT (instance = ANY (coalesce(p_instances, '{}'::text[])));
  DELETE FROM pgvigil.collector_inline_password c
   USING pgvigil.collector_heartbeat h
   WHERE c.collector_id = h.collector_id AND h.host = v_host AND h.collector_id <> p_id
     AND (h.stopped_at IS NOT NULL OR h.retired_at IS NOT NULL);
  INSERT INTO pgvigil.collector_inline_password (collector_id, instance, host, seen_at)
  SELECT DISTINCT p_id, n, v_host, now()
    FROM unnest(coalesce(p_instances, '{}'::text[])) n
   WHERE coalesce(n, '') <> ''
  ON CONFLICT (collector_id, instance) DO UPDATE SET seen_at = EXCLUDED.seen_at;
END $$;

-- the finding, in the findings shape: one warning per active instance a LIVE run lists - not stopped, not retired,
-- and its own newest beat within a day (rn-l9 S1: never the host's newest start; a run gone silent has its own finding
-- and its list is not current). The words (rn-l9 B2): env: and file: hold the WHOLE connection string, never the
-- password alone - a bare password there would be read as a connection string and reach the logs in pgx's parse error.
CREATE OR REPLACE VIEW pgvigil.inline_password_findings AS
WITH live AS (
  SELECT c.host, c.instance, max(c.seen_at) AS seen_at
    FROM pgvigil.collector_inline_password c
    JOIN pgvigil.collector_heartbeat h ON h.collector_id = c.collector_id
   WHERE h.stopped_at IS NULL AND h.retired_at IS NULL AND h.beat_at > now() - interval '1 day'
   GROUP BY c.host, c.instance
)
SELECT i.instance_id,
       'warning'::text AS severity,
       'inline password'::text AS setting,
       i.name AS value,
       true AS is_set,
       'the whole connection string in env:NAME or file:/path (pgvigil secret seal), or the password alone in a passfile or password_secret'::text AS suggested,
       'all'::text AS platforms,
       format('pgvigil.yaml on %s holds the read login''s password for %s inline in its dsn: move the whole connection string to env:NAME or file:/path - ''pgvigil secret seal -name "%s"'' seals it (a dpapi: reference on Windows, a file elsewhere) - or the password alone to a passfile or password_secret (docs/check.md)',
              c.host, i.name, replace(i.name, '"', '\"'))::text AS detail,
       'pgvigil collector'::text AS source,
       c.seen_at AS at
  FROM live c
  JOIN pgvigil.instances i ON i.name = c.instance AND i.is_active AND i.engine = 'postgres';

COMMENT ON VIEW pgvigil.inline_password_findings IS 'L9: an inline PostgreSQL password in pgvigil.yaml as a warning on the instance, in the findings shape; joined into pgvigil.findings by RELNOTES-S3 join line 1.';
