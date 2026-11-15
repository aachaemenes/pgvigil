package web

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"time"
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

// The HA/DR folder's three SQL Server pages in DBA Dash's shape (task 383): Availability Groups, Mirroring and Log
// Shipping, at the root, a tag folder (instances=) and one instance (instance=). DBA Dash 4.25.0's own sources say
// what each column is (DBADashGUI/HA/AG.cs, Mirroring.cs, LogShippingView.cs and their procedures); the comments name
// the procedure lines a query follows.
//
// GET /api/mssql/hadr/fleet?page=ag|mirroring|logshipping&[instance=N | instances=1,2]&[from=&to=]&[status=...]
// (Server.MSSQLHADRFleet), ?part= one part:
//   ag           summary (a folder) or detail (one instance), role_changes, health_events (one instance)
//   mirroring    summary, detail, role_changes
//   logshipping  summary, detail (?status= narrows the detail only, as LogShippingReport_Get.sql:217-220), thresholds
// from / to bound role_changes and health_events only (default the last 30 days, AG.cs:599; at most a year).
//
// Every scope reads active SQL Server instances only: $1 the instance (0 = any), $2 the folder's instances (NULL =
// any); an event grid's range is $3 / $4. Snapshot Date / Age are the collection's last run as the Collection dates page judges it (critical: the run
// failed; warning: older than three intervals, at least 300 s; disabled: interval 0) - $3 the expected intervals,
// $4 the stale age when no interval is known.

const hadrScope = `sc AS (
  SELECT i.instance_id, i.name FROM pgvigil.instances i
   WHERE i.is_active AND i.engine = 'sqlserver' AND ($1::int = 0 OR i.instance_id = $1) AND ($2::int[] IS NULL OR i.instance_id = ANY ($2))
)`

// hadrReads: the collection's last run per instance in scope, with the Collection dates page's status
func hadrReads(collection string) string {
	return `rd AS (
  SELECT c.instance_id, c.snapshot_at, greatest(0, extract(epoch FROM now() - c.snapshot_at))::bigint AS age_secs,
         CASE WHEN x.interval_secs = 0 THEN 'disabled'
              WHEN c.status = 'error' THEN 'critical'
              WHEN now() - c.snapshot_at > make_interval(secs => CASE WHEN x.interval_secs IS NULL THEN $4::int ELSE greatest(300, 3 * x.interval_secs) END) THEN 'warning'
              ELSE 'ok' END AS snap_status
    FROM pgvigil.collection_dates c
    JOIN sc ON sc.instance_id = c.instance_id
    CROSS JOIN LATERAL (SELECT coalesce(($3::jsonb -> 'instances' -> sc.name ->> c.collection)::int, ($3::jsonb -> 'defaults' ->> c.collection)::int) AS interval_secs) x
   WHERE c.collection = '` + collection + `'
)`
}

// AvailabilityGroupSummary_Get.sql:7-92: DATABASE replicas counted per instance (DBA Dash's rows are DatabasesHADR);
// the state as the DMV writes it ('NOT SYNCHRONIZING' with a space; pgvigil stores the _desc text as read), so it is
// normalised once; the data loss and recovery estimates per row first (:27-28: a primary -1, a SYNCHRONIZED row's
// data loss 0, an empty redo queue's recovery 0, unknown -2), then the largest. Synchronized Status: 6 (WarningLow)
// where a local row is not SYNCHRONIZED, else 4 (:36).
var sqlHADRAgSummary = `
WITH ` + hadrScope + `, ` + hadrReads("mssql_ag") + `, d AS (
  SELECT d.instance_id, coalesce(d.is_local, false) AS loc, coalesce(d.is_primary_replica, false) AS pri,
         upper(replace(d.synchronization_state, '_', ' ')) AS st, upper(replace(d.synchronization_health, '_', ' ')) AS health,
         r.secondary_connections, r.availability_mode, d.secondary_lag_s,
         CASE WHEN coalesce(d.is_primary_replica, false) THEN -1
              WHEN upper(replace(d.synchronization_state, '_', ' ')) = 'SYNCHRONIZED' THEN 0
              ELSE coalesce(d.est_data_loss_s, -2) END AS loss_s,
         CASE WHEN coalesce(d.is_primary_replica, false) THEN -1 WHEN d.redo_queue_kb IS NULL THEN -2 WHEN d.redo_queue_kb = 0 THEN 0
              ELSE coalesce(d.est_recovery_s, -2) END AS recovery_s,
         d.redo_queue_kb, d.log_send_queue_kb
    FROM pgvigil.mssql_ag_database_state d
    JOIN sc ON sc.instance_id = d.instance_id
    LEFT JOIN pgvigil.mssql_ag_state r ON r.instance_id = d.instance_id AND r.group_id = d.group_id AND r.replica_server = d.replica_server
)
SELECT sc.instance_id, sc.name AS instance,
       count(*) FILTER (WHERE loc AND pri) AS primary_replicas,
       count(*) FILTER (WHERE loc AND NOT pri) AS secondary_replicas,
       count(*) FILTER (WHERE loc AND secondary_connections IN ('READ_ONLY', 'ALL')) AS readable_secondaries,
       count(*) FILTER (WHERE loc AND availability_mode = 'ASYNCHRONOUS_COMMIT') AS async_commit,
       count(*) FILTER (WHERE loc AND availability_mode = 'SYNCHRONOUS_COMMIT') AS sync_commit,
       count(*) FILTER (WHERE loc AND st = 'NOT SYNCHRONIZING') AS not_synchronizing,
       count(*) FILTER (WHERE loc AND st = 'SYNCHRONIZING') AS synchronizing,
       count(*) FILTER (WHERE loc AND st = 'SYNCHRONIZED') AS synchronized,
       count(*) FILTER (WHERE loc AND st = 'REVERTING') AS reverting,
       count(*) FILTER (WHERE loc AND st = 'INITIALIZING') AS initializing,
       count(*) FILTER (WHERE NOT loc AND st = 'NOT SYNCHRONIZING') AS remote_not_synchronizing,
       count(*) FILTER (WHERE NOT loc AND st = 'SYNCHRONIZING') AS remote_synchronizing,
       count(*) FILTER (WHERE NOT loc AND st = 'SYNCHRONIZED') AS remote_synchronized,
       count(*) FILTER (WHERE NOT loc AND st = 'REVERTING') AS remote_reverting,
       count(*) FILTER (WHERE NOT loc AND st = 'INITIALIZING') AS remote_initializing,
       CASE min(CASE health WHEN 'NOT HEALTHY' THEN 0 WHEN 'PARTIALLY HEALTHY' THEN 1 WHEN 'HEALTHY' THEN 2 END)
            WHEN 0 THEN 'NOT_HEALTHY' WHEN 1 THEN 'PARTIALLY_HEALTHY' WHEN 2 THEN 'HEALTHY' END AS sync_health,
       CASE WHEN bool_or(loc AND coalesce(st, '') <> 'SYNCHRONIZED') THEN 'warninglow' ELSE 'ok' END AS synchronized_status,
       rd.snapshot_at AS snapshot_date, rd.age_secs AS snapshot_age_secs, rd.snap_status AS snapshot_status,
       max(secondary_lag_s) AS max_secondary_lag_s, max(loss_s) AS max_data_loss_s, max(recovery_s) AS max_recovery_s,
       sum(redo_queue_kb) AS total_redo_queue_kb, round(avg(redo_queue_kb)) AS avg_redo_queue_kb,
       sum(log_send_queue_kb) AS total_send_queue_kb, round(avg(log_send_queue_kb)) AS avg_send_queue_kb
  FROM d
  JOIN sc ON sc.instance_id = d.instance_id
  LEFT JOIN rd ON rd.instance_id = d.instance_id
 GROUP BY sc.instance_id, sc.name, rd.snapshot_at, rd.age_secs, rd.snap_status
 ORDER BY sc.name`

