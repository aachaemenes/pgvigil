package web

import (
	"fmt"
	"net/http"
	"time"
)

// The daily health calendar (task 177 D29, Darling's PerformanceMonitor's Daily Health Calendar): GET
// /api/healthcal?instance=<id>[&month=YYYY-MM] returns one row per UTC day of the month up to today, the signals
// PerformanceMonitor bands a day by (its DailySummarySql.cs range read), read from pgvigil's own samples:
//   cpu_samples / high_cpu   the CPU reads of the day and those at or over 80 % (PostgreSQL host_sample.cpu_pct;
//                            SQL Server mssql_cpu_sample, 100 - idle, the process's share without an idle figure)
//   blocking / peak_block_s  PostgreSQL: the statements seen waiting on a lock and the longest span one was seen
//                            waiting (a lower bound); SQL Server: the blocked process reports and their longest wait_ms
//   deadlocks                PostgreSQL: pg_stat_database's counter risen within the day per database and restart
//                            epoch (0010); SQL Server: the deadlock graphs
//   mem_pressure / mem_crit  SQL Server only: the memory reads with memory grants pending, and those where the
//                            process memory was low (PostgreSQL has no grant queue: NULL)
//   top_wait / total_wait_s  the day's largest wait (PostgreSQL pg_wait_sampling's event type and event; SQL Server
//                            the wait type, the benign ones left out) and the day's wait seconds
//   errors                   the collection runs that ended in an error (collection_log keeps the runs that did not
//                            end well only: there is no run count; PerformanceMonitor's rule without one: any error is
//                            a warning)
//   alerts                   the alerts first sent that day for the instance (alert_state's episodes)
//   hours                    the day's span: 24, today's the hours elapsed (the per-hour bands read it)
//   has_data                 a per-minute sample of the day exists (PostgreSQL activity_summary, host_sample, dbstats;
//                            SQL Server mssql_cpu_sample, mssql_sched_sample, mssql_memory_sample)
// A day without a sample is a gap (has_data false), never a healthy day. The page bands each day (healthcal.ts). The
// day is a UTC day whatever the session's zone. The sample tables are read through their (instance_id, snapshot_at)
// or (instance_id, event_at) indexes; collection_log through its (snapshot_at) index, one day at a time.

