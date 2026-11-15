// The menus' browser check (task 172): the tree's right-click menus, their keyboard (the context-menu key, Shift+F10,
// the arrows into and out of a submenu, Escape back to the node), each item doing what DBA Dash's shot shows, the drive
// nodes' used-space bars, the grids' cell-menu lines (Select, Filter by value, Exclude value, Clear filters, 'Rows |
// Cols' and the Sum / Avg / Min / Max line; the grid's Export Excel is export.ts's, after the copy lines), the Tools menu's file opening by the picker, a drop and a
// paste, and the Data Retention page against a hand read of the repository.
//   PGVIGIL_ADMIN_DSN="host=... user=..." node scripts/menu-check.mjs
// Self-contained: it builds the binary (the web bundle internal/web/dist/app.js must be built first), seeds the demo
// into a throwaway database, serves it on loopback, starts a headless Chromium, and removes all three at the end (a
// killed run too: SIGINT / SIGTERM drop the database by name). Needs go, psql, chromium, node 22+.
//   PGVIGIL_DEMO_WAIT_S  seconds to wait for the seeded demo (default 240)
//   PGVIGIL_MENU_SHOTS   a folder: a picture of each menu, light and dark, is saved there
//   PGVIGIL_MENU_ONLY    the cases to run, by name prefix, comma-separated ('G': the grid menu's; scripts/proof-gridmenu.sh)
// Prints one 'ok <case>: ...' or 'FAIL <case>: ...' line per case and 'PASS' / 'FAIL' last; exit 1 on a failed case.
//
// Expected (written before the first run; the cases marked (run 3) rewritten after review s172-1, before run 3):
//   R1 root menu      'Refresh|Add Connections...|Find Database|Open in a new tab' on a right-click of 'All instances'; role
//                     menu, each item menuitem (run 3)
//   R2 refresh        on About (no live page): no /api/instances read in 1.5 s alone, a new one after Refresh (run 3)
//   R3 add            Add Connections: name sql09, SQL Server, env PGVIGIL_DSN_SQL09 -> the lines '  - name: sql09',
//                     '    engine: sqlserver', '    dsn: env:PGVIGIL_DSN_SQL09'; SQL Server's platforms
//                     'auto,onprem,rds,azuresqldb,azuresqlmi,cloudsql' (cloudsql: Google Cloud SQL for SQL Server,
//                     config.go's SQL Server platforms); a name already in the fleet said so (run 3)
//   R4 find           'a' refused (two characters); 'erp' and 'sales': exactly the search API's database rows plus the
//                     SQL Server databases read by hand from each instance's storage read, every link holding the text,
//                     'sales' with a link to a SQL Server instance's Database files; 'billing', one exact name: its page
//                     with i= its instance exactly; erp01's own Find Database 'er': its own database list by hand (run 3)
//   I1 instance menu  'Find Database|Refresh|Instance Actions|Open in a new tab'; Instance Actions has
//                     'Pause/Resume Collections...|Configure Schedule...|Connection Options...|Add Alert Blackout...'
//   I2 pause/resume   one row per /api/instance/collections row; unticking the first running one -> 'disabled: [...]' =
//                     the ones off before (not opt-in) and it; the opt-in collections (default 0) not tickable (run 3)
//   I3 schedule       '15m' typed for the first collection -> 'schedules:' and '<it>: 15m'; '5x', '0m', '30s',
//                     '9999999999h' refused (run 3)
//   I4 connection     the instance's name in the grid and '  - name: <name>' in the lines
//   I5 blackout       Add Alert Blackout... -> the dialog "Blackout '<name>'" with a start and an end (two date-time
//                     inputs), or the read-only reason (run 3: read from the last dialog opened)
//   K  keyboard       Shift+F10 and the ContextMenu key on the focused instance node open its menu with the focus on its
//                     first item; Instance Actions aria-haspopup menu, expanded false; Down, Down, Right opens it with the
//                     focus on its first item, expanded true; Left closes it, the focus on 'Instance Actions', expanded
//                     false; Escape closes the menu with the focus on the node (run 3: the aria states)
//   F  folder         the Jobs folder of a pg_cron instance: 'Filter|Refresh|Open in a new tab'; Filter by a part of one
//                     job's name -> 'Filter "<part>": k of n...' with k = the drawn jobs whose names hold it, those k shown,
//                     the rest hidden, none shown without it (run 3)
//   J  job            'Job Info|Configure Thresholds|Start/Stop Job|Refresh|Open in a new tab'; Job Info -> the leaf's own
//                     href exactly (run 3); Start/Stop Job -> 'Execute Job - <name>' with Start off (pg_cron has no run-now
//                     call) and Stop off (not running, or actions off), each saying why; Configure Thresholds ->
//                     'Job thresholds: <name>'
//   D2 drive history  a drive's History on onprem-sql01's Drives page (2026-11-12: the chart was fixed at 30 days with no
//                     way to change it; then: 5 minutes to one year): a window picker of twelve windows in minutes
//                     '5|15|30|60|360|1440|2880|10080|43200|129600|259200|525600' standing at 43200 and the chart 'over 30
//                     days'; 90 days picked -> a read of /api/drives/history with minutes=129600, the chart 'over 90 days'
//                     DRAWN (its first point over 80 % of the window back: the demo holds a year of volume reads) under a
//                     line 'N reads over ... of history'; 5 minutes -> minutes=5, the title 'over 5 minutes' and the line
//                     that says why no line is drawn ('This window holds no read|one read, so no line is drawn. This
//                     drive is read about every 60 minutes ...': a SQL Server volume is read hourly, the interval the
//                     upper median of its newest gaps; said once - no second 'a chart needs two'; two reads in the 5
//                     minutes, asked of the API first: their chart and '2 reads over'); 1 year as 90 days, with
//                     minutes=525600 (review fold: each point under its own read time); the pick kept in the
//                     browser (pgvigil.driveHistoryMinutes = 525600) and READ BACK: the History closed and opened again
//                     stands at 525600 under 'over 1 year'
//   W  pg words       a PostgreSQL instance's own Summary (demo-cloudsql-analytics01, the demo's all-OK instance) names
//                     no SQL Server-only check in its counts line - 'Every check group is OK.' or 'no sample for:' with
//                     only cells that have no read, never QS, SQL Agent Alerts, Backup DIFF ... (review 20261112-191720:
//                     the n/a cells of the other engine were listed there)
//   D  drives         under onprem-sql01's Storage folder one node per volume of /api/mssql/storage (total > 0), each with
//                     a bar whose width is its used share (within 0.2 %) in the colour of its free share (ok / warn under
//                     20 % / crit under 10 %), its visible words '... free (n %)', its title '... free of ...' (run 3)
//   G  grid menu      (task 172's flat menu) retired by task GM: its rows are now G-select, G-menu, G-filters and G-file
//   T  tools          the bar's Tools: 'Open Deadlock Graph | *.xdl|Open Query Plan | *.sqlplan|Open Grid or Data Set |
//                     *.json;*.csv;*.gz', the button aria-expanded true; the picker given dl.xdl -> 'Deadlock graph: dl.xdl',
//                     an svg, 2 sessions with 'Session 55' the victim, 2 locked resources; a right-click in its grid opens the
//                     grid menu inside the dialog with the focus in it (run 3); the picker given a UTF-16 p16.sqlplan
//                     (SSMS's own encoding, a byte-order mark) -> 'Query plan: p16.sqlplan' with its 3 operators
//   X  drop / paste   a real drag (CDP dragEnter, dragOver, drop) of p.sqlplan -> 'Query plan: p.sqlplan', 3 operators,
//                     parents '', 0, 0, cost % 20 / 20 / 60 with the lookup's warning, 1 missing index of impact 81.5 (run 3:
//                     the real drag); a deadlock graph pasted into the tree's search field opens nothing, pasted on the
//                     page -> 'Deadlock graph: pasted deadlock graph'; a dropped rows.json -> 'Grid: rows.json', 3 rows
//   RT retention      (run 3: an activity_sample partition three months back made first) the page's rows = the hand count
//                     of schema pgvigil's tables; activity_sample's size = its partitions' and its own pg_total_relation_size
//                     by hand, 'monthly partitions', the partitions a purge at 1 day drops = the hand count of its months
//                     by purge()'s rule (1 or more), on the page too; mssql_requests 'daily partitions' with its days by
//                     hand; job_runs 'rows older than the age' by start_time, judged, its oldest row = min(start_time) by
//                     hand, the page's cells the same; query_text the same as activity_sample, not judged; instances
//                     'kept whole'
//   GM the grid menu at DBA Dash's level (task GM, the design as the pass's fold left it; written before the build, red
//                     first on main 1aba474: every G- row FAIL there but G-chart, case G's own rows ok). Grids: Instances'
//                     (number column 'sessions', text 'platform', unique 'name'), a dropped JSON file's viewer grid (a
//                     modal dialog; the hostile fixture), slow.ts's own table, demo-onprem-sql01's Drives, a statements
//                     grid, an empty one. Contracts: the block's head. Each case:
//   G-menu            a sessions cell: Copy, Export Excel, Export file, Transpose, Select, Columns..., Row numbers, Data bar,
//                     'Filter by value...', 'Exclude value...', All filters, Clear filters in that order, then 'Rows: n |
//                     Cols: m' and '[sessions] Sum: ...'; Copy > Grid | Column | Cell | Row | Selected | As Markdown | As
//                     JSON (DD's order), As Markdown > Standard | Prettified, As JSON > Compact | Prettified, Export file >
//                     CSV | JSON | Markdown | HTML | SQL (INSERT) for PostgreSQL | for SQL Server, Transpose > This row |
//                     Selected rows | Grid, Select > Row | Column | All, Data bar > Behind value | Under value | Traffic
//                     light (higher is worse) | (higher is better) | Remove, All filters > = <> > < >= <= (a text column:
//                     Like | Not like first); Clear filters off with the visible words 'no filter is set'
//   G-select          Select > Column: n cells, the tools' line says so, the menu's last line 'Selected Cells: n (k
//                     numeric) | Sum: ...'; Select > Row: the row's shown cells; a version cell: no Sum line, 'Rows: ...' last
//   G-header          sessions' header: the grid-level items, Hide column / Freeze up to / Group by sessions, Data bar,
//                     its Sum line last; its Copy holds Grid, Column, Selected, As Markdown, As JSON (no Cell, no Row)
//   G-copy            through a stubbed clipboard: Cell; Row ends with the row tab-separated; Column = the shown column;
//                     Selected = a 2x2 rectangle with HTML beside it; Grid = the header and n rows; Markdown n+2 lines,
//                     '| --- |' second, prettified one width; JSON n objects keyed by the shown headers, sessions a number
//                     or null (an empty cell), 'longest active' its seconds; JSON VALUES: a percent shown '12.5 %' is 12.5;
//                     EMPTY: a filter leaving no row turns every Copy item off with 'No data to copy'
//   G-file            Export Excel and each Export file form share one file name stem (oneFile's); CSV the header then n
//                     rows; JSON n objects; Markdown n+2 lines; HTML meta utf-8, a style block with the fills, td classes,
//                     no inline style; PostgreSQL SQL: no BOM (psql reads none), SET standard_conforming_strings = on first,
//                     SET client_encoding = 'UTF8', DROP TABLE IF
//                     EXISTS pg_temp.pgvigil_grid, one CREATE TEMP TABLE, INSERT INTO pg_temp.pgvigil_grid, n value rows,
//                     no N''; SQL Server: a BOM, IF OBJECT_ID('tempdb..#pgvigil_grid') ... DROP, [sessions], every string N''
//   G-hidden          platform hidden: in no copy and no file
//   G-order           sessions descending and '>0': Copy > Column and the CSV in that order
//   G-rownum          Row numbers: a CSS counter, no cell added; kept after a reload; with it on, Hide platform hides
//                     platform, Freeze up to sessions ends at sessions, Filter by value counts right; not in Copy > Grid or
//                     the CSV; off again
//   G-transpose       This row: 'Transposed ...' of the shown columns, name and value, with Copy; Selected rows (2): three
//                     cells a row; Grid on a page over 50 rows: 50 values a row, the cap's reason, its Copy every row
//   G-filters         Filter by value AND Exclude value: the rows by hand; the six operators from a prompt holding the
//                     clicked value; Like / Not like 'a%'; Clear filters off with its words when none; QUOTING on the
//                     fixture: Filter by value 'R & D' = that one row, typed 'R & D' = contains (2 rows), Like's prefill on
//                     pg_stat_statements 'pg\_stat\_statements'
//   G-in              three name cells: Filter by these values = those three rows; Exclude these values = the rest
//   G-bars            Under value a gradient at the bottom; traffic lights in their own classes (no ok / warn / crit /
//                     status), worse and better the colours swapped, kept after a reload, absent from the HTML file; Remove
//   G-keys            Tab lands in the grid (role grid, aria-rowcount n, no other tab stop in its body); Down, Right: the
//                     cell of row 2, column 2; Shift+F10: the menu at it, the focus on Copy; Right, Down, Enter: Copy >
//                     Column, the focus back on the cell; Shift+F10, Escape: the cell; Tab leaves the grid
//   G-grouped         Group by platform: the grid's menu works, Copy > Grid n rows; the group panel's table has a menu
//   G-empty0          a grid empty from the start: Copy items off 'No data to copy', Export Excel on, Columns..., 'Rows: 0'
//   G-dialog          the viewer's grid: the menu inside the dialog, Copy > Cell 'a]b'
//   G-sql             the fixture's two SQL files on the box's PostgreSQL (standard_conforming_strings on, then off, then off
//                     with the file sent as one query as pgAdmin's F5 does) and a SQL Server container (PGVIGIL_MENU_MSSQL /
//                     _ENV; the fixture holds a backslash before a line break and a GO line): every row read back equal, NUL dropped and said,
//                     names "we]ird""name" / column_n, table t intact
//   G-stmt            a statement cell's button: the grid's menu, Copy > Cell the statement
//   G-plain           slow.ts's own table.grid: the menu, Copy > Cell
//   G-mssql           demo-onprem-sql01's Drives grid: the same first level
//   G-chart           a chart's menu unchanged (ui.ts showMenu: Copy image ... Export Excel): green on both sides
//   G-big             a 10,000-row grid's menu opens (.tm-menu); its open time said
//   G-themes          (PGVIGIL_MENU_SHOTS) the menu and the transpose shot light and dark, the menu's background differs
//   S  shots          (run 3) after a reload in the dark theme (data-theme dark): every one of the 15 light and 4 dark
//                     pictures written by this run
const { spawn, execFileSync } = await import('node:child_process');
const fs = await import('node:fs');
const os = await import('node:os');
const path = await import('node:path');

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const dsn = process.env.PGVIGIL_ADMIN_DSN;
if (!dsn) { console.error('FAIL: PGVIGIL_ADMIN_DSN is not set'); process.exit(2); }
const shots = process.env.PGVIGIL_MENU_SHOTS ?? '';
const waitS = Number(process.env.PGVIGIL_DEMO_WAIT_S ?? 240);
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'pgvigil-menu-'));
const db = `pgvigil_menu_${process.pid}`;
const port = 21000 + Math.floor(Math.random() * 9000);
let srv = null, chr = null, done = false;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const started = Date.now();
const psql = (sql, dbname = db) => execFileSync('psql', [`${dsn} dbname=${dbname}`, '-XAtq', '-c', sql], { encoding: 'utf8' }).trim();
// cleanup: on every way out (the end, a crash, Ctrl+C, a kill, a dropped ssh session): the server and Chromium stopped,
// the database dropped by name (a drop that fails fails the run), the work folder removed (Chromium's profile retried
// while its processes finish)
function cleanup() {
  if (done) return; done = true;
  try { srv?.kill('SIGTERM'); } catch { /* gone */ }
  try { chr?.kill('SIGTERM'); } catch { /* gone */ }
  try { psql(`drop database if exists ${db} with (force)`, 'postgres'); } catch (e) { console.error(`FAIL cleanup: the database ${db} was not dropped: ${e.message}`); process.exitCode = 1; }
  try { fs.rmSync(work, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 }); } catch (e) { console.error(`cleanup: ${work} was not removed: ${e.message}`); }
}
process.on('exit', cleanup);
for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) process.on(sig, () => { cleanup(); process.exit(code); });

