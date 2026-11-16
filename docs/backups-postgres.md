# PostgreSQL: base backups, role changes and server state

Two collections and two tabs per instance, two fleet pages, and five Summary columns: the PostgreSQL side of DBA Dash's backups, log shipping, role-change, crash, Query Store, uptime and last-good-check cells. Nothing is installed on the monitored server and nothing is written there.

| collection | every | reads | needs |
| --- | --- | --- | --- |
| `backup_tools` | 15 min | which backup tool the server's `archive_command` and `restore_command` name; that tool's own JSON, run on the collector's host; a standby's replay | pg_monitor (it reads both commands); the tool on the collector's host |
| `rolechange` | 1 min | `pg_is_in_recovery()`, the timeline, `pg_control_system()`'s system identifier, the postmaster's start, the newest timeline history file in `pg_wal`; Patroni's REST API where Patroni is seen or named (below) | pg_monitor for `pg_control_*` and `pg_ls_waldir()` (without it those parts stay empty); for Patroni, the collector's host reaching its REST API |

`backup_tools` does not run on RDS, Aurora, Azure, Cloud SQL or AlloyDB: those platforms take their own backups (the `backups` collection in the README's table reads RDS and Aurora's snapshots and restore window). `rolechange` runs everywhere; its Patroni read on self-managed servers only.

## Base backups (pgBackRest, barman)

pgvigil finds the tool from the server's own settings and keeps only its name and the stanza or server name, never the command (it can carry a credential):

| the command names | the tool | the read, on the collector's host |
| --- | --- | --- |
| `pgbackrest ... --stanza=<s> archive-push` (or `archive-get` in `restore_command`) | pgBackRest, stanza `<s>` | `pgbackrest --output=json --stanza=<s> info` |
| `barman-wal-archive [options] <host> <server>`, `barman-wal-restore ...`, or an `rsync` into `.../<server>/incoming/` | barman, server `<server>` | `barman -f json list-backups <server>` |
| `barman-cloud-wal-archive [options] <url> <server>` | barman-cloud | `barman-cloud-backup-list -f json <url> <server>` |