// AvailabilityGroup_Get.sql:7-60 for one instance: its database replicas, local rows first, then group and database
// (:58-60); Secondary Lag's words (:26) - the primary 'None (Primary)', a local secondary 'Reported on Primary', the
// primary's suspend reason where the primary's own row of that database is suspended.
var sqlHADRAgDetail = `
WITH ` + hadrScope + `, ` + hadrReads("mssql_ag") + `
SELECT d.database_name, d.group_name, d.replica_server, d.synchronization_state, d.synchronization_health, d.suspend_reason,
       d.database_state, coalesce(d.is_local, false) AS is_local, r.availability_mode, r.failover_mode,
       coalesce(d.is_primary_replica, false) AS is_primary, r.primary_connections, r.secondary_connections,
       rd.snapshot_at AS snapshot_date, rd.age_secs AS snapshot_age_secs, rd.snap_status AS snapshot_status,
       CASE WHEN coalesce(d.is_primary_replica, false) THEN 'None (Primary)' WHEN coalesce(d.is_local, false) THEN 'Reported on Primary'
            WHEN p.is_suspended THEN coalesce(p.suspend_reason, 'SUSPENDED') END AS secondary_lag_words,
       d.secondary_lag_s,
       CASE WHEN coalesce(d.is_primary_replica, false) THEN -1
            WHEN upper(replace(d.synchronization_state, '_', ' ')) = 'SYNCHRONIZED' THEN 0
            ELSE d.est_data_loss_s END AS data_loss_s,
       CASE WHEN coalesce(d.is_primary_replica, false) THEN -1 WHEN d.redo_queue_kb IS NULL THEN -2 WHEN d.redo_queue_kb = 0 THEN 0
            ELSE coalesce(d.est_recovery_s, -2) END AS recovery_s,
       d.redo_queue_kb, d.redo_rate_kb_s, d.log_send_queue_kb, d.log_send_rate_kb_s,
       d.last_sent_at, d.last_received_at, d.last_hardened_at, d.last_redone_at, d.last_commit_at
  FROM pgvigil.mssql_ag_database_state d
  JOIN sc ON sc.instance_id = d.instance_id
  LEFT JOIN pgvigil.mssql_ag_state r ON r.instance_id = d.instance_id AND r.group_id = d.group_id AND r.replica_server = d.replica_server
  LEFT JOIN rd ON rd.instance_id = d.instance_id
  LEFT JOIN LATERAL (SELECT x.is_suspended, x.suspend_reason FROM pgvigil.mssql_ag_database_state x
                      WHERE x.instance_id = d.instance_id AND x.group_id = d.group_id AND x.database_name = d.database_name
                        AND x.is_primary_replica AND x.is_local LIMIT 1) p ON true
 ORDER BY coalesce(d.is_local, false) DESC, d.group_name, d.database_name, d.replica_server`

