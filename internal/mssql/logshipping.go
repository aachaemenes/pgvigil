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

// lsScheduleRuns: a schedule (ss) that still runs its job by itself - enabled, repeating (sysschedules.freq_type 4
// daily, 8 weekly, 16 monthly, 32 monthly relative) and not past its end date. A one-time schedule, one that fires
// when SQL Server Agent starts (64) or when the CPUs are idle (128), and one that has ended do not keep a log shipping
// job running.
const lsScheduleRuns = `ss.enabled = 1 AND ss.freq_type IN (4, 8, 16, 32) AND ss.active_end_date >= CONVERT(int, CONVERT(char(8), GETDATE(), 112))`

// lsJobColumns: a log shipping job (x.job_id, x.job_role) as SQL Server Agent holds it: whether it exists, enabled,
// the schedules that still run it (lsScheduleRuns) and the shortest interval among them in minutes (freq_subday_type
// 2 seconds, 4 minutes, 8 hours; a schedule that runs once a day has no interval: NULL, not judged). job_id is read
// raw: the reader gives it as the canonical upper-case text mssql_jobs holds.
const lsJobColumns = `x.job_role, x.job_id, CAST(j.name AS nvarchar(128)) AS job_name,
  CAST(CASE WHEN j.job_id IS NULL THEN 0 ELSE 1 END AS int) AS job_exists, CAST(j.enabled AS int) AS job_enabled,
  (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = js.schedule_id
    WHERE js.job_id = j.job_id AND ` + lsScheduleRuns + `) AS enabled_schedules,
  (SELECT CAST(MIN(CASE ss.freq_subday_type WHEN 2 THEN ss.freq_subday_interval / 60.0 WHEN 4 THEN ss.freq_subday_interval * 1.0
                                            WHEN 8 THEN ss.freq_subday_interval * 60.0 END) AS float)
     FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules ss ON ss.schedule_id = js.schedule_id
    WHERE js.job_id = j.job_id AND ` + lsScheduleRuns + `) AS interval_min`

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
LEFT JOIN sys.databases d ON d.database_id = DB_ID(p.primary_database)   -- by id: no comparison of two collations
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

// lsForeignWhere: over a row source x (file_name, backup_directory, backup_share, database_name) it keeps the files
// that are NOT log shipping's own. Own = written under the configuration's backup_directory or backup_share (compared
// upper-cased, '/' read as '\', trailing spaces and a trailing separator of the folder dropped, a separator after the
// folder: C:\LS never matches C:\LS2\x.trn), or named as log shipping names its own backups wherever the file is -
// <database>_<14 digits>.trn - so the backups it took before its folder was changed are not called foreign. A
// configuration with no backup_directory is not judged. The NUL device, a URL, a virtual device and a backup with no
// media family are never own. Known misses, kept on purpose (a miss, never a false alarm): another job that writes
// into log shipping's folder or below it; on a case-sensitive file system two folders that differ only in case.
// TestLogShippingForeignPathsLive runs this fragment as it is over Windows- and Linux-shaped paths.
const lsForeignWhere = `
CROSS APPLY (SELECT UPPER(REPLACE(ISNULL(x.file_name, N''), N'/', N'\')) AS fn,
                    UPPER(RTRIM(REPLACE(ISNULL(x.backup_directory, N''), N'/', N'\'))) AS d1,
                    UPPER(RTRIM(REPLACE(ISNULL(x.backup_share, N''), N'/', N'\'))) AS d2,
                    UPPER(x.database_name) AS db) n
CROSS APPLY (SELECT RTRIM(CASE WHEN RIGHT(n.d1, 1) = N'\' THEN LEFT(n.d1, LEN(n.d1) - 1) ELSE n.d1 END) AS d1,
                    RTRIM(CASE WHEN RIGHT(n.d2, 1) = N'\' THEN LEFT(n.d2, LEN(n.d2) - 1) ELSE n.d2 END) AS d2,
                    RIGHT(n.fn, CHARINDEX(N'\', REVERSE(n.fn) + N'\') - 1) AS leaf) t
WHERE LEN(t.d1) > 0
  AND LEFT(n.fn, LEN(t.d1) + 1) <> t.d1 + N'\'
  AND (LEN(t.d2) = 0 OR LEFT(n.fn, LEN(t.d2) + 1) <> t.d2 + N'\')
  AND NOT (LEN(t.leaf) = LEN(n.db) + 19 AND LEFT(t.leaf, LEN(n.db) + 1) = n.db + N'_'
           AND SUBSTRING(t.leaf, LEN(n.db) + 2, 14) NOT LIKE N'%[^0-9]%' AND RIGHT(t.leaf, 4) = N'.TRN')`

