package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// statsCollector is mssql_stats: the health of the optimizer's statistics in every user database, every six hours.
//
// Per database two reads, each one SELECT through the database's own sys.sp_executesql (nothing written):
//
//   - the summary over every statistic of a user table or an indexed view: how many there are, when the oldest and
//     the newest were last updated, how many were never updated, and the average share of rows modified since;
//   - the statistics worth a row of their own, the most modified first, statsCap a database at most: every statistic
//     on 10,000 rows or more, and whatever the row count every statistic created WITH NORECOMPUTE, with a filter,
//     with a persisted sample rate, or not incremental on a partitioned table. Each with its columns, when it was
//     last updated, the rows it was built on and the rows sampled, and the modifications since.
//
// The figures come from sys.dm_db_stats_properties, which answers only for a statistic whose columns the login may
// SELECT (or as db_owner, db_ddladmin or sysadmin): for any other statistic it returns no row. A monitoring login
// rarely has that right, so the read falls back per statistic on what the catalog gives every login that can see
// the table's definition: the last update from STATS_DATE, the modifications from sys.sysindexes.rowmodctr and the
// rows from sys.dm_db_partition_stats. Such a row says so (props_read false): its sample rate and persisted sample
// rate are not known, and the repository judges neither.
//
// The judgements are the repository's (0092: not updated in 30 days with 10 % of 10,000 or more rows modified, a
// low sample rate, a persisted sample rate, NORECOMPUTE, a filter, not incremental on a partitioned table).
//
// A database whose read fails keeps what the repository holds and its row says why; the system databases and
// database snapshots are not read; a run starts at another database each time (by the clock).
//
// Rights: VIEW SERVER STATE for the row counts (as mssql_cpu, perfApplies); VIEW ANY DEFINITION for the catalog of
// every database (without it sys.stats lists only objects the login has a permission on, and the run says so) and
// CONNECT ANY DATABASE (or a user in it) to enter it; SELECT on the tables (db_datareader) for the sample rates. Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance;
// persisted_sample_percent is read where the server has it (2016 SP1 CU4, 2017 CU1 and later). Not on Azure SQL
// Database.
type statsCollector struct{}

func init() { Register(statsCollector{}) }

func (statsCollector) Name() string                   { return Prefix + "stats" }
func (statsCollector) DefaultInterval() time.Duration { return 6 * time.Hour }

// Timeout: two catalog reads per database.
func (statsCollector) Timeout() time.Duration { return 5 * time.Minute }

func (statsCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not yet on Azure SQL Database (the per-database pass runs through other databases' sys.sp_executesql)"
	// VIEW SERVER STATE itself, not 2022's VIEW SERVER PERFORMANCE STATE: the sizes are a database's own DMV, which
	// needs VIEW DATABASE STATE, and only VIEW SERVER STATE gives that in every database
	case !info.ViewServerState:
		return false, "the login lacks VIEW SERVER STATE: sys.dm_db_partition_stats and the sizes of each database cannot be read"
	}
	return true, ""
}

// statsCap is the most statistics of one database a read stores (the most modified first); statsMinRows is the
// row count from which a statistic gets a row whatever its options.
const (
	statsCap     = 5000
	statsMinRows = 10000
)

// statsColsSQL: the columns this server's sys.dm_db_stats_properties returns.
const statsColsSQL = `SELECT CAST(name AS nvarchar(128)) AS name FROM sys.all_columns WHERE object_id = OBJECT_ID(N'sys.dm_db_stats_properties')`

// statsFromSQL is the FROM both reads share: every statistic of a user table or an indexed view with its
// properties where the login may read them (sp), and the catalog's own figures beside them (the fallback).
const statsFromSQL = `FROM sys.stats s
JOIN sys.objects o ON o.object_id = s.object_id
OUTER APPLY sys.dm_db_stats_properties(s.object_id, s.stats_id) sp
LEFT JOIN sys.sysindexes si ON si.id = s.object_id AND si.indid = s.stats_id
LEFT JOIN (SELECT p.object_id, SUM(p.row_count) AS row_count FROM sys.dm_db_partition_stats p WHERE p.index_id IN (0, 1) GROUP BY p.object_id) ps
       ON ps.object_id = s.object_id
CROSS APPLY (SELECT CASE WHEN sp.object_id IS NULL THEN 0 ELSE 1 END AS props_read,
                    ISNULL(sp.last_updated, STATS_DATE(s.object_id, s.stats_id)) AS last_updated,
                    ISNULL(sp.rows, ps.row_count) AS row_count,
                    ISNULL(sp.modification_counter, CASE WHEN si.rowmodctr >= 0 THEN si.rowmodctr END) AS modifications,
                    {{persisted}} AS persisted_pct,
                    CASE WHEN EXISTS (SELECT 1 FROM sys.partitions p WHERE p.object_id = s.object_id AND p.index_id IN (0, 1) AND p.partition_number > 1)
                         THEN 1 ELSE 0 END AS partitioned) x
WHERE o.is_ms_shipped = 0 AND o.type IN ('U', 'V')`

