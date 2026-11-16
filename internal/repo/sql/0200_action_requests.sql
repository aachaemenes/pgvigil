-- 0200_action_requests: community tools and every action through a request / result queue in the repository (CQ).
--
-- serve writes a request; a collector that holds the instance (its own worker lease, renewed every 15 s on the
-- REPOSITORY's clock) claims it at once (NOTIFY pgvigil_request carries the id; a 5 s poll is the guarantee, since a
-- transaction-mode pooler drops LISTEN), runs it with the logins it already holds and writes the result; serve hears
-- NOTIFY pgvigil_result and the page shows it. The direct path (serve connects itself) is unchanged; serve's
-- actions.via selects the queue, and a collector takes requests only with cq.enabled in its pgvigil.yaml.
--
--   action_kinds      every kind the queue knows: engine, class (action / read / collect), lifetime, the urgent slot,
--                     the payload's fields and their types, the field a door names (a tool, a job). Seeded here; the
--                     worker registers a runner per kind, an unregistered kind answers 'not through the queue yet'.
--   action_requests   one row per ask and its end: who (ui_user is serve's word; asked_login is the repository login
--                     that inserted), the instance, the state, the holder and its lease, the times. The reader may read
--                     it (the Grafana login included): it holds no payload and no result.
--   ui_action_data    the payload and the result of a request. Owner only (ui_*: apply_roles revokes it from the
--                     reader); a result is read through ui_action_result(request, ui_user) by the asker alone (by
--                     every signed-in user under the opt-in '7d' keep); every string of it masked before it is stored.
--   cq_workers        each worker's lease: the instances it holds now and its last beat on the repository's now().
--   action_doors      per worker, instance, kind and name (a tool or a job; '' = the kind): open or shut and the
--                     collector's own words. A shut or missing door refuses at the insert and is skipped by the claim.
--   cq_tools          per worker and instance: the community tools present, their versions and parameter lists,
--                     published by the collector (never a request per page view).
--
-- Times: every time here is the repository's clock (now() / clock_timestamp()), never a host's. A request is never run
-- after its expires_at; a running request whose lease lapses is 'lost' and never run again (an action is not
-- idempotent). The audit rows of a run are written by the worker through the existing import_* functions in the same
-- transaction as import_action_finish.
--
-- Rights: import_* run as the owner (apply_roles: SECURITY DEFINER, EXECUTE to pgvigil_collector); import_action_request
-- and import_action_cancel are granted to pgvigil_requester too (a queue-mode serve's login holds reader + auth +
-- requester, never the collector); ui_action_result is the auth role's (apply_roles' ui_* rule). Read kinds' rows are
-- purged after 7 days (a purge() line of the release's join); action kinds are kept as actions_log is.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_requester') THEN
    CREATE ROLE pgvigil_requester NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA pgvigil TO pgvigil_requester;

