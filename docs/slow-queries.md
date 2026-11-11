# Slow queries, a statement's history and the jobs timeline

Three views that follow DBA Dash's Slow Queries and Jobs Timeline and the History drill of Darling's Top Queries.

## Slow queries: Group By and the events behind a count

The Slow queries page of an instance, of a SQL Server instance and of the fleet carries a **Group by** grid over
the slow events of both engines:

| Engine | Source | What an event carries |
|---|---|---|
| PostgreSQL | the server log (the `serverlog` collection on-prem, CloudWatch Logs on RDS and Aurora): statements over `log_min_duration_statement` | time, duration, database, user, client, pid; no CPU, reads or rows |
| SQL Server | the slow capture (Extended Events: `rpc_completed`, `sql_batch_completed` and the statement completions) | time, duration, CPU, logical and physical reads, writes, rows, database, login, client host, application, session, object, result |

The grid has one row per value of the grouping and DBA Dash's ten duration buckets as columns (`<5 sec`, `5-10 sec`,
`10-20 sec`, `20-30 sec`, `30-60 sec`, `1-5 min`, `5-10 min`, `10-30 min`, `30-60 min`, `1hr+`), then Total, Failed,
Total Duration and Total CPU in seconds, and logical reads, physical reads and writes. An **All** row under it
counts every event of the filter.

- **Group By**: Instance, Database Name, App, Username, Client (without the port PostgreSQL logs), Event Type
  (`server log` or `CloudWatch` for PostgreSQL; the event name for SQL Server), Object Name, Result, Session ID,
  Text (the statement's shape: its text without literals), Time - Hour, Time - Day (in the display time zone, the browser's unless another is chosen in the range panel; an
  hour carries its UTC offset, so the hour a clock goes back is two rows) and Engine. A value that is an empty
  string (a SQL Server client that sends no application name) is its own row, `(empty)`, apart from `(none)`. DBA Dash's Time - Custom is the page's own range.
- **Database**: the databases with slow events in the range, each with its count; one picked cuts the grid to it.
- **Top**: 20, 50, 100 or 500 groups, the most events first (Time - Hour and Time - Day in time order).
- **Events**: `calls` (the default) counts SQL Server's rpc and batch completions only; `calls and their statements`
  adds the statement events (`sql_statement_completed`, `sp_statement_completed`). With the capture's statement
  events on, one slow procedure call is stored as the call and as its slow statements, so counting both would count
  its time twice.
- The page's **Threshold** (100 ms to 1 min, or all logged) applies to the grid too.

Every count is a button: it lists the events of that cell below the grid, the longest first (at most 500, with the
cell's full count): instance, database, event type, object, time, duration, CPU, reads, writes, rows, user,
client, application, result, session and the statement.

- **Failed** counts SQL Server events whose result is not `OK` (`Error` or `Abort`: a client cancel or a timeout).
  The PostgreSQL log writes a duration only for a statement that finished, so a PostgreSQL event is always `OK`.
- **App** on PostgreSQL: the log line pgvigil reads carries no application name. An event in the drill shows the
  application the activity sampler saw for the same pid while the statement ran, marked `(sampled)`; an event no
  sample caught shows none. Grouped by App, the PostgreSQL events fall in one `(none)` row.
- Under a tag folder of the fleet, Group By Instance keeps the folder's instances; the other groupings and the All
  row count the whole fleet, and the page says so. A drilled cell then lists only the folder's instances, and its
  heading gives both counts (the fleet's, and the folder's listed).

## A statement's history

A **History** button on each row of the Statements grid and of the Slow queries shape lists (and of the drilled
events) opens a row under it with the statement's figures over the page's range, about 72 intervals of whole
minutes; **Hide history** closes it.

| Row of | Source | Charts |
|---|---|---|
| Statements (PostgreSQL) | `pg_stat_statements` deltas of that queryid (and database) | mean time and the longest run; calls and rows |
| Slow queries (either engine) | the slow events of that shape | mean and longest duration; events, failed and rows |

`pg_stat_statements` keeps no maximum per interval: the longest run of a Statements row is the longest event of the
same shape the server log recorded in that interval, so an interval with nothing over `log_min_duration_statement`
has none. A delta is placed at the middle of the period it covers. A reset of the statistics between two reads
leaves that interval out. An interval with nothing in it is drawn as zero (or as a gap for the times), never as a
line joining its neighbours. The intervals that had something are in a table under the charts.

## The jobs timeline

**Jobs timeline**, in the Jobs folder of an instance (pg_cron, pgAgent or SQL Server Agent) and of the fleet, draws
every run that overlaps the range:

- one row per job (the fleet: grouped under each instance), its runs as bars from start to end: green succeeded,
  red failed, amber cancelled or retried, blue still running (drawn to now), grey unknown: a run with no end that no
  read has seen in the last 15 minutes (the collection stopped) is drawn up to the last time it was seen, never left
  open;
- a red count beside a job with failed runs;
- a **Running at once** lane at the top: how many runs went on at each moment, with its **peak** (two runs back to
  back are not at once);
- a **time cursor**: point at the drawing (or focus it and use the arrow keys) and it says the time and how many
  jobs were running then;
- an **Outcome** filter (failed, succeeded, running, or cancelled, retry or unknown) and a job name filter;
- on an instance, a job's name cuts the timeline to that job; a SQL Server job then shows its steps as their own
  rows ("1 : step one", "2 : step two" in red when it failed). pg_cron has no steps, and pgAgent's step log is not
  kept per run (the failed step is on the run);
- the same runs, and the steps, as tables under the drawing.

A SQL Server run's start is msdb's `run_date` and `run_time` as the collector reads them; its end is the start plus
the duration; a run the Agent still reports running is not drawn a second time once its finished row is stored. A
run that started up to 7 days before the range and was still going in it is drawn from the range's start; one that
started earlier is not drawn. At most 5,000 runs are drawn (the newest); the page says when there were more.

## API

| Route | Parameters | Parts |
|---|---|---|
| `GET /api/slow/groups` | `instance` (none = the fleet), `from`, `to`, `min` (ms, default 1000), `db`, `group`, `tz`, `top`, `events` (`calls` or `all`) | `groups`, `totals`, `dbs` |
| `GET /api/slow/events` | the same, and `value` (or `blank=1` for the empty string, or `null=1`; none = every group), `bucket` (0-9), `failed=1` | `events`, `meta` |
| `GET /api/stmttrend` | `instance`, `from`, `to`, and `queryid` (with `db`) or `shape` (with `min`) | `meta`, `trend` |
| `GET /api/jobs/timeline` | `instance` (none = the fleet), `from`, `to`, and on an instance `scheduler` with `job` | `runs`, `meta`, `steps` (SQL Server) |

The Statements grid's History button and the Jobs timeline's place in the Jobs folder come with the shell's
wiring (the routes, the tab and the column).

The SQL lives in migration `0076_slow_events.sql`: the view `pgvigil.slow_events_all` (both engines in one shape),
`pgvigil.slow_bucket(ms)`, `pgvigil.stmt_trend(...)` and `pgvigil.slow_trend(...)`. It adds no table and no column.

Proof: `scripts/proof-stmt-slow-timeline.sh`.
