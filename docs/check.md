# Checking an install

`pgvigil check [-config pgvigil.yaml] [-json] [-instance name]...` is a read-only health check of an install: nothing
is written to the repository or to a monitored server. It prints one line per check, `OK | WARN | FAIL <what>: <words>`
(`-json` gives the same rows as JSON), and exits **0** when everything is OK, **1** when the configuration does not
load (or on a usage error), **2** when the repository is unreachable, its dsn resolves to nothing (an unset variable,
an unreadable file: a configuration error of the repository's own, as `pgvigil run` refuses it) or it was written by a
newer pgvigil, and **3** on
any WARN or a failed instance - so an install script can gate on the code.

A word after the flags (`pgvigil check /etc/pgvigil/pgvigil.yaml`) is a usage error: the file is `-config <path>`.

- **The configuration** loads exactly as `pgvigil run` loads it - the instances and the `alerts:` block (its channels,
  the Slack door, `alerts_dsn`, `base_url`) - or the check fails with the loader's own error. It
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
  would be libpq's defaults: localhost, as the account running the check); otherwise the connect (the dsn read as the
  service's pool reads it: `pool_max_conns` and the other `pool_*` keys stay on this side), its schema level against
  this build, read as `pgvigil run` reads it - through the functions the collector's login may call, so the
  configured login is enough - (behind: an embedded migration the store lacks, *run pgvigil migrate*; ahead: a FAIL,
  this build must not run on it), and its size. Free space beside the store is read only when the connection reached
  this host (a loopback address or a socket) and its `data_directory` is readable to the login and the process: a
  WARN under 10 GiB free or under 30 days of the store's growth (the size a day or two ago, scaled to a day). The
  line says why when it is not read: *the store is on \<address\>*, *data_directory is not readable to this login*,
  *the store's directory is not readable to this process*, *no free-space read on this platform*, or the read's own
  error; and *growth not read* when no reading of a day or two ago is there or the login may not read the beats (the
  collector's login reads no table).
- **The inventory**: a row of Admin > Instances the scheduler would leave out (it breaks a rule the page refuses on
  write), a page instance whose cloud block is not used, or Admin > Instances not read at all (the repository not
  reached, the read refused) is a WARN `inventory` line (exit 3): the file's instances are still tested.
- **Each instance** - the file's and Admin > Instances' enabled inventory, both engines - gets the one connection test
  the Admin page itself uses (10 seconds, at most 8 at a time): who answered, and the collections that will not run
  there and why. A server this build does not know is a WARN beside its OK line: a PostgreSQL major outside 13 to 18,
  a SQL Server major outside 13 to 17 (2016 to 2025; Azure SQL Database and Managed Instance answer 12 whatever they
  run and are not judged by it), or an engine edition pgvigil does not run on (Microsoft Fabric's SQL database, 12,
  among them). Nothing is refused for it: each collection keeps its own version rule and one whose read breaks fails
  alone (a named difference from DBA Dash, which refuses an unknown version or edition unless its check is skipped).
  `-instance <name>` narrows the connection tests; the configuration and repository checks still run. A name that
  matches no instance of the file or the page is a FAIL (exit 3): nothing was tested. The instance lines print in
  name order.

## Keeping a password out of pgvigil.yaml

This section is about an instance's `dsn`. The repository's `dsn`, `reports_dsn`, `alerts_dsn` and an instance's
`pgbouncer:` are PostgreSQL connection strings in the same file and take the same forms below, but an inline password
there is not warned on.

A PostgreSQL instance's `dsn` may hold its password inline, and such a configuration keeps loading - but the
collector warns at every start, `pgvigil check` lists the instance, and `pgvigil run`'s start makes it an info
finding on the instance (*inline password*, on the instance's page and the Findings page, with the host and the fix;
an alert channel sends it only when its `min_severity` is `info`; it clears at the next start after the fix; a
scheduled `pgvigil collect` warns but makes no finding). The form is discouraged:
pgvigil.yaml is pasted, diffed and kept in configuration repositories, and the password goes with it. The other
forms:

- the **whole connection string** in `env:NAME` or `file:/path` - pgvigil reads the variable or the file as the
  complete dsn (`host=... user=... password=...`), never a password alone: a bare password there is read as a
  connection string that does not parse;
- the **password alone** in a libpq passfile (`passfile=` in the dsn) or `password_secret` (AWS Secrets Manager);
- the whole connection string **sealed**:

```
pgvigil secret seal -name pg1 [-config pgvigil.yaml] < the connection string     (typed at a terminal, it is not shown)
dsn: file:/etc/pgvigil/secrets/pg1-3f9c2a1b77e0.dsn                               (Linux)
dsn: dpapi:C:\ProgramData\pgvigil\secrets\pg1-3f9c2a1b77e0.dpapi                    (Windows)
```

The command takes the connection string on stdin - never as an argument - and judges first that the configuration
loads and that `-name` is one of its PostgreSQL instances: give `-config` the service's own file (an elevated prompt
starts in `C:\Windows\system32`, where the default `pgvigil.yaml` is not). It writes `secrets/` beside the
configuration and prints the line to put under the instance in place of its `dsn`.

- **On Linux** the sealed file is plain text with pgvigil.yaml's own owner and group - 0640 in a 0750 folder when
  pgvigil.yaml's group may read (the installer's root:<the service's group> form), 0600 in a 0700 folder when it may
  not - so it is exactly as readable as pgvigil.yaml itself: what it gains is that pgvigil.yaml no longer holds the
  password. The installed service's account must be able to read it as its owner or through its group, or the seal
  is refused and says why (a pgvigil.yaml the service reads through its bits for others is such a case). Run it as
  root or as pgvigil.yaml's owner.
- **On Windows** it is a DPAPI blob at machine scope and a `dpapi:` reference; `secrets/` gets its own protected
  access list - SYSTEM, the Administrators and the installed service's account - whatever the folder above it allows.
  In Windows PowerShell 5.1 type the string at the prompt rather than piping it: 5.1 pipes text to a program in
  ASCII by default, which turns any other character of a password into `?`.

Each seal writes a new file and leaves the previous one, with the password it held: the command names those files,
to delete once pgvigil.yaml points at the new line. `pgvigil uninstall -all` removes the folder.

A `dpapi:` blob opens only on the host that sealed it (machine scope): a configuration folder copied to a new server,
or a host rebuilt, keeps the reference and loses the secret. pgvigil has no key to offer for it and keeps no
encrypted configuration (a named difference from DBA Dash's temporary key: here every secret is a reference read at
each connect). The connect, `pgvigil check` and, for the repository's own dsn, the service's start (exit 3) then say
which reference resolved to nothing and why - the blob that did not open and the fix (seal it again on this host),
the file and the system's error, the variable not set - never what was read. To move a host with its sealed
secrets, `pgvigil config export -password-stdin` opens them on the old host and `pgvigil config import` seals them
again on the new one ([moving pgvigil to a new server](upgrade.md#moving-pgvigil-to-a-new-server)).
