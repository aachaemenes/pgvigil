package mssql

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// indexesCollector is mssql_indexes: the index inventory of every user database, every six hours, and the server's
// missing-index requests.
//
// Per database, one row per index of a user table or an indexed view (heaps have none): its definition (key columns
// in order with their direction, included columns, filter, uniqueness, whether it backs a primary key or a unique
// constraint, IGNORE_DUP_KEY, fill factor, compression), its size and rows (sys.dm_db_partition_stats), and what it
// was used for since the usage counters began: seeks, scans, lookups and writes with the time of the last read and
// the last write (sys.dm_db_index_usage_stats). The table's create and modify dates ride along: SQL Server keeps no
// creation date for an index.
//
// The usage counters are kept in memory: they begin again when the server starts, when the database is restored
// and when it is created or attached. The collector sends the three dates per database (the server's start time,
// the newest row of msdb.dbo.restorehistory, sys.databases.create_date) and the repository takes the latest as the
// start of the usage window (0092), names which it was, and judges no index unused before the window is seven days
// long. On an availability group's primary with readable secondaries the row says so: reads on a secondary are
// counted there, not here.
//
// The judgements are the repository's, never the collector's (0092: unused and seldom read indexes, exact
// duplicates, key subsets, the same keys with other includes, a unique constraint doubled by an index, the same
// keys in another order, the same leading column). The DISABLE line and the merged definition the page shows are
// text for a DBA to read: pgvigil runs neither.
//
// The missing-index requests (sys.dm_db_missing_index_group_stats, _groups and _details) are read for the whole
// server, the ixMissingCap with the most benefit: the columns the optimizer asked for and how often. They are the
// optimizer's hints, one per query shape, with no regard for the indexes that exist or for each other: the page
// shows them as hints and never as a CREATE INDEX statement.
//
// Each database is read through its own sys.sp_executesql (one SELECT, nothing written) and stored as a batch of its
// own, so a server with many databases never builds one payload of all of them; a database whose read fails keeps
// what the repository holds and its row says why. The system databases and database snapshots are not read. A
// database with more than ixIndexCap indexes stores the largest and says so. A run starts at another database each
// time (by the clock), so a deadline never cuts the same ones.
//
// Rights: VIEW SERVER STATE for the usage counters, the sizes and the missing-index requests (on SQL Server 2022
// VIEW SERVER PERFORMANCE STATE is enough for the server's views; the sizes of a database still need VIEW DATABASE
// STATE there, which VIEW SERVER STATE gives); VIEW ANY DEFINITION for the catalog of every database (without it
// sys.indexes lists only objects the login has a permission on); CONNECT ANY DATABASE, or a user in the database,
// to enter it; SELECT on msdb.dbo.restorehistory for the restore date (without it the window is taken from the
// other two dates and the row says the restore date was not read). Runs on SQL Server 2016 SP1 and later, Amazon
// RDS and Azure SQL Managed Instance; not on Azure SQL Database.
type indexesCollector struct{}

func init() { Register(indexesCollector{}) }

func (indexesCollector) Name() string                   { return Prefix + "indexes" }
func (indexesCollector) DefaultInterval() time.Duration { return 6 * time.Hour }

// Timeout: one catalog read per database.
func (indexesCollector) Timeout() time.Duration { return 5 * time.Minute }

func (indexesCollector) Applies(info Info) (bool, string) {
	switch {
	case info.Kind == KindAzureDB:
		return false, "not yet on Azure SQL Database (the per-database pass runs through other databases' sys.sp_executesql)"
	// VIEW SERVER STATE itself, not 2022's VIEW SERVER PERFORMANCE STATE: the sizes are a database's own DMV, which
	// needs VIEW DATABASE STATE, and only VIEW SERVER STATE gives that in every database
	case !info.ViewServerState:
		return false, "the login lacks VIEW SERVER STATE: sys.dm_db_index_usage_stats and the sizes of each database cannot be read"
	}
	return true, ""
}

const (
	// ixIndexCap is the most indexes of one database a read stores (the largest first).
	ixIndexCap = 20000
	// ixMissingCap is the most missing-index requests a read stores (the most benefit first).
	ixMissingCap = 500
)

// utcOf moves a datetime the server wrote in its own clock to UTC by the server's offset now (an instant from the
// other side of a daylight-saving change is an hour off: these dates are judged in days).
func utcOf(expr string) string {
	return "TODATETIMEOFFSET(DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), " + expr + "), 0)"
}

