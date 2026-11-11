package mssql

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/aachaemenes/pgvigil/internal/collect"
)

// planCacheCollector is mssql_plancache: what each cached statement did, every five minutes, from
// sys.dm_exec_query_stats: the executions, the CPU, the duration, the logical and physical reads, the writes, the
// rows, the spills, and the largest memory grant and degree of parallelism. It is the statement history of a
// database that has no Query Store; a database whose Query Store is on is read too (the server's plan cache is one
// list) and its row says so.
//
// The view has one row per statement of a cached plan and counts since the plan was compiled, so the collector sends
// the counters as they are, one row per statement and plan (the plan's handle, the statement's offsets and its
// compile time), and the import stores what the interval added, summed per database and query hash (0092: a
// statement the read before did not hold, or one whose counters went down, gives its whole count; nothing is ever
// negative). A statement compiled, run and evicted between two reads is not seen at all, and what a plan ran after
// the read before is lost with it when the cache drops it: on a server whose cache turns over fast the figures are
// a floor, and the plan cache health read (below) says how fast it turns over.
//
// Not every cached statement leaves the server: the candidate set is the first planCacheTopN by CPU, by duration,
// by logical reads and by executions, and the first planCacheTopN with a memory grant or a spill by those. A cache
// that holds more says so in the state row (capped) and the run is partial; after a cut read a statement new to the
// set gives its whole count only when it was compiled at or after that read's clock, else it only sets its counters
// (it may have been past the cut).
//
// The database is the one the plan was compiled in (sys.dm_exec_plan_attributes' dbid); the resource database's
// own statements (32767) are left out. The text is read apart, by the statement's handle and offsets, for at most
// planCacheTextsPerRun statements a run whose text this process has not sent in the last planCacheTextEvery: the
// repository keeps one text per query hash, so a statement's text travels once, not every five minutes. The text
// follows the instance's query-text policy before it is stored (none: no text). OBJECT_NAME waits behind a schema
// change on the object; the session gives up on a lock after two seconds and the texts are then read without the
// module's name.
//
// The server's clock is read BEFORE the counters, as mssql_procstats reads it.
//
// Rights as mssql_cpu (perfApplies). Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed
// Instance; the grant, parallelism and spill columns are read where the server has them (sys.all_columns is asked:
// spills arrived with 2016 SP2 and 2017 CU3). Not on Azure SQL Database. Nothing is written on the server.
type planCacheCollector struct{}

func init() {
	Register(planCacheCollector{})
	Register(planCacheHealthCollector{})
}

func (planCacheCollector) Name() string                   { return Prefix + "plancache" }
func (planCacheCollector) DefaultInterval() time.Duration { return 5 * time.Minute }
func (planCacheCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not yet on Azure SQL Database (the database's own plan cache is a later wave)"
	}
	return perfApplies(info, "sys.dm_exec_query_stats")
}

const (
	// planCacheTopN is how many statements each of the candidate set's lists keeps.
	planCacheTopN = 500
	// planCacheTextsPerRun bounds the statement texts one run reads; planCacheTextEvery is how long a text this
	// process sent is not sent again; planCacheTextMax is the most characters of one text.
	planCacheTextsPerRun = 200
	planCacheTextEvery   = 6 * time.Hour
	planCacheTextMax     = 8000
)

// planCacheColsSQL: the columns this server's sys.dm_exec_query_stats has.
const planCacheColsSQL = `SELECT CAST(name AS nvarchar(128)) AS name FROM sys.all_columns WHERE object_id = OBJECT_ID(N'sys.dm_exec_query_stats')`

// planCacheDatabasesSQL: every database with its Query Store switch, for the page's scope 'databases without Query
// Store'. A database that is not ONLINE has no switch to read.
const planCacheDatabasesSQL = `SELECT 'database' AS kind, CAST(d.database_id AS int) AS database_id, CAST(d.name AS nvarchar(128)) AS database_name,
  CAST(d.is_query_store_on AS int) AS query_store_on, CAST(d.state_desc AS nvarchar(60)) AS database_state
FROM sys.databases d`

