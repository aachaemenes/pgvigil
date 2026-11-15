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

// lsJobColumns: a log shipping job (x.job_id, x.job_role) as SQL Server Agent holds it: whether it exists, enabled,
// its enabled schedules and the shortest interval among them in minutes (sysschedules freq_subday_type 2 seconds,
// 4 minutes, 8 hours; any other schedule shape has no interval: NULL, not judged). job_id is read raw: the reader
// gives it as the canonical upper-case text mssql_jobs holds.
const lsJobColumns = `x.job_role, x.job_id, CAST(j.name AS nvarchar(128)) AS job_name,
  CAST(CASE WHEN j.job_id IS NULL THEN 0 ELSE 1 END AS int) AS job_exists, CAST(j.enabled AS int) AS job_enabled,
  (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = js.schedule_id
    WHERE js.job_id = j.job_id AND ss.enabled = 1) AS enabled_schedules,
  (SELECT CAST(MIN(CASE ss.freq_subday_type WHEN 2 THEN ss.freq_subday_interval / 60.0 WHEN 4 THEN ss.freq_subday_interval * 1.0
                                            WHEN 8 THEN ss.freq_subday_interval * 60.0 END) AS float)
     FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = js.schedule_id
    WHERE js.job_id = j.job_id AND ss.enabled = 1) AS interval_min`

// lsConfigSQL: SQL Server's own log shipping configuration on this server, one row per job: a primary database's
// backup job (with the database's recovery model and its backup folders), a secondary database's copy and restore
// jobs (with its primary and its restore mode: 0 NORECOVERY, 1 STANDBY), and the monitor's alert job
// (log_shipping_monitor_alert, no database). A job id with no msdb.dbo.sysjobs row is job_exists 0 (the job was
// deleted while the configuration names it). SQL Server 2016 SP1 and later (the tables are unchanged since 2005).
var lsConfigSQL = `SELECT 'lsconfig' AS kind, 'primary' AS role, CAST(p.primary_database AS nvarchar(128)) AS database_name,
  CAST(d.recovery_model_desc AS nvarchar(60)) AS recovery_model,
  CAST(p.backup_directory AS nvarchar(500)) AS backup_directory, CAST(p.backup_share AS nvarchar(500)) AS backup_share,
  CAST(NULL AS nvarchar(128)) AS primary_server, CAST(NULL AS nvarchar(128)) AS primary_database, CAST(NULL AS int) AS restore_mode,
  ` + lsJobColumns + `
FROM msdb.dbo.log_shipping_primary_databases p
LEFT JOIN sys.databases d ON d.name = p.primary_database
CROSS APPLY (SELECT CAST('backup' AS varchar(10)) AS job_role, p.backup_job_id AS job_id) x
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = x.job_id
UNION ALL
SELECT 'lsconfig', 'secondary', CAST(sd.secondary_database AS nvarchar(128)), NULL, NULL, NULL,
  CAST(s.primary_server AS nvarchar(128)), CAST(s.primary_database AS nvarchar(128)), CAST(sd.restore_mode AS int),
  ` + lsJobColumns + `
FROM msdb.dbo.log_shipping_secondary_databases sd
JOIN msdb.dbo.log_shipping_secondary s ON s.secondary_id = sd.secondary_id
CROSS APPLY (VALUES (CAST('copy' AS varchar(10)), s.copy_job_id), (CAST('restore' AS varchar(10)), s.restore_job_id)) x (job_role, job_id)
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = x.job_id
UNION ALL
SELECT 'lsconfig', 'monitor', N'', NULL, NULL, NULL, NULL, NULL, NULL,
  ` + lsJobColumns + `
FROM msdb.dbo.log_shipping_monitor_alert a
CROSS APPLY (SELECT CAST('alert' AS varchar(10)) AS job_role, a.alert_job_id AS job_id) x
LEFT JOIN msdb.dbo.sysjobs j ON j.job_id = x.job_id`

