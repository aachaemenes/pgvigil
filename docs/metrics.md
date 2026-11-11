# Metrics

An instance's **Metrics** tab (under *Performance* in the tree) is one grid per counter family. It replaces the
Counters charts on a PostgreSQL instance and is the same page on a SQL Server instance. Nothing new is collected for
it: every figure is read from a series the collector already stores.

## The grid

One row per counter, over the time range picked in the header:

| Column | What it is |
|---|---|
| counter | The counter's name; its key (`sessions.idle_in_txn`) and unit are in the cell's title. |
| max, min, avg | The highest, lowest and average sample of the range. |
| current | The newest sample of the range; *last sample* says when it was taken. |
| samples | How many samples the range holds. 0 = nothing was collected in the range (the figures are empty). |
| warning, critical | The thresholds in force for the row, with their direction (`above 80 %`). |
| rule | For how long the value must hold, what the rule covers, and what the alert sender last made of it: ok, pending, warning, critical, no data, or *not judged yet*. |
| threshold | *New threshold* where none is in force; *Edit* for the rule in force; *Override here* to give this instance its own rule over a wider one. |
| chart | Draws the row over the range, with its thresholds as flat lines. *Chart every row* draws the family. |

A row with thresholds colours each of its four figures by them: a figure beyond the critical value is critical,
beyond the warning value warning. The thresholds stand in their own columns, so the colour is never the only sign. A
figure's colour is a reading of that one number; whether an **alert** is open is the *rule* column's word, because a
rule also asks for its minutes.

The families:

| Engine | Family | From |
|---|---|---|
| PostgreSQL | Sessions | The activity samples: sessions by state, connections used, the longest active statement and idle transaction, the oldest xmin age. |
| PostgreSQL | Database | `pg_stat_database`: commits, rollbacks, blocks read and hit, the cache hit ratio, tuples, temp bytes, deadlocks, backends. Summed over the databases, or one database picked above the grid. |
| PostgreSQL | Server | The checkpointer, the background writer and WAL: checkpoints, buffers written and allocated, WAL bytes and records. |
| PostgreSQL | IO | `pg_stat_io` (PostgreSQL 16 and later): read, write and extend bytes, buffer hits, fsyncs. |
| SQL Server | Requests | Sessions, running requests, blocked processes, blocking chain heads, the longest wait. |
| SQL Server | CPU | SQL Server's, the other processes' and the machine's CPU. |
| SQL Server | Scheduler | Batch requests, transactions, compilations and recompilations per second; runnable tasks, the work queue, pending IO, workers. |
| SQL Server | Memory | Page life expectancy, memory grants pending and outstanding, total and target server memory, the buffer pool, the plan cache, stolen and available memory, physical memory used. |
| both | Host | CPU, CPU in IO wait, memory used and free, swap, load (where the instance has a host source). |

A cumulative counter is shown as its **rate over each collection interval**. An interval in which the counter was
reset gives no sample, never a dip. A metric the server's version does not have reads no samples.

The tab keeps the Counters page's address: `?kind=` is the family (`db`, `server`, `io` and `sessions` still open
theirs; none shows every family).

## Thresholds are alert rules

A threshold on this page **is** an alert rule ([alerts.md](alerts.md), *Alert rules on a charted metric*): the same
row in the repository, shown here for the instance in view and on the **Alert rules** page for the fleet. So:

- *New threshold* opens the rule form with the metric fixed and this instance as what it covers; change *Covers* to
  a tag or to every instance to set it wider.
- The thresholds a row shows are the rule **in force** for this instance: its own rule over its tag's over the
  fleet's. With a database picked, a rule naming that database comes first.
- *Edit* edits that rule where it lives. Editing a fleet rule from one instance's grid changes it for the fleet; the
  form says what the rule covers. *Override here* leaves the wider rule alone and adds this instance's own.
- The grid colours by the thresholds whether or not anything sends alerts. The alerts need a channel
  ([alerts.md](alerts.md)): the sender judges the rules in its pass.

Edits need the UI login; without it the grid is read only and says why.

## The chart

*Chart* reads the row's samples over the range (`GET /api/metrics/series`). Up to about 600 points are drawn as
stored; a longer range is bucketed, and the chart then draws each bucket's average with its highest and lowest
sample, and says the bucket's length in the legend. The warning and critical values are flat lines across it.

## The API

| Endpoint | Answer |
|---|---|
| `GET /api/metrics?instance=&from=&to=[&db=]` | `grid` (the rows above, with `max_status` ... `current_status` and the rule's columns), `databases`, `engine`, and `writable` with its `reason`. |
| `GET /api/metrics/series?instance=&metric=<family.metric>&from=&to=[&db=]` | `series` (`snapshot_at`, `value`, `max_value`, `min_value`, `samples`), `step_secs` (1 = every sample as stored) and `metric` (label, unit, the thresholds in force). |

The grid, a row's chart and the rule's evaluation read the same function (`pgvigil.metric_points`, migration 0085),
so the three agree.

## Proof

`scripts/proof-alert-rules.sh`, parts G and S: the grid's max, min, average, newest value and sample count of
*Sessions: active sessions* and of *Database: commits* (summed, and for one database) equal hand queries on the
stored samples; a seeded SQL Server series reads its known figures and is coloured against a rule's values; each
engine lists its own families.
