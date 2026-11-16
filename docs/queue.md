# The request queue: community tools and actions run by the collector

By default `pgvigil serve` connects to a monitored server itself when someone clicks a button: a community tool, a
kill, a job start, an EXPLAIN. That needs serve to hold every instance's logins, so serve and the collector run on one
host. The request queue lets them run on different machines: serve writes each click into the repository as a request,
a `pgvigil run` that holds the instance takes it within a second, runs it with the logins it already holds and writes
the result back, and the page shows it the moment it lands. Serve then connects to no monitored server: only to the
repository (and to a DBA Dash repository named under `dbadash:`, as before).

DBA Dash does the same through SQL Server Service Broker (a queue per collector service). pgvigil keeps one table in
the repository (`pgvigil.action_requests`, migration 0200) with PostgreSQL's LISTEN / NOTIFY to wake the collector at
once, and a poll every 5 seconds that takes over when LISTEN cannot be held (a connection pooler in transaction mode
drops it).

## What goes through the queue in this release

| Button | In queue mode |
|---|---|
| Community tools: run, a procedure's own help | through the queue |
| Glenn Berry's queries (free SQL text) | through the queue only where `community_allow` names them (below) |
| Kill, cancel, terminate, job start and stop | off: not through the queue yet |
| EXPLAIN, EXPLAIN ANALYZE, the hypothetical index, the index advisor | off: not through the queue yet |
| Custom reports (save and run) | off |
| Admin > Instances (add, change, test) | off |
| Acknowledgements, alert-rule edits, applications | off |
| Investigations (Investigate, the Ask box, Close, an answered ask's Run) | off: "investigations are not offered in queue mode" |
| Scheduled report mail | off (serve's log says so at start) |

Every "off" button says why: "off in queue mode (actions.via queue in pgvigil.yaml): this serve holds no login to the
monitored servers and no write login to the repository, and in this release only the community tools go through the
queue to a collector". Acknowledgements, alert rules, applications, Admin > Instances, custom reports and report mail
are serve's own writes to the repository: they ride the audit login, which a queue-mode serve does not hold.

## Turning it on

Two switches, both off by default. The queue is locked down until a person turns on both.

On the collector host, in that collector's `pgvigil.yaml`:

```yaml
cq:
  enabled: true      # this collector takes the requests of the instances it holds (default false)
  workers: 4         # requests run at once, 1 to 16 (default 4), plus one slot kept for kill, cancel, terminate and job stop
  result_keep: read  # read (the default): kept until its asker has read it, or 1 hour, and only its asker reads it;
                     # 7d: every result this collector stores is kept 7 days, read or not, and EVERY pgvigil user can
                     # read every stored result (an opt-in: a person's runs are no longer theirs alone)
```

On the serve host, in serve's `pgvigil.yaml`:

```yaml
actions:
  via: queue         # direct (default): serve runs every button itself, as before
```

With `actions: via: queue` serve:

- resolves no instance's `dsn`, `actions_dsn` or `explain_dsn` (its file's instances keep their names and tags for the
  tree; their logins are the collector's), and no credential of an instance added in Admin > Instances
  (`doors: page_instance_reads` is the collector's setting in queue mode);
- keeps no audit login: the collector that runs a request writes its audit rows, and serve's own writes (the "off" rows
  above) are off; one WARN at start names them;
- refuses to start when its repository login is IN ROLE `pgvigil_collector` (one line naming the role). The login is
  serve's own: `-dsn` when given, else `repository: dsn:`.

Its repository login holds `pgvigil_reader`, `pgvigil_auth` and `pgvigil_requester` (`pgvigil roles` prints the
logins). The Windows app's serve can run community tools this way once the site grants `pgvigil_requester` to the
app's login.

A collector without `cq: enabled: true` loads no actions or explain login for the queue and opens no LISTEN
connection; a request for one of its instances is refused at once with "no collector takes requests (cq.enabled in
that collector's pgvigil.yaml)".

## Who may ask, and what they see

- A signed-in user of the operator role or above may ask what the instance's doors open, as in direct mode (a
  request is a community run, `POST /api/community/run`, a tool's @help in queue mode too; cancelling one's own
  request is the operator's as well: docs/roles.md). The doors are the COLLECTOR's: its
  logins, its `doors: page_instance_reads` for instances added in Admin > Instances, and the instance's
  `community_allow` (below). The page draws each button from what the collector published, with the collector's words
  and its host. When two collectors hold one instance, a request goes to one whose doors are open for it.
- `ui_user` is serve's word: every holder of the requester login (the Windows app's login on each desktop that has it)
  can ask any open kind under any name. At most 10 open requests per user name and 10 per repository login; every
  user of one serve shares serve's login, so that is 10 open requests across all of that serve's users.
- A result is read by its asker as serve names them: another user's page gets "this run was asked by another user".
  Under a collector's `cq.result_keep: 7d` every signed-in user reads every result that collector stored, for 7 days.
  The check trusts the user name serve passes, so any holder of serve's auth login (which already reads the UI's
  password hashes) can read any stored result. The Grafana login and every other `pgvigil_reader` login can see that a
  request was made, by whom and how it ended, never its arguments or its result.

