# Diff, connections over time and the grids

This page covers five reads that came with migration 0086: the **Diff** page, the stacked chart on the
**Connections** page, a job's **duration and run chart** with its step cut, the fleet **Table size** page and the
detail columns of a PostgreSQL instance's **Configuration** page. None of them adds a collection: each reads what
the repository already keeps. The one collector change is a second list in the hourly instance read (the settings'
detail).

## Diff

The Diff page puts two sides, A and B, next to each other and lists what differs. It follows DBA Dash's Diff menu
(Database Schema Diff, Agent Job Diff) with the settings added; the schema part exists for PostgreSQL only. Differences only, unless **Show identical rows** is
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
| Settings | the settings the hourly instance read lists: those set in a configuration file, on the command line, in the environment, or by `ALTER DATABASE` for the database the collector connects to | `sys.configurations`, the values in use |
| Jobs     | pg_cron and pgAgent jobs, each as its stored definition                     | SQL Server Agent jobs, each as its stored definition    |
| Schema   | the schema collection's objects ([schema.md](schema.md))                     | not compared: the repository holds no schema objects of a SQL Server instance |

A PostgreSQL instance is never compared with a SQL Server instance (the request is refused). Above the result the
page lists the two sides with, per store, its newest read and where its history starts, and it names every section
it did not compare with the reason. A section that is absent is therefore never read as "no difference". A section
is also left out when one side has no read for it yet (an instance added within the hour, a schema collection that
has not run): every row would read "only in" the other side, which is not a difference.

Three limits of what the stores hold:

- **A setting "only in A"** means B does not set it in one of those places. B's running value can still be the same:
  a file that writes out the default, or a role's own setting (`ALTER ROLE ... SET`), which the list never holds.
  An `ALTER DATABASE` setting of another database than the collector's is not listed either.
- **A database the schema collection could not snapshot** (over its object cap, or not connectable) is not on its
  side: against a side that has it, it reads "only in" that side.
- **Jobs** are what the jobs collections stored. A server without a scheduler has none, and so has one whose jobs
  collection has not run; the page says when a side holds no job version.

### How rows are matched

- **Settings** by name. Status: `same`, `different`, `only in A`, `only in B`.
- **Jobs**, one instance at two times: by scheduler and job id. Two instances: by scheduler and job name (a job
  without a name: its command), and among jobs of one name by the order of their ids (9 before 10), because the ids
  of two servers say nothing more about each other; two same-named jobs created in another order on the other
  server therefore pair crosswise. For the same reason the `#<id>` that ends a schedule's or a step's key is left
  out of the comparison between two instances. A job that differs lists each field with both values.
- **Schema objects** by kind and identity (`public.orders`, `orders_pkey on public.orders`). Two instances pair
  their databases by name, or compare the one pair picked. `different` names what differs: `definition`, `owner`,
  `acl`. The definition is compared by its own hash, so a change past the stored 20,000 characters counts. A column,
  index, constraint, trigger or owned sequence whose table is on one side only is folded into the table's row and
  counted there. A database only one side has is one row. One reply lists at most 1,000 schema rows; the counts
  beside the grid cover all of them, and picking a database on each side narrows the list.

### How far back a time can reach

| Store    | What an earlier time reads                                                   | Where it stops                                   |
|----------|-------------------------------------------------------------------------------|--------------------------------------------------|
| Settings, PostgreSQL | the current non-default settings rolled back through the setting change history (one read an hour) | the instance's first read |
| Settings, SQL Server | the value in use, or the previous value when the last change came later | **one** earlier value per setting is kept: a time before the change before last shows the value of that change |
| Jobs     | the newest version of each job at or before the time (every version is kept) | the job's first read                             |
| Schema   | the changes found between the two times, netted per object, for each database whose snapshot covers both times | each database's first schema read, and the repository's retention (older change partitions are purged) |

Netting means the page shows the difference between the two ends, not every step: an object created and dropped
inside the range has no row; a view changed and changed back has no row (it is `same` when identical rows are
shown). A change is dated by the hourly read that found it, so the two times are compared to the hour, not to the
second. What the change history cannot tell is said on the row instead of guessed:

- **A table dropped and re-created** inside the range is always `different`, marked "re-created (owner and ACL not
  compared)": the history of a drop and of an add holds the definition alone. Its definition is compared.
- **A database first read inside the range** (a new database, one that became connectable, or the instance's first
  schema read) has no snapshot at the earlier time: it is one row, "only in B", and its objects are not listed.
  **A database no longer read by the later time** (dropped, or no longer connectable) is one row, "only in A".
- **A dependent object folded into its table** is counted only when it has a change of its own in the range; one
  that came or went in the same read as its table is part of the table's row already.

