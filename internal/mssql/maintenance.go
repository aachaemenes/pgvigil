package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// mssql_maintenance (task 410, B17 with B24b): Ola Hallengren's maintenance solution - where it is installed, its
// objects and their version - its CommandLog read forward from a cursor per database, and each database's data purity
// flag. One walk over the databases the login can enter:
//   - the solution is looked for in every such database (sys.objects, schema dbo: CommandExecute, DatabaseBackup,
//     DatabaseIntegrityCheck, IndexOptimize, CommandLog). A login without VIEW DEFINITION there sees none of the
//     procedures (sys.objects shows it nothing it has no right on): that database is 'not read', never 'not installed';
//   - dbo.CommandLog, where the login may SELECT it and CommandExecute is there too, forward from one past the highest
//     ID read until its end (at most maintCommandLogMax rows a run; how far behind is stored), and the rows still open
//     at the last read again (from the lowest of them: those still open or closed since), its times converted from the
//     server's local time to UTC at the read;
//   - DBCC DBINFO WITH TABLERESULTS (dbi_createVersion, dbi_dbccFlags), once a day per database: data purity checks
//     are off only for a database made before SQL Server 2005 whose flags are 0 (dbatools' Get-DbaLastGoodCheckDb
//     rule); a refusal is that database's 'not read' with the error.
//
// A secondary replica of an availability group is not read (the primary is: the flags are its boot page).
//
// The jobs are not read again: 0161 judges them from what mssql_jobs stores (each step's command, masked).
type maintenanceCollector struct{}

func init() { Register(maintenanceCollector{}) }

func (maintenanceCollector) Name() string                   { return Prefix + "maintenance" }
func (maintenanceCollector) DefaultInterval() time.Duration { return time.Hour }

// Timeout: a few short reads per database.
func (maintenanceCollector) Timeout() time.Duration { return 5 * time.Minute }

func (maintenanceCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not on Azure SQL Database: it has no SQL Server Agent to run the solution's jobs"
	}
	return true, ""
}

// maintCommandLogMax is the most CommandLog rows read from one database in one run: the read goes on batch by batch
// until it reaches the table's end, this many rows or the run's deadline; how far it stayed behind is stored.
const maintCommandLogMax = 50000

// maintCommandLogBatch is the rows of one emitted batch (each batch carries its cursor).
const maintCommandLogBatch = 1000

// maintOpenDays is how long a CommandLog row without an EndTime is read again before it is 'never closed'.
const maintOpenDays = 7

// maintCommandMax is the characters of a command kept, cut after it is masked (a key appended last stays masked).
const maintCommandMax = 4000

// maintPurityEvery is how often a database's data purity flag is read: it changes only after a CHECKDB WITH
// DATA_PURITY, and each DBCC DBINFO is an Audit DBCC event in the default trace.
const maintPurityEvery = 24 * time.Hour

// maintDatabasesSQL: every database but tempdb and the snapshots, whether the login can enter it, its quoted name,
// and whether it is a secondary replica here (%s: indexes.go's userDBLocalSecondary where Always On is enabled, else 0).
const maintDatabasesSQL = `SELECT CAST(d.name AS nvarchar(128)) AS database_name, CAST(d.state_desc AS nvarchar(60)) AS state,
  CAST(CASE WHEN d.state = 0 AND HAS_DBACCESS(d.name) = 1 THEN 1 ELSE 0 END AS int) AS can_enter, QUOTENAME(d.name) AS quoted_name,
  CAST(%s AS int) AS local_secondary
FROM sys.databases d
WHERE d.name <> N'tempdb' AND d.source_database_id IS NULL
ORDER BY d.name`

