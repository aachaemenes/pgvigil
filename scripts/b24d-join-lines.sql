-- B24d (migration 0196, above 0190): the lines for the next join's own file 0300_join_release3.sql (the 03:3x rule).
-- Not a migration of its own; the record of what the join places.
--
-- metrics_sample_times (0196's): re-created WHOLE in 0300 with an arm for each family the joined metric_catalog
-- carries beyond 0085's (the j16 review's A15): 0196's CASE names nine families and has no ELSE, and its WHERE drops a
-- NULL time, so on the joined store /metrics would give the 'counters', 'xe', 'waits' and 'collection' value series
-- with no pgvigil_sample_timestamp_seconds beside them - a staleness alert on time() - that series never firing for
-- them. Each new arm reads the newest sample of the table its family's points come from, as its points count it:
--   counters   - mssql_counter_read (401's mssql_counter_values reads it; 0124's table)
--   xe         - mssql_attention_reads, a done read while the capture ran (0153's mssql_attention_points: read_done
--                AND state = 'running')
--   waits      - mssql_wait_sample (412's mssql_wait_core_points; 0064's table)
--   collection - collection_health_hour, stamped at the hour's end and only for an hour that has ended (0166's
--                metric_points arm: hour + 1 hour)
-- The guard: internal/repo/metrics_sample_times_test.go (every DISTINCT metric_catalog family has its WHEN arm; the
-- four arms each give their seeded sample's time) - red on the joined store with 0196's body, green with this one.

CREATE OR REPLACE FUNCTION pgvigil.metrics_sample_times(p_ids int[] DEFAULT NULL)
RETURNS TABLE (instance_id int, family text, at timestamptz)
LANGUAGE sql STABLE SET jit = off AS $$
  SELECT i.instance_id, f.family, t.at
    FROM pgvigil.instances i
    CROSS JOIN LATERAL (SELECT DISTINCT c.family FROM pgvigil.metric_catalog c WHERE c.engine IN (i.engine, 'any')) f
    CROSS JOIN LATERAL (SELECT CASE f.family
             WHEN 'sessions'   THEN (SELECT max(x.snapshot_at) FROM pgvigil.activity_summary x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'database'   THEN (SELECT max(x.snapshot_at) FROM pgvigil.dbstats x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'server'     THEN (SELECT max(x.snapshot_at) FROM pgvigil.serverstats x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'io'         THEN (SELECT max(x.snapshot_at) FROM pgvigil.iostats x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'host'       THEN (SELECT max(x.snapshot_at) FROM pgvigil.host_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'requests'   THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_requests_summary x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'cpu'        THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_cpu_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'scheduler'  THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_sched_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'memory'     THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_memory_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'counters'   THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_counter_read x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'xe'         THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_attention_reads x WHERE x.instance_id = i.instance_id AND x.read_done AND x.state = 'running' AND x.snapshot_at <= now())
             WHEN 'waits'      THEN (SELECT max(x.snapshot_at) FROM pgvigil.mssql_wait_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at <= now())
             WHEN 'collection' THEN (SELECT max(x.hour) + interval '1 hour' FROM pgvigil.collection_health_hour x WHERE x.instance_id = i.instance_id AND x.hour + interval '1 hour' <= now())
           END AS at) t
   WHERE i.instance_id = ANY (coalesce(p_ids, ARRAY(SELECT x.instance_id FROM pgvigil.instances x WHERE x.is_active)))
     AND t.at IS NOT NULL
$$;
COMMENT ON FUNCTION pgvigil.metrics_sample_times(int[]) IS
  'The newest sample of each metric family of each instance, stale or not, no age bound (pgvigil_sample_timestamp_seconds); one WHEN arm per metric_catalog family (internal/repo/metrics_sample_times_test.go).';