// planCacheSQL: the candidate set, the most CPU first. {{grant}}, {{used}}, {{spills}} and {{dop}} are the columns
// newer servers have, or 0. The handles and hashes ride as 0x text (QueryRows); creation_time is the server's own
// clock without a zone, as the DMV writes it.
const planCacheSQL = `WITH s AS (
  SELECT qs.plan_handle, qs.sql_handle, qs.statement_start_offset, qs.statement_end_offset, qs.creation_time,
         qs.query_hash, qs.query_plan_hash, qs.execution_count, qs.total_worker_time, qs.total_elapsed_time,
         qs.total_logical_reads, qs.total_physical_reads, qs.total_logical_writes, qs.total_rows,
         {{grant}} AS max_grant_kb, {{used}} AS max_used_grant_kb, {{spills}} AS total_spills, {{dop}} AS max_dop,
         ROW_NUMBER() OVER (ORDER BY qs.total_worker_time DESC, qs.plan_handle, qs.statement_start_offset) AS rn_cpu,
         ROW_NUMBER() OVER (ORDER BY qs.total_elapsed_time DESC, qs.plan_handle, qs.statement_start_offset) AS rn_duration,
         ROW_NUMBER() OVER (ORDER BY qs.total_logical_reads DESC, qs.plan_handle, qs.statement_start_offset) AS rn_reads,
         ROW_NUMBER() OVER (ORDER BY qs.execution_count DESC, qs.plan_handle, qs.statement_start_offset) AS rn_executions,
         ROW_NUMBER() OVER (ORDER BY {{grant}} DESC, qs.plan_handle, qs.statement_start_offset) AS rn_grant,
         ROW_NUMBER() OVER (ORDER BY {{spills}} DESC, qs.plan_handle, qs.statement_start_offset) AS rn_spills,
         COUNT_BIG(*) OVER () AS cached
    FROM sys.dm_exec_query_stats qs
)
SELECT 'stmt' AS kind, s.plan_handle AS plan_handle, s.sql_handle AS sql_handle,
  CAST(s.statement_start_offset AS int) AS stmt_start, CAST(s.statement_end_offset AS int) AS stmt_end, s.creation_time AS creation_time,
  s.query_hash AS query_hash, s.query_plan_hash AS plan_hash,
  CAST(pa.dbid AS int) AS database_id, CAST(DB_NAME(pa.dbid) AS nvarchar(128)) AS database_name,
  CAST(s.execution_count AS bigint) AS execution_count, CAST(s.total_worker_time AS bigint) AS worker_us,
  CAST(s.total_elapsed_time AS bigint) AS elapsed_us, CAST(s.total_logical_reads AS bigint) AS logical_reads,
  CAST(s.total_physical_reads AS bigint) AS physical_reads, CAST(s.total_logical_writes AS bigint) AS logical_writes,
  CAST(s.total_rows AS bigint) AS row_count, CAST(s.total_spills AS bigint) AS spills,
  CAST(s.max_grant_kb AS bigint) AS max_grant_kb, CAST(s.max_used_grant_kb AS bigint) AS max_used_grant_kb, CAST(s.max_dop AS bigint) AS max_dop,
  CAST(s.cached AS bigint) AS cached
FROM s
OUTER APPLY (SELECT TOP (1) CAST(a.value AS int) AS dbid FROM sys.dm_exec_plan_attributes(s.plan_handle) a WHERE a.attribute = N'dbid') pa
WHERE (s.rn_cpu <= @top OR s.rn_duration <= @top OR s.rn_reads <= @top OR s.rn_executions <= @top
       OR (s.rn_grant <= @top AND s.max_grant_kb > 0) OR (s.rn_spills <= @top AND s.total_spills > 0))
  AND ISNULL(pa.dbid, 0) <> 32767
ORDER BY s.rn_cpu`

// planCacheQuery fills planCacheSQL with the optional columns the server has (have: sys.all_columns' names).
func planCacheQuery(have map[string]bool) string {
	col := func(name string) string {
		if have[name] {
			return "ISNULL(qs." + name + ", 0)"
		}
		// a subquery, not a bare constant: a window's ORDER BY refuses a constant expression
		return "(SELECT CAST(0 AS bigint))"
	}
	return strings.NewReplacer("{{grant}}", col("max_grant_kb"), "{{used}}", col("max_used_grant_kb"),
		"{{spills}}", col("total_spills"), "{{dop}}", col("max_dop")).Replace(planCacheSQL)
}

