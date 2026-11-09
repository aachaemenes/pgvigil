# pgvigil

PostgreSQL monitoring for DBAs: daily checks, running queries with blocking chains, the statements that cost the most, counters and rates, replication and slots, database inventory, and alerting, across on-prem PostgreSQL, Amazon RDS and Aurora, Azure Database for PostgreSQL, Google Cloud SQL and AlloyDB.

One collector binary (Go, static, no runtime on the target) polls each instance on a schedule and writes into a PostgreSQL repository. A web UI served by the same binary, and later an installable desktop client, read the repository; Grafana can read it too.

Status: phase 1, under construction. The collector, the repository, the collections below, the web UI with its login and HTTPS listen work and are proven on PostgreSQL 13 through 18 and on Aurora PostgreSQL 17 (the AWS log and DMS doors); the installers and the service wrappers ship with v0.2.0 (the section below); the desktop wrapper is not built yet. The first release is [v0.1.0](https://github.com/aachaemenes/pgvigil/releases/tag/v0.1.0): static binaries for Linux, Windows and macOS.

## Screenshots

The demo fleet (`pgvigil demo`): the Summary grid, one row per instance and a coloured cell per check group; an instance's running queries with the blocking chain to its head; the DMS tab with the drain readout.

![Summary grid](docs/img/summary.png)

![Running queries with a blocking chain](docs/img/running-queries.png)

![DMS tasks with the drain readout](docs/img/dms.png)

## What it collects today

| Collection | Cadence | Source | Stored as |
|---|---|---|---|
| instance | hourly | version, recovery state, settings (server-level sources only, credentials masked), extensions | current state plus a history of setting changes |
| activity | 1 min | pg_stat_activity: active and idle-in-transaction sessions, every blocker any Lock waiter names, pg_blocking_pids | samples in monthly partitions, a per-snapshot summary, `blocking_chains()` to the head |
| statements | 5 min | pg_stat_statements, top 500 by time plus top 200 by calls, text capped and masked | per-interval deltas with reset detection, `top_statements()` over a window |
| dbstats | 1 min | pg_stat_database, bgwriter / checkpointer / WAL | cumulative rows, `*_rate()` functions over a window |
| iostats | 5 min | pg_stat_io (PG16+) by backend type, object and context; `schedules: iostats: 1m` reads it every minute at about three times the storage (Sizing below); any cadence works, the Counters chart looks back three intervals for its first point | cumulative rows, `iostats_rate()` over a window |
| replication | 1 min | pg_stat_replication, pg_stat_wal_receiver, slots with retained WAL, subscriptions, publications, conflicts, aurora_replica_status() | one row per object per snapshot, `replication_checks` view |
| databases | hourly | pg_database with sizes, xid and multixact age | current inventory plus a size history |
| jobs | 1 min | pg_cron (cron.job, cron.job_run_details) and pgAgent (pga_job, pga_joblog) where installed | current jobs, a run history, `job_failures` and `job_running` views |
| logs | 1 min | RDS / Aurora: the postgresql log exported to CloudWatch Logs, read from a cursor with a 5 min overlap: slow statements, lock waits, deadlocks, failed logins (text masked and capped) | `log_events` in monthly partitions, `log_cursor` per source |
| dms | 1 min | AWS DMS tasks named in the instance's `aws.dms.tasks` (or `*`): DescribeReplicationTasks, DescribeTableStatistics, DescribeReplicationInstances, CloudWatch CDC latency and host metrics; read only | `dms_tasks`, `dms_table_stats`, `dms_instances` (current, absent objects kept with `is_present = false`), `dms_task_sample` per run, `dms_checks` view (a task stopped on purpose warns until it leaves the list) |
| vacuum | 1 min | pg_stat_progress_vacuum and pg_stat_progress_analyze with their pg_stat_activity rows (a VACUUM still waiting for its table lock included), the server's autovacuum state, the xmin holders outside the sessions (slots, prepared transactions, standbys with hot_standby_feedback) | `vacuum_sample` partitions, `vacuum_runs` (a run per pid, start and table, folded from the minute samples), `vacuum_state`, `vacuum_holders`, `vacuum_running` view, `vacuum_history()` (the samples, and the log's autovacuum lines once a reader parses them) |
| vacuum_tables | hourly | per database the tables near or over their autovacuum thresholds (from the table's reloptions and the server settings; PG18's insert threshold scaled by the unfrozen fraction), never or long unvacuumed, autovacuum off, near a forced freeze; age(datfrozenxid) and mxid_age against the freeze max ages | `vacuum_tables` and `vacuum_databases` (current, absent rows kept with `is_present = false`), `vacuum_table_state`, `vacuum_wraparound`, `vacuum_checks` / `vacuum_findings` (over the threshold for 6 h warns, 24 h is critical; wraparound past autovacuum_freeze_max_age warns, at 1,000,000,000 or vacuum_failsafe_age is critical; a vacuum over an hour or waiting on a lock) |
| host | 1 min | on-prem: the `system_stats` extension where the server's DBA installed it (EDB, PostgreSQL licence, built from source: not in PGDG; `GRANT monitor_system_stats TO <login>` is the one opt-in beyond pg_monitor): OS, CPU, memory, load, every mount, device IO; RDS / Aurora: CloudWatch CPUUtilization, FreeableMemory, SwapUsage, DatabaseConnections, FreeStorageSpace / FreeLocalStorage plus DescribeDBInstances (IAM `cloudwatch:GetMetricData`, `rds:DescribeDBInstances`); skipped with its reason where neither door exists | `host_state` current, `host_sample` and `host_io` partitions, `host_disks` (absent volumes kept with `is_present = false`) with `host_disk_history`, `host_checks` / `host_findings` (CPU over 90 % for 10 minutes, swap used, a volume under 10 % free), the fleet `disk_report` |
| storage | 15 min | the WAL directory (`pg_ls_waldir()`), the tablespaces, the RDS allocated storage with its autoscaling maximum, the Aurora cluster volume (VolumeBytesUsed against 128 TiB); growth from the host volumes, the database and table sizes | `storage_state` current, `storage_sample` partitions, `volume_forecast()` (growth per day over 7 and 30 days, days until full), `database_growth()` (days to double), `table_growth()`, `storage_checks` / `storage_findings` (a volume full within 30 days warns, within 7 is critical) |

