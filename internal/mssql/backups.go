package mssql

import (
	"context"
	"database/sql"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// backupsCollector is mssql_backups: per database of the server its state and recovery model (sys.databases), the
// availability group it belongs to, and from msdb.dbo.backupset the last full, differential and log backup this
// server took of it: the finish time, the size and compressed size, the duration, the device, and whether it was
// copy-only. A backup to the NUL device is kept apart: it is no backup, and it is reported as its own row.
// msdb is each server's own record: the backups another replica of an availability group took are in that
// replica's msdb, and the repository merges them by group and database name.
//
// The finish time is moved to UTC by the offset backupset.time_zone recorded with the backup (15-minute units;
// 127 = unknown, then the server's offset at the read). The shape "the newest row per database and type from
// backupset, this server's own backups only" follows DBA Dash 4.24.1, DBADash/SQL/SQLBackups.sql (MIT, Copyright
// 2022 Trimble, Inc.); the statement is pgvigil's own.
type backupsCollector struct{}

func init() { Register(backupsCollector{}) }

func (backupsCollector) Name() string                   { return Prefix + "backups" }
func (backupsCollector) DefaultInterval() time.Duration { return time.Hour }
func (backupsCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "Azure SQL Database keeps no backup history in msdb (its backups are the service's own)"
	case !info.MsdbAccess:
		return false, "the login has no access to msdb (a user there with db_datareader)"
	}
	return true, ""
}

// Timeout: one pass over msdb.dbo.backupset, which nothing indexes by database; a history of millions of rows
// takes its time.
func (backupsCollector) Timeout() time.Duration { return 2 * time.Minute }

// backupDatabasesSQL: every database with what decides whether its backups are judged. SQL Server 2016 SP1 and
// later. The group comes from the catalog (sys.databases.replica_id), which needs no VIEW SERVER STATE.
func backupDatabasesSQL(withGroups bool) string {
	group := `CAST(NULL AS nvarchar(36)) AS ag_group_id, CAST(NULL AS nvarchar(128)) AS ag_name`
	join := ""
	if withGroups {
		group = `CAST(ag.group_id AS nvarchar(36)) AS ag_group_id, CAST(ag.name AS nvarchar(128)) AS ag_name`
		join = `
LEFT JOIN sys.availability_replicas ar ON ar.replica_id = d.replica_id
LEFT JOIN sys.availability_groups ag ON ag.group_id = ar.group_id`
	}
	return `SELECT 'database' AS kind, CAST(d.name AS nvarchar(128)) AS database_name,
  CAST(d.state_desc AS nvarchar(60)) AS state, CAST(d.recovery_model_desc AS nvarchar(60)) AS recovery_model,
  ` + utcText("d.create_date") + ` AS created_utc,
  CASE WHEN d.source_database_id IS NOT NULL THEN 1 ELSE 0 END AS is_snapshot,
  CAST(d.is_read_only AS int) AS is_read_only, CAST(d.is_in_standby AS int) AS is_standby,
  ` + group + `
FROM sys.databases d` + join + `
ORDER BY d.name`
}

// backupUTC is a backupset time in UTC by the row's own recorded offset.
func backupUTC(col string) string {
	return "CONVERT(varchar(33), CASE WHEN bs.time_zone BETWEEN -48 AND 56 THEN DATEADD(minute, -15 * bs.time_zone, " + col + ")" +
		" ELSE DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), " + col + ") END, 126) + 'Z'"
}

// backupsSQL: the newest finished backup per database, type (D full, I differential, L log) and "to NUL or not",
// of this server's own backups. SQL Server 2016 SP1 and later.
var backupsSQL = `WITH b AS (
  SELECT bs.database_name, bs.type, bs.backup_set_id, bs.backup_start_date, bs.backup_finish_date, bs.time_zone,
         bs.backup_size, bs.compressed_backup_size, bs.is_copy_only, bs.is_snapshot, mf.device_type, mf.physical_device_name,
         CASE WHEN UPPER(mf.physical_device_name) IN (N'NUL', N'NUL:') THEN 1 ELSE 0 END AS to_nul
    FROM msdb.dbo.backupset bs
   OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
                 WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number) mf
   WHERE bs.type IN ('D', 'I', 'L') AND bs.backup_finish_date IS NOT NULL
     AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
), r AS (
  SELECT b.*, ROW_NUMBER() OVER (PARTITION BY b.database_name, b.type, b.to_nul ORDER BY b.backup_finish_date DESC, b.backup_set_id DESC) AS rn
    FROM b
)
SELECT 'backup' AS kind, CAST(bs.database_name AS nvarchar(128)) AS database_name,
  CASE bs.type WHEN 'D' THEN 'full' WHEN 'I' THEN 'diff' ELSE 'log' END AS backup_type,
  bs.to_nul,
  ` + backupUTC("bs.backup_finish_date") + ` AS finish_utc,
  DATEDIFF(second, bs.backup_start_date, bs.backup_finish_date) AS duration_s,
  CAST(bs.backup_size AS bigint) AS size_bytes, CAST(bs.compressed_backup_size AS bigint) AS compressed_bytes,
  CAST(bs.is_copy_only AS int) AS is_copy_only, CAST(bs.is_snapshot AS int) AS is_snapshot,
  CASE bs.device_type % 100 WHEN 2 THEN 'disk' WHEN 5 THEN 'tape' WHEN 7 THEN 'virtual device' WHEN 9 THEN 'url'
       ELSE CAST(bs.device_type AS varchar(12)) END AS device,
  CAST(LEFT(bs.physical_device_name, 260) AS nvarchar(260)) AS device_name
FROM r bs
WHERE bs.rn = 1
ORDER BY 2, 3, 4`

// how far back msdb's own backup history reaches: "no backup in msdb" is not "never backed up" on a server whose
// history is trimmed
const backupHistorySQL = `SELECT 'history' AS kind, COUNT_BIG(*) AS backup_sets,
  CONVERT(varchar(33), DATEADD(minute, DATEDIFF(minute, GETDATE(), GETUTCDATE()), MIN(backup_start_date)), 126) + 'Z' AS oldest_utc
FROM msdb.dbo.backupset`

func (backupsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	rows, err := QueryRows(ctx, conn, backupDatabasesSQL(info.HADREnabled))
	if err != nil {
		return nil, err
	}
	bk, err := QueryRows(ctx, conn, backupsSQL)
	if err != nil {
		return nil, err
	}
	rows = append(rows, bk...)
	hist, err := QueryRows(ctx, conn, backupHistorySQL)
	if err != nil {
		return nil, err
	}
	return append(rows, hist...), nil
}