if (!fs.existsSync(path.join(root, 'internal/web/dist/app.js'))) { console.error('FAIL: internal/web/dist/app.js is missing: build the web bundle first'); process.exit(2); }
console.log(`== build, seed the demo into ${db}, serve on 127.0.0.1:${port}`);
execFileSync('go', ['build', '-o', path.join(work, 'pgvigil'), './cmd/pgvigil'], { cwd: root, env: { ...process.env, CGO_ENABLED: '0' }, stdio: 'inherit' });
psql(`create database ${db}`, 'postgres');
const log = fs.openSync(path.join(work, 'demo.log'), 'w');
srv = spawn(path.join(work, 'pgvigil'), ['demo', '-dsn', `${dsn} dbname=${db}`, '-serve', '-listen', `127.0.0.1:${port}`, '-days', '3'], { stdio: ['ignore', log, log] });
let up = false;
for (let i = 0; i < waitS && !up; i++) { await sleep(1000); up = fs.readFileSync(path.join(work, 'demo.log'), 'utf8').includes('pgvigil demo serving'); if (srv.exitCode !== null) break; }
if (!up) { console.error(fs.readFileSync(path.join(work, 'demo.log'), 'utf8').split('\n').slice(-8).join('\n')); console.error(`FAIL: the demo did not come up in ${waitS} s`); process.exit(1); }
const dl = path.join(work, 'dl'); fs.mkdirSync(dl);
// port 0: Chromium takes a free port and writes it into its profile (DevToolsActivePort), so the check talks to its own
chr = spawn('chromium', ['--headless=new', '--remote-debugging-port=0', `--user-data-dir=${path.join(work, 'chrome')}`, '--no-first-run', '--disable-gpu', 'about:blank'], { stdio: 'ignore' });
let tabs = null, cdp = 0;
for (let i = 0; i < 60 && !tabs; i++) {
  await sleep(500);
  try { cdp = Number(fs.readFileSync(path.join(work, 'chrome', 'DevToolsActivePort'), 'utf8').split('\n')[0]); } catch { continue; }
  tabs = await fetch(`http://127.0.0.1:${cdp}/json`).then(r => r.json()).catch(() => null);
}
if (!tabs) { console.error("FAIL: chromium's CDP port never answered"); process.exit(1); }
const base = `http://127.0.0.1:${port}/`, origin = base.replace(/\/$/, '');