Platform detection runs on every connection (on-prem, RDS, Aurora, Azure, Cloud SQL, AlloyDB) and each collection says whether it applies to that platform and version. Column names are taken from the server's own catalog views, so PostgreSQL 13 through 18 share one query set.

## Design

- The collector runs as a `pg_monitor` login at most, opens read-only sessions with a 30 s statement timeout and a 2 s lock timeout, and never writes to a monitored server.
- Rows reach the repository as a JSON array handed to `pgvigil.import_<collection>(instance_id, snapshot_at, payload)`; the collector never knows the table shapes. The import functions are SECURITY DEFINER: the collector's repository login (`pgvigil_collector`) can execute them and read nothing. A `pgvigil_reader` role serves the UI.
- Time-series tables are partitioned by month (UTC) and dropped whole by `pgvigil.purge()`, which `pgvigil purge` runs on the operator's schedule (Retention below).
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
   `serve` is read only: its sessions are `default_transaction_read_only` with a 15 s statement timeout. Pages at the root (the fleet, or a tag folder of it): Summary (one row per instance, a coloured cell per check group), Daily checks (failing or stale collections, replication, failed jobs, DMS tasks failed or stopped, CDC latency, tables in error, host and disk, storage forecasts, deadlocks and checksum failures in 24 h), Findings, Instances, DMS (tasks, their tables, the replication instances), Disk report (every volume under a free-% threshold) and Storage (every volume, the soonest full first). Per instance: Summary, Running queries (blocking chains with the head, history by snapshot time), Statements (top by total time over a window), Counters (database, server, IO and session rates), Tables, Replication, Jobs, Logs, DMS, Host (OS, CPU, memory, load, volumes, device IO), Storage (volumes with growth and days until full, WAL, tablespaces, database and table growth), Configuration and Findings. The JSON endpoints under `/api/` return `{columns, rows}` behind the same login (the session cookie) and serve scripts as well; Grafana reads the repository views directly with a `pgvigil_reader` login.

7. The retention: schedule `pgvigil purge` daily as the owner (the Retention section below).

On Windows the same commands run in PowerShell (`$env:PGVIGIL_REPO_DSN = '...'`, `pgvigil.exe ...`).

## Demo

`pgvigil demo` seeds a synthetic fleet through the import functions and, with `-serve`, serves it on loopback without a login: 12 instances across on-prem, RDS, Aurora, Azure and Cloud SQL, 7 days of history with two blocking chains and an idle-in-transaction head, statements with a reset, counters with a daily curve, a lagging replica and an inactive slot, a failed pg_cron job, a lag-warned DMS task with tables in error, and log events. The instances carry the tag `demo` and the name prefix `demo-`; a re-run replaces them and touches nothing else.

```
pgvigil demo -dsn 'postgres://pgvigil_owner:...@host:5432/pgvigil_demo?sslmode=disable' -serve   # into a repository database you own
```

