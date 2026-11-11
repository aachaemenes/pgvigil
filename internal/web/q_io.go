package web

import (
	"errors"
	"net/http"
	"strconv"
	"time"
)

// IOOverviewCheck is the daily check behind the Summary grid's IO column: every warning or critical row of
// io_findings (EBS / burst balance, queue depth, read latency, DMS replication instance IO, checkpoints
// requested over timed). It goes into overviewChecks as one line; its check_group is "io".
var IOOverviewCheck = struct{ name, sql string }{"io", `
SELECT f.instance_id, f.severity, f.setting, f.value, f.at, f.detail
  FROM pgvigil.io_findings f JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND f.severity IN ('critical', 'warning')`}

// ioBucket is the chart bucket in seconds for a window: about 600 points, never under the 5-minute
// CloudWatch period (a smaller bucket would only repeat the period's value).
func ioBucket(from, to time.Time, floor int) int {
	b := int(to.Sub(from).Seconds()) / 600
	if b < floor {
		b = floor
	}
	return b
}

// sqlIOPlatformLatest is the newest CloudWatch datapoint of each storage metric of one instance.
const sqlIOPlatformLatest = `
SELECT metric, value, unit, stat, source, dim, at, read_at
  FROM pgvigil.cloud_io_latest
 WHERE instance_id = $1
 ORDER BY metric`

// sqlIOPlatform is the CloudWatch storage metrics over the window, the mean per $4-second bucket, long form
// (one row per bucket and metric; the page pivots), the newest rows kept when the cap is reached.
const sqlIOPlatform = `
SELECT * FROM (
  SELECT to_timestamp(floor(extract(epoch FROM snapshot_at) / $4) * $4) AS snapshot_at, metric,
         avg(value) AS value, min(value) AS low, max(value) AS high, max(unit) AS unit
    FROM pgvigil.cloud_io_sample
   WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3
   GROUP BY 1, 2
   ORDER BY 1 DESC
   LIMIT 20000) x
 ORDER BY snapshot_at, metric`

// sqlIOStats is pg_stat_io (the iostats collection) as per-second rates per snapshot, summed over its rows,
// with the time per read and per write where track_io_timing is on (the *_time columns stay 0 without it).
const sqlIOStats = `
SELECT snapshot_at,
       round(sum(reads)::numeric  / max(interval_secs), 2) AS reads_s,
       round(sum(writes)::numeric / max(interval_secs), 2) AS writes_s,
       round(sum(read_bytes)  / max(interval_secs), 0) AS read_bytes_s,
       round(sum(write_bytes) / max(interval_secs), 0) AS write_bytes_s,
       round(sum(extend_bytes) / max(interval_secs), 0) AS extend_bytes_s,
       round(sum(evictions)::numeric / max(interval_secs), 2) AS evictions_s,
       round((sum(read_time)  / nullif(sum(reads), 0))::numeric, 3) AS ms_per_read,
       round((sum(write_time) / nullif(sum(writes), 0))::numeric, 3) AS ms_per_write
  FROM pgvigil.iostats_rate($1, $2, $3, make_interval(secs => $4))
 WHERE interval_secs > 0
 GROUP BY snapshot_at
HAVING NOT bool_or(reset)
 ORDER BY snapshot_at`

// sqlIOByKind is the window's pg_stat_io totals per backend type, object and context, the busiest first.
const sqlIOByKind = `
SELECT backend_type, object, context, sum(reads) AS reads, sum(read_bytes) AS read_bytes,
       round((sum(read_time) / nullif(sum(reads), 0))::numeric, 3) AS ms_per_read,
       sum(writes) AS writes, sum(write_bytes) AS write_bytes,
       round((sum(write_time) / nullif(sum(writes), 0))::numeric, 3) AS ms_per_write,
       sum(writebacks) AS writebacks, sum(extends) AS extends, sum(extend_bytes) AS extend_bytes,
       sum(hits) AS hits, round(100.0 * sum(hits) / nullif(sum(hits) + sum(reads), 0), 1) AS hit_pct,
       sum(evictions) AS evictions, sum(fsyncs) AS fsyncs
  FROM pgvigil.iostats_rate($1, $2, $3, make_interval(secs => $4))
 WHERE NOT reset
 GROUP BY backend_type, object, context
HAVING coalesce(sum(reads), 0) + coalesce(sum(writes), 0) + coalesce(sum(extends), 0) + coalesce(sum(hits), 0) + coalesce(sum(fsyncs), 0) > 0
 ORDER BY coalesce(sum(read_bytes), 0) + coalesce(sum(write_bytes), 0) DESC, reads DESC NULLS LAST
 LIMIT 100`

