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
// Prints one 'ok <case>: ...' or 'FAIL <case>: ...' line per case and 'PASS' / 'FAIL' last; exit 1 on a failed case.
//
// Expected (written before the first run; the cases marked (run 3) rewritten after review s172-1, before run 3):
//   R1 root menu      'Refresh|Add Connections...|Find Database|Open in a new tab' on a right-click of 'All instances'; role
//                     menu, each item menuitem (run 3)
//   R2 refresh        on About (no live page): no /api/instances read in 1.5 s alone, a new one after Refresh (run 3)
//   R3 add            Add Connections: name sql09, SQL Server, env PGVIGIL_DSN_SQL09 -> the lines '  - name: sql09',
//                     '    engine: sqlserver', '    dsn: env:PGVIGIL_DSN_SQL09'; SQL Server's platforms
//                     'auto,onprem,rds,azuresqldb,azuresqlmi'; a name already in the fleet said so (run 3)
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
//   G  grid menu      Instances' first non-empty sessions cell: one 'Export Excel' line before them, then 'Select row|Select
//                     column|Filter by value: <v>|Exclude value (contains)|Select all|Rows: <n> | Cols: <m>|[sessions] Sum: <s> | Avg:
//                     <a> | Min | Max' after the grid's own items, over the non-empty cells summed by hand (run 3: empty
//                     cells are no numbers); Select column -> n cells, the tools' line says so, the menu then 'Selected
//                     Cells: n (<numbers> numeric) | Sum: <s> ...'; Select row -> the m cells of one row; Filter by value
//                     (a number column: '=') -> exactly the rows showing v; Exclude value -> the rows not holding v; Clear
//                     filters -> n rows each time; Export Excel -> an .xlsx (PK, a worksheet) downloaded; (run 4) a version
//                     cell ('17.10', a text column): no Sum line, the menu ends with 'Rows: ...'
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
const guard = async (name, f) => { try { await f(); } catch (e) { check(name, false, 'threw: ' + (e instanceof Error ? e.message : String(e)).slice(0, 400)); } };
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
    && t.plats === 'auto,onprem,rds,azuresqldb,azuresqlmi' && /in the fleet already/.test(t.taken),
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

