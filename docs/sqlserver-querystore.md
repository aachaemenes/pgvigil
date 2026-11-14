# SQL Server: Query Store

One collection of the [SQL Server engine](sqlserver.md), `mssql_querystore` (hourly), and the Query Store tab it feeds. Nothing is installed on the monitored server and nothing is written there: pgvigil forces no plan, clears no store and changes no option.

## What is read

For every database except `master`, `tempdb` and database snapshots:

- The store's own state (`sys.database_query_store_options`): the state asked for and the state it is in, why it is read-only, its size against its limit, the capture mode, the cleanup mode, the interval length and the other options.
- The database's automatic tuning options (`sys.database_automatic_tuning_options`, SQL Server 2017 and later).

For a store that holds data (READ_WRITE or READ_ONLY), in two steps:

1. The intervals to read, from `sys.query_store_runtime_stats_interval`: every interval that ended after the start of the newest interval the repository holds for the database, the oldest first, 200 intervals a run. The newest stored one is read again each time, because it was still open. A first read starts 24 hours back; no read starts more than 7 days back. A backlog longer than 200 intervals (a first read of a store with 1-minute intervals, a collector that was stopped for days) is read over the following runs, each going on where the one before ended.
2. The runtime statistics and the wait statistics of those intervals only (`sys.query_store_runtime_stats`, `sys.query_store_wait_stats`, filtered by the first and last interval id), summed per plan and interval on the server. Only the plans in an interval's first 50 by total duration, by CPU, by logical reads, by largest memory grant or by wait time leave the server, together with the interval's totals over every plan.

Then, for those plans by their ids, and for every forced plan: the plan's properties, its query's hash, object and text (`sys.query_store_plan`, `sys.query_store_query`, `sys.query_store_query_text`), and the plan's showplan XML once (the repository says which plans it already holds). Last, the automatic tuning recommendations (`sys.dm_db_tuning_recommendations`, 2017 and later; the first 200 by score).

### What a run costs the server

The store's history never leaves the server, and text, plans and plan XML are read for the candidate plans alone. Inside the store the access paths have not been looked at (not proven: no proof reads the plans of the collector's statements). SQL Server keeps the runtime statistics clustered by plan, not by interval (read on SQL Server 2022: `plan_id, runtime_stats_interval_id, execution_type`), so the filter on the interval can make SQL Server read the store's runtime statistics table through once per database and run, as SSMS's own Query Store reports and `sp_QuickieStore` do. That table is bounded by the store's `MAX_STORAGE_SIZE_MB`; on a store of many gigabytes the hourly read is a real read, and the collection's interval can be raised or the collection switched off per instance.

Each read is one SELECT run through that database's `sys.sp_executesql`; it changes no session setting. The collector's own statements run inside the database and are captured by its Query Store like any other session's: two to seven short statements per database a run.

### Bounds of one run

- A run has five minutes on the server. It takes no further database once it carries 60,000 rows (one database adds at most 200 intervals of 250 plans each) or once its deadline is near; it then says `partial`, and the databases it left out are the first of the next run (the databases the repository holds least of are always read first).
- Plan XML: 100 plans per database and 64 MB over all databases a run, 4 MB a plan. A plan over 4 MB is listed without its XML and says so. A plan put off by the other two bounds is stored without its XML, silently, and is asked for again the next time it is among an interval's top plans or while it is forced.
- A database whose read fails part-way stores nothing of its intervals in that run; the next run reads the same intervals again.

## What the list can miss

A window's list is exact for the plans that were stored. A query that stayed under all five cuts of every interval it ran in is not stored: it is in the interval's totals and not in the list. The Top view says what share of the window's duration, CPU and executions its rows hold.

## Rights

| Right | Without it |
| --- | --- |
| `VIEW SERVER STATE` | The collection is skipped. It is `VIEW DATABASE STATE` in every database, which the Query Store views need. |
| `CONNECT ANY DATABASE`, or a user in the database | That database is listed as `not read` with this reason. When the login can enter none of the users' databases (`msdb`, which any login enters as guest, does not count) the run says `partial` and names the grant. |
| `VIEW ANY DEFINITION`, or `VIEW DEFINITION` in the database | The object a statement belongs to (`schema.procedure`) is expected to come back empty: SQL Server shows an object's name only to a login that may see its definition. Not run without the right. |

## Versions and platforms

| Server | Read |
| --- | --- |
| SQL Server 2016 SP1 | the store's state and contents; no wait statistics, no forcing type, no automatic tuning (not proven: task 164) |
| SQL Server 2017 | the above with wait statistics, the forcing type, automatic tuning |
| SQL Server 2019 and later | the above with the custom capture policy's four thresholds |
| Azure SQL Managed Instance, Amazon RDS | as their engine version (not proven: RDS is task 165; Managed Instance not proven) |
| Azure SQL Database | not yet: the collection is skipped |

