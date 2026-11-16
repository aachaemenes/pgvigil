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
-- no upgrade path from the pre-fold 0254 (the review of the fold #10): migrate skips a file schema_version holds, and no
-- release carried the earlier form - a store that applied it (a lab's own) is built again, never patched

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
     -- a probe already past 8 days (a collector clock that far behind) is not kept: it would sit below the trim's mark,
     -- where no trim reaches (the old whole-key trim removed it in the same beat)
     AND date_trunc('minute', coalesce(r.at, p_minute)) >= now() - interval '8 days'
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
  -- store under probe_every_minute grew without end) by the table's mark (0121's collector_trim: 10 minutes at most a
  -- beat from the mark; TRIMMARK, the lead's 11-15 17:4x (a)). A store whose 0121 was applied before the mark existed
  -- (first migrated by an untagged build: migrate skips the edited 0121, and such a store is made fresh - the lead's
  -- B6F4 #1 rule) has no collector_trim: the old whole-key trim, so the import never fails there on a missing function
  -- (the review of TRIMMARK #2: heartbeat.go reads that 42883 as 'no 0254' and stops sending the probes)
  IF to_regprocedure('pgvigil.collector_trim(text)') IS NOT NULL THEN
    PERFORM pgvigil.collector_trim('collector_probe');
  ELSE
    DELETE FROM pgvigil.collector_probe WHERE minute < now() - interval '8 days';
  END IF;
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

-- collector_instance_hosts: per collector host and instance, the host its probe is filed under (its newest target; the
-- host cut from the picked row alone, not from each of the 20 minutes' rows: BJb2's plan)
CREATE OR REPLACE VIEW pgvigil.collector_instance_hosts AS
SELECT x.collector_host, x.instance_id, pgvigil.collector_target_host(x.target) AS host
  FROM (SELECT DISTINCT ON (h.host, l.instance_id) h.host AS collector_host, l.instance_id, l.target
          FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
         WHERE l.minute > now() - interval '20 minutes' AND l.target IS NOT NULL AND h.retired_at IS NULL
         ORDER BY h.host, l.instance_id, l.minute DESC) x;

-- collector_probe_thresholds: B24h's two keys in force for EVERY active instance at once - pg_threshold's own rule (0103:
-- the instance's level, then a tag of its (the first by name), then the root, then the key's default; the row of the
-- best level wins, so an empty level is off, never the next one's value: keep in step with pg_threshold), as one
-- set-based read (the B24h-1 review part b #4, vis-b24hbj2g: pg_threshold called twice per instance, each reading the
-- merged tags, cost the judged view about half a second at 2,124 instances)
CREATE OR REPLACE VIEW pgvigil.collector_probe_thresholds AS
WITH i AS MATERIALIZED (
  SELECT i.instance_id, coalesce(m.tags, '{}'::text[]) AS tags
    FROM pgvigil.instances i LEFT JOIN pgvigil.instance_tags_merged m USING (instance_id) WHERE i.is_active
), cand AS (
  SELECT i.instance_id, t.key, t.warn, CASE t.level WHEN 'instance' THEN 2 WHEN 'tag' THEN 3 ELSE 4 END AS rank, t.tag
    FROM pgvigil.pg_thresholds t
    JOIN i ON t.level = 'root' OR (t.level = 'instance' AND t.instance_id = i.instance_id) OR (t.level = 'tag' AND t.tag = ANY (i.tags))
   WHERE t.ended_at IS NULL AND t.key IN ('round_trip_time', 'ping_time')
  UNION ALL
  SELECT i.instance_id, k.key, k.warn_default, 9, NULL FROM i CROSS JOIN pgvigil.pg_threshold_keys k WHERE k.key IN ('round_trip_time', 'ping_time')
)
SELECT DISTINCT ON (instance_id, key) instance_id, key, warn FROM cand ORDER BY instance_id, key, rank, tag NULLS LAST;

-- collector_round_trips: per collector host and instance, the round trips of its last 5 measured minutes of the 20 -
-- JUDGED with 3 or more and the newest within 8 minutes; its average and longest in seconds, its own warning, slow over it
CREATE OR REPLACE VIEW pgvigil.collector_round_trips AS
WITH m AS (
  SELECT h.host, l.instance_id, l.minute, sum(l.rt_count) AS n, sum(l.rt_ms_sum) AS ms, max(l.rt_ms_max) AS mx
    FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE l.minute > now() - interval '20 minutes' AND l.rt_count > 0 AND h.retired_at IS NULL
   GROUP BY h.host, l.instance_id, l.minute
), w AS (
  -- the last 5 measured minutes, and the 5 before the newest (the window a measured minute ago: 'crossed' below)
  SELECT host, instance_id, sum(n) FILTER (WHERE k <= 5) AS n, sum(ms) FILTER (WHERE k <= 5) AS ms, max(mx) FILTER (WHERE k <= 5) AS mx,
         max(minute) AS newest, sum(n) FILTER (WHERE k BETWEEN 2 AND 6) AS n_prev, sum(ms) FILTER (WHERE k BETWEEN 2 AND 6) AS ms_prev
    FROM (SELECT m.*, row_number() OVER (PARTITION BY m.host, m.instance_id ORDER BY m.minute DESC) AS k FROM m) r
   WHERE k <= 6 GROUP BY host, instance_id
)
SELECT w.host AS collector_host, w.instance_id, i.name, w.n, round(w.ms::numeric / w.n / 1000, 3) AS avg_s, round(w.mx::numeric / 1000, 3) AS max_s,
       th.warn, coalesce(w.ms::numeric / w.n / 1000 > th.warn, false) AS slow,
       -- crossed: slow now and not a measured minute ago (the B24h-1 review part b #5, collector_connects' form): the
       -- forming wait below reads it
       coalesce(w.ms::numeric / w.n / 1000 > th.warn AND w.n_prev >= 3 AND w.ms_prev::numeric / w.n_prev / 1000 <= th.warn, false) AS crossed
  FROM w JOIN pgvigil.instances i ON i.instance_id = w.instance_id AND i.is_active
  LEFT JOIN pgvigil.collector_probe_thresholds th ON th.instance_id = w.instance_id AND th.key = 'round_trip_time'
 WHERE w.n >= 3 AND w.newest >= now() - interval '8 minutes';

-- collector_probe_forming: 3 or more of a collector host's instances crossed into a slow round trip in their newest
-- measured minute - B24h's fold may be forming: a NEW 'query round trip slow' of them waits (the join's line 3 term, as
-- slow-connect's collector_slow_forming: the B24h-1 review part b #5 - the first member was sent before the fold formed;
-- a ping's is collector_probe_forming_hosts: the review of the fold #4)
CREATE OR REPLACE VIEW pgvigil.collector_probe_forming AS
SELECT x.instance_id
  FROM (SELECT r.instance_id, r.crossed, count(*) FILTER (WHERE r.crossed) OVER (PARTITION BY r.collector_host) AS n
          FROM pgvigil.collector_round_trips r) x
 WHERE x.crossed AND x.n >= 3;

-- collector_pings: per collector host and probed address, its probed minutes of the last 5 of the 20 (answered or not;
-- 'not probed' rows left out) of the per-minute rounds only (probe_every_minute: the review of B24h-1 part b #7, the
-- lead's 12:4x (a) - the default mode's probes after a failure feed the parent's words, never ping slow or silence):
-- rounds, answered, the answered average and longest in seconds, the newest probed minute; silent3 = none answered in
-- each of its 3 newest probed minutes, the oldest of them within 6 minutes; the 5 before the newest (answered_prev,
-- avg_s_prev: a ping 'crossed' in the judged view - the review of the fold #4) and the silence's oldest minute
-- (silent_from: an opened connection since answers for the host - the review of the fold #9)
CREATE OR REPLACE VIEW pgvigil.collector_pings AS
WITH p AS (
  SELECT h.host AS collector_host, p.host, p.address, p.method, p.minute, p.sent, p.answered, p.ms_sum, p.ms_max,
         row_number() OVER (PARTITION BY h.host, p.address ORDER BY p.minute DESC) AS k
    FROM pgvigil.collector_probe p JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE p.minute > now() - interval '20 minutes' AND p.answered IS NOT NULL AND p.scheduled AND h.retired_at IS NULL
)
SELECT collector_host, host, address, max(method) FILTER (WHERE k <= 5) AS method, count(*) FILTER (WHERE k <= 5) AS rounds,
       sum(answered) FILTER (WHERE k <= 5) AS answered,
       round(sum(ms_sum) FILTER (WHERE k <= 5)::numeric / nullif(sum(answered) FILTER (WHERE k <= 5), 0) / 1000, 3) AS avg_s,
       round(max(ms_max) FILTER (WHERE k <= 5)::numeric / 1000, 3) AS max_s,
       count(*) FILTER (WHERE k <= 3) = 3 AND coalesce(bool_and(answered = 0) FILTER (WHERE k <= 3), false)
         AND coalesce(min(minute) FILTER (WHERE k <= 3) >= now() - interval '6 minutes', false) AS silent3,
       max(minute) AS newest,   -- the newest probed minute
       sum(answered) FILTER (WHERE k BETWEEN 2 AND 6) AS answered_prev,
       round(sum(ms_sum) FILTER (WHERE k BETWEEN 2 AND 6)::numeric / nullif(sum(answered) FILTER (WHERE k BETWEEN 2 AND 6), 0) / 1000, 3) AS avg_s_prev,
       min(minute) FILTER (WHERE k <= 3) AS silent_from
  FROM p WHERE k <= 6 GROUP BY collector_host, host, address;

-- collector_probe_judged: each instance judged by its own thresholds - its round trip, and its host's ping (3 or more
-- answered probes of 5, the newest within 8 minutes: the review of B24h-1 part b #7c); 'not answering' = its host silent3
-- AND that address answered once (collector_probe_host) AND no connection to that HOST opened from that collector since
-- the silence's oldest probed minute (part b #12: an opened connection is an answer; the review of the fold #9: any
-- instance's connection to the host, so an instance read every 5 minutes does not flap) - a host that never answered
-- (ICMP blocked: a cloud endpoint) is words on the page only, never a finding (B24h-b, the fold's #6a); ping_crossed =
-- ping slow now and not in the 5 before the newest (the fold's forming wait, collector_probe_forming_hosts). ONE pass
-- (part b #4, the lead's 12:4x (a)): the pings read once and joined (a host reached at more than one address: the address
-- probed newest - an endpoint's failover moves it: the review of the fold #7 - then the most answers, then by name,
-- speaks for it), never a lateral read of the windowed view per instance. Every join on ONE key, the collector host and
-- the host (address, instance) joined by a unit separator (#b4's attempt 3, vis-bj2plan2: matched on two columns, the
-- planner merged on the collector host alone and filtered the host per pair - 4.5 million pairs a join for a collector
-- of 2,124 instances)
CREATE OR REPLACE VIEW pgvigil.collector_probe_judged AS
WITH ih AS MATERIALIZED (
  SELECT x.*, x.collector_host || E'\x1f' || x.host AS hk, x.collector_host || E'\x1f' || x.instance_id AS ik
    FROM pgvigil.collector_instance_hosts x
), rt AS MATERIALIZED (
  SELECT r.*, r.collector_host || E'\x1f' || r.instance_id AS ik FROM pgvigil.collector_round_trips r
), pgs AS MATERIALIZED (
  SELECT DISTINCT ON (x.collector_host, x.host) x.*, x.collector_host || E'\x1f' || x.host AS hk, x.collector_host || E'\x1f' || x.address AS ak
    FROM pgvigil.collector_pings x ORDER BY x.collector_host, x.host, x.newest DESC, x.answered DESC, x.address
), ans AS MATERIALIZED (
  SELECT DISTINCT h.host || E'\x1f' || ph.address AS ak FROM pgvigil.collector_probe_host ph JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE ph.last_answered IS NOT NULL
), op AS MATERIALIZED (   -- per collector host and dial host, the newest minute a connection opened (the host cut once a target)
  SELECT t.collector_host || E'\x1f' || pgvigil.collector_target_host(t.target) AS hk, max(t.last_opened) AS last_opened
    FROM (SELECT h.host AS collector_host, l.target, max(l.minute) AS last_opened
            FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
           WHERE l.minute > now() - interval '20 minutes' AND l.opened > 0 AND l.target IS NOT NULL AND h.retired_at IS NULL
           GROUP BY 1, 2) t
   GROUP BY 1
), th AS MATERIALIZED (
  SELECT instance_id, warn FROM pgvigil.collector_probe_thresholds WHERE key = 'ping_time'
)
SELECT ih.collector_host, ih.instance_id, i.name, ih.host,
       rt.avg_s AS rt_avg_s, rt.max_s AS rt_max_s, rt.warn AS rt_warn, coalesce(rt.slow, false) AS rt_slow,
       pg.method, pg.avg_s AS ping_avg_s, pg.max_s AS ping_max_s, th.warn AS ping_warn,
       coalesce(pg.answered >= 3 AND pg.avg_s > th.warn AND pg.newest >= now() - interval '8 minutes', false) AS ping_slow,
       coalesce(pg.silent3, false) AND an.ak IS NOT NULL AND NOT coalesce(o.last_opened >= pg.silent_from, false) AS not_answering,
       coalesce(pg.answered >= 3 AND pg.avg_s > th.warn AND pg.newest >= now() - interval '8 minutes'
                AND pg.answered_prev >= 3 AND pg.avg_s_prev <= th.warn, false) AS ping_crossed
  FROM ih
  JOIN pgvigil.instances i ON i.instance_id = ih.instance_id AND i.is_active
  LEFT JOIN rt ON rt.ik = ih.ik
  LEFT JOIN pgs pg ON pg.hk = ih.hk
  LEFT JOIN ans an ON an.ak = pg.ak
  LEFT JOIN op o ON o.hk = ih.hk
  LEFT JOIN th ON th.instance_id = ih.instance_id
 WHERE rt.instance_id IS NOT NULL OR pg.host IS NOT NULL;

-- collector_probe_state: every judged instance with its collector's fold beside it - the judged view read ONCE for the
-- fold, the forming hosts, the held sets and the findings (#b4's attempt 3: the held set read judged twice, its own and
-- the fold's). Per collector host: its probed hosts judged, those slow (an instance on it slow by its round trip or its
-- host's ping) and those whose ping crossed; the fold FORMS at 3 or more slow hosts and more than half, an open alert
-- STAYS while 3 or more and more than a quarter are slow (the fold's #3, SLOW-CONNECT's form)
CREATE OR REPLACE VIEW pgvigil.collector_probe_state AS
WITH j AS MATERIALIZED (
  SELECT x.*, x.collector_host || E'\x1f' || x.host AS hk FROM pgvigil.collector_probe_judged x
), hs AS MATERIALIZED (
  SELECT hk, collector_host, bool_or(rt_slow OR ping_slow) AS slow, bool_or(ping_crossed) AS crossed FROM j GROUP BY hk, collector_host
), c AS MATERIALIZED (
  SELECT collector_host, count(*) AS hosts, count(*) FILTER (WHERE slow) AS slow_hosts, count(*) FILTER (WHERE crossed) AS crossed_hosts
    FROM hs GROUP BY collector_host
), f AS MATERIALIZED (
  SELECT c.*, c.slow_hosts >= 3
              AND (c.slow_hosts * 2 > c.hosts
                   OR (c.slow_hosts * 4 > c.hosts
                       AND EXISTS (SELECT 1 FROM pgvigil.alert_state s JOIN pgvigil.alert_channels ch ON ch.name = s.channel AND ch.is_configured
                                    WHERE s.cleared_at IS NULL AND s.missing_since IS NULL AND s.source = 'pgvigil repository'
                                      AND s.setting = 'network slow from this collector' AND s.value = c.collector_host))) AS folded
    FROM c
)
SELECT j.collector_host, j.instance_id, j.name, j.host, j.rt_avg_s, j.rt_max_s, j.rt_warn, j.rt_slow, j.method, j.ping_avg_s, j.ping_max_s,
       j.ping_warn, j.ping_slow, j.not_answering, j.ping_crossed,
       f.folded, f.hosts AS fold_hosts, f.slow_hosts AS fold_slow_hosts, f.crossed_hosts, hs.crossed AS host_crossed
  FROM j JOIN f ON f.collector_host = j.collector_host JOIN hs ON hs.hk = j.hk;

-- collector_probe_forming_hosts: per collector host, its probed hosts whose ping crossed while 3 or more of its hosts
-- crossed (the review of the fold #4: the host's 'ping slow' row is the one sent - every instance's own is held under
-- it): a NEW host row of theirs waits while the fold may form (the join's line 3 term, as collector_probe_forming for a
-- round trip); a staggered crossing (one host a pass before the rest) is not covered, as slow-connect's is not
CREATE OR REPLACE VIEW pgvigil.collector_probe_forming_hosts AS
SELECT DISTINCT collector_host, host FROM pgvigil.collector_probe_state WHERE host_crossed AND crossed_hosts >= 3;

-- collector_probe_fold: B24h's own fold over its two measures (collector_probe_state's rule): per collector host, its
-- probed hosts judged and those slow; warning
CREATE OR REPLACE VIEW pgvigil.collector_probe_fold AS
SELECT DISTINCT collector_host, fold_hosts AS hosts, fold_slow_hosts AS slow_hosts FROM pgvigil.collector_probe_state WHERE folded;

-- collector_probe_held: the probe findings alert_due holds (its term is WIRING: scripts/b24h-join-lines.sql) - every
-- instance's probe finding under a standing collector fold; an instance's own ping rows under its host's row (one alert
-- a host, the fold's #2); collector_probe_held_hosts: a host's rows under a standing collector fold (each reads
-- collector_probe_state once: the judged rows and the fold in one read)
CREATE OR REPLACE VIEW pgvigil.collector_probe_held AS
SELECT p.instance_id, s.setting
  FROM pgvigil.collector_probe_state p
  CROSS JOIN (VALUES ('query round trip slow'), ('ping slow'), ('host not answering ping')) s(setting)
 WHERE p.folded OR (s.setting = 'ping slow' AND p.ping_slow) OR (s.setting = 'host not answering ping' AND p.not_answering);
CREATE OR REPLACE VIEW pgvigil.collector_probe_held_hosts AS
SELECT DISTINCT host FROM pgvigil.collector_probe_state WHERE folded;

-- collector_probe_findings: the findings shape (pgvigil.findings' arms; the arm is WIRING): an instance's round trip;
-- its host's ping and silence on the instance (held) and once for the host (source 'pgvigil repository', the host as
-- its value: one alert a host, naming the instances over their own thresholds); the collector fold
CREATE OR REPLACE VIEW pgvigil.collector_probe_findings AS
WITH j AS MATERIALIZED (SELECT * FROM pgvigil.collector_probe_state)   -- read once for every arm, the fold's too (#b4's attempt 3)
SELECT j.instance_id, 'warning'::text AS severity, 'query round trip slow'::text AS setting, j.name AS value, true AS is_set,
       'a query round trip under ' || j.rt_warn || ' s'::text AS suggested, 'all'::text AS platforms,
       'query round trip (network and the server''s response) ' || j.rt_avg_s || ' s on average, ' || j.rt_max_s
         || ' s at most over its last 5 measured minutes, from ' || j.collector_host || '; warning over ' || j.rt_warn || ' s' AS detail,
       'pgvigil collector'::text AS source, now() AS at
  FROM j WHERE j.rt_slow
UNION ALL
SELECT j.instance_id, 'warning', 'ping slow', j.host, true, 'its host answering under ' || j.ping_warn || ' s', 'all',
       'its host ' || j.host || ' answers in ' || j.ping_avg_s || ' s on average (' || j.method || '), ' || j.ping_max_s
         || ' s at most, from ' || j.collector_host || '; warning over ' || j.ping_warn || ' s', 'pgvigil collector', now()
  FROM j WHERE j.ping_slow
UNION ALL
SELECT NULL::int, 'warning', 'ping slow', h.host, true, 'the host answering under each instance''s threshold', 'all',
       'host ' || h.host || ' answers in ' || h.avg_s || ' s on average, from ' || h.collector_host || '; over the threshold of: ' || h.who,
       'pgvigil repository', now()
  FROM (SELECT collector_host, host, max(ping_avg_s) AS avg_s, string_agg(name || ' (' || ping_warn || ' s)', ', ' ORDER BY name) AS who
          FROM j WHERE ping_slow GROUP BY collector_host, host) h
UNION ALL
SELECT j.instance_id, 'warning', 'host not answering ping', j.host, true, 'its host answering ping', 'all',
       'its host ' || j.host || ' answered none of the probes of its last 3 probed minutes from ' || j.collector_host
         || ' (it answered before)', 'pgvigil collector', now()
  FROM j WHERE j.not_answering
UNION ALL
SELECT NULL::int, 'warning', 'host not answering ping', h.host, true, 'the host answering ping', 'all',
       'host ' || h.host || ' answered none of the probes of its last 3 probed minutes from ' || h.collector_host || ' (it answered before); its instances: ' || h.who,
       'pgvigil repository', now()
  FROM (SELECT collector_host, host, string_agg(name, ', ' ORDER BY name) AS who
          FROM j WHERE not_answering GROUP BY collector_host, host) h
UNION ALL
SELECT NULL::int, 'warning', 'network slow from this collector', f.collector_host, true, 'fewer than a quarter of its hosts slow', 'all',
       f.slow_hosts || ' of the ' || f.hosts || ' hosts this collector reads are slow (query round trip or ping): its own network or '
         || 'host is the likelier cause; their instances'' probe findings are held under this one', 'pgvigil repository', now()
  FROM (SELECT DISTINCT collector_host, fold_hosts AS hosts, fold_slow_hosts AS slow_hosts FROM j WHERE folded) f;