// maintObjectsSQL runs inside one database (%s: its QUOTENAME): the login's rights there, which of the solution's
// objects it sees in schema dbo, and each procedure's '--// Version:' line. FOR XML PATH keeps it on SQL Server 2016.
const maintObjectsSQL = `EXEC %s.sys.sp_executesql N'SELECT
  CAST(ISNULL(HAS_PERMS_BY_NAME(DB_NAME(), ''DATABASE'', ''VIEW DEFINITION''), 0) AS int) AS view_definition,
  CAST(ISNULL(HAS_PERMS_BY_NAME(''dbo.CommandLog'', ''OBJECT'', ''SELECT''), 0) AS int) AS commandlog_select,
  CAST(STUFF((SELECT N'','' + o.name FROM sys.objects o
               WHERE o.schema_id = SCHEMA_ID(N''dbo'') AND o.name IN (N''CommandExecute'', N''DatabaseBackup'', N''DatabaseIntegrityCheck'', N''IndexOptimize'', N''CommandLog'')
               ORDER BY o.name FOR XML PATH(N'''')), 1, 1, N'''') AS nvarchar(400)) AS objects,
  CAST(STUFF((SELECT N'','' + o.name + N''='' + SUBSTRING(m.definition, CHARINDEX(N''--// Version: '', m.definition) + 14, 19)
               FROM sys.objects o JOIN sys.sql_modules m ON m.object_id = o.object_id
               WHERE o.schema_id = SCHEMA_ID(N''dbo'') AND o.name IN (N''CommandExecute'', N''DatabaseBackup'', N''DatabaseIntegrityCheck'', N''IndexOptimize'')
                 AND CHARINDEX(N''--// Version: '', m.definition) > 0
               ORDER BY o.name FOR XML PATH(N'''')), 1, 1, N'''') AS nvarchar(400)) AS versions'`

// maintCommandLogMaxSQL: the CommandLog's highest ID (a cursor past it means the table was emptied or truncated) and
// the server's own clock now (the next read re-reads the open rows that closed since: EndTime is on that clock).
const maintCommandLogMaxSQL = `EXEC %s.sys.sp_executesql N'SELECT CAST(ISNULL(MAX(ID), 0) AS bigint) AS max_id, CONVERT(varchar(27), SYSDATETIME(), 126) AS server_now FROM dbo.CommandLog'`

// maintCommandLogCols: a CommandLog row as read. StartTime and EndTime are the server's local time: converted to UTC
// at the read by the offset in force now (a row read again after a daylight saving step moves by its hour). The
// command is read whole - the collector masks it, then cuts it (maintCommandMax) - and the backup's kind is told on
// the server from the whole command (a differential's ', DIFFERENTIAL' comes after every file of a striped backup):
// Ola Hallengren's native, LiteSpeed (xp_backup_database / xp_backup_log), Red Gate (sqlbackup with its -SQL "BACKUP
// ..."; its RESTORE VERIFYONLY is no backup), SQL Safe (@backuptype) and Data Domain Boost (-l full | diff | incr).
const maintCommandLogCols = `CAST(c.ID AS bigint) AS id, CAST(c.DatabaseName AS nvarchar(128)) AS db,
  CAST(c.SchemaName AS nvarchar(128)) AS schema_name, CAST(c.ObjectName AS nvarchar(128)) AS object_name, CAST(c.ObjectType AS nvarchar(8)) AS object_type,
  CAST(c.IndexName AS nvarchar(128)) AS index_name, CAST(c.StatisticsName AS nvarchar(128)) AS statistics_name, CAST(c.PartitionNumber AS int) AS partition_number,
  CAST(c.CommandType AS nvarchar(60)) AS command_type,
  CAST(CASE
    WHEN c.CommandType IN (N''BACKUP_LOG'', N''xp_backup_log'') THEN ''log''
    WHEN c.CommandType IN (N''BACKUP_DATABASE'', N''xp_backup_database'') THEN CASE WHEN c.Command LIKE N''%%, DIFFERENTIAL%%'' THEN ''diff'' ELSE ''full'' END
    WHEN c.CommandType = N''sqlbackup'' AND c.Command LIKE N''%%-SQL "BACKUP LOG%%'' THEN ''log''
    WHEN c.CommandType = N''sqlbackup'' AND c.Command LIKE N''%%-SQL "BACKUP DATABASE%%'' THEN CASE WHEN c.Command LIKE N''%%, DIFFERENTIAL%%'' THEN ''diff'' ELSE ''full'' END
    WHEN c.CommandType = N''xp_ss_backup'' THEN CASE WHEN c.Command LIKE N''%%@backuptype = ''''Differential''''%%'' THEN ''diff'' WHEN c.Command LIKE N''%%@backuptype = ''''Log''''%%'' THEN ''log'' ELSE ''full'' END
    WHEN c.CommandType = N''emc_run_backup'' THEN CASE WHEN c.Command LIKE N''%% -l diff%%'' THEN ''diff'' WHEN c.Command LIKE N''%% -l incr%%'' THEN ''log'' WHEN c.Command LIKE N''%% -l full%%'' THEN ''full'' END
  END AS varchar(4)) AS backup_kind,
  CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), c.StartTime), 126) + ''Z'' AS start_utc,
  CONVERT(varchar(33), DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), c.EndTime), 126) + ''Z'' AS end_utc,
  CAST(DATEDIFF(day, c.StartTime, SYSDATETIME()) AS int) AS age_days,
  CAST(c.ErrorNumber AS int) AS error_number, CAST(LEFT(c.ErrorMessage, 2000) AS nvarchar(2000)) AS error_message,
  CAST(c.Command AS nvarchar(max)) AS command
FROM dbo.CommandLog c`

