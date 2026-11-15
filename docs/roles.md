# Roles of the web UI

Every user of the web UI has one role. The role decides which changes the user may make; every role reads every
page.

| Role | What it may do |
|---|---|
| viewer | read every page, export, copy, run a stored custom report; change nothing |
| operator | what a viewer may, and act on a monitored server - cancel a query, end a session, KILL, start or stop a job, evict a plan, EXPLAIN and EXPLAIN ANALYZE, try a hypothetical index, run a community tool, send a report by mail - and acknowledge, note, dismiss, mute one instance with an end |
| admin | what an operator may, and change configuration others live with - instances, discovery sources, proposals, DBA Dash moves, applications and their contacts, alert rules, drive / PostgreSQL / job thresholds, job exclusions, custom reports and their folders, report mail schedules, a mute or blackout over every instance, a tag, or with no end |

Each action still needs what it needed before the roles: an instance's own opt-in (`actions:`, `explain_analyze`,
`hypo_index`), a typed confirmation, the actions door's audit login. The server checks the role first, then those.

## In the pages

The header shows the role beside the user's name, with what it may do: `alice (viewer: a viewer reads; a change needs
the operator or the admin role)`.

A control that makes a change is drawn for every role. Below the role it needs, it is off - still reachable with the
keyboard - and says why in the server's own refusal words (its title; its description is the header's sentence, or a
note beside it inside a dialog). A page that is read only as a whole below a role (Admin > Instances, Applications,
the DBA Dash move, custom reports' folders) says the words once, in its "Read only" sentence.

A control that is off for a reason of the server's own - no actions door, an instance not opted in, the demo - says
that reason and not the role's: it is the first that would have to change. A dialog that only reads opens for every
role (a job's thresholds, a rule's values); its Save is the one that is off.

A mute, a silence or a blackout over more than one instance (every instance, a tag) or with no end needs the admin
role, whichever page asks: `Mute similar` is off below admin, and the mute dialog asks an operator for one instance
and an end. The edit of a mute rule is held to the same rule as a new one.

The answers the pages read say what the session's role may do (`can: {operator, admin}`) beside their own `writable`
and `reason`, so a page shows a role changed since it was loaded at its next read; the server decides at every
request whatever a page shows.

## Until the per-login instance scope lands

Until the per-login instance scope lands, every role sees every instance - in the tree, the pages, exports, the API
and the MCP door. A role limits what a user may change, not what it may read.

## Managing roles

Users are managed on the server, as the repository owner:

```
pgvigil user add  -config pgvigil.yaml -role operator alice     # viewer, operator or admin
pgvigil user role -config pgvigil.yaml alice admin              # an open session follows at its next request
pgvigil user list -config pgvigil.yaml                          # the role column
```

`pgvigil user add` without `-role` makes an admin when the repository has no enabled admin (its first), and a viewer
otherwise; the line it prints says which. The role is read with the password hash at every request, so a demoted,
disabled or re-passworded user loses the right at the next request.

## A refusal

A change above the user's role is refused with 403 and its words, for example:

```
acknowledging needs the operator role: alice is a viewer (an admin changes it with 'pgvigil user role alice operator' on the server)
```

A refusal is a log line of pgvigil serve (`role refused`, with the user, the role and the route), never an audit row:
a loop of refused requests cannot fill the audit tables. The audit rows of a change name its user, not the role the
user held at that moment.

When the role cannot be read (the repository does not answer the lookup), a page still reads, and a change is
refused with 503 "the role could not be read".

## Upgrading

The role migration (`0257_ui_roles.sql`) makes every user that exists then an admin, so nobody loses what they could
do; a user added later starts as a viewer. A pgvigil serve older than the migration, on a repository that holds it,
signs in admins only (it knows no role, so it admits only who could do everything); a newer serve on an older
repository refuses to start and says to run `pgvigil migrate`.

## Where roles do not apply

- **`pgvigil serve -no-login`** (loopback only): there is no user, so no role; the changes that need a signed-in user
  say so in their own words, as before.
- **`pgvigil demo -serve`**: the demo's own door and user; roles are not applied there.

## The routes

Every change is a POST. Its need is the lowest role that may send it (`anyone` = without a session). Every GET needs
a signed-in user of any role. This table is the server's own list: a test compares the two.

| Route | Need | What |
|---|---|---|
| `POST /api/login` | anyone | sign in |
| `POST /api/logout` | anyone | sign out |
| `POST /api/indexes/advise` | viewer | read an index advice (stores nothing) |
| `POST /api/mssql/actions/preview` | viewer | preview an action's statement (runs nothing) |
| `POST /api/community/glenn/parse` | viewer | read a diagnostic file (stores nothing) |
| `POST /api/community/params` | viewer | read a tool's parameters (@help) |
| `POST /api/customreports/run` | viewer | run a stored custom report (on the reports login or the instance's read login) |
| `POST /api/reportmail/rendered` | viewer | the mailed report's drawing step (the render's own user) |
| `POST /api/actions/cancel` | operator | cancel a PostgreSQL query |
| `POST /api/actions/terminate` | operator | end a PostgreSQL session |
| `POST /api/mssql/actions/run` | operator | KILL, job start / stop, plan evict on SQL Server |
| `POST /api/jobs/actions/stop` | operator | stop a job |
| `POST /api/jobs/actions/start` | operator | start a job |
| `POST /api/ack` | operator | acknowledge, note, mute or black out one instance with an end (wider or open-ended: admin) |
| `POST /api/ack/end` | operator | end an acknowledgement |
| `POST /api/alerts/dismiss` | operator | dismiss an alert |
| `POST /api/alerts/mute` | operator | pause, resume or edit a mute rule (an edit to every instance, a tag or no end: admin) |
| `POST /api/alerts/test` | operator | send a test alert |
| `POST /api/plans/explain` | operator | EXPLAIN (stores a plan row) |
| `POST /api/plans/analyze` | operator | EXPLAIN ANALYZE (runs the statement) |
| `POST /api/plans/hypo` | operator | try a hypothetical index |
| `POST /api/community/run` | operator | run a community tool (a script runs as the read login in a rolled-back transaction) |
| `POST /api/reportmail/send` | operator | send a report by mail now |
| `POST /api/reportmail/test` | operator | send a schedule's test mail |
| `POST /api/admin/instances` | admin | add, edit, enable, disable, remove an instance |
| `POST /api/admin/sources` | admin | a discovery source and its cloud settings (add, edit, enable, disable, remove, sync, sweep) |
| `POST /api/admin/proposals` | admin | approve or ignore a proposed instance |
| `POST /api/admin/dbadash_moves` | admin | move a DBA Dash instance |
| `POST /api/admin/applications` | admin | an application |
| `POST /api/admin/applications/contacts` | admin | an application's contacts |
| `POST /api/admin/applications/assign` | admin | assign instances to an application |
| `POST /api/admin/applications/routes` | admin | an application's routes |
| `POST /api/admin/applications/import` | admin | import the applications inventory file (CSV, JSON or .xlsx; contacts are never in it) |
| `POST /api/alertrules` | admin | an alert rule |
| `POST /api/alertrules/end` | admin | end an alert rule |
| `POST /api/drives/thresholds` | admin | a drive threshold |
| `POST /api/pg/thresholds` | admin | a PostgreSQL threshold |
| `POST /api/jobs/thresholds` | admin | a job threshold |
| `POST /api/jobs/exclusions` | admin | a job exclusion |
| `POST /api/customreports` | admin | a custom report or folder (SQL run against servers, a view others share) |
| `POST /api/reportmail` | admin | a report mail schedule (add, edit, end, enable, disable) |
