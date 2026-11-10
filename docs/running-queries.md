# Running queries

What runs now, on every instance of the fleet and on one instance, in the shape of DBA Dash's Running Queries: one line per row, a statement cut to its first 80 characters and opened whole by a click, a status line of totals above the grid, earlier and later snapshot buttons. Both engines. The data is the minute snapshots the collector already takes (`activity` on PostgreSQL, `mssql_requests` on SQL Server, see [SQL Server: running queries](sqlserver-running.md)); nothing new is collected and nothing is written to a monitored server.

## The fleet page (`Running queries` on the root strip)

One row per instance, from its **newest** snapshot, both engines, every column sortable by a click on its header:

| column | PostgreSQL | SQL Server |
|---|---|---|
| snapshot, age | the newest `activity_summary` row; its age by the repository's clock | the newest `mssql_requests_summary` row |
| sessions | the snapshot's sessions | the sessions listed |
| active | active sessions | requests running |
| idle in transaction | idle-in-transaction sessions | sessions without a request that hold an open transaction |
| blocked | sessions waiting on a `Lock` that name a blocker | sessions behind a head, or behind no session |
| chain heads | sessions a blocked one names that are not blocked themselves | the snapshot's heads |
| longest blocked wait | the age of the oldest blocked statement: `pg_stat_activity` has no start of a wait, so this is the most the wait can be | the longest wait behind a head, as the server measured it |
| longest statement | the oldest active statement of a client backend, its session and its first 80 characters | the longest running request, leaving out idle background work |
| oldest transaction | the oldest `xact_start` of the snapshot | the oldest open transaction, by the server's clock |

- A snapshot older than **3 minutes** is marked `stale` in muted text: its numbers are the last ones read, not the state now. An instance with no snapshot keeps its row, `no snapshot`.
- Above the grid: `Blocked sessions: n on m instances, longest wait ...`, the count of stale instances and of those without a snapshot.
- `Blocked only` keeps the instances with a blocked session in their newest snapshot.
- A row opens that instance's Running queries at that snapshot.
- The scope is the tag folder picked in the tree, then the tag filter of the bar, as on the Summary.
- The page refreshes every 30 seconds while the range follows now.

## An instance's page

**PostgreSQL** (the `Running queries` tab). One line per session of the snapshot (active, idle in transaction, or one that blocks another):

pid | state | wait | blocked by | chain head | blocks | query age | transaction age | xmin age | database | user | application | client | statement | plan | action

- `chain head`: `head` on a head; on a blocked session the pid of its chain's head; `cycle` on sessions that wait on each other with no head to name.
- `blocks`: the sessions behind this one, at any depth (DBA Dash's blocked count, recursive).
- The **statement** of an idle-in-transaction session is the LAST statement it ran, not one running now: the cell's title says so. On a head it points at the code that left the transaction open.
- `plan` opens the statement's plans and EXPLAIN; `Cancel` and `Terminate` go through the [actions door](app.md) with a typed reason and the pid typed again.
- **Snapshot**: Earlier, the snapshot's time, Later, Latest, and a picker for the snapshot at or before a time. A snapshot in the past turns the 30-second refresh off.
- **Blocked (n)** keeps the sessions of a blocking chain: the blocked ones and the ones that block them.
- **Group by** database, user, application, state or wait folds the grid into one counted row per group (sessions, blocked, the longest query age); a group's name opens its sessions, `All groups` folds them again.
- **Blocking chains**, above the grid when the snapshot has one: an indented tree, the head first, then the sessions behind it depth first, the longest waiting first; sessions in a cycle are listed after the trees.
- Below: what ran, or sat idle in a transaction, at least N seconds over the page's range, and the per-sample summary.

**SQL Server** (the `Running queries` tab of a SQL Server instance). The same one-line shape: session | status | command | waiting on | wait resource | blocked by | chain head | blocks | running for | transaction open for | database | login | program | host | statement | and the counters (CPU, reads, writes, parallelism, memory, tempdb, log written, isolation, the session's largest waits, the hashes and handles, cut on one line and whole in the cell's title). A slider with Earlier, Later and Latest moves over the snapshots kept in the range; an address with `at=` (a fleet row) opens the snapshot at or before that time. A sleeping session's statement is its last batch. The notes that explain a head, a parallel request's coordinator counters and a blocked row with no head are behind `what is this` links.

## The viewer

A statement cell is a button: a click, or Enter, opens the whole text in a dialog, monospace and wrapped, with a **Copy** button. The focus stays inside the dialog; Escape, Close or a click outside closes it and the focus returns to the cell. Both engines' pages use the same viewer.

## The rules

- Only a `Lock` wait is blocking on PostgreSQL; an LWLock, IO, IPC or Client wait is not, even when a stale `blocking_pids` names someone.
- The head of a chain is the session that blocks others and is not blocked itself. The cause of a chain is the head's transaction and its last statement, never the object the others wait on.

## API

- `GET /api/running/fleet`: the fleet page's rows (`rows`).
- `GET /api/running/snapshots?instance=<id>[&at=<RFC 3339>]`: the snapshot shown (the newest at or before `at`), the one before, the one after and the newest (`steps`).
- `GET /api/activity?instance=<id>[&at=]` and `GET /api/mssql/running?instance=<id>&from=&to=[&at=]`: one snapshot in full.
