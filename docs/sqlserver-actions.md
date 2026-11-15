# SQL Server: actions

pgvigil reads. On a SQL Server instance it can also do five things, and only when the instance is set up for them: end a session, and start, stop, enable or disable an Agent job. This page is how that door works and how to open it.

The door is off by default. It is off for an instance until that instance has a separate actions login AND a list that names the action.

## What it can do

| Action | Statement sent | The actions login needs |
| --- | --- | --- |
| `kill` | `KILL <session id>` | `ALTER ANY CONNECTION` |
| `job_start` | `EXEC msdb.dbo.sp_start_job @job_id = '<id>'` | `SQLAgentOperatorRole` in msdb |
| `job_stop` | `EXEC msdb.dbo.sp_stop_job @job_id = '<id>'` | `SQLAgentOperatorRole` in msdb |
| `job_enable` | `EXEC msdb.dbo.sp_update_job @job_id = '<id>', @enabled = 1` | `SQLAgentOperatorRole` in msdb |
| `job_disable` | `EXEC msdb.dbo.sp_update_job @job_id = '<id>', @enabled = 0` | `SQLAgentOperatorRole` in msdb |

Nothing else. The read login never sends any of these.

## The actions login

A login of its own, with these grants and no more. Grant only the part you will use.

```sql
CREATE LOGIN [pgvigil_actions] WITH PASSWORD = '<a long random password>';

-- for kill:
GRANT ALTER ANY CONNECTION TO [pgvigil_actions];

-- for job_start, job_stop, job_enable and job_disable:
USE msdb;
CREATE USER [pgvigil_actions] FOR LOGIN [pgvigil_actions];
ALTER ROLE SQLAgentOperatorRole ADD MEMBER [pgvigil_actions];
```

