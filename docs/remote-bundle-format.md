# The remote collector's bundle (format 1)

A remote collector (docs/remote-collector.md) reads its instances as any pgvigil collector does and writes each
instance's interval as a **bundle**: a folder of plain files any tool can read (`gunzip`, `jq`, `sha256sum`). A hub
pgvigil ingests the bundles from a drop (a folder, an S3 or GCS bucket, an Azure Blob container). This page is the
format; `internal/remote/format` is its code, and both the writer and the hub use that package for it.

## The folder

```
<site>/<collector>/<instance-key>/<yyyy-mm-dd>/<seq>-<window end>/
    <view>.ndjson.gz     one per view that has rows in the interval
    SHA256SUMS           sha256sum's form, one line per view file
    manifest.sig         only when the collector signs (Ed25519 over manifest.json's bytes)
    manifest.json        written last
```

- `<site>` and `<collector>`: lower-case letters, digits, `_`, `.`, `-`, a letter or a digit first, at most 63.
- `<instance-key>`: the instance's name with every byte that is not a letter, a digit, `_`, `-` or a `.` after the
  first byte written as `%XX` (upper-case hex): `HOST\INST` is `HOST%5CINST`. Each name has exactly one key.
- `<yyyy-mm-dd>`: the UTC day of the window's end, so a reader lists one day at a time.
- `<seq>`: ten digits from `0000000001`, one more per bundle of the instance's stream; `<window end>`:
  `yyyymmddThhmmssZ` (UTC).
- A folder ending in `.part` is still being written on the collector's host: nobody reads it. On the host the
  writer renames it whole; on a drop that has no rename (a bucket) `manifest.json` is the last object written.

## A view file

`<view>.ndjson.gz` is gzip of one JSON object per line, one line per batch the collector handed over:

```json
{"n": 1, "at": "2026-11-16T17:51:00Z", "rows": [{"session_id": 52, "wait_type": "LCK_M_X"}]}
```

- `n`: the batch's number across the whole bundle, from 1, in the order the collector produced them; the hub
  replays the batches of all views in `n` order.
- `at`: the batch's snapshot time.
- `rows`: a list of row objects, the columns the collector's import function takes. Numbers are written as the
  collector read them (a 64-bit query id is not rounded); a reader passes `rows` through as bytes.
- Statement text is never in a bundle: under `query_text: hash` each text column holds the SHA-256 of its normalized
  form (the same statement gives the same value in every interval); under `none` it is null.

## SHA256SUMS

`sha256sum` output over the view files (`<sha256>  <file name>`, two spaces), so `sha256sum -c SHA256SUMS` in the
folder checks them. The manifest is not in it: the manifest is written last and carries every file's sum and the
sum of SHA256SUMS itself.

## manifest.json

