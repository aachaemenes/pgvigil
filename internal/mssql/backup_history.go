package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
	"github.com/aachaemenes/pgvigil/internal/config"
	"github.com/aachaemenes/pgvigil/internal/mssqlopen"
)

// backupHistoryCollector is mssql_backup_history (task 301b): per database, type (full / diff / log) and copy-only the
// newest backupHistoryN sets of this server's own backups that were kept somewhere (301's backupSinkExpr), with family
// 1's device and path, and the newest restoreHistoryM restores per destination database and restore type
// (msdb.dbo.restorehistory with the set it restored). Both read on from a cursor (the newest id read and that row's mark,
// as mssql_backup_files does): the first read is one whole pass, the reads after it only what is new. The restores are
// read only with SELECT on msdb.dbo.restorehistory (HAS_PERMS_BY_NAME, as indexes.go); without it the read says
// 'no right' every hour and asks the server nothing more.
type backupHistoryCollector struct{}

// backupChecksCollector is mssql_backup_checks (task 301b): per database whether a FULL or BULK_LOGGED database is
// pseudo-simple (sys.database_recovery_status' last_log_backup_lsn; Database#39), per instance the default backup path
// and whether it is a directory the service account sees (Instance#14), and - an admin's opt-in per instance - whether
// the newest backup's files are still where msdb says they were written (Database#7). sys.databases is read first;
// sys.database_recovery_status only for the databases that are ONLINE, not a snapshot, not a secondary replica's and,
// unless the instance opts in, not AUTO_CLOSE: the recovery-status read opens a closed AUTO_CLOSE database (probe
// 301bP2, SQL Server 2019 and 2022), so its cell says 'not read: AUTO_CLOSE (reading would open it)'.
type backupChecksCollector struct{}

func init() {
	Register(backupHistoryCollector{})
	Register(backupChecksCollector{})
}

func (backupHistoryCollector) Name() string                   { return Prefix + "backup_history" }
func (backupHistoryCollector) DefaultInterval() time.Duration { return time.Hour }
func (backupHistoryCollector) Applies(info Info) (bool, string) {
	return backupsCollector{}.Applies(info)
}

// Timeout: the first read is one pass over backupset and restorehistory; the reads after it a few rows.
func (backupHistoryCollector) Timeout() time.Duration { return 2 * time.Minute }

func (backupChecksCollector) Name() string                   { return Prefix + "backup_checks" }
func (backupChecksCollector) DefaultInterval() time.Duration { return time.Hour }
func (backupChecksCollector) Applies(info Info) (bool, string) {
	return backupsCollector{}.Applies(info)
}
func (backupChecksCollector) Timeout() time.Duration { return 2 * time.Minute }

const (
	// BackupHistoryCursorSource names mssql_backup_history's set cursor: the newest backup_set_id read
	// (pgvigil.mssql_hadr_cursor; the arm is 0300's).
	BackupHistoryCursorSource = "backup_history"
	// BackupHistoryMarkSource names the set cursor's mark: CHECKSUM(backup_set_uuid) of that row.
	BackupHistoryMarkSource = "backup_history_mark"
	// RestoreHistoryCursorSource names its restore cursor: the newest restore_history_id read.
	RestoreHistoryCursorSource = "restore_history"
	// RestoreHistoryMarkSource names the restore cursor's mark: CHECKSUM(restore_date, destination_database_name,
	// backup_set_id) of that row.
	RestoreHistoryMarkSource = "restore_history_mark"
	// backupHistoryN and restoreHistoryM: decision E2 (the repository keeps the same numbers, 0191).
	backupHistoryN  = 10
	restoreHistoryM = 20
	// backupPathTimeout caps the default backup path's one existence call (a share that does not answer).
	backupPathTimeout = 20 * time.Second
)

// backupCheckOptions says what an instance opted in to: reading AUTO_CLOSE databases' recovery status
// (reads.auto_close_databases) and checking the newest backups' files (Database#7). Both are an admin's opt-in, off by
// default (the locked-down default has the fewest side effects); backup_checks_wiring.go's
// init() sets this from the instance's configuration.
var backupCheckOptions = func(Info) (autoClose, files bool) { return false, false }

