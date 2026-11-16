-- 0144: Patroni depth (task 376). The rolechange collection's Patroni read (internal/collect/patroni.go): GET /cluster
-- on the instance's Patroni REST API (the patroni: block of the config - another port, https, a client certificate -
-- else http://<the dsn's host>:8008 while a Patroni session is connected), then GET /patroni on every member for what
-- /cluster lacks; with /cluster failing (the DCS down), the endpoint's own /patroni alone.
--   1. pg_patroni_read and pg_patroni_members (0103) gain each member's state: paused, pending restart and its reason,
--      failsafe mode holding the leader, when the member last reached the DCS, whether its own API answered, its
--      Patroni version; and what the checks age: the read's leader and since when there is none, since when the
--      cluster is paused, since when a member is down, since when a restart is pending, since when the read fails.
--   2. Five threshold keys (minutes, the pg_thresholds levels root / tag / instance), pgmonitor 5.3.0's Patroni rules
--      (crunchy-alert-rules-patroni.yml.example): patroni_no_leader (PatroniNoLeader: critical for 60 s),
--      patroni_member_down (PatroniPGIsRunning: critical for 60 s), patroni_paused (PatroniIsPaused: critical for
--      900 s), patroni_pending_restart (PatroniPendingRestart: warning for 1800 s), patroni_dcs_last_seen
--      (PatroniDCSLastSeen: warning over 300 s, critical over 1800 s).
--   3. import_patroni (the Patroni rows of a role read); import_rolechange again: 0103's role part as it was, word for
--      word, and its Patroni block replaced by a call of import_patroni with the read's Patroni rows (none = Patroni
--      is not there).
--   4. pg_patroni_clusters (one row per cluster: scope and system identifier, judged by ONE instance's read - the
--      lowest instance id among the fresh good reads - so a cluster read from three members is judged once);
--      pg_patroni_checks (the Summary's rows, check_group 'patroni') and pg_patroni_findings (the join UNION ALLs it
--      into pgvigil.findings).
-- Retention: the absent members are dropped past the retention by the purge line 0103 already has (0110 / 0190).

