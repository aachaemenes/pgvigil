# Support and problem reports

Questions and problems go to **support@pgvigil.com**. A security problem does not: see [Security](#security) below.

pgvigil never sends a problem report by itself. Both ways of reporting a problem on this page produce something you read first and send yourself.

## Report a problem from the UI

The **About** page (the About link in the bar) shows what this pgvigil is: the server's version line, the repository's PostgreSQL version and migration level, the monitored engines counted by version and platform, and your browser. It opens when the repository does not answer, too; what it could not read then says "not read".

**Report a problem** on that page is a `mailto:` link: it opens a new mail to support@pgvigil.com in your own mail program, with those same lines under a space for your description. The page shows the lines before you click, and **Copy these lines** puts them on the clipboard for a machine without a mail program.

What the mail starts with:

```
What happened, what you expected instead, and the page it was on:



--- filled in by pgvigil; change or remove anything before you send ---
pgvigil: pgvigil v0.4.0 (go1.27.3 linux/amd64; fips140 off)
Repository: PostgreSQL 18.1, migration 0089_alert_pagerduty
Monitored: 3 x PostgreSQL 18.1 (aurora); 1 x SQL Server 16.0.4135.4 (onprem)
Browser: Mozilla/5.0 ...
```

No instance, host, database or user name is in it, and not the address of your pgvigil. A SQL Server is written by its build number. At most twelve version lines are listed, and fewer when the mail would grow past what mail programs take in a link; the rest is a count.

## A report with more detail: `pgvigil report`

On the host that runs pgvigil:

```sh
pgvigil report -config pgvigil.yaml
```

writes `pgvigil-report-<UTC time>.zip` into the folder it is run in, prints what it wrote, and stops. On Linux and macOS the file is readable by its owner alone (mode 0600); on Windows the folder's permissions apply. It connects to the repository and to nothing else: no monitored server, no network address of the project's. Attach the zip to your mail after you have read it.

| File | What it holds |
| --- | --- |
| `README.txt` | what the files are and where the zip goes |
| `version.txt` | the line of `pgvigil version`, the operating system and its release name, the CPU count, the build's revision and the versions of the main modules (the database drivers, the YAML reader, the AWS SDK) |
| `config.yaml` | the configuration file, masked (below), and the result of the check the commands run on it |
| `repository.txt` | the repository's server version, its migration level against this binary's, the last runs counted by status |
| `instances.txt` | engine, platform, server version, active or not and last seen ('not read yet (added <time>)' for an instance added on Admin > Instances that no read has reached), per instance the repository knows |
| `collection-errors.txt` | the collections whose last run failed and the newest errors of the collection log, with their notes |

The zip is still written when the configuration does not load or the repository does not answer: the report then says that, with the reason. That is when a report is needed.

From the repository the command reads the instance list, the last run of each collection and the collection log, and nothing else: no collected statement, no row of monitored data.

### What is masked in `config.yaml`

`config.yaml` is written value by value from a short list of settings; it is not the file with some lines blacked out.

- **Shown as written**: `engine`, `platform`, `query_text`, intervals and switches (`interval`, `explain_analyze`, `hypo_index`, `explain_timeout`, `every`), a custom check's `rule` and `compare`, thresholds (`archive_warn_minutes`, `latency_warn_secs`, `warning`, `critical`, the numbers under `mssql_thresholds`), collection names and their intervals (`schedules`, `disabled`), `actions`, `ui.group_by`, an AWS `region`, and of an alert channel its `kind`, `min_severity`, `quiet_hours`, `timezone`, `repeat`, `recovery`, `clear_after`, `port`, `tls` and `format`, each only while the value has the shape of a setting (a word, a number, a duration).
- **`env:NAME`** stays as written under the keys pgvigil reads it from (a connection string, a webhook address, a key, a mail login), with a note saying whether the variable is set where the command runs. A service that cannot find its variable is a common problem, and the name is not the secret. A tag written `env:prod` is a tag, and masked like any tag.
- **`file:/path`** is written as `file:<masked>`, with a note saying whether the file was read.
- **Everything else is `<masked>`**: every connection string, password, webhook address, routing key, host, user, database, address and recipient, every tag and tag value, a custom check's name and statement, a channel's name, the database patterns of `backup_exclude`, and any value under a key that names a secret wherever it stands.
- **A key that is no key of pgvigil's configuration** (a misspelt one, one of your own) is written as `<masked-key-N>` and its values are masked. A YAML anchor and its aliases are renamed `a1`, `a2`, ...; a tag of your own (`!name`) is dropped.
- **Instance names** are written as `instance-1`, `instance-2`, ... in the order of the file. The command prints which is which on your terminal; that list is not in the zip. `-names` keeps the names of the `instances:` list; a channel's or a custom check's own `instances:` list stays masked.
- **Comments are not copied**: a commented-out line can hold anything.
- A file that is not valid YAML is not copied in any form.

### What is taken out of error text

The error text in the report (a collection's note, the reason of a failed check or a refused connection) is what a server or a driver wrote. It passes a filter of its own:

1. every value masked in the configuration, the contents behind every `env:` and `file:`, the parts of every connection string (password, host, user, database) and the quoted literals of a custom check's statement are taken out; instance names become their aliases;
2. then whatever has the shape of a credential, an address or a name goes, whatever its source: the user and password of a URL, the path and query of an `http(s)` address, a value after a name that ends in `password`, `secret`, `token` or `api_key` (`PGPASSWORD=`, `client_secret=`), a `host=`, `user=` or `database=` value, the quoted name after `user`, `role`, `database` or `host` (`user "x"`, `database "y"`), an IPv4 or IPv6 address other than loopback, the host of a failed lookup or dial.

If an `env:` variable or a `file:` of the configuration cannot be read where you run the command (a login shell does not have the service's variables), step 1 does not know what it holds. The command says so on the terminal and in `README.txt`, and `config.yaml` marks each such value; step 2 still applies. Run the report where the service's variables are set for the full filter.

**What can remain**: what the configuration does not hold and no shape gives away, such as a table named in a server's message, a piece of the statement a collection ran (pgvigil's own, or a custom check's) or a host of an instance that another collector reads into the same repository; a value shorter than four characters, a bare number, and the words that name nothing (`postgres`, `master`, `localhost`, `pgvigil`), which are never searched for. Read `collection-errors.txt` before you send the zip.

### Options

| Option | Meaning |
| --- | --- |
| `-config file` | the configuration file (default `pgvigil.yaml`) |
| `-out file.zip` | where to write; an existing file is never replaced |
| `-dsn value` | the repository connection string for the reads, as `env:NAME` or `file:/path` (a string typed on the command line works too, and shows in the process list); the default is the configuration's `repository.dsn` |
| `-names` | keep the instance names |
| `-errors N` | how many of the newest collection errors to include (default 200, at most 5000) |

The collector's own login writes to the repository and may not read its tables: with it the report still holds the versions and the migration level, and says which parts it could not read. Run it with the repository owner's configuration, or with `-dsn` and a login in the role `pgvigil_reader`, for the instances and the errors.

The command opens two sessions on the repository, both read only (`default_transaction_read_only`) with 10 seconds to connect and 10 seconds a statement: its own for the reads, and a short one that asks the schema function whether the repository is at this binary's level. The whole of it ends after two minutes at most.

Exit codes: 0 the zip was written (or `-h` printed the options); 1 it could not be written (the file exists, the folder is not writable); 2 a bad command line.

## Security

Report a vulnerability privately through GitHub: the repository's **Security** tab, **Report a vulnerability** (<https://github.com/aachaemenes/pgvigil/security/advisories/new>). The report stays between you and the maintainers until the advisory is published. Do not send a vulnerability by mail, and do not attach a problem report to it unless asked.

## What to put in a mail

- What happened and what you expected, and the page or the command it was on.
- The lines of the About page, or the zip of `pgvigil report`.
- Whether it happens every time, and since which version or change.

Never send a password, a connection string or a key. If one is needed to explain the problem, describe its shape instead.
