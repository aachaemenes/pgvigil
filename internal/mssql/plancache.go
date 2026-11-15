package mssql

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/xml"
	"errors"
	"fmt"
	"html"
	"regexp"
	"sort"
	"strconv"
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
// repository keeps one text per query hash, so a statement's text travels once an hour, not every five minutes (a
// text whose import failed is sent again within the hour; one under the policy 'none' replaces the stored words). The text
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
	planCacheTextEvery   = time.Hour
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
// newer servers have, or 0. The handles and hashes ride as 0x text (QueryRows; the hashes as *_hex: the text policy
// rewrites a column named query_hash); creation_time and last_execution are the server's own clock without a zone,
// as the DMV writes them; last_execution is when the last run STARTED, last_elapsed_us how long it took.
const planCacheSQL = `WITH s AS (
  SELECT qs.plan_handle, qs.sql_handle, qs.statement_start_offset, qs.statement_end_offset, qs.creation_time,
         qs.query_hash, qs.query_plan_hash, qs.execution_count, qs.total_worker_time, qs.total_elapsed_time,
         qs.total_logical_reads, qs.total_physical_reads, qs.total_logical_writes, qs.total_rows,
         qs.last_execution_time, qs.last_elapsed_time,
         {{grant}} AS max_grant_kb, {{used}} AS max_used_grant_kb, {{spills}} AS total_spills, {{dop}} AS max_dop,
         ROW_NUMBER() OVER (ORDER BY qs.total_worker_time DESC, qs.plan_handle, qs.statement_start_offset) AS rn_cpu,
         ROW_NUMBER() OVER (ORDER BY qs.total_elapsed_time DESC, qs.plan_handle, qs.statement_start_offset) AS rn_duration,
         ROW_NUMBER() OVER (ORDER BY qs.total_logical_reads DESC, qs.plan_handle, qs.statement_start_offset) AS rn_reads,
         ROW_NUMBER() OVER (ORDER BY qs.execution_count DESC, qs.plan_handle, qs.statement_start_offset) AS rn_executions,
         ROW_NUMBER() OVER (ORDER BY {{grant}} DESC, qs.plan_handle, qs.statement_start_offset) AS rn_grant,
         ROW_NUMBER() OVER (ORDER BY {{spills}} DESC, qs.plan_handle, qs.statement_start_offset) AS rn_spills,
         COUNT_BIG(*) OVER () AS cached
    FROM sys.dm_exec_query_stats qs
), k AS (
  -- the candidate set; listed counts it before the resource database's statements leave it, so the cut is judged
  -- on the lists alone
  SELECT s.*, COUNT_BIG(*) OVER () AS listed
    FROM s
   WHERE s.rn_cpu <= @top OR s.rn_duration <= @top OR s.rn_reads <= @top OR s.rn_executions <= @top
      OR (s.rn_grant <= @top AND s.max_grant_kb > 0) OR (s.rn_spills <= @top AND s.total_spills > 0)
)
SELECT 'stmt' AS kind, k.plan_handle AS plan_handle, k.sql_handle AS sql_handle,
  CAST(k.statement_start_offset AS int) AS stmt_start, CAST(k.statement_end_offset AS int) AS stmt_end, k.creation_time AS creation_time,
  k.query_hash AS query_hash_hex, k.query_plan_hash AS plan_hash_hex,
  CAST(pa.dbid AS int) AS database_id, CAST(DB_NAME(pa.dbid) AS nvarchar(128)) AS database_name,
  CAST(k.execution_count AS bigint) AS execution_count, CAST(k.total_worker_time AS bigint) AS worker_us,
  CAST(k.total_elapsed_time AS bigint) AS elapsed_us, CAST(k.total_logical_reads AS bigint) AS logical_reads,
  CAST(k.total_physical_reads AS bigint) AS physical_reads, CAST(k.total_logical_writes AS bigint) AS logical_writes,
  CAST(k.total_rows AS bigint) AS row_count, CAST(k.total_spills AS bigint) AS spills,
  CAST(k.max_grant_kb AS bigint) AS max_grant_kb, CAST(k.max_used_grant_kb AS bigint) AS max_used_grant_kb, CAST(k.max_dop AS bigint) AS max_dop,
  k.last_execution_time AS last_execution, CAST(k.last_elapsed_time AS bigint) AS last_elapsed_us,
  CAST(k.cached AS bigint) AS cached, CAST(k.listed AS bigint) AS listed
FROM k
OUTER APPLY (SELECT TOP (1) CAST(a.value AS int) AS dbid FROM sys.dm_exec_plan_attributes(k.plan_handle) a WHERE a.attribute = N'dbid') pa
WHERE ISNULL(pa.dbid, 0) <> 32767
ORDER BY k.rn_cpu`

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
	h, _ := r["query_hash_hex"].(string)
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
func (t *planCacheTexts) pick(server string, rows []collect.Row, now time.Time, limit int) []collect.Row {
	t.mu.Lock()
	defer t.mu.Unlock()
	for k, at := range t.sent {
		if now.Sub(at) >= planCacheTextEvery {
			delete(t.sent, k)
		}
	}
	var out []collect.Row
	for _, r := range rows {
		if len(out) >= limit {
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
	cached, listed := int64(len(stmts)), int64(len(stmts))
	for _, s := range stmts {
		if n, _ := s["cached"].(int64); n > cached {
			cached = n
		}
		if n, _ := s["listed"].(int64); n > listed {
			listed = n
		}
		delete(s, "cached")
		delete(s, "listed")
		s["query_key"] = planCacheKey(s)
	}
	// cut: the cache holds statements none of the lists kept. After a cut read the import counts a statement new to the
	// list whole only when it can tell it was not in that read: compiled after its clock, or run once and ended after
	// it; any other new statement only sets its counters, so a cut costs a statement's first interval, never a count twice.
	capped := cached > listed
	for _, s := range out {
		s["capped"], s["cached"] = capped, cached
	}
	if capped {
		notes = append(notes, collect.Row{"kind": "collector_error", "source": "sys.dm_exec_query_stats",
			"message": fmt.Sprintf("the plan cache holds %d statements: the %d in the first %d by CPU, duration, reads, executions, grant or spills are stored", cached, listed, planCacheTopN)})
	}
	// the memory of the texts sent is per server and run of it: two servers cloned from one image share a name
	server := info.ServerName
	if len(out) > 0 {
		server += fmt.Sprintf("|%v", out[0]["server_start"])
	}
	picked := planCacheSent.pick(server, stmts, time.Now(), planCacheTextsPerRun)
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
			planCacheSent.unpick(server, picked)
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
//     and when the oldest was; the statements whose query hash has more than one cached ad hoc or prepared plan in
//     the database (the same statement compiled again and again, most often because its literals are not
//     parameters; a statement that is in several procedures shares its hash and is not counted).
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

// Timeout: four passes over the plan cache, each asking sys.dm_exec_plan_attributes per plan.
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
// to a query hash with more than one cached ad hoc or prepared plan (the same statement compiled again for other
// literals or SET options; one statement in several procedures shares a hash and is not that). One pass over the
// view: the plans per hash come from a window (the highest DENSE_RANK of the plan handle within the hash), so the
// counts are of one read and can never disagree. oldest_compile is moved to UTC by the server's offset now.
var planCacheStatementsSQL = `WITH q AS (
  SELECT pa.dbid, qs.query_hash, qs.creation_time,
         CASE WHEN cp.objtype IN (N'Adhoc', N'Prepared') AND qs.query_hash <> 0x0000000000000000
              THEN DENSE_RANK() OVER (PARTITION BY pa.dbid, qs.query_hash, CASE WHEN cp.objtype IN (N'Adhoc', N'Prepared') THEN 1 ELSE 0 END ORDER BY qs.plan_handle) END AS plan_rank
    FROM sys.dm_exec_query_stats qs
    JOIN sys.dm_exec_cached_plans cp ON cp.plan_handle = qs.plan_handle
    ` + fmt.Sprintf(planCacheDBIDApply, "qs.plan_handle") + `
   WHERE pa.dbid <> 32767
), w AS (
  SELECT q.*, MAX(q.plan_rank) OVER (PARTITION BY q.dbid, q.query_hash) AS hash_plans FROM q
)
SELECT 'statements' AS kind, CAST(w.dbid AS int) AS database_id, CAST(DB_NAME(w.dbid) AS nvarchar(128)) AS database_name,
  COUNT_BIG(*) AS statements,
  SUM(CASE WHEN w.creation_time >= DATEADD(hour, -24, GETDATE()) THEN CAST(1 AS bigint) ELSE 0 END) AS compiled_24h,
  SUM(CASE WHEN w.creation_time >= DATEADD(hour, -4, GETDATE()) THEN CAST(1 AS bigint) ELSE 0 END) AS compiled_4h,
  SUM(CASE WHEN w.creation_time >= DATEADD(hour, -1, GETDATE()) THEN CAST(1 AS bigint) ELSE 0 END) AS compiled_1h,
  ` + utcOf("MIN(w.creation_time)") + ` AS oldest_compile,
  SUM(CASE WHEN w.plan_rank IS NOT NULL AND w.hash_plans > 1 THEN CAST(1 AS bigint) ELSE 0 END) AS duplicate_statements,
  CAST(COUNT(DISTINCT CASE WHEN w.plan_rank IS NOT NULL AND w.hash_plans > 1 THEN w.query_hash END) AS bigint) AS duplicate_hashes
FROM w
GROUP BY w.dbid`

// planCacheSingleUseSQL: the largest single-use plans.
var planCacheSingleUseSQL = `SELECT TOP (@top) 'single_use' AS kind, CAST(pa.dbid AS int) AS database_id, CAST(DB_NAME(pa.dbid) AS nvarchar(128)) AS database_name,
  CAST(cp.objtype AS nvarchar(20)) AS plan_kind, CAST(cp.size_in_bytes AS bigint) AS size_bytes,
  CAST(LEFT(t.text, ` + fmt.Sprint(planCacheListText) + `) AS nvarchar(max)) AS query
FROM sys.dm_exec_cached_plans cp
` + fmt.Sprintf(planCacheDBIDApply, "cp.plan_handle") + `
OUTER APPLY sys.dm_exec_sql_text(cp.plan_handle) t
WHERE cp.cacheobjtype = N'Compiled Plan' AND cp.usecounts = 1 AND cp.objtype IN (N'Adhoc', N'Prepared') AND pa.dbid <> 32767
ORDER BY cp.size_in_bytes DESC, cp.plan_handle`

// planCacheDuplicatesSQL: the query hashes with the most cached ad hoc and prepared plans, each with its most executed
// statement's text; one pass over the view, as planCacheStatementsSQL.
var planCacheDuplicatesSQL = `WITH q AS (
  SELECT pa.dbid, qs.query_hash, qs.sql_handle, qs.statement_start_offset AS s, qs.statement_end_offset AS e, qs.execution_count,
         DENSE_RANK() OVER (PARTITION BY pa.dbid, qs.query_hash ORDER BY qs.plan_handle) AS plan_rank,
         ROW_NUMBER() OVER (PARTITION BY pa.dbid, qs.query_hash ORDER BY qs.execution_count DESC, qs.plan_handle, qs.statement_start_offset) AS rn
    FROM sys.dm_exec_query_stats qs
    JOIN sys.dm_exec_cached_plans cp ON cp.plan_handle = qs.plan_handle
    ` + fmt.Sprintf(planCacheDBIDApply, "qs.plan_handle") + `
   WHERE qs.query_hash <> 0x0000000000000000 AND cp.objtype IN (N'Adhoc', N'Prepared') AND pa.dbid <> 32767
), h AS (
  SELECT q.*, MAX(q.plan_rank) OVER (PARTITION BY q.dbid, q.query_hash) AS plans,
         COUNT_BIG(*) OVER (PARTITION BY q.dbid, q.query_hash) AS statements,
         SUM(q.execution_count) OVER (PARTITION BY q.dbid, q.query_hash) AS executions
    FROM q
)
SELECT TOP (@top) 'duplicate' AS kind, CAST(h.dbid AS int) AS database_id, CAST(DB_NAME(h.dbid) AS nvarchar(128)) AS database_name,
  h.query_hash AS query_hash_hex, CAST(h.plans AS bigint) AS plans, CAST(h.statements AS bigint) AS statements, CAST(h.executions AS bigint) AS executions,
  CAST(LEFT(SUBSTRING(t.text, h.s / 2 + 1, (CASE WHEN h.e = -1 THEN DATALENGTH(t.text) ELSE h.e END - h.s) / 2 + 1), ` + fmt.Sprint(planCacheListText) + `) AS nvarchar(max)) AS query
FROM h
OUTER APPLY sys.dm_exec_sql_text(h.sql_handle) t
WHERE h.rn = 1 AND h.plans > 1
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

// ---- a cached plan read on demand by its handle (task 406, Opserver's Detail > Query Plan "Download") ----------------

// PlanByHandleMaxBytes is the largest plan (DATALENGTH of the showplan text, UTF-16) a read by handle returns; a larger
// one is answered with its size and no XML.
const PlanByHandleMaxBytes = 16 << 20

// PlanFetch is what a read by handle found. State is one of:
//
//	ok            the plan of the statement (or of the batch), its QueryPlanHash the one the row was read with
//	changed       a plan, but its QueryPlanHash is not the row's: the statement was compiled again since the sample
//	gone          the cache holds no plan under the handle (evicted, recompiled under a new handle, a restart)
//	parameterized the handle's plan is the shell of a parameterized statement: the server gives its text, no plan
//	encrypted     the plan of an encrypted module: the server gives none
//	too_large     over PlanByHandleMaxBytes
//	no_plan       the server answered with no showplan for the statement (NULL: a statement it compiles at each run)
type PlanFetch struct {
	State    string `json:"state"`
	Words    string `json:"words"`
	XML      string `json:"-"`
	PlanHash string `json:"plan_hash,omitempty"` // the QueryPlanHash of the plan read (0x text)
	ObjType  string `json:"objtype,omitempty"`   // Proc, Adhoc, Prepared, Trigger ... (sys.dm_exec_cached_plans)
	Database string `json:"database,omitempty"`
	Object   string `json:"object,omitempty"` // schema.module of a module's plan
	Bytes    int64  `json:"bytes,omitempty"`
}

var planHandleForm = regexp.MustCompile(`^0[xX](?:[0-9A-Fa-f]{2}){1,64}$`)

// ParsePlanHandle turns a handle as the pages carry it (0x text, an even number of hex digits, varbinary(64) at most)
// into its bytes.
// PlanConfirm is the code typed to evict a plan: the first 8 hex digits (upper case) of SHA-256 over the handle's
// bytes, the whole handle. A handle's own digits do not name its plan: its tail is zero padding (00000000 for nearly
// every plan) and its object id or batch hash is shared by a procedure's plans under other SET options. "" for a
// handle that does not parse.
func PlanConfirm(handle string) string {
	b, err := ParsePlanHandle(handle)
	if err != nil {
		return ""
	}
	sum := sha256.Sum256(b)
	return strings.ToUpper(hex.EncodeToString(sum[:4]))
}

func ParsePlanHandle(s string) ([]byte, error) {
	s = strings.TrimSpace(s)
	if !planHandleForm.MatchString(s) {
		return nil, fmt.Errorf("a plan handle is 0x and 2 to 128 hex digits, an even count")
	}
	b := make([]byte, (len(s)-2)/2)
	for i := range b {
		var v byte
		for _, c := range s[2+2*i : 4+2*i] {
			v <<= 4
			switch {
			case c >= '0' && c <= '9':
				v |= byte(c - '0')
			case c >= 'a' && c <= 'f':
				v |= byte(c-'a') + 10
			default:
				v |= byte(c-'A') + 10
			}
		}
		b[i] = v
	}
	return b, nil
}

// planByHandleSQL reads the plan the cache holds under @h for the statement at the offsets (0, -1 = the whole batch).
// The cached-plans view drives the read, so no row = no plan under the handle. The XML is returned only under the
// size cap; DATALENGTH says how large it is either way.
const planByHandleSQL = `SELECT CAST(cp.objtype AS nvarchar(20)) AS objtype, CAST(DB_NAME(p.dbid) AS nvarchar(128)) AS database_name,
  CAST(ISNULL(p.encrypted, 0) AS int) AS encrypted, CAST(DATALENGTH(p.query_plan) AS bigint) AS plan_bytes,
  CASE WHEN DATALENGTH(p.query_plan) <= @max THEN p.query_plan END AS query_plan,
  CAST(p.dbid AS int) AS dbid, CAST(p.objectid AS int) AS objectid
FROM sys.dm_exec_cached_plans cp
OUTER APPLY sys.dm_exec_text_query_plan(cp.plan_handle, @start, @end) p
WHERE cp.plan_handle = @h`

// planObjectSQL names a module's plan apart: OBJECT_NAME waits behind a schema change, and the plan is worth having
// without its name.
const planObjectSQL = `SELECT CAST(OBJECT_SCHEMA_NAME(@obj, @db) + N'.' + OBJECT_NAME(@obj, @db) AS nvarchar(260))`

var (
	queryPlanHashRE = regexp.MustCompile(`\bQueryPlanHash="(0x[0-9A-Fa-f]+)"`)
	queryPlanElemRE = regexp.MustCompile(`<QueryPlan[\s>]`)
	paramShellRE    = regexp.MustCompile(`\bParameterizedPlanHandle="`)
)

// PlanByHandle reads one cached plan on demand through conn (the instance's read login). wantHash is the plan hash the
// page's row was read with (0x text; "" = no compare). start and end are the statement's offsets; 0 and -1 read the
// whole batch.
func PlanByHandle(ctx context.Context, conn *sql.Conn, handle []byte, start, end int, wantHash string) (PlanFetch, error) {
	var f PlanFetch
	var objtype, dbname, xml sql.NullString
	var enc, dbid, objid sql.NullInt64
	var size sql.NullInt64
	err := conn.QueryRowContext(ctx, planByHandleSQL, sql.Named("h", handle), sql.Named("start", start), sql.Named("end", end),
		sql.Named("max", int64(PlanByHandleMaxBytes))).Scan(&objtype, &dbname, &enc, &size, &xml, &dbid, &objid)
	if errors.Is(err, sql.ErrNoRows) {
		f.State, f.Words = "gone", "the plan cache holds no plan under this handle now: it was evicted, compiled again under another handle, or the server restarted since the sample"
		return f, nil
	}
	if err != nil {
		return f, err
	}
	f.ObjType, f.Database, f.Bytes = objtype.String, dbname.String, size.Int64
	if objid.Valid && objid.Int64 != 0 && dbid.Valid {
		var name sql.NullString
		if conn.QueryRowContext(ctx, planObjectSQL, sql.Named("obj", objid.Int64), sql.Named("db", dbid.Int64)).Scan(&name) == nil {
			f.Object = name.String
		}
	}
	f.State, f.Words, f.PlanHash, f.XML = planState(enc.Int64 == 1, size.Int64, xml.Valid, xml.String, wantHash)
	f.XML = MaskPlanXML(f.XML)
	return f, nil
}

// planState judges what the server returned for a handle (PlanByHandle's rules, apart for the tests): the state, its
// words, the plan's own QueryPlanHash and the XML worth returning ("" when none).
func planState(encrypted bool, size int64, has bool, xml, wantHash string) (state, words, hash, out string) {
	switch {
	case encrypted:
		return "encrypted", "the plan belongs to an encrypted module: SQL Server gives no plan for it", "", ""
	case size > PlanByHandleMaxBytes:
		return "too_large", fmt.Sprintf("the plan is %.1f MB, over the %d MB this page reads on demand", float64(size)/(1<<20), PlanByHandleMaxBytes>>20), "", ""
	case !has || xml == "":
		return "no_plan", "SQL Server answered with no plan for this statement (none is kept for it, or it is compiled at each run)", "", ""
	case !queryPlanElemRE.MatchString(xml):
		if paramShellRE.MatchString(xml) {
			return "parameterized", "the handle holds the shell of a parameterized statement: SQL Server gives its text and the parameterized plan's handle, not a plan", "", ""
		}
		return "no_plan", "the showplan SQL Server returned holds no QueryPlan element", "", ""
	}
	if m := queryPlanHashRE.FindStringSubmatch(xml); m != nil {
		hash = "0x" + strings.ToUpper(m[1][2:])
	}
	if wantHash != "" && hash != "" && !strings.EqualFold(wantHash, hash) {
		return "changed", fmt.Sprintf("the cached plan changed since this sample: its plan hash is %s, the sample's %s", hash, strings.ToUpper(wantHash)), hash, xml
	}
	return "ok", "the cached plan", hash, xml
}

// ---- the plans of running queries (task 406, DBA Dash 4.25.0's running query plans and live plans, row N55) --------

// runningPlansCollector is mssql_running_plans: the statement plan of a running query whose plan is worth keeping,
// read every minute once the instance's schedules: switch it on (off by default: DefaultInterval 0). The running
// requests are grouped as DBA Dash 4.25.0 groups them (DBCollector.cs GetPlansMeetingThreshold): by plan handle,
// plan hash and the statement's offsets, a zero plan hash left out (a statement not compiled yet); a group is kept
// when any of DBA Dash's default thresholds is met (PlanCollectionThreshold.DefaultThreshold): its requests' CPU
// summed to 1,000 ms, their granted memory summed to 6,400 pages (50 MB), 2 requests on the plan, or the oldest
// running 10 s. Each kept group sends a 'running' row with its figures every read; its plan (sys.dm_exec_text_query_plan
// at the offsets) travels when this process has not sent that plan in runningPlanEvery, as plancache's texts do.
// The plan follows the instance's query_text policy (kind_of 'plan': stored under full only) and qsPlanXMLMaxBytes.
// The repository keys a plan as DBA Dash does: query hash, plan hash and offsets (0157).
//
// liveplansCollector is mssql_live_plans: the plan with its operator counters so far (sys.dm_exec_query_statistics_xml)
// of a long running request, off by default, on a build where that function is safe to call every minute (SQL Server
// 2016 SP1 and later; 2017 from CU26 and 2019 from CU12, the builds that took ParameterRuntimeValue out of it after the
// access violation Microsoft's page names; 2022 and later; Managed Instance and Azure SQL Database), at most
// livePlanMax requests a read, the most CPU first, each over DBA Dash's LiveProfileThreshold.DefaultThreshold (60 s of
// CPU, or 300 s running while not blocked) and on a plan that meets the plan threshold above. Without lightweight
// profiling (before SQL Server 2019 trace flag 7412 turns it on) the function returns no plan: the run says so.
//
// Rights: VIEW SERVER STATE (VIEW SERVER PERFORMANCE STATE on 2022). Nothing is written on the server.
type runningPlansCollector struct{}
type livePlansCollector struct{}

func init() {
	Register(runningPlansCollector{})
	Register(livePlansCollector{})
}

const (
	// DBA Dash 4.25.0's PlanCollectionThreshold.DefaultThreshold
	runningPlanCPUms      = 1000
	runningPlanGrantPages = 6400
	runningPlanCount      = 2
	runningPlanRunningMs  = 10000
	// DBA Dash 4.25.0's LiveProfileThreshold.DefaultThreshold and DefaultMaxPerCollection
	livePlanCPUms     = 60000
	livePlanRunningMs = 300000
	livePlanMax       = 10
	// runningPlanEvery is how long a plan this process sent is not sent again (its figures are, every read)
	runningPlanEvery = time.Hour
	// runningPlanReadsPerRun and runningPlanBytesPerRun bound the plans one read asks for, the most CPU first; the rest
	// travel with their figures only and are asked for at a later read
	runningPlanReadsPerRun = 20
	runningPlanBytesPerRun = 16 << 20
	// livePlanCallTimeout bounds one sys.dm_exec_query_statistics_xml call; livePlanRunBudget the calls of one read
	// (under RunTimeout, so a slow server ends the read with what it has, never with the run's own deadline)
	livePlanCallTimeout = 10 * time.Second
	livePlanRunBudget   = 40 * time.Second
)

func (runningPlansCollector) Name() string                   { return Prefix + "running_plans" }
func (runningPlansCollector) DefaultInterval() time.Duration { return 0 }
func (runningPlansCollector) Applies(info Info) (bool, string) {
	if !info.ViewServerState && info.Kind != KindAzureMI && info.Major < 16 {
		return false, "the login lacks VIEW SERVER STATE: the running requests of other logins cannot be read"
	}
	return true, ""
}

func (livePlansCollector) Name() string                   { return Prefix + "live_plans" }
func (livePlansCollector) DefaultInterval() time.Duration { return 0 }
func (livePlansCollector) Applies(info Info) (bool, string) {
	if ok, why := LivePlanBuildOK(info); !ok {
		return false, why
	}
	return runningPlansCollector{}.Applies(info)
}

// LivePlanBuildOK is the build gate of mssql_live_plans (and of any live plan read): sys.dm_exec_query_statistics_xml
// exists from SQL Server 2016 SP1; on 2017 before CU26 and 2019 before CU12 it can hit the access violation those
// updates fixed by taking ParameterRuntimeValue out, so it is not called there.
func LivePlanBuildOK(info Info) (bool, string) {
	if info.Kind == KindAzureDB || info.Kind == KindAzureMI {
		return true, ""
	}
	switch {
	case info.Major == 13 && info.Build < 4001:
		return false, fmt.Sprintf("SQL Server 2016 before SP1 (build %s) has no sys.dm_exec_query_statistics_xml", info.ProductVersion)
	case info.Major == 14 && info.Build < 3411:
		return false, fmt.Sprintf("off on SQL Server 2017 before CU26 (build %s; CU26 is 14.0.3411.3): sys.dm_exec_query_statistics_xml can raise an access violation there (Microsoft's page, Limitations)", info.ProductVersion)
	case info.Major == 15 && info.Build < 4153:
		return false, fmt.Sprintf("off on SQL Server 2019 before CU12 (build %s; CU12 is 15.0.4153.1): sys.dm_exec_query_statistics_xml can raise an access violation there (Microsoft's page, Limitations)", info.ProductVersion)
	case info.Major > 0 && info.Major < 13:
		return false, "SQL Server before 2016 has no sys.dm_exec_query_statistics_xml"
	}
	return true, ""
}

// runningReqSQL: the user requests running now with a compiled plan (DBA Dash's columns), the server's clock with them.
// running_ms is how long the request has run; blocked says another session holds it up (it does not count toward the
// live plan's running time).
const runningReqSQL = `SELECT r.session_id AS session_id, r.request_id AS request_id, r.plan_handle AS plan_handle, r.query_hash AS query_hash,
  r.query_plan_hash AS plan_hash, CAST(r.statement_start_offset AS int) AS stmt_start, CAST(r.statement_end_offset AS int) AS stmt_end,
  CAST(r.cpu_time AS bigint) AS cpu_ms, CAST(r.granted_query_memory AS bigint) AS grant_pages,
  CAST(DATEDIFF_BIG(millisecond, r.start_time, GETDATE()) AS bigint) AS running_ms,
  CAST(CASE WHEN r.blocking_session_id > 0 THEN 1 ELSE 0 END AS int) AS blocked,
  CAST(DB_NAME(r.database_id) AS nvarchar(128)) AS database_name, CAST(d.compatibility_level AS int) AS compat
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON s.session_id = r.session_id
LEFT JOIN sys.databases d ON d.database_id = r.database_id
WHERE r.session_id <> @@SPID AND s.is_user_process = 1 AND r.plan_handle IS NOT NULL
  AND r.query_plan_hash IS NOT NULL AND r.query_plan_hash <> 0x0000000000000000`

// runningReq is one row of runningReqSQL.
type runningReq struct {
	session, request             int64
	handle, qhash, phash, dbname string
	start, end                   int64
	cpu, grant, running          int64
	compat                       int64 // the database's compatibility level; 0 = not read
	blocked                      bool
}

func runningReqs(rows []collect.Row) []runningReq {
	out := make([]runningReq, 0, len(rows))
	for _, r := range rows {
		s := func(k string) string { v, _ := r[k].(string); return v }
		n := func(k string) int64 { v, _ := r[k].(int64); return v }
		out = append(out, runningReq{session: n("session_id"), request: n("request_id"), handle: s("plan_handle"), qhash: s("query_hash"),
			phash: s("plan_hash"), dbname: s("database_name"), start: n("stmt_start"), end: n("stmt_end"), cpu: n("cpu_ms"),
			grant: n("grant_pages"), running: n("running_ms"), compat: n("compat"), blocked: n("blocked") == 1})
	}
	return out
}

// planGroup is the running requests of one plan and statement (DBA Dash's key: handle, plan hash, offsets).
type planGroup struct {
	key                 string
	first               runningReq
	requests            int
	cpu, grant, longest int64
	reasons             []string
	meets               bool
}

// groupRunning groups the requests and judges each group against the plan threshold, the most CPU first.
func groupRunning(reqs []runningReq) []*planGroup {
	by := map[string]*planGroup{}
	var order []*planGroup
	for _, q := range reqs {
		if q.phash == "" || zeroHash.MatchString(q.phash) || q.handle == "" {
			continue
		}
		k := fmt.Sprintf("%s|%s|%d|%d", q.handle, q.phash, q.start, q.end)
		g := by[k]
		if g == nil {
			g = &planGroup{key: k, first: q}
			by[k] = g
			order = append(order, g)
		}
		g.requests++
		g.cpu += q.cpu
		g.grant += q.grant
		if q.running > g.longest {
			g.longest = q.running
		}
	}
	for _, g := range order {
		if g.cpu >= runningPlanCPUms {
			g.reasons = append(g.reasons, "cpu")
		}
		if g.grant >= runningPlanGrantPages {
			g.reasons = append(g.reasons, "grant")
		}
		if g.requests >= runningPlanCount {
			g.reasons = append(g.reasons, "count")
		}
		if g.longest >= runningPlanRunningMs {
			g.reasons = append(g.reasons, "duration")
		}
		g.meets = len(g.reasons) > 0
	}
	sort.SliceStable(order, func(i, j int) bool { return order[i].cpu > order[j].cpu })
	return order
}

// livePicks are the requests whose live plan a read asks for: on a plan that meets the plan threshold, over 60 s of
// CPU or 300 s running while not blocked, the most CPU first, livePlanMax at most.
func livePicks(reqs []runningReq) []runningReq {
	meets := map[string]bool{}
	for _, g := range groupRunning(reqs) {
		meets[g.key] = g.meets
	}
	var out []runningReq
	for _, q := range reqs {
		k := fmt.Sprintf("%s|%s|%d|%d", q.handle, q.phash, q.start, q.end)
		if !meets[k] {
			continue
		}
		if q.cpu >= livePlanCPUms || (!q.blocked && q.running >= livePlanRunningMs) {
			out = append(out, q)
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].cpu > out[j].cpu })
	if len(out) > livePlanMax {
		out = out[:livePlanMax]
	}
	return out
}

// sentMemo remembers when this process last sent something per key (a server's plan), so it travels once in a while.
type sentMemo struct {
	mu sync.Mutex
	at map[string]time.Time
	// every is how long a key sent is not sent again
	every time.Duration
}

func (m *sentMemo) due(key string, now time.Time) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.at[key]
	return !ok || now.Sub(t) >= m.every
}

