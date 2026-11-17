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
// the serve under test is proof-crview.sh's: a demo seed served by `pgvigil serve` WITH the login (a demo serve has
// none, and saving a report, its role rules and a refused run need one), its address and two users from the environment
// (passwords through the environment, never a command line): PGVIGIL_CRVIEW_URL, PGVIGIL_CRVIEW_ADMIN and
// PGVIGIL_CRVIEW_OPERATOR as user:password; PGVIGIL_ADMIN_DSN and PGVIGIL_CRVIEW_DB for the store's own reads
const dsn = process.env.PGVIGIL_ADMIN_DSN, db = process.env.PGVIGIL_CRVIEW_DB ?? '';
const base0 = process.env.PGVIGIL_CRVIEW_URL ?? '';
const [adminUser, adminPw] = (process.env.PGVIGIL_CRVIEW_ADMIN ?? ':').split(/:(.*)/s);
const [opUser, opPw] = (process.env.PGVIGIL_CRVIEW_OPERATOR ?? ':').split(/:(.*)/s);
if (!dsn || !db || !base0 || !adminUser || !opUser) { console.error('FAIL: PGVIGIL_ADMIN_DSN, PGVIGIL_CRVIEW_DB, PGVIGIL_CRVIEW_URL, PGVIGIL_CRVIEW_ADMIN and PGVIGIL_CRVIEW_OPERATOR are needed (scripts/proof-crview.sh sets them)'); process.exit(2); }
const shots = process.env.PGVIGIL_CRVIEW_SHOTS ?? '';
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'pgvigil-crview-'));
let chr = null, done = false;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const started = Date.now();
const psql = sql => execFileSync('psql', [`${dsn} dbname=${db}`, '-XAtq', '-c', sql], { encoding: 'utf8' }).trim();
// cleanup: Chromium stopped and the work folder removed on every way out; the serve and the database are proof-crview.sh's
function cleanup() {
  if (done) return; done = true;
  try { chr?.kill('SIGTERM'); } catch { /* gone */ }
  try { fs.rmSync(work, { recursive: true, force: true, maxRetries: 10, retryDelay: 300 }); } catch (e) { console.error(`cleanup: ${work} was not removed: ${e.message}`); }
}
process.on('exit', cleanup);
for (const [sig, code] of [['SIGINT', 130], ['SIGTERM', 143], ['SIGHUP', 129]]) process.on(sig, () => { cleanup(); process.exit(code); });
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
const base = base0.replace(/\/?$/, '/'), origin = base.replace(/\/$/, '');

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

// login: the browser signed in as one user (the session cookie in Chromium's own jar; the password goes over CDP to
// the page, never a command line); the page at the serve first, any earlier session ended
const login = async (u, p) => {
  await send('Page.navigate', { url: base }); await sleep(500);
  await ev(`fetch('/api/logout', { method: 'POST', headers: { 'X-Pgvigil': '1' } }).catch(() => null)`);
  return ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify(${JSON.stringify({ username: u, password: p })}) }).then(r => r.status)`);
};
const st = await login(adminUser, adminPw);
if (st !== 200) { console.error(`FAIL: the admin's sign-in answered ${st}`); process.exit(1); }

// ---- the cases (task 1 writes them group by group; a group not written yet is one FAIL saying so) ----
// ---- helpers of the cases
const pageJSON = (method, route, body) => ev(`fetch(${JSON.stringify('/api/' + route)}, { method: ${JSON.stringify(method)}, headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }${body === undefined ? '' : ', body: ' + JSON.stringify(JSON.stringify(body))} }).then(async r => ({ status: r.status, body: await r.text() }))`);
const parse = t => { try { return JSON.parse(t); } catch { return null; } };
const rowsOf = t => t ? t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]]))) : [];
const instances = async () => rowsOf(parse((await pageJSON('GET', 'instances')).body));
const tagsOf = r => (Array.isArray(r.tags) ? r.tags : String(r.tags ?? '').split(/[\s,{}]+/)).filter(Boolean);
// addReport: a report saved through the page's own route; its id read back by its name
const addReport = async def => {
  const r = await pageJSON('POST', 'customreports', { op: 'add', folder: '', kind: 'sql', params: [], columns: [], rules: [], ...def });
  const list = rowsOf(parse((await pageJSON('GET', 'customreports')).body)?.reports);
  return { status: r.status, said: r.body.slice(0, 200), id: list.find(x => x.name === def.name)?.report_id };
};
const listedOn = async (q, name) => { await go('#/customreports' + q); return ev(`[...document.querySelectorAll('main table.grid a')].some(a => a.textContent.trim() === ${JSON.stringify(name)})`); };

