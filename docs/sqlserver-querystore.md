# SQL Server: Query Store

One collection of the [SQL Server engine](sqlserver.md), `mssql_querystore` (hourly), and the Query Store tab it feeds. Nothing is installed on the monitored server and nothing is written there: pgvigil forces no plan, clears no store and changes no option.

## What is read

For every database except `master`, `tempdb` and database snapshots:

- The store's own state (`sys.database_query_store_options`): the state asked for and the state it is in, why it is read-only, its size against its limit, the capture mode, the cleanup mode, the interval length and the other options.
- The database's automatic tuning options (`sys.database_automatic_tuning_options`, SQL Server 2017 and later).

For a store that holds data (READ_WRITE or READ_ONLY), in two steps:

1. The intervals to read, from `sys.query_store_runtime_stats_interval`: every interval that ended after the start of the newest interval the repository holds for the database. The newest one is read again each time, because it was still open. A first read goes 24 hours back; no read goes more than 7 days back or takes more than 200 intervals.
2. The runtime statistics and the wait statistics of those intervals only (`sys.query_store_runtime_stats`, `sys.query_store_wait_stats`, filtered by the oldest interval's id), summed per plan and interval on the server. Only the plans in an interval's first 50 by total duration, by CPU, by logical reads, by largest memory grant or by wait time leave the server, together with the interval's totals over every plan.

Then, for those plans by their ids, and for every forced plan: the plan's properties, its query's hash, object and text (`sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`), and the plan's showplan XML once (the repository says which plans it already holds). Last, the automatic tuning recommendations (`sys.dm_db_tuning_recommendations`, 2017 and later).

The store's history is never read whole. Each read is one SELECT run through that database's `sys.sp_executesql`; it changes no session setting. The collector's own statements run inside the database and are captured by its Query Store like any other session's: three to six short statements a run.

One run carries 60,000 rows and 64 MB of plan XML at most over all databases. A run that reaches either bound, or its five-minute deadline, says `partial` and leaves the remaining databases to the next run, which reads on from the repository's cursors. A plan over 4 MB of XML is listed without its XML.

## What the list can miss

A window's list is exact for the plans that were stored. A query that stayed under all five cuts of every interval it ran in is not stored: it is in the interval's totals and not in the list. The Top view says what share of the window's duration, CPU and executions its rows hold.

## Rights

| Right | Without it |
| --- | --- |
| `VIEW SERVER STATE` | The collection is skipped. It is `VIEW DATABASE STATE` in every database, which the Query Store views need. |
| `CONNECT ANY DATABASE`, or a user in the database | That database is listed as `not read` with this reason. When the login can enter no database at all the run says `partial` and names the grant. |

## Versions and platforms

| Server | Read |
| --- | --- |
| SQL Server 2016 SP1 | the store's state and contents; no wait statistics, no forcing type, no automatic tuning |
| SQL Server 2017 | the above with wait statistics, the forcing type, automatic tuning |
| SQL Server 2019 and later | the above with the custom capture policy's four thresholds |
| Azure SQL Managed Instance, Amazon RDS | as their engine version |
| Azure SQL Database | not yet: the collection is skipped |

Proven on SQL Server 2022 only (`scripts/proof-mssql-querystore.sh`). The column sets of 2016, 2017 and 2019 follow Microsoft's documentation and have not been run.

## The statement text and the plan XML

The instance's `query_text` policy applies before anything leaves the collector:

| Policy | Query text | Plan XML |
| --- | --- | --- |
| `full` | as the store holds it, 16,000 characters at most | stored; the tab offers it as a `.sqlplan` download |
| `normalized` | literals replaced by `?`, comments dropped | not stored: a showplan carries the statement and the compiled parameter values |
| `none` | not stored | not stored |

The query hash and the plan hash are SQL Server's own and are stored under every policy; they carry no text. A policy tightened later replaces a query's stored text at its next read. A plan XML stored while the policy was `full` stays until the plan's row is purged.

## The Query Store tab

A window takes every interval of the store that overlaps it: with 60-minute intervals the last hour at 10:20 is the intervals of 09:00 and 10:00. The database list narrows every view but Store state.

- **Top**: the window's totals over every plan (executions, duration, CPU, logical reads, wait time) and the first 100 queries by duration, CPU, logical reads, memory grant, waits or executions, each with its share of the window's total. A query's `Open` shows its text, its plans that ran in the window (executions, average and maximum duration, average CPU and reads, the largest memory grant, forced or not) with a `Download .sqlplan` per plan, and each plan's average duration and CPU per interval as a line.
- **Regressed**: a plan whose average duration or CPU in the window is 1.5 times its query's average in the window of equal length before it, or more. The average before is over all the query's plans, so a new plan is weighed against what the query cost before. A query that was in no interval's first 50 before has nothing to be weighed against and is not listed.
- **Forced plans**: every forced plan as the last read found it, with the forcing type, the failure count and the last failure's reason.
- **Tuning**: SQL Server's own plan-regression recommendations with their state, score and script, and each database's automatic tuning options. A restart of SQL Server empties the server's list; a recommendation it stopped listing inside the window stays, marked so.
- **Store state**: one row per database: desired and actual state, the read-only reason spelled out, capture mode, cleanup mode, sizes, intervals and the capture policy.

A cleared store (`ALTER DATABASE ... SET QUERY_STORE CLEAR`) numbers its queries and plans again from 1. Rows read before the clear keep the hashes they were read with and never show the text of the query that took their number; they show without text.

## The Summary's QS cell and the findings

The cell counts databases, per instance:

| Store | Cell |
| --- | --- |
| in the `ERROR` state | critical |
| `READ_ONLY`, asked for or not | warning, with the reasons; nothing when the only reasons are a read-only database or a secondary replica |
| `OFF` though another state was asked for | warning |
| `OFF` and not asked for | nothing: a choice |
| not read by the last run | nothing; the row says why |

Findings, each for three hours after the read that raised it:

| Finding | Severity | Rule |
| --- | --- | --- |
| Query Store in the ERROR state | critical | the store's actual state is `ERROR` |
| Query Store is read-only | warning | as the cell above |
| Query Store is off though asked for | warning | as the cell above |
| Query Store near its max size | info | a `READ_WRITE` store at 90 % of its max size with size-based cleanup off: it goes read-only when full |
| a forced plan fails | warning | a plan is forced and its failure count is above 0; the detail gives the last reason |

## What is kept

The current state per database; one row per interval and one per kept plan and interval, in monthly partitions; the queries, plans and recommendations as last read.