pgvigil refuses an actions login that is `sysadmin` or holds `CONTROL SERVER`, and one that is the read login. `SQLAgentOperatorRole` is the smallest role SQL Server has for starting and stopping a job the login does not own, and it carries more than that: its member can also read every local job with its history, enable or disable local jobs and schedules, and delete a local job's history. Of those pgvigil sends only `job_enable` and `job_disable`, when the list names them, and only in the one form the role may send: `sp_update_job` with the job's id and `@enabled` and nothing else (Microsoft's "SQL Server Agent fixed database roles": "Only the parameters that specify the job or schedule name or identifier and the `@enabled` parameter can be specified by members of SQLAgentOperatorRole"). Weigh the rest before you grant the role.

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
    actions: [kill, job_start, job_stop, job_enable, job_disable]   # empty or absent = nothing
```

- `actions_dsn` is the actions login's connection string. It must come through `env:` or `file:`.
- `actions:` is the allow list. An action it does not name is off, even with an `actions_dsn`.
- An `actions:` list without an `actions_dsn`, an unknown action, or an `actions_dsn` equal to the `dsn` is refused when the file is read.
- Actions need the UI login. A server started with `-no-login` has no actions.

## How an action runs

1. **The button.** Kill is offered only on a live range (a preset range that ends now): there it is on every session row of the newest Running queries snapshot while that snapshot is at most 5 minutes old (DBA Dash's kill window), and as `kill this head` on each holder head of the blocking chain tree, and an older snapshot offers no Kill and the page says why. A past range, or an `at=` link widened to the hour before it, offers no Kill. Before the dialog opens, the button reads the live session and refuses when its login or login time is not the row's (the id went to a new session); Start and Stop are on a row of Jobs, and on the instance's own Jobs tab Disable on an enabled job and Enable on a disabled one (by the job's flag as last read). A button is disabled, with the reason as its title, when the action is off for the instance.
2. **The preview.** The server reads the target through the read login and shows it: for a session its login, host, program, database, open transaction count and last statement; for a job its name, owner and current state, and for Enable or Disable whether it is enabled now and whether it is a multiserver job. The statement that would be sent is shown too.
3. **The confirm step.** You type a reason (kept in the log) and the session id, or the job's name. The request carries the values you were shown.
4. **The check.** The server reads the target again. A session id whose login or login time differs now belongs to another session: the one you saw has ended and its id was reused. It is refused. A job whose name differs is refused. An enable or a disable is refused, with nothing sent, when msdb treats the job as a multiserver job - it came from a master server (`sysjobs.originating_server_id`, a target server's downloaded job: Msg 14274), it is in a multi-server category (Msg 14396), or it has a target server (this server is its master) - since only a sysadmin may change one there, the refusal naming which; or when it is already in the state asked.
5. **The statement.** It goes through the actions login. What the server answers is kept. After an enable or a disable the read login reads the job's flag again and the result says what it reads; the Jobs grid shows the change after the next jobs read.

A session is never killed from the UI when it is a system session, a session of pgvigil's read login, or a session of the actions login.

Whether the actions login holds the right for the statement is the server's to say. A login without `ALTER ANY CONNECTION` gets the server's own error (Msg 6102), and the attempt is logged as failed with that message.

Both connections are open and the actions login is checked before the last read of the target, so that read and the statement are two round trips apart. A session id reused inside that gap would not be noticed. That is the cost of keeping the actions login unable to read other sessions.

Disabling a job stops the Agent from starting it by its schedules; a run going on at that moment goes on (Stop ends it). Enabling it lets its schedules run it again; a schedule that is itself disabled stays off.

A kill rolls the session's open transaction back. A long transaction takes about as long to roll back as it took to run, and the session stays visible in that state until it is done.

## The log

Actions run only on an instance of `pgvigil.yaml` (its `dsn`, `actions_dsn` and `actions:`); on an instance added in Admin > Instances every action is off with 'actions run only on an instance of pgvigil.yaml (dsn, actions_dsn, actions:); move it there and remove it from Admin > Instances', so `pgvigil.actions_log` keeps no door column.

Every attempt is written to `pgvigil.actions_log` in the repository before the reply is sent: the UI user and their address, the instance, the action, the statement, the target (session id, login, program and host, or the job's name and id), the reason, the outcome and the server's message.

| Outcome | Meaning |
| --- | --- |
| `done` | The statement was sent and the server accepted it. |
| `refused` | A check said no. Nothing was sent. |
| `failed` | The statement was sent and the server refused it. Its message is in the row. |

Before anything is sent the server checks that the log can be written: the audit login answers and may call the log's function (a repository not yet migrated has none, and the action is refused with that reason); for Enable and Disable also that the log's CHECK names them (migration 0194: serve does not check the repository's version, so a binary ahead of its repository refuses them with that reason rather than send a statement it could not log). A row that still fails after the statement was sent is reported in the reply and written to the server's own log with its outcome. The log is shown on the instance's Actions log tab, with what is on for the instance. Rows are written through one function and nobody but the repository's owner can change or delete them. A request without a UI session never reaches the door (401) and is not logged: there is no user to name.

The table is the one PostgreSQL's cancel and terminate use; a row says which engine it belongs to.

## Proof

`scripts/proof-mssql-actions.sh` runs against a SQL Server container with SQL Server Agent and a PostgreSQL sandbox, through the API of a running server as a signed-in user. Its actions login holds `ALTER ANY CONNECTION` and `SQLAgentOperatorRole` and nothing else.

- A kill of the proof's own sleeping session: gone on the server, one log row with the statement and the outcome.
- Refused, and logged: another login's values for the session id, an action not on the list, an instance without an `actions_dsn`, a system session, the read login's and the actions login's own sessions, an actions login that is the read login, a `sysadmin` actions login, a wrong typed confirmation.
- A login without the right cannot kill or start a job: the server's own error is shown and logged.
- A job the proof creates is started and stopped, with the log rows.
- The same job is disabled and enabled again, `sysjobs.enabled` read back through the read login each time; a second disable is refused as already disabled with nothing sent; a login without `SQLAgentOperatorRole` gets the server's own error; a job seeded with a target server row, and the same job put in msdb's multi-server category (stand-ins for a multiserver job: the proof sets up no master server), are refused.
- Everything the proof made is dropped.

Proven on SQL Server 2017, 2019, 2022 and 2025 in Linux containers ([versions](sqlserver.md#versions)), except Enable and Disable: those rows run on the proof's one container (SQL Server 2022) and are not run yet. Not proven: a Windows login as the actions login (task 144), Managed Instance, RDS (task 165).
