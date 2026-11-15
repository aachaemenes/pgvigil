package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// restoreChainCollector is mssql_restore_chain (task 304): what a restore of each database needs, read from this
// server's msdb - the newest full that is not copy-only with the newest differential after it, the newest copy-only full,
// and every log backup since the start set they give, each with its LSNs, its recovery fork and every file of its media.
// The chain itself (which sets, in which order, where it breaks) is decided by the repository (pgvigil.mssql_restore_chain),
// one rule for a standalone server and an availability group whose replicas each hold part of the log.
//
// The start set is chosen as dbatools v2.9.1's Get-DbaDbBackupHistory -Last chooses its full and its differential
// (public/Get-DbaDbBackupHistory.ps1 L365-437 and L440-612: ranked by last_lsn, then backup_finish_date; a differential
// kept only when it follows the full: its database_backup_lsn equals the full's checkpoint_lsn, L415), and, where pgvigil
// differs on purpose, by the design fold of task 304: a copy-only full is a start set too (it restores like any full),
// the start set is the candidate with the greatest last_lsn, and logs are chosen by LSN and recovery fork only (a
// database_backup_lsn that does not match is a mark, never a filter). The recovery fork is the newest set's by
// backup_finish_date (a restore over the database to an older point starts a fork whose LSNs lie BELOW the old fork's
// newest: the greatest last_lsn would follow the abandoned fork), as dbatools keeps only the newest set's fork. dbatools is MIT-licensed, Copyright (c) 2018
// Chrissy LeMaire; no code of it is copied: the statements are pgvigil's own. pgvigil never takes or restores a backup:
// the package's statements hold neither verb (TestRestoreChainSQLHasNoBackupOrRestoreVerb).
type restoreChainCollector struct{}

func init() { Register(restoreChainCollector{}) }

func (restoreChainCollector) Name() string                   { return Prefix + "restore_chain" }
func (restoreChainCollector) DefaultInterval() time.Duration { return time.Hour }
func (restoreChainCollector) Applies(info Info) (bool, string) {
	return backupsCollector{}.Applies(info)
}

// Timeout: one ranked pass over msdb.dbo.backupset (as mssql_backups), then the logs since each start set.
func (restoreChainCollector) Timeout() time.Duration { return 3 * time.Minute }

const (
	// restoreLogKeep is the most log backups one database sends in a read: 7 days of 5-minute log backups. A database
	// with more since its start set sends the newest restoreLogKeep and the count of all; the repository then holds a gap
	// below the oldest log sent as 'not read whole', never a break (0147's covered_since).
	restoreLogKeep = 2016
	// restoreNoStartDays is how far back a database without a start set on this server sends its logs (a replica whose
	// fulls run elsewhere); the 'read' row says it, and a gap older than it is held the same way.
	restoreNoStartDays = 7
)

// restoreLogKeepNow is restoreLogKeep, or a LOWER keep from PGVIGIL_RESTORE_LOG_KEEP (1 to restoreLogKeep; anything else
// is ignored): the hook a proof uses to cap a read without thousands of log backups. It can never raise the keep.
func restoreLogKeepNow() int {
	if n, err := strconv.Atoi(strings.TrimSpace(os.Getenv("PGVIGIL_RESTORE_LOG_KEEP"))); err == nil && n >= 1 && n < restoreLogKeep {
		return n
	}
	return restoreLogKeep
}

// restoreSetCols are the columns of a set row (bs = backupset, mf = its first media family): LSNs as text (numeric(25,0)
// is wider than a Go int64), guids as text, the times in UTC by the row's own offset.
const restoreSetCols = `CAST(bs.database_name AS nvarchar(128)) AS database_name, bs.backup_set_id,
  CAST(bs.backup_set_uuid AS varchar(36)) AS backup_set_uuid, bs.type AS set_type, CAST(bs.is_copy_only AS int) AS is_copy_only,
  CAST(bs.position AS int) AS position, CAST(bs.is_snapshot AS int) AS is_snapshot, CAST(bs.has_bulk_logged_data AS int) AS has_bulk_logged_data,
  CAST(bs.is_damaged AS int) AS is_damaged, CAST(bs.begins_log_chain AS int) AS begins_log_chain,
  CAST(bs.first_lsn AS varchar(25)) AS first_lsn, CAST(bs.last_lsn AS varchar(25)) AS last_lsn,
  CAST(bs.checkpoint_lsn AS varchar(25)) AS checkpoint_lsn, CAST(bs.database_backup_lsn AS varchar(25)) AS database_backup_lsn,
  CAST(bs.differential_base_lsn AS varchar(25)) AS differential_base_lsn, CAST(bs.differential_base_guid AS varchar(36)) AS differential_base_guid,
  CAST(bs.fork_point_lsn AS varchar(25)) AS fork_point_lsn, CAST(bs.database_guid AS varchar(36)) AS database_guid,
  CAST(bs.family_guid AS varchar(36)) AS family_guid, CAST(bs.first_recovery_fork_guid AS varchar(36)) AS first_recovery_fork_guid,
  CAST(bs.last_recovery_fork_guid AS varchar(36)) AS last_recovery_fork_guid, CAST(bs.recovery_model AS nvarchar(60)) AS recovery_model,
  CAST(bs.user_name AS nvarchar(128)) AS user_name, CAST(bs.backup_size AS bigint) AS size_bytes,
  CAST(bs.compressed_backup_size AS bigint) AS compressed_bytes`

