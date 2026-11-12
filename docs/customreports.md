# Custom reports and community tools

Two pages under each scope's **Reports** folder, in the shape of DBA Dash's custom reports and community tools.

**Custom reports** are the DBA's own SQL, or a procedure, saved as a report with parameters, column formats and
colour rules, in folders that every user shares. A report runs on the repository itself (pgvigil's own tables:
reports about the fleet) or, read-only, on a chosen PostgreSQL or SQL Server instance or on the instances of a tag.
Its result is pgvigil's grid, with the grid's menu, the grid tools and the Excel export; a colour rule colours the
cell on the screen, and the export and a mailed page carry the same colour.

**Community tools** run a community procedure that a DBA installed on a SQL Server instance (sp_WhoIsActive, the
First Responder Kit, Erik Darling's procedures), Glenn Berry's diagnostic queries from your own copy of his script,
or one of pgvigil's own diagnostic reads on a PostgreSQL instance, and show each result set as a grid.

PostgreSQL's custom checks ([custom checks](custom.md): SQL from the configuration, run by the collector on a
cadence, judged against thresholds) stay as they are: a custom report is the side you run when you want to look.

## Who may save and run

Saving, moving, deleting and running are behind the UI login, through the actions door's audit login (the
repository dsn of the configuration, a login in `pgvigil_collector`): a server started with `-no-login`, or without
the audit login, shows the reports and says why nothing can be saved or run. Every save, move, delete, folder change
and run is written to `pgvigil.custom_report_log` (who, from where, the report or tool, the instance, the statement
sent, the outcome, the rows and the time it took), shown at the bottom of each page. A run whose log row cannot be
written answers an error and does not show its rows; nothing runs when the audit login may not write the row (run
`pgvigil migrate`: 0106). A run refused before anything is sent (a parameter value that does not parse, a target with
no instance of the report's engine, a procedure parameter pgvigil leaves out) is logged too, as refused, with the
reason. The log is an audit, like the actions log: it is never purged.

## A custom report

| Field | What it is |
|---|---|
| Name | unique among the live reports, whatever the case |
| Folder | a path of parts joined by `/` (`Ops/Daily`); empty is the top of the Custom reports folder |
| Runs on | **the repository** (pgvigil's own tables), **PostgreSQL instances** or **SQL Server instances** |
| Kind | **SQL** (the text runs as written) or **a procedure** (its name; pgvigil calls it with the parameters by name) |
| Parameters | a name, a type (text, whole number, number, true / false, date and time, date), a label, a default, required |
| Column formats | per result set and column: a label, a format (number with its decimals, whole number, bytes, kilobytes, megabytes, a duration in seconds or milliseconds, percent, date and time, date, text), hidden |
| Colour rules | per result set and column: the cell it colours, the column judged (the same one, or another of the row), the condition (equals, does not equal, greater than, at least, less than, at most, between, contains, does not contain, begins with, ends with, is empty, is not empty, always), one or two values, the status (OK, Warning, Critical), case-sensitive or not. The rules of a column are tried in order and the first that matches colours the cell (DBA Dash's rule sets) |
| Timeout | 1 to 60 seconds |
| Rows at most | per result set, 1 to 50,000 |

A parameter is `@name` in the SQL on both engines (pgx's named arguments on PostgreSQL, sp_executesql's parameters on
SQL Server). Every run also passes **@from** and **@to** (the page's time range; timestamptz on PostgreSQL,
datetimeoffset on SQL Server) and, on the repository, **@instance_ids** (an int[]: the instances the run is about:
one, a tag's, or every active one). So a fleet report reads like this:

```sql
SELECT i.name, b.database_name, b.finish_time
  FROM pgvigil.instances i JOIN pgvigil.backups b USING (instance_id)
 WHERE i.instance_id = ANY (@instance_ids) AND b.finish_time BETWEEN @from AND @to
 ORDER BY b.finish_time DESC
```

A procedure report is called with the parameters that have a value, by name; one left empty takes the procedure's own
default: `EXEC [schema].[name] @p = @p` on SQL Server, `SELECT * FROM schema.name(p => @p)` on PostgreSQL and the
repository (a set-returning function). PostgreSQL takes one statement per report; SQL Server takes a batch (no `GO`
lines) and every result set it returns is drawn, at most 50.

A report on the repository runs when its page opens, as DBA Dash's do; a report on instances runs on its Run button,
or on open when the page's address carries `run=1` (a mailed or a linked page: `#/customreports?report=12&run=1&i=3`,
a parameter as `p.<name>=<value>`).

A cell is cut at 256 KB and says so; a run keeps at most 24 MB of rows. A result set that reaches its row cap is cut
there and the statement is cancelled (the server stops producing rows nobody reads): the set says where it was cut,
and on SQL Server a later result set of the same batch is not read.

## How a run stays read-only

| Where | The login | What keeps it read-only |
|---|---|---|
| the repository | the UI's own repository login (`-dsn`, a member of `pgvigil_reader`) | a connection of its own (closed after the run: an advisory lock or a `set_config` never outlives it), `BEGIN TRANSACTION READ ONLY` rolled back, the report's timeout as `statement_timeout`, a 2 s `lock_timeout`, one statement |
| a PostgreSQL instance | the instance's monitoring login (its `dsn`) | the same, and `default_transaction_read_only = on` |
| a SQL Server instance | the instance's read login (its `dsn`) | a connection of its own, `LOCK_TIMEOUT 2000`, `DEADLOCK_PRIORITY LOW`, the report inside a transaction that is rolled back, the timeout on the request, and the login's own rights |

A PostgreSQL run is refused before the report's statement when the login is a superuser or a member of
`pg_execute_server_program`, `pg_write_server_files` or `pg_read_server_files`: a read-only transaction does not stop
`COPY ... TO PROGRAM`. A `SET TRANSACTION READ WRITE` in a report is refused, because the transaction has run a
query (the rights check) before the report's statement.

SQL Server has no read-only session. What keeps a report from writing there is the read login's rights:
[the login](sqlserver.md#the-login) (`VIEW SERVER STATE`, `VIEW ANY DEFINITION`, `CONNECT ANY DATABASE`) and no
more, never sysadmin: a run on a login that is a member of sysadmin is refused before anything is sent. The rollback
undoes what a write-capable login did inside the transaction; it does not undo a `COMMIT` the report itself sends,
which is why the rights are the guard. A report that reads a table needs `SELECT` on it (`db_datareader` in that
database, or a grant); a procedure report needs `EXECUTE` on the procedure.

## Folders

The Custom reports page lists the top level and every folder, each with its reports (Edit, Move to folder, Delete)
and its own actions (Rename, which takes the folders under it and their reports along; Delete folder, refused while
it or a folder under it holds a report; New report here). A folder made with New folder stays while it is empty.

An edit is made on the version it was opened on: a report changed by someone else since then is refused with who
changed it and when, and is reopened. A deleted report is kept for its log and never shown.

## Community tools

The page lists, for the instance's engine, each tool with what it does and, on SQL Server, whether it is installed in
the database the page looks in (`master` unless you name another). pgvigil never installs a procedure: a missing one
says where to get it.

| Group | Tools | Where to get them |
|---|---|---|
| sp_WhoIsActive | sp_WhoIsActive | <https://github.com/amachanic/sp_whoisactive> |
| First Responder Kit | sp_Blitz, sp_BlitzFirst, sp_BlitzCache, sp_BlitzIndex, sp_BlitzLock, sp_BlitzWho | <https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit> |
| Darling Data | sp_PressureDetector, sp_QuickieStore, sp_HumanEventsBlockViewer, sp_HealthParser, sp_LogHunter, sp_IndexCleanup | <https://github.com/erikdarlingdata/DarlingData> |
| Glenn Berry | SQL Server Diagnostic Queries | <https://glennsqlperformance.com/resources/> |

Opening a procedure reads its parameters from `sys.parameters` of the installed copy (so the form follows the
version you installed) and runs its `@help = 1` (audited, like any run) for the descriptions, matched to the
parameters by name, and the help's own grids. A parameter left empty takes the procedure's default. Left out of the
form, and refused in a run, are the parameters that make a procedure write a table (the First Responder Kit's
`@Output...DatabaseName / SchemaName / TableName / ServerName`, sp_BlitzFirst's `@LogMessage...`, sp_BlitzBackups'
`@WriteBackupsToDatabaseName`, Erik Darling's `@log_...`, sp_WhoIsActive's `@destination_table` and `@return_schema`)
or send what it read to a service outside the server (sp_BlitzCache's `@AI...`, which calls
`sp_invoke_external_rest_endpoint`), the OUTPUT parameters and the help switch: pgvigil reads, it never writes
through a procedure. A procedure runs as itself, with no transaction around it (several of them refuse one), under
the timeout you give (at most 60 s).

**Glenn Berry's diagnostic queries** carry no licence that lets pgvigil ship them, so pgvigil ships none of their
text. Download the script for the server's version from his site and pick the file on the page: the server cuts it at
its `-- ... (Query n) (name)` lines (each query runs to the next `------` line; `GO` lines dropped) and keeps nothing.
Pick a query to run it on the instance's read login, as written, in a transaction that is rolled back, audited with
its full text. A database-level query runs in the database you name on the page.

The read login needs `EXECUTE` on each procedure where it is installed, besides its standing rights, and on every
procedure of a kit you installed, not only the ones the page lists: a kit's procedures call each other (sp_Blitz runs
sp_BlitzBackups, and a run without that right fails after the rows it read):

```sql
USE master;   -- or the database the procedures are installed in
CREATE USER [pgvigil_monitor] FOR LOGIN [pgvigil_monitor];   -- if it has no user there yet
GRANT EXECUTE ON dbo.sp_WhoIsActive TO [pgvigil_monitor];
GRANT EXECUTE ON dbo.sp_Blitz TO [pgvigil_monitor];
GRANT EXECUTE ON dbo.sp_BlitzBackups TO [pgvigil_monitor];
-- ... one line per procedure the kits installed
```

A run that fails part-way shows the rows it read before the error, and the error.

Some procedures do more with more rights: sp_Blitz skips the checks a non-sysadmin cannot run and says so; sp_LogHunter
reads the error log through `xp_readerrorlog` (`GRANT EXECUTE ON master.sys.xp_readerrorlog`, as the error log reader
asks: [readers](sqlserver-readers.md)); sp_HumanEventsBlockViewer reads an Extended Events session that captures the
blocked process report; sp_QuickieStore needs Query Store on in the database it reads. A run that lacks a right shows
the procedure's own error.

On PostgreSQL the page offers pgvigil's own diagnostic reads, run on the instance's monitoring login like a custom
report (read-only, refused for a superuser), each in the database you name (empty = the login's own):

| Read | What it shows |
|---|---|
| Running now | every session that is not idle: state, wait, the pids blocking it, how long, the statement |
| Blocking tree | who blocks whom now, the heads (blocking, not blocked) first |
| Top statements | pg_stat_statements by total time since its reset (the extension in that database) |
| Largest tables | the table, its indexes and its TOAST, live and dead rows |
| Unused indexes | never scanned since the statistics reset, not behind a constraint |
| Duplicate indexes | the same table, columns, operator classes, expressions and predicate |
| Invalid indexes | left invalid by a failed CREATE INDEX CONCURRENTLY |
| What holds back vacuum | the oldest transaction horizons: sessions, replication slots, prepared transactions |
| Settings changed | every setting not at its built-in default, and those waiting for a restart |
| Sequences near their end | the share of each sequence's range used |

They are pgvigil's own SQL, written after the ideas of postgres_dba's lock trees and index reads (BSD-3, Nikolay
Samokhvalov) and pghero's sequence and index checks (MIT, Andrew Kane); no text of theirs is copied.

## The API

| Route | What it does |
|---|---|
| `GET /api/customreports` | the folders, the live reports with their definitions, the latest 200 log rows, and whether saving and running are on here |
| `GET /api/customreports?report=N` | one report and its 100 latest log rows |
| `POST /api/customreports` | `{op: add, edit, delete, move, folder_add, folder_rename, folder_delete, ...}` |
| `POST /api/customreports/run` | `{report_id, target: fleet (repository reports only), tag or instance, instance_id, tag, from, to, params}` |
| `GET /api/community?instance=N&database=D` | the tools for the instance's engine, whether each is installed, the instance's log |
| `POST /api/community/params` | `{instance_id, tool, database}`: a procedure's form and help |
| `POST /api/community/run` | `{instance_id, tool, database, params, timeout_secs, text, query_name}` |
| `POST /api/community/glenn/parse` | `{text}`: the queries of a diagnostic script |

A POST carries the `X-Pgvigil` header (a cross-site form cannot set it) and the session cookie. A run on a tag goes to
at most 20 instances of the report's engine, four at a time, within 62 s in all (the serve answers within 75 s): an
instance not answered by then fails with the deadline.
