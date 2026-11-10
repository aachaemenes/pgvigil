# Jobs

The Jobs tab of an instance shows its scheduled jobs the way DBA Dash shows SQL Server Agent jobs: one line per job,
and for the job picked, its runs and the changes to its definition. It works the same on both engines:

| Engine | Scheduler | Collection | Read every |
|---|---|---|---|
| PostgreSQL | pg_cron (`cron.job`, `cron.job_run_details`) | `jobs` | 1 minute |
| PostgreSQL | pgAgent (`pgagent.pga_job`, `pga_schedule`, `pga_jobstep`, `pga_joblog`, `pga_jobsteplog`) | `jobs` | 1 minute |
| SQL Server | SQL Server Agent (msdb: `sysjobs`, `sysjobsteps`, `sysschedules`, `sysjobhistory`) | `mssql_jobs` | 5 minutes |

OS cron and Windows Task Scheduler cannot be seen from SQL and are out of scope.

## The jobs grid

One line per job:

| Column | What it shows |
|---|---|
| job | the job's name; a click opens its History and Changes under the grid |
| enabled | `no` when the job (pg_cron: `active`) is off |
| schedule | pg_cron's cron text; pgAgent's schedule is in the job's definition (Changes); SQL Server's schedules in words ("every day every 15 minutes between 00:00 and 23:59:59"), on the server's clock |
| last run, outcome | when the newest run started and how it ended; a fill only when it failed (red) or was cancelled (amber) |
| last failure | when the newest failed run started, the step that failed and its message: the first 200 characters on one line, the whole text on a click |
| next run | pg_cron: pgvigil's own reading of the schedule; pgAgent: its own `jobnextrun`; SQL Server: the Agent's |
| runs, failures | the runs that started in the page's range, and how many failed |
| changed | the number of changes to the definition in the range, and when the last one was seen |
| dropped | a job no longer on the server is kept, marked with the time the read first missed it |

The PostgreSQL page adds the scheduler, database, user and command, a link to the job's own page, and every run of
the range under the grid.

## History

For the picked job, the runs that started in the range (the newest 1,000 listed; the counts above them cover every run): start, duration, outcome, the
step that failed, the message, and on SQL Server msdb's error number, severity and the retries of the run's steps.
A SQL Server job running now is the first row.

- **SQL Server:** the outcome row of a run (msdb's step 0) carries the step that failed in that run: the last step
  row of the run with the run's own status, its name, its message, `sql_message_id` and `sql_severity`. DBA Dash keeps
  the step's message behind "View Steps"; pgvigil puts it on the run.
- **pg_cron:** `job_run_details.status` and `return_message`.
- **pgAgent:** the run's status from `pga_joblog`; for a failed run the step that ended it (`pga_jobsteplog`: the
  first failed step) with its result and output.

Above the grid: succeeded, failed, cancelled, running long (a finished run over twice the median of the job's
successful runs in the range) and that median; then a strip of the runs' durations, oldest first, a failed or
cancelled run drawn hollow with an `x` above it.

## Changes

On every read each job's definition is hashed; a hash that differs from the one kept stores a new version, with
the fields that changed, old against new. The definition is:

- **SQL Server:** name, enabled, owner, category, description, start step, notifications (e-mail, page, event log,
  delete the job, and the operators), each schedule (enabled, and its terms in words) and each step (name,
  subsystem, database, command, on success, on failure, retries and their interval, output file, proxy).
- **pg_cron:** name, schedule, command, database, username, active.
- **pgAgent:** name, enabled, description, host agent, each schedule (enabled, start, end, minutes, hours, weekdays,
  month days, months) and each step (enabled, kind, database, connection string, on error, code).

A job the read no longer lists gets a version marked dropped, with the time of that read; a job that comes back gets
another. The first version of a job is "first seen", not a change. A version in the page's range opens by itself.

DBA Dash keeps the SMO script of a job and diffs it as text (Job DDL History); pgvigil keeps the definition as
fields, so a change reads as "steps / step 02 / command: old -> new". Like DBA Dash, it cannot say who made a
change, and a change undone between two reads is not seen.

### Passwords

A step's command, a connection string and a run's output can carry a password. Before a job row leaves the collector
(both engines; `MaskJobText` in internal/collect/jobs.go) the value of each of these is replaced by `<masked>`:
`PASSWORD = '...'` and `SECRET = '...'`; any `@...password`, `@passwd`, `@...pwd` or `@...secret` parameter
(`sp_addlinkedsrvlogin`, `sp_addlogin`); a `key = value` whose key holds password, passwd, pwd or secret (connection
strings, libpq keywords; quoted or not, spaces or not); the `user:password@` of a URI; `-P` (sqlcmd, bcp), `-Password`,
`-pw`, `-pwd`; the string given to `ConvertTo-SecureString`; the password of `net use \\host\share <password>`;
dtexec's `/DE` and `/Decrypt`. The command is stored masked (in the job row and in every version). A password in any
other form is stored as read: keep secrets out of job steps (a credential, a proxy, a vault lookup).

### Known limits

- Outcome rows stored before migration 0072 carry no failed step: the step shows from the first read after it.
- When pg_cron or pgAgent is removed from a server, the jobs collection stops applying there and no read lists the
  jobs as gone: their last version stays "present". A server that keeps the scheduler but has no job left marks every
  job dropped.

## Rights

- **SQL Server:** a user in msdb with `db_datareader` (the collector asks per table and skips the read with the
  missing right otherwise). Azure SQL Database has no Agent.
- **pg_cron:** read on `cron.job` and `cron.job_run_details`; pg_cron's row security shows a login only its own jobs
  unless it has `bypassrls` or is a superuser.
- **pgAgent:** read on the `pgagent` schema's tables.

## Storage and retention

Runs stay in the existing run tables (`pgvigil.job_runs`, `pgvigil.mssql_job_runs`) and are purged with them.
`pgvigil.job_versions` (migration 0072) keeps a row per change, not per read, and goes with its instance.

## API

`GET /api/jobs/history?engine=pg|mssql&instance=<id>&from=&to=` is the grid; with `&scheduler=<pg_cron|pgagent|sqlagent>&job=<id>`
also the job's `runs`, `counts` and `changes`.

## Not proven

pg_cron and pgAgent are not installed on the proof's PostgreSQL sandbox: `scripts/proof-jobs-history.sh` proves the
pg_cron side over imported rows and pgAgent's SQL over a stand-in schema of the columns it reads. The SQL Server side
runs against a real Agent job the proof makes, fails, changes and deletes.
