# Alerts out

pgvigil sends its findings to the channels your configuration names: an SMTP relay, a webhook (Microsoft Teams, Slack,
Discord, Google Chat or a generic JSON body), PagerDuty (its Events API v2), Opsgenie (its Alert API v2) and a file drop
(one JSON file per alert, for a site with no way out). **Nothing is sent unless a channel is configured.** With no `alerts:` list pgvigil sends nothing, and the Alerts tab and the send log say so.

The collector sends. It runs a pass every minute inside `pgvigil run`, and `pgvigil alerts -config pgvigil.yaml` runs
one pass by hand. Each pass reads the repository's findings, works out what each channel owes, sends it and records
every attempt in the repository.

## Configuration

The `alerts:` list sits in `pgvigil.yaml` beside the rest:

```yaml
alerts_dsn: env:PGVIGIL_ALERTS_DSN   # the sender's login (IN ROLE pgvigil_alerter); default the repository's dsn
alerts_base_url: https://pgvigil.example.org   # optional: the UI's address; every alert line then links to its page
alerts:
  - name: dba-mail                # lower-case letters, digits, '_', '.', '-'; unique
    kind: smtp                    # smtp | webhook | file | pagerduty | opsgenie
    min_severity: warning         # info | warning (the default) | critical
    instances: [erp01, crm01]     # optional
    tags: [env:prod]              # optional; an instance matches when it is listed or holds a listed tag
    quiet_hours: "22:00-07:00"    # optional; nothing is sent inside it, and what is owed goes out when it ends
    timezone: America/Chicago     # the zone of quiet_hours (default UTC)
    repeat: 24h                   # a standing finding is sent again after this (default 24h; disabled = once; at least 5m)
    recovery: true                # a message when the finding clears (default true)
    clear_after: 10m              # how long a finding must stay gone before it is resolved (default 10m; 0 = at once)
    max_per_hour: 30              # optional send cap (default 0 = none); see "The send cap"
    templates:                    # optional; see "Templates"
      subject: {firing: "{severity}: {setting} on {instance}"}
      line: {resolved: "OK again: {instance} {setting}"}
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
      format: teams               # teams | slack | discord | googlechat | json (the default)
      ca_file: /etc/pgvigil/ca.pem   # optional

  - name: spool
    kind: file
    file:
      dir: /var/spool/pgvigil/alerts

  - name: ops
    kind: opsgenie
    opsgenie:
      api_key: env:PGVIGIL_OG_KEY # an API integration's key; env:NAME or file:/path only
      url: https://api.eu.opsgenie.com   # optional: the EU region (default https://api.opsgenie.com)
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
| resolved | The finding has been gone from the findings for `clear_after` (default 10 minutes, so a finding at a time window's edge does not send a recovery and a new alert a minute later), **and** the collector has read the instance successfully since the finding went missing. An instance left unread (unreachable, the collector stopped, a gap of any length) holds its alerts open: its time-windowed findings leave the view, but nothing was fixed. 'Read successfully' means a collection that finished with status ok; a partial read (one database or one source failed) does not count. Under `pgvigil run` the every-minute reads give one each minute (PostgreSQL: activity; SQL Server: waits, memory and the waiting tasks, which need VIEW SERVER STATE), so a known limit stays: an instance with those reads off, or a SQL Server login without VIEW SERVER STATE before SQL Server 2022, can hold a resolved alert open until another collection reads it whole. Sent when `recovery` is on; otherwise the alert is closed without a message (the log's outcome `cleared`). |
| closed without a message | The instance was deactivated or removed, or the channel's instances or tags no longer cover it: nothing was fixed, so no recovery is sent. PagerDuty and Opsgenie are the exception: they close their incident, or it would stay open for good. |

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

## The address of an alert, templates, the send cap, Send test

- **Every alert carries the address of its page.** With `alerts_base_url` set (the UI's address as a reader opens it:
  `https://host[:port][/path]`, no query; `env:` and `file:` work), every alert line ends with
  `<base>/#/alert?k=<finding key>&t=<first send, Unix seconds>` (`alerts_base_url` at most 200 bytes; the key and the time follow it). The address is added
  after the line is cut at 600 bytes, so it is never cut. A template that places `{url}` itself keeps it where it
  stands while the line fits; a longer line is cut and the whole address follows it, once. The JSON body, the file drop, PagerDuty
  (`links` and `custom_details.url`) and Opsgenie (`details.url`) carry it as a field too. Without the setting no link is
  sent, and the Alerts tab says so.