On a laptop with no admin rights and no Docker, a portable PostgreSQL does: unzip the EDB binaries archive (`postgresql-17.x-windows-x64-binaries.zip`; a Linux tarball works the same way) and point `-pgbin` at its `bin` folder. The demo runs `initdb` into `-pgdata` (default `pgvigil-demo-data` in the current folder, reused on the next run), starts that server on a free port, seeds, serves, and stops it when you press Ctrl-C:

```
pgvigil.exe demo -pgbin C:\Users\you\pgsql\bin -serve      # then open http://127.0.0.1:8080/
```

`-instances 1000 -days 7` seeds a scale run (the twelve repeat); `-listen` moves the port. Proven on Linux and on Windows as an administrator; a standard Windows account is not proven yet.

## Installing as a service

From v0.2.0 the binary installs itself as a service, and two thin scripts fetch the release, verify its checksum and call it (re-run either to upgrade: the binary and the service definition are replaced, the config is kept):

```
curl -fsSL https://pgvigil.com/install.sh | sh          # Linux (POSIX sh; sudo when not root)
irm https://pgvigil.com/install.ps1 | iex               # Windows, elevated PowerShell
```

`PGVIGIL_VERSION=v0.2.0` pins a tag, `PGVIGIL_BASE_URL` points at a mirror of the release folder (air-gapped sites), `PGVIGIL_NO_SERVICE=1` only downloads and verifies the binary into the current folder. The scripts are `deploy/install.sh` and `deploy/install.ps1` (served from pgvigil.com as the same files); read them first if you like.

