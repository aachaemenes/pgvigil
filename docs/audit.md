# Audit monitoring (pgaudit)

pgvigil does not audit a server. [pgaudit](https://www.pgaudit.org) does: it writes one `AUDIT:` line to the server
log for every statement or object it is told to audit. pgvigil reads two things about it every minute, with the
`pgaudit` collection:

- **Is the audit on, and what does it cover?** The settings, from the catalog.
- **What did it record?** The `AUDIT:` lines, from the server log, through the same doors the log readers use.

The Audit tab of an instance (under Configuration) shows both. SQL Server's audit is its own page:
[SQL Server Audit](sqlserver-audit.md).

## What is read

**Settings** (any login can read these; `pg_monitor` adds the preload list and the log's directory):

- whether the library is loaded. pgaudit loads through `shared_preload_libraries` or not at all, so its own settings
  exist in a backend only when it is;
- every `pgaudit.*` setting of `pg_settings` with its source (`pgaudit.log`, `log_catalog`, `log_client`, `log_level`,
  `log_parameter`, `log_relation`, `log_rows`, `log_statement`, `log_statement_once`, `role`, as the server's
  version of pgaudit has them);
- every `ALTER DATABASE ... SET pgaudit.*`, `ALTER ROLE ... SET pgaudit.*` and `ALTER ROLE ... IN DATABASE ... SET`
  from `pg_db_role_setting`: a role's or a database's value replaces the server's for its sessions, so "the server
  logs nothing" and "nothing is logged" are different statements;
- where the server log goes (`log_destination`, `logging_collector`, `log_directory`, `log_filename`; on RDS and
  Aurora the CloudWatch log group of the instance's `aws:` block).

Whether the `pgaudit` extension is created in each database comes from the `extensions` collection (hourly), not
from a connection per database every minute. It matters for DDL: without `CREATE EXTENSION pgaudit` a database's DDL
entries carry no object type and no object name (the event triggers that supply them come with the extension).

**Entries**, only on a server that has pgaudit loaded:

- on-prem, the stderr log files, listed with `pg_ls_logdir()` and read through the read door the client's DBA opens
  for the monitoring login (`pgvigil_read_log`, or the wide grant on `pg_read_binary_file`): the same door as the
  [server log reader](logs.md), nothing more to grant;
- on RDS and Aurora, the instance's PostgreSQL log group in CloudWatch Logs (`aws:` block), as the `logs`
  collection reads it.

The collection reads the log on a pass of its own, from a cursor of its own. A server without pgaudit costs one
catalog read a minute and no log read.

`csvlog` and `jsonlog` files are not read (stderr only, as the log readers). On Azure, Cloud SQL and AlloyDB the
settings are read and the entries are not.

## What is kept

| entries | kept as | columns |
| --- | --- | --- |
| `ROLE`, `DDL` | a row per entry (`pgvigil.pgaudit_events`) | when, who, database, client, command, object type and name, the role named, SESSION or OBJECT |
| `SET` / `RESET` of a setting that matters to an audit | a row per entry, class `MISC_SET` | the same; the object is the setting's name |
| `READ`, `WRITE`, `FUNCTION`, `MISC` | a count (`pgvigil.pgaudit_counts`) | per hour (UTC), role, database, class, command, object |
| every other `SET` / `RESET` | a count, class `MISC_SET` | per hour, role, database and setting name |
| failed sign-ins | the log readers' `auth_fail` events (`pgvigil.log_events`) | when, who, database, client, the server's message |

Failed sign-ins are the server's own messages, not pgaudit's: they are there with or without pgaudit, wherever the
`serverlog` or `logs` collection reads the log.

**SET.** pgaudit writes a `SET` or a `RESET` with the class `MISC` in the log line, whichever of `misc` and `misc_set`
in `pgaudit.log` turned it on. pgvigil files both commands under `MISC_SET`, the `pgaudit.log` class that logs them.
Most of them are routine: an application's `SET search_path`, a pooler's `SET application_name`, and pgvigil's own
four session settings on every connection it makes. So a `SET` is a row only when it changes who the session is,
what is audited or logged, or what the server enforces:

- `pgaudit.*` (the audit itself);
- `session_authorization` (a superuser acting as another role);
- `log_statement`, `log_min_messages`, `log_min_error_statement`, `log_min_duration_statement` (what reaches the log);
- `row_security`, `session_replication_role` (row-level security, triggers and rules).

Every other `SET` is counted by its setting's name. `SET ROLE` is counted too, with the role taken in the count's
object (`role = admin`): an application that takes a role per request does it thousands of times an hour.
A `SET` whose statement pgaudit did not write (`pgaudit.log_statement = off`) has no setting name and is counted.

**The object of a row.** pgaudit names the object of a `SELECT`, of DML and of most DDL. For the entries where it
names none, pgvigil reads the names from the statement before the statement is dropped:

- `CREATE` / `ALTER` / `DROP ROLE` (`USER`, `GROUP`): the role;
- `GRANT` / `REVOKE`: the object after `ON` (or the roles granted, for a membership) and, in "role named", the
  grantees;
- `SET` / `RESET`: the setting's name, never its value; `SET SESSION AUTHORIZATION` also gives the role taken.

These are identifiers. A literal is never read into them.

**The object of a count.** A session entry of a `SELECT` or of DML names its relation only with
`pgaudit.log_relation = on`; object auditing (`pgaudit.role`) always names it. Without either the counts are per
role, database and command.

**Counted once.** Like the log readers, each run reads a few minutes of overlap behind its cursor again. A row is
dropped on the second read by its key. A count has no key, so the collector counts per second and per log file, and
the repository adds only what a second gained since it was last counted (`pgvigil.pgaudit_count_secs`, kept 30
minutes behind the cursor).

## Statement text is opt-in

An audited statement can carry data: a literal in a `WHERE` clause, a value in an `INSERT`, a bound parameter. By
default pgvigil stores none of it: no statement, no parameters, for any class.

```yaml
instances:
  - name: billing-primary
    dsn: env:BILLING_DSN
    pgaudit_text: true      # keep the statement text of the entries stored as rows
```

With `pgaudit_text: true` the rows keep their statement, and their parameters where `pgaudit.log_parameter`
writes them. Three limits stay:

- a counted entry never keeps text, with or without the switch;
- the instance's `query_text` policy still applies, as to every other statement pgvigil keeps: under `normalized`
  the literals are replaced and no parameters are kept, under `none` nothing is kept;
- a password in the text is masked (pgaudit redacts `CREATE` / `ALTER ROLE ... PASSWORD` itself; pgvigil masks what
  is left, as in every statement it stores).

Switching it off again stops new text; the rows already stored keep theirs until they age out.

## The status cell and the findings

| cell | means |
| --- | --- |
| `off` - not loaded | pgaudit is not in `shared_preload_libraries` and nothing sets a `pgaudit.*` value |
| `ok` - the classes | loaded and logging: the server's `pgaudit.log`, the role of object auditing, and how many databases and roles set their own |
| `warning` - loaded, logging nothing | loaded, and `pgaudit.log` names no class at the server, on any database or on any role, and `pgaudit.role` names no role |
| `warning` - set, not loaded | something sets a `pgaudit.*` value and the library is not loaded: nothing is audited |

Findings (they reach the Findings tab and the alert channels like any other):

- **pgaudit preloaded, logging nothing** (warning);
- **pgaudit settings without pgaudit** (warning): a value set at the server, on a database or on a role, the
  library not loaded;
- **log_parameter on: statement parameters reach the log** (warning), at the server, on a database or on a role:
  every bound value of an audited statement is written in clear to the log and to every place the log is shipped;
- **pgaudit extension not created in ...** (info): DDL is audited and these databases' entries carry no object.

## Alert rules

A rule counts entries of one kind inside a window and fires at a count. A firing rule is a finding of the instance
(`audit rule: <name>`), so the alert channels, repeats, silences and acknowledgements of [Alerts](alerts.md) apply.

| rule | counts | fires at | default |
| --- | --- | --- | --- |
| role or privilege change | `ROLE` entries | 1 in 24 hours | on, warning |
| audit setting changed by a session | `SET` / `RESET` of `pgaudit.%` | 1 in 24 hours | on, warning |
| session authorization changed | `SET SESSION AUTHORIZATION` | 1 in 24 hours | on, warning |
| failed sign-ins | the log readers' `auth_fail` events | 10 in 1 hour | on, warning |
| object dropped | `DDL` entries, command `DROP %` | 1 in 24 hours | off |
| schema change | `DDL` entries | 1 in 24 hours | off |

The second and third rules need `misc_set` (or `misc`) in `pgaudit.log`: pgaudit writes a `SET` only then. A rule
on `MISC_SET` sees the rows, so the settings listed under [What is kept](#what-is-kept).

The rules are rows of `pgvigil.pgaudit_rules` in the repository. The repository's owner changes them in SQL:

```sql
-- more sign-in failures before it fires, and critical
UPDATE pgvigil.pgaudit_rules SET min_count = 50, severity = 'critical' WHERE name = 'failed sign-ins';
-- switch a rule on
UPDATE pgvigil.pgaudit_rules SET is_enabled = true WHERE name = 'object dropped';
-- a rule of your own: any change to one role
INSERT INTO pgvigil.pgaudit_rules (name, what, object_like, min_count, window_minutes, severity)
VALUES ('the payments role changed', 'ROLE', 'payments%', 1, 1440, 'critical');
```

`what` is `ROLE`, `DDL`, `MISC_SET` or `AUTH_FAIL`; `command_like` and `object_like` are `LIKE` patterns, case-blind
(for `AUTH_FAIL`, `object_like` matches the login name); `window_minutes` is at most 31 days. A rule applies to
every PostgreSQL instance.

## Limits

- The entries are as complete as the log: a log line the reader cannot place (a `log_line_prefix` without a time or
  the process id) is not read, and the collection says why on the Audit tab.
- One run reads at most 64 MB of log files (200,000 CloudWatch events); a busier server is read over several runs.
- A second that holds more than 64 MB of log is read up to that size, and the run is marked partial.
- The hours of the counts are UTC hours.
- Not proven on RDS or Aurora: the CloudWatch path shares the log reader's fetch and cursor rule and has run only
  against recorded events.
