# Checking an install

`pgvigil check [-config pgvigil.yaml] [-json] [-instance name]...` is a read-only health check of an install: nothing
is written to the repository or to a monitored server. It prints one line per check, `OK | WARN | FAIL <what>: <words>`
(`-json` gives the same rows as JSON), and exits **0** when everything is OK, **1** when the configuration does not
load (or on a usage error), **2** when the repository is unreachable or was written by a newer pgvigil, and **3** on
any WARN or a failed instance - so an install script can gate on the code.

- **The configuration** loads exactly as `pgvigil run` loads it, or the check fails with the loader's own error. It
  warns on a PostgreSQL instance whose dsn carries an inline password (move it to a passfile, `env:NAME`, `file:/path`
  or `password_secret`; the inline form is discouraged) and on an instance with no collection left to run.
- **The repository**: the connect, its schema level against this build (behind: *run pgvigil migrate*; ahead: a FAIL -
  this build must not run on it), and its size. Free space beside the store is read only when the store is on this
  host and its `data_directory` is readable to the login and the process: a WARN under 10 GiB free or under 30 days of
  the store's growth; otherwise the line says *not read: the store is on \<host\>*.
- **Each instance** - the file's and Admin > Instances' enabled inventory, both engines - gets the one connection test
  the Admin page itself uses (10 seconds, at most 8 at a time): who answered, and the collections that will not run
  there and why. `-instance <name>` narrows the connection tests; the configuration and repository checks still run.

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
configuration and prints the line to put under the instance in place of its `dsn`. On Linux that is a file of mode
0600 with the configuration folder's owner (run it as root or as the service account); on Windows a DPAPI blob at
machine scope and a `dpapi:` reference, readable through the configuration folder's own access list. Each seal
writes a new file; `pgvigil uninstall -all` removes the folder.
