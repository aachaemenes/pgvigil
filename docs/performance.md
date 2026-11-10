# Performance summary and the Performance page

Two pages after DBA Dash's Performance Summary and Performance tabs, for PostgreSQL and SQL Server instances.

## Performance summary (fleet)

`#/perfsummary` - one row per active instance in the scope (the tag folder the tree has open) over the page's range,
every column sortable by a header click. API: `GET /api/perfsummary?from=&to=[&tag=][&part=pg|mssql]`.

| column | PostgreSQL | SQL Server |
|---|---|---|
| CPU avg / max (data bars) | the host collection's `cpu_pct` (system_stats or CloudWatch); none = "no host read" | not collected yet: "not read" |
| CPU histogram | the share of the range's samples in ten 10 % buckets; only 70-90 % (warning) and 90-100 % (critical) are coloured | "not read" |
| active avg / max | `activity_summary.active` | `mssql_requests_summary.requests` |
| Lock (the critical wait), IO, LWLock / latch, IPC / parallelism, Client, total (ms of wait per second) | `wait_sample` (pg_wait_sampling) by event type; the idling Activity type, an idle connection's ClientRead and CPU left out. Without pg_wait_sampling, Lock alone is estimated from the sessions seen waiting on a lock at each minute's sample, marked `*` | `mssql_wait_sample` by category: Locking; Disk + Transaction log; the latch categories; Parallelism; Query (client, spills, spools); idle background waits left out |
| signal wait % | n/a | the part of the wait time spent runnable |
| transactions/s, commits/s, rollbacks/s | `dbstats`, the counters' rise per restart epoch | "not read" |
| read / write latency (ms), MB/s | `pg_stat_io` (PostgreSQL 16+, `track_io_timing` on for the latency), else CloudWatch `ReadLatency`, `WriteLatency`, `*Throughput` | "not read" |
| temp/s | `dbstats.temp_bytes` | "not read" |
| longest statement, oldest transaction, blocked - now | the newest activity snapshot in the range | the newest requests snapshot in the range |

Thresholds (the page's "thresholds" link): CPU max over 75 % warning, over 90 % critical; Lock wait over 100 ms/sec
warning, over 1,000 critical. A cell past its line carries a fill and the word; every other cell is plain.

Cost: one statement per engine, driven from the instance list, each history table read through its
`(instance_id, snapshot_at)` index. No index was added (no migration). The endpoint runs the statements in a
read-only transaction with `jit = off`: at about 200 instances the plan's cost estimate passes `jit_above_cost`, and
JIT's compile time (measured 695 ms) is several times the statement's own run (180 ms). Measured with
`EXPLAIN (ANALYZE)` (`scripts/proof-perfsummary.sh`, part D; `SCALE_N=185` for 200 instances); the work grows with
instances x samples in the range, so 1,000 instances cost about five times the 200-instance figure.

| | 15 instances (demo) | 200 instances | 1,000 instances (stated: x5 of 200) |
|---|---|---|---|
| PostgreSQL statement, 1 h | 6 ms | 86 ms (634 ms with JIT on) | about 0.45 s |
| PostgreSQL statement, 24 h | 28 ms | 378 ms (877 ms with JIT on) | about 1.9 s |
| SQL Server statement, 1 h / 24 h | 2 / 8 ms | 5 / 16 ms (3 SQL Server instances in both) | grows with the SQL Server instances only |
| GET /api/perfsummary, 1 h / 24 h | 0.02 / 0.04 s | 0.07 / 0.38 s | about 0.4 / 1.9 s |

Measured 2026-11-10 on the local PostgreSQL 18 with a one-minute demo history (the scale instances: one day).

## Performance (instance)

`#/performance?i=<id>` - small charts over the range on one time axis (about 120 steps, a minute at least; the steps
with a sample in any chart). Each title opens the detailed page.

- PostgreSQL: CPU (Host), sessions by state (Counters: sessions), waits by class stacked (Waits), transactions per
  second (Counters: db), IO latency (IO), IO throughput (Counters: io), temp usage (Counters: db); links to Load,
  Memory and Pooler under the charts.
- SQL Server: requests and blocked sessions (Running queries), waits by category stacked (Waits); CPU, transactions
  and IO say "not read".

API: `GET /api/performance?instance=N&from=&to=[&part=]` - parts `meta`, `grid` and, per engine, `cpu`, `sessions`,
`waits`, `db`, `io` (PostgreSQL) or `sessions`, `waits` (SQL Server).

## Not yet

SQL Server CPU, transactions per second and file IO latency: a collector reading `sys.dm_os_ring_buffers`
(scheduler monitor: SQL and other-process CPU per minute), the `Batch Requests/sec` and `Transactions/sec` counters of
`sys.dm_os_performance_counters`, and `sys.dm_io_virtual_file_stats` differences would fill the three columns.