// lsForeignSQL: on a primary, every log backup of a log-shipped database finished in the last 24 hours (this
// server's own rows) that is NOT copy-only and is not log shipping's own (lsForeignWhere) - another job's log backup:
// the secondaries never receive it, so they cannot restore past it. Only the first media family's file is read (a
// striped backup is judged by its first stripe). Times in UTC by the row's own backupset.time_zone.
var lsForeignSQL = `SELECT 'lsforeign' AS kind, CAST(x.database_name AS nvarchar(128)) AS database_name,
  CAST(x.file_name AS nvarchar(500)) AS file_name, x.device, x.started_utc, x.finished_utc,
  CAST(x.backup_directory AS nvarchar(500)) AS backup_directory
FROM (SELECT bs.database_name, mf.physical_device_name AS file_name, p.backup_directory, p.backup_share, bs.backup_finish_date,
             CASE mf.device_type % 100 WHEN 2 THEN 'disk' WHEN 5 THEN 'tape' WHEN 7 THEN 'virtual device' WHEN 9 THEN 'url'
                  ELSE CAST(mf.device_type AS varchar(12)) END AS device,
             ` + backupUTC("bs.backup_start_date") + ` AS started_utc,
             ` + backupUTC("bs.backup_finish_date") + ` AS finished_utc
        FROM msdb.dbo.log_shipping_primary_databases p
        JOIN msdb.dbo.backupset bs ON bs.database_name = p.primary_database AND bs.type = 'L' AND bs.is_copy_only = 0
         AND bs.backup_finish_date >= DATEADD(hour, -24, GETDATE())
         AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
       OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
                     WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number) mf) x` + lsForeignWhere + `
ORDER BY x.backup_finish_date DESC`

// lsErrorSQL: what log shipping's own agents (backup on a primary, copy and restore on a secondary) wrote into
// msdb.dbo.log_shipping_monitor_error_detail in the last 24 hours (an index on log_time_utc bounds the read): the
// newest 20 rows per agent and database (ord 1 = the newest) with how many rows that agent and database have in the
// 24 hours. An error is a sequence of rows of one session (Microsoft: "Each error is logged as a sequence of
// exceptions"): the agent's own line (sequence 0), then the engine's (source '.Net SqlClient Data Provider'). The
// copy agent's rows name no database (Microsoft: "empty for copy"): they take the databases of its secondary id.
// standby_noise marks, on a secondary restored WITH STANDBY (restore_mode 1), a row that says the database is
// read-only: the repository shows such rows counted and never judges them. The words are a log shipping report's
// filter and SQL Server's own Msg 3906 ('Failed to update database "<name>" because the database is read-only.'); no
// real agent row with them was seen (a STANDBY copy in use wrote 'Exclusive access could not be obtained', which is
// a real reason restores fall behind and is never marked): the filter is proven on stored rows only.
var lsErrorSQL = `WITH e AS (
  SELECT e.agent_type, e.session_id, e.sequence_number, e.log_time_utc, e.message, e.source,
         COALESCE(NULLIF(e.database_name, N''), CASE e.agent_type WHEN 0 THEN p.primary_database ELSE sd.secondary_database END) AS database_name,
         sd.restore_mode
    FROM msdb.dbo.log_shipping_monitor_error_detail e
    LEFT JOIN msdb.dbo.log_shipping_primary_databases p ON e.agent_type = 0 AND p.primary_id = e.agent_id
    LEFT JOIN msdb.dbo.log_shipping_secondary_databases sd ON e.agent_type IN (1, 2) AND sd.secondary_id = e.agent_id
         AND (ISNULL(e.database_name, N'') = N'' OR sd.secondary_database = e.database_name)
   WHERE e.log_time_utc >= DATEADD(hour, -24, GETUTCDATE())
     -- this server's own agents only (a monitor's msdb also holds the other servers' rows)
     AND ((e.agent_type = 0 AND p.primary_id IS NOT NULL) OR (e.agent_type IN (1, 2) AND sd.secondary_id IS NOT NULL))
), r AS (
  SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.agent_type, e.database_name ORDER BY e.log_time_utc DESC, e.session_id DESC, e.sequence_number DESC) AS ord,
         COUNT(*) OVER (PARTITION BY e.agent_type, e.database_name) AS rows_24h
    FROM e
)
SELECT 'lserror' AS kind, CASE r.agent_type WHEN 0 THEN 'backup' WHEN 1 THEN 'copy' ELSE 'restore' END AS agent,
  CAST(ISNULL(r.database_name, N'') AS nvarchar(128)) AS database_name, CAST(r.ord AS int) AS ord, r.session_id, r.sequence_number,
  ` + isUTCText("r.log_time_utc") + ` AS logged_utc,
  CAST(LEFT(r.message, 2000) AS nvarchar(2000)) AS message, CAST(LEFT(r.source, 200) AS nvarchar(200)) AS source,
  CAST(r.rows_24h AS int) AS rows_24h,
  CAST(CASE WHEN r.restore_mode = 1 AND (r.message LIKE N'%read-only database%' OR r.message LIKE N'%database is in read-only mode%'
                                         OR r.message LIKE N'%because the database is read-only%')
            THEN 1 ELSE 0 END AS int) AS standby_noise
FROM r
WHERE r.ord <= 20
ORDER BY r.agent_type, r.database_name, r.ord`