// ---- CDP ----
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl); await new Promise(r => { ws.onopen = r; });
let id = 0; const pend = new Map(), waiters = [];
ws.onmessage = m => {
  const d = JSON.parse(m.data);
  if (d.id && pend.has(d.id)) { const p = pend.get(d.id); clearTimeout(p.timer); pend.delete(d.id); p.resolve(d); return; }
  if (d.method) for (const w of [...waiters]) if (w.method === d.method) { waiters.splice(waiters.indexOf(w), 1); w.resolve(d.params); }
};
// each call answers in 30 s or fails its case; a Chromium that went away fails the run at once
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const i = ++id;
  pend.set(i, { resolve, timer: setTimeout(() => { pend.delete(i); reject(new Error(`${method}: no answer in 30 s`)); }, 30000) });
  ws.send(JSON.stringify({ id: i, method, params }));
});
ws.onclose = () => { if (!done) { console.error('FAIL: the connection to Chromium closed'); process.exit(1); } };
const event = (method, ms = 5000) => new Promise((resolve, reject) => { const w = { method, resolve }; waiters.push(w); setTimeout(() => { const i = waiters.indexOf(w); if (i >= 0) { waiters.splice(i, 1); reject(new Error('no ' + method)); } }, ms); });
const ev = async e => {
  const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true, userGesture: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 500));
  return r.result?.result?.value;
};
let failed = 0;
const check = (name, okay, detail) => { console.log(`${okay ? 'ok  ' : 'FAIL'} ${name}: ${detail}`); if (!okay) failed++; };
// PGVIGIL_MENU_ONLY: the cases whose names start with one of its comma-separated prefixes ('G' = case G and the GM
// cases G-...); unset = every case
const only = (process.env.PGVIGIL_MENU_ONLY ?? '').split(',').map(x => x.trim()).filter(Boolean);
const guard = async (name, f) => {
  if (only.length && !only.some(p => name === p || name.startsWith(p + ' ') || name.startsWith(p + '-'))) return;
  try { await f(); } catch (e) { check(name, false, 'threw: ' + (e instanceof Error ? e.message : String(e)).slice(0, 400)); }
};
await send('Page.enable');
await send('Browser.grantPermissions', { permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'], origin });
await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dl, eventsEnabled: true });
await send('Emulation.setFocusEmulationEnabled', { enabled: true });
await send('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
const go = async h => {
  await send('Page.navigate', { url: base + h });
  for (let i = 0; i < 60; i++) { await sleep(250); if (await ev(`!!document.querySelector('main section, main .grid-box') && !document.querySelector('main > p.empty[role=status]') && !!document.querySelector('#tree .tree-root')`)) break; }
  await sleep(500);
};
const shot = async name => {
  if (!shots) return;
  fs.mkdirSync(shots, { recursive: true });
  const r = await send('Page.captureScreenshot', { format: 'png' });
  if (r.result?.data) fs.writeFileSync(path.join(shots, name + '.png'), Buffer.from(r.result.data, 'base64'));
};
const key = async (k, code, vk, mods = 0) => {
  await send('Input.dispatchKeyEvent', { type: 'rawKeyDown', key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers: mods });
  await send('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk, nativeVirtualKeyCode: vk, modifiers: mods });
  await sleep(150);
};
const menuItems = () => ev(`[...document.querySelectorAll('.tm-menu')].map(m => [...m.querySelectorAll(':scope > button')].map(b => b.textContent.replace(/▸$/, '')).join('|'))`);
const escape = () => ev(`document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
const rightClick = sel => ev(`(() => { const e = ${sel}; if (!e) return false; const r = e.getBoundingClientRect(); e.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 10, clientY: r.top + 5 })); return true; })()`);
const clickItem = label => ev(`(() => { const b = [...document.querySelectorAll('.tm-menu button, .menu button')].find(x => x.textContent.replace(/▸$/, '').startsWith(${JSON.stringify(label)})); if (!b) return false; b.click(); return true; })()`);
const closeDialogs = () => ev(`document.querySelectorAll('dialog[open]').forEach(d => d.close())`);
const inst = await (await fetch(base + 'api/instances')).json(); const ic = inst.columns;
const idOf = n => inst.rows.find(r => String(r[ic.indexOf('name')]) === n)?.[ic.indexOf('instance_id')];
const api = async (p, q = {}) => (await fetch(base + 'api/' + p + '?' + new URLSearchParams(q))).json();
const rowsOf = t => t ? t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]]))) : [];
const treeInst = n => `[...document.querySelectorAll('#tree .tree-inst')].find(x => x.querySelector('a.inst')?.textContent.trim() === ${JSON.stringify(n)})`;
const openCaret = async k => { await ev(`(() => { const b = document.querySelector('#tree button.caret[data-key=${JSON.stringify(k)}]'); if (b && b.getAttribute('aria-expanded') !== 'true') b.click(); })()`); await sleep(400); };

// ---- R: the fleet root ----
await go('#/summary');
await guard('R1 root menu', async () => {
  await rightClick(`document.querySelector('#tree a.tree-root')`);
  const m = await menuItems();
  const roles = await ev(`(() => { const m = document.querySelector('.tm-menu'); return m ? m.getAttribute('role') + '/' + [...m.querySelectorAll(':scope > button')].every(b => b.getAttribute('role') === 'menuitem') : 'none'; })()`);
  await shot('tree-root-menu-light');
  check('R1 root menu', m.length === 1 && m[0] === 'Refresh|Add Connections...|Find Database|Open in a new tab' && roles === 'menu/true', `${m.join(' / ') || 'no menu'}; roles ${roles}`);
  await escape();
});
await guard('R2 refresh', async () => {
  // About is no live page: no timer of its own reads the fleet while the case waits
  await go('#/about');
  const before = await ev(`performance.getEntriesByType('resource').filter(e => e.name.includes('/api/instances')).length`);
  await sleep(1500);
  const idle = await ev(`performance.getEntriesByType('resource').filter(e => e.name.includes('/api/instances')).length`);
  await rightClick(`document.querySelector('#tree a.tree-root')`); await clickItem('Refresh'); await sleep(1500);
  const after = await ev(`performance.getEntriesByType('resource').filter(e => e.name.includes('/api/instances')).length`);
  check('R2 refresh', idle === before && after > idle, `/api/instances reads ${before}, ${idle} after 1.5 s alone, ${after} after Refresh`);
});
await guard('R3 add', async () => {
  await go('#/summary');
  await rightClick(`document.querySelector('#tree a.tree-root')`); await clickItem('Add Connections');
  const t = await ev(`(async () => { const v = (id, x) => { const e = document.getElementById(id); e.value = x; e.dispatchEvent(new Event('change')); e.dispatchEvent(new Event('input')); };
    v('tm-ac-name', 'sql09'); v('tm-ac-engine', 'sqlserver'); await new Promise(r => setTimeout(r, 100));
    const plats = [...document.getElementById('tm-ac-platform').options].map(o => o.value).join(',');
    v('tm-ac-name', 'demo-onprem-erp01'); await new Promise(r => setTimeout(r, 100));
    const taken = document.querySelector('dialog[open] p.error')?.textContent ?? '';
    v('tm-ac-name', 'sql09'); await new Promise(r => setTimeout(r, 100));
    return { yaml: document.querySelector('dialog[open] pre.tm-yaml').textContent, plats, taken }; })()`);
  await shot('add-connections-light');
  check('R3 add', t.yaml.includes('  - name: sql09\n') && t.yaml.includes('    engine: sqlserver\n') && t.yaml.includes('    dsn: env:PGVIGIL_DSN_SQL09')
    && t.plats === 'auto,onprem,rds,azuresqldb,azuresqlmi,cloudsql' && /in the fleet already/.test(t.taken),
    `${JSON.stringify(t.yaml.split('\n').slice(0, 4))}; SQL Server platforms ${t.plats}; a taken name: '${t.taken}'`);
  await closeDialogs();
});
// findIn: Find Database from a node's menu, a text submitted, the dialog's links (text and href) or the page it moved to
const findIn = async (node, q) => {
  await closeDialogs();
  await rightClick(node); await clickItem('Find Database');
  return ev(`(async () => { const i = document.getElementById('tm-find'); const from = location.hash; i.value = ${JSON.stringify(q)}; i.closest('form').requestSubmit();
    for (let k = 0; k < 60 && location.hash === from && /Searching|^$/.test(document.getElementById('tm-find-out')?.textContent ?? ''); k++) await new Promise(r => setTimeout(r, 200));
    const out = document.getElementById('tm-find-out');
    return { hash: location.hash, moved: location.hash !== from, links: out ? [...out.querySelectorAll('a')].map(a => ({ t: a.textContent, h: a.getAttribute('href') })) : [], text: out?.textContent.slice(0, 160) ?? '' }; })()`);
};
// mssqlHits: SQL Server databases whose name holds q, read by hand from each SQL Server instance's storage read
const mssqlHits = async (q, only) => {
  const n = [];
  for (const r of rowsOf(inst).filter(x => x.engine === 'sqlserver' && (!only || Number(x.instance_id) === only))) {
    for (const d of rowsOf((await api('mssql/storage', { instance: r.instance_id, part: 'databases' })).databases)) if (String(d.database_name).toLowerCase().includes(q.toLowerCase())) n.push(d.database_name);
  }
  return n;
};
await guard('R4 find', async () => {
  const root = `document.querySelector('#tree a.tree-root')`;
  await rightClick(root); await clickItem('Find Database');
  const short = await ev(`(async () => { const i = document.getElementById('tm-find'); i.value = 'a'; i.closest('form').requestSubmit(); await new Promise(r => setTimeout(r, 200)); return document.getElementById('tm-find-out').textContent; })()`);
  const pgErp = rowsOf(await api('search', { q: 'erp' })).filter(r => r.kind === 'database').slice(0, 50), msErp = await mssqlHits('erp');
  const erp = await findIn(root, 'erp');
  await shot('find-database-light');
  const pgSales = rowsOf(await api('search', { q: 'sales' })).filter(r => r.kind === 'database').slice(0, 50), msSales = await mssqlHits('sales');
  const sales = await findIn(root, 'sales');
  const exact = rowsOf(await api('search', { q: 'billing' })).filter(x => x.kind === 'database' && String(x.datname) === 'billing');
  const bill = await findIn(root, 'billing');
  const billI = bill.moved ? new URLSearchParams(bill.hash.split('?')[1] ?? '').get('i') : null;
  // one instance's own databases: its database list by hand
  await go('#/summary');
  const erpId0 = idOf('demo-onprem-erp01');
  const own = rowsOf((await api('dbinfo', { instance: erpId0, part: 'databases' })).databases).filter(r => r.is_present !== false && !r.is_template && String(r.datname).toLowerCase().includes('er'));
  const one = await findIn(`${treeInst('demo-onprem-erp01')}?.querySelector('a.inst')`, 'er');
  const holds = (ls, q) => ls.every(l => l.t.toLowerCase().includes(q));
  const okOne = own.length === 1 && own[0].datname === 'er' ? one.moved : one.links.length === own.length && holds(one.links, 'er') && one.links.every(l => new URLSearchParams(l.h.split('?')[1]).get('i') === String(erpId0));
  check('R4 find', /two characters/.test(short)
    && erp.links.length === pgErp.length + msErp.length && holds(erp.links, 'erp')
    && sales.links.length === pgSales.length + msSales.length && msSales.length > 0 && holds(sales.links, 'sales') && sales.links.some(l => l.h.startsWith('#/mssqlfiles'))
    && (exact.length === 1 ? billI === String(exact[0].instance_id) : !bill.moved)
    && okOne,
    `'a': ${short}; 'erp' ${erp.links.length} links for ${pgErp.length} + ${msErp.length} by hand; 'sales' ${sales.links.length} for ${pgSales.length} + ${msSales.length}; 'billing' -> i=${billI} (hand ${exact.map(x => x.instance_id).join(',')}); on erp01 'er': ${one.moved ? 'moved to ' + one.hash : one.links.length + ' links'} for ${own.length} by hand`);
  await closeDialogs();
});

// ---- I and K: an instance ----
await go('#/summary');
const erp = 'demo-onprem-erp01', erpId = idOf(erp);
const openActions = async label => { await closeDialogs(); await rightClick(`${treeInst(erp)}?.querySelector('a.inst')`); await clickItem('Instance Actions'); await sleep(150); await clickItem(label); };
await guard('I1 instance menu', async () => {
  await rightClick(`${treeInst(erp)}?.querySelector('a.inst')`);
  const m = await menuItems();
  await clickItem('Instance Actions'); await sleep(200);
  const m2 = await menuItems();
  await shot('tree-instance-menu-light');
  check('I1 instance menu', m[0] === 'Find Database|Refresh|Instance Actions|Open in a new tab' && m2[1] === 'Pause/Resume Collections...|Configure Schedule...|Connection Options...|Add Alert Blackout...', m2.join(' / '));
  await ev(`document.querySelectorAll('.tm-menu').forEach(m => m.remove())`);
});
await guard('I2 pause/resume', async () => {
  const c = rowsOf((await api('instance/collections', { instance: erpId })).collections);
  const optIn = r => r.default_s != null && Number(r.default_s) === 0;
  const offBefore = c.filter(r => !optIn(r) && r.interval_s != null && Number(r.interval_s) === 0).map(r => r.collection);
  await openActions('Pause/Resume Collections'); await sleep(1200);
  const r = await ev(`(async () => { const d = [...document.querySelectorAll('dialog[open]')].pop(); const rows = d.querySelectorAll('tbody tr').length;
    const t = [...d.querySelectorAll('tbody input[type=checkbox]')].find(x => !x.disabled && x.checked); const name = t?.closest('tr').children[1].textContent; if (t) t.click();
    const locked = [...d.querySelectorAll('tbody input[type=checkbox]')].filter(x => x.disabled).map(x => x.closest('tr').children[1].textContent);
    await new Promise(r => setTimeout(r, 100)); return { rows, name, locked, yaml: d.querySelector('pre.tm-yaml').textContent }; })()`);
  await shot('pause-resume-light');
  const want = `disabled: [${[...new Set([...offBefore, r.name])].sort().join(', ')}]`;
  const wantLocked = c.filter(optIn).map(x => x.collection).sort().join(',');
  check('I2 pause/resume', c.length > 0 && r.rows === c.length && r.yaml.includes(want) && r.locked.sort().join(',') === wantLocked,
    `${r.rows} rows for ${c.length} collections; untick ${r.name} -> ${JSON.stringify(r.yaml.split('\n').find(l => l.includes('disabled')))} (want '${want}'); opt-in, not tickable: ${r.locked.join(',') || 'none'} (hand ${wantLocked || 'none'})`);
  await closeDialogs();
});
await guard('I3 schedule', async () => {
  await openActions('Configure Schedule'); await sleep(1200);
  const r = await ev(`(async () => { const d = [...document.querySelectorAll('dialog[open]')].pop(); const i = d.querySelector('tbody input'); const name = i.closest('tr').children[0].textContent;
    const bad = v => { i.value = v; i.dispatchEvent(new Event('input')); return !i.checkValidity(); };
    const refused = ['5x', '0m', '30s', '9999999999h'].map(bad);
    i.value = '15m'; i.dispatchEvent(new Event('input')); await new Promise(r => setTimeout(r, 100));
    return { name, refused, yaml: d.querySelector('pre.tm-yaml').textContent }; })()`);
  check('I3 schedule', r.refused.every(Boolean) && r.yaml.includes('    schedules:\n') && r.yaml.includes(`      ${r.name}: 15m`), `'5x', '0m', '30s', '9999999999h' refused ${r.refused.join('/')}; ${JSON.stringify(r.yaml.split('\n').slice(-2))}`);
  await closeDialogs();
});
await guard('I4 connection', async () => {
  await openActions('Connection Options'); await sleep(800);
  const r = await ev(`(() => { const d = [...document.querySelectorAll('dialog[open]')].pop(); return { grid: d.querySelector('table.props')?.textContent ?? '', yaml: d.querySelector('pre.tm-yaml').textContent }; })()`);
  check('I4 connection', r.grid.includes(erp) && r.yaml.includes(`  - name: ${erp}\n`), JSON.stringify(r.yaml.split('\n').slice(0, 3)));
  await closeDialogs();
});
await guard('I5 blackout', async () => {
  await openActions('Add Alert Blackout'); await sleep(1000);
  const bo = await ev(`(() => { const d = [...document.querySelectorAll('dialog[open]')].pop(); return d ? { label: d.getAttribute('aria-label') ?? '', when: d.querySelectorAll('input[type=datetime-local]').length, text: d.textContent.slice(0, 120) } : null; })()`);
  await shot('add-blackout-light');
  await closeDialogs();
  check('I5 blackout', !!bo && ((bo.label === `Blackout '${erp}'` && bo.when === 2) || (bo.label === 'Add Alert Blackout' && /read only/.test(bo.text))), JSON.stringify(bo));
});
await guard('K keyboard', async () => {
  await closeDialogs();
  const focusNode = () => ev(`(() => { const a = ${treeInst(erp)}?.querySelector('a.inst'); a.focus(); return document.activeElement === a; })()`);
  await focusNode();
  await key('F10', 'F10', 121, 8);
  const a = await ev(`({ open: !!document.querySelector('.tm-menu'), focus: document.activeElement?.textContent ?? '', inMenu: !!document.activeElement?.closest('.tm-menu') })`);
  await key('ArrowDown', 'ArrowDown', 40); await key('ArrowDown', 'ArrowDown', 40);
  const pop = await ev(`document.activeElement?.getAttribute('aria-haspopup') + '/' + document.activeElement?.getAttribute('aria-expanded')`);
  await key('ArrowRight', 'ArrowRight', 39);
  const b = await ev(`({ menus: document.querySelectorAll('.tm-menu').length, focus: document.activeElement?.textContent ?? '', exp: [...document.querySelectorAll('.tm-menu button[aria-haspopup]')].map(x => x.getAttribute('aria-expanded')).join() })`);
  await key('ArrowLeft', 'ArrowLeft', 37);
  const c = await ev(`({ menus: document.querySelectorAll('.tm-menu').length, focus: (document.activeElement?.textContent ?? '').replace(/▸$/, ''), exp: document.activeElement?.getAttribute('aria-expanded') })`);
  await key('Escape', 'Escape', 27);
  const d = await ev(`({ menus: document.querySelectorAll('.tm-menu').length, onNode: document.activeElement === ${treeInst(erp)}?.querySelector('a.inst') })`);
  await focusNode();
  await key('ContextMenu', 'ContextMenu', 93);
  const e = await ev(`({ open: !!document.querySelector('.tm-menu'), inMenu: !!document.activeElement?.closest('.tm-menu') })`);
  await key('Escape', 'Escape', 27);
  check('K keyboard', a.open && a.inMenu && a.focus === 'Find Database' && pop === 'menu/false' && b.menus === 2 && b.focus === 'Pause/Resume Collections...' && b.exp === 'true'
    && c.menus === 1 && c.focus === 'Instance Actions' && c.exp === 'false' && d.menus === 0 && d.onNode && e.open && e.inMenu,
    `Shift+F10 ${a.open}/${a.focus}; Instance Actions ${pop}; Right -> ${b.menus} menus, ${b.focus}, expanded ${b.exp}; Left -> ${c.menus}, ${c.focus}, expanded ${c.exp}; Escape -> ${d.menus}, on the node ${d.onNode}; ContextMenu key ${e.open}`);
});

// ---- F and J: a Jobs folder and a job of a pg_cron instance ----
const cronInst = ['demo-rds-billing01', 'demo-aurora-crm01'].find(n => idOf(n));
const cronId = idOf(cronInst);
const jobs = rowsOf((await api('jobs', { instance: cronId, part: 'jobs' })).jobs).filter(r => r.is_present);
await guard('F folder', async () => {
  await go('#/summary');
  await openCaret(`i${cronId}`);
  await rightClick(`document.querySelector('#tree button.caret[data-key="i${cronId}/jobs"]')?.closest('.tree-node')?.querySelector('a')`);
  const m = await menuItems();
  await shot('tree-jobs-folder-menu-light');
  const drawn = jobs.slice(0, 30), name = String(drawn[0]?.job_name ?? ''), part = name.slice(0, Math.max(2, Math.min(5, name.length)));
  const want = drawn.filter(j => String(j.job_name ?? j.job_id).toLowerCase().includes(part.toLowerCase())).length;
  await clickItem('Filter');
  const r = await ev(`(async () => { const i = document.getElementById('tm-filter'); i.value = ${JSON.stringify(part)}; i.closest('form').requestSubmit();
    for (let k = 0; k < 30 && !document.querySelector('#tree .tm-filtered'); k++) await new Promise(r => setTimeout(r, 200));
    await new Promise(r => setTimeout(r, 600));
    const box = document.querySelector('#tree button.caret[data-key="i${cronId}/jobs"]').closest('.tree-node').parentElement;
    const leaves = [...box.querySelectorAll(':scope > div > a.inst[href^="#/job?"]')];
    return { line: document.querySelector('#tree .tm-filtered span')?.textContent ?? '', shown: leaves.filter(a => !a.parentElement.hidden).length, hidden: leaves.filter(a => a.parentElement.hidden).length,
      wrong: leaves.filter(a => !a.parentElement.hidden && !a.textContent.toLowerCase().includes(${JSON.stringify(part.toLowerCase())})).length }; })()`);
  check('F folder', m[0] === 'Filter|Refresh|Open in a new tab' && jobs.length > 0 && r.line.startsWith(`Filter "${part}": ${want} of ${drawn.length}`) && r.shown === want && r.hidden === drawn.length - want && r.wrong === 0,
    `${m[0]}; '${r.line}'; ${r.shown} shown, ${r.hidden} hidden, ${r.wrong} shown without '${part}' (hand ${want} of ${drawn.length})`);
  await ev(`[...document.querySelectorAll('#tree .tm-filtered button')].forEach(b => b.click())`);
});
await guard('J job', async () => {
  const leaf = `document.querySelector('#tree a.inst[href^="#/job?"]')`;
  for (let k = 0; k < 20 && !(await ev(`!!${leaf}`)); k++) await sleep(250);
  const name = await ev(`${leaf}?.textContent.trim()`), want = await ev(`${leaf}?.getAttribute('href')`);
  await rightClick(leaf);
  const m = await menuItems();
  await shot('tree-job-menu-light');
  await clickItem('Start/Stop Job'); await sleep(1500);
  const x = await ev(`(() => { const d = [...document.querySelectorAll('dialog[open]')].pop(); const b = [...d.querySelectorAll('button')]; const st = b.find(e => e.textContent === 'Start'), sp = b.find(e => e.textContent === 'Stop');
    return { title: d.getAttribute('aria-label'), start: st?.getAttribute('aria-disabled') === 'true' ? st.title : 'on', stop: sp?.getAttribute('aria-disabled') === 'true' ? sp.title : 'on' }; })()`);
  await shot('execute-job-light');
  await closeDialogs();
  await rightClick(leaf); await clickItem('Configure Thresholds'); await sleep(1200);
  const th = await ev(`[...document.querySelectorAll('dialog[open]')].pop()?.getAttribute('aria-label') ?? ''`);
  await closeDialogs();
  await rightClick(leaf); await clickItem('Job Info'); await sleep(800);
  const h = await ev('location.hash');
  check('J job', m[0] === 'Job Info|Configure Thresholds|Start/Stop Job|Refresh|Open in a new tab' && x.title === `Execute Job - ${name}` && /pg_cron/.test(x.start) && x.stop !== 'on' && th === `Job thresholds: ${name}` && h === want,
    `${m[0]}; ${x.title}: Start '${x.start}', Stop '${x.stop}'; ${th}; Job Info -> ${h} (the leaf ${want})`);
});

// ---- D: the drive nodes ----
await guard('D drives', async () => {
  await go('#/summary');
  const sqlId = idOf('demo-onprem-sql01');
  const vols = rowsOf((await api('mssql/storage', { instance: sqlId, part: 'volumes' })).volumes).filter(v => Number(v.total_bytes) > 0);
  await openCaret(`i${sqlId}`); await openCaret(`i${sqlId}/storage`);
  for (let k = 0; k < 20 && !(await ev(`!!document.querySelector('#tree .tm-drive')`)); k++) await sleep(250);
  const d = await ev(`[...document.querySelectorAll('#tree .tm-drive')].map(n => ({ v: n.dataset.volume, w: parseFloat(n.querySelector('.tm-bar > span')?.style.width ?? 'NaN'), cls: n.querySelector('.tm-bar').className, text: n.querySelector('a').textContent.trim(), title: n.querySelector('a').title }))`);
  await shot('tree-drives-light');
  const okW = d.length === vols.length && vols.every(v => {
    const n = d.find(x => x.v === String(v.volume)), used = (Number(v.total_bytes) - Number(v.free_bytes)) / Number(v.total_bytes) * 100, free = 100 - used;
    return n && Math.abs(n.w - used) <= 0.2 && / free \(/.test(n.text) && / free of /.test(n.title) && n.cls.includes(free < 10 ? 'crit' : free < 20 ? 'warn' : 'ok');
  });
  check('D drives', vols.length > 0 && okW, `${d.length} drive nodes for ${vols.length} volumes: ${d.map(x => `${x.v} ${x.w}% (${x.cls.replace('tm-bar ', '')}) '${x.text}'`).join(', ')}`);
});

// ---- D2: a drive's History and its window picker ----
await guard('D2 drive history', async () => {
  const sqlId = idOf('demo-onprem-sql01');
  await ev(`localStorage.removeItem('pgvigil.driveHistoryMinutes')`);
  await ev('performance.clearResourceTimings()');   // the browser keeps 250 reads of one document: D2 counts only its own
  await go(`#/drives?i=${sqlId}`);
  const histSel = 'button.link[aria-label^="History of"]', winSel = 'select[aria-label^="History window of"]';
  for (let k = 0; k < 40 && !(await ev(`!!document.querySelector('${histSel}')`)); k++) await sleep(250);
  await ev(`document.querySelector('${histSel}').click()`);
  const titled = async words => { for (let k = 0; k < 40; k++) { if (await ev(`document.querySelector('#main').innerText.includes('used and free over ${words}')`)) return true; await sleep(250); } return false; };
  const first = await titled('30 days');
  const opts = await ev(`[...(document.querySelector('${winSel}')?.options ?? [])].map(o => o.value).join('|')`);
  const at = await ev(`document.querySelector('${winSel}')?.value ?? ''`);
  // the History's own line (how much the window holds, or why no line is drawn)
  const line = () => ev(`[...document.querySelectorAll('#main p[role=status]')].map(p => p.textContent).find(t => /of history|This window holds/.test(t)) ?? ''`);
  // pick(minutes, words, drawn): the window picked, its read on the wire, its title; drawn = a chart whose first point
  // lies over 80 % of the window back and the line 'N reads over ...'; 'short' = a chart of the two reads a short
  // window happens to hold; not drawn = no chart and the line that says why
  const pick = async (m, words, drawn) => {
    await ev(`(() => { const s = document.querySelector('${winSel}'); s.value = '${m}'; s.dispatchEvent(new Event('change')); return true; })()`);
    const t = await titled(words);
    const read = await ev(`performance.getEntriesByType('resource').some(e => e.name.includes('/api/drives/history') && /[?&]minutes=${m}(&|$)/.test(e.name))`);
    const firstAt = await ev(`[...document.querySelectorAll('#main .chart')].find(b => b.querySelector('h3')?.textContent.includes('used and free over ${words}'))?.dataset.first ?? ''`);
    const said = await line();
    const ok = drawn === 'short' ? !!firstAt && /^2 reads over .+ of history/.test(said)
      : drawn ? !!firstAt && Date.now() - Date.parse(firstAt) > m * 60e3 * 0.8 && /^\d[\d,.]* reads over .+ of history/.test(said)
        : !firstAt && /^This window holds (no read|one read), so no line is drawn\./.test(said) && /read about every/.test(said) && !/a chart needs two/.test(await ev(`document.querySelector('#main').innerText`));
    return { ok: t && read && ok, said };
  };
  // the demo writes a SQL Server volume read on the hour and one at the seed's end: the 5 minutes hold none or one, or
  // two when the seed ended just after an hour - asked of the API first, the page must then say or draw exactly that
  const drive = (await ev(`document.querySelector('${histSel}').getAttribute('aria-label')`)).replace(/^History of /, '').replace(/ on demo-onprem-sql01$/, '');
  const n5 = await ev(`fetch('/api/drives/history?instance=${sqlId}&minutes=5&drive=' + encodeURIComponent(${JSON.stringify(drive)})).then(r => r.json()).then(d => d.history ? d.history.rows.length : -1)`);
  const p90 = await pick(129600, '90 days', true), p5 = await pick(5, '5 minutes', n5 >= 2 ? 'short' : false), pYear = await pick(525600, '1 year', true);
  const kept = await ev(`localStorage.getItem('pgvigil.driveHistoryMinutes')`);
  // the stored pick is read back: the History closed and opened again stands at the year
  await ev(`document.querySelector('${histSel}').click()`); await sleep(300);
  await ev(`document.querySelector('${histSel}').click()`);
  const reopened = await titled('1 year') && await ev(`document.querySelector('${winSel}')?.value ?? ''`) === '525600';
  check('D2 drive history', first && opts === '5|15|30|60|360|1440|2880|10080|43200|129600|259200|525600' && at === '43200' && p90.ok && p5.ok && pYear.ok && kept === '525600' && reopened,
    `opened at 30 days: ${first}; windows '${opts}' at '${at}'; 90 days read and drawn: ${p90.ok} ('${p90.said}'); 5 minutes (${n5} read(s) by the API) read and said: ${p5.ok} ('${p5.said}'); 1 year read and drawn: ${pYear.ok} ('${pYear.said}'); kept: ${kept}; reopened at the year: ${reopened}`);
});

// ---- W: a PostgreSQL instance's Summary names no SQL Server-only check ----
await guard('W pg words', async () => {
  const pgId = idOf('demo-cloudsql-analytics01');
  await go(`#/summary?i=${pgId}`);
  const read = () => ev(`[...document.querySelectorAll('#main p.counts')].map(p => p.textContent).find(t => /^(Not OK|No warning|Every check)/.test(t)) ?? ''`);
  let line = '';
  for (let k = 0; k < 40 && !(line = await read()); k++) await sleep(250);
  const sqlOnly = ['QS', 'SQL Agent Alerts', 'Backup DIFF', 'Is Agent Running', 'Mirroring', 'Log Space', 'File Space', '% Max Size', 'Elastic Pool Storage', 'DB Mail', 'Identity Columns', 'Service Broker'];
  const hit = sqlOnly.filter(w => new RegExp('(^|[^A-Za-z])' + w + '([^A-Za-z]|$)').test(line));
  check('W pg words', !!line && hit.length === 0, `demo-cloudsql-analytics01's Summary says '${line.slice(0, 200)}'; SQL Server-only names in it: ${hit.join(', ') || 'none'}; judged on an all-OK instance (where the line lists the cells without a read): ${!/^Not OK/.test(line)}`);
});

