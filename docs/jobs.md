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
| last run, outcome | when the newest run started and how it ended; coloured by the outcome (see Status and thresholds) |
| last failure | when the newest failed or cancelled run started (`(cancelled)` after the time when it was a cancel: a SQL Agent run_status 3, a PostgreSQL run aborted), the step that failed and its message: the first 200 characters on one line, the whole text on a click |
| next run | pg_cron: pgvigil's own reading of the schedule; pgAgent: its own `jobnextrun`; SQL Server: the Agent's |
| runs, failures | the runs that started in the page's range, and how many failed or were cancelled (one judge with the status: a cancel is a failure, as in DBA Dash); a job whose last run failed or was cancelled is listed first |
| changed | the number of changes to the definition in the range, and when the last one was seen |
| status | the job against its thresholds, and the door to them (see Status and thresholds) |
| dropped | a job no longer on the server is kept, marked with the time the read first missed it |

The PostgreSQL page adds the scheduler, database, user and command, a link to the job's own page, and every run of
the range under the grid.

### The range's runs: tiles and top 5

Above the grid, from the hourly statistics (the hours that started in the page's range, the job's own outcome rows):
tiles for the runs that failed or were cancelled (a cancel is a failure, as in DBA Dash), that succeeded, and the
retries attempted (SQL Server: the step retries msdb recorded in the range; pg_cron and pgAgent do not retry a run);
then the five longest jobs (by their longest run), the five most frequent and the five most failed. While the
instance's hours of the range are being built (after an upgrade, an import or a late read) the section says so.

## The fleet's Job status

The fleet's Jobs page lists every job of the instances in view (DBA Dash's root Jobs) with its status, its last failure
and success, the 24-hour and 7-day counts, and:

| Column | What it shows |
|---|---|
| running now | the job runs now, since when (SQL Agent: the newest read of msdb; pg_cron and pgAgent: a run without an end the newest read of the job still saw) |
| last run took | the last finished run's time |
| failure rate 7 days | the failed runs (a cancel a failure) over the finished runs of the hours that started in the last 7 days; `reading...` until the hourly statistics answer, `being built` while the instance's hours are, `not read: <why>` when the read failed - never 0 for a rate not read |

**Show** picks the rows: critical, warning and acknowledged (the default with more than one instance), all, the last
run failed or cancelled, the last run succeeded, running now, a failure rate over 50 % (7 days), disabled.

**Jobs by instance**, above the grid, counts per instance the jobs whose last run failed or was cancelled, whose last
run succeeded, that run now and whose failure rate is over 50 %; each count opens those jobs in the grid (Show and the
instance set, 'every instance' to go back).

## History

For the picked job, the runs that started in the range (the newest 1,000 listed; the counts above them cover every run): start, duration, outcome, the
step that failed, the message, and on SQL Server msdb's error number, severity and the retries of the run's steps.
A SQL Server job running now is the first row.

- **SQL Server:** the outcome row of a run (msdb's step 0) carries the step that failed in that run: the last step
  row of the run with the run's own status, its name, its message, `sql_message_id` and `sql_severity`. pgvigil puts the
  step's message on the run.
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
another. The first version of a job is "first seen", not a change.

### Versions and the job's script

Like DBA Dash's Job DDL History, every version also keeps the whole job as one script, written by the collector:

- **SQL Server:** `sp_add_job`, one `sp_add_jobstep` per step, one `sp_add_jobschedule` per schedule,
  `sp_add_jobserver`; one parameter per line. A command over the 8,000 characters read says so in the script.
- **pg_cron:** `cron.schedule_in_database` with a named argument per line (a job without a name: `cron.schedule`).
- **pgAgent:** the `DO` block pgAdmin writes: the job, an `INSERT` per step and per schedule.

A version is stored when the definition's fields change, and also when only the script does. A version kept before
migration 0094 has no script: the first read after it fills the newest version's script in place; older ones show
their definition as text instead, and the page says so. Each script carries the number of the format it was written
in: when a pgvigil upgrade writes scripts another way, the newest version's script is rewritten in place, not stored as
a new version of every job (the diff across that version then also shows the change of format).

What the script does not carry: pgAgent's job class (written as class 1) and its exceptions (`pga_exception`); a
change to either is not seen. On SQL Server it carries every parameter of the job, its steps (with `@flags`) and its
schedules that msdb holds, but not the job's target servers beyond the local one (multi-server administration).

Under the job's history the versions are listed with valid from / to; for the one picked:

| View | What it shows |
|---|---|
| Script | the script alone (code view), against the version before side by side, or inline (`-` / `+` lines, the words that changed boxed); Copy left / Copy right |
| Info | that version as the job's page: its fields, its steps and schedules as tables |
| Compare info | that version beside the one before, the same tables, each changed cell marked (tinted and `*`) |
| Fields | the changed fields, old against new |

### Status and thresholds

The SQL Server and PostgreSQL grids carry a status per job, judged against thresholds at three levels, as DBA Dash's
Agent Job Thresholds: the job's own, else the instance's, else the root's (every instance); a level without its own
row inherits the one above. Without any row the built-in rule holds: the last run failed = critical. The thresholds:
failed runs in 24 hours and in 7 days, failed steps (SQL Server) in 24 hours and 7 days, minutes since the last
failure, minutes since the last success, each with a warning and a critical value, and whether a failed last run is
a warning or critical. **Thresholds** in the status cell opens the three levels; Save writes the level (the old row is
ended and kept), Inherit ends it. Writing needs the UI login and the actions door's audit login, as acknowledgements do.

The value cells take the outcome's colour: last run and outcome red when failed, amber when cancelled or retried, green
when succeeded; failures red above 0 (not acknowledged) and green at 0; a step's last outcome and run likewise.

### Start and Stop

On SQL Server the grid's last column has Start and Stop (`sp_start_job`, `sp_stop_job`) through the actions door
([sqlserver-actions](sqlserver-actions.md)): disabled, with the reason, where the instance has no actions login.

## Configuration history

- **Change log, both engines:** every value that was replaced, with valid from / to. SQL Server keeps every value of
  `sys.configurations` a read saw (`pgvigil.mssql_config_history`, migration 0094; the values kept before it are carried
  over: the value before the last change has no start). PostgreSQL's comes from its setting history; on the
  Configuration page it sits beside the Best practice grid.
- **The fleet (SQL Server):** `sys.configurations` of every instance side by side, an option a column; a value that is
  not the one most instances run is amber with a `*` (in a tie every value is marked). Only the options that differ are
  shown unless every option is asked for.
- **Trace flags (SQL Server):** `mssql_traceflags` reads `DBCC TRACESTATUS(-1)` hourly: the flags on now, and each
  flag added or removed with the read that saw it. The first read is the baseline. A flag on for the collector's own
  session only is listed as such. The same read carries the day-one checks' verdict of each flag (the Checks page's
  Trace flags view and its findings, [SQL Server checks](sqlserver-checks.md)): no other collection reads
  `DBCC TRACESTATUS(-1)` (`mssql_tempdb` asks for 1117 and 1118 alone).

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
`pgvigil.job_versions` (migration 0072, the script since 0094), `mssql_config_history`, `mssql_trace_flag_history` and
`job_thresholds` keep a row per change, not per read, and go with their instance.

