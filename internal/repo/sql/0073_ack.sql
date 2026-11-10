-- 0073_ack: acknowledge, mute, notes (task 118). One store for every acknowledgement and mute the UI makes, with who
-- and when on every row, and the audit of every attempt to make or end one.
--
--   acks            one row per acknowledgement, note or rule; never deleted by the UI: ending one stamps ended_by and
--                   ended_at. kind:
--                     ack        a check (a Summary status column, check_key = its group key) of one instance, until a
--                                time and / or until the check changes (seen_state = the cell as acknowledged; the
--                                page compares it, the store keeps it)
--                     alert_ack  an alert (finding_key): no repeat send while it stands; an escalation still sends
--                     note       a note on an alert (finding_key, note)
--                     close      an open alert whose finding is gone, closed: it leaves the open list
--                     blackout   one instance from starts_at to until: its alerts are not sent (still logged) and are
--                                flagged blackout on the Alerts page
--                     job        a job's failure (instance, job_name, seen_state = the last failure acknowledged): the
--                                cell loses its colour until a newer failure
--                     silence    one instance, until unsilenced (or until): every alert of the server is held and logged
--                     mute       a rule: any of check (a finding's source or setting), instance, tag, text (in the
--                                source, setting or value), finding_key (one alert); an expiry; held sends are logged
--                     noise      a known-noise label (note) shown beside a matching alert; nothing is held
--   ack_log         every attempt from the UI (done or refused), who, from where, what.
--   ack_suppressed  per rule, channel and alert: the sends a mute, silence or blackout held (first, last, passes).
--
-- Writes: pgvigil.import_ack(at, payload), the actions door's audit login (pgvigil_collector: apply_roles makes every
-- import_* SECURITY DEFINER and grants it there). The sender (pgvigil_alerter) reads acks and writes ack_suppressed
-- through alert_mark; alert_due leaves a muted alert unsent. Neither table is purged: like actions_log, an audit.

CREATE TABLE IF NOT EXISTS pgvigil.acks (
  ack_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kind           text NOT NULL CHECK (kind IN ('ack', 'alert_ack', 'note', 'close', 'blackout', 'job', 'silence', 'mute', 'noise')),
  instance_id    int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  instance_name  text,            -- the match: a removed instance's rule matches nothing, never every server
  check_key      text CHECK (length(check_key) <= 200),
  finding_key    text CHECK (length(finding_key) <= 64),
  job_name       text CHECK (length(job_name) <= 300),
  tag            text CHECK (length(tag) <= 200),
  match_text     text CHECK (length(match_text) BETWEEN 1 AND 200),
  note           text CHECK (length(note) BETWEEN 1 AND 2000),
  seen_state     text CHECK (length(seen_state) <= 300),
  starts_at      timestamptz,
  until          timestamptz,
  until_change   boolean NOT NULL DEFAULT false,
  created_by     text NOT NULL,
  created_at     timestamptz NOT NULL,
  client         text,
  ended_by       text,
  ended_at       timestamptz,
  CONSTRAINT "an ack, job, silence or blackout names one instance" CHECK (kind NOT IN ('ack', 'job', 'silence', 'blackout') OR instance_name IS NOT NULL),
  CONSTRAINT "a check's ack names the check" CHECK (kind <> 'ack' OR check_key IS NOT NULL),
  CONSTRAINT "a job's ack names the job and its failure" CHECK (kind <> 'job' OR (job_name IS NOT NULL AND seen_state IS NOT NULL)),
  CONSTRAINT "an alert's ack, note or close names the alert" CHECK (kind NOT IN ('alert_ack', 'note', 'close') OR finding_key IS NOT NULL),
  CONSTRAINT "a note has its text" CHECK (kind <> 'note' OR note IS NOT NULL),
  CONSTRAINT "a known-noise rule has its label" CHECK (kind <> 'noise' OR note IS NOT NULL),
  CONSTRAINT "a blackout has a start and a later end" CHECK (kind <> 'blackout' OR (starts_at IS NOT NULL AND until IS NOT NULL AND until > starts_at)),
  CONSTRAINT "a rule matches on a check, instance, tag, text or alert" CHECK (kind NOT IN ('mute', 'noise') OR num_nonnulls(instance_name, check_key, tag, match_text, finding_key) > 0),
  CONSTRAINT "until is after the row is made" CHECK (until IS NULL OR until > created_at)
);
CREATE INDEX IF NOT EXISTS acks_open_idx ON pgvigil.acks (kind, instance_name) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS acks_finding_idx ON pgvigil.acks (finding_key) WHERE finding_key IS NOT NULL;
COMMENT ON TABLE pgvigil.acks IS 'Acknowledgements, notes, blackouts, silences, mute rules and known-noise labels from the UI; written through import_ack only.';