-- ---------------------------------------------------------------------------------------------------------------
-- 1. The tables' new columns
ALTER TABLE pgvigil.pg_patroni_read
  ADD COLUMN IF NOT EXISTS configured        boolean NOT NULL DEFAULT false,  -- the endpoint came from the patroni: block
  ADD COLUMN IF NOT EXISTS cluster_ok        boolean,                         -- /cluster answered (false: the endpoint's own /patroni only)
  ADD COLUMN IF NOT EXISTS paused            boolean,                         -- /cluster's pause (maintenance mode)
  ADD COLUMN IF NOT EXISTS paused_since      timestamptz,
  ADD COLUMN IF NOT EXISTS leader            text,                            -- the member in role leader / standby_leader
  ADD COLUMN IF NOT EXISTS no_leader_since   timestamptz,
  ADD COLUMN IF NOT EXISTS system_identifier text,                            -- a member's database_system_identifier
  ADD COLUMN IF NOT EXISTS last_ok_at        timestamptz,
  ADD COLUMN IF NOT EXISTS failing_since     timestamptz;

ALTER TABLE pgvigil.pg_patroni_members
  ADD COLUMN IF NOT EXISTS pending_restart        boolean,
  ADD COLUMN IF NOT EXISTS pending_restart_reason text,                       -- 'max_connections 100 -> 120, ...'
  ADD COLUMN IF NOT EXISTS pending_restart_since  timestamptz,
  ADD COLUMN IF NOT EXISTS dcs_last_seen          timestamptz,                -- the member's own /patroni (its clock)
  ADD COLUMN IF NOT EXISTS failsafe_active        boolean,                    -- failsafe mode holds the leader up
  ADD COLUMN IF NOT EXISTS paused                 boolean,                    -- the member's own view of the pause
  ADD COLUMN IF NOT EXISTS api_ok                 boolean,                    -- its own /patroni answered
  ADD COLUMN IF NOT EXISTS api_message            text,
  ADD COLUMN IF NOT EXISTS version                text,
  ADD COLUMN IF NOT EXISTS down_since             timestamptz,                -- first good read that found it gone or not running
  ADD COLUMN IF NOT EXISTS down_reason            text;
COMMENT ON COLUMN pgvigil.pg_patroni_members.snapshot_at IS 'the newest read that listed the member: for an absent member, when it was last seen';

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Threshold keys
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('patroni_no_leader',       'Patroni: no member holds the leader key',              'minutes', 'over', NULL, 1,    '{root,tag,instance}', 525600),
  ('patroni_member_down',     'Patroni: a member gone from the cluster or not running', 'minutes', 'over', NULL, 1,  '{root,tag,instance}', 525600),
  ('patroni_paused',          'Patroni: the cluster paused (no automatic failover)',  'minutes', 'over', NULL, 15,   '{root,tag,instance}', 525600),
  ('patroni_pending_restart', 'Patroni: a member waiting for a restart',              'minutes', 'over', 30,   NULL, '{root,tag,instance}', 525600),
  ('patroni_dcs_last_seen',   'Patroni: time since a member last reached its DCS',    'minutes', 'over', 5,    30,   '{root,tag,instance}', 525600)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- ---------------------------------------------------------------------------------------------------------------
-- 3. The imports
-- patroni_state_up: a member state that serves (Patroni 4.1's words: 'running' on a primary, 'streaming' on a replica
-- that streams, 'in archive recovery' on one fed by restore_command); every other state ('stopped', 'crashed',
-- 'starting', 'stopping', 'restarting', 'start failed', 'creating replica', ...) is not.
CREATE OR REPLACE FUNCTION pgvigil.patroni_state_up(p_state text) RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT coalesce(p_state IN ('running', 'streaming', 'in archive recovery'), false)
$$;

-- import_patroni: the Patroni rows of a role read (import_rolechange passes them).
-- payload rows: none (no Patroni session and no patroni: block: nothing to read), or {kind:'patroni_read'} once and,
-- when it is ok, {kind:'patroni'} per member - every member when /cluster answered (cluster_ok), else the endpoint's
-- own member alone (its /patroni: the DCS is down or /cluster failed otherwise; the read row's message says why).
CREATE OR REPLACE FUNCTION pgvigil.import_patroni(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  rd    jsonb;
  o     pgvigil.pg_patroni_read%ROWTYPE;
  v_ok  boolean;
  v_cok boolean;
  v_pau boolean;
  v_ldr text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_patroni'), p_instance_id);
  SELECT x INTO rd FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'patroni_read' LIMIT 1;
  IF rd IS NULL THEN
    -- Patroni is not (or no longer) on this server: nothing is judged, the members read before are not its state
    UPDATE pgvigil.pg_patroni_members SET is_present = false, down_since = NULL, down_reason = NULL, pending_restart_since = NULL
     WHERE instance_id = p_instance_id AND (is_present OR down_since IS NOT NULL);
    DELETE FROM pgvigil.pg_patroni_read WHERE instance_id = p_instance_id;
    RETURN;
  END IF;
  v_ok := coalesce((rd->>'ok')::boolean, false);
  v_cok := v_ok AND coalesce((rd->>'cluster_ok')::boolean, true);
  v_pau := coalesce((rd->>'paused')::boolean, false);
  v_ldr := nullif(rd->>'leader', '');
  SELECT * INTO o FROM pgvigil.pg_patroni_read WHERE instance_id = p_instance_id FOR UPDATE;
  IF v_ok THEN
    -- the leader is /cluster's: a read of the endpoint's own member keeps the last one read (a DCS outage is not a
    -- cluster without a leader: failsafe mode may hold it, the DCS check says so)
    INSERT INTO pgvigil.pg_patroni_read AS p (instance_id, snapshot_at, url, ok, message, scope, members, configured, cluster_ok, paused, paused_since,
                                              leader, no_leader_since, system_identifier, last_ok_at, failing_since)
    VALUES (p_instance_id, p_snapshot_at, rd->>'url', true, left(rd->>'message', 500), coalesce(rd->>'scope', o.scope), (rd->>'members')::int,
            coalesce((rd->>'configured')::boolean, false), v_cok,
            v_pau, CASE WHEN v_pau THEN coalesce(CASE WHEN o.paused THEN o.paused_since END, p_snapshot_at) END,
            CASE WHEN v_cok THEN v_ldr ELSE o.leader END,
            CASE WHEN NOT v_cok THEN o.no_leader_since WHEN v_ldr IS NULL THEN coalesce(o.no_leader_since, p_snapshot_at) END,
            -- a member's /patroni names it; none answered: the role read's own (pg_control_system), so two clusters
            -- under one common scope name stay apart
            coalesce(nullif(rd->>'system_identifier', ''), (SELECT rs.system_identifier FROM pgvigil.pg_role_state rs WHERE rs.instance_id = p_instance_id),
                     o.system_identifier), p_snapshot_at, NULL)
    ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, url = EXCLUDED.url, ok = true, message = EXCLUDED.message,
      scope = EXCLUDED.scope, members = EXCLUDED.members, configured = EXCLUDED.configured, cluster_ok = EXCLUDED.cluster_ok, paused = EXCLUDED.paused,
      paused_since = EXCLUDED.paused_since, leader = EXCLUDED.leader, no_leader_since = EXCLUDED.no_leader_since,
      system_identifier = EXCLUDED.system_identifier, last_ok_at = EXCLUDED.last_ok_at, failing_since = NULL;

    INSERT INTO pgvigil.pg_patroni_members AS m (instance_id, member, snapshot_at, scope, role, state, host, port, timeline, lag_bytes, lag_text, api_url,
                                                 is_present, pending_restart, pending_restart_reason, pending_restart_since, dcs_last_seen, failsafe_active,
                                                 paused, api_ok, api_message, version, down_since, down_reason)
    SELECT p_instance_id, x->>'member', p_snapshot_at, x->>'scope', x->>'role', x->>'state', x->>'host', (x->>'port')::int, (x->>'timeline')::bigint,
           (x->>'lag_bytes')::bigint, x->>'lag_text', x->>'api_url', true,
           coalesce((x->>'pending_restart')::boolean, false), left(x->>'pending_restart_reason', 500),
           CASE WHEN (x->>'pending_restart')::boolean THEN p_snapshot_at END,
           (x->>'dcs_last_seen')::timestamptz, (x->>'failsafe_active')::boolean, (x->>'paused')::boolean, (x->>'api_ok')::boolean,
           left(x->>'api_message', 500), x->>'version',
           CASE WHEN NOT pgvigil.patroni_state_up(x->>'state') THEN p_snapshot_at END,
           CASE WHEN NOT pgvigil.patroni_state_up(x->>'state') THEN 'state ' || coalesce(x->>'state', '(none)') END
      FROM (SELECT DISTINCT ON (x->>'member') x FROM jsonb_array_elements(p_payload) x
             WHERE x->>'kind' = 'patroni' AND coalesce(x->>'member', '') <> '') y
    ON CONFLICT (instance_id, member) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, scope = coalesce(EXCLUDED.scope, m.scope), role = EXCLUDED.role,
      state = EXCLUDED.state, host = coalesce(EXCLUDED.host, m.host), port = coalesce(EXCLUDED.port, m.port), timeline = EXCLUDED.timeline,
      lag_bytes = EXCLUDED.lag_bytes, lag_text = EXCLUDED.lag_text, api_url = coalesce(EXCLUDED.api_url, m.api_url), is_present = true,
      pending_restart = EXCLUDED.pending_restart, pending_restart_reason = EXCLUDED.pending_restart_reason,
      -- an age carries over from the read before only while the condition held then too (a failed read between
      -- them leaves it; a member gone from the cluster starts it again)
      pending_restart_since = CASE WHEN EXCLUDED.pending_restart THEN CASE WHEN m.pending_restart THEN coalesce(m.pending_restart_since, EXCLUDED.pending_restart_since)
                                                                          ELSE EXCLUDED.pending_restart_since END END,
      dcs_last_seen = EXCLUDED.dcs_last_seen, failsafe_active = EXCLUDED.failsafe_active, paused = EXCLUDED.paused, api_ok = EXCLUDED.api_ok,
      api_message = EXCLUDED.api_message, version = coalesce(EXCLUDED.version, m.version),
      down_since = CASE WHEN EXCLUDED.down_since IS NOT NULL THEN coalesce(CASE WHEN m.snapshot_at > EXCLUDED.snapshot_at - interval '7 days' THEN m.down_since END, EXCLUDED.down_since) END,
      down_reason = EXCLUDED.down_reason;

    IF v_cok THEN
      -- a member /cluster no longer lists: Patroni stopped there, or its member key expired in the DCS (ttl). Seen in
      -- the last 7 days = down (its down_since kept from the first read that missed it); older = absent, not down.
      UPDATE pgvigil.pg_patroni_members m SET is_present = false, pending_restart_since = NULL,
             down_since = CASE WHEN m.snapshot_at > p_snapshot_at - interval '7 days' THEN coalesce(m.down_since, p_snapshot_at) ELSE m.down_since END,
             down_reason = CASE WHEN m.snapshot_at > p_snapshot_at - interval '7 days' THEN 'gone from the cluster' ELSE m.down_reason END
       WHERE m.instance_id = p_instance_id AND m.snapshot_at < p_snapshot_at
         AND (m.is_present OR (m.snapshot_at > p_snapshot_at - interval '7 days'
                               AND (m.down_since IS NULL OR m.down_reason IS DISTINCT FROM 'gone from the cluster')));
    ELSE
      -- the endpoint's own member only: the others are not shown as the cluster's state, and nothing is said of them
      UPDATE pgvigil.pg_patroni_members m SET is_present = false WHERE m.instance_id = p_instance_id AND m.is_present AND m.snapshot_at < p_snapshot_at;
    END IF;
  ELSE
    -- the read failed (the row says why): the cluster's last good facts stay for the checks' names; the members are
    -- not shown as its state (0103's rule), and a failed read says nothing about them (down_since untouched)
    INSERT INTO pgvigil.pg_patroni_read AS p (instance_id, snapshot_at, url, ok, message, configured, cluster_ok, failing_since)
    VALUES (p_instance_id, p_snapshot_at, rd->>'url', false, left(rd->>'message', 500), coalesce((rd->>'configured')::boolean, false), false, p_snapshot_at)
    ON CONFLICT (instance_id) DO UPDATE SET snapshot_at = EXCLUDED.snapshot_at, url = EXCLUDED.url, ok = false, message = EXCLUDED.message,
      configured = EXCLUDED.configured, cluster_ok = false, failing_since = coalesce(CASE WHEN NOT p.ok THEN p.failing_since END, EXCLUDED.failing_since);
    UPDATE pgvigil.pg_patroni_members m SET is_present = false WHERE m.instance_id = p_instance_id AND m.is_present;
  END IF;
END $$;

-- import_rolechange: the role part below is 0103's (L408-478), unchanged; 0103's Patroni block (L480-503) is now
-- import_patroni, called with the read's Patroni rows. payload rows: {kind:'role'} once, {kind:'patroni_read'} and
-- {kind:'patroni'} when Patroni was asked.
CREATE OR REPLACE FUNCTION pgvigil.import_rolechange(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  r       jsonb;
  o       pgvigil.pg_role_state%ROWTYPE;
  v_rep   boolean;
  v_tl    bigint;
  v_sys   text;
  v_pm    timestamptz;
  v_now   timestamptz;
  v_hat   timestamptz;
  v_htl   bigint;
  v_kind  text;
  v_at    timestamptz;
  v_src   text;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_rolechange'), p_instance_id);
  SELECT x INTO r FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' = 'role' LIMIT 1;
  IF r IS NOT NULL THEN
    v_rep := (r->>'is_replica')::boolean;
    v_tl := (r->>'timeline_id')::bigint;
    v_sys := r->>'system_identifier';
    v_pm := (r->>'postmaster_start')::timestamptz;
    v_now := coalesce((r->>'server_now')::timestamptz, p_snapshot_at);
    v_hat := (r->>'history_at')::timestamptz;
    v_htl := (r->>'history_timeline')::bigint;
    SELECT * INTO o FROM pgvigil.pg_role_state WHERE instance_id = p_instance_id FOR UPDATE;
    IF o.instance_id IS NULL THEN
      INSERT INTO pgvigil.pg_role_state (instance_id, read_at, server_now, is_replica, timeline_id, timeline_source, system_identifier, postmaster_start,
                                         cluster_name, history_file, history_at, since, since_source, first_read_at)
      VALUES (p_instance_id, p_snapshot_at, v_now, v_rep, v_tl, r->>'timeline_source', v_sys, v_pm, r->>'cluster_name', r->>'history_file', v_hat,
              -- a primary on a timeline above 1 was promoted when its history file was written
              CASE WHEN NOT v_rep AND v_htl IS NOT NULL AND v_htl = v_tl THEN v_hat END,
              CASE WHEN NOT v_rep AND v_htl IS NOT NULL AND v_htl = v_tl THEN 'history file' END, p_snapshot_at);
    ELSE
      v_kind := CASE
        WHEN v_sys IS NOT NULL AND o.system_identifier IS NOT NULL AND v_sys <> o.system_identifier THEN 'another cluster'
        WHEN o.is_replica AND NOT v_rep THEN 'promotion'
        WHEN NOT o.is_replica AND v_rep THEN 'demotion'
        -- a standby's checkpoint timeline trails its replay: only a rise counts (from any source: the receiver restarts
        -- in a failover, so the source flips exactly then); a lower reading is the trailing one and is not kept
        WHEN v_tl IS NOT NULL AND o.timeline_id IS NOT NULL AND v_tl > o.timeline_id THEN 'timeline'
      END;
      IF v_kind IS NOT NULL THEN
        -- the time: the new timeline's history file when it was written between the two reads (the server's clock),
        -- else the postmaster's start when the server restarted between them, else this read
        IF v_kind IN ('promotion', 'timeline') AND v_htl IS NOT NULL AND v_htl = v_tl AND v_hat > coalesce(o.server_now, o.read_at) - interval '1 minute'
           AND v_hat <= v_now + interval '1 minute' THEN
          v_at := v_hat; v_src := 'history file';
        ELSIF v_pm IS DISTINCT FROM o.postmaster_start AND v_pm > coalesce(o.server_now, o.read_at) - interval '1 minute' AND v_pm <= v_now THEN
          v_at := v_pm; v_src := 'postmaster start';
        ELSE
          v_at := p_snapshot_at; v_src := 'read';
        END IF;
        INSERT INTO pgvigil.pg_role_changes (instance_id, changed_at, changed_at_source, detected_at, prev_read_at, change, from_role, to_role,
                                             from_timeline, to_timeline, from_system_identifier, to_system_identifier, postmaster_restarted, held_secs)
        VALUES (p_instance_id, v_at, v_src, p_snapshot_at, o.read_at, v_kind,
                CASE WHEN o.is_replica THEN 'standby' ELSE 'primary' END, CASE WHEN v_rep THEN 'standby' ELSE 'primary' END,
                o.timeline_id, v_tl, o.system_identifier, v_sys, v_pm IS DISTINCT FROM o.postmaster_start,
                CASE WHEN o.since IS NOT NULL THEN greatest(0, extract(epoch FROM v_at - o.since))::bigint END);
      END IF;
      UPDATE pgvigil.pg_role_state SET read_at = p_snapshot_at, server_now = v_now, is_replica = v_rep,
             timeline_id = CASE WHEN v_kind IN ('promotion', 'demotion', 'another cluster') THEN coalesce(v_tl, o.timeline_id) ELSE greatest(o.timeline_id, v_tl) END,
             timeline_source = r->>'timeline_source', system_identifier = coalesce(v_sys, o.system_identifier), postmaster_start = v_pm,
             cluster_name = r->>'cluster_name', history_file = r->>'history_file', history_at = v_hat,
             since = CASE WHEN v_kind IS NOT NULL THEN v_at ELSE o.since END,
             since_source = CASE WHEN v_kind IS NOT NULL THEN v_src ELSE o.since_source END
       WHERE instance_id = p_instance_id;
    END IF;
    PERFORM pgvigil.import_patroni(p_instance_id, p_snapshot_at,
            coalesce((SELECT jsonb_agg(x) FROM jsonb_array_elements(p_payload) x WHERE x->>'kind' IN ('patroni_read', 'patroni')), '[]'::jsonb));
  END IF;
END $$;

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Views
-- pg_patroni_clusters: one row per Patroni cluster (scope + system identifier) read well by an active instance in the
-- last 5 minutes, and the instance whose read judges it: among the reads within 120 s of the cluster's newest, a read
-- of the whole cluster (/cluster answered) before one of the endpoint's own member only, then the lowest instance id -
-- so the findings of a cluster read from each of its members stay on one instance from read to read, an instance cut
-- from the DCS does not hide what the others see, and an instance that stopped reading (its own server down) hands
-- over after 120 s. A cluster whose every read failed
-- or aged is not here (its instances' read rows say why: the 'patroni API not answering' check).
CREATE OR REPLACE VIEW pgvigil.pg_patroni_clusters AS
WITH r AS (
  SELECT p.*, i.name AS instance, max(p.snapshot_at) OVER w AS newest_at, count(*) OVER w AS read_by
    FROM pgvigil.pg_patroni_read p JOIN pgvigil.instances i ON i.instance_id = p.instance_id AND i.is_active
   WHERE p.ok AND p.snapshot_at > now() - interval '5 minutes'
  WINDOW w AS (PARTITION BY coalesce(p.scope, ''), coalesce(p.system_identifier, ''))
)
SELECT DISTINCT ON (coalesce(r.scope, ''), coalesce(r.system_identifier, ''))
       r.instance_id, r.instance, r.scope, r.system_identifier, r.url, r.configured, r.snapshot_at AS read_at, r.members, r.leader,
       r.no_leader_since, r.paused, r.paused_since, r.read_by
  FROM r
 WHERE r.snapshot_at >= r.newest_at - interval '120 seconds'
 ORDER BY coalesce(r.scope, ''), coalesce(r.system_identifier, ''), r.cluster_ok IS NOT TRUE, r.instance_id;

-- The Summary's rows (instance_id, severity, check_name, object, at, detail, check_group 'patroni'): warning and
-- critical only, each past its threshold (pg_threshold: both tiers NULL = off). An age is the read's time less the
-- time the condition was first read; 10 s of slack lets the second read of a 1-minute schedule count as 1 minute.
--   patroni no leader        no member in role leader or standby_leader (pgmonitor's PatroniNoLeader)
--   patroni member down      a member a good read no longer lists (seen in the last 7 days), or listed in a state
--                            that does not serve (stopped, crashed, start failed, ...) (PatroniPGIsRunning)
--   patroni paused           the cluster in maintenance mode: Patroni neither fails over nor restarts (PatroniIsPaused)
--   patroni pending restart  a member whose settings wait for a restart (PatroniPendingRestart)
--   patroni DCS not reached  a member whose last contact with the DCS is past the threshold (PatroniDCSLastSeen)
--   patroni API not answering  an instance whose Patroni read fails for 2 reads in a row, when the endpoint is
--                            configured or answered in the last 7 days (warning; pgvigil's own)
CREATE OR REPLACE VIEW pgvigil.pg_patroni_checks AS
WITH c AS (SELECT * FROM pgvigil.pg_patroni_clusters),
mem AS (
  SELECT c.read_at, m.*
    FROM c JOIN pgvigil.pg_patroni_members m ON m.instance_id = c.instance_id
),
-- a member's DCS contact from the newest read of it by any instance that reads the cluster (in a DCS outage each
-- instance reads its own member only), judged on the cluster's judging instance
dcs AS (
  SELECT DISTINCT ON (c.instance_id, m.member) c.instance_id, c.read_at, m.member, m.snapshot_at, m.dcs_last_seen, m.failsafe_active
    FROM pgvigil.pg_patroni_clusters c
    JOIN pgvigil.pg_patroni_read q ON q.ok AND q.snapshot_at > now() - interval '5 minutes'
                                  AND coalesce(q.scope, '') = coalesce(c.scope, '') AND coalesce(q.system_identifier, '') = coalesce(c.system_identifier, '')
    JOIN pgvigil.instances qi ON qi.instance_id = q.instance_id AND qi.is_active
    JOIN pgvigil.pg_patroni_members m ON m.instance_id = q.instance_id AND m.is_present AND m.dcs_last_seen IS NOT NULL
   ORDER BY c.instance_id, m.member, m.snapshot_at DESC
)
SELECT c.instance_id, CASE WHEN th.crit IS NOT NULL AND extract(epoch FROM c.read_at - c.no_leader_since) + 10 >= th.crit * 60 THEN 'critical' ELSE 'warning' END AS severity,
       'patroni no leader' AS check_name, coalesce(c.scope, '(no scope)') AS object, c.read_at AS at,
       'no member holds the leader key since ' || to_char(c.no_leader_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
       || CASE WHEN c.paused THEN '; the cluster is paused: Patroni elects no leader until it is resumed' ELSE '' END
       || ' (' || concat_ws(', ', 'warning ' || th.warn || ' min', 'critical ' || th.crit || ' min', th.level) || ')' AS detail, 'patroni' AS check_group
  FROM c CROSS JOIN LATERAL pgvigil.pg_threshold(c.instance_id, 'patroni_no_leader') th
 WHERE c.leader IS NULL AND c.no_leader_since IS NOT NULL AND coalesce(th.warn, th.crit) IS NOT NULL
   AND extract(epoch FROM c.read_at - c.no_leader_since) + 10 >= coalesce(th.warn, th.crit) * 60
UNION ALL
SELECT m.instance_id, CASE WHEN th.crit IS NOT NULL AND extract(epoch FROM m.read_at - m.down_since) + 10 >= th.crit * 60 THEN 'critical' ELSE 'warning' END,
       'patroni member down', m.member, m.read_at,
       CASE WHEN m.down_reason IS DISTINCT FROM 'gone from the cluster' THEN 'Patroni lists it ' || coalesce(m.state, '(no state)') || ' since ' || to_char(m.down_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
            ELSE 'gone from the cluster since ' || to_char(m.down_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC (its Patroni stopped or lost the DCS); last seen as '
                 || coalesce(m.role, '?') || ', ' || coalesce(m.state, '?') END
       || ' (' || concat_ws(', ', 'warning ' || th.warn || ' min', 'critical ' || th.crit || ' min', th.level) || ')', 'patroni'
  FROM mem m CROSS JOIN LATERAL pgvigil.pg_threshold(m.instance_id, 'patroni_member_down') th
 WHERE m.down_since IS NOT NULL AND m.snapshot_at > now() - interval '7 days' AND coalesce(th.warn, th.crit) IS NOT NULL
   AND extract(epoch FROM m.read_at - m.down_since) + 10 >= coalesce(th.warn, th.crit) * 60
UNION ALL
SELECT c.instance_id, CASE WHEN th.crit IS NOT NULL AND extract(epoch FROM c.read_at - c.paused_since) + 10 >= th.crit * 60 THEN 'critical' ELSE 'warning' END,
       'patroni paused', coalesce(c.scope, '(no scope)'), c.read_at,
       'maintenance mode since ' || to_char(c.paused_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC: no automatic failover, no restart of a stopped member'
       || ' (' || concat_ws(', ', 'warning ' || th.warn || ' min', 'critical ' || th.crit || ' min', th.level) || ')', 'patroni'
  FROM c CROSS JOIN LATERAL pgvigil.pg_threshold(c.instance_id, 'patroni_paused') th
 WHERE c.paused AND c.paused_since IS NOT NULL AND coalesce(th.warn, th.crit) IS NOT NULL
   AND extract(epoch FROM c.read_at - c.paused_since) + 10 >= coalesce(th.warn, th.crit) * 60
UNION ALL
SELECT m.instance_id, CASE WHEN th.crit IS NOT NULL AND extract(epoch FROM m.read_at - m.pending_restart_since) + 10 >= th.crit * 60 THEN 'critical' ELSE 'warning' END,
       'patroni pending restart', m.member, m.read_at,
       'pending since ' || to_char(m.pending_restart_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC' || coalesce(': ' || m.pending_restart_reason, '')
       || ' (' || concat_ws(', ', 'warning ' || th.warn || ' min', 'critical ' || th.crit || ' min', th.level) || ')', 'patroni'
  FROM mem m CROSS JOIN LATERAL pgvigil.pg_threshold(m.instance_id, 'patroni_pending_restart') th
 WHERE m.is_present AND m.pending_restart AND m.pending_restart_since IS NOT NULL AND coalesce(th.warn, th.crit) IS NOT NULL
   AND extract(epoch FROM m.read_at - m.pending_restart_since) + 10 >= coalesce(th.warn, th.crit) * 60
UNION ALL
SELECT m.instance_id, CASE WHEN th.crit IS NOT NULL AND extract(epoch FROM m.snapshot_at - m.dcs_last_seen) >= th.crit * 60 THEN 'critical' ELSE 'warning' END,
       'patroni DCS not reached', m.member, m.read_at,
       'last reached its DCS ' || CASE WHEN extract(epoch FROM m.snapshot_at - m.dcs_last_seen) < 120 THEN round(extract(epoch FROM m.snapshot_at - m.dcs_last_seen)) || ' s'
                                       ELSE round(extract(epoch FROM m.snapshot_at - m.dcs_last_seen) / 60) || ' min' END || ' before the read ('
       || to_char(m.dcs_last_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC, the member''s clock)'
       || CASE WHEN m.failsafe_active THEN '; failsafe mode keeps the leader running' ELSE '' END
       || ' (' || concat_ws(', ', 'warning ' || th.warn || ' min', 'critical ' || th.crit || ' min', th.level) || ')', 'patroni'
  FROM dcs m CROSS JOIN LATERAL pgvigil.pg_threshold(m.instance_id, 'patroni_dcs_last_seen') th
 WHERE m.dcs_last_seen IS NOT NULL AND coalesce(th.warn, th.crit) IS NOT NULL
   AND extract(epoch FROM m.snapshot_at - m.dcs_last_seen) >= coalesce(th.warn, th.crit) * 60
UNION ALL
SELECT p.instance_id, 'warning', 'patroni API not answering', p.url, p.snapshot_at,
       coalesce(p.message, 'no answer') || ' (failing since ' || to_char(p.failing_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'
       || coalesce('; the last good read ' || to_char(p.last_ok_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC', '; never read well') || ')', 'patroni'
  FROM pgvigil.pg_patroni_read p JOIN pgvigil.instances i ON i.instance_id = p.instance_id AND i.is_active
 WHERE NOT p.ok AND p.snapshot_at > now() - interval '1 hour' AND p.failing_since IS NOT NULL
   AND extract(epoch FROM p.snapshot_at - p.failing_since) + 10 >= 60
   AND (p.configured OR p.last_ok_at > now() - interval '7 days');

-- The findings arm (the findings columns): the checks above, plus one info row: Patroni runs on the server (a Patroni
-- session is connected) but its REST API was never read at the default endpoint (another port, https: the instance's
-- patroni: block names it).
CREATE OR REPLACE VIEW pgvigil.pg_patroni_findings AS
SELECT c.instance_id, c.severity, c.check_name AS setting, c.object || ': ' || c.detail AS value, true AS is_set,
       CASE c.check_name
         WHEN 'patroni no leader' THEN 'read patronictl list and the Patroni logs; a paused cluster elects no leader: patronictl resume'
         WHEN 'patroni member down' THEN 'start Patroni on the member (systemctl status patroni, its log); a member removed for good drops out after 7 days'
         WHEN 'patroni paused' THEN 'resume it when the maintenance is over: patronictl resume'
         WHEN 'patroni pending restart' THEN 'restart the member in a quiet window: patronictl restart <cluster> <member>'
         WHEN 'patroni DCS not reached' THEN 'check the DCS (etcd, Consul, ZooKeeper) and the network between the member and it'
         ELSE 'check the instance''s patroni: block (url, ca_file, cert_file / key_file) against Patroni''s restapi settings'
       END AS suggested, 'self-managed' AS platforms,
       CASE c.check_name
         WHEN 'patroni no leader' THEN 'without a leader the cluster takes no writes and nothing fails over'
         WHEN 'patroni member down' THEN 'a member down is a standby less to fail over to, or the primary itself'
         WHEN 'patroni paused' THEN 'a paused cluster does not fail over when its primary fails'
         WHEN 'patroni pending restart' THEN 'a setting changed in the cluster''s configuration is not in force until the restart'
         WHEN 'patroni DCS not reached' THEN 'a member that cannot reach the DCS cannot hold or take the leader key; a leader demotes itself unless failsafe mode holds it'
         ELSE 'while the API does not answer, Patroni''s state is not read: no leader and member down cannot be seen'
       END AS detail, 'patroni' AS source, c.at
  FROM pgvigil.pg_patroni_checks c
UNION ALL
SELECT p.instance_id, 'info', 'patroni API not found', p.url || ': ' || coalesce(p.message, 'no answer'), true,
       'name the REST API in the instance''s patroni: block (url https://<host>:<port>, ca_file) (docs/backups-postgres.md)', 'self-managed',
       'Patroni runs on the server but its REST API is not at the default http://<host>:8008: its state is not read', 'patroni', p.snapshot_at
  FROM pgvigil.pg_patroni_read p JOIN pgvigil.instances i ON i.instance_id = p.instance_id AND i.is_active
 WHERE NOT p.ok AND NOT p.configured AND p.last_ok_at IS NULL AND p.snapshot_at > now() - interval '1 hour';
