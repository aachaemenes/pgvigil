-- B24h's lines for the joined objects (the lead's 03:3x join-file rule): 0254 creates B24h's own objects only; the next
-- join (0300_join_release3.sql) re-creates each object below WHOLE with these lines in it. Not a migration: never applied
-- by `pgvigil migrate` (scripts/ is not embedded).

-- 1. pgvigil.findings (0190's view): one more arm
--    UNION ALL SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.collector_probe_findings

-- 2. pgvigil.collector_shared_cause (0121): the three settings join 'pgvigil collector''s list (201's parent holds them)
--    p_source = 'pgvigil collector' AND p_setting IN ('authentication failing', 'collection failing', 'server unreachable', 'slow connect',
--                                                     'query round trip slow', 'ping slow', 'host not answering ping')

-- 3. alert_due (0190): the hold terms beside slow-connect's - an instance's probe finding held while
--    pgvigil.collector_probe_held names it; a host's row held while pgvigil.collector_probe_held_hosts names the host
--    AND NOT (sc.source = 'pgvigil collector' AND sc.setting IN ('query round trip slow', 'ping slow', 'host not answering ping')
--             AND EXISTS (SELECT 1 FROM pgvigil.collector_probe_held h WHERE h.instance_id = sc.instance_id AND h.setting = sc.setting))
--    AND NOT (sc.source = 'pgvigil repository' AND sc.setting IN ('ping slow', 'host not answering ping')
--             AND sc.value IN (SELECT host FROM pgvigil.collector_probe_held_hosts))

-- 4. import_pg_threshold (0190): a SQL Server instance's own level takes B24h's keys too
--    AND (i.engine = 'postgres' OR (v_key IN ('uptime', 'connect_time', 'round_trip_time', 'ping_time') AND v_level = 'instance'))

-- 5. purge() (0190): collector_probe kept as collector_load (8 days); collector_probe_host rows of a retired collector
--    with its heartbeat row
--    DELETE FROM pgvigil.collector_probe WHERE minute < now() - interval '8 days';
--    DELETE FROM pgvigil.collector_probe_host ph WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat h WHERE h.collector_id = ph.collector_id);

-- 6. the parents' words (the fold's #7): 'server unreachable' (0121) and 'collector or network''s 'server not answering'
--    (0190) end their detail with the probe's answer for the instance's host, newest of the last 5 minutes:
--    'the host answers (tcp): the service is down, not the host' when collector_pings.answered > 0, 'the host does not
--    answer either (tcp): the host or the network' when it is 0, nothing when not probed