// Role Changes (AvailabilityGroupRoleChanges_Get.sql; the XE rows as AGHealthEvents_Upd.sql L140-224 derives them):
//
//	XE        from the instance's AlwaysOn_health availability_replica_state_change rows (mssql_ag_events): stable
//	          roles PRIMARY_NORMAL / GLOBAL_PRIMARY (1) and SECONDARY_NORMAL / FORWARDER (2); Changed Before = the
//	          event that reached a new stable role, Changed After = the first state change after the previous stable
//	          state, Previous Role = that change's stable previous state, else the previous stable state.
//	Snapshot  mssql_ag_failovers (the read that first saw a new primary), for the instance whose own server name is
//	          the new primary ('Became Primary') or the old one ('No Longer Primary'); Changed After = the instance's
//	          read before it; hidden where an XE row of the same instance and group lies within 2 minutes (:133-144).
//
// Failover Type and Reason (:33-112): the window from 2 minutes before Changed After (or Before) to 30 s after Changed
// Before; alwayson_ddl_executed (not in phase ROLLBACK) holding FORCE_FAILOVER_ALLOW_DATA_LOSS = Forced, FAILOVER =
// Manual (Reason: the statement); availability_group_lease_expired = Automatic; then the instance-level events of any
// monitored replica of the group: the HADR manager not ONLINE (priority 3, Automatic) or an error (4). An event counts
// for the group only where its instance holds a replica row of that name and group_id (mssql_ag_events has no
// group_id: the gate keeps two clusters' same-named groups apart). $3 / $4 the range; $5 true = also the role changes
// other monitored replicas of the scope's groups report (the instance's Detail, AvailabilityGroup_Get.sql:66-69).
var sqlHADRAgRoleChanges = `
WITH ` + hadrScope + `, rs AS (
  SELECT sc.instance_id FROM sc
  UNION
  SELECT a2.instance_id FROM pgvigil.mssql_ag_state a1
    JOIN pgvigil.mssql_ag_state a2 ON lower(a2.group_id) = lower(a1.group_id) AND a2.instance_id <> a1.instance_id
    JOIN pgvigil.instances i2 ON i2.instance_id = a2.instance_id AND i2.is_active
   WHERE $5::boolean AND a1.instance_id IN (SELECT instance_id FROM sc)
), names AS (
  -- the instance's own server name: mssql_instance's, else its local replica's name in a group it holds (a replica
  -- is named by its server; an instance whose mssql_instance collection has not run still matches its own rows)
  SELECT i.instance_id, i.name,
         coalesce(mi.server_name, (SELECT a.replica_server FROM pgvigil.mssql_ag_state a
                                     WHERE a.instance_id = i.instance_id AND a.is_local AND NOT coalesce(a.is_distributed, false)
                                     ORDER BY a.snapshot_at DESC LIMIT 1)) AS server_name
    FROM pgvigil.instances i
    JOIN rs ON rs.instance_id = i.instance_id
    LEFT JOIN pgvigil.mssql_instance mi ON mi.instance_id = i.instance_id
), ln AS (
  -- every name a replica of the instance goes by: its server name and each local replica row's name - a distributed
  -- group's local replica is its member group, and its state changes and failover rows name that group (DBA Dash
  -- matches any is_local replica name, AGHealthEvents_Upd.sql:125-133)
  SELECT DISTINCT ON (x.instance_id, lower(x.lname)) x.instance_id, x.lname
    FROM (SELECT n.instance_id, n.server_name AS lname FROM names n WHERE n.server_name IS NOT NULL
          UNION ALL
          SELECT a.instance_id, a.replica_server FROM pgvigil.mssql_ag_state a JOIN rs ON rs.instance_id = a.instance_id
           WHERE a.is_local AND a.replica_server IS NOT NULL) x
   ORDER BY x.instance_id, lower(x.lname), x.lname
), ev AS (
  SELECT e.instance_id, e.ag_name, e.replica_name, e.event_at, e.event_key,
         CASE WHEN upper(e.previous_state) IN ('PRIMARY_NORMAL', 'GLOBAL_PRIMARY') THEN 1 WHEN upper(e.previous_state) IN ('SECONDARY_NORMAL', 'FORWARDER') THEN 2 END AS prev_stable,
         CASE WHEN upper(e.current_state) IN ('PRIMARY_NORMAL', 'GLOBAL_PRIMARY') THEN 1 WHEN upper(e.current_state) IN ('SECONDARY_NORMAL', 'FORWARDER') THEN 2 END AS cur_stable
    FROM pgvigil.mssql_ag_events e
    JOIN names n ON n.instance_id = e.instance_id
   -- a day past the range's end: a change that began before a custom end and finished after it is kept (the final
   -- WHERE's overlap rule, DBA Dash's :114-115)
   WHERE lower(e.event_name) = 'availability_replica_state_change' AND e.event_at <= $4::timestamptz + interval '1 day' AND e.event_at > $3::timestamptz - interval '30 days'
     AND (NOT EXISTS (SELECT 1 FROM ln WHERE ln.instance_id = e.instance_id)        -- nothing local known: every replica
          OR EXISTS (SELECT 1 FROM ln WHERE ln.instance_id = e.instance_id AND lower(ln.lname) = lower(e.replica_name)))
), ew AS (
  -- per replica in time order: grp = how many stable states came before the event (the events after one stable state
  -- up to the next share it); stable_no numbers the stable events. One pass of window functions, not a scan of the
  -- replica's events per event (review 383b S4)
  SELECT e.*,
         count(e.cur_stable) OVER (PARTITION BY e.instance_id, lower(e.ag_name), lower(e.replica_name) ORDER BY e.event_at, e.event_key
                                   ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS grp,
         CASE WHEN e.cur_stable IS NOT NULL
              THEN count(e.cur_stable) OVER (PARTITION BY e.instance_id, lower(e.ag_name), lower(e.replica_name) ORDER BY e.event_at, e.event_key
                                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) END AS stable_no
    FROM ev e
), eg AS (
  -- the first change after the previous stable state (Changed After) and its stable previous state
  SELECT w.*, first_value(w.event_at) OVER g AS grp_first_at, first_value(w.prev_stable) OVER g AS grp_first_prev
    FROM ew w
  WINDOW g AS (PARTITION BY w.instance_id, lower(w.ag_name), lower(w.replica_name), w.grp ORDER BY w.event_at, w.event_key)
), xe AS (
  SELECT e.instance_id, e.ag_name AS group_name, e.replica_name AS replica_server, pr.prev_role, e.cur_stable AS new_role,
         e.grp_first_at AS changed_after, e.event_at AS changed_before, 'XE'::text AS source
    FROM eg e
    LEFT JOIN ew p ON p.instance_id = e.instance_id AND lower(p.ag_name) = lower(e.ag_name) AND lower(p.replica_name) = lower(e.replica_name)
                  AND p.stable_no = e.grp                                       -- the previous stable state
    CROSS JOIN LATERAL (SELECT coalesce(e.grp_first_prev, p.cur_stable) AS prev_role) pr
   WHERE e.cur_stable IS NOT NULL AND pr.prev_role IS NOT NULL AND pr.prev_role <> e.cur_stable
), sn AS (
  SELECT f.instance_id, f.group_name, l.lname AS replica_server,
         CASE WHEN lower(f.new_primary) = lower(l.lname) THEN 2 ELSE 1 END AS prev_role,
         CASE WHEN lower(f.new_primary) = lower(l.lname) THEN 1 ELSE 2 END AS new_role,
         b.snapshot_at AS changed_after, f.at AS changed_before, 'Snapshot'::text AS source, f.group_id
    FROM pgvigil.mssql_ag_failovers f
    JOIN ln l ON l.instance_id = f.instance_id AND lower(l.lname) IN (lower(f.new_primary), lower(f.old_primary))
    -- the instance's read before the failover: up to a day back (an old primary down for hours writes the failover
    -- row at its first read after the restart; DBA Dash takes the previous snapshot however old)
    LEFT JOIN LATERAL (SELECT s.snapshot_at FROM pgvigil.mssql_ag_sample s
                        WHERE s.instance_id = f.instance_id AND s.snapshot_at < f.at AND s.snapshot_at > f.at - interval '1 day'
                        ORDER BY s.snapshot_at DESC LIMIT 1) b ON true
   WHERE f.at <= $4::timestamptz + interval '1 day' AND f.at > $3::timestamptz - interval '1 day'
), rc AS (
  SELECT x.instance_id, x.group_name, x.replica_server, x.prev_role, x.new_role, x.changed_after, x.changed_before, x.source,
         (SELECT a.group_id FROM pgvigil.mssql_ag_state a WHERE a.instance_id = x.instance_id AND lower(a.group_name) = lower(x.group_name) LIMIT 1) AS group_id
    FROM xe x
  UNION ALL
  SELECT s.instance_id, s.group_name, s.replica_server, s.prev_role, s.new_role, s.changed_after, s.changed_before, s.source, s.group_id
    FROM sn s
   WHERE NOT EXISTS (SELECT 1 FROM xe x WHERE x.instance_id = s.instance_id AND lower(x.group_name) = lower(s.group_name)
                       AND x.changed_before > coalesce(s.changed_after, s.changed_before) - interval '2 minutes'
                       AND x.changed_before <= s.changed_before + interval '2 minutes')
)
SELECT rc.instance_id, n.name AS instance, rc.group_name, rc.replica_server,
       CASE WHEN rc.new_role = 1 THEN 'Became Primary' WHEN rc.prev_role = 1 THEN 'No Longer Primary'
            ELSE concat(CASE rc.prev_role WHEN 1 THEN 'PRIMARY' ELSE 'SECONDARY' END, ' => ', CASE rc.new_role WHEN 1 THEN 'PRIMARY' ELSE 'SECONDARY' END) END AS change,
       CASE rc.prev_role WHEN 1 THEN 'PRIMARY' WHEN 2 THEN 'SECONDARY' END AS previous_role,
       CASE rc.new_role WHEN 1 THEN 'PRIMARY' WHEN 2 THEN 'SECONDARY' END AS new_role,
       rc.changed_after, rc.changed_before,
       extract(epoch FROM rc.changed_before - rc.changed_after)::bigint AS duration_s,
       CASE WHEN age.is_forced THEN 'Forced' WHEN age.is_manual THEN 'Manual'
            WHEN age.is_lease OR ie.priority <= 3 THEN 'Automatic' END AS failover_type,
       coalesce(CASE WHEN age.is_forced OR age.is_manual THEN age.statement END,
                CASE WHEN ie.priority <= 3 THEN ie.reason END,
                CASE WHEN age.is_lease THEN 'Lease expired' END,
                ie.reason) AS reason,
       rc.source
  FROM rc
  JOIN names n ON n.instance_id = rc.instance_id
  CROSS JOIN LATERAL (SELECT coalesce(rc.changed_after, rc.changed_before) - interval '2 minutes' AS w_from,
                             rc.changed_before + interval '30 seconds' AS w_to) w
  CROSS JOIN LATERAL (
    SELECT coalesce(bool_or(lower(e.event_name) = 'alwayson_ddl_executed' AND e.statement ILIKE '%FORCE\_FAILOVER\_ALLOW\_DATA\_LOSS%'), false) AS is_forced,
           coalesce(bool_or(lower(e.event_name) = 'alwayson_ddl_executed' AND e.statement ILIKE '%FAILOVER%'), false) AS is_manual,
           coalesce(bool_or(lower(e.event_name) = 'availability_group_lease_expired'), false) AS is_lease,
           max(e.statement) FILTER (WHERE lower(e.event_name) = 'alwayson_ddl_executed' AND e.statement ILIKE '%FAILOVER%') AS statement
      FROM pgvigil.mssql_ag_events e
     WHERE e.instance_id IN (SELECT a.instance_id FROM pgvigil.mssql_ag_state a
                              WHERE lower(a.group_name) = lower(rc.group_name)
                                AND CASE WHEN rc.group_id IS NULL THEN a.instance_id = rc.instance_id ELSE lower(a.group_id) = lower(rc.group_id) END)
       AND e.event_at >= w.w_from AND e.event_at <= w.w_to AND lower(e.ag_name) = lower(rc.group_name)
       AND lower(e.event_name) IN ('alwayson_ddl_executed', 'availability_group_lease_expired')
       AND upper(coalesce(e.ddl_phase, '')) <> 'ROLLBACK') age
  LEFT JOIN LATERAL (
    SELECT CASE WHEN lower(e.event_name) = 'availability_replica_manager_state_change'
                THEN concat('HADR manager ', e.current_state, ' on ', ri.name)
                ELSE concat('Error ', e.error_number, ' on ', ri.name, ': ', e.message) END AS reason,
           CASE WHEN lower(e.event_name) = 'availability_replica_manager_state_change' THEN 3 ELSE 4 END AS priority
      FROM pgvigil.mssql_ag_events e
      JOIN pgvigil.instances ri ON ri.instance_id = e.instance_id
     WHERE e.instance_id IN (SELECT rc.instance_id
                              UNION SELECT a.instance_id FROM pgvigil.mssql_ag_state a WHERE rc.group_id IS NOT NULL AND lower(a.group_id) = lower(rc.group_id))
       AND e.event_at >= w.w_from AND e.event_at <= w.w_to
       AND (lower(e.event_name) = 'error_reported'
            OR (lower(e.event_name) = 'availability_replica_manager_state_change' AND upper(coalesce(e.current_state, '')) <> 'ONLINE'))
     ORDER BY 2, e.event_at LIMIT 1) ie ON true
 WHERE rc.changed_before >= $3::timestamptz AND coalesce(rc.changed_after, rc.changed_before) < $4::timestamptz
   -- the instance's own changes, or ($5) another replica's change of a group the instance itself holds
   -- (AvailabilityGroupRoleChanges_Get.sql:122-129: AR.group_id = RC.group_id with the instance in @InstanceIDs)
   AND (rc.instance_id IN (SELECT sc.instance_id FROM sc)
        OR ($5::boolean AND lower(rc.group_id) IN (SELECT lower(a.group_id) FROM pgvigil.mssql_ag_state a JOIN sc ON sc.instance_id = a.instance_id)))
 ORDER BY rc.changed_before DESC, rc.group_name, n.name`

