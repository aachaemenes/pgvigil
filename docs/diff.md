# Diff, connections over time and the grids

This page covers five reads that came with migration 0086: the **Diff** page, the stacked chart on the
**Connections** page, a job's **duration and run chart** with its step cut, the fleet **Table size** page and the
detail columns of a PostgreSQL instance's **Configuration** page. None of them adds a collection: each reads what
the repository already keeps. The one collector change is a second list in the hourly instance read (the settings'
detail).

## Diff

The Diff page puts two sides, A and B, next to each other and lists what differs. It is DBA Dash's Diff menu
(Database Schema Diff, Agent Job Diff) with the settings added. Differences only, unless **Show identical rows** is
ticked. The picks ride in the page's address, so a diff is a link.

| Compare                        | What the two sides are                                              | Sections                    |
|--------------------------------|----------------------------------------------------------------------|-----------------------------|
| Two instances                  | each instance as it was last read; one engine on both sides          | settings, jobs, schema      |
| One instance at two times      | the instance at an earlier time (A) and a later one (B, default: the newest read), from the change histories | settings, jobs, schema |
| Two databases of one instance  | two databases as last read                                           | schema                      |

Two instances are never compared at a past time: the histories hold one instance's past, and the page says so
rather than guess.

What each section compares, and on which engine:

| Section  | PostgreSQL                                                                 | SQL Server                                              |
|----------|-----------------------------------------------------------------------------|---------------------------------------------------------|
| Settings | the server-level non-default settings of the hourly instance read; a setting only one side lists is at its default on the other | `sys.configurations`, the values in use |
| Jobs     | pg_cron and pgAgent jobs, each as its stored definition                     | SQL Server Agent jobs, each as its stored definition    |
| Schema   | the schema collection's objects ([schema.md](schema.md))                     | not compared: the repository holds no schema objects of a SQL Server instance |

A PostgreSQL instance is never compared with a SQL Server instance (the request is refused). Above the result the
page lists the two sides with, per store, its newest read and where its history starts, and it names every section
it did not compare with the reason. A section that is absent is therefore never read as "no difference".

### How rows are matched

- **Settings** by name. Status: `same`, `different`, `only in A`, `only in B`.
- **Jobs**, one instance at two times: by scheduler and job id. Two instances: by scheduler and job name (a job
  without a name: its command), and among jobs of one name by their order, because the ids of two servers say
  nothing about each other. For the same reason the `#<id>` that ends a schedule's or a step's key is left out of
  the comparison between two instances. A job that differs lists each field with both values.
- **Schema objects** by kind and identity (`public.orders`, `orders_pkey on public.orders`). Two instances pair
  their databases by name, or compare the one pair picked. `different` names what differs: `definition`, `owner`,
  `acl`. The definition is compared by its own hash, so a change past the stored 20,000 characters counts. A column,
  index, constraint, trigger or owned sequence whose table is on one side only is folded into the table's row and
  counted there. A database only one side has is one row. One reply lists at most 1,000 schema rows; the counts
  beside the grid cover all of them, and picking one database narrows the list.

### How far back a time can reach

| Store    | What an earlier time reads                                                   | Where it stops                                   |
|----------|-------------------------------------------------------------------------------|--------------------------------------------------|
| Settings, PostgreSQL | the current non-default settings rolled back through the setting change history (one read an hour) | the instance's first read |
| Settings, SQL Server | the value in use, or the previous value when the last change came later | **one** earlier value per setting is kept: a time before the change before last shows the value of that change |
| Jobs     | the newest version of each job at or before the time (every version is kept) | the job's first read                             |
| Schema   | the changes found between the two times, netted per object                    | each database's first schema read, and the repository's retention (older change partitions are purged) |

Netting means the page shows the difference between the two ends, not every step: an object created and dropped
inside the range has no row; a view changed and changed back has no row (it is `same` when identical rows are
shown); a table dropped and re-created with another definition is `different`. A change is dated by the hourly read
that found it, so the two times are compared to the hour, not to the second.

### API

`GET /api/diff?a=<instance id>&b=<instance id>[&at_a=<RFC 3339>&at_b=<RFC 3339>][&db_a=<name>&db_b=<name>][&all=1]`

- `a` and `b` differ: two instances as last read (`at_a` and `at_b` are refused); `db_a` with `db_b` picks one pair
  of databases.
- `a` equals `b` with `at_a`: one instance at two times (`at_b` defaults to now; `db_a` narrows the schema part to
  one database).
- `a` equals `b` with two different databases in `db_a` and `db_b`: their schema objects as last read.
- `part=databases` returns only each side's databases with a schema snapshot.

The reply holds `sides`, `meta`, `databases`, `coverage`, and for each compared section its rows and a count per
status (`settings`, `settings_counts`, `jobs`, `jobs_counts`, `schema`, `schema_counts`). The SQL behind it is
`pgvigil.diff_settings`, `diff_jobs`, `diff_schema`, `diff_schema_snapshots` and `diff_sides`.

