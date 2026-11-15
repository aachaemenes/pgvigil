package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// storageCollector is mssql_storage: every database file the server lists (sys.master_files) with the space used
// inside it, read per ONLINE database the login can enter (sys.database_files and FILEPROPERTY in that database's
// own context), and the volumes the files sit on (sys.dm_os_volume_stats). A database the login cannot enter is
// kept with its allocated size and the note 'used not read'. Nothing is written on the server: the per-database
// read is one SELECT run through that database's sys.sp_executesql, which changes no session setting.
//
// Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; not on Azure SQL Database
// (no sys.master_files there).
type storageCollector struct{}

func init() { Register(storageCollector{}) }

func (storageCollector) Name() string                   { return Prefix + "storage" }
func (storageCollector) DefaultInterval() time.Duration { return time.Hour }

// Timeout: one short read per database; a server with a few thousand databases needs more than a minute.
func (storageCollector) Timeout() time.Duration { return 5 * time.Minute }

func (storageCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not yet on Azure SQL Database (no sys.master_files; the database's own files are a later wave)"
	case !info.ViewAnyDefinition:
		return false, "the login lacks VIEW ANY DEFINITION: sys.master_files lists no other database's files"
	}
	return true, ""
}

// filesSQL lists every file with its database's state and whether the login can enter it. SQL Server 2016 SP1+.
// size, max_size and a size growth are in 8 KB pages; max_size -1 = until the volume is full, 0 = no growth.
// A database snapshot is left out: sys.master_files lists its sparse files at the source's full size.
// %s is the volume part: volumeApply where the login may read the server's state (perfStateHeld: VIEW SERVER STATE, or
// VIEW SERVER PERFORMANCE STATE on SQL Server 2022 and later), volumeNone without.
const filesSQL = `SELECT 'file' AS kind, mf.database_id, d.name AS database_name, CAST(d.state_desc AS nvarchar(60)) AS database_state,
  mf.file_id, mf.name AS file_name, CAST(mf.type_desc AS nvarchar(60)) AS type_desc, mf.physical_name,
  CAST(mf.state_desc AS nvarchar(60)) AS state_desc,
  CAST(mf.size AS bigint) * 8192 AS size_bytes,
  CASE WHEN mf.max_size = -1 THEN NULL WHEN mf.max_size = 0 THEN CAST(mf.size AS bigint) * 8192 ELSE CAST(mf.max_size AS bigint) * 8192 END AS max_size_bytes,
  CASE WHEN mf.max_size = 0 OR mf.is_percent_growth = 1 THEN CAST(0 AS bigint) ELSE CAST(mf.growth AS bigint) * 8192 END AS growth_bytes,
  CASE WHEN mf.max_size <> 0 AND mf.is_percent_growth = 1 THEN CAST(mf.growth AS int) ELSE 0 END AS growth_pct,
  CAST(CASE WHEN d.state = 0 AND HAS_DBACCESS(d.name) = 1 THEN 1 ELSE 0 END AS int) AS can_enter,
  QUOTENAME(d.name) AS quoted_name,
  %s
FROM sys.master_files mf
JOIN sys.databases d ON d.database_id = mf.database_id
%s
WHERE d.source_database_id IS NULL
ORDER BY mf.database_id, mf.file_id`

const (
	volumeCols = `vs.volume_mount_point, vs.logical_volume_name, CAST(vs.file_system_type AS nvarchar(60)) AS file_system_type,
  CAST(vs.total_bytes AS bigint) AS total_bytes, CAST(vs.available_bytes AS bigint) AS available_bytes`
	volumeApply    = `OUTER APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs`
	volumeColsNone = `CAST(NULL AS nvarchar(512)) AS volume_mount_point, CAST(NULL AS nvarchar(512)) AS logical_volume_name,
  CAST(NULL AS nvarchar(60)) AS file_system_type, CAST(NULL AS bigint) AS total_bytes, CAST(NULL AS bigint) AS available_bytes`
)

// usedSQL runs inside one database (through its sys.sp_executesql): the files' current size (tempdb's differs from
// sys.master_files, which keeps its size at startup), the pages used inside each (FILEPROPERTY reads only the
// current database's files) and the filegroup. %s is the database's name from QUOTENAME on the server.
const usedSQL = `EXEC %s.sys.sp_executesql N'SELECT df.file_id, CAST(df.size AS bigint) * 8192 AS size_bytes,
  CAST(FILEPROPERTY(df.name, ''SpaceUsed'') AS bigint) * 8192 AS used_bytes, fg.name AS filegroup
FROM sys.database_files df LEFT JOIN sys.filegroups fg ON fg.data_space_id = df.data_space_id'`

