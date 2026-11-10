-- 0059_alerts: alerts out (task 60). The alert sender (internal/alerts: `pgvigil alerts` for one pass, and the loop
-- inside `pgvigil run`) reads the repository's findings and sends them to the channels the configuration's alerts:
-- list names (SMTP, a webhook, a file drop). Nothing is sent unless a channel is configured.
--
--   alert_channels      the channels as configured (the last sync of a sender): kind, the destination as shown (a
--                       webhook's host only, never its path or token), the severity floor, the instances and tags it
--                       covers, quiet hours, the repeat interval, the clear delay, recovery on or off; is_configured
--                       false once a sender's configuration no longer names it.
--   alert_state         per channel and finding: first sent, last sent, the sends, the severity last sent, missing
--                       since (the first pass that no longer saw the finding), cleared (and the recovery message's
--                       time). One open row (cleared_at NULL) per channel and finding.
--   alert_log           every send attempt (monthly partitions on snapshot_at, the attempt's time): the channel, its
--                       destination, how many alerts it carried by event, the outcome (sent, failed, refused, cleared
--                       without a message, none: no channel configured) and the error text.
--   alert_finding_key(i, source, setting, value)   a finding's identity across reads: its instance, source, setting
--                       and value with every free-standing number replaced by '#', so "lowest 99.0 % over 9 samples"
--                       and "... over 10 samples" are one standing finding, while an index name's digits (idx1, idx2)
--                       stay apart.
--   alert_findings      pgvigil.findings of the active instances with the key, the instance's name and its tags.
--   alert_sent          per finding key: the open alert rows of the configured channels (first sent, last sent, the
--                       channels).
--   findings_alerts     pgvigil.findings' rows with the alert columns (the Findings tab's alerted column).
--
-- The sender's role (the repository's access contract, 0008, keeps the collector away from other instances' data):
-- pgvigil_alerter, a member of pgvigil_reader (it reads the findings), with INSERT and UPDATE on alert_channels and
-- alert_state and INSERT on alert_log; a login IN ROLE pgvigil_alerter is the configuration's alerts_dsn (`pgvigil
-- roles` prints it). The collector login (pgvigil_collector) gets nothing here. The functions run as their caller
-- (apply_roles grants them to pgvigil_reader as well: a reader can call alert_due, which reads what it may read
-- anyway, and fails in the others for want of a write privilege). The one owner's door is alert_log_partition (SECURITY
-- DEFINER): it creates alert_log's partition for the month of a time within a day of now(), nothing else, and only
-- for a session user in pgvigil_alerter or in the schema's owner (apply_roles grants every function to
-- pgvigil_reader after each migrate, so the check is in the body, not in a REVOKE).
--   alert_channels_sync(at, channels)   records the configured channels.
--   alert_mark(at, channels)            stamps missing_since on the open rows whose finding left the view (on an
--                                       active instance), and clears the stamp of the ones that came back.
--   alert_due(at, channels)             what is due now per channel: 'firing' (a matching finding with no open row),
--                                       'escalated' (its severity rose above the one sent), 'repeat' (the repeat
--                                       interval passed since the last send), 'resolved' (the finding has been gone
--                                       for the channel's clear delay and the instance had an ok collection since it
--                                       went missing: an instance left unread holds its alerts; 'cleared' when the
--                                       channel sends no recovery),
--                                       and 'cleared' without a message when the instance left (inactive or removed)
--                                       or the channel's scope no longer covers it. A finding still present below the
--                                       channel's severity floor holds its open row: no repeat, no recovery.
--   alert_record(at, attempt)           records one attempt and, when it was sent (or cleared), moves the rows.
-- The partition parent alert_log and the retention of cleared alert_state rows are purge()'s, added at the wave's join.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_alerter') THEN
    CREATE ROLE pgvigil_alerter NOLOGIN;
  END IF;
END $$;
GRANT pgvigil_reader TO pgvigil_alerter;

CREATE TABLE IF NOT EXISTS pgvigil.alert_channels (
  name              text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_.-]{0,62}$'),
  kind              text NOT NULL CHECK (kind IN ('smtp', 'webhook', 'file')),
  destination       text NOT NULL,
  min_severity      text NOT NULL CHECK (min_severity IN ('info', 'warning', 'critical')),
  instances         text[] NOT NULL DEFAULT '{}',
  tags              text[] NOT NULL DEFAULT '{}',
  quiet_hours       text,
  timezone          text,
  repeat_secs       int NOT NULL CHECK (repeat_secs >= 0),
  clear_after_secs  int NOT NULL DEFAULT 600 CHECK (clear_after_secs >= 0),
  recovery          boolean NOT NULL,
  is_configured     boolean NOT NULL DEFAULT true,
  configured_at     timestamptz NOT NULL,
  updated_at        timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS pgvigil.alert_state (
  channel           text NOT NULL,
  finding_key       text NOT NULL,
  instance_id       int REFERENCES pgvigil.instances(instance_id) ON DELETE SET NULL,
  instance_name     text NOT NULL,
  source            text,
  setting           text,
  value             text,
  severity          text NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  first_sent_at     timestamptz NOT NULL,
  last_sent_at      timestamptz NOT NULL,
  send_count        int NOT NULL DEFAULT 1,
  missing_since     timestamptz,
  cleared_at        timestamptz,
  recovery_sent_at  timestamptz,
  PRIMARY KEY (channel, finding_key, first_sent_at)
);
CREATE UNIQUE INDEX IF NOT EXISTS alert_state_open_uq ON pgvigil.alert_state (channel, finding_key) WHERE cleared_at IS NULL;
CREATE INDEX IF NOT EXISTS alert_state_key_idx ON pgvigil.alert_state (finding_key) WHERE cleared_at IS NULL;

CREATE TABLE IF NOT EXISTS pgvigil.alert_log (
  snapshot_at   timestamptz NOT NULL,          -- the attempt
  instance_id   int,                           -- the instance when every alert of the attempt is one instance's
  channel       text,                          -- NULL: the 'none' row (no channel configured)
  kind          text,
  destination   text,
  n_firing      int NOT NULL DEFAULT 0,        -- firing and escalated
  n_repeat      int NOT NULL DEFAULT 0,
  n_resolved    int NOT NULL DEFAULT 0,        -- resolved and cleared
  outcome       text NOT NULL CHECK (outcome IN ('sent', 'failed', 'refused', 'cleared', 'none')),
  error         text,
  keys          text[] NOT NULL DEFAULT '{}'
) PARTITION BY RANGE (snapshot_at);

GRANT SELECT, INSERT, UPDATE ON pgvigil.alert_channels, pgvigil.alert_state TO pgvigil_alerter;
GRANT SELECT, INSERT ON pgvigil.alert_log TO pgvigil_alerter;

CREATE OR REPLACE FUNCTION pgvigil.severity_rank(p_severity text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_severity WHEN 'critical' THEN 3 WHEN 'warning' THEN 2 WHEN 'info' THEN 1 ELSE 0 END
$$;

CREATE OR REPLACE FUNCTION pgvigil.alert_finding_key(p_instance_id int, p_source text, p_setting text, p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT md5(p_instance_id::text || E'\x1f' || coalesce(p_source, '') || E'\x1f' || coalesce(p_setting, '') || E'\x1f' ||
             regexp_replace(coalesce(p_value, ''), '(?<![A-Za-z_0-9])[0-9]+([.,][0-9]+)*', '#', 'g'))
$$;

CREATE OR REPLACE VIEW pgvigil.alert_findings AS
SELECT pgvigil.alert_finding_key(f.instance_id, f.source, f.setting, f.value) AS finding_key,
       f.instance_id, i.name AS instance, coalesce(t.tags, '{}'::text[]) AS tags,
       f.severity, f.setting, f.value, f.suggested, f.detail, f.source, f.at
  FROM pgvigil.findings f
  JOIN pgvigil.instances i USING (instance_id)
  LEFT JOIN pgvigil.instance_tags_merged t USING (instance_id)
 WHERE i.is_active;

CREATE OR REPLACE VIEW pgvigil.alert_sent AS
SELECT s.finding_key, min(s.first_sent_at) AS first_sent_at, max(s.last_sent_at) AS last_sent_at,
       sum(s.send_count)::int AS sends, array_agg(DISTINCT s.channel ORDER BY s.channel) AS channels
  FROM pgvigil.alert_state s
  JOIN pgvigil.alert_channels c ON c.name = s.channel AND c.is_configured
 WHERE s.cleared_at IS NULL
 GROUP BY s.finding_key;

CREATE OR REPLACE VIEW pgvigil.findings_alerts AS
SELECT f.*, a.first_sent_at AS alert_first_sent, a.last_sent_at AS alert_last_sent, a.sends AS alert_sends,
       a.channels AS alert_channels
  FROM pgvigil.findings f
  LEFT JOIN pgvigil.alert_sent a ON a.finding_key = pgvigil.alert_finding_key(f.instance_id, f.source, f.setting, f.value);

-- alert_in_scope: a channel's instance and tag scope (no instance and no tag listed = every instance)
CREATE OR REPLACE FUNCTION pgvigil.alert_in_scope(p_instance text, p_tags text[], p_instances text[], p_scope_tags text[])
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT (cardinality(coalesce(p_instances, '{}')) = 0 AND cardinality(coalesce(p_scope_tags, '{}')) = 0)
      OR p_instance = ANY (coalesce(p_instances, '{}')) OR coalesce(p_tags, '{}') && coalesce(p_scope_tags, '{}')
$$;

-- alert_log_partition: the owner's door for alert_log's month partition, for a time within a day of now() only
CREATE OR REPLACE FUNCTION pgvigil.alert_log_partition(p_at timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp AS $$
BEGIN
  IF NOT (pg_has_role(session_user, 'pgvigil_alerter', 'MEMBER')
          OR pg_has_role(session_user, (SELECT n.nspowner FROM pg_namespace n WHERE n.nspname = 'pgvigil'), 'MEMBER')) THEN
    RAISE EXCEPTION 'alert_log_partition: % is not the alert sender', session_user USING ERRCODE = '42501';
  END IF;
  IF p_at IS NULL OR p_at < now() - interval '1 day' OR p_at > now() + interval '1 day' THEN
    RAISE EXCEPTION 'alert_log_partition: % is not within a day of now()', p_at;
  END IF;
  PERFORM pgvigil.ensure_month_partition('alert_log', p_at);
END $$;
GRANT EXECUTE ON FUNCTION pgvigil.alert_log_partition(timestamptz) TO pgvigil_alerter;

-- alert_channels_sync: the configured channels (a JSON array), upserted; every other row is_configured false. A
-- sender with no channel never calls it (a collector without an alerts: list leaves the channels as they are).
CREATE OR REPLACE FUNCTION pgvigil.alert_channels_sync(p_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.alert_channels AS c (name, kind, destination, min_severity, instances, tags, quiet_hours, timezone,
                                           repeat_secs, clear_after_secs, recovery, is_configured, configured_at, updated_at)
  SELECT x.name, x.kind, x.destination, x.min_severity, coalesce(x.instances, '{}'), coalesce(x.tags, '{}'),
         nullif(x.quiet_hours, ''), nullif(x.timezone, ''), x.repeat_secs, coalesce(x.clear_after_secs, 600), x.recovery,
         true, p_at, p_at
    FROM jsonb_to_recordset(coalesce(p_payload, '[]'::jsonb)) AS x(name text, kind text, destination text, min_severity text,
         instances text[], tags text[], quiet_hours text, timezone text, repeat_secs int, clear_after_secs int, recovery boolean)
  ON CONFLICT (name) DO UPDATE SET kind = EXCLUDED.kind, destination = EXCLUDED.destination,
    min_severity = EXCLUDED.min_severity, instances = EXCLUDED.instances, tags = EXCLUDED.tags,
    quiet_hours = EXCLUDED.quiet_hours, timezone = EXCLUDED.timezone, repeat_secs = EXCLUDED.repeat_secs,
    clear_after_secs = EXCLUDED.clear_after_secs, recovery = EXCLUDED.recovery, is_configured = true,
    updated_at = EXCLUDED.updated_at,
    configured_at = CASE WHEN c.is_configured THEN c.configured_at ELSE EXCLUDED.configured_at END;
  UPDATE pgvigil.alert_channels c SET is_configured = false, updated_at = p_at
   WHERE c.is_configured
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_payload, '[]'::jsonb)) e WHERE e->>'name' = c.name);
END $$;

-- alert_mark: per open row of the given channels, missing_since = the first pass that no longer saw its finding (an
-- active instance's finding gone from the view), NULL again when it is back
CREATE OR REPLACE FUNCTION pgvigil.alert_mark(p_at timestamptz, p_channels jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_names text[] := ARRAY(SELECT e->>'name' FROM jsonb_array_elements(coalesce(p_channels, '[]'::jsonb)) e);
BEGIN
  UPDATE pgvigil.alert_state s SET missing_since = p_at
   WHERE s.cleared_at IS NULL AND s.missing_since IS NULL AND s.channel = ANY (v_names)
     AND NOT EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = s.finding_key);
  UPDATE pgvigil.alert_state s SET missing_since = NULL
   WHERE s.cleared_at IS NULL AND s.missing_since IS NOT NULL AND s.channel = ANY (v_names)
     AND EXISTS (SELECT 1 FROM pgvigil.alert_findings f WHERE f.finding_key = s.finding_key);
END $$;

-- alert_due: what each channel of p_channels (the ones out of their quiet hours: the sender decides) owes now. One
-- row per channel and finding key (the most severe row of the key when two rules share it).
CREATE OR REPLACE FUNCTION pgvigil.alert_due(p_at timestamptz, p_channels jsonb)
RETURNS TABLE (channel text, event text, finding_key text, instance_id int, instance text, severity text, source text,
               setting text, value text, detail text, suggested text, finding_at timestamptz, first_sent_at timestamptz,
               send_count int)
LANGUAGE sql STABLE AS $$
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
  ), m AS (    -- the ones at or above its floor
    SELECT * FROM sc WHERE pgvigil.severity_rank(sc.severity) >= sc.floor
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
      OR (s.repeat_secs > 0 AND p_at - s.last_sent_at >= make_interval(secs => s.repeat_secs))
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
              -- and the collector read the instance since: a finding that left the view because its instance went
              -- unread (unreachable, the collector down, a time window running past the last sample) is held
              AND EXISTS (SELECT 1 FROM pgvigil.collection_dates d
                           WHERE d.instance_id = s.instance_id AND d.status = 'ok' AND d.snapshot_at > s.missing_since)))
  ORDER BY 1, 2, 6, 5
$$;

-- alert_record: one attempt {channel, kind, destination, outcome, error, items: [{event, finding_key, instance_id,
-- instance, severity, source, setting, value}]}; outcome sent (or cleared) moves the rows: firing opens one,
-- escalated and repeat stamp the open one, resolved and cleared close it.
CREATE OR REPLACE FUNCTION pgvigil.alert_record(p_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_outcome text := p_payload->>'outcome';
  v_chan    text := nullif(p_payload->>'channel', '');
  v_items   jsonb := coalesce(p_payload->'items', '[]'::jsonb);
BEGIN
  IF to_regclass('pgvigil.alert_log_' || to_char(date_trunc('month', p_at AT TIME ZONE 'UTC'), 'YYYYMM')) IS NULL THEN
    PERFORM pgvigil.alert_log_partition(p_at);   -- a past month's partition is the owner's to make (the demo's history)
  END IF;
  WITH i AS (
    SELECT x.event, x.finding_key, x.instance_id
      FROM jsonb_to_recordset(v_items) AS x(event text, finding_key text, instance_id int)
     WHERE x.finding_key IS NOT NULL AND x.event IN ('firing', 'escalated', 'repeat', 'resolved', 'cleared')
  ), insts AS (SELECT array_agg(DISTINCT i.instance_id) AS a FROM i WHERE i.instance_id IS NOT NULL)
  INSERT INTO pgvigil.alert_log (snapshot_at, instance_id, channel, kind, destination, n_firing, n_repeat, n_resolved,
                                 outcome, error, keys)
  SELECT p_at, CASE WHEN cardinality((SELECT a FROM insts)) = 1 THEN (SELECT a[1] FROM insts) END, v_chan,
         nullif(p_payload->>'kind', ''), nullif(p_payload->>'destination', ''),
         (SELECT count(*) FROM i WHERE i.event IN ('firing', 'escalated')), (SELECT count(*) FROM i WHERE i.event = 'repeat'),
         (SELECT count(*) FROM i WHERE i.event IN ('resolved', 'cleared')), v_outcome,
         left(nullif(p_payload->>'error', ''), 2000),
         coalesce((SELECT array_agg(i.finding_key ORDER BY i.finding_key) FROM i), '{}');
  IF v_chan IS NULL OR v_outcome NOT IN ('sent', 'cleared') THEN
    RETURN;   -- a failed or refused attempt moves nothing: the next pass owes the same alerts
  END IF;
  INSERT INTO pgvigil.alert_state AS s (channel, finding_key, instance_id, instance_name, source, setting, value, severity,
                                        first_sent_at, last_sent_at, send_count)
  SELECT v_chan, x.finding_key, x.instance_id, coalesce(x.instance, ''), x.source, x.setting, x.value, x.severity, p_at, p_at, 1
    FROM jsonb_to_recordset(v_items) AS x(event text, finding_key text, instance_id int, instance text, severity text,
                                          source text, setting text, value text)
   WHERE x.event = 'firing' AND x.finding_key IS NOT NULL
  ON CONFLICT (channel, finding_key) WHERE cleared_at IS NULL DO UPDATE SET
    last_sent_at = EXCLUDED.last_sent_at, send_count = s.send_count + 1, severity = EXCLUDED.severity, value = EXCLUDED.value,
    missing_since = NULL;
  UPDATE pgvigil.alert_state s SET last_sent_at = p_at, send_count = s.send_count + 1, severity = x.severity,
         value = x.value, missing_since = NULL
    FROM jsonb_to_recordset(v_items) AS x(event text, finding_key text, severity text, value text)
   WHERE x.event IN ('escalated', 'repeat') AND s.channel = v_chan AND s.finding_key = x.finding_key AND s.cleared_at IS NULL;
  UPDATE pgvigil.alert_state s SET cleared_at = p_at, recovery_sent_at = CASE WHEN x.event = 'resolved' THEN p_at END
    FROM jsonb_to_recordset(v_items) AS x(event text, finding_key text)
   WHERE x.event IN ('resolved', 'cleared') AND s.channel = v_chan AND s.finding_key = x.finding_key AND s.cleared_at IS NULL;
END $$;

GRANT EXECUTE ON FUNCTION pgvigil.alert_channels_sync(timestamptz, jsonb), pgvigil.alert_mark(timestamptz, jsonb),
  pgvigil.alert_due(timestamptz, jsonb), pgvigil.alert_record(timestamptz, jsonb), pgvigil.severity_rank(text),
  pgvigil.alert_finding_key(int, text, text, text), pgvigil.alert_in_scope(text, text[], text[], text[]) TO pgvigil_alerter;