const sqlHealthCal = `
WITH d AS (
  SELECT g::date AS day, g AT TIME ZONE 'UTC' AS day_start,
         least((g + interval '1 day') AT TIME ZONE 'UTC', $4::timestamptz) AS day_end
    FROM generate_series($2::timestamptz AT TIME ZONE 'UTC', ($3::timestamptz AT TIME ZONE 'UTC') - interval '1 day', interval '1 day') g
   WHERE g AT TIME ZONE 'UTC' < $4::timestamptz
), i AS (
  SELECT instance_id, engine FROM pgvigil.instances WHERE instance_id = $1
)
SELECT d.day, round((extract(epoch FROM d.day_end - d.day_start) / 3600)::numeric, 2) AS hours,
       hd.has_data,
       cpu.samples AS cpu_samples, cpu.hot AS high_cpu,
       bl.blocking, bl.peak_block_s, dl.deadlocks,
       mem.pressure AS mem_pressure, mem.crit AS mem_crit,
       w.top_wait, w.total_wait_s,
       coalesce(col.errors, 0) AS errors,
       al.alerts
  FROM d CROSS JOIN i
  -- a day has data when the instance's per-minute samples hold a read of it (PostgreSQL: the activity summary, the
  -- host, the database counters; SQL Server: the scheduler monitor, the schedulers, the memory clerks)
  CROSS JOIN LATERAL (
    SELECT CASE WHEN i.engine = 'postgres' THEN
             EXISTS (SELECT 1 FROM pgvigil.activity_summary x WHERE x.instance_id = i.instance_id AND x.snapshot_at >= d.day_start AND x.snapshot_at < d.day_end)
             OR EXISTS (SELECT 1 FROM pgvigil.host_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at >= d.day_start AND x.snapshot_at < d.day_end)
             OR EXISTS (SELECT 1 FROM pgvigil.dbstats x WHERE x.instance_id = i.instance_id AND x.snapshot_at >= d.day_start AND x.snapshot_at < d.day_end)
           ELSE
             EXISTS (SELECT 1 FROM pgvigil.mssql_cpu_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at >= d.day_start AND x.snapshot_at < d.day_end)
             OR EXISTS (SELECT 1 FROM pgvigil.mssql_sched_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at >= d.day_start AND x.snapshot_at < d.day_end)
             OR EXISTS (SELECT 1 FROM pgvigil.mssql_memory_sample x WHERE x.instance_id = i.instance_id AND x.snapshot_at >= d.day_start AND x.snapshot_at < d.day_end)
           END AS has_data) hd
  -- collection_log holds the runs that did not end well only (log_collection, 0001): the errors, no run count
  LEFT JOIN LATERAL (
    SELECT count(*) AS errors
      FROM pgvigil.collection_log l
     WHERE l.instance_id = i.instance_id AND l.status = 'error' AND l.snapshot_at >= d.day_start AND l.snapshot_at < d.day_end) col ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS samples, count(*) FILTER (WHERE h.cpu_pct >= 80) AS hot
      FROM pgvigil.host_sample h
     WHERE i.engine = 'postgres' AND h.instance_id = i.instance_id AND h.cpu_pct IS NOT NULL
       AND h.snapshot_at >= d.day_start AND h.snapshot_at < d.day_end
    UNION ALL
    SELECT count(*), count(*) FILTER (WHERE CASE WHEN m.idle_pct IS NULL THEN m.sql_pct ELSE 100 - m.idle_pct END >= 80)
      FROM pgvigil.mssql_cpu_sample m
     WHERE i.engine = 'sqlserver' AND m.instance_id = i.instance_id
       AND m.snapshot_at >= d.day_start AND m.snapshot_at < d.day_end
     ORDER BY 1 DESC LIMIT 1) cpu ON true
  LEFT JOIN LATERAL (
    SELECT count(*) AS blocking, round(max(x.waited)::numeric, 1) AS peak_block_s FROM (
      SELECT extract(epoch FROM max(a.snapshot_at) - min(a.snapshot_at)) AS waited
        FROM pgvigil.activity_sample a
       WHERE i.engine = 'postgres' AND a.instance_id = i.instance_id AND a.wait_event_type = 'Lock'
         AND a.snapshot_at >= d.day_start AND a.snapshot_at < d.day_end
       GROUP BY a.pid, a.backend_start, a.query_start) x
    UNION ALL
    SELECT count(*), round(max(b.wait_ms) / 1000.0, 1)
      FROM pgvigil.mssql_blocked_reports b
     WHERE i.engine = 'sqlserver' AND b.instance_id = i.instance_id
       AND b.event_at >= d.day_start AND b.event_at < d.day_end
     ORDER BY 1 DESC LIMIT 1) bl ON true
  LEFT JOIN LATERAL (
    SELECT coalesce(sum(greatest(x.hi - x.lo, 0)), 0)::bigint AS deadlocks FROM (
      SELECT max(s.deadlocks) AS hi, min(s.deadlocks) AS lo FROM pgvigil.dbstats s
       WHERE i.engine = 'postgres' AND s.instance_id = i.instance_id
         AND s.snapshot_at >= d.day_start AND s.snapshot_at < d.day_end
       GROUP BY s.dbid, s.epoch) x
    UNION ALL
    SELECT count(*) FROM pgvigil.mssql_deadlocks k
     WHERE i.engine = 'sqlserver' AND k.instance_id = i.instance_id
       AND k.event_at >= d.day_start AND k.event_at < d.day_end
     ORDER BY 1 DESC LIMIT 1) dl ON true
  LEFT JOIN LATERAL (
    SELECT count(*) FILTER (WHERE coalesce(m.grants_pending, 0) > 0 OR m.process_low) AS pressure,
           count(*) FILTER (WHERE m.process_low) AS crit
      FROM pgvigil.mssql_memory_sample m
     WHERE i.engine = 'sqlserver' AND m.instance_id = i.instance_id
       AND m.snapshot_at >= d.day_start AND m.snapshot_at < d.day_end
    HAVING i.engine = 'sqlserver') mem ON true
  LEFT JOIN LATERAL (
    SELECT (array_agg(t.name ORDER BY t.secs DESC))[1] AS top_wait, round(sum(t.secs)::numeric, 1) AS total_wait_s FROM (
      SELECT ws.event_type || ':' || ws.event AS name, sum(ws.wait_secs) AS secs
        FROM pgvigil.wait_sample ws
       WHERE i.engine = 'postgres' AND ws.instance_id = i.instance_id AND ws.wait_secs IS NOT NULL
         AND ws.event_type NOT IN ('Activity', 'CPU') AND NOT (ws.event_type = 'Client' AND ws.event = 'ClientRead' AND ws.queryid = 0)
         AND ws.snapshot_at >= d.day_start AND ws.snapshot_at < d.day_end
       GROUP BY 1
      UNION ALL
      SELECT mw.wait_type, sum(mw.wait_ms) / 1000.0
        FROM pgvigil.mssql_wait_sample mw
       WHERE i.engine = 'sqlserver' AND mw.instance_id = i.instance_id AND NOT mw.is_benign
         AND mw.snapshot_at >= d.day_start AND mw.snapshot_at < d.day_end
       GROUP BY 1) t
    HAVING count(*) > 0) w ON true
  LEFT JOIN LATERAL (
    SELECT count(DISTINCT s.finding_key) AS alerts
      FROM pgvigil.alert_state s
     WHERE s.instance_id = i.instance_id AND s.first_sent_at >= d.day_start AND s.first_sent_at < d.day_end) al ON true
 ORDER BY d.day`

// HealthCal is GET /api/healthcal: one instance's days of one UTC month (the current one by default), up to now.
func (s *Server) HealthCal(w http.ResponseWriter, r *http.Request) {
	id, _, _, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	now := time.Now().UTC()
	start := time.Date(now.Year(), now.Month(), 1, 0, 0, 0, 0, time.UTC)
	if m := r.URL.Query().Get("month"); m != "" {
		t, err := time.Parse("2006-01", m)
		if err != nil {
			writeErr(w, http.StatusBadRequest, fmt.Errorf("month: want YYYY-MM: %w", err))
			return
		}
		start = t.UTC()
	}
	end := start.AddDate(0, 1, 0)
	t, err := s.query(r.Context(), sqlHealthCal, id, start, end, now)
	s.reply(w, r, map[string]any{"days": t, "month": start.Format("2006-01"), "now": now}, err)
}