func (storageCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	perf := perfStateHeld(ctx, conn, info)
	cols, apply := volumeCols, volumeApply
	if !perf {
		cols, apply = volumeColsNone, ""
	}
	raw, err := QueryRows(ctx, conn, fmt.Sprintf(filesSQL, cols, apply))
	if err != nil {
		return nil, err
	}
	files, vols := storageRows(raw)
	var failed []string
	// the space split of each database read (task 407), where the login may read it
	var spaces []collect.Row
	cut := 0 // databases not read because the run's deadline came first
	// the per-database reads stop a little before the run's deadline: what was read by then is stored (the files
	// with their allocated sizes, the volumes) and the run is partial, instead of an hour with nothing
	stop, hasStop := ctx.Deadline()
	stmt := usedStatement(info, perf)
	for _, db := range enterable(raw) {
		if cut > 0 || ctx.Err() != nil || (hasStop && time.Until(stop) < 10*time.Second) {
			noteUnread(files, db.id, "the run's deadline came before this database's turn")
			cut++
			continue
		}
		used, err := QueryRows(ctx, conn, fmt.Sprintf(stmt, db.quoted))
		if err != nil {
			why := "the read of the database failed: " + err.Error()
			if ctx.Err() != nil {
				why = "the run's deadline came during this database's read"
				cut++
			} else {
				failed = append(failed, db.name)
			}
			noteUnread(files, db.id, why)
			continue
		}
		applyUsed(files, db.id, used)
		if sp := spaceRow(db, used); sp != nil {
			spaces = append(spaces, sp)
		}
	}
	out := make([]collect.Row, 0, len(files)+len(vols)+2)
	out = append(out, files...)
	out = append(out, vols...)
	out = append(out, spaces...)
	if !perf {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.dm_os_volume_stats",
			"message": "the login lacks VIEW SERVER STATE (VIEW SERVER PERFORMANCE STATE on SQL Server 2022 and later): the volumes' total and free space were not read"})
	}
	if cut > 0 {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.database_files",
			"message": fmt.Sprintf("the run's deadline came before the used space of %d database(s) was read: their files are stored with the allocated size", cut)})
	}
	if len(failed) > 0 {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.database_files",
			"message": fmt.Sprintf("the used space of %d database(s) was not read (%s): each file's note says why", len(failed), firstFew(failed, 5))})
	}
	return out, nil
}

type dbRef struct {
	id     int64
	name   string
	quoted string
}

// enterable lists the databases of the file rows the login can enter (ONLINE and HAS_DBACCESS), once each.
func enterable(raw []collect.Row) []dbRef {
	seen := map[int64]bool{}
	var out []dbRef
	for _, r := range raw {
		id, ok := r["database_id"].(int64)
		if !ok || seen[id] {
			continue
		}
		seen[id] = true
		q, _ := r["quoted_name"].(string)
		if n, _ := r["can_enter"].(int64); n != 1 || q == "" {
			continue
		}
		name, _ := r["database_name"].(string)
		out = append(out, dbRef{id: id, name: name, quoted: q})
	}
	return out
}

// storageRows turns the rows of filesSQL into the payload's file rows (used not read until applyUsed says
// otherwise) and its volume rows, one per volume with the count of files on it.
func storageRows(raw []collect.Row) (files, volumes []collect.Row) {
	type vol struct {
		row   collect.Row
		files int
	}
	vols := map[string]*vol{}
	var order []string
	for _, r := range raw {
		phys, _ := r["physical_name"].(string)
		mount, _ := r["volume_mount_point"].(string)
		v := volumeOf(mount, phys, r["total_bytes"] != nil)
		note := "the login cannot enter the database"
		if st, _ := r["database_state"].(string); st != "ONLINE" {
			note = "the database is " + strings.ToLower(st)
		}
		f := collect.Row{"kind": "file", "database_id": r["database_id"], "database_name": r["database_name"],
			"database_state": r["database_state"], "file_id": r["file_id"], "file_name": r["file_name"], "type_desc": r["type_desc"],
			"filegroup": nil, "physical_name": r["physical_name"], "state_desc": r["state_desc"], "size_bytes": r["size_bytes"],
			"used_bytes": nil, "used_read": 0, "used_note": "used not read: " + note, "max_size_bytes": r["max_size_bytes"],
			"growth_bytes": r["growth_bytes"], "growth_pct": r["growth_pct"], "volume": nil}
		if v != "" {
			f["volume"] = v
			x, ok := vols[v]
			if !ok {
				x = &vol{row: collect.Row{"kind": "volume", "volume": v, "logical_name": r["logical_volume_name"],
					"file_system": r["file_system_type"], "total_bytes": r["total_bytes"], "free_bytes": r["available_bytes"]}}
				vols[v] = x
				order = append(order, v)
			}
			x.files++
		}
		files = append(files, f)
	}
	sort.Strings(order)
	for _, v := range order {
		vols[v].row["files"] = vols[v].files
		volumes = append(volumes, vols[v].row)
	}
	return files, volumes
}

