package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// indexLocksCollector is mssql_indexlocks: where sessions waited for locks, per index, every five minutes, from
// sys.dm_db_index_operational_stats: the row lock waits and their milliseconds, the page lock waits and theirs, and
// the lock escalations: the attempts (the engine's checks as a statement's locks on the index grow) and the
// escalations made (the index's row and page locks traded for one table lock). An UPDATE of 6,000 rows gets three
// attempts and no escalation on SQL Server 2022, one of 20,000 rows is escalated (measured). Only rowsets with a lock
// wait or an escalation attempt are read. The function counts since the
// index's metadata entered the cache, so the collector sends the counters as they are, one row per rowset (a
// columnstore partition has several), and the import stores what the interval added, summed per index (0084: an
// index new to the list, or one whose counters went down, gives its whole count; nothing is ever negative).
//
// These are counters of waits that ENDED on the index: they say where sessions collided, not who held the lock. The
// holder of a chain is on the Running queries and Blocked reports pages.
//
// The function is called once per ONLINE database, never for the whole server at once: it waits behind a schema
// change (an offline index rebuild, an ALTER TABLE or a partition switch inside a transaction) on any object it
// lists, and one such lock would fail the read of every database. A database whose call fails is named in the
// state row (skipped): the import keeps its counters, so its next read takes the difference from the last read
// that reached it, and the run is partial. The same holds for the databases a run's deadline cuts off.
//
// The function knows ids only. The schema, table and index names are read from each database's own catalog
// (sys.indexes and sys.objects through that database's sys.sp_executesql, one SELECT, nothing written), for the
// 500 objects per database with the most lock wait; a database the login cannot enter leaves its rows without
// names and the page shows the ids. The list is cut at the 20,000 rowsets with the most lock wait; the state row
// says so (capped) and the import then takes no difference for a rowset the cut read did not list.
//
// Not read: the page latch and page IO latch counters of the same function (Darling's Locking page shows them; a
// latch is not a lock, and the Waits page has PAGELATCH and PAGEIOLATCH), the engine's own catalog tables (object
// ids 1 to 100: sysrscols, sysallocunits ..., nothing a DBA can index or change), and memory-optimized tables,
// which the function does not list.
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
	// indexLocksCap is the most rowsets one read stores.
	indexLocksCap = 20000
	// indexNamesCap is the most objects of one database whose names one read asks for.
	indexNamesCap = 500
)

// indexLockDatabasesSQL: the databases the function is asked about - the online ones the login can enter (without a
// user there the function refuses with 297, as on Amazon RDS, whose master user cannot enter model) - with what the
// name read needs (the name quoted by the server, and whether the login can enter the database).
const indexLockDatabasesSQL = `SELECT CAST(d.database_id AS int) AS database_id, CAST(d.name AS nvarchar(128)) AS database_name,
  QUOTENAME(d.name) AS quoted_name, CAST(ISNULL(HAS_DBACCESS(d.name), 0) AS int) AS can_enter
FROM sys.databases d
WHERE d.state = 0 AND HAS_DBACCESS(d.name) = 1
ORDER BY d.database_id`

// indexLocksSQL: one database's rowsets with a lock wait or an escalation attempt. @db is the database's id. Object
// ids 1 to 100 are the engine's own catalog tables; a temporary table's id is negative and stays in.
const indexLocksSQL = `SELECT 'index' AS kind, CAST(os.database_id AS int) AS database_id, CAST(os.object_id AS bigint) AS object_id,
  CAST(os.index_id AS int) AS index_id, CAST(os.partition_number AS int) AS partition_number, CAST(os.hobt_id AS bigint) AS hobt_id,
  CAST(os.row_lock_wait_count AS bigint) AS row_lock_waits, CAST(os.row_lock_wait_in_ms AS bigint) AS row_lock_wait_ms,
  CAST(os.page_lock_wait_count AS bigint) AS page_lock_waits, CAST(os.page_lock_wait_in_ms AS bigint) AS page_lock_wait_ms,
  CAST(os.index_lock_promotion_attempt_count AS bigint) AS escalation_attempts,
  CAST(os.index_lock_promotion_count AS bigint) AS escalations
FROM sys.dm_db_index_operational_stats(@db, NULL, NULL, NULL) os
WHERE (os.row_lock_wait_count > 0 OR os.page_lock_wait_count > 0 OR os.index_lock_promotion_attempt_count > 0)
  AND os.object_id NOT BETWEEN 1 AND 100`

// indexNamesSQL runs inside one database (through its sys.sp_executesql). The first %s is the database's name from
// QUOTENAME on the server, the second the object ids, integers from the server's own rows.
const indexNamesSQL = `EXEC %s.sys.sp_executesql N'SELECT CAST(i.object_id AS bigint) AS object_id, CAST(i.index_id AS int) AS index_id,
  CAST(SCHEMA_NAME(o.schema_id) AS nvarchar(128)) AS schema_name, CAST(o.name AS nvarchar(128)) AS table_name,
  CAST(i.name AS nvarchar(128)) AS index_name, CAST(i.type_desc AS nvarchar(60)) AS index_type
FROM sys.indexes i JOIN sys.objects o ON o.object_id = i.object_id
WHERE i.object_id IN (%s)'`

