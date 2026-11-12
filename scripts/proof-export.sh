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
#   names      fleet_Summary_<yyyymmdd-hhmm>_<yyyymmdd-hhmm>.xlsx and .csv; <instance>_Tables_<from>_<to>.xlsx and
#              .csv.zip (the Tables tab has two grids), the instance named as in the tree
#   summary    sheets: Summary first, then one per grid named by the heading above it ('Summary' repeated is
#              'Summary (2)', 'Summary (3)': the heading inside the Needs attention strip names no grid outside
#              the strip); every data sheet: no frozen pane (DBA Dash's: P03), each column's width the rule's (export.ts
#              colWidth, DBA Dash's AdjustToContents: Carlito widths, header 1.0286 x bold + 22.19 px, a cell 1.0738 x + 0.52
#              px, (px - 0.025625) / 7, at most 150) within a pixel; styles.xml carries a solid
#              fill in each status colour the Summary grid shows on screen
#              (DBA Dash's: ok FF006638 white, warn FFE49325 dark FF1D1300, crit FFAB1F26 white, 'no sample' FFE0E1E9 FF004F83) and a cell of
#              that sheet is styled with it, in a plain font (not bold, P03); the header row of every data sheet filled FF0063A3 with white bold text; each sheet's data rows = the grid's rows on screen;
#              the Summary sheet's own header row (Item, Value, Note) and its 'Sheet | Rows | Note' line in the same blue, white bold (6 cells), no pane and no table on it
#   table      every data sheet with rows is an Excel table: the sheet names one table part (no sheet autoFilter beside
#              it), the part's ref and its autoFilter's cover the sheet (A1 to the last column and row, = the sheet's
#              dimension), its column names are unique whatever the case, none empty, and equal to the header cells in
#              order, which are shared strings (xl/sharedStrings.xml, as Excel stores a table's header); its tableStyleInfo
#              DBA Dash's (no style name, showRowStripes 1: no stripe drawn);
#              ids and names unique in the workbook; the part in [Content_Types].xml. A grid a filter leaves
#              without rows (the Tables tab's second grid, filtered to nothing) keeps the plain sheet filter and no table
#   colours    every cell of every row the page draws (a grid draws its first 200 rows; the read must return exactly
#              those), against the page: a cell the screen colours (a status cell, a badge, a dot, a
#              bare class set on the cell: no page draws one since ui.ts turns a Col's bare cls into a status cell,
#              so the driver gives two cells of the Tables tab one to keep export.ts's branch tested) carries that status's fill and text colour; a cell with a status fill
#              the screen does not give it is a value its row's judging cell coloured: only in a value column of the
#              pairs the doc lists (last archived / archiver, last start / last run, free size / free, a finding's
#              value / severity ...), the judging cell of that row shows that colour, the cell is not empty; a cell
#              the screen draws as a link is filled FFF1F1F6 with text
#              FF004F83 (DBA Dash's link column); every other cell has NO fill and no text colour (no banded rows:
#              DBA Dash bands none). Counted per sheet (the lines 'cells:'), to set beside DBA Dash's own export
#   carry      Backups: every 'last archived' cell of a row whose 'archiver' cell is coloured is in that colour (the
#              demo's failing archiver red, the archiving ones green: at least one each); Jobs: every 'last start' of
#              a row with a coloured 'last run' is in its colour (at least one). Since the join the page's own rule
#              colours those value cells on the screen (the file follows the screen); a value cell the screen leaves
#              plain is carried in the file by export.ts. Either way the value's colour = the judging cell's
#   percent    Storage: every 'free' cell a number under numFmt 167 ('0.0%', DBA Dash's P1) whose value is the screen's percent / 100;
#              its CSV keeps the percent figure itself (12.5, not 0.125)
#   drives     the Storage folder's grids at the root (task 176): Drives (its metrics grid, every status), DB Space and
#              Files each show a grid with rows, named fleet_Drives_ / fleet_DB-Space_ / fleet_Files_, and are graded as
#              every page here is (sheets, tables, colours, csv); Drives drawn with the status All and Toggle Metrics
#              pressed, Files with the status All (read from the page); DB Space's allocated (GB) and used (GB) numbers
#              in the workbook (no figure left as text; used's text only 'not read')
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
#   tables     sheets: Summary, Tables, Biggest tables (the screen's headings); Biggest tables sorted by 'total'
#              on screen first (the click changes the order), its sheet's 'table' column in the screen's order and
#              every 'total' and 'live rows' still a number
#              (a page model out of step with the sort turns them to text); a numeric cell (<v>, no t=) styled
#              with a number format (numFmtId 165 bytes, '#,##0" B"'), a time cell with 168 ('yyyy-MM-dd HH:mm', DBA
#              Dash's) and a count with 0 (General, as DBA Dash writes one); no '#,##0' or '#,##0.00' in styles.xml
#   roles      the instance's Roles tab: the privilege grids sit under h4 headings; every sheet's name follows the
#              heading above its grid (no 'Memberships (2)' for 'Database privileges')
#   activity   the instance's Running queries tab over 7 days: Per sample shows 500 rows; the Summary sheet's row for it
#              carries 'the newest 500 of N samples'; every workbook's Summary sheet has a Time zone row ('<zone> (UTC+hh:mm at export)')
#   slow       the fleet's Slow queries tab (24 h): the hand-built Per day table's statements column numeric, a
#              duration cell with numFmt 170 ('#,##0.###" ms"'); on EVERY page no 'x ms / x s / x min' text is left in
#              any sheet (each tab rounds its milliseconds its own way)
#   db         a database's drill page: its statements grid's millisecond column holds a value under 1 ms and one
#              at 1,000 ms or more, both numbers with numFmt 170
#   perf       (P03) the fleet's Performance summary: graded as every page here; its CPU histogram column (a picture of
#              bars, the top bucket painted critical even when empty) has no fill in any row
#   reader     the screen's colour of a cell is read on its own terms, not by export.ts's rule: a status cell, else the
#              worst of the marks drawn in it (a badge, a dot, a data bar's fill, a span marked warn / crit, each with
#              a size on the screen) and of its texts computed in the critical or warning colour, else a bare class
#   csv        the Summary's .csv: its data rows (python csv, header excluded) = the grid's rows; the Tables
#              .csv.zip: two CSVs, each with its grid's row count; a UTF-8 BOM first (every page's CSV is graded so)
#   gridmenu   (P03) the fleet Backups grid's menu has one Export Excel line (no other line starting so), right after its
#              copies (DBA Dash's grid menu: Copy, then Export Excel); clicked, it downloads fleet_Backups_<sheet>_<from>_<to>.xlsx: Summary + that grid's
#              sheet, its rows, every cell in the screen's colour, the widths by the rule; the grid's line says 'Exported <file>'
#   summary drop-down (P03) the fleet Summary's bar has Export to Excel (aria-haspopup menu) with Export Summary and
#              Export Test Summary; each downloads one grid's workbook (sheets Summary + 'Instance Summary' / 'Test
#              Summary'), graded as above; the Test Summary by DBA Dash's rule (summary-1.xlsx holds it too): a count 0
#              green, above 0 in its column's status, a test's name in its row's worst of critical and warning else green,
#              the counts General
#   charts     (P03) a line chart's and a ring's menu (the root DB Space first, else an instance's pages) has Export
#              Excel; each downloads Summary + a sheet of the chart's numbers, its rows = the menu's 'Saved N points /
#              slices as Excel'; the line's first column 'time', every point under 'yyyy-MM-dd HH:mm'; the ring's name /
#              size / share, every share under '0.0%', the shares adding up to 1
#   emptyhidden (P03) a grid with rows over 24 h that is an empty grid's note in a 2001 window under the same heading
#              and columns (the first of seven candidate pages that has one); a column hidden with its menu over 24 h;
#              the 2001 page's Export .xlsx: that grid's sheet is its header row without the hidden column
#   shots      with PGVIGIL_EXPORT_SHOTS: grid-menu, summary-export, chart-menu-line, chart-menu-ring, each -light and -dark
#   libre      when soffice is on the machine, each .xlsx converts to CSV headless (the file opens); none = said
#   languages  all of the above twice: Chromium in en-US and in fr-FR (navigator.language says so; 1234567 shows
#              without a comma: the locale's grouping space), the numbers numeric in both
set -euo pipefail
cd "$(dirname "$0")/.."
: "${PGVIGIL_ADMIN_DSN:?}"
WORK=$(mktemp -d); DB="pgvigil_export_$RANDOM"; PORT=$((21000 + RANDOM % 9000)); CDP=$((PORT + 1)); SRV=""; CHR=""
fail() { echo "FAIL: $*" >&2; exit 1; }
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

