# SQL Server instances

pgvigil can hold SQL Server instances beside its PostgreSQL fleet as an engine of its own: its own collector, its own tables in the same repository. This page is what exists today, the base; the collections, findings and pages built on it arrive wave by wave and are listed here as they land.

The [DBA Dash door](dbadash.md) is a different thing: it shows what a DBA Dash repository already knows. The engine reads the SQL Server itself.

## What the base does

- An instance says `engine: sqlserver`; everything else is PostgreSQL, as before.
- Only SQL Server collections run on a SQL Server instance and only PostgreSQL collections on a PostgreSQL one. A SQL Server collection is named `mssql_<what>`. Naming a collection of the other engine under an instance's `schedules:` or `disabled:` is refused when the file is read.
- One collection, hourly: `mssql_instance` - the server's own description (version, edition, update level, collation, clustered, Always On enabled), every row of `sys.configurations` with the previous value and the time a value in use changed, and, with VIEW SERVER STATE, the CPU count, memory and start time.
- Nothing is installed on the monitored server and nothing is written there. The collector's session gives up on a lock after two seconds, loses any deadlock it is part of and reads without shared locks, so it cannot join a blocking chain.

Not yet: running queries and blocking, waits, Extended Events, Always On, mirroring, replication, log shipping, Agent jobs, backups, the SQL Server pages and their actions. A SQL Server instance is a row in the tree and on the Summary; the cells of PostgreSQL checks say `not yet` for it, the fleet pages of PostgreSQL checks (Versions, Corruption, Slow queries' sources) do not list it, and no PostgreSQL finding is raised on it. Azure Synapse Analytics answers on the same protocol and is refused with a clear error: it is not a SQL Server.

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

`actions_dsn`, `explain_dsn`, `explain_analyze`, `pgbouncer`, `aws:` and `backups:` are refused on a SQL Server instance for now.

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