// sqlIODBTime is pg_stat_database's block read and write time (track_io_timing) per snapshot: milliseconds spent
// reading or writing per wall-clock second, and the time per block read.
const sqlIODBTime = `
SELECT snapshot_at,
       round((sum(blk_read_time)  / max(interval_secs))::numeric, 3) AS read_ms_s,
       round((sum(blk_write_time) / max(interval_secs))::numeric, 3) AS write_ms_s,
       round(sum(blks_read)::numeric / max(interval_secs), 2) AS blks_read_s,
       round((sum(blk_read_time) / nullif(sum(blks_read), 0))::numeric, 4) AS ms_per_blk_read
  FROM pgvigil.dbstats_rate($1, $2, $3, make_interval(secs => $4))
 WHERE interval_secs > 0
 GROUP BY snapshot_at
HAVING NOT bool_or(reset)
 ORDER BY snapshot_at`

// sqlIOCheckpoints is the checkpointer per snapshot: timed and requested checkpoints and the buffers written.
const sqlIOCheckpoints = `
SELECT snapshot_at, checkpoints_timed, checkpoints_req,
       round(coalesce(buffers_checkpoint, 0)::numeric / interval_secs, 2) AS buffers_checkpoint_s,
       round(coalesce(checkpoint_write_time, 0)::numeric / 1000, 1) AS write_secs,
       round(coalesce(checkpoint_sync_time, 0)::numeric / 1000, 1) AS sync_secs
  FROM pgvigil.serverstats_rate($1, $2, $3, make_interval(secs => $4))
 WHERE interval_secs > 0
 ORDER BY snapshot_at`

// sqlIOCheckpointTotals is the checkpointer's counters summed over the window (the intervals across a stats reset
// left out): timed and requested checkpoints, the write and sync time and the buffers written. Before 17 they are
// pg_stat_bgwriter's, from 17 pg_stat_checkpointer's (num_timed, num_requested, write_time, sync_time,
// buffers_written: the dbstats collection reads the view the version has). The counters count a checkpoint that WAL
// volume forced as requested; the log's start line tells the two apart (sqlIOCheckpointCauses).
const sqlIOCheckpointTotals = `
SELECT sum(checkpoints_timed) AS timed, sum(checkpoints_req) AS requested,
       round((sum(checkpoint_write_time) / 1000)::numeric, 3) AS write_secs,
       round((sum(checkpoint_sync_time) / 1000)::numeric, 3) AS sync_secs,
       sum(buffers_checkpoint) AS buffers, count(*) AS intervals
  FROM pgvigil.serverstats_rate($1, $2, $3, make_interval(secs => $4))
 WHERE interval_secs > 0 AND NOT reset`

// sqlIOCheckpointLines: the log's checkpoint lines (log_checkpoints; kind 'checkpoint' since 0079) of the window and
// the hour before it (a start before the window pairs with its completion inside it); $1 instance, $2 from, $3 to.
const sqlIOCheckpointLines = `
WITH c AS (
  SELECT e.snapshot_at, e.pid, e.detail,
         substring(e.detail FROM '^(checkpoint|restartpoint) ') AS what,
         substring(e.detail FROM '^(?:checkpoint|restartpoint) (starting|complete):') AS phase
    FROM pgvigil.log_events e
   WHERE e.instance_id = $1 AND e.kind = 'checkpoint' AND e.snapshot_at > $2 - interval '1 hour' AND e.snapshot_at <= $3
)`

// checkpointCause names a start line's flags (in a column called flags) by the cause pgBadger charts: shutdown, end of
// recovery, wal (xlog before PostgreSQL 10), time, otherwise requested (a CHECKPOINT command, immediate / fast, force:
// CREATE DATABASE, a base backup, pg_start_backup).
const checkpointCause = `CASE WHEN flags IS NULL THEN 'start not read'
            WHEN flags ~ '\mshutdown\M' THEN 'shutdown'
            WHEN flags ~ '\mend-of-recovery\M' THEN 'end of recovery'
            WHEN flags ~ '\m(wal|xlog)\M' THEN 'wal'
            WHEN flags ~ '\mtime\M' THEN 'time'
            ELSE 'requested' END`

