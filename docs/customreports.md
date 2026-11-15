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
repository dsn of the configuration, a login in `pgvigil_collector`): a server without the UI login (`pgvigil serve
-no-login`, or `pgvigil demo -serve`), or without the audit login, shows the reports and says why nothing can be saved or run. Every save, move, delete, folder change
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

A report on the repository runs when its page opens (where it may run: its login, below), as DBA Dash's do; a report on instances runs on its Run button,
or on open when the page's address carries `run=1` (a mailed or a linked page: `#/customreports?report=12&run=1&i=3`,
a parameter as `p.<name>=<value>`).

A cell is cut at 256 KB and says so; a run keeps at most 24 MB of rows. A result set that reaches its row cap is cut
there and the statement is cancelled (the server stops producing rows nobody reads): the set says where it was cut,
and on SQL Server a later result set of the same batch is not read.

## How a run stays read-only

| Where | The login | What keeps it read-only |
|---|---|---|
| the repository | its own login, `reports_dsn` (IN ROLE `pgvigil_reader` alone; never the UI's login) | a connection of its own (closed after the run: an advisory lock or a `set_config` never outlives it), `BEGIN TRANSACTION READ ONLY` rolled back, the report's timeout as `statement_timeout`, a 2 s `lock_timeout`, one statement |
| a PostgreSQL instance | the instance's monitoring login (its `dsn`) | the same, and `default_transaction_read_only = on` |
| a SQL Server instance | the instance's read login (its `dsn`) | a connection of its own, `LOCK_TIMEOUT 2000`, `DEADLOCK_PRIORITY LOW`, the report inside a transaction that is rolled back, the timeout on the request, and the login's own rights |

A PostgreSQL run is refused before the report's statement when its SESSION user is a superuser, a member of a
superuser role (a `NOINHERIT` member too: the statement can `SET ROLE` to it), or a member of
`pg_execute_server_program`, `pg_write_server_files` or `pg_read_server_files` (a read-only transaction does not stop
`COPY ... TO PROGRAM`), a member of `pgvigil_auth` (it reads the UI's password hashes), `pgvigil_collector` (its
import functions write the repository) or `pgvigil_alerter` (the alerts login: `alert_contact_routes()` returns every
alert contact's address to it), or may `CREATE` in a `pgvigil` schema (the repository's owner); and, in a
database that holds a `pgvigil` schema (the repository monitored as an instance), a member of that schema's owner (a
`NOINHERIT` member too: `SET ROLE` reaches the owner) or of `pg_read_all_data` (it reads every table, the UI's logins
among them), or a login that may read the UI's password hashes. A monitoring login's `pg_read_all_data` stays fine on
every other database. The session
user, not the current role: a role set when the login connects (`ALTER ROLE ... SET role`) or inside the run can be
undone by the report's own statement (`set_config('role', 'none', true)`: PostgreSQL checks a role change against the
session user). A
`SET TRANSACTION READ WRITE` in a report is refused, because the transaction has run a query (the rights check)
before the report's statement. EXPLAIN on the Plan page and the index advisor's hypothetical index ask the same check of
the monitoring login, and EXPLAIN
ANALYZE's own login is refused the same way.

### A report on the repository: its own login (reports_dsn)

A report on the repository runs the DBA's own SQL against pgvigil's own tables, so it runs only as a login of its own,
`reports_dsn` in `pgvigil.yaml` (`env:NAME`, `file:/path`, or a connection string without a password, its password
in pgpass as the Windows app's is), a login IN ROLE `pgvigil_reader` alone
(`pgvigil roles` prints it: `pgvigil_reports`). The UI's own repository login holds `pgvigil_auth`, which reads every UI
user's password hash through `pgvigil.ui_password_hash`, so a report on it could read them; a report is never run as
it. Each run checks the login inside its own read-only transaction, on its session user: refused when it is a superuser
or bypasses row security, a member of any role but `pgvigil_reader` (the owner, `pgvigil_auth`, `pgvigil_collector`,
`pg_read_all_data`, `pg_monitor`, the server-file roles), may not read the schema, may read the password hashes, or
reaches another server or database than the repository dsn's (its server's start time and the database's oid are
compared: a replica or a copy is refused). Without the key, Run on a report on the repository is off and says:
'a report on the store runs only as a login IN ROLE pgvigil_reader alone: reports_dsn in pgvigil.yaml names one
('pgvigil roles' prints it); this server's repository login holds pgvigil_auth, which reads the UI's password hashes';
the page does not run it when it opens, and a mailed report carries the same words. `serve` says it once in a WARN at
start and starts anyway. Behind PgBouncer, the reports login's startup settings are the UI login's (the README's
`track_extra_parameters` line).

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
reads the error log through `xp_readerrorlog` (`GRANT EXECUTE ON sys.xp_readerrorlog` in master, as the error log
reader asks: [readers](sqlserver-readers.md)), and lists the archived logs through `sp_enumerrorlogs`: for a member of
securityadmin, and from SQL Server 2022 for a login with `VIEW SERVER STATE` or `VIEW ANY ERROR LOG` (a note on the
page otherwise);
sp_HumanEventsBlockViewer reads an Extended Events session that captures the blocked process report; sp_QuickieStore
reads Query Store of one database, which is never on in master.

