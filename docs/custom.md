# Custom checks

pgvigil runs the DBA's own SQL as checks, the way DBADash runs custom collections: each check is a statement in the
configuration's `custom:` list (PostgreSQL's by default; a SQL Server check says `engine: sqlserver`, or names a
procedure: [SQL Server checks](#sql-server-checks)), run by the collector on the instances or tag folders it names, at its own cadence,
judged against its own thresholds. Every run's value, its rows and its error are kept in the repository; a check
that crosses a threshold, fails, or stops running becomes a finding. Each instance has a **Custom** tab (each check's
latest value, its chart over the time range, the rows of its latest run, its SQL) and the root has the **Custom
report** (every check of the fleet, the worst first).

## The rights a check runs with

A check runs as the instance's own monitoring login (the `dsn` of the instance: the `pg_monitor` login) on the
collector's connection, which is read only (`default_transaction_read_only = on`) with a 30 s
statement timeout and a 2 s lock timeout. Each check runs inside its own `BEGIN TRANSACTION READ ONLY` that is always
rolled back:

- a write to a table (`INSERT`, `UPDATE`, `DELETE`, a function that writes to a table), DDL, `nextval` and whatever
  else PostgreSQL refuses in a read-only transaction fails with "cannot execute ... in a read-only transaction"; the
  failure is the check's error, shown on the tab and raised as a finding, and the statement is never retried another
  way;
- a `SET` or `set_config()` inside the check is undone by the rollback, so it cannot change the next check or the
  collector's session;
- one statement only: the server's extended protocol refuses `SELECT 1; DELETE ...`;
- a function whose effect lies outside the transaction is not stopped by READ ONLY: `pg_advisory_lock` keeps its
  lock, `pg_cancel_backend` cancels a session the login may signal; such an effect lasts at most until the end of the
  run, when the collection's connection is closed. The checks are the DBA's own SQL: review them as such;
- READ ONLY does not stop what a server-side right allows: `COPY ... TO PROGRAM` runs inside a read-only transaction
  for a superuser or a member of `pg_execute_server_program`. So before any check runs, each run reads the login's
  rights, and the collection refuses to run on the instance (a failed collection naming the right, no check run) when
  the login is a superuser, a member of a superuser role (a `NOINHERIT` member too: a check's statement can
  `SET ROLE` to it) or a member of `pg_execute_server_program`, `pg_write_server_files` or `pg_read_server_files`.
  The rights read are the session user's: a login that starts as another role (`ALTER ROLE ... SET role`) is judged as
  itself, since a check can set the role back;
- the check sees what the monitoring login sees: the statistics views in full (`pg_monitor`), the catalogs, and the
  tables the login has been granted. A check that needs more is the server DBA's grant to that login, made by hand.

A check runs in the database the instance's DSN connects to. A check meant for another database is a second
instance entry with that database in its DSN.

## The configuration

```yaml
custom:
  - name: idle_in_transaction          # lower-case letters, digits, '_', '.', '-' (1..63); unique in the list
    description: sessions idle inside an open transaction
    sql: SELECT count(*) AS value FROM pg_stat_activity WHERE state LIKE 'idle in transaction%'
    every: 5m                          # the cadence: 1m to 24h (default 5m)
    instances: [erp01]                 # instance names from instances:, and / or
    tags: [env:prod]                   # tags the instances carry in instances: (key:value or a plain word)
    rule: value                        # value (default) | rows | status (SQL Server: DBA Dash's custom check)
    value: value                       # the value column (default: the column named value, else the first column)
    compare: ">"                       # > (default)  >=  <  <=  =  !=
    warning: 5
    critical: 20
```

- **Where it runs.** A check runs on every instance it names and on every instance that carries one of its tags; a
  check that names neither runs on every instance. A tag folder of the UI tree is a tag: `tags: [env:prod]` runs the
  check on the folder `env: prod`.
- **The rule.** A *value* check reads one number: the value column of the first row (order the statement so the
  first row is the worst). A *rows* check counts the rows the statement returns (`value:` is refused with it). No row,
  or a NULL value, judges nothing: the run is `ok` with the note "no row" or "the value is NULL". A value that is not
  a number (text that does not parse, a date) is the check's error. A *status* check is SQL Server's alone: [DBA
  Dash's custom check](#dba-dashs-custom-check), whose rows judge themselves.
- **The thresholds.** `critical` is tested before `warning`; either may be left out. With `>` or `>=` critical must be
  at or above warning, with `<` or `<=` at or below it. `=` and `!=` take any pair.
- **What is kept.** The status (`ok`, `warning`, `critical`, `error`), the value, the row count, the column names, at
  most 100 rows (each cell masked for passwords and cut at 1000 characters) under `query_text: full`; under
  `normalized` or `none` the rows are not kept (the value and the count are). The runs are kept as long as the other
  samples (`pgvigil purge`).
- **Where it must match.** A check may name an instance or a tag that only Admin > Instances holds, so a name not in
  `instances:`, or `instances:` and `tags:` that together match no instance of the file (a typo such as `env:prd`
  for `env:prod`), is a warning at start, not a refusal; the collector warns again when a check matches none of
  its instances (the file's, and the page's when it holds them).
- **Off and gone.** Without a `custom:` key the collection is off. A check taken off the list, or off an instance, is
  marked gone at that instance's next run (the tab lists it under "Taken off this instance"); to retire every check,
  leave `custom: []` in the file, so the runs go on long enough to mark them gone. While a `custom:` key is present the
  collection visits every instance once a minute, even one no check names (that is how a check taken off it is
  marked gone); a check runs only when its own cadence is due, and never more often than the collection itself
  (`schedules: {custom: 5m}` makes a 1m check a 5m check). A check that is no longer listed anywhere (the collection
  switched off, or disabled on the instance) leaves the repository with the purge's retention; it raises no finding
  once its latest listing is more than two of its cadences old (at least 5 minutes), so a removed `custom:` key clears
  the Findings and the Summary's Custom Checks column within that time, and `custom: []` clears them at the next run.
- **The findings.** `custom_findings`: a check whose latest run is `warning` or `critical` (that severity), a check
  whose latest run failed (warning, with the error), and a check that has not run in two of its cadences while the
  collection still visits the instance (warning: the collection runs less often than the check, or a run of many slow
  checks takes longer than the cadence). Every finding needs the check's latest listing within two of its cadences
  (at least 5 minutes). A collection that stops visiting (switched off, disabled, failing to connect)
  is the daily checks' "collection stale" or "collection failing", not a finding of each check.

`pgvigil collect -once custom` runs every check that applies, due or not (`pgvigil collect -once mssql_custom` the SQL
Server checks).

## SQL Server checks

A check written for SQL Server runs on the SQL Server instances its `instances:` and `tags:` reach (on every SQL Server
instance when it names neither), never on a PostgreSQL one, and a check without `engine:` never runs on SQL Server.
It is the collection `mssql_custom` (every minute, `schedules: mssql_custom`), which visits no SQL Server instance while
the file has no SQL Server check.

```yaml
custom:
  - name: failed_job_outcomes
    engine: sqlserver                  # a SQL Server check (postgres is the default)
    sql: SELECT COUNT(*) AS value FROM dbo.sysjobhistory WHERE run_status = 0 AND step_id = 0
    database: msdb                     # optional: the database the batch runs in (default: the dsn's)
    every: 15m
    warning: 0
  - name: order_backlog
    procedure: Utility.dbo.pgvigil_check_backlog   # DBA Dash's form: [database.][schema.]name, run with no parameter
    rule: rows
    critical: 100
```

- **What runs.** A `sql:` check is a T-SQL batch; a `procedure:` check is the EXEC of the procedure the DBA made on the
  server (DBA Dash's custom collection), 1 to 3 parts of letters, digits, `_`, `$` and `#`, each part quoted by pgvigil;
  exactly one of the two. `database:` is for a `sql:` check (a procedure names its database in its own name).
- **The rights are the fence.** SQL Server has no read-only transaction, and a transaction does not hold the DBA's own
  T-SQL: a `COMMIT` in the text ends it, and a trace it makes outlives the rollback. So before a check runs (when one
  is due) the run reads the read login's rights and refuses the whole collection on the instance, naming each right,
  when the login holds one outside the documented [read login](sqlserver.md#the-login)'s on the server (`VIEW SERVER
  STATE`, `VIEW ANY DEFINITION`, `CONNECT ANY DATABASE`, `ALTER TRACE`, and the rows SQL Server 2022 splits them into),
  may impersonate another login, or holds a grant on a login, an endpoint or an availability group but `CONNECT` and
  `VIEW DEFINITION`; and in EVERY database it can open (a check's T-SQL reaches each of them with `USE` or a
  three-part name), through its user or any role of it, when it holds a database-wide right but `CONNECT`, `SELECT`,
  `REFERENCES`, `SHOWPLAN` and the `VIEW` rights - a database-wide `EXECUTE` too: a `sql:` check could run any
  procedure there, and a `dbo` procedure writes `dbo`'s tables by ownership chaining -, a grant on a schema, an
  object, a column or another principal but `SELECT`, `REFERENCES`, `VIEW DEFINITION`, `VIEW CHANGE TRACKING` and
  `EXECUTE` on one procedure (`INSERT ON SCHEMA::dbo`, `UPDATE` on a table, `EXECUTE ON SCHEMA::dbo`), may impersonate
  another user, or owns a schema that holds an object, or an object. A sysadmin, `CONTROL SERVER`, `ALTER ANY
  CONNECTION`, `bulkadmin` or `db_datawriter` anywhere is refused in those words; a right a later SQL Server adds is
  refused by its name until pgvigil names it. Custom reports take the
  same fence ([customreports.md](customreports.md)); community tools keep their own, which refuses a sysadmin alone,
  because they run named procedures pgvigil knows, some of which need rights outside a read-only list (sp_HumanEvents
  makes event sessions).
- **How a check runs.** Each check on a connection of its own (closed after it, so a `SET`, `CONTEXT_INFO`,
  `SESSION_CONTEXT`, an applock or an `EXECUTE AS` it leaves reaches no other check), as `SET XACT_ABORT ON; BEGIN
  TRANSACTION; EXEC sys.sp_executesql <the check>; ROLLBACK`, under the collector's session settings (`READ
  UNCOMMITTED`, a 2 s lock timeout, the deadlock's victim: a check never waits on the application, and may read rows
  not yet committed), at most 30 s each (and the run 10 minutes at most: at its end the checks run so far are kept and
  the rest run at the next run).
  Its result is its FIRST result set (a later one is counted in the run's note); its value column takes the integer
  types, `real`, `float`, `decimal`, `numeric`, `money` and `bit`; at most 100 rows, 50 columns and 1,000 characters a
  cell are kept, and the rows only under `query_text: full`, as on PostgreSQL. Unlike PostgreSQL, a batch may hold
  more than one statement; the rollback undoes them only while the check stays in its transaction, and the rights
  above are what keeps any of them from writing.
- **A check's error, in words.** A check that ends its own transaction (a `COMMIT` or `ROLLBACK` in it: pgvigil
  compares the transaction's id before and after, so `COMMIT; BEGIN TRAN` is caught too; what it changed before is
  kept, which is why the rights are the fence), one that makes, starts, stops or closes a trace (`ALTER TRACE` is the
  read login's: pgvigil reads `sys.traces` before and after each check - after one that failed or ran out of time too,
  the trace then said with the check's own error - and leaves the trace as it is: stopping it is the DBA's hand), a procedure that does not exist
  (Msg 2812) or that the login may not run (Msg 229: `GRANT EXECUTE` on it to the read login), a write the login may
  not make, a value column that is no number, and a check past its 30 s are each that check's error, shown on its tab
  and raised as a finding.
- **What the fence does not see.** A procedure's own body is the procedure's: a `dbo` procedure reading or writing
  `dbo` tables needs only `EXECUTE` on it (ownership chaining), as in DBA Dash, so review it as the DBA's own code -
  and a `sql:` check may EXEC any procedure the login holds `EXECUTE` on. A grant the login cannot see is not read
  (a login without `VIEW ANY DEFINITION`: Azure SQL Database's contained user; not proven). A write
  through an EXISTING linked server whose login mapping holds rights on the remote server is the remote server's and
  is not undone by the local rollback: pgvigil cannot see the mapping.
- **DBA Dash's custom check.** <a id="dba-dashs-custom-check"></a>A check with `rule: status` reads the columns of DBA
  Dash's `dbo.DBADash_CustomCheck` - `Test`, `Context`, `Status` (1 critical, 2 warning, 3 N/A, 4 OK) and `Info` -
  by name, without case (`Info` may be left out; another column is named in the run's note), so the procedure a DBA
  Dash site already has runs as it is:

  ```yaml
  custom:
    - name: dbadash_custom_check
      procedure: dbo.DBADash_CustomCheck   # in the dsn's database, as DBA Dash runs it (or Utility.dbo.DBADash_CustomCheck)
      rule: status
      every: 1h                            # DBA Dash's schedule
  ```

  It is an entry of the list like any check (never found and run by itself: DBA Dash runs the procedure whenever it
  exists), with no `warning`, `critical`, `compare` or `value` (each refused in words), behind the same fence; a
  `sql:` batch that returns the four columns is a status check too. Each row is judged by its own Status: one
  finding per row at 1 (critical) or 2 (warning), named `custom check <name>: <Test> (<Context>)`, its value the
  status word (`Status 1`, `Status 2`: an alert's key, which a row's changing Info never moves), the row's Info in its
  detail; the run's status is the worst row, its value the rows at warning or critical (the chart), its row count
  the rows. The rows the last run returned are kept as the check's current set (one per Test and Context, at most
  1,000, the worst first - every critical row, then every warning row, then the rest, so a row that raises a finding
  is never cut while an OK row is kept; `Info` only under `query_text: full`, cut at 1,000 characters), replaced by each run and kept by a failed
  one, as DBA Dash keeps its `CustomChecks` table; DBA Dash's per-row history is not kept (the runs are). A Status
  NULL or outside 1 to 4, a `Test` or `Context` NULL or over 128 characters, or one pair twice is the check's error.
  The Summary's Custom Checks column reads, for a SQL Server instance, its custom findings (these rows, a threshold
  crossed, a check failed or late); it says n/a where no check has been listed for the instance within two of its
  cadences (none of the file reaches it), as DBA Dash's N/A, and read failed with the reason where the collection's
  last run failed (a fence refusal, a connection).
- **Not DBA Dash's storage.** DBA Dash puts a collection's rows in a table of the user's (`UserData.<name>`, made by a
  script the user runs in its repository, with its own retention); pgvigil keeps each run's value, row count and at
  most 100 rows in its own store, with the purge, as PostgreSQL's checks.
- **NOT PROVEN** (scripts/proof-custom-mssql.sh runs on SQL Server 2017, 2019 and 2022 in Linux containers): SQL
  Server on Windows, Azure SQL Database (whose rights are read in its one database), Azure SQL Managed Instance and
  Amazon RDS.

## The catalogue of ready-made checks

The catalogue below takes its list of checks from the ACTIONS of
[check_postgres](https://bucardo.org/check_postgres/) (Bucardo, BSD-2-Clause): the names and the ideas only. The SQL
is pgvigil's own, written for a `pg_monitor` login on PostgreSQL 13 and later (lockwait: 14 and later, it reads
`pg_locks.waitstart`); not proven on PostgreSQL 13: `scripts/proof-custom.sh` part G runs all 18 on one sandbox server; no code of check_postgres is copied.
Copy an entry into `custom:`, then set its `instances:` or `tags:` and tune its thresholds; the defaults below are a
starting point.

### archive_ready: WAL segments waiting for the archiver

The `.ready` files in `pg_wal/archive_status`: segments the archiver has not archived yet.
`pg_ls_archive_statusdir()` is granted to `pg_monitor` like `pg_ls_waldir()`, which pgvigil's storage collection
reads (proven on a self-managed server and on Aurora only). Aurora keeps no WAL in `pg_wal` (the cluster volume holds it), so the count there is
expected to stay 0; the backups collection reads the archiver itself (`pg_stat_archiver`). Not yet run on RDS or
Aurora.

```yaml
  - name: archive_ready
    description: WAL segments waiting for the archiver
    sql: SELECT count(*) AS value FROM pg_ls_archive_statusdir() WHERE name LIKE '%.ready'
    every: 5m
    warning: 10
    critical: 50
```

### autovac_freeze: databases near the forced anti-wraparound vacuum

Each database's transaction ID age as a percent of `autovacuum_freeze_max_age`, the highest first: at 100 % autovacuum
starts its anti-wraparound vacuum, which cannot be cancelled.

```yaml
  - name: autovac_freeze
    description: the oldest database's xid age as a percent of autovacuum_freeze_max_age
    sql: >-
      SELECT round(100 * age(datfrozenxid)::numeric / current_setting('autovacuum_freeze_max_age')::numeric, 1) AS value,
             datname, age(datfrozenxid) AS xid_age
        FROM pg_database WHERE datallowconn ORDER BY age(datfrozenxid) DESC
    every: 1h
    warning: 90
    critical: 95
```

### backends: client connections as a percent of max_connections

```yaml
  - name: backends
    description: client backends as a percent of max_connections
    sql: >-
      SELECT round(100 * count(*) / current_setting('max_connections')::numeric, 1) AS value, count(*) AS connections,
             current_setting('max_connections') AS max_connections
        FROM pg_stat_activity WHERE backend_type = 'client backend'
    every: 1m
    warning: 80
    critical: 95
```

### bloat: tables with a large share of dead rows

An estimate from the statistics (dead rows against live rows in `pg_stat_user_tables`, connected database), not a
page count: a `pg_monitor` login cannot read `pg_stats` for tables it has no SELECT on, which a page-based estimate
needs. The tables over 20 % dead with at least 10,000 dead rows, the worst first.

```yaml
  - name: bloat
    description: tables over 20 percent dead rows (at least 10000), the worst first
    sql: >-
      SELECT schemaname, relname, n_live_tup, n_dead_tup,
             round(100 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0)::numeric, 1) AS dead_pct, last_autovacuum
        FROM pg_stat_user_tables
       WHERE n_dead_tup >= 10000 AND n_dead_tup > 0.2 * (n_live_tup + n_dead_tup)
       ORDER BY n_dead_tup DESC LIMIT 50
    rule: rows
    every: 1h
    warning: 0
    critical: 10
```

### checkpoint: seconds since the last checkpoint

On a primary, the age of the last checkpoint; on a standby, of the last restart point. Tune it to
`checkpoint_timeout` (default 5 min). An idle server skips its timed checkpoint when no WAL was written since the
last one, and a standby makes a restart point only from a checkpoint it replays: on an idle primary, or the standby
of one, the age grows past any threshold without anything being wrong. Give this check to busy instances (`tags:`),
or raise its thresholds where a server can sit idle for an hour.

```yaml
  - name: checkpoint
    description: seconds since the last checkpoint (restart point on a standby)
    sql: SELECT round(extract(epoch FROM now() - checkpoint_time)) AS value, checkpoint_time FROM pg_control_checkpoint()
    every: 5m
    warning: 1800
    critical: 3600
```

### cluster_id: the server is not the one it was

The system identifier changes when the data directory is replaced (a restore, a new initdb, a promoted copy).
Replace the number with the instance's own (`SELECT system_identifier FROM pg_control_system()`); the comparison is
made in SQL because the identifier has more digits than a threshold keeps.

```yaml
  - name: cluster_id
    description: the system identifier is not the expected one
    sql: SELECT system_identifier FROM pg_control_system() WHERE system_identifier <> 1234567890123456789
    rule: rows
    every: 1h
    critical: 0
```

### commitratio: commits as a percent of all transactions

Per database since the statistics reset (cumulative), the lowest first. A low ratio is an application that rolls
back much of what it starts. Every custom check run is itself a transaction that is rolled back, in the database the
instance's DSN connects to: with many checks on a quiet database (often `postgres`), pgvigil's own rollbacks pull
that database's ratio down. Read that database's row with care, or leave it out (`AND datname <> 'postgres'`).

```yaml
  - name: commitratio
    description: the lowest commit percent of any database since the statistics reset
    sql: >-
      SELECT round(100 * xact_commit / nullif(xact_commit + xact_rollback, 0)::numeric, 2) AS value, datname,
             xact_commit, xact_rollback, stats_reset
        FROM pg_stat_database WHERE datname IS NOT NULL AND xact_commit + xact_rollback > 1000
       ORDER BY 1 ASC
    compare: "<"
    every: 1h
    warning: 90
    critical: 80
```

### disabled_triggers: triggers switched off

Triggers that are disabled (`ALTER TABLE ... DISABLE TRIGGER`) in the connected database: a load that disabled them
and did not switch them back.

```yaml
  - name: disabled_triggers
    description: user triggers that are disabled
    sql: >-
      SELECT n.nspname AS schema, c.relname AS table, t.tgname AS trigger
        FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE NOT t.tgisinternal AND t.tgenabled = 'D'
       ORDER BY 1, 2, 3
    rule: rows
    every: 1h
    warning: 0
```

### hitratio: the share of reads served from shared buffers

Per database since the statistics reset (cumulative), the lowest first. A read counted here as missed may still
have come from the operating system's cache.

```yaml
  - name: hitratio
    description: the lowest buffer hit percent of any database since the statistics reset
    sql: >-
      SELECT round(100 * blks_hit / nullif(blks_hit + blks_read, 0)::numeric, 2) AS value, datname, blks_hit, blks_read
        FROM pg_stat_database WHERE datname IS NOT NULL AND blks_hit + blks_read > 10000
       ORDER BY 1 ASC
    compare: "<"
    every: 1h
    warning: 95
    critical: 90
```

### locks: sessions waiting on a lock

```yaml
  - name: locks
    description: lock requests waiting
    sql: SELECT count(*) AS value FROM pg_locks WHERE NOT granted
    every: 1m
    warning: 10
    critical: 50
```

### lockwait: the longest lock wait

The wait of the request that has waited longest, in seconds (`pg_locks.waitstart`, PostgreSQL 14 and later). The
Running queries tab shows the chain and its head.

```yaml
  - name: lockwait
    description: seconds the longest waiting lock request has waited
    sql: >-
      SELECT round(extract(epoch FROM now() - l.waitstart)) AS value, l.pid, a.usename, a.datname, l.locktype, l.mode
        FROM pg_locks l LEFT JOIN pg_stat_activity a ON a.pid = l.pid
       WHERE NOT l.granted AND l.waitstart IS NOT NULL ORDER BY l.waitstart LIMIT 20
    every: 1m
    warning: 60
    critical: 300
```

### prepared_txns: prepared transactions left open

A prepared transaction holds its locks and its xmin until it is committed or rolled back; one left behind by a
failed transaction manager blocks vacuum in every database. The value is the oldest one's age in seconds.

```yaml
  - name: prepared_txns
    description: seconds the oldest prepared transaction has been open
    sql: >-
      SELECT round(extract(epoch FROM now() - prepared)) AS value, gid, owner, database, prepared
        FROM pg_prepared_xacts ORDER BY prepared
    every: 5m
    warning: 60
    critical: 300
```

### query_time: the longest running statement

```yaml
  - name: query_time
    description: seconds the longest active statement has run
    sql: >-
      SELECT round(extract(epoch FROM now() - query_start)) AS value, pid, usename, datname, application_name
        FROM pg_stat_activity
       WHERE state = 'active' AND backend_type = 'client backend' AND pid <> pg_backend_pid()
       ORDER BY query_start LIMIT 20
    every: 1m
    warning: 300
    critical: 1800
```

### sequence: sequences near their end

The used share of each sequence, the fullest first. **A grant is needed:** `pg_sequences.last_value` is NULL for a
sequence the login cannot read, and `pg_monitor` reads none; the server DBA grants `pg_read_all_data` (PostgreSQL
14+) or SELECT on the sequences to the monitoring login. Without it the check returns no row and judges nothing.

```yaml
  - name: sequence
    description: the fullest sequence as a percent of its range
    sql: >-
      SELECT round(100 * CASE WHEN increment_by > 0 THEN (last_value::numeric - min_value) / nullif(max_value::numeric - min_value, 0)
                              ELSE (max_value::numeric - last_value) / nullif(max_value::numeric - min_value, 0) END, 2) AS value,
             schemaname, sequencename, data_type, last_value, max_value
        FROM pg_sequences WHERE last_value IS NOT NULL AND NOT cycle
       ORDER BY 1 DESC LIMIT 20
    every: 1h
    warning: 75
    critical: 90
```

### txn_idle: the longest idle-in-transaction session

A session idle inside an open transaction holds its locks and pins the xmin horizon. Its last statement is the
Running queries tab's lead.

```yaml
  - name: txn_idle
    description: seconds the longest idle-in-transaction session has been idle
    sql: >-
      SELECT round(extract(epoch FROM now() - state_change)) AS value, pid, usename, datname, application_name
        FROM pg_stat_activity WHERE state LIKE 'idle in transaction%' ORDER BY state_change LIMIT 20
    every: 1m
    warning: 60
    critical: 600
```

### txn_time: the longest open transaction

```yaml
  - name: txn_time
    description: seconds the oldest open transaction has been open
    sql: >-
      SELECT round(extract(epoch FROM now() - xact_start)) AS value, pid, usename, datname, state, application_name
        FROM pg_stat_activity
       WHERE xact_start IS NOT NULL AND backend_type = 'client backend' AND pid <> pg_backend_pid()
       ORDER BY xact_start LIMIT 20
    every: 1m
    warning: 600
    critical: 3600
```

### txn_wraparound: transaction IDs left before wraparound

The oldest database's xid age; PostgreSQL stops assigning transaction IDs at about 2.1 billion (2^31 less a margin).

```yaml
  - name: txn_wraparound
    description: the oldest database's transaction ID age
    sql: SELECT age(datfrozenxid) AS value, datname FROM pg_database ORDER BY age(datfrozenxid) DESC
    every: 1h
    warning: 1300000000
    critical: 1400000000
```

### wal_files: pg_wal against max_wal_size

The size of `pg_wal` as a percent of `max_wal_size`: a slot, a failing archiver or a long checkpoint keeps WAL past
it. It reads `pg_ls_waldir()` as the storage collection does, as `pg_monitor` (proven on a self-managed server and on Aurora only); Aurora keeps no WAL
in `pg_wal` (its count is 0 there), so on Aurora the check has no value (no file to sum: "the value is NULL") and never fires (not run there); the Storage tab and the
replication slots are the read there.

```yaml
  - name: wal_files
    description: pg_wal as a percent of max_wal_size
    sql: >-
      SELECT round(100 * sum(size) / pg_size_bytes(current_setting('max_wal_size'))::numeric) AS value,
             count(*) AS files, pg_size_pretty(sum(size)) AS size FROM pg_ls_waldir()
    every: 5m
    warning: 150
    critical: 300
```

### The rest of the action list

| check_postgres action | In pgvigil |
| --- | --- |
| connection | every collection connects; a failing one is the daily check "collection failing" |
| database_size, relation_size, table_size, index_size, indexes_size, total_relation_size | the databases and tables collections (Growth, Tables, Database info) |
| dbstats | the dbstats collection (Metrics) |
| disk_space | the host collection (Host, Disk report) |
| hot_standby_delay | the replication collection (Replication) |
| last_vacuum, last_autovacuum, last_analyze, last_autoanalyze | the vacuum collection (Vacuum) |
| logfile | the log readers (Logs) |
| new_version_* | the versions collection, against the release table built into pgvigil: nothing is fetched from outside |
| pgb_pool_*, pgbouncer_* | the Pooler tab (a `pgbouncer:` DSN per instance) |
| replicate_row | not catalogued: it writes a row, and a check is read only |
| same_schema | the Schema tab (schema snapshots) |
| settings_checksum | the instance collection keeps the non-default settings |
| slony_status | not catalogued: Slony is out of scope |
| timesync | not catalogued: a check runs on the server and has no second clock to compare with |
| version | the instance collection (the server version on every page) |
| fsm_pages, fsm_relations | not catalogued: the free space map is automatic since PostgreSQL 8.4 (max_fsm_pages is gone) |
| custom_query | this page |
