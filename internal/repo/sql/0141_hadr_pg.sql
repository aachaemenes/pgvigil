-- 0141 hadr_pg: PostgreSQL streaming replication health (the HA build, tasks 370-372 and 374; the replication collection
-- of internal/collect/replication.go). This file's rules live in PostgreSQL's own views (0006's replication_checks and
-- 0103's pg_backups_checks / pg_backups_findings, re-created here with their arms kept); 0118's darling_alert_findings is
-- not touched.
--   task 370 (a)  a base backup's senders (state 'backup', or application_name pg_basebackup / pg_rewind: pgwatch 6.1.0's
--                 rule, metrics.yaml L1980) are no standby: 'sender not streaming' and the replay-lag check leave them out,
--                 and they are never a link
--   task 370 (b)  'receiver down' (the standby's side): in recovery, primary_conninfo set and no WAL receiver for 2 reads
--                 in a row - warning while replay still advances through restore_command, critical when it has not moved
--                 since the receiver went down or for the 'restore_stall' threshold (pgvigil's own default 5 minutes);
--                 'standby gone' (the sending side): a physical link this server sent to in the last 7 days with no sender
--                 for 2 reads in a row - critical. Both are left to the provider on a managed platform (RDS, Aurora, Azure,
--                 Cloud SQL, AlloyDB). Before this file such a standby raised nothing until the file-fed rule's 60 minutes
--                 (0103's 'log shipping' arm), and never on a managed platform; that arm now leaves out a standby with
--                 primary_conninfo set ('receiver down' judges it).
-- The collector adds a 'standby' row (the server in recovery: its receiver, primary_conninfo / restore_command set,
-- positions, replay pause) and each sender's slot (name, type). import_replication keeps two small state tables from them.

INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('restore_stall', 'Receiver down: replay through restore_command stopped for', 'minutes', 'over', NULL, 5, '{root,tag,instance}', 1440)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- pg_repl_standby_state: one row per instance, the newest read of its recovery state. down_reads counts the reads in a row
-- with the receiver down (in recovery, primary_conninfo set, no WAL receiver); replay_moved_at is the newest read whose
-- replay position was past the read before it.
CREATE TABLE IF NOT EXISTS pgvigil.pg_repl_standby_state (
  instance_id        int PRIMARY KEY,
  read_at            timestamptz NOT NULL,
  in_recovery        boolean NOT NULL,
  has_receiver       boolean,
  conninfo_set       boolean,          -- NULL: the login cannot read primary_conninfo (pg_read_all_settings, in pg_monitor)
  restore_set        boolean,
  primary_slot       text,
  min_apply_delay_ms bigint,
  receive_lsn        pg_lsn,
  replay_lsn         pg_lsn,
  prev_replay_lsn    pg_lsn,
  replay_moved_at    timestamptz,
  last_replay_at     timestamptz,
  replay_paused      boolean,
  down_reads         int NOT NULL DEFAULT 0,
  down_since         timestamptz
);

-- pg_repl_link_seen: the physical links a server sends WAL to (a standby, pg_receivewal, Barman), by link: 'slot:<name>'
-- when the sender holds a physical slot, else 'app:<application_name>', with '@<address>' when the name is the default
-- one (walreceiver, pg_receivewal, empty) and so says nothing of which standby it is. gone_reads counts the reads in a row
-- with no sender for the link; a link not seen for 7 days is dropped, and a role change of the server drops its links.
CREATE TABLE IF NOT EXISTS pgvigil.pg_repl_link_seen (
  instance_id      int NOT NULL,
  link             text NOT NULL,
  application_name text,
  client_addr      text,
  slot_name        text,
  first_seen       timestamptz NOT NULL,
  last_seen        timestamptz NOT NULL,
  checked_at       timestamptz NOT NULL,
  last_state       text,
  gone_reads       int NOT NULL DEFAULT 0,
  gone_since       timestamptz,
  PRIMARY KEY (instance_id, link)
);

CREATE OR REPLACE FUNCTION pgvigil.import_replication(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_sb          jsonb;      -- the 'standby' row: NULL on a server not in recovery
  v_sb_failed   boolean;
  v_snd_failed  boolean;
  v_prev        pgvigil.pg_repl_standby_state%ROWTYPE;
  v_had         boolean;
  v_in_rec      boolean;
  v_down        boolean;
  v_replay      pg_lsn;
BEGIN
  PERFORM pgvigil.ensure_month_partition('replication_sample', p_snapshot_at);
  INSERT INTO pgvigil.replication_sample (instance_id, snapshot_at, kind, key, state, lag_bytes, lag_secs, active, detail)
  SELECT p_instance_id, p_snapshot_at, r->>'kind',
         CASE r->>'kind'
           WHEN 'sender'         THEN coalesce(r->>'application_name', '') || '@' || coalesce(r->>'client_addr', '') || '#' || coalesce(r->>'pid', '')
           WHEN 'receiver'       THEN coalesce(r->>'slot_name', r->>'sender_host', 'receiver')
           WHEN 'standby'        THEN 'recovery'
           WHEN 'slot'           THEN r->>'slot_name'
           WHEN 'subscription'   THEN coalesce(r->>'datname', '') || ':' || coalesce(r->>'subname', '')
           WHEN 'publication'    THEN r->>'pubname'
           WHEN 'conflict'       THEN r->>'datname'
           WHEN 'aurora_replica' THEN r->>'server_id'
           ELSE coalesce(r->>'pid', '?') END,
         CASE r->>'kind'
           WHEN 'sender'         THEN r->>'state'
           WHEN 'receiver'       THEN r->>'status'
           WHEN 'standby'        THEN CASE WHEN (r->>'has_receiver')::boolean THEN 'receiving'
                                           WHEN (r->>'conninfo_set')::boolean THEN 'receiver down'
                                           WHEN (r->>'restore_set')::boolean THEN 'file-fed'
                                           ELSE 'no WAL source' END
           WHEN 'slot'           THEN r->>'wal_status'
           WHEN 'subscription'   THEN CASE WHEN (r->>'enabled')::boolean THEN 'enabled' ELSE 'disabled' END
           WHEN 'aurora_replica' THEN r->>'session_id'
           ELSE NULL END,
         CASE r->>'kind'
           WHEN 'sender'  THEN (r->>'replay_lag_bytes')::bigint
           WHEN 'standby' THEN (r->>'replay_lag_bytes')::bigint
           WHEN 'slot'    THEN (r->>'retained_bytes')::bigint
           ELSE NULL END,
         CASE r->>'kind'
           WHEN 'sender'         THEN (r->>'replay_lag_secs')::float8
           WHEN 'receiver'       THEN (r->>'replay_delay_secs')::float8
           WHEN 'aurora_replica' THEN (r->>'replica_lag_in_msec')::float8 / 1000.0
           ELSE NULL END,
         CASE r->>'kind'
           WHEN 'sender'       THEN (r->>'state') = 'streaming'
           WHEN 'standby'      THEN (r->>'has_receiver')::boolean
           WHEN 'slot'         THEN (r->>'active')::boolean
           WHEN 'subscription' THEN (r->>'enabled')::boolean
           ELSE NULL END,
         r
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' <> 'collector_error';

  -- a kind that could not be read is reported by the collector as status 'partial' through
  -- log_collection (collection_dates and collection_log); replication_checks lists it. A failed read changes no state.
  v_sb_failed  := EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'standby');
  v_snd_failed := EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'senders');
  SELECT r INTO v_sb FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'standby' LIMIT 1;
  v_in_rec := v_sb IS NOT NULL;

  SELECT * INTO v_prev FROM pgvigil.pg_repl_standby_state WHERE instance_id = p_instance_id FOR UPDATE;
  v_had := FOUND;
  IF v_had AND p_snapshot_at <= v_prev.read_at THEN
    RETURN;   -- a read older than the state: its samples are stored, the state stays the newer read's
  END IF;

  IF NOT v_sb_failed THEN
    -- a role change (a promotion, or a primary rejoined as a standby): the links it sent to are no longer expected
    IF v_had AND v_prev.in_recovery IS DISTINCT FROM v_in_rec THEN
      DELETE FROM pgvigil.pg_repl_link_seen WHERE instance_id = p_instance_id;
    END IF;
    v_down   := v_in_rec AND NOT coalesce((v_sb->>'has_receiver')::boolean, false) AND coalesce((v_sb->>'conninfo_set')::boolean, false);
    v_replay := (v_sb->>'replay_lsn')::pg_lsn;
    INSERT INTO pgvigil.pg_repl_standby_state AS s
           (instance_id, read_at, in_recovery, has_receiver, conninfo_set, restore_set, primary_slot, min_apply_delay_ms,
            receive_lsn, replay_lsn, prev_replay_lsn, replay_moved_at, last_replay_at, replay_paused, down_reads, down_since)
    VALUES (p_instance_id, p_snapshot_at, v_in_rec, (v_sb->>'has_receiver')::boolean, (v_sb->>'conninfo_set')::boolean,
            (v_sb->>'restore_set')::boolean, nullif(v_sb->>'primary_slot_name', ''), (v_sb->>'min_apply_delay_ms')::bigint,
            (v_sb->>'receive_lsn')::pg_lsn, v_replay, NULL, NULL, (v_sb->>'last_replay_at')::timestamptz,
            (v_sb->>'replay_paused')::boolean, CASE WHEN v_down THEN 1 ELSE 0 END, CASE WHEN v_down THEN p_snapshot_at END)
    ON CONFLICT (instance_id) DO UPDATE SET
      read_at = EXCLUDED.read_at, in_recovery = EXCLUDED.in_recovery, has_receiver = EXCLUDED.has_receiver,
      conninfo_set = EXCLUDED.conninfo_set, restore_set = EXCLUDED.restore_set, primary_slot = EXCLUDED.primary_slot,
      min_apply_delay_ms = EXCLUDED.min_apply_delay_ms, receive_lsn = EXCLUDED.receive_lsn, replay_lsn = EXCLUDED.replay_lsn,
      prev_replay_lsn = CASE WHEN EXCLUDED.in_recovery AND s.in_recovery THEN s.replay_lsn END,
      replay_moved_at = CASE WHEN NOT EXCLUDED.in_recovery THEN NULL
                             WHEN s.in_recovery AND s.replay_lsn IS NOT NULL AND EXCLUDED.replay_lsn > s.replay_lsn THEN EXCLUDED.read_at
                             WHEN s.in_recovery THEN s.replay_moved_at END,
      last_replay_at = EXCLUDED.last_replay_at, replay_paused = EXCLUDED.replay_paused,
      down_reads = CASE WHEN EXCLUDED.down_reads = 1 THEN s.down_reads + 1 ELSE 0 END,
      down_since = CASE WHEN EXCLUDED.down_reads = 1 THEN coalesce(s.down_since, EXCLUDED.read_at) END;
  END IF;

  IF NOT v_snd_failed THEN
    -- the physical links of this read (a base backup, pg_rewind and a logical slot's sender are no link)
    INSERT INTO pgvigil.pg_repl_link_seen AS l
           (instance_id, link, application_name, client_addr, slot_name, first_seen, last_seen, checked_at, last_state, gone_reads, gone_since)
    SELECT DISTINCT ON (x.link) p_instance_id, x.link, x.app, x.addr, x.slot, p_snapshot_at, p_snapshot_at, p_snapshot_at, x.state, 0, NULL::timestamptz
      FROM (SELECT CASE WHEN r->>'slot_name' IS NOT NULL THEN 'slot:' || (r->>'slot_name')
                        WHEN coalesce(r->>'application_name', '') IN ('', 'walreceiver', 'pg_receivewal')
                          THEN 'app:' || coalesce(r->>'application_name', '') || '@' || coalesce(r->>'client_addr', 'local')
                        ELSE 'app:' || (r->>'application_name') END AS link,
                   r->>'application_name' AS app, r->>'client_addr' AS addr, r->>'slot_name' AS slot, r->>'state' AS state
              FROM jsonb_array_elements(p_payload) r
             WHERE r->>'kind' = 'sender'
               AND coalesce(r->>'state', '') <> 'backup'
               AND coalesce(r->>'application_name', '') NOT IN ('pg_basebackup', 'pg_rewind')
               AND coalesce(r->>'slot_type', 'physical') = 'physical') x
     ORDER BY x.link, (x.state = 'streaming') DESC
    ON CONFLICT (instance_id, link) DO UPDATE SET
      application_name = EXCLUDED.application_name, client_addr = EXCLUDED.client_addr, slot_name = EXCLUDED.slot_name,
      last_seen = EXCLUDED.last_seen, checked_at = EXCLUDED.checked_at, last_state = EXCLUDED.last_state, gone_reads = 0, gone_since = NULL;
    UPDATE pgvigil.pg_repl_link_seen
       SET gone_reads = gone_reads + 1, gone_since = coalesce(gone_since, p_snapshot_at), checked_at = p_snapshot_at
     WHERE instance_id = p_instance_id AND checked_at < p_snapshot_at;
    DELETE FROM pgvigil.pg_repl_link_seen WHERE instance_id = p_instance_id AND last_seen < p_snapshot_at - interval '7 days';
  END IF;
END $$;

-- pg_hadr_checks: the streaming replication rules of this file, one row per finding (instance_id, severity, check_name,
-- object, at, detail, reads, stable). detail is the newest read's account (the Summary and the Replication page);
-- stable is the text the findings carry, fixed while the fault lasts: an alert is keyed by its finding's value, so a
-- text that changed every read would close and open an alert each minute. A read older than 30 minutes raises nothing (the Collections page says the collection is
-- stale); a managed platform's standbys are the provider's.
CREATE OR REPLACE VIEW pgvigil.pg_hadr_checks AS
SELECT s.instance_id,
       CASE WHEN s.replay_moved_at IS NULL OR s.replay_moved_at <= s.down_since
                 OR (th.crit IS NOT NULL AND s.replay_moved_at < s.read_at - make_interval(secs => th.crit * 60))
            THEN 'critical' ELSE 'warning' END AS severity,
       'receiver down'::text AS check_name, coalesce('slot ' || s.primary_slot, 'primary_conninfo') AS object, s.read_at AS at,
       format('in recovery with primary_conninfo set and no WAL receiver for %s reads in a row (since %s UTC); %s',
              s.down_reads, to_char(s.down_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
              CASE WHEN s.replay_moved_at IS NULL OR s.replay_moved_at <= s.down_since
                     THEN 'replay has not moved since the receiver went down' || CASE WHEN s.restore_set THEN ' (restore_command finds nothing new)' ELSE ' (no restore_command)' END
                   WHEN th.crit IS NOT NULL AND s.replay_moved_at < s.read_at - make_interval(secs => th.crit * 60)
                     THEN 'replay has stopped: it last moved ' || to_char(s.replay_moved_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC (critical after ' || trim_scale(th.crit) || ' min, ' || th.level || ')'
                   ELSE 'replay still advances through restore_command (last moved ' || to_char(s.replay_moved_at AT TIME ZONE 'UTC', 'HH24:MI:SS') || ' UTC): the standby follows whole WAL files, not the stream'
              END || CASE WHEN s.replay_paused THEN '; replay is paused' ELSE '' END) AS detail,
       s.down_reads AS reads,
       format('no WAL receiver since %s UTC while primary_conninfo is set', to_char(s.down_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')) AS stable
  FROM pgvigil.pg_repl_standby_state s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
  CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'restore_stall') th
 WHERE s.in_recovery AND s.conninfo_set AND NOT coalesce(s.has_receiver, false) AND s.down_reads >= 2
   AND s.read_at > now() - interval '30 minutes'
   AND i.platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')
UNION ALL
SELECT l.instance_id, 'critical', 'standby gone',
       coalesce(nullif(l.application_name, ''), '(no name)') || coalesce(' at ' || l.client_addr, '') || coalesce(' (slot ' || l.slot_name || ')', ''),
       l.checked_at,
       format('streamed from this server until %s UTC and has had no WAL sender for %s reads in a row: the standby is stopped, cut off or no longer replicating',
              to_char(l.last_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'), l.gone_reads),
       l.gone_reads,
       format('no WAL sender since %s UTC (it last streamed %s UTC)', to_char(l.gone_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
              to_char(l.last_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'))
  FROM pgvigil.pg_repl_link_seen l
  JOIN pgvigil.instances i ON i.instance_id = l.instance_id AND i.is_active
 WHERE l.gone_reads >= 2 AND l.last_seen > now() - interval '7 days' AND l.checked_at > now() - interval '30 minutes'
   AND i.platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')
   -- the same standby back under another link (a slot added or dropped, a default name from a new address) is no gap
   AND NOT EXISTS (SELECT 1 FROM pgvigil.pg_repl_link_seen o
                    WHERE o.instance_id = l.instance_id AND o.link <> l.link AND o.gone_reads = 0
                      AND ((l.slot_name IS NOT NULL AND o.slot_name = l.slot_name)
                           OR (coalesce(l.application_name, '') NOT IN ('', 'walreceiver', 'pg_receivewal') AND o.application_name = l.application_name)));

-- 0006's daily-check view again with a severity column at its end (the Summary's 'replication' overview and the
-- Replication page read it): a base backup's senders out of 'sender not streaming' and the replay-lag check (task 370 a),
-- and pg_hadr_checks' rows (value = the reads in a row, state = the finding's detail).
CREATE OR REPLACE VIEW pgvigil.replication_checks AS
  SELECT instance_id, snapshot_at, 'inactive slot retaining WAL' AS check_name, key AS object,
         lag_bytes AS value, 'bytes' AS unit, detail->>'wal_status' AS state, 'warning'::text AS severity
    FROM pgvigil.replication_latest
   WHERE kind = 'slot' AND NOT coalesce(active, false) AND coalesce(lag_bytes, 0) > 0
     AND NOT coalesce((detail->>'synced')::boolean, false)      -- a failover slot synced from the primary is always inactive on a PG17 standby
  UNION ALL
  SELECT instance_id, snapshot_at, 'slot WAL status not reserved', key, lag_bytes, 'bytes', detail->>'wal_status', 'critical'
    FROM pgvigil.replication_latest
   WHERE kind = 'slot' AND detail->>'wal_status' IN ('unreserved', 'lost')
  UNION ALL
  SELECT instance_id, snapshot_at, 'sender not streaming', key, lag_bytes, 'bytes', state, 'warning'
    FROM pgvigil.replication_latest
   WHERE kind = 'sender' AND state IS DISTINCT FROM 'streaming'
     AND state IS DISTINCT FROM 'backup' AND coalesce(detail->>'application_name', '') NOT IN ('pg_basebackup', 'pg_rewind')
  UNION ALL
  SELECT instance_id, snapshot_at, 'replay lag', key, lag_secs::bigint, 'seconds', state, 'warning'
    FROM pgvigil.replication_latest
   WHERE kind IN ('sender', 'receiver', 'aurora_replica') AND coalesce(lag_secs, 0) > 30
     AND NOT (kind = 'sender' AND (state = 'backup' OR coalesce(detail->>'application_name', '') IN ('pg_basebackup', 'pg_rewind')))
  UNION ALL
  -- a read that failed is a check of its own: an unreadable slot list must not look healthy
  SELECT d.instance_id, d.snapshot_at, 'replication read failed', split_part(d.note, ':', 1), NULL::bigint, NULL, d.note, 'warning'
    FROM pgvigil.collection_dates d
   WHERE d.collection = 'replication' AND d.status = 'partial'
  UNION ALL
  SELECT h.instance_id, h.at, h.check_name, h.object, h.reads::bigint, 'reads in a row', h.detail, h.severity
    FROM pgvigil.pg_hadr_checks h;

-- 0103's Summary rows and findings again (its section 4, every arm kept): the 'log shipping' arm leaves out a standby with
-- primary_conninfo set, and the 'replication' check group carries pg_hadr_checks (to pgvigil.findings through
-- pg_backups_findings, so the alert sender sends them; the Summary shows them through replication_checks).
CREATE OR REPLACE VIEW pgvigil.pg_backups_checks AS
SELECT b.instance_id, 'critical' AS severity, b.tool || ' read failing' AS check_name, b.name AS object, b.read_at AS at,
       coalesce(b.status_message, b.message, b.state) AS detail, 'base backups' AS check_group
  FROM pgvigil.pg_base_backup_status b
 WHERE b.state = 'error' AND b.read_at > now() - interval '1 day'
UNION ALL
SELECT b.instance_id, CASE WHEN b.full_age_s IS NULL OR (b.full_crit_h IS NOT NULL AND b.full_age_s > b.full_crit_h * 3600) THEN 'critical' ELSE 'warning' END,
       'full backup older than ' || coalesce(b.full_warn_h, b.full_crit_h) || ' h', b.name, b.read_at,
       coalesce('the newest full backup ' || b.full_label || ' ended ' || b.full_age_h || ' h before the read', 'no full backup is listed')
       || ' (' || concat_ws(', ', 'warning ' || b.full_warn_h || ' h', 'critical ' || b.full_crit_h || ' h', b.full_level) || ')', 'base backups'
  FROM pgvigil.pg_base_backup_status b
 WHERE b.state = 'ok' AND coalesce(b.full_warn_h, b.full_crit_h) IS NOT NULL
   AND (b.full_age_s IS NULL OR b.full_age_s > coalesce(b.full_warn_h, b.full_crit_h) * 3600) AND b.read_at > now() - interval '1 day'
UNION ALL
SELECT b.instance_id, CASE WHEN b.last_age_s IS NULL OR (b.any_crit_h IS NOT NULL AND b.last_age_s > b.any_crit_h * 3600) THEN 'critical' ELSE 'warning' END,
       'backup older than ' || coalesce(b.any_warn_h, b.any_crit_h) || ' h', b.name, b.read_at,
       coalesce('the newest backup ' || b.last_label || ' ended ' || b.last_age_h || ' h before the read', 'no backup is listed'), 'base backups'
  FROM pgvigil.pg_base_backup_status b
 WHERE b.state = 'ok' AND coalesce(b.any_warn_h, b.any_crit_h) IS NOT NULL
   AND (b.last_age_s IS NULL OR b.last_age_s > coalesce(b.any_warn_h, b.any_crit_h) * 3600) AND b.read_at > now() - interval '1 day'
UNION ALL
SELECT x.instance_id, 'warning', 'newest backup failed', x.name, x.snapshot_at, x.label || ' (' || coalesce(x.tool_status, x.status) || ')', 'base backups'
  FROM (SELECT DISTINCT ON (b.instance_id, b.tool, b.name) b.* FROM pgvigil.pg_base_backups b
          JOIN pgvigil.instances i ON i.instance_id = b.instance_id AND i.is_active
         WHERE b.is_present AND b.status <> 'running' ORDER BY b.instance_id, b.tool, b.name, coalesce(b.stopped_at, b.started_at) DESC NULLS LAST) x
 WHERE x.status = 'error' AND x.snapshot_at > now() - interval '1 day'
UNION ALL
SELECT w.instance_id, CASE WHEN w.crit_min IS NOT NULL AND w.replay_delay_secs > w.crit_min * 60 THEN 'critical' ELSE 'warning' END,
       'replay delay over ' || coalesce(w.warn_min, w.crit_min) || ' min', 'restore_command', w.read_at,
       'last replayed commit ' || round((w.replay_delay_secs / 60)::numeric) || ' min before the read, no WAL receiver (file shipping)'
       || CASE WHEN w.primary_id IS NULL THEN '; its primary is not in the fleet: an idle primary also reads as a delay' ELSE '' END
       || CASE WHEN w.replay_paused THEN '; replay is paused' ELSE '' END, 'log shipping'
  FROM pgvigil.pg_wal_replay_status w
 WHERE NOT coalesce(w.has_receiver, false) AND coalesce(w.warn_min, w.crit_min) IS NOT NULL AND w.replay_delay_secs > coalesce(w.warn_min, w.crit_min) * 60
   AND NOT coalesce(w.caught_up, false)
   AND w.read_at > now() - interval '1 hour'
   -- 0141: a standby with primary_conninfo set is a streaming standby whose receiver is down: 'receiver down' judges it
   AND NOT EXISTS (SELECT 1 FROM pgvigil.pg_repl_standby_state s
                    WHERE s.instance_id = w.instance_id AND s.in_recovery AND s.conninfo_set AND s.read_at > now() - interval '1 hour')
UNION ALL
SELECT c.instance_id, c.status, 'crash restart', 'log', c.open_crash_at,
       c.open_detail || ' (' || c.open_age_h || ' h ago; ' || c.open_30d || ' not acknowledged in 30 days)', 'crashes'
  FROM pgvigil.pg_crash_state c
 WHERE c.status IN ('warning', 'critical')
UNION ALL
SELECT s.instance_id, 'warning', 'statements evicted', 'pg_stat_statements', s.info_at,
       s.dealloc_24h || ' eviction(s) in 24 h: pg_stat_statements.max (' || coalesce(s.max_entries::text, '?') || ') is too small for the statements run', 'statement store'
  FROM pgvigil.pg_stmt_store_state s
 WHERE s.dealloc_24h > 0
UNION ALL
SELECT s.instance_id, 'warning', 'statement tracking off', 'pg_stat_statements', s.ext_at, 'pg_stat_statements.track = none: nothing is recorded', 'statement store'
  FROM pgvigil.pg_stmt_store_state s
 WHERE s.track = 'none'
UNION ALL
SELECT u.instance_id, u.status, 'uptime under ' || CASE WHEN u.status = 'critical' THEN u.crit_h ELSE u.warn_h END || ' h', 'postmaster', u.postmaster_start,
       'started ' || to_char(u.postmaster_start AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC, ' || u.uptime_h || ' h ago (critical under '
       || coalesce(u.crit_h::text, '-') || ' h, warning under ' || coalesce(u.warn_h::text, '-') || ' h, ' || u.threshold_level || ')', 'uptime'
  FROM pgvigil.pg_uptime_state u
 WHERE u.status IN ('warning', 'critical')
UNION ALL
SELECT a.instance_id, CASE WHEN a.last_ok_at IS NULL OR (a.crit_days IS NOT NULL AND a.age_s > a.crit_days * 86400) THEN 'critical' ELSE 'warning' END,
       CASE WHEN a.last_ok_at IS NULL THEN 'amcheck never clean' ELSE 'amcheck older than ' || coalesce(a.warn_days, a.crit_days) || ' d' END, a.datname, coalesce(a.last_run_at, now()),
       coalesce('the last clean run ' || a.age_days || ' d ago', 'no clean run stored') || coalesce(' (the newest run: ' || a.last_status || ')', '')
       || ' (' || concat_ws(', ', 'warning ' || a.warn_days || ' d', 'critical ' || a.crit_days || ' d', a.threshold_level) || ')', 'amcheck age'
  FROM pgvigil.pg_amcheck_age a
 WHERE a.amcheck_runs_any AND coalesce(a.warn_days, a.crit_days) IS NOT NULL
   AND (a.last_ok_at IS NULL OR a.age_s > coalesce(a.warn_days, a.crit_days) * 86400)
UNION ALL
-- 0141: the streaming replication rules (pg_hadr_checks)
SELECT h.instance_id, h.severity, h.check_name, h.object, h.at, h.stable, 'replication'
  FROM pgvigil.pg_hadr_checks h;

-- The findings arm (the findings columns): the checks above but uptime (a state, not a finding), plus two info rows:
-- a tool the server names that the collector's host lacks, and amcheck never run on an instance.
CREATE OR REPLACE VIEW pgvigil.pg_backups_findings AS
SELECT c.instance_id, c.severity, c.check_name AS setting, c.object || ': ' || c.detail AS value, true AS is_set,
       CASE c.check_group
         WHEN 'base backups' THEN 'read the tool''s log and its last backup; a stanza status other than ok names what is missing'
         WHEN 'log shipping' THEN 'check restore_command on the standby and archiving on the primary; set archive_timeout so a quiet primary still ships'
         WHEN 'crashes' THEN 'read the server log around the crash (the backend''s last statement, the signal) and acknowledge it on the Summary'
         WHEN 'statement store' THEN 'raise pg_stat_statements.max (a restart) or turn tracking back on'
         WHEN 'replication' THEN CASE c.check_name
                                   WHEN 'receiver down' THEN 'read the standby''s server log for the receiver''s connect error (pg_hba on the primary, the network, the replication login, a slot gone) and fix it; the standby catches up by itself once streaming resumes'
                                   ELSE 'start the standby or reconnect it; if it was retired on purpose, the finding ends 7 days after it was last seen'
                                 END
         ELSE 'schedule the amcheck collection for the database (README: the amcheck collection)'
       END AS suggested, 'self-managed' AS platforms,
       CASE c.check_group
         WHEN 'base backups' THEN 'without a recent base backup a restore replays more WAL, or has nothing to start from'
         WHEN 'log shipping' THEN 'a standby that falls behind loses what it has not replayed if it must take over'
         WHEN 'crashes' THEN 'a crash restart ends every session and replays WAL from the last checkpoint'
         WHEN 'statement store' THEN 'evicted statements drop out of the statement history'
         WHEN 'replication' THEN 'a standby that does not stream falls behind: a failover to it loses what it has not received'
         ELSE 'damage in an index or a table is only found by a check that reads it'
       END AS detail, 'pg-backups' AS source, c.at
  FROM pgvigil.pg_backups_checks c
 WHERE c.check_group <> 'uptime'
UNION ALL
SELECT t.instance_id, 'info', t.tool || ' not on the collector host', t.name || ': ' || t.message, true,
       'install ' || t.tool || ' on the collector host with read access to the repository (docs/backups-postgres.md)', 'self-managed',
       'the server archives with ' || t.tool || ' but its backups cannot be read from here', 'pg-backups', t.snapshot_at
  FROM pgvigil.pg_backup_tools t JOIN pgvigil.instances i ON i.instance_id = t.instance_id AND i.is_active
 WHERE t.is_present AND t.state = 'no_binary'
UNION ALL
SELECT i.instance_id, 'info', 'amcheck never run', i.name, true, 'schedule the amcheck collection (README: the amcheck collection)', 'all',
       'no amcheck run is stored for the instance: damage in an index or a table goes unseen until a query reads it', 'pg-backups', now()
  FROM pgvigil.instances i
 WHERE i.is_active AND i.engine = 'postgres'
