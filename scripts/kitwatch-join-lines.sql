-- kitwatch-join-lines.sql - KITWATCH's arms of the joined views (the lead's JOIN-FILE RULE, 2026-11-15 03:3x): its
-- migration 0253 is above 0190, so it creates only its own objects (pgvigil.kit_findings, mssql_kit_versions,
-- import_mssql_kits, kit_versions_fleet) and this file holds the lines the next join (0300_join_release3.sql) puts into
-- the views it re-creates whole. Not a migration: nothing runs this file; the join copies each arm in place.

-- pgvigil.findings (0190's union; 0300 re-creates it whole): one arm after collector_findings' -
--   K4.2: sp_WhoIsActive unusable (a streak of the collector's fallback with a shape-class error) / failing (another)
    UNION ALL
    -- KITWATCH (0253): the collector's sp_WhoIsActive call seen - unusable (warning) or failing (info)
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.kit_findings

-- The Summary's Collection Errors (internal/web/q_mssql_summary.go) and `pgvigil report` (report.go) count a partial
-- run's note: their owner's code change, not SQL (named in the KITWATCH DONE's WIRING).
