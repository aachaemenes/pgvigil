-- 0262 SQL Server custom checks (ST6): a custom: check with engine: sqlserver (or a procedure:) runs on SQL Server
-- instances through the collection mssql_custom (internal/mssql/custom.go), into the SAME store as PostgreSQL's custom
-- checks (0060: custom_checks, custom_results, custom_status, custom_series, custom_report, custom_findings), which is
-- keyed by instance only: the Custom tab, the Custom report, the findings and the alerts serve both engines.
--
--   import_mssql_custom  the collection's import function (the frame names it import_<collection>): import_custom's
--                        payload and work, for a SQL Server instance only (apply_roles makes it SECURITY DEFINER and
--                        grants it to the collector, as every import_*)
--   custom_report()      gains the instance's engine (its last column; the page reads it by name)
--   custom_findings      the same columns; its words per engine: a failed SQL Server check names its batch's fence (the
--                        read login, a transaction rolled back), a check not run names its collection (mssql_custom)

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_custom(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = p_instance_id AND i.engine = 'sqlserver') THEN
    RAISE EXCEPTION 'import_mssql_custom: instance % is not a SQL Server instance', p_instance_id USING ERRCODE = '22023';
  END IF;
  PERFORM pgvigil.import_custom(p_instance_id, p_snapshot_at, p_payload);
END $$;

-- custom_report: 0060's, with the instance's engine as its last column (a new result column: drop and create)
DROP FUNCTION IF EXISTS pgvigil.custom_report();
CREATE FUNCTION pgvigil.custom_report()
RETURNS TABLE (instance_id int, instance text, platform text, check_name text, description text, rule text, compare text,
               warning float8, critical float8, every_secs int, targets text, last_run timestamptz, status text,
               value float8, row_count int, error text, note text, overdue boolean, engine text)
LANGUAGE sql STABLE AS $$
  SELECT s.instance_id, i.name, i.platform, s.check_name, s.description, s.rule, s.compare, s.warning, s.critical,
         s.every_secs, s.targets, s.last_run, s.status, s.value, s.row_count, s.error, s.note, s.overdue, i.engine
    FROM pgvigil.custom_status s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
   ORDER BY CASE WHEN s.status = 'critical' THEN 0 WHEN s.status = 'error' THEN 1 WHEN s.status = 'warning' THEN 2
                 WHEN s.overdue THEN 3 ELSE 4 END, s.check_name, i.name
$$;

-- custom_findings: 0060's three arms and columns as they were (every union over it in 0062-0190 reads it unchanged);
-- the words of the error and not-run arms per engine
CREATE OR REPLACE VIEW pgvigil.custom_findings AS
WITH s AS (
  -- one read of custom_status for the three arms; a check whose latest listing is older than two of its cadences (at
  -- least 5 minutes: the collection's own minute and its jitter) raises nothing: the custom: key removed, the
  -- collection disabled on the instance or failing to connect (the daily checks report the collection itself)
  SELECT s.*, i.engine FROM pgvigil.custom_status s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
   WHERE s.listed_at >= now() - make_interval(secs => greatest(2 * s.every_secs, 300))
)
SELECT s.instance_id, s.status AS severity, 'custom check ' || s.check_name AS setting,
       coalesce(pgvigil.custom_fmt(s.value), '') AS value, true AS is_set,
       format('%s %s', s.compare, pgvigil.custom_fmt(CASE s.status WHEN 'critical' THEN s.critical ELSE s.warning END)) AS suggested,
       'all'::text AS platforms,
       format('the custom check %s %s: %s %s %s (warning %s, critical %s)%s', s.check_name,
              CASE s.status WHEN 'critical' THEN 'crossed its critical threshold' ELSE 'crossed its warning threshold' END,
              CASE s.rule WHEN 'rows' THEN 'it returned ' || s.row_count || ' rows,' ELSE 'its value ' || pgvigil.custom_fmt(s.value) || ' is' END,
              s.compare, pgvigil.custom_fmt(CASE s.status WHEN 'critical' THEN s.critical ELSE s.warning END),
              coalesce(s.compare || ' ' || pgvigil.custom_fmt(s.warning), 'none'), coalesce(s.compare || ' ' || pgvigil.custom_fmt(s.critical), 'none'),
              coalesce('. ' || s.description, '')) AS detail,
       'pgvigil custom'::text AS source, s.last_run AS at
  FROM s
 WHERE s.status IN ('warning', 'critical')
UNION ALL
SELECT s.instance_id, 'warning', 'custom check ' || s.check_name, '(error)', true,
       CASE s.engine WHEN 'sqlserver' THEN 'a T-SQL batch or procedure that runs as the read login, in a transaction rolled back'
                     ELSE 'a statement that runs as the monitoring login, read only' END,
       'all', format('the custom check %s failed at its last run: %s', s.check_name, s.error), 'pgvigil custom', s.last_run
  FROM s
 WHERE s.status = 'error'
UNION ALL
SELECT s.instance_id, 'warning', 'custom check ' || s.check_name, '(not run)', true, format('a run every %s', make_interval(secs => s.every_secs)),
       'all', format('the custom check %s has not run in two of its cadences (every %s) while the collection visits the instance: %s', s.check_name,
                     make_interval(secs => s.every_secs),
                     coalesce('its last run was at ' || to_char(s.last_run AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC',
                              'it has never run since it was listed at ' || to_char(s.first_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC')
                     || CASE s.engine WHEN 'sqlserver'
                          THEN '. The SQL Server custom collection still visits the instance, but runs less often than the check''s cadence (schedules: mssql_custom) or its runs take longer than the cadence (many slow checks: each has 30 s).'
                          ELSE '. The custom collection still visits the instance, but runs less often than the check''s cadence (schedules: custom) or its runs take longer than the cadence (many slow checks).' END),
       'pgvigil custom', coalesce(s.last_run, s.first_seen)
  FROM s
 WHERE s.overdue;