CREATE TABLE IF NOT EXISTS pgvigil.ack_log (
  log_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  at             timestamptz NOT NULL,
  ui_user        text NOT NULL,
  client         text,
  op             text NOT NULL CHECK (op IN ('add', 'end')),
  kind           text,
  ack_id         bigint,
  instance_name  text,
  outcome        text NOT NULL CHECK (outcome IN ('done', 'refused')),
  detail         text,
  payload        jsonb
);
CREATE INDEX IF NOT EXISTS ack_log_at_idx ON pgvigil.ack_log (at DESC);

CREATE TABLE IF NOT EXISTS pgvigil.ack_suppressed (
  ack_id         bigint NOT NULL REFERENCES pgvigil.acks(ack_id),
  channel        text NOT NULL,
  finding_key    text NOT NULL,
  instance_id    int,
  instance_name  text,
  severity       text,
  source         text,
  setting        text,
  value          text,
  first_at       timestamptz NOT NULL,
  last_at        timestamptz NOT NULL,
  passes         int NOT NULL DEFAULT 1,
  PRIMARY KEY (ack_id, channel, finding_key)
);
CREATE INDEX IF NOT EXISTS ack_suppressed_last_idx ON pgvigil.ack_suppressed (last_at DESC);

-- the sender: reads acks (pgvigil_reader, through apply_roles), records what it held
GRANT SELECT, INSERT, UPDATE ON pgvigil.ack_suppressed TO pgvigil_alerter;

-- ack_live: a row in force at p_at (not ended, started, not expired)
CREATE OR REPLACE FUNCTION pgvigil.ack_live(p_ended_at timestamptz, p_starts_at timestamptz, p_until timestamptz, p_at timestamptz)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT (p_ended_at IS NULL OR p_ended_at > p_at) AND (p_starts_at IS NULL OR p_starts_at <= p_at) AND (p_until IS NULL OR p_until > p_at)
$$;

-- ack_rule_matches: a mute / silence / blackout / noise row against one alert
CREATE OR REPLACE FUNCTION pgvigil.ack_rule_matches(a pgvigil.acks, p_instance text, p_tags text[], p_finding_key text,
                                                    p_source text, p_setting text, p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT (a.instance_name IS NULL OR a.instance_name = p_instance)
     AND (a.tag IS NULL OR a.tag = ANY (coalesce(p_tags, '{}')))
     AND (a.finding_key IS NULL OR a.finding_key = p_finding_key)
     AND (a.check_key IS NULL OR lower(a.check_key) = lower(coalesce(p_source, '')) OR lower(a.check_key) = lower(coalesce(p_setting, '')))
     AND (a.match_text IS NULL
          OR strpos(lower(concat_ws(' ', p_source, p_setting, p_value)), lower(a.match_text)) > 0)
$$;

-- ack_hold: the mute, silence or blackout that holds an alert's send at p_at (the oldest), NULL = none
CREATE OR REPLACE FUNCTION pgvigil.ack_hold(p_at timestamptz, p_instance text, p_tags text[], p_finding_key text,
                                            p_source text, p_setting text, p_value text)
RETURNS bigint LANGUAGE sql STABLE AS $$
  SELECT a.ack_id FROM pgvigil.acks a
   WHERE a.kind IN ('mute', 'silence', 'blackout') AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, p_at)
     AND pgvigil.ack_rule_matches(a, p_instance, p_tags, p_finding_key, p_source, p_setting, p_value)
   ORDER BY a.ack_id LIMIT 1