- **Templates.** `templates: {subject: {...}, line: {...}}` per channel, each keyed by `firing`, `escalated`, `repeat` or
  `resolved` (escalated falls back to firing's; an event without its own template gets the built-in text). The subject is
  a message's headline (the SMTP Subject, a chat post's first line, Opsgenie's message); the line is each alert's line.
  Placeholders: `{event}`, `{severity}`, `{instance}`, `{source}`, `{setting}`, `{value}`, `{detail}`, `{suggested}`,
  `{first_sent}`, `{finding_at}` (UTC, RFC 3339), `{sends}`, `{url}`, `{channel}`, and in a subject only `{count}` (the
  alerts in the message) and `{summary}` (the built-in headline). An unknown placeholder, an unknown event or a line
  break in a subject stops the command with exit code 3, and so does a template where nothing would use it: on a file
  drop (it writes the alert's fields), or a line template on a `json` webhook (its body carries the fields; a subject
  template is its `summary`). A message of several events takes the subject of its leading
  one: a firing or escalated alert, else a repeat, else the recoveries. The Alerts tab shows which templates a channel
  has, never their text.
- **The send cap.** `max_per_hour: n` (1 to 100000; 0 = none) caps the alerts a channel sends in any 60 minutes, counted
  from its `sent` log rows. What is over the cap is held, logged as one row of outcome `capped` per pass, and owed again
  by the next pass: new and escalated alerts go first (critical first), then the recoveries, then the repeats. A held
  recovery leaves its alert open until it goes out. The Alerts tab shows each channel's use of its cap.
- **Send test.** The Alerts tab's *Send test* on a channel row asks the sender for a test message. The request is a row
  (`pgvigil.alert_tests`, through the actions door like an acknowledgement: the UI login and the audit login). The
  sender's next pass, within a minute while `pgvigil run` is up, sends it to that channel and records the
  destination's answer. The serve process never holds a channel's secret. A test goes out whatever the quiet hours,
  back-off or cap. PagerDuty and Opsgenie get the test and its resolve at once, so no incident stays open (on Opsgenie
  the close waits, up to about 10 seconds, for Opsgenie to have created the test alert). A channel takes one waiting
  request at a time, and one test in two minutes: a test reaches a real destination. A request no sender answered within the hour reads *no answer*: no running
  sender names that channel. The send log shows the attempt as outcome `test` (or `failed` / `refused`).

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
  closes it when the finding clears - also when the finding is cleared without a fix (the instance deactivated or
  removed, the channel no longer covering it), which on the other kinds but Opsgenie sends nothing; `recovery: false` is refused
  for this kind. The routing key (the service's
  integration key) comes through `env:` or `file:` and is never shown or logged; the URL may name
  events.pagerduty.com (the default) or events.eu.pagerduty.com only. A 429 or a 5xx is a failed send: the channel waits 1, 2, 4 ... 30 minutes and the next pass sends again.
- **Opsgenie** (`kind: opsgenie`, migration 0093) sends each alert as its own request to the Alert API v2 under one
  alias per instance and finding (`pgvigil:<instance>:<finding>`, hashed past 512 bytes): a firing or a repeat creates
  (Opsgenie folds a create on an open alias into its alert), an escalation creates and raises the priority, a recovery
  closes by alias, and so does a finding cleared without a fix, as on PagerDuty; `recovery: false` is refused. Priority
  P1 for critical, P3 for warning, P5 for info. The key (an API integration's key, a UUID) comes through `env:` or
  `file:` and is sent only in the `Authorization: GenieKey` header; the URL may name api.opsgenie.com (the default) or
  api.eu.opsgenie.com only. A 429 or a 5xx is a failed send, retried as any.
- **Discord and Google Chat** are webhook formats (`format: discord`, `format: googlechat`). Discord takes the
  message as its `content` with `allowed_mentions` empty (a finding's text never pings `@everyone` or a role); Google
  Chat takes a text message. Both have a text limit (Discord 2000 characters, Google Chat 4096): a message carries only
  as many alerts as their lines fit, the rest go in the next message of the same pass; no alert line is cut. Their URLs
  hold a token (Google Chat's in its query), so they come through `env:` or `file:` like every webhook URL, and only the
  scheme and host are shown.
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
- **The alert's page** (`#/alert?k=<finding key>`, the address every sent alert carries): the card (severity, instance,
  the finding's value now or the last value sent, its threshold: an alert rule's value or the finding's suggested
  value, this firing's first and last send, the state, how many times it fired), the detail, the **fix** statement
  with *Copy*, every firing of the alert, every send attempt that carried it, and what was done with it
  (acknowledgements, notes, mutes, dismissals). Links open the instance's pages (Summary, Findings, Metrics,
  Performance, Running queries at the firing, Waits, Logs; SQL Server's own pages for a SQL Server instance) pinned to
  the firing's window, from half an hour before it to half an hour after it cleared; the *now* switch points them at the
  last hour instead. *Export* keeps the page as a workbook (the report); *Copy link* copies its address. There is no
  chart drawn on the page itself: the Metrics and Performance links open the instance's charts on the firing's window.
- **The fix statement** (`pgvigil.finding_fix`) is given for a PostgreSQL setting finding on one of the settings
  pgvigil reads per instance (real, changeable parameters: never `data_checksums`, never an extension's name) whose
  suggested value is one word: `ALTER SYSTEM SET <setting> = '<value>'; SELECT pg_reload_conf();` (a setting of context `postmaster` takes a
  restart besides; on Aurora and RDS the parameter group holds it), and for a maintenance statement the finding's
  detail spells out (REINDEX, CREATE / DROP INDEX, ALTER TABLE / INDEX, VACUUM, ANALYZE). Otherwise none: the detail
  says what to do; an alert rule's finding gets none. pgvigil runs nothing; the statement is advice.
- **Triage on the open alerts**: a box per row and an *all shown* box that ticks every row the grid shows; the actions
  act on the ticked rows (acknowledge, clear, notes, close, and **Dismiss with a reason**: "tolerable for this server",
  "controlled elsewhere", "a known pattern of this system", "a test or lab instance" or any text up to 500
  characters). A dismissed alert leaves the grid; *Show dismissed* brings it back with who dismissed it and why, and the
  alert's page has *Undismiss*. A dismissal never ends by itself: a later firing of the same finding stays dismissed
  until someone ends it. A dismissal changes what the grid shows, never what is sent: a mute or an
  acknowledgement holds the sends. Every dismissal and its end is in the acknowledge log (kind `dismiss`). Each row's
  alert opens its page, and the *fix* column copies the fix statement.
- **Mute rules** carry an instance field, a **start** (blank = at once; until it passes the rule reads *upcoming* and
  holds nothing: a quiet window set ahead of planned work) and an end (no expiry, hours after the start, or a time).
  **Edit** ends the rule and writes its successor in one step (the successor's row says which rule it replaces, the
  old one which replaced it; a paused rule stays paused), as alert rules are edited. An edit keeps the rule's instance
  unless another is picked; widening it to every instance takes *Any instance* and a box ticked by hand, so a rule on
  an instance removed since never widens to the fleet by an edit. **Pause** keeps the rule and holds
  nothing until **Resume**. Known patterns are edited the same way; they hold nothing, so they have no pause. Each
  step is in the acknowledge log: an edit as three rows (the successor's `add`, the old rule's `end`, the `edit`),
  a pause and a resume as one each.
- **Alert history** (the Alerts tab, the range): every firing open at some time in the range, newest first: fired,
  cleared, how it ended (*resolved*: a recovery was sent; *cleared without a fix*: its instance retired, the channel no
  longer covers it, or recovery is off - PagerDuty and Opsgenie closed their incident, the other kinds sent nothing),
  severity, instance, the alert (a link to its page), the value last sent,
  the threshold (an alert rule's value; a finding's suggested value while the finding stands), the channels, the sends.
  A firing is the channels' alerts of one finding grouped while their send periods overlap; an alert still open on a
  channel the configuration no longer names leaves the history (nothing moves it again). The history is as long as
  purge keeps the cleared alerts.
- **Thresholds in force** (the Alert rules page): every threshold each active instance is judged by. Per metric the
  alert rule in force on it (an instance's rule over a tag's over the fleet's) with the wider rules it overrides there;
  on a SQL Server instance the HA/DR, jobs and backups thresholds, marked *configuration file* where `mssql_thresholds`
  sets them and *default* where it does not (read only: the file is their source). Click a rule's line for an
  override that would be in force: on a fleet rule, **for this instance** or **for one of its tags**; on a tag rule,
  for this instance; an instance's own rule opens to be edited. The rule form opens with the metric and the numbers
  filled. The built-in findings' own limits (the setting rules, vacuum, storage ...) are not listed here; they are in
  each finding's detail.

## In the repository (migration 0059)

| Object | What it holds |
|---|---|
| `pgvigil.alert_channels` | The channels as configured (the last pass's record). |
| `pgvigil.alert_state` | Per channel and finding: first sent, last sent, sends, the severity sent, cleared, recovery sent. |
| `pgvigil.alert_log` | Every attempt (monthly partitions): channel, destination, the alerts by event, outcome (`sent`, `failed`, `refused`, `cleared`, `none`) and the error text. |
| `pgvigil.alert_findings`, `pgvigil.findings_alerts`, `pgvigil.alert_sent` | Findings with their key, and with their alert columns. |

The sender connects as `alerts_dsn`, a login in the role `pgvigil_alerter` that migration 0059 creates. The role is a
member of `pgvigil_reader`, so it reads the findings. It also holds INSERT and UPDATE on `alert_channels`, `alert_state`, `alert_rule_fired` and `ack_suppressed`, UPDATE and DELETE on `alert_rule_state`, and UPDATE of `alert_tests`' outcome columns (migrations 0059, 0073, 0085, 0093):

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

## In the repository (migration 0093)

| Object | What it holds |
|---|---|
| `pgvigil.alert_channels` | Gains `max_per_hour`, `templates` (which events and parts carry one, never the text) and `link_base`; kind takes `opsgenie`. |
| `pgvigil.alert_log` | Outcome takes `capped` (held by the cap, owed again) and `test` (a Send test answered). |
| `pgvigil.alert_tests` | Every Send test asked (who, from where, the channel), refused requests included, and the sender's answer. Purged after the purge window. |
| `pgvigil.alert_dismissals` | Every dismissal with its reason, who and when, and its end. Not purged (an audit). |
| `pgvigil.acks` | Gains `paused_at`, `paused_by` and `replaces` (the rule an edit ended). |
| `pgvigil.alert_occurrences` | Every firing of every alert over the channels, its clearance and how it ended. |
| `pgvigil.finding_fix(...)` | The fix statement of a finding, or NULL. |

Writes from the UI go through `pgvigil.import_alert_test`, `pgvigil.import_alert_dismiss` and
`pgvigil.import_ack_change` (the actions door's audit login, as `import_ack`; `POST /api/alerts/test`,
`/api/alerts/dismiss`, `/api/alerts/mute`). The sender reads the requests through `pgvigil.alert_tests_due` and answers
through `pgvigil.alert_test_record`; its login needs nothing new (0093 grants `pgvigil_alerter` the test table).

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
- On the same loopback listener with `alerts_base_url` set: an Opsgenie channel (one create per alert under
  its alias with the page's address, the key only in its header; the close of a resolved alert and of each alert of a
  deactivated instance; a 401 that echoes the key is logged with the key replaced), Discord and Google Chat (every post
  within its text limit, as many alert lines as alerts, each ending with its page's address; Discord's mentions off),
  a send cap (3 sent, the rest held and logged, still held through the hour, up to 3 more once it passed), SMTP templates (the subject's count, the lines); the alert's page through the API (the card,
  the fix statement and its refusals, two firings, the sends), dismiss through the door (401, 403, no reason, done, again, the
  history's mark, the end, the log), a mute rule set ahead (holds nothing until its start), edited, paused and resumed,
  and Send test (refused while one waits and for an unconfigured channel; sent by the next pass, Opsgenie's test closed
  at once, answered and logged).

Opsgenie, Discord and Google Chat are proven on the loopback listener only: no test account of theirs was made. A
real send to them is not proven, and neither is how Opsgenie orders a create and an immediate close of the same alias.

`scripts/proof-alerts-live.sh` sends to REAL destinations (run it only against test ones): a finding of its own fires
to an SMTP server, a Teams Workflows webhook, a Slack webhook and PagerDuty, its recovery follows on all four, and a
finding cleared without a fix (the instance deactivated) resolves the PagerDuty incident while the other three record
it silently. Proven 2026-11-11 against Amazon SES (STARTTLS on 587), a Teams Workflows webhook, a Slack incoming
webhook and a PagerDuty Events API v2 service: every pass exit 0, each provider accepted every send.
