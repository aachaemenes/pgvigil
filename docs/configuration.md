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
| xid age | `age(datfrozenxid)` under `autovacuum_freeze_max_age` | at or past it: the anti-wraparound vacuum is due | 1 billion or more | |

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
checks until it is enabled. A server list or CSV must be readable by more than its owner (0644): a file only its owner
may read, a network (UNC) path and a `.pgpass`-shaped line are refused, so no credential file is read into the page.

Who may change them: every UI login can add, change, disable and remove instances and sources, and these writes need
the actions door's audit login, as acknowledgements do. Give UI logins to the people who may change what is monitored.

One collector per repository collects the page's instances: the one holding the repository's `page_inventory` lock. A
second `pgvigil run` on the same repository (another host with its own file's instances) collects its file's
instances only, logs once that another collector holds the page's, and takes them over within 15 seconds when the
first one stops.

A `custom:` check may name an instance or a tag only the page holds: the file's instances no longer decide, so a name
or tag that matches nothing in the file is a warning at start, and the collector warns again when a check matches no
instance of the file or the page.

`pgvigil run` starts with no instance in the file (the page may hold them all); `pgvigil collect -once` reads the
file's instances only. A repository `dsn` that resolves to nothing (the installer's env file not filled in yet) stops
`run` and `serve` with exit 3, which the service leaves stopped.

Credentials go to files beside the configuration file (`instances/` and `sources/`): on Linux 0600 files in 0700
folders; on Windows a DPAPI machine-scope blob in a folder whose access list is SYSTEM, Administrators and the service
account. The repository keeps only each file's name, so `pgvigil serve` and `pgvigil run` must share the configuration
folder (one host). Every change is audited (the page's Changes grid).

Not in this release: Entra (Azure AD) sign-in for an instance added here. The page can build such a connection, but the
collector does not sign in with it yet; its test says so.
