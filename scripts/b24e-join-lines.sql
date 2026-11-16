-- b24e-join-lines.sql - B24e's arms of the joined views (the join-file rule): its migration
-- 0192 is above 0190, so it creates only its own objects (pgvigil.secret_findings) and this file holds the line the next
-- join (0300_join_release3.sql) puts into the view it re-creates whole. Not a migration: nothing runs this file.

-- pgvigil.findings (0190's union; 0300 re-creates it whole): one arm after collector_findings' -
--   the login's password not readable from AWS Secrets Manager, or refused by the server (critical)
    UNION ALL
    -- B24e (0192): a password secret the collector could not read or the server refused
    SELECT instance_id, severity, check_name, object, true, 'the login''s password readable from AWS Secrets Manager by the collector host''s identity'::text,
           'all'::text, detail, 'pgvigil collector'::text, at
      FROM pgvigil.secret_findings
