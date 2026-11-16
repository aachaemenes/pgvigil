# SQL Server day-one checks

Three collections judge a SQL Server instance the way a DBA does on the first day with it: the server's options, its trace flags, its build, every database's options and state, the logs, the last good DBCC CHECKDB, damaged pages, SQL Server Agent's alerts and the identity columns near their limit. Every value is stored **with its verdict**, so the pages show each option a rule covers, met or not, coloured as DBA Dash colours its Configuration and DB Options grids:

- **green**: the value is at its default or meets its best practice;
- **yellow**: a warning or an advice rule is broken (a value that is only off its default is advice);
- **red**: a critical rule is broken;
- **grey (N/A)**: no rule covers the value, or the column is shown and not judged.

A coloured cell is never the only signal: its title names the rule and says why, and on an instance's page a column of words in the same row says it too (the fleet's option pivot has the title only). Each broken rule is also a finding, with the rule that raised it (the source tool and its check number) and the number that broke it.

| Collection | Interval | What it reads | Rights |
|---|---|---|---|
| `mssql_checks` | 1 hour | `sys.configurations`, the build, `sys.databases` with `DATABASEPROPERTYEX(..., 'LastGoodCheckDbTime')`, `DBCC SQLPERF(LOGSPACE)` and `sys.dm_db_log_info`, `msdb.dbo.suspect_pages`, `msdb.dbo.sysalerts`, `sysoperators`, `sysnotifications`, `sp_MSgetalertinfo` | public for the options, build, databases and CHECKDB; `VIEW SERVER STATE` for the logs and for weighing max server memory and MAXDOP against the machine; `db_datareader` in msdb for the alerts (the suspect pages are readable by the public role through msdb's guest user, read so on SQL Server 2022) |
| `mssql_identity` | 6 hours | `sys.identity_columns` in every user database the login can enter | `VIEW ANY DEFINITION` and access to the databases (`CONNECT ANY DATABASE`) |

The trace flags are judged by the same rules but read once, by `mssql_traceflags` (hourly, `DBCC TRACESTATUS(-1)`, any login; [jobs and configuration history](jobs.md)): its rows are the one store of the flags, and its read writes the checks' Trace flags cell and findings. An area the last run could not read keeps its rows and findings (the last known) and its cell says **not read now**, uncoloured. Nothing is written on the server. `mssql_checks` never enters a user database; `mssql_identity` runs one SELECT per database through that database's `sys.sp_executesql`. Both are written for SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; `scripts/proof-mssql-checks.sh` ([Proof](#proof)) passes on SQL Server 2017, 2019, 2022 and 2025 (the versions run, [SQL Server](sqlserver.md#versions)) and both collections stored `ok` on one SQL Server 2016 SP3 server ([SQL Server 2016](sqlserver-2016.md)); not yet on Azure SQL Database. An area the login may not read is stored as **not read** with the reason and keeps what an earlier read stored; the run is then partial.

## The areas

| Area | Rules (source) |
|---|---|
| Server options | every option against its default (sp_Blitz's defaults table); priority boost on: critical (sp_Blitz 126); max server memory at its default, above the machine or at 95 % of it: warning (dbachecks MaxMemory, sp_Blitz 50, sp_PerfCheck 1002); cost threshold at 5: warning, under 50: advice (sp_Blitz 188, sp_PerfCheck 1004); MAXDOP 0 over 8 CPUs or on several NUMA nodes: advice with dbatools' recommended value; min server memory equal to or within 10 % of max: advice; xp_cmdshell, Ole Automation, Ad Hoc Distributed Queries, cross db ownership chaining on, the default trace off, lightweight pooling on, a server-wide fill factor: warning; remote admin connections 0, backup compression and checksum default 0, optimize for ad hoc workloads 0, CLR on: advice |
| Trace flags | every flag on globally with what it does (sp_Blitz 74): 652, 661, 834, 1211, 1224, 1806, 2330, 3505, 3608, 3609, 8649 warning; 1117, 1118, 2371 redundant on 2016 and later, 4199, 7752, 8017, 8048, an unknown flag: advice; 3226 and 7745 off: advice (Glenn Berry) |
| Build | the build against the catalogue of builds (the SQL Server First Responder Kit's SqlServerVersions): updates behind (sp_Blitz 217; a warning when the newest is over a year newer, else advice; advice when the catalogue does not list the build, whose date is then unknown), extended support ended (warning), ending within 180 days (warning), mainstream support ended (advice). A build newer than the catalogue is not counted as behind; SQL Server 2016's Azure Feature Pack builds count only for a server on that branch; a managed service's build is not weighed |
| Database options | auto close, auto shrink: warning (sp_Blitz 12, 13); page verify NONE: critical, TORN_PAGE_DETECTION: warning (sp_Blitz 14); auto create / update statistics off: warning (sp_Blitz 15, 16); trustworthy on: warning; delayed durability: warning; an old compatibility level, asynchronous statistics, target recovery time not 60, an unknown owner, a collation other than the server's, and every option of sp_Blitz's database defaults table (RCSI, ADR, CDC, Service Broker, forced parameterization ...): advice. The system databases ship with some of these on (msdb's trustworthy and broker) and are not judged on them |
| Database state | SUSPECT, RECOVERY_PENDING, EMERGENCY: critical; OFFLINE, RECOVERING: warning (sp_Blitz 102); SINGLE_USER or RESTRICTED_USER: warning (sp_PerfCheck 7003) |
| Log space | log used 75 % and more: warning, 90 %: critical, with the log reuse wait; virtual log files 200 and more: advice, 512: warning, 1,000: warning (Glenn Berry Q36, dbachecks, sp_Blitz 69) |
| Last good CHECKDB | never: critical (a database under seven days old is not raised); past 7 days: warning; past 14 days: critical (dbachecks, sp_Blitz 68), each with half a day's grace so a weekly CHECKDB still running does not raise it. tempdb, read-only databases and snapshots are not judged |
| Suspect pages | an 823 / 824 error, a bad checksum or a torn page in `msdb.dbo.suspect_pages`: critical when under 30 days old, else warning (sp_Blitz 90); the table at 900 of its 1,000 rows: warning |
| Agent alerts | no enabled operator, no alert for severity 19 to 25, none for errors 823 / 824 / 825: warning (sp_Blitz 31, 61, 96); some severities missing, an alert disabled, one that notifies nobody, one without the error's text, no fail-safe operator: advice. An operator's e-mail address is not stored |
| Identity columns | a column at 75 % of its range: warning, 90 %: critical (the defaults: an instance's `mssql_thresholds` may set `identity_warn_pct` and `identity_crit_pct`, each from 10 to 100 with the warning under the critical, and a finding names the lines in force); columns under 10 % are not stored. The range runs from 0 to the type's largest value, or from the seed when it is negative (`IDENTITY(-2147483648, 1)`); a column that counts down is not weighed. The rate per day and the days left once two reads are an hour apart; a reseed starts the rate again. A login that can enter no user database leaves the area not read, with the reason |

## Configuration checks (task 409)

The instance configuration and database option checks dbachecks names, each judged against an expected value that a
site sets at the root, on a tag or on one instance (migration 0160; the Checks grid on an instance's Configuration
tab). Every rule has a row, met or not, with its value, the expected value, where the expectation is set (default,
root, `tag:<name>`, instance) and its source.

- A rule whose source is a site's policy (**dbachecks policy**) is **off** until a scope sets it - grey, 'set an
  expectation', no finding: a server option's expected value (dbachecks' Database Mail XPs and remote access are
  listed whether set or not, any other option once it is set), the recovery model (master, tempdb, model and msdb
  left out unless the list says otherwise; tempdb is never judged by it), the database-scoped MAXDOP, databases that are RESTORING, read-only or in
  standby (a mirror, an availability group secondary and a log shipping secondary are never counted), the databases
  expected to exist (critical when one is missing), Query Store on or off, the event sessions expected stopped,
  running, allowed to run and to exist, the trace flags expected and not expected, the error log files kept, the
  Agent's operators, its fail-safe operator and the logins that may or may not own a job (compared without case; an
  operator's name holding '@' is refused: no e-mail address is stored; a login's name may hold one), the TCP port, the
  enabled protocols (as SQL Server names them: Tcp, Np, Sm; on Linux a list without Tcp is info) and the Windows
  processor scheduling. A number has the range the server takes for it (MAXDOP 0 to 32767, 6 to 99 error log files,
  a TCP port, 0 to 63 for the processor scheduling); names on a list and the databases left out are compared without
  case.
- A rule from **Microsoft**'s guidance or a **dbatools formula** is **on** and a scope may set it off: the engine's
  and the Agent's start mode (Automatic on a standalone instance, Manual on a failover cluster instance),
  @@SERVERNAME against the server's own name ('a rename not finished'), max server memory against dbatools'
  Test-DbaMaxMemory for the machine, shared by the monitored instances on it (on Linux only 'under the machine's
  memory' is judged; Analysis, Reporting and Integration Services are not counted), MAXDOP against dbatools'
  Test-DbaMaxDop (from 1 up to the advised value is in order), and 'scan for startup procs' on with no startup
  procedure.
- **info** is shown amber and raises no finding (max server memory, MAXDOP, the error log files, the port, the
  protocols, the processor scheduling); **warning** and **critical** rows are findings (source
  `mssql_config_checks`). **not read** and **not applicable** are grey with the reason beside them and never green:
  the engine's start mode on Linux (sys.dm_server_services lists no engine service there), the startup procedures
  for a login without VIEW ANY DEFINITION, the Agent's fail-safe operator for a login that may not run
  `master.dbo.sp_MSgetalertinfo`, the error log count on a Linux server whose `errorlog.numerrorlogs` is not set (and on
  Windows where no value is read while the server keeps more files than the default of 6 archives), a database rule
  with a database it could not read (a database the login cannot enter, a recovery model or Query Store state the
  server gave none of), a RESTORING, read-only or standby database where the secondaries could not be told apart, the
  SQL Server Browser (pgvigil has no Windows host door yet), and on Amazon RDS, Azure SQL Managed Instance and Google
  Cloud SQL every rule about the host ('<service> runs the host').
- A server option that has an expected value in force is judged by that expectation alone: while it is set, the
  day-one check's own finding for the option is left out everywhere - the findings, the Checks page's areas and the
  Summary's cells, and the findings that page lists.
- Linked servers: the list (provider, data source, who is mapped at each - a local login or every login, with its own
  credential or a remote login; never a remote login's name or password). Their connection test is off until the
  instance carries the tag `pgvigil:linkedserver-test`: then `sys.sp_testlinkedserver` runs FROM the monitored
  server, as the collector's own login maps there, for two servers a run (30 s each at most), each in its turn. A
  failure is a warning with the error and since when, and stands until the server's next test; error 7416 is 'not
  tested: the collector's login has no mapping there' and 18456 'the login mapped for the collector's login was
  refused at the remote server', grey, never a failure of the link; a server of another provider than SQL Server's
  is left out. A refused login's error text (it names the remote login) is never kept, and a login, user or
  principal named in any other error is cut out. A login that may not see every linked server (it needs ALTER ANY
  LINKED SERVER, ALTER ANY LOGIN, VIEW ANY DEFINITION, setupadmin or sysadmin once a server's default login mapping
  is dropped) gets a short list: the list says so, a server it does not show is kept, and no linked server visible
  reads 'not read', never 'no linked server'. The test follows the tag in the instance's configuration, the one the
  collector reads.
- The expected values are set in the page's editor (the same seat as the threshold writes: a signed-in admin on a
  server with the actions door's audit login); a change ends the live row and writes its successor, so who set what
  and when stays. `pgvigil.mssql_config_expect_in_force(instance)` gives the value in force per kind and key with
  where it was set.
- Not proven: a live Windows server, a managed service, SQL Server 2016 (those rows are proven on rows written into
  the repository, `scripts/proof-mssql-config-checks.sh`); 'a rename not finished' live (SQL Server on Linux
  registers the host's name again at its start); a linked server of another provider (SQL Server on Linux refuses to
  make one; the provider filter is a Go test's); the fail-safe operator read live; the editor's write with a
  signed-in user. The TCP port, the protocols and the processor scheduling read 'not read' until the properties
  collection stores them. An Azure SQL Database instance has no configuration checks (one database is the instance).

API: `GET /api/mssql/config_checks?instance=N`, `GET /api/mssql/config_expect?instance=N` and
`POST /api/mssql/config_expect`.

## Maintenance (task 410)

Ola Hallengren's maintenance solution, judged as dbachecks judges it (migration 0161; the Jobs group's Maintenance
tab). Every rule has a row, met or not.

- **Installed**: the solution is found by its objects in schema dbo (CommandExecute, DatabaseBackup,
  DatabaseIntegrityCheck, IndexOptimize, CommandLog) in any database the login can enter; the version is each
  procedure's own line. A part of it in a database is a warning naming what is missing. A login without VIEW
  DEFINITION in a database sees none of its procedures: that database reads 'not read', never 'not installed' (nor a
  part of it: SELECT on dbo.CommandLog shows that table alone). No solution in any database read is one info row, 'not
  installed' (another tool may do the maintenance), never a warning: it is info for the databases read and names the
  ones the login cannot enter ('not looked into: model (no access), ...') - a database a login can never enter does
  not hold the row at 'not read'.
- **Jobs**: each job the solution makes on the instance's platform (eleven on Windows, ten on Linux - no 'Output File
  Cleanup' -, six on Azure SQL Managed Instance, three on Amazon RDS) is matched by what its step calls (the
  procedure with its @Databases and @BackupType in any order, a list with exclusions such as 'USER_DATABASES, -BigDb'
  taken as its first word - 'ALL_DATABASES' is matched by the job's name only -, the CommandLog clean-up, the two msdb
  history procedures; those two only where the solution may be), else by the solution's description and its name,
  else by its name; a renamed job is still matched. The tab's Jobs grid lists the same match, each job with its role
  and the clean-up age its steps name. Each must be enabled and
  have an enabled schedule (warning each: the solution makes its jobs without schedules). Its clean-up age: a backup
  job's @CleanupTime at least 192 hours (absent or NULL: the files are never removed, met; @MirrorCleanupTime is not
  it), the CommandLog clean-up, the two history clean-ups and Output File Cleanup (Windows) at least 30 days - under
  it info, a step whose age the
  parser does not know 'age not read', never met. A job the solution makes that is not there is info 'not present';
  an expected value of kind job (keys expected and not_expected, on the Configuration tab's Checks) makes it a
  warning, or 'off'.
- **History**: the solution's CommandLog (only where CommandExecute is in the same database: an application's own
  dbo.CommandLog is not read) is read forward from one past the highest ID read, batch by batch until its end, at
  most 50,000 rows a database a run or the run's deadline - a read that stays behind says how far (info, 'N rows
  behind'); the rows still running at a read (no EndTime) are read again at the next, from the lowest of them, until
  they end (after 7 days 'never closed', info, and no longer read again); a table emptied or truncated starts again
  without losing the rows read. A command is masked whole, then cut at 4,000 characters; a backup's kind (full,
  differential, log) is read from its whole command on the server - native, LiteSpeed, Red Gate SQL Backup, SQL Safe,
  Data Domain Boost. Times are converted from the server's own clock to UTC by the offset in force at the read: a
  row read again after a daylight saving step moves by its hour, and the first read of a database (its last 7 days)
  takes every older row at the new offset. A command that failed in the last day is a warning naming the database,
  the object, the command type and the error number (CommandLog keeps no message for some failures - a backup's 3013
  - and the job's history has it); 1205, 1222 and 5245 are info once a job of the command's own role has run and
  succeeded since (an index or statistics command: IndexOptimize's job; a DBCC: an integrity check's; a backup: a
  backup's), else a warning. Without SELECT on dbo.CommandLog the history reads 'not read'; a CommandLog the last read
  did not reach reads 'not read' too. purge() deletes the rows past the retention. Not caught: a table truncated and
  refilled past the old cursor between two reads (its new rows under the cursor are not read).
- **Data purity** (dbachecks Database#11): DBCC DBINFO WITH TABLERESULTS inside every database the login can enter,
  as its own user there, once a day per database (the flag changes only after a CHECKDB WITH DATA_PURITY; a read
  between keeps the day's): off only for a database made before SQL Server 2005 (dbi_createVersion under 611) whose
  dbi_dbccFlags are 0 - a warning. By version, for a monitor login that is not sysadmin: SQL Server 2022 answers it;
  SQL Server 2017 and 2019 refuse it (error 2571, 'does not have permission to run DBCC DBINFO'), so each database
  reads 'not read' with that error there, never a verdict. A database the login cannot enter reads 'not read: no
  access'; a secondary replica of an availability group 'not read: a secondary replica (read on the primary)'.
- Not proven: SQL Server 2016 (Windows-only, rides task 164's Windows host); Windows (eleven jobs, 'Output File
  Cleanup' and its age: written rows); Managed Instance and RDS (the expected lists on written rows); a server across a
  daylight saving step; an availability group's secondary replica; a read cut by the run's deadline.

API: `GET /api/mssql/maintenance?instance=N` (checks, parts, databases, jobs, last, commandlog over from / to, runs).

## Pages

- **Checks** (an instance's Configuration folder): a summary of the areas, each cell a link to its view; the server options worst first; the database grid (one row per database, one column per option, the deviating cells coloured); the trace flags; the build and the suspect pages; the alerts and operators; the identity columns with each database's scan state; every finding.
- **SQL Server options** (the fleet's Configuration folder): per instance the count of databases with each risky option (page verify, auto close, auto shrink, statistics off, old compatibility level, trustworthy, no indirect checkpoints, delayed durability, not online, not multi user, VLF count), each count a link to those databases; under it every server option across the fleet, one column per instance, coloured by its verdict on that instance.

API: `GET /api/mssql/checks?instance=N` and `GET /api/mssql/checks/fleet`, each with `part=` for one part.

## The script that creates the alerts

pgvigil creates no alert. Where the alerts area finds one missing, the Checks page's Agent alerts view shows **The script that creates them** with Copy, and `pgvigil mssql-agent-alerts -print` prints the same script; `-print -drop` prints its undo. pgvigil prints both and never runs either: the server's DBA reads the script and runs it as a sysadmin.

```
pgvigil mssql-agent-alerts -print [-operator <name> [-email <address>]] [-ag] [-delay <seconds>]
pgvigil mssql-agent-alerts -print -drop
```

- **What it makes:** one alert per severity 19 to 25 and per error 823, 824 and 825, named `(pgvigil) Severity 19` ... `(pgvigil) Error 825`, each enabled, sending the error's text by e-mail and starting no job. With `-ag` (the page always includes it) also one alert per Availability Group message SQLMonitor alerts on (1480, 976, 983, 3402, 19406, 35206, 35250, 35264, 35273-35276, 41091, 41131, 41142, 41406, 41414), made only where Availability Groups are on when the script runs. **These are not proven to fire**: `sys.messages`' `is_event_logged` does not say whether the engine writes a message to the log, and no pgvigil proof has made them fire yet. Severities 17 and 18 and errors 15457 and 5084, which SQLMonitor also alerts on, are left out: no pgvigil rule asks for them.
- **The delay between two responses** of one alert is 900 seconds, a CONFIG line at the top of the script that is used when an alert is created. Two published scripts disagree: Glenn Berry's *Configuring Alerts for High Severity Problems* uses 900, and the script the First Responder Kit's sp_Blitz links for missing alerts (brentozar.com/go/alert) uses 60. pgvigil takes the larger, so a storm of one error (an 823 can be raised many times a second) sends one mail per 15 minutes. A later run tells you where an existing pgvigil alert's delay differs from the CONFIG line, and changes nothing.
- **What it leaves alone:** a condition already covered by an alert of any name on msdb's own key for it (the message id, the severity, no database and no keyword) gets no second alert; the script names that alert and says why it may not serve (disabled, notifies nobody, no error text). An alert limited to one database or a keyword does not cover the condition, and the script says it is there. A `(pgvigil) ...` name held by an alert on another condition gets no second alert, and the script says that its name makes it pgvigil's: the notification step e-mails the operator from it and the drop script drops it (rename it to keep it apart). It changes no server or Agent setting, never enables an alert a DBA disabled, and never changes an operator.
- **The operator:** with `-operator`, each pgvigil alert e-mails it; an operator of that name is reused as it is, and is created only with `-email` when none exists. The address goes into the printed text only, never pgvigil's store. Notifications are added in a step of their own over every `(pgvigil) ...` alert, so naming the operator in a later run connects the alerts an earlier run made. The page's script names an operator the last read found enabled and with an address, or carries an example in its `@operator` line.
- **Checks when it runs:** a message id missing from this version's `sys.messages` is skipped with words; every `sp_add_alert`, `sp_add_operator` and `sp_add_notification` is caught with its return code, so a refusal is never reported as created; where msdb kept the row but could not tell the Agent (error 14258 while the Agent starts) it says 'created (the Agent was not told: ...)'. It ends with read-only notes (Database Mail off, no mail profile, the Agent without a mail profile or with its mail profile not enabled, the Agent not running) and lists every alert on these conditions.
- **Where it stops** (its first batch, with words, before anything else): SQL Server Express (no Agent); Azure SQL Database and Azure SQL Edge (not a platform this script supports; on Azure SQL Database a compile error about msdb may follow the stop line, and nothing runs); Azure SQL Managed Instance (`sp_add_alert` raises error 41914 there); Amazon RDS (alerts and operators are not supported); **SQL Server on Linux** (Microsoft lists Agent alerts among the features SQL Server on Linux does not support); a login that is not a member of sysadmin (`sp_add_alert` needs it, error 15003), which also covers Cloud SQL for SQL Server, where Google gives no login that role and lists Database Mail as unsupported. On those platforms the page says "not applicable" and shows no script.
- **Undo:** `-print -drop` drops every `(pgvigil) ...` alert, with its notifications, and nothing else. The operator stays: it may be older than pgvigil.

## Proof

`scripts/proof-mssql-checks.sh` starts its own SQL Server container and seeds each state, then undoes it: a database with AUTO_CLOSE on and PAGE_VERIFY NONE, cross db ownership chaining on, the cost threshold at 50 and back at 5, trace flag 1211, master never checked and then checked, a full log and a log of many virtual log files, a suspect page, the Agent with and without alerts and an operator, a tinyint identity at 78 % and 94 %, and a login with the public role only. Each finding is raised and cleared, each cell turns yellow or red and back to green. `scripts/proof-mssql-agent-alerts.sh` (NOT RUN YET: the rows below are its expected result, stated as proven only after its box run) runs the printed script on a SQL Server 2022 container, where it should stop on Linux; then, on the proof's own copy with the Linux stop line removed: two runs, the second changing nothing in msdb; a site's own alerts on severity 20 and error 823 left alone; an existing operator reused unchanged; an operator named in a later run getting every pgvigil alert; pgvigil's own read storing the pgvigil alerts enabled and notifying; the drop script removing them all; and a severity 19 error raised WITH LOG measured (Microsoft says no alert fires on Linux). Windows firing is a separate row on the lab's Windows VM, on a named instance: NOT RUN YET. Not proven: SQL Server 2016 (task 164) to 2019 and 2025, Windows (task 144), Amazon RDS (task 165), Azure SQL Managed Instance, a build behind the catalogue on a live server, a real damaged page, a database SUSPECT or RECOVERY_PENDING, the fail-safe operator set, the page in a browser.
