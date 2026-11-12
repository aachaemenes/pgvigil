# The pooler traced

A client that waits inside PgBouncer for a server connection is invisible to PostgreSQL: it has no backend, so
`pg_stat_activity`, Running queries and every chain built from them cannot list it. The Pooler tab reads PgBouncer's
own lists of its clients and servers and joins each server to the backend it runs, so a pooled application's wait
traces to the backend its pool is stuck on and to that backend's holder.

The pooler's setup (the `pgbouncer:` DSN, a `stats_users` login, SHOW only) is in [Memory and poolers](memory.md#the-pooler-pgbouncer).
Nothing more is configured for this page.

## What is read

Every minute, beside `SHOW POOLS`, `SHOW STATS`, `SHOW DATABASES`, `SHOW USERS` and `SHOW CONFIG`:

- **SHOW CLIENTS**: each client connection: its state (`active`: paired with a server; `waiting`: queued for one;
  `idle`: connected, not in a transaction), how long it has waited (`wait` + `wait_us`), its application, address,
  connect and last-request times, and `link`, the server it is paired with.
- **SHOW SERVERS**: each server connection, with `remote_pid`, the backend's pid in PostgreSQL.

Stored per read in `pgvigil.pooler_conn_sample` (migration 0081): the clients that are not idle, the longest waits
first, at most 1000; every server up to the same cap; and a count of the clients read and kept. Idle clients are
counted, not stored: a busy pooler can hold thousands. The admin console's own clients (database `pgbouncer`, the
collector's login among them) are left out. A console that refuses `SHOW CLIENTS` or `SHOW SERVERS` (an older
PgBouncer, a narrowed login) keeps the pools as before and stores no clients.

PgBouncer before 1.21 shows an idle client as `active`: there every client is stored up to the cap (not proven: the proof runs PgBouncer 1.26.1).

## The trace (Pooler tab)

The read shown is the one nearest the page's time within two minutes, else the newest before it. Its servers are
joined by `remote_pid` to the **activity snapshot** nearest the read (within two minutes) and to that snapshot's
blocking chains (the same rule as Running queries: only a Lock wait that names a blocker is blocking; the head holds
and does not wait):

- **Trace** - one line per pool (database / user) with a client waiting or a server in a chain: the clients waiting
  and the longest wait, how many of the pool's servers are busy and how many of them are blocked on a lock, and the
  head pid(s) behind them. "No server's backend waits on a lock" means the pool is busy, not blocked: too small for
  its load, or its transactions are slow.
- **Heads** - each head a pooler server waits behind: its state (idle in transaction = the application holds its
  transaction open), its application and last statement, whether the head is itself one of this pooler's servers and
  for which client, the pooler servers blocked behind it and the clients waiting in those pools. Its pid opens
  Running queries at the paired snapshot. The cause is the head's transaction and its last statement, not the row or
  table the others wait on.
- **Clients (SHOW CLIENTS)** and **Servers (SHOW SERVERS)** - the grids, each server with its backend's state, wait,
  query and transaction ages, its role in a chain (head / blocked / in a cycle) and its chain's head.

A server whose backend is idle between transactions is not in the activity snapshot (it samples active and
idle-in-transaction sessions and blockers): it reads "not in the sample".

## On Running queries

On an instance with a pooler read, Running queries pairs its snapshot with the pooler read of the same minute:

- a status line: the clients waiting in PgBouncer for a server and the longest wait (they are not in the sessions
  below), the head pid(s) the pool's servers wait behind, and how many of the sessions are pooler servers;
- a **pooler** column in the chain tree and the Sessions grid: `pooler: <application>` on a session that is a
  PgBouncer server, naming the client application it serves.

## What it cannot say

- The pooler read and the activity snapshot are two reads seconds apart. In transaction mode which client a server
  serves changes with every transaction, so a pairing is as of the pooler read; a backend's state is as of the
  activity snapshot. A pooled wait shorter than a minute can fall between reads.
- A waiting client waits for any server of its pool, not a particular backend: the trace names the pool's servers
  and the heads they wait behind, never "client X waits for pid Y".
- A chain whose head connects directly (not through the pooler) is traced all the same; the head reads "no (a
  direct session)".
- Several PgBouncers in front of one instance: one `pgbouncer:` DSN per instance is read.

## Proof

`scripts/proof-pooler.sh`: a real PgBouncer 1.26.1 in transaction mode, 20 clients on a pool of 3, one holder idle
in a transaction with a row lock: the 17 waiting clients, the 3 servers with the backends `pg_stat_activity` holds,
the two blocked servers traced to the holder's pid, the API's trace and heads, and both pages in a headless Chromium.