// statsSummarySQL: one row over every statistic of the database.
var statsSummarySQL = `SELECT COUNT_BIG(*) AS [statistics],   -- STATISTICS is a reserved word
  SUM(CAST(x.props_read AS bigint)) AS props_read,
  SUM(CASE WHEN x.last_updated IS NULL THEN CAST(1 AS bigint) ELSE 0 END) AS never_updated,
  ` + utcOf("MIN(x.last_updated)") + ` AS oldest_update, ` + utcOf("MAX(x.last_updated)") + ` AS newest_update,
  CAST(AVG(CASE WHEN x.row_count > 0 AND x.modifications IS NOT NULL THEN 100.0 * x.modifications / x.row_count END) AS float) AS avg_modified_pct
` + statsFromSQL

// statsRowsSQL: the statistics worth a row of their own, the most modified first.
var statsRowsSQL = `SELECT TOP (@cap) 'stat' AS kind, CAST(s.object_id AS bigint) AS object_id, CAST(s.stats_id AS int) AS stats_id,
  CAST(SCHEMA_NAME(o.schema_id) AS nvarchar(128)) AS schema_name, CAST(o.name AS nvarchar(128)) AS table_name, CAST(s.name AS nvarchar(128)) AS stats_name,
  (SELECT c.name AS n FROM sys.stats_columns sc JOIN sys.columns c ON c.object_id = sc.object_id AND c.column_id = sc.column_id
    WHERE sc.object_id = s.object_id AND sc.stats_id = s.stats_id ORDER BY sc.stats_column_id FOR JSON PATH) AS columns_json,
  CAST(s.auto_created AS int) AS auto_created, CAST(s.user_created AS int) AS user_created, CAST(s.no_recompute AS int) AS no_recompute,
  CAST(s.has_filter AS int) AS has_filter, CAST(s.filter_definition AS nvarchar(4000)) AS filter_definition,
  CAST(s.is_incremental AS int) AS is_incremental, CAST(x.partitioned AS int) AS partitioned, CAST(x.props_read AS int) AS props_read,
  ` + utcOf("x.last_updated") + ` AS last_updated, CAST(x.row_count AS bigint) AS row_count, CAST(sp.rows_sampled AS bigint) AS rows_sampled,
  CAST(x.modifications AS bigint) AS modifications, CAST(sp.steps AS int) AS steps, CAST(x.persisted_pct AS float) AS persisted_sample_pct
` + statsFromSQL + `
  AND (x.row_count >= @minrows OR s.no_recompute = 1 OR s.has_filter = 1 OR x.persisted_pct > 0 OR (x.partitioned = 1 AND s.is_incremental = 0))
ORDER BY ISNULL(x.modifications, 0) DESC, s.object_id, s.stats_id`

// statsQuery fills a statistics statement with the persisted sample rate where the server's function returns it.
func statsQuery(query string, have map[string]bool) string {
	persisted := "CAST(NULL AS float)"
	if have["persisted_sample_percent"] {
		persisted = "sp.persisted_sample_percent"
	}
	return strings.ReplaceAll(query, "{{persisted}}", persisted)
}

// statRows gives each statistic's row its column list in place of the JSON the server sent and names its
// database. A row whose list cannot be read is dropped and counted.
func statRows(db userDB, rows []collect.Row) (out []collect.Row, bad int) {
	out = make([]collect.Row, 0, len(rows))
	for _, r := range rows {
		cols, err := indexColumns(r["columns_json"])
		if err != nil {
			bad++
			continue
		}
		delete(r, "columns_json")
		r["stat_columns"] = cols
		r["database_id"], r["database_name"] = db.id, db.name
		out = append(out, r)
	}
	return out, bad
}

// Run is the read as one slice, for a caller that does not know the batch path.
func (c statsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	var out []collect.Row
	err := c.RunBatches(ctx, conn, info, BatchOptions{}, nil, func(rows []collect.Row) error {
		out = append(out, rows...)
		return nil
	})
	return out, err
}

