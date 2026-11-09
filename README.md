# pgvigil

PostgreSQL monitoring for DBAs: daily checks, running queries with blocking chains, the statements that cost the most, counters and rates, replication and slots, database inventory, and alerting, across on-prem PostgreSQL, Amazon RDS and Aurora, Azure Database for PostgreSQL, Google Cloud SQL and AlloyDB.

One collector binary (Go, static, no runtime on the target) polls each instance on a schedule and writes into a PostgreSQL repository. A web UI served by the same binary, and later an installable desktop client, read the repository; Grafana can read it too.

Status: phase 1, under construction. The collector, the repository, the collections below and the first UI pages work and are proven on PostgreSQL 18 and on Aurora PostgreSQL 17 (the AWS log and DMS doors); the installers, the UI login and the release are not built yet. Nothing is released.

## What it collects today

| Collection | Cadence | Source | Stored as |
|---|---|---|---|
| instance | hourly | version, recovery state, settings (server-level sources only, credentials masked), extensions | current state plus a history of setting changes |
| activity | 1 min | pg_stat_activity: active and idle-in-transaction sessions, every blocker any Lock waiter names, pg_blocking_pids | samples in monthly partitions, a per-snapshot summary, `blocking_chains()` to the head |
| statements | 5 min | pg_stat_statements, top 500 by time plus top 200 by calls, text capped and masked | per-interval deltas with reset detection, `top_statements()` over a window |
| dbstats | 1 min | pg_stat_database, bgwriter / checkpointer / WAL, pg_stat_io | cumulative rows, `*_rate()` functions over a window |
| replication | 1 min | pg_stat_replication, pg_stat_wal_receiver, slots with retained WAL, subscriptions, publications, conflicts, aurora_replica_status() | one row per object per snapshot, `replication_checks` view |
| databases | hourly | pg_database with sizes, xid and multixact age | current inventory plus a size history |
| jobs | 1 min | pg_cron (cron.job, cron.job_run_details) and pgAgent (pga_job, pga_joblog) where installed | current jobs, a run history, `job_failures` and `job_running` views |
| logs | 1 min | RDS / Aurora: the postgresql log exported to CloudWatch Logs, read from a cursor with a 5 min overlap: slow statements, lock waits, deadlocks, failed logins (text masked and capped) | `log_events` in monthly partitions, `log_cursor` per source |
| dms | 1 min | AWS DMS tasks named in the instance's `aws.dms.tasks` (or `*`): DescribeReplicationTasks, DescribeTableStatistics, DescribeReplicationInstances, CloudWatch CDC latency and host metrics; read only | `dms_tasks`, `dms_table_stats`, `dms_instances` (current, absent objects kept with `is_present = false`), `dms_task_sample` per run, `dms_checks` view |

Platform detection runs on every connection (on-prem, RDS, Aurora, Azure, Cloud SQL, AlloyDB) and each collection says whether it applies to that platform and version. Column names are taken from the server's own catalog views, so PostgreSQL 13 through 18 share one query set.

## Design

- The collector runs as a `pg_monitor` login at most, opens read-only sessions with a 30 s statement timeout and a 2 s lock timeout, and never writes to a monitored server.
- Rows reach the repository as a JSON array handed to `pgvigil.import_<collection>(instance_id, snapshot_at, payload)`; the collector never knows the table shapes. The import functions are SECURITY DEFINER: the collector's repository login (`pgvigil_collector`) can execute them and read nothing. A `pgvigil_reader` role serves the UI.
- Time-series tables are partitioned by month (UTC) and dropped whole by `pgvigil.purge()`.
- Credentials never sit in the config file: a DSN is `env:NAME` or `file:/path`. On the managed platforms the platform's own token login (IAM, Entra, Cloud SQL IAM) is the intended door.
- Credentials inside collected text are masked before they leave the target (replication conninfo, `PASSWORD '...'` literals, `password=` / `PWD=` in connection strings).
- `query_text: full | normalized | none` says what statement text the repository may hold at all: the text as the server shows it, every literal replaced by `?`, or no text (hashes and counters only); per file or per instance.
- The AWS door (`aws:` block per instance) reads only: CloudWatch Logs, the DMS Describe* calls and CloudWatch metrics. Nothing starts, stops or modifies a task.

## Build and run (from source, for now)

```
go build -o bin/pgvigil ./cmd/pgvigil
cp deploy/examples/pgvigil.example.yaml pgvigil.yaml     # edit: repository dsn, instances
export PGVIGIL_REPO_DSN='postgres://pgvigil_agent:...@repo-host:5432/pgvigil?sslmode=require'
bin/pgvigil migrate -config pgvigil.yaml                  # as the repository owner, once per upgrade
bin/pgvigil roles                                         # prints the CREATE ROLE statements
bin/pgvigil collect -config pgvigil.yaml -once instance   # one collection, one run
bin/pgvigil run -config pgvigil.yaml                      # every collection on its schedule
bin/pgvigil serve -config pgvigil.yaml -dsn env:PGVIGIL_READER_DSN   # web UI on http://127.0.0.1:8080/
```

`pgvigil serve` is read only: its sessions are `default_transaction_read_only` with a 15 s statement timeout, and `-dsn` should name a login holding only `pgvigil_reader`. It listens on loopback by default and has no login of its own yet, so anything wider belongs behind a proxy with authentication. Pages: Overview (daily checks: failing or stale collections, replication, failed jobs, DMS tasks failed or stopped, CDC latency, tables in error, deadlocks and checksum failures in 24 h), Instances, Running queries (blocking chains with the head, history by snapshot time), Statements (top by total time over a window), Counters (database, server, IO and session rates) and DMS (tasks, their tables, the replication instances). The JSON endpoints under `/api/` return `{columns, rows}` and serve Grafana or scripts as well.

The frontend is TypeScript under `web/`, built into `internal/web/dist/` (committed, so `go build` needs no Node): `cd web && npm ci && npm run build` after a change there.

`scripts/*.sh` are the proofs: each seeds a condition on a throwaway PostgreSQL (a lock chain, a statements reset, a replication slot, a password literal), collects, and checks the repository against the expected result written in its header. `scripts/integration.sh` runs in CI against PostgreSQL 13, 16 and 18.

## Releases and how to verify one

A tag `v*` runs `.github/workflows/release.yml`: tests, static binaries for Linux (amd64, arm64), Windows (amd64) and macOS (arm64, amd64), a `SHA256SUMS` file, and a keyless [Sigstore](https://www.sigstore.dev/) signature of that file made with the workflow's own GitHub identity (no signing key exists anywhere). To verify a download:

```
sha256sum -c SHA256SUMS --ignore-missing
cosign verify-blob --signature SHA256SUMS.sig --certificate SHA256SUMS.pem \
  --certificate-identity "https://github.com/aachaemenes/pgvigil/.github/workflows/release.yml@refs/tags/<tag>" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
```

The first line proves the binary is the one the checksums name; the second proves the checksums file came out of this repository's release workflow for that tag. No release exists yet.

## Licence

MIT. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). pgvigil is an independent project, not affiliated with Trimble, Inc. or DBA Dash.
