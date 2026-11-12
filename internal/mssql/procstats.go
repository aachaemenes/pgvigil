package mssql

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	mssqldb "github.com/microsoft/go-mssqldb"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// procStatsCollector is mssql_procstats: what each stored procedure did, every five minutes, from
// sys.dm_exec_procedure_stats: the executions, the CPU, the duration, the logical and physical reads, the logical
// writes and the spilled pages (total_spills, where the server has the column: SQL Server 2016 SP2 and 2017 CU3 on;
// sys.all_columns is asked, and a server without it sends NULL). The view has one row per cached plan and counts since the plan entered the cache, so the
// collector sends the counters as they are, one row per plan (its handle and cached time), and the import stores
// what the interval added, summed per procedure (0084: a plan the read before did not hold, or one whose counters
// went down, gives its whole count; nothing is ever negative). A procedure that never left the cache between two
// reads loses nothing; one compiled, run and evicted between two reads is not seen at all.
//
// The server's clock is read BEFORE the counters, so a plan cached while the read runs is in this read's rows or in
// the next one's with its whole count, never lost. The list is cut at the 5,000 plans with the most CPU; the state
// row then says capped, the run is partial, and for the read after it the import falls back on the plan's cached
// time against that read's clock (both sent as the server writes them, without a zone) to tell a plan cached since
// from one that was only past the cut. That comparison is the one place the server's local clock matters: in the
// hour the clocks go back, after a cut read, it can miss a new plan's first interval or count a cut plan whole.
//
// The names come from OBJECT_NAME and OBJECT_SCHEMA_NAME, which wait behind a schema change on the object; the
// session gives up on a lock after two seconds (error 1222), and the read then runs again without the names (stored
// with the ids; the page shows 'object <id>'). The server names a procedure of another database only for a login
// that can enter that database (CONNECT ANY DATABASE, or a user there) and see its definition (VIEW ANY
// DEFINITION): the run is partial and counts the plans left without a name. The resource database's own procedures
// (database id 32767) are left out: the server names almost none of them, to anyone.
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

// lockTimeout is the server's error for a lock the session gave up on (SET LOCK_TIMEOUT).
const lockTimeout = 1222

// procStateSQL is perfStateSQL with the server's own clock as the DMV's cached_time is written (no zone).
const procStateSQL = `SELECT 'state' AS kind,
  TODATETIMEOFFSET(SYSUTCDATETIME(), 0) AS server_utc,
  TODATETIMEOFFSET(DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), sqlserver_start_time), 0) AS server_start,
  GETDATE() AS server_local
FROM sys.dm_os_sys_info`

// procStatsSQL: one row per cached plan of a stored procedure, the most CPU first. {{schema}} and {{object}} are the
// name expressions, or NULL in the second run. The handle rides as 0x text (QueryRows).
const procStatsSQL = `SELECT TOP ({{top}}) 'proc' AS kind, ps.plan_handle AS plan_handle, ps.cached_time AS cached_time,
  CAST(ps.database_id AS int) AS database_id, CAST(ps.object_id AS bigint) AS object_id,
  CAST(DB_NAME(ps.database_id) AS nvarchar(128)) AS database_name,
  CAST({{schema}} AS nvarchar(128)) AS schema_name, CAST({{object}} AS nvarchar(128)) AS object_name,
  CAST(ps.type_desc AS nvarchar(60)) AS type_desc,
  CAST(ps.execution_count AS bigint) AS execution_count,
  CAST(ps.total_worker_time AS bigint) AS worker_us, CAST(ps.total_elapsed_time AS bigint) AS elapsed_us,
  CAST(ps.total_logical_reads AS bigint) AS logical_reads, CAST(ps.total_physical_reads AS bigint) AS physical_reads,
  CAST(ps.total_logical_writes AS bigint) AS logical_writes, {{spills}} AS spills
FROM sys.dm_exec_procedure_stats ps
WHERE ps.database_id <> 32767
ORDER BY ps.total_worker_time DESC, ps.plan_handle`

// procStatsQuery fills procStatsSQL: with the names, or without them; the spills as NULL (procStatsWithSpills puts
// the server's own column in where it has one).
func procStatsQuery(names bool) string {
	schema, object := "NULL", "NULL"
	if names {
		schema, object = "OBJECT_SCHEMA_NAME(ps.object_id, ps.database_id)", "OBJECT_NAME(ps.object_id, ps.database_id)"
	}
	return strings.NewReplacer("{{top}}", fmt.Sprint(procStatsCap+1), "{{schema}}", schema, "{{object}}", object,
		"{{spills}}", procSpillsNone).Replace(procStatsSQL)
}

// procStatsColsSQL lists the view's columns: total_spills arrived in SQL Server 2016 SP2 and 2017 CU3.
const procStatsColsSQL = `SELECT CAST(name AS nvarchar(128)) AS name FROM sys.all_columns WHERE object_id = OBJECT_ID(N'sys.dm_exec_procedure_stats')`

// procSpillsNone is the spills of a server without the column: NULL, never 0 (the page says "not read on this
// version", where a 0 would say the procedure never spilled).
const procSpillsNone = "CAST(NULL AS bigint)"

// procStatsWithSpills reads the server's own total_spills in a statement procStatsQuery wrote.
func procStatsWithSpills(q string) string {
	return strings.Replace(q, procSpillsNone+" AS spills", "CAST(ps.total_spills AS bigint) AS spills", 1)
}

// isLockTimeout says whether the server refused a statement because a lock was not granted in time.
func isLockTimeout(err error) bool {
	var me mssqldb.Error
	return errors.As(err, &me) && me.Number == lockTimeout
}

// unnamed counts the rows the server gave no object name for.
func unnamed(procs []collect.Row) int {
	n := 0
	for _, p := range procs {
		if p["object_name"] == nil {
			n++
		}
	}
	return n
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
	have, err := columnSet(ctx, conn, procStatsColsSQL)
	if err != nil {
		return nil, err
	}
	query := func(names bool) string {
		if have["total_spills"] {
			return procStatsWithSpills(procStatsQuery(names))
		}
		return procStatsQuery(names)
	}
	var notes []collect.Row
	named := true
	procs, err := QueryRows(ctx, conn, query(true))
	if err != nil {
		// only a lock the name functions waited for: any other failure is the read's own
		if !isLockTimeout(err) {
			return nil, err
		}
		nameErr := err
		named = false
		if procs, err = QueryRows(ctx, conn, query(false)); err != nil {
			return nil, err
		}
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "OBJECT_NAME",
			"message": "the procedures' names were not read this time (a schema change held a lock: " + nameErr.Error() + "): the counters are stored with the object ids"})
	}
	capped := len(procs) > procStatsCap
	if capped {
		procs = procs[:procStatsCap]
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_exec_procedure_stats",
			"message": fmt.Sprintf("the plan cache holds more than %d procedure plans: the %d with the most CPU are stored", procStatsCap, procStatsCap)})
	}
	for _, s := range out {
		s["capped"] = capped
	}
	if n := unnamed(procs); named && n > 0 {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "OBJECT_NAME",
			"message": fmt.Sprintf("%d of %d procedure plans are stored without a name: the login cannot enter their database (CONNECT ANY DATABASE, or a user there), lacks VIEW ANY DEFINITION, or the procedure is gone", n, len(procs))})
	}
	out = append(out, procs...)
	return append(out, notes...), nil
}