// indexDB is one database of the read.
type indexDB struct {
	id       int64
	name     string
	quoted   string
	canEnter bool
}

func (indexLocksCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_db_index_operational_stats"); err != nil {
		return nil, err
	}
	state, err := QueryRows(ctx, conn, perfStateSQL)
	if err != nil {
		return nil, err
	}
	raw, err := QueryRows(ctx, conn, indexLockDatabasesSQL)
	if err != nil {
		return nil, err
	}
	dbs := make([]indexDB, 0, len(raw))
	for _, r := range raw {
		id, ok := r["database_id"].(int64)
		if !ok {
			continue
		}
		name, _ := r["database_name"].(string)
		quoted, _ := r["quoted_name"].(string)
		enter, _ := r["can_enter"].(int64)
		dbs = append(dbs, indexDB{id: id, name: name, quoted: quoted, canEnter: enter == 1})
	}

	// one call per database: a schema change held in one of them fails that database's call, not the read
	var rows, notes []collect.Row
	var failed []string
	var firstErr error
	skipped := []int64{}
	cut := 0
	stop, hasStop := ctx.Deadline()
	for _, db := range dbs {
		if cut > 0 || ctx.Err() != nil || (hasStop && time.Until(stop) < 15*time.Second) {
			skipped = append(skipped, db.id)
			cut++
			continue
		}
		part, err := QueryRows(ctx, conn, indexLocksSQL, sql.Named("db", db.id))
		if err != nil {
			skipped = append(skipped, db.id)
			if ctx.Err() != nil {
				cut++
				continue
			}
			failed = append(failed, db.name)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		for _, r := range part {
			r["database_name"] = db.name
			r["schema_name"], r["table_name"], r["index_name"], r["index_type"] = nil, nil, nil, nil
		}
		rows = append(rows, part...)
	}
	if len(dbs) > 0 && len(failed) == len(dbs) {
		return nil, fmt.Errorf("sys.dm_db_index_operational_stats failed in every database: %w", firstErr)
	}
	if len(failed) > 0 {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_db_index_operational_stats",
			"message": fmt.Sprintf("%d database(s) were not read this time (%s): %v; their lock waits are counted at their next read", len(failed), firstFew(failed, 5), firstErr)})
	}
	if cut > 0 {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_db_index_operational_stats",
			"message": fmt.Sprintf("the run's deadline came before %d database(s) were read: their lock waits are counted at their next read", cut)})
	}

	// the most lock wait first: the cut and the names both go by it
	sort.SliceStable(rows, func(a, b int) bool { return lockWaitMS(rows[a]) > lockWaitMS(rows[b]) })
	capped := len(rows) > indexLocksCap
	if capped {
		rows = rows[:indexLocksCap]
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_db_index_operational_stats",
			"message": fmt.Sprintf("more than %d rowsets have lock waits: the %d with the most lock wait are stored", indexLocksCap, indexLocksCap)})
	}
	for _, s := range state {
		s["capped"], s["skipped"] = capped, skipped
	}
	if n := nameIndexes(ctx, conn, rows, dbs); n != "" {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.indexes", "message": n})
	}
	state = append(state, rows...)
	return append(state, notes...), nil
}

// lockWaitMS is a row's lock wait, row and page locks together.
func lockWaitMS(r collect.Row) int64 {
	a, _ := r["row_lock_wait_ms"].(int64)
	b, _ := r["page_lock_wait_ms"].(int64)
	return a + b
}

// nameIndexes fills the rows' schema, table and index names from each database's catalog and returns what could
// not be named, "" when everything was.
func nameIndexes(ctx context.Context, conn *sql.Conn, rows []collect.Row, dbs []indexDB) string {
	want, order, past := indexObjects(rows, indexNamesCap)
	if len(order) == 0 {
		return ""
	}
	byID := map[int64]indexDB{}
	for _, d := range dbs {
		byID[d.id] = d
	}
	var failed []string
	closed, cut := 0, 0
	stop, hasStop := ctx.Deadline()
	for _, id := range order {
		db, ok := byID[id]
		if !ok || !db.canEnter || db.quoted == "" {
			closed++
			continue
		}
		if cut > 0 || ctx.Err() != nil || (hasStop && time.Until(stop) < 10*time.Second) {
			cut++
			continue
		}
		names, err := QueryRows(ctx, conn, fmt.Sprintf(indexNamesSQL, db.quoted, strings.Join(want[id], ", ")))
		if err != nil {
			if ctx.Err() != nil {
				cut++
			} else {
				failed = append(failed, db.name)
			}
			continue
		}
		applyIndexNames(rows, id, names)
	}
	left := 0
	for _, r := range rows {
		if r["table_name"] == nil {
			left++
		}
	}
	if left == 0 {
		return ""
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
		// every catalog was read and still gave no row: the object is gone, or the login may not see its definition
		return fmt.Sprintf("%d of %d rows are stored with their ids and no names: the object was dropped since, or the login lacks VIEW ANY DEFINITION", left, len(rows))
	}
	return fmt.Sprintf("%d of %d rows are stored with their ids and no names: %s", left, len(rows), strings.Join(parts, ", "))
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
