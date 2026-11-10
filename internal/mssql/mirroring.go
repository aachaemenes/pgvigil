package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mirroringCollector is mssql_mirroring: database mirroring from sys.database_mirroring (the role, the state, the
// safety level, the partner and the witness) with the send and redo queues from the Database Mirroring performance
// counters. A server without a mirrored database returns no row and nothing is stored.
type mirroringCollector struct{}

func init() { Register(mirroringCollector{}) }

func (mirroringCollector) Name() string                   { return Prefix + "mirroring" }
func (mirroringCollector) DefaultInterval() time.Duration { return time.Minute }
func (mirroringCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "Azure SQL Database has no database mirroring"
	}
	return true, ""
}

// mirroringSQL: SQL Server 2016 SP1 and later (the view and the counter object are unchanged since 2005). The
// counters need VIEW SERVER STATE; without it the queues are NULL.
func mirroringSQL(withCounters bool) string {
	queues := `CAST(NULL AS bigint) AS log_send_queue_kb, CAST(NULL AS bigint) AS redo_queue_kb`
	apply := ""
	if withCounters {
		queues = `c.log_send_queue_kb, c.redo_queue_kb`
		apply = `
OUTER APPLY (SELECT MAX(CASE WHEN RTRIM(pc.counter_name) = 'Log Send Queue KB' THEN pc.cntr_value END) AS log_send_queue_kb,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Redo Queue KB' THEN pc.cntr_value END) AS redo_queue_kb
               FROM sys.dm_os_performance_counters pc
              WHERE pc.object_name LIKE '%:Database Mirroring%' AND RTRIM(pc.instance_name) = d.name) c`
	}
	return `SELECT 'mirror' AS kind, CAST(d.name AS nvarchar(128)) AS database_name,
  CAST(m.mirroring_role_desc AS nvarchar(60)) AS role,
  CAST(m.mirroring_state_desc AS nvarchar(60)) AS state,
  CAST(m.mirroring_safety_level_desc AS nvarchar(60)) AS safety_level,
  CAST(m.mirroring_partner_name AS nvarchar(128)) AS partner,
  CAST(m.mirroring_partner_instance AS nvarchar(128)) AS partner_instance,
  CAST(NULLIF(m.mirroring_witness_name, '') AS nvarchar(128)) AS witness,
  CAST(m.mirroring_witness_state_desc AS nvarchar(60)) AS witness_state,
  m.mirroring_connection_timeout AS connection_timeout_s,
  ` + queues + `
FROM sys.database_mirroring m
JOIN sys.databases d ON d.database_id = m.database_id` + apply + `
WHERE m.mirroring_guid IS NOT NULL
ORDER BY d.name`
}

func (mirroringCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, mirroringSQL(info.ViewServerState))
	if err != nil {
		return nil, err
	}
	return mirroringRows(rows, info.ViewServerState), nil
}

// mirroringRows adds the partial note when mirrored databases were read without their queues.
func mirroringRows(rows []collect.Row, withCounters bool) []collect.Row {
	if len(rows) == 0 {
		return noRows()
	}
	if !withCounters {
		rows = append(rows, collect.Row{"kind": "collector_error", "source": "sys.dm_os_performance_counters",
			"message": "the login lacks VIEW SERVER STATE: the mirroring send and redo queues were not read"})
	}
	return rows
}
