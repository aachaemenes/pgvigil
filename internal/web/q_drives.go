package web

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// The Storage folder in DBA Dash's shape (task 176; DBA Dash's Storage > Drives | DB Space | Files | Drive
// Performance, Drives/DrivesView.cs, DBFiles/SpaceTracking.cs, DBFiles/DBFilesView.cs), on both engines. Routes,
// wired in Handler:
//
//	GET  /api/drives       s.Drives               the drives of the scope with the threshold in force and the status
//	POST /api/drives/thresholds  s.DriveThresholdWrite  one Configure attempt through pgvigil.import_drive_threshold
//	GET  /api/dbspace      s.DBSpace              allocated / used per instance (a folder) or per database (an instance)
//	GET  /api/dbfiles      s.DBFiles              the files: SQL Server's data and log files, PostgreSQL's WAL and tablespaces
//	GET  /api/driveperf    s.DrivePerf            one instance's latency and throughput per drive over the window
//
// The scope of the three folder reads: instance=N (one instance), instances=1,2,3 (a tag folder's), or neither (the
// fleet); instances=0 (an empty folder) gives no row.

// driveStatuses are the statuses the status filter takes (DBA Dash's Critical, Warning, OK, plus pgvigil's unknown:
// a drive whose size the door does not say).
var driveStatuses = map[string]bool{"critical": true, "warning": true, "ok": true, "unknown": true}

// storageScope reads instance= or instances=: id 0 and ids nil = the fleet.
func storageScope(r *http.Request) (id int, ids []int32, err error) {
	q := r.URL.Query()
	if v := q.Get("instance"); v != "" {
		if id, err = strconv.Atoi(v); err != nil || id <= 0 {
			return 0, nil, errors.New("instance must be a positive instance_id")
		}
		if q.Get("instances") != "" {
			return 0, nil, errors.New("give instance or instances, not both")
		}
		return id, nil, nil
	}
	if v := q.Get("instances"); v != "" {
		for _, f := range strings.Split(v, ",") {
			n, perr := strconv.ParseInt(strings.TrimSpace(f), 10, 32)
			if perr != nil || n < 0 || len(ids) >= tableSizeMaxInstances {
				return 0, nil, errors.New("instances must be instance ids separated by commas (2,000 at most)")
			}
			ids = append(ids, int32(n))
		}
	}
	return 0, ids, nil
}

// statusFilter reads status=: 'all' or empty = every status (nil), else a comma list of driveStatuses.
func statusFilter(r *http.Request) ([]string, error) {
	v := r.URL.Query().Get("status")
	if v == "" || v == "all" {
		return nil, nil
	}
	var out []string
	for _, f := range strings.Split(v, ",") {
		f = strings.TrimSpace(f)
		if !driveStatuses[f] {
			return nil, errors.New("status must be all, or critical, warning, ok and unknown separated by commas")
		}
		out = append(out, f)
	}
	return out, nil
}

// $1 the instance (0 = any), $2 the folder's instances (NULL = any), $3 the statuses (NULL = any)
const sqlDrives = `
SELECT d.instance_id, d.instance, d.engine, d.platform, d.drive, d.label, d.source, d.total_bytes, d.used_bytes, d.free_bytes,
       d.free_pct, d.holds_data, d.files, d.snapshot_at, round(extract(epoch FROM now() - d.snapshot_at))::bigint AS age_secs,
       d.warn_pct, d.crit_pct, d.threshold_level, d.threshold_tag, d.threshold_id, d.status
  FROM pgvigil.drives_now d
 WHERE ($1::int = 0 OR d.instance_id = $1) AND ($2::int[] IS NULL OR d.instance_id = ANY ($2)) AND ($3::text[] IS NULL OR d.status = ANY ($3))
 ORDER BY CASE d.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'unknown' THEN 3 ELSE 4 END, d.free_pct NULLS LAST, d.instance, d.drive`