// AvailabilityGroupHealthEvents_Get.sql:9-25: one instance's AlwaysOn_health events of the range, newest first.
// Database and Component are not stored by pgvigil's reader (empty columns, as DBA Dash's grid has them). At most 5001
// rows: the page shows the newest 5000 and says when there were more.
var sqlHADRAgHealthEvents = `
WITH ` + hadrScope + `
SELECT e.event_at, e.event_name, e.ag_name, e.replica_name, NULL::text AS database_name, NULL::text AS component,
       e.previous_state, e.current_state, e.ddl_action, e.ddl_phase,
       e.error_number, coalesce(e.statement, e.message) AS details
  FROM pgvigil.mssql_ag_events e
  JOIN sc ON sc.instance_id = e.instance_id
 WHERE e.event_at >= $3::timestamptz AND e.event_at < $4::timestamptz
 ORDER BY e.event_at DESC
 LIMIT 5001`

// DatabaseMirroringSummary_Get.sql:6-30: per instance, by sys.database_mirroring.mirroring_state (0143's
// state_code): synchronized 4 / 6, suspended 0, disconnected 1, synchronizing 2, pending failover 3, not
// synchronized 5; the witness columns are 0 / 1 flags (MAX, :15-17); MirroringStatus (:18) colours Synchronized
// Count: 4 where every row is synchronized with its witness unknown (0) or connected (1), 2 where synchronizing or
// synchronized otherwise (a session with no witness too: its witness state is NULL - DBA Dash's rule as written,
// D7), else 1. A mirror read by a login that is not sysadmin (values_hidden) counts in Mirror Count only.
var sqlHADRMirroringSummary = `
WITH ` + hadrScope + `, ` + hadrReads("mssql_mirroring") + `, m AS (
  SELECT m.*, CASE upper(m.witness_state) WHEN 'UNKNOWN' THEN 0 WHEN 'CONNECTED' THEN 1 WHEN 'DISCONNECTED' THEN 2 END AS wcode,
         coalesce(m.values_hidden, false) AS hidden
    FROM pgvigil.mssql_mirroring_state m JOIN sc ON sc.instance_id = m.instance_id
)
SELECT sc.instance_id, sc.name AS instance,
       count(*) FILTER (WHERE m.role = 'PRINCIPAL') AS principal_count,
       count(*) FILTER (WHERE m.role = 'MIRROR') AS mirror_count,
       count(*) FILTER (WHERE NOT m.hidden AND m.state_code IN (4, 6)) AS synchronized_count,
       count(*) FILTER (WHERE NOT m.hidden AND m.state_code = 0) AS suspended_count,
       count(*) FILTER (WHERE NOT m.hidden AND m.state_code = 1) AS disconnected_count,
       count(*) FILTER (WHERE NOT m.hidden AND m.state_code = 2) AS synchronizing_count,
       count(*) FILTER (WHERE NOT m.hidden AND m.state_code = 3) AS pending_failover_count,
       count(*) FILTER (WHERE NOT m.hidden AND m.state_code = 5) AS not_synchronized_count,
       max(CASE WHEN NOT m.hidden AND m.wcode = 0 THEN 1 ELSE 0 END) AS witness_unknown_count,
       max(CASE WHEN NOT m.hidden AND m.wcode = 1 THEN 1 ELSE 0 END) AS witness_connected_count,
       max(CASE WHEN NOT m.hidden AND m.wcode = 2 THEN 1 ELSE 0 END) AS witness_disconnected_count,
       CASE min(CASE WHEN m.hidden THEN NULL WHEN m.state_code IN (4, 6) AND m.wcode IN (0, 1) THEN 4
                     WHEN m.state_code IN (2, 4, 6) THEN 2 ELSE 1 END)
            WHEN 4 THEN 'ok' WHEN 2 THEN 'warning' WHEN 1 THEN 'critical' END AS mirroring_status,
       count(*) FILTER (WHERE m.hidden) AS hidden_count,
       rd.age_secs AS snapshot_age_secs, rd.snap_status AS snapshot_status
  FROM m
  JOIN sc ON sc.instance_id = m.instance_id
  LEFT JOIN rd ON rd.instance_id = m.instance_id
 GROUP BY sc.instance_id, sc.name, rd.age_secs, rd.snap_status
 ORDER BY sc.name`

