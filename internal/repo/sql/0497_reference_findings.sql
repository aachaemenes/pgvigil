-- 0497_reference_findings: an instance whose connection string reference resolved to nothing - an env: variable not
-- set, a file: not read, a dpapi: seal that does not open on this host (a host move) - as the instance's own critical
-- finding 'connection string unresolved', never 'server unreachable': the server was not asked, so the person fixes
-- the reference on that host. The collector records such a run as the collection's error with a note
-- 'reference: <ref> resolved to nothing: <why>' (Repo.LogReferenceFailure: the reference as written, never its value).
-- One finding per instance, however many of its collections met the reference: it stands while the instance's newest
-- run is such a refusal within the last 15 minutes and no run of the instance has succeeded since (a resolved
-- reference clears it at its first good run).
--
-- Above 0300, so this file makes only its own object (the view); its arm in pgvigil.findings - and so in alerting and
-- the Summary - is in the release's join lines for the next join, as 0192's was.
CREATE OR REPLACE VIEW pgvigil.reference_findings AS
SELECT d.instance_id,
       'critical'::text AS severity,
       'connection string unresolved'::text AS setting,
       split_part(substr(d.note, length('reference: ') + 1), ' resolved to nothing: ', 1) AS value,
       true AS is_set,
       'every connection string reference resolved on the collector''s host'::text AS suggested,
       'all'::text AS platforms,
       split_part(d.note, ' resolved to nothing: ', 2)
         || '. The server was not asked: fix the reference on this host - a dpapi: seal opens only where it was sealed.' AS detail,
       'pgvigil collector'::text AS source,
       d.snapshot_at AS at
  FROM (SELECT DISTINCT ON (c.instance_id) c.instance_id, c.snapshot_at, c.note
          FROM pgvigil.collection_dates c
         WHERE c.status = 'error' AND c.note LIKE 'reference: % resolved to nothing: %' AND c.snapshot_at > now() - interval '15 minutes'
         ORDER BY c.instance_id, c.snapshot_at DESC) d
 WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collection_dates ok
                    WHERE ok.instance_id = d.instance_id AND ok.status IN ('ok', 'partial') AND ok.snapshot_at > d.snapshot_at);
