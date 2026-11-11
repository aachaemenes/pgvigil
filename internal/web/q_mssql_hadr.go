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
// ?part=<name> reads one part (?part=reads is the shell's check: a row_count above 0 = the server has that feature).
//
// The part "distributed" is the one that looks past the instance: every distributed group the instance lists itself
// or carries a member group of, AS THE ACTIVE INSTANCE THAT IS THAT MEMBER GROUP'S PRIMARY REPORTS IT (only a member
// group's primary lists a distributed group's members: a secondary whose own primary is not read by an active
// instance cannot be tied and gets no row). One row per replica of each member group, read from that primary's
// instance; a member group whose primary no active instance reads comes as one row without a replica.

const sqlMSSQLAgReplicas = `
SELECT group_name, replica_server, is_local, role, primary_replica, availability_mode, failover_mode, connected_state,
       synchronization_health, operational_state, recovery_health, cluster_type, is_distributed, is_contained, group_health,
       seeding_mode, secondary_connections, backup_preference, backup_priority, required_sync_secondaries, db_failover,
       endpoint_url, listeners, cluster, last_connect_error, last_connect_error_text, last_connect_error_at, snapshot_at
  FROM pgvigil.mssql_ag_state
 WHERE instance_id = $1
 ORDER BY group_name, (role = 'PRIMARY') DESC NULLS LAST, replica_server`

// availability_mode: the replica's commit mode, from the replica's own row as the instance read it (a distributed
// group's link row: the member group's mode in the distributed group); the page marks SYNCHRONIZING by it
const sqlMSSQLAgDatabases = `
SELECT d.group_name, d.replica_server, d.database_name, d.is_local, d.is_primary_replica, d.synchronization_state,
       d.synchronization_health, d.database_state, d.is_suspended, d.suspend_reason, d.log_send_queue_kb, d.log_send_rate_kb_s,
       d.redo_queue_kb, d.redo_rate_kb_s, d.est_data_loss_s, d.est_recovery_s, d.secondary_lag_s, d.last_sent_at,
       d.last_received_at, d.last_hardened_at, d.last_redone_at, d.last_commit_at, r.availability_mode, d.snapshot_at
  FROM pgvigil.mssql_ag_database_state d
  LEFT JOIN pgvigil.mssql_ag_state r ON r.instance_id = d.instance_id AND r.group_id = d.group_id AND r.replica_server = d.replica_server
 WHERE d.instance_id = $1
 ORDER BY d.group_name, d.database_name, d.is_primary_replica DESC NULLS LAST, d.replica_server`

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

