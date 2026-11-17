// crview-check.mjs - the browser check of parity set 3 (the 44 rows of 11-16 21:48: DBA Dash's custom report view,
// three grid rows, three PM rows), driven over the Chrome DevTools Protocol with node's own WebSocket, as
// scripts/menu-check.mjs is. scripts/proof-crview.sh starts the demo serve (a custom report of each engine seeded, the
// SQL Server container for the SQL Server report) and runs it; PGVIGIL_CRVIEW_ONLY=<prefixes> runs some cases.
//
// EXPECTED (written 11-17 03:1x before any run; the RED run on rel-j16-last 65083820: every case FAIL in its own words -
// the control, the words or the API it reads is absent - no case 'threw'; 'FAIL: <n> case(s)', rc 1). On the build,
// each case as named (a case of both engines runs on the PostgreSQL report and the SQL Server one):
//  task 2 - who sees a report
//   CR-visibility  a report with rules (instance type PostgreSQL only; tag env:prod; include one instance, exclude one)
//                  is listed only where the rules match - on the fleet tree, under env:prod, on the included instance,
//                  never on the excluded one or a SQL Server instance; the editor's rules section warns 'these rules
//                  match no instance' for rules that match none; Clear Rules lists it everywhere again (DBA Dash L84)
//   CR-role        a report whose access is 'admin': an operator's page says 'You do not have access to this report'
//                  and its run POST answers 403 with the role's words; an admin runs it (L85)
//  task 3 - the run
//   CR-cancel      a report that sleeps 60 s: Cancel ends it within 5 s, the status 'Cancelled', the statement gone
//                  from the server (pg_stat_activity / sys.dm_exec_requests read by the proof) (L89)
//   CR-timer       while it runs the status shows a running hh:mm:ss that moves; then 'Completed in <t>'; a report
//                  that RAISE NOTICEs (PRINTs on SQL Server) with 'status from messages' shows the last message as its
//                  status (L90)
//   CR-paramreq    a required parameter left empty: no run, 'Parameters are required to run the report' with a Set
//                  Parameters link that focuses the first empty one (L92)
//   CR-pickers     a standard picker (a list), a text picker (Enter runs) and a query picker (its values from the
//                  report's picker query) shape the run's parameters; the menu bar marks a picker not at its default (L95)
//   CR-assoc       Associate Collection lists the collections a Trigger Collection button runs now; the button's run
//                  reaches the collector (its log row) - or the case says 'P13's trigger route not on this base' (L98)
//  task 4 - the result sets
//   CR-select      with three result sets a Select Results list (by name, plus All) shows one or all; one set leaves
//                  the list out (L102)
//   CR-restore     Restore Default View undoes a hidden column, a filter and a resized panel (L103)
//   CR-switch      a paired report's switch button opens its pair with the filters both declare; Back returns (L106)
//   CR-urllabel    a report's URL label is a link to its URL, opening a new tab, under its description (L107)
//   CR-renameset   Rename Result Set names the list entry and the grid's header, kept with the report (L110)
//   CR-script      Script Report opens the code viewer with the report's definition, its pickers and its saved
//                  customizations, re-creatable (L111)
//   CR-singlepage  with several result sets a toggle fits them to one screen or lets each grow and the page scroll (L112)
//   CR-toggle      Toggle Charts / Toggle Grid hides one panel (L113)
//   CR-setbar      with several sets each has its toolbar: maximize / restore, its name, Columns, Copy, Clear Filter
//                  (marked while a filter is on), Rename (L114)
//   CR-resize      a set's bottom edge drags, at least 100 px, by mouse and by keys (L115)
//  task 5 - the columns
//   CR-layout      Save Layout keeps each set's column visibility, width and order and the chart / grid split for
//                  every viewer; Reset Layout clears it (L109, L208)
//   CR-renamecol   Rename Column's alias is the header for every viewer (L116)
//   CR-coltip      Set Column Tooltip's text is the header's title (L117)
//   CR-localtz     a time column shows the browser's zone by default and the stored zone (UTC) when its box is off (L118)
//   CR-highlight   Highlight Cell Value opens the colour rules prefilled with the clicked value and column (L123)
//  task 6 - the links
//   CR-addlink     Add Link offers None, URL (with its trust words), Text (SQL / JSON / Markdown / XML), Drill Down,
//                  Navigate Tree; the target column (L120)
//   CR-drill       a drill-down maps a column to the target report's parameter and opens it in a new tab, in this
//                  one (Back returns) or in a panel under the report; the user's filters carried (L125)
//   CR-navtree     a Navigate Tree link opens the row's instance (and database) at the chosen tab (L126)
//   CR-textlink    a text link opens the value in the code viewer with its syntax (L127)
//   CR-url         a URL link opens the column's URL in a new tab; a value that is no http(s) URL is no link (L128)
//  task 7 - every grid
//   G-reorder      a header dragged (and moved by keys) reorders the columns; kept with the grid's choices (L203)
//   G-0x           a SQL Server binary cell shows 0x and its hex, cut with its length past 32 bytes (L205)
//   G-tipcap       a cell's title text stops at 1,000 characters with '...'; the setting changes the cap (L206, RELNOTES L129)
//  task 8 - custom tools
//   CR-tools       an instance's own procedure listed as a tool runs with its parameters and its result drawn (L169);
//                  the role per tool: 'waits on D1' until Allen's roles answer
//  task 9 - the PM rows (PostgreSQL)
//   PM-vacthr      Vacuum: where each table's autovacuum thresholds are, against its dead and changed rows (map-pm-web.tsv:237)
//   PM-headroom    Vacuum: per database, the xid and multixact headroom left before the forced freeze (:238)
//   PM-iosummary   I/O Summary: pg_stat_io's reads, writes and their times by backend type and object over the range (:245)
//  task 10 - the charts
//   CR-addchart    Add Chart: StackedArea, StackedColumn, Column, Line, Pie (Doughnut), Scatter from a result set with
//                  its X column, metrics and series column; each drawn (L130)
//   CR-syschart    Add System Chart (CPU, waits, IO, blocking) and Save System Chart State (L131)
//   CR-chartlayout Chart Layout (rows, columns, auto), Chart Location (top, bottom, left, right), Delete All Charts
//                  after a confirm (L132)
//   CR-chartmenu   each chart's Configure, Move Up, Move Down, Delete (L133)
//   CR-pointdrill  a click on a point opens the drill target of the row behind it (L134)
//   CR-chartopts   the X axis bound to the date range, an overlay from another result set, a chart hidden while a
//                  parameter is set (L135)
// The last line 'crview-check: <n> FAIL' (0 = every case ok); rc 1 when any failed.
//
// RED STUB: the cases are written in task 1's next commits; until then this file runs none and says so.
console.log('crview-check: the cases are not written yet (task 1 in progress)');
console.log('crview-check: 1 FAIL');
process.exit(1);