The jobs' hourly statistics (`pgvigil.job_stats_hourly`, migration 0139) keep, per job and UTC hour of a run's start,
the runs, successes, failures, retries and the total, longest and shortest duration of the job's OUTCOME rows only
(SQL Agent's step 0; a PostgreSQL run counts as its job's step 0). This departs from DBA Dash, whose `JobStats_60MIN`
keeps a row per step too: the step rows would be about three quarters of the hours (about 75 GB more over 730 days at
305 SQL Server instances of 30 jobs) and no page reads them yet; SQL Agent's and pgAgent's step rows, with a step chart
that reads them, are a later task. The hours are kept 730 days by default, their own age apart from `purge -days`
(`pgvigil.hours_retention`; `pgvigil purge -hours job_stats_hourly=<days>` changes it), measured at about 0.7 GB a month
for 200 SQL Server instances of 30 jobs [an estimate from the per-step measure: 2.9 GB a month with every step]. After the
upgrade to 0139 each instance's hours are built by its next jobs import that stores a run (about 2 seconds of building
an import, the newest week first) and by `pgvigil purge`, which builds every instance still waiting, each in its own
transaction; a history import from DBA Dash builds them once at its end. Until an instance's hours of the last 7 days
are built, the fleet Jobs page's four 7-day columns read `being built`. `-hours <table>=<days>` takes days and drops
the months the new age no longer keeps in the same run: a value lower than the stored one needs `-confirm` (the hours
cannot be rebuilt once their runs are purged), and `-dry-run` with it lists those months and changes nothing. A purge
scheduled as SQL alone (`SELECT pgvigil.purge(N)` from pg_cron) does not build the hours: schedule
`SELECT pgvigil.job_stats_heal_one(i) FROM pgvigil.job_stats_pending() i LIMIT 1` beside it (one instance a run, in its
own transaction).

## API

`GET /api/jobs/history?engine=pg|mssql&instance=<id>&from=&to=` is the grid; with `&scheduler=<pg_cron|pgagent|sqlagent>&job=<id>`
also the job's `runs`, `counts` and `changes` (each version with its `script`); without a job, `&part=cards` and
`&part=top` are the range's tiles and top 5 lists (read only by name). `GET /api/jobsreport?part=status&ids=` and
`?part=stats&ids=` are the fleet's Job status grid (`running_since`, `last_secs`; `failed_7d` beside the stats).
`GET /api/jobs/thresholds?instance=` the levels and each job's status; `POST /api/jobs/thresholds` sets a level or
makes it inherit. `GET /api/config/changes[?instance=]`, `GET /api/mssql/config/fleet`, `GET /api/mssql/traceflags[?instance=]`.

## Not proven

pg_cron and pgAgent are not installed on the proof's PostgreSQL sandbox: `scripts/proof-jobs-history.sh` proves the
pg_cron side over imported rows and pgAgent's SQL over a stand-in schema of the columns it reads. The SQL Server side
runs against a real Agent job the proof makes, fails, changes and deletes. `scripts/proof-job-ddl.sh` proves the
scripts, their diffs, the change log, the pivot and the trace flag history against a SQL Server container of its own.
Not proven: the page in a browser (`scripts/proof-a11y.sh` renders the tab for accessibility only); a real pg_cron (its script is built by the collector, the proof imports one); a SQL Server job with an operator notification (the proof makes no operator).
