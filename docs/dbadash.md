# Imported SQL Server servers (the DBA Dash door)

A site that runs [DBA Dash](https://github.com/trimble-oss/dba-dash) for its SQL Server estate can show DBA Dash's instances beside its PostgreSQL fleet: pgvigil reads the DBA Dash repository (a SQL Server database) with a read-only login and shows the statuses of DBA Dash's own Summary screen, in DBA Dash's words, and DBA Dash's own screens for one instance (Performance Summary, Running Queries, Backups, Agent Jobs, Drives, DB Space, Configuration, SQL Agent Alerts) drawn from DBA Dash's own stored procedures. Every status and figure on these pages was computed by DBA Dash, and DBA Dash's thresholds and acknowledgements apply. Kill a session and start or stop an Agent job are offered through pgvigil's own SQL Server actions door, and a DBA Dash repository's history can be imported into pgvigil's store (the way off DBA Dash, below).

In pgvigil's own pages these are the **imported servers**: the root tab Imported servers, a tree folder `Imported: <name>` per repository, and each instance with the same SQL Server tab set as a server pgvigil collects itself (below). DBA Dash is named once in the UI, as the source, on the Imported servers page's settings line, and credited on the About page and in THIRD-PARTY-NOTICES.md. The internal names stay: the package `internal/dbadash`, the configuration key `dbadash:`, the route `/api/dbadash`, the `pgvigil import dbadash` command.

The door is off until the configuration names a repository.

## Configuration

```yaml
dbadash:
  - name: corp                 # the tree folder is "Imported: corp"
    dsn: env:DBADASH_CORP_DSN  # or file:/etc/pgvigil/dbadash-corp.dsn
  - name: lab
    dsn: file:/etc/pgvigil/dbadash-lab.dsn
    interval: 10m              # default 5m, at least 1m
```

- `name` is required, unique (case-insensitive), at most 100 characters, without `/`.
- `dsn` is a [go-mssqldb](https://github.com/microsoft/go-mssqldb) connection string: the URL form `sqlserver://login:password@host:1433?database=DBADashDB&encrypt=true` or the ADO form `server=host;database=DBADashDB;user id=login;password=...`. A string that holds a password (a `user:password@` URL, or a `password` / `pwd` key in any spelling) must come through `env:NAME` or `file:/path`, never written inline in the file. Inline is fine for a string without a password. Windows authentication (`integrated security=sspi`, pgvigil on Windows) is not proven: `scripts/proof-dbadash.sh` runs a SQL login only. Microsoft Entra ID (`fedauth=ActiveDirectoryManagedIdentity`, or `ActiveDirectoryServicePrincipal` with the application id and secret) and Kerberos on Linux (`authenticator=krb5`) open as for a monitored SQL Server ([SQL Server in the cloud](sqlserver-cloud.md#signing-in-without-a-stored-password)); neither is proven against a DBA Dash repository.
- `interval` is how often the repository is read. DBA Dash refreshes its own Summary cache on its own schedule, so a shorter interval than DBA Dash's refresh adds nothing.

Several repositories are allowed; each one is read on its own, so one that does not answer never delays another.

## The login: read-only

On the DBA Dash repository database, a login that may read and run DBA Dash's read procedures, and nothing else:

```sql
CREATE LOGIN pgvigil_dbadash WITH PASSWORD = '<a strong password>';
USE DBADashDB;
CREATE USER pgvigil_dbadash FOR LOGIN pgvigil_dbadash;
GRANT SELECT ON SCHEMA::dbo TO pgvigil_dbadash;          -- the Summary read, the import, and the procedures' dynamic SQL
GRANT EXECUTE ON TYPE::dbo.IDs TO pgvigil_dbadash;       -- the instance list the report procedures take
GRANT EXECUTE ON dbo.PerformanceSummary_Get   TO pgvigil_dbadash;
GRANT EXECUTE ON dbo.RunningQueriesSummary_Get TO pgvigil_dbadash;
GRANT EXECUTE ON dbo.RunningQueries_Get        TO pgvigil_dbadash;
GRANT EXECUTE ON dbo.BackupReport_Get          TO pgvigil_dbadash;
GRANT EXECUTE ON dbo.AgentJobsReport_Get       TO pgvigil_dbadash;
GRANT EXECUTE ON dbo.DrivesReport_Get          TO pgvigil_dbadash;
GRANT EXECUTE ON dbo.DBFilesReport_Get         TO pgvigil_dbadash;
GRANT EXECUTE ON dbo.Configuration_Get         TO pgvigil_dbadash;
GRANT EXECUTE ON dbo.Alerts_Get                TO pgvigil_dbadash;
```

SELECT on the dbo schema is needed beside EXECUTE: four of these procedures (AgentJobsReport_Get, DrivesReport_Get, DBFilesReport_Get, RunningQueries_Get) build their statement as dynamic SQL, which SQL Server runs with the caller's own rights. SELECT writes nothing. The login needs no other EXECUTE and must not have DBA Dash's `AppReadOnly` role or `db_owner`: `AppReadOnly` may run every `*_Get` procedure, and `dbo.Summary_Get` rewrites the Summary cache (below). `scripts/proof-dbadash-door.sh` checks that this login is refused an INSERT, `dbo.Summary_Upd` and `dbo.Summary_Get`.

A door that only shows the Summary (no screens, no import) works with less: SELECT on `dbo.Instances`, `dbo.Summary`, `dbo.CollectionDates` and `dbo.DBVersionHistory` alone (proven by `scripts/proof-dbadash.sh`); the screens then answer with SQL Server's own permission error.

## What pgvigil reads

| DBA Dash table | Columns read | What for |
|---|---|---|
| `dbo.Instances` | `InstanceID`, `Instance`, `ConnectionID`, `Alias`, `ShowInSummary`, `ProductVersion`, `Edition`, `CollectionsPausedUntil`, `IsActive`, `EngineEdition` | the instance list: the active instances (`IsActive = 1`), the name DBA Dash shows (`ISNULL(Alias, ConnectionID)`, DBA Dash's `InstanceDisplayName`); Azure SQL databases (`EngineEdition = 5`) are left out |
| `dbo.Summary` | `InstanceID`, `RefreshDate`, `IsAzure`, the 26 status columns below, and the detail columns `DetectedCorruptionDateUtc`, `CollectionErrorCount`, `SnapshotAgeMin`, `SnapshotAgeMax`, `sqlserver_start_time_utc`, `sqlserver_uptime`, `host_uptime`, `MemoryDumpCount`, `LastMemoryDumpUTC`, `LastGoodCheckDBCriticalCount`, `LastGoodCheckDBWarningCount`, `LastGoodCheckDBHealthyCount`, `LastGoodCheckDBNACount`, `OldestLastGoodCheckDBTime`, `DaysSinceLastGoodCheckDB`, `LastAlert`, `LastCritical`, `TotalAlerts`, `IsAgentRunning`, `DBMailStatusDescription`, `MaxIdentityPctUsed`, `MinIdentityEstimatedDays`, `OfflineSince`, `LastFail`, `ServiceBrokerStatusDescription` | the statuses of DBA Dash's Summary screen, the rows with `IsAzure = 0` |
| `dbo.CollectionDates` | `InstanceID`, `SnapshotDate` | the last collection per instance (the newest `SnapshotDate`) |
| `dbo.DBVersionHistory` | `DeployDate`, `Version` | the repository's DBA Dash version |

The 26 statuses, in the column order of DBA Dash's Summary screen, with its column headers: `MemoryDumpStatus` (Memory Dump), `CorruptionStatus` (Corruption), `LastGoodCheckDBStatus` (Last Good Check DB), `AlertStatus` (SQL Agent Alerts), `FullBackupStatus` (Backup FULL), `DiffBackupStatus` (Backup DIFF), `LogBackupStatus` (Backup LOG), `DriveStatus` (Drive Space), `JobStatus` (Agent Jobs), `IsAgentRunningStatus` (Is Agent Running), `LogShippingStatus` (Log Shipping), `MirroringStatus` (Mirroring), `AGStatus` (Availability Groups), `LogFreeSpaceStatus` (Log Space), `FileFreeSpaceStatus` (File Space), `PctMaxSizeStatus` (% Max Size), `ElasticPoolStorageStatus` (Elastic Pool Storage), `QueryStoreStatus` (QS), `CustomCheckStatus` (Custom Checks), `CollectionErrorStatus` (DBA Dash Errors (24hrs)), `SnapshotAgeStatus` (Snapshot Age), `DBMailStatus` (DB Mail), `IdentityStatus` (Identity Columns), `DatabaseStateStatus` (Database State), `ServiceBrokerStatus` (Service Broker), `UptimeStatus` (Instance Uptime).

A status is DBA Dash's code and its word: 1 Critical, 2 Warning, 3 N/A, 4 OK, 5 Acknowledged, 6 Warning (low), 7 Information, 8 Disabled. pgvigil colours Critical red, Warning and Warning (low) amber, OK green, and the rest muted; the instance's dot is its worst status.

A column an older or newer DBA Dash does not have is simply not read (pgvigil lists the columns the login can see first); the reader was built against DBA Dash 4.24.1.

### Why the table, not `dbo.Summary_Get`

DBA Dash's Summary screen calls `dbo.Summary_Get`. When its cache is older than the `SummaryCacheDurationSec` setting, that procedure runs `dbo.Summary_Upd` first, which rewrites `dbo.Summary`: a write on the DBA Dash repository. pgvigil reads the same cache (`dbo.Summary`, the rows `Summary_Get` returns for SQL Server instances) and never refreshes it. The statuses are therefore as fresh as DBA Dash's last refresh; the page shows that time ("Summary refreshed"). DBA Dash refreshes the cache when someone opens its Summary screen, and on a schedule when the DBA Dash service's `SummaryRefreshCron` is set: set it (for example every 5 minutes) when pgvigil should follow DBA Dash without a GUI open.

## Where it shows

- **The tree**: below the instance folders, one folder per repository, `Imported: <name> (n)`, a node per SQL Server instance with its worst Summary status as the dot. A node opens the instance's pgvigil instance when pgvigil holds one (imported, or collected by pgvigil under the same `@@SERVERNAME`), else the instance's own page. A repository that did not answer, or refused the login, shows `not read` and the reason under its folder; the instances of its last good read stay listed.
- **The Imported servers page** (`#/dbadash`, the folder's link): the settings line (the source, its read cadence), the repositories (last read, the reason when not read, the source version and its Summary refresh time, the critical and warning counts) and every instance as a row of Summary cells, a cell per status in the source's column order, with whether pgvigil holds it (collected, imported, not imported).
- **An instance**: the SQL Server tab set (below).

DBA Dash's GUI is a desktop application with no URL, so these pages name the instance and the repository and offer no link into DBA Dash.

## An imported server's tabs

An instance read through a repository opens with the same tabs as a SQL Server instance pgvigil collects itself (the main tabs Summary, Performance, Running queries, Slow queries, Waits, Deadlocks, Blocked reports, Findings, and the groups Logs, HA/DR, Performance, Storage, Jobs, Configuration: 33 tabs). Which instance is which:

- **Collected**: pgvigil collects a SQL Server whose `@@SERVERNAME` equals the instance's, or the pgvigil instance of the display name has a collection attempt of its own (an `instances:` entry or an Admin > Instances row was added for it; a failed first collection counts, so its error shows on pgvigil's own pages, but a failed connect does not: until pgvigil reaches the server it opens on the repository's screens). It is pgvigil's own instance, with its own pages, and the repository adds nothing to them (the actions of the repository's screens go through it, below).
- **Imported**: `pgvigil import dbadash` made a pgvigil SQL Server instance under the instance's display name, and pgvigil has never tried to collect it.
- Only repositories the configuration still names count: a repository removed from `dbadash:` leaves its imported servers as plain SQL Server instances with the history the import stored.
- When several instances of the configured repositories carry one display name (two repositories, or a server re-added in one), the page reads the one still listed with the newest collection, and says so. It opens at its pgvigil instance (`#/<tab>?i=<id>`); each tab is served as the table says.
- **Not imported**: neither. It opens at its own page (`#/dbadash?dr=<repository>&di=<InstanceID>&dp=<tab>`) with the same tabs; a tab the import would fill says so, with the command.

A limit of this release: an instance imported under another name (`-name <id>=<name>`) is not recognised as imported (the import records no source for a pgvigil instance), so it opens as a SQL Server instance with pgvigil's own pages over what the import stored, and the pages pgvigil's own collection fills are empty there. Import under the display name to get the table below.

Each tab is served from pgvigil's store where the import fills the tables its page reads, else from the repository's live screen, else it says in one line `not read for an imported server: <what would read it>`, never an empty grid:

| Tab | Imported server | Not imported |
|---|---|---|
| Summary | the repository's Summary statuses, their changes in the range (the stored read above) | the same |
| Performance | screen `dbo.PerformanceSummary_Get` | the same |
| Running queries | screen `dbo.RunningQueriesSummary_Get`; a snapshot (and "the latest snapshot's sessions") `dbo.RunningQueries_Get`, with Kill through a collected instance (below) | the same |
| Backups | screen `dbo.BackupReport_Get` | the same |
| Jobs | screen `dbo.AgentJobsReport_Get` with Start / Stop through a collected instance, then the SQL Agent alerts `dbo.Alerts_Get` | the same |
| Database files | screen `dbo.DBFilesReport_Get` | the same |
| Configuration | screen `dbo.Configuration_Get` | the same |
| Properties | the instance's facts as the repository records them (the stored read) | the same |
| CPU | pgvigil's CPU page over the CPU minutes the import copied (`mssql_cpu_sample`) | not read: the import copies them |
| Storage | the newest size of each database the import copied (pgvigil's store, `mssql_database_size`), then screen `dbo.DrivesReport_Get` (pgvigil's own Storage page lists the databases of its own file read, which an imported server has not; the import's volume samples wait for the server to be collected) | screen `dbo.DrivesReport_Get` |
| Jobs timeline | pgvigil's Jobs timeline over the job outcomes the import copied (`mssql_job_runs`) | not read: the import copies them |
| Slow queries, Waits, Deadlocks, Blocked reports, Findings, Availability, Row versions, Actions log, Memory, File IO, TempDB, Query Store, Metrics, Procedures, Index locks, Audit, Plan cache, Indexes, Checks, Error log, Default trace, System health | not read: the line names pgvigil's own read of the server that fills it | the same |

On the CPU and Jobs timeline tabs, the parts of pgvigil's page that its own collection fills (schedulers, running jobs) stay empty for an imported server, and the page says so in its first line. To get every tab, add the server to `instances:` with `engine: sqlserver`: it becomes a collected instance, and the import's history stays under it when the names match (the import's `-to` rule below).

## DBA Dash's own screens

The screens of the table above. Each is ONE call of the DBA Dash procedure that DBA Dash's GUI calls for that screen, made when the page is opened, through the repository's read login, with the parameters the GUI passes for one instance and every status of its status filter ticked; every result set the procedure returns is drawn as a grid, its columns and rows as the procedure returned them, DBA Dash's status columns in its words and colours. pgvigil stores nothing of a screen: the repository is the store, as it is for DBA Dash's GUI.

| Screen | DBA Dash procedure | Takes |
|---|---|---|
| Summary | (the `dbo.Summary` table, above) | |
| Performance Summary | `dbo.PerformanceSummary_Get` | the time range |
| Running Queries | `dbo.RunningQueriesSummary_Get` | the time range; a snapshot opens its sessions |
| Running Queries (snapshot) | `dbo.RunningQueries_Get` | one snapshot time (none = the latest) |
| Backups | `dbo.BackupReport_Get` | |
| Agent Jobs | `dbo.AgentJobsReport_Get` | |
| Drives | `dbo.DrivesReport_Get` | |
| DB Space | `dbo.DBFilesReport_Get` | |
| Configuration | `dbo.Configuration_Get` | |
| SQL Agent Alerts | `dbo.Alerts_Get` | |

Every one is a `dbo.*_Get` procedure that writes nothing (each was read in DBA Dash 4.24.1's source: no write to a permanent table, no `_Upd` procedure called). The procedures are the contract, and they change between DBA Dash releases: the screens are proven on DBA Dash 4.24.1 (`scripts/proof-dbadash-door.sh`: each screen's grids equal the same procedure's output read by a second, independent SQL Server client). A repository of another version is still read and every screen says "not proven on source version <version>"; a procedure whose parameters changed answers with SQL Server's own message on the page.

The API: `GET /api/dbadash?repo=<name>&id=<InstanceID>&page=<key>[&from=..&to=..][&snapshot=..]`, the keys `performance`, `running`, `sessions`, `backups`, `jobs`, `drives`, `dbfiles`, `configuration`, `alerts` (`page=list` names them). A repository that does not answer is a 502 with the reason.

## Actions: kill a session, start or stop a job

The Running Queries snapshot carries Kill on each session and Agent Jobs carries Start and Stop on each job. They go through pgvigil's own SQL Server actions door ([sqlserver-actions.md](sqlserver-actions.md)): the preview read through the instance's read login, the typed confirmation, the statement through a separate actions login (ALTER ANY CONNECTION for a kill, SQLAgentOperatorRole in msdb for the jobs; never sysadmin), and every attempt in `pgvigil.actions_log`. DBA Dash's repository login never acts, and pgvigil sends nothing to the DBA Dash repository.

So an instance's buttons are on only when pgvigil itself monitors that SQL Server: an active `instances:` entry with `engine: sqlserver`, its `actions_dsn` and its `actions:` allow list. pgvigil matches the DBA Dash instance to it by two names, both ignoring case: DBA Dash's `Instance` (the server's `@@SERVERNAME`) equal to the server name pgvigil collected, and DBA Dash's `MachineName` equal to pgvigil's machine name. The second guards a host renamed without `sp_dropserver` / `sp_addserver`, which keeps its old `@@SERVERNAME` while a new server may carry that name. Kill is offered on the latest Running Queries snapshot only: a session id of a past snapshot may belong to another session by now. Without such an instance, with names that differ, or without its `actions_dsn` or the action on its list, the button is off and says why; the actions are off by default. The preview step then shows the session or job as it is now, read through the instance's read login, before anything is sent.

```yaml
instances:
  - name: sql-prod-1
    engine: sqlserver
    dsn: env:SQLPROD1_DSN               # the read login (VIEW SERVER STATE; db_datareader in msdb)
    actions_dsn: env:SQLPROD1_ACTIONS   # the actions login
    actions: [kill, job_start, job_stop]
```

## The way off DBA Dash: importing its history

`pgvigil import dbadash` loads what a DBA Dash repository collected into pgvigil's own SQL Server tables, so a site moving to pgvigil keeps its history; the door stays, and both run side by side until the DBA switches the DBA Dash service off.

```
pgvigil import dbadash -config /etc/pgvigil/pgvigil.yaml -repo corp -dry-run
pgvigil import dbadash -config /etc/pgvigil/pgvigil.yaml -repo corp [-instance 3,7] [-from 2026-01-01T00:00:00Z] [-to ...] [-name 3=sql-prod-1]
```

- It reads the repository named by `-repo` in the `dbadash:` list, through its dsn (the read login above).
- It writes the configuration's pgvigil repository, whose dsn must be the repository owner's (the one `pgvigil migrate` uses): the rows go straight into the history tables, so the collector's and the reader's logins are refused ("may not write what the import writes").
- Each active SQL Server instance (or the `-instance` ids) becomes a pgvigil SQL Server instance under DBA Dash's display name, or the name `-name` gives (the name `instances:` will monitor it under, so pgvigil's own collection continues the same history). An instance pgvigil already stores under that name keeps its own description and tags; one stored as PostgreSQL is skipped and the reason printed. DBA Dash's own tags come along as `name:value` tags; its system tags (`{Edition}`, `{Version}` ...) do not: pgvigil reads those from the server itself.
- Idempotent and resumable: a row pgvigil already holds is skipped, and every batch of 2,000 rows commits on its own, so a run cut short is run again and goes on. `-dry-run` prints the counts and writes nothing. An `-instance` id that is not an active SQL Server instance of the repository is printed with that reason.
- History older than pgvigil's retention is imported, and the next `pgvigil purge` removes it again (by whole months): give `-from` the oldest time the retention keeps, or raise the retention first.
- It prints, per instance and table, the DBA Dash rows of the window, the rows inserted now and the rows pgvigil holds for the window after.
- Start pgvigil's own collection of an instance before its import, and give `-to` the time that collection began. The import skips a DBA Dash CPU minute within 30 seconds of a row pgvigil holds and an Agent job outcome pgvigil already read (the same history id, job and step), but pgvigil's collector, run after an import, would add its first read (up to about four hours of CPU records) beside the imported minutes; drive and database sizes of the same hours are separate readings and both are kept, and an Agent job outcome from before a daylight-saving change can be stored twice (its local time differs by the hour above).

| DBA Dash 4.24.1 | pgvigil | How |
|---|---|---|
| `dbo.Instances`, `dbo.Tags`, `dbo.InstanceIDsTags` | `instances` (engine sqlserver) | the display name (`ISNULL(Alias, ConnectionID)`), the product version, the platform (an Azure SQL Managed Instance as such), the tags: the name lower-cased with spaces as `_`, a tag pgvigil's tag rule still refuses (a value over 100 characters or with a comma) left out and named in the log |
| `dbo.CPU` | `mssql_cpu_sample` | a row per DBA Dash minute: SQL Server's share, other processes', idle; on Linux other and idle are left empty as the collector leaves them (the server writes no idle figure there) |
| `dbo.DriveSnapshot` + `dbo.Drives` | `mssql_volume_sample` | a row per drive and snapshot: capacity and free bytes; DBA Dash keeps a mount point in capitals, so a volume pgvigil already lists keeps pgvigil's spelling |
| `dbo.DBFileSnapshot` + `dbo.DBFiles` + `dbo.Databases` | `mssql_database_size` | a row per database and snapshot, by the collector's own rule: data (every file but the log) and log size, pages × 8 KB, used space only when DBA Dash read it for every file of that side, the file count |
| `dbo.JobHistory` + `dbo.Jobs` | `mssql_job_runs` | a row per job outcome and step: msdb's own history id, the job and step, status, duration, message; DBA Dash keeps the start in UTC (exact), and msdb's local run_date / run_time are rebuilt with the instance's current UTC offset, so a run from before a daylight-saving change shows its local time one hour off |

Not imported (no home in pgvigil's store, or nothing a later pgvigil read would not rebuild): wait statistics (`dbo.Waits`; pgvigil classifies waits as it collects them), running-query and slow-query captures, performance counters, IO statistics, backup history (pgvigil keeps each database's current backup state, which its first read fills), the configuration and patch history, DBA Dash's alerts, thresholds and acknowledgements, and Azure SQL Database rows.

The import is proven on a DBA Dash 4.24.1 repository built by DBA Dash's own service (`scripts/proof-dbadash-door.sh`: the dry run's counts equal the source tables', the run inserts and then holds exactly those, a second run inserts nothing). That repository was collected on Linux, where DBA Dash reads no drives: the drive mapping is proven with 0 rows there.

## Storage and retention

Migration 0052: `dbadash_repositories` (one row per configured repository: the last read, ok or `not read` with the reason), `dbadash_instances` and `dbadash_summary` (one current row per instance), and `dbadash_summary_history` (the change points: an instance's first read and every read whose statuses changed). The retention (not proven: no proof purges these tables): from the wave's join migration on, `pgvigil purge` deletes history older than the retention while keeping each instance's newest row (its current baseline), and deletes an instance DBA Dash no longer lists once it is older than the retention. A read that fails keeps the last rows as they were. A repository removed from the configuration leaves the tree at the next start of `pgvigil run`, the last one too.

The API: `GET /api/dbadash` (every repository and instance), `?repo=<name>` (one repository), `?repo=<name>&id=<DBA Dash InstanceID>&from=..&to=..` (one instance and the changes of the window). It reads 0052's functions only.

## What it does not do

- No SQL Server collection by the door: an instance DBA Dash does not monitor is not shown here (pgvigil's own SQL Server engine, [sqlserver.md](sqlserver.md), monitors an instance directly).
- No Azure SQL Database rows (DBA Dash groups those per Azure server in its Summary; pgvigil leaves them out).
- No write on the DBA Dash side, no DBA Dash procedure executed but the nine read procedures above, no acknowledgement set from pgvigil.
- Nothing outbound beyond the repositories the configuration names.

The driver is [microsoft/go-mssqldb](https://github.com/microsoft/go-mssqldb) (BSD-3-Clause). DBA Dash is MIT-licensed; pgvigil copies none of its code: the table, column, procedure and parameter names above are read from its published schema, and its procedures are called, never copied.
