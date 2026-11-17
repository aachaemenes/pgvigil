# SQL Server: plan cache, indexes and statistics

Four collections cover three areas: the statements the plan cache ran, the indexes of every user database, and the health of the optimizer's statistics. Each one only reads. None of them runs a DISABLE, a CREATE or an UPDATE STATISTICS. Any T-SQL the pages show is text for a DBA to read, test and run.

| Collection | Every | What it reads | Rights |
|---|---|---|---|
| `mssql_plancache` | 5 min | `sys.dm_exec_query_stats`: per cached statement, what changed between two reads | `VIEW SERVER STATE` (2022: `VIEW SERVER PERFORMANCE STATE` is enough) |
| `mssql_plancache_health` | 1 h | `sys.dm_exec_cached_plans` and `sys.dm_exec_query_stats`: what the cache holds, per database | as `mssql_plancache` |
| `mssql_indexes` | 6 h | each user database's `sys.indexes`, `sys.index_columns`, `sys.dm_db_index_usage_stats` and `sys.dm_db_partition_stats`; the server's missing-index DMVs | `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `CONNECT ANY DATABASE`; `SELECT` on `msdb.dbo.restorehistory` for the restore date |
| `mssql_stats` | 6 h | each user database's `sys.stats` with `sys.dm_db_stats_properties` | as `mssql_indexes`; `db_datareader` for the sample rates |

All four are written for SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; only SQL Server 2022 is proven (below). They do not run on Azure SQL Database yet.

## Plan cache (`mssql_plancache`, `mssql_plancache_health`)

`sys.dm_exec_query_stats` counts per statement from the moment its plan was compiled. The collector sends those counters as they stand. The repository then stores what each five-minute interval added, summed per database and query hash. It follows the same rules as the procedure statistics:

- The first read only sets the starting counters.
- A statement seen before gives the difference.
- A statement that is new, or whose counters went down, gives its whole count.
- No figure is ever negative.

The plan cache only shows what stays in it. Some work is never counted:

- A statement compiled, run and evicted between two reads.
- Whatever a plan ran after the last read, if the cache drops that plan before the next one.

On a cache that turns over fast, the figures are a floor. The health read shows how fast the cache turns over.

The collector does not send every cached statement. It sends the first 500 by CPU, by duration, by logical reads and by executions, plus the first 500 with a memory grant or a spill. When the cache holds more, the read is marked *cut*. After a cut read, a statement that is new to the list gives its whole count only if it was compiled after that read. Otherwise it only sets its counters, because it may simply have been past the cut. Statement texts travel apart, each one at most once an hour, and they follow the instance's query-text policy.

The **Plan cache** tab shows:

- The statements of the range, the most CPU first.
- A **database** filter.
- **Only databases without Query Store**, the scope for which the plan cache is the only statement history. Databases with Query Store have a fuller history on the Query Store tab.
- Four column groups on the statements, each off until its box is ticked: **Times** (the plan's generation, CLR time, peak CPU per second), **Extremes** (the smallest and largest CPU, duration, physical reads, rows and spilled pages of a single run), **Memory grants** (the smallest grant, the largest use, the smallest and largest ideal grant) and **Parallelism** (the smallest DOP, reserved and used threads). The server keeps each extreme per cached statement since its compile, so a group shows the plans that ran in the range, each since its compile, not the range's own smallest and largest. "not read" means the server has no such column, or the reads came before pgvigil stored it.
- A **diagnostics** column with sp_QuickieCache's words: *Row count variance* (the largest run returned 100 times the smallest or more), *Parameter sniffing* (over 3 executions, and a run under 0.70 or over 1.30 of the average CPU; or, with the CPU inside that band, of an average of physical reads over 1,000) and *Wasteful grant* (over 1 MB granted, under 10 % used). They are judged on the statement's newest read of the range, on its figures since compile. sp_QuickieCache counts every cached plan of the query hash; pgvigil counts the plans that ran in that read. **with a diagnostic** keeps the statements that carry one.
- **Slow and frequent**: dbatools' `Get-DbaQueryExecutionTime` filter with its defaults - an average CPU of 500 ms or more over 100 executions or more, and of each database the first 100 by average CPU - on the range's figures (dbatools reads the counts since compile). The API takes the three values as `min_avg_cpu_ms`, `min_executions` and `per_db`.
- What the cache holds, per database: plans, single-use plans and their size, statements compiled in the last 24, 4 and 1 hours, and statements whose query hash has more than one cached plan.
- Two lists: the largest single-use plans, and the query hashes with the most plans.

Findings (a read older than three hours raises nothing):

| Finding | When |
|---|---|
| most cached plans are recent (warning) | over 75 % of the 1,000 or more cached statements were compiled in the last 24 hours, on a server up for more than a day |
| single-use plans in the cache | single-use ad hoc or prepared plans are over 10 % of a user database's compiled plans (info) or over 75 % (warning), with 100 at least |
| one statement compiled into many plans | statements of a query hash with several plans are over 5 % of a user database's cached statements (info) or over 75 % (warning), with 100 at least |
| wasteful memory grants (info) | a statement that ran in the last 3 hours was granted over 1 MB of memory and used under 10 % of it; one finding per instance, with the count and the five largest |

The grant finding looks at the last 3 hours only, and its words say so: a nightly job's grant is gone from Findings by morning without having been fixed. The Plan cache tab's own grant columns and its diagnostics follow the tab's range, so the job's statement is found there by picking the night.

The **Procedures** tab has an **Extremes** box: the smallest and largest CPU, duration, logical and physical reads, writes and spilled pages of a single execution, as the server keeps them per cached procedure plan.

### Cached plans, read on demand

A row of the Plan cache tab's statements has **Cached plans**: each entry the last read held (plan handle, the statement's offsets, plan hash, compile time), with **Download .sqlplan** and **Open** of the statement's plan or the whole batch's, read from the server when asked through the read login (`sys.dm_exec_text_query_plan`). A plan is read under the instance's `query_text` policy `full` only (a plan carries the statement's text and its compiled values) and its T-SQL password forms are masked. Every read writes a row in the custom reports' log first (op `plan_read`: who, from where, the instance, the handle and offsets and what was read, never the plan), through the actions door's audit login: a serve without it (`-no-login`, or no audit login) reads no plan and says why. A read login in `sysadmin` is not refused here, unlike for custom reports: these are pgvigil's own fixed reads, the ones its collections make on that login. The reply says when the plan's hash is not the sample's (compiled again since), when the cache no longer holds it, when the handle holds a parameterized statement's shell, and when the module is encrypted. **Evict** removes the plan through the actions door (`plan_evict`, off by default: [actions](sqlserver-actions.md)). **On every instance** lists the statement's query hash on every SQL Server instance over the range.

### Plans of running queries

`mssql_running_plans` and `mssql_live_plans` are off by default, on every instance: a plan carries the statement's text and its literals (passwords masked), and it is kept only under the `query_text` policy `full`. An instance added on Admin > Instances is switched on by its **running plans** box there (an admin's tick; off again by clearing it; the collector takes it within 15 seconds). For an instance of the configuration file add to it:

```yaml
    schedules:
      mssql_running_plans: 1m
      mssql_live_plans: 1m      # where the build allows it (the table above)