// backupSetHistorySQL: per database, type and copy-only the newest backupHistoryN finished sets past @p1 (0 = all) of this
// server's own backups kept somewhere, ranked by their UTC finish (backupFinishUTCExpr), with family 1's device kind and
// path (mirror 0). SQL Server 2022's compression_algorithm only where msdb has it.
func backupSetHistorySQL(has2022 bool) string {
	alg := "CAST(NULL AS nvarchar(32)) AS compression_algorithm"
	if has2022 {
		alg = "CAST(bs.compression_algorithm AS nvarchar(32)) AS compression_algorithm"
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
  CAST(bs.is_copy_only AS int) AS is_copy_only, bs.backup_set_id, CAST(bs.backup_set_uuid AS varchar(36)) AS backup_set_uuid,
  ` + backupUTC("bs.backup_start_date") + ` AS start_utc,
  ` + backupUTC("bs.backup_finish_date") + ` AS finish_utc,
  CAST(bs.backup_size AS bigint) AS size_bytes, CAST(bs.compressed_backup_size AS bigint) AS compressed_bytes,
  CAST(bs.recovery_model AS nvarchar(60)) AS recovery_model, CAST(bs.user_name AS nvarchar(128)) AS user_name,
  CAST(bs.machine_name AS nvarchar(128)) AS machine_name, CAST(bs.server_name AS nvarchar(128)) AS server_name,
  CAST(bs.name AS nvarchar(128)) AS set_name, CAST(bs.has_backup_checksums AS int) AS has_checksums,
  CAST(bs.is_damaged AS int) AS is_damaged, CAST(bs.is_password_protected AS int) AS is_password_protected,
  CAST(bs.is_snapshot AS int) AS is_snapshot, CAST(bs.has_bulk_logged_data AS int) AS has_bulk_logged_data,
  CAST(bs.is_readonly AS int) AS is_readonly, CAST(bs.is_force_offline AS int) AS is_force_offline,
  CAST(bs.is_single_user AS int) AS is_single_user, CAST(bs.encryptor_type AS nvarchar(32)) AS encryptor_type,
  CAST(bs.key_algorithm AS nvarchar(32)) AS key_algorithm, ` + alg + `,
  ms.media_family_count AS family_count, CAST(bs.position AS int) AS position, f1.device_kind, f1.path,
  ` + backupLsn("first_lsn") + `, ` + backupLsn("last_lsn") + `, ` + backupLsn("checkpoint_lsn") + `, ` + backupLsn("database_backup_lsn") + `,
  CAST(bs.differential_base_guid AS varchar(36)) AS differential_base_guid
FROM r
JOIN msdb.dbo.backupset bs ON bs.backup_set_id = r.backup_set_id
LEFT JOIN msdb.dbo.backupmediaset ms ON ms.media_set_id = bs.media_set_id
OUTER APPLY (SELECT TOP (1) ` + backupDeviceKindExpr + ` AS device_kind, CAST(f.physical_device_name AS nvarchar(260)) AS path
               FROM msdb.dbo.backupmediafamily f WHERE f.media_set_id = bs.media_set_id
              ORDER BY f.mirror, f.family_sequence_number) f1
WHERE r.rn <= ` + strconv.Itoa(backupHistoryN) + `
ORDER BY bs.backup_set_id`
}

// restoreLocalUTC is a restorehistory time (the server's local time, no offset recorded) as UTC by the server's
// offset at the read: a restore made under the other daylight-saving offset (before the clocks last changed) reads an
// hour off (said in docs/backups-sqlserver.md and on the page).
func restoreLocalUTC(col string) string {
	return "CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), " + col + "), 126) + 'Z'"
}

// restoreHistorySQL: per destination database and restore type the newest restoreHistoryM restores past @p1 (a
// restore_history_id; 0 = all), with the set restored (its server, database, type, UTC finish and uuid) and family 1's
// path (mirror 0).
var restoreHistorySQL = `WITH r AS (
  SELECT rh.restore_history_id, ROW_NUMBER() OVER (PARTITION BY rh.destination_database_name, rh.restore_type ORDER BY rh.restore_date DESC, rh.restore_history_id DESC) AS rn
    FROM msdb.dbo.restorehistory rh WHERE rh.restore_history_id > @p1
)
SELECT 'restore' AS kind, rh.restore_history_id, ` + restoreLocalUTC("rh.restore_date") + ` AS restore_utc,
  CAST(rh.destination_database_name AS nvarchar(128)) AS destination_database_name, CAST(rh.user_name AS nvarchar(128)) AS user_name,
  CAST(rh.restore_type AS varchar(1)) AS restore_type, CAST(rh.[replace] AS int) AS [replace], CAST(rh.recovery AS int) AS recovery,
  CASE WHEN rh.stop_at IS NOT NULL THEN ` + restoreLocalUTC("rh.stop_at") + ` END AS stop_at_utc,
  CAST(bs.server_name AS nvarchar(128)) AS source_server, CAST(bs.database_name AS nvarchar(128)) AS source_database,
  CAST(bs.type AS varchar(1)) AS source_type,
  CASE WHEN bs.backup_set_id IS NOT NULL THEN ` + backupUTC("bs.backup_finish_date") + ` END AS source_finish_utc,
  CAST(bs.backup_set_uuid AS varchar(36)) AS source_backup_set_uuid, f1.path AS source_path
FROM r
JOIN msdb.dbo.restorehistory rh ON rh.restore_history_id = r.restore_history_id
LEFT JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
OUTER APPLY (SELECT TOP (1) CAST(f.physical_device_name AS nvarchar(260)) AS path FROM msdb.dbo.backupmediafamily f
              WHERE f.media_set_id = bs.media_set_id ORDER BY f.mirror, f.family_sequence_number) f1
WHERE r.rn <= ` + strconv.Itoa(restoreHistoryM) + `
ORDER BY rh.restore_history_id`

// restoreRightSQL: SELECT on restorehistory (every login reads it through msdb's guest unless it is denied: probe 301bP1).
const restoreRightSQL = `SELECT CAST(ISNULL(HAS_PERMS_BY_NAME(N'msdb.dbo.restorehistory', 'OBJECT', 'SELECT'), 0) AS int)`

// restoreNewestSQL and restoreMarkSQL: the newest restorehistory row and its mark; the mark of the row at @p1.
const (
	restoreNewestSQL = `SELECT TOP (1) rh.restore_history_id, CAST(CHECKSUM(rh.restore_date, rh.destination_database_name, rh.backup_set_id) AS bigint)
FROM msdb.dbo.restorehistory rh ORDER BY rh.restore_history_id DESC`
	restoreMarkSQL = `SELECT CAST(CHECKSUM(rh.restore_date, rh.destination_database_name, rh.backup_set_id) AS bigint) FROM msdb.dbo.restorehistory rh WHERE rh.restore_history_id = @p1`
)

// Run is the read without a cursor: one whole pass every time.
func (c backupHistoryCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	return c.RunFrom(ctx, conn, info, nil)
}

// RunFrom reads the databases, the newest sets past the set cursor and the newest restores past the restore cursor.
func (backupHistoryCollector) RunFrom(ctx context.Context, conn *sql.Conn, info Info, cursor SeqCursorFunc) ([]collect.Row, error) {
	for _, t := range []string{"backupset", "backupmediafamily", "backupmediaset"} {
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
	var newest, newestMark sql.NullInt64
	if err := conn.QueryRowContext(ctx, backupNewestSQL).Scan(&newest, &newestMark); err != nil && !errors.Is(err, sql.ErrNoRows) {
		return nil, err
	}
	from, err := cursorFrom(ctx, conn, cursor, BackupHistoryCursorSource, BackupHistoryMarkSource, backupMarkSQL)
	if err != nil {
		return nil, err
	}
	sets, err := QueryRows(ctx, conn, backupSetHistorySQL(has2022 == 1), from)
	if err != nil {
		return nil, err
	}
	rows = append(rows, sets...)

	var right int64
	if err := conn.QueryRowContext(ctx, restoreRightSQL).Scan(&right); err != nil {
		return nil, err
	}
	restoreRead := "no right"
	if right == 1 {
		restoreRead = "read"
		var rNewest, rMark sql.NullInt64
		if err := conn.QueryRowContext(ctx, restoreNewestSQL).Scan(&rNewest, &rMark); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, err
		}
		rFrom, err := cursorFrom(ctx, conn, cursor, RestoreHistoryCursorSource, RestoreHistoryMarkSource, restoreMarkSQL)
		if err != nil {
			return nil, err
		}
		restores, err := QueryRows(ctx, conn, restoreHistorySQL, rFrom)
		if err != nil {
			return nil, err
		}
		rows = append(rows, restores...)
		if cursor != nil && rNewest.Valid {
			rows = append(rows, collect.Row{"kind": "cursor", "source": RestoreHistoryCursorSource, "last_id": rNewest.Int64, "mark": rMark.Int64})
		}
	}
	rows = append(rows, collect.Row{"kind": "read", "from_set_id": from, "restore_read": restoreRead})
	if cursor != nil && newest.Valid {
		rows = append(rows, collect.Row{"kind": "cursor", "source": BackupHistoryCursorSource, "last_id": newest.Int64, "mark": newestMark.Int64})
	}
	return rows, nil
}

// cursorFrom is where a cursor read starts: a little behind the stored id while the row there still has the stored
// mark (msdb not replaced), else 0 (one whole pass). No cursor function (Run), no stored cursor, or a stored 0: 0.
func cursorFrom(ctx context.Context, conn *sql.Conn, cursor SeqCursorFunc, source, markSource, markSQL string) (int64, error) {
	if cursor == nil {
		return 0, nil
	}
	last, haveLast, err := cursor(ctx, source)
	if err != nil {
		return 0, fmt.Errorf("%s cursor: %w", source, err)
	}
	mark, haveMark, err := cursor(ctx, markSource)
	if err != nil {
		return 0, fmt.Errorf("%s cursor mark: %w", source, err)
	}
	if !haveLast || !haveMark || last <= 0 {
		return 0, nil
	}
	var now sql.NullInt64
	switch err := conn.QueryRowContext(ctx, markSQL, last).Scan(&now); {
	case errors.Is(err, sql.ErrNoRows):
		return 0, nil
	case err != nil:
		return 0, err
	}
	if !now.Valid || now.Int64 != mark {
		return 0, nil
	}
	return backupReadFrom(last), nil
}

// backupCheckDBsSQL: every database with what decides whether its recovery status is read (sys.databases reads no
// database: probe 301bP2), and whether it is a secondary replica's copy here (is_secondary 1; availability groups only
// where HADR is on); without VIEW SERVER STATE a group member's role is not read (is_secondary 2: backupGroupsRead).
func backupCheckDBsSQL(groups int) string {
	secondary := "CAST(0 AS int)"
	switch groups {
	case groupsDMV:
		secondary = `CAST(CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states rs
                                     WHERE rs.database_id = d.database_id AND rs.is_local = 1 AND rs.is_primary_replica = 0) THEN 1 ELSE 0 END AS int)`
	case groupsMember:
		secondary = "CAST(CASE WHEN d.replica_id IS NULL THEN 0 ELSE 2 END AS int)"
	}
	return `SELECT d.database_id, CAST(d.name AS nvarchar(128)) AS database_name, CAST(d.state_desc AS nvarchar(60)) AS state,
  CAST(d.recovery_model_desc AS nvarchar(60)) AS recovery_model, CAST(d.is_auto_close_on AS int) AS is_auto_close_on,
  CAST(CASE WHEN d.source_database_id IS NULL THEN 0 ELSE 1 END AS int) AS is_snapshot, CAST(d.is_in_standby AS int) AS is_standby,
  ` + secondary + ` AS is_secondary
FROM sys.databases d
ORDER BY d.database_id`
}

// backupRecoverySQL: last_log_backup_lsn of the databases named ({ids}: database_id numbers the server gave).
const backupRecoverySQL = `SELECT rs.database_id, CAST(rs.last_log_backup_lsn AS varchar(25)) AS last_log_backup_lsn
FROM sys.database_recovery_status rs WHERE rs.database_id IN ({ids})`

// backupPathSQL: the default backup path (SQL Server 2019 and later).
const backupPathSQL = `SELECT CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS nvarchar(260))`

// backupPathRegSQL: the registry's BackupDirectory (SQL Server 2017; only after 301c's gate says xp_instance_regread
// may be called): an xp failure is a message, never an error, so the return code says it (NULL: failed).
const backupPathRegSQL = `DECLARE @rc int, @bd nvarchar(260);
EXEC @rc = master.dbo.xp_instance_regread N'HKEY_LOCAL_MACHINE', N'Software\Microsoft\MSSQLServer\MSSQLServer', N'BackupDirectory', @bd OUTPUT;
SELECT @rc, @bd`

// backupExistsSQL: whether @p1 is a file or a directory the service account sees (sys.dm_os_file_exists, SQL Server
// 2017 and later; every login may call it: probe 301bP1). xp_fileexist is never called: a login that is not sysadmin
// gets 0 / 0 / 0 for a file that exists (probe 301bP1).
const backupExistsSQL = `SELECT CAST(x.file_exists AS int), CAST(x.file_is_a_directory AS int), CAST(x.parent_directory_exists AS int)
FROM sys.dm_os_file_exists(@p1) x`

// Run reads the databases, then the recovery status of those it may read, then the default backup path; the file check
// (Database#7) only where the instance opts in.
func (backupChecksCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	autoClose, files := backupCheckOptions(info)
	dbs, err := QueryRows(ctx, conn, backupCheckDBsSQL(backupGroupsRead(info)))
	if err != nil {
		return nil, err
	}
	rows, ids := backupCheckDBRows(dbs, autoClose)
	if len(ids) > 0 {
		rec, err := QueryRows(ctx, conn, strings.Replace(backupRecoverySQL, "{ids}", strings.Join(ids, ", "), 1))
		if err != nil {
			return nil, err
		}
		applyRecovery(rows, rec)
	}
	for _, r := range rows {
		delete(r, "database_id")
	}
	pool := backupFileDB(info)
	fileState := "not read: the file check is off"
	switch {
	case files && pool != nil:
		var fileRows []collect.Row
		fileRows, fileState = backupFileRows(ctx, conn, info, pool)
		rows = append(rows, fileRows...)
	case files:
		fileState = "not judged: no connection for the file check"
	}
	rows = append(rows, collect.Row{"kind": "files_read", "state": fileState})
	rows = append(rows, backupPathRow(ctx, conn, info, pool))
	return rows, nil
}

// backupGroupsRead says how a database's availability group role is read: groupsNone where HADR is off, groupsDMV
// with VIEW SERVER STATE (sys.dm_hadr_database_replica_states needs it, as indexes.go's gate), else groupsMember -
// sys.databases' replica_id only, and a group member's cell 'not judged' (its role is not readable).
func backupGroupsRead(info Info) int {
	switch {
	case !info.HADREnabled:
		return groupsNone
	case info.ViewServerState:
		return groupsDMV
	}
	return groupsMember
}

const (
	groupsNone = iota
	groupsDMV
	groupsMember
)

// backupFileDB is the file check's own pool (F3: a share that does not answer holds only its own connection, never
// the collection's): openBackupFilePool's, never RunOnce's, which Connect caps at the collection's one connection (run
// 301bp4). nil, the default, leaves the file check off; the WIRING patch sets it from Info.
var backupFileDB = func(Info) *sql.DB { return nil }

const (
	// backupRootTimeout caps one root's existence call on its own connection; backupRootsBudget all the roots of one
	// read (a dead NAS with a share per database is many roots); backupFilesBudget the read's file calls.
	backupRootTimeout = 15 * time.Second
	backupRootsBudget = 30 * time.Second
	backupFilesBudget = 60 * time.Second
	// backupFilePoolConns: a root's connection the server has not let go of (a cancel it does not answer inside an SMB
	// call) leaves room for the next root and for the files' connection.
	backupFilePoolConns = 3
)

// openBackupFilePool opens the file check's own pool on the instance's DSN, as Connect opens the collection's, with
// backupFileDialer: no idle connection is kept (each Conn is a fresh short-lived one, F3) and each connection ends at
// the deadline its caller put on the context (backupFileUntil). Its connections run no sessionSetup: they only call
// sys.dm_os_file_exists, which takes no lock. The instance's password_secret (B24e) is read first and its login and
// password set on the parsed string, as Connect's. The caller closes it.
func openBackupFilePool(ctx context.Context, in config.Instance) (*sql.DB, error) {
	dsn := in.DSN()
	if strings.TrimSpace(dsn) == "" {
		return nil, errors.New("the dsn resolved to an empty string")
	}
	sec, err := readSecret(ctx, in)
	if err != nil {
		return nil, err
	}
	dl := backupFileDialer{keepAlive: 30 * time.Second}
	var db *sql.DB
	if sec.ref == nil {
		db, err = mssqlopen.OpenDialer(withAppName(dsn), dl)
	} else {
		db, err = mssqlopen.OpenDialerCredentials(withAppName(dsn), sec.user, sec.val.Password, dl)
	}
	if err != nil {
		return nil, err
	}
	db.SetMaxIdleConns(0)
	db.SetMaxOpenConns(backupFilePoolConns)
	return db, nil
}

// backupFileUntilKey carries the hard end of a file check connection on the context its Conn is asked with (the
// driver wraps the dial's context in its own 15-second dial timeout, so the dial's deadline is not the caller's).
type backupFileUntilKey struct{}

// backupFileConn takes a fresh connection from the file check's pool that ends at until, whatever the driver or the
// server does: its socket's deadline.
func backupFileConn(ctx context.Context, pool *sql.DB, until time.Time) (*sql.Conn, error) {
	return pool.Conn(context.WithValue(ctx, backupFileUntilKey{}, until))
}

// backupFileDialer dials the file check's connections. A connection's socket deadline is the end its Conn was asked
// with (backupFileConn), and a deadline the driver sets later is held to it: a share that never answers cannot hold
// the connection past its cap, even where the server does not answer the driver's cancel.
type backupFileDialer struct{ keepAlive time.Duration }

func (d backupFileDialer) DialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	until, ok := ctx.Value(backupFileUntilKey{}).(time.Time)
	if !ok {
		until = time.Now().Add(backupRootTimeout)
	}
	c, err := (&net.Dialer{KeepAlive: d.keepAlive, Deadline: until}).DialContext(ctx, network, addr)
	if err != nil {
		return nil, err
	}
	if err := c.SetDeadline(until); err != nil {
		_ = c.Close()
		return nil, err
	}
	return &cappedConn{Conn: c, until: until}, nil
}

// cappedConn is a connection whose deadlines never go past until.
type cappedConn struct {
	net.Conn
	until time.Time
}

func (c *cappedConn) held(t time.Time) time.Time {
	if t.IsZero() || t.After(c.until) {
		return c.until
	}
	return t
}
func (c *cappedConn) SetDeadline(t time.Time) error      { return c.Conn.SetDeadline(c.held(t)) }
func (c *cappedConn) SetReadDeadline(t time.Time) error  { return c.Conn.SetReadDeadline(c.held(t)) }
func (c *cappedConn) SetWriteDeadline(t time.Time) error { return c.Conn.SetWriteDeadline(c.held(t)) }

// backupFileSetsSQL: per database and type the newest set of this server's own backups that is not copy-only and was
// kept somewhere (301's backupSinkExpr, as the sets and the history: a BACKUP LOG to NUL is not the newest log),
// every family of mirror 0 with its device type; a differential only when its base is the newest full (F6).
var backupFileSetsSQL = `WITH b AS (
  SELECT bs.backup_set_id, bs.database_name, bs.type, CAST(bs.backup_set_uuid AS varchar(36)) AS uuid,
         CAST(bs.differential_base_guid AS varchar(36)) AS base_uuid,
         ROW_NUMBER() OVER (PARTITION BY bs.database_name, bs.type ORDER BY ` + backupFinishUTCExpr + ` DESC, bs.backup_set_id DESC) AS rn
    FROM msdb.dbo.backupset bs
   OUTER APPLY (SELECT TOP (1) f.device_type, f.physical_device_name FROM msdb.dbo.backupmediafamily f
                 WHERE f.media_set_id = bs.media_set_id ORDER BY f.family_sequence_number, f.mirror) mf
   WHERE bs.type IN ('D', 'I', 'L') AND bs.is_copy_only = 0 AND bs.backup_finish_date IS NOT NULL
     AND bs.server_name IN (@@SERVERNAME, CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)))
     AND ` + backupSinkExpr + ` = 'backup'
), n AS (SELECT * FROM b WHERE b.rn = 1)
SELECT CAST(n.database_name AS nvarchar(128)) AS database_name, CASE n.type WHEN 'D' THEN 'full' WHEN 'I' THEN 'diff' ELSE 'log' END AS backup_type,
  n.uuid AS backup_set_uuid, CAST(f.family_sequence_number AS int) AS family, CAST(f.device_type AS int) AS device_type,
  CAST(f.physical_device_name AS nvarchar(260)) AS path
