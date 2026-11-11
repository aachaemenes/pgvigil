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
| resolved | The finding has been gone from the findings for `clear_after` (default 10 minutes, so a finding at a time window's edge does not send a recovery and a new alert a minute later), **and** the collector has read the instance successfully since the finding went missing. An instance left unread (unreachable, the collector stopped, a gap of any length) holds its alerts open: its time-windowed findings leave the view, but nothing was fixed. Sent when `recovery` is on; otherwise the alert is closed without a message (the log's outcome `cleared`). |
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

## Alert rules on a charted metric

A finding is a rule pgvigil ships. An **alert rule** is one you make: any metric of an instance's
[Metrics](metrics.md) page, above or below a value, for a number of minutes.

- **The rule.** One metric (for example *Sessions: idle in transaction* or, on SQL Server, *Requests: processes
  blocked*), `above` or `below`, a **warning** value, a **critical** value or both (critical at or beyond warning),
  and **for n minutes** (0 to 1440; the default is 5). The values are in the metric's own unit, which the form names
  (a count, percent, seconds, bytes per second).
- **What it covers.** Every instance, the instances of one tag, or one instance. Where two rules on one metric cover
  an instance, the narrower one is in force: an instance's own rule wins over a tag's, a tag's over the fleet's (two
  tags of one instance: the newer rule). A tag or an instance rule is therefore that scope's **threshold override**,
  in either direction: stricter or looser than the wider rule.
- **One database.** A metric of the *Database* family (commits, cache hit ratio, temp bytes ...) can name a
  database: the rule then watches that database's own series, and overrides nothing for the instance's summed
  series. The other way round too: a rule that names no database watches the series summed over all databases, and
  never one database by itself.
- **When it fires.** The alert sender judges every rule in force once a pass, on the samples the collector already
  stores. A level is reached when the newest sample is beyond its value **and** the unbroken run of samples beyond
  it spans the rule's minutes, measured from the run's first sample to its newest: a single late sample never fires
  a rule by the clock alone. Until then the rule is *pending*. With 0 minutes the first sample beyond the value fires.
- **No data is not a recovery.** A metric with no sample newer than its limit (10 minutes; 30 for the IO counters,
  15 for the host) reads *no data*. A firing rule whose series stops is **held** open, and its alert says since when
  no fresh sample came: the collector may be down, or the instance. When the samples come back still beyond the
  value, after a gap of any length, the rule goes on firing: no recovery, no second alert. It recovers when a sample
  inside the value arrives.
- **Editing a rule that fires.** The alert stays the same alert: a value changed keeps it open (it may move between
  warning and critical), and the rule's "last fired" goes with its successor. Edited while held, the rule keeps
  firing if its last sample is still beyond the new value, and stops if it is not. **Ending or switching off a rule
  that fires closes its alert the way a finding that went away does: the channels send their recovery message**,
  though nothing was fixed; the rule log says who ended it.
- **How it is sent.** A firing rule is a finding of source `alert rule`, so everything above applies unchanged: the
  channels and their severity floors and scopes, the repeat interval, the recovery message after `clear_after`, quiet
  hours, and acknowledge, mute, silence and blackout ([acknowledge.md](acknowledge.md)). A rise from warning to
  critical is sent at once as *escalated*; a change of the rule's value keeps one alert open.
- **Who judges.** The sender's pass. **With no channel configured no pass runs, and the rules are not judged**: the
  Alert rules page says so, and the Metrics grid still colours its figures by the thresholds.

Rules are made on the **Alert rules** page (a root tab: *New rule*) and from any row of an instance's Metrics grid
(*New threshold*, *Edit*, *Override here*). Edits need the UI login and the actions door's audit login, as
acknowledgements do; without them the pages are read only and say why. Nothing is updated in place except a rule's
on / off switch: an edit ends the rule and writes its successor, an *End* keeps the row, and every attempt, refused
ones included, is in the rule log with who and from where.

