# Statements: filters with shares, Group by, then and now, the suggested index and PostgreSQL depth

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
server is PostgreSQL 13, is `(not sampled)`. A session over the server's Unix socket has no address and is `[local]`.
A parallel worker's samples are left out (they carry the leader's statement). The page says how much of the window's
time was sampled.

A database or user that no longer exists (a dropped role still in `pg_stat_statements`) is listed as `(none)` and can
be ticked like any other value.

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

- A sequential scan whose filter compares plain columns of its table with a value or a parameter (`=`, `= ANY` of a
  constant list, `<`, `<=`, `>`, `>=`, `IS NULL`) suggests a btree index on those columns, the equality columns first
  and one range column last: `CREATE INDEX CONCURRENTLY ON big (n)`. Names are quoted as `quote_ident` would quote
  them (`"user"`, `"Orders"`).
- The table is schema-qualified when the plan names its schema (EXPLAIN VERBOSE). When it does not, the text names
  the table the statement's `search_path` finds, and **Details** says to qualify it before running it.
- A scan of a partitioned table is a scan of each partition, so the suggestion names a partition. An index on the
  parent is the DBA's call.
- **Details** gives the reasoning: the scan, its estimated rows (and, from EXPLAIN ANALYZE, the actual rows and the
  rows the filter removed), and the conditions the index serves.
- A filter with an `OR`, a `LIKE`, a cast column (`(created_at)::date = ...`) or an expression gets no suggestion,
  and the page names which one. A LIKE needs
  `text_pattern_ops` or a `pg_trgm` index, and an expression index is the DBA's call.
- Under a statement, pgvigil reads the statement's newest stored plan: by its queryid (pg_store_plans) or by its shape
  (an EXPLAIN of its text or an auto_explain line). With no plan stored, the box links to Plans to EXPLAIN it.

Every suggestion is labelled **not planner-checked** until the planner checks it. **Check with the planner (hypopg)**
plans the statement twice through the monitoring login, once as it is and once with the suggested index created as
a hypothetical index by [hypopg](https://github.com/HypoPG/hypopg). Nothing is executed and nothing is created: the
hypothetical index lives only in that session, which runs in a read-only transaction, calls `hypopg_reset()` and
rolls back. The statement is prepared through the extended protocol, which takes one statement only. The answer is
the plan's cost before and after, and whether the plan uses the index: **lower cost**, **used, cost not lower** or
**not used**. The page sends the index text it shows; if the plan was captured again since (its scans in another
order), the check is refused and asks for a reload.

- The check goes through the actions door: the UI login, the `X-Pgvigil` header, a reason, and an audit row in the
  actions log (`hypo_index`, with the index, the statement under the query-text policy, the outcome and the detail).
- It is **off by default** per instance. Turn it on with `hypo_index: true` on the instance in the config:

  ```yaml
  instances:
    - name: prod-main
      dsn: env:PGVIGIL_PROD_MAIN
      hypo_index: true
  ```

- hypopg must be installed in the statement's database (`CREATE EXTENSION hypopg`, the client DBA's choice), in any
  schema: pgvigil calls its functions in that schema.
  Without it the answer is "not planner-checked: hypopg is not installed in database X" and the attempt is audited.
- The monitoring login must be able to plan the statement (SELECT on its tables, or `pg_read_all_data` on PostgreSQL
  14 and later), as for EXPLAIN.

pgvigil never runs the CREATE INDEX. The text is for the DBA. `CONCURRENTLY` does not block writes but waits for every
older transaction, so an idle-in-transaction session stalls it.

## PostgreSQL depth

Five collections read what `pg_stat_statements`' time and calls leave out. Their sections sit on the Statements tab
(statement depth, functions), the IO tab (the server state, the SLRU caches) and the Indexes tab (the depth findings,
btree bloat, sequences, the catalog checks). Each section says what it needs when a read is missing.

| Collection | Cadence | Reads |
|---|---|---|
| `statements` | 5 min | `pg_stat_statements`, now with planning, JIT, WAL and worker counters (below) |
| `dbstats` | 1 min | also one server-state row: the last checkpoint, WAL since its redo point, timeline, system identifier, client sessions, standbys, archive backlog, `pg_wal` |
| `functions` | 5 min | `pg_stat_user_functions`, every connectable database, the 500 busiest of each |
| `dbchecks` | 1 h | sequences and the catalog checks, every connectable database; MD5 passwords from `pg_authid` |
| `slru` | 5 min | `pg_stat_slru` (PostgreSQL 13 and later) |
| `index_bloat` | 1 h | a btree bloat estimate for every valid btree index of 10 MB or more, every connectable database |

### Statement depth

