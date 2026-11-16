package web

import (
	"net/http"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// The Collector page (task 201, migration 0121; PerformanceMonitor's Collection Health as pgvigil's own page): the
// service (each run of a collector seen in the last 8 days: up, stopped, not seen, or retired - its host's collector uninstalled; serve's watchdog on or off), the
// findings of the collectors and the repository, each collection's runs over 24 h (failures, p50 / p95 duration from
// the beat's histograms, rows written, the read-to-store lag), the runs per minute, pgvigil's own load on each
// monitored server (connection attempts and connections opened per minute, logins refused), and the repository (size, growth per day, rows written per minute, the largest
// tables, its connections, the purges). ?instance=N narrows it to what the instance's Collection dates line shows.

// sqlCollectors: every run of a collector seen in the last 8 days, the live ones first
const sqlCollectors = `
SELECT s.collector_id, s.host, s.os, s.runs_as, s.version, s.pid, s.started_at, s.beat_at, s.beat_age_secs, s.state,
       s.stopped_at, s.retired_at, s.mem_bytes, s.goroutines, s.instances, s.repo_conns
  FROM pgvigil.collector_status s
 ORDER BY CASE s.state WHEN 'up' THEN 1 WHEN 'not seen' THEN 2 WHEN 'retired' THEN 4 ELSE 3 END, s.beat_at DESC`

// sqlWatchdog: serve's watchdog ($1: on, off: <why>; empty outside serve)
const sqlWatchdog = `SELECT nullif($1::text, '') AS watchdog`

// sqlCollectorFindings: the collector's findings ($1 the instance, 0 = all: an instance sees its own and the
// repository-wide ones) - every finding of pgvigil's own health, read from pgvigil.findings' own arms (0121's, B6.4's: a
// collection that runs long and a collector host whose collections run long, the alert sender idle, the repository's
// autovacuum behind), deduplicated by the findings view's own key. Never pgvigil.findings itself: a filter on source cannot pass its DISTINCT ON, so a fleet-wide load
// built every arm (B6.2 part c #5). 403b's K3 (an alert channel failing) is read here where its arm is joined: a
// WIRING line at the join. K3 is alert_findings' arm through alert_channel_findings (never findings': its ck CTE
// reads findings), so the guard walks the arms of both views and names K3 by its view (TestCollectorFindingsReadsItsArms;
// TestCollectorFindingsK3AtTheJoin shows the walk finds both of 403b's views as own arms; TestCollectorFindingsReadsItsArms
// is red at the join until they are read here and named in the claim CASE below). The claim ('why') is the collector parents' only.
const sqlCollectorFindings = `
WITH f AS (
  SELECT DISTINCT ON (x.instance_id, x.setting, x.value, x.detail) x.*
    FROM (SELECT instance_id, severity, setting, value, detail, source, at FROM pgvigil.collector_findings
          UNION ALL
          SELECT instance_id, severity, setting, value, detail, source, at FROM pgvigil.collection_runs_long_findings
          UNION ALL
          SELECT instance_id, severity, setting, value, detail, source, at FROM pgvigil.alert_sender_idle_findings
          UNION ALL
          SELECT instance_id, severity, setting, value, detail, source, at FROM pgvigil.repository_autovacuum_findings
          UNION ALL
          SELECT instance_id, severity, setting, value, detail, source, at FROM pgvigil.collection_runs_long_fold) x
   WHERE x.source IN ('pgvigil collector', 'pgvigil repository') AND ($1::int = 0 OR x.instance_id IS NULL OR x.instance_id = $1)
   ORDER BY x.instance_id, x.setting, x.value, x.detail
)
SELECT f.instance_id, coalesce(i.name, 'the repository') AS instance, f.severity, f.setting, f.value, f.detail, f.source, f.at,
       CASE WHEN f.source = 'pgvigil repository' AND f.setting NOT IN ('alert sender idle', 'repository autovacuum behind', 'alert channel failing', 'collections run long')
            THEN pgvigil.collector_claim(f.detail) END AS why
  FROM f
  LEFT JOIN pgvigil.instances i ON i.instance_id = f.instance_id
 ORDER BY pgvigil.severity_rank(f.severity) DESC, f.instance_id NULLS FIRST, f.setting`

// sqlCollectorCollections: per collection over 24 h. p50 / p95 from the summed histograms (an estimate within the
// bucket's factor of two); lag: now against the newest ok read of the collection (any instance) and the oldest
// instance's newest ok read (a failed run updates collection_dates too: it does not count as a read); retries: the
// imports its runs took again after a deadlock (0271, N4).
const sqlCollectorCollections = `
WITH r AS (
  SELECT engine, collection, sum(runs)::bigint AS runs, sum(failures)::bigint AS failures, sum(rows_written)::bigint AS rows_written,
         sum(dur_ms_sum)::bigint AS dur_sum, max(dur_ms_max) AS dur_max, max(minute) AS last_minute,
         sum(retries)::bigint AS retries
    FROM pgvigil.collector_runs WHERE minute > now() - interval '24 hours'
   GROUP BY engine, collection
), h AS (
  SELECT engine, collection, array_agg(n ORDER BY b) AS hist
    FROM (SELECT cr.engine, cr.collection, u.b, sum(u.v)::int AS n
            FROM pgvigil.collector_runs cr, unnest(cr.dur_hist) WITH ORDINALITY AS u(v, b)
           WHERE cr.minute > now() - interval '24 hours'
           GROUP BY cr.engine, cr.collection, u.b) x
   GROUP BY engine, collection
), lag AS (
  SELECT i.engine, d.collection, max(d.snapshot_at) FILTER (WHERE d.status = 'ok') AS newest,
         min(d.snapshot_at) FILTER (WHERE d.status = 'ok') AS oldest_newest
    FROM pgvigil.collection_dates d JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
   GROUP BY i.engine, d.collection
)
SELECT r.engine, r.collection, r.runs, r.failures,
       round(100.0 * r.failures / nullif(r.runs, 0), 1) AS failure_pct, r.retries,
       round(r.dur_sum::numeric / nullif(r.runs, 0)) AS avg_ms,
       round(pgvigil.collector_pctl(h.hist, 0.5)::numeric) AS p50_ms,
       round(pgvigil.collector_pctl(h.hist, 0.95)::numeric) AS p95_ms,
       r.dur_max AS max_ms, r.rows_written,
       round(extract(epoch FROM now() - lag.newest))::bigint AS lag_secs,
       round(extract(epoch FROM now() - lag.oldest_newest))::bigint AS oldest_lag_secs,
       r.last_minute
  FROM r
  LEFT JOIN h USING (engine, collection)
  LEFT JOIN lag USING (engine, collection)
 ORDER BY r.failures DESC, r.engine, r.collection`

// sqlCollectorMinutes: runs, failures and rows written per minute over 24 h (the chart)
// B6.4 (CHK#38 / OVW#140): p95_ms, the minute's run duration at its 95th percentile over every collection (the
// histograms of the minute summed, as the 24-hour p95 above), and max_ms, the minute's longest run (B6.2 part c #8: one
// collection running long among a minute's runs moves no p95)
const sqlCollectorMinutes = `
WITH m AS (
  SELECT minute, sum(runs)::bigint AS runs, sum(failures)::bigint AS failures, sum(rows_written)::bigint AS rows_written,
         max(dur_ms_max) AS max_ms
    FROM pgvigil.collector_runs WHERE minute > now() - interval '24 hours'
   GROUP BY minute
), h AS (
  SELECT minute, array_agg(n ORDER BY b) AS hist
    FROM (SELECT cr.minute, u.b, sum(u.v)::int AS n
            FROM pgvigil.collector_runs cr, unnest(cr.dur_hist) WITH ORDINALITY AS u(v, b)
           WHERE cr.minute > now() - interval '24 hours'
           GROUP BY cr.minute, u.b) x
   GROUP BY minute
)
SELECT m.minute AS snapshot_at, m.runs, m.failures, m.rows_written, round(pgvigil.collector_pctl(h.hist, 0.95)::numeric) AS p95_ms,
       m.max_ms
  FROM m LEFT JOIN h ON h.minute = m.minute
 ORDER BY m.minute`

// sqlCollectorLoad: pgvigil's own load per instance: connections opened and connection attempts per minute over the
// last hour (the mean over the minutes it ran, every collector summed, and the busiest minute), runs and failures in
// the hour, logins refused in the hour and 24 h, and the slow-connect tier's connect time in the hour (the timed
// connects' average and the longest, in seconds; NULL: none timed) ($1 the instance, 0 = all)
const sqlCollectorLoad = `
WITH l AS (
  SELECT l.instance_id, l.minute, sum(l.attempts) AS attempts, sum(l.opened) AS opened, sum(l.runs) AS runs,
         sum(l.failures) AS failures, sum(l.auth_failures) AS auth_failures,
         sum(l.timed) AS timed, sum(l.connect_ms_sum) AS connect_ms, max(l.connect_ms_max) AS connect_ms_max,
         sum(l.rt_count) AS rt_count, sum(l.rt_ms_sum) AS rt_ms, max(l.rt_ms_max) AS rt_ms_max
    FROM pgvigil.collector_load l
   WHERE l.minute > now() - interval '24 hours' AND ($1::int = 0 OR l.instance_id = $1)
   GROUP BY l.instance_id, l.minute
), ihh AS (
  -- the instance's probed host per collector host over the HOUR's load rows, as the probes below are read (the review of
  -- B24h-1 part b #15: collector_instance_hosts keeps 20 minutes, so an instance whose collector stopped 25 minutes ago
  -- showed no probe though the hour held them); its newest target
  SELECT DISTINCT ON (h.host, l.instance_id) h.host AS collector_host, l.instance_id, pgvigil.collector_target_host(l.target) AS host
    FROM pgvigil.collector_load l JOIN pgvigil.collector_heartbeat h USING (collector_id)
   WHERE l.minute > now() - interval '1 hour' AND l.target IS NOT NULL AND h.retired_at IS NULL AND ($1::int = 0 OR l.instance_id = $1)
   ORDER BY h.host, l.instance_id, l.minute DESC
), prh AS (
  -- B24h (0254): the instance's host's probe over the hour - its probed host over the hour (ihh), every collector host
  -- summed; when its address last answered (collector_probe_host). One row per probed host: an instance two collector
  -- hosts read under two dial names has two
  SELECT ih.instance_id, max(p.method) AS method, count(*) FILTER (WHERE p.answered IS NOT NULL) AS rounds,
         sum(p.answered) AS answered, sum(p.ms_sum) AS ms_sum, max(p.ms_max) FILTER (WHERE p.answered > 0) AS ms_max,
         (SELECT max(ph.last_answered) FROM pgvigil.collector_probe_host ph WHERE ph.host = ih.host) AS last_answered
    FROM ihh ih
    JOIN pgvigil.collector_heartbeat h ON h.host = ih.collector_host
    JOIN pgvigil.collector_probe p ON p.collector_id = h.collector_id AND p.host = ih.host AND p.minute > now() - interval '1 hour'
   WHERE ($1::int = 0 OR ih.instance_id = $1)
   GROUP BY ih.instance_id, ih.host
), pr AS (
  -- one row per instance (the review B6f8 #1: a row per probed host multiplied the load's rows in the join below)
  SELECT instance_id, max(method) AS method, sum(rounds) AS rounds, sum(answered) AS answered,
         round(sum(ms_sum)::numeric / nullif(sum(answered), 0) / 1000, 3) AS avg_s,
         round(max(ms_max)::numeric / 1000, 3) AS max_s, max(last_answered) AS last_answered
    FROM prh GROUP BY instance_id
)
SELECT i.instance_id, i.name AS instance, i.engine,
       round(avg(l.opened) FILTER (WHERE l.minute > now() - interval '1 hour'), 1) AS conns_per_min,
       round(avg(l.attempts) FILTER (WHERE l.minute > now() - interval '1 hour'), 1) AS attempts_per_min,
       max(l.opened) FILTER (WHERE l.minute > now() - interval '1 hour') AS conns_peak_min,
       sum(l.runs) FILTER (WHERE l.minute > now() - interval '1 hour') AS runs_1h,
       sum(l.failures) FILTER (WHERE l.minute > now() - interval '1 hour') AS failures_1h,
       coalesce(sum(l.auth_failures) FILTER (WHERE l.minute > now() - interval '1 hour'), 0) AS auth_failures_1h,
       sum(l.auth_failures) AS auth_failures_24h,
       round(sum(l.connect_ms) FILTER (WHERE l.minute > now() - interval '1 hour')::numeric
             / nullif(sum(l.timed) FILTER (WHERE l.minute > now() - interval '1 hour'), 0) / 1000, 3) AS connect_avg_s,
       round(max(l.connect_ms_max) FILTER (WHERE l.minute > now() - interval '1 hour' AND l.timed > 0)::numeric / 1000, 3) AS connect_max_s,
       -- B24h: the query round trip over the hour (one 'SELECT 1' a minute: the network and the server's answer)
       round(sum(l.rt_ms) FILTER (WHERE l.minute > now() - interval '1 hour')::numeric
             / nullif(sum(l.rt_count) FILTER (WHERE l.minute > now() - interval '1 hour'), 0) / 1000, 3) AS rt_avg_s,
       round(max(l.rt_ms_max) FILTER (WHERE l.minute > now() - interval '1 hour' AND l.rt_count > 0)::numeric / 1000, 3) AS rt_max_s,
       max(pr.method) AS probe_method, max(pr.rounds) AS probe_rounds_1h, max(pr.answered) AS probe_answered_1h,
       max(pr.avg_s) AS probe_avg_s, max(pr.max_s) AS probe_max_s, max(pr.last_answered) AS probe_last_answered,
       max(l.minute) AS last_minute
  FROM l
  JOIN pgvigil.instances i ON i.instance_id = l.instance_id AND i.is_active
  LEFT JOIN pr ON pr.instance_id = l.instance_id
 GROUP BY i.instance_id, i.name, i.engine
 ORDER BY sum(l.auth_failures) DESC, avg(l.opened) FILTER (WHERE l.minute > now() - interval '1 hour') DESC NULLS LAST, i.name`

// sqlCollectorStreaks: the collections failing now ($1 the instance, 0 = all) - per instance and collection the
// streak that speaks (collector_streaks_now: the lowest of the hosts still reading it, as the findings)
const sqlCollectorStreaks = `
SELECT s.instance_id, i.name AS instance, s.collection, s.fail_streak, s.failing_since, s.last_run_at, s.last_error
  FROM pgvigil.collector_streaks_now s
  JOIN pgvigil.instances i ON i.instance_id = s.instance_id AND i.is_active
 WHERE s.fail_streak > 0 AND ($1::int = 0 OR s.instance_id = $1)
 ORDER BY s.fail_streak DESC, i.name, s.collection`

// sqlCollectorRepository: one row: the repository's size now and 24 h ago (the beats' readings), the growth per day,
// rows written per minute over the last hour, the last purge
const sqlCollectorRepository = `
WITH now_b AS (SELECT pg_database_size(current_database()) AS bytes),
past AS (SELECT repo_bytes AS bytes, at FROM pgvigil.collector_beats
          WHERE at <= now() - interval '23 hours' AND repo_bytes IS NOT NULL ORDER BY at DESC LIMIT 1),
first AS (SELECT repo_bytes AS bytes, at FROM pgvigil.collector_beats WHERE repo_bytes IS NOT NULL ORDER BY at LIMIT 1),
w AS (SELECT round(sum(rows_written)::numeric / greatest(count(DISTINCT date_trunc('minute', at)), 1)) AS rows_per_min, count(*) AS beats
        FROM pgvigil.collector_beats WHERE at > now() - interval '1 hour'),
p AS (SELECT * FROM pgvigil.purge_runs ORDER BY finished_at DESC LIMIT 1)
SELECT n.bytes AS size_bytes,
       coalesce(past.bytes, first.bytes) AS size_then_bytes, coalesce(past.at, first.at) AS size_then_at,
       CASE WHEN coalesce(past.at, first.at) < now() - interval '1 hour'
            THEN round((n.bytes - coalesce(past.bytes, first.bytes)) * 86400.0 / extract(epoch FROM now() - coalesce(past.at, first.at))) END AS growth_per_day_bytes,
       w.rows_per_min, w.beats AS beats_1h,
       p.finished_at AS purge_at, p.days AS purge_days, cardinality(p.partitions_dropped) AS purge_partitions,
       p.rows_deleted AS purge_rows, p.total AS purge_total, array_to_string(p.partitions_dropped, ', ') AS purge_dropped
  FROM now_b n CROSS JOIN w LEFT JOIN past ON true LEFT JOIN first ON true LEFT JOIN p ON true`

// sqlCollectorTables: the repository's largest tables, a partitioned table as one line with its partitions
const sqlCollectorTables = `
SELECT coalesce(p.relname, c.relname) AS table_name, sum(pg_total_relation_size(c.oid))::bigint AS bytes,
       count(*) AS parts, sum(c.reltuples)::bigint AS rows_estimate
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'pgvigil'
  LEFT JOIN pg_inherits ih ON ih.inhrelid = c.oid
  LEFT JOIN pg_class p ON p.oid = ih.inhparent
 WHERE c.relkind = 'r'
 GROUP BY coalesce(p.relname, c.relname)
 ORDER BY 2 DESC LIMIT 15`

// sqlCollectorConns: the repository's connections now, by application and state
const sqlCollectorConns = `
SELECT coalesce(nullif(application_name, ''), '(none)') AS application, coalesce(state, '-') AS state, count(*) AS connections
  FROM pg_stat_activity
 WHERE datname = current_database()
 GROUP BY 1, 2 ORDER BY 3 DESC, 1, 2`

// sqlCollectorPurges: the last ten purge() runs
const sqlCollectorPurges = `
SELECT run_id, started_at, finished_at, round(extract(epoch FROM finished_at - started_at) * 1000)::bigint AS duration_ms, days,
       cardinality(partitions_dropped) AS partitions, rows_deleted, total, array_to_string(partitions_dropped, ', ') AS dropped
  FROM pgvigil.purge_runs ORDER BY finished_at DESC LIMIT 10`

// sqlCollectorWaits: a forming wait that ended on a collector without a parent (task 201 DONE-2 N7): its alerts went
// out as they came. The page says it under the findings; a parent's detail never does.
const sqlCollectorWaits = `
SELECT e.host, e.last_forming, e.ended_at, cardinality(e.instances) AS instances
  FROM pgvigil.collector_forming_ended e
 ORDER BY e.host`

// Collector is GET /api/collector[?instance=N]: the whole page, or with an instance the parts its Collection dates
// line reads (collectors, findings, load, streaks).
func (s *Server) Collector(w http.ResponseWriter, r *http.Request) {
	id, _, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	parts := []part{
		{"collectors", sqlCollectors, nil},
		{"watchdog", sqlWatchdog, []any{collect.WatchdogStatus()}},
		{"findings", sqlCollectorFindings, []any{id}},
		{"load", sqlCollectorLoad, []any{id}},
		{"streaks", sqlCollectorStreaks, []any{id}},
	}
	if id == 0 { // the Collector page; an instance's Collection dates line reads none of these
		parts = append(parts,
			part{"waits", sqlCollectorWaits, nil},
			part{"collections", sqlCollectorCollections, nil},
			part{"minutes", sqlCollectorMinutes, nil},
			part{"repository", sqlCollectorRepository, nil},
			part{"tables", sqlCollectorTables, nil},
			part{"connections", sqlCollectorConns, nil},
			part{"purges", sqlCollectorPurges, nil})
	}
	s.multiPart(w, r, parts)
}
