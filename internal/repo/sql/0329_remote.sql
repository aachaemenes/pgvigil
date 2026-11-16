-- 0329: the remote collector's hub (docs/remote-collector.md, docs/remote-bundle-format.md). A hub loads each site's
-- bundles once (internal/ingest): the sites as remote_sites: names them (and their collectors), each remote collector's
-- heartbeat, the bundles and their batches (the once-only ledgers), each stream's high-water, the hub's first sight of
-- each bundle folder (the settle clock), the marks (late, conflict, gap, a bundle set aside, an audit gap, a retry), the
-- instance a site owns (owner, as_of), the batch loader, the silence findings and the three views the pages read
-- (remote_instance_state, remote_collector_state, remote_collection_interval).
-- INGEST'S DOOR: every function below that writes (and the loader's reads) is pgvigil_ingest's alone - ingest runs on its
-- own login, a member of pgvigil_ingest, never the collector's (a collector login could otherwise load a batch row and
-- hide a site's data) and never the owner. apply_roles (0300) gives the door its SECURITY DEFINER and grants:
-- scripts/REMOTE-join-lines.sql line 4.
-- The findings view's arm, alert_due's clear_after floor, purge()'s line and apply_roles' ingest door belong to objects a
-- join file defines (0300): scripts/REMOTE-join-lines.sql, stood in for the proofs by scripts/remote-join-draft.sql.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'pgvigil_ingest') THEN
    CREATE ROLE pgvigil_ingest NOLOGIN;
  END IF;
END $$;
GRANT USAGE ON SCHEMA pgvigil TO pgvigil_ingest;