echo "== build and seed the demo into $DB, serve on 127.0.0.1:$PORT"
CGO_ENABLED=0 go build -o "$WORK/pgvigil" ./cmd/pgvigil
psql "$PGVIGIL_ADMIN_DSN dbname=postgres" -XAtq -c "create database $DB" >/dev/null
"$WORK/pgvigil" demo -dsn "$PGVIGIL_ADMIN_DSN dbname=$DB" -serve -listen "127.0.0.1:$PORT" -days 2 > "$WORK/demo.log" 2>&1 &
SRV=$!
for _ in $(seq 1 "${PGVIGIL_DEMO_WAIT_S:-240}"); do grep -q 'pgvigil demo serving' "$WORK/demo.log" 2>/dev/null && break; kill -0 $SRV 2>/dev/null || { cat "$WORK/demo.log"; fail "the demo serve died"; }; sleep 1; done
grep -q 'pgvigil demo serving' "$WORK/demo.log" || { tail -5 "$WORK/demo.log"; fail "the demo did not come up in ${PGVIGIL_DEMO_WAIT_S:-240} s (PGVIGIL_DEMO_WAIT_S raises the wait on a loaded machine)"; }

# the driver: open a page, count each grid's rows and read the headings, press a button, wait for the download
cat > "$WORK/drive.mjs" <<'JS'
const [port, U, dl] = process.argv.slice(2);
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
  const head = c => { const x = c.cloneNode(true); x.querySelectorAll('.whatis, .filter-btn').forEach(b => b.remove()); return words(x); };
  // b: the colour is the page's own class on the cell itself (a Col's cls without 'status'), no status cell or mark
  const cell = td => ({ t: words(td), s: st(td), l: !td.classList.contains('status') && !!td.querySelector('a[href]'),
    b: !td.classList.contains('status') && !td.querySelector(KNOWN) && ['crit', 'warn', 'ok'].some(k => td.classList.contains(k)) });
  // a heading inside a region of its own (the Summary's Needs attention strip) names only the grids of that region
  let outer = '', inner = null;
  return [...document.querySelectorAll('main h2, main h3, main h4, main table.grid, main table.props, main p.empty[data-cols]')].map(e => {
    if (e.tagName !== 'TABLE' && e.tagName !== 'P') {
      const within = e.closest('[role=region]');
      if (within) inner = { text: head(e), within }; else { outer = head(e); inner = null; }
      return { h: head(e) };
    }
    const named = inner && inner.within.contains(e) ? inner.text : outer;
    // a grid with no row (ui.ts grid: its note carries its columns' names): the export's sheet of its header row alone
    // (a note with no column the export leaves out: null, dropped by grids())
    if (e.tagName === 'P') { const cols = JSON.parse(e.dataset.cols || '[]'); return cols.length ? { named, rows: 0, head: cols, cells: [], status: [], empty: true, tests: !!e.closest('.tests'), att: !!e.closest('.attention') } : null; }
    const grid = e.classList.contains('grid');
    const cells = grid ? [...e.querySelectorAll(':scope > tbody > tr')].map(tr => [...tr.children].map(cell))
      : [...e.querySelectorAll('tr')].map(tr => { const th = tr.querySelector('th'), td = tr.querySelector('td'); return [{ t: th ? words(th) : '', s: null, l: false }, { t: td ? words(td) : '', s: td ? st(td) : null, l: false }]; });
    return { named, rows: e.dataset.rows ? Number(e.dataset.rows) : cells.length, head: grid ? [...e.querySelectorAll(':scope > thead > tr:first-child > th')].map(head) : ['item', 'value'], cells,
      status: [...new Set(cells.flat().map(c => c.s).filter(k => k && k !== 'ack'))], tests: !!e.closest('.tests'), att: !!e.closest('.attention') };
  });
})()`;
const page = async (hash, sortBy, filterNone) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(300);
  if (!await settled()) throw new Error('page did not render: ' + hash);
  let order = null, before = null;
  if (filterNone) {
    // the page's last grid filtered to nothing: a grid without rows keeps the plain sheet filter, no Excel table
    await ev(`(() => { const t = [...document.querySelectorAll('main table.grid')].pop(); t.querySelector('thead .filter-btn').click(); const i = t.querySelector('thead tr.filters input'); i.value = 'zzzz-no-such-row'; i.dispatchEvent(new Event('input', { bubbles: true })); })()`);
    await sleep(600);
    // and two cells of the page's first grid given a class as a page's own rule gives one (ui.ts adds a Col's cls to the
    // cell the same way): no tab of this proof's visits has such a rule in the demo, the export must read the class
    const drawn = await ev(`(() => { const t = document.querySelector('main table.grid'); if (Number(t.dataset.rows ?? 0) > 200) return false;   // past its page the export builds the rows off the screen
      const tr = t.querySelector(':scope > tbody > tr'); tr.children[1].classList.add('crit'); tr.children[2].classList.add('warn'); return true; })()`);
    if (!drawn) throw new Error('the first grid of the Tables tab has over 200 rows: the class check needs a grid drawn whole');
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
  return { hash, grids, order, before, xlsx: await press('Export .xlsx', ['.xlsx']), csv: await press('Export CSV', ['.csv', '.csv.zip']) };
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
// a database's drill page (the Database info tab's first database link): its statements grid rounds to 0.1 ms, with
// sub-millisecond, fractional and 1,000+ ms values in one column
await cmd('Page.navigate', { url: U + `#/dbinfo?i=${one.instance_id}` }); await sleep(300);
if (!await settled()) throw new Error('the Database info tab did not render');
const dbHref = await ev(`(document.querySelector('main a[href*="#/db?"]') || {}).getAttribute?.('href') ?? null`);
if (!dbHref) throw new Error('no database link on the Database info tab');
out.db = await page(dbHref);
// the Tables tab again (another window: another file name), its second grid filtered to nothing: a sheet without rows
out.empty = await page(`#/tables?i=${one.instance_id}&w=24h`, null, true);
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
  }
}
out.charts = charts;
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
console.log(JSON.stringify(out));
process.exit(0);
JS
cat > "$WORK/check.py" <<'PY'
import csv, io, json, os, re, sys, zipfile
d = json.load(open(sys.argv[1])); dl = sys.argv[2]; want = sys.argv[3]
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
        else: val, text = (float(v.group(1)) if v else None), (unesc(t.group(1)) if t else None)
        out[(int(m.group(2)), colidx(m.group(1)))] = (int(m.group(3)), val, text)
    return out
