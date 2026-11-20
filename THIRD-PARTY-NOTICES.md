# Third-party notices

pgvigil is an independent project. It is not affiliated with or endorsed by Trimble, Inc.

## DBA Dash

pgvigil's collection catalog, schedule defaults, repository layout and documentation structure were informed by DBA Dash (https://github.com/trimble-oss/dba-dash). Where a file, schema or text is copied or adapted from that project, this notice applies:

Copyright 2022 Trimble, Inc.

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## uPlot

The web UI bundles uPlot (https://github.com/leeoniya/uPlot) for its charts, in `internal/web/dist/app.js` and `internal/web/dist/uplot.css`.

The MIT License (MIT)

Copyright (c) 2022 Leon Sorokin

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## pgMonitor

pgvigil's pg_hba.conf change detection (a checksum of the rules between two reads) follows the idea of pgMonitor's monitor.pg_hba_checksum (https://github.com/CrunchyData/pgmonitor). No code is copied. pgMonitor is licensed under the Apache License 2.0; Copyright (c) 2017-2025 Crunchy Data Solutions, Inc. and Copyright (c) 2025-2026 Snowflake, Inc.

The `standby lag` rule's byte tiers - the defaults of the threshold key `standby_lag_bytes`, warning 50 MB and critical 100 MB (internal/repo/sql/0141_hadr_pg.sql; a megabyte there is 1,048,576 bytes) - are the thresholds of pgMonitor 5.3.0's alert rule `PGReplicationByteLag` (prometheus/common/alert-rules.d/crunchy-alert-rules-pg.yml.example at the tag v5.3.0: `ccp_replication_lag_size_bytes` over 5.24288e+07 and over 1.048576e+08, each for 60 s). The two numbers are ported as data; the rule is pgvigil's own (per link, the smaller of two reads in a row of the bytes not yet replayed - the sending server's replay position, or its flush position on a standby that delays apply on purpose, else the standby's own received less replayed). That tag's LICENSE file reads: Copyright (c) 2017-2025 Crunchy Data Solutions, Inc. All Rights Reserved; licensed under the Apache License, Version 2.0.

## pev2 and the plan viewer's bundle

The Plan page draws a plan with pev2 (https://github.com/dalibo/pev2), bundled into `internal/web/dist/pev2/pev2.js` by `web/package.json`'s `build:pev2` and loaded only when a plan is opened, inside a shadow root so its styles never reach the rest of the UI. It is used as published; no code of it is changed.

- pev2 1.25.0 - PostgreSQL License - Copyright (c) 2019, Dalibo. pev2's own build bundles, and so ships with it: d3 7.9.2 (ISC, Copyright 2010-2026 Mike Bostock); d3-flextree 2.1.2 (WTFPL); lodash 4.18.1 (MIT); motion 12.43.0 (MIT); splitpanes 4.1.2 (MIT); vue-tippy 6.8.0 (MIT); @vueuse/core 14.4.0 (MIT); highlight.js 11.12.0 (BSD-3-Clause, Copyright (c) 2006, Ivan Sagalaev); vue-clipboard3 2.0.0 (MIT); humanize-duration 3.35.1 (Unlicense); @fortawesome/vue-fontawesome 3.3.3 (MIT); @fortawesome/fontawesome-svg-core 6.7.2 (MIT); @fortawesome/free-solid-svg-icons 6.7.2 and free-regular-svg-icons 7.3.1 (icons CC BY 4.0, code MIT; Copyright (c) 2024 Fonticons, Inc.).
- vue 3.5.44 - MIT - Copyright (c) 2018-present, Yuxi (Evan) You - `internal/web/dist/pev2/vue.js` and its chunk.
- bootstrap 5.3.8 (CSS only) - MIT - Copyright (c) 2011-2025 The Bootstrap Authors - `internal/web/dist/pev2/bootstrap.min.css`, inside the viewer's shadow root only.
- @fortawesome/fontawesome-svg-core 6.7.2 styles.css - MIT - `internal/web/dist/pev2/fontawesome.css`.

For a review: the bundle makes no request beyond its own three stylesheets and two modules; its strings hold links (pev2's issues page, the PostgreSQL documentation) that run only when clicked; no eval and no new Function, so it fits the content security policy as is; d3-flextree's WTFPL and humanize-duration's Unlicense are unusual licences a legal review may ask about.

## postgres_dba

The redundant and invalid index reads of the indexes collection (`internal/collect/indexes.go`) and the lock tree of the Waits tab (`lock_tree()` in migration 0030, after sql/l2_lock_trees.sql) are taken from postgres_dba (https://github.com/NikolayS/postgres_dba): sql/i2_redundant_indexes.sql, sql/i4_invalid_indexes.sql and the DO / UNDO pattern of sql/i5_indexes_migration.sql, with the changes listed in the file's header. Used under its licence (the same text stands in the file's header):

BSD 3-Clause License

Copyright (c) 2017, Nikolay Samokhvalov
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
* Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## pganalyze collector

The server log line classes of `internal/logparse/classes_pganalyze.go` (the message prefixes and, where a prefix alone is ambiguous, the regexps of fourteen classes: connection limit, connection lost, timeouts, cancellations, autovacuum cancelled, vacuum skipped, wraparound, frequent checkpoints, a crash, out of memory, archiving failed, standby conflicts, serialization failures, temporary files) are taken from the pganalyze collector's logs/analyze.go (https://github.com/pganalyze/collector); the file's header lists what was taken and what was not. Used under its licence (the same text stands in the file's header):

Copyright (c) 2016, pganalyze Team <team@pganalyze.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.
* Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

## The Windows app's bundle

`pgvigil-app.exe` (the `app/` module, shipped in `pgvigil-app_<tag>_windows_amd64.zip`) links three modules and embeds one Microsoft file; their full licence texts are in the module cache under the paths named.

- go-webview2 (https://github.com/jchv/go-webview2), in pgvigil-app.exe: MIT License, Copyright (c) 2020 John Chadwick, some portions Copyright (c) 2017 Serge Zaitsev (`go-webview2@v0.0.0-20260205173254-56598839c808/LICENSE`).
- go-winloader (https://github.com/jchv/go-winloader), in pgvigil-app.exe: ISC License, Copyright (c) 2021, John Chadwick (`go-winloader@v0.0.0-20250406163304-c1995be93bd1/LICENSE.md`).
- golang.org/x/sys v0.49.0, in pgvigil-app.exe (and in pgvigil itself, listed with every module in docs/notices.md): BSD 3-Clause License, Copyright 2009 The Go Authors (`golang.org/x/sys@v0.49.0/LICENSE`).
- WebView2Loader.dll from the Microsoft Edge WebView2 SDK, embedded in pgvigil-app.exe through go-webview2: BSD 3-Clause License, Copyright (C) Microsoft Corporation (`go-webview2@.../webviewloader/sdk/LICENSE.txt`).

## The SQL Server collections

Each piece below is named in a comment beside it in the file. Where only a shape or an idea was followed, the statement is pgvigil's own; where a list was ported, it is ported as data. DBA Dash's notice is the one at the top of this file.

| What | From | Licence | Where |
|---|---|---|---|
| The running-queries snapshot's shape (sessions with a request or an open transaction, the oldest transaction per session, tempdb pages per request, the top three session waits) | DBA Dash 4.24.1, DBADash/SQL/SQLRunningQueries.sql | MIT, Copyright 2022 Trimble, Inc. | internal/mssql/requests.go (requestsTemplate) |
| The running-jobs filter and the job history read's shape (past a cursor on instance_id, the in-progress status left out) | DBA Dash 4.24.1, DBADash/SQL/SQLRunningJobs.sql and SQLJobHistory.sql | MIT, Copyright 2022 Trimble, Inc. | internal/mssql/jobs.go |
| The idea of the newest backup per database and type from this server's own msdb.dbo.backupset (the statement is pgvigil's own) | DBA Dash 4.24.1, DBADash/SQL/SQLBackups.sql | MIT, Copyright 2022 Trimble, Inc. | internal/mssql/backups.go |
| The three reads behind the Agent, Database Mail and memory dump cells and the Agent's session name (the statements are pgvigil's own) | DBA Dash 4.24.1, DBADash/SQL/SQLServerExtraProperties.sql | MIT, Copyright 2022 Trimble, Inc. | internal/mssql/services.go |
| The shape of the Extended Events sessions (a dedicated deadlock session, the slow session's events, actions and duration predicate, an event_file read from a cursor, the Managed Instance and Azure SQL Database forms); the session text is pgvigil's own | DBA Dash 4.24.1, DBADash/SQL/SQLDeadlockSession.sql, SQLSlowQueriesEventFileSession.sql, SQLSlowQueries.sql, SQLDeadlockSessionAzure.sql | MIT, Copyright 2022 Trimble, Inc. | internal/mssql/xe.go |
| One session per capture, the blocked-process and attention sessions on a ring buffer with an event_counter beside attention, the five-second dispatch latency | PerformanceMonitor at commit 65bdb5f, DarlingXeSessions.cs and AlwaysOnXeSessions.cs | MIT, Erik Darling, Darling Data, LLC | internal/mssql/xe.go |
| The wait types of idle background work (the rows marked Ignorable in its wait category table), as data | SQL Server First Responder Kit 8.34, sp_BlitzFirst.sql | MIT, Copyright (c) 2022 Brent Ozar Unlimited | internal/mssql/waits.go (benignWaits) |
| The wait list grouped by what it points at, as data | DarlingData 6.11, sp_PressureDetector.sql | MIT, Copyright (c) 2021 Darling Data, LLC | internal/mssql/waits.go (waitCategories) |
| The default of every sys.configurations option (the #ConfigurationDefaults table) and sp_Blitz's CheckIDs, as data; the database options its #DatabaseDefaults table holds off, as rules; the notes on global trace flags (CheckID 74), in this project's words | SQL Server First Responder Kit 8.34, sp_Blitz.sql | MIT, Copyright (c) 2022 Brent Ozar Unlimited; portions of sp_Blitz Copyright Microsoft (tigertoolbox, MIT) | internal/mssql/checks.go (configDefaultList, traceFlagNotes), internal/mssql/dboptions.go (databaseRules) |
| The catalogue of SQL Server builds 2016-2025 with their release and support end dates and each build's page (its [Url]), as data | SQL Server First Responder Kit 8.34, SqlServerVersions.sql (the script by Josh Darnell, SqlServerVersionScript, MIT) | MIT, Copyright (c) 2022 Brent Ozar Unlimited; Copyright for SqlServerVersionScript held by Josh Darnell | internal/mssql/checks.go (buildCatalogue, BuildDocs) |
| The waits per core per minute figure (its formula and its 180 flag) and the 27 wait types its per-core list leaves out beyond sp_BlitzFirst's Ignorable ones, as data | SQLMonitor (github.com/imajaydwivedi/SQLMonitor) at de87d37: DDLs/SCH-usp_waits_per_core_per_minute.sql, DDLs/SCH-Create-All-Objects.sql (BlitzFirst_WaitStats_Categories) | MIT, Copyright (c) 2022 Ajay Dwivedi | internal/repo/sql/0152_mssql_counters.sql (mssql_wait_percore_ignored, mssql_wait_core_points, mssql_wait_core_summary), internal/repo/sql/0153_mssql_counter_checks.sql (the seed) |
| The SQL Server plan-warning rules' thresholds and words (the cost, runtime and plan checks of the plan cache's warnings: implicit conversions, lookups, missing indexes, UDFs, multi-statement TVFs and function joins, table variables, cursors, nearly parallel plans, forced serialization, spools, sorts, remote queries, spills, row goals, estimates, adaptive joins, Switch operators, scans, forced indexes, columnstore row mode, index operations, DDL, CPU, writes, stale statistics, trace flags, compile time and timeouts, non-SARGable predicates, parameterization, plan and operator warnings, busy loops) and sp_Blitz's plan checks 63, 65, 67 and 118, read and written anew in Go (no SQL of theirs is used) | SQL Server First Responder Kit 8.34, sp_BlitzCache.sql and sp_Blitz.sql | MIT, Copyright (c) 2022 Brent Ozar Unlimited (portions of sp_Blitz Microsoft's, tigertoolbox, MIT) | internal/plans/mssqlwarn.go |
| The error log's match list and noise list (the search strings of its @custom_message_only = 0 run less 'Microsoft SQL Server' and 'Server name is', and the line patterns it deletes after the search), as data | DarlingData (darlingdata-20261101), sp_LogHunter.sql | MIT, Copyright (c) 2021 Darling Data, LLC | internal/mssql/errorlog.go (errorLogMatches, errorLogNoise*) |
| The waiting-tasks read (its query and WHERE: sessions 50 and up, not the collector's own, a wait type, not PerformanceMonitor's own database; the collector's own session dropped as a blocker) and the ignored-wait list (IgnoredWaitDefaults.All, 126 types), as data; THREADPOOL waiters counted with no filter as sp_PressureDetector reads them | PerformanceMonitor 3.12.0, PerformanceMonitor.Collectors/WaitingTasksCollector.cs and IgnoredWaitDefaults.cs; DarlingData (darlingdata-20261101), sp_PressureDetector.sql | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC | internal/mssql/darling_waiting.go (waitingSQL, pmIgnoredWaits, threadpoolSQL), internal/repo/sql/0108_darling_waiting_tasks.sql |
| The blocking findings' rules and words (an implicit transaction blocking, sessions in implicit transactions, a lead blocker's share of the blocked wait at 10 %), the wait findings' thresholds and words (wait share, signal wait ratio, SOS_SCHEDULER_YIELD, tempdb page latch, forced grants, poison waits, range locks, CMEMTHREAD on NUMA), and the blocked-process reports' checks 1-10, 1000 and 1001 with the lead walk, ported from the procedures' text | DarlingData (darlingdata-20261101): sp_HumanEventsBlockViewer 5.11 (checks 1-10, 1000, 1001), sp_PerfCheck 2.11 (6001, 6101, 6102, 2010, 4101), sp_HealthParser 3.11 (system_health's blockingTasks); SQL Server First Responder Kit 8.34: sp_BlitzFirst (30, 37), sp_Blitz (117, 121, 162, 215) | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC; MIT, Copyright (c) Brent Ozar Unlimited | internal/repo/sql/0114_darling_blocking.sql, 0115_darling_waits.sql, 0116_darling_blocking_history.sql, internal/mssql/xe_shred.go (blockingTasks) |
| The four system_health events read beside the component results (the memory broker, memory node out-of-memory, the scheduler monitor, wait_info), its significant-wait filter (500 ms) and ignorable wait list, and the System Events page's Corruption and Contention Events charts (each the largest value per bucket) and the scheduler monitor's warnings (SQL Server's CPU 90 %, other processes 50 %, memory utilization 50), ported from the procedure's text and PerformanceMonitor's page | DarlingData (darlingdata-20261101): sp_HealthParser 3.11; PerformanceMonitor 3.12.0 (its System Events page) | MIT, Copyright (c) 2021 Darling Data, LLC; MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC | internal/mssql/readers_sysevents.go, internal/repo/sql/0120_darling_sysevents.sql, internal/web/q_mssql_errorlog.go (sqlMSSQLHealthSeries, sqlMSSQLHealthSpinlocks, sqlMSSQLHealthScheduler, sqlMSSQLHealthWaits), web/src/mssql_errorlog.ts |
| The memory reads and their shapes (the grants with their queries, the semaphores, the grant cap and reduced grants, the largest clerks and caches, stolen memory, the resource monitor's low-memory records, the plan cache by cache and object type with its bloat level) and the memory findings' rules (sp_Blitz 145 / 146, sp_BlitzFirst 45 / 46, grant timeouts), ported from the procedures' text and PerformanceMonitor's collectors | DarlingData (darlingdata-20261101): sp_PressureDetector (its memory section); PerformanceMonitor 3.12.0: MemoryGrantsCollector, MemoryPressureEventsCollector, PlanCacheStatsCollector and the Memory tab's columns; SQL Server First Responder Kit 8.34: sp_BlitzFirst (45, 46), sp_Blitz (145, 146) | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC; MIT, Copyright (c) Brent Ozar Unlimited | internal/mssql/memory.go, internal/repo/sql/0119_darling_memory.sql, web/src/mssql_perf.ts |
| The anchor lines around each ported block and the items of each ported list (48 ports, 1,135 items: the text pgvigil's code follows, kept to tell when a kit changed it), and the kits' result shapes and parameter names (column and parameter names, types, no code), as data | SQL Server First Responder Kit 8.34; DarlingData (darlingdata-20261101); PerformanceMonitor 3.12.0 (commit 65bdb5f946f7); sp_WhoIsActive v2200.20260409 (its result shape and parameter names alone) | MIT, Copyright (c) 2022 Brent Ozar Unlimited; MIT, Copyright (c) 2021 Darling Data, LLC; MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC; sp_WhoIsActive GPL-3.0 (no line of its code is copied) | internal/community/kits/ports.json, internal/community/kits/shapes.json |
| The performance counter list and its storage per series (a cumulative counter as its rate and its total), the CPU details, the thread row with its runnable line and THREADPOOL waits, the scheduler pressure line beside pgvigil's own level, the sessions by application, host and database with their totals, tempdb space per session, SLEEP_TASK kept at an average of 1,000 ms or more, the remote admin connections line, and the findings on other processes holding the CPU, a long open transaction and slow data file writes | DarlingData (darlingdata-20261101): sp_PressureDetector (its perfmon list, CPU and thread usage sections, tempdb per session); PerformanceMonitor 3.12.0: PerfmonStatsCollector, CpuSchedulerStatsCollector, SessionStatsCollector, SessionSummaryStatsCollector, ClassifyCpuSchedulerPressure, the perfmon panel's and the Activity tab's columns | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC | internal/mssql/cpu.go, internal/mssql/activity.go, internal/mssql/waits.go (sleepTaskSpills), internal/mssql/checks.go, internal/repo/sql/0124_darling_cpu.sql, web/src/mssql_perf.ts, web/src/metrics.ts |
| PerformanceMonitor's alert defaults as findings (dead tuples, slot WAL, a volume under 5 / 2 GB free, runnable queue 8 / 16 per scheduler, long-running requests at 30 min with its exclusions as data, Server Unreachable on any failed connect; its replay lag tiers of 30 s / 5 min are the defaults of the threshold keys standby_replay_lag and logical_sender_lag, the 'standby lag' and 'replay lag' rules) and the Admin page's five tabs | PerformanceMonitor 3.12.0: CustomAlertTemplates.cs, DarlingConfig.cs, RunnableQueueEvaluator.cs, DarlingAlertReadAdapter.cs, LongRunningQueryExclusions.cs, ConnectionAlertPolicy.cs | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC | internal/repo/sql/0118_darling_alerts.sql, internal/repo/sql/0141_hadr_pg.sql (standby_replay_lag, logical_sender_lag), web/src/alerts.ts (builtIn, adminView) |
| The Client Timeouts rate (the reads back to 3 minutes, the attentions over the span, at least a minute; its floors 10 and 60 a minute) and its left-out events (the SSMS IntelliSense prefix and suffix, the five VS Code mssql metadata names, the 1 ms floor with a missing duration counted (pgvigil applies it only to an event that came with no statement), Azure Data Studio's two metadata statement shapes), as data | PerformanceMonitor 3.13.0: AttentionEvaluator.cs, AttentionWindowSql.cs | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC | internal/repo/sql/0153_mssql_counter_checks.sql (mssql_attention_left_out, mssql_attention_points, the seed) |
| The Query Store regression tests (cost: Regular CPU per run more than 25 % above the baseline's adding at least 1,000 ms over the window; timeouts / errors: at least 3 Aborted / Exception runs at twice the baseline's per-hour rate, or any where the baseline had none), the 7-day baseline, a row placed by its last run, the severity bands, the order and the 200-row cap with the failures' third; the compare picks (Previous period, Yesterday, Last week) and their column labels; the plan cache's hashes and handles and the procedures' spilled pages | PerformanceMonitor 3.12.0: QueryStoreRegressionRules.cs, PerformanceMonitor.Darling.Storage/QueryStoreRegressionBaseline.cs, top-compare.js, server-tabs.js, DarlingDataReader.cs, DarlingMcpDataTools.cs | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC | internal/web/q_mssql_querystore.go (qsRegBase, sqlMSSQLQSRegressed, sqlMSSQLQSCompare), internal/web/q_mssql_plancache.go (sqlMSSQLPCCompare), internal/web/q_mssql_procs.go (sqlMSSQLProcCompare, sqlMSSQLProcs), internal/web/q_mssql_plancache.go (sqlMSSQLPCTop), web/src/mssql_querystore.ts, web/src/mssql_plancache.ts, web/src/mssql_procs.ts |
| The Queries view's section order, the query heatmap (its bins aiming at 144 columns, seven log10 buckets per metric, eight log-scale shades, its legend, cell words and 'Show as table', 'Show Active Queries at This Time' at the bin's middle, the 7-day reach), the time strips over Active queries and the Query Store grid with a row's overlay, the wait filter's words, the per-query trend and the procedure history's four metrics, the Query Store overhead's sleep waits and its memory clerk line | PerformanceMonitor 3.12.0: server-tabs.js, query-heatmap.js, query-heatmap-model.js, time-slicer.js, stats-history.js, charts.js, DarlingQueryHeatmapReader.cs, DarlingMcpQueryHeatmapTools.cs, DarlingMcpTrendTools.cs, ViewerDataService.QueryStoreClutter.cs | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC | internal/web/q_mssql_plancache.go, web/src/mssql_queries.ts, web/src/mssql_querystore.ts, web/src/timestrip.ts, and the wiring's mssql_running.ts, mssql_procs.ts |

The MIT licence of each of these sources, with its copyright line above:

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## The demo's stored samples of the community tools

On a demo instance (`pgvigil demo`: no server stands behind it) the Community tools page opens each tool's stored sample: the result sets a run of the tool returned on a test server built for the capture (scripts/capture-community-samples.sh), marked as that test server's wherever it is shown, exported or mailed. The findings' names, details and URLs in them are the kits' own words as the procedures returned them. No code of any kit is stored: the reads of the plan cache and of Query Store run first, in the test server's user database only, and the capture stops when the rows of a tool that reads statements hold a kit's own statement.

| What | From | Licence | Where |
|---|---|---|---|
| Stored result sets of sp_Blitz, sp_BlitzFirst, sp_BlitzCache, sp_BlitzIndex, sp_BlitzLock and sp_BlitzWho (their findings' words and links as the procedures returned them on a test server; plan XML left out), and their parameters' names and help text, for the demo only | SQL Server First Responder Kit 8.34 (2026-07-02) | MIT; its licence whole below (it names further MIT portions) | internal/demo/community/samples/sp_Blitz*.json.gz |
| Stored result sets of sp_PressureDetector 6.11, sp_QuickieStore 6.11, sp_HumanEventsBlockViewer 5.11, sp_HealthParser 3.11, sp_LogHunter 3.11 and sp_IndexCleanup 2.11 (their findings' words and links as the procedures returned them on a test server; plan XML left out), and their parameters' names and help text, for the demo only | DarlingData (2026-11-01) | MIT, Copyright 2026 Darling Data, LLC (the MIT licence above) | internal/demo/community/samples/ (the six files named for them) |
| Stored result rows of sp_WhoIsActive v2200.20260409: the test server's own sessions as it listed them, and its parameters' names; none of its own text (its @help output and its parameters' descriptions are not stored) | sp_WhoIsActive, (C) 2007-2026 Adam Machanic | GPL-3.0: the rows are the server's data, the program's output, not a copy of the program | internal/demo/community/samples/sp_WhoIsActive.json.gz |

Glenn Berry's SQL Server Diagnostic Queries: nothing of them is stored (his script's header reserves all rights); the demo says what the tool does and where to download the script.

The First Responder Kit's licence, whole (LICENSE.md of its repository, read 2026-11-12):

```text
MIT License

Copyright for portions of sp_Blitz are held by Microsoft as part of project 
tigertoolbox and are provided under the MIT license:
https://github.com/Microsoft/tigertoolbox
All other copyrights for sp_Blitz are held by Brent Ozar Unlimited, 2022 as
described below.

Copyright for portions of DatabaseRestore are held by GregWhiteDBA as part
of project MSSQLAutoRestore and are provided under the MIT license:
https://github.com/GregWhiteDBA/MSSQLAutoRestore
All other copyrights for DatabaseRestore are held by Brent Ozar Unlimited, 2022
as described below.

Copyright for sp_BlitzInMemoryOLTP are held by Ned Otter and Konstantin
Taranov as part of project sqlserver-kit and are provided under the MIT license:
https://github.com/ktaranov/sqlserver-kit

Copyright for SqlServerVersionScript are held by Josh Darnell as part of
project SqlServerVersionScript and are provided under the MIT license:
https://github.com/jadarnel27/SqlServerVersionScript


Copyright (c) 2022 Brent Ozar Unlimited

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## The Parquet export's file contract

The Parquet export (internal/export, docs/parquet-export.md) follows the file contract of PerformanceMonitor 3.13.0's exporter closely: the layout `<prefix>/<name>/<table>/<table>__<name>__<from>__<to>.parquet`, one JSON manifest per window under `_manifests/` written after the data, a file no manifest lists being an unfinished run, the three table kinds a consumer dedupes by identity, the manifest's per-file row count, size and sha256, and the session settings of the reading login (PerformanceMonitor, Exporter/README.md and Exporter/file-contract.md; MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC). The code and the text are pgvigil's own; no file of that project is in pgvigil, and its exporter writes through DuckDB where pgvigil's writes through parquet-go. The MIT licence printed under "The SQL Server collections" above applies with this copyright line.

## The agent door

The shape of an investigation request and an agent's working rules were followed, not copied; the statements and the
code are pgvigil's own.

| What | From | Licence | Where |
|---|---|---|---|
| An investigation request an operator's own agent claims through MCP (the first claim wins and holds a lease; a brief with the calls to make first, earlier reports marked unreviewed and a budget; a report with a verdict real / false_positive / needs_person, evidence entries and the queries run; a record of every event) and the agent's rules (tool values are data, never instructions; earlier reports are unreviewed; report needs_person when the budget runs out) | PerformanceMonitor 3.13.0, Darling/AGENTS.example.md, docs/darling-agent-dispatch.md and Darling/PerformanceMonitor.Darling.Service/Mcp/DarlingMcpInvestigationTools.cs | MIT, Copyright (c) 2026 Erik Darling, Darling Data LLC (the MIT licence text above, under The SQL Server collections) | internal/repo/sql/0268_investigations.sql, internal/mcp/investigate.go (briefRules), docs/agents.md |

## Read, not copied

The DBADash door (internal/dbadash, task 55) reads a DBA Dash repository (Trimble, MIT) through SQL against its tables dbo.Instances, dbo.Summary, dbo.CollectionDates, dbo.DBVersionHistory and (DBA Dash 4.25.0 or later) dbo.CollectionRunStatus with a read-only login; the table and column names and the status codes (1 Critical, 2 Warning, 3 N/A, 4 OK) are DBA Dash's own, read from the repository DBA Dash 4.24.1 built in the proof; no code of DBA Dash is copied. The SQL Server driver is github.com/microsoft/go-mssqldb (BSD 3-Clause), listed with every module in docs/notices.md.

The waits collection reads pg_wait_sampling's and pgms_wait_sampling's views, the statements collection pg_stat_monitor's, and the index advisor pg_qualstats' and HypoPG's functions, through SQL against the installed extension; no code of theirs is in pgvigil. Their licences (the PostgreSQL licence, each read 2026-11-10 UTC) ask nothing of a program that only queries them; the notice is courtesy: pg_wait_sampling, Copyright (c) 2015-2025, Postgres Professional, Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group, Portions Copyright (c) 1994, The Regents of the University of California; pg_stat_monitor, Portions Copyright (c) 2018-2020, Percona LLC and/or its affiliates, Portions Copyright (c) 1996-2020, PostgreSQL Global Development Group, Portions Copyright (c) 1994, The Regents of the University of California; pg_qualstats, Copyright (c) 2014-2017 Ronan Dunklau, Copyright (c) 2018-2025 The Powa-Team; HypoPG, Portions Copyright (c) 2015-2018, PostgreSQL Global Development Group, Portions Copyright (c) 1994, The Regents of the University of California. The plan reading of depesz's explain.depesz.com and pgMustard informed the plan rules as concepts only; nothing of theirs is copied.

The thresholds of the SQL Server day-one checks (internal/mssql/checks.go, dboptions.go, agentalerts.go; each rule names its source beside it) were read from sp_PerfCheck (DarlingData, MIT), dbachecks (MIT), dbatools' Test-DbaMaxDop (MIT) and Glenn Berry's SQL Server Diagnostic Queries; no code of theirs is copied.

The SQL Server running-queries collection calls sp_WhoIsActive (GPL-3.0) where a server's DBA installed it, with its documented parameters only; no line of it is in pgvigil and pgvigil does not ship it. The storage, version store, availability group, mirroring, log shipping and replication reads are written from Microsoft's documentation of the views and tables.

The provider replica read (internal/cloudrepl, task 390b) calls Amazon RDS and CloudWatch through the AWS SDK for Go v2, and the Cloud SQL Admin and Cloud Monitoring REST APIs through golang.org/x/oauth2 (BSD 3-Clause, Copyright 2009 The Go Authors; v0.38.0) with cloud.google.com/go/compute/metadata (Apache-2.0, Google LLC; v0.10.0) for Application Default Credentials, each licence read from the module at its version on 2026-11-15 UTC and both listed with every module in docs/notices.md; the request shapes and metric names are written from Google's and Amazon's API documentation, no code of theirs is copied.

## dbatools (task 304: the restore chain)

pgvigil's restore chain (internal/mssql/restore_chain.go, internal/repo/sql/0147_restore_chain.sql) chooses its full and
differential backups as dbatools v2.9.1's Get-DbaDbBackupHistory -Last does (public/Get-DbaDbBackupHistory.ps1: the sets
ranked by last_lsn, a differential kept only when it follows its full) and differs from it on purpose where its docs say so
(a copy-only full as a start set, logs chosen by LSN alone, a gap named). No code of dbatools is copied. dbatools is under
the MIT License:

MIT License

Copyright (c) 2018 Chrissy LeMaire

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