Limits to know: a rule compares one sample series with a fixed value (no rate of change, no comparison with last
week, no rule on a count of log events); the sender's cadence is one minute, so "for 0 minutes" still waits for the
next pass; a counter's sample is its rate over the collection interval, and a counter reset gives no sample for that
interval. Where two tags of one instance each hold a rule on one metric, the rule made or edited last is in force.
The sender gives the evaluation 30 seconds a pass: past that the rules keep their last states for that pass, the
pass's summary line says "alert rules not judged" with the reason, and the findings still go out. A rule on a
database that is later dropped stays held until someone ends the rule.

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
- **PagerDuty** (`kind: pagerduty`, `pagerduty: {routing_key: env:PD_KEY}`, migration 0089) sends each alert as its own
  Events API v2 event: firing, escalated and repeat trigger, a recovery resolves, all under one dedup key per instance
  and finding (`pgvigil:<instance>:<finding>`, hashed past 255 bytes), so PagerDuty keeps one incident per finding and
  closes it when the finding clears; `recovery: false` is refused for this kind. The routing key (the service's
  integration key) comes through `env:` or `file:` and is never shown or logged; the URL may name
  events.pagerduty.com (the default) or events.eu.pagerduty.com only. A 429 is a failed send the next pass repeats.
- **The air-gapped site** uses the file drop. pgvigil writes into a directory and the site's own tooling picks the
  files up.

## Where it shows

- **Alerts** (a root tab) lists the channels as last recorded: kind, destination, severity floor, scope, quiet hours,
  repeat, recovery, the last send, the last attempt with its outcome and error, and whether the configuration still
  names the channel. Below them are the alerts open now and the send log of the time range.
- **Findings** gains a column, *alerted*: when the finding was last sent and to which channels.
- **Alert rules** (a root tab) lists the rules with their on / off switch, what each covers, where it is in force
  and where it fires, when it last fired; under them the state of every rule per instance as the sender last judged
  it, and the rule log. A firing rule is an open alert on the Alerts tab; it is not listed on the Findings tab.
- **Metrics** (an instance tab) shows each counter's thresholds and colours its figures by them
  ([metrics.md](metrics.md)).

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
owner, `alert_log_partition`: it creates `alert_log`'s month partition for a time within a day of now, nothing else,
and only for a login in `pgvigil_alerter` (or the schema's owner).
Without `alerts_dsn` the sender uses the repository's dsn: that works when it is the owner (a demo, a one-box
install), and fails with "permission denied" when it is the collector's login. Only a configuration **with**
channels needs `alerts_dsn`: without an `alerts:` list, `pgvigil run` logs "alerts off" and never touches the alert
tables, and `pgvigil alerts` prints "no channel configured: nothing sent" and exits 0 whatever the login.

## In the repository (migration 0085)

| Object | What it holds |
|---|---|
| `pgvigil.metric_catalog` | Every metric a rule may name (`family.metric`): engine, label, unit, whether it has a per-database series, how old its newest sample may be. |
| `pgvigil.alert_rules` | The rules; an edit ends a row and writes its successor (`replaces`), so the table is its own history. |
| `pgvigil.alert_rule_log` | Every attempt from the UI, done or refused: who, from where, what. Not purged, like the acknowledge log. |
| `pgvigil.alert_rule_state` | The sender's last evaluation per rule in force, instance and series: `ok`, `pending`, `warning`, `critical` or `nodata`, held or not, the newest sample, since when. |
| `pgvigil.alert_rule_fired` | Per rule: when it last began to fire, on which instance, how often. |
| `pgvigil.alert_rule_scope`, `pgvigil.alert_rules_effective` | Every live rule on every instance it covers; the one in force per instance, metric and series. |
| `pgvigil.alert_rule_findings` | The firing rows as findings; `pgvigil.alert_findings` (0059) lists them beside `pgvigil.findings`. |

`pgvigil.alert_rules_run(at)` is the sender's call (its login needs nothing new: migration 0085 grants
`pgvigil_alerter` the state tables). `pgvigil.alert_rule_eval(at)` is the same judgement read only, for a look by
hand. `pgvigil.import_alert_rule(at, payload)` is the only way a rule is written: it runs as the owner for the
collector role, which is the actions door's audit login, and checks what a rule may hold (a known metric, an instance
of the metric's engine, one live rule per metric, scope with its tag or instance, and database).

## Proof

`scripts/proof-alert-rules.sh` covers the rules on a sandbox PostgreSQL: the role contract (the collector writes
rules only through the function, the sender stores the state and writes no rule, a reader reads); the write door
(no session, no header, malformed and refused requests, a server without the login); a rule on real held sessions
that stays pending under its minute, fires once, is not sent again when its sample changes, and clears once after
the sessions end and the instance is read; a tag's rule winning over the fleet's in both directions; a rule on one
database's series beside a fleet rule on the summed one; edit, switch and end; the hold (seeded: no sample, then
samples back beyond the value after a long gap, an edit, a sample inside); the audit. On a PostgreSQL 13 container
it applies every migration and runs the grid, every family's read, a rule added, judged and listed as a finding;
edit, end and the switch run on the 14+ server only.

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
