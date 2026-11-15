-- 0154_alert_scope: alert routing and scope beyond 310 (task 403a; DBA Dash 4.25.0 N15-N23, PerformanceMonitor 3.13
-- Added 4 / 7 / 9, Changed 18, Release 7; SQLWATCH ENG#3-#7, OVW#137, PBI#3; SQLMonitor A31).
--
--   alert_windows       a blackout, mute or daily-digest window: a scope (one instance | a tag list | the fleet),
--                       weekdays, a daily start and end in an IANA zone (a window across midnight belongs to its start
--                       day), optionally copied from a rule's scope; a digest window has a severity ceiling (info or
--                       warning: a critical is never digest-held). Live row and successor, like alert_rules: an edit
--                       ends the row and writes the next one, so the table is its own history.
--   alert_window_log    every attempt from the UI (done or refused): who, from where, what.
--   alert_held          the sends every hold but 0073's acks held, per hold, channel and alert (first, last, passes,
--                       the newest detail; a digest row's missing_since); ack_suppressed keeps the sends an ack held
--                       first by precedence (an ack mute behind a window blackout is logged under the window).
--                       alert_held_all is the union, the one read behind the 'why held' line and the digest.
--   alert_hold(...)     the ONE hold test, called by alert_mark (here) and alert_due (0190's, a wiring line): the
--                       first hold by precedence - blackout (an ack, then a window) > mute (an ack mute or silence, then
--                       a window) > digest (a window, then the carry-over) > flapping - or NULL.
--   digest_log          one row per channel and digest: sent, failed, refused or empty; digest_due reads it.
--   findings_history    every finding key's open, close and severity change, plus one sample per standing key per hour
--                       (the timeline); monthly partitions, kept 90 days (findings_history_days; the purge line is a
--                       wiring line). No detail is stored: a detail can carry statement text (0029's plan findings).
--
-- Digest holds apply only on a channel that has a daily digest (its digest_hour; the sender passes 'digest'): on any
-- other channel a digest window holds nothing, so no alert is held for a digest that never comes.
-- The digest carry-over: an alert first held by a digest window on a channel, never sent there, stays held after the
-- window ends while it keeps standing. It ends when the finding has been gone for the channel's clear_after
-- (alert_held.missing_since, set by alert_mark as 0059 sets alert_state's) - never because the sender did not look
-- (quiet hours, a back-off, a restart). So the window's end fires nothing, no recovery is ever owed (nothing was sent:
-- there is no alert_state row), and the alert reaches the channel in the digest only. An escalation past the window's
-- ceiling is not held and fires at once.
--
-- Migration order: Migrate applies every missing file in name order, so on a fresh store this file runs BEFORE 0190
-- and on a store already at 0190 after it. Nothing here replaces an object 0190 defines (alert_due, alert_findings,
-- alert_record, purge, ack_rule_matches) and nothing is dropped with CASCADE; a SQL function here names only objects
-- that exist before it runs.
--
-- Writes: pgvigil.import_alert_window(at, payload) through the actions door's audit login (apply_roles makes every
-- import_* SECURITY DEFINER and grants it there), behind the UI login; minimum role operator (B24f). The sender
-- (pgvigil_alerter) writes alert_held, digest_log and findings_history.

-- ---- tag lists (N15 N16 N20): (key1 = a OR key1 = b) AND key2 = c; keys compared case-insensitively -------------

-- alert_tag_key / alert_tag_value: 'key:value' split at the first colon; a bare tag is key '' with its whole text
CREATE OR REPLACE FUNCTION pgvigil.alert_tag_key(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN strpos(p, ':') > 0 THEN lower(btrim(split_part(p, ':', 1))) ELSE '' END
$$;
CREATE OR REPLACE FUNCTION pgvigil.alert_tag_value(p text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN strpos(p, ':') > 0 THEN substr(p, strpos(p, ':') + 1) ELSE p END
$$;

-- alert_scope_norm: a tag list as stored - keys lower-cased, blanks dropped, distinct, sorted (NULL for none)
CREATE OR REPLACE FUNCTION pgvigil.alert_scope_norm(p text[])
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
  SELECT nullif(ARRAY(SELECT DISTINCT CASE WHEN pgvigil.alert_tag_key(t) = '' THEN btrim(t)
                                           ELSE pgvigil.alert_tag_key(t) || ':' || pgvigil.alert_tag_value(t) END
                        FROM unnest(coalesce(p, '{}')) t
                       WHERE btrim(coalesce(t, '')) <> ''
                       ORDER BY 1), '{}')
$$;

-- alert_tags_match: every key of the list is met by one of its values among the instance's tags; an empty list
-- matches nothing (a scope never widens to the fleet by losing its tags)
CREATE OR REPLACE FUNCTION pgvigil.alert_tags_match(p_scope text[], p_tags text[])
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT cardinality(coalesce(p_scope, '{}')) > 0
     AND NOT EXISTS (
       SELECT 1 FROM (SELECT DISTINCT pgvigil.alert_tag_key(s) AS k FROM unnest(p_scope) s) g
        WHERE NOT EXISTS (
          SELECT 1 FROM unnest(p_scope) s, unnest(coalesce(p_tags, '{}')) t
           WHERE pgvigil.alert_tag_key(s) = g.k AND pgvigil.alert_tag_key(t) = g.k
             AND pgvigil.alert_tag_value(t) = pgvigil.alert_tag_value(s)))
$$;

-- ---- windows (N17 N18 N22, PM Added 4, PM Added 7 / Changed 18 / Release 7) ------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.alert_windows (
  window_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name              text CHECK (length(name) BETWEEN 1 AND 100),
  action            text NOT NULL CHECK (action IN ('blackout', 'mute', 'digest')),
  scope             text NOT NULL CHECK (scope IN ('fleet', 'tags', 'instance')),
  scope_tags        text[],
  instance_id       int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  instance_name     text CHECK (length(instance_name) BETWEEN 1 AND 200),   -- the match: a removed instance's window holds nothing
  from_rule_id      bigint,
  weekdays          int[] NOT NULL,          -- ISO: 1 Monday .. 7 Sunday
  start_local       time NOT NULL,
  end_local         time NOT NULL,
  zone              text NOT NULL CHECK (length(zone) BETWEEN 1 AND 64),
  severity_ceiling  text CHECK (severity_ceiling IN ('info', 'warning')),
  starts_at         timestamptz,
  until             timestamptz,
  note              text CHECK (length(note) BETWEEN 1 AND 500),
  replaces          bigint,
  created_by        text NOT NULL,
  created_at        timestamptz NOT NULL,
  client            text,
  ended_by          text,
  ended_at          timestamptz,
  CONSTRAINT "a window's scope names what it holds" CHECK (
    (scope = 'fleet' AND scope_tags IS NULL AND instance_name IS NULL)
    OR (scope = 'tags' AND cardinality(scope_tags) BETWEEN 1 AND 20 AND instance_name IS NULL)
    OR (scope = 'instance' AND scope_tags IS NULL AND instance_name IS NOT NULL)),
  CONSTRAINT "weekdays are 1 to 7, at least one" CHECK (
    cardinality(weekdays) BETWEEN 1 AND 7 AND weekdays <@ ARRAY[1, 2, 3, 4, 5, 6, 7]),
  CONSTRAINT "a window starts and ends at different times" CHECK (start_local <> end_local),
  CONSTRAINT "a window starts before 24:00 (an end of 24:00 is the day's end)" CHECK (start_local < '24:00'),
  CONSTRAINT "a digest window has its ceiling, no other window has one" CHECK (
    (action = 'digest') = (severity_ceiling IS NOT NULL)),
  CONSTRAINT "until is after starts_at" CHECK (until IS NULL OR starts_at IS NULL OR until > starts_at)
);
CREATE INDEX IF NOT EXISTS alert_windows_live_idx ON pgvigil.alert_windows (action) WHERE ended_at IS NULL;
COMMENT ON TABLE pgvigil.alert_windows IS 'Blackout, mute and digest windows from the UI; written through import_alert_window only.';

CREATE TABLE IF NOT EXISTS pgvigil.alert_window_log (
  log_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at         timestamptz NOT NULL,
  ui_user    text NOT NULL,
  client     text,
  op         text,
  window_id  bigint,
  action     text,
  outcome    text NOT NULL CHECK (outcome IN ('done', 'refused')),
  detail     text,
  payload    jsonb
);
CREATE INDEX IF NOT EXISTS alert_window_log_at_idx ON pgvigil.alert_window_log (at DESC);

-- alert_window_open: p_at inside the window's daily span on one of its weekdays, in its zone. A span across midnight
-- belongs to the weekday it starts on. Local time is read with the zone's own rules: on a spring-forward day a span
-- inside the skipped hour never holds, and in the repeated hour of a fall-back day a span holds for both passes of it.
CREATE OR REPLACE FUNCTION pgvigil.alert_window_open(p_at timestamptz, p_weekdays int[], p_start time, p_end time, p_zone text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_start < p_end
              THEN extract(isodow FROM x.l)::int = ANY (p_weekdays) AND x.l::time >= p_start AND x.l::time < p_end
              ELSE (extract(isodow FROM x.l)::int = ANY (p_weekdays) AND x.l::time >= p_start)
                OR (extract(isodow FROM x.l - interval '1 day')::int = ANY (p_weekdays) AND x.l::time < p_end) END
    FROM (SELECT p_at AT TIME ZONE p_zone AS l) x
$$;

-- alert_window_live: the row in force at p_at (not ended, started, not past until) and inside its daily span
CREATE OR REPLACE FUNCTION pgvigil.alert_window_live(w pgvigil.alert_windows, p_at timestamptz)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT w.ended_at IS NULL AND (w.starts_at IS NULL OR w.starts_at <= p_at) AND (w.until IS NULL OR w.until > p_at)
     AND pgvigil.alert_window_open(p_at, w.weekdays, w.start_local, w.end_local, w.zone)
$$;

-- alert_window_matches: a window's scope against one alert. A window never holds a repository-wide alert (source
-- 'pgvigil repository': the collector or the repository itself) - a held one would hide that pgvigil cannot see.
CREATE OR REPLACE FUNCTION pgvigil.alert_window_matches(w pgvigil.alert_windows, p_instance text, p_tags text[], p_source text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT p_source IS DISTINCT FROM 'pgvigil repository'
     AND CASE w.scope WHEN 'fleet' THEN true
                      WHEN 'tags' THEN pgvigil.alert_tags_match(w.scope_tags, p_tags)
                      ELSE w.instance_name = p_instance END
$$;

-- alert_checks_match: a channel's checks: list (SQLMonitor A31; lower-cased by the sender) against one finding - its
-- source or setting, case-insensitively (the mutes' check match, 0073); an empty list takes every finding. alert_mark
-- uses it here, alert_due through the wiring line.
CREATE OR REPLACE FUNCTION pgvigil.alert_checks_match(p_checks text[], p_source text, p_setting text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT cardinality(coalesce(p_checks, '{}')) = 0
      OR lower(coalesce(p_source, '')) = ANY (p_checks) OR lower(coalesce(p_setting, '')) = ANY (p_checks)
$$;

-- ---- the held-sends log and the one hold test ---------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.alert_held (
  hold_kind      text NOT NULL CHECK (hold_kind IN ('blackout', 'mute', 'digest', 'flapping')),
  hold_id        bigint NOT NULL,           -- the window (blackout, mute, digest) or the rule (flapping)
  channel        text NOT NULL,
  finding_key    text NOT NULL,
  instance_id    int,
  instance_name  text,
  severity       text,
  source         text,
  setting        text,
  value          text,
  detail         text,                      -- the newest detail, as the alert's own message would carry it
  missing_since  timestamptz,               -- a digest row: the first pass that no longer saw its finding (the carry-over)
  first_at       timestamptz NOT NULL,
  last_at        timestamptz NOT NULL,
  passes         int NOT NULL DEFAULT 1,
  PRIMARY KEY (hold_kind, hold_id, channel, finding_key)
);
CREATE INDEX IF NOT EXISTS alert_held_last_idx ON pgvigil.alert_held (last_at DESC);
CREATE INDEX IF NOT EXISTS alert_held_digest_idx ON pgvigil.alert_held (channel, finding_key, last_at DESC) WHERE hold_kind = 'digest';
GRANT SELECT, INSERT, UPDATE ON pgvigil.alert_held TO pgvigil_alerter;

-- alert_held_all: every held send, the ack kinds (ack_suppressed, the ack's own kind) and the rest (alert_held)
CREATE OR REPLACE VIEW pgvigil.alert_held_all AS
SELECT a.kind AS hold_kind, s.ack_id AS hold_id, 'ack' AS hold_source, s.channel, s.finding_key, s.instance_id,
       s.instance_name, s.severity, s.source, s.setting, s.value, NULL::text AS detail, s.first_at, s.last_at, s.passes
  FROM pgvigil.ack_suppressed s JOIN pgvigil.acks a USING (ack_id)
UNION ALL
SELECT h.hold_kind, h.hold_id, CASE WHEN h.hold_kind = 'flapping' THEN 'rule' ELSE 'window' END, h.channel, h.finding_key,
       h.instance_id, h.instance_name, h.severity, h.source, h.setting, h.value, h.detail, h.first_at, h.last_at, h.passes
  FROM pgvigil.alert_held h;

DO $$
BEGIN
  IF to_regtype('pgvigil.alert_hold_t') IS NULL THEN
    CREATE TYPE pgvigil.alert_hold_t AS (kind text, hold_id bigint, via text);   -- via: 'ack' | 'window' | 'carry' | 'rule'
  END IF;
END $$;

-- alert_hold (the one hold test) is defined after the rules part below: its flapping hold reads alert_rule_findings'
-- mark. alert_mark is plpgsql and calls it at run time only.

-- alert_mark: 0073's, with every hold through alert_hold - per open row of the given channels missing_since is the
-- first pass that no longer saw its finding, NULL again when it is back; then each held send of each channel is
-- logged: the ack kinds to ack_suppressed (unchanged), every other hold to alert_held with the newest detail.
CREATE OR REPLACE FUNCTION pgvigil.alert_mark(p_at timestamptz, p_channels jsonb)
RETURNS void LANGUAGE plpgsql SET jit = off AS $$
DECLARE
  v_names text[] := ARRAY(SELECT e->>'name' FROM jsonb_array_elements(coalesce(p_channels, '[]'::jsonb)) e);
BEGIN
  UPDATE pgvigil.alert_state s SET missing_since = p_at
   WHERE s.cleared_at IS NULL AND s.missing_since IS NULL AND s.channel = ANY (v_names)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = s.finding_key);
  UPDATE pgvigil.alert_state s SET missing_since = NULL
   WHERE s.cleared_at IS NULL AND s.missing_since IS NOT NULL AND s.channel = ANY (v_names)
     AND EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = s.finding_key);
  -- the carry-over's clock: a digest row whose finding is gone is marked at the first pass that no longer sees it
  UPDATE pgvigil.alert_held d SET missing_since = p_at
   WHERE d.hold_kind = 'digest' AND d.missing_since IS NULL AND d.channel = ANY (v_names)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = d.finding_key);

  WITH h AS MATERIALIZED (
    SELECT x.channel, x.finding_key, x.instance_id, x.instance, x.severity, x.source, x.setting, x.value, x.detail,
           (x.hold).kind AS kind, (x.hold).hold_id AS hold_id, (x.hold).via AS via
      FROM (SELECT DISTINCT ON (c.name, f.finding_key) c.name AS channel, f.finding_key, f.instance_id, f.instance,
                   f.severity, f.source, f.setting, f.value, f.detail,
                   pgvigil.alert_hold(p_at, c.name, f.instance, f.tags, f.finding_key, f.source, f.setting, f.value,
                                      f.severity, c.clear_after_secs, coalesce(c.digest, false)) AS hold
              FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
                   AS c(name text, min_severity text, instances text[], tags text[], clear_after_secs int, checks text[],
                        digest boolean)
              JOIN pgvigil.alert_findings f ON pgvigil.alert_in_scope(f.instance, f.tags, coalesce(c.instances, '{}'), coalesce(c.tags, '{}'))
             WHERE pgvigil.severity_rank(f.severity) >= pgvigil.severity_rank(c.min_severity)
               AND pgvigil.alert_checks_match(c.checks, f.source, f.setting)
             ORDER BY c.name, f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC) x
     WHERE x.hold IS NOT NULL
  ), a AS (
    INSERT INTO pgvigil.ack_suppressed AS s (ack_id, channel, finding_key, instance_id, instance_name, severity, source,
                                             setting, value, first_at, last_at, passes)
    SELECT h.hold_id, h.channel, h.finding_key, h.instance_id, h.instance, h.severity, h.source, h.setting, h.value, p_at, p_at, 1
      FROM h WHERE h.via = 'ack'
    ON CONFLICT (ack_id, channel, finding_key) DO UPDATE SET last_at = EXCLUDED.last_at, passes = s.passes + 1,
      severity = EXCLUDED.severity, value = EXCLUDED.value
  )
  INSERT INTO pgvigil.alert_held AS y (hold_kind, hold_id, channel, finding_key, instance_id, instance_name, severity,
                                       source, setting, value, detail, first_at, last_at, passes)
  SELECT h.kind, h.hold_id, h.channel, h.finding_key, h.instance_id, h.instance, h.severity, h.source, h.setting,
         h.value, h.detail, p_at, p_at, 1
    FROM h WHERE h.via <> 'ack'
  ON CONFLICT (hold_kind, hold_id, channel, finding_key) DO UPDATE SET last_at = EXCLUDED.last_at,
    passes = y.passes + 1, severity = EXCLUDED.severity, value = EXCLUDED.value, detail = EXCLUDED.detail,
    missing_since = NULL;
END $$;

-- import_alert_window: one attempt from the UI (the actions door's audit login; minimum role operator, B24f).
-- p_payload: {op: add|edit|end, ui_user, client; add / edit: name, action, scope, scope_tags, instance_id,
-- instance_name, from_rule_id, weekdays, start_local, end_local, zone, severity_ceiling, starts_at, until, note;
-- edit / end: window_id}. An edit ends the row and writes its successor (replaces). from_rule_id with no scope given
-- copies the live rule's scope. Every attempt leaves an alert_window_log row; a refused one changes nothing else.
-- Returns {outcome, detail, window_id}.
CREATE OR REPLACE FUNCTION pgvigil.import_alert_window(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_action  text := nullif(p_payload->>'action', '');
  v_scope   text := nullif(p_payload->>'scope', '');
  v_tags    text[];
  v_inst    text := nullif(btrim(coalesce(p_payload->>'instance_name', '')), '');
  v_zone    text := nullif(btrim(coalesce(p_payload->>'zone', '')), '');
  v_ceiling text := nullif(p_payload->>'severity_ceiling', '');
  v_rule    bigint;
  v_old     pgvigil.alert_windows;
  v_id      bigint;
  v_new     bigint;
  v_why     text;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_alert_window: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IN ('edit', 'end') THEN
    IF coalesce(p_payload->>'window_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'window_id')::bigint;
      SELECT * INTO v_old FROM pgvigil.alert_windows WHERE window_id = v_id FOR UPDATE;
    END IF;
    IF v_id IS NULL THEN
      v_why := format('window_id %L is not a window id', p_payload->>'window_id');
    ELSIF v_old.window_id IS NULL THEN
      v_why := format('no window %s', v_id);
    ELSIF v_old.ended_at IS NOT NULL THEN
      v_why := format('window %s was already ended by %s at %s', v_id, v_old.ended_by, v_old.ended_at);
    END IF;
  ELSIF v_op IS DISTINCT FROM 'add' THEN
    v_why := 'op must be add, edit or end';
  END IF;

  IF v_why IS NULL AND v_op IN ('add', 'edit') THEN
    IF jsonb_typeof(p_payload->'scope_tags') = 'array' THEN
      v_tags := pgvigil.alert_scope_norm(ARRAY(SELECT jsonb_array_elements_text(p_payload->'scope_tags')));
    END IF;
    IF coalesce(p_payload->>'from_rule_id', '') ~ '^[0-9]{1,18}$' THEN
      v_rule := (p_payload->>'from_rule_id')::bigint;
      IF v_scope IS NULL THEN        -- the rule's scope, copied
        SELECT CASE r.scope WHEN 'tag' THEN 'tags' ELSE r.scope END,
               CASE r.scope WHEN 'tag' THEN pgvigil.alert_scope_norm(ARRAY[r.tag]) WHEN 'tags' THEN r.scope_tags END, r.instance_name
          INTO v_scope, v_tags, v_inst
          FROM pgvigil.alert_rules r WHERE r.rule_id = v_rule AND r.ended_at IS NULL;
        IF v_scope IS NULL THEN
          v_why := format('no live rule %s to copy the scope of', v_rule);
        END IF;
      END IF;
    END IF;
  END IF;
  IF v_why IS NULL AND v_op IN ('add', 'edit') THEN
    IF v_action IS NULL OR v_action NOT IN ('blackout', 'mute', 'digest') THEN
      v_why := format('no such action %L (blackout, mute or digest)', v_action);
    ELSIF v_scope IS NULL OR v_scope NOT IN ('fleet', 'tags', 'instance') THEN
      v_why := format('no such scope %L (fleet, tags or instance)', v_scope);
    ELSIF v_scope = 'tags' AND v_tags IS NULL THEN
      v_why := 'a tags scope names at least one tag';
    ELSIF v_scope = 'instance' AND v_inst IS NULL THEN
      v_why := 'an instance scope names its instance';
    ELSIF v_zone IS NULL OR NOT EXISTS (SELECT 1 FROM pg_timezone_names z WHERE z.name = v_zone) THEN
      v_why := format('%L is not a time zone this server knows (an IANA name, e.g. America/Chicago)', v_zone);
    ELSIF v_action = 'digest' AND coalesce(v_ceiling, 'warning') NOT IN ('info', 'warning') THEN
      v_why := 'a digest window holds info or warning alerts only: a critical always pages at once';
    ELSIF NOT pgvigil.ack_time_ok(p_payload->>'until') OR NOT pgvigil.ack_time_ok(p_payload->>'starts_at') THEN
      v_why := 'until / starts_at is not a timestamp';
    ELSIF (p_payload->>'until') IS NOT NULL AND (p_payload->>'until')::timestamptz <= p_at THEN
      v_why := 'until is not in the future';
    END IF;
  END IF;

  IF v_why IS NULL THEN
    BEGIN
      IF v_op IN ('edit', 'end') THEN
        UPDATE pgvigil.alert_windows SET ended_by = v_user, ended_at = p_at WHERE window_id = v_id;
      END IF;
      IF v_op IN ('add', 'edit') THEN
        INSERT INTO pgvigil.alert_windows (name, action, scope, scope_tags, instance_id, instance_name, from_rule_id,
                                           weekdays, start_local, end_local, zone, severity_ceiling, starts_at, until,
                                           note, replaces, created_by, created_at, client)
        SELECT nullif(btrim(coalesce(x.name, '')), ''), v_action, v_scope, CASE WHEN v_scope = 'tags' THEN v_tags END,
               CASE WHEN v_scope = 'instance' THEN (SELECT i.instance_id FROM pgvigil.instances i WHERE i.name = v_inst) END,
               CASE WHEN v_scope = 'instance' THEN v_inst END, v_rule,
               ARRAY(SELECT DISTINCT d::int FROM jsonb_array_elements_text(coalesce(p_payload->'weekdays', '[]'::jsonb)) d ORDER BY 1),
               x.start_local, x.end_local, v_zone,
               CASE WHEN v_action = 'digest' THEN coalesce(v_ceiling, 'warning') END,
               x.starts_at, x.until, nullif(btrim(coalesce(x.note, '')), ''),
               CASE WHEN v_op = 'edit' THEN v_id END, v_user, p_at, v_client
          FROM jsonb_to_record(p_payload) AS x(name text, start_local time, end_local time, starts_at timestamptz,
                                               until timestamptz, note text)
        RETURNING window_id INTO v_new;
      END IF;
    EXCEPTION WHEN check_violation OR not_null_violation OR foreign_key_violation OR invalid_text_representation
                   OR invalid_datetime_format OR datetime_field_overflow OR numeric_value_out_of_range
                   OR string_data_right_truncation THEN
      v_why := 'refused by the store: ' || SQLERRM;
      v_new := NULL;
    END;
  END IF;
  INSERT INTO pgvigil.alert_window_log (at, ui_user, client, op, window_id, action, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, v_op, coalesce(v_new, v_id), coalesce(v_action, v_old.action),
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
          coalesce(v_why, CASE v_op WHEN 'end' THEN 'ended' WHEN 'edit' THEN 'edited' ELSE 'added' END), p_payload);
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, CASE v_op WHEN 'end' THEN 'ended' WHEN 'edit' THEN 'edited' ELSE 'added' END),
                            'window_id', coalesce(v_new, v_id));
END $$;

-- ---- the daily digest (PM Added 7, Changed 18, Release 7) ---------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.digest_log (
  channel     text NOT NULL,
  at          timestamptz NOT NULL,          -- the attempt
  due_at      timestamptz NOT NULL,          -- the digest hour it answers, as an instant
  since       timestamptz NOT NULL,          -- what it carried: held alerts seen after this
  outcome     text NOT NULL CHECK (outcome IN ('sent', 'failed', 'refused', 'empty')),
  groups      int NOT NULL DEFAULT 0,
  alerts      int NOT NULL DEFAULT 0,
  error       text CHECK (length(error) <= 2000),
  PRIMARY KEY (channel, at)
);
GRANT SELECT, INSERT ON pgvigil.digest_log TO pgvigil_alerter;

-- digest_hour_at: today's digest hour of a zone as an instant, or yesterday's when today's is still ahead. A local
-- hour the zone skips (a spring-forward day) is read as the zone's rules give it (the hour after).
CREATE OR REPLACE FUNCTION pgvigil.digest_hour_at(p_at timestamptz, p_hour int, p_zone text)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN t.h <= p_at THEN t.h
              ELSE (date_trunc('day', p_at AT TIME ZONE p_zone) - interval '1 day' + make_interval(hours => p_hour)) AT TIME ZONE p_zone END
    FROM (SELECT (date_trunc('day', p_at AT TIME ZONE p_zone) + make_interval(hours => p_hour)) AT TIME ZONE p_zone AS h) t
$$;

-- digest_due: the channels owed a digest at p_at. p_channels: [{name, digest_hour 0-23, timezone}] (a channel with no
-- digest_hour has none; a route channel 'contact-<id>' carries its base's, routes.go's copy). Owed when the newest
-- digest hour at or before p_at has no sent, refused or empty digest since it: a failed one is owed again on the
-- next pass (the pass's own back-off and cap apply), and a missed hour (pgvigil down) is owed once, carrying
-- everything since the last digest (at most 7 days back).
CREATE OR REPLACE FUNCTION pgvigil.digest_due(p_at timestamptz, p_channels jsonb)
RETURNS TABLE (channel text, due_at timestamptz, since timestamptz)
LANGUAGE sql STABLE AS $$
  SELECT c.name, d.due_at,
         greatest(coalesce((SELECT max(l.at) FROM pgvigil.digest_log l
                             WHERE l.channel = c.name AND l.outcome IN ('sent', 'empty')), p_at - interval '7 days'),
                  p_at - interval '7 days')
    FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb)) AS c(name text, digest_hour int, timezone text)
    CROSS JOIN LATERAL (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_timezone_names z WHERE z.name = coalesce(nullif(c.timezone, ''), 'UTC'))
                                    THEN pgvigil.digest_hour_at(p_at, c.digest_hour, coalesce(nullif(c.timezone, ''), 'UTC')) END AS due_at) d
   WHERE c.digest_hour BETWEEN 0 AND 23 AND d.due_at IS NOT NULL   -- a zone this server does not know: that channel only waits
     AND NOT EXISTS (SELECT 1 FROM pgvigil.digest_log l
                      WHERE l.channel = c.name AND l.at >= d.due_at AND l.outcome IN ('sent', 'refused', 'empty'))
$$;

-- digest_items: what one channel's digest carries - the alerts a digest window held on it (and the carry-over) seen
-- after p_since, grouped by instance and check: how many alerts, the first and last time held, the highest severity
-- and the newest detail (the detail the alert's own message would have carried).
CREATE OR REPLACE FUNCTION pgvigil.digest_items(p_channel text, p_since timestamptz, p_until timestamptz)
RETURNS TABLE (instance text, check_name text, alerts bigint, first_at timestamptz, last_at timestamptz, severity text,
               detail text)
LANGUAGE sql STABLE AS $$
  SELECT coalesce(h.instance_name, 'pgvigil'), coalesce(h.source, '') || coalesce(': ' || h.setting, ''),
         count(DISTINCT h.finding_key), min(h.first_at), max(h.last_at),
         (array_agg(h.severity ORDER BY pgvigil.severity_rank(h.severity) DESC))[1],
         (array_agg(h.detail ORDER BY h.last_at DESC))[1]
    FROM pgvigil.alert_held h
   WHERE h.hold_kind = 'digest' AND h.channel = p_channel AND h.last_at > p_since AND h.last_at <= p_until
   GROUP BY 1, 2
   ORDER BY max(pgvigil.severity_rank(h.severity)) DESC, 1, 2
$$;

-- digest_record: the attempt of one channel's digest
CREATE OR REPLACE FUNCTION pgvigil.digest_record(p_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.digest_log (channel, at, due_at, since, outcome, groups, alerts, error)
  SELECT x.channel, p_at, x.due_at, x.since, x.outcome, coalesce(x.groups, 0), coalesce(x.alerts, 0), left(x.error, 2000)
    FROM jsonb_to_record(p_payload) AS x(channel text, due_at timestamptz, since timestamptz, outcome text, groups int,
                                         alerts int, error text)
  ON CONFLICT (channel, at) DO NOTHING
$$;

-- ---- the findings history (ENG#7, OVW#137, PBI#3) -----------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgvigil.findings_history (
  snapshot_at    timestamptz NOT NULL,      -- the pass (ensure_month_partition and purge read this name)
  finding_key    text NOT NULL,
  instance_id    int,
  instance_name  text,
  source         text,
  setting        text,
  value          text,
  event          text NOT NULL CHECK (event IN ('open', 'close', 'severity', 'sample')),
  severity       text,
  metric_value   double precision           -- a rule finding's newest sample (the timeline's line), else NULL
) PARTITION BY RANGE (snapshot_at);   -- each month's partition gets (instance_id, snapshot_at) from ensure_month_partition
GRANT SELECT, INSERT ON pgvigil.findings_history TO pgvigil_alerter;

-- the standing set the history compares each pass with (one row per standing finding key)
CREATE TABLE IF NOT EXISTS pgvigil.findings_history_last (
  finding_key    text PRIMARY KEY,
  instance_id    int,                       -- kept for the close row (the instance's timeline filters on it)
  instance_name  text,
  source         text,
  setting        text,
  value          text,
  severity       text,
  opened_at      timestamptz NOT NULL,
  sampled_at     timestamptz NOT NULL
);
GRANT SELECT, INSERT, UPDATE, DELETE ON pgvigil.findings_history_last TO pgvigil_alerter;

-- findings_history_days: how long the history is kept (purge's wiring line reads it)
CREATE OR REPLACE FUNCTION pgvigil.findings_history_days()
RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 90 $$;

-- findings_history_partition: the owner's door for the history's month partition, for a time within a day of now()
-- only, the sender's or the owner's session only (alert_log_partition's rule)
CREATE OR REPLACE FUNCTION pgvigil.findings_history_partition(p_at timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
BEGIN
  IF NOT (pg_has_role(session_user, 'pgvigil_alerter', 'MEMBER')
          OR pg_has_role(session_user, (SELECT n.nspowner FROM pg_namespace n WHERE n.nspname = 'pgvigil'), 'MEMBER')) THEN
    RAISE EXCEPTION 'findings_history_partition: % is not the alert sender', session_user USING ERRCODE = '42501';
  END IF;
  IF p_at IS NULL OR p_at < now() - interval '1 day' OR p_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'findings_history_partition: % is not within a day of now()', p_at;
  END IF;
  PERFORM pgvigil.ensure_month_partition('findings_history', p_at);
END $$;
GRANT EXECUTE ON FUNCTION pgvigil.findings_history_partition(timestamptz) TO pgvigil_alerter;

-- findings_history_run: one pass of the history, called by the sender every pass. A row on a change only - a key
-- that opened, closed or changed severity - and one 'sample' row per standing key when its last one is an hour old.
-- Returns the rows written.
CREATE OR REPLACE FUNCTION pgvigil.findings_history_run(p_at timestamptz)
RETURNS int LANGUAGE plpgsql SET jit = off AS $$
DECLARE
  n int;
BEGIN
  IF to_regclass('pgvigil.findings_history_' || to_char(date_trunc('month', p_at AT TIME ZONE 'UTC'), 'YYYYMM')) IS NULL THEN
    PERFORM pgvigil.findings_history_partition(p_at);
  END IF;
  WITH cur AS MATERIALIZED (
    SELECT DISTINCT ON (f.finding_key) f.finding_key, f.instance_id, f.instance, f.source, f.setting, f.value, f.severity,
           y.metric_value
      FROM pgvigil.alert_findings f
      LEFT JOIN pgvigil.alert_rule_findings y      -- a rule finding's newest sample (alert_rule_findings, below)
        ON f.source = 'alert rule' AND y.instance_id = f.instance_id AND y.setting = f.setting AND y.value = f.value
     ORDER BY f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC
  ), ev AS (
    SELECT c.finding_key, c.instance_id, c.instance, c.source, c.setting, c.value, c.severity, c.metric_value,
           CASE WHEN l.finding_key IS NULL THEN 'open'
                WHEN l.severity IS DISTINCT FROM c.severity THEN 'severity'
                WHEN l.sampled_at <= p_at - interval '1 hour' THEN 'sample' END AS event
      FROM cur c LEFT JOIN pgvigil.findings_history_last l USING (finding_key)
    UNION ALL
    SELECT l.finding_key, l.instance_id, l.instance_name, l.source, l.setting, l.value, l.severity, NULL, 'close'
      FROM pgvigil.findings_history_last l
     WHERE NOT EXISTS (SELECT 1 FROM cur c WHERE c.finding_key = l.finding_key)
  ), w AS (
    INSERT INTO pgvigil.findings_history (snapshot_at, finding_key, instance_id, instance_name, source, setting, value, event,
                                          severity, metric_value)
    SELECT p_at, ev.finding_key, ev.instance_id, ev.instance, ev.source, ev.setting, ev.value, ev.event, ev.severity,
           ev.metric_value
      FROM ev WHERE ev.event IS NOT NULL
    RETURNING 1
  ), d AS (
    DELETE FROM pgvigil.findings_history_last l
     WHERE NOT EXISTS (SELECT 1 FROM cur c WHERE c.finding_key = l.finding_key)
  ), u AS (
    INSERT INTO pgvigil.findings_history_last AS l (finding_key, instance_id, instance_name, source, setting, value, severity,
                                                    opened_at, sampled_at)
    SELECT ev.finding_key, ev.instance_id, ev.instance, ev.source, ev.setting, ev.value, ev.severity, p_at, p_at
      FROM ev WHERE ev.event IN ('open', 'severity', 'sample')
    ON CONFLICT (finding_key) DO UPDATE SET severity = EXCLUDED.severity, sampled_at = EXCLUDED.sampled_at,
      instance_id = EXCLUDED.instance_id, instance_name = EXCLUDED.instance_name
  )
  SELECT count(*) INTO n FROM w;
  RETURN n;
END $$;

-- ---- rules: tag lists, operator families, the baseline, flapping (N15 N16 N20 N23, ENG#3 #4 #5) -----------------
-- A rule's op is above | below (the threshold family, 0085's), rises (ENG#3: the rise between two samples beyond the
-- value) or above_baseline (ENG#5: above the same local hour's baseline widened by band_pct AND above the rule's own
-- value - SQLWATCH's relaxed mode). One live rule per metric, scope, series AND family: rules of different families
-- on one metric coexist. A threshold rule's alert keeps its key (its value text is 0085's, word for word).

ALTER TABLE pgvigil.alert_rules ADD COLUMN IF NOT EXISTS scope_tags text[];
ALTER TABLE pgvigil.alert_rules ADD COLUMN IF NOT EXISTS band_pct double precision;
ALTER TABLE pgvigil.alert_rules ADD COLUMN IF NOT EXISTS zone text;
ALTER TABLE pgvigil.alert_rules ADD COLUMN IF NOT EXISTS ignore_flapping boolean NOT NULL DEFAULT false;
ALTER TABLE pgvigil.alert_rules ADD COLUMN IF NOT EXISTS op_family text
  GENERATED ALWAYS AS (CASE op WHEN 'rises' THEN 'rise' WHEN 'above_baseline' THEN 'baseline' ELSE 'threshold' END) STORED;
ALTER TABLE pgvigil.alert_rules DROP CONSTRAINT IF EXISTS alert_rules_op_check;
ALTER TABLE pgvigil.alert_rules ADD CONSTRAINT alert_rules_op_check CHECK (op IN ('above', 'below', 'rises', 'above_baseline'));
ALTER TABLE pgvigil.alert_rules DROP CONSTRAINT IF EXISTS alert_rules_scope_check;
ALTER TABLE pgvigil.alert_rules ADD CONSTRAINT alert_rules_scope_check CHECK (scope IN ('fleet', 'tag', 'tags', 'instance'));
ALTER TABLE pgvigil.alert_rules DROP CONSTRAINT IF EXISTS "critical is at or beyond warning";
ALTER TABLE pgvigil.alert_rules ADD CONSTRAINT "critical is at or beyond warning" CHECK (
  warning IS NULL OR critical IS NULL OR (op <> 'below' AND critical >= warning) OR (op = 'below' AND critical <= warning));
ALTER TABLE pgvigil.alert_rules DROP CONSTRAINT IF EXISTS "a tag rule names its tag, an instance rule its instance";
ALTER TABLE pgvigil.alert_rules ADD CONSTRAINT "a tag rule names its tag, an instance rule its instance" CHECK (
  (scope = 'fleet' AND tag IS NULL AND instance_name IS NULL AND scope_tags IS NULL)
  OR (scope = 'tag' AND tag IS NOT NULL AND instance_name IS NULL AND scope_tags IS NULL)
  OR (scope = 'tags' AND tag IS NULL AND instance_name IS NULL AND cardinality(scope_tags) BETWEEN 1 AND 20)
  OR (scope = 'instance' AND tag IS NULL AND instance_name IS NOT NULL AND scope_tags IS NULL));
ALTER TABLE pgvigil.alert_rules DROP CONSTRAINT IF EXISTS "a baseline rule has its band and zone";
ALTER TABLE pgvigil.alert_rules ADD CONSTRAINT "a baseline rule has its band and zone" CHECK (
  op <> 'above_baseline' OR (band_pct BETWEEN 0 AND 1000 AND zone IS NOT NULL AND length(zone) <= 64));

-- one live rule per metric, scope, series and family (0085's index had no family: a second family replaced the first)
DROP INDEX IF EXISTS pgvigil.alert_rules_live_uq;
CREATE UNIQUE INDEX IF NOT EXISTS alert_rules_live_family_uq ON pgvigil.alert_rules
  (metric, scope, coalesce(tag, ''), coalesce(scope_tags, '{}'::text[]), coalesce(instance_name, ''), coalesce(database, ''), op_family)
  WHERE ended_at IS NULL;

-- alert_scope_text: a tag list as a reader says it - '(env:prod OR env:stage) AND app:billing'
CREATE OR REPLACE FUNCTION pgvigil.alert_scope_text(p text[])
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT string_agg(g.t, ' AND ' ORDER BY g.k)
    FROM (SELECT pgvigil.alert_tag_key(x) AS k,
                 CASE WHEN count(*) > 1 THEN '(' || string_agg(x, ' OR ' ORDER BY x) || ')' ELSE min(x) END AS t
            FROM unnest(coalesce(p, '{}')) x GROUP BY 1) g
$$;

-- alert_rule_scope: 0085's, with the tag list (alert_tags_match) and the new columns at the end
CREATE OR REPLACE VIEW pgvigil.alert_rule_scope AS
SELECT r.rule_id, r.name, r.metric, r.op, r.warning, r.critical, r.for_minutes, r.scope, r.tag, r.instance_name, r.database,
       i.instance_id, i.name AS instance,
       CASE r.scope WHEN 'instance' THEN 3 WHEN 'fleet' THEN 1 ELSE 2 END AS level,
       r.op_family, r.scope_tags,
       CASE r.scope WHEN 'tags' THEN (SELECT count(DISTINCT pgvigil.alert_tag_key(x))::int FROM unnest(r.scope_tags) x)
                    WHEN 'tag' THEN 1 ELSE 0 END AS terms,
       r.band_pct, r.zone, r.ignore_flapping
  FROM pgvigil.alert_rules r
  JOIN pgvigil.metric_catalog c ON c.key = r.metric
  JOIN pgvigil.instances i ON i.is_active AND c.engine IN (i.engine, 'any')
  LEFT JOIN pgvigil.instance_tags_merged t ON t.instance_id = i.instance_id
 WHERE r.ended_at IS NULL AND r.enabled
   AND (c.per_database OR r.database IS NULL)
   AND (r.scope = 'fleet' OR (r.scope = 'instance' AND r.instance_name = i.name)
        OR (r.scope = 'tag' AND r.tag = ANY (coalesce(t.tags, '{}'::text[])))
        OR (r.scope = 'tags' AND pgvigil.alert_tags_match(r.scope_tags, t.tags)));

-- alert_rules_effective: the rule in force per instance, metric, series AND family. Precedence within a family: an
-- instance's rule over a tag rule's over the fleet's; between two tag rules, the one with more AND terms; then the
-- newer rule.
CREATE OR REPLACE VIEW pgvigil.alert_rules_effective AS
SELECT DISTINCT ON (s.instance_id, s.metric, coalesce(s.database, ''), s.op_family) s.*
  FROM pgvigil.alert_rule_scope s
 ORDER BY s.instance_id, s.metric, coalesce(s.database, ''), s.op_family, s.level DESC, s.terms DESC, s.rule_id DESC;

-- alert_rule_overrides: per live rule, the rule of its family in force instead of it on some of its instances, and on
-- how many (the editor's 'overrides <rule> on N instances' and 'overridden on N instances by <rule>')
CREATE OR REPLACE VIEW pgvigil.alert_rule_overrides AS
SELECT s.rule_id, e.rule_id AS by_rule_id, count(*) AS instances
  FROM pgvigil.alert_rule_scope s
  JOIN pgvigil.alert_rules_effective e
    ON e.instance_id = s.instance_id AND e.metric = s.metric AND coalesce(e.database, '') = coalesce(s.database, '')
   AND e.op_family = s.op_family AND e.rule_id <> s.rule_id
 GROUP BY s.rule_id, e.rule_id;

-- metric_rule: 0085's, the threshold family only (the Metrics grid colours a figure by its threshold rule)
CREATE OR REPLACE FUNCTION pgvigil.metric_rule(p_instance_id int, p_key text, p_database text DEFAULT NULL)
RETURNS TABLE (rule_id bigint, rule_name text, op text, warning double precision, critical double precision, for_minutes int,
               rule_scope text, rule_target text, rule_database text)
LANGUAGE sql STABLE AS $$
  SELECT e.rule_id, e.name, e.op, e.warning, e.critical, e.for_minutes, e.scope,
         coalesce(e.tag, e.instance_name, pgvigil.alert_scope_text(e.scope_tags)), e.database
    FROM pgvigil.alert_rules_effective e
   WHERE e.instance_id = p_instance_id AND e.metric = p_key AND e.database IS NOT DISTINCT FROM p_database
     AND e.op_family = 'threshold'
$$;

-- the sender's state per series and family, with the flapping ring (the last 12 judged levels within 6 h, newest
-- last) and its mark, and the baseline the row was judged against
ALTER TABLE pgvigil.alert_rule_state ADD COLUMN IF NOT EXISTS op_family text NOT NULL DEFAULT 'threshold';
ALTER TABLE pgvigil.alert_rule_state ADD COLUMN IF NOT EXISTS results text[] NOT NULL DEFAULT '{}';
ALTER TABLE pgvigil.alert_rule_state ADD COLUMN IF NOT EXISTS result_at timestamptz[] NOT NULL DEFAULT '{}';
ALTER TABLE pgvigil.alert_rule_state ADD COLUMN IF NOT EXISTS flapping_since timestamptz;
ALTER TABLE pgvigil.alert_rule_state ADD COLUMN IF NOT EXISTS baseline double precision;
ALTER TABLE pgvigil.alert_rule_state ADD COLUMN IF NOT EXISTS baseline_days int;
ALTER TABLE pgvigil.alert_rule_state DROP CONSTRAINT IF EXISTS alert_rule_state_pkey;
ALTER TABLE pgvigil.alert_rule_state ADD CONSTRAINT alert_rule_state_pkey PRIMARY KEY (instance_id, metric, database, op_family);

-- the baseline per baseline rule, instance and series for one local hour: the average of the same local hour on
-- each of the last 7 days that has samples (days = how many had); refreshed by the sender when the hour turns
CREATE TABLE IF NOT EXISTS pgvigil.alert_rule_baseline (
  rule_id      bigint NOT NULL,
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  database     text NOT NULL DEFAULT '',
  hour_at      timestamptz NOT NULL,          -- the start of the local hour it is for
  base         double precision,
  days         int NOT NULL,
  PRIMARY KEY (rule_id, instance_id, database)
);
GRANT SELECT, INSERT, UPDATE, DELETE ON pgvigil.alert_rule_baseline TO pgvigil_alerter;

-- alert_rule_hour_at: the start of p_at's local hour in a zone, as an instant (a zone's own rules: the repeated hour
-- of a fall-back day is two hours)
CREATE OR REPLACE FUNCTION pgvigil.alert_rule_hour_at(p_at timestamptz, p_zone text)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
  SELECT date_trunc('hour', p_at AT TIME ZONE p_zone) AT TIME ZONE p_zone
$$;

-- alert_rule_baseline_refresh: the baselines of every baseline rule in force whose stored hour is not p_at's local
-- hour; each of the last 7 days read as that day's same local hour (DST-correct: 09:00 local each day, whatever the
-- UTC offset). Returns the rows refreshed.
CREATE OR REPLACE FUNCTION pgvigil.alert_rule_baseline_refresh(p_at timestamptz)
RETURNS int LANGUAGE plpgsql SET jit = off AS $$
DECLARE
  g     record;
  v_n   int := 0;
  v_sum double precision;
  v_cnt int;
  v_avg double precision;
  v_loc timestamp;
BEGIN
  DELETE FROM pgvigil.alert_rule_baseline b
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.alert_rules_effective e
                      WHERE e.rule_id = b.rule_id AND e.instance_id = b.instance_id AND coalesce(e.database, '') = b.database);
  FOR g IN
    SELECT e.rule_id, e.instance_id, e.database, e.zone, c.family, c.metric AS m,
           pgvigil.alert_rule_hour_at(p_at, e.zone) AS hour_at
      FROM pgvigil.alert_rules_effective e
      JOIN pgvigil.metric_catalog c ON c.key = e.metric
      LEFT JOIN pgvigil.alert_rule_baseline b
        ON b.rule_id = e.rule_id AND b.instance_id = e.instance_id AND b.database = coalesce(e.database, '')
     WHERE e.op_family = 'baseline' AND (b.rule_id IS NULL OR b.hour_at <> pgvigil.alert_rule_hour_at(p_at, e.zone))
  LOOP
    v_sum := 0; v_cnt := 0;
    v_loc := g.hour_at AT TIME ZONE g.zone;
    FOR d IN 1..7 LOOP
      SELECT avg(x.value) INTO v_avg
        FROM pgvigil.metric_points(g.instance_id, g.family, (v_loc - make_interval(days => d)) AT TIME ZONE g.zone,
                                   (v_loc - make_interval(days => d) + interval '1 hour') AT TIME ZONE g.zone,
                                   interval '1 hour', g.database) x
       WHERE x.metric = g.m;
      IF v_avg IS NOT NULL THEN
        v_sum := v_sum + v_avg; v_cnt := v_cnt + 1;
      END IF;
    END LOOP;
    INSERT INTO pgvigil.alert_rule_baseline AS b (rule_id, instance_id, database, hour_at, base, days)
    VALUES (g.rule_id, g.instance_id, coalesce(g.database, ''), g.hour_at, CASE WHEN v_cnt > 0 THEN v_sum / v_cnt END, v_cnt)
    ON CONFLICT (rule_id, instance_id, database) DO UPDATE SET hour_at = EXCLUDED.hour_at, base = EXCLUDED.base, days = EXCLUDED.days;
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- alert_rule_eval: 0085's, per family. The rise family judges each sample's rise from the sample before it (the
-- first sample of the window has none); the baseline family judges the level against the greater of the rule's value
-- and the baseline x (1 + band) once 7 days of the hour are known, else against the rule's value alone (the finding
-- says 'no baseline yet (N of 7 days)'). The family, the baseline and its days ride at the end. Its result type
-- changes, so it is dropped first (no view uses it; alert_rules_run below is its one caller).
DROP FUNCTION IF EXISTS pgvigil.alert_rule_eval(timestamptz);
CREATE FUNCTION pgvigil.alert_rule_eval(p_at timestamptz)
RETURNS TABLE (rule_id bigint, instance_id int, metric text, database text, state text, value double precision,
               threshold double precision, sample_at timestamptz, beyond_since timestamptz,
               crit_beyond boolean, crit_within_at timestamptz, warn_beyond boolean, warn_within_at timestamptz,
               op_family text, baseline double precision, baseline_days int)
LANGUAGE plpgsql STABLE SET jit = off AS $$
#variable_conflict use_column
DECLARE
  g record;
BEGIN
  FOR g IN
    SELECT e.instance_id, c.family, e.database, max(e.for_minutes) AS max_for
      FROM pgvigil.alert_rules_effective e JOIN pgvigil.metric_catalog c ON c.key = e.metric
     GROUP BY e.instance_id, c.family, e.database
  LOOP
    RETURN QUERY
    WITH p0 AS MATERIALIZED (
      SELECT x.at, x.metric, x.value
        FROM pgvigil.metric_points(g.instance_id, g.family, p_at - make_interval(mins => g.max_for + 60), p_at,
                                   interval '1 hour', g.database) x
    ), p AS MATERIALIZED (   -- every sample as a level, and as the rise from the sample before it
      SELECT 'level'::text AS kind, p0.at, p0.metric, p0.value FROM p0
      UNION ALL
      SELECT 'rise'::text, d.at, d.metric, d.value
        FROM (SELECT p0.at, p0.metric, p0.value - lag(p0.value) OVER (PARTITION BY p0.metric ORDER BY p0.at) AS value FROM p0) d
       WHERE d.value IS NOT NULL
    ), lv AS (          -- each rule of this instance, family and series at each level it sets
      SELECT e.rule_id, e.metric AS key, c.metric AS m, CASE e.op WHEN 'below' THEN 'below' ELSE 'above' END AS op,
             CASE e.op_family WHEN 'rise' THEN 'rise' ELSE 'level' END AS kind, e.op_family AS fam,
             e.for_minutes, c.fresh_secs, l.sev,
             CASE WHEN e.op_family = 'baseline' AND b.days = 7 AND b.base IS NOT NULL
                  THEN greatest(l.thr, b.base * (1 + e.band_pct / 100.0)) ELSE l.thr END AS thr,
             CASE WHEN e.op_family = 'baseline' THEN b.base END AS base,
             CASE WHEN e.op_family = 'baseline' THEN coalesce(b.days, 0) END AS base_days
        FROM pgvigil.alert_rules_effective e
        JOIN pgvigil.metric_catalog c ON c.key = e.metric
        LEFT JOIN pgvigil.alert_rule_baseline b
          ON b.rule_id = e.rule_id AND b.instance_id = e.instance_id AND b.database = coalesce(e.database, '')
        CROSS JOIN LATERAL (VALUES ('critical', e.critical), ('warning', e.warning)) AS l(sev, thr)
       WHERE e.instance_id = g.instance_id AND c.family = g.family AND e.database IS NOT DISTINCT FROM g.database
         AND l.thr IS NOT NULL
    ), j AS (
      SELECT lv.*, z.last_at, z.last_value, z.last_within,
             (SELECT min(p2.at) FROM p p2
               WHERE p2.kind = lv.kind AND p2.metric = lv.m AND (z.last_within IS NULL OR p2.at > z.last_within)) AS run_from
        FROM lv
        LEFT JOIN LATERAL (
          SELECT max(p1.at) AS last_at, (array_agg(p1.value ORDER BY p1.at DESC))[1] AS last_value,
                 max(p1.at) FILTER (WHERE NOT pgvigil.alert_beyond(lv.op, p1.value, lv.thr)) AS last_within
            FROM p p1 WHERE p1.kind = lv.kind AND p1.metric = lv.m) z ON true
    ), k AS (
      SELECT j.*,
             (j.last_at IS NOT NULL AND p_at - j.last_at <= make_interval(secs => j.fresh_secs)) AS fresh,
             (j.run_from IS NOT NULL AND j.last_at - j.run_from >= make_interval(mins => j.for_minutes)) AS long_enough
        FROM j
    ), x AS (
      SELECT k.rule_id, k.key, k.fam,
             CASE WHEN NOT bool_or(k.fresh) THEN 'nodata'
                  WHEN bool_or(k.fresh AND k.long_enough) FILTER (WHERE k.sev = 'critical') THEN 'critical'
                  WHEN bool_or(k.fresh AND k.long_enough) FILTER (WHERE k.sev = 'warning') THEN 'warning'
                  WHEN bool_or(k.run_from IS NOT NULL) THEN 'pending'
                  ELSE 'ok' END AS st,
             max(k.last_value) AS last_value, max(k.last_at) AS last_at,
             max(k.thr) FILTER (WHERE k.sev = 'critical') AS crit_thr, max(k.thr) FILTER (WHERE k.sev = 'warning') AS warn_thr,
             min(k.run_from) FILTER (WHERE k.sev = 'critical') AS crit_from, min(k.run_from) FILTER (WHERE k.sev = 'warning') AS warn_from,
             bool_or(k.run_from IS NOT NULL) FILTER (WHERE k.sev = 'critical') AS crit_run,
             max(k.last_within) FILTER (WHERE k.sev = 'critical') AS crit_in,
             bool_or(k.run_from IS NOT NULL) FILTER (WHERE k.sev = 'warning') AS warn_run,
             max(k.last_within) FILTER (WHERE k.sev = 'warning') AS warn_in,
             max(k.base) AS base, max(k.base_days) AS base_days
        FROM k
       GROUP BY k.rule_id, k.key, k.fam
    )
    SELECT x.rule_id, g.instance_id, x.key, g.database, x.st, x.last_value,
           CASE x.st WHEN 'critical' THEN x.crit_thr WHEN 'warning' THEN x.warn_thr ELSE coalesce(x.warn_thr, x.crit_thr) END,
           x.last_at,
           CASE x.st WHEN 'critical' THEN x.crit_from WHEN 'warning' THEN x.warn_from ELSE coalesce(x.warn_from, x.crit_from) END,
           x.crit_run, x.crit_in, x.warn_run, x.warn_in, x.fam, x.base, x.base_days
      FROM x;
  END LOOP;
END $$;

-- alert_rules_run: 0085's, per family, with the baselines refreshed first and the flapping ring kept. Flapping is
-- SQLWATCH's rule: of the series' last 12 judged levels within 6 h (ok, warning or critical; pending and no data
-- count as ok), a status-change ratio between 0.35 and 0.65 marks it (flapping_since); under 0.35 the mark drops;
-- fewer than 12 results keep the mark as it is. A rule with ignore_flapping is never marked.
CREATE OR REPLACE FUNCTION pgvigil.alert_rules_run(p_at timestamptz)
RETURNS int LANGUAGE plpgsql SET jit = off AS $$
DECLARE
  v_firing int;
BEGIN
  PERFORM pgvigil.alert_rule_baseline_refresh(p_at);
  WITH e AS MATERIALIZED (
    SELECT * FROM pgvigil.alert_rule_eval(p_at)
  ), j AS MATERIALIZED (
    SELECT e.*, coalesce(e.database, '') AS db, CASE r.op WHEN 'below' THEN 'below' ELSE 'above' END AS op,
           r.warning AS r_warn, r.critical AS r_crit, r.ignore_flapping,
           o.state AS o_state, o.rule_id AS o_rule, o.since AS o_since, o.beyond_since AS o_beyond,
           o.sample_at AS o_sample_at, o.value AS o_value,
           coalesce(o.state IN ('warning', 'critical'), false) AS o_firing,
           coalesce(o.results, '{}') AS o_results, coalesce(o.result_at, '{}') AS o_result_at, o.flapping_since AS o_flapping
      FROM e
      JOIN pgvigil.alert_rules r ON r.rule_id = e.rule_id
      LEFT JOIN pgvigil.alert_rule_state o
        ON o.instance_id = e.instance_id AND o.metric = e.metric AND o.database = coalesce(e.database, '')
       AND o.op_family = e.op_family
  ), fin AS MATERIALIZED (
    SELECT j.*,
           CASE
             WHEN j.state = 'critical' THEN 'critical'
             WHEN j.state = 'nodata' AND j.o_firing AND j.o_rule = j.rule_id THEN j.o_state
             WHEN j.state = 'nodata' AND j.o_firing AND pgvigil.alert_beyond(j.op, j.o_value, j.r_crit) THEN 'critical'
             WHEN j.state = 'nodata' AND j.o_firing AND pgvigil.alert_beyond(j.op, j.o_value, j.r_warn) THEN 'warning'
             WHEN j.o_firing AND j.o_state = 'critical' AND j.crit_beyond
                  AND (j.crit_within_at IS NULL OR (j.o_rule = j.rule_id AND j.crit_within_at <= j.o_sample_at)) THEN 'critical'
             WHEN j.state = 'warning' THEN 'warning'
             WHEN j.o_firing AND j.warn_beyond
                  AND (j.warn_within_at IS NULL OR (j.o_rule = j.rule_id AND j.warn_within_at <= j.o_sample_at)) THEN 'warning'
             ELSE j.state END AS new_state
      FROM j
  ), rg AS MATERIALIZED (   -- the ring: the last 12 levels within 6 h, newest last, and how often they changed
    SELECT fin.*, z.res, z.res_at,
           (SELECT count(*)::int FROM generate_subscripts(z.res, 1) s WHERE s > 1 AND z.res[s] IS DISTINCT FROM z.res[s - 1]) AS changes
      FROM fin
      CROSS JOIN LATERAL (
        SELECT coalesce(array_agg(u.v ORDER BY u.o), '{}') AS res, coalesce(array_agg(u.t ORDER BY u.o), '{}') AS res_at
          FROM (SELECT q.v, q.t, q.o
                  FROM unnest(fin.o_results || ARRAY[CASE WHEN fin.new_state IN ('warning', 'critical') THEN fin.new_state ELSE 'ok' END],
                              fin.o_result_at || ARRAY[p_at]) WITH ORDINALITY AS q(v, t, o)
                 WHERE q.t > p_at - interval '6 hours'
                 ORDER BY q.o DESC LIMIT 12) u) z
  ), up AS (
    INSERT INTO pgvigil.alert_rule_state AS s (instance_id, metric, database, op_family, rule_id, state, held, value,
                                               threshold, sample_at, beyond_since, since, evaluated_at, results, result_at,
                                               flapping_since, baseline, baseline_days)
    SELECT rg.instance_id, rg.metric, rg.db, rg.op_family, rg.rule_id, rg.new_state,
           (rg.state = 'nodata' AND rg.new_state IN ('warning', 'critical')),
           coalesce(rg.value, rg.o_value),
           -- 0085's: the rule's own value of the level kept; a baseline rule judged at that level now: the widened value
           CASE rg.new_state
             WHEN 'critical' THEN CASE WHEN rg.op_family = 'baseline' AND rg.state = 'critical' THEN rg.threshold ELSE rg.r_crit END
             WHEN 'warning' THEN CASE WHEN rg.op_family = 'baseline' AND rg.state = 'warning' THEN rg.threshold ELSE rg.r_warn END
             ELSE rg.threshold END,
           coalesce(rg.sample_at, rg.o_sample_at),
           CASE WHEN rg.o_state = rg.new_state AND rg.new_state IN ('warning', 'critical')
                THEN least(rg.o_beyond, rg.beyond_since) ELSE rg.beyond_since END,
           CASE WHEN rg.o_state = rg.new_state THEN rg.o_since ELSE p_at END,
           p_at, rg.res, rg.res_at,
           CASE WHEN rg.ignore_flapping THEN NULL
                WHEN cardinality(rg.res) = 12 AND rg.changes / 11.0 BETWEEN 0.35 AND 0.65 THEN coalesce(rg.o_flapping, p_at)
                WHEN cardinality(rg.res) = 12 AND rg.changes / 11.0 < 0.35 THEN NULL
                ELSE rg.o_flapping END,
           rg.baseline, rg.baseline_days
      FROM rg
    ON CONFLICT (instance_id, metric, database, op_family) DO UPDATE SET
      rule_id = EXCLUDED.rule_id, state = EXCLUDED.state, held = EXCLUDED.held, value = EXCLUDED.value,
      threshold = EXCLUDED.threshold, sample_at = EXCLUDED.sample_at, beyond_since = EXCLUDED.beyond_since,
      since = EXCLUDED.since, evaluated_at = EXCLUDED.evaluated_at, results = EXCLUDED.results,
      result_at = EXCLUDED.result_at, flapping_since = EXCLUDED.flapping_since, baseline = EXCLUDED.baseline,
      baseline_days = EXCLUDED.baseline_days
    RETURNING s.instance_id
  ), began AS (         -- the series that began to fire in this run
    SELECT fin.rule_id, max(i.name) AS instance, count(*) AS n
      FROM fin JOIN pgvigil.instances i ON i.instance_id = fin.instance_id
     WHERE fin.new_state IN ('warning', 'critical') AND NOT fin.o_firing
     GROUP BY fin.rule_id
  )
  INSERT INTO pgvigil.alert_rule_fired AS f (rule_id, last_fired_at, last_instance, fired)
  SELECT b.rule_id, p_at, b.instance, b.n FROM began b
  ON CONFLICT (rule_id) DO UPDATE SET last_fired_at = EXCLUDED.last_fired_at, last_instance = EXCLUDED.last_instance,
    fired = f.fired + EXCLUDED.fired;
  DELETE FROM pgvigil.alert_rule_state s WHERE s.evaluated_at IS DISTINCT FROM p_at;
  SELECT count(*) INTO v_firing FROM pgvigil.alert_rule_state s WHERE s.state IN ('warning', 'critical');
  RETURN v_firing;
END $$;
GRANT EXECUTE ON FUNCTION pgvigil.alert_rules_run(timestamptz) TO pgvigil_alerter;

-- the firing rows as findings: 0085's, per family. A threshold rule's value and detail are 0085's word for word (its
-- open alerts keep their keys at the upgrade); a rise or baseline finding's value names its family, so its key is
-- its own. The detail says the baseline's state and, while the series is marked, that it is flapping. The rule, its
-- family, the mark and the newest sample ride at the end.
CREATE OR REPLACE VIEW pgvigil.alert_rule_findings AS
SELECT s.instance_id, s.state AS severity,
       c.family_label || ': ' || c.label || CASE WHEN s.database <> '' THEN ' [' || s.database || ']' ELSE '' END AS setting,
       CASE s.op_family
         WHEN 'rise' THEN 'rises ' || pgvigil.metric_num(s.threshold) || ' between two samples for ' || r.for_minutes
                          || ' min; last rise ' || coalesce(pgvigil.metric_num(s.value), 'none')
         WHEN 'baseline' THEN 'above baseline for ' || r.for_minutes || ' min; last sample ' || coalesce(pgvigil.metric_num(s.value), 'none')
         ELSE r.op || ' ' || pgvigil.metric_num(s.threshold) || ' for ' || r.for_minutes || ' min; last sample '
              || coalesce(pgvigil.metric_num(s.value), 'none') END AS value,
       NULL::boolean AS is_set, NULL::text AS suggested, NULL::text AS platforms,
       'alert rule ' || r.rule_id || coalesce(' "' || r.name || '"', '') || ' ('
         || CASE r.scope WHEN 'fleet' THEN 'every instance' WHEN 'tag' THEN 'tag ' || r.tag
                         WHEN 'tags' THEN 'tags ' || pgvigil.alert_scope_text(r.scope_tags) ELSE 'instance ' || r.instance_name END
         || '): ' || r.metric || ' '
         || CASE s.op_family
              WHEN 'rise' THEN 'rises more than ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || ') between two samples'
              WHEN 'baseline' THEN CASE WHEN coalesce(s.baseline_days, 0) = 7 AND s.baseline IS NOT NULL
                                        THEN 'above ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || '): the greater of the rule''s value and this hour''s baseline '
                                             || pgvigil.metric_num(s.baseline) || ' + ' || pgvigil.metric_num(r.band_pct) || ' % (' || r.zone || ')'
                                        ELSE 'above ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || '): no baseline yet ('
                                             || coalesce(s.baseline_days, 0) || ' of 7 days), the rule''s value alone' END
              ELSE r.op || ' ' || pgvigil.metric_num(s.threshold) || ' (' || c.unit || ')' END
         || ' since ' || to_char(s.beyond_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC'
         || CASE WHEN s.held THEN '; no fresh sample since ' || to_char(s.sample_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC: the alert is held' ELSE '' END
         || CASE WHEN s.flapping_since IS NOT NULL
                 THEN '; flapping since ' || to_char(s.flapping_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI')
                      || ' UTC (4 to 7 changes in its last 12 results): sent once, its repeats held' ELSE '' END AS detail,
       'alert rule'::text AS source, coalesce(s.sample_at, s.evaluated_at) AS at,
       s.rule_id, s.op_family, s.flapping_since, s.value AS metric_value
  FROM pgvigil.alert_rule_state s
  JOIN pgvigil.alert_rules r ON r.rule_id = s.rule_id
  JOIN pgvigil.metric_catalog c ON c.key = s.metric
 WHERE s.state IN ('warning', 'critical');

-- alert_hold: the first hold of one alert on one channel at p_at, by precedence, or NULL - called by alert_mark and,
-- through the wiring line, alert_due. An ack blackout, silence or mute is 0073's (ack_rule_matches; a paused rule holds
-- nothing); a window holds inside its span, a digest window only up to its ceiling; the digest carry-over (this
-- file's header) only while the alert was never sent on the channel and its digest row was refreshed within the
-- channel's clear_after (missing_since) - both digest holds on a channel with a digest only (p_digest); the
-- flapping hold last - a rule's alert whose series is marked flapping is held on a channel
-- once that channel was sent it (any occurrence) since the mark at its severity or higher: the first send after the
-- mark goes out (its detail says flapping), its repeats and re-firings are held, an escalation is sent.
CREATE OR REPLACE FUNCTION pgvigil.alert_hold(p_at timestamptz, p_channel text, p_instance text, p_tags text[],
                                              p_finding_key text, p_source text, p_setting text, p_value text,
                                              p_severity text, p_clear_after_secs int DEFAULT 600,
                                              p_digest boolean DEFAULT false)
RETURNS pgvigil.alert_hold_t LANGUAGE sql STABLE AS $$
  SELECT ROW(h.kind, h.id, h.via)::pgvigil.alert_hold_t
    FROM (
      SELECT CASE a.kind WHEN 'blackout' THEN 1 ELSE 2 END AS rank, 1 AS sub,
             CASE a.kind WHEN 'blackout' THEN 'blackout' ELSE 'mute' END AS kind, a.ack_id AS id, 'ack' AS via
        FROM pgvigil.acks a
       WHERE a.kind IN ('mute', 'silence', 'blackout') AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, p_at)
         AND a.paused_at IS NULL
         AND pgvigil.ack_rule_matches(a, p_instance, p_tags, p_finding_key, p_source, p_setting, p_value)
      UNION ALL
      SELECT CASE w.action WHEN 'blackout' THEN 1 WHEN 'mute' THEN 2 ELSE 3 END, 2, w.action, w.window_id, 'window'
        FROM pgvigil.alert_windows w
       WHERE w.ended_at IS NULL AND pgvigil.alert_window_live(w, p_at)
         AND pgvigil.alert_window_matches(w, p_instance, p_tags, p_source)
         AND (w.action <> 'digest'
              OR (p_digest AND pgvigil.severity_rank(p_severity) <= pgvigil.severity_rank(w.severity_ceiling)))
      UNION ALL
      SELECT 3, 3, 'digest', d.hold_id, 'carry'
        FROM pgvigil.alert_held d
        JOIN pgvigil.alert_windows w ON w.window_id = d.hold_id
       WHERE p_digest AND d.hold_kind = 'digest' AND d.channel = p_channel AND d.finding_key = p_finding_key
         AND (d.missing_since IS NULL
              OR d.missing_since > p_at - make_interval(secs => greatest(coalesce(p_clear_after_secs, 600), 60)))
         AND pgvigil.severity_rank(p_severity) <= pgvigil.severity_rank(w.severity_ceiling)
         AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_state st
                          WHERE st.channel = p_channel AND st.finding_key = p_finding_key AND st.cleared_at IS NULL)
      UNION ALL
      SELECT 4, 1, 'flapping', y.rule_id, 'rule'
        FROM pgvigil.alert_rule_findings y
       WHERE p_source = 'alert rule' AND y.flapping_since IS NOT NULL
         AND pgvigil.alert_key(y.instance_id, y.source, y.setting, y.value) = p_finding_key
         AND EXISTS (SELECT 1 FROM pgvigil.alert_state st
                      WHERE st.channel = p_channel AND st.finding_key = p_finding_key
                        AND st.last_sent_at >= y.flapping_since
                        AND pgvigil.severity_rank(st.severity) >= pgvigil.severity_rank(p_severity))
    ) h
   ORDER BY h.rank, h.sub, h.id
   LIMIT 1
$$;

-- import_alert_rule: 0085's, with the new fields (the actions door's audit login; minimum role operator for every op,
-- B24f): op_dir above | below | rises | above_baseline; scope fleet | tag | tags (scope_tags, a list) | instance;
-- band_pct (default 20) and zone (an IANA name, required) for above_baseline; ignore_flapping. A second rule of one
-- family on one metric, scope and database is refused (edit that rule); rules of different families coexist.
CREATE OR REPLACE FUNCTION pgvigil.import_alert_rule(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_metric  text := nullif(p_payload->>'metric', '');
  v_dir     text := p_payload->>'op_dir';
  v_scope   text := p_payload->>'scope';
  v_tag     text := nullif(btrim(coalesce(p_payload->>'tag', '')), '');
  v_inst    text := nullif(p_payload->>'instance_name', '');
  v_db      text := nullif(btrim(coalesce(p_payload->>'database', '')), '');
  v_name    text := nullif(btrim(coalesce(p_payload->>'name', '')), '');
  v_note    text := nullif(btrim(coalesce(p_payload->>'note', '')), '');
  v_tags    text[];
  v_band    double precision;
  v_zone    text := nullif(btrim(coalesce(p_payload->>'zone', '')), '');
  v_noflap  boolean := false;
  v_warn    double precision;
  v_crit    double precision;
  v_for     int := 5;
  v_id      bigint;
  v_new     bigint;
  v_why     text;
  v_done    text;
  v_old     pgvigil.alert_rules;
  v_cat     record;
  v_engine  text;
  v_iid     int;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_alert_rule: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op IS NULL OR v_op NOT IN ('add', 'edit', 'end', 'enable', 'disable') THEN
    v_why := 'op must be add, edit, end, enable or disable';
  END IF;
  IF v_why IS NULL AND v_op <> 'add' THEN
    IF coalesce(p_payload->>'rule_id', '') ~ '^[0-9]{1,18}$' THEN
      v_id := (p_payload->>'rule_id')::bigint;
      SELECT * INTO v_old FROM pgvigil.alert_rules WHERE rule_id = v_id FOR UPDATE;
    END IF;
    IF v_id IS NULL THEN
      v_why := format('rule_id %L is not a rule id', p_payload->>'rule_id');
    ELSIF v_old.rule_id IS NULL THEN
      v_why := format('no rule %s', v_id);
    ELSIF v_old.ended_at IS NOT NULL THEN
      v_why := format('rule %s was ended by %s at %s', v_id, v_old.ended_by, v_old.ended_at);
    ELSIF v_op = 'enable' AND v_old.enabled THEN
      v_why := format('rule %s is already on', v_id);
    ELSIF v_op = 'disable' AND NOT v_old.enabled THEN
      v_why := format('rule %s is already off', v_id);
    END IF;
  END IF;
  IF v_why IS NULL AND v_op IN ('add', 'edit') THEN
    SELECT c.key, c.engine, c.per_database INTO v_cat FROM pgvigil.metric_catalog c WHERE c.key = v_metric;
    IF v_cat.key IS NULL THEN
      v_why := format('no metric %L', v_metric);
    ELSIF v_dir IS NULL OR v_dir NOT IN ('above', 'below', 'rises', 'above_baseline') THEN
      v_why := 'op_dir must be above, below, rises or above_baseline';
    ELSIF coalesce(jsonb_typeof(p_payload->'band_pct'), 'null') NOT IN ('number', 'null')
          OR coalesce(jsonb_typeof(p_payload->'ignore_flapping'), 'null') NOT IN ('boolean', 'null') THEN
      v_why := 'band_pct is a number and ignore_flapping true or false';
    ELSIF v_dir = 'above_baseline' AND (v_zone IS NULL OR NOT EXISTS (SELECT 1 FROM pg_timezone_names z WHERE z.name = v_zone)) THEN
      v_why := format('a baseline rule names its time zone: %L is not one this server knows (an IANA name, e.g. America/Chicago)', v_zone);
    ELSIF v_dir = 'above_baseline' AND coalesce((p_payload->>'band_pct')::double precision, 20) NOT BETWEEN 0 AND 1000 THEN
      v_why := 'band_pct is 0 to 1000 (per cent above the baseline)';
    ELSIF coalesce(jsonb_typeof(p_payload->'warning'), 'null') NOT IN ('number', 'null')
          OR coalesce(jsonb_typeof(p_payload->'critical'), 'null') NOT IN ('number', 'null') THEN
      v_why := 'warning and critical are numbers';
    ELSIF coalesce(jsonb_typeof(p_payload->'for_minutes'), 'null') NOT IN ('number', 'null')
          OR coalesce(p_payload->>'for_minutes', '5') !~ '^[0-9]{1,4}$' THEN
      v_why := 'for_minutes is a whole number of minutes, 0 to 1440';
    ELSIF v_scope IS NULL OR v_scope NOT IN ('fleet', 'tag', 'tags', 'instance') THEN
      v_why := 'scope must be fleet, tag, tags or instance';
    ELSIF v_scope = 'tag' AND v_tag IS NULL THEN
      v_why := 'a tag rule names its tag';
    ELSIF v_scope = 'tags' AND (jsonb_typeof(p_payload->'scope_tags') IS DISTINCT FROM 'array'
          OR pgvigil.alert_scope_norm(ARRAY(SELECT jsonb_array_elements_text(p_payload->'scope_tags'))) IS NULL) THEN
      v_why := 'a tags rule names at least one tag (scope_tags)';
    ELSIF v_scope = 'instance' AND v_inst IS NULL THEN
      v_why := 'an instance rule names its instance';
    ELSIF v_db IS NOT NULL AND NOT v_cat.per_database THEN
      v_why := format('%s has no per-database series: leave the database empty', v_metric);
    ELSE
      BEGIN
        v_warn := (p_payload->>'warning')::double precision;
        v_crit := (p_payload->>'critical')::double precision;
      EXCEPTION WHEN numeric_value_out_of_range OR invalid_text_representation THEN
        v_why := 'warning and critical must be finite numbers';
      END;
      v_for := coalesce(p_payload->>'for_minutes', '5')::int;
      IF v_why IS NOT NULL THEN
        NULL;
      ELSIF v_for > 1440 THEN
        v_why := 'for_minutes is a whole number of minutes, 0 to 1440';
      ELSIF v_warn IS NULL AND v_crit IS NULL THEN
        v_why := 'a rule needs a warning or a critical value';
      ELSIF (v_dir <> 'below' AND v_crit < v_warn) OR (v_dir = 'below' AND v_crit > v_warn) THEN
        v_why := format('critical must be at or beyond warning (%s: critical %s warning)', v_dir,
                        CASE v_dir WHEN 'below' THEN '<=' ELSE '>=' END);
      ELSIF v_scope = 'instance' THEN
        SELECT i.instance_id, i.engine INTO v_iid, v_engine FROM pgvigil.instances i WHERE i.name = v_inst AND i.is_active;
        IF v_iid IS NULL THEN
          v_why := format('no active instance %L', v_inst);
        ELSIF v_cat.engine NOT IN (v_engine, 'any') THEN
          v_why := format('%s is a %s metric and %s is a %s instance', v_metric, v_cat.engine, v_inst, v_engine);
        END IF;
      END IF;
      IF v_scope <> 'tag' THEN v_tag := NULL; END IF;
      IF v_scope = 'tags' THEN
        v_tags := pgvigil.alert_scope_norm(ARRAY(SELECT jsonb_array_elements_text(p_payload->'scope_tags')));
      END IF;
      IF v_dir = 'above_baseline' THEN
        v_band := coalesce((p_payload->>'band_pct')::double precision, 20);
      ELSE
        v_zone := NULL;
      END IF;
      v_noflap := coalesce((p_payload->>'ignore_flapping')::boolean, false);
      IF v_scope <> 'instance' THEN v_inst := NULL; v_iid := NULL; END IF;
    END IF;
  END IF;
  IF v_why IS NULL THEN
    BEGIN
      IF v_op IN ('edit', 'end') THEN
        UPDATE pgvigil.alert_rules SET ended_by = v_user, ended_at = p_at WHERE rule_id = v_id;
        v_done := 'ended';
      ELSIF v_op IN ('enable', 'disable') THEN
        UPDATE pgvigil.alert_rules SET enabled = (v_op = 'enable') WHERE rule_id = v_id;
        v_done := CASE v_op WHEN 'enable' THEN 'switched on' ELSE 'switched off' END;
      END IF;
      IF v_op IN ('add', 'edit') THEN
        INSERT INTO pgvigil.alert_rules (name, metric, op, warning, critical, for_minutes, scope, tag, instance_id, instance_name,
                                         database, note, enabled, replaces, created_by, created_at, client,
                                         scope_tags, band_pct, zone, ignore_flapping)
        VALUES (v_name, v_metric, v_dir, v_warn, v_crit, v_for, v_scope, v_tag, v_iid, v_inst, v_db, v_note,
                CASE WHEN v_op = 'edit' THEN v_old.enabled ELSE true END,
                CASE WHEN v_op = 'edit' THEN v_id END, v_user, p_at, v_client, v_tags, v_band, v_zone, v_noflap)
        RETURNING rule_id INTO v_new;
        IF v_op = 'edit' THEN     -- the successor is the same rule to its reader: when it last fired goes with it
          INSERT INTO pgvigil.alert_rule_fired (rule_id, last_fired_at, last_instance, fired)
          SELECT v_new, f.last_fired_at, f.last_instance, f.fired FROM pgvigil.alert_rule_fired f WHERE f.rule_id = v_id;
        END IF;
        v_done := CASE v_op WHEN 'edit' THEN format('rule %s replaced by rule %s', v_id, v_new) ELSE 'added' END;
      END IF;
    EXCEPTION
      WHEN unique_violation THEN
        v_why := 'a live rule of this kind (above / below, rises or above the baseline) already holds this metric, scope and database: edit that rule';
        v_new := NULL;
      WHEN check_violation OR foreign_key_violation OR invalid_text_representation OR numeric_value_out_of_range
           OR string_data_right_truncation THEN
        v_why := 'refused by the store: ' || SQLERRM;
        v_new := NULL;
    END;
  END IF;
  INSERT INTO pgvigil.alert_rule_log (at, ui_user, client, op, rule_id, metric, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, v_op, coalesce(v_new, v_id), coalesce(v_metric, v_old.metric),
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, coalesce(v_why, v_done), p_payload);
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, v_done), 'rule_id', coalesce(v_new, v_id));
END $$;
