-- 0055_sessionsets: the settings the application's own sessions change (task 58): the session_sets collection's
-- import (internal/collect/sessionsets.go: pg_stat_statements' utility rows that begin SET, SET LOCAL or RESET, read
-- hourly) and its reads.
--
--   session_sets_state      one row per instance: the last read's status ('ok' | 'not available'), the reason, and
--                           pg_stat_statements.track_utility as read.
--   session_sets            one row per pg_stat_statements entry (instance, dbid, userid, queryid, toplevel): the
--                           role, the database, the command, the setting, its value (NULL when the text hides it, PG
--                           17+, or the query_text policy dropped it), whether it is a planner setting, the cumulative
--                           calls, first_seen, last_seen (the last read that listed it) and last_grew (the last read
--                           its calls rose in).
--   session_sets_sample     the calls each entry gained between two reads (a row only when it gained; after a reset,
--                           the calls since). An entry first seen counts its calls only when the instance had an
--                           earlier ok read (the entry is new since then); on the instance's first read nothing is
--                           counted (its pg_stat_statements may hold months of history). A read older than an entry's
--                           stored row adds nothing (a one-off collect beside the daemon).
--   import_session_sets(i, at, payload)
--   session_sets_window(i, f, t)   per entry: the calls gained in the window (NULL: none) beside its current row.
--   sessionsets_findings    the findings view's columns: a planner setting SET (not RESET) to a value that is not the
--                           server's (session_set_is_server_value) by a role's sessions whose calls rose in the last
--                           24 hours, on an instance whose last read is 'ok'. The UNION arm in pgvigil.findings and
--                           the purge lines are the wave's join.
--
-- The SETs pgvigil itself runs on the instance (its session setup, the index read's search_path, the Explain's
-- plan_cache_mode) are left out under the monitor's role by the collector; every other SET of that role is kept (a
-- login the application shares with the monitor).

CREATE TABLE IF NOT EXISTS pgvigil.session_sets_state (
  instance_id    int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at    timestamptz NOT NULL,
  status         text NOT NULL CHECK (status IN ('ok', 'not available')),
  reason         text,
  track_utility  text
);

CREATE TABLE IF NOT EXISTS pgvigil.session_sets (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  dbid          bigint NOT NULL,
  userid        bigint NOT NULL,
  queryid       bigint NOT NULL,
  toplevel      boolean NOT NULL,
  datname       text,
  rolname       text,
  command       text NOT NULL,             -- SET | SET LOCAL | RESET
  setting       text NOT NULL,
  value         text,
  value_hidden  boolean NOT NULL DEFAULT false,
  planner       boolean NOT NULL DEFAULT false,
  calls         bigint NOT NULL,
  first_seen    timestamptz NOT NULL,
  last_seen     timestamptz NOT NULL,
  last_grew     timestamptz,
  query         text,
  PRIMARY KEY (instance_id, dbid, userid, queryid, toplevel)
);

CREATE TABLE IF NOT EXISTS pgvigil.session_sets_sample (
  instance_id   int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  snapshot_at   timestamptz NOT NULL,
  dbid          bigint NOT NULL,
  userid        bigint NOT NULL,
  queryid       bigint NOT NULL,
  toplevel      boolean NOT NULL,
  calls         bigint NOT NULL,
  PRIMARY KEY (instance_id, snapshot_at, dbid, userid, queryid, toplevel)
);
CREATE INDEX IF NOT EXISTS session_sets_sample_at_idx ON pgvigil.session_sets_sample (snapshot_at);

