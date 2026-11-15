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
| resolved | The finding has been gone from the findings for `clear_after` (default 10 minutes, so a finding at a time window's edge does not send a recovery and a new alert a minute later), **and** the collector has read the instance successfully since the finding went missing. An instance left unread (unreachable, the collector stopped, a gap of any length) holds its alerts open: its time-windowed findings leave the view, but nothing was fixed. 'Read successfully' means a collection that finished with status ok; a partial read (one database or one source failed) does not count. Under `pgvigil run` several reads run every minute and give one each minute on a healthy instance (PostgreSQL: activity and connections, usually the database statistics; SQL Server: database mirroring, which needs no VIEW SERVER STATE and ends ok on a server with no mirrored database, and with VIEW SERVER STATE the waits, memory, CPU, file IO, requests and waiting tasks). An instance whose every-minute reads all end skipped or partial (before SQL Server 2022, a login without VIEW SERVER STATE on a server with a mirrored database) holds a resolved alert open until another collection reads it whole. A `pgvigil collect -once` run from another host writes to the same repository: a connect it cannot make there raises 'server unreachable' for that instance until the service's next ok read. Sent when `recovery` is on; otherwise the alert is closed without a message (the log's outcome `cleared`). |
| closed without a message | The instance was deactivated, disabled on Admin > Instances, or removed, or the channel's instances or tags no longer cover it: nothing was fixed, so no recovery is sent. PagerDuty and Opsgenie are the exception: they close their incident, or it would stay open for good. |

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

## The round trip and the ping (B24h)

Three findings come from the collector's own measures (warnings, settable per root, tag or instance as
`round_trip_time` and `ping_time`, in seconds to three places, each settable empty: off):

- **query round trip slow** - an instance's 'SELECT 1' round trip (the network and the server's answer) averaged over
  its last 5 measured minutes is over its threshold (40 ms by default);
- **ping slow** and **host not answering ping** - under `probe_every_minute` only, the host's answer to the probe
  (until B24h-2 the TCP handshake to the port the instance's connection used) over its last 5 probed minutes, the
  newest within 8 minutes, is over its threshold (10 ms by default), or none of its last 3 probed minutes answered
  though the host answered before and no connection to the host opened since the first of them (an opened
  connection is an answer). A host reached at a new address (an endpoint's failover) is judged by the address probed
  newest. One alert a host (source `pgvigil repository`, the host as its value), the instances' own rows held under
  it;
- **network slow from this collector** - 3 or more of a collector's probed hosts slow, and more than half of them: its
  own network or host is the likelier cause; the instances' probe findings are held under it, and it is held itself
  while 'collector or network' or the slow-connect fold stands for the same collector (one alert, not three). While
  3 or more of a collector's instances (a round trip) or hosts (a ping) turn slow in the same minute, their new alerts
  wait a pass for the fold to form; one that turns slow a pass before the others is sent first.

By default a host is probed only after a connection to it got no answer (never after a login or a query the server
refused): the probe's answer then goes into the words of 'server unreachable' and 'server not answering' (the host
answers: the service is down, not the host).

## When many instances fail at once

A network cut, the collector's host in trouble or a shared login gone wrong fails many instances at once. pgvigil
sends one alert for it, **collector or network** (critical, source `pgvigil repository`, to every channel past its
severity floor, scoped channels too), instead of one per instance:

- **raised** when a collector (a host) has not beaten for 5 minutes while no other collector reads its instances
  (*collector not seen*), or when failures of its instances BEGAN together: 5 or more, or at least 3 and over half of
  those it ran, started failing every run within the collector's span plus 3 minutes of each other (*instances failing
  together*; its text says how many of how many). The span is the fastest configured collection interval of the
  instances the collector reads, 1 to 5 minutes. A failure that stood before never counts: instances that began
  failing at different times raise nothing however many they are, and a new single failure beside them alerts as any;
  or when one server stops answering (*server not answering*, its text naming the server by its dial target - the
  DSN's host and port with the engine, `postgres:db1:5432` or `mssql:sql1\inst:1433`, never the address the server
  reports): the instances the collector reads through that target got no answer at their connects (no error from the
  server - a dropped database, a refused login or too many connections are answers), no instance on the target has
  answered a connect since they began, and 3 or more of them are new to it (each answered a connect before, however
  long ago) and began within the span plus 3 minutes of each other, or with no read between (an instance read once an
  hour joins when its next read fails). One on that target that was already failing, or has never answered, is held
  with them but not counted. A group failing together whose instances are exactly one server's down instances names
  that server (*instances failing together from ... on server ...*);
