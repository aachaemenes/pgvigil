-- 0271 (N4): partitions made AHEAD, each in its own short transaction, so that no import makes one in the normal path.
--
-- An import that first meets a month (or a day) without a partition makes it inside its own transaction and so holds
-- ACCESS EXCLUSIVE on the parent until it commits (and SHARE ROW EXCLUSIVE on pgvigil.instances for a parent with a
-- foreign key to it); a second import that already wrote a shared row (query_text) then waits on the parent while the
-- first waits on that row: a deadlock (40P01; a 20-day demo seed across a month line). With the month's partition
-- there, ensure_month_partition takes no lock at all (to_regclass) and an import's INSERT only ROW EXCLUSIVE on the parent
-- and the routed partition (read on PostgreSQL 18.6). Here:
--   partition_parents()          every range-partitioned parent of schema pgvigil and the maker its imports call: a
--                                parent ranged on snapshot_at takes ensure_month_partition (0002), mssql_requests
--                                mssql_ensure_day_partition (0064), any other range key mssql_event_partition (0065)
--   import_partitions_due(a, b)  the partitions missing between a and b (months; days for the daily parent), read only
--   import_partition_make(t, at) one partition by its parent's own maker under its own short lock_timeout: an answer
--                                'made', 'exists' or 'busy' (a lock not had in time, or a deadlock it lost)
-- The collector (internal/repo: PartitionsAhead) calls the make once per missing partition, each call its own
-- transaction: a transaction that holds one parent cannot close a cycle with imports. The make's lock_timeout is 450 ms,
-- or half of deadlock_timeout when that is less, so in a cycle of the make and ONE other transaction the make gives up
-- before the other side's deadlock check; in a longer cycle a member that has waited since before the make took the
-- parent may be checked first and chosen: an import is then taken again (repo.Import's retry), an admin's delete of an
-- instance fails and is run again. The makers inside the imports stay: old or late data, a stopped scheduler.
-- Both door functions start with import_, so apply_roles makes them SECURITY DEFINER and grants them to the collector.
-- The collector gains one right: alert_log's current and next month (an empty partition; 0059's door makes the month
-- for the alerter within a day of now()); an earlier month of alert_log stays the owner's, as 0059 keeps it. For every
-- other parent any import already makes any month from its own time. The make refuses a partition starting more than
-- 62 days ahead (the next month always starts within 31) and a name that is not a parent.
-- Ported from the earlier build of the same design (rel-pdeadlock's 0135, 11-14), its retry and beat parts left out.

CREATE OR REPLACE FUNCTION pgvigil.partition_parents()
RETURNS TABLE (parent text, maker text, unit text) LANGUAGE sql STABLE AS $$
  SELECT c.relname::text,
         CASE WHEN c.relname = 'mssql_requests' THEN 'day' WHEN a.attname = 'snapshot_at' THEN 'month' ELSE 'event' END,
         CASE WHEN c.relname = 'mssql_requests' THEN 'day' ELSE 'month' END
    FROM pg_partitioned_table pt
    JOIN pg_class c ON c.oid = pt.partrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = pt.partattrs[0]
   WHERE n.nspname = 'pgvigil' AND NOT c.relispartition AND pt.partstrat = 'r' AND pt.partnatts = 1
$$;

CREATE OR REPLACE FUNCTION pgvigil.import_partitions_due(p_from timestamptz, p_to timestamptz)
RETURNS TABLE (parent text, unit text, starts timestamptz) LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
BEGIN
  IF p_from IS NULL OR p_to IS NULL OR p_to < p_from OR p_to - p_from > interval '400 days' THEN
    RAISE EXCEPTION 'import_partitions_due: % to % is not a span of 0 to 400 days', p_from, p_to USING ERRCODE = '22023';
  END IF;
  RETURN QUERY
  SELECT p.parent, p.unit, g.s
    FROM pgvigil.partition_parents() p
   CROSS JOIN LATERAL (
     SELECT x AT TIME ZONE 'UTC' AS s
       FROM generate_series(date_trunc(p.unit, p_from AT TIME ZONE 'UTC'), date_trunc(p.unit, p_to AT TIME ZONE 'UTC'),
                            CASE p.unit WHEN 'day' THEN interval '1 day' ELSE interval '1 month' END) x) g
   WHERE to_regclass('pgvigil.' || quote_ident(p.parent || '_' ||
           to_char(g.s AT TIME ZONE 'UTC', CASE p.unit WHEN 'day' THEN 'YYYYMMDD' ELSE 'YYYYMM' END))) IS NULL
   ORDER BY p.parent, g.s;
END $$;

-- The SET clause keeps the function's lock_timeout to the function (a set_config inside it is undone at its end too).
CREATE OR REPLACE FUNCTION pgvigil.import_partition_make(p_parent text, p_at timestamptz)
RETURNS text LANGUAGE plpgsql SET lock_timeout = '450ms' AS $$
DECLARE
  v_maker text;
  v_unit  text;
  v_start timestamptz;
  v_name  text;
  v_dl    int := (SELECT s.setting::int FROM pg_settings s WHERE s.name = 'deadlock_timeout');   -- milliseconds
BEGIN
  IF v_dl IS NOT NULL AND v_dl / 2 < 450 THEN
    PERFORM set_config('lock_timeout', greatest(v_dl / 2, 1)::text || 'ms', true);
  END IF;
  SELECT p.maker, p.unit INTO v_maker, v_unit FROM pgvigil.partition_parents() p WHERE p.parent = p_parent;
  IF v_maker IS NULL THEN
    RAISE EXCEPTION 'import_partition_make: % is not a partitioned table of schema pgvigil', p_parent USING ERRCODE = '22023';
  END IF;
  IF p_at IS NULL THEN
    RAISE EXCEPTION 'import_partition_make: no time given' USING ERRCODE = '22023';
  END IF;
  v_start := date_trunc(v_unit, p_at AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  IF v_start > now() + interval '62 days' THEN
    RAISE EXCEPTION 'import_partition_make: % starts %, more than 62 days ahead', p_parent, v_start USING ERRCODE = '22023';
  END IF;
  IF p_parent = 'alert_log' AND v_start < date_trunc('month', now() AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
     AND NOT pg_has_role(session_user, (SELECT n.nspowner FROM pg_namespace n WHERE n.nspname = 'pgvigil'), 'MEMBER') THEN
    RAISE EXCEPTION 'import_partition_make: an earlier month of alert_log is the owner''s (0059)' USING ERRCODE = '42501';
  END IF;
  v_name := p_parent || '_' || to_char(v_start AT TIME ZONE 'UTC', CASE v_unit WHEN 'day' THEN 'YYYYMMDD' ELSE 'YYYYMM' END);
  IF to_regclass('pgvigil.' || quote_ident(v_name)) IS NOT NULL THEN
    RETURN 'exists';
  END IF;
  BEGIN
    CASE v_maker
      WHEN 'month' THEN PERFORM pgvigil.ensure_month_partition(p_parent, v_start);
      WHEN 'day'   THEN PERFORM pgvigil.mssql_ensure_day_partition(p_parent, v_start);
      ELSE              PERFORM pgvigil.mssql_event_partition(p_parent, v_start);
    END CASE;
  EXCEPTION WHEN lock_not_available OR deadlock_detected THEN
    RETURN 'busy';   -- the block's locks went with it; the next pass tries again
  END;
  RETURN 'made';   -- this call ran the maker: two passes at once may both count one partition (the maker takes the other's)
END $$;
