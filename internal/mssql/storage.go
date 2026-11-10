package mssql

import (
	"context"
	"database/sql"
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
// %s is the volume part: volumeApply with VIEW SERVER STATE, volumeNone without.
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
	cols, apply := volumeCols, volumeApply
	if !info.ViewServerState {
		cols, apply = volumeColsNone, ""
	}
	raw, err := QueryRows(ctx, conn, fmt.Sprintf(filesSQL, cols, apply))
	if err != nil {
		return nil, err
	}
	files, vols := storageRows(raw)
	var failed []string
	for _, db := range enterable(raw) {
		used, err := QueryRows(ctx, conn, fmt.Sprintf(usedSQL, db.quoted))
		if err != nil {
			if ctx.Err() != nil {
				return nil, err // the run's deadline: nothing after it would be read either
			}
			noteUnread(files, db.id, "the read of the database failed: "+err.Error())
			failed = append(failed, db.name)
			continue
		}
		applyUsed(files, db.id, used)
	}
	out := make([]collect.Row, 0, len(files)+len(vols)+2)
	out = append(out, files...)
	out = append(out, vols...)
	if !info.ViewServerState {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.dm_os_volume_stats",
			"message": "the login lacks VIEW SERVER STATE: the volumes' total and free space were not read"})
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