## The life of a request

- **waiting**: written, not yet taken. A request never runs after its time: an action lives 30 seconds, a community
  run its timeout plus 30 seconds. One no collector took in that time is **expired** and never run (a kill five minutes
  late lands on someone else's work).
- **running**: taken by the collector named on the page, under a lease that collector renews every 15 seconds on the
  repository's clock, for the runs it still holds.
- **done**, **failed** or **refused**: the end, the collector's words. A run whose end could not be written ends
  **failed** with those words.
- **lost**: the collector stopped while running it, or lost track of it (its lease lapsed). It is never run again: it
  may or may not have run.
- **cancelled**: the asker pressed Cancel. A waiting request is cancelled at once; a running one is asked to stop and
  ends as soon as the server answers the cancel. A cancel that lands after the run ended leaves it **done**. A kill
  already sent is not undone.

## Community tools and the allow-list

`community_allow` on an instance (DBA Dash's allowed scripts) names which community tools its doors offer:

```yaml
instances:
  - name: sql01
    engine: sqlserver
    dsn: env:SQL01_DSN
    community_allow: [sp_WhoIsActive, sp_Blitz]   # or [all], or [none]; unset = every tool, as today
```

A tool outside the list is off with "<tool> is not in community_allow for this instance". Glenn Berry's diagnostic
queries send free SQL text, so through the queue they run only where `community_allow` names them (`glenn_berry` or
"SQL Server Diagnostic Queries") or says `all`; unset, they are off with words saying so. `jobs_allow` (names, `*` and
`-name` exclusions, as DBA Dash's allowed jobs) is read and its form checked at start, but no job is checked against
it yet: the job buttons do not go through the queue in this first cut, and the job check comes with them (from CQ's
slice B on).

The collector checks which tools each instance has, and each installed procedure's parameters, at its start, when
its instances change and every 10 minutes, and publishes them with its doors; the page reads that, never a request
per view. On SQL Server it checks one database, its login's default: the page names it, and a run in another database
looks for the procedure there and says so if it is not installed. The form's preset values (a default direct mode
fills in from a live read, such as sp_HumanEventsBlockViewer's session name) are not drawn in queue mode in this
release: type the value, or the procedure's own words say what it needs.

## Results

A community run's result is stored for its asker as its sets (columns and rows), with the direct run's limits per set
(5,000 rows, 50 sets, 256 KB a cell) and 8 MB in all as the repository stores it; past 8 MB it is cut with the words
"cut at <n> rows: queue mode keeps 8 MB" (the direct run's reply stops at 24 MB). One the repository still finds over
8 MB ends **failed** with words, its result not kept. It is cleared after it is read, or after an hour; under the
collector's `cq.result_keep: 7d` it is kept 7 days, read or not, and every pgvigil user can read it. The request's
own row (who, when, what, how it ended) is kept: a read's and every refused one's for 7 days, an action's as the
actions log is.

Every text in a stored result is masked BEFORE it is stored, with the credential mask the collector puts on the
statements it stores; among its forms: a sqlcmd, bcp, osql or isql `-P`, `PASSWORD = '...'`, `SECRET = '...'`, a
password-named `@` parameter, a connection string's or a URI's password, `ConvertTo-SecureString`, `net use`, each
written `<masked>`. A value that is an XML document (a plan, a deadlock graph, a blocked process report) is masked
inside its attribute values, text and processing instructions (sp_WhoIsActive writes its query text as one) and stays
XML. A cell, a column name, a message and the run's own words are all masked, and so are the request's outcome and
refusal, which the Grafana login can read. The direct run is not stored and its reply shows the tool's output as the tool returned it, so
the same run can show a secret in direct mode and `<masked>` in queue mode.

## Audit

Every request is its own record of the ask and its end. The collector also writes the audit rows the direct path
writes (the custom report log's `community_run` and `community_help`, and `community_form` for a help refused before
it ran), with the instance's id, and `via: queue`, the request's id and the collector in their parameters, in the same
transaction as the end: a run whose audit row fails ends with neither. The community page's run log lists them.
