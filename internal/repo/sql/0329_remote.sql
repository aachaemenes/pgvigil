-- 0329: the remote collector's hub (docs/remote-collector.md, docs/remote-bundle-format.md). A hub loads each site's
-- bundles once (internal/ingest): the sites as remote_sites: names them, each remote collector's heartbeat, the bundles
-- and their batches (the once-only ledgers), each stream's high-water, the marks (late, conflict, gap, a bundle set
-- aside, an audit gap), the instance a site owns (owner, as_of), the batch loader, the silence findings and the three
-- views the pages read (remote_instance_state, remote_collector_state, remote_collection_interval).
-- The findings view's arms, alert_due's clear_after floor and purge()'s lines belong to objects a join file defines
-- (0300): scripts/REMOTE-join-lines.sql, stood in for the proofs by scripts/remote-join-draft.sql.

-- the instance a site owns ('<site>/<name>'; NULL = the hub's own configuration) and the window end of its newest loaded
-- bundle (the pages' 'as of')
ALTER TABLE pgvigil.instances ADD COLUMN IF NOT EXISTS owner text;
ALTER TABLE pgvigil.instances ADD COLUMN IF NOT EXISTS as_of timestamptz;

-- remote_sites: each site as the hub's remote_sites: names it, synced by ingest at each start (remote_site_sync)
CREATE TABLE IF NOT EXISTS pgvigil.remote_sites (
  name                 text PRIMARY KEY,
  tags                 text[] NOT NULL DEFAULT '{}',
  expected_every_secs  int NOT NULL,
  gap_wait_secs        int NOT NULL,
  synced_at            timestamptz NOT NULL DEFAULT now()
);

-- remote_collectors: each remote collector's heartbeat as its newest loaded bundle carried it (never collector_hosts:
-- a transfer's delay is not a collector down)
CREATE TABLE IF NOT EXISTS pgvigil.remote_collectors (
  site             text NOT NULL,
  collector        text NOT NULL,
  pgvigil_version  text,
  host             text,
  started          timestamptz,
  heartbeat_at     timestamptz,
  instances        int,
  fail_streak      int,
  updated_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (site, collector)
);

-- remote_bundles: one row per bundle begun (a bundle's digest is the sha256 of its manifest.json): 'loading' while its
-- batches go in, 'loaded' once its end is recorded; a stopped bundle resumes on the same row
CREATE TABLE IF NOT EXISTS pgvigil.remote_bundles (
  bundle_id     bigserial PRIMARY KEY,
  site          text NOT NULL,
  collector     text NOT NULL,
  instance_key  text NOT NULL,
  stream        text NOT NULL,
  seq           bigint NOT NULL,
  window_from   timestamptz NOT NULL,
  window_to     timestamptz NOT NULL,
  digest        text NOT NULL,
  instance_id   int REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  state         text NOT NULL DEFAULT 'loading' CHECK (state IN ('loading', 'loaded')),
  begun_at      timestamptz NOT NULL DEFAULT now(),
  loaded_at     timestamptz,
  UNIQUE (site, collector, instance_key, stream, seq, digest)
);
CREATE INDEX IF NOT EXISTS remote_bundles_instance ON pgvigil.remote_bundles (instance_id, window_to DESC) WHERE state = 'loaded';

-- remote_batches: each batch loaded, by its bundle and its number (n is unique across a bundle's views)
CREATE TABLE IF NOT EXISTS pgvigil.remote_batches (
  bundle_id  bigint NOT NULL REFERENCES pgvigil.remote_bundles(bundle_id) ON DELETE CASCADE,
  n          int NOT NULL,
  view       text NOT NULL,
  loaded_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (bundle_id, n)
);

-- remote_streams: each stream's newest loaded seq (kept for good: the purge leaves it)
CREATE TABLE IF NOT EXISTS pgvigil.remote_streams (
  site          text NOT NULL,
  collector     text NOT NULL,
  instance_key  text NOT NULL,
  stream        text NOT NULL,
  instance_id   int REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  high_seq      bigint NOT NULL,
  high_end      timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (site, collector, instance_key, stream)
);

-- remote_marks: a bundle not loaded (late, conflict, newer format, signature, mismatch, unknown view, or a format check's
-- kind: missing, short, checksum, extra, malformed, too_big, count), a gap ingest went past, an audit cursor moved over
-- a gap; kept until a person clears it
CREATE TABLE IF NOT EXISTS pgvigil.remote_marks (
  mark_id       bigserial PRIMARY KEY,
  site          text NOT NULL,
  collector     text NOT NULL,
  instance_key  text NOT NULL,
  stream        text NOT NULL,
  seq           bigint NOT NULL,
  window_to     timestamptz,
  kind          text NOT NULL,
  reason        text NOT NULL,
  digest        text NOT NULL DEFAULT '',
  marked_at     timestamptz NOT NULL DEFAULT now(),
  cleared_at    timestamptz,
  cleared_by    text
);
-- one mark per bundle and kind: each round finds a set-aside bundle again
CREATE UNIQUE INDEX IF NOT EXISTS remote_marks_once ON pgvigil.remote_marks (site, collector, instance_key, stream, seq, kind, digest)
  WHERE kind <> 'audit gap';

-- remote_intervals: each collection's interval on its remote collector (the manifest's reads[].interval_secs)
CREATE TABLE IF NOT EXISTS pgvigil.remote_intervals (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collection     text NOT NULL,
  interval_secs  int NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instance_id, collection)
);

-- remote_site_sync: a site as remote_sites: names it now
CREATE OR REPLACE FUNCTION pgvigil.remote_site_sync(p_name text, p_tags text[], p_expected_every_secs int, p_gap_wait_secs int)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.remote_sites (name, tags, expected_every_secs, gap_wait_secs, synced_at)
  VALUES (p_name, coalesce(p_tags, '{}'), p_expected_every_secs, p_gap_wait_secs, now())
  ON CONFLICT (name) DO UPDATE SET tags = EXCLUDED.tags, expected_every_secs = EXCLUDED.expected_every_secs,
    gap_wait_secs = EXCLUDED.gap_wait_secs, synced_at = now()
$$;

-- import_remote_ensure: the instance a site's bundle names, '<site>/<name>', owned by the site; its tags the manifest's
-- and the site's. A name another site or the hub's own configuration holds is refused; an instance an admin disabled
-- stays disabled (its id is returned, nothing of it changes).
CREATE OR REPLACE FUNCTION pgvigil.import_remote_ensure(p_site text, p_engine text, p_name text, p_platform text,
  p_server_version text, p_version_num int, p_is_replica boolean, p_tags text[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_full    text := p_site || '/' || p_name;
  v_id      int;
  v_owner   text;
  v_active  boolean;
  v_tags    text[];
BEGIN
  SELECT instance_id, owner, is_active INTO v_id, v_owner, v_active FROM pgvigil.instances WHERE name = v_full;
  IF v_id IS NOT NULL AND v_owner IS DISTINCT FROM p_site THEN
    RAISE EXCEPTION 'import_remote_ensure: instance % is owned elsewhere (%): the bundle is set aside', v_full,
      coalesce('site ' || v_owner, 'this hub''s own configuration');
  END IF;
  IF v_id IS NOT NULL AND NOT v_active THEN
    RETURN v_id;
  END IF;
  v_tags := ARRAY(SELECT DISTINCT t FROM unnest(coalesce(p_tags, '{}') || coalesce((SELECT s.tags FROM pgvigil.remote_sites s WHERE s.name = p_site), '{}')) AS t ORDER BY 1);
  v_id := pgvigil.ensure_instance(v_full, p_platform, p_server_version, p_version_num, p_is_replica, v_tags, p_engine);
  UPDATE pgvigil.instances SET owner = p_site WHERE instance_id = v_id AND owner IS DISTINCT FROM p_site;
  RETURN v_id;
END $$;

-- remote_bundle_begin: the bundle's ledger row (the same one again for the same digest: a stopped bundle resumes)
CREATE OR REPLACE FUNCTION pgvigil.remote_bundle_begin(p_site text, p_collector text, p_key text, p_stream text, p_seq bigint,
  p_from timestamptz, p_to timestamptz, p_digest text, p_instance_id int)
RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO pgvigil.remote_bundles (site, collector, instance_key, stream, seq, window_from, window_to, digest, instance_id)
  VALUES (p_site, p_collector, p_key, p_stream, p_seq, p_from, p_to, p_digest, p_instance_id)
  ON CONFLICT (site, collector, instance_key, stream, seq, digest) DO UPDATE SET instance_id = EXCLUDED.instance_id
  RETURNING bundle_id
$$;

-- import_remote_batch: one batch of a bundle, loaded once - its ledger row and its rows in this one call (one
-- transaction). True = loaded now, false = it was already. The view must be one a collector writes through its import
-- function and never one a bundle may not reach (the collector's own health, the alerts, the actions' log, the DBA
-- Dash door, these ledgers, the SQL Server cursor the hub keeps): ingest's allow-list checks the same first. After a
-- gap (p_after_gap), an audit batch's sources have their stored cursor moved to the batch's start - with the move
-- recorded as an 'audit gap' with both ends - so import_mssql_audit's own compare-and-swap takes it.
CREATE OR REPLACE FUNCTION pgvigil.import_remote_batch(p_bundle_id bigint, p_view text, p_n int, p_instance_id int,
  p_at timestamptz, p_rows jsonb, p_after_gap boolean DEFAULT false)
RETURNS boolean LANGUAGE plpgsql AS $$
DECLARE
  v_c     record;
  v_file  text;
  v_off   bigint;
  v_there boolean;
BEGIN
  IF p_view IS NULL OR p_view !~ '^[a-z][a-z0-9_]{0,62}$' OR p_view = 'mssql_cursor' OR p_view = 'actions_log'
     OR p_view LIKE 'collector\_%' OR p_view LIKE 'alert\_%' OR p_view LIKE 'dbadash\_%' OR p_view LIKE 'remote\_%'
     OR to_regprocedure('pgvigil.import_' || p_view || '(integer, timestamp with time zone, jsonb)') IS NULL THEN
    RAISE EXCEPTION 'import_remote_batch: % is not a view a bundle may carry', coalesce(p_view, '(null)');
  END IF;
  INSERT INTO pgvigil.remote_batches (bundle_id, n, view) VALUES (p_bundle_id, p_n, p_view) ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN
    RETURN false;
  END IF;
  IF p_after_gap AND p_view = 'mssql_audit' THEN
    FOR v_c IN
      SELECT DISTINCT ON (r->>'source') r->>'source' AS source, r->>'from_file' AS from_file, (r->>'from_offset')::bigint AS from_offset
        FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS t(r, n)
       WHERE r->>'kind' = 'cursor' AND r->>'source' IS NOT NULL
       ORDER BY r->>'source', n
    LOOP
      v_file := NULL; v_off := NULL;
      SELECT c.file_name, c.file_offset INTO v_file, v_off FROM pgvigil.mssql_cursor c WHERE c.instance_id = p_instance_id AND c.source = v_c.source;
      v_there := FOUND;
      CONTINUE WHEN v_there AND v_file IS NOT DISTINCT FROM v_c.from_file AND v_off IS NOT DISTINCT FROM v_c.from_offset;
      CONTINUE WHEN NOT v_there AND v_c.from_file IS NULL;
      IF v_c.from_file IS NULL THEN
        DELETE FROM pgvigil.mssql_cursor WHERE instance_id = p_instance_id AND source = v_c.source;
      ELSE
        INSERT INTO pgvigil.mssql_cursor (instance_id, source, file_name, file_offset, updated_at)
        VALUES (p_instance_id, v_c.source, v_c.from_file, v_c.from_offset, now())
        ON CONFLICT (instance_id, source) DO UPDATE SET file_name = EXCLUDED.file_name, file_offset = EXCLUDED.file_offset, updated_at = now();
      END IF;
      INSERT INTO pgvigil.remote_marks (site, collector, instance_key, stream, seq, window_to, kind, reason)
      SELECT b.site, b.collector, b.instance_key, b.stream, b.seq, b.window_to, 'audit gap',
             format('audit source %s: the cursor moved from %s @ %s to %s @ %s - the audit between them is not in the hub', v_c.source,
                    coalesce(v_file, 'none'), coalesce(v_off::text, '-'), coalesce(v_c.from_file, 'none'), coalesce(v_c.from_offset::text, '-'))
        FROM pgvigil.remote_bundles b WHERE b.bundle_id = p_bundle_id;
    END LOOP;
  END IF;
  EXECUTE format('SELECT pgvigil.%I($1, $2, $3)', 'import_' || p_view) USING p_instance_id, p_at, p_rows;
  RETURN true;
END $$;

-- remote_bundle_done: a bundle's end, in one transaction - the ledger row loaded, the stream's high-water, the
-- instance's as_of (the newest window end), the collector's heartbeat (a newer one only) and its collections' intervals
CREATE OR REPLACE FUNCTION pgvigil.remote_bundle_done(p_bundle_id bigint, p_heartbeat jsonb, p_intervals jsonb, p_version text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_b pgvigil.remote_bundles;
BEGIN
  UPDATE pgvigil.remote_bundles SET state = 'loaded', loaded_at = now() WHERE bundle_id = p_bundle_id RETURNING * INTO v_b;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remote_bundle_done: no bundle %', p_bundle_id;
  END IF;
  INSERT INTO pgvigil.remote_streams AS s (site, collector, instance_key, stream, instance_id, high_seq, high_end)
  VALUES (v_b.site, v_b.collector, v_b.instance_key, v_b.stream, v_b.instance_id, v_b.seq, v_b.window_to)
  ON CONFLICT (site, collector, instance_key, stream) DO UPDATE
    SET high_seq = greatest(s.high_seq, EXCLUDED.high_seq),
        high_end = CASE WHEN EXCLUDED.high_seq >= s.high_seq THEN EXCLUDED.high_end ELSE s.high_end END,
        instance_id = EXCLUDED.instance_id, updated_at = now();
  UPDATE pgvigil.instances SET as_of = greatest(as_of, v_b.window_to) WHERE instance_id = v_b.instance_id;
  INSERT INTO pgvigil.remote_collectors AS c (site, collector, pgvigil_version, host, started, heartbeat_at, instances, fail_streak)
  VALUES (v_b.site, v_b.collector, p_version, p_heartbeat->>'host', (p_heartbeat->>'started')::timestamptz, (p_heartbeat->>'at')::timestamptz,
          (p_heartbeat->>'instances')::int, (p_heartbeat->>'fail_streak')::int)
  ON CONFLICT (site, collector) DO UPDATE
    SET pgvigil_version = EXCLUDED.pgvigil_version, host = EXCLUDED.host, started = EXCLUDED.started, heartbeat_at = EXCLUDED.heartbeat_at,
        instances = EXCLUDED.instances, fail_streak = EXCLUDED.fail_streak, updated_at = now()
    WHERE c.heartbeat_at IS NULL OR EXCLUDED.heartbeat_at >= c.heartbeat_at;
  INSERT INTO pgvigil.remote_intervals AS r (instance_id, collection, interval_secs)
  SELECT v_b.instance_id, x->>'collection', (x->>'interval_secs')::int
    FROM jsonb_array_elements(coalesce(p_intervals, '[]')) AS x
   WHERE coalesce((x->>'interval_secs')::int, 0) > 0
  ON CONFLICT (instance_id, collection) DO UPDATE SET interval_secs = EXCLUDED.interval_secs, updated_at = now();
END $$;

-- remote_mark: a bundle not loaded, or a gap ingest went past (once per bundle and kind)
CREATE OR REPLACE FUNCTION pgvigil.remote_mark(p_site text, p_collector text, p_key text, p_stream text, p_seq bigint,
  p_window_to timestamptz, p_kind text, p_reason text, p_digest text)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.remote_marks (site, collector, instance_key, stream, seq, window_to, kind, reason, digest)
  VALUES (p_site, p_collector, p_key, p_stream, p_seq, p_window_to, p_kind, p_reason, coalesce(p_digest, ''))
  ON CONFLICT (site, collector, instance_key, stream, seq, kind, digest) WHERE kind <> 'audit gap' DO NOTHING
$$;

-- the three views the hub's pages read (contract 2)
CREATE OR REPLACE VIEW pgvigil.remote_instance_state AS
SELECT i.instance_id, i.name, i.engine, i.owner AS site, b.collector, i.as_of,
       extract(epoch FROM b.window_to - b.window_from)::int AS interval_secs, s.expected_every_secs, b.loaded_at
  FROM pgvigil.instances i
  LEFT JOIN LATERAL (SELECT x.collector, x.window_from, x.window_to, x.loaded_at FROM pgvigil.remote_bundles x
                      WHERE x.instance_id = i.instance_id AND x.state = 'loaded'
                      ORDER BY x.window_to DESC, x.bundle_id DESC LIMIT 1) b ON true
  LEFT JOIN pgvigil.remote_sites s ON s.name = i.owner
 WHERE i.owner IS NOT NULL;

CREATE OR REPLACE VIEW pgvigil.remote_collector_state AS
SELECT k.site, k.collector, c.pgvigil_version, c.host, c.heartbeat_at, c.instances, c.fail_streak,
       (SELECT max(b.window_to) FROM pgvigil.remote_bundles b WHERE b.site = k.site AND b.collector = k.collector AND b.state = 'loaded') AS newest_bundle_at,
       count(m.mark_id) FILTER (WHERE m.kind = 'gap')::int AS gaps,
       count(m.mark_id) FILTER (WHERE m.kind NOT IN ('gap', 'late', 'conflict', 'audit gap'))::int AS set_aside,
       (SELECT x.kind || ': ' || x.reason FROM pgvigil.remote_marks x
         WHERE x.site = k.site AND x.collector = k.collector AND x.cleared_at IS NULL AND x.kind NOT IN ('gap', 'late', 'conflict', 'audit gap')
         ORDER BY x.marked_at DESC, x.mark_id DESC LIMIT 1) AS newest_set_aside_reason,
       count(m.mark_id) FILTER (WHERE m.kind = 'late')::int AS late,
       count(m.mark_id) FILTER (WHERE m.kind = 'conflict')::int AS conflicts
  FROM (SELECT site, collector FROM pgvigil.remote_collectors
        UNION SELECT site, collector FROM pgvigil.remote_bundles
        UNION SELECT site, collector FROM pgvigil.remote_marks) k
  LEFT JOIN pgvigil.remote_collectors c ON c.site = k.site AND c.collector = k.collector
  LEFT JOIN pgvigil.remote_marks m ON m.site = k.site AND m.collector = k.collector AND m.cleared_at IS NULL
 GROUP BY k.site, k.collector, c.pgvigil_version, c.host, c.heartbeat_at, c.instances, c.fail_streak;

CREATE OR REPLACE VIEW pgvigil.remote_collection_interval AS
SELECT instance_id, collection, interval_secs FROM pgvigil.remote_intervals;

-- remote_silence_findings: a site, and each of its instances, whose newest loaded bundle ended more than 2 x
-- expected_every ago (warning; 6 x critical) - a finding's columns, joined into pgvigil.findings by
-- scripts/REMOTE-join-lines.sql line 1. A site that never sent is judged from its first sync.
CREATE OR REPLACE VIEW pgvigil.remote_silence_findings AS
WITH site AS (
  SELECT s.name, s.expected_every_secs, coalesce((SELECT max(b.window_to) FROM pgvigil.remote_bundles b WHERE b.site = s.name AND b.state = 'loaded'), s.synced_at) AS newest,
         EXISTS (SELECT 1 FROM pgvigil.remote_bundles b WHERE b.site = s.name AND b.state = 'loaded') AS sent
    FROM pgvigil.remote_sites s
), inst AS (
  SELECT i.instance_id, i.name, i.owner, i.as_of, s.expected_every_secs
    FROM pgvigil.instances i JOIN pgvigil.remote_sites s ON s.name = i.owner
   WHERE i.is_active AND i.as_of IS NOT NULL
)
SELECT NULL::int AS instance_id,
       CASE WHEN now() - newest > make_interval(secs => 6 * expected_every_secs) THEN 'critical' ELSE 'warning' END AS severity,
       'remote site quiet'::text AS setting, name AS value, true AS is_set,
       format('a bundle every %s s or sooner', expected_every_secs) AS suggested, 'all'::text AS platforms,
       format('site %s has gone quiet: last bundle %s', name, CASE WHEN sent THEN to_char(newest AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"') ELSE 'never' END) AS detail,
       'remote collector'::text AS source, newest AS at
  FROM site
 WHERE now() - newest > make_interval(secs => 2 * expected_every_secs)
UNION ALL
SELECT instance_id,
       CASE WHEN now() - as_of > make_interval(secs => 6 * expected_every_secs) THEN 'critical' ELSE 'warning' END,
       'remote instance quiet', name, true, format('a bundle every %s s or sooner', expected_every_secs), 'all',
       format('instance %s of site %s has gone quiet: last bundle %s', name, owner, to_char(as_of AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"')),
       'remote collector', as_of
  FROM inst
 WHERE now() - as_of > make_interval(secs => 2 * expected_every_secs);

-- the reader (serve's pages) reads the views; nobody but the repository's owner (ingest inside pgvigil run) writes
DO $$
DECLARE t regclass;
BEGIN
  FOREACH t IN ARRAY ARRAY['pgvigil.remote_sites', 'pgvigil.remote_collectors', 'pgvigil.remote_bundles', 'pgvigil.remote_batches',
    'pgvigil.remote_streams', 'pgvigil.remote_marks', 'pgvigil.remote_intervals', 'pgvigil.remote_instance_state',
    'pgvigil.remote_collector_state', 'pgvigil.remote_collection_interval', 'pgvigil.remote_silence_findings']::regclass[]
  LOOP
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, pgvigil_collector, pgvigil_auth', t);
    EXECUTE format('GRANT SELECT ON %s TO pgvigil_reader', t);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION pgvigil.remote_site_sync(text, text[], int, int), pgvigil.import_remote_ensure(text, text, text, text, text, int, boolean, text[]),
  pgvigil.remote_bundle_begin(text, text, text, text, bigint, timestamptz, timestamptz, text, int),
  pgvigil.import_remote_batch(bigint, text, int, int, timestamptz, jsonb, boolean),
  pgvigil.remote_bundle_done(bigint, jsonb, jsonb, text), pgvigil.remote_mark(text, text, text, text, bigint, timestamptz, text, text, text)
  FROM PUBLIC;
