-- REMOTE's lines for the joined objects (the 03:3x join-file rule, as BLITZ-GAP's): 0329 creates REMOTE's own objects;
-- the next join re-creates each object below WHOLE with its line in it. Not a migration: never applied by `pgvigil
-- migrate` (scripts/ is not embedded). scripts/remote-join-draft.sql stands them in for the proofs (0300's text whole,
-- each line marked 'REMOTE line <n>').

-- 1. pgvigil.findings (0300's view): one more arm, last - a remote site, and each of its instances, gone quiet past
--    2 x its site's expected_every (warning; 6 x critical; 0329's view)
--      UNION ALL
--      SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.remote_silence_findings

-- 2. pgvigil.alert_due (0300's): an instance a site owns clears no sooner than its bundle interval + its site's
--    expected_every (V1, the slice lead 10:2x: never in alerts.go - the resolve test is SQL, 0300 L831 / L833). In the
--    CTE s, the channel's clear_after_secs becomes:
--      greatest(ch.clear_after_secs, coalesce((SELECT r.interval_secs + r.expected_every_secs FROM pgvigil.remote_instance_state r
--                                              WHERE r.instance_id = st.instance_id), 0)) AS clear_after_secs

-- 3. pgvigil.purge (0300's): the remote ledgers past 90 days (0329's remote_purge: a loaded bundle with its batches, a
--    cleared mark; each stream's high-water and an uncleared mark kept), before the run is recorded:
--      IF to_regprocedure('pgvigil.remote_purge(integer)') IS NOT NULL THEN
--        n := n + pgvigil.remote_purge(90);
--      END IF;