// volumeOf names the volume a file sits on: the mount point the server gives (C:\, a mounted folder); where it
// read the volume but names no mount point (SQL Server on Linux), the file's directory as it is. "" = the volume
// was not read (no right, or a file that is not on a volume: a URL).
func volumeOf(mount, physical string, read bool) string {
	if mount != "" {
		return mount
	}
	if !read {
		return ""
	}
	if i := strings.LastIndexAny(physical, `/\`); i >= 0 {
		return physical[:i+1]
	}
	return ""
}

// applyUsed writes one database's read into its file rows: the current size, the used bytes and the filegroup.
// A file the database lists and FILEPROPERTY gives no figure for (a FILESTREAM container) keeps 'used not read'.
func applyUsed(files []collect.Row, databaseID int64, used []collect.Row) {
	by := map[int64]collect.Row{}
	for _, u := range used {
		if id, ok := u["file_id"].(int64); ok {
			by[id] = u
		}
	}
	for _, f := range files {
		if id, _ := f["database_id"].(int64); id != databaseID {
			continue
		}
		fid, _ := f["file_id"].(int64)
		u, ok := by[fid]
		if !ok {
			f["used_note"] = "used not read: the database does not list this file"
			continue
		}
		if u["size_bytes"] != nil {
			f["size_bytes"] = u["size_bytes"]
		}
		f["filegroup"] = u["filegroup"]
		if u["used_bytes"] == nil {
			f["used_note"] = "used not read: the server gives no used space for this kind of file"
			continue
		}
		f["used_bytes"], f["used_read"], f["used_note"] = u["used_bytes"], 1, nil
	}
}

// noteUnread marks one database's files with why their used space was not read.
func noteUnread(files []collect.Row, databaseID int64, why string) {
	for _, f := range files {
		if id, _ := f["database_id"].(int64); id == databaseID {
			f["used_note"] = "used not read: " + why
		}
	}
}

func firstFew(names []string, n int) string {
	if len(names) <= n {
		return strings.Join(names, ", ")
	}
	return strings.Join(names[:n], ", ") + fmt.Sprintf(" and %d more", len(names)-n)
}

// ---- task 407 (B13 storage depth) -----------------------------------------------------------------------------------

// usedSpaceSQL is usedSQL with the database's space split on every row, in the same statement (one walk of the
// databases): sp_spaceused's arithmetic over sys.dm_db_partition_stats - reserved and used pages of every object, data
// = the heap or clustered index's in-row, LOB and row-overflow pages used. It needs VIEW DATABASE STATE and VIEW
// DEFINITION in the database (Microsoft's page of the view; on SQL Server 2022 VIEW DATABASE PERFORMANCE STATE and VIEW
// SECURITY DEFINITION): asked only of a login with VIEW SERVER STATE - or, on 2022 and later and Managed Instance,
// VIEW SERVER PERFORMANCE STATE - (which hold the database right everywhere) and VIEW ANY DEFINITION (which mssql_storage
// needs anyway). Memory-optimized tables
// keep no pages there: their memory is mssql_tables' (sys.dm_db_xtp_table_memory_stats).
const usedSpaceSQL = `EXEC %s.sys.sp_executesql N'SELECT df.file_id, CAST(df.size AS bigint) * 8192 AS size_bytes,
  CAST(FILEPROPERTY(df.name, ''SpaceUsed'') AS bigint) * 8192 AS used_bytes, fg.name AS filegroup,
  ps.reserved_kb, ps.used_kb, ps.data_kb
FROM sys.database_files df LEFT JOIN sys.filegroups fg ON fg.data_space_id = df.data_space_id
CROSS JOIN (SELECT CAST(ISNULL(SUM(p.reserved_page_count), 0) AS bigint) * 8 AS reserved_kb,
                   CAST(ISNULL(SUM(p.used_page_count), 0) AS bigint) * 8 AS used_kb,
                   CAST(ISNULL(SUM(CASE WHEN it.object_id IS NULL AND p.index_id IN (0, 1) THEN p.in_row_data_page_count + p.lob_used_page_count + p.row_overflow_used_page_count ELSE 0 END), 0) AS bigint) * 8 AS data_kb
              FROM sys.dm_db_partition_stats p
              LEFT JOIN sys.internal_tables it ON it.object_id = p.object_id AND it.internal_type IN (` + spaceInternalTypes + `)) ps'`

// usedStatement: the per-database read with the space split where the login may read it (perf: perfStateHeld), else
// as before.
func usedStatement(info Info, perf bool) string {
	if perf && info.ViewAnyDefinition {
		return usedSpaceSQL
	}
	return usedSQL
}

// perfStateHeld: VIEW SERVER STATE, or on SQL Server 2022 and later (and Managed Instance) VIEW SERVER PERFORMANCE
// STATE, asked once a run; a failed ask is no.
func perfStateHeld(ctx context.Context, conn *sql.Conn, info Info) bool {
	if info.ViewServerState {
		return true
	}
	if info.Kind != KindAzureMI && info.Major < 16 {
		return false
	}
	var ok sql.NullInt64
	err := conn.QueryRowContext(ctx, `SELECT CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, NULL, 'VIEW SERVER PERFORMANCE STATE'), 0) AS int)`).Scan(&ok)
	return err == nil && ok.Int64 == 1
}

// spaceRow: one database's space split from its rows of usedSpaceSQL (every row carries the same figures); nil when the
// read had no split (usedSQL) or no row.
func spaceRow(db dbRef, used []collect.Row) collect.Row {
	if len(used) == 0 || used[0]["reserved_kb"] == nil {
		return nil
	}
	return collect.Row{"kind": "space", "database_id": db.id, "database_name": db.name,
		"reserved_kb": used[0]["reserved_kb"], "used_kb": used[0]["used_kb"], "data_kb": used[0]["data_kb"]}
}

// depthApplies: the two collections of task 407 - not on Azure SQL Database (no sys.master_files, no host), and the
// server's state readable (VIEW SERVER STATE; VIEW SERVER PERFORMANCE STATE on SQL Server 2022 and later, asked in the
// run). Without it they are skipped with the right named; the page says 'not read' with it.
func depthApplies(info Info, what string) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not on Azure SQL Database: " + what + " are the service's there"
	}
	return perfApplies(info, what)
}