```

and restart the collector. The file's global `schedules:` line for `mssql_running_plans` comes before the page's box: `0` turns it off for every instance whose own `schedules:` does not name it, the ticked page instances too, and any other value reads every SQL Server instance, ticked or not. When the policy leaves `full`, the plans and live plans kept are dropped at the next read and no longer shown. The tab's **Plans of running queries** lists each plan kept, why (CPU, memory grant, running time, requests), the largest figures a read saw, its plan and its newest live plan, and **Statistics used** (the statistics the plan was compiled with, stale at compile when their changes had passed the auto-update line). A slow query's or a running request's **Plan** lists every plan pgvigil holds or can read for its query and plan hash.

## Indexes (`mssql_indexes`)

There is one row per index of every user table and indexed view. Each row holds:

- The definition: keys in order with their direction, included columns, the filter, uniqueness, the constraint the index backs, IGNORE_DUP_KEY, fill factor and compression.
- Its size and rows.
- What it was used for: seeks, scans, lookups and writes, with the time of the last read and the last write.

Each database is read and stored on its own. If a database's read fails, the repository keeps what it already holds for it.

### What else each read stores

After a database's index read, five more reads of the same database, each a plain `SELECT` (sp_BlitzIndex 8.34 and sp_IndexCleanup 2.11 read the same things; their rules come from these values):

- Per index: whether its object is a table or an indexed view; its filegroup or partition scheme, with the partition function's argument type, partition count and boundaries (`RANGE RIGHT FOR VALUES (100, 200)`, each value written whole) and the partitioning column; whether any partition is uncompressed; and a filtered index's filter columns.
- Per index, from `sys.dm_db_index_operational_stats` summed over the partitions: row and page lock waits, page latch and page I/O latch waits (count and milliseconds), forwarded fetches and leaf deletes. These count only since the table's metadata entered the server's cache, which can be later than the server's start.
- Per columnstore index, on SQL Server 2022 and later: the columns whose compressed segments keep no minimum and maximum string data. Such an index was built before 2022 and gains string segment elimination only from a rebuild. Before 2022 this is not read, and the database's read notes say so.
- Per heap of a user table: its size, rows, reads, writes, forwarded fetches and deletes, its filegroup or partition scheme and the table's create date. The Indexes tab lists them in a Heaps block under the inventory.
- Per user table and indexed view: its columns' count and declared bytes, its LOB and string columns, whether it has a sparse column or a `text`, `ntext` or `image` column, the clustered key's bytes and columns, and whether it is a system-versioned temporal table or a history table.
- Per enabled foreign key: its table, the table it references and its columns in order.

The filter columns are the table's columns whose bracketed name the filter holds, as sp_IndexCleanup finds them. sp_BlitzIndex reads them from `sys.sql_expression_dependencies`, but by default only `db_owner` may read that view, so the monitor login cannot. No new right is needed for any of these reads.

When one of these reads fails (a lock timeout, a denied right), the index read and the other reads still stand. The database's **read notes** on the Usage window grid name the part and the server's words, and the collection's run shows as partial. A part that was not read stores nothing for that database: a rule that needs it does not judge that database.

### The usage window

The usage counters are kept in memory. They start again whenever:

- the server starts;
- a database is restored;
- a database is created or attached;
- a database is shut down: taken offline and back, detached, or closed by AUTO_CLOSE.

The start of a database's window is the latest of the dates pgvigil can read (server start, last restore, create date), and the page says which one it was. A shutdown leaves no date. pgvigil sees one when an index's counters went down between two reads, and then the window starts at the read before. A database with AUTO_CLOSE on has no known window, and none of its indexes is judged unused. A shutdown after which every counter grew past its old value before the next read is not seen. **No index is called unused before the window is seven days long, or while its table is younger than seven days**: the page says "too early". Under 14 days, an unused verdict carries a warning, because a weekly or monthly job may not have run yet. On an availability group's primary with a readable secondary, reads made on the secondary are counted there and not here. A database that is a secondary replica on the server read is not read at all: its indexes are the primary's.

Memory-optimized tables are left out: the usage counters do not count their indexes, and DISABLE does not apply to them.

An index that backs a primary key or a unique constraint, or that a foreign key is bound to, is never the one a rule disables. An index another one's included columns are to be merged into is never called unused, and has no text of its own while that merge stands. SQL Server keeps no creation date for an index, so the table's last change is named when it is recent.

### The rules

| Rule | What it means | Text shown (never run) |
|---|---|---|
| exact duplicate | the same keys, includes and filter as another index; a constraint is kept first, then a unique index, then the most read | `ALTER INDEX ... DISABLE` |
| duplicate constraint | two constraints on the same keys | none: a foreign key may reference either |
| key subset | its keys are the leading keys of another index | the kept index with this one's includes merged in (`DROP_EXISTING`) when it lacks any, then `DISABLE`; no text when the merge cannot be written (the kept index backs a constraint or a foreign key, or its partitions differ in compression) |
| same keys, other includes | the same keys and filter, other includes | as for a key subset |
| constraint doubled | the keys of a unique constraint, plus includes | this index made `UNIQUE`, then the constraint dropped |
| unused, written / unused | no seek, scan or lookup in a window over 7 days (10,000 or more writes: a warning) | `DISABLE` |
| written, seldom read | 10,000 or more writes, under 10,000 reads, ten times more writes than reads | none |
| same keys, another order / same leading column | for review | none |

A merged definition spells out `ONLINE` (as the edition allows), `FILLFACTOR`, `SORT_IN_TEMPDB` and `DATA_COMPRESSION`, and keeps the index's `IGNORE_DUP_KEY`, `ALLOW_ROW_LOCKS`, `ALLOW_PAGE_LOCKS` and `STATISTICS_NORECOMPUTE`. The merged definition does not name the filegroup or partition scheme (the inventory shows it), and pgvigil does not read `OPTIMIZE_FOR_SEQUENTIAL_KEY`: check both before running the text. A disabled index comes back with `ALTER INDEX ... REBUILD`. Findings are raised per database: exact duplicates, unused indexes that are written, unused indexes, and redundant indexes.

### Missing-index requests

Missing-index requests are what the optimizer asked for, one query shape at a time, since the server started. They show the equality, inequality and included columns, how often each was asked for, and the benefit per day of uptime. They are **hints**. They know nothing of the indexes that already exist or of the other requests, so pgvigil never writes them as a `CREATE INDEX`. A request worth 100,000 or more a day of uptime raises an info finding.

### Usage and requests kept per read (task 414)

Each read of `mssql_indexes` keeps what it added, so the Indexes tab charts **User actions over time**: the seeks, scans, lookups and updates each six-hourly read added, for a database or for one index (its row's *trend*). An index that did not move keeps no row; an index read for the first time adds nothing (its counters start the line); after a restart, a restore or the database taken offline or closed, a read adds the whole count. The inventory shows seeks, scans, lookups and updates apart, scans per seek and updates per read. The missing-index requests are kept the same way: **Missing-index requests over time** draws the seeks and scans each read added for the ten requests with the most benefit, beside the newest read's top 10 and its impact-against-requests scatter. A request is the same across reads when its database, table and columns are (the server's handle changes at a restart).

Volume: one row per index that moved, per read: at most instances x indexes x 4 a day (every index of a table written in six hours moves its updates). The rows sit in monthly partitions under the repository's retention.

### Disabled indexes, untrusted keys and constraints (task 414)

A disabled index is listed per database (info). A disabled clustered index is a **warning**: the table can be neither read nor written, and its nonclustered indexes and foreign keys are disabled with it; `ALTER INDEX ALL ON <table> REBUILD` enables them. A disabled primary key or unique index that a foreign key references is a warning too: those foreign keys are disabled with it, and the rebuild does not enable them: each takes `ALTER TABLE ... WITH CHECK CHECK CONSTRAINT` (Microsoft Learn, *Disable Indexes and Constraints*).

The collection `mssql_constraints` (every six hours) reads the untrusted foreign keys and check constraints of each user database: enabled again without `WITH CHECK`, or disabled. The rows written while they were off were never checked, and the optimizer does not use them. NOT FOR REPLICATION ones are left out, and disabled check constraints are counted, not named (dbachecks' rules). `WITH CHECK CHECK CONSTRAINT` reads the whole table: the tab shows it as text to review. Not on Azure SQL Database.

### A histogram on demand (task 414)

A statistic's histogram (its steps: RANGE_HI_KEY, EQ_ROWS, RANGE_ROWS, DISTINCT_RANGE_ROWS) is read when asked, from `sys.dm_db_stats_histogram`, and never stored. The keys are the column's **real values**, so it is **off** until an admin turns it on for the instance in `pgvigil.yaml`:

```yaml
  - name: sql1
    engine: sqlserver
    dsn: env:PGV_SQL1
    histogram: true
    stats_dsn: env:PGV_SQL1_STATS   # optional: the statistics-only login
