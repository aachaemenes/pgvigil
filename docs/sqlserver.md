# SQL Server instances

pgvigil can hold SQL Server instances beside its PostgreSQL fleet as an engine of its own: its own collector, its own tables in the same repository, its own pages. This page is the base every collection stands on (the engine, the configuration, the login) and the list of what is collected; each group of collections has a page of its own.

The [DBA Dash door](dbadash.md) is a different thing: it shows what a DBA Dash repository already knows. The engine reads the SQL Server itself.

## What the base does

- An instance says `engine: sqlserver`; everything else is PostgreSQL, as before.
- Only SQL Server collections run on a SQL Server instance and only PostgreSQL collections on a PostgreSQL one. A SQL Server collection is named `mssql_<what>`. Naming a collection of the other engine under an instance's `schedules:` or `disabled:` is refused when the file is read.
- The collector asks the server what it is (a server someone runs, Amazon RDS, Azure SQL Managed Instance, Azure SQL Database) and what the login may read (VIEW SERVER STATE, VIEW ANY DEFINITION, msdb) before each collection. A collection that does not apply there is skipped with the reason, never failed.
- Nothing is installed on the monitored server and nothing is written there. The collector's session gives up on a lock after two seconds, loses any deadlock it is part of and reads without shared locks, so it cannot join a blocking chain. The one door that changes anything is the [actions door](sqlserver-actions.md), off until an instance opens it with a login of its own.

## Collections

Twenty-two collections. `every` is the default; an instance's `schedules:` changes it and `disabled:` switches one off.