// the scope's drives by status, whatever the filter: the toolbar's counts and the empty state's words
const sqlDriveCounts = `
SELECT count(*) AS drives, count(*) FILTER (WHERE d.status = 'critical') AS critical, count(*) FILTER (WHERE d.status = 'warning') AS warning,
       count(*) FILTER (WHERE d.status = 'ok') AS ok, count(*) FILTER (WHERE d.status = 'unknown') AS unknown,
       count(DISTINCT d.instance_id) AS instances, max(d.snapshot_at) AS newest_at
  FROM pgvigil.drives_now d
 WHERE ($1::int = 0 OR d.instance_id = $1) AND ($2::int[] IS NULL OR d.instance_id = ANY ($2))`

// the live thresholds (every level: the Configure dialog says what each level holds) and the tags to set one on
const sqlDriveThresholds = `
SELECT t.threshold_id, t.level, t.instance_id, i.name AS instance, t.tag, t.drive, t.warn_pct, t.crit_pct, t.created_by, t.created_at
  FROM pgvigil.drive_thresholds t LEFT JOIN pgvigil.instances i USING (instance_id)
 WHERE t.ended_at IS NULL
 ORDER BY CASE t.level WHEN 'root' THEN 1 WHEN 'tag' THEN 2 WHEN 'instance' THEN 3 ELSE 4 END, t.tag, i.name, t.drive`

const sqlDriveTags = `
SELECT DISTINCT t.tag FROM pgvigil.instance_tags_merged m JOIN pgvigil.instances i USING (instance_id) CROSS JOIN unnest(m.tags) t(tag)
 WHERE i.is_active ORDER BY 1`

// Drives is GET /api/drives[?instance=N|?instances=..][&status=all|critical,warning][&part=drives|counts|thresholds|tags].
func (s *Server) Drives(w http.ResponseWriter, r *http.Request) {
	id, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	st, err := statusFilter(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	s.multiPart(w, r, []part{
		{"drives", sqlDrives, []any{id, ids, st}},
		{"counts", sqlDriveCounts, []any{id, ids}},
		{"thresholds", sqlDriveThresholds, nil},
		{"tags", sqlDriveTags, nil},
	})
}

// DriveThresholdWrite is POST /api/drives/thresholds: one Configure attempt (set a level's warning and critical per
// cent free, or make the level inherit). The function checks every value and answers done or refused; a refused
// attempt is 409 with its reason. The same doors as the other threshold writes: the X-Pgvigil header, a signed-in
// user, the actions configuration's audit login.
func (s *Server) DriveThresholdWrite(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get(loginHeader) == "" {
		writeErr(w, http.StatusForbidden, errors.New("the X-Pgvigil header is required"))
		return
	}
	if why := s.ackOff(); why != "" {
		writeErr(w, http.StatusForbidden, errors.New(strings.Replace(why, "acknowledgements", "thresholds", 1)))
		return
	}
	user := s.sessionUser(r)
	if user == "" {
		writeErr(w, http.StatusUnauthorized, errors.New("login required"))
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 4097))
	if err != nil || len(raw) > 4096 {
		writeErr(w, http.StatusBadRequest, errors.New("body: unreadable or over 4 KB"))
		return
	}
	if strings.Contains(string(raw), `\u0000`) || strings.ContainsRune(string(raw), 0) {
		writeErr(w, http.StatusBadRequest, errors.New("the request holds a NUL character: nothing was written"))
		return
	}
	var in map[string]any
	if err := json.Unmarshal(raw, &in); err != nil {
		writeErr(w, http.StatusBadRequest, fmt.Errorf("body: %w", err))
		return
	}
	pay := map[string]any{"ui_user": user, "client": clientIP(r)}
	for _, k := range []string{"op", "level", "instance_id", "tag", "drive", "warn", "crit"} {
		if v, ok := in[k]; ok && v != nil {
			if f, isNum := v.(float64); isNum {
				v = strconv.FormatFloat(f, 'f', -1, 64)
			}
			pay[k] = v
		}
	}
	b, _ := json.Marshal(pay)
	var out []byte
	wctx, wcancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer wcancel()
	if err := s.actions.audit.QueryRow(wctx, `SELECT pgvigil.import_drive_threshold($1, $2::jsonb)::text`, time.Now(), string(b)).Scan(&out); err != nil {
		s.log.Error("drive threshold: not written", "user", user, "err", err)
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("not written: %v", err))
		return
	}
	var res struct {
		Outcome     string `json:"outcome"`
		Detail      string `json:"detail"`
		ThresholdID *int64 `json:"threshold_id"`
		Error       string `json:"error,omitempty"` // a refusal's reason, where the UI's post() reads an error
	}
	if err := json.Unmarshal(out, &res); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Errorf("import_drive_threshold answered %q", out))
		return
	}
	s.log.Info("drive threshold: attempt", "op", pay["op"], "level", pay["level"], "user", user, "outcome", res.Outcome, "detail", res.Detail)
	code := http.StatusOK
	if res.Outcome != "done" {
		code = http.StatusConflict
		res.Error = "refused: " + res.Detail
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(res)
}

