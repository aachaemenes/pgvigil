# SQL Server in the cloud: Azure SQL Database, Azure SQL Managed Instance, Amazon RDS and Google Cloud SQL

The [SQL Server engine](sqlserver.md) reads four managed services besides a server someone runs: Azure SQL Database, Azure SQL Managed Instance, Amazon RDS for SQL Server and Google Cloud SQL for SQL Server. This page says, per service, how pgvigil tells it apart, which login it needs, what each collection does there and why, and what was proven against a real instance of each.

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
- Community tools and custom reports on an instance added in Admin > Instances (`doors: page_instance_reads: on`) open for `sql` and `entra` only: `windows` and `entra-identity` sign in as `pgvigil serve` itself, so a tool or report on such an instance runs only from `pgvigil.yaml` ([Configuration](configuration.md#community-tools-and-custom-reports-on-a-page-instance)).
- A collector outside Azure has no managed identity: Entra workload identity federation (an app registration's federated credential, no secret) is not in this release; a service principal (`entra`) works there.
- Proven against a live service (2026-11-13, a Basic elastic pool of Azure SQL Database): `entra-identity` with an Azure VM's system-assigned identity, made a user of one pooled database by its client id (`CREATE USER [<name>] WITH SID = <client id as binary(16)>, TYPE = E;`, which needs no directory role). Five connects signed in as that one identity; the other database, where it has no user, refused it (`Login failed for user '<token-identified principal>'`, 18456); and `pgvigil collect -once mssql_instance` with the connection string pgvigil writes for `entra-identity` (no login, no password) stored the instance as Azure SQL Database. The identity held VIEW DATABASE STATE only, so mssql_instance ended partial: the CPU count, memory and start time need VIEW SERVER STATE (`##MS_ServerStateReader##` in master: the Azure SQL Database section).
- Not proven against a live service in this release: `entra` (a service principal) on Azure, a user-assigned identity, `entra-identity` on an Azure SQL Managed Instance, and Kerberos against a real domain controller; the proofs show the strings pgvigil writes, the sign-in each one asks for, and that `windows` off Windows never falls back to a SQL login.

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

Nine collections of this table run; the others are skipped by an Azure SQL Database rule, each with its reason on the run's row and on the page that would show it ("Not read on this instance: ... is skipped (...)"), and the Summary lists their groups as "not on this platform" (its Disk cell too: the platform has no volumes).

| collection | on Azure SQL Database | why |
| --- | --- | --- |
| `mssql_instance` | runs | `sys.configurations` (read-only there), the server's description, `sys.dm_os_sys_info` with VIEW DATABASE STATE |
| `mssql_requests` | runs | the database's own sessions and requests (`database_id = DB_ID()`), no task columns |
| `mssql_waits` | runs | `sys.dm_db_wait_stats`: the database's own waits (the server-wide view is the logical server's, not the tenant's) |
| `mssql_waiting_tasks` | runs | the tasks waiting now, `sys.dm_os_waiting_tasks` with VIEW DATABASE STATE (the right Microsoft names there outside Basic, S0, S1 and pools) |
| `mssql_xe` | runs | the database-scoped sessions of pgvigil's script (`sys.database_event_sessions`, `sys.dm_xe_database_sessions`), ring buffer targets |
| `mssql_azuredb_resources` | runs | the database's resource use, a row a minute from `sys.dm_db_resource_stats` (VIEW DATABASE STATE on every tier): [below](#resource-use-and-the-tier) |
| `mssql_azuredb_governance` | runs | the tier and its limits, hourly, from `sys.dm_user_db_resource_governance` (VIEW DATABASE STATE or `##MS_ServerStateReader##`; on Basic, S0, S1 and in an elastic pool the role, the server admin or the Entra admin: VIEW DATABASE STATE alone is not enough there) |
| `mssql_pool_limits` | runs in an elastic pool, hourly | [Pool history](#pool-history-an-opt-in): master's `sys.elastic_pool_resource_stats` on a connection of its own to master, only where the login holds `dbmanager` there (an opt-in); skipped with its words otherwise |
| `mssql_storage` | runs | the database's own files from `sys.database_files` with the space used inside each (`FILEPROPERTY`); no volumes. That a user with CONNECT only gets the space used is not proven yet (Microsoft: `FILEPROPERTY` gives NULL to a caller without permission on the object); the proof asserts it |
| `mssql_services` | skipped | no SQL Server Agent, no Database Mail, no memory dump files to read |
| `mssql_activity` | skipped | `sys.dm_os_performance_counters` and the server's sessions there are the host's |
| `mssql_reports` | skipped | no server roles, SQL logins or service list of its own to read |
| `mssql_pool` | runs in an elastic pool, else skipped | the pool's figures from `sys.dm_elastic_pool_resource_stats`: [elastic pools](#azure-sql-database-elastic-pools) |
| `mssql_ag`, `mssql_mirroring`, `mssql_fci`, `mssql_logshipping`, `mssql_replication` | skipped | none of them exists on the service (its geo-replication is `mssql_georepl`'s, below) |
| `mssql_georepl` | runs | the database's active geo-replication links, every minute (VIEW DATABASE STATE) |
| `mssql_failover_groups` | runs with an `azure:` block | the logical server's failover groups from Azure Resource Manager, every 5 minutes |
| `mssql_jobs` | skipped | no SQL Server Agent (Elastic Jobs are not read) |
| `mssql_backups` | skipped | no backup history in msdb: the backups are the service's own |
| `mssql_versionstore` | skipped | tempdb's version store is not the tenant's |
| `mssql_cpu` | skipped | the database's CPU is `mssql_azuredb_resources`' (`sys.dm_db_resource_stats`, the view DBA Dash reads there); the CPU tab, the Performance page and the Performance summary read it |
| `mssql_memory`, `mssql_fileio`, `mssql_tempdb`, `mssql_properties` | skipped | the memory, file stats, tempdb and processors there are the host's, not the database's; the Properties page shows the tier's rows of `mssql_azuredb_governance` instead |
| `mssql_procstats`, `mssql_funcstats` | runs, with the tier's right | `sys.dm_exec_procedure_stats`, `_function_stats` and `_trigger_stats`, cut to the connection's own database (Microsoft: there `database_id` is "unique within a single database or an elastic pool, but not within a logical server"); on Basic, S0, S1 and in an elastic pool Microsoft asks for the server admin, the Entra admin or `##MS_ServerStateReader##` (the documented login's role), elsewhere `VIEW DATABASE STATE`; no server triggers there. The logical server's and the pool's Object Execution tab reads them. Not proven on a live Azure SQL Database yet: the next Azure lab |
| `mssql_indexlocks`, `mssql_querystore` | skipped (not yet) | the database's own index and Query Store reads are a later wave |
| `mssql_audit` | skipped | the service's auditing writes "to an audit log in your Azure storage account, Log Analytics workspace, or Event Hubs", and the T-SQL differences page says "SQL Server audit: Use SQL Database auditing instead" ([Auditing for Azure SQL Database](https://learn.microsoft.com/en-us/azure/azure-sql/database/auditing-overview); `sys.server_audits` applies to SQL Server and Managed Instance only) |
| `mssql_defaulttrace` | skipped | "SQL Server trace" is T-SQL syntax not supported in Azure SQL Database ([T-SQL differences](https://learn.microsoft.com/en-us/azure/azure-sql/database/transact-sql-tsql-differences-sql-server)); `sys.traces` applies to SQL Server and Managed Instance only |
| `mssql_errorlog` | skipped | `sys.sp_readerrorlog` applies to SQL Server only ([sys.sp_readerrorlog](https://learn.microsoft.com/en-us/sql/relational-databases/system-stored-procedures/sp-readerrorlog-transact-sql)); the service names no error log a login can read |
| `mssql_syshealth` | skipped | "In Azure SQL Database and SQL database in Fabric, event sessions are always database-scoped" ([Extended Events in Azure SQL](https://learn.microsoft.com/en-us/azure/azure-sql/database/xevent-db-diff-from-svr)); the `system_health` session's page applies to SQL Server and Managed Instance only ([Use the system_health session](https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/use-the-system-health-session)) |
| `mssql_traceflags` | skipped | trace flags are instance configuration, T-SQL not supported there: "Use service tiers and compute sizes instead" ([T-SQL differences](https://learn.microsoft.com/en-us/azure/azure-sql/database/transact-sql-tsql-differences-sql-server)) |
| `mssql_checks`, `mssql_identity`, `mssql_indexes`, `mssql_stats`, `mssql_plancache`, `mssql_plancache_health` | skipped (not yet) | the server options, msdb and the other databases are the service's; the database's own identity columns, indexes, statistics and plan cache are a later wave |

The database's Query Store is not read in this release.

### Resource use and the tier

DBA Dash's Azure Summary and its instance's Azure DB tab are the shape: the root page **Azure Summary** lists every Azure SQL Database over the window, and the instance's **Azure** tab (Performance) shows one.

The tree's Azure folder holds each **logical server** and each **elastic pool** as a page of its own, with DBA Dash's tabs in DBA Dash's order: a logical server has Performance Summary, Azure Summary, Alerts, Slow Queries, Object Execution and Running Queries; an elastic pool has Pool (the pool's own figures, read through one of its databases), Performance Summary, Azure Summary, Slow Queries, Object Execution, Running Queries and DB Space. Each tab is the fleet's page cut to the node's databases (the Azure SQL Databases pgvigil reads on that server or in that pool, within the tag folder when one is open); Object Execution lists the procedures, functions and triggers of all those databases in one grid with an instance column. A node opens on its first tab.

- **`mssql_azuredb_resources`, every minute.** It reads DBA Dash's 13 columns of `sys.dm_db_resource_stats` (Microsoft: "a row for every 15 seconds", kept "approximately one hour") from the end of the newest stored minute, filtered on the server. A minute holds the averages of its 15-second rows, the largest CPU, data IO, log write, memory, XTP storage, instance CPU and instance memory of them (the seven maxima of DBA Dash's raw view), DBA Dash's DTU % per row (the greatest of CPU, data IO and log write when `dtu_limit` is over 0; none on vCore) with the DTUs that makes, the row count, and ten bucket counts each of DTU, CPU, data IO and log write (under 10 %, 10-20 % ... 80-90 %, 90 % and over). The 15-second rows are not kept. A minute is stored once 30 seconds have passed after its end and never rewritten; the oldest minute of a first read is not stored (the view drops its oldest rows one by one).
- **Its cost.** A collection run that applies opens its own connection, so `mssql_azuredb_resources` is one more connection a minute to each database; a run whose collection does not apply there opens none while the database's last detect is under 2 minutes old (about 5 connections a minute on an Azure SQL Database, where 7 of the 12 minute collections do not apply). The store's side at 1,819 databases is a test of its own (`TestAzureDBFleetScaleOnAStore`, run with `PGVIGIL_SCALE_TEST=1`).
- **Gaps.** When the view's oldest row starts after the newest stored minute (the collector down over the view's hour, a failover - Microsoft: the view then returns "data for the time since that failover" - or a serverless pause), the minutes between are lost: pgvigil stores the gap, and the Azure tab and the Azure Summary name it. A gap is seen when the view's oldest row ends over 16 s (a row's 15 s and 1 s for a late row) after the newest stored minute; a row lost when the rows end less than a second after the minute is not seen, and that minute is stored with one row fewer (its row count says so).
- **The averages over a window** weigh each minute by its rows, so they equal DBA Dash's average over the view's rows; a maximum is the largest row; the histograms sum the bucket counts. **The hours** (`mssql_azuredb_hour`, 0167): DBA Dash's `AzureDBResourceStats_60MIN` shape (its averages, maxima, the limits and the 40 bucket counts per UTC hour), kept 730 days as DBA Dash's, filled as each minute is stored; a window reads its built whole hours from them and only its two edge parts (and any hour not built yet) from the minutes, so a day or a year reads hours, and the numbers are the minutes' at any length; the CPU charts (the Performance page and the instance's CPU tab) read the minutes up to a day and whole hours past it. Two departures, stated: pgvigil keeps each hour's totals and sample counts (not its average), so a long window's average is the minutes' exactly where DBA Dash averages hourly averages; and it never rounds a window to hours (DBA Dash reads hours for a window over 24 hours or on whole-hour bounds). pgvigil also keeps the limits' minimum beside DBA Dash's maximum. After an upgrade from a release without the hours, `pgvigil purge` builds them, one database a transaction; until then those databases read their minutes. Their size: about 31.9 million rows over 730 days at 1,819 databases, about 14 GB of heap and 1 to 1.3 GB of key (an estimate; the fleet scale test measures a day of them).
- **`mssql_azuredb_governance`, hourly.** It reads the database's row of `sys.dm_user_db_resource_governance` whole (every column the view has: Microsoft calls its data "intended for internal consumption and ... subject to change") with the edition, service objective and max size from `DATABASEPROPERTYEX`, and the pool's name as `mssql_pool` takes it. A new history row is kept when one of the 54 columns DBA Dash compares (every column it reads but `user_data_directory_space_usage_mb`), the edition, the service objective or the pool changes. The tier's figures are the instance's Properties rows (group Azure SQL Database); a change of the service objective, the pool, the DTU limit or the vCore limit is listed under Properties' Changes (DBA Dash's DTU limit change).
- **`mssql_storage`.** The database's files with the space used inside them; the Summary's **% Max Size** cell is DBA Dash's status there: the PRIMARY filegroup's data files' allocated size against their summed max size, over 80 % a warning and over 90 % critical (DBA Dash's default thresholds, a strict "over"), no status when a file has no max size. A departure: pgvigil's thresholds are fixed at 80 and 90 %; it has none of DBA Dash's `DBFileThresholds` levels (the root one an administrator may edit, an instance's, a database's, a filegroup's).
- **Retention.** The minutes are monthly partitions dropped by `pgvigil purge -days N` (30 by default) with the rest of the history; DBA Dash keeps them 120 days (its DataRetention seed for AzureDBResourceStats): to keep the minutes as long, run the purge with `-days 120`. The hours keep their own age, 730 days (`pgvigil purge -hours mssql_azuredb_hour=<days>`), and each `pgvigil purge` run makes their next month's partition ahead (a store where purge never runs gets it from the month's first import, which then waits on any long read of the hours). The tier's history and the gaps are few rows and kept, as DBA Dash keeps its governance and service objective histories.

Not proven live yet: everything in this part (no lab has run it); a pooled database's figures and the pool's DTU or vCore limit (the pool page shows percentages, below); Hyperscale; a geo-replica (its `replica_role` is stored, a secondary is not read); Business Critical.

### Extended Events

`pgvigil mssql-xe -print -form azuresqldb -install-id <id>` prints the four database-scoped sessions (ring buffer targets); the database's admin runs it in the monitored database. The collector only reads them.

### Geo-replication and failover groups

DBA Dash reads none of this; pgvigil shows it on the database's Availability tab, in its availability group grid's shape.

- **`mssql_georepl`, every minute**, reads `sys.dm_geo_replication_link_status` in the database (Microsoft: a row for each link "between primary and secondary databases"; empty in master; VIEW DATABASE STATE in the database). The lag (`replication_lag_sec`) and the last replication are the primary's only; on a secondary pgvigil shows that the lag is read on the primary. Beside the lag it keeps the primary's **unsent window** (its last commit less the last replication it heard back for, both on the primary's clock) and the time since the last acknowledgement, computed on the server.
- **A failover** is seen as the database's role changing between two reads, or, for an instance whose host is a failover group's listener (`<group>.database.windows.net`), as the link's partner changing while the role stays: the read names the logical server it reached. Either is a change row with the read before it and a critical finding for an hour. The view cannot tell a planned failover from a forced one (Microsoft's own wording is about these T-SQL commands: they "only apply to active geo-replication and do not apply to failover groups"); the Activity Log can, below.
- **Findings** (`mssql_georepl_findings`): the data loss - the greater of the lag and the unsent window - over `georepl_data_loss` for 5 minutes (warning 1 minute, sp_Blitz check 268's 60 s for an availability group's secondary; critical 5 minutes, pgvigil's own), set at the root or a tag (the instance level comes with the threshold engines of a later release); a link SUSPENDED in two reads (critical); seeding for over an hour (warning); a role or partner change (critical, an hour); a link removed while the database is still read (warning, 24 hours).
- **`mssql_failover_groups`, every 5 minutes**, reads the server's groups from Azure Resource Manager (List By Server, api-version 2025-01-01: no T-SQL view shows a group): each group's role, replication state, read-write policy and grace period, read-only policy, secondary type (a Standby secondary takes no reads), partners and databases, one read per logical server per interval whichever of its databases reads it. It also reads, as a trial, each group's failover operations of the last two hours from the Activity Log (it arrives 3 to 20 minutes late) on the group's own resource, on this server and on each partner (a planned failover is logged on the new primary's group), one row per operation however many of its events (started, accepted, succeeded), so a change can say planned, forced, or planned before forced; the caller is never kept. A group's primary moving is a critical finding for an hour. A read that fails gives the server back to its next database's run; three failed runs in a row are the instance's 'collection failing' finding (critical, with the error's words).
- **Its door** is an `azure:` block on the instance (`subscription`, `resource_group`, `server`, and `cloud`: public, usgov or china). The token is the instance's own Entra identity when its connection signs in with one (a service principal written `<application id>@<tenant>`, or a managed identity), else azidentity's default chain (the environment, a workload identity, a managed identity, the Azure CLI's sign-in). The identity needs `Microsoft.Sql/servers/failoverGroups/read` on the server (Reader, or a custom role with that action), and `Microsoft.Insights/eventtypes/values/read` for the Activity Log, on this server and on each partner (the log is read on both). The Activity Log's call is made at the subscription's scope: whether a grant on the server or its resource group is enough for it is not proven (no identity of the lab's own was made). A refusal is stored with Resource Manager's code and the right it needs; a throttle waits for its Retry-After. Without the block nothing calls Resource Manager: the collection says so. A configuration file's door runs under either site profile; the host's administrator turns it on in pgvigil.yaml on that host, never the page. A discovered (page) instance carries no `azure:` block yet: task B24p.
- Managed Instance's geo-replication is not read yet (its view is per database).

## Azure SQL Database elastic pools

A database in an elastic pool is an Azure SQL Database instance like any other; `mssql_pool` adds its pool's figures, a row a minute, and the Elastic pool page (DBA Dash's Azure Summary pool grid and its pool's Pool tab).

- **Where the figures come from:** `sys.dm_elastic_pool_resource_stats` in the pooled database itself. Microsoft: it "returns the same data in any database in the same elastic pool", a row "every few seconds", kept "approximately 40 minutes", and needs VIEW SERVER STATE (on Azure SQL Database the server-level role `##MS_ServerStateReader##`, added in master by the server admin or the Entra admin). DBA Dash reads master's `sys.elastic_pool_resource_stats` instead (14 days, but it needs `dbmanager`, which also creates and alters databases); pgvigil reads the minutes without a master login, and master's view only for [Pool history](#pool-history-an-opt-in), an opt-in.
- **A minute:** the average of the view's few-second averages (CPU, data IO, log write, eDTU on a DTU pool, the instance's CPU and memory), the largest of its maxima (workers, sessions), the largest average CPU as the minute's maximum CPU, and the storage figures as the minute ended (used, allocated, the pool's maximum data size). A minute is stored only once 30 seconds have passed after its end (Microsoft adds a row "every few seconds", and a stored minute is never rewritten), and never the oldest minute of a read (the view's oldest minute may have lost its first rows). Every pooled database pgvigil reads sends what it saw; a minute is stored once per pool, by the first database read. A collector outage longer than about 40 minutes leaves a gap.
- **The pool's name:** the view names none. pgvigil takes `sys.database_service_objectives` where the login may read it (Microsoft: dbManager in master, or the database's creator or owner; on a live Basic pool a login holding `##MS_ServerStateReader##` with a plain user in the database read it too), else the instance's tag `pool:<name>` (an Azure source's proposal of a pooled database carries it, from the database's `elasticPoolId`: [discovery.md](discovery.md)), else the run is skipped and says so. A tag that names another pool than the database's own answer is stale (the database was moved after the tag was written - an Azure source writes it at the approve): the database's own pool is read, and the run ends partial naming both until the tag is changed. Where only the tag is readable it is trusted as given: a database moved to another pool would write its new pool's figures under the tag's name, mixed minute by minute with the old pool's, until the tag changes - so the login that may read its service objectives is the safer one.
- **Limits:** the view gives the pool's maximum data size and its percentages of the pool's other limits, not the DTU or vCore limit itself; the page shows percentages. The DTU and storage limits themselves, over time, are [Pool history](#pool-history-an-opt-in)'s.
- **Elastic Pool Storage:** DBA Dash's cell, the pool's allocated storage as a percentage of its maximum data size against warning 80 % and critical 90 % (DBA Dash's defaults; `pgvigil.mssql_pool_thresholds` holds a pool's own, the row with an empty server and pool is the default). DBA Dash compares with a strict "over": 80 % is OK, 90 % is Warning, 91 % is Critical; a missing WARNING threshold is N/A (a missing critical one, or a missing percentage, compares as false: DBA Dash's view). pgvigil's own additions: N/A for a pool with no minute in the last 5 minutes, and no cell at all on a database not read in a pool for over 10 minutes (it left the pool). pgvigil shows it in the Summary's Elastic Pool Storage column (hidden while no instance is in a pool: n/a elsewhere) and on each pooled database's Elastic pool page (its tab, under Performance, is shown only while the database is read in a pool).

Proven against a live Basic 50 eDTU pool of two databases: the read as a login holding `##MS_ServerStateReader##` with a user in the database (six complete minutes equal, field by field, to the server admin's read of the view right after), the role's reach (`##MS_DatabaseConnector##` and `##MS_ServerStateReader##` with no user in the database read the view), the pool's name from `sys.database_service_objectives`, the store's one row a minute from the first of the two databases, and the storage status (OK). Not proven live: a vCore pool's columns (instance CPU and memory), and the cell against master's own `sys.elastic_pool_resource_stats`.

### Pool history (an opt-in)

DBA Dash's Pool history: each change of an elastic pool's DTU or storage limit, with the old and the new limit and when it changed, on the Azure Summary under its Elastic pools grid and on the pool's own page.

- **Where it comes from:** `mssql_pool_limits`, hourly, on each database in an elastic pool, reads master's `sys.elastic_pool_resource_stats` for the database's own pool. Microsoft: the view "exists in the master database of the logical server", has a row per pool every 15 seconds "retained for 14 days", and "Requires membership in the **dbmanager** role". The read opens a connection of its own to master with the instance's connection settings (its database master), within 15 seconds; a refused or slow master never touches the instance's own connection or its other collections.
- **The right, read first:** in master, `IS_ROLEMEMBER('dbmanager') = 1`, the server admin (`dbo` there; Microsoft: `IS_ROLEMEMBER` answers 0 for `dbo`), or the login's own membership of the server role `##MS_DatabaseManager##` (read in `sys.server_role_members` with `sys.sql_logins`: Microsoft says `IS_SRVROLEMEMBER` is not supported in the master database). Without it the run is skipped with its words, and a pool whose databases were all skipped or failed since their last read shows 'read until <time>; since then: <why>'; a login with no way into master (a contained database user: only a login in master, with `##MS_DatabaseConnector##` or a user in master, signs in there) is skipped too. The page then says why for each pool, and never shows an empty grid.
- **An opt-in:** `dbmanager` lets the login create and drop databases on the logical server, which can cost money. pgvigil's documented login does not hold it and pgvigil never asks for it; the instance's rights script (Admin > Instances) prints this block, every line a comment, to uncomment only where that is accepted:

```sql
-- OPT-IN, not needed: every line below is a comment; uncomment it only where the login may create and drop databases.
-- dbmanager lets the login create and drop databases on this logical server, which can cost money.
-- Only Pool history needs it (the elastic pool's limits over time); pgvigil reads every other figure without it.
-- It needs a LOGIN in master: a contained database user (CREATE USER ... WITH PASSWORD in the database) has none -
-- make a login, a user for it in master and in the database, and point the instance's connection string at it.
-- An Entra identity: CREATE USER [<the identity>] FROM EXTERNAL PROVIDER in master, then the role below.
-- In the logical server's master database, as the server admin or the Entra admin:
-- CREATE USER [<the login>] FROM LOGIN [<the login>];
-- ALTER ROLE dbmanager ADD MEMBER [<the login>];
-- or: ALTER SERVER ROLE ##MS_DatabaseManager## ADD MEMBER [<the login>]; (the server role: the same create and drop of databases)
-- To take it back: ALTER ROLE dbmanager DROP MEMBER [<the login>]; or ALTER SERVER ROLE ##MS_DatabaseManager## DROP MEMBER [<the login>];
```

  Microsoft's server-roles page says to use `##MS_DatabaseManager##` in place of `dbmanager`, while the view's own page names `dbmanager` only. In pgvigil's lab (2026-11-17, a Basic elastic pool) a login holding `##MS_DatabaseManager##` alone, with a user in master, read the view (the same rows as the server admin), so pgvigil takes either. The server role also lets the login create and drop databases: the same opt-in. Like any server role change on Azure SQL Database, it can take up to 5 minutes and a new connection to take effect (Microsoft); the collection opens a new connection to master every hour.
- **The history:** the read sends the view's rows collapsed into periods of equal limits; each pooled database keeps its own copy (so a tag-scoped login sees a pool's history through a database of its scope), and the page lists each change once. The reads overlap every hour (14 days each): a later read continues the stored periods, a change splits one once, the same read twice stores nothing twice; the first read brings the pool's 14 days from before pgvigil read it. `elastic_pool_cpu_limit` is stored but never shown: Microsoft calls it "Identified for informational purposes only. Not supported."; a change of it alone is not a change.
- **Known limit:** two reads of one database's pool imported at the same moment (a `pgvigil collect -once mssql_pool_limits` started within seconds of the hourly read) can store the older read last: its window then replaces the newer read's periods, and the pool's newest change is missing, or its period ends early, until the next hourly read brings master's 14 days back. Where every database of a pool went unread for more than master's 14 days (a paused instance, the opt-in taken back and given again), a change inside that gap is listed as 'between' the last period read before it and the first after it; a change made and undone inside the gap is not seen.
- **Proven live** (`scripts/proof-mssql-poollimits.sh`, 2026-11-17, a Basic elastic pool of two databases): a login with no way into master (skipped, the server's own refusal 916), a user in master without `dbmanager` (skipped), `dbmanager` given (read, the pool's period stored with master's DTU and storage limits), the pool rescaled from 50 to 100 eDTU and 5,000 to 10,000 MB (the change stored as a new period), and the grant taken away again. **Not proven live yet:** the collection's own read as a login holding `##MS_DatabaseManager##` alone - the lab read the view as such a login, and the check that takes the server role came after it; the next Azure lab reruns that step. `TestPoolLimitsLive` (`internal/mssql/pool_limits_test.go`) runs on SQL Server in a container what can run there: the period statement on a seeded copy of the view's columns, the right as the admin, as a plain login and as a member of `##MS_DatabaseManager##` (SQL Server 2022 has the role), and both skips end to end.

## Azure SQL Managed Instance

A Managed Instance is an instance-scoped SQL Server that Microsoft runs (`EngineEdition` 8, kind `azuresqlmi`): most collections run on it as on a server someone runs. DBA Dash skips backups, mirroring, log restores and the availability group reads there; pgvigil follows Microsoft's T-SQL differences page item by item, below. `scripts/proof-mssql-mi.sh` runs these against a real General Purpose instance (Microsoft's free offer); Business Critical (its readable secondary, `AlwaysOn_health`) has not run.

### The login

Made in master by the instance's admin (a SQL login, or an Entra one), as on a server someone runs ([the login](sqlserver.md)): VIEW SERVER STATE (Microsoft: the DMVs need it there too), VIEW ANY DEFINITION, CONNECT ANY DATABASE (a built-in server permission there; without it a real instance's identity read was partial with "the login can enter none of the 1 online user database(s)", and its index, Query Store and statistics reads with "the login cannot enter any of the 1 user database(s)"), ALTER TRACE for the default trace (not settled there: below), a user in msdb with db_datareader. For `entra-identity` (above) the login is `CREATE LOGIN [<the identity's name>] FROM EXTERNAL PROVIDER;` in master, the name being the identity's display name (a system-assigned identity's is its VM's name). The instance must have a Microsoft Entra admin (a group here; a guest account of the tenant was refused as the admin); then its SQL admin (sysadmin) may make the login too. A real instance with no Entra admin refused it with Msg 33134 "Principal '<name>' could not be resolved", twice, with the Directory Readers role already given to the instance's own identity (a tenant role, given in Entra; not run without it). A login with no user in a database and without CONNECT ANY DATABASE is refused there with 4060 "Cannot open database ... requested by the login".

### What runs

The collections run as on a server someone runs, with these differences:

| collection | on a Managed Instance | why (Microsoft's T-SQL differences page, unless named) |
| --- | --- | --- |
| `mssql_mirroring` | skipped | "Database mirroring isn't supported." |
| `mssql_fci` | skipped | a managed service runs its own failover: there is no failover cluster instance to read |
| `mssql_logshipping` | skipped | "Differential, log, and file snapshot backups aren't supported": a user takes `COPY_ONLY` full backups to a URL only, so there is no log of the user's own to ship |
| `mssql_checks`, its alerts area | the operators only | SQL Server Agent: "Alerts aren't yet supported." and "Pager isn't supported.", while email notification is: 'no operator' is judged; the alert findings (severities 19 to 25, corruption errors, disabled alerts) and the fail-safe operator (it serves alert paging) are not. The Summary's alerts cell then counts 0 alerts |
| `mssql_backups` | runs; master, model and msdb not judged (each with its reason: master is not backed up, model and msdb are kept by the service) | ['Automated backups'](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/automated-backups-overview): "The system databases are automatically backed up (excluding the physical master database), but these backups aren't currently logged in msdb." User databases are judged: ['Monitor backup activity'](https://learn.microsoft.com/en-us/azure/azure-sql/managed-instance/backup-activity-monitor) says the instance "stores backup information in the msdb database". The collection stays on (DBA Dash skips it) because it also lists the databases for new and dropped databases |
| `mssql_errorlog` | runs | `sp_readerrorlog` reads the unfiltered log there (Microsoft's SQLCAT post on `sp_readmierrorlog`, an open-source procedure that filters it: not used) |
| Extended Events | ring buffers | `pgvigil mssql-xe -print -form azuresqlmi`: "The `event_file` target isn't supported" (a file there must be in Azure Blob storage); `system_health` (`mssql_syshealth`, and the deadlock reports `mssql_xe` reads without pgvigil's own session) is read from its ring buffer, which it keeps beside its file there: a real instance refused its file `system_health.xel` by name (Msg 40538, "A valid URL beginning with 'https://' is required"). That ring comes back cut off: a real instance's held 1,267 events in about 4 MB, and its output (truncated) the oldest 703, the newest of them 16 minutes old, so the component results and `system_health`'s deadlock reports arrive that late there (read once, not over hours); the reader's state says the output was cut off. pgvigil's own deadlock session keeps a ring of its own |
| the Windows power plan, the memory limit | not read, not advised | Microsoft runs the host and sets the memory limit |

A real General Purpose instance (Microsoft's free offer) answered `scripts/proof-mssql-mi.sh`: every collection ok or skipped as the login above (`mssql_plancache` partial only by its own cap, as anywhere), msdb rows for its user database's automatic full and log backups (none for master, model and msdb), the four `-form azuresqlmi` sessions with no `event_file` target, and `entra-identity` from a VM's system-assigned identity. Not settled: the default trace (that login held no ALTER TRACE, so its reader's "ok" was the "no right" state, not a read), whether every automatic differential and log backup keeps its row (and whether the weekly full against the 168-hour default warns before each new full), and what the availability group reads show for Business Critical's own replicas and a Managed Instance link.

## Google Cloud SQL for SQL Server

Google's own SQL Server instances: SQL Server on Linux that Google runs, the customer's highest login being the `sqlserver` user (no sysadmin). DBA Dash has no Cloud SQL detection; this is pgvigil's own reading of Google's pages, run against a real instance (Express) and a simulation (below).

### How it is told apart

Google's own mark is the server role `CustomerDbRootRole` (the `sqlserver` user is its member, and grants it makes name it as their grantor). Detection asks for it, on a Linux host, only on a server that is neither Azure nor RDS, in a statement of its own (a role of that name carried to a Windows server is not Cloud SQL). msdb's `gcloudsql_bulk_insert` is no mark: Google creates it only once the bulk-insert flag is on. A login sees the role only with VIEW ANY DEFINITION; a login without it reads the instance as a server someone runs, unless the configuration's `platform: cloudsql` (or Admin > Instances' platform Google Cloud SQL) names it.

### The login

Made in T-SQL by the `sqlserver` user (a user made through gcloud or the console gets the `sqlserver` user's own rights, more than a monitor needs):

```sql
-- in master, as the sqlserver user: the grant option is CustomerDbRootRole's, so each grant names the role
CREATE LOGIN [pgvigil_monitor] WITH PASSWORD = '<a long random password>';
GRANT VIEW SERVER STATE TO [pgvigil_monitor] AS [CustomerDbRootRole];
GRANT VIEW ANY DEFINITION TO [pgvigil_monitor] AS [CustomerDbRootRole];
```

On a real instance (SQL Server 2022 Express): the `sqlserver` login itself holds only CONNECT SQL; its role `CustomerDbRootRole` holds VIEW SERVER STATE and VIEW ANY DEFINITION with the grant option, so a plain `GRANT` is refused (Msg 4613, "Grantor does not have GRANT permission") and the grant `AS [CustomerDbRootRole]` is taken. It cannot add a login to the fixed roles `##MS_ServerStateReader##` or `##MS_DefinitionReader##`, and cannot grant CONNECT ANY DATABASE. It cannot make a user in msdb for another login (Msg 15247), so the monitoring login has no way in there and SQL Server Agent's jobs and log shipping are not read (Google: users created through SQL Server directly cannot use SQL Server Agent). Google offers no IAM sign-in for SQL Server: the password-free way is Windows authentication through Managed Microsoft AD (above).

### What runs

The collections run as on a server someone runs, with these differences:

- SQL Server Agent's jobs and log shipping: skipped, naming msdb (msdb is protected from logins made in T-SQL; a user made through the console or gcloud carries `CustomerDbRootRole`'s rights, more than a monitor needs).
- The Windows power plan: not read (Google runs the host; SQL Server on Linux there).
- Extended Events: `pgvigil mssql-xe -print -form cloudsql`, run by the `sqlserver` user, makes and starts the four sessions, the slow capture's event file under `/var/opt/mssql/xevents/`, the folder Google names. Google's trigger on CREATE EVENT SESSION takes one `max_memory=` per command, read as the session's `MAX_MEMORY`, of 4 to 8 MB: in this form the ring buffers set no size of their own and each session's MAX_MEMORY is its capture's size kept within 4-8 MB. Cloud SQL has no `sp_configure` and its database flags offer no blocked process threshold, so the blocked-process session stays empty there; deadlocks, slow queries and attention still capture.
- Trace flags: the Checks page advises the trace flags a server someone runs should have on (3226, 7745) only on such a server; on Cloud SQL a trace flag is Google's database flag, not advised.

Read on a real instance by the login above: the error log, the default trace, the Extended Events sessions (made by the `sqlserver` user), and every other collection. Google's own database `gcloud_cloudsqladmin` (owner CloudDbSqlRoot, the only user database of a new instance) is left out of the user databases, as Amazon RDS's `rdsadmin` is: no monitor login can be given a way in (the `sqlserver` user cannot grant CONNECT ANY DATABASE), and the per-database reads would otherwise end partial on every Cloud SQL server. Not settled: the blocked process threshold (no flag found), Extended Events sessions made by a login other than the `sqlserver` user, Database Mail, Resource Governor and server triggers (Google lists them as unavailable), and how a high-availability instance or a read replica shows itself in T-SQL.

### Proof

`scripts/proof-cloudsql-sim.sh` is a SIMULATION: a SQL Server 2022 container on Linux wearing Cloud SQL's role. A login with exactly the grants above is stored as `cloudsqlsqlserver`; without VIEW ANY DEFINITION the role is invisible and the instance is a server, until `platform: cloudsql` names it; every collection ends as it ends on the same server and login with `platform: onprem`. Against a real Cloud SQL instance (SQL Server 2022 Express, one vCPU): the login above with its grants AS the role, the platform stored as `cloudsqlsqlserver`, every collection's outcome (all ok but the jobs and log shipping, skipped for msdb, and the four per-database reads, partial on Google's `gcloud_cloudsqladmin` before it was left out of the user databases; not run against an instance since), and the four Extended Events sessions made, started and read.

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
-- optional, for the instance's high availability mode and last failover on its Properties page:
GRANT EXECUTE ON dbo.rds_get_high_availability_option TO [pgvigil_monitor];
GRANT EXECUTE ON dbo.rds_failover_time TO [pgvigil_monitor];
-- in each database whose procedures, indexes, statistics and Query Store pgvigil is to name:
USE [<database>];
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];
ALTER ROLE db_datareader ADD MEMBER [pgvigil_monitor];   -- the statistics' properties (sys.dm_db_stats_properties asks SELECT)
```

A database made later needs its own user before pgvigil reads it.

The instance's security group admits the collector's address on 1433 (a /32, never a range).

### What runs

Detected as `rdssqlserver` by the database `rdsadmin`. Every collection runs as on a server someone runs, except where the service or the login it allows says otherwise:

| collection | on Amazon RDS (Express and Standard) | why |
| --- | --- | --- |
| `mssql_instance`, `mssql_services`, `mssql_requests`, `mssql_waits` | runs | as on a server (VIEW SERVER STATE) |
| `mssql_cpu`, `mssql_memory`, `mssql_fileio`, `mssql_tempdb`, `mssql_properties`, `mssql_storage`, `mssql_versionstore` | runs | as on a server |
| `mssql_waiting_tasks`, `mssql_reports`, `mssql_activity` | runs | as on a server (run on Standard; `mssql_activity`'s rows are not compared by the proof) |
| `mssql_mirroring`, `mssql_replication` | runs | nothing to read on the instances proven (Express, and Standard in a single AZ: no mirroring, no distributor): stored as none |
| `mssql_fci` | skipped | a managed service runs its own failover: there is no failover cluster instance to read |
| `mssql_procstats` | runs | every cached procedure of every database (one server-wide DMV); a database the login has no user in keeps its procedures' ids without their names, and the run says partial |
| `mssql_indexlocks`, `mssql_querystore` | runs | in the databases the login has a user in; the others are not read (the master user cannot enter `model`, so no user can be made there) |
| `mssql_backups` | runs | `msdb.dbo.backupset` is readable without a grant there. RDS's automated backups and snapshots are the service's own storage snapshots and are not counted: what msdb holds of the instance's own is the full backups RDS writes to the NUL device while it builds the instance (msdb, model, rdsadmin; never a last full backup, as on any server) and native backups (`msdb.dbo.rds_backup_database`), which count as on a server. The last-backup check speaks of native backups alone |
| `mssql_xe` | runs | reads pgvigil's sessions where they exist. On Standard and Enterprise they come from `pgvigil mssql-xe -print -form rds` (Extended Events, below). RDS refuses event sessions on Express and Web (its trigger `rds_extended_events_trigger`: "supports extended events only for the Enterprise and Standard editions"): there every capture reads `not installed` |
| `mssql_ag` | skipped on Express, runs on Standard | Express: Always On is not enabled. Standard: RDS enables Always On even in a single AZ (`SERVERPROPERTY('IsHadrEnabled')` 1) and makes no availability group there, so none is stored |
| `mssql_logshipping` | skipped | RDS has no log shipping (and its master user cannot grant msdb's log shipping tables) |
| `mssql_jobs` | skipped | the read needs eleven msdb tables and the master user can grant three (`sysjobs`, `sysjobhistory`, `sysjobactivity`; the other eight are invisible to it: "Cannot find the object", Msg 15151); the skip names the first table it cannot read (`sysjobsteps`). Express has no Agent at all; on Standard the Agent runs and its jobs are still not read |
| `mssql_pool` | skipped | elastic pools are Azure SQL Database's |
| `mssql_audit`, `mssql_checks`, `mssql_traceflags` | runs | as on a server: `sys.server_audits` and their specifications (RDS keeps two audits of its own, read like any other), `sys.configurations`, `DBCC TRACESTATUS(-1)` (RDS sets trace flags of its own, listed like any other) |
| `mssql_checks`, its alerts area | not read, no alert finding | AWS's [SQL Server Agent page](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.SQLServer.CommonDBATasks.Agent.html): "SQL Server Agent alerts and operators aren't supported." On Express there is no Agent at all; on Web, Standard and Enterprise the 'no alerts for severity 19 to 25' and 'no operator' findings would ask for what the service does not offer |
| `mssql_errorlog` | runs | the current log only, through `rdsadmin.dbo.rds_read_error_log` (the archives are not readable that way); the reader's state says so |
| `mssql_defaulttrace` | runs | needs ALTER TRACE (in the login above): the default trace's growths, shrinks, DBCC commands and object changes |
| `mssql_syshealth` | runs | reads the `system_health` session's event files (on Standard in `D:\rdsdbdata\Log`); an Express db.t3.micro writes no `sp_server_diagnostics_component_result` there, so nothing is stored (and nothing is missing); a Standard db.m7i.large writes them, and the four components are stored |
| `mssql_identity`, `mssql_indexes`, `mssql_stats` | runs | in the user databases the login has a user in; `rdsadmin`, the service's own database, is left out (its tables are not the DBA's and the master user cannot give a login SELECT there) |
| `mssql_plancache`, `mssql_plancache_health` | runs | as on a server. On a db.t3.micro SQL Server's memory target is about 115 MB and a plan stays cached only while it is used (recompiled every few seconds under load), so both lists hold what runs at the moment of the read |

Two of RDS's own procedures are read, by `mssql_properties` into the instance's Properties page (Server): **High availability (Amazon RDS)** from `msdb.dbo.rds_get_high_availability_option` (AWS's values: `Single-AZ`, `Multi-AZ (AlwaysOn)`, `Multi-AZ (Mirroring)`, `Multi-AZ (Block level replication)`; a change of mode is logged), and **Last failover (Amazon RDS)** from `msdb.dbo.rds_failover_time` (the most recent failover the error logs still hold, as the procedure returns it: AWS names no time zone; `none` when they hold none), asked only when the mode is not `Single-AZ`: on a single-AZ instance the procedure refuses ("This procedure can only be used on Multi-AZ RDS Instance."), and the row's value is `none` with that reason. Each needs the optional EXECUTE above: without it the mode's row names both lines (`USE msdb; GRANT EXECUTE ON dbo.<procedure> TO [<the login's user in msdb>];`) and the run stays ok; a refusal by the failover procedure itself is said on its row and the run stays ok; any other error makes the run partial. Read on a real single-AZ Standard instance: the master user's answer `Single-AZ`, the refusal of the failover time, the monitoring login refused without the grant (Msg 229) and the master user's right to grant it. The collector's read of these answers is tested in Go on those answers and against stubs of the two procedures on a SQL Server container (`internal/mssql/rds_ha_test.go`, `TestRDSHALive`, which also runs the printed GRANT lines), not against an RDS instance. Not proven: a Multi-AZ instance's answers (they follow AWS's page) and either procedure's answer to a granted login other than the master user. RDS's other procedures (`rds_*` in msdb) are not read in this release.

### Extended Events

`pgvigil mssql-xe -print -form rds`, run in `master` by the master user, makes and starts the four sessions on Standard and Enterprise (AWS: Extended Events on those two editions, SQL Server 2016 and later). It is the server form with the slow capture's event file in `D:\rdsdbdata\log\`: RDS's trigger refuses an event file anywhere else ("Extended events event_file target is allowed only to D:\rdsdbdata\Log"), the server form's bare file name too. AWS's limits, which the script's default sizes keep within: a ring buffer of at most 4 MB, a session's memory of 4 to 8 MB (`xe_session_max_memory`), an event file of 100 MB unless raised (`xe_file_target_size`, up to 1 GB, through `rdsadmin.dbo.rds_set_configuration`).

The blocked-process capture needs the 'blocked process threshold (s)' above 0, and on RDS that is a DB parameter group's setting (dynamic, 0 to 86400; AWS's default group `default.sqlserver-se-15.0` holds 0). A default group cannot be changed: the value goes in a group of the instance's own, where a dynamic change applies at once, and an instance moved to a new group takes it at its next reboot. The script prints the step and does not take it.

On a Multi-AZ instance a session made on the primary does not reach the standby (AWS); after a failover the script is run again on the new primary, and until then the captures read `not installed`.

On a real Standard instance the four sessions were made and started, the slow session's file was in `D:\rdsdbdata\log`, and `mssql_xe` read its events. The threshold was left at 0 there, so the blocked-process capture read nothing; it is not proven on RDS, and `-form rds` is not proven on Enterprise, on another SQL Server version, past AWS's limits or across a Multi-AZ failover.

## Proof

Two proofs, each against a real instance made for it and removed after it:

- `scripts/proof-mssql-azuresqldb.sh` against a General Purpose serverless database (the subscription's free offer) made by `scripts/lab/azure-sqldb.sh`.
- `scripts/proof-mssql-rds.sh` against an RDS for SQL Server instance made by `scripts/lab/aws-rds-mssql.sh`: Express (db.t3.micro, the default) and Standard (db.m7i.large, `PGVIGIL_LAB_RDS_EDITION=se`), both SQL Server 2019 in a single AZ.

Each proof checks the collector's rights, the platform and edition stored, every SQL Server collection (stored rows equal to the setup login's read of the same view, or a skip whose note says why, never counted as collected or failed), the instance's pages, and that the monitored side is unchanged by the collector. The lab scripts make each resource with a tag, admit one address, keep the passwords only in a mode-600 file under `.lab/`, and take everything down with the listing read back.

### Results

Run from a machine outside each service's cloud (on 2026-11-11; RDS Standard on 2026-11-14), each service's door admitting that machine alone:

| service | instance | result |
| --- | --- | --- |
| Azure SQL Database | General Purpose serverless Gen5, 1 vCore (the free offer), engine 12.0.2000.8 | PASS: the contained user's rights; platform `azuresqldb`, engine edition 5; 4 collections stored equal to the setup login's read of the same views, 28 skipped by an Azure SQL Database rule with nothing stored; the Summary and 33 tabs, each skipped tab saying why; the database unchanged by the collector |
| Amazon RDS for SQL Server | Express Edition 15.0.4500.2 (SQL Server 2019), db.t3.micro | PASS: the RDS form of the login; platform `rdssqlserver`, engine edition 4; 29 collections stored equal to the master user's read of the same views (counters between a read before and a read after the run; `mssql_syshealth` 0 = 0, below), 3 skipped by an RDS rule (`mssql_ag`, `mssql_logshipping`, `mssql_jobs`); the Summary (no cell stale or never read) and 33 tabs; the server unchanged by the collector |
| Amazon RDS for SQL Server | Standard Edition 15.0.4500.2 (SQL Server 2019), db.m7i.large, single AZ | PASS: the RDS form of the login; platform `rdssqlserver`, engine edition 2; 33 collections run, 32 of them stored equal to the master user's read of the same views (`mssql_activity`'s rows not compared), 3 skipped (`mssql_logshipping`, `mssql_jobs`: RDS rules; `mssql_pool`: Azure SQL Database's); `mssql_ag` with Always On enabled and no group; `mssql_xe` reading the four sessions of `-form rds`, the slow capture's file among them; `mssql_syshealth` the four components equal; the Summary and 33 tabs; the server unchanged by the collector |

What the Express instance could not show, and the proof says so in its result: an Extended Events session of pgvigil's running (RDS refuses them on Express; every capture reads `not installed`, as the master user reads it), and a system_health component row's content (the instance writes none); the Standard instance showed both. On a db.t3.micro a plan stays cached only while it runs: the procedure, statement and plan-count reads were compared while a session ran the proof's own statements, a statement's plan by its handle and offsets where the cache compiled it again between the reads, and its count against the read that lists the same plan; where no read listed it, the proof says so.

These results are for this release's code, which includes the collector and page changes the proofs found (Azure SQL Database's VIEW DATABASE STATE check, its event session form, the skipped tabs' lines, the RDS skip notes, and `rdsadmin` left out of the per-database passes).

## Not proven, not in this release

- Geo-replication and failover groups (task 390a): NOT PROVEN until the lab's proof (`scripts/proof-mssql-georepl.sh`) runs; and not in it: Managed Instance's geo-replication, a SUSPENDED link (no way to make one), a group with several secondaries (Microsoft's preview), the usgov and china clouds (no lab), the `azure:` block on a discovered (page) instance (task B24p).
- Azure SQL Database: the Basic, S0 and S1 tiers as single databases (their rights differ, above; a Basic elastic pool is proven live: the elastic pools section), a vCore elastic pool, Microsoft Entra sign-in with a service principal (`entra`) or a user-assigned identity against a live server (built: above; a system-assigned identity is proven live on a pooled database), a geo-replica.
- Amazon RDS: Web and Enterprise (`-form rds` on Enterprise too); SQL Server versions other than 2019 (both proofs ran 15.0.4500.2); Multi-AZ (Always On or mirroring, the high availability mode's Multi-AZ values and `rds_failover_time`'s answer on the Properties page, the event sessions after a failover); the two Properties rows read live (their Go cases rest on R1's recorded answers); SQL Server Agent's jobs (skipped: above); the blocked-process capture with the threshold set in a parameter group; Windows authentication through AWS Managed Microsoft AD, RDS Custom.
- Not in this release: AlloyDB is not proven against a real instance. Google Cloud SQL for SQL Server is (Express, the login above, above); Azure SQL Managed Instance is on General Purpose (above), not on Business Critical.
