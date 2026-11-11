package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// procStatsCollector is mssql_procstats: what each stored procedure did, every five minutes, from
// sys.dm_exec_procedure_stats: the executions, the CPU, the duration, the logical and physical reads and the
// logical writes. The view counts per cached plan since the plan entered the cache, so the collector sends the
// counters as they are, summed per database, object and cached time, and the import stores what the interval added
// (0084: a plan cached since the read before, or one whose counters went down, gives its whole count; nothing is
// ever negative). A procedure that never left the cache between two reads loses nothing; one compiled, run and
// evicted between two reads is not seen at all.
//
// The server's clock is read BEFORE the counters, so 'cached since the read before' is exact: a plan missing from
// the read before whose cached time is at or after that read's clock was cached after it. The cached time and
// that clock are sent as the server writes them, without a zone (the import's header says why).
//
// The names come from OBJECT_NAME and OBJECT_SCHEMA_NAME, which wait behind a schema change on the object; the
// session gives up on a lock after two seconds, and the read then runs again without the names (stored with the
// ids; the page shows 'object <id>'). Without VIEW ANY DEFINITION the procedures of other databases have no names.
// The list is cut at the 5,000 plans with the most CPU; the run is partial when it is.
//
// Rights as mssql_cpu (perfApplies). Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed
// Instance; not on Azure SQL Database.
type procStatsCollector struct{}

func init() { Register(procStatsCollector{}) }

func (procStatsCollector) Name() string                   { return Prefix + "procstats" }
func (procStatsCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (procStatsCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not yet on Azure SQL Database (the database's own procedure statistics are a later wave)"
	}
	return perfApplies(info, "sys.dm_exec_procedure_stats")
}

// procStatsCap is the most plans one read stores.
const procStatsCap = 5000

// procStateSQL is perfStateSQL with the server's own clock as the DMV's cached_time is written (no zone).
const procStateSQL = `SELECT 'state' AS kind,
  TODATETIMEOFFSET(SYSUTCDATETIME(), 0) AS server_utc,
  TODATETIMEOFFSET(DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), sqlserver_start_time), 0) AS server_start,
  GETDATE() AS server_local
FROM sys.dm_os_sys_info`

// procStatsSQL: one row per database, object and cached time (two plans of one procedure, cached under different
// SET options, are two rows unless cached in the same instant). {{schema}} and {{object}} are the name
// expressions, or NULL in the second run. Database 32767 is the resource database: the system procedures.
const procStatsSQL = `SELECT TOP ({{top}}) 'proc' AS kind, CAST(ps.database_id AS int) AS database_id, CAST(ps.object_id AS bigint) AS object_id,
  ps.cached_time AS cached_time,
  CAST(CASE WHEN ps.database_id = 32767 THEN N'mssqlsystemresource' ELSE DB_NAME(ps.database_id) END AS nvarchar(128)) AS database_name,
  CAST({{schema}} AS nvarchar(128)) AS schema_name, CAST({{object}} AS nvarchar(128)) AS object_name,
  CAST(MAX(ps.type_desc) AS nvarchar(60)) AS type_desc,
  SUM(CAST(ps.execution_count AS bigint)) AS execution_count,
  SUM(CAST(ps.total_worker_time AS bigint)) AS worker_us, SUM(CAST(ps.total_elapsed_time AS bigint)) AS elapsed_us,
  SUM(CAST(ps.total_logical_reads AS bigint)) AS logical_reads, SUM(CAST(ps.total_physical_reads AS bigint)) AS physical_reads,
  SUM(CAST(ps.total_logical_writes AS bigint)) AS logical_writes
FROM sys.dm_exec_procedure_stats ps
GROUP BY ps.database_id, ps.object_id, ps.cached_time
ORDER BY SUM(CAST(ps.total_worker_time AS bigint)) DESC, ps.database_id, ps.object_id, ps.cached_time`

// procStatsQuery fills procStatsSQL: with the names, or without them.
func procStatsQuery(names bool) string {
	schema, object := "NULL", "NULL"
	if names {
		schema, object = "OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id)", "OBJECT_NAME(ps.object_id, ps.database_id)"
	}
	return strings.NewReplacer("{{top}}", fmt.Sprint(procStatsCap+1), "{{schema}}", schema, "{{object}}", object).Replace(procStatsSQL)
}

func (procStatsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_exec_procedure_stats"); err != nil {
		return nil, err
	}
	// the clock first: a plan cached after this read of it is in this read's rows or in the next one's, never lost
	out, err := QueryRows(ctx, conn, procStateSQL)
	if err != nil {
		return nil, err
	}
	var notes []collect.Row
	procs, err := QueryRows(ctx, conn, procStatsQuery(true))
	if err != nil {
		if ctx.Err() != nil {
			return nil, err
		}
		nameErr := err
		if procs, err = QueryRows(ctx, conn, procStatsQuery(false)); err != nil {
			return nil, err
		}
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "OBJECT_NAME",
			"message": "the procedures' names were not read this time (" + nameErr.Error() + "): the counters are stored with the object ids"})
	}
	if len(procs) > procStatsCap {
		procs = procs[:procStatsCap]
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_exec_procedure_stats",
			"message": fmt.Sprintf("the plan cache holds more than %d procedure plans: the %d with the most CPU are stored", procStatsCap, procStatsCap)})
	}
	if !info.ViewAnyDefinition {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "OBJECT_NAME",
			"message": "the login lacks VIEW ANY DEFINITION: the procedures of databases it cannot enter are stored without their names"})
	}
	out = append(out, procs...)
	return append(out, notes...), nil
}
