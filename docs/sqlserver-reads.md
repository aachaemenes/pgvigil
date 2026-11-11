# SQL Server: properties, procedures, index locks

Three collections of the [SQL Server engine](sqlserver.md) and the tabs they feed, and two additions to pages that were already there (the fleet's Running queries and an instance's Waits). Nothing is installed on the monitored server and nothing is written there.

| collection | every | what | the login needs |
|---|---|---|---|
| `mssql_properties` | 1 hour | what the instance is: server, processors, memory, tempdb's layout, host; every change of a value | public; `VIEW SERVER STATE` for the processor, memory and host rows (partial without it) |
| `mssql_procstats` | 5 min | what each stored procedure did between two reads | `VIEW SERVER STATE` (2022: `VIEW SERVER PERFORMANCE STATE` is enough); names of another database's procedures: `CONNECT ANY DATABASE` and `VIEW ANY DEFINITION` |
| `mssql_indexlocks` | 5 min | where sessions waited for locks, per index, and lock escalations | as `mssql_procstats`; names: a database the login can enter |

None of the three runs on Azure SQL Database.

To name procedures and indexes in every database, the monitoring login takes one more grant than [the base login](sqlserver.md#the-login):

```sql
GRANT CONNECT ANY DATABASE TO [pgvigil_monitor];   -- SQL Server 2014 and later; it enters a database, it reads no table
```

Without it the counters are still stored, under the object's id.

## Properties (`mssql_properties`)

One row per property, in five groups (DBA Dash's Info page):

- **Server**: edition, version and level, collation, clustered, Always On enabled, the machine's and the server's name, max degree of parallelism, cost threshold for parallelism (`SERVERPROPERTY`, `sys.configurations`).
- **Processor**: logical CPUs, sockets, cores per socket, the hyperthread ratio, NUMA nodes, soft NUMA, the affinity type, max worker threads, the hypervisor (`sys.dm_os_sys_info`); the schedulers online and offline (`sys.dm_os_schedulers`: an offline scheduler is a CPU the edition's core limit, the licence or an affinity mask keeps SQL Server from using); the power plan.
- **Memory**: the machine's memory, max and min server memory, max server memory as a per cent of the machine (`no limit` while the setting is at its default), the memory model.
- **TempDB**: data files, their size, whether they are one size, log files, log size (`tempdb.sys.database_files`).
- **Host**: platform, distribution, release (`sys.dm_os_host_info`; before SQL Server 2017 `sys.dm_os_windows_info`).

A property the server did not give says **not read** and why: the login lacks the right, the server's version does not have the column (`socket_count`, `cores_per_socket` and `numa_node_count` came with SQL Server 2016 SP2 and 2017; the collector asks the server which columns it has), or the platform has no such thing.

**The power plan** is the one value SQL Server does not hold. On a Windows server someone runs, the collector reads the active power scheme from the registry (`xp_regread` on `HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes`, a read) and names it; a plan other than High performance carries a note. On Linux, Amazon RDS and Azure SQL Managed Instance the row says not read. A login that may not execute `xp_regread` gets not read as well.

**The change history.** The first read of a property sets it. From then on a value that differs from the read before is logged with the old value, the new one and the time of the read that saw it (the change happened within the hour before). tempdb's sizes move by themselves and are shown without being logged. The server's start time is not a property: the DMV writes it in the local clock, and a daylight-saving shift would log a change that never happened.

## Procedures (`mssql_procstats`)

`sys.dm_exec_procedure_stats` counts per cached plan since the plan entered the cache. pgvigil keeps the last counters and stores what one interval added: executions, CPU, duration, logical and physical reads, logical writes, summed per procedure. The page (DBA Dash's Object Execution) shows them over the range as totals, per execution, and per second or minute of the time the range's reads cover; a database filter; the instance's totals over time; and, on a procedure's name, that procedure read by read.

What a figure is, and is not:

- It is what ran **between two reads**. The first read of an instance only sets the starting counters.
- A plan cached since the read before (a new procedure, a recompile, anything after a restart of the server) gives its whole count: all of it ran after the read before. A plan whose counters went down counts whole as well. No interval is ever negative.
- A procedure compiled, run and dropped from the plan cache between two reads is in no read. The executions of a plan the cache dropped since the read before are lost with it. On a server under memory pressure the page undercounts; it never overcounts.
- Stored procedures only. Triggers and functions have their own views and are not collected.
- The server's clock is read before the counters and the cached time is kept in the server's own clock, so "cached since the read before" stays exact through a daylight-saving change.
- The list is cut at the 5,000 plans with the most CPU; the run is `partial` when it is.

The names come from `OBJECT_NAME`, which waits behind a schema change on the object. The collector's session gives up on a lock after two seconds; the read then runs again without the names and the page shows `object <id>` for that interval.

## Index locks (`mssql_indexlocks`)

`sys.dm_db_index_operational_stats` counts per index partition since the index's metadata entered the cache. pgvigil reads the partitions with a lock wait or an escalation attempt, keeps the last counters, and stores what one interval added per index: row lock waits and their milliseconds, page lock waits and theirs, lock escalation attempts and escalations (Darling's Locking & Contention page).

> These are waits that **ended** on an index: where sessions collided. They name no holder. The root cause of a blocking chain is the head's transaction and its last statement, which the [Running queries and Blocked reports](sqlserver-running.md) pages show; an index with many lock waits is a collision path, not a verdict.

- An escalation is the server trading an index's row and page locks for one lock on the whole table, after a statement took about 5,000 locks on it. An attempt that failed (another session held a conflicting lock) is counted as an attempt only.
- The rule for the differences is the procedures' rule: the first read sets; an index new to the list, or one whose counters went down (the metadata left the cache and came back), gives its whole count; nothing is negative.
- The names (schema, table, index, type) are read from each database's own catalog, for the 500 objects per database with the most lock wait. A database the login cannot enter leaves `object <id>` and `index <id>` on the page.
- The list is cut at the 20,000 partitions with the most lock wait. After a cut read, a partition new to the list sets its counters and gives nothing, so a cut never invents a wait.
- Not collected: the page latch and page IO latch counters of the same view (a latch is not a lock; the Waits tab has `PAGELATCH` and `PAGEIOLATCH`), the system base tables (object ids 1 to 100, which no catalog view names), and memory-optimized tables, which the view does not list.

## Running queries at the root: memory grants and tempdb waits

A SQL Server row of the fleet's Running queries page carries, from the instance's newest snapshot (DBA Dash's Running Queries at the root):

- **max memory grant** and **sum of memory grants**: of the requests that hold a grant at the snapshot.
- **tempdb latch waits** and their time: the requests waiting at the snapshot for a page latch on a tempdb page (`PAGELATCH_*` on `2:<file>:<page>`; never `PAGEIOLATCH_*`, which is the disk).
- **tempdb allocation waits** and their time: those of them on an allocation page (PFS: page 1 and every 8,088th; GAM: page 2 and every 511,232nd; SGAM: page 3 and every 511,232nd after it). This is the contention more tempdb data files relieve.

They are waits in progress at one moment, not totals: the instance's Waits tab has what ended. DBA Dash's third pair, waits on the pages of tempdb's system tables (metadata contention), is not shown: the snapshot does not store which object a page belongs to. A PostgreSQL row leaves these cells empty.

## Waits: a description and the rate per core

The Waits tab's grid gains three columns (DBA Dash's Waits):

- **wait time (ms/sec)**: a wait type's time over the seconds the range's reads cover. 1,000 means one task waiting the whole time.
- **wait time (ms/sec/core)**: that, divided by the schedulers that ran user work (`VISIBLE ONLINE`) as the newest CPU read at or before the range's end counted them. Empty where `mssql_cpu` has not run.
- **description**: what the wait means, for about fifty types a DBA meets most; a type without its own text takes its family's (`LCK_M_`, `PAGEIOLATCH_`, `PAGELATCH_`, `LATCH_`, `PREEMPTIVE_`, `HADR_`, `CX`). The texts are pgvigil's own wording.

## Retention

The interval rows (`mssql_proc_sample`, `mssql_proc_read`, `mssql_indexlock_sample`, `mssql_indexlock_read`) are monthly partitions dropped by `purge` with the rest; a property change older than the window is deleted; the properties themselves are one row each and stay.

## Proof

`scripts/proof-mssql-reads.sh`, against a SQL Server 2022 in a Linux container, as a login with `VIEW SERVER STATE`, `VIEW ANY DEFINITION` and `CONNECT ANY DATABASE`, a login with `VIEW SERVER STATE` alone and a login with neither:

- every property against `sa`'s own read of its source; a second read of the unchanged server logs nothing; on the proof's own container, max server memory set once shows as exactly two changes;
- a procedure run 7 times between two reads stored with 7 executions and `sa`'s own rise of CPU, duration and reads; a procedure created between two reads stored with its whole count; after `sp_recompile`, the new plan's count and nothing negative;
- a row lock wait forced on a table (a session holds a row for four seconds, another waits for it) stored on its clustered index with `sa`'s own rise of waits and milliseconds; an escalation forced by one UPDATE of 6,000 rows stored as `sa`'s rise of attempts and escalations;
- the fleet row's grants and tempdb waits on stored rows, and a real memory grant held by a sorting session against `sa`'s read of it;
- the rate per second and per core of the forced lock wait against a division done by hand;
- on imported rows: a restart with lower counters (the whole count, never a negative one), an idle read, a recompile, a cut list, late reads, the property history, the tempdb page arithmetic, the purge;
- the migration chain applied on PostgreSQL 13.

Not proven: a real power plan (it needs a Windows SQL Server), a real tempdb page latch wait, SQL Server 2016 to 2019 (the older `sys.dm_os_sys_info`), Amazon RDS, Azure SQL Managed Instance, a daylight-saving change on a live server, a list long enough to be cut on a real server.
