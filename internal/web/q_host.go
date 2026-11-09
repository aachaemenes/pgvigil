package web

import (
	"errors"
	"net/http"
	"strconv"
)

// The host collection's API (task 32): one instance's Host tab and the fleet Disk report. The routes are
// wired in Handler (GET /api/host -> s.Host, GET /api/disks -> s.Disks); the two overview checks below
// feed the Summary columns Host and Disk (check_group 'host' and 'disk').

func init() {
	overviewChecks = append(overviewChecks,
		struct{ name, sql string }{"host", `
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.host_checks c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND c.check_group = 'host'`},
		struct{ name, sql string }{"disk", `
SELECT c.instance_id, c.severity, c.check_name, c.object, c.at, c.detail
  FROM pgvigil.host_checks c JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND c.check_group = 'disk'`},
	)
}

// sqlHostLatest is what the host is and its newest sample.
const sqlHostLatest = `SELECT * FROM pgvigil.host_latest WHERE instance_id = $1`

// sqlHostDisks lists the instance's volumes, present first, the fullest first.
const sqlHostDisks = `
SELECT d.mount_point, d.device, d.fs_type, d.source, d.total_bytes, d.used_bytes, d.free_bytes,
       round(100.0 * d.free_bytes / nullif(d.total_bytes, 0), 1) AS free_pct, d.mounts, d.holds_data, d.snapshot_at, d.is_present
  FROM pgvigil.host_disks d
 WHERE d.instance_id = $1
 ORDER BY d.is_present DESC, round(100.0 * d.free_bytes / nullif(d.total_bytes, 0), 1) NULLS LAST, d.mount_point`

// sqlHostSeries is the CPU, memory, swap, load and connections over the window, averaged (CPU, load) or
// taken at the worst (memory free, swap, connections) per $4-second bucket.
const sqlHostSeries = `
SELECT to_timestamp(floor(extract(epoch FROM h.snapshot_at) / $4) * $4) AS snapshot_at,
       round(avg(h.cpu_pct)::numeric, 2) AS cpu_pct, round(avg(h.cpu_user_pct)::numeric, 2) AS cpu_user_pct,
       round(avg(h.cpu_system_pct)::numeric, 2) AS cpu_system_pct, round(avg(h.cpu_iowait_pct)::numeric, 2) AS cpu_iowait_pct,
       max(h.mem_used) AS mem_used, min(h.mem_free) AS mem_free, max(h.mem_total) AS mem_total, max(h.swap_used) AS swap_used,
       round(avg(h.load1)::numeric, 2) AS load1, max(h.connections) AS connections
  FROM pgvigil.host_sample h
 WHERE h.instance_id = $1 AND h.snapshot_at > $2 AND h.snapshot_at <= $3
 GROUP BY 1 ORDER BY 1`

// sqlHostIO is system_stats' device IO over the window, summed over devices per snapshot (on-prem only).
const sqlHostIO = `
SELECT snapshot_at, sum(reads_s) AS reads_s, sum(writes_s) AS writes_s, sum(read_bytes_s) AS read_bytes_s,
       sum(write_bytes_s) AS write_bytes_s, max(read_ms_per_op) AS read_ms_per_op, max(write_ms_per_op) AS write_ms_per_op
  FROM pgvigil.host_io_rate($1, $2, $3)
 GROUP BY snapshot_at ORDER BY snapshot_at`

// sqlHostChecks are the instance's host and disk checks now.
const sqlHostChecks = `
SELECT severity, check_name, object, at, detail, check_group FROM pgvigil.host_checks WHERE instance_id = $1 ORDER BY severity, check_name, object`

// sqlDiskReport is every present volume of the fleet under $1 % free (volumes with no total are listed
// at 100 only), the fullest first.
const sqlDiskReport = `
SELECT d.instance_id, d.instance, d.platform, d.mount_point, d.device, d.fs_type, d.source, d.total_bytes, d.used_bytes, d.free_bytes,
       d.free_pct, d.holds_data, d.snapshot_at
  FROM pgvigil.disk_report d
 WHERE coalesce(d.free_pct, 100) <= $1
 ORDER BY d.free_pct NULLS LAST, d.instance, d.mount_point`

// Host is one instance's Host tab: the latest state, the volumes, the series and the device IO of the
// window, and the host and disk checks.
func (s *Server) Host(w http.ResponseWriter, r *http.Request) {
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
		{"latest", sqlHostLatest, []any{id}},
		{"disks", sqlHostDisks, []any{id}},
		{"series", sqlHostSeries, []any{id, from, to, bucket}},
		{"io", sqlHostIO, []any{id, from, to}},
		{"checks", sqlHostChecks, []any{id}},
	})
}

// Disks is the fleet Disk report: every volume at or under ?under= % free (default 20; 100 lists all).
func (s *Server) Disks(w http.ResponseWriter, r *http.Request) {
	under := 20.0
	if v := r.URL.Query().Get("under"); v != "" {
		f, err := strconv.ParseFloat(v, 64)
		if err != nil || f < 0 || f > 100 {
			writeErr(w, http.StatusBadRequest, errors.New("under must be 0..100 (percent free)"))
			return
		}
		under = f
	}
	t, err := s.query(r.Context(), sqlDiskReport, under)
	s.reply(w, r, t, err)
}