// userDatabasesSQL lists the user databases (no system database, no database snapshot) with what the per-database
// reads need: the name quoted by the server, whether the login can enter it, when it was created, when it was last
// restored and whether it is the primary of an availability group with a readable secondary. {{restore}} and
// {{secondary}} are filled by userDatabasesQuery.
var userDatabasesSQL = `SELECT CAST(d.database_id AS int) AS database_id, CAST(d.name AS nvarchar(128)) AS database_name, QUOTENAME(d.name) AS quoted_name,
  CAST(d.state_desc AS nvarchar(60)) AS database_state,
  CAST(CASE WHEN d.state = 0 AND HAS_DBACCESS(d.name) = 1 THEN 1 ELSE 0 END AS int) AS can_enter,
  ` + utcOf("d.create_date") + ` AS created_at,
  {{restore}} AS last_restore,
  CAST({{secondary}} AS int) AS readable_secondary
FROM sys.databases d
WHERE d.database_id > 4 AND d.source_database_id IS NULL
ORDER BY d.database_id`

var (
	userDBRestoreExpr = `(SELECT ` + utcOf("MAX(rh.restore_date)") + ` FROM msdb.dbo.restorehistory rh WHERE rh.destination_database_name = d.name)`
	userDBSecondary   = `CASE WHEN EXISTS (SELECT 1 FROM sys.dm_hadr_database_replica_states rs
      JOIN sys.availability_replicas ar ON ar.group_id = rs.group_id AND ar.replica_id <> rs.replica_id
     WHERE rs.database_id = d.database_id AND rs.is_local = 1 AND rs.is_primary_replica = 1
       AND ar.secondary_role_allow_connections > 0) THEN 1 ELSE 0 END`
)

// userDatabasesQuery fills userDatabasesSQL: with the restore history when the login may read it, with the
// availability group's replicas when Always On is enabled.
func userDatabasesQuery(restore, hadr bool) string {
	r, s := "CAST(NULL AS datetimeoffset)", "0"
	if restore {
		r = userDBRestoreExpr
	}
	if hadr {
		s = userDBSecondary
	}
	return strings.NewReplacer("{{restore}}", r, "{{secondary}}", s).Replace(userDatabasesSQL)
}

// userDB is one database of a per-database pass.
type userDB struct {
	id       int64
	name     string
	quoted   string
	state    string
	canEnter bool
	row      collect.Row // what the database's 'db' row starts from
}

// userDatabases reads the databases of a per-database pass. restoreRead says whether msdb's restore history was
// read (false: the login may not, and every row's last_restore is empty for that reason).
func userDatabases(ctx context.Context, conn *sql.Conn, info Info) (dbs []userDB, restoreRead bool, err error) {
	var ok sql.NullInt64
	if err := conn.QueryRowContext(ctx, `SELECT CAST(ISNULL(HAS_PERMS_BY_NAME(N'msdb.dbo.restorehistory', 'OBJECT', 'SELECT'), 0) AS int)`).Scan(&ok); err != nil {
		return nil, false, err
	}
	restoreRead = ok.Int64 == 1
	raw, err := QueryRows(ctx, conn, userDatabasesQuery(restoreRead, info.HADREnabled))
	if err != nil {
		return nil, restoreRead, err
	}
	for _, r := range raw {
		id, ok := r["database_id"].(int64)
		if !ok {
			continue
		}
		name, _ := r["database_name"].(string)
		quoted, _ := r["quoted_name"].(string)
		state, _ := r["database_state"].(string)
		enter, _ := r["can_enter"].(int64)
		secondary, _ := r["readable_secondary"].(int64)
		dbs = append(dbs, userDB{id: id, name: name, quoted: quoted, state: state, canEnter: enter == 1 && quoted != "",
			row: collect.Row{"kind": "db", "database_id": id, "database_name": name, "database_state": state, "created_at": r["created_at"],
				"last_restore": r["last_restore"], "restore_read": restoreRead, "readable_secondary": secondary == 1, "read": false, "note": nil}})
	}
	return dbs, restoreRead, nil
}

