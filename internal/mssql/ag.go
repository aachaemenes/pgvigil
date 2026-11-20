package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/repo"
)

// The HA/DR, Agent jobs and backups collections (mssql_ag, mssql_mirroring, mssql_logshipping, mssql_replication,
// mssql_jobs, mssql_backups) share what is in this file: the UTC conversion every one of them does on the SQL
// Server side, the version gate, and the thresholds' door to the repository.

// utcText is the SELECT expression that turns a column written in the server's local clock into UTC text ending in
// Z, by the offset the server has at the read (QueryRows' contract: no zone-less text is stored as an instant). A
// NULL column stays NULL. The offset is one value read once (the difference of two clock reads can straddle a
// minute and come out one minute off).
func utcText(col string) string {
	return "CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), " + col + "), 126) + 'Z'"
}

// isUTCText is utcText for a column the server already keeps in UTC.
func isUTCText(col string) string { return "CONVERT(varchar(33), " + col + ", 126) + 'Z'" }

// atLeast says whether the server has what SQL Server <major> added. Azure SQL Managed Instance reports product
// version 12 and has the current engine's catalog.
func atLeast(info Info, major int) bool {
	return info.Kind == KindAzureMI || info.Major >= major
}

// colOr returns the column when the version has it, else a typed NULL under the same name.
func colOr(have bool, expr, sqlType, alias string) string {
	if have {
		return expr + " AS " + alias
	}
	return "CAST(NULL AS " + sqlType + ") AS " + alias
}

// noRows is what a collection hands over when it read nothing: an empty JSON array, so its import still runs and
// clears what an earlier read stored.
func noRows() []collect.Row { return []collect.Row{} }

// HADRCollections are the collections whose findings read pgvigil.mssql_hadr_thresholds.
var HADRCollections = map[string]bool{
	Prefix + "ag": true, Prefix + "mirroring": true, Prefix + "logshipping": true,
	Prefix + "replication": true, Prefix + "jobs": true, Prefix + "backups": true,
}

// HADRThresholds lists the configuration's threshold names with their defaults (the defaults themselves live in
// the repository's view pgvigil.mssql_hadr_limits; TestThresholdDefaults holds the two lists together).
var HADRThresholds = map[string]float64{
	"log_send_queue_kb":           102400, // 100 MB waiting to be sent, in every read of five minutes
	"redo_queue_kb":               512000, // 500 MB waiting to be redone, in every read of five minutes
	"repl_undistributed_commands": 100000,
	"job_failed_hours":            24,
	"job_long_factor":             3,   // a running job at this many times its average duration ...
	"job_long_min_seconds":        300, // ... and at least this far past it
	"full_backup_hours":           168,
	"diff_backup_hours":           0, // 0 = differential backups are not judged
	"log_backup_minutes":          60,
	"new_database_hours":          24,
	"nul_backup_days":             7,
}

// ThresholdRows turns an instance's thresholds as the configuration gives them (name: number, and backup_exclude:
// a list of LIKE patterns of database names whose backups are not judged) into the one-row payload of
// pgvigil.import_mssql_hadr_thresholds. An unknown name or a negative number is an error here, before any write.
// The identity rule's two lines (IdentityThresholds) live in the same block and are the collection's own: checked
// here with the rest, never written to the threshold store.
func ThresholdRows(t map[string]any) ([]collect.Row, error) {
	if _, _, err := IdentityLimits(t); err != nil {
		return nil, err
	}
	row := collect.Row{}
	names := make([]string, 0, len(t))
	for k := range t {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		v := t[k]
		if k == "backup_exclude" {
			pats, err := stringList(v)
			if err != nil {
				return nil, fmt.Errorf("mssql threshold backup_exclude: %w", err)
			}
			row[k] = pats
			continue
		}
		if _, identity := IdentityThresholds[k]; identity {
			continue
		}
		if _, known := HADRThresholds[k]; !known {
			return nil, fmt.Errorf("mssql threshold %q is not known; known: %s, backup_exclude, identity_warn_pct, identity_crit_pct", k, strings.Join(thresholdNames(), ", "))
		}
		n, ok := number(v)
		if !ok || n < 0 {
			return nil, fmt.Errorf("mssql threshold %s: %v is not a number of 0 or more", k, v)
		}
		row[k] = n
	}
	return []collect.Row{row}, nil
}