CREATE OR REPLACE FUNCTION pgvigil.import_session_sets(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_state   jsonb;
  v_prev_ok boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_session_sets'), p_instance_id);
  SELECT EXISTS (SELECT 1 FROM pgvigil.session_sets_state s
                  WHERE s.instance_id = p_instance_id AND s.status = 'ok' AND s.snapshot_at < p_snapshot_at) INTO v_prev_ok;
  SELECT r INTO v_state FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'state' LIMIT 1;
  IF v_state IS NULL THEN
    RAISE EXCEPTION 'import_session_sets: the payload has no state row';
  END IF;
  INSERT INTO pgvigil.session_sets_state AS s (instance_id, snapshot_at, status, reason, track_utility)
  VALUES (p_instance_id, p_snapshot_at, v_state->>'status', v_state->>'reason', v_state->>'track_utility')
  ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, status = EXCLUDED.status,
    reason = EXCLUDED.reason, track_utility = EXCLUDED.track_utility
  WHERE s.snapshot_at <= EXCLUDED.snapshot_at;
  IF v_state->>'status' <> 'ok' THEN
    RETURN;   -- not read: the stored rows stay as they were (not read is not "gone")
  END IF;

  CREATE TEMP TABLE pgv_sets_in ON COMMIT DROP AS
  SELECT DISTINCT ON (dbid, userid, queryid, toplevel)
         (r->>'dbid')::bigint AS dbid, r->>'datname' AS datname, (r->>'userid')::bigint AS userid, r->>'rolname' AS rolname,
         (r->>'queryid')::bigint AS queryid, coalesce((r->>'toplevel')::boolean, true) AS toplevel,
         r->>'command' AS command, r->>'setting' AS setting, r->>'value' AS value,
         coalesce((r->>'value_hidden')::boolean, false) AS value_hidden, coalesce((r->>'planner')::boolean, false) AS planner,
         (r->>'calls')::bigint AS calls, r->>'query' AS query
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'set' AND r->>'dbid' IS NOT NULL AND r->>'userid' IS NOT NULL AND r->>'queryid' IS NOT NULL
     AND r->>'setting' IS NOT NULL AND r->>'command' IS NOT NULL AND r->>'calls' IS NOT NULL
   ORDER BY dbid, userid, queryid, toplevel, (r->>'calls')::bigint DESC;

  -- the calls gained since the last read: a fall (a reset) counts the calls since; a new entry counts its calls only
  -- after an earlier ok read of the instance; a read older than the stored row counts nothing
  INSERT INTO pgvigil.session_sets_sample (instance_id, snapshot_at, dbid, userid, queryid, toplevel, calls)
  SELECT p_instance_id, p_snapshot_at, i.dbid, i.userid, i.queryid, i.toplevel,
         CASE WHEN c.calls IS NULL OR i.calls < c.calls THEN i.calls ELSE i.calls - c.calls END
    FROM pgv_sets_in i
    LEFT JOIN pgvigil.session_sets c
      ON c.instance_id = p_instance_id AND c.dbid = i.dbid AND c.userid = i.userid AND c.queryid = i.queryid AND c.toplevel = i.toplevel
   WHERE i.calls > 0
     AND ((c.calls IS NULL AND v_prev_ok) OR (c.calls IS NOT NULL AND i.calls <> c.calls AND c.last_seen <= p_snapshot_at))
  ON CONFLICT DO NOTHING;

  INSERT INTO pgvigil.session_sets AS s (instance_id, dbid, userid, queryid, toplevel, datname, rolname, command, setting, value,
                                         value_hidden, planner, calls, first_seen, last_seen, last_grew, query)
  SELECT p_instance_id, i.dbid, i.userid, i.queryid, i.toplevel, i.datname, i.rolname, i.command, i.setting, i.value,
         i.value_hidden, i.planner, i.calls, p_snapshot_at, p_snapshot_at, CASE WHEN i.calls > 0 AND v_prev_ok THEN p_snapshot_at END, i.query
    FROM pgv_sets_in i
  ON CONFLICT (instance_id, dbid, userid, queryid, toplevel) DO UPDATE SET
    datname = coalesce(EXCLUDED.datname, s.datname), rolname = coalesce(EXCLUDED.rolname, s.rolname),
    command = EXCLUDED.command, setting = EXCLUDED.setting, value = EXCLUDED.value, value_hidden = EXCLUDED.value_hidden,
    planner = EXCLUDED.planner, query = EXCLUDED.query,
    last_grew = CASE WHEN EXCLUDED.calls <> s.calls AND EXCLUDED.calls > 0 THEN EXCLUDED.last_seen ELSE s.last_grew END,
    calls = EXCLUDED.calls, last_seen = EXCLUDED.last_seen
  WHERE s.last_seen <= EXCLUDED.last_seen;
END $$;

-- server_setting_value: the server's value of a setting as the repository knows it: the instance's non-default
-- settings (the instance collection, server-level sources), else the built-in default this rule knows (the boolean
-- planner settings: enable_partitionwise_join and enable_partitionwise_aggregate off, every other enable_*, jit and
-- geqo on; pg_settings.boot_val on 11 through 18); NULL = unknown (a numeric setting at its default, a role's ALTER
-- ROLE SET, which the instance collection does not read)
CREATE OR REPLACE FUNCTION pgvigil.server_setting_value(p_instance_id int, p_name text)
RETURNS text LANGUAGE sql STABLE AS $$
  SELECT coalesce(
    (SELECT x->>'value' FROM pgvigil.instance_state s, jsonb_array_elements(coalesce(s.non_default_settings, '[]'::jsonb)) x
      WHERE s.instance_id = p_instance_id AND x->>'name' = p_name LIMIT 1),
    CASE WHEN p_name IN ('enable_partitionwise_join', 'enable_partitionwise_aggregate') THEN 'off'
         WHEN p_name LIKE 'enable\_%' OR p_name IN ('jit', 'geqo') THEN 'on' END)
$$;

-- session_set_is_server_value: true when a session's value is the server's own (a boolean by its meaning: on, true,
-- yes and 1 are one value, off, false, no and 0 the other; anything else as text, case and surrounding space aside,
-- so '64MB' and '65536' are not the same to this read); false when they differ or either is unknown (a hidden value,
-- PostgreSQL 17+). A SET back to the server's value changes no plan: it fires nothing (the join review's point).
CREATE OR REPLACE FUNCTION pgvigil.session_set_is_server_value(p_instance_id int, p_name text, p_value text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  WITH v AS (SELECT lower(trim(p_value)) AS a, lower(trim(pgvigil.server_setting_value(p_instance_id, p_name))) AS b)
  SELECT CASE
    WHEN a IS NULL OR b IS NULL THEN false
    WHEN a IN ('on', 'off', 'true', 'false', 'yes', 'no', '1', '0') AND b IN ('on', 'off', 'true', 'false', 'yes', 'no', '1', '0')
      THEN (a IN ('on', 'true', 'yes', '1')) = (b IN ('on', 'true', 'yes', '1'))
    ELSE a = b END
    FROM v
$$;

-- every entry of the instance, with the calls it gained in the window (NULL: none), the planner ones first; fires =
-- a planner setting SET (not RESET) to a value that is not the server's, by sessions that ran it in the window
CREATE OR REPLACE FUNCTION pgvigil.session_sets_window(p_instance_id int, p_from timestamptz, p_to timestamptz)
RETURNS TABLE (rolname text, datname text, command text, setting text, value text, value_hidden boolean, planner boolean,
               calls_in_window bigint, calls bigint, first_seen timestamptz, last_seen timestamptz, last_grew timestamptz,
               queryid bigint, query text, fires boolean)
LANGUAGE sql STABLE AS $$
  SELECT s.rolname, s.datname, s.command, s.setting, s.value, s.value_hidden, s.planner,
         g.calls, s.calls, s.first_seen, s.last_seen, s.last_grew, s.queryid, s.query,
         s.planner AND s.command <> 'RESET' AND coalesce(g.calls, 0) > 0
           AND NOT pgvigil.session_set_is_server_value(s.instance_id, s.setting, s.value)
    FROM pgvigil.session_sets s
    LEFT JOIN LATERAL (
      SELECT sum(x.calls)::bigint AS calls FROM pgvigil.session_sets_sample x
       WHERE x.instance_id = s.instance_id AND x.dbid = s.dbid AND x.userid = s.userid AND x.queryid = s.queryid
         AND x.toplevel = s.toplevel AND x.snapshot_at > p_from AND x.snapshot_at <= p_to) g ON true
   WHERE s.instance_id = p_instance_id
   ORDER BY s.planner DESC, s.rolname, s.datname, s.setting, s.command
$$;

-- sessionsets_findings: the findings view's columns (instance_id, severity, setting, value, is_set, suggested, platforms,
-- detail, source, at); a SET to the server's own value fires nothing (session_set_is_server_value)
CREATE OR REPLACE VIEW pgvigil.sessionsets_findings AS
SELECT s.instance_id, 'warning'::text AS severity, s.setting,
       coalesce(s.value, CASE WHEN s.value_hidden THEN '(value hidden: PostgreSQL 17+ keeps $1)' ELSE '(value not kept)' END) AS value,
       true AS is_set, 'the server''s or the role''s setting, not the session''s' AS suggested, 'all'::text AS platforms,
       format('a planner setting changed by the application''s sessions: role %s in database %s ran %s %s times in the last 24 hours (%s since the statistics reset). A plan measured in another session (psql, pgAdmin, EXPLAIN) runs without it and cannot show the application''s plan: measure under the same SET, or find where the application sets it.',
              coalesce(s.rolname, s.userid::text), coalesce(s.datname, s.dbid::text), s.command || ' ' || s.setting,
              g.calls, s.calls) AS detail,
       'pgvigil session_sets'::text AS source, s.last_grew AS at
  FROM pgvigil.session_sets s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
  JOIN pgvigil.session_sets_state st ON st.instance_id = s.instance_id AND st.status = 'ok'
  CROSS JOIN LATERAL (
    SELECT sum(x.calls)::bigint AS calls FROM pgvigil.session_sets_sample x
     WHERE x.instance_id = s.instance_id AND x.dbid = s.dbid AND x.userid = s.userid AND x.queryid = s.queryid
       AND x.toplevel = s.toplevel AND x.snapshot_at > now() - interval '1 day') g
 WHERE s.planner AND s.command <> 'RESET' AND g.calls > 0
   AND NOT pgvigil.session_set_is_server_value(s.instance_id, s.setting, s.value);