func (m *sentMemo) mark(key string, now time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for k, t := range m.at { // forget what is long past, so the memo never grows without bound
		if now.Sub(t) >= 2*m.every {
			delete(m.at, k)
		}
	}
	m.at[key] = now
}

// runningPlanSent remembers which plans this process sent, per server and key, for runningPlanEvery.
var runningPlanSent = &sentMemo{at: map[string]time.Time{}, every: runningPlanEvery}

// runningPlanSQL reads one statement's plan by handle and offsets, under the size cap.
const runningPlanSQL = `SELECT CAST(DATALENGTH(p.query_plan) AS bigint) AS plan_bytes,
  CASE WHEN DATALENGTH(p.query_plan) <= @max THEN p.query_plan END AS query_plan, CAST(ISNULL(p.encrypted, 0) AS int) AS encrypted
FROM sys.dm_exec_text_query_plan(CONVERT(varbinary(64), @h, 1), @start, @end) p`

func (runningPlansCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	reqs, err := QueryRows(ctx, conn, runningReqSQL)
	if err != nil {
		return nil, err
	}
	server := info.ServerName
	now := time.Now()
	// the policy row: kind_of 'plan' carries the instance's text policy to the import (the policy empties its statement
	// unless it is full), which then drops every running plan and live capture a wider policy stored
	out := []collect.Row{policyRow()}
	asked, budget := 0, int64(runningPlanBytesPerRun)
	for _, g := range groupRunning(runningReqs(reqs)) {
		if !g.meets {
			continue
		}
		q := g.first
		row := collect.Row{"kind": "running", "query_hash_hex": q.qhash, "plan_hash_hex": q.phash, "stmt_start": q.start, "stmt_end": q.end,
			"plan_handle": q.handle, "database_name": q.dbname, "requests": g.requests, "cpu_ms": g.cpu, "grant_kb": g.grant * 8,
			"longest_ms": g.longest, "reasons": strings.Join(g.reasons, ",")}
		if q.compat > 0 {
			row["compatibility_level"] = q.compat
		}
		if runningPlanSent.due(runningPlanKey(server, row), now) && asked < runningPlanReadsPerRun && budget > 0 {
			asked++
			var size sql.NullInt64
			var xml sql.NullString
			var enc int64
			err := conn.QueryRowContext(ctx, runningPlanSQL, sql.Named("h", q.handle), sql.Named("start", q.start), sql.Named("end", q.end),
				sql.Named("max", min(int64(qsPlanXMLMaxBytes), budget))).Scan(&size, &xml, &enc)
			switch {
			case errors.Is(err, sql.ErrNoRows) || (err == nil && !size.Valid && enc == 0):
				row["plan_state"] = "gone" // the request ended and its plan left the cache between the two reads
			case err != nil:
				if ctx.Err() != nil {
					return out, err
				}
				row["plan_state"] = "error"
				row["plan_note"] = "the plan was not read: " + err.Error()
			case enc == 1:
				row["plan_state"] = "encrypted"
			case size.Int64 > qsPlanXMLMaxBytes:
				row["plan_state"], row["plan_bytes"] = "too large", size.Int64
			case size.Int64 > budget:
				delete(row, "plan_state") // over what is left of this read's share: asked for again at a later read
			case xml.Valid && xml.String != "":
				// kind_of 'plan': the policy empties statement unless it is full
				row["kind_of"], row["statement"], row["plan_bytes"], row["plan_state"] = "plan", MaskPlanXML(xml.String), size.Int64, "read"
				budget -= size.Int64
				out = append(out, statsRows(xml.String, collect.Row{"query_hash_hex": q.qhash, "plan_hash_hex": q.phash, "stmt_start": q.start,
					"stmt_end": q.end, "database_name": q.dbname})...)
			default:
				row["plan_state"] = "no plan"
			}
		}
		out = append(out, row)
	}
	return out, nil
}

