# SQL Server: running queries, blocking and waits

Two collections run every minute on a [SQL Server instance](sqlserver.md): `mssql_requests` (what runs now, and who blocks whom) and `mssql_waits` (what the server waited on since the last read). Both need `VIEW SERVER STATE` and nothing else; without it they are skipped with that reason. Nothing is installed on the monitored server and nothing is written there, but for a session temp table on the sp_WhoIsActive path (below).

## Running queries (`mssql_requests`)

One row per session (pgvigil's own left out) that

- is a user session running a request, or
- is a user session holding an open transaction (a sleeping one too), or
- blocks another session, whatever it is (a sleeping session without a transaction still holds its database lock; a system session can head a chain).

A row carries the session and request, the status and command, the wait type, wait time and wait resource, the blocking session, the open transaction count, the transaction id, the transaction's start and the log bytes it wrote, the isolation level, CPU, physical reads, writes, logical reads, the granted memory, the tempdb pages of the request (allocated, and still held), the degree of parallelism, the login, host, program and database names, the `sql_handle`, `plan_handle`, `query_hash` and `query_plan_hash`, the percent complete (a backup or a restore shows its progress), and the session's own three largest waits since it logged in (`sys.dm_exec_session_wait_stats`).

**The statement.** For a request it is the statement that runs now, cut from its batch by the request's offsets on the server. For a session without a request it is the session's input buffer: its last batch. Text is stored once per instance, handle and offsets (`mssql_statement_text`); a minute's rows carry a key. A trivial statement the server auto-parameterises shows in its parameterised form (`(@1 int,@2 tinyint)UPDATE [dbo].[t] set [v] = [v]+@1 WHERE [id]=@2`): that is the text the request's handle names. A statement longer than 16,000 characters is cut there and its real length kept. The instance's `query_text` policy applies: `normalized` stores the text with its literals replaced, `none` stores the key with no text.

**A parallel request.** `sys.dm_exec_requests` keeps CPU, reads and writes for the coordinator task alone. The row keeps those numbers, marked "(coordinator)" on the page, and beside them the task count and the CPU and physical IO summed over the request's tasks (`tasks_cpu_ms`, `tasks_physical_io`, from `sys.sysprocesses`, one row per task). Not on Azure SQL Database, which does not offer that view.

**Every time is UTC**, moved on the server by its own offset at the read, and the snapshot keeps the server's own clock beside the collector's. Durations (a wait, a request's elapsed time, a transaction's age) are the server's own numbers, so a clock difference between the two machines does not distort them.

### The blocking chain

Each snapshot's chain is built from its own rows by one rule:

> The head is the session that blocks others and does not itself wait behind a session. The root cause of a chain is the head's transaction and its last statement, never the object its victims wait on.

- A blocked row carries its head's session and its depth (1 directly behind the head, 2 behind that).
- The head's row carries the number of sessions behind it, at any depth, and the longest wait among them.
- A head that is `sleeping` with an open transaction is an application that left its transaction open. Its statement is its last batch: read it, it points at the code that did not commit.
- A blocker that is not a session is no session to wait behind, and the row says which case it is: `-2` an orphaned distributed transaction, `-3` a deferred recovery transaction, `-4` and `-5` a latch whose owner the server does not name. A session that waits only behind one of these still heads the sessions behind it, and the chain says what the head itself waits on.
- A chain that closes on itself (a deadlock the server has not resolved yet) is marked as a cycle on its members; the sessions behind it carry a note.

`mssql_blocking` holds one row per snapshot and head: the victims, the longest wait, the head's status, login, host, program, database, its transaction's start and age, and its statement.

### sp_WhoIsActive

Where a DBA has installed [sp_WhoIsActive](https://github.com/amachanic/sp_whoisactive) in `master`, or in the database the instance's connection string names (`database=`), and the monitoring login may execute it, pgvigil calls it instead of reading the session list itself:

```sql
EXEC sp_WhoIsActive @get_transaction_info = 1, @get_outer_command = 1, @find_block_leaders = 1, @format_output = 0,
     @destination_table = '#pgvigil_wia';   -- a session temp table made from the procedure's own @return_schema
```

The procedure decides which sessions are listed and gives the statement, the blocker, the transaction's start and the counters it sums itself. What it does not return (the handles and hashes, the wait resource, the isolation level, the granted memory) and what it can leave empty (the percent complete) is completed from the DMVs, joined by session id and request id. The chain is built by the same rule either way. Every snapshot says which source ran (`dmv` or `sp_whoisactive`) and why.

pgvigil does not install the procedure, ship it or copy any of it (it is GPL-3.0; pgvigil is MIT). To let the login call an existing one:

```sql
USE master;   -- or the database it lives in
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];
GRANT EXECUTE ON dbo.sp_WhoIsActive TO [pgvigil_monitor];
```

If the call fails (an old version without one of the parameters), the DMV read runs in the same minute and the collection is `partial` with the procedure's error.

## Waits (`mssql_waits`)

`sys.dm_os_wait_stats` counts since the server started, so pgvigil keeps the last counters and stores the difference between two reads: the waits that ended in that minute, their wait time, and the signal part of it (time spent runnable, waiting for a CPU). On Azure SQL Database the source is `sys.dm_db_wait_stats`.

- A wait is counted when it **ends**. A session that has waited ten minutes on a lock is on the Running queries tab now and in the waits once its wait is over.
- The first read of an instance, the first after a restart and the first after someone cleared the counters (`DBCC SQLPERF('sys.dm_os_wait_stats', CLEAR)`) store no difference.
- The waits of idle background work (a queue reader waiting for work, a timer, `WAITFOR`) are stored like the others and kept out of the shares and the chart: by sheer time they would outweigh every real wait.
- A wait type the DBA reads first carries a category: Locking, CPU, Memory, Disk, Parallelism, Transaction log and so on.

## Pages

- **Running queries**: the newest snapshot as a grid, a slider (with Earlier, Later and Latest buttons) over the kept minutes of the time range, and the blocking chains as a tree with the head first.
- **Waits**: the wait time, the tasks waiting on average, the signal share and the lock share of the range; the eight largest wait types over time as a stacked chart with its numbers in a table; every wait type in a grid.

## Findings

From the newest snapshot of an instance, when it is at most five minutes old (`mssql_running_findings`):

| Finding | When | Severity |
|---|---|---|
| a blocking chain | a head whose victims wait over 30 s; over 5 min | warning; critical |
| a session idle in a transaction over an hour holding locks | a sleeping session whose transaction began over an hour ago and that wrote to the log, or heads a chain | warning |
| a request running over an hour | a user request older than an hour that is not parked on an idle wait | info |
| memory grants pending | a request waits for a memory grant at the read | warning |

"Holding locks" is judged by the log the transaction wrote (a write holds its locks until the commit) or by a session waiting behind it; a transaction that only read under REPEATABLE READ or SERIALIZABLE holds locks too and is not found by this rule.

## What it stores, and how much

| Table | Rows | Kept |
|---|---|---|
| `mssql_requests_summary` | one per snapshot | as long as its day of `mssql_requests` |
| `mssql_requests` | one per listed session and snapshot, daily partitions | whole days dropped past the retention |
| `mssql_statement_text` | one per instance, handle and offsets | until not seen for the retention and no kept row names it |
| `mssql_blocking` | one per head and snapshot, monthly partitions | the retention |
| `mssql_wait_sample` | one per wait type that moved and read, monthly partitions | the retention |

A row of `mssql_requests` carries no text and keeps its handles as binary. The size grows with the sessions listed each minute; not measured.

## One run by hand

```
pgvigil collect -config pgvigil.yaml -once mssql_requests -instance sales-sql01
pgvigil collect -config pgvigil.yaml -once mssql_waits -instance sales-sql01
```

## Proof

`scripts/proof-mssql-running.sh` runs against a SQL Server container and a PostgreSQL sandbox as a least-privilege login of its own. It opens three sessions in its own database: one updates a row inside a transaction and goes to sleep, a second waits behind it, a third behind the second. The snapshot names the sleeping session as the head (depth 0) with its last batch, the two victims at depths 1 and 2 with the wait time within the tolerance; the handles read back as 0x text and join the text table; the statement cut by its offsets equals the statement; the finding fires once the wait passes 30 s; after the head commits the next snapshot holds no chain. The same chain is read through sp_WhoIsActive where it is installed. A `WAITFOR` the proof runs appears in the waits under its type; a read whose counters went down stores nothing; a login without VIEW SERVER STATE is skipped with the reason; an old day is purged.

Proven on SQL Server 2017, 2019, 2022 and 2025 in Linux containers ([versions](sqlserver.md#versions)). Not proven: SQL Server 2016 (task 164, on a Windows host), Azure SQL Database (its database filter and `sys.dm_db_wait_stats`) and RDS (task 165), Managed Instance, the task sums on a real parallel plan, a MARS session, a blocker that is not a session, and anything on Windows (task 144). The cost of the read: 91 to 136 ms with 3,000 sessions each holding an open transaction, measured once by hand as sa (`scripts/proof-mssql-running.sh` part H prints it); not measured at 10,000 sessions.

## Sources

The snapshot's shape is ported from DBA Dash's `SQLRunningQueries.sql` (MIT, Copyright 2022 Trimble, Inc.). The list of idle background waits is the rows marked ignorable in sp_BlitzFirst's wait categories (SQL Server First Responder Kit, MIT, Copyright (c) 2022 Brent Ozar Unlimited). The wait categories are sp_PressureDetector's wait list (DarlingData, MIT, Copyright (c) 2021 Darling Data, LLC). sp_WhoIsActive is called, never copied.