- **stands** while 3 or more of those instances still fail every run - one that is read again has left it - and a
  server not answering stands until an instance on it answers a connect. A group that never recovers keeps it
  standing (a server taken out for good: remove it from the configuration, or mute it). Under 3 it clears and resolves
  `clear_after` later (10 minutes by default); the one or two still failing then alert on their own, once each. While
  it stands it holds every instance of every failing group and every server not answering on that collector;
- **is one alert per collector**: its value is the collector's host, whatever its reason. It repeats once per change
  of its reason: a cut whose collector then stops beating, and a collector that crash-loops while its group stands
  repeats at each flip. A new cut on that collector while one stands (instances that begin failing together, or a
  second server that stops answering, more than the span plus 3 minutes after the standing one began) repeats it once
  too, its text naming the new start, and that repeat passes an acknowledgement of the alert, as an escalation does;
  when the newer cut clears first, the text names the older start again and repeats once more (an acknowledgement
  holds that one). The same cut changing its reason (a server not answering that more instances then join) is no new
  start: an acknowledgement holds it. A mute by text written for the old value (*collector not seen: host*) no longer
  matches: mute the alert itself, or by check (`collector or network`).

Only the alerts a shared cause explains wait under it: *authentication failing*, *collection failing*, *server
unreachable*, and the findings judged by their age on data the cut stops refreshing (*job run over twice its
average*, *job schedule missed*, *a job runs far longer than its average*, *amcheck older than N d*, *unused index*).
Every other finding comes from the last good read and is sent as it is: a disk filling up before the cut may be its
cause.

| When | What those alerts do |
|---|---|
| In a collector's newest written minute 5 or more of its instances, or at least 3 and over half of those it ran, have trouble that is NEW: a connect that stopped opening, or a failed run of a collection that began failing, within the last span plus 1 minute (a cut starts partway through a minute; a failure that stood before - a collection failing on its own every minute or every 5 minutes, a login refused for an hour - never counts) | A new one waits for the next minute: about a minute, at most the span plus 3 minutes from the minute its own trouble began (4 at the default span of a minute, 8 when every collection runs every 5 minutes). One or two instances failing never wait. A cut that starts late in a minute may reach only some instances before the minute ends; when that is fewer than 3, or under 5 and not over half of those the collector ran, they alert at once, one beat (about a minute) before the parent, which then names them among the open alerts it covers: 4 instances at most (2 on a collector of up to 5 instances, 3 on one of 6 or 7). |
| The parent stands | Held for its instances still failing every run: no new alert, no repeat, no recovery. One already open stays open and silent, and the parent's text names the open alerts it covers. An instance that comes back while held sends nothing. |
| After the parent clears | An instance still failing sends one alert per finding after its next failure past the outage's window (its next refused login, failed run or failed connect once the span plus 4 minutes have passed since the last minute the group failed together, or its server answered no one: about 5 minutes after the others came back at the default span), never off a streak built during the outage. An instance whose connects in the server's first minute back fell before it answered waits the same way, so it sends nothing when it is read again a minute later. An alert that was open before it does not repeat on a failure from inside the outage either: when the instance is back, its recovery arrives alone. |
| A wait ended without a parent | The new trouble did not turn into a shared cause: the alerts that waited go out as they come, and the Collector page says so under the collector for 15 minutes - *The wait for a shared cause ended on host at HH:MM without one: new alerts of its N failing instance(s) are sent as they come.* A wait that ran into a parent, since cleared, is not one. A parent that rises later says in its text when the wait had stopped (in UTC) and how many of the open alerts it covers went out between that stop and its own first send. |

