# SQL Server: actions

pgvigil reads. On a SQL Server instance it can also do four things, and only when the instance is set up for them: end a session, start an Agent job, stop an Agent job, and remove one plan from the plan cache. This page is how that door works and how to open it.

The door is off by default. It is off for an instance until that instance has a separate actions login AND a list that names the action.

## What it can do

| Action | Statement sent | The actions login needs |
| --- | --- | --- |
| `kill` | `KILL <session id>` | `ALTER ANY CONNECTION` |
| `job_start` | `EXEC msdb.dbo.sp_start_job @job_id = '<id>'` | `SQLAgentOperatorRole` in msdb |
| `job_stop` | `EXEC msdb.dbo.sp_stop_job @job_id = '<id>'` | `SQLAgentOperatorRole` in msdb |
| `plan_evict` | `EXEC master.dbo.pgvigil_evict_plan @plan_handle = <handle>`, or `DBCC FREEPROCCACHE (<handle>)` where the server has no such procedure; the handle is sent as a varbinary parameter | `EXECUTE` on the signed procedure below (documented), or `ALTER SERVER STATE` (the alternative, with what it gives) |

Nothing else. The read login never sends any of these.

## The actions login

A login of its own, with these grants and no more. Grant only the part you will use.

```sql
CREATE LOGIN [pgvigil_actions] WITH PASSWORD = '<a long random password>';

-- for kill:
GRANT ALTER ANY CONNECTION TO [pgvigil_actions];

-- for job_start and job_stop:
USE msdb;
CREATE USER [pgvigil_actions] FOR LOGIN [pgvigil_actions];
ALTER ROLE SQLAgentOperatorRole ADD MEMBER [pgvigil_actions];
```

pgvigil refuses an actions login that is `sysadmin` or holds `CONTROL SERVER`, and one that is the read login. `SQLAgentOperatorRole` is the smallest role SQL Server has for starting and stopping a job the login does not own, and it carries more than that: its member can also read every local job with its history, enable or disable local jobs and schedules, and delete a local job's history. pgvigil sends none of those; weigh them before you grant the role.

### For plan_evict: a certificate-signed procedure (the documented grant)

`DBCC FREEPROCCACHE (<plan handle>)` needs `ALTER SERVER STATE`, a right far wider than one plan: see the alternative below. The documented route keeps that right off the actions login. A procedure in master removes the one plan it is given; a certificate signs it, the certificate's own login holds `ALTER SERVER STATE`, and the actions login may only `EXECUTE` the procedure. Run as a sysadmin, once per server:

```sql
USE master;
CREATE CERTIFICATE pgvigil_evict_cert ENCRYPTION BY PASSWORD = '<a long random password>'
  WITH SUBJECT = 'pgvigil: remove one cached plan', EXPIRY_DATE = '2036-01-01';
GO
-- removes the plan the handle names, and nothing else; a handle with no plan in the cache is an error
CREATE PROCEDURE dbo.pgvigil_evict_plan @plan_handle varbinary(64)
AS
BEGIN
  SET NOCOUNT ON;
  IF NOT EXISTS (SELECT 1 FROM sys.dm_exec_cached_plans WHERE plan_handle = @plan_handle)
    THROW 50001, 'no plan under this handle in the plan cache', 1;
  DBCC FREEPROCCACHE (@plan_handle) WITH NO_INFOMSGS;
END;
GO
ADD SIGNATURE TO dbo.pgvigil_evict_plan BY CERTIFICATE pgvigil_evict_cert WITH PASSWORD = '<the password above>';
CREATE LOGIN pgvigil_evict_signer FROM CERTIFICATE pgvigil_evict_cert;
GRANT ALTER SERVER STATE TO pgvigil_evict_signer;
CREATE USER [pgvigil_actions] FOR LOGIN [pgvigil_actions];   -- once: the actions login in master
GRANT EXECUTE ON dbo.pgvigil_evict_plan TO [pgvigil_actions];
```

Changing the procedure drops its signature: sign it again after any `ALTER PROCEDURE`. pgvigil sends the procedure when `master.dbo.pgvigil_evict_plan` exists, and `DBCC FREEPROCCACHE` itself when it does not.

**The alternative, the direct grant** (`GRANT ALTER SERVER STATE TO [pgvigil_actions];`). It works, and it gives the actions login three things pgvigil never uses:

