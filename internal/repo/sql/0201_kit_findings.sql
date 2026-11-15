-- 0201_kit_findings: KITWATCH K4.2 (the design's F15 / F16) - the collector's sp_WhoIsActive fallback seen.
--
-- mssql_requests runs sp_WhoIsActive and reads 14 of its columns by name; when the call fails the DMV read runs
-- instead and the run is 'partial' with the note 'sp_WhoIsActive: <the server's error> (error <n>); the DMV read ran
-- instead' (internal/mssql/requests.go). Until now no finding, Summary count or report showed it, so a site that
-- updated sp_WhoIsActive to a shape pgvigil cannot read never saw it. This view raises:
--   * 'sp_WhoIsActive unusable' (warning): the instance's newest mssql_requests runs are a streak of at least 5 such
--     partial runs over at least 5 minutes, and the newest one's error is of a shape class - 207 (an invalid column),
--     8144 / 8145 (too many or an unknown parameter), 213 (the column count), 2812 (no such procedure), or 50000 that
--     speaks of the schema (@return_schema answered none);
--   * 'sp_WhoIsActive failing' (info): the same streak with another error (a deadlock victim 1205, a lock timeout 1222,
--     a killed session) - repeated, not a shape;
--   * nothing once a run is not the fallback (the streak is counted from the newest run back), nor for a shorter or
--     briefer streak (a passing error opens and clears nothing).
-- The value is the error's number; the detail the newest note (the column it could not find).
--
-- Its own view in the findings shape (F16): collector_findings (0121) is another owner's, edited in place before its
-- release, so a CREATE OR REPLACE of it here would freeze a copy. The findings union, the Summary's Collection Errors
-- and `pgvigil report` read this view through the WIRING lines of the KITWATCH DONE (0121's owner joins it).
-- ---------------------------------------------------------------------------------------------------------------
CREATE OR REPLACE VIEW pgvigil.kit_findings AS
WITH r AS (
  SELECT l.instance_id, l.snapshot_at, l.note,
         (l.status = 'partial' AND l.note LIKE 'sp_WhoIsActive: %the DMV read ran instead') AS fallback,
         row_number() OVER (PARTITION BY l.instance_id ORDER BY l.snapshot_at DESC) AS rn
    FROM pgvigil.collection_log l
   WHERE l.collection = 'mssql_requests' AND l.snapshot_at > now() - interval '1 day'
), good AS (
  -- the newest run that is not the fallback: the streak is the runs after it
  SELECT instance_id, min(rn) AS rn FROM r WHERE NOT fallback GROUP BY instance_id
), streak AS (
  SELECT r.instance_id, count(*) AS runs, min(r.snapshot_at) AS since, max(r.snapshot_at) AS newest,
         (array_agg(r.note ORDER BY r.snapshot_at DESC))[1] AS note
    FROM r LEFT JOIN good g USING (instance_id)
   WHERE r.fallback AND r.rn < coalesce(g.rn, 2147483647)
   GROUP BY r.instance_id
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
       format('%s partial mssql_requests runs since %s UTC: %s', s.runs, to_char(s.since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'), s.note)::text AS detail,
       'pgvigil collector'::text AS source, s.since AS at
  FROM streak s
  CROSS JOIN LATERAL (SELECT substring(s.note FROM '\(error ([0-9]+)\); the DMV read ran instead$')::int AS num) e
  CROSS JOIN LATERAL (SELECT coalesce(e.num IN (207, 8144, 8145, 213, 2812) OR (e.num = 50000 AND s.note ILIKE '%schema%'), false) AS shape) k
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
 WHERE s.runs >= 5 AND s.newest - s.since >= interval '5 minutes';

COMMENT ON VIEW pgvigil.kit_findings IS 'KITWATCH K4.2: sp_WhoIsActive unusable (a streak of the collector''s fallback with a shape-class error) or failing (another error), in the findings shape; joined into the findings union by its owner (WIRING).';
