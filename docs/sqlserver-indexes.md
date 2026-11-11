# SQL Server: plan cache, indexes and statistics

Four collections cover three areas: the statements the plan cache ran, the indexes of every user database, and the health of the optimizer's statistics. Each one only reads. None of them runs a DISABLE, a CREATE or an UPDATE STATISTICS. Any T-SQL the pages show is text for a DBA to read, test and run.

| Collection | Every | What it reads | Rights |
|---|---|---|---|
| `mssql_plancache` | 5 min | `sys.dm_exec_query_stats`: per cached statement, what changed between two reads | `VIEW SERVER STATE` (2022: `VIEW SERVER PERFORMANCE STATE` is enough) |
| `mssql_plancache_health` | 1 h | `sys.dm_exec_cached_plans` and `sys.dm_exec_query_stats`: what the cache holds, per database | as `mssql_plancache` |
| `mssql_indexes` | 6 h | each user database's `sys.indexes`, `sys.index_columns`, `sys.dm_db_index_usage_stats` and `sys.dm_db_partition_stats`; the server's missing-index DMVs | `VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `CONNECT ANY DATABASE`; `SELECT` on `msdb.dbo.restorehistory` for the restore date |
| `mssql_stats` | 6 h | each user database's `sys.stats` with `sys.dm_db_stats_properties` | as `mssql_indexes`; `db_datareader` for the sample rates |

All four run on SQL Server 2016 SP1 and later, on Amazon RDS and on Azure SQL Managed Instance. They do not run on Azure SQL Database yet.

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

The collector does not send every cached statement. It sends the first 500 by CPU, by duration, by logical reads and by executions, plus the first 500 with a memory grant or a spill. When the cache holds more, the read is marked *cut*. After a cut read, a statement that is new to the list gives its whole count only if it was compiled after that read. Otherwise it only sets its counters, because it may simply have been past the cut. Statement texts travel apart, each one once every six hours, and they follow the instance's query-text policy.

The **Plan cache** tab shows:

- The statements of the range, the most CPU first.
- A **database** filter.
- **Only databases without Query Store**, the scope for which the plan cache is the only statement history. Databases with Query Store have a fuller history on the Query Store tab.
- What the cache holds, per database: plans, single-use plans and their size, statements compiled in the last 24, 4 and 1 hours, and statements whose query hash has more than one cached plan.
- Two lists: the largest single-use plans, and the query hashes with the most plans.

Findings (a read older than three hours raises nothing):

| Finding | When |
|---|---|
| most cached plans are recent (warning) | over 75 % of the 1,000 or more cached statements were compiled in the last 24 hours, on a server up for more than a day |
| single-use plans in the cache | single-use ad hoc or prepared plans are over 10 % of a user database's compiled plans (info) or over 75 % (warning), with 100 at least |
| one statement compiled into many plans | statements of a query hash with several plans are over 5 % of a user database's cached statements (info) or over 75 % (warning), with 100 at least |

## Indexes (`mssql_indexes`)

There is one row per index of every user table and indexed view. Each row holds:

- The definition: keys in order with their direction, included columns, the filter, uniqueness, the constraint the index backs, IGNORE_DUP_KEY, fill factor and compression.
- Its size and rows.
- What it was used for: seeks, scans, lookups and writes, with the time of the last read and the last write.

Each database is read and stored on its own. If a database's read fails, the repository keeps what it already holds for it.

### The usage window

The usage counters are kept in memory. They start again whenever:

- the server starts;
- a database is restored;
- a database is created or attached.

The start of a database's window is the latest of those three dates, and the page says which one it was. **No index is called unused before the window is seven days long**: the page says "too early". Under 14 days, an unused verdict carries a warning, because a weekly or monthly job may not have run yet. On an availability group's primary with a readable secondary, reads made on the secondary are counted there and not here. SQL Server keeps no creation date for an index, so the table's last change is named when it is recent.

### The rules

| Rule | What it means | Text shown (never run) |
|---|---|---|
| exact duplicate | the same keys, includes and filter as another index; a constraint is kept first, then a unique index, then the most read | `ALTER INDEX ... DISABLE` |
| duplicate constraint | two constraints on the same keys | none: a foreign key may reference either |
| key subset | its keys are the leading keys of another index | the kept index with this one's includes merged in (`DROP_EXISTING`), then `DISABLE` |
| same keys, other includes | the same keys and filter, other includes | the merged definition, then `DISABLE` |
| constraint doubled | the keys of a unique constraint, plus includes | this index made `UNIQUE`, then the constraint dropped |
| unused, written / unused | no seek, scan or lookup in a window over 7 days (10,000 or more writes: a warning) | `DISABLE` |
| written, seldom read | 10,000 or more writes, under 10,000 reads, ten times more writes than reads | none |
| same keys, another order / same leading column | for review | none |

A merged definition spells out `ONLINE` (as the edition allows), `FILLFACTOR`, `SORT_IN_TEMPDB` and `DATA_COMPRESSION`. A disabled index comes back with `ALTER INDEX ... REBUILD`. Findings are raised per database: exact duplicates, unused indexes that are written, unused indexes, and redundant indexes.

### Missing-index requests

Missing-index requests are what the optimizer asked for, one query shape at a time, since the server started. They show the equality, inequality and included columns, how often each was asked for, and the benefit per day of uptime. They are **hints**. They know nothing of the indexes that already exist or of the other requests, so pgvigil never writes them as a `CREATE INDEX`. A request worth 100,000 or more a day of uptime raises an info finding.

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

`scripts/proof-mssql-plancache-indexes.sh` runs against a SQL Server 2022 container that it starts and removes. It shows:

- A seeded workload's top statement equals a hand read of `sys.dm_exec_query_stats`.
- An exact duplicate and a key subset are found on a fresh server, and an unused index is **not**: the guard says "too early".
- Once the stored window is moved back 10 days in the proof's own repository, the unused index is found, with its DISABLE line.
- The stored modification count of a NORECOMPUTE statistic equals the DMV's. Moved back 40 days, the statistic is stale.
- The import's rules hold for a cut read, counters that went down and a late read.

It does not show:

- SQL Server 2016 to 2019.
- RDS or Managed Instance.
- A list cut on a real server.
- The pages in a browser.
