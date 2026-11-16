-- 0256: the Parquet export's own record in the repository (`pgvigil export`, docs/parquet-export.md). The export
-- only reads the repository; this is the one thing it writes, through one door, so that a failing or a late export
-- is seen on the Collector page instead of in a bucket nobody looks at. Its own objects only.
--
--   export_runs          one row per window a run took: the window, the pass (1 | final), when, ok | failed, the
--                        tables / files / rows / bytes written, the error of a failed one. Kept 90 days (the door
--                        trims it; purge() has nothing to do here).
--   export_state         one row per configured export (its name): where it writes, its last run and its newest
--                        window. It is what 'configured' means: `pgvigil export -off` removes it, and an export that
--                        was turned off raises no 'behind' line.
--   pgvigil_exporter     a role for the export's login: IN ROLE pgvigil_reader plus the two functions below. A login
--                        IN ROLE pgvigil_reader alone still exports; it leaves no row here.
--   export_run_record    the door. SECURITY DEFINER, and it checks the session's own login: a member of
--                        pgvigil_exporter, else it raises (apply_roles grants every function outside its lists to
--                        pgvigil_reader, so the check is inside, as alert_contact_routes does it). It writes one
--                        export_runs row and keeps export_state; nothing else.
--   export_off           removes an export's export_state row and its runs (the same check).
--   export_service       the lines for the service's own row, while an export is configured: a window whose last
--                        attempt failed, or the newest window ended more than 3 hours ago.

CREATE TABLE IF NOT EXISTS pgvigil.export_runs (
  run_id       bigserial PRIMARY KEY,
  name         text NOT NULL,
  window_from  timestamptz NOT NULL,
  window_to    timestamptz NOT NULL,
  pass         text NOT NULL DEFAULT '1' CHECK (pass IN ('1', 'final')),
  started_at   timestamptz NOT NULL,
  finished_at  timestamptz NOT NULL DEFAULT now(),
  outcome      text NOT NULL CHECK (outcome IN ('ok', 'failed')),
  tables       int NOT NULL DEFAULT 0,
  files        int NOT NULL DEFAULT 0,
  rows         bigint NOT NULL DEFAULT 0,
  bytes        bigint NOT NULL DEFAULT 0,
  error        text,
  login        text NOT NULL
);
CREATE INDEX IF NOT EXISTS export_runs_started_idx ON pgvigil.export_runs (started_at);
COMMENT ON TABLE pgvigil.export_runs IS 'The Parquet export''s runs, one row per window, written through export_run_record; kept 90 days.';

CREATE TABLE IF NOT EXISTS pgvigil.export_state (
  name              text PRIMARY KEY,
  destination       text NOT NULL,
  configured_at     timestamptz NOT NULL DEFAULT now(),
  last_run_at       timestamptz NOT NULL,
  last_outcome      text NOT NULL CHECK (last_outcome IN ('ok', 'failed')),
  last_error        text,
  newest_window_to  timestamptz
);
COMMENT ON TABLE pgvigil.export_state IS 'One row per configured Parquet export: its last run and its newest window; pgvigil export -off removes it.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_exporter') THEN
    CREATE ROLE pgvigil_exporter NOLOGIN;
  END IF;
END $$;
GRANT pgvigil_reader TO pgvigil_exporter;