Per statement over the window: plans and planning time (and its share of planning plus execution), JIT functions and
JIT time (generation, inlining, optimization, emission and deform, added up), WAL records, full-page images and their
share of the records, WAL bytes and WAL buffers full, parallel workers planned, launched and not launched, generic and
custom plan counts, local and temp blocks, and the statement's share of every statement's execution time in the
window. Sorts: planning time, execution time, JIT time, WAL bytes, full-page images, workers not launched.

A column the installed `pg_stat_statements` lacks stays blank, never 0:

| Columns | From |
|---|---|
| plans, planning time, WAL records, full-page images, WAL bytes, local blocks | 1.8 (PostgreSQL 13) |
| JIT functions and times (generation, inlining, optimization, emission) | 1.10 (15) |
| JIT deform | 1.11 (17) |
| WAL buffers full, parallel workers to launch and launched | 1.12 (18) |
| generic and custom plan counts | read where a later version has them: 1.12, PostgreSQL 18's, does not |

Plans and planning time stay 0 unless `pg_stat_statements.track_planning` is on (off by default: it costs a little on
very busy servers). Rows stored before this release carry no depth counters, and the first interval after the upgrade
has none either.

### Functions

`pg_stat_user_functions` per database: calls, total time (with the functions it calls), self time (without them), per
call, and each function's share of every function's time over the window. `track_functions` decides what is counted:
`pl` counts PL/pgSQL and other procedural functions, `all` adds SQL and C functions, `none` (the default) counts
nothing. The section lists each database's setting, since `ALTER DATABASE ... SET track_functions` can differ from the
server's. An SQL function the planner inlines is never counted.

### WAL, checkpoints and connections

From the minute read: the last checkpoint's time (from the control file: `pg_control_checkpoint()`, open to every
login) and the WAL written since its redo point, which is what crash recovery would replay; the server's timeline (a
primary's current WAL file, a standby's WAL receiver: a promotion shows at once, not at the next checkpoint) and the
system identifier (a standby with no WAL receiver running has none, rather than a restartpoint's that may lag a
promotion); the client sessions against the slots a client may use (`max_connections` less
`superuser_reserved_connections` and, from 16, `reserved_connections`); the physical standbys streaming from the
server (a walsender of a logical slot is not counted); and, with `pg_monitor`, the `.ready` files the archiver has not
sent and `pg_wal`'s segments and size. The ages are the server's own clock's, so a skewed collector clock never moves
them. Aurora keeps no local WAL or control file: it shows connections and standbys
only.

### SLRU caches

`pg_stat_slru` per cache (PostgreSQL 13 and later): pages hit, read from disk, written, zeroed, flushes and truncations
over the window. PostgreSQL 17 renamed the caches (`Subtrans` became `subtransaction`, `MultiXactMember`
`multixact_member`): the page groups both spellings. Pages read from disk in the subtransaction cache come from a
transaction with more than 64 subtransactions (a `SAVEPOINT` or a PL/pgSQL `EXCEPTION` block per row) while other
sessions take snapshots: every reader then looks each row's transaction up in `pg_subtrans`. In the multixact caches
they come from many sessions locking the same rows (`FOR SHARE`, `FOR KEY SHARE`, foreign keys).

### Sequences

Every sequence (2,000 per database at most, the fullest first): its last value against the smaller of its own maximum
and the maximum of the column it feeds (an identity or serial column, or a `DEFAULT nextval()`): a `bigint` sequence
behind an `integer` column runs out at 2,147,483,647. Its block reads and hits from `pg_statio_user_sequences`. Reading
a sequence's value needs SELECT or USAGE on it: `pg_read_all_data` on 14 and later, or a grant. A sequence the login
may not read is listed with no value. A cycling sequence is never a finding. A descending sequence is measured against the
larger of its own minimum and its column type's; a limit of 0 (a countdown to 0) has no share.

### Btree bloat

An estimate from the catalog for every valid btree index of 10 MB or more: a leaf tuple is the 8-byte index tuple
header plus its columns' widths (a fixed-width type's length, a variable one's `pg_stats` average width), rounded up
to 8 bytes, plus its 4-byte line pointer. A page holds (block size less 40 bytes) times the fillfactor of them, the rows
are the table's row estimate (the index's own for a partial index), and one metapage and one level of inner pages are
added. The bloat is the size less that estimate; an index not estimated has no bloat figure (never 0). Each row carries `REINDEX INDEX CONCURRENTLY <index>;` as text.

- A variable-width column needs the table's statistics and the login's right to read them (`pg_read_all_data`, or
  SELECT on the table). Without them, and for an expression column or a table never vacuumed or analyzed, the row says
  why it is not estimated.
- Deduplication (13 and later) is not modelled. An index of many equal keys is smaller than the estimate, so it reads
  as less bloated than it is, never as more.
- `REINDEX INDEX CONCURRENTLY` (12 and later) does not block writes but waits for older transactions and needs about
  the index's size again on disk while it runs. Run it alone, outside a transaction. pgvigil never runs it.

