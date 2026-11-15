-- 0269 DBA Dash's custom check on SQL Server (ST6b; the number is the lead's to confirm): a custom: check with
-- rule: status (a procedure: such as dbo.DBADash_CustomCheck, or a sql: batch) returns rows that judge themselves -
-- Test, Context, Status (1 critical, 2 warning, 3 N/A, 4 OK) and Info - as DBA Dash's custom check does.
--
--   custom_checks.rule   takes 'status'
--   custom_status_rows   each status check's CURRENT rows on an instance (DBA Dash's dbo.CustomChecks: one row per Test
--                        and Context, the set replaced by each run; a failed run keeps the last set, as DBA Dash's);
--                        gone with its check (the purge of custom_checks, an instance's removal)
--   import_mssql_custom  0262's, and then each status check that ran replaces its set
--   custom_findings      the same columns; the threshold arm leaves status checks out, and a fourth arm raises one
--                        finding per current row at Status 1 (critical) or 2 (warning)
-- A run's custom_results row keeps its status (the worst row), its value (the rows at warning or critical: the chart)
-- and its row count: the history of a status check is its runs (DBA Dash's per-row history is not kept).

ALTER TABLE pgvigil.custom_checks DROP CONSTRAINT IF EXISTS custom_checks_rule_check;
ALTER TABLE pgvigil.custom_checks ADD CONSTRAINT custom_checks_rule_check CHECK (rule IN ('value', 'rows', 'status'));

CREATE TABLE IF NOT EXISTS pgvigil.custom_status_rows (
  instance_id   int NOT NULL,
  check_name    text NOT NULL,
  test          text NOT NULL,
  context       text NOT NULL,
  status        smallint NOT NULL CHECK (status BETWEEN 1 AND 4),
  info          text,
  snapshot_at   timestamptz NOT NULL,
  PRIMARY KEY (instance_id, check_name, test, context),
  FOREIGN KEY (instance_id, check_name) REFERENCES pgvigil.custom_checks (instance_id, check_name) ON DELETE CASCADE
);

CREATE OR REPLACE FUNCTION pgvigil.import_mssql_custom(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_ran text[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pgvigil.instances i WHERE i.instance_id = p_instance_id AND i.engine = 'sqlserver') THEN
    RAISE EXCEPTION 'import_mssql_custom: instance % is not a SQL Server instance', p_instance_id USING ERRCODE = '22023';
  END IF;
  PERFORM pgvigil.import_custom(p_instance_id, p_snapshot_at, p_payload);

  -- a check that is no longer a status check keeps no rows
  DELETE FROM pgvigil.custom_status_rows s
   USING pgvigil.custom_checks c
   WHERE s.instance_id = p_instance_id AND c.instance_id = s.instance_id AND c.check_name = s.check_name AND c.rule <> 'status';

  -- the status checks that ran now (their result is not an error), and whose stored set is not newer than this run
  SELECT coalesce(array_agg(DISTINCT r->>'check_name'), '{}') INTO v_ran
    FROM jsonb_array_elements(p_payload) r
    JOIN pgvigil.custom_checks c ON c.instance_id = p_instance_id AND c.check_name = r->>'check_name' AND c.rule = 'status'
   WHERE r->>'kind' = 'result' AND r->>'status' IS DISTINCT FROM 'error'
     AND NOT EXISTS (SELECT 1 FROM pgvigil.custom_status_rows x
                      WHERE x.instance_id = p_instance_id AND x.check_name = r->>'check_name' AND x.snapshot_at > p_snapshot_at);
  IF cardinality(v_ran) = 0 THEN
    RETURN;
  END IF;

  DELETE FROM pgvigil.custom_status_rows s
   WHERE s.instance_id = p_instance_id AND s.check_name = ANY (v_ran);

  INSERT INTO pgvigil.custom_status_rows (instance_id, check_name, test, context, status, info, snapshot_at)
  SELECT DISTINCT ON (r->>'check_name', r->>'test', r->>'context')
         p_instance_id, r->>'check_name', r->>'test', r->>'context', (r->>'status')::smallint, r->>'info', p_snapshot_at
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'status_row' AND r->>'check_name' = ANY (v_ran)
     AND r->>'test' IS NOT NULL AND r->>'context' IS NOT NULL AND (r->>'status')::smallint BETWEEN 1 AND 4
   ORDER BY r->>'check_name', r->>'test', r->>'context';
END $$;

-- custom_findings: 0262's three arms and columns (the threshold arm without status checks: their status is their
-- rows'), and one finding per current row of a status check at Status 1 or 2
CREATE OR REPLACE VIEW pgvigil.custom_findings AS
WITH s AS (
  -- one read of custom_status for the arms; a check whose latest listing is older than two of its cadences (at
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
 WHERE s.status IN ('warning', 'critical') AND s.rule <> 'status'
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
 WHERE s.overdue
UNION ALL
-- a status check's current rows at Status 1 or 2 (a failed run keeps the last set, as DBA Dash's: its error stands
-- beside them)
SELECT s.instance_id, CASE r.status WHEN 1 THEN 'critical' ELSE 'warning' END,
       'custom check ' || s.check_name || ': ' || r.test || ' (' || r.context || ')',
       coalesce(left(r.info, 200), CASE r.status WHEN 1 THEN 'Status 1' ELSE 'Status 2' END), true,
       'Status 4 (OK)', 'all',
       format('the custom check %s reports %s for the test %s in the context %s%s%s', s.check_name,
              CASE r.status WHEN 1 THEN 'Status 1 (critical)' ELSE 'Status 2 (warning)' END, r.test, r.context,
              coalesce(': ' || r.info, ''), coalesce('. ' || s.description, '')),
       'pgvigil custom', r.snapshot_at
  FROM s
  JOIN pgvigil.custom_status_rows r ON r.instance_id = s.instance_id AND r.check_name = s.check_name
 WHERE s.rule = 'status' AND r.status IN (1, 2);
