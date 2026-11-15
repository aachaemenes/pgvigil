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
   Two runs never overlap: the second says it is locked and exits 0.

## What a run does

A **window** is one clock hour `[from, to)`, UTC, on the **repository's** clock. A run lists the destination's
manifests - they are its only memory - and exports every window that is due, oldest first, at most
`max_windows_per_run` (12); it says how many more are due.

- **Pass 1**: a window is first exported `settle_minutes` (20) after it ends, with what the repository holds then.
- **The final pass**: once the window is `final_after_hours` (24) old it is exported again under the same names,
  with what was stored since under a time inside it - a job run that ended later, a Query Store interval read an
  hour late, an hour row rebuilt. The manifest says `"pass": "final"`, and a marker
  `_manifests/_final/<name>__<from>__<to>` follows it. Replace a window's rows when a newer manifest for it arrives.
- A row stored more than `final_after_hours` after its own time is in neither pass. Re-export those hours by hand:
  `pgvigil export -from 2026-01-31T14:00:00Z -to 2026-01-31T16:00:00Z`. Nothing here claims that no late row is
  ever missed.
- A run reaches back `max_window_age_hours` (48). An hour between the export's first window and that reach with no
  manifest has **aged out**: every run names it with the `-from / -to` line that fills it and exits 1, and
  `-status` lists it. `pgvigil export -gap <from> <to>` accepts the hole: it writes a manifest with `"gap": true`
  and no table for each such hour. A new export on an old repository starts `max_window_age_hours` back and names
  nothing before its first window.
- One table cannot stop the export. A table whose read fails leaves its window without a manifest (exit 1) and is
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
- A subset run (`-tables a,b` with `-from / -to`) writes a manifest and files marked `__t<8 hex>`: it never
  replaces a full window's.
- Two machines exporting one repository to one destination are not supported (the lock is per machine); a manifest
  is written only where none is, so the second writer fails instead of replacing the first's.

### The manifest

`contract_version` (1, the first key), `repository`, `window` (`from_utc`, `to_utc`), `pass` (1 or `"final"`),
`gap`, `pgvigil_version`, `schema_migrations`, `started_at`, `finished_at`, and:

- `tables[]`: `table`, `kind`, `time_column`, `key_columns`, `output_files[]` (`path` under `<prefix>/<name>/`,
  `row_count`, `byte_size`, `sha256`), `row_count`, `byte_size`, `columns[]` (`name`, `pg_type`, `parquet_type`,
  `note`), `read_ms`.
- `skipped[]`: a table not exported under this configuration, and why.
- `failed[]`: a table given up after three failed runs, and its error.
- `dropped_columns[]`: a column left behind, and why.

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
  other table (a blocked statement, a deadlock graph, a job's command, a log line's message) are dropped and named
  in `dropped_columns`; the rest of the table is carried.
- **Audit is off unless you carry it.** Without `carry: [audit]` these are skipped: pgvigil's own action logs (who
  acknowledged, ran, changed what), the servers' audit trails and their counts, failed logins, and the posture
  tables (logins and roles, role members, grants, hba rules).
- Never exported: the web UI's logins; the collector's cursors and counter baselines; the service's queues and
  marks; its inventory of connection references, hosts and logins. And these columns of tables that are carried:
  a mail's recipients, subject, body and attachment, an alert channel's address, a claim token, a Patroni URL.
- A `state` or `dimension` table over `snapshot_max_bytes` (256MB) is left out and named in `skipped`.
- Views are not exported: the findings are derived, not stored.
- What leaves the repository cannot be called back: that is why both carries are off by default.

## Types

| PostgreSQL | Parquet |
|---|---|
| boolean | BOOLEAN |
| smallint, integer | INT32 |
| bigint | INT64 |
| real / double precision | FLOAT / DOUBLE |
| numeric(p, s), p up to 38 | DECIMAL(p, s) |
| numeric with no precision | DOUBLE - except the identity and sequence figures that reach past the bigint line, which are DECIMAL(38, 0) |
| timestamp with time zone | TIMESTAMP(MICROS, adjusted to UTC) |
| timestamp without time zone | TIMESTAMP(MICROS, not adjusted) |
| date | DATE |
| text, varchar, name, uuid, inet, pg_lsn | STRING |
| bytea | BYTE_ARRAY |
| json, jsonb | STRING with the JSON annotation |
| an array of one of the scalars above | LIST of it, its elements OPTIONAL |
| anything else | STRING holding PostgreSQL's text form; the manifest's column says `as text` |

A timestamp of infinity, and a NaN in a DECIMAL column, are written as null and the manifest's column says
`infinite as null`. Units are as stored (bytes, milliseconds, the column's own name says which). A column missing
from an older file is null. The repository's encoding must be UTF8.

## Destinations and their rights

- `folder`: `path`. Each object is written beside its place and renamed.
- `s3`: `bucket`, `prefix`, `region`, and for an S3-compatible store its `endpoint`; `profile` to name one.
  Credentials come from the AWS default chain, never from this file. Rights on the prefix: `s3:PutObject`,
  `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, and `s3:ListBucket` on the bucket. A file over
  64 MB goes up in parts. pgvigil sends no checksum trailer of its own (S3-compatible stores differ on them).
- `azure_blob`: `container`, `prefix`, and one way in: `connection_string: env:NAME`, `sas_url: env:NAME` (the
  account's URL with its SAS), or `account_url` with the default credential (a managed identity, the environment,
  the Azure CLI's login). Rights: read, write, delete and list on the container (Storage Blob Data Contributor).

## The reading session

Every session of the export is `pgvigil-export` in `pg_stat_activity`, read only from its first statement
(`default_transaction_read_only`), with `statement_timeout` (120 s, `export.statement_timeout`), `lock_timeout`
5 s, `work_mem` 16MB and no parallel workers. Each table of a window is read in one
`REPEATABLE READ READ ONLY` transaction that has ended before anything is uploaded, by one statement that starts
with `/* pgvigil-export:<table> */`. A window table is read one instance at a time through its
(instance_id, time) index, for every row of `instances`, active or not (a removed instance's history stays, and
is exported). JIT is off in the session: on a read this small the compilation costs more than the read. Behind
PgBouncer these startup settings must be in `track_extra_parameters`.

## Seeing it

- `pgvigil export -status [-json]`: the newest window, the hours without a manifest or without their final pass,
  the hours aged out.
- With the exporter's login, the Collector page shows a **Parquet export** panel: the last windows, their
  outcome and sizes, and a line when the last run failed or the export is more than 3 hours behind.
  `pgvigil export -off` removes the export's row from the repository when you turn it off, so that nothing calls
  it late.

## Not proven by the proof

`scripts/proof-parquet.sh` reads every file back with an independent reader and writes to an S3-compatible server
and to Azurite in containers. It does not prove:

- real AWS S3 and real Azure Blob, the AWS `profile`, the Azure default credential;
- the refusal of a second manifest on S3 and on Blob (a manifest is put only where none is; the folder's refusal
  has a unit test, the two stores were tried for it with another client only);
- the 256 MB line that closes a file at its real size (a unit test crosses it with small files; the 64 MB line of
  a row group and the 1,000,000-row line are crossed for real);
- the refusal of a repository whose encoding is not UTF8;
- a session through PgBouncer;
- the build with FIPS 140-3 on, and the Windows file lock;
- the Collector page's panel drawn in a browser (the proof reads what it draws from, `GET /api/export`).

The layout, the manifest and the rules above follow the file contract of PerformanceMonitor's exporter closely
(MIT; see THIRD-PARTY-NOTICES.md).
