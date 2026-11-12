# SQL Server in the cloud: Azure SQL Database and Amazon RDS

The [SQL Server engine](sqlserver.md) reads two managed services besides a server someone runs: Azure SQL Database and Amazon RDS for SQL Server. This page says, per service, how pgvigil tells it apart, which login it needs, what each collection does there and why, and what was proven against a real instance of each.

Nothing is installed on the monitored server and nothing is written there, on either service: the proofs read every object, principal, permission and event session before and after the collector's runs and find them equal.

## How pgvigil tells the services apart

Before each collection the collector asks the server what it is (`internal/mssql/detect.go`):

| service | engine edition | other sign | platform stored | version stored |
| --- | --- | --- | --- | --- |
| Azure SQL Database | 5 | | `azuresqldb` | 12.0 (120000) whatever engine runs it |
| Amazon RDS for SQL Server | 2, 3 or 4 (Standard, Enterprise, Express; Web reads as Standard) | the database `rdsadmin` exists | `rdssqlserver` | the engine's own (SQL Server 2019 = 150000) |
| Azure SQL Managed Instance | 8 | | `azuresqlmi` | 12.0 |

`platform:` in the configuration names the service instead (`azuresqldb`, `rds`, `azuresqlmi`, `onprem`); `auto` (the default) keeps what the server says. The instance's Summary shows the platform as a badge beside its name.

## Azure SQL Database

One database is the instance: the connection string names it (`database=<the database>`), and every collection reads that database alone.

### The login

A contained user in the database, with one right:

```sql
-- in the monitored database, as its admin
CREATE USER [pgvigil_monitor] WITH PASSWORD = '<a long random password>';
GRANT VIEW DATABASE STATE TO [pgvigil_monitor];
```

The connection string: `sqlserver://pgvigil_monitor:<password>@<server>.database.windows.net:1433?database=<the database>&encrypt=true`, through `env:` or `file:` as on any SQL Server instance. The server's firewall admits the collector's address (a single address, never a range).

The service tier matters: on Basic, S0 and S1 (and in an elastic pool) Microsoft's pages of the server-state views ask for the server admin or the `##MS_ServerStateReader##` role instead of VIEW DATABASE STATE, so a contained user reads less there. The proof ran on General Purpose serverless.

### What runs

Four collections run; twenty-eight are skipped by an Azure SQL Database rule, each with its reason on the run's row and on the page that would show it ("Not read on this instance: ... is skipped (...)"), and the Summary lists their groups as "not on this platform".