### Before the click

The page says, before any click, each tool's state on that instance in the column 'before it runs', and above the
list what stops every tool there, each with the way to get it:

| State | The tool | Said |
|---|---|---|
| ready | on | where it is installed |
| note | on | what the run will not see, or what the form filled in for this server |
| off | off | what it lacks: the line to ask for (a `GRANT`, a configuration key, a setting) |
| not checked | off | the check that failed or ran out of time: a tool is never 'ready' on a guess |
| demo | Run off; 'Open sample' (or the name) opens the stored sample | a demo instance: `pgvigil demo` invented its data and no server stands behind it |

A tool's panel (its form and Run, or on a demo instance its stored sample) opens directly under the tool's own table, at
the top of the view with the keyboard's focus on its heading (a failed read: on its error); a click on another tool
moves it there, and a later click wins over an earlier one still loading. On a demo instance the address's `tool=`
opens the sample the same way once as the page is reached (a link, Back); a redraw of the same page (the system's
colours under the 'auto' theme) leaves the view where it is. An address naming no tool there says so above the tools.

On a demo instance (one this running `pgvigil demo -serve` seeded, still tagged `demo` under the demo's name prefix,
with no login for it on this server: decided per instance, so `pgvigil demo -serve -config` shows real instances beside
it as themselves; a plain `pgvigil serve` has no demo instance, whatever an instance's tags, and the demo's instances
there are instances without a login) the page says so first ('Each tool with a stored sample opens it: its real
output, captured on a test server; nothing runs on a demo instance.'), and each row's 'before it runs' leads with an 'Open
sample' button (named 'Open sample: <tool>'; the tool's name opens it too) before the demo line; a tool with no stored
sample says so in its row. The sample is what a run of the tool
returned on a test server built for the capture (`scripts/capture-community-samples.sh`: a SQL Server 2022 and a
PostgreSQL server of their own, loaded with the demo's own invented names; the kit, its version, the capture's date (its
UTC day, said so) and the test server's version in the line above it, and 'not <instance>' - with the instance's
platform where it is not the test server's, since the same run there returns other rows: 'not demo-azure-sql03, an
Azure SQL Managed Instance, where the same run returns other rows.'), with a link to the instance's own page of the
same subject and Run off with the demo's line. Beside the result sets a sample keeps the stored run's parameters: their
names, and for the First Responder Kit's and DarlingData's procedures their own help text (MIT, as
THIRD-PARTY-NOTICES.md says); sp_WhoIsActive's sample holds its result rows and its parameters' names only. A sample is never a run: nothing is sent, nothing is audited, and it is
never among the instance's runs; its grids carry the line's short form into Export .xlsx (About's line of each of its sheets) and Export
CSV (the file's first line: a program that reads the CSV takes that line as its first record). A sample is never
mailed: `pgvigil demo -serve` has no login, so it sends and schedules no report mail (its door writes the repository
only), and a serve that mails has no demo instance. The address keeps the tool open (`tool=<id>`), so a page linked
from there opens the sample again (on a real instance `tool=` opens nothing: a tool's form asks the server, which only
a click does). Plan XML is left out of the stored copy and said, and so are the capture login's own statements in Top statements (the monitor's reads are not the demo's subject). Glenn Berry's queries
are his own text: nothing of them is stored, and the demo says where to get the script.

What decides it, and where pgvigil reads it:

- the server: without the UI login (`pgvigil serve -no-login`, or `pgvigil demo -serve`; sign in: serve with the
  configuration file, without `-no-login`, and add a user with `pgvigil user add`), no actions door or its audit login
  not connected (then a PostgreSQL instance's own login is not asked about: the server's line is the reason); each page names it in its own words (Running a tool / Saving or running a
  report / Sending or scheduling a mail needs ...).
- the configuration file: no read login (SQL Server) or monitoring login (PostgreSQL) for the instance; an instance
  added in Admin > Instances has its stored login as its door only where `doors: page_instance_reads: on` is set and
  its sign-in is one the page door opens ([Configuration](configuration.md#community-tools-and-custom-reports-on-a-page-instance)),
  else its own words say which of these it is.
- live, on the instance's own login, within 5 s for the instance and the database named, kept 60 s (Look again checks at
  once, except that it first shows the answer of a check that outran the 5 s; at most 16 checks run at once): a sysadmin
  or superuser login (refused); each procedure in the database named as the login sees it (not there: name the database
  they are installed in, or install it; a login without `EXECUTE` or `VIEW DEFINITION` on a procedure does not see it);
  `EXECUTE` on it (off, with the `GRANT` line, and `CREATE USER` when the login has no user in that database); `EXECUTE`
  on a procedure of its kit it runs itself (sp_Blitz's version check runs every First Responder Kit procedure installed
  beside it, and its database checks run sp_ineachdb: off without it; sp_BlitzFirst's sp_BlitzWho and sp_BlitzCache,
  sp_BlitzIndex's sp_BlitzCache: a note); sp_LogHunter's own test of `xp_readerrorlog` (`HAS_PERMS_BY_NAME`; Amazon
  RDS's own reader needs no grant; Azure SQL Database: the procedure does not run there); a user database the login can
  reach, online, writable and not in standby (sp_IndexCleanup skips read-only and standby databases); the compatibility
  level of the database named (sp_BlitzCache cannot run from one below 130) and SQL Server 2016 or later for
  sp_BlitzCache; the blocked process threshold (`sys.configurations`); the running Extended Events sessions; on
  PostgreSQL `pg_stat_statements` in the run's database: not created there (a superuser-class role runs `CREATE
  EXTENSION`; the monitoring login cannot), its view read with `LIMIT 0` (refused: the `GRANT SELECT` line), then one
  row of its function (created but not loaded: it goes in `shared_preload_libraries` and needs a restart), and
  `pg_read_all_stats` for other users' statement text (a note).
- the repository, with the time of its read: the databases with Query Store on (`mssql_qs_store`), read live only when
  no collection holds them yet; the blocked process threshold only when the live read finds none (the collection reads
  it hourly, so a threshold set since would be read as the old value and the form would preset a click the procedure
  declines).

The form fills in what the server makes the procedure's own default wrong: sp_HumanEventsBlockViewer reads its
default session `keeper_HumanEvents_blocking` when it runs; otherwise another running session that captures the
blocked process report; otherwise, and whenever the blocked process threshold is 0, `system_health` (which holds only
the blocking `sp_server_diagnostics` recorded in it), with a note saying so. sp_QuickieStore gets the first database
with Query Store on; sp_IndexCleanup, installed in a system database (its own default reads that database and skips it),
the first user database the login reaches. A value you type over a filled one is sent as typed.

A tool that is off stays in the keyboard order with its reason beside it, read out as its description and shown on
hover; a click on it sends nothing.

A run the procedure itself turns down in one of its own messages, before it returned anything, is drawn as a note
'declined' with its words: sp_LogHunter without `EXECUTE` on `xp_readerrorlog` or on Azure SQL Database;
sp_HumanEventsBlockViewer with the blocked process report off, or a session that does not run; sp_IndexCleanup with
no database to process, before SQL Server 2012, or `@get_all_databases` on Azure SQL Database; sp_HealthParser and
sp_QuickieStore on the Azure platforms they refuse (DarlingData 2026-11-01's messages). The audit keeps it as a
failed run (the statement reached the server) with the words; any other error, a lock timeout or a denied permission
inside a procedure included, stays an error box.

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

### The kits pgvigil was checked against

The community tools change upstream without asking pgvigil, so pgvigil watches them:

- **The versions it was checked against**: First Responder Kit 8.34 (2026-07-02), DarlingData of 2026-11-01
  (sp_PressureDetector and sp_QuickieStore 6.11, sp_HumanEventsBlockViewer 5.11, sp_HealthParser and sp_LogHunter 3.11,
  sp_IndexCleanup 2.11), sp_WhoIsActive v2200.20260409, on SQL Server 2022 CU28 (16.0.4325.4). The stored shapes are
  `internal/community/kits/shapes.json`; the blocks pgvigil's code ports from the kits are listed with their anchors
  in `ports.json`.
- **Each server's own versions** (`mssql_kits`, once a day): read from each procedure's definition in `master` and the
  connection's database - nothing of the kits is executed. A login without VIEW DEFINITION on a procedure reads 'not
  readable' (never an error). The Community tools page shows the installed version beside the checked one, and says
  when it is newer; `pgvigil.kit_versions_fleet` counts the fleet's instances per procedure and version.
- **The collector's own call**: `mssql_requests` reads 14 of sp_WhoIsActive's columns by name. When the call fails the
  DMV read runs instead and the run is partial; after 5 such runs in a row over at least 5 minutes with an error that
  means a changed shape (207 a column, 8144 / 8145 a parameter, 213 the column count, 2812 no such procedure, or 50000
  about the schema) the finding 'sp_WhoIsActive unusable' (warning) is raised, with the server's own error; another
  repeated error (a deadlock victim, a lock timeout) is 'sp_WhoIsActive failing' (info). The first run that is not
  the fallback clears it. The view is `pgvigil.kit_findings`.
- **Every week** (`.github/workflows/kitwatch.yml`, Monday): the pinned kits and the newest (the First Responder Kit's
  and sp_WhoIsActive's latest release, DarlingData's default branch) are installed on one SQL Server container and
  every tool is run through pgvigil itself - the form, the Run path with every preset, the collector's call, the
  siblings each tool cannot run without, the refusals pgvigil words as 'declined' - and compared. A **BREAK** line (a
  column pgvigil reads by name, a coarse type, a set or column removed, a preset's parameter, the help's descriptions,
  a new form parameter pgvigil's write filter does not take out, a new sibling, a run that stops succeeding) turns the
  run red with its lines in the run's summary; a **DRIFT** line (a column or set added, an exact type inside one
  coarse type, nullability, order, a ported block or list that moved) is a warning on a green run. A section that had
  no rows in one of the two runs (sp_HealthParser's one-column 'finding' set, sp_PressureDetector's 'THREADPOOL') is an
  info line, its columns not compared that week: its shape follows the server's data, not the kit. The pinned pass is
  also compared with `shapes.json`, so a change of pgvigil's own code, its driver or the runner is told apart from a
  kit's. A run that could not run (a fetch, docker, a state the tools need not reached) is red and says why.
- **Taking a change**: accommodate the code, then run the workflow by hand with its baseline input (or
  `bash scripts/kitwatch.sh -baseline` with a PostgreSQL superuser in `PGVIGIL_ADMIN_DSN`) and commit the new
  `shapes.json` and `ports.json` with the code change, so the stored shapes are always the ones the code was proven
  against. The run's artifact holds its report only: no kit file is stored or committed (sp_WhoIsActive is GPL-3.0).
- **Keeping it running**: GitHub turns a scheduled workflow off after 60 days without repository activity; before a
  release `gh workflow view kitwatch` must say it is enabled (`gh workflow enable kitwatch` if not).

## The API

| Route | What it does |
|---|---|
| `GET /api/customreports` | the folders, the live reports with their definitions, the latest 200 log rows, and whether saving and running are on here |
| `GET /api/customreports?report=N` | one report and its 100 latest log rows |
| `POST /api/customreports` | `{op: add, edit, delete, move, folder_add, folder_rename, folder_delete, ...}` |
| `POST /api/customreports/run` | `{report_id, target: fleet (repository reports only), tag or instance, instance_id, tag, from, to, params}` |
| `GET /api/community?instance=N&database=D[&fresh=1]` | the tools for the instance's engine, each with its state (ready, note, needs, not_checked, demo), its needs and notes with the way to get each, its form's preset values; the instance's own needs; `checked_at` (kept 60 s; `fresh=1` is Look again); the instance's log |
| `POST /api/community/params` | `{instance_id, tool, database}`: a procedure's form and help |
| `POST /api/community/run` | `{instance_id, tool, database, params, timeout_secs, text, query_name}`; each run's `declined` is true when the procedure turned it down in its own listed words (stored `failed`) |
| `POST /api/community/glenn/parse` | `{text}`: the queries of a diagnostic script |
| `GET /api/community/sample?instance=N&tool=T` | a demo instance's stored sample of the tool: its mark (`kit`, `version`, `version_date`, `captured_at`, `server`, `line`, `mark`, `page`: the instance tab of the subject), `database`, `params` (the stored run's), `param_doc` (the procedure's own; help text for the MIT kits only), `dropped` and `cut` (what was left out), `scrubbed` (the test server's own names replaced, by the fixed word put in), `sets`; 400 for an unknown tool or one of the other engine, 404 for an instance that is not a demo instance without a login and for a tool without a sample (with why) |

A POST carries the `X-Pgvigil` header (a cross-site form cannot set it) and the session cookie. A run on a tag goes to
at most 20 instances of the report's engine, four at a time, within 62 s in all (the serve answers within 75 s): an
instance not answered by then fails with the deadline.
