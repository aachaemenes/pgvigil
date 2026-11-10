-- 0059_alerts: alerts out (task 60). The collector's alert loop (internal/alerts: `pgvigil alerts` for one pass, and
-- the loop inside `pgvigil run`) reads the repository's findings and sends them to the channels the configuration's
-- alerts: list names (SMTP, a webhook, a file drop). Nothing is sent unless a channel is configured.
--
--   alert_channels      the channels as configured (the last sync of a sender): kind, the destination as shown (a
--                       webhook's host only, never its path or token), the severity floor, the instances and tags it
--                       covers, quiet hours, the repeat interval, recovery on or off; is_configured false once the
--                       configuration no longer names it.
--   alert_state         per channel and finding: first sent, last sent, the sends, the severity last sent, cleared
--                       (and the recovery message's time). One open row (cleared_at NULL) per channel and finding.
--   alert_log           every send attempt (monthly partitions on snapshot_at, the attempt's time): the channel, its
--                       destination, how many alerts it carried by event, the outcome (sent, failed, refused, cleared
--                       without a message, none: no channel configured) and the error text.
--   alert_finding_key(i, source, setting, value)   a finding's identity across reads: its instance, source, setting
--                       and value with every free-standing number replaced by '#', so "lowest 99.0 % over 9 samples"
--                       and "... over 10 samples" are one standing finding, while an index name's digits (idx1, idx2)
--                       stay apart.
--   alert_findings      pgvigil.findings of the active instances with the key, the instance's name and its tags.
--   alert_sent          per finding key: the open alert rows across channels (first sent, last sent, the channels).
--   findings_alerts     pgvigil.findings' rows with the alert columns (the Findings tab's sent / when / where column).
--
-- The collector's door (0008's contract: the collector login may not read the findings): three SECURITY DEFINER
-- functions, named import_* so apply_roles grants them to pgvigil_collector:
--   import_alert_channels(at, channels)   records the configured channels.
--   import_alert_due(at, channels)        returns what is due now per channel: 'firing' (a matching finding with no
--                                         open row), 'escalated' (its severity rose above the one sent), 'repeat' (the
--                                         repeat interval passed since the last send), 'resolved' (an open row whose
--                                         finding no longer matches; 'cleared' when the channel sends no recovery).
--                                         The sender sees the findings it is to send, nothing else.
--   import_alert_log(at, attempt)         records one attempt and, when it was sent (or cleared), the alert rows.
-- The partition parent alert_log and the retention of cleared alert_state rows are purge()'s, added at the wave's join.

CREATE TABLE IF NOT EXISTS pgvigil.alert_channels (
  name           text PRIMARY KEY CHECK (name ~ '^[a-z0-9][a-z0-9_.-]{0,62}$'),
  kind           text NOT NULL CHECK (kind IN ('smtp', 'webhook', 'file')),
  destination    text NOT NULL,
  min_severity   text NOT NULL CHECK (min_severity IN ('info', 'warning', 'critical')),
  instances      text[] NOT NULL DEFAULT '{}',
  tags           text[] NOT NULL DEFAULT '{}',
  quiet_hours    text,
  timezone       text,
  repeat_secs    int NOT NULL CHECK (repeat_secs >= 0),
  recovery       boolean NOT NULL,
  is_configured  boolean NOT NULL DEFAULT true,
  configured_at  timestamptz NOT NULL,
  updated_at     timestamptz NOT NULL
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
 WHERE s.cleared_at IS NULL
 GROUP BY s.finding_key;

CREATE OR REPLACE VIEW pgvigil.findings_alerts AS
SELECT f.*, a.first_sent_at AS alert_first_sent, a.last_sent_at AS alert_last_sent, a.sends AS alert_sends,
       a.channels AS alert_channels
  FROM pgvigil.findings f
  LEFT JOIN pgvigil.alert_sent a ON a.finding_key = pgvigil.alert_finding_key(f.instance_id, f.source, f.setting, f.value);

-- import_alert_channels: the configured channels (a JSON array), upserted; every other row is_configured false.
CREATE OR REPLACE FUNCTION pgvigil.import_alert_channels(p_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.alert_channels AS c (name, kind, destination, min_severity, instances, tags, quiet_hours, timezone,
                                           repeat_secs, recovery, is_configured, configured_at, updated_at)
  SELECT x.name, x.kind, x.destination, x.min_severity, coalesce(x.instances, '{}'), coalesce(x.tags, '{}'),
         nullif(x.quiet_hours, ''), nullif(x.timezone, ''), x.repeat_secs, x.recovery, true, p_at, p_at
    FROM jsonb_to_recordset(coalesce(p_payload, '[]'::jsonb)) AS x(name text, kind text, destination text, min_severity text,
         instances text[], tags text[], quiet_hours text, timezone text, repeat_secs int, recovery boolean)
  ON CONFLICT (name) DO UPDATE SET kind = EXCLUDED.kind, destination = EXCLUDED.destination,
    min_severity = EXCLUDED.min_severity, instances = EXCLUDED.instances, tags = EXCLUDED.tags,
    quiet_hours = EXCLUDED.quiet_hours, timezone = EXCLUDED.timezone, repeat_secs = EXCLUDED.repeat_secs,
    recovery = EXCLUDED.recovery, is_configured = true, updated_at = EXCLUDED.updated_at,
    configured_at = CASE WHEN c.is_configured THEN c.configured_at ELSE EXCLUDED.configured_at END;
  UPDATE pgvigil.alert_channels c SET is_configured = false, updated_at = p_at
   WHERE c.is_configured
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_payload, '[]'::jsonb)) e WHERE e->>'name' = c.name);
END $$;

