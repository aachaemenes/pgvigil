# SQL Server in the cloud: Azure SQL Database, Amazon RDS and Google Cloud SQL

The [SQL Server engine](sqlserver.md) reads two managed services besides a server someone runs: Azure SQL Database and Amazon RDS for SQL Server. This page says, per service, how pgvigil tells it apart, which login it needs, what each collection does there and why, and what was proven against a real instance of each.

Nothing is installed on the monitored server and nothing is written there, on either service: the proofs read every object, principal, permission and event session before and after the collector's runs and find them equal.

## How pgvigil tells the services apart

Before each collection the collector asks the server what it is (`internal/mssql/detect.go`):

| service | engine edition | other sign | platform stored | version stored |
| --- | --- | --- | --- | --- |
| Azure SQL Database | 5 | | `azuresqldb` | 12.0 (120000) whatever engine runs it |
| Amazon RDS for SQL Server | 2, 3 or 4 (Standard, Enterprise, Express; Web reads as Standard) | the database `rdsadmin` exists | `rdssqlserver` | the engine's own (SQL Server 2019 = 150000) |
| Azure SQL Managed Instance | 8 | | `azuresqlmi` | 12.0 |
| Google Cloud SQL for SQL Server | 2, 3 or 4 | the server role `CustomerDbRootRole` on a Linux host; the login sees the role only with VIEW ANY DEFINITION | `cloudsqlsqlserver` | the engine's own |

`platform:` in the configuration names the service instead (`azuresqldb`, `rds`, `azuresqlmi`, `cloudsql`, `onprem`); `auto` (the default) keeps what the server says. The instance's Summary shows the platform as a badge beside its name.

## Signing in without a stored password

A SQL Server instance's authentication (its `auth` on Admin > Instances, or its connection string in `pgvigil.yaml`) says how the collector signs in. Three ways keep no password in pgvigil's files:

