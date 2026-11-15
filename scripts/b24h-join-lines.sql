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
--             AND sc.value IN (SELECT host FROM probe_held_hosts))
--    with the two sets read once each as alert_due's slow_held is (the B24h-1 review part b #4):
--      probe_held AS MATERIALIZED (SELECT * FROM pgvigil.collector_probe_held),
--      probe_held_hosts AS MATERIALIZED (SELECT * FROM pgvigil.collector_probe_held_hosts)
--    (and 'collector_probe_held h' above reads probe_held). The host rows under 'collector or network' (part b #2: the
--    parent's hold reads instance ids, a host row has none):
--    AND NOT (sc.source = 'pgvigil repository' AND sc.setting IN ('ping slow', 'host not answering ping')
--             AND sc.value IN (SELECT j.host FROM pgvigil.collector_probe_judged j JOIN held ON held.instance_id = j.instance_id))
--    B24h's fold held while its collector's parent stands (part b #2) and while SLOW-CONNECT's host fold stands for the
--    same collector - one alert, not three (part b #8, the lead's 12:4x (a)) - and its members under SLOW-CONNECT's fold:
--    AND NOT (sc.source = 'pgvigil repository' AND sc.setting = 'network slow from this collector'
--             AND (EXISTS (SELECT 1 FROM pgvigil.collector_parent p WHERE p.host = sc.value)
--                  OR EXISTS (SELECT 1 FROM pgvigil.collector_slow_folds f WHERE f.kind = 'host' AND f.host = sc.value)))
--    AND NOT (sc.source = 'pgvigil collector' AND sc.setting IN ('query round trip slow', 'ping slow', 'host not answering ping')
--             AND EXISTS (SELECT 1 FROM pgvigil.collector_probe_judged j JOIN pgvigil.collector_slow_folds f ON f.kind = 'host' AND f.host = j.collector_host
--                          WHERE j.instance_id = sc.instance_id))
--    and in alert_due's resolve arm, as 'slow connects' is guarded (0190 L563-564): the fold is not resolved while its
--    collector's parent stands (part b #2: its round trips leave the judged set 8 minutes into an outage)
--    AND NOT (s.source = 'pgvigil repository' AND s.setting = 'network slow from this collector'
--             AND EXISTS (SELECT 1 FROM pgvigil.collector_parent p WHERE p.host = s.value))

-- 4. import_pg_threshold (0190): a SQL Server instance's own level takes B24h's keys too
--    AND (i.engine = 'postgres' OR (v_key IN ('uptime', 'connect_time', 'round_trip_time', 'ping_time') AND v_level = 'instance'))

-- 5. purge() (0190): collector_probe_host rows of a retired collector with its heartbeat row (collector_probe's 8 days are
--    import_collector_probe's own trim since the B24h-1 fold, part b #9)
--    DELETE FROM pgvigil.collector_probe_host ph WHERE NOT EXISTS (SELECT 1 FROM pgvigil.collector_heartbeat h WHERE h.collector_id = ph.collector_id);

-- 6. the parents' words (the fold's #7): 'server unreachable' (0121's collector_findings) and 'server not answering'
--    (0121's collector_parent / collector_findings - not 0190's: the B24h-1 review part b #10) end their detail with the
--    probe's NEWEST answer for the instance's host (part b #10: not the 20 minutes' sum):
--      (SELECT p.answered FROM pgvigil.collector_probe p JOIN pgvigil.collector_heartbeat h USING (collector_id)
--        WHERE h.host = <the collector host> AND p.host = <the instance's host> AND p.answered IS NOT NULL
--          AND p.minute > now() - interval '5 minutes' ORDER BY p.minute DESC LIMIT 1)
--    'the host answers (tcp): the service is down, not the host' when it is above 0, 'the host does not answer either
--    (tcp): the host or the network' when it is 0, nothing when not probed

-- 7. alert_key (0121): the host-valued probe rows keep their host whole, as 'collector or network' and 'slow connects'
--    (the B24h-1 review part b #1, BLOCKER: alert_finding_key masks digits, so 10.0.0.5 and 10.0.0.6 were one key)
--    p_instance_id IS NULL AND p_source = 'pgvigil repository'
--      AND p_setting IN ('collector or network', 'slow connects', 'collections run long', 'ping slow', 'host not answering ping',
--                        'network slow from this collector')

-- 8. import_pg_threshold (0190): the two B24h keys in seconds to three places and settable empty (the B24h-1 review
--    part b #3: 0.025 and 0.005 were refused; off could not be set)
--    the value's shape, set in the loop's DECLARE (never a CASE inside the IF's condition: PL/pgSQL ends an IF's
--    condition at its first THEN - rel-b6g vis-b6g0166):
--      DECLARE v text := ...; v_re text := CASE WHEN v_k.unit = 'seconds' THEN '^[0-9]{1,7}(\.[0-9]{1,3})?$' ELSE '^[0-9]{1,7}(\.[0-9]{1,2})?$' END;
--      ... IF v IS NOT NULL AND v !~ v_re THEN
--    both values null allowed: v_key NOT IN ('uptime', 'crash', 'round_trip_time', 'ping_time') at L826
--    the no-PostgreSQL-instance words (L802) name the two keys among those a SQL Server instance takes
