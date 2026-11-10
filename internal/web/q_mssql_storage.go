package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The SQL Server storage and row versions API (migration 0067): GET /api/mssql/storage is one SQL Server instance's
// Storage and Database files tabs (the volumes, each database's size with its growth over a chosen number of days,
// every file, the size lines), GET /api/mssql/rowversions its Row versions tab (the tempdb version store over the
// range, the holder, the store per database, the persistent version store). Every query reads the slice's own
// tables and views only; a PostgreSQL instance has no row in them and gets empty parts.

// storageDays are the windows the Storage tab's selector offers.
var storageDays = map[int]bool{7: true, 30: true, 90: true, 180: true, 365: true}

// sqlMSSQLVolumes: each volume now, and how much its used space grew over the window ($2 days).
const sqlMSSQLVolumes = `
SELECT v.volume, v.logical_name, v.file_system, v.total_bytes, v.free_bytes, v.total_bytes - v.free_bytes AS used_bytes,
       round(100.0 * v.free_bytes / nullif(v.total_bytes, 0), 1) AS free_pct, v.files, v.snapshot_at,
       w.first_at, (v.total_bytes - v.free_bytes) - w.first_used AS grown_bytes,
       CASE WHEN v.snapshot_at > w.first_at
            THEN round(((v.total_bytes - v.free_bytes) - w.first_used) / greatest(extract(epoch FROM v.snapshot_at - w.first_at) / 86400.0, 1 / 24.0)) END AS per_day
  FROM pgvigil.mssql_volumes v
  LEFT JOIN LATERAL (SELECT s.snapshot_at AS first_at, s.total_bytes - s.free_bytes AS first_used
                       FROM pgvigil.mssql_volume_sample s
                      WHERE s.instance_id = v.instance_id AND s.volume = v.volume AND s.snapshot_at > now() - make_interval(days => $2)
                      ORDER BY s.snapshot_at LIMIT 1) w ON true
 WHERE v.instance_id = $1 AND v.is_present
 ORDER BY free_pct NULLS LAST, v.volume`

// sqlMSSQLDatabases: each database now (data, log, the space used inside the files where it was read) and its
// growth over the window: the size now minus the oldest size the window holds.
const sqlMSSQLDatabases = `
WITH cur AS (
  SELECT f.database_name, max(f.database_state) AS database_state,
         coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc <> 'LOG'), 0) AS data_bytes,
         coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'LOG'), 0) AS log_bytes,
         coalesce(sum(f.size_bytes), 0) AS size_bytes,
         CASE WHEN bool_and(f.used_read) THEN sum(f.used_bytes) END AS used_bytes,
         bool_and(f.used_read) AS used_read,
         min(f.used_note) FILTER (WHERE NOT f.used_read) AS used_note,
         count(*) AS files, max(f.snapshot_at) AS snapshot_at
    FROM pgvigil.mssql_files f
   WHERE f.instance_id = $1 AND f.is_present
   GROUP BY f.database_name)
SELECT cur.*, w.first_at, w.first_bytes, cur.size_bytes - w.first_bytes AS grown_bytes,
       CASE WHEN cur.snapshot_at > w.first_at
            THEN round((cur.size_bytes - w.first_bytes) / greatest(extract(epoch FROM cur.snapshot_at - w.first_at) / 86400.0, 1 / 24.0)) END AS per_day
  FROM cur
  LEFT JOIN LATERAL (SELECT s.snapshot_at AS first_at, s.data_bytes + s.log_bytes AS first_bytes
                       FROM pgvigil.mssql_database_size s
                      WHERE s.instance_id = $1 AND s.database_name = cur.database_name AND s.snapshot_at > now() - make_interval(days => $2)
                      ORDER BY s.snapshot_at LIMIT 1) w ON true
 ORDER BY cur.size_bytes DESC, cur.database_name`

// sqlMSSQLFiles: every file the server lists, one database's when $2 names it.
const sqlMSSQLFiles = `
SELECT f.database_name, f.database_state, f.file_id, f.file_name, f.type_desc, f.filegroup, f.physical_name, f.state_desc,
       f.size_bytes, f.used_bytes, f.size_bytes - f.used_bytes AS free_in_file_bytes, f.used_read, f.used_note,
       f.max_size_bytes, f.growth_bytes, f.growth_pct, f.volume, f.previous_size_bytes, f.size_changed_at, f.snapshot_at
  FROM pgvigil.mssql_files f
 WHERE f.instance_id = $1 AND f.is_present AND ($2::text IS NULL OR f.database_name = $2)
 ORDER BY f.database_name, CASE f.type_desc WHEN 'ROWS' THEN 1 WHEN 'LOG' THEN 3 ELSE 2 END, f.file_id`

// sqlMSSQLSizeSeries: the sizes of the eight largest databases over the window, the largest per $3-second bucket.
const sqlMSSQLSizeSeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $3) * $3) AS snapshot_at, s.database_name,
       max(s.data_bytes + s.log_bytes) AS size_bytes
  FROM pgvigil.mssql_database_size s
 WHERE s.instance_id = $1 AND s.snapshot_at > now() - make_interval(days => $2)
   AND s.database_name IN (SELECT f.database_name FROM pgvigil.mssql_files f WHERE f.instance_id = $1 AND f.is_present
                            GROUP BY f.database_name ORDER BY sum(f.size_bytes) DESC NULLS LAST, f.database_name LIMIT 8)
 GROUP BY 1, 2 ORDER BY 1, 2`

const sqlMSSQLStorageChecks = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_storage_findings
 WHERE instance_id = $1 AND check_name NOT LIKE '%version store%'
 ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, check_name, object`

