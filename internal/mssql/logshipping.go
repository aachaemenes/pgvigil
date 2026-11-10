package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// logshippingCollector is mssql_logshipping: msdb's own monitor tables as the server keeps them, a primary's last
// backup and a secondary's last copy and restore with the thresholds their configuration names. The tables hold
// UTC columns beside the local ones; the UTC ones are read. A server without log shipping returns no row.
type logshippingCollector struct{}

func init() { Register(logshippingCollector{}) }

func (logshippingCollector) Name() string                   { return Prefix + "logshipping" }
func (logshippingCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (logshippingCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "Azure SQL Database has no log shipping"
	case !info.MsdbAccess:
		return false, "the login has no access to msdb (a user there with db_datareader)"
	}
	return true, ""
}

// SQL Server 2016 SP1 and later (the monitor tables are unchanged since 2005).
var logshippingPrimarySQL = `SELECT 'primary' AS kind,
  CAST(primary_server AS nvarchar(128)) AS primary_server, CAST(primary_database AS nvarchar(128)) AS database_name,
  backup_threshold AS threshold_minutes, CAST(threshold_alert_enabled AS int) AS alert_enabled,
  CAST(last_backup_file AS nvarchar(500)) AS last_backup_file,
  ` + isUTCText("last_backup_date_utc") + ` AS last_backup_utc
FROM msdb.dbo.log_shipping_monitor_primary
ORDER BY primary_database`

var logshippingSecondarySQL = `SELECT 'secondary' AS kind,
  CAST(secondary_server AS nvarchar(128)) AS secondary_server, CAST(secondary_database AS nvarchar(128)) AS database_name,
  CAST(primary_server AS nvarchar(128)) AS primary_server, CAST(primary_database AS nvarchar(128)) AS primary_database,
  restore_threshold AS threshold_minutes, CAST(threshold_alert_enabled AS int) AS alert_enabled,
  CAST(last_copied_file AS nvarchar(500)) AS last_copied_file,
  ` + isUTCText("last_copied_date_utc") + ` AS last_copied_utc,
  CAST(last_restored_file AS nvarchar(500)) AS last_restored_file,
  ` + isUTCText("last_restored_date_utc") + ` AS last_restored_utc,
  last_restored_latency AS last_restored_latency_min
FROM msdb.dbo.log_shipping_monitor_secondary
ORDER BY secondary_database`

func (logshippingCollector) Run(ctx context.Context, conn *sql.Conn, _ Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, logshippingPrimarySQL)
	if err != nil {
		return nil, err
	}
	sec, err := QueryRows(ctx, conn, logshippingSecondarySQL)
	if err != nil {
		return nil, err
	}
	rows = append(rows, sec...)
	if len(rows) == 0 {
		return noRows(), nil
	}
	return rows, nil
}
