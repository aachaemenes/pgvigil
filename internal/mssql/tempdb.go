package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// tempdbCollector is mssql_tempdb: how tempdb is laid out, hourly, for the check DBA Dash's TempDB page makes. Its
// files as they stand now (tempdb.sys.database_files: the current size, which sys.master_files keeps at its
// startup size, the growth step and the maximum), the volume each sits on, the logical CPU count the number of data
// files is weighed against, the trace flags 1117 and 1118 (global, from DBCC TRACESTATUS) and whether tempdb's
// metadata is memory-optimized (SERVERPROPERTY('IsTempDBMetadataMemoryOptimized'), SQL Server 2019 and later).
//
// The check is the repository's (0074, mssql_perf_findings), on Microsoft's guidance (the tempdb page of the SQL
// Server documentation): with eight logical processors or fewer, as many data files as processors; with more, eight
// to start with; the data files of one size and one growth step; trace flags 1117 and 1118 are no longer required
// from SQL Server 2016 (their behaviour is tempdb's default there), so they are weighed only before 2016.
//
// Rights: tempdb's own files and the trace flags need only the public role; the CPU count and the volumes need
// VIEW SERVER STATE (or VIEW SERVER PERFORMANCE STATE on 2022): without it the files are stored, the CPU count is
// blank, the file-count part of the check says it cannot weigh, and the run is partial. Runs on SQL Server 2016 SP1
// and later, Amazon RDS and Azure SQL Managed Instance; not on Azure SQL Database (tempdb is the service's there).
type tempdbCollector struct{}

func init() { Register(tempdbCollector{}) }

func (tempdbCollector) Name() string                   { return Prefix + "tempdb" }
func (tempdbCollector) DefaultInterval() time.Duration { return time.Hour }
func (tempdbCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not on Azure SQL Database: tempdb is the service's there, not configurable"
	}
	return true, ""
}

// tempdbFilesSQL: the files with their current size; a growth as a size or a per cent; max_size -1 = until the
// volume is full. %s is the volume part.
const tempdbFilesSQL = `SELECT 'file' AS kind, CAST(f.file_id AS int) AS file_id, f.name AS file_name, CAST(f.type_desc AS nvarchar(60)) AS type_desc,
  f.physical_name, CAST(f.size AS bigint) * 8192 AS size_bytes,
  CASE WHEN f.max_size = -1 THEN NULL WHEN f.max_size = 0 THEN CAST(f.size AS bigint) * 8192 ELSE CAST(f.max_size AS bigint) * 8192 END AS max_size_bytes,
  CASE WHEN f.is_percent_growth = 1 THEN CAST(0 AS bigint) ELSE CAST(f.growth AS bigint) * 8192 END AS growth_bytes,
  CASE WHEN f.is_percent_growth = 1 THEN CAST(f.growth AS int) ELSE 0 END AS growth_pct,
  %s
FROM tempdb.sys.database_files f
%s
ORDER BY f.file_id`

const (
	tempdbVolume     = `CAST(vs.volume_mount_point AS nvarchar(512)) AS volume_mount_point`
	tempdbVolumeJoin = `OUTER APPLY sys.dm_os_volume_stats(2, f.file_id) vs`
	tempdbVolumeNone = `CAST(NULL AS nvarchar(512)) AS volume_mount_point`
)

const tempdbServerSQL = `SELECT 'server' AS kind, CAST(SERVERPROPERTY('IsTempDBMetadataMemoryOptimized') AS int) AS memopt_metadata, %s AS cpu_count`

const tempdbFlagsSQL = `DBCC TRACESTATUS(1117, 1118) WITH NO_INFOMSGS`

func (tempdbCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	perf := perfState(ctx, conn, info, "sys.dm_os_sys_info") == nil
	vcol, vjoin, cpu := tempdbVolumeNone, "", "CAST(NULL AS int)"
	if perf {
		vcol, vjoin, cpu = tempdbVolume, tempdbVolumeJoin, "(SELECT CAST(cpu_count AS int) FROM sys.dm_os_sys_info)"
	}
	files, err := QueryRows(ctx, conn, fmt.Sprintf(tempdbFilesSQL, vcol, vjoin))
	if err != nil {
		return nil, err
	}
	for _, f := range files {
		mount, _ := f["volume_mount_point"].(string)
		phys, _ := f["physical_name"].(string)
		if v := volumeOf(mount, phys, perf); v != "" {
			f["volume"] = v
		}
		delete(f, "volume_mount_point")
	}
	server, err := QueryRows(ctx, conn, fmt.Sprintf(tempdbServerSQL, cpu))
	if err != nil {
		return nil, err
	}
	if len(server) == 1 {
		server[0]["major"] = info.Major
		// Azure SQL Managed Instance answers 12.0 as its product version and runs the current engine: the flags never apply
		server[0]["flags_required"] = b2i(info.Kind != KindAzureMI && info.Major > 0 && info.Major < 13)
		if info.Kind == KindAzureMI || info.Major < 15 {
			server[0]["memopt_metadata"] = nil // the feature is SQL Server 2019 and later, and not on Managed Instance
		}
		server[0]["tf1117"], server[0]["tf1118"] = nil, nil
		flags, ferr := QueryRows(ctx, conn, tempdbFlagsSQL)
		if ferr != nil {
			files = append(files, collect.Row{"kind": "collector_error", "source": "DBCC TRACESTATUS", "message": ferr.Error()})
		} else {
			server[0]["tf1117"], server[0]["tf1118"] = 0, 0
			for _, f := range flags {
				on := f["Global"] == int64(1) // a flag set globally; a session-only flag does not change tempdb
				switch f["TraceFlag"] {
				case int64(1117):
					server[0]["tf1117"] = b2i(on)
				case int64(1118):
					server[0]["tf1118"] = b2i(on)
				}
			}
		}
	}
	server = append(server, files...)
	out := server
	if !perf {
		out = append(out, collect.Row{"kind": "collector_error", "source": "sys.dm_os_sys_info",
			"message": "the login lacks VIEW SERVER STATE: the CPU count and the volumes were not read, so the number of data files is not weighed"})
	}
	return out, nil
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}
