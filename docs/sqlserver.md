# SQL Server instances

pgvigil can hold SQL Server instances beside its PostgreSQL fleet as an engine of its own: its own collector, its own tables in the same repository, its own pages. This page is the base every collection stands on (the engine, the configuration, the login) and the list of what is collected; each group of collections has a page of its own.

The [DBA Dash door](dbadash.md) is a different thing: it shows what a DBA Dash repository already knows. The engine reads the SQL Server itself.

## What the base does

- An instance says `engine: sqlserver`; everything else is PostgreSQL, as before.
- Only SQL Server collections run on a SQL Server instance and only PostgreSQL collections on a PostgreSQL one. A SQL Server collection is named `mssql_<what>`. Naming a collection of the other engine under an instance's `schedules:` or `disabled:` is refused when the file is read.
- The collector asks the server what it is (a server someone runs, Amazon RDS, Azure SQL Managed Instance, Azure SQL Database) and what the login may read (VIEW SERVER STATE, VIEW ANY DEFINITION, msdb) before each collection. A collection that does not apply there is skipped with the reason, never failed.
- Nothing is installed on the monitored server and nothing is written there. The collector's session gives up on a lock after two seconds, loses any deadlock against a session of normal or high priority and reads without shared locks, so it cannot join a blocking chain. The one door that changes anything is the [actions door](sqlserver-actions.md), off until an instance opens it with a login of its own.

## Versions

SQL Server 2017, 2019, 2022 and 2025 are proven; the table says on what. `scripts/proof-mssql-versions.sh` starts a pair of Linux containers of Microsoft's image per version (Developer edition, SQL Server Agent and Always On switched on), joins the pair in a clusterless availability group and runs thirteen SQL Server proofs of this repository (the rows below; `checks`, `audit` and `plancache-indexes` since task 166) against the pair. The runs of 2026-11-11 (SQL Server 2017, 2022 and 2025 in one run of the tree; SQL Server 2019 in a second run, after a fix to the proof's own choice of ports that had kept its pair from starting in the first):

| | build the run read | the image's host | result |
| --- | --- | --- | --- |
| SQL Server 2025 | 17.0.5045.3 (RTM, CU10), Enterprise Developer Edition | Ubuntu 24.04 | setup and all ten proofs passed |
| SQL Server 2022 | 16.0.4315.2 (RTM, CU27), Developer Edition | Ubuntu 22.04 | setup and all ten proofs passed |
| SQL Server 2019 | 15.0.4510.2 (RTM, CU32), Developer Edition | Ubuntu 20.04 | setup and all ten proofs passed |
| SQL Server 2017 | 14.0.3570.2 (RTM, CU31), Developer Edition | Ubuntu 18.04 | setup and all ten proofs passed |
| SQL Server 2016 (SP1 and later) | 13.0.7050.2 (SP3 CU1 GDR), Developer Edition | Windows Server 2019 Datacenter (an Azure VM) | proven on one Windows server by `scripts/proof-mssql-2016.sh`: [SQL Server 2016](sqlserver-2016.md) (Always On not proven: one server; `mssql_defaulttrace` partial there) |
| Azure SQL Database | 12.0.2000.8, General Purpose serverless Gen5, 1 vCore | Azure (the service) | proven by `scripts/proof-mssql-azuresqldb.sh` on the 32 collections before `mssql_waiting_tasks` and `mssql_reports` joined: 4 collections stored equal to the setup login's read, 28 skipped by an Azure SQL Database rule, each with its reason ([SQL Server in the cloud](sqlserver-cloud.md)) |
| Azure SQL Managed Instance | not proven yet | | |
| Amazon RDS for SQL Server | 15.0.4500.2 (SQL Server 2019), Express Edition, db.t3.micro | AWS (the service) | proven by `scripts/proof-mssql-rds.sh` on the 32 collections before `mssql_waiting_tasks` and `mssql_reports` joined: 29 collections stored equal to the master user's read, 3 skipped by an RDS rule; the login is the RDS form ([SQL Server in the cloud](sqlserver-cloud.md)) |