// restoreSetsSQL: per database the start-set candidates and the logs since the start set, of this server's own rows and
// of the database as the server lists it now (finished after its creation, an hour of slack: 0066's rule), each set once
// by backup_set_uuid (a RESTORE on this server writes the restored sets' rows into msdb again under the same uuid: the
// lowest backup_set_id is kept), and only of the database's current recovery fork: the fork of its newest set by
// backup_finish_date, and of the parent fork the sets that end at or before the fork point. The same pass counts the
// partial and file backups (types F, G, P, Q), which no chain here reads. %s is the last_valid_restore_time column (SQL
// Server 2022 and later) or NULL. One ranked pass finds the candidates; the logs are read behind one floor on
// backup_finish_date (the column msdb indexes for its history cleanup), the earliest start set's start less an hour, and
// then per database by LSN.
func restoreSetsSQL(has2022 bool) string {
	return restoreSetsSQLKeep(has2022, restoreLogKeepNow())
}

// restoreForkFilter keeps a set (bs) of the database's current fork (fk), or of its parent fork at or before the fork point.
const restoreForkFilter = `(fk.fork IS NULL OR bs.last_recovery_fork_guid = fk.fork
          OR (bs.last_recovery_fork_guid = fk.parent AND bs.last_lsn <= fk.fork_point_lsn))`

