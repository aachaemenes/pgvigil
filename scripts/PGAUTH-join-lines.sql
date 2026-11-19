-- PGAUTH-join-lines.sql - PGAUTH M1's arm of a joined view (the join-file rule): its migration 0467 is above 0300, so it
-- creates only its own objects (pgvigil.pg_signin, import_pg_signin, pgvigil.pg_signin_findings) and this file holds the
-- line the next join puts into the view it re-creates whole. Not a migration: nothing runs this file; the join copies
-- the arm in place.

-- 1. pgvigil.findings (0300's union, re-created whole by the next join): one arm beside RELNOTES-S3's L9 arm -
--    a password-shaped sign-in short of sslmode=verify-full, a warning on the instance (0467)
    UNION ALL
    -- PGAUTH M1 (0467): a directory password without a certificate check (pg_signin)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.pg_signin_findings

-- 2. pgvigil.collector_shared_cause (0300): NOT joined - how a server signs the login in is a configuration fact, never
--    a symptom a host or network cut explains (named here so the join leaves it out on purpose).