// ---- GM: the grid menu at DBA Dash's level (task GM, its design as the pass's fold left it) - one case per item, each
// able to fail on a tree without it (the flat menu answers no '.tm-menu'). The grids: Instances' (#/instances; number
// column 'sessions', text 'platform', unique 'name'), a dropped JSON file's viewer grid (a modal dialog: the hostile
// fixture), slow.ts's own table.grid, a SQL Server instance's Drives grid, a statements grid, an empty one. Contracts the
// cases hold the build to: the menu is treemenu's (.tm-menu boxes in the host of the grid - the open dialog or the body;
// a submenu's button aria-haspopup with its '▸'; an off item aria-disabled with its reason as visible words in a child
// .off-reason); a copy goes through navigator.clipboard (stubbed here: each write kept as type and text); a file is a
// browser download; a filter's prompt is a dialog[open] whose first input holds the prefill and whose form (or its
// Filter / OK / Apply button) applies it; a transpose is a dialog[open] holding a table and a Copy button.
const GT = `document.querySelector('main table.grid')`;
const gIx = (label, t = GT) => `[...${t}.querySelectorAll('thead tr:first-child th')].findIndex(h => h.textContent.trim() === ${JSON.stringify(label)})`;
const gRowsOf = t => `[...${t}.querySelectorAll(':scope > tbody > tr')].filter(tr => !tr.classList.contains('trend-row'))`;
const gRows = gRowsOf(GT);
const gCell = (label, nth = 0, t = GT) => `${gRowsOf(t)}.map(tr => tr.children[${gIx(label, t)}]).filter(td => td && td.textContent.trim() !== '')[${nth}]`;
const gCol = (label, t = GT) => ev(`${gRowsOf(t)}.map(tr => tr.children[${gIx(label, t)}]?.textContent.trim() ?? '')`);
const gHeads = (t = GT) => ev(`[...${t}.querySelectorAll('thead tr:first-child th')].filter(h => !h.hasAttribute('data-gt-hidden') && getComputedStyle(h).display !== 'none').map(h => h.textContent.trim())`);
const gNum = s => { const t = String(s).replace(/,/g, '').trim(); return t !== '' && /^-?\d+(\.\d+)?$/.test(t) ? Number(t) : null; };
// each open menu level: its items' labels (the '▸' and an off item's words left out), the visible words of an off one
const gmLevels = () => ev(`[...document.querySelectorAll('.tm-menu')].map(m => [...m.querySelectorAll(':scope > button')].map(b => {
  const why = b.querySelector('.off-reason'), c = b.cloneNode(true); c.querySelectorAll('.off-reason, .tm-arrow').forEach(x => x.remove());
  return { label: c.textContent.replace(/▸$/, '').trim(), off: b.getAttribute('aria-disabled') === 'true' ? (why && why.offsetParent !== null && why.textContent.trim() ? why.textContent.trim() : '(no visible words)') : null,
    sub: b.getAttribute('aria-haspopup') === 'menu', inDialog: !!m.closest('dialog[open]') }; }))`);
const gmClose = async () => { for (let k = 0; k < 5 && await ev(`!!document.querySelector('.tm-menu, .menu')`); k++) { await escape(); await sleep(100); } await ev(`document.querySelectorAll('.tm-menu, .menu').forEach(m => m.remove())`); };
const gmOpen = async sel => { await gmClose(); await rightClick(sel); await sleep(300); return gmLevels(); };
const gmBtn = (i, label) => `(() => { const box = [...document.querySelectorAll('.tm-menu')][${i}]; return box && [...box.querySelectorAll(':scope > button')].find(b => { const c = b.cloneNode(true);
  c.querySelectorAll('.off-reason, .tm-arrow').forEach(x => x.remove()); const t = c.textContent.replace(/▸$/, '').trim(); return t === ${JSON.stringify(label)} || t.replace(/\\.\\.\\.$/, '') === ${JSON.stringify(label)} || ${label.endsWith(':')} && t.startsWith(${JSON.stringify(label)}); }); })()`;
// gmPick: down the open menu by its labels (a label ending ':' matches its start): each but the last opens its submenu,
// the last acts; false when one is not there or is off (the menu is closed then)
const gmPick = async (...labels) => {
  for (let i = 0; i < labels.length; i++) {
    const hit = await ev(`(() => { const b = ${gmBtn(i, labels[i])}; if (!b || b.getAttribute('aria-disabled') === 'true') return false; b.click(); return true; })()`);
    if (!hit) { await gmClose(); return false; }
    await sleep(250);
  }
  return true;
};
const gmSub = async (sel, ...labels) => { await gmOpen(sel); const okk = await gmPick(...labels); const lv = okk ? await gmLevels() : []; await gmClose(); return okk ? (lv[labels.length] ?? []).map(x => x.label.replace(/\.\.\.$/, '')) : null; };
const gmClip = () => ev(`(() => { window.__clip = []; const c = navigator.clipboard;
  c.writeText = t => { window.__clip.push({ type: 'text/plain', t: String(t) }); return Promise.resolve(); };
  c.write = async its => { for (const it of its) for (const ty of it.types) window.__clip.push({ type: ty, t: await (await it.getType(ty)).text() }); };
  return true; })()`);
const gmCopied = async (type = 'text/plain') => { for (let k = 0; k < 20; k++) { const v = await ev(`(window.__clip || []).filter(x => x.type === ${JSON.stringify(type)}).map(x => x.t).pop() ?? null`); if (v != null) return v; await sleep(150); } return null; };
const gmCopy = async (sel, ...labels) => { await gmClip(); await gmOpen(sel); if (!await gmPick(...labels)) return null; return gmCopied(); };
const dlClear = () => { for (const f of fs.readdirSync(dl)) fs.rmSync(path.join(dl, f), { recursive: true, force: true }); };
const dlWait = async ext => { for (let k = 0; k < 40; k++) { const f = fs.readdirSync(dl).find(x => x.endsWith('.' + ext)); if (f) { await sleep(300); return { name: f, buf: fs.readFileSync(path.join(dl, f)), text: fs.readFileSync(path.join(dl, f), 'utf8') }; } await sleep(250); } return null; };
const gmFile = async (sel, label, ext) => { dlClear(); await gmOpen(sel); if (!await gmPick('Export file', label)) return null; return dlWait(ext); };
const gmExcel = async sel => { dlClear(); await gmOpen(sel); if (!await gmPick('Export Excel')) return null; return dlWait('xlsx'); };
const gFresh = async () => { await gmClose(); await closeDialogs(); await go('#/summary'); await go('#/instances'); };
const gFilter = async (label, v, t = GT) => { await ev(`(() => { const t = ${t}; t.querySelector('thead tr.filters')?.removeAttribute('hidden');
  const i = t.querySelectorAll('thead tr.filters td')[${gIx(label, t)}]?.querySelector('input'); if (!i) return false; i.value = ${JSON.stringify(v)}; i.dispatchEvent(new Event('input', { bubbles: true })); return true; })()`); await sleep(600); };
const gPrompt = async v => ev(`(() => { const d = [...document.querySelectorAll('dialog[open]')].pop(); const i = d?.querySelector('input'); if (!i) return null; const was = i.value;
  if (${JSON.stringify(v)} !== null) i.value = ${JSON.stringify(v)};
  if (i.form) i.form.requestSubmit(); else [...d.querySelectorAll('button')].find(b => /^(Filter|OK|Apply)$/.test(b.textContent.trim()))?.click(); return was; })()`);
const gClick = (sel, mods = {}) => ev(`(() => { const x = ${sel}; if (!x) return false; x.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, ...${JSON.stringify(mods)} })); return true; })()`);
const gSelectRect = async (a, b) => { await gClick(a, { ctrlKey: true }); return gClick(b, { shiftKey: true }); };
const gClearSel = (t = GT) => gClick(`${t}.querySelector('tbody td')`);
const gSolid = () => ev(`localStorage.setItem('pgvigil.status', 'solid')`);
// gReset: every grid choice kept in this browser dropped (theme, status style and refresh kept), and the page loaded
// again (gridtools keeps them in memory too)
const gReset = async () => { await ev(`(() => { for (const k of Object.keys(localStorage)) if (!/^pgvigil\\.(theme|status|refresh)$/.test(k)) localStorage.removeItem(k); })()`); await send('Page.reload'); await sleep(1500); };
// RFC 4180 rows (the byte-order mark left out)
const csvRows = text => { const out = []; let row = [], cur = '', q = false; const t = text.replace(/^﻿/, '');
  for (let i = 0; i < t.length; i++) { const ch = t[i];
    if (q) { if (ch === '"') { if (t[i + 1] === '"') { cur += '"'; i++; } else q = false; } else cur += ch; }
    else if (ch === '"') q = true; else if (ch === ',') { row.push(cur); cur = ''; } else if (ch === '\n') { row.push(cur); out.push(row); row = []; cur = ''; } else if (ch !== '\r') cur += ch; }
  if (cur !== '' || row.length) { row.push(cur); out.push(row); }
  return out; };
