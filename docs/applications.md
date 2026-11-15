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
- **Inventory** and **Import a file**: the inventory as a file and back (below, "The inventory file").

Report mail never mails this page (it carries contacts). The demo (`pgvigil demo`) gets three made-up applications with
contacts at example.com and no route.

A rename or a removal moves the tag `application:<name>`. When a threshold, an acknowledgement or an alert rule is
scoped by that tag, the change is refused and names them; tick "also rewrite" (rename) or "and end" (remove) to change
them with it. An application still assigned is removed only with "with its assignments" ticked, and the page asks twice.
An edit made from a page that read the application before someone else changed it is refused ("stale"): open it again.

Changing an application needs the admin role ([roles.md](roles.md)): a viewer or an operator sees the page read
only, with the role's words. A server running with
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

## The inventory file

The inventory goes out as a file and comes back in (task 312, migration 0146). The **Inventory** grid lists one row per
active server and one per database of it. **Export the inventory (.xlsx)** writes every row whatever the grid is
filtered to (a sheet named Inventory, every value as the text the repository holds, its About sheet saying it holds
every line; never the page's own workbook, which carries the Changes grid's user names and, while shown, the contacts);
the button stays on in a read-only page (it is a read). **Download the inventory (CSV)** gets the same rows from `GET
/api/applications/inventory.csv` (UTF-8 with a BOM, an attachment). **Import a file** reads a CSV, JSON or .xlsx file,
previews what it would change, and changes it only on Apply.

- **Columns**, in order: level (server or database), instance, engine, database, application, environment, tier,
  description, cmdb_url, not_an_application; then inherited_from, absent_since, source and set_at, which the export
  writes and an import reads back and ignores. The header line is found by its names (server, app, db and cmdb are
  taken too), so the export bar's two lines above it are skipped. A header naming one column twice (Instance and
  Server, say) is refused, both cells named.
- **Rows**: one per server (database blank) and one per database: every present database, and every absent one an
  assignment or a mark still names (absent_since filled). System databases and inactive servers are left out; a line
  naming an inactive server is refused.
- **Inheritance**: a database that inherits its server's application has application blank and the server's in
  inherited_from, so a round trip never turns inheritance into an assignment of its own.
- **A blank cell changes nothing**, in every column. environment is the assignment's own (blank: the application's
  default); it and tier, description and cmdb_url (the application's, repeated on each of its rows) are read only on a
  line that names an application. Two lines giving one application different values refuse that application and name
  both lines.
- **`(none)`** (in any case) in application removes the target's own assignment: one an import set is a change, one a person entered
  is a conflict. On a database with no application of its own (it inherits, or has none) it changes nothing, and the
  preview says so. `(none)`, in any case, is no longer accepted as an application's name; an older store's application
  of that name is kept, and in a file the word means none.
- **not_an_application**: yes marks the database, no unmarks it, blank changes nothing; yes beside an application on
  one line refuses the line; a whole server is never marked.
- **Contacts are never in the file**, either way. A column named email, phone, contact or owner, like any column not
  listed above, is not read, and the preview lists it under the columns not read (the first 40 names and a count of
  the rest).
- **Matching**: a server by its exact name, else by the one name equal to it ignoring case; an import never makes a
  server: a line naming no known server is refused and the rest go on. A filled engine must be the server's. A database
  is matched the same way among the server's present databases and the absent ones still named; an unknown one is
  listed, never made. An absent database is assigned, re-assigned or marked on the page only.

**Formats.** CSV: commas or semicolons (Excel in a comma-decimal locale saves semicolons), UTF-8; UTF-16, a
tab-separated file and an .xls are refused in words, and so is a quote that ends a field early (with its line number:
a stray quote never reads the rest of the file into one cell). The CSV export ends its lines with LF (a carriage return
inside a cell is kept) and writes one more `'` before a cell that starts with `=`, `+`, `-`, `@`, a tab or a carriage
return (or with `'`s before one), so a spreadsheet does not run it as a formula, and an import takes one off: exact both
ways, key columns too; the page's export bar guards its CSV files the same way. JSON: the grid's `{columns, rows}` as
the API answers it, or an array of objects (an element that is not one is a refused line). .xlsx: the sheet named
Inventory, else the first whose header (in its first 20 rows) names instance and application; read as values, so a cell
holding a formula or an error refuses its line; a workbook lists at most 32 sheets and unpacks to at most 128 MB, its
rows go up (a row number twice is refused), and a cell past column 64 is not read. The inventory's own .xlsx writes
every value as text, so it reads back as exported. A workbook another tool saved is read by its cells' types: a
date-formatted cell as its date (yyyy-MM-dd; a 1904 workbook's too), a time alone as HH:MM:SS, a TRUE / FALSE cell as
yes / no, a number as it is stored (`1.50` typed into a spreadsheet as a number is `1.5`). A file is read by what it
holds, never by its name. Excel's own save of the workbook is not proven, nor a LibreOffice re-save (neither runs where
the proof runs: it reads the export's workbook and one with shared strings the proof writes).

**Preview and apply.**

- **Preview the import** writes nothing (no audit row). It lists each item: an application added or changed, and each
  line that changes (assign, re-assign, unassign, mark, unmark), with the conflicts, the refused lines and the unknown
  servers and databases, the counts, and how many servers' `application:` tag would move (so which tag-scoped
  thresholds, acknowledgements, rules and routes cover them differently).
- **A conflict** is a value a person entered on this page that the file would change, a database-level assignment under
  a server whose application a person entered included: it is kept unless ticked. A ticked application writes every
  field its words name (the ones entered by hand and the others the file changes); a line with a conflict waits whole
  for its tick. A database with an import's own assignment under a server a person assigned is the import's to change. What an import set, the next import
  may change. Every field and assignment an import sets records its source `import:<name>`, the name typed beside the
  file (1 to 40 of a-z, 0-9, `_ . -`; default `file`).
- **Apply the import** sends the preview's digest. When anything the plan read changed since the preview (a page write,
  another import), the apply is refused whole and nothing is written: preview again. A collector reading the servers'
  database lists in between is not a change.