// RunBatches reads the databases one by one, each stored as a batch of its own with the run's state row, then the
// list of the databases the server has.
func (c statsCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, _ CursorFunc, emit EmitFunc) error {
	if err := perfState(ctx, conn, info, "sys.dm_db_partition_stats"); err != nil {
		return err
	}
	state, err := QueryRows(ctx, conn, perfStateSQL)
	if err != nil {
		return err
	}
	if len(state) == 0 {
		return fmt.Errorf("sys.dm_os_sys_info returned no row")
	}
	st := state[0]
	have, err := columnSet(ctx, conn, statsColsSQL)
	if err != nil {
		return err
	}
	dbs, _, err := userDatabases(ctx, conn, info)
	if err != nil {
		return err
	}
	var failed []string
	var firstErr error
	names := make([]string, 0, len(dbs))
	closed, cut, noProps := 0, 0, 0
	for _, db := range rotate(dbs, time.Now(), c.DefaultInterval()) {
		names = append(names, db.name)
		// the statistics' own 'db' row: the index read's dates are not this collection's
		row := collect.Row{"kind": "db", "database_id": db.id, "database_name": db.name, "database_state": db.state, "read": false, "note": nil}
		batch := []collect.Row{st, row}
		switch {
		case !db.canEnter:
			row["note"] = whyNotEntered(db)
			if db.state == "ONLINE" {
				closed++
			}
		case cut > 0 || ctx.Err() != nil || (!opt.Deadline.IsZero() && time.Now().After(opt.Deadline)):
			row["note"] = "not read this time: the run's deadline came before this database's turn; the next run starts at another database"
			cut++
		default:
			sum, err := qsRead(ctx, conn, db.quoted, statsQuery(statsSummarySQL, have), "")
			var rows []collect.Row
			if err == nil {
				rows, err = qsRead(ctx, conn, db.quoted, statsQuery(statsRowsSQL, have), "@cap int, @minrows bigint",
					sql.Named("cap", statsCap+1), sql.Named("minrows", int64(statsMinRows)))
			}
			if err != nil {
				if ctx.Err() != nil {
					row["note"] = "not read this time: the run's deadline came during this database's read"
					cut++
					break
				}
				row["note"] = "the read failed: " + err.Error()
				failed = append(failed, db.name)
				if firstErr == nil {
					firstErr = err
				}
				break
			}
			if len(sum) > 0 {
				for _, k := range []string{"statistics", "props_read", "never_updated", "oldest_update", "newest_update", "avg_modified_pct"} {
					row[k] = sum[0][k]
				}
				// renamed: the 'db' row's own read flag is "read"
				row["statistics_with_props"] = row["props_read"]
				delete(row, "props_read")
				all, _ := sum[0]["statistics"].(int64)
				with, _ := sum[0]["props_read"].(int64)
				if all > with {
					noProps++
					row["note"] = fmt.Sprintf("%d of %d statistics were read without their properties (the login may not SELECT their columns): no sample rate; the dates and the modifications are the catalog's", all-with, all)
				}
			}
			capped := len(rows) > statsCap
			if capped {
				rows = rows[:statsCap]
			}
			stats, bad := statRows(db, rows)
			row["read"], row["capped"], row["listed"] = true, capped, len(stats)
			if bad > 0 {
				batch = append(batch, collect.Row{"kind": "collector_error", "source": "sys.stats_columns",
					"message": fmt.Sprintf("%s: the column list of %d statistic(s) could not be read; they are not stored", db.name, bad)})
			}
			batch = append(batch, stats...)
		}
		if err := emit(batch); err != nil {
			return err
		}
	}
	last := []collect.Row{st, {"kind": "databases", "names": names}}
	if len(failed) > 0 {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.stats",
			"message": fmt.Sprintf("%d database(s) were not read this time (%s): %v; the repository keeps what it holds of them", len(failed), firstFew(failed, 5), firstErr)})
	}
	if cut > 0 {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.stats",
			"message": fmt.Sprintf("the run's deadline came before %d database(s) were read; the next run starts at another database", cut)})
	}
	if closed > 0 && closed == len(dbs) {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.databases",
			"message": fmt.Sprintf("the login cannot enter any of the %d user database(s): GRANT CONNECT ANY DATABASE (with VIEW ANY DEFINITION) lets it read each catalog", closed)})
	}
	if !info.ViewAnyDefinition {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.stats", "message": noDefinitionNote("statistics")})
	}
	if noProps > 0 {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.dm_db_stats_properties",
			"message": fmt.Sprintf("in %d database(s) the login may not read the properties of every statistic (SELECT on the tables, db_datareader, is the missing right): their sample rates are not read; the last update and the modifications come from STATS_DATE and sys.sysindexes", noProps)})
	}
	return emit(last)
}
