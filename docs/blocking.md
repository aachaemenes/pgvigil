# Blocking and deadlocks

What pgvigil shows about blocking on both engines, where it comes from, and what it cannot see. The live snapshot (one
chain as it stands now, with Cancel and Terminate on PostgreSQL) is the Running queries tab; this page is about the
history of the range and the SQL Server deadlock graph.

## The rule for a chain

A session is **blocked** when it waits on a lock and names a blocker (PostgreSQL: `wait_event_type = 'Lock'` with
`pg_blocking_pids()`; SQL Server: `blocking_session_id`). The **head** of a chain blocks others and is not blocked
itself. The cause of a chain is the head's transaction and its last statement, never the object the others wait on:
a head that is idle in a transaction (PostgreSQL) or sleeping with an open transaction (SQL Server) is an
application that left its transaction open, and the statement shown is the last one it ran. No other wait (LWLock,
IO, a latch, CXPACKET) is blocking.

## PostgreSQL: the chain history (Running queries, below the snapshot)

Built from the activity samples the `activity` collection already keeps (pg_stat_activity once a minute: active and
idle-in-transaction sessions and every blocker a Lock waiter names). Nothing new is collected.

- **The denominator** (tiles): captures in the range, captures with blocking and their share, the worst chain's
  victims and its root's state, captures with a cycle (waiters that wait on each other with no head: a deadlock caught
  before `deadlock_timeout` fired).
- **Charts** per step (about 120 over the range): the most sessions blocked in one capture; the longest blocked and
  the oldest root transaction.
- **Chains by root transaction**: one row per head TRANSACTION (its pid, session start and transaction start): first
  and last capture, samples as root, its state at the last capture and how many captures it was idle in transaction,
  its transaction's age, victims (at any depth), direct victims, depth (the largest of the victims' shortest distances
  from the head), the longest blocked, and its last statement.
  The last-seen time opens the Running queries snapshot of that capture.
- **Who pins the xmin horizon**: now (`vacuum_xmin_holders`: sessions of the latest capture, slots, prepared
  transactions, standbys of the latest vacuum read) and over the range per session: how many captures it held the
  OLDEST session xmin in, its peak xmin age with its state, transaction age and statement at that peak. The tiles
  count the idle-in-transaction sessions and those none of whose idle samples had an xmin (decided per sample: an
  active statement's own xmin does not count): under READ COMMITTED a session idle between
  statements holds its locks and no snapshot, so it does not hold vacuum back; under REPEATABLE READ or SERIALIZABLE
  it does.

Read the counts as floors: a chain shorter than a minute can fall between two captures, and a waiter's wait is the
age of its statement at the capture (the lock wait itself, `pg_locks.waitstart`, is not sampled).

Functions (migration 0075): `blocking_history_chains`, `blocking_history_summary`, `blocking_history_episodes`,
`blocking_history_trend`, `xmin_pins`, `xmin_pins_summary`, each `(instance_id, from, to)` (the trend also takes the
step in seconds). The chains are worked out set-based from the samples with the same rule as `blocking_chains`
(0002) and give the same heads and victims for every capture (the proof checks it). On a lock queue, where each waiter
names the holder and every waiter ahead of it, each victim is at distance 1 from the head (depth 1); `blocking_chains`
can say depth 2 there. The walk keeps each (head, waiter, distance) once, so a queue of n sessions costs about n x
depth rows, not one row per path (2^n). The most blocked in a capture counts each waiter once, however many heads it
is behind. Each call reads the
range's activity samples of the instance once (the sample tables carry no index; monthly partitions prune the range).

## SQL Server

- **Running queries**: the chain tree of the snapshot now carries the head's login time, when its last request
  ended (a sleeping head: how long the application has left it), its open transactions and the log its transaction
  wrote (Darling 13.5's per-head columns). Below the snapshot, **Blocking over the range**: snapshots with a blocked
  session and their share, the most blocked at once, the longest wait, and per step the most blocked sessions and
  heads and the longest wait (from `mssql_requests_summary`, the minute snapshots).
- **Deadlocks**: the deadlocks per step over the range, the list, and one deadlock **drawn**: each session a box with
  its login, the lock it wanted, how long it waited and the first line of its statement; the victim boxed in the
  critical colour and labelled VICTIM; each locked resource a box below (KEY / PAGE / OBJECT / RID lock, the object
  and the index); an edge from a resource to the session that holds it (`holds X`) and a dashed one from a waiting
  session to the resource it wants (`waits for U`). The newest deadlock of the range opens by itself. The picture is
  drawn from the deadlock XML SQL Server wrote (`Save XML` downloads it as an .xdl that SSMS opens); where the XML is
  not kept (an instance whose `query_text` policy is not `full`), from the processes and resources the reader took
  out of it, and the page says which. Under the picture: the victim's details, and the processes and resources as
  grids (the picture's text form).

The deadlocks come from the Extended Events reader (docs/sqlserver-xe.md): pgvigil's own deadlock session where the
DBA created it, else system_health.

## API

`GET /api/blocking/history?instance=<id>[&from=&to=][&part=]`, read only. The window is cut to its newest seven days
(`meta.cut`); a step is about 120 points, never under a minute. PostgreSQL parts: `meta`, `summary`, `episodes`,
`trend`, `xmin_summary`, `xmin_pins`, `xmin_now`. SQL Server parts: `meta`, `trend`, `deadlock_trend` (every step of
the window is a row, a quiet one with zeros).

## Proof

`scripts/proof-blocking-history.sh`: a PostgreSQL chain held over three captures counted (head, victims, depth,
samples as root, idle in transaction, the transaction's age growing; the same rows as `blocking_chains`), a REPEATABLE
READ head listed as an xmin pin and a READ COMMITTED bystander not; a queue of 20 sessions on one lock counted as one
chain of 20 direct victims, in under 2 s; a SQL Server chain over two snapshots in the
trend; a real deadlock made on the SQL Server sandbox, stored, counted in the trend, and drawn by the Deadlocks tab
in a headless Chromium with its victim, both resources and the four labelled edges.

Not proven: a chain under a minute, a head that is a background worker, a deadlock of more than two sessions or with
a parallel exchange, Azure SQL Database (task 165) and Managed Instance.
