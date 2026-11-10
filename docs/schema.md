# Schema snapshots

The **schema** collection keeps a snapshot of every database's own schema and records what changed between two
reads. This is what DBADash calls DDL change tracking. Each hour, on every database the monitoring login can connect
to, it reads one row per object:

| Object                      | Its definition, as stored                                                              |
|-----------------------------|----------------------------------------------------------------------------------------|
| schema                      | `schema`, with its owner and ACL                                                       |
| table                       | `table`, `unlogged table`, `foreign table` or `partitioned table by ...`; the partition bound, storage options, tablespace and row level security |
| column (each its own row)   | the type, collation, `not null`, the default, identity, or generated expression (stored or virtual); its column ACL |
| index                       | `pg_get_indexdef`, marked `(INVALID)` when invalid                                     |
| constraint                  | `pg_get_constraintdef`, marked `NOT VALID` when not validated                          |
| trigger                     | `pg_get_triggerdef`, marked when disabled, replica or always                           |
| function, procedure         | the kind, its arguments with their names and defaults, result, language, volatility, strictness, `security definer`, leakproof, parallel safety, cost and rows, its `SET` settings, and `body sha256:<16 hex>` of its source |
| view, materialized view     | `pg_get_viewdef`                                                                       |
| sequence                    | the type, start, increment, min, max, cache, cycle, and the column that owns it (an owned sequence belongs to that table) |

Each object also keeps its owner and its ACL as text (empty means the built-in default). A column, index, constraint
or trigger takes its owner from its table, so its own owner is left empty. An object is known by
`pg_identify_object()`'s identity (`public.orders`, `public.orders.amount`, `orders_pkey on public.orders`,
`public.f(integer)`), which is the same text an event trigger reports. A hash of the kind, definition, owner and ACL
tells whether the object changed; a second hash of the definition alone catches a change past the cut below even
when the owner or ACL changed in the same hour.

These are left out: the catalog schemas (`pg_catalog`, `information_schema`, `pg_toast*`, `pg_temp*`), temporary
relations, every object that belongs to an extension (that DDL is the extension's, and its version is on the
Extensions tab), aggregates, and PostgreSQL 18's NOT NULL constraints (the column's own definition already says
`not null`). A function's body is hashed by pgvigil itself (SHA-256, Go's crypto), so the read works on a server
where FIPS mode disables `md5()`. A definition longer than 20,000 characters is stored cut, but its hash is taken
over the whole text, so a change after the cut still shows.

**Rights:** pg_monitor, nothing more. The catalogs and the `pg_get_*def` functions are readable by every role.

**Size:** the collector hands the repository one database at a time (its event-trigger rows, then its objects), and a
last call that marks a database neither read nor in error as gone; PostgreSQL refuses a jsonb array over 256 MB, so
one payload for the whole instance would fail near 800,000 objects. A database whose objects come to more than about
160 MB of text (for example 8,000 views of 20,000 characters) is reported as a collector error and keeps its snapshot.

**Versions:** on PostgreSQL 13 and 14 the trigger a partition inherits from its partitioned table is internal and is
not read; from 15 on it is its own object. So the same schema gives fewer trigger rows on 13 and 14, and after a
`pg_upgrade` from 14 to 15 or later that keeps the database OIDs, the next read shows every partition's inherited
trigger as added. Only PostgreSQL 18 ran the proof.

## What a change is

A database's first read is its baseline: its objects are stored and no change is recorded. The same holds for the
first read after a database comes back to the list (it was dropped and created again, or the login lost its CONNECT
right and got it back). Every later read is
compared with the stored snapshot:

- **added**: an object not in the snapshot (`after` holds its definition);
- **dropped**: an object in the snapshot and not in this read (`before` holds the definition it had); the row stays
  in `schema_objects` with `is_present = false`;
- **changed**: one row per attribute that differs (`definition`, `owner` or `acl`), with the text `before` and
  `after`.