A refused login, or a server that does not answer at the instance's own connect, is that instance's one finding
(*authentication failing* or *server unreachable*): the collections that could not connect do not each raise
*collection failing*. An empty or unreadable DSN shows as *server unreachable* too, its error in the detail. For an
instance the collector service reads (`pgvigil run`, which beats), *server unreachable* is raised after 3 failed
connects in a row over a minute or more, and a refused login is *authentication failing* alone: one failed connect is
not yet a server down (a restart, a failover or a network blip ends inside a minute), and the Collection dates page
shows the failed read at once. At the default intervals a server that stops answering (its port refuses) is reported
1 to about 4 minutes later, 2 and a half on average: up to a minute until the instance's next collection, the rule's
own minute, then the collector's beat and the alert pass, each up to a minute. A host that drops packets instead
takes up to 10 seconds more per attempt: the collector ends an instance connect whose DSN sets no `connect_timeout`
after 10 seconds (a DSN's own `connect_timeout` is kept; `connect_timeout=0` is read as none set), a SQL Server
instance's too (its DSN's own `connection timeout` is kept - the SQL Server driver then applies it to every read of
the session as well, so a query whose server sends nothing for that long is cut off; without either the driver would
wait for good on a server that accepts the connection and never answers). On a SQL Server instance that signs in with
Entra (`auth entra`, `auth entra-identity`) the time the identity provider takes to hand over the token is not counted
in those 10 seconds; a Kerberos exchange with the domain controller (`auth windows` off Windows) is - a string that
sets its own `connection timeout` gives a slow KDC more room. An instance read only
by `pgvigil collect` on a schedule has no heartbeat: its *server unreachable* is raised by its first failed connect
of any kind, a refused login included. The service names each instance to the repository inside the instance's own
connect, so its first failed connect is already the service's to report - after a long stop, for an instance read
once an hour, and for one never reached. The service's *server unreachable* and *collection failing* speak only while
a collector that beats still names the instance: 20 minutes after its last naming (the instance moved to a scheduled
`pgvigil collect`, or its collector died) they leave the findings, and the scheduled read's own *server unreachable*
and the Summary's Collection Errors check speak for it. An alert that was open stays open until a read of the instance
is ok - it is never resolved because nobody reads the server any more. An instance moved from the service to a
scheduled collect while it fails is announced again, once, by the scheduled collect: the two speak for different
readers.

Two collectors reading one instance (a move to another host, a second collector) each keep their own counts, and
*collection failing*, *server unreachable* and *authentication failing* stand at the lowest of the collectors still
reading it: one refused while the other reads fine raises nothing (*collected by more than one collector* says that
two read it). A collector on a renamed host starts its counts at 0: an hourly collection needs 3 more hours to raise
*collection failing*.

What the hold does not cover: a collector whose collections all run less often than every 5 minutes, with its
instances spread over the minutes, sends one alert per instance - the hold reads failures that begin within the span
plus 3 minutes of each other, and the span is 5 minutes at most.

A host whose collector was uninstalled while the repository stays is retired there by the uninstall
([uninstall.md](uninstall.md)): it raises no *collector not seen*. A blackout, silence or mute that names an instance
never holds *collector or network* or *purge not run in 2 days*, which belong to no instance and carry no tag - mute
those by their own alert, by check (`collector or network`) or by text.

