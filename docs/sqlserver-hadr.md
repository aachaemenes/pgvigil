# SQL Server: availability, Agent jobs and backups

Seven collections of the [SQL Server engine](sqlserver.md) and the three tabs they feed. Nothing is installed on the monitored server and nothing is written there: every statement is a SELECT over the DMVs, the catalog, msdb and, on a distributor, the distribution database.

| collection | every | reads | needs |
| --- | --- | --- | --- |
| `mssql_ag` | 1 min | Always On availability groups: groups, replicas, database replicas, listeners, cluster members; per replica its join state and read-only routing; per database and replica joined and failover-ready; automatic seeding; the endpoint; the AlwaysOn_health session; the flow control, resent message and blocked redo counters | Always On enabled, VIEW SERVER STATE, VIEW ANY DEFINITION |
| `mssql_mirroring` | 1 min | database mirroring: `sys.database_mirroring` (with the role sequence), the Database Mirroring counters, the endpoint | VIEW SERVER STATE for the queues and rates and to see a mirror at all from a login that is not sysadmin (below), VIEW ANY DEFINITION for the endpoint |
| `mssql_logshipping` | 5 min | msdb's `log_shipping_monitor_primary` and `_secondary`, and the restore history (`restorehistory`, `backupset`) of every database that is restoring | a user in msdb with db_datareader |
| `mssql_fci` | 1 min | a failover cluster instance's nodes (`sys.dm_os_cluster_nodes`) and the node it runs on, only where `SERVERPROPERTY('IsClustered')` is 1 | VIEW SERVER STATE; a server someone runs (not RDS, Managed Instance, Cloud SQL) |
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

A **contained** group is marked; none is proven here (no such group on the test servers). A **distributed** group has its own section below.

**A replica's role is what the server reports, nothing more.** A managed read replica has been reported to name itself PRIMARY (unproven here). pgvigil therefore decides nothing from the role alone: backups are judged wherever they ran, and the primary shown is the one the group's state names.

**Failovers.** A group in the middle of a failover names no primary; the last one known is kept through such a read. When the primary of a group differs between two reads, the change is kept as an event with its time (`mssql_ag_failovers`: the read that first saw the new primary, so the failover happened in the minute before). The Availability tab lists the events of the window; a finding stays for an hour.

The queues of every read are kept (`mssql_ag_sample`, monthly partitions) and charted over the window, with the same numbers as a table.

