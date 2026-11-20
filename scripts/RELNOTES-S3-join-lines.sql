-- RELNOTES-S3-join-lines.sql - the RELNOTES rows' arms of the joined views (the join-file rule): their migration 0455 is
-- above 0300, so it creates only its own objects (pgvigil.collector_inline_password, import_collector_inline_passwords,
-- pgvigil.inline_password_findings) and this file holds the lines the next join puts into the views it re-creates
-- whole. Not a migration: nothing runs this file; the join copies each arm in place.

-- 1. pgvigil.findings (0300's union, re-created whole by the next join): one arm after collector_findings' -
--    L9: an inline PostgreSQL password in pgvigil.yaml, a warning on the instance (0455)
    UNION ALL
    -- RELNOTES-S3 L9 (0455): an inline PostgreSQL password in pgvigil.yaml, as the collector's start lists it
    SELECT instance_id, severity, setting, value, is_set, suggested, platforms, detail, source, at FROM pgvigil.inline_password_findings

-- 1b. WIRING (rn-l9 S2): the arm is 'pgvigil collector''s own finding, so the Collector page's findings read it too -
--     sqlCollectorFindings (internal/web/q_collector.go) gains, beside its other own arms, the same SELECT ... FROM
--     pgvigil.inline_password_findings; TestCollectorFindingsReadsItsArms goes red on line 1 alone (KITWATCH's 0253
--     line 22-23 did the same).

-- 2. pgvigil.collector_shared_cause (0300): NOT joined - 'inline password' is a configuration fact, never a symptom a
--    host or network cut explains, so it is sent as any finding while a parent stands (named here so the join leaves it out
--    on purpose).

-- 3. pgvigil.import_admin_source (RELNOTES L237, 0476): RE-MADE whole by 0476 from 0123's text with auto_add (the
--    v_auto / v_door lines - v_door coalesced to false, 718bdf8e6: an absent door is the door shut -, the two refusals, the insert's and the edit's auto_add, the notes cleared on off, the
--    audit's '; adds what it finds by itself'). A NAMED CHECK of the join: a file of another branch that re-makes
--    import_admin_source after 0476 (or one 0476 lands after) carries these lines, else the switch is lost or a
--    newer line of that file is.
