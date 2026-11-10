# SQL Server instances

pgvigil can hold SQL Server instances beside its PostgreSQL fleet as an engine of its own: its own collector, its own tables in the same repository, its own pages. This page is the base every collection stands on (the engine, the configuration, the login) and the list of what is collected; each group of collections has a page of its own.

The [DBA Dash door](dbadash.md) is a different thing: it shows what a DBA Dash repository already knows. The engine reads the SQL Server itself.

## What the base does

- An instance says `engine: sqlserver`; everything else is PostgreSQL, as before.
- Only SQL Server collections run on a SQL Server instance and only PostgreSQL collections on a PostgreSQL one. A SQL Server collection is named `mssql_<what>`. Naming a collection of the other engine under an instance's `schedules:` or `disabled:` is refused when the file is read.
- The collector asks the server what it is (a server someone runs, Amazon RDS, Azure SQL Managed Instance, Azure SQL Database) and what the login may read (VIEW SERVER STATE, VIEW ANY DEFINITION, msdb) before each collection. A collection that does not apply there is skipped with the reason, never failed.
- Nothing is installed on the monitored server and nothing is written there. The collector's session gives up on a lock after two seconds, loses any deadlock it is part of and reads without shared locks, so it cannot join a blocking chain. The one door that changes anything is the [actions door](sqlserver-actions.md), off until an instance opens it with a login of its own.

## Collections

Thirteen collections. `every` is the default; an instance's `schedules:` changes it and `disabled:` switches one off.

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

Amazon RDS for SQL Server and Azure SQL Managed Instance: no collection is switched off by the kind of server; each runs wherever the login has its right. Neither is proven here (each page's Proof section says what is).

Not yet: CPU and the performance counters, memory, the plan cache and Query Store, index and statistics health, DBCC and corruption, the error log, logins and permissions, Azure SQL Database's storage, version store and backups, Windows authentication proven, and the `aws:` block (CloudWatch and RDS metrics) on a SQL Server instance. The cells of PostgreSQL checks on the Summary say `not yet` for a SQL Server instance, the fleet pages of PostgreSQL checks (Versions, Corruption, Slow queries' sources) do not list it, and no PostgreSQL finding is raised on it. Azure Synapse Analytics answers on the same protocol and is refused with a clear error: it is not a SQL Server.

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

`explain_dsn`, `explain_analyze`, `pgbouncer` and `backups:` are PostgreSQL's and refused on a SQL Server instance; the `aws:` block is refused there for now. `actions_dsn` and `actions:` open the [actions door](sqlserver-actions.md); `mssql_thresholds:` sets the availability, jobs and backups thresholds ([the page](sqlserver-hadr.md)).

## The login

A SQL login or a Windows login with three things and no more; never sysadmin.

```sql
CREATE LOGIN [pgvigil_monitor] WITH PASSWORD = '<a long random password>';
GRANT VIEW SERVER STATE TO [pgvigil_monitor];
GRANT VIEW ANY DEFINITION TO [pgvigil_monitor];
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

## One run by hand

```
pgvigil collect -config pgvigil.yaml -once mssql_instance -instance sales-sql01
```

## Proof

`scripts/proof-mssql-base.sh` runs against a SQL Server container and a PostgreSQL sandbox: the collection as the least-privilege login compared with what `sa` reads, the other engine's collections refused both ways, a login without VIEW SERVER STATE stored as partial, a name refused under a second engine, a configuration change kept with its previous value, a value the server no longer lists marked as gone, and the collector's row contract (handles and GUIDs as text that survives, times without a false time zone) read back from the server. Proven on SQL Server 2022 in a Linux container. Not proven: Azure SQL Database, Managed Instance, RDS, SQL Server 2016-2019, Windows authentication, and that a collector session never waits behind a writer (no collection of the base reads a user table). The server's start time is moved to UTC by the offset the server has at the read: a server started before a daylight-saving change shows it one hour off until its next restart.
