# Repository migrations

Numbered SQL files applied in name order by `pgvigil migrate`, each inside one transaction and recorded in `pgvigil.schema_version`; a file already recorded is never re-run.

Rule: until the v0.1.0 tag the repository is disposable and a file may be edited in place (every development repository is re-created from scratch by the proofs). From v0.1.0 on, every file is frozen once released; a change is a new file with a higher number, and a function whose signature changes is dropped and re-created there.

Every collection has an import function `pgvigil.import_<collection>(instance_id, snapshot_at, payload jsonb)` that unpacks a JSON array of rows; the collector never knows the table shapes. Time-series tables are partitioned by month in UTC (`pgvigil.ensure_month_partition`) and dropped whole by `pgvigil.purge`.
