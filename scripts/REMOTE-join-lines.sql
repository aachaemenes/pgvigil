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

-- 4. pgvigil.apply_roles (0300's): the INGEST DOOR (H review part 1 B5, the slice lead's (a) 12:3x) - 0329's ingest
--    functions run as the owner and are pgvigil_ingest's alone (never pgvigil_collector's - a collector login could load
--    a batch row and hide a site's data - nor the reader's). In the function loop, a branch BEFORE the import\_% one:
--      ELSIF f.proname IN ('remote_site_sync', 'remote_sites_retire', 'remote_ensure_instance', 'remote_seen', 'remote_newest',
--                          'remote_recorded', 'remote_retries', 'remote_retry', 'remote_bundle_begin', 'remote_batch',
--                          'remote_bundle_done', 'remote_mark', 'remote_purge') THEN
--        EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER SET search_path = pgvigil, pg_catalog, pg_temp', f.sig);
--        EXECUTE format('REVOKE ALL ON FUNCTION %s FROM pgvigil_reader, pgvigil_collector', f.sig);
--        EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO pgvigil_ingest', f.sig);
--    and pgvigil_ingest in the schema's USAGE grant (0329 creates the role and grants it; apply_roles re-grants it):
--      GRANT USAGE ON SCHEMA pgvigil TO pgvigil_collector, pgvigil_reader, pgvigil_auth, pgvigil_ingest;