const tuples = s => s.split('\n').filter(l => /^\s*,?\s*\(/.test(l)).length;
const stem = f => f?.name.replace(/\.[a-z]+$/, '') ?? null;
// the hostile fixture (blocker 3): a value of each kind that breaks a careless writer, in a dropped JSON file's grid
const GH = 'gm-hostile.json', longText = 'SELECT ' + 'x'.repeat(9993);
const hostile = [
  ["it's", 'o1'], ['a]b', 'o2'], ['say "hi"', 'o3'], ['trail\\', 'o4'], ['line1\nline2', 'o5'], ['tab\there', 'o6'], ['nul\u0000here', 'o7'], ['00412', 'o8'],
  ['NaN', 'o9'], ['<script>alert(1)</script>', 'o10'], [longText, '100%'], ['\\', "');DROP TABLE t;--"], ['R & D', 'pg_stat_statements'], ['R & D dept', 'o14'],
  // review-15 gm2 B3 and its GO question: T-SQL's backslash line continuation, and a GO line inside a value (sqlcmd)
  ['back\\\nslash', 'o15'], ['x\nGO\ny', 'o16'],
].map(([txt, odd], i) => ({ id: i + 1, txt, 'we]ird"name': odd, num: [1, 2.5, -3, 0, 412, 1000000, 7.25, 8, 9, 10, 11, 12, 13, 14, 15, 16][i], '': i < 6 ? null : 'e' + (i + 1) }));
const want = hostile.map(r => ({ ...r, txt: r.txt.replace(/\u0000/g, '') }));
const GV = `[...document.querySelectorAll('dialog[open] table.grid')].pop()`;
const dropHostile = async (rows = hostile, name = GH) => { await closeDialogs(); await go('#/summary');
  await ev(`(() => { const dt = new DataTransfer(); dt.items.add(new File([${JSON.stringify(JSON.stringify(rows))}], ${JSON.stringify(name)})); document.body.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt })); })()`);
  for (let k = 0; k < 40; k++) { await sleep(250); if (await ev(`!!${GV}`)) break; } };

await guard('G-menu', async () => {
  await gSolid(); await send('Page.reload'); await sleep(1500); await gFresh();
  const n = (await gCol('sessions')).length, cols = (await gHeads()).length;
  const L = await gmOpen(gCell('sessions'));
  const top = (L[0] ?? []).map(x => x.label);
  const wantTop = ['Copy', 'Export Excel', 'Export file', 'Transpose', 'Select', 'Columns...', 'Row numbers', 'Data bar', 'All filters', 'Clear filters'];
  const at = wantTop.map(w => top.indexOf(w)), ordered = at.every((x, i) => x >= 0 && (i === 0 || x > at[i - 1]));
  const fv = top.findIndex(x => x.startsWith('Filter by value')), xv = top.findIndex(x => x.startsWith('Exclude value'));
  const subsOk = ['Copy', 'Export file', 'Transpose', 'Select', 'Data bar', 'All filters'].every(s => L[0]?.find(x => x.label === s)?.sub);
  const clear = L[0]?.find(x => x.label === 'Clear filters');
  const tail = top.slice(-2);
  const W = { Copy: ['Grid', 'Column', 'Cell', 'Row', 'Selected', 'As Markdown', 'As JSON'], 'Copy > As Markdown': ['Standard', 'Prettified'], 'Copy > As JSON': ['Compact', 'Prettified'],
    'Export file': ['CSV', 'JSON', 'Markdown', 'HTML', 'SQL (INSERT) for PostgreSQL', 'SQL (INSERT) for SQL Server'], Transpose: ['This row', 'Selected rows', 'Grid'], Select: ['Row', 'Column', 'All'],
    'Data bar': ['Behind value', 'Under value', 'Traffic light (higher is worse)', 'Traffic light (higher is better)', 'Remove'], 'All filters': ['=', '<>', '>', '<', '>=', '<='] };
  const got = {};
  for (const k of Object.keys(W)) got[k] = await gmSub(gCell('sessions'), ...k.split(' > '));
  const txt = await gmSub(gCell('platform'), 'All filters'), txtWant = ['Like', 'Not like', '=', '<>', '>', '<', '>=', '<='];
  const bad = Object.keys(W).filter(k => JSON.stringify(got[k]) !== JSON.stringify(W[k])).map(k => `${k}: ${JSON.stringify(got[k])}`);
  if (JSON.stringify(txt) !== JSON.stringify(txtWant)) bad.push(`platform's All filters: ${JSON.stringify(txt)}`);
  check('G-menu', ordered && fv > at[7] && xv > fv && xv < at[8] && subsOk && clear?.off === 'no filter is set'
    && new RegExp(`^Rows: ${n} \\| Cols: ${cols}$`).test(tail[0] ?? '') && /^\[sessions\] Sum: /.test(tail[1] ?? '') && bad.length === 0,
    `first level: ${top.join(' / ') || '(no .tm-menu)'}; order of ${wantTop.join(', ')}: ${at.join(',')}; Filter / Exclude at ${fv} / ${xv}; Clear filters ${clear ? (clear.off ?? 'ON') : 'absent'}; last two '${tail.join("' / '")}'; submenus off: ${bad.join('; ') || 'none'}`);
});

await guard('G-select', async () => {
  // Select > Column: every drawn cell, the tools' line says so, the menu's last line the selection's statistics; Select >
  // Row: the row's shown cells; a version cell (text that looks like a number): no Sum line, the menu ends 'Rows: ...'
  await gFresh();
  const ses = await gCol('sessions'), n = ses.length, cols = (await gHeads()).length, nums = ses.filter(x => gNum(x) !== null).length;
  await gmOpen(gCell('sessions')); const c = await gmPick('Select', 'Column'); await sleep(300);
  const sel = await ev(`({ n: ${GT}.querySelectorAll('tbody td.gt-sel').length, line: ${GT}.closest('.grid-box')?.querySelector('.gt-stats')?.textContent ?? '' })`);
  const L = await gmOpen(gCell('sessions')), last = (L[0] ?? []).map(x => x.label).pop() ?? ''; await gmClose(); await gClearSel();
  await gmOpen(`${gRows}[1].children[1]`); const r = await gmPick('Select', 'Row'); await sleep(300);
  const row = await ev(`({ n: ${GT}.querySelectorAll('tbody td.gt-sel').length, rows: new Set([...${GT}.querySelectorAll('tbody td.gt-sel')].map(td => td.parentElement)).size })`);
  await gClearSel();
  const V = await gmOpen(`${gRows}.map(tr => tr.children[${gIx('version')}]).find(td => /^\\d+\\.\\d+$/.test(td.textContent.trim()))`), vlast = (V[0] ?? []).map(x => x.label).pop() ?? ''; await gmClose();
  check('G-select', c && sel.n === n && /selected/.test(sel.line) && last.startsWith(`Selected Cells: ${n} (${nums} numeric) | Sum: `) && r && row.n === cols && row.rows === 1 && /^Rows: /.test(vlast),
    `Select > Column ${c}: ${sel.n} cells of ${n}, '${sel.line}', the menu's last '${last}'; Select > Row ${r}: ${row.n} cells in ${row.rows} row (${cols} columns); a version cell's last line '${vlast}'`);
});

await guard('G-header', async () => {
  await gFresh();
  const th = `${GT}.querySelectorAll('thead tr:first-child th')[${await ev(gIx('sessions'))}]`;
  const H = await gmOpen(th), top = (H[0] ?? []).map(x => x.label);
  const copy = await gmSub(th, 'Copy');
  const wantIn = ['Copy', 'Export Excel', 'Export file', 'Columns...', 'Row numbers', 'Hide column sessions', 'Group by sessions', 'Data bar', 'Clear filters'];
  const missing = wantIn.filter(w => !top.includes(w));
  check('G-header', missing.length === 0 && top.some(x => x.startsWith('Freeze the columns up to sessions')) && top.some(x => /^Rows: /.test(x)) && /^\[sessions\] Sum: /.test(top[top.length - 1] ?? '')
    && ['Grid', 'Column', 'Selected', 'As Markdown', 'As JSON'].every(x => copy?.includes(x)) && !copy?.includes('Cell') && !copy?.includes('Row'),
    `sessions' header menu: ${top.join(' / ') || '(no .tm-menu)'}${missing.length ? '; missing ' + missing.join(', ') : ''}; its Copy: ${JSON.stringify(copy)}`);
});

await guard('G-copy', async () => {
  await gFresh();
  const hs = await gHeads(), ses = await gCol('sessions'), n = ses.length, td = gCell('sessions'), j = await ev(gIx('sessions'));
  const cell = await gmCopy(td, 'Copy', 'Cell'), want0 = await ev(`${td}.textContent.trim()`);
  const rowTsv = await ev(`[...${td}.parentElement.children].filter(c => getComputedStyle(c).display !== 'none').map(c => c.textContent.trim()).join('\\t')`);
  const row = await gmCopy(td, 'Copy', 'Row');
  const col = await gmCopy(td, 'Copy', 'Column');
  await gSelectRect(`${gRows}[0].children[${j}]`, `${gRows}[1].children[${j + 1}]`);
  const rect = await ev(`[0, 1].map(r => [${j}, ${j + 1}].map(c => ${gRows}[r].children[c].textContent.trim()).join('\\t')).join('\\n')`);
  await gmClip(); await gmOpen(td); const selOk = await gmPick('Copy', 'Selected'); const sel = selOk ? await gmCopied() : null, selHtml = selOk ? await gmCopied('text/html') : null; await gClearSel();
  const grid = await gmCopy(td, 'Copy', 'Grid');
  const mdS = await gmCopy(td, 'Copy', 'As Markdown', 'Standard'), mdP = await gmCopy(td, 'Copy', 'As Markdown', 'Prettified');
  const jsC = await gmCopy(td, 'Copy', 'As JSON', 'Compact'), jsP = await gmCopy(td, 'Copy', 'As JSON', 'Prettified');
  const lines = s => (s ?? '').replace(/\r/g, '').split('\n');
  const parse = s => { try { return JSON.parse(s ?? ''); } catch { return null; } };
  const jc = parse(jsC), jp = parse(jsP);
  // the JSON's raw values: sessions a number or null (an empty cell), 'longest active' the seconds its words say
  const secsOf = s => { const m = /^(?:(\d+)d\s*)?(?:(\d+)h\s*)?(?:(\d+)m\s*)?(?:([\d.]+)\s*s)?$/.exec(s.trim()); return s.trim() && m ? (+(m[1] ?? 0)) * 86400 + (+(m[2] ?? 0)) * 3600 + (+(m[3] ?? 0)) * 60 + (+(m[4] ?? 0)) : null; };
  const longest = await gCol('longest active');
  // (a duration whose words do not parse here is not judged)
  const typed = Array.isArray(jc) && jc.every((o, i) => (ses[i] === '' ? o.sessions === null : o.sessions === gNum(ses[i]))
    && (longest[i] === '' ? o['longest active'] === null : secsOf(longest[i]) === null || Math.abs(o['longest active'] - secsOf(longest[i])) <= 1));
  const mdLines = lines(mdP).filter(Boolean), widths = new Set(mdLines.map(l => l.length));
  const r = {
    cell: cell === want0, row: lines(row).pop() === rowTsv, column: JSON.stringify(lines(col)) === JSON.stringify(ses),
    selected: sel === rect && /<table/i.test(selHtml ?? ''), grid: lines(grid)[0] === hs.join('\t') && lines(grid).length === n + 1,
    mdStandard: lines(mdS).filter(Boolean).length === n + 2 && /^\|( *:?-{3,}:? *\|)+$/.test(lines(mdS)[1] ?? ''), mdPrettified: mdLines.length === n + 2 && widths.size === 1,
    jsonCompact: Array.isArray(jc) && jc.length === n && JSON.stringify(Object.keys(jc[0] ?? {})) === JSON.stringify(hs) && typed && !/\n/.test(jsC ?? ''),
    jsonPrettified: JSON.stringify(jp) === JSON.stringify(jc) && /\n/.test(jsP ?? ''),
  };
  check('G-copy', Object.values(r).every(Boolean), Object.entries(r).map(([k, v]) => `${k} ${v ? 'ok' : 'NO'}`).join(', ') + `; ${n} rows, ${hs.length} columns; the cell '${cell}' (want '${want0}'); the selection '${(sel ?? '').replace(/\t/g, '→').replace(/\n/g, '⏎')}' (want '${rect.replace(/\t/g, '→').replace(/\n/g, '⏎')}')`);
  // a percent: the first root page whose grid shows one, its JSON value the shown number (12.5, not 0.125)
  let pct = null;
  for (const h of ['#/drives', '#/storage', '#/disks', '#/dbspace', '#/growth', '#/backups']) {
    await go(h);
    const hit = await ev(`(() => { const t = document.querySelector('main table.grid'); if (!t) return null; const rows = ${gRowsOf('t')};
      for (const [i, tr] of rows.entries()) for (const [k, td] of [...tr.children].entries()) if (/^-?[\\d.,]+ %$/.test(td.textContent.trim())) return { i, head: t.querySelectorAll('thead tr:first-child th')[k].textContent.trim(), text: td.textContent.trim() };
      return null; })()`);
    if (hit) { const js = parse(await gmCopy(`document.querySelector('main table.grid tbody td')`, 'Copy', 'As JSON', 'Compact')); pct = { h, ...hit, got: js?.[hit.i]?.[hit.head] }; break; }
  }
  check('G-copy JSON values', !!pct && pct.got === Number(pct.text.replace(/[ ,%]/g, '')), pct ? `${pct.h} '${pct.head}' row ${pct.i} shows '${pct.text}', its JSON ${JSON.stringify(pct.got)}` : 'no grid with a percent on the pages tried');
  // an emptied grid: every Copy item off with 'No data to copy'
  await gFresh(); await gFilter('platform', 'no-such-platform-xyz');
  await gmOpen(`${GT}.querySelector('thead tr:first-child th')`); await gmPick('Copy'); const sub = (await gmLevels())[1] ?? []; await gmClose();
  check('G-copy empty', (await gCol('sessions')).length === 0 && sub.length > 0 && sub.every(x => x.off === 'No data to copy'),
    `${(await gCol('sessions')).length} rows shown; Copy's items: ${sub.map(x => `${x.label} ${x.off ?? 'ON'}`).join(' / ') || '(no Copy submenu)'}`);
});

await guard('G-file', async () => {
  await gFresh();
  const n = (await gCol('sessions')).length, hs = await gHeads(), td = gCell('sessions');
  const xl = await gmExcel(td);
  const f = {};
  for (const [label, ext] of [['CSV', 'csv'], ['JSON', 'json'], ['Markdown', 'md'], ['HTML', 'html'], ['SQL (INSERT) for PostgreSQL', 'sql'], ['SQL (INSERT) for SQL Server', 'sql']]) f[label] = await gmFile(td, label, ext);
  const named = !!xl && Object.values(f).every(x => x && stem(x) === stem(xl));
  const csv = csvRows(f.CSV?.text ?? '');
  let js = null; try { js = JSON.parse(f.JSON?.text ?? ''); } catch { /* no file, or not JSON */ }
  const md = (f.Markdown?.text ?? '').replace(/\r/g, '').split('\n').filter(Boolean);
  const html = f.HTML?.text ?? '', pg = f['SQL (INSERT) for PostgreSQL']?.text ?? '', ms = f['SQL (INSERT) for SQL Server']?.text ?? '';
  const bom = x => !!x && x.buf[0] === 0xef && x.buf[1] === 0xbb && x.buf[2] === 0xbf;
  const firstStmt = s => s.replace(/^﻿/, '').split('\n').map(l => l.trim()).find(l => l && !l.startsWith('--')) ?? '';
  const r = {
    named, csv: csv.length === n + 1 && JSON.stringify(csv[0]) === JSON.stringify(hs), json: Array.isArray(js) && js.length === n && JSON.stringify(Object.keys(js[0] ?? {})) === JSON.stringify(hs),
    markdown: md.length === n + 2, html: /<meta charset="utf-8">/i.test(html) && /<style[\s\S]*background[\s\S]*<\/style>/i.test(html) && /<td class="[^"]+"/.test(html) && !/<td[^>]*style=/i.test(html),
    sqlPg: !!f['SQL (INSERT) for PostgreSQL'] && !bom(f['SQL (INSERT) for PostgreSQL']) && /^SET standard_conforming_strings = on;$/i.test(firstStmt(pg)) && /SET client_encoding = 'UTF8';/.test(pg) && /DROP TABLE IF EXISTS pg_temp\.pgvigil_grid;/.test(pg)
      && (pg.match(/CREATE TEMP(ORARY)? TABLE/gi) ?? []).length === 1 && /INSERT INTO pg_temp\.pgvigil_grid/.test(pg) && tuples(pg) === n && !/\bN'/.test(pg),
    sqlMs: bom(f['SQL (INSERT) for SQL Server']) && /IF OBJECT_ID\('tempdb\.\.#pgvigil_grid'\) IS NOT NULL DROP TABLE #pgvigil_grid/.test(ms) && /\[sessions\]/.test(ms) && /N'/.test(ms) && !ms.split('\n').filter(l => /^\s*,?\s*\(/.test(l)).some(l => /[(,]\s*'/.test(l)) && tuples(ms) === n,
  };
  check('G-file', Object.values(r).every(Boolean), Object.entries(r).map(([k, v]) => `${k} ${v ? 'ok' : 'NO'}`).join(', ')
    + `; Excel ${xl?.name ?? 'none'}; files: ${Object.entries(f).map(([k, v]) => `${k} ${v ? v.name + ' ' + v.buf.length + ' B' : 'none'}`).join(' | ')}; ${n} rows; csv ${csv.length} rows, md ${md.length} lines, pg tuples ${tuples(pg)}, ms tuples ${tuples(ms)}`);
});

await guard('G-hidden', async () => {
  // a hidden column is absent from every copy and every file
  await gFresh();
  await gmOpen(gCell('platform')); const hid = await gmPick('Hide column platform'); await sleep(300);
  const td = gCell('sessions'), out = {};
  out.grid = await gmCopy(td, 'Copy', 'Grid'); out.md = await gmCopy(td, 'Copy', 'As Markdown', 'Standard'); out.json = await gmCopy(td, 'Copy', 'As JSON', 'Compact');
  for (const [label, ext] of [['CSV', 'csv'], ['JSON', 'json'], ['Markdown', 'md'], ['HTML', 'html'], ['SQL (INSERT) for PostgreSQL', 'sql'], ['SQL (INSERT) for SQL Server', 'sql']]) out[label] = (await gmFile(td, label, ext))?.text ?? null;
  const holds = Object.entries(out).filter(([, v]) => v === null || /platform/.test(v)).map(([k, v]) => `${k} ${v === null ? 'none' : 'holds platform'}`);
  await gReset();
  check('G-hidden', hid && holds.length === 0, `Hide column platform ${hid}; ${holds.join(', ') || 'no form holds platform'}`);
});

await guard('G-order', async () => {
  await gFresh();
  const j = await ev(gIx('sessions'));
  for (let k = 0; k < 2; k++) { await ev(`${GT}.querySelectorAll('thead tr:first-child th')[${j}].click()`); await sleep(300); }   // twice: descending
  await gFilter('sessions', '>0');
  const shown = await gCol('sessions'), nums = shown.map(gNum);
  const desc = nums.every((x, i) => i === 0 || x === null || nums[i - 1] === null || nums[i - 1] >= x);
  const col = await gmCopy(gCell('sessions'), 'Copy', 'Column');
  const csv = await gmFile(gCell('sessions'), 'CSV', 'csv');
  const rows = csvRows(csv?.text ?? ''), h = rows[0] ?? [];
  const plain = x => String(x).replace(/,/g, '');
  const csvCol = rows.slice(1).map(r => r[h.indexOf('sessions')] ?? '');
  check('G-order', desc && shown.length > 0 && (col ?? '').split('\n').join('|') === shown.join('|') && csvCol.map(plain).join('|') === shown.map(plain).join('|'),
    `sorted descending ${desc}, ${shown.length} rows '>0': ${shown.join(',')}; Copy Column: ${(col ?? 'none').split('\n').join(',')}; the CSV's sessions: ${csvCol.join(',') || 'none'}`);
});

await guard('G-rownum', async () => {
  await gFresh();
  const n = (await gCol('sessions')).length, cells0 = await ev(`${gRows}[0].children.length`), heads0 = (await gHeads()).length;
  await gmOpen(gCell('sessions')); const on = await gmPick('Row numbers'); await sleep(300);
  // numbers drawn without a DOM column: a CSS counter on the row (no cell added)
  const look = () => ev(`(() => { const tr = ${gRows}[0]; if (!tr) return null; const xs = [tr, ...tr.children];
    return { cells: tr.children.length, counter: xs.some(x => /counter\\(/.test(getComputedStyle(x, '::before').content)), heads: [...${GT}.querySelectorAll('thead tr:first-child th')].length }; })()`);
  const a = await look();
  await send('Page.reload'); await sleep(1500); await go('#/instances');
  const b = await look();
  // with the numbers on: Hide, Freeze and Filter reach the column they name
  await gmOpen(gCell('platform')); await gmPick('Hide column platform'); await sleep(300);
  const hiddenHead = await ev(`[...${GT}.querySelectorAll('thead tr:first-child th')].filter(h => h.hasAttribute('data-gt-hidden')).map(h => h.textContent.trim()).join(',')`);
  await gmOpen(gCell('sessions')); const fz = await ev(`(() => { const b = [...document.querySelectorAll('.tm-menu button')].find(b => b.textContent.startsWith('Freeze the columns up to sessions')); b?.click(); return !!b; })()`); await sleep(300);
  const frozenLast = await ev(`(() => { const hs = [...${GT}.querySelectorAll('thead tr:first-child th')]; const st = hs.filter(h => getComputedStyle(h).position === 'sticky'); return st.length ? st[st.length - 1].textContent.trim() : ''; })()`);
  const v = await ev(`${gCell('sessions')}.textContent.trim()`), eq = (await gCol('sessions')).filter(x => x === v).length;
  await gmOpen(gCell('sessions')); await gmPick('Filter by value:'); await sleep(500); const fv = await gCol('sessions');
  const grid = await gmCopy(gCell('sessions'), 'Copy', 'Grid');
  const csv = await gmFile(gCell('sessions'), 'CSV', 'csv');
  await gmOpen(gCell('sessions')); const off = await gmPick('Row numbers'); await sleep(300);
  const c = await look();
  await gReset();
  check('G-rownum', on && !!a && a.counter && a.cells === cells0 && a.heads === heads0 && !!b && b.counter && hiddenHead === 'platform' && fz && frozenLast === 'sessions' && fv.length === eq && fv.every(x => x === v)
    && !!grid && !/^#\t/.test(grid) && !!csv && (csvRows(csv.text)[0] ?? ['#'])[0] !== '#' && off && !!c && !c.counter,
    `on ${on}: ${JSON.stringify(a)} (cells ${cells0}, heads ${heads0} before); after a reload ${JSON.stringify(b)}; hidden '${hiddenHead}'; Freeze ${fz} -> last frozen '${frozenLast}'; Filter by value '${v}': ${fv.length} rows (${eq} by hand); Copy Grid starts '${(grid ?? 'none').slice(0, 20)}'; the CSV starts '${(csv?.text ?? 'none').slice(0, 20)}'; off ${off}: ${JSON.stringify(c)}`);
});

