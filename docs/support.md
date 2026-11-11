# Support and problem reports

Questions and problems go to **support@pgvigil.com**. A security problem does not: see [Security](#security) below.

pgvigil never sends anything to that address, or anywhere else, by itself. Both ways of reporting a problem on this page produce something you read first and send yourself.

## Report a problem from the UI

The **About** page (the link at the right end of the bar) shows what this pgvigil is: the server's version line, the repository's PostgreSQL version and migration level, the monitored engines counted by version and platform, and your browser.

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

No instance, host, database or user name is in it, and not the address of your pgvigil. At most twelve version lines are listed; a larger fleet ends with a count of the rest.

## A report with more detail: `pgvigil report`

On the host that runs pgvigil:

```sh
pgvigil report -config pgvigil.yaml
```

writes `pgvigil-report-<UTC time>.zip` into the folder it is run in, prints what it wrote, and stops. On Linux the file is readable by its owner alone (mode 0600); on Windows the folder's permissions apply. It connects to the repository and to nothing else: no monitored server, no network address of the project's. Attach the zip to your mail after you have read it.

| File | What it holds |
| --- | --- |
| `README.txt` | what the files are and where the zip goes |
| `version.txt` | the line of `pgvigil version`, the operating system and its release name, the CPU count, the build's revision and the versions of the main modules (the database drivers, the YAML reader, the AWS SDK) |
| `config.yaml` | the configuration file, masked (below), and the result of the check the commands run on it |
| `repository.txt` | the repository's server version, its migration level against this binary's, the last runs counted by status |
| `instances.txt` | engine, platform, server version, active or not and last seen, per instance the repository knows |
| `collection-errors.txt` | the collections whose last run failed and the newest errors of the collection log, with their notes |

The zip is still written when the configuration does not load or the repository does not answer: the report then says that, with the reason. That is when a report is needed.

### What is masked

`config.yaml` is written value by value from a short list of settings; it is not the file with some lines blacked out.

- **Shown as written**: `engine`, `platform`, `query_text`, intervals and switches (`interval`, `explain_analyze`, `hypo_index`, `explain_timeout`, `every`), a custom check's `rule` and `compare`, thresholds (`archive_warn_minutes`, `latency_warn_secs`, `warning`, `critical`, everything under `mssql_thresholds`), collection names and their intervals (`schedules`, `disabled`), `actions`, `ui.group_by`, an AWS `region`, and of an alert channel its `kind`, `min_severity`, `quiet_hours`, `timezone`, `repeat`, `recovery`, `clear_after`, `port`, `tls` and `format`, each only while the value has the shape of a setting (a word, a number, a duration).
- **`env:NAME`** stays as written, with a note saying whether the variable is set where the command runs. A service that cannot find its variable is a common problem, and the name is not the secret.
- **`file:/path`** is written as `file:<masked>`, with a note saying whether the file was read.
- **Everything else is `<masked>`**: every connection string, password, webhook address, routing key, host, user, database, address and recipient, every tag and tag value, a custom check's name and statement, a channel's name, and the value of any key the list above does not hold, so a new or misspelt key is masked, never shown. A mapping key that is not a plain name is written as `<masked-key>`.
- **Instance names** are written as `instance-1`, `instance-2`, ... in the order of the file. The command prints which is which on your terminal; that list is not in the zip. `-names` keeps the real names.
- **Comments are not copied**: a commented-out line can hold anything.
- A file that is not valid YAML is not copied in any form.

The error text in the report (a collection's note, a refused connection) is what a server or a driver wrote, and it passes a second filter: every value masked in the configuration, the contents behind every `env:` and `file:`, and the parts of every connection string (password, host, user, database) are taken out of it; instance names become their aliases; then whatever has the shape of a credential or an address goes too, whatever its source: the user and password of a URL, the path and query of an `http(s)` address, a `password=`, `secret=`, `token=` or `api_key=` value, a `host=`, `user=` or `database=` value, an IPv4 address other than loopback, the host of a failed lookup or dial.

**What can remain**: a name the configuration does not hold, such as a table in a server's message or a host of an instance that another collector reads into the same repository; a value shorter than four characters (it is not searched for: a two-letter user would take ordinary words apart); an IPv6 address. Read `collection-errors.txt` before you send the zip. Statement text and rows of monitored data are never read for the report.

### Options

| Option | Meaning |
| --- | --- |
| `-config file` | the configuration file (default `pgvigil.yaml`) |
| `-out file.zip` | where to write; an existing file is never replaced |
| `-dsn value` | the repository connection string for the reads, also as `env:NAME` or `file:/path`; the default is the configuration's `repository.dsn` |
| `-names` | keep the instance names |
| `-errors N` | how many of the newest collection errors to include (default 200, at most 5000) |

The collector's own login writes to the repository and may not read its tables: with it the report still holds the versions and the migration level, and says which parts it could not read. Run it with the repository owner's configuration, or with `-dsn` and a login in the role `pgvigil_reader`, for the instances and the errors. The session is read only (`default_transaction_read_only`), with a 10 second limit to connect and per statement.

Exit codes: 0 the zip was written; 1 it could not be written (the file exists, the folder is not writable); 2 a bad command line.

## Security

Report a vulnerability privately through GitHub: the repository's **Security** tab, **Report a vulnerability** (<https://github.com/aachaemenes/pgvigil/security/advisories/new>). The report is visible to the maintainer alone until a fix is released. Do not send a vulnerability by mail, and do not attach a problem report to it unless asked.

## What to put in a mail

- What happened and what you expected, and the page or the command it was on.
- The lines of the About page, or the zip of `pgvigil report`.
- Whether it happens every time, and since which version or change.

Never send a password, a connection string or a key. If one is needed to explain the problem, describe its shape instead.