// storageDepthCollector is mssql_storage_depth (hourly): what the server can say about its storage beyond its files'
// sizes - its default data and log paths (SERVERPROPERTY InstanceDefaultDataPath / InstanceDefaultLogPath), the
// host's platform, every fixed drive with its free space (sys.dm_os_enumerate_fixed_drives, SQL Server 2017 and later:
// it gives no drive size, so a drive without database files has its free bytes only), and the data and log files in
// the instance's folders that no database lists (sys.dm_os_enumerate_filesystem over the default paths and every
// folder holding a database file, SQL Server 2017 and later: dbachecks' orphaned files). 'SMO and DMO XPs' at 0 turns
// the two functions off (KB4046638): the run says so and never switches it on. Nothing is written on the server.
type storageDepthCollector struct{}

func init() { Register(storageDepthCollector{}) }

func (storageDepthCollector) Name() string                   { return Prefix + "storage_depth" }
func (storageDepthCollector) DefaultInterval() time.Duration { return time.Hour }

// Timeout: one listing per folder holding a database file; a server with thousands of folders needs more than a minute.
func (storageDepthCollector) Timeout() time.Duration { return 5 * time.Minute }

// Applies: the paths and drives need only the read's own right; the orphan list also needs VIEW ANY DEFINITION, and
// without it says so (orphanRows is not run).
func (storageDepthCollector) Applies(info Info) (bool, string) {
	return depthApplies(info, "the default paths, fixed drives and folders")
}

// noOrphanRight is the orphan list's note for a login without VIEW ANY DEFINITION.
const noOrphanRight = "not read: the login lacks VIEW ANY DEFINITION: sys.master_files lists no other database's files, so no file can be called orphaned"

// storagePathsSQL: one row. sys.dm_os_host_info came with SQL Server 2017: a 2016 server is a Windows one. server_start
// is sqlserver_start_time on the server's own clock (only compared with itself: tempdb's paths are kept per start).
const storagePathsSQL = `SELECT 'paths' AS kind, %s AS host_platform,
  (SELECT CONVERT(varchar(23), sqlserver_start_time, 126) FROM sys.dm_os_sys_info) AS server_start,
  CAST(SERVERPROPERTY('MachineName') AS nvarchar(256)) AS machine_name,
  CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS nvarchar(512)) AS default_data_path,
  CAST(SERVERPROPERTY('InstanceDefaultLogPath') AS nvarchar(512)) AS default_log_path,
  (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = N'SMO and DMO XPs') AS smo_xps`

const fixedDrivesSQL = `SELECT 'drive' AS kind, CAST(fixed_drive_path AS nvarchar(512)) AS drive, CAST(drive_type_desc AS nvarchar(60)) AS drive_type,
  CAST(free_space_in_bytes AS bigint) AS free_bytes
FROM sys.dm_os_enumerate_fixed_drives`

// databaseFilesSQL: every file a database lists, its path as the server knows it (snapshots' sparse files too), and
// tempdb's own list. After ALTER DATABASE tempdb MODIFY FILE both name the new path at once, while the server runs on
// the old files until its restart (the proof's P8 rows). must_list: a data or log file of an ONLINE database, itself
// ONLINE - a file its folder must list (a memory-optimized or FILESTREAM container is a directory; an OFFLINE
// database's files may be gone).
const databaseFilesSQL = `SELECT CAST(mf.physical_name AS nvarchar(512)) AS physical_name, mf.database_id,
  CAST(CASE WHEN mf.type IN (0, 1) AND mf.state = 0 AND d.state = 0 THEN 1 ELSE 0 END AS int) AS must_list
FROM sys.master_files mf JOIN sys.databases d ON d.database_id = mf.database_id
UNION SELECT CAST(physical_name AS nvarchar(512)), 2, 0 FROM tempdb.sys.database_files`

// folderFilesSQL lists a folder's entries (files and directories). It lists a subfolder's too, so orphanRows keeps only
// the rows whose parent folder is the folder asked for. written_since_start: the file was written at or after the
// server's start (2 s margin), both in UTC - the start from the ticks (no clock or DST step), the write time switched
// from its offset where the function gives one, else from the server's clock at its current offset. A file tempdb runs
// on is written after the start; a file left by a move finished at a restart is not. @p1 the folder.
const folderFilesSQL = `SELECT CAST(f.full_filesystem_path AS nvarchar(512)) AS path, CAST(f.size_in_bytes AS bigint) AS size_bytes,
  CAST(f.is_directory AS int) AS is_directory,
  CAST(CASE WHEN CASE WHEN SQL_VARIANT_PROPERTY(CAST(f.last_write_time AS sql_variant), 'BaseType') = 'datetimeoffset'
                      THEN CAST(SWITCHOFFSET(CAST(f.last_write_time AS datetimeoffset), '+00:00') AS datetime2)
                      ELSE DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), CAST(f.last_write_time AS datetime2)) END
            >= DATEADD(second, -2 - CAST((i.ms_ticks - i.sqlserver_start_time_ms_ticks) / 1000 AS int), SYSUTCDATETIME())
       THEN 1 ELSE 0 END AS int) AS written_since_start
FROM sys.dm_os_enumerate_filesystem(@p1, N'*') f CROSS JOIN sys.dm_os_sys_info i`

