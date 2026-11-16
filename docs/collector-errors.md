# Collector errors

Checks > Collector errors (`#/collectorerrors`, at the root, in a tag folder and on every instance of either engine)
lists every run of a collection that did not end well, as DBA Dash's Checks > DBA Dash ErrorLog does. pgvigil keeps
those runs in `pgvigil.collection_log` for 30 days (purge's own window); nothing is collected for the page and nothing
is set up on a monitored server.

## What a row is

- **Type**: Error (the run failed), Warning (the run finished, one of its parts did not: a batch collection whose part
  was refused goes on with the next), Skipped (the collection did not apply, or the login lacks a right it needs:
  hidden unless the Skipped picker shows it). pgvigil never retries a run, so DBA Dash's Retry type has no rows here.
- **Stage**: Connect (the server did not answer; DBA Dash counts this under Collect), Collect (the read on the server),
  Import (the repository's side: a write, a batch part included, or the read of the collector's own cursor; the
  run's note then leads with that error), Other (the service's own work, such as a rollup's
  heal). A row written before migration 0198 has no stage of its own: it is read from its note ('connect: ' is Connect,
  'rollup ' is Other, anything else Collect). There is no WMI stage: pgvigil reads nothing through WMI.
- **(the service)**: the service's own failures where pgvigil already stores them - an alert send that failed or was
  refused (the Alerts page's log; a test send is labelled as one), a report mail that failed or was refused (Report
  mail), a configured DBA Dash repository that was not read at its last attempt (Imported servers). They show at the
  root and in a tag folder, never on one instance, each with a link to the page where it is handled.
- **Not here**: what only the service's own log holds (journalctl, or the Windows event log for the service), and a run
  that failed before its instance was recognised (the platform not detected, the instance row not made).

## Views, drill and filters

Three views over one row set, so a count always lists the rows it counts: a row per instance (the default at the
root and in a folder), a row per collection (the default on one instance), a row per error. Each instance, collection,
type, stage and count is a link that narrows the page in place; the page's address carries the filters, so Back goes
up and a narrowed view can be shared. The filters: Skipped (hidden or shown), Type, Stage, a text in the note, the
collection (from a drill), and the page's time range. A count of 0 is drawn empty, as DBA Dash draws NULL.

## Suggestions

A column on a row per instance and one card per kind at the top: two or more collections failing on a missing right
(the note names one: permission denied, must be superuser, VIEW SERVER STATE ...) suggests granting what the engine's
docs list (`docs/postgres.md`, `docs/sqlserver.md`) or turning those collections off; an instance whose every error is
a failed connection is unreachable (the server unreachable finding). DBA Dash's one suggestion is about WMI.

## Acknowledge

Acknowledge on an instance's row (or Acknowledge all in view, one write per instance) marks the instance's errors up
to the newest shown: the page greys them and counts the new ones, and the Summary's Collection Errors cell leaves them
out of its 24-hour count and stops calling a collection failing whose failed run is under the mark - until a newer
error comes (DBA Dash's Acknowledge Errors, which is one date for the whole repository). It is offered only with no
filter set and a range of 24 hours or more that ends now, because it covers every error of the instance, shown or
not, and the Summary counts the last 24 hours; an instance with nothing new since its mark is not offered it again. Who and when are kept (the acknowledgements'
log); Unacknowledge brings them back. The mark is the error log's row number (`log_id`), not a time: a run's time is
when it started, so a long run that fails later would otherwise count as acknowledged.

## Links in

Collection dates' last error opens the page at that instance and collection; the Collector page's failure count of a
collection opens its errors of the last 24 hours (that count is the collector's runs that ended with an error, the list
is the error log's rows: the two can differ).

## API

`GET /api/collectorerrors?[instance=|instances=][&tag=][&service=1][&from=&to=][&view=instance|collection|error]
[&coll=][&type=Error|Warning|Skipped][&stage=Connect|Collect|Import|Other][&q=][&skipped=1]`: the parts are rows, insights
and marks. The acknowledgement is an `ack` row (`check_key 'collector errors'`, `seen_state 'log_id:<n>'`) written
through `POST /api/ack`.

## Store

Migration 0198 adds `collection_log.stage`, a 7-argument `pgvigil.log_collection(..., p_stage)` beside the
6-argument one (whose rows carry no stage), `pgvigil.collection_error_class(status, note, stage)` and an index on
`collection_log (instance_id, snapshot_at)`.

## PostgreSQL's errors

This page is the collector's own errors, for both engines. A PostgreSQL server's own log errors are on each instance's
Logs page (`#/logs`, `GET /api/logs` and `/api/logs/groups`); there is no fleet-wide stream of them yet. SQL Server's
fleet stream is SQL Server errors (`docs/sqlserver-readers.md`).

## Proof

`scripts/proof-collector-errors.sh` rows A-E, G and H.