await guard('G-transpose', async () => {
  await gFresh();
  const hs = await gHeads(), td = gCell('sessions');
  const dlg = () => ev(`(() => { const d = [...document.querySelectorAll('dialog[open]')].pop(); if (!d) return null; const t = d.querySelector('table');
    return { title: d.querySelector('h2, h3, legend, [role=heading]')?.textContent.trim() ?? d.getAttribute('aria-label') ?? '', rows: t ? [...t.querySelectorAll('tbody tr')].map(tr => [...tr.children].map(c => c.textContent.trim())) : [], text: d.textContent,
      copy: [...d.querySelectorAll('button')].some(b => /^Copy/.test(b.textContent.trim())) }; })()`);
  await gmOpen(td); await gmPick('Transpose', 'This row'); await sleep(400); const one = await dlg(); await closeDialogs();
  await gSelectRect(`${gRows}[0].children[1]`, `${gRows}[1].children[1]`);
  await gmOpen(td); await gmPick('Transpose', 'Selected rows'); await sleep(400); const two = await dlg(); await closeDialogs(); await gClearSel();
  const rowOk = !!one && /^Transposed/.test(one.title) && one.rows.length === hs.length && one.rows.every((r, i) => r[0] === hs[i] && r.length === 2) && one.copy;
  const twoOk = !!two && two.rows.length === hs.length && two.rows.every(r => r.length === 3);
  // Grid on a grid over 50 rows: the cap with its reason in the dialog; the dialog's Copy takes every row
  let big = null;
  for (const h of ['#/collectiondates', '#/findings', '#/checks', '#/extensions', '#/roles', '#/indexes', '#/versions']) {
    await go(h); const n = await ev(`document.querySelector('main table.grid') ? ${gRows}.length : 0`);
    if (n > 50) {
      await gmOpen(`${GT}.querySelector('tbody td')`); await gmPick('Transpose', 'Grid'); await sleep(500); const d = await dlg();
      await gmClip(); await ev(`[...[...document.querySelectorAll('dialog[open]')].pop()?.querySelectorAll('button') ?? []].find(b => /^Copy/.test(b.textContent.trim()))?.click()`);
      const copied = await gmCopied(); big = { h, n, d, cols: (copied ?? '').split('\n')[0]?.split('\t').length ?? 0 }; await closeDialogs(); break;
    }
  }
  const capOk = !!big?.d && /\b50\b/.test(big.d.text) && big.d.rows.length > 0 && big.d.rows.every(r => r.length === 51) && big.cols === big.n + 1;
  check('G-transpose', rowOk && twoOk && capOk, `This row: ${one ? `'${one.title}', ${one.rows.length} rows (want ${hs.length}), Copy ${one.copy}` : 'no dialog'}; Selected rows (2): ${two ? `${two.rows.length} rows of ${[...new Set(two.rows.map(r => r.length))].join('/')} cells` : 'no dialog'}; `
    + `Grid: ${big ? `${big.h} ${big.n} rows -> ${big.d ? `${big.d.rows.length} rows of ${[...new Set(big.d.rows.map(r => r.length))].join('/')} cells, '50' said ${/\b50\b/.test(big.d.text)}, its Copy ${big.cols} columns (want ${big.n + 1})` : 'no dialog'}` : 'no grid over 50 rows on the pages tried'}`);
});

await guard('G-filters', async () => {
  await gFresh();
  const ses0 = await gCol('sessions'), plat0 = await gCol('platform'), n = ses0.length;
  const v = await ev(`${gCell('sessions')}.textContent.trim()`), x = gNum(v);
  const menuAct = start => ev(`(() => { const b = [...document.querySelectorAll('.tm-menu button')].find(b => b.textContent.startsWith(${JSON.stringify(start)}) && b.getAttribute('aria-disabled') !== 'true'); b?.click(); return !!b; })()`);
  // Filter by value on sessions, then Exclude value on the platform of the first row it leaves: both hold (AND)
  await gmOpen(gCell('sessions')); const f1 = await menuAct('Filter by value'); await sleep(500);
  const ex = await ev(`${gCell('platform')}?.textContent.trim() ?? ''`);
  await gmOpen(gCell('platform')); const x1 = await menuAct('Exclude value'); await sleep(500);
  const both = await gCol('sessions'), bothP = await gCol('platform'), wantBoth = ses0.filter((s, i) => gNum(s) === x && plat0[i] !== ex).length;
  await gmOpen(gCell('sessions')); await gmPick('Clear filters'); await sleep(500);
  const back = (await gCol('sessions')).length;
  // All filters: each operator from a prompt holding the clicked value, against the count by hand (number cells only)
  const ops = { '=': a => a === x, '<>': a => a !== x, '>': a => a > x, '<': a => a < x, '>=': a => a >= x, '<=': a => a <= x };
  const opRes = [];
  for (const [op, test] of Object.entries(ops)) {
    await gmOpen(`${gRows}.map(tr => tr.children[${gIx('sessions')}]).find(td => td.textContent.trim() === ${JSON.stringify(v)})`);
    const okk = await gmPick('All filters', op); await sleep(300); const was = okk ? await gPrompt(null) : null; await sleep(500);
    const got = (await gCol('sessions')).length, want = ses0.filter(s => gNum(s) !== null && test(gNum(s))).length;
    opRes.push(`${op} ${v}: ${got}/${want}${was === v ? '' : ` (prompt held '${was}')`}`);
    if (!okk || got !== want || was !== v) opRes.push('BAD');
    await gmOpen(`${GT}.querySelector('thead tr:first-child th')`); await gmPick('Clear filters'); await sleep(400);
  }
  for (const [op, test] of [['Like', s => /^a/i.test(s)], ['Not like', s => !/^a/i.test(s)]]) {
    await gmOpen(gCell('platform')); const okk = await gmPick('All filters', op); await sleep(300); await gPrompt('a%'); await sleep(500);
    const got = (await gCol('platform')).length, want = plat0.filter(test).length;
    opRes.push(`${op} 'a%': ${got}/${want}`); if (!okk || got !== want) opRes.push('BAD');
    await gmOpen(`${GT}.querySelector('thead tr:first-child th')`); await gmPick('Clear filters'); await sleep(400);
  }
  const L = await gmOpen(gCell('sessions')); const clear = (L[0] ?? []).find(b => b.label === 'Clear filters'); await gmClose();
  check('G-filters', f1 && x1 && both.length === wantBoth && both.every(s => gNum(s) === x) && bothP.every(q => q !== ex) && back === n && !opRes.includes('BAD') && clear?.off === 'no filter is set',
    `sessions = '${v}' and platform not '${ex}': ${both.length} rows (${wantBoth} by hand, of ${n}); cleared ${back}; ${opRes.filter(r => r !== 'BAD').join('; ')}; with none set Clear filters ${clear ? (clear.off ?? 'ON') : 'absent'}`);
  // the quoting rule (SF4) on the fixture's grid: a menu-made value with ' & ' inside is one value; a typed 'R & D' keeps
  // today's meaning (contains); Like's prefill escapes _ and %
  await dropHostile();
  const txtCell = val => `${gRowsOf(GV)}.map(tr => tr.children[${gIx('txt', GV)}]).find(td => td.textContent.trim() === ${JSON.stringify(val)})`;
  await gmOpen(txtCell('R & D')); const fr = await menuAct('Filter by value'); await sleep(500); const amp = await gCol('txt', GV);
  await gmOpen(`${GV}.querySelector('thead tr:first-child th')`); await gmPick('Clear filters'); await sleep(400);
  await gFilter('txt', 'R & D', GV); const typedAmp = await gCol('txt', GV); await gFilter('txt', '', GV);
  const oddCell = `${gRowsOf(GV)}.map(tr => tr.children[${gIx('we]ird"name', GV)}]).find(td => td.textContent.trim() === 'pg_stat_statements')`;
  await gmOpen(oddCell); const lk = await gmPick('All filters', 'Like'); await sleep(300); const pre = lk ? await gPrompt(null) : null; await sleep(400);
  const liked = await gCol('we]ird"name', GV);
  await closeDialogs();
  check('G-filters quoting', fr && JSON.stringify(amp) === JSON.stringify(['R & D']) && JSON.stringify(typedAmp) === JSON.stringify(['R & D', 'R & D dept']) && lk && pre === 'pg\\_stat\\_statements' && JSON.stringify(liked) === JSON.stringify(['pg_stat_statements']),
    `Filter by value 'R & D': ${JSON.stringify(amp)}; typed 'R & D': ${JSON.stringify(typedAmp)}; Like on 'pg_stat_statements': prefill '${pre}', ${JSON.stringify(liked)}`);
});

await guard('G-in', async () => {
  // IN / NOT IN from a selection inside one column: three name cells
  await gFresh();
  const names = await gCol('name'), n = names.length, j = await ev(gIx('name'));
  for (const r of [0, 1, 2]) await gClick(`${gRows}[${r}].children[${j}]`, { ctrlKey: true });
  const three = names.slice(0, 3);
  await gmOpen(`${gRows}[0].children[${j}]`); const inn = await gmPick('Filter by these values'); await sleep(500);
  const a = await gCol('name');
  await gmOpen(`${GT}.querySelector('thead tr:first-child th')`); await gmPick('Clear filters'); await sleep(400);
  for (const r of [0, 1, 2]) await gClick(`${gRows}[${r}].children[${j}]`, { ctrlKey: true });
  await gmOpen(`${gRows}[0].children[${j}]`); const out = await gmPick('Exclude these values'); await sleep(500);
  const b = await gCol('name');
  await gmOpen(`${GT}.querySelector('thead tr:first-child th')`); await gmPick('Clear filters'); await sleep(400); await gClearSel();
  check('G-in', inn && JSON.stringify([...a].sort()) === JSON.stringify([...three].sort()) && out && b.length === n - 3 && b.every(x => !three.includes(x)),
    `the three: ${three.join(', ')}; Filter by these values ${inn}: ${a.length} rows (${a.slice(0, 4).join(', ')}); Exclude these values ${out}: ${b.length} of ${n}`);
});

await guard('G-bars', async () => {
  await gFresh();
  const ses = (await gCol('sessions')).map(gNum), hi = Math.max(...ses.filter(x => x !== null)), lo = Math.min(...ses.filter(x => x !== null));
  const cellAt = val => `${gRows}.map(tr => tr.children[${gIx('sessions')}]).find(td => ${JSON.stringify(String(val))} === td.textContent.trim().replace(/,/g, ''))`;
  const look = val => ev(`(() => { const td = ${cellAt(val)}; if (!td) return null; const s = getComputedStyle(td); return { cls: td.className, bg: s.backgroundColor, img: s.backgroundImage, size: s.backgroundSize, pos: s.backgroundPosition }; })()`);
  const tableOf = s => (/<table[\s\S]*<\/table>/i.exec(s ?? '')?.[0] ?? '');
  const pick = async (...labels) => { await gmOpen(cellAt(hi)); return gmPick('Data bar', ...labels); };
  const htmlBefore = (await gmFile(gCell('sessions'), 'HTML', 'html'))?.text ?? null;
  const under = await pick('Under value'); await sleep(300); const u = await look(hi);
  const underOk = under && !!u && /gradient/.test(u.img) && /100%$/.test(u.pos) && !/^auto$|100% 100%/.test(u.size);
  const worse = await pick('Traffic light (higher is worse)'); await sleep(300); const wHi = await look(hi), wLo = await look(lo);
  const htmlWorse = (await gmFile(gCell('sessions'), 'HTML', 'html'))?.text ?? null;
  const better = await pick('Traffic light (higher is better)'); await sleep(300); const bHi = await look(hi), bLo = await look(lo);
  await send('Page.reload'); await sleep(1500); await go('#/instances'); const kept = await look(hi);
  const removed = await pick('Remove'); await sleep(300); const gone = await look(hi);
  const status = c => /\b(ok|warn|crit|status)\b/.test(c?.cls ?? '');
  // traffic lights: their own classes (never a status's), worse / better the two colours swapped, not in the files
  check('G-bars', underOk && worse && !!wHi && !!wLo && wHi.bg !== wLo.bg && !status(wHi) && !status(wLo) && better && bHi?.bg === wLo.bg && bLo?.bg === wHi.bg && kept?.bg === bHi?.bg
    && !!htmlBefore && tableOf(htmlBefore) === tableOf(htmlWorse) && removed && gone?.bg !== bHi?.bg && !/gradient/.test(gone?.img ?? ''),
    `Under value ${under}: ${JSON.stringify(u)}; worse ${worse}: ${hi} ${wHi?.bg} '${wHi?.cls}' / ${lo} ${wLo?.bg}; better ${better}: ${bHi?.bg} / ${bLo?.bg}; after a reload ${kept?.bg}; the HTML file's table the same with the lights on ${!!htmlBefore && tableOf(htmlBefore) === tableOf(htmlWorse)}; Remove ${removed}: ${gone?.bg} ${gone?.img}`);
});

await guard('G-keys', async () => {
  await gFresh();
  // the focus on the last control before the grid (never the grid's own box), then Tab: into the grid (one tab stop)
  await ev(`(() => { const t = ${GT}; const f = [...document.querySelectorAll('a[href], button, input, select, textarea, [tabindex]')].filter(e => e.tabIndex >= 0 && !t.contains(e) && !e.contains(t) && (e.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING) && e.offsetParent !== null);
    (f[f.length - 1] ?? document.body).focus(); })()`);
  await key('Tab', 'Tab', 9);
  const into = await ev(`(() => { const a = document.activeElement, t = ${GT}; return { inGrid: t.contains(a) || a === t, tag: a?.tagName, role: t.getAttribute('role'), rowcount: t.getAttribute('aria-rowcount'), n: ${gRows}.length,
    stops: [...t.querySelectorAll('tbody a[href], tbody button, tbody input, tbody [tabindex]')].filter(e => e.tabIndex >= 0 && e !== a).length }; })()`);
  await key('ArrowDown', 'ArrowDown', 40); await key('ArrowRight', 'ArrowRight', 39);
  const at = await ev(`(() => { const a = document.activeElement; return a?.tagName === 'TD' ? { r: ${gRows}.indexOf(a.parentElement), c: [...a.parentElement.children].indexOf(a) } : { tag: a?.tagName }; })()`);
  await key('F10', 'F10', 121, 8);
  const m = await ev(`(() => { const box = document.querySelector('.tm-menu'), a = document.activeElement, td = ${typeof at.c === 'number' ? `${gRows}[${at.r}].children[${at.c}]` : 'null'};
    const b = box?.getBoundingClientRect(), c = td?.getBoundingClientRect();
    return { open: !!box, focus: box?.contains(a) ? a.textContent.replace(/▸$/, '').trim() : a?.tagName, atCell: !!(b && c && b.left >= c.left - 8 && b.left <= c.right + 8 && b.top >= c.top - 8 && b.top <= c.bottom + 40) }; })()`);
  await gmClip();
  // Copy > Column: Right into Copy (Grid first), Down to Column, Enter
  await key('ArrowRight', 'ArrowRight', 39); await key('ArrowDown', 'ArrowDown', 40); await key('Enter', 'Enter', 13);
  const col = await gmCopied(), back = await ev(`document.activeElement?.tagName`);
  await key('F10', 'F10', 121, 8); await key('Escape', 'Escape', 27);
  const esc = await ev(`(() => { const a = document.activeElement; return { menus: document.querySelectorAll('.tm-menu').length, tag: a?.tagName, r: a?.tagName === 'TD' ? ${gRows}.indexOf(a.parentElement) : -1 }; })()`);
  await key('Tab', 'Tab', 9);
  const out = await ev(`(() => { const a = document.activeElement, t = ${GT}; return !t.contains(a) && a !== t && a !== t.parentElement; })()`);
  const colWant = (await ev(`${gRows}.map(tr => tr.children[${typeof at.c === 'number' ? at.c : 0}]?.textContent.trim().replace(/[\\t\\n]/g, ' ') ?? '')`)).join('\n');
  check('G-keys', into.inGrid && into.role === 'grid' && into.rowcount === String(into.n) && into.stops === 0 && at.r === 1 && at.c === 1 && m.open && m.focus === 'Copy' && m.atCell && col === colWant && back === 'TD' && esc.menus === 0 && esc.tag === 'TD' && esc.r === 1 && out,
    `Tab -> ${JSON.stringify(into)}; Down, Right -> ${JSON.stringify(at)}; Shift+F10 -> ${JSON.stringify(m)}; Right, Down, Enter (Copy > Column) -> ${col === colWant ? 'the column' : `'${(col ?? 'nothing').slice(0, 60)}'`}, the focus ${back}; Shift+F10, Escape -> ${JSON.stringify(esc)}; Tab leaves the grid ${out}`);
});

await guard('G-grouped', async () => {
  await gFresh();
  const n = (await gCol('sessions')).length;
  await gmOpen(gCell('platform')); const g = await gmPick('Group by platform'); await sleep(500);
  const panel = await ev(`!!document.querySelector('main .gt-groups')`);
  const L = await gmOpen(gCell('sessions'));
  const grid = await gmCopy(gCell('sessions'), 'Copy', 'Grid');
  // the group panel's own table has the menu too
  const P = await gmOpen(`document.querySelector('main .gt-groups table tbody td')`);
  await gmOpen(gCell('sessions')); await gmPick('Ungroup'); await sleep(300);
  check('G-grouped', g && panel && (L[0] ?? []).length > 0 && (grid ?? '').replace(/\r/g, '').split('\n').length === n + 1 && (P[0] ?? []).some(x => x.label === 'Copy'),
    `Group by platform ${g}, its panel ${panel}; the grid's menu then: ${(L[0] ?? []).map(x => x.label).slice(0, 6).join(' / ') || '(no .tm-menu)'}...; Copy Grid ${(grid ?? '').split('\n').length - 1} rows of ${n}; the panel's own menu: ${(P[0] ?? []).map(x => x.label).slice(0, 4).join(' / ') || '(no .tm-menu)'}`);
});

