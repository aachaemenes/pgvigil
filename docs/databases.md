# Tables, connections and databases

Four reads that answer "which tables are busy now", "who holds the connections", "is this instance healthy at a
glance" and "which databases came and went". Each says where its numbers come from and what it cannot see.

## The busiest tables (Table Size tab, "Busiest tables in the window")

The top 5, 10 or 25 tables of the instance by **sequential scans**, **rows inserted**, **rows updated** (with the HOT
share), **rows deleted** and **disk I/O reads** (the heap, index and TOAST blocks read from outside shared buffers)
over the page's time range (pgwatch's Tables Overview).

- Source: the `table_activity` collection, every 5 minutes, reads `pg_stat_user_tables` and, from this version on,
  `pg_statio_user_tables`' block counters in every database the login may connect to (the connected one on its own
  connection, each other on a short connection of its own, as the `tables` collection does). Only the statistics views
  are read: no size function, no lock taken.
- Per database it keeps the 100 tables that lead each counter - sequential scans, inserts, updates, deletes and heap +
  index blocks read - (cumulatively since the statistics reset); with fewer tables than that every table is read, idle
  ones included, so a table's first rise has a base. Disk I/O reads count only reads that hold the block counters.
- The window's number is the sum of the rises between consecutive reads, the read just before the window (up to a
  day back) being the base. A step is a reset when a counter fell (a statistics reset, a crash, a failover): it counts
  the new values. A reset whose counters climb past their old values within one 5-minute step is not seen, and that
  step counts low (the database's `stats_reset` cannot mark it: from PostgreSQL 15 a single table's reset moves it).
- A range longer than 7 days is cut to its last 7 (the section says which span it shows): the read orders every
  5-minute read of every table, and a long range can pass the page's statement timeout (not measured). A table first read inside the window (it joined a busy database's top 100 late) counts from that read:
  the "counted from" column says so.
- The ranks are instance-wide: every database's tables compete.

## A table's activity (Table Details, "Activity")

Beside its size and its live and dead rows, a table's page draws, per `table_activity` read in the time range, the
change since the read before it: **sequential and index scans**, **rows inserted, updated and deleted**, and the
**buffer hit** - the heap and index blocks found in shared buffers, as a share of those found plus those read from
outside (pgwatch's table details). A counter that fell (a statistics reset) leaves that read's changes out, and the
section says how many resets the range holds. The buffer hit needs the block counters, read from this version on: a
read before it has none, and the section says so. A table outside its database's busiest 100 by every counter is not
read every 5 minutes: its page says so instead of drawing charts.

## UNUSED (Table Size tab, beside a table's total size)

A table with no sequential and no index scan since the statistics reset (pghero marks unused indexes the same way):
it is written or kept, never read. The biggest tables of each database carry the mark; the counts reset with the
statistics, so a recent reset makes every table look unused until it is read.

## Connection sources (Connections page)

One row per source, grouped by any of **application**, **user**, **database** and **client** (the checkboxes; all
four by default), with its states, over the page's time range (pghero's connection sources).

- Source: the `connections` collection, every minute, counts every client backend of `pg_stat_activity` per
  application, user, database and client (`client_hostname`, else the address, else `local socket`), with how many
  are active, idle, idle in a transaction and waiting on a lock. Idle connections are counted here; the activity
  samples keep only active and idle-in-transaction sessions.
- average: the connections per read over every read of the window (a read the source was absent from counts 0);
  peak: the most at one read; newest read: the count at the window's last read; share: the source's part of all the
  window's connections.
- A login without `pg_monitor` (or `pg_read_all_stats`) sees other users' sessions without their state or client:
  they count as "state not shown".
- Over 500 sources at one read the smallest are folded into one row named "(other sources)" in all four columns,
  so it stays apart whatever the grouping.

## The tile wall (instance Summary)

Numbers coloured against a threshold (pgwatch's Health Check), from the newest activity read of the range:

| tile | warning | critical |
| --- | --- | --- |
| xmin horizon age: `age(backend_xmin)` of the oldest client session | 1,000,000 | 100,000,000 |
| idle in transaction: sessions (and the longest, seconds) | 1 (60 s) | 5 (600 s) |
| blocked sessions: `wait_event_type = 'Lock'` | 1 | 5 |
| longest query: the oldest running statement | 60 s | 600 s |
| connections used: client backends / `max_connections` | 75 % | 90 % |
| cache hit over the range: `blks_hit / (blks_hit + blks_read)`, every database | under 95 % | under 90 % |

The xmin tile is the client sessions' horizon only; a replication slot or a prepared transaction can hold it further
back (the Replication and Vacuum pages show those).

The safety settings, from the newest instance read, as on / off tiles: `fsync` and `full_page_writes` off are
critical (a crash can corrupt the cluster or leave a torn page), `synchronous_commit` off is a warning (a crash can
lose the last commits, no corruption), data checksums off and `wal_level = minimal` are warnings.

## New and dropped databases (fleet and instance)

Both engines, newest first, over the last 7, 30, 90 or 365 days (DBA Dash's New Databases and Deleted Databases).

- **SQL Server** (tempdb, re-created at every start, and database snapshots left out): the creation time is the server's own (`sys.databases.create_date`, from the `mssql_backups`
  collection); a database created anew under an old name shows its new date. Dropped: the backups read no longer
  lists it; its size is the last data + log size the storage collection read; dropped by: the first storage read
  that no longer listed it.
- **PostgreSQL** keeps no creation time. A database is new when the hourly `databases` collection first saw it after
  the instance's first read; it was created between the read before and that read. Dropped: a read no longer lists
  it; it went between its last read and the next one, and its size is the size of its last read. A database created
  and dropped between two hourly reads is never seen. PostgreSQL rows older than the repository's retention (the
  purge days) are gone with the history behind them; SQL Server's stay, so a range past the retention shows the two
  engines differently.

## API

| route | parameters | parts |
| --- | --- | --- |
| `GET /api/tables/top` | `instance`, `from`, `to` (at most the last 7 days used), `n` (1-50, default 10) | `tables` (each row with its four ranks), `meta` (n, from_at, to_at, reads) |
| `GET /api/connections` | `instance`, `from`, `to`, `by` (comma list of application, user, database, client) | `sources`, `meta` |
| `GET /api/tiles` | `instance`, `from`, `to` | `tiles` |
| `GET /api/dbchanges` | `instance` (none = the fleet), `days` (1-366, default 30) | `changes`, `meta` |

The repository functions behind them (migration 0080): `table_activity_top`, `conn_sources_window`,
`instance_tiles`, `database_changes`. The proof is `scripts/proof-tables-conn.sh`.

## Autovacuum over time (Vacuum page)

Below its tiles and checks the Vacuum page draws, over the time range (coroot's autovacuum charts), from what the collector
already keeps:

- **Autovacuum workers**: per minute sample, the autovacuum workers running against `autovacuum_max_workers`. A
  minute with nothing running stores no sample. The setting's history is not kept: the line is its value as last read.
- **Dead tuples by table**: the 5 tables with the most dead tuples at the range's newest table size read, each a point
  per read.
- **Autovacuum pressure**: per table size read, the tables whose dead tuples are past autovacuum's trigger
  (`autovacuum_vacuum_threshold` + `autovacuum_vacuum_scale_factor` x live rows, capped by
  `autovacuum_vacuum_max_threshold` unless -1) with the instance's settings as last read. A table's own autovacuum
  settings are not read here (the grid below reads them).