| the collector runs on | the server | Admin > Instances | `pgvigil.yaml` connection string |
| --- | --- | --- | --- |
| an Azure VM (or another Azure host) with a managed identity | Azure SQL Database (an elastic pool's databases too), Azure SQL Managed Instance | auth `entra-identity`; the login is a user-assigned identity's client id, empty for the host's system-assigned identity | `sqlserver://<server>.database.windows.net?database=<db>&fedauth=ActiveDirectoryManagedIdentity` (a user-assigned identity: `sqlserver://<client id>@<server>.database.windows.net?...`) |
| Windows, the service running as a gMSA or a domain account | a SQL Server that takes Windows logins: one you run; Amazon RDS for SQL Server joined to AWS Managed Microsoft AD; Google Cloud SQL for SQL Server joined to Managed Service for Microsoft Active Directory | auth `windows` (the service's own account) | `sqlserver://<host>?encrypt=true` (no login: the service's account) |
| Linux, with a Kerberos key | the same | auth `windows`; with a keytab the login is the principal (`user@REALM`, or a gMSA's `name$@REALM`) and the driver options name the key: `krb5-keytabfile=/etc/pgvigil/pgvigil.keytab&krb5-configfile=/etc/krb5.conf` (or `KRB5_KTNAME` in the service's environment); with a credential cache the login stays empty (the cache names the principal): `krb5-credcachefile=<file>&krb5-configfile=/etc/krb5.conf`, or `KRB5CCNAME` | `server=<host>;user id=<principal>;authenticator=krb5;krb5-keytabfile=/etc/pgvigil/pgvigil.keytab;krb5-configfile=/etc/krb5.conf;encrypt=true` |

- On the server the identity becomes a login like any other, made by an Entra admin for `entra-identity` (`CREATE USER [<the identity's name>] FROM EXTERNAL PROVIDER;` in each database read on Azure SQL Database) and by a Windows login for `windows` (`CREATE LOGIN [DOMAIN\pgvigil-gmsa$] FROM WINDOWS;`), with the rights each service's section below names.
- A Kerberos keytab or credential cache is a stored key: on Linux it stands where Windows keeps a gMSA's password, and the host keeps it fresh outside pgvigil (a gMSA's password changes, every 30 days by default, so its keytab is fetched again). Only on Windows does a gMSA keep no key on the collector's disk.
- Off Windows, `windows` is always Kerberos (`authenticator=krb5`), never NTLM: go-mssqldb's NTLM, given no `DOMAIN\user`, falls back to a SQL login with an empty user name (`Login failed for user ''`). A keytab needs its principal, and a credential cache must not have one (with a login go-mssqldb looks for a keytab first, `/etc/krb5.keytab` on a domain-joined host): the page refuses either mistake. A connection string that names no login, no password and no sign-in at all (a Windows row saved before this release) is opened with Kerberos too.
- `entra` is an Entra service principal: its application id (`<application id>@<tenant>` names the tenant; without it the server's) and its secret, kept in the instance's credential file as a SQL login's password is.
- Each Entra identity gets one Azure credential for the life of the collector, so a connect reuses the token until it nears its expiry (`internal/mssqlopen`). A token is asked for only for Azure SQL (`https://database.windows.net/` and its Government and China forms): a server that asks for another resource's token is refused. Every SQL Server reader opens through it: the collector, the actions door, custom reports, Admin > Instances' test and sync, and the DBA Dash import and door.
- Amazon RDS and Google Cloud SQL offer no IAM database sign-in for SQL Server: their password-free way is Windows authentication through the provider's managed Active Directory (above).
- A collector outside Azure has no managed identity: Entra workload identity federation (an app registration's federated credential, no secret) is not in this release; a service principal (`entra`) works there.
- Not proven against a live service in this release: `entra-identity` and `entra` on Azure, and Kerberos against a real domain controller; the proofs show the strings pgvigil writes, the sign-in each one asks for, and that `windows` off Windows never falls back to a SQL login.

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
| `mssql_syshealth` | skipped | "In Azure SQL Database and SQL database in Fabric, event sessions are always database-scoped" ([Extended Events in Azure SQL](https://learn.microsoft.com/en-us/azure/azure-sql/database/xevent-db-diff-from-svr)); the `system_health` session's page applies to SQL Server and Managed Instance only ([Use the system_health session](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/use-the-system-health-session)) |
| `mssql_traceflags` | skipped | trace flags are instance configuration, T-SQL not supported there: "Use service tiers and compute sizes instead" ([T-SQL differences](https://learn.microsoft.com/en-us/azure/azure-sql/database/transact-sql-tsql-differences-sql-server)) |
| `mssql_checks`, `mssql_identity`, `mssql_indexes`, `mssql_stats`, `mssql_plancache`, `mssql_plancache_health` | skipped (not yet) | the server options, msdb and the other databases are the service's; the database's own identity columns, indexes, statistics and plan cache are a later wave |

The database's own resource use (`sys.dm_db_resource_stats`), its files and its Query Store are not read in this release.

### Extended Events

`pgvigil mssql-xe -print -form azuresqldb -install-id <id>` prints the four database-scoped sessions (ring buffer targets); the database's admin runs it in the monitored database. The collector only reads them.

## Azure SQL Database elastic pools

A database in an elastic pool is an Azure SQL Database instance like any other; `mssql_pool` adds its pool's figures, a row a minute, and the Elastic pool page (DBA Dash's Azure Summary pool grid and its pool's Pool tab).

- **Where the figures come from:** `sys.dm_elastic_pool_resource_stats` in the pooled database itself. Microsoft: it "returns the same data in any database in the same elastic pool", a row "every few seconds", kept "approximately 40 minutes", and needs VIEW SERVER STATE (on Azure SQL Database the server-level role `##MS_ServerStateReader##`, added in master by the server admin or the Entra admin). DBA Dash reads master's `sys.elastic_pool_resource_stats` instead (14 days, but it needs `dbmanager`, which also creates and alters databases); pgvigil asks for no master login.
- **A minute:** the average of the view's few-second averages (CPU, data IO, log write, eDTU on a DTU pool, the instance's CPU and memory), the largest of its maxima (workers, sessions), the largest average CPU as the minute's maximum CPU, and the storage figures as the minute ended (used, allocated, the pool's maximum data size). A minute is stored only once 30 seconds have passed after its end (Microsoft adds a row "every few seconds", and a stored minute is never rewritten), and never the oldest minute of a read (the view's oldest minute may have lost its first rows). Every pooled database pgvigil reads sends what it saw; a minute is stored once per pool, by the first database read. A collector outage longer than about 40 minutes leaves a gap.
- **The pool's name:** the view names none. pgvigil takes `sys.database_service_objectives` where the login may read it (Microsoft: dbManager in master, or the database's creator or owner; on a live Basic pool a login holding `##MS_ServerStateReader##` with a plain user in the database read it too), else the instance's tag `pool:<name>` (an Azure source's proposal of a pooled database carries it, from the database's `elasticPoolId`: [discovery.md](discovery.md)), else the run is skipped and says so. A tag that names another pool than the database's own answer is a skip with both names. Where only the tag is readable it is trusted as given: a database moved to another pool would write its new pool's figures under the tag's name, mixed minute by minute with the old pool's, until the tag changes - so the login that may read its service objectives is the safer one.
- **Limits:** the view gives the pool's maximum data size and its percentages of the pool's other limits, not the DTU or vCore limit itself; the page shows percentages.
- **Elastic Pool Storage:** DBA Dash's cell, the pool's allocated storage as a percentage of its maximum data size against warning 80 % and critical 90 % (DBA Dash's defaults; `pgvigil.mssql_pool_thresholds` holds a pool's own, the row with an empty server and pool is the default). DBA Dash compares with a strict "over": 80 % is OK, 90 % is Warning, 91 % is Critical; a missing WARNING threshold is N/A (a missing critical one, or a missing percentage, compares as false: DBA Dash's view). pgvigil's own additions: N/A for a pool with no minute in the last 5 minutes, and no cell at all on a database not read in a pool for over 10 minutes (it left the pool). pgvigil shows it in the Summary's Elastic Pool Storage column (hidden while no instance is in a pool: n/a elsewhere) and on each pooled database's Elastic pool page (its tab, under Performance, is shown only while the database is read in a pool).

Proven against a live Basic 50 eDTU pool of two databases: the read as a login holding `##MS_ServerStateReader##` with a user in the database (six complete minutes equal, field by field, to the server admin's read of the view right after), the role's reach (`##MS_DatabaseConnector##` and `##MS_ServerStateReader##` with no user in the database read the view), the pool's name from `sys.database_service_objectives`, the store's one row a minute from the first of the two databases, and the storage cell (OK). Not proven live: a vCore pool's columns (instance CPU and memory), and the cell against master's own `sys.elastic_pool_resource_stats`.

## Google Cloud SQL for SQL Server

Google's own SQL Server instances: SQL Server on Linux that Google runs, the customer's highest login being the `sqlserver` user (no sysadmin). DBA Dash has no Cloud SQL detection; this is pgvigil's own reading of Google's pages, run so far only against a simulation (below).

### How it is told apart

Google's own mark is the server role `CustomerDbRootRole` (the `sqlserver` user is its member, and grants it makes name it as their grantor). Detection asks for it, on a Linux host, only on a server that is neither Azure nor RDS, in a statement of its own (a role of that name carried to a Windows server is not Cloud SQL). msdb's `gcloudsql_bulk_insert` is no mark: Google creates it only once the bulk-insert flag is on. A login sees the role only with VIEW ANY DEFINITION; a login without it reads the instance as a server someone runs, unless the configuration's `platform: cloudsql` (or Admin > Instances' platform Google Cloud SQL) names it.

### The login

Made in T-SQL by the `sqlserver` user (a user made through gcloud or the console gets the `sqlserver` user's own rights, more than a monitor needs):

```sql
-- in master, as the sqlserver user
CREATE LOGIN [pgvigil_monitor] WITH PASSWORD = '<a long random password>';
GRANT VIEW SERVER STATE TO [pgvigil_monitor];
GRANT VIEW ANY DEFINITION TO [pgvigil_monitor];
-- in msdb
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];
ALTER ROLE db_datareader ADD MEMBER [pgvigil_monitor];
```

Whether the `sqlserver` user may grant each of these (Google's pages show its own rights, not which it may pass on) is settled only against a real instance, and so is the msdb part: Google protects msdb from users created through SQL Server directly (its Managed Microsoft AD page, on SQL Server Agent), so the two msdb lines may be refused and the jobs then not read. Google offers no IAM sign-in for SQL Server; the password-free way is Windows authentication through Managed Service for Microsoft Active Directory (above).

### What runs

The collections run as on a server someone runs, with these differences:

- SQL Server Agent's jobs: read when msdb lets the login in; otherwise skipped with Google's reason (msdb is protected from logins made in T-SQL; a user made through the console or gcloud carries `CustomerDbRootRole`'s rights, more than a monitor needs). Not settled until a real instance answers.
- The Windows power plan: not read (Google runs the host; SQL Server on Linux there).
- Extended Events: `pgvigil mssql-xe -print -form cloudsql` writes the slow capture's event file under `/var/opt/mssql/xevents/`, the folder Google names. Cloud SQL has no `sp_configure` and its database flags offer no blocked process threshold, so the blocked-process session stays empty there; deadlocks, slow queries and attention still capture.
- Trace flags: the Checks page advises the trace flags a server someone runs should have on (3226, 7745) only on such a server; on Cloud SQL a trace flag is Google's database flag, not advised.

Not settled until a real instance answers: SQL Server Agent's jobs (above), the blocked process threshold (no flag found), the error log (Google sends it to Cloud Logging; whether `sp_readerrorlog` answers the monitoring login), the default trace, Extended Events sessions made by a login other than the `sqlserver` user, Database Mail, Resource Governor and server triggers (Google lists them as unavailable), and how a high-availability instance or a read replica shows itself in T-SQL.

### Proof

`scripts/proof-cloudsql-sim.sh` is a SIMULATION: a SQL Server 2022 container on Linux wearing Cloud SQL's role. A login with exactly the grants above is stored as `cloudsqlsqlserver`; without VIEW ANY DEFINITION the role is invisible and the instance is a server, until `platform: cloudsql` names it; every collection ends as it ends on the same server and login with `platform: onprem`. Against a real Cloud SQL instance: not proven in this release.

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

Each proof checks the collector's rights, the platform and edition stored, every one of the 32 SQL Server collections (stored rows equal to the setup login's read of the same view, or a skip whose note says why, never counted as collected or failed), the instance's pages, and that the monitored side is unchanged by the collector. The lab scripts make each resource with a tag, admit one address, keep the passwords only in a mode-600 file under `.lab/`, and take everything down with the listing read back.

### Results

Run on 2026-11-11 from a machine in another cloud, each service's door admitting that machine alone:

| service | instance | result |
| --- | --- | --- |
| Azure SQL Database | General Purpose serverless Gen5, 1 vCore (the free offer), engine 12.0.2000.8 | PASS: the contained user's rights; platform `azuresqldb`, engine edition 5; 4 collections stored equal to the setup login's read of the same views, 28 skipped by an Azure SQL Database rule with nothing stored; the Summary and 33 tabs, each skipped tab saying why; the database unchanged by the collector |
| Amazon RDS for SQL Server | Express Edition 15.0.4500.2 (SQL Server 2019), db.t3.micro | PASS: the RDS form of the login; platform `rdssqlserver`, engine edition 4; 29 collections stored equal to the master user's read of the same views (counters between a read before and a read after the run; `mssql_syshealth` 0 = 0, below), 3 skipped by an RDS rule (`mssql_ag`, `mssql_logshipping`, `mssql_jobs`); the Summary (no cell stale or never read) and 33 tabs; the server unchanged by the collector |

What the RDS instance could not show, and the proof says so in its result: an Extended Events session of pgvigil's running (RDS refuses them on Express; every capture reads `not installed`, as the master user reads it), and a system_health component row's content (the instance writes none). On a db.t3.micro a plan stays cached only while it runs: the procedure, statement and plan-count reads were compared while a session ran the proof's own statements, a statement's plan by its handle and offsets where the cache compiled it again between the reads, and its count against the read that lists the same plan; where no read listed it, the proof says so.

These results are for this release's code, which includes the collector and page changes the proofs found (Azure SQL Database's VIEW DATABASE STATE check, its event session form, the skipped tabs' lines, the RDS skip notes, and `rdsadmin` left out of the per-database passes).

## Not proven, not in this release

- Azure SQL Database: the Basic, S0 and S1 tiers as single databases (their rights differ, above; a Basic elastic pool is proven live: the elastic pools section), a vCore elastic pool, Microsoft Entra sign-in against a live server (`entra-identity` and `entra` are built: above), a geo-replica.
- Amazon RDS: editions other than Express (Web, Standard, Enterprise: SQL Server Agent and its jobs, Multi-AZ with Always On or mirroring), Windows authentication through AWS Managed Microsoft AD, RDS Custom.
- Not in this release: Azure SQL Managed Instance, Google Cloud SQL for SQL Server (only its simulation, above) and AlloyDB are not proven against a real instance; a Managed Instance is detected and read like a server, with no collection switched off by its kind.