-- import_alert_due: what each channel of p_channels (the ones out of their quiet hours: the sender decides) owes now.
-- A channel's scope: no instance and no tag listed = every instance; else an instance listed by name, or one holding
-- a listed tag in its written form (prod, env:prod). One row per channel and finding key (the most severe row of the
-- key when two rules share it).
CREATE OR REPLACE FUNCTION pgvigil.import_alert_due(p_at timestamptz, p_channels jsonb)
RETURNS TABLE (channel text, event text, finding_key text, instance_id int, instance text, severity text, source text,
               setting text, value text, detail text, suggested text, finding_at timestamptz, first_sent_at timestamptz,
               send_count int)
LANGUAGE sql STABLE AS $$
  WITH ch AS (
    SELECT c.name, pgvigil.severity_rank(c.min_severity) AS floor, coalesce(c.instances, '{}') AS instances,
           coalesce(c.tags, '{}') AS tags, coalesce(c.repeat_secs, 0) AS repeat_secs, coalesce(c.recovery, true) AS recovery
      FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
           AS c(name text, min_severity text, instances text[], tags text[], repeat_secs int, recovery boolean)
  ), m AS (
    SELECT DISTINCT ON (ch.name, f.finding_key) ch.name AS channel, f.*
      FROM ch JOIN pgvigil.alert_findings f
        ON pgvigil.severity_rank(f.severity) >= ch.floor
       AND ((cardinality(ch.instances) = 0 AND cardinality(ch.tags) = 0) OR f.instance = ANY (ch.instances) OR f.tags && ch.tags)
     ORDER BY ch.name, f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC
  ), s AS (
    SELECT st.*, ch.repeat_secs, ch.recovery
      FROM pgvigil.alert_state st JOIN ch ON ch.name = st.channel
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
  SELECT s.channel, CASE WHEN s.recovery THEN 'resolved' ELSE 'cleared' END, s.finding_key, s.instance_id, s.instance_name,
         s.severity, s.source, s.setting, s.value, NULL, NULL, NULL, s.first_sent_at, s.send_count
    FROM s
   WHERE NOT EXISTS (SELECT 1 FROM m WHERE m.channel = s.channel AND m.finding_key = s.finding_key)
  ORDER BY 1, 2, 6, 5
$$;

-- import_alert_log: one attempt {channel, kind, destination, outcome, error, items: [{event, finding_key, instance_id,
-- instance, severity, source, setting, value}]}; outcome sent (or cleared) moves the alert rows: firing opens one,
-- escalated and repeat stamp the open one, resolved and cleared close it.
CREATE OR REPLACE FUNCTION pgvigil.import_alert_log(p_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_outcome text := p_payload->>'outcome';
  v_chan    text := nullif(p_payload->>'channel', '');
  v_insts   int[];
BEGIN
  PERFORM pgvigil.ensure_month_partition('alert_log', p_at);
  CREATE TEMP TABLE pgv_alert_items ON COMMIT DROP AS
  SELECT x.event, x.finding_key, x.instance_id, x.instance, x.severity, x.source, x.setting, x.value
    FROM jsonb_to_recordset(coalesce(p_payload->'items', '[]'::jsonb))
         AS x(event text, finding_key text, instance_id int, instance text, severity text, source text, setting text, value text)
   WHERE x.finding_key IS NOT NULL AND x.event IN ('firing', 'escalated', 'repeat', 'resolved', 'cleared');
  SELECT array_agg(DISTINCT i.instance_id) INTO v_insts FROM pgv_alert_items i WHERE i.instance_id IS NOT NULL;
  INSERT INTO pgvigil.alert_log (snapshot_at, instance_id, channel, kind, destination, n_firing, n_repeat, n_resolved,
                                 outcome, error, keys)
  SELECT p_at, CASE WHEN cardinality(v_insts) = 1 THEN v_insts[1] END, v_chan, nullif(p_payload->>'kind', ''),
         nullif(p_payload->>'destination', ''),
         count(*) FILTER (WHERE i.event IN ('firing', 'escalated')), count(*) FILTER (WHERE i.event = 'repeat'),
         count(*) FILTER (WHERE i.event IN ('resolved', 'cleared')), v_outcome, left(nullif(p_payload->>'error', ''), 2000),
         coalesce(array_agg(i.finding_key ORDER BY i.finding_key) FILTER (WHERE i.finding_key IS NOT NULL), '{}')
    FROM (SELECT 1) one LEFT JOIN pgv_alert_items i ON true;
  IF v_chan IS NULL OR v_outcome NOT IN ('sent', 'cleared') THEN
    RETURN;   -- a failed or refused attempt moves nothing: the next pass owes the same alerts
  END IF;
  INSERT INTO pgvigil.alert_state AS s (channel, finding_key, instance_id, instance_name, source, setting, value, severity,
                                        first_sent_at, last_sent_at, send_count)
  SELECT v_chan, i.finding_key, i.instance_id, coalesce(i.instance, ''), i.source, i.setting, i.value, i.severity, p_at, p_at, 1
    FROM pgv_alert_items i WHERE i.event = 'firing'
  ON CONFLICT (channel, finding_key) WHERE cleared_at IS NULL DO UPDATE SET
    last_sent_at = EXCLUDED.last_sent_at, send_count = s.send_count + 1, severity = EXCLUDED.severity, value = EXCLUDED.value;
  UPDATE pgvigil.alert_state s SET last_sent_at = p_at, send_count = s.send_count + 1, severity = i.severity, value = i.value
    FROM pgv_alert_items i
   WHERE i.event IN ('escalated', 'repeat') AND s.channel = v_chan AND s.finding_key = i.finding_key AND s.cleared_at IS NULL;
  UPDATE pgvigil.alert_state s SET cleared_at = p_at, recovery_sent_at = CASE WHEN i.event = 'resolved' THEN p_at END
    FROM pgv_alert_items i
   WHERE i.event IN ('resolved', 'cleared') AND s.channel = v_chan AND s.finding_key = i.finding_key AND s.cleared_at IS NULL;
END $$;