// DatabaseMirroring_Get.sql:35-52 with its partner's row: DBA Dash joins the partner INNER (:56), so a database
// whose partner it does not monitor has no row; pgvigil keeps the row with the partner's columns empty. The partner:
// the active instance whose own server name (mssql_instance.server_name) is this row's partner_instance; for a
// values_hidden mirror (partner_instance NULL) the other way round - the instance whose row of that database names
// this instance's server name as its partner. pgvigil's own columns after DBA Dash's (role sequence, queues, rates,
// the delay per write).
var sqlHADRMirroringDetail = `
WITH ` + hadrScope + `, ` + hadrReads("mssql_mirroring") + `
SELECT m.instance_id, sc.name AS instance, m.database_name,
       CASE WHEN coalesce(m.values_hidden, false) THEN NULL ELSE m.state_code END AS mirroring_state,
       CASE WHEN coalesce(m.values_hidden, false) THEN 'shown on the principal (this login is not sysadmin)' ELSE m.state END AS mirroring_state_desc,
       m.role AS mirroring_role_desc, m.safety_level AS mirroring_safety_level_desc,
       m.partner AS mirroring_partner_name, coalesce(m.partner_instance, p.server_name) AS mirroring_partner_instance,
       m.witness AS mirroring_witness_name,
       CASE upper(m.witness_state) WHEN 'UNKNOWN' THEN 0 WHEN 'CONNECTED' THEN 1 WHEN 'DISCONNECTED' THEN 2 END AS mirroring_witness_state,
       m.witness_state AS mirroring_witness_state_desc, m.connection_timeout_s AS mirroring_connection_timeout,
       p.state_code AS partner_mirroring_state, p.state AS partner_mirroring_state_desc, p.instance AS partner_monitored_as,
       rd.age_secs AS snapshot_age_secs, rd.snap_status AS snapshot_status,
       coalesce(m.values_hidden, false) AS values_hidden, m.role_sequence, m.log_send_queue_kb, m.redo_queue_kb,
       m.send_rate_kb_s, m.redo_rate_kb_s, m.txn_delay_ms
  FROM pgvigil.mssql_mirroring_state m
  JOIN sc ON sc.instance_id = m.instance_id
  LEFT JOIN pgvigil.mssql_instance me ON me.instance_id = m.instance_id
  LEFT JOIN rd ON rd.instance_id = m.instance_id
  LEFT JOIN LATERAL (
    SELECT o.state_code, o.state, i.name AS instance, oi.server_name
      FROM pgvigil.mssql_mirroring_state o
      JOIN pgvigil.instances i ON i.instance_id = o.instance_id AND i.is_active
      JOIN pgvigil.mssql_instance oi ON oi.instance_id = o.instance_id
     WHERE o.instance_id <> m.instance_id AND lower(o.database_name) = lower(m.database_name)
       AND CASE WHEN m.partner_instance IS NOT NULL THEN lower(oi.server_name) = lower(m.partner_instance)
                ELSE me.server_name IS NOT NULL AND lower(o.partner_instance) = lower(me.server_name) END
     ORDER BY o.snapshot_at DESC LIMIT 1) p ON true
 ORDER BY sc.name, m.database_name`

