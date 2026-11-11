# SQL Server: audit monitoring

SQL Server Audit records who signed in and failed, who was given a permission or a role, what was created, altered or dropped, and who touched the audit itself. A server can have an audit and nobody looking at it: switched off after a change, pointed at a full disk, or recording into files no one reads. pgvigil reads the audits a DBA defined. It does not define them.

## The rule

pgvigil's monitoring login never creates, alters, starts, stops or drops a server audit or an audit specification, and it could not: that needs ALTER ANY SERVER AUDIT. The collection `mssql_audit` reads two things, every five minutes:

- the audit **health**: is each audit running, where does it write, what is it told to record;
- the audit **events** of every audit that writes to a file, forward from where the last read stopped.

Azure SQL Database: not built. Its audit goes to a storage container (the blob target), a Log Analytics workspace or an event hub, and T-SQL names none of them; reading the blob target would need the container's address in the configuration. The collection says `skipped` there, with that reason, and the Audit page shows it.

## Audit health

For every server audit (`sys.server_audits`, `sys.server_file_audits`, `sys.dm_server_audit_status`):

| | |
|---|---|
| state | `started`, `not started` (defined and switched off), `failed` (the server reports a runtime or target failure, or the audit is switched on and not among the audits the server runs), and since when |
| target | file, Windows Application log, Windows Security log (on a Managed Instance: URL, external monitor) |
| on failure | continue, shut the server down, or fail the audited operation |
| queue delay | milliseconds; 0 is synchronous |
| file | the folder, the file written now, its size, the size and rollover limits |
| last event | the time of the newest event pgvigil read from it |
| its events | what became of them at the last read: read, nothing read yet (never read and not started), health only (the login may not read the files), not readable through T-SQL (a Windows log), not read (URL, external monitor) |

And what each audit is told to record: every server audit specification with its action groups, and every database's audit specification with its groups and its single actions (`SELECT on dbo.orders by public`), each with the audit it belongs to and whether it is switched on. The database specifications are read database by database; a database the login cannot enter is counted as not asked and keeps what an earlier read stored.

Measured on SQL Server 2022: an audit that is switched off has no row in `sys.dm_server_audit_status` at all. `is_state_enabled` in `sys.server_audits` is what says it is off.

On the Summary the cell `audit` reads `2 started`, `1 of 2 started` (a warning) or `none`; a failed audit makes it critical.

## Audit events

A file audit's records are read with `sys.fn_get_audit_file` (on Amazon RDS `msdb.dbo.rds_fn_get_audit_file`) from a cursor kept in the repository: the audit's file and the offset of the last buffer read.

- The first read of an audit starts at the file the audit is writing now. What older files hold is not loaded: an audit of every SELECT can keep gigabytes of them.
- A read ends on a buffer's edge and is stored together with its cursor in one transaction, so an event is stored once and a count is never added twice.
- When the file the cursor names has been rolled away, the set is read again from its oldest file and the records at or before the newest event already read are passed over.
- A run that cannot finish a backlog in its two minutes goes on from the cursor at the next run.

### What is kept as a row

| Category | Actions |
|---|---|
| failed sign-ins | `LOGIN FAILED`, `DATABASE AUTHENTICATION FAILED`: who, when, from which address, program and host, the server's reason, error and state |
| role membership | `ADD MEMBER`, `DROP MEMBER` of a server or database role |
| permissions | `GRANT`, `DENY`, `REVOKE` in their forms, `TAKE OWNERSHIP` |
| logins and passwords | password change and reset, unlock, enable, disable, rename, credential mapping |
| DDL | `CREATE`, `ALTER`, `DROP`, `TRANSFER` |
| audit changes | the audit started or stopped, an audit or an audit specification created, altered or dropped, an audit shut down on failure |

Each row carries the login, the session's login where it differs (EXECUTE AS), the target login or user, the database, schema and object, the client address, program and host, and whether the action succeeded.

DDL inside tempdb and on statistics is routine (a temporary table, an automatic statistic) and is counted, not listed. One read lists at most 20,000 events of one audit; the rest of that read is counted, and the audit's row says so.

### What is counted

Everything else an audit records (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `EXECUTE`, successful sign-ins and sign-outs, completed batches, transactions, backups, DBCC) is counted per hour, login, database, schema, object and action, with the count of those whose permission check failed. No row and no statement of them is stored.

### Statement text

Statement text can carry data: a literal in a WHERE clause, a value in an INSERT. By default pgvigil stores none of it for audit events.

```yaml
instances:
  - name: sales-sql01
    engine: sqlserver
    dsn: env:SALES_SQL01_DSN
    audit_text: true          # store the statement of the LISTED events (default false)
```

With `audit_text: true` the statement of a listed event is stored, under the instance's `query_text` policy: `full` as the server wrote it, `normalized` with every literal replaced by `?`, `none` nothing. SQL Server itself writes a password as `'******'` in an audit record; any other credential form is masked before the text leaves the collector. The statement of a counted event is never taken off the server, opted in or not.