// rotate returns the databases starting at another one each run (the clock in steps of every), so a deadline that
// cuts a run short never cuts the same databases.
func rotate(dbs []userDB, now time.Time, every time.Duration) []userDB {
	if len(dbs) < 2 || every <= 0 {
		return dbs
	}
	start := int((now.Unix() / int64(every.Seconds())) % int64(len(dbs)))
	return append(append([]userDB{}, dbs[start:]...), dbs[:start]...)
}

// whyNotEntered says why a database's catalog is not read.
func whyNotEntered(db userDB) string {
	if db.state != "ONLINE" {
		return "not read: the database is " + strings.ToLower(db.state)
	}
	return "not read: the login cannot enter the database (CONNECT ANY DATABASE, or a user in the database, is the missing right)"
}

// indexesSQL runs inside one database: one row per index of a user table or an indexed view, the largest first.
// The key and included columns ride as JSON arrays the server writes (FOR JSON, SQL Server 2016 and later), so a
// column's name can hold any character.
var indexesSQL = `SELECT TOP (@cap) 'index' AS kind, CAST(i.object_id AS bigint) AS object_id, CAST(i.index_id AS int) AS index_id,
  CAST(SCHEMA_NAME(o.schema_id) AS nvarchar(128)) AS schema_name, CAST(o.name AS nvarchar(128)) AS table_name, CAST(i.name AS nvarchar(128)) AS index_name,
  CAST(i.type_desc AS nvarchar(60)) AS index_type, CAST(i.is_unique AS int) AS is_unique, CAST(i.is_primary_key AS int) AS is_primary_key,
  CAST(i.is_unique_constraint AS int) AS is_unique_constraint, CAST(i.is_disabled AS int) AS is_disabled,
  CAST(i.is_hypothetical AS int) AS is_hypothetical, CAST(i.has_filter AS int) AS has_filter,
  CAST(i.filter_definition AS nvarchar(4000)) AS filter_definition, CAST(i.ignore_dup_key AS int) AS ignore_dup_key,
  CAST(i.fill_factor AS int) AS fill_factor,
  (SELECT c.name AS n, CAST(ic.is_descending_key AS int) AS d
     FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.key_ordinal > 0
    ORDER BY ic.key_ordinal FOR JSON PATH) AS keys_json,
  (SELECT c.name AS n
     FROM sys.index_columns ic JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
    WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
    ORDER BY c.name FOR JSON PATH) AS includes_json,
  CAST(ps.row_count AS bigint) AS row_count, CAST(ps.reserved_kb AS bigint) AS size_kb,
  CAST(pt.partitions AS int) AS partitions, CAST(pt.compression AS nvarchar(60)) AS compression,
  CAST(ISNULL(us.user_seeks, 0) AS bigint) AS user_seeks, CAST(ISNULL(us.user_scans, 0) AS bigint) AS user_scans,
  CAST(ISNULL(us.user_lookups, 0) AS bigint) AS user_lookups, CAST(ISNULL(us.user_updates, 0) AS bigint) AS user_updates,
  ` + utcOf("(SELECT MAX(x.v) FROM (VALUES (us.last_user_seek), (us.last_user_scan), (us.last_user_lookup)) x(v))") + ` AS last_read,
  ` + utcOf("us.last_user_update") + ` AS last_write,
  ` + utcOf("o.create_date") + ` AS table_created, ` + utcOf("o.modify_date") + ` AS table_modified
FROM sys.indexes i
JOIN sys.objects o ON o.object_id = i.object_id
LEFT JOIN (SELECT p.object_id, p.index_id, SUM(p.row_count) AS row_count, SUM(p.reserved_page_count) * 8 AS reserved_kb
             FROM sys.dm_db_partition_stats p GROUP BY p.object_id, p.index_id) ps ON ps.object_id = i.object_id AND ps.index_id = i.index_id
LEFT JOIN (SELECT p.object_id, p.index_id, COUNT(*) AS partitions,
                  CASE WHEN MIN(p.data_compression_desc) = MAX(p.data_compression_desc) THEN MIN(p.data_compression_desc) ELSE N'MIXED' END AS compression
             FROM sys.partitions p GROUP BY p.object_id, p.index_id) pt ON pt.object_id = i.object_id AND pt.index_id = i.index_id
LEFT JOIN sys.dm_db_index_usage_stats us ON us.database_id = DB_ID() AND us.object_id = i.object_id AND us.index_id = i.index_id
WHERE o.is_ms_shipped = 0 AND o.type IN ('U', 'V') AND i.index_id > 0
ORDER BY ISNULL(ps.reserved_kb, 0) DESC, i.object_id, i.index_id`