// Mirroring's role changes (the lead's D1: a grid of its own on the Mirroring tab, in the AG grid's shape):
// mssql_mirroring_role_changes, Changed After = that database's read before the change (mssql_mirroring_sample).
// Change: 'Became Principal' (MIRROR -> PRINCIPAL), 'No Longer Principal', else '<old> => <new> (role sequence a => b)'
// (the old principal's PRINCIPAL -> PRINCIPAL after a failover and back). Failover Type and Reason: no event source.
var sqlHADRMirroringRoleChanges = `
WITH ` + hadrScope + `
SELECT c.instance_id, sc.name AS instance, c.database_name, c.partner,
       CASE WHEN c.new_role = 'PRINCIPAL' AND c.old_role = 'MIRROR' THEN 'Became Principal'
            WHEN c.old_role = 'PRINCIPAL' AND c.new_role = 'MIRROR' THEN 'No Longer Principal'
            ELSE concat(coalesce(c.old_role, '?'), ' => ', coalesce(c.new_role, '?'),
                        CASE WHEN c.new_sequence IS NOT NULL THEN concat(' (role sequence ', coalesce(c.old_sequence::text, '?'), ' => ', c.new_sequence, ')') END) END AS change,
       c.old_role AS previous_role, c.new_role, b.snapshot_at AS changed_after, c.at AS changed_before,
       extract(epoch FROM c.at - b.snapshot_at)::bigint AS duration_s, 'Snapshot'::text AS source, c.state_after, c.witness_after
  FROM pgvigil.mssql_mirroring_role_changes c
  JOIN sc ON sc.instance_id = c.instance_id
  LEFT JOIN LATERAL (SELECT s.snapshot_at FROM pgvigil.mssql_mirroring_sample s
                      WHERE s.instance_id = c.instance_id AND s.database_name = c.database_name
                        AND s.snapshot_at < c.at AND s.snapshot_at > c.at - interval '1 hour'
                      ORDER BY s.snapshot_at DESC LIMIT 1) b ON true
 WHERE c.at >= $3::timestamptz AND coalesce(b.snapshot_at, c.at) < $4::timestamptz
 ORDER BY c.at DESC, sc.name, c.database_name`

// Log Shipping (LogShippingView.cs; LogShippingReport_Get.sql): every restoring database read from restore history
// and every log shipping copy that left (a 'pair' that is a stream), with its Status from pgvigil.mssql_logship_judged()
// - the same rows mssql_hadr_findings takes its log shipping findings from (the lead's D6): the worst finding of the
// database, else OK where the restore-history check judges it, else N/A with the reason. Mirrored, availability group
// and SIMPLE-recovery databases have no row (DBA Dash's LogShippingStatus.sql:116-117 leaves them out). The durations
// at now(), as DBA Dash (LogShippingStatus.sql:67-69): Time Since Last = now - restore, Latency of Last = restore -
// backup start, Total Time Behind = now - backup start (minutes). Snapshot Age's status in the detail: DBA Dash's
// fixed tiers (LogShippingReport_Get.sql:199: over 1440 min critical, over 120 warning, under 60 OK, else N/A).
var sqlHADRLogShippingRows = `
WITH ` + hadrScope + `, ` + hadrReads("mssql_logshipping") + `, j AS (
  SELECT * FROM pgvigil.mssql_logship_judged() WHERE role = 'secondary'
), db AS (
  SELECT s.instance_id, sc.name AS instance, s.database_name, s.kind, s.source_server, s.source_database, s.database_state,
         s.is_in_standby, s.created_at, s.last_log_restore_at, s.last_log_backup_start_at, s.last_file, s.snapshot_at,
         w.severity, w.checks, w.na_reason, w.judged_ok,
         extract(epoch FROM now() - s.last_log_restore_at) / 60 AS time_since_last_min,
         extract(epoch FROM s.last_log_restore_at - s.last_log_backup_start_at) / 60 AS latency_of_last_min,
         extract(epoch FROM now() - s.last_log_backup_start_at) / 60 AS total_time_behind_min,
         extract(epoch FROM now() - s.snapshot_at) / 60 AS snapshot_age_min,
         rd.snap_status AS collection_status,
         ta.level AS threshold_level, ta.tag AS threshold_tag, ta.warn AS age_warn, ta.crit AS age_crit,
         tl.level AS latency_level, tl.tag AS latency_tag, tl.warn AS latency_warn, tl.crit AS latency_crit,
         extract(epoch FROM now() - s.created_at)::bigint AS database_age_s,
         ms.primary_server AS msdb_primary_server
    FROM pgvigil.mssql_logrestore_state s
    JOIN sc ON sc.instance_id = s.instance_id
    LEFT JOIN rd ON rd.instance_id = s.instance_id
    LEFT JOIN LATERAL (SELECT CASE WHEN bool_or(j.severity = 'critical') THEN 'critical' WHEN bool_or(j.severity = 'warning') THEN 'warning' END AS severity,
                              string_agg(DISTINCT j.check_name, '; ') AS checks, max(j.na_reason) AS na_reason,
                              coalesce(bool_or(j.severity IS NULL AND j.na_reason IS NULL), false) AS judged_ok
                         FROM j WHERE j.instance_id = s.instance_id AND lower(j.database_name) = lower(s.database_name)) w ON true
    CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'logship_restore_age', s.database_name) ta
    CROSS JOIN LATERAL pgvigil.pg_threshold(s.instance_id, 'logship_restore_latency', s.database_name) tl
    LEFT JOIN LATERAL (SELECT m.primary_server FROM pgvigil.mssql_logshipping_state m
                        WHERE m.instance_id = s.instance_id AND m.role = 'secondary' AND lower(m.database_name) = lower(s.database_name)
                        LIMIT 1) ms ON true
   WHERE coalesce(w.na_reason, '') NOT IN ('mirrored', 'availability group', 'SIMPLE recovery')
     AND (s.kind = 'restore' OR w.severity IS NOT NULL)          -- a pair only where it is a stream: its finding (the lead's D4)
)
SELECT db.*,
       coalesce(db.severity, CASE WHEN db.judged_ok THEN 'ok' ELSE 'na' END) AS status,
       CASE WHEN db.severity IS NOT NULL OR db.judged_ok THEN NULL ELSE db.na_reason END AS excluded_by,
       db.kind = 'pair' AS is_missing,
       coalesce(db.na_reason = 'New Database', false) AS is_new_database,
       coalesce(db.source_server, db.msdb_primary_server) AS primary_server,
       (SELECT i.instance_id FROM pgvigil.mssql_instance mi JOIN pgvigil.instances i ON i.instance_id = mi.instance_id AND i.is_active
         WHERE lower(mi.server_name) = lower(coalesce(db.source_server, db.msdb_primary_server)) LIMIT 1) AS primary_instance_id,
       CASE WHEN db.snapshot_age_min > 1440 THEN 'critical' WHEN db.snapshot_age_min > 120 THEN 'warning'
            WHEN db.snapshot_age_min < 60 THEN 'ok' ELSE 'na' END AS snapshot_age_status
  FROM db`

