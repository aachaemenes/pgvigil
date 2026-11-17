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

// funcStatsCollector is mssql_funcstats: what each scalar function and each trigger did, every five minutes, from
// sys.dm_exec_function_stats and sys.dm_exec_trigger_stats - mssql_procstats' read for the two views beside the
// procedures': the counters as they are, one row per cached plan (its handle and cached time), and the import stores
// what the interval added.
//
// sys.dm_exec_function_stats lists SCALAR functions only, and of those only the ones that ran as functions: it
// 'does not return information about table valued functions, and about scalar functions that are inlined with
// Scalar UDF Inlining' (Microsoft Learn, sys.dm_exec_function_stats). A function that is not listed was inlined, is
// table-valued or did not run; it was not idle. The view arrived with SQL Server 2016 and has no spills column.
//
// sys.dm_exec_trigger_stats lists a DML trigger under its database with a name OBJECT_NAME gives. A DDL or logon
// trigger has none there: a database's DDL trigger is listed under its database (its name is in that database's
// sys.triggers), a server's DDL or logon trigger under database id 1 (its name is in sys.server_triggers; master is
// where the server keeps it, not a database it belongs to). Those names are read from the two catalogs, and the
// row says which it is (trigger_scope 'database' or 'server').
//
// Either view's read failing fails the run: a payload without one kind would drop that kind's last counters and
// count every plan whole at the next read. The clock first, the names' lock fallback, the cut at 5,000 plans a
// view and the resource database left out are mssql_procstats' (procstats.go says why). Rights and platforms as
// mssql_procstats: not on Azure SQL Database.
//
// Reading the two views beside the procedures' view follows sp_QuickieCache 1.11's function and trigger reads
// (DarlingData, sp_QuickieCache/sp_QuickieCache.sql L1918-2032 at Updates_20261101: the function read, then the
// trigger read; MIT, Copyright (c) 2021 Darling Data, LLC): the statements are pgvigil's own.
type funcStatsCollector struct{}

func init() { Register(funcStatsCollector{}) }

