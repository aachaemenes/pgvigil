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
  show the same value. On such a row the server's value is shown N/A (grey), marked as read under the override.
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

## The request queue (cq, actions)

`cq:` (a collector's `enabled`, `workers`, `result_keep`: read or 7d) and `actions: via:` (serve's `direct` or `queue`) send the
community tools through the repository, so serve and the collector can run on different machines; both are off by
default. An instance's `community_allow` (all, none or tool names) and `jobs_allow` (names, `*`, `-name`) are DBA Dash's
allow-lists. What each key opens, and what serve stops doing in queue mode: [queue.md](queue.md).

## The custom reports' login on the store (reports_dsn)

```yaml
reports_dsn: env:PGVIGIL_REPORTS_DSN   # a login IN ROLE pgvigil_reader alone, on the repository the repository dsn names
```

A custom report on the store (pgvigil's own repository) runs the DBA's own SQL, so it runs only as this login, never
as serve's own repository login (which holds `pgvigil_auth` and reads the UI's password hashes). `pgvigil roles`
prints it (`pgvigil_reports`). Each run checks it on its session user inside the run's own transaction: a superuser,
a member of any role but `pgvigil_reader`, a login that may read the hashes, or one that reaches another server or
database than the repository dsn's is refused, with words. Without the key (or when it resolves to nothing) a report on
the store is refused and the page and a mailed report say why; `serve` starts anyway, with one WARN. Reports on
instances need nothing here. The rules and the words: [customreports.md](customreports.md).

## The agent door (agents)

```yaml
agents:
  enabled: true     # default false: the Investigate button, the Ask box and the Investigations page are not drawn
```

Off (the default), serve's list `GET /api/investigations` answers 200 with `"enabled": false` and "agents.enabled is off:
...", one request (`?id=`) and the writes answer 404 with the same words, and the pages draw nothing of the door. On, a person may ask for an investigation of a finding or ask a question; the site's own agent
claims it through `pgvigil mcp` on a login IN ROLE `pgvigil_reader, pgvigil_investigator`, and an answered question's SELECT
runs on Run as `reports_dsn` (without that key Run is off, with the words). pgvigil holds no agent, no model and no key:
[agents.md](agents.md).

## The Daily checks mail (reports.daily_checks)

```yaml
reports:
  daily_checks:
    enabled: true               # required when the block is there; false = off, and the page says the file turned it off
    at: "07:00"                 # HH:MM
    tz: America/Los_Angeles     # an IANA name, or UTC
    to: [dba@example.org]       # 1 to 50 addresses
    as: alice                   # the UI user the page is drawn as
    channel: mail               # an smtp channel of the alerts: block
```