// The three reads of a CommandLog (%s: the database's QUOTENAME), each one statement with its own plan (CommandLog's
// only index is its primary key on ID): forward from the cursor (@from, an ID seek); the first read of a database
// with no cursor yet (its last maintOpenDays days); and the open rows again - from the lowest row still running at the
// last read (@open) up to where that read ended (@to), the rows still open or closed since that read began (@since,
// the server's clock).
var (
	maintCommandLogFromSQL = `EXEC %s.sys.sp_executesql N'SELECT TOP (@n) ` + maintCommandLogCols + `
WHERE c.ID >= @from
ORDER BY c.ID', N'@n int, @from bigint', @n = @p1, @from = @p2`
	maintCommandLogFirstSQL = `EXEC %s.sys.sp_executesql N'SELECT TOP (@n) ` + maintCommandLogCols + `
WHERE c.StartTime >= DATEADD(day, -@days, SYSDATETIME())
ORDER BY c.ID', N'@n int, @days int', @n = @p1, @days = @p2`
	maintCommandLogOpenSQL = `EXEC %s.sys.sp_executesql N'SELECT TOP (@n) ` + maintCommandLogCols + `
WHERE c.ID >= @open AND c.ID < @to AND (c.EndTime IS NULL OR c.EndTime >= CAST(@since AS datetime2(7)))
ORDER BY c.ID', N'@n int, @open bigint, @to bigint, @since varchar(27)', @n = @p1, @open = @p2, @to = @p3, @since = @p4`
)

// maintDBInfoSQL runs DBCC DBINFO inside one database (%s: its QUOTENAME), as the login's own user there - from
// master the login is guest, which SQL Server 2017 and 2019 refuse (error 2571); the two fields the purity rule reads.
// The #table is the collection's own and is dropped in the same batch.
const maintDBInfoSQL = `IF OBJECT_ID(N'tempdb..#pgv_mt_dbinfo') IS NOT NULL DROP TABLE #pgv_mt_dbinfo;
CREATE TABLE #pgv_mt_dbinfo (ParentObject nvarchar(255), Object nvarchar(255), Field nvarchar(255), VALUE nvarchar(255));
INSERT #pgv_mt_dbinfo EXEC %s.sys.sp_executesql N'DBCC DBINFO WITH TABLERESULTS, NO_INFOMSGS';
SELECT CAST(MAX(CASE WHEN Field = N'dbi_createVersion' THEN VALUE END) AS int) AS create_version,
       CAST(MAX(CASE WHEN Field = N'dbi_dbccFlags' THEN VALUE END) AS int) AS dbcc_flags
  FROM #pgv_mt_dbinfo;
DROP TABLE #pgv_mt_dbinfo;`

