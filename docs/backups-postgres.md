# PostgreSQL: base backups, role changes and server state

Two collections and two tabs per instance, two fleet pages, and five Summary columns: the PostgreSQL side of DBA Dash's backups, log shipping, role-change, crash, Query Store, uptime and last-good-check cells. Nothing is installed on the monitored server and nothing is written there.

| collection | every | reads | needs |
| --- | --- | --- | --- |
| `backup_tools` | 15 min | which backup tool the server's `archive_command` and `restore_command` name; with `backups: read_tools: true`, that tool's own JSON, run on the collector's host; a standby's replay | any login (every role that logs in reads both commands with SHOW); the tool on the collector's host |
| `backup_dest` | 15 min | where the WAL, the base backups and the restore go, built from `archive_command`, `archive_library` (with `basic_archive.archive_directory`) and `restore_command`; with `backups: read_tools: true`, the tool's own configuration on the collector's host (pgBackRest's files and `PGBACKREST_REPOn_*`, `barman show-servers`) | any login; for the tool read, the tool and read access to its configuration on the collector's host |
| `rolechange` | 1 min | `pg_is_in_recovery()`, the timeline, `pg_control_system()`'s system identifier, the postmaster's start, the newest timeline history file in `pg_wal`; Patroni's `/cluster` where Patroni is seen | pg_monitor for `pg_control_*` and `pg_ls_waldir()` (without it those parts stay empty) |

`backup_tools` does not run on RDS, Aurora, Azure, Cloud SQL or AlloyDB: those platforms take their own backups (the `backups` collection in the README's table reads RDS and Aurora's snapshots and restore window). `rolechange` runs everywhere.

## The tool read is opt-in

Running a backup tool and reading its configuration happen on the collector's host as the collector's account, and a tool's configuration can hold a repository's keys and passphrase. So both are off until an instance asks for them in `pgvigil.yaml`:

```yaml
instances:
  - name: pg1
    backups:
      read_tools: true
```

Off, the Base backups tab names the tool the server uses and says `not read: the tool read is off for this instance`, its base backups are not judged (an info finding, `base backups not read`, and a grey Summary cell, never green), and 'Where the backups go' shows only what the server's own settings name. A tool's failure is said in fixed words (an exit code, no answer in 60 s, could not run, not the JSON expected, not in the answer): its stderr is never stored or logged.

## Where the backups go

The collection `backup_dest` reads the archiver's settings and names, per instance, **base backups to**, **WAL to** and **restore from**, each with where it was read. No command text is stored: a destination is built from pieces that each pass a plain pattern (a scheme, a host, a port, a path, a bucket), a URL keeps `scheme://host[:port]/path` only (its `user:password@` and its query go), and anything else is `not known`, never guessed. The commands are cut as a shell cuts a plain line (the lexer is written in `internal/collect/backup_dest.go`'s header): a variable taints its word, a command substitution its whole segment, a newline or an unclosed quote the whole command.

