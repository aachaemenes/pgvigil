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
// The harness (scripts/menu-check.mjs's, lines 265-365 at 65083820): the demo seeded and served, headless Chromium,
// the CDP calls, check / guard / go.
const { spawn, execFileSync } = await import('node:child_process');
const fs = await import('node:fs');
const os = await import('node:os');
const path = await import('node:path');

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const dsn = process.env.PGVIGIL_ADMIN_DSN;
if (!dsn) { console.error('FAIL: PGVIGIL_ADMIN_DSN is not set'); process.exit(2); }
const shots = process.env.PGVIGIL_CRVIEW_SHOTS ?? '';
const waitS = Number(process.env.PGVIGIL_DEMO_WAIT_S ?? 240);
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'pgvigil-crview-'));
const db = `pgvigil_crview_${process.pid}`;
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
  // the drop retried while the demo's sessions close: SIGTERM does not wait, and a demo still seeding has a pool that
  // opens a session again after FORCE ends it ('is being accessed by other users', gridmenu-b2 under a load of 66): after
  // a refusal the serve is killed outright, up to 10 tries 0.5 s apart (a sync pause: no timer runs in an exit handler)
  for (let k = 1; ; k++) {
    try { psql(`drop database if exists ${db} with (force)`, 'postgres'); break; }
    catch (e) {
      if (k >= 10) { console.error(`FAIL cleanup: the database ${db} was not dropped: ${e.message}`); process.exitCode = 1; break; }
      try { srv?.kill('SIGKILL'); } catch { /* gone */ }
      Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 500);
    }
  }
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
// PGVIGIL_CRVIEW_ONLY: the cases whose names start with one of its comma-separated prefixes ('CR', 'G', 'PM'); unset =
// every case
const only = (process.env.PGVIGIL_CRVIEW_ONLY ?? '').split(',').map(x => x.trim()).filter(Boolean);
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

// ---- the cases (task 1 writes them group by group; a group not written yet is one FAIL saying so) ----
const notYet = ['task 2 who sees a report', 'task 3 the run', 'task 4 the result sets', 'task 5 the columns', 'task 6 the links',
  'task 7 every grid', 'task 8 custom tools', 'task 9 the PM rows', 'task 10 the charts'];
for (const g of notYet) check(g, false, 'its cases are not written yet (task 1)');

console.log(`crview-check: ${failed} FAIL`);
process.exit(failed ? 1 : 0);