- The apply writes through this page's own writes, so each change has its audit row, plus one summary row (counts
  only, never a cell's text). A line with a credential-shaped cell, each cell read alone (a password, secret, token or
  API, access, private, account or shared access key followed by = or :, a URL with user:password@, a link whose query
  sets token, key, sig, secret, password or auth, a PEM private key, a bearer token) is refused, its text in no answer
  and no audit row - also when the page took the same text (a description such as `Token: rotated monthly`): the
  export carries it and its re-import refuses those lines, so change that text on the page.
- **One import at a time**: a second, preview or apply, while one runs, is refused in words, never queued. A preview
  holds no lock on this page's writes; an apply does: a change made on this page while an apply runs waits about 2 s,
  then is refused in words ("the applications are being written now"): make it again when the import has ended. A file
  holds 5 MB and 20,000 lines at most, and an import has 120 s (else it is rolled back and says so: split the file).
- An apply whose answer is lost on the way (a closed connection, a proxy's page) may still have been applied: the page
  says so; read Changes, then preview the file again.
- Signed-in users only (no door without the login cookie); with the page read only, the Import section is off too.

## In the repository (migrations 0136, 0146)

| Object | What |
|---|---|
| app_applications | the application: name (a tag value: 1 to 100 bytes, no comma), description, tier, environment, CMDB link, version |
| ui_app_contacts | its contacts (ui_: the reader cannot read it) |
| app_assignments | an application per server (database_name NULL) or per database (by name), its environment, source, who and when, the engine's id and last seen |
| app_not_application | the databases marked not an application, with the mark's source (0146) |
| app_field_source | each field's source and when (an import never overwrites an entered field unless forced) |
| ui_app_contact_routes | the routes: contact, channel, minimum severity, on or off |
| instance_tag_pairs | gains the `application` arm (source `application`); the key leaves the configuration's and the overrides' arms |
| import_app_application, import_app_contact, import_app_assign, import_app_contact_route | the writes, each answering done or refused with the reason, one audit row per attempt (a done assign, unassign, mark or unmark: one per target) |
| app_effective, app_databases, app_unassigned | the reads of the page |
| alert_contact_routes() | the alert sender's one read of the live routes and their addresses (its own session or the owner's only) |
| app_conflict | 0146: the one rule of every write above: true when an unforced import would change what a person entered |
| app_inventory(), import_app_file | 0146: the file's rows; the one planner of an import (match, plan, digest, then the writes above) |

## Proof

`scripts/proof-applications.sh` on a throwaway repository: the store (S1-S24 with S11b and S11c), the API (H1-H8), the page
clicked in a headless Chromium with axe-core and the page's export (P1-P15), and owner-routed alerts on real alert
passes against a loopback SMTP sink (O1-O20 with O5b and O14b); serve reads on a login IN ROLE pgvigil_reader,
pgvigil_auth and writes on one IN ROLE pgvigil_collector, the passes send as one IN ROLE pgvigil_alerter. O5b (a custom
report calling the contacts' door) is said OWED, not failed, on a tree without the custom reports' own login. Go tests: internal/alerts/routes_test.go (the derived channels), internal/mcp/applications_test.go
(no MCP tool reads or answers a contact, row A11), internal/sched/apptag_test.go (the file's application: tag named).

`scripts/proof-app-import.sh` (the inventory file) on a throwaway repository: 0146's writes as an import against what a
person entered (M1-M12), the file through the API on the same non-superuser logins on both engines (F1-F26), the page in
a headless Chromium (P1-P4: the inventory's own .xlsx read back with the grid filtered and contacts shown, a file
previewed, one of two conflicts ticked and applied by clicks, a tick kept across a redraw of the preview, axe-core light
and dark) and the limits (section B: F13, 20,000
lines previewed and applied). Go tests: internal/web/q_app_import_test.go (the CSV, JSON and .xlsx readers).
