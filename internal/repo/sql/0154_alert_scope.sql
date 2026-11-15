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
--                       the newest detail); ack_suppressed keeps the ack kinds unchanged. alert_held_all is the union,
--                       the one read behind the 'why held' line and the digest.
--   alert_hold(...)     the ONE hold test, called by alert_mark (here) and alert_due (0190's, a wiring line): the
--                       first hold by precedence - blackout (an ack, then a window) > mute (an ack mute or silence, then
--                       a window) > digest (a window, then the carry-over) > flapping - or NULL.
--   digest_log          one row per channel and digest: sent, failed, refused or empty; digest_due reads it.
--   findings_history    every finding key's open, close and severity change, plus one sample per standing key per hour
--                       (the timeline); monthly partitions, kept 90 days (findings_history_days; the purge line is a
--                       wiring line). No detail is stored: a detail can carry statement text (0029's plan findings).
--
-- The digest carry-over: an alert first held by a digest window on a channel, never sent there, stays held after the
-- window ends while it keeps standing (alert_held's row is refreshed every pass; a gap longer than the channel's
-- clear_after ends it). So the window's end fires nothing, no recovery is ever owed (nothing was sent: there is no
-- alert_state row), and the alert reaches the channel in the digest only. An escalation past the window's ceiling is
-- not held and fires at once.
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

-- alert_hold: the first hold of one alert on one channel at p_at, by precedence, or NULL. An ack blackout, silence
-- or mute is 0073's (ack_rule_matches, paused rules hold nothing); a window holds inside its span; a digest window
-- only up to its ceiling; the digest carry-over (this file's header) only while the alert was never sent on the
-- channel and its digest row was refreshed within the channel's clear_after. Flapping is added below (the rules part).
CREATE OR REPLACE FUNCTION pgvigil.alert_hold(p_at timestamptz, p_channel text, p_instance text, p_tags text[],
                                              p_finding_key text, p_source text, p_setting text, p_value text,
                                              p_severity text, p_clear_after_secs int DEFAULT 600)
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
         AND (w.action <> 'digest' OR pgvigil.severity_rank(p_severity) <= pgvigil.severity_rank(w.severity_ceiling))
      UNION ALL
      SELECT 3, 3, 'digest', d.hold_id, 'carry'
        FROM pgvigil.alert_held d
        JOIN pgvigil.alert_windows w ON w.window_id = d.hold_id
       WHERE d.hold_kind = 'digest' AND d.channel = p_channel AND d.finding_key = p_finding_key
         AND d.last_at >= p_at - make_interval(secs => greatest(coalesce(p_clear_after_secs, 600), 60))
         AND pgvigil.severity_rank(p_severity) <= pgvigil.severity_rank(w.severity_ceiling)
         AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_state st
                          WHERE st.channel = p_channel AND st.finding_key = p_finding_key AND st.cleared_at IS NULL)
    ) h
   ORDER BY h.rank, h.sub, h.id
   LIMIT 1
$$;

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

  WITH h AS MATERIALIZED (
    SELECT x.channel, x.finding_key, x.instance_id, x.instance, x.severity, x.source, x.setting, x.value, x.detail,
           (x.hold).kind AS kind, (x.hold).hold_id AS hold_id, (x.hold).via AS via
      FROM (SELECT DISTINCT ON (c.name, f.finding_key) c.name AS channel, f.finding_key, f.instance_id, f.instance,
                   f.severity, f.source, f.setting, f.value, f.detail,
                   pgvigil.alert_hold(p_at, c.name, f.instance, f.tags, f.finding_key, f.source, f.setting, f.value,
                                      f.severity, c.clear_after_secs) AS hold
              FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
                   AS c(name text, min_severity text, instances text[], tags text[], clear_after_secs int)
              JOIN pgvigil.alert_findings f ON pgvigil.alert_in_scope(f.instance, f.tags, coalesce(c.instances, '{}'), coalesce(c.tags, '{}'))
             WHERE pgvigil.severity_rank(f.severity) >= pgvigil.severity_rank(c.min_severity)
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
    passes = y.passes + 1, severity = EXCLUDED.severity, value = EXCLUDED.value, detail = EXCLUDED.detail;
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
               CASE WHEN r.scope = 'tag' THEN pgvigil.alert_scope_norm(ARRAY[r.tag]) END, r.instance_name
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
    CROSS JOIN LATERAL (SELECT pgvigil.digest_hour_at(p_at, c.digest_hour, coalesce(nullif(c.timezone, ''), 'UTC')) AS due_at) d
   WHERE c.digest_hour BETWEEN 0 AND 23
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
    SELECT DISTINCT ON (f.finding_key) f.finding_key, f.instance_id, f.instance, f.source, f.setting, f.value, f.severity
      FROM pgvigil.alert_findings f
     ORDER BY f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC
  ), ev AS (
    SELECT c.finding_key, c.instance_id, c.instance, c.source, c.setting, c.value, c.severity,
           CASE WHEN l.finding_key IS NULL THEN 'open'
                WHEN l.severity IS DISTINCT FROM c.severity THEN 'severity'
                WHEN l.sampled_at <= p_at - interval '1 hour' THEN 'sample' END AS event
      FROM cur c LEFT JOIN pgvigil.findings_history_last l USING (finding_key)
    UNION ALL
    SELECT l.finding_key, NULL, NULL, NULL, NULL, NULL, l.severity, 'close'
      FROM pgvigil.findings_history_last l
     WHERE NOT EXISTS (SELECT 1 FROM cur c WHERE c.finding_key = l.finding_key)
  ), w AS (
    INSERT INTO pgvigil.findings_history (snapshot_at, finding_key, instance_id, instance_name, source, setting, value, event, severity)
    SELECT p_at, ev.finding_key, ev.instance_id, ev.instance, ev.source, ev.setting, ev.value, ev.event, ev.severity
      FROM ev WHERE ev.event IS NOT NULL
    RETURNING 1
  ), d AS (
    DELETE FROM pgvigil.findings_history_last l
     WHERE NOT EXISTS (SELECT 1 FROM cur c WHERE c.finding_key = l.finding_key)
  ), u AS (
    INSERT INTO pgvigil.findings_history_last AS l (finding_key, severity, opened_at, sampled_at)
    SELECT ev.finding_key, ev.severity, p_at, p_at FROM ev WHERE ev.event IN ('open', 'severity', 'sample')
    ON CONFLICT (finding_key) DO UPDATE SET severity = EXCLUDED.severity, sampled_at = EXCLUDED.sampled_at
  )
  SELECT count(*) INTO n FROM w;
  RETURN n;
END $$;
