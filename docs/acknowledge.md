# Acknowledge, mute and notes

pgvigil keeps every acknowledgement and every mute in one store in the repository. A row is never deleted from the UI.
Ending a row records who ended it and when. Every attempt to make or end a row that passes the write door (the UI login, the `X-Pgvigil` header, a readable body of a known kind for a known instance) is audited, refused attempts included.

| What | Where | What it does |
|---|---|---|
| Acknowledge a check | Summary: Needs attention, **Acknowledge** | The instance's warning and critical cells lose their colour. They count under *acknowledged* in the test grid and as *check(s) acknowledged* in the header line. The acknowledgement lasts until a time, until the cell's reading changes, or both. |
| Acknowledge an alert | Alerts: tick the alerts, **Acknowledge alerts** | The alert is not sent again on its channel's repeat interval. A rise in its severity is still sent (not proven: the proof covers the repeat only). **Clear acknowledgement** ends it. |
| Note | Alerts: **Add notes to selected alerts** | Keeps a note on the alert, with who wrote it and when. The *notes* column shows the newest note and the count. Not proven: the proof writes no note. |
| Close resolved | Alerts: **Close resolved alerts** | Takes an alert whose finding is gone off the open list. **Show closed** lists it again. The channels still send the recovery (not proven: the proof reads the close, not a send). |
| Silence a server | Alerts: Silenced servers, **Silence** | Holds every alert of the instance until it is unsilenced or the time chosen passes. Held alerts are still logged. |
| Blackout | Alerts: Silenced servers, **Blackout** | Holds an instance's alerts from a start to an end and flags them *blackout*. |
| Mute rule | Alerts: **Mute this alert**, **Mute similar**, **New mute rule** | Holds every alert matching the rule until the rule ends or expires. Held alerts are logged under *Held sends*. |
| Known pattern | Alerts: **New known pattern** | Shows a label beside each matching alert. It holds nothing. |
| Acknowledge a job | The Jobs grids: **Acknowledge** | The job's failure cell loses its colour until the job fails again (not proven: the proof makes no job acknowledgement). |

A rule matches an alert when every field filled in matches:

- *check*: the finding's source or setting, ignoring case;
- *instance*: one instance by name;
- *tag*: one of the instance's tags;
- *text*: a substring of the source, setting or value, ignoring case;
- *one alert*: from **Mute this alert**.

A rule whose instance was later removed matches nothing. It never widens to every server.

## Who may write

Writes take the same path as the Cancel and Terminate buttons (docs/running-queries.md):

- the UI login: the row's *made by* is the signed-in user;
- the `X-Pgvigil` header, which the UI sends and a cross-site form cannot;
- the repository login from the configuration (the collector's), which calls `pgvigil.import_ack`.

The UI's read-only pool never writes. A server running with `-no-login`, or one whose actions door is off, shows the
store read-only and says why: the buttons are disabled with the reason as their title.

## The sender

Each pass of the alert sender (`pgvigil run`, `pgvigil alerts`) checks the store:

- A mute, a silence or a blackout in force keeps a matching alert from firing, escalating or repeating. Its open alert
  stays open: no recovery is sent while the finding is still there.
- Every held alert is counted per rule, channel and alert in `pgvigil.ack_suppressed` (first pass, last pass, passes).
  The Alerts page shows these rows as *Held sends*.
- An acknowledged alert is owed no repeat.
- Resolution is unchanged.

## The store (migration 0073)

| Table | Holds |
|---|---|
| `pgvigil.acks` | One row per acknowledgement, note, close, blackout, job acknowledgement, silence, mute rule or known pattern: what it matches, until when, made by and at, ended by and at |
| `pgvigil.ack_log` | Every attempt from the UI: who, from where, add or end, the kind, done or refused with the reason |
| `pgvigil.ack_suppressed` | The sends a rule held |

No table is purged: like the actions log, they are an audit. The API is `GET /api/ack?part=acks|log|suppressed|alerts|attention`,
`POST /api/ack` and `POST /api/ack/end`.

## Needs attention

The Summary lists one line per instance with a warning or critical cell that is not acknowledged. Each line shows:

- blocking over the last 15 minutes, as a count and a rate per hour. PostgreSQL counts distinct sessions seen waiting on
  a lock. SQL Server counts blocked process reports.
- deadlocks over the same 15 minutes. PostgreSQL uses the rise of `pg_stat_database.deadlocks`. SQL Server counts
  deadlock graphs.
- the cells.

**Needs attention only** keeps the instances and tests with a warning or critical. **Sort** orders the grid and the
lines by severity, by name, or by CPU (the newest host sample).
