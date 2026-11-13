-- Proof only (scripts/proof-darling-alerts.sh), never a migration: pgvigil.findings given the arm of
-- pgvigil.darling_alert_findings (migration 0118) the release's join writes in its own view (0190_join_release2.sql).
-- The view's definition as it stands wrapped with one more branch, so no body is copied; run once per database, after
-- the migrations (a second run finds the arm and does nothing). The old view's order is its subquery's: its readers sort.
DO $$
DECLARE d text := pg_get_viewdef('pgvigil.findings'::regclass, false);
BEGIN
  IF d NOT LIKE '%darling_alert_findings%' THEN
    EXECUTE 'CREATE OR REPLACE VIEW pgvigil.findings AS SELECT f.instance_id, f.severity, f.setting, f.value, f.is_set, f.suggested, f.platforms, f.detail, f.source, f.at FROM ('
      || rtrim(d, '; ' || chr(10)) || ') f UNION ALL SELECT a.instance_id, a.severity, a.setting, a.value, a.is_set, a.suggested, a.platforms, a.detail, a.source, a.at FROM pgvigil.darling_alert_findings a';
  END IF;
END $$;
