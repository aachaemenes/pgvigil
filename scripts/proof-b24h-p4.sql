-- In git since the B24h-1 fold (the review of 60991f0e part b #14): run on a migrated scratch repository with
--   psql "<dsn>" -XAtq -f scripts/proof-b24h-p4.sql
-- and graded by its 'Expected' lines. Its thresholds are written into pg_thresholds directly: import_pg_threshold takes
-- B24h's keys in seconds to three places only with the join's line 8 (scripts/b24h-join-lines.sql); after the join they go through it.
-- B24h-1 rows P4a / P4b / P4c on a migrated scratch repository (each case one transaction rolled back; now() holds).
-- They read B24h's own views (0254): the findings arm and alert_due's hold term are join lines
-- (scripts/b24h-join-lines.sql), so 'held' here is pgvigil.collector_probe_held / _held_hosts, not a send.
-- RED on 539172c9 (B24h's base, no 0254): every row 'n/a (<error>)'.
\set ON_ERROR_STOP 1
\pset footer off
SET jit = off;
INSERT INTO pgvigil.instances (name, platform) SELECT 'q' || g, 'self-managed' FROM generate_series(1, 6) g ON CONFLICT DO NOTHING;
CREATE OR REPLACE FUNCTION pg_temp.try(p_sql text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE v text; BEGIN EXECUTE p_sql INTO v; RETURN coalesce(v, '-');
EXCEPTION WHEN undefined_table OR undefined_function OR undefined_column OR foreign_key_violation THEN RETURN 'n/a (' || SQLERRM || ')'; END $$;
-- hb: a live run of collector p_coll on host p_host
CREATE OR REPLACE FUNCTION pg_temp.hb(p_coll text, p_host text) RETURNS void LANGUAGE sql AS $$
  INSERT INTO pgvigil.collector_heartbeat (collector_id, host, os, runs_as, version, pid, started_at, beat_at)
  VALUES (p_coll, p_host, 'linux', 'console', 'x', 1, now() - interval '1 hour', now());
$$;
-- ld: q<n>'s load rows for the p_mins written minutes before now's (its dial target p_target), each with p_rt round
-- trips of p_rt_ms ms (0: none) - the rt columns are 0254's ('n/a' before it)
CREATE OR REPLACE FUNCTION pg_temp.ld(p_coll text, p_inst text, p_target text, p_mins int, p_rt int DEFAULT 0, p_rt_ms int DEFAULT 0) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.collector_load (minute, instance_id, collector_id, attempts, opened, runs, failures, auth_failures, target)
  SELECT date_trunc('minute', now()) - make_interval(mins => k), i.instance_id, p_coll, 1, 1, 1, 0, 0, p_target
    FROM pgvigil.instances i CROSS JOIN generate_series(1, p_mins) k WHERE i.name = p_inst;
  IF p_rt > 0 THEN
    EXECUTE format('UPDATE pgvigil.collector_load SET rt_count = %s, rt_ms_sum = %s, rt_ms_max = %s
                     WHERE collector_id = %L AND instance_id = (SELECT instance_id FROM pgvigil.instances WHERE name = %L)',
                   p_rt, p_rt * p_rt_ms, p_rt_ms, p_coll, p_inst);
  END IF;
  RETURN 'ok';
EXCEPTION WHEN undefined_column THEN RETURN 'n/a (' || SQLERRM || ')';
END $$;
-- pr: p_mins probed minutes of host p_host at p_addr by p_coll, each one probe answered in p_ms ms; the address answered
CREATE OR REPLACE FUNCTION pg_temp.pr(p_coll text, p_host text, p_addr text, p_mins int, p_ms int) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format($q$INSERT INTO pgvigil.collector_probe (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max, scheduled)
                    SELECT date_trunc('minute', now()) - make_interval(mins => k), %L, %L, %L, 'tcp', 1, 1, %s, %s, true FROM generate_series(1, %s) k$q$,   -- per-minute rounds (probe_every_minute: the B24h-1 fold's #b7)
                 p_coll, p_host, p_addr, p_ms, p_ms, p_mins);
  EXECUTE format($q$INSERT INTO pgvigil.collector_probe_host (collector_id, host, address, first_probed, last_answered, last_method)
                    VALUES (%L, %L, %L, now() - interval '30 minutes', now() - interval '1 minute', 'tcp')$q$, p_coll, p_host, p_addr);
  RETURN 'ok';
EXCEPTION WHEN undefined_table THEN RETURN 'n/a (' || SQLERRM || ')';
END $$;
-- th: q<n>'s own warning for p_key (seconds), at the instance level
CREATE OR REPLACE FUNCTION pg_temp.th(p_inst text, p_key text, p_warn numeric) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO pgvigil.pg_thresholds (key, level, instance_id, warn, created_by, created_at)
  SELECT p_key, 'instance', instance_id, p_warn, 'proof', now() FROM pgvigil.instances WHERE name = p_inst;
  RETURN 'ok';
EXCEPTION WHEN foreign_key_violation THEN RETURN 'n/a (' || SQLERRM || ')';
END $$;
-- fx: the probe findings as '<instance or -> <setting> <value>[ <who, for a host row>]'
CREATE OR REPLACE FUNCTION pg_temp.fx() RETURNS text LANGUAGE sql AS $$
  SELECT pg_temp.try($q$SELECT coalesce(string_agg(x, '; ' ORDER BY x), '-') FROM (
    SELECT coalesce(i.name, '-') || ' ' || f.setting || ' ' || f.value
           || CASE WHEN f.instance_id IS NULL AND f.setting = 'ping slow' THEN ' [' || substring(f.detail FROM 'threshold of: (.*)$') || ']' ELSE '' END AS x
      FROM pgvigil.collector_probe_findings f LEFT JOIN pgvigil.instances i USING (instance_id)) s$q$);
$$;
-- P4a (the fold's #2: the carrier) two instances on host dbh1 (one address) with their own ping warnings 0.005 s and
-- 0.050 s, a 20 ms answer in 5 probed minutes: ONE host row naming q1 alone, q1's own row (held under the host's), q2
-- not over its own. Expected 'P4a - ping slow dbh1 [q1 (0.005 s)]; q1 ping slow dbh1 | held q1 ping slow'
BEGIN; SELECT pg_temp.hb('pc1', 'ch1');
SELECT pg_temp.ld('pc1', 'q1', 'postgres:dbh1:5432', 5), pg_temp.ld('pc1', 'q2', 'postgres:dbh1:5432', 5);
SELECT pg_temp.pr('pc1', 'dbh1', '10.0.0.5', 5, 20), pg_temp.th('q1', 'ping_time', 0.005), pg_temp.th('q2', 'ping_time', 0.050);
SELECT 'P4a ' || pg_temp.fx() || ' | held ' || pg_temp.try($q$SELECT coalesce(string_agg(i.name || ' ' || h.setting, ', ' ORDER BY i.name, h.setting), '-')
                                                             FROM pgvigil.collector_probe_held h JOIN pgvigil.instances i USING (instance_id)$q$); ROLLBACK;
-- P4b (the fold's #3: B24h's own fold) five hosts dbh1-dbh5 read by ch1, one instance each, every one answering in 20 ms
-- (over the default 0.010 s): the collector fold 5 of 5 - its five host rows and five instances held. Expected
-- 'P4b fold ch1 5/5 | held hosts 5 | held instances 5'
BEGIN; SELECT pg_temp.hb('pc1', 'ch1');
SELECT pg_temp.ld('pc1', 'q' || g, 'postgres:dbh' || g || ':5432', 5), pg_temp.pr('pc1', 'dbh' || g, '10.0.0.' || g, 5, 20) FROM generate_series(1, 5) g;
SELECT 'P4b fold ' || pg_temp.try($q$SELECT coalesce(string_agg(collector_host || ' ' || slow_hosts || '/' || hosts, '; '), '-') FROM pgvigil.collector_probe_fold$q$)
       || ' | held hosts ' || pg_temp.try($q$SELECT count(*)::text FROM pgvigil.collector_probe_held_hosts$q$)
       || ' | held instances ' || pg_temp.try($q$SELECT count(DISTINCT instance_id)::text FROM pgvigil.collector_probe_held$q$); ROLLBACK;
-- P4b2 two of the five slow (20 ms), three at 2 ms: no fold, two host rows. Expected 'P4b2 fold - | host rows dbh1, dbh2'
BEGIN; SELECT pg_temp.hb('pc1', 'ch1');
SELECT pg_temp.ld('pc1', 'q' || g, 'postgres:dbh' || g || ':5432', 5), pg_temp.pr('pc1', 'dbh' || g, '10.0.0.' || g, 5, CASE WHEN g <= 2 THEN 20 ELSE 2 END) FROM generate_series(1, 5) g;
SELECT 'P4b2 fold ' || pg_temp.try($q$SELECT coalesce(string_agg(collector_host, '; '), '-') FROM pgvigil.collector_probe_fold$q$)
       || ' | host rows ' || pg_temp.try($q$SELECT coalesce(string_agg(value, ', ' ORDER BY value), '-') FROM pgvigil.collector_probe_findings WHERE instance_id IS NULL AND setting = 'ping slow'$q$); ROLLBACK;
-- P4c the round trip's tier (warning over 0.040 s by default; judged with 3 or more measures, the newest within 8
-- minutes): q1 60 ms in 5 minutes = slow; q2 60 ms in 2 minutes = not judged; q3 30 ms in 5 = not over. Expected
-- 'P4c q1 query round trip slow q1'
BEGIN; SELECT pg_temp.hb('pc1', 'ch1');
SELECT pg_temp.ld('pc1', 'q1', 'postgres:dbh1:5432', 5, 1, 60), pg_temp.ld('pc1', 'q2', 'postgres:dbh2:5432', 2, 1, 60), pg_temp.ld('pc1', 'q3', 'postgres:dbh3:5432', 5, 1, 30);
SELECT 'P4c ' || pg_temp.fx(); ROLLBACK;