// planCacheTextSQL reads the text of the named statements. The first %s is the VALUES list (planCacheTextValues),
// {{object}} the module's name or NULL (the second run, after a lock the name functions waited for).
const planCacheTextSQL = `SELECT 'text' AS kind, v.h AS sql_handle, CAST(v.s AS int) AS stmt_start, CAST(v.e AS int) AS stmt_end,
  CAST({{object}} AS nvarchar(300)) AS object_name,
  CAST(LEFT(SUBSTRING(t.text, v.s / 2 + 1, (CASE WHEN v.e = -1 THEN DATALENGTH(t.text) ELSE v.e END - v.s) / 2 + 1), {{max}}) AS nvarchar(max)) AS query
FROM (VALUES %s) v(h, s, e)
CROSS APPLY sys.dm_exec_sql_text(v.h) t
WHERE t.text IS NOT NULL`

const planCacheObjectExpr = `CASE WHEN t.objectid IS NOT NULL THEN ISNULL(OBJECT_SCHEMA_NAME(t.objectid, t.dbid) + N'.', N'') + OBJECT_NAME(t.objectid, t.dbid) END`

// planCacheTextQuery fills planCacheTextSQL: with the module's name, or without it.
func planCacheTextQuery(values string, names bool) string {
	object := "NULL"
	if names {
		object = planCacheObjectExpr
	}
	return fmt.Sprintf(strings.NewReplacer("{{object}}", object, "{{max}}", fmt.Sprint(planCacheTextMax)).Replace(planCacheTextSQL), values)
}

// hexHandle is a handle or a hash as QueryRows writes it: 0x and upper-case hex. Only such a value is ever put
// into a statement's text.
var hexHandle = regexp.MustCompile(`^0x[0-9A-F]{2,256}$`)

// zeroHash is a query hash the server did not compute (a cursor fetch, some DDL).
var zeroHash = regexp.MustCompile(`^0x0+$`)

// planCacheKey is what a statement's samples are summed under: its query hash, or for a statement the server gave
// no hash its handle and start offset.
func planCacheKey(r collect.Row) string {
	h, _ := r["query_hash"].(string)
	if h != "" && !zeroHash.MatchString(h) {
		return h
	}
	sh, _ := r["sql_handle"].(string)
	start, _ := r["stmt_start"].(int64)
	return fmt.Sprintf("%s:%d", sh, start)
}

// planCacheTexts remembers which statement texts this process sent, per server: the repository keeps one text per
// query key, so a text travels once in planCacheTextEvery, not with every read.
type planCacheTexts struct {
	mu   sync.Mutex
	sent map[string]time.Time
}

var planCacheSent = &planCacheTexts{sent: map[string]time.Time{}}

// pick returns the statements whose text this run reads: per query key the first row in the rows' order (the most
// CPU first), max keys at most, none whose text was sent less than planCacheTextEvery ago. It marks what it
// picked; unpick takes the marks back when the read failed.
func (t *planCacheTexts) pick(server string, rows []collect.Row, now time.Time, max int) []collect.Row {
	t.mu.Lock()
	defer t.mu.Unlock()
	for k, at := range t.sent {
		if now.Sub(at) >= planCacheTextEvery {
			delete(t.sent, k)
		}
	}
	var out []collect.Row
	for _, r := range rows {
		if len(out) >= max {
			break
		}
		key, _ := r["query_key"].(string)
		sh, _ := r["sql_handle"].(string)
		if key == "" || !hexHandle.MatchString(sh) {
			continue
		}
		id := server + "|" + key
		if _, done := t.sent[id]; done {
			continue
		}
		t.sent[id] = now
		out = append(out, r)
	}
	return out
}

func (t *planCacheTexts) unpick(server string, rows []collect.Row) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for _, r := range rows {
		key, _ := r["query_key"].(string)
		delete(t.sent, server+"|"+key)
	}
}

// planCacheTextValues writes the VALUES rows of planCacheTextSQL: (handle, start offset, end offset), the handle
// as the 0x literal the server itself returned.
func planCacheTextValues(rows []collect.Row) string {
	parts := make([]string, 0, len(rows))
	for _, r := range rows {
		sh, _ := r["sql_handle"].(string)
		if !hexHandle.MatchString(sh) {
			continue
		}
		start, _ := r["stmt_start"].(int64)
		end, _ := r["stmt_end"].(int64)
		parts = append(parts, fmt.Sprintf("(%s, %d, %d)", sh, start, end))
	}
	return strings.Join(parts, ", ")
}