func (storageDepthCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "the default paths, fixed drives and folders"); err != nil {
		return nil, err
	}
	plat := "(SELECT CAST(host_platform AS nvarchar(60)) FROM sys.dm_os_host_info)"
	if info.Kind != KindAzureMI && info.Major > 0 && info.Major < 14 {
		plat = "CAST(N'Windows' AS nvarchar(60))"
	}
	paths, err := QueryRows(ctx, conn, fmt.Sprintf(storagePathsSQL, plat))
	if err != nil || len(paths) == 0 {
		return nil, fmt.Errorf("the default paths: %v", err)
	}
	p := paths[0]
	out := []collect.Row{p}
	smoOff := p["smo_xps"] != nil && fmt.Sprint(p["smo_xps"]) == "0"
	off := "not read: SMO and DMO XPs is off on this server"
	old := info.Kind != KindAzureMI && info.Major > 0 && info.Major < 14
	switch {
	case old:
		out = append(out, collect.Row{"kind": "drives", "read": 0, "note": "not read: SQL Server 2017 and later list the fixed drives"},
			collect.Row{"kind": "orphans", "read": 0, "note": "not read: SQL Server 2017 and later list a folder's files"})
		return out, nil
	case smoOff:
		out = append(out, collect.Row{"kind": "drives", "read": 0, "note": off}, collect.Row{"kind": "orphans", "read": 0, "note": off})
		return out, nil
	}
	if drives, err := QueryRows(ctx, conn, fixedDrivesSQL); err != nil {
		out = append(out, collect.Row{"kind": "drives", "read": 0, "note": "not read: " + err.Error()},
			collect.Row{"kind": "collector_error", "source": "sys.dm_os_enumerate_fixed_drives", "message": err.Error()})
	} else {
		out = append(out, collect.Row{"kind": "drives", "read": 1})
		out = append(out, drives...)
	}
	if !info.ViewAnyDefinition {
		return append(out, collect.Row{"kind": "orphans", "read": 0, "note": noOrphanRight}), nil
	}
	out = append(out, orphanRows(ctx, conn, p)...)
	return out, nil
}

