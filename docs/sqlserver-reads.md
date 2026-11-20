# SQL Server: properties, procedures, index locks

Three collections of the [SQL Server engine](sqlserver.md) and the tabs they feed, and two additions to pages that were already there (the fleet's Running queries and an instance's Waits). Nothing is installed on the monitored server and nothing is written there.

| collection | every | what | the login needs |
|---|---|---|---|
| `mssql_properties` | 1 hour | what the instance is: server, processors, memory, tempdb's layout, host; every change of a value | public for the server and tempdb rows and max / min server memory (on Amazon RDS the two RDS rows need EXECUTE on two msdb procedures, optional: [SQL Server in the cloud](sqlserver-cloud.md)); `VIEW SERVER STATE` for the processor rows, the machine's memory and the memory model; the host rows are public's before SQL Server 2022 and need `VIEW SERVER PERFORMANCE STATE` from it (partial where a row cannot be read) |
| `mssql_procstats` | 5 min | what each stored procedure did between two reads | `VIEW SERVER STATE` (2022: `VIEW SERVER PERFORMANCE STATE` should be enough; not proven); names of another database's procedures: `CONNECT ANY DATABASE` and `VIEW ANY DEFINITION` |
| `mssql_indexlocks` | 5 min | where sessions waited for locks, per index, and lock escalations | as `mssql_procstats`; names: a database the login can enter |

None of the three runs on Azure SQL Database; there the Properties page shows the tier's rows of `mssql_azuredb_governance` ([cloud](sqlserver-cloud.md#resource-use-and-the-tier)).

