# pgvigil

PostgreSQL monitoring for DBAs: daily checks, running queries with blocking chains, the statements that cost the most, counters and rates, replication and slots, database inventory, and alerting, across on-prem PostgreSQL, Amazon RDS and Aurora, Azure Database for PostgreSQL, Google Cloud SQL and AlloyDB.

One collector binary (Go, static, no runtime on the target) polls each instance on a schedule and writes into a PostgreSQL repository. A web UI served by the same binary, and later an installable desktop client, read the repository; Grafana can read it too.

Status: phase 1, under construction. The collector, the repository and the collections below work and are proven on PostgreSQL 18; the UI, the installers and the cloud log and metric doors are not built yet. Nothing is released.

## What it collects today

| Collection | Cadence | Source | Stored as |
|---|---|---|---|
| instance | hourly | version, recovery state, settings (server-level sources only, credentials masked), extensions | current state plus a history of setting changes |
| activity | 1 min | pg_stat_activity: active and idle-in-transaction sessions, every blocker any Lock waiter names, pg_blocking_pids | samples in monthly partitions, a per-snapshot summary, `blocking_chains()` to the head |
| statements | 5 min | pg_stat_statements, top 500 by time plus top 200 by calls, text capped and masked | per-interval deltas with reset detection, `top_statements()` over a window |
| dbstats | 1 min | pg_stat_database, bgwriter / checkpointer / WAL, pg_stat_io | cumulative rows, `*_rate()` functions over a window |
| replication | 1 min | pg_stat_replication, pg_stat_wal_receiver, slots with retained WAL, subscriptions, publications, conflicts, aurora_replica_status() | one row per object per snapshot, `replication_checks` view |
| databases | hourly | pg_database with sizes, xid and multixact age | current inventory plus a size history |

Platform detection runs on every connection (on-prem, RDS, Aurora, Azure, Cloud SQL, AlloyDB) and each collection says whether it applies to that platform and version. Column names are taken from the server's own catalog views, so PostgreSQL 13 through 18 share one query set.

## Design

- The collector runs as a `pg_monitor` login at most, opens read-only sessions with a 30 s statement timeout and a 2 s lock timeout, and never writes to a monitored server.
- Rows reach the repository as a JSON array handed to `pgvigil.import_<collection>(instance_id, snapshot_at, payload)`; the collector never knows the table shapes. The import functions are SECURITY DEFINER: the collector's repository login (`pgvigil_collector`) can execute them and read nothing. A `pgvigil_reader` role serves the UI.
- Time-series tables are partitioned by month (UTC) and dropped whole by `pgvigil.purge()`.
- Credentials never sit in the config file: a DSN is `env:NAME` or `file:/path`. On the managed platforms the platform's own token login (IAM, Entra, Cloud SQL IAM) is the intended door.
- Credentials inside collected text are masked before they leave the target (replication conninfo, `PASSWORD '...'` literals).

## Build and run (from source, for now)

```
go build -o bin/pgvigil ./cmd/pgvigil
cp deploy/examples/pgvigil.example.yaml pgvigil.yaml     # edit: repository dsn, instances
export PGVIGIL_REPO_DSN='postgres://pgvigil_agent:...@repo-host:5432/pgvigil?sslmode=require'
bin/pgvigil migrate -config pgvigil.yaml                  # as the repository owner, once per upgrade
bin/pgvigil roles                                         # prints the CREATE ROLE statements
bin/pgvigil collect -config pgvigil.yaml -once instance   # one collection, one run
bin/pgvigil run -config pgvigil.yaml                      # every collection on its schedule
```

`scripts/*.sh` are the proofs: each seeds a condition on a throwaway PostgreSQL (a lock chain, a statements reset, a replication slot, a password literal), collects, and checks the repository against the expected result written in its header. `scripts/integration.sh` runs in CI against PostgreSQL 13, 16 and 18.

## Licence

MIT. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). pgvigil is an independent project, not affiliated with Trimble, Inc. or DBA Dash.