// planCacheTextRows turns the text read into the payload's 'text' rows: each carries the query key and the
// database of the statement it was read for.
func planCacheTextRows(picked, texts []collect.Row) []collect.Row {
	type at struct {
		h    string
		s, e int64
	}
	by := map[at]collect.Row{}
	for _, p := range picked {
		sh, _ := p["sql_handle"].(string)
		start, _ := p["stmt_start"].(int64)
		end, _ := p["stmt_end"].(int64)
		by[at{sh, start, end}] = p
	}
	out := make([]collect.Row, 0, len(texts))
	for _, t := range texts {
		sh, _ := t["sql_handle"].(string)
		start, _ := t["stmt_start"].(int64)
		end, _ := t["stmt_end"].(int64)
		p, ok := by[at{sh, start, end}]
		if !ok || t["query"] == nil {
			continue
		}
		out = append(out, collect.Row{"kind": "text", "query_key": p["query_key"], "database_id": p["database_id"],
			"object_name": t["object_name"], "query": t["query"]})
	}
	return out
}

// columnSet reads the names a statement returns in its 'name' column into a set.
func columnSet(ctx context.Context, conn *sql.Conn, query string) (map[string]bool, error) {
	rows, err := QueryRows(ctx, conn, query)
	if err != nil {
		return nil, err
	}
	have := make(map[string]bool, len(rows))
	for _, r := range rows {
		if n, _ := r["name"].(string); n != "" {
			have[n] = true
		}
	}
	return have, nil
}

func (planCacheCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_exec_query_stats"); err != nil {
		return nil, err
	}
	have, err := columnSet(ctx, conn, planCacheColsSQL)
	if err != nil {
		return nil, err
	}
	// the clock first: a plan compiled after this read of it is in this read's rows or in the next one's, never lost
	out, err := QueryRows(ctx, conn, procStateSQL)
	if err != nil {
		return nil, err
	}
	dbs, err := QueryRows(ctx, conn, planCacheDatabasesSQL)
	if err != nil {
		return nil, err
	}
	stmts, err := QueryRows(ctx, conn, planCacheQuery(have), sql.Named("top", planCacheTopN))
	if err != nil {
		return nil, err
	}
	var notes []collect.Row
	cached := int64(len(stmts))
	for _, s := range stmts {
		if n, _ := s["cached"].(int64); n > cached {
			cached = n
		}
		delete(s, "cached")
		s["query_key"] = planCacheKey(s)
	}
	// cut: the cache holds more statements than one list keeps and not all of them left the server. (The resource
	// database's own statements are counted in the cache and never sent: on a cache just over the list's size that
	// alone reads as a cut, which only makes the import careful, never wrong.)
	capped := cached > planCacheTopN && cached > int64(len(stmts))
	for _, s := range out {
		s["capped"], s["cached"] = capped, cached
	}
	if capped {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_exec_query_stats",
			"message": fmt.Sprintf("the plan cache holds %d statements: the %d in the first %d by CPU, duration, reads, executions, grant or spills are stored", cached, len(stmts), planCacheTopN)})
	}
	picked := planCacheSent.pick(info.ServerName, stmts, time.Now(), planCacheTextsPerRun)
	if len(picked) > 0 {
		texts, err := QueryRows(ctx, conn, planCacheTextQuery(planCacheTextValues(picked), true))
		if err != nil && isLockTimeout(err) {
			nameErr := err
			texts, err = QueryRows(ctx, conn, planCacheTextQuery(planCacheTextValues(picked), false))
			if err == nil {
				notes = append(notes, collect.Row{"kind": "collector_error", "source": "OBJECT_NAME",
					"message": "the modules' names were not read this time (a schema change held a lock: " + nameErr.Error() + "): the texts are stored without them"})
			}
		}
		if err != nil {
			// the counters are whole without the texts: they are stored, and the texts are asked for again next time
			planCacheSent.unpick(info.ServerName, picked)
			notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_exec_sql_text", "message": "the statement texts were not read: " + err.Error()})
		} else {
			out = append(out, planCacheTextRows(picked, texts)...)
		}
	}
	out = append(out, dbs...)
	out = append(out, stmts...)
	return append(out, notes...), nil
}

