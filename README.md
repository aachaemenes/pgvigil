# pgvigil

PostgreSQL monitoring for DBAs: daily checks, running queries with blocking chains, the statements that cost the most, counters and rates, replication and slots, database inventory, and alerting, across on-prem PostgreSQL, Amazon RDS and Aurora, Azure Database for PostgreSQL, Google Cloud SQL and AlloyDB.

One collector binary (Go, static, no runtime on the target) polls each instance on a schedule and writes into a PostgreSQL repository. A web UI served by the same binary, and later an installable desktop client, read the repository; Grafana can read it too.

Status: phase 1, under construction. The collector, the repository, the collections below, the web UI with its login and HTTPS listen work and are proven on PostgreSQL 13 through 18 and on Aurora PostgreSQL 17 (the AWS log and DMS doors); the installers and the service wrappers ship with v0.2.0 (the section below); the desktop wrapper is not built yet. The first release is [v0.1.0](https://github.com/aachaemenes/pgvigil/releases/tag/v0.1.0): static binaries for Linux, Windows and macOS.

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
| dms | 1 min | AWS DMS tasks named in the instance's `aws.dms.tasks` (or `*`): DescribeReplicationTasks, DescribeTableStatistics, DescribeReplicationInstances, CloudWatch CDC latency and host metrics; read only | `dms_tasks`, `dms_table_stats`, `dms_instances` (current, absent objects kept with `is_present = false`), `dms_task_sample` per run, `dms_checks` view (a task stopped on purpose warns until it leaves the list) |

Platform detection runs on every connection (on-prem, RDS, Aurora, Azure, Cloud SQL, AlloyDB) and each collection says whether it applies to that platform and version. Column names are taken from the server's own catalog views, so PostgreSQL 13 through 18 share one query set.

## Design

- The collector runs as a `pg_monitor` login at most, opens read-only sessions with a 30 s statement timeout and a 2 s lock timeout, and never writes to a monitored server.
- Rows reach the repository as a JSON array handed to `pgvigil.import_<collection>(instance_id, snapshot_at, payload)`; the collector never knows the table shapes. The import functions are SECURITY DEFINER: the collector's repository login (`pgvigil_collector`) can execute them and read nothing. A `pgvigil_reader` role serves the UI.
- Time-series tables are partitioned by month (UTC) and dropped whole by `pgvigil.purge()`.
- Credentials never sit in the config file: a DSN is `env:NAME` or `file:/path`. On the managed platforms the platform's own token login (IAM, Entra, Cloud SQL IAM) is the intended door.
- Credentials inside collected text are masked before they leave the target (replication conninfo, `PASSWORD '...'` literals, `password=` / `PWD=` in connection strings).
- `query_text: full | normalized | none` says what statement text the repository may hold at all: the text as the server shows it; every literal replaced by `?` and comments dropped, keyed by a hash of that normalized form (nothing of the raw text, not even its hash, is kept); or no text and no text hash at all. Per file or per instance.
- The AWS door (`aws:` block per instance) reads only: CloudWatch Logs, the DMS Describe* calls and CloudWatch metrics. Nothing starts, stops or modifies a task.
- The web UI has its own login: users in `pgvigil.ui_users` with argon2id password hashes, managed by `pgvigil user` as the repository owner. The UI's repository login verifies a password through one SECURITY DEFINER function (`pgvigil_auth` role) and can never read the hashes; a `pgvigil_reader` login (Grafana, a script) cannot call it. A session is a random token in an HttpOnly, SameSite=Strict cookie (Secure under TLS), held in the serve process for 12 hours; every request behind it re-reads the user's hash, so a user disabled, removed or given a new password loses an open session at once. A POST needs the `X-Pgvigil` header. After five failed logins in a minute an address is refused for the rest of the minute (429); a user name is only slowed down (2 s more per failure, 20 s at most), never locked, so nobody can keep an operator out by guessing at the name. The address is the TCP peer: behind a reverse proxy every client is one address and the limit counts the proxy (X-Forwarded-For is deliberately not trusted).
- `pgvigil serve` listens on loopback by default. A listen reachable from other machines needs `-tls-cert` and `-tls-key` and keeps the login: it refuses to start without them. `-no-login` is accepted on loopback only.

## Quick start

Download the binary for your platform from the [latest release](https://github.com/aachaemenes/pgvigil/releases/latest), verify it (the section below), rename it `pgvigil` (`pgvigil.exe` on Windows) and put it anywhere on the PATH; `pgvigil version` prints its tag. From source instead: Go 1.27, `go build -o bin/pgvigil ./cmd/pgvigil` or `make build`.

1. A repository database on a PostgreSQL 13+ server (any edition, RDS and Aurora included), and a login that owns it; this is the only place pgvigil writes. The owner needs CREATEROLE: `migrate` creates the three NOLOGIN roles of the access contract (`pgvigil_collector`, `pgvigil_reader`, `pgvigil_auth`). On RDS and Aurora the master user has it.
   ```
   CREATE ROLE pgvigil_owner LOGIN CREATEROLE PASSWORD '...';
   CREATE DATABASE pgvigil OWNER pgvigil_owner;
   ```
2. The config: copy `deploy/examples/pgvigil.example.yaml` to `pgvigil.yaml`, name the repository DSN as `env:PGVIGIL_REPO_DSN` and list the instances to monitor (each DSN as `env:` or `file:`). Nothing secret goes in the file.
3. The schema and the roles, as the owner:
   ```
   export PGVIGIL_REPO_DSN='postgres://pgvigil_owner:...@repo-host:5432/pgvigil?sslmode=require'
   pgvigil migrate -config pgvigil.yaml          # once per upgrade
   pgvigil roles                                  # prints the CREATE ROLE statements: run them, passwords filled in
   ```
   `roles` prints three logins: the collector's (`pgvigil_collector`: may only call the import functions), the UI's (`pgvigil_reader` + `pgvigil_auth`: reads every view and verifies UI passwords) and the monitoring login for each monitored server (`pg_monitor`).
4. The first UI user, as the owner (the password is asked for twice, at least 12 characters; `PGVIGIL_PASSWORD` or a piped line for a script):
   ```
   pgvigil user add admin -config pgvigil.yaml
   ```
5. The collector, as the collector login:
   ```
   export PGVIGIL_REPO_DSN='postgres://pgvigil_agent:...@repo-host:5432/pgvigil?sslmode=require'
   pgvigil collect -config pgvigil.yaml -once instance   # one collection, one run: the first sight of each instance
   pgvigil run -config pgvigil.yaml                       # every collection on its schedule, until stopped
   ```
6. The web UI, as the UI login. On the machine itself, over loopback:
   ```
   export PGVIGIL_UI_DSN='postgres://pgvigil_ui:...@repo-host:5432/pgvigil?sslmode=require'
   pgvigil serve -config pgvigil.yaml -dsn env:PGVIGIL_UI_DSN                 # http://127.0.0.1:8080/, sign in as admin
   ```
   For other machines, over HTTPS (a certificate from your CA, or a self-signed pair from `pgvigil cert`, which the browser will warn about):
   ```
   pgvigil cert -hosts pgvigil.example.internal,10.0.0.5                       # writes pgvigil.crt and pgvigil.key (0600)
   pgvigil serve -config pgvigil.yaml -dsn env:PGVIGIL_UI_DSN -listen 0.0.0.0:8443 -tls-cert pgvigil.crt -tls-key pgvigil.key
   ```
   `serve` is read only: its sessions are `default_transaction_read_only` with a 15 s statement timeout. Pages: Overview (daily checks: failing or stale collections, replication, failed jobs, DMS tasks failed or stopped, CDC latency, tables in error, deadlocks and checksum failures in 24 h), Instances, Running queries (blocking chains with the head, history by snapshot time), Statements (top by total time over a window), Counters (database, server, IO and session rates) and DMS (tasks, their tables, the replication instances). The JSON endpoints under `/api/` return `{columns, rows}` behind the same login (the session cookie) and serve scripts as well; Grafana reads the repository views directly with a `pgvigil_reader` login.

On Windows the same commands run in PowerShell (`$env:PGVIGIL_REPO_DSN = '...'`, `pgvigil.exe ...`).

## Installing as a service

From v0.2.0 the binary installs itself as a service, and two thin scripts fetch the release, verify its checksum and call it (re-run either to upgrade: the binary and the service definition are replaced, the config is kept):

```
curl -fsSL https://pgvigil.com/install.sh | sh          # Linux (POSIX sh; sudo when not root)
irm https://pgvigil.com/install.ps1 | iex               # Windows, elevated PowerShell
```

`PGVIGIL_VERSION=v0.2.0` pins a tag, `PGVIGIL_BASE_URL` points at a mirror of the release folder (air-gapped sites), `PGVIGIL_NO_SERVICE=1` only downloads and verifies the binary into the current folder. The scripts are `deploy/install.sh` and `deploy/install.ps1` (served from pgvigil.com as the same files); read them first if you like.

What `pgvigil install` does (and `pgvigil uninstall` undoes; `-purge` also removes the config folder and the binary):

- Linux: the binary to `/usr/local/bin/pgvigil`; a system account `pgvigil` (no home, no shell; `-user` names another); `/etc/pgvigil/pgvigil.yaml` (a template that lists no instance) and `/etc/pgvigil/pgvigil.env` (`PGVIGIL_REPO_DSN=` and one line per monitored instance), both `0640 root:pgvigil`; the unit `/etc/systemd/system/pgvigil.service` (`deploy/pgvigil.service`: runs as `pgvigil`, read-only file system, restart on failure), enabled. The service is started only once the config names an instance, so the first run ends with the three steps left to you; after `migrate`, `roles` and the edits, run the installer again or `systemctl start pgvigil`. Logs: `journalctl -u pgvigil`.
- Windows: the binary to `%ProgramFiles%\pgvigil\pgvigil.exe` (the installer script adds the folder to the machine PATH); `%ProgramData%\pgvigil\pgvigil.yaml` (the template points the repository at `file:...\repo.dsn` beside it, one line, empty until you fill it) with the folder readable by SYSTEM, Administrators and the service's own account only; the service `pgvigil` under the virtual account `NT SERVICE\pgvigil` (no password to keep), automatic start, restarted on failure. Started once the config names an instance (each instance DSN as `file:` beside the config: a service has no shell environment). Logs: `%ProgramData%\pgvigil\pgvigil.log` (the service writes that one file and nothing else in the folder; no rotation yet). `uninstall` leaves the PATH entry.
- macOS and the BSDs: the binary and the config template only; run `pgvigil run -config ...` under launchd or your init.

Proofs: `scripts/proof-install.sh` (a Debian container running systemd, a mock release server, a throwaway repository: checksum refusal, install without an instance, the upgrade path starting the service as `pgvigil`, uninstall, purge) and `scripts/proof-install-windows.sh` (the same on a Windows VM over SSH).

Other commands: `pgvigil user list | passwd | disable | enable | remove`, `pgvigil serve -no-login` (loopback only), `pgvigil serve -session-hours 8`.

The frontend is TypeScript under `web/`, built into `internal/web/dist/` (committed, so `go build` needs no Node): `cd web && npm ci && npm run build` after a change there.

`scripts/*.sh` are the proofs: each seeds a condition on a throwaway PostgreSQL (a lock chain, a statements reset, a replication slot, a password literal, a login), collects or serves, and checks the result against the expected result written in its header. `scripts/integration.sh` and `scripts/proof-auth.sh` run in CI against PostgreSQL 13, 16 and 18.

## Releases and how to verify one

A tag `v*` runs `.github/workflows/release.yml`: tests, static binaries for Linux (amd64, arm64), Windows (amd64) and macOS (arm64, amd64), a `SHA256SUMS` file, and a keyless [Sigstore](https://www.sigstore.dev/) signature of that file made with the workflow's own GitHub identity (no signing key exists anywhere). To verify a download:

```
sha256sum -c SHA256SUMS --ignore-missing
cosign verify-blob --signature SHA256SUMS.sig --certificate SHA256SUMS.pem \
  --certificate-identity "https://github.com/aachaemenes/pgvigil/.github/workflows/release.yml@refs/tags/<tag>" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com SHA256SUMS
```

The first line proves the binary is the one the checksums name; the second proves the checksums file came out of this repository's release workflow for that tag.

## Licence

MIT. See [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). pgvigil is an independent project, not affiliated with Trimble, Inc. or DBA Dash.