-- the instance a site owns ('<site>/<name>'; NULL = the hub's own configuration) and the window end of its newest loaded
-- bundle (the pages' 'as of')
ALTER TABLE pgvigil.instances ADD COLUMN IF NOT EXISTS owner text;
ALTER TABLE pgvigil.instances ADD COLUMN IF NOT EXISTS as_of timestamptz;

-- remote_sites: each site as the hub's remote_sites: names it, synced by ingest each round (remote_site_sync); a site no
-- longer listed is inactive (remote_sites_retire): no silence finding, no Collector row
CREATE TABLE IF NOT EXISTS pgvigil.remote_sites (
  name                 text PRIMARY KEY,
  tags                 text[] NOT NULL DEFAULT '{}',
  expected_every_secs  int NOT NULL,
  gap_wait_secs        int NOT NULL,
  collectors           text[],                              -- the configured collectors (NULL: not synced yet)
  active               boolean NOT NULL DEFAULT true,
  first_synced_at      timestamptz NOT NULL DEFAULT now(),  -- a site that never sent goes quiet from here
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
-- batches go in, 'loaded' once its end is recorded; a stopped bundle resumes on the same row. query_text: the
-- manifest's statement-text mode (contract 3: the pages read a remote instance's policy from it)
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
  query_text    text NOT NULL DEFAULT 'hash' CHECK (query_text IN ('hash', 'none')),
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

-- remote_streams: each stream's newest loaded seq and when the hub last loaded one of it (kept for good: the purge
-- leaves it, so a site's silence is judged by its newest load after its bundles are purged)
CREATE TABLE IF NOT EXISTS pgvigil.remote_streams (
  site            text NOT NULL,
  collector       text NOT NULL,
  instance_key    text NOT NULL,
  stream          text NOT NULL,
  instance_id     int REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  high_seq        bigint NOT NULL,
  high_end        timestamptz NOT NULL,
  high_loaded_at  timestamptz NOT NULL DEFAULT now(),  -- the hub's clock: the silence findings read it
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (site, collector, instance_key, stream)
);

-- remote_sightings: the hub's first sight of each bundle folder - the settle clock (a copy still running is waited for
-- gap_wait from here, never from the bundle's window end: a backlog copied late is not past it on arrival)
CREATE TABLE IF NOT EXISTS pgvigil.remote_sightings (
  site          text NOT NULL,
  collector     text NOT NULL,
  instance_key  text NOT NULL,
  dir           text NOT NULL,
  first_seen    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (site, collector, dir)
);

-- remote_marks: a bundle not loaded (late, conflict, newer format, signature, mismatch, unknown view, owned, load,
-- drop error, or a format check's kind: missing, short, checksum, extra, malformed, too_big, count), a gap ingest went
-- past, an audit cursor moved over a gap, a retry asked by 'pgvigil ingest -retry'; open until cleared (a load of its
-- seq, -retry, or a person)
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
-- one OPEN mark per bundle and kind: each round finds a set-aside bundle again; a cleared mark never hides the same
-- failure seen again
CREATE UNIQUE INDEX IF NOT EXISTS remote_marks_once ON pgvigil.remote_marks (site, collector, instance_key, stream, seq, kind, digest)
  WHERE kind <> 'audit gap' AND cleared_at IS NULL;

-- remote_intervals: each collection's interval on its remote collector (the newest loaded bundle's reads[].interval_secs)
CREATE TABLE IF NOT EXISTS pgvigil.remote_intervals (
  instance_id    int NOT NULL REFERENCES pgvigil.instances(instance_id) ON DELETE CASCADE,
  collection     text NOT NULL,
  interval_secs  int NOT NULL,
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (instance_id, collection)
);

-- remote_site_sync: a site as remote_sites: names it now (its collectors too); a retired site listed again is active
CREATE OR REPLACE FUNCTION pgvigil.remote_site_sync(p_name text, p_tags text[], p_expected_every_secs int, p_gap_wait_secs int,
  p_collectors text[] DEFAULT NULL)
RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.remote_sites (name, tags, expected_every_secs, gap_wait_secs, collectors)
  VALUES (p_name, coalesce(p_tags, '{}'), p_expected_every_secs, p_gap_wait_secs, p_collectors)
  ON CONFLICT (name) DO UPDATE SET tags = EXCLUDED.tags, expected_every_secs = EXCLUDED.expected_every_secs,
    gap_wait_secs = EXCLUDED.gap_wait_secs, collectors = coalesce(EXCLUDED.collectors, pgvigil.remote_sites.collectors),
    active = true, synced_at = now()
$$;

-- remote_sites_retire: every site not in p_names (the configuration's remote_sites: now) is inactive; its rows stay
CREATE OR REPLACE FUNCTION pgvigil.remote_sites_retire(p_names text[])
RETURNS int LANGUAGE sql AS $$
  WITH r AS (UPDATE pgvigil.remote_sites SET active = false WHERE active AND NOT (name = ANY (coalesce(p_names, '{}'))) RETURNING 1)
  SELECT count(*)::int FROM r
$$;

-- ensure_instance (0063's, whole, with one guard first): the hub's own configuration - pgvigil.yaml, Admin > Instances,
-- the demo, DBA Dash - never takes a name a remote site owns (it would write live rows into the site's instance). The
-- remote instance itself is made by remote_ensure_instance, which never calls this. The 6-argument form calls this one,
-- so both refuse.
CREATE OR REPLACE FUNCTION pgvigil.ensure_instance(
  p_name text, p_platform text, p_server_version text, p_version_num int, p_is_replica boolean, p_tags text[], p_engine text)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE v_id int; v_have text; v_owner text;
BEGIN
  SELECT engine, owner INTO v_have, v_owner FROM pgvigil.instances WHERE name = p_name;
  IF v_owner IS NOT NULL THEN
    RAISE EXCEPTION 'ensure_instance: instance % is read by remote site % (remote_sites:): this hub''s own configuration cannot hold that name; give the server another name', p_name, v_owner;
  END IF;
  IF p_engine IS NULL OR p_engine NOT IN ('postgres', 'sqlserver') THEN
    RAISE EXCEPTION 'ensure_instance: unknown engine %', coalesce(p_engine, '(null)');
  END IF;
  IF v_have IS NOT NULL AND v_have <> p_engine THEN
    RAISE EXCEPTION 'ensure_instance: instance % is already stored as engine %, not %; give the other server its own name', p_name, v_have, p_engine;
  END IF;
  INSERT INTO pgvigil.instances AS i (name, platform, server_version, server_version_num, is_replica, tags, engine)
  VALUES (p_name, p_platform, p_server_version, p_version_num, p_is_replica, coalesce(p_tags, '{}'), p_engine)
  ON CONFLICT (name) DO UPDATE
     SET platform = EXCLUDED.platform,
         server_version = EXCLUDED.server_version,
         server_version_num = EXCLUDED.server_version_num,
         is_replica = EXCLUDED.is_replica,
         tags = EXCLUDED.tags,
         last_seen = now(),
         is_active = true
   -- the read above is for the clear message; this is the guard: two first calls of one new name under two
   -- engines both pass the read, and the second one's update then matches no row instead of the other engine's;
   -- a row a site took meanwhile matches none either
   WHERE i.engine = p_engine AND i.owner IS NULL
  RETURNING instance_id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'ensure_instance: instance % is already stored as engine % or read by a remote site; give the server its own name',
      p_name, (SELECT engine FROM pgvigil.instances WHERE name = p_name);
  END IF;
  RETURN v_id;
END $$;

-- remote_ensure_instance: the instance a site's bundle names, '<site>/<name>', owned by the site; its tags the manifest's
-- and the site's; its own upsert (never ensure_instance). A name another site or the hub's own configuration holds is
-- refused; a platform, version or replica flag the manifest leaves empty keeps the stored one (a collector restarted
-- while the server was down knows none). An instance an admin disabled stays disabled - its id is returned and its
-- bundles still load (their rows, runs and as_of), so the history has no hole if it is enabled again.
CREATE OR REPLACE FUNCTION pgvigil.remote_ensure_instance(p_site text, p_engine text, p_name text, p_platform text,
  p_server_version text, p_version_num int, p_is_replica boolean, p_tags text[])
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_full    text := p_site || '/' || p_name;
  v_id      int;
  v_owner   text;
  v_active  boolean;
  v_engine  text;
  v_tags    text[];
BEGIN
  IF p_engine IS NULL OR p_engine NOT IN ('postgres', 'sqlserver') THEN
    RAISE EXCEPTION 'remote_ensure_instance: unknown engine %', coalesce(p_engine, '(null)');
  END IF;
  SELECT instance_id, owner, is_active, engine INTO v_id, v_owner, v_active, v_engine FROM pgvigil.instances WHERE name = v_full;
  IF v_id IS NOT NULL AND v_owner IS DISTINCT FROM p_site THEN
    RAISE EXCEPTION 'remote_ensure_instance: instance % is owned elsewhere (%): the bundle is set aside', v_full,
      coalesce('site ' || v_owner, 'this hub''s own configuration');
  END IF;
  IF v_id IS NOT NULL AND v_engine <> p_engine THEN
    RAISE EXCEPTION 'remote_ensure_instance: instance % is stored as engine %, its bundle says %: the bundle is set aside', v_full, v_engine, p_engine;
  END IF;
  IF v_id IS NOT NULL AND NOT v_active THEN
    RETURN v_id;
  END IF;
  v_tags := ARRAY(SELECT DISTINCT t FROM unnest(coalesce(p_tags, '{}') || coalesce((SELECT s.tags FROM pgvigil.remote_sites s WHERE s.name = p_site), '{}')) AS t ORDER BY 1);
  INSERT INTO pgvigil.instances AS i (name, platform, server_version, server_version_num, is_replica, tags, engine, owner)
  VALUES (v_full, nullif(p_platform, ''), nullif(p_server_version, ''), nullif(p_version_num, 0), coalesce(p_is_replica, false), v_tags, p_engine, p_site)
  ON CONFLICT (name) DO UPDATE
     SET platform = coalesce(EXCLUDED.platform, i.platform),
         server_version = coalesce(EXCLUDED.server_version, i.server_version),
         server_version_num = coalesce(EXCLUDED.server_version_num, i.server_version_num),
         is_replica = CASE WHEN EXCLUDED.server_version IS NULL THEN i.is_replica ELSE EXCLUDED.is_replica END,
         tags = EXCLUDED.tags,
         last_seen = now(),
         is_active = true
   WHERE i.owner = p_site AND i.engine = p_engine
  RETURNING instance_id INTO v_id;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'remote_ensure_instance: instance % is owned elsewhere (taken while this bundle loaded): the bundle is set aside', v_full;
  END IF;
  RETURN v_id;
END $$;

-- remote_seen: the hub's first sight of a bundle folder (the settle clock), recorded once
CREATE OR REPLACE FUNCTION pgvigil.remote_seen(p_site text, p_collector text, p_key text, p_dir text)
RETURNS timestamptz LANGUAGE plpgsql AS $$
DECLARE v timestamptz;
BEGIN
  INSERT INTO pgvigil.remote_sightings (site, collector, instance_key, dir) VALUES (p_site, p_collector, p_key, p_dir)
  ON CONFLICT DO NOTHING;
  SELECT first_seen INTO v FROM pgvigil.remote_sightings WHERE site = p_site AND collector = p_collector AND dir = p_dir;
  RETURN v;
END $$;

-- remote_newest: a key's newest loaded bundle (of one stream; '' = of any stream): its stream, seq and window end
CREATE OR REPLACE FUNCTION pgvigil.remote_newest(p_site text, p_collector text, p_key text, p_stream text)
RETURNS TABLE (stream text, high_seq bigint, high_end timestamptz) LANGUAGE sql STABLE AS $$
  SELECT s.stream, s.high_seq, s.high_end FROM pgvigil.remote_streams s
   WHERE s.site = p_site AND s.collector = p_collector AND s.instance_key = p_key AND (p_stream = '' OR s.stream = p_stream)
   ORDER BY s.high_end DESC LIMIT 1
$$;

-- remote_recorded: what the ledger holds for a bundle's seq - loaded (with its digest), loading (a bundle begun and
-- stopped part-way, with its digest), or its newest open mark (not a gap) - else nothing
CREATE OR REPLACE FUNCTION pgvigil.remote_recorded(p_site text, p_collector text, p_key text, p_stream text, p_seq bigint)
RETURNS TABLE (digest text, kind text) LANGUAGE sql STABLE AS $$
  SELECT x.digest, x.kind FROM (
    SELECT b.digest, b.state AS kind, CASE b.state WHEN 'loaded' THEN 0 ELSE 1 END AS o, coalesce(b.loaded_at, b.begun_at) AS at
      FROM pgvigil.remote_bundles b
     WHERE b.site = p_site AND b.collector = p_collector AND b.instance_key = p_key AND b.stream = p_stream AND b.seq = p_seq
    UNION ALL
    SELECT m.digest, m.kind, 2, m.marked_at FROM pgvigil.remote_marks m
     WHERE m.site = p_site AND m.collector = p_collector AND m.instance_key = p_key AND m.stream IN (p_stream, '') AND m.seq = p_seq
       AND m.cleared_at IS NULL AND m.kind NOT IN ('gap', 'audit gap')) x
   ORDER BY x.o, x.at DESC LIMIT 1
$$;

-- remote_retries: the window ends of a key's bundles with an open 'retry' (the round lists their days too)
CREATE OR REPLACE FUNCTION pgvigil.remote_retries(p_site text, p_collector text, p_key text)
RETURNS SETOF timestamptz LANGUAGE sql STABLE AS $$
  SELECT DISTINCT m.window_to FROM pgvigil.remote_marks m
   WHERE m.site = p_site AND m.collector = p_collector AND m.instance_key = p_key AND m.kind = 'retry' AND m.cleared_at IS NULL
     AND m.window_to IS NOT NULL
$$;

-- remote_retry: 'pgvigil ingest -retry' - a bundle's open marks (not its gaps) cleared and a 'retry' recorded, so the next
-- round reads it again even past the stream's newest (loaded after a gap); refused when the seq's marks name more than
-- one stream. The number of marks cleared.
CREATE OR REPLACE FUNCTION pgvigil.remote_retry(p_site text, p_collector text, p_key text, p_seq bigint)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  v_streams text[];
  v_end     timestamptz;
  n         int;
BEGIN
  SELECT array_agg(DISTINCT stream) FILTER (WHERE stream <> ''), max(window_to) INTO v_streams, v_end FROM pgvigil.remote_marks
   WHERE site = p_site AND collector = p_collector AND instance_key = p_key AND seq = p_seq AND cleared_at IS NULL
     AND kind NOT IN ('gap', 'audit gap', 'retry');
  IF coalesce(array_length(v_streams, 1), 0) > 1 THEN
    RAISE EXCEPTION 'remote_retry: seq % of %/%/% has marks in more than one stream (%): clear the one meant by hand', p_seq, p_site, p_collector, p_key, array_to_string(v_streams, ', ');
  END IF;
  UPDATE pgvigil.remote_marks SET cleared_at = now(), cleared_by = 'pgvigil ingest -retry'
   WHERE site = p_site AND collector = p_collector AND instance_key = p_key AND seq = p_seq AND cleared_at IS NULL
     AND kind NOT IN ('gap', 'audit gap');
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n > 0 THEN
    INSERT INTO pgvigil.remote_marks (site, collector, instance_key, stream, seq, window_to, kind, reason)
    VALUES (p_site, p_collector, p_key, coalesce(v_streams[1], ''), p_seq, v_end, 'retry', 'pgvigil ingest -retry')
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN n;
END $$;

-- remote_bundle_begin: the bundle's ledger row (the same one again for the same digest: a stopped bundle resumes)
CREATE OR REPLACE FUNCTION pgvigil.remote_bundle_begin(p_site text, p_collector text, p_key text, p_stream text, p_seq bigint,
  p_from timestamptz, p_to timestamptz, p_digest text, p_instance_id int, p_query_text text DEFAULT 'hash')
RETURNS bigint LANGUAGE sql AS $$
  INSERT INTO pgvigil.remote_bundles (site, collector, instance_key, stream, seq, window_from, window_to, digest, instance_id, query_text)
  VALUES (p_site, p_collector, p_key, p_stream, p_seq, p_from, p_to, p_digest, p_instance_id, coalesce(nullif(p_query_text, ''), 'hash'))
  ON CONFLICT (site, collector, instance_key, stream, seq, digest) DO UPDATE SET instance_id = EXCLUDED.instance_id
  RETURNING bundle_id
$$;

-- remote_batch: one batch of a bundle, loaded once - its ledger row and its rows in this one call (one transaction).
-- True = loaded now, false = it was already. The view must be one a collector writes through its import function and
-- never one a bundle may not reach (the collector's own health, the alerts, the actions' log, the DBA Dash door, these
-- ledgers, the SQL Server cursor the hub keeps): ingest's allow-list checks the same first. After a gap (p_after_gap),
-- an audit batch's sources have their stored cursor moved to the batch's start - with the move recorded as an 'audit
-- gap' with both ends - so import_mssql_audit's own compare-and-swap takes it.
CREATE OR REPLACE FUNCTION pgvigil.remote_batch(p_bundle_id bigint, p_view text, p_n int, p_instance_id int,
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
    RAISE EXCEPTION 'remote_batch: % is not a view a bundle may carry', coalesce(p_view, '(null)');
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

-- remote_bundle_done: a bundle's end, in one transaction - the ledger row loaded, the stream's high-water and the hub's
-- load time, the instance's as_of (the newest window end), the collector's heartbeat (a newer one only), its collections'
-- intervals (from the newest bundle only; a collection it no longer reports loses its row), the manifest's runs
-- (log_collection) and failures (a connect failure through import_connect_failure with its cause; a secret one through
-- log_collection 'secret: ...' as the collector's own LogSecretFailure writes it), the gap ingest went past to load it
-- (p_gap: its reason), and the open set-aside marks of its seq cleared (a copy that finished, a retry that loaded)
CREATE OR REPLACE FUNCTION pgvigil.remote_bundle_done(p_bundle_id bigint, p_heartbeat jsonb, p_intervals jsonb, p_version text,
  p_runs jsonb DEFAULT '[]', p_failures jsonb DEFAULT '[]', p_gap text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_b    pgvigil.remote_bundles;
  v_i    pgvigil.instances;
  v_prev timestamptz;
  x      jsonb;
BEGIN
  UPDATE pgvigil.remote_bundles SET state = 'loaded', loaded_at = now() WHERE bundle_id = p_bundle_id RETURNING * INTO v_b;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'remote_bundle_done: no bundle %', p_bundle_id;
  END IF;
  SELECT * INTO v_i FROM pgvigil.instances WHERE instance_id = v_b.instance_id;
  v_prev := v_i.as_of;
  IF p_gap IS NOT NULL THEN
    INSERT INTO pgvigil.remote_marks (site, collector, instance_key, stream, seq, window_to, kind, reason, digest)
    VALUES (v_b.site, v_b.collector, v_b.instance_key, v_b.stream, v_b.seq, v_b.window_to, 'gap', p_gap, v_b.digest)
    ON CONFLICT DO NOTHING;
  END IF;
  INSERT INTO pgvigil.remote_streams AS s (site, collector, instance_key, stream, instance_id, high_seq, high_end, high_loaded_at)
  VALUES (v_b.site, v_b.collector, v_b.instance_key, v_b.stream, v_b.instance_id, v_b.seq, v_b.window_to, now())
  ON CONFLICT (site, collector, instance_key, stream) DO UPDATE
    SET high_seq = greatest(s.high_seq, EXCLUDED.high_seq),
        high_end = CASE WHEN EXCLUDED.high_seq >= s.high_seq THEN EXCLUDED.high_end ELSE s.high_end END,
        high_loaded_at = now(), instance_id = EXCLUDED.instance_id, updated_at = now();
  UPDATE pgvigil.instances SET as_of = greatest(as_of, v_b.window_to) WHERE instance_id = v_b.instance_id;
  INSERT INTO pgvigil.remote_collectors AS c (site, collector, pgvigil_version, host, started, heartbeat_at, instances, fail_streak)
  VALUES (v_b.site, v_b.collector, p_version, p_heartbeat->>'host', (p_heartbeat->>'started')::timestamptz, (p_heartbeat->>'at')::timestamptz,
          (p_heartbeat->>'instances')::int, (p_heartbeat->>'fail_streak')::int)
  ON CONFLICT (site, collector) DO UPDATE
    SET pgvigil_version = EXCLUDED.pgvigil_version, host = EXCLUDED.host, started = EXCLUDED.started, heartbeat_at = EXCLUDED.heartbeat_at,
        instances = EXCLUDED.instances, fail_streak = EXCLUDED.fail_streak, updated_at = now()
    WHERE c.heartbeat_at IS NULL OR EXCLUDED.heartbeat_at >= c.heartbeat_at;
  IF v_prev IS NULL OR v_b.window_to >= v_prev THEN
    DELETE FROM pgvigil.remote_intervals r WHERE r.instance_id = v_b.instance_id
       AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(coalesce(p_intervals, '[]')) AS e
                        WHERE e->>'collection' = r.collection AND coalesce((e->>'interval_secs')::int, 0) > 0);
    INSERT INTO pgvigil.remote_intervals AS r (instance_id, collection, interval_secs)
    SELECT v_b.instance_id, e->>'collection', (e->>'interval_secs')::int
      FROM jsonb_array_elements(coalesce(p_intervals, '[]')) AS e
     WHERE coalesce((e->>'interval_secs')::int, 0) > 0
    ON CONFLICT (instance_id, collection) DO UPDATE SET interval_secs = EXCLUDED.interval_secs, updated_at = now();
  END IF;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_runs, '[]')) LOOP
    PERFORM pgvigil.log_collection(v_b.instance_id, x->>'collection', (x->>'at')::timestamptz, coalesce((x->>'ms')::int, 0), x->>'status',
                                   nullif(x->>'note', ''), nullif(x->>'stage', ''));
  END LOOP;
  FOR x IN SELECT * FROM jsonb_array_elements(coalesce(p_failures, '[]')) LOOP
    CASE x->>'kind'
      WHEN 'connect' THEN
        PERFORM pgvigil.import_connect_failure(v_i.name, x->>'collection', (x->>'at')::timestamptz, coalesce((x->>'ms')::int, 0), x->>'cause',
                                               v_i.engine, v_i.platform, v_i.tags);
      WHEN 'secret' THEN
        PERFORM pgvigil.log_collection(v_b.instance_id, x->>'collection', (x->>'at')::timestamptz, coalesce((x->>'ms')::int, 0), 'error',
                                       'secret: ' || coalesce(x->>'cause', ''), NULL);
      ELSE
        PERFORM pgvigil.import_run_failure(v_i.name, v_i.engine, x->>'collection', (x->>'at')::timestamptz, coalesce((x->>'ms')::int, 0), x->>'cause');
    END CASE;
  END LOOP;
  UPDATE pgvigil.remote_marks SET cleared_at = now(), cleared_by = 'loaded'
   WHERE site = v_b.site AND collector = v_b.collector AND instance_key = v_b.instance_key AND seq = v_b.seq
     AND stream IN (v_b.stream, '') AND cleared_at IS NULL AND kind NOT IN ('gap', 'audit gap', 'late', 'conflict');
END $$;

-- remote_mark: a bundle not loaded, or a gap ingest went past (one open mark per bundle and kind); true = recorded now
CREATE OR REPLACE FUNCTION pgvigil.remote_mark(p_site text, p_collector text, p_key text, p_stream text, p_seq bigint,
  p_window_to timestamptz, p_kind text, p_reason text, p_digest text)
RETURNS boolean LANGUAGE sql AS $$
  WITH ins AS (
    INSERT INTO pgvigil.remote_marks (site, collector, instance_key, stream, seq, window_to, kind, reason, digest)
    VALUES (p_site, p_collector, p_key, p_stream, p_seq, p_window_to, p_kind, p_reason, coalesce(p_digest, ''))
    ON CONFLICT (site, collector, instance_key, stream, seq, kind, digest) WHERE kind <> 'audit gap' AND cleared_at IS NULL DO NOTHING
    RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM ins)
$$;

-- the three views the hub's pages read (contract 2; query_text is contract 3)
CREATE OR REPLACE VIEW pgvigil.remote_instance_state AS
SELECT i.instance_id, i.name, i.engine, i.owner AS site, coalesce(b.collector, n.collector) AS collector, i.as_of,
       extract(epoch FROM b.window_to - b.window_from)::int AS interval_secs, s.expected_every_secs, b.loaded_at,
       b.query_text
  FROM pgvigil.instances i
  LEFT JOIN LATERAL (SELECT x.collector, x.window_from, x.window_to, x.loaded_at, x.query_text FROM pgvigil.remote_bundles x
                      WHERE x.instance_id = i.instance_id AND x.state = 'loaded'
                      ORDER BY x.window_to DESC, x.bundle_id DESC LIMIT 1) b ON true
  -- the collector of an instance whose bundles are all still loading (its newest bundle of any state)
  LEFT JOIN LATERAL (SELECT x.collector FROM pgvigil.remote_bundles x WHERE x.instance_id = i.instance_id
                      ORDER BY x.bundle_id DESC LIMIT 1) n ON true
  LEFT JOIN pgvigil.remote_sites s ON s.name = i.owner
 WHERE i.owner IS NOT NULL;

-- remote_collector_state: each collector of an active site - configured (remote_sites: lists it) or seen (a bundle, a
-- heartbeat, a mark) - with its newest bundle's window end, the hub's newest load of it (newest_loaded_at: the silence
-- is judged on it, the hub's clock), its counts and its site's expected_every; configured false = no longer listed
CREATE OR REPLACE VIEW pgvigil.remote_collector_state AS
SELECT k.site, k.collector, c.pgvigil_version, c.host, c.heartbeat_at, c.instances, c.fail_streak,
       (SELECT max(b.window_to) FROM pgvigil.remote_bundles b WHERE b.site = k.site AND b.collector = k.collector AND b.state = 'loaded') AS newest_bundle_at,
       count(m.mark_id) FILTER (WHERE m.kind = 'gap')::int AS gaps,
       count(m.mark_id) FILTER (WHERE m.kind NOT IN ('gap', 'late', 'conflict', 'audit gap', 'retry'))::int AS set_aside,
       (SELECT x.kind || ': ' || x.reason FROM pgvigil.remote_marks x
         WHERE x.site = k.site AND x.collector = k.collector AND x.cleared_at IS NULL AND x.kind NOT IN ('gap', 'late', 'conflict', 'audit gap', 'retry')
         ORDER BY x.marked_at DESC, x.mark_id DESC LIMIT 1) AS newest_set_aside_reason,
       count(m.mark_id) FILTER (WHERE m.kind = 'late')::int AS late,
       count(m.mark_id) FILTER (WHERE m.kind = 'conflict')::int AS conflicts,
       s.expected_every_secs,
       (SELECT max(t.high_loaded_at) FROM pgvigil.remote_streams t WHERE t.site = k.site AND t.collector = k.collector) AS newest_loaded_at,
       (s.collectors IS NULL OR k.collector = ANY (s.collectors)) AS configured
  FROM (SELECT site, collector FROM pgvigil.remote_collectors
        UNION SELECT site, collector FROM pgvigil.remote_bundles
        UNION SELECT site, collector FROM pgvigil.remote_marks
        UNION SELECT name, unnest(collectors) FROM pgvigil.remote_sites) k
  LEFT JOIN pgvigil.remote_collectors c ON c.site = k.site AND c.collector = k.collector
  LEFT JOIN pgvigil.remote_marks m ON m.site = k.site AND m.collector = k.collector AND m.cleared_at IS NULL
  LEFT JOIN pgvigil.remote_sites s ON s.name = k.site
 WHERE s.active IS NOT FALSE
 GROUP BY k.site, k.collector, c.pgvigil_version, c.host, c.heartbeat_at, c.instances, c.fail_streak, s.expected_every_secs, s.collectors;

CREATE OR REPLACE VIEW pgvigil.remote_collection_interval AS
SELECT instance_id, collection, interval_secs FROM pgvigil.remote_intervals;

-- remote_silence_findings: a site, a configured collector of a site that still sends, and each of the site's instances,
-- whose newest LOAD by the hub (its clock, never the site's) is more than 2 x max(expected_every, the bundle interval)
-- ago (warning; 6 x critical) - a finding's columns, joined into pgvigil.findings by scripts/REMOTE-join-lines.sql line
-- 1. The site's arm is repository-wide (source 'pgvigil repository', as the collector's own instance-less findings),
-- so alert_findings sends it. A site that never sent is judged from its first sync; active sites only.
CREATE OR REPLACE VIEW pgvigil.remote_silence_findings AS
WITH site AS (
  SELECT s.name, s.collectors,
         greatest(s.expected_every_secs, coalesce((SELECT max(r.interval_secs) FROM pgvigil.remote_instance_state r WHERE r.site = s.name), 0)) AS every_secs,
         s.expected_every_secs,
         coalesce((SELECT max(t.high_loaded_at) FROM pgvigil.remote_streams t WHERE t.site = s.name), s.first_synced_at) AS newest,
         EXISTS (SELECT 1 FROM pgvigil.remote_streams t WHERE t.site = s.name) AS sent
    FROM pgvigil.remote_sites s
   WHERE s.active
), coll AS (
  SELECT st.name AS site, c AS collector, st.every_secs, st.expected_every_secs,
         (SELECT max(t.high_loaded_at) FROM pgvigil.remote_streams t WHERE t.site = st.name AND t.collector = c) AS newest
    FROM site st CROSS JOIN LATERAL unnest(st.collectors) AS c
   WHERE st.sent AND now() - st.newest <= make_interval(secs => 2 * st.every_secs)
), inst AS (
  SELECT i.instance_id, i.name, i.owner, s.every_secs, s.expected_every_secs,
         (SELECT max(t.high_loaded_at) FROM pgvigil.remote_streams t WHERE t.instance_id = i.instance_id) AS newest
    FROM pgvigil.instances i JOIN site s ON s.name = i.owner
   WHERE i.is_active
)
SELECT NULL::int AS instance_id,
       CASE WHEN now() - newest > make_interval(secs => 6 * every_secs) THEN 'critical' ELSE 'warning' END AS severity,
       'remote site quiet'::text AS setting, name AS value, true AS is_set,
       format('a bundle every %s s or sooner', expected_every_secs) AS suggested, 'all'::text AS platforms,
       format('site %s has gone quiet: last bundle %s', name, CASE WHEN sent THEN to_char(newest AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"') ELSE 'never' END) AS detail,
       'pgvigil repository'::text AS source, newest AS at
  FROM site
 WHERE now() - newest > make_interval(secs => 2 * every_secs)
UNION ALL
SELECT NULL::int,
       CASE WHEN now() - coalesce(newest, '-infinity') > make_interval(secs => 6 * every_secs) THEN 'critical' ELSE 'warning' END,
       'remote collector quiet', site || '/' || collector, true, format('a bundle every %s s or sooner', expected_every_secs), 'all',
       format('collector %s of site %s has gone quiet: last bundle %s', collector, site,
              coalesce(to_char(newest AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"'), 'never')),
       'pgvigil repository', coalesce(newest, now())
  FROM coll
 WHERE newest IS NULL OR now() - newest > make_interval(secs => 2 * every_secs)
UNION ALL
SELECT instance_id,
       CASE WHEN now() - newest > make_interval(secs => 6 * every_secs) THEN 'critical' ELSE 'warning' END,
       'remote instance quiet', name, true, format('a bundle every %s s or sooner', expected_every_secs), 'all',
       format('instance %s of site %s has gone quiet: last bundle %s', name, owner, to_char(newest AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI "UTC"')),
       'remote collector', newest
  FROM inst
 WHERE newest IS NOT NULL AND now() - newest > make_interval(secs => 2 * every_secs);

-- remote_purge: the ledgers past p_days - a loaded bundle (its batches with it), a cleared mark, a sighting; each
-- stream's high-water (its newest load too) and an open mark are kept (purge() calls it: scripts/REMOTE-join-lines.sql
-- line 3)
CREATE OR REPLACE FUNCTION pgvigil.remote_purge(p_days int DEFAULT 90)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  n bigint := 0;
  v bigint;
BEGIN
  DELETE FROM pgvigil.remote_bundles WHERE state = 'loaded' AND loaded_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v = ROW_COUNT; n := n + v;
  DELETE FROM pgvigil.remote_marks WHERE cleared_at IS NOT NULL AND cleared_at < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v = ROW_COUNT; n := n + v;
  DELETE FROM pgvigil.remote_sightings WHERE first_seen < now() - make_interval(days => p_days);
  GET DIAGNOSTICS v = ROW_COUNT; n := n + v;
  RETURN n;
END $$;

-- the reader (serve's pages) reads the views; nobody writes but ingest's door (apply_roles: join line 4)
DO $$
DECLARE t regclass;
BEGIN
  FOREACH t IN ARRAY ARRAY['pgvigil.remote_sites', 'pgvigil.remote_collectors', 'pgvigil.remote_bundles', 'pgvigil.remote_batches',
    'pgvigil.remote_streams', 'pgvigil.remote_sightings', 'pgvigil.remote_marks', 'pgvigil.remote_intervals', 'pgvigil.remote_instance_state',
    'pgvigil.remote_collector_state', 'pgvigil.remote_collection_interval', 'pgvigil.remote_silence_findings']::regclass[]
  LOOP
    EXECUTE format('REVOKE ALL ON %s FROM PUBLIC, pgvigil_collector, pgvigil_auth, pgvigil_ingest', t);
    EXECUTE format('GRANT SELECT ON %s TO pgvigil_reader', t);
  END LOOP;
END $$;
REVOKE ALL ON FUNCTION pgvigil.remote_site_sync(text, text[], int, int, text[]), pgvigil.remote_sites_retire(text[]),
  pgvigil.remote_ensure_instance(text, text, text, text, text, int, boolean, text[]), pgvigil.remote_seen(text, text, text, text),
  pgvigil.remote_newest(text, text, text, text), pgvigil.remote_recorded(text, text, text, text, bigint), pgvigil.remote_retries(text, text, text),
  pgvigil.remote_retry(text, text, text, bigint),
  pgvigil.remote_bundle_begin(text, text, text, text, bigint, timestamptz, timestamptz, text, int, text),
  pgvigil.remote_batch(bigint, text, int, int, timestamptz, jsonb, boolean),
  pgvigil.remote_bundle_done(bigint, jsonb, jsonb, text, jsonb, jsonb, text),
  pgvigil.remote_mark(text, text, text, text, bigint, timestamptz, text, text, text), pgvigil.remote_purge(int)
  FROM PUBLIC;