// runningPlanKey is the memo's key of a running row: the server and DBA Dash's key.
func runningPlanKey(server string, r collect.Row) string {
	return fmt.Sprint(server, "|", r["query_hash_hex"], "|", r["plan_hash_hex"], "|", r["stmt_start"], "|", r["stmt_end"])
}

// AfterStore marks the plans of a stored run as sent (read, too large, encrypted: the same answer for an hour), so a
// run whose rows were not stored (its deadline, a failed import) asks for them again at the next read. RunOnce calls
// it after the import (the wiring patch's mssql.go hunk); without it every read asks again, within the per-run share.
func (runningPlansCollector) AfterStore(info Info, rows []collect.Row) {
	now := time.Now()
	for _, r := range rows {
		if r["kind"] != "running" {
			continue
		}
		switch r["plan_state"] {
		case "read", "too large", "encrypted":
			runningPlanSent.mark(runningPlanKey(info.ServerName, r), now)
		}
	}
}

// AfterStorer is what a collector adds when it must learn that its run's rows were stored.
type AfterStorer interface {
	AfterStore(info Info, rows []collect.Row)
}

// policyRow carries the instance's text policy to the import: kind_of 'plan' (the policy empties statement unless
// it is full); an import that sees it emptied drops the instance's running plans and live captures.
func policyRow() collect.Row {
	return collect.Row{"kind": "plan_policy", "kind_of": "plan", "statement": "kept"}
}