// purityOn is dbatools' rule: data purity checks are off only for a database made before SQL Server 2005
// (createVersion under 611) whose DBCC flags are 0; a database made on 2005 or later checks data purity always.
func purityOn(createVersion, dbccFlags int64) bool { return createVersion >= 611 || dbccFlags != 0 }

// commandLogStatus names a CommandLog row: running (no EndTime, started within maintOpenDays), never closed (no
// EndTime, older), failed (an error number), ok.
func commandLogStatus(endUTC any, ageDays, errorNumber int64) string {
	switch {
	case endUTC == nil && ageDays < maintOpenDays:
		return "running"
	case endUTC == nil:
		return "never closed"
	case errorNumber != 0:
		return "failed"
	}
	return "ok"
}

// commandLogCursors moves a database's two cursors past one batch of rows: hw, one past the highest ID read (where
// the next forward read starts); open, the lowest ID still running (0 = none), from which the next run re-reads the
// open rows up to hw. A row never closed holds neither.
func commandLogCursors(rows []collect.Row, hw, open int64) (int64, int64) {
	for _, r := range rows {
		id, _ := asInt64(r["id"])
		if r["status"] == "running" && (open == 0 || id < open) {
			open = id
		}
		if id+1 > hw {
			hw = id + 1
		}
	}
	return hw, open
}

// commandLogPrepare names each row's status and masks its command, then cuts it.
func commandLogPrepare(rows []collect.Row, database string) {
	for _, r := range rows {
		age, _ := asInt64(r["age_days"])
		en, _ := asInt64(r["error_number"])
		r["kind"], r["database_name"], r["status"] = "commandlog", database, commandLogStatus(r["end_utc"], age, en)
		if c, ok := r["command"].(string); ok {
			r["command"] = cutRunes(collect.MaskJobText(c), maintCommandMax)
		}
		delete(r, "age_days")
	}
}

// serverClockLayout is how the server's own clock travels in an open cursor's LastEventAt: its wall time held as if
// UTC (compared only with EndTime, on the same clock), never converted.
const serverClockLayout = "2006-01-02T15:04:05.9999999"

func maintPart(part string, read bool, note string) collect.Row {
	return collect.Row{"kind": "part", "part": part, "read": b2i(read), "note": nilIfEmpty(note)}
}

func (maintenanceCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, fmt.Errorf("mssql_maintenance runs with its cursors (RunBatches)")
}

// maintCursorSource is the mssql_cursor source of one database's CommandLog read forward (one past its highest ID
// read); maintOpenSource holds the lowest row still running and the server's clock at the read that saw it; and
// maintPuritySource when the database's purity flag was last read.
func maintCursorSource(database string) string { return Prefix + "maintenance:" + database }
func maintOpenSource(database string) string   { return Prefix + "maintenance_open:" + database }
func maintPuritySource(database string) string { return Prefix + "maintenance_purity:" + database }

