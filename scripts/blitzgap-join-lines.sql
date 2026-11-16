-- BLITZ-GAP's lines for the joined objects (the lead's 03:3x join-file rule; the lead 06:3x): 0322 creates BLITZ-GAP's own
-- object only; the next join re-creates each object below WHOLE with these lines in it. Not a migration: never applied by
-- `pgvigil migrate` (scripts/ is not embedded). scripts/blitzgap-join-draft.sql stands them in for the proofs.

-- 1. pgvigil.mssql_storage_findings (0145's view): one more arm, sp_Blitz 26 / 148 / 149 (0322's view)
--    UNION ALL SELECT instance_id, severity, check_name, object, at, detail FROM pgvigil.mssql_file_place_findings
