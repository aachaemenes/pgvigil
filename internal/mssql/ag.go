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
// NULL column stays NULL.
func utcText(col string) string {
	return "CONVERT(varchar(33), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), " + col + "), 126) + 'Z'"
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
func ThresholdRows(t map[string]any) ([]collect.Row, error) {
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
		if _, known := HADRThresholds[k]; !known {
			return nil, fmt.Errorf("mssql threshold %q is not known; known: %s, backup_exclude", k, strings.Join(thresholdNames(), ", "))
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
// clusterless group is read like any other; a distributed group's "replicas" are its two member groups, by name.
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
// cluster_type and required_synchronized_secondaries_to_commit from 2017, is_contained from 2022).
func agReplicaSQL(info Info) string {
	return `SELECT 'replica' AS kind,
  ag.group_id, CAST(ag.name AS nvarchar(128)) AS group_name,
  ` + colOr(atLeast(info, 14), "CAST(ag.cluster_type_desc AS nvarchar(60))", "nvarchar(60)", "cluster_type") + `,
  CAST(ag.is_distributed AS int) AS is_distributed,
  ` + colOr(atLeast(info, 16), "CAST(ag.is_contained AS int)", "int", "is_contained") + `,
  CAST(ag.automated_backup_preference_desc AS nvarchar(60)) AS backup_preference,
  CAST(ag.db_failover AS int) AS db_failover,
  ` + colOr(atLeast(info, 14), "ag.required_synchronized_secondaries_to_commit", "int", "required_sync_secondaries") + `,
  CAST(ags.primary_replica AS nvarchar(256)) AS primary_replica,
  CAST(ags.synchronization_health_desc AS nvarchar(60)) AS group_health,
  ar.replica_id, CAST(ar.replica_server_name AS nvarchar(256)) AS replica_server,
  CAST(ar.endpoint_url AS nvarchar(256)) AS endpoint_url,
  CAST(ar.availability_mode_desc AS nvarchar(60)) AS availability_mode,
  CAST(ar.failover_mode_desc AS nvarchar(60)) AS failover_mode,
  CAST(ar.seeding_mode_desc AS nvarchar(60)) AS seeding_mode,
  CAST(ar.secondary_role_allow_connections_desc AS nvarchar(60)) AS secondary_connections,
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
ORDER BY ag.name, ar.replica_server_name`
}

// agDatabaseSQL: one row per database replica the instance sees. The estimates are the two the documentation of
// sys.dm_hadr_database_replica_states gives ("Monitor performance for Always On availability groups"): the
// recovery time is the redo queue over the redo rate; the data loss is the primary's last commit time less the
// secondary's, which only the primary can compute (it alone sees both rows). SQL Server 2016 SP1 and later.
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
  CASE WHEN drs.is_primary_replica = 1 OR p.last_commit_time IS NULL OR drs.last_commit_time IS NULL THEN NULL
       WHEN drs.last_commit_time >= p.last_commit_time THEN 0
       WHEN DATEDIFF(day, drs.last_commit_time, p.last_commit_time) > 20000 THEN NULL
       ELSE DATEDIFF(second, drs.last_commit_time, p.last_commit_time) END AS est_data_loss_s,
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
ORDER BY ag.name, ar.replica_server_name, 5`

const agListenerSQL = `SELECT 'listener' AS kind, l.group_id, CAST(l.dns_name AS nvarchar(63)) AS dns_name, l.port,
  CAST(l.ip_configuration_string_from_cluster AS nvarchar(1000)) AS ip_configuration
FROM sys.availability_group_listeners l
ORDER BY l.dns_name`

// the Windows cluster under the groups, where there is one and the login may read it (a clusterless group and a
// Linux server return no row)
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