Off by default: no block, no mail (the Daily checks page's own **Mail daily...** then decides). With `enabled: true`
every key is required, and a key the block does not know or writes twice, a value of the wrong kind (`to:` is a list,
`enabled:` is true or false), or a block without `enabled`, stops `pgvigil serve` at its start with the key's name
and its line in the file; `pgvigil report`'s configuration check line says the same. There is no separate check
command: `pgvigil serve` and `pgvigil report` are where the block is checked. An alias (`to: *dba_list`) and a merge
key read as what they stand for. `pgvigil serve` reads the block once, at its start. What it keeps, who wins between the
file and the page, and what the mail holds: `docs/reportmail.md`, *The Daily checks mail*. In a support report
(`pgvigil report`) the switch, the hour and the zone are shown; the addresses, the user and the channel are masked.

## Saved views: who writes shared ones (views.shared_editors)

```yaml
views:
  shared_editors: [ann, bob]   # read and ignored since the roles: a shared view needs the admin role
```

Every signed-in user saves personal views (a page's state, a dashboard) and reads the shared ones; a shared view is
created, changed, deleted or made a page's shared default only by a user of the admin role (`docs/roles.md`). A personal view is its owner's
alone, and removing a user (`pgvigil user remove`) deletes that user's personal views; a shared one stays. Views are
saved through the actions door's audit login, so saving is off under `-no-login` and on `pgvigil demo -serve`; every
attempt that reaches the store is kept in `ui_view_log` (a request serve refuses before it - no X-Pgvigil header, a
body over 256 KB - is not). These rules are serve's: like alert rules, the store's write functions
(`import_view_save`, `import_view_delete`) are the collector's door, so a login of the collector's role can write any
view as any user - keep the collector's login on the hosts you trust. `views.shared_editors`, the list
that decided this before the roles, is read and ignored: a viewer or an operator named there is refused like any
other, and the key goes in a later release.

## Instances added in the page

Admin > Instances adds, tests, edits, disables and removes an instance, and syncs sources into proposals that a click
approves or ignores: a SQL Server Central Management Server (its login needs msdb's `ServerGroupReaderRole`), a DBA Dash
repository named under `dbadash:`, a server list file, a `pg_service.conf` and a CSV. A server gone from its source is
marked gone, never removed. The instances of `pgvigil.yaml` are shown read-only. An instance added here has its own
schedules and statement-text policy in its Settings ([instance-settings.md](instance-settings.md)). The collector takes a change within
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

### Cloud blocks on a page instance

An instance of `pgvigil.yaml` reads its cloud side through its `aws:` block (CloudWatch IO and logs, Performance
Insights, Aurora Serverless) or its `azure:` block (an Azure SQL Database's failover groups). An instance added in
Admin > Instances, or approved from a discovery source, can carry the same blocks (the form's collapsed **Cloud**
fieldset; an approved proposal gets its block from the cloud's own identity of the server) - but its reads run under
the **collector host's own cloud identity**, while a page instance may be added by any signed-in user. So the file
turns them on, off by default on every install:

```yaml
doors:
  page_cloud_blocks: on          # let the instances of Admin > Instances carry an aws: or azure: block
  page_aws_profiles: [prod-read] # the AWS profiles such a block may name (empty = none: the host's default chain)
  discovery_auto_add: on         # a cloud discovery source may add the servers it finds by itself (its own switch too)
```

- **Off** (the default): every page block is kept in the repository but not used - the collector logs 'a page
  instance's cloud block is not used' with the switch's words, the page shows them on the row, and the instance keeps
  collecting everything else. The form's Cloud fieldset is off with the same words.
- **The block's keys**: `aws` region, cluster, db_instance (log_group and dms stay the file's); `azure` subscription,
  resource_group, server, cloud. `aws:` on a PostgreSQL instance only (on SQL Server it waits for its own reads),
  `azure:` on a SQL Server instance of platform `azuresqldb` only. No profile is typed on the page; an approved
  proposal takes its source's profile only when `page_aws_profiles` lists it.
- **The name match**: the block's target must be the instance's own host by name - an RDS instance endpoint
  `<db_instance>.<x>.<region>.rds.amazonaws.com`, or a cluster's writer or reader endpoint
  `<cluster>.cluster-[ro-]<x>.<region>.rds.amazonaws.com` (in the China regions `.amazonaws.com.cn`, either
  `<region>.rds.` or `rds.<region>.`: not proven, no China account), or `<server>.database.windows.net`
  (`.database.usgovcloudapi.net` with `cloud: usgov`, `.database.chinacloudapi.cn` with `cloud: china`). An instance
  endpoint names the block's `db_instance` and a cluster endpoint its `cluster`; the other name, when given, is the
  provider's to confirm (below). A custom cluster endpoint (`.cluster-custom-`), a CNAME, a private DNS name
  (privatelink) or an address is refused with both names: give such an instance its block in `pgvigil.yaml`, where
  the file's author answers for it.
- **The provider's check (aws:)**: an RDS name is unique only inside one account, so before an `aws:` block's first
  read the collector asks RDS - in the region and with the profile the block reads with - for the DB instance's
  `Endpoint.Address` and the cluster's writer and reader endpoints, and keeps the block only when the instance's host
  is one of them; a block naming both must name an instance of that cluster. A refused block is logged once ('a page
  instance's aws: block is not used', with both names) and each collection that needs it says so as its skip; the
  instance keeps collecting. An AWS error (no credentials, `AccessDenied`) refuses the block too, and it is asked
  again after 5 minutes; a verdict is kept until the block or the host changes (or the collector restarts). The
  rights are the reads' own: `rds:DescribeDBInstances`, and `rds:DescribeDBClusters` for a block naming a cluster.
- **A resource group** is checked as ASCII letters, digits and `-_.()` on the page and in the repository alike; a
  group named with other letters takes its block in `pgvigil.yaml`.
- **A profile**: an approved instance's block keeps its source's profile when an edit on the page leaves the region
  as it was (the form shows it, and has no profile field); an edit to another region, or Clear, removes it.
- A block set, changed or cleared restarts the instance's loops within the collector's next read of the list (15 s).
  Its Clear is its own control; an emptied fieldset clears nothing.
- Not in this release: a `gcp:` block on a page instance (its credentials file is a path on the host).

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

### Prometheus endpoint

```yaml
doors:
  prometheus_metrics: on    # GET /metrics for Prometheus (docs/prometheus.md)
metrics:
  token: file:/etc/pgvigil/metrics.token
```

`doors.prometheus_metrics` turns on `GET /metrics` (docs/prometheus.md): every active instance's newest figures in the
Prometheus text format, read with a signed-in session or `metrics.token` (`file:/path` or `env:NAME`, 32 bytes at
least); it opens server names, engines, platforms, versions and every figure to whoever reads that Prometheus. Its
`metrics:` block holds `token`, `cache_seconds`, `databases`, `max_databases`, `include_databases` and `tags`.


### From the command line (pgvigil instance)

On serve's host, after `pgvigil install`, the page's add, list and disable run headless:

```
pgvigil instance add -config <pgvigil.yaml> -name pg7 -engine postgres -dsn-stdin [-platform auto] [-tag prod]... [-no-test] < the connection string
pgvigil instance list -config <pgvigil.yaml>
pgvigil instance disable -config <pgvigil.yaml> -name pg7
```

`add` takes the page's own path: the connection string on stdin (never a flag; at a terminal it is not shown) read
into the page's fields - the sign-ins the page takes, an az or Kerberos one stays in `pgvigil.yaml` - the page's
connection test first (a refusal writes nothing; `-no-test` skips it), the credential sealed in `instances/` for the
installed service's account (never for the administrator running the command: serve must keep reading it), and the
page's repository function with the configuration's repository login, audited as `cli:<the account>`. `list` shows
the file's and the page's instances with each one's last collection (`never` before the first). Where no pgvigil
service is installed `add` is refused: the service's account owns the page's credentials.

## SQL Server schema history (mssql_schema)

A SQL Server instance's `mssql_schema: {databases: [...]}` turns the schema history on for those databases (`*` every
user database, a name that one, `-name` leaves one out); without it the collection `mssql_schema` is off. What it
reads and keeps, and the rights it needs: [schema snapshots, SQL Server](schema.md#sql-server-mssql_schema).

## The repository's own sessions run without jit

Every `pgvigil migrate` (and so `install -upgrade` and `demo`) sets `jit = off` on the repository database
(`ALTER DATABASE <the repository> SET jit = off`, logged as one INFO line) when the database has no jit setting of
its own and its login owns that database or is a superuser. Every new session on that database then plans without
jit: Grafana's login, psql, a BI tool and pgvigil's own processes. The reason: the findings view and the heavy
functions cross the server's `jit_above_cost` even on a near-empty repository, and with jit on each such read spends
its time compiling with LLVM (a 55 s read against 0.5 s without jit was measured on PostgreSQL 18). `pgvigil serve`
already starts its sessions with `jit = off`, and the alert sender's functions carry their own `SET jit = off`. A jit
setting the database already has is the site's own choice and is left alone: off in any spelling PostgreSQL takes is
nothing to do, any other value is kept and named in an INFO line on each migrate. When the login does not own the
database, migrate logs one WARN with the statement for the database's owner to run once (none where no session would
compile anyway: the server's own jit off, or no LLVM module). A login role's own setting
(`ALTER ROLE <login> SET jit = on`) or a session's startup parameter outranks the database's: that is how an
application that shares the repository database keeps jit on for its own login. The setting reaches new sessions
only: a connection already open keeps its jit until it reconnects, so restart Grafana (or reconnect its data source)
and any pooler's server connections after the migrate. Connections to a monitored instance are unchanged: that
server's jit is its owner's choice.

## The Parquet export (export:)

Absent = off. [parquet-export.md](parquet-export.md) is the whole page; these are the keys.

```yaml
export:
  name: prod-repo                 # required: the folder under the destination and part of every file name
                                  #   (lower case, a letter first, a letter or digit last, no '__', at most 31)
  dsn: env:PGVIGIL_EXPORT_DSN     # required: the export's login, IN ROLE pgvigil_exporter (or pgvigil_reader) alone;
                                  #   env:NAME or file:/path - a connection string written here is refused
  state_dir: /var/lib/pgvigil/export   # required: the lock and the files being built
  destination:                    # required: one of
    type: folder                  #   folder:     path
    path: /srv/pgvigil-export     #   s3:         bucket, prefix, region, endpoint (an S3-compatible store), profile
                                  #   azure_blob: container, prefix, and connection_string: env:NAME | sas_url: env:NAME
                                  #               | account_url (the default credential)
  settle_minutes: 20              # a window is first exported this long after it ends
  final_after_hours: 24           # it is exported again, as final, once it is this old
  max_window_age_hours: 48        # how far back a run looks for hours to export; an older hour with no manifest is
                                  #   named as aged out (its final pass is owed at any age)
  max_windows_per_run: 12
  snapshot_max_bytes: 256MB       # a whole-table export over it (its size on disk with its indexes) is left out and
                                  #   named; 0 = no line
  statement_timeout: 120s         # of the reading session
  carry: []                       # text (statement, plan and log text), audit (action logs, audit trails, logins,
                                  #   roles and grants): each OFF unless named
  tables: { exclude: [] }         # more tables left out by name (a name that is no table is refused); what the map
                                  #   leaves out cannot be put back in
```

A key the section does not know is refused (exit 3): a mistyped key must not pass as a default.

## The probes: /livez and /readyz (web:)

`pgvigil serve` answers two probes for a load balancer or an orchestrator, without the UI login and with nothing but
their words:

- `GET /livez` - `200 ok` while the process answers. It reads nothing.
- `GET /readyz` - `200 ok` while the repository answers and its schema is current (the answer `pgvigil run` checks at
  its start, read from `pgvigil.schema_version` on serve's own login), else `503 not ready: <why>` (`the repository
  does not answer`, or `the repository's schema is behind this binary (needs <migration>)`). The answer is kept 5
  seconds: a burst of probes runs one check. The check has its own 3 seconds: a probe that gives up sooner does not cut
  it, and what the next probes are told is the repository's answer. The repository's own error stays in the log (it
  can name the login and the address).

`/readyz` is open while the UI login is off. With the login on it answers `404` unless the configuration opens it:

```yaml
web:
  readyz_without_login: true   # default false: /readyz then needs nothing from the caller
```

The collector's own state (a collection failing, the alert sender idle, the repository's autovacuum behind) is a
finding on the Collector page and the Summary, never a probe's answer.

## The UI under a sub-path, behind a reverse proxy (web: base_path)

`pgvigil serve` can answer under a sub-path - `https://tools.example.org/pgvigil/` - for a reverse proxy that passes
the path whole:

```yaml
web:
  base_path: /pgvigil   # a leading '/', no trailing one; empty (the default) = the root
```

`pgvigil serve -base-path /pgvigil` says the same and wins over the file. With a base path every route is under it:
the pages, `/pgvigil/api/...`, the probes (`/pgvigil/livez`, `/pgvigil/readyz`), `/pgvigil/metrics`. `/pgvigil` alone
is sent to `/pgvigil/`; any other path is a 404, and the log names the base path once. The session cookie's path is
the base path's, so it is not sent to the other sites on the host. pgvigil takes the prefix from this setting only,
never from a header such as `X-Forwarded-Prefix` (a header any client can send).

The proxy must pass the path as it came, and a Host header pgvigil accepts: on a loopback listen (`-listen
127.0.0.1:8080`, the default) serve takes only a loopback Host, which nginx sends by default and Caddy must be told.

nginx:

```nginx
location /pgvigil/ {
    proxy_pass http://127.0.0.1:8080;   # no URI part: the path goes through whole
    proxy_http_version 1.1;
    proxy_buffering off;                # the live pages' event stream is one long answer
}
```

Caddy:

```
redir /pgvigil /pgvigil/ 308
handle /pgvigil/* {
    reverse_proxy 127.0.0.1:8080 {
        header_up Host {upstream_hostport}
    }
}
```

`handle`, not `handle_path` (which strips the prefix). A proxy that strips the prefix is not served: pgvigil answers
404 to every path. Set `alerts_base_url` (the alerts' links) to the address with the prefix,
`https://tools.example.org/pgvigil`. The session cookie is `Secure` when serve's own listener is TLS (`-tls-cert`);
behind a proxy that ends TLS, keep serve on loopback.

Not proven: Apache httpd and IIS as the proxy; a proxy that rewrites the pages it passes.

## Log verbosity (log_level)

```yaml
log_level: info        # debug | info (the default) | warn | error
```

The level of every line the collector (`pgvigil run`), `pgvigil serve` and the other commands write to their log -
stderr, the journal under systemd, `%ProgramData%\pgvigil\logs\pgvigil.log` for the Windows service. `warn` keeps
the warnings and failures only; `debug` adds the few lines written for a problem's read. The environment's
`PGVIGIL_LOG_LEVEL` wins over the file for a one-off (a command run by hand, or the service's own environment), and
an unknown word there is ignored with one warning; an unknown word in the file is refused at load. The level is read
at each start: a change needs the service restarted.
