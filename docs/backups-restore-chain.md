# SQL Server: the restore chain

The collection `mssql_restore_chain` (hourly) reads, from each SQL Server's own msdb, the backup sets a restore of each
database needs, and the repository decides the chain from them: which sets, in which order, and where it breaks. The
Restore chain tab shows it per database; a break raises the finding 'the log chain is broken' among the instance's findings
(and in the Summary's Backup LOG cell). pgvigil writes and runs no restore and takes no backup: the collection's
statements hold neither verb (a test checks it).

## What is read

| Collection | Interval | Reads |
|---|---|---|
| `mssql_restore_chain` | 1 hour | `msdb.dbo.backupset`, `backupmediafamily` and `backupmediaset`: per database the newest full backup that is not copy-only with the newest differential after it, the newest copy-only full, and every log backup since the start set they give - each with its LSNs, its recovery fork (`family_guid`, `fork_point_lsn`), `last_valid_restore_time` where msdb has it (SQL Server 2022 and later), and every file of its media (stripes and mirrors); only sets of the database's current recovery fork (the fork of its newest backup by finish time, and of the parent fork the sets up to the fork point), each set once by `backup_set_uuid`; the count of partial and file backups |

It needs what `mssql_backups` needs: a user in msdb with `db_datareader`. It is not run on Azure SQL Database (no msdb
backup history). The logs are read behind one floor on `backup_finish_date` (the column msdb indexes for its history
cleanup: an hour before the earliest start set of any database, and at least 7 days back); per database the logs since
its own start set, or its last 7 days when it has no start set on this server (a replica whose full backups run
elsewhere); at most 2,016 per database (7 days of 5-minute log backups), the newest. When more logs exist since the start set than were sent, the
tab says so and 'Copy the file list' is off: a list from it would miss some; a gap below the oldest log listed is held,
never called a break. A RESTORE on the server writes the restored sets' rows into msdb again under the same
`backup_set_uuid`: each set is read once (the lowest `backup_set_id`).

Partial and file backups (msdb types P, Q, F, G) are not read into a chain: the tab says how many msdb lists.

LSNs (`numeric(25,0)` in msdb) travel as text from the server to the page: they are never put through a floating-point
number, and the page never sorts or computes with them.

## How the chain is decided

1. The start set: the candidate with the greatest `last_lsn` among the newest full backup that is not copy-only (or its
   differential when that follows it: the differential's `differential_base_guid` equals the full's `backup_set_uuid`)
   and the newest copy-only full - a copy-only full restores like any full.
2. Then every log backup in LSN order, from every monitored replica of the database's availability group (one set once
   by its `backup_set_uuid`), on the recovery fork of the newest set by its finish time (a restore over the database to
   an older point starts a fork whose LSNs lie below the old fork's newest: the chain follows the database as it is
   now); a set of the parent fork counts when it ends at or before the fork point.
3. A log that ends at or before the LSN reached is not needed (no step); a copy-only log is listed, never a step; a log
   whose `database_backup_lsn` is not the start set's checkpoint is marked, never left out.
4. A log to the NUL device is a hole: the chain went to NUL there. A log whose `first_lsn` is past the LSN reached is a
   break - unless the gap is held, never called a break, because a log in it may exist: a replica's last successful
   read is older than the finish of the set after the gap ('not yet read from <instance> (last read <time>)'); a read
   did not list every log back to the step before the gap - capped, or a replica without a start set of its own that
   lists its last 7 days ('not read whole: ...'); the database is in a distributed availability group, whose other side
   pgvigil does not merge ('not judged (the distributed availability group ...)').

The verdict per database:

| Verdict | When |
|---|---|
| restorable from these backups to <time>; later than that needs a tail-log backup | the chain is whole to its last log (`last_valid_restore_time` where msdb has it, else the log's START in UTC: a log may hold nothing written after it began) |
| restorable to the full / differential | SIMPLE recovery, or no log backup since the start set |
| broken before the log of <time>: the log from LSN a to b is in no msdb read | a break; the restorable point before it is said too |
| went to NUL at <time>: the log from LSN a to b was not kept | a log to the NUL device |
| not yet read from <instance> (last read <time>) | a gap a replica's late read may fill: held |
| not read whole: <instance>'s read lists its log backups since <time> only | a gap below what a capped read or a replica without a start set listed: held |
| not judged (the distributed availability group <name>: its other side's msdb is not merged) | a gap in a distributed group: held |
| no full backup on the current recovery fork; the earlier full is on a previous fork - not judged | a restore over the database with logs only since |
| no full backup of this database in the msdb history read | nothing to start from |

## Findings

| Finding | Severity | When |
|---|---|---|
| the log chain is broken | warning | a database judged for its log backups (as on the Backups tab) whose verdict is a break or a log to NUL, every replica of its group monitored; never for a held gap; not on Amazon RDS or Azure SQL Managed Instance |

The finding reaches the instance's findings and the Summary's Backup LOG cell through the lead's wiring (its
`pgvigil.findings` arm and the Summary's map); the Backups tab's own findings are 301's.

Marks on a step: a copy-only full (no differential can follow it), damaged, a snapshot backup, a virtual-device backup
(restored through the tool that took it; 'Copy the file list' is off for such a chain), a URL or tape backup, the set's
place on its media, bulk-logged data, a log whose full is another than the start set's, and on the start set a newer
full that went to NUL (a differential after it does not restore on this start).

## Where pgvigil differs from dbatools on purpose

The start set is chosen as dbatools 2.9.1's `Get-DbaDbBackupHistory -Last` chooses its full and its differential, but:

- a newer copy-only full is a start set (dbatools' default skips copy-only fulls; with `-IncludeCopyOnly` they agree);
- logs are chosen by LSN and recovery fork only: dbatools lists a log whose `last_lsn` passes the start set's
  `first_lsn`, so a log that ends exactly at the differential's `last_lsn` (taken right after it with nothing written in
  between) is in dbatools' list and is no step here - it applies nothing;
- dbatools names no gap in the log chain; pgvigil names the first one, or holds it while a replica's read is late;
- dbatools reads no availability group: pgvigil merges the replicas' msdb.

dbatools is MIT-licensed, Copyright (c) 2018 Chrissy LeMaire; no code of it is copied (THIRD-PARTY-NOTICES.md).

## Not judged or not proven

- Amazon RDS and Azure SQL Managed Instance keep their backups themselves: the tab shows the platform's line and the
  finding is off.
- A distributed availability group: a gap is held ('not judged'), never raised; the other side's msdb is not merged.
- Not proven on a live server: a forced failover's new recovery fork (the repository test holds the fork rule), a
  snapshot or virtual-device full (the marks are proven on stored rows of the repository test), SQL Server 2025's full
  and differential backups on a secondary replica.