| collection | every | reads | needs | Azure SQL Database | page |
| --- | --- | --- | --- | --- | --- |
| `mssql_instance` | 1 hour | the server's description (version, edition, update level, collation, clustered, Always On enabled), every row of `sys.configurations` with the previous value and the time a value in use changed, the CPU count, memory and start time | nothing for the first two; VIEW SERVER STATE for the third (partial without it) | runs | this page |
| `mssql_services` | 5 min | is SQL Server Agent running, is Database Mail started, the memory dump files | VIEW SERVER STATE | not run | this page |
| `mssql_requests` | 1 min | what runs now and who blocks whom | VIEW SERVER STATE | runs | [running queries](sqlserver-running.md) |
| `mssql_waits` | 1 min | the wait counters, as the difference between two reads | VIEW SERVER STATE | runs (the database's own waits) | [running queries](sqlserver-running.md) |
| `mssql_xe` | 1 min | the Extended Events sessions a DBA created from pgvigil's script: deadlocks, blocked-process reports, slow batches, cancelled requests, availability group events | VIEW SERVER STATE | runs (database-scoped sessions) | [Extended Events](sqlserver-xe.md) |
| `mssql_ag` | 1 min | Always On availability groups | Always On enabled, VIEW SERVER STATE, VIEW ANY DEFINITION | not run | [availability, jobs, backups](sqlserver-hadr.md) |
| `mssql_mirroring` | 1 min | database mirroring | VIEW SERVER STATE for the queues | not run | [availability, jobs, backups](sqlserver-hadr.md) |
| `mssql_logshipping` | 5 min | msdb's log shipping monitor tables | a user in msdb with db_datareader | not run | [availability, jobs, backups](sqlserver-hadr.md) |
| `mssql_replication` | 5 min | the distribution database, on a distributor | a user in the distribution database with db_datareader | not run | [availability, jobs, backups](sqlserver-hadr.md) |
| `mssql_jobs` | 5 min | SQL Server Agent: jobs, steps, schedules, what runs now, the history | a user in msdb with db_datareader | not run | [availability, jobs, backups](sqlserver-hadr.md) |
| `mssql_backups` | 1 hour | every database's last full, differential and log backup | a user in msdb with db_datareader | not run | [availability, jobs, backups](sqlserver-hadr.md) |
| `mssql_storage` | 1 hour | every database file with its size, growth and volume | VIEW ANY DEFINITION; VIEW SERVER STATE for the volumes | not run yet | [storage and row versions](sqlserver-storage.md) |
| `mssql_versionstore` | 1 min | tempdb's version store and the transaction that holds it | VIEW SERVER STATE | not run yet | [storage and row versions](sqlserver-storage.md) |
| `mssql_cpu` | 1 min | CPU (the scheduler monitor ring buffer), scheduler pressure, batch requests / compilations / transactions per second | VIEW SERVER STATE (2022: VIEW SERVER PERFORMANCE STATE is enough) | not run | [CPU, memory, file IO, tempdb](#cpu-memory-file-io-and-tempdb) |
| `mssql_memory` | 1 min | the machine's and the server's memory, the memory clerks, memory grants, Page life expectancy | as `mssql_cpu` | not run | [CPU, memory, file IO, tempdb](#cpu-memory-file-io-and-tempdb) |
| `mssql_fileio` | 1 min | read and write latency and bytes per database file, as the difference between two reads | as `mssql_cpu`; VIEW ANY DEFINITION for the files' names and types (partial without it) | not run | [CPU, memory, file IO, tempdb](#cpu-memory-file-io-and-tempdb) |
| `mssql_tempdb` | 1 hour | tempdb's layout: files, sizes, growth, the CPU count, trace flags 1117 / 1118, memory-optimized metadata | public; VIEW SERVER STATE for the CPU count and volumes (partial without it) | not run | [CPU, memory, file IO, tempdb](#cpu-memory-file-io-and-tempdb) |
| `mssql_properties` | 1 hour | what the instance is (server, processors, memory, tempdb's layout, host) and every change of a value | public; VIEW SERVER STATE for the processor, memory and host rows (partial without it) | not run | [properties, procedures, index locks](sqlserver-reads.md) |
| `mssql_procstats` | 5 min | what each stored procedure did between two reads: calls, CPU, duration, reads | VIEW SERVER STATE (2022: VIEW SERVER PERFORMANCE STATE); CONNECT ANY DATABASE and VIEW ANY DEFINITION for the names in other databases | not run | [properties, procedures, index locks](sqlserver-reads.md) |
| `mssql_indexlocks` | 5 min | row and page lock waits and lock escalations per index, as the difference between two reads | as `mssql_procstats` | not run | [properties, procedures, index locks](sqlserver-reads.md) |
| `mssql_querystore` | 1 hour | each database's Query Store: state, top queries per interval, forced plans, tuning recommendations | VIEW SERVER STATE, CONNECT ANY DATABASE (VIEW ANY DEFINITION for object names) | not run | [Query Store](sqlserver-querystore.md) |
| `mssql_audit` | 5 min | the server audits, their server and database specifications and their state; the events of a file audit read forward from a cursor (role, permission, DDL and audit changes and failed sign-ins as rows, the rest counted) | VIEW ANY DEFINITION and VIEW SERVER STATE; VIEW SERVER SECURITY AUDIT for the events (2022) | skipped (its blob target is not built) | [SQL Server Audit](sqlserver-audit.md) |

Amazon RDS for SQL Server and Azure SQL Managed Instance: no collection is switched off by the kind of server; each runs wherever the login has its right. Neither is proven here (each page's Proof section says what is).

Not yet: the performance counters beyond the ones named below, the plan cache, index and statistics health, DBCC and corruption, the error log, logins and permissions, Azure SQL Database's storage and version store, a proof of Windows authentication, and the `aws:` block (CloudWatch and RDS metrics) on a SQL Server instance. Azure SQL Database's backups are the service's own and are not read. On the Summary a SQL Server instance's cell in a PostgreSQL-only column says `n/a`, and a column with a SQL Server read says `not yet` until a read of its group is stored; the fleet pages of PostgreSQL checks (Versions, Corruption, Slow queries' sources) do not list it, and no PostgreSQL finding is raised on it. Azure Synapse Analytics answers on the same protocol and is refused with a clear error: it is not a SQL Server.

## Configuration

```yaml
instances:
  - name: sales-sql01
    engine: sqlserver
    dsn: env:SALES_SQL01_DSN     # or file:/etc/pgvigil/sales-sql01.dsn
    platform: auto               # auto (default), onprem, rds, azuresqldb, azuresqlmi
    tags: [env:prod, team:sales]
```

The connection string is the driver's own form, `sqlserver://login:password@host:1433?database=master&encrypt=true`, or the ADO form `server=host;user id=login;password=...;database=master`. One that carries a password must come through `env:` or `file:`; an inline password is refused. Windows authentication from a Windows collector host is the driver's (a connection string without a login); it is not proven here.

`explain_dsn`, `explain_analyze`, `pgbouncer` and `backups:` are PostgreSQL's and refused on a SQL Server instance; the `aws:` block is refused there for now. `actions_dsn` and `actions:` open the [actions door](sqlserver-actions.md); `mssql_thresholds:` sets the availability, jobs and backups thresholds ([the page](sqlserver-hadr.md)); `audit_text: true` keeps the statement text of the audit events stored as rows (off by default: it can carry data; [SQL Server Audit](sqlserver-audit.md)).

## The login

A SQL login or a Windows login with four things and no more; never sysadmin.

```sql
CREATE LOGIN [pgvigil_monitor] WITH PASSWORD = '<a long random password>';
GRANT VIEW SERVER STATE TO [pgvigil_monitor];
GRANT VIEW ANY DEFINITION TO [pgvigil_monitor];
GRANT CONNECT ANY DATABASE TO [pgvigil_monitor];   -- SQL Server 2014 and later: the names of procedures and indexes in every database; pgvigil reads no table, and the login holds in each database what public holds there
-- a server, Amazon RDS and Azure SQL Managed Instance only (Azure SQL Database has no msdb):
USE msdb;
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];
ALTER ROLE db_datareader ADD MEMBER [pgvigil_monitor];
```

On Azure SQL Database the login block is the first three lines only, run in `master` (or a contained user in the database, with `VIEW DATABASE STATE`); not proven here.

A collection that needs a right the login lacks does not fail the instance: it stores what it could read, and its row on the Collections page says `partial` with the missing right.

## Agent, Database Mail and memory dumps (`mssql_services`, every 5 minutes)

Three columns of the Summary, read with the same login:

- **Agent**: is SQL Server Agent running. The service's own state where the server lists it (`sys.dm_server_services`), else whether Agent's sessions are open. Stopped is critical; stopped with the service disabled is a warning; SQL Server Express has no Agent and says so.
- **DB Mail**: started or stopped, where Database Mail is switched on. `msdb.dbo.sysmail_help_status_sp` asks for CONTROL SERVER or `db_owner` in msdb, so pgvigil makes that procedure's one catalog read itself (does the queue `ExternalMailQueue` receive), which VIEW ANY DEFINITION covers. Stopped is a warning; switched off is shown as `off` and never flagged. A login that cannot see the queue gets `not readable` and a partial run that says why.
- **Memory dumps**: the dump files the server lists (`sys.dm_server_memory_dumps`). The newest under 48 hours old is critical, under 7 days a warning. A file whose creation time the server cannot tell (SQL Server on Linux lists one dated 1601) is counted and never dated.

Not on Azure SQL Database. Needs VIEW SERVER STATE. The services the server lists are kept in `pgvigil.mssql_service`, the three states in `pgvigil.mssql_health`, the cells' rules in the view `pgvigil.mssql_health_status`. Proof: `scripts/proof-mssql-services.sh` (a stopped Agent is proven on imported rows only; Windows, Express, RDS and Managed Instance are not proven).

## CPU, memory, file IO and tempdb

Four collections behind the Performance page's CPU, Transactions and IO charts, the Performance summary's SQL Server CPU, transactions, IO latency and memory columns, and four pages of an instance: **CPU** and **Memory** and **File IO** (the Performance group), **TempDB** (the Storage group; at the root, every SQL Server instance's TempDB row).

| DMV | what is read | SQL Server | right (Microsoft's page) | Managed Instance | Azure SQL Database |
| --- | --- | --- | --- | --- | --- |
| `sys.dm_os_ring_buffers` (RING_BUFFER_SCHEDULER_MONITOR) | each minute's SQL Server CPU % and idle %; the last 256 records | 2016 SP1+ | VIEW SERVER STATE; 2022+: VIEW SERVER PERFORMANCE STATE | yes | not run (the host's) |
| `sys.dm_os_schedulers` | runnable tasks, work queue, pending IO, workers of the VISIBLE ONLINE schedulers | 2016 SP1+ | as above | yes | not run |
| `sys.dm_os_performance_counters` | Batch Requests/sec, SQL (Re-)Compilations/sec, Transactions/sec (cumulative: stored as rates); Target / Total / Stolen / Database Cache Memory, Memory Grants Pending / Outstanding, Page life expectancy (as read) | 2016 SP1+ | as above | yes | not run |
| `sys.dm_os_sys_memory`, `sys.dm_os_process_memory` | physical and available memory, the OS's memory state; the process's working set and its low-memory flag | 2016 SP1+ | as above | yes | not on Azure SQL Database (Microsoft's pages list SQL Server and Managed Instance only) |
| `sys.dm_os_sys_info` | CPU count, committed and target memory, the memory model (`sql_memory_model_desc`: 2016 SP1+) | 2016 SP1+ | as above | yes | not run |
| `sys.dm_os_memory_clerks` | the 25 largest clerk types by `pages_kb` (2012+) and the total | 2016 SP1+ | as above | yes | not run |
| `sys.dm_exec_query_resource_semaphores`, `sys.dm_exec_query_memory_grants` | granted and waiting queries, granted / target KB; the largest and the summed grant at the read | 2016 SP1+ | as above | yes | not run |
| `sys.dm_io_virtual_file_stats(NULL, NULL)` | per file: reads, bytes, read stall; writes, bytes, write stall (cumulative: stored as differences) | 2016 SP1+ | as above | yes | not run (its ids are the elastic pool's there) |
| `tempdb.sys.database_files`, `DBCC TRACESTATUS`, `SERVERPROPERTY('IsTempDBMetadataMemoryOptimized')` | tempdb's files as they are now, flags 1117 / 1118, memory-optimized metadata (2019+; not on Managed Instance) | 2016 SP1+ | public | yes | not run (tempdb is the service's) |

What the pages show (the shapes of Darling's CPU, Memory, File I/O and I/O Trends tabs and DBA Dash's Performance, Memory and TempDB):

- **CPU**: SQL Server %, the other processes' % and the total per step; the scheduler pressure tiles at the newest read with a verdict (NORMAL / ELEVATED / HIGH: runnable tasks per scheduler, the work queue, workers against max worker threads); the scheduler and workers trend; batch requests, transactions, compilations and recompilations per second.
- **Memory**: physical, available, utilization, total and target server memory, buffer pool, plan cache, stolen, Page life expectancy, grants waiting, the OS's memory state and the memory model; max server memory against physical; the memory trend, PLE, grants and grant sizes; the memory clerks' trend with a picker (the five largest drawn first, up to ten) and every clerk's current, max, avg and min.
- **File IO**: read and write latency per database and file type (the five with the most stall, the rest as `(other)`), read and write MB/s for the five busiest files, every file's operations, latency, bytes and path over the range.
- **TempDB**: DBA Dash's grid (# data files, insufficient files, recommended minimum, # log files, even size, even growth, sizes, growth, volumes, CPU count, T1117, T1118, trace flags required, memory-optimized metadata) and the files.

The checks (in Findings and on each page): tempdb with fewer data files than recommended (Microsoft's tempdb page: as many as the logical processors up to eight, then eight; more by fours only while allocation contention stays), data files of different sizes or growth (warning), a data file growing by per cent (info), trace flags 1117 / 1118 off before SQL Server 2016 (warning; from 2016 they are no longer required); the CPU at 90 % or more over 15 minutes (95 %: critical); one runnable task per scheduler, or a work queue, over 15 minutes (scheduler pressure); the OS saying available physical memory is low; queries waiting for memory grants in 3 of 15 minutes; a data file's reads at 50 ms or more (100 ms: critical) or a log's writes at 20 ms or more, over the last hour with 1,000 operations.

SQL Server on Linux writes the scheduler monitor's idle figure as 0 in every record: on a Linux host the other processes' share and the machine's total are not read, the pages draw the SQL Server process's CPU alone and say so, and the CPU check weighs that.

Proof: `scripts/proof-mssql-perf.sh`, against the SQL Server sandbox pair (SQL Server 2022 on Linux, both servers) as a login with VIEW SERVER STATE and VIEW ANY DEFINITION, a login with VIEW SERVER STATE alone and a login with neither, compared with what `sa` reads; the checks' thresholds, retries, late reads and a restart on imported rows; the API; and a two-day demo. Not proven: SQL Server 2016-2019, Windows, Managed Instance, RDS, a login holding only VIEW SERVER PERFORMANCE STATE, a real memory grant wait, a ring buffer after a real restart.

## One run by hand

```
pgvigil collect -config pgvigil.yaml -once mssql_instance -instance sales-sql01
```

## Proof

`scripts/proof-mssql-base.sh` runs against a SQL Server container and a PostgreSQL sandbox: the collection as the least-privilege login compared with what `sa` reads, the other engine's collections refused both ways, a login without VIEW SERVER STATE stored as partial, a name refused under a second engine, a configuration change kept with its previous value, a value the server no longer lists marked as gone, and the collector's row contract (handles and GUIDs as text that survives, times without a false time zone) read back from the server. Proven on SQL Server 2022 in a Linux container. Not proven: Azure SQL Database, Managed Instance, RDS, SQL Server 2016-2019, Windows authentication, and that a collector session never waits behind a writer (no collection of the base reads a user table). The server's start time is moved to UTC by the offset the server has at the read: a server started before a daylight-saving change shows it one hour off until its next restart.
