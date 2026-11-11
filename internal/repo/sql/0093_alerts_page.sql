-- 0093 alerting completion (task 151, K07): the page per alert, triage, the open channels, Send test, the send cap,
-- mute rules with a start, an edit and a pause, and the alert history.
--
--   alert_channels      kind takes 'opsgenie'; max_per_hour (0 = no cap), templates (which events and parts carry a
--                       template, never their text) and link_base (alerts_base_url) as the sender last recorded them.
--   alert_log           outcome takes 'capped' (held by max_per_hour, owed again: alert_record moves nothing for it)
--                       and 'test' (a Send test answered; its 'failed' and 'refused' as any send).
--   alert_tests         every Send test asked from the Alerts page (who, from where, the channel) and the sender's
--                       answer (sent, failed, refused, with the destination's error); refused requests are rows too.
--   alert_dismissals    a finding dismissed with a reason ("tolerable for this server"): the open-alerts grid hides it
--                       behind Show dismissed. A dismissal changes what the grid shows, not what is sent: a mute or
--                       an acknowledgement holds the sends.
--   acks                paused_at / paused_by (a mute rule paused holds nothing until resumed) and replaces (an edit
--                       ends the rule and writes its successor, as alert rules do).
--   ack_log             op takes 'edit', 'pause' and 'resume' beside add and end.
--   alert_occurrences   every firing of every alert over the channels (an occurrence = the channel rows of one
--                       finding key whose send periods overlap), its clearance and how it ended.
--   finding_fix         the statement a finding's fix is, or NULL: ALTER SYSTEM for a PostgreSQL setting finding
--                       with a one-word suggested value; a maintenance statement the finding's detail spells out.
--
-- Writes from the UI: pgvigil.import_alert_test, pgvigil.import_alert_dismiss and pgvigil.import_ack_change (the
-- actions door's audit login: apply_roles makes every import_* SECURITY DEFINER and grants it to pgvigil_collector),
-- behind the UI login, as import_ack. The sender (pgvigil_alerter) reads the test requests (alert_tests_due) and
-- answers them (alert_test_record). alert_tests is purged after the purge window (the join's purge() line);
-- alert_dismissals is an audit like acks and is not purged.

ALTER TABLE pgvigil.alert_channels DROP CONSTRAINT IF EXISTS alert_channels_kind_check;
ALTER TABLE pgvigil.alert_channels ADD CONSTRAINT alert_channels_kind_check
  CHECK (kind IN ('smtp', 'webhook', 'file', 'pagerduty', 'opsgenie'));
ALTER TABLE pgvigil.alert_channels ADD COLUMN IF NOT EXISTS max_per_hour int NOT NULL DEFAULT 0 CHECK (max_per_hour >= 0);
ALTER TABLE pgvigil.alert_channels ADD COLUMN IF NOT EXISTS templates text;
ALTER TABLE pgvigil.alert_channels ADD COLUMN IF NOT EXISTS link_base text;

ALTER TABLE pgvigil.alert_log DROP CONSTRAINT IF EXISTS alert_log_outcome_check;
ALTER TABLE pgvigil.alert_log ADD CONSTRAINT alert_log_outcome_check
  CHECK (outcome IN ('sent', 'failed', 'refused', 'cleared', 'none', 'capped', 'test'));

ALTER TABLE pgvigil.ack_log DROP CONSTRAINT IF EXISTS ack_log_op_check;
ALTER TABLE pgvigil.ack_log ADD CONSTRAINT ack_log_op_check CHECK (op IN ('add', 'end', 'edit', 'pause', 'resume'));

ALTER TABLE pgvigil.acks ADD COLUMN IF NOT EXISTS paused_at timestamptz;
ALTER TABLE pgvigil.acks ADD COLUMN IF NOT EXISTS paused_by text;
ALTER TABLE pgvigil.acks ADD COLUMN IF NOT EXISTS replaces bigint REFERENCES pgvigil.acks (ack_id);

-- alert_channels_sync: 0059's, with max_per_hour, templates and link_base
CREATE OR REPLACE FUNCTION pgvigil.alert_channels_sync(p_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.alert_channels AS c (name, kind, destination, min_severity, instances, tags, quiet_hours, timezone,
                                           repeat_secs, clear_after_secs, recovery, max_per_hour, templates, link_base,
                                           is_configured, configured_at, updated_at)
  SELECT x.name, x.kind, x.destination, x.min_severity, coalesce(x.instances, '{}'), coalesce(x.tags, '{}'),
         nullif(x.quiet_hours, ''), nullif(x.timezone, ''), x.repeat_secs, coalesce(x.clear_after_secs, 600), x.recovery,
         coalesce(x.max_per_hour, 0), nullif(x.templates, ''), nullif(x.link_base, ''), true, p_at, p_at
    FROM jsonb_to_recordset(coalesce(p_payload, '[]'::jsonb)) AS x(name text, kind text, destination text, min_severity text,
         instances text[], tags text[], quiet_hours text, timezone text, repeat_secs int, clear_after_secs int, recovery boolean,
         max_per_hour int, templates text, link_base text)
  ON CONFLICT (name) DO UPDATE SET kind = EXCLUDED.kind, destination = EXCLUDED.destination,
    min_severity = EXCLUDED.min_severity, instances = EXCLUDED.instances, tags = EXCLUDED.tags,
    quiet_hours = EXCLUDED.quiet_hours, timezone = EXCLUDED.timezone, repeat_secs = EXCLUDED.repeat_secs,
    clear_after_secs = EXCLUDED.clear_after_secs, recovery = EXCLUDED.recovery, max_per_hour = EXCLUDED.max_per_hour,
    templates = EXCLUDED.templates, link_base = EXCLUDED.link_base, is_configured = true,
    updated_at = EXCLUDED.updated_at,
    configured_at = CASE WHEN c.is_configured THEN c.configured_at ELSE EXCLUDED.configured_at END;
  UPDATE pgvigil.alert_channels c SET is_configured = false, updated_at = p_at
   WHERE c.is_configured
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_payload, '[]'::jsonb)) e WHERE e->>'name' = c.name);
END $$;

-- ack_hold: 0073's, a paused rule holding nothing
CREATE OR REPLACE FUNCTION pgvigil.ack_hold(p_at timestamptz, p_instance text, p_tags text[], p_finding_key text,
                                            p_source text, p_setting text, p_value text)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT a.ack_id FROM pgvigil.acks a
   WHERE a.kind IN ('mute', 'silence', 'blackout') AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, p_at)
     AND a.paused_at IS NULL
     AND pgvigil.ack_rule_matches(a, p_instance, p_tags, p_finding_key, p_source, p_setting, p_value)
   ORDER BY a.ack_id LIMIT 1