// A distributed group has one group_id on every server. Its member groups are tied to it by name on the instance
// that holds them (seen.member_gid), then by their own group_id across instances. Which member group is the PRIMARY
// is what the NEWEST read of the distributed group names as its primary (both primaries name it), never a member's
// own older claim: after a failover the side that no longer answers cannot stay a second primary. The state of the
// link comes from a read of the last five minutes (fresh) and from no older one, from the other side where that side
// reports one: the global primary sees the link, the forwarder only itself. replica_stale marks the rows of a member
// group whose primary's instance was last read more than five minutes ago.
const sqlMSSQLAgDistributed = `
WITH own AS (
  SELECT DISTINCT lower(group_id) AS gid FROM pgvigil.mssql_ag_state WHERE instance_id = $1
), seen AS (
  SELECT lower(d.group_id) AS dag_id, d.group_name AS dag_name, d.replica_server AS member, d.is_local, d.role,
         d.connected_state, d.synchronization_health, d.availability_mode, d.endpoint_url, d.primary_replica,
         d.instance_id, i.name AS instance, d.snapshot_at, d.snapshot_at > now() - interval '5 minutes' AS fresh,
         CASE WHEN d.is_local THEN (SELECT lower(g.group_id) FROM pgvigil.mssql_ag_state g
                                     WHERE g.instance_id = d.instance_id AND NOT coalesce(g.is_distributed, false)
                                       AND lower(g.group_name) = lower(d.replica_server) LIMIT 1) END AS member_gid
    FROM pgvigil.mssql_ag_state d
    JOIN pgvigil.instances i ON i.instance_id = d.instance_id AND i.is_active
   WHERE d.is_distributed
), mine AS (
  SELECT DISTINCT s.dag_id FROM seen s JOIN own o ON o.gid = s.dag_id OR o.gid = s.member_gid
), dag AS (
  SELECT s.dag_id, (array_agg(s.primary_replica ORDER BY s.snapshot_at DESC) FILTER (WHERE s.primary_replica IS NOT NULL))[1] AS dag_primary
    FROM seen s
   WHERE s.dag_id IN (SELECT dag_id FROM mine)
   GROUP BY s.dag_id
), member AS (
  SELECT s.dag_id, (array_agg(s.dag_name ORDER BY s.snapshot_at DESC))[1] AS dag_name,
         (array_agg(s.member ORDER BY s.snapshot_at DESC))[1] AS member,
         (array_agg(s.role ORDER BY s.snapshot_at DESC) FILTER (WHERE s.role IS NOT NULL))[1] AS seen_role,
         (array_agg(s.connected_state ORDER BY s.is_local, s.snapshot_at DESC) FILTER (WHERE s.fresh AND s.connected_state IS NOT NULL))[1] AS member_connected,
         (array_agg(s.synchronization_health ORDER BY s.is_local, s.snapshot_at DESC) FILTER (WHERE s.fresh AND s.synchronization_health IS NOT NULL))[1] AS member_health,
         (array_agg(s.availability_mode ORDER BY s.snapshot_at DESC))[1] AS member_mode,
         (array_agg(s.endpoint_url ORDER BY s.snapshot_at DESC))[1] AS member_url,
         (array_agg(s.instance_id ORDER BY s.snapshot_at DESC) FILTER (WHERE s.member_gid IS NOT NULL))[1] AS holder_id,
         (array_agg(s.instance ORDER BY s.snapshot_at DESC) FILTER (WHERE s.member_gid IS NOT NULL))[1] AS holder,
         (array_agg(s.member_gid ORDER BY s.snapshot_at DESC) FILTER (WHERE s.member_gid IS NOT NULL))[1] AS member_gid,
         max(s.snapshot_at) AS seen_at
    FROM seen s
   WHERE s.dag_id IN (SELECT dag_id FROM mine)
   GROUP BY s.dag_id, lower(s.member)
)
SELECT m.dag_name, m.dag_id, g.dag_primary, m.member, mr.member_role, m.member_connected, m.member_health, m.member_mode, m.member_url,
       m.holder AS member_instance, m.holder_id AS member_instance_id, m.seen_at,
       r.replica_server, r.role AS replica_role, r.connected_state AS replica_connected,
       r.synchronization_health AS replica_health, r.availability_mode AS replica_mode,
       CASE WHEN r.role = 'PRIMARY' AND mr.member_role = 'PRIMARY' THEN 'global primary'
            WHEN r.role = 'PRIMARY' AND mr.member_role = 'SECONDARY' THEN 'forwarder'
            WHEN r.role = 'SECONDARY' THEN 'secondary' END AS dag_role,
       x.instance_id AS replica_instance_id, x.name AS replica_instance,
       coalesce(x.instance_id = $1, false) AS is_this_instance, r.snapshot_at AS replica_seen_at,
       coalesce(r.snapshot_at <= now() - interval '5 minutes', false) AS replica_stale
  FROM member m
  JOIN dag g ON g.dag_id = m.dag_id
  CROSS JOIN LATERAL (SELECT CASE WHEN g.dag_primary IS NULL THEN m.seen_role
                                  WHEN lower(m.member) = lower(g.dag_primary) THEN 'PRIMARY' ELSE 'SECONDARY' END AS member_role) mr
  LEFT JOIN pgvigil.mssql_ag_state r ON r.instance_id = m.holder_id AND lower(r.group_id) = m.member_gid
  LEFT JOIN LATERAL (SELECT a.instance_id, ai.name
                       FROM pgvigil.mssql_ag_state a
                       JOIN pgvigil.instances ai ON ai.instance_id = a.instance_id AND ai.is_active
                      WHERE lower(a.group_id) = m.member_gid AND a.is_local AND lower(a.replica_server) = lower(r.replica_server)
                      ORDER BY a.snapshot_at DESC LIMIT 1) x ON r.replica_server IS NOT NULL
 ORDER BY m.dag_name, m.dag_id, (mr.member_role = 'PRIMARY') DESC NULLS LAST, m.member, (r.role = 'PRIMARY') DESC NULLS LAST, r.replica_server`

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

// the four collections' last runs: a skipped run stores no read, so the runs lead (collection_dates) and the read
// (its time and row count) rides beside; row_count says whether the server has the feature at all
const sqlMSSQLHADRReads = `
SELECT c.collection, c.snapshot_at AS run_at, c.status, c.note, r.snapshot_at, coalesce(r.row_count, 0) AS row_count
  FROM pgvigil.collection_dates c
  LEFT JOIN pgvigil.mssql_hadr_reads r ON r.instance_id = c.instance_id AND r.collection = c.collection
 WHERE c.instance_id = $1 AND c.collection IN ('mssql_ag', 'mssql_mirroring', 'mssql_logshipping', 'mssql_replication')
 ORDER BY c.collection`

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
		{"distributed", sqlMSSQLAgDistributed, []any{id}},
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