| collection | on Azure SQL Database | why |
| --- | --- | --- |
| `mssql_instance` | runs | `sys.configurations` (read-only there), the server's description, `sys.dm_os_sys_info` with VIEW DATABASE STATE |
| `mssql_requests` | runs | the database's own sessions and requests (`database_id = DB_ID()`), no task columns |
| `mssql_waits` | runs | `sys.dm_db_wait_stats`: the database's own waits (the server-wide view is the logical server's, not the tenant's) |
| `mssql_xe` | runs | the database-scoped sessions of pgvigil's script (`sys.database_event_sessions`, `sys.dm_xe_database_sessions`), ring buffer targets |
| `mssql_services` | skipped | no SQL Server Agent, no Database Mail, no memory dump files to read |
| `mssql_ag`, `mssql_mirroring`, `mssql_logshipping`, `mssql_replication` | skipped | none of them exists on the service (its geo-replication is not read) |
| `mssql_jobs` | skipped | no SQL Server Agent (Elastic Jobs are not read) |
| `mssql_backups` | skipped | no backup history in msdb: the backups are the service's own |
| `mssql_storage`, `mssql_versionstore` | skipped (not yet) | no `sys.master_files`; tempdb's version store is not the tenant's |
| `mssql_cpu`, `mssql_memory`, `mssql_fileio`, `mssql_tempdb`, `mssql_properties` | skipped | the ring buffer, schedulers, memory, file stats, tempdb and processors there are the host's, not the database's |
| `mssql_procstats`, `mssql_indexlocks`, `mssql_querystore` | skipped (not yet) | the database's own procedure, index and Query Store reads are a later wave |
| `mssql_audit` | skipped | the service's auditing writes "to an audit log in your Azure storage account, Log Analytics workspace, or Event Hubs", and the T-SQL differences page says "SQL Server audit: Use SQL Database auditing instead" ([Auditing for Azure SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/auditing-overview); `sys.server_audits` applies to SQL Server and Managed Instance only) |
| `mssql_defaulttrace` | skipped | "SQL Server trace" is T-SQL syntax not supported in Azure SQL Database ([T-SQL differences](https://learn.microsoft.com/en-us/azure/azure-sql/database/transact-sql-tsql-differences-sql-server)); `sys.traces` applies to SQL Server and Managed Instance only |
| `mssql_errorlog` | skipped | `sys.sp_readerrorlog` applies to SQL Server only ([sys.sp_readerrorlog](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-readerrorlog-transact-sql)); the service names no error log a login can read |
| `mssql_syshealth` | skipped | "There's no built-in `system_health` Extended Event session in Azure SQL Database" ([Extended Events in Azure SQL](https://learn.microsoft.com/en-us/azure/azure-sql/database/xevent-db-diff-from-svr)) |
| `mssql_traceflags` | skipped | trace flags are instance configuration, T-SQL not supported there: "Use service tiers and compute sizes instead" ([T-SQL differences](https://learn.microsoft.com/en-us/azure/azure-sql/database/transact-sql-tsql-differences-sql-server)) |
| `mssql_checks`, `mssql_identity`, `mssql_indexes`, `mssql_stats`, `mssql_plancache`, `mssql_plancache_health` | skipped (not yet) | the server options, msdb and the other databases are the service's; the database's own identity columns, indexes, statistics and plan cache are a later wave |

The database's own resource use (`sys.dm_db_resource_stats`), its files and its Query Store are not read in this release.

### Extended Events

`pgvigil mssql-xe -print -form azuresqldb -install-id <id>` prints the four database-scoped sessions (ring buffer targets); the database's admin runs it in the monitored database. The collector only reads them.

## Amazon RDS for SQL Server

### The login

The RDS master user is no sysadmin, and two parts of the login on [the base page](sqlserver.md#the-login) cannot be given on RDS: the master user holds no CONNECT ANY DATABASE and cannot grant it (Msg 4613), and in msdb it is in no role and may not add a member to `db_datareader` (Msg 15151). What it can give:

```sql
-- as the RDS master user
CREATE LOGIN [pgvigil_monitor] WITH PASSWORD = '<a long random password>';
GRANT VIEW SERVER STATE TO [pgvigil_monitor];
GRANT VIEW ANY DEFINITION TO [pgvigil_monitor];
GRANT ALTER TRACE TO [pgvigil_monitor];   -- the default trace reader; the master user holds it WITH GRANT OPTION
USE msdb;   -- the three Agent tables the master user holds WITH GRANT OPTION
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];
GRANT SELECT ON dbo.sysjobs TO [pgvigil_monitor];
GRANT SELECT ON dbo.sysjobhistory TO [pgvigil_monitor];
GRANT SELECT ON dbo.sysjobactivity TO [pgvigil_monitor];
-- in each database whose procedures, indexes, statistics and Query Store pgvigil is to name:
USE [<database>];
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];
ALTER ROLE db_datareader ADD MEMBER [pgvigil_monitor];   -- the statistics' properties (sys.dm_db_stats_properties asks SELECT)
```

A database made later needs its own user before pgvigil reads it.

The instance's security group admits the collector's address on 1433 (a /32, never a range).

### What runs

Detected as `rdssqlserver` by the database `rdsadmin`. Every collection runs as on a server someone runs, except where the service or the login it allows says otherwise:

| collection | on Amazon RDS (Express) | why |
| --- | --- | --- |
| `mssql_instance`, `mssql_services`, `mssql_requests`, `mssql_waits` | runs | as on a server (VIEW SERVER STATE) |
| `mssql_cpu`, `mssql_memory`, `mssql_fileio`, `mssql_tempdb`, `mssql_properties`, `mssql_storage`, `mssql_versionstore` | runs | as on a server |
| `mssql_mirroring`, `mssql_replication` | runs | nothing to read on Express (no mirroring, no distributor): stored as none |
| `mssql_procstats` | runs | every cached procedure of every database (one server-wide DMV); a database the login has no user in keeps its procedures' ids without their names, and the run says partial |
| `mssql_indexlocks`, `mssql_querystore` | runs | in the databases the login has a user in; the others are not read (the master user cannot enter `model`, so no user can be made there) |
| `mssql_backups` | runs | `msdb.dbo.backupset` is readable without a grant there. RDS's automated backups and snapshots are the service's own storage snapshots and are not counted: what msdb holds of the instance's own is the full backups RDS writes to the NUL device while it builds the instance (msdb, model, rdsadmin; never a last full backup, as on any server) and native backups (`msdb.dbo.rds_backup_database`), which count as on a server. The last-backup check speaks of native backups alone |
| `mssql_xe` | runs | reads pgvigil's sessions where they exist. RDS refuses event sessions on Express and Web (its trigger `rds_extended_events_trigger`: "supports extended events only for the Enterprise and Standard editions"): there every capture reads `not installed` |
| `mssql_ag` | skipped | Always On is not enabled on this server (Express, single-AZ) |
| `mssql_logshipping` | skipped | RDS has no log shipping (and its master user cannot grant msdb's log shipping tables) |
| `mssql_jobs` | skipped | the read needs eleven msdb tables and the master user can grant three (`sysjobs`, `sysjobhistory`, `sysjobactivity`); the skip names the first table it cannot read. Express has no Agent at all |
| `mssql_audit`, `mssql_checks`, `mssql_traceflags` | runs | as on a server: `sys.server_audits` and their specifications (RDS keeps two audits of its own, read like any other), `sys.configurations`, `DBCC TRACESTATUS(-1)` (RDS sets trace flags of its own, listed like any other) |
| `mssql_errorlog` | runs | the current log only, through `rdsadmin.dbo.rds_read_error_log` (the archives are not readable that way); the reader's state says so |
| `mssql_defaulttrace` | runs | needs ALTER TRACE (in the login above): the default trace's growths, shrinks, DBCC commands and object changes |
| `mssql_syshealth` | runs | reads the `system_health` session's event files; an Express db.t3.micro writes no `sp_server_diagnostics_component_result` there, so nothing is stored (and nothing is missing) |
| `mssql_identity`, `mssql_indexes`, `mssql_stats` | runs | in the user databases the login has a user in; `rdsadmin`, the service's own database, is left out (its tables are not the DBA's and the master user cannot give a login SELECT there) |
| `mssql_plancache`, `mssql_plancache_health` | runs | as on a server. On a db.t3.micro SQL Server's memory target is about 115 MB and a plan stays cached only while it is used (recompiled every few seconds under load), so both lists hold what runs at the moment of the read |

RDS's own procedures (`rds_*` in msdb) are not read in this release.

## Proof

Two proofs, each against a real instance made for it and removed after it:

- `scripts/proof-mssql-azuresqldb.sh` against a General Purpose serverless database (the subscription's free offer) made by `scripts/lab/azure-sqldb.sh`.
- `scripts/proof-mssql-rds.sh` against an RDS for SQL Server Express instance (db.t3.micro, SQL Server 2019) made by `scripts/lab/aws-rds-mssql.sh`.

Each proof checks the collector's rights, the platform and edition stored, every one of the 21 SQL Server collections (stored rows equal to the setup login's read of the same view, or a skip whose note says why, never counted as collected or failed), the instance's pages, and that the monitored side is unchanged by the collector. The lab scripts make each resource with a tag, admit one address, keep the passwords only in a mode-600 file under `.lab/`, and take everything down with the listing read back.

### Results

Run on 2026-11-11 from a machine in another cloud, each service's door admitting that machine alone:

| service | instance | result |
| --- | --- | --- |
| Azure SQL Database | General Purpose serverless Gen5, 1 vCore (the free offer), engine 12.0.2000.8 | PASS: the contained user's rights; platform `azuresqldb`, engine edition 5; 4 collections stored equal to the setup login's read of the same views, 28 skipped by an Azure SQL Database rule with nothing stored; the Summary and 33 tabs, each skipped tab saying why; the database unchanged by the collector |
| Amazon RDS for SQL Server | Express Edition 15.0.4500.2 (SQL Server 2019), db.t3.micro | PASS: the RDS form of the login; platform `rdssqlserver`, engine edition 4; 29 collections stored equal to the master user's read of the same views (counters between a read before and a read after the run), 3 skipped by an RDS rule (`mssql_ag`, `mssql_logshipping`, `mssql_jobs`); the Summary (no cell stale or never read) and 33 tabs; the server unchanged by the collector |

What the RDS instance could not show, and the proof says so in its result: an Extended Events session of pgvigil's running (RDS refuses them on Express; every capture reads `not installed`, as the master user reads it), and a system_health component row's content (the instance writes none). On a db.t3.micro a plan stays cached only while it runs: the procedure, statement and plan-count reads were compared while a session ran the proof's own statements, a statement's plan by its handle and offsets where the cache compiled it again between the reads.

## Not proven, not in this release

- Azure SQL Database: the Basic, S0 and S1 tiers and elastic pools (their rights differ, above), Microsoft Entra authentication, a geo-replica.
- Amazon RDS: editions other than Express (Web, Standard, Enterprise: SQL Server Agent and its jobs, Multi-AZ with Always On or mirroring), Windows authentication through AWS Managed Microsoft AD, RDS Custom.
- Not in this release: Azure SQL Managed Instance, Google Cloud SQL for SQL Server and AlloyDB are not proven against a real instance; a Managed Instance is detected and read like a server, with no collection switched off by its kind.
