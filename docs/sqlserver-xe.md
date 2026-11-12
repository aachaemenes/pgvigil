# SQL Server: Extended Events

Deadlocks, blocked-process reports, slow batches and cancelled requests are things a DMV snapshot misses: they happen between two reads. SQL Server records them through Extended Events sessions. pgvigil reads such sessions; it does not create them.

## The rule

pgvigil's monitoring login never creates, alters, starts, stops or drops an event session, and it could not: it holds VIEW SERVER STATE and VIEW ANY DEFINITION, and creating a session needs ALTER ANY EVENT SESSION. The sessions are created by the server's DBA from a script pgvigil prints. Where a session is there, pgvigil reads it. Where it is not, the page says `not installed` and names the script; nothing fails.

SQL Server's own sessions `system_health` and `AlwaysOn_health` are read and never touched.

## The four sessions

One small session per capture, named with the product and an install id, so each can be sized, stopped or dropped on its own and two pgvigil installs watching one server do not share a session.

| Session | Event | Target | Volume |
|---|---|---|---|
| `pgvigil_<id>_deadlocks` | `xml_deadlock_report` | ring buffer, 4 MB | rare |
| `pgvigil_<id>_blocked` | `blocked_process_report` | ring buffer, 4 MB | none until the server's blocked process threshold is above 0 |
| `pgvigil_<id>_slow` | `rpc_completed`, `sql_batch_completed` over a threshold (1 s unless changed), and the single statements over it | event file, 50 MB x 4 files, rollover | the one high-volume capture |
| `pgvigil_<id>_attention` | `attention` | ring buffer, 1 MB, and an event counter | one per cancelled request |

The slow session leaves out pgvigil's own connections (program name `pgvigil`). Its event file has no path: SQL Server writes it to its own log directory, beside `system_health`'s. All four start with the instance (`STARTUP_STATE = ON`).

Why the slow session also takes `sql_statement_completed` and `sp_statement_completed`: SQL Server gives a batch or a procedure call's completion event no query hash (the `query_hash` action reads 0 there). The statement's own event carries it, so pgvigil fills a completion's query hash and plan hash from the longest statement it ran; they are the hashes Query Store and `sys.dm_exec_query_stats` show. The statement events use the same duration threshold, so they add at most one event per slow statement. `@slow_statements = 0` in the script turns them off, and the hashes with them.

## Print the script, hand it to the DBA

```
pgvigil mssql-xe -print -install-id prod1 > pgvigil-xe.sql
```

`-install-id` is 1 to 20 lower-case letters and digits (default `main`). `-form` is `server` (the default: SQL Server on a machine, a VM or a container, and Amazon RDS for SQL Server), `azuresqlmi` or `azuresqldb`.

The script is one batch, run in `master` by a login that may create event sessions. It has a settings block at the top for the DBA:

```sql
DECLARE @slow_ms          int = 1000;   -- a completion slower than this is captured (milliseconds)
DECLARE @slow_statements  bit = 1;      -- also the single statements over @slow_ms (they carry the query hash)
DECLARE @slow_file_mb     int = 50;     -- the size of one event file
DECLARE @slow_files       int = 4;      -- files kept; the cap on disk is size x files
DECLARE @slow_memory_kb   int = 4096;   -- the session's buffer memory
DECLARE @deadlock_kb      int = 4096;   -- ring buffer sizes (KB)
DECLARE @blocked_kb       int = 4096;
DECLARE @attention_kb     int = 1024;
```

What the script does and does not do:

- It creates a session only when no session of that name exists, and says `created`, `NOT created` or `exists, left as it is` for each.
- It starts a session that is stopped.
- It changes no server setting and drops nothing.
- At the end it shows the server's `blocked process threshold (s)` and what the value means, and lists the four sessions with their state.

To change a setting later, drop the sessions and run the script again:

```
pgvigil mssql-xe -print -drop -install-id prod1
```

The drop script drops the four sessions of that install id and nothing else. The event files a slow session wrote stay in the log directory.

### The blocked process threshold

SQL Server raises a blocked-process report only when the server's `blocked process threshold (s)` is above 0; the default is 0. Setting it is a server-wide change and the DBA's own step, never pgvigil's:

```sql
EXEC sys.sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sys.sp_configure 'blocked process threshold (s)', 15; RECONFIGURE;
```

A report is raised for a task blocked that many seconds and again each time that many more pass; 5 is the lowest value SQL Server honours. The Blocked reports tab shows the value the server uses and says so when it is 0.