To name procedures and indexes in every database, the monitoring login takes one more grant than [the base login](sqlserver.md#the-login):

```sql
GRANT CONNECT ANY DATABASE TO [pgvigil_monitor];   -- SQL Server 2014 and later; pgvigil reads no table, and the login holds in each database what public holds there
```

Without it the counters are still stored, under the object's id.

## Properties (`mssql_properties`)

One row per property, in seven groups (DBA Dash's Info page, and the network and the default backup path beside it):

- **Server**: edition, version and level, collation, clustered, Always On enabled, the machine's and the server's name, max degree of parallelism, cost threshold for parallelism (`SERVERPROPERTY`, `sys.configurations`); on Amazon RDS also its high availability mode and its last failover (`msdb.dbo.rds_get_high_availability_option`, `msdb.dbo.rds_failover_time`).
- **Processor**: logical CPUs, sockets, cores per socket, the hyperthread ratio, NUMA nodes, soft NUMA, the affinity type, max worker threads, the hypervisor (`sys.dm_os_sys_info`); the schedulers online and offline (`sys.dm_os_schedulers`: an offline scheduler is a CPU the edition's core limit, the licence or an affinity mask keeps SQL Server from using); the power plan; Win32PrioritySeparation (`win32_priority_separation`: the machine's processor scheduling, the raw registry value; the checks judge it).
- **Memory**: the machine's memory, max and min server memory, max server memory as a per cent of the machine (`no limit` while the setting is at its default; a note when it is more than the machine has), the memory model.
- **TempDB**: data files, their size, whether they are one size, log files, log size (`tempdb.sys.database_files`).
- **Host**: platform, distribution, release (`sys.dm_os_host_info`; before SQL Server 2017 `sys.dm_os_windows_info`).
- **Network**: the TCP port (`tcp_port`: the ports the instance listens on - IPAll's static port, or its dynamic one; with ListenOnAllIPs off, the enabled IPn entries', each named in the note), whether it is dynamic (`tcp_port_dynamic`), listen on all IP addresses (`tcp_listen_all_ips`), force encryption (`force_encryption`), force strict encryption (`force_strict_encryption`, SQL Server 2022 and later), the protocols enabled (`protocols_enabled`: of Shared Memory, Named Pipes and TCP/IP). These keys are fixed: the configuration checks judge the stored rows by them.
- **Backups**: the default backup path (`default_backup_path`: `SERVERPROPERTY('InstanceDefaultBackupPath')` from SQL Server 2019, the registry's `BackupDirectory` through `xp_instance_regread` on 2017 once the right is checked; not read on 2016 and earlier and on Azure SQL Managed Instance, Amazon RDS and Cloud SQL, where the service keeps the backups), a change of it logged as any property's; beside it on the tab, whether the SQL Server service account sees it as a directory - `mssql_backup_checks`' hourly read, [backups-sqlserver.md](backups-sqlserver.md), not a stored property; until that read has checked the path now stored, the row says 'not read yet: the path changed since mssql_backup_checks last read it (hourly)'.

A property the server did not give says **not read** and why: the login lacks the right, the server's version does not have the column (`socket_count`, `cores_per_socket` and `numa_node_count` came with SQL Server 2016 SP2 and 2017; the collector asks the server which columns it has), or the platform has no such thing.

**The power plan** is the one value SQL Server does not hold. On a Windows server someone runs, the collector reads the active power scheme from the registry with `xp_regread` (a read): first the plan a Group Policy enforces (`HKLM\SOFTWARE\Policies\Microsoft\Power\PowerSettings`), which the machine's own key does not follow, then the machine's own (`HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes`). It names the plan; one other than High performance or Ultimate Performance carries a note. On Linux, Amazon RDS and Azure SQL Managed Instance the row says not read. A login that may not execute `xp_regread` gets `no right: EXECUTE on master.dbo.xp_regread - in master, CREATE USER [login] FOR LOGIN [login] when it has none, then GRANT EXECUTE ON dbo.xp_regread TO [login]` (a GRANT on an object names the login's user in master), and the procedure is not called.

**The network and Win32PrioritySeparation** are registry values. On Windows the collector reads SQL Server's own network configuration from `sys.dm_server_registry` (VIEW SERVER STATE; VIEW SERVER PERFORMANCE STATE from SQL Server 2022), the IPn entries with it; where the view is refused it reads the same values but the IPn entries with `xp_instance_regread`. Where the view lacks ForceEncryption (seen on SQL Server 2022 on Windows: no row of the SuperSocketNetLib key itself), the two encryption values are read with `xp_instance_regread` too. Force strict encryption is the value `ForceStrict` (Microsoft's name for it, SQL Server 2022 and later); where the view lacks it, it is asked of `xp_instance_regread` too, and where that answered for the key (ForceEncryption was read) with no `ForceStrict`, the row says `not set: the key holds no ForceStrict value`: its cell says not set and the page does not count it as not read. The row reports the read: no Microsoft page gives the setting's default (the strict-encryption page, read 2026-11-15, names the value and its versions only), so none is claimed. Before SQL Server 2022 the row says `not on this version`. A NUL at the end of a string value the view gives is dropped before the value is read: on the same server sqlcmd printed the view's TcpPort and TcpDynamicPorts values cut short, as a terminating NUL cuts them (not read byte by byte). Win32PrioritySeparation, a key of the machine's, is read with `xp_regread`. On Linux the view is empty and `xp_instance_regread` answers from SQL Server on Linux's own registry, which follows mssql-conf (`network.tcpport`, `network.forceencryption`); the protocols are TCP only (`met: Linux serves TCP only`), and ListenOnAllIPs and Win32PrioritySeparation say not on Linux. On Amazon RDS, Azure SQL Managed Instance and Google Cloud SQL the rows say not applicable: the service runs the host. Both procedures (and the power plan's `xp_regread`) are called only after `HAS_PERMS_BY_NAME` says the login may execute them: a login without the right is never refused every hour, and its rows say how the right is given (`no right: EXECUTE on master.dbo.xp_instance_regread - in master, CREATE USER ... then GRANT EXECUTE ON dbo.xp_instance_regread TO [login]`); on Linux the protocols and ListenOnAllIPs need no registry read and keep their words. The TCP port row lists every port the instance listens on: a static port and a dynamic one together when TcpDynamicPorts is set (it is blank only while dynamic ports are off), and none, with the reason, while TCP/IP is disabled.

**The change history.** The first value of a property sets it (also when earlier reads could not read it). From then on a value that differs from the read before is logged with the old value, the new one and the time of the read that saw it (the change happened within the hour before). Three values are shown without being logged: tempdb's two sizes, which move by themselves, and the per cent, which is derived (the change of max server memory is logged once, on its own row); on Amazon RDS a fourth, the last failover, which leaves the error logs as they roll over. The server's start time is not a property: the DMV writes it in the local clock, and a daylight-saving shift would log a change that never happened.

## Procedures (`mssql_procstats`)

`sys.dm_exec_procedure_stats` has one row per cached plan and counts since the plan entered the cache. pgvigil keeps the last counters per plan and stores what one interval added: executions, CPU, duration, logical and physical reads, logical writes, summed per procedure. The page (DBA Dash's Object Execution) shows them over the range as totals, per execution, and per second or minute of the time the range's reads cover, with the busiest single read's executions per minute; a database filter; the instance's totals over time; and, on a procedure's name, that procedure read by read.

What a figure is, and is not:

- It is what ran **between two reads**. The first read of an instance only sets the starting counters.
- A plan the read before did not hold (a new procedure, a recompile, anything after a restart of the server) gives its whole count: all of it ran after the read before. A plan whose counters went down counts whole as well. No interval is ever negative.
- A procedure compiled, run and dropped from the plan cache between two reads is in no read. The executions of a plan the cache dropped since the read before are lost with it. On a server under memory pressure the page undercounts.
- Stored procedures only. Triggers and functions have their own views and are not collected. The resource database's own procedures (database id 32767) are left out: the server names almost none of them.
- The list is cut at the 5,000 plans with the most CPU; the run is `partial` when it is. For the one read after a cut read, a plan new to the list is counted whole only when it was cached after the cut read, by the server's own clock; a plan that was merely past the cut sets its counters and gives nothing. In the hour the clocks go back that one comparison can miss a new plan's first interval or count a cut plan whole. A read that was not cut needs no clock.

The names come from `OBJECT_NAME`, which waits behind a schema change on the object. The collector's session gives up on a lock after two seconds; the read then runs again without the names and the page shows `object <id>` for that interval.

## Index locks (`mssql_indexlocks`)

`sys.dm_db_index_operational_stats` counts per rowset of an index partition since the index's metadata entered the cache. pgvigil reads the rowsets with a lock wait or an escalation attempt, keeps the last counters, and stores what one interval added per index: row lock waits and their milliseconds, page lock waits and theirs, lock escalation attempts and escalations (Darling's Locking & Contention page).

> These are waits that **ended** on an index: where sessions collided. They name no holder. The root cause of a blocking chain is the head's transaction and its last statement, which the [Running queries and Blocked reports](sqlserver-running.md) pages show; an index with many lock waits is a collision path, not a verdict.

- An escalation is the server trading an index's row and page locks for one lock on the whole table. The engine checks as a statement's locks on the index grow, each check counted as an attempt, and escalates once the statement holds more than about 5,000. Attempts without an escalation are a statement that ended before that point (an UPDATE of 6,000 rows gets three attempts and no escalation on SQL Server 2022; one of 20,000 rows is escalated) or a conflicting lock held by another session.
- **One call per database.** The function waits behind a schema change (an offline index rebuild, an `ALTER TABLE` or a partition switch held in a transaction) on any object it lists, so it is called database by database. A database whose call fails is skipped for that read, the run is `partial`, and the database's next read takes the difference from the last read that reached it: nothing is lost and nothing is counted twice. Its lock waits show one read late.
- The rule for the differences is the procedures' rule: the first read sets; an index new to the list, or one whose counters went down (the metadata left the cache and came back), gives its whole count; nothing is negative. The state is kept per rowset, so a columnstore index whose delta store is compressed away does not look like a counter that went down.
- The names (schema, table, index, type) are read from each database's own catalog, for the 500 objects per database with the most lock wait. A database the login cannot enter leaves `object <id>` and `index <id>` on the page.
- The list is cut at the 20,000 rowsets with the most lock wait. After a cut read, a rowset new to the list sets its counters and gives nothing, so a cut never invents a wait.
- Not collected: the page latch and page IO latch counters of the same view (a latch is not a lock; the Waits tab has `PAGELATCH` and `PAGEIOLATCH`), the engine's own catalog tables (object ids 1 to 100: nothing a DBA can index or change), and memory-optimized tables, which the view does not list.

## Running queries at the root: memory grants and tempdb waits

A SQL Server row of the fleet's Running queries page carries, from the instance's newest snapshot (DBA Dash's Running Queries at the root):

- **max memory grant** and **sum of memory grants**: of the requests that hold a grant at the snapshot.
- **tempdb latch waits** and their time: the requests waiting at the snapshot for a page latch on a tempdb page (`PAGELATCH_*` on `2:<file>:<page>`; never `PAGEIOLATCH_*`, which is the disk).
- **tempdb allocation waits** and their time: those of them on an allocation page (PFS: page 1 and every 8,088th; GAM: page 2 and every 511,232nd; SGAM: page 3 and every 511,232nd after it). This is the contention more tempdb data files relieve.

They are waits in progress at one moment, not totals: the instance's Waits tab has what ended. A request's row carries its coordinator's wait, so a parallel request whose workers wait for a tempdb page shows `CXPACKET` or `CXCONSUMER` and is not counted. DBA Dash's third pair, waits on the pages of tempdb's system tables (metadata contention), is not shown: the snapshot does not store which object a page belongs to. A PostgreSQL row leaves these cells empty.

## Waits: a description and the rate per core

The Waits tab's grid gains three columns (DBA Dash's Waits):

- **wait time (ms/sec)**: a wait type's time over the seconds the range's reads cover. 1,000 means one task waiting the whole time.
- **wait time (ms/sec/core)**: that, divided by the schedulers that ran user work (`VISIBLE ONLINE`) as the newest CPU read at or before the range's end counted them. Empty where `mssql_cpu` has not run.
- **description**: what the wait means, for about fifty types a DBA meets most; a wait of idle background work says so; any other type without its own text takes its family's (`LCK_M_`, `PAGEIOLATCH_`, `PAGELATCH_`, `LATCH_`, `PREEMPTIVE_`, `HADR_`, `CX`). The texts are pgvigil's own wording.

## Retention

The interval rows (`mssql_proc_sample`, `mssql_proc_read`, `mssql_indexlock_sample`, `mssql_indexlock_read`) are monthly partitions dropped by `purge` with the rest; a property change older than the window is deleted; the properties themselves are one row each and stay.

## Proof

`scripts/proof-mssql-reads.sh` starts its own SQL Server 2022 container (or takes a sandbox), and checks, as a login with `VIEW SERVER STATE`, `VIEW ANY DEFINITION` and `CONNECT ANY DATABASE`, a login with `VIEW SERVER STATE` alone and a login with neither:

- every property against `sa`'s own read of its source; a second read of the unchanged server logs nothing; on the proof's own container, max server memory set once shows as exactly one change;
- a procedure run 7 times between two reads stored with 7 executions and `sa`'s own rise of CPU, duration and reads; a procedure created between two reads stored with its whole count; after `sp_recompile`, the new plan's count and nothing negative;
- a row lock wait forced on a table (a session holds a row, another waits for it) stored on its clustered index with `sa`'s own rise of waits and milliseconds; one UPDATE of 20,000 rows stored as `sa`'s rise of escalation attempts and escalations, with an escalation;
- the fleet row's grants and tempdb waits on stored rows, and a real memory grant held by a sorting session against `sa`'s read of the grants view;
- the rate per second and per core of the forced lock wait against a division done by hand;
- on imported rows: a restart with lower and with higher counters (the whole count, never a negative one), an idle read, a recompile, a cut list, a skipped database, a columnstore rowset that goes, late reads, the property history, the tempdb page arithmetic, the purge function;
- every statement of the four API handlers on those imported rows;
- the migration chain applied on PostgreSQL 13;
- with `PGVIGIL_SHOTS`, the five pages in a headless browser in both themes.

Result, 2026-11-11: every part passed, against SQL Server 2022 (16.0.4315.2, Developer edition) in the proof's own Linux container, with the repository on PostgreSQL 18.6 and the migration chain also applied on PostgreSQL 13. Among the figures of that run: 35 properties, 33 of them equal to `sa`'s reads; the forced lock wait stored as 1 wait of 5,472 ms and the UPDATE of 20,000 rows as 4 escalation attempts and 1 escalation, both equal to `sa`'s rise; a sorting session's grant of 92,328 KB equal to the grants view. The accessibility check (`scripts/proof-a11y.sh`) found 0 violations over 300 page renders with the three new tabs in both themes.

Not proven: a real power plan (it needs a Windows SQL Server: task 144), a real tempdb page latch wait, SQL Server 2016 (the older `sys.dm_os_sys_info`: task 164; 2017, 2019, 2022 and 2025 are proven: [versions](sqlserver.md#versions)), Amazon RDS (task 165), Azure SQL Managed Instance, a list long enough to be cut and a database skipped on a real server, a columnstore rowset with lock waits.
