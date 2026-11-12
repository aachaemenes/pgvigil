# SQL Server readers: error log, default trace, system_health

Three collections read what SQL Server already keeps about itself, each forward from where its last read stopped, and
change nothing on the server: no trace, no event session, no setting is created, started or switched.

| Collection | Reads | Every | The right it needs | Not on |
|---|---|---|---|---|
| `mssql_errorlog` | the error log, current and archived | 5 min | EXECUTE on `master.dbo.xp_readerrorlog`; listing the archives: securityadmin, or on SQL Server 2022 and later VIEW SERVER STATE or VIEW ANY ERROR LOG | Azure SQL Database |
| `mssql_defaulttrace` | the default trace | 5 min | ALTER TRACE | Azure SQL Database |
| `mssql_syshealth` | system_health's sp_server_diagnostics results | 5 min | VIEW SERVER STATE | Azure SQL Database |

A reader whose right is missing is not a failing collection. Its state is **no right** with the right it needs named
on its page, its run is recorded as ok, and the one finding it raises is an info row ("a SQL Server reader lacks its
right"). A source the server has switched off (the default trace disabled, system_health stopped) is the state **off**.
**failed** is anything else that stopped a read, and that one is a warning.

The pages are Error log, Default trace and System health under the instance's Logs group.

## Error log (`mssql_errorlog`)

The reader asks for each log file once, from the cursor's time on, oldest line first, and matches the lines itself.
The server does not run one search per string. The first read goes seven days back.

- **Which files.** The archives are listed with `sys.sp_enumerrorlogs`. A file that ended before the cursor (with a
  minute of grace: the listing cuts a file's last write to the minute) is not read. A login that may not list the
  archives reads the current log only. Its state says "current log only", and its note says that lines written
  between two reads and a cycle of the log are not seen.
- **How.** `xp_readerrorlog <file>, 1, NULL, NULL, <start>, NULL, 'asc'`. When EXECUTE on it is refused, the reader
  falls back to `sys.sp_readerrorlog` (securityadmin, or on 2022 and later VIEW SERVER STATE or VIEW ANY ERROR LOG).
  That call hands over the whole file, and the lines before the start are passed over here. Amazon RDS uses
  `rdsadmin.dbo.rds_read_error_log @index, @type` (the arguments its documentation names) the same way and reads the
  current log only.
- **Where a read starts.** Half an hour before the cursor. The log is not always in time order: a server under memory
  pressure wrote lines dated before the line above them. `xp_readerrorlog` with a start time hands
  over only the lines after the last line dated before the start, so a read that started at the cursor would lose
  them. What is read again is stored once. The cursor keeps the server's offset of the read that wrote it, and the
  start uses the earlier of that offset and today's. A clock set forward (spring) and a clock set back (autumn) both
  lose nothing, and the cursor never runs ahead of the server's now.
- **The terse form.** An error the server could not format is one line, `Error: 802, Severity: 17, State: 2.
  (Params:). The error is printed in terse mode ...`. It is read as a whole error with its numbers.
- **What is kept.**
  - Any error of severity 17 or higher.
  - A line that one of sp_LogHunter's search strings finds, unless its noise list names the line.
  - A line one of the instance's own strings finds.

  An error's own line under severity 17 (a first line whose message never came, the terse form) is left out, as
  sp_LogHunter's `Severity: 1[0-8]` pattern does, unless one of the instance's own strings found it. The match
  ignores case, as `xp_readerrorlog`'s own search does. The server writes an error as two lines, `Error:
  n, Severity: s, State: t.` and the message under it at the same time by the same process. They are one row: the
  message with its number, severity and state. A line is stored once, whatever it matched (`matched` lists every
  string it matched).
- **Class.** A kept line is filed under the gravest class its matches name: corruption, memory, io, scheduler,
  availability, startup, config, general. A CHECKDB that found 0 errors is general, never corruption.
- **Times.** The log writes the server's local clock without a zone. The row keeps that time as written
  (`logged_local`, the page's "server clock" column) and the instant, which is the local time less the server's offset
  at the read. The row's key is made of the local time, the process and the text, so a line read twice is one row
  whatever the offset was each time. When a clock is set back, the hour that is read again is stored once.

The page lists the kept lines newest first (at most 1,000) over the page's range. It filters by class, by a text the
line holds, and by severity 17 or higher.

### The instance's own search strings

Up to 50 strings of 1 to 200 characters per instance (one per spelling without regard to case), set by the
repository's owner:

```sql
SELECT pgvigil.mssql_errorlog_search_set('<instance name>', ARRAY['payroll', 'Login failed for user ''etl'''], false);
-- true as the last argument: search only these (errors of severity 17 or higher are still kept)
SELECT pgvigil.mssql_errorlog_search_set('<instance name>', '{}', false);   -- removes them
```

The next read uses them; lines already passed over are not searched again. The page shows the strings in force.

## Default trace (`mssql_defaulttrace`)

SQL Server writes the default trace by itself (five files of 20 MB in its log directory, the oldest dropped at each
rollover) unless `default trace enabled` is 0. The reader keeps:

- file growths and shrinks the server made by itself (event classes 92 to 95), with the database, the file, how long it
  took and the size change.
- DBCC commands (116), with who ran them, the command's name and its text. FREEPROCCACHE with a plan handle (one plan)
  is told apart from FREEPROCCACHE (the whole cache), and SQLPERF with CLEAR (the wait or latch counters reset) from
  the other SQLPERF calls. The command is named by its first word, never by a word in its arguments. pgvigil's own
  calls are left out by the program name its session carries (pgvigil, or the one the dsn names).
- DDL, meaning objects created, dropped and altered (46, 47, 164), committed, outside tempdb, statistics left out.

The cursor is the time the last event read was written and its sequence number, plus the trace file current at the
end of the read. A growth or a shrink is written when it ends and stamped with the time it began, so the order is the
write time (its end), and the stored time is when it began. The cursor's time goes back on the server's clock as the
error log's does (the earlier of the stored and today's offset). The next read opens that file and the ones after it. When that file has been rolled away, the set is read again
from its oldest file by the same time. The state carries the oldest event the files still hold, which is how far back
the trace reaches on that server.

## System health (`mssql_syshealth`)

Every five minutes SQL Server runs `sp_server_diagnostics` for itself, and its `system_health` session records the
result of four components. Each has a state (CLEAN, WARNING, ERROR) and its figures:

- **SYSTEM**: CPU (SQL Server's and the machine's), page faults, spinlock backoffs and a sick spinlock type, latch
  warnings, non-yielding tasks, access violations, dump requests, bad pages detected and fixed.
- **RESOURCE**: the last memory notification, out-of-memory exceptions, a resource pool out of memory, and the memory
  report (available physical memory, working set, the low-memory flags, target and committed memory).
- **QUERY_PROCESSING**: most workers, workers created and idle, pending tasks and the oldest one's wait, and the
  unresolvable deadlock and deadlocked schedulers flags.
- **IO_SUBSYSTEM**: IO latch timeouts, long IOs (15 s and more) and the five longest pending requests with their files.

The reader takes the results from the session's event file, past a cursor of its own. The Extended Events reader
(`mssql_xe`) keeps another one for the deadlock reports in the same files. The long lists of a QUERY_PROCESSING result
(top waits, CPU-intensive requests) are not stored. A session without an event file target (a DBA changed it, or the platform writes it to a ring
buffer only) is not read: the state is off and says so.

## Findings

| Finding | Severity | When |
|---|---|---|
| error log: errors of severity 17 or higher | warning; critical at 20 or higher, or when one of them is a corruption line | in the last 24 hours |
| error log: corruption reported | critical | a line of that class (under severity 17) in the last 24 hours |
| error log: memory pressure / slow or failed IO / scheduler or worker thread trouble reported | warning | the same, by class |
| default trace: slow file growth | warning | a growth over 1 s in the last 24 hours, per database and file kind |
| default trace: auto-shrink ran | warning | in the last 24 hours |
| default trace: a disruptive DBCC command ran | warning | FREEPROCCACHE (the whole cache), FREESYSTEMCACHE, DROPCLEANBUFFERS, WRITEPAGE in the last 24 hours |
| default trace: a DBCC SHRINK command ran | info | SHRINKFILE or SHRINKDATABASE in the last 24 hours |
| default trace: the wait or latch statistics were cleared | info | DBCC SQLPERF (..., CLEAR) in the last 24 hours |
| system_health: a component is not clean | warning; critical for ERROR | a result in the last hour |
| system_health: bad pages detected / access violations / non-yielding tasks / latch warnings / a sick spinlock | critical | the newest SYSTEM result of the last hour (the counters run from the server's start) |
| system_health: dump requests | critical | in the last 24 hours |
| system_health: an unresolvable deadlock occurred / deadlocked schedulers | critical | in the last 24 hours |
| system_health: tasks waiting for a worker | warning | 10 or more pending tasks in a result of the last hour |
| system_health: long IO or IO latch timeouts | warning | long IOs in the last 24 hours, or IO latch timeouts the counter gained in them (it runs from the server's start) |
| system_health: out of memory | critical | out-of-memory exceptions the counter gained in the last 24 hours (it runs from the server's start), or a pool out of memory |
| a SQL Server reader could not read its source | warning | the state failed, read in the last 30 minutes |
| a SQL Server reader's source is switched off | info | the state off |
| a SQL Server reader lacks its right | info | the state no right, one row per instance naming the readers |

## API

- `GET /api/mssql/errorlog?instance=<id>[&from=&to=][&class=][&q=][&sev=][&part=]`: the parts are state, findings,
  lines, classes and search.
- `GET /api/mssql/defaulttrace?instance=<id>[&from=&to=][&part=]`: state, findings, growth_summary, growths,
  dbcc_summary, dbcc, ddl.
- `GET /api/mssql/syshealth?instance=<id>[&from=&to=][&part=]`: state, findings, latest, issues, system,
  query_processing, io, resource, series.

## Retention

The three event tables (`mssql_errorlog`, `mssql_trace_events`, `mssql_health_components`) are partitioned by month
and dropped whole by `pgvigil.purge` past the retention window. The reader states and the search strings are one row
per instance and reader.

## Borrowed

The error log's match list and noise list are the search strings and the excluded line patterns of sp_LogHunter (Erik
Darling, Darling Data, LLC), used as data under its licence. The reader and its statements are pgvigil's own:

> Copyright (c) 2021 Darling Data, LLC
>
> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
> documentation files (the "Software"), to deal in the Software without restriction, including without limitation the
> rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
> permit persons to whom the Software is furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
> Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
> WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
> COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
> OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

What the default trace and system_health are read for follows the checks of sp_Blitz (Brent Ozar Unlimited, MIT),
sp_PerfCheck and sp_HealthParser (Darling Data, MIT) and dbatools' Get-DbaSchemaChangeHistory (MIT). No code of theirs
is copied.

## Proof

`scripts/proof-mssql-readers.sh` runs against a SQL Server container of its own. Its clock is set to
America/Los_Angeles, so the server's local time is not UTC. Its header lists every expected result.

Result (2026-11-11, SQL Server 2022 16.0.4315.2 in a container on Linux, the server's clock 480 minutes behind UTC;
the repository on PostgreSQL 18, the migration chain also on PostgreSQL 13): PASS.

- A severity 17 error was stored once, at the server's own time to the millisecond and that time moved by the offset.
- After two cycles of the log, an error in archive 1 was stored once, and a line the instance's own string found was
  marked as its own.
- A login that may read a log file but not list the archives stored the current log only and said so; a login with
  no right at all was "no right", and its run was ok.
- The default trace: 3 data and 11 log growths of a seeded database, equal to sa's count; a DBCC SHRINKFILE once by
  sa, dated to the millisecond; a table's create and drop. A second read stored nothing more.
- system_health: 400 sessions behind one lock, with max worker threads at 128, gave a QUERY_PROCESSING result in
  WARNING with 43 pending tasks. It was stored once with its finding.

Not proven here: a Windows SQL Server (task 144; its backslash paths are unit-tested), SQL Server 2016 (task 164), 2017, 2019 and 2025, Amazon RDS (task 165),
Azure SQL Managed Instance, a growth slower than 1 s, and the corruption, IO and scheduler figures of a real server in
trouble.
