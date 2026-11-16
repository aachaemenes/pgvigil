package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// instanceCollector is mssql_instance: what the server says about itself (SERVERPROPERTY: readable by any login),
// its configuration values (sys.configurations: readable by any login) and, with VIEW SERVER STATE, the machine it
// sees (sys.dm_os_sys_info). Without that right the first two parts are still stored and the run is partial.
type instanceCollector struct{}

func init() { Register(instanceCollector{}) }

func (instanceCollector) Name() string                   { return Prefix + "instance" }
func (instanceCollector) DefaultInterval() time.Duration { return time.Hour }
func (instanceCollector) Applies(Info) (bool, string)    { return true, "" }

const serverSQL = `SELECT
  'server' AS kind,
  CAST(SERVERPROPERTY('MachineName') AS nvarchar(128)) AS machine_name,
  -- task 404 (0155): the node the instance runs on; a failover cluster's MachineName is its virtual name on every node
  CAST(SERVERPROPERTY('ComputerNamePhysicalNetBIOS') AS nvarchar(128)) AS physical_machine,
  CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS server_name,
  CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)) AS instance_name,
  CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edition,
  CAST(SERVERPROPERTY('EngineEdition') AS int) AS engine_edition,
  CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS product_version,
  CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS product_level,
  CAST(SERVERPROPERTY('ProductUpdateLevel') AS nvarchar(128)) AS product_update_level,
  CAST(SERVERPROPERTY('ProductUpdateReference') AS nvarchar(128)) AS product_update_reference,
  CAST(SERVERPROPERTY('Collation') AS nvarchar(128)) AS collation,
  CAST(SERVERPROPERTY('IsClustered') AS int) AS is_clustered,
  CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS is_hadr_enabled,
  CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS is_integrated_security_only`

const configSQL = `SELECT 'config' AS kind, CAST(name AS nvarchar(128)) AS name, CAST(value AS bigint) AS value,
  CAST(value_in_use AS bigint) AS value_in_use, CAST(minimum AS bigint) AS minimum, CAST(maximum AS bigint) AS maximum,
  CAST(is_dynamic AS int) AS is_dynamic, CAST(is_advanced AS int) AS is_advanced
FROM sys.configurations ORDER BY name`

// the start time: the server's UTC clock less the ticks since the start (sqlserver_start_time_ms_ticks, in seconds and
// milliseconds so no DATEADD argument passes an int). The DMV's sqlserver_start_time is local: moved to UTC by today's
// offset it was an hour off after every daylight-saving change, a false restart to 0155's events (task 404, F5).
const sysinfoSQL = `SELECT 'sysinfo' AS kind, cpu_count, hyperthread_ratio, physical_memory_kb, committed_target_kb,
  max_workers_count, scheduler_count, CAST(virtual_machine_type_desc AS nvarchar(60)) AS virtual_machine_type,
  CONVERT(varchar(33), DATEADD(MILLISECOND, -CAST((ms_ticks - sqlserver_start_time_ms_ticks) % 1000 AS int),
    DATEADD(SECOND, -CAST((ms_ticks - sqlserver_start_time_ms_ticks) / 1000 AS int), SYSUTCDATETIME())), 126) + 'Z' AS started_at_utc,
  -- task 404 (0155): the server's own clock at this read, the read 0155 compares the next start with
  CONVERT(varchar(33), SYSUTCDATETIME(), 126) + 'Z' AS server_utc
FROM sys.dm_os_sys_info`

func (instanceCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, serverSQL)
	if err != nil {
		return nil, err
	}
	cfg, err := QueryRows(ctx, conn, configSQL)
	if err != nil {
		return nil, err
	}
	rows = append(rows, cfg...)
	if !info.ViewServerState {
		return append(rows, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info",
			"message": "the login lacks VIEW SERVER STATE: the CPU count, memory and start time were not read"}), nil
	}
	si, err := QueryRows(ctx, conn, sysinfoSQL)
	if err != nil {
		return append(rows, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info", "message": err.Error()}), nil
	}
	return append(rows, si...), nil
}
