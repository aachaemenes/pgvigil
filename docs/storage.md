# Storage

The Storage folder's first tabs are DBA Dash's, in its order. At the root and in a tag folder: Drives, DB Space, Files, TempDB and Table Size. Under a PostgreSQL instance: Drives, DB Space, Files, Temp (in TempDB's place), Tables (its table sizes) and Drive Performance. Under a SQL Server instance: Drives, DB Space, Files, TempDB and Drive Performance (the repository holds no table sizes of a SQL Server instance).

| Tab | What it shows | Read from |
| --- | --- | --- |
| Drives | one bar per drive with its free space and the threshold it is judged by | PostgreSQL: the host collection's volumes (`system_stats`, or CloudWatch on RDS and Aurora); SQL Server: `mssql_storage`'s volumes (`sys.dm_os_volume_stats`) |
| DB Space | the space the databases hold: per instance in a folder, per database under an instance, with its history | PostgreSQL: `pg_database_size` per database (`databases`); SQL Server: the data and log files (`mssql_storage`) |
| Files | SQL Server's data and log files; PostgreSQL's WAL directory and tablespaces, each on the drive that holds it (pg_wal, pg_default and pg_global, which have no location of their own, on the drive of the data directory) | `mssql_storage`; the `storage` collection and the host's volumes |
| TempDB | SQL Server's tempdb files per instance | `mssql_tempdb` ([SQL Server storage](sqlserver-storage.md)) |
| Temp | a PostgreSQL instance's temporary files over the page's range: by database, by statement, by hour | `pg_stat_database`'s temp_files and temp_bytes, `pg_stat_statements`' temp blocks, the log's temporary-file lines (the Memory page's reads) |
| Table Size | the largest tables with their growth (under a PostgreSQL instance: its Tables page) | the `tables` collection (PostgreSQL only: the repository holds no table sizes of a SQL Server instance) |
| Drive Performance | read and write latency, throughput and IOPS per drive over the page's range | SQL Server: each database file's virtual file stats, the file placed on its drive; PostgreSQL: `system_stats`' device counters (an on-prem host; RDS and Aurora have no device read) |

The folder's other pages follow them: Disk report, Storage, Growth, New and dropped databases and Indexes at the root and in a tag folder; Storage, Database info and New and dropped databases under a PostgreSQL instance; Storage, Database files and Row versions under a SQL Server instance.

## Drives

Each drive is a bar filled to its used share: green while its free space is above the warning, amber under the warning, red under the critical. Beside it is DBA Dash's drive icon with its mark: a green tick, an amber '!', a red 'x' (a grey '?' where the size is not read); the status word is the icon's accessible name, and the grid and the export keep the word. Under the bar is `<free> GB free (<per cent>) of <size> GB` and `Updated <time> (<age> ago)`. At the right are the Warning and Critical per cents it is judged by, where they were set, and Configure. Files lists the files on that drive (the instance's Files page for the drive, as DBA Dash's does); History shows the drive's used and free space over 30 days. A drive whose size the door does not give (Aurora's local storage) shows no bar and says so.

The status filter at the top lists Critical and Warning first in a folder, and every drive under an instance, as DBA Dash does; All, Critical, Warning and OK are beside it, and the choice is kept per browser. Toggle Metrics shows the same drives as a grid, with the grid's copy, export and columns. Refresh reads them again.

### Thresholds

A drive is judged on its free space as a per cent of its size: a warning under the warning per cent, a critical under the critical per cent. Each engine keeps the rule it had: a PostgreSQL drive is judged on the per cent rounded to 0.1, as the page shows it; a SQL Server volume on the exact ratio, so at the default a volume at 9.96 % free is critical though the page shows 10.0 % (a PostgreSQL drive there is a warning). The threshold in force is the drive's own, else its instance's, else a tag's (the first tag by name when two of the instance's tags carry one), else the root's, else the default: DBA Dash's, warning under 20 %, critical under 10 % (migration 0113; before it the default was 10 / 5, the rule both engines used before thresholds could be set). The check names stay 'disk free under 10 %' and 'a volume under 10 % free' (alert rules and acknowledgements match them); each finding's detail names the threshold in force.

Configure on a drive sets that drive's; Configure in the toolbar sets the scope's: the root at the root, the tag in a tag folder, the instance under an instance. Inherit ends a level's own threshold, so the level above applies again. Who set a threshold, when, and which row it replaced are kept. Setting one takes a signed-in user and the actions configuration, as the other threshold pages do.