var sqlHADRLogShippingDetail = `
SELECT * FROM (` + sqlHADRLogShippingRows + `) x
 WHERE $5::text[] IS NULL OR x.status = ANY ($5)
 ORDER BY CASE x.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'na' THEN 3 ELSE 4 END, x.total_time_behind_min DESC NULLS LAST,
          x.instance, x.database_name`

// LogShippingReport_Get.sql:80-177: per secondary instance, the worst non-N/A status (N/A where all are), the counts,
// and the durations and dates over the non-N/A rows; each key's threshold in force at the instance (Configure's
// dialogs; bold where either is the instance's own); ordered by the status's rank as DBA Dash (:177: 1 Critical,
// 2 Warning, 3 N/A, 4 OK), not its text.
var sqlHADRLogShippingSummary = `
SELECT g.*, ia.level AS age_level, ia.tag AS age_tag, ia.warn AS age_warn, ia.crit AS age_crit,
       il.level AS latency_level, il.tag AS latency_tag, il.warn AS latency_warn, il.crit AS latency_crit,
       (ia.level = 'instance' OR il.level = 'instance') AS instance_level_threshold
  FROM (
SELECT x.instance_id, x.instance,
       CASE min(CASE x.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'ok' THEN 4 END)
            WHEN 1 THEN 'critical' WHEN 2 THEN 'warning' WHEN 4 THEN 'ok' ELSE 'na' END AS status,
       string_agg(DISTINCT x.primary_server, ', ') AS primary_instances,
       count(*) FILTER (WHERE NOT x.is_missing AND x.status <> 'na') AS log_shipped_dbs,
       count(*) FILTER (WHERE x.status = 'warning') AS warning_count,
       count(*) FILTER (WHERE x.status = 'critical') AS critical_count,
       count(*) FILTER (WHERE x.is_missing AND x.status <> 'na') AS missing_count,
       count(*) FILTER (WHERE x.is_new_database) AS new_database_count,
       max(x.total_time_behind_min) FILTER (WHERE x.status <> 'na') AS max_total_time_behind_min,
       min(x.total_time_behind_min) FILTER (WHERE x.status <> 'na') AS min_total_time_behind_min,
       avg(x.total_time_behind_min) FILTER (WHERE x.status <> 'na') AS avg_total_time_behind_min,
       max(x.latency_of_last_min) FILTER (WHERE x.status <> 'na') AS max_latency_of_last_min,
       min(x.latency_of_last_min) FILTER (WHERE x.status <> 'na') AS min_latency_of_last_min,
       avg(x.latency_of_last_min) FILTER (WHERE x.status <> 'na') AS avg_latency_of_last_min,
       max(x.time_since_last_min) FILTER (WHERE x.status <> 'na') AS max_time_since_last_min,
       min(x.time_since_last_min) FILTER (WHERE x.status <> 'na') AS min_time_since_last_min,
       avg(x.time_since_last_min) FILTER (WHERE x.status <> 'na') AS avg_time_since_last_min,
       max(x.snapshot_age_min) AS snapshot_age_min, min(x.collection_status) AS collection_status,
       min(x.last_log_backup_start_at) FILTER (WHERE x.status <> 'na') AS backup_date_of_oldest_file,
       max(x.last_log_backup_start_at) FILTER (WHERE x.status <> 'na') AS backup_date_of_newest_file,
       min(x.last_log_restore_at) FILTER (WHERE x.status <> 'na') AS restore_date_of_oldest_file,
       max(x.last_log_restore_at) FILTER (WHERE x.status <> 'na') AS restore_date_of_newest_file,
       min(CASE x.status WHEN 'critical' THEN 1 WHEN 'warning' THEN 2 WHEN 'na' THEN 3 ELSE 4 END) AS status_rank
  FROM (` + sqlHADRLogShippingRows + `) x
 GROUP BY x.instance_id, x.instance) g
  CROSS JOIN LATERAL pgvigil.pg_threshold(g.instance_id, 'logship_restore_age') ia
  CROSS JOIN LATERAL pgvigil.pg_threshold(g.instance_id, 'logship_restore_latency') il
 ORDER BY g.status_rank, g.max_total_time_behind_min DESC NULLS LAST, g.instance`

// the two keys' rows (Configure's dialog: pg_backups.ts thresholdDialog) with the root's own live row of each (the
// toolbar's Thresholds (Root): NULL = the root has none, the default applies)
const sqlHADRLogShippingThresholds = `
SELECT k.key, k.label, k.unit, k.direction, k.warn_default, k.crit_default, k.levels, k.max_value,
       r.warn AS root_warn, r.crit AS root_crit, r.threshold_id IS NOT NULL AS root_own
  FROM pgvigil.pg_threshold_keys k
  LEFT JOIN LATERAL (SELECT t.warn, t.crit, t.threshold_id FROM pgvigil.pg_thresholds t
                      WHERE t.ended_at IS NULL AND t.key = k.key AND t.level = 'root' LIMIT 1) r ON true
 WHERE k.key IN ('logship_restore_age', 'logship_restore_latency') ORDER BY k.key`

