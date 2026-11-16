# Check all and Rights (Admin > Instances)

Two reads on Admin > Instances, for every instance - the ones added in the page and the ones of `pgvigil.yaml`
alike. Both connect to the monitored server as the instance's own monitoring login; neither changes anything there.

## Check all

**Check all** tests the connection of every instance in view, six at a time, and fills each row's *last test* as its
answer comes: `connected` or `failed`, with the server's words on hover. A server that does not answer holds one of
the six seats for at most 10 seconds; the others go on. A disabled instance is not asked and says so in the last
line (`Checked 12: 11 connected, 1 failed; 2 disabled, not checked.`). A row's own **Test** does the same for one.

- An instance of `pgvigil.yaml` is tested with the file's own `dsn`, which stays in `pgvigil serve`: no answer and
  no page holds a connection string or a password.
- An instance of the file whose `dsn` does not parse says only that (`the instance's dsn in pgvigil.yaml does not
  parse`): the parser's own error would show the string, and with it a password.
- Each result is kept (the page's instances on their own row, the file's by name) and still shows after the page is
  read again; a result older than the one kept is audited and not kept. Each test is one row in *Changes* (`instance tested`), as a single Test always was: a Check all of a
  large fleet fills that list of the last 200.
- *Last collected* is how long ago the instance's newest collection ended ok, by the repository's clock (`26 seconds
  ago`, the time on hover); `never collected` for an instance no collection has reached. Where a collection's last
  run ended in an error it says how many do and names the newest with its note (`; 1 failing: jobs - ...`). A
  *skipped* collection is not an error: it lacks a right, and **Rights** names it.

Check all needs what every write of the page needs: a signed-in user and the actions door's audit login (the page
says `Read only: ...` where it cannot).

## Rights

**Rights** on a row reads, as that instance's monitoring login, which of the rights pgvigil needs it holds, and
prints the script of the missing ones. **pgvigil never runs that script and has no button that grants**: it is text
to copy, for an administrator of that server to read and run. Every name in it is quoted by the server itself.

- On SQL Server a database right goes to the login's own user there, found by its SID whatever its name; where the
  read could not see it, the script's block finds it when it runs, creates it only where neither it nor a user of the
  login's name is there, and stops with an error rather than grant to a user of that name that is not the login's (an
  orphan left by a restore). Each such block is a batch of its own (`GO`).
- An account that signs in through a Windows group's login has no login of its own to grant to: no script is printed,
  and the box says so.
- No script is printed either when a name the server answered (the login, the server, a user or a database) holds a
  line break or another control character: such a name could end a comment line and start a statement of its own.
- On PostgreSQL the script's first lines name the database to run it in (the door function and the `pg_catalog`
  grants are that database's), and the door is `CREATE OR REPLACE`. A member of pg_monitor that does not inherit its
  rights gets `ALTER ROLE ... INHERIT` (`GRANT pg_monitor ... WITH INHERIT TRUE` on PostgreSQL 16 and later).

Each right is listed with what needs it and one of: `held`, `missing`, `not installed: ...` (the thing it is about
is not on the server) or `not on this server: ...`. *Needed* rights are the ones a whole family of collections is
skipped without; *optional* ones belong to one feature.

| SQL Server | Needed for |
|---|---|
| VIEW SERVER STATE (needed) | the live reads: running queries and blocking, waits, CPU and memory, the counters. From SQL Server 2022 VIEW SERVER PERFORMANCE STATE alone serves the performance reads |
| VIEW ANY DEFINITION (needed) | every database's metadata, the audits and their specifications |
| msdb: a user with db_datareader (needed) | the Agent jobs and their history, the backup history |
| CONNECT ANY DATABASE (needed) | each database's own reads; held when the login holds it, else the online multi-user databases it cannot enter are named (the platform's own, rdsadmin and gcloud_cloudsqladmin, are left out; on Google Cloud SQL the row says its administrator cannot grant it) |
| SELECT on msdb.dbo.restorehistory | a restored database's restore date |
| EXECUTE on master.dbo.xp_instance_regread, xp_regread | Properties: the network settings, Win32PrioritySeparation, the power plan |
| ALTER TRACE | the default trace's events. It also lets the login start and stop server traces: give it only where that is accepted |
| VIEW SERVER SECURITY AUDIT | the audit's events (SQL Server 2022 and later; before that they need CONTROL SERVER, which pgvigil never asks for) |
| EXECUTE on master.dbo.sp_WhoIsActive | Running queries through sp_WhoIsActive, where it is installed (a login without VIEW ANY DEFINITION may not see it: then `not installed, or not visible to this login`) |

On Azure SQL Database the one right is VIEW DATABASE STATE in the database - or, on Basic, S0, S1 and in an elastic
pool, membership of the logical server's ##MS_ServerStateReader## (the DMVs ask the server-level right there). On Azure SQL Managed Instance, Amazon
RDS and Google Cloud SQL the registry rights are listed as not applying (the platform runs the host); Amazon RDS
lists its own audit reader (`msdb.dbo.rds_fn_get_audit_file`).

| PostgreSQL | Needed for |
|---|---|
| pg_monitor (needed) | every statistics view and setting |
| CONNECT on every database (needed) | each database's own reads; a `GRANT CONNECT` line per database the login cannot connect to (a template, an invalid database and a managed platform's own - rdsadmin, azure_maintenance, cloudsqladmin, alloydbadmin - are left out) |
| EXECUTE on pg_ls_logdir() | the server log's files listed (pg_monitor gives it) |
| the server log's read door | the log's content on a self-managed server: the function `pgvigil roles` prints, which a superuser creates |
| SELECT on pg_hba_file_rules | pg_hba.conf's rules on the Roles page |
| SELECT on pg_subscription's oid (PostgreSQL 13) | the logical replication read's subscriptions and their tables (13 grants the column to superusers only; 14 to all) |

The last four are listed on a self-managed server only. Not in the list: an extension's own functions where it is
installed (pg_buffercache, amcheck, system_stats - the collection that reads it names its GRANT in its skip note),
pg_cron's schema and BYPASSRLS (`pgvigil roles` prints them), and the actions and explain logins, which have their
own pages ([sqlserver-actions.md](sqlserver-actions.md), `pgvigil roles`).

A Rights read is one connection of at most 10 seconds and one row in *Changes* (`instance rights`). A server that
cannot be reached says why in the box, as a test does.
