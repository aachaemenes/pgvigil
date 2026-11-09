package web

import "net/http"

// The storage API (task 45): one instance's Storage tab and the fleet Storage root. The routes are wired in
// Handler (GET /api/storage -> s.Storage, GET /api/storage/fleet -> s.StorageFleet); the overview check below
// feeds the Summary column Storage (check_group 'storage').

func init() {
	overviewChecks = append(overviewChecks, struct{ name, sql string }{"storage", `
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.storage_checks c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active`})
}

// sqlStorageVolumes is one instance's volumes with growth and days until full, the soonest first.
const sqlStorageVolumes = `
SELECT volume, kind, total_bytes, used_bytes, free_bytes, free_pct, capacity_bytes, headroom_bytes, headroom_pct, autoscaling, at_maximum, holds_data,
       growth_7d_per_day, growth_30d_per_day, days_until_full_7, days_until_full_30, days_until_full, snapshot_at
  FROM pgvigil.volume_forecast($1)
 ORDER BY days_until_full NULLS LAST, free_pct NULLS LAST, volume`

// sqlStorageObjects is what the storage collection read: the WAL directory, the tablespaces, the RDS and
// Aurora volumes.
const sqlStorageObjects = `
SELECT kind, name, location, size_bytes, files, allocated_bytes, max_allocated_bytes, autoscaling, at_maximum, storage_type, iops, throughput,
       class, limit_bytes, round(100.0 * size_bytes / nullif(limit_bytes, 0), 3) AS limit_pct, metrics_at, snapshot_at
  FROM pgvigil.storage_state
 WHERE instance_id = $1 AND is_present
 ORDER BY CASE kind WHEN 'rds' THEN 1 WHEN 'aurora_volume' THEN 2 WHEN 'wal' THEN 3 ELSE 4 END, size_bytes DESC NULLS LAST, name`

// sqlStorageSeries is the WAL directory and each tablespace over the window, the largest per $4-second bucket.
const sqlStorageSeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       max(s.size_bytes) FILTER (WHERE s.kind = 'wal') AS wal_bytes,
       sum(s.size_bytes) FILTER (WHERE s.kind = 'tablespace') AS tablespace_bytes,
       max(s.size_bytes) FILTER (WHERE s.kind = 'aurora_volume') AS aurora_volume_bytes
  FROM pgvigil.storage_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlStorageTemp is the temporary file volume of the last 24 hours and 7 days (dbstats, summed over databases).
const sqlStorageTemp = `
SELECT (SELECT sum(temp_bytes) FROM pgvigil.dbstats_rate($1, now() - interval '1 day', now()) WHERE NOT reset) AS temp_bytes_24h,
       (SELECT sum(temp_files) FROM pgvigil.dbstats_rate($1, now() - interval '1 day', now()) WHERE NOT reset) AS temp_files_24h,
       (SELECT sum(temp_bytes) FROM pgvigil.dbstats_rate($1, now() - interval '7 days', now()) WHERE NOT reset) AS temp_bytes_7d`

// sqlStorageRepo is the repository's own size: the database and the pgvigil schema.
const sqlStorageRepo = `
SELECT pg_database_size(current_database()) AS database_bytes,
       (SELECT sum(pg_total_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'pgvigil' AND c.relkind IN ('r', 'm')) AS schema_bytes,
       (SELECT sum(pg_total_relation_size(c.oid)) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'pgvigil' AND c.relkind = 'r' AND c.relispartition
           AND EXISTS (SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid)) AS history_bytes`

// sqlStorageFleet is the fleet's volumes, the soonest full first, then the fullest.
const sqlStorageFleet = `
SELECT instance_id, instance, platform, volume, kind, total_bytes, used_bytes, free_bytes, free_pct, capacity_bytes, headroom_bytes,
       headroom_pct, autoscaling, at_maximum, holds_data, growth_7d_per_day, growth_30d_per_day, days_until_full, snapshot_at
  FROM pgvigil.volume_forecast(NULL)
 ORDER BY days_until_full NULLS LAST, free_pct NULLS LAST, instance, volume`

// Storage is one instance's Storage tab.
func (s *Server) Storage(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	bucket := int(to.Sub(from).Seconds()) / 600
	if bucket < 60 {
		bucket = 60
	}
	s.multi(w, r, []part{
		{"volumes", sqlStorageVolumes, []any{id}},
		{"objects", sqlStorageObjects, []any{id}},
		{"databases", `SELECT * FROM pgvigil.database_growth($1)`, []any{id}},
		{"tables", `SELECT * FROM pgvigil.table_growth($1, 20)`, []any{id}},
		{"series", sqlStorageSeries, []any{id, from, to, bucket}},
		{"temp", sqlStorageTemp, []any{id}},
		{"checks", `SELECT severity, check_name, object, at, detail FROM pgvigil.storage_checks WHERE instance_id = $1 ORDER BY severity, check_name, object`, []any{id}},
	})
}

// StorageFleet is the fleet Storage root: every volume, the soonest full first, and the repository's own size.
func (s *Server) StorageFleet(w http.ResponseWriter, r *http.Request) {
	s.multi(w, r, []part{
		{"volumes", sqlStorageFleet, nil},
		{"repository", sqlStorageRepo, nil},
	})
}