// The Log Shipping page's panel below DBA Dash's two grids (task LSX, pgvigil's own): per instance in scope, log
// shipping's own jobs as its configuration names them (with the jobs collection's last run where a read of the last
// 15 minutes holds it), what its agents logged in the last 24 hours (the newest 20 per agent and database; a STANDBY
// copy's read-only rows flagged), how often a restore job found nothing to apply in the last hour, and the log
// backups taken outside log shipping. $1 / $2 the scope only.
// job_severity: the judge's own finding for that job (pgvigil.mssql_logship_judged(), matched by its object), so the
// panel colours a job only where Findings has it: a role change done Microsoft's way leaves disabled jobs that raise
// nothing, and the monitor's alert job is a warning, never a critical.
const sqlHADRLogShippingJobs = `
WITH ` + hadrScope + `, jf AS (
  SELECT j.instance_id, j.object, j.severity FROM pgvigil.mssql_logship_judged() j
   WHERE j.check_name IN ('a log shipping job is missing', 'a log shipping job is disabled')
)
SELECT c.instance_id, sc.name AS instance, c.role, nullif(c.database_name, '') AS database_name, c.job_role, c.job_name, c.job_id,
       c.job_exists, c.job_enabled, c.enabled_schedules, c.interval_min, c.recovery_model, c.restore_mode, c.backup_directory,
       c.primary_server, c.primary_database, mj.last_outcome, mj.last_run_at, c.snapshot_at,
       (SELECT max(jf.severity) FROM jf WHERE jf.instance_id = c.instance_id
           AND jf.object = c.role || CASE WHEN c.database_name <> '' THEN ' / ' || c.database_name ELSE '' END || ' / '
                           || coalesce(c.job_name, c.job_role || ' job ' || c.job_id)) AS job_severity
  FROM pgvigil.mssql_logship_config c
  JOIN sc ON sc.instance_id = c.instance_id
  LEFT JOIN pgvigil.mssql_jobs mj ON mj.instance_id = c.instance_id AND mj.job_id = c.job_id AND mj.snapshot_at > now() - interval '15 minutes'
 ORDER BY sc.name, c.database_name, CASE c.role WHEN 'primary' THEN 1 WHEN 'secondary' THEN 2 ELSE 3 END,
          CASE c.job_role WHEN 'backup' THEN 1 WHEN 'copy' THEN 2 WHEN 'restore' THEN 3 ELSE 4 END`

const sqlHADRLogShippingMessages = `
WITH ` + hadrScope + `
SELECT e.instance_id, sc.name AS instance, nullif(e.database_name, '') AS database_name, e.agent, e.logged_at, e.session_id,
       e.sequence_number, e.message, e.source, e.rows_24h, NULL::int AS idle_runs_1h, e.standby_noise, e.ord, e.snapshot_at
  FROM pgvigil.mssql_logship_errors e
  JOIN sc ON sc.instance_id = e.instance_id
UNION ALL
SELECT i.instance_id, sc.name, i.database_name, 'restore', i.last_at, NULL, NULL,
       format('Could not find a log backup file that could be applied to secondary database (%s time%s in the last hour after its last restore)',
              i.runs, CASE WHEN i.runs = 1 THEN '' ELSE 's' END),
       'the restore job''s history', NULL, i.runs, false, 0, i.snapshot_at
  FROM pgvigil.mssql_logship_idle i
  JOIN sc ON sc.instance_id = i.instance_id
 WHERE i.runs > 0
 ORDER BY 2, 3, 5 DESC NULLS LAST, 4, 13`

const sqlHADRLogShippingForeign = `
WITH ` + hadrScope + `
SELECT f.instance_id, sc.name AS instance, f.database_name, f.finished_at, f.started_at, f.file_name, f.device, f.backup_directory, f.snapshot_at
  FROM pgvigil.mssql_logship_foreign_logs f
  JOIN sc ON sc.instance_id = f.instance_id
 ORDER BY sc.name, f.database_name, f.finished_at DESC`

// hadrStatuses: the Log Shipping status filter's words (DBA Dash's Critical, Warning, N/A, OK; none = every box
// cleared: no Detail row)
var hadrStatuses = map[string]bool{"critical": true, "warning": true, "na": true, "ok": true, "none": true}

// hadrRange reads from / to for the event grids: the last 30 days by default (AG.cs:599), at most a year and a day.
func hadrRange(r *http.Request) (from, to time.Time, err error) {
	q := r.URL.Query()
	to = time.Now()
	if v := q.Get("to"); v != "" {
		if to, err = time.Parse(time.RFC3339, v); err != nil {
			return from, to, fmt.Errorf("to: %w", err)
		}
	}
	from = to.Add(-30 * 24 * time.Hour)
	if v := q.Get("from"); v != "" {
		if from, err = time.Parse(time.RFC3339, v); err != nil {
			return from, to, fmt.Errorf("from: %w", err)
		}
	}
	if !from.Before(to) {
		return from, to, errors.New("from must be before to")
	}
	if to.Sub(from) > maxWindow {
		return from, to, errors.New("window longer than a year (366 days and an hour)")
	}
	return from, to, nil
}

// MSSQLHADRFleet serves the HA/DR folder's SQL Server pages (task 383).
func (s *Server) MSSQLHADRFleet(w http.ResponseWriter, r *http.Request) {
	id, ids, err := storageScope(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	from, to, err := hadrRange(r)
	if err != nil {
		writeErr(w, http.StatusBadRequest, err)
		return
	}
	exp, err := json.Marshal(s.expected)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, err)
		return
	}
	// $1 / $2 the scope; a part with Snapshot Date / Age reads $3 / $4 (hadrReads), an event grid $3 / $4 as its range
	scope := []any{id, ids, string(exp), DefaultStaleSecs}
	events := func(more ...any) []any { return append([]any{id, ids, from, to}, more...) }
	switch r.URL.Query().Get("page") {
	case "ag":
		if id > 0 {
			s.multiPart(w, r, []part{
				{"detail", sqlHADRAgDetail, scope},
				{"role_changes", sqlHADRAgRoleChanges, events(true)},
				{"health_events", sqlHADRAgHealthEvents, events()},
			})
			return
		}
		s.multiPart(w, r, []part{
			{"summary", sqlHADRAgSummary, scope},
			{"role_changes", sqlHADRAgRoleChanges, events(false)},
		})
	case "mirroring":
		s.multiPart(w, r, []part{
			{"summary", sqlHADRMirroringSummary, scope},
			{"detail", sqlHADRMirroringDetail, scope},
			{"role_changes", sqlHADRMirroringRoleChanges, events()},
		})
	case "logshipping":
		var statuses []string
		if v := r.URL.Query().Get("status"); v != "" && v != "all" {
			for _, f := range splitList(v) {
				if !hadrStatuses[f] {
					writeErr(w, http.StatusBadRequest, errors.New("status must be all, none, or critical, warning, na and ok separated by commas"))
					return
				}
				statuses = append(statuses, f)
			}
		}
		s.multiPart(w, r, []part{
			{"summary", sqlHADRLogShippingSummary, scope},
			{"detail", sqlHADRLogShippingDetail, append(append([]any{}, scope...), statuses)},
			{"thresholds", sqlHADRLogShippingThresholds, nil},
			{"jobs", sqlHADRLogShippingJobs, []any{id, ids}},
			{"messages", sqlHADRLogShippingMessages, []any{id, ids}},
			{"foreign", sqlHADRLogShippingForeign, []any{id, ids}},
		})
	default:
		writeErr(w, http.StatusBadRequest, errors.New("page must be ag, mirroring or logshipping"))
	}
}
