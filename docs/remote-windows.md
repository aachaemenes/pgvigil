# Findings of a remote instance and the delay of its bundles

A remote instance's rows reach the hub in bundles ([remote-collector.md](remote-collector.md)): its newest data is as
old as the bundle interval plus the transfer - a few minutes for a direct push, an hour or a day for a site that
copies once an hour or carries a USB stick once a day. Call that the **delay**. pgvigil's findings are judged in the
repository against its own clock, so the delay changes them in four ways. This page lists each finding by what the
delay does to it (read from the findings' definitions of v0.4.0; the minute, hour and day windows and the
`make_interval` forms alike).

| what the delay does | findings | at a 5-minute delay | at a 1-hour delay | at a 1-day delay |
|---|---|---|---|---|
| **fires late, never falsely**: judges only the newest loaded rows | the latest-state findings (below) | 5 min late | 1 h late | 1 day late |
| **cannot fire once the delay passes its window**: judges the rows of a recent window | the windowed findings (below), by window | windows of 5 min or less miss | windows under 1 h miss | windows under 1 day miss |
| **may fire falsely**: reads an age against the hub's clock | the six age tests (below) | rarely | possible | likely |
| **fires on time, may fire after a renewal**: compares a stored date with the hub's clock | the deadline tests (below) | as a direct read | a renewal inside the hour still shows | a renewal inside the day still shows |

The site's own silence is judged by its cadence, not by these: no bundle for twice `expected_every` is a warning and
six times critical, per site and per instance. A finding of a remote instance clears no sooner than its bundle
interval plus its site's `expected_every`, so a windowed finding that cannot see the newest rows does not clear and
fire again with each bundle.

## Latest-state findings (late by the delay, never false)

PostgreSQL settings and the setting rules, a database's frozen-xid age, the extensions, the versions, the roles, a
table over its vacuum threshold, wraparound, amcheck's damage, invalid, duplicate and redundant indexes, a job that
fails again and again, backup destinations and PostgreSQL's backup chain checks, the restore checks, SQL Server's
security checks, two backup destinations on one volume, the WAL state's ages, the database options, and a database's
connection limit when it is invalid (-2) or 0. (SQL Server's backup checks are windowed: below, 2 h 10 min.)

## Windowed findings (cannot fire once the delay passes the window)

A windowed finding sees the rows in its window before now; with the delay longer than the window it sees none and
does not fire; with a shorter delay it judges part of the window, so it fires late, on fewer rows.

| window | findings |
|---|---|
| 2 to 3 minutes | the pooler's waiters (2 min), an availability group's data loss (3 min), a PostgreSQL cluster's checks (3 min) |
| 5 minutes | SQL Server running requests, an availability group's state and queues (5 to 5.5 min), blocking, the runnable queue, a Patroni cluster's state |
| 10 minutes | host CPU, a vacuum running over an hour or waiting on a lock, Extended Events capture state, a session waiting, long transactions and long requests, a database's sessions against its connection limit, a poison wait (10 to 20 min) |
| 15 minutes | host swap, log shipping, replication (SQL Server), tempdb and the version store, CPU, schedulers, memory and grants, waits, slot WAL, 'a job runs far longer than its average' (its gate; see the age tests) |
| 20 to 30 minutes | SQL Server audit definitions (20 min), the readers' state, PostgreSQL replication and DMS (30 min) |
| 1 hour | disk free, storage forecast, I/O burst balance, queue and latency, backups' read, Performance Insights, deadlocks and blocked reports, ring-buffer drops, failovers, file I/O, system events, the lead blocker, audit events, system_health, a replay delay, a Patroni API, tempdb writes, the alert rules on a metric whose freshness is an hour or less (below) |
| 2 hours | the comparison with the baseline (and the import skips a read 2 hours old: it never refreshes past that delay), the buffer cache, SQL Server audit counts, the alert rules on a 2-hour metric |
| 2 h 10 min | SQL Server's 'no recent full backup', 'no recent log backup', 'no recent differential backup' and 'a backup went to NUL' (each judges the backup read of the last 2 h 10 min: past that delay they never fire, they do not fire late) |
| 3 hours | volumes and files, tempdb's size, Query Store, the plan cache, the instance checks and configuration checks, maintenance |
| 13 hours | SQL Server index usage and statistics |
| 1 day | an inactive replication slot, temp spills, schema changes, session-set changes, corruption in the log, a job that failed (24 h by default, `job_failed_hours`), base backups, statements evicted, restarts, SQL Server error log and trace, a command that failed in maintenance, pgaudit rules (their own window, a day by default) |
| 7 days | plans captured, a backup destination not seen before; a crash is judged over its own 24 h / 168 h |

The **alert rules** (a charted metric above or below a value for n minutes) judge the minutes inside the data, but a
rule only runs on fresh data: 10 minutes to 2 hours by metric. Past that delay a rule on a remote instance reads 'no
data': a firing alert stays firing, a new one does not start.

## Age tests (may fire falsely)

These read how long ago something happened against the hub's clock; a remote instance's delay makes it look that much
older:

- **'a job ran over twice its average'** (PostgreSQL jobs): a run that ended inside the delay still reads as running,
  so a short job can be named long.
- **'job schedule missed'**: a running job is exempt for its first day, so the exemption ends a delay early.
- **'unused index'** (info): an index first seen, or statistics reset, within the delay of seven days counts as seven
  days old.
- **'a job runs far longer than its average'** (SQL Server Agent): only while the delay is under 15 minutes (its own
  window gates it); inside that, a run the delay hides as ended reads longer.
- **'amcheck older than'** (7 days warning, 14 days critical by default): the last good check reads the delay older.
- **'not judged: needs pg_wait_sampling'** (info): no wait sample within a day - a delay of a day or more raises it on
  an instance that has the extension.

On a site with a long delay, read these as 'as of the last bundle' and check them there before acting.

## Deadline tests (on time, may lag a renewal)

A role's `valid_until`, a SQL Server certificate's expiry and an upgrade's pending maintenance (its severity only)
compare a stored date with the hub's clock: they fire on time, and a renewal done inside the delay shows only with
the next bundle.

## pgvigil's own health

The collector's and the repository's findings (a collector not seen, purge not run, a collection failing, the alert
sender idle, the repository's autovacuum) are about the hub. A remote collector's heartbeat lands only in the remote
collectors list, so its delay never raises 'collector not seen' or holds an instance's alerts as 'collector or
network'; the site's silence finding stands in for it.

## Counts

In the migrations of v0.4.0's base, `now() - '<n> minute'` appears on 177 lines in 38 files, `now() - '<n> hour|day'`
on 300 lines in 68 files and `now() - make_interval(...)` on 1,040 lines in 53 files; most of those are reads, not
findings. The findings above are the 65 arms of `pgvigil.findings` and the alert rules, read one by one.
