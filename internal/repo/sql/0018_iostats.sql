-- 0018: pg_stat_io leaves the dbstats collection for its own, iostats, read every 5 minutes by default
-- (its rows were 21.3 of the 25.6 MB an idle instance stored a day at the minute cadence). The import
-- takes the same rows (kind io) into the same partitioned table; import_dbstats keeps its io branch for
-- a collector not yet upgraded and for the demo's generator, so nothing changes shape and nothing is
-- lost across the upgrade. apply_roles (run by migrate after this file) makes it the collector's door.
CREATE OR REPLACE FUNCTION pgvigil.import_iostats(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pgvigil.ensure_month_partition('iostats', p_snapshot_at);
  INSERT INTO pgvigil.iostats (
    instance_id, snapshot_at, backend_type, object, context, stats_reset, reads, read_bytes, read_time, writes, write_bytes,
    write_time, writebacks, writeback_time, extends, extend_bytes, extend_time, op_bytes, hits, evictions, reuses, fsyncs, fsync_time)
  SELECT p_instance_id, p_snapshot_at, r->>'backend_type', r->>'object', r->>'context', (r->>'stats_reset')::timestamptz,
         (r->>'reads')::bigint, (r->>'read_bytes')::numeric, (r->>'read_time')::float8, (r->>'writes')::bigint,
         (r->>'write_bytes')::numeric, (r->>'write_time')::float8, (r->>'writebacks')::bigint, (r->>'writeback_time')::float8,
         (r->>'extends')::bigint, (r->>'extend_bytes')::numeric, (r->>'extend_time')::float8, (r->>'op_bytes')::bigint,
         (r->>'hits')::bigint, (r->>'evictions')::bigint, (r->>'reuses')::bigint, (r->>'fsyncs')::bigint, (r->>'fsync_time')::float8
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'io';
END $$;
