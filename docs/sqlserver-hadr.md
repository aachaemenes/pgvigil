# SQL Server: availability, Agent jobs and backups

Six collections of the [SQL Server engine](sqlserver.md) and the three tabs they feed. Nothing is installed on the monitored server and nothing is written there: every statement is a SELECT over the DMVs, the catalog, msdb and, on a distributor, the distribution database.

| collection | every | reads | needs |
| --- | --- | --- | --- |
| `mssql_ag` | 1 min | Always On availability groups: groups, replicas, database replicas, listeners, cluster members | Always On enabled, VIEW SERVER STATE, VIEW ANY DEFINITION |
| `mssql_mirroring` | 1 min | database mirroring: `sys.database_mirroring` and the Database Mirroring counters | VIEW SERVER STATE for the queues |
| `mssql_logshipping` | 5 min | msdb's `log_shipping_monitor_primary` and `_secondary` | a user in msdb with db_datareader |
| `mssql_replication` | 5 min | the distribution database's own tables, on a distributor | a user in the distribution database with db_datareader |
| `mssql_jobs` | 5 min | SQL Server Agent: jobs, steps, schedules, what runs now, the job history | a user in msdb with db_datareader |
| `mssql_backups` | 1 hour | every database with the last full, differential and log backup in `msdb.dbo.backupset` | a user in msdb with db_datareader |

A collection that lacks its right does not fail the instance: its row on the Collections page says `skipped` with the missing right. msdb lets every login in through its guest user, so each msdb collection asks for the right to its own table before it reads.

None of them runs on Azure SQL Database (no Agent, no msdb backup history, no availability group to read).

## Availability groups

Per group: the primary as the group's own state names it, the cluster type (a clusterless group is read like any other), whether it is distributed or contained (where the version has the column: distributed from 2016, cluster type from 2017, contained from 2022), the listeners, and the cluster's members where the server has a cluster and lets the login read it.

Per replica: role, commit mode, failover mode, connected state, synchronization health, operational state, the last connect error.

Per database replica: synchronization state and health, suspended with its reason, the log send queue and rate, the redo queue and rate, the last sent, received, hardened, redone and commit times (moved to UTC on the server), and two estimates as the documentation of `sys.dm_hadr_database_replica_states` gives them:

- estimated recovery time = redo queue / redo rate;
- estimated data loss = the primary's last commit time less the replica's. Only a primary can compute it: it alone sees both rows.

While data movement of a database is suspended, SQL Server reports no send queue for it at all (the column is NULL; read on SQL Server 2022): the exposure shows as the estimated data loss growing and as the finding "a database is suspended", and the queues reappear while the replica catches up after RESUME.

What an instance sees depends on where it stands. A primary sees every replica and every database replica. A secondary sees its own rows, and the group's primary by name; the other replicas' state columns are empty there, and the page says "not visible from here". Monitor every replica as an instance of its own.

A **distributed** group is stored as such; its two "replicas" are its member groups, by name, and its queues are the link's. A **contained** group is marked. Neither is proven here (no such group on the test servers).

**A replica's role is what the server reports, nothing more.** A managed read replica has been reported to name itself PRIMARY (unproven here). pgvigil therefore decides nothing from the role alone: backups are judged wherever they ran, and the primary shown is the one the group's state names.

**Failovers.** A group in the middle of a failover names no primary; the last one known is kept through such a read. When the primary of a group differs between two reads, the change is kept as an event with its time (`mssql_ag_failovers`: the read that first saw the new primary, so the failover happened in the minute before). The Availability tab lists the events of the window; a finding stays for an hour.

The queues of every read are kept (`mssql_ag_sample`, monthly partitions) and charted over the window, with the same numbers as a table.

## Mirroring, log shipping, replication

Sections of the Availability tab that appear only where the server has the feature.

- **Mirroring**: role, state, safety level, partner, witness and its state, the send and redo queues.
- **Log shipping**: per primary database the last log backup, per secondary the last copy and restore, each against the threshold its own configuration in msdb names. A monitor server lists every secondary; two secondaries that carry the same database name are two rows.
- **Replication**, as the distributor knows it: publications, subscriptions with the distribution agent's last status, the commands not yet delivered (the distribution database's view `MSdistribution_status`) and the time to deliver them at the agent's last rate, and the log reader, snapshot and merge agents with their last status. **No tracer token is ever written and no replication procedure is called.** A publisher whose distributor is another server is read there: add the distributor as an instance. A distribution database the login cannot enter is named in the collection's note with the missing right (a distribution database on a secondary replica that takes no connections reads the same way: read it on the primary). When one of the three reads of a distribution database fails, the rows of the reads that worked are replaced and the failed read's rows stay as last read.

