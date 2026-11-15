# SQL Server: where the backups went

The collection `mssql_backup_files` (hourly) reads, from each SQL Server's own msdb, where the newest full, differential and
log backup of every database went: every file of the backup set, each stripe and each mirror, with the path whole. It sits
beside `mssql_backups`, which keeps reading the times and ages the Backups tab and the Summary judge; the two are joined in
the repository.

| Collection | Every | Reads | Needs |
|---|---|---|---|
| `mssql_backup_files` | 1 hour | `msdb.dbo.backupset`, `backupmediafamily`, `backupmediaset` and `backupfile`: per database and type the newest set this server took and kept somewhere (not the NUL device, not an availability group's seeding stream), and beside a copy-only full the newest full that is not copy-only; every media family and mirror of those sets; the database's own files as msdb recorded them with the set; the log backups of the last 7 days by destination and login | a user in msdb with db_datareader |

It is not run on Azure SQL Database (no msdb backup history: the service keeps its backups itself). A login without SELECT
on one of the four tables is skipped with the table named.

## What it reads, and how often

The first read goes through `msdb.dbo.backupset` once; every read after it starts from the newest `backup_set_id` it read
(50 rows behind, a row numbered before it may become visible late), so an hourly read of a server with years of history
and 15-minute log backups reads the sets written since. A mark (the checksum of that row's `backup_set_uuid`) tells a
replaced msdb (a restore, a rebuilt server under the old name, its numbering started again) from the one read: then the
read starts from the beginning again. The newest set is chosen by its finish time in UTC (`backupset.time_zone`), so a
backup taken in the hour the clocks go back is not outranked by an earlier one.

`compression_algorithm` and `last_valid_restore_time` are read where msdb has them (SQL Server 2022 and later).

The repository keeps the newest set of each key (database, type, copy-only) and replaces it only with a newer one; a set
msdb no longer lists stays. As `mssql_backups` does, a set is kept only for a database the server lists and only when it
finished after the database was created (an hour of slack); a database created anew under an old name starts without the
old one's sets. A database a read does not list loses its sets; when a later read lists it again (a login that
could not see it for a while: `sys.databases` lists only what the login may see), the next read starts from the
beginning again, so its sets older than the cursor come back.

## The page

- The Backups tab of a SQL Server instance, Databases grid: DBA Dash's Detail columns at DBA Dash's places - full,
  differential and log damaged after 'backup to NUL'; full, differential and log checksum, compressed, password
  protected, encrypted and compression algorithm after the sizes - and pgvigil's own after them: **full to**,
  **differential to**, **log to**, the folder (a URL's container) of the newest backup of the type, its file count when
  striped and 'mirrored' when mirrored.
- A database opens its **Last backup** panel under the grid (DBA Dash's drill from a database, its Last Backup grid):
  one row per type kept, DBA Dash's 26 columns in its order, then pgvigil's own - to, files, mirrors, device, taken by,
  machine, set name, description, software, copy-only, incomplete metadata, the differential's base, the media set's
  password, and whether the backup sits on the database's own volume. Under it every file of those sets with a Copy
  button per path and one for all, the log backups of the last 7 days by destination, and the destinations seen.
- **Backup files**: every file of every database's kept sets; the export writes it as its own sheet.
- The fleet's Backups page, SQL Server by instance: DBA Dash's Summary texts - full, differential and log checksums,
  compressed, password protected and encrypted as 'n/m' over the judged databases with a backup of the type, and the
  compression algorithms as 'NAME(count)'.

## Findings

| Finding | Severity | When |
|---|---|---|
| a full / differential / log backup on the volume of the database's own files | warning (info when a replica of the group is not monitored) | the newest backup of the type that is not copy-only sits with the database's data or log files: on Windows on the same volume (the longest mount point of the instance's volumes the path starts with, compared without case; the drive letter when none is) and in that volume's root or in a directory a database file sits in (or below); on Linux in the very directory of one of the database's files |
| log backups to two destinations | warning (info when a replica of the group is not monitored) | the log backups of the last 7 days that are not copy-only went to two or more destinations or device kinds: a restore needs every log backup of the chain, from each place. Two logins writing to one destination are a note in the panel, not a finding |
| a backup destination not seen before | info, 7 days | a backup that is not copy-only went to a destination the database's backups of that type were not seen at before; a move back to a known destination writes nothing |

A destination is the part of the path that does not change from one backup to the next: a share `\\host\share` (written
as msdb holds it: `\\name`, `\\name.domain` and `\\10.1.2.3` are three destinations, and a DFS namespace hides its
target), a drive `X:\`, a Linux path's first two directories, an Azure container `https://account/container`, an S3
bucket (`s3://endpoint/bucket` in path style, `s3://bucket.domain` in virtual-host style), a virtual device by its
software. A URL's file is never part of it. SQL Server's documentation gives both S3 styles, the port optional in path
style, and no rule between them: a host with `.s3.` or `.s3-` after the bucket (Amazon's virtual host), or a file right
after the host, is read as virtual-host style; any other S3 URL with a folder after the host as path style (a virtual
host on another domain with folders is read so, its first folder taken for the bucket). Whether a URL used a SAS token, a key or a managed identity is never in msdb.

Not judged, and said so in the panel: a database that is not judged for its backups (excluded, new, offline, a snapshot,
tempdb); the volume on Windows when the instance's volumes were not read (`mssql_storage` needs VIEW ANY DEFINITION and
VIEW SERVER STATE); on Windows a directory deeper than its volume's root where no database file sits - it may be a
folder mounted for the backups alone, and the instance's volumes list only those that hold a database file
(`sys.dm_os_volume_stats` per file); on Linux any directory other than the database's own, a directory below it too
(it may be a mounted folder); on Amazon RDS and Azure SQL Managed Instance,
until a real row of theirs is seen. Each replica of an availability group has its own msdb: the newest set of each type
is the newest any monitored replica took, and two destinations split between two replicas are not seen.

## The platforms that keep their backups

- Azure SQL Database: the service keeps them (point-in-time restore 1 to 35 days, 7 by default, Basic 1 to 7); they
  cannot be downloaded and no path exists; `sys.dm_database_backups` lists their times and returns nothing on Hyperscale.
  Not read by pgvigil.
- Amazon RDS for SQL Server: automated backups are storage snapshots kept by RDS (not read by pgvigil); a native backup
  goes to S3 through `msdb.dbo.rds_backup_database` and is listed in msdb; log backups cannot be taken by the user.
- Azure SQL Managed Instance: the service backs up every database (retention 1 to 35 days, set on the service); msdb lists
  what it records, the system databases' backups are not recorded there.