func restoreSetsSQLKeep(has2022 bool, keep int) string {
	lvr := "CAST(NULL AS varchar(33))"
	if has2022 {
		lvr = "CASE WHEN bs.last_valid_restore_time IS NOT NULL THEN " + backupUTC("bs.last_valid_restore_time") + " END"
	}
	return fmt.Sprintf(`SET NOCOUNT ON;
IF OBJECT_ID('tempdb..#pgv_rc_fork') IS NOT NULL DROP TABLE #pgv_rc_fork;
IF OBJECT_ID('tempdb..#pgv_rc_cand') IS NOT NULL DROP TABLE #pgv_rc_cand;
IF OBJECT_ID('tempdb..#pgv_rc_start') IS NOT NULL DROP TABLE #pgv_rc_start;
-- per database its current recovery fork (the newest full, differential or log by backup_finish_date), the parent fork
-- and fork point from the set that crossed into it, and the count of partial and file backups
WITH dbs AS (
  SELECT d.name, d.create_date FROM sys.databases d WHERE d.database_id <> 2 AND d.source_database_id IS NULL
), n AS (
  SELECT bs.database_name, bs.last_recovery_fork_guid,
         ROW_NUMBER() OVER (PARTITION BY bs.database_name ORDER BY CASE WHEN bs.type IN ('D', 'I', 'L') THEN 0 ELSE 1 END,
                                                                   bs.backup_finish_date DESC, bs.backup_set_id DESC) AS rn,
         SUM(CASE WHEN bs.type IN ('F', 'G', 'P', 'Q') THEN 1 ELSE 0 END) OVER (PARTITION BY bs.database_name) AS partial_sets
    FROM msdb.dbo.backupset bs
    JOIN dbs ON dbs.name = bs.database_name AND bs.backup_finish_date >= DATEADD(hour, -1, dbs.create_date)
   WHERE bs.type IN ('D', 'I', 'L', 'F', 'G', 'P', 'Q') AND bs.backup_finish_date IS NOT NULL
     AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
)
SELECT n.database_name, n.last_recovery_fork_guid AS fork, p.first_recovery_fork_guid AS parent, p.fork_point_lsn, n.partial_sets
  INTO #pgv_rc_fork
  FROM n
 OUTER APPLY (SELECT TOP (1) x.first_recovery_fork_guid, x.fork_point_lsn FROM msdb.dbo.backupset x
               WHERE x.database_name = n.database_name AND x.last_recovery_fork_guid = n.last_recovery_fork_guid
                 AND x.first_recovery_fork_guid <> n.last_recovery_fork_guid AND x.fork_point_lsn IS NOT NULL
                 AND x.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
               ORDER BY x.last_lsn, x.backup_set_id) p
 WHERE n.rn = 1;
WITH dbs AS (
  SELECT d.name, d.create_date FROM sys.databases d WHERE d.database_id <> 2 AND d.source_database_id IS NULL
), b AS (
  SELECT bs.backup_set_id, bs.database_name, bs.type, bs.is_copy_only, bs.first_lsn, bs.last_lsn, bs.checkpoint_lsn,
         bs.database_backup_lsn, bs.differential_base_guid, bs.backup_set_uuid, bs.backup_start_date,
         `+backupSinkExpr+` AS sink,
         ROW_NUMBER() OVER (PARTITION BY bs.backup_set_uuid ORDER BY bs.backup_set_id) AS dup
    FROM msdb.dbo.backupset bs
    JOIN dbs ON dbs.name = bs.database_name AND bs.backup_finish_date >= DATEADD(hour, -1, dbs.create_date)
    JOIN #pgv_rc_fork fk ON fk.database_name = bs.database_name
   OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
                 WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number, f.mirror) mf
   WHERE bs.type IN ('D', 'I') AND bs.backup_finish_date IS NOT NULL
     AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
     AND `+restoreForkFilter+`
), r AS (
  SELECT b.*, ROW_NUMBER() OVER (PARTITION BY b.database_name, b.type, b.is_copy_only, b.sink ORDER BY b.last_lsn DESC, b.backup_set_id DESC) AS rn
    FROM b WHERE b.sink IN ('backup', 'nul') AND b.dup = 1
)
SELECT r.* INTO #pgv_rc_cand FROM r WHERE r.rn = 1;
-- the start set per database: the greatest last_lsn among the newest full that is not copy-only (or its differential
-- when that follows it: the base's uuid, else dbatools' LSN test) and the newest copy-only full
WITH nf AS (SELECT * FROM #pgv_rc_cand WHERE type = 'D' AND is_copy_only = 0 AND sink = 'backup'),
     nd AS (SELECT c.* FROM #pgv_rc_cand c JOIN nf ON nf.database_name = c.database_name
             WHERE c.type = 'I' AND c.sink = 'backup' AND c.last_lsn > nf.last_lsn
               AND (c.differential_base_guid = nf.backup_set_uuid OR c.database_backup_lsn = nf.checkpoint_lsn)),
     cf AS (SELECT * FROM #pgv_rc_cand WHERE type = 'D' AND is_copy_only = 1 AND sink = 'backup'),
     s AS (SELECT database_name, first_lsn, last_lsn, backup_start_date FROM nd
           UNION ALL SELECT nf.database_name, nf.first_lsn, nf.last_lsn, nf.backup_start_date FROM nf WHERE NOT EXISTS (SELECT 1 FROM nd WHERE nd.database_name = nf.database_name)
           UNION ALL SELECT database_name, first_lsn, last_lsn, backup_start_date FROM cf),
     t AS (SELECT s.*, ROW_NUMBER() OVER (PARTITION BY s.database_name ORDER BY s.last_lsn DESC) AS rn FROM s)
SELECT database_name, first_lsn, last_lsn, backup_start_date INTO #pgv_rc_start FROM t WHERE rn = 1;
DECLARE @floor datetime = (SELECT DATEADD(hour, -1, MIN(backup_start_date)) FROM #pgv_rc_start);
DECLARE @nostart datetime = DATEADD(day, -%[2]d, GETDATE());
IF @floor IS NULL OR @floor > @nostart SET @floor = @nostart;
WITH lg0 AS (
  SELECT bs.backup_set_id, bs.database_name, bs.last_lsn, bs.first_lsn, bs.is_copy_only,
         `+backupSinkExpr+` AS sink,
         ROW_NUMBER() OVER (PARTITION BY bs.backup_set_uuid ORDER BY bs.backup_set_id) AS dup
    FROM msdb.dbo.backupset bs
    JOIN sys.databases d ON d.name = bs.database_name AND bs.backup_finish_date >= DATEADD(hour, -1, d.create_date)
    JOIN #pgv_rc_fork fk ON fk.database_name = bs.database_name
    LEFT JOIN #pgv_rc_start st ON st.database_name = bs.database_name
   OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
                 WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number, f.mirror) mf
   WHERE bs.type = 'L' AND bs.backup_finish_date IS NOT NULL AND bs.backup_finish_date >= @floor
     AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
     AND `+restoreForkFilter+`
     AND (st.database_name IS NULL AND bs.backup_finish_date >= @nostart
          OR bs.last_lsn > st.first_lsn AND bs.backup_finish_date >= DATEADD(hour, -1, st.backup_start_date))
), lg AS (
  SELECT lg0.*, ROW_NUMBER() OVER (PARTITION BY lg0.database_name ORDER BY lg0.last_lsn DESC, lg0.backup_set_id DESC) AS newest,
         COUNT(*) OVER (PARTITION BY lg0.database_name) AS logs_since
    FROM lg0 WHERE lg0.dup = 1
), g AS (
  -- the server's own gap count over its logs that are not copy-only: a kept log whose first_lsn passes every earlier
  -- log's last_lsn. A log to NUL is a hole the verdict names, not a gap, and the log after it is no gap either.
  SELECT lg.*, CASE WHEN lg.sink = 'backup' AND lg.is_copy_only = 0
                         AND lg.first_lsn > MAX(CASE WHEN lg.is_copy_only = 0 THEN lg.last_lsn END)
                               OVER (PARTITION BY lg.database_name ORDER BY lg.last_lsn, lg.backup_set_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
                    THEN 1 ELSE 0 END AS gap
    FROM lg
), g2 AS (
  SELECT g.*, SUM(g.gap) OVER (PARTITION BY g.database_name) AS gaps FROM g
)
SELECT 'set' AS kind, `+restoreSetCols+`, x.sink, x.role, x.logs_since, x.gaps, fk.partial_sets,
  `+backupUTC("bs.backup_start_date")+` AS start_utc, `+backupUTC("bs.backup_finish_date")+` AS finish_utc,
  %[1]s AS last_valid_restore_utc,
  CAST(ms.software_name AS nvarchar(128)) AS software_name, ms.media_family_count AS family_count, ms.mirror_count
FROM (SELECT c.backup_set_id, c.sink, CASE WHEN c.type = 'I' THEN 'diff' WHEN c.is_copy_only = 1 THEN 'copy_full' ELSE 'full' END AS role,
             NULL AS logs_since, NULL AS gaps
        FROM #pgv_rc_cand c
      UNION ALL
      SELECT g2.backup_set_id, g2.sink, 'log', g2.logs_since, g2.gaps
        FROM g2 WHERE g2.newest <= %[3]d) x
JOIN msdb.dbo.backupset bs ON bs.backup_set_id = x.backup_set_id
LEFT JOIN #pgv_rc_fork fk ON fk.database_name = bs.database_name
LEFT JOIN msdb.dbo.backupmediaset ms ON ms.media_set_id = bs.media_set_id
ORDER BY bs.database_name, bs.last_lsn, bs.backup_set_id;
DROP TABLE #pgv_rc_cand; DROP TABLE #pgv_rc_start; DROP TABLE #pgv_rc_fork;`, lvr, restoreNoStartDays, keep)
}

