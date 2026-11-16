-- 0322 BLITZ-GAP (the lead 05:2x / 06:3x): sp_Blitz 26, 148 and 149 judged by pgvigil itself over the storage
-- collection's file list (mssql_files.physical_name, 0067) - no new read. One object of its own:
--
--   mssql_file_place_findings  a user database file named on the C: drive (sp_Blitz 26, warning), a database file on a
--                              network share (148, info: a UNC path) or in Azure blob storage (149, info: an https URL);
--                              the columns of mssql_storage_findings, then the rule. None of the three on Azure SQL Managed
--                              Instance (instances.platform 'azuresqlmi', as 0129 and 0156 key it): its files are the
--                              service's, in blob storage by design (review-24 S2). SQL Server on Linux keeps a C:\ file
--                              name as given and maps C:\ to the / directory, so on Linux the name says C: while the
--                              place may be any mount: the words say both (review-24 S5).
--
-- Its arm in pgvigil.mssql_storage_findings (so the Storage tab and pgvigil.findings carry it) belongs to a joined
-- object: scripts/blitzgap-join-lines.sql (the lead's 03:3x rule), with sp_Blitz 55's key and arm in 0160's
-- configuration checks.

CREATE OR REPLACE VIEW pgvigil.mssql_file_place_findings AS
SELECT f.instance_id, x.severity, x.check_name, f.database_name || ': ' || coalesce(f.file_name, f.file_id::text) AS object,
       f.snapshot_at AS at, format(x.words, f.physical_name) AS detail, x.rule
  FROM pgvigil.mssql_files f
  JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.platform IS DISTINCT FROM 'azuresqlmi'
 CROSS JOIN LATERAL (VALUES
   ('warning'::text, 'a user database file on the C: drive'::text, 'sp_Blitz 26'::text,
    '%s: a user database file named on the C: drive - on Windows a full system drive stops Windows and SQL Server together (SQL Server on Linux maps C:\ to the / directory)'::text,
    f.database_id > 4 AND upper(left(f.physical_name, 3)) = 'C:\'),
   ('info', 'a database file on a network share', 'sp_Blitz 148',
    '%s: on a network share - every read and write crosses the network, and an outage of the share is the database''s',
    left(f.physical_name, 2) = '\\'),
   ('info', 'a database file in Azure blob storage', 'sp_Blitz 149',
    '%s: in Azure blob storage - its latency and throttling are the storage account''s',
    lower(left(f.physical_name, 8)) = 'https://')
 ) x (severity, check_name, rule, words, hit)
 WHERE x.hit AND f.is_present AND f.snapshot_at > now() - interval '3 hours';