await guard('G-empty0', async () => {
  // a grid empty from the start (ui.ts's div.empty-grid): its menu all the same
  let hit = null;
  for (const h of ['#/alerts', '#/corruption', '#/dms', '#/replication', '#/pgreplication', '#/dbchanges', `#/jobs?i=${erpId}`, `#/logs?i=${erpId}`, `#/replication?i=${erpId}`]) {
    await go(h); if (await ev(`!!document.querySelector('main .empty-grid')`)) { hit = h; break; }
  }
  const L = hit ? await gmOpen(`document.querySelector('main .empty-grid table, main .empty-grid')`) : [];
  const top = L[0] ?? [];
  const copy = hit ? await (async () => { await gmOpen(`document.querySelector('main .empty-grid table, main .empty-grid')`); await gmPick('Copy'); const s = (await gmLevels())[1] ?? []; await gmClose(); return s; })() : [];
  const xl = top.find(x => x.label === 'Export Excel');
  check('G-empty0', !!hit && copy.length > 0 && copy.every(x => x.off === 'No data to copy') && !!xl && xl.off === null && top.some(x => x.label === 'Columns...') && top.some(x => /^Rows: 0\b/.test(x.label)),
    `${hit ?? 'no empty grid on the pages tried'}: ${top.map(x => x.label + (x.off ? ` (${x.off})` : '')).join(' / ') || '(no .tm-menu)'}; Copy: ${copy.map(x => `${x.label} ${x.off ?? 'ON'}`).join(' / ')}`);
});

await guard('G-dialog', async () => {
  // a file viewer's grid (a modal dialog): the menu in that dialog, Copy > Cell copies
  await dropHostile();
  const td = `${gRowsOf(GV)}[1].children[${gIx('txt', GV)}]`;
  const L = await gmOpen(td);
  const inDialog = (L[0] ?? []).length > 0 && (L[0] ?? []).every(x => x.inDialog);
  const cell = await gmCopy(td, 'Copy', 'Cell');
  await closeDialogs();
  check('G-dialog', inDialog && cell === 'a]b', `the menu ${(L[0] ?? []).length ? (inDialog ? 'inside the dialog' : 'OUTSIDE the dialog') : '(no .tm-menu)'}; Copy > Cell '${cell}'`);
});

await guard('G-sql', async () => {
  // the hostile fixture's two SQL files run on the box's PostgreSQL (once with standard_conforming_strings off for the
  // session) and its SQL Server; every row read back equal (NUL dropped, said in the header); a table t survives
  await dropHostile();
  const td = `${gRowsOf(GV)}[0].children[0]`;
  const pgf = await gmFile(td, 'SQL (INSERT) for PostgreSQL', 'sql'), msf = await gmFile(td, 'SQL (INSERT) for SQL Server', 'sql');
  await closeDialogs();
  const res = [];
  const cmp = (rows, tag) => {
    if (!Array.isArray(rows) || rows.length !== want.length) { res.push(`${tag}: ${Array.isArray(rows) ? rows.length : 'no'} rows read back`); return; }
    rows.forEach((r, i) => { const w = want[i], vals = Object.values(r);
      const okRow = Number(vals[0]) === w.id && vals[1] === w.txt && vals[2] === w['we]ird"name'] && Number(vals[3]) === w.num && (vals[4] ?? null) === w[''];
      if (!okRow) res.push(`${tag} row ${w.id}: ${JSON.stringify(vals).slice(0, 160)}`); });
    const names = Object.keys(rows[0] ?? {});
    if (names[2] !== 'we]ird"name' || !/^column_\d+$/.test(names[4] ?? '')) res.push(`${tag} names ${JSON.stringify(names)}`);
  };
  if (!pgf || !msf) res.push(`files: PostgreSQL ${pgf?.name ?? 'none'}, SQL Server ${msf?.name ?? 'none'}`);
  else {
    if (!/NUL/.test(pgf.text.split('\n').filter(l => l.startsWith('--') || l.startsWith('﻿--')).join(' '))) res.push('the PostgreSQL header names no NUL dropped');
    fs.writeFileSync(path.join(work, 'gm-pg.sql'), pgf.buf); fs.writeFileSync(path.join(work, 'gm-ms.sql'), msf.buf);
    psql('create table if not exists t (x int)');
    // -f: psql runs the file a statement at a time; whole: the file as ONE query (psql -c, as pgAdmin's F5 sends it),
    // lexed before its SET runs - with standard_conforming_strings off it is the hostile row's injection path (gm2 B2)
    for (const [scs, whole] of [['on', false], ['off', false], ['off', true]]) {
      const tag = `PostgreSQL (standard_conforming_strings ${scs}${whole ? ', the file as one query' : ''})`;
      try {
        const o = execFileSync('psql', [`${dsn} dbname=${db}`, '-XAtq', '-v', 'ON_ERROR_STOP=1', ...(whole ? ['-c', pgf.text] : ['-f', path.join(work, 'gm-pg.sql')]), '-c', '\\echo @@READBACK', '-c', 'select row_to_json(g)::text from pg_temp.pgvigil_grid g order by g.id'],
          { encoding: 'utf8', env: { ...process.env, PGOPTIONS: `-c standard_conforming_strings=${scs}` } });
        cmp(o.split('\n@@READBACK\n')[1]?.split('\n').filter(Boolean).map(l => JSON.parse(l)), tag);
      } catch (e) { res.push(`${tag}: ${String(e.stderr ?? e.message).split('\n').slice(0, 3).join(' | ')}`); }
      if (psql(`select count(*) from pg_class where relname = 't' and relkind = 'r'`) !== '1') { res.push(`table t is GONE after ${tag}`); psql('create table if not exists t (x int)'); }
    }
    if (psql(`select count(*) from pg_class where relname = 't' and relkind = 'r'`) !== '1') res.push('table t is GONE');
    const sc = process.env.PGVIGIL_MENU_MSSQL, ef = process.env.PGVIGIL_MENU_MSSQL_ENV;
    if (!sc || !ef) res.push('no SQL Server given (PGVIGIL_MENU_MSSQL / PGVIGIL_MENU_MSSQL_ENV: proof-gridmenu.sh starts one)');
    else {
      const rb = `\nGO\nPRINT '@@READBACK';\nDECLARE @o int = OBJECT_ID('tempdb..#pgvigil_grid');
SELECT STRING_AGG(CONVERT(varchar(max), CONVERT(varbinary(max), CAST(name AS nvarchar(max))), 2), '|') WITHIN GROUP (ORDER BY column_id) FROM tempdb.sys.columns WHERE object_id = @o;
DECLARE @s nvarchar(max) = N'SELECT ' + (SELECT STRING_AGG(CAST(N'ISNULL(CONVERT(varchar(max), CONVERT(varbinary(max), CAST(' + QUOTENAME(name) + N' AS nvarchar(max))), 2), ''NULL'')' AS nvarchar(max)), N' + ''|'' + ') WITHIN GROUP (ORDER BY column_id) FROM tempdb.sys.columns WHERE object_id = @o)
  + N' FROM #pgvigil_grid ORDER BY ' + (SELECT QUOTENAME(name) FROM tempdb.sys.columns WHERE object_id = @o AND column_id = 1);
EXEC (@s);\nGO\n`;
      try {
        const o = execFileSync('docker', ['exec', '-i', '--env-file', ef, sc, 'bash', '-c', 'SQLCMDPASSWORD=$SA_PW /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -I -f 65001 -y 0 -h -1 -d tempdb -i /dev/stdin'],
          { input: Buffer.concat([msf.buf, Buffer.from(rb, 'utf8')]), encoding: 'utf8', maxBuffer: 64 << 20 });
        const after = o.split('@@READBACK')[1]?.split('\n').map(l => l.trimEnd()).filter(l => l && !/rows? affected/.test(l)) ?? [];
        const hex = h => h === 'NULL' ? null : Buffer.from(h, 'hex').toString('utf16le');
        const names = (after[0] ?? '').split('|').map(hex);
        cmp(after.slice(1).map(l => Object.fromEntries(l.split('|').map((h, k) => [names[k] ?? 'c' + k, hex(h)]))), 'SQL Server');
      } catch (e) { res.push(`SQL Server: ${String(e.stderr ?? e.stdout ?? e.message).split('\n').filter(Boolean).slice(0, 3).join(' | ')}`); }
    }
  }
  check('G-sql', res.length === 0, res.length ? res.join('; ').slice(0, 900) : `${want.length} rows read back equal on PostgreSQL (standard_conforming_strings on and off) and SQL Server; table t intact`);
});

await guard('G-stmt', async () => {
  // a statement cell is a button (sqlview.ts): its right-click opens the grid's menu, Copy > Cell gives the statement
  await go(`#/statements?i=${erpId}`); await sleep(500);
  const btn = `document.querySelector('main table.grid tbody td button')`;
  const L = await gmOpen(btn);
  const cell = await gmCopy(btn, 'Copy', 'Cell'), full = await ev(`(() => { const b = ${btn}; const td = b?.closest('td'); return td?.getAttribute('data-full') ?? b?.getAttribute('data-full') ?? td?.textContent.trim() ?? ''; })()`);
  check('G-stmt', (L[0] ?? []).some(x => x.label === 'Copy') && !!cell && cell.length > 0 && (cell === full || full.startsWith(cell.slice(0, 40))),
    `a statement button's right-click: ${(L[0] ?? []).map(x => x.label).slice(0, 4).join(' / ') || '(no .tm-menu)'}; Copy > Cell '${(cell ?? 'nothing').slice(0, 60)}'`);
});

await guard('G-plain', async () => {
  // a table.grid not drawn by grid() (slow.ts's own tables, each inside a .grid-wrap of its own; grid()'s sit in a
  // .grid-box): the menu through the delegated handler (review-15 gm1 B1)
  const sel = `[...document.querySelectorAll('main table.grid')].find(t => !t.closest('.grid-box'))?.querySelector('tbody td')`;
  let found = false;
  for (const h of ['#/slowqueries', `#/slowqueries?i=${erpId}`]) { await go(h); await sleep(800); found = await ev(`!!${sel}`); if (found) break; }
  const L = found ? await gmOpen(sel) : [];
  const cell = found ? await gmCopy(sel, 'Copy', 'Cell') : null, want0 = found ? await ev(`${sel}.textContent.trim()`) : null;
  check('G-plain', found && (L[0] ?? []).some(x => x.label === 'Copy') && cell === want0, `${found ? 'slow.ts table found' : 'no table.grid outside a .grid-box on the slow pages'}; its menu: ${(L[0] ?? []).map(x => x.label).slice(0, 4).join(' / ') || '(no .tm-menu)'}; Copy > Cell '${cell}' (want '${want0}')`);
});

await guard('G-mssql', async () => {
  // a SQL Server instance's grid: the same menu
  await go(`#/drives?i=${idOf('demo-onprem-sql01')}`); await sleep(500);
  const L = await gmOpen(`document.querySelector('main table.grid tbody td')`), top = (L[0] ?? []).map(x => x.label);
  const wantTop = ['Copy', 'Export Excel', 'Export file', 'Transpose', 'Select', 'Columns...', 'Row numbers', 'All filters', 'Clear filters'];
  await gmClose();
  check('G-mssql', wantTop.every(w => top.includes(w)), `demo-onprem-sql01's Drives grid: ${top.join(' / ') || '(no .tm-menu)'}`);
});

await guard('G-chart', async () => {
  // a chart's own menu stays ui.ts's showMenu (unchanged by GM: green on both sides)
  let opened = false;
  for (const h of [`#/summary?i=${erpId}`, `#/performance?i=${erpId}`, '#/perfsummary']) {
    await go(h); await sleep(1500);
    opened = await ev(`(() => { const b = [...document.querySelectorAll('main button')].find(b => [b.getAttribute('aria-label'), b.title, b.textContent].some(s => /^Chart menu/.test(s ?? ''))); b?.click(); return !!b; })()`);
    if (opened) break;
  }
  await sleep(300);
  const items = await ev(`[...document.querySelectorAll('.menu:not(.tm-menu) button')].map(b => b.textContent.trim())`);
  await gmClose();
  check('G-chart', opened && ['Copy image', 'Save image', 'Copy data', 'Export data (CSV)', 'Export Excel'].every(x => items.includes(x)) && !(await ev(`!!document.querySelector('.tm-menu')`)),
    `a chart's menu ${opened ? 'opened' : 'button not found'}: ${items.join(' / ')}`);
});

await guard('G-big', async () => {
  // a 10,000-row grid (a dropped file): the menu's open time read and said (no threshold yet: a number first)
  const big = Array.from({ length: 10000 }, (_, i) => ({ id: i + 1, name: 'row ' + (i + 1), n: (i * 7919) % 1000, at: '2026-11-14' }));
  await dropHostile(big, 'gm-big.json');
  const t = await ev(`(() => { const t = ${GV}; const td = t?.querySelector('tbody td:nth-child(3)'); if (!td) return null; const r = td.getBoundingClientRect();
    const a = performance.now(); td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5 })); const ms = performance.now() - a;
    return { ms: Math.round(ms), tm: !!document.querySelector('.tm-menu'), rows: t.getAttribute('aria-rowcount') ?? t.dataset.rows ?? '' }; })()`);
  await gmClose(); await closeDialogs();
  check('G-big', !!t && t.tm, t ? `the menu on a 10,000-row grid opened in ${t.ms} ms (${t.tm ? '.tm-menu' : 'no .tm-menu'}; rows ${t.rows})` : 'the grid did not draw');
});

if (shots) await guard('G-themes', async () => {
  const both = {};
  for (const theme of ['light', 'dark']) {
    await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)})`); await send('Page.reload'); await sleep(1500); await go('#/instances');
    await gmOpen(gCell('sessions')); await gmPick('Copy'); await sleep(200);
    both[theme] = await ev(`(() => { const b = document.querySelector('.tm-menu'); return b ? getComputedStyle(b).backgroundColor : null; })()`);
    await shot(`gm-menu-${theme}`); await gmClose();
    await gmOpen(gCell('sessions')); await gmPick('Transpose', 'This row'); await sleep(400); await shot(`gm-transpose-${theme}`); await closeDialogs();
  }
  await ev(`localStorage.setItem('pgvigil.theme', 'light')`); await send('Page.reload'); await sleep(1500);
  const wantShots = ['gm-menu-light', 'gm-menu-dark', 'gm-transpose-light', 'gm-transpose-dark'].map(x => x + '.png');
  const missing = wantShots.filter(f => !fs.existsSync(path.join(shots, f)) || fs.statSync(path.join(shots, f)).mtimeMs < started);
  check('G-themes', !!both.light && !!both.dark && both.light !== both.dark && missing.length === 0, `the menu's background light ${both.light}, dark ${both.dark}; ${wantShots.length - missing.length} of ${wantShots.length} pictures${missing.length ? ', missing ' + missing.join(', ') : ''}`);
});

