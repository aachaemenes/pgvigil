# SQL Server: storage and row versions

Two collections of the [SQL Server engine](sqlserver.md) and the three tabs they feed. Nothing is installed on the monitored server and nothing is written there.

## Storage (`mssql_storage`, hourly)

What is read:

- Every database file the server lists (`sys.master_files`; a database snapshot is left out, its sparse files are listed at the source's full size): its logical name, type (rows, log, FILESTREAM), physical path, state, size, maximum size, and its growth step as a size or as a per cent of the file.
- The space used inside each file and its filegroup, read in each ONLINE database the login can enter (`sys.database_files` and `FILEPROPERTY(..., 'SpaceUsed')`). The read is one SELECT run in that database's own context; it changes no session setting. The file's current size comes from the same read, which matters for tempdb: `sys.master_files` keeps tempdb's size at startup.
- A database the login cannot enter is kept with its allocated size, and so is one whose turn came after the run's five-minute deadline (the run then says `partial`). Its files say `used not read`, with the reason (the login cannot enter the database, the database is restoring or offline, or the read failed).
- The volumes the files sit on (`sys.dm_os_volume_stats`): mount point, label, file system, total and free space.

What is kept: the current row per file with the previous size and the time the size changed, the current row per volume, each database's data and log size per read, and each volume's total and free space per read. A file or volume the server no longer lists is marked as gone and stays as last read.

### Rights

| Right | Without it |
| --- | --- |
| `VIEW ANY DEFINITION` | The collection is skipped: `sys.master_files` lists no other database's files. |
| `VIEW SERVER STATE` | The files are stored; the volumes are not read, and the run says `partial`. |
| A user in a database | That database's files are kept with `used not read`. |

The login needs no role in a database to read the used space; a user (or the `guest` user, as in `master` and `tempdb`) is enough.

### SQL Server on Linux

SQL Server on Linux names no mount point for a volume. The directory of the files stands for the volume there, as it is (`/var/opt/mssql/data/`). Two directories on one file system then show as two volumes with the same size and free space.

### The Storage tab

- A ring per volume of used against free, a ring of the space each database holds on the instance, and a ring of data files against log files. Every ring has its numbers in a table beside it: name, size, share.
- A days selector (7, 30, 90, 180, 365). It redraws the size lines of the eight largest databases, the ring of growth by database, and the growth figures of every database and volume: the size at the start of the window, now, grown, per day. A window longer than the history says how many days it really holds.
- Grids of the volumes and the databases. A database's name opens its files.

### The Database files tab

One database at a time, chosen from a list (the largest first): a ring of each file within the database, a ring of used against free inside its files, and the grid of its files. Below it, every file of the instance: database, file, type, filegroup, size, used, free in the file, maximum size, growth, volume, path, and the last size change.

### Findings

| Finding | Severity | Rule |
| --- | --- | --- |
| a volume under 10 % free (the name kept for alert rules and acknowledgements) | warning under 20 % free; critical under 10 % (DBA Dash's defaults; Storage > Drives > Configure sets a drive, an instance, a tag or the root) | free space over total, per volume; the detail names the threshold in force |
| a file at its max size | critical | the file has a maximum, grows, and has reached it |
| a file within one growth of its max size | warning | at most one growth step is left |
| a percentage growth on a file over 10 GB | info | any per cent growth on a file over 10 GiB: the step grows with the file |
| a log file larger than its data files | info | per database, from 1 GiB of log (a decision of this build: smaller logs are not raised) |

A file set not to grow has no maximum to reach and raises neither max size finding. A read older than three hours raises nothing; the Collections page says the collection is stale.

## Row versions (`mssql_versionstore`, every minute)

SQL Server keeps the old versions of changed rows in tempdb's version store, for snapshot isolation, read committed snapshot, triggers, MARS and online index builds. Cleanup removes a version once no transaction can still read it. One transaction left open holds the whole store back, and tempdb fills.

What is read:

- The store's size: the `Version Store Size (KB)` counter and the pages reserved in tempdb's files (`version_store_reserved_page_count`), beside the size of tempdb's data files.
- The generation and cleanup rates. `Version Generation rate (KB/s)` and `Version Cleanup rate (KB/s)` are cumulative counters; the rate stored is the difference between two reads over the seconds between them. The first read after a start, or after the server restarted, has no rate.
- **The holder**: the oldest active transaction that generates or may read row versions (`sys.dm_tran_active_snapshot_database_transactions`), with its session, login, host, program, the session's current database, the transaction's start in UTC, how long it has been open, and its last statement (the session's input buffer). The statement follows the instance's `query_text` policy.
- The store per database (`sys.dm_tran_version_store_space_usage`, from SQL Server 2016 SP2).
- The persistent version store of accelerated database recovery per database (`sys.dm_tran_persistent_version_store_stats`, from SQL Server 2019): its size, the aborted transactions waiting for the cleaner, and the oldest active transaction with its session where it still runs. A database with accelerated database recovery keeps its row versions in itself, not in tempdb.

The collection needs `VIEW SERVER STATE`; without it it is skipped with that reason.

### The Row versions tab

The store's size and the two rates over the chosen range, each chart with its numbers in a table below it; the holder named beside them, with its last statement; every holder seen in the range; the store per database; the persistent version store. The heading is shared with the PostgreSQL side, where the equivalent is the xmin horizon and what holds it.

### Findings

| Finding | Severity | Rule |
| --- | --- | --- |
| the version store grows while cleanup is at zero | warning | over ten minutes of reads the store grew, versions were generated and cleanup removed nothing; the detail names the holder's session, login, program, age and last statement |
| the version store over a third of tempdb | warning | pages reserved for the store against tempdb's data files |
| the persistent version store over its threshold with aborted transactions | warning | over 1 GiB and over a tenth of the database's data files, with at least one aborted transaction |

When cleanup stands still and no snapshot transaction was active at the read, the finding says `holder unknown` and names the next read (the oldest open transaction of any kind).

## One run by hand

```
pgvigil collect -config pgvigil.yaml -once mssql_storage -instance sales-sql01
pgvigil collect -config pgvigil.yaml -once mssql_versionstore -instance sales-sql01
```

## Proof

`scripts/proof-mssql-storage.sh` runs against a SQL Server container and a PostgreSQL sandbox, as a least-privilege login, against what `sa` reads:

- a database of its own with two data files and a log: sizes, used space, maximum, growth and filegroup equal to `sa`'s read; the volume's total equal and its free space within tolerance;
- a database the login cannot enter kept with `used not read`;
- a file grown by the proof larger on the next run, with the previous size and the findings at one growth from its maximum and at it;
- a removed file marked as gone; a login without `VIEW SERVER STATE` stored as partial;
- the version store under snapshot isolation: a session holds a snapshot transaction open while another rewrites rows; the store rises across two reads with a generation rate, the holder is named with its session and last statement, and after it commits the store falls and the holder is gone;
- every finding's threshold, on imported rows.

Proven on SQL Server 2017, 2019, 2022 and 2025 in Linux containers ([versions](sqlserver.md#versions)). Not proven: Windows volumes (drive letters and mounted folders: task 144), SQL Server 2016 (task 164), Managed Instance, RDS (task 165), a server with thousands of databases, a FILESTREAM container. Azure SQL Database is not covered by either collection yet.
