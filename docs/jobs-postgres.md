# PostgreSQL: job actions, Running now, job exclusions and deadlocks

The PostgreSQL side of four things DBA Dash has for SQL Server Agent and SQL Server deadlocks: stopping and starting a job,
the jobs running now, leaving jobs out of the job checks, and a Deadlocks page. The Jobs page itself (the grid, the history,
the versions with their scripts and diffs, the thresholds) is [jobs](jobs.md).

## Stop and Run now

| Action | Scheduler | What is sent | Through |
| --- | --- | --- | --- |
| `job_stop` | pg_cron | `SELECT pg_cancel_backend(<the run's job_pid>)` | the actions login |
| `job_stop` | pgAgent | `SELECT pg_cancel_backend(<the pid of the session running the current step>)` | the actions login |
| `job_start` | pgAgent | `UPDATE pgagent.pga_job SET jobnextrun = now() WHERE jobid = <id>` (what pgAdmin's Run now does) | the actions login |

pg_cron has no run-now call: a pg_cron job runs at its schedule only, and its row says so.

**Off by default.** Both ride the actions door of [running queries](running-queries.md): an instance needs its `actions_dsn`
(the login `pgvigil_actions`, `pg_signal_backend` and nothing else) and, for the job actions, an `actions:` list that names
them. Cancel and terminate need no list; the job actions do:

```yaml
instances:
  - name: app1
    dsn: env:APP1_DSN
    actions_dsn: env:APP1_ACTIONS_DSN
    actions: [job_stop, job_start]     # either or both; nothing else is taken on a PostgreSQL instance
```

Run now also needs the actions login to set that one column, and no more:

```sql
GRANT USAGE ON SCHEMA pgagent TO pgvigil_actions;
GRANT SELECT (jobid, jobenabled, jobagentid), UPDATE (jobnextrun) ON pgagent.pga_job TO pgvigil_actions;
```

**What is checked before anything is sent**, through the instance's monitoring login, as the cancel button's checks are:

- **Stop on pg_cron:** the run is still running in `cron.job_run_details`, its `job_pid` is the one the row showed, that
  pid's backend started before the run did (a later backend that reused the pid is refused), it is a client backend with
  `application_name` `pg_cron`, the run's user and database, and no superuser (`pg_signal_backend` cannot reach one). A job
  run by a superuser cannot be stopped from here: run it as a login of its own. `cron.use_background_workers = on` is not
  supported by this action (the run's backend is then a background worker).
- **Stop on pgAgent:** pgAgent keeps no pid for a run. The run is still running in `pga_joblog`, its running step is a SQL
  step on this server (a batch step runs in the pgAgent host's shell; a step with its own connection string may run on
  another server: both refused), and exactly one active session of the step's database runs the step's code and started
  it no earlier than the step (none or several = refused: stop it from Running queries). Stopping a step fails that step;
  the job then goes on or fails by the step's "on error".
- **Run now:** the job exists under the name shown, is enabled, is not running (`jobagentid` empty), and a pgAgent that may
  take it is connected (`pga_jobagent`, and its host where the job names one).
- Both logins reach the same server (`pg_postmaster_start_time()`), the actions login is no superuser.

**The dialog** shows the run or the job, asks for a reason (5 to 500 characters) and the job's name typed to confirm. An
attempt that reaches the instance's checks - past the UI login, the `X-Pgvigil` header, a well-formed body without a NUL
character, a PostgreSQL instance and a reachable audit login that may write it - writes one row in `pgvigil.actions_log`
(done, refused or failed), with the UI user, the client address, the reason, the job (`target`, and `target_id` =
`<scheduler>:<job id>`, with ` run <run id>` for a stop), the pid and the statement sent or that would have been; the
others are answered with their reason and write nothing. The instance's Jobs page lists the newest 200 under "Job
actions". Run now also refuses a standby (its job tables are the primary's copy) and an `actions_dsn` that connects to
another database than the instance's (Run now writes in that database).

## Running now

Under the jobs grid: every pg_cron and pgAgent run that the newest read of its job still saw running (a run that ended
since is gone at the next read, within a minute):

| Column | What it shows |
| --- | --- |
| started, running for | the run's start, and the time since |
| average | the job's average over its successful runs of the last 30 days, and how many |
| estimated end | the start plus that average; amber with "passed" when the run is over twice the average and 10 s more, with 3 runs or more behind it (the job report's rule) |
| current step | pgAgent: the step running now and since when |
| pid, db, run as | the run's backend (pg_cron's `job_pid`), database and user |
| checks | `left out` when an exclusion takes the job |
| action | Stop |

The Jobs grid gains two columns on PostgreSQL: the pg_cron schedule in words ("every 5 minutes", "at 04:10 every day",
"at minute 0 of hours 8 to 18 on Monday to Friday"; an expression it does not read is shown as it is) and Run now on a
pgAgent job.

## pgAgent's step log

The collection `job_steps` (every minute, where pgAgent is installed) reads `pgagent.pga_jobsteplog` - one row per step per
run, its outcome (`succeeded`, `failed`, `ignored` = a failure the step's "on error = ignore" passed over, `aborted`,
`running`), its result, its duration and its output (the first 4,000 characters, passwords masked as a job's text is) - into
`pgvigil.job_step_runs`. On the Jobs page, "pgAgent steps" opens each pgAgent job's steps over the page's range: runs,
succeeded, failed, ignored, aborted, the average and longest duration, the last outcome; and the step runs themselves.
A pgAgent job's failed steps now count in its status: the step thresholds of [jobs](jobs.md) (failed steps in 24 hours and
in 7 days) apply to pgAgent as they do to SQL Server Agent. pgAgent runs a job's steps in the order of their names.

## Leaving jobs out of the checks

DBA Dash's job exclusions: a pattern on a job's name (a pg_cron job without a name: its id) or its command, `*` for any
text and `?` for one character, any case (`tmp_*`, `*VACUUM*`), for every instance or for this one. A command pattern takes
pg_cron jobs only: a pgAgent job has no command of its own (its steps' code is not matched). A job it takes is left out of:

- its status against the thresholds (`job_status`: status `excluded`, the reason names the pattern);
- the job report's checks (`job_report_checks`: the Summary's Jobs column and the job findings);
- the overview's failed-job check (`job_failures`).

The grids still list the job and its runs, marked. The exclusions are written from the Jobs page (Leave out of the checks;
End) through `pgvigil.import_job_exclusion`, by the UI login and the actions door's audit login, as acknowledgements are; a
pattern of wildcards alone and a second copy of a live one are refused. A row is never changed: End closes it with who and
when (`pgvigil.job_exclusions` is its own history). PostgreSQL jobs only: SQL Server Agent's findings do not read them.

## Deadlocks

The instance's Deadlocks tab, from the deadlocks the log reader stores (`log_events`, kind `deadlock`: the server log's
`ERROR: deadlock detected` with its DETAIL lines, read by the `serverlog` or CloudWatch reader, [logs](logs.md)).
PostgreSQL writes, for each process of the cycle, `Process P waits for <mode> on <lock>; blocked by process Q.` and then
`Process P: <statement>`, in the cycle's order, the first being the process that found the deadlock and was cancelled.

| Part | What it shows |
| --- | --- |
| tiles | the deadlocks in the log in the range, pg_stat_database's deadlock counter over the same range (its rise between the range's own samples; more there than in the log: the reader is not reading this server's log, or entries were cut), the groups, the last |
| chart | every deadlock of the range per 5 minutes (per hour over a day or more) |
| by database, user, application, relation | a ring and a grid each; a deadlock counts once in each value its processes had |
| groups | one row per set of statement shapes (literals and numbers as `?`), relations and lock modes: its count, first, last, the latest's graph |
| deadlocks | the newest 500: the victim's pid, user, application and statement, the relations, the locks (with more than 500 in the range, the groups and the breakdowns read these 500, and the page says so) |
| the graph | the SQL Server page's drawing: each process a box with its statement's first line, the victim boxed VICTIM, each lock between them with who holds it and who waits for it; then the participants and the locks as grids |

What the log does not carry, and what pgvigil does instead:

- **The holder's mode.** A transaction lock's holder holds ExclusiveLock on its own transaction; any other lock's holder
  is shown as "a conflicting mode".
- **The relation.** Named from a lock on a relation, a page or a tuple (its OID, resolved through the tables collection),
  else from the victim's CONTEXT line (`while updating tuple (0,2) in relation "t"`), else from the statement's target
  (`UPDATE`, `DELETE FROM`, `INSERT INTO`, `SELECT ... FROM`, `LOCK`), marked "from the statement".
- **The application, and the other processes' user.** Not in the log prefixes the readers take. They come from the
  activity samples: the pid seen from 90 seconds before the deadlock to 5 seconds after; "not sampled" otherwise (a deadlock between short
  transactions is often not sampled: the activity collection reads once a minute). The victim's user and database are
  the log line's own.
- **The query-text policy.** Under `normalized` every number of the DETAIL lines is `?` and the lines are joined into one:
  pgvigil splits them again, names the processes by their place in the cycle (`process #1`, the victim the first) and
  keeps one lock per holder. Under `none` no detail is stored: a deadlock is its time, the victim's pid, user, database
  and sampled application, and it is not drawn.
- **A function's inner statement.** A deadlock inside a PL/pgSQL function shows the function call in DETAIL; the inner
  statement that took the lock is in the event's statement (the CONTEXT line's `SQL statement "..."`).

