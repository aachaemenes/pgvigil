#!/usr/bin/env bash
# Proof of the tab export (task 54; the workbook as DBA Dash writes its own and the grid tools, task 153): a demo
# fleet is seeded into a throwaway database and served on loopback, a headless Chromium opens the fleet Summary,
# Backups, Jobs, Storage, the Storage folder's Drives, DB Space and Files, the fleet Slow queries and one instance's tabs, presses the bar's 'Export .xlsx' and 'Export CSV' on each and
# saves what downloads; each file is read back with python3's zipfile and csv and graded against the page it came
# from, cell by cell for the colours. Needs go, psql, chromium, node, unzip and python3, the web bundle built with the
# export wired into the bar (internal/web/dist/app.js carries 'Export .xlsx': `cd web && npm run build` after the
# wiring in main.ts), and a PostgreSQL for the throwaway database:
#   PGVIGIL_ADMIN_DSN  keyword-form connection to a cluster as a login that may create a database
#   PGVIGIL_DEMO_WAIT_S the seconds to wait for the seeded demo to serve (default 240; a loaded machine seeds slower)
#   PGVIGIL_EXPORT_OUT a folder to keep the downloads in (default: removed with the proof's temporary folder); the
#                      local comparison with DBA Dash's own export reads its Test Summary from there
#                      (scripts/proof-export-dbadash.py <that .xlsx> <DBA Dash's summary-1.xlsx>)
#   PGVIGIL_EXPORT_SHOTS a folder for the shots of each new menu open, light and dark (the en-US run only)
#   PGVIGIL_PYLIB      a folder that holds the openpyxl package, when python3 has none of its own
#   PGVIGIL_EXPORT_NEED the parts that must be graded: 'tools' (the default: the grid tools through the grid's menu,
#                      which needs ui.ts to send 'pgvigil:gridmenu'), 'lib' (openpyxl opens every workbook), both as
#                      'lib,tools', or 'none'. A part not named is 'not checked', said so, when its tool is missing
# Expected:
#   names      fleet_Summary_<yyyymmdd-hhmm>_<yyyymmdd-hhmm>.xlsx and .csv; <instance>_Table-Size_<from>_<to>.xlsx and
#              .csv.zip (the Table Size tab has two grids), the instance named as in the tree
#   summary    sheets: the page's sections in page order - each grid (a sheet named by the heading above it, h2 to h5, or
#              by the name the page gives it: data-sheet, a tile row's aria-label), each property card, tile row and the
#              Needs attention lines (every line, also past the 8 the page draws) as an Item | Value | Status table, one
#              sheet per chart that has numbers, named by its title, in the charts' page order, no other - then 'About'
#              LAST (D-A: the window, the zone, the export's time, the source, every sheet's rows; also the document's
#              properties); no
#              name a numbered repeat (X2: two headings equal after the cut keep their start, an ellipsis and the words
#              where they part; a name taken goes under the heading above it; sections sharing a heading take 'tiles' or
#              'properties'); no pane (X6); each column's width the rule's (export.ts colWidth, DBA Dash's AdjustToContents:
#              Carlito widths, header 1.0286 x bold + 22.19 px, a cell 1.0738 x + 0.52 px, (px - 0.025625) / 7, at most
#              150) within a pixel; the header row DBA Dash's (FF0063A3, white, bold: X4); every cell the named pair of the
#              status the screen shows or plain (X0: OK FF006638 / white, Warning FFE49325 / dark FF1D1300 (X3), Critical
#              FFAB1F26 / white, N/A FFE0E1E9 / FF004F83, Acknowledged FF1B6AA3 / white, a link cell FFF1F1F6 / FF004F83);
#              the two grids named 'Test Summary' and 'Instance Summary'; each sheet's data rows = the grid's rows on screen
#   page       (D-B) the page sheet with pictures is parked: no page sheet, no drawing, no picture in any workbook (X12)
#   table      every data sheet is an Excel table (P1; an empty grid's over its header and ONE empty row, P2, as DBA
#              Dash writes it): the sheet names one table part (no sheet autoFilter beside
#              it), the part's ref and its autoFilter's cover the sheet (A1 to the last column and row, = the sheet's
#              dimension), its column names are unique whatever the case, none empty, and equal to the header cells in
#              order, which are shared strings (xl/sharedStrings.xml, as Excel stores a table's header); its tableStyleInfo
#              DBA Dash's (no style name, showRowStripes 1: no stripe drawn);
#              ids and names unique in the workbook; the part in [Content_Types].xml. A grid a filter leaves
#              without rows (the Table Size tab's second grid, filtered to nothing) is a table of its header and one empty
#              row, no sheet filter, no _FilterDatabase (changed by P2: it kept the plain sheet filter and no table)
#   colours    (X0) every cell of every row the page draws (a grid draws its first 200 rows; the read must return
#              exactly those), against the page: the status the screen shows on it (read by the driver's own code, not
#              export_colours.ts: the cell's status, else a badge's in it, a link) is its named pair in the file, any
#              other cell plain - no fill, no text colour of its own, not bold; the two Table Size columns the driver gives
#              a bare class (crit, warn on the first row, ok on the others: a whole column, as X18 wants) take their
#              named pairs (export.ts statusOf reads a bare class as its status).
#              Counted per sheet (the lines 'cells:')
#   percent    Storage: every 'free' cell a number under numFmt 167 ('0.0%', DBA Dash's P1) whose value is the screen's percent / 100;
#              its CSV keeps the percent figure itself (12.5, not 0.125)
#   drives     the Storage folder's grids at the root (task 176): Drives (its metrics grid, every status), DB Space and
#              Files each show a grid with rows, named fleet_Drives_ / fleet_DB-Space_ / fleet_Files_, and are graded as
#              every page here is (sheets, tables, colours, csv); Drives drawn with the status All and Toggle Metrics
#              pressed, Files with the status All (read from the page); DB Space's allocated (GB) and used (GB) numbers
#              in the workbook (no figure left as text; used's text only 'not read'), each figure one decimal on the
#              page ('12.0') and a number under '0.0' in the workbook (dbs_onedec, every DB Space grid)
#   library    when python3 has openpyxl, each workbook loads with it without an error, its tables counted; none = said
#   tools      when the grid's menu carries the grid tools (ui.ts sends 'pgvigil:gridmenu'; not wired = said), on
#              the fleet Backups grid: 'Copy the rows as HTML with the colours' puts a table on the clipboard whose
#              header is #0063a3 and whose cells carry each status the screen shows as background and text colour, a
#              row per grid row; 'Copy the rows as Markdown' a pipe table of rows + 2 lines; Ctrl+click on two numbers
#              says '2 cells selected' with their sum, a plain click clears it; 'Group by platform' lists one group
#              per platform, their rows adding up to the grid's; 'Data bars on failed' draws a bar on each failed
#              count above zero, the largest at 100 %; 'Freeze the columns up to platform' makes the first two sticky;
#              'Hide column platform' hides it, keeps the choice in localStorage and after a reload it is still
#              hidden, frozen and barred; the workbook exported then has no platform column (one column fewer, the
#              table too); 'Columns...' lists every column and 'Reset this grid' brings all back and forgets the choice
#   tables     sheets: the screen's sections, Tables and Biggest tables named by their headings; Biggest tables sorted
#              by 'total' on screen first (the click changes the order), its sheet's 'table' column in the screen's order
#              and every 'total' and 'live rows' still a number (a page model out of step with the sort turns them to
#              text); a time cell with numFmt 168 ('yyyy-MM-dd HH:mm', DBA Dash's), a count or a size with 0 (General, as
#              DBA Dash writes one); a size column in ONE unit named in its header ('size (GB)'), the cells plain numbers
#              (X7: no '#,##0" B"' or other custom format)
#   roles      the instance's Roles tab: the privilege grids sit under h4 headings; every sheet's name follows the
#              heading above its grid (or the heading above that one, 'Role beta Database privileges'), none a numbered
#              repeat (the tiles 'Roles tiles', the grid 'Roles')
#   activity   the instance's Running queries tab over 7 days: Per sample shows 500 rows; 'About' carries 'the newest
#              500 of N samples' beside its rows; every workbook's 'About' has a Time zone row ('<zone> (UTC+hh:mm at
#              export)', the value read)
#   slow       the fleet's Slow queries tab (24 h): the hand-built Per day table's statements column numeric and its day
#              column dates under 'yyyy-MM-dd' (its sheet 'Per day': the time in its heading left out); a duration column
#              plain numbers in one unit named in its header (X7, X8: no custom format)
#   units      (X7) on EVERY page no number with a unit is left as text on a grid sheet or a chart's series sheet (a size,
#              a duration, a rate, a count of days; the mixed list by column only: an Item | Value | Status sheet's Value,
#              the Instance Summary's ages as DBA Dash's Summary writes them, a Files growth column holding a percent);
#              every column whose header names a unit the export added holds the screen's figure converted into it, within
#              the figure's shown precision (1024 steps for sizes, 1000 / 60 for times), a cell the screen shows with no
#              number empty in a column of days or of a rate; a chart's first figures in the unit its axis draws, named
#              and converted (one unit per axis); no bare number left as text on any grid or chart sheet (a column headed
#              'version' and '0042' aside); the instance Storage page graded as every page
#   values     (X7-X9) an Item | Value | Status sheet's Value is typed by its content: no bare number left as text
#   db         a database's drill page: its statements' durations (the columns headed ' (ms)' / ' (s)' / ' (min)') are
#              numbers under General (X7), two at least and not all equal
#   sqljobs    (decision (b)) the SQL Server instance's Jobs tab: graded as every page here; each job's step grid named by
#              its job (data-sheet), no numbered repeat
#   dbspace_i  the SQL Server instance's DB Space page: graded as every page here; its grid's allocated, used, data and
#              log headed '(GB)' on the page and in the workbook, each cell a number rounded to 0.1 equal to the screen's
#              (used may be blank), no text; one decimal on the page, '0.0' in the workbook (dbs_onedec)
#   dbspace_p  a PostgreSQL instance's DB Space page: graded as every page here; its grid's allocated (GB) and used (GB)
#              only (no data / log column), allocated a number rounded to 0.1 equal to the screen's, used 'not read' throughout;
#              allocated one decimal on the page, '0.0' in the workbook (dbs_onedec)
#   perf       (P03) the fleet's Performance summary: graded as every page here; its CPU histogram column (a picture of
#              bars, the top bucket painted critical even when empty) has no fill in any row
#   reader     the screen's colour of a cell is read on its own terms, not by export.ts's rule: a status cell, else the
#              worst of the marks drawn in it (a badge, a dot, a data bar's fill, a span marked warn / crit, each with
#              a size on the screen) and of its texts computed in the critical or warning colour, else a bare class
#   colours    (E2-4's reader) web/src/export_colours.ts: its unit tests (web/src/export_colours.test.mjs, Node, stand-in
#              elements) all pass; in the browser on the fleet Summary, the reader gives the stylesheet's own colours
#              (app.css): a header cell 004F83 / FFFFFF, status cells ok 006638 / FFFFFF, crit AB1F26 / FFFFFF, 'no sample'
#              E0E1E9 / 004F83, a plain cell no fill of its own and 1B2230, a link 2259C8 with no fill; a planted
#              rgba(34, 89, 200, .14) cell on a panel E0E8F7 and a planted color-mix(in srgb, #1b2230 50%, transparent)
#              text 8D9097 (each within 1 a channel: rounding); under data-theme dark the same plain cell E3E6EB with no fill
#              and the header 004F83; the theme put back
#   sections   (E2-1's reader) every page the proof opens is read as its visible sections in page order (heading, grid,
#              property card, chart, tiles, chips, disclosure, attention strip, calendar, table, list, note, and 'other'
#              for any text outside those; controls are not sections), printed per page; self-test on an instance's
#              Summary: sections planted at the end of the page are read in their place (a heading and a tile row, a closed
#              disclosure's summary line, an open disclosure's summary and its grid, an unknown element's text as
#              'other'), and none of the planted hidden ones (a closed disclosure's grid, display none, a visually-hidden
#              note, visibility hidden) is read; the planted sections removed after
#   offpage    (E2-4's reader, the rows a grid does not draw: readRows) the fleet Findings' grid has over 200 rows, 200 drawn
#              before its 'Show all' and every row after; each drawn row's cells read where they are (paintOf: the cell,
#              and the badge, pill, dot or link in it) equal the same cells read through readRows' shell from detached
#              copies of the rows (as ui.ts's allRows() builds the rows past the page: rowEl's classes and content), every
#              row, the rows past 200 included and coloured ones among them; the shell was the table's own classes, hidden,
#              fixed, right after the table, and left nothing behind (the page's height, the grid's rows and its
#              parent's children as before); self-test: the same copies read bare (detached: no computed style) differ
#   routes     (E2-1's inventory over the whole app; the first language only) every route of the app's route tables
#              (web/src/router.ts, read as scripts/proof-darling-alerts.sh reads them: rootTabs, instanceTabs,
#              mssqlInstanceTabs, drillTabs) is opened - rootTabs at the fleet, instanceTabs on the demo's PostgreSQL
#              instance, mssqlInstanceTabs on its SQL Server instance, each drill page by the first link to it on the
#              pages walked - and renders (no Loading note left in 15 s) with at least one visible section (SECTIONS);
#              a line per page (its sections by kind), and as said, not graded: the pages that show an error box and the
#              pages without the bar's export; with PGVIGIL_EXPORT_OUT the inventory is kept there as
#              sections-inventory.json (the list E3's page sheet is graded against)
#   csv        the Summary's .csv: its data rows (python csv, header excluded) = the grid's rows; the Tables
#              .csv.zip: two CSVs, each with its grid's row count; a UTF-8 BOM first (every page's CSV is graded so); a
#              .csv.zip's files named by their grids' sheet names in the workbook (no numbered repeat)
#   gridmenu   (P03) the fleet Backups grid's menu has one Export Excel line (no other line starting so: task 172's
#              'Export Excel (this grid)' out of treemenu.ts, P03's WIRING BLOCK), right after its copies (DBA Dash's grid
#              menu: Copy, then Export Excel); clicked, it downloads fleet_Backups_<sheet>_<from>_<to>.xlsx: that grid's
#              sheet, then 'About' (X12: the grid alone), its rows, every cell its named pair or plain, the widths by the
#              rule; the grid's line says 'Exported <file>'
#   summary drop-down (P03) the fleet Summary's bar has Export to Excel (aria-haspopup menu) with Export Summary and
#              Export Test Summary; each downloads one grid's workbook ('Instance Summary' / 'Test Summary', then
#              'About'), graded as above; the Test Summary by DBA Dash's rule (summary-1.xlsx holds it too): a count 0
#              green, above 0 in its column's status, a test's name in its row's worst of critical and warning else green,
#              the counts General
#   charts     (P03) a line chart's and a ring's menu (the root DB Space first, else an instance's pages) has Export
#              Excel; each downloads the chart's numbers as a sheet, then 'About', its rows = the menu's 'Saved N points /
#              slices as Excel'; the line's first column 'time', every point under 'yyyy-MM-dd HH:mm'; the ring's name /
#              size / share, every share under '0.0%', the shares adding up to 1; the page's own workbook holds the line
#              chart's numbers sheet equal to it cell by cell, and no picture (D-B, X12)
#   emptyhidden (P03) a grid with rows over 24 h that is an empty grid's note in a 2001 window under the same heading
#              and columns (the first of seven candidate pages that has one); a column hidden with its menu over 24 h;
#              the 2001 page's Export .xlsx: that grid's sheet is its header row without the hidden column
#   shots      with PGVIGIL_EXPORT_SHOTS: grid-menu, summary-export, chart-menu-line, chart-menu-ring, each -light and -dark
#   libre      when soffice is on the machine, each .xlsx converts to CSV headless (the file opens); none = said
#   xcheck     (X0-X12) scripts/xlsx-check.test.py (its built workbooks, a probe per shape) all ok; every downloaded .xlsx
#              passes scripts/xlsx-check.py rules: the file rules DBA Dash's own exports pass (a grid sheet per grid, the
#              named colour pairs only, the fixed header, one table each, no pane, the formats General / '0' / '0.0%' /
#              '0.00%' / 'yyyy-MM-dd HH:mm' / 'yyyy-MM-dd' and a fixed count of decimals '0.0' .., booleans, widths, no app
#              link, no picture); 'ok xcheck Xn' only on one PASS line per workbook. X18 (a status column has a status
#              or N/A on every cell) on every page; scripts/x18-scan.py first: every status column of web/src (a
#              warning or critical badge, inline or through a helper) has a cls (its values read by review) or is on its
#              reviewed list with each badge of class ok / none
#   decimals   (X13) no number cell shows more decimals than its column shows on the screen (nor fewer under a fixed
#              format): the read-back takes each grid column's most decimals from the screen's text (a grid drawn whole;
#              not a chart's series: the driver reads one point of it) into page-<lang>.json and runs
#              scripts/xlsx-check.py rules --page on every page's workbook; each one judged, none off
#   volumes    an instance's Storage page: each volume its Volumes chart draws is a row of the 'Volumes' grid sheet
#   languages  all of the above twice: Chromium in en-US and in fr-FR (navigator.language says so; 1234567 shows
#              without a comma: the locale's grouping space), the numbers numeric in both
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_export_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
XCHECK="$PWD/scripts/xlsx-check.py"   # the file rules X0-X13 (every downloaded workbook; X13 with the screen's decimals, in check.py); $PWD is the repository's root (cd above)
[[ -f "$XCHECK" ]] || fail "scripts/xlsx-check.py is not in $PWD"
ok() { echo "ok   $*"; }
cleanup() {
  [[ -n "$SRV" ]] && kill "$SRV" 2>/dev/null || true
  [[ -n "$CHR" ]] && kill "$CHR" 2>/dev/null || true
  psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "drop database if exists $DB with (force)" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
for t in go chromium node psql unzip python3 curl; do command -v $t >/dev/null || fail "$t is not on this machine"; done
grep -q 'Export .xlsx' internal/web/dist/app.js || fail "the web bundle has no export button: wire exportButtons into the bar (main.ts) and run 'npm run build' in web/"
grep -q 'tableParts' internal/web/dist/app.js || fail "the web bundle is older than the export's source (no Excel table writer in it): run 'npm run build' in web/"
grep -q 'pgvigil.drivesMetrics' internal/web/dist/app.js || fail "the web bundle has no Storage folder pages (drives.ts not wired in main.ts): run 'npm run build' in web/"

echo "== the colour reader's unit tests (web/src/export_colours.ts)"
[[ -x web/node_modules/.bin/esbuild ]] || fail "web/node_modules has no esbuild: run 'npm ci' in web/"
web/node_modules/.bin/esbuild web/src/export_colours.ts --format=esm --log-level=warning --outfile="$WORK/export_colours.mjs" || fail "esbuild could not compile web/src/export_colours.ts"
node web/src/export_colours.test.mjs "$WORK/export_colours.mjs" > "$WORK/colours-unit.out" 2>&1 || { cat "$WORK/colours-unit.out"; fail "the colour reader's unit tests"; }
ok "colour reader: $(tail -1 "$WORK/colours-unit.out")"
echo "== the sheet names' unit tests (web/src/export_names.ts)"
web/node_modules/.bin/esbuild web/src/export_names.ts --format=esm --log-level=warning --outfile="$WORK/export_names.mjs" || fail "esbuild could not compile web/src/export_names.ts"
node web/src/export_names.test.mjs "$WORK/export_names.mjs" > "$WORK/names-unit.out" 2>&1 || { cat "$WORK/names-unit.out"; fail "the sheet names' unit tests"; }
ok "sheet names: $(tail -1 "$WORK/names-unit.out")"
echo "== the X rules' own tests (scripts/xlsx-check.test.py: built workbooks, a probe per shape)"
python3 -I scripts/xlsx-check.test.py "$XCHECK" > "$WORK/xcheck-unit.out" 2>&1 || { cat "$WORK/xcheck-unit.out"; fail "the X rules' own tests"; }
ok "X rules' tests: $(tail -1 "$WORK/xcheck-unit.out")"
echo "== a status column's other cells on the screen (scripts/x18-scan.py)"
python3 -I scripts/x18-scan.py web/src > "$WORK/x18-scan.out" 2>&1 || { cat "$WORK/x18-scan.out"; fail "a status column's other cells (scripts/x18-scan.py)"; }
ok "x18-scan: $(tail -1 "$WORK/x18-scan.out")"
# the same module as a script for the page (the driver runs it there: window.__pgvColours)
web/node_modules/.bin/esbuild web/src/export_colours.ts --format=iife --global-name=__pgvColours --log-level=warning --outfile="$WORK/export_colours.js" || fail "esbuild could not compile web/src/export_colours.ts as a script"

# the app's route tables (web/src/router.ts), read as scripts/proof-darling-alerts.sh reads them, for the route walk
python3 -I - web/src/router.ts > "$WORK/routes.json" <<'PY' || fail "web/src/router.ts: its route tables could not be read"
import json, re, sys
src = open(sys.argv[1], encoding='utf-8').read()
tables = {}
for m in re.finditer(r'export const (\w+Tabs)\b[^=]*= \{(.*?)\};', src, re.S):
    seen = []
    for k in re.findall(r"""(?:^|[{,\s])([a-z_][a-z0-9_]*)\s*:\s*['"`]""", m.group(2)):
        if k not in seen: seen.append(k)
    tables[m.group(1)] = seen
print(json.dumps(tables))
PY

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-240} s (PGVIGIL_DEMO_WAIT_S raises the wait on a loaded machine)"; }