FROM n
JOIN msdb.dbo.backupset bs ON bs.backup_set_id = n.backup_set_id
JOIN msdb.dbo.backupmediafamily f ON f.media_set_id = bs.media_set_id AND f.mirror = 0
WHERE n.type <> 'I' OR EXISTS (SELECT 1 FROM n d WHERE d.database_name = n.database_name AND d.type = 'D' AND d.uuid = n.base_uuid)
ORDER BY n.database_name, n.type, f.family_sequence_number`

// backupFileSet is one database's newest set of a type with its families' paths.
type backupFileSet struct {
	db, typ, uuid string
	paths         []string
	disk          bool
}

// backupFileRows checks the newest sets' files (Database#7) and says how the check went: each distinct root once on
// its own short-lived connection (backupRootTimeout each, backupRootsBudget for all), then the files under the roots
// that answered on one fresh connection within backupFilesBudget (backupFileStates decides the states).
func backupFileRows(ctx context.Context, conn *sql.Conn, info Info, pool *sql.DB) ([]collect.Row, string) {
	switch {
	case info.Major < 14:
		return nil, "not read: SQL Server 2017 and later (sys.dm_os_file_exists)"
	case info.Kind == KindAzureMI || info.Kind == KindRDS || info.Kind == KindCloudSQL:
		return nil, "not read: the service keeps the backups"
	}
	fams, err := QueryRows(ctx, conn, backupFileSetsSQL)
	if err != nil {
		return nil, "not judged: the backup history could not be read"
	}
	sets := backupFileSetsOf(fams)
	roots := map[string]string{} // root -> "" answered, else why its files are not judged
	rootsEnd := time.Now().Add(backupRootsBudget)
	for _, s := range sets {
		if !s.disk {
			continue
		}
		for _, p := range s.paths {
			root := backupPathRoot(p)
			if _, seen := roots[root]; seen {
				continue
			}
			switch {
			case ctx.Err() != nil:
				roots[root] = "not judged: the read's time ran out before " + root + " was asked"
			case time.Until(rootsEnd) <= 0:
				roots[root] = fmt.Sprintf("not judged: %s not asked (the roots' %d-second budget ran out)", root, int(backupRootsBudget.Seconds()))
			case !backupRootAnswers(ctx, pool, root, rootsEnd):
				roots[root] = "not judged: " + root + " did not answer"
			default:
				roots[root] = ""
			}
		}
	}
	filesEnd := time.Now().Add(backupFilesBudget)
	bctx, cancel := context.WithDeadline(ctx, filesEnd)
	defer cancel()
	var exists backupExister
	fc, err := backupFileConn(bctx, pool, filesEnd)
	if err == nil {
		defer func() { _ = fc.Close() }()
		exists = func(p string) (int64, int64, error) {
			var ex, isDir, parent sql.NullInt64
			err := fc.QueryRowContext(bctx, backupExistsSQL, p).Scan(&ex, &isDir, &parent)
			if err != nil && bctx.Err() != nil {
				return 0, 0, errBackupBudget
			}
			if err == nil && (!ex.Valid || !parent.Valid) {
				err = errors.New("no answer") // a NULL is never read as 'folder gone'
			}
			return ex.Int64, parent.Int64, err
		}
	}
	return backupFileStates(sets, roots, exists), "read"
}

// backupExister answers sys.dm_os_file_exists for one path: file_exists and parent_directory_exists, or
// errBackupBudget once the files' budget ran out, or another error (refused). nil: no connection for the file check.
type backupExister func(path string) (exists, parent int64, err error)

var errBackupBudget = errors.New("the files' budget ran out")

// backupFileStates is the file check's states (F3, F5): an answered missing file is 'gone', its missing directory
// 'folder gone'; a root that did not answer (roots[root] != ""), a refusal or the budget's end is 'not judged'. Every
// family of a striped set whose root answered is asked, and the set takes its worst family's state and path (folder
// gone, then gone, then not judged, then present): an answered missing stripe is the finding even when another
// stripe's root did not answer. A set that is not a disk set is 'not checked: not a disk path'.
func backupFileStates(sets []*backupFileSet, roots map[string]string, exists backupExister) []collect.Row {
	rank := map[string]int{"present": 0, "not judged": 1, "gone": 2, "folder gone": 3}
	var rows []collect.Row
	for _, s := range sets {
		r := collect.Row{"kind": "file", "database_name": s.db, "backup_type": s.typ, "backup_set_uuid": s.uuid}
		if len(s.paths) > 0 {
			r["path"] = s.paths[0]
		}
		if !s.disk {
			r["state"], r["detail"] = "not judged", "not checked: not a disk path"
			rows = append(rows, r)
			continue
		}
		state, detail := "present", ""
		worst := func(st, why, p string) {
			if rank[st] > rank[state] {
				state, detail, r["path"] = st, why, p
			}
		}
		for _, p := range s.paths {
			if why := roots[backupPathRoot(p)]; why != "" {
				worst("not judged", why, p)
				continue
			}
			if exists == nil {
				worst("not judged", "not judged: no connection for the file check", p)
				continue
			}
			ex, parent, err := exists(p)
			switch {
			case errors.Is(err, errBackupBudget):
				worst("not judged", fmt.Sprintf("not judged: the read's %d-second budget ran out", int(backupFilesBudget.Seconds())), p)
			case err != nil:
				worst("not judged", "not judged: the existence check was refused", p)
			case ex == 1:
			case parent == 1:
				worst("gone", "the file is gone", p)
			default:
				worst("folder gone", "the folder "+backupDirOf(p)+" is gone", p)
			}
		}
		r["state"], r["detail"] = state, detail
		rows = append(rows, r)
	}
	return rows
}

// backupFileSetsOf groups the family rows by database and type, in their order; a set is a disk set when every family
// is a disk device (device_type 2 or 102) with a path that is not NUL.
func backupFileSetsOf(fams []collect.Row) []*backupFileSet {
	var sets []*backupFileSet
	idx := map[string]*backupFileSet{}
	for _, f := range fams {
		db, _ := f["database_name"].(string)
		typ, _ := f["backup_type"].(string)
		uuid, _ := f["backup_set_uuid"].(string)
		path, _ := f["path"].(string)
		k := db + "\x00" + typ
		s := idx[k]
		if s == nil {
			s = &backupFileSet{db: db, typ: typ, uuid: uuid, disk: true}
			idx[k] = s
			sets = append(sets, s)
		}
		s.paths = append(s.paths, path)
		if intOf(f["device_type"])%100 != 2 || strings.Contains(path, "://") || strings.EqualFold(strings.TrimSuffix(path, ":"), "NUL") {
			s.disk = false
		}
	}
	return sets
}

// backupRootAnswers: whether a root answers sys.dm_os_file_exists on its own connection within backupRootTimeout and
// before the roots' end (an answer of any value counts: a root that is not there makes its files 'folder gone').
func backupRootAnswers(ctx context.Context, pool *sql.DB, root string, rootsEnd time.Time) bool {
	until := time.Now().Add(backupRootTimeout)
	if rootsEnd.Before(until) {
		until = rootsEnd
	}
	rctx, cancel := context.WithDeadline(ctx, until)
	defer cancel()
	c, err := backupFileConn(rctx, pool, until)
	if err != nil {
		return false
	}
	defer func() { _ = c.Close() }()
	var exists, isDir, parent sql.NullInt64
	return c.QueryRowContext(rctx, backupExistsSQL, root).Scan(&exists, &isDir, &parent) == nil
}

// backupPathRoot: the part of a backup path that names where it goes, as 0140's mssql_backup_root for a disk path: a
// share '\\host\share', a drive 'X:\', a Linux path's first two directories.
func backupPathRoot(p string) string {
	switch {
	case strings.HasPrefix(p, `\\`):
		parts := strings.SplitN(p[2:], `\`, 3)
		if len(parts) >= 2 {
			return `\\` + strings.ToLower(parts[0]) + `\` + strings.ToLower(parts[1])
		}
	case len(p) >= 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/'):
		return strings.ToUpper(p[:1]) + `:\`
	case strings.HasPrefix(p, "/"):
		parts := strings.SplitN(p[1:], "/", 3)
		if len(parts) == 3 {
			return "/" + parts[0] + "/" + parts[1]
		}
		return backupDirOf(p)
	}
	return p
}

// backupDirOf: a path's directory with its separator ('/var/opt/mssql/data/' of '/var/opt/mssql/data/x.bak').
func backupDirOf(p string) string {
	if i := strings.LastIndexAny(p, `/\`); i >= 0 {
		return p[:i+1]
	}
	return p
}

// backupCheckDBRows: a 'database' row per database with its lsn_state, and the database_id numbers whose recovery
// status is read (ONLINE, not a snapshot, not a standby, not a secondary replica's copy, and AUTO_CLOSE only when the
// instance opts in).
func backupCheckDBRows(dbs []collect.Row, autoClose bool) ([]collect.Row, []string) {
	var rows []collect.Row
	var ids []string
	for _, d := range dbs {
		r := collect.Row{"kind": "database", "database_name": d["database_name"], "recovery_model": d["recovery_model"], "database_id": d["database_id"]}
		state, _ := d["state"].(string)
		switch {
		case state != "ONLINE":
			r["lsn_state"] = "not judged: the database is " + strings.ToLower(firstNonEmpty(state, "in an unknown state"))
		case intOf(d["is_snapshot"]) == 1:
			r["lsn_state"] = "not judged: a database snapshot"
		case intOf(d["is_standby"]) == 1:
			r["lsn_state"] = "not judged: a standby database (restoring logs)"
		case intOf(d["is_secondary"]) == 1:
			r["lsn_state"] = "not judged: a secondary replica"
		case intOf(d["is_secondary"]) == 2:
			r["lsn_state"] = "not judged: availability group role not readable (VIEW SERVER STATE)"
		case intOf(d["is_auto_close_on"]) == 1 && !autoClose:
			r["lsn_state"] = "not read: AUTO_CLOSE (reading would open it)"
		default:
			r["lsn_state"] = "read"
			if id := intOf(d["database_id"]); id > 0 {
				ids = append(ids, strconv.FormatInt(id, 10))
			}
		}
		rows = append(rows, r)
	}
	return rows, ids
}

// applyRecovery puts each read database's last_log_backup_lsn on its row (a database the view did not return keeps
// 'read' with no value: it reads as pseudo-simple only where its model says so - the view returns a row per database).
func applyRecovery(rows, rec []collect.Row) {
	lsn := map[int64]any{}
	for _, r := range rec {
		lsn[intOf(r["database_id"])] = r["last_log_backup_lsn"]
	}
	for _, r := range rows {
		if r["lsn_state"] != "read" {
			continue
		}
		if v, ok := lsn[intOf(r["database_id"])]; ok {
			r["last_log_backup_lsn"] = v
		} else {
			r["lsn_state"] = "not judged: no recovery status row"
		}
	}
}

// backupPathRow: the default backup path and its state. 2019 and later SERVERPROPERTY; 2017 the registry behind 301c's
// gate; 2016 and the managed platforms words of their own. A call that fails or does not answer in backupPathTimeout
// is 'not judged' with fixed words (the server's text is never stored). Where the file check is on (pool), the
// existence call runs on a connection of the file check's own pool that ends at the cap (F11 takes F3's handling);
// where it is off, on the collection's connection with the cap as a cancel only (said in docs/backups-sqlserver.md).
func backupPathRow(ctx context.Context, conn *sql.Conn, info Info, pool *sql.DB) collect.Row {
	row := collect.Row{"kind": "default_path"}
	notJudged := func(why string) collect.Row {
		row["state"], row["detail"] = "not judged", "not judged: "+why
		return row
	}
	path, why := defaultBackupPath(ctx, conn, info, func() propGate { return readPropGate(ctx, conn) })
	if why != "" {
		return notJudged(why)
	}
	row["path"] = path
	if ctx.Err() != nil {
		return notJudged("the read's time ran out before the path was asked")
	}
	until := time.Now().Add(backupPathTimeout)
	cctx, cancel := context.WithDeadline(ctx, until)
	defer cancel()
	ask := conn.QueryRowContext
	if pool != nil {
		pc, err := backupFileConn(cctx, pool, until)
		if err != nil {
			return notJudged("no connection for the existence check")
		}
		defer func() { _ = pc.Close() }()
		ask = pc.QueryRowContext
	}
	var exists, isDir, parent sql.NullInt64
	if err := ask(cctx, backupExistsSQL, path).Scan(&exists, &isDir, &parent); err != nil {
		switch {
		case ctx.Err() != nil:
			return notJudged("the read's time ran out before the path answered")
		case cctx.Err() != nil:
			return notJudged(fmt.Sprintf("the path did not answer in %d seconds", int(backupPathTimeout.Seconds())))
		}
		return notJudged("the existence check was refused")
	}
	if isDir.Valid && isDir.Int64 == 1 {
		row["state"], row["detail"] = "directory", "a directory the service account sees (writing not tried)"
	} else {
		row["state"], row["detail"] = "gone", "not a directory the service account sees"
	}
	return row
}

// defaultBackupPath reads the instance's default backup path (Instance#14): SERVERPROPERTY('InstanceDefaultBackupPath')
// from SQL Server 2019, the registry's BackupDirectory on 2017 once gate says xp_instance_regread may be called. why
// is the reason there is no path, in fixed words (the server's text is never kept); both callers put their own prefix
// before it (mssql_backup_checks 'not judged: ', the Properties row 'not read: ').
//
// A managed platform (Azure SQL Managed Instance, Amazon RDS, Cloud SQL) is never read (F11: the service keeps the
// backups, and nobody there can act on a path the service account does not see; the registry is never read there).
func defaultBackupPath(ctx context.Context, conn *sql.Conn, info Info, gate func() propGate) (path, why string) {
	switch info.Kind {
	case KindAzureMI:
		return "", "Azure SQL Managed Instance keeps its backups itself"
	case KindRDS:
		return "", "Amazon RDS for SQL Server keeps its backups itself"
	case KindCloudSQL:
		return "", "Cloud SQL for SQL Server keeps its backups itself"
	}
	if info.Major < 14 {
		return "", "SQL Server 2017 and later"
	}
	var p sql.NullString
	if info.Major >= 15 {
		if err := conn.QueryRowContext(ctx, backupPathSQL).Scan(&p); err != nil {
			return "", "the default backup path could not be read"
		}
	} else {
		if g := gate(); !g.instanceRegread {
			return "", "no right to read the registry (xp_instance_regread)"
		}
		var rc sql.NullInt64
		if err := conn.QueryRowContext(ctx, backupPathRegSQL).Scan(&rc, &p); err != nil || !rc.Valid || rc.Int64 != 0 {
			return "", "the registry's BackupDirectory could not be read"
		}
	}
	if !p.Valid || strings.TrimSpace(p.String) == "" {
		return "", "no default backup path set"
	}
	return p.String, ""
}

// intOf reads a whole number a driver returned in any of its integer shapes (0 for anything else).
func intOf(v any) int64 {
	switch n := v.(type) {
	case int64:
		return n
	case int32:
		return int64(n)
	case int:
		return int64(n)
	case int16:
		return int64(n)
	case uint8:
		return int64(n)
	case bool:
		if n {
			return 1
		}
	}
	return 0
}