| key | what |
|---|---|
| `format` | 1. A reader refuses a newer format (the hub sets the bundle aside and reads it after its own upgrade). |
| `pgvigil_version`, `schema_level` | the writing binary's release and the newest migration it carries |
| `site`, `collector` | as in the folder |
| `stream` | 16 to 64 lower-case hex digits, random, new when the collector's state folder is new: a new stream starts at seq 1 |
| `seq`, `window_from`, `window_to` | as in the folder; `window_to` to the second is the folder's end |
| `query_text` | `hash` or `none` |
| `instance` | `engine` (postgres, sqlserver), `name`, `platform`, `server_version`, `version_num`, `is_replica`, `tags` |
| `files` | per view file: `view`, `name` (`<view>.ndjson.gz`), `batches`, `rows`, `bytes`, `raw_bytes` (uncompressed), `sha256` |
| `sums_sha256` | the sha256 of SHA256SUMS |
| `reads` | every collection of the instance's schedule: `status` `ran`, `failed` (`runs`, `failed` count them) or `skipped` (`reason`: `off`, `not_due`, `not_applicable`, `running`), and `interval_secs`, the collection's interval on the collector (the hub judges the collection's staleness by it) |
| `runs` | every run: `collection`, `at`, `ms`, `status`, `note`, `stage` |
| `failures` | every run that never reached its rows: `kind` (`connect`, `secret`, `run`), `collection`, `at`, `ms`, `cause` |
| `cursors` | how far each source was read when the bundle closed: `kind` `log` (`at`), `mssql` (`file_name`, `file_offset`, `last_event_at`, `last_seq`), `seq` (`seq`), `list` (`names`: a list the store's import keeps beside a cursor - backup history's database list, backup files' unlisted databases and the sets it holds) or `null` (a source the store holds as NULL; nothing else) |
| `heartbeat` | the collector's `host`, `started`, `at`, `instances`, `fail_streak` |

A key the reader does not know, or a value outside its set, is refused.

## What a reader checks, in order

1. The signature, when the hub lists the collector's keys (the hub's step; the format's code does not hold keys).
2. The manifest: its format, its keys and values; the folder it was found in names the same site, collector,
   instance, seq and window end.
3. No file in the folder that the manifest does not list (`extra`).
4. SHA256SUMS: there (`missing`), its sha256 the manifest's and its lines the manifest's files (`checksum`).
5. Each view file: there (`missing`), not shorter (`short`), its bytes the manifest's (`checksum`), under the
   reader's uncompressed cap (`too_big`), its lines `{n, at, rows}` with rows a list of objects (`malformed`), its
   batches, rows and uncompressed bytes the manifest's (`count`).
6. The batch numbers across the bundle are 1 to N, each once (`malformed`).

`missing` and `short` can be a copy that has not finished: the hub retries them until its settle time and sets the
bundle aside only after it. Every other kind sets the bundle aside with the kind as its reason.

## What sums do and do not give

The sums and the row counts catch a file damaged, cut or changed on the way. They do not say who wrote a bundle:
anyone who can write the drop can change a file and its sum together. Who may write a drop is its access rights
(each site its own drop, the site's identity the only writer, the hub's credential read-only), and a collector
may also sign (`remote.sign: true`). The files are not encrypted by pgvigil: in transit the transport's
encryption (HTTPS, SFTP), at rest the store's own.

## For the slices building on this format (v0.4.0)

- The writer (internal/remote) implements `store.Store` (internal/store): what a collector writes goes into the
  open bundle, what it asks (cursors, settings, the counter list, schema due) is answered from the collector's
  state folder.
- The hub's ingest (internal/ingest) lists `<site>/<collector>/<instance-key>/<day>/` on the site's drop
  (`remote_sites:` in pgvigil.yaml), verifies each bundle with this package, and loads it through migration 0329:
  `pgvigil.remote_collectors` (each collector's heartbeat), `remote_bundles` and `remote_batches` (the once-only
  ledgers: a bundle, and each of its batches by view and `n`), each stream's high-water seq, set-aside and late
  bundles with their reason, `instances.as_of` (the window end of the newest bundle loaded) and the instance's
  owner (the site), `pgvigil.import_remote_ensure` and the silence findings per site and per instance.
- The hub's pages read 0329's three views (SELECT granted to the reader role serve reads with) and say 'as of
  <time>', judge a remote collection's staleness by its interval and keep every live door shut in words:
  - `pgvigil.remote_instance_state`: one row per instance a site owns - `instance_id`, `name` (`<site>/<name>`),
    `engine`, `site`, `collector`, `as_of` (the newest loaded bundle's `window_to`), `interval_secs` (that bundle's
    window), `expected_every_secs` (the site's, as ingest last synced `remote_sites:`), `loaded_at`.
  - `pgvigil.remote_collector_state`: one row per collector - `site`, `collector`, `pgvigil_version`, `host`,
    `heartbeat_at`, `instances`, `fail_streak`, `newest_bundle_at`, and the counts of `gaps`, `set_aside` (with
    `newest_set_aside_reason`), `late` and `conflicts`.
  - `pgvigil.remote_collection_interval`: `instance_id`, `collection`, `interval_secs` - the newest bundle's
    `reads[].interval_secs` per collection.
- A remote instance's alerts do not clear between bundles: 0329's `alert_due` holds an owned instance's clear time
  to at least its interval plus its site's `expected_every` (the channel's `clear_after` when that is longer).