# a value column and the columns that may judge it, by the screen's headings (docs/export.md's table; a finding's
# value is headed by what it names)
PAIRS = {'last archived': ('archiver',), 'last start': ('last run',), 'free size': ('free',), 'last full': ('full',), 'full age': ('full',),
         'last differential': ('differential',), 'last log': ('log',), 'log age': ('log',), 'last run': ('outcome', 'last outcome'),
         'value': ('severity', 'check'), 'role': ('severity',), 'index': ('severity',), 'database': ('severity',), 'object': ('severity',)}
def audit(key, name, x, cx, g, sst):
    # every drawn cell against the screen: its own colour, a colour carried from its row, a link's fill and text, else no fill
    cells = cells_of(x, sst); n = dict.fromkeys(['ok', 'warn', 'crit', 'none', 'ack', 'carried', 'link', 'plain', 'class'], 0); wrong = []
    for i, row in enumerate(g['cells']):
        for j, c in enumerate(row):
            sid = cells.get((i + 2, j), (0, None, None))[0]
            f, fo = (cx[sid]['fill'], cx[sid]['font']) if sid < len(cx) else ('?', '?')
            at = f"{colname(j)}{i + 2}"
            if c['s']:
                if f == fill[c['s']] and fo == font[c['s']]: n[c['s']] += 1; n['class'] += 1 if c.get('b') else 0
                else: wrong.append(f"{at} {c['s']} on screen, fill {f} text {fo}")
            elif f in fill.values():
                head = g['head'][j] if j < len(g['head']) else ''
                judges = [row[g['head'].index(h)] for h in PAIRS.get(head, ()) if h in g['head'] and g['head'].index(h) < len(row)]
                if c['t'] != '' and any(q['s'] and fill[q['s']] == f for q in judges): n['carried'] += 1
                else: wrong.append(f"{at} ('{head}') fill {f}: no judging cell of its row shows that colour")
            elif c['l']:
                if f == LINKFILL and fo == LINK: n['link'] += 1
                else: wrong.append(f"{at} a link on screen, fill {f} text {fo}")
            elif f is None and fo is None: n['plain'] += 1
            else: wrong.append(f"{at} plain on screen, fill {f} text {fo}")
    total = sum(len(r) for r in g['cells'])
    # the read returned the rows the page draws: all of them, or a long grid's first 200
    check(len(g['cells']) == min(g['rows'], 200), f"{key}: sheet '{name}' the screen read returned {len(g['cells'])} rows of the grid's {g['rows']} (the page draws at most 200)")
    filled = n['ok'] + n['warn'] + n['crit'] + n['none'] + n['ack'] + n['carried']
    check(not wrong, f"{key}: sheet '{name}' every drawn cell in the screen's colour ({total} cells of {len(g['cells'])} rows; {len(wrong)} wrong {wrong[:3]})")
    print(f"     cells: {key} '{name}': {total} body cells, {filled} with a status fill (ok {n['ok']}, warn {n['warn']}, crit {n['crit']}, none {n['none']}, ack {n['ack']}, carried from the row {n['carried']}), {n['link']} link cells, {n['plain']} plain with no fill")
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
def sheets_of(z):
    wb = z.read('xl/workbook.xml').decode()
    return [n.replace('&amp;', '&') for n in re.findall(r'<sheet name="([^"]*)"', wb)]