// sqlDriveHistory: one drive's size, used and free over $3 days per $4-second bucket (the bucket's last read): a
// PostgreSQL host's from host_disk_history, a SQL Server's from mssql_volume_sample. $1 the instance, $2 the drive.
const sqlDriveHistory = `
SELECT DISTINCT ON (1) to_timestamp(floor(extract(epoch FROM h.snapshot_at) / $4) * $4) AS snapshot_at, h.total_bytes, h.used_bytes, h.free_bytes,
       round(100.0 * h.free_bytes / nullif(h.total_bytes, 0), 1) AS free_pct
  FROM (SELECT x.snapshot_at, x.total_bytes, x.used_bytes, x.free_bytes FROM pgvigil.host_disk_history x
         WHERE x.instance_id = $1 AND x.mount_point = $2 AND x.snapshot_at > now() - make_interval(days => $3)
        UNION ALL
        SELECT v.snapshot_at, v.total_bytes, v.total_bytes - v.free_bytes, v.free_bytes FROM pgvigil.mssql_volume_sample v
         WHERE v.instance_id = $1 AND v.volume = $2 AND v.snapshot_at > now() - make_interval(days => $3)) h
 ORDER BY 1, h.snapshot_at DESC`

// DriveHistory is GET /api/drives/history?instance=N&drive=..[&days=30]: DBA Dash's drive History.
func (s *Server) DriveHistory(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	id, err := strconv.Atoi(q.Get("instance"))
	if err != nil || id <= 0 {
		writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
		return
	}
	drive := q.Get("drive")
	if drive == "" || len(drive) > 400 {
		writeErr(w, http.StatusBadRequest, errors.New("drive must name the drive (400 characters at most)"))
		return
	}
	days := 30
	if v := q.Get("days"); v != "" {
		if days, err = strconv.Atoi(v); err != nil || !dbSpaceDays[days] {
			writeErr(w, http.StatusBadRequest, errors.New("days must be 7, 30, 90, 180 or 365"))
			return
		}
	}
	step := int(math.Ceil(float64(days) * 86400 / 300))
	s.multiPart(w, r, []part{{"history", sqlDriveHistory, []any{id, drive, days, step}}})
}

// sqlDBSpaceInstances: per instance of the scope, the space its databases hold now. PostgreSQL: the databases' sizes
// (pg_database_size; a PostgreSQL file holds no unallocated space to read, so used is not given); SQL Server: the
// files' sizes, and the space used inside them where every file's was read.
const sqlDBSpaceInstances = `
SELECT i.instance_id, i.name AS instance, i.engine, x.allocated_bytes, x.used_bytes, x.databases, x.snapshot_at
  FROM pgvigil.instances i
  CROSS JOIN LATERAL (
    SELECT sum(d.size_bytes) AS allocated_bytes, NULL::numeric AS used_bytes, count(*) AS databases, max(d.snapshot_at) AS snapshot_at
      FROM pgvigil.databases d WHERE d.instance_id = i.instance_id AND d.is_present AND i.engine = 'postgres'
    UNION ALL
    SELECT sum(f.size_bytes), CASE WHEN bool_and(f.used_read) THEN sum(f.used_bytes) END, count(DISTINCT f.database_name), max(f.snapshot_at)
      FROM pgvigil.mssql_files f WHERE f.instance_id = i.instance_id AND f.is_present AND i.engine = 'sqlserver') x
 WHERE i.is_active AND x.databases > 0 AND ($1::int[] IS NULL OR i.instance_id = ANY ($1))
 ORDER BY x.allocated_bytes DESC NULLS LAST, i.name`