A cut that drops packets instead of refusing them makes each connect hang until the 10-second connect timeout above
ends it (or the DSN's own timeout; without either the operating system gives up after about 2 minutes on Linux). A run
is counted when it ends, so the parent can rise a little later than for a refused connection.

## When connects are slow

The collector times every connect it opens - an instance's own and a collection's per-database ones - from the call
to the open connection: DNS, the TCP and TLS handshakes, the login, and the collector's own CPU and scheduling. On a
SQL Server instance that signs in with Entra the time the identity provider takes to hand over the token is left out
(it is the provider's, not the server's); a Kerberos exchange with the domain controller is counted. A failed connect
is never timed (it is *server unreachable* or *authentication failing*).

**slow connect** (warning or critical, source `pgvigil collector`): an instance whose connects over its last 5 written
minutes average over its `connect_time` threshold - 1.00 s for a warning and 2.50 s for a critical by default. The
Thresholds page sets it at the root, at a tag or at a PostgreSQL instance; a SQL Server instance takes the root's or
its tag's, as Instance Uptime does (the page lists PostgreSQL instances and their tags; a SQL Server instance's own row
is taken through the API). A level set with one box empty is not judged at that level (warning 3.00 s with no
critical never turns critical). It needs 3 or more timed connects in those minutes (an instance read every minute has
about 13 a minute, some 65 in the 5; one slow connect among them does not alert, a server slow at every login does),
and its newest written minute within the collector's span plus 3 minutes of now: a stopped collector's last minutes
judge nothing. The Collector page shows each instance's connect average and longest of the
hour, and the instance's line on Collection dates says the same.

When most of one server's instances, or most of the servers one collector reads, are slow at once, ONE alert speaks
for them, **slow connects** (source `pgvigil repository`), and the members' own *slow connect* alerts are held while
it stands (a member over the alert's level is still sent):
- a **server** (a dial target: a SQL Server, an Azure SQL logical server and its databases, a PostgreSQL host and
  port) with 3 or more judged instances is slow when 3 or more of them and more than half are over their own warning -
  its gateway or its login, not the collector; the alert's value is the server;
- a **collector** is slow when 3 or more of the servers it reads and more than half are slow (a server of 1 or 2
  instances counts as slow when all of them are) - the collector's own CPU, DNS or network, not the servers; its value
  is the collector's host, and the servers' own *slow connects* at or under its level are held under it (a server
  critical under a warning collector alert is sent).
It becomes critical when more than half are over their critical value (for a collector: more than half of its servers
slow and over their critical). It forms at more than half and clears only at a quarter or less (or under 3) while its
alert is open on a configured channel, so a count that hovers at half does not send and resolve every minute; while 3
or more of a collector's instances cross their warning in the same minute (slow now, not slow in the 5 minutes before),
a new *slow connect* waits up to a minute for the fold to form. A member above the level the alert was sent at (one
server critical under a warning alert; a critical one while a critical alert falls to warning is still held) is sent
on its own. While the collector's own *collector or network* stands, its *slow connects* is not resolved. The detail
names the counts, the members' average over their last 5 written minutes with the first minute of that window ('the
window from', not the minute the slowdown began: the alert's own first send is the nearest time to that) and the 3
slowest instances. A
collector's own *collector or network* comes first: the instances it holds are not judged.

What the time costs and why the collections start spread: a collector spends about 2 ms of its own CPU on each
PostgreSQL connect with TLS and a password login (measured 2026-11-14 on a 4-CPU client, flat with the load). Each
collection's first run after the collector starts falls at a random moment within its interval, 5 minutes at most,
then repeats at the interval: a site's minute collections spread over the whole minute (about 25,000 connects a minute
cost about 0.8 of a CPU, every connect under 10 ms at the 95th percentile on that rig) instead of all firing in the first
10 seconds, which would queue them behind the collector's CPU and read as slow connects everywhere. An hourly or daily
collection still runs within 5 minutes of a start.

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

## Alerts to an application's contacts

Admin > Applications can route an application's contacts to the alerts of its servers through an smtp channel of this
file (task 310): each pass makes one channel per route, `contact-<route id>`, with the channel's relay, repeat,
clear_after, quiet hours and max_per_hour, its scope the application's tag. Repository-wide alerts never go to a route,
a Send test and Report mail use the configured channels only, and no address appears in the log or on the Alerts page.
A channel of this file may not be named `contact-...`. The whole: [applications.md](applications.md#alerts-to-contacts-routes).

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