```

It is read under `query_text: full` only, each read is audited before its answer (Custom reports' log, op `histogram`: who, the instance, the statistic and the step count, never a key value), the answer is sent `no-store`, and it is never an MCP tool, an export or a report mail. `sys.dm_db_stats_histogram` answers only for a login that may SELECT the statistic's columns (or owns the table). Do **not** give that to the read login: custom reports and report mail stay metadata-only because the read login holds VIEW SERVER STATE, VIEW ANY DEFINITION and CONNECT ANY DATABASE and no more. Give it to a separate statistics-only login, named by `stats_dsn` (env: or file: only), used by this read alone:

```sql
CREATE LOGIN pgvigil_stats WITH PASSWORD = '<a strong password>';
-- in each database whose histograms you want, per schema:
CREATE USER pgvigil_stats FOR LOGIN pgvigil_stats;
GRANT SELECT ON SCHEMA::dbo TO pgvigil_stats;
```

On Amazon RDS use the per-database form `ALTER ROLE db_datareader ADD MEMBER pgvigil_stats;` (whether the master user may grant a server-wide right there was not checked). Off below SQL Server 2016 SP1 CU2 (13.0.4422.0), on Azure SQL Database, on a columnstore, XML or spatial index, and on an instance added in Admin > Instances (the file's instances only, as EXPLAIN and the index advisor).

### Fragmentation on demand (task 414)

**Read LIMITED** or **Read SAMPLED** reads `sys.dm_db_index_physical_stats` for one database, when asked, never on a schedule. It reads every index and heap of the database, and a heap's data pages are read in full even in LIMITED (the read login may only ask for every object at once: a single object needs CONTROL on it). SAMPLED reads 1 % of an index or heap of 10,000 pages or more and all of a smaller one. **Show the heap size** gives the database's heap and total size first. It is **off** until an admin turns it on for the instance (`index_fragmentation: true` in `pgvigil.yaml`).

The read is a job of `pgvigil serve`, not tied to the browser's request: the page polls it, **Cancel** ends it on the server, one runs at a time per instance, and a read that loses serve (a restart) reads *stopped* a minute after its last beat. Its lock timeout is 30 s: index maintenance (an offline rebuild, an ALTER) can end it, and the rows read before are kept with where it stopped. It is refused on a secondary replica (its locks can block the redo thread there). Indexes over 30 % fragmented and over 1,000 pages are marked; pgvigil offers no rebuild. Each read is kept with who asked and when.

## Statistics (`mssql_stats`)

For each database the read stores:

- A summary over every statistic: the count, how many were never updated, the oldest and newest update, and the average share of rows modified.
- A row for every statistic on 10,000 rows or more.
- A row for every statistic that is NORECOMPUTE, filtered, has a persisted sample rate, or sits on a partitioned table and is not incremental.

`sys.dm_db_stats_properties` answers only for a login that may SELECT the statistic's columns. For any other statistic, the read falls back on `STATS_DATE` and `sys.sysindexes.rowmodctr`. It then knows no sample rate, and the database's row says so.

| Flag | When |
|---|---|
| stale (warning) | not updated in 30 days, 10 % or more of 10,000 or more rows modified |
| low sample | under 10 % of 10,000 to 1,000,000 rows, under 1 % above |
| persisted sample | a persisted sample rate other than 100 % |
| NORECOMPUTE | never updated automatically |
| filtered | its modification counter counts the whole table |
| not incremental | on a partitioned table |

## What the proof shows

`scripts/proof-mssql-plancache-indexes.sh` runs against a SQL Server 2022 container that it starts and removes (or an existing sandbox it is given). It shows:

- A seeded workload's top statement equals a hand read of `sys.dm_exec_query_stats`.
- (`scripts/proof-mssql-cache-spread.sh`) Every extreme stored for a statement, and for a procedure, equals a hand read of the server's own view; the three diagnostics appear on statements made to show them and stay off a statement held under the rule's 3 executions; the grant finding appears, and is gone once its interval is over three hours old; the filter keeps what a hand read keeps and ranks each database before the 1,000-row cap.
- An exact duplicate and a key subset are found on a fresh server, and an unused index is **not**: the guard says "too early".
- Once the stored window is moved back 10 days in the proof's own repository, the unused index is found, with its DISABLE line.
- The stored modification count of a NORECOMPUTE statistic equals the DMV's. Moved back 40 days, the statistic is stale.
- The import's rules hold for a cut read, counters that went down and a late read.
- The index rules hold on crafted rows: a kept index is never called unused, chained merges give no text, a foreign key's index is never disabled, IGNORE_DUP_KEY survives a merge, an AUTO_CLOSE database is not judged, and a counter reset shortens the window.

It does not show:

- SQL Server 2016 (task 164) to 2019, and 2025.
- RDS (task 165) or Managed Instance.
- A list cut on a real server, or a server with more databases than one run reaches.
- An availability group, or a memory-optimized table.
- The per-day missing-index finding (it needs days of uptime).
- The pages in a browser.
