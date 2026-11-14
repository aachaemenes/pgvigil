package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// backupsCollector is mssql_backups: per database of the server its state and recovery model (sys.databases), the
// availability group it belongs to, and from msdb.dbo.backupset the last full, differential and log backup this
// server took of it: the finish time, the size and compressed size, the duration, the device, and whether it was
// copy-only. A backup to the NUL device is kept apart: it is no backup, and it is reported as its own row. The
// stream of an availability group's automatic seeding, which msdb also records, is left out.
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
		" ELSE DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), " + col + ") END, 126) + 'Z'"
}

// backupSinkExpr says where a backupset row (bs) went, by its first media family (mf): 'nul' (the NUL device:
// nothing was kept), 'seeding' or 'backup'. 'seeding' is the stream of an availability group's automatic seeding,
// which msdb records as a full, copy-only backup to a virtual device named by a bare GUID, without a backup name
// and not a snapshot backup (a copy-only VSS snapshot backup has the same device shape and IS a backup: is_snapshot
// tells them apart).
const backupSinkExpr = `CASE WHEN UPPER(mf.physical_device_name) IN (N'NUL', N'NUL:') THEN 'nul'
              WHEN bs.type = 'D' AND bs.is_copy_only = 1 AND bs.is_snapshot = 0 AND mf.device_type IN (7, 107) AND bs.name IS NULL
                   AND mf.physical_device_name LIKE N'{________-____-____-____-____________}' THEN 'seeding'
              ELSE 'backup' END`

// backupsSQL: the newest finished backup per database, type (D full, I differential, L log) and sink, of this
// server's own backups. SQL Server 2016 SP1 and later. The sink is 'backup' (kept somewhere), 'nul' (the NUL
// device: nothing was kept) or 'seeding': automatic seeding of an availability group streams the database to the
// new replica as a copy-only full backup to a virtual device named by a bare GUID, and msdb records it like a
// backup; it is no backup anyone can restore, so it never counts as the last full one. Only this server's own
// rows are read (server_name): a RESTORE writes the source server's rows into msdb, and they are not this server's
// backups; a server renamed since shows no backup older than its rename.
var backupsSQL = `WITH b AS (
  SELECT bs.database_name, bs.type, bs.backup_set_id, bs.backup_start_date, bs.backup_finish_date, bs.time_zone,
         bs.backup_size, bs.compressed_backup_size, bs.is_copy_only, bs.is_snapshot, bs.name, mf.device_type, mf.physical_device_name,
         ` + backupSinkExpr + ` AS sink
    FROM msdb.dbo.backupset bs
   OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
                 WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number) mf
   WHERE bs.type IN ('D', 'I', 'L') AND bs.backup_finish_date IS NOT NULL
     AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
), r AS (
  SELECT b.*, ROW_NUMBER() OVER (PARTITION BY b.database_name, b.type, b.sink ORDER BY b.backup_finish_date DESC, b.backup_set_id DESC) AS rn
    FROM b
)
SELECT 'backup' AS kind, CAST(bs.database_name AS nvarchar(128)) AS database_name,
  CASE bs.type WHEN 'D' THEN 'full' WHEN 'I' THEN 'diff' ELSE 'log' END AS backup_type,
  bs.sink,
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
  CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), MIN(backup_start_date)), 126) + 'Z' AS oldest_utc
FROM msdb.dbo.backupset`