$$;

-- ack_alert_acked: an alert acknowledged at p_at (its repeats are not sent)
CREATE OR REPLACE FUNCTION pgvigil.ack_alert_acked(p_at timestamptz, p_finding_key text)
RETURNS boolean LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM pgvigil.acks a WHERE a.kind = 'alert_ack' AND a.finding_key = p_finding_key
                    AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, p_at))
$$;

-- Both functions below run with jit off: the findings view under them crosses jit_above_cost, and LLVM spends 17 s
-- per read of it against 0.14 s without (a 1-day demo, 2026-11-10; serve sets jit off on its pool for the same view).
-- The sender's login has no such setting, and every pass reads the view several times.
--
-- alert_mark (0059's, the same two updates) and then the holds of this pass: per due channel, every finding in its
-- scope at or above its floor that a mute, silence or blackout holds, counted per rule, channel and alert
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
  INSERT INTO pgvigil.ack_suppressed AS x (ack_id, channel, finding_key, instance_id, instance_name, severity, source,
                                           setting, value, first_at, last_at, passes)
  SELECT h.ack_id, h.channel, h.finding_key, h.instance_id, h.instance, h.severity, h.source, h.setting, h.value, p_at, p_at, 1
    FROM (SELECT DISTINCT ON (c.name, f.finding_key) c.name AS channel, f.*,
                 pgvigil.ack_hold(p_at, f.instance, f.tags, f.finding_key, f.source, f.setting, f.value) AS ack_id
            FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
                 AS c(name text, min_severity text, instances text[], tags text[])
            JOIN pgvigil.alert_findings f ON pgvigil.alert_in_scope(f.instance, f.tags, coalesce(c.instances, '{}'), coalesce(c.tags, '{}'))
           WHERE pgvigil.severity_rank(f.severity) >= pgvigil.severity_rank(c.min_severity)
           ORDER BY c.name, f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC) h
   WHERE h.ack_id IS NOT NULL
  ON CONFLICT (ack_id, channel, finding_key) DO UPDATE SET last_at = EXCLUDED.last_at, passes = x.passes + 1,
    severity = EXCLUDED.severity, value = EXCLUDED.value;
END $$;

-- alert_due: 0059's, with the holds: a finding a mute, silence or blackout holds is owed nothing new (no firing, no
-- escalation, no repeat) while it stands, and its open row stays open (no recovery for a held alert that is still
-- there); an acknowledged alert is owed no repeat, an escalation still sends. Resolution is unchanged.
CREATE OR REPLACE FUNCTION pgvigil.alert_due(p_at timestamptz, p_channels jsonb)
RETURNS TABLE (channel text, event text, finding_key text, instance_id int, instance text, severity text, source text,
               setting text, value text, detail text, suggested text, finding_at timestamptz, first_sent_at timestamptz,
               send_count int)