// sqlDBSpaceDatabases: one instance's databases now. $1 the instance.
const sqlDBSpaceDatabases = `
SELECT d.datname AS database, d.size_bytes AS allocated_bytes, NULL::bigint AS used_bytes, NULL::bigint AS data_bytes, NULL::bigint AS log_bytes, d.snapshot_at
  FROM pgvigil.databases d JOIN pgvigil.instances i USING (instance_id)
 WHERE d.instance_id = $1 AND d.is_present AND i.engine = 'postgres'
UNION ALL
SELECT f.database_name, sum(f.size_bytes), CASE WHEN bool_and(f.used_read) THEN sum(f.used_bytes) END,
       coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc <> 'LOG'), 0), coalesce(sum(f.size_bytes) FILTER (WHERE f.type_desc = 'LOG'), 0), max(f.snapshot_at)
  FROM pgvigil.mssql_files f JOIN pgvigil.instances i USING (instance_id)
 WHERE f.instance_id = $1 AND f.is_present AND i.engine = 'sqlserver'
 GROUP BY f.database_name
 ORDER BY 2 DESC NULLS LAST, 1`

// sqlDBSpaceHistory: one instance's space over $2 days, per $3-second bucket: the total of every database (each
// database's largest read in the bucket, summed) - DBA Dash's DB Space History. $1 the instance.
const sqlDBSpaceHistory = `
SELECT b.at AS snapshot_at, sum(b.size_bytes) AS allocated_bytes,
       CASE WHEN count(b.used_bytes) = count(*) THEN sum(b.used_bytes) END AS used_bytes, count(*) AS databases
  FROM (SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $3) * $3) AS at, s.datname AS db, max(s.size_bytes) AS size_bytes, NULL::bigint AS used_bytes
          FROM pgvigil.database_sizes s
         WHERE s.instance_id = $1 AND s.snapshot_at > now() - make_interval(days => $2)
         GROUP BY 1, 2
        UNION ALL
        SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $3) * $3), s.database_name, max(s.data_bytes + s.log_bytes),
               max(s.data_used_bytes + s.log_used_bytes)
          FROM pgvigil.mssql_database_size s
         WHERE s.instance_id = $1 AND s.snapshot_at > now() - make_interval(days => $2)
         GROUP BY 1, 2) b
 GROUP BY 1 ORDER BY 1`

// dbSpaceDays are the History windows offered (days).
var dbSpaceDays = map[int]bool{7: true, 30: true, 90: true, 180: true, 365: true}

// DBSpace is GET /api/dbspace[?instance=N|?instances=..][&days=30]: DBA Dash's DB Space. A folder: one row per
// instance (instances); an instance: its databases (databases) and its total over the days asked (history).
func (s *Server) DBSpace(w http.ResponseWriter, r *http.Request) {
	id, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	days := 30
	if v := r.URL.Query().Get("days"); v != "" {
		if days, err = strconv.Atoi(v); err != nil || !dbSpaceDays[days] {
			writeErr(w, http.StatusBadRequest, errors.New("days must be 7, 30, 90, 180 or 365"))
			return
		}
	}
	if id == 0 {
		s.multiPart(w, r, []part{{"instances", sqlDBSpaceInstances, []any{ids}}})
		return
	}
	step := int(math.Ceil(float64(days) * 86400 / 300))
	s.multiPart(w, r, []part{
		{"instances", sqlDBSpaceInstances, []any{[]int32{int32(id)}}},
		{"databases", sqlDBSpaceDatabases, []any{id}},
		{"history", sqlDBSpaceHistory, []any{id, days, step}},
	})
}