// lsIdleSQL: per secondary database, how many times in the last hour the restore job ran AFTER its last restore and
// found nothing to apply - its history line 'Could not find a log backup file that could be applied to secondary
// database' (the pattern's '_' stands for the blank after 'backup'). The line is written by every idle run of a
// healthy pair, so it means something only where restores are behind: then the copy job is where to look (Microsoft,
// error 14421). The history table holds about eight rows per run of each agent and keeps them for days (its
// retention), and its index on log_time_utc does not bound the read (an hour is a small part of the table: SQL
// Server scans the clustered index with the time as a residual - measured, 1.3 million rows, 24,261 reads). So the
// read starts from this server's own secondary databases and reaches the history by its clustered key (agent_id =
// the secondary id, agent_type 2): a server with no secondary database reads nothing, and a monitor's rows of other
// servers' agents are never read. This server's own monitor row gives the last restore (an idle run leaves its time
// as it was: Microsoft, 14421); a secondary with no monitor row counts the whole hour. The words are English: a
// localized agent's line is not counted (not proven).
var lsIdleSQL = `SELECT 'lsidle' AS kind, CAST(sd.secondary_database AS nvarchar(128)) AS database_name,
  ` + isUTCText("MAX(h.log_time_utc)") + ` AS last_utc, COUNT(*) AS runs
FROM msdb.dbo.log_shipping_secondary_databases sd
JOIN msdb.dbo.log_shipping_monitor_history_detail h ON h.agent_id = sd.secondary_id AND h.agent_type = 2 AND h.database_name = sd.secondary_database
WHERE h.log_time_utc >= DATEADD(hour, -1, GETUTCDATE())
  AND h.message LIKE N'Could not find a log backup_file that could be applied%'
  AND h.log_time_utc > ISNULL((SELECT MAX(m.last_restored_date_utc) FROM msdb.dbo.log_shipping_monitor_secondary m
                                WHERE m.secondary_id = sd.secondary_id AND m.secondary_database = sd.secondary_database), CONVERT(datetime, '19000101', 112))
GROUP BY sd.secondary_database
ORDER BY sd.secondary_database`

// lsParts: the configuration, the foreign log backups, the agents' errors and the idle restore runs, each a part of
// its own (a failure is a collector_error row of its source, never the loss of the rest; the repository's import
// keeps a part's stored rows by these names)
var lsParts = []struct {
	source string
	tables []string
	query  string
}{
	{"log shipping configuration", []string{"log_shipping_primary_databases", "log_shipping_secondary", "log_shipping_secondary_databases",
		"log_shipping_monitor_alert", "sysjobs", "sysjobschedules", "sysschedules"}, lsConfigSQL},
	{"log shipping foreign log backups", []string{"log_shipping_primary_databases", "backupset", "backupmediafamily"}, lsForeignSQL},
	{"log shipping agent errors", []string{"log_shipping_monitor_error_detail", "log_shipping_primary_databases", "log_shipping_secondary_databases"}, lsErrorSQL},
	{"log shipping idle restores", []string{"log_shipping_secondary_databases", "log_shipping_monitor_history_detail", "log_shipping_monitor_secondary"}, lsIdleSQL},
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
