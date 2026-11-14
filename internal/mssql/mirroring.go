package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mirroringCollector is mssql_mirroring: database mirroring from sys.database_mirroring (the role, the state, the
// safety level, the partner and the witness, and the role sequence: it counts the role swaps of the session, so a
// swap between two reads is seen even when the pair is SYNCHRONIZED again at the next one) with the send and redo
// queues and the cumulative send, redo and transaction-delay counters of the Database Mirroring performance object
// (the repository turns two reads of a counter into a rate), and the instance's mirroring endpoint (its state, role,
// port, authentication and encryption) where the login may see it. A mirror database whose values sys.database_mirroring
// hides from a login that is not sysadmin is read as the mirror from its counters (mirroringSQL). A server without a
// mirrored database returns no row and nothing is stored.
type mirroringCollector struct{}

func init() { Register(mirroringCollector{}) }

func (mirroringCollector) Name() string                   { return Prefix + "mirroring" }
func (mirroringCollector) DefaultInterval() time.Duration { return time.Minute }
func (mirroringCollector) Applies(info Info) (bool, string) {
	switch info.Kind {
	case KindAzureDB:
		return false, "Azure SQL Database has no database mirroring"
	case KindAzureMI:
		// Microsoft's T-SQL differences page for Managed Instance: "Database mirroring isn't supported."
		return false, "Azure SQL Managed Instance does not support database mirroring"
	}
	return true, ""
}

// mirroringSQL: SQL Server 2016 SP1 and later (the view and the counter object are unchanged since 2005). The
// counters need VIEW SERVER STATE; without it the queues and the counters are NULL. The counters named "/sec" and
// "Transaction Delay" are cumulative in sys.dm_os_performance_counters (cntr_type 272696576, read with each value so
// the repository takes a difference only of a cumulative one); the queues are values at the read.
//
// A mirror database seen by a login that is not sysadmin: Microsoft's page for sys.database_mirroring says "To see
// non-NULL values on a mirror database, you must be a member of the sysadmin fixed server role", so for a
// least-privilege login every mirroring column of the mirror's row is NULL (the principal's row is whole). With VIEW
// SERVER STATE the Database Mirroring performance object still has an instance for that database on the mirror, so a
// RESTORING database with that instance is read as the mirror: role MIRROR, its queues and counters as on the
// principal, values_hidden 1, and its state, partner, witness and role sequence NULL (the principal's row has them).
func mirroringSQL(withCounters bool) string {
	counters := `CAST(NULL AS bigint) AS log_send_queue_kb, CAST(NULL AS bigint) AS redo_queue_kb,
  CAST(NULL AS bigint) AS log_bytes_sent_total, CAST(NULL AS bigint) AS redo_bytes_total,
  CAST(NULL AS bigint) AS txn_delay_ms_total, CAST(NULL AS bigint) AS mirrored_write_txns_total,
  CAST(NULL AS int) AS log_bytes_sent_type, CAST(NULL AS int) AS redo_bytes_type, CAST(NULL AS int) AS txn_delay_type,
  CAST(NULL AS int) AS mirrored_write_txns_type`
	apply, hidden := "", ""
	if withCounters {
		// the mirror a least-privilege login sees with NULL values (above): a counter instance of its own
		hidden = `
   OR (m.mirroring_guid IS NULL AND d.state = 1 AND c.redo_queue_kb IS NOT NULL)`
		counters = `c.log_send_queue_kb, c.redo_queue_kb, c.log_bytes_sent_total, c.redo_bytes_total, c.txn_delay_ms_total,
  c.mirrored_write_txns_total, c.log_bytes_sent_type, c.redo_bytes_type, c.txn_delay_type, c.mirrored_write_txns_type`
		apply = `
OUTER APPLY (SELECT MAX(CASE WHEN RTRIM(pc.counter_name) = 'Log Send Queue KB' THEN pc.cntr_value END) AS log_send_queue_kb,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Redo Queue KB' THEN pc.cntr_value END) AS redo_queue_kb,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Log Bytes Sent/sec' THEN pc.cntr_value END) AS log_bytes_sent_total,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Redo Bytes/sec' THEN pc.cntr_value END) AS redo_bytes_total,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Transaction Delay' THEN pc.cntr_value END) AS txn_delay_ms_total,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Mirrored Write Transactions/sec' THEN pc.cntr_value END) AS mirrored_write_txns_total,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Log Bytes Sent/sec' THEN pc.cntr_type END) AS log_bytes_sent_type,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Redo Bytes/sec' THEN pc.cntr_type END) AS redo_bytes_type,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Transaction Delay' THEN pc.cntr_type END) AS txn_delay_type,
                    MAX(CASE WHEN RTRIM(pc.counter_name) = 'Mirrored Write Transactions/sec' THEN pc.cntr_type END) AS mirrored_write_txns_type
               FROM sys.dm_os_performance_counters pc
              WHERE pc.object_name LIKE '%:Database Mirroring%' AND RTRIM(pc.instance_name) = d.name) c`
	}
	return `SELECT 'mirror' AS kind, CAST(d.name AS nvarchar(128)) AS database_name,
  CAST(COALESCE(m.mirroring_role_desc, N'MIRROR') AS nvarchar(60)) AS role,
  CAST(CASE WHEN m.mirroring_guid IS NULL THEN 1 ELSE 0 END AS int) AS values_hidden,
  CAST(m.mirroring_state_desc AS nvarchar(60)) AS state,
  CAST(m.mirroring_state AS int) AS state_code,
  CAST(m.mirroring_role_sequence AS int) AS role_sequence,
  CAST(m.mirroring_safety_level_desc AS nvarchar(60)) AS safety_level,
  CAST(m.mirroring_partner_name AS nvarchar(128)) AS partner,
  CAST(m.mirroring_partner_instance AS nvarchar(128)) AS partner_instance,
  CAST(NULLIF(m.mirroring_witness_name, '') AS nvarchar(128)) AS witness,
  CAST(m.mirroring_witness_state_desc AS nvarchar(60)) AS witness_state,
  m.mirroring_connection_timeout AS connection_timeout_s,
  CAST(d.state_desc AS nvarchar(60)) AS database_state,
  ` + counters + `
FROM sys.database_mirroring m
JOIN sys.databases d ON d.database_id = m.database_id` + apply + `
WHERE m.mirroring_guid IS NOT NULL` + hidden + `
ORDER BY d.name`
}

// mirroringEndpointSQL: the instance's one database mirroring endpoint (an availability group uses the same kind). A
// login without VIEW ANY DEFINITION sees no endpoint it was not granted, so the read is made only with that right.
const mirroringEndpointSQL = `SELECT 'endpoint' AS kind, CAST(e.name AS nvarchar(128)) AS endpoint_name,
  CAST(e.state_desc AS nvarchar(60)) AS endpoint_state, CAST(e.role_desc AS nvarchar(60)) AS endpoint_role,
  t.port AS endpoint_port, CAST(e.connection_auth_desc AS nvarchar(60)) AS endpoint_auth,
  CAST(e.encryption_algorithm_desc AS nvarchar(60)) AS endpoint_encryption
FROM sys.database_mirroring_endpoints e
LEFT JOIN sys.tcp_endpoints t ON t.endpoint_id = e.endpoint_id
ORDER BY e.name`

func (mirroringCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, mirroringSQL(info.ViewServerState))
	if err != nil {
		return nil, err
	}
	rows = mirroringRows(rows, info.ViewServerState)
	if len(rows) == 0 || !info.ViewAnyDefinition {
		return rows, nil
	}
	eps, err := QueryRows(ctx, conn, mirroringEndpointSQL)
	if err != nil {
		return append(rows, collect.Row{"kind": "collector_error", "source": "sys.database_mirroring_endpoints", "message": err.Error()}), nil
	}
	return append(rows, eps...), nil
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
