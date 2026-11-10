-- 0051: the final join of phase 2 wave D: the two read views Grafana's dashboards waited for (docs/grafana.md's two
-- gaps). The UI reads pgvigil.activity_summary and pgvigil.wait_sample itself (internal/web/queries.go 'sessions',
-- internal/web/q_waits.go sqlWaitsSeries); a reader login reads views and functions only, so each table gets a view
-- that applies the UI's own filters.
-- sessions_over_time: activity_summary as it is, one row per instance and sample: the session counts by state (active,
-- idle, idle in transaction, idle in transaction (aborted); waiting on a lock and active in ClientRead are subsets of
-- active), the longest active and idle-in-transaction seconds, the oldest xmin age and max_connections.
-- waits_over_time: the wait-sampling extension's rows (pg_wait_sampling, or Azure's pgms_wait_sampling) per instance,
-- sample time, source and event type, without the Activity type (background processes idling between their rounds)
-- and without an idle connection's Client:ClientRead (queryid 0), as the UI's Waits tab counts them; sessions is the
-- wait time over the sample's period: the average sessions waiting on that type during the sample (NULL where the
-- period is unknown). An instance without the extension has no rows here: the UI's tab falls back to the activity
-- samples for it, a Grafana panel does not (docs/grafana.md says so).

CREATE OR REPLACE VIEW pgvigil.sessions_over_time AS
SELECT instance_id, snapshot_at, total, active, idle, idle_in_txn, idle_in_txn_aborted, waiting_lock,
       active_client_wait, longest_active_secs, longest_idle_txn_secs, oldest_xmin_age, max_connections
  FROM pgvigil.activity_summary;

CREATE OR REPLACE VIEW pgvigil.waits_over_time AS
SELECT w.instance_id, w.snapshot_at, w.source, w.event_type,
       sum(w.samples)::bigint AS samples, sum(w.wait_secs) AS wait_secs,
       CASE WHEN max(w.interval_secs) > 0
            THEN round((sum(w.wait_secs) / max(w.interval_secs))::numeric, 3)::float8 END AS sessions
  FROM pgvigil.wait_sample w
 WHERE w.event_type <> 'Activity' AND NOT (w.event_type = 'Client' AND w.event = 'ClientRead' AND w.queryid = 0)
 GROUP BY w.instance_id, w.snapshot_at, w.source, w.event_type;