# the driver: open a page, count each grid's rows and read the headings, press a button, wait for the download
cat > "$WORK/drive.mjs" <<'JS'
const [port, U, dl, colourFile, routesFile] = process.argv.slice(2);
const fs = await import('node:fs');
const inst = await (await fetch(U + 'api/instances')).json();
const rows = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const one = rows.find(r => r.platform === 'onprem') ?? rows[0];
const ver = await (await fetch(`http://127.0.0.1:${port}/json/version`)).json();
const bws = new WebSocket(ver.webSocketDebuggerUrl);
await new Promise(r => bws.addEventListener('open', r));
bws.send(JSON.stringify({ id: 1, method: 'Browser.setDownloadBehavior', params: { behavior: 'allow', downloadPath: dl } }));
await new Promise(r => bws.addEventListener('message', r));
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async () => {
  for (const t = Date.now(); Date.now() - t < 15000; await sleep(150)) {
    if (await ev(`(() => { const m = document.querySelector('main'); const e = m && m.querySelector('p.empty'); return !!m && m.children.length > 0 && !(e && /^Loading/.test(e.textContent)) && !!document.querySelector('#bar .export'); })()`)) { await sleep(400); return true; }
  }
  return false;
};
// the downloads folder as name -> time written: a new name is the download; a known name written again is two pages
// of one name inside one minute (Chromium replaces the file), which the checker could not tell apart
// (a name listed and gone before its stat is Chromium renaming its .crdownload: left out, the next look has the file)
const folder = () => Object.fromEntries(fs.readdirSync(dl).flatMap(f => { try { return [[f, fs.statSync(dl + '/' + f).mtimeMs]]; } catch { return []; } }));
const press = async (label, exts) => {
  const before = folder();
  const hit = await ev(`(() => { const b = [...document.querySelectorAll('#bar .export button')].find(x => x.textContent === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
  if (!hit) throw new Error('no button ' + label);
  for (const t = Date.now(); Date.now() - t < 15000; await sleep(200)) {
    const now = folder();
    if (Object.keys(now).some(x => x.endsWith('.crdownload'))) continue;
    const mine = Object.keys(now).filter(f => exts.some(e => f.endsWith(e)));
    const f = mine.filter(n => !(n in before));
    if (f.length) return f[0];
    const again = mine.filter(n => before[n] !== now[n]);
    if (again.length) throw new Error(`the download after ${label} replaced ${again[0]}: a page exported twice under one name (give the later visit another window, ?w=)`);
  }
  throw new Error(`no ${exts.join(' or ')} downloaded after ${label} on ${await ev('location.hash')}: ` + await ev(`document.querySelector('#bar .export [role=status]').textContent`));
};
// what the screen shows of each grid, read as the export reads it: the header's words, and of every row drawn each
// cell's words, the colour the screen gives it (a status cell, a badge or a dot in it, the page's own cell class) and
// whether it is drawn as a link
const SCREEN = `(() => {
  const words = e => { const f = e.querySelector('[data-full]'); if (f) return f.getAttribute('data-full'); const t = (e.textContent || '').replace(/\\s+/g, ' ').trim(); return t || (e.querySelector('[data-text]')?.getAttribute('data-text') ?? ''); };
  const pick = x => ['crit', 'warn', 'ok', 'none'].find(k => x.classList.contains(k)) ?? null;
  // the screen's colour of a cell, read on its own terms (not export.ts's rule): a status cell; else the worst of the
  // marks drawn in it (a badge, a dot, a data bar's fill, a span marked warn / crit: those with a size on the screen)
  // and of its texts painted in the critical or the warning colour (computed); else a bare class on the cell
  const probe = c => { const s = document.createElement('span'); s.style.color = 'var(--' + c + ')'; document.body.append(s); const v = getComputedStyle(s).color; s.remove(); return v; };
  const CRIT = probe('crit'), WARN = probe('warn');
  const KNOWN = '.badge, .dot, .bar-fill, .crit, .warn';
  const drawn = m => { const r = m.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const own = m => [...m.childNodes].some(n => n.nodeType === 3 && n.textContent.trim());
  const st = td => { if (td.classList.contains('status')) return td.classList.contains('ack') ? 'ack' : pick(td);
    const got = new Set([...td.querySelectorAll('*')].filter(drawn).map(m => m.matches(KNOWN) ? pick(m) : own(m) ? (getComputedStyle(m).color === CRIT ? 'crit' : getComputedStyle(m).color === WARN ? 'warn' : null) : null).filter(Boolean));
    const w = ['crit', 'warn', 'ok', 'none'].find(k => got.has(k)); if (w) return w;
    return ['crit', 'warn', 'ok'].find(k => td.classList.contains(k)) ?? null; };
  const head = c => { const x = c.cloneNode(true); x.querySelectorAll('.whatis, .filter-btn, .chart-reset').forEach(b => b.remove()); return words(x); };
  // the look the page's CSS gives a cell, read here on its own (not by web/src/export_colours.ts): the backgrounds laid
  // over each other up to the nearest solid one; the cell's fill when it differs from its table's, else a badge's in it;
  // the text colour of the first words (or the badge's) blended over what lies under them; bold at 600 or more
  const rgb = s => { s = (s || '').trim(); let m = /^rgba?\\(([^)]*)\\)$/.exec(s);
    if (m) { const v = m[1].split(/[\\s,\\/]+/).filter(Boolean).map(parseFloat); return [v[0], v[1], v[2], v.length > 3 ? (/%/.test(m[1]) ? v[3] / 100 : v[3]) : 1]; }
    m = /^color\\(srgb ([^)]*)\\)$/.exec(s);
    if (m) { const v = m[1].split(/[\\s\\/]+/).filter(Boolean).map(parseFloat); return [v[0] * 255, v[1] * 255, v[2] * 255, v.length > 3 ? v[3] : 1]; }
    return null; };
  const ov = (t, u) => { const a = t[3] + u[3] * (1 - t[3]); return a ? [0, 1, 2].map(i => (t[i] * t[3] + u[i] * u[3] * (1 - t[3])) / a).concat([a]) : [0, 0, 0, 0]; };
  const bg = e => { const L = []; for (let x = e; x; x = x.parentElement) { const c = rgb(getComputedStyle(x).backgroundColor); if (!c || !c[3]) continue; L.push(c); if (c[3] >= 1) break; } return L.reduceRight((u, t) => ov(t, u), [255, 255, 255, 1]); };
  const hx = c => c.slice(0, 3).map(v => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0')).join('').toUpperCase();
  const look = (td, table) => {
    const at = bg(td), base = hx(bg(table)); let fill = hx(at) === base ? null : hx(at), src = td, under = at;
    const b = td.querySelector('.badge');
    if (!fill && b && b.getBoundingClientRect().width > 0) { under = bg(b); fill = hx(under) === base ? null : hx(under); src = b; }
    else { const w = document.createTreeWalker(td, NodeFilter.SHOW_TEXT); for (let n = w.nextNode(); n; n = w.nextNode()) if (n.textContent.trim() && !n.parentElement.closest('button')) { src = n.parentElement; under = bg(src); break; } }
    const t = rgb(getComputedStyle(src).color) || [0, 0, 0, 1];
    return [fill, hx(ov(t, under)), Number(getComputedStyle(src).fontWeight) >= 600];
  };
  // (F2) a cell's or a header's horizontal alignment as the page computes it: 'right', 'center' or null (left / start)
  const al = e => { const a = getComputedStyle(e).textAlign; return a === 'right' || a === 'end' || a === '-webkit-right' ? 'right' : a === 'center' || a === '-webkit-center' ? 'center' : null; };
  // b: the colour is the page's own class on the cell itself (a Col's cls without 'status'), no status cell or mark
  const cell = td => ({ t: words(td), s: st(td), l: !td.classList.contains('status') && !!td.querySelector('a[href]'), p: look(td, td.closest('table')), a: al(td),
    b: !td.classList.contains('status') && !td.querySelector(KNOWN) && ['crit', 'warn', 'ok'].some(k => td.classList.contains(k)) });
  // a heading inside a region of its own (the Summary's Needs attention strip) names only the grids of that region; h2 to
  // h5 by level (export.ts headings), 'up' the heading above the one that names a grid; a grid inside an element with
  // data-sheet (a disclosure per job or per check, a totals grid) is named by it ('alone'), or - when that element holds
  // the last heading met (a pgAgent job's 'Steps') - by it then that heading ('with', oh)
  let outer = '', inner = null, last = null, upper = '';
  const lv = [];
  return [...document.querySelectorAll('main h2, main h3, main h4, main h5, main table.grid, main table.props, main p.empty[data-cols]')].map(e => {
    if (e.tagName !== 'TABLE' && e.tagName !== 'P') {
      const within = e.closest('[role=region]');
      if (within) inner = { text: head(e), within, up: outer };
      else { const n = Number(e.tagName.slice(1)); lv.length = n; lv[n] = head(e); outer = head(e); upper = lv.slice(0, n).filter(Boolean).pop() || ''; inner = null; last = e; }
      return { h: head(e) };
    }
    const inR = !!inner && inner.within.contains(e), hd = inR ? inner.text : outer, wi = inR ? inner.up : upper;
    const own = e.closest('[data-sheet]'), on = own ? (own.getAttribute('data-sheet') || '').trim() : '';
    const kind = on ? (last && own.contains(last) ? 'with' : 'alone') : '';
    const named = kind === 'alone' ? on : kind === 'with' ? on : hd, oh = kind === 'with' ? hd : '', up = kind === 'alone' ? hd : wi;
    // a grid with no row (ui.ts grid: its note carries its columns' names): the export's sheet of its header row alone
    // (a note with no column the export leaves out: null, dropped by grids())
    if (e.tagName === 'P') { const cols = JSON.parse(e.dataset.cols || '[]'); const eth = e.parentElement && e.parentElement.querySelector(':scope > table.grid-empty th'); return cols.length ? { named, own: kind, oh, up, rows: 0, head: cols, cells: [], status: [], empty: true, hl: eth ? look(eth, eth.closest('table')) : null, tests: !!e.closest('.tests'), att: !!e.closest('.attention') } : null; }
    const grid = e.classList.contains('grid');
    const cells = grid ? [...e.querySelectorAll(':scope > tbody > tr')].map(tr => [...tr.children].map(cell))
      : [...e.querySelectorAll('tr')].map(tr => { const th = tr.querySelector('th'), td = tr.querySelector('td'); return [{ t: th ? words(th) : '', s: null, l: false, p: th ? look(th, e) : null }, { t: td ? words(td) : '', s: td ? st(td) : null, l: false, p: td ? look(td, e) : null }]; });
    // a property card's sheet has the export's own 'item | value' header: the page's grid-header look, read on a probe
    // header put in the page and removed (the page draws no header over a card)
    const probe = () => { const w = document.createElement('div'); w.className = 'grid-wrap'; w.style.cssText = 'position: fixed; left: -100000px; top: 0; visibility: hidden';
      w.innerHTML = '<table class="grid"><thead><tr><th><span class="th-label">x</span></th></tr></thead></table>'; document.getElementById('main').append(w);
      const r = look(w.querySelector('th'), w.querySelector('table')); w.remove(); return r; };
    const th0 = grid ? e.querySelector(':scope > thead > tr:first-child > th') : null;
    return { named, own: kind, oh, up, rows: e.dataset.rows ? Number(e.dataset.rows) : cells.length, head: grid ? [...e.querySelectorAll(':scope > thead > tr:first-child > th')].map(head) : ['item', 'value'], cells, hl: th0 ? look(th0, e) : probe(),
      ha: grid ? [...e.querySelectorAll(':scope > thead > tr:first-child > th')].map(al) : null,
      status: [...new Set(cells.flat().map(c => c.s).filter(k => k && k !== 'ack'))], tests: !!e.closest('.tests'), att: !!e.closest('.attention') };
  });
})()`;
// PAGELOOK (E2 step 2, a, b1 and the charts): read on the page's own terms - every visible tile's label, value and pill as the page
// draws them, and the words of every cell, header label, tile line and chip line the page draws on more than one line
// (its content's height over its line height; not the box's: a td is as tall as its row)
const PAGELOOK = `(() => {
  const main = document.getElementById('main') || document.querySelector('main');
  const flat = s => (s || '').replace(/\\s+/g, ' ').trim();
  const vis = e => e.checkVisibility ? e.checkVisibility({ contentVisibilityAuto: true, opacityProperty: true, visibilityProperty: true }) : e.getClientRects().length > 0;
  const tiles = [...main.querySelectorAll('.tile')].filter(vis).map(t => ({ l: flat(t.querySelector('.tile-l')?.textContent), v: flat(t.querySelector('.tile-v')?.textContent), p: flat(t.querySelector(':scope > .pill, :scope > .badge')?.textContent) }));
  const wraps = e => {
    const r = document.createRange(); r.selectNodeContents(e); const b = r.getBoundingClientRect();
    const cs = getComputedStyle(e); const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2;
    return b.height > lh * 1.5;
  };
  const wrapped = [...main.querySelectorAll('td, th, .th-label, .tile > *, .chip > *')].filter(vis).filter(e => flat(e.textContent) && wraps(e)).map(e => flat(e.textContent));
  // the charts: each one's title, its plot's CSS width, its legend's series (shown or off) and its own state words
  const charts = [...main.querySelectorAll('.chart')].filter(vis).map(b => {
    const h = b.querySelector('h3, h4'), sv = b.querySelector('.uplot') ? null : b.querySelector('svg[role=img]'), cv = b.querySelector('.uplot canvas') ?? sv;
    const hc = h ? h.cloneNode(true) : null; if (hc) hc.querySelectorAll('button, select, .chart-note, .chart-reset, .whatis, .filter-btn').forEach(x => x.remove());
    // tbl: the page shows the chart's numbers as a table of its own (that table's sheet); nums: the rows of the numbers its
    // menu's Export Excel writes (chart.ts pgvNumbers), null for a chart that has none
    const tbl = (() => { for (let a = b; a && a !== main; a = a.parentElement) { const nx = a.nextElementSibling; if (nx && nx.tagName === 'DETAILS' && /numbers as a table/.test(nx.querySelector('summary')?.textContent ?? '')) return true; } return false; })();
    let nums = null; try { nums = typeof b.pgvNumbers === 'function' ? (b.pgvNumbers().rows || []).length : null; } catch { nums = null; }
    // first: the first row with a figure, each figure as the chart's own axis formatter draws it (chart.ts pgvNumbers fmts)
    let first = null; try { if (typeof b.pgvNumbers === 'function') { const n = b.pgvNumbers(); const i = (n.rows || []).findIndex(r => r.some((v, j) => j > 0 && typeof v === 'number'));
      if (i >= 0) first = { i, texts: n.rows[i].map((v, j) => typeof v === 'number' && n.fmts && n.fmts[j] ? n.fmts[j](v) : null) }; } } catch { first = null; }
    return { title: flat(hc ? hc.textContent : ''), tbl, nums, first, w: cv ? cv.getBoundingClientRect().width : null, h: cv ? cv.getBoundingClientRect().height : null,
             series: sv ? [...b.querySelectorAll('.swatch')].map(s => ({ label: flat(s.nextSibling?.textContent), on: true }))
               : [...b.querySelectorAll('.u-legend .u-series')].slice(1).map(s => ({ label: flat(s.querySelector('.u-label')?.textContent ?? s.textContent), on: !s.classList.contains('u-off') })),
             svg: !!sv, table: !!sv && (() => { for (let a = b; a && a !== main; a = a.parentElement) { const nx = a.nextElementSibling; if (nx && nx.tagName === 'DETAILS' && /numbers as a table/.test(nx.querySelector('summary')?.textContent ?? '')) return true; } return false; })(), fills: sv ? [...new Set([...sv.querySelectorAll('rect[fill], path[fill], circle[stroke]')].filter(x => { const r = x.getBoundingClientRect(); return r.width >= 1 && r.height >= 1; }).map(x => (x.getAttribute('fill') || x.getAttribute('stroke') || '').toLowerCase()).filter(f => /^#[0-9a-f]{6}$/.test(f)))] : [],
             legend: !!sv && !!b.querySelector('table.legend, .swatch'),
             swatches: sv ? [...b.querySelectorAll('.swatch')].filter(vis).map(s => ({ label: flat(s.nextSibling?.textContent), colour: getComputedStyle(s).backgroundColor })) : [],
             state: flat(b.querySelector('.chart-state')?.textContent) };
  });
  // (F1) the fleet Summary's 'Needs attention' lines: each one's instance name (its link), its reasons, its badge
  const attention = [...main.querySelectorAll('.attention-row')].filter(vis).map(r => ({ name: flat(r.querySelector('a')?.textContent),
    text: flat([...r.children].find(c => c.tagName === 'SPAN' && !c.matches('.dot, .badge'))?.textContent), badge: flat(r.querySelector('.badge')?.textContent) }));
  // the lines the strip holds in all: its 'Show all N' button's N, else the lines drawn
  const allBtn = [...main.querySelectorAll('.attention button')].find(b => /^Show all \\d/.test(flat(b.textContent)));
  const attentionTotal = allBtn ? Number(flat(allBtn.textContent).replace(/\\D/g, '')) : attention.length;
  // the rows of tiles (a .tiles holding a tile on the screen): each one a section of its own
  const tileRows = [...main.querySelectorAll('.tiles')].filter(vis).filter(t => [...t.querySelectorAll(':scope > .tile')].some(vis)).length;
  const css = getComputedStyle(document.documentElement);
  const palette = [1, 2, 3, 4, 5, 6, 7, 8].map(i => css.getPropertyValue('--s' + i).trim());
  return { tiles, tileRows, attention, attentionTotal, wrapped: [...new Set(wrapped)], charts, palette, card: css.getPropertyValue('--card').trim(), theme: document.documentElement.getAttribute('data-theme') };
})()`;
// SECTIONS (E2-1): the page's visible sections in page order, read on the page's own terms (not by export.ts's walk):
// every block of #main the eye sees - a heading, a grid (an empty grid's header-only table too), a property card, a
// chart (a chart box, a canvas, an SVG), tiles, chips, a disclosure's summary line, the attention strip, the health
// calendar, any other table, a list, a note - and, so that no content goes unread, any other element with text of its
// own outside those ('other'); controls (buttons, inputs, the window's choice, the tabs) are not sections. A block the
// eye does not see is left out: display none, visibility hidden, opacity 0, a closed disclosure's content (no box), a
// visually-hidden note (a clipped pixel). The export's own walk (export.ts) is graded against this list in E3.
const SECTIONS = `(() => {
  const main = document.getElementById('main');
  const KINDS = [['heading', 'h1, h2, h3, h4, h5, h6'], ['grid', 'table.grid, table.grid-empty'], ['props', 'table.props'],
    ['chart', '.chart, .u-wrap, canvas, svg, figure, img'], ['tiles', '.tiles, .tile-wall, .tile'], ['chips', '.chips, .chip, .badge, .pill, .dot'],
    ['attention', '.attention'], ['calendar', '.healthcal'], ['disclosure', 'summary'], ['table', 'table'], ['list', 'ul, ol, dl'],
    ['note', 'p, .meta, .note, .empty, .error']];
  const CONTROL = 'button, input, select, textarea, label, nav, form, [role=tablist], [role=toolbar], .seg, .subtabs, .filter-btn, .whatis, .chart-menu';
  const ANY = KINDS.map(k => k[1]).join(', ');
  const flat = t => (t || '').split(/\\s+/).filter(Boolean).join(' ');
  const out = []; let hidden = 0;
  const push = (kind, e, text) => {
    const r = e.getBoundingClientRect();
    const s = { kind, tag: e.tagName.toLowerCase(), cls: (e.getAttribute('class') || '').trim(), text: flat(text ?? e.textContent).slice(0, 160),
      x: Math.round(r.x), y: Math.round(r.y + scrollY), w: Math.round(r.width), h: Math.round(r.height) };
    if (kind === 'grid') {
      s.cols = [...e.querySelectorAll(':scope > thead > tr:first-child > th')].map(h => flat(h.textContent));
      s.rows = [...e.querySelectorAll(':scope > tbody > tr')].filter(tr => tr.getBoundingClientRect().height > 1).length;
    }
    out.push(s);
  };
  // seen: the browser's own answer (checkVisibility: false under display none, visibility hidden, opacity 0 and a
  // content-visibility that skips the content - a closed disclosure's, which keeps display 'table' and a box from a forced
  // layout), a closed disclosure's content but its summary, and a box over a pixel (a visually-hidden note is one)
  const visit = e => {
    const cs = getComputedStyle(e), r = e.getBoundingClientRect();
    if (cs.display === 'none') { hidden++; return; }
    if (cs.display !== 'contents') {
      const shut = e.closest('details:not([open])');
      if (shut && shut !== e && !shut.querySelector(':scope > summary')?.contains(e)) { hidden++; return; }
      if (e.checkVisibility && !e.checkVisibility({ opacityProperty: true, visibilityProperty: true, contentVisibilityAuto: true })) { hidden++; return; }
      if (cs.visibility !== 'visible' || Number(cs.opacity) === 0) { hidden++; return; }
      if ((r.width <= 1 && r.height <= 1) || (r.width === 0 && r.height === 0)) { hidden++; return; }
    }
    const k = KINDS.find(([, sel]) => e.matches(sel));
    if (k) { push(k[0], e); return; }
    if (e.matches(CONTROL)) return;
    const own = flat([...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join(' '));
    if (own && !e.querySelector(ANY)) { push('other', e); return; }
    if (own) push('other', e, own);
    for (const c of e.children) visit(c);
  };
  for (const c of main.children) visit(c);
  return { sections: out, hidden };
})()`;
const page = async (hash, sortBy, filterNone) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(300);
  if (!await settled()) throw new Error('page did not render: ' + hash);
  let order = null, before = null;
  if (filterNone) {
    // the page's last grid filtered to nothing: a grid without rows keeps the plain sheet filter, no Excel table
    await ev(`(() => { const t = [...document.querySelectorAll('main table.grid')].pop(); t.querySelector('thead .filter-btn').click(); const i = t.querySelector('thead tr.filters input'); i.value = 'zzzz-no-such-row'; i.dispatchEvent(new Event('input', { bubbles: true })); })()`);
    await sleep(600);
    // and two columns of the page's first grid given a class as a page's own rule gives one (ui.ts adds a Col's cls to
    // the cell the same way): no tab of this proof's visits has such a rule in the demo, the export must read the class
    const drawn = await ev(`(() => { const t = document.querySelector('main table.grid'); if (Number(t.dataset.rows ?? 0) > 200) return false;   // past its page the export builds the rows off the screen
      // every row of the two columns classed, as a page's rule classes its whole column (X18: a status column has a
      // status on every cell): the first row crit / warn, the others ok
      const trs = [...t.querySelectorAll(':scope > tbody > tr')]; trs[0].children[1].classList.add('crit'); trs[0].children[2].classList.add('warn');
      trs.slice(1).forEach(tr => { tr.children[1].classList.add('ok'); tr.children[2].classList.add('ok'); }); return true; })()`);
    if (!drawn) throw new Error('the first grid of the Table Size tab has over 200 rows: the class check needs a grid drawn whole');
  }
  if (sortBy) {
    // sort the page's last grid by a column (one click: ascending), so the export must follow the screen's order; the
    // order before the click is kept too: the check needs the click to have changed it
    const col = `(() => { const t = [...document.querySelectorAll('main table.grid')].pop(); const hs = [...t.querySelectorAll('thead th')];
      const j = hs.findIndex(h => h.textContent === ${JSON.stringify(sortBy[1])});
      return [...t.querySelectorAll('tbody tr')].map(tr => tr.children[j].textContent.trim()); })()`;
    before = await ev(col);
    await ev(`[...[...document.querySelectorAll('main table.grid')].pop().querySelectorAll('thead th')].find(h => h.textContent === ${JSON.stringify(sortBy[0])}).click()`);
    await sleep(200);
    order = await ev(col);
  }
  const grids = await ev(SCREEN);
  const sections = await ev(SECTIONS);
  const pagelook = await ev(PAGELOOK);
  return { hash, grids, order, before, sections, pagelook, xlsx: await press('Export .xlsx', ['.xlsx']), csv: await press('Export CSV', ['.csv', '.csv.zip']) };
};
// the grid tools on the fleet Backups grid, through the grid's own menu (ui.ts adds the tools' lines when it sends
// 'pgvigil:gridmenu'); what each does is read back from the page for the checker
const tools = async () => {
  // another window than the Backups export above: the workbook exported here has another name
  const open = async () => { await cmd('Page.navigate', { url: U + '#/backups?w=24h' }); await sleep(300); if (!await settled()) throw new Error('the Backups page did not render (tools)'); };
  await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(300); await settled();
  await open();
  const T = `document.querySelector('main table.grid')`;
  const HS = `[...${T}.querySelectorAll(':scope > thead > tr:first-child > th')].map(h => { const c = h.cloneNode(true); c.querySelectorAll('.filter-btn').forEach(b => b.remove()); return c.textContent.trim(); })`;
  // the menu on the first row's cell of a column (a contextmenu event, as a right-click or the menu key sends)
  const menu = col => ev(`(() => { const j = ${HS}.indexOf(${JSON.stringify(col)}); const td = ${T}.querySelector(':scope > tbody > tr').children[j];
    td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 320, clientY: 320 })); return [...document.querySelectorAll('.menu button')].map(b => b.textContent); })()`);
  const choose = async (col, text) => {
    const items = await menu(col);
    const hit = await ev(`(() => { const b = [...document.querySelectorAll('.menu button')].find(x => x.textContent === ${JSON.stringify(text)}); if (!b) return false; b.click(); return true; })()`);
    if (!hit) throw new Error(`the menu on '${col}' has no '${text}': ${JSON.stringify(items)}`);
    await sleep(250);
  };
  const first = await menu('platform');
  const out = { wired: first.some(x => x.startsWith('Copy the rows as HTML')), menu: first };
  await ev(`document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
  if (!out.wired) return out;
  out.head = await ev(HS); out.rows = await ev(`Number(${T}.dataset.rows)`);
  out.screen = (await ev(SCREEN)).find(g => g && g.cells && !g.empty);   // the first grid with a table, never an empty grid's note
  // the clipboard is kept on the page: what a copy writes is what the checker reads
  await ev(`(() => { window.__gt = {}; const c = navigator.clipboard;
    c.write = async items => { for (const it of items) for (const ty of it.types) window.__gt[ty] = await (await it.getType(ty)).text(); };
    c.writeText = async t => { window.__gt.text = t; }; })()`);
  await choose('platform', 'Copy the rows as HTML with the colours'); await sleep(300);
  out.html = await ev(`window.__gt['text/html'] ?? null`); out.plain = await ev(`window.__gt['text/plain'] ?? null`);
  await choose('platform', 'Copy the rows as Markdown'); await sleep(300);
  out.markdown = await ev(`window.__gt.text ?? null`);
  // Ctrl+click on the first two 'failed' counts, then a plain click
  out.sel = await ev(`(() => { const j = ${HS}.indexOf('failed'); const tds = [...${T}.querySelectorAll(':scope > tbody > tr')].slice(0, 2).map(tr => tr.children[j]);
    for (const td of tds) td.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ctrlKey: true }));
    return { cells: tds.map(td => td.textContent.trim()), picked: ${T}.querySelectorAll('td.gt-sel').length, line: document.querySelector('main .gt-stats')?.textContent ?? '' }; })()`);
  out.selCleared = await ev(`(() => { const j = ${HS}.indexOf('platform'); ${T}.querySelector(':scope > tbody > tr').children[j].dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true }));
    return { picked: ${T}.querySelectorAll('td.gt-sel').length, line: document.querySelector('main .gt-stats')?.textContent ?? '' }; })()`);
  await choose('platform', 'Group by platform');
  out.group = await ev(`(() => { const g = document.querySelector('main .gt-groups'); if (!g) return null;
    return { label: g.getAttribute('aria-label'), head: [...g.querySelectorAll('thead th')].map(h => h.textContent), rows: [...g.querySelectorAll('tbody tr')].map(tr => [...tr.children].map(c => c.textContent)),
      platforms: [...new Set([...${T}.querySelectorAll(':scope > tbody > tr')].map(tr => tr.children[${HS}.indexOf('platform')].textContent.trim()))].length }; })()`);
  await choose('platform', 'Ungroup');
  out.ungrouped = await ev(`!document.querySelector('main .gt-groups')`);
  await choose('failed', 'Data bars on failed');
  const BARS = `(() => { const j = ${HS}.indexOf('failed'); return [...${T}.querySelectorAll(':scope > tbody > tr')].map(tr => { const td = tr.children[j]; return { t: td.textContent.trim(), bar: td.classList.contains('gt-bar'), share: td.style.getPropertyValue('--gt-share'), badge: !!td.querySelector('.badge') }; }); })()`;
  out.bars = await ev(BARS);
  await choose('platform', 'Freeze the columns up to platform');
  const FROZEN = `(() => { const t = ${T}; const tr = t.querySelector(':scope > tbody > tr'); return { on: t.hasAttribute('data-gt-frozen'), classes: [...t.classList].filter(c => /^gt-f/.test(c)).sort(), sticky: [0, 1, 2].map(j => getComputedStyle(tr.children[j]).position) }; })()`;
  out.frozen = await ev(FROZEN);
  await choose('platform', 'Hide column platform');
  const HIDDEN = `(() => { const t = ${T}; const hs = [...t.querySelectorAll(':scope > thead > tr:first-child > th')]; const j = ${HS}.indexOf('platform');
    return { marked: hs.filter(h => h.hasAttribute('data-gt-hidden')).length, th: getComputedStyle(hs[j]).display, td: getComputedStyle(t.querySelector(':scope > tbody > tr').children[j]).display,
      keys: Object.keys(localStorage).filter(k => k.startsWith('pgvigil.grid.')) }; })()`;
  out.hidden = await ev(HIDDEN);
  // a reload: the choice comes back from localStorage on the freshly drawn grid
  await cmd('Page.reload'); await sleep(500); if (!await settled()) throw new Error('the Backups page did not render after the reload'); await sleep(400);
  out.after = { hidden: await ev(HIDDEN), frozen: await ev(FROZEN), bars: await ev(BARS) };
  out.xlsx = await press('Export .xlsx', ['.xlsx']);
  // the chooser: every column listed; 'Reset this grid' brings all back and forgets the choice
  await choose('archiver', 'Columns...');
  out.chooser = await ev(`(() => { const p = document.querySelector('main .gt-panel'); if (!p) return null; return { cols: p.querySelectorAll('.gt-col').length, unticked: [...p.querySelectorAll('.gt-col > label:first-child input')].filter(i => !i.checked).length, label: p.getAttribute('aria-label') }; })()`);
  await ev(`[...document.querySelectorAll('main .gt-panel button')].find(b => b.textContent === 'Reset this grid').click()`); await sleep(300);
  out.reset = { hidden: await ev(HIDDEN), frozen: await ev(FROZEN), bars: (await ev(BARS)).filter(b => b.bar).length };
  await ev(`[...document.querySelectorAll('main .gt-panel button')].find(b => b.textContent === 'Close').click()`);
  out.closed = await ev(`!document.querySelector('main .gt-panel')`);
  await ev(`Object.keys(localStorage).filter(k => k.startsWith('pgvigil.grid.')).forEach(k => localStorage.removeItem(k))`);
  return out;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const out = { instance: one.name, lang: await ev('navigator.language'), sample: await ev('(1234567).toLocaleString()') };
out.summary = await page('#/summary');
// the fleet's Backups, Jobs and Storage: the pages DBA Dash's own exports were taken from, and the carried colours
out.backups = await page('#/backups');
out.jobs = await page('#/jobs');
out.storage = await page('#/storage');
// the Storage folder's grids at the root (task 176): Drives as its metrics grid with every status, DB Space, Files
await ev(`localStorage.setItem('pgvigil.drivesMetrics', '1'); localStorage.setItem('pgvigil.drivesStatus.folder', 'all'); localStorage.setItem('pgvigil.filesStatus.folder', 'all'); true`);
// the state each page was drawn in (its status filter, the Drives metrics toggle), read after its export
const STATE = `({ selects: [...document.querySelectorAll('main select')].map(s => s.id + '=' + s.value), metrics: [...document.querySelectorAll('main button')].find(b => b.textContent === 'Toggle Metrics')?.getAttribute('aria-pressed') ?? null })`;
out.drives = await page('#/drives'); out.drives.state = await ev(STATE);
out.dbspace = await page('#/dbspace'); out.dbspace.state = await ev(STATE);
out.dbfiles = await page('#/dbfiles'); out.dbfiles.state = await ev(STATE);
await ev(`['pgvigil.drivesMetrics', 'pgvigil.drivesStatus.folder', 'pgvigil.filesStatus.folder'].forEach(k => localStorage.removeItem(k)); true`);
out.tables = await page(`#/tables?i=${one.instance_id}`, ['total', 'table']);
// the Roles tab: grids under h4 headings (the privilege grids)
out.roles = await page(`#/roles?i=${one.instance_id}`);
// the Running queries tab over 7 days: more than 500 samples, so the page says 'the newest 500 of N'
out.activity = await page(`#/activity?i=${one.instance_id}&w=7d`);
// the fleet's Slow queries tab over 24 h: the Per day table is hand-built (no page model), the durations are 'x ms / s / min'
out.slow = await page('#/slowqueries?w=24h');
// the fleet's Performance summary: a data bar's fill colours its cell, a CPU histogram (a picture whose top bucket is
// painted critical even when empty) colours none
out.perf = await page('#/perfsummary');
// the rows whose CPU histogram cell holds the picture (a row with no CPU sample shows '-'): the no-fill check needs one
out.perf.pictures = await ev(`(() => { const t = [...document.querySelectorAll('main table.grid')].find(x => [...x.querySelectorAll(':scope > thead > tr:first-child > th')].some(h => h.textContent.trim().startsWith('CPU histogram')));
  if (!t) return 0; const j = [...t.querySelectorAll(':scope > thead > tr:first-child > th')].findIndex(h => h.textContent.trim().startsWith('CPU histogram'));
  return [...t.querySelectorAll(':scope > tbody > tr')].filter(tr => tr.children[j]?.querySelector('[role=img]')).length; })()`);
// a database's drill page (the Database info tab's first database link): its statements grid rounds to 0.1 ms, with
// sub-millisecond, fractional and 1,000+ ms values in one column
await cmd('Page.navigate', { url: U + `#/dbinfo?i=${one.instance_id}` }); await sleep(300);
if (!await settled()) throw new Error('the Database info tab did not render');
const dbHref = await ev(`(document.querySelector('main a[href*="#/db?"]') || {}).getAttribute?.('href') ?? null`);
if (!dbHref) throw new Error('no database link on the Database info tab');
out.db = await page(dbHref);
// the Table Size tab again (another window: another file name), its second grid filtered to nothing: a sheet without rows
out.empty = await page(`#/tables?i=${one.instance_id}&w=24h`, null, true);
// (decision (b)) the SQL Server instance's Jobs tab: each job's step grid named by its job (data-sheet); the demo's '-sql01'
// is the instance with jobs (internal/demo mssqlCollections); a tab that shows no grid is said, not pressed
const sq = rows.find(r => r.engine === 'sqlserver' && /-sql01$/.test(r.name)) ?? rows.find(r => r.engine === 'sqlserver');
if (sq) {
  await cmd('Page.navigate', { url: U + `#/mssqljobs?i=${sq.instance_id}&w=24h` }); await sleep(300);
  if (!await settled()) throw new Error('the SQL Server Jobs tab did not render');
  const any = await ev(`!!document.querySelector('main table.grid, main table.props, main p.empty[data-cols]')`);
  out.sqljobs = any ? { ...(await page(`#/mssqljobs?i=${sq.instance_id}&w=24h`)), instance: sq.name } : { none: await ev(`(document.querySelector('main')?.textContent || '').replace(/\\s+/g, ' ').trim().slice(0, 160)`), instance: sq.name };
  // the instance's DB Space grid: its size columns in DBA Dash's unit (GB, one decimal), as the fleet grid's
  out.dbspace_i = { ...(await page(`#/dbspace?i=${sq.instance_id}`)), instance: sq.name };
}
// a PostgreSQL instance's DB Space page: its grid with no data / log columns, used 'not read'
const pq_ = rows.find(r => r.engine === 'postgres' && r.platform === 'onprem') ?? rows.find(r => r.engine === 'postgres');
if (pq_) out.dbspace_p = { ...(await page(`#/dbspace?i=${pq_.instance_id}`)), instance: pq_.name };
out.tools = await tools();
// ---- P03: the new menu items, each clicked and its download read ---------------------------------------------------
const waitDl = async (before, what) => {
  for (const t = Date.now(); Date.now() - t < 15000; await sleep(200)) {
    const now = folder();
    if (Object.keys(now).some(x => x.endsWith('.crdownload'))) continue;
    const f = Object.keys(now).filter(n => n.endsWith('.xlsx') && !(n in before));
    if (f.length) return f[0];
  }
  throw new Error(`no .xlsx downloaded after ${what} on ${await ev('location.hash')}`);
};
const go = async hash => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); if (!await settled()) throw new Error('page did not render: ' + hash); await sleep(500); };
const items = () => ev(`[...document.querySelectorAll('.menu button')].map(b => b.textContent)`);
const click = text => ev(`(() => { const b = [...document.querySelectorAll('.menu button')].find(x => x.textContent === ${JSON.stringify(text)}); if (!b) return false; b.click(); return true; })()`);
// the shots of each menu open, in the light and the dark theme (the first language's run only)
const SHOTS = process.env.PGVIGIL_EXPORT_SHOTS && out.lang.startsWith('en') ? process.env.PGVIGIL_EXPORT_SHOTS : '';
const shot = async name => {
  if (!SHOTS) return;
  for (const th of ['light', 'dark']) {
    await ev(`document.documentElement.setAttribute('data-theme', '${th}')`); await sleep(250);
    const d = await cmd('Page.captureScreenshot', { format: 'png' });
    if (d.result?.data) fs.writeFileSync(`${SHOTS}/${name}-${th}.png`, Buffer.from(d.result.data, 'base64'));
  }
  await ev(`document.documentElement.removeAttribute('data-theme')`);
};
// a grid's menu: Export Excel right after the copies; that grid's workbook (the fleet Backups grid)
await go('#/backups?w=2h');
const gm = { hash: '#/backups?w=2h' };
gm.items = await ev(`(() => { const td = document.querySelector('main table.grid > tbody > tr').children[1];
  td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 360, clientY: 300 })); return [...document.querySelectorAll('.menu button')].map(b => b.textContent); })()`);
await shot('grid-menu');
gm.screen = (await ev(SCREEN)).find(g => g && g.cells && !g.empty);
let before = folder();
if (!await click('Export Excel')) throw new Error("the grid's menu has no Export Excel: " + JSON.stringify(gm.items));
gm.xlsx = await waitDl(before, "the grid menu's Export Excel");
await sleep(200);
gm.said = await ev(`document.querySelector('main .grid-box .filter-count')?.textContent ?? ''`);
out.gridmenu = gm;
// the fleet Summary's Export to Excel drop-down: Export Summary (the instance grid), Export Test Summary (the tests grid)
await go('#/summary?w=2h');
const sm = { button: await ev(`[...document.querySelectorAll('#bar .export button')].map(b => b.textContent)`) };
const dd = `[...document.querySelectorAll('#bar .export button')].find(b => b.textContent.startsWith('Export to Excel'))`;
if (!await ev(`!!${dd}`)) throw new Error('no Export to Excel drop-down on the Summary bar: ' + JSON.stringify(sm.button));
sm.screen = (await ev(SCREEN)).filter(g => g && g.cells && !g.att);
await ev(`${dd}.click()`); await sleep(250);
sm.items = await items(); sm.popup = await ev(`${dd}.getAttribute('aria-haspopup')`);
await shot('summary-export');
before = folder(); if (!await click('Export Summary')) throw new Error('no Export Summary: ' + JSON.stringify(sm.items));
sm.summary = await waitDl(before, 'Export Summary');
await ev(`${dd}.click()`); await sleep(250);
before = folder(); if (!await click('Export Test Summary')) throw new Error('no Export Test Summary');
sm.tests = await waitDl(before, 'Export Test Summary');
out.summaryExport = sm;
// a chart's menu: Export Excel on a line chart and on a ring (the root DB Space first: DBA Dash's chart menu rows)
const CHARTS = `[...document.querySelectorAll('main button.chart-menu[aria-haspopup=menu]')].map((b, i) => { const box = b.closest('h3')?.parentElement;
  return { i, title: (b.getAttribute('aria-label') || '').replace(/^Chart menu: /, ''), line: !!box?.querySelector('.u-over'), ring: !!box?.querySelector('svg[role=img]') }; })`;
const charts = {};
for (const hash of ['#/dbspace?w=2h', `#/summary?i=${one.instance_id}&w=2h`, `#/dbinfo?i=${one.instance_id}&w=2h`, `#/performance?i=${one.instance_id}&w=2h`]) {
  if (charts.line && charts.ring) break;
  await go(hash); await sleep(700);
  const ms = await ev(CHARTS);
  for (const kind of ['line', 'ring']) {
    const m = charts[kind] ? null : ms.find(x => x[kind]);
    if (!m) continue;
    await ev(`document.querySelectorAll('main button.chart-menu[aria-haspopup=menu]')[${m.i}].click()`); await sleep(250);
    const its = await items();
    await shot('chart-menu-' + kind);
    before = folder();
    if (!await click('Export Excel')) throw new Error(`the ${kind} chart '${m.title}' has no Export Excel in its menu: ${JSON.stringify(its)}`);
    const xlsx = await waitDl(before, `the ${kind} chart's Export Excel`);
    await sleep(300);
    const said = await ev(`document.querySelectorAll('main button.chart-menu[aria-haspopup=menu]')[${m.i}].closest('h3')?.parentElement?.querySelector('.chart-note')?.textContent ?? ''`);
    charts[kind] = { hash, title: m.title, items: its, xlsx, said };
    if (kind === 'line') {
      // the page's own export beside the chart's (its numbers sheet = this workbook), then the same page loaded fresh in
      // the dark theme and exported (E2-16: the file is light; the screen dark again after it)
      charts.line.look = await ev(PAGELOOK);
      charts.line.page = await press('Export .xlsx', ['.xlsx']);
      await ev(`localStorage.setItem('pgvigil.theme', 'dark'); true`);
      // under another window: the file's name holds the window, and the driver refuses a download that replaces one; a
      // preset of router.ts (2h and 3h are none: both fall back to 1h, the same name - t-e3-d2, t-e3-d4)
      const hashD = hash.replace(/w=[^&]*/, 'w=4h');
      await cmd('Page.navigate', { url: 'about:blank' }); await sleep(300); await go(hashD); await sleep(700);
      charts.line.darkTheme = await ev(`document.documentElement.getAttribute('data-theme')`);
      charts.line.dark = await press('Export .xlsx', ['.xlsx']);
      charts.line.after = await ev(`document.documentElement.getAttribute('data-theme')`);
      await ev(`localStorage.setItem('pgvigil.theme', 'light'); true`);
      await cmd('Page.navigate', { url: 'about:blank' }); await sleep(300); await go(hash); await sleep(500);
    }
  }
}
out.charts = charts;
// a chart the page draws in HTML (chart.ts volumeBars: the Volumes bars of an instance's Storage page, a table): the
// bars' rows as the page draws them, then the page's export (its rows on the page sheet after the chart's line)
{
  // (the review's fold) graded as every page here too: its days, its rates, its Volumes
  const hashV = `#/storage?i=${one.instance_id}&w=24h`;
  await go(hashV); await sleep(700);
  const bars = await ev(`[...document.querySelectorAll('main .chart.bars tbody tr')].map(tr => [...tr.children].map(td => (td.textContent || '').replace(/\\s+/g, ' ').trim()))`);
  out.volumes = { ...(await page(hashV)), bars };
}
// an empty grid's sheet without the column the grid tools hide: a grid with rows over 24 h that is an empty grid's
// note (no table to mark) in a window of 2001, under the same heading with the same columns, found on the first
// candidate page that has one; a column hidden with its menu over 24 h, then the 2001 page exported
const OLD = 'from=2001-01-01T00:00:00.000Z&to=2001-01-01T01:00:00.000Z';
// each grid or empty grid's note of the page with the heading above it as the grid tools name it (gridtools.ts headingOf)
const GRIDS = `(() => { let h = ''; const out = []; for (const e of document.querySelectorAll('main h2, main h3, main h4, main table.grid, main p.empty[data-cols]')) {
  if (e.tagName[0] === 'H') { const c = e.cloneNode(true); c.querySelectorAll('.whatis, .filter-btn').forEach(b => b.remove()); h = c.textContent.replace(/\\s+/g, ' ').trim().replace(/\\s*\\(.*\\)$/, ''); continue; }
  out.push({ h, t: e.tagName, cols: e.tagName === 'P' ? JSON.parse(e.dataset.cols || '[]') : [...e.querySelectorAll(':scope > thead > tr:first-child > th')].map(th => { const c = th.cloneNode(true); c.querySelectorAll('.filter-btn').forEach(b => b.remove()); return c.textContent.replace(/\\s+/g, ' ').trim(); }) }); }
  return out; })()`;
const eh = { tried: [] };
const sep = h => h.includes('?') ? '&' : '?';
for (const base of ['#/slowqueries', `#/slowqueries?i=${one.instance_id}`, `#/statements?i=${one.instance_id}`, '#/jobs', `#/logs?i=${one.instance_id}`, `#/waits?i=${one.instance_id}`, `#/pg_deadlocks?i=${one.instance_id}`]) {
  await go(base + sep(base) + 'w=24h'); const A = await ev(GRIDS);
  await go(base + sep(base) + OLD); const B = await ev(GRIDS);
  eh.tried.push(`${base}: ${A.filter(x => x.t === 'TABLE').length} grids with rows over 24 h, ${B.filter(x => x.t === 'P').length} empty in 2001`);
  const hit = B.find(x => x.t === 'P' && x.cols.length >= 2 && A.some(y => y.t === 'TABLE' && y.h === x.h && JSON.stringify(y.cols) === JSON.stringify(x.cols)));
  if (hit) { eh.base = base; eh.heading = hit.h; eh.cols = hit.cols; eh.k = A.filter(y => y.t === 'TABLE').findIndex(y => y.h === hit.h && JSON.stringify(y.cols) === JSON.stringify(hit.cols)); break; }
}
if (!eh.base) throw new Error('no candidate page has a grid with rows over 24 h that is empty in 2001: ' + JSON.stringify(eh.tried));
eh.hidden = eh.cols[1];
await go(eh.base + sep(eh.base) + 'w=24h');
await ev(`document.querySelectorAll('main table.grid')[${eh.k}].querySelector(':scope > tbody > tr').children[1].dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 320, clientY: 320 }))`); await sleep(200);
if (!await click('Hide column ' + eh.hidden)) throw new Error(`no 'Hide column ${eh.hidden}' on the '${eh.heading}' grid's menu: ` + JSON.stringify(await items()));
await sleep(300);
eh.keys = await ev(`Object.keys(localStorage).filter(k => k.startsWith('pgvigil.grid.'))`);
await go(eh.base + sep(eh.base) + OLD);
eh.note = (await ev(GRIDS)).find(x => x.t === 'P' && x.h === eh.heading) ?? null;
eh.xlsx = await press('Export .xlsx', ['.xlsx']);
await ev(`Object.keys(localStorage).filter(k => k.startsWith('pgvigil.grid.')).forEach(k => localStorage.removeItem(k))`);
out.emptyHidden = eh;
// the colour reader (web/src/export_colours.ts as a script: window.__pgvColours) on the fleet Summary's own elements,
// then on two planted cells (an rgba fill, a color-mix text), then the same plain cell and header under the dark theme
await go('#/summary?w=2h');
await ev(fs.readFileSync(colourFile, 'utf8') + '; true');
out.colourReader = await ev(`(() => {
  const P = window.__pgvColours.paintOf, main = document.getElementById('main'), root = document.documentElement;
  const g = [...main.querySelectorAll('table.grid')];
  const th = g[0]?.querySelector(':scope > thead > tr > th');
  const st = k => main.querySelector('table.grid td.status.' + k + (k === 'none' ? ':not(.ack)' : ''));
  const plain = [...main.querySelectorAll('table.grid td')].find(td => !td.classList.contains('status') && !td.querySelector('a, .badge, .dot, .bar-fill') && (td.textContent || '').trim());
  const link = main.querySelector('table.grid td:not(.status) a[href]');
  const r = {};
  const put = (k, e, base) => { r[k] = e ? P(e, base) : null; };
  put('th', th); put('ok', st('ok')); put('crit', st('crit')); put('none', st('none')); put('plain', plain); put('link', link, link?.closest('table'));
  const box = document.createElement('div'); box.className = 'panel';
  box.innerHTML = '<table class="grid"><tbody><tr><td style="background: rgba(34, 89, 200, .14)">x</td><td style="color: color-mix(in srgb, #1b2230 50%, transparent)">y</td></tr></tbody></table>';
  main.append(box);
  const tds = box.querySelectorAll('td'); put('tint', tds[0]); put('mix', tds[1]); r.mixRaw = getComputedStyle(tds[1]).color;
  box.remove();
  const was = root.getAttribute('data-theme');
  root.setAttribute('data-theme', 'dark'); put('darkPlain', plain); put('darkTh', th);
  if (was === null) root.removeAttribute('data-theme'); else root.setAttribute('data-theme', was);
  r.themeBack = root.getAttribute('data-theme') === was;
  return r;
})()`);
// SECTIONS' self-test on an instance's Summary: sections planted at the end of the page, read, then removed, in one
// evaluation (the live page redraws every 30 s)
await go(`#/summary?i=${one.instance_id}&w=2h`);
out.sectionsSelfTest = await ev(`(() => {
  const main = document.getElementById('main');
  const plant = html => { const d = document.createElement('div'); d.innerHTML = html; const e = d.firstElementChild; e.dataset.plant = '1'; main.append(e); };
  plant('<section><h3>Planted heading</h3><div class="tiles"><div class="tile ok"><div class="tile-v">7</div> <div class="tile-l">planted tile</div></div></div></section>');
  plant('<details><summary>planted closed disclosure</summary><table class="grid"><tbody><tr><td>planted hidden cell</td></tr></tbody></table></details>');
  plant('<div class="tiles" style="display: none"><div class="tile">planted display none</div></div>');
  plant('<p class="visually-hidden">planted visually hidden</p>');
  plant('<details open><summary>planted open disclosure</summary><table class="grid"><thead><tr><th>c</th></tr></thead><tbody><tr><td>planted open cell</td></tr></tbody></table></details>');
  plant('<div style="visibility: hidden"><p class="meta">planted invisible note</p></div>');
  plant('<div><span class="no-such-kind">planted unknown content</span></div>');
  const r = ${SECTIONS};
  main.querySelectorAll('[data-plant]').forEach(e => e.remove());
  return { ...r, removed: main.querySelectorAll('[data-plant]').length === 0 };
})()`);
// readRows (the reader for the rows a grid does not draw) on the fleet Findings' grid, its longest: 'Show all' draws
// every row, each drawn row's cells read where they are; then detached copies of the rows (as ui.ts's allRows() builds
// the rows past the page: rowEl's classes and content, which draw() also uses) read through readRows' shell, and the
// same copies read bare (the self-test: a detached element has no computed style). One evaluation (no redraw between)
await go('#/findings?w=2h');
await ev(fs.readFileSync(colourFile, 'utf8') + '; true');
out.offPage = await ev(`(() => {
  const C = window.__pgvColours, main = document.getElementById('main');
  const t = [...main.querySelectorAll('table.grid')].sort((a, b) => Number(b.dataset.rows || 0) - Number(a.dataset.rows || 0))[0];
  if (!t) return { none: true };
  const body = () => [...t.querySelectorAll(':scope > tbody > tr')];
  const total = Number(t.dataset.rows || 0), before = body().length;
  const all = [...(t.closest('.grid-box')?.querySelectorAll('.grid-more button') ?? [])].find(b => b.textContent.startsWith('Show all'));
  if (all) all.click();
  const drawn = body();
  const MARK = '.badge, .pill, .dot, a[href]';
  const pc = p => (p.fill ?? '-') + '/' + p.text;
  const cellsOf = tr => [...tr.children].map(td => { const m = td.querySelector(MARK); return pc(C.paintOf(td)) + (m ? '|' + pc(C.paintOf(m, tr.closest('table'))) : ''); });
  const onScreen = drawn.map(cellsOf);
  const wrap = t.parentElement, h0 = document.scrollingElement.scrollHeight, kids0 = wrap.children.length;
  const copies = drawn.map(tr => tr.cloneNode(true));
  let shell = null;
  const viaShell = C.readRows(t, copies, tr => {
    const s = tr.closest('table');
    if (!shell) { const cs = getComputedStyle(s); shell = { same: s === t, cls: s.className, visibility: cs.visibility, position: cs.position, next: t.nextElementSibling === s, hidden: s.getAttribute('aria-hidden'), h: document.scrollingElement.scrollHeight }; }
    return cellsOf(tr);
  });
  const bare = copies.map(cellsOf);
  return { total, before, after: drawn.length, cols: [...t.querySelectorAll(':scope > thead > tr:first-child > th')].map(h => h.textContent.trim()), onScreen, viaShell, bare, shell,
    h0, h1: document.scrollingElement.scrollHeight, kids0, kids1: wrap.children.length, drawnAfter: body().length, copiesLoose: copies.every(c => c.parentElement === null),
    left: main.querySelectorAll('table[aria-hidden="true"].grid').length };
})()`);
// the route walk (E2-1's inventory over the whole app; the first language only): every route of the app's route
// tables opened - rootTabs at the fleet, instanceTabs on the demo's PostgreSQL instance, mssqlInstanceTabs on its SQL
// Server instance, each drill page by the first link to it on the pages walked - and read by SECTIONS. A page renders
// when #main has content and no Loading note is left (not the bar's export: a page without it is said, not waited for)
if (out.lang.startsWith('en')) {
  const R = JSON.parse(fs.readFileSync(routesFile, 'utf8'));
  const pgI = rows.find(r => (r.engine ?? 'postgres') === 'postgres' && r.platform === 'onprem') ?? rows.find(r => (r.engine ?? 'postgres') === 'postgres');
  const sqI = rows.find(r => r.engine === 'sqlserver');
  const walk = { tables: Object.fromEntries(Object.entries(R).map(([k, v]) => [k, v.length])), pg: pgI?.name ?? null, sql: sqI?.name ?? null, pages: [], drill: {} };
  const shown = async () => {
    for (const t = Date.now(); Date.now() - t < 15000; await sleep(150)) {
      if (await ev(`(() => { const m = document.querySelector('main'); return !!m && m.children.length > 0 && !m.querySelector('.state.loading') && ![...m.querySelectorAll('p.empty')].some(e => /^Loading/.test(e.textContent)); })()`)) { await sleep(400); return true; }
    }
    return false;
  };
  const visit = async (table, route, hash) => {
    await cmd('Page.navigate', { url: U + hash }); await sleep(300);
    const r = { table, route, hash, rendered: await shown() };
    if (r.rendered) {
      const s = await ev(SECTIONS);
      r.sections = s.sections.map(x => ({ kind: x.kind, text: x.text.slice(0, 80), ...(x.cols ? { cols: x.cols, rows: x.rows } : {}) }));
      r.hidden = s.hidden;
      r.errors = await ev(`[...document.querySelectorAll('main .error')].filter(e => e.getBoundingClientRect().height > 0).map(e => e.textContent.trim().slice(0, 160))`);
      r.exportBar = await ev(`!!document.querySelector('#bar .export')`);
      r.at = await ev('location.hash');
      for (const d of R.drillTabs ?? []) if (!walk.drill[d]) {
        const h = await ev(`(document.querySelector('main a[href*="#/${d}?"]') || {}).getAttribute?.('href') ?? null`);
        if (h) walk.drill[d] = h.slice(h.indexOf('#'));
      }
    }
    walk.pages.push(r);
  };
  for (const t of R.rootTabs ?? []) await visit('rootTabs', t, `#/${t}`);
  if (pgI) for (const t of R.instanceTabs ?? []) await visit('instanceTabs', t, `#/${t}?i=${pgI.instance_id}`);
  if (sqI) for (const t of R.mssqlInstanceTabs ?? []) await visit('mssqlInstanceTabs', t, `#/${t}?i=${sqI.instance_id}`);
  for (const t of R.drillTabs ?? []) {
    if (walk.drill[t]) await visit('drillTabs', t, walk.drill[t]);
    else walk.pages.push({ table: 'drillTabs', route: t, hash: null, rendered: false, why: 'no link to it on the pages walked' });
  }
  out.walk = walk;
}
console.log(JSON.stringify(out));
process.exit(0);
JS
cat > "$WORK/check.py" <<'PY'
import csv, io, json, math, os, re, subprocess, sys, zipfile
d = json.load(open(sys.argv[1])); dl = sys.argv[2]; want = sys.argv[3]
PAGE_DP = {}   # (X13) file -> sheet -> column header -> the most decimals the screen shows in that column
need = {x.strip() for x in os.environ.get('PGVIGIL_EXPORT_NEED', 'tools').split(',') if x.strip()} - {'none'}
if os.environ.get('PGVIGIL_PYLIB'): sys.path.append(os.environ['PGVIGIL_PYLIB'])
try:
    import openpyxl
except Exception:
    openpyxl = None
bad = 0
def check(cond, msg):
    global bad
    print(('ok   ' if cond else 'FAIL ') + msg)
    if not cond: bad += 1
def skipped(part, msg):
    # a part whose tool is missing: said, and a failure only when PGVIGIL_EXPORT_NEED names it
    if part in need: check(False, f"{msg} (PGVIGIL_EXPORT_NEED asks for '{part}')")
    else: print('not checked: ' + msg)
fill = {'ok': 'FF006638', 'warn': 'FFE49325', 'crit': 'FFAB1F26', 'none': 'FFE0E1E9', 'ack': 'FF1B6AA3'}
font = {'ok': 'FFFFFFFF', 'warn': 'FF1D1300', 'crit': 'FFFFFFFF', 'none': 'FF004F83', 'ack': 'FFFFFFFF'}
LINKFILL, LINK = 'FFF1F1F6', 'FF004F83'
def unesc(t): return t.replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"').replace('&amp;', '&')
def colname(i):
    n = ''
    i += 1
    while i > 0: n = chr(65 + (i - 1) % 26) + n; i = (i - 1) // 26
    return n
def colidx(c):
    n = 0
    for ch in c: n = n * 26 + ord(ch) - 64
    return n - 1
def shared(z):
    # the workbook's shared strings, in order (a table's header cells point into them)
    if 'xl/sharedStrings.xml' not in z.namelist(): return []
    return [unesc(t) for t in re.findall(r'<si><t[^>]*>([^<]*)</t></si>', z.read('xl/sharedStrings.xml').decode())]
def cells_of(x, sst=()):
    # every cell the sheet writes: (row, column) -> (style id, its number or None, its text or None)
    out = {}
    for m in re.finditer(r'<c r="([A-Z]+)(\d+)" s="(\d+)"(?: t="(\w+)")?(?:/>|>(.*?)</c>)', x, re.S):
        body = m.group(5) or ''
        v = re.search(r'<v>([^<]*)</v>', body); t = re.search(r'<t[^>]*>([^<]*)</t>', body)
        if m.group(4) == 's': val, text = None, (sst[int(v.group(1))] if v and int(v.group(1)) < len(sst) else None)
        elif m.group(4) == 'b': val, text = None, ('TRUE' if v and v.group(1) == '1' else 'FALSE')   # (P3) as Excel draws it
        else: val, text = (float(v.group(1)) if v else None), (unesc(t.group(1)) if t else None)
        out[(int(m.group(2)), colidx(m.group(1)))] = (int(m.group(3)), val, text)
    return out
# a value column and the columns that may judge it, by the screen's headings (docs/export.md's table; a finding's
# value is headed by what it names)
PAIRS = {'last archived': ('archiver',), 'last start': ('last run',), 'free size': ('free',), 'last full': ('full',), 'full age': ('full',), 'full age (hours)': ('full',),
         'last differential': ('differential',), 'last log': ('log',), 'log age': ('log',), 'log age (minutes)': ('log',), 'last run': ('outcome', 'last outcome'),
         'value': ('severity', 'check'), 'role': ('severity',), 'index': ('severity',), 'database': ('severity',), 'object': ('severity',)}
def audit(key, name, x, cx, g, sst, first=2):
    # every drawn cell against the page (E2-4'): its fill, its text colour and its weight in the file = the look the page's
    # CSS gives it, read by the driver's own code (SCREEN look); a status cell's fill is the status colour (counted)
    cells = cells_of(x, sst); n = dict.fromkeys(['ok', 'warn', 'crit', 'none', 'ack', 'link', 'plain', 'class', 'filled'], 0); wrong = []
    for i, row in enumerate(g['cells']):
        for j, c in enumerate(row):
            sid = cells.get((i + first, j), (0, None, None))[0]
            f, fo, b = (cx[sid]['fill'], cx[sid]['font'], cx[sid]['bold']) if sid < len(cx) else ('?', '?', None)
            at = f"{colname(j)}{i + first}"
            # (changed by X0: a grid sheet's cell is the named pair of the status the screen shows, the link column's pair,
            # or plain - no longer the page's own look)
            want = (fill[c['s']], font[c['s']], False) if c.get('s') in fill else (LINKFILL, LINK, False) if c.get('l') else (None, None, False)
            if (f, fo, bool(b)) != want: wrong.append(f"{at} '{c['t'][:20]}' file {f}/{fo}/{'b' if b else '-'} want {want[0]}/{want[1]}"); continue
            if c['s'] and f == fill.get(c['s']): n[c['s']] += 1
            if c.get('b') and c['s']: n['class'] += 1
            if c['l'] and not c['s']: n['link'] += 1
            if f is None: n['plain'] += 1
            else: n['filled'] += 1
    total = sum(len(r) for r in g['cells'])
    # the read returned the rows the page draws: all of them, or a long grid's first 200
    check(len(g['cells']) == min(g['rows'], 200), f"{key}: sheet '{name}' the screen read returned {len(g['cells'])} rows of the grid's {g['rows']} (the page draws at most 200)")
    check(not wrong, f"{key}: sheet '{name}' every drawn cell its status's named pair, the link pair or plain (X0) - fill, text colour, not bold ({total} cells of {len(g['cells'])} rows; {len(wrong)} wrong {wrong[:3]})")
    print(f"     cells: {key} '{name}': {total} body cells, {n['filled']} filled (status ok {n['ok']}, warn {n['warn']}, crit {n['crit']}, none {n['none']}, ack {n['ack']}), {n['link']} link cells, {n['plain']} unfilled")
    return n, cells
def carried(key, name, g, cells, cx, judge, value, least):
    # a value cell in the colour of its row's judging cell: every row where the judge is coloured and the value not empty
    if judge not in g['head'] or value not in g['head']: return check(False, f"{key}: sheet '{name}' has the columns '{judge}' and '{value}'")
    a, b = g['head'].index(judge), g['head'].index(value); got = {}; miss = []
    for i, row in enumerate(g['cells']):
        s = row[a]['s']
        if not s or row[b]['t'] == '': continue
        if row[b]['s']:
            # coloured on the screen by the page's own rule (the file's fill against the screen is checked per cell above)
            if row[b]['s'] == s: got[s] = got.get(s, 0) + 1
            else: miss.append(f"{colname(b)}{i + 2} on screen {row[b]['s']} for {s}")
            continue
        f = cx[cells.get((i + 2, b), (0, None, None))[0]]['fill']
        if f == fill[s]: got[s] = got.get(s, 0) + 1
        else: miss.append(f"{colname(b)}{i + 2} {f} for {s}")
    check(not miss and sum(got.values()) >= 1 and all(got.get(k, 0) >= 1 for k in least), f"{key}: '{value}' is in the colour of '{judge}' in its row ({got}; at least one of {least or 'any'}; {len(miss)} wrong {miss[:3]})")
def number(t):
    t = re.sub(r'[\s\u202f\u00a0%+]', '', t)
    if ',' in t and '.' not in t: t = t.replace(',', '.')
    try: return float(t.replace(',', ''))
    except ValueError: return None
def dbs_onedec(key, g, cells, cx):
    # (DBA Dash's 'Decimal Places: 1': '12.0', never '12') every GB figure of a DB Space grid shows exactly one decimal on
    # the page (fr-FR '12,0'), its workbook cell a number under '0.0' whose value is the figure shown; a blank or 'not read'
    # cell is skipped. The grid must hold a whole figure (the case the rule is about), or the row proves nothing
    gb = [j for j, h in enumerate(g['head']) if h.endswith('(GB)')]
    seen, whole, bad = 0, 0, []
    for i, row in enumerate(g.get('cells') or []):
        for j in gb:
            t_ = row[j]['t'] if j < len(row) else ''
            if t_ in ('', 'not read'): continue
            sid, v_, _ = cells.get((i + 2, j), (0, None, None))
            code = FMT_CODES.get(cx[sid]['fmt'], cx[sid]['fmt']) if sid < len(cx) else '?'
            n_ = number(t_); seen += 1
            if n_ is not None and n_ == int(n_): whole += 1
            if not re.fullmatch(r'-?[\d\s\u202f\u00a0.,]*\d[.,]\d', t_) or v_ is None or code != '0.0' or n_ is None or abs(n_ - v_) >= 1e-9:
                bad.append(f"{colname(j)}{i + 2} page {t_!r}, workbook {v_} under {code!r}")
    check(len(gb) >= 1 and seen >= 1 and whole >= 1 and not bad, f"{key}: every GB figure shows one decimal on the page and is a number under '0.0' in the workbook, the value shown ({len(gb)} GB columns, {seen} figures, {whole} whole; {len(bad)} off {bad[:3]})")
def sheets_of(z):
    wb = z.read('xl/workbook.xml').decode()
    return [n.replace('&amp;', '&') for n in re.findall(r'<sheet name="([^"]*)"', wb)]
def xfs(z):
    st = z.read('xl/styles.xml').decode()
    fills = re.findall(r'<fill>(.*?)</fill>', re.search(r'<fills[^>]*>(.*?)</fills>', st).group(1))
    cx = re.findall(r'<xf ([^>]*?)\s*/?>(?:(<alignment[^>]*/>)</xf>)?', re.search(r'<cellXfs[^>]*>(.*?)</cellXfs>', st).group(1))
    FMT_CODES.update({int(i): unesc(c) for i, c in re.findall(r'<numFmt numFmtId="(\d+)" formatCode="([^"]*)"/>', st)})
    fonts = re.findall(r'<font>(.*?)</font>', re.search(r'<fonts[^>]*>(.*?)</fonts>', st).group(1))
    out = []
    for a, al in cx:
        g = lambda k: int(re.search(k + r'="(\d+)"', a).group(1))
        f = re.search(r'rgb="(\w+)"', fills[g('fillId')])
        fo = fonts[g('fontId')]; c = re.search(r'rgb="(\w+)"', fo)
        sz = re.search(r'<sz val="([\d.]+)"/>', fo)
        out.append({'fmt': g('numFmtId'), 'fill': f.group(1) if f else None, 'font': c.group(1) if c else None, 'bold': '<b/>' in fo, 'border': g('borderId') != 0, 'wrap': 'wrapText="1"' in al, 'valign': (re.search(r'vertical="(\w+)"', al) or [None, 'bottom'])[1], 'sz': float(sz.group(1)) if sz else 11.0, 'halign': (re.search(r'horizontal="(\w+)"', al) or [None, None])[1], 'u': '<u/>' in fo})
    return st, out
def grids(page):
    head, out = '', []
    for g in page['grids']:
        if not g: continue   # a note the export leaves out
        if 'h' in g: head = g['h']
        else: out.append(dict(g, name=g.get('named', head)))
    return out
def sheet_rows(z, i):
    x = z.read(f'xl/worksheets/sheet{i}.xml').decode()
    return x, len(re.findall(r'<row r="', x)) - 1
UNIT_RE = r' \((?:B|KB|MB|GB|TB|PB|ms|s|min|days|(?:B|KB|MB|GB|TB|PB)/day)\)$'   # a unit the export names in a header (X7: sizes, durations, days, sizes per day)
def table_head(head):
    # export.ts tableHead: each column named once (case ignored): an empty heading 'Column n', a repeat ' (2)'
    used, out = set(), []
    for j, h in enumerate(head):
        base = (h or '')[:250] or f'Column {j + 1}'; t = base; i = 2
        while t.lower() in used: t = f'{base} ({i})'; i += 1
        used.add(t.lower()); out.append(t)
    return out
def grid_sheets(z, gs, names):
    # (X1, X12) each screen grid's sheet in page order: a sheet whose header is the grid's (a unit in brackets left out on
    # both sides: the export names a size or a duration column's unit; a property card's item | value is Item | Value |
    # Status) and whose data rows are the grid's; every other sheet but 'About' (the last) is one of the page's other
    # sections (tiles, the Needs attention lines, a chart's series)
    sst = shared(z); out = []; k = 1
    def head_of(i):
        x = z.read(f'xl/worksheets/sheet{i}.xml').decode(); c = cells_of(x, sst)
        h = [c.get((1, j), (0, None, None))[2] for j in range(max([j for (r, j) in c if r == 1] + [-1]) + 1)]
        return [re.sub(UNIT_RE, '', t or '') for t in h], len(re.findall(r'<row r="', x)) - 1
    for g in gs:
        found = None
        # export.ts tableHead: an empty heading is 'Column n' in the file (an Excel table names every column), a repeat ' (2)'
        want = ['Item', 'Value', 'Status'] if g['head'] == ['item', 'value'] else table_head([re.sub(UNIT_RE, '', h or '') for h in g['head']])
        for i in range(k, len(names)):
            h, n = head_of(i)
            if h == want and (n == g['rows'] or (g['rows'] == 0 and n <= 1)): found = i; break
        out.append(found)
        if found: k = found + 1
    return out, [i for i in range(1, len(names)) if i not in out]
# export_names.ts mirrored (X2): the page's own time shapes leave a name (a date with a 4-digit year and a clock after it,
# in brackets or after a word), a bare count in brackets in grouping; a rate's slash reads 'per'; each character Excel
# refuses a space, runs of spaces one, spaces and quotes at either end off; ownName; under (the heading above, then the title)
DAY_ = r'(?:\d{4}[/.-]\d{1,2}[/.-]\d{1,2}|\d{1,2}[/.-]\d{1,2}[/.-]\d{4})'
CLOCK_ = r',?\s*\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AP]M)?'
def clean_(t):
    t = re.sub(r'(\S)\s*/\s*(s|sec|min|h|hr|day)\b', r'\1 per \2', t)
    return re.sub(r"^[\s']+|[\s']+$", '', re.sub(r'\s+', ' ', re.sub(r'[\\/?*\[\]:]', ' ', t)))
def title_of(t):
    t2 = re.sub(r'\s*\((?:read\s+)?[^()]*' + DAY_ + CLOCK_ + r'[^()]*\)', '', t)
    t2 = re.sub(r'\s*(?:\b(?:since|from|until|to|at|as of|read|of)\s+)?' + DAY_ + CLOCK_, '', t2, flags=re.I).strip()
    t2 = re.sub(r'\s*\(\d+(?:[,.\s\u202f\u00a0]\d{3})*\)$', '', t2).strip() or t   # a bare count in brackets out too ('Findings (16)', '(1000)')
    return clean_(t2)
def name_of(g):
    # the title a grid's sheet starts from: a data-sheet's own name kept whole ('alone'); one holding its own heading
    # ('with'), that name then the heading's title (export_names.ts ownName); else the heading's title
    if g.get('own') == 'with': return clean_(clean_(g['named']) + ' ' + title_of(g.get('oh') or ''))
    if g.get('own') == 'alone': return clean_(g['named'])
    return title_of(g['name'])
def under_(up, t):
    both = f'{up} {t}'
    if len(both) <= 31: return clean_(both)
    return clean_(re.sub(r"[\s'_.-]+$", '', up[:31 - 2 - len(t)]) + '… ' + t if len(t) <= 25 else re.sub(r"[\s']+$", '', both[:31]))
def close_cut(c):
    # export_names.ts closeCut: a name a cut left inside a bracket loses that bracket's start
    i = c.rfind('(')
    if i < 0 or c.find(')', i) >= 0: return c
    e = c.find('…', i)
    return (c[:i].rstrip() + (c[e:] if e >= 0 else '')) or c
def named_by(n, f, up):
    # a sheet's name made from its title f (export_names.ts sheetNames): the title cut at 31 (a bracket the cut lands in
    # left out), its start then '…' and the words where it parts from another, or under the heading above it; never a name
    # that ends inside a bracket it cut
    if re.search(r'\([^)]*$', n): return False
    cut31 = re.sub(r"[\s']+$", '', f[:31])
    if len(f) > 31 and re.search(r'\([^)]*$', cut31):
        if n == clean_(close_cut(cut31)): return True
    elif n.startswith(f[:24].rstrip()): return True
    if up and n == clean_(close_cut(under_(title_of(up), f))): return True
    if '…' in n:
        a_, b_ = n.split('…', 1)
        return f.startswith(a_.rstrip(" '_.-")) and (f.endswith(b_.strip()) or (a_ == '' and b_.strip() in f))
    return n.endswith(' ' + f[:31 - 2]) or n.endswith(' ' + f)
def safe_(n): return re.sub(r'[^A-Za-z0-9._-]+', '-', n).strip('-') or 'x'
def norm_(t): return re.sub(r'\s+', ' ', t or '').strip()   # the page's text as the export reads it (a locale's narrow space one space)
# (X7, the lead 13:44 (2)) a number with a unit as the pages write it: a size, a duration (fmtSecs's '1d 2h' too), a
# rate, a count of days
UNIT_TEXT = re.compile(r'-?[\d\s,.\u202f\u00a0]*\d ?(?:B|KB|MB|GB|TB|PB|ms|s|min|h|d|days?|hours?)(?: ?/ ?(?:day|h|s))?|-?\d+[dhm](?: \d+[hms])?|off \(\d+ days?\)')
# the mixed list, by sheet and column: the Instance Summary's ages (DBA Dash's Summary writes its ages as text: 'Instance
# Uptime' '51 minutes, 19 seconds' in its own file)
AGES = {'Memory Dump', 'Corruption', 'Last Good Check DB', 'Instance Uptime', 'Snapshot Age', 'Alerts'}
SIZE_U = ['B', 'KB', 'MB', 'GB', 'TB', 'PB']
DUR_MS = {'ms': 1, 's': 1000, 'min': 60000}
def digits_(t):
    t = re.sub(r'[\s\u202f\u00a0]', '', t)
    t = t.replace(',', '') if want.startswith('en') else t.replace(',', '.')
    try: return float(t), len(t.split('.')[1]) if '.' in t else 0
    except ValueError: return None, 0
def converted(head_unit, screen):
    # the screen's figure in the header's unit and its tolerance (half the shown last digit, and an fmtSecs part's truncation);
    # None: the screen shows no figure of that family; 'none': the screen shows no number at all
    if not re.search(r'\d', screen): return 'none'
    m = re.fullmatch(r'(-?\d+(?:\.(\d+))?) (B|KB|MB|GB|TB|PB)( / day)?', screen)
    hu = re.fullmatch(r'(B|KB|MB|GB|TB|PB)(/day)?', head_unit)
    if m and hu and bool(m.group(4)) == bool(hu.group(2)):
        k = len(m.group(2) or ''); b = float(m.group(1)) * 1024 ** SIZE_U.index(m.group(3)); tol = 0.5 * 10 ** -k * 1024 ** SIZE_U.index(m.group(3))
        return b / 1024 ** SIZE_U.index(hu.group(1)), tol / 1024 ** SIZE_U.index(hu.group(1)) + 1e-9
    if head_unit in DUR_MS:
        m = re.fullmatch(r'(.+) (ms|s|min)', screen)
        if m:
            v, k = digits_(m.group(1))
            if v is not None: return v * DUR_MS[m.group(2)] / DUR_MS[head_unit], 0.5 * 10 ** -k * DUR_MS[m.group(2)] / DUR_MS[head_unit] + 1e-9
        m = re.fullmatch(r'(-)?(?:(\d+)d)? ?(?:(\d+)h)? ?(?:(\d+)m)? ?(?:(\d+)s)?', screen)
        if m and any(m.group(i) for i in range(2, 6)):
            parts = [(m.group(2), 86400), (m.group(3), 3600), (m.group(4), 60), (m.group(5), 1)]
            secs = sum(int(a) * u for a, u in parts if a); low = min(u for a, u in parts if a)
            sign = -1 if m.group(1) else 1
            return sign * (secs + low / 2) * 1000 / DUR_MS[head_unit], (low / 2) * 1000 / DUR_MS[head_unit] + 1e-6
    if head_unit == 'days':
        m = re.fullmatch(r'(?:off \()?(.+) days?\)?', screen)
        if m:
            v, k = digits_(m.group(1))
            if v is not None: return v, 0.5 * 10 ** -k + 1e-9
        if re.fullmatch(r'over \d+ years', screen): return 'over'
    return None
def page_decimals(t):
    # (X13) how many decimals a screen figure shows, read here on its own (export.ts decimalsOf is the writer's): a size as
    # fmtBytes writes it (under 1024, at most one decimal: '1.6 GB', '7 B', '-2.0 GB / day'; a '.' in any language), a
    # number in the browser's language with a unit or a percent ('12.35 ms', '1 536,5 MB', '12,5 %', '233.3 days', 'off (0
    # days)'), a bare number ('17.35', '61,075'); None for words, a time, a date, a version, an address and fmtSecs's whole
    # units ('1m 5s': the page cuts the seconds it does not show; the writer leaves such a column General)
    t = re.sub(r'[\s\u202f\u00a0]+', ' ', t or '').strip()
    m = re.fullmatch(r'off \((.*)\)', t); t = m.group(1) if m else t
    m = re.fullmatch(r'-?\d{1,4}(?:\.(\d))? (?:B|KB|MB|GB|TB|PB)(?: / day)?', t)
    if m: return len(m.group(1) or '')
    if re.fullmatch(r'-?\d+[dhms](?: \d+[hms])*', t): return None
    m = re.fullmatch(r'[+-]?(\d[\d ,.]*?)(?: (?:%|ms|s|min|days?|B|KB|MB|GB|TB|PB)(?: / day)?)?', t)
    if not m: return None
    n = m.group(1).replace(' ', '')
    n = n.replace(',', '') if want.startswith('en') else n.replace(',', '.')
    if not re.fullmatch(r'\d+(?:\.\d+)?', n): return None
    return len(n.split('.')[1]) if '.' in n else 0
def stamp(n, inst, tab, ext):
    return re.fullmatch(re.escape(inst) + '_' + re.escape(tab) + r'_\d{8}-\d{4}_\d{8}-\d{4}' + re.escape(ext), n) is not None
# P03: the column widths as DBA Dash's writer sets them (export.ts colWidth: ClosedXML's AdjustToContents, Carlito's
# advance widths, a header 1.0286 x its bold text + 22.19 px, another cell 1.0738 x its text + 0.52 px, whole pixels,
# width = (px - 0.025625) / 7, at most 150). The advance tables are read from export.ts (the local DBA Dash comparison,
# proof-export-dbadash.py, grades them against DBA Dash's own widths); this re-measures every column of every sheet.
SRC = open('web/src/export.ts').read()
ADV = [int(x) for x in re.search(r'const ADV = \[([^\]]*)\]', SRC).group(1).split(',')]
ADV_B = [int(x) for x in re.search(r'const ADV_B = \[([^\]]*)\]', SRC).group(1).split(',')]
def tpx(t, bold, cap=True):
    # cap as export.ts textPx's: for the width rule only; the fit audit measures the whole text
    a = ADV_B if bold else ADV; u = 0
    for ch in t:
        c = ord(ch); u += a[c - 32] if 32 <= c <= 126 else 2048 if c >= 0x2e80 else (1030 if bold else 1013)
        if cap and u * 11 * 96 / 72 / 2048 > 1200: break
    return u * 11 * 96 / 72 / 2048
import datetime
FMT_CODES = {}
def render_code(val, code, group=',', dec='.'):
    # (F2, E2-15) a number under one of the page sheet's own formats (export.ts numFmtOf, sizeOf, dateFmt) as a
    # spreadsheet draws it, with the given grouping and decimal marks: '#,##0', '0.000', '0.0" MB"', a date form
    bare = re.sub(r'"[^"]*"', '', code)
    if re.search(r'[ymdhs]', bare):
        tm = datetime.datetime(1899, 12, 30) + datetime.timedelta(seconds=round(val * 86400))
        toks = re.findall(r'"[^"]*"|yyyy|yy|mm|m|dd|d|hh|h|ss|.', code)
        codes = [i for i, x in enumerate(toks) if re.fullmatch(r'y+|m+|d+|h+|s+', x)]
        out = []
        for i, x in enumerate(toks):
            if x.startswith('"'): out.append(x[1:-1]); continue
            if i not in codes: out.append(x); continue
            k = codes.index(i); prev = toks[codes[k - 1]] if k else ''; nxt = toks[codes[k + 1]] if k + 1 < len(codes) else ''
            if x[0] == 'm' and (prev.startswith('h') or nxt.startswith('s')): out.append(f'{tm.minute:02d}' if x == 'mm' else str(tm.minute)); continue
            v = {'y': tm.year, 'm': tm.month, 'd': tm.day, 'h': tm.hour, 's': tm.second}[x[0]]
            out.append(str(v)[-2:] if x == 'yy' else f'{v:02d}' if len(x) == 2 else str(v))
        return ''.join(out)
    m = re.fullmatch(r'(#,##0|0)(?:\.(0+))?(?:"([^"]*)")?', code)
    if not m: return js_num(val)
    k = len(m.group(2) or ''); s = f'{abs(val):,.{k}f}' if m.group(1) == '#,##0' else f'{abs(val):.{k}f}'
    s = s.replace(',', '\0').replace('.', dec).replace('\0', group)
    return ('-' if val < 0 else '') + s + (m.group(3) or '')   # a negative figure keeps its minus where it rounds to zero ('-0.0')
def shown_py(val, text, fmt):
    if text is not None: return max(re.split(r'\r?\n', text), key=len) if text else ''
    if val is None: return ''
    if fmt >= 171 and fmt in FMT_CODES: return render_code(val, FMT_CODES[fmt])
    if fmt == 168: return (datetime.datetime(1899, 12, 30) + datetime.timedelta(seconds=round(val * 86400))).strftime('%Y-%m-%d %H:%M')
    if fmt == 167: return f'{val * 100:.1f}%'
    if fmt == 9: return f'{val * 100:.0f}%'     # Excel's '0%' (a share the screen writes in whole percents, X13)
    if fmt == 10: return f'{val * 100:.2f}%'    # Excel's '0.00%'
    if fmt == 165: return f'{round(val):,} B'
    if FMT_CODES.get(fmt) == 'yyyy-MM-dd': return (datetime.datetime(1899, 12, 30) + datetime.timedelta(days=round(val))).strftime('%Y-%m-%d')   # a day alone (169)
    if fmt == 170: return f'{val:,.3f}'.rstrip('0').rstrip('.') + ' ms'
    if fmt == 166:
        t = round(val * 86400); a = abs(t); return f"{'-' if t < 0 else ''}{a // 3600}:{a // 60 % 60:02d}:{a % 60:02d}"
    if fmt == 1: return str(int(val))
    return js_num(val)
def js_num(v):
    # JavaScript's String(number), the text export.ts measures a General number by
    if v == int(v) and abs(v) < 1e21: return str(int(v))
    r = repr(v)
    if 1e-6 <= abs(v) < 1e21:
        if 'e' in r:
            from decimal import Decimal
            return format(Decimal(r), 'f')
        return r
    m, e = r.split('e') if 'e' in r else (r, '0')
    return f"{m}e{'+' if int(e) >= 0 else '-'}{abs(int(e))}"
def widths_of(x):
    out = {}
    for a, b, w in re.findall(r'<col min="(\d+)" max="(\d+)" width="([\d.]+)"', x):
        for k in range(int(a), int(b) + 1): out[k - 1] = float(w)
    return out
def texts_of(x, sst):
    # every cell's words as written: an inline string's runs joined, a shared string, else none (a number); with its runs
    # (text, size, bold): a rich string's each in its own font, a plain one a single run in the cell's (None, None)
    out = {}
    for m in re.finditer(r'<c r="([A-Z]+)(\d+)" s="(\d+)"(?: t="(\w+)")?(?:/>|>(.*?)</c>)', x, re.S):
        body = m.group(5) or ''
        if m.group(4) == 'inlineStr':
            t = unesc(''.join(re.findall(r'<t[^>]*>([^<]*)</t>', body)))
            rs = re.findall(r'<r>(?:<rPr>(.*?)</rPr>)?<t[^>]*>([^<]*)</t></r>', body)
            segs = [(unesc(tt), float((re.search(r'<sz val="([\d.]+)"', rp or '') or [None, 0])[1]) or None, ('<b/>' in rp) if rp else None) for rp, tt in rs] if rs else [(t, None, None)]
        elif m.group(4) == 's':
            v = re.search(r'<v>(\d+)</v>', body); t = sst[int(v.group(1))] if v and int(v.group(1)) < len(sst) else ''; segs = [(t, None, None)]
        else: continue
        out[(int(m.group(2)), colidx(m.group(1)))] = (int(m.group(3)), t, segs)
    return out
def seg_lines(segs, bold, sz):
    # a cell's lines in pixels, each run at its own size and weight (as export.ts linePx), the whole text (no cap)
    out = [0.0]
    for t, s, b in segs:
        for k, part in enumerate(t.split('\n')):
            if k: out.append(0.0)
            out[-1] += tpx(part, b if b is not None else bold, False) * (s or sz) / 11
    return out
def seg_size(segs, sz):
    return max([sz] + [s for _, s, _ in segs if s])
def fit_audit(x, cx, sst):
    # (E2 1b, fault 1) every text cell of a sheet is whole: a line of words fits the room it is drawn in - its column and
    # the empty cells after it in its row (none after it: it runs to the sheet's edge) - measured in the file's font as
    # the width rule measures a cell (Carlito's advances, 1.0738 x + the cell's padding, at the cell's size); a wrapped cell:
    # its lines at the column's width fit the row's height (1.36 x the points a line). Returns the cut cells.
    ws = widths_of(x); hts = {int(r): float(h) for r, h in re.findall(r'<row r="(\d+)" ht="([\d.]+)"', x)}
    allc = cells_of(x, sst); tx = texts_of(x, sst)
    px = lambda j: round((ws.get(j, 0) if ws.get(j, 0) > 0 else 8.43) * 7) + 5
    full = {k for k, v in allc.items() if v[1] is not None or (k in tx and tx[k][1] != '')}
    cut = []
    for (r, j), (sid, t, segs) in tx.items():
        if not t: continue
        st_ = cx[sid] if sid < len(cx) else {'bold': False, 'sz': 11.0, 'wrap': False}
        sz = st_.get('sz', 11.0); ls = seg_lines(segs, st_['bold'], sz)
        if st_.get('wrap'):
            room = max(10, px(j) - 6)
            lines = sum(max(1, math.ceil((1.0738 * w + 1) / room)) for w in ls)
            if lines * seg_size(segs, sz) * 1.36 > hts.get(r, 15.0) + 0.5: cut.append(f"{colname(j)}{r} '{t[:30]}' needs {lines} lines, row {hts.get(r, 15.0)} pt")
            continue
        need = 1.0738 * max(ls) + 6
        after = [k for (rr, k) in full if rr == r and k > j]
        if not after: continue
        room = sum(px(k) for k in range(j, min(after)))
        if need > room + 2: cut.append(f"{colname(j)}{r} '{t[:30]}' needs {round(need)} px, has {room}")
    return cut
def tall_audit(x, cx, sst):
    # (1b d) a row given a height is no taller than its tallest cell needs: its largest font's line, a wrapped cell's
    # lines at its column's width (each run at its own size), 1.36 x the points a line; (1b e) every cell of a row taller
    # than one line sits where the page sets it - top (the page's td and props cells), middle (its grid header) - never
    # at the bottom (Excel's default). Returns (rows over, cells at the bottom).
    ws = widths_of(x); hts = {int(r): float(h) for r, h in re.findall(r'<row r="(\d+)" ht="([\d.]+)"', x)}
    px = lambda j: round((ws.get(j, 0) if ws.get(j, 0) > 0 else 8.43) * 7) + 5
    tx = texts_of(x, sst); need = {}; low = []
    for m in re.finditer(r'<c r="([A-Z]+)(\d+)" s="(\d+)"', x):
        r, j, sid = int(m.group(2)), colidx(m.group(1)), int(m.group(3))
        st_ = cx[sid] if sid < len(cx) else {'bold': False, 'sz': 11.0, 'wrap': False, 'valign': 'bottom'}
        sz = st_.get('sz', 11.0); segs = tx.get((r, j), (0, '', []))[2]; size = seg_size(segs, sz) if segs else sz
        h = size * 1.36
        if st_.get('wrap') and (r, j) in tx and tx[(r, j)][1]:
            h = sum(max(1, math.ceil((1.0738 * w + 1) / max(10, px(j) - 6))) for w in seg_lines(segs, st_['bold'], sz)) * size * 1.36
        need[r] = max(need.get(r, 15.0), math.ceil(h))
        if hts.get(r, 15.0) > 15.5 and st_.get('valign', 'bottom') == 'bottom' and (r, j) in tx and tx[(r, j)][1]:
            low.append(f"{colname(j)}{r} '{tx[(r, j)][1][:24]}' in a {hts[r]} pt row")
    over = [f"row {r} {h} pt, its lines {need.get(r, 15)}" for r, h in sorted(hts.items()) if h > need.get(r, 15.0) + 1]
    return over, low
def tiles_audit(x, sst, tiles):
    # (step 2 a) each tile the page shows is a card on the page sheet: its label in a cell, its value in a cell of the
    # same column within the next four rows, its pill (if any) in that column between them; and no cell holds a tile's
    # value and its label run together. Returns (tiles found, missing, run together).
    tx = texts_of(x, sst); ns = lambda s: re.sub(r'\s+', '', s or '')
    at = {}
    for (r, j), (sid, t, segs) in tx.items(): at.setdefault(ns(t), []).append((r, j))
    found, missing, runs = 0, [], []
    for t in tiles:
        if not t.get('l') or not t.get('v'): continue
        ok = False
        for (r, j) in at.get(ns(t['l']), []):
            below = {ns(tx[(rr, j)][1]): rr for rr in range(r + 1, r + 5) if (rr, j) in tx}
            if ns(t['v']) in below and (not t.get('p') or ns(t['p']) in below): ok = True; break
        if ok: found += 1
        else: missing.append(f"{t['l'][:20]} / {t['v'][:12]}{' / ' + t['p'] if t.get('p') else ''}")
        for (r, j), (sid, s, segs) in tx.items():
            if ns(s) in (ns(t['v']) + ns(t['l']), ns(t['l']) + ns(t['v'])): runs.append(f"{colname(j)}{r} '{s[:30]}'")
    return found, missing, runs
def wrap_audit(x, cx, sst, wrapped):
    # (step 2 b1) a wrapped text cell with nothing to its right on its row (no cell with words, a number, a fill or a
    # border) is a text the page itself draws on more than one line; anything else runs over the empty cells as the
    # page's one line does. Returns the cells wrapped where the page has one line.
    tx = texts_of(x, sst); ns = lambda s: re.sub(r'\s+', ' ', s or '').strip()
    pw = [ns(w)[:40] for w in wrapped]
    right = {}
    for m in re.finditer(r'<c r="([A-Z]+)(\d+)" s="(\d+)"(?: t="(\w+)")?(?:/>|>(.*?)</c>)', x, re.S):
        r, j, sid = int(m.group(2)), colidx(m.group(1)), int(m.group(3))
        st_ = cx[sid] if sid < len(cx) else {}
        has = bool(st_.get('fill')) or bool(st_.get('border')) or re.search(r'<v>|<t[^>]*>[^<]', m.group(5) or '') is not None
        if has: right[r] = max(right.get(r, -1), j)
    bad = []
    for (r, j), (sid, t, segs) in tx.items():
        st_ = cx[sid] if sid < len(cx) else {}
        if not t or not st_.get('wrap') or right.get(r, -1) > j: continue
        k = ns(t)[:40]
        if not any(w.startswith(k) or k.startswith(w) for w in pw if w): bad.append(f"{colname(j)}{r} '{t[:36]}'")
    return bad
def png_rgba(b):
    # a PNG's size and pixels (8-bit RGB or RGBA, not interlaced: what a canvas's toDataURL writes), zlib only
    import struct, zlib
    if b[:8] != b'\x89PNG\r\n\x1a\n': return 0, 0, 4, b''
    pos, idat, w, h, ct = 8, b'', 0, 0, 6
    while pos + 8 <= len(b):
        n = struct.unpack('>I', b[pos:pos + 4])[0]; t = b[pos + 4:pos + 8]; dta = b[pos + 8:pos + 8 + n]; pos += 12 + n
        if t == b'IHDR': w, h, _, ct = struct.unpack('>IIBB', dta[:10])
        elif t == b'IDAT': idat += dta
        elif t == b'IEND': break
    bpp = 4 if ct == 6 else 3; stride = w * bpp; raw = zlib.decompress(idat); out = bytearray(); prev = bytearray(stride); i = 0
    for _ in range(h):
        f = raw[i]; ln = bytearray(raw[i + 1:i + 1 + stride]); i += 1 + stride
        if f == 1:
            for x in range(bpp, stride): ln[x] = (ln[x] + ln[x - bpp]) & 255
        elif f == 2:
            for x in range(stride): ln[x] = (ln[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride): ln[x] = (ln[x] + (((ln[x - bpp] if x >= bpp else 0) + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = ln[x - bpp] if x >= bpp else 0; up = prev[x]; c = prev[x - bpp] if x >= bpp else 0
                p_ = a + up - c; pa, pb, pc = abs(p_ - a), abs(p_ - up), abs(p_ - c)
                ln[x] = (ln[x] + (a if pa <= pb and pa <= pc else up if pb <= pc else c)) & 255
        out += ln; prev = ln
    return w, h, bpp, bytes(out)
def rgb_of(s):
    s = (s or '').strip()
    m = re.fullmatch(r'#([0-9a-fA-F]{6})', s)
    if m: return tuple(int(m.group(1)[k:k + 2], 16) for k in (0, 2, 4))
    m = re.fullmatch(r'#([0-9a-fA-F]{3})', s)
    if m: return tuple(int(c * 2, 16) for c in m.group(1))
    m = re.match(r'rgba?\((\d+),\s*(\d+),\s*(\d+)', s)
    return tuple(int(m.group(k)) for k in (1, 2, 3)) if m else None
def colour_runs(x):
    # every inline string cell's runs with their colours: [(text, 'RRGGBB' or None)]; a plain inline cell one run, None
    out = []
    for m in re.finditer(r'<c r="[A-Z]+\d+" s="\d+" t="inlineStr"><is>(.*?)</is></c>', x, re.S):
        rs = re.findall(r'<r>(?:<rPr>(.*?)</rPr>)?<t[^>]*>([^<]*)</t></r>', m.group(1))
        out.append([(unesc(tt), (re.search(r'<color rgb="FF([0-9A-Fa-f]{6})"', rp or '') or [None, None])[1]) for rp, tt in rs]
                   or [(unesc(''.join(re.findall(r'<t[^>]*>([^<]*)</t>', m.group(1)))), None)])
    return out
def legend_audit(cells, swatches):
    # (21:05) each swatch of a chart's legend on the page sheet: a run '■' in the swatch's colour, its name in the run
    # after it; the names not found so
    wrong = []
    for s in swatches:
        q = rgb_of(s.get('colour')); want = ('%02X%02X%02X' % q) if q else '?'
        if not any(rs[k][0].strip() == '■' and (rs[k][1] or '').upper() == want and k + 1 < len(rs) and rs[k + 1][0].strip().startswith(s['label'])
                   for rs in cells for k in range(len(rs))): wrong.append(s['label'])
    return wrong
def attention_audit(x, sst, att):
    # (F1) each 'Needs attention' line on the page sheet: a cell whose words after its dot are the line's name (the
    # link's text), its reasons a cell of their own on that row, its badge a cell of its own; the badges' columns
    tx = texts_of(x, sst); cols, bad = set(), []
    for a in att:
        hit = sorted(r_ for (r_, c_), (_, t_, _) in tx.items() if re.sub(r'^● ', '', t_) == a['name'])
        if not hit: bad.append(a['name'] + ': no cell of its name alone'); continue
        row_ = {c_: t_ for (r_, c_), (_, t_, _) in tx.items() if r_ == hit[0]}
        if a['text'] and a['text'] not in row_.values(): bad.append(a['name'] + ': its reasons not a cell of their own')
        bc = sorted(c_ for c_, t_ in row_.items() if t_ == a['badge'])
        if bc: cols.add(bc[0])
        else: bad.append(a['name'] + ': no badge cell')
    return cols, bad
def pictures_of(z):
    # the page sheet's pictures in drawing order: (width and height in CSS px from the anchor's EMU, alt text, PNG bytes)
    if 'xl/drawings/drawing1.xml' not in z.namelist(): return []
    dx = z.read('xl/drawings/drawing1.xml').decode(); rels = z.read('xl/drawings/_rels/drawing1.xml.rels').decode()
    tg = dict(re.findall(r'Id="(rId\d+)"[^>]*Target="\.\./media/([^"]+)"', rels))
    out = []
    for a in re.findall(r'<xdr:oneCellAnchor>(.*?)</xdr:oneCellAnchor>', dx, re.S):
        e = re.search(r'<xdr:ext cx="(\d+)" cy="(\d+)"/>', a); ds = re.search(r'descr="([^"]*)"', a); rid = re.search(r'r:embed="(rId\d+)"', a)
        row_ = re.search(r'<xdr:row>(\d+)</xdr:row>', a)
        out.append({'w': int(e.group(1)) / 9525, 'h': int(e.group(2)) / 9525, 'descr': unesc(ds.group(1)) if ds else '', 'row': int(row_.group(1)) if row_ else -1,
                    'png': z.read('xl/media/' + tg[rid.group(1)]) if rid and rid.group(1) in tg else b''})
    return out
def chart_audit(key, z, names, sst, look, light=None):
    # (E2-8, the lead 19:22) each chart the page draws is a picture on the page sheet: as wide in the sheet as its plot
    # on the page (within 2 px), its pixels 2x that; its alt text names the title, the series shown and a numbers sheet
    # that exists, whose header is 'time' and those series and which holds points; its pixels hold every shown series'
    # colour of the light palette and the light card colour behind the title, not blank. light: the light page's facts
    # (palette, card) for an export made in the dark theme
    lk = light or look
    drawn = [c for c in look.get('charts') or [] if c.get('w')]
    pics = pictures_of(z)
    check(len(pics) == len(drawn), f"{key}: {len(drawn)} chart(s) drawn on the page, {len(pics)} picture(s) on the page sheet")
    pal = [rgb_of(c) for c in lk.get('palette') or []]; card = rgb_of(lk.get('card'))
    for c, p in zip(drawn, pics):
        w, h, bpp, px = png_rgba(p['png'])
        check(abs(p['w'] - c['w']) <= 2 and abs(w - 2 * p['w']) <= 1, f"{key}: chart '{c['title']}' {round(p['w'], 1)} CSS px wide in the sheet for {round(c['w'], 1)} on the page; its picture {w} x {h} px = 2x")
        shown = [s['label'] for s in c['series'] if s['on']]
        m = re.search(r'numbers on sheet (.+)$', p['descr']); sn = m.group(1) if m else ''
        check(p['descr'].startswith(c['title'] + ':') and all(s in p['descr'] for s in shown) and sn in names[1:], f"{key}: chart '{c['title']}' alt text '{p['descr'][:120]}' names its series {shown} and its numbers sheet ('{sn}' {'found' if sn in names else 'missing'})")
        if sn in names and not c.get('svg'):
            x, n = sheet_rows(z, names.index(sn) + 1); t1 = texts_of(x, sst)
            hd = [t1[(1, j)][1] for j in range(len(shown) + 1) if (1, j) in t1]
            check(hd == ['time'] + shown and n >= 2, f"{key}: chart '{c['title']}' numbers sheet '{sn}': header {hd}, {n} points")
        at = lambda xx, yy: tuple(px[(yy * w + xx) * bpp:(yy * w + xx) * bpp + 3]) if w and h else None
        near = lambda q, r_, d=24: q and r_ and all(abs(q[k] - r_[k]) <= d for k in range(3))
        cols = {}
        for i in range(0, len(px), bpp * 7): cols[px[i:i + 3]] = cols.get(px[i:i + 3], 0) + 1
        idx = [i for i, s in enumerate(c['series']) if s['on']]
        want = [rgb_of(f_) for f_ in c.get('fills') or []] if c.get('svg') else [pal[i] if i < len(pal) else None for i in idx]
        found = [sum(v for q, v in cols.items() if near(tuple(q), wc)) for wc in want]
        check(w > 0 and near(at(w - 1, 0), card, 2) and len(cols) >= 8 and all(f_ >= 3 for f_ in found),
              f"{key}: chart '{c['title']}' picture: the card colour {lk.get('card')} at its top right ({at(w - 1, 0) if w else None}), {len(cols)} colours sampled, each shown series' colour found {found}")
        if not c.get('svg') and c.get('h'):
            # (F6) no title of its own: the picture is the plot and its legend's lines (20 CSS px each), the sheet's line
            # above it names the chart; (F7) each shown series' legend mark a short bar as the page's (14 x 4 CSS px)
            extra = p['h'] - c['h']; nl = round(extra / 20)
            check(nl >= 1 and abs(extra - 20 * nl) <= 1, f"{key}: chart '{c['title']}' picture without a title of its own (F6): {round(p['h'], 1)} CSS px high = the plot's {round(c['h'], 1)} + {nl} legend line(s) of 20 px ({round(extra, 1)})")
            y0 = int(round(c['h'] * 2)); boxes = []
            for wc in want:
                xs_, ys_ = [], []
                for yy in range(y0, h):
                    for xx in range(w):
                        if near(at(xx, yy), wc, 24): xs_.append(xx); ys_.append(yy)
                boxes.append((max(xs_) - min(xs_) + 1, max(ys_) - min(ys_) + 1) if xs_ else (0, 0))
            check(bool(boxes) and all(bw >= 2.5 * bh and 0 < bh <= 12 for bw, bh in boxes), f"{key}: chart '{c['title']}' legend marks as short bars like the page's (F7): each shown series' mark w x h px at 2x {boxes}")
        if c.get('svg') and c.get('legend'):
            # its legend (an HTML swatch legend or the ring's legend table): each colour square a '■' in the light
            # page's colour before its name (light: the light page's swatches for an export made dark)
            lc = next((q for q in (lk.get('charts') or []) if q.get('title') == c['title']), c)
            sws = lc.get('swatches') or []
            wrong = legend_audit(colour_runs(sheet_rows(z, 1)[0]), sws)
            check(len(sws) >= 1 and not wrong, f"{key}: chart '{c['title']}': its legend on the page sheet - each of its {len(sws)} swatch(es) a ■ in the swatch's colour before its name ({len(sws) - len(wrong)} found; wrong {wrong[:4]})")
    return pics
def width_audit(x, cx, sst):
    # every column: the width the rule gives its cells (row 1, the header, measured as DBA Dash's bold header: the
    # rule's own place, not the cell's font - the page's header is not bold, and a bold badge cell is no header),
    # within one pixel (1/7)
    cells = cells_of(x, sst); ws = widths_of(x); cols = {}
    for (r, c), (sid, val, text) in cells.items():
        t = shown_py(val, text, cx[sid]['fmt'] if sid < len(cx) else 0)
        if not t: continue
        px = 1.0286 * tpx(t, True) + 22.19 if r == 1 else 1.0738 * tpx(t, False) + 0.52
        cols[c] = max(cols.get(c, 0), px)
    off = []
    for c, w in ws.items():
        px = round(cols.get(c, 0)); want = 8.43 if px <= 0 else min(150, (px - 0.025625) / 7)
        if abs(w - want) > 1 / 7 + 1e-6 or w > 150: off.append(f'{colname(c)} {w} vs {round(want, 6)}')
    return len(ws), off

print(f"     browser language {d['lang']}, 1234567 shown as {d['sample']!r}")
check(d['lang'].lower().startswith(want[:2].lower()), f"the browser runs in {want}")
if want.startswith('fr'):
    check(',' not in d['sample'], "the fr-FR grouping is not a comma (the locale took)")
# fit_audit's self-test: a planted long label in a narrow column with a cell after it is cut; the same label with the
# cell after it empty runs over (whole); a wrapped cell in a row too short for its lines is cut
_cx = [{'fmt': 0, 'fill': None, 'font': None, 'bold': False, 'wrap': False, 'sz': 11.0}, {'fmt': 0, 'fill': None, 'font': None, 'bold': False, 'wrap': True, 'sz': 11.0}]
_lab = "msdb's backup history reaches back to"
_x1 = f'<cols><col min="1" max="1" width="10" customWidth="1"/></cols><sheetData><row r="1"><c r="A1" s="0" t="inlineStr"><is><t>{_lab}</t></is></c><c r="B1" s="0" t="inlineStr"><is><t>x</t></is></c></row></sheetData>'
_x2 = _x1.replace('<c r="B1" s="0" t="inlineStr"><is><t>x</t></is></c>', '')
_x3 = f'<cols><col min="1" max="1" width="10" customWidth="1"/></cols><sheetData><row r="1"><c r="A1" s="1" t="inlineStr"><is><t>{_lab} {_lab}</t></is></c></row></sheetData>'
check(len(fit_audit(_x1, _cx, [])) == 1 and fit_audit(_x2, _cx, []) == [] and len(fit_audit(_x3, _cx, [])) == 1,
      f"fit: self-test - a planted label cut by the cell after it is found ({fit_audit(_x1, _cx, [])}), the same label running over empty cells is whole, a wrapped cell in a short row is found")
# a wrapped text past textPx's 1,200 px cap: a row as tall as the capped count's lines is found short, the whole count's is whole
_long = ' '.join([_lab] * 12)
_n = lambda cap: max(1, math.ceil((1.0738 * tpx(_long, False, cap) + 1) / (round(150 * 7) + 5 - 6)))
_x4 = lambda n: f'<cols><col min="1" max="1" width="150" customWidth="1"/></cols><sheetData><row r="1" ht="{math.ceil(n * 11 * 1.36)}" customHeight="1"><c r="A1" s="1" t="inlineStr"><is><t>{_long}</t></is></c></row></sheetData>'
check(_n(True) < _n(False) and len(fit_audit(_x4(_n(True)), _cx, [])) == 1 and fit_audit(_x4(_n(False)), _cx, []) == [],
      f"fit: self-test - a wrapped text past the 1,200 px cap ({round(tpx(_long, False, False))} px) in a row of the capped count's {_n(True)} lines is found, in a row of its {_n(False)} lines whole")
_cx2 = _cx + [{'fmt': 0, 'bold': False, 'wrap': True, 'sz': 15.0, 'valign': 'top'}, {'fmt': 0, 'bold': False, 'wrap': False, 'sz': 11.0, 'valign': 'bottom'}, {'fmt': 0, 'bold': False, 'wrap': False, 'sz': 11.0, 'valign': 'top'}]
_tile = lambda ht, s: f'<cols><col min="1" max="2" width="20" customWidth="1"/></cols><sheetData><row r="1" ht="{ht}" customHeight="1"><c r="A1" s="2" t="inlineStr"><is><r><rPr><sz val="15"/></rPr><t xml:space="preserve">13</t></r><r><rPr><sz val="11"/></rPr><t xml:space="preserve">xmin horizon age</t></r></is></c><c r="B1" s="{s}" t="inlineStr"><is><t>version</t></is></c></row></sheetData>'
check(tall_audit(_tile(21, 4), _cx2, []) == ([], []) and len(tall_audit(_tile(41, 4), _cx2, [])[0]) == 1 and len(tall_audit(_tile(21, 3), _cx2, [])[1]) == 1 and fit_audit(_tile(21, 4), _cx2, []) == [],
      f"tall: self-test - a tile's 15 pt value and 11 pt label on one line: a 21 pt row whole and not over, the 41 pt of the count at one size found over ({tall_audit(_tile(41, 4), _cx2, [])[0]}), a label at the bottom of the tall row found ({tall_audit(_tile(21, 3), _cx2, [])[1]})")
_tl = [{'l': 'xmin horizon age', 'v': '10', 'p': 'WARN'}]
_tx1 = '<sheetData><row r="1"><c r="A1" s="0" t="inlineStr"><is><t>10xmin horizon age</t></is></c></row><row r="2"><c r="A2" s="0" t="inlineStr"><is><t>WARN</t></is></c></row></sheetData>'
_tx2 = '<sheetData><row r="1"><c r="A1" s="0" t="inlineStr"><is><t>xmin horizon age</t></is></c></row><row r="2"><c r="A2" s="0" t="inlineStr"><is><t>WARN</t></is></c></row><row r="3"><c r="A3" s="0" t="inlineStr"><is><t>10</t></is></c></row></sheetData>'
_cx3 = _cx + [{'fmt': 0, 'fill': 'FFEEEEEE', 'border': False, 'bold': False, 'wrap': False, 'sz': 11.0}]
_wx = lambda after: f'<sheetData><row r="1"><c r="A1" s="1" t="inlineStr"><is><t>{_lab}</t></is></c>{after}</row></sheetData>'
check(tiles_audit(_tx1, [], _tl)[1:] == (['xmin horizon age / 10 / WARN'], ["A1 '10xmin horizon age'"]) and tiles_audit(_tx2, [], _tl) == (1, [], [])
      and len(wrap_audit(_wx(''), _cx3, [], [])) == 1 and wrap_audit(_wx(''), _cx3, [], [_lab]) == [] and wrap_audit(_wx('<c r="B1" s="2"/>'), _cx3, [], []) == [],
      f"tiles and wraps: self-test - a tile's value and label in one cell found ({tiles_audit(_tx1, [], _tl)[1:]}), label / pill / value down one column found whole; a wrapped cell with nothing to its right found when the page has one line, whole when the page wraps it or a filled cell is to its right")
def _png(w, h, px, filters):
    # a planted PNG: rows filtered as given (0 none, 1 sub, 2 up, 4 Paeth), RGBA
    import struct, zlib
    raw = b''; prev = bytes(w * 4)
    for y in range(h):
        ln = px[y * w * 4:(y + 1) * w * 4]; f = filters[y]; enc = bytearray()
        for x in range(w * 4):
            a = ln[x - 4] if x >= 4 else 0; up = prev[x]; c = prev[x - 4] if x >= 4 else 0
            if f == 0: pr = 0
            elif f == 1: pr = a
            elif f == 2: pr = up
            else:
                p_ = a + up - c; pa, pb, pc = abs(p_ - a), abs(p_ - up), abs(p_ - c); pr = a if pa <= pb and pa <= pc else up if pb <= pc else c
            enc.append((ln[x] - pr) & 255)
        raw += bytes([f]) + bytes(enc); prev = ln
    ch = lambda t, dta: struct.pack('>I', len(dta)) + t + dta + struct.pack('>I', zlib.crc32(t + dta) & 0xffffffff)
    return b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b'')
_pp = bytes((x * 37 + y * 91 + k * 13) % 256 for y in range(4) for x in range(5) for k in range(4))
_dec = png_rgba(_png(5, 4, _pp, [0, 1, 2, 4]))
check(_dec == (5, 4, 4, _pp) and rgb_of('#2a6fd6') == (42, 111, 214) and rgb_of('rgb(255, 255, 255)') == (255, 255, 255),
      f"charts: self-test - a planted 5 x 4 PNG with rows filtered none / sub / up / Paeth decoded to its own pixels ({_dec[:3]}, {'equal' if _dec[3] == _pp else 'DIFFERENT'}); colours read from #hex and rgb()")
_lg = lambda col: f'<sheetData><row r="1"><c r="A1" s="0" t="inlineStr"><is><r><rPr><sz val="11"/>{col}<rFont val="Calibri"/></rPr><t xml:space="preserve">■ </t></r><r><rPr><sz val="11"/><color rgb="FF1B2230"/><rFont val="Calibri"/></rPr><t xml:space="preserve">WRITELOG</t></r></is></c></row></sheetData>'
_sw = [{'label': 'WRITELOG', 'colour': 'rgb(42, 111, 214)'}]
_lg_ok, _lg_other = legend_audit(colour_runs(_lg('<color rgb="FF2A6FD6"/>')), _sw), legend_audit(colour_runs(_lg('<color rgb="FFC4511A"/>')), _sw)
_lg_none = legend_audit(colour_runs('<sheetData><row r="1"><c r="A1" s="0" t="inlineStr"><is><t>WRITELOG</t></is></c></row></sheetData>'), _sw)
_at = [{'name': 'db1', 'text': 'Agent Jobs 2 critical', 'badge': 'Critical'}, {'name': 'db22', 'text': 'Roles 1 warning', 'badge': 'Warning'}]
_ax = lambda b2: f'<sheetData><row r="1"><c r="A1" s="0" t="inlineStr"><is><t>● db1</t></is></c><c r="B1" s="0" t="inlineStr"><is><t>Agent Jobs 2 critical</t></is></c><c r="E1" s="0" t="inlineStr"><is><t>Critical</t></is></c></row><row r="2"><c r="A2" s="0" t="inlineStr"><is><t>● db22</t></is></c><c r="B2" s="0" t="inlineStr"><is><t>Roles 1 warning</t></is></c><c r="{b2}2" s="0" t="inlineStr"><is><t>Warning</t></is></c></row></sheetData>'
_at_ok, _at_two = attention_audit(_ax('E'), [], _at), attention_audit(_ax('D'), [], _at)
_at_run = attention_audit(_ax('E').replace('<t>● db1</t></is></c><c r="B1" s="0" t="inlineStr"><is><t>Agent Jobs 2 critical</t>', '<t>● db1Agent Jobs 2 critical</t></is></c><c r="B1" s="0" t="inlineStr"><is><t>x</t>'), [], _at)
check(len(_at_ok[0]) == 1 and not _at_ok[1] and len(_at_two[0]) == 2 and _at_run[1],
      f"attention: self-test - two lines with their badges in one column found right ({sorted(_at_ok[0])}), in two columns found ({sorted(_at_two[0])}), a name run into its reasons found ({_at_run[1][:1]})")
check(_lg_ok == [] and _lg_other == ['WRITELOG'] and _lg_none == ['WRITELOG'],
      f"charts: self-test - a legend's ■ in its swatch's colour before its name found ({_lg_ok}); a ■ in another colour ({_lg_other}) and a name without its ■ ({_lg_none}) found wrong")
iname = re.sub(r'[^A-Za-z0-9._-]+', '-', d['instance'])
CONVERTED = [0]
# (decision (b)) the SQL Server instance's Jobs tab, when the demo has a SQL Server instance
PAGES = [('summary', 'Summary', 'fleet'), ('backups', 'Backups', 'fleet'), ('jobs', 'Jobs', 'fleet'), ('storage', 'Storage', 'fleet'), ('drives', 'Drives', 'fleet'), ('dbspace', 'DB-Space', 'fleet'), ('dbfiles', 'Files', 'fleet'), ('tables', 'Table-Size', iname), ('roles', 'Roles', iname),
         ('activity', 'Running-queries', iname), ('slow', 'Slow-queries', 'fleet'), ('perf', 'Performance-summary', 'fleet'), ('db', 'Database', iname), ('empty', 'Table-Size', iname)]
if (d.get('volumes') or {}).get('grids') is not None: PAGES.append(('volumes', 'Storage', iname))   # the instance Storage page (days, rates, Volumes)
if d.get('sqljobs') and not d['sqljobs'].get('none'): PAGES.append(('sqljobs', 'Jobs', re.sub(r'[^A-Za-z0-9._-]+', '-', d['sqljobs']['instance'])))
elif d.get('sqljobs'): print(f"not checked: sqljobs: the SQL Server instance {d['sqljobs']['instance']}'s Jobs tab shows no grid ({d['sqljobs']['none'][:100]})")
else: print("not checked: sqljobs: the demo has no SQL Server instance (its Jobs tab's step grids)")
if d.get('dbspace_i'): PAGES.append(('dbspace_i', 'DB-Space', re.sub(r'[^A-Za-z0-9._-]+', '-', d['dbspace_i']['instance'])))
else: print("not checked: dbspace_i: the demo has no SQL Server instance (its DB Space grid)")
if d.get('dbspace_p'): PAGES.append(('dbspace_p', 'DB-Space', re.sub(r'[^A-Za-z0-9._-]+', '-', d['dbspace_p']['instance'])))
else: print("not checked: dbspace_p: the demo has no PostgreSQL instance (its DB Space grid)")
if openpyxl is None:
    skipped('lib', "python3 has no openpyxl (PGVIGIL_PYLIB names a folder that holds it): no workbook was opened by a spreadsheet library")
for key, tab, inst in PAGES:
    p = d[key]; gs = grids(p)
    check(stamp(p['xlsx'], inst, tab, '.xlsx'), f"{key}: the workbook's name {p['xlsx']}")
    z = zipfile.ZipFile(f"{dl}/{p['xlsx']}")
    names = sheets_of(z)
    st, cx = xfs(z)
    # (changed by X1 / X12 / D-A: no page sheet - the sheets are the page's sections in page order, the grids and the
    # sections that are no grid (tiles, the Needs attention lines, a chart's series), then 'About' LAST)
    gsheet, extra = grid_sheets(z, gs, names)
    check(names[-1] == 'About' and None not in gsheet and gsheet == sorted(gsheet),
          f"{key}: sheets {names} = the page's sections in page order, then 'About' (grid sheets {gsheet}; other sections {[names[k - 1] for k in extra]})"
          + ''.join(f"; no sheet for the screen's grid '{g['name']}' ({' | '.join(g['head'][:8])}; {g['rows']} rows)" for g, k in zip(gs, gsheet) if k is None))
    if None in gsheet:
        continue   # a grid with no sheet: the page fails on the row above; its other rows cannot be read
    ct = z.read('[Content_Types].xml').decode(); wbx = z.read('xl/workbook.xml').decode(); tabs = []; linked = False; classed = 0; sst = shared(z)
    for i, g in enumerate(gs):
        x, n = sheet_rows(z, gsheet[i])
        # (changed by X6: no frozen row - DBA Dash freezes none)
        check('<pane' not in x, f"{key}: sheet '{names[gsheet[i] - 1]}' no pane (X6)")
        nw, woff = width_audit(x, cx, sst)
        check(nw >= max(1, len(g['head'])) and not woff, f"{key}: sheet '{names[gsheet[i] - 1]}' {nw} column widths by DBA Dash's rule, none over 150 ({len(woff)} off {woff[:3]})")
        over, low = tall_audit(x, cx, sst)
        check(not over and not low, f"{key}: sheet '{names[gsheet[i] - 1]}' no row taller than its lines, no cell at the bottom of a tall row (over {over[:2]}; bottom {low[:2]})")
        check(n == g['rows'], f"{key}: sheet '{names[gsheet[i] - 1]}' {n} data rows = {g['rows']} on screen")
        counts, cells = audit(key, names[gsheet[i] - 1], x, cx, g, sst)
        classed += counts['class']
        rels = f'xl/worksheets/_rels/sheet{gsheet[i]}.xml.rels'
        # (changed by P1 / P2, the lead 22:34: an empty grid's sheet held the plain filter and no table; now, as DBA Dash
        # writes it, every grid sheet is one table and an empty grid's covers its header and ONE empty row)
        if g['rows'] == 0:
            check('<tableParts count="1">' in x and '<autoFilter' not in x and rels in z.namelist() and '_xlnm._FilterDatabase' not in wbx and '<row r="2"' not in x,
                  f"{key}: sheet '{names[gsheet[i] - 1]}' has no rows: one Excel table over its header and one empty row, no sheet filter, no _FilterDatabase (P2)")
        if True:
            rel = z.read(rels).decode() if rels in z.namelist() else ''
            m = re.search(r'Target="\.\./tables/(table\d+\.xml)"', rel)
            tx = z.read('xl/tables/' + m.group(1)).decode() if m and 'xl/tables/' + m.group(1) in z.namelist() else ''
            check('<tableParts count="1"><tablePart r:id="rId1"/></tableParts>' in x and '<autoFilter' not in x and bool(tx), f"{key}: sheet '{names[gsheet[i] - 1]}' names one table part, no sheet filter beside it")
            check('<tableStyleInfo showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/>' in tx and 'tableStyleInfo name=' not in tx, f"{key}: sheet '{names[gsheet[i] - 1]}' its table has DBA Dash's style info (no style name, row stripes 1: none drawn)")
            # (changed by X12: a property card's sheet is an Item | Value | Status table, three columns)
            card = g['head'] == ['item', 'value']
            gh = ['Item', 'Value', 'Status'] if card else g['head']
            ncol = 3 if card else max([len(g['head'])] + [len(r) for r in g['cells']])
            ref = f"A1:{colname(ncol - 1)}{max(g['rows'], 1) + 1}"
            got = [(re.search(a, b) or [None, None])[1] for a, b in ((r'<table [^>]*\bref="([^"]+)"', tx), (r'<autoFilter ref="([^"]+)"', tx), (r'<dimension ref="([^"]+)"', x))]
            check(got == [ref, ref, ref], f"{key}: sheet '{names[gsheet[i] - 1]}' the table's ref, its filter's and the sheet's dimension are {ref} ({got})")
            cols = [unesc(c) for c in re.findall(r'<tableColumn id="\d+" name="([^"]*)"', tx)]
            hdr = [cells.get((1, j), (0, None, None))[2] for j in range(ncol)]
            check(len(cols) == ncol and all(cols) and len({c.lower() for c in cols}) == ncol and cols == hdr and f'<tableColumns count="{ncol}">' in tx,
                  f"{key}: sheet '{names[gsheet[i] - 1]}' {len(cols)} table columns, each named once, = the header cells")
            row1x = (re.search(r'<row r="1"[^>]*>(.*?)</row>', x, re.S) or [None, ''])[1]
            check(row1x.count(' t="s"><v>') == ncol and 'inlineStr' not in row1x and 'sharedStrings+xml' in ct, f"{key}: sheet '{names[gsheet[i] - 1]}' its {ncol} header cells are shared strings")
            # (changed by X7: a size or a duration column's header carries its unit, ' (GB)', ' (s)': left out on both sides - the
            # screen may name it too - its own rows check it)
            nu = lambda t: re.sub(UNIT_RE, '', t or '')
            check(all(nu(c) == nu(h) for c, h in zip(cols, gh) if h and gh.count(h) == 1),
                  f"{key}: sheet '{names[gsheet[i] - 1]}' the header cells are the screen's headings ({[(c, h) for c, h in zip(cols, gh) if h and gh.count(h) == 1 and nu(c) != nu(h)][:3]})")
            tabs.append((re.search(r'<table [^>]*\bid="(\d+)"', tx) or [0, ''])[1] + '|' + (re.search(r'displayName="([^"]+)"', tx) or [0, ''])[1])
            # (X7) a column whose header names a unit the export added holds the screen's figure converted
            # into it, within the figure's shown precision; in a column of days or of a rate a cell the screen shows with no
            # number is empty
            if not card:
                off_, ncmp = [], 0
                for j, (c_, h_) in enumerate(zip(cols, g['head'])):
                    mu = re.search(r' \(([^()]+)\)$', c_ or '')
                    if not mu or (h_ or '').endswith(mu.group(0)) or not re.fullmatch(r'(?:B|KB|MB|GB|TB|PB)(?:/day)?|ms|s|min|days', mu.group(1)): continue
                    for k_, r_ in enumerate(g['cells']):
                        if j >= len(r_): continue
                        sid, v_, t_ = cells.get((k_ + 2, j), (0, None, None)); scr = r_[j]['t']
                        e_ = converted(mu.group(1), scr)
                        if e_ is None: continue
                        if e_ == 'none':
                            if (mu.group(1) == 'days' or mu.group(1).endswith('/day')) and (v_ is not None or t_): off_.append(f"{colname(j)}{k_ + 2} '{scr}' -> {v_ if v_ is not None else t_!r}, not empty")
                            continue
                        ncmp += 1
                        if e_ == 'over':
                            if v_ is None or v_ <= 3650: off_.append(f"{colname(j)}{k_ + 2} '{scr}' -> {v_}")
                        elif v_ is None or abs(v_ - e_[0]) > e_[1] + abs(e_[0]) * 1e-9: off_.append(f"{colname(j)}{k_ + 2} '{scr}' -> {v_} ({mu.group(1)}), want {e_[0]:.6g}")
                CONVERTED[0] += ncmp
                if ncmp or off_:
                    check(not off_, f"{key}: sheet '{names[gsheet[i] - 1]}' {ncmp} figure(s) in its unit-headed columns = the screen's, converted, within the shown precision ({off_[:3]})")
                # (X14) a percent column's share = the screen's figure / 100 within its shown precision: the file alone cannot
                # tell 13.4 % from 1,340 % (a query's +4,900 % is a real share of 49, a run at 15 times its average 15.0)
                poff, npct = [], 0
                for j, c_ in enumerate(cols):
                    if '%' not in (c_ or ''): continue
                    for k_, r_ in enumerate(g['cells']):
                        if j >= len(r_): continue
                        _sid, v_, _t = cells.get((k_ + 2, j), (0, None, None)); mp = re.fullmatch(r'\+?(-?[\d.,\s\u202f\u00a0]*\d)\s?%?', r_[j]['t'] or '')
                        if v_ is None or not mp: continue
                        e_, kd = digits_(mp.group(1))
                        if e_ is None: continue
                        npct += 1
                        if abs(v_ - e_ / 100) > 0.5 * 10 ** -kd / 100 + 1e-9: poff.append(f"{colname(j)}{k_ + 2} '{r_[j]['t']}' -> {v_}, want {e_ / 100:.6g}")
                if npct or poff:
                    check(not poff, f"{key}: sheet '{names[gsheet[i] - 1]}' {npct} share(s) in its percent columns = the screen's figure / 100, within the shown precision ({poff[:3]})")
                # (X13) the most decimals the screen shows in each column of this grid, for xlsx-check's page - a grid the
                # screen drew whole only (a long grid's rows past the drawn ones can show more: the writer reads them all)
                if len(g['cells']) == g['rows']:
                    dps_ = {}
                    for j, c_ in enumerate(cols):
                        ks_ = [k_ for k_ in (page_decimals(r_[j]['t']) for r_ in g['cells'] if j < len(r_)) if k_ is not None]
                        if ks_ and c_: dps_[c_] = max(ks_)
                    PAGE_DP.setdefault(p['xlsx'], {})[names[gsheet[i] - 1]] = dps_
            check(bool(m) and f'PartName="/xl/tables/{m.group(1)}" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"' in ct, f"{key}: sheet '{names[gsheet[i] - 1]}' its table part is in [Content_Types].xml")
        if key == 'summary' and g['rows'] > 1 and any(c['l'] and not c['s'] for r in g['cells'] for c in r):
            # (changed by X11: a link cell is DBA Dash's link column - F1F1F6 / 004F83, no underline, no hyperlink)
            lk = [cx[cells.get((k + 2, j), (0, None, None))[0]] for k, r in enumerate(g['cells']) for j, c in enumerate(r) if c['l'] and not c['s']]
            check(counts['link'] >= 1 and counts['plain'] >= 1 and all(q['fill'] == LINKFILL and q['font'] == LINK and not q.get('u') for q in lk),
                  f"summary: sheet '{names[gsheet[i] - 1]}' its link cells in DBA Dash's link pair F1F1F6 / 004F83, not underlined ({counts['link']} link cells; {counts['plain']} plain)")
            linked = True
        # (changed by C4 in the E2 answer: no colour is carried from a judging cell to a value cell; the file follows the
        # page, whose value cells the audit above holds to their own look: the rows 'carry' are gone)
        if key == 'storage' and 'free' in g['head'] and g['rows'] > 0:
            j = g['head'].index('free'); seen = [(number(r[j]['t']), cells.get((k + 2, j), (0, None, None))) for k, r in enumerate(g['cells']) if r[j]['t'] != '']
            off = [(a, b) for a, b in seen if a is None or b[1] is None or cx[b[0]]['fmt'] != 167 or abs(b[1] * 100 - a) > 0.006]
            check(len(seen) >= 1 and not off and 'numFmtId="167" formatCode="0.0%"' in st, f"storage: sheet '{names[gsheet[i] - 1]}' {len(seen)} 'free' cells, each the screen's percent / 100 under numFmt 167 '0.0%' (DBA Dash's) ({off[:2]})")
    check(len(set(tabs)) == len(tabs) and all(re.fullmatch(r'\d+\|Table\d+', t) for t in tabs), f"{key}: {len(tabs)} table(s), ids and names unique in the workbook")
    # (X12) the sheets that are no grid: one per row of tiles, one for the Needs attention lines, one per
    # chart that has numbers (not one whose numbers the page shows as a table), named by its title, in the charts' page order
    pl = p.get('pagelook') or {}
    if 'tileRows' in pl:
        drawn_ch = [c for c in pl.get('charts') or [] if c.get('nums') and not c.get('tbl')]
        want_x = pl['tileRows'] + (1 if pl.get('attention') else 0) + len(drawn_ch)
        at_ = []
        for c in drawn_ch:
            t_ = title_of(c.get('title') or '')
            at_.append(next((k for k in extra if t_ and (names[k - 1].startswith(t_[:24].rstrip()) or names[k - 1].endswith(' ' + t_[:20]) or named_by(names[k - 1], t_, None))), None))
        check(len(extra) == want_x and None not in at_ and at_ == sorted(at_),
              f"{key}: {len(extra)} section sheet(s) = {pl['tileRows']} tile row(s) + {1 if pl.get('attention') else 0} attention + {len(drawn_ch)} chart(s) with numbers; each chart's sheet named by its title in page order ({[(c.get('title'), k) for c, k in zip(drawn_ch, at_)]}; sections {[names[k - 1] for k in extra]})")
    else:
        print(f"not checked: {key}: the section sheets' count (the driver reads no tile rows)")
    # (X7-X9, the lead 13:44 (1)) an Item | Value | Status sheet's Value typed by its content: no bare number in the page's
    # locale left as text (a version - its Item names one - is no number)
    BARE = r'-?\d{1,3}(?:,\d{3})+(?:\.\d+)?|-?\d+(?:\.\d+)?' if want.startswith('en') else r'-?\d{1,3}(?:[\u202f\u00a0 ]\d{3})+(?:,\d+)?|-?\d+(?:,\d+)?'
    vt = []
    for k in extra + [k_ for k_ in gsheet if k_]:
        cv = cells_of(z.read(f'xl/worksheets/sheet{k}.xml').decode(), sst)
        if [cv.get((1, j), (0, None, None))[2] for j in range(3)] != ['Item', 'Value', 'Status']: continue
        for (r_, c_), (_, v_, t_) in cv.items():
            if r_ > 1 and c_ == 1 and v_ is None and t_ and re.fullmatch(BARE, t_) and not re.search(r'\bversion\b', cv.get((r_, 0), (0, None, ''))[2] or '', re.I): vt.append(f"{names[k - 1]}!B{r_} '{t_}'")
    check(not vt, f"{key}: no Value cell a bare number left as text (the lead 13:44 (1)) ({vt[:3]})")
    # (X7, the review's second pass) no bare number in the page's locale left as text on any grid or chart sheet: a count,
    # a figure the page rounds; a column headed 'version' and a text the writer keeps by design ('0042', '+5') aside
    gt = []
    for k in [k_ for k_ in gsheet if k_] + extra:
        cv = cells_of(z.read(f'xl/worksheets/sheet{k}.xml').decode(), sst); hd_ = {c_: t_ or '' for (r_, c_), (_, _, t_) in cv.items() if r_ == 1}
        if [hd_.get(j) for j in range(3)] == ['Item', 'Value', 'Status']: continue   # the Value row above
        for (r_, c_), (_, v_, t_) in cv.items():
            if r_ > 1 and v_ is None and t_ and re.fullmatch(BARE, t_) and not re.match(r'[+0]\d', t_) and 'version' not in hd_.get(c_, '').lower():
                gt.append(f"{names[k - 1]}!{colname(c_)}{r_} '{hd_.get(c_)}' '{t_}'")
    check(not gt, f"{key}: no bare number left as text on a grid or a chart's sheet ({len(gt)}: {gt[:3]})")
    # (the lead 13:44 (3)) each chart's sheet holds its first figures in the unit its axis draws: a series whose axis shows
    # a size or a duration names its unit, and its value is the axis's figure converted, within the shown precision
    if 'tileRows' in pl:
        cf_ = []; ncf = 0
        for c, k in zip(drawn_ch, at_):
            fi = c.get('first')
            if not fi or not k: continue
            cv = cells_of(z.read(f'xl/worksheets/sheet{k}.xml').decode(), sst); hd_ = {c_: t_ or '' for (r_, c_), (_, _, t_) in cv.items() if r_ == 1}
            for j, txt in enumerate(fi['texts']):
                if not txt or not re.search(r'\d\s?(?:B|KB|MB|GB|TB|PB|ms|s|min)$', norm_(txt)): continue
                mu = re.search(r' \(([^()]+)\)$', hd_.get(j, ''))
                v_ = cv.get((fi['i'] + 2, j), (0, None, None))[1]
                e_ = converted(mu.group(1), norm_(txt)) if mu else None
                ncf += 1
                if not mu: cf_.append(f"{names[k - 1]} '{hd_.get(j)}': no unit for '{txt}'")
                elif not isinstance(e_, tuple) or v_ is None or abs(v_ - e_[0]) > e_[1] + abs(e_[0]) * 1e-9: cf_.append(f"{names[k - 1]} '{hd_.get(j)}' {v_} for '{txt}'")
        if ncf or cf_:
            check(not cf_, f"{key}: {ncf} chart figure(s) in the unit their axis draws, named, converted within the shown precision ({cf_[:3]})")
    # (P1) one table on every grid sheet, no sheet filter and no _FilterDatabase anywhere
    for k in extra:
        ex = z.read(f'xl/worksheets/sheet{k}.xml').decode()
        check('<tableParts count="1">' in ex and '<pane' not in ex, f"{key}: section sheet '{names[k - 1]}' one Excel table, no pane (X5, X12)")
    check(len(tabs) == len(gs) and '_FilterDatabase' not in wbx, f"{key}: every grid sheet one Excel table (P1): {len(tabs)} table(s) for {len(gs)} grid(s), no _FilterDatabase")
    # (P3) a boolean the page holds: an Excel boolean on its grid sheet, the page's words on the page sheet; no grid column
    # holds both a boolean and the words yes / no / true / false (a boolean the export missed)
    nbool, mixed = 0, []
    for i, g in enumerate(gs):
        xg = z.read(f'xl/worksheets/sheet{gsheet[i]}.xml').decode(); cg = cells_of(xg, sst)
        bc = {colidx(c) for c in re.findall(r'<c r="([A-Z]+)\d+" s="\d+" t="b"', xg)}; nbool += len(re.findall(r' t="b"', xg))
        for j in bc:
            if any(r_ >= 2 and c_ == j and (tx_ or '') in ('yes', 'no', 'true', 'false', 'Yes', 'No') for (r_, c_), (_, _, tx_) in cg.items()): mixed.append(f"{names[gsheet[i] - 1]} {colname(j)}")
    check(not mixed and (nbool >= 1 or key != 'roles'), f"{key}: booleans (P3, X9): {nbool} Excel boolean cell(s) on the grid sheets; no column mixing a boolean with its words ({mixed[:3]})")
    # (P4, E2-11) no underlined cell without a hyperlink behind it, and no hyperlink leaving the workbook (the sheet jumps
    # are location links; a link to the app's own routes keeps its colour, not its underline)
    ulb, ext = [], [n for n in z.namelist() if n.endswith('.rels') and 'TargetMode="External"' in z.read(n).decode()]
    for i in range(len(names)):
        xs = z.read(f'xl/worksheets/sheet{i + 1}.xml').decode(); hl = set(re.findall(r'<hyperlink ref="([A-Z]+\d+)"', xs))
        if re.search(r'<hyperlink [^>]*r:id=', xs): ext.append(names[i])
        for m in re.finditer(r'<c r="([A-Z]+\d+)" s="(\d+)"(?: t="(\w+)")?(?:/>|>(.*?)</c>)', xs, re.S):
            sid = int(m.group(2)); body = m.group(4) or ''
            if body and ((sid < len(cx) and cx[sid].get('u')) or '<u/>' in body) and m.group(1) not in hl: ulb.append(f"{names[i]}!{m.group(1)}")
    check(not ulb and not ext, f"{key}: no underlined cell without a hyperlink, no hyperlink leaving the workbook (P4, E2-11) ({len(ulb)} underlined without one {ulb[:3]}; leaving {ext[:3]})")
    # (P5) a sheet's name is the grid's own title: no read time in it
    p5 = [n for n in names if re.search(r'\(read |\b\d{1,2} \d{1,2} \d{4}\b', n)]
    check(not p5, f"{key}: sheet names without a read time (P5) ({p5[:3]})")
    if key == 'summary':
        check(linked, "summary: a grid with link cells (the instance names) was graded for the link's look and the plain cells'")
        # (changed by X2: the fleet Summary's two grids are 'Test Summary' and 'Instance Summary' on every route)
        check('Test Summary' in names and 'Instance Summary' in names and not any(re.search(r' \(\d+\)$', n_) for n_ in names), f"summary: the two grids named 'Test Summary' and 'Instance Summary', no numbered repeat ({names})")
    if key == 'backups': check(any('archiver' in g['head'] for g in gs), "backups: the fleet grid with the 'archiver' column is on the page")
    if key == 'jobs': check(any('last run' in g['head'] for g in gs), "jobs: the fleet grid with the 'last run' column is on the page")
    if key == 'storage': check(any('free' in g['head'] for g in gs), "storage: the fleet grid with the 'free' column is on the page")
    if key in ('drives', 'dbspace', 'dbfiles'):
        # a backstop: a page with no grid fails in the driver first (the export finds nothing, press() names the page)
        check(len(gs) >= 1 and sum(g['rows'] for g in gs) >= 1, f"{key}: the Storage folder's page shows {len(gs)} grid(s), {sum(g['rows'] for g in gs)} rows")
        sel = (p.get('state') or {}).get('selects') or []
        if key == 'drives': check('drv-status=all' in sel and p['state'].get('metrics') == 'true', f"drives: drawn as its metrics grid with every status ({p.get('state')})")
        if key == 'dbfiles': check('files-status=all' in sel, f"dbfiles: drawn with every status ({p.get('state')})")
        if key == 'dbspace':
            # the GB columns are numbers in the workbook (the page shows the GB figure with one decimal, fmtGB); a used cell
            # left as text is only 'not read' (a PostgreSQL instance)
            sx = z.read(f'xl/worksheets/sheet{gsheet[0]}.xml').decode(); g0 = gs[0]
            check(g0['head'][1:3] == ['allocated (GB)', 'used (GB)'], f"dbspace: the grid's columns 2 and 3 are allocated (GB) and used (GB) ({g0['head'][:4]})")
            alloc = [k for r, k in re.findall(r'<c r="B(\d+)"[^>]*?(/>|><v>|t="inlineStr")', sx) if r != '1']
            check(len(alloc) == g0['rows'] and sum(k == '><v>' for k in alloc) >= 1 and not any(k == 't="inlineStr"' for k in alloc), f"dbspace: allocated (GB) numeric in {sum(k == '><v>' for k in alloc)} of {g0['rows']} rows, none as text")
            used_text = re.findall(r'<c r="C(\d+)"[^>]*t="inlineStr"><is><t[^>]*>([^<]*)</t>', sx)
            used_num = [r for r, k in re.findall(r'<c r="C(\d+)"[^>]*?(/>|><v>|t="inlineStr")', sx) if r != '1' and k == '><v>']
            check(len(used_num) >= 1 and all(t in ('not read', '') for r, t in used_text if r != '1'), f"dbspace: used (GB) numeric in {len(used_num)} rows, its text cells only 'not read' ({sorted({t for r, t in used_text if r != '1'})[:3]})")
            dbs_onedec('dbspace', g0, cells_of(sx, shared(z)), cx)
    if key == 'dbspace_i':
        # an instance's DB Space grid reads as DBA Dash's ('Unit: GB, Decimal Places: 1') and as the fleet grid: allocated,
        # used, data and log hold the GB figure, headed '(GB)' on the page and in the workbook, numbers in the
        # workbook (this is the SQL Server instance: no text cell). Its names are its own (dsi_): the grader's
        # module-level names (want: the language) are read further on
        dsi_g = gs[0]; dsi_c = cells_of(z.read(f'xl/worksheets/sheet{gsheet[0]}.xml').decode(), shared(z))
        dsi_cols = sorted({c for r, c in dsi_c}); dsi_hdr = [(dsi_c.get((1, c)) or (0, None, None))[2] for c in dsi_cols]
        dsi_want = ['allocated (GB)', 'used (GB)', 'data (GB)', 'log (GB)']
        check(dsi_g['head'][1:5] == dsi_want and dsi_hdr[1:5] == dsi_want, f"dbspace_i: the instance grid's columns 2-5 are {dsi_want}: page {dsi_g['head'][1:5]}, workbook {dsi_hdr[1:5]}")
        dsi_rows = sorted({r for r, c in dsi_c if r > 1})
        # each column: a number in every row (used: a number or blank - a SQL Server instance's unread used is blank), no
        # text, each a tenth (the GB figure rounded to 0.1, not bytes under a '(GB)' heading), each the screen cell's number
        for dsi_j, dsi_w in enumerate(dsi_want, 1):
            if dsi_j >= len(dsi_cols): break
            dsi_v = [(dsi_c.get((r, dsi_cols[dsi_j])) or (0, None, None)) for r in dsi_rows]
            dsi_scr = [(row[dsi_j]['t'] if dsi_j < len(row) else '') for row in dsi_g.get('cells') or []]
            dsi_nums = [v for _, v, _ in dsi_v if v is not None]
            dsi_texts = sorted({t for _, v, t in dsi_v if v is None and t})
            dsi_odd = [v for v in dsi_nums if abs(v * 10 - round(v * 10)) >= 1e-9]
            dsi_diff = [(s_, v) for (_, v, _), s_ in zip(dsi_v, dsi_scr) if not ((v is None and not s_) or (v is not None and s_ and number(s_) is not None and abs(number(s_) - v) < 1e-9))]
            dsi_full = len(dsi_nums) >= 1 if dsi_w == 'used (GB)' else len(dsi_nums) == len(dsi_rows)
            check(len(dsi_rows) == dsi_g['rows'] == len(dsi_scr) and dsi_full and not dsi_texts and not dsi_odd and not dsi_diff,
                  f"dbspace_i: '{dsi_w}' a number in {len(dsi_nums)} of {len(dsi_rows)} rows (page {dsi_g['rows']}, screen read {len(dsi_scr)}), text cells {dsi_texts[:3]}, not a tenth {dsi_odd[:3]}, off the screen {dsi_diff[:3]}")
        dbs_onedec('dbspace_i', dsi_g, dsi_c, cx)
    if key == 'dbspace_p':
        # a PostgreSQL instance's DB Space grid: allocated (GB) and used (GB) only - no data / log column (a PostgreSQL
        # database has no files of its own to size) - on the page and in the workbook; allocated a number in every row,
        # rounded to 0.1, the screen's; used 'not read' in every row (the page and the workbook). Its names are its own (dsp_)
        dsp_g = gs[0]; dsp_c = cells_of(z.read(f'xl/worksheets/sheet{gsheet[0]}.xml').decode(), shared(z))
        dsp_cols = sorted({c for r, c in dsp_c}); dsp_hdr = [(dsp_c.get((1, c)) or (0, None, None))[2] for c in dsp_cols]
        dsp_want = ['allocated (GB)', 'used (GB)']
        dsp_extra = [h for h in list(dsp_g['head']) + dsp_hdr if h and h.split(' ')[0] in ('data', 'log')]
        check(dsp_g['head'][1:3] == dsp_want and dsp_hdr[1:3] == dsp_want and not dsp_extra, f"dbspace_p: the PostgreSQL instance grid's columns 2-3 are {dsp_want} and no data / log column: page {dsp_g['head']}, workbook {dsp_hdr}")
        dsp_rows = sorted({r for r, c in dsp_c if r > 1}); dsp_scr = [row for row in dsp_g.get('cells') or []]
        if len(dsp_cols) > 2:
            dsp_a = [(dsp_c.get((r, dsp_cols[1])) or (0, None, None)) for r in dsp_rows]
            dsp_as = [(row[1]['t'] if len(row) > 1 else '') for row in dsp_scr]
            dsp_bad = [(t_, v) for (_, v, _), t_ in zip(dsp_a, dsp_as) if v is None or abs(v * 10 - round(v * 10)) >= 1e-9 or number(t_) is None or abs(number(t_) - v) >= 1e-9]
            check(len(dsp_rows) == dsp_g['rows'] == len(dsp_scr) and not dsp_bad, f"dbspace_p: 'allocated (GB)' a number rounded to 0.1, the screen's, in every row ({len(dsp_rows)} rows, page {dsp_g['rows']}, screen read {len(dsp_scr)}; off {dsp_bad[:3]})")
            dsp_u = [(dsp_c.get((r, dsp_cols[2])) or (0, None, None))[2] for r in dsp_rows]
            dsp_us = [(row[2]['t'] if len(row) > 2 else '') for row in dsp_scr]
            check(dsp_u and all(t_ == 'not read' for t_ in dsp_u + dsp_us), f"dbspace_p: 'used (GB)' 'not read' in every row (workbook {sorted(set(map(str, dsp_u)))[:3]}, screen {sorted(set(dsp_us))[:3]})")
        dbs_onedec('dbspace_p', dsp_g, dsp_c, cx)
    if key == 'perf':
        hg = [(i, g) for i, g in enumerate(gs) if 'CPU histogram' in g['head'] and g['rows'] > 0]
        if hg:
            i, g0 = hg[0]; j = g0['head'].index('CPU histogram'); px_ = sheet_rows(z, gsheet[i])[0]; cc = cells_of(px_, sst)
            filled = [k for k in range(len(g0['cells'])) if cx[cc.get((k + 2, j), (0, None, None))[0]]['fill'] is not None]
        check(bool(hg) and p.get('pictures', 0) >= 1 and not filled, f"perf: the CPU histogram column has no fill in any of its rows, {p.get('pictures')} of them holding the picture (a picture, no status; {len(filled) if hg else 'no grid'} filled)")
    if key == 'empty':
        tg = [g for g in gs if not g.get('empty')]   # the Table Size tab's grids with a table: the filtered one is the last
        check(tg[-1]['rows'] == 0 and len(tg) > 1 and tg[0]['rows'] > 0, f"empty: the last grid is filtered to no rows, the first keeps its rows ({[g['rows'] for g in gs]})")
        # (changed by X0: a bare class is read as its status (export.ts statusOf) and the cell takes the named pair - as
        # the screen read marks it; the audit above held both cells to that)
        x0 = z.read(f'xl/worksheets/sheet{gsheet[0]}.xml').decode(); c0 = cells_of(x0, sst)
        two = [cx[c0.get((2, j), (0, None, None))[0]] for j in (1, 2)]
        rest = [cx[c0.get((k + 3, j), (0, None, None))[0]]['fill'] for k in range(tg[0]['rows'] - 1) for j in (1, 2)]
        check(classed == 2 * tg[0]['rows'] and [q['fill'] for q in two] == [fill['crit'], fill['warn']] and all(f == fill['ok'] for f in rest),
              f"empty: the two columns given a bare class (crit, warn on the first row, ok on the {tg[0]['rows'] - 1} others) take their named pairs (X0 ({classed} cells, {[q['fill'] for q in two]}, {len(rest)} ok cells: {sorted(set(map(str, rest)))})")
    if openpyxl is not None:
        try:
            wb = openpyxl.load_workbook(f"{dl}/{p['xlsx']}")
            check(wb.sheetnames == names and sum(len(ws.tables) for ws in wb.worksheets) == len(names) - 1, f"{key}: openpyxl {openpyxl.__version__} opens the workbook: {len(wb.sheetnames)} sheets, a table on each but 'About'")
        except Exception as e:
            check(False, f"{key}: openpyxl could not open {p['xlsx']}: {type(e).__name__}: {e}")
    for i, g in enumerate(gs):
        x, n = sheet_rows(z, gsheet[i])
        # (changed by E2-4' / E2-5': a status the screen shows is no longer written as DBA Dash's solid fill in a plain
        # font whatever the page draws; its cells take the page's look - a solid status cell its fill, a badge its tint,
        # a pill the page draws bold in bold - which the audit above holds cell by cell. What stays: each status the
        # screen shows is on the sheet in some cell of that status's look on the page)
        # (changed by X0: each status the screen shows is on the sheet as its named pair)
        for s_ in g.get('status', []):
            used = {int(v) for v in re.findall(r' s="(\d+)"', x)}
            check(s_ in fill and any(u < len(cx) and cx[u]['fill'] == fill[s_] and cx[u]['font'] == font[s_] for u in used), f"{key}: '{s_}' cells in '{names[gsheet[i] - 1]}' in its named pair {fill.get(s_)} / {font.get(s_)} (X0)")
        row1 = re.search(r'<row r="1"[^>]*>(.*?)</row>', x, re.S)
        hs1 = {int(v) for v in re.findall(r' s="(\d+)"', row1.group(1))} if row1 else set()
        # (changed by E2-4': the header row in the page's own th look - 004F83, white, the page's weight - not DBA Dash's
        # 0063A3 bold; wrapped as the page wraps a header)
        # (changed by X4: the header row is DBA Dash's - FF0063A3, white, bold - not the page's th look)
        check(bool(hs1) and all(u < len(cx) and cx[u]['fill'] == 'FF0063A3' and cx[u]['font'] == 'FFFFFFFF' and cx[u]['bold'] for u in hs1),
              f"{key}: sheet '{names[gsheet[i] - 1]}' header row FF0063A3, white, bold (X4) ({sorted({(cx[u]['fill'], cx[u]['font'], cx[u]['bold']) for u in hs1 if u < len(cx)})})")
    # each sheet named by the heading above its grid (h2 to h5, or the name the page gives it: data-sheet): the name starts
    # with the heading's first words (cut at 31 characters)
    # (the export's rule: a character Excel refuses becomes a space, then each run of spaces one space)
    # (changed by P5, the lead 22:34: a time the heading carries in brackets is left out of the sheet's name)
    # (changed by X2: a time after a word too; never a numbered repeat - two headings equal after the cut keep their start,
    # '…' and the words where they part; a name taken in full goes under the heading above it: export_names.ts)
    # (changed: the export's own time shapes only, a data-sheet's name kept whole or before its own
    # heading, a name under the heading above it - the page-level title_of / name_of / named_by above)
    full = [name_of(g) for g in gs]
    gn = [names[k - 1] for k in gsheet]
    check(all(named_by(n, f, g.get('up')) or (key == 'summary' and n in ('Test Summary', 'Instance Summary')) for n, f, g in zip(gn, full, gs)) and not any(re.search(r' \(\d+\)$', n) for n in names),
          f"{key}: grid sheet names {gn} follow the screen's headings {[g['name'] for g in gs]}, none a numbered repeat (X2)")
    if key == 'roles':
        check(any(g['name'].endswith('privileges') or 'privileges' in g['name'] for g in gs), "roles: a grid under a privileges (h4) heading on screen")
        check('Roles tiles' in names and 'Roles' in names, f"roles: the tiles 'Roles tiles' and the grid 'Roles' ({names})")
    if key == 'sqljobs':
        js_ = [(g['named'], names[k - 1]) for g, k in zip(gs, gsheet) if g.get('own') == 'alone']
        if not js_: print(f"not checked: sqljobs: no job step grid on the page (the demo's jobs carry no steps; decision (b)'s names: the unit tests and the same-data run on a real server) - sheets {names}")
        else: check(not any(re.search(r' \(\d+\)$', n_) for n_ in names) and all(n_ == clean_(j_)[:31].rstrip(" '") or named_by(n_, clean_(j_), None) for j_, n_ in js_),
              f"sqljobs: {len(js_)} job step grid(s), each sheet named by its job (data-sheet), no numbered repeat ({js_[:4]})")
    if key == 'tables':
        check(gn == [g['name'] for g in gs], f"tables: grid sheet names {gn} = the screen's headings {[g['name'] for g in gs]}")
        x = ''.join(z.read(f'xl/worksheets/sheet{gsheet[i]}.xml').decode() for i in range(len(gs)))
        nums = {int(s) for s in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>', x)}
        for f, what in ((168, "a time, DBA Dash's 'yyyy-MM-dd HH:mm'"), (0, "a count, General as DBA Dash writes one")):
            check(any(cx[s]['fmt'] == f for s in nums), f"tables: a numeric cell with numFmt {f} ({what})")
        # (changed by X7: a size column is ONE unit, in its header, the cells plain numbers; no '#,##0\" B\"' format)
        units = [h for h in re.findall(r'<tableColumn id="\d+" name="([^"]*)"', ''.join(z.read(n).decode() for n in z.namelist() if n.startswith('xl/tables/'))) if re.search(r' \((?:B|KB|MB|GB|TB|PB)\)$', h)]
        check('numFmtId="168" formatCode="yyyy-MM-dd HH:mm"' in st and 'B&quot;' not in st and 'formatCode="#,##0"' not in st and 'formatCode="#,##0.00"' not in st and len(units) >= 1,
              f"tables: a size column in one unit with the unit in its header ({units[:3]}); numFmt 168 'yyyy-MM-dd HH:mm'; no custom size format, no '#,##0' (X7)")
        last = z.read(f'xl/worksheets/sheet{gsheet[-1]}.xml').decode()
        col = re.findall(r'<c r="D(\d+)"[^>]*t="inlineStr"><is><t xml:space="preserve">([^<]*)</t>', last)
        got = [t.replace('&amp;', '&').replace('&lt;', '<').replace('&gt;', '>').replace('&quot;', '"') for r, t in col if r != '1']
        check(p['order'] != p['before'], "tables: the click changed the grid's order on screen")
        check(p['order'] and got == p['order'], f"tables: 'Biggest tables' sorted by total on screen, the sheet's table column in the same order ({len(got)} rows)")
        # the raw values must follow the sort too: a model out of step pairs a row's text with another row's value,
        # and the cell falls back to text; every 'total' (E, bytes) and 'live rows' (I, counts in the millions: the
        # locale's grouping) of the sorted sheet stays a number
        for c, what in (('E', 'total'), ('I', 'live rows')):
            cells = re.findall(r'<c r="' + c + r'(\d+)"[^>]*?(/>|><v>|t="inlineStr")', last)
            numeric = [r for r, k in cells if r != '1' and k == '><v>']
            check(len(got) > 1 and len(numeric) == len(got), f"tables: the sorted sheet's {what} column: {len(numeric)} of {len(got)} rows numeric")
    if key == 'summary':
        check(any(cx[s]['fill'] in fill.values() for s in range(len(cx))), "summary: a status fill in styles.xml")
    # (changed by D-B: the page sheet with pictures is parked - its rows (title, window, the page's text, tiles as cards, the
    # Needs attention lines, pictures) are not graded; X12: each of those is a section sheet; D-A: 'About' last)
    ab = cells_of(z.read(f'xl/worksheets/sheet{len(names)}.xml').decode(), sst)
    items = [ab.get((r_, 0), (0, None, None))[2] for r_ in range(2, max([r_ for r_, _ in ab] + [1]) + 1)]
    check(items[:8] == ['Instance', 'Tab', 'Window', 'Window from', 'Window to', 'Exported at', 'Time zone', 'Source'] and all(f'Sheet {n_}' in items for n_ in names[:-1]),
          f"{key}: 'About' (D-A) - Instance, Tab, Window, from, to, Exported at, Time zone, Source, then every sheet's rows ({items[:10]}; missing {[n_ for n_ in names[:-1] if f'Sheet {n_}' not in items][:3]})")
    tz_ = next((ab.get((r_, 1), (0, None, None))[2] for (r_, c_), (_, _, t_) in ab.items() if c_ == 0 and t_ == 'Time zone'), None)
    check(bool(tz_) and re.search(r'\S \(UTC[+-]\d{2}:\d{2} at export\)', tz_ or '') is not None, f"{key}: 'About' Time zone reads '<zone> (UTC+hh:mm at export)' ({tz_!r})")
    core = z.read('docProps/core.xml').decode() if 'docProps/core.xml' in z.namelist() else ''
    check('<dc:title>' in core and '<dc:description>' in core and 'core-properties' in z.read('_rels/.rels').decode(), f"{key}: the document's properties hold the export's facts (D-A)")
    if pl.get('tiles'):
        allt = set()
        for k in extra:
            allt |= {t_ for (r_, c_), (_, _, t_) in cells_of(z.read(f'xl/worksheets/sheet{k}.xml').decode(), sst).items() if c_ == 0 and r_ > 1}
        lab = [t.get('label') or t.get('l') for t in pl['tiles']]
        miss = [l_ for l_ in lab if l_ and l_ not in allt]
        check(not miss, f"{key}: the page's {len(lab)} tiles are rows of an Item | Value | Status sheet (X12) (missing {miss[:3]})")
    # (the Summary's guard back - its strip read at all; every line, also past the 8 the page draws)
    if pl.get('attention') or (key == 'summary' and 'attention' in pl):
        an = [n_ for n_ in names if n_.startswith('Needs attention')]
        rows_ = cells_of(z.read(f'xl/worksheets/sheet{names.index(an[0]) + 1}.xml').decode(), sst) if an else {}
        got = {t_ for (r_, c_), (_, _, t_) in rows_.items() if c_ == 0 and r_ > 1}
        miss = [a_['name'] for a_ in pl['attention'] if a_.get('name') not in got]
        total_ = pl.get('attentionTotal', len(pl['attention']))
        check(bool(an) and not miss and len(got) == total_, f"{key}: the page's {total_} Needs attention line(s) on the sheet 'Needs attention', a row each, also past the 8 drawn (X12) ({len(got)} rows; missing {miss[:3]})")
    if key == 'activity':
        i = next((i for i, g in enumerate(gs) if g['name'] == 'Per sample'), None)
        check(i is not None and gs[i]['rows'] == 500, f"activity: the Per sample grid shows 500 rows on screen ({gs[i]['rows'] if i is not None else 'no grid'})")
        nl = next((t for (r_, c_), (_, _, t) in ab.items() if c_ == 1 and re.search(r'newest 500 of [\d,.\s\u202f\u00a0]*\d', str(t))), None)
        check(nl is not None, f"activity: 'About' carries the page's 'the newest 500 of N' line beside its grid's rows ({str(nl)[:60] if nl else 'none'})")
    if key == 'slow':
        i = next((i for i, g in enumerate(gs) if g['name'].startswith('Per day')), None)
        check(i is not None and gs[i]['rows'] >= 1, f"slow: a Per day table with rows on screen ({gs[i]['rows'] if i is not None else 'no grid'})")
        if i is not None:
            x = z.read(f'xl/worksheets/sheet{gsheet[i]}.xml').decode()
            cnt = re.findall(r'<c r="C(\d+)"[^>]*?(/>|><v>|t="inlineStr")', x)
            numeric = [r for r, k in cnt if r != '1' and k == '><v>']
            check(len(numeric) == gs[i]['rows'], f"slow: Per day's statements column (no page model): {len(numeric)} of {gs[i]['rows']} rows numeric")
            # (the lead 13:44 (4)) its day column dates under 'yyyy-MM-dd' (numFmt 169), never a false 00:00
            dc_ = cells_of(x, sst); days_ = [dc_.get((r_, 0)) for r_ in range(2, gs[i]['rows'] + 2)]
            check(all(v and v[1] is not None and FMT_CODES.get(cx[v[0]]['fmt']) == 'yyyy-MM-dd' for v in days_), f"slow: Per day's day column {len(days_)} dates under 'yyyy-MM-dd' ({[(v[1], cx[v[0]]['fmt']) if v else None for v in days_][:2]})")
    # (changed, X7: any number with a unit - a size, a duration, a rate, a count of days - is never
    # left as text on a grid sheet or a chart's series sheet, whichever tab's formatter wrote it; the mixed list by column)
    allx = ''.join(z.read(f'xl/worksheets/sheet{gsheet[j]}.xml').decode() for j in range(len(gs)))
    texts = []
    for k in [k_ for k_ in gsheet if k_] + extra:
        cv = cells_of(z.read(f'xl/worksheets/sheet{k}.xml').decode(), sst); hd_ = {c_: t_ for (r_, c_), (_, _, t_) in cv.items() if r_ == 1}
        if [hd_.get(j) for j in range(3)] == ['Item', 'Value', 'Status']: continue   # a Value with a unit stays the page's words (13:44 (1))
        colt = {}
        for (r_, c_), (_, v_, t_) in cv.items():
            if r_ > 1 and v_ is None and t_: colt.setdefault(c_, []).append(t_)
        for c_, ts in colt.items():
            h_ = hd_.get(c_) or ''
            if names[k - 1] == 'Instance Summary' and h_ in AGES: continue
            if h_ == 'growth' and any(re.fullmatch(r'\d+(?:[.,]\d+)? ?%', t_) for t_ in ts): continue   # a Files growth column holding a percent
            texts += [f"{names[k - 1]} '{h_}' '{t_}'" for t_ in ts if UNIT_TEXT.fullmatch(t_.strip())]
    check(not texts, f"{key}: no number with a unit left as text on a grid or a chart's sheet (X7) ({texts[:3]})")
    if key in ('slow', 'db'):
        nums = {int(s) for s in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>', allx)}
        # (changed by X7: a duration column holds plain numbers in one unit named in its header; no custom format)
        tu = [h for h in re.findall(r'<tableColumn id="\d+" name="([^"]*)"', ''.join(z.read(n).decode() for n in z.namelist() if n.startswith('xl/tables/'))) if re.search(r' \((?:ms|s|min)\)$', h)]
        check(len(tu) >= 1 and 'ms&quot;' not in st and 's&quot;' not in st, f"{key}: a duration column in one unit named in its header ({tu[:3]}), no custom duration format (X7)")
    if key == 'db':
        # (changed by X7: the statements' durations are plain numbers under General, two at least and not all equal; no
        # numFmt 170 any more) (changed: the duration columns only, by their headers' unit)
        vals, wrong_ = [], []
        for k in [k_ for k_ in gsheet if k_]:
            cv = cells_of(z.read(f'xl/worksheets/sheet{k}.xml').decode(), sst)
            dc = {c_ for (r_, c_), (_, _, t_) in cv.items() if r_ == 1 and re.search(r' \((?:ms|s|min)\)$', t_ or '')}
            for (r_, c_), (sid, v_, t_) in cv.items():
                if r_ > 1 and c_ in dc and (v_ is not None or t_):
                    if v_ is None or not (cx[sid]['fmt'] == 0 or re.fullmatch(r'0(?:\.0+)?', FMT_CODES.get(cx[sid]['fmt'], ''))): wrong_.append(f"{names[k - 1]}!{colname(c_)}{r_} {t_!r}")
                    else: vals.append(v_)
        # (changed by X13: a duration with decimals is under the decimals its column shows on the screen, '0.00', not General)
        check(len(vals) >= 2 and min(vals) < max(vals) and not wrong_, f"db: the statements' durations are numbers under General or their column's decimals (X7, X13) ({len(vals)} cells in the ' (ms)' / ' (s)' / ' (min)' columns, min {min(vals) if vals else '-'}, max {max(vals) if vals else '-'}; not a number {wrong_[:3]})")
    # CSV
    if p['csv'].endswith('.csv.zip'):
        cz = zipfile.ZipFile(f"{dl}/{p['csv']}")
        parts = sorted(cz.namelist())
        check(len(parts) == len(gs), f"{key}: {len(parts)} CSV(s) in {p['csv']} = {len(gs)} grid(s)")
        blobs = [cz.read(n) for n in parts]
        # each CSV named by its grid's sheet in the workbook: the same names, no numbered repeat
        check([n_[3:-4] for n_ in parts] == [safe_(names[k - 1]) for k in gsheet], f"{key}: the CSVs named by their grids' sheet names ({[n_[3:-4] for n_ in parts][:4]} | {[safe_(names[k - 1]) for k in gsheet][:4]})")
    else:
        check(len(gs) == 1, f"{key}: one grid, one .csv")
        blobs = [open(f"{dl}/{p['csv']}", 'rb').read()]
    check(stamp(p['csv'], inst, tab, '.csv.zip' if p['csv'].endswith('.zip') else '.csv'), f"{key}: the CSV's name {p['csv']}")
    for b, g in zip(blobs, gs):
        check(b.startswith(b'\xef\xbb\xbf'), f"{key}: CSV '{g['name']}' starts with a UTF-8 BOM")
        n = len(list(csv.reader(io.StringIO(b.decode('utf-8-sig'))))) - 1
        check(n == g['rows'], f"{key}: CSV '{g['name']}' {n} data rows = {g['rows']} on screen")
        if key == 'storage' and 'free' in g['head'] and g['rows'] > 0:
            # the CSV keeps the percent figure the screen shows (12.5), not the share the workbook's percent format holds (0.125)
            recs = list(csv.reader(io.StringIO(b.decode('utf-8-sig')))); j = recs[0].index('free')
            pairs = [(number(r[g['head'].index('free')]['t']), recs[k + 1][j]) for k, r in enumerate(g['cells']) if r[g['head'].index('free')]['t'] != '']
            check(len(pairs) >= 1 and all(a is not None and abs(float(v) - a) < 1e-6 for a, v in pairs), f"storage: CSV '{g['name']}' {len(pairs)} 'free' values are the screen's percent figures ({pairs[:2]})")

check(CONVERTED[0] >= 20, f"units: {CONVERTED[0]} figures in unit-headed columns compared with the screen across the pages (at least 20)")
# converted()'s self-test: a figure in another unit, a rate, an fmtSecs pair, a badge's days, a cell with no number, a wrong value off
_cv = [converted('GB', '93.9 GB'), converted('MB/day', '3.0 GB / day'), converted('s', '1m 5s'), converted('days', 'off (0 days)'), converted('days', 'never'), converted('GB', '12 ms')]
check(abs(_cv[0][0] - 93.9) < 1e-9 and abs(_cv[1][0] - 3072) < 1e-9 and _cv[1][1] > 51 and abs(_cv[2][0] - 65.5) < 1e-9 and _cv[3][0] == 0 and _cv[4] == 'none' and _cv[5] is None
      and abs(93.9 * 1.01 - _cv[0][0]) > _cv[0][1], f"units: self-test - converted() reads a size, a rate, an fmtSecs pair, a badge's days, no number, another family; a value 1 % off is off ({_cv})")
# (X13) no number cell shows more decimals than its column on the screen: the screen's decimals per grid column (and per
# chart series with a unit) handed to scripts/xlsx-check.py rules --page; every page's workbook judged, none over
_dp = [page_decimals(x) for x in ('1.6 GB', '336.0 MB', '7 B', '-2.0 GB / day', '1m 5s', '233.3 days', 'off (0 days)', '17.35', 'never', '10/3/2026, 21:05:00', '16.0.4325.4')]
_dp += [page_decimals('12.35 ms' if want.startswith('en') else '12,35 ms'), page_decimals('1,234' if want.startswith('en') else '1\u202f234'), page_decimals('12.5 %' if want.startswith('en') else '12,5 %')]
_dp += [page_decimals('1.536 MB')]   # no fmtBytes form (three decimals past 1024's reach): the language's number - en-US 3, fr-FR 3 (de-DE's grouping is not a proof language)
check(_dp == [1, 1, 0, 1, None, 1, 0, 2, None, None, None, 2, 0, 1, 3], f"decimals: self-test - page_decimals() reads a size, a rate, days, a badge, a bare number, the language's decimal mark and grouping; words, a time, a version and fmtSecs's whole units are no figure ({_dp})")
_pg = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), f'page-{want}.json')
json.dump(PAGE_DP, open(_pg, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
if os.environ.get('PGVIGIL_EXPORT_OUT') and os.path.isdir(os.path.join(os.environ['PGVIGIL_EXPORT_OUT'], want)):   # kept beside the downloads
    json.dump(PAGE_DP, open(os.path.join(os.environ['PGVIGIL_EXPORT_OUT'], want, os.path.basename(_pg)), 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
_books = [f"{dl}/{n}" for n in PAGE_DP]
_r = subprocess.run([sys.executable, '-I', 'scripts/xlsx-check.py', 'rules', '--page', _pg] + _books, capture_output=True, text=True)
_l13 = [l for l in _r.stdout.splitlines() if ' X13 ' in l]
_pass = [l for l in _l13 if l.startswith('PASS X13 ')]; _fail = [l for l in _l13 if not l.startswith('PASS X13 ')]
_cells = sum(int(m_.group(1)) for m_ in (re.search(r': (\d+) number cells', l) for l in _pass) if m_)
_cols = sum(int(m_.group(1)) for m_ in (re.search(r', (\d+) with decimals', l) for l in _pass) if m_)   # columns judged whose screen shows decimals
check(len(_books) >= len(PAGES) - 1 and len(_pass) == len(_books) and not _fail and _cells >= 50 and _cols >= 3,
      f"decimals (X13): no number cell shows more decimals than its column on the screen, none under a fixed format fewer - {len(_pass)} of {len(_books)} page workbooks PASS, {_cells} number cells judged, {_cols} columns whose screen shows decimals; page in {os.path.basename(_pg)} ({[l[:300].replace(dl + '/', '') for l in _fail][:4]}{(' rc ' + str(_r.returncode) + ' ' + _r.stderr[-200:]) if _r.returncode not in (0, 1) else ''})")
# (X17) the measured cell carries its row's status, as DBA Dash colours it: the map from the workbooks' own headers - a
# 'Drives' sheet's free % (its status column's colour) and free in a size unit (N/A: no size threshold), a job grid's job
# and last failure (its status) and the time since (any status) - handed to scripts/xlsx-check.py rules --measured; the
# Drives sheet and a job grid found, every mapped workbook PASS
import importlib.util
_xs = importlib.util.spec_from_file_location('xlsx_check', 'scripts/xlsx-check.py'); _xc = importlib.util.module_from_spec(_xs); _xs.loader.exec_module(_xc)
MEASURED = {}
_n17 = {}   # (file, sheet) -> [data rows, the mapped columns' cells that hold a value]: what X17 can judge on each sheet
for _n in sorted(os.listdir(dl)):
    if not _n.endswith('.xlsx'): continue
    try: _bk = _xc.Book(f"{dl}/{_n}")
    except Exception: continue
    for _s in _bk.sheets:
        if not _s['grid']: continue
        _h = [str(c['v'] if c['v'] is not None else '').strip() for c in _s['cells'] if c['row'] == 1]
        _m = {}
        if _s['name'] == 'Drives' and 'free %' in _h and 'status' in _h:
            _m['free %'] = 'status'
            _m.update({h: 'N/A' for h in _h if re.fullmatch(r'free \((?:B|KB|MB|GB|TB|PB)\)', h)})
        if {'job', 'status', 'last failure'} <= set(_h):
            _m.update({'job': 'status', 'last failure': 'status'})
            if 'since last failure (minutes)' in _h: _m['since last failure (minutes)'] = '*'
        if _m:
            MEASURED.setdefault(_n, {})[_s['name']] = _m
            _mc = {c['col'] for c in _s['cells'] if c['row'] == 1 and str(c['v'] if c['v'] is not None else '').strip() in _m}
            _n17[(_n, _s['name'])] = [len({c['row'] for c in _s['cells'] if c['row'] > 1}),
                                      sum(1 for c in _s['cells'] if c['row'] > 1 and c['col'] in _mc and str(c['v'] if c['v'] is not None else '').strip())]
_mg = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), f'measured-{want}.json')
json.dump(MEASURED, open(_mg, 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
if os.environ.get('PGVIGIL_EXPORT_OUT') and os.path.isdir(os.path.join(os.environ['PGVIGIL_EXPORT_OUT'], want)):   # kept beside the downloads
    json.dump(MEASURED, open(os.path.join(os.environ['PGVIGIL_EXPORT_OUT'], want, os.path.basename(_mg)), 'w', encoding='utf-8'), indent=1, ensure_ascii=False)
_r17 = subprocess.run([sys.executable, '-I', 'scripts/xlsx-check.py', 'rules', '--measured', _mg] + [f"{dl}/{n}" for n in MEASURED], capture_output=True, text=True)
_p17 = [l for l in _r17.stdout.splitlines() if l.startswith('PASS X17 ')]; _f17 = [l for l in _r17.stdout.splitlines() if l.startswith('FAIL X17 ')]
_c17 = sum(int(m_.group(1)) for m_ in (re.search(r': (\d+) cells', l) for l in _p17) if m_)
_s17 = sorted({s for v in MEASURED.values() for s in v})
# every mapped sheet with rows judged on cells of its own: the Drives cells alone never carry the job grids
_none17 = [f"{n}:{sn}" for (n, sn), (nr, nc) in _n17.items() if nr and not nc]
_drv17 = sum(nc for (n, sn), (nr, nc) in _n17.items() if sn == 'Drives'); _job17 = sum(nc for (n, sn), (nr, nc) in _n17.items() if sn != 'Drives')
check('Drives' in _s17 and any(s != 'Drives' for s in _s17) and len(_p17) == len(MEASURED) and not _f17 and _drv17 > 0 and _job17 > 0 and not _none17,
      f"measured cells (X17): the Drives sheet's free % / free and the job grids' job / last failure carry their row's status - {len(_p17)} of {len(MEASURED)} workbooks PASS on sheets {_s17}, {_c17} cells judged ({_drv17} on Drives, {_job17} on the job grids; a sheet with rows and none judged: {_none17[:3]}); map in {os.path.basename(_mg)}; {(_f17 or [''])[0][:300]}")
# ---- P03: the new menu items, each clicked, each download read --------------------------------------------------
def one_book(key, fname, inst, tab, sheet, g):
    # a workbook of one grid: its name, one sheet named so then 'About' (X12, D-A), the grid's rows, every cell its named
    # pair or plain (X0), the widths by the rule, no pane; returns the zip
    check(stamp(fname, inst, tab + '_' + re.sub(r'[^A-Za-z0-9._-]+', '-', sheet).strip('-'), '.xlsx'), f"{key}: the workbook's name {fname}")
    z = zipfile.ZipFile(f"{dl}/{fname}"); names = sheets_of(z); st, cx = xfs(z); sst = shared(z)
    check(names == [sheet, 'About'], f"{key}: sheets {names} = '{sheet}' + About (the grid alone, X12)")
    x, n = sheet_rows(z, 1)
    check(n == g['rows'], f"{key}: '{sheet}' {n} data rows = {g['rows']} on screen")
    audit(key, sheet, x, cx, g, sst)
    nw, woff = width_audit(x, cx, sst)
    check('<pane' not in x and not woff, f"{key}: '{sheet}' no pane, {nw} widths by the rule ({woff[:3]})")
    if openpyxl is not None:
        try: openpyxl.load_workbook(f"{dl}/{fname}"); check(True, f"{key}: openpyxl opens {fname}")
        except Exception as e: check(False, f"{key}: openpyxl could not open {fname}: {type(e).__name__}: {e}")
    return z, x, cx, sst
gm = d.get('gridmenu') or {}
its = gm.get('items') or []
lastcopy = max([i for i, x in enumerate(its) if x.startswith('Copy')] or [-1])
check('Export Excel' in its and its.index('Export Excel') == lastcopy + 1 and sum(1 for x in its if x.startswith('Export Excel')) == 1, f"gridmenu: the grid's menu has one Export Excel, right after its copies, as DBA Dash's grid menu (red with task 172's 'Export Excel (this grid)' still in web/src/treemenu.ts: P03's WIRING BLOCK takes it out) ({its})")
if gm.get('xlsx'):
    g = gm['screen']
    # export_names.ts sheetNames for one name: Excel's refused characters a space, the quotes at either end off, runs of
    # spaces one, cut at 31 (a trailing space or quote off); (changed by X2: a name taken - 'About', 'History' - goes under
    # the heading above it, never numbered: this grid's name is none of them, checked first)
    sheet = re.sub(r'\s+', ' ', re.sub(r"^'+|'+$", '', re.sub(r'[\\/?*\[\]:]', ' ', g['named']))).strip()[:31].rstrip(" '") or 'Sheet'
    check(sheet.lower() not in ('about', 'history'), f"gridmenu: the grid's own name is no name the workbook takes ({sheet})")
    one_book('gridmenu', gm['xlsx'], 'fleet', 'Backups', sheet, g)
    check((gm.get('said') or '').startswith('Exported ' + gm['xlsx']), f"gridmenu: the grid's line says what was saved ({gm.get('said')!r})")
sm = d.get('summaryExport') or {}
check(any(b.startswith('Export to Excel') for b in sm.get('button', [])) and sm.get('popup') == 'menu' and sm.get('items') == ['Export Summary', 'Export Test Summary'],
      f"summary: the bar's Export to Excel drop-down holds Export Summary and Export Test Summary (DBA Dash's Summary toolbar) ({sm.get('button')}, {sm.get('items')})")
scr = sm.get('screen') or []
tg = [g for g in scr if g.get('tests')]; ig = [g for g in scr if not g.get('tests')]
check(len(tg) == 1 and len(ig) >= 1, f"summary: the page shows the test grid and the instance grid ({[(g['named'], g['rows'], g.get('tests')) for g in scr]})")
if tg and sm.get('tests'):
    z, x, cx, sst = one_book('testsummary', sm['tests'], 'fleet', 'Summary', 'Test Summary', tg[0])
    # DBA Dash's Test Summary rule, in the file: a count 0 green, above 0 in its column's status; the test's name in its
    # row's worst of critical and warning, else green (summary-1.xlsx holds the same; proof-export-dbadash.py compares)
    cells = cells_of(x, sst); col_st = ['ok', 'warn', 'crit', 'none', 'ack']; wrong = []
    for i, row in enumerate(tg[0]['cells']):
        vals = [cells.get((i + 2, j), (0, None, None)) for j in range(len(row))]
        nums = [v[1] for v in vals[1:6]]
        for j, v in enumerate(nums):
            want = 'ok' if not v else col_st[j]
            if cx[vals[j + 1][0]]['fill'] != fill[want]: wrong.append(f"{colname(j + 1)}{i + 2} {v} not {want}")
        worst = 'crit' if nums[2] else 'warn' if nums[1] else 'ok'
        if cx[vals[0][0]]['fill'] != fill[worst]: wrong.append(f"A{i + 2} not {worst}")
        if any(cx[v[0]]['fmt'] != 0 for v in vals[1:6]): wrong.append(f"row {i + 2}: a count not General")
    check(not wrong, f"testsummary: every count green at 0, else its column's status; every test name its row's worst; counts General ({len(tg[0]['cells'])} rows; {wrong[:3]})")
if ig and sm.get('summary'):
    one_book('instancesummary', sm['summary'], 'fleet', 'Summary', 'Instance Summary', ig[-1])
ch = d.get('charts') or {}
cl = ch.get('line') or {}
if cl.get('page') and cl.get('look'):
    zp = zipfile.ZipFile(f"{dl}/{cl['page']}"); np_ = sheets_of(zp); sp = shared(zp)
    # (changed by D-B / X12: no picture - the chart's series is a sheet of the page's workbook, named by its title)
    check(not any(n_.startswith('xl/drawings/') or n_.startswith('xl/media/') for n_ in zp.namelist()), "charts: the line chart's page workbook holds no picture (D-B, X12)")
    zm = zipfile.ZipFile(f"{dl}/{cl['xlsx']}"); nm = sheets_of(zm); sm_ = shared(zm)
    sn = nm[0] if nm else ''
    a_ = cells_of(sheet_rows(zp, np_.index(sn) + 1)[0], sp) if sn in np_ else {}
    b_ = cells_of(sheet_rows(zm, 1)[0], sm_) if nm else {}
    vals = lambda cs: {k: (v[1], v[2]) for k, v in cs.items()}
    check(bool(a_) and vals(a_) == vals(b_), f"charts: the line chart '{cl['title']}': its numbers sheet '{sn}' in the page's workbook equals its own Export Excel's sheet cell by cell ({len(a_)} | {len(b_)} cells)")
if cl.get('dark') and cl.get('look'):
    zd = zipfile.ZipFile(f"{dl}/{cl['dark']}"); nd = sheets_of(zd); sd = shared(zd)
    check(cl.get('darkTheme') == 'dark' and cl.get('after') == 'dark', f"charts: the page drawn dark ({cl.get('darkTheme')}) and dark again after its export ({cl.get('after')})")
    if cl.get('page'):
        fl = lambda zz: sorted(set(re.findall(r'rgb="(\w+)"', zz.read('xl/styles.xml').decode())))
        check(fl(zd) == fl(zipfile.ZipFile(f"{dl}/{cl['page']}")), f"charts: the dark export's colours are the light export's (E2-16) ({len(fl(zd))} colours)")

vo = d.get('volumes') or {}
check(bool(vo.get('xlsx')), f"volumes: an instance's Storage page ({vo.get('hash')}) exported ({vo.get('xlsx')})")
if vo.get('xlsx'):   # (changed by D-B: the page sheet is parked; the Volumes bars' volumes are rows of the 'Volumes' grid sheet)
    zv = zipfile.ZipFile(f"{dl}/{vo['xlsx']}"); nv = sheets_of(zv)
    av = {t_ for (r_, c_), (_, _, t_) in cells_of(sheet_rows(zv, nv.index('Volumes') + 1)[0], shared(zv)).items() if c_ == 0 and r_ > 1 and t_} if 'Volumes' in nv else set()
    bars = vo.get('bars') or []
    miss = [b[0] for b in bars if not any(a_ == b[0] or a_.startswith(b[0] + ' (') for a_ in av)]
    check('Volumes' in nv and len(bars) >= 1 and not miss, f"volumes: the {len(bars)} volume(s) the Volumes chart draws are rows of the 'Volumes' grid sheet ({len(bars) - len(miss)} found; missing {miss[:4]}; sheets {nv[:6]})")

for kind in ('line', 'ring'):
    c = ch.get(kind)
    check(bool(c), f"charts: a {kind} chart's menu was found and its Export Excel clicked ({sorted(ch)})")
    if not c: continue
    check('Export Excel' in c['items'], f"charts: the {kind} chart '{c['title']}' menu {c['items']}")
    z = zipfile.ZipFile(f"{dl}/{c['xlsx']}"); names = sheets_of(z); st, cx = xfs(z); sst = shared(z)
    x, n = sheet_rows(z, 1); cells = cells_of(x, sst)
    m = re.search(r'Saved (\d+) (points|slices) as Excel', c['said'] or '')
    hdr = [cells.get((1, j), (0, None, None))[2] for j in range(3)]
    check(len(names) == 2 and names[1] == 'About' and m is not None and int(m.group(1)) == n and n >= 1, f"charts: the {kind} chart '{c['title']}' workbook {c['xlsx']}: sheets {names}, {n} rows = the menu's word ({c['said']!r})")
    nw, woff = width_audit(x, cx, sst)
    check(not woff, f"charts: the {kind} chart's sheet widths by the rule ({woff[:3]})")
    if kind == 'line':
        t = [cells.get((r, 0)) for r in range(2, n + 2)]
        check(hdr[0] == 'time' and all(v and v[1] is not None and cx[v[0]]['fmt'] == 168 for v in t), f"charts: the line chart's first column is 'time', every point a time under 'yyyy-MM-dd HH:mm' ({hdr})")
    else:
        sh = [cells.get((r, 2)) for r in range(2, n + 2)]
        tot = sum(v[1] for v in sh if v and v[1] is not None)
        # (changed by the lead 13:44 (3): a size ring's size carries its axis's unit, 'size (GB)')
        unit_ok = re.fullmatch(r'size \((?:B|KB|MB|GB|TB|PB)\)', hdr[1] or '') is not None if c['hash'].startswith('#/dbspace') else re.fullmatch(r'size(?: \(\w+\))?', hdr[1] or '') is not None
        check(hdr[0] == 'name' and unit_ok and hdr[2] == 'share' and all(v and cx[v[0]]['fmt'] == 167 for v in sh) and abs(tot - 1) < 1e-6, f"charts: the ring's sheet is name / size (its unit) / share, every share under '0.0%', adding up to 1 ({hdr}, {tot})")
    if openpyxl is not None:
        try: openpyxl.load_workbook(f"{dl}/{c['xlsx']}"); check(True, f"charts: openpyxl opens the {kind} chart's workbook")
        except Exception as e: check(False, f"charts: openpyxl could not open {c['xlsx']}: {e}")
eh = d.get('emptyHidden') or {}
note = eh.get('note') or {}
check(bool(eh.get('base')) and note.get('t') == 'P' and eh.get('hidden') in (note.get('cols') or []) and len(eh.get('keys') or []) == 1,
      f"emptyhidden: '{eh.get('heading')}' on {eh.get('base')} has rows over 24 h and is an empty grid's note in 2001 carrying every column, '{eh.get('hidden')}' hidden with its menu ({eh.get('tried')}; keys {eh.get('keys')})")
if eh.get('xlsx'):
    z = zipfile.ZipFile(f"{dl}/{eh['xlsx']}"); names = sheets_of(z); sst = shared(z)
    want = [c for c in (note.get('cols') or []) if c != eh.get('hidden')]
    heads = []
    for k in range(2, len(names) + 1):
        x = z.read(f'xl/worksheets/sheet{k}.xml').decode()
        if len(re.findall(r'<row r="', x)) == 1: heads.append((names[k - 1], [v[2] for (r, c), v in sorted(cells_of(x, sst).items()) if r == 1]))
    check(any(h == want for _, h in heads) and not any(h == note.get('cols') for _, h in heads),
          f"emptyhidden: the empty grid's sheet is its header row without the hidden column '{eh.get('hidden')}', as DBA Dash writes the visible columns only ({heads})")

# the grid tools, when the grid's menu carries them
t = d.get('tools') or {}
digits = lambda v: re.sub(r'\D', '', v or '')
if not t.get('wired'):
    skipped('tools', f"the grid's menu carries no grid tools (ui.ts does not send 'pgvigil:gridmenu'): its lines are {t.get('menu')}")
else:
    g, rows, head = t['screen'], t['rows'], t['head']
    h = t.get('html') or ''
    trs = re.findall(r'<tr>(.*?)</tr>', h, re.S)
    ths = re.findall(r'<th style="([^"]*)">([^<]*)</th>', h)
    check(len(trs) == rows + 1 and [unesc(x[1]) for x in ths] == head and all('background:#0063a3;color:#ffffff;font-weight:bold' in x[0] for x in ths),
          f"tools: the HTML copy is a table of {len(trs) - 1} rows (the grid: {rows}) under the {len(ths)} headings, the header #0063a3 with white bold text")
    tds = [re.findall(r'<td style="([^"]*)"(?: data-status="(\w+)")?>([^<]*)</td>', r) for r in trs[1:]]
    wrong = []; seen = {}
    for i, row in enumerate(g['cells']):
        for j, c in enumerate(row):
            style, st_, text = tds[i][j] if i < len(tds) and j < len(tds[i]) else ('', '', '')
            pair = lambda k: f"background:#{fill[k][2:].lower()};color:#{font[k][2:].lower()}"
            judges = [row[head.index(h)] for h in PAIRS.get(head[j], ()) if h in head]
            if c['s']: good = st_ == c['s'] and pair(c['s']) in style
            elif st_: good = any(q['s'] == st_ for q in judges) and c['t'] != '' and pair(st_) in style
            else: good = ('background:#f1f1f6;color:#004f83' in style) == c['l'] and ('background:' in style) == c['l']
            if st_: seen[st_] = seen.get(st_, 0) + 1
            if not good or unesc(text) != c['t']: wrong.append(f"row {i + 1} column {j + 1}: {c} as {style[-60:]!r} {st_!r} {text!r}")
    check(not wrong and all(k in seen for k in g['status']), f"tools: every cell of the HTML copy carries the screen's colour as its own style ({seen}; the screen shows {g['status']}; {len(wrong)} wrong {wrong[:2]})")
    check((t.get('plain') or '').split('\n')[0] == '\t'.join(head), "tools: the HTML copy has the tab-separated words beside it for a plain paste")
    md = (t.get('markdown') or '').rstrip('\n').split('\n')
    marks = md[1].replace(' ', '').strip('|').split('|') if len(md) > 1 else []
    check(len(md) == rows + 2 and md[0] == '| ' + ' | '.join(head) + ' |' and len(marks) == len(head) and set(marks) <= {'---', '---:'} and '---:' in marks
          and md[2] == '| ' + ' | '.join(re.sub(r'([\\|*_`<\[\]])', r'\\\1', c['t']) for c in g['cells'][0]) + ' |',
          f"tools: the Markdown copy is a pipe table of {len(md)} lines (the grid's {rows} rows + 2), number columns right-aligned, its first row the screen's")
    sel = t['sel']; sm = re.search(r'sum ([^\u00b7]+)\u00b7', sel['line'])
    check(sel['picked'] == 2 and sel['line'].startswith('2 cells selected: sum ') and sm is not None and digits(sm.group(1)) == str(sum(int(digits(x) or 0) for x in sel['cells'])),
          f"tools: Ctrl+click on two 'failed' counts {sel['cells']}: {sel['line']!r}")
    check(t['selCleared'] == {'picked': 0, 'line': ''}, f"tools: a plain click clears the selection and its line ({t['selCleared']})")
    gp = t.get('group') or {}
    check(gp.get('label') == 'Grouped by platform' and gp.get('head', [None])[:2] == ['platform', 'rows'] and any(x.endswith('(sum)') for x in gp.get('head', []))
          and len(gp.get('rows', [])) == gp.get('platforms') and sum(int(digits(r[1]) or 0) for r in gp.get('rows', [])) == rows and t.get('ungrouped') is True,
          f"tools: 'Group by platform' lists {len(gp.get('rows', []))} groups for {gp.get('platforms')} platforms, their rows adding up to {rows}, each number column summed; 'Ungroup' removes it")
    def bars_ok(bs): return len(bs) == len(g['cells']) and all(b['bar'] == (int(digits(b['t']) or 0) > 0) for b in bs) and any(b['share'] == '100%' for b in bs) and any(b['bar'] for b in bs)
    check(bars_ok(t['bars']), f"tools: 'Data bars on failed' draws a bar on each failed count above zero, the largest at 100 % ({[(b['t'], b['share']) for b in t['bars'] if b['bar']][:4]})")
    fz = t['frozen']
    check(fz['on'] and fz['classes'] == ['gt-f1', 'gt-f2'] and fz['sticky'][:2] == ['sticky', 'sticky'] and fz['sticky'][2] != 'sticky', f"tools: 'Freeze the columns up to platform' makes the first two columns sticky ({fz})")
    hd = t['hidden']
    check(hd['marked'] == 1 and hd['th'] == 'none' and hd['td'] == 'none' and len(hd['keys']) == 1 and hd['keys'][0].startswith('pgvigil.grid.backups.'),
          f"tools: 'Hide column platform' hides the header and the cells and keeps the choice in localStorage ({hd})")
    af = t['after']
    check(af['hidden'] == hd and af['frozen']['on'] and af['frozen']['classes'] == ['gt-f1', 'gt-f3'] and bars_ok(af['bars']),
          f"tools: after a reload the column is still hidden, the first two shown columns frozen ({af['frozen']['classes']}) and the bars drawn")
    # (changed by X12: the page's sections come first - the tiles' sheet before the grid's: the grid's sheet is the one whose
    # header begins 'instance', its table the one its relationship names; X7: a unit in a header left out)
    z2 = zipfile.ZipFile(f"{dl}/{t['xlsx']}"); s2 = shared(z2); hdr2, tx2 = [], ''
    for k_ in range(1, len(sheets_of(z2)) + 1):
        c2 = cells_of(z2.read(f'xl/worksheets/sheet{k_}.xml').decode(), s2)
        if c2.get((1, 0), (0, None, None))[2] == head[0]:
            hdr2 = [re.sub(UNIT_RE, '', h_) if h_ else h_ for h_ in (c2.get((1, j), (0, None, None))[2] for j in range(len(head)))]
            rl = f'xl/worksheets/_rels/sheet{k_}.xml.rels'
            m_ = re.search(r'Target="\.\./tables/(table\d+\.xml)"', z2.read(rl).decode()) if rl in z2.namelist() else None
            tx2 = z2.read('xl/tables/' + m_.group(1)).decode() if m_ else ''
            break
    check('platform' in head and hdr2 == [x for x in head if x != 'platform'] + [None] and f'<tableColumns count="{len(head) - 1}">' in tx2 and 'name="platform"' not in tx2,
          f"tools: the workbook exported with the column hidden has no platform column ({len([x for x in hdr2 if x])} of the grid's {len(head)} columns, the table too)")
    ch = t.get('chooser') or {}
    check(ch.get('cols') == len(head) and ch.get('unticked') == 1 and ch.get('label') == 'Columns of this grid', f"tools: 'Columns...' lists the {len(head)} columns, the hidden one unticked ({ch})")
    rs = t['reset']
    check(rs['hidden']['marked'] == 0 and rs['hidden']['keys'] == [] and rs['hidden']['td'] != 'none' and not rs['frozen']['on'] and rs['bars'] == 0 and t.get('closed') is True,
          f"tools: 'Reset this grid' brings every column back, unfreezes, drops the bars and forgets the choice; 'Close' closes the panel ({rs['hidden']}, frozen {rs['frozen']['on']}, bars {rs['bars']})")

# the colour reader (web/src/export_colours.ts) on the page's own elements: the stylesheet's colours (app.css)
cr = d.get('colourReader') or {}
def pc(k): return cr.get(k) or {}
def near(a, b): return bool(a) and bool(b) and all(abs(int(a[i:i + 2], 16) - int(b[i:i + 2], 16)) <= 1 for i in (0, 2, 4))
check(pc('th').get('fill') == '004F83' and pc('th').get('text') == 'FFFFFF', f"colour reader: a grid's header cell 004F83 / FFFFFF (app.css --st-head / --st-on) ({pc('th')})")
for k, f_, t_ in (('ok', '006638', 'FFFFFF'), ('crit', 'AB1F26', 'FFFFFF'), ('none', 'E0E1E9', '004F83')):
    check(pc(k).get('fill') == f_ and pc(k).get('text') == t_, f"colour reader: a status cell '{k}' {f_} / {t_} ({pc(k)})")
check(bool(pc('plain')) and 'fill' not in pc('plain') and pc('plain').get('text') == '1B2230', f"colour reader: a plain cell paints no fill of its own, its text 1B2230 (--text) ({pc('plain')})")
check(bool(pc('link')) and 'fill' not in pc('link') and pc('link').get('text') == '2259C8', f"colour reader: a link in a cell: no fill, 2259C8 (--accent) ({pc('link')})")
check(near(pc('tint').get('fill'), 'E0E8F7') and pc('tint').get('under') == 'FFFFFF', f"colour reader: a planted rgba(34, 89, 200, .14) cell on a panel blends to E0E8F7 within 1 a channel ({pc('tint')})")
check(near(pc('mix').get('text'), '8D9097'), f"colour reader: a planted color-mix(in srgb, #1b2230 50%, transparent) text blends to 8D9097 within 1 a channel (computed {cr.get('mixRaw')!r}; {pc('mix')})")
check(bool(pc('darkPlain')) and 'fill' not in pc('darkPlain') and pc('darkPlain').get('text') == 'E3E6EB' and pc('darkTh').get('fill') == '004F83' and cr.get('themeBack') is True,
      f"colour reader: under data-theme dark the same plain cell E3E6EB with no fill, the header 004F83; the theme put back ({pc('darkPlain')}, {pc('darkTh')}, back {cr.get('themeBack')})")

# SECTIONS (E2-1): its self-test, then each page's visible sections
st = d.get('sectionsSelfTest') or {}
secs = st.get('sections') or []
tail = secs[-6:]
kinds = [x['kind'] for x in tail]
want = ['heading', 'tiles', 'disclosure', 'disclosure', 'grid', 'other']
texts = ['Planted heading', 'planted tile', 'planted closed disclosure', 'planted open disclosure', 'planted open cell', 'planted unknown content']
check(kinds == want and all(t in x['text'] for t, x in zip(texts, tail)) and (tail[4].get('rows') == 1 if len(tail) == 6 else False),
      f"sections: the planted visible sections read last, in their place: {[(x['kind'], x['text'][:30]) for x in tail]}")
leak = [t for t in ('planted hidden cell', 'planted display none', 'planted visually hidden', 'planted invisible note') if any(t in x['text'] for x in secs)]
check(not leak, f"sections: none of the planted hidden sections is read (read: {leak or 'none'}; {st.get('hidden')} hidden elements met)")
check(st.get('removed') is True, "sections: the planted sections removed after")
for key, pg in d.items():
    if isinstance(pg, dict) and isinstance(pg.get('sections'), dict):
        ss = pg['sections']['sections']
        n_ = {}
        for x in ss: n_[x['kind']] = n_.get(x['kind'], 0) + 1
        print(f"sections {pg.get('hash')}: {len(ss)} - " + ', '.join(f'{k} {v}' for k, v in sorted(n_.items())))

# readRows: the rows a grid does not draw, read through the shell, against the same rows drawn
op = d.get('offPage') or {}
tot, scr, via, bare_ = op.get('total') or 0, op.get('onScreen') or [], op.get('viaShell') or [], op.get('bare') or []
check(tot > 200 and op.get('before') == 200 and op.get('after') == tot and len(scr) == tot,
      f"offpage: the fleet Findings' longest grid has {tot} rows (over 200 needed), {op.get('before')} drawn before 'Show all', {op.get('after')} after ({op.get('cols')})")
cells = [(i, j) for i, r in enumerate(scr) for j in range(len(r))]
same = [(i, j) for i, j in cells if i < len(via) and j < len(via[i]) and via[i][j] == scr[i][j]]
past = [(i, j) for i, j in cells if i >= 200]
coloured = [(i, j) for i, j in past if not re.fullmatch(r'-/1B2230', scr[i][j])]
sset = set(same)
diff = [(i, j, scr[i][j], via[i][j] if i < len(via) and j < len(via[i]) else None) for i, j in cells if (i, j) not in sset]
check(len(scr) > 0 and len(via) == len(scr) and len(same) == len(cells) and len(coloured) > 0,
      f"offpage: every row's cells read through readRows' shell from detached copies = the drawn rows' computed colours: {len(same)} of {len(cells)} cells; "
      f"rows 201-{tot}: {len([c for c in past if c in sset])} of {len(past)}, {len(coloured)} of them coloured (a fill, a mark or a text other than plain 1B2230; "
      f"e.g. {sorted({scr[i][j] for i, j in coloured})[:4]}) (differ: {diff[:3]})")
sh = op.get('shell') or {}
check(sh.get('same') is False and 'grid' in (sh.get('cls') or '').split() and sh.get('visibility') == 'hidden' and sh.get('position') == 'fixed' and sh.get('next') is True and sh.get('hidden') == 'true'
      and sh.get('h') == op.get('h0') == op.get('h1') and op.get('kids0') == op.get('kids1') and op.get('drawnAfter') == tot and op.get('copiesLoose') is True and op.get('left') == 0,
      f"offpage: the shell was the table's own classes, hidden, fixed, right after the table, and left nothing behind (page height {op.get('h0')} / {sh.get('h')} / {op.get('h1')}, "
      f"the wrap's children {op.get('kids0')} / {op.get('kids1')}, drawn rows {op.get('drawnAfter')}, copies detached {op.get('copiesLoose')}, shells left {op.get('left')}) ({sh})")
nb = len([(i, j) for i, j in cells if i < len(bare_) and j < len(bare_[i]) and bare_[i][j] != scr[i][j]])
check(nb > 0, f"offpage: self-test - the same copies read bare (detached: no computed style) differ from the screen on {nb} of {len(cells)} cells (e.g. {bare_[0][:2] if bare_ else None} against {scr[0][:2] if scr else None})")

# the route walk (the first language only): every route of the app's route tables opened, rendered, read
w = d.get('walk')
lang = sys.argv[3]   # the language this run checks ('want' is reused above as the planted sections' kinds)
if lang.startswith('en'):
    w = w or {}
    pages = w.get('pages') or []
    tabs = w.get('tables') or {}
    check(sorted(tabs) == ['drillTabs', 'instanceTabs', 'mssqlInstanceTabs', 'rootTabs'] and all(tabs.values()) and w.get('pg') and w.get('sql'),
          f"routes: the app's route tables read from web/src/router.ts: {sorted(tabs.items())}; walked on the PostgreSQL instance {w.get('pg')!r} and the SQL Server instance {w.get('sql')!r}")
    by = {}
    for p in pages: by.setdefault(p['table'], []).append(p)
    notr = [(p['table'], p['route'], p.get('why') or p.get('hash')) for p in pages if not p.get('rendered')]
    check(sum(tabs.values()) > 0 and all(len(by.get(k, [])) == n for k, n in tabs.items()) and not notr,
          f"routes: every route opened and rendered: {len(pages) - len(notr)} of {sum(tabs.values())} pages ({', '.join(f'{k} {len(by.get(k, []))} of {n}' for k, n in sorted(tabs.items()))}; drill pages by {w.get('drill')}) (not: {notr[:8]})")
    nosec = [(p['table'], p['route']) for p in pages if p.get('rendered') and not p.get('sections')]
    check(not nosec and len(pages) > 0, f"routes: every rendered page has at least one visible section (none: {nosec[:8]})")
    tally = {}
    for p in pages:
        for x in p.get('sections') or []: tally[x['kind']] = tally.get(x['kind'], 0) + 1
    print(f"routes: {sum(len(p.get('sections') or []) for p in pages)} sections over {len(pages)} pages - " + ', '.join(f'{k} {v}' for k, v in sorted(tally.items())))
    errs = [(p['table'], p['route'], p['errors'][0][:60]) for p in pages if p.get('errors')]
    print(f"routes (said, not graded): {len(errs)} pages show an error box: {errs}")
    nobar = [(p['table'], p['route']) for p in pages if p.get('rendered') and not p.get('exportBar')]
    print(f"routes (said, not graded): {len(nobar)} pages without the bar's export: {nobar}")
    for p in pages:
        n_ = {}
        for x in p.get('sections') or []: n_[x['kind']] = n_.get(x['kind'], 0) + 1
        print(f"route {p['table']} {p['route']} {p.get('at') or p.get('hash')}: {len(p.get('sections') or [])} - " + ', '.join(f'{k} {v}' for k, v in sorted(n_.items())))
    if os.environ.get('PGVIGIL_EXPORT_OUT'):
        os.makedirs(os.environ['PGVIGIL_EXPORT_OUT'], exist_ok=True)
        json.dump(w, open(os.path.join(os.environ['PGVIGIL_EXPORT_OUT'], 'sections-inventory.json'), 'w'), indent=1)
        print(f"routes: the inventory kept in {os.environ['PGVIGIL_EXPORT_OUT']}/sections-inventory.json")
else:
    print(f"routes: walked in the first language only ({lang}: not walked)")
sys.exit(1 if bad else 0)
PY

# each language: its own Chromium (the page's locale is the browser's), its own downloads, the same checks
for L in en-US fr-FR; do
  echo "== a headless Chromium in $L on CDP $CDP"
  [[ -n "$CHR" ]] && { kill "$CHR" 2>/dev/null || true; wait "$CHR" 2>/dev/null || true; CHR=""; }
  DL="$WORK/dl-$L"; mkdir -p "$DL"
  LANGUAGE=${L/-/_} LC_ALL=${L/-/_}.UTF-8 chromium --headless=new --lang=$L --accept-lang=$L --remote-debugging-port=$CDP --user-data-dir="$WORK/chrome-$L" --no-first-run --disable-gpu about:blank > "$WORK/chrome-$L.log" 2>&1 &
  CHR=$!
  for _ in $(seq 1 60); do curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null 2>&1 && break; sleep 0.5; done
  curl -fs "http://127.0.0.1:$CDP/json/list" >/dev/null || fail "chromium's CDP port never answered"
  echo "== the downloads ($L)"
  node "$WORK/drive.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$DL" "$WORK/export_colours.js" "$WORK/routes.json" > "$WORK/drive-$L.json" || fail "the driver failed ($L)"
  ok "downloaded ($L): $(cd "$DL" && ls | tr '\n' ' ')"
  echo "== the X rules on every workbook ($L): scripts/xlsx-check.py rules"
  XRC=0; python3 -I "$XCHECK" rules "$DL"/*.xlsx > "$WORK/xcheck-$L.txt" || XRC=$?   # exit 1 = a rule failed (set -e: caught)
  [[ -n "${PGVIGIL_EXPORT_OUT:-}" ]] && { mkdir -p "$PGVIGIL_EXPORT_OUT/$L"; cp "$WORK/xcheck-$L.txt" "$WORK/drive-$L.json" "$DL"/* "$PGVIGIL_EXPORT_OUT/$L"/; }
  # every rule on every page (X18 too); any other exit than 0 / 1 is the check's own failure
  { grep -E '^FAIL' "$WORK/xcheck-$L.txt" || true; } | cut -c1-400   # no FAIL line: grep's exit 1 must not end the proof (pipefail)
  NW=$(ls "$DL"/*.xlsx | wc -l)
  for r in X0 X1 X2 X3 X4 X5 X6 X7 X8 X9 X10 X11 X12; do
    n=$(grep -c "^FAIL $r " "$WORK/xcheck-$L.txt" || true); np=$(grep -c "^PASS $r " "$WORK/xcheck-$L.txt" || true)
    if [[ "$n" == 0 && "$np" == "$NW" ]]; then ok "xcheck $r: every workbook ($L, $np of $NW files PASS)"; else echo "FAIL: xcheck $r: $n FAIL, $np PASS of $NW workbook(s) ($L)"; XRC=1; fi
  done
  echo "== the files read back ($L)"
  # (the X rules' verdict after the read-back: one run shows both)
  CRC=0; python3 -I "$WORK/check.py" "$WORK/drive-$L.json" "$DL" "$L" || CRC=$?
  [[ $XRC == 0 ]] || fail "a workbook breaks an X rule of scripts/xlsx-check.py ($L)"
  [[ $CRC == 0 ]] || fail "a file did not match its page ($L)"
  if command -v soffice >/dev/null; then
    for f in "$DL"/*.xlsx; do
      (cd "$WORK" && timeout 120 soffice --headless -env:UserInstallation=file://$WORK/lo --convert-to csv --outdir "$WORK/lo-out-$L" "$f" >/dev/null 2>&1) || fail "LibreOffice could not open $(basename "$f")"
      [[ -s "$WORK/lo-out-$L/$(basename "${f%.xlsx}").csv" ]] || fail "LibreOffice wrote nothing for $(basename "$f")"
      ok "LibreOffice opens $(basename "$f") ($L)"
    done
  else
    echo "not checked: soffice is not on this machine (the file opening in a spreadsheet program)"
  fi
  [[ -n "${PGVIGIL_EXPORT_OUT:-}" ]] && { mkdir -p "$PGVIGIL_EXPORT_OUT/$L"; cp "$DL"/* "$PGVIGIL_EXPORT_OUT/$L"/; echo "kept in $PGVIGIL_EXPORT_OUT/$L"; }
done
echo "OK: every page above exported to .xlsx and CSV in two languages, each file matching its page cell by cell (every grid with rows an Excel table, DBA Dash's formats and widths); a grid's menu, the Summary's drop-down and two charts' menus exported with Export Excel"