-- ---- the kinds ---------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.action_kinds (
  kind           text PRIMARY KEY CHECK (kind ~ '^[a-z][a-z0-9_]{1,40}$'),
  engine         text NOT NULL CHECK (engine IN ('postgres', 'sqlserver', 'any')),
  class          text NOT NULL CHECK (class IN ('action', 'read', 'collect')),
  lifetime_s     int NOT NULL CHECK (lifetime_s BETWEEN 5 AND 900),  -- a read: its timeout_s (at most max_timeout_s) + this
  max_timeout_s  int CHECK (max_timeout_s BETWEEN 1 AND 300),       -- a read's own timeout cap; NULL for an action
  urgent         boolean NOT NULL DEFAULT false,                    -- the worker's reserved slot (kill, cancel, terminate, job stop)
  fields         jsonb NOT NULL,                                    -- {"name": "int|text|uuid|ts|hex|object|bool", "?opt": ...}; a text is at most 200,000 characters, a payload 256 KB (direct's gate)
  door_field     text,                                              -- the payload field a door names (a tool, a job), or NULL
  label          text NOT NULL
);
COMMENT ON TABLE pgvigil.action_kinds IS 'The kinds the request queue knows, seeded by 0200; the worker registers a runner per kind.';

INSERT INTO pgvigil.action_kinds (kind, engine, class, lifetime_s, max_timeout_s, urgent, fields, door_field, label) VALUES
  -- the fields are the direct handlers' own request bodies (internal/web, read at 56b7467), less what serve checks
  -- before the insert (the typed confirm, the session user): the worker hands them to the same runner
  ('pg_cancel',          'postgres',  'action',  30, NULL, true,  '{"pid": "int", "backend_start": "ts", "reason": "text"}', NULL, 'cancel a PostgreSQL query'),
  ('pg_terminate',       'postgres',  'action',  30, NULL, true,  '{"pid": "int", "backend_start": "ts", "reason": "text"}', NULL, 'terminate a PostgreSQL session'),
  ('pg_job_stop',        'postgres',  'action',  30, NULL, true,  '{"scheduler": "text", "job_id": "int", "job_name": "text", "?run_id": "int", "?job_pid": "int", "reason": "text"}', 'job_name', 'stop a PostgreSQL job'),
  ('pg_job_start',       'postgres',  'action',  30, NULL, false, '{"scheduler": "text", "job_id": "int", "job_name": "text", "reason": "text"}', 'job_name', 'start a PostgreSQL job'),
  ('mssql_preview',      'sqlserver', 'read',    30,   15, false, '{"action": "text", "?session_id": "int", "?job_id": "uuid", "?plan_handle": "hex"}', NULL, 'read a SQL Server action''s target'),
  ('mssql_kill',         'sqlserver', 'action',  30, NULL, true,  '{"session_id": "int", "login_time": "ts", "login": "text", "reason": "text"}', NULL, 'kill a SQL Server session'),
  ('mssql_job_start',    'sqlserver', 'action',  30, NULL, false, '{"job_id": "uuid", "job_name": "text", "reason": "text"}', 'job_name', 'start a SQL Server Agent job'),
  ('mssql_job_stop',     'sqlserver', 'action',  30, NULL, true,  '{"job_id": "uuid", "job_name": "text", "reason": "text"}', 'job_name', 'stop a SQL Server Agent job'),
  -- s3's task 406 (rel-sqltb-s3): its body is aligned at 406's join; no runner registers it before then
  ('mssql_plan_evict',   'sqlserver', 'action',  30, NULL, false, '{"plan_handle": "hex", "confirm": "text", "reason": "text"}', NULL, 'evict a SQL Server plan'),
  ('community_run',      'any',       'read',    30,   60, false, '{"tool": "text", "?database": "text", "?params": "object", "?timeout_secs": "int", "?query_name": "text", "?text": "text"}', 'tool', 'run a community tool'),
  ('community_help',     'any',       'read',    30,   30, false, '{"tool": "text", "?database": "text"}', 'tool', 'a community tool''s @help'),
  ('custom_report',      'any',       'read',    30,   60, false, '{"report_id": "int", "edited_at": "ts", "?from": "ts", "?to": "ts", "?params": "object"}', NULL, 'run a custom report'),
  ('explain',            'postgres',  'read',    30,   60, false, '{"statement": "text", "?datname": "text"}', NULL, 'EXPLAIN a statement'),
  ('explain_analyze',    'postgres',  'read',    30,  300, false, '{"statement": "text", "?datname": "text", "reason": "text", "?timeout_secs": "int"}', NULL, 'EXPLAIN ANALYZE a statement'),
  ('hypo_index',         'postgres',  'read',    30,   60, false, '{"plan_id": "int", "n": "int", "reason": "text", "?ddl": "text"}', NULL, 'plan a statement with a hypothetical index'),
  ('index_advisor',      'postgres',  'read',    30,   60, false, '{"database": "text"}', NULL, 'run the index advisor'),
  ('admin_test',         'any',       'read',    30,   10, false, '{}', NULL, 'test an instance''s connection'),
  ('collect_now',        'any',       'collect', 600, NULL, false, '{"collection": "text"}', NULL, 'collect now')
ON CONFLICT (kind) DO NOTHING;

-- ---- the requests --------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.action_requests (
  request_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind            text NOT NULL REFERENCES pgvigil.action_kinds (kind),
  class           text NOT NULL,
  instance        text NOT NULL,
  ui_user         text NOT NULL,
  client          text,
  asked_login     text NOT NULL,
  asked_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
  expires_at      timestamptz NOT NULL,
  state           text NOT NULL CHECK (state IN ('waiting', 'running', 'done', 'failed', 'refused', 'expired', 'lost', 'cancelled')),
  taken_by        text,
  taken_host      text,
  taken_at        timestamptz,
  lease_until     timestamptz,
  cancel_asked_at timestamptz,
  done_at         timestamptz,
  outcome         text,
  refusal         text,
  rows_out        int,
  result_bytes    int,
  duration_ms     int,
  keep_until      timestamptz,
  keep            text NOT NULL DEFAULT 'read' CHECK (keep IN ('read', '7d')),  -- the collector's cq.result_keep at the end (task 488)
  read_at         timestamptz,
  cleared_at      timestamptz
);
CREATE INDEX IF NOT EXISTS action_requests_open_idx ON pgvigil.action_requests (state, asked_at) WHERE state IN ('waiting', 'running');
CREATE INDEX IF NOT EXISTS action_requests_instance_idx ON pgvigil.action_requests (instance, asked_at DESC);
CREATE INDEX IF NOT EXISTS action_requests_user_idx ON pgvigil.action_requests (ui_user, asked_at DESC);
CREATE INDEX IF NOT EXISTS action_requests_kept_idx ON pgvigil.action_requests (keep_until) WHERE cleared_at IS NULL AND keep_until IS NOT NULL;
COMMENT ON TABLE pgvigil.action_requests IS 'Every request of the queue and its end; written through import_action_* only; no payload, no result (ui_action_data holds them).';

CREATE TABLE IF NOT EXISTS pgvigil.ui_action_data (
  request_id  bigint PRIMARY KEY REFERENCES pgvigil.action_requests (request_id) ON DELETE CASCADE,
  payload     jsonb NOT NULL CHECK (octet_length(payload::text) <= 262144),
  result      jsonb CHECK (octet_length(result::text) <= 8388608)
);
COMMENT ON TABLE pgvigil.ui_action_data IS 'The payload and result of each request; owner only, read by its asker through ui_action_result.';

CREATE TABLE IF NOT EXISTS pgvigil.cq_workers (
  collector_id  text PRIMARY KEY,
  host          text NOT NULL,
  instances     text[] NOT NULL DEFAULT '{}',
  started_at    timestamptz NOT NULL,
  beat_at       timestamptz,               -- NULL after a clean stop
  stopped_at    timestamptz
);
COMMENT ON TABLE pgvigil.cq_workers IS 'Each request worker''s lease on the repository clock: renewed every 15 s, live while beat_at is under 45 s old.';

CREATE TABLE IF NOT EXISTS pgvigil.action_doors (
  collector_id  text NOT NULL REFERENCES pgvigil.cq_workers (collector_id) ON DELETE CASCADE,
  instance      text NOT NULL,
  kind          text NOT NULL REFERENCES pgvigil.action_kinds (kind),
  name          text NOT NULL DEFAULT '',  -- '' = the kind; else a tool or a job (ST4's allow-lists)
  open          boolean NOT NULL,
  why           text,
  at            timestamptz NOT NULL,
  PRIMARY KEY (collector_id, instance, kind, name)
);
COMMENT ON TABLE pgvigil.action_doors IS 'Each worker''s doors per instance, kind and name, with the collector''s own words; replaced whole by import_cq_doors.';

CREATE TABLE IF NOT EXISTS pgvigil.cq_tools (
  collector_id  text NOT NULL REFERENCES pgvigil.cq_workers (collector_id) ON DELETE CASCADE,
  instance      text NOT NULL,
  tool          text NOT NULL,
  present       boolean NOT NULL,
  why           text,
  version       text,
  params        jsonb,
  database      text,                      -- the database the presence was checked in (SQL Server); NULL = the login's
  at            timestamptz NOT NULL,
  PRIMARY KEY (collector_id, instance, tool)
);
COMMENT ON TABLE pgvigil.cq_tools IS 'The community tools each worker found per instance (in one database: the column says which) and their parameter lists; replaced per instance by import_cq_tools.';

-- the live leases: a worker is live while its beat is under 45 s old (three renewals of 15 s); a running request's
-- lease_until is renewed with the beat and lapses 25 s after the last renewal, so with the 5 s sweep a run whose worker
-- died is 'lost' within 30 s of its last renewal (a healthy run is renewed every 15 s: 10 s to spare)
CREATE OR REPLACE FUNCTION pgvigil.cq_lease_secs() RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 45 $$;
CREATE OR REPLACE FUNCTION pgvigil.cq_run_lease_secs() RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 25 $$;

-- ---- notify --------------------------------------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pgvigil.action_requests_notify() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('pgvigil_request', NEW.request_id::text);
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS action_requests_asked ON pgvigil.action_requests;
CREATE TRIGGER action_requests_asked AFTER INSERT ON pgvigil.action_requests
  FOR EACH ROW WHEN (NEW.state = 'waiting') EXECUTE FUNCTION pgvigil.action_requests_notify();
DROP TRIGGER IF EXISTS action_requests_cancel ON pgvigil.action_requests;
CREATE TRIGGER action_requests_cancel AFTER UPDATE OF cancel_asked_at ON pgvigil.action_requests
  FOR EACH ROW WHEN (NEW.state = 'running' AND OLD.cancel_asked_at IS NULL AND NEW.cancel_asked_at IS NOT NULL)
  EXECUTE FUNCTION pgvigil.action_requests_notify();

-- ---- the payload check --------------------------------------------------------------------------------------------
-- action_payload_why: why a payload does not fit its kind's fields, or NULL. Every field named is required unless it
-- starts with '?'; no other key is allowed; each value has its type. A kind's own rules beyond the shape (a reason's
-- length, a plan handle's form) are checked here too, so a forged insert is refused before any worker sees it.
CREATE OR REPLACE FUNCTION pgvigil.action_payload_why(p_kind pgvigil.action_kinds, p_args jsonb)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  f     record;
  k     text;
  v     jsonb;
  want  text;
  need  boolean;
BEGIN
  IF p_args IS NULL OR jsonb_typeof(p_args) <> 'object' THEN
    RETURN 'the request carries no arguments object';
  END IF;
  -- ui_action_data's CHECK in words, before it can raise: 200,000 characters of a multibyte text pass the length rule
  IF octet_length(p_args::text) > 262144 THEN
    RETURN format('%s: the arguments are over 256 KB', p_kind.kind);
  END IF;
  FOR k IN SELECT jsonb_object_keys(p_args) LOOP
    IF NOT (p_kind.fields ? k OR p_kind.fields ? ('?' || k)) THEN
      RETURN format('%s takes no argument %s', p_kind.kind, k);
    END IF;
  END LOOP;
  FOR f IN SELECT key, value #>> '{}' AS t FROM jsonb_each(p_kind.fields) LOOP
    need := left(f.key, 1) <> '?';
    k := ltrim(f.key, '?');
    want := f.t;
    v := p_args -> k;
    IF v IS NULL OR v = 'null'::jsonb THEN
      IF need THEN
        RETURN format('%s needs %s', p_kind.kind, k);
      END IF;
      CONTINUE;
    END IF;
    IF want = 'int' AND NOT (jsonb_typeof(v) = 'number' AND (v #>> '{}') ~ '^-?[0-9]{1,18}$') THEN
      RETURN format('%s: %s is not a whole number', p_kind.kind, k);
    ELSIF want = 'bool' AND jsonb_typeof(v) <> 'boolean' THEN
      RETURN format('%s: %s is not true or false', p_kind.kind, k);
    ELSIF want = 'object' AND jsonb_typeof(v) <> 'object' THEN
      RETURN format('%s: %s is not an object', p_kind.kind, k);
    ELSIF want IN ('text', 'ts', 'uuid', 'hex') AND jsonb_typeof(v) <> 'string' THEN
      RETURN format('%s: %s is not a string', p_kind.kind, k);
    ELSIF want = 'text' AND length(v #>> '{}') > 200000 THEN
      RETURN format('%s: %s is over 200,000 characters', p_kind.kind, k);
    ELSIF want = 'ts' AND (v #>> '{}') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+(Z|[+-][0-9:]+)?$' THEN
      RETURN format('%s: %s is not a timestamp', p_kind.kind, k);
    ELSIF want = 'uuid' AND (v #>> '{}') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
      RETURN format('%s: %s is not a job id', p_kind.kind, k);
    ELSIF want = 'hex' AND (v #>> '{}') !~ '^0x([0-9A-Fa-f]{2})+$' THEN
      RETURN format('%s: %s is not a hex handle (0x and pairs of hex digits)', p_kind.kind, k);
    END IF;
  END LOOP;
  -- the kinds' own rules
  IF p_args ? 'reason' AND length(btrim(p_args ->> 'reason')) NOT BETWEEN 5 AND 500 THEN
    RETURN 'the reason is 5 to 500 characters';
  END IF;
  IF p_kind.kind = 'mssql_kill' AND (p_args ->> 'session_id')::bigint NOT BETWEEN 1 AND 32767 THEN
    RETURN 'the session id is 1 to 32767';
  END IF;
  IF p_kind.kind IN ('pg_cancel', 'pg_terminate') AND (p_args ->> 'pid')::bigint <= 0 THEN
    RETURN 'the pid is not a process id';
  END IF;
  IF p_args ? 'timeout_secs' AND ((p_args ->> 'timeout_secs')::bigint < 1 OR (p_args ->> 'timeout_secs')::bigint > coalesce(p_kind.max_timeout_s, 0)) THEN
    RETURN format('%s: timeout_secs is 1 to %s', p_kind.kind, coalesce(p_kind.max_timeout_s, 0));
  END IF;
  IF p_kind.kind IN ('pg_job_stop', 'pg_job_start') AND (p_args ->> 'scheduler') NOT IN ('pg_cron', 'pgagent') THEN
    RETURN 'the scheduler is pg_cron or pgagent';
  END IF;
  IF p_kind.kind = 'mssql_preview' AND (p_args ->> 'action') NOT IN ('kill', 'job_start', 'job_stop', 'plan_evict') THEN
    RETURN 'a preview is of kill, job_start, job_stop or plan_evict';
  END IF;
  IF p_kind.kind = 'collect_now' AND (p_args ->> 'collection') !~ '^(\*|[a-z][a-z0-9_]{0,63})$' THEN
    RETURN 'collect_now names one collection or *';
  END IF;
  RETURN NULL;
END $$;

-- ---- the ask ---------------------------------------------------------------------------------------------------------
-- import_action_request: one request {kind, instance, ui_user, client, args}; refused (and recorded, state 'refused',
-- no notify) when the kind is unknown, the arguments do not fit it, no live worker holds the instance, the worker's door
-- is shut (its own words), the asker or the login already has 10 open requests, or the same collection was asked in
-- the last 30 s. Returns {outcome: 'waiting' | 'refused', detail, request_id, expires_at}.
CREATE OR REPLACE FUNCTION pgvigil.import_action_request(p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_now    timestamptz := clock_timestamp();
  v_kind   pgvigil.action_kinds;
  v_name   text := nullif(btrim(coalesce(p_payload ->> 'kind', '')), '');
  v_inst   text := nullif(btrim(coalesce(p_payload ->> 'instance', '')), '');
  v_user   text := lower(nullif(btrim(coalesce(p_payload ->> 'ui_user', '')), ''));
  v_client text := left(nullif(p_payload ->> 'client', ''), 100);
  v_args   jsonb := coalesce(p_payload -> 'args', '{}'::jsonb);
  v_login  text := session_user;
  v_why    text;
  v_live   int;
  v_last   record;
  v_door   record;
  v_dname  text;
  v_life   int;
  v_exp    timestamptz;
  v_id     bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_action_request: no ui_user' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_kind FROM pgvigil.action_kinds k WHERE k.kind = v_name;
  IF v_kind.kind IS NULL THEN
    -- an unknown kind is refused without a row: there is no kind to record it under
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('the queue knows no kind %s', left(coalesce(v_name, ''), 60)));
  END IF;
  -- the two caps' counts are serialized per user AND per login (two users of one serve share its login); always in this
  -- order, so two asks never wait on each other in a cycle
  PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.action_requests:' || v_user, 0));
  PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.action_requests.login:' || v_login, 0));
  IF v_inst IS NULL OR length(v_inst) > 200 THEN
    v_why := 'no instance named';
  ELSE
    v_why := pgvigil.action_payload_why(v_kind, v_args);
  END IF;
  IF v_why IS NULL THEN
    SELECT count(*) INTO v_live FROM pgvigil.cq_workers w
     WHERE w.beat_at > v_now - make_interval(secs => pgvigil.cq_lease_secs());
    IF v_live = 0 THEN
      v_why := 'no collector takes requests (cq.enabled in that collector''s pgvigil.yaml)';
    ELSIF NOT EXISTS (SELECT 1 FROM pgvigil.cq_workers w
                       WHERE w.beat_at > v_now - make_interval(secs => pgvigil.cq_lease_secs()) AND v_inst = ANY (w.instances)) THEN
      SELECT w.host, w.beat_at INTO v_last FROM pgvigil.cq_workers w WHERE v_inst = ANY (w.instances)
       ORDER BY w.beat_at DESC NULLS LAST LIMIT 1;
      v_why := CASE WHEN v_last.host IS NULL THEN format('no collector takes requests for %s', v_inst)
                    ELSE format('no collector takes requests for %s now (last lease %s on %s)', v_inst,
                                to_char(v_last.beat_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS "UTC"'), v_last.host) END;
    END IF;
  END IF;
  IF v_why IS NULL THEN
    -- the kind's door on a live holder: one open door is enough (the claim takes it only on a claimer whose door is open)
    SELECT d.open, d.why, w.host INTO v_door FROM pgvigil.action_doors d
      JOIN pgvigil.cq_workers w ON w.collector_id = d.collector_id
     WHERE w.beat_at > v_now - make_interval(secs => pgvigil.cq_lease_secs()) AND v_inst = ANY (w.instances)
       AND d.instance = v_inst AND d.kind = v_kind.kind AND d.name = ''
     ORDER BY d.open DESC LIMIT 1;
    IF v_door.open IS NULL THEN
      v_why := format('%s is not through the queue yet on %s', v_kind.label, v_inst);
    ELSIF NOT v_door.open THEN
      v_why := coalesce(v_door.why, format('%s is off for %s', v_kind.label, v_inst)) || format(' (the collector on %s)', v_door.host);
    END IF;
  END IF;
  IF v_why IS NULL AND v_kind.door_field IS NOT NULL THEN
    -- a named door (a tool, a job: ST4's lists) is published only when shut, per holder: the ask is taken when ONE live
    -- holder whose kind door is open has no shut door of that name (the claim takes it only on such a holder), and is
    -- refused with a shutting holder's words only when every open holder shuts it
    v_dname := v_args ->> v_kind.door_field;
    IF NOT EXISTS (
         SELECT 1 FROM pgvigil.cq_workers w JOIN pgvigil.action_doors d ON d.collector_id = w.collector_id
          WHERE w.beat_at > v_now - make_interval(secs => pgvigil.cq_lease_secs()) AND v_inst = ANY (w.instances)
            AND d.instance = v_inst AND d.kind = v_kind.kind AND d.name = '' AND d.open
            AND NOT EXISTS (SELECT 1 FROM pgvigil.action_doors n
                             WHERE n.collector_id = w.collector_id AND n.instance = v_inst AND n.kind = v_kind.kind
                               AND lower(n.name) = lower(v_dname) AND NOT n.open)) THEN
      SELECT n.open, n.why, w.host INTO v_door FROM pgvigil.action_doors n
        JOIN pgvigil.cq_workers w ON w.collector_id = n.collector_id
       WHERE w.beat_at > v_now - make_interval(secs => pgvigil.cq_lease_secs()) AND v_inst = ANY (w.instances)
         AND n.instance = v_inst AND n.kind = v_kind.kind AND lower(n.name) = lower(v_dname) AND NOT n.open
       ORDER BY w.beat_at DESC LIMIT 1;
      v_why := coalesce(v_door.why, format('%s %s is off for %s', v_kind.door_field, v_dname, v_inst)) || format(' (the collector on %s)', v_door.host);
    END IF;
  END IF;
  IF v_why IS NULL AND (SELECT count(*) FROM pgvigil.action_requests r WHERE r.ui_user = v_user AND r.state IN ('waiting', 'running')) >= 10 THEN
    v_why := format('%s already has 10 open requests: wait for one to end', v_user);
  END IF;
  IF v_why IS NULL AND (SELECT count(*) FROM pgvigil.action_requests r WHERE r.asked_login = v_login AND r.state IN ('waiting', 'running')) >= 10 THEN
    v_why := format('the login %s already has 10 open requests: wait for one to end', v_login);
  END IF;
  IF v_why IS NULL AND v_kind.kind = 'collect_now' AND EXISTS (
       SELECT 1 FROM pgvigil.action_requests r JOIN pgvigil.ui_action_data a USING (request_id)
        WHERE r.kind = 'collect_now' AND r.instance = v_inst AND r.state <> 'refused' AND r.asked_at > v_now - interval '30 seconds'
          AND (a.payload ->> 'collection' IN (v_args ->> 'collection', '*') OR v_args ->> 'collection' = '*')) THEN
    v_why := format('%s of %s was asked in the last 30 seconds', v_args ->> 'collection', v_inst);
  END IF;
  -- the lifetime from a checked timeout only: a refused payload's timeout_secs may not be a number at all
  v_life := v_kind.lifetime_s + CASE WHEN v_why IS NULL AND v_kind.class = 'read'
                                     THEN coalesce((v_args ->> 'timeout_secs')::int, v_kind.max_timeout_s, 0) ELSE 0 END;
  v_exp := v_now + make_interval(secs => v_life);
  INSERT INTO pgvigil.action_requests (kind, class, instance, ui_user, client, asked_login, asked_at, expires_at, state, done_at, refusal)
  VALUES (v_kind.kind, v_kind.class, left(coalesce(v_inst, ''), 200), left(v_user, 200), v_client, v_login, v_now, v_exp,
          CASE WHEN v_why IS NULL THEN 'waiting' ELSE 'refused' END, CASE WHEN v_why IS NOT NULL THEN v_now END, v_why)
  RETURNING request_id INTO v_id;
  IF v_why IS NULL THEN
    INSERT INTO pgvigil.ui_action_data (request_id, payload) VALUES (v_id, v_args);
  END IF;
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'waiting' ELSE 'refused' END,
                            'detail', coalesce(v_why, format('%s on %s asked: a collector takes it within seconds', v_kind.label, v_inst)),
                            'request_id', v_id, 'expires_at', v_exp);
END $$;

-- import_action_cancel: the asker's cancel. Waiting = 'cancelled' at once; running = cancel_asked_at set (the notify and
-- the holder's next poll cancel the run). Another user's request is refused with words.
CREATE OR REPLACE FUNCTION pgvigil.import_action_cancel(p_request_id bigint, p_ui_user text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_now  timestamptz := clock_timestamp();
  r      pgvigil.action_requests;
BEGIN
  SELECT * INTO r FROM pgvigil.action_requests WHERE request_id = p_request_id FOR UPDATE;
  IF r.request_id IS NULL THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', format('no request %s', p_request_id));
  ELSIF r.ui_user <> lower(btrim(coalesce(p_ui_user, ''))) THEN
    RETURN jsonb_build_object('outcome', 'refused', 'detail', 'this run was asked by another user');
  ELSIF r.state = 'waiting' THEN
    UPDATE pgvigil.action_requests SET state = 'cancelled', done_at = v_now, outcome = 'cancelled before a collector took it'
     WHERE request_id = p_request_id;
    PERFORM pg_notify('pgvigil_result', p_request_id::text);
    RETURN jsonb_build_object('outcome', 'cancelled', 'detail', 'cancelled before a collector took it');
  ELSIF r.state = 'running' THEN
    UPDATE pgvigil.action_requests SET cancel_asked_at = coalesce(cancel_asked_at, v_now) WHERE request_id = p_request_id;
    RETURN jsonb_build_object('outcome', 'asked', 'detail', format('the collector on %s is asked to cancel it', r.taken_host));
  END IF;
  RETURN jsonb_build_object('outcome', 'refused', 'detail', format('request %s already ended (%s)', p_request_id, r.state));
END $$;

-- ---- the worker's side ---------------------------------------------------------------------------------------------
-- import_action_sweep: waiting requests past expires_at -> 'expired'; running ones whose lease lapsed -> 'lost' (never
-- run again); kept results past keep_until, or read under the 'read' keep -> cleared (a '7d' keep stays its 7 days,
-- read or not: task 488). Each change notifies pgvigil_result. Returns the count.
CREATE OR REPLACE FUNCTION pgvigil.import_action_sweep()
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_now  timestamptz := clock_timestamp();
  v_n    int := 0;
  v_id   bigint;
BEGIN
  FOR v_id IN
    UPDATE pgvigil.action_requests SET state = 'expired', done_at = v_now,
           outcome = 'no collector took it before it expired: it was never run'
     WHERE state = 'waiting' AND expires_at <= v_now RETURNING request_id
  LOOP
    PERFORM pg_notify('pgvigil_result', v_id::text); v_n := v_n + 1;
  END LOOP;
  FOR v_id IN
    UPDATE pgvigil.action_requests SET state = 'lost', done_at = v_now,
           outcome = format('the collector on %s stopped while running it: it may or may not have run', taken_host)
     WHERE state = 'running' AND lease_until <= v_now RETURNING request_id
  LOOP
    PERFORM pg_notify('pgvigil_result', v_id::text); v_n := v_n + 1;
  END LOOP;
  WITH c AS (
    UPDATE pgvigil.action_requests SET cleared_at = v_now
     WHERE cleared_at IS NULL AND keep_until IS NOT NULL AND (keep_until <= v_now OR (read_at IS NOT NULL AND keep = 'read'))
     RETURNING request_id)
  UPDATE pgvigil.ui_action_data a SET result = NULL FROM c WHERE a.request_id = c.request_id;
  RETURN v_n;
END $$;

-- import_cq_beat: the worker's lease (its instances now) and the lease_until of the running rows it still runs
-- (p_running, the ids in its memory), on the repository clock. A running row of this worker that is NOT in p_running
-- (its finish failed, or its claimed row was never started) is not renewed: it lapses and the sweep says 'lost'.
-- Returns the ids among p_running whose cancel was asked (the poll's cancel read: seen behind a pooler).
DROP FUNCTION IF EXISTS pgvigil.import_cq_beat(text, text, text[]);  -- an earlier build of this file
CREATE OR REPLACE FUNCTION pgvigil.import_cq_beat(p_collector_id text, p_host text, p_instances text[], p_running bigint[])
RETURNS SETOF bigint LANGUAGE plpgsql AS $$
DECLARE
  v_now  timestamptz := clock_timestamp();
BEGIN
  INSERT INTO pgvigil.cq_workers AS w (collector_id, host, instances, started_at, beat_at)
  VALUES (p_collector_id, left(p_host, 200), coalesce(p_instances, '{}'), v_now, v_now)
  ON CONFLICT (collector_id) DO UPDATE SET host = EXCLUDED.host, instances = EXCLUDED.instances, beat_at = v_now, stopped_at = NULL;
  UPDATE pgvigil.action_requests SET lease_until = v_now + make_interval(secs => pgvigil.cq_run_lease_secs())
   WHERE taken_by = p_collector_id AND state = 'running' AND request_id = ANY (coalesce(p_running, '{}'));
  RETURN QUERY SELECT r.request_id FROM pgvigil.action_requests r
                WHERE r.taken_by = p_collector_id AND r.state = 'running' AND r.cancel_asked_at IS NOT NULL
                  AND r.request_id = ANY (coalesce(p_running, '{}'));
END $$;

-- import_cq_stop: a clean stop ends the lease at once (an insert then refuses instead of waiting for an expiry)
CREATE OR REPLACE FUNCTION pgvigil.import_cq_stop(p_collector_id text)
RETURNS void LANGUAGE sql AS $$
  UPDATE pgvigil.cq_workers SET beat_at = NULL, stopped_at = clock_timestamp() WHERE collector_id = p_collector_id
$$;

-- import_cq_page_held: whether the page lease (0122's admin_page_holder) is held by a holder whose name starts with
-- p_prefix ('<host>:<pid>:', the scheduler's own lease in this process) and was renewed within the lease's 45 s: the
-- worker holds the page's instances exactly while its own process's scheduler does
CREATE OR REPLACE FUNCTION pgvigil.import_cq_page_held(p_prefix text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT coalesce(p_prefix, '') <> '' AND EXISTS (
    SELECT 1 FROM pgvigil.admin_page_holder h
     WHERE left(h.holder, length(p_prefix)) = p_prefix AND h.beat > now() - interval '45 seconds')
$$;

-- import_cq_doors: the worker's doors replaced whole [{instance, kind, name?, open, why?}]
CREATE OR REPLACE FUNCTION pgvigil.import_cq_doors(p_collector_id text, p_doors jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_n  int;
BEGIN
  DELETE FROM pgvigil.action_doors WHERE collector_id = p_collector_id;
  INSERT INTO pgvigil.action_doors (collector_id, instance, kind, name, open, why, at)
  SELECT p_collector_id, left(d ->> 'instance', 200), d ->> 'kind', left(coalesce(d ->> 'name', ''), 200),
         coalesce((d ->> 'open')::boolean, false), left(d ->> 'why', 1000), clock_timestamp()
    FROM jsonb_array_elements(coalesce(p_doors, '[]'::jsonb)) d
   WHERE d ->> 'kind' IN (SELECT kind FROM pgvigil.action_kinds) AND coalesce(d ->> 'instance', '') <> ''
  ON CONFLICT (collector_id, instance, kind, name) DO UPDATE SET open = EXCLUDED.open, why = EXCLUDED.why, at = EXCLUDED.at;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- import_cq_tools: one instance's community tools as this worker found them [{tool, present, why?, version?, params?,
-- database?}]
CREATE OR REPLACE FUNCTION pgvigil.import_cq_tools(p_collector_id text, p_instance text, p_tools jsonb)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_n  int;
BEGIN
  DELETE FROM pgvigil.cq_tools WHERE collector_id = p_collector_id AND instance = p_instance;
  INSERT INTO pgvigil.cq_tools (collector_id, instance, tool, present, why, version, params, database, at)
  SELECT p_collector_id, left(p_instance, 200), left(t ->> 'tool', 200), coalesce((t ->> 'present')::boolean, false),
         left(t ->> 'why', 1000), left(t ->> 'version', 100), t -> 'params', left(nullif(t ->> 'database', ''), 128), clock_timestamp()
    FROM jsonb_array_elements(coalesce(p_tools, '[]'::jsonb)) t
   WHERE coalesce(t ->> 'tool', '') <> ''
  ON CONFLICT (collector_id, instance, tool) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- import_action_claim: the waiting requests of the instances this worker holds now whose (instance, kind) door is open
-- ON THIS WORKER, oldest first, the urgent kinds first: at most p_free + p_urgent in all, at most p_free of them not
-- urgent, and per instance at most p_room->>instance (the worker's own count: 2 less what it runs there; absent = 2) of
-- the kinds that are not urgent (an urgent kind skips the per-instance cap). Each is set running with this worker's run
-- lease. remaining_ms is expires_at - now() on the repository clock: the worker's deadline is its monotonic clock plus it.
CREATE OR REPLACE FUNCTION pgvigil.import_action_claim(p_collector_id text, p_free int, p_urgent int, p_room jsonb)
RETURNS TABLE (request_id bigint, kind text, instance text, ui_user text, client text, payload jsonb, remaining_ms bigint)
LANGUAGE plpgsql AS $$
#variable_conflict use_column
DECLARE
  v_now  timestamptz := clock_timestamp();
  v_host text;
  v_inst text[];
  v_free int := greatest(coalesce(p_free, 0), 0);
  v_all  int := greatest(coalesce(p_free, 0), 0) + greatest(coalesce(p_urgent, 0), 0);
BEGIN
  PERFORM pgvigil.import_action_sweep();
  SELECT w.host, w.instances INTO v_host, v_inst FROM pgvigil.cq_workers w
   WHERE w.collector_id = p_collector_id AND w.beat_at > v_now - make_interval(secs => pgvigil.cq_lease_secs());
  IF v_host IS NULL OR v_all = 0 THEN
    RETURN;  -- no live lease (the worker renews first) or no room
  END IF;
  RETURN QUERY
  WITH cand AS (
    SELECT r.request_id AS rid, k.urgent, r.asked_at,
           row_number() OVER (PARTITION BY r.instance, k.urgent ORDER BY r.asked_at) AS n_inst,
           coalesce((p_room ->> r.instance)::int, 2) AS room
      FROM pgvigil.action_requests r
      JOIN pgvigil.action_kinds k ON k.kind = r.kind
     WHERE r.state = 'waiting' AND r.expires_at > v_now AND r.instance = ANY (v_inst)
       AND EXISTS (SELECT 1 FROM pgvigil.action_doors d WHERE d.collector_id = p_collector_id AND d.instance = r.instance
                      AND d.kind = r.kind AND d.name = '' AND d.open)
       -- and no shut named door of the request's tool or job on THIS worker: the one that would refuse never takes it
       AND (k.door_field IS NULL OR NOT EXISTS (
             SELECT 1 FROM pgvigil.action_doors n JOIN pgvigil.ui_action_data a ON a.request_id = r.request_id
              WHERE n.collector_id = p_collector_id AND n.instance = r.instance AND n.kind = r.kind
                AND lower(n.name) = lower(a.payload ->> k.door_field) AND NOT n.open))
  ), fit AS (
    SELECT c.rid, c.urgent, c.asked_at,
           row_number() OVER (PARTITION BY c.urgent ORDER BY c.asked_at) AS n_kind
      FROM cand c WHERE c.urgent OR c.n_inst <= c.room
  ), pick AS (
    SELECT f.rid, row_number() OVER (ORDER BY f.urgent DESC, f.asked_at) AS n_all
      FROM fit f WHERE f.urgent OR f.n_kind <= v_free
  ), locked AS (
    SELECT r.request_id AS rid FROM pgvigil.action_requests r JOIN pick p ON p.rid = r.request_id
     WHERE p.n_all <= v_all AND r.state = 'waiting' FOR UPDATE OF r SKIP LOCKED
  ), took AS (
    UPDATE pgvigil.action_requests r SET state = 'running', taken_by = p_collector_id, taken_host = v_host, taken_at = v_now,
           lease_until = v_now + make_interval(secs => pgvigil.cq_run_lease_secs())
      FROM locked l WHERE r.request_id = l.rid
    RETURNING r.request_id AS rid, r.kind AS rkind, r.instance AS rinst, r.ui_user AS ruser, r.client AS rclient, r.expires_at AS rexp
  )
  SELECT t.rid, t.rkind, t.rinst, t.ruser, t.rclient, a.payload,
         greatest(0, (extract(epoch FROM (t.rexp - clock_timestamp())) * 1000)::bigint)  -- at the claim's end, not its start
    FROM took t JOIN pgvigil.ui_action_data a ON a.request_id = t.rid
   ORDER BY t.rid;
END $$;

-- import_action_finish: the worker's end of one of its running requests {state, outcome, refusal, result, rows,
-- duration_ms, keep: 'read' | '7d'}. False when the row is no longer this worker's running row (lost, or cancelled
-- and swept): the worker then rolls back the audit rows it wrote in the same transaction.
CREATE OR REPLACE FUNCTION pgvigil.import_action_finish(p_collector_id text, p_request_id bigint, p_end jsonb)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  v_now    timestamptz := clock_timestamp();
  v_state  text := p_end ->> 'state';
  v_result jsonb := p_end -> 'result';
  v_keep   text := coalesce(p_end ->> 'keep', 'read');
  v_out    text := p_end ->> 'outcome';
  v_bytes  int;
  v_ok     boolean;
BEGIN
  IF v_state NOT IN ('done', 'failed', 'refused', 'cancelled') THEN
    RAISE EXCEPTION 'import_action_finish: state % is not an end', v_state USING ERRCODE = '22023';
  END IF;
  -- a result over ui_action_data's 8 MB as jsonb's text (the worker cuts by its own measure, which can fall short of
  -- this one) ends 'failed' with words instead of raising: a raise would leave the row running until its lease lapses
  v_bytes := octet_length(v_result::text);
  IF v_bytes > 8388608 THEN
    v_state := 'failed';
    v_out := format('it ran, but its result is %s MB as stored, over the 8 MB queue mode keeps: the result is not kept (ask for fewer rows)',
                    round(v_bytes / 1048576.0, 1));
    v_result := NULL;
  END IF;
  UPDATE pgvigil.action_requests SET state = v_state, done_at = v_now, outcome = left(v_out, 2000),
         refusal = left(p_end ->> 'refusal', 2000), rows_out = (p_end ->> 'rows')::int, duration_ms = (p_end ->> 'duration_ms')::int,
         result_bytes = CASE WHEN v_result IS NOT NULL THEN v_bytes END,
         keep_until = CASE WHEN v_result IS NULL THEN NULL WHEN v_keep = '7d' THEN v_now + interval '7 days' ELSE v_now + interval '1 hour' END,
         keep = CASE WHEN v_keep = '7d' THEN '7d' ELSE 'read' END,
         lease_until = NULL
   WHERE request_id = p_request_id AND taken_by = p_collector_id AND state = 'running';
  v_ok := FOUND;
  IF v_ok THEN
    UPDATE pgvigil.ui_action_data SET result = v_result WHERE request_id = p_request_id;
    PERFORM pg_notify('pgvigil_result', p_request_id::text);
  END IF;
  RETURN v_ok;
END $$;

-- import_cq_instance_id: an instance's id by its name, for the audit rows the worker writes (the collector's login
-- reads no table; NULL when the name is not registered)
CREATE OR REPLACE FUNCTION pgvigil.import_cq_instance_id(p_name text)
RETURNS int LANGUAGE sql STABLE AS $$
  SELECT i.instance_id FROM pgvigil.instances i WHERE i.name = p_name
$$;

-- ---- the asker's read ------------------------------------------------------------------------------------------------
-- ui_action_result: one request's state and, for its asker alone, its result (a 'read' keep is cleared at the next
-- sweep once read). Another user gets the refusal words and no data - except under a '7d' keep (the collector's
-- cq.result_keep: 7d, an opt-in whose words say every pgvigil user can read every stored result; task 488), which
-- answers every signed-in user as it answers the asker; only the asker's read sets read_at.
CREATE OR REPLACE FUNCTION pgvigil.ui_action_result(p_request_id bigint, p_ui_user text)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  r  pgvigil.action_requests;
  v  jsonb;
BEGIN
  PERFORM pgvigil.import_action_sweep();  -- with no live worker left nothing else sweeps: the asker still sees 'lost' or 'expired'
  SELECT * INTO r FROM pgvigil.action_requests WHERE request_id = p_request_id;
  IF r.request_id IS NULL THEN
    RETURN jsonb_build_object('refused', format('no request %s', p_request_id));
  ELSIF r.ui_user <> lower(btrim(coalesce(p_ui_user, ''))) AND r.keep <> '7d' THEN
    RETURN jsonb_build_object('refused', 'this run was asked by another user');
  END IF;
  SELECT a.result INTO v FROM pgvigil.ui_action_data a WHERE a.request_id = p_request_id;
  IF v IS NOT NULL AND r.read_at IS NULL AND r.state IN ('done', 'failed') AND r.ui_user = lower(btrim(coalesce(p_ui_user, ''))) THEN
    UPDATE pgvigil.action_requests SET read_at = clock_timestamp() WHERE request_id = p_request_id;
  END IF;
  RETURN jsonb_build_object('request_id', r.request_id, 'kind', r.kind, 'instance', r.instance, 'state', r.state,
                            'asked_at', r.asked_at, 'expires_at', r.expires_at, 'taken_host', r.taken_host, 'taken_at', r.taken_at,
                            'done_at', r.done_at, 'outcome', r.outcome, 'refusal', r.refusal, 'rows', r.rows_out,
                            'duration_ms', r.duration_ms, 'cleared', r.cleared_at IS NOT NULL, 'result', v);
END $$;

-- the requester's two doors (apply_roles grants every import_* to the collector and leaves this grant alone)
GRANT EXECUTE ON FUNCTION pgvigil.import_action_request(jsonb), pgvigil.import_action_cancel(bigint, text) TO pgvigil_requester;
