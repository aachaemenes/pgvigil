# Menus

pgvigil's tree, its grids and its bar carry the right-click and drop-down menus a DBA expects from a desktop
monitoring console. Every menu opens on a right-click, on the context-menu key, or on Shift+F10 when its node or
cell has the keyboard focus; Up and Down move through it, Right opens a submenu and Left closes it, Enter runs an
item, Escape closes the menu and gives the focus back to where it was.

## The tree

The tree's folders are DBA Dash's, in its order. At the root, over the whole fleet: Configuration, Checks, HA/DR,
Storage, Jobs, then pgvigil's Doors and Admin, then Reports, then the tag folders. Each top-level tag folder (one per
value of the first `ui.group_by` key, or one per written tag when `group_by` is empty) holds the same Configuration,
Checks, HA/DR, Storage, Jobs and Reports over its own instances only (`?tag=` on every page they open), then its
instances, as DBA Dash's tag folder does. A tag folder carries only the pages that read its instances: the pages that
read the whole repository whatever folder is open (Diff, Thresholds, Data retention, Recycle Bin, Custom reports,
Community tools, Report mail, Doors, Admin, Alert rules) stay at the root, and a page that holds one engine's data
(SQL Server options, TempDB, Flushed Plans, Server Services; PostgreSQL options, Replication, Extensions, Corruption,
Versions, Table size, Backups, Roles, DMS, Custom report, Disk report, Storage, Growth, Indexes, Jobs) is left out of a
folder whose instances are all of the other. The folder's tab strip shows the same pages. An instance's folders follow DBA Dash's
order too: Configuration, Checks, HA/DR, Storage, Databases (PostgreSQL; a SQL Server instance's databases are pages),
Jobs, then Performance (and Logs on SQL Server), then Reports.

- **'(no env)'** holds the instances without a value of the grouping key (DBA Dash's '[N/A]' folder) and carries the
  same folders, at `?tag=env:` (an empty value: the instances with no `env` tag).
- **'untagged'** (with `group_by` empty, an instance with several tags sits in several folders) holds the instances
  with no tag at all, at `?tag=untagged`. DBA Dash groups by one tag name, so it has no counterpart: it is pgvigil's.
- A **nested** folder (`group_by: [env, team]`: the team folders inside an env folder) holds instances only: no single
  tag scopes it. The root's folders keep a tag that no top-level folder carries (a bookmark, a link from a page), so
  the tree still leads to that scope's pages.
- DBA Dash's tree also has Extended Events folders (root, tag, instance); pgvigil has no Extended Events page at the
  root, so there is none under a tag either. DBA Dash's Group menu (one tag name per user, saved per user) is not
  pgvigil's: the grouping is the configuration's `ui.group_by`, the same for every user.
- Configure (Drives) under 'untagged' or '(no env)' sets the root's thresholds and says so: no threshold level exists
  for the instances a tag is missing from.

| Node | Menu |
| --- | --- |
| All instances (the fleet root) | Refresh, Add Connections..., Find Database, Open in a new tab |
| An instance | Find Database, Refresh, Instance Actions > (Pause/Resume Collections..., Configure Schedule..., Connection Options..., Add Alert Blackout...), Open in a new tab |
| An instance's Jobs or Databases folder | Filter, Refresh, Open in a new tab |
| A job | Job Info, Configure Thresholds, Start/Stop Job, Refresh, Open in a new tab |

- **Refresh** reads the fleet again and every open folder under the node (its databases, tables, jobs, drives).
- **Find Database** asks for a part of a database's name and searches the fleet (on an instance: that instance's own
  database list): PostgreSQL databases through the search (its first 50, said when there are more), SQL Server
  databases from each instance's storage read (an instance that cannot be read is counted and said). One exact match
  opens that database's page; otherwise the matches are listed as links.
- **Add Connections...** builds the `instances:` lines of `pgvigil.yaml` for a new instance (name, engine, platform,
  tags, the environment variable that holds its connection string) to copy. pgvigil reads the file when the collector
  starts: add the lines, then restart the service.
- **Instance Actions** shows the instance as the server knows it and writes the config lines that change it (for an
  instance added in Admin > Instances, Pause/Resume Collections and Configure Schedule save its Settings there instead,
  with no config line: see docs/instance-settings.md):
  - *Pause/Resume Collections...* lists each collection that has stored a read on the instance with its interval,
    last read, status and errors in the last 24 hours; an unticked collection goes into the instance's `disabled:` list
    (paused), a ticked one comes out of it. An opt-in collection (off until a schedule gives it an interval) cannot be
    ticked here: Configure Schedule turns it on. A collection paused by a `schedules:` value of 0 shows unticked and
    resumes when that value goes; one that never ran on the instance is not listed.
  - *Configure Schedule...* takes a new interval per collection, the opt-in ones too (`15m`, `1h`; a minute or more)
    for the instance's `schedules:`.
  - *Connection Options...* shows the instance's name, engine, platform, version and tags and its `instances:` line.
    The connection string is never shown: pgvigil reads it from the environment or a file the line names.
  Each dialog's lines are keys to merge into the instance's own entry under `instances:`; a second entry of the same
  name is refused when the collector starts. Add Connections offers the platforms the config accepts for the engine
  chosen and says when the name is in the fleet already.
  - *Add Alert Blackout...* opens the blackout of the acknowledgement store for the instance (docs/acknowledge.md): from
    a start to an end its alerts are held, still logged, and flagged blackout; the Alerts page lists and ends it.
  Data: `GET /api/instance/collections?instance=N` (each collection's interval as the server was given it, 0 =
  disabled, and its `collection_dates` / `collection_log` rows).
- **Filter** (a PostgreSQL instance's Jobs and Databases folders) shows the folder's children whose name holds the text
  typed, with a line under the folder that says how many of how many and a Clear button. The tree draws an instance's
  first 30 jobs: the line says so when there are more, and the Jobs tab lists them all. It holds while the page is open.
- **Job Info** opens the job's page. **Configure Thresholds** opens the job's thresholds at its three levels (the job's
  own, the instance's, the root's), as the Jobs tab's Thresholds button does. **Start/Stop Job** opens the Execute Job
  window: the job, whether it is enabled, its last run and whether it runs now, with **Start** (pgAgent's Run now) and
  **Stop** (cancels the running run's backend). Both go through the actions door with its typed confirmation and its
  audit row (docs/jobs-postgres.md); a button that cannot act says why (pg_cron has no run-now call, the job is not
  running, the instance's `actions:` list does not name it).
- **Drives**: under an instance's Storage folder each volume is a node with a bar of its used share (amber under 20 %
  free, red under 10 %) and its free space ('E:\\ 12.1 GB free (5.9 %)'; 'free not known' when the read has none), a
  link to the Storage tab. Read every 10 minutes at most, and again on Refresh.

## A grid's cell menu

Below the grid's own items (Copy cell, Copy row, Copy all rows) and the grid tools' (the copies with the colours, Hide
column, Freeze, Group by, Data bars, Columns...):

- **Select row**, **Select column**, **Select all**: the grid tools' selection (Ctrl+click and Shift+click make it by
  hand) of the cells drawn (a grid past its first 200 rows says so in the item); the line above the grid gives its
  count, sum, average, min and max.
- **Filter by value** sets the column's filter: on a number column the value exactly as shown (`=`, units included),
  on a text column the rows whose cell holds the words (the item says 'contains'). **Exclude value (contains)** keeps
  the rows whose cell does not hold them. **Clear filters** empties every filter of the grid.
- **Export Excel** (higher in the menu, after the copy lines, where DBA Dash's grid menu has it; `docs/export.md`): the
  grid alone as an .xlsx with its colours and number formats (the bar's Export .xlsx takes every grid of the page).
- `Rows: n | Cols: m`: the rows the filters leave and the columns shown.
- `[column] Sum: ... | Avg: ... | Min: ... | Max: ...`: the clicked cell's column over every row the filters leave (past
  the drawn page too; an empty cell is no number), in the column's own unit (bytes, durations, percentages as the screen writes them). With a selection of two cells or more:
  `Selected Cells: n (k numeric) | Sum: ... | Avg: ... | Min: ... | Max: ...`. A click on either line copies it.

## Saved views (the View button)

The Summary, the Performance summary and the three Slow queries pages (the fleet's, an instance's and a SQL Server
instance's) carry DBA Dash's View drop-down: a button `View: <name>` in the page's toolbar (`View: None` when no
view is loaded, `(changed)` after it while the page's picks or its grids' layouts differ from the loaded view's). A view is a named state of one page:

- the page's own picks, as the page has them when it is saved (every one, not only those in the address):

  | Page | Picks a view keeps |
  | --- | --- |
  | Summary | Focused View, Show Test Summary, the test summary's height, the instance grid's sort |
  | Performance summary | none of its own: the layouts below |
  | Slow queries (fleet, instance) | Threshold, Group By, Database, Top, Events, Auto Size Columns |
  | Slow queries (SQL Server instance) | Group By, Database, Top, Events, Auto Size Columns |

- the layouts of the page's grids (hidden columns, data bars, frozen columns; `Columns...` and the cell menu's items),
  each kept under the grid's heading;
- the time range, when **Save the time range** is ticked.

The menu lists the page's own items first (the Summary's Focused View and Show Test Summary, Slow queries' Auto Size
Columns), then `{None}`, the shared views and the user's own (`(shared)` or `(mine)`, `- default` on the one that loads
by default, a tick on the loaded one), then **Save**, **Save as...**, **Rename...** and **Delete...**. An item the user
may not use is off with its reason beside it: saving is off under `-no-login`, on `pgvigil demo -serve` and without
the actions door's audit login; a shared view is written only by the users `views.shared_editors` names
(`docs/configuration.md`); a personal view only by its owner. **Save as...** asks for a name, who sees it (Only me, or
Everyone), whether it loads by default on this page, a folder, and whether to keep the time range.

- **Loading**: a view lives in the page's address (`view=<id>` beside the page's picks, which Save as and opening a
  view write there), so a reload, Back and Forward and a link sent to someone bring it back; a pick the link carries
  wins over the view's. Entering one of these pages with none of its picks in the address loads
  the user's own default for the page, else the shared default, once; a default's saved time range applies only when
  the view is picked from the menu or its link is opened, so entering the page keeps the range you were on. A page's
  default resets its picks each time the page is entered; `{None}` (`view=none`) keeps them.
- **Layouts**: a loaded view's layouts lie over the browser's own grid choices and never overwrite them: `{None}`,
  another page or a tab change gives your own back. A grid the view does not name draws with no choices while the
  view is loaded. A column hidden or a bar added on a loaded view marks it `(changed)` until **Save**; a view's layout
  whose grid is no longer on the page is said under the toolbar ('n grid layouts of this view no longer match:
  skipped (...)').
- **Another's view**: a link to someone's personal view opens its picks (they are in the address) but not its layouts
  ('view N is not yours to open: its address applied, its layouts not'); a view of another page is not applied.
- **Save** writes the page as it is now: its picks, its grids' layouts and, for a view that keeps the time range, the
  range on screen. **Rename** keeps the stored range.
- **Two people at once**: saving a view someone changed since you loaded it is refused with the reason and a
  **Load the stored one** link; nothing is overwritten. A name already taken is refused in words.
- A report mail's render (the Daily checks mail, Send now, a schedule) takes no view: no default is loaded and
  `view=` is ignored.

## Tools (the bar)

| Item | Opens |
| --- | --- |
| Open Deadlock Graph \| *.xdl | a deadlock graph as SQL Server wrote it (system_health's `<deadlock>`, or Profiler's and trace flag 1222's `<deadlock-list>`): the graph as the Deadlocks tab draws it, its sessions and its locked resources as grids; a file of several deadlocks shows the first and says how many |
| Open Query Plan \| *.sqlplan | a showplan: each statement with its cost and its own warnings (an implicit convert, an excessive grant, a wait), its operators as an indented tree with their parent node (object, estimated rows per execution and estimated executions, actual rows and executions over all of them - marked where ten times off the estimate for all executions -, each operator's own share of the statement's cost, warnings: spills in granted / used memory and pages written) and the missing indexes the optimizer named; a cursor plan is not read, and said |
| Open Grid or Data Set \| *.json;*.csv;*.gz | rows as a grid: a JSON array of rows, `{columns, rows}` as the API writes it, an object of those, or a CSV with a header; gzipped too |
| Open STATISTICS IO / TIME messages \| *.txt;*.statistics.json | SQL Server's STATISTICS IO / TIME messages as SSMS's Messages tab gives them (pasted into a .txt), or a saved .statistics.json: the reads and times per table and statement, in the viewer 'STATISTICS IO / TIME: <file>' |

A file dropped anywhere on the page opens the same way (its extension decides the viewer; its contents only when the
extension says nothing), and so does a deadlock graph or a showplan pasted outside a field. A grid in a viewer has
every grid's menu. The file is read in the browser only: nothing is sent to the server. A .sqlplan saved by SSMS is UTF-16; the
viewer reads UTF-8 and UTF-16 by the file's byte-order mark. Files up to 64 MB.

## Data retention

Configuration > Data retention lists every table of the repository's `pgvigil` schema: its size (its partitions,
indexes and TOAST included), its estimated rows, what the retention does to it, the time column a row delete compares,
the table whose rows keep it ("same as": a query text stays while a sample names it), its partitions, its oldest
partition or oldest row, the days that oldest row is from now (the actual retention), and what a purge with a given age
would drop. The rules are read from `pgvigil.purge()` as installed, so the page follows the function:

| Retention | Meaning |
| --- | --- |
| monthly partitions | a partition is dropped once its whole month is older than the age |
| daily partitions | a partition is dropped once its whole day is older than the age (SQL Server's running-queries samples) |
| rows older than the age | rows whose time column is older than the age are deleted |
| rows absent longer than the age | rows no longer present at the source, older than the age, are deleted |
| rows *table* no longer names | rows are deleted once the other table no longer refers to them (with "older than the age": both) |
| rows older than the age, under conditions | the age and conditions of its own (a channel no longer configured, the newest row of each instance kept) |
| *n* rules | the purge deletes from it in more than one way, each listed |
| kept whole | the purge never deletes from it (inventories, settings, the current state) |

The rules are read from `pgvigil.purge()` and the `*_purge` functions it calls (SQL Server's running queries, reads and
plan cache).

A partitioned table that `purge()` does not name is marked: it grows until a release names it. The actual retention is
marked amber, with the words 'older than the age allows', where a table under a rule of the age alone holds rows older
than it (a month more for monthly partitions, a day for daily ones): the purge is not scheduled, or runs with a longer
age. A rule with conditions keeps older rows on purpose and is not judged.

The age itself is the `-days` of the scheduled `pgvigil purge` (deploy/pgvigil-purge.timer runs it with 30); the
server is not told it, so the page takes an age to preview (kept in the browser) and does not change it. Each oldest
row is read with a 2-second limit, all of them within 20 seconds; a table too large to read in that time says so.

Data: `GET /api/retention?days=N` (N from 1 to 3650, default 30). Read only: the sizes come from the catalogue, the
oldest rows through `SELECT`, which `apply_roles()` grants the UI's login on every table but the `ui_` ones (the
logins' own tables: their oldest row is not read, and the page says so).