LANGUAGE sql STABLE SET jit = off AS $$
  WITH ch AS (
    SELECT c.name, pgvigil.severity_rank(c.min_severity) AS floor, coalesce(c.instances, '{}') AS instances,
           coalesce(c.tags, '{}') AS tags, coalesce(c.repeat_secs, 0) AS repeat_secs,
           coalesce(c.clear_after_secs, 600) AS clear_after_secs, coalesce(c.recovery, true) AS recovery
      FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
           AS c(name text, min_severity text, instances text[], tags text[], repeat_secs int, clear_after_secs int, recovery boolean)
  ), sc AS (   -- every finding in a channel's scope, any severity
    SELECT DISTINCT ON (ch.name, f.finding_key) ch.name AS channel, ch.floor, f.*
      FROM ch JOIN pgvigil.alert_findings f ON pgvigil.alert_in_scope(f.instance, f.tags, ch.instances, ch.tags)
     ORDER BY ch.name, f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC
  ), m AS (    -- the ones at or above its floor that nothing holds
    SELECT * FROM sc WHERE pgvigil.severity_rank(sc.severity) >= sc.floor
       AND pgvigil.ack_hold(p_at, sc.instance, sc.tags, sc.finding_key, sc.source, sc.setting, sc.value) IS NULL
  ), s AS (
    SELECT st.*, ch.repeat_secs, ch.recovery, ch.clear_after_secs,
           i.is_active IS TRUE AS instance_active,
           EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = st.finding_key) AS present
      FROM pgvigil.alert_state st JOIN ch ON ch.name = st.channel
      LEFT JOIN pgvigil.instances i ON i.instance_id = st.instance_id
     WHERE st.cleared_at IS NULL
  )
  SELECT m.channel,
         CASE WHEN s.channel IS NULL THEN 'firing'
              WHEN pgvigil.severity_rank(m.severity) > pgvigil.severity_rank(s.severity) THEN 'escalated'
              ELSE 'repeat' END,
         m.finding_key, m.instance_id, m.instance, m.severity, m.source, m.setting, m.value, m.detail, m.suggested, m.at,
         s.first_sent_at, coalesce(s.send_count, 0)
    FROM m LEFT JOIN s ON s.channel = m.channel AND s.finding_key = m.finding_key
   WHERE s.channel IS NULL
      OR pgvigil.severity_rank(m.severity) > pgvigil.severity_rank(s.severity)
      OR (s.repeat_secs > 0 AND p_at - s.last_sent_at >= make_interval(secs => s.repeat_secs)
          AND NOT pgvigil.ack_alert_acked(p_at, m.finding_key))
  UNION ALL
  SELECT s.channel,
         CASE WHEN NOT s.instance_active OR s.present THEN 'cleared'          -- the instance left, or out of scope now
              WHEN s.recovery THEN 'resolved' ELSE 'cleared' END,
         s.finding_key, s.instance_id, s.instance_name, s.severity, s.source, s.setting, s.value, NULL, NULL, NULL,
         s.first_sent_at, s.send_count
    FROM s
   WHERE NOT EXISTS (SELECT 1 FROM sc WHERE sc.channel = s.channel AND sc.finding_key = s.finding_key)
     AND (NOT s.instance_active OR s.present
          OR (s.missing_since IS NOT NULL AND p_at - s.missing_since >= make_interval(secs => s.clear_after_secs)
              AND EXISTS (SELECT 1 FROM pgvigil.collection_dates d
                           WHERE d.instance_id = s.instance_id AND d.status = 'ok' AND d.snapshot_at > s.missing_since)))
  ORDER BY 1, 2, 6, 5
$$;

-- ack_time_ok: NULL or a text that reads as a timestamptz
CREATE OR REPLACE FUNCTION pgvigil.ack_time_ok(p text)
RETURNS boolean LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF p IS NULL THEN RETURN true; END IF;
  PERFORM p::timestamptz;
  RETURN true;
EXCEPTION WHEN OTHERS THEN
  RETURN false;
END $$;