The Summary's Drive Space column (DBA Dash's name) judges by the same threshold on both engines (a SQL Server volume's finding has that column of its own), and the finding's detail names the threshold and where it was set. The other pages that colour a volume's free space take the same judgement: an instance's Storage page on either engine (its volume bars too), the Host page's volumes and the Disk report. The Storage page's check 'volume under 10 % free' is another measure, the headroom against an RDS volume's capacity, and is shown as 'capacity headroom under 10 %'.

## The Summary's links

A Summary cell opens the page DBA Dash's Summary opens for it (DBA Dash's Checks/Summary.cs): Disk opens Drives on both engines; Storage opens Drives on PostgreSQL (its checks are volume checks) and Files on SQL Server (its checks are file and log checks, DBA Dash's Log Space). Collection opens Collection dates (DBA Dash's Snapshot Age: Checks > Collection Dates, both engines); Database state opens the database options (DBA Dash's DB Options: PostgreSQL's Database options page, SQL Server's Checks page in its Database options view); QS opens the Query Store page on SQL Server and Server state, where the statement store is judged, on PostgreSQL; Uptime opens DBA Dash's Instance Uptime dialog over the Summary. In the tests grid, Disk and Storage open Drives over the scope. The tree's Storage folder opens Drives at the root, in a tag folder and under an instance of either engine. No Summary link opens the Daily checks list. `scripts/proof-clickmap.sh` clicks them.

### Collection dates

One row per instance and collection, at the root, a tag folder or an instance (Checks > Collection dates): the status (Critical: the last run failed; Warning: the last run is older than three of the collection's intervals, 300 s at least, the daily check 'collection stale'; OK; Disabled where the collection's interval is 0), the last run and its age, the warning threshold, the schedule (the collector's interval) and the next run, the last success, the last error kept, the run's duration and note. The repository keeps one run per collection and the failed ones: a last success older than a failed last run is not kept.

### The Uptime dialog

The Summary's Uptime cell opens a dialog over the grid, as DBA Dash's does, on both engines, in its layout: the instance, its Uptime and Start Time, the threshold in force and where it was set (the instance's own, a tag's, the root's or the default: DBA Dash's, a warning under 48 hours, a critical under 12), Inherit, Enabled, Warning / Critical over their boxes, Clear Alert and Update; the root's own from the Summary's Options > Instance Uptime > Configure Thresholds. It is the uptime threshold of the Thresholds page, one store for both engines: a SQL Server instance takes one too (migration 0113), and the SQL Server summary's Uptime cell judges by it. Setting one takes a signed-in user and the actions configuration.

## Proof

`scripts/proof-clickmap.sh` runs on the demo (12 PostgreSQL and 3 SQL Server instances):

- T: the thresholds. At the default (20 / 10), every drive judges by DBA Dash's rule, its edges by a fixture at 19.96 % and 9.96 % free on each engine; host_checks and the SQL Server findings raise exactly those drives. Then a root, a tag, an instance and a drive threshold each take their drives, and inherit falls back a level. Six bad attempts are refused and write nothing. T9: a SQL Server instance takes an uptime threshold (another key is refused there), `/api/uptime` and the SQL Server summary's Uptime cell follow it, and inherit ends it.
- R: the reads (`/api/drives`, `/api/drives/history`, `/api/dbspace`, `/api/dbfiles` with a drive's files, `/api/driveperf`, `/api/collectiondates`) against the repository's own rows; the write is refused without the header or a login.
- C: `scripts/click-check.mjs` in a headless Chromium. From the Summary at the root, a tag folder, a PostgreSQL instance and a SQL Server instance, every link's target is checked against DBA Dash's map, one link per column, engine and scope is clicked, and every tab of the Storage folder at those scopes is opened; the Uptime cell's click must open the dialog with the instance's name and thresholds (and, since task P08, the Summary's shape, its Options menu and both threshold dialogs' layout and order), and each drive's Files link under an instance must list that drive's files only. No landing may be Daily checks.

Not proven here: Drive Performance on a PostgreSQL host with real devices (the demo's device counters are synthetic); a threshold set through the UI's Configure on a server with the actions configuration (the proof sets them through the same function; on a server without logins the page's write is refused, 403, as proven; the signed-in path is not); the Uptime dialog's Set and Inherit through the UI on a server with logins (the proof sets the threshold through the same function and opens the dialog); Windows volumes for PostgreSQL.
