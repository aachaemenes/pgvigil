# Custom checks

pgvigil runs the DBA's own SQL as checks, the way DBADash runs custom collections: each check is a statement in the
configuration's `custom:` list, run by the collector on the instances or tag folders it names, at its own cadence,
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
  the login is a superuser or a member of `pg_execute_server_program`, `pg_write_server_files` or
  `pg_read_server_files`;
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
    rule: value                        # value (default) | rows
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
  a number (text that does not parse, a date) is the check's error.
- **The thresholds.** `critical` is tested before `warning`; either may be left out. With `>` or `>=` critical must be
  at or above warning, with `<` or `<=` at or below it. `=` and `!=` take any pair.
- **What is kept.** The status (`ok`, `warning`, `critical`, `error`), the value, the row count, the column names, at
  most 100 rows (each cell masked for passwords and cut at 1000 characters) under `query_text: full`; under
  `normalized` or `none` the rows are not kept (the value and the count are). The runs are kept as long as the other
  samples (`pgvigil purge`).
- **Where it must match.** A check whose `instances:` and `tags:` together match no instance in `instances:` (a typo
  such as `env:prd` for `env:prod`) refuses the configuration, as an unknown instance name does.
- **Off and gone.** Without a `custom:` key the collection is off. A check taken off the list, or off an instance, is
  marked gone at that instance's next run (the tab lists it under "Taken off this instance"); to retire every check,
  leave `custom: []` in the file, so the runs go on long enough to mark them gone. While a `custom:` key is present the
  collection visits every instance once a minute, even one no check names (that is how a check taken off it is
  marked gone); a check runs only when its own cadence is due, and never more often than the collection itself
  (`schedules: {custom: 5m}` makes a 1m check a 5m check). A check that is no longer listed anywhere (the collection
  switched off, or disabled on the instance) leaves the repository with the purge's retention; it raises no finding
  once its latest listing is more than two of its cadences old (at least 5 minutes), so a removed `custom:` key clears
  the Findings and the Summary's Custom column within that time, and `custom: []` clears them at the next run.
- **The findings.** `custom_findings`: a check whose latest run is `warning` or `critical` (that severity), a check
  whose latest run failed (warning, with the error), and a check that has not run in two of its cadences while the
  collection still visits the instance (warning: the collection runs less often than the check, or a run of many slow
  checks takes longer than the cadence). Every finding needs the check's latest listing within two of its cadences
  (at least 5 minutes). A collection that stops visiting (switched off, disabled, failing to connect)
  is the daily checks' "collection stale" or "collection failing", not a finding of each check.

`pgvigil collect -once custom` runs every check that applies, due or not.

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
