-- 0060_custom: custom checks (phase 3 wave F, task 61; DBADash's custom collections): the custom collection's import
-- (internal/collect/custom.go: the DBA's own SQL from the configuration's custom: list, run as the instance's
-- monitoring login in a read-only transaction rolled back, at each check's cadence) and its reads.
--
--   custom_checks       one row per instance and check: the definition as configured (the SQL, the cadence, the rule,
--                       the value column, the comparison and the thresholds, the instances and tags it names),
--                       first_seen, snapshot_at (the last run that listed it) and is_present (false once a run of the
--                       instance no longer lists it: the check was taken off the list or off this instance).
--   custom_results      every run of every check: its status (ok | warning | critical | error), its value (a value
--                       check's number, a rows check's row count), the row count, the columns, the rows (at most 100,
--                       kept under query_text full only), the error, the note and the duration; monthly partitions.
--   custom_status       a view: every present check of every instance with its latest result and overdue: its latest
--                       run (or its first listing) more than two of its cadences before the latest run that listed it.
--   import_custom(i, at, payload)
--   custom_series(i, f, t, step)   one point per check and step of the window: the value furthest past the check's
--                       thresholds in the step (the largest for > and >=, the smallest for < and <=, the last otherwise)
--                       and the worst status of the step: the Custom tab's chart.
--   custom_report()     every present check of every active instance with its latest result, the worst first: the
--                       Custom report at the root (DBADash's custom report shape).
--   custom_findings     the findings view's columns: a check whose latest run crossed its warning or critical
--                       threshold, a check whose latest run failed (its error), a check that has not run in two of
--                       its cadences while the collection still visits the instance (overdue). The UNION arm in
--                       pgvigil.findings and the purge lines (custom_results among the partition parents; custom_checks
--                       not listed within the window, present or not: a collection switched off lists nothing) are the
--                       wave's join.

CREATE TABLE IF NOT EXISTS pgvigil.custom_checks (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  check_name    text NOT NULL,
  description   text,
  sql           text NOT NULL,
  every_secs    int NOT NULL CHECK (every_secs > 0),
  rule          text NOT NULL CHECK (rule IN ('value', 'rows')),
  value_column  text,
  compare       text NOT NULL CHECK (compare IN ('>', '>=', '<', '<=', '=', '!=')),
  warning       float8,
  critical      float8,
  targets       text,
  first_seen    timestamptz NOT NULL,
  snapshot_at   timestamptz NOT NULL,
  is_present    boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, check_name)
);

CREATE TABLE IF NOT EXISTS pgvigil.custom_results (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  check_name    text NOT NULL,
  status        text NOT NULL CHECK (status IN ('ok', 'warning', 'critical', 'error')),
  value         float8,
  row_count     int,
  columns       jsonb,
  rows          jsonb,
  rows_kept     boolean NOT NULL DEFAULT false,
  error         text,
  note          text,
  duration_ms   int,
  PRIMARY KEY (instance_id, check_name, snapshot_at)
) PARTITION BY RANGE (snapshot_at);

-- custom_fmt: a value as the UI and the findings write it (at most four decimals, no trailing zeros)
CREATE OR REPLACE FUNCTION pgvigil.custom_fmt(p float8)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p IS NULL THEN NULL
              WHEN p = trunc(p) AND abs(p) < 1e15 THEN trunc(p)::numeric::text
              ELSE rtrim(rtrim(round(p::numeric, 4)::text, '0'), '.') END
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_custom(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state jsonb;
  v_names text[];
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_custom'), p_instance_id);
  SELECT r INTO v_state FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state' LIMIT 1;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'import_custom: the payload has no state row';
  END IF;
  SELECT coalesce(array_agg(x), '{}') INTO v_names FROM jsonb_array_elements_text(coalesce(v_state->'checks', '[]'::jsonb)) x;

  -- the definitions as configured; a run older than the stored row changes nothing (a one-off collect beside the daemon)
  INSERT INTO pgvigil.custom_checks AS c (instance_id, check_name, description, sql, every_secs, rule, value_column, compare,
                                          warning, critical, targets, first_seen, snapshot_at, is_present)
  SELECT DISTINCT ON (r->>'check_name')
         p_instance_id, r->>'check_name', r->>'description', r->>'sql', (r->>'every_secs')::int, r->>'rule', r->>'value_column',
         r->>'compare', (r->>'warning')::float8, (r->>'critical')::float8, r->>'targets', p_snapshot_at, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'check' AND r->>'check_name' IS NOT NULL AND r->>'check_name' = ANY (v_names)
   ORDER BY r->>'check_name'
  ON CONFLICT (instance_id, check_name) DO UPDATE SET
    description = EXCLUDED.description, sql = EXCLUDED.sql, every_secs = EXCLUDED.every_secs, rule = EXCLUDED.rule,
    value_column = EXCLUDED.value_column, compare = EXCLUDED.compare, warning = EXCLUDED.warning, critical = EXCLUDED.critical,
    targets = EXCLUDED.targets, snapshot_at = EXCLUDED.snapshot_at,
    -- a check back on the list after it was gone counts its cadences from now (not run in two cadences)
    first_seen = CASE WHEN c.is_present THEN c.first_seen ELSE EXCLUDED.first_seen END,
    is_present = true
  WHERE c.snapshot_at <= EXCLUDED.snapshot_at;

  UPDATE pgvigil.custom_checks c SET is_present = false, snapshot_at = p_snapshot_at
   WHERE c.instance_id = p_instance_id AND c.is_present AND c.snapshot_at <= p_snapshot_at
     AND NOT (c.check_name = ANY (v_names));

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'result') THEN
    PERFORM pgvigil.ensure_month_partition('custom_results', p_snapshot_at);
    INSERT INTO pgvigil.custom_results (instance_id, snapshot_at, check_name, status, value, row_count, columns, rows, rows_kept,
                                        error, note, duration_ms)
    SELECT p_instance_id, p_snapshot_at, r->>'check_name', r->>'status', (r->>'value')::float8, (r->>'row_count')::int,
           r->'columns', CASE WHEN coalesce((r->>'rows_kept')::boolean, false) THEN r->'rows' END,
           coalesce((r->>'rows_kept')::boolean, false), r->>'error', r->>'note', (r->>'duration_ms')::int
      FROM jsonb_array_elements(p_payload) r
     WHERE r->>'kind' = 'result' AND r->>'check_name' = ANY (v_names) AND r->>'status' IS NOT NULL
    ON CONFLICT DO NOTHING;
  END IF;
END $$;

-- custom_status: every present check with its latest result (NULL columns: never run)
CREATE OR REPLACE VIEW pgvigil.custom_status AS
SELECT c.instance_id, c.check_name, c.description, c.sql, c.every_secs, c.rule, c.value_column, c.compare, c.warning,
       c.critical, c.targets, c.first_seen, c.snapshot_at AS listed_at,
       l.snapshot_at AS last_run, l.status, l.value, l.row_count, l.columns, l.rows, l.rows_kept, l.error, l.note, l.duration_ms,
       -- not run in two cadences while the collection still visits the instance (listed_at moves at every visit): a
       -- collection switched off, disabled on the instance or failing to connect lists nothing, so its checks are not
       -- overdue here (the daily checks' "collection stale" and "collection failing" report the collection itself)
       coalesce(l.snapshot_at, c.first_seen) < c.snapshot_at - make_interval(secs => 2 * c.every_secs) AS overdue
  FROM pgvigil.custom_checks c
  LEFT JOIN LATERAL (
    SELECT r.* FROM pgvigil.custom_results r
     WHERE r.instance_id = c.instance_id AND r.check_name = c.check_name
     ORDER BY r.snapshot_at DESC LIMIT 1) l ON true
 WHERE c.is_present;

-- custom_series: the Custom tab's chart, one point per check and p_step seconds of the window
CREATE OR REPLACE FUNCTION pgvigil.custom_series(p_instance_id int, p_from timestamptz, p_to timestamptz, p_step int)
RETURNS TABLE (snapshot_at timestamptz, check_name text, value float8, status text, runs bigint)
LANGUAGE sql STABLE AS $$
  SELECT to_timestamp(floor(extract(epoch FROM r.snapshot_at) / greatest(p_step, 60)) * greatest(p_step, 60)) AS snapshot_at,
         r.check_name,
         CASE WHEN c.compare IN ('>', '>=') THEN max(r.value)
              WHEN c.compare IN ('<', '<=') THEN min(r.value)
              ELSE (array_agg(r.value ORDER BY r.snapshot_at DESC))[1] END,
         (array_agg(r.status ORDER BY CASE r.status WHEN 'critical' THEN 0 WHEN 'error' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END))[1],
         count(*)
    FROM pgvigil.custom_results r
    JOIN pgvigil.custom_checks c ON c.instance_id = r.instance_id AND c.check_name = r.check_name
   WHERE r.instance_id = p_instance_id AND r.snapshot_at > p_from AND r.snapshot_at <= p_to
   GROUP BY 1, 2, c.compare
   ORDER BY 1, 2
$$;

-- custom_report: the fleet's Custom report, the worst first (critical, error, warning, not run, ok)
CREATE OR REPLACE FUNCTION pgvigil.custom_report()
RETURNS TABLE (instance_id int, instance text, platform text, check_name text, description text, rule text, compare text,
               warning float8, critical float8, every_secs int, targets text, last_run timestamptz, status text,
               value float8, row_count int, error text, note text, overdue boolean)
LANGUAGE sql STABLE AS $$
  SELECT s.instance_id, i.name, i.platform, s.check_name, s.description, s.rule, s.compare, s.warning, s.critical,
         s.every_secs, s.targets, s.last_run, s.status, s.value, s.row_count, s.error, s.note, s.overdue
    FROM pgvigil.custom_status s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
   ORDER BY CASE WHEN s.status = 'critical' THEN 0 WHEN s.status = 'error' THEN 1 WHEN s.status = 'warning' THEN 2
                 WHEN s.overdue THEN 3 ELSE 4 END, s.check_name, i.name
$$;

-- custom_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms,
-- detail, source, at)
CREATE OR REPLACE VIEW pgvigil.custom_findings AS
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
  FROM pgvigil.custom_status s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
 WHERE s.status IN ('warning', 'critical')
UNION ALL
SELECT s.instance_id, 'warning', 'custom check ' || s.check_name, '(error)', true, 'a statement that runs as the monitoring login, read only',
       'all', format('the custom check %s failed at its last run: %s', s.check_name, s.error), 'pgvigil custom', s.last_run
  FROM pgvigil.custom_status s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
 WHERE s.status = 'error'
UNION ALL
SELECT s.instance_id, 'warning', 'custom check ' || s.check_name, '(not run)', true, format('a run every %s', make_interval(secs => s.every_secs)),
       'all', format('the custom check %s has not run in two of its cadences (every %s) while the collection visits the instance: %s', s.check_name,
                     make_interval(secs => s.every_secs),
                     coalesce('its last run was at ' || to_char(s.last_run AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC',
                              'it has never run since it was listed at ' || to_char(s.first_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC')
                     || '. The custom collection still visits the instance, but runs less often than the check''s cadence (schedules: custom) or its runs take longer than the cadence (many slow checks).'),
       'pgvigil custom', coalesce(s.last_run, s.first_seen)
  FROM pgvigil.custom_status s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
 WHERE s.overdue;
