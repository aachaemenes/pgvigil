-- B24h's lines for the joined objects (the lead's 03:3x join-file rule): 0254 creates B24h's own objects only; the next
-- join (0300_join_release3.sql) re-creates each object below WHOLE with these lines in it. Not a migration: never applied
-- by `pgvigil migrate` (scripts/ is not embedded).

-- 1. pgvigil.findings (0190's view): one more arm (scripts/b24h-join-draft-base.sql stands it in at alert_findings, the
--    view alert_due reads findings through)
--    UNION ALL SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.collector_probe_findings

-- 2. pgvigil.collector_shared_cause (0121): the three settings join 'pgvigil collector''s list (201's parent holds them)
--    p_source = 'pgvigil collector' AND p_setting IN ('authentication failing', 'collection failing', 'server unreachable', 'slow connect',
--                                                     'query round trip slow', 'ping slow', 'host not answering ping')

-- 3. alert_due (0190): the terms marked 'B24h line 3' in scripts/b24h-join-draft-alertdue.sql - that file is 0190's
--    alert_due (L476-574 at df95d278) with them in, proven by TestProbeAlertDueDraftOnAStore on the drafts (the review of
--    the fold #5: BJb4 / BJb5 / BJf3 / BJf4) and timed by BJf2; the join diffs it against 0190 and writes the terms into
--    0300's alert_due. In short:
--    - CTEs read once a pass (the review of the fold #1: none inside the per-row filter reads a view of its own, each
--      term an uncorrelated IN, hashed once): probe_state (collector_probe_state: the judged rows and the fold in ONE
--      read) and, from it, probe_held, probe_held_hosts (with the hosts of instances under 'held'), probe_under_slow
--      (judged from a collector whose slow-connect host fold stands: slow_folds, kind 'host', value = the collector
--      host), probe_forming_hosts; probe_forming (the round trips); probe_parents (collector_parent's hosts whose why is
--      the collector's own: 'collector not seen', 'instances failing together') and probe_stopped ('collector not seen'
--      alone: the resolve guards) - the review of F9 #1; af (alert_findings read once a pass, which sc and s's 'present'
--      read: line 1 puts the judged rows in it - the review of F9 #3);
--    - m: an instance's probe finding held while probe_held names it or it is under slow-connect's host fold; a host's
--      row ('ping slow', 'host not answering ping') while probe_held_hosts names the host; B24h's
--      fold while its collector's own parent (probe_parents) or slow-connect's host fold stands (part b #2 / #8);
--    - a NEW 'query round trip slow' waits while probe_forming names its instance, a NEW host 'ping slow' row while
--      probe_forming_hosts names its host (part b #5, the review of the fold #4; a staggered crossing is sent first, as
--      slow-connect's is);
--    - the resolve arm: B24h's fold, and a host's rows of a collector not seen (probe_stopped), are not 'resolved' (part b
--      #2, the review of the fold #3, of F9 #1).

-- 4. import_pg_threshold (0190): a SQL Server instance's own level takes B24h's keys too
--    AND (i.engine = 'postgres' OR (v_key IN ('uptime', 'connect_time', 'round_trip_time', 'ping_time') AND v_level = 'instance'))

-- 5. purge() (0190): collector_probe's 8 days (the B24h-1 fold part b #9: a store under probe_every_minute grew without
--    end) - here, not in import_collector_probe: a per-beat DELETE cost 3.5-4.1 s a beat at 2,124 addresses (BJf8, the
--    review of the fold's bar 50 ms); a daily purge deletes a day (about 3 M rows at 2,124 addresses) once - and the
--    collector_probe_host rows of a retired collector with its heartbeat row
--    DELETE FROM pgvigil.collector_probe WHERE minute < now() - interval '8 days';
--    GET DIAGNOSTICS v_rows = ROW_COUNT; n := n + v_rows;
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
