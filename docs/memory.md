# Memory and poolers

Two instance tabs: **Memory** (what holds shared_buffers, and the sorts and hashes that spill to temp files) and
**Pooler** (a PgBouncer in front of the instance). Every read is a read: nothing is created, changed or reset on
the monitored server or the pooler.

## The buffer cache (pg_buffercache)

The `buffercache` collection reads PostgreSQL's `pg_buffercache` view hourly, where the extension is installed in
the database pgvigil connects to. Installing it is the server DBA's opt-in, once, as a role that may create
extensions:

```sql
CREATE EXTENSION pg_buffercache;   -- in the database the instance's dsn: names
```

On PostgreSQL 10 and later the view is readable by `pg_monitor`, so the monitoring login needs nothing more.
Without the extension the tab says `not available` with the reason, and the rest of the tab still works.

Each read stores:

- the totals: shared_buffers in pages and bytes, the used and the dirty buffers;
- the 50 relations holding the most buffers: their buffers and size in the cache, their share of shared_buffers,
  their dirty buffers, the mean usage count (0-5: how often the clock sweep found the buffer used) and the buffers
  at usage count 3 or more (the hot part).

The server names a relation's file only within its own database: a relation of another database keeps that
database's name and its file node. The chart shows the used, dirty and largest-relation shares over the time range.

Each read of the view walks every buffer header, so the collection reads it once per run: the buffers are grouped by
relation file in that one pass, and the totals and the 50 largest relations both come from the grouped rows (one row per relation file in the cache).
On a large shared_buffers the walk still takes a moment, which is
why it is hourly.
Set `schedules: {buffercache: 6h}` on an instance to read it less often, or `disabled: [buffercache]` to stop it.

## Temp-file spills

A sort, hash or materialize that does not fit `work_mem` writes temp files. Two sources already in the repository
show them, and the hourly `temp_files` collection rolls them up per hour (the last six hours each time, so a log line
read late still lands in its hour):

- **By statement**: `pg_stat_statements`' `temp_blks_read` and `temp_blks_written` per statement and hour (from the
  statements collection), in bytes by the server's block size, with the statement's text. Only the statements that
  collection keeps are here: each read takes the server's top 500 by execution time and top 200 by calls, so a
  statement outside both cuts is missing, and the hour's statement sum is a floor, not a total (the database
  statistics below count every temp file).
- **By hour**: those summed, beside the log readers' `temporary file: path ..., size N` lines (the count, the bytes
  and the largest file). The server logs only files at or above `log_temp_files` (`-1`, the default, logs none;
  `0` logs every file). The hour also carries the size of the instance's databases at that hour.
- The hour's statement sum counts top-level statements only: with `pg_stat_statements.track = all` a statement run
  inside a function is also counted under the call, and adding both would count its temp files twice. PostgreSQL 13
  has no `toplevel` column, so there every statement reads as top level: with `track = all` on 13 the hour sum can
  count a nested spill twice and reach the 10 % warning early (`track = top`, the default, has no nested rows).

**Temp files by database** is the database statistics' view (pg_stat_database's `temp_files` and `temp_bytes` over
the time range): it counts every temp file, logged or not, which is the closest PostgreSQL has to a TempDB page.

The collection itself reads only the block size and `pg_database_size` of the databases that accept connections
(`pg_monitor` holds `pg_read_all_stats`, which that function needs).

## The pooler (PgBouncer)

Give an instance its pooler's admin console as a separate DSN, `pgbouncer:`, to a login named in PgBouncer's
`stats_users`:

```yaml
instances:
  - name: crm01
    dsn: env:CRM01_DSN
    pgbouncer: env:CRM01_PGBOUNCER   # host=pgb01 port=6432 dbname=pgbouncer user=pgvigil_stats password=...
```

```ini
; pgbouncer.ini
stats_users = pgvigil_stats
```

A `stats_users` login may run `SHOW` commands only; PgBouncer itself refuses it `PAUSE`, `RELOAD`, `KILL` and every
other admin command. The `pgbouncer` collection sends only `SHOW VERSION`, `SHOW POOLS`, `SHOW STATS`,
`SHOW DATABASES`, `SHOW USERS`, `SHOW CONFIG`, `SHOW CLIENTS` and `SHOW SERVERS` ([who waits in the pooler and for which backend](pooler.md)), every minute, over the simple query protocol the console speaks. An instance
without `pgbouncer:` is never read for a pooler and has no Pooler tab.

The Pooler tab shows:

- the pools as last read: clients active and waiting, servers active, idle and used, the longest wait, the pool's
  size and mode. The size is the user's own `pool_size` where PgBouncer's `[users]` section sets one (1.17 and
  later; it wins over the database's `pool_size` and over `default_pool_size`), read from `SHOW USERS`, else the
  database's from `SHOW DATABASES`; the grid says which. PgBouncer 1.24.1's `SHOW USERS` repeats the row above on a
  user that sets no size, so a user's value is taken only where it differs from the row above: two users in a row
  with the same size read as the database's;
- the clients and servers over the time range (summed over the pools);
- the per-database rates of `SHOW STATS` (PgBouncer's own per-second averages: queries, transactions, the mean query
  time and the mean client wait) and the totals since the pooler started;
- `SHOW DATABASES` (the pool sizes, the reserve, the connection limits, paused and disabled) and `SHOW CONFIG` as
  last read.

A pooler that cannot be reached shows the error and when it was last read; the collection log says partial.

## Findings

| Finding | Severity | Fires when |
|---|---|---|
| clients waiting on the pooler | warning | a pool's `cl_waiting` is above 0 in every read of the last 5 minutes |
| clients waiting on the pooler | critical | the latest read's `maxwait` is over 5 seconds |
| a pool at its size | warning | `sv_active` equals the pool's `pool_size` in every read of the last 5 minutes |
| temp-file spills | info | a statement wrote more than 1 GB of temp files in one hour of the last 24 |
| temp-file spills | warning | an hour of the last 24 wrote temp files over 10 % of the data size (the larger of the logged bytes and the statements' written bytes) |
| one relation holds over half of shared_buffers | info | the latest buffer cache read |

"Every read of the last 5 minutes" needs reads at least 4 minutes apart within the last 5.5 minutes and one in the
last 2 minutes: a pooler not read lately fires nothing.

## Retention

`buffercache_sample`, `temp_sample` and `pooler_sample` are monthly partitions, dropped by the repository's purge
with the rest of the history; `pooler_state` of an instance not read within the retention is removed.
