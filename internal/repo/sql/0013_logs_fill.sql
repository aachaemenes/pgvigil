-- 0013_logs_fill: an entry read first without its DETAIL / STATEMENT lines (a delivery or a batch cut
-- between them) and again whole keeps one row: the event key no longer depends on those lines, and a
-- later read with longer statement or detail text fills the stored row in.

CREATE OR REPLACE FUNCTION pgvigil.import_logs(p_instance_id int, p_snapshot_at timestamptz, p_payload jsonb)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  m timestamptz;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('pgvigil.import_logs'), p_instance_id);
  FOR m IN SELECT DISTINCT date_trunc('month', (r->>'at')::timestamptz AT TIME ZONE 'UTC') AT TIME ZONE 'UTC'
             FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'event'
  LOOP
    PERFORM pgvigil.ensure_month_partition('log_events', m);
  END LOOP;

  CREATE TEMP TABLE pgv_log_in ON COMMIT DROP AS
  SELECT DISTINCT ON (r->>'at', r->>'event_key')
         (r->>'at')::timestamptz AS at, r->>'kind_of' AS kind, (r->>'pid')::int AS pid, r->>'client' AS client,
         r->>'usename' AS usename, r->>'datname' AS datname, (r->>'duration_ms')::float8 AS duration_ms,
         r->>'statement' AS statement, r->>'detail' AS detail, r->>'source' AS source, r->>'event_key' AS event_key
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'event'
   ORDER BY r->>'at', r->>'event_key', length(coalesce(r->>'statement', '') || coalesce(r->>'detail', '')) DESC;

  UPDATE pgvigil.log_events e
     SET statement = CASE WHEN length(coalesce(i.statement, '')) > length(coalesce(e.statement, '')) THEN i.statement ELSE e.statement END,
         detail    = CASE WHEN length(coalesce(i.detail, ''))    > length(coalesce(e.detail, ''))    THEN i.detail    ELSE e.detail END
    FROM pgv_log_in i
   WHERE e.instance_id = p_instance_id AND e.snapshot_at = i.at AND e.event_key = i.event_key
     AND (length(coalesce(i.statement, '')) > length(coalesce(e.statement, ''))
       OR length(coalesce(i.detail, ''))    > length(coalesce(e.detail, '')));

  INSERT INTO pgvigil.log_events (instance_id, snapshot_at, kind, pid, client, usename, datname, duration_ms, statement, detail, source, event_key)
  SELECT p_instance_id, i.at, i.kind, i.pid, i.client, i.usename, i.datname, i.duration_ms, i.statement, i.detail, i.source, i.event_key
    FROM pgv_log_in i
   WHERE NOT EXISTS (SELECT 1 FROM pgvigil.log_events e
                      WHERE e.instance_id = p_instance_id AND e.snapshot_at = i.at AND e.event_key = i.event_key);
  DROP TABLE pgv_log_in;

  INSERT INTO pgvigil.log_cursor AS c (instance_id, source, read_to)
  SELECT p_instance_id, r->>'source', (r->>'read_to')::timestamptz
    FROM jsonb_array_elements(p_payload) r WHERE r->>'kind' = 'cursor'
  ON CONFLICT (instance_id, source) DO UPDATE SET read_to = greatest(c.read_to, EXCLUDED.read_to), updated_at = now();
END $$;

SELECT pgvigil.apply_roles();
