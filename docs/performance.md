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
`(instance_id, snapshot_at)` index. No index was added (no migration). Measured with `EXPLAIN (ANALYZE)` on the demo
(`scripts/proof-perfsummary.sh`, part D); the work grows with instances x samples in the range.

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