// orphanRows lists the data and log files (.mdf, .ndf, .ldf) of the default paths and of every folder holding a
// database file that no database lists - a folder's own files only, never its subfolders' (another instance's files may
// sit in a subfolder of this one's default path). When any folder cannot be listed (an error, the run's time ran out,
// or a folder holding a database file lists no file of its own - SQL Server on Linux lists a folder it may not read as
// empty, without an error) the list is not read this run (read 0, the stored list kept): a list missing a folder would
// clear its orphans. tempdb's files are not counted for that: a path set by MODIFY FILE does not exist until the restart.
// The read also sends the server's start and tempdb's paths: the import keeps the paths of its first read after each
// start, the files tempdb runs on, and never stores one of them as an orphan (a pending MODIFY FILE names new paths).
func orphanRows(ctx context.Context, conn *sql.Conn, paths collect.Row) []collect.Row {
	known, err := QueryRows(ctx, conn, databaseFilesSQL)
	if err != nil {
		return []collect.Row{{"kind": "orphans", "read": 0, "note": "not read: " + err.Error()},
			{"kind": "collector_error", "source": "sys.master_files", "message": err.Error()}}
	}
	listed := map[string]bool{}
	held := map[string]int{} // a folder's data and log files of ONLINE databases other than tempdb, by pathKey(folder)
	var tempdbPaths []string // tempdb's files as the server names them now (the import keeps them per server start)
	var folders []string
	seen := map[string]bool{}
	addFolder := func(dir string) {
		dir = folderOf(dir)
		if dir == "" || seen[pathKey(dir)] {
			return
		}
		seen[pathKey(dir)] = true
		folders = append(folders, dir)
	}
	for _, k := range []string{"default_data_path", "default_log_path"} {
		if d, _ := paths[k].(string); d != "" {
			addFolder(d)
		}
	}
	for _, r := range known {
		phys, _ := r["physical_name"].(string)
		if phys == "" {
			continue
		}
		listed[pathKey(phys)] = true
		if fmt.Sprint(r["database_id"]) == "2" {
			tempdbPaths = append(tempdbPaths, phys)
		}
		if i := strings.LastIndexAny(phys, `/\`); i >= 0 && !strings.Contains(phys, "://") {
			addFolder(phys[:i+1])
			if fmt.Sprint(r["database_id"]) != "2" && fmt.Sprint(r["must_list"]) == "1" {
				held[pathKey(folderOf(phys[:i+1]))]++
			}
		}
	}
	sort.Strings(folders)
	var out []collect.Row
	var unread []string
	for _, dir := range folders {
		if ctx.Err() != nil {
			unread = append(unread, dir+" (the run's time ran out)")
			continue
		}
		files, err := QueryRows(ctx, conn, folderFilesSQL, dir)
		if err != nil {
			unread = append(unread, dir+" ("+err.Error()+")")
			continue
		}
		own := 0
		var found []collect.Row
		for _, f := range files {
			path, _ := f["path"].(string)
			i := strings.LastIndexAny(path, `/\`)
			if i < 0 || pathKey(folderOf(path[:i+1])) != pathKey(dir) {
				continue // a subfolder's file
			}
			own++ // a directory is one of the folder's own entries too, never a candidate
			if fmt.Sprint(f["is_directory"]) == "1" || !isDataOrLogFile(path) || listed[pathKey(path)] || serverOwnFile(path) {
				continue
			}
			found = append(found, collect.Row{"kind": "orphan", "path": path, "size_bytes": f["size_bytes"],
				"written_since_start": f["written_since_start"]})
		}
		if own == 0 && held[pathKey(dir)] > 0 {
			unread = append(unread, fmt.Sprintf("%s (lists nothing, while %d data or log file(s) of an online database sit in it: the server may not read it)", dir, held[pathKey(dir)]))
			continue
		}
		out = append(out, found...)
	}
	if len(unread) > 0 {
		msg := fmt.Sprintf("%d of %d folder(s) could not be listed: %s", len(unread), len(folders), firstFew(unread, 3))
		return []collect.Row{{"kind": "orphans", "read": 0, "note": "not read: " + msg},
			{"kind": "collector_error", "source": "sys.dm_os_enumerate_filesystem", "message": msg}}
	}
	sort.Strings(tempdbPaths)
	return append([]collect.Row{{"kind": "orphans", "read": 1, "server_start": paths["server_start"], "tempdb_paths": tempdbPaths}}, out...)
}

// folderOf is a folder as orphanRows compares it: no trailing separator, except a root keeps its own ('/' and 'D:\';
// 'D:' alone means the drive's current folder, never its root).
func folderOf(dir string) string {
	if dir == "" {
		return ""
	}
	t := strings.TrimRight(dir, `/\`)
	switch {
	case t == "":
		return dir[:1] // '/' or '\'
	case len(t) == 2 && t[1] == ':':
		return t + `\`
	}
	return t
}

// serverOwnFiles are files SQL Server keeps in its data folder that no database lists: the templates of SQL Server
// 2022's contained availability groups (model_msdb*, model_replicatedmaster*), replication's distribution model and the
// resource database. The list is dbatools' (Find-DbaOrphanedFile.ps1 L329, dbatools 2.9.1, MIT).
var serverOwnFiles = map[string]bool{"distmdl.ldf": true, "distmdl.mdf": true, "mssqlsystemresource.ldf": true, "mssqlsystemresource.mdf": true,
	"model_msdbdata.mdf": true, "model_msdblog.ldf": true, "model_replicatedmaster.mdf": true, "model_replicatedmaster.ldf": true}

// serverOwnFile: the file's name (any case, either separator) is one of serverOwnFiles.
func serverOwnFile(path string) bool {
	if i := strings.LastIndexAny(path, `/\`); i >= 0 {
		path = path[i+1:]
	}
	return serverOwnFiles[strings.ToLower(path)]
}

// isDataOrLogFile: a file name ending in .mdf, .ndf or .ldf, in any case.
func isDataOrLogFile(path string) bool {
	l := strings.ToLower(path)
	return strings.HasSuffix(l, ".mdf") || strings.HasSuffix(l, ".ndf") || strings.HasSuffix(l, ".ldf")
}

// tablesCollector is mssql_tables (every 6 hours, on by default; off for an instance by its 'disabled' list): every
// user table of every database the login can enter - its type (heap, clustered, clustered columnstore,
// memory-optimized; a temporal or graph table marked), the compression of its heap or clustered index's partitions,
// its partitions, rows and sizes (sys.dm_db_partition_stats; a memory-optimized table's memory from
// sys.dm_db_xtp_table_memory_stats) - so the size of any table is kept over time, not only the 50 largest of the
// Reports page. tempdb and model are left out (a #table read once would be kept as gone for ever), as are snapshots,
// a database not ONLINE or not open to the login, and a local secondary replica (its primary holds the same tables).
// The repository keeps a sample only when a table's rows or size changed. The pass runs through the batch path: every
// tablesBatchRows tables (at a database's end) are one import, so a server with hundreds of thousands of tables never
// builds one payload past what a jsonb value holds; the last batch carries the list of every database the server
// lists (a database no longer listed is gone) and where the next run starts (the cursor 'mssql_tables': the first
// database this run did not reach). It stops a little before the run's deadline: the databases not reached say so, and
// the growth lists leave them out.
type tablesCollector struct{}

// tablesBatchRows is how many tables one import of mssql_tables carries at most (a database is never split).
const tablesBatchRows = 20000

// tablesCursor is the mssql_cursor source that keeps where the next mssql_tables pass starts (last_seq: its index in
// the databases' list by name).
const tablesCursor = "mssql_tables"

func init() { Register(tablesCollector{}) }

func (tablesCollector) Name() string                   { return Prefix + "tables" }
func (tablesCollector) DefaultInterval() time.Duration { return 6 * time.Hour }
func (tablesCollector) Timeout() time.Duration         { return 10 * time.Minute }
func (tablesCollector) Applies(info Info) (bool, string) {
	if ok, why := depthApplies(info, "the tables' sizes"); !ok {
		return ok, why
	}
	if !info.ViewAnyDefinition {
		return false, "the login lacks VIEW ANY DEFINITION: the catalog would list only the tables the login has a right on"
	}
	return true, ""
}

// tablesDatabasesSQL: every database and whether the pass enters it. %s = the local secondary test (Always On).
const tablesDatabasesSQL = `SELECT CAST(d.name AS nvarchar(256)) AS name, QUOTENAME(d.name) AS quoted,
  CASE WHEN d.state <> 0 THEN 'the database is ' + LOWER(CAST(d.state_desc AS nvarchar(60)))
       WHEN d.source_database_id IS NOT NULL THEN 'a database snapshot'
       WHEN HAS_DBACCESS(d.name) = 0 THEN 'the login cannot enter the database'
       WHEN %s = 1 THEN 'a local secondary replica: its primary holds the same tables' END AS skip
FROM sys.databases d
WHERE d.database_id NOT IN (2, 3)
ORDER BY d.name`

// spaceInternalTypes: the internal tables sp_spaceused counts with their parent table (XML indexes, full-text and
// selective XML index tables): sys.internal_tables.internal_type. The proof compares a table holding an XML index
// with sp_spaceused on the box.
const spaceInternalTypes = `202, 204, 207, 211, 212, 213, 214, 215, 216, 221, 222, 236`

// tablesSQL lists one database's user tables (the first %s the database, the second the graph columns of SQL Server
// 2017 and later). compression: the heap or clustered index's partitions counted by their data_compression. The sizes
// are sp_spaceused's: the table's own pages and its internal tables' (spaceInternalTypes, counted as index); one
// grouped pass over each catalog view, not a read per table.
const tablesSQL = `EXEC %s.sys.sp_executesql N'WITH ps AS (
  SELECT COALESCE(it.parent_id, p.object_id) AS object_id,
         SUM(CASE WHEN it.object_id IS NULL AND p.index_id IN (0, 1) THEN p.row_count ELSE 0 END) AS row_count,
         CAST(SUM(p.reserved_page_count) AS bigint) * 8 AS reserved_kb, CAST(SUM(p.used_page_count) AS bigint) * 8 AS used_kb,
         CAST(SUM(CASE WHEN it.object_id IS NULL AND p.index_id IN (0, 1) THEN p.in_row_data_page_count + p.lob_used_page_count + p.row_overflow_used_page_count ELSE 0 END) AS bigint) * 8 AS data_kb
    FROM sys.dm_db_partition_stats p
    LEFT JOIN sys.internal_tables it ON it.object_id = p.object_id AND it.internal_type IN (` + spaceInternalTypes + `)
   GROUP BY COALESCE(it.parent_id, p.object_id)
), pt AS (
  SELECT p.object_id, COUNT(*) AS parts, SUM(CASE WHEN p.data_compression = 0 THEN 1 ELSE 0 END) AS c_none,
         SUM(CASE WHEN p.data_compression = 1 THEN 1 ELSE 0 END) AS c_row, SUM(CASE WHEN p.data_compression = 2 THEN 1 ELSE 0 END) AS c_page,
         SUM(CASE WHEN p.data_compression = 3 THEN 1 ELSE 0 END) AS c_cs, SUM(CASE WHEN p.data_compression = 4 THEN 1 ELSE 0 END) AS c_csa
    FROM sys.partitions p WHERE p.index_id IN (0, 1) GROUP BY p.object_id
)
SELECT CAST(s.name AS nvarchar(256)) AS schema_name, CAST(t.name AS nvarchar(256)) AS table_name,
  CAST(t.object_id AS bigint) AS object_id,
  CASE WHEN t.is_memory_optimized = 1 THEN ''memory-optimized''
       WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.index_id = 1 AND i.type = 5) THEN ''clustered columnstore''
       WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.index_id = 1) THEN ''clustered'' ELSE ''heap'' END AS table_type,
  CASE t.temporal_type WHEN 1 THEN ''history table'' WHEN 2 THEN ''system-versioned'' END AS temporal,
  %s AS graph,
  pt.parts, pt.c_none, pt.c_row, pt.c_page, pt.c_cs, pt.c_csa,
  ps.row_count, ps.reserved_kb, ps.used_kb, ps.data_kb,
  CAST(x.allocated_kb AS bigint) AS xtp_allocated_kb, CAST(x.used_kb AS bigint) AS xtp_used_kb, CAST(x.table_used_kb AS bigint) AS xtp_table_used_kb
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
LEFT JOIN pt ON pt.object_id = t.object_id
LEFT JOIN ps ON ps.object_id = t.object_id
OUTER APPLY (SELECT m.memory_allocated_for_table_kb + m.memory_allocated_for_indexes_kb AS allocated_kb,
                    m.memory_used_by_table_kb + m.memory_used_by_indexes_kb AS used_kb, m.memory_used_by_table_kb AS table_used_kb
               FROM sys.dm_db_xtp_table_memory_stats m WHERE m.object_id = t.object_id AND t.is_memory_optimized = 1) x
