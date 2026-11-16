-- BLITZ-GAP's lines for the joined objects (the lead's 03:3x join-file rule; the lead 06:3x): 0322 creates BLITZ-GAP's own
-- object only; the next join re-creates each object below WHOLE with these lines in it. Not a migration: never applied by
-- `pgvigil migrate` (scripts/ is not embedded). scripts/blitzgap-join-draft.sql stands them in for the proofs.

-- 1. pgvigil.mssql_storage_findings (0145's view): one more arm, sp_Blitz 26 / 148 / 149 (0322's view)
--    UNION ALL SELECT instance_id, severity, check_name, object, at, detail FROM pgvigil.mssql_file_place_findings

-- 2. pgvigil.mssql_config_expect_keys() (0161's): one more row, sp_Blitz 55 (the lead 06:3x: 55 = (a))
--    ('database', 'owner', 'text', NULL, true, '[]'::jsonb, true, 'sp_Blitz', 'sp_Blitz 55', 'database owner')

-- 3. pgvigil.mssql_config_checks_of(int) (0160's):
--    a. the list rules' own-row part leaves the key out (55 has its own part): src's WHERE
--       ... OR (k.kind = 'database' AND k.key <> 'owner')
--    b. one more part, after the last: each user database's owner against the expected owner (sa unless a scope names
--       another; 'off' off; 'info' when it differs, so no finding row; 'not applicable' when the SID maps to no login) -
--       as in scripts/blitzgap-join-draft-config.sql's 'line 3b'
