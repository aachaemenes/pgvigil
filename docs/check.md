# Checking an install

`pgvigil check [-config pgvigil.yaml] [-json] [-instance name]...` is a read-only health check of an install: nothing
is written to the repository or to a monitored server. It prints one line per check, `OK | WARN | FAIL <what>: <words>`
(`-json` gives the same rows as JSON), and exits **0** when everything is OK, **1** when the configuration does not
load (or on a usage error), **2** when the repository is unreachable or was written by a newer pgvigil, and **3** on
any WARN or a failed instance - so an install script can gate on the code.

- **The configuration** loads exactly as `pgvigil run` loads it, or the check fails with the loader's own error. It
  warns on a PostgreSQL instance whose dsn carries an inline password (move it to a passfile, `env:NAME`, `file:/path`
  or `password_secret`; the inline form is discouraged) and on an instance with no collection left to run.
- **The secret files**: who may read each file of the configuration's folder that can hold a secret - the file,
  the installer's dsn files (`repo.dsn`, `reports.dsn`, `pgvigil.env`), everything under `secrets/`, `instances/`,
  `sources/` and `keys/` - and the folders. On Linux any bit for others is a FAIL and a group bit beyond read a WARN
  (a folder's group may pass through it); on Windows read for anyone but SYSTEM, the Administrators and the service's
  account is a FAIL. Each prints its fix (`chmod o-rwx <file>`, `icacls "<file>" /remove:g *<SID>`); check changes
  nothing (on Windows `pgvigil install` run again sets the installer's access list on the folder once more).
- **The references**: every `env:`, `file:` and `dpapi:` value of the file, whichever block holds it (`reports_dsn`,
  `alerts_dsn`, an instance's `actions_dsn`, `explain_dsn`, `stats_dsn` or `pgbouncer`, `export:`, the alert
  channels), is resolved as its reader resolves it: each that resolves to nothing is a FAIL naming where it sits
  (`reference instances[pg1].actions_dsn`) and why - the variable not set or empty, the file and the system's error,
  the `dpapi:` blob that did not open on this host - never what was read; when all resolve, one OK line counts them.
  The repository's dsn and each instance's dsn are judged in their own lines below with the same words.
- **The repository**: a dsn that resolves to nothing is a FAIL with why and nothing is connected (an empty dsn
  would be libpq's defaults: localhost, as the account running the check); otherwise the connect, its schema level against this build (behind: *run pgvigil migrate*; ahead: a FAIL -
  this build must not run on it), and its size. Free space beside the store is read only when the store is on this
  host and its `data_directory` is readable to the login and the process: a WARN under 10 GiB free or under 30 days of
  the store's growth; otherwise the line says *not read: the store is on \<host\>*.
- **Each instance** - the file's and Admin > Instances' enabled inventory, both engines - gets the one connection test
  the Admin page itself uses (10 seconds, at most 8 at a time): who answered, and the collections that will not run
  there and why. A server this build does not know is a WARN beside its OK line: a PostgreSQL major outside 13 to 18,
  a SQL Server major outside 13 to 17 (2016 to 2025; Azure SQL Database and Managed Instance answer 12 whatever they
  run and are not judged by it), or an engine edition pgvigil does not run on (Microsoft Fabric's SQL database, 12,
  among them). Nothing is refused for it: each collection keeps its own version rule and one whose read breaks fails
  alone (a named difference from DBA Dash, which refuses an unknown version or edition unless its check is skipped).
  `-instance <name>` narrows the connection tests; the configuration and repository checks still run.

## Keeping a password out of pgvigil.yaml

A PostgreSQL instance's `dsn` may hold its password inline, and such a configuration keeps loading - but the
collector warns at every start, `pgvigil check` lists the instance, and the form is discouraged: the file is read by
whoever reads the configuration, and backups carry it. The other forms: a libpq passfile (`passfile=` in the dsn),
`env:NAME`, `file:/path`, `password_secret` (AWS Secrets Manager), or a sealed file:

```
pgvigil secret seal -name pg1 [-config pgvigil.yaml] < the connection string     (typed at a terminal, it is not shown)
dsn: file:/etc/pgvigil/secrets/pg1-3f9c2a1b77e0.dsn
```

The command takes the connection string on stdin - never as an argument - writes it to `secrets/` beside the
configuration and prints the line to put under the instance in place of its `dsn`. On Linux that is a file with the
configuration folder's owner and group - mode 0640 under the installer's 0750 folder, so the service reads it as its
group, 0600 elsewhere (run it as root or as the folder's owner); on Windows a DPAPI blob at
machine scope and a `dpapi:` reference, readable through the configuration folder's own access list. Each seal
writes a new file; `pgvigil uninstall -all` removes the folder.

A `dpapi:` blob opens only on the host that sealed it (machine scope): a configuration folder copied to a new server,
or a host rebuilt, keeps the reference and loses the secret. pgvigil has no key to offer for it and keeps no
encrypted configuration (a named difference from DBA Dash's temporary key: here every secret is a reference read at
each connect). The connect, `pgvigil check` and, for the repository's own dsn, the service's start (exit 3) then say
which reference resolved to nothing and why - the blob that did not open and the fix (seal it again on this host),
the file and the system's error, the variable not set - never what was read. To move a host with its sealed
secrets, `pgvigil config export -password-stdin` opens them on the old host and `pgvigil config import` seals them
again on the new one ([moving pgvigil to a new server](upgrade.md#moving-pgvigil-to-a-new-server)).
