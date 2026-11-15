-- 0254 B24h: reachability and the query round trip (dbachecks Instance#3, Instance#18, Server#4, Server#5). Above 0190:
-- this file creates B24h's own objects only and adds collector_load's three round-trip columns; every arm of a joined
-- view or function (pgvigil.findings, alert_due, collector_shared_cause, purge(), import_pg_threshold, the parents'
-- words) is in scripts/b24h-join-lines.sql for the next join.

-- the query round trip (heartbeat.go loadAgg rt*): one 'SELECT 1' timed per instance and minute by the minute's first
-- collection, on its own connection - the network and the server's answer; its count, sum and longest (ms)
ALTER TABLE pgvigil.collector_load
  ADD COLUMN IF NOT EXISTS rt_count int NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS rt_ms_sum bigint NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS rt_ms_max int NOT NULL DEFAULT 0;

-- collector_probe: one address's probe in a round (probe.go): the host it was reached by, the method ('tcp': the TCP
-- handshake to the address the instance's last connection used; 'icmp' from B24h-2), sent, answered (NULL: not probed
-- in its round - the round's deadline - never 'not answered'), the answered time summed and the longest (ms)
CREATE TABLE IF NOT EXISTS pgvigil.collector_probe (
  minute        timestamptz NOT NULL,
  collector_id  text NOT NULL,
  host          text NOT NULL,
  address       text NOT NULL,
  method        text NOT NULL CHECK (method IN ('icmp', 'tcp')),
  sent          int NOT NULL,
  answered      int,
  ms_sum        bigint NOT NULL DEFAULT 0,
  ms_max        int NOT NULL DEFAULT 0,
  scheduled     boolean NOT NULL DEFAULT false,   -- a round of probe_every_minute (the review of B24h-1 part b #7)
  PRIMARY KEY (minute, collector_id, address)
);
-- a store that ran this file before the column (the lab's): added
ALTER TABLE pgvigil.collector_probe ADD COLUMN IF NOT EXISTS scheduled boolean NOT NULL DEFAULT false;

-- collector_probe_host: per collector and address, when it was first probed and last answered (the fold's #5: the
-- 'never answered' and 'stopped answering' words read this, never 8 days of probe rows)
CREATE TABLE IF NOT EXISTS pgvigil.collector_probe_host (
  collector_id  text NOT NULL,
  host          text NOT NULL,
  address       text NOT NULL,
  first_probed  timestamptz NOT NULL,
  last_answered timestamptz,
  last_method   text NOT NULL,
  PRIMARY KEY (collector_id, address)
);

-- import_collector_probe: the beat's B24h parts (heartbeat.go beat(): called after import_collector_beat with the same
-- body) - the load rows' round-trip figures added to the minute's collector_load rows import_collector_beat just wrote
-- (sums added, the larger max kept), the probe rows, and each address's first probe and last answer
CREATE OR REPLACE FUNCTION pgvigil.import_collector_probe(p_collector text, p_minute timestamptz, p_beat jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  UPDATE pgvigil.collector_load l
     SET rt_count = l.rt_count + x.rt_count, rt_ms_sum = l.rt_ms_sum + x.rt_ms_sum, rt_ms_max = greatest(l.rt_ms_max, x.rt_ms_max)
    FROM (SELECT i.instance_id, coalesce(r.rt_count, 0) AS rt_count, coalesce(r.rt_ms_sum, 0) AS rt_ms_sum, coalesce(r.rt_ms_max, 0) AS rt_ms_max
            FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'load') = 'array' THEN p_beat->'load' ELSE '[]'::jsonb END))
                 AS r(instance text, rt_count int, rt_ms_sum bigint, rt_ms_max int)
            JOIN pgvigil.instances i ON i.name = r.instance
           WHERE coalesce(r.rt_count, 0) > 0) x
   WHERE l.minute = p_minute AND l.collector_id = p_collector AND l.instance_id = x.instance_id;
  INSERT INTO pgvigil.collector_probe AS p (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max, scheduled)
  SELECT date_trunc('minute', coalesce(r.at, p_minute)), p_collector, coalesce(r.host, ''), r.address, r.method, coalesce(r.sent, 0), r.answered,
         coalesce(r.ms_sum, 0), coalesce(r.ms_max, 0), coalesce(r.scheduled, false)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'probes') = 'array' THEN p_beat->'probes' ELSE '[]'::jsonb END))
         AS r(host text, address text, method text, at timestamptz, sent int, answered int, ms_sum bigint, ms_max int, scheduled boolean)
   WHERE r.address IS NOT NULL AND r.method IN ('icmp', 'tcp')
  ON CONFLICT (minute, collector_id, address) DO UPDATE
     SET sent = p.sent + EXCLUDED.sent, answered = CASE WHEN EXCLUDED.answered IS NULL THEN p.answered ELSE coalesce(p.answered, 0) + EXCLUDED.answered END,
         ms_sum = p.ms_sum + EXCLUDED.ms_sum, ms_max = greatest(p.ms_max, EXCLUDED.ms_max), method = EXCLUDED.method, host = EXCLUDED.host,
         scheduled = p.scheduled OR EXCLUDED.scheduled;
  INSERT INTO pgvigil.collector_probe_host AS h (collector_id, host, address, first_probed, last_answered, last_method)
  SELECT p_collector, coalesce(max(r.host), ''), r.address, min(coalesce(r.at, p_minute)),
         max(coalesce(r.at, p_minute)) FILTER (WHERE r.answered > 0), max(r.method)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'probes') = 'array' THEN p_beat->'probes' ELSE '[]'::jsonb END))
         AS r(host text, address text, method text, at timestamptz, answered int)
   WHERE r.address IS NOT NULL AND r.method IN ('icmp', 'tcp') AND r.answered IS NOT NULL
   GROUP BY r.address
  ON CONFLICT (collector_id, address) DO UPDATE
     SET first_probed = least(h.first_probed, EXCLUDED.first_probed),
         last_answered = greatest(h.last_answered, EXCLUDED.last_answered),
         host = EXCLUDED.host, last_method = EXCLUDED.last_method;
  -- an opened connection is a TCP answer (the review of B24h-1 part a #1, the lead's 12:4x (a)): the host's last answer is
  -- the newest open, probed or not ('never answered' never stands for a server a connection reached); first_probed is
  -- then the first time the address was seen
  INSERT INTO pgvigil.collector_probe_host AS h (collector_id, host, address, first_probed, last_answered, last_method)
  SELECT p_collector, coalesce(max(o.host), ''), o.address, min(coalesce(o.at, p_minute)), max(coalesce(o.at, p_minute)), 'tcp'
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'opened') = 'array' THEN p_beat->'opened' ELSE '[]'::jsonb END))
         AS o(host text, address text, at timestamptz)
   WHERE o.address IS NOT NULL
   GROUP BY o.address
  ON CONFLICT (collector_id, address) DO UPDATE
     SET first_probed = least(h.first_probed, EXCLUDED.first_probed),
         last_answered = greatest(h.last_answered, EXCLUDED.last_answered), host = EXCLUDED.host;
  -- the probe rows are kept 8 days, trimmed here (the review of B24h-1 part b #9: until the join's purge() line, a
  -- store under probe_every_minute grew without end); the key's leading minute serves the delete
  DELETE FROM pgvigil.collector_probe WHERE minute < now() - interval '8 days';
