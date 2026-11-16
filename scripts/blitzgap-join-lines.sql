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
--    b. two more parts, after the last: each database's owner against the expected owner (the original sa, sid 0x01
--       from 0159's logins - 'sa' while they are not read - unless a scope names another; master, model, msdb and tempdb
--       against the original sa always, a scope's owner never - sp_Blitz 8.35 L3831; 'off' in any case off, exclusions
--       leave any database out; 'info' when it differs, so no finding row; 'not applicable' when the SID maps to no login;
--       rdsadmin and gcloud_cloudsqladmin left out; no row at all on Azure SQL Managed Instance - sp_Blitz 8.35 L870), and
--       one 'not read' row while no database is read - as scripts/blitzgap-join-draft-config.sql's 'line 3b' (FOLD-55)
--    c. (web, with the join) web/src/mssql_config.ts's hint for the new text key says the default (the original sa), that
--       the system databases are always held to the original sa, and that 'off' turns it off (review-24 N4; FOLD-55).

-- 4. (docs, the join note as 72's) rel-b20's docs/sqlserver-checks.md 'sp_Blitz weekly' section says 'pgvigil has no rule for
--    19, 21, 26, 55, 72, 77, 148 and 149': once rel-blitzgap is joined, that sentence keeps 72 only, and the seven are named
--    where pgvigil judges them - 19 / 21 / 77 the Checks tab's database options, 55 the configuration checks' 'database
--    owner', 26 / 148 / 149 the Storage tab.
--    The docs of 26 / 148 / 149 and 55 (docs/sqlserver-storage.md, docs/sqlserver-checks.md) describe them as shown; they reach
--    the Storage tab and the configuration grid only with lines 1-3, so the docs and the lines join together (review-24 N5).