What `pgvigil install` does (and `pgvigil uninstall` undoes; `-purge` also removes the installer's own files, their folder when nothing else is in it, and the binary; `uninstall` takes the same `-bin`, `-config` and `-user` as the install did). The config's folder belongs to the installer (it sets its permissions and `-purge` empties it), so `-config` must sit in a folder named `pgvigil`, or one that is new or holds only the installer's files; a flat `/etc/pgvigil.yaml` is refused.

- Linux: the binary to `/usr/local/bin/pgvigil`; a system account `pgvigil` (no home, no shell; `-user` names another); `/etc/pgvigil/pgvigil.yaml` (a template that lists no instance) and `/etc/pgvigil/pgvigil.env` (`PGVIGIL_REPO_DSN=` and one line per monitored instance), both `0640 root:pgvigil`; the unit `/etc/systemd/system/pgvigil.service` (`deploy/pgvigil.service`: runs as `pgvigil` with its primary group, read-only file system, `ProtectHome` so a `file:` DSN must sit outside `/home` and `/root`, restart on failure except on a configuration error), enabled. The service is started only once the config names an instance, so the first run ends with the three steps left to you; a host that reboots before then fails the unit once with exit 3 (no restart loop) and `systemctl status pgvigil` says why. After `migrate`, `roles` and the edits, run the installer again or `systemctl start pgvigil` (`restart` after an upgrade with `-no-start`). Logs: `journalctl -u pgvigil`.
- Windows: the binary to `%ProgramFiles%\pgvigil\pgvigil.exe` (the installer script adds the folder to the machine PATH); `%ProgramData%\pgvigil\pgvigil.yaml` (the template points the repository at `file:...\repo.dsn` beside it, one line, empty until you fill it) with the folder readable by SYSTEM, Administrators and the service's own account only; the service `pgvigil` under the virtual account `NT SERVICE\pgvigil` (no password to keep), automatic start, restarted on failure. Started once the config names an instance (each instance DSN as `file:` beside the config: a service has no shell environment). Logs: `%ProgramData%\pgvigil\logs\pgvigil.log` (the service may write only under `logs\`, so a deleted log is made again and the config stays out of its reach; no rotation yet). A configuration error stops the service without a retry; a runtime failure is retried after 10, 30 and 60 s. `uninstall` leaves the PATH entry.
- macOS and the BSDs: the binary and the config template only; run `pgvigil run -config ...` under launchd or your init.

Proofs: `scripts/proof-install.sh` (a Debian container running systemd, a mock release server, a throwaway repository: checksum refusal, install without an instance, the upgrade path starting the service as `pgvigil`, uninstall, purge) and `scripts/proof-install-windows.sh` (the same on a Windows VM over SSH).

Other commands: `pgvigil user list | passwd | disable | enable | remove`, `pgvigil serve -no-login` (loopback only), `pgvigil serve -session-hours 8`, `pgvigil demo` (the section below).

The frontend is TypeScript under `web/`, built into `internal/web/dist/` (committed, so `go build` needs no Node): `cd web && npm ci && npm run build` after a change there.

`scripts/*.sh` are the proofs: each seeds a condition on a throwaway PostgreSQL (a lock chain, a statements reset, a replication slot, a password literal, a login), collects or serves, and checks the result against the expected result written in its header. `scripts/integration.sh`, `scripts/proof-dbstats.sh` and `scripts/proof-auth.sh` run in CI against PostgreSQL 13, 16 and 18.

## Retention

Every time series (activity samples, statement deltas, the counters, iostats, replication samples, database and table sizes, log events, DMS samples) is partitioned by month in UTC, and `pgvigil.purge(days)` drops a partition once its whole month is older than `days`, so a daily `purge(30)` keeps between 30 and about 61 days on disk; the row-level series (job runs, activity summaries, statement info, statement and query texts no sample names any more, the collection log) are deleted past the same age. pgvigil does not run it by itself: the operator schedules it, as the repository owner (the function is granted to no other login).

```
pgvigil purge -config pgvigil.yaml -dry-run      # the partitions a run would drop; nothing changes
pgvigil purge -config pgvigil.yaml -days 30      # as the owner: PGVIGIL_REPO_DSN is the owner's DSN, as for migrate
```

Three ways to schedule it:

- systemd: `deploy/pgvigil-purge.service` and `deploy/pgvigil-purge.timer` (daily at 03:15, a random delay of up to 15 minutes, a missed run caught up after a downtime). Copy both to `/etc/systemd/system/`, write the owner's DSN as `PGVIGIL_REPO_DSN=...` in `/etc/pgvigil/pgvigil-purge.env` (`0600 root:root`: systemd reads it as root before it drops to the service account, so the collector's own account never reads the owner's credential; apart from the collector's env file, which holds the collector login), then `systemctl enable --now pgvigil-purge.timer`. `systemctl list-timers pgvigil-purge.timer` shows the next run, `journalctl -u pgvigil-purge` the last.
- pg_cron on the repository server (RDS and Aurora have it; `cron.database_name` is a parameter-group setting, `postgres` by default, so when the repository is another database schedule with `cron.schedule_in_database`, pg_cron 1.4+), as the owner so the job runs as the owner: `SELECT cron.schedule('pgvigil-purge', '15 3 * * *', $$SELECT pgvigil.purge(30)$$);`. On RDS and Aurora the owner needs `GRANT USAGE ON SCHEMA cron TO <owner>` from an `rds_superuser` member first.
- Windows: a daily scheduled task running `pgvigil.exe purge -config C:\ProgramData\pgvigil\pgvigil-purge.yaml -days 30`, where that config is a copy whose `repository.dsn` is a `file:` holding the owner's DSN, readable by the task's account alone (the installed config points at the collector's DSN file). Not proven here yet.

## Sizing

Measured 2026-11-09 against one idle PostgreSQL 18 target with one database, polled for six minutes with pg_stat_io every minute (the default before it became its own collection) and scaled to a day; the 5-minute row is derived from that measurement (the pg_stat_io share divided by five), not measured. The sizing note with the commands and the raw output lives with the project's records. A busy server stores more statement deltas (capped at the top 500 by time plus the top 200 by calls per snapshot) and more activity rows, so these are the floor:

| Collector settings | Repository growth per instance-day | 1,000 instances at 30 days (30-61 on disk with the monthly partitions) |
|---|---|---|
| the defaults (pg_stat_io every 5 minutes), derived | about 8.6 MB | about 260-530 GB |
| `schedules: iostats: 1m`, as measured | about 25.6 MB | about 770 GB-1.6 TB |
| `schedules: iostats: disabled`, or PG15 and older (no pg_stat_io) | about 4.3 MB | about 130-260 GB |

WAL is written on top of that, about the same volume again as the table and index data: size the repository's WAL disk or archive for it. The demo's synthetic history is lighter (about 2 MB per instance-day) and is not a sizing base.

Collectors: one collector polling 1,000 instance entries against one target standing in for the fleet used 94 MB of memory and 0.19 cores on average (about one core in the burst at the start of each minute) and lost no collection; plan one collector per 1,000 instances, or per 500 to halve each one's burst. Each monitored server sees one short connection per collection per interval (9 to 46 ms each on the test target), never a held one. Each collector keeps a pool of connections to the repository at pgx's default size, the CPU count of its host and at least 4 (23 held on the 24-CPU test host); cap it with `pool_max_conns=<n>` in the repository DSN (`...?sslmode=require&pool_max_conns=8` in the URL form, ` pool_max_conns=8` in the keyword form) and size the repository's `max_connections` for the collectors plus the UI (`pgvigil serve` holds at most 8) plus your own sessions, or put a pooler in front of the collectors (PgBouncer in transaction mode suits them: every import is one function call). Ten collectors at the default pool on hosts like the test one would hold about 230 connections.

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