// sqlIOCheckpointCauses counts the start lines of the window by cause.
const sqlIOCheckpointCauses = sqlIOCheckpointLines + `,
s AS (SELECT c.what, btrim(substring(c.detail FROM 'starting:(.*)$')) AS flags FROM c WHERE c.phase = 'starting' AND c.snapshot_at > $2)
SELECT s.what, ` + checkpointCause + ` AS cause, count(*) AS checkpoints
  FROM s
 GROUP BY 1, 2
 ORDER BY 3 DESC, 1, 2`

// sqlIOCheckpointLog is one row per completed checkpoint of the window, newest first (at most 200): its start (the
// latest start line of the same process after that process's previous completion; none read = 'start not read'), the
// flags and cause, and the figures of the complete line (buffers and their share of shared_buffers, WAL files added /
// removed / recycled, write, sync and total seconds, distance and estimate). PostgreSQL 13 to 18 write the same
// fields (18 adds the SLRU buffers and the LSNs, not read here).
const sqlIOCheckpointLog = sqlIOCheckpointLines + `,
d AS (
  SELECT d.snapshot_at, d.pid, d.what, d.detail, st.snapshot_at AS started_at,
         btrim(substring(st.detail FROM 'starting:(.*)$')) AS flags
    FROM c d
    LEFT JOIN LATERAL (
      SELECT x.snapshot_at, x.detail FROM c x
       WHERE x.phase = 'starting' AND x.what = d.what AND x.pid = d.pid AND x.snapshot_at <= d.snapshot_at
         AND x.snapshot_at > coalesce((SELECT max(y.snapshot_at) FROM c y
                                        WHERE y.phase = 'complete' AND y.what = d.what AND y.pid = d.pid AND y.snapshot_at < d.snapshot_at), '-infinity')
       ORDER BY x.snapshot_at DESC LIMIT 1) st ON true
   WHERE d.phase = 'complete' AND d.snapshot_at > $2
)
SELECT d.snapshot_at AS completed_at, d.started_at, d.what, d.flags, ` + checkpointCause + ` AS cause,
       (substring(d.detail FROM 'wrote (\d+) buffers'))::bigint AS buffers,
       (substring(d.detail FROM 'buffers \(([0-9.]+)%\)'))::numeric AS buffers_pct,
       (regexp_match(d.detail, '(\d+) WAL file\(s\) added, (\d+) removed, (\d+) recycled'))[1]::int AS wal_added,
       (regexp_match(d.detail, '(\d+) WAL file\(s\) added, (\d+) removed, (\d+) recycled'))[2]::int AS wal_removed,
       (regexp_match(d.detail, '(\d+) WAL file\(s\) added, (\d+) removed, (\d+) recycled'))[3]::int AS wal_recycled,
       (substring(d.detail FROM 'write=([0-9.]+) s'))::numeric AS write_secs,
       (substring(d.detail FROM 'sync=([0-9.]+) s'))::numeric AS sync_secs,
       (substring(d.detail FROM 'total=([0-9.]+) s'))::numeric AS total_secs,
       (substring(d.detail FROM 'distance=(\d+) kB'))::bigint AS distance_kb,
       (substring(d.detail FROM 'estimate=(\d+) kB'))::bigint AS estimate_kb
  FROM d
 ORDER BY d.snapshot_at DESC
 LIMIT 200`

// sqlIOState is what the page needs to say why a panel is empty: the platform, the version (pg_stat_io from 16),
// track_io_timing, and log_checkpoints where it is not the default (on from PostgreSQL 15, off before).
const sqlIOState = `
SELECT i.platform, st.server_version_num, st.track_io_timing, st.snapshot_at,
       (SELECT x ->> 'value'
          FROM jsonb_array_elements(CASE WHEN jsonb_typeof(st.non_default_settings) = 'array' THEN st.non_default_settings ELSE '[]' END) x
         WHERE x ->> 'name' = 'log_checkpoints' LIMIT 1) AS log_checkpoints_set
  FROM pgvigil.instances i LEFT JOIN pgvigil.instance_state st USING (instance_id)
 WHERE i.instance_id = $1`

// sqlIOFindings is one instance's IO findings plus pgvigil.findings' own track_io_timing rule.
const sqlIOFindings = `
SELECT severity, setting, value, suggested, platforms, detail, source, at
  FROM pgvigil.io_findings WHERE instance_id = $1
UNION ALL
SELECT severity, setting, value, suggested, platforms, detail, source, at
  FROM pgvigil.findings WHERE instance_id = $1 AND setting = 'track_io_timing'
 ORDER BY 1, 2`