A table created or dropped between two reads gives one row, the table's own. Its columns, indexes, constraints,
triggers and owned sequences come and go with it and are not listed separately; so do a view's triggers and a
materialized view's indexes. A view dropped and created again under the same name is
**changed**, not dropped and added. A rename is a drop and an add. A database that could not be read (an error, or
over 50,000 objects) keeps its snapshot as it was, and the run is marked `partial` with the reason; its event-trigger
rows are still read. Each read takes the database row and the objects in one repeatable-read, read-only transaction,
so the read time recorded is the moment the snapshot stands for. A database that
is gone has its row marked not present, and its objects are not counted as dropped.

An object created and dropped between two hourly reads is not seen by the diff. The event trigger below logs it.

## The exact statement: the opt-in event trigger

The hourly diff shows *what* changed. The statement that made the change, and the role that ran it, can only be
captured inside the database by an event trigger, and only a superuser can create one. pgvigil does not install it.
`pgvigil roles` prints the block, commented out, with the monitoring login filled in, and the server's DBA runs it in
each database that should be covered:

- the guard: the block runs as one transaction, and the `DO` block after its `BEGIN` stops it in a database with a
  `FOR ALL TABLES` publication (or, on PostgreSQL 15 and later, a publication of the schema `public`). The new table
  would join that publication, and every subscriber without the table would stop applying changes with "logical
  replication target relation "public.pgvigil_ddl_log" does not exist". Create the table on every subscriber first
  and uncomment the block's `set_config('pgvigil.publication_ok', 'on', true)` line, or leave that database out. A FOR ALL TABLES publication
  created after the install takes the table too;
- the table `public.pgvigil_ddl_log` (log id, time, event, command tag, object type, schema, object identity, role,
  and the client's query text: every statement sent together in one query, cut at 10,000 characters, so a batch's
  rows all carry the whole batch). Its owner may read it, plus the monitoring login (`GRANT SELECT`);
  PUBLIC gets nothing;
- the function `public.pgvigil_ddl_capture()`: `SECURITY DEFINER`, with a fixed `search_path`. Any error inside it
  becomes a WARNING, so the capture never fails the DDL it records (a DROP of the log table itself still works), and
  its `lock_timeout` of one second bounds the wait for its own table: a DDL statement behind a lock on the log waits
  at most a second, then runs and is not logged.
  A statement that may carry a password is not kept: the rows of `CREATE` and `ALTER` of a `SERVER`, `USER MAPPING`
  or `SUBSCRIPTION`, and every row whose query text names `password`, `secret` or `pwd`, holds a URL with a password
  (`postgresql://user:pw@host`) or holds such a `CREATE` or `ALTER` (the other statements of a batch carry the same
  text), are stored as `(statement not kept: it may carry a password)`. The rule errs wide: `ADD COLUMN
  password_hash` loses its text too. The match reads the kept 10,000 characters only, so a batch of thousands of
  statements costs no more per command than a short one. pg_monitor cannot read a user mapping's options or a
  subscription's connection string, and the log must not hand them over;
  Temporary objects and the commands an extension's script runs are not logged: the snapshot leaves both out, and an
  application that creates a temp table per request would otherwise fill the table;
- the event triggers `pgvigil_ddl_end` (`ddl_command_end`) and `pgvigil_ddl_drop` (`sql_drop`);
- the undo (`DROP EVENT TRIGGER`, `DROP FUNCTION`, `DROP TABLE`), and a `DELETE` line to keep the table small. The
  table grows with every DDL statement and pgvigil never deletes from it. Purge it with DELETE only: a TRUNCATE,
  VACUUM FULL or ALTER of the table locks it, and every DDL statement in the database waits up to a second behind
  that lock and then goes unlogged.

The collector reads the log rows newer than its cursor (`schema_ddl:<database>` in `log_cursor`), with one hour of
overlap so that a transaction committed late is not missed. It reads in pages of 5,000 by (logged time, log id), up to
50,000 rows per database per run; a run that reaches that cap moves the cursor to its last row, so the next run goes
on from there. On a database's first read it takes the last day. The repository keeps each row once
(`schema_ddl_log`).

