# Parquet export

`pgvigil export` writes the repository to Parquet files, one set and one manifest per clock hour, into a folder, an
S3 bucket (or an S3-compatible store) or an Azure Blob container, for a consumer outside pgvigil: a lake, a
warehouse, a notebook. It only reads the repository. It is **off** until the configuration has an `export:`
section, and nothing in `pgvigil run` or `pgvigil serve` starts it: your scheduler does, as it starts `purge`.

This page is also the **file contract** (contract version 1): what a consumer may rely on.

## Turning it on

1. The export's login, on the repository, as its owner (`pgvigil roles` prints the line):

   ```sql
   CREATE ROLE pgvigil_export LOGIN PASSWORD '...' IN ROLE pgvigil_exporter;
   ```

   `pgvigil_exporter` is `pgvigil_reader` plus one door that records each window for the Collector page. A login
   `IN ROLE pgvigil_reader` alone exports just the same and leaves no row there. A login that could write is
   **refused** before anything is read (exit 3, the line says why): a superuser, a login that bypasses row
   security, a member of any other role (the collector's, the alerter's, the owner's - inherited or not), a login
   with an INSERT, UPDATE, DELETE or TRUNCATE privilege on any table of the schema.

2. The section (see [configuration.md](configuration.md) for every key):

   ```yaml
   export:
     name: prod-repo                    # the folder under the destination and part of every file name
     dsn: env:PGVIGIL_EXPORT_DSN        # the login above, named by env:NAME or file:/path, never written in this file
     state_dir: /var/lib/pgvigil/export # the lock and the files being built; nothing kept
     destination: { type: folder, path: /srv/pgvigil-export }
   ```

3. `pgvigil export -config pgvigil.yaml -check` proves it: the login, the map of tables against your repository,
   and the destination by one tiny object written and removed. Then `-plan` shows the windows a run would take.

4. Schedule `pgvigil export -config pgvigil.yaml` hourly: `deploy/pgvigil-export.service` and
   `deploy/pgvigil-export.timer` (minute 35, away from the purge), a cron line, or a Windows scheduled task.
   Two runs never overlap: the second says it is locked and exits 0. The unit may write only its state folder
   (`/var/lib/pgvigil/export`): a folder destination needs a drop-in
   (`systemctl edit pgvigil-export.service`, `[Service]` `ReadWritePaths=/srv/pgvigil-export`), and the unit's
   `UMask=0077` makes the files readable by its own account only - give a loader that runs as another account a
   group in the drop-in (`UMask=0027`, `Group=`), or read the folder as `pgvigil`.

To turn it off: stop the timer, run `pgvigil export -off` (it removes the export's rows from the repository, so
nothing calls it late), then remove the `export:` section. `-off` before the timer stops is undone by the next run.

## What a run does

A **window** is one clock hour `[from, to)`, UTC, on the **repository's** clock. A run lists the destination's
manifests - they are its only memory - and exports every window that is due, oldest first, at most
`max_windows_per_run` (12); it says how many more are due.

- **Pass 1**: a window is first exported `settle_minutes` (20) after it ends, with what the repository holds then.
- **The final pass**: once the window is `final_after_hours` (24) old it is exported again under the same names,
  with what was stored since under a time inside it - a job run that ended later, a Query Store interval read an
  hour late, an hour row rebuilt. The manifest says `"pass": "final"`, and a marker
  `_manifests/_final/<name>__<from>__<to>` follows it. Replace a window's rows table by table: when a newer
  manifest for the window arrives, each table it lists replaces that table's rows of the window. A table the
  final pass gave up is in its `failed` and keeps its earlier entry and files (its entry's `note` says so).
  A window that has its first pass gets its final pass at any age: an export that was down for days catches up on
  them when it next runs.
- A row stored more than `final_after_hours` after its own time is in neither pass. Re-export those hours by hand:
  `pgvigil export -from 2026-01-31T14:00:00Z -to 2026-01-31T16:00:00Z`. Nothing here claims that no late row is
  ever missed.
- A run reaches back `max_window_age_hours` (48). An hour between the export's first window and that reach with no
  manifest has **aged out**: every run names it with the `-from / -to` line that fills it and exits 1, and
  `-status` lists it. `pgvigil export -gap <from> <to>` accepts the hole: it writes a manifest with `"gap": true`
  and no table for each such hour, and its final marker (no later pass fills it; `-from / -to` does, by hand). A new export on an old repository starts `max_window_age_hours` back and names
  nothing before its first window.
- One table cannot stop the export. A table whose read or upload fails leaves its window without a manifest (exit 1) and is
  tried again by the next run; on the third failed run the window completes without it and the manifest's
  `failed` list names it with the error.

Exit: 0 every window this run took has its manifest; 1 a window is left without one, a table was given up, or an
hour aged out; 2 usage; 3 the configuration or the login is refused.

## The files

```
<prefix>/<name>/<table>/<table>__<name>__<from>__<to>.parquet          from, to as 20260131T1400Z
<prefix>/<name>/<table>/<table>__<name>__<from>__<to>__p2.parquet      a second file of the same table and window
<prefix>/<name>/_manifests/<name>__<from>__<to>.json
<prefix>/<name>/_manifests/_final/<name>__<from>__<to>
```

- **Data first, manifest last.** A manifest means every file it lists is whole. A file no manifest lists belongs
  to an unfinished run: ignore it. A window done again removes its manifest first, writes its files, then writes
  the manifest; the files an older pass wrote and this one did not are removed.
- A table with no row in the window has an entry with `row_count` 0 and no file.
- A file holds at most 1,000,000 rows and is closed at 256 MB; its row groups hold at most 50,000 rows or 64 MB of
  values. Pages are ZSTD. Every column is OPTIONAL and the columns are in the table's own order. A text, bytes or
  JSON column has no statistics in its page headers (a page's largest value would sit there whole, and a reader
  refuses a header of many megabytes); its row group's minimum and maximum are in the footer, whole.
- A subset run (`-tables a,b` with `-from / -to`) writes a manifest and files marked `__t<8 hex>`, and its
  manifest says `"subset": true`: it stands for the tables it lists only, and never replaces a full window's.
- Two machines exporting one repository to one destination are not supported (the lock is per machine); a manifest
  is written only where none is, so the second writer fails instead of replacing the first's.

### The manifest

`contract_version` (1, the first key), `repository`, `window` (`from_utc`, `to_utc`), `pass` (1 or `"final"`),
`gap` and `subset` (present only when true), `pgvigil_version`, `schema_migrations`, `started_at`, `finished_at`,
and (`time_column` and `note` present only when set):

- `tables[]`: `table`, `kind`, `time_column`, `key_columns`, `output_files[]` (`path` under `<prefix>/<name>/`,
  `row_count`, `byte_size`, `sha256`), `row_count`, `byte_size`, `columns[]` (`name`, `pg_type`, `parquet_type`,
  `note`), `read_ms`, `note`.
- `skipped[]`: a table not exported under this configuration, and why.
- `failed[]`: a table given up after three failed runs, and its error.
- `dropped_columns[]`: a column left behind, and why.
- `filtered_rows[]`: rows of a table left behind (`table`, `rows` - the predicate, `reason`).

Every time in a manifest is the repository's clock.

Hold every file to its `sha256`: it is the export's end-to-end check, whatever the store.

## What it carries

Every table is classed by how pgvigil **writes** it, in a map in the code (`pgvigil export -tables-list` prints
it for your repository). A table the map does not name stops every run before anything is read: a new table is
never exported by a guess.

| kind | what a window holds | identity |
|---|---|---|
| `window` | the rows whose own time column (`time_column`) is inside the hour: every partitioned table by its partition key, and the plain tables that are keyed by or logged under a time | `key_columns` where the table has a primary key: keep one row per key within a window (an hour row can be rebuilt) |
| `state` | the whole table, in the **day's first window** (00:00 UTC) only: what an import upserts or rebuilds at every read (the current state of hosts, databases, jobs, settings, thresholds). `instances` is in every window | `key_columns`; the newest window's copy replaces the older |
| `dimension` | text keyed by a hash: the rows seen in or after the window's start, and the whole table in the day's first window | `key_columns` |

- No column is added to a row. Two repositories are joined on (repository name, instance name), never on
  `instance_id`: `instances` gives the names.
- **Text is off unless you carry it.** Statement, plan and log text can hold literals. Without
  `carry: [text]` the tables that are text (statement and plan texts) are skipped, and the text columns of every
  other table are dropped and named in `dropped_columns`, the rest of the table carried: a blocked statement, a
  deadlock graph, a job's command and its output, a log or error-log line's message, an audited statement and its
  parameters, an index's or an object's definition and a filter's predicate, the SQL a check proposes, and the
  error text of a failed collection (a driver's words can quote a value, a host or a login).
- **Audit is off unless you carry it.** Without `carry: [audit]`:
  - these tables are skipped: pgvigil's own action logs (who acknowledged, ran, changed what), the servers'
    audit trails and their counts, SQL Server's failed logins, and the posture tables (logins and roles, role
    members, grants, hba rules);
  - these columns are dropped and named in `dropped_columns`: who made, changed or ended one of pgvigil's own
    rules, thresholds, acknowledgements, reports and schedules and from which address (`created_by`, `client`,
    `ended_by` and the like), an object's grants (`schema_objects.acl`), and who ran a DDL statement
    (`schema_ddl_log.role_name`);
  - PostgreSQL's failed sign-ins (`log_events` of kind `auth_fail`) are left behind, and the manifest's
    `filtered_rows` says so.
  A table that leaves only with the audit carry still leaves without its text unless `text` is carried too.
- Never exported: the web UI's logins; the collector's cursors, counter baselines and duplicate guards; the
  service's queues and marks; its inventory of connection references, hosts and logins. And these columns of
  tables that are carried: a mail's recipients, subject, body and attachment, a mail server's reply (it can quote
  the address it refused), an alert channel's address, a claim token, a Patroni URL.
- Every text, JSON and bytes column of every exported table is classed by name: one a later version adds is not
  exported by a guess (pgvigil's own proof fails until it is read and classed).
- A window table's row whose time is not set yet (a job run that never started) belongs to no hour: it is in the
  day's first window, every day, until it has its time.
- A `state` table over `snapshot_max_bytes` (256MB; its size on disk with its indexes) is left out and named in
  `skipped`; `instances` never is. A `dimension` table over it loses only its whole copy in the day's first
  window - the rows seen since each window's start are still carried - and its entry's `note` says so.
- Views are not exported: the findings are derived, not stored.
- What leaves the repository cannot be called back: that is why both carries are off by default.

## Types

| PostgreSQL | Parquet |
|---|---|
| boolean | BOOLEAN |
| smallint, integer | INT32 |
| bigint | INT64 |
| real / double precision | FLOAT / DOUBLE |
| numeric(p, s), p up to 18 | DECIMAL(p, s) |
| numeric(p, s), p over 18 | STRING holding the exact digits (`exact digits as text`) |
| numeric with no precision | DOUBLE - except the identity and sequence figures that reach past the bigint line, which are STRING holding their exact digits (`exact digits as text`; a 16-byte DECIMAL's statistics cannot be written right for a negative figure) |
| timestamp with time zone | TIMESTAMP(MICROS, adjusted to UTC) |
| timestamp without time zone | TIMESTAMP(MICROS, not adjusted) |
| date | DATE |
| text, varchar, name, uuid, inet, pg_lsn | STRING |
| bytea | BYTE_ARRAY |
| json, jsonb | STRING with the JSON annotation |
| an array of booleans, integers, floats or strings | LIST of it, its elements OPTIONAL |
| any other array | STRING holding its JSON text (`as JSON text`) |
| anything else | STRING holding PostgreSQL's text form; the manifest's column says `as text` |

A timestamp of infinity, and a NaN in a DECIMAL column, are written as null and the manifest's column says
`infinite as null`. Units are as stored (bytes, milliseconds, the column's own name says which). A column missing
from an older file is null. The repository's encoding must be UTF8.

## Destinations and their rights

- `folder`: `path`. Each object is written beside its place and renamed; a manifest goes in by a hard link (so
  that a second writer is refused), so the file system must have hard links - not a share or a mount without
  them (CIFS without the unix extensions, blobfuse, s3fs). `-check` tries it.
- `s3`: `bucket`, `prefix`, `region`, and for an S3-compatible store its `endpoint`; `profile` to name one.
  Credentials come from the AWS default chain, never from this file. Rights on the prefix: `s3:PutObject`,
  `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, and `s3:ListBucket` on the bucket. A file over
  64 MB goes up in parts. pgvigil sends no checksum trailer of its own (S3-compatible stores differ on them).
- `azure_blob`: `container`, `prefix`, and one way in: `connection_string: env:NAME`, `sas_url: env:NAME` (the
  account's URL with its SAS), or `account_url` with the default credential (a managed identity, the environment,
  the Azure CLI's login). Rights: read, write, delete and list on the container (Storage Blob Data Contributor;
  with a user-delegation SAS the identity that signed it needs that data role too). The Azure SDK writes a file
  of 256 MiB or less in one request and a larger one in 16 MB blocks.

## The reading session

Every reading session of the export is `pgvigil-export` in `pg_stat_activity`, read only from its first statement
(`default_transaction_read_only`) - the one other session, the door's, runs only the record of a window, for 30
seconds at most - with `statement_timeout` (120 s, `export.statement_timeout`), `lock_timeout`
5 s, `work_mem` 16MB and no parallel workers. Each table of a window is read in one
`REPEATABLE READ READ ONLY` transaction that has ended before anything is uploaded, by one statement that starts
with `/* pgvigil-export:<table> */`. A window table is read one instance at a time through its
(instance_id, time) index, for every row of `instances`, active or not (a removed instance's history stays, and
is exported). JIT is off in the session: on a read this small the compilation costs more than the read. Behind
PgBouncer these startup settings must be in `track_extra_parameters` (`plan_cache_mode`, `jit`, `TimeZone`
among them).

## Seeing it

- `pgvigil export -status [-json]`: the newest window, the hours without a manifest or without their final pass,
  the hours aged out.
- With the exporter's login, the Collector page shows a **Parquet export** panel: the last windows, their
  outcome and sizes, and a line when the last run failed or the export is more than 3 hours behind.
  `pgvigil export -off` removes the export's row from the repository when you turn it off, so that nothing calls
  it late.

## Not proven by the proof

`scripts/proof-parquet.sh` reads every file back with an independent reader and writes to an S3-compatible server
and to Azurite in containers. Beyond it, the export was run by hand against real AWS S3 and real Azure Blob
(`-check`, one window read back file by file with its sha256, size and rows, the store's own refusal of a second
manifest, a re-export; on S3 an 80 MB file in a multipart upload; on Blob through `sas_url` with a user-delegation
SAS) and under its own systemd units on a systemd host (as shipped the unit cannot write a folder destination;
with the drop-in of step 4 it exports as the account `pgvigil`, and its timer and its lock hold). None of it
proves:

- a file over 256 MiB, which the Azure SDK uploads in blocks, on real Azure Blob or on Azurite (every file the
  runs wrote was under 256 MiB, so each went up in one request); a file is closed at the first row group past
  256 MiB, so one can be larger by up to a row group;
- the AWS `profile`, the Azure default credential;
- the 256 MB line that closes a file at its real size (a unit test crosses it with small files; the 64 MB line of
  a row group and the 1,000,000-row line are crossed for real);
- the refusal of a repository whose encoding is not UTF8;
- a session through PgBouncer;
- the build with FIPS 140-3 on, and the Windows file lock;
- the Collector page's panel drawn in a browser (the proof reads what it draws from, `GET /api/export`);
- the door refusing a write that is not the export's own beyond the cases the proof seeds; the `account_url` way
  into Blob; a table given up after upload failures; the 90-day trim of `export_runs`.

The layout, the manifest and the rules above follow the file contract of PerformanceMonitor's exporter closely
(MIT; see THIRD-PARTY-NOTICES.md).
