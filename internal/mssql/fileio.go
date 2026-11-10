package mssql

import (
	"context"
	"database/sql"
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
  CAST(vfs.num_of_writes AS bigint) AS writes, CAST(vfs.num_of_bytes_written AS bigint) AS write_bytes, CAST(vfs.io_stall_write_ms AS bigint) AS write_stall_ms
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
	state = append(state, files...)
	out := state
	if !info.ViewAnyDefinition {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.master_files",
			"message": "the login lacks VIEW ANY DEFINITION: the files of other databases are stored without their names, types and paths"})
	}
	return out, nil
}