func (maintenanceCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, _ BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	local := "0"
	if info.HADREnabled {
		local = userDBLocalSecondary
	}
	dbs, err := QueryRows(ctx, conn, fmt.Sprintf(maintDatabasesSQL, local))
	if err != nil {
		return err
	}
	stop, hasStop := ctx.Deadline()
	var head, logs []collect.Row
	type logDB struct{ name, quoted string }
	var withLog []logDB
	noDef, cut := 0, 0
	for _, db := range dbs {
		name, _ := db["database_name"].(string)
		if platformOwnDatabase(info.Kind, name) {
			continue
		}
		quoted, _ := db["quoted_name"].(string)
		row := collect.Row{"kind": "database", "database_name": name, "install_read": 0, "note": nil, "objects": []string{},
			"versions": map[string]string{}, "purity_read": 0, "purity_note": nil, "create_version": nil, "dbcc_flags": nil}
		if db["can_enter"] != int64(1) || quoted == "" || db["local_secondary"] == int64(1) {
			why := "not read: no access (the login cannot enter the database)"
			if st, _ := db["state"].(string); st != "ONLINE" {
				why = "not read: the database is " + strings.ToLower(st)
			} else if db["local_secondary"] == int64(1) {
				why = "not read: a secondary replica (read on the primary)"
			}
			row["note"], row["purity_note"] = why, why
			head = append(head, row)
			continue
		}
		if cut > 0 || (hasStop && time.Until(stop) < 15*time.Second) {
			cut++
			row["note"] = "not read: the run's deadline came before this database's turn"
			row["purity_note"] = row["note"]
			head = append(head, row)
			continue
		}
		objs, oerr := QueryRows(ctx, conn, fmt.Sprintf(maintObjectsSQL, quoted))
		switch {
		case oerr != nil:
			row["note"] = "not read: " + oerr.Error()
		case len(objs) == 1:
			o := objs[0]
			list, _ := o["objects"].(string)
			found := splitList(list)
			row["objects"] = found
			vs := map[string]string{}
			for _, kv := range splitList(stringOf(o["versions"])) {
				if k, v, ok := strings.Cut(kv, "="); ok {
					vs[k] = strings.TrimSpace(v)
				}
			}
			row["versions"] = vs
			if o["view_definition"] == int64(1) {
				row["install_read"] = 1
			} else {
				noDef++
				row["note"] = "not read: VIEW DEFINITION (the login sees none of a database's procedures without it)"
			}
			// the solution's CommandLog only: CommandExecute writes to the CommandLog of its own database, and an
			// application's own dbo.CommandLog (other columns) is no history of the solution
			switch {
			case !contains(found, "CommandLog") || !contains(found, "CommandExecute"):
			case o["commandlog_select"] == int64(1):
				withLog = append(withLog, logDB{name, quoted})
			default:
				row["commandlog_note"] = "not read: SELECT on dbo.CommandLog"
			}
		}
		// data purity (B24b): DBCC DBINFO once a day per database, its refusal this database's 'not read'; between
		// two reads the row says the flags are kept and the import keeps the day's
		pc, pcerr := cursor(ctx, maintPuritySource(name))
		if pcerr != nil {
			return pcerr
		}
		if pc.Found && !pc.LastEventAt.IsZero() && time.Since(pc.LastEventAt) < maintPurityEvery {
			row["purity_kept"] = 1
			row["purity_note"] = "not read: the flags are read once a day (none kept for this database yet)"
			head = append(head, row)
			continue
		}
		pr, perr := QueryRows(ctx, conn, fmt.Sprintf(maintDBInfoSQL, quoted))
		switch {
		case perr != nil:
			row["purity_note"] = "not read: " + perr.Error()
		case len(pr) == 1 && pr[0]["create_version"] != nil:
			cv, _ := asInt64(pr[0]["create_version"])
			fl, _ := asInt64(pr[0]["dbcc_flags"])
			row["purity_read"], row["create_version"], row["dbcc_flags"] = 1, cv, fl
			row["purity_on"] = b2i(purityOn(cv, fl))
		default:
			row["purity_note"] = "not read: DBCC DBINFO gave no dbi_createVersion"
		}
		head = append(head, row, Cursor{LastEventAt: time.Now()}.Row(maintPuritySource(name)))
	}
	note := ""
	if noDef > 0 {
		note = fmt.Sprintf("%d database(s) were not looked into: the login lacks VIEW DEFINITION there", noDef)
	}
	if cut > 0 {
		note = strings.TrimPrefix(note+fmt.Sprintf("; the run's deadline came before %d database(s)", cut), "; ")
	}
	head = append([]collect.Row{maintPart("install", true, note)}, head...)
	if err := emit(head); err != nil {
		return err
	}
	// a batch with the rows waiting to go (a reset, a read error) first
	send := func(rows ...collect.Row) error {
		batch := make([]collect.Row, 0, len(logs)+len(rows))
		batch = append(append(batch, logs...), rows...)
		logs = nil
		return emit(batch)
	}
	for _, d := range withLog {
		if hasStop && time.Until(stop) < batchMargin {
			break
		}
		fw, cerr := cursor(ctx, maintCursorSource(d.name))
		if cerr != nil {
			return cerr
		}
		op, cerr := cursor(ctx, maintOpenSource(d.name))
		if cerr != nil {
			return cerr
		}
		mx, merr := QueryRows(ctx, conn, fmt.Sprintf(maintCommandLogMaxSQL, d.quoted))
		if merr != nil || len(mx) != 1 {
			logs = append(logs, collect.Row{"kind": "collector_error", "source": "dbo.CommandLog in " + d.name, "message": errText(merr, "no MAX(ID) row")})
			continue
		}
		maxID, _ := asInt64(mx[0]["max_id"])
		serverNow, _ := mx[0]["server_now"].(string)
		from, open := fw.LastSeq, op.LastSeq
		if from > 0 && maxID+1 < from {
			// emptied or truncated: start again from its start (the last maintOpenDays days)
			from, open = 0, 0
			logs = append(logs, collect.Row{"kind": "reset", "database_name": d.name})
		}
		hw, newOpen, failed := from, int64(0), false
		// the rows open at the last read, again: still open, or closed since that read began
		if open > 0 && from > 0 {
			since := ""
			if !op.LastEventAt.IsZero() {
				// a millisecond back: the repository keeps microseconds, the server's clock 100 ns
				since = op.LastEventAt.Add(-time.Millisecond).UTC().Format(serverClockLayout)
			} else {
				since = "1900-01-01T00:00:00"
			}
			rows, qerr := QueryRows(ctx, conn, fmt.Sprintf(maintCommandLogOpenSQL, d.quoted), int64(maintCommandLogMax), open, from, since)
			if qerr != nil {
				logs = append(logs, collect.Row{"kind": "collector_error", "source": "dbo.CommandLog in " + d.name, "message": qerr.Error()})
				continue
			}
			commandLogPrepare(rows, d.name)
			_, newOpen = commandLogCursors(rows, hw, 0)
			if len(rows) > 0 {
				if err := send(rows...); err != nil {
					return err
				}
			}
		}
		// forward from the cursor, batch by batch, each batch with the forward cursor, until the table's end, the
		// run's cap or its deadline
		read := 0
		for read < maintCommandLogMax {
			n := maintCommandLogBatch
			if maintCommandLogMax-read < n {
				n = maintCommandLogMax - read
			}
			var rows []collect.Row
			var qerr error
			if hw == 0 {
				rows, qerr = QueryRows(ctx, conn, fmt.Sprintf(maintCommandLogFirstSQL, d.quoted), int64(n), int64(maintOpenDays))
			} else {
				rows, qerr = QueryRows(ctx, conn, fmt.Sprintf(maintCommandLogFromSQL, d.quoted), int64(n), hw)
			}
			if qerr != nil {
				logs = append(logs, collect.Row{"kind": "collector_error", "source": "dbo.CommandLog in " + d.name, "message": qerr.Error()})
				failed = true
				break
			}
			commandLogPrepare(rows, d.name)
			before := hw
			hw, newOpen = commandLogCursors(rows, hw, newOpen)
			if hw == 0 {
				// a first read with nothing in its window: the next read starts past the table's end
				hw = maxID + 1
			}
			if err := send(append(rows, Cursor{LastSeq: hw}.Row(maintCursorSource(d.name)))...); err != nil {
				return err
			}
			read += len(rows)
			if len(rows) < n || hw <= before || (hasStop && time.Until(stop) < batchMargin) {
				break
			}
		}
		if failed {
			continue
		}
		// the open cursor, and how far the read stayed behind the table's end as it was at the read's start
		behind := maxID + 1 - hw
		if behind < 0 {
			behind = 0
		}
		at, _ := time.Parse(serverClockLayout, serverNow)
		if err := send(collect.Row{"kind": "commandlog_read", "database_name": d.name, "behind": behind},
			Cursor{LastSeq: newOpen, LastEventAt: at}.Row(maintOpenSource(d.name))); err != nil {
			return err
		}
	}
	if len(logs) > 0 {
		return emit(logs)
	}
	return nil
}

// errText is an error's text, or the words given when there is none.
func errText(err error, none string) string {
	if err != nil {
		return err.Error()
	}
	return none
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func stringOf(v any) string {
	s, _ := v.(string)
	return s
}
