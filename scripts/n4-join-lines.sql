-- N4-P10 (the purge 22008 fault): the lines for the join, placed in place in the migrations named (neither file is
-- released yet: until v0.4.0 the join edits migrations in place). Not a migration of its own; kept as the record of
-- what the join placed. scripts/n4-wiring.patch places exactly these lines for the proof (proof-purge's OID row).
--
-- The fault: a month test on c.relname inside a WHERE may be tested on every pg_class row before the join to
-- pg_inherits (no evaluation order is promised), and a TOAST table pg_toast_<six digits> whose last two digits are no
-- month (13-99 or 00: the database past OID 100,000) makes to_date fail the whole purge with SQLSTATE 22008
-- ('date/time field value out of range: "10001701"', box job sqltb-s2-n4-2, purge -days 30 under hash joins and scans
-- only). The fix: a strict month pattern, and the parse inside a CASE on it.

-- (1) 0190_join_release2.sql, pgvigil.purge(): the two lines
--       AND c.relname ~ '_[0-9]{6}$'
--       AND (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)
--     become (three comment lines, three code lines):
       -- a name ending in a month (YYYYMM), parsed inside a CASE: the server may test these conditions on every pg_class
       -- row before the join, in any order, and a TOAST table pg_toast_<six digits> ending in no month (a database past
       -- OID 100,000) failed the whole purge with 22008 (proof-purge's OID row)
       AND c.relname ~ '_[0-9]{4}(0[1-9]|1[0-2])$'
       AND (CASE WHEN c.relname ~ '_[0-9]{4}(0[1-9]|1[0-2])$' THEN to_date(right(c.relname, 6) || '01', 'YYYYMMDD') END
            + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)

-- (2) 0139_job_stats_hourly.sql, pgvigil.job_stats_hourly_purge() (purge()'s last block calls it): the same two lines
--     with v_days for p_days become the same six (three comment lines, three code lines), with v_days.

-- Read and left (no line): the older purge() bodies (0002-0110), replaced by 0190's; 0064's mssql_running_purge() (its
-- last body), whose day parse is anchored to '^mssql_requests_[0-9]{8}$' (a TOAST name never matches; a table of that
-- name with eight digits that are no date would); scripts/menu-check.mjs L626 / L628 and scripts/proof-range.sh L136-137
-- (the walks' and the range proof's own reads, on fresh containers far below OID 100,000).
-- Changed in Go beside these lines (not join lines): repo.go's PurgeCandidates (the WIRING patch, repo.go is shared)
-- and internal/web/q_retention.go - its CTEs MATERIALIZED with the strict month and day patterns, the hours read's
-- FILTER guarded by the CASE (today's shapes passed on PostgreSQL 18.6 under a forced plan in the code review's probe;
-- a CTE read once with a month test outside it failed with 22008 there, so the safety is made explicit).

-- (3) N4 T9 (the lead's (d)): 0121_collector_health.sql, pgvigil.import_collector_beat() - the beat's runs[].retries into
--     0271's collector_runs.retries. A join line, not a CREATE OR REPLACE in 0271: rel-b6g (B6.4 / B6g-2) edits this
--     function in place too (its sends_alerts arm), and a later replace would drop the other slice's arm. In the
--     INSERT INTO pgvigil.collector_runs of the runs:
--       the column list gains   retries
--       the SELECT gains        greatest(coalesce(r.retries, 0), 0)
--       the recordset gains     retries int        (after hist jsonb)
--       ON CONFLICT ... SET gains   retries = collector_runs.retries + EXCLUDED.retries,
--     and the function's header comment names runs[].retries (absent = 0, an older collector). The column itself is
--     0271's (ALTER TABLE ... ADD COLUMN IF NOT EXISTS retries int NOT NULL DEFAULT 0).

-- (4) N4 T9 (the stalled pass): 0121_collector_health.sql, pgvigil.collector_findings - one arm after the 'purge not
--     run in 2 days' arm:
--       UNION ALL
--       SELECT * FROM pgvigil.partitions_ahead_finding(now())
--     and, before the view, a DO block making a stub pgvigil.partitions_ahead_finding(timestamptz) (same signature and
--     result columns, no rows) only where the function is absent: the view is made before 0271, which gives the
--     function its body (rel-b6g's collection_dont_monitor stub is the same form). A join line, not a CREATE OR REPLACE
--     VIEW in 0271: rel-b6g edits this view in place too (collection_dont_monitor). The functions themselves are 0271's
--     (partitions_missing_next, partitions_ahead_finding).
