-- 0253_kit_findings: KITWATCH K4.2 (the design's F15 / F16) - the collector's sp_WhoIsActive fallback seen; and K4.3 (F14) - the kits' versions per instance (mssql_kit_versions, import_mssql_kits, kit_versions_fleet).
--
-- mssql_requests runs sp_WhoIsActive and reads 14 of its columns by name; when the call fails the DMV read runs
-- instead: the read's summary row says source 'dmv', 'sp_WhoIsActive in <db> failed, the DMV read ran instead', and
-- the run is 'partial' with the note 'sp_WhoIsActive: <the server's error> (error <n>); the DMV read ran instead'
-- (internal/mssql/requests.go). Until now no finding, Summary count or report showed it, so a site that updated
-- sp_WhoIsActive to a shape pgvigil cannot read never saw it. This view raises:
--   * 'sp_WhoIsActive unusable' (warning): the instance's newest mssql_requests reads are a streak of at least 5 such
--     fallbacks in a row over at least 5 minutes, and the newest one's error is of a shape class - 207 (an invalid
--     column), 8144 / 8145 (too many or an unknown parameter), 213 (the column count), 2812 (no such procedure), or
--     50000 that speaks of the schema (@return_schema answered none);
--   * 'sp_WhoIsActive failing' (info): the same streak with another error (a deadlock victim 1205, a lock timeout 1222,
--     a killed session) - repeated, not a shape;
--   * nothing once a read is not the fallback (the streak is counted from the newest read back, so the next good read
--     clears it), nor for a shorter or briefer streak (a passing error opens and clears nothing).
-- The streak is counted on mssql_requests_summary (0064: one row per read, ok or not), never on collection_log, which
-- holds a run only when it is not ok (log_collection, 0001): a good read between two fallbacks is seen there. The
-- error comes from the newest read's collection_log row (the same snapshot_at: mssql.go logs the run at the start it
-- imported with). The value is the error's number; the detail the newest note (the column it could not find).
--
-- Its own view in the findings shape (F16): collector_findings (0121) is another owner's, edited in place before its
-- release, so a CREATE OR REPLACE of it here would freeze a copy. The findings union, the Summary's Collection Errors
-- and `pgvigil report` read this view through the WIRING lines of the KITWATCH DONE (0121's owner joins it).
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.kit_findings AS
WITH newest AS (
  -- per active SQL Server instance its newest read of the day, kept only when it is the fallback (the PK's index)
  SELECT i.instance_id, n.snapshot_at
    FROM pgvigil.instances i
    CROSS JOIN LATERAL (SELECT s.snapshot_at, s.source, s.source_note FROM pgvigil.mssql_requests_summary s
                         WHERE s.instance_id = i.instance_id ORDER BY s.snapshot_at DESC LIMIT 1) n
   WHERE i.is_active AND i.engine = 'sqlserver' AND n.snapshot_at > now() - interval '1 day'
     AND n.source = 'dmv' AND n.source_note LIKE 'sp_WhoIsActive in % failed, the DMV read ran instead'
), streak AS (
  -- the reads after the newest one that is not the fallback: all of them are fallbacks
  SELECT w.instance_id, w.snapshot_at AS newest, st.runs, st.since
    FROM newest w
    CROSS JOIN LATERAL (SELECT max(s.snapshot_at) AS at FROM pgvigil.mssql_requests_summary s
                         WHERE s.instance_id = w.instance_id AND s.snapshot_at > now() - interval '1 day'
                           AND NOT (s.source = 'dmv' AND coalesce(s.source_note, '') LIKE 'sp_WhoIsActive in % failed, the DMV read ran instead')) g
    CROSS JOIN LATERAL (SELECT count(*) AS runs, min(s.snapshot_at) AS since FROM pgvigil.mssql_requests_summary s
                         WHERE s.instance_id = w.instance_id AND s.snapshot_at > greatest(g.at, now() - interval '1 day')) st
), noted AS (
  SELECT s.*, (SELECT l.note FROM pgvigil.collection_log l
                WHERE l.snapshot_at = s.newest AND l.instance_id = s.instance_id AND l.collection = 'mssql_requests'
                  AND l.status = 'partial' AND l.note LIKE 'sp_WhoIsActive: %the DMV read ran instead'
                ORDER BY l.log_id DESC LIMIT 1) AS note
    FROM streak s
)
SELECT s.instance_id,
       CASE WHEN k.shape THEN 'warning' ELSE 'info' END::text AS severity,
       CASE WHEN k.shape THEN 'sp_WhoIsActive unusable' ELSE 'sp_WhoIsActive failing' END::text AS setting,
       coalesce(e.num::text, 'no number')::text AS value,
       true AS is_set,
       CASE WHEN k.shape
            THEN 'an sp_WhoIsActive whose shape pgvigil reads (the version the Community tools page names as checked), or pgvigil''s next release'
            ELSE 'the server''s error below; the DMV read covers the snapshots meanwhile' END::text AS suggested,
       'all'::text AS platforms,
       format('%s mssql_requests reads in a row fell back to the DMV read since %s UTC: %s', s.runs,
              to_char(s.since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), coalesce(s.note, 'the error was not recorded'))::text AS detail,
       'pgvigil collector'::text AS source, s.since AS at
  FROM noted s
  CROSS JOIN LATERAL (SELECT substring(s.note FROM '\(error ([0-9]+)\); the DMV read ran instead$')::int AS num) e
  CROSS JOIN LATERAL (SELECT coalesce(e.num IN (207, 8144, 8145, 213, 2812) OR (e.num = 50000 AND s.note ILIKE '%schema%'), false) AS shape) k
 WHERE s.runs >= 5 AND s.newest - s.since >= interval '5 minutes';

COMMENT ON VIEW pgvigil.kit_findings IS 'KITWATCH K4.2: sp_WhoIsActive unusable (a streak of the collector''s fallback with a shape-class error) or failing (another error), in the findings shape; joined into the findings union by its owner (WIRING).';

-- KITWATCH K4.3 (F14): the community procedures as installed per SQL Server instance, read daily from their
-- definitions by mssql_kits (internal/mssql/kits.go; nothing of the kits executed), kept as last read: each read
-- replaces the instance's rows. The Community tools page shows them beside the versions pgvigil was checked against
-- (internal/community/kits); kit_versions_fleet is the fleet's one line per procedure and version.
CREATE TABLE IF NOT EXISTS pgvigil.mssql_kit_versions (
  instance_id     int NOT NULL REFERENCES pgvigil.instances ON DELETE CASCADE,
  database_name   text NOT NULL,
  procedure_name  text NOT NULL,
  version         text NOT NULL DEFAULT '',
  version_date    text NOT NULL DEFAULT '',   -- yyyymmdd, '' when the definition said none
  modify_date     text NOT NULL DEFAULT '',
  readable        boolean NOT NULL,           -- false: the login has no VIEW DEFINITION on it
  read_at         timestamptz NOT NULL,
  PRIMARY KEY (instance_id, database_name, procedure_name)
);
COMMENT ON TABLE pgvigil.mssql_kit_versions IS 'KITWATCH K4.3: the community procedures installed on a SQL Server instance and their versions from their definitions, as last read (mssql_kits).';

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_kits(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_rows jsonb := CASE WHEN jsonb_typeof(p_payload) = 'array' THEN p_payload ELSE '[]'::jsonb END;
BEGIN
  IF (SELECT engine FROM pgvigil.instances WHERE instance_id = p_instance_id) IS DISTINCT FROM 'sqlserver' THEN
    RAISE EXCEPTION 'import_mssql_kits: instance % is not a SQL Server instance', p_instance_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_rows) r WHERE r->>'kind' = 'read') THEN
    RAISE EXCEPTION 'import_mssql_kits: the payload has no read row';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.mssql_kits'), p_instance_id);
  -- an older read arriving late changes nothing
  IF EXISTS (SELECT 1 FROM pgvigil.mssql_kit_versions WHERE instance_id = p_instance_id AND read_at > p_snapshot_at) THEN
    RETURN;
  END IF;
  DELETE FROM pgvigil.mssql_kit_versions WHERE instance_id = p_instance_id;
  INSERT INTO pgvigil.mssql_kit_versions (instance_id, database_name, procedure_name, version, version_date, modify_date, readable, read_at)
  SELECT DISTINCT ON (r->>'database_name', r->>'procedure_name')
         p_instance_id, r->>'database_name', r->>'procedure_name', coalesce(r->>'version', ''), coalesce(r->>'version_date', ''),
         coalesce(r->>'modify_date', ''), coalesce((r->>'readable')::boolean, false), p_snapshot_at
    FROM jsonb_array_elements(v_rows) r
   WHERE r->>'kind' = 'proc' AND coalesce(r->>'database_name', '') <> '' AND coalesce(r->>'procedure_name', '') <> '';
END $$;

-- the fleet: one line per procedure and version (an unreadable or unversioned definition is the version '')
CREATE OR REPLACE VIEW pgvigil.kit_versions_fleet AS
SELECT k.procedure_name, k.version, k.version_date, count(DISTINCT k.instance_id)::int AS instances,
       bool_or(NOT k.readable) AS some_not_readable, max(k.read_at) AS newest_read
  FROM pgvigil.mssql_kit_versions k
  JOIN pgvigil.instances i ON i.instance_id = k.instance_id AND i.is_active
 GROUP BY k.procedure_name, k.version, k.version_date;