-- import_ack: one attempt from the UI (the actions door's audit login). p_payload: {op: add|end, ui_user, client,
-- and for add: kind, instance_id, instance_name, check_key, finding_key, job_name, tag, match_text, note, seen_state,
-- starts_at, until, until_change; for end: ack_id}. Every attempt leaves an ack_log row; a refused one changes
-- nothing else. Returns {outcome, detail, ack_id}.
CREATE OR REPLACE FUNCTION pgvigil.import_ack(p_at timestamptz, p_payload jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
  v_op      text := p_payload->>'op';
  v_user    text := nullif(btrim(coalesce(p_payload->>'ui_user', '')), '');
  v_client  text := nullif(p_payload->>'client', '');
  v_kind    text := nullif(p_payload->>'kind', '');
  v_inst    text := nullif(p_payload->>'instance_name', '');
  v_id      bigint;
  v_why     text;
  v_row     pgvigil.acks;
BEGIN
  IF v_user IS NULL THEN
    RAISE EXCEPTION 'import_ack: no ui_user' USING ERRCODE = '22023';
  END IF;
  IF v_op = 'end' THEN
    v_id := (p_payload->>'ack_id')::bigint;
    SELECT * INTO v_row FROM pgvigil.acks WHERE ack_id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      v_why := format('no acknowledgement %s', v_id);
    ELSIF v_row.ended_at IS NOT NULL THEN
      v_why := format('acknowledgement %s was already ended by %s at %s', v_id, v_row.ended_by, v_row.ended_at);
    ELSE
      UPDATE pgvigil.acks SET ended_by = v_user, ended_at = p_at WHERE ack_id = v_id;
    END IF;
    INSERT INTO pgvigil.ack_log (at, ui_user, client, op, kind, ack_id, instance_name, outcome, detail, payload)
    VALUES (p_at, v_user, v_client, 'end', v_row.kind, v_id, v_row.instance_name,
            CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, coalesce(v_why, 'ended'), p_payload);
    RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                              'detail', coalesce(v_why, 'ended'), 'ack_id', v_id);
  ELSIF v_op IS DISTINCT FROM 'add' THEN
    v_why := 'op must be add or end';
  ELSIF v_kind IS NULL OR v_kind NOT IN ('ack', 'alert_ack', 'note', 'close', 'blackout', 'job', 'silence', 'mute', 'noise') THEN
    v_why := format('no such kind %L', v_kind);
  ELSIF NOT pgvigil.ack_time_ok(p_payload->>'until') OR NOT pgvigil.ack_time_ok(p_payload->>'starts_at') THEN
    v_why := 'until / starts_at is not a timestamp';
  ELSIF (p_payload->>'until') IS NOT NULL AND (p_payload->>'until')::timestamptz <= p_at THEN
    v_why := 'until is not in the future';
  ELSIF v_kind IN ('ack', 'job', 'silence', 'blackout') AND v_inst IS NULL THEN
    v_why := format('a %s names one instance', v_kind);
  ELSIF v_kind = 'silence' AND EXISTS (SELECT 1 FROM pgvigil.acks a WHERE a.kind = 'silence' AND a.instance_name = v_inst
                                          AND pgvigil.ack_live(a.ended_at, a.starts_at, a.until, p_at)) THEN
    v_why := format('%s is already silenced', v_inst);
  END IF;
  IF v_why IS NULL THEN
    BEGIN
      INSERT INTO pgvigil.acks (kind, instance_id, instance_name, check_key, finding_key, job_name, tag, match_text, note,
                                seen_state, starts_at, until, until_change, created_by, created_at, client)
      SELECT v_kind, x.instance_id, v_inst, nullif(x.check_key, ''), nullif(x.finding_key, ''), nullif(x.job_name, ''),
             nullif(x.tag, ''), nullif(btrim(coalesce(x.match_text, '')), ''), nullif(btrim(coalesce(x.note, '')), ''),
             nullif(x.seen_state, ''), x.starts_at, x.until, coalesce(x.until_change, false), v_user, p_at, v_client
        FROM jsonb_to_record(p_payload) AS x(instance_id int, check_key text, finding_key text, job_name text, tag text,
                                             match_text text, note text, seen_state text, starts_at timestamptz,
                                             until timestamptz, until_change boolean)
      RETURNING ack_id INTO v_id;
    EXCEPTION WHEN check_violation OR foreign_key_violation OR invalid_text_representation OR invalid_datetime_format
                   OR datetime_field_overflow THEN
      v_why := 'refused by the store: ' || SQLERRM;
    END;
  END IF;
  INSERT INTO pgvigil.ack_log (at, ui_user, client, op, kind, ack_id, instance_name, outcome, detail, payload)
  VALUES (p_at, v_user, v_client, 'add', v_kind, v_id, v_inst,
          CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END, coalesce(v_why, 'added'), p_payload);
  RETURN jsonb_build_object('outcome', CASE WHEN v_why IS NULL THEN 'done' ELSE 'refused' END,
                            'detail', coalesce(v_why, 'added'), 'ack_id', v_id);
END $$;