### API

`GET /api/diff?a=<instance id>&b=<instance id>[&at_a=<RFC 3339>&at_b=<RFC 3339>][&db_a=<name>&db_b=<name>][&all=1]`

- `a` and `b` differ: two instances as last read (`at_a` and `at_b` are refused); `db_a` with `db_b` picks one pair
  of databases.
- `a` equals `b` with `at_a`: one instance at two times (`at_b` defaults to now; `db_a` narrows the schema part to
  one database).
- `a` equals `b` with two different databases in `db_a` and `db_b`: their schema objects as last read.
- `part=databases` returns only each side's databases with a schema snapshot.
- Refused with 400: two engines, `at_a` or `at_b` with two instances, `at_b` without `at_a`, one of `db_a` and `db_b`
  with two instances, and `db_a` or `db_b` on SQL Server.

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
per step); the runs grid's "step that failed" cell is then filled only on the runs where that step failed. A
PostgreSQL job has the outcome row alone: pg_cron has no steps, and pgAgent's step log is kept on the run (the failed
step is in the runs grid). A SQL Server job still running at the read counts as a run and has no duration yet.

`GET /api/jobs/history?...&scheduler=&job=` adds `stats`, `series` and `series_meta`; `&step=<n>` (with
`engine=mssql`) is the cut.

## Table size (the fleet)

The Table size page at the root of the tree lists the largest tables across the PostgreSQL instances, each database
at its newest table read of the page's range, with the growth over the range: bytes, rows, and both per day. **Rows**
chooses 20, 50, 100 or 500; **Order** the largest or the fastest growing first. Under a tag folder of the tree the
rows and the counts are the folder's own instances'.

- A database whose read failed in the instance's newest run is shown at its own newest read of the day before it;
  the **read** column says which read a row is.
- The growth is measured against the instance's last read at or before the start of the range (at most two days
  earlier), or its first read inside the range when there is none. A table absent from that read (it joined the list
  later) counts from its own first read after it. The **growth since** column gives the time and says when it lies
  inside the range. One read only means no growth figure.
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
| a change needs  | `context`           | what a new value in the file needs before it is in use: a restart (`postmaster`), a reload (`sighup`; `user` and `superuser` settings too, which can also be SET in one session), or a reload and then new sessions (`backend`) |
| pending restart | `pending_restart`   | at the last reload the configuration file held another value than the running server |
| category        | `category`          | the manual's group for the setting                                          |

The grid lists the server-level non-default settings, as before, **and every setting waiting for a restart**, those
first. The second group matters: a restart-only setting that was edited from its default and not yet restarted still
reads source `default`, so a list of non-default sources alone would hide exactly the setting someone is waiting on.
Such a setting is not a change yet: the change history records it when the restart makes it the value in use. The
grid shows the running value; the value that waits is in the server's own file (`pg_file_settings`, a superuser's
read), not in the repository.
PostgreSQL keeps the pending mark until the server restarts or a reload finds the file's value equal to the running
one again; taking the line back out of the file does not clear it. A setting can therefore read pending restart
while no file names it any more: the edit was undone, and a restart would change nothing.

The detail arrives with the next hourly instance read after the upgrade; until then the grid shows the setting and
value alone and says so. Values that can carry a credential stay masked as before.

`GET /api/pgconfig?instance=<id>` (`pgvigil.pg_config_settings`).

## Proof

`scripts/proof-diff-grids.sh` runs on a sandbox PostgreSQL and applies every migration to a fresh PostgreSQL 13.
What it proves, and against what:

- **The diff.** Two monitored databases of one sandbox server, read as two instances, differ by one table, one
  `ALTER DATABASE` setting and one job: the page lists exactly those three. One instance at two times lists exactly
  the table created, the setting set and the job's schedule changed between them. The table and the setting are
  made on the server; the jobs are rows imported in the collectors' shape (no scheduler runs on the sandbox).
- **The chart** against the grid, and against hand counts of `pg_stat_activity` taken at each read.
- **The table sizes** against hand reads of `pg_total_relation_size` before and after 20,000 rows are added.
- **A setting waiting for a restart**: one set by `ALTER SYSTEM` and reloaded reads pending restart with source
  `default`.
- **Seeded rows** for the cases a sandbox does not give: SQL Server settings and jobs, a re-created table, a database
  dropped or first read between the two times, a database missing from the newest table read, jobs of one name.

Not proven there: the pages in a browser (the accessibility check and the looks are separate), a real pg_cron,
pgAgent or SQL Server (their collectors have their own proofs), the 1,000-row cap, and the timings on a large fleet.