| the server's setting names | what is shown |
| --- | --- |
| `pgbackrest --stanza=S archive-push` | pgBackRest stanza S, its inline repository options; with read_tools, each `repoN` as the collector host's pgBackRest configuration names it (`[S:archive-push]` over `[S]` over `[global:archive-push]` over `[global]`, an indexed name over pgBackRest's deprecated un-indexed one (`repo-path`, `repo-type`, `repo-s3-bucket`, `retention-full` ... read as repo1's), `PGBACKREST_REPOn_*` over the file, the server's own inline options over all; a `repoN-host` = that host's configuration, not read; a stanza the configuration never names and no repository option at all: 'stanza S is not in the collector host's configuration', no default shown); base backups go to the same repository. The configuration rows follow the archiver: a stanza a leftover `archive_command` names is not read while `archive_mode` is off or `archive_library` is set, and `restore_command`'s stanza gives 'restore from' rows only |
| `barman-wal-archive [options] HOST SERVER` | barman server SERVER on HOST; with read_tools, its `basebackups_directory` and `wals_directory` from `barman show-servers` (only those keys, the method and the retention: never its conninfo) |
| `barman-cloud-wal-archive [options] URL SERVER` | the URL and the endpoint |
| `WALG_S3_PREFIX=... wal-g wal-push` (or `WALG_FILE_PREFIX`, wal-e's `--s3-prefix`) | the prefix; an `envdir` or a `--config` file is named as where it lives, else 'in the server's environment' |
| `aws s3 cp`, `gsutil cp`, `az storage blob upload`, `azcopy`, `s3cmd put`, `rclone copy`, `mc cp`, `curl -T` | the bucket, container or remote and the path |
| `rsync` or `scp` to `host:/path` or `host::module` (into `.../SERVER/incoming` = barman) | the host and the directory |
| `cp`, `copy`, `install`, `dd of=`, a compressor with `> file` | the directory of the file it writes |
| `archive_library = 'basic_archive'` | `basic_archive.archive_directory`. On PostgreSQL 15 a library wins over `archive_command`; from 16, with both set the archiver refuses to run ('both archive_command and archive_library set') and the line says 'WAL is not archived' |
| a script (`/path/x.sh %p %f`) | 'a script (x.sh): the destination is inside it - not known' |
| `archive_mode = off`, no command | WAL is not archived |
| `true`, `:`, `cp %p /dev/null` with archive_mode on | WAL is discarded (a warning) |

A password, a key or a token on the command line (`PGPASSWORD=`, `--password=`, `sshpass -p`, `curl -u user:pass`, a URL's `user:password@` or a signature, an inline rclone remote's secret) is never kept: it raises the warning `a credential is written in the archiver's command` - both settings are readable by every role that logs in. A key's id, type, name or file, a password file (`--password-file`), `StrictHostKeyChecking` and the ssh `*Authentication` options, barman-cloud's `--credential` (a kind: azure-cli, managed-identity, default), `AWS_SHARED_CREDENTIALS_FILE` / `GOOGLE_APPLICATION_CREDENTIALS` (paths) and barman's `--sse-customer-key file://...` are not credentials. A redirect is never a destination for `cp`, `mv`, `install` or `copy` (`2>/dev/null`, `>> /var/log/archive.log` are their own messages); for a compressor, `cat` or `dd` only the output's redirect is. `|| true` and `; exit $?` after the archiving program are the shell's own ending, not 'WAL is discarded'; `exit 1` fails the archiver (it retries, and the WAL waits). An `--endpoint-url` pgvigil cannot read makes the line 'not known: the endpoint', never Amazon's bucket of that name. An entry a person writes is checked with the same rule before it is stored. A standby with `archive_mode = on` (not `always`) does not archive and says so; a `restore_command` on a primary is 'set, not in use'. On RDS and Aurora the line is the service's (retention, the restorable window, the backup window); Azure, Cloud SQL and AlloyDB 'kept by the service (not read by pgvigil)'.

Where nothing can be read (a `pg_basebackup` from cron leaves no trace in the server), a person enters it with **Edit**: never a credential (refused), at most 500 characters, shown beside a value read and never over it, with who and when, its history kept.

## Base backups (pgBackRest, barman)

pgvigil finds the tool from the server's own settings and keeps only its name and the stanza or server name, never the command (it can carry a credential):

| the command names | the tool | the read, on the collector's host |
| --- | --- | --- |
| `pgbackrest ... --stanza=<s> archive-push` (or `archive-get` in `restore_command`) | pgBackRest, stanza `<s>` | `pgbackrest --output=json --stanza=<s> info` |
| `barman-wal-archive [options] <host> <server>`, `barman-wal-restore ...`, or an `rsync` into `.../<server>/incoming/` | barman, server `<server>` | `barman -f json list-backups <server>` |
| `barman-cloud-wal-archive [options] <url> <server>` | barman-cloud | `barman-cloud-backup-list -f json <url> <server>` |

The binary comes from the collector's `PATH`, runs without a shell for at most 60 seconds, and inherits the collector's environment. A stanza or server name must start with a letter, a digit or `_` (never an option) and is passed after `--`. Of barman-cloud's options only `--cloud-provider` (aws-s3, azure-blob-storage or google-cloud-storage) and `--endpoint-url` (a checked URL) are passed on; the destination URL must be a plain scheme, host, port and path. The listing uses the collector host's own cloud credentials on the bucket the server's command names. **The collector's host needs the tool and read access to the repository:** for pgBackRest a `pgbackrest.conf` with the repository (`repo1-path`, or the object store and its credentials) and the stanza; `pgbackrest info` reads the repository only, never the database. For barman, run the collector on the barman server or give it a barman client configuration that sees the catalog. A tool the server names but the host lacks is a state 'no binary' and an info finding "pgbackrest not on the collector host", never a red cell. A `--config` path inside the server's command is not carried over: the collector's tool uses its own default configuration (or `PGBACKREST_CONFIG` in the collector's environment), and the configuration read does the same - the read's message names the server's path. With `read_tools` off, the Summary's Backup FULL cell of an instance whose server names a tool is grey ('not read'), never green.

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

**Patroni.** When a session whose application name starts with `Patroni` is connected (Patroni's own connection), `rolechange` asks `http://<the dsn's host>:8008/cluster` (Patroni's default REST port; a socket directory means this machine) with a 3-second limit and keeps each member: name, role (leader, replica, sync_standby, standby_leader), state, host, port, timeline and lag. No such session means no request. A REST API on another port or behind TLS is not read. A read that fails (no answer, not a cluster) keeps the read row with its message and takes the members away: Patroni's state is shown only while its endpoint answers.

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

A level may set a warning, a critical or both: a rule fires past whichever is set (a critical alone fires only past it); since 0117 an uptime or crash level may set neither (Enabled off: that level judges nothing). `archive_age` takes whole minutes from 1 (0022's rule keeps minutes as a whole number). A threshold set in the UI at any level wins over the config file's `archive_warn_minutes`. The Thresholds page (Configuration) sets the root, a tag, an instance or a database; the Base backups and Server state tabs set their instance's, and each database's amcheck threshold. A write needs the UI login and goes through the actions door's audit login (`pgvigil.import_pg_threshold`): an edit ends the level's row and writes its successor with who and when, **Inherit** ends it so the level above applies, and a refused value (a word, a critical on the wrong side of the warning, a key at a level it does not take) writes nothing and says why.

## Retention

Role changes and threshold rows are kept whole. Tools, backups, Patroni members and standby replay rows no longer present are dropped after the retention (`pgvigil purge`).

## Proven

`scripts/proof-pg-backups-roles.sh` on the lab box: a pgBackRest stanza's full and diff backups read with pgBackRest's own sizes and the WAL since; the tool off the host's PATH; a barman answer (a stand-in printing barman 3.20's JSON shape, a failed and a running backup without an end: barman itself is not run); an unreadable pgBackRest repository (status 99) keeping the backups (seeded); a streaming standby promoted (one promotion row, timed by its history file); a standby restored by pgBackRest and fed by `restore_command`; a SIGSEGV crash restart found once and acknowledged; the thresholds at each level with their refusals; Patroni's `/cluster` from a stand-in on port 8008; the rules on seeded rows. Not proven: barman and barman-cloud themselves, a real Patroni cluster, the pages in a browser.