// liveTraceSQL: before SQL Server 2019 lightweight profiling is on only with trace flag 7412 (globally).
const liveTraceSQL = `DECLARE @t TABLE (TraceFlag int, Status int, Global int, Session int);
INSERT @t EXEC (N'DBCC TRACESTATUS(7412, -1) WITH NO_INFOMSGS');
SELECT CAST(ISNULL(MAX(Global), 0) AS int) FROM @t`

// livePlanSQL: the live plan under the size cap (its bytes always; the XML only when they fit).
const livePlanSQL = `SELECT x.request_id, CONVERT(varchar(140), x.plan_handle, 1), CAST(DATALENGTH(c.t) AS bigint),
  CASE WHEN DATALENGTH(c.t) <= @max THEN c.t END
FROM sys.dm_exec_query_statistics_xml(@sid) x CROSS APPLY (SELECT CAST(x.query_plan AS nvarchar(max)) AS t) c`

func (livePlansCollector) Run(ctx context.Context, conn *sql.Conn, info Info) ([]collect.Row, error) {
	reqs, err := QueryRows(ctx, conn, runningReqSQL)
	if err != nil {
		return nil, err
	}
	picks := livePicks(runningReqs(reqs))
	if len(picks) == 0 {
		return []collect.Row{policyRow(), {"kind": "live_read", "asked": 0, "read": 0}}, nil
	}
	note := ""
	if info.Kind == KindServer || info.Kind == KindRDS {
		if info.Major > 0 && info.Major < 15 {
			var on int64
			if err := conn.QueryRowContext(ctx, liveTraceSQL).Scan(&on); err == nil && on == 0 {
				note = "lightweight profiling is off on this server (before SQL Server 2019 trace flag 7412 turns it on): no live plan is returned"
			}
		}
	}
	out := []collect.Row{policyRow()}
	read, asked, over := 0, 0, 0
	budget := int64(runningPlanBytesPerRun) // the live plans of one read, as the running plans' share
	began := time.Now()
	for _, q := range picks {
		if time.Since(began) >= livePlanRunBudget {
			note = fmt.Sprintf("the read stopped after %d of %d requests: its %d s for live plans were spent", asked, len(picks), int(livePlanRunBudget.Seconds()))
			break
		}
		asked++
		cctx, cancel := context.WithTimeout(ctx, livePlanCallTimeout)
		var reqID, size sql.NullInt64
		var handle, xml sql.NullString
		err := conn.QueryRowContext(cctx, livePlanSQL, sql.Named("sid", q.session), sql.Named("max", min(int64(qsPlanXMLMaxBytes), budget))).Scan(&reqID, &handle, &size, &xml)
		cancel()
		if ctx.Err() != nil {
			return out, ctx.Err()
		}
		if err != nil || !size.Valid || !strings.EqualFold(handle.String, q.handle) || reqID.Int64 != q.request {
			continue // the request ended or moved on, or no live plan is kept for it
		}
		row := collect.Row{"kind": "live", "query_hash_hex": q.qhash, "plan_hash_hex": q.phash, "stmt_start": q.start,
			"stmt_end": q.end, "session_id": q.session, "request_id": q.request, "cpu_ms": q.cpu, "running_ms": q.running,
			"database_name": q.dbname, "plan_bytes": size.Int64}
		switch {
		case size.Int64 > qsPlanXMLMaxBytes:
			row["plan_state"] = "too large" // its bytes kept, no XML (no kind_of: nothing for the policy to empty)
		case size.Int64 > budget:
			over++ // over what is left of this read's share: asked for again at a later read
			continue
		case xml.Valid && xml.String != "":
			row["kind_of"], row["statement"] = "plan", MaskPlanXML(xml.String)
			budget -= size.Int64
		default:
			continue
		}
		read++
		out = append(out, row)
	}
	r := collect.Row{"kind": "live_read", "asked": len(picks), "read": read}
	if over > 0 {
		note = strings.TrimPrefix(note+fmt.Sprintf("; %d live plan(s) left out: over the read's %d MB", over, runningPlanBytesPerRun>>20), "; ")
	}
	if note != "" && (read == 0 || asked < len(picks) || over > 0) {
		r["note"] = note
	}
	return append(out, r), nil
}