// lsForeignSQL: on a primary, every log backup of a log-shipped database finished in the last 24 hours (this
// server's own rows) that is NOT copy-only and whose file is NOT under the configuration's backup_directory or
// backup_share - another job's log backup: the secondaries never receive it, so they cannot restore past it. The
// folders are compared upper-cased with '/' read as '\' and a separator after the folder (C:\LS never matches
// C:\LS2\x.trn); a configuration with no backup_directory is not judged. A backup to the NUL device counts (nothing
// was kept, and the chain is broken all the same). Times in UTC by the row's own backupset.time_zone.
var lsForeignSQL = `SELECT 'lsforeign' AS kind, CAST(bs.database_name AS nvarchar(128)) AS database_name,
  CAST(mf.physical_device_name AS nvarchar(500)) AS file_name,
  CASE mf.device_type % 100 WHEN 2 THEN 'disk' WHEN 5 THEN 'tape' WHEN 7 THEN 'virtual device' WHEN 9 THEN 'url'
       ELSE CAST(mf.device_type AS varchar(12)) END AS device,
  ` + backupUTC("bs.backup_start_date") + ` AS started_utc,
  ` + backupUTC("bs.backup_finish_date") + ` AS finished_utc,
  CAST(p.backup_directory AS nvarchar(500)) AS backup_directory
FROM msdb.dbo.log_shipping_primary_databases p
JOIN msdb.dbo.backupset bs ON bs.database_name = p.primary_database AND bs.type = 'L' AND bs.is_copy_only = 0
 AND bs.backup_finish_date >= DATEADD(hour, -24, GETDATE())
 AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
              WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number) mf
CROSS APPLY (SELECT UPPER(REPLACE(ISNULL(mf.physical_device_name, N''), N'/', N'\')) AS fn,
                    UPPER(REPLACE(ISNULL(p.backup_directory, N''), N'/', N'\')) AS d1,
                    UPPER(REPLACE(ISNULL(p.backup_share, N''), N'/', N'\')) AS d2) n
CROSS APPLY (SELECT CASE WHEN RIGHT(n.d1, 1) = N'\' THEN LEFT(n.d1, LEN(n.d1) - 1) ELSE n.d1 END AS d1,
                    CASE WHEN RIGHT(n.d2, 1) = N'\' THEN LEFT(n.d2, LEN(n.d2) - 1) ELSE n.d2 END AS d2) t
WHERE LEN(t.d1) > 0
  AND LEFT(n.fn, LEN(t.d1) + 1) <> t.d1 + N'\'
  AND (LEN(t.d2) = 0 OR LEFT(n.fn, LEN(t.d2) + 1) <> t.d2 + N'\')
ORDER BY bs.backup_finish_date DESC`

// lsParts: the configuration and the foreign log backups, each its own part (a failure is a collector_error row of
// its source, never the loss of the rest); the foreign read needs backupset and backupmediafamily too
var lsParts = []struct {
	source string
	tables []string
	query  string
}{
	{"log shipping configuration", []string{"log_shipping_primary_databases", "log_shipping_secondary", "log_shipping_secondary_databases",
		"log_shipping_monitor_alert", "sysjobs", "sysjobschedules", "sysschedules"}, lsConfigSQL},
	{"log shipping foreign log backups", []string{"log_shipping_primary_databases", "backupset", "backupmediafamily"}, lsForeignSQL},
}

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
	for _, part := range lsParts {
		readable := true
		for _, t := range part.tables {
			if err := msdbReadable(ctx, conn, t); err != nil {
				rows = append(rows, collect.Row{"kind": "collector_error", "source": part.source, "message": err.Error()})
				readable = false
				break
			}
		}
		if !readable {
			continue
		}
		got, err := QueryRows(ctx, conn, part.query)
		if err != nil {
			rows = append(rows, collect.Row{"kind": "collector_error", "source": part.source, "message": err.Error()})
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