// sqlDBFiles: the files of the scope. SQL Server: every data and log file with its size, the space used inside it
// where read, its maximum and growth, and the status 0067's rule gives (critical at its max, warning within one growth
// of it); PostgreSQL: the WAL directory and each tablespace the storage collection read (no maximum: status ok). A
// PostgreSQL row's drive (task 176b: a drive's Files link lists the files on that drive, as DBA Dash's does): a
// tablespace with a location, the host volume one of whose mount points is the longest prefix of it; a row without a
// location (pg_wal, pg_default, pg_global: inside the data directory) the volume that holds the data directory
// (host_disks.holds_data; a pg_wal symlinked elsewhere is not read). $1 the instance (0 = any), $2 the folder's instances, $3 the statuses,
// $4 the drive (empty = every drive).
const sqlDBFilesFrom = `
WITH f AS (
  SELECT f.instance_id, f.database_name AS database, coalesce(f.file_name, f.file_id::text) AS file, f.type_desc AS type, f.filegroup,
         f.physical_name AS location, f.size_bytes, CASE WHEN f.used_read THEN f.used_bytes END AS used_bytes,
         CASE WHEN f.used_read THEN f.size_bytes - f.used_bytes END AS free_bytes,
         CASE WHEN f.used_read THEN round(100.0 * (f.size_bytes - f.used_bytes) / nullif(f.size_bytes, 0), 1) END AS free_pct,
         f.max_size_bytes, CASE WHEN f.growth_pct > 0 THEN f.growth_pct || ' %' ELSE pg_size_pretty(f.growth_bytes) END AS growth,
         f.volume AS drive, f.snapshot_at,
         CASE WHEN f.max_size_bytes IS NOT NULL AND f.size_bytes >= f.max_size_bytes AND (coalesce(f.growth_bytes, 0) > 0 OR coalesce(f.growth_pct, 0) > 0) THEN 'critical'
              WHEN f.max_size_bytes IS NOT NULL AND (coalesce(f.growth_bytes, 0) > 0 OR coalesce(f.growth_pct, 0) > 0)
                   AND f.size_bytes + CASE WHEN f.growth_pct > 0 THEN f.size_bytes * f.growth_pct / 100 ELSE f.growth_bytes END >= f.max_size_bytes THEN 'warning'
              ELSE 'ok' END AS status
    FROM pgvigil.mssql_files f
   WHERE f.is_present
  UNION ALL
  SELECT s.instance_id, NULL, s.name, upper(s.kind), NULL, s.location, s.size_bytes, NULL, NULL, NULL, NULL, NULL,
         CASE WHEN s.location IS NULL
              THEN (SELECT h.mount_point FROM pgvigil.host_disks h WHERE h.instance_id = s.instance_id AND h.is_present AND h.holds_data
                     ORDER BY h.mount_point LIMIT 1)
              ELSE (SELECT h.mount_point FROM pgvigil.host_disks h CROSS JOIN LATERAL unnest(coalesce(h.mounts, '{}'::text[]) || h.mount_point) m
                     WHERE h.instance_id = s.instance_id AND h.is_present
                       AND (s.location = m OR left(s.location, length(rtrim(m, '/')) + 1) = rtrim(m, '/') || '/')
                     ORDER BY length(m) DESC LIMIT 1) END,
         s.snapshot_at, 'ok'
    FROM pgvigil.storage_state s
   WHERE s.is_present AND s.kind IN ('wal', 'tablespace')
)`

const sqlDBFiles = sqlDBFilesFrom + `
SELECT f.instance_id, i.name AS instance, i.engine, f.database, f.file, f.type, f.filegroup, f.location, f.size_bytes, f.used_bytes, f.free_bytes,
       f.free_pct, f.max_size_bytes, f.growth, f.drive, f.snapshot_at, f.status
  FROM f JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.is_active
 WHERE ($1::int = 0 OR f.instance_id = $1) AND ($2::int[] IS NULL OR f.instance_id = ANY ($2)) AND ($3::text[] IS NULL OR f.status = ANY ($3))
   AND ($4::text = '' OR f.drive = $4)
 ORDER BY CASE f.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 ELSE 3 END, i.name, f.database NULLS FIRST, f.size_bytes DESC NULLS LAST`

// sqlDBFileCounts: the files of the scope and drive whatever the status filter.
const sqlDBFileCounts = sqlDBFilesFrom + `
SELECT count(*) AS files, coalesce(sum(f.size_bytes), 0) AS size_bytes
  FROM f JOIN pgvigil.instances i ON i.instance_id = f.instance_id AND i.is_active
 WHERE ($1::int = 0 OR f.instance_id = $1) AND ($2::int[] IS NULL OR f.instance_id = ANY ($2)) AND ($3::text = '' OR f.drive = $3)`