def xfs(z):
    st = z.read('xl/styles.xml').decode()
    fills = re.findall(r'<fill>(.*?)</fill>', re.search(r'<fills[^>]*>(.*?)</fills>', st).group(1))
    cx = re.findall(r'<xf ([^>]*)/>', re.search(r'<cellXfs[^>]*>(.*?)</cellXfs>', st).group(1))
    fonts = re.findall(r'<font>(.*?)</font>', re.search(r'<fonts[^>]*>(.*?)</fonts>', st).group(1))
    out = []
    for a in cx:
        g = lambda k: int(re.search(k + r'="(\d+)"', a).group(1))
        f = re.search(r'rgb="(\w+)"', fills[g('fillId')])
        fo = fonts[g('fontId')]; c = re.search(r'rgb="(\w+)"', fo)
        out.append({'fmt': g('numFmtId'), 'fill': f.group(1) if f else None, 'font': c.group(1) if c else None, 'bold': '<b/>' in fo})
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
def stamp(n, inst, tab, ext):
    return re.fullmatch(re.escape(inst) + '_' + re.escape(tab) + r'_\d{8}-\d{4}_\d{8}-\d{4}' + re.escape(ext), n) is not None
# P03: the column widths as DBA Dash's writer sets them (export.ts colWidth: ClosedXML's AdjustToContents, Carlito's
# advance widths, a header 1.0286 x its bold text + 22.19 px, another cell 1.0738 x its text + 0.52 px, whole pixels,
# width = (px - 0.025625) / 7, at most 150). The advance tables are read from export.ts (the local DBA Dash comparison,
# proof-export-dbadash.py, grades them against DBA Dash's own widths); this re-measures every column of every sheet.
SRC = open('web/src/export.ts').read()
ADV = [int(x) for x in re.search(r'const ADV = \[([^\]]*)\]', SRC).group(1).split(',')]
ADV_B = [int(x) for x in re.search(r'const ADV_B = \[([^\]]*)\]', SRC).group(1).split(',')]
def tpx(t, bold):
    a = ADV_B if bold else ADV; u = 0
    for ch in t:
        c = ord(ch); u += a[c - 32] if 32 <= c <= 126 else 2048 if c >= 0x2e80 else (1030 if bold else 1013)
        if u * 11 * 96 / 72 / 2048 > 1200: break
    return u * 11 * 96 / 72 / 2048
import datetime
def shown_py(val, text, fmt):
    if text is not None: return max(re.split(r'\r?\n', text), key=len) if text else ''
    if val is None: return ''
    if fmt == 168: return (datetime.datetime(1899, 12, 30) + datetime.timedelta(seconds=round(val * 86400))).strftime('%Y-%m-%d %H:%M')
    if fmt == 167: return f'{val * 100:.1f}%'
    if fmt == 165: return f'{round(val):,} B'
    if fmt == 169: return f'{round(val):,} s'
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
def width_audit(x, cx, sst):
    # every column: the width the rule gives its cells (a bold cell measured as a header), within one pixel (1/7)
    cells = cells_of(x, sst); ws = widths_of(x); cols = {}
    for (r, c), (sid, val, text) in cells.items():
        t = shown_py(val, text, cx[sid]['fmt'] if sid < len(cx) else 0)
        if not t: continue
        bold = sid < len(cx) and cx[sid]['bold']
        px = 1.0286 * tpx(t, True) + 22.19 if bold else 1.0738 * tpx(t, False) + 0.52
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
iname = re.sub(r'[^A-Za-z0-9._-]+', '-', d['instance'])
if openpyxl is None:
    skipped('lib', "python3 has no openpyxl (PGVIGIL_PYLIB names a folder that holds it): no workbook was opened by a spreadsheet library")
