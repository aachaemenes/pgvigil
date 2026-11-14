# Configuration: best practice (PostgreSQL)

The Configuration page of a PostgreSQL instance opens with a **Best practice** grid: one row for every setting a
rule covers (41 settings, 35 rules), the worst first. The colour sits on the value in use:

| colour | verdict | meaning |
|---|---|---|
| green | meets the rule | every rule of the setting that applies to this instance is met |
| yellow | deviates: warning / deviates: advice | a warning rule or an advice rule is broken |
| red | deviates: critical | a critical rule is broken (autovacuum off, track_counts off, zero_damaged_pages on) |
| grey | not for this platform | no rule of the setting is meant for this instance |

Columns: the setting; the value in use, marked `(default)` when nothing sets it; the value a broken rule suggests
(empty on a met rule); the verdict in words; what the rule guards against; where the rule applies.

- Values are `pg_settings.setting`: in the setting's base unit (ms, s, kB, MB, 8 kB pages), the unit the rules
  compare in.
- A rule applies by platform (`all`, `self-managed` = on-premises, `managed` = any cloud platform, `not aurora`,
  `replica`) and by version: `default_toast_compression` and `idle_session_timeout` arrived in PostgreSQL 14 and are
  grey on 13.
- A setting with two rules (`autovacuum_freeze_max_age`, the two `max_standby_*_delay`) shows the worst broken one.
- The rules are pg_gather's parameter recommendations and pgvigil's own; every broken rule is also a finding, with
  the same severity, on the Findings page and in the alerts.
- In the **Settings** grid below, a setting a rule covers carries the same colour on its value and the verdict in
  the `best practice` column; the Excel export carries both.

The grid needs repository migration 0099 (`pgvigil migrate`). A server whose repository is not migrated yet shows the
Settings grid alone.

Not there yet: a fleet pivot of the settings; the SQL Server Configuration page has no rule set yet (its day-one
checks are on the Checks page, `docs/sqlserver-checks.md`).

Proof: `scripts/proof-pg-bestpractice.sh`.

## Database options and setting overrides (PostgreSQL)

The **Database options** page of a PostgreSQL instance (under Configuration) has two grids in the same colours:
green where the value meets its rule, yellow where a warning or an advice rule is broken, red where a critical one
is, grey where it is not judged here or the version lacks it. Every coloured cell says its verdict in its title, and a
column of words in the same row says it too; the Excel export carries both.

**Databases**, one row per database:

| cell | green | yellow | red | grey |
|---|---|---|---|---|
| connection limit | no limit, or under 80 % in use | 80 % or more of `CONNECTION LIMIT` in use; a limit of 0 (only a superuser gets in) | reached: a new session of a login that is not a superuser is refused; an invalid database (an interrupted `DROP DATABASE`, `datconnlimit` -2) | connections not allowed; sessions not read in the last 10 minutes; under the limit on a read that folded its smallest sources (the count is then a floor) |
| allow connections | allowed | not allowed on a database that is not a template | | a template |
| encoding | UTF8 | another encoding (advice) | | template0 (`CREATE DATABASE ... TEMPLATE template0` takes any encoding) |
| collation version | the version recorded = the library's now | they differ: text indexes may be out of order (REINDEX, then `ALTER DATABASE ... REFRESH COLLATION VERSION`) | | before PostgreSQL 15; a locale without a version (C, POSIX, builtin); not read |
| data checksums (the cluster's) | on | off (a warning self-managed, advice on a managed platform) | | Aurora (its storage checks its pages) |
| xid age | `age(datfrozenxid)` under `autovacuum_freeze_max_age` | at or past it: the anti-wraparound vacuum is due | 1 billion or more | an invalid database (autovacuum skips it, so its age only grows) |

The sessions are the newest read of the `connections` collection (every minute; the collector's own session left out;
a server with more than 500 connection sources folds the smallest into `(other sources)`, so a database's count there
is a floor). A superuser is not held to the limit. The other cells come from the `databases`, `versions` and `instance`
collections; nothing is read twice.

**Setting overrides**, one row per `ALTER DATABASE ... SET`, `ALTER ROLE ... SET`, `ALTER ROLE ... IN DATABASE ... SET`
and `ALTER ROLE ALL SET` (the `dbsettings` collection, hourly, from `pg_db_role_setting`, which every login may read).
`ALTER ROLE ALL IN DATABASE ... SET` is stored by PostgreSQL as `ALTER DATABASE ... SET` and is shown so. Each override is
held to the same rule as the server's own value (the Best practice grid above): an override that breaks a rule is
yellow or red even where the server's value is green, and the server's value stands beside it in its own colour.

- PostgreSQL keeps an override's text as it was typed (`256MB`, `ALL`, `true`). The collector reads it into the
  setting's base unit as `pg_settings.setting` shows it (262144 kB, `all`, `on`; `1.3GB` is 1362944 kB, rounded to
  whole MB first as PostgreSQL rounds it), the unit the rules compare in; the grid shows both. A value it cannot read
  (masked, a placeholder of an extension not loaded, a string: PostgreSQL rewrites some, such as `TimeZone`) is grey.
  A setting keeps PostgreSQL's own spelling (`TimeZone`, `DateStyle`).
