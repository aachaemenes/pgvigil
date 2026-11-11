# The server log: events grouped, latency of the logged statements, checkpoints

Three views over what pgvigil's two log readers store (the `serverlog` collection on-prem, which reads the log
files through a read door; the `logs` collection on RDS and Aurora, which reads CloudWatch Logs). They follow
pgBadger's Events, General Activity, Histogram of query times, Temp Files and Checkpoints tabs.

## What the readers store

Every entry of the log is classified; an entry no rule takes is not stored. The kinds:

| Kind | From |
|---|---|
| `slow` | `duration: N ms statement: ...` (log_min_duration_statement) |
| `plan` | auto_explain's `duration: N ms plan:` |
| `lock_wait`, `deadlock`, `auth_fail` | log_lock_waits, the deadlock report, a failed login |
| `corruption` | the messages only a damaged page, file, TOAST value or commit log raises |
| the pganalyze classes | connection limits, timeouts, cancellations, autovacuum cancelled, wraparound, crashes, out of memory, archiving, standby conflicts, serialization failures, temporary files, frequent checkpoints |
| `error` | any other WARNING, ERROR, FATAL or PANIC entry: a syntax error, a constraint violation, a permission denied |
| `checkpoint` | log_checkpoints' `checkpoint starting:` and `checkpoint complete:` lines (`restartpoint` on a standby) |

Each event since migration 0079 carries its **level** (LOG, WARNING, ERROR, FATAL, PANIC) and its **message
shape**: the first line of the message with the cursor position the server appends (`at character 15`) dropped, a
double- or single-quoted run (from the first quote of the line to the last) turned into `"..."` / `'...'`, a tuple id
into `(...)`, and every token that holds a digit or an `@` (a number, an LSN, a path of OIDs, an IP address, a UUID,
an e-mail address, a `$` amount, a name such as `acct_7781`) into `...`. So `relation "a" does not exist` and
`relation "b" does not exist` are one message. Two quoted names on one line become one run (`column "x" of relation
"y" does not exist` reads `column "..." does not exist`).

What the shape can still carry: the words of a free-text message (a `RAISE EXCEPTION` whose value has no digit and
no quote) and an unquoted name (`permission denied for function f`). With the instance's `query_text` policy:

| Policy | message shape | an `error` event's detail (its DETAIL, HINT, CONTEXT lines: `Key (email)=(...) already exists`) | statement |
|---|---|---|---|
| full | stored (passwords masked) | stored as the server wrote it | stored |
| normalized | stored | not stored: the SQL normalizer cannot mask a row value written outside a literal | normalized |
| none | not stored (the event groups by its kind) | not stored | not stored |

An event is keyed by its first line's time text, level, pid and message, so a re-read drops it; two identical
lines of one process in the same time text (one millisecond with `%m`, one second with `%t`) are stored as one
event, a stated limit of the counts.

Events read before 0079 have no level and no shape. The grouped view takes the level from the kind where the kind
is logged at one level only, and the shape from the stored detail where the detail is the server's own message
(`pgvigil.log_message_shape`, the same rule in SQL); a lock wait read before 0079 is shown as one group named by its
kind.

## Logs: grouped by message

The Logs tab of an instance has a **grouped by message** sub-tab: one row per kind, level and message shape, the
most frequent first (at most 500), with the times it was reported, first and last seen, and the databases and
users it came from. A count opens the raw events of its group below (the newest 200), each with its time, level,
pid, database, user, client, the message with its detail, and the statement. Above the grid: the events, the
groups, the most times one message was reported (pgBadger's key values) and the events per level; a **Level**
filter keeps one level.

Slow statements, plans, checkpoint lines and temporary files are left out of the groups: the Slow queries page,
the IO page and the list below carry them.

**Largest temporary files**: one row per temporary file the log recorded (`log_temp_files`: a file at or over the
setting is logged when it is deleted; -1 logs none), the largest first (at most 50), with its time, size,
database, user, client, pid, path and the statement where the server wrote a STATEMENT line; above it the files,
the bytes and the largest over the window.

API: `GET /api/logs/groups?instance=<id>&from=&to=&[level=]` (groups, totals, levels, temp_files, temp_total) and
`GET /api/logs/groups/rows?<the same>&key=<group_key>` (events, meta).

## Slow queries: latency of the logged statements

The Slow queries tab of an instance carries **Latency of the logged statements**, at the page's threshold:

- per hour (in the display time zone: the browser's unless another is chosen in the range panel): the statements, min, max and mean, and **p90 / p95 / p99**, as a chart and
  a table. The percentiles are nearest-rank: the smallest logged duration with at least that share of the hour's
  statements at or under it.
- a **duration histogram** in pgBadger's buckets (0-1 ms, 1-5 ms, 5-10 ms, 10-25 ms, 25-50 ms, 50-100 ms,
  100-500 ms, 500 ms-1 s, 1-10 s, over 10 s): statements, their share and their total time.

Every figure is **of the statements the server logged**: a statement under `log_min_duration_statement` never
reaches the log, so a p99 here is the p99 of the logged statements, not of every statement the server ran. The
panel names the server's `log_min_duration_statement` as pgvigil last read it; a database or role setting
(`ALTER DATABASE ... SET`, `ALTER ROLE ... SET`) can differ from it.

API: `GET /api/slow/percentiles?instance=<id>&from=&to=&[min=<ms>]&[tz=<IANA>]` (hours, histogram, meta).

## IO: checkpoints

The Checkpoints section of an instance's IO tab:

- **the counters**, summed over the window: timed and requested checkpoints, the write and sync time and the
  buffers written; before PostgreSQL 17 from `pg_stat_bgwriter`, from 17 from `pg_stat_checkpointer` (the `dbstats`
  collection reads the view the version has). Charts per interval: timed and requested, write and sync time,
  buffers per second. The counters count a checkpoint that WAL volume forced as requested.
- **from the server log** (`log_checkpoints`, on by default from PostgreSQL 15): the **causes**, counted from the
  start lines: `time`, `wal` (max_wal_size reached; `xlog` in old releases), `requested` (a CHECKPOINT command,
  immediate or fast, force: a base backup, CREATE DATABASE), `shutdown`, `end of recovery`; and **one row per
  completed checkpoint** (the newest 200): when it started and completed, its flags and cause, the buffers written
  and their share of shared_buffers, the WAL files added, removed and recycled, the write, sync and total seconds,
  and the distance and estimate. A start line the readers did not read shows as `start not read`.
  The parser pairs a complete line with its start in log order when it reads both in one pass (it stores the start
  as a `STARTED:` line under the complete line), which is exact even with a whole-seconds prefix (`%t`, the RDS
  default) where one checkpoint's completion and the next one's start share a second. Only a pair split across two
  reads is paired by time, and with a whole-seconds prefix two back-to-back checkpoints split that way can pair wrong.

Many `wal` checkpoints mean max_wal_size is small for the write rate; a long sync time points at the storage.
With `log_checkpoints` off the section says so and the counters still count.

## Proof

`scripts/proof-log-groups.sh`: a PostgreSQL 18 throwaway cluster with a known workload (three missing tables, two
duplicate keys, a division by zero, two ROLLBACKs outside a transaction, a statement timeout, a login as a missing
role, a spilling sort, pg_sleep of known lengths), grouped to the expected counts; the Go and SQL shape rules
compared on every stored message; the largest temp file against the raw log; the hourly percentiles and the
histogram against a hand computation; a forced checkpoint counted as requested on PostgreSQL 18 and 13; and 0079
migrated on PostgreSQL 13.
