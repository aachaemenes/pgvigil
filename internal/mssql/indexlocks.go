package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// indexLocksCollector is mssql_indexlocks: where sessions waited for locks, per index, every five minutes, from
// sys.dm_db_index_operational_stats(NULL, NULL, NULL, NULL): the row lock waits and their milliseconds, the page
// lock waits and theirs, and the lock escalations (the attempts to trade an index's row and page locks for one
// table lock, and the attempts that succeeded). Only partitions with a lock wait or an escalation attempt are
// read. The function counts since the index's metadata entered the cache, so the collector sends the counters as
// they are and the import stores what the interval added (0084: an index new to the list, or one whose counters
// went down, gives its whole count; nothing is ever negative).
//
// These are counters of waits that ENDED on the index: they say where sessions collided, not who held the lock. The
// holder of a chain is on the Running queries and Blocked reports pages.
//
// The function knows ids only. The schema, table and index names are read from each database's own catalog
// (sys.indexes and sys.objects through that database's sys.sp_executesql, one SELECT, nothing written), for the
// 500 objects per database with the most lock wait; a database the login cannot enter, or one past the run's
// deadline, leaves its rows without names and the page shows the ids. The list is cut at the 20,000 partitions
// with the most lock wait; the state row says so (capped) and the import then takes no difference for a partition
// the cut read did not list.
//
// Not read: the page latch and page IO latch counters of the same function (Darling's Locking page shows them; a
// latch is not a lock, and the Waits page has PAGELATCH and PAGEIOLATCH), the system base tables (object ids 1 to
// 100), and memory-optimized tables, which the function does not list.
//
// Rights as mssql_cpu (perfApplies). Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed
// Instance; not on Azure SQL Database.
type indexLocksCollector struct{}

func init() { Register(indexLocksCollector{}) }

func (indexLocksCollector) Name() string                   { return Prefix + "indexlocks" }
func (indexLocksCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (indexLocksCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not yet on Azure SQL Database (the database's own index statistics are a later wave)"
	}
	return perfApplies(info, "sys.dm_db_index_operational_stats")
}

const (
	// indexLocksCap is the most partitions one read stores.
	indexLocksCap = 20000
	// indexNamesCap is the most objects of one database whose names one read asks for.
	indexNamesCap = 500
)

// indexLocksSQL: the partitions with a lock wait or an escalation attempt, the most lock wait first. %d is the cap + 1.
// Object ids 1 to 100 are the system base tables (sysrscols, sysallocunits ...): no catalog view names them and no
// DBA can change them; a temporary table's id is negative and stays in.
const indexLocksSQL = `SELECT TOP (%d) 'index' AS kind, CAST(os.database_id AS int) AS database_id, CAST(os.object_id AS bigint) AS object_id,
  CAST(os.index_id AS int) AS index_id, CAST(os.partition_number AS int) AS partition_number,
  CAST(DB_NAME(os.database_id) AS nvarchar(128)) AS database_name,
  SUM(CAST(os.row_lock_wait_count AS bigint)) AS row_lock_waits, SUM(CAST(os.row_lock_wait_in_ms AS bigint)) AS row_lock_wait_ms,
  SUM(CAST(os.page_lock_wait_count AS bigint)) AS page_lock_waits, SUM(CAST(os.page_lock_wait_in_ms AS bigint)) AS page_lock_wait_ms,
  SUM(CAST(os.index_lock_promotion_attempt_count AS bigint)) AS escalation_attempts,
  SUM(CAST(os.index_lock_promotion_count AS bigint)) AS escalations
FROM sys.dm_db_index_operational_stats(NULL, NULL, NULL, NULL) os
WHERE (os.row_lock_wait_count > 0 OR os.page_lock_wait_count > 0 OR os.index_lock_promotion_attempt_count > 0)
  AND os.object_id NOT BETWEEN 1 AND 100
GROUP BY os.database_id, os.object_id, os.index_id, os.partition_number
ORDER BY SUM(CAST(os.row_lock_wait_in_ms AS bigint)) + SUM(CAST(os.page_lock_wait_in_ms AS bigint)) DESC,
  os.database_id, os.object_id, os.index_id, os.partition_number`

// indexDatabasesSQL: the databases of the list the login can enter, with their names quoted by the server. %s is
// the database ids, integers from the server's own rows.
const indexDatabasesSQL = `SELECT CAST(d.database_id AS int) AS database_id, QUOTENAME(d.name) AS quoted_name
FROM sys.databases d
WHERE d.state = 0 AND HAS_DBACCESS(d.name) = 1 AND d.database_id IN (%s)`

// indexNamesSQL runs inside one database (through its sys.sp_executesql). The first %s is the database's name from
// QUOTENAME on the server, the second the object ids, integers from the server's own rows.
const indexNamesSQL = `EXEC %s.sys.sp_executesql N'SELECT CAST(i.object_id AS bigint) AS object_id, CAST(i.index_id AS int) AS index_id,
  CAST(SCHEMA_NAME(o.schema_id) AS nvarchar(128)) AS schema_name, CAST(o.name AS nvarchar(128)) AS table_name,
  CAST(i.name AS nvarchar(128)) AS index_name, CAST(i.type_desc AS nvarchar(60)) AS index_type
FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id
WHERE i.object_id IN (%s)'`

func (indexLocksCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_db_index_operational_stats"); err != nil {
		return nil, err
	}
	state, err := QueryRows(ctx, conn, perfStateSQL)
	if err != nil {
		return nil, err
	}
	rows, err := QueryRows(ctx, conn, fmt.Sprintf(indexLocksSQL, indexLocksCap+1))
	if err != nil {
		return nil, err
	}
	var notes []collect.Row
	capped := len(rows) > indexLocksCap
	if capped {
		rows = rows[:indexLocksCap]
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_db_index_operational_stats",
			"message": fmt.Sprintf("more than %d partitions have lock waits: the %d with the most lock wait are stored", indexLocksCap, indexLocksCap)})
	}
	for _, s := range state {
		s["capped"] = capped
	}
	for _, r := range rows {
		r["schema_name"], r["table_name"], r["index_name"], r["index_type"] = nil, nil, nil, nil
	}
	if n := nameIndexes(ctx, conn, rows); n != "" {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.indexes", "message": n})
	}
	state = append(state, rows...)
	return append(state, notes...), nil
}

