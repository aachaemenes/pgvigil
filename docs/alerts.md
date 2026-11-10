# Alerts out

pgvigil sends its findings to the channels your configuration names: an SMTP relay, a webhook (Microsoft Teams, Slack or
a generic JSON body) and a file drop (one JSON file per alert, for a site with no way out). **Nothing is sent unless a
channel is configured.** With no `alerts:` list pgvigil sends nothing, and the Alerts tab and the send log say so.

The collector sends. It runs a pass every minute inside `pgvigil run`, and `pgvigil alerts -config pgvigil.yaml` runs
one pass by hand. Each pass reads the repository's findings, works out what each channel owes, sends it and records
every attempt in the repository.

## Configuration

The `alerts:` list sits in `pgvigil.yaml` beside the rest:

```yaml
alerts_dsn: env:PGVIGIL_ALERTS_DSN   # the sender's login (IN ROLE pgvigil_alerter); default the repository's dsn
alerts:
  - name: dba-mail                # lower-case letters, digits, '_', '.', '-'; unique
    kind: smtp                    # smtp | webhook | file
    min_severity: warning         # info | warning (the default) | critical
    instances: [erp01, crm01]     # optional
    tags: [env:prod]              # optional; an instance matches when it is listed or holds a listed tag
    quiet_hours: "22:00-07:00"    # optional; nothing is sent inside it, and what is owed goes out when it ends
    timezone: America/Chicago     # the zone of quiet_hours (default UTC)
    repeat: 24h                   # a standing finding is sent again after this (default 24h; disabled = once; at least 5m)
    recovery: true                # a message when the finding clears (default true)
    clear_after: 10m              # how long a finding must stay gone before it is resolved (default 10m; 0 = at once)
    smtp:
      host: relay.example.org
      port: 587                   # default 587 (465 with tls: implicit)
      tls: starttls               # starttls (default) | implicit | none (loopback relay only)
      ca_file: /etc/pgvigil/ca.pem   # optional: the CA of an internal relay
      username: pgvigil           # optional: plain, env:NAME or file:/path
      password: file:/etc/pgvigil/smtp.pass   # env:NAME or file:/path only
      from: pgvigil@example.org
      to: [dba-team@example.org]
      helo: pgvigil01.example.org # the EHLO name (default this host's name)

  - name: dba-teams
    kind: webhook
    min_severity: critical
    webhook:
      url: env:PGVIGIL_TEAMS_URL  # env:NAME or file:/path only: the URL carries the webhook's token
      format: teams               # teams | slack | json (the default)
      ca_file: /etc/pgvigil/ca.pem   # optional

  - name: spool
    kind: file
    file:
      dir: /var/spool/pgvigil/alerts
```

A channel covers every instance when it lists no instance and no tag. Tags are written as in `instances:` (`prod`,
`env:prod`). An error in the list stops `pgvigil run` and `pgvigil alerts` with exit code 3 (a configuration error).
A secret given through `env:` or `file:` is read when the command starts.

## What is sent, and when

A finding's identity is its instance, source, setting and value, with every free-standing number in the value
replaced by `#`. "lowest 99.0 %, average 99.0 % over 10 samples" and "... over 11 samples" are one standing finding,
while the digits inside a name (`orders_idx1`, `orders_idx2`) keep two indexes apart.

| Event | When |
|---|---|
| new (firing) | A finding at or above the channel's severity, in its scope, that the channel has not sent. |
| new (escalated) | The finding's severity rose above the one sent. It goes out at once. |
| still open (repeat) | The repeat interval has passed since the last send. |
| resolved | The finding has been gone from the findings for `clear_after` (default 10 minutes, so a collection gap or a finding at a time window's edge does not send a recovery and a new alert a minute later). Sent when `recovery` is on; otherwise the alert is closed without a message (the log's outcome `cleared`). |
| closed without a message | The instance was deactivated or removed, or the channel's instances or tags no longer cover it: nothing was fixed, so no recovery is sent. |

A finding that falls below the channel's severity floor but stays (critical to warning on a critical channel) keeps its
alert open and quiet: no repeat, no recovery. If it rises again it is not sent again until the repeat interval.

An SMTP message or a webhook post carries up to 25 alerts, each line cut at 600 bytes; more go in the next message of
the same pass. A file drop
writes one file per alert: `<UTC time>-<event>-<channel>-<key>.json`. Each file is written under a temporary name and
renamed, so a reader never sees half of one.