Each proof on each version, as the runs printed it (`setup` is the pair itself: both servers answer, the collector connects to both and stores the version it read, the group is synchronized; the other rows are `scripts/proof-mssql-<name>.sh`, and each proof's page says what it checks):

| | SQL Server 2025 | SQL Server 2022 | SQL Server 2019 | SQL Server 2017 |
| --- | --- | --- | --- | --- |
| setup (the pair, the connect check, the group) | PASS | PASS | PASS | PASS |
| `base` | PASS | PASS | PASS | PASS |
| `services` | PASS | PASS | PASS | PASS |
| `running` | PASS | PASS | PASS | PASS |
| `xe` | PASS | PASS | PASS | PASS |
| `hadr` | PASS | PASS | PASS | PASS |
| `storage` | PASS | PASS | PASS | PASS |
| `perf` | PASS | PASS | PASS | PASS |
| `reads` | PASS | PASS | PASS | PASS |
| `querystore` | PASS | PASS | PASS | PASS |
| `actions` | PASS | PASS | PASS | PASS |
| `audit` | PASS | PASS | PASS | PASS |
| `plancache-indexes` | PASS | PASS | PASS | PASS |
| `checks` | PASS | PASS | PASS | PASS |
| certificate with a negative serial (node a, node b) | no, no | no, no | no, no | yes, yes |

What a version changes. The collector reads the server's version at every connection and names a column only where that version has it:

- **SQL Server 2017** can generate a certificate with a negative serial number for itself where none is installed. Go refuses to parse such a certificate, and the parse comes before any decision about trust, so `TrustServerCertificate=true` does not help: without the setting below every connection to such a server fails with `x509: negative serial number`. pgvigil is built with `godebug x509negativeserial=1` (go.mod), which lets the certificate be parsed and changes nothing else: a certificate is verified exactly as before. The proof reads both servers of each pair with the setting and once more with it switched off: in the run above both SQL Server 2017 servers had such a certificate, in an earlier run of the same day one of two did, and no SQL Server 2019, 2022 or 2025 server read that day had one.
- **Before SQL Server 2019** there is no accelerated database recovery: the persistent version store is not read and the Row versions page lists no database for it. tempdb's memory-optimized metadata says n/a, and Query Store has no custom capture policy.
- **Before SQL Server 2022** an availability group's `is_contained` is not read.
- **SQL Server 2025**: no change of the collector or of a proof was specific to it.

Not proven by these runs: a Windows host on any version, an edition other than Developer, a Windows cluster's availability group. What each proof leaves out on any server (mirroring, log shipping and replication without a real partner; a browser render) is on that proof's own page; the availability proof's job history check ran against sixty seeded history rows, and a server with fewer than fifty rows of job history is not proven there.

## Collections

Thirty-four collections; `mssql_checks` and `mssql_identity` are on [day-one checks](sqlserver-checks.md). `every` is the default; an instance's `schedules:` changes it and `disabled:` switches one off.

| collection | every | reads | needs | Azure SQL Database | page |
| --- | --- | --- | --- | --- | --- |
| `mssql_instance` | 1 hour | the server's description (version, edition, update level, collation, clustered, Always On enabled), every row of `sys.configurations` with the previous value and the time a value in use changed, the CPU count, memory and start time | nothing for the first two; VIEW SERVER STATE for the third (partial without it) | runs | this page |
| `mssql_traceflags` | 1 hour | the trace flags on globally (`DBCC TRACESTATUS(-1)`) and their history | any login | not run | [jobs and configuration history](jobs.md) |
| `mssql_services` | 5 min | is SQL Server Agent running, is Database Mail started, the memory dump files | VIEW SERVER STATE | not run | this page |
| `mssql_requests` | 1 min | what runs now and who blocks whom | VIEW SERVER STATE | runs | [running queries](sqlserver-running.md) |
| `mssql_waits` | 1 min | the wait counters, as the difference between two reads | VIEW SERVER STATE | runs (the database's own waits) | [running queries](sqlserver-running.md) |
| `mssql_waiting_tasks` | 1 min | every task of every waiting request (`sys.dm_os_waiting_tasks` with `sys.dm_exec_requests`, PerformanceMonitor's read), its resource decoded to database, object and index, and the THREADPOOL waiters | VIEW SERVER STATE | runs (VIEW DATABASE STATE; not proven there) | the Waiting tasks tab |
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
| `mssql_plancache` | 5 min | `sys.dm_exec_query_stats`: per cached statement, what changed between two reads (the place of Query Store where it is off) | VIEW SERVER STATE (2022: VIEW SERVER PERFORMANCE STATE) | not run | [plan cache, indexes, statistics](sqlserver-indexes.md) |
| `mssql_plancache_health` | 1 hour | what the plan cache holds per database: single-use and duplicate plans | as `mssql_plancache` | not run | [plan cache, indexes, statistics](sqlserver-indexes.md) |
| `mssql_indexes` | 6 hours | each user database's indexes with their usage and size, the missing-index DMVs | VIEW SERVER STATE, VIEW ANY DEFINITION, CONNECT ANY DATABASE; SELECT on msdb.dbo.restorehistory | not run | [plan cache, indexes, statistics](sqlserver-indexes.md) |
| `mssql_stats` | 6 hours | each user database's statistics with their age, modifications and sample | as `mssql_indexes`; db_datareader for the sample rates | not run | [plan cache, indexes, statistics](sqlserver-indexes.md) |
| `mssql_errorlog` | 5 min | the error log forward from a date cursor: errors of severity 17+, sp_LogHunter's search strings, the instance's own | EXECUTE on xp_readerrorlog; the archives: securityadmin (2022+: VIEW SERVER STATE) | not run | [readers](sqlserver-readers.md) |
| `mssql_defaulttrace` | 5 min | the default trace forward: file growths and shrinks, DBCC commands, DDL | ALTER TRACE | not run | [readers](sqlserver-readers.md) |
| `mssql_syshealth` | 5 min | system_health's sp_server_diagnostics results (SYSTEM, RESOURCE, QUERY_PROCESSING, IO_SUBSYSTEM) | VIEW SERVER STATE | not run | [readers](sqlserver-readers.md) |
| `mssql_reports` | 1 hour | server role members, SQL logins with their password age, the error log's failed logins, the services' files, extended properties and the largest tables of each database | VIEW ANY DEFINITION (role members, logins, properties), VIEW SERVER STATE (services; with VIEW ANY DEFINITION the table sizes), EXECUTE on xp_readerrorlog or securityadmin (the failed logins; 2022 and later VIEW SERVER STATE or VIEW ANY ERROR LOG) | not run | [reports](reports.md) |

Azure SQL Managed Instance: no collection is switched off by the kind of server; each runs wherever the login has its right; not proven here. Azure SQL Database and Amazon RDS for SQL Server have their own rules, logins and proofs: [SQL Server in the cloud](sqlserver-cloud.md) (on RDS the login below cannot be made: the master user holds no CONNECT ANY DATABASE and cannot add a member to msdb's db_datareader, so the page gives the RDS form).

Not yet: the performance counters beyond the ones named below, logins and permissions, Azure SQL Database's storage and version store, a proof of Windows authentication, and the `aws:` block (CloudWatch and RDS metrics) on a SQL Server instance. Azure SQL Database's backups are the service's own and are not read. On the Summary a SQL Server instance's cell in a PostgreSQL-only column says `n/a`, and a column with a SQL Server read says `not yet` until a read of its group is stored; the fleet pages of PostgreSQL checks (Versions, Corruption, Slow queries' sources) do not list it, and no PostgreSQL finding is raised on it. Azure Synapse Analytics answers on the same protocol and is refused with a clear error: it is not a SQL Server.

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

A SQL login (or a Windows login: not proven here) with these rights and no more; never sysadmin.

```sql
CREATE LOGIN [pgvigil_monitor] WITH PASSWORD = '<a long random password>';
GRANT VIEW SERVER STATE TO [pgvigil_monitor];
GRANT VIEW ANY DEFINITION TO [pgvigil_monitor];
GRANT CONNECT ANY DATABASE TO [pgvigil_monitor];   -- SQL Server 2014 and later: the names of procedures and indexes in every database; pgvigil reads no table, and the login holds in each database what public holds there
-- a server, Amazon RDS and Azure SQL Managed Instance only (Azure SQL Database has no msdb):
USE msdb;
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];
ALTER ROLE db_datareader ADD MEMBER [pgvigil_monitor];
-- the error log and default trace readers ([readers](sqlserver-readers.md)):
GRANT ALTER TRACE TO [pgvigil_monitor];
USE master;
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];
GRANT EXECUTE ON master.sys.xp_readerrorlog TO [pgvigil_monitor];
```

On Azure SQL Database the login block is the first three lines only, run in `master` (or a contained user in the database, with `VIEW DATABASE STATE`); not proven here.

A collection that needs a right the login lacks does not fail the instance: it stores what it could read, and its row on the Collections page says `partial` with the missing right.

## Agent, Database Mail and memory dumps (`mssql_services`, every 5 minutes)

Three columns of the Summary, read with the same login:

- **Agent**: is SQL Server Agent running. The service's own state where the server lists it (`sys.dm_server_services`), else whether Agent's sessions are open. Stopped is critical; stopped with the service disabled is a warning; SQL Server Express has no Agent and says so.
- **DB Mail**: started or stopped, where Database Mail is switched on. `msdb.dbo.sysmail_help_status_sp` asks for CONTROL SERVER or `db_owner` in msdb, so pgvigil makes that procedure's one catalog read itself (does the queue `ExternalMailQueue` receive), which VIEW ANY DEFINITION covers. Stopped is a warning; switched off is shown as `off` and never flagged. A login that cannot see the queue gets `not readable` and a partial run that says why.
- **Memory dumps**: the dump files the server lists (`sys.dm_server_memory_dumps`). The newest under 48 hours old is critical, under 7 days a warning. A file whose creation time the server cannot tell (SQL Server on Linux lists one dated 1601) is counted and never dated.

Not on Azure SQL Database. Needs VIEW SERVER STATE. The services the server lists are kept in `pgvigil.mssql_service`, the three states in `pgvigil.mssql_health`, the cells' rules in the view `pgvigil.mssql_health_status`. Proof: `scripts/proof-mssql-services.sh`, on SQL Server 2017, 2019, 2022 and 2025 ([Versions](#versions)); a stopped Agent is proven on imported rows only; Windows, Express, RDS and Managed Instance are not proven.

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

Proof: `scripts/proof-mssql-perf.sh`, against the SQL Server sandbox pair (SQL Server 2022 on Linux, both servers) as a login with VIEW SERVER STATE and VIEW ANY DEFINITION, a login with VIEW SERVER STATE alone and a login with neither, compared with what `sa` reads; the checks' thresholds, retries, late reads and a restart on imported rows; the API; and a two-day demo. The same proof against a pair of SQL Server 2017, 2019 and 2025 servers: [Versions](#versions). Not proven: SQL Server 2016, Windows, Managed Instance, RDS, a login holding only VIEW SERVER PERFORMANCE STATE, a real memory grant wait, a ring buffer after a real restart.

## One run by hand

```
pgvigil collect -config pgvigil.yaml -once mssql_instance -instance sales-sql01
```

## Proof

`scripts/proof-mssql-base.sh` runs against a SQL Server container and a PostgreSQL sandbox: the collection as the least-privilege login compared with what `sa` reads, the other engine's collections refused both ways, a login without VIEW SERVER STATE stored as partial, a name refused under a second engine, a configuration change kept with its previous value, a value the server no longer lists marked as gone, and the collector's row contract (handles and GUIDs as text that survives, times without a false time zone) read back from the server. Proven on SQL Server 2017, 2019, 2022 and 2025 in Linux containers ([Versions](#versions)). Not proven: Azure SQL Database, Managed Instance, RDS, SQL Server 2016, Windows authentication, and that a collector session never waits behind a writer (no collection of the base reads a user table). The server's start time is moved to UTC by the offset the server has at the read: a server started before a daylight-saving change shows it one hour off until its next restart (not proven: no proof crosses a daylight-saving change).