**More per group and replica** (the tools audit's row B1, dbatools' and dbachecks' Always On checks):

- **Joined.** A replica's own word on whether its server joined the group (`sys.dm_hadr_availability_replica_cluster_states.join_state_desc`: NOT_JOINED = added on the primary, never joined there), and per database and replica whether the database joined the group there and is ready for a failover (`sys.dm_hadr_database_replica_cluster_states`: it lists the replicas a database is NOT joined on, which the database replica states do not). A replica or database that is not joined raises its own finding (a warning, as dbatools' Test-DbaAgPolicyState rates it) and nothing else for that cause: not also 'not connected' or 'not synchronizing'.
- **Failover readiness** is judged only for a replica in AUTOMATIC failover mode (a clusterless group is always MANUAL, so never there), and only where the database is synchronized, not suspended and its replica connected but the cluster still has not marked it ready: synchronizing, suspended or disconnected has its own finding already.
- **Quorum and cluster members** are stored and shown as the server reports them (on a clusterless Linux node: proven below), and judged only when the group's cluster type is WSFC.
- **The endpoint** (`sys.database_mirroring_endpoints`: state, role, port, authentication, encryption): not STARTED is critical - no replica can connect.
- **Automatic seeding**: the newest seeding of each database and remote replica of the last 7 days (`sys.dm_hadr_automatic_seeding`, with the transfer's progress from `sys.dm_hadr_physical_seeding_stats` while one runs); a FAILED one in the last 24 hours is a warning while its database is still in the group and not joined on that replica since (a restore by hand); an unjoined database whose seeding is still running is not 'not joined', from either replica's read.
- **Read-only routing**: each replica's routing URL and routing list. A list that names a replica that allows no connections in the secondary role, has no routing URL, or is not a replica of the group is a warning.
- **The group's own settings**: failure condition level and health check timeout, shown (a site's own choice: not judged, as dbachecks' policy values are not).
- **AlwaysOn_health**: the event session exists, runs and starts with the server (dbachecks' three HADR checks); on a server that holds a replica, anything else is a warning: the group's state changes and failovers are not recorded, and pgvigil's own event reader (`mssql_xe`) reads that session.
- **Flow control, resent messages, blocked redo**: the cumulative counters of the Availability Replica object (per replica this server talks to: flow control time and count, resent messages) and of the Database Replica object (per local database: its flow control and the redo that was blocked), turned into rates per second from two reads (`mssql_ag_replica_sample`, `mssql_ag_dbcounter_sample`, monthly partitions), charted beside the queues.

**Estimated data loss, judged.** One rule with two tiers, the threshold key `ag_data_loss` (minutes; set per root, tag or instance on the Thresholds page): warning at 1 minute (sp_Blitz 20260708, check 268: a secondary 60 seconds behind the primary's last commit), critical at 5 minutes (pgvigil's own default). The value judged is the smaller of the secondary's last two reads, so a single read's spike raises nothing. Each tier stands on its own: a key with only its critical set judges the critical alone. A secondary that has redone no commit yet (its last commit time NULL) is measured from its last hardened time, as sp_Blitz does; the stored row says which (`data_loss_basis`: commit or hardened). One finding per secondary and database.

## Distributed availability groups

A distributed group joins two availability groups, each with its own primary: the **global primary** (the primary of the member group that is the distributed group's PRIMARY) and the **forwarder** (the primary of the other member group, which takes the log from the global primary and passes it to its own secondaries).

**Monitor both primaries.** Add the global primary and the forwarder as instances, and the secondaries like any replica. One of the two is not enough, because SQL Server shows each fact in one place only:

- the two member groups of a distributed group are listed on the primary of each member group, nowhere else (a secondary's catalog names the distributed group and none of its members: pgvigil stores nothing of it there);
- the link between the two groups (its send queue, redo queue and lag, per database) is on the global primary alone;
- a secondary of the second group that stops is seen by the forwarder alone; the global primary goes on reporting a healthy link;
- after a failover of the distributed group the two primaries swap roles, and the link's rows move with the global primary.

**What is stored.** On each of the two primaries the distributed group is a group like any other with `is_distributed` set and the same group id on both, and two rows in place of replicas: its member groups, by name, with the role each has in it (PRIMARY, SECONDARY; the forwarder does not see the global primary's state) and the group's primary named as a member group. On the global primary there is one database row per database for the other member group: the link, with its send queue and rate, redo queue and rate, `secondary_lag_s` and the estimated data loss. SQL Server keeps no row for the global primary's own side of a distributed group, so the estimate takes the primary's last commit from the database's own row in the local member group. The forwarder has no database row of the link; what it received is on its own group's row.

**What is shown.** The Availability tab draws every distributed group the instance is part of once, as a tree: the distributed group, under it its two member groups with their role and the state of the link, under each its replicas, the global primary and the forwarder named as such, each replica that is a monitored instance linking to its own tab. The same tree is on the tab of every instance of either member group, the secondaries included: a secondary is tied to the distributed group through its own group's id, as the monitored primary of that group reports it. Which member group is the primary is what the newest read of the distributed group names, so a side that no longer answers cannot stay a second primary on the page. The state of the link is taken from a read of the last five minutes only, the global primary's where there is one. A member group whose primary's instance was not read in the last five minutes is marked stale, with the time of that read: its replicas' states are that read's. A member group whose primary no active instance reads is drawn with its listener and no replica, and says so.

**Findings** are the availability findings above; where they name a replica of a distributed group they name the member group (`dag1 / ag2`). Which instance raises what:

| what happens | on the global primary | on the forwarder | on a secondary of the second group |
| --- | --- | --- | --- |
| a database is suspended on the forwarder | a database is suspended (`dag1 / ag2 / db`), a replica is not healthy (`dag1 / ag2`) | a database is suspended (`ag2 / forwarder / db`) | a database is not synchronizing |
| the forwarder stops | a replica is not connected (`dag1 / ag2`), a database is not synchronizing | its reads fail | a replica is not connected (itself: it lost its primary) |
| a secondary of the second group stops | nothing | a replica is not connected (`ag2 / that secondary`) | its reads fail |
| the distributed group fails over | the primary of a group changed (`dag1`: from one member group to the other) | the same | nothing |

A planned failover of the distributed group is kept as one event per primary in `mssql_ag_failovers`, from one member group's name to the other's; the member groups' own primaries do not change in it and get no event.

## Mirroring, log shipping, replication

Sections of the Availability tab that appear only where the server has the feature.

- **Mirroring**: role, state, safety level, partner, witness and its state, the send and redo queues, the send and redo rates and the transaction delay per mirrored write (from two reads of the cumulative counters, kept per read in `mssql_mirroring_sample`), the database's state, and the endpoint. Judged by DBA Dash's states (4.24.1, `DatabaseMirroringSummary_Get`): **OK** synchronized with the witness unknown or connected; **warning** synchronizing, or a named witness disconnected ('the mirroring witness is disconnected': no automatic failover is possible); **critical** everything else - suspended or disconnected ('mirroring is disconnected or suspended'), PENDING_FAILOVER and UNSYNCHRONIZED ('mirroring is not synchronized'). Witness rules apply only where a witness is named. The send queue over `log_send_queue_kb` on the principal and the redo queue (the log not yet restored) over `redo_queue_kb` on the mirror, in every read of 5 minutes, are warnings: the availability groups' own two thresholds judge both features, so the redo tier needs the mirror monitored as an instance. The Availability tab shows the role, state, safety level, partner, witness, timeout and the two queues; the rates, the delay, the database state, the endpoint, `values_hidden` and the role changes are stored (the tab's columns for them are the release's wiring). **A mirror read by a login that is not sysadmin**: Microsoft's `sys.database_mirroring` page says "To see non-NULL values on a mirror database, you must be a member of the sysadmin fixed server role", so pgvigil's least-privilege login sees every mirroring column of the mirror's row as NULL (the principal's row is whole). With VIEW SERVER STATE the mirror database still has its own instance of the Database Mirroring counters, so a RESTORING database with one is stored as the mirror (`values_hidden`): role MIRROR, its redo queue and rates; its state, partner, witness and role sequence are left empty there and shown on the principal's row, and no state rule judges an empty state. A swap is still seen on that side by its role (a swap there and back between two reads is seen on the principal's side only, by its sequence). (DBA Dash's own read, `SQLDatabaseMirroring.sql`, keeps only rows with a mirroring state, so the same login there shows no mirror.) **A role swap is an event** (`mssql_mirroring_role_changes`): the role changed, or the session's role sequence moved up (two swaps between reads leave the role as it was; a sequence back at 1 is a session re-created, not a swap); 'the principal of a mirrored database changed' is critical for an hour, on each side. A witness's automatic failover ends SYNCHRONIZED and was silent before: it is now this event. On Amazon RDS the rows are read and shown, never judged: RDS runs its Multi-AZ standby on its own mirroring or availability group (the same gate holds the availability group findings there).
- **Log shipping**: per primary database the last log backup, per secondary the last copy and restore, each against the threshold its own configuration in msdb names. A monitor server lists every secondary; two secondaries that carry the same database name are two rows. **And log shipping however it was set up, from restore history** (DBA Dash's measures, 4.24.1 `LogShippingStatus`): every database that is RESTORING, in STANDBY, or RECOVERING after a log restore, with its newest log restore of the last 14 days. Two measures, each with two tiers (threshold keys, minutes, per root, tag, instance or database): the time since the last log restore (`logship_restore_age`, 1440 / 2880) and that restore's latency, from the start of the log backup it restored to the restore (`logship_restore_latency`, 1440 / 2880). The backup's start is the primary's clock: it is moved to UTC by `backupset.time_zone` (127 = unknown: the server's own offset). The restore's own time is this server's clock, moved to UTC by its offset at the read: across a daylight-saving change it is an hour off (and so is the latency) until the next restore. The pair is the server and database the restored log backups came from. Not judged: a database younger than `new_database_hours` (24 = DBA Dash's 1440 minutes), a mirrored database (a mirror a login that is not sysadmin sees with empty mirroring values is known by its Database Mirroring counter instance, with VIEW SERVER STATE; without that right it reads as a restore left behind), a database in an availability group, SIMPLE recovery. A database msdb's monitor already judges gets the critical tier only for the time since its last restore (msdb's own threshold is its warning: never two warnings); its latency, which msdb does not judge, keeps both tiers. msdb's database name is matched without regard to case. A database left restoring with no restore of any kind in `restoring_days` days (2; sp_Blitz check 111) is a warning (critical from the key's critical tier when one is set); one whose last restore was a log restore older than the 14 days read is a log shipping copy broken past every tier: critical; a database that had log restores in the last 14 days and no longer exists is 'a log shipping copy is missing' (a warning). A copy brought online is not judged (it is often a planned failover).
- **Replication**, as the distributor knows it: publications, subscriptions with the distribution agent's last status, the commands not yet delivered (the distribution database's view `MSdistribution_status`) and the time to deliver them at the agent's last rate, and the log reader, snapshot and merge agents with their last status. **No tracer token is ever written and no replication procedure is called.** A publisher whose distributor is another server is read there: add the distributor as an instance. A distribution database the login cannot enter is named in the collection's note with the missing right (a distribution database on a secondary replica that takes no connections reads the same way: read it on the primary). When one of the three reads of a distribution database fails, the rows of the reads that worked are replaced and the failed read's rows stay as last read.

## Failover cluster instance

Read only where `SERVERPROPERTY('IsClustered')` is 1 (the clustered flag): each node of the Windows cluster the instance may run on (`sys.dm_os_cluster_nodes`: its state, which one owns the instance) and the node it runs on now (`SERVERPROPERTY('ComputerNamePhysicalNetBIOS')`). A change of the owning node is kept as an event (`mssql_fci_owner_changes`) and raises 'the failover cluster instance moved to another node' (critical, for an hour: the instance restarted there); a node that is not up is a warning; no other node up to fail over to is 'no spare cluster node' (a warning; sp_Blitz check 184). **Not proven: no Windows cluster** in the labs (it needs a failover cluster and shared storage); the statements are compiled and run on servers that are not clustered, where they read nothing.

## Agent jobs

Per job: owner, enabled, category, schedules, the next run (the Agent's own value for its current session; else the schedule table's, which the Agent refreshes every 20 minutes), the last outcome with its duration and message, whether it runs now and since when. Per step: subsystem, database, last outcome and duration. **A step's command is read for the job's definition and masked before it leaves the collector** ([jobs](jobs.md)): it can hold a password.

The job history (`msdb.dbo.sysjobhistory`) is read forward from a cursor on its `instance_id`, kept in the repository and advanced in the transaction that stores the rows. Each read starts 50 rows behind the cursor (a row can become visible after a newer one) and goes on, 5,000 rows at a time, until it has caught up or has read 100,000 rows; the next run reads on. A first read, and a read after a long stop, go back seven days by the run's start date and no further: a run that started more than seven days before it is first read is not stored.

The cursor carries a mark of the row it stands on. When that row is no longer in msdb, or is another row (msdb restored, or the server replaced under the same name: the numbering starts again), the read starts over from the kept window. A row is stored once either way: it is known by its number, job, step and msdb's own date and time.

msdb keeps dates and times as integers (`20261110`, `93005`) in the server's local clock. They are turned into datetimes on the server and moved to UTC by the offset the server has at the read: a row written before a daylight-saving change is one hour off (not proven here: the test servers keep UTC).

The Jobs tab: what runs now (with the average of the job's good runs beside it), the failed runs of the window with the step that failed and its message, every job, and the runs per job over the window.

**One judge of a job.** The fleet's Jobs page ('Job status'), the Summary's Agent Jobs cell and the instance's Thresholds dialog judge a job the same way (`pgvigil.job_status_view`, migration 0137), for SQL Agent, pg_cron and pgAgent alike. With no threshold set at any level the rule is DBA Dash's default: **critical** when the job's last run failed or a run failed in the last 60 minutes, **warning** when a run failed in the last 7 days. A job that failed at 08:00 and succeeded at 09:00 is a warning until a week later (before 0137 pgvigil called it ok). A threshold set at the root, the instance or the job replaces the default whole. A cancelled run is a failure, as in DBA Dash: a SQL Agent run or step cancelled (run_status 3) and a PostgreSQL run aborted count in the last failure and the 24 hour and 7 day counts, and a job whose last run was cancelled reads 'the last run was cancelled' (critical by default). A disabled job is not judged ('not judged', the job is disabled), as in DBA Dash. A job whose last run failed shows that failure however long ago it was; other failures and successes are looked for back as far as the longest threshold in force, 7 days at least. The instance's own job findings ('a job failed') still count a failed run only (run_status 0) inside `job_failed_hours`.

The last failure and the last success are looked for back as far as the longest 'since' threshold in force for the instances on the page, 7 days at least and 400 days at most: no threshold judges a run older than its own span. A job with none inside that span reads 'none in the last <n> days', never 'never'.

The fleet's Jobs page lists every job of the instances in view, DBA Dash's columns, the last run failed first, then the newest failure. Its filter starts on 'Critical, warning and acknowledged' when the view holds more than one instance, on All for one (DBA Dash's own reset). The succeeded counts and the longest and average run over 7 days come from a second read after the grid is drawn: if that read fails, those four cells say 'not read' and the grid stays. A job's name opens its last 7 days of runs under the grid; 'judged at' opens the thresholds dialog. PostgreSQL's schedule checks (failing 3 or more in a row, a missed schedule, a run over twice its average) stay below the grid. A server imported from DBA Dash carries its job runs, not its jobs: its jobs are not in the grid.

## Backups

Per database: state, recovery model, and the last full, differential and log backup (finish time, and from the server that took it the size, compressed size, duration, device and copy-only). The finish time is moved to UTC by the offset `backupset.time_zone` recorded with the backup.

- **A backup to the NUL device is no backup.** It never counts as the last backup of its type; it is kept apart and raises a finding.
- **An automatic seeding stream is no backup either.** When a database joins an availability group with automatic seeding, msdb records the stream to the new replica as a copy-only full backup to a virtual device named by a bare GUID. Such a row (full, copy-only, virtual device, a GUID for its device name, no backup name) is left out: it never counts as the last full backup. A copy-only snapshot (VSS) backup has the same device shape and is a backup: it counts. A backup tool that writes copy-only full backups that are not snapshot backups through a virtual device named by a bare GUID, without a backup name, would be left out the same way; none is known to.
- **msdb is each server's own record**, and only the server's own rows are read: a restore copies the source server's backup rows into msdb, and those are not this server's backups. A server renamed since shows no backup older than its rename, until the next one runs. A database in an availability group shows, per type, the newest backup that any *monitored* replica took, with the instance it ran on; that backup's size and device are on that instance's tab. A group with a replica that is not monitored is not alarmed on: the finding says the backup may run where pgvigil does not look.
- **A backup older than its database is not its backup.** msdb keys its history by name: a backup that finished before the database was created belonged to an earlier database of that name and is not counted. A restore also sets a new creation time, so a restored database shows no backup until its first one after the restore; the finding says "created or restored <time>; no full backup since", so nobody hunts for a lost history.
- **A backup once seen is kept** when msdb's history is trimmed, and the tab says how far back msdb's history reaches: "no backup in msdb" is not always "never backed up".
- **Not judged**: tempdb, a database that is not online, a database snapshot, a standby database, a database younger than `new_database_hours`, a name matching `backup_exclude`. The log backup is judged only under the full or bulk-logged recovery model, after a first full backup, and not for `model` or a read-only database.
- **Every age is the age at the read.** The collection is hourly; a page opened 50 minutes later does not add 50 minutes to a log backup's age.

**The fleet's Backups page** holds, below PostgreSQL's sections, DBA Dash's two root grids: one row per SQL Server instance in view (a server whose backups were never read has its row, saying so) and one row per database. The databases grid starts on Problems when the view holds more than one SQL Server instance (a backup late or never taken, or a backup to the NUL device inside `nul_backup_days`) and on All for one. An instance opens its Backups tab; a database opens that tab with its row first. Sizes and rates count only the backups that ran on the row's own server: a full backup taken on another replica of an availability group is counted on that replica's row. Backup thresholds are each instance's `mssql_thresholds` in `pgvigil.yaml`; the page's Configure says so and does nothing. Not read by pgvigil: backup checksums, encryption, password protection, the compression algorithm, damaged and partial or filegroup backups, the partner replica's backups, and a history of backups (pgvigil keeps the newest backup of each type per database).

## Findings

`mssql_hadr_findings`:

| finding | severity |
| --- | --- |
| a replica is not connected / a replica is not healthy | critical |
| a database is suspended / a database is not synchronizing | critical |
| the primary of a group changed (for an hour) | critical |
| the log send queue is over its threshold / the redo queue is over its threshold, in every read of 5 minutes | warning |
| a synchronous replica is not synchronized | warning |
| a secondary would lose data in a failover (`ag_data_loss`: 1 / 5 minutes) | warning / critical |
| a replica is not joined / a database is not joined | warning |
| a database is not ready for automatic failover (AUTOMATIC replicas only) | critical |
| the cluster has no normal quorum (WSFC only) | critical |
| a cluster member is down (WSFC only) | warning |
| the availability group endpoint is not started | critical |
| automatic seeding failed (in 24 hours) | warning |
| read-only routing names a replica that takes no reads | warning |
| the AlwaysOn_health session is not running | warning |
| mirroring is disconnected or suspended / mirroring is not synchronized | critical |
| mirroring is synchronizing / the mirroring witness is disconnected | warning |
| the mirroring send queue / redo queue is over its threshold, in every read of 5 minutes | warning |
| the principal of a mirrored database changed (for an hour) | critical |
| the mirroring endpoint is not started (on a partner) | critical |
| log shipping is behind its threshold (msdb's own threshold) | warning |
| log restores are behind (`logship_restore_age` / `logship_restore_latency`) | warning / critical |
| a database has been restoring for days (`restoring_days`; critical past its critical tier, or a log shipping copy past the 14 days read) | warning / critical |
| a log shipping copy is missing | warning |
| the failover cluster instance moved to another node (for an hour) | critical |
| a cluster node is not up / no spare cluster node | warning |
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

The newer rules take their numbers from the Thresholds page (root, a tag, an instance; the two log shipping keys also per database), each a default the user changes:

| key | unit | warning | critical | source |
| --- | --- | --- | --- | --- |
| `ag_data_loss` | minutes | 1 | 5 | sp_Blitz 20260708 check 268 (60 s); the critical tier is pgvigil's own default |
| `logship_restore_age` | minutes | 1440 | 2880 | DBA Dash 4.24.1 (time since the last restore) |
| `logship_restore_latency` | minutes | 1440 | 2880 | DBA Dash 4.24.1 (latency of the last restore) |
| `restoring_days` | days | 2 | - | sp_Blitz 20260708 check 111 |

Mirroring's queues use `log_send_queue_kb` and `redo_queue_kb` above (the availability groups' numbers, one setting for both features).

## One run by hand

```
pgvigil collect -config pgvigil.yaml -once mssql_ag -instance sales-sql01
```

## Proof

`scripts/proof-mssql-hadr.sh` runs against two SQL Server containers of one version (2017, 2019, 2022 and 2025 proven: [versions](sqlserver.md#versions)) that share a clusterless availability group, as a least-privilege login of its own on each node. Proven there: the group read from the primary and from the secondary with the roles right on each; a database the proof adds to the group, suspends on the secondary and resumes (the finding, the estimated data loss growing while suspended, the queue of the catch-up where a read catches it, the drain); a full backup on the primary and a log backup on the secondary merged by group, the seeding stream msdb records left out, the thresholds from the configuration, a backup to NUL, an excluded name; a job that fails at its second step found with the step's message, its next run and its history read once through the cursor; a running job; a login without a user in msdb skipped with the reason; every statement compiled and run by the server on both nodes.

`scripts/proof-mssql-dag.sh` forms a distributed group in a lab of its own (`scripts/dag/trial.sh`: four SQL Server 2022 containers, two clusterless groups and the distributed group over them) and reads all four nodes with pgvigil's collector as a login with VIEW SERVER STATE and VIEW ANY DEFINITION. Proven there: the distributed group stored once (one group id) with its two member groups on both primaries and not at all on the secondaries; the tree of the Availability tab the same for all four instances, in the API and in a headless browser; the link's queues and estimated data loss under a write load; a database suspended on the forwarder, the forwarder stopped and a secondary of the second group stopped, each with its findings on the instances named in the table above and gone after the undo; a planned failover to the second group by Microsoft's sequence for SQL Server 2022, kept as one event on each primary, with the tree redrawn around the new global primary; every container and network of the lab removed at the end. The lab runs `mcr.microsoft.com/mssql/server:2022-CU27-GDR2-ubuntu-22.04` (16.0.4315.2) unless `PGVIGIL_MSSQL_IMAGE` names another: on the 2022 CU28 container (16.0.4325.4) a secondary stopped answering logins seconds after its primary made a clusterless group, three times, in our lab - seen in containers only, not a claim about CU28 itself.

`scripts/proof-mssql-hadr.sh gaps` (part S) builds the same lab on the SQL Server 2022 CU27 image and proves the availability group checks above on it, each fault made, its finding read, then undone and the clear read: the join states, the group's settings, the endpoint, the AlwaysOn_health session (on the lab's nodes it exists but is stopped and does not start with the server: groups made by T-SQL on Linux leave it so; the warning is raised there, as sa's own read says), quorum as a clusterless Linux node reports it (NODE_MAJORITY, NORMAL_QUORUM: stored, not judged), joined and failover-ready, automatic seeding, the counter rates; a secondary held back (its data movement suspended, rows written on the primary) raising ONE data-loss finding, a warning at 15 s and critical at 45 s with the thresholds set lower for the run; a secondary's endpoint stopped (critical on it, 'a replica is not connected' on the primary); a database left on a replica (SET HADR OFF there) and a replica added and never joined, each one warning and nothing else for it; a read-only routing list naming a replica with no routing URL; a seeding that fails because the database exists on the secondary already, and its warning gone once the database leaves the group; each read's estimate compared with sa's own, and each tier raised only after two reads in a row reach it. A group's secondary database reads ONLINE, so log shipping's group exclusion cannot be shown there: it is proven over stub rows (part T).

`scripts/proof-mssql-hadr.sh stubs` (part T) feeds 0143's import functions stub payloads on a fresh repository for what no lab here reaches (a Windows cluster's quorum and members, a failover cluster instance, PENDING / UNSYNCHRONIZED mirroring, Amazon RDS, a mirror re-created, a mirror read by a login that is not sysadmin, a log shipping copy past the 14-day window, a tier set alone, a group database left RESTORING, a seeding seen from either side) and checks the findings against its expected list line for line. On an idle database the estimate jumps at the primary's next commit to the age of the secondary's last commit (it measures from there), so a secondary that stops while nothing is written shows its full exposure at once.

`scripts/proof-mssql-logshipping.sh` builds a real pair of SQL Server 2022 CU27 containers that share one Docker volume, the primary on a clock eight hours behind UTC: log shipping by hand and by SQL Server's own procedures (`sp_add_log_shipping_*`, its backup, copy and restore jobs, which run on Linux). Proven there: the restore history read as sa reads it, with the primary's backup start moved to UTC by `backupset.time_zone` (-32) and a latency of minutes, not eight hours; no finding for a new database; the age tiers (warning, then critical) and the latency tier alone, one finding each time; a database left restoring after a full restore (sp_Blitz 111) warned once and never judged as log shipping; msdb's own pair stored from both reads and judged once (msdb's warning, then the critical tier beside it); a copy dropped on the secondary found as missing; the primary not read as a secondary; every statement run as a least-privilege login.

`scripts/proof-mssql-mirroring.sh` reads the Windows lab of `scripts/lab/win-mirroring.ps1` (three named SQL Server 2022 instances on one host: principal, mirror, witness; the mirrored database with the witness in high-safety mode) from another machine through the lab's one firewall rule, as a monitoring login that is not sysadmin (VIEW SERVER STATE, VIEW ANY DEFINITION, msdb db_datareader). It proves: the principal's row as sa reads it and the mirror as that login reads it (role MIRROR from its counter instance, its values hidden); the send rate, redo rate and transaction delay under a write load; the witness lost (the warning, gone when it is back); a manual role swap (kept as an event on both sides and raised) and a witness failover (the principal's endpoint stopped: an isolated principal that still runs, not a crashed one; the event and its finding read on the new principal's side); suspended (critical) with the send queue over a 1 KB threshold in every read of five minutes (the warning); disconnected (critical, gone when the mirror is back); the mirror database stored as mirrored (the rule that leaves a mirrored database out of log shipping is proven over stub rows, part T); the pair handed back as the lab made it. Two statements changed after that run and are proven over stub rows only: the transaction delay per write (now from the raw counter differences) and the role sequence (only a rise is a swap). Not proven there: a network split between the partners (all three run on one host); PENDING_FAILOVER and UNSYNCHRONIZED (transient: their rule is proven over stub rows); the redo-queue tier held for five minutes on a real mirror (the mirror's redo queue and rate are read under load; the rule is the availability groups', proven over samples); an Amazon RDS instance (the gate is proven over stub rows).

Not proven by it: a distributed group over Windows clusters with listeners (the lab is clusterless: each side's listener URL is its primary's endpoint); a forced failover with data loss; a failover inside a member group while it is in a distributed group; a member group whose primary is not monitored, and a side that stops answering after a failover, on a live server (the tree for both, and the stale mark, are proven over stored rows); SQL Server 2016 to 2019 and 2025.

Not proven: the findings "a job runs far longer than its average", "no recent full backup" (only "no full backup ever"), "no recent differential backup", "a synchronous replica is not synchronized" and the two "a collection stores nothing" findings were never raised by a test; the three pages were never opened in a browser by `proof-mssql-hadr.sh` (it reads their API; `proof-mssql-dag.sh` draws the Availability tab's distributed-group tree in one); the report that a managed read replica names itself PRIMARY. Also not proven, each named by the proof: a contained group, a listener, a Windows cluster's members; a queue held over its threshold for five minutes on a live server (the two queue findings are proven over stored samples); a real distributor (its collection runs and finds none: its findings are proven over stubbed rows, and the replication statements over a stand-in database with tables of the documented shape); quorum, a cluster member down and failover readiness on a Windows cluster, the failover cluster instance (no Windows cluster in the labs), and dbachecks' checks of the cluster's own nodes, resources, networks and listener names (Windows only); PENDING_FAILOVER and UNSYNCHRONIZED on a real pair (transient: their rule is proven over stub rows); SQL Server 2016 (task 164), Amazon RDS (task 165), Azure SQL Managed Instance; on Windows only database mirroring was run (the mirroring lab), nothing else of this page (task 144).

## Sources

The mirroring states follow DBA Dash 4.24.1 (`DatabaseMirroringSummary_Get.sql`); log shipping from restore history follows its `SQLLogRestores.sql` and `LogShippingStatus.sql` (the two measures, the 1440 / 2880 defaults, the new-database exemption, mirrored databases left out); sp_Blitz 20260708 (MIT, Brent Ozar Unlimited) checks 111, 184 and 268 are named where their rules are taken; 'not joined' is a warning as dbatools 2.9.1 `Test-DbaAgPolicyState` rates it; the AlwaysOn_health and endpoint checks are dbachecks 3.0.2's HADR checks.

The running-jobs filter and the shape of the job history read follow DBA Dash 4.24.1 (`DBADash/SQL/SQLRunningJobs.sql`, `SQLJobHistory.sql`; MIT, Copyright 2022 Trimble, Inc.); "the newest backup per database and type, this server's own" follows its `SQLBackups.sql`. The statements are pgvigil's own, written from the documentation of the views and tables they read.