// IO is one instance's IO tab: the platform's storage metrics (CloudWatch), pg_stat_io, pg_stat_database's IO
// time, the checkpointer (its counters, and the log's checkpoint lines with their causes and times: parity3 task
// 126), the top statements by IO and the IO findings, over from..to.
func (s *Server) IO(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	ctx := r.Context()
	io, db := s.rateLookback(ctx, id, "iostats"), s.rateLookback(ctx, id, "dbstats")
	s.multi(w, r, []part{
		{"state", sqlIOState, []any{id}},
		{"platform_latest", sqlIOPlatformLatest, []any{id}},
		{"platform", sqlIOPlatform, []any{id, from, to, ioBucket(from, to, 300)}},
		{"pgio", sqlIOStats, []any{id, from, to, io}},
		{"pgio_by", sqlIOByKind, []any{id, from, to, io}},
		{"dbtime", sqlIODBTime, []any{id, from, to, db}},
		{"checkpoints", sqlIOCheckpoints, []any{id, from, to, db}},
		{"checkpoint_totals", sqlIOCheckpointTotals, []any{id, from, to, db}},
		{"checkpoint_causes", sqlIOCheckpointCauses, []any{id, from, to}},
		{"checkpoint_log", sqlIOCheckpointLog, []any{id, from, to}},
		{"statements", `SELECT * FROM pgvigil.top_statements_by($1, $2, $3, 'io', 20)`, []any{id, from, to}},
		{"findings", sqlIOFindings, []any{id}},
	})
}

// sqlDMSIOInstances is the newest IO read of every replication instance ($1 NULL) or one instance's.
const sqlDMSIOInstances = `
SELECT r.instance_id, i.name AS instance, r.ri_id, r.ri_arn, r.class, r.allocated_gb, r.free_storage_bytes,
       round((100.0 * r.free_storage_bytes / nullif(r.allocated_gb::numeric * 1073741824, 0))::numeric, 1) AS free_pct,
       r.read_iops, r.write_iops, r.read_latency_ms, r.write_latency_ms, r.read_bytes_s, r.write_bytes_s,
       r.queue_depth, r.net_tx_bytes_s, r.net_rx_bytes_s, r.cpu_pct, r.metrics_at, r.is_present
  FROM pgvigil.dms_instances r
  JOIN pgvigil.instances i USING (instance_id)
 WHERE i.is_active AND ($1::int IS NULL OR r.instance_id = $1)
 ORDER BY r.is_present DESC, i.name, r.ri_id`

// sqlDMSIOSeries is each replication instance's IO over the window, the mean per $4-second bucket (queue depth
// and latency: the bucket's worst), the newest rows kept at the cap.
const sqlDMSIOSeries = `
SELECT * FROM (
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS snapshot_at, s.instance_id, s.ri_arn,
         max(s.ri_id) AS ri_id, avg(s.read_iops) AS read_iops, avg(s.write_iops) AS write_iops,
         max(s.read_latency_ms) AS read_latency_ms, max(s.write_latency_ms) AS write_latency_ms,
         avg(s.read_bytes_s) AS read_bytes_s, avg(s.write_bytes_s) AS write_bytes_s, max(s.queue_depth) AS queue_depth,
         avg(s.net_tx_bytes_s) AS net_tx_bytes_s, avg(s.net_rx_bytes_s) AS net_rx_bytes_s,
         min(s.free_storage_bytes) AS free_storage_bytes, avg(s.cpu_pct) AS cpu_pct
    FROM pgvigil.dms_ri_sample s
    JOIN pgvigil.instances i USING (instance_id)
   WHERE i.is_active AND ($1::int IS NULL OR s.instance_id = $1) AND s.snapshot_at > $2 AND s.snapshot_at <= $3
   GROUP BY 1, 2, 3
   ORDER BY 1 DESC
   LIMIT 20000) x
 ORDER BY snapshot_at, instance_id, ri_arn`

// DMSIO is the DMS page's IO panel: the replication instances' newest storage IO and network read, and
// their trend over from..to (every instance, or one with ?instance=).
func (s *Server) DMSIO(w http.ResponseWriter, r *http.Request) {
	_, from, to, err := params(r, false)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	var id *int
	if v := r.URL.Query().Get("instance"); v != "" {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			writeErr(w, http.StatusBadRequest, errors.New("instance must be a positive instance_id"))
			return
		}
		id = &n
	}
	s.multi(w, r, []part{
		{"instances", sqlDMSIOInstances, []any{id}},
		{"series", sqlDMSIOSeries, []any{id, from, to, ioBucket(from, to, 60)}},
	})
}