$$;

-- import_ack_change: an edit, a pause or a resume of a mute rule or a known pattern from the UI (the actions door's
-- audit login). p_payload: {op: edit | pause | resume, ack_id, ui_user, client}, and for edit the rule's fields as
-- import_ack takes them (instance_id, instance_name, check_key, tag, match_text, note, starts_at, until). An edit is
-- import_ack's add of the successor (replaces = the old rule, its pause kept) and its end of the old rule, in one call:
-- a refused add ends nothing. Pause and resume are mute rules' only (a known pattern holds nothing). Every attempt
-- leaves an ack_log row. Returns {outcome, detail, ack_id} (ack_id: the successor of an edit).
CREATE OR REPLACE FUNCTION pgvigil.import_ack_change(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client text := nullif(p_payload->>'client', '');
  v_id     bigint;
  v_row    pgvigil.acks;
  v_why    text;
  v_add    jsonb;
  v_end    jsonb;
  v_new    bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_ack_change: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF coalesce(p_payload->>'ack_id', '') ~ '^[0-9]{1,18}$' THEN
    v_id := (p_payload->>'ack_id')::bigint;
    SELECT * INTO v_row FROM pgvigil.acks WHERE ack_id = v_id FOR UPDATE;
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('edit', 'pause', 'resume') THEN
    v_why := 'op must be edit, pause or resume';
  ELSIF v_id IS NULL THEN
    v_why := format('ack_id %L is not a rule id', p_payload->>'ack_id');
  ELSIF v_row.ack_id IS NULL THEN
    v_why := format('no rule %s', v_id);
  ELSIF v_row.ended_at IS NOT NULL THEN
    v_why := format('rule %s was ended by %s at %s', v_id, v_row.ended_by, v_row.ended_at);
  ELSIF v_row.until IS NOT NULL AND v_row.until <= p_at THEN
    v_why := format('rule %s expired at %s', v_id, v_row.until);
  ELSIF v_op = 'edit' AND v_row.kind NOT IN ('mute', 'noise') THEN
    v_why := format('a %s is not edited here (only mute rules and known patterns)', v_row.kind);
  ELSIF v_op IN ('pause', 'resume') AND v_row.kind <> 'mute' THEN
    v_why := format('only a mute rule is paused (rule %s is a %s)', v_id, v_row.kind);
  ELSIF v_op = 'pause' AND v_row.paused_at IS NOT NULL THEN
    v_why := format('rule %s is already paused (by %s at %s)', v_id, v_row.paused_by, v_row.paused_at);
  ELSIF v_op = 'resume' AND v_row.paused_at IS NULL THEN
    v_why := format('rule %s is not paused', v_id);
  END IF;
  IF v_why IS NULL AND v_op = 'pause' THEN
    UPDATE pgvigil.acks SET paused_at = p_at, paused_by = v_user WHERE ack_id = v_id;
  ELSIF v_why IS NULL AND v_op = 'resume' THEN
    UPDATE pgvigil.acks SET paused_at = NULL, paused_by = NULL WHERE ack_id = v_id;
  ELSIF v_why IS NULL AND v_op = 'edit' THEN
    v_add := jsonb_strip_nulls(jsonb_build_object('op', 'add', 'ui_user', v_user, 'client', v_client, 'kind', v_row.kind,
               'instance_id', p_payload->'instance_id', 'instance_name', p_payload->'instance_name',
               'check_key', p_payload->'check_key', 'tag', p_payload->'tag', 'match_text', p_payload->'match_text',
               'note', p_payload->'note', 'starts_at', p_payload->'starts_at', 'until', p_payload->'until'));
    IF coalesce(btrim(v_add->>'check_key'), '') = '' AND coalesce(btrim(v_add->>'tag'), '') = ''
       AND coalesce(btrim(v_add->>'match_text'), '') = '' AND coalesce(btrim(v_add->>'instance_name'), '') = ''
       AND v_row.finding_key IS NULL THEN
      v_why := 'the edited rule matches every alert: name a check, an instance, a tag or a text';
    ELSE
      IF v_row.finding_key IS NOT NULL THEN
        v_add := v_add || jsonb_build_object('finding_key', v_row.finding_key);
      END IF;
      v_end := pgvigil.import_ack(p_at, v_add);
      IF v_end->>'outcome' <> 'done' THEN
        v_why := 'the successor was refused: ' || coalesce(v_end->>'detail', '');
      ELSE
        v_new := (v_end->>'ack_id')::bigint;
        UPDATE pgvigil.acks SET replaces = v_id, paused_at = v_row.paused_at, paused_by = v_row.paused_by WHERE ack_id = v_new;
        v_end := pgvigil.import_ack(p_at, jsonb_build_object('op', 'end', 'ui_user', v_user, 'client', v_client, 'ack_id', v_id));
        IF v_end->>'outcome' <> 'done' THEN
          RAISE EXCEPTION 'import_ack_change: rule % not ended: %', v_id, v_end->>'detail';
        END IF;
      END IF;
    END IF;
  END IF;
  INSERT INTO pgvigil.ack_log (at, ui_user, client, op, kind, ack_id, instance_name, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, CASE WHEN v_op IN ('edit', 'pause', 'resume') THEN v_op ELSE 'edit' END, v_row.kind, v_id,
          v_row.instance_name, CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
          coalesce(v_why, CASE v_op WHEN 'edit' THEN format('rule %s replaced by rule %s', v_id, v_new)
                                    WHEN 'pause' THEN 'paused' ELSE 'resumed' END), p_payload);
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, CASE v_op WHEN 'edit' THEN format('rule %s replaced by rule %s', v_id, v_new)
                                                            WHEN 'pause' THEN 'paused' ELSE 'resumed' END),
                            'ack_id', coalesce(v_new, v_id));
