-- 0273_long_range_reports: B20's long-range reports (the lead 11-15 16:3x / 17:0x / 18:1x).
--   trend_series: the Trend report's reader (B20-1) - one series per instance (or per database of one instance) of a
--   metric over raw samples of both engines, a statistic inside each hour or day bucket. Raw only: B21's hours add
--   their arm in B21's reader slice (419), not here. The fleet file-IO window (the newest raw days the fleet latency
--   reads) is the handler's: it moves p_from; this function reads what it is given.
--   The metrics and their cells (the design's table, review-19's fold):
--     os_cpu       SQL Server 100 - mssql_cpu_sample.idle_pct; PostgreSQL host_sample.cpu_pct (system_stats or CloudWatch)
--     sql_cpu      SQL Server mssql_cpu_sample.sql_pct; PostgreSQL has none (the handler says so)
--     latency      SQL Server sum(stall) / sum(IO) over a sample's files (mssql_fileio_sample), per database with
--                  p_by = 'database'; PostgreSQL (read_time + write_time) / (reads + writes) of iostats_rate's deltas
--                  where track_io_timing is on, else CloudWatch Read / WriteLatency x 1000; a sample under 1 IO a
--                  second draws nothing (0031's floor)
--     active       SQL Server mssql_requests_summary.requests; PostgreSQL activity_summary.active
--     free_memory  a percent of the total: available_kb / physical_kb; (mem_free + mem_cache) / mem_total
--     connections  SQL Server mssql_session_summary sessions - background; PostgreSQL activity_summary.total
--   p_stat: p50 / p95 / p98 / p99 / max, or p5 / p2 / p1 / min (memory ranks lowest first); a percentile is
--   percentile_cont inside the bucket; p_hour keeps one hour of the day in p_tz; a bucket's 'at' is its start in p_tz.
--   One read gives both: a row per bucket, and a row with 'at' NULL per series - its statistic over every sample of
--   the range (the rank the top N orders by; GROUPING SETS, so the samples are read once).

CREATE OR REPLACE FUNCTION pgvigil.trend_series(p_metric text, p_ids int[], p_from timestamptz, p_to timestamptz,
  p_bucket text, p_stat text, p_hour int, p_tz text, p_by text DEFAULT NULL)
RETURNS TABLE (instance_id int, database_name text, at timestamptz, v double precision, n int)
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_frac double precision := CASE p_stat WHEN 'p50' THEN 0.5 WHEN 'p95' THEN 0.95 WHEN 'p98' THEN 0.98 WHEN 'p99' THEN 0.99
                                         WHEN 'max' THEN 1 WHEN 'p5' THEN 0.05 WHEN 'p2' THEN 0.02 WHEN 'p1' THEN 0.01 WHEN 'min' THEN 0 END;
  v_ids  text := 'AND ($1 IS NULL OR x.instance_id = ANY ($1))';
  v_t    text := 'x.snapshot_at > $2 AND x.snapshot_at <= $3';
  v_src  text;
BEGIN
  IF v_frac IS NULL THEN RAISE EXCEPTION 'stat must be p50, p95, p98, p99, max, p5, p2, p1 or min, not %', p_stat; END IF;
  IF p_bucket NOT IN ('hour', 'day') THEN RAISE EXCEPTION 'bucket must be hour or day, not %', p_bucket; END IF;
  IF p_hour IS NOT NULL AND (p_hour < 0 OR p_hour > 23) THEN RAISE EXCEPTION 'hour must be 0 to 23, not %', p_hour; END IF;
  PERFORM now() AT TIME ZONE p_tz;   -- an unknown zone is refused here, in PostgreSQL's words
  -- s: one row per sample (instance_id, database_name, at, v)
  v_src := CASE p_metric
    WHEN 'os_cpu' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, (100 - x.idle_pct)::float8 FROM pgvigil.mssql_cpu_sample x WHERE %1$s AND x.idle_pct IS NOT NULL %2$s
       UNION ALL SELECT x.instance_id, NULL, x.snapshot_at, x.cpu_pct::float8 FROM pgvigil.host_sample x WHERE %1$s AND x.cpu_pct IS NOT NULL %2$s', v_t, v_ids)
    WHEN 'sql_cpu' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, x.sql_pct::float8 FROM pgvigil.mssql_cpu_sample x WHERE %1$s %2$s', v_t, v_ids)
    WHEN 'latency' THEN format(
      'SELECT x.instance_id, %3$s, x.snapshot_at, sum(x.read_stall_ms + x.write_stall_ms)::float8 / sum(x.reads + x.writes)
         FROM pgvigil.mssql_fileio_sample x WHERE %1$s %2$s
        GROUP BY x.instance_id, %3$s, x.snapshot_at HAVING sum(x.reads + x.writes) / max(x.interval_secs) >= 1
       UNION ALL
       SELECT r.instance_id, NULL, r.snapshot_at, sum(r.read_time + r.write_time) / sum(r.reads + r.writes)
         FROM pgvigil.instances x JOIN pgvigil.instance_state st ON st.instance_id = x.instance_id AND st.track_io_timing = ''on''
        CROSS JOIN LATERAL pgvigil.iostats_rate(x.instance_id, $2, $3) r
        WHERE x.engine = ''postgres'' %2$s AND $4 IS NULL
        GROUP BY r.instance_id, r.snapshot_at HAVING sum(r.reads + r.writes) / max(r.interval_secs) >= 1
       UNION ALL
       SELECT x.instance_id, NULL, x.snapshot_at, avg(x.value) * 1000 FROM pgvigil.cloud_io_sample x
        WHERE %1$s %2$s AND $4 IS NULL AND x.metric IN (''ReadLatency'', ''WriteLatency'') AND x.value IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM pgvigil.instance_state st WHERE st.instance_id = x.instance_id AND st.track_io_timing = ''on'')
        GROUP BY x.instance_id, x.snapshot_at', v_t, v_ids, CASE WHEN p_by = 'database' THEN 'x.database_name' ELSE 'NULL::text' END)
    WHEN 'active' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, x.requests::float8 FROM pgvigil.mssql_requests_summary x WHERE %1$s %2$s
       UNION ALL SELECT x.instance_id, NULL, x.snapshot_at, x.active::float8 FROM pgvigil.activity_summary x WHERE %1$s AND x.active IS NOT NULL %2$s', v_t, v_ids)
    WHEN 'free_memory' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, 100.0 * x.available_kb / x.physical_kb FROM pgvigil.mssql_memory_sample x
        WHERE %1$s AND x.physical_kb > 0 AND x.available_kb IS NOT NULL %2$s
       UNION ALL SELECT x.instance_id, NULL, x.snapshot_at, 100.0 * (x.mem_free + coalesce(x.mem_cache, 0)) / x.mem_total FROM pgvigil.host_sample x
        WHERE %1$s AND x.mem_total > 0 AND x.mem_free IS NOT NULL %2$s', v_t, v_ids)
    WHEN 'connections' THEN format(
      'SELECT x.instance_id, NULL::text, x.snapshot_at, (x.sessions - coalesce(x.background, 0))::float8 FROM pgvigil.mssql_session_summary x
        WHERE %1$s AND x.sessions IS NOT NULL %2$s
       UNION ALL SELECT x.instance_id, NULL, x.snapshot_at, x.total::float8 FROM pgvigil.activity_summary x WHERE %1$s AND x.total IS NOT NULL %2$s', v_t, v_ids)
  END;
  IF v_src IS NULL THEN RAISE EXCEPTION 'metric must be os_cpu, sql_cpu, latency, active, free_memory or connections, not %', p_metric; END IF;
  IF p_by IS NOT NULL AND (p_by <> 'database' OR p_metric <> 'latency') THEN RAISE EXCEPTION 'by database is for the latency of one instance'; END IF;
  RETURN QUERY EXECUTE format(
    'SELECT s.iid, s.db, CASE WHEN GROUPING(s.bkt) = 0 THEN s.bkt AT TIME ZONE $5 END, percentile_cont($6) WITHIN GROUP (ORDER BY s.v), count(*)::int
       FROM (SELECT s0.iid, s0.db, s0.v, date_trunc(%L, s0.at AT TIME ZONE $5) AS bkt
               FROM (%s) s0 (iid, db, at, v)
              WHERE $7 IS NULL OR extract(hour FROM s0.at AT TIME ZONE $5) = $7) s
      GROUP BY GROUPING SETS ((s.iid, s.db, s.bkt), (s.iid, s.db))', p_bucket, v_src)
    USING p_ids, p_from, p_to, p_by, p_tz, v_frac, p_hour;
END $$;
COMMENT ON FUNCTION pgvigil.trend_series(text, int[], timestamptz, timestamptz, text, text, int, text, text) IS
  'B20-1: the Trend report''s reader over raw samples of both engines (0273''s header says each metric''s cells).';

SELECT pgvigil.apply_roles();
