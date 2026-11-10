package web

import (
	"math"
	"net/http"
)

// The Availability tab of a SQL Server instance (task 98).
//
// GET /api/mssql/availability?instance=<id>&[from=&to=] (Server.MSSQLAvailability): the availability groups as the
// instance sees them (one row per replica, the group's own columns on each), the database replicas with their
// queues, estimates and last times, the queues over the window per database replica (bucketed to about 600 points),
// the failovers of the window, and the sections that exist only where the server has the feature: database
// mirroring, log shipping, replication. Then the instance's HA/DR findings and the thresholds in force.
// ?part=<name> reads one part (the shell's check for what the server has).

const sqlMSSQLAgReplicas = `
SELECT group_name, replica_server, is_local, role, primary_replica, availability_mode, failover_mode, connected_state,
       synchronization_health, operational_state, recovery_health, cluster_type, is_distributed, is_contained, group_health,
       seeding_mode, secondary_connections, backup_preference, backup_priority, required_sync_secondaries, db_failover,
       endpoint_url, listeners, cluster, last_connect_error, last_connect_error_text, last_connect_error_at, snapshot_at
  FROM pgvigil.mssql_ag_state
 WHERE instance_id = $1
 ORDER BY group_name, (role = 'PRIMARY') DESC NULLS LAST, replica_server`

const sqlMSSQLAgDatabases = `
SELECT group_name, replica_server, database_name, is_local, is_primary_replica, synchronization_state, synchronization_health,
       database_state, is_suspended, suspend_reason, log_send_queue_kb, log_send_rate_kb_s, redo_queue_kb, redo_rate_kb_s,
       est_data_loss_s, est_recovery_s, secondary_lag_s, last_sent_at, last_received_at, last_hardened_at, last_redone_at,
       last_commit_at, snapshot_at
  FROM pgvigil.mssql_ag_database_state
 WHERE instance_id = $1
 ORDER BY group_name, database_name, is_primary_replica DESC NULLS LAST, replica_server`

// the queues summed over the database replicas per bucket (the largest of a bucket's reads), and the worst estimates
const sqlMSSQLAgSeries = `
WITH per AS (
  SELECT to_timestamp(floor(extract(epoch FROM s.snapshot_at) / $4) * $4) AS bucket, s.replica_server, s.database_name,
         max(s.log_send_queue_kb) AS send_kb, max(s.redo_queue_kb) AS redo_kb, max(s.est_recovery_s) AS recovery_s,
         max(s.est_data_loss_s) AS loss_s, bool_or(s.is_suspended) AS suspended
    FROM pgvigil.mssql_ag_sample s
   WHERE s.instance_id = $1 AND s.snapshot_at > $2 AND s.snapshot_at <= $3
   GROUP BY 1, 2, 3
)
SELECT bucket AS snapshot_at, sum(send_kb)::bigint AS log_send_queue_kb, sum(redo_kb)::bigint AS redo_queue_kb,
       max(recovery_s) AS est_recovery_s, max(loss_s) AS est_data_loss_s, count(*) FILTER (WHERE suspended) AS suspended
  FROM per
 GROUP BY bucket
 ORDER BY bucket`

const sqlMSSQLAgFailovers = `
SELECT at, group_name, old_primary, new_primary FROM pgvigil.mssql_ag_failovers
 WHERE instance_id = $1 AND at > $2 AND at <= $3
 ORDER BY at DESC`

const sqlMSSQLMirroring = `
SELECT database_name, role, state, safety_level, partner, partner_instance, witness, witness_state, connection_timeout_s,
       log_send_queue_kb, redo_queue_kb, snapshot_at
  FROM pgvigil.mssql_mirroring_state WHERE instance_id = $1 ORDER BY database_name`

const sqlMSSQLLogShipping = `
SELECT role, database_name, primary_server, primary_database, secondary_server, threshold_minutes, alert_enabled,
       last_backup_at, last_backup_file, last_copied_at, last_copied_file, last_restored_at, last_restored_file,
       last_restored_latency_min,
       round(extract(epoch FROM snapshot_at - CASE role WHEN 'primary' THEN last_backup_at ELSE last_restored_at END) / 60) AS age_minutes,
       snapshot_at
  FROM pgvigil.mssql_logshipping_state WHERE instance_id = $1 ORDER BY role, database_name`

const sqlMSSQLReplication = `
SELECT kind, distribution_db, publisher, publisher_db, publication, publication_type, articles, subscriber, subscriber_db,
       subscription_type, agent_type, agent_name, runstatus,
       CASE runstatus WHEN 1 THEN 'started' WHEN 2 THEN 'succeeded' WHEN 3 THEN 'in progress' WHEN 4 THEN 'idle'
                      WHEN 5 THEN 'retrying' WHEN 6 THEN 'failed' END AS status,
       status_text, last_run_at, latency_ms, delivery_rate, undistributed, est_catchup_s, snapshot_at
  FROM pgvigil.mssql_replication_state WHERE instance_id = $1
 ORDER BY CASE kind WHEN 'publication' THEN 0 WHEN 'subscription' THEN 1 ELSE 2 END, publisher, publisher_db, publication, subscriber, agent_name`

const sqlMSSQLHADRFindings = `
SELECT severity, check_name, object, at, detail FROM pgvigil.mssql_hadr_findings
 WHERE instance_id = $1
 ORDER BY CASE severity WHEN 'critical' THEN 0 WHEN 'warning' THEN 1 ELSE 2 END, at DESC`

const sqlMSSQLHADRLimits = `
SELECT log_send_queue_kb, redo_queue_kb, repl_undistributed_commands FROM pgvigil.mssql_hadr_limits WHERE instance_id = $1`

const sqlMSSQLHADRReads = `
SELECT r.collection, r.snapshot_at, r.row_count, c.status, c.note
  FROM pgvigil.mssql_hadr_reads r
  LEFT JOIN pgvigil.collection_dates c ON c.instance_id = r.instance_id AND c.collection = r.collection
 WHERE r.instance_id = $1 AND r.collection IN ('mssql_ag', 'mssql_mirroring', 'mssql_logshipping', 'mssql_replication')
 ORDER BY r.collection`

// MSSQLAvailability serves the Availability tab of one SQL Server instance.
func (s *Server) MSSQLAvailability(w http.ResponseWriter, r *http.Request) {
	id, from, to, err := params(r, true)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	// about 600 points over any window, never finer than the one-minute collection
	step := int(math.Ceil(to.Sub(from).Seconds() / 600))
	if step < 60 {
		step = 60
	}
	s.multiPart(w, r, []part{
		{"replicas", sqlMSSQLAgReplicas, []any{id}},
		{"databases", sqlMSSQLAgDatabases, []any{id}},
		{"series", sqlMSSQLAgSeries, []any{id, from, to, step}},
		{"failovers", sqlMSSQLAgFailovers, []any{id, from, to}},
		{"mirroring", sqlMSSQLMirroring, []any{id}},
		{"logshipping", sqlMSSQLLogShipping, []any{id}},
		{"replication", sqlMSSQLReplication, []any{id}},
		{"findings", sqlMSSQLHADRFindings, []any{id}},
		{"limits", sqlMSSQLHADRLimits, []any{id}},
		{"reads", sqlMSSQLHADRReads, []any{id}},
	})
}