func thresholdNames() []string {
	out := make([]string, 0, len(HADRThresholds))
	for k := range HADRThresholds {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func number(v any) (float64, bool) {
	switch x := v.(type) {
	case int:
		return float64(x), true
	case int64:
		return float64(x), true
	case uint64:
		return float64(x), true
	case float64:
		return x, true
	}
	return 0, false
}

func stringList(v any) ([]string, error) {
	switch x := v.(type) {
	case nil:
		return []string{}, nil
	case string:
		return []string{x}, nil
	case []string:
		return x, nil
	case []any:
		out := make([]string, 0, len(x))
		for _, e := range x {
			s, ok := e.(string)
			if !ok || strings.TrimSpace(s) == "" {
				return nil, fmt.Errorf("%v is not a pattern", e)
			}
			out = append(out, s)
		}
		return out, nil
	}
	return nil, fmt.Errorf("%v is not a list of patterns", v)
}

// StoreHADRThresholds writes an instance's thresholds to the repository before a run of one of the HADRCollections
// (any other collection: nothing happens). RunOnce calls it with the instance's configuration block; an empty or
// missing block stores the defaults.
func StoreHADRThresholds(ctx context.Context, r *repo.Repo, instanceID int, collection string, at time.Time, t map[string]any) error {
	if !HADRCollections[collection] {
		return nil
	}
	rows, err := ThresholdRows(t)
	if err != nil {
		return err
	}
	return r.Import(ctx, instanceID, Prefix+"hadr_thresholds", at, rows)
}

// agCollector is mssql_ag: Always On availability groups as the instance sees them. A primary sees every replica
// and every database replica of its groups; a secondary sees its own rows and the group's primary by name. A
// clusterless group is read like any other.
//
// A distributed group's "replicas" are its two member groups, by name, and only the primary of each member group
// lists them (a secondary's catalog names the distributed group and none of its replicas, so nothing of it is read
// there). Its database rows exist on the global primary alone: one per database, for the other member group, with
// the queues and the lag of the link. The forwarder has no such row; what it received is on its own group's row.
// Read on SQL Server 2022 (scripts/proof-mssql-dag.sh).
type agCollector struct{}

func init() { Register(agCollector{}) }

func (agCollector) Name() string                   { return Prefix + "ag" }
func (agCollector) DefaultInterval() time.Duration { return time.Minute }
func (agCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "Azure SQL Database has no availability group to read"
	case !info.HADREnabled:
		return false, "Always On is not enabled on this server"
	case !info.ViewServerState:
		return false, "the login lacks VIEW SERVER STATE (the sys.dm_hadr_* views)"
	case !info.ViewAnyDefinition:
		return false, "the login lacks VIEW ANY DEFINITION (sys.availability_groups lists no group without it)"
	}
	return true, ""
}

// agReplicaSQL: one row per replica of every group, the group's own columns on each (SQL Server 2016 SP1 and later;
// cluster_type and required_synchronized_secondaries_to_commit from 2017, is_contained from 2022). join_state is the
// replica's own word on whether its server joined the group (NOT_JOINED: added on the primary, never joined there);
// read_only_routing_url is where read-intent connections routed to the replica go.
func agReplicaSQL(info Info) string {
	return `SELECT 'replica' AS kind,
  ag.group_id, CAST(ag.name AS nvarchar(128)) AS group_name,
  ` + colOr(atLeast(info, 14), "CAST(ag.cluster_type_desc AS nvarchar(60))", "nvarchar(60)", "cluster_type") + `,
  CAST(ag.is_distributed AS int) AS is_distributed,
  ` + colOr(atLeast(info, 16), "CAST(ag.is_contained AS int)", "int", "is_contained") + `,
  CAST(ag.automated_backup_preference_desc AS nvarchar(60)) AS backup_preference,
  CAST(ag.db_failover AS int) AS db_failover,
  ag.failure_condition_level, ag.health_check_timeout AS health_check_timeout_ms,
  ` + colOr(atLeast(info, 14), "ag.required_synchronized_secondaries_to_commit", "int", "required_sync_secondaries") + `,
  CAST(ags.primary_replica AS nvarchar(256)) AS primary_replica,
  CAST(ags.synchronization_health_desc AS nvarchar(60)) AS group_health,
  ar.replica_id, CAST(ar.replica_server_name AS nvarchar(256)) AS replica_server,
  CAST(ar.endpoint_url AS nvarchar(256)) AS endpoint_url,
  CAST(ar.availability_mode_desc AS nvarchar(60)) AS availability_mode,
  CAST(ar.failover_mode_desc AS nvarchar(60)) AS failover_mode,
  CAST(ar.seeding_mode_desc AS nvarchar(60)) AS seeding_mode,
  CAST(ar.secondary_role_allow_connections_desc AS nvarchar(60)) AS secondary_connections,
  CAST(ar.primary_role_allow_connections_desc AS nvarchar(60)) AS primary_connections,
  CAST(ar.read_only_routing_url AS nvarchar(256)) AS read_only_routing_url,
  CAST(rcs.join_state_desc AS nvarchar(60)) AS join_state,
  ar.backup_priority, ar.session_timeout,
  CAST(COALESCE(ars.is_local, CASE WHEN ar.replica_server_name = @@SERVERNAME THEN 1 ELSE 0 END) AS int) AS is_local,
  CAST(ars.role_desc AS nvarchar(60)) AS role,
  CAST(ars.operational_state_desc AS nvarchar(60)) AS operational_state,
  CAST(ars.connected_state_desc AS nvarchar(60)) AS connected_state,
  CAST(ars.recovery_health_desc AS nvarchar(60)) AS recovery_health,
  CAST(ars.synchronization_health_desc AS nvarchar(60)) AS synchronization_health,
  ars.last_connect_error_number AS last_connect_error,
  CAST(LEFT(ars.last_connect_error_description, 1000) AS nvarchar(1000)) AS last_connect_error_text,
  ` + utcText("ars.last_connect_error_timestamp") + ` AS last_connect_error_utc
FROM sys.availability_groups ag
JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_group_states ags ON ags.group_id = ag.group_id
LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id
LEFT JOIN sys.dm_hadr_availability_replica_cluster_states rcs ON rcs.replica_id = ar.replica_id
ORDER BY ag.name, ar.replica_server_name`
}

// agDatabaseSQL: one row per database replica the instance sees. The estimates are the two the documentation of
// sys.dm_hadr_database_replica_states gives ("Monitor performance for Always On availability groups"): the
// recovery time is the redo queue over the redo rate; the data loss is the primary's last commit time less the
// secondary's, which only the primary can compute (it alone sees both rows). A secondary that has redone no commit yet
// (its last_commit_time NULL) gets no estimate here; the repository measures it from its last hardened time against
// the primary's row of the same read, as sp_Blitz's check 268 does. A distributed group has no row for its
// primary side (the global primary sees the other member group's row only), so there the primary's last commit is
// taken from the database's own row in the local member group (own): without it the link's data loss was never
// estimated. SQL Server 2016 SP1 and later.
var agDatabaseSQL = `SELECT 'database' AS kind,
  drs.group_id, CAST(ag.name AS nvarchar(128)) AS group_name,
  CAST(ar.replica_server_name AS nvarchar(256)) AS replica_server,
  CAST(COALESCE(adc.database_name, DB_NAME(drs.database_id)) AS nvarchar(128)) AS database_name,
  CAST(drs.is_local AS int) AS is_local, CAST(drs.is_primary_replica AS int) AS is_primary_replica,
  CAST(drs.synchronization_state_desc AS nvarchar(60)) AS synchronization_state,
  CAST(drs.synchronization_health_desc AS nvarchar(60)) AS synchronization_health,
  CAST(drs.database_state_desc AS nvarchar(60)) AS database_state,
  CAST(drs.is_suspended AS int) AS is_suspended,
  CAST(drs.suspend_reason_desc AS nvarchar(60)) AS suspend_reason,
  drs.log_send_queue_size AS log_send_queue_kb, drs.log_send_rate AS log_send_rate_kb_s,
  drs.redo_queue_size AS redo_queue_kb, drs.redo_rate AS redo_rate_kb_s,
  CASE WHEN drs.redo_rate > 0 THEN CAST(drs.redo_queue_size AS float) / drs.redo_rate END AS est_recovery_s,
  CASE WHEN drs.is_primary_replica = 1 OR COALESCE(p.last_commit_time, own.last_commit_time) IS NULL OR drs.last_commit_time IS NULL THEN NULL
       WHEN drs.last_commit_time >= COALESCE(p.last_commit_time, own.last_commit_time) THEN 0
       WHEN DATEDIFF(day, drs.last_commit_time, COALESCE(p.last_commit_time, own.last_commit_time)) > 20000 THEN NULL
       ELSE DATEDIFF(second, drs.last_commit_time, COALESCE(p.last_commit_time, own.last_commit_time)) END AS est_data_loss_s,
  drs.secondary_lag_seconds AS secondary_lag_s,
  ` + utcText("drs.last_sent_time") + ` AS last_sent_utc,
  ` + utcText("drs.last_received_time") + ` AS last_received_utc,
  ` + utcText("drs.last_hardened_time") + ` AS last_hardened_utc,
  ` + utcText("drs.last_redone_time") + ` AS last_redone_utc,
  ` + utcText("drs.last_commit_time") + ` AS last_commit_utc
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
LEFT JOIN sys.availability_databases_cluster adc ON adc.group_id = drs.group_id AND adc.group_database_id = drs.group_database_id
LEFT JOIN sys.dm_hadr_database_replica_states p
       ON p.group_id = drs.group_id AND p.group_database_id = drs.group_database_id AND p.is_primary_replica = 1
LEFT JOIN sys.dm_hadr_database_replica_states own
       ON ag.is_distributed = 1 AND drs.is_local = 0 AND own.database_id = drs.database_id
      AND own.group_id <> drs.group_id AND own.is_local = 1 AND own.is_primary_replica = 1
ORDER BY ag.name, ar.replica_server_name, 5`

// agDatabaseClusterSQL: per database of a group and replica, whether the database joined the group there and whether
// it is ready for a failover (sys.dm_hadr_database_replica_cluster_states; it lists the replicas a database is NOT
// joined on too, which sys.dm_hadr_database_replica_states does not). SQL Server 2016 SP1 and later.
const agDatabaseClusterSQL = `SELECT 'db_cluster' AS kind, ar.group_id, CAST(ag.name AS nvarchar(128)) AS group_name,
  CAST(ar.replica_server_name AS nvarchar(256)) AS replica_server, CAST(dcs.database_name AS nvarchar(128)) AS database_name,
  CAST(dcs.is_failover_ready AS int) AS is_failover_ready, CAST(dcs.is_database_joined AS int) AS is_database_joined,
  CAST(dcs.is_pending_secondary_suspend AS int) AS is_pending_secondary_suspend
FROM sys.dm_hadr_database_replica_cluster_states dcs
JOIN sys.availability_replicas ar ON ar.replica_id = dcs.replica_id
JOIN sys.availability_groups ag ON ag.group_id = ar.group_id
WHERE ag.is_distributed = 0
ORDER BY ag.name, ar.replica_server_name, dcs.database_name`

// agRoutingSQL: the read-only routing list of each replica, in priority order (an entry of one priority shares the
// load with its siblings).
const agRoutingSQL = `SELECT 'routing' AS kind, ar.group_id, CAST(ar.replica_server_name AS nvarchar(256)) AS replica_server,
  rl.routing_priority, CAST(rr.replica_server_name AS nvarchar(256)) AS read_only_replica
FROM sys.availability_read_only_routing_lists rl
JOIN sys.availability_replicas ar ON ar.replica_id = rl.replica_id
JOIN sys.availability_replicas rr ON rr.replica_id = rl.read_only_replica_id
ORDER BY ar.replica_server_name, rl.routing_priority, rr.replica_server_name`

// agSeedingSQL: the newest automatic seeding of each database and remote replica in the last 7 days as this server
// saw it (sys.dm_hadr_automatic_seeding keeps its rows until the instance restarts), with the transfer's progress
// from sys.dm_hadr_physical_seeding_stats while one runs. Times are the server's local clock, converted here.
var agSeedingSQL = `WITH s AS (
  SELECT a.ag_id, a.ag_db_id, a.ag_remote_replica_id, a.is_source, a.current_state, a.failure_state_desc, a.error_code,
         a.number_of_attempts, a.start_time, a.completion_time, a.operation_id,
         ROW_NUMBER() OVER (PARTITION BY a.ag_id, a.ag_db_id, a.ag_remote_replica_id ORDER BY a.start_time DESC) AS rn
    FROM sys.dm_hadr_automatic_seeding a
   WHERE a.start_time > DATEADD(day, -7, GETDATE()))
SELECT 'seeding' AS kind, s.ag_id AS group_id, CAST(ag.name AS nvarchar(128)) AS group_name,
  CAST(COALESCE(adc.database_name, CONVERT(nvarchar(40), s.ag_db_id)) AS nvarchar(128)) AS database_name,
  CAST(rr.replica_server_name AS nvarchar(256)) AS remote_replica, CAST(s.is_source AS int) AS is_source,
  CAST(s.current_state AS nvarchar(60)) AS seeding_state, CAST(s.failure_state_desc AS nvarchar(120)) AS failure_state,
  s.error_code, s.number_of_attempts,
  ` + utcText("s.start_time") + ` AS start_utc,
  ` + utcText("s.completion_time") + ` AS completion_utc,
  ps.transferred_size_bytes, ps.database_size_bytes,
  CONVERT(varchar(33), ps.estimate_time_complete_utc, 126) + 'Z' AS estimate_complete_utc
FROM s
JOIN sys.availability_groups ag ON ag.group_id = s.ag_id
LEFT JOIN sys.availability_databases_cluster adc ON adc.group_id = s.ag_id AND adc.group_database_id = s.ag_db_id
LEFT JOIN sys.availability_replicas rr ON rr.replica_id = s.ag_remote_replica_id
LEFT JOIN sys.dm_hadr_physical_seeding_stats ps ON ps.remote_physical_seeding_id = s.operation_id OR ps.local_physical_seeding_id = s.operation_id
WHERE s.rn = 1
ORDER BY ag.name, 4, 5`

// agEndpointSQL: the instance's database mirroring endpoint, the one an availability group's replicas connect through.
const agEndpointSQL = mirroringEndpointSQL

// agCountersSQL: the cumulative counters of the two availability group objects (each with its cntr_type, so the
// repository takes a difference only of a cumulative one): per replica this server talks to (Availability Replica,
// instance_name = the replica, '_Total' left out) flow control and resent messages; per local database (Database
// Replica, instance_name = the database) its flow control and the redo that was blocked. Rates come from two reads.
const agCountersSQL = `SELECT CASE WHEN pc.object_name LIKE '%:Availability Replica%' THEN 'replica_counters' ELSE 'db_counters' END AS kind,
  CAST(RTRIM(pc.instance_name) AS nvarchar(256)) AS counter_instance,
  MAX(CASE WHEN RTRIM(pc.counter_name) = 'Flow Control Time (ms/sec)' THEN pc.cntr_value END) AS flow_control_ms_total,
  MAX(CASE WHEN RTRIM(pc.counter_name) = 'Flow Control/sec' THEN pc.cntr_value END) AS flow_controls_total,
  MAX(CASE WHEN RTRIM(pc.counter_name) = 'Resent Messages/sec' THEN pc.cntr_value END) AS resent_messages_total,
  MAX(CASE WHEN RTRIM(pc.counter_name) = 'Database Flow Control Delay' THEN pc.cntr_value END) AS db_flow_control_delay_total,
  MAX(CASE WHEN RTRIM(pc.counter_name) = 'Database Flow Controls/sec' THEN pc.cntr_value END) AS db_flow_controls_total,
  MAX(CASE WHEN RTRIM(pc.counter_name) = 'Redo blocked/sec' THEN pc.cntr_value END) AS redo_blocked_total,
  MAX(CASE WHEN RTRIM(pc.counter_name) IN ('Flow Control Time (ms/sec)', 'Database Flow Control Delay') THEN pc.cntr_type END) AS flow_control_type,
  MAX(CASE WHEN RTRIM(pc.counter_name) IN ('Flow Control/sec', 'Database Flow Controls/sec') THEN pc.cntr_type END) AS flow_controls_type,
  MAX(CASE WHEN RTRIM(pc.counter_name) IN ('Resent Messages/sec', 'Redo blocked/sec') THEN pc.cntr_type END) AS third_type
FROM sys.dm_os_performance_counters pc
WHERE (pc.object_name LIKE '%:Availability Replica%' OR pc.object_name LIKE '%:Database Replica%')
  AND RTRIM(pc.instance_name) NOT IN ('', '_Total')
GROUP BY CASE WHEN pc.object_name LIKE '%:Availability Replica%' THEN 'replica_counters' ELSE 'db_counters' END, RTRIM(pc.instance_name)
ORDER BY 1, 2`

// agHealthSessionSQL: the AlwaysOn_health event session (dbachecks' HADR checks: it exists, runs and starts with the
// server); pgvigil's own reader of its events (mssql_xe) needs it running.
const agHealthSessionSQL = `SELECT 'health_session' AS kind,
  CAST(CASE WHEN es.name IS NULL THEN 0 ELSE 1 END AS int) AS session_exists,
  CAST(CASE WHEN xs.name IS NULL THEN 0 ELSE 1 END AS int) AS session_running,
  CAST(es.startup_state AS int) AS session_autostart
FROM (SELECT 1 AS one) x
LEFT JOIN sys.server_event_sessions es ON es.name = 'AlwaysOn_health'
LEFT JOIN sys.dm_xe_sessions xs ON xs.name = 'AlwaysOn_health'`

const agListenerSQL = `SELECT 'listener' AS kind, l.group_id, CAST(l.dns_name AS nvarchar(63)) AS dns_name, l.port,
  CAST(l.ip_configuration_string_from_cluster AS nvarchar(1000)) AS ip_configuration
FROM sys.availability_group_listeners l
ORDER BY l.dns_name`

// the Windows cluster under the groups, where there is one and the login may read it (a Linux server without a
// cluster answers with one row: itself, under an empty cluster name)
const agClusterSQL = `SELECT 'cluster_member' AS kind, CAST(c.cluster_name AS nvarchar(128)) AS cluster_name,
  CAST(c.quorum_type_desc AS nvarchar(60)) AS quorum_type, CAST(c.quorum_state_desc AS nvarchar(60)) AS quorum_state,
  CAST(m.member_name AS nvarchar(128)) AS member_name, CAST(m.member_type_desc AS nvarchar(60)) AS member_type,
  CAST(m.member_state_desc AS nvarchar(60)) AS member_state, m.number_of_quorum_votes AS quorum_votes
FROM sys.dm_hadr_cluster_members m CROSS JOIN sys.dm_hadr_cluster c
ORDER BY m.member_name`

func (agCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, agReplicaSQL(info))
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return noRows(), nil
	}
	dbs, err := QueryRows(ctx, conn, agDatabaseSQL)
	if err != nil {
		return nil, err
	}
	rows = append(rows, dbs...)
	// the gaps reads (item 5): a statement that fails is a note on the read, never the read's failure
	for _, part := range []struct{ source, query string }{
		{"sys.dm_hadr_database_replica_cluster_states", agDatabaseClusterSQL},
		{"sys.availability_read_only_routing_lists", agRoutingSQL},
		{"sys.dm_hadr_automatic_seeding", agSeedingSQL},
		{"sys.database_mirroring_endpoints", agEndpointSQL},
		{"sys.dm_os_performance_counters", agCountersSQL},
		{"sys.server_event_sessions", agHealthSessionSQL},
	} {
		got, err := QueryRows(ctx, conn, part.query)
		if err != nil {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": part.source, "message": err.Error()})
			continue
		}
		rows = append(rows, got...)
	}
	ls, err := QueryRows(ctx, conn, agListenerSQL)
	if err != nil {
		return append(rows, collect.Row{"kind": "collector_error", "source": "sys.availability_group_listeners", "message": err.Error()}), nil
	}
	rows = append(rows, ls...)
	// "where readable": a server whose cluster views cannot be read keeps its groups and says so in the state row
	cm, err := QueryRows(ctx, conn, agClusterSQL)
	if err != nil {
		return append(rows, collect.Row{"kind": "cluster_unread", "message": err.Error()}), nil
	}
	return append(rows, cm...), nil
}
