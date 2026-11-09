package web

// sqlInstances lists the active instances with their state and the latest session summary.
const sqlInstances = `
SELECT i.instance_id, i.name, i.platform, i.server_version, i.is_replica, i.tags, i.last_seen,
       st.postmaster_start, st.max_connections, st.data_checksums, st.has_pg_stat_statements,
       a.snapshot_at AS activity_at, a.total, a.active, a.idle_in_txn, a.waiting_lock,
       a.longest_active_secs, a.longest_idle_txn_secs, a.oldest_xmin_age,
       (SELECT count(*) FROM pgvigil.collection_dates c
         WHERE c.instance_id = i.instance_id AND c.status = 'error') AS collections_failing
  FROM pgvigil.instances i
  LEFT JOIN pgvigil.instance_state st ON st.instance_id = i.instance_id
  LEFT JOIN LATERAL (SELECT * FROM pgvigil.activity_summary x
                      WHERE x.instance_id = i.instance_id
                      ORDER BY x.snapshot_at DESC LIMIT 1) a ON true
 WHERE i.is_active
 ORDER BY i.name`

// sqlOverview is the daily-checks list, one row per finding, worst first.
// $1 = {"instance": {"collection": seconds}} from the config, $2 = the fallback stale age.
// A collection is stale past three intervals (at least five minutes).
const sqlOverview = `
WITH inst AS (SELECT instance_id, name FROM pgvigil.instances WHERE is_active),
checks AS (
  SELECT c.instance_id, 'critical' AS severity, 'collection failing' AS check_name, c.collection AS object,
         c.snapshot_at AS at, c.note AS detail
    FROM pgvigil.collection_dates c JOIN inst i USING (instance_id)
   WHERE c.status = 'error'
  UNION ALL
  SELECT c.instance_id, 'warning', 'collection stale', c.collection, c.snapshot_at,
         'last ' || to_char(now() - c.snapshot_at, 'DD"d" HH24"h" MI"m"') || ' ago'
    FROM pgvigil.collection_dates c JOIN inst i USING (instance_id)
   WHERE c.status <> 'error'
     AND now() - c.snapshot_at > make_interval(secs => greatest(300, 3 * coalesce(($1::jsonb -> i.name ->> c.collection)::int, $2::int)))
  UNION ALL
  SELECT r.instance_id, CASE WHEN r.check_name LIKE 'slot WAL status%' THEN 'critical' ELSE 'warning' END,
         r.check_name, r.object, r.snapshot_at,
         r.value::text || ' ' || r.unit || coalesce(' (' || r.state || ')', '')
    FROM pgvigil.replication_checks r JOIN inst i USING (instance_id)
  UNION ALL
  SELECT f.instance_id, 'critical', 'job failed', f.scheduler || ' ' || coalesce(f.job_name, f.job_id::text), f.start_time,
         left(f.return_message, 300)
    FROM pgvigil.job_failures f JOIN inst i USING (instance_id)
  UNION ALL
  SELECT i.instance_id, CASE WHEN x.checksum_failures > 0 THEN 'critical' ELSE 'warning' END,
         CASE WHEN x.checksum_failures > 0 THEN 'checksum failures (24 h)' ELSE 'deadlocks (24 h)' END,
         x.datname, x.last_at,
         CASE WHEN x.checksum_failures > 0 THEN x.checksum_failures::text || ' checksum failure(s); ' ELSE '' END
           || x.deadlocks::text || ' deadlock(s)'
    FROM inst i
    CROSS JOIN LATERAL (
      SELECT d.datname, sum(d.deadlocks) AS deadlocks, sum(d.checksum_failures) AS checksum_failures, max(d.snapshot_at) AS last_at
        FROM pgvigil.dbstats_rate(i.instance_id, now() - interval '1 day', now()) d
       GROUP BY d.datname) x
   WHERE x.deadlocks > 0 OR x.checksum_failures > 0
)
SELECT ch.severity, i.name AS instance, ch.instance_id, ch.check_name, ch.object, ch.at, ch.detail
  FROM checks ch JOIN inst i USING (instance_id)
 ORDER BY ch.severity = 'critical' DESC, i.name, ch.check_name, ch.object`