const xdl = `<deadlock><victim-list><victimProcess id="process1"/></victim-list><process-list>
<process id="process1" spid="55" waitresource="KEY: 5:72057594045071360 (8194443284a0)" waittime="4012" lockMode="U" loginname="app" hostname="web01" clientapp="api" currentdbname="orders" isolationlevel="read committed (2)" trancount="2"><executionStack><frame procname="orders.dbo.upd_a" line="5">UPDATE dbo.a SET x = 1 WHERE id = 1</frame></executionStack><inputbuf>EXEC dbo.upd_a 1</inputbuf></process>
<process id="process2" spid="61" waitresource="KEY: 5:72057594045136896 (a1b2c3d4e5f6)" waittime="3988" lockMode="U" loginname="app" hostname="web02" clientapp="api" currentdbname="orders" isolationlevel="read committed (2)" trancount="2"><executionStack><frame procname="orders.dbo.upd_b" line="7">UPDATE dbo.b SET y = 2 WHERE id = 1</frame></executionStack><inputbuf>EXEC dbo.upd_b 1</inputbuf></process>
</process-list><resource-list>
<keylock hobtid="72057594045071360" dbid="5" objectname="orders.dbo.a" indexname="PK_a" id="lock1" mode="X" associatedObjectId="72057594045071360"><owner-list><owner id="process2" mode="X"/></owner-list><waiter-list><waiter id="process1" mode="U" requestType="wait"/></waiter-list></keylock>
<keylock hobtid="72057594045136896" dbid="5" objectname="orders.dbo.b" indexname="PK_b" id="lock2" mode="X" associatedObjectId="72057594045136896"><owner-list><owner id="process1" mode="X"/></owner-list><waiter-list><waiter id="process2" mode="U" requestType="wait"/></waiter-list></keylock>
</resource-list></deadlock>`;
const sqlplan = `<?xml version="1.0" encoding="utf-16"?>
<ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564" Build="16.0.4165.4"><BatchSequence><Batch><Statements>
<StmtSimple StatementText="SELECT o.id, o.total FROM dbo.orders o WHERE o.customer_id = @c" StatementId="1" StatementCompId="1" StatementType="SELECT" StatementSubTreeCost="0.5" StatementEstRows="40">
<QueryPlan DegreeOfParallelism="1" CompileTime="3"><MemoryGrantInfo SerialRequiredMemory="0" SerialDesiredMemory="0" GrantedMemory="0"/>
<MissingIndexes><MissingIndexGroup Impact="81.5"><MissingIndex Database="[shop]" Schema="[dbo]" Table="[orders]"><ColumnGroup Usage="EQUALITY"><Column Name="[customer_id]" ColumnId="2"/></ColumnGroup><ColumnGroup Usage="INCLUDE"><Column Name="[total]" ColumnId="5"/></ColumnGroup></MissingIndex></MissingIndexGroup></MissingIndexes>
<RelOp NodeId="0" PhysicalOp="Nested Loops" LogicalOp="Inner Join" EstimateRows="40" EstimatedTotalSubtreeCost="0.5" Parallel="0">
<RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="40" ActualExecutions="1"/></RunTimeInformation>
<NestedLoops Optimized="0">
<RelOp NodeId="1" PhysicalOp="Index Seek" LogicalOp="Index Seek" EstimateRows="40" EstimatedTotalSubtreeCost="0.1" Parallel="0"><RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="40" ActualExecutions="1"/></RunTimeInformation><IndexScan><Object Database="[shop]" Schema="[dbo]" Table="[orders]" Index="[ix_orders_date]"/></IndexScan></RelOp>
<RelOp NodeId="2" PhysicalOp="Clustered Index Seek" LogicalOp="Clustered Index Seek" EstimateRows="1" EstimatedTotalSubtreeCost="0.3" Parallel="0"><Warnings><ColumnsWithNoStatistics><ColumnReference Column="total"/></ColumnsWithNoStatistics></Warnings><RunTimeInformation><RunTimeCountersPerThread Thread="0" ActualRows="40" ActualExecutions="40"/></RunTimeInformation><IndexScan Lookup="1"><Object Database="[shop]" Schema="[dbo]" Table="[orders]" Index="[pk_orders]"/></IndexScan></RelOp>
</NestedLoops></RelOp></QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>`;
const rowsJson = JSON.stringify([{ name: 'a', n: 1 }, { name: 'b', n: 2 }, { name: 'c', n: 3 }]);
fs.writeFileSync(path.join(work, 'dl.xdl'), xdl);
fs.writeFileSync(path.join(work, 'p16.sqlplan'), Buffer.concat([Buffer.from([0xff, 0xfe]), Buffer.from(sqlplan, 'utf16le')]));
fs.writeFileSync(path.join(work, 'p.sqlplan'), sqlplan);
const viewerNow = () => ev(`(() => { const d = document.querySelector('dialog.fd-viewer[open]'); return d ? d.getAttribute('aria-label') : ''; })()`);
await guard('T tools', async () => {
  await go('#/summary');
  await ev(`[...document.querySelectorAll('#bar button')].find(b => b.textContent === 'Tools').click()`);
  const m = await menuItems();
  const exp = await ev(`[...document.querySelectorAll('#bar button')].find(b => b.textContent === 'Tools').getAttribute('aria-expanded')`);
  await shot('tools-menu-light');
  await send('Page.setInterceptFileChooserDialog', { enabled: true });
  const chooser = event('Page.fileChooserOpened');
  await clickItem('Open Deadlock Graph');
  const fc = await chooser;
  await send('DOM.setFileInputFiles', { files: [path.join(work, 'dl.xdl')], backendNodeId: fc.backendNodeId });
  await sleep(1000);
  const d = await ev(`(() => { const d = document.querySelector('dialog.fd-viewer[open]'); if (!d) return null; const gs = d.querySelectorAll('table.grid');
    return { title: d.getAttribute('aria-label'), svg: !!d.querySelector('svg'), sessions: gs[0]?.querySelectorAll('tbody tr').length, victim: [...(gs[0]?.querySelectorAll('tbody tr') ?? [])].find(tr => tr.textContent.includes('victim'))?.children[0].textContent, resources: gs[1]?.querySelectorAll('tbody tr').length }; })()`);
  await shot('open-xdl-light');
  // a grid's own menu inside the viewer: drawn in the dialog (the top layer), its first item focused
  const inside = await ev(`(async () => { const td = document.querySelector('dialog.fd-viewer[open] table.grid tbody td'); const r = td.getBoundingClientRect();
    td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5 })); await new Promise(r => setTimeout(r, 100));
    const m = document.querySelector('.menu'); const ok = !!m && !!m.closest('dialog[open]') && document.activeElement?.closest('.menu') === m;
    document.activeElement?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return ok; })()`);
  await closeDialogs();
  // SSMS saves a .sqlplan as UTF-16 with a byte-order mark
  await ev(`[...document.querySelectorAll('#bar button')].find(b => b.textContent === 'Tools').click()`);
  const chooser2 = event('Page.fileChooserOpened');
  await clickItem('Open Query Plan');
  await send('DOM.setFileInputFiles', { files: [path.join(work, 'p16.sqlplan')], backendNodeId: (await chooser2).backendNodeId });
  await sleep(1000);
  const p16 = await ev(`(() => { const d = document.querySelector('dialog.fd-viewer[open]'); return d ? d.getAttribute('aria-label') + ': ' + (d.querySelector('table.grid')?.querySelectorAll('tbody tr').length ?? 0) : 'none'; })()`);
  await send('Page.setInterceptFileChooserDialog', { enabled: false });
  await closeDialogs();
  check('T tools', m[0] === 'Open Deadlock Graph | *.xdl|Open Query Plan | *.sqlplan|Open Grid or Data Set | *.json;*.csv;*.gz' && exp === 'true' && d && d.title === 'Deadlock graph: dl.xdl' && d.svg && d.sessions === 2 && d.victim === 'Session 55' && d.resources === 2 && inside && p16 === 'Query plan: p16.sqlplan: 3',
    `${m[0]}; expanded ${exp}; ${JSON.stringify(d)}; the grid menu inside the viewer ${inside}; UTF-16 plan: ${p16}`);
});
await guard('X drop and paste', async () => {
  // a real drag of a file from outside the page (the browser's own dragenter, dragover, drop): a page that let the
  // browser keep the drop would navigate to the file and the viewer would never open
  const drag = async (type, files) => send('Input.dispatchDragEvent', { type, x: 640, y: 400, data: { items: [], files, dragOperationsMask: 1 } });
  await drag('dragEnter', [path.join(work, 'p.sqlplan')]); await drag('dragOver', [path.join(work, 'p.sqlplan')]); await drag('drop', [path.join(work, 'p.sqlplan')]);
  await sleep(1000);
  const p = await ev(`(() => { const d = document.querySelector('dialog.fd-viewer[open]'); if (!d) return { page: location.href }; const gs = d.querySelectorAll('table.grid');
    const ths = [...gs[0].querySelectorAll('thead tr:first-child th')].map(h => h.textContent); const c = ths.indexOf('cost %'), w = ths.indexOf('warnings'), pa = ths.indexOf('parent node');
    const rows = [...gs[0].querySelectorAll('tbody tr')]; return { title: d.getAttribute('aria-label'), ops: rows.length, cost: rows.map(r => r.children[c].textContent).join(' / '), warn: rows[2]?.children[w].textContent,
      parents: rows.map(r => r.children[pa].textContent).join(','), missing: gs[1] ? [...gs[1].querySelectorAll('tbody tr')].map(r => r.children[0].textContent).join(',') : '' }; })()`);
  await shot('open-sqlplan-light');
  await closeDialogs();
  const paste = (sel) => ev(`(() => { const dt = new DataTransfer(); dt.setData('text/plain', ${JSON.stringify(xdl)}); (${sel}).dispatchEvent(new ClipboardEvent('paste', { bubbles: true, cancelable: true, clipboardData: dt })); })()`);
  await paste('document.querySelector(\'#tree input[type=search]\')'); await sleep(600);
  const inField = await viewerNow();
  await paste('document.body'); await sleep(600);
  const pasted = await viewerNow();
  await closeDialogs();
  await ev(`(() => { const dt = new DataTransfer(); dt.items.add(new File([${JSON.stringify(rowsJson)}], 'rows.json')); document.body.dispatchEvent(new DragEvent('drop', { bubbles: true, cancelable: true, dataTransfer: dt })); })()`);
  await sleep(600);
  const j = await ev(`(() => { const d = document.querySelector('dialog.fd-viewer[open]'); return d ? { title: d.getAttribute('aria-label'), rows: d.querySelectorAll('table.grid tbody tr').length } : null; })()`);
  await closeDialogs();
  check('X drop and paste', p && p.title === 'Query plan: p.sqlplan' && p.ops === 3 && p.cost === '20 % / 20 % / 60 %' && p.parents === ',0,0' && /no statistics/.test(p.warn ?? '') && p.missing === '81.5'
    && inField === '' && pasted === 'Deadlock graph: pasted deadlock graph' && j && j.title === 'Grid: rows.json' && j.rows === 3,
    `${JSON.stringify(p)}; a paste into the search field opened '${inField}'; on the page '${pasted}'; ${JSON.stringify(j)}`);
});

// ---- RT: the Data Retention page against a hand read ----
await guard('RT retention', async () => {
  // a partition three months back, so a purge at one day has something of activity_sample to drop
  psql(`select pgvigil.ensure_month_partition('activity_sample', now() - interval '3 months')`);
  const actSize = () => Number(psql(`select pg_total_relation_size('pgvigil.activity_sample') + coalesce((select sum(pg_total_relation_size(inhrelid)) from pg_inherits where inhparent = 'pgvigil.activity_sample'::regclass), 0)`));
  const hand = {
    tables: Number(psql(`select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'pgvigil' and c.relkind in ('r','p') and not c.relispartition`)),
    act: actSize(),
    oldest: Number(psql(`select coalesce(extract(epoch from min(start_time)), 0) from pgvigil.job_runs`)),
    actDrop: Number(psql(`select count(*) from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'pgvigil.activity_sample'::regclass
      and c.relname ~ '_[0-9]{6}$' and (to_date(right(c.relname, 6) || '01', 'YYYYMMDD') + interval '1 month') at time zone 'UTC' < now() - interval '1 day'`)),
    reqDrop: Number(psql(`select count(*) from pg_inherits i join pg_class c on c.oid = i.inhrelid where i.inhparent = 'pgvigil.mssql_requests'::regclass
      and c.relname ~ '_[0-9]{8}$' and (to_date(right(c.relname, 8), 'YYYYMMDD') + interval '1 day') at time zone 'UTC' < now() - interval '1 day'`)),
  };
  const a = await api('retention', { days: 1 });
  const act2 = actSize();   // a vacuum between the two reads (a new visibility map) is not the page's fault
  const rows = rowsOf(a.tables), by = n => rows.find(r => r.table_name === n) ?? {};
  await go('#/retention');
  await ev(`(async () => { const i = document.getElementById('ret-days'); i.value = '1'; [...document.querySelectorAll('main button')].find(b => b.textContent === 'Preview').click();
    for (let k = 0; k < 80 && ![...document.querySelectorAll('main table.grid thead th')].some(h => h.textContent.includes('at 1 days')); k++) await new Promise(r => setTimeout(r, 250)); })()`);
  const page = await ev(`(() => { const t = document.querySelector('main table.grid'); const ths = [...t.querySelectorAll('thead tr:first-child th')].map(h => h.textContent);
    const cell = (n, h) => { const tr = [...t.querySelectorAll('tbody tr')].find(tr => tr.children[1].textContent === n); return tr ? tr.children[ths.indexOf(h)].textContent : null; };
    return { n: Number(t.dataset.rows), head: ths.join('|'), jobRule: cell('job_runs', 'Retention'), jobCol: cell('job_runs', 'By column'), actDrop: cell('activity_sample', 'Partitions a purge at 1 days drops'),
      reqRule: cell('mssql_requests', 'Retention'), qtSame: cell('query_text', 'Same as') }; })()`);
  await shot('retention-light');
  const ar = by('activity_sample'), jr = by('job_runs'), qt = by('query_text'), ins = by('instances'), rq = by('mssql_requests');
  const okOld = hand.oldest === 0 ? jr.oldest_row == null : Math.abs(Date.parse(jr.oldest_row) / 1000 - hand.oldest) < 1;
  check('RT retention', rows.length === hand.tables && page.n === hand.tables && (Number(ar.size_bytes) === hand.act || Number(ar.size_bytes) === act2) && ar.retention === 'monthly partitions'
    && hand.actDrop > 0 && Number(ar.would_drop) === hand.actDrop && page.actDrop === String(hand.actDrop)
    && rq.retention === 'daily partitions' && page.reqRule === 'daily partitions' && Number(rq.would_drop) === hand.reqDrop
    && jr.retention === 'rows older than the age' && jr.judged === true && jr.column_name === 'start_time' && page.jobRule === 'rows older than the age' && page.jobCol === 'start_time' && okOld
    && qt.same_as === 'activity_sample' && qt.judged === false && page.qtSame === 'activity_sample' && ins.retention === 'kept whole',
    `${rows.length} / page ${page.n} tables for ${hand.tables} by hand; activity_sample ${ar.size_bytes} vs ${hand.act} / ${act2}, ${ar.retention}, drops ${ar.would_drop} (page ${page.actDrop}) vs ${hand.actDrop} by hand; `
    + `mssql_requests ${rq.retention}, drops ${rq.would_drop} vs ${hand.reqDrop}; job_runs ${jr.retention} by ${jr.column_name} (page ${page.jobRule} / ${page.jobCol}), oldest ${jr.oldest_row} vs epoch ${hand.oldest}; `
    + `query_text same as ${qt.same_as}, judged ${qt.judged}; instances ${ins.retention}`);
});

// ---- the dark theme's pictures ----
if (shots) await guard('S shots', async () => {
  await ev(`localStorage.setItem('pgvigil.theme', 'dark')`);
  await send('Page.reload'); await sleep(1500);
  await go('#/summary');
  const theme = await ev(`document.documentElement.getAttribute('data-theme')`);
  await rightClick(`document.querySelector('#tree a.tree-root')`); await shot('tree-root-menu-dark'); await escape();
  await rightClick(`${treeInst(erp)}?.querySelector('a.inst')`); await clickItem('Instance Actions'); await sleep(200); await shot('tree-instance-menu-dark');
  await ev(`document.querySelectorAll('.tm-menu').forEach(m => m.remove())`);
  await go('#/instances');
  await rightClick(`document.querySelector('main table.grid tbody td:nth-child(3)')`); await shot('grid-cell-menu-dark');
  await ev(`document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
  await go('#/retention'); await sleep(1500); await shot('retention-dark');
  const want = ['tree-root-menu', 'find-database', 'add-connections', 'tree-instance-menu', 'pause-resume', 'add-blackout', 'tree-jobs-folder-menu', 'tree-job-menu', 'execute-job',
    'tree-drives', 'grid-cell-menu', 'tools-menu', 'open-xdl', 'open-sqlplan', 'retention'].map(n => n + '-light.png')
    .concat(['tree-root-menu', 'tree-instance-menu', 'grid-cell-menu', 'retention'].map(n => n + '-dark.png'));
  const missing = want.filter(f => !fs.existsSync(path.join(shots, f)) || fs.statSync(path.join(shots, f)).mtimeMs < started);
  check('S shots', theme === 'dark' && missing.length === 0, `theme ${theme}; ${want.length - missing.length} of ${want.length} pictures written by this run${missing.length ? ', missing ' + missing.join(', ') : ''}`);
});

ws.close();
console.log(failed ? `FAIL: ${failed} case(s)` : 'PASS: menu-check');
cleanup();
process.exit(failed ? 1 : 0);
