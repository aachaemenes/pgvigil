# The DBADash door

pgvigil monitors PostgreSQL. A site that also runs [DBA Dash](https://github.com/trimble-oss/dba-dash) for its SQL Server estate can show DBA Dash's instances beside its PostgreSQL fleet: pgvigil reads the DBA Dash repository (a SQL Server database) with a read-only login and shows the statuses of DBA Dash's own Summary screen, in DBA Dash's words. pgvigil collects nothing from SQL Server itself. Every status on these pages was computed by DBA Dash, and DBA Dash's thresholds and acknowledgements apply.

The door is off until the configuration names a repository.

## Configuration

```yaml
dbadash:
  - name: corp                 # the tree folder is "DBADash: corp"
    dsn: env:DBADASH_CORP_DSN  # or file:/etc/pgvigil/dbadash-corp.dsn
  - name: lab
    dsn: "sqlserver://sql-lab01:1433?database=DBADashDB&fedauth=ActiveDirectoryDefault"
    interval: 10m              # default 5m, at least 1m
```

- `name` is required, unique (case-insensitive), at most 100 characters, without `/`.
- `dsn` is a [go-mssqldb](https://github.com/microsoft/go-mssqldb) connection string: the URL form `sqlserver://login:password@host:1433?database=DBADashDB&encrypt=true` or the ADO form `server=host;database=DBADashDB;user id=login;password=...`. A string that holds a password must come through `env:NAME` or `file:/path`, never written inline in the file. Inline is fine without a password (Microsoft Entra ID through `fedauth=`, or Windows authentication on a Windows host).
- `interval` is how often the repository is read. DBA Dash refreshes its own Summary cache on its own schedule, so a shorter interval than DBA Dash's refresh adds nothing.

Several repositories are allowed; each one is read on its own, so one that does not answer never delays another.

## The login: read-only

On the DBA Dash repository database, a login with SELECT on four tables and nothing else:

```sql
CREATE LOGIN pgvigil_dbadash WITH PASSWORD = '<a strong password>';
USE DBADashDB;
CREATE USER pgvigil_dbadash FOR LOGIN pgvigil_dbadash;
GRANT SELECT ON dbo.Instances        TO pgvigil_dbadash;
GRANT SELECT ON dbo.Summary          TO pgvigil_dbadash;
GRANT SELECT ON dbo.CollectionDates  TO pgvigil_dbadash;
GRANT SELECT ON dbo.DBVersionHistory TO pgvigil_dbadash;
```

These four grants are the whole right: SELECT on `dbo.Instances`, `dbo.Summary`, `dbo.CollectionDates` and `dbo.DBVersionHistory`, no EXECUTE on any procedure (proven against DBA Dash 4.24.1 by `scripts/proof-dbadash.sh`). `db_datareader` works too, and grants more than pgvigil reads. The login needs no EXECUTE: pgvigil runs no DBA Dash procedure (see below), and it writes nothing on the DBA Dash side. `scripts/proof-dbadash.sh` checks that this login is refused an INSERT and the procedure that refreshes the Summary.

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

DBA Dash's Summary screen calls `dbo.Summary_Get`. When its cache is older than the `SummaryCacheDurationSec` setting, that procedure runs `dbo.Summary_Upd` first, which rewrites `dbo.Summary`: a write on the DBA Dash repository. pgvigil reads the same cache (`dbo.Summary`, the rows `Summary_Get` returns for SQL Server instances) and never refreshes it. The statuses are therefore as fresh as DBA Dash's last refresh; the page shows that time ("DBADash Summary refreshed"). DBA Dash refreshes the cache when someone opens its Summary screen, and on a schedule when the DBA Dash service's `SummaryRefreshCron` is set: set it (for example every 5 minutes) when pgvigil should follow DBA Dash without a GUI open.

## Where it shows

- **The tree**: below the PostgreSQL folders, one folder per repository, `DBADash: <name> (n)`, a node per SQL Server instance with its worst status as the dot. A repository that did not answer, or refused the login, shows `not read` and the reason under its folder; the instances of its last good read stay listed.
- **The DBADash page** (`#/dbadash`, the folder's link): the repositories (last read, the reason when not read, DBA Dash's version and its Summary refresh time, the critical and warning counts) and every instance as a row of Summary cells, a cell per status in DBA Dash's column order.
- **An instance's page** (a node's link): the instance, its DBA Dash connection and the repository it came from, the SQL Server version DBA Dash recorded, the last collection by DBA Dash, when DBA Dash refreshed its Summary and when pgvigil read it, a Summary row of 26 cells (DBA Dash's header and word in each, the detail DBA Dash shows beside it as the cell's title: days since the last good CHECKDB, the error count, the snapshot age, the uptime, ...), the same as a list, and the status changes of the time range.

DBA Dash's GUI is a desktop application with no URL, so these pages name the instance and the repository and offer no link into DBA Dash.

## Storage and retention

Migration 0052: `dbadash_repositories` (one row per configured repository: the last read, ok or `not read` with the reason), `dbadash_instances` and `dbadash_summary` (one current row per instance), and `dbadash_summary_history` (every read, kept under the retention: `pgvigil purge` deletes it by age). A read that fails keeps the last rows as they were. A repository removed from the configuration leaves the tree at the next start.

The API: `GET /api/dbadash` (every repository and instance), `?repo=<name>` (one repository), `?repo=<name>&id=<DBA Dash InstanceID>&from=..&to=..` (one instance and the changes of the window). It reads 0052's functions only.

## What it does not do

- No SQL Server collection: an instance DBA Dash does not monitor is not shown.
- No Azure SQL Database rows (DBA Dash groups those per Azure server in its Summary; pgvigil leaves them out).
- No write on the DBA Dash side, no DBA Dash procedure executed, no acknowledgement set from pgvigil.
- Nothing outbound beyond the repositories the configuration names.

The driver is [microsoft/go-mssqldb](https://github.com/microsoft/go-mssqldb) (BSD-3-Clause). DBA Dash is MIT-licensed; pgvigil copies none of its code: the table and column names above are read from its published schema.
