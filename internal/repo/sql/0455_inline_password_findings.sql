-- 0455_inline_password_findings: L9 - an inline PostgreSQL password in pgvigil.yaml as a finding on the instance (the
-- lead's 17:32 (1) a; migration number the lead's 15:25).
--
-- A PostgreSQL instance whose dsn in pgvigil.yaml holds its password inline keeps loading: the collector warns at its
-- start, 'pgvigil check' lists it, and this file makes it a finding on the instance, so the instance's page, the
-- Findings page and the alert channels show it with the fix in words. The collector's start hands the repository the
-- names of those instances (config.InlinePasswordInstances; collect.NoteInlinePasswords through the heartbeat's own run
-- id) - never the connection string, never the password. Each start's list replaces its host's list, so a fixed
-- configuration clears the finding at the next start. A page instance (Admin > Instances) never has an inline form:
-- its credential is a file: or dpapi: reference.
--
-- Above 0300, so this file makes only its own objects (the join-file rule): the table, its import, and the finding's
-- own view in the findings shape; the arm that puts the view into pgvigil.findings is line 1 of
-- scripts/RELNOTES-S3-join-lines.sql.

CREATE TABLE IF NOT EXISTS pgvigil.collector_inline_password (
  host          text NOT NULL,                  -- the collector's host (collector_heartbeat.host): its list is the host's
  instance      text NOT NULL,                  -- the instance's name as pgvigil.yaml gives it
  collector_id  text NOT NULL,                  -- the run that wrote the row
  seen_at       timestamptz NOT NULL,
  PRIMARY KEY (host, instance)
);
COMMENT ON TABLE pgvigil.collector_inline_password IS 'L9: per collector host, the file instances whose dsn in pgvigil.yaml carries an inline PostgreSQL password, as its newest start listed them (import_collector_inline_passwords).';

-- import_collector_inline_passwords: run p_id's host lists p_instances (its whole list: a name left out is fixed);
-- an unknown run is refused in words.
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
   WHERE host = v_host AND NOT (instance = ANY (coalesce(p_instances, '{}'::text[])));
  INSERT INTO pgvigil.collector_inline_password (host, instance, collector_id, seen_at)
  SELECT DISTINCT v_host, n, p_id, now()
    FROM unnest(coalesce(p_instances, '{}'::text[])) n
   WHERE coalesce(n, '') <> ''
  ON CONFLICT (host, instance) DO UPDATE SET collector_id = EXCLUDED.collector_id, seen_at = EXCLUDED.seen_at;
END $$;

-- the finding, in the findings shape: one warning per active instance a live host lists - the host's newest run is
-- not retired and beat within a day (a host gone silent has its own finding; its list is not current)
CREATE OR REPLACE VIEW pgvigil.inline_password_findings AS
WITH hosts AS (
  SELECT DISTINCT ON (h.host) h.host, h.retired_at, h.beat_at
    FROM pgvigil.collector_heartbeat h
   ORDER BY h.host, h.started_at DESC
)
SELECT i.instance_id,
       'warning'::text AS severity,
       'inline password'::text AS setting,
       i.name AS value,
       true AS is_set,
       'the password in a passfile, env:NAME, file:/path or password_secret'::text AS suggested,
       'all'::text AS platforms,
       format('pgvigil.yaml on %s holds the read login''s password for %s inline in its dsn: move it to a passfile, env:NAME, file:/path or password_secret - ''pgvigil secret seal -name %s'' writes the file form (docs/check.md)',
              c.host, i.name, i.name)::text AS detail,
       'pgvigil collector'::text AS source,
       c.seen_at AS at
  FROM pgvigil.collector_inline_password c
  JOIN hosts h ON h.host = c.host AND h.retired_at IS NULL AND h.beat_at > now() - interval '1 day'
  JOIN pgvigil.instances i ON i.name = c.instance AND i.is_active AND i.engine = 'postgres';

COMMENT ON VIEW pgvigil.inline_password_findings IS 'L9: an inline PostgreSQL password in pgvigil.yaml as a warning on the instance, in the findings shape; joined into pgvigil.findings by RELNOTES-S3 join line 1.';
