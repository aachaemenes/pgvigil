package mssql

import (
	"context"
	"database/sql"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// fileioCollector is mssql_fileio: the IO of every database file, every minute, from
// sys.dm_io_virtual_file_stats(NULL, NULL): the reads, the bytes read and the time the reads stalled, the same for
// the writes. The counters count since the server started, so the collector sends them as they are and the
// import stores each file's difference between two reads (mssql_fileio_sample): the latency of an interval is its
// stall over its operations. A file whose counters went down (a restart; a database dropped and another made under
// its id) stores no difference for that read.
//
// The file's logical name, type and path come from sys.master_files, which lists another database's files only with
// VIEW ANY DEFINITION; without it the counters are stored with the database and file ids and the name is blank.
//
// Each file also carries the resource governor's queued stall (io_stall_queued_read_ms / _write_ms: the IO a resource
// pool's limit held back; 0 where no pool limits IO) and the IOs pending on it at the read: sys.dm_io_pending_io_requests
// counted by its io_handle and matched to the file's file_handle of the same read (no second read of the file
// statistics, no path, no case, no right beyond the read's own), with how many of them the operating system still holds
// (io_pending = 1). Microsoft calls the pending time 'internal use only': it is
// not kept. A server whose pending list cannot be read stores the files without it and says why.
//
// Rights as mssql_cpu (perfApplies). Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed
// Instance; not on Azure SQL Database (the function's ids there are the elastic pool's, not the logical server's).
type fileioCollector struct{}

func init() { Register(fileioCollector{}) }

func (fileioCollector) Name() string                   { return Prefix + "fileio" }
func (fileioCollector) DefaultInterval() time.Duration { return time.Minute }
func (fileioCollector) Applies(info Info) (bool, string) {
	return perfApplies(info, "sys.dm_io_virtual_file_stats")
}

const fileioSQL = `SELECT 'file' AS kind, CAST(vfs.database_id AS int) AS database_id, DB_NAME(vfs.database_id) AS database_name,
  CAST(vfs.file_id AS int) AS file_id, mf.name AS file_name, CAST(mf.type_desc AS nvarchar(60)) AS type_desc, mf.physical_name,
  CAST(vfs.num_of_reads AS bigint) AS reads, CAST(vfs.num_of_bytes_read AS bigint) AS read_bytes, CAST(vfs.io_stall_read_ms AS bigint) AS read_stall_ms,
  CAST(vfs.num_of_writes AS bigint) AS writes, CAST(vfs.num_of_bytes_written AS bigint) AS write_bytes, CAST(vfs.io_stall_write_ms AS bigint) AS write_stall_ms,
  CAST(vfs.io_stall_queued_read_ms AS bigint) AS read_queued_ms, CAST(vfs.io_stall_queued_write_ms AS bigint) AS write_queued_ms,
  CONVERT(varchar(20), vfs.file_handle, 1) AS file_handle
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
LEFT JOIN sys.master_files mf ON mf.database_id = vfs.database_id AND mf.file_id = vfs.file_id`

func (fileioCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_io_virtual_file_stats"); err != nil {
		return nil, err
	}
	state, err := QueryRows(ctx, conn, perfStateSQL)
	if err != nil {
		return nil, err
	}
	files, err := QueryRows(ctx, conn, fileioSQL)
	if err != nil {
		return nil, err
	}
	pending, perr := QueryRows(ctx, conn, pendingIOSQL)
	if perr != nil {
		state = append(state, collect.Row{"kind": "pending", "read": 0, "note": perr.Error()},
			collect.Row{"kind": "collector_error", "source": "sys.dm_io_pending_io_requests", "message": "the IOs pending were not read: " + perr.Error()})
	} else {
		ios, inOS := applyPending(files, pending)
		// the read's totals come from the pending rows themselves: an IO on a path no file row names still counts
		state = append(state, collect.Row{"kind": "pending", "read": 1, "pending_ios": ios, "pending_in_os": inOS})
	}
	state = append(state, files...)
	out := state
	if !info.ViewAnyDefinition {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.master_files",
			"message": "the login lacks VIEW ANY DEFINITION: the files of other databases are stored without their names, types and paths"})
	}
	return out, nil
}

// pendingIOSQL: the IOs pending now, by the handle of the file they are on (io_handle, the file_handle of
// sys.dm_io_virtual_file_stats). io_pending = 1: the operating system has not completed the IO yet; 0: completed,
// waiting for SQL Server to take it.
const pendingIOSQL = `SELECT CONVERT(varchar(20), io_handle, 1) AS handle, COUNT(*) AS pending_ios,
  SUM(CASE WHEN io_pending = 1 THEN 1 ELSE 0 END) AS pending_in_os
FROM sys.dm_io_pending_io_requests
WHERE io_handle IS NOT NULL
GROUP BY io_handle`

// applyPending writes each file's pending IOs (0 when none) from the rows of pendingIOSQL, matched by the file's
// handle of the same read; the handle is not stored. It returns the totals of every pending row, matched or not.
func applyPending(files, pending []collect.Row) (ios, inOS int64) {
	by := map[string]collect.Row{}
	for _, p := range pending {
		n, _ := asInt64(p["pending_ios"])
		o, _ := asInt64(p["pending_in_os"])
		ios, inOS = ios+n, inOS+o
		if h, _ := p["handle"].(string); h != "" {
			by[strings.ToLower(h)] = p
		}
	}
	for _, f := range files {
		f["pending_ios"], f["pending_in_os"] = int64(0), int64(0)
		h, _ := f["file_handle"].(string)
		delete(f, "file_handle")
		if p, ok := by[strings.ToLower(h)]; ok && h != "" {
			f["pending_ios"], f["pending_in_os"] = p["pending_ios"], p["pending_in_os"]
		}
	}
	return ios, inOS
}

// pathKey is a file path as a map key, in lower case: Windows compares paths so, and SQL Server on Linux keeps names
// in sys.master_files in another case than the files on disk (msdb's MSDBData.mdf is msdbdata.mdf in the folder). A
// Windows path (a drive letter or a UNC start) also has its forward slashes read as backslashes, as Windows does.
func pathKey(path string) string {
	k := strings.ToLower(path)
	if (len(k) > 1 && k[1] == ':') || strings.HasPrefix(k, `\\`) {
		k = strings.ReplaceAll(k, "/", `\`)
	}
	return k
}
