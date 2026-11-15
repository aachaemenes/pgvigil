# Applications

Admin > Applications says which application each monitored server and database serves, who owns it and who is told when
it has a problem (task 310, migration 0136).

An application is set on a whole server (every database of it inherits the application) or on one database (its own
application beats its server's). A server or a database has one application at its own level. Every server an
application is on carries the tag `application:<name>`: on the tree, in the tag filter, in a threshold's, an
acknowledgement's or an alert rule's scope, like any other tag. The tag is pgvigil's own: `pgvigil tag`, Admin >
Instances and the configuration file cannot set the key `application`: a file's `application:` tag is not taken, the
page names the instance, and the collector logs "tag not taken" when the instance starts. An older store's override of
the key (named on the page too) is cleared with `pgvigil tag -reset <instance> application`.

## The page

- **Applications**: each application with its tier (1 the most critical to 4), its default environment, its owner team
  (the first team contact that is a business or technical owner; shown with the UI login on only), and how many servers
  and databases it is on. Click a name to open it below the list.
- **One application**: each field with where it came from (`entered` by a person on this page, or `import:<name>` by an
  import) and when; Edit (only the fields changed are sent, so a field an import set and nobody changed keeps its
  source); Rename; Remove; its contacts; its servers and databases; Assign.
- **Servers and databases**: own (assigned here) or inherited (a database of a server the application is on, with no
  application of its own). A database dropped on its server keeps its assignment, shown absent since its last read; it
  leaves the tag after that. A database renamed on its server (PostgreSQL: the same database id) is never taken under
  its new name silently: the old name shows absent with "renamed to <new>", and Assign instead moves the assignment. The
offer is not made while the new name has an application of its own; on SQL Server it says "possibly" (SQL Server gives
a dropped database's id to the next database made).
- **Databases with no application**: every present database of a monitored server with neither its own application nor
  its server's. System databases (template0, template1, rdsadmin, master, model, msdb, tempdb) are left out. Tick rows,
  then assign them all to one application in one request (500 at most), or mark them **not an application** (a test
  database, a DBA's own): a marked database leaves the list, and Unmark brings it back.
- **Changes**: the last 200 changes and refusals of this page, who and from where.

Report mail never mails this page (it carries contacts). The demo (`pgvigil demo`) gets three made-up applications with
contacts at example.com and no route.

A rename or a removal moves the tag `application:<name>`. When a threshold, an acknowledgement or an alert rule is
scoped by that tag, the change is refused and names them; tick "also rewrite" (rename) or "and end" (remove) to change
them with it. An application still assigned is removed only with "with its assignments" ticked, and the page asks twice.
An edit made from a page that read the application before someone else changed it is refused ("stale"): open it again.

Until the viewer, operator and admin roles exist, any signed-in user may change applications. A server running with
`-no-login`, `pgvigil demo -serve`, or without the actions door's audit login shows the page read only, each control
off with the reason.

## Contacts are personal data

A contact is a team (its group address first) or a person (with a phone if wanted), in a role: business owner,
technical owner, support or escalation. Contacts are read only when asked: the list and one application's answer never
carry them, Show contacts reads them (with the UI login on only: with `-no-login` the answer is "contacts hidden: the
login is off"), and an export of the page carries them only while they are shown (the page is never mailed: Report
mail refuses it). The reader role (BI tools, the MCP door) can neither read the contacts table nor call the doors that
answer them. A custom report on the store runs on the serve's own login, which can call those doors: a login of its
own for custom reports, in the reader role alone, closes that and is not part of this page. A change's audit row names the application, the role
and the contact's id, never a name, an e-mail address or a phone. The repository's backups and its server's statement
log, if it logs statements, hold what was typed: treat them as personal data too.

## Alerts to contacts (routes)

A route mails one contact the alerts of its application's servers through a channel of the configuration file
(`alerts:`): pick the contact, an smtp channel, and a minimum severity (empty: the channel's). The relay, its login and
its secrets stay in the configuration file. Each alert pass makes one channel per live route, named `contact-<route id>`:

- the channel's own recipients and scope are unchanged; the route mails only the contact, and only the findings of the
  servers that carry `application:<name>` (a server assigned at its own level, or through a database still present);
- the channel's repeat, clear_after, recovery, quiet hours and max_per_hour hold the route as a channel of its own (its
  own repeat clock, its own hourly count);
- repository-wide alerts (a collector or the network, purge not run) go to the configured channels, never to a route;
- a route turned off or removed (or its contact, or its channel gone from the configuration) closes its open alerts with
  no message, and turning it on again sends no old recovery; when the routes cannot be read in a pass, nothing is closed
  and the configured channels send as usual;
- a route whose channel is not configured, is not smtp, or whose address the mail parser refuses sends nothing, and the
  alert log says so once (by the contact's id);
- no address leaves the route: its destination text and every error name the contact's id (a relay's refusal that names
  the recipient is logged as `contact <id>`);
- a Send test, Report mail and the alert rules page's channel count use the configured channels only;
- with no channel configured, no route can send and the sender closes nothing (it records no channel then, so it
  leaves what another collector recorded as it was).

A person on two contact rows (two applications, or two roles) gets two copies. The relay carries one message per pass
for each configured channel with something due, plus one for each route with something due: with n channels and r
routes in all, up to n + r messages a pass.

A channel of the configuration may not be named `contact-...` (pgvigil refuses to start with one).

A base channel renamed in `pgvigil.yaml` does not carry its routes over: at the next pass each route through the old
name is 'not configured' and its open alerts close with no message. Set the route again on the new name: that is a new
route, and its application's standing findings are mailed to the contact again as new.

A development or lab repository that recorded migration 0190 before this release's version of it keeps the older
alert_due, which sends repository-wide alerts to routes too: pgvigil migrate does not run a recorded file again, so
such a store is made anew (a released store never held the older 0190).

## In the repository (migration 0136)

| Object | What |
|---|---|
| app_applications | the application: name (a tag value: 1 to 100 bytes, no comma), description, tier, environment, CMDB link, version |
| ui_app_contacts | its contacts (ui_: the reader cannot read it) |
| app_assignments | an application per server (database_name NULL) or per database (by name), its environment, source, who and when, the engine's id and last seen |
| app_not_application | the databases marked not an application |
| app_field_source | each field's source and when (an import never overwrites an entered field unless forced) |
| ui_app_contact_routes | the routes: contact, channel, minimum severity, on or off |
| instance_tag_pairs | gains the `application` arm (source `application`); the key leaves the configuration's and the overrides' arms |
| import_app_application, import_app_contact, import_app_assign, import_app_contact_route | the writes, each answering done or refused with the reason, one audit row per attempt (a done assign, unassign, mark or unmark: one per target) |
| app_effective, app_databases, app_unassigned | the reads of the page |
| alert_contact_routes() | the alert sender's one read of the live routes and their addresses (its own session or the owner's only) |

## Proof

`scripts/proof-applications.sh` on a throwaway repository: the store (S1-S24 with S11b and S11c), the API (H1-H8), the page
clicked in a headless Chromium with axe-core and the page's export (P1-P15), and owner-routed alerts on real alert
passes against a loopback SMTP sink (O1-O20 with O5b and O14b); serve reads on a login IN ROLE pgvigil_reader,
pgvigil_auth and writes on one IN ROLE pgvigil_collector, the passes send as one IN ROLE pgvigil_alerter. O5b (a custom
report calling the contacts' door) is said OWED, not failed, on a tree without the custom reports' own login. Go tests: internal/alerts/routes_test.go (the derived channels), internal/mcp/applications_test.go
(no MCP tool reads or answers a contact, row A11), internal/sched/apptag_test.go (the file's application: tag named).
