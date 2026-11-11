# SQL Server 2016

pgvigil is built for SQL Server 2016 SP1 and later (major version 13): where a view or a column arrived later, the
collector asks the version or the server's own column list first. It is proven on SQL Server 2016 SP3 only. SQL
Server 2016 runs on Windows only: Microsoft ships no Linux image of it, so the 2016 proof runs against a Windows
server, not against the containers the other versions are proven on (`scripts/proof-mssql-versions.sh`: SQL Server
2017, 2019, 2022 and 2025).

Proven on SQL Server 2016 SP3 (13.0.7050.2, SP3 CU1 GDR), Developer edition, on Windows Server 2019 Datacenter, one
server, by `scripts/proof-mssql-2016.sh` (below). The collector needed no change for 2016. Five of the SQL Server
proofs did (actions, perf, reads, querystore, xe): their own setup and comparisons used things SQL Server 2017
introduced (`STRING_AGG`, `sys.dm_os_host_info`, Query Store's wait statistics) or read an event file by its Linux
path. Each now takes a form 2016 has (FOR XML PATH, `sys.dm_os_windows_info` before 2017, the server's own log
folder, the wait statistics only from 2017); on 2017 and later they compare the same values as before, and the five
changed proofs pass on SQL Server 2017 containers too.

## What collects on 2016

Every SQL Server collection runs on 2016 without a statement the server does not have: all 21 (`mssql_ag`,
`backups`, `cpu`, `fileio`, `indexlocks`, `instance`, `jobs`, `logshipping`, `memory`, `mirroring`, `procstats`,
`properties`, `querystore`, `replication`, `requests`, `services`, `storage`, `tempdb`, `versionstore`, `waits`,
`xe`) ran once as `sa` and stored `ok`, except `mssql_ag`, which stored `skipped: Always On is not enabled on this
server` (the server is not in a Windows cluster). The collector connects over TLS and stores the server as version
130000.

What the proofs compared on this server against `sa`'s own reads, and found equal or within each proof's stated
bound (a rate against the counter's rise, the plan cache within 5 %, file IO counters at or below a later read, a
volume's free bytes within 2 %, a slow batch's duration within 250 ms):

- the instance and its configuration;
- SQL Server Agent, Database Mail and memory dumps;
- running queries and blocking, with sp_WhoIsActive installed too;
- the Extended Events captures: deadlocks, blocked process reports, slow batches (read from the event files in the
  instance's Log folder, across rollovers), attentions;
- the database files and the volume they sit on (drive `C:\`: total and free bytes);
- CPU (the idle per cent is compared on Windows; on Linux it is not stored), memory, file IO and tempdb;
- the server's properties (33 values against `sa`'s reads; on 2016 the host's platform is Windows by rule on both
  sides and its release is read from `sys.dm_os_windows_info` on both);
- Query Store: the stores' options and the top list per statement (executions, duration, CPU, reads, the largest
  memory grant). On 2016 the server keeps no wait statistics: the collector stores a wait time of 0 and there is
  nothing on the server to compare it with (see below);
- the actions through the separate actions login: a session's preview and kill, an Agent job started and stopped,
  the refusals and the audit rows.

Where 2016 lacks something the collector reads on later versions, the collector asks first, by the version or by
the server's column list, or drops what an older version cannot give; it never fails on it:

| What | On 2016 | Why |
| --- | --- | --- |
| The host (`mssql_properties`: platform, distribution, release) | platform Windows and the release from `sys.dm_os_windows_info`; no distribution | `sys.dm_os_host_info` arrived in SQL Server 2017; before it the engine runs on Windows only |
| Query Store wait statistics (`mssql_querystore`) | the wait mode is not stored; every plan's wait time is stored as 0 | `sys.query_store_wait_stats` and `wait_stats_capture_mode_desc` arrived in 2017 |
| Query Store plan forcing type and automatic tuning | not read | `plan_forcing_type` and `sys.dm_db_tuning_recommendations` arrived in 2017 |
| An availability group's `cluster_type` and `required_synchronized_secondaries_to_commit` | NULL by the version guard (the statement compiles on this server; without a group it is not run) | the columns arrived in 2017 |
| tempdb's memory-optimized metadata | no value (n/a) | `SERVERPROPERTY('IsTempDBMetadataMemoryOptimized')` answers from 2019; the collector reads it and stores no value before 2019 |
| `sys.dm_os_sys_info` socket and core counts, `sys.dm_tran_version_store_space_usage` | read | they arrived in 2016 SP2 (the collector asks the column list and the build); this server is SP3 |

## What does not, and why

- **Availability groups on 2016 need a Windows Server Failover Cluster.** The clusterless group (`CLUSTER_TYPE =
  NONE`) the other versions are proven with arrived in SQL Server 2017, so a single 2016 server has Always On off
  and `mssql_ag` skips with that reason. The group's statements are still compiled by the 2016 server (`SET NOEXEC
  ON`, the live test `TestHADRStatementsLive`). Mirroring, log shipping, jobs, backups (the form without groups) and
  the replication distributors read also run; the replication publications, subscriptions and agents are compiled
  only (the server has no distribution database).
- **The Windows power plan, as a least-privilege login**: not read on this server (`xp_regread() returned error 5,
  'Access is denied.'`); the property says so in its note. Seen on 2016; not checked on a Windows host of another
  version.
- **Query Store's wait time** reads 0 on 2016, where the server keeps no wait statistics at all: a 0 there means
  "not measured", not "no waits".

## Not proven

- An availability group on SQL Server 2016 (a Windows cluster's group, two nodes): the availability proof
  (`proof-mssql-hadr.sh`) is not run on one node, and the Extended Events proof's AlwaysOn_health part is skipped.
- A second 2016 server: the proofs that compare a pair ran against one.
- SQL Server 2016 before SP3 (SP1 and SP2), and editions other than Developer (Express, Standard, Enterprise).
- Windows authentication for the collector's login; a Windows login as the actions login; a session id reused
  between the actions' check and the KILL.
- A server whose clock is not UTC (this VM runs in UTC); a real power plan read; a real tempdb page latch wait; a
  server setting really changed (the properties' history is proven on imported rows); a list cut and a database
  skipped on a real server; a columnstore rowset with lock waits.
- A login holding only VIEW SERVER PERFORMANCE STATE; a real memory grant wait; a ring buffer after a real restart.
- A Query Store in the ERROR state or really cleared, the bounds of one run, the access path of the interval floor.
- Thousands of databases, a FILESTREAM container, a live ring buffer overrun of an Extended Events capture.
- That a collector session never waits behind a writer (no collection of the base reads a user table); the many
  sessions load test (`TestRequestsManySessionsLive`, skipped); the pages in a browser and their accessibility.

The proofs print their own "not proven here" lines, written for the container sandbox; some still name "SQL Server
2016-2019" and "Windows" (volumes, event file paths). On this server those proofs ran and passed.

## The proof

`scripts/proof-mssql-2016.sh` runs on a Linux machine (docker, psql, curl, jq, python3, ss, timeout, od, flock, a Go
toolchain and a PostgreSQL superuser connection) against one SQL Server 2016 server reached over the network:

- **P**: the server answers; its major version is 13, its edition Developer, SQL Server Agent runs; whether Always On
  is enabled is recorded (on 2016 it needs a Windows cluster).
- **C**: the collector connects over TLS (`encrypt=true`; the certificate accepted without validation,
  `TrustServerCertificate=true`) and stores the server as `sqlserver`, version 130000. A control read with
  `GODEBUG=x509negativeserial=0` records whether the server's certificate has a negative serial number (go.mod's
  `godebug x509negativeserial=1` lets the collector connect to such a server; this one's was not negative).
- **H**: the server is made to look like one in use: Database Mail on and started, sixty rows of Agent job history
  (both put back at the end).
- **K**: every SQL Server collection of the collector (21) runs once as `sa`; none may fail on a column, a view or a
  function the server does not have, or on any other server error.
- **T**: the live tests of `internal/mssql` run against the server (`TestHADRStatementsLive` compiles every
  availability group, mirroring, log shipping and replication statement under `SET NOEXEC ON`).
- **R**: the SQL Server proofs of `proof-mssql-versions.sh` run against the server. They reach their server's `sa`
  side through `docker exec <container> sqlcmd -S localhost`; the wrapper puts a `docker` of its own first on their
  PATH that sends those calls to a sqlcmd in a tools container on the proof machine (Microsoft's SQL Server image,
  only its sqlcmd) with `-S` pointed at the server; a `bash -c` line that runs sqlcmd gets the same `-S`, and the
  removal of a proof's temporary file under /tmp happens in the tools container. Two calls have no network form and
  are translated: a file a proof copies into its container goes into the tools container, and the deletion of a
  proof's own event files under the Linux log folder deletes them in the server's Log folder through `xp_cmdshell`,
  which is switched on for that one call when it is off and switched off again in the same batch (a server setting
  changed for a moment). Any other call into the container fails the proof that made it.
- **S**: `proof-mssql-summary.sh` once.

The proof that needs an availability group of two replicas (`proof-mssql-hadr.sh`) is not run on a server where
Always On is not enabled, and says `NOT PROVEN: one node`; any other failure fails the run.

### Running it

The server: `scripts/lab/azure-mssql2016-vm.sh up` makes one Windows VM in an Azure resource group you own, from
Microsoft's SQL Server 2016 SP3 Developer image (`MicrosoftSQLServer:sql2016sp3-ws2019:sqldev`: no SQL Server
licence is billed for Developer; the Windows licence is in the VM's hourly price), opens TCP 1433 to ONE address
(the proof machine's), enables SQL authentication and `sa` with a password made at run time (kept in
`.lab/pgv16-sa.pw`, mode 600), and prints the endpoint. `stop` deallocates the VM between runs and `start` starts it
again; `door` admits a new address when the proof machine's changes; `status` lists what it made; `down` deletes
everything it made and reads the listing back.

```sh
export PGVIGIL_AZ_GROUP=<your resource group> PGVIGIL_AZ_LOCATION=<its region> PGVIGIL_LAB_ALLOW=<the proof machine's public IPv4>
scripts/lab/azure-mssql2016-vm.sh up
# on the proof machine, with .lab/ copied to the repository root (mode 600 kept):
PGVIGIL_ADMIN_DSN="host=127.0.0.1 user=postgres" PGVIGIL_2016_WHOISACTIVE=<a local copy of sp_WhoIsActive.sql> \
  scripts/proof-mssql-2016.sh
scripts/lab/azure-mssql2016-vm.sh down
```

Without `PGVIGIL_2016_WHOISACTIVE` the running-queries proof passes with its sp_WhoIsActive part not proven.

The default size is the smallest the image runs on, a 2 vCPU, 4 GB VM (`PGVIGIL_AZ_SIZE`, default
`Standard_B2als_v2`; not run here: the subscription had no quota for that family). The run recorded on this page
used `Standard_E2bs_v5`.