func (funcStatsCollector) Name() string                   { return Prefix + "funcstats" }
func (funcStatsCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (funcStatsCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not yet on Azure SQL Database (the database's own function and trigger statistics are a later wave)"
	}
	return perfApplies(info, "sys.dm_exec_function_stats and sys.dm_exec_trigger_stats")
}

// funcStatsCap is the most plans one read stores of each view.
const funcStatsCap = 5000

// funcTriggerNameDBs is the most databases one read asks for their DDL triggers' names.
const funcTriggerNameDBs = 50

// funcStatsViews: the two views and the kind their rows carry.
var funcStatsViews = []struct{ kind, view string }{
	{"function", "sys.dm_exec_function_stats"},
	{"trigger", "sys.dm_exec_trigger_stats"},
}

// funcStatsFigures: the payload's key and the view's column of every figure a server may lack - the spilled pages
// (total_spills: the triggers' view from SQL Server 2016 SP2 and 2017 CU3, the functions' view never) and the 12
// extremes mssql_procstats reads. A column the view lacks is NULL, never 0.
var funcStatsFigures = append([]struct{ key, col string }{{"spills", "total_spills"}}, procStatsSpread...)

// funcStatsColsSQL lists one view's columns (%s: the view); no row means the server has no such view.
const funcStatsColsSQL = `SELECT CAST(name AS nvarchar(128)) AS name FROM sys.all_columns WHERE object_id = OBJECT_ID(N'%s')`

// funcStatsSQL: one row per cached plan of a function or a trigger, the most CPU first. {{schema}} and {{object}}
// are the name expressions, or NULL in the second run; {{figures}} is funcStatsFigures. The handle rides as 0x text.
const funcStatsSQL = `SELECT TOP ({{top}}) '{{kind}}' AS kind, fs.plan_handle AS plan_handle, fs.cached_time AS cached_time,
  CAST(fs.database_id AS int) AS database_id, CAST(fs.object_id AS bigint) AS object_id,
  CAST(DB_NAME(fs.database_id) AS nvarchar(128)) AS database_name,
  CAST({{schema}} AS nvarchar(128)) AS schema_name, CAST({{object}} AS nvarchar(128)) AS object_name,
  CAST(fs.type_desc AS nvarchar(60)) AS type_desc,
  CAST(fs.execution_count AS bigint) AS execution_count,
  CAST(fs.total_worker_time AS bigint) AS worker_us, CAST(fs.total_elapsed_time AS bigint) AS elapsed_us,
  CAST(fs.total_logical_reads AS bigint) AS logical_reads, CAST(fs.total_physical_reads AS bigint) AS physical_reads,
  CAST(fs.total_logical_writes AS bigint) AS logical_writes,
  {{figures}}
FROM {{view}} fs
WHERE fs.database_id <> 32767
ORDER BY fs.total_worker_time DESC, fs.plan_handle`

// funcStatsQuery fills funcStatsSQL for one view: with the names or without them, each figure the view's own column
// where have (sys.all_columns' names for that view) lists it.
func funcStatsQuery(kind, view string, names bool, have map[string]bool) string {
	schema, object := "NULL", "NULL"
	if names {
		schema, object = "OBJECT_SCHEMA_NAME(fs.object_id, fs.database_id)", "OBJECT_NAME(fs.object_id, fs.database_id)"
	}
	figures := make([]string, 0, len(funcStatsFigures))
	for _, c := range funcStatsFigures {
		if have[c.col] {
			figures = append(figures, "CAST(fs."+c.col+" AS bigint) AS "+c.key)
		} else {
			figures = append(figures, procSpillsNone+" AS "+c.key)
		}
	}
	return strings.NewReplacer("{{top}}", fmt.Sprint(funcStatsCap+1), "{{kind}}", kind, "{{view}}", view, "{{schema}}", schema,
		"{{object}}", object, "{{figures}}", strings.Join(figures, ", ")).Replace(funcStatsSQL)
}

// serverTriggersSQL: the server's own DDL and logon triggers.
const serverTriggersSQL = `SELECT CAST(object_id AS bigint) AS object_id, CAST(name AS nvarchar(128)) AS name FROM sys.server_triggers`

// funcStatsDatabasesSQL: the online databases the login can enter, with the name as the server quotes it.
const funcStatsDatabasesSQL = `SELECT CAST(d.database_id AS int) AS database_id, QUOTENAME(d.name) AS quoted_name
FROM sys.databases d
WHERE d.state = 0 AND HAS_DBACCESS(d.name) = 1`

// databaseTriggersSQL: one database's own DDL triggers (%s: its quoted name).
const databaseTriggersSQL = `SELECT CAST(object_id AS bigint) AS object_id, CAST(name AS nvarchar(128)) AS name FROM %s.sys.triggers WHERE parent_class = 0`

// unnamedTriggerDatabases lists, in order, the databases that hold a trigger row without a name which is not one of
// the server's own triggers (server: sys.server_triggers by object id): the ones whose sys.triggers is worth asking.
func unnamedTriggerDatabases(rows []collect.Row, server map[int64]string) []int64 {
	seen := map[int64]bool{}
	var ids []int64
	for _, r := range rows {
		if r["kind"] != "trigger" || r["object_name"] != nil {
			continue
		}
		db, _ := r["database_id"].(int64)
		id, _ := r["object_id"].(int64)
		if _, ok := server[id]; ok && db == 1 {
			continue
		}
		if !seen[db] {
			seen[db] = true
			ids = append(ids, db)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

// nameTriggers gives each trigger row without a name the one its catalog holds: a server's DDL or logon trigger
// (listed under database id 1) from server, a database's DDL trigger from byDB (database id, then object id). A row
// with a name, a function's row and a trigger neither catalog lists stay as they are.
func nameTriggers(rows []collect.Row, server map[int64]string, byDB map[int64]map[int64]string) {
	for _, r := range rows {
		if r["kind"] != "trigger" || r["object_name"] != nil {
			continue
		}
		db, _ := r["database_id"].(int64)
		id, _ := r["object_id"].(int64)
		if name, ok := server[id]; ok && db == 1 {
			r["object_name"], r["trigger_scope"] = name, "server"
			continue
		}
		if name, ok := byDB[db][id]; ok {
			r["object_name"], r["trigger_scope"] = name, "database"
		}
	}
}

// funcInlineEvery is how often one database's scalar functions are asked for their inlineability: it follows the
// definition's constructs and the INLINE clause, so it changes only with the definition.
const funcInlineEvery = time.Hour

// funcInlineSent remembers, per server and database, when this process last read sys.sql_modules there.
var funcInlineSent = &sentMemo{at: map[string]time.Time{}, every: funcInlineEvery}

// funcInlineSQL: one database's scalar functions as sys.sql_modules holds them (%s: the database's quoted name).
// is_inlineable and inline_type arrived with SQL Server 2019 (Microsoft Learn, sys.sql_modules).
const funcInlineSQL = `SELECT CAST(m.object_id AS bigint) AS object_id, CAST(m.is_inlineable AS int) AS is_inlineable,
  CAST(m.inline_type AS int) AS inline_type
FROM %[1]s.sys.sql_modules m JOIN %[1]s.sys.objects o ON o.object_id = m.object_id
WHERE o.type = 'FN'`

// inlineDatabases lists, in order, the databases that hold a listed scalar function.
func inlineDatabases(rows []collect.Row) []int64 {
	seen := map[int64]bool{}
	var ids []int64
	for _, r := range rows {
		if r["kind"] != "function" {
			continue
		}
		if db, ok := r["database_id"].(int64); ok && !seen[db] {
			seen[db] = true
			ids = append(ids, db)
		}
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return ids
}

// inlineRows turns one database's sys.sql_modules answer into the payload's rows: an 'inline_read' row (the import
// replaces that database's rows) and one 'inline' row per function, the two flags as booleans.
func inlineRows(db int64, read []collect.Row) []collect.Row {
	out := []collect.Row{{"kind": "inline_read", "database_id": db}}
	for _, r := range read {
		id, ok := r["object_id"].(int64)
		if !ok {
			continue
		}
		flag := func(k string) any {
			if v, ok := r[k].(int64); ok {
				return v == 1
			}
			return nil
		}
		out = append(out, collect.Row{"kind": "inline", "database_id": db, "object_id": id, "is_inlineable": flag("is_inlineable"), "inline_type": flag("inline_type")})
	}
	return out
}

// funcInline reads the inlineability of the scalar functions the read listed, at most hourly a database, on SQL
// Server 2019 and later (and Managed Instance): a database that cannot be read costs a note and keeps what the
// store holds of it, never the run.
func funcInline(ctx context.Context, conn *sql.Conn, info Info, rows []collect.Row, now time.Time) []collect.Row {
	if info.Major < 15 && info.Kind != KindAzureMI {
		return nil
	}
	ids := inlineDatabases(rows)
	if len(ids) == 0 {
		return nil
	}
	quoted := map[int64]string{}
	dbs, err := QueryRows(ctx, conn, funcStatsDatabasesSQL)
	if err != nil {
		return []collect.Row{{"kind": "collector_error", "source": "sys.databases", "message": "the databases were not listed for their functions' inlineability (" + err.Error() + ")"}}
	}
	for _, d := range dbs {
		id, _ := d["database_id"].(int64)
		if q, _ := d["quoted_name"].(string); q != "" {
			quoted[id] = q
		}
	}
	out := inlineUnasked(rows, ids, quoted)
	asked := 0
	for _, id := range ids {
		key := fmt.Sprintf("%s|%d", info.ServerName, id)
		q, ok := quoted[id]
		if !ok || !funcInlineSent.due(key, now) || asked >= funcTriggerNameDBs {
			continue
		}
		asked++
		read, err := QueryRows(ctx, conn, fmt.Sprintf(funcInlineSQL, q))
		if err != nil {
			out = append(out, collect.Row{"kind": "collector_error", "source": "sys.sql_modules",
				"message": "the inlineability of the scalar functions of database " + q + " was not read (" + err.Error() + "): the page says 'not read' for them"})
			continue
		}
		funcInlineSent.mark(key, now)
		out = append(out, inlineRows(id, read)...)
	}
	return out
}

// inlineUnasked names, in one note, the databases whose functions ran but which the databases' list did not offer
// (quoted: online and the login can enter them): their functions' marks read 'not read', and the note says where.
func inlineUnasked(rows []collect.Row, ids []int64, quoted map[int64]string) []collect.Row {
	return nil
}

// idNames reads an object id and name list into a map.
func idNames(ctx context.Context, conn *sql.Conn, query string) (map[int64]string, error) {
	rows, err := QueryRows(ctx, conn, query)
	if err != nil {
		return nil, err
	}
	out := make(map[int64]string, len(rows))
	for _, r := range rows {
		id, ok := r["object_id"].(int64)
		name, _ := r["name"].(string)
		if ok && name != "" {
			out[id] = name
		}
	}
	return out, nil
}

// triggerCatalogNames names the DDL and logon triggers among rows from sys.server_triggers and each database's
// sys.triggers. A catalog that cannot be read costs only its names: the counters are stored with the object ids,
// and the note says which read failed.
func triggerCatalogNames(ctx context.Context, conn *sql.Conn, rows []collect.Row) []collect.Row {
	var notes []collect.Row
	note := func(source, msg string) {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": source, "message": msg})
	}
	server, err := idNames(ctx, conn, serverTriggersSQL)
	if err != nil {
		note("sys.server_triggers", "the server's DDL and logon triggers' names were not read ("+err.Error()+"): their counters are stored with the object ids")
		server = map[int64]string{}
	}
	byDB := map[int64]map[int64]string{}
	if ids := unnamedTriggerDatabases(rows, server); len(ids) > 0 {
		quoted := map[int64]string{}
		dbs, err := QueryRows(ctx, conn, funcStatsDatabasesSQL)
		if err != nil {
			note("sys.databases", "the databases were not listed for their DDL triggers' names ("+err.Error()+"): those counters are stored with the object ids")
		}
		for _, d := range dbs {
			id, _ := d["database_id"].(int64)
			if q, _ := d["quoted_name"].(string); q != "" {
				quoted[id] = q
			}
		}
		if len(ids) > funcTriggerNameDBs {
			note("sys.triggers", fmt.Sprintf("%d databases hold a trigger without a name: the first %d were asked for their DDL triggers' names", len(ids), funcTriggerNameDBs))
			ids = ids[:funcTriggerNameDBs]
		}
		for _, id := range ids {
			q, ok := quoted[id]
			if !ok {
				continue // offline, gone, or the login cannot enter it: its triggers keep their ids
			}
			names, err := idNames(ctx, conn, fmt.Sprintf(databaseTriggersSQL, q))
			if err != nil {
				note("sys.triggers", "the DDL triggers' names of database "+q+" were not read ("+err.Error()+"): their counters are stored with the object ids")
				continue
			}
			byDB[id] = names
		}
	}
	nameTriggers(rows, server, byDB)
	return notes
}

func (funcStatsCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	const what = "sys.dm_exec_function_stats and sys.dm_exec_trigger_stats"
	if err := perfState(ctx, conn, info, what); err != nil {
		return nil, err
	}
	// the clock first: a plan cached after this read of it is in this read's rows or in the next one's, never lost
	out, err := QueryRows(ctx, conn, procStateSQL)
	if err != nil {
		return nil, err
	}
	var all, notes []collect.Row
	capped := false
	kinds := []string{} // the views this read held: the import leaves a kind it did not hold as it was
	for _, v := range funcStatsViews {
		have, err := columnSet(ctx, conn, fmt.Sprintf(funcStatsColsSQL, v.view))
		if err != nil {
			return nil, err
		}
		if len(have) == 0 {
			notes = append(notes, collect.Row{"kind": "collector_error", "source": v.view,
				"message": "this server has no " + v.view + ": no " + v.kind + " is read"})
			continue
		}
		named := true
		rows, err := QueryRows(ctx, conn, funcStatsQuery(v.kind, v.view, true, have))
		if err != nil {
			// only a lock the name functions waited for: any other failure is the read's own, and fails the run
			if !isLockTimeout(err) {
				return nil, err
			}
			nameErr := err
			named = false
			if rows, err = QueryRows(ctx, conn, funcStatsQuery(v.kind, v.view, false, have)); err != nil {
				return nil, err
			}
			notes = append(notes, collect.Row{"kind": "collector_error", "source": "OBJECT_NAME",
				"message": "the " + v.kind + "s' names were not read this time (a schema change held a lock: " + nameErr.Error() + "): the counters are stored with the object ids"})
		}
		if len(rows) > funcStatsCap {
			rows = rows[:funcStatsCap]
			capped = true
			notes = append(notes, collect.Row{"kind": "collector_error", "source": v.view,
				"message": fmt.Sprintf("the plan cache holds more than %d %s plans: the %d with the most CPU are stored", funcStatsCap, v.kind, funcStatsCap)})
		}
		if named && v.kind == "trigger" {
			notes = append(notes, triggerCatalogNames(ctx, conn, rows)...)
		}
		if n := unnamed(rows); named && n > 0 {
			notes = append(notes, collect.Row{"kind": "collector_error", "source": "OBJECT_NAME",
				"message": fmt.Sprintf("%d of %d %s plans are stored without a name: the login cannot enter their database (CONNECT ANY DATABASE, or a user there), lacks VIEW ANY DEFINITION, or the object is gone", n, len(rows), v.kind)})
		}
		all = append(all, rows...)
		kinds = append(kinds, v.kind)
	}
	// one flag for both kinds: a cut read of either makes the import fall back on the cached time for both
	for _, s := range out {
		s["capped"], s["kinds"] = capped, kinds
	}
	out = append(out, all...)
	out = append(out, funcInline(ctx, conn, info, all, time.Now())...)
	return append(out, notes...), nil
}
