# The request queue: community tools and actions run by the collector

By default `pgvigil serve` connects to a monitored server itself when someone clicks a button: a community tool, a
kill, a job start, an EXPLAIN. That needs serve to hold every instance's logins, so serve and the collector run on one
host. The request queue lets them run on different machines: serve writes each click into the repository as a request,
a `pgvigil run` that holds the instance takes it within a second, runs it with the logins it already holds and writes
the result back, and the page shows it the moment it lands. Serve then connects to nothing but the repository.

DBA Dash does the same through SQL Server Service Broker (a queue per collector service). pgvigil keeps one table in
the repository (`pgvigil.action_requests`, migration 0200) with PostgreSQL's LISTEN / NOTIFY to wake the collector at
once, and a poll every 5 seconds that takes over when LISTEN cannot be held (a connection pooler in transaction mode
drops it).

## What goes through the queue in this release

| Button | Through the queue |
|---|---|
| Community tools: run, Glenn Berry's queries, a procedure's own help | yes |
| Kill, cancel, terminate, job start and stop, plan evict | not yet: the button is off with "not through the queue yet" |
| EXPLAIN, EXPLAIN ANALYZE, the hypothetical index, the index advisor | not yet |
| Custom reports | not yet |
| Admin > Instances (add, change, test) | not yet |
| Collect now | not yet |

## Turning it on

Two switches, both off by default. The queue is locked down until a person turns on both.

On the collector host, in that collector's `pgvigil.yaml`:

```yaml
cq:
  enabled: true      # this collector takes the requests of the instances it holds (default false)
  workers: 4         # requests run at once, 1 to 16 (default 4), plus one slot kept for kill, cancel, terminate and job stop
  result_keep: read  # read (default): a result is kept until its asker has read it, or 1 hour
                     # 7d: kept 7 days - every pgvigil user can read every stored result
```

On the serve host, in serve's `pgvigil.yaml`:

```yaml
actions:
  via: queue         # direct (default): serve runs every button itself, as before
```

With `actions: via: queue` serve:

- resolves no instance's `dsn`, `actions_dsn` or `explain_dsn` (its file's instances keep their names and tags for the
  tree; their logins are the collector's);
- keeps no audit login: the collector that runs a request writes its audit rows;
- refuses to start when its repository login is IN ROLE `pgvigil_collector` (one line naming the role).

Its repository login holds `pgvigil_reader`, `pgvigil_auth` and `pgvigil_requester` (`pgvigil roles` prints the
logins). The Windows app's serve can run community tools this way once the site grants `pgvigil_requester` to the
app's login.

A collector without `cq: enabled: true` loads no actions or explain login for the queue and opens no LISTEN
connection; a request for one of its instances is refused at once with "no collector takes requests (cq.enabled in
that collector's pgvigil.yaml)".

## Who may ask, and what they see

- Every signed-in user may ask what the instance's doors open, as in direct mode. The doors are the COLLECTOR's: its
  logins, its `doors: page_instance_reads` for instances added in Admin > Instances, and the instance's
  `community_allow` (below). The page draws each button from what the collector published, with the collector's words
  and its host.
- `ui_user` is serve's word: every holder of the requester login (the Windows app's login on each desktop that has it)
  can ask any open kind under any name. At most 10 open requests per user name and per repository login.
- A result is read by its asker alone (another user gets "this run was asked by another user"). The Grafana login and
  every other `pgvigil_reader` login can see that a request was made, by whom and how it ended, never its arguments or
  its result.

## The life of a request

- **waiting**: written, not yet taken. A request never runs after its time: an action lives 30 seconds, a community
  run its timeout plus 30 seconds. One no collector took in that time is **expired** and never run (a kill five minutes
  late lands on someone else's work).
- **running**: taken by the collector named on the page, under a lease that collector renews every 15 seconds on the
  repository's clock.
- **done**, **failed** or **refused**: the end, the collector's words.
- **lost**: the collector stopped while running it (its lease lapsed). It is never run again: it may or may not have
  run.
- **cancelled**: the asker pressed Cancel. A waiting request is cancelled at once; a running one is asked to stop and
  ends as soon as the server answers the cancel. A kill already sent is not undone.

## Community tools and the allow-list

`community_allow` on an instance (DBA Dash's allowed scripts) names which community tools its doors offer:

```yaml
instances:
  - name: sql01
    engine: sqlserver
    dsn: env:SQL01_DSN
    community_allow: [sp_WhoIsActive, sp_Blitz]   # or [all], or [none]; unset = every tool, as today
```

A tool outside the list is off with "<tool> is not in community_allow for this instance". `jobs_allow` (names, `*`
and `-name` exclusions, as DBA Dash's allowed jobs) is read and checked now and applies to the job buttons when they
go through the queue.

The collector checks which tools each instance has, and each installed procedure's parameters, at its start, when
its instances change and every 10 minutes, and publishes them; the page reads that, never a request per view. The
form's preset values (a default the procedure would decline here) are read by serve from the repository.

## Results

A community run's result is stored for its asker as its sets (columns and rows), with the direct run's limits per set
(5,000 rows, 50 sets, 256 KB a cell) and 8 MB in all; past 8 MB it is cut with the words "cut at <n> rows: queue mode
keeps 8 MB" (the direct run's reply has no total cap). It is cleared after it is read, or after an hour, or after 7
days with `result_keep: 7d`. The request's own row (who, when, what, how it ended) is kept: a read's for 7 days, an
action's as the actions log is.

## Audit

Every request is its own record of the ask and its end. The collector also writes the audit rows the direct path
writes (the custom report log's `community_run` and `community_help`), with `via: queue`, the request's id and the
collector in their parameters, in the same transaction as the end: a run whose audit row fails ends with neither.