// MaskPlanXML masks the password forms of collect.MaskJobText (PASSWORD = '...', SECRET = '...', @...pwd = N'...', a
// connection string's Pwd=, sqlcmd's -P, net use) in a showplan. A showplan's text is in its attribute values
// (StatementText, ParameterCompiledValue, ParameterRuntimeValue, ScalarString, ConstValue): each value is decoded (SQL
// Server writes a literal's quotes as &apos; and &quot;), masked, and written back escaped only when the mask changed
// it, so the document stays XML and every value the mask leaves alone keeps its bytes. Every plan this package sends or
// a page returns goes through it, the query_text policy 'full' included ("credentials masked on the way out, always").
// A value only the parameter's name marks (ParameterCompiledValue of @pwd) is not seen: that is the policy's job.
func MaskPlanXML(x string) string {
	if x == "" {
		return x
	}
	return planAttrRE.ReplaceAllStringFunc(x, func(m string) string {
		g := planAttrRE.FindStringSubmatch(m)
		head, raw, q := g[1], g[2], g[3]
		if raw == "" {
			head, raw, q = g[4], g[5], g[6]
		}
		if raw == "" {
			return m
		}
		val := html.UnescapeString(raw)
		masked := collect.MaskJobText(val)
		if masked == val {
			return m
		}
		return head + planAttrEscape(masked) + q
	})
}