### Azure SQL Database and Managed Instance

`-form azuresqldb` prints database-scoped sessions (`ON DATABASE`, `database_xml_deadlock_report`), every target a ring buffer, to run in the database pgvigil connects to. `-form azuresqlmi` prints server-scoped sessions with a ring buffer for the slow capture too (an event file on a Managed Instance must be a blob URL with a credential). **Both forms are not proven**: they were written from the documentation and have not been run against either service, and the script says so in its header.

## The reader: `mssql_xe`, every minute

For each capture the reader looks for a session named `pgvigil_<any id>_<capture>` and stores one of three states:

- `running`: the session is defined and started. It is read.
- `stopped`: the session is defined and not started (someone stopped it, or it was created with `STARTUP_STATE = OFF` and the instance restarted). Nothing is captured until the DBA starts it.
- `not installed`: no session of that name.

A stopped or missing capture becomes a finding only after two reads in a row have seen it, so the first read after a restart or a failover does not raise one.

How it reads:

- **From a cursor.** An event file is read past the last block read (the file name and offset); a ring buffer past the newest event read (its time and sequence number). A batch of events and the cursor's new position are stored in one repository transaction, so an event is stored once: a run that dies between two batches loses nothing and repeats nothing. A read takes at most 1,000 events per batch and stops in time for the next run, which goes on from the cursor.
- **Nothing is shredded on the server.** The reader takes the XML as text (a ring buffer in pieces of 16,000 characters, read once into a variable so the pieces are one consistent copy) and takes it apart on the collector's host. It runs no XQuery on the monitored server.
- **After a rollover.** The cursor names a file; while that file exists the read goes on through the newer files. When it is gone (the files rolled past it while the collector was down), the reader reads the set again from its oldest file and passes over what it already stored; events that were in the deleted files and never read are lost, and the state row's note says the fallback happened.
- **A deadlock is one row whatever session carried it.** Its key is its time and its graph. When the product's deadlock session is stopped or dropped and the reader goes back to `system_health`, the deadlocks it already stored are not stored again.
- **A control character does not cost the read.** A statement's text can hold a character XML forbids (a `CHAR(1)` in a literal). The reader replaces it with U+FFFD before it parses, so one such event does not fail a whole ring buffer.
- **Unknown events are counted.** An event in a pgvigil session that the reader has no parser for is counted on the state row, not dropped silently.

What is stored, each event once:

- **Deadlocks**: the graph XML whole, the victim, and each process with its session, login, host, program, database, statement, and the object and lock mode it waited on; the resources with their owners and waiters.
- **Blocked-process reports**: the blocked and the blocking process, the wait resource and time, the blocking process's status and its input buffer (the head's last statement).
- **Slow completions**: duration, CPU, reads, writes, rows, the result (OK, Error, Abort), the statement or procedure, the login, host, program and database, and the query hash and plan hash as `0x` text.
- **Attentions**: the session, the statement that was cancelled, who ran it. The event's own duration is the time the interrupt took, in microseconds; it is not how long the request had run, and the page labels it so.

### system_health and AlwaysOn_health

- On a server with no running deadlock session of pgvigil, the reader takes the `xml_deadlock_report` events from `system_health`'s event files instead, and marks each deadlock as read from there. `system_health` keeps a limited history and shares its files with many other events, so a busy server can roll a deadlock out before it is read; the dedicated session does not have that problem.
- Where Always On is enabled, the reader takes `AlwaysOn_health`'s replica state changes, replica manager state changes, lease expiries, availability group DDL and reported errors, each with its time. An error is filed under a family by its number: lease (19407, 19419, 19421, 19422, 19423, 19424), connection (35201, 35202, 35206), role (1480, 19406), data movement (35264, 35265); an informational message of no family is not kept. A role change is marked a failover when a secondary is told to take over, when a primary loses its role, or when a `FAILOVER` statement commits. A start of the instance is not a failover.
- The first read of either session goes through its whole history, 20,000 events per batch; events older than 45 days are not stored.

Neither session is ever started, stopped or altered. An `AlwaysOn_health` session that is not running is shown as stopped and left alone.

## Pages