// planCacheHealthCollector is mssql_plancache_health: what the plan cache holds, hourly, per database.
//
//   - sys.dm_exec_cached_plans (compiled plans only): the plans and their size; the single-use plans (ad hoc and
//     prepared plans used once) and their size; the plans by kind.
//   - sys.dm_exec_query_stats: the cached statements; how many were compiled in the last 24 hours, 4 hours and hour
//     and when the oldest was; the statements whose query hash has more than one cached plan in the database (the
//     same statement compiled again and again, most often because its literals are not parameters).
//   - two lists: the planCacheListN largest single-use plans with the start of their text, and the planCacheListN
//     query hashes with the most cached plans with one statement of each.
//
// The database is the one the plan was compiled in (sys.dm_exec_plan_attributes' dbid); the resource database
// (32767) is left out. Both views are read whole on the server and only the sums and the two lists leave it. The
// texts follow the instance's query-text policy.
//
// Rights as mssql_cpu (perfApplies). Runs on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed
// Instance; not on Azure SQL Database. Nothing is written on the server.
type planCacheHealthCollector struct{}

func (planCacheHealthCollector) Name() string                   { return Prefix + "plancache_health" }
func (planCacheHealthCollector) DefaultInterval() time.Duration { return time.Hour }

// Timeout: three passes over the plan cache, each asking sys.dm_exec_plan_attributes per plan.
func (planCacheHealthCollector) Timeout() time.Duration { return 3 * time.Minute }

func (planCacheHealthCollector) Applies(info Info) (bool, string) {
	if info.Kind == KindAzureDB {
		return false, "not yet on Azure SQL Database (the database's own plan cache is a later wave)"
	}
	return perfApplies(info, "sys.dm_exec_cached_plans")
}

// planCacheListN is how many rows each of the two lists keeps; planCacheListText the characters of a list's text.
const (
	planCacheListN    = 50
	planCacheListText = 4000
)

// planCacheDBIDApply names the database a plan was compiled in. %s: the plan handle's column.
const planCacheDBIDApply = `CROSS APPLY (SELECT TOP (1) CAST(a.value AS int) AS dbid FROM sys.dm_exec_plan_attributes(%s) a WHERE a.attribute = N'dbid') pa`

// planCachePlansSQL: the compiled plans per database.
var planCachePlansSQL = `SELECT 'plans' AS kind, CAST(pa.dbid AS int) AS database_id, CAST(DB_NAME(pa.dbid) AS nvarchar(128)) AS database_name,
  COUNT_BIG(*) AS plans, SUM(CAST(cp.size_in_bytes AS bigint)) AS plan_bytes,
  SUM(CASE WHEN cp.usecounts = 1 AND cp.objtype IN (N'Adhoc', N'Prepared') THEN CAST(1 AS bigint) ELSE 0 END) AS single_use,
  SUM(CASE WHEN cp.usecounts = 1 AND cp.objtype IN (N'Adhoc', N'Prepared') THEN CAST(cp.size_in_bytes AS bigint) ELSE 0 END) AS single_use_bytes,
  SUM(CASE WHEN cp.objtype = N'Adhoc' THEN CAST(1 AS bigint) ELSE 0 END) AS adhoc_plans,
  SUM(CASE WHEN cp.objtype = N'Prepared' THEN CAST(1 AS bigint) ELSE 0 END) AS prepared_plans,
  SUM(CASE WHEN cp.objtype = N'Proc' THEN CAST(1 AS bigint) ELSE 0 END) AS proc_plans
FROM sys.dm_exec_cached_plans cp
` + fmt.Sprintf(planCacheDBIDApply, "cp.plan_handle") + `
WHERE cp.cacheobjtype = N'Compiled Plan' AND pa.dbid <> 32767
GROUP BY pa.dbid`