// planAttrRE is one attribute and its value, in double quotes or single quotes (a value holds no raw delimiter).
var planAttrRE = regexp.MustCompile(`(\s[A-Za-z_][\w.:-]*\s*=\s*")([^"<]*)(")|(\s[A-Za-z_][\w.:-]*\s*=\s*')([^'<]*)(')`)

// planAttrEscape writes a value for an attribute: the five entities and the line ends as SQL Server writes them.
func planAttrEscape(v string) string {
	var b strings.Builder
	for _, r := range v {
		switch r {
		case '&':
			b.WriteString("&amp;")
		case '<':
			b.WriteString("&lt;")
		case '>':
			b.WriteString("&gt;")
		case '"':
			b.WriteString("&quot;")
		case '\'':
			b.WriteString("&apos;")
		case '\r':
			b.WriteString("&#xD;")
		case '\n':
			b.WriteString("&#xA;")
		case '\t':
			b.WriteString("&#x9;")
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// ---- the statistics a plan was compiled with (task 406, PerformanceMonitor 3.13's Added 1) -------------------------

// StatUsed is one StatisticsInfo of a showplan's OptimizerStatsUsage: a statistic the optimizer loaded to compile the
// statement, as it saw it then (SQL Server 2017 and 2016 SP2 write the element; an older plan has none).
type StatUsed struct {
	Stmt        int    // the statement's place in the plan, from 1
	Database    string // as the plan writes it, brackets taken off
	Schema      string
	Table       string
	Statistics  string
	ModCount    int64   // ModificationCount: rows changed since the statistic's last update, at compile
	SamplingPct float64 // SamplingPercent
	LastUpdate  string  // LastUpdate as written (the server's clock, no zone)
}

func unbracket(s string) string {
	if len(s) >= 2 && s[0] == '[' && s[len(s)-1] == ']' {
		return strings.ReplaceAll(s[1:len(s)-1], "]]", "]")
	}
	return s
}

// PlanStatsUsed reads every StatisticsInfo of a showplan (encoding/xml, nothing evaluated); a document that does not
// parse gives what was read before the fault.
func PlanStatsUsed(plan string) []StatUsed {
	var out []StatUsed
	if !strings.Contains(plan, "StatisticsInfo") {
		return nil
	}
	dec := xml.NewDecoder(strings.NewReader(plan))
	stmt := 0
	for {
		tok, err := dec.Token()
		if err != nil {
			return out
		}
		se, ok := tok.(xml.StartElement)
		if !ok {
			continue
		}
		switch se.Name.Local {
		case "StmtSimple", "StmtCond", "StmtCursor", "StmtReceive", "StmtUseDb":
			stmt++
		case "StatisticsInfo":
			s := StatUsed{Stmt: max(stmt, 1)}
			for _, a := range se.Attr {
				switch a.Name.Local {
				case "Database":
					s.Database = unbracket(a.Value)
				case "Schema":
					s.Schema = unbracket(a.Value)
				case "Table":
					s.Table = unbracket(a.Value)
				case "Statistics":
					s.Statistics = unbracket(a.Value)
				case "ModificationCount":
					s.ModCount, _ = strconv.ParseInt(a.Value, 10, 64)
				case "SamplingPercent":
					s.SamplingPct, _ = strconv.ParseFloat(a.Value, 64)
				case "LastUpdate":
					s.LastUpdate = a.Value
				}
			}
			out = append(out, s)
		}
	}
}

// statsRows turns a plan's statistics into collect rows of kind 'plan_stats' carrying the plan's key fields.
func statsRows(plan string, key collect.Row) []collect.Row {
	var out []collect.Row
	for _, s := range PlanStatsUsed(plan) {
		r := collect.Row{"kind": "plan_stats", "stmt": s.Stmt, "stat_database": s.Database, "stat_schema": s.Schema, "stat_table": s.Table,
			"stat_name": s.Statistics, "modification_count": s.ModCount, "sampling_pct": s.SamplingPct, "last_update": s.LastUpdate}
		for k, v := range key {
			r[k] = v
		}
		out = append(out, r)
	}
	return out
}
