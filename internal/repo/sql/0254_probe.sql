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
  PRIMARY KEY (minute, collector_id, address)
);

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
  INSERT INTO pgvigil.collector_probe AS p (minute, collector_id, host, address, method, sent, answered, ms_sum, ms_max)
  SELECT date_trunc('minute', coalesce(r.at, p_minute)), p_collector, coalesce(r.host, ''), r.address, r.method, coalesce(r.sent, 0), r.answered,
         coalesce(r.ms_sum, 0), coalesce(r.ms_max, 0)
    FROM jsonb_to_recordset((CASE WHEN jsonb_typeof(p_beat->'probes') = 'array' THEN p_beat->'probes' ELSE '[]'::jsonb END))
         AS r(host text, address text, method text, at timestamptz, sent int, answered int, ms_sum bigint, ms_max int)
   WHERE r.address IS NOT NULL AND r.method IN ('icmp', 'tcp')
  ON CONFLICT (minute, collector_id, address) DO UPDATE
     SET sent = p.sent + EXCLUDED.sent, answered = CASE WHEN EXCLUDED.answered IS NULL THEN p.answered ELSE coalesce(p.answered, 0) + EXCLUDED.answered END,
         ms_sum = p.ms_sum + EXCLUDED.ms_sum, ms_max = greatest(p.ms_max, EXCLUDED.ms_max), method = EXCLUDED.method, host = EXCLUDED.host;
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
END
$$;
