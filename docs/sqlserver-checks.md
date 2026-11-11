# SQL Server day-one checks

Two collections judge a SQL Server instance the way a DBA does on the first day with it: the server's options, its trace flags, its build, every database's options and state, the logs, the last good DBCC CHECKDB, damaged pages, SQL Server Agent's alerts and the identity columns near their limit. Every value is stored **with its verdict**, so the pages show each option a rule covers, met or not, coloured as DBA Dash colours its Configuration and DB Options grids:

- **green**: the value is at its default or meets its best practice;
- **yellow**: a warning or an advice rule is broken (a value that is only off its default is advice);
- **red**: a critical rule is broken;
- **uncoloured**: no rule covers the value, or the column is shown and not judged.

A coloured cell is never the only signal: its title names the rule and says why, and on an instance's page a column of words in the same row says it too (the fleet's option pivot has the title only). Each broken rule is also a finding, with the rule that raised it (the source tool and its check number) and the number that broke it.

| Collection | Interval | What it reads | Rights |
|---|---|---|---|
| `mssql_checks` | 1 hour | `sys.configurations`, `DBCC TRACESTATUS(-1)`, the build, `sys.databases` with `DATABASEPROPERTYEX(..., 'LastGoodCheckDbTime')`, `DBCC SQLPERF(LOGSPACE)` and `sys.dm_db_log_info`, `msdb.dbo.suspect_pages`, `msdb.dbo.sysalerts`, `sysoperators`, `sysnotifications`, `sp_MSgetalertinfo` | public for the options, flags, build, databases and CHECKDB; `VIEW SERVER STATE` for the logs and for weighing max server memory and MAXDOP against the machine; `db_datareader` in msdb for the alerts (the suspect pages are readable by the public role through msdb's guest user, read so on SQL Server 2022) |
| `mssql_identity` | 6 hours | `sys.identity_columns` in every user database the login can enter | `VIEW ANY DEFINITION` and access to the databases (`CONNECT ANY DATABASE`) |

An area the last run could not read keeps its rows and findings (the last known) and its cell says **not read now**, uncoloured. Nothing is written on the server. `mssql_checks` never enters a user database; `mssql_identity` runs one SELECT per database through that database's `sys.sp_executesql`. Both run on SQL Server 2016 SP1 and later, Amazon RDS and Azure SQL Managed Instance; not yet on Azure SQL Database. An area the login may not read is stored as **not read** with the reason and keeps what an earlier read stored; the run is then partial.

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
| Identity columns | a column at 75 % of its range: warning, 90 %: critical; columns under 10 % are not stored. The range runs from 0 to the type's largest value, or from the seed when it is negative (`IDENTITY(-2147483648, 1)`); a column that counts down is not weighed. The rate per day and the days left once two reads are an hour apart; a reseed starts the rate again. A login that can enter no user database leaves the area not read, with the reason |

## Pages

- **Checks** (an instance's Configuration folder): a summary of the areas, each cell a link to its view; the server options worst first; the database grid (one row per database, one column per option, the deviating cells coloured); the trace flags; the build and the suspect pages; the alerts and operators; the identity columns with each database's scan state; every finding.
- **SQL Server options** (the fleet's Configuration folder): per instance the count of databases with each risky option (page verify, auto close, auto shrink, statistics off, old compatibility level, trustworthy, no indirect checkpoints, delayed durability, not online, not multi user, VLF count), each count a link to those databases; under it every server option across the fleet, one column per instance, coloured by its verdict on that instance.

API: `GET /api/mssql/checks?instance=N` and `GET /api/mssql/checks/fleet`, each with `part=` for one part.

## Proof

`scripts/proof-mssql-checks.sh` starts its own SQL Server container and seeds each state, then undoes it: a database with AUTO_CLOSE on and PAGE_VERIFY NONE, xp_cmdshell on, the cost threshold at 50 and back at 5, trace flag 1211, master never checked and then checked, a full log and a log of many virtual log files, a suspect page, the Agent with and without alerts and an operator, a tinyint identity at 78 % and 94 %, and a login with the public role only. Each finding is raised and cleared, each cell turns yellow or red and back to green.
