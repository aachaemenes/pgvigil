# Storage

The Storage folder holds the same six pages on both engines, in the order the folder lists them. They appear at the root of the tree, in a tag folder and under an instance. The first five are at every scope; Drive Performance is an instance's page.

| Tab | What it shows | Read from |
| --- | --- | --- |
| Drives | one bar per drive with its free space and the threshold it is judged by | PostgreSQL: the host collection's volumes (`system_stats`, or CloudWatch on RDS and Aurora); SQL Server: `mssql_storage`'s volumes (`sys.dm_os_volume_stats`) |
| DB Space | the space the databases hold: per instance in a folder, per database under an instance, with its history | PostgreSQL: `pg_database_size` per database (`databases`); SQL Server: the data and log files (`mssql_storage`) |
| Files | SQL Server's data and log files; PostgreSQL's WAL directory and tablespaces | `mssql_storage`; the `storage` collection |
| TempDB | SQL Server's tempdb files per instance | `mssql_tempdb` ([SQL Server storage](sqlserver-storage.md)) |
| Table Size | the largest tables with their growth | the `tables` collection (PostgreSQL only: the repository holds no table sizes of a SQL Server instance) |
| Drive Performance | read and write latency, throughput and IOPS per drive over the page's range | SQL Server: each database file's virtual file stats, the file placed on its drive; PostgreSQL: `system_stats`' device counters (an on-prem host; RDS and Aurora have no device read) |

The folder's other pages follow these six: Disk report, Growth, New and dropped databases and Indexes at the root; Tables, Storage, Database info and New and dropped databases under a PostgreSQL instance; Storage, Database files and Row versions under a SQL Server instance.

## Drives

Each drive is a bar filled to its used share: green while its free space is above the warning, amber under the warning, red under the critical. Under the bar is `<free> GB free (<per cent>) of <size> GB` and `Updated <time> (<age> ago)`. At the right are the Warning and Critical per cents it is judged by, where they were set, and Configure. Files opens the instance's Files page; History shows the drive's used and free space over 30 days. A drive whose size the door does not give (Aurora's local storage) shows no bar and says so.

The status filter at the top lists Critical and Warning first in a folder, and every drive under an instance, as DBA Dash does; All, Critical, Warning and OK are beside it, and the choice is kept per browser. Toggle Metrics shows the same drives as a grid, with the grid's copy, export and columns. Refresh reads them again.

### Thresholds

A drive is judged on its free space as a per cent of its size: a warning under the warning per cent, a critical under the critical per cent. Each engine keeps the rule it had: a PostgreSQL drive is judged on the per cent rounded to 0.1, as the page shows it; a SQL Server volume on the exact ratio, so a volume at 9.96 % free is a warning though the page shows 10.0 %. The threshold in force is the drive's own, else its instance's, else a tag's (the first tag by name when two of the instance's tags carry one), else the root's, else the default: warning under 10 %, critical under 5 %, the rule both engines used before thresholds could be set.

Configure on a drive sets that drive's; Configure in the toolbar sets the scope's: the root at the root, the tag in a tag folder, the instance under an instance. Inherit ends a level's own threshold, so the level above applies again. Who set a threshold, when, and which row it replaced are kept. Setting one takes a signed-in user and the actions configuration, as the other threshold pages do.

The Summary's Disk column judges by the same threshold on both engines (a SQL Server volume's finding now has the Disk column of its own, DBA Dash's Drive Space), and the finding's detail names the threshold and where it was set. The other pages that colour a volume's free space in the Storage folder (an instance's Storage page on either engine) take the same judgement.

## The Summary's links

A Summary cell opens the page DBA Dash's Summary opens for it (DBA Dash's Checks/Summary.cs): Disk opens Drives on both engines; Storage opens Drives on PostgreSQL (its checks are volume checks) and Files on SQL Server (its checks are file and log checks, DBA Dash's Log Space). In the tests grid, Disk and Storage open Drives over the scope. The tree's Storage folder opens Drives at the root, in a tag folder and under an instance of either engine. No Summary link opens the Daily checks list. `scripts/proof-clickmap.sh` clicks them.

## Proof

`scripts/proof-clickmap.sh` runs on the demo (12 PostgreSQL and 3 SQL Server instances):

- T: the thresholds. At the default, every drive judges as before; host_checks and the SQL Server findings raise the same drives as before. Then a root, a tag, an instance and a drive threshold each take their drives, and inherit falls back a level. Six bad attempts are refused and write nothing.
- R: the reads (`/api/drives`, `/api/drives/history`, `/api/dbspace`, `/api/dbfiles`, `/api/driveperf`) against the repository's own rows; the write is refused without the header or a login.
- C: `scripts/click-check.mjs` in a headless Chromium. From the Summary at the root, a tag folder, a PostgreSQL instance and a SQL Server instance, every link's target is checked against DBA Dash's map, one link per column, engine and scope is clicked, and every tab of the Storage folder at those scopes is opened. No landing may be Daily checks.

Not proven here: Drive Performance on a PostgreSQL host with real devices (the demo's device counters are synthetic); a threshold set through the UI's Configure on a server with the actions configuration (the proof sets them through the same function; the page's write is refused without a login, as proven); Windows volumes for PostgreSQL. A drive's Files link opens all of its instance's files, not that drive's alone (DBA Dash's opens the drive's).