- it reads every session's statement text and plan (ALTER SERVER STATE includes VIEW SERVER STATE), so the actions login is no longer a login that cannot see other sessions;
- it can empty the whole plan cache (`DBCC FREEPROCCACHE` with no handle), and every query on the server compiles again;
- it can reset the wait and latch statistics (`DBCC SQLPERF`), which breaks the wait history of every monitor reading them, pgvigil's included.

The Actions log tab says, for an instance whose list names `plan_evict`, whether its actions login holds VIEW SERVER STATE and ALTER SERVER STATE and whether it may run the signed procedure. Not offered on Azure SQL Database (there `DBCC FREEPROCCACHE` needs `##MS_ServerStateManager##` and empties the plans of every database of an elastic pool); not proven on Amazon RDS or Managed Instance.

To take the door away again:

```sql
USE msdb;
DROP USER [pgvigil_actions];
USE master;
DROP LOGIN [pgvigil_actions];
```

## Configuration

```yaml
instances:
  - name: sales-sql01
    engine: sqlserver
    dsn: env:SALES_SQL01_DSN
    actions_dsn: env:SALES_SQL01_ACTIONS_DSN   # env: or file: only, never inline
    actions: [kill, job_start, job_stop, plan_evict]   # empty or absent = nothing
```

- `actions_dsn` is the actions login's connection string. It must come through `env:` or `file:`.
- `actions:` is the allow list. An action it does not name is off, even with an `actions_dsn`.
- An `actions:` list without an `actions_dsn`, an unknown action, or an `actions_dsn` equal to the `dsn` is refused when the file is read.
- Actions need the UI login. A server started with `-no-login` has no actions.

## How an action runs

1. **The button.** Kill is offered only on a live range (a preset range that ends now): there it is on every session row of the newest Running queries snapshot while that snapshot is at most 5 minutes old (DBA Dash's kill window), and as `kill this head` on each holder head of the blocking chain tree, and an older snapshot offers no Kill and the page says why. A past range, or an `at=` link widened to the hour before it, offers no Kill. Before the dialog opens, the button reads the live session and refuses when its login or login time is not the row's (the id went to a new session); Start and Stop are on a row of Jobs. A button is disabled, with the reason as its title, when the action is off for the instance.
2. **The preview.** The server reads the target through the read login and shows it: for a session its login, host, program, database, open transaction count and last statement; for a job its name, owner and current state. The statement that would be sent is shown too.
3. **The confirm step.** You type a reason (kept in the log) and the session id, or the job's name, or for a plan the code shown beside it (the first 8 hex digits of SHA-256 over its whole handle: a handle's own last digits are zero padding, the same for nearly every plan). The request carries the values you were shown.

For `plan_evict` the button is on each cache entry of a Plan cache row (Cached plans). The preview reads the plan by its handle: its kind (objtype), what it is the plan of, its compile time, how many statements it holds (each compiles again at its next run: a procedure's plan holds all its statements), its uses and size, the route (the signed procedure or the direct statement), and the batch's first 400 characters under the instance's `query_text` policy `full` only. The run reads the plan again and sends nothing when it is gone or is now another plan (another kind or compile time), refuses a SQL handle (it names no plan), and reads it back after the statement: the log says 'gone' or 'compiled again at <time>'.
4. **The check.** The server reads the target again. A session id whose login or login time differs now belongs to another session: the one you saw has ended and its id was reused. It is refused. A job whose name differs is refused.
5. **The statement.** It goes through the actions login. What the server answers is kept.

A session is never killed from the UI when it is a system session, a session of pgvigil's read login, or a session of the actions login.

Whether the actions login holds the right for the statement is the server's to say. A login without `ALTER ANY CONNECTION` gets the server's own error (Msg 6102), and the attempt is logged as failed with that message.

Both connections are open and the actions login is checked before the last read of the target, so that read and the statement are two round trips apart. A session id reused inside that gap would not be noticed. That is the cost of keeping the actions login unable to read other sessions.

A kill rolls the session's open transaction back. A long transaction takes about as long to roll back as it took to run, and the session stays visible in that state until it is done.

## verify_backup (task 301b)

RESTORE VERIFYONLY of one backup set from the backup history's grid (a set's Verify, in its right-click menu): it
reads the backup file(s) and checks the set can be restored, with CHECKSUM where the set has checksums. Off unless
the instance's `actions:` list names `verify_backup` - and on the site's switch list it says what it opens: **it gives
the actions login CREATE DATABASE: it can restore a copy of any database whose backup file the SQL Server service
account can read** (as that login, under a new name, owned by it). RESTORE VERIFYONLY itself creates no database and
writes no restorehistory row.