END
$$;

-- ===== the findings (B24h-1c part 2; the fold's #2, #3, #6a, #13, B24h-b, B24h-c) =====
-- the threshold keys: warning only at dbachecks' values (Instance#18 40 ms, Server#5 10 ms), each settable empty (off)
-- like connect_time; in seconds, the keys' unit check holding no milliseconds
INSERT INTO pgvigil.pg_threshold_keys (key, label, unit, direction, warn_default, crit_default, levels, max_value) VALUES
  ('round_trip_time', 'Query round trip: an instance''s average ''SELECT 1'' (the network and the server''s response) over its last 5 measured minutes', 'seconds', 'over', 0.040, NULL, '{root,tag,instance}', 60),
  ('ping_time', 'Ping: the average answer of an instance''s host over its last 5 probed minutes (probe_every_minute)', 'seconds', 'over', 0.010, NULL, '{root,tag,instance}', 60)
ON CONFLICT (key) DO UPDATE SET label = EXCLUDED.label, unit = EXCLUDED.unit, direction = EXCLUDED.direction,
  warn_default = EXCLUDED.warn_default, crit_default = EXCLUDED.crit_default, levels = EXCLUDED.levels, max_value = EXCLUDED.max_value;

-- collector_target_host: the first host of a dial target ('postgres:db1:5432,db2:5433' -> 'db1'; '[2001:db8::1]:5432'
-- -> '2001:db8::1') - the name probe.go files an instance's probe under (heartbeat.go targetHost)
-- (a SQL Server named instance's host is its box: 'mssql:sql01\a:0' -> 'sql01', the review of B24h-1 part b #6; a bare
-- IPv6 literal loses its ':port' as heartbeat.go targetHost cuts it, part a #4)
CREATE OR REPLACE FUNCTION pgvigil.collector_target_host(p_target text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
  SELECT split_part(CASE WHEN f LIKE '[%' THEN substring(f FROM 2 FOR strpos(f, ']') - 2) ELSE regexp_replace(f, ':[0-9]+$', '') END, E'\\', 1)
    FROM (SELECT split_part(substring(p_target FROM strpos(p_target, ':') + 1), ',', 1) AS f) x
$$;

-- collector_instance_hosts: per collector host and instance, the host its probe is filed under (its newest target)
CREATE OR REPLACE VIEW pgvigil.collector_instance_hosts AS
SELECT DISTINCT ON (h.host, l.instance_id) h.host AS collector_host, l.instance_id, pgvigil.collector_target_host(l.target) AS host
  FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
 WHERE l.minute > now() - interval '20 minutes' AND l.target IS NOT NULL AND h.retired_at IS NULL
 ORDER BY h.host, l.instance_id, l.minute DESC;

-- collector_round_trips: per collector host and instance, the round trips of its last 5 measured minutes of the 20 -
-- JUDGED with 3 or more and the newest within 8 minutes; its average and longest in seconds, its own warning, slow over it
CREATE OR REPLACE VIEW pgvigil.collector_round_trips AS
WITH m AS (
  SELECT h.host, l.instance_id, l.minute, sum(l.rt_count) AS n, sum(l.rt_ms_sum) AS ms, max(l.rt_ms_max) AS mx
    FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE l.minute > now() - interval '20 minutes' AND l.rt_count > 0 AND h.retired_at IS NULL
   GROUP BY h.host, l.instance_id, l.minute
), w AS (
  SELECT host, instance_id, sum(n) AS n, sum(ms) AS ms, max(mx) AS mx, max(minute) AS newest
    FROM (SELECT m.*, row_number() OVER (PARTITION BY m.host, m.instance_id ORDER BY m.minute DESC) AS k FROM m) r
   WHERE k <= 5 GROUP BY host, instance_id
)
SELECT w.host AS collector_host, w.instance_id, i.name, w.n, round(w.ms::numeric / w.n / 1000, 3) AS avg_s, round(w.mx::numeric / 1000, 3) AS max_s,
       th.warn, coalesce(w.ms::numeric / w.n / 1000 > th.warn, false) AS slow
  FROM w JOIN pgvigil.instances i ON i.instance_id = w.instance_id AND i.is_active
  CROSS JOIN LATERAL pgvigil.pg_threshold(w.instance_id, 'round_trip_time') th
 WHERE w.n >= 3 AND w.newest >= now() - interval '8 minutes';

-- collector_pings: per collector host and probed address, its probed minutes of the last 5 of the 20 (answered or not;
-- 'not probed' rows left out): rounds, answered, the answered average and longest in seconds; silent3 = none answered in
-- each of its 3 newest probed minutes, the oldest of them within 6 minutes (only probe_every_minute probes that often)
CREATE OR REPLACE VIEW pgvigil.collector_pings AS
WITH p AS (
  SELECT h.host AS collector_host, p.host, p.address, p.method, p.minute, p.sent, p.answered, p.ms_sum, p.ms_max,
         row_number() OVER (PARTITION BY h.host, p.address ORDER BY p.minute DESC) AS k
    FROM pgvigil.collector_probe p JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE p.minute > now() - interval '20 minutes' AND p.answered IS NOT NULL AND h.retired_at IS NULL
)
SELECT collector_host, host, address, max(method) AS method, count(*) AS rounds, sum(answered) AS answered,
       round(sum(ms_sum)::numeric / nullif(sum(answered), 0) / 1000, 3) AS avg_s, round(max(ms_max)::numeric / 1000, 3) AS max_s,
       count(*) FILTER (WHERE k <= 3) = 3 AND coalesce(bool_and(answered = 0) FILTER (WHERE k <= 3), false)
         AND coalesce(min(minute) FILTER (WHERE k <= 3) >= now() - interval '6 minutes', false) AS silent3
  FROM p WHERE k <= 5 GROUP BY collector_host, host, address;

-- collector_probe_judged: each instance judged by its own thresholds - its round trip, and its host's ping (3 or more
-- answered probes of 5); 'not answering' = its host silent3 AND that address answered once (collector_probe_host): a
-- host that never answered (ICMP blocked: a cloud endpoint) or that stopped answering while connections open is words
-- on the page only, never a finding (B24h-b, the fold's #6a)
CREATE OR REPLACE VIEW pgvigil.collector_probe_judged AS
SELECT ih.collector_host, ih.instance_id, i.name, ih.host,
       rt.avg_s AS rt_avg_s, rt.max_s AS rt_max_s, rt.warn AS rt_warn, coalesce(rt.slow, false) AS rt_slow,
       pg.method, pg.avg_s AS ping_avg_s, pg.max_s AS ping_max_s, th.warn AS ping_warn,
       coalesce(pg.answered >= 3 AND pg.avg_s > th.warn, false) AS ping_slow,
       coalesce(pg.silent3, false) AND EXISTS (SELECT 1 FROM pgvigil.collector_probe_host ph JOIN pgvigil.collector_heartbeat h USING (collector_id)
                                                WHERE h.host = ih.collector_host AND ph.address = pg.address AND ph.last_answered IS NOT NULL) AS not_answering
  FROM pgvigil.collector_instance_hosts ih
  JOIN pgvigil.instances i ON i.instance_id = ih.instance_id AND i.is_active
  LEFT JOIN pgvigil.collector_round_trips rt ON rt.collector_host = ih.collector_host AND rt.instance_id = ih.instance_id
  -- a host reached at more than one address: the address with the most answers (then by name) speaks for it
  LEFT JOIN LATERAL (SELECT * FROM pgvigil.collector_pings x WHERE x.collector_host = ih.collector_host AND x.host = ih.host
                      ORDER BY x.answered DESC, x.address LIMIT 1) pg ON true
  CROSS JOIN LATERAL pgvigil.pg_threshold(ih.instance_id, 'ping_time') th
 WHERE rt.instance_id IS NOT NULL OR EXISTS (SELECT 1 FROM pgvigil.collector_pings x WHERE x.collector_host = ih.collector_host AND x.host = ih.host);

-- collector_probe_fold: B24h's own fold over its two measures (the fold's #3, SLOW-CONNECT's form): per collector host,
-- its probed hosts judged and those slow (an instance on it slow by its round trip or its host's ping); it FORMS at 3
-- or more slow hosts and more than half; an open alert STAYS while 3 or more and more than a quarter are slow; warning
CREATE OR REPLACE VIEW pgvigil.collector_probe_fold AS
WITH hs AS (
  SELECT collector_host, host, bool_or(rt_slow OR ping_slow) AS slow FROM pgvigil.collector_probe_judged GROUP BY collector_host, host
), c AS (
  SELECT collector_host, count(*) AS hosts, count(*) FILTER (WHERE slow) AS slow_hosts FROM hs GROUP BY collector_host
)
SELECT c.collector_host, c.hosts, c.slow_hosts
  FROM c
 WHERE c.slow_hosts >= 3
   AND (c.slow_hosts * 2 > c.hosts
        OR (c.slow_hosts * 4 > c.hosts
            AND EXISTS (SELECT 1 FROM pgvigil.alert_state s JOIN pgvigil.alert_channels ch ON ch.name = s.channel AND ch.is_configured
                         WHERE s.cleared_at IS NULL AND s.missing_since IS NULL AND s.source = 'pgvigil repository'
                           AND s.setting = 'network slow from this collector' AND s.value = c.collector_host)));

-- collector_probe_held: the probe findings alert_due holds (its term is WIRING: scripts/b24h-join-lines.sql) - every
-- instance's probe finding under a standing collector fold; an instance's own ping rows under its host's row (one alert
-- a host, the fold's #2); collector_probe_held_hosts: a host's rows under a standing collector fold
CREATE OR REPLACE VIEW pgvigil.collector_probe_held AS
SELECT j.instance_id, s.setting
  FROM pgvigil.collector_probe_judged j
  CROSS JOIN (VALUES ('query round trip slow'), ('ping slow'), ('host not answering ping')) s(setting)
 WHERE EXISTS (SELECT 1 FROM pgvigil.collector_probe_fold f WHERE f.collector_host = j.collector_host)
    OR (s.setting = 'ping slow' AND j.ping_slow) OR (s.setting = 'host not answering ping' AND j.not_answering);
CREATE OR REPLACE VIEW pgvigil.collector_probe_held_hosts AS
SELECT DISTINCT j.host FROM pgvigil.collector_probe_judged j JOIN pgvigil.collector_probe_fold f ON f.collector_host = j.collector_host;

-- collector_probe_findings: the findings shape (pgvigil.findings' arms; the arm is WIRING): an instance's round trip;
-- its host's ping and silence on the instance (held) and once for the host (source 'pgvigil repository', the host as
-- its value: one alert a host, naming the instances over their own thresholds); the collector fold
CREATE OR REPLACE VIEW pgvigil.collector_probe_findings AS
SELECT j.instance_id, 'warning'::text AS severity, 'query round trip slow'::text AS setting, j.name AS value, true AS is_set,
       'a query round trip under ' || j.rt_warn || ' s'::text AS suggested, 'all'::text AS platforms,
       'query round trip (network and the server''s response) ' || j.rt_avg_s || ' s on average, ' || j.rt_max_s
         || ' s at most over its last 5 measured minutes, from ' || j.collector_host || '; warning over ' || j.rt_warn || ' s' AS detail,
       'pgvigil collector'::text AS source, now() AS at
  FROM pgvigil.collector_probe_judged j WHERE j.rt_slow
UNION ALL
SELECT j.instance_id, 'warning', 'ping slow', j.host, true, 'its host answering under ' || j.ping_warn || ' s', 'all',
       'its host ' || j.host || ' answers in ' || j.ping_avg_s || ' s on average (' || j.method || '), ' || j.ping_max_s
         || ' s at most, from ' || j.collector_host || '; warning over ' || j.ping_warn || ' s', 'pgvigil collector', now()
  FROM pgvigil.collector_probe_judged j WHERE j.ping_slow
UNION ALL
SELECT NULL::int, 'warning', 'ping slow', h.host, true, 'the host answering under each instance''s threshold', 'all',
       'host ' || h.host || ' answers in ' || h.avg_s || ' s on average, from ' || h.collector_host || '; over the threshold of: ' || h.who,
       'pgvigil repository', now()
  FROM (SELECT collector_host, host, max(ping_avg_s) AS avg_s, string_agg(name || ' (' || ping_warn || ' s)', ', ' ORDER BY name) AS who
          FROM pgvigil.collector_probe_judged WHERE ping_slow GROUP BY collector_host, host) h
UNION ALL
SELECT j.instance_id, 'warning', 'host not answering ping', j.host, true, 'its host answering ping', 'all',
       'its host ' || j.host || ' answered none of the probes of its last 3 probed minutes from ' || j.collector_host
         || ' (it answered before)', 'pgvigil collector', now()
  FROM pgvigil.collector_probe_judged j WHERE j.not_answering
UNION ALL
SELECT NULL::int, 'warning', 'host not answering ping', h.host, true, 'the host answering ping', 'all',
       'host ' || h.host || ' answered none of the probes of its last 3 probed minutes from ' || h.collector_host || ' (it answered before); its instances: ' || h.who,
       'pgvigil repository', now()
  FROM (SELECT collector_host, host, string_agg(name, ', ' ORDER BY name) AS who
          FROM pgvigil.collector_probe_judged WHERE not_answering GROUP BY collector_host, host) h
UNION ALL
SELECT NULL::int, 'warning', 'network slow from this collector', f.collector_host, true, 'fewer than a quarter of its hosts slow', 'all',
       f.slow_hosts || ' of the ' || f.hosts || ' hosts this collector reads are slow (query round trip or ping): its own network or '
         || 'host is the likelier cause; their instances'' probe findings are held under this one', 'pgvigil repository', now()
  FROM pgvigil.collector_probe_fold f;
