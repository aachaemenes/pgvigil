-- DRAFT of the join's alert_due with B24h's line 3 (scripts/b24h-join-lines.sql) in it: 0190's alert_due (L476-574 at
-- df95d278) with every term marked 'B24h line 3' - a proof of the line only, never a migration; applied after
-- scripts/b24h-join-draft-base.sql (lines 1, 2 and 7) by TestProbeAlertDueDraftOnAStore in its own transaction, rolled
-- back. The join (0300) re-creates alert_due whole with the marked terms in it: diff this file against 0190 L476-574.
CREATE OR REPLACE FUNCTION pgvigil.alert_due(p_at timestamptz, p_channels jsonb)
RETURNS TABLE (channel text, event text, finding_key text, instance_id int, instance text, severity text, source text,
               setting text, value text, detail text, suggested text, finding_at timestamptz, first_sent_at timestamptz,
               send_count int)
LANGUAGE sql STABLE SET jit = off AS $$
  WITH held AS MATERIALIZED (   -- task 201: the instances held under their collector's 'collector or network'
    SELECT instance_id FROM pgvigil.collector_held_instances
  ), forming AS MATERIALIZED (  -- task 201: the instances of a parent that may be forming
    SELECT DISTINCT instance_id FROM pgvigil.collector_forming
  ), slow_folds AS MATERIALIZED (  -- the slow-connect tier: the standing folds, read once a pass (0121 collector_slow_folds)
    SELECT kind, value, under_host, held FROM pgvigil.collector_slow_folds
  ), slow_held AS MATERIALIZED (   -- the members a standing fold holds (those at or under its level)
    SELECT DISTINCT m.instance_id FROM slow_folds f CROSS JOIN LATERAL unnest(f.held) AS m(instance_id)
  ), slow_under AS MATERIALIZED (  -- a server's fold under its collector's standing fold: held (a server two collectors
    -- fold - one alert key - only when it is under the fold of every one of them)
    SELECT value FROM slow_folds WHERE kind = 'target' GROUP BY value HAVING bool_and(under_host)
  ), slow_forming AS MATERIALIZED (  -- 3 or more of a collector's instances crossed in its newest minute: new ones wait
    SELECT instance_id FROM pgvigil.collector_slow_forming
  ), probe_judged AS MATERIALIZED (   -- B24h line 3: the judged instances, read once a pass (the review of the fold #1)
    SELECT collector_host, instance_id, host FROM pgvigil.collector_probe_judged
  ), probe_held AS MATERIALIZED (     -- B24h line 3: the probe findings a standing fold or a host row holds
    SELECT instance_id, setting FROM pgvigil.collector_probe_held
  ), probe_held_hosts AS MATERIALIZED (   -- B24h line 3: the host rows a standing fold holds
    SELECT host FROM pgvigil.collector_probe_held_hosts
  ), probe_parent_hosts AS MATERIALIZED (   -- B24h line 3: the hosts of instances held under 'collector or network'
    SELECT DISTINCT j.host FROM probe_judged j JOIN held ON held.instance_id = j.instance_id
  ), probe_under_slow AS MATERIALIZED (   -- B24h line 3: instances judged from a collector whose slow-connect host fold
    -- stands (kind 'host': its value is the collector host)
    SELECT DISTINCT j.instance_id FROM probe_judged j JOIN slow_folds f ON f.kind = 'host' AND f.value = j.collector_host
  ), probe_forming AS MATERIALIZED (  -- B24h line 3: 3 or more of a collector's instances crossed a slow round trip
    SELECT instance_id FROM pgvigil.collector_probe_forming
  ), probe_forming_hosts AS MATERIALIZED (   -- B24h line 3: 3 or more of a collector's hosts crossed a slow ping
    SELECT DISTINCT host FROM pgvigil.collector_probe_forming_hosts
  ), ch AS (
    SELECT c.name, pgvigil.severity_rank(c.min_severity) AS floor, coalesce(c.instances, '{}') AS instances,
           coalesce(c.tags, '{}') AS tags, coalesce(c.repeat_secs, 0) AS repeat_secs,
           coalesce(c.clear_after_secs, 600) AS clear_after_secs, coalesce(c.recovery, true) AS recovery,
           coalesce(c.repo_wide, true) AS repo_wide
      FROM jsonb_to_recordset(coalesce(p_channels, '[]'::jsonb))
           AS c(name text, min_severity text, instances text[], tags text[], repeat_secs int, clear_after_secs int, recovery boolean,
                repo_wide boolean)
  ), sc AS (   -- every finding in a channel's scope, any severity (a repository-wide one: every channel but a route's,
               -- task 310 - an application contact's route says repo_wide false)
    SELECT DISTINCT ON (ch.name, f.finding_key) ch.name AS channel, ch.floor, f.*
      FROM ch JOIN pgvigil.alert_findings f
        ON pgvigil.alert_in_scope(f.instance, f.tags, ch.instances, ch.tags) OR (f.source = 'pgvigil repository' AND ch.repo_wide)
     ORDER BY ch.name, f.finding_key, pgvigil.severity_rank(f.severity) DESC, f.at DESC
  ), m AS (    -- the ones at or above its floor that nothing holds
    SELECT * FROM sc WHERE pgvigil.severity_rank(sc.severity) >= sc.floor
       AND pgvigil.ack_hold(p_at, sc.instance, sc.tags, sc.finding_key, sc.source, sc.setting, sc.value) IS NULL
       AND NOT (pgvigil.collector_shared_cause(sc.source, sc.setting)
                AND EXISTS (SELECT 1 FROM held WHERE held.instance_id = sc.instance_id))
       AND NOT (sc.source = 'pgvigil collector' AND sc.setting = 'slow connect'
                AND EXISTS (SELECT 1 FROM slow_held WHERE slow_held.instance_id = sc.instance_id))
       AND NOT (sc.source = 'pgvigil repository' AND sc.setting = 'slow connects'
                AND EXISTS (SELECT 1 FROM slow_under WHERE slow_under.value = sc.value))
       -- B24h line 3: an instance's probe finding while collector_probe_held names it (under its collector's fold, or
       -- its ping rows under its host's row); a host's row while a standing fold holds the host or its instances are
       -- held under 'collector or network' (the B24h-1 review part b #2: a host row has no instance id)
       AND NOT (sc.source = 'pgvigil collector' AND sc.setting IN ('query round trip slow', 'ping slow', 'host not answering ping')
                AND EXISTS (SELECT 1 FROM probe_held h WHERE h.instance_id = sc.instance_id AND h.setting = sc.setting))
       AND NOT (sc.source = 'pgvigil repository' AND sc.setting IN ('ping slow', 'host not answering ping')
                AND (sc.value IN (SELECT host FROM probe_held_hosts) OR sc.value IN (SELECT host FROM probe_parent_hosts)))
       -- B24h line 3: the fold held while its collector's parent stands, or slow-connect's host fold for the same
       -- collector (one alert, not three: part b #8), and its members under slow-connect's fold
       AND NOT (sc.source = 'pgvigil repository' AND sc.setting = 'network slow from this collector'
                AND (EXISTS (SELECT 1 FROM pgvigil.collector_parent p WHERE p.host = sc.value)
                     OR EXISTS (SELECT 1 FROM slow_folds f WHERE f.kind = 'host' AND f.value = sc.value)))
       AND NOT (sc.source = 'pgvigil collector' AND sc.setting IN ('query round trip slow', 'ping slow', 'host not answering ping')
                AND EXISTS (SELECT 1 FROM probe_under_slow u WHERE u.instance_id = sc.instance_id))
  ), s AS (
    SELECT st.*, ch.repeat_secs, ch.recovery, ch.clear_after_secs,
           (i.is_active IS TRUE OR st.source = 'pgvigil repository') AS instance_active,
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
   WHERE CASE WHEN s.channel IS NULL   -- new: it waits while its instance's parent may be forming, or inside its window
              THEN NOT (pgvigil.collector_shared_cause(m.source, m.setting)
                        AND (EXISTS (SELECT 1 FROM forming WHERE forming.instance_id = m.instance_id)
                             OR (m.source = 'pgvigil collector' AND pgvigil.collector_in_window(m.instance_id, m.at))))
                   AND NOT (m.source = 'pgvigil collector' AND m.setting = 'slow connect'
                            AND EXISTS (SELECT 1 FROM slow_forming WHERE slow_forming.instance_id = m.instance_id))
                   -- B24h line 3: a new round trip or host ping row waits while B24h's fold may be forming (part b #5,
                   -- the review of the fold #4: the host row is the ping alert sent)
                   AND NOT (m.source = 'pgvigil collector' AND m.setting = 'query round trip slow'
                            AND EXISTS (SELECT 1 FROM probe_forming WHERE probe_forming.instance_id = m.instance_id))
                   AND NOT (m.source = 'pgvigil repository' AND m.setting = 'ping slow'
                            AND m.value IN (SELECT host FROM probe_forming_hosts))
              -- open: an escalation always; a repeat of a collector kind waits like a new one while its newest failure
              -- is inside a failing-together window (the instance released by an ok read, its finding standing until
              -- the next clean minute is written: a stale repeat just before its recovery) - deferred, never dropped
              ELSE pgvigil.severity_rank(m.severity) > pgvigil.severity_rank(s.severity)
                   OR (s.repeat_secs > 0 AND p_at - s.last_sent_at >= make_interval(secs => s.repeat_secs)
                       AND NOT pgvigil.ack_alert_acked(p_at, m.finding_key, s.first_sent_at)
                       AND NOT (m.source = 'pgvigil collector' AND pgvigil.collector_shared_cause(m.source, m.setting)
                                AND pgvigil.collector_in_window(m.instance_id, m.at)))
                   -- task 201 DONE-2 (N6): a repository-wide alert whose claim changed since its last send (a cut that
                   -- turned into a host not seen; a new cut while one stands): ONE repeat - alert_record stores the claim
                   -- it sent. An acknowledgement holds it, but for a NEWER event (collector_claim_newer), which passes
                   -- the ack as an escalation does
                   OR (m.source = 'pgvigil repository' AND s.why IS NOT NULL AND s.why IS DISTINCT FROM pgvigil.collector_claim(m.detail)
                       AND (NOT pgvigil.ack_alert_acked(p_at, m.finding_key, s.first_sent_at)
                            OR pgvigil.collector_claim_newer(pgvigil.collector_claim(m.detail), s.why))) END
  UNION ALL
  SELECT s.channel,
         CASE WHEN NOT s.instance_active OR s.present THEN 'cleared'          -- the instance left, or out of scope now
              WHEN s.recovery THEN 'resolved' ELSE 'cleared' END,
         s.finding_key, s.instance_id, s.instance_name, s.severity, s.source, s.setting, s.value, NULL, NULL, NULL,
         s.first_sent_at, s.send_count
    FROM s
   WHERE NOT EXISTS (SELECT 1 FROM sc WHERE sc.channel = s.channel AND sc.finding_key = s.finding_key)
     -- a collector's 'slow connects' is not 'resolved' while that collector's own 'collector or network' stands (its
     -- connects stopped being judged because it stopped, not because they got faster)
     AND NOT (s.source = 'pgvigil repository' AND s.setting = 'slow connects'
              AND EXISTS (SELECT 1 FROM pgvigil.collector_parent p WHERE p.host = s.value))
     -- B24h line 3: B24h's fold, and a host's rows of a collector whose parent stands, are not 'resolved' (part b #2,
     -- the review of the fold #3: the probes stopped with the collector, the host was not seen to recover)
     AND NOT (s.source = 'pgvigil repository' AND s.setting = 'network slow from this collector'
              AND EXISTS (SELECT 1 FROM pgvigil.collector_parent p WHERE p.host = s.value))
     AND NOT (s.source = 'pgvigil repository' AND s.setting IN ('ping slow', 'host not answering ping')
              AND EXISTS (SELECT 1 FROM pgvigil.collector_probe_host ph JOIN pgvigil.collector_heartbeat h USING (collector_id)
                           JOIN pgvigil.collector_parent p ON p.host = h.host WHERE ph.host = s.value))
     AND (NOT s.instance_active OR s.present
          OR (s.missing_since IS NOT NULL AND p_at - s.missing_since >= make_interval(secs => s.clear_after_secs)
              AND s.source = 'pgvigil repository')
          OR (s.missing_since IS NOT NULL AND p_at - s.missing_since >= make_interval(secs => s.clear_after_secs)
              AND NOT (pgvigil.collector_shared_cause(s.source, s.setting)
                       AND EXISTS (SELECT 1 FROM held WHERE held.instance_id = s.instance_id))
              AND EXISTS (SELECT 1 FROM pgvigil.collection_dates d
                           WHERE d.instance_id = s.instance_id AND d.status = 'ok' AND d.snapshot_at > s.missing_since)))
  ORDER BY 1, 2, 6, 5
$$;