WHERE t.is_ms_shipped = 0'`

const (
	graphCols = `CASE WHEN t.is_node = 1 THEN ''node'' WHEN t.is_edge = 1 THEN ''edge'' END`
	graphNone = `CAST(NULL AS nvarchar(10))`
)

// Run is not the collection's path: RunOnce sends a BatchCollector to RunBatches.
func (tablesCollector) Run(context.Context, *sql.Conn, Info) ([]collect.Row, error) {
	return nil, errors.New("mssql_tables runs through the batch path (RunBatches)")
}

func (tablesCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, cursor CursorFunc, emit EmitFunc) error {
	if err := perfState(ctx, conn, info, "the tables' sizes"); err != nil {
		return err
	}
	local := "0"
	if info.HADREnabled {
		local = userDBLocalSecondary
	}
	dbs, err := QueryRows(ctx, conn, fmt.Sprintf(tablesDatabasesSQL, local))
	if err != nil {
		return err
	}
	graph := graphCols
	if info.Kind != KindAzureMI && info.Major > 0 && info.Major < 14 {
		graph = graphNone
	}
	cur, err := cursor(ctx, tablesCursor)
	if err != nil {
		return err
	}
	start := tablesStart(cur, len(dbs))
	names := make([]string, 0, len(dbs))
	for _, db := range dbs {
		name, _ := db["name"].(string)
		names = append(names, name)
	}
	var batch []collect.Row
	var failed []string
	tables, reached, cut := 0, 0, 0
	for _, db := range rotateFrom(dbs, start) {
		name, _ := db["name"].(string)
		if skip, _ := db["skip"].(string); skip != "" {
			batch = append(batch, collect.Row{"kind": "dbread", "database_name": name, "read": 0, "note": skip})
			reached++
			continue
		}
		if cut > 0 || ctx.Err() != nil || (!opt.Deadline.IsZero() && time.Until(opt.Deadline) < 15*time.Second) {
			batch = append(batch, collect.Row{"kind": "dbread", "database_name": name, "read": 0, "note": "the run's deadline came before this database's turn"})
			cut++
			continue
		}
		quoted, _ := db["quoted"].(string)
		rows, err := QueryRows(ctx, conn, fmt.Sprintf(tablesSQL, quoted, graph))
		if err != nil {
			why := "the read of the database failed: " + err.Error()
			if ctx.Err() != nil {
				why, cut = "the run's deadline came during this database's read", cut+1
			} else {
				failed = append(failed, name)
				reached++
			}
			batch = append(batch, collect.Row{"kind": "dbread", "database_name": name, "read": 0, "note": why})
			continue
		}
		reached++
		for _, r := range rows {
			batch = append(batch, tableRow(name, r))
		}
		batch = append(batch, collect.Row{"kind": "dbread", "database_name": name, "read": 1})
		if tables += len(rows); tables >= tablesBatchRows {
			if err := emit(batch); err != nil {
				return err
			}
			batch, tables = nil, 0
		}
	}
	if cut > 0 {
		batch = append(batch, collect.Row{"kind": "collector_error", "source": "sys.tables",
			"message": fmt.Sprintf("the run's deadline came before %d database(s) were read: their tables stay as last read", cut)})
	}
	if len(failed) > 0 {
		batch = append(batch, collect.Row{"kind": "collector_error", "source": "sys.tables",
			"message": fmt.Sprintf("the tables of %d database(s) were not read (%s)", len(failed), firstFew(failed, 5))})
	}
	next := 0
	if len(dbs) > 0 {
		next = (start + reached) % len(dbs)
	}
	batch = append(batch, collect.Row{"kind": "dblist", "names": names}, Cursor{LastSeq: int64(next)}.Row(tablesCursor))
	return emit(batch)
}