Proven on SQL Server 2017, 2019, 2022 and 2025 (`scripts/proof-mssql-querystore.sh`, [versions](sqlserver.md#versions)). The column set of 2016 follows Microsoft's documentation and has not been run (task 164); nor have Amazon RDS (task 165), a managed instance, or a secondary replica that is not readable.

## The statement text and the plan XML

The instance's `query_text` policy applies before anything leaves the collector:

| Policy | Query text | Plan XML |
| --- | --- | --- |
| `full` | as the store holds it, 16,000 characters at most | stored; the tab offers it as a `.sqlplan` download |
| `normalized` | literals replaced by `?`, comments dropped | not stored: a showplan carries the statement and the compiled parameter values |
| `none` | not stored | not stored |

The query hash and the plan hash are SQL Server's own and are stored under every policy; they carry no text. A policy tightened later takes effect at each database's next read: the stored query texts are replaced, and every plan XML stored for the database under the wider policy is dropped (its download then answers 404). Under `normalized` and `none` the collector still reads a plan's XML from the server once a day to look at it, and discards it.

## The Query Store tab

A window takes every interval of the store that overlaps it: with 60-minute intervals the last hour at 10:20 is the intervals of 09:00 and 10:00. The database list narrows every view but Store state.

- **Top**: the window's totals over every plan (executions, duration, CPU, logical reads, wait time) and the first 100 queries by duration, CPU, logical reads, memory grant, waits or executions, each with its share of the window's total. A query's `Open` shows its text, its plans in the window's stored rows (executions, average and maximum duration, average CPU and reads, the largest memory grant, forced or not) with a `Download .sqlplan` per plan, and each plan's average duration and CPU per interval as a line, with the numbers as a table. Over the grid, PerformanceMonitor's strip: the store's duration per step of the window; a drag across it (or a click, or the keyboard) reads the grid again for that stretch, widened to whole steps of the store's intervals, its shares of that stretch's own totals; a row's `Draw` puts that query's average duration per interval on the strip as a line.
- **Regressed** (PerformanceMonitor 3.12.0's Query Store regressions, MIT, beside pgvigil's own test): one row per query, the window against a baseline: by default PerformanceMonitor's 7 days before the window; or the window of equal length before it, or the same window 24 or 168 hours earlier. A row of the store (one kept plan in one interval) is placed by its last run, as PerformanceMonitor places it: in the window when its interval overlaps the window and it ran last at or after the window's start, in the baseline when it ran last inside the baseline (so a run before the window never counts in it). With Yesterday or Last week over a range longer than the shift the baseline overlaps the range, and the page says so. A query is listed for **cost** (its Regular CPU per run more than 25 % above the baseline's, adding at least 1 s of CPU over the window), **timeouts** or **errors** (at least 3 Aborted or Exception runs in the window and at least twice the baseline's rate per hour, or any where the baseline had none; per hour over each window's clock hours from its start, or from the database's first stored interval when that is later), or **duration** (pgvigil's: one of its plans averages 1.5 times the query's average duration or CPU over the baseline, or more, and at least 1 ms). Severity and the columns are PerformanceMonitor's. Aborted is SQL Server's execution_type 3, a client abort: a timeout or a cancel; Exception (4) a run that ended in an error. Rows stored before pgvigil kept the two apart (migration 0126) read "not read apart", and the cost, timeouts and errors tests are not applied to their query. A query in no kept row of the baseline reads "no kept baseline".
- **Compare** (under Top, and under the Plan cache and Procedures grids; PerformanceMonitor's compare): the window against the same span earlier (Previous period, Yesterday = 24 hours, Last week = 168 hours, as UTC instants: across a change of the clocks the earlier window reads an hour off on the wall clock, and both windows are printed in UTC and the viewer's zone), by database and query hash (procedures by database and name), each row placed by its last run as in Regressed: executions, average duration and average CPU before and now with the change in percent, PerformanceMonitor's colours, each window's first 100 by duration. Query Store keeps each interval's top plans only: a query is **new** when its first plan was compiled after the earlier window, "not kept before" when it has no kept row then but was compiled earlier, "not kept now" when it has no kept row in the window. The plan cache says NEW / GONE only when no read of either window, nor the read just before each, was cut, otherwise "not kept before / now" with the count of cut reads. "No data for the comparison window" when nothing was stored for it.
- **Forced plans**: every forced plan as the last read found it, with the forcing type, the failure count and the last failure's reason.
- **Tuning** (proven on demo and written rows only: no real recommendation was read): SQL Server's own plan-regression recommendations with their state, score and script, and each database's automatic tuning options. A restart of SQL Server empties the server's list; a recommendation it stopped listing inside the window stays, marked so. The statement beside a recommendation is the store's current query of that number. First seen and Last seen are the first and the last read that listed the recommendation (PerformanceMonitor's columns; its Captures count is not kept).
- **Store state**: one row per database: desired and actual state, the read-only reason spelled out, capture mode, cleanup mode, sizes, intervals and the capture policy. Under the grid, what each flagged state means; the checks at the top of the page say the same while the store's read is under three hours old.

A cleared store (`ALTER DATABASE ... SET QUERY_STORE CLEAR`) numbers its queries and plans again from 1. Rows read before the clear keep the hashes they were read with and never show the text of the query that took their number; they show without text. A plan number that comes back under another query loses the XML stored for it.

## The Queries page

The Performance row's Queries tab (in Plan cache's place: the full Plan cache grid keeps its address and opens from the page) is PerformanceMonitor 3.12.0's Queries view in its section order, on what pgvigil stores. Each section reads when it first comes into view, by itself, and the page is not refreshed every 30 s.

- **Active queries**: the requests per Running snapshot as a strip, and the first 10 requests of the newest snapshot; a drag on the strip shows the snapshot at the end of the stretch (a newer drag's answer wins). A range with no Running snapshot says so, never an older snapshot's requests. Links to Running queries.
- **Query duration trend** and **Executions per second**: the plan cache's duration and CPU (ms per second) and its executions per second over every cached statement.
- **Top queries (plan cache)**: the Plan cache grid's first 10, with a `History` per row; the `Query` list draws the same chart for any of the first 100: the query's average duration and CPU per execution in about 120 steps of the window, each weighted by its executions (a step without a run is a gap; reads cut at the collector's lists are counted under the chart). The Plan cache tab has the same `History` per row.
- **Query Store**: its strip and its first 10 queries by duration (the Top view's strip and `Draw`, as above).
- **Regressions**: Regressed's first 10 against PerformanceMonitor's baseline, the 7 days before the window.
- **Query heatmap** (PerformanceMonitor's, from the plan cache's stored reads): bins of 5 minutes and more, aiming at 144 columns over the window (10 minutes at 24 hours, 70 at 7 days), by seven log10 buckets of Duration (ms), CPU (ms), Logical Writes or Execution Count per read. A cell counts the distinct queries (database and query hash) whose reads fell in it: PerformanceMonitor counts its 1-minute rows, so its counts run higher, and a query that ran at two speeds in one bin counts in both cells. PerformanceMonitor's legend (none, 1, eight shades on a log scale against the busiest cell's count) and its words for a cell (`<time> | Duration 100ms-1s | 1 query`); an empty cell is outlined, never the lightest shade, and an empty range says whether no plan-cache read was taken or no query ran. A picked cell names its most-executed query and opens Running queries at the bin's middle with `Show Active Queries at This Time` (the hour around it; Running shows the snapshot at or before that time, or the hour up to it when the hour holds none); `Show as table` switches the picture for the table of every cell with the same link (a phone-width window opens on the table; the pick is kept). Whole columns are kept, newest first, up to 1,000 cells; the page names how many older columns are left out and when the drawn part starts. 7 days is the reach, and a window whose reads stored more than about 6 million samples (2,016 reads x 3,000, the collector's ceiling) is refused with its own count in the heatmap's place. One read over every stored row of the window: about 2 s over 7 days at 761 statements a read and 8 s at 3,000 on the proof's 16-CPU box; a read past the 15 s statement timeout shows "the heatmap's read took too long for this range: pick 24 hours or less".
- **Query Store overhead**: Query Store's own waits from the stored one-minute wait deltas, every QDS_* type but PerformanceMonitor's four sleep waits, in ms per hour over the seconds the window's wait reads cover; and PerformanceMonitor's line on its memory clerk, MEMORYCLERK_QUERYDISKSTORE (latest, largest, and whether the newest read held it among its 25 largest clerks). Per server, never per database.
- **Long completions**: the Slow queries tab's first 10 statement shapes (pgvigil's capture: 1 s; PerformanceMonitor's: 2 s).
- **Plan corrections and automatic tuning**: the Tuning view's first 10 recommendations with First seen and Last seen, and the options.

On the Procedures tab a strip over the grid draws every procedure's duration per step; a drag reads the grid again for the stretch (whole five-minute reads), and a procedure opened by its name draws its own Duration (ms/s) on it, with its chart under its reads in PerformanceMonitor's four metrics (Avg Duration (ms), Avg CPU (ms), Duration (ms/s), Executions (per second)). On Running queries a strip of the requests per snapshot steps the snapshot slider to the end of a dragged stretch, and `wait=<wait type>` in the address (the Waits page's `requests` link beside each wait type) lists only the requests waiting on it, with `Show all active queries` to clear it.

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
| a forced plan fails | warning | a plan is forced, SQL Server has counted a failure to force it, and the query last ran more than ten seconds after its forced plan did (or the forced plan never ran): the query runs with another plan now. The failure counter alone is not the rule: SQL Server resets it only when the plan is forced anew. |

## What is kept

The current state per database; one row per interval and one per kept plan and interval, in monthly partitions; the queries, plans and recommendations as last read.

How long (`pgvigil purge`, 30 days by default): the interval and runtime partitions go by whole months once the month is past the window. A query or a plan that no read has listed within the window goes once no kept runtime row names it, so a runtime row never loses its text. A forced plan, and a recommendation still marked present, stay while their database's store is listed: a store pgvigil no longer reads (OFF, ERROR, a database the login cannot enter) keeps showing them. Any other recommendation goes when no read has listed it within the window. The store's state and its tuning options go with their instance.