## Storage and retention

| Table | Rows | Kept |
| --- | --- | --- |
| `pgvigil.job_step_runs` | one per pgAgent step run | as `job_runs`: `pgvigil.purge()` deletes by start time |
| `pgvigil.job_exclusions` | one per exclusion, ended rows kept | with its instance |
| `pgvigil.actions_log` | one per job action attempt | as the actions door's audit |

Migration `0102_pg_jobs_deadlocks.sql`. It replaces `job_status` (0094's, the same signature: the exclusions, and
pgAgent's step failures in its step counts), and `job_report_checks` and `job_failures` (the exclusions).

## API

| Route | What |
| --- | --- |
| `GET /api/jobs/running?instance=N` | Running now, which job actions are on (and why not), the job actions' audit |
| `POST /api/jobs/actions/stop` | `{instance_id, scheduler, job_id, job_name, run_id, job_pid, reason, confirm}` |
| `POST /api/jobs/actions/start` | `{instance_id, scheduler: "pgagent", job_id, job_name, reason, confirm}` |
| `GET /api/jobs/steps?instance=N&job=J[&run=R]` | pgAgent's step stats over the range and the step runs |
| `GET /api/jobs/exclusions?instance=N`, `POST` | the live exclusions; `{op: add, level, instance_id, match_on, pattern, note}` or `{op: end, exclusion_id}` |
| `GET /api/pg/deadlocks?instance=N` | the deadlocks, groups, breakdowns, trend and counter of the range |

The POST routes need the UI login and the `X-Pgvigil` header; a refused attempt is 409 with its reason, a failed one 502,
a body with a NUL or a SQL Server instance 400, an audit login that cannot write 503.

## Proof

`scripts/proof-pg-jobs-deadlocks.sh` runs on PostgreSQL 13, 16 and 18 (PGDG's pg_cron and pgAgent in the official images):
a pg_cron job stopped from its Running now row and audited, the refusals (no header, a wrong confirmation, another pid, an
instance whose `actions:` list does not name it); Running now's estimate from crafted runs; a pgAgent job run now and
stopped in its step with the step log stored; exclusions; a deadlock found once with both participants, its locks and its
relation, and drawn; a job changed twice and its script diff; both pages in a headless Chromium.

## Not proven

- `cron.use_background_workers = on` (the action refuses it), pg_cron on a node other than the monitored one
  (`cron.job.nodename`), RDS and Aurora (pg_cron there; pgAgent is not offered).
- A pgAgent step's session is found by its code (proven with a code longer than `track_activity_query_size`, matched by the
  text's start, beside another active session); a step whose code another session of its database runs at that moment
  too is refused, never guessed.
- The CloudWatch reader's deadlock events on the page (the same events as the `serverlog` reader's; read through the
  same parser).