// DBFiles is GET /api/dbfiles[?instance=N|?instances=..][&status=..][&drive=..]: DBA Dash's Files.
func (s *Server) DBFiles(w http.ResponseWriter, r *http.Request) {
	id, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	st, err := statusFilter(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	drive := r.URL.Query().Get("drive")
	if len(drive) > 400 {
		writeErr(w, http.StatusBadRequest, errors.New("drive is 400 characters at most"))
		return
	}
	s.multiPart(w, r, []part{
		{"files", sqlDBFiles, []any{id, ids, st, drive}},
		{"counts", sqlDBFileCounts, []any{id, ids, drive}},
	})
}

// sqlDrivePerfMSSQL: SQL Server, per drive per $4-second step: the files' read and write latency (stall over
// operations) and throughput (bytes over each read's seconds), a file put on its drive by mssql_files.volume.
const sqlDrivePerfMSSQL = `
SELECT to_timestamp(floor(extract(epoch FROM p.snapshot_at) / $4) * $4) AS snapshot_at, p.drive,
       round(sum(p.read_stall_ms)::numeric / nullif(sum(p.reads), 0), 2) AS read_ms,
       round(sum(p.write_stall_ms)::numeric / nullif(sum(p.writes), 0), 2) AS write_ms,
       round((sum(p.read_bytes) / nullif(sum(p.secs), 0) / 1048576.0)::numeric, 3) AS read_mb_s,
       round((sum(p.write_bytes) / nullif(sum(p.secs), 0) / 1048576.0)::numeric, 3) AS write_mb_s,
       round((sum(p.reads + p.writes) / nullif(sum(p.secs), 0))::numeric, 1) AS iops
  FROM (SELECT f.snapshot_at, coalesce(m.volume, 'drive not read') AS drive, sum(f.reads) AS reads, sum(f.read_stall_ms) AS read_stall_ms,
               sum(f.writes) AS writes, sum(f.write_stall_ms) AS write_stall_ms, sum(f.read_bytes) AS read_bytes, sum(f.write_bytes) AS write_bytes,
               max(f.interval_secs) AS secs
          FROM pgvigil.mssql_fileio_sample f
          LEFT JOIN pgvigil.mssql_files m ON m.instance_id = f.instance_id AND m.database_id = f.database_id AND m.file_id = f.file_id
         WHERE f.instance_id = $1 AND f.snapshot_at > $2 AND f.snapshot_at <= $3
         GROUP BY 1, 2) p
 GROUP BY 1, 2 ORDER BY 1, 2`

// sqlDrivePerfPG: PostgreSQL, per device per $4-second step from system_stats' device counters (an on-prem host
// with system_stats; RDS and Aurora have no device read).
const sqlDrivePerfPG = `
SELECT to_timestamp(floor(extract(epoch FROM h.snapshot_at) / $4) * $4) AS snapshot_at, h.device AS drive,
       round(avg(h.read_ms_per_op), 2) AS read_ms, round(avg(h.write_ms_per_op), 2) AS write_ms,
       round(avg(h.read_bytes_s) / 1048576.0, 3) AS read_mb_s, round(avg(h.write_bytes_s) / 1048576.0, 3) AS write_mb_s,
       round(avg(h.reads_s + h.writes_s), 1) AS iops
  FROM pgvigil.host_io_rate($1, $2, $3) h
 GROUP BY 1, 2 ORDER BY 1, 2`

// DrivePerf is GET /api/driveperf?instance=N[&from=&to=]: DBA Dash's Drive Performance. series: per drive per step;
// meta: the engine and the step.
func (s *Server) DrivePerf(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	step := int(to.Sub(from).Seconds()) / 120
	if step < 60 {
		step = 60
	}
	var engine string
	if err := s.pool.QueryRow(r.Context(), `SELECT engine FROM pgvigil.instances WHERE instance_id = $1`, id).Scan(&engine); err != nil {
		engine = "postgres" // an unknown instance: the PostgreSQL read, empty
	}
	q := sqlDrivePerfPG
	if engine == "sqlserver" {
		q = sqlDrivePerfMSSQL
	}
	s.multiPart(w, r, []part{
		{"series", q, []any{id, from, to, step}},
		{"meta", `SELECT $1::text AS engine, $2::int AS step_secs`, []any{engine, step}},
	})
}