CREATE OR REPLACE FUNCTION pgvigil.export_run_record(
  p_name text, p_destination text, p_from timestamptz, p_to timestamptz, p_pass text, p_started timestamptz,
  p_outcome text, p_tables int, p_files int, p_rows bigint, p_bytes bigint, p_error text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog AS $$
DECLARE
  v_id bigint;
BEGIN
  IF NOT pg_has_role(session_user, 'pgvigil_exporter', 'MEMBER') THEN
    RAISE EXCEPTION 'export_run_record: % is not an export login (IN ROLE pgvigil_exporter)', session_user USING ERRCODE = '42501';
  END IF;
  -- a row is of an hour that has passed, started about now, of an export name the configuration allows
  IF p_name !~ '^[a-z]([a-z0-9_-]{0,29}[a-z0-9])?$' OR p_to IS NULL OR p_from IS NULL OR NOT isfinite(p_to) OR NOT isfinite(p_from)
     OR p_to > now() + interval '5 minutes' OR p_from >= p_to
     OR p_started IS NULL OR p_started > now() + interval '5 minutes' OR p_started < now() - interval '1 day' THEN
    RAISE EXCEPTION 'export_run_record: a row out of bounds (name %, window % .. %, started %)', p_name, p_from, p_to, p_started USING ERRCODE = '22023';
  END IF;
  INSERT INTO pgvigil.export_runs (name, window_from, window_to, pass, started_at, outcome, tables, files, rows, bytes, error, login)
  VALUES (p_name, p_from, p_to, p_pass, p_started, p_outcome, coalesce(p_tables, 0), coalesce(p_files, 0), coalesce(p_rows, 0),
          coalesce(p_bytes, 0), left(p_error, 2000), session_user)
  RETURNING run_id INTO v_id;
  INSERT INTO pgvigil.export_state AS s (name, destination, last_run_at, last_outcome, last_error, newest_window_to)
  VALUES (p_name, p_destination, now(), p_outcome, left(p_error, 2000), CASE WHEN p_outcome = 'ok' THEN p_to END)
  ON CONFLICT (name) DO UPDATE
    SET destination = EXCLUDED.destination, last_run_at = EXCLUDED.last_run_at, last_outcome = EXCLUDED.last_outcome,
        last_error = EXCLUDED.last_error,
        newest_window_to = CASE WHEN EXCLUDED.newest_window_to IS NULL THEN s.newest_window_to
                                ELSE greatest(s.newest_window_to, EXCLUDED.newest_window_to) END;
  DELETE FROM pgvigil.export_runs WHERE started_at < now() - interval '90 days';
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.export_off(p_name text)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog AS $$
DECLARE
  v_n int;
BEGIN
  IF NOT pg_has_role(session_user, 'pgvigil_exporter', 'MEMBER') THEN
    RAISE EXCEPTION 'export_off: % is not an export login (IN ROLE pgvigil_exporter)', session_user USING ERRCODE = '42501';
  END IF;
  DELETE FROM pgvigil.export_state WHERE name = p_name;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  DELETE FROM pgvigil.export_runs WHERE name = p_name; -- nothing would trim them once the export no longer runs
  RETURN v_n;
END $$;

REVOKE ALL ON FUNCTION pgvigil.export_run_record(text, text, timestamptz, timestamptz, text, timestamptz, text, int, int, bigint, bigint, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION pgvigil.export_off(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION pgvigil.export_run_record(text, text, timestamptz, timestamptz, text, timestamptz, text, int, int, bigint, bigint, text) TO pgvigil_exporter;
GRANT EXECUTE ON FUNCTION pgvigil.export_off(text) TO pgvigil_exporter;

-- the service's own lines, for a configured export: a window whose LAST attempt failed (another window's success
-- does not hide it; its own export, or its acceptance as a gap, clears it), or the export more than 3 hours behind
CREATE OR REPLACE VIEW pgvigil.export_service AS
WITH last AS (
  SELECT DISTINCT ON (r.name, r.window_from) r.name, r.window_from, r.outcome, r.error
    FROM pgvigil.export_runs r
   ORDER BY r.name, r.window_from, r.started_at DESC, r.run_id DESC),
bad AS (
  SELECT l.name, count(*) AS windows, min(l.window_from) AS oldest,
         (array_agg(l.error ORDER BY l.window_from))[1] AS error
    FROM last l WHERE l.outcome = 'failed' GROUP BY l.name)
SELECT s.name,
       CASE WHEN b.windows IS NOT NULL
            THEN 'Parquet export ' || s.name || ': ' || b.windows || ' window(s) failed at their last attempt, the oldest ' ||
                 to_char(b.oldest AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' || coalesce(': ' || b.error, '')
            ELSE 'Parquet export ' || s.name || ': ' ||
                 floor(extract(epoch FROM now() - coalesce(s.newest_window_to, s.configured_at)) / 3600)::int ||
                 ' hours behind (its newest window ended ' ||
                 coalesce(to_char(s.newest_window_to AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC', 'never') || ')'
       END AS detail,
       s.last_run_at, s.last_outcome, s.newest_window_to
  FROM pgvigil.export_state s
  LEFT JOIN bad b ON b.name = s.name
 WHERE b.windows IS NOT NULL
    OR coalesce(s.newest_window_to, s.configured_at) < now() - interval '3 hours';