// sqlSessions is one activity snapshot with statement text and ages at the snapshot.
const sqlSessions = `
SELECT s.pid, s.leader_pid, s.backend_type, s.datname, s.usename, s.application_name, s.client, s.state,
       s.wait_event_type, s.wait_event, s.blocking_pids, s.is_blocker,
       extract(epoch FROM s.snapshot_at - s.query_start)::int AS query_secs,
       extract(epoch FROM s.snapshot_at - s.xact_start)::int  AS xact_secs,
       extract(epoch FROM s.snapshot_at - s.state_change)::int AS state_secs,
       s.backend_xmin_age, s.xid_assigned, s.query_id, q.query
  FROM pgvigil.activity_sample s
  LEFT JOIN pgvigil.query_text q ON q.query_hash = s.query_hash
 WHERE s.instance_id = $1 AND s.snapshot_at = $2
 ORDER BY s.is_blocker DESC, cardinality(s.blocking_pids) > 0 DESC, s.query_start NULLS LAST`

// sqlCounters are per-second rates per snapshot, summed over databases (db) or IO rows (io).
var sqlCounters = map[string]string{
	"db": `
SELECT snapshot_at,
       round(sum(xact_commit)::numeric   / max(interval_secs), 2) AS commits_s,
       round(sum(xact_rollback)::numeric / max(interval_secs), 2) AS rollbacks_s,
       round(sum(blks_read)::numeric     / max(interval_secs), 2) AS blks_read_s,
       round(sum(blks_hit)::numeric      / max(interval_secs), 2) AS blks_hit_s,
       round(sum(tup_returned + tup_fetched)::numeric / max(interval_secs), 2) AS tup_read_s,
       round(sum(tup_inserted + tup_updated + tup_deleted)::numeric / max(interval_secs), 2) AS tup_written_s,
       round(sum(temp_bytes)::numeric    / max(interval_secs), 0) AS temp_bytes_s,
       sum(deadlocks) AS deadlocks, sum(numbackends) AS backends
  FROM pgvigil.dbstats_rate($1, $2, $3)
 WHERE interval_secs > 0
 GROUP BY snapshot_at ORDER BY snapshot_at`,
	"server": `
SELECT snapshot_at,
       checkpoints_timed + checkpoints_req AS checkpoints, checkpoints_req,
       round((coalesce(buffers_checkpoint, 0) + coalesce(buffers_clean, 0) + coalesce(buffers_backend, 0))::numeric / interval_secs, 2) AS buffers_written_s,
       round(buffers_alloc::numeric / interval_secs, 2) AS buffers_alloc_s,
       round(wal_bytes / interval_secs, 0) AS wal_bytes_s,
       round(wal_records::numeric / interval_secs, 2) AS wal_records_s,
       wal_buffers_full
  FROM pgvigil.serverstats_rate($1, $2, $3)
 WHERE interval_secs > 0
 ORDER BY snapshot_at`,
	"io": `
SELECT snapshot_at,
       round(sum(read_bytes)   / max(interval_secs), 0) AS read_bytes_s,
       round(sum(write_bytes)  / max(interval_secs), 0) AS write_bytes_s,
       round(sum(extend_bytes) / max(interval_secs), 0) AS extend_bytes_s,
       round(sum(hits)::numeric / max(interval_secs), 2) AS hits_s,
       round(sum(fsyncs)::numeric / max(interval_secs), 2) AS fsyncs_s
  FROM pgvigil.iostats_rate($1, $2, $3)
 WHERE interval_secs > 0
 GROUP BY snapshot_at ORDER BY snapshot_at`,
	"sessions": `
SELECT snapshot_at, total, active, idle_in_txn, waiting_lock, active_client_wait,
       longest_active_secs, longest_idle_txn_secs, oldest_xmin_age
  FROM pgvigil.activity_summary
 WHERE instance_id = $1 AND snapshot_at > $2 AND snapshot_at <= $3
 ORDER BY snapshot_at`,
}
