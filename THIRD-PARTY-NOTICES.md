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
| The catalogue of SQL Server builds 2016-2025 with their release and support end dates, as data | SQL Server First Responder Kit 8.34, SqlServerVersions.sql (the script by Josh Darnell, SqlServerVersionScript, MIT) | MIT, Copyright (c) 2022 Brent Ozar Unlimited; Copyright for SqlServerVersionScript held by Josh Darnell | internal/mssql/checks.go (buildCatalogue) |
| The error log's match list and noise list (the search strings of its @custom_message_only = 0 run less 'Microsoft SQL Server' and 'Server name is', and the line patterns it deletes after the search), as data | DarlingData (darlingdata-20261101), sp_LogHunter.sql | MIT, Copyright (c) 2021 Darling Data, LLC | internal/mssql/errorlog.go (errorLogMatches, errorLogNoise*) |

The MIT licence of each of these sources, with its copyright line above:

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

## Read, not copied

The DBADash door (internal/dbadash, task 55) reads a DBA Dash repository (Trimble, MIT) through SQL against its tables dbo.Instances, dbo.Summary, dbo.CollectionDates and dbo.DBVersionHistory with a read-only login; the table and column names and the status codes (1 Critical, 2 Warning, 3 N/A, 4 OK) are DBA Dash's own, read from the repository DBA Dash 4.24.1 built in the proof; no code of DBA Dash is copied. The SQL Server driver is github.com/microsoft/go-mssqldb (BSD 3-Clause), listed with every module in docs/notices.md.

The waits collection reads pg_wait_sampling's and pgms_wait_sampling's views, the statements collection pg_stat_monitor's, and the index advisor pg_qualstats' and HypoPG's functions, through SQL against the installed extension; no code of theirs is in pgvigil. Their licences (the PostgreSQL licence, each read 2026-11-10 UTC) ask nothing of a program that only queries them; the notice is courtesy: pg_wait_sampling, Copyright (c) 2015-2025, Postgres Professional, Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group, Portions Copyright (c) 1994, The Regents of the University of California; pg_stat_monitor, Portions Copyright (c) 2018-2020, Percona LLC and/or its affiliates, Portions Copyright (c) 1996-2020, PostgreSQL Global Development Group, Portions Copyright (c) 1994, The Regents of the University of California; pg_qualstats, Copyright (c) 2014-2017 Ronan Dunklau, Copyright (c) 2018-2025 The Powa-Team; HypoPG, Portions Copyright (c) 2015-2018, PostgreSQL Global Development Group, Portions Copyright (c) 1994, The Regents of the University of California. The plan reading of depesz's explain.depesz.com and pgMustard informed the plan rules as concepts only; nothing of theirs is copied.

The thresholds of the SQL Server day-one checks (internal/mssql/checks.go, dboptions.go, agentalerts.go; each rule names its source beside it) were read from sp_PerfCheck (DarlingData, MIT), dbachecks (MIT), dbatools' Test-DbaMaxDop (MIT) and Glenn Berry's SQL Server Diagnostic Queries; no code of theirs is copied.

The SQL Server running-queries collection calls sp_WhoIsActive (GPL-3.0) where a server's DBA installed it, with its documented parameters only; no line of it is in pgvigil and pgvigil does not ship it. The storage, version store, availability group, mirroring, log shipping and replication reads are written from Microsoft's documentation of the views and tables.
