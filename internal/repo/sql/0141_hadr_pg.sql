-- 0141 hadr_pg: PostgreSQL streaming replication health (the HA build, tasks 370-372 and 374; the replication collection
-- of internal/collect/replication.go). This file's rules live in PostgreSQL's own views (0006's replication_checks and
-- 0103's pg_backups_checks / pg_backups_findings, re-created here with their arms kept); 0118's darling_alert_findings is
-- not touched.
--   task 370 (a)  a base backup's senders (state 'backup', or application_name pg_basebackup / pg_rewind: pgwatch 6.1.0's
--                 rule, metrics.yaml L1980) are no standby: 'sender not streaming' and the lag checks leave them out, and
--                 they are never a link
--   task 370 (b)  'receiver down' (the standby's side): in recovery, primary_conninfo set and no WAL receiver for 2 reads
--                 in a row - warning while replay still advances through restore_command, critical when it has not moved
--                 since the receiver went down or for the 'restore_stall' threshold (pgvigil's own default 5 minutes);
--                 'standby gone' (the sending side): a physical link this server sent to in the last 7 days with no sender
--                 for 2 reads in a row - critical. Both are left to the provider on a managed platform (RDS, Aurora, Azure,
--                 Cloud SQL, AlloyDB). Before this file such a standby raised nothing until the file-fed rule's 60 minutes
--                 (0103's 'log shipping' arm), and never on a managed platform; that arm now leaves out a standby with
--                 primary_conninfo set ('receiver down' judges it).
--   task 371      a LINK is one sending server and one physical consumer of its WAL (a standby, pg_receivewal, Barman):
--                 'slot:<slot>' when the sender holds a physical slot, else 'app:<application_name>@<address>' (a name
--                 alone says little: walreceiver is the default, and Debian's packages give every server cluster_name
--                 '<version>/main'). A logical slot's sender is no link (task 373's subscriptions), nor a sender on a
--                 temporary slot (pg_basebackup -X stream's). A link that vanished is the same standby back - not a gap -
--                 when a current link has its name and address (a slot added or dropped), or when as many new links of
--                 its name (no slot) appeared since it vanished as there are vanished ones (a new address). replication_sample keys a link's
--                 sender row by the link, no longer by its pid, so a reconnect keeps its series and its alert key.
--                 pg_repl_link_health pairs both sides: the sending server's view (its sender, kept in pg_repl_link_seen)
--                 and the standby's own (pg_repl_standby_state, when the standby is monitored: matched by system
--                 identifier and its primary_slot_name, cluster_name or instance name), and lists the links expected but
--                 absent: a sender seen in the last 7 days, an inactive physical slot, a name in synchronous_standby_names.
--                 ONE finding per link, the first that holds of: 'receiver down' (on the standby), 'standby gone' (on the
--                 sending server, only while the standby's own read cannot speak: not monitored, stale or unreachable;
--                 the link shows 'down: standby unreachable' then), 'replay paused' (the standby, 2 reads, critical: H2),
--                 'standby lag' - bytes not yet replayed at 50 MB warning / 100 MB critical (pgmonitor 5.3.0's tiers,
--                 'standby_lag_bytes') and the primary's replay_lag at 30 s / 300 s beyond the standby's
--                 recovery_min_apply_delay (PerformanceMonitor 3.12.0's tiers as 0118 had them, 'standby_replay_lag'),
--                 each held for 2 reads in a row; judged from the sending server's sender (its replay position, or its
--                 flush position on a standby that delays apply on purpose) and from the standby's received - replayed
--                 bytes when the sending server is not read.
--   task 372      synchronous standbys (pg_sync_state): synchronous_standby_names parsed (pg_sync_standbys: FIRST n (...),
--                 ANY n (...), n (...) = FIRST, a bare list = FIRST 1, '*' = any); 'synchronous commits waiting' when
--                 fewer standbys are in 'sync' / 'quorum' state than num_sync - critical at once (H2: a commit waits),
--                 a warning when synchronous_commit is off or local at the server (its sessions' commits do not wait);
--                 'synchronous standby absent' (warning, on that name's link row) when a named standby is not
--                 connected and num_sync still holds ('potential' and 'quorum' are healthy).
--   task 373      logical replication (the 'logical' collection): pg_logical_subs / _rels / _pubs kept by import_logical,
--                 pg_logical_checks (one finding per subscription: apply errors, worker down, disabled, sync errors,
--                 PostgreSQL 18's conflicts, a table's initial sync not finished, silent), pg_logical_status for the
--                 Replication page; a subscription's walsender on the publisher is keyed by its slot.
--   task 374      slots: the collector adds invalidation_reason (17 on), max_slot_wal_keep_size and pg_stat_replication_
--                 slots' spill / stream counters (14 on: 'slot_stats' rows); pg_repl_slot_state keeps each slot's retained
--                 WAL at an hourly mark for its growth per hour. One finding per slot: 'slot invalidated' (critical:
--                 invalidation_reason set or wal_status lost), 'slot WAL near its limit' (safe_wal_size under 'slot_safe_wal',
--                 1024 MB, or under half of max_slot_wal_keep_size when that is smaller: warning; wal_status unreserved:
--                 critical - this replaces 0006's 'slot WAL status not reserved'),
--                 'slot WAL growing' (retained WAL up 'slot_growth', 1024 MB, or more in the last full hour: warning);
--                 thresholds pgvigil's own defaults. Aurora: a reader is judged by aurora_replica_status alone - 'Aurora
--                 replica lag' on the writer at the 'standby_replay_lag' tiers (30 / 300 s, PerformanceMonitor 3.12.0's; a
--                 reader returns the same rows and raises nothing), no receiver rule and no link row for an Aurora reader.
--   review fold   (2026-11-14, the split review of ee6d061..6b75eb0) a database walsender is no link; a held 'receiver down'
--                 read with the receiver back is a warning; a standby whose primary_conninfo is unreadable does not speak
--                 for its link; a named synchronous standby with a down link is not listed twice; 'sending server not read';
--                 a WAL receiver without a replay position (pg_receivewal) judged on its flush position; 0006's standby-side
--                 'replay lag' kept for a standby no monitored primary sends to; a subscription's publisher paired only
--                 when one instance has that slot; the state tables cascade with their instance.
-- The collector adds a 'standby' row (the server in recovery: its receiver, primary_conninfo / restore_command set,
-- positions, replay pause), a 'sync' row (synchronous_standby_names) and each sender's slot and flush lag;
-- import_replication keeps the two state tables from them.

INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('restore_stall', 'Receiver down: replay through restore_command stopped for', 'minutes', 'over', NULL, 5, '{root,tag,instance}', 1440)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- task 371's tiers are in seconds and megabytes: the unit check takes both
ALTER TABLE pgvigil.pg_threshold_keys DROP CONSTRAINT IF EXISTS pg_threshold_keys_unit_check;
ALTER TABLE pgvigil.pg_threshold_keys ADD CONSTRAINT pg_threshold_keys_unit_check CHECK (unit IN ('minutes', 'hours', 'days', 'seconds', 'MB'));
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('standby_lag_bytes',  'Standby lag: WAL not yet replayed, 2 reads in a row', 'MB', 'over', 50, 100, '{root,tag,instance}', 1048576),
  ('standby_replay_lag', 'Standby lag: the primary''s replay_lag beyond recovery_min_apply_delay, 2 reads in a row', 'seconds', 'over', 30, 300, '{root,tag,instance}', 604800)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- pg_repl_standby_state: one row per instance, the newest read of its recovery state. down_reads counts the reads in a row
-- with the receiver down (in recovery, primary_conninfo set, no WAL receiver); one read with a receiver does not end it
-- (a receiver that connects and then fails - a slot gone - shows its row for a moment every retry): up_reads counts the
-- reads with a receiver, and the fault ends at 2; replay_moved_at is the newest read whose
-- replay position was past the read before it (a move is dated by the read that sees it); rcv_bytes is received - replayed.
CREATE TABLE IF NOT EXISTS pgvigil.pg_repl_standby_state (
  instance_id        int PRIMARY KEY REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  read_at            timestamptz NOT NULL,
  in_recovery        boolean NOT NULL,
  has_receiver       boolean,
  receiver_status    text,
  sender_host        text,
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
  prev_replay_paused boolean,
  rcv_bytes          bigint,
  prev_rcv_bytes     bigint,
  down_reads         int NOT NULL DEFAULT 0,
  up_reads           int NOT NULL DEFAULT 0,
  down_since         timestamptz
);

-- pg_repl_link_seen: the physical links a server sends WAL to, by link (pg_link_key). gone_reads counts the reads in a row
-- with no sender for the link; the lag columns are the newest read's and the one before (prev_*, NULL after a gap) so a
-- tier holds for 2 reads in a row; a link not seen for 7 days is dropped, and a role change of the server drops its links.
CREATE TABLE IF NOT EXISTS pgvigil.pg_repl_link_seen (
  instance_id      int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  link             text NOT NULL,
  application_name text,
  client_addr      text,
  slot_name        text,
  first_seen       timestamptz NOT NULL,
  last_seen        timestamptz NOT NULL,
  checked_at       timestamptz NOT NULL,
  last_state       text,
  sync_state       text,
  lag_bytes        bigint,
  prev_lag_bytes   bigint,
  flush_bytes      bigint,
  prev_flush_bytes bigint,
  lag_secs         double precision,
  prev_lag_secs    double precision,
  gone_reads       int NOT NULL DEFAULT 0,
  gone_since       timestamptz,
  PRIMARY KEY (instance_id, link)
);
-- a repository migrated by this file before task 371 has the table without the lag columns
ALTER TABLE pgvigil.pg_repl_link_seen ADD COLUMN IF NOT EXISTS sync_state text, ADD COLUMN IF NOT EXISTS lag_bytes bigint,
  ADD COLUMN IF NOT EXISTS prev_lag_bytes bigint, ADD COLUMN IF NOT EXISTS flush_bytes bigint, ADD COLUMN IF NOT EXISTS prev_flush_bytes bigint,
  ADD COLUMN IF NOT EXISTS lag_secs double precision, ADD COLUMN IF NOT EXISTS prev_lag_secs double precision;
ALTER TABLE pgvigil.pg_repl_standby_state ADD COLUMN IF NOT EXISTS receiver_status text, ADD COLUMN IF NOT EXISTS sender_host text,
  ADD COLUMN IF NOT EXISTS prev_replay_paused boolean, ADD COLUMN IF NOT EXISTS rcv_bytes bigint, ADD COLUMN IF NOT EXISTS prev_rcv_bytes bigint,
  ADD COLUMN IF NOT EXISTS up_reads int NOT NULL DEFAULT 0;

INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('slot_safe_wal', 'Slots: WAL left before max_slot_wal_keep_size invalidates the slot (safe_wal_size)', 'MB', 'under', 1024, NULL, '{root,tag,instance}', 1048576),
  ('slot_growth',   'Slots: retained WAL grown in the last full hour', 'MB', 'over', 1024, NULL, '{root,tag,instance}', 1048576)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- pg_repl_slot_state (task 374): each slot's newest retained WAL and an hourly mark; growth_bytes_h is the growth over the
-- last full hour (bytes per hour), growth_at the read that closed that hour. A slot no longer listed is dropped.
CREATE TABLE IF NOT EXISTS pgvigil.pg_repl_slot_state (
  instance_id     int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  slot_name       text NOT NULL,
  read_at         timestamptz NOT NULL,
  retained_bytes  bigint,
  mark_at         timestamptz NOT NULL,
  mark_bytes      bigint,
  growth_bytes_h  bigint,
  growth_at       timestamptz,
  PRIMARY KEY (instance_id, slot_name)
);

-- pg_link_key: a physical link's name (the header above). pg_link_sender: whether a sender row is a physical link's.
CREATE OR REPLACE FUNCTION pgvigil.pg_link_key(p_app text, p_addr text, p_slot text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_slot IS NOT NULL THEN 'slot:' || p_slot
              ELSE 'app:' || coalesce(p_app, '') || '@' || coalesce(p_addr, 'local') END
$$;
CREATE OR REPLACE FUNCTION pgvigil.pg_link_sender(r jsonb)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
  SELECT r->>'kind' = 'sender' AND coalesce(r->>'state', '') <> 'backup'
     AND coalesce(r->>'application_name', '') NOT IN ('pg_basebackup', 'pg_rewind')
     AND coalesce(r->>'slot_type', 'physical') = 'physical'
     AND NOT coalesce((r->>'slot_temporary')::boolean, false)   -- pg_basebackup -X stream's own slot, whatever its name
     AND NOT coalesce((r->>'db_sender')::boolean, false)        -- a database (logical) walsender, slot or not: a table copy
$$;

-- pg_sync_standbys: synchronous_standby_names parsed - FIRST n (a, b), ANY n (a, b), n (a, b) (FIRST), a bare list
-- (FIRST 1), '*' (any standby: no names). Names lose their double quotes; an empty setting is method NULL.
CREATE OR REPLACE FUNCTION pgvigil.pg_sync_standbys(p_setting text, OUT method text, OUT num_sync int, OUT names text[])
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  v_s text := btrim(coalesce(p_setting, ''));
  v_m text[];
BEGIN
  IF v_s = '' THEN RETURN; END IF;
  v_m := regexp_match(v_s, '^(?:(first|any)\s+)?([0-9]+)\s*\((.*)\)$', 'i');
  IF v_m IS NOT NULL THEN
    method := upper(coalesce(v_m[1], 'FIRST')); num_sync := v_m[2]::int; v_s := v_m[3];
  ELSE
    method := 'FIRST'; num_sync := 1;
  END IF;
  SELECT array_agg(n ORDER BY o) INTO names
    FROM (SELECT btrim(btrim(x), '"') AS n, o FROM unnest(string_to_array(v_s, ',')) WITH ORDINALITY u(x, o)) y
   WHERE n <> '' AND n <> '*';
  IF v_s ~ '(^|,)\s*\*\s*(,|$)' THEN names := NULL; method := method || ' *'; END IF;
END $$;

CREATE OR REPLACE FUNCTION pgvigil.import_replication(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_sb          jsonb;      -- the 'standby' row: NULL on a server not in recovery
  v_rcv         jsonb;      -- the 'receiver' row
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
         CASE WHEN pgvigil.pg_link_sender(r) THEN pgvigil.pg_link_key(r->>'application_name', r->>'client_addr', r->>'slot_name')
              WHEN r->>'kind' = 'sender' AND r->>'slot_type' = 'logical' THEN 'slot:' || (r->>'slot_name')   -- task 373: a subscription's walsender
              ELSE CASE r->>'kind'
           WHEN 'sender'         THEN coalesce(r->>'application_name', '') || '@' || coalesce(r->>'client_addr', '') || '#' || coalesce(r->>'pid', '')
           WHEN 'receiver'       THEN coalesce(r->>'slot_name', r->>'sender_host', 'receiver')
           WHEN 'standby'        THEN 'recovery'
           WHEN 'sync'           THEN 'synchronous_standby_names'
           WHEN 'slot'           THEN r->>'slot_name'
           WHEN 'slot_stats'     THEN r->>'slot_name'
           WHEN 'subscription'   THEN coalesce(r->>'datname', '') || ':' || coalesce(r->>'subname', '')
           WHEN 'publication'    THEN r->>'pubname'
           WHEN 'conflict'       THEN r->>'datname'
           WHEN 'aurora_replica' THEN r->>'server_id'
           ELSE coalesce(r->>'pid', '?') END END,
         CASE r->>'kind'
           WHEN 'sender'         THEN r->>'state'
           WHEN 'receiver'       THEN r->>'status'
           WHEN 'standby'        THEN CASE WHEN (r->>'has_receiver')::boolean THEN 'receiving'
                                           WHEN (r->>'conninfo_set')::boolean THEN 'receiver down'
                                           WHEN (r->>'restore_set')::boolean THEN 'file-fed'
                                           ELSE 'no WAL source' END
           WHEN 'sync'           THEN r->>'names'
           WHEN 'slot'           THEN r->>'wal_status'
           WHEN 'subscription'   THEN CASE WHEN (r->>'enabled')::boolean THEN 'enabled' ELSE 'disabled' END
           WHEN 'aurora_replica' THEN r->>'session_id'
           ELSE NULL END,
         CASE r->>'kind'
           WHEN 'sender'  THEN (r->>'replay_lag_bytes')::bigint
           WHEN 'standby' THEN (r->>'replay_lag_bytes')::bigint
           WHEN 'slot'    THEN (r->>'retained_bytes')::bigint
           WHEN 'slot_stats' THEN (r->>'spill_bytes')::bigint
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
  SELECT r INTO v_rcv FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'receiver' LIMIT 1;
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
           (instance_id, read_at, in_recovery, has_receiver, receiver_status, sender_host, conninfo_set, restore_set, primary_slot,
            min_apply_delay_ms, receive_lsn, replay_lsn, prev_replay_lsn, replay_moved_at, last_replay_at, replay_paused,
            prev_replay_paused, rcv_bytes, prev_rcv_bytes, down_reads, down_since)
    VALUES (p_instance_id, p_snapshot_at, v_in_rec, (v_sb->>'has_receiver')::boolean, v_rcv->>'status', v_rcv->>'sender_host',
            (v_sb->>'conninfo_set')::boolean, (v_sb->>'restore_set')::boolean, nullif(v_sb->>'primary_slot_name', ''),
            (v_sb->>'min_apply_delay_ms')::bigint, (v_sb->>'receive_lsn')::pg_lsn, v_replay, NULL, NULL,
            (v_sb->>'last_replay_at')::timestamptz, (v_sb->>'replay_paused')::boolean, NULL,
            (v_sb->>'replay_lag_bytes')::bigint, NULL, CASE WHEN v_down THEN 1 ELSE 0 END, CASE WHEN v_down THEN p_snapshot_at END)
    ON CONFLICT (instance_id) DO UPDATE SET
      read_at = EXCLUDED.read_at, in_recovery = EXCLUDED.in_recovery, has_receiver = EXCLUDED.has_receiver,
      receiver_status = EXCLUDED.receiver_status, sender_host = EXCLUDED.sender_host,
      conninfo_set = EXCLUDED.conninfo_set, restore_set = EXCLUDED.restore_set, primary_slot = EXCLUDED.primary_slot,
      min_apply_delay_ms = EXCLUDED.min_apply_delay_ms, receive_lsn = EXCLUDED.receive_lsn, replay_lsn = EXCLUDED.replay_lsn,
      prev_replay_lsn = CASE WHEN EXCLUDED.in_recovery AND s.in_recovery THEN s.replay_lsn END,
      replay_moved_at = CASE WHEN NOT EXCLUDED.in_recovery THEN NULL
                             WHEN s.in_recovery AND s.replay_lsn IS NOT NULL AND EXCLUDED.replay_lsn > s.replay_lsn THEN EXCLUDED.read_at
                             WHEN s.in_recovery THEN s.replay_moved_at END,
      last_replay_at = EXCLUDED.last_replay_at, replay_paused = EXCLUDED.replay_paused,
      prev_replay_paused = CASE WHEN EXCLUDED.in_recovery AND s.in_recovery THEN s.replay_paused END,
      rcv_bytes = EXCLUDED.rcv_bytes,
      prev_rcv_bytes = CASE WHEN EXCLUDED.in_recovery AND s.in_recovery THEN s.rcv_bytes END,
      up_reads   = CASE WHEN EXCLUDED.down_reads = 1 THEN 0
                        WHEN EXCLUDED.has_receiver AND s.down_reads > 0 THEN s.up_reads + 1 ELSE 0 END,
      down_reads = CASE WHEN EXCLUDED.down_reads = 1 THEN s.down_reads + 1
                        WHEN EXCLUDED.has_receiver AND s.down_reads > 0 AND s.up_reads + 1 < 2 THEN s.down_reads
                        ELSE 0 END,
      down_since = CASE WHEN EXCLUDED.down_reads = 1 THEN coalesce(s.down_since, EXCLUDED.read_at)
                        WHEN EXCLUDED.has_receiver AND s.down_reads > 0 AND s.up_reads + 1 < 2 THEN s.down_since END;
  END IF;

  IF NOT v_snd_failed THEN
    -- the physical links of this read (a base backup, pg_rewind and a logical slot's sender are no link)
    INSERT INTO pgvigil.pg_repl_link_seen AS l
           (instance_id, link, application_name, client_addr, slot_name, first_seen, last_seen, checked_at, last_state, sync_state,
            lag_bytes, prev_lag_bytes, flush_bytes, prev_flush_bytes, lag_secs, prev_lag_secs, gone_reads, gone_since)
    SELECT DISTINCT ON (x.link) p_instance_id, x.link, x.app, x.addr, x.slot, p_snapshot_at, p_snapshot_at, p_snapshot_at, x.state, x.sync,
           x.lag_bytes, NULL::bigint, x.flush_bytes, NULL::bigint, x.lag_secs, NULL::float8, 0, NULL::timestamptz
      FROM (SELECT pgvigil.pg_link_key(r->>'application_name', r->>'client_addr', r->>'slot_name') AS link,
                   r->>'application_name' AS app, r->>'client_addr' AS addr, r->>'slot_name' AS slot, r->>'state' AS state,
                   r->>'sync_state' AS sync, (r->>'replay_lag_bytes')::bigint AS lag_bytes, (r->>'flush_lag_bytes')::bigint AS flush_bytes,
                   (r->>'replay_lag_secs')::float8 AS lag_secs
              FROM jsonb_array_elements(p_payload) r
             WHERE pgvigil.pg_link_sender(r)) x
     ORDER BY x.link, (x.state = 'streaming') DESC
    ON CONFLICT (instance_id, link) DO UPDATE SET
      application_name = EXCLUDED.application_name, client_addr = EXCLUDED.client_addr, slot_name = EXCLUDED.slot_name,
      last_seen = EXCLUDED.last_seen, checked_at = EXCLUDED.checked_at, last_state = EXCLUDED.last_state, sync_state = EXCLUDED.sync_state,
      prev_lag_bytes = CASE WHEN l.gone_reads = 0 THEN l.lag_bytes END, lag_bytes = EXCLUDED.lag_bytes,
      prev_flush_bytes = CASE WHEN l.gone_reads = 0 THEN l.flush_bytes END, flush_bytes = EXCLUDED.flush_bytes,
      prev_lag_secs = CASE WHEN l.gone_reads = 0 THEN l.lag_secs END, lag_secs = EXCLUDED.lag_secs,
      gone_reads = 0, gone_since = NULL;
    UPDATE pgvigil.pg_repl_link_seen
       SET gone_reads = gone_reads + 1, gone_since = coalesce(gone_since, p_snapshot_at), checked_at = p_snapshot_at
     WHERE instance_id = p_instance_id AND checked_at < p_snapshot_at;
    DELETE FROM pgvigil.pg_repl_link_seen WHERE instance_id = p_instance_id AND last_seen < p_snapshot_at - interval '7 days';
  END IF;

  -- task 374: each slot's retained WAL against its hourly mark
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'slots') THEN
    INSERT INTO pgvigil.pg_repl_slot_state AS t (instance_id, slot_name, read_at, retained_bytes, mark_at, mark_bytes)
    SELECT p_instance_id, r->>'slot_name', p_snapshot_at, (r->>'retained_bytes')::bigint, p_snapshot_at, (r->>'retained_bytes')::bigint
      FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'slot'
    ON CONFLICT (instance_id, slot_name) DO UPDATE SET
      read_at = EXCLUDED.read_at, retained_bytes = EXCLUDED.retained_bytes,
      growth_bytes_h = CASE WHEN EXCLUDED.read_at - t.mark_at >= interval '1 hour'
                            THEN ((EXCLUDED.retained_bytes - t.mark_bytes) / (extract(epoch FROM EXCLUDED.read_at - t.mark_at) / 3600.0))::bigint
                            ELSE t.growth_bytes_h END,
      growth_at = CASE WHEN EXCLUDED.read_at - t.mark_at >= interval '1 hour' THEN EXCLUDED.read_at ELSE t.growth_at END,
      mark_bytes = CASE WHEN EXCLUDED.read_at - t.mark_at >= interval '1 hour' THEN EXCLUDED.retained_bytes ELSE t.mark_bytes END,
      mark_at = CASE WHEN EXCLUDED.read_at - t.mark_at >= interval '1 hour' THEN EXCLUDED.read_at ELSE t.mark_at END;
    DELETE FROM pgvigil.pg_repl_slot_state WHERE instance_id = p_instance_id AND read_at < p_snapshot_at;
  END IF;
END $$;

-- pg_sync_state (task 372): each primary's synchronous standbys - synchronous_standby_names parsed (FIRST n (...),
-- ANY n (...), n (...) = FIRST, a bare list = FIRST 1, '*' = any standby), the physical senders in 'sync' or 'quorum'
-- state, and the named standbys with no streaming sender. 'potential' and 'async' are not in sync.
CREATE OR REPLACE VIEW pgvigil.pg_sync_state AS
SELECT y.instance_id, y.snapshot_at, y.setting, p.method, p.num_sync, p.names, y.commit_level,
       (SELECT count(*) FROM pgvigil.replication_latest r
         WHERE r.instance_id = y.instance_id AND pgvigil.pg_link_sender(r.detail) AND r.state = 'streaming'
           AND r.detail->>'sync_state' IN ('sync', 'quorum')) AS in_sync,
       (SELECT array_agg(n.name ORDER BY n.o) FROM unnest(p.names) WITH ORDINALITY n(name, o)
         WHERE NOT EXISTS (SELECT 1 FROM pgvigil.replication_latest r
                            WHERE r.instance_id = y.instance_id AND pgvigil.pg_link_sender(r.detail) AND r.state = 'streaming'
                              AND lower(r.detail->>'application_name') = lower(n.name))) AS absent,
       (SELECT string_agg(r.detail->>'application_name' || ' ' || coalesce(r.detail->>'sync_state', '?'), ', ' ORDER BY r.detail->>'application_name')
          FROM pgvigil.replication_latest r WHERE r.instance_id = y.instance_id AND pgvigil.pg_link_sender(r.detail)) AS senders
  FROM (SELECT r.instance_id, r.snapshot_at, r.state AS setting, r.detail->>'commit_level' AS commit_level
          FROM pgvigil.replication_latest r
         WHERE r.kind = 'sync' AND NOT coalesce((r.detail->>'in_recovery')::boolean, false) AND btrim(coalesce(r.state, '')) <> '') y
  CROSS JOIN LATERAL pgvigil.pg_sync_standbys(y.setting) p
 WHERE p.num_sync IS NOT NULL;

-- pg_repl_link_health: one row per physical link of the fleet (the header's task 371), with both sides' views, its
-- status and its one finding (check_name NULL when it has none). finding_id is the instance the finding is raised on.
-- stable is the text the findings carry, fixed while the fault lasts (an alert is keyed by its finding's value).
CREATE OR REPLACE VIEW pgvigil.pg_repl_link_health AS
WITH unreach AS (   -- instances whose newest collection attempt could not connect (0118's 'server unreachable' read)
  SELECT c.instance_id
    FROM (SELECT DISTINCT ON (d.instance_id) d.instance_id, d.status, d.note, d.snapshot_at
            FROM pgvigil.collection_dates d ORDER BY d.instance_id, d.snapshot_at DESC) c
   WHERE c.status = 'error' AND c.note LIKE 'connect: %' AND c.snapshot_at > now() - interval '30 minutes'
),
stb AS (            -- the monitored standbys
  SELECT s.*, i.name AS standby, i.platform AS standby_platform, rs.system_identifier AS sysid, rs.cluster_name,
         (s.read_at > now() - interval '30 minutes' AND NOT EXISTS (SELECT 1 FROM unreach u WHERE u.instance_id = s.instance_id)) AS speaks,
         EXISTS (SELECT 1 FROM unreach u WHERE u.instance_id = s.instance_id) AS unreachable
    FROM pgvigil.pg_repl_standby_state s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = s.instance_id
   WHERE s.in_recovery
     AND i.platform <> 'aurora'   -- task 374: an Aurora reader has no WAL receiver; aurora_replica_status judges it
),
snd AS (            -- the sending side: every physical link a server sent to in the last 7 days
  SELECT l.*, i.name AS sending, i.platform AS sending_platform, rs.system_identifier AS sysid,
         (l.checked_at > now() - interval '30 minutes') AS fresh,
         -- the same standby back under another link (the header's rule): its vanished link is no gap
         (l.gone_reads > 0 AND (
            EXISTS (SELECT 1 FROM pgvigil.pg_repl_link_seen o
                     WHERE o.instance_id = l.instance_id AND o.link <> l.link AND o.gone_reads = 0
                       AND o.application_name IS NOT DISTINCT FROM l.application_name AND o.client_addr IS NOT DISTINCT FROM l.client_addr
                       AND (o.slot_name IS NULL OR l.slot_name IS NULL))
            OR (l.slot_name IS NULL
                AND (SELECT count(*) FROM pgvigil.pg_repl_link_seen o
                      WHERE o.instance_id = l.instance_id AND o.slot_name IS NULL AND o.gone_reads = 0
                        AND o.application_name IS NOT DISTINCT FROM l.application_name AND o.first_seen >= l.gone_since - interval '1 minute')
                 >= (SELECT count(*) FROM pgvigil.pg_repl_link_seen g
                      WHERE g.instance_id = l.instance_id AND g.slot_name IS NULL AND g.gone_reads > 0
                        AND g.application_name IS NOT DISTINCT FROM l.application_name AND g.last_seen > now() - interval '7 days')))) AS replaced
    FROM pgvigil.pg_repl_link_seen l
    JOIN pgvigil.instances i ON i.instance_id = l.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = l.instance_id
   WHERE l.last_seen > now() - interval '7 days'
),
paired AS (         -- a link paired with the monitored standby it names: by its slot, or by a name exactly one standby has
  SELECT snd.*, CASE WHEN snd.slot_name IS NOT NULL OR m.n = 1 THEN m.instance_id END AS standby_id
    FROM snd
    LEFT JOIN LATERAL (
      SELECT b.instance_id, count(*) OVER () AS n FROM stb b
       WHERE b.instance_id <> snd.instance_id
         AND (b.sysid = snd.sysid OR b.sysid IS NULL OR snd.sysid IS NULL)
         AND ((snd.slot_name IS NOT NULL AND b.primary_slot = snd.slot_name)
              OR (snd.slot_name IS NULL AND (lower(b.cluster_name) = lower(snd.application_name) OR lower(b.standby) = lower(snd.application_name))))
       ORDER BY (b.sysid = snd.sysid) DESC NULLS LAST, b.read_at DESC LIMIT 1) m ON true
),
sync AS (           -- each primary's synchronous_standby_names, parsed (inert on a standby)
  SELECT r.instance_id, p.method, p.num_sync, p.names
    FROM pgvigil.replication_latest r
    CROSS JOIN LATERAL pgvigil.pg_sync_standbys(r.state) p
   WHERE r.kind = 'sync' AND NOT coalesce((r.detail->>'in_recovery')::boolean, false)
),
links AS (
  -- a link the sending server sent to, with its standby's own read when that standby is monitored
  SELECT 'sender'::text AS source, p.instance_id AS sending_id, p.sending, p.sending_platform, p.link, p.application_name,
         p.client_addr, p.slot_name, p.sysid, p.fresh AS sender_fresh, p.gone_reads, p.gone_since, p.last_seen, p.checked_at,
         p.last_state AS sender_state, p.sync_state, p.lag_bytes, p.prev_lag_bytes, p.flush_bytes, p.prev_flush_bytes,
         p.lag_secs, p.prev_lag_secs, p.standby_id, p.replaced
    FROM paired p
  UNION ALL
  -- a monitored standby no sending server's link names (its primary not monitored, or not matched)
  SELECT 'standby', NULL, NULL, NULL, 'standby:' || b.standby, NULL, NULL, b.primary_slot, b.sysid, NULL, NULL, NULL, NULL, b.read_at,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, b.instance_id, false
    FROM stb b WHERE NOT EXISTS (SELECT 1 FROM paired p WHERE p.standby_id = b.instance_id)
  UNION ALL
  -- an inactive physical slot no link was seen through: a standby expected, never seen here (0190's 'inactive
  -- replication slot' finding covers it)
  SELECT 'slot', s.instance_id, i.name, i.platform, 'slot:' || s.key, NULL, NULL, s.key, rs.system_identifier, true, NULL, NULL, NULL, s.snapshot_at,
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, false
    FROM pgvigil.replication_latest s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = s.instance_id
   WHERE s.kind = 'slot' AND s.detail->>'slot_type' = 'physical' AND NOT coalesce(s.active, false)
     AND NOT coalesce((s.detail->>'temporary')::boolean, false) AND NOT coalesce((s.detail->>'synced')::boolean, false)
     AND NOT EXISTS (SELECT 1 FROM snd WHERE snd.instance_id = s.instance_id AND snd.link = 'slot:' || s.key)
  UNION ALL
  -- a name in synchronous_standby_names with no link of that application_name (task 372 judges it)
  SELECT 'sync names', y.instance_id, i.name, i.platform, 'app:' || n.name, n.name, NULL, NULL, rs.system_identifier, true, NULL, NULL, NULL, now(),
         NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, false
    FROM sync y
    CROSS JOIN LATERAL unnest(y.names) n(name)
    JOIN pgvigil.instances i ON i.instance_id = y.instance_id AND i.is_active
    LEFT JOIN pgvigil.pg_role_state rs ON rs.instance_id = y.instance_id
   WHERE NOT EXISTS (SELECT 1 FROM snd WHERE snd.instance_id = y.instance_id AND lower(snd.application_name) = lower(n.name))
),
judged AS (
  SELECT k.*, b.standby, b.standby_platform, b.speaks, b.unreachable, b.read_at AS standby_read_at, b.in_recovery,
         b.has_receiver, b.receiver_status, b.sender_host, b.conninfo_set, b.restore_set, b.primary_slot, b.min_apply_delay_ms,
         b.rcv_bytes, b.prev_rcv_bytes, b.replay_paused, b.prev_replay_paused, b.replay_moved_at, b.down_reads, b.down_since,
         b.replay_lsn AS standby_replay_lsn, b.receive_lsn AS standby_receive_lsn,
         ss.in_sync, ss.num_sync AS sync_num, ss.setting AS sync_setting, ss.snapshot_at AS sync_at,
         -- a standby paired with several links (an old one replaced, or vanished) judges its own side on one: its live
         -- link first, else the newest
         (k.standby_id IS NULL OR row_number() OVER (PARTITION BY k.standby_id ORDER BY (k.gone_reads = 0) DESC NULLS FIRST, k.last_seen DESC NULLS FIRST) = 1) AS own_row,
         coalesce(b.min_apply_delay_ms, 0) / 1000.0 AS delay_s,
         -- the standby speaks for this link only when read since its sender vanished (else its last word is older)
         -- and only when it can judge its own side: a receiver, or primary_conninfo readable (NULL = a login without
         -- pg_read_all_settings: then the sender's 'standby gone' holds)
         (b.speaks AND (b.has_receiver OR b.conninfo_set IS NOT NULL) AND (k.gone_since IS NULL OR b.read_at >= k.gone_since)) AS link_speaks,
         -- the sending server's view counts while its read is fresh and the link has a sender
         (k.source = 'sender' AND k.sender_fresh AND k.gone_reads = 0) AS sender_view,
         ts.warn AS t_warn, ts.crit AS t_crit, ts.level AS t_level, bs.warn AS b_warn, bs.crit AS b_crit, bs.level AS b_level,
         bb.warn AS sb_warn, bb.crit AS sb_crit, rst.crit AS stall_min, rst.level AS stall_level
    FROM links k
    LEFT JOIN stb b ON b.instance_id = k.standby_id
    LEFT JOIN pgvigil.pg_sync_state ss ON ss.instance_id = k.sending_id
         AND (k.source = 'sync names'
              OR (k.source = 'sender' AND k.gone_reads > 0 AND lower(k.application_name) IN (SELECT lower(x) FROM unnest(ss.names) x)))
    LEFT JOIN LATERAL pgvigil.pg_threshold(k.sending_id, 'standby_replay_lag') ts ON k.sending_id IS NOT NULL
    LEFT JOIN LATERAL pgvigil.pg_threshold(k.sending_id, 'standby_lag_bytes') bs ON k.sending_id IS NOT NULL
    LEFT JOIN LATERAL pgvigil.pg_threshold(k.standby_id, 'standby_lag_bytes') bb ON k.standby_id IS NOT NULL
    LEFT JOIN LATERAL pgvigil.pg_threshold(k.standby_id, 'restore_stall') rst ON k.standby_id IS NOT NULL
),
measured AS (
  SELECT j.*,
         -- bytes held for 2 reads: the sending server's replay position (its flush position on a standby that delays
         -- apply on purpose), else the standby's received - replayed (not judged on a delayed standby)
         -- (least() skips a NULL, so each pair is NULL unless both reads have a value: a first read is no 2 in a row)
         CASE WHEN NOT j.own_row AND NOT j.sender_view THEN NULL
              WHEN j.sender_view AND j.delay_s > 0 THEN CASE WHEN j.prev_flush_bytes IS NOT NULL AND j.flush_bytes IS NOT NULL THEN least(j.flush_bytes, j.prev_flush_bytes) END
              WHEN j.sender_view THEN CASE WHEN coalesce(j.prev_lag_bytes, j.prev_flush_bytes) IS NOT NULL AND coalesce(j.lag_bytes, j.flush_bytes) IS NOT NULL
                                           THEN least(coalesce(j.lag_bytes, j.flush_bytes), coalesce(j.prev_lag_bytes, j.prev_flush_bytes)) END   -- pg_receivewal / Barman: no replay position
              WHEN j.speaks AND j.has_receiver AND j.delay_s = 0 THEN CASE WHEN j.prev_rcv_bytes IS NOT NULL AND j.rcv_bytes IS NOT NULL THEN least(j.rcv_bytes, j.prev_rcv_bytes) END
         END AS bytes2,
         CASE WHEN j.sender_view AND j.prev_lag_secs IS NOT NULL AND j.lag_secs IS NOT NULL THEN least(j.lag_secs, j.prev_lag_secs) - j.delay_s END AS secs2,
         CASE WHEN j.sender_view THEN j.b_warn WHEN j.speaks THEN j.sb_warn END AS bw,
         CASE WHEN j.sender_view THEN j.b_crit WHEN j.speaks THEN j.sb_crit END AS bc,
         -- down_reads holds through one read with a receiver (the state's hysteresis), so has_receiver is not asked here
         (j.own_row AND j.speaks AND j.conninfo_set AND j.down_reads >= 2
          AND j.standby_platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')) AS is_down,
         (j.source = 'sender' AND j.sender_fresh AND j.gone_reads >= 2 AND NOT coalesce(j.link_speaks, false) AND NOT j.replaced
          AND j.sending_platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')) AS is_gone,
         (j.own_row AND j.speaks AND j.replay_paused AND j.prev_replay_paused
          AND j.standby_platform NOT IN ('rds', 'aurora', 'azure', 'cloudsql', 'alloydb')) AS is_paused,
         -- 'receiver down' is a warning only while restore_command still feeds replay past the last streamed position
         (j.restore_set AND j.replay_moved_at > j.down_since AND j.standby_replay_lsn > coalesce(j.standby_receive_lsn, '0/0'::pg_lsn)
          AND NOT (j.stall_min IS NOT NULL AND j.replay_moved_at < j.standby_read_at - make_interval(secs => j.stall_min * 60))) AS fed,
         -- a named synchronous standby not connected while num_sync still holds (fewer is pg_hadr_checks' critical)
         (j.source IN ('sync names', 'sender') AND j.in_sync >= j.sync_num AND j.sync_at > now() - interval '30 minutes') AS is_sync_absent
    FROM judged j
),
tiered AS (
  SELECT m.*,
         CASE WHEN (m.bc IS NOT NULL AND m.bytes2 >= m.bc * 1048576) OR (m.t_crit IS NOT NULL AND m.secs2 >= m.t_crit) THEN 'critical'
              WHEN (m.bw IS NOT NULL AND m.bytes2 >= m.bw * 1048576) OR (m.t_warn IS NOT NULL AND m.secs2 >= m.t_warn) THEN 'warning' END AS lag_sev,
         true AS tiered
    FROM measured m
)
SELECT t.source, t.sending_id, t.sending, t.link, t.application_name, t.client_addr, t.slot_name, t.sysid AS system_identifier,
       t.standby_id, t.standby,
       CASE WHEN t.source = 'slot' THEN 'missing: physical slot inactive'
            WHEN t.source = 'sync names' THEN 'missing: named in synchronous_standby_names'
            WHEN t.is_down THEN 'down: receiver'
            WHEN t.source = 'sender' AND NOT t.sender_fresh THEN 'sending server not read'
            WHEN t.source = 'sender' AND t.gone_reads > 0 AND t.replaced THEN 'replaced: the standby is back under another link'
            WHEN t.source = 'sender' AND t.gone_reads > 0 AND t.unreachable THEN 'down: standby unreachable'
            WHEN t.source = 'sender' AND t.gone_reads > 0 AND t.link_speaks AND t.has_receiver THEN 'moved: the standby streams from elsewhere'
            WHEN t.source = 'sender' AND t.gone_reads > 0 THEN 'down: no sender'
            WHEN t.is_paused OR (t.speaks AND t.replay_paused) THEN 'replay paused'
            WHEN t.source = 'standby' AND t.speaks AND t.has_receiver THEN 'streaming (its primary not monitored)'
            WHEN t.source = 'standby' AND t.speaks THEN 'no WAL receiver'
            WHEN t.source = 'standby' THEN 'standby not read'
            ELSE coalesce(t.sender_state, 'unknown') END AS status,
       t.sender_state, t.sync_state, t.lag_bytes AS sender_lag_bytes, t.flush_bytes AS sender_flush_bytes, t.lag_secs AS sender_lag_secs,
       t.receiver_status, t.sender_host, t.has_receiver, t.rcv_bytes AS standby_lag_bytes, t.min_apply_delay_ms, t.replay_paused,
       t.down_reads, t.gone_reads, t.last_seen, t.checked_at, t.standby_read_at, t.unreachable AS standby_unreachable,
       CASE WHEN t.is_down OR t.is_gone OR t.is_paused THEN NULL ELSE t.lag_sev END AS lag_severity,
       CASE WHEN t.is_down THEN 'receiver down' WHEN t.is_gone THEN 'standby gone' WHEN t.is_paused THEN 'replay paused'
            WHEN t.lag_sev IS NOT NULL THEN 'standby lag' WHEN t.is_sync_absent THEN 'synchronous standby absent' END AS check_name,
       CASE WHEN t.is_down THEN CASE WHEN t.fed OR t.has_receiver THEN 'warning' ELSE 'critical' END
            WHEN t.is_gone OR t.is_paused THEN 'critical'
            WHEN t.is_sync_absent THEN 'warning'
            ELSE t.lag_sev END AS severity,
       CASE WHEN t.is_down OR t.is_paused THEN t.standby_id WHEN t.is_gone THEN t.sending_id
            WHEN t.lag_sev IS NOT NULL THEN CASE WHEN t.sender_view THEN t.sending_id ELSE t.standby_id END
            WHEN t.is_sync_absent THEN t.sending_id END AS finding_id,
       CASE WHEN t.is_down THEN coalesce('slot ' || t.primary_slot, 'primary_conninfo')
            WHEN t.is_paused THEN 'replay'
            ELSE coalesce(nullif(t.application_name, ''), t.standby, '(no name)') || coalesce(' at ' || t.client_addr, '')
                 || coalesce(' (slot ' || t.slot_name || ')', '') END AS object,
       CASE WHEN t.is_down THEN t.standby_read_at WHEN t.is_paused THEN t.standby_read_at ELSE t.checked_at END AS at,
       CASE WHEN t.is_down THEN t.down_reads WHEN t.is_gone THEN t.gone_reads ELSE 2 END AS reads,
       CASE WHEN t.is_down THEN
              format('in recovery with primary_conninfo set and no WAL receiver for %s reads in a row (since %s UTC); %s',
                     t.down_reads, to_char(t.down_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
                     CASE WHEN t.has_receiver
                            THEN 'a WAL receiver is back (' || coalesce(t.receiver_status, 'status unknown') || '): the fault ends at the second read with it'
                          WHEN t.fed
                            THEN 'replay still advances through restore_command (last moved ' || to_char(t.replay_moved_at AT TIME ZONE 'UTC', 'HH24:MI:SS') || ' UTC): the standby follows whole WAL files, not the stream'
                          WHEN NOT coalesce(t.restore_set, false)
                            THEN 'no restore_command: nothing reaches the standby until the receiver is back'
                          WHEN t.replay_moved_at IS NULL OR t.replay_moved_at <= t.down_since
                            THEN 'replay has not moved since the receiver went down (restore_command finds nothing new)'
                          WHEN t.stall_min IS NOT NULL AND t.replay_moved_at < t.standby_read_at - make_interval(secs => t.stall_min * 60)
                            THEN 'replay has stopped: it last moved ' || to_char(t.replay_moved_at AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC (critical after ' || trim_scale(t.stall_min) || ' min, ' || t.stall_level || ')'
                          ELSE 'replay moved only through WAL already received: restore_command has brought nothing past it'
                     END || CASE WHEN t.replay_paused THEN '; replay is paused' ELSE '' END)
            WHEN t.is_gone THEN
              format('streamed from this server until %s UTC and has had no WAL sender for %s reads in a row: the standby is %s',
                     to_char(t.last_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'), t.gone_reads,
                     CASE WHEN t.unreachable THEN 'not answering pgvigil either (stopped or cut off)' ELSE 'stopped, cut off or no longer replicating' END)
            WHEN t.is_paused THEN 'replay is paused (pg_wal_replay_pause) for 2 reads in a row: the standby receives WAL and applies none of it'
            WHEN t.is_sync_absent THEN
              format('named in synchronous_standby_names (%s) and not connected; %s in sync of the %s it asks for: commits go on, one more loss and they wait',
                     t.sync_setting, t.in_sync, t.sync_num)
            WHEN t.lag_sev IS NOT NULL THEN
              concat_ws('; ',
                CASE WHEN t.bw IS NOT NULL AND t.bytes2 >= t.bw * 1048576 THEN format('%s not yet replayed (%s)', pg_size_pretty(t.bytes2::numeric),
                       CASE WHEN t.sender_view AND t.delay_s > 0 THEN 'the sender''s flush position: apply is delayed on purpose'
                            WHEN t.sender_view THEN 'the sender''s replay position' ELSE 'received - replayed on the standby' END) END,
                CASE WHEN t.t_warn IS NOT NULL AND t.secs2 >= t.t_warn THEN format('replay_lag %s s beyond the apply delay of %s s', round(t.secs2::numeric, 1), round(t.delay_s, 1)) END,
                format('2 reads in a row; warning %s MB / %s s, critical %s MB / %s s', coalesce(trim_scale(t.bw)::text, '-'), coalesce(trim_scale(t.t_warn)::text, '-'),
                       coalesce(trim_scale(t.bc)::text, '-'), coalesce(trim_scale(t.t_crit)::text, '-')))
       END AS detail,
       CASE WHEN t.is_down THEN format('no WAL receiver since %s UTC while primary_conninfo is set', to_char(t.down_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'))
            WHEN t.is_gone THEN format('no WAL sender since %s UTC (it last streamed %s UTC)', to_char(t.gone_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'),
                                       to_char(t.last_seen AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS'))
            WHEN t.is_paused THEN 'replay is paused'
            WHEN t.lag_sev IS NOT NULL THEN 'the standby is behind its primary (bytes not replayed or replay_lag past the thresholds)'
            WHEN t.is_sync_absent THEN 'named in synchronous_standby_names and not connected' END AS stable
  FROM tiered t;

-- ---------------------------------------------------------------------------------------------------------------
-- task 373: logical replication (the 'logical' collection, internal/collect/logical.go). Three state tables, one row per
-- object (no time series: the publisher's walsender of each subscription, with its lag over time, is the replication
-- collection's sender row of the slot, keyed 'slot:<name>').
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('subscription_silent', 'Logical replication: no message from the publisher for', 'minutes', 'over', 5, NULL, '{root,tag,instance}', 10080),
  ('table_sync_age',      'Logical replication: a table''s initial sync not finished after', 'minutes', 'over', 60, NULL, '{root,tag,instance}', 43200)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- pg_logical_subs: a subscriber's subscriptions. The counters are cumulative: *_rose_at is the newest read whose counter
-- was past the read before (a counter that went down was reset: not a rise); apply_rise_reads counts the reads in a row
-- whose apply_error_count rose, and apply_loop_at is the newest read where the rise was a failing loop (2 or more since
-- the read before, or a second rise in a row: a single rise of one is a disconnect); worker_down_reads counts the reads
-- in a row of an enabled subscription on a server not in recovery with no apply worker, or one with no message received
-- since it started (last_msg_receipt_time NULL: the collector sends NULL for PostgreSQL's '-infinity' of a new worker).
CREATE TABLE IF NOT EXISTS pgvigil.pg_logical_subs (
  instance_id        int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  datname            text NOT NULL,
  subname            text NOT NULL,
  read_at            timestamptz NOT NULL,
  is_present         boolean NOT NULL DEFAULT true,
  in_recovery        boolean,
  enabled            boolean,
  slot_name          text,
  publications       text,
  disable_on_error   boolean,
  worker_pid         int,
  received_lsn       pg_lsn,
  latest_end_lsn     pg_lsn,
  last_msg_at        timestamptz,
  silent_secs        double precision,
  sync_workers       int,
  apply_errors       bigint,
  sync_errors        bigint,
  conflicts          jsonb,
  conflicts_total    bigint,
  apply_rose_at      timestamptz,
  apply_rise_reads   int NOT NULL DEFAULT 0,
  apply_loop_at      timestamptz,
  sync_rose_at       timestamptz,
  conflicts_rose_at  timestamptz,
  worker_down_reads  int NOT NULL DEFAULT 0,
  disabled_since     timestamptz,
  rels_ready         text,
  PRIMARY KEY (instance_id, datname, subname)
);
-- the loop columns came after the first form of this file: a repository that ran that form by hand keeps its table
ALTER TABLE pgvigil.pg_logical_subs ADD COLUMN IF NOT EXISTS apply_rise_reads int NOT NULL DEFAULT 0,
                                    ADD COLUMN IF NOT EXISTS apply_loop_at timestamptz;
-- pg_logical_rels: the tables of a subscription whose initial sync has not finished (a ready table has no row)
CREATE TABLE IF NOT EXISTS pgvigil.pg_logical_rels (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  datname      text NOT NULL,
  subname      text NOT NULL,
  rel          text NOT NULL,
  state        text,
  state_since  timestamptz NOT NULL,
  read_at      timestamptz NOT NULL,
  PRIMARY KEY (instance_id, datname, subname, rel)
);
-- pg_logical_pubs: the publications per database of a publisher
CREATE TABLE IF NOT EXISTS pgvigil.pg_logical_pubs (
  instance_id  int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  datname      text NOT NULL,
  pubname      text NOT NULL,
  all_tables   boolean,
  operations   text,
  table_count  bigint,
  read_at      timestamptz NOT NULL,
  is_present   boolean NOT NULL DEFAULT true,
  PRIMARY KEY (instance_id, datname, pubname)
);

CREATE OR REPLACE FUNCTION pgvigil.import_logical(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM pgvigil.pg_logical_subs WHERE instance_id = p_instance_id AND read_at >= p_snapshot_at) THEN
    RETURN;   -- an older read than the state: nothing changes
  END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'collector_error' AND r->>'source' = 'subscriptions') THEN
    INSERT INTO pgvigil.pg_logical_subs AS s
           (instance_id, datname, subname, read_at, is_present, in_recovery, enabled, slot_name, publications, disable_on_error,
            worker_pid, received_lsn, latest_end_lsn, last_msg_at, silent_secs, sync_workers, apply_errors, sync_errors,
            conflicts, conflicts_total, worker_down_reads, disabled_since)
    SELECT p_instance_id, coalesce(r->>'datname', '?'), r->>'subname', p_snapshot_at, true, (r->>'in_recovery')::boolean,
           (r->>'enabled')::boolean, r->>'slot_name', r->>'publications', (r->>'disable_on_error')::boolean,
           (r->>'worker_pid')::int, (r->>'received_lsn')::pg_lsn, (r->>'latest_end_lsn')::pg_lsn,
           (r->>'last_msg_receipt_time')::timestamptz, (r->>'silent_secs')::float8, (r->>'sync_workers')::int,
           (r->>'apply_error_count')::bigint, (r->>'sync_error_count')::bigint,
           c.conflicts, c.total,
           CASE WHEN (r->>'enabled')::boolean AND NOT coalesce((r->>'in_recovery')::boolean, false)
                     AND (r->>'worker_pid' IS NULL OR r->>'last_msg_receipt_time' IS NULL) THEN 1 ELSE 0 END,
           CASE WHEN NOT (r->>'enabled')::boolean THEN p_snapshot_at END
      FROM jsonb_array_elements(p_payload) r
      CROSS JOIN LATERAL (
        SELECT jsonb_object_agg(k, (r->>k)::bigint) FILTER (WHERE r->>k IS NOT NULL) AS conflicts,
               sum((r->>k)::bigint) AS total
          FROM unnest(ARRAY['confl_insert_exists', 'confl_update_origin_differs', 'confl_update_exists', 'confl_update_missing',
                            'confl_delete_origin_differs', 'confl_delete_missing', 'confl_multiple_unique_conflicts',
                            'confl_update_deleted']) k) c
     WHERE r->>'kind' = 'subscription'
    ON CONFLICT (instance_id, datname, subname) DO UPDATE SET
      read_at = EXCLUDED.read_at, is_present = true, in_recovery = EXCLUDED.in_recovery, enabled = EXCLUDED.enabled,
      slot_name = EXCLUDED.slot_name, publications = EXCLUDED.publications, disable_on_error = EXCLUDED.disable_on_error,
      worker_pid = EXCLUDED.worker_pid, received_lsn = EXCLUDED.received_lsn, latest_end_lsn = EXCLUDED.latest_end_lsn,
      last_msg_at = EXCLUDED.last_msg_at, silent_secs = EXCLUDED.silent_secs, sync_workers = EXCLUDED.sync_workers,
      apply_rose_at = CASE WHEN s.is_present AND EXCLUDED.apply_errors > s.apply_errors THEN EXCLUDED.read_at ELSE s.apply_rose_at END,
      apply_rise_reads = CASE WHEN s.is_present AND EXCLUDED.apply_errors > s.apply_errors THEN s.apply_rise_reads + 1 ELSE 0 END,
      apply_loop_at = CASE WHEN s.is_present AND EXCLUDED.apply_errors > s.apply_errors
                                AND (EXCLUDED.apply_errors - s.apply_errors >= 2 OR s.apply_rise_reads >= 1)
                           THEN EXCLUDED.read_at ELSE s.apply_loop_at END,
      sync_rose_at = CASE WHEN s.is_present AND EXCLUDED.sync_errors > s.sync_errors THEN EXCLUDED.read_at ELSE s.sync_rose_at END,
      conflicts_rose_at = CASE WHEN s.is_present AND EXCLUDED.conflicts_total > s.conflicts_total THEN EXCLUDED.read_at ELSE s.conflicts_rose_at END,
      apply_errors = EXCLUDED.apply_errors, sync_errors = EXCLUDED.sync_errors,
      conflicts = EXCLUDED.conflicts, conflicts_total = EXCLUDED.conflicts_total,
      worker_down_reads = CASE WHEN EXCLUDED.worker_down_reads = 1 THEN s.worker_down_reads + 1 ELSE 0 END,
      disabled_since = CASE WHEN NOT EXCLUDED.enabled THEN coalesce(s.disabled_since, EXCLUDED.read_at) END;
    -- a subscription no longer listed is gone (dropped): its unfinished tables go now, its row (the counters a
    -- re-created subscription must not be compared with) after 7 days
    UPDATE pgvigil.pg_logical_subs SET is_present = false
     WHERE instance_id = p_instance_id AND is_present AND read_at < p_snapshot_at;
    DELETE FROM pgvigil.pg_logical_rels l
     WHERE l.instance_id = p_instance_id
       AND NOT EXISTS (SELECT 1 FROM pgvigil.pg_logical_subs s
                        WHERE s.instance_id = l.instance_id AND s.datname = l.datname AND s.subname = l.subname AND s.is_present);
    DELETE FROM pgvigil.pg_logical_subs WHERE instance_id = p_instance_id AND NOT is_present AND read_at < p_snapshot_at - interval '7 days';
  END IF;

  -- per database read: its unfinished tables and its publications replace what was there; a database not read keeps them
  UPDATE pgvigil.pg_logical_subs s SET rels_ready = r->>'state'
    FROM jsonb_array_elements(p_payload) r
   WHERE r->>'kind' = 'sub_rels' AND s.instance_id = p_instance_id AND s.datname = r->>'datname' AND s.subname = r->>'subname';
  INSERT INTO pgvigil.pg_logical_rels AS l (instance_id, datname, subname, rel, state, state_since, read_at)
  SELECT p_instance_id, r->>'datname', r->>'subname', r->>'rel', r->>'state', p_snapshot_at, p_snapshot_at
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'sub_rel'
  ON CONFLICT (instance_id, datname, subname, rel) DO UPDATE SET
    state_since = CASE WHEN l.state IS DISTINCT FROM EXCLUDED.state THEN EXCLUDED.read_at ELSE l.state_since END,
    state = EXCLUDED.state, read_at = EXCLUDED.read_at;
  DELETE FROM pgvigil.pg_logical_rels l
   USING jsonb_array_elements(p_payload) d
   WHERE d->>'kind' = 'db_read' AND (d->>'subs')::boolean AND l.instance_id = p_instance_id AND l.datname = d->>'datname' AND l.read_at < p_snapshot_at;
  INSERT INTO pgvigil.pg_logical_pubs AS p (instance_id, datname, pubname, all_tables, operations, table_count, read_at, is_present)
  SELECT p_instance_id, r->>'datname', r->>'pubname', (r->>'puballtables')::boolean,
         concat_ws(', ', CASE WHEN (r->>'pubinsert')::boolean THEN 'insert' END, CASE WHEN (r->>'pubupdate')::boolean THEN 'update' END,
                   CASE WHEN (r->>'pubdelete')::boolean THEN 'delete' END, CASE WHEN (r->>'pubtruncate')::boolean THEN 'truncate' END),
         (r->>'table_count')::bigint, p_snapshot_at, true
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'publication'
  ON CONFLICT (instance_id, datname, pubname) DO UPDATE SET all_tables = EXCLUDED.all_tables, operations = EXCLUDED.operations,
    table_count = EXCLUDED.table_count, read_at = EXCLUDED.read_at, is_present = true;
  UPDATE pgvigil.pg_logical_pubs p SET is_present = false
    FROM jsonb_array_elements(p_payload) d
   WHERE d->>'kind' = 'db_read' AND (d->>'pubs')::boolean AND p.instance_id = p_instance_id AND p.datname = d->>'datname'
     AND p.is_present AND p.read_at < p_snapshot_at;
END $$;

-- pg_logical_checks: one finding per subscription (on the subscriber), the first that holds of:
--   'subscription apply errors'    critical: the apply worker fails and retries (apply_loop_at in the last 2 minutes,
--                                  pgvigil's own default: apply_error_count rose by 2 or more since the read before, or
--                                  rose on 2 reads in a row): a conflict (a row that exists, PostgreSQL 18 names it in
--                                  the conflict counters) or a missing table or column. A rise of one on one read is no
--                                  loop: PostgreSQL counts a streaming publisher's disconnect as one apply error
--                                  (measured on PostgreSQL 18; a failed reconnect is not counted), so the stop reads as
--                                  'worker down', not as apply errors
--   'subscription worker down'     critical: enabled, the server not in recovery, for 2 reads in a row no apply worker or
--                                  one that has received nothing since it started (a publisher that does not answer: the
--                                  relaunched worker waits in its connect with a pid and no message)
--   'subscription disabled'        warning; critical when disable_on_error is set and the apply errors rose in the 5
--                                  minutes before it was disabled (the error disabled it)
--   'subscription sync errors'     warning: sync_error_count rose in the last 2 minutes (a table's initial copy fails)
--   'subscription conflicts'       warning: a PostgreSQL 18 conflict counter rose in the last 2 minutes (a conflict
--                                  applied or skipped without an error: update_missing, delete_missing, origin_differs)
--   'table sync not finished'      warning: a table not ready for longer than 'table_sync_age' (60 minutes)
--   'subscription silent'          warning: no message from the publisher for 'subscription_silent' (5 minutes) while
--                                  the worker runs (the publisher keeps the link alive every wal_sender_timeout / 2)
-- On a server in recovery a subscription runs no worker (it replicates as the standby): only 'disabled' is judged there.
CREATE OR REPLACE VIEW pgvigil.pg_logical_checks AS
WITH s AS (
  SELECT s.*, i.name AS instance,
         (s.apply_loop_at > s.read_at - interval '2 minutes') AS apply_now,
         (s.sync_rose_at > s.read_at - interval '2 minutes') AS sync_now,
         (s.conflicts_rose_at > s.read_at - interval '2 minutes') AS confl_now,
         (SELECT string_agg(l.rel || ' (' || l.state || ' since ' || to_char(l.state_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC)', ', ' ORDER BY l.rel)
            FROM pgvigil.pg_logical_rels l
           WHERE l.instance_id = s.instance_id AND l.datname = s.datname AND l.subname = s.subname
             AND ts.warn IS NOT NULL AND l.state_since < s.read_at - make_interval(secs => ts.warn * 60)) AS slow_rels,
         ss.warn AS silent_min
    FROM pgvigil.pg_logical_subs s
    JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
    CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'table_sync_age') ts
    CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'subscription_silent') ss
   WHERE s.is_present AND s.read_at > now() - interval '30 minutes'
),
c AS (
  SELECT s.*,
         CASE WHEN s.apply_now AND s.enabled AND NOT coalesce(s.in_recovery, false) THEN 'subscription apply errors'
              WHEN s.enabled AND NOT coalesce(s.in_recovery, false) AND s.worker_down_reads >= 2 THEN 'subscription worker down'
              WHEN NOT s.enabled THEN 'subscription disabled'
              WHEN s.sync_now AND NOT coalesce(s.in_recovery, false) THEN 'subscription sync errors'
              WHEN s.confl_now AND NOT coalesce(s.in_recovery, false) THEN 'subscription conflicts'
              WHEN s.slow_rels IS NOT NULL AND NOT coalesce(s.in_recovery, false) THEN 'table sync not finished'
              WHEN s.enabled AND NOT coalesce(s.in_recovery, false) AND s.worker_pid IS NOT NULL AND s.silent_min IS NOT NULL
                   AND s.silent_secs > s.silent_min * 60 THEN 'subscription silent' END AS check_name
    FROM s
)
SELECT c.instance_id,
       CASE c.check_name
         WHEN 'subscription apply errors' THEN 'critical'
         WHEN 'subscription worker down' THEN 'critical'
         WHEN 'subscription disabled' THEN CASE WHEN c.disable_on_error AND c.apply_rose_at >= c.disabled_since - interval '5 minutes' THEN 'critical' ELSE 'warning' END
         ELSE 'warning' END AS severity,
       c.check_name, c.datname || '.' || c.subname AS object, c.read_at AS at,
       CASE c.check_name
         WHEN 'subscription apply errors' THEN format('apply_error_count %s, rising (last at %s UTC): the apply worker fails and retries%s; the server log names the row and the error',
                c.apply_errors, to_char(c.apply_rose_at AT TIME ZONE 'UTC', 'HH24:MI:SS'),
                CASE WHEN c.conflicts_total > 0 THEN '; conflicts ' || c.conflicts::text ELSE '' END)
         WHEN 'subscription worker down' THEN format('enabled with no apply worker receiving for %s reads in a row (%s): the publisher (%s) refuses, does not answer, or the worker cannot start',
                c.worker_down_reads, CASE WHEN c.worker_pid IS NULL THEN 'no worker' ELSE 'worker ' || c.worker_pid || ' has received nothing since it started' END, c.publications)
         WHEN 'subscription disabled' THEN format('disabled since %s UTC%s: nothing is applied and the publisher''s slot %s keeps its WAL',
                to_char(c.disabled_since AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
                CASE WHEN c.disable_on_error AND c.apply_rose_at >= c.disabled_since - interval '5 minutes' THEN ' by disable_on_error after an apply error' ELSE '' END,
                coalesce(c.slot_name, '(none)'))
         WHEN 'subscription sync errors' THEN format('sync_error_count %s, rising: a table''s initial copy fails%s', c.sync_errors, coalesce('; not ready: ' || c.slow_rels, ''))
         WHEN 'subscription conflicts' THEN format('conflicts rising: %s', c.conflicts::text)
         WHEN 'table sync not finished' THEN format('tables not ready: %s (%s ready)', c.slow_rels, coalesce(c.rels_ready, '?'))
         WHEN 'subscription silent' THEN format('no message from the publisher for %s s (the worker runs)', round(c.silent_secs::numeric))
       END AS detail,
       CASE c.check_name
         WHEN 'subscription apply errors' THEN 'the apply worker fails and retries'
         WHEN 'subscription worker down' THEN 'enabled with no apply worker receiving'
         WHEN 'subscription disabled' THEN 'disabled'
         WHEN 'subscription sync errors' THEN 'a table''s initial copy fails'
         WHEN 'subscription conflicts' THEN 'conflicts rising'
         WHEN 'table sync not finished' THEN 'tables not ready'
         WHEN 'subscription silent' THEN 'no message from the publisher'
       END AS stable
  FROM c
 WHERE c.check_name IS NOT NULL;

-- pg_logical_status: the Replication page's subscriptions block - one row per subscription with its publisher's walsender
-- (the slot's sender row on a monitored instance) and its one finding.
CREATE OR REPLACE VIEW pgvigil.pg_logical_status AS
SELECT s.instance_id, i.name AS instance, s.datname, s.subname, s.enabled, s.in_recovery, s.publications, s.slot_name,
       s.worker_pid, s.last_msg_at, s.silent_secs, s.sync_workers, s.rels_ready, s.apply_errors, s.sync_errors, s.conflicts,
       s.disabled_since, s.read_at,
       snd.instance_id AS publisher_id, pi.name AS publisher, snd.state AS sender_state, snd.lag_bytes AS sender_lag_bytes,
       snd.lag_secs AS sender_lag_secs,
       k.severity, k.check_name, k.detail
  FROM pgvigil.pg_logical_subs s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
  LEFT JOIN LATERAL (SELECT r.* FROM pgvigil.replication_latest r
                      WHERE r.kind = 'sender' AND r.detail->>'slot_type' = 'logical' AND r.detail->>'slot_name' = s.slot_name
                        AND r.instance_id <> s.instance_id
                        AND (SELECT count(DISTINCT r2.instance_id) FROM pgvigil.replication_latest r2
                              WHERE r2.kind = 'sender' AND r2.detail->>'slot_type' = 'logical' AND r2.detail->>'slot_name' = s.slot_name
                                AND r2.instance_id <> s.instance_id) = 1   -- a slot name two publishers share pairs with neither
                      ORDER BY r.snapshot_at DESC LIMIT 1) snd ON true
  LEFT JOIN pgvigil.instances pi ON pi.instance_id = snd.instance_id
  LEFT JOIN pgvigil.pg_logical_checks k ON k.instance_id = s.instance_id AND k.object = s.datname || '.' || s.subname
 WHERE s.is_present;

-- pg_hadr_checks: the streaming replication rules of this file, one row per finding (instance_id, severity, check_name,
-- object, at, detail, reads, stable): one per link at most. detail is the newest read's account (the Summary and the
-- Replication page); stable is the text the findings carry. A read older than 30 minutes raises nothing (the
-- Collections page says the collection is stale); a managed platform's standbys are the provider's.
CREATE OR REPLACE VIEW pgvigil.pg_hadr_checks AS
SELECT h.finding_id AS instance_id, h.severity, h.check_name, h.object, h.at, h.detail, h.reads, h.stable
  FROM pgvigil.pg_repl_link_health h
 WHERE h.check_name IS NOT NULL AND h.finding_id IS NOT NULL
UNION ALL
-- task 372: fewer standbys in sync than synchronous_standby_names asks for (one row per primary, not per link)
SELECT y.instance_id, CASE WHEN y.commit_level IN ('off', 'local') THEN 'warning' ELSE 'critical' END, 'synchronous commits waiting',
       'synchronous_standby_names', y.snapshot_at,
       format('%s standby(s) in sync of the %s that synchronous_standby_names = ''%s'' asks for (%s)%s; %s',
              y.in_sync, y.num_sync, y.setting, coalesce('senders: ' || y.senders, 'no sender connected'),
              coalesce('; named and not connected: ' || array_to_string(y.absent, ', '), ''),
              CASE WHEN y.commit_level IN ('off', 'local') THEN 'synchronous_commit is ' || y.commit_level || ' at the server: sessions that keep it do not wait, those that set on / remote_write / remote_apply do'
                   ELSE 'every commit waits (synchronous_commit ' || y.commit_level || ') until a standby is back or the setting changes' END),
       1, format('fewer synchronous standbys than synchronous_standby_names = ''%s'' asks for', y.setting)
  FROM pgvigil.pg_sync_state y
  JOIN pgvigil.instances i ON i.instance_id = y.instance_id AND i.is_active
 WHERE y.in_sync < y.num_sync AND y.snapshot_at > now() - interval '30 minutes'
UNION ALL
-- task 373: logical replication, one finding per subscription
SELECT k.instance_id, k.severity, k.check_name, k.object, k.at, k.detail, 1, k.stable
  FROM pgvigil.pg_logical_checks k
UNION ALL
-- task 374: one finding per slot (a temporary slot, and a failover slot synced to a standby, are not judged)
SELECT x.instance_id,
       CASE WHEN x.check_name = 'slot invalidated' THEN 'critical'
            WHEN x.check_name = 'slot WAL near its limit' AND x.wal_status = 'unreserved' THEN 'critical'
            ELSE 'warning' END,
       x.check_name, 'slot ' || x.key, x.snapshot_at,
       CASE x.check_name
         WHEN 'slot invalidated' THEN format('invalidated (%s): the slot can no longer be used; its consumer must be rebuilt (a standby from a new base backup, a subscription or CDC task re-synced)',
                                             coalesce(x.reason, 'wal_status lost'))
         WHEN 'slot WAL near its limit' THEN format('%s of WAL left before max_slot_wal_keep_size (%s) invalidates it (wal_status %s; retains %s; warning under %s MB or half the limit, the smaller)',
                                                    pg_size_pretty(x.safe_bytes), pg_size_pretty(x.max_keep), x.wal_status, pg_size_pretty(x.lag_bytes), trim_scale(x.safe_warn))
         WHEN 'slot WAL growing' THEN format('retained WAL grew %s in the last full hour (closed %s UTC; now %s; warning at %s MB)',
                                             pg_size_pretty(x.growth_bytes_h), to_char(x.growth_at AT TIME ZONE 'UTC', 'HH24:MI'), pg_size_pretty(x.lag_bytes), trim_scale(x.growth_warn))
       END,
       1,
       CASE x.check_name WHEN 'slot invalidated' THEN 'the slot is invalidated'
                         WHEN 'slot WAL near its limit' THEN 'the slot is near max_slot_wal_keep_size'
                         ELSE 'the slot keeps more WAL every hour' END
  FROM (SELECT r.instance_id, r.key, r.snapshot_at, r.lag_bytes, r.detail->>'wal_status' AS wal_status, r.detail->>'invalidation_reason' AS reason,
               (r.detail->>'safe_wal_size')::bigint AS safe_bytes, (r.detail->>'max_keep_bytes')::bigint AS max_keep,
               st.growth_bytes_h, st.growth_at, sw.warn AS safe_warn, gw.warn AS growth_warn,
               CASE WHEN r.detail->>'invalidation_reason' IS NOT NULL OR r.detail->>'wal_status' = 'lost' THEN 'slot invalidated'
                    WHEN r.detail->>'wal_status' = 'unreserved'
                         OR (sw.warn IS NOT NULL AND (r.detail->>'safe_wal_size')::bigint
                               < least(sw.warn * 1048576, (r.detail->>'max_keep_bytes')::bigint / 2)) THEN 'slot WAL near its limit'
                    WHEN gw.warn IS NOT NULL AND st.growth_bytes_h >= gw.warn * 1048576 AND st.growth_at > now() - interval '2 hours' THEN 'slot WAL growing'
               END AS check_name
          FROM pgvigil.replication_latest r
          JOIN pgvigil.instances i ON i.instance_id = r.instance_id AND i.is_active
          LEFT JOIN pgvigil.pg_repl_slot_state st ON st.instance_id = r.instance_id AND st.slot_name = r.key
          CROSS JOIN LATERAL pgvigil.pg_threshold(r.instance_id, 'slot_safe_wal') sw
          CROSS JOIN LATERAL pgvigil.pg_threshold(r.instance_id, 'slot_growth') gw
         WHERE r.kind = 'slot' AND r.snapshot_at > now() - interval '30 minutes'
           AND NOT coalesce((r.detail->>'temporary')::boolean, false) AND NOT coalesce((r.detail->>'synced')::boolean, false)) x
 WHERE x.check_name IS NOT NULL
UNION ALL
-- task 374: an Aurora reader, judged by aurora_replica_status on the writer alone (the writer's own row is left out)
SELECT a.instance_id, CASE WHEN t.crit IS NOT NULL AND a.lag_secs >= t.crit THEN 'critical' ELSE 'warning' END, 'Aurora replica lag',
       'replica ' || a.key, a.snapshot_at,
       format('the Aurora replica %s is %s s behind the writer (aurora_replica_status; warning %s s, critical %s s, %s)', a.key, round(a.lag_secs::numeric, 1),
              coalesce(trim_scale(t.warn)::text, '-'), coalesce(trim_scale(t.crit)::text, '-'), t.level),
       1, 'the Aurora replica is behind the writer'
  FROM pgvigil.replication_latest a
  JOIN pgvigil.instances i ON i.instance_id = a.instance_id AND i.is_active
  CROSS JOIN LATERAL pgvigil.pg_threshold(a.instance_id, 'standby_replay_lag') t
 WHERE a.kind = 'aurora_replica' AND a.snapshot_at > now() - interval '30 minutes'
   AND coalesce(a.state, '') <> 'MASTER_SESSION_ID' AND coalesce(t.warn, t.crit) IS NOT NULL AND a.lag_secs >= coalesce(t.warn, t.crit)
   -- a reader returns the same aurora_replica_status rows: the writer alone raises (one finding per lagging replica)
   AND NOT EXISTS (SELECT 1 FROM pgvigil.pg_repl_standby_state st WHERE st.instance_id = a.instance_id AND st.in_recovery);

-- 0006's daily-check view again with a severity column at its end (for the Summary's 'replication' overview and the
-- Replication page, which judge severity by check name until they read this column: the join's wiring): a base backup's senders out of 'sender not streaming' and the replay-lag check (task 370
-- a); a physical link's sender state and lag are judged once per link by pg_hadr_checks (task 371), an Aurora replica's
-- lag and a slot's WAL status by its rows (task 374), so 'sender not streaming' and 'replay lag' keep logical senders only; pg_hadr_checks' rows (value = the reads in
-- a row, state = the finding's detail).
CREATE OR REPLACE VIEW pgvigil.replication_checks AS
  SELECT instance_id, snapshot_at, 'inactive slot retaining WAL' AS check_name, key AS object,
         lag_bytes AS value, 'bytes' AS unit, detail->>'wal_status' AS state, 'warning'::text AS severity
    FROM pgvigil.replication_latest
   WHERE kind = 'slot' AND NOT coalesce(active, false) AND coalesce(lag_bytes, 0) > 0
     AND NOT coalesce((detail->>'synced')::boolean, false)      -- a failover slot synced from the primary is always inactive on a PG17 standby
  UNION ALL
  SELECT instance_id, snapshot_at, 'sender not streaming', key, lag_bytes, 'bytes', state, 'warning'
    FROM pgvigil.replication_latest
   WHERE kind = 'sender' AND state IS DISTINCT FROM 'streaming' AND detail->>'slot_type' = 'logical'
  UNION ALL
  SELECT instance_id, snapshot_at, 'replay lag', key, lag_secs::bigint, 'seconds', state, 'warning'
    FROM pgvigil.replication_latest
   WHERE coalesce(lag_secs, 0) > 30 AND kind = 'sender' AND detail->>'slot_type' = 'logical'
  UNION ALL
  -- 0006's time rule on the standby side, kept for a standby no monitored primary sends to (the link rule judges the rest)
  SELECT r.instance_id, r.snapshot_at, 'replay lag', r.key, r.lag_secs::bigint, 'seconds', r.state, 'warning'
    FROM pgvigil.replication_latest r
   WHERE r.kind = 'receiver' AND coalesce(r.lag_secs, 0) > 30
     AND NOT EXISTS (SELECT 1 FROM pgvigil.pg_repl_link_health h WHERE h.standby_id = r.instance_id AND h.sending_id IS NOT NULL)
  UNION ALL
  -- a read that failed is a check of its own: an unreadable slot list must not look healthy
  SELECT d.instance_id, d.snapshot_at, 'replication read failed', split_part(d.note, ':', 1), NULL::bigint, NULL, d.note, 'warning'
    FROM pgvigil.collection_dates d
   WHERE d.collection = 'replication' AND d.status = 'partial'
  UNION ALL
  SELECT h.instance_id, h.at, h.check_name, h.object, h.reads::bigint, 'read(s) in a row', h.detail, h.severity
    FROM pgvigil.pg_hadr_checks h;

-- 0103's Summary rows and findings again (its section 4, every arm kept): the 'log shipping' arm leaves out a standby with
-- primary_conninfo set, and the 'replication' check group carries pg_hadr_checks (to pgvigil.findings through
-- pg_backups_findings, so the alert sender sends them; the Summary shows them through replication_checks); the findings'
-- platforms column says 'aurora' for 'Aurora replica lag' (every other row keeps 0103's 'self-managed').
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
                                   WHEN 'standby gone' THEN 'start the standby or reconnect it; if it was retired on purpose, the finding ends 7 days after it was last seen'
                                   WHEN 'replay paused' THEN 'resume replay on the standby (SELECT pg_wal_replay_resume()) unless it was paused on purpose'
                                   WHEN 'standby lag' THEN 'find what holds the standby back: a query conflicting with replay (max_standby_streaming_delay, hot_standby_feedback), slow disk or network, a long apply'
                                   WHEN 'synchronous commits waiting' THEN 'bring a synchronous standby back, or change synchronous_standby_names: until then commits wait'
                                   WHEN 'synchronous standby absent' THEN 'bring the named standby back or take its name out of synchronous_standby_names'
                                   WHEN 'subscription apply errors' THEN 'read the subscriber''s server log for the failing change (a conflicting row, a missing table or column), fix the data or ALTER SUBSCRIPTION ... SKIP the transaction'
                                   WHEN 'subscription worker down' THEN 'check that the publisher answers and accepts the subscription''s connection, and the subscriber''s max_logical_replication_workers'
                                   WHEN 'subscription disabled' THEN 'ALTER SUBSCRIPTION ... ENABLE once its cause is fixed, or drop it (and its slot on the publisher)'
                                   WHEN 'subscription sync errors' THEN 'read the subscriber''s server log for the failing initial copy (a row already there, a missing column)'
                                   WHEN 'subscription conflicts' THEN 'read the subscriber''s server log for the conflicts: changes are being skipped or applied over other rows'
                                   WHEN 'table sync not finished' THEN 'check the tablesync workers (max_sync_workers_per_subscription) and the server log for the copy'
                                   WHEN 'subscription silent' THEN 'check the publisher and the network between them: the publisher sends a keepalive every wal_sender_timeout / 2'
                                   WHEN 'slot invalidated' THEN 'rebuild the slot''s consumer (a standby from a new base backup, a subscription or CDC task re-synced), then drop the invalidated slot'
                                   WHEN 'slot WAL near its limit' THEN 'find why the slot''s consumer lags or is offline and bring it back, or raise max_slot_wal_keep_size if the disk allows: at the limit the slot is invalidated'
                                   WHEN 'slot WAL growing' THEN 'find why the slot''s consumer does not confirm (offline, slow, a long transaction on the publisher); drop the slot if nothing uses it'
                                   WHEN 'Aurora replica lag' THEN 'read the replica''s CloudWatch AuroraReplicaLag and its load (a long query on the reader, an undersized instance class)'
                                   ELSE 'see the Replication page'
                                 END
         ELSE 'schedule the amcheck collection for the database (README: the amcheck collection)'
       END AS suggested, CASE WHEN c.check_name = 'Aurora replica lag' THEN 'aurora' ELSE 'self-managed' END AS platforms,
       CASE c.check_group
         WHEN 'base backups' THEN 'without a recent base backup a restore replays more WAL, or has nothing to start from'
         WHEN 'log shipping' THEN 'a standby that falls behind loses what it has not replayed if it must take over'
         WHEN 'crashes' THEN 'a crash restart ends every session and replays WAL from the last checkpoint'
         WHEN 'statement store' THEN 'evicted statements drop out of the statement history'
         WHEN 'replication' THEN CASE WHEN c.check_name LIKE 'subscription%' OR c.check_name = 'table sync not finished'
                                     THEN 'a subscriber that does not apply falls behind its publisher, and the publisher''s slot keeps WAL until it does'
                                     WHEN c.check_name LIKE 'slot %'
                                     THEN 'a slot keeps WAL until its consumer confirms it: the disk fills, or past max_slot_wal_keep_size the slot is invalidated and its consumer must be rebuilt'
                                     WHEN c.check_name = 'synchronous commits waiting'
                                     THEN 'a commit waits until enough synchronous standbys confirm it: the applications stall'
                                     WHEN c.check_name = 'Aurora replica lag'
                                     THEN 'reads on a lagging replica return old data, and a failover to it takes longer'
                                     ELSE 'a standby that does not stream falls behind: a failover to it loses what it has not received' END
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
   AND EXISTS (SELECT 1 FROM pgvigil.databases d WHERE d.instance_id = i.instance_id AND d.is_present)
   AND NOT EXISTS (SELECT 1 FROM pgvigil.amcheck_runs a WHERE a.instance_id = i.instance_id);