func (backupsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := msdbReadable(ctx, conn, "backupset"); err != nil {
		return nil, err
	}
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

// backupFilesCollector is mssql_backup_files (task 301): where the newest full, differential and log backup of each
// database went - every media family and mirror of the set (msdb.dbo.backupmediafamily, the path whole), the set's own
// facts (who took it, its name and description, checksum, damaged, password, encryption, compression, the media set's
// software), the database's files as msdb.dbo.backupfile recorded them with the set (whether the backup sits on their
// volume), its LSNs and recovery fork (the restore chain reads them), and the log backups of the last 7 days grouped by
// destination and login (two writers of one log chain). Per database and type the newest set is kept, and beside a
// copy-only one the newest that is not copy-only (DBA Dash's Last Backup lists a copy-only backup as its own row).
//
// The read goes on from a cursor (the newest backup_set_id read and that row's mark, as the job history's): an hourly
// pass over msdb.dbo.backupset of a server with years of history and 15-minute log backups is millions of rows; past
// the first read only the sets written since are read. 0066's mssql_backups stays the reader of the backup times and
// ages; this collection's rows are joined to them by the repository.
type backupFilesCollector struct{}

func init() { Register(backupFilesCollector{}) }

func (backupFilesCollector) Name() string                   { return Prefix + "backup_files" }
func (backupFilesCollector) DefaultInterval() time.Duration { return time.Hour }
func (backupFilesCollector) Applies(info Info) (bool, string) {
	return backupsCollector{}.Applies(info)
}

// Timeout: the first read is one pass over backupset (as mssql_backups' every read); the reads after it a few rows.
func (backupFilesCollector) Timeout() time.Duration { return 2 * time.Minute }

const (
	// BackupSetsCursorSource names the cursor of mssql_backup_files: the newest backup_set_id read.
	BackupSetsCursorSource = "backup_sets"
	// BackupSetsMarkSource names its mark: CHECKSUM(backup_set_uuid) of that row. msdb's numbering starts again when
	// msdb is replaced (a restore, a rebuilt server); the mark tells the row read from another row with its number.
	BackupSetsMarkSource = "backup_sets_mark"
	// backupSetsOverlap is how far behind the cursor a read starts: an identity value is allocated before its row is
	// visible. The import keeps the newer set of a key, so a set read twice changes nothing.
	backupSetsOverlap = 50
	// backupIDChunk bounds the ids one statement names (the files and the database files of the sets chosen).
	backupIDChunk = 400
	// backupWriterDays is the window of the log writers.
	backupWriterDays = 7
)

// backupFinishUTCExpr is a backupset row's finish as a UTC datetime by its own recorded offset (backupUTC's value
// before it is text): the ranking orders by it, so a backup taken in the hour the clocks go back is not outranked by
// an earlier one whose local time reads later.
const backupFinishUTCExpr = "CASE WHEN bs.time_zone BETWEEN -48 AND 56 THEN DATEADD(minute, -15 * bs.time_zone, bs.backup_finish_date)" +
	" ELSE DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), bs.backup_finish_date) END"

// backupDeviceKindExpr names a media family's (f) device: a URL by its scheme first (an S3 or Azure row whatever its
// device_type), then by device_type: 2 disk, 5 tape, 7 virtual device, 9 url (the 100s are the same devices as
// permanent backup devices).
const backupDeviceKindExpr = `CASE WHEN f.physical_device_name LIKE N'%://%' THEN 'url'
       ELSE CASE f.device_type % 100 WHEN 2 THEN 'disk' WHEN 5 THEN 'tape' WHEN 7 THEN 'virtual device' WHEN 9 THEN 'url'
            ELSE CAST(f.device_type AS varchar(12)) END END`

// backupLsn is an LSN as text: numeric(25,0) goes to the repository whole, never through a float.
func backupLsn(col string) string { return "CAST(bs." + col + " AS varchar(25)) AS " + col }

// backupSetsSQL: per database, type and copy-only the newest finished set past @p1 (a backup_set_id; 0 = all), of this
// server's own backups and kept somewhere (backupSinkExpr's 'backup': not NUL, not a seeding stream). SQL Server 2016 SP1
// and later; compression_algorithm and last_valid_restore_time exist from SQL Server 2022 and are read only where msdb
// has them (has2022), as DBA Dash reads them.
func backupSetsSQL(has2022 bool) string {
	alg, lvr := "CAST(NULL AS nvarchar(32)) AS compression_algorithm", "CAST(NULL AS varchar(33)) AS last_valid_restore_utc"
	if has2022 {
		alg = "CAST(bs.compression_algorithm AS nvarchar(32)) AS compression_algorithm"
		lvr = "CASE WHEN bs.last_valid_restore_time IS NOT NULL THEN " + strings.ReplaceAll(backupUTC("bs.last_valid_restore_time"), "bs.backup_finish_date", "bs.last_valid_restore_time") + " END AS last_valid_restore_utc"
	}
	return `WITH b AS (
  SELECT bs.backup_set_id, bs.database_name, bs.type, bs.is_copy_only, ` + backupFinishUTCExpr + ` AS finish_utc_dt,
         ` + backupSinkExpr + ` AS sink
    FROM msdb.dbo.backupset bs
   OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
                 WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number, f.mirror) mf
   WHERE bs.backup_set_id > @p1 AND bs.type IN ('D', 'I', 'L') AND bs.backup_finish_date IS NOT NULL
     AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
), r AS (
  SELECT b.backup_set_id, ROW_NUMBER() OVER (PARTITION BY b.database_name, b.type, b.is_copy_only ORDER BY b.finish_utc_dt DESC, b.backup_set_id DESC) AS rn
    FROM b WHERE b.sink = 'backup'
)
SELECT 'set' AS kind, CAST(bs.database_name AS nvarchar(128)) AS database_name,
  CASE bs.type WHEN 'D' THEN 'full' WHEN 'I' THEN 'diff' ELSE 'log' END AS backup_type,
  CAST(bs.is_copy_only AS int) AS is_copy_only, bs.backup_set_id, CAST(bs.backup_set_uuid AS varchar(36)) AS backup_set_uuid, bs.media_set_id,
  ` + backupUTC("bs.backup_start_date") + ` AS start_utc,
  ` + backupUTC("bs.backup_finish_date") + ` AS finish_utc,
  DATEDIFF(second, bs.backup_start_date, bs.backup_finish_date) AS duration_s,
  CAST(bs.backup_size AS bigint) AS size_bytes, CAST(bs.compressed_backup_size AS bigint) AS compressed_bytes,
  CAST(bs.recovery_model AS nvarchar(60)) AS recovery_model,
  CAST(bs.user_name AS nvarchar(128)) AS user_name, CAST(bs.machine_name AS nvarchar(128)) AS machine_name,
  CAST(bs.name AS nvarchar(128)) AS set_name, CAST(bs.description AS nvarchar(255)) AS description,
  CAST(bs.has_backup_checksums AS int) AS has_checksums, CAST(bs.is_damaged AS int) AS is_damaged,
  CAST(bs.is_password_protected AS int) AS is_password_protected, CAST(bs.has_bulk_logged_data AS int) AS has_bulk_logged_data,
  CAST(bs.is_readonly AS int) AS is_readonly, CAST(bs.is_single_user AS int) AS is_single_user,
  CAST(bs.is_force_offline AS int) AS is_force_offline, CAST(bs.has_incomplete_metadata AS int) AS has_incomplete_metadata,
  CAST(bs.is_snapshot AS int) AS is_snapshot,
  CAST(bs.key_algorithm AS nvarchar(32)) AS key_algorithm, CAST(bs.encryptor_type AS nvarchar(32)) AS encryptor_type,
  ` + alg + `, ` + lvr + `,
  ms.media_family_count AS family_count, ms.mirror_count, CAST(ms.software_name AS nvarchar(128)) AS software_name,
  ms.software_vendor_id, CAST(ms.is_compressed AS int) AS media_compressed, CAST(ms.is_encrypted AS int) AS media_encrypted,
  CAST(ms.is_password_protected AS int) AS media_password,
  CAST(bs.database_guid AS varchar(36)) AS database_guid, CAST(bs.family_guid AS varchar(36)) AS family_guid,
  CAST(bs.first_recovery_fork_guid AS varchar(36)) AS first_recovery_fork_guid, CAST(bs.last_recovery_fork_guid AS varchar(36)) AS last_recovery_fork_guid,
  ` + backupLsn("fork_point_lsn") + `, ` + backupLsn("first_lsn") + `, ` + backupLsn("last_lsn") + `, ` + backupLsn("checkpoint_lsn") + `,
  ` + backupLsn("database_backup_lsn") + `, ` + backupLsn("differential_base_lsn") + `,
  CAST(bs.differential_base_guid AS varchar(36)) AS differential_base_guid, CAST(bs.begins_log_chain AS int) AS begins_log_chain
FROM r
JOIN msdb.dbo.backupset bs ON bs.backup_set_id = r.backup_set_id
LEFT JOIN msdb.dbo.backupmediaset ms ON ms.media_set_id = bs.media_set_id
WHERE r.rn = 1
ORDER BY bs.backup_set_id`
}

// backupHas2022SQL: whether msdb's backupset has SQL Server 2022's two columns (both or neither).
const backupHas2022SQL = `SELECT CASE WHEN COL_LENGTH('msdb.dbo.backupset', 'compression_algorithm') IS NOT NULL
  AND COL_LENGTH('msdb.dbo.backupset', 'last_valid_restore_time') IS NOT NULL THEN 1 ELSE 0 END`

// backupNewestSQL: the newest row of backupset and its mark - the cursor after this read (read before the sets: a row
// written in between is read now and again by the next read, never lost).
const backupNewestSQL = `SELECT TOP (1) bs.backup_set_id, CAST(CHECKSUM(bs.backup_set_uuid) AS bigint) AS mark
FROM msdb.dbo.backupset bs ORDER BY bs.backup_set_id DESC`

// backupMarkSQL: the mark of the row at @p1 (no row: msdb no longer has it).
const backupMarkSQL = `SELECT CAST(CHECKSUM(bs.backup_set_uuid) AS bigint) FROM msdb.dbo.backupset bs WHERE bs.backup_set_id = @p1`

// backupFilesSQL: every media family and mirror of the sets named ({ids}: a list of backup_set_id numbers; not a
// format string - the device expression holds a LIKE pattern with '%').
const backupFilesSQL = `SELECT 'file' AS kind, bs.backup_set_id, CAST(f.family_sequence_number AS int) AS family, CAST(f.mirror AS int) AS mirror,
  ` + backupDeviceKindExpr + ` AS device_kind,
  CAST(f.logical_device_name AS nvarchar(128)) AS logical_name, CAST(f.physical_device_name AS nvarchar(260)) AS path
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = bs.media_set_id
WHERE bs.backup_set_id IN ({ids})
ORDER BY bs.backup_set_id, f.family_sequence_number, f.mirror`

// backupDBFilesSQL: the database's data and log files as msdb recorded them with each set named ({ids}).
const backupDBFilesSQL = `SELECT 'dbfile' AS kind, bf.backup_set_id, CAST(bf.file_number AS int) AS file_number, CAST(bf.file_type AS varchar(1)) AS file_type,
  CAST(bf.logical_name AS nvarchar(128)) AS logical_name, CAST(bf.physical_name AS nvarchar(260)) AS physical_name
FROM msdb.dbo.backupfile bf
WHERE bf.backup_set_id IN ({ids}) AND bf.file_type IN ('D', 'L')
ORDER BY bf.backup_set_id, bf.file_number`

// backupWritersSQL: the log backups of the last backupWriterDays days that are not copy-only and were kept somewhere,
// by database, the device and directory of their first file (family 1, mirror 0: a striped set's other families and its
// mirrors go where its first one goes, by the same job), the media's software and the login. The repository folds the
// directories into destination roots. The window is by backup_finish_date, the column msdb indexes for its own history
// cleanup.
var backupWritersSQL = fmt.Sprintf(`SELECT 'writer' AS kind, CAST(bs.database_name AS nvarchar(128)) AS database_name, x.device_kind,
  CAST(x.directory AS nvarchar(260)) AS directory, CAST(ms.software_name AS nvarchar(128)) AS software_name,
  CAST(bs.user_name AS nvarchar(128)) AS user_name, COUNT(*) AS sets,
  MIN(%[1]s) AS first_utc, MAX(%[1]s) AS last_utc
FROM msdb.dbo.backupset bs
CROSS APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
              WHERE f.media_set_id = bs.media_set_id ORDER BY f.mirror, f.family_sequence_number) f
CROSS APPLY (SELECT %[2]s AS device_kind,
                    CASE WHEN PATINDEX(N'%%[\/]%%', REVERSE(f.physical_device_name)) > 0
                         THEN LEFT(f.physical_device_name, LEN(f.physical_device_name) - PATINDEX(N'%%[\/]%%', REVERSE(f.physical_device_name)) + 1)
                         ELSE f.physical_device_name END AS directory) x
LEFT JOIN msdb.dbo.backupmediaset ms ON ms.media_set_id = bs.media_set_id
WHERE bs.backup_finish_date >= DATEADD(day, -%[3]d, GETDATE()) AND bs.type = 'L' AND bs.is_copy_only = 0
  AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
  AND UPPER(f.physical_device_name) NOT IN (N'NUL', N'NUL:')
GROUP BY bs.database_name, x.device_kind, x.directory, ms.software_name, bs.user_name`, backupUTC("bs.backup_finish_date"), backupDeviceKindExpr, backupWriterDays)

// backupFileTables are the msdb tables the read touches: a login without SELECT on one is skipped with it named.
var backupFileTables = []string{"backupset", "backupmediafamily", "backupmediaset", "backupfile"}

// Run is the read without a cursor (a RunOnce that does not know CursorCollector): one whole pass every time.
func (c backupFilesCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	return c.RunFrom(ctx, conn, info, nil)
}

// RunFrom reads the databases, the newest sets past the cursor with their files, and the writers' window.
func (backupFilesCollector) RunFrom(ctx context.Context, conn *sql.Conn, info Info, cursor SeqCursorFunc) ([]collect.Row, error) {
	for _, t := range backupFileTables {
		if err := msdbReadable(ctx, conn, t); err != nil {
			return nil, err
		}
	}
	rows, err := QueryRows(ctx, conn, backupDatabasesSQL(info.HADREnabled))
	if err != nil {
		return nil, err
	}
	var has2022 int64
	if err := conn.QueryRowContext(ctx, backupHas2022SQL).Scan(&has2022); err != nil {
		return nil, err
	}
	// the cursor after this read: the newest row now (none: msdb holds no backup)
	var newest, newestMark sql.NullInt64
	if err := conn.QueryRowContext(ctx, backupNewestSQL).Scan(&newest, &newestMark); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	from := int64(0)
	if cursor != nil {
		last, haveLast, err := cursor(ctx, BackupSetsCursorSource)
		if err != nil {
			return nil, fmt.Errorf("backup sets cursor: %w", err)
		}
		mark, haveMark, err := cursor(ctx, BackupSetsMarkSource)
		if err != nil {
			return nil, fmt.Errorf("backup sets cursor mark: %w", err)
		}
		if haveLast && haveMark && last > 0 {
			var now sql.NullInt64
			switch err := conn.QueryRowContext(ctx, backupMarkSQL, last).Scan(&now); {
			case errors.Is(err, sql.ErrNoRows):
			case err != nil:
				return nil, err
			default:
				if now.Valid && now.Int64 == mark {
					from = backupReadFrom(last)
				}
			}
		}
	}
	sets, err := QueryRows(ctx, conn, backupSetsSQL(has2022 == 1), from)
	if err != nil {
		return nil, err
	}
	rows = append(rows, sets...)
	ids := backupSetIDs(sets)
	for i := 0; i < len(ids); i += backupIDChunk {
		list := strings.Join(ids[i:min(i+backupIDChunk, len(ids))], ", ")
		files, err := QueryRows(ctx, conn, strings.Replace(backupFilesSQL, "{ids}", list, 1))
		if err != nil {
			return nil, err
		}
		dbf, err := QueryRows(ctx, conn, strings.Replace(backupDBFilesSQL, "{ids}", list, 1))
		if err != nil {
			return nil, err
		}
		rows = append(append(rows, files...), dbf...)
	}
	writers, err := QueryRows(ctx, conn, backupWritersSQL)
	if err != nil {
		return nil, err
	}
	rows = append(append(rows, writers...), collect.Row{"kind": "writers_read"}, collect.Row{"kind": "read", "cursor": cursor != nil, "from": from})
	if cursor != nil && newest.Valid {
		rows = append(rows, collect.Row{"kind": "cursor", "last_set_id": newest.Int64, "mark": newestMark.Int64})
	}
	return rows, nil
}

// backupReadFrom is where a cursor read starts: a little behind the newest set read while that row is still the row
// that was read (msdb not replaced).
func backupReadFrom(last int64) int64 {
	if last <= backupSetsOverlap {
		return 0
	}
	return last - backupSetsOverlap
}

// backupSetIDs is the backup_set_id of each set row, as the decimal text a statement names (numbers the server gave).
func backupSetIDs(sets []collect.Row) []string {
	var out []string
	for _, s := range sets {
		switch v := s["backup_set_id"].(type) {
		case int64:
			out = append(out, strconv.FormatInt(v, 10))
		case int32:
			out = append(out, strconv.FormatInt(int64(v), 10))
		case int:
			out = append(out, strconv.Itoa(v))
		}
	}
	return out
}
