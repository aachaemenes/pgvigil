package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// servicesCollector is mssql_services: is SQL Server Agent running, is Database Mail started, has the server written
// a memory dump - three columns of DBA Dash's Summary (its SQLServerExtraProperties.sql, MIT, is where the three
// reads and the Agent's session name come from; the statements here are pgvigil's own).
//
// Needs VIEW SERVER STATE (on SQL Server 2022 and later that right carries VIEW SERVER SECURITY STATE and VIEW
// SERVER PERFORMANCE STATE, which the two DMVs ask for). Not on Azure SQL Database: it has no Agent, no Database
// Mail and no dump files of its own. A part the server refuses is named in a collector_error row and the rest is
// stored (a partial run).
type servicesCollector struct{}

func init() { Register(servicesCollector{}) }

func (servicesCollector) Name() string                   { return Prefix + "services" }
func (servicesCollector) DefaultInterval() time.Duration { return 5 * time.Minute }

func (servicesCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not on Azure SQL Database (no SQL Server Agent, no Database Mail, no memory dump files to read)"
	case !info.ViewServerState:
		return false, "the login lacks VIEW SERVER STATE: the services, the Agent's sessions and the memory dumps are not readable"
	}
	return true, ""
}

// serviceListSQL: the services the server lists. On Linux that is the Agent alone; a server that lists none
// (or refuses the view) leaves the Agent's state to its sessions.
const serviceListSQL = `SELECT 'service' AS kind, CAST(servicename AS nvarchar(256)) AS service_name,
  CAST(startup_type_desc AS nvarchar(256)) AS startup_type, CAST(status_desc AS nvarchar(256)) AS status, process_id,
  CONVERT(varchar(34), SWITCHOFFSET(last_startup_time, '+00:00'), 127) AS last_startup_at_utc,
  CAST(service_account AS nvarchar(256)) AS service_account, CAST(is_clustered AS nvarchar(1)) AS is_clustered,
  CAST(instant_file_initialization_enabled AS nvarchar(1)) AS ifi_enabled
FROM sys.dm_server_services`

// agentSQL: the Agent's own sessions (it names them 'SQLAgent - <what>') and the edition (Express has no Agent).
const agentSQL = `SELECT 'agent' AS kind,
  (SELECT COUNT(*) FROM sys.dm_exec_sessions WHERE program_name LIKE 'SQLAgent - %') AS sessions,
  CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition`

// dbmailSQL: msdb.dbo.sysmail_help_status_sp answers STARTED when the queue ExternalMailQueue receives; the
// procedure itself asks for CONTROL SERVER or db_owner in msdb, so its one catalog read is made here instead
// (visible with VIEW ANY DEFINITION, or as a user of msdb with VIEW DEFINITION). queues_seen 0 = the login cannot
// see the queue: the state is then unknown, never STOPPED. Read only when Database Mail is switched on.
const dbmailSQL = `SELECT 'dbmail' AS kind,
  CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'Database Mail XPs') AS int) AS xps_in_use,
  (SELECT COUNT(*) FROM msdb.sys.service_queues WHERE name = N'ExternalMailQueue') AS queues_seen,
  (SELECT COUNT(*) FROM msdb.sys.service_queues WHERE name = N'ExternalMailQueue' AND is_receive_enabled = 1) AS receive_enabled`

// dbmailOffSQL: the same row without touching msdb, for a login that has no access to it.
const dbmailOffSQL = `SELECT 'dbmail' AS kind,
  CAST((SELECT value_in_use FROM sys.configurations WHERE name = 'Database Mail XPs') AS int) AS xps_in_use,
  0 AS queues_seen, 0 AS receive_enabled`

// dumpsSQL: the dump files the server lists. A file whose creation time the server cannot tell (SQL Server on
// Linux lists such a row with the year 1601) is counted and never dated.
const dumpsSQL = `SELECT 'dumps' AS kind, COUNT(*) AS dump_count,
  CONVERT(varchar(34), SWITCHOFFSET(MAX(CASE WHEN creation_time >= '2000-01-01' THEN creation_time END), '+00:00'), 127) AS last_dump_at_utc
FROM sys.dm_server_memory_dumps`

func (servicesCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, agentSQL)
	if err != nil {
		return nil, err
	}
	part := func(source, query string) {
		r, err := QueryRows(ctx, conn, query)
		if err != nil {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": source, "message": err.Error()})
			return
		}
		rows = append(rows, r...)
	}
	part("sys.dm_server_services", serviceListSQL)
	if info.MsdbAccess {
		part("msdb.sys.service_queues", dbmailSQL)
		// msdb lets every login in as guest, and a guest without VIEW ANY DEFINITION sees no queue: say so
		last := rows[len(rows)-1]
		on, _ := asInt(last["xps_in_use"])
		seen, ok := asInt(last["queues_seen"])
		if last["kind"] == "dbmail" && on == 1 && ok && seen == 0 {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": "msdb.sys.service_queues",
				"message": "Database Mail is switched on and the login cannot see its queue in msdb (VIEW ANY DEFINITION, or VIEW DEFINITION in msdb): started or stopped was not read"})
		}
	} else {
		part("sys.configurations", dbmailOffSQL)
		rows = append(rows, collect.Row{"kind": "collector_error", "source": "msdb.sys.service_queues",
			"message": "the login has no access to msdb: whether Database Mail is started was not read"})
	}
	part("sys.dm_server_memory_dumps", dumpsSQL)
	return rows, nil
}