- **Deadlocks**: the deadlocks of the range; one opened as its processes and resources with the victim marked; the graph as an `.xdl` download that SSMS opens.
- **Blocked reports**: one row per blocking statement, the blocking side first; the reports of one statement. Each report shows both sides' isolation level, transaction name, last batch started and completed, last transaction started, log used and priority. Over the range the tab shows sp_HumanEventsBlockViewer's findings (checks 1-10, 1000, 1001, in the procedure's words) and the blocked wait per lead blocker (each blocked wait walked to its chain's lead), object, database and blocking login, application and host. Where no pgvigil capture runs, system_health's QUERY_PROCESSING `blockingTasks` are read instead; system_health writes them every five minutes, so a block shorter than that can be missed. The contended object is named from pgvigil's waiting-tasks read of the same lock, else the procedure's `Unresolved` label.
- **Slow queries**: by statement shape (a procedure call by its procedure; a statement sent through a driver's wrapper such as `sp_executesql` or `sp_prepexec` by the statement inside it; anything else by its text without literals; a call by handle, `sp_execute`, has no text and is named by its query hash): count, total and worst duration; the events of one shape; a chart of completions over time with its table. The **Attentions** section is below it. Not proven: these pages in a browser (the proof's part P grades their API; `scripts/proof-a11y.sh` renders them for accessibility only).

## Findings

| Finding | Severity |
|---|---|
| deadlocks in the last hour | warning; more than ten: critical |
| blocked-process reports naming the same head statement (two or more in the last hour) | warning |
| a capture is not installed (one row per instance, after two reads) | info |
| a capture is stopped (one row per instance, after two reads) | warning |
| the ring buffer dropped events (the session dropped events, or events left a ring buffer between two reads) | warning |
| an availability replica changed role or state in the last hour | warning; a failover: critical |

## Query text

The instance's `query_text` policy applies. Under `normalized`, statements are stored without literals and the deadlock graph and the blocked-process report XML are not stored (they carry raw text). Under `none`, no statement text is stored at all: slow events group by procedure name only and blocked reports are not grouped by statement. A shape treats a double-quoted token as an identifier; a client that runs with `QUOTED_IDENTIFIER OFF` and writes string literals in double quotes keeps them in its shapes.

## What it costs the monitored server

Each read is two small catalog and DMV queries, one read per ring buffer (4 MB at most, 1 MB for attentions) and one `sys.fn_xe_file_target_read_file` call per batch of an event file, from an offset. The sessions themselves are the DBA's to size: the three ring-buffer sessions hold rare events; the slow session's cost follows `@slow_ms`. A threshold of a few milliseconds on a busy server writes every statement to disk: keep it at a value that names the slow ones.

## Sources

The session definitions are pgvigil's own text. Their shape follows DBA Dash 4.24.1 (MIT; `SQLDeadlockSession.sql`, `SQLSlowQueriesEventFileSession.sql`, `SQLSlowQueries.sql`, `SQLDeadlockSessionAzure.sql`: a dedicated deadlock session, the slow-query events, actions and predicate, the event file read from a resume cursor, the Azure forms) and PerformanceMonitor at commit 65bdb5f (MIT; one session per capture, the blocked-process and attention sessions, the event counter beside the attention ring buffer). Both are named in THIRD-PARTY-NOTICES.md.

## Proof

`scripts/proof-mssql-xe.sh` runs against a SQL Server container and a PostgreSQL sandbox. It proves: a server without the sessions gives four `not installed` rows and no error, with `system_health`'s deadlocks read; the monitoring login cannot run the script (the error is shown) and the script says `NOT created`; the script run by `sa` creates and starts four sessions and a second run leaves them; a provoked deadlock is stored once with its victim and both statements, and still once after the reader goes back to `system_health`; a control character inside a statement's text is stored as U+FFFD; the collector's role reads its cursor through its own door; a blocked-process report holds the head's statement (the threshold lowered for the proof and put back); a slow batch is stored with its duration and its hashes, the query hash found in `sys.dm_exec_query_stats`; a cancelled query is stored as an attention; a second read stores nothing twice; 2,000 slow events across file rollovers are stored once each, the cursor moving per batch; a cursor on a vanished file falls back without storing anything twice; a stopped session is `stopped` and becomes a finding at the second read; `AlwaysOn_health` is read on an availability group's primary; the server's other sessions are unchanged; the printed drop script drops exactly the four.

Proven on SQL Server 2017, 2019, 2022 and 2025 in Linux containers ([versions](sqlserver.md#versions)). Not proven: the Azure SQL Database and Managed Instance forms, SQL Server 2016, Amazon RDS, a Windows server's event file paths, and a live ring buffer overrun (the count of events that left a buffer between two reads is checked as arithmetic on the repository).