// tableRow: one table of tablesSQL in the payload's shape. A memory-optimized table keeps no pages: its memory stands
// for its size (allocated = reserved, used = used, the table's own = data, the indexes' = index).
func tableRow(database string, r collect.Row) collect.Row {
	out := collect.Row{"kind": "table", "database_name": database, "schema_name": r["schema_name"], "table_name": r["table_name"],
		"object_id": r["object_id"], "table_type": r["table_type"], "temporal": r["temporal"], "graph": r["graph"],
		"partitions": r["parts"], "compression": compressionText(r), "row_count": r["row_count"],
		"reserved_kb": r["reserved_kb"], "used_kb": r["used_kb"], "data_kb": r["data_kb"], "index_kb": nil}
	if r["table_type"] == "memory-optimized" && r["xtp_allocated_kb"] != nil {
		out["reserved_kb"], out["used_kb"], out["data_kb"] = r["xtp_allocated_kb"], r["xtp_used_kb"], r["xtp_table_used_kb"]
	}
	if u, ok := asInt64(out["used_kb"]); ok {
		if d, ok := asInt64(out["data_kb"]); ok && u >= d {
			out["index_kb"] = u - d
		}
	}
	return out
}

// compressionText: the one compression every partition has, or 'mixed: ROW 3, PAGE 9'; empty when no partition was read.
func compressionText(r collect.Row) string {
	names := []struct{ key, name string }{{"c_none", "NONE"}, {"c_row", "ROW"}, {"c_page", "PAGE"}, {"c_cs", "COLUMNSTORE"}, {"c_csa", "COLUMNSTORE_ARCHIVE"}}
	var parts []string
	for _, n := range names {
		if c, ok := asInt64(r[n.key]); ok && c > 0 {
			parts = append(parts, fmt.Sprintf("%s %d", n.name, c))
		}
	}
	switch len(parts) {
	case 0:
		return ""
	case 1:
		return strings.Fields(parts[0])[0]
	}
	return "mixed: " + strings.Join(parts, ", ")
}

func asInt64(v any) (int64, bool) {
	switch x := v.(type) {
	case int64:
		return x, true
	case int32:
		return int64(x), true
	case int:
		return int64(x), true
	case float64:
		return int64(x), true
	}
	return 0, false
}

// tablesStart: where a pass over n databases starts - the stored cursor's index (taken modulo n: the list may have
// shrunk since), 0 on the first run.
func tablesStart(cur Cursor, n int) int {
	if !cur.Found || n <= 0 {
		return 0
	}
	return int(((cur.LastSeq % int64(n)) + int64(n)) % int64(n))
}

// rotateFrom starts the list at index k (the cursor's next start), so a pass the deadline cuts goes on from the first
// database it did not reach.
func rotateFrom(rows []collect.Row, k int) []collect.Row {
	if len(rows) < 2 || k <= 0 || k >= len(rows) {
		return rows
	}
	return append(append([]collect.Row{}, rows[k:]...), rows[:k]...)
}