// planCacheStatementsSQL: the cached statements per database: how recently they were compiled, and how many belong
// to a query hash with more than one cached plan. oldest_compile is moved to UTC by the server's offset now.
var planCacheStatementsSQL = `WITH q AS (
  SELECT pa.dbid, qs.query_hash, qs.plan_handle, qs.creation_time
    FROM sys.dm_exec_query_stats qs
    ` + fmt.Sprintf(planCacheDBIDApply, "qs.plan_handle") + `
   WHERE pa.dbid <> 32767
), h AS (
  SELECT q.dbid, q.query_hash, COUNT(DISTINCT q.plan_handle) AS plans, COUNT_BIG(*) AS statements
    FROM q WHERE q.query_hash <> 0x0000000000000000
   GROUP BY q.dbid, q.query_hash
), d AS (
  SELECT h.dbid, SUM(CASE WHEN h.plans > 1 THEN h.statements ELSE 0 END) AS duplicate_statements,
         SUM(CASE WHEN h.plans > 1 THEN CAST(1 AS bigint) ELSE 0 END) AS duplicate_hashes
    FROM h GROUP BY h.dbid
), c AS (
  SELECT q.dbid, COUNT_BIG(*) AS statements,
         SUM(CASE WHEN q.creation_time >= DATEADD(hour, -24, GETDATE()) THEN CAST(1 AS bigint) ELSE 0 END) AS compiled_24h,
         SUM(CASE WHEN q.creation_time >= DATEADD(hour, -4, GETDATE()) THEN CAST(1 AS bigint) ELSE 0 END) AS compiled_4h,
         SUM(CASE WHEN q.creation_time >= DATEADD(hour, -1, GETDATE()) THEN CAST(1 AS bigint) ELSE 0 END) AS compiled_1h,
         MIN(q.creation_time) AS oldest
    FROM q GROUP BY q.dbid
)
SELECT 'statements' AS kind, CAST(c.dbid AS int) AS database_id, CAST(DB_NAME(c.dbid) AS nvarchar(128)) AS database_name,
  CAST(c.statements AS bigint) AS statements, CAST(c.compiled_24h AS bigint) AS compiled_24h, CAST(c.compiled_4h AS bigint) AS compiled_4h,
  CAST(c.compiled_1h AS bigint) AS compiled_1h,
  TODATETIMEOFFSET(DATEADD(minute, -DATEPART(TZOFFSET, SYSDATETIMEOFFSET()), c.oldest), 0) AS oldest_compile,
  CAST(ISNULL(d.duplicate_statements, 0) AS bigint) AS duplicate_statements, CAST(ISNULL(d.duplicate_hashes, 0) AS bigint) AS duplicate_hashes
FROM c LEFT JOIN d ON d.dbid = c.dbid`

// planCacheSingleUseSQL: the largest single-use plans.
var planCacheSingleUseSQL = `SELECT TOP (@top) 'single_use' AS kind, CAST(pa.dbid AS int) AS database_id, CAST(DB_NAME(pa.dbid) AS nvarchar(128)) AS database_name,
  CAST(cp.objtype AS nvarchar(20)) AS plan_kind, CAST(cp.size_in_bytes AS bigint) AS size_bytes,
  CAST(LEFT(t.text, ` + fmt.Sprint(planCacheListText) + `) AS nvarchar(max)) AS query
FROM sys.dm_exec_cached_plans cp
` + fmt.Sprintf(planCacheDBIDApply, "cp.plan_handle") + `
OUTER APPLY sys.dm_exec_sql_text(cp.plan_handle) t
WHERE cp.cacheobjtype = N'Compiled Plan' AND cp.usecounts = 1 AND cp.objtype IN (N'Adhoc', N'Prepared') AND pa.dbid <> 32767
ORDER BY cp.size_in_bytes DESC, cp.plan_handle`