A failed sign-in's reason (`Login failed for user 'x'. Reason: Password did not match that for the login provided.`) is the server's own message, not statement text, and is always kept. The rest of that record's detail is not stored: it carries a fragment of the password's hash.

## The rights

Read from Microsoft's pages on 2026-11-11 and measured on SQL Server 2022.

| To read | The login needs |
|---|---|
| the audits and their specifications | `VIEW ANY DEFINITION` (or `ALTER ANY SERVER AUDIT`). Without it the catalog views list nothing and raise no error |
| each database's specification | `VIEW ANY DEFINITION` and `CONNECT ANY DATABASE` |
| which audit is started | `VIEW SERVER STATE` |
| the events | SQL Server 2022 and later: `VIEW SERVER SECURITY AUDIT`. SQL Server 2019 and earlier: `CONTROL SERVER` |

The first three are what pgvigil's monitoring login already holds. The fourth is a choice:

```sql
GRANT VIEW SERVER SECURITY AUDIT TO [pgvigil];   -- SQL Server 2022 and later
```

On SQL Server 2019 and earlier the server asks for `CONTROL SERVER`, which is the whole server. pgvigil does not ask for it. A login without the right reads the health only: every file audit's row says `health only` and names the right, the Summary cell says `events not read`, the collection's status stays `ok`. It is counted apart and is not a failure.

On SQL Server 2022 the two narrower rights `VIEW ANY SECURITY DEFINITION` and `VIEW SERVER SECURITY STATE` read the catalog and the state view too, but the collection asks the connection for `VIEW ANY DEFINITION` or `VIEW SERVER STATE` before it runs: a login that holds only the narrow pair is skipped.

An audit that writes to the Windows Application or Security log cannot be read through T-SQL (`sys.fn_get_audit_file` reads files). Its health is read, and its row says its events are in the Event Viewer of the server.

## Findings

| Finding | Severity |
|---|---|
| an audit is defined and not started | warning, per audit |
| an audit failed | critical, per audit |
| an audit specification is switched off (while its audit is started) | warning |
| an audit specification has no audit on this server (a restored or failed-over database whose specification names an audit GUID the server does not have) | warning |
| no audit covers sign-in failures (no started audit has an enabled specification with `FAILED_LOGIN_GROUP`) | info |
| failed sign-ins in the last hour | 10 or more: warning; 100 or more: critical |
| an audit or its specification was changed (in the last hour) | warning; an audit shut down on failure: critical |
| a server role gained a member (in the last hour) | warning |
| security changes in the last hour (role, permission, login events) | info |

The health findings need a read in the last 20 minutes: a server pgvigil has not read lately raises none of them. Findings reach the alert channels like every other finding ([alerts](alerts.md)).

## The page

The **Audit** tab of a SQL Server instance: the findings, what the last read could read, the audits, the specifications, the listed events (with a category filter and the time strip), the counted events of the hours the window touches, and a chart per hour.

## Amazon RDS, Managed Instance

On Amazon RDS for SQL Server the reader is `msdb.dbo.rds_fn_get_audit_file` and the right asked is SELECT on it. A finished file that RDS has moved to its `transmitted` folder is not read. This path is built from AWS's documentation and is not proven: it has not been run against Amazon RDS.

On Azure SQL Managed Instance an audit writes to a URL or an external monitor: its health is read and its row says its events are not read. Not proven either: it has not been run against a Managed Instance.

## What it costs the monitored server

Six small catalog reads, one more per database for its specification, and for each file audit one read of the records past the cursor, 5,000 at a time. The reader takes the statement column off the server only for the listed actions and only when the instance opted in.

## Retention

The events and the hourly counts are stored in monthly partitions and leave with `pgvigil purge` like every other history. An audit or a specification gone from the server is kept for 30 days.

## Proof

`scripts/proof-mssql-audit.sh` creates an audit with a server and a database specification on a SQL Server of its own and proves: the health against sa's own read; a CREATE LOGIN, a GRANT, a role membership, a failed sign-in and a CREATE TABLE each stored once, 1,000 SELECTs and 3 INSERTs counted exactly, across many batches; no statement text in the repository without the opt-in and the text under each `query_text` policy with it; a stopped audit raising its finding and a started one clearing it, with the ALTER of the audit listed once and the events read across the file change; a login without the audit right reading the health only; the sign-in rule; and the rules no server shows on demand on imported rows.

Result, 2026-11-11, SQL Server 2022 (16.0.4315.2) on Linux in a container of its own, the repository on PostgreSQL 18 and the migration chain on PostgreSQL 13: PASS, every part, with the Audit page checked in a headless browser in both themes.

Not proven: an Application or Security log target and a failed audit on a live server (SQL Server on Linux has the file target only), SQL Server 2016 to 2019, Amazon RDS, Azure SQL Managed Instance, a cursor file rolled away on a live server (a unit test covers the rule), a record longer than 4,000 characters.