The Schema tab places a statement beside the change it made. A statement belongs to a change when it was logged in
the same database, between the read before the change and the read that found it (both times on the monitored
server's own clock, so there is no skew between machines), and when its object identity is the changed object's or
its table's (an exact match first). A `GRANT` or `REVOKE` is logged without an identity, so it is matched to an ACL
change by the object's name as a whole word in its text; the schema is not checked, so a GRANT on a same-named object
of another schema in the same interval can be shown. A statement logged up to a minute before that interval is used only when nothing
inside it matches. If several statements match, the newest is shown.

Each database's row on the tab gives the trigger's state:

| State                       | Meaning                                                                 |
|-----------------------------|-------------------------------------------------------------------------|
| installed                   | the table and both enabled event triggers are there; statements are shown |
| not installed               | no `pgvigil_ddl_log` table: changes are found, with no statement        |
| table present, event triggers missing or disabled | the table is read, but nothing new will be logged |
| not readable                | the monitoring login lacks `SELECT` on the table                        |

Event triggers do not fire for shared objects (roles, databases, tablespaces) or for the event triggers themselves.
The statement text follows the instance's `query_text` policy, like every other statement pgvigil keeps:
`normalized` replaces the literals, and `none` keeps no text, in which case the tab says no statement was captured.
The object definitions are schema, not data: a column default, a view's text or a check constraint is kept whole
under every policy.

## The UI

- **Schema** (instance tab): tiles for the databases, objects, changes and drops in the range (a dropped partition
  is not counted as a drop, as in the findings), and in how many
  databases the trigger is installed; the instance's schema findings; the databases (objects, changes and drops in
  the range, the trigger's state, the read the comparison starts from); the changes of the range, with a picker for
  the kind of change and a filter on the object's name; the trigger's own log for the range (which includes what the
  hourly diff cannot see; the database page's section says so too when it holds the newest 1,000); and the objects of one database at a time, with a kind picker and a name filter (the
  first 5,000 by schema, kind and name are read, and 500 are shown). The tiles count every change of the range; the
  list holds the newest 2,000 and the trigger's log the newest 1,000, each saying so when full. A long definition,
  before, after or statement opens in place (a disclosure the keyboard reaches).
- **The database page** has a Schema section with the same content for that one database.
- `GET /api/schema?instance=<id>&from=&to=[&db=<dbid>]` serves both (`state`, `databases`, `changes`, `ddl`,
  `findings`, and with `db` also `objects`, each row carrying the database's `total`); `part=<name>` returns one part.

## Findings

`schema_findings` gives one row per database for each of two findings, over the last 24 hours:

- **schema: an object dropped** (warning): how many objects were dropped, and the newest drop;
- **schema: a definition changed** (info): how many objects were added and how many changed, and the newest change.
  A dropped partition (a retention job's routine) is counted here, not in the warning.

## The repository (migration 0058)

| Table / function                                  | Holds                                                                           |
|---------------------------------------------------|---------------------------------------------------------------------------------|
| `schema_databases`                                | per database read: object count, the trigger's state and table, `read_at` (the server's clock), `first_read`, `is_present` |
| `schema_objects`                                  | the current snapshot, one row per object; `first_seen`, `last_changed`, `is_present` |
| `schema_changes` (monthly partitions)             | the diff history: change, attribute, before, after, and both reads' times        |
| `schema_ddl_log` (monthly partitions)             | the event trigger's rows, by the time they were logged                           |
| `import_schema(i, at, payload)`                   | the collector's import: the diff, the snapshot, the log rows, the cursor         |
| `schema_changes_window(i, from, to, dbid)`        | the changes of a window (2,000 newest), each with its matched statement          |
| `schema_findings`                                 | the two findings above                                                           |

A late import (a one-off `collect` that finishes after the daemon's newer read) changes nothing.