// planCacheDuplicatesSQL: the query hashes with the most cached plans, each with its most executed statement's text.
var planCacheDuplicatesSQL = `WITH q AS (
  SELECT pa.dbid, qs.query_hash, qs.plan_handle, qs.sql_handle, qs.statement_start_offset AS s, qs.statement_end_offset AS e, qs.execution_count,
         ROW_NUMBER() OVER (PARTITION BY pa.dbid, qs.query_hash ORDER BY qs.execution_count DESC, qs.plan_handle, qs.statement_start_offset) AS rn
    FROM sys.dm_exec_query_stats qs
    ` + fmt.Sprintf(planCacheDBIDApply, "qs.plan_handle") + `
   WHERE qs.query_hash <> 0x0000000000000000 AND pa.dbid <> 32767
), h AS (
  SELECT q.dbid, q.query_hash, COUNT(DISTINCT q.plan_handle) AS plans, COUNT_BIG(*) AS statements, SUM(q.execution_count) AS executions
    FROM q GROUP BY q.dbid, q.query_hash HAVING COUNT(DISTINCT q.plan_handle) > 1
)
SELECT TOP (@top) 'duplicate' AS kind, CAST(h.dbid AS int) AS database_id, CAST(DB_NAME(h.dbid) AS nvarchar(128)) AS database_name,
  h.query_hash AS query_hash, CAST(h.plans AS bigint) AS plans, CAST(h.statements AS bigint) AS statements, CAST(h.executions AS bigint) AS executions,
  CAST(LEFT(SUBSTRING(t.text, q.s / 2 + 1, (CASE WHEN q.e = -1 THEN DATALENGTH(t.text) ELSE q.e END - q.s) / 2 + 1), ` + fmt.Sprint(planCacheListText) + `) AS nvarchar(max)) AS query
FROM h JOIN q ON q.dbid = h.dbid AND q.query_hash = h.query_hash AND q.rn = 1
OUTER APPLY sys.dm_exec_sql_text(q.sql_handle) t
ORDER BY h.plans DESC, h.executions DESC, h.query_hash`

// planCacheHealthRows joins the two per-database reads into one 'health' row per database, in the databases' order.
// A database only one of the reads listed keeps the other's figures at zero (a plan without statistics yet, or a
// statement whose plan left between the two reads).
func planCacheHealthRows(plans, statements []collect.Row) []collect.Row {
	by := map[int64]collect.Row{}
	var ids []int64
	at := func(r collect.Row) collect.Row {
		id, ok := r["database_id"].(int64)
		if !ok {
			return nil
		}
		h, known := by[id]
		if !known {
			h = collect.Row{"kind": "health", "database_id": id, "database_name": r["database_name"],
				"plans": int64(0), "plan_bytes": int64(0), "single_use": int64(0), "single_use_bytes": int64(0),
				"adhoc_plans": int64(0), "prepared_plans": int64(0), "proc_plans": int64(0),
				"statements": int64(0), "compiled_24h": int64(0), "compiled_4h": int64(0), "compiled_1h": int64(0),
				"oldest_compile": nil, "duplicate_statements": int64(0), "duplicate_hashes": int64(0)}
			by[id] = h
			ids = append(ids, id)
		}
		if h["database_name"] == nil {
			h["database_name"] = r["database_name"]
		}
		return h
	}
	for _, p := range plans {
		if h := at(p); h != nil {
			for _, k := range []string{"plans", "plan_bytes", "single_use", "single_use_bytes", "adhoc_plans", "prepared_plans", "proc_plans"} {
				h[k] = p[k]
			}
		}
	}
	for _, s := range statements {
		if h := at(s); h != nil {
			for _, k := range []string{"statements", "compiled_24h", "compiled_4h", "compiled_1h", "oldest_compile", "duplicate_statements", "duplicate_hashes"} {
				h[k] = s[k]
			}
		}
	}
	sort.Slice(ids, func(a, b int) bool { return ids[a] < ids[b] })
	out := make([]collect.Row, 0, len(ids))
	for _, id := range ids {
		out = append(out, by[id])
	}
	return out
}

func (planCacheHealthCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	if err := perfState(ctx, conn, info, "sys.dm_exec_cached_plans"); err != nil {
		return nil, err
	}
	out, err := QueryRows(ctx, conn, perfStateSQL)
	if err != nil {
		return nil, err
	}
	plans, err := QueryRows(ctx, conn, planCachePlansSQL)
	if err != nil {
		return nil, err
	}
	statements, err := QueryRows(ctx, conn, planCacheStatementsSQL)
	if err != nil {
		return nil, err
	}
	out = append(out, planCacheHealthRows(plans, statements)...)
	// the two lists are read on their own: one that fails keeps the sums
	for _, l := range []struct{ source, query string }{
		{"sys.dm_exec_cached_plans", planCacheSingleUseSQL}, {"sys.dm_exec_query_stats", planCacheDuplicatesSQL}} {
		rows, err := QueryRows(ctx, conn, l.query, sql.Named("top", planCacheListN))
		if err != nil {
			if ctx.Err() != nil {
				return nil, err
			}
			out = append(out, collect.Row{"kind": "collector_error", "source": l.source, "message": "the list was not read: " + err.Error()})
			continue
		}
		out = append(out, rows...)
	}
	return out, nil
}