The binary comes from the collector's `PATH`, runs without a shell for at most 60 seconds, and inherits the collector's environment. A stanza or server name must start with a letter, a digit or `_` (never an option) and is passed after `--`. Of barman-cloud's options only `--cloud-provider` (aws-s3, azure-blob-storage or google-cloud-storage) and `--endpoint-url` (a checked URL) are passed on; the destination URL must be a plain scheme, host, port and path. The listing uses the collector host's own cloud credentials on the bucket the server's command names. **The collector's host needs the tool and read access to the repository:** for pgBackRest a `pgbackrest.conf` with the repository (`repo1-path`, or the object store and its credentials) and the stanza; `pgbackrest info` reads the repository only, never the database. For barman, run the collector on the barman server or give it a barman client configuration that sees the catalog. A tool the server names but the host lacks is a state 'no binary' and an info finding "pgbackrest not on the collector host", never a red cell. A `--config` path inside the server's command is not carried over: the collector's tool uses its own default configuration (or `PGBACKREST_CONFIG` in the collector's environment).

What is kept, per instance and stanza: the read's state, the tool's status (pgBackRest's code and message), the archive's oldest and newest WAL file, the database's system identifier and version; per backup (the newest 50): its label, kind (pgBackRest full, diff, incr; barman full, incremental, rsync, snapshot), status (ok, error, running), start and end, the cluster's size it holds, what it copied and its size in the repository, its first and last WAL file, the backup it is based on, and the WAL archived after it (pgBackRest: the archive's newest segment less the backup's last, at the server's segment size; barman: the WAL belonging to the backup). A backup a later read no longer lists has expired by the tool's retention: it is kept as absent. The read sends every label it lists, so a backup older than the newest 50 is not taken for expired (the newest full and the newest that ended well are always sent too). Only a read that answered judges absence: state ok, or pgBackRest's status 0 or 2 (no valid backup); any other status (1, a missing stanza path; 99, an unreadable repository) is a critical 'pgbackrest read failing' and keeps every backup as it was. barman: a backup without an end (running, failed) is placed by its id's time (barman's default id is its start on the barman server's clock, read as UTC); a listing without `backup_type` (before barman 3.11) is full; barman-cloud backups are full, their times from `begin_time_iso` / `end_time_iso` (barman 3.13 and later) or the older ctime fields read as UTC.

The **Base backups** tab shows each tool with its last backup, kind, size and the WAL since, the newest full backup's age, every backup listed, and the rules hit. The fleet **Backups** page gains the same per instance.

## Log shipping: a standby fed by restore_command alone

On every standby `backup_tools` reads the last replayed commit (`pg_last_xact_replay_timestamp()`), the replay and receive positions, whether replay is paused, and whether a WAL receiver runs. A standby with a receiver is streaming: its lag is the Replication tab's. A standby **without** one is fed by `restore_command` (file-based log shipping): its replay delay is judged here.

Behind an idle primary the last replayed commit's time does not move, which is not a delay. When the fleet holds the standby's primary (the same system identifier, not in recovery, on the standby's timeline first), pgvigil compares: a standby that has replayed past the end of the primary's last archived WAL file has caught up, and its delay raises nothing. When the primary is not in the fleet, the rule judges the delay alone and says so in its detail.

## Role changes

`rolechange` keeps each instance's role, timeline and system identifier and writes a row whenever one of them differs from the read before:

| change | when |
| --- | --- |
| promotion | standby -> primary |
| demotion | primary -> standby (a rewound or rebuilt old primary) |
| timeline | the same role on a higher timeline (a standby following a new primary) |
| another cluster | the system identifier changed: another cluster answers under the instance's name |

Its time: the new timeline's history file in `pg_wal` (its modification time) when it was written between the two reads on the server's own clock; else the postmaster's start when the server restarted between them; else the read that saw the change (within a minute of it). The row also keeps the timelines before and after, whether the postmaster restarted, and how long the role before it was held. Rows are never purged. A standby's timeline comes from its WAL receiver, else from the last restart point, which can trail a switch until the next restart point: a lower reading from the same source is not a change.

The **Server state** tab lists the instance's changes; the fleet **Replication** page lists every instance's.

## The fleet Replication page

Instances are grouped into clusters by system identifier: per cluster the primary and its standbys, one row per member with its timeline and role since, how it is fed (streaming from a host, or `restore_command`), the primary's sender row that serves it (its sync state and replay lag: the `pg_stat_replication` row whose application name is the standby's `cluster_name` or instance name, or whose slot it uses), the slot and the WAL it keeps, and the role changes of 30 days. Two primaries in one cluster are said: a split, or a standby not read yet.

## Patroni

**Where.** By default `rolechange` asks `http://<the dsn's host>:8008` (Patroni's default REST port; a socket directory means this machine), and only while a session whose application name starts with `Patroni` is connected (Patroni's own connections, `Patroni heartbeat` and `Patroni restapi`): no such session, no request. A REST API on another port, behind TLS or asking for a client certificate is named in the instance's `patroni:` block, and is then read whether or not a Patroni session is seen:

```yaml
instances:
  - name: pg-a
    dsn: env:PG_A_DSN
    patroni:
      url: https://10.0.0.5:8009          # http or https, a host and a port
      ca_file: /etc/pgvigil/patroni-ca.pem  # the CA that signed restapi.certfile (empty: the system's roots)
      cert_file: /etc/pgvigil/client.pem    # a client certificate, for restapi.verify_client
      key_file: /etc/pgvigil/client.key
```

Patroni's GET endpoints take no password (restapi.authentication guards the unsafe ones), so the block holds none.

**What.** Each request is a GET of at most 1 MB with a 3-second limit and no redirect: `/cluster` (the scope, the pause flag, each member's name, role - leader, standby_leader, sync_standby, quorum_standby, replica -, state, host, port, timeline, lag, a pending restart and its reason), then every member's own `/patroni` at its `api_url` in parallel, for what `/cluster` does not carry: when the member last reached the DCS (`dcs_last_seen`, the member's clock), whether failsafe mode holds its leader up, its own view of the pause and of a pending restart, its Patroni version and the cluster's system identifier. A member whose own API does not answer keeps its `/cluster` row with the message. When `/cluster` fails (Patroni answers it from the DCS: with the DCS down it does not), the endpoint's own `/patroni` is read alone, so a DCS outage still shows: the member's DCS contact ageing, failsafe mode. A member that joined just before the DCS was lost reads failsafe false: it is outside the leader's failsafe list (GET /failsafe on the leader shows that list), which is Patroni's own state, not a fault of the read. A read that fails keeps its message (an https endpoint asked over http, the reverse, a certificate no CA in `ca_file` signed and a client certificate asked for or not accepted each say so) and takes the members off the page: Patroni's state is shown only while its endpoint answers.

**The checks** (check group `patroni`, the Summary's Replication column, the Server state tab and the fleet Replication page). A cluster read from several of its members is judged once, on one instance: among the fresh good reads of its scope and system identifier, a read of the whole cluster before a read of the endpoint's own member alone, then the lowest instance id (a reader that stops reading hands over after 120 s). Each age is the read's time less the first read that saw the condition, 10 s of slack letting the second read of the 1-minute schedule count as 1 minute:

| check | when | default |
| --- | --- | --- |
| patroni no leader | no member in role leader or standby_leader (a paused cluster elects none until resumed) | critical after 1 min (pgmonitor 5.3.0 PatroniNoLeader) |
| patroni member down | a member `/cluster` no longer lists (its Patroni stopped or its key expired in the DCS) and seen in the last 7 days, or listed in a state that does not serve (stopped, crashed, start failed, starting ...; running, streaming and in archive recovery serve) | critical after 1 min (pgmonitor PatroniPGIsRunning) |
| patroni paused | the cluster in maintenance mode: no failover, no restart of a stopped member | critical after 15 min (pgmonitor PatroniIsPaused) |
| patroni pending restart | a member whose settings wait for a restart (the reason: `max_connections 100 -> 120`) | warning after 30 min (pgmonitor PatroniPendingRestart) |
| patroni DCS not reached | a member's last DCS contact before the read (the newest read of the member by any instance of the cluster) | warning 5 min, critical 30 min (pgmonitor PatroniDCSLastSeen) |
| patroni API not answering | an instance's read failing for 2 reads in a row, where the `patroni:` block names the endpoint or it answered in the last 7 days | warning (pgvigil's own) |

A Patroni session with no answer at the default endpoint and no `patroni:` block is an info finding, `patroni API not found`. A member removed for good drops out of the checks 7 days after it was last seen.

## Streaming replication, slots and logical replication

The `replication` and `logical` collections feed these rules (migrations 0141 and 0150). Each reaches the instance's **Replication** tab and Findings; the fleet **Replication** page shows the links, the subscriptions and the publications. Their numbers are the thresholds below. On a managed platform (RDS, Aurora, Azure, Cloud SQL, AlloyDB) `receiver down`, `standby gone` and `replay paused` are left to the provider.

- **A link** is one sending server and one physical consumer of its WAL (a standby, `pg_receivewal`, Barman), named by its slot when the sender holds a physical one, else by its application name and address; a base backup's or `pg_rewind`'s sender, a logical slot's sender and a sender on a temporary slot are no link. A link is read from both of its sides and gets ONE finding, the first that holds of:
  - `receiver down` (on the standby): in recovery, `primary_conninfo` set and no WAL receiver for 2 reads in a row. A warning while replay still advances through `restore_command`; critical when it has not moved since the receiver went down, or for `restore_stall`.
  - `standby gone` (on the sending server): a physical link it sent to in the last 7 days with no sender for 2 reads in a row, while the standby's own read cannot speak (not monitored, stale or unreachable). Critical.
  - `replay paused` (on the standby): for 2 reads. Critical.
  - `standby lag`: the bytes not yet replayed against `standby_lag_bytes`, and the primary's `replay_lag` beyond the standby's `recovery_min_apply_delay` against `standby_replay_lag`, each held for 2 reads in a row.
- **Synchronous standbys**: `synchronous commits waiting` when fewer standbys are in `sync` or `quorum` state than `synchronous_standby_names` asks for - critical at once, a warning when `synchronous_commit` is off or local at the server; `synchronous standby absent` (warning) when a named standby is not connected and the number asked for still holds.
- **Slots**, one finding per slot: `slot invalidated` (critical: an invalidation reason, or `wal_status` lost); `slot WAL near its limit` (`safe_wal_size` under `slot_safe_wal`: a warning; `wal_status` unreserved: critical); `slot WAL growing` (the retained WAL up by `slot_growth` or more in the last full hour: a warning).
- **Logical replication** (the `logical` collection, which opens one connection per database that holds a subscription or a logical slot): one finding per subscription - apply errors, the worker down, the subscription disabled, sync errors, PostgreSQL 18's conflicts, a table's initial sync not finished (`table_sync_age`), no message from the publisher (`subscription_silent`).
- **An Aurora reader** is judged by `aurora_replica_status` alone: `Aurora replica lag` on the writer - or, when no monitored writer reads that replica, once on the lowest such reader - at the `standby_replay_lag` tiers; no receiver rule and no link row for a reader.
- **Across the members of one cluster** (one system identifier; managed platforms out), from the roles read every minute:
  - `two primaries`: critical on each of two primaries of one cluster when the second was promoted after the first's role began, both were read as primary 55 seconds or more after the collector saw the promotion, and the two are one topology (a link between them in the last 7 days, a common upstream that sent to both, or one `cluster` tag value on both). A promoted copy that never streamed, and a switchover whose old primary is stopped, raise nothing.
  - `cluster without a primary`: critical, one finding on the member last seen as primary (else the lowest instance id), when no member read in the last 3 minutes is primary, every such standby has had its receiver down for 2 reads or more or is cascaded (a standby of the cluster streams to it now), at least one is down, and a member was read as primary in the last 7 days. Never where a Patroni read covers a member (`patroni no leader` says it).
- **A standby's cancelled queries** (every platform): `standby queries cancelled`, a warning on a standby in recovery, one per database, when its recovery-conflict counters rose by `standby_conflicts` or more over 10 minutes.

**The trends.** The replication samples are also kept as hourly minimum, mean and maximum for 730 days (`replication_hourly`; its own age in `pgvigil.hours_retention`, not the purge's `-days`). A chart over 2 days or less whose stored samples reach back to its start reads the samples, any other the hours; an instance whose hours are not built yet reads the samples. `pgvigil purge` builds and heals the hours; a purge scheduled as SQL alone needs two more jobs for them, `SELECT pgvigil.replication_hourly_months(i) FROM pgvigil.replication_hourly_pending() i LIMIT 1` and `SELECT pgvigil.replication_hourly_heal_one(i) FROM pgvigil.replication_hourly_pending() i LIMIT 1`, apart so that the month partitions are committed before the build starts. If a write of the hours fails, the import still stores its samples: a `rollup failed` row is written to the collection log (collection `replication_hourly`, with the hours and the error; one an hour while the cause lasts, and a `rollup healed` row once they are rebuilt), and the Collector page and the alerts carry the warning `replication hours not rolled up` for that instance from that row until its `rollup healed` row. The hours are rebuilt by the instance's next import and by `pgvigil purge`.

## Crashes (the Memory Dump column)

A crash restart is read from the server log's crash events (the [log reader](logs.md): a backend killed by a signal, the restart of the others, the kernel's kill -9 of a backend): one row per restart, the first event with no other in the minute before it, its signal and message. The Summary cell is critical while the newest crash not acknowledged is within 48 hours, warning within 168 (the `crash` thresholds), and OK after. **Acknowledge** (the Server state tab, or the Summary's own) clears every crash up to then; a newer crash colours the cell again. Without the log reader nothing is seen: the cell then says OK with nothing read, the Logs tab says why.

## The statement store (the pg_stat_statements column)

PostgreSQL has no Query Store: the Summary's QS column is SQL Server's alone and reads n/a on a PostgreSQL instance. PostgreSQL's statement store has its own Summary column, `pg_stat_statements`, which reads n/a on SQL Server.

`pg_stat_statements` per instance: available, preloaded, created in a database read, `track`, `max`, the entries kept against `max`, the evictions (`pg_stat_statements_info.dealloc`, PostgreSQL 14 and later) in 24 hours and since the last reset, the last reset. The cell warns on evictions in 24 hours (raise `pg_stat_statements.max`) and on `track = none`; not available, not preloaded and not created are the extensions collection's findings.

## Uptime and amcheck age

**Uptime**: critical under 12 hours since the postmaster's start, warning under 48 (DBA Dash's defaults), as thresholds. **amcheck age** (the Last Good Check DB column): per database, the newest clean run (status ok) of the `amcheck` collection (the README's table), critical when there is none or it is older than 14 days, warning past 7. It judges only instances where amcheck has run at all (the collection is opt-in); an instance with none has an info finding "amcheck never run".

## Thresholds

Every rule above takes its numbers from the thresholds store (the uptime and crash rows judge SQL Server instances too: one store for both engines, migrations 0113 and 0117; a SQL Server instance takes an instance row for uptime only, its crash threshold comes from the levels above it), set in the UI at four levels: the root (every instance), a tag (its instances; the first of an instance's tags in sort order that has a row), an instance, and a database (amcheck only). The nearest level wins; with none, the built-in default:

| key | unit | rule | default |
| --- | --- | --- | --- |
| `uptime` | hours | under | warning 48, critical 12 |
| `full_backup_age` | hours | over | warning 192, critical 360 |
| `backup_age` (any kind) | hours | over | not judged |
| `archive_age` | minutes | over | warning 60 (or the config file's `backups.archive_warn_minutes`) |
| `retention` (RDS / Aurora) | days | under | warning 7, critical 0 |
| `replay_delay` | minutes | over | warning 60, critical 240 |
| `amcheck_age` | days | over | warning 7, critical 14 |
| `crash` | hours | under | warning 168, critical 48 (DBA Dash's Memory Dump defaults, 0117) |
| `patroni_no_leader` | minutes | over | critical 1 |
| `patroni_member_down` | minutes | over | critical 1 |
| `patroni_paused` | minutes | over | critical 15 |
| `patroni_pending_restart` | minutes | over | warning 30 |
| `patroni_dcs_last_seen` | minutes | over | warning 5, critical 30 |
| `restore_stall` | minutes | over | critical 5 (a standby whose receiver is down and whose replay through `restore_command` has stopped) |
| `standby_lag_bytes` | MB | over | warning 50, critical 100 (WAL not yet replayed, 2 reads in a row) |
| `standby_replay_lag` | seconds | over | warning 30, critical 300 (the primary's `replay_lag` beyond `recovery_min_apply_delay`, 2 reads in a row; an Aurora reader's lag too) |
| `slot_safe_wal` | MB | under | warning 1024, or half of `max_slot_wal_keep_size` when that is smaller |
| `slot_growth` | MB | over | warning 1024 (a slot's retained WAL grown in the last full hour) |
| `subscription_silent` | minutes | over | warning 5 (no message from the publisher) |
| `table_sync_age` | minutes | over | warning 60 (a table's initial sync not finished) |
| `standby_conflicts` | count | over | warning 3 (recovery-conflict cancellations of one database in 10 minutes) |

A level may set a warning, a critical or both: a rule fires past whichever is set (a critical alone fires only past it); since 0117 an uptime or crash level may set neither (Enabled off: that level judges nothing). `archive_age` takes whole minutes from 1 (0022's rule keeps minutes as a whole number). A threshold set in the UI at any level wins over the config file's `archive_warn_minutes`. The Thresholds page (Configuration) sets the root, a tag, an instance or a database; the Base backups and Server state tabs set their instance's, and each database's amcheck threshold. A write needs the UI login and goes through the actions door's audit login (`pgvigil.import_pg_threshold`): an edit ends the level's row and writes its successor with who and when, **Inherit** ends it so the level above applies, and a refused value (a word, a critical on the wrong side of the warning, a key at a level it does not take) writes nothing and says why.

## Retention

Role changes and threshold rows are kept whole. Tools, backups, Patroni members and standby replay rows no longer present are dropped after the retention (`pgvigil purge`).

## Proven

`scripts/proof-pg-backups-roles.sh` on the lab box: a pgBackRest stanza's full and diff backups read with pgBackRest's own sizes and the WAL since; the tool off the host's PATH; a barman answer (a stand-in printing barman 3.20's JSON shape, a failed and a running backup without an end: barman itself is not run); an unreadable pgBackRest repository (status 99) keeping the backups (seeded); a streaming standby promoted (one promotion row, timed by its history file); a standby restored by pgBackRest and fed by `restore_command`; a SIGSEGV crash restart found once and acknowledged; the thresholds at each level with their refusals; the rules on seeded rows. Not proven: barman and barman-cloud themselves, the pages in a browser.

`scripts/proof-patroni.sh` on the lab box, a real cluster: Patroni 4.1.5 (PGDG's package) with three members on PostgreSQL 17 and one etcd 3.5: the three members read whole from the default endpoint; a pending restart and its reason, then gone after `patronictl restart`; the pause; a member's PostgreSQL stopped while paused (down on the second read); no leader (paused, the leader's container stopped), judged on another member after the hand-over; resumed and the old leader rejoined; etcd stopped (each member's own state: failsafe mode, the DCS contact ageing, the leader kept); the REST API moved to https on 8009, read with the CA and then with a client certificate, each wrong setting's message; the rules on seeded rows; the Go cases. Not proven: Consul, ZooKeeper and Kubernetes as the DCS, a standby cluster (standby_leader), the pages in a browser.