END $$;

-- ---- Send test ------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.alert_tests (
  test_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  channel       text NOT NULL,
  requested_by  text NOT NULL,
  requested_at  timestamptz NOT NULL,
  client        text,
  done_at       timestamptz,
  outcome       text CHECK (outcome IN ('sent', 'failed', 'refused')),
  error         text
);
CREATE INDEX IF NOT EXISTS alert_tests_due_idx ON pgvigil.alert_tests (requested_at) WHERE done_at IS NULL;
COMMENT ON TABLE pgvigil.alert_tests IS 'Send test requests from the Alerts page and the sender''s answers; written through import_alert_test and alert_test_record only.';
GRANT SELECT, UPDATE ON pgvigil.alert_tests TO pgvigil_alerter;

-- the window a request waits for a sender: past it the page says no sender answered
CREATE OR REPLACE FUNCTION pgvigil.alert_test_window()
RETURNS interval LANGUAGE sql IMMUTABLE AS $$ SELECT interval '1 hour' $$;

-- import_alert_test: one Send test request {ui_user, client, channel}; refused (and recorded) when the channel is
-- not configured or a request of it already waits. Returns {outcome, detail, test_id}.
CREATE OR REPLACE FUNCTION pgvigil.import_alert_test(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client text := nullif(p_payload->>'client', '');
  v_chan   text := nullif(btrim(coalesce(p_payload->>'channel', '')), '');
  v_why    text;
  v_wait   pgvigil.alert_tests;
  v_id     bigint;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_alert_test: no ui_user' USING ERRCODE = '22023';
  END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.alert_tests:' || coalesce(v_chan, ''), 0));
  SELECT * INTO v_wait FROM pgvigil.alert_tests t
   WHERE t.channel = v_chan AND t.done_at IS NULL AND t.requested_at > p_at - pgvigil.alert_test_window()
   ORDER BY t.requested_at DESC LIMIT 1;
  IF v_chan IS NULL OR length(v_chan) > 63 THEN
    v_why := 'no channel named';
  ELSIF NOT EXISTS (SELECT 1 FROM pgvigil.alert_channels c WHERE c.name = v_chan AND c.is_configured) THEN
    v_why := format('channel %s is not configured (the sender''s last record of its alerts: list)', v_chan);
  ELSIF v_wait.test_id IS NOT NULL THEN
    v_why := format('a test of %s asked by %s at %s still waits for the sender', v_chan, v_wait.requested_by, v_wait.requested_at);
  END IF;
  INSERT INTO pgvigil.alert_tests (channel, requested_by, requested_at, client, done_at, outcome, error)
  VALUES (coalesce(v_chan, ''), v_user, p_at, v_client, CASE WHEN v_why IS NOT NULL THEN p_at END,
          CASE WHEN v_why IS NOT NULL THEN 'refused' END, v_why)
  RETURNING test_id INTO v_id;
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, format('test %s of %s asked: the sender''s next pass sends it (within a minute while pgvigil run is up)', v_id, v_chan)),
                            'test_id', v_id);