The grant, in master only (the narrower of the two forms that work; never dbcreator, never ALTER ANY DATABASE -
pgvigil refuses a login that holds either, as it refuses sysadmin and CONTROL SERVER):

    USE master;
    CREATE USER pgvigil_actions FOR LOGIN pgvigil_actions;
    GRANT CREATE DATABASE TO pgvigil_actions;

How it runs: the request carries the set's backup_set_uuid and what Preview showed; the read login reads the set
again (its database, type, finish, disk files, position, checksums, size) and any difference refuses; RESTORE HEADERONLY of the file and
position (on the actions login) must name the set's uuid, else the file now holds another backup set; then RESTORE
VERIFYONLY with the paths and the position as parameters (the audit keeps the statement with no path in it). The
verify runs detached from the request, bounded by `verify_timeout` (top level, default 2h), one per instance; the
audit writes `started`, then `done` or `failed` with the server's own words ('The backup set on file 1 is valid.'),
`cut by shutdown` when serve stops under it, and `ended unknown` for a verify that has no end while no verify holds
its instance's lock (serve was killed under it: its session, and the lock, are gone) - looked for at serve's start
and every hour, whatever the row's age. One verify per instance is a session advisory lock on the repository,
held on a connection of its own for the run: behind a connection pooler in transaction mode (PgBouncer
`pool_mode = transaction`) a session lock does not hold, so serve's repository DSN names the server or a session-mode
pool. Where the read login holds VIEW SERVER STATE, it looks every minute for the verify's session: when the
session no longer runs the RESTORE twice in a row (the server restarted, failed over or ended it), the verify ends
`failed` with those words; without that right a lost connection is seen only at `verify_timeout`. A refused attempt
(a second click while one runs, the wrong typed name) writes `refused` and sends nothing; the grid's last verify
shows the newest verify that was sent. While serve stops, a new verify is refused ('serve is stopping').
Not offered: a URL, tape, virtual-device or NUL backup, password-protected media, an encrypted backup.

## The log

Actions run only on an instance of `pgvigil.yaml` (its `dsn`, `actions_dsn` and `actions:`); on an instance added in Admin > Instances every action is off with 'actions run only on an instance of pgvigil.yaml (dsn, actions_dsn, actions:); move it there and remove it from Admin > Instances', so `pgvigil.actions_log` keeps no door column.

Every attempt is written to `pgvigil.actions_log` in the repository before the reply is sent: the UI user and their address, the instance, the action, the statement, the target (session id, login, program and host, or the job's name and id), the reason, the outcome and the server's message.

| Outcome | Meaning |
| --- | --- |
| `done` | The statement was sent and the server accepted it. |
| `refused` | A check said no. Nothing was sent. |
| `failed` | The statement was sent and the server refused it. Its message is in the row. |

Before anything is sent the server checks that the log can be written: the audit login answers and may call the log's function (a repository not yet migrated has none, and the action is refused with that reason). A row that still fails after the statement was sent is reported in the reply and written to the server's own log with its outcome. The log is shown on the instance's Actions log tab, with what is on for the instance. Rows are written through one function and nobody but the repository's owner can change or delete them. A request without a UI session never reaches the door (401) and is not logged: there is no user to name.

The table is the one PostgreSQL's cancel and terminate use; a row says which engine it belongs to.

## Proof

`scripts/proof-mssql-actions.sh` runs against a SQL Server container with SQL Server Agent and a PostgreSQL sandbox, through the API of a running server as a signed-in user. Its actions login holds `ALTER ANY CONNECTION` and `SQLAgentOperatorRole` and nothing else.

- A kill of the proof's own sleeping session: gone on the server, one log row with the statement and the outcome.
- Refused, and logged: another login's values for the session id, an action not on the list, an instance without an `actions_dsn`, a system session, the read login's and the actions login's own sessions, an actions login that is the read login, a `sysadmin` actions login, a wrong typed confirmation.
- A login without the right cannot kill or start a job: the server's own error is shown and logged.
- A job the proof creates is started and stopped, with the log rows.
- Everything the proof made is dropped.

Proven on SQL Server 2017, 2019, 2022 and 2025 in Linux containers ([versions](sqlserver.md#versions)). Not proven: a Windows login as the actions login (task 144), Managed Instance, RDS (task 165).