### Catalog checks

Per database: a `SECURITY DEFINER` function without its own `search_path` (an extension's functions left out), a
`NOT VALID` check or foreign key with its `ALTER TABLE ... VALIDATE CONSTRAINT` line, a DEFAULT partition that holds
rows, and CREATE on schema `public` for PUBLIC (the default before 15). Once per instance: the login roles whose
password is an MD5 hash. `pg_authid` is a superuser's read, so with any other login the MD5 check is not made, and the
run says so in no error.

### The findings

`pgvigil.pg_depth_findings` (source `pg-depth`) holds one row per broken rule. Each row names the line that fixes it:

| Finding | Severity | Rule |
|---|---|---|
| checkpoint late | warning | the last checkpoint is older than twice `checkpoint_timeout` plus a minute while 16 MB or more of WAL waits since its redo point (an idle server skips its timed checkpoints and raises nothing); a primary's |
| archive backlog | warning | 10 or more `.ready` files, or the oldest over 30 minutes old |
| timeline changed | warning | the timeline differs from a read in the 24 hours before the newest: a promotion, a failover, a point-in-time restore; it clears 24 hours on |
| system identifier changed | critical | the instance's name now reaches another cluster (a rebuild, a restore, a DSN pointed elsewhere) |
| no standby | info | a self-managed primary with no physical standby streaming (a managed platform's standby is not visible) |
| connections near the limit | warning, critical at 100 % | 90 % or more of the client slots used |
| subtransaction SLRU reads, multixact SLRU reads | warning | 50 or more pages read from disk between the two newest SLRU reads (the few a start or a multixact truncation reads are not the overflow) |
| sequence near its maximum | warning, critical at 98 % | 90 % or more used |
| SECURITY DEFINER without search_path | warning | the fix: `ALTER ROUTINE ... SET search_path = pg_catalog, pg_temp` (a function or a procedure) |
| NOT VALID constraint | info | the fix: `ALTER TABLE ... VALIDATE CONSTRAINT ...` (a domain's: `ALTER DOMAIN`) |
| rows in a DEFAULT partition | info | live rows in a DEFAULT partition |
| CREATE on schema public | warning | the fix: `REVOKE CREATE ON SCHEMA public FROM PUBLIC` |
| MD5 password | warning | a login role with an MD5 password hash |
| dead rows | warning | 100,000 dead rows or more and 20 % or more of the table's rows (the tables collection) |
| index bloat | info, warning at 1 GB of bloat | 50 % or more of an index of 10 MB or more |

The proof `scripts/proof-pg-depth.sh` raises each finding with a state seeded on PostgreSQL 13, 16 and 18 and clears it
by its undo there. The 24-hour expiry of the timeline and system-identifier findings is proven with a stored read 25
hours later. The new columns are checked against a hand read of the server. Not proven: the subtransaction SLRU
finding's live seed on PostgreSQL 16 (it passed there once and then not in three runs: its session's scan did not take the
pg_subtrans path, cause unknown); the finding is proven live on 13 and 18.

## API

| Route | What it returns |
|---|---|
| `GET /api/stmtgroups?instance=&from=&to=&group=query\|db\|user\|client&db=&user=&client=&limit=` | `facets` (each value with its share and whether it is ticked), `groups`, `totals` (the whole, the ticked total, the sampled share) |
| `GET /api/stmttrend?instance=&from=&to=&queryid=&db=` | one statement per interval: calls, rows, total and mean time, shared hit and read, temp read and written, the log's longest run |
| `GET /api/stmtlag?instance=&from=&to=&queryid=&db=&lag=<secs>` or `&at=<time>` | the window, one day earlier and the chosen lag, each with its snapshots |
| `GET /api/plans/suggest?id=<plan>` or `?instance=&queryid=&db=` | the suggestions with their reasoning, the scans that suggested nothing and why, whether the check is on |
| `POST /api/plans/hypo` `{plan_id, n, ddl, reason}` | the check of suggestion `n`: checked, used, the cost before and after, audited |
| `GET /api/pgdepth?instance=&part=&from=&to=&order=&limit=` | PostgreSQL depth: `part` = `statements` (order plan, time, jit, wal, fpi, workers), `functions` (order total, self, calls, mean; and each database's `track_functions`), `wal` (the newest server state and the state over the window), `slru` (per cache totals and per read), `sequences`, `bloat`, `checks`, `findings` |

The SQL is in migration `0078_stmt_groups.sql`: `stmt_window_rows`, `stmt_groups`, `stmt_facets`,
`stmt_trend_detail` and `stmt_lag`. The PostgreSQL depth reads are migration `0095_pg_depth.sql`'s: `statement_depth`, `function_top`,
`slru_rate`, the views `wal_state_latest`, `slru_latest` and `pg_depth_findings`, and the tables `sequence_state`,
`db_checks` and `index_bloat`.