A send that fails moves nothing: the next pass owes the same alerts. Inside `pgvigil run`, a failing channel is tried
again after 1, 2, 4, 8, 16 and then every 30 minutes, and the other channels go on. Delivery is **at least once**: a
send that went out but whose record in the repository then failed (the repository unreachable, the process killed) is
sent again by the next pass. Two senders at the same time (the service and a `pgvigil alerts` by hand) do not both
send: a pass holds an advisory lock in the repository, and a second sender skips its pass.

One collector sends alerts: name the `alerts:` list in one configuration. A collector without the list leaves the
channels as recorded. A channel removed from the list keeps its open alerts in the repository but leaves the Findings
column; renamed, it is a new channel and sends the standing findings again.

## Destinations and the rules they keep

- **Only the configured destination.** A webhook's redirect is never followed: the send is refused, and the log says
  so (outcome `refused`). The HTTP client ignores the environment's proxy settings. SMTP connects to the configured
  host and port only.
- **TLS is Go's crypto/tls**, so a FIPS build of pgvigil uses its validated module, at TLS 1.2 or later. `starttls`
  refuses a relay that does not offer STARTTLS; it never falls back to plain text. A login is never sent over plain
  SMTP.
- **Plain transport only on loopback.** `tls: none` and an `http://` webhook are accepted only for 127.0.0.1, ::1 or
  localhost (a local relay or forwarder).
- **Secrets stay out of the file and out of the screen.** A webhook URL and an SMTP password come through `env:` or
  `file:`. The UI and the log show a webhook's scheme and host only, never its path or token, and an error text never
  carries the URL.
- **The air-gapped site** uses the file drop. pgvigil writes into a directory and the site's own tooling picks the
  files up.

## Where it shows

- **Alerts** (a root tab) lists the channels as last recorded: kind, destination, severity floor, scope, quiet hours,
  repeat, recovery, the last send, the last attempt with its outcome and error, and whether the configuration still
  names the channel. Below them are the alerts open now and the send log of the time range.
- **Findings** gains a column, *alerted*: when the finding was last sent and to which channels.

## In the repository (migration 0059)

| Object | What it holds |
|---|---|
| `pgvigil.alert_channels` | The channels as configured (the last pass's record). |
| `pgvigil.alert_state` | Per channel and finding: first sent, last sent, sends, the severity sent, cleared, recovery sent. |
| `pgvigil.alert_log` | Every attempt (monthly partitions): channel, destination, the alerts by event, outcome (`sent`, `failed`, `refused`, `cleared`, `none`) and the error text. |
| `pgvigil.alert_findings`, `pgvigil.findings_alerts`, `pgvigil.alert_sent` | Findings with their key, and with their alert columns. |

The sender connects as `alerts_dsn`, a login in the role `pgvigil_alerter` that migration 0059 creates. The role is a
member of `pgvigil_reader`, so it reads the findings. It also holds INSERT and UPDATE on the alert tables:

```sql
CREATE ROLE pgvigil_alerts LOGIN PASSWORD '<set-me>' IN ROLE pgvigil_alerter;
```

The collector's login (`pgvigil_collector`) gets nothing here. The repository's access contract keeps it away from
what other instances sent, and it may not call the alert functions. The functions `alert_channels_sync`,
`alert_mark`, `alert_due` and `alert_record` run as their caller. A reader login may call `alert_due`, which reads
only what a reader can read anyway, and fails in the others for want of a write privilege. One function runs as the
owner, `alert_log_partition`: it creates `alert_log`'s month partition for a time within a day of now, nothing else.
Without `alerts_dsn` the sender uses the repository's dsn: that works when it is the owner (a demo, a one-box
install), and fails with "permission denied" when it is the collector's login.

## Proof

`scripts/proof-alerts.sh` runs on a sandbox PostgreSQL with the demo fleet, as a `pgvigil_alerter` login. It starts
its own loopback SMTP sink and HTTP listener and covers these cases:

- The role contract: the collector login is refused, a reader cannot write, the alerter reads.
- No channel: nothing is sent, and the log's `none` row is written.
- SMTP, webhook and file-drop channels receive the critical findings.
- A redirect is refused and not followed.
- An unreachable destination is logged, and the other channels still send.
- A channel inside its quiet hours holds its alerts.
- The repeat interval: a finding is sent once over two runs, then again after the interval.
- A finding that falls under a channel's severity floor and comes back is held, not resolved and not sent again.
- Recovery messages are sent, a channel without recovery closes its alerts without a message, and the clear delay
  holds a recovery until it has passed.
- A deactivated instance's alerts close without a recovery message.
- The loop inside `pgvigil run` keeps running past a failing channel.
- The Alerts API and the Findings column.
