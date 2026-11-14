package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// logshippingCollector is mssql_logshipping: msdb's own monitor tables as the server keeps them, a primary's last
// backup and a secondary's last copy and restore with the thresholds their configuration names (the tables hold UTC
// columns beside the local ones; the UTC ones are read), AND log shipping as restore history shows it, whoever set
// it up (DBA Dash's LogRestores read): every database that is RESTORING, in STANDBY, or RECOVERING after a log
// restore, with its newest log restore of the last 14 days - when it ran, the start of the log backup it restored
// (the primary's clock, converted by backupset.time_zone), the server and database that backup came from (the
// pair), the file - and the newest restore of any kind; a database that is mirrored or in an availability group is
// read with that said, so the repository leaves it out. A log restore pair of the last 14 days whose destination
// database no longer exists is a 'pair' row with no database. A server with neither returns no row.
type logshippingCollector struct{}

func init() { Register(logshippingCollector{}) }

func (logshippingCollector) Name() string                   { return Prefix + "logshipping" }
func (logshippingCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (logshippingCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "Azure SQL Database has no log shipping"
	case info.Kind == KindRDS:
		// RDS's master user cannot grant msdb's log shipping tables either: the login could never read them
		return false, "Amazon RDS for SQL Server has no log shipping"
	case info.Kind == KindAzureMI:
		// Microsoft's T-SQL differences page for Managed Instance: "Differential, log, and file snapshot backups
		// aren't supported" - a user takes COPY_ONLY full backups to a URL only, so there is no log to ship
		return false, "Azure SQL Managed Instance has no log shipping: it takes no log backup a user can ship"
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

// logRestoreSQL: SQL Server 2016 SP1 and later. restore_date and create_date are the server's local clock (utcText);
// backup_start_date is the clock of the server that took the backup: backupset.time_zone is its offset from UTC in
// 15-minute steps at the backup (127 = unknown: then this server's offset is taken, as for a backup of its own).
// replica_id is NULL for a database in no availability group (SQL Server 2012 and later). msdb.dbo.restorehistory has
// no index on the destination's name, so each of the two newest-restore lists is ONE pass over it (ROW_NUMBER per
// destination), joined to sys.databases - never a scan per database.
// A mirror database is mirrored by its sys.database_mirroring row, which a login that is not sysadmin sees with NULL
// values on the mirror (Microsoft: "To see non-NULL values on a mirror database, you must be a member of the sysadmin
// fixed server role"). For such a login with VIEW SERVER STATE the mirror's Database Mirroring counter instance says
// so (mirroringSQL); for a sysadmin a NULL row is the answer. A login with neither cannot tell a RESTORING database
// from a mirror: is_mirrored is NULL (unknown) there, and the repository does not judge it.
func logRestoreSQL(withCounters bool) string {
	mirrored := "CASE WHEN m.mirroring_guid IS NOT NULL THEN 1 WHEN IS_SRVROLEMEMBER('sysadmin') = 1 OR d.state <> 1 THEN 0 END"
	if withCounters {
		mirrored = `CASE WHEN m.mirroring_guid IS NOT NULL OR (IS_SRVROLEMEMBER('sysadmin') = 0 AND EXISTS (SELECT 1 FROM sys.dm_os_performance_counters pc
                    WHERE pc.object_name LIKE '%:Database Mirroring%' AND RTRIM(pc.instance_name) = d.name)) THEN 1 ELSE 0 END`
	}
	return `WITH lr AS (
  SELECT rh.destination_database_name AS dest, rh.restore_date, bs.backup_start_date, bs.time_zone, bs.server_name,
         bs.database_name AS source_database, bmf.physical_device_name AS last_file,
         ROW_NUMBER() OVER (PARTITION BY rh.destination_database_name ORDER BY rh.restore_date DESC, rh.restore_history_id DESC) AS rn
    FROM msdb.dbo.restorehistory rh
    JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
    LEFT JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id AND bmf.family_sequence_number = 1
   WHERE rh.restore_type = 'L' AND rh.restore_date >= DATEADD(day, -14, GETDATE())
), ar AS (
  SELECT rh.destination_database_name AS dest, rh.restore_date, rh.restore_type,
         ROW_NUMBER() OVER (PARTITION BY rh.destination_database_name ORDER BY rh.restore_date DESC, rh.restore_history_id DESC) AS rn
    FROM msdb.dbo.restorehistory rh
)
SELECT 'restore' AS kind, CAST(d.name AS nvarchar(128)) AS database_name,
  CAST(d.state_desc AS nvarchar(60)) AS database_state, CAST(d.is_in_standby AS int) AS is_in_standby,
  CAST(d.recovery_model_desc AS nvarchar(60)) AS recovery_model,
  ` + utcText("d.create_date") + ` AS created_utc,
  CAST(` + mirrored + ` AS int) AS is_mirrored,
  CAST(CASE WHEN d.replica_id IS NOT NULL THEN 1 ELSE 0 END AS int) AS in_availability_group,
  ` + utcText("lr.restore_date") + ` AS last_log_restore_utc,
  CASE WHEN lr.backup_start_date IS NULL THEN NULL
       WHEN lr.time_zone IS NULL OR lr.time_zone = 127 THEN ` + utcText("lr.backup_start_date") + `
       ELSE CONVERT(varchar(33), DATEADD(minute, -15 * lr.time_zone, lr.backup_start_date), 126) + 'Z' END AS last_log_backup_start_utc,
  lr.time_zone AS backup_time_zone,
  CAST(lr.server_name AS nvarchar(128)) AS source_server, CAST(lr.source_database AS nvarchar(128)) AS source_database,
  CAST(lr.last_file AS nvarchar(500)) AS last_file,
  ` + utcText("ar.restore_date") + ` AS last_restore_utc, CAST(ar.restore_type AS nvarchar(1)) AS last_restore_type
FROM sys.databases d
LEFT JOIN sys.database_mirroring m ON m.database_id = d.database_id
LEFT JOIN lr ON lr.dest = d.name AND lr.rn = 1
LEFT JOIN ar ON ar.dest = d.name AND ar.rn = 1
WHERE d.database_id > 4 AND d.source_database_id IS NULL
  AND (d.state = 1 OR d.is_in_standby = 1 OR (d.state = 2 AND lr.restore_date IS NOT NULL))
ORDER BY d.name`
}

// logRestorePairSQL: a database log-restored here in the last 14 days that no longer exists: its pair, its last
// restore, how many log restores it had in the window and whether the newest was WITH RECOVERY (restorehistory.recovery)
// - the repository raises a missing copy only for a stream (two or more, the newest WITH NORECOVERY), never for a
// restore test or a cut-over that brought one database online and dropped it. One row per destination name.
var logRestorePairSQL = `SELECT 'pair' AS kind, CAST(x.destination_database_name AS nvarchar(128)) AS database_name,
  CAST(x.server_name AS nvarchar(128)) AS source_server, CAST(x.source_database AS nvarchar(128)) AS source_database,
  ` + utcText("x.restore_date") + ` AS last_log_restore_utc, x.log_restores, CAST(x.recovery AS int) AS last_with_recovery
FROM (SELECT rh.destination_database_name, rh.restore_date, rh.recovery, bs.server_name, bs.database_name AS source_database,
             COUNT(*) OVER (PARTITION BY rh.destination_database_name) AS log_restores,
             ROW_NUMBER() OVER (PARTITION BY rh.destination_database_name ORDER BY rh.restore_date DESC, rh.restore_history_id DESC) AS rn
        FROM msdb.dbo.restorehistory rh
        JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
       WHERE rh.restore_type = 'L' AND rh.restore_date >= DATEADD(day, -14, GETDATE())) x
WHERE x.rn = 1 AND DB_ID(x.destination_database_name) IS NULL
ORDER BY 2`

func (logshippingCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	for _, t := range []string{"log_shipping_monitor_primary", "log_shipping_monitor_secondary"} {
		if err := msdbReadable(ctx, conn, t); err != nil {
			return nil, err
		}
	}
	rows, err := QueryRows(ctx, conn, logshippingPrimarySQL)
	if err != nil {
		return nil, err
	}
	sec, err := QueryRows(ctx, conn, logshippingSecondarySQL)
	if err != nil {
		return nil, err
	}
	rows = append(rows, sec...)
	// restore history is its own part: a login that may read the monitor tables only, or a failure of this read, is a
	// note beside msdb's own rows, never the loss of them
	history := true
	for _, t := range []string{"restorehistory", "backupset", "backupmediafamily"} {
		if err := msdbReadable(ctx, conn, t); err != nil {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": "msdb.dbo." + t,
				"message": err.Error() + ": log shipping from restore history was not read"})
			history = false
			break
		}
	}
	for _, q := range []string{logRestoreSQL(info.ViewServerState), logRestorePairSQL} {
		if !history {
			break
		}
		got, err := QueryRows(ctx, conn, q)
		if err != nil {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": "msdb.dbo.restorehistory", "message": err.Error()})
			continue
		}
		rows = append(rows, got...)
	}
	for _, r := range rows {
		if r["kind"] == "restore" && r["is_mirrored"] == nil {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": "sys.database_mirroring",
				"message": "the login is not sysadmin and lacks VIEW SERVER STATE: a RESTORING database cannot be told from a mirror, so it is not judged as log shipping"})
			break
		}
	}
	if len(rows) == 0 {
		return noRows(), nil
	}
	return rows, nil
}