// missingIndexSQL: the server's missing-index requests, the most benefit first. benefit is the figure sp_BlitzIndex
// ranks by: the times the optimizer wanted the index, times the cost of the queries that did, times the share of
// that cost it expected to save.
var missingIndexSQL = `SELECT TOP (@top) 'missing' AS kind, CAST(d.database_id AS int) AS database_id, CAST(DB_NAME(d.database_id) AS nvarchar(128)) AS database_name,
  CAST(d.object_id AS bigint) AS object_id, CAST(d.statement AS nvarchar(520)) AS table_ref,
  CAST(d.equality_columns AS nvarchar(4000)) AS equality_columns, CAST(d.inequality_columns AS nvarchar(4000)) AS inequality_columns,
  CAST(d.included_columns AS nvarchar(4000)) AS included_columns,
  CAST(s.user_seeks AS bigint) AS user_seeks, CAST(s.user_scans AS bigint) AS user_scans, CAST(s.unique_compiles AS bigint) AS compiles,
  CAST(s.avg_total_user_cost AS float) AS avg_cost, CAST(s.avg_user_impact AS float) AS avg_impact,
  ` + utcOf("(SELECT MAX(x.v) FROM (VALUES (s.last_user_seek), (s.last_user_scan)) x(v))") + ` AS last_request,
  CAST(s.avg_total_user_cost * s.avg_user_impact * (s.user_seeks + s.user_scans) AS float) AS benefit
FROM sys.dm_db_missing_index_group_stats s
JOIN sys.dm_db_missing_index_groups g ON g.index_group_handle = s.group_handle
JOIN sys.dm_db_missing_index_details d ON d.index_handle = g.index_handle
WHERE d.database_id <> 32767
ORDER BY benefit DESC, d.database_id, d.object_id, d.index_handle`

// indexColumns turns the server's JSON array of an index's columns into quoted names; a descending key column
// carries " DESC". An empty or missing array (a columnstore index has no key) is no column.
func indexColumns(v any) ([]string, error) {
	s, _ := v.(string)
	if strings.TrimSpace(s) == "" {
		return []string{}, nil
	}
	var cols []struct {
		N string `json:"n"`
		D int    `json:"d"`
	}
	if err := json.Unmarshal([]byte(s), &cols); err != nil {
		return nil, err
	}
	out := make([]string, 0, len(cols))
	for _, c := range cols {
		q := quoteName(c.N)
		if c.D == 1 {
			q += " DESC"
		}
		out = append(out, q)
	}
	return out, nil
}

// indexRows gives each index row its two column lists (key_columns, include_columns) in place of the JSON the
// server sent and names its database. A row whose lists cannot be read is dropped and counted.
func indexRows(db userDB, rows []collect.Row) (out []collect.Row, bad int) {
	out = make([]collect.Row, 0, len(rows))
	for _, r := range rows {
		keys, err1 := indexColumns(r["keys_json"])
		incl, err2 := indexColumns(r["includes_json"])
		if err1 != nil || err2 != nil {
			bad++
			continue
		}
		delete(r, "keys_json")
		delete(r, "includes_json")
		r["key_columns"], r["include_columns"] = keys, incl
		r["database_id"], r["database_name"] = db.id, db.name
		out = append(out, r)
	}
	return out, bad
}

// onlineIndexBuilds says whether the edition builds an index online (Enterprise, Developer and Evaluation are engine
// edition 3; Azure SQL Database and Managed Instance do too): the merged definition's ONLINE option follows it.
func onlineIndexBuilds(info Info) bool {
	return info.EngineEdition == 3 || info.EngineEdition == 5 || info.EngineEdition == 8
}

// Run is the read as one slice, for a caller that does not know the batch path.
func (c indexesCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	var out []collect.Row
	err := c.RunBatches(ctx, conn, info, BatchOptions{}, nil, func(rows []collect.Row) error {
		out = append(out, rows...)
		return nil
	})
	return out, err
}