- A setting a session cannot set cannot be overridden: `ALTER DATABASE ... SET autovacuum = off` is refused by the
  server ('cannot be changed now'). The overrides that can break a critical rule are `track_counts = off` and
  `zero_damaged_pages = on`; most others are warnings or advice (`synchronous_commit = off`, a `work_mem` over 96 MB,
  `log_statement = all`, `jit = on`, ...).
- A setting the Best practice grid has no rule for is grey 'no rule' as an override too: a role's
  `statement_timeout = 0` is grey, since no rule covers `statement_timeout` (a global timeout is set from
  measurement, never by a default rule).
- `ALTER ROLE ALL SET` and an override of the database the collector connects to are also seen by the `instance`
  collection as server-level values (`pg_settings` sources `global` and `database`), so the Best practice grid can
  show the same value. On such a row the server's value is shown uncoloured, marked as read under the override.
- Values that can carry a credential are masked as the server's are.

**Findings.** Every override that breaks a rule is a finding with the rule's severity. The database cells raise
findings where no other finding covers them: the connection limit reached (critical) or near (warning), connections
not allowed (warning), an encoding other than UTF8 (info). The collation, checksums and xid age cells have theirs
already (`collation version`, `data_checksums`, `database xid age`).

**The fleet.** The root page **PostgreSQL options** (under Configuration) counts per instance the databases at their
connection limit (or invalid) and near it (or closed by a limit of 0), not allowing connections, not UTF8, with a collation mismatch, without checksums, past
the freeze age, and the overrides that break a rule; each count opens the instance's page filtered to them (the twin
of the SQL Server options page).

API: `GET /api/pg/dboptions?instance=<id>[&part=state|databases|overrides|overrides_read|findings]`,
`GET /api/pg/dboptions/fleet` (`risks`). Repository migration 0104 (`pgvigil migrate`).

Proof: `scripts/proof-pg-dboptions.sh` (PostgreSQL 13, 16 and 18).

## Instances added in the page