## Connections over time

Above the Connections grid a stacked chart shows the connections over the page's range by one dimension:
application, user, database or client (**Chart by**). The eight sources with the most connections over the range
each get a band under their own name; the rest are one band, `other`. A point is the average number of connections
per read in its bucket, so the bands add up to the instance's connections and the top line is the total. A bucket is
a whole number of minutes (about 300 buckets over the range, never under the collection's one minute). A read in
which no client was connected still counts as a read, and a source absent from a bucket draws 0 there.

The chart and the grid are the same numbers: per source, the sum of the chart's connections divided by its reads is
the grid's **average**, and the highest read is the grid's **peak**. PostgreSQL only: the connection sources are
collected from `pg_stat_activity`.

`GET /api/connections?...&chart=<application|user|database|client>` adds `series` and `series_meta` to the reply
(`pgvigil.conn_sources_series`).

## A job's chart and its steps

Picking a job on the Jobs page now shows, above its runs:

- **Duration**: the average and the longest run per bucket.
- **Runs**: the runs per bucket, succeeded and failed stacked. A bucket without a run counts 0, so a job whose runs
  all take 0 seconds still draws its runs (the duration line then sits at 0).
- **Steps**: one row per step with a run in the range: failed, succeeded, retry and cancelled runs, the average,
  longest, shortest and total duration, and the last run. The first row is the job's own outcome.

On SQL Server a step's button cuts the charts, the counts and the runs grid to that step's rows (msdb keeps a row
per step). A PostgreSQL job has the outcome row alone: pg_cron has no steps, and pgAgent's step log is kept on the
run (the failed step is in the runs grid).

`GET /api/jobs/history?...&scheduler=&job=` adds `stats`, `series` and `series_meta`; `&step=<n>` (with
`engine=mssql`) is the cut.

## Table size (the fleet)

The Table size page at the root of the tree lists the largest tables across the PostgreSQL instances, each at its
newest table read of the page's range, with the growth over the range: bytes, rows, and both per day. **Rows**
chooses 20, 50, 100 or 500; **Order** the largest or the fastest growing first.

- The growth is measured against the instance's last read at or before the start of the range (at most two days
  earlier). An instance first read inside the range, or a table that joined the list later, counts from its first
  read inside the range; the **growth since** column says so. One read only means no growth figure.
- The repository keeps an hourly size for the largest tables of each database (the tables collection's top 25), so
  a smaller table is not on this page, and neither is a table the newest read no longer lists.
- Heap, TOAST and index sizes are shown when the range ends at the newest read.
- PostgreSQL only. The repository holds no table sizes of a SQL Server instance; the page counts the SQL Server
  instances it does not cover and points at their Storage page. A line above the grid says on how many PostgreSQL
  instances no table was read in the range.

`GET /api/tablesize?from=&to=[&top=20|50|100|500][&order=size|growth]` (`pgvigil.table_size_fleet`).

## Configuration: the settings' detail

The settings grid of a PostgreSQL instance's Configuration page now has, beside the setting and its value:

| Column          | From `pg_settings`  | Meaning                                                                    |
|-----------------|---------------------|----------------------------------------------------------------------------|
| unit            | `unit`              | the unit of the value and of the default (`8kB`, `kB`, `ms`, `s`, ...)       |
| default         | `boot_val`          | the value the server would use with nothing set                             |
| source          | `source`            | where the value in use comes from (configuration file, command line, database, default, ...) |
| a change needs  | `context`           | a restart (`postmaster`), a reload (`sighup`), or only a session            |
| pending restart | `pending_restart`   | the configuration file holds another value than the running server          |
| category        | `category`          | the manual's group for the setting                                          |

The grid lists the server-level non-default settings, as before, **and every setting waiting for a restart**, those
first. The second group matters: a restart-only setting that was edited from its default and not yet restarted still
reads source `default`, so a list of non-default sources alone would hide exactly the setting someone is waiting on.
Such a setting is not a change yet: the change history records it when the restart makes it the value in use.
PostgreSQL keeps the pending mark until the server restarts or a reload finds the file's value equal to the running
one again; taking the line back out of the file does not clear it. A setting can therefore read pending restart
while no file names it any more: the edit was undone, and a restart would change nothing.

The detail arrives with the next hourly instance read after the upgrade; until then the grid shows the setting and
value alone and says so. Values that can carry a credential stay masked as before.

`GET /api/pgconfig?instance=<id>` (`pgvigil.pg_config_settings`).

## Proof

`scripts/proof-diff-grids.sh` proves the above on a sandbox PostgreSQL and applies every migration to a fresh
PostgreSQL 13: two instances that differ by one table, one setting and one job show exactly those three; one
instance at two times shows exactly the three changes made between them; the chart's totals equal the grid's and
the hand counts of `pg_stat_activity`; the fleet's table sizes equal hand reads of `pg_total_relation_size`; a
setting edited and not restarted reads pending restart with source `default`.