// RunBatches reads the databases one by one, each stored as a batch of its own with the run's state row, then the
// missing-index requests and the list of the databases the server has (the repository drops what is no longer
// there).
func (c indexesCollector) RunBatches(ctx context.Context, conn *sql.Conn, info Info, opt BatchOptions, _ CursorFunc, emit EmitFunc) error {
	if err := perfState(ctx, conn, info, "sys.dm_db_index_usage_stats"); err != nil {
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
	st["online_index_builds"] = onlineIndexBuilds(info)
	dbs, restoreRead, err := userDatabases(ctx, conn, info)
	if err != nil {
		return err
	}
	var failed []string
	var firstErr error
	names := make([]string, 0, len(dbs))
	closed, cut := 0, 0
	for _, db := range rotate(dbs, time.Now(), c.DefaultInterval()) {
		names = append(names, db.name)
		batch := []collect.Row{st, db.row}
		switch {
		case !db.canEnter:
			db.row["note"] = whyNotEntered(db)
			if db.state == "ONLINE" {
				closed++
			}
		case cut > 0 || ctx.Err() != nil || (!opt.Deadline.IsZero() && time.Now().After(opt.Deadline)):
			db.row["note"] = "not read this time: the run's deadline came before this database's turn; the next run starts at another database"
			cut++
		default:
			rows, err := qsRead(ctx, conn, db.quoted, indexesSQL, "@cap int", sql.Named("cap", ixIndexCap+1))
			if err != nil {
				if ctx.Err() != nil {
					db.row["note"] = "not read this time: the run's deadline came during this database's read"
					cut++
					break
				}
				db.row["note"] = "the read failed: " + err.Error()
				failed = append(failed, db.name)
				if firstErr == nil {
					firstErr = err
				}
				break
			}
			capped := len(rows) > ixIndexCap
			if capped {
				rows = rows[:ixIndexCap]
			}
			idx, bad := indexRows(db, rows)
			db.row["read"], db.row["capped"], db.row["indexes"] = true, capped, len(idx)
			if capped {
				db.row["note"] = fmt.Sprintf("more than %d indexes: the %d largest are stored", ixIndexCap, ixIndexCap)
			}
			if bad > 0 {
				batch = append(batch, collect.Row{"kind": "collector_error", "source": "sys.index_columns",
					"message": fmt.Sprintf("%s: the column list of %d index(es) could not be read; they are not stored", db.name, bad)})
			}
			batch = append(batch, idx...)
		}
		if err := emit(batch); err != nil {
			return err
		}
	}
	// the last batch: what stands for the whole server
	last := []collect.Row{st, {"kind": "databases", "names": names}}
	missing, err := QueryRows(ctx, conn, missingIndexSQL, sql.Named("top", ixMissingCap))
	switch {
	case err != nil && ctx.Err() != nil:
		return err
	case err != nil:
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.dm_db_missing_index_group_stats", "message": "the missing-index requests were not read: " + err.Error()})
	default:
		// the marker says the list is this read's: a stored request it does not hold is gone (the server restarted,
		// or the table's metadata changed)
		last = append(append(last, missing...), collect.Row{"kind": "missing_read", "capped": len(missing) >= ixMissingCap})
	}
	if !restoreRead {
		last = append(last, collect.Row{"kind": "collector_error", "source": "msdb.dbo.restorehistory",
			"message": "the login may not read msdb.dbo.restorehistory: a database's usage window is taken from the server's start and the database's create date alone, and a restore since then is not seen"})
	}
	if len(failed) > 0 {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.indexes",
			"message": fmt.Sprintf("%d database(s) were not read this time (%s): %v; the repository keeps what it holds of them", len(failed), firstFew(failed, 5), firstErr)})
	}
	if cut > 0 {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.indexes",
			"message": fmt.Sprintf("the run's deadline came before %d database(s) were read; the next run starts at another database", cut)})
	}
	if closed > 0 && closed == len(dbs) {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.databases",
			"message": fmt.Sprintf("the login cannot enter any of the %d user database(s): GRANT CONNECT ANY DATABASE (with VIEW ANY DEFINITION) lets it read each catalog", closed)})
	}
	if !info.ViewAnyDefinition {
		last = append(last, collect.Row{"kind": "collector_error", "source": "sys.indexes", "message": noDefinitionNote("indexes")})
	}
	return emit(last)
}

// noDefinitionNote says what a login without VIEW ANY DEFINITION gets from a database's catalog.
func noDefinitionNote(what string) string {
	return "the login lacks VIEW ANY DEFINITION: a database's catalog lists only the objects the login has a permission on, so the " + what + " stored may be a part of what the database has"
}