// restoreFilesSQL: every media family and mirror of the sets named ({ids}).
const restoreFilesSQL = `SELECT 'file' AS kind, bs.backup_set_id, CAST(f.family_sequence_number AS int) AS family, CAST(f.mirror AS int) AS mirror,
  ` + backupDeviceKindExpr + ` AS device_kind, CAST(f.physical_device_name AS nvarchar(260)) AS path
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = bs.media_set_id
WHERE bs.backup_set_id IN ({ids})
ORDER BY bs.backup_set_id, f.family_sequence_number, f.mirror`

// Run reads the databases, the start sets and logs, and the files of every set read.
func (restoreChainCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	for _, t := range backupFileTables[:3] {
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
	keep := restoreLogKeepNow()
	sets, err := QueryRows(ctx, conn, restoreSetsSQLKeep(has2022 == 1, keep))
	if err != nil {
		return nil, err
	}
	rows = append(rows, sets...)
	ids := backupSetIDs(sets)
	for i := 0; i < len(ids); i += backupIDChunk {
		files, err := QueryRows(ctx, conn, strings.Replace(restoreFilesSQL, "{ids}", strings.Join(ids[i:min(i+backupIDChunk, len(ids))], ", "), 1))
		if err != nil {
			return nil, err
		}
		rows = append(rows, files...)
	}
	return append(rows, collect.Row{"kind": "read", "log_keep": keep, "nostart_days": restoreNoStartDays}), nil
}

// restoreVerbs finds a BACKUP or RESTORE statement verb anywhere in T-SQL text - after IF / ELSE on one line or inside a
// dynamic string too - by the word that such a statement takes next (not 'backupset', 'msdb.dbo.restorehistory' or a
// column name, which no such word follows).
var restoreVerbs = regexp.MustCompile(`(?i)\b(BACKUP|RESTORE)\s+(DATABASE|LOG|HEADERONLY|FILELISTONLY|VERIFYONLY|LABELONLY|CERTIFICATE|MASTER\s+KEY|SERVICE\s+MASTER\s+KEY|SYMMETRIC\s+KEY)\b`)