## Agent jobs

Per job: owner, enabled, category, schedules, the next run (the Agent's own value for its current session; else the schedule table's, which the Agent refreshes every 20 minutes), the last outcome with its duration and message, whether it runs now and since when. Per step: subsystem, database, last outcome and duration. **A step's command is never read**: it can hold a password.

The job history (`msdb.dbo.sysjobhistory`) is read forward from a cursor on its `instance_id`, kept in the repository and advanced in the transaction that stores the rows. Each read starts 50 rows behind the cursor (a row can become visible after a newer one) and goes on, 5,000 rows at a time, until it has caught up or has read 100,000 rows; the next run reads on. A first read, and a read after a long stop, go back seven days by the run's start date and no further: a run that started more than seven days before it is first read is not stored.

The cursor carries a mark of the row it stands on. When that row is no longer in msdb, or is another row (msdb restored, or the server replaced under the same name: the numbering starts again), the read starts over from the kept window. A row is stored once either way: it is known by its number, job, step and msdb's own date and time.

msdb keeps dates and times as integers (`20261110`, `93005`) in the server's local clock. They are turned into datetimes on the server and moved to UTC by the offset the server has at the read: a row written before a daylight-saving change is one hour off (not proven here: the test servers keep UTC).

The Jobs tab: what runs now (with the average of the job's good runs beside it), the failed runs of the window with the step that failed and its message, every job, and the runs per job over the window.

## Backups

Per database: state, recovery model, and the last full, differential and log backup (finish time, and from the server that took it the size, compressed size, duration, device and copy-only). The finish time is moved to UTC by the offset `backupset.time_zone` recorded with the backup.

- **A backup to the NUL device is no backup.** It never counts as the last backup of its type; it is kept apart and raises a finding.
- **An automatic seeding stream is no backup either.** When a database joins an availability group with automatic seeding, msdb records the stream to the new replica as a copy-only full backup to a virtual device named by a bare GUID. Such a row (full, copy-only, virtual device, a GUID for its device name, no backup name) is left out: it never counts as the last full backup. A copy-only snapshot (VSS) backup has the same device shape and is a backup: it counts. A backup tool that writes copy-only full backups that are not snapshot backups through a virtual device named by a bare GUID, without a backup name, would be left out the same way; none is known to.
- **msdb is each server's own record**, and only the server's own rows are read: a restore copies the source server's backup rows into msdb, and those are not this server's backups. A server renamed since shows no backup older than its rename, until the next one runs. A database in an availability group shows, per type, the newest backup that any *monitored* replica took, with the instance it ran on; that backup's size and device are on that instance's tab. A group with a replica that is not monitored is not alarmed on: the finding says the backup may run where pgvigil does not look.
- **A backup older than its database is not its backup.** msdb keys its history by name: a backup that finished before the database was created belonged to an earlier database of that name and is not counted. A restore also sets a new creation time, so a restored database shows no backup until its first one after the restore; the finding says "created or restored <time>; no full backup since", so nobody hunts for a lost history.
- **A backup once seen is kept** when msdb's history is trimmed, and the tab says how far back msdb's history reaches: "no backup in msdb" is not always "never backed up".
- **Not judged**: tempdb, a database that is not online, a database snapshot, a standby database, a database younger than `new_database_hours`, a name matching `backup_exclude`. The log backup is judged only under the full or bulk-logged recovery model, after a first full backup, and not for `model` or a read-only database.
- **Every age is the age at the read.** The collection is hourly; a page opened 50 minutes later does not add 50 minutes to a log backup's age.

## Findings

`mssql_hadr_findings`:

| finding | severity |
| --- | --- |
| a replica is not connected / a replica is not healthy | critical |
| a database is suspended / a database is not synchronizing | critical |
| the primary of a group changed (for an hour) | critical |
| the log send queue is over its threshold / the redo queue is over its threshold, in every read of 5 minutes | warning |
| a synchronous replica is not synchronized | warning |
| mirroring is disconnected or suspended | critical |
| log shipping is behind its threshold | warning |
| a replication agent failed / undistributed commands over the threshold | warning |
| a collection stores nothing where rows are expected (`mssql_ag` on a server with Always On enabled, 60 reads) | info |

`mssql_jobs_findings`:

| finding | severity |
| --- | --- |
| a job failed (in the last `job_failed_hours`, 24 by default and at most 744; with the step, its message and the next run) | warning |
| a job runs far longer than its average | info |
| no full backup ever / no recent full backup | critical |
| no recent log backup | warning |
| no recent differential backup (only when `diff_backup_hours` is set) | warning |
| a backup went to NUL | warning |
| backups not judged: a replica of the group is not monitored | info |
| a collection stores nothing where rows are expected (`mssql_backups` read no database) | warning |

Each instance reports what it sees. When the primary and a secondary of one group are both monitored, a finding about a database of the group (suspended, a queue, a late backup, a failover) is raised on each of them.

A state that was not read lately fires nothing (5 minutes for the minute collections, 15 for the five-minute ones, 130 for backups); the Collections page says the read is stale.

## Thresholds

Per instance, all optional; a name left out keeps its default. An unknown name fails the run with the list of known ones.

```yaml
instances:
  - name: sales-sql01
    engine: sqlserver
    dsn: env:SALES_SQL01_DSN
    mssql_thresholds:
      log_send_queue_kb: 102400            # 100 MB, in every read of 5 minutes
      redo_queue_kb: 512000                # 500 MB, in every read of 5 minutes
      repl_undistributed_commands: 100000
      job_failed_hours: 24
      job_long_factor: 3                   # a running job at 3 times its average ...
      job_long_min_seconds: 300            # ... and at least 5 minutes past it
      full_backup_hours: 168               # 7 days
      diff_backup_hours: 0                 # 0 = differential backups are not judged
      log_backup_minutes: 60
      new_database_hours: 24
      nul_backup_days: 7
      backup_exclude: ['scratch%', 'tmp%']    # patterns of database names: % any text, _ any one character, any case
```

A threshold of 0 turns its finding off.

## One run by hand

```
pgvigil collect -config pgvigil.yaml -once mssql_ag -instance sales-sql01
```

## Proof

`scripts/proof-mssql-hadr.sh` runs against two SQL Server 2022 containers that share a clusterless availability group, as a least-privilege login of its own on each node. Proven there: the group read from the primary and from the secondary with the roles right on each; a database the proof adds to the group, suspends on the secondary and resumes (the finding, the estimated data loss growing while suspended, the queue of the catch-up where a read catches it, the drain); a full backup on the primary and a log backup on the secondary merged by group, the seeding stream msdb records left out, the thresholds from the configuration, a backup to NUL, an excluded name; a job that fails at its second step found with the step's message, its next run and its history read once through the cursor; a running job; a login without a user in msdb skipped with the reason; every statement compiled and run by the server on both nodes.

Not proven: the findings "a job runs far longer than its average", "no recent full backup" (only "no full backup ever"), "no recent differential backup", "a replica is not connected", "a replica is not healthy", "a database is not synchronizing", "a synchronous replica is not synchronized" and the two "a collection stores nothing" findings were never raised by a test; the three pages were never opened in a browser by the proof (it reads their API); the report that a managed read replica names itself PRIMARY. Also not proven, each named by the proof: a distributed or contained group, a listener, a Windows cluster's members; a queue held over its threshold for five minutes on a live server (the two queue findings are proven over stored samples); a real mirrored database, log shipping pair or distributor (their collections run and find none; their imports and findings are proven over stubbed rows, and the replication statements over a stand-in database with tables of the documented shape); `backupset.time_zone` on real rows of a server whose clock is not UTC (the expression is proven over literal rows: -32 is eight hours behind UTC); SQL Server 2016 to 2019, Amazon RDS, Azure SQL Managed Instance; anything on Windows.

## Sources

The running-jobs filter and the shape of the job history read follow DBA Dash 4.24.1 (`DBADash/SQL/SQLRunningJobs.sql`, `SQLJobHistory.sql`; MIT, Copyright 2022 Trimble, Inc.); "the newest backup per database and type, this server's own" follows its `SQLBackups.sql`. The statements are pgvigil's own, written from the documentation of the views and tables they read.