END $$;

-- alert_tests_due: the requests a sender owes at p_at (asked within the window, unanswered), oldest first
CREATE OR REPLACE FUNCTION pgvigil.alert_tests_due(p_at timestamptz)
RETURNS TABLE (test_id bigint, channel text, requested_by text, requested_at timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT t.test_id, t.channel, t.requested_by, t.requested_at FROM pgvigil.alert_tests t
   WHERE t.done_at IS NULL AND t.requested_at > p_at - pgvigil.alert_test_window() AND t.requested_at <= p_at
   ORDER BY t.requested_at
   LIMIT 50
$$;

-- alert_test_record: the sender's answer to one request (an answered one is left as it is)
CREATE OR REPLACE FUNCTION pgvigil.alert_test_record(p_at timestamptz, p_test_id bigint, p_outcome text, p_error text)
RETURNS void LANGUAGE sql AS $$
  UPDATE pgvigil.alert_tests SET done_at = p_at, outcome = p_outcome, error = left(nullif(p_error, ''), 2000)
   WHERE test_id = p_test_id AND done_at IS NULL
$$;
GRANT EXECUTE ON FUNCTION pgvigil.alert_tests_due(timestamptz), pgvigil.alert_test_record(timestamptz, bigint, text, text),
  pgvigil.alert_test_window() TO pgvigil_alerter;

-- ---- dismissals ---------------------------------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pgvigil.alert_dismissals (
  dismiss_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  finding_key    text NOT NULL,
  instance_id    int REFERENCES pgvigil.instances (instance_id) ON DELETE SET NULL,
  instance_name  text,
  source         text,
  setting        text,
  reason         text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 500),
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  client         text,
  ended_by       text,
  ended_at       timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS alert_dismissals_live_uq ON pgvigil.alert_dismissals (finding_key) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.alert_dismissals IS 'Findings dismissed from the open-alerts grid with a reason; written through import_alert_dismiss only; not purged (an audit).';

-- import_alert_dismiss: {op: add | end, ui_user, client, finding_key, reason | dismiss_id}; each attempt is an
-- ack_log row of kind 'dismiss'. A dismissal names an alert the sender sent (an alert_state row of the key). Returns
-- {outcome, detail, dismiss_id}.
CREATE OR REPLACE FUNCTION pgvigil.import_alert_dismiss(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op     text := p_payload->>'op';
  v_user   text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client text := nullif(p_payload->>'client', '');
  v_key    text := nullif(btrim(coalesce(p_payload->>'finding_key', '')), '');
  v_reason text := nullif(btrim(coalesce(p_payload->>'reason', '')), '');
  v_id     bigint;
  v_row    pgvigil.alert_dismissals;
  v_st     pgvigil.alert_state;
  v_why    text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_alert_dismiss: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op = 'end' THEN
    IF coalesce(p_payload->>'dismiss_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'dismiss_id')::bigint;
      SELECT * INTO v_row FROM pgvigil.alert_dismissals WHERE dismiss_id = v_id FOR UPDATE;
    END IF;
    IF v_row.dismiss_id IS NULL THEN
      v_why := format('no dismissal %s', coalesce(p_payload->>'dismiss_id', ''));
    ELSIF v_row.ended_at IS NOT NULL THEN
      v_why := format('dismissal %s was already ended by %s at %s', v_id, v_row.ended_by, v_row.ended_at);
    ELSE
      UPDATE pgvigil.alert_dismissals SET ended_by = v_user, ended_at = p_at WHERE dismiss_id = v_id;
    END IF;
    v_key := coalesce(v_row.finding_key, v_key);
  ELSIF v_op IS DISTINCT FROM 'add' THEN
    v_why := 'op must be add or end';
  ELSE
    PERFORM pg_advisory_xact_lock(hashtextextended('pgvigil.alert_dismissals:' || coalesce(v_key, ''), 0));
    SELECT * INTO v_st FROM pgvigil.alert_state s WHERE s.finding_key = v_key ORDER BY s.last_sent_at DESC LIMIT 1;
    IF v_key IS NULL OR v_key !~ '^[0-9a-f]{32}$' THEN
      v_why := 'finding_key must be an alert''s key (32 hexadecimal digits)';
    ELSIF v_st.finding_key IS NULL THEN
      v_why := format('no alert was sent for finding %s', v_key);
    ELSIF v_reason IS NULL OR length(v_reason) > 500 THEN
      v_why := 'a dismissal needs a reason of 1 to 500 characters';
    ELSIF EXISTS (SELECT 1 FROM pgvigil.alert_dismissals d WHERE d.finding_key = v_key AND d.ended_at IS NULL) THEN
      v_why := 'this alert is already dismissed';
    ELSE
      INSERT INTO pgvigil.alert_dismissals (finding_key, instance_id, instance_name, source, setting, reason, created_by,
                                            created_at, client)
      VALUES (v_key, v_st.instance_id, v_st.instance_name, v_st.source, v_st.setting, v_reason, v_user, p_at, v_client)
      RETURNING dismiss_id INTO v_id;
    END IF;
  END IF;
  INSERT INTO pgvigil.ack_log (at, ui_user, client, op, kind, ack_id, instance_name, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, CASE WHEN v_op = 'end' THEN 'end' ELSE 'add' END, 'dismiss', v_id,
          coalesce(v_row.instance_name, v_st.instance_name), CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
          coalesce(v_why, CASE WHEN v_op = 'end' THEN 'dismissal ended' ELSE 'dismissed: ' || v_reason END), p_payload);
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, CASE WHEN v_op = 'end' THEN 'dismissal ended' ELSE 'dismissed' END),
                            'dismiss_id', v_id);
END $$;

-- ---- history ------------------------------------------------------------------------------------------------------
-- alert_occurrences: per finding key, the channel rows of alert_state grouped into firings: a row whose first send
-- comes after every earlier row of the key has cleared starts a new occurrence. An occurrence is open while any of its
-- rows is open; it ended 'resolved' when a recovery was sent on any channel, else 'closed without a message' (the
-- instance retired, the channel narrowed, recovery off). The history is as long as alert_state keeps cleared rows
-- (purge()'s window).
CREATE OR REPLACE VIEW pgvigil.alert_occurrences AS
WITH r AS (
  SELECT s.*, coalesce(s.cleared_at, 'infinity'::timestamptz) AS end_at FROM pgvigil.alert_state s
), g AS (
  SELECT r.*, CASE WHEN r.first_sent_at > max(r.end_at) OVER (PARTITION BY r.finding_key ORDER BY r.first_sent_at, r.channel
                                                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
                   THEN 1 ELSE 0 END AS brk
    FROM r
), o AS (
  SELECT g.*, 1 + sum(g.brk) OVER (PARTITION BY g.finding_key ORDER BY g.first_sent_at, g.channel) AS occurrence FROM g
)
SELECT o.finding_key, o.occurrence::int AS occurrence, max(o.instance_id) AS instance_id, max(o.instance_name) AS instance,
       (array_agg(o.severity ORDER BY pgvigil.severity_rank(o.severity) DESC))[1] AS severity,
       max(o.source) AS source, max(o.setting) AS setting,
       (array_agg(o.value ORDER BY o.last_sent_at DESC))[1] AS value,
       min(o.first_sent_at) AS fired_at, max(o.last_sent_at) AS last_sent_at,
       CASE WHEN bool_or(o.cleared_at IS NULL) THEN NULL ELSE max(o.cleared_at) END AS cleared_at,
       CASE WHEN bool_or(o.cleared_at IS NULL) THEN 'open'
            WHEN bool_or(o.recovery_sent_at IS NOT NULL) THEN 'resolved'
            ELSE 'closed without a message' END AS status,
       min(o.missing_since) FILTER (WHERE o.cleared_at IS NULL) AS missing_since,
       array_agg(DISTINCT o.channel ORDER BY o.channel) AS channels, sum(o.send_count)::int AS sends
  FROM o
 GROUP BY o.finding_key, o.occurrence;

-- finding_fix: the statement that fixes a finding, NULL when there is none to give (the detail says what to do):
-- a PostgreSQL setting finding (is_set) whose suggested value is one word gets ALTER SYSTEM and the reload (a
-- setting of context postmaster takes a restart besides: the page says so beside the line); a finding whose detail spells out one maintenance statement
-- (REINDEX, CREATE / DROP INDEX, ALTER TABLE / INDEX, VACUUM, ANALYZE) gets that statement.
CREATE OR REPLACE FUNCTION pgvigil.finding_fix(p_engine text, p_setting text, p_is_set boolean, p_suggested text, p_detail text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN coalesce(p_engine, 'postgres') = 'postgres' AND p_is_set IS TRUE
         AND p_setting ~ '^[a-z_][a-z0-9_]*(\.[a-z_][a-z0-9_]*)?$'
         AND p_suggested ~ '^[A-Za-z0-9_.+-]{1,40}$'
      THEN format('ALTER SYSTEM SET %s = %L; SELECT pg_reload_conf();', p_setting, p_suggested)
    -- (no bound over 255 in a PostgreSQL regular expression: the length is cut after the match)
    ELSE left(substring(p_detail FROM '((?:REINDEX|CREATE (?:UNIQUE )?INDEX|DROP INDEX|ALTER (?:TABLE|INDEX)|VACUUM|ANALYZE)\M[^;]+;)'), 1000)
  END
$$;