// ---- task 2: who sees a report
await guard('CR-visibility', async () => {
  const all = await instances(), pgs = all.filter(r => r.engine !== 'sqlserver'), ms = all.find(r => r.engine === 'sqlserver');
  const tagCount = new Map();
  for (const r of pgs) for (const t of tagsOf(r)) tagCount.set(t, (tagCount.get(t) ?? 0) + 1);
  const tag = [...tagCount.entries()].filter(([, n]) => n >= 2 && n < pgs.length).sort((a, b) => b[1] - a[1])[0]?.[0];
  const withTag = pgs.filter(r => tagsOf(r).includes(tag)), without = pgs.filter(r => !tagsOf(r).includes(tag));
  if (!tag || withTag.length < 2 || !without.length || !ms) { check('CR-visibility', false, `the demo has no tag fit for the case (tag ${tag}, ${withTag.length} with, ${without.length} without, SQL Server ${!!ms})`); return; }
  const inc = without[0], exc = withTag[0], kept = withTag[1], name = `cr-vis-${Date.now()}`;
  const saved = await addReport({ name, engine: 'store', body: 'SELECT 1 AS one', visibility: { engines: ['postgres'], tags: [tag], include: [inc.name], exclude: [exc.name] } });
  const at = { fleet: await listedOn('', name), tag: await listedOn(`?tag=${encodeURIComponent(tag)}`, name), kept: await listedOn(`?i=${kept.instance_id}`, name),
    included: await listedOn(`?i=${inc.instance_id}`, name), excluded: await listedOn(`?i=${exc.instance_id}`, name), sqlserver: await listedOn(`?i=${ms.instance_id}`, name) };
  // the editor: its rules, the no-match warning for rules no instance meets, Clear Rules
  await go(`#/customreports?edit=${saved.id}`);
  const ed = await ev(`(() => { const f = [...document.querySelectorAll('main fieldset')].find(x => /^Visibility/.test(x.querySelector('legend')?.textContent ?? ''));
    return { section: !!f, clear: !!f && [...f.querySelectorAll('button')].some(b => b.textContent.trim() === 'Clear Rules') }; })()`);
  const none = await addReport({ name: name + '-none', engine: 'store', body: 'SELECT 1 AS one', visibility: { engines: ['sqlserver'], tags: [tag], include: [], exclude: [] } });
  await go(`#/customreports?edit=${none.id}`);
  const warn = await ev(`/these rules match no instance/i.test(document.querySelector('main')?.textContent ?? '')`);
  const okAt = at.fleet && at.tag && at.kept && at.included && !at.excluded && !at.sqlserver;
  check('CR-visibility', saved.status === 200 && okAt && ed.section && ed.clear && warn,
    `saved ${saved.status}; listed ${JSON.stringify(at)} (want every place but excluded and sqlserver); the editor's Visibility section ${ed.section}, Clear Rules ${ed.clear}; the no-match warning ${warn}`);
});
await guard('CR-role', async () => {
  const name = `cr-role-${Date.now()}`;
  const saved = await addReport({ name, engine: 'store', body: 'SELECT 1 AS one', access: 'admin' });
  await login(opUser, opPw);
  await go(`#/customreports?report=${saved.id}`);
  const said = await ev(`(document.querySelector('main')?.textContent ?? '').includes('You do not have access to this report')`);
  const run = await pageJSON('POST', 'customreports/run', { report_id: saved.id, target: 'fleet', params: {} });
  await login(adminUser, adminPw);
  const adminRun = await pageJSON('POST', 'customreports/run', { report_id: saved.id, target: 'fleet', params: {} });
  check('CR-role', saved.status === 200 && said && run.status === 403 && /admin role/.test(run.body) && adminRun.status === 200,
    `saved ${saved.status}; the operator's page says no access ${said}; the operator's run ${run.status} ${run.body.slice(0, 120)}; the admin's run ${adminRun.status}`);
});

const notYet = [ 'task 4 the result sets', 'task 5 the columns', 'task 6 the links',
  'task 7 every grid', 'task 8 custom tools', 'task 9 the PM rows', 'task 10 the charts'];
for (const g of notYet) check(g, false, 'its cases are not written yet (task 1)');

console.log(`crview-check: ${failed} FAIL`);
process.exit(failed ? 1 : 0);