for key, tab, inst in (('summary', 'Summary', 'fleet'), ('backups', 'Backups', 'fleet'), ('jobs', 'Jobs', 'fleet'), ('storage', 'Storage', 'fleet'), ('drives', 'Drives', 'fleet'), ('dbspace', 'DB-Space', 'fleet'), ('dbfiles', 'Files', 'fleet'), ('tables', 'Tables', iname), ('roles', 'Roles', iname),
                       ('activity', 'Running-queries', iname), ('slow', 'Slow-queries', 'fleet'), ('perf', 'Performance-summary', 'fleet'), ('db', 'Database', iname), ('empty', 'Tables', iname)):
    p = d[key]; gs = grids(p)
    check(stamp(p['xlsx'], inst, tab, '.xlsx'), f"{key}: the workbook's name {p['xlsx']}")
    z = zipfile.ZipFile(f"{dl}/{p['xlsx']}")
    names = sheets_of(z)
    check(names[0] == 'Summary' and len(names) == len(gs) + 1, f"{key}: sheets {names} = Summary + {len(gs)} grid(s)")
    st, cx = xfs(z)
    ct = z.read('[Content_Types].xml').decode(); wbx = z.read('xl/workbook.xml').decode(); tabs = []; linked = False; classed = 0; sst = shared(z)
    for i, g in enumerate(gs):
        x, n = sheet_rows(z, i + 2)
        check('<pane' not in x, f"{key}: sheet '{names[i + 1]}' no frozen pane (DBA Dash's)")
        nw, woff = width_audit(x, cx, sst)
        check(nw >= max(1, len(g['head'])) and not woff, f"{key}: sheet '{names[i + 1]}' {nw} column widths by DBA Dash's rule, none over 150 ({len(woff)} off {woff[:3]})")
        check(n == g['rows'], f"{key}: sheet '{names[i + 1]}' {n} data rows = {g['rows']} on screen")
        counts, cells = audit(key, names[i + 1], x, cx, g, sst)
        classed += counts['class']
        rels = f'xl/worksheets/_rels/sheet{i + 2}.xml.rels'
        if g['rows'] == 0:
            check('<autoFilter ref="A1:' in x and '<tableParts' not in x and rels not in z.namelist() and '_xlnm._FilterDatabase' in wbx, f"{key}: sheet '{names[i + 1]}' has no rows: the plain filter, no Excel table")
        else:
            rel = z.read(rels).decode() if rels in z.namelist() else ''
            m = re.search(r'Target="\.\./tables/(table\d+\.xml)"', rel)
            tx = z.read('xl/tables/' + m.group(1)).decode() if m and 'xl/tables/' + m.group(1) in z.namelist() else ''
            check('<tableParts count="1"><tablePart r:id="rId1"/></tableParts>' in x and '<autoFilter' not in x and bool(tx), f"{key}: sheet '{names[i + 1]}' names one table part, no sheet filter beside it")
            check('<tableStyleInfo showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/>' in tx and 'tableStyleInfo name=' not in tx, f"{key}: sheet '{names[i + 1]}' its table has DBA Dash's style info (no style name, row stripes 1: none drawn)")
            ncol = max([len(g['head'])] + [len(r) for r in g['cells']])
            ref = f"A1:{colname(ncol - 1)}{g['rows'] + 1}"
            got = [(re.search(a, b) or [None, None])[1] for a, b in ((r'<table [^>]*\bref="([^"]+)"', tx), (r'<autoFilter ref="([^"]+)"', tx), (r'<dimension ref="([^"]+)"', x))]
            check(got == [ref, ref, ref], f"{key}: sheet '{names[i + 1]}' the table's ref, its filter's and the sheet's dimension are {ref} ({got})")
            cols = [unesc(c) for c in re.findall(r'<tableColumn id="\d+" name="([^"]*)"', tx)]
            hdr = [cells.get((1, j), (0, None, None))[2] for j in range(ncol)]
            check(len(cols) == ncol and all(cols) and len({c.lower() for c in cols}) == ncol and cols == hdr and f'<tableColumns count="{ncol}">' in tx,
                  f"{key}: sheet '{names[i + 1]}' {len(cols)} table columns, each named once, = the header cells")
            row1x = (re.search(r'<row r="1"[^>]*>(.*?)</row>', x, re.S) or [None, ''])[1]
            check(row1x.count(' t="s"><v>') == ncol and 'inlineStr' not in row1x and 'sharedStrings+xml' in ct, f"{key}: sheet '{names[i + 1]}' its {ncol} header cells are shared strings")
            check(all(c == h for c, h in zip(cols, g['head']) if h and g['head'].count(h) == 1), f"{key}: sheet '{names[i + 1]}' the header cells are the screen's headings")
            tabs.append((re.search(r'<table [^>]*\bid="(\d+)"', tx) or [0, ''])[1] + '|' + (re.search(r'displayName="([^"]+)"', tx) or [0, ''])[1])
            check(bool(m) and f'PartName="/xl/tables/{m.group(1)}" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"' in ct, f"{key}: sheet '{names[i + 1]}' its table part is in [Content_Types].xml")
        if key == 'summary' and g['rows'] > 1 and any(c['l'] and not c['s'] for r in g['cells'] for c in r):
            check(counts['link'] >= 1 and counts['plain'] >= 1, f"summary: sheet '{names[i + 1]}' a link cell is filled {LINKFILL} with text {LINK} and a plain cell has no fill ({counts['link']} link cells, {counts['plain']} plain)")
            linked = True
        if key == 'backups' and 'archiver' in g['head'] and g['rows'] > 0: carried(key, names[i + 1], g, cells, cx, 'archiver', 'last archived', ['crit', 'ok'])
        if key == 'jobs' and 'last run' in g['head'] and g['rows'] > 0: carried(key, names[i + 1], g, cells, cx, 'last run', 'last start', [])
        if key == 'storage' and 'free' in g['head'] and g['rows'] > 0:
            j = g['head'].index('free'); seen = [(number(r[j]['t']), cells.get((k + 2, j), (0, None, None))) for k, r in enumerate(g['cells']) if r[j]['t'] != '']
            off = [(a, b) for a, b in seen if a is None or b[1] is None or cx[b[0]]['fmt'] != 167 or abs(b[1] * 100 - a) > 0.006]
            check(len(seen) >= 1 and not off and 'numFmtId="167" formatCode="0.0%"' in st, f"storage: sheet '{names[i + 1]}' {len(seen)} 'free' cells, each the screen's percent / 100 under numFmt 167 '0.0%' (DBA Dash's) ({off[:2]})")
    check(len(set(tabs)) == len(tabs) and all(re.fullmatch(r'\d+\|Table\d+', t) for t in tabs), f"{key}: {len(tabs)} table(s), ids and names unique in the workbook")
    if key == 'summary':
        check(linked, "summary: a grid with link cells (the instance names) was graded for the link's fill and text and for the plain cells' no fill")
        check(names == ['Summary', 'Summary (2)', 'Summary (3)'], f"summary: the two grids are named by the page's own heading, not by the Needs attention strip's ({names})")
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
            # the GB columns are numbers in the workbook (the page shows the GB figure with fmtNum); a used cell left as
            # text is only 'not read' (a PostgreSQL instance)
            sx = z.read('xl/worksheets/sheet2.xml').decode(); g0 = gs[0]
            check(g0['head'][1:3] == ['allocated (GB)', 'used (GB)'], f"dbspace: the grid's columns 2 and 3 are allocated (GB) and used (GB) ({g0['head'][:4]})")
            alloc = [k for r, k in re.findall(r'<c r="B(\d+)"[^>]*?(/>|><v>|t="inlineStr")', sx) if r != '1']
            check(len(alloc) == g0['rows'] and sum(k == '><v>' for k in alloc) >= 1 and not any(k == 't="inlineStr"' for k in alloc), f"dbspace: allocated (GB) numeric in {sum(k == '><v>' for k in alloc)} of {g0['rows']} rows, none as text")
            used_text = re.findall(r'<c r="C(\d+)"[^>]*t="inlineStr"><is><t[^>]*>([^<]*)</t>', sx)
            used_num = [r for r, k in re.findall(r'<c r="C(\d+)"[^>]*?(/>|><v>|t="inlineStr")', sx) if r != '1' and k == '><v>']
            check(len(used_num) >= 1 and all(t in ('not read', '') for r, t in used_text if r != '1'), f"dbspace: used (GB) numeric in {len(used_num)} rows, its text cells only 'not read' ({sorted({t for r, t in used_text if r != '1'})[:3]})")
    if key == 'perf':
        hg = [(i, g) for i, g in enumerate(gs) if 'CPU histogram' in g['head'] and g['rows'] > 0]
        if hg:
            i, g0 = hg[0]; j = g0['head'].index('CPU histogram'); px_ = sheet_rows(z, i + 2)[0]; cc = cells_of(px_, sst)
            filled = [k for k in range(len(g0['cells'])) if cx[cc.get((k + 2, j), (0, None, None))[0]]['fill'] is not None]
        check(bool(hg) and not filled, f"perf: the CPU histogram column has no fill in any of its rows (a picture, no status; {len(filled) if hg else 'no grid'} filled)")
    if key == 'empty':
        tg = [g for g in gs if not g.get('empty')]   # the Tables tab's grids with a table: the filtered one is the last
        check(tg[-1]['rows'] == 0 and len(tg) > 1 and tg[0]['rows'] > 0, f"empty: the last grid is filtered to no rows, the first keeps its rows ({[g['rows'] for g in gs]})")
        check(classed == 2, f"empty: the two cells that carry only a class of the page's own rule (crit, warn) are filled in their colours ({classed} cells)")
    if openpyxl is not None:
        try:
            wb = openpyxl.load_workbook(f"{dl}/{p['xlsx']}")
            check(wb.sheetnames == names and sum(len(ws.tables) for ws in wb.worksheets) == len(tabs), f"{key}: openpyxl {openpyxl.__version__} opens the workbook: {len(wb.sheetnames)} sheets, {len(tabs)} table(s)")
        except Exception as e:
            check(False, f"{key}: openpyxl could not open {p['xlsx']}: {type(e).__name__}: {e}")
    for i, g in enumerate(gs):
        x, n = sheet_rows(z, i + 2)
        for s in g.get('status', []):
            used = {int(v) for v in re.findall(r' s="(\d+)"', x)}
            check(any(cx[u]['fill'] == fill[s] and cx[u]['font'] == font[s] for u in used if u < len(cx)), f"{key}: '{s}' cells filled {fill[s]} with text {font[s]} in '{names[i + 1]}'")
            check(not any(cx[u]['fill'] == fill[s] and cx[u]['bold'] for u in used if u < len(cx)), f"{key}: '{s}' cells in '{names[i + 1]}' in a plain font, not bold (DBA Dash's)")
        row1 = re.search(r'<row r="1"[^>]*>(.*?)</row>', x, re.S)
        hs1 = {int(v) for v in re.findall(r' s="(\d+)"', row1.group(1))} if row1 else set()
        check(bool(hs1) and all(u < len(cx) and cx[u]['fill'] == 'FF0063A3' and cx[u]['font'] == 'FFFFFFFF' and cx[u]['bold'] for u in hs1), f"{key}: sheet '{names[i + 1]}' header row filled FF0063A3, white bold")
    # each sheet named by the heading above its grid (h2, h3 or h4): the name starts with the heading's first words
    # (cut at 31 characters, a repeat numbered; the Summary grid's heading meets the export's own Summary sheet)
    # (the export's rule: a character Excel refuses becomes a space, then each run of spaces one space)
    hs = [re.sub(r'\s+', ' ', re.sub(r'[\\/?*\[\]:]', ' ', g['name'])).strip()[:24].rstrip() for g in gs]
    check(all(n.startswith(h) for n, h in zip(names[1:], hs)), f"{key}: sheet names {names[1:]} follow the screen's headings {[g['name'] for g in gs]}")
    if key == 'roles':
        check(any(g['name'].endswith('privileges') or 'privileges' in g['name'] for g in gs), "roles: a grid under a privileges (h4) heading on screen")
    if key == 'tables':
        check(names[1:] == [g['name'] for g in gs], f"tables: sheet names {names[1:]} = the screen's headings {[g['name'] for g in gs]}")
        x = ''.join(z.read(f'xl/worksheets/sheet{i + 2}.xml').decode() for i in range(len(gs)))
        nums = {int(s) for s in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>', x)}
        for f, what in ((165, 'bytes'), (168, "a time, DBA Dash's 'yyyy-MM-dd HH:mm'"), (0, "a count, General as DBA Dash writes one")):
            check(any(cx[s]['fmt'] == f for s in nums), f"tables: a numeric cell with numFmt {f} ({what})")
        check('numFmtId="165" formatCode="#,##0&quot; B&quot;"' in st and 'numFmtId="168" formatCode="yyyy-MM-dd HH:mm"' in st and 'formatCode="#,##0"' not in st and 'formatCode="#,##0.00"' not in st,
              "tables: numFmt 165 is '#,##0\" B\"', 168 'yyyy-MM-dd HH:mm'; no '#,##0' or '#,##0.00' (a count or a decimal is General)")
        last = z.read(f'xl/worksheets/sheet{len(gs) + 1}.xml').decode()
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
    first = z.read('xl/worksheets/sheet1.xml').decode()
    # the Summary sheet is formatted too: its header row and the heading of its list of sheets in the header's blue
    f1 = cells_of(first); heads1 = [k for k, v in f1.items() if v[2] in ('Item', 'Value', 'Note', 'Sheet', 'Rows')]
    check(len(heads1) == 6 and all(cx[f1[k][0]]['fill'] == 'FF0063A3' and cx[f1[k][0]]['font'] == 'FFFFFFFF' and cx[f1[k][0]]['bold'] for k in heads1)
          and '<pane' not in first and '<tableParts' not in first, f"{key}: the Summary sheet's header row and its 'Sheet | Rows | Note' line are filled FF0063A3 with white bold text ({len(heads1)} cells)")
    check('>Time zone<' in first and re.search(r'\(UTC[-+]\d\d:\d\d at export\)', first) is not None, f"{key}: the Summary sheet has a Time zone row with the offset at export")
    if key == 'activity':
        i = next((i for i, g in enumerate(gs) if g['name'] == 'Per sample'), None)
        check(i is not None and gs[i]['rows'] == 500, f"activity: the Per sample grid shows 500 rows on screen ({gs[i]['rows'] if i is not None else 'no grid'})")
        row = re.search(r'<row r="\d+"><c [^>]*><is><t[^>]*>Per sample</t></is></c><c [^>]*><v>(\d+)</v></c><c [^>]*><is><t[^>]*>([^<]*)</t>', first)
        check(row is not None and row.group(1) == '500' and re.search(r'newest 500 of [\d,.\s\u202f\u00a0]*\d', row.group(2)) is not None, f"activity: the Summary's Per sample row carries the 'newest 500 of N' note ({row.group(2)[:60] if row else 'none'})")
    if key == 'slow':
        i = next((i for i, g in enumerate(gs) if g['name'].startswith('Per day')), None)
        check(i is not None and gs[i]['rows'] >= 1, f"slow: a Per day table with rows on screen ({gs[i]['rows'] if i is not None else 'no grid'})")
        if i is not None:
            x = z.read(f'xl/worksheets/sheet{i + 2}.xml').decode()
            cnt = re.findall(r'<c r="C(\d+)"[^>]*?(/>|><v>|t="inlineStr")', x)
            numeric = [r for r, k in cnt if r != '1' and k == '><v>']
            check(len(numeric) == gs[i]['rows'], f"slow: Per day's statements column (no page model): {len(numeric)} of {gs[i]['rows']} rows numeric")
    # every page: a duration ('x ms', 'x s', 'x min') is never left as text in any sheet, whichever tab's formatter wrote it
    allx = ''.join(z.read(f'xl/worksheets/sheet{j + 2}.xml').decode() for j in range(len(gs)))
    texts = [t for t in re.findall(r't="inlineStr"><is><t[^>]*>([^<]*)</t>', allx) if re.fullmatch(r'[\d\s,.\u202f\u00a0]+ (ms|s|min)', t)]
    check(not texts, f"{key}: no duration left as text ({texts[:3]})")
    if key in ('slow', 'db'):
        nums = {int(s) for s in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>', allx)}
        check(any(cx[s]['fmt'] == 170 for s in nums), f"{key}: a duration cell with numFmt 170 (ms)")
        check('numFmtId="170" formatCode="#,##0.###&quot; ms&quot;"' in st, f"{key}: numFmt 170 is '#,##0.###\" ms\"'")
    if key == 'db':
        # the statements grid: a column whose cells carry numFmt 170 holds a value under 1 ms and one at 1,000 ms or more
        vals = [float(v) for sid, v in re.findall(r'<c r="[A-Z]+\d+" s="(\d+)"><v>([^<]*)</v>', allx) if cx[int(sid)]['fmt'] == 170]
        check(any(v < 1 for v in vals) and any(v >= 1000 for v in vals), f"db: millisecond values under 1 ms and from 1,000 ms up are both numbers ({len(vals)} cells, min {min(vals) if vals else '-'}, max {max(vals) if vals else '-'})")
    # CSV
    if p['csv'].endswith('.csv.zip'):
        cz = zipfile.ZipFile(f"{dl}/{p['csv']}")
        parts = sorted(cz.namelist())
        check(len(parts) == len(gs), f"{key}: {len(parts)} CSV(s) in {p['csv']} = {len(gs)} grid(s)")
        blobs = [cz.read(n) for n in parts]
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

# ---- P03: the new menu items, each clicked, each download read --------------------------------------------------
def one_book(key, fname, inst, tab, sheet, g):
    # a workbook of one grid: its name, Summary + one sheet named so, the grid's rows, every cell in the screen's colour,
    # the widths by the rule, no pane; returns the zip
    check(stamp(fname, inst, tab + '_' + re.sub(r'[^A-Za-z0-9._-]+', '-', sheet).strip('-'), '.xlsx'), f"{key}: the workbook's name {fname}")
    z = zipfile.ZipFile(f"{dl}/{fname}"); names = sheets_of(z); st, cx = xfs(z); sst = shared(z)
    check(names == ['Summary', sheet], f"{key}: sheets {names} = Summary + '{sheet}'")
    x, n = sheet_rows(z, 2)
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
check('Export Excel' in its and its.index('Export Excel') == lastcopy + 1 and sum(1 for x in its if x.startswith('Export Excel')) == 1, f"gridmenu: the grid's menu has one Export Excel, right after its copies, as DBA Dash's grid menu ({its})")
if gm.get('xlsx'):
    g = gm['screen']
    # export.ts sheetNames for one name: Excel's refused characters a space, the quotes at either end off, runs of spaces
    # one, cut at 31 (a trailing space or quote off), 'Summary' and 'History' (reserved) numbered
    sheet = re.sub(r'\s+', ' ', re.sub(r"^'+|'+$", '', re.sub(r'[\\/?*\[\]:]', ' ', g['named']))).strip()[:31].rstrip(" '") or 'Sheet'
    one_book('gridmenu', gm['xlsx'], 'fleet', 'Backups', sheet + ' (2)' if sheet.lower() in ('summary', 'history') else sheet, g)
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
for kind in ('line', 'ring'):
    c = ch.get(kind)
    check(bool(c), f"charts: a {kind} chart's menu was found and its Export Excel clicked ({sorted(ch)})")
    if not c: continue
    check('Export Excel' in c['items'], f"charts: the {kind} chart '{c['title']}' menu {c['items']}")
    z = zipfile.ZipFile(f"{dl}/{c['xlsx']}"); names = sheets_of(z); st, cx = xfs(z); sst = shared(z)
    x, n = sheet_rows(z, 2); cells = cells_of(x, sst)
    m = re.search(r'Saved (\d+) (points|slices) as Excel', c['said'] or '')
    hdr = [cells.get((1, j), (0, None, None))[2] for j in range(3)]
    check(len(names) == 2 and names[0] == 'Summary' and m is not None and int(m.group(1)) == n and n >= 1, f"charts: the {kind} chart '{c['title']}' workbook {c['xlsx']}: sheets {names}, {n} rows = the menu's word ({c['said']!r})")
    nw, woff = width_audit(x, cx, sst)
    check(not woff, f"charts: the {kind} chart's sheet widths by the rule ({woff[:3]})")
    if kind == 'line':
        t = [cells.get((r, 0)) for r in range(2, n + 2)]
        check(hdr[0] == 'time' and all(v and v[1] is not None and cx[v[0]]['fmt'] == 168 for v in t), f"charts: the line chart's first column is 'time', every point a time under 'yyyy-MM-dd HH:mm' ({hdr})")
    else:
        sh = [cells.get((r, 2)) for r in range(2, n + 2)]
        tot = sum(v[1] for v in sh if v and v[1] is not None)
        check(hdr == ['name', 'size', 'share'] and all(v and cx[v[0]]['fmt'] == 167 for v in sh) and abs(tot - 1) < 1e-6, f"charts: the ring's sheet is name / size / share, every share under '0.0%', adding up to 1 ({hdr}, {tot})")
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
    z2 = zipfile.ZipFile(f"{dl}/{t['xlsx']}"); x2 = z2.read('xl/worksheets/sheet2.xml').decode(); c2 = cells_of(x2, shared(z2))
    hdr2 = [c2.get((1, j), (0, None, None))[2] for j in range(len(head))]
    tx2 = z2.read('xl/tables/table1.xml').decode()
    check('platform' in head and hdr2 == [x for x in head if x != 'platform'] + [None] and f'<tableColumns count="{len(head) - 1}">' in tx2 and 'name="platform"' not in tx2,
          f"tools: the workbook exported with the column hidden has no platform column ({len([x for x in hdr2 if x])} of the grid's {len(head)} columns, the table too)")
    ch = t.get('chooser') or {}
    check(ch.get('cols') == len(head) and ch.get('unticked') == 1 and ch.get('label') == 'Columns of this grid', f"tools: 'Columns...' lists the {len(head)} columns, the hidden one unticked ({ch})")
    rs = t['reset']
    check(rs['hidden']['marked'] == 0 and rs['hidden']['keys'] == [] and rs['hidden']['td'] != 'none' and not rs['frozen']['on'] and rs['bars'] == 0 and t.get('closed') is True,
          f"tools: 'Reset this grid' brings every column back, unfreezes, drops the bars and forgets the choice; 'Close' closes the panel ({rs['hidden']}, frozen {rs['frozen']['on']}, bars {rs['bars']})")
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
  node "$WORK/drive.mjs" "$CDP" "http://127.0.0.1:$PORT/" "$DL" > "$WORK/drive-$L.json" || fail "the driver failed ($L)"
  ok "downloaded ($L): $(cd "$DL" && ls | tr '\n' ' ')"
  echo "== the files read back ($L)"
  python3 -I "$WORK/check.py" "$WORK/drive-$L.json" "$DL" "$L" || fail "a file did not match its page ($L)"
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
echo "OK: fourteen pages exported to .xlsx and CSV in two languages, each file matching its page cell by cell (every grid with rows an Excel table, DBA Dash's formats and widths); a grid's menu, the Summary's drop-down and two charts' menus exported with Export Excel"