// MSSQLStorage is GET /api/mssql/storage?instance=N&days=30[&db=name][&part=...]: the Storage and Database files tabs.
func (s *Server) MSSQLStorage(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	days := 30
	if v := r.URL.Query().Get("days"); v != "" {
		if days, err = strconv.Atoi(v); err != nil || !storageDays[days] {
			writeErr(w, http.StatusBadRequest, errors.New("days must be one of 7, 30, 90, 180, 365"))
			return
		}
	}
	var db any
	if v := r.URL.Query().Get("db"); v != "" {
		db = v
	}
	bucket := days * 86400 / 300
	if bucket < 3600 {
		bucket = 3600
	}
	s.multiPart(w, r, []part{
		{"volumes", sqlMSSQLVolumes, []any{id, days}},
		{"databases", sqlMSSQLDatabases, []any{id, days}},
		{"files", sqlMSSQLFiles, []any{id, db}},
		{"series", sqlMSSQLSizeSeries, []any{id, days, bucket}},
		{"checks", sqlMSSQLStorageChecks, []any{id}},
	})
}

// sqlMSSQLVersionLatest is the newest read: the store, the rates and the holder.
const sqlMSSQLVersionLatest = `
SELECT snapshot_at, store_bytes, reserved_bytes, tempdb_data_bytes, round(100.0 * reserved_bytes / nullif(tempdb_data_bytes, 0), 1) AS tempdb_pct,
       generation_kb_s, cleanup_kb_s, snapshot_tx_count, holder_session_id, holder_login, holder_host, holder_program, holder_database,
       holder_is_snapshot, holder_started_at, holder_elapsed_s, holder_statement
  FROM pgvigil.mssql_versionstore_latest WHERE instance_id = $1`

// sqlMSSQLVersionSeries: the store's size and the two rates over the window, per $4-second bucket.
const sqlMSSQLVersionSeries = `
SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at,
       max(s.reserved_bytes) AS reserved_bytes, max(s.store_bytes) AS store_bytes, max(s.tempdb_data_bytes) AS tempdb_data_bytes,
       round(avg(s.generation_kb_s), 3) AS generation_kb_s, round(avg(s.cleanup_kb_s), 3) AS cleanup_kb_s,
       max(s.holder_elapsed_s) AS holder_elapsed_s
  FROM pgvigil.mssql_versionstore_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlMSSQLVersionHolders: every holder seen in the window, the longest held first.
const sqlMSSQLVersionHolders = `
SELECT s.holder_session_id AS session_id, s.holder_login AS login_name, s.holder_host AS host_name, s.holder_program AS program_name,
       s.holder_database AS database_name, bool_or(s.holder_is_snapshot) AS is_snapshot, s.holder_started_at AS started_at,
       max(s.holder_elapsed_s) AS elapsed_s, min(s.snapshot_at) AS first_seen, max(s.snapshot_at) AS last_seen, count(*) AS reads,
       (array_agg(s.holder_statement ORDER BY s.snapshot_at DESC))[1] AS statement
  FROM pgvigil.mssql_versionstore_sample s
 WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3 AND s.holder_session_id IS NOT NULL
 GROUP BY s.holder_session_id, s.holder_login, s.holder_host, s.holder_program, s.holder_database, s.holder_started_at
 ORDER BY max(s.holder_elapsed_s) DESC NULLS LAST, max(s.snapshot_at) DESC
 LIMIT 50`

const sqlMSSQLVersionChecks = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_storage_findings
 WHERE instance_id = $1 AND check_name LIKE '%version store%'
 ORDER BY CASE severity WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, check_name, object`

// MSSQLRowVersions is GET /api/mssql/rowversions?instance=N&from=&to=[&part=...]: the Row versions tab.
func (s *Server) MSSQLRowVersions(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	bucket := int(to.Sub(from).Seconds()) / 600
	if bucket < 60 {
		bucket = 60
	}
	s.multiPart(w, r, []part{
		{"latest", sqlMSSQLVersionLatest, []any{id}},
		{"series", sqlMSSQLVersionSeries, []any{id, from, to, bucket}},
		{"holders", sqlMSSQLVersionHolders, []any{id, from, to}},
		{"databases", `SELECT database_name, reserved_bytes, snapshot_at FROM pgvigil.mssql_versionstore_db WHERE instance_id = $1 ORDER BY reserved_bytes DESC NULLS LAST, database_name`, []any{id}},
		{"pvs", `SELECT database_name, adr_on, pvs_bytes, online_index_bytes, aborted_tx_count, oldest_active_tx_id, oldest_aborted_tx_id, oldest_tx_session_id, oldest_tx_started_at, snapshot_at
		           FROM pgvigil.mssql_pvs WHERE instance_id = $1 ORDER BY pvs_bytes DESC NULLS LAST, database_name`, []any{id}},
		{"checks", sqlMSSQLVersionChecks, []any{id}},
	})
}