// ---- G: the grid cell menu ----
await guard('G grid menu', async () => {
  await go('#/instances');
  const col = `[...document.querySelectorAll('main table.grid thead tr:first-child th')].findIndex(h => h.textContent === 'sessions')`;
  const g = await ev(`(async () => {
    const t = document.querySelector('main table.grid'); const ths = [...t.querySelectorAll('thead tr:first-child th')];
    const j = ${col}; const trs = [...t.querySelectorAll(':scope > tbody > tr')];
    const texts = trs.map(tr => tr.children[j].textContent.trim()), vals = texts.filter(x => x !== '').map(x => Number(x.replace(/[^0-9.-]/g, '')));
    const sum = vals.reduce((a, b) => a + b, 0), f = n => (Math.round(n * 100) / 100).toLocaleString(undefined, { maximumFractionDigits: 2 });
    const want = '[sessions] Sum: ' + f(sum) + ' | Avg: ' + f(sum / vals.length) + ' | Min: ' + f(Math.min(...vals)) + ' | Max: ' + f(Math.max(...vals));
    const td = trs.find(tr => tr.children[j].textContent.trim() !== '').children[j]; const r = td.getBoundingClientRect();
    td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5 }));
    const items = [...document.querySelectorAll('.menu button')].map(b => b.textContent);
    const v = td.textContent.trim();
    return { items, want, n: trs.length, cols: ths.filter(h => !h.hasAttribute('data-gt-hidden')).length, v, sum: f(sum), nums: vals.length,
      eq: texts.filter(x => x === v).length, holds: texts.filter(x => x.includes(v)).length };
  })()`);
  await shot('grid-cell-menu-light');
  const tail = g.items.slice(g.items.indexOf('Select row'));
  const wantTail = ['Select row', 'Select column', `Filter by value: ${g.v}`, 'Exclude value (contains)', 'Select all', `Rows: ${g.n} | Cols: ${g.cols}`, g.want];
  check('G grid menu', JSON.stringify(tail) === JSON.stringify(wantTail), tail.join(' / ') + (JSON.stringify(tail) === JSON.stringify(wantTail) ? '' : ' (want ' + wantTail.join(' / ') + ')'));
  // the grid's Export Excel (export.ts): one line, before these, after the copies
  const xl = g.items.filter(x => x.startsWith('Export Excel'));
  check('G grid menu Export Excel', xl.length === 1 && xl[0] === 'Export Excel' && g.items.indexOf('Export Excel') < g.items.indexOf('Select row'), JSON.stringify(xl));
  await clickItem('Select column'); await sleep(300);
  const sel = await ev(`(() => { const t = document.querySelector('main table.grid'); const td = t.querySelector('tbody td.gt-sel'); const r = td.getBoundingClientRect();
    const n = t.querySelectorAll('tbody td.gt-sel').length; const line = t.closest('.grid-box').querySelector('.gt-stats')?.textContent ?? '';
    td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5 }));
    const items = [...document.querySelectorAll('.menu button')].map(b => b.textContent); return { n, line, last: items[items.length - 1] }; })()`);
  await ev(`document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))`);
  // Select row: the row's cells of the columns shown
  await rightClick(`document.querySelector('main table.grid tbody tr:nth-child(2) td:nth-child(2)')`);
  await clickItem('Select row'); await sleep(300);
  const rowSel = await ev(`({ n: document.querySelectorAll('main table.grid tbody td.gt-sel').length, rows: new Set([...document.querySelectorAll('main table.grid tbody td.gt-sel')].map(td => td.parentElement)).size })`);
  check('G selection', sel.n === g.n && /selected/.test(sel.line) && sel.last.startsWith(`Selected Cells: ${g.n} (${g.nums} numeric) | Sum: ${g.sum} |`) && rowSel.n === g.cols && rowSel.rows === 1,
    `column: ${sel.n} cells; '${sel.line}'; '${sel.last}'; row: ${rowSel.n} cells in ${rowSel.rows} row for ${g.cols} columns`);
  const firstNum = `[...document.querySelectorAll('main table.grid tbody tr')].map(tr => tr.children[${col}]).find(td => td.textContent.trim() === ${JSON.stringify(g.v)})`;
  const shownRows = `(() => { const t = document.querySelector('main table.grid'); return [...t.querySelectorAll(':scope > tbody > tr')].map(tr => tr.children[${col}].textContent.trim()); })()`;
  await rightClick(firstNum); await clickItem('Filter by value'); await sleep(500);
  const fv = await ev(shownRows);
  await rightClick(firstNum); await clickItem('Clear filters'); await sleep(500);
  const back1 = (await ev(shownRows)).length;
  await rightClick(firstNum); await clickItem('Exclude value'); await sleep(500);
  const ex = await ev(shownRows);
  await rightClick(`document.querySelector('main table.grid tbody td')`); await clickItem('Clear filters'); await sleep(500);
  const back2 = (await ev(shownRows)).length;
  check('G filter', fv.length === g.eq && fv.every(x => x === g.v) && back1 === g.n && ex.length === g.n - g.holds && ex.every(x => !x.includes(g.v)) && back2 === g.n,
    `filter by '${g.v}': ${fv.length} rows (${g.eq} equal by hand); exclude: ${ex.length} (${g.n - g.holds} by hand); cleared: ${back1}, ${back2} of ${g.n}`);
  for (const f of fs.readdirSync(dl)) fs.rmSync(path.join(dl, f));
  await rightClick(`document.querySelector('main table.grid tbody td')`);
  await clickItem('Export Excel'); let x = '';
  for (let k = 0; k < 40 && !x; k++) { await sleep(250); x = fs.readdirSync(dl).find(f => f.endsWith('.xlsx')) ?? ''; }
  const buf = x ? fs.readFileSync(path.join(dl, x)) : Buffer.alloc(0);
  // a text column whose values look like numbers (the version, '17.10'): no Sum line
  await rightClick(`[...document.querySelectorAll('main table.grid tbody tr')].map(tr => tr.children[[...document.querySelectorAll('main table.grid thead tr:first-child th')].findIndex(h => h.textContent.startsWith('version'))]).find(td => /^\\d+\\.\\d+$/.test(td.textContent.trim()))`);
  const verLast = await ev(`(() => { const b = [...document.querySelectorAll('.menu button')].map(x => x.textContent); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return b[b.length - 1] ?? ''; })()`);
  check('G text column', /^Rows: /.test(verLast), `the last item on a version cell: '${verLast}'`);
  check('G export', buf.length > 0 && buf.subarray(0, 2).toString() === 'PK' && buf.includes(Buffer.from('xl/worksheets/sheet')), `${x || 'no .xlsx'} ${buf.length} bytes`);
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
