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
--     become:
       -- a name ending in a month (YYYYMM), parsed inside a CASE: the server may test these conditions on every pg_class
       -- row before the join, in any order, and a TOAST table pg_toast_<six digits> ending in no month (a database past
       -- OID 100,000) failed the whole purge with 22008 (proof-purge's OID row)
       AND c.relname ~ '_[0-9]{4}(0[1-9]|1[0-2])$'
       AND (CASE WHEN c.relname ~ '_[0-9]{4}(0[1-9]|1[0-2])$' THEN to_date(right(c.relname, 6) || '01', 'YYYYMMDD') END
            + interval '1 month') AT TIME ZONE 'UTC' < now() - make_interval(days => p_days)

-- (2) 0139_job_stats_hourly.sql, pgvigil.job_stats_hourly_purge() (purge()'s last block calls it): the same two lines
--     with v_days for p_days become the same five, with v_days.

-- Read and left (no line): internal/web/q_retention.go's month / day parses sit in a CTE's select list over rows
-- already joined to a pgvigil parent (sqlRetentionTables' and sqlStored's p, each read more than once, so not
-- inlined) or in an aggregate's FILTER after a join (sqlRetentionHours) [inferred from the query shapes; not proven
-- past OID 100,000]; the older purge() bodies (0002-0110) are replaced by 0190's.