// nameIndexes fills the rows' schema, table and index names from each database's catalog and returns what could
// not be named, "" when everything was.
func nameIndexes(ctx context.Context, conn *sql.Conn, rows []collect.Row) string {
	want, order, past := indexObjects(rows, indexNamesCap)
	if len(order) == 0 {
		return ""
	}
	ids := make([]string, len(order))
	for i, id := range order {
		ids[i] = strconv.FormatInt(id, 10)
	}
	dbs, err := QueryRows(ctx, conn, fmt.Sprintf(indexDatabasesSQL, strings.Join(ids, ", ")))
	if err != nil {
		return "the indexes' names were not read (" + err.Error() + "): the counters are stored with the ids"
	}
	quoted := map[int64]string{}
	for _, d := range dbs {
		id, _ := d["database_id"].(int64)
		if q, _ := d["quoted_name"].(string); q != "" {
			quoted[id] = q
		}
	}
	var failed []string
	closed, cut := 0, 0
	stop, hasStop := ctx.Deadline()
	for _, db := range order {
		q, ok := quoted[db]
		if !ok {
			closed++
			continue
		}
		if cut > 0 || ctx.Err() != nil || (hasStop && time.Until(stop) < 10*time.Second) {
			cut++
			continue
		}
		names, err := QueryRows(ctx, conn, fmt.Sprintf(indexNamesSQL, q, strings.Join(want[db], ", ")))
		if err != nil {
			if ctx.Err() != nil {
				cut++
			} else {
				failed = append(failed, q)
			}
			continue
		}
		applyIndexNames(rows, db, names)
	}
	var parts []string
	if past > 0 {
		parts = append(parts, fmt.Sprintf("%d object(s) past the %d a database's names are read for", past, indexNamesCap))
	}
	if closed > 0 {
		parts = append(parts, fmt.Sprintf("%d database(s) the login cannot enter", closed))
	}
	if cut > 0 {
		parts = append(parts, fmt.Sprintf("%d database(s) past the run's deadline", cut))
	}
	if len(failed) > 0 {
		parts = append(parts, fmt.Sprintf("%d database(s) whose catalog read failed (%s)", len(failed), firstFew(failed, 5)))
	}
	if len(parts) == 0 {
		return ""
	}
	return "stored with their ids and no names: the indexes of " + strings.Join(parts, ", ")
}

// indexObjects lists, per database in the rows' order (the most lock wait first), the first perDB distinct object
// ids as text, the databases in the order they first appear, and how many objects were past perDB.
func indexObjects(rows []collect.Row, perDB int) (want map[int64][]string, order []int64, past int) {
	want = map[int64][]string{}
	seen := map[[2]int64]bool{}
	for _, r := range rows {
		db, ok1 := r["database_id"].(int64)
		obj, ok2 := r["object_id"].(int64)
		if !ok1 || !ok2 || seen[[2]int64{db, obj}] {
			continue
		}
		seen[[2]int64{db, obj}] = true
		if _, known := want[db]; !known {
			order = append(order, db)
			want[db] = nil
		}
		if len(want[db]) < perDB {
			want[db] = append(want[db], strconv.FormatInt(obj, 10))
		} else {
			past++
		}
	}
	return want, order, past
}

// applyIndexNames writes one database's catalog rows into its index rows, by object and index id.
func applyIndexNames(rows []collect.Row, databaseID int64, names []collect.Row) {
	by := map[[2]int64]collect.Row{}
	for _, n := range names {
		obj, ok1 := n["object_id"].(int64)
		idx, ok2 := n["index_id"].(int64)
		if ok1 && ok2 {
			by[[2]int64{obj, idx}] = n
		}
	}
	for _, r := range rows {
		if db, _ := r["database_id"].(int64); db != databaseID {
			continue
		}
		obj, _ := r["object_id"].(int64)
		idx, _ := r["index_id"].(int64)
		if n, ok := by[[2]int64{obj, idx}]; ok {
			r["schema_name"], r["table_name"], r["index_name"], r["index_type"] = n["schema_name"], n["table_name"], n["index_name"], n["index_type"]
		}
	}
}