Admin > Instances adds, tests, edits, disables and removes an instance, and syncs sources into proposals that a click
approves or ignores: a SQL Server Central Management Server (its login needs msdb's `ServerGroupReaderRole`), a DBA Dash
repository named under `dbadash:`, a server list file, a `pg_service.conf` and a CSV. A server gone from its source is
marked gone, never removed. The instances of `pgvigil.yaml` are shown read-only. The collector takes a change within
15 seconds, without a restart. A disabled instance is collected no more and leaves the fleet's stale and failing
checks until it is enabled. An instance enabled, or added (again), while its server is down is reported at its first
read: 'server unreachable' and a failing collection, as for any instance that cannot be reached; so is an instance of `pgvigil.yaml` whose server has never answered (its row is made at that first read, with the file's engine, platform and tags). Until a read of an added instance connects, Admin > Servers, the fleet list, its Summary card and `pgvigil report` say 'not read yet (added <time>)': beside its name on the fleet list (which shows no last-seen time), in place of a last-seen time elsewhere; its 'history from' (the Diff page) is that first read. Removing a page instance no read ever reached (and `pgvigil import dbadash` never filled) removes its row too, so the name can be added again with the other engine; an instance read once, or imported, keeps its row and its history. A network (UNC) path and a `.pgpass`-shaped line are refused as a server list or CSV, and on
Linux and macOS so is a file only its owner may read (a server list is 0644), so no credential file is read into the
page.

Who may change them: every UI login can add, change, disable and remove instances and sources, and these writes need
the actions door's audit login, as acknowledgements do. Give UI logins to the people who may change what is monitored.

One collector per repository collects the page's instances: the holder of the repository's page lease, a row it
renews every 15 seconds (it works through a transaction-mode pooler; every time in it is the repository's clock,
never a host's). The lease expires 45 seconds (three renewals) after its last renewal. A second `pgvigil run` on the
same repository (another host with its own file's instances) collects its file's instances only, logs once that
the page's instances are not its own, and takes them over within 30 seconds of a clean stop of the first one, or
within about 75 seconds of the first one's last renewal when its host is lost. The lease is fenced: each take-over
bumps its generation and names the new holder, so a holder that comes back after a network partition finds itself
superseded at its next renewal and stops starting collections of the page's instances within 30 seconds; a holder
that cannot reach the repository lets go of them itself after two failed renewals (30 seconds), before another can
take the lease.

A `custom:` check may name an instance or a tag only the page holds: the file's instances no longer decide, so a name
or tag that matches nothing in the file is a warning at start, and the collector warns again when a check matches no
instance of the file or the page.

`pgvigil run` starts with no instance in the file (the page may hold them all); `pgvigil collect -once` reads the
file's instances only. A repository `dsn` that resolves to nothing (the installer's env file not filled in yet) stops
`run` and `serve` with exit 3, which the service leaves stopped.

Credentials go to files beside the configuration file (`instances/` and `sources/`): on Linux 0600 files in 0700
folders; on Windows a DPAPI machine-scope blob in a folder whose access list is SYSTEM, Administrators and the service
account. The repository keeps only each file's name, so `pgvigil serve` and `pgvigil run` must share the configuration
folder and run as one account: the account that wrote a credential is the one that can read it (on Windows the
folder's access list names SYSTEM, Administrators and that account's own SID; on Linux the files are its own). Every
change is audited (the page's Changes grid).

A SQL Server added here signs in by `sql` (a login and its password), `windows` (the service's own account on Windows;
off Windows Kerberos, the login the principal and the driver options naming the keytab or credential cache), `entra`
(an Entra service principal and its secret) or `entra-identity` (the host's Azure managed identity, no secret): which
works where is [SQL Server in the cloud](sqlserver-cloud.md#signing-in-without-a-stored-password). Entra and Kerberos
are not proven against a live server in this release.

### Community tools and custom reports on a page instance

`pgvigil serve` runs Community tools and custom reports on an instance of `pgvigil.yaml` through its read login. On
an instance added in Admin > Instances it does so only when `pgvigil.yaml` turns it on, off by default on every
install:

```yaml
doors:
  page_instance_reads: on   # Community tools and custom reports on the instances of Admin > Instances
```

The switch is in the file only, never on the page; while it is off a page instance's tools and reports say 'off on
this install: doors.page_instance_reads in pgvigil.yaml turns on Community tools and custom reports for instances
added in Admin > Instances' - unless its row has a refusal of its own (disabled, left out of the list, this server's
own identity, an option the door does not open), which the switch would not lift: those words come first. (A later
release lists the switch on a Site settings page, one switch per door in one place, where this file's 'off' still
wins.)

With it on, a page instance's door is its stored read login alone, and it opens only for a credential typed into
the form, never for one that signs in as `pgvigil serve` itself:

- SQL Server: auth `sql` and `entra` (a service principal and its secret); `windows` and `entra-identity` are refused,
  being the service's own identity. PostgreSQL: auth `password`; `pgpass` (the service account's own `.pgpass`) is
  refused.
- The driver options it opens with, each for one reason. SQL Server (go-mssqldb's names, without case): `database`,
  `encrypt`, `trustservercertificate`, `hostnameincertificate`, `tlsmin` (TLS on the wire and the certificate's
  check), `connection timeout`, `dial timeout`, `keepalive` (seconds), `applicationintent` (an availability group's
  read routing), `multisubnetfailover` (every address of one listener), `packet size`. PostgreSQL (pgx's keywords):
  `sslmode`, `sslrootcert=system` (the operating system's CA store), `sslsni`, `sslnegotiation`, `channel_binding`
  (TLS on the wire), `connect_timeout` (seconds), `target_session_attrs` (which server of a list). Every other option
  refuses the door: a file on serve's host (`certificate`, `passfile`, `servicefile`, `sslcert`, `sslkey`, a
  `sslrootcert` path), serve's Kerberos or Entra identity (`authenticator`, `fedauth` other than a service
  principal, `serverspn`, `krbsrvname`, `gssencmode`, `krb5-*`), a second server (`failoverpartner`), a startup
  setting (PostgreSQL's `options` and any runtime parameter) and anything else.
- Both are checked twice: on the row's sign-in and options for the words, and on the stored credential's own
  connection string each time the door is built, which is the check that holds - a hand-edited row or credential file
  cannot widen it, and a key neither check knows refuses the door. Serve's environment lending a client certificate
  or a Kerberos name (`PGSSLCERT`, `PGSSLKEY`, `PGKRBSRVNAME`) refuses it too.

Each refusal is in words on the page and in the run's audit row: in neither `pgvigil.yaml` nor Admin > Instances;
disabled in Admin > Instances; left out of the list (the reason); off on this install; this server's own identity; an
authentication or a driver option the door does not open; a driver option that names a file on this server's host;
this server's own socket; a credential stored as a URL rather than the keyword form pgvigil writes; a credential the
driver reads differently from the door's check; a credential not readable on this host (stored by another host's
`pgvigil serve`: serve here as the account, and with the configuration folder, that stored it - storing it again with
Edit on this server moves it to this host, where a collector on the other host then reads nothing); the list of
Admin > Instances not read yet on this server (its log names why a read failed). A custom report's page opened on an
instance that is disabled or removed (a mailed page names its instance) keeps it as the target and runs on no other in
its place: its run says why, and a mailed turn carries those words in the mail. EXPLAIN, the index advisor and every
action (cancel, terminate, kill, a job's start and stop) stay on the instances of `pgvigil.yaml`: on a page instance -
one with a door or refused one - they say so, and the actions log keeps no door column because a page instance runs no
action.

A change in Admin > Instances reaches this server's doors at once (its write waits up to 5 seconds for them, then
answers that the change reaches Community tools and custom reports within 15 seconds) and another `pgvigil serve` on
the same repository within 15 seconds. On an install whose page doors are off the answer says nothing of them. A run
that reached a door names it in its audit row (`custom_report_log`): `file` (an instance of `pgvigil.yaml`), `page`
(Admin > Instances') or `store` (the repository); one refused for want of a door names none. Each carries
`door_generation`, the repository's inventory generation its door set was read from. `pgvigil serve` keeps every open
page door's credential in memory while it runs. While a serve cannot read the repository, its last doors stay as they
were: a disable written through another serve reaches it once its reads work again.
