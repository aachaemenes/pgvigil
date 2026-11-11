# Statements: filters with shares, Group by, then and now, and the suggested index

The Statements page of a PostgreSQL instance reads `pg_stat_statements` as per-interval differences (the
`statements` collection). Four parts follow PMM's Query Analytics, pgwatch's Query ID drill and PgHero's Queries page.

## Filters with shares and Group by

On top of the page a **Filters** panel lists every database, user and client host of the window, each with its share
of the total execution time, as a checkbox:

- A tick narrows the page at once; several ticks in one group are an OR, ticks in two groups an AND.
- A group's shares are over the statements the other groups' ticks leave, so a ticked database still lists the other
  databases with their shares (a faceted filter, as PMM's).
- **Reset all** clears every tick. The ticks ride the page's link (`sg`, `sdb`, `suser`, `scl`), so a link keeps them.

**Group by** switches the grid beside it between the statements, the databases, the users and the client hosts. Each
row has its total time, its **share** of the ticked statements' time (a number and a bar), its share **of all**
statements' time, calls, the time per call, rows, IO blocks and the cache hit ratio.

The client host is an estimate. `pg_stat_statements` keeps no client: a statement's time is split over the hosts the
running-queries samples saw it from, in proportion to the samples (PostgreSQL 14 and later, with `compute_query_id`
on or `auto` with `pg_stat_statements` loaded). A statement the samples never saw, because it is short or because the
server is PostgreSQL 13, is `(not sampled)`. The page says how much of the window's time was sampled.

The **Top statements** grid below keeps its seven sorts. Its total time carries the statement's share of all
statements' time in the window in grey beside it, as PgHero shows it. The whole is every statement of the window,
not only the hundred listed.

## A statement's history: calls, time per call and buffers

**History** on a statement's row opens its trend under the row, over the page's window in about 72 intervals:

- **Calls** per interval.
- **Time per call** and the longest run of the same statement the server log recorded (statements over
  `log_min_duration_statement`; `pg_stat_statements` keeps no maximum).
- **Buffers**: shared hit, shared read and temp written per interval, and the hit and read **per call**.
- **Rows** per interval.

The numbers are also in a table under the charts.

## Then and now

Under the charts, **Then and now** puts the statement's window beside the same window one day earlier (day over day)
and beside a chosen lag: **1 h**, **1 d** or **7 d** earlier, or a window starting at a chosen date and time. Each
row has the calls, the time per call, the total, the buffers and how much each changed ("now vs then", + = higher
now). A compared window in which pgvigil read no statements at all says **no data**. A window that was read but in
which the statement did not run shows no calls.

## The suggested index

Under a plan (Plans, one plan) and under a statement's history, pgvigil suggests an index where the plan reads a whole
table to keep a few rows:

- A sequential scan whose filter compares plain columns of its table with a value or a parameter (`=`, `<`, `<=`,
  `>`, `>=`, `IS NULL`) suggests a btree index on those columns, the equality columns first and one range column
  last: `CREATE INDEX CONCURRENTLY ON big (n)`.
- **Details** gives the reasoning: the scan, its estimated rows (and, from EXPLAIN ANALYZE, the actual rows and the
  rows the filter removed), and the conditions the index serves.
- A filter with an `OR`, a `LIKE` or an expression gets no suggestion, and the page names which one. A LIKE needs
  `text_pattern_ops` or a `pg_trgm` index, and an expression index is the DBA's call.
- Under a statement, pgvigil reads the statement's newest stored plan: by its queryid (pg_store_plans) or by its shape
  (an EXPLAIN of its text or an auto_explain line). With no plan stored, the box links to Plans to EXPLAIN it.

Every suggestion is labelled **not planner-checked** until the planner checks it. **Check with the planner (hypopg)**
plans the statement twice through the monitoring login, once as it is and once with the suggested index created as
a hypothetical index by [hypopg](https://github.com/HypoPG/hypopg). Nothing is executed and nothing is created: the
hypothetical index lives only in that session, which runs in a read-only transaction, calls `hypopg_reset()` and
rolls back. The answer is the plan's cost before and after, and whether the plan uses the index.

- The check goes through the actions door: the UI login, the `X-Pgvigil` header, a reason, and an audit row in the
  actions log (`hypo_index`, with the index, the statement under the query-text policy, the outcome and the detail).
- It is **off by default** per instance. Turn it on with `hypo_index: true` on the instance in the config:

  ```yaml
  instances:
    - name: prod-main
      dsn: env:PGVIGIL_PROD_MAIN
      hypo_index: true
  ```

- hypopg must be installed in the statement's database (`CREATE EXTENSION hypopg`, the client DBA's choice).
  Without it the answer is "not planner-checked: hypopg is not installed in database X" and the attempt is audited.
- The monitoring login must be able to plan the statement (SELECT on its tables, or `pg_read_all_data` on PostgreSQL
  14 and later), as for EXPLAIN.

pgvigil never runs the CREATE INDEX. The text is for the DBA. `CONCURRENTLY` does not block writes but waits for every
older transaction, so an idle-in-transaction session stalls it.

## API

| Route | What it returns |
|---|---|
| `GET /api/stmtgroups?instance=&from=&to=&group=query\|db\|user\|client&db=&user=&client=&limit=` | `facets` (each value with its share and whether it is ticked), `groups`, `totals` (the whole, the ticked total, the sampled share) |
| `GET /api/stmttrend?instance=&from=&to=&queryid=&db=` | one statement per interval: calls, rows, total and mean time, shared hit and read, temp read and written, the log's longest run |
| `GET /api/stmtlag?instance=&from=&to=&queryid=&db=&lag=<secs>` or `&at=<time>` | the window, one day earlier and the chosen lag, each with its snapshots |
| `GET /api/plans/suggest?id=<plan>` or `?instance=&queryid=&db=` | the suggestions with their reasoning, the scans that suggested nothing and why, whether the check is on |
| `POST /api/plans/hypo` `{plan_id, n, reason}` | the check of suggestion `n`: checked, used, the cost before and after, audited |

The SQL is in migration `0078_stmt_groups.sql`: `stmt_window_rows`, `stmt_groups`, `stmt_facets`,
`stmt_trend_detail` and `stmt_lag`.
