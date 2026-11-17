// The click-through (the pre-publish walk): every page, tab, button, menu item and tree node of both engines
// clicked once on a `pgvigil demo -serve`, each click a row - landed where, opened what, off with which words, a
// write sent (held by the walk), or NOTHING - and a shot of each page. Two modes:
//   node scripts/clickthrough.mjs list <cdp port> <base url/> <pages.json> <shards>
//     the pages (a11y-check's method: #tabs' data-all) of the fleet root and of one instance per engine (the first
//     on-premises PostgreSQL instance and the first 'sqlserver' one by name), the Pooler tab of the first instance
//     that has it, the drill pages (db, table, index, job, compare: the first link of each kind per engine) and the
//     first alert; split into <shards> files <pages>-<k>.json balanced by an estimated cost, the tree and the bar
//     in the first
//   node scripts/clickthrough.mjs walk <cdp port> <base url/> <shard.json> <out.json> <shots dir> <work dir>
//     one driver: its own headless Chromium on <cdp port> (started again when it dies); every distinct control of
//     a page (main's, an open dialog's, an open menu's) found by its signature and clicked from a fresh page; what
//     a click adds is queued one level deeper (at most 3, at most `cap` a page); a control of the instance header
//     once per engine; a select's first 5 options; a file input and a file chooser given a fixture by its accept
// Every request that is not a GET to the server's /api/ is HELD by the walk (Fetch.failRequest): the row names it
// ('write held: POST /api/...'), so a click proves its write is sent and the demo's state never changes between
// clicks or drivers. Kinds a row can end with (scripts/clickthrough-grade.mjs grades them): link, navigates, dialog,
// menu, expands, redraws, status, download, chooser, write held, js-dialog, copies, current, focus, disabled (with
// its words), outside, over the cap; NOTHING, reads (a read and nothing to see), error, js-error, api <status>,
// link-error, link-stuck, dead link, reloads, off without words, not reached, click not settled, browser lost,
// driver error.
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import os from 'node:os';

const [mode, port, base] = process.argv.slice(2, 5);
if (!['list', 'walk'].includes(mode) || !port || !base) { console.error('usage: node scripts/clickthrough.mjs list <cdp port> <base url/> <pages.json> <shards> | walk <cdp port> <base url/> <shard.json> <out.json> <shots dir> <work dir>'); process.exit(2); }
const U = base.endsWith('/') ? base : base + '/';
const sleep = ms => new Promise(r => setTimeout(r, ms));
const [a5, a6, a7, a8] = process.argv.slice(5);
const work = mode === 'walk' ? a8 : fs.mkdtempSync(path.join(os.tmpdir(), 'clickthrough-list-'));
if (!work) { console.error('walk needs <work dir>'); process.exit(2); }
fs.mkdirSync(work, { recursive: true });
const label = mode === 'walk' ? path.basename(a5, '.json') : 'list';

// ---- the browser: its own Chromium, every command with a 30 s limit, started again when lost ----------------------
const udd = path.join(work, label + '-chrome');
const clog = fs.openSync(path.join(work, label + '-chrome.log'), 'a');
const dl = path.join(work, label + '-downloads');
fs.mkdirSync(dl, { recursive: true });
let chrome = null, ws = null, lost = true, id = 0, starts = 0;
const wait = new Map();
let net = [], exc = [], dlgs = [], held = [], chooser = [];
// chromium never outlives the driver: killed on any exit, and a TERM or INT ends the driver (its exit kills it)
process.on('exit', () => { try { chrome?.kill('SIGKILL'); } catch {} });
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => process.exit(sig === 'SIGINT' ? 130 : 143));
const startChrome = async () => {
  starts++;
  chrome = spawn('chromium', ['--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${udd}`, '--no-first-run', '--disable-gpu', '--lang=en-US', 'about:blank'], { stdio: ['ignore', clog, clog] });
  chrome.on('exit', (code, sig) => { console.error(`${label}: chromium exited (code ${code}, signal ${sig})`); chrome = null; });
  for (let i = 0; i < 80; i++) { try { const r = await fetch(`http://127.0.0.1:${port}/json/list`); if (r.ok) return; } catch {} await sleep(250); }
  throw new Error('chromium did not open its CDP port');
};
const send = (method, params = {}) => { if (ws && !lost) ws.send(JSON.stringify({ id: ++id, method, params })); };
const cmd = (method, params = {}, ms = 30000) => new Promise((res, rej) => {
  if (lost || !ws) return rej(new Error('browser lost'));
  const i = ++id; const t = setTimeout(() => { wait.delete(i); rej(new Error(`no reply in ${ms / 1000} s to ${method}`)); }, ms);
  wait.set(i, d => { clearTimeout(t); d.lost ? rej(new Error('browser lost during ' + method)) : res(d); });
  ws.send(JSON.stringify({ id: i, method, params }));
});
const ev = async expr => { const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }); if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300)); return d.result?.result?.value; };
const call = (fn, arg) => ev(`(${fn.toString()})(${JSON.stringify(arg ?? null)})`);
// the fixtures a file input or a chooser gets, by its accept attribute
const fixtures = {
  xdl: path.join(work, 'fixture.xdl'), sqlplan: path.join(work, 'fixture.sqlplan'), csv: path.join(work, 'fixture.csv'), sql: path.join(work, 'fixture.sql'),
};
fs.writeFileSync(fixtures.xdl, '<deadlock><victim-list><victimProcess id="p1"/></victim-list><process-list><process id="p1" spid="51" lockMode="X" waitresource="KEY: 5:1 (a)" isolationlevel="read committed (2)" lasttranstarted="2026-01-01T00:00:00"><inputbuf>UPDATE t SET a = 1</inputbuf></process><process id="p2" spid="52" lockMode="X" waitresource="KEY: 5:1 (b)" isolationlevel="read committed (2)" lasttranstarted="2026-01-01T00:00:00"><inputbuf>UPDATE t SET a = 2</inputbuf></process></process-list><resource-list><keylock dbid="5" objectname="db.dbo.t" indexname="pk" mode="X"><owner-list><owner id="p2" mode="X"/></owner-list><waiter-list><waiter id="p1" mode="X" requestType="wait"/></waiter-list></keylock></resource-list></deadlock>');
fs.writeFileSync(fixtures.sqlplan, '<?xml version="1.0" encoding="utf-16"?><ShowPlanXML xmlns="http://schemas.microsoft.com/sqlserver/2004/07/showplan" Version="1.564" Build="16.0.4325.4"><BatchSequence><Batch><Statements><StmtSimple StatementText="SELECT 1" StatementType="SELECT" StatementSubTreeCost="0.01"><QueryPlan><RelOp NodeId="0" PhysicalOp="Constant Scan" LogicalOp="Constant Scan" EstimateRows="1" EstimatedTotalSubtreeCost="0.01" Parallel="0"/></QueryPlan></StmtSimple></Statements></Batch></BatchSequence></ShowPlanXML>');
fs.writeFileSync(fixtures.csv, 'name,n\r\na,1\r\nb,2\r\n');
fs.writeFileSync(fixtures.sql, '-- the walk\'s script\r\n-- Server version (Query 1) (Version Info)\r\nSELECT @@VERSION AS v;\r\n------\r\n');
const fixtureFor = accept => /xdl/.test(accept) ? fixtures.xdl : /sqlplan/.test(accept) ? fixtures.sqlplan : /csv|json/.test(accept) ? fixtures.csv : fixtures.sql;
const connect = async () => {
  if (!chrome) await startChrome();
  const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  let pg = list.find(t => t.type === 'page');
  if (!pg) pg = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  ws = new WebSocket(pg.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
  lost = false;
  ws.addEventListener('close', () => { lost = true; for (const [, f] of wait) f({ lost: true }); wait.clear(); console.error(`${label}: the CDP socket closed`); });
  ws.addEventListener('message', m => {
    const d = JSON.parse(m.data);
    if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); return; }
    const p = d.params;
    if (d.method === 'Network.responseReceived' && p.response.url.startsWith(U + 'api/')) net.push({ url: p.response.url.slice(U.length - 1), status: p.response.status });
    if (d.method === 'Network.loadingFailed' && p.type !== 'Document' && p.errorText !== 'net::ERR_BLOCKED_BY_CLIENT') net.push({ url: '(failed) ' + p.errorText, status: 0 });
    if (d.method === 'Runtime.exceptionThrown') exc.push((p.exceptionDetails.exception?.description || p.exceptionDetails.text || '').split('\n')[0].slice(0, 200));
    if (d.method === 'Runtime.consoleAPICalled' && p.type === 'error') exc.push('console.error: ' + p.args.map(a => a.value ?? a.description ?? '').join(' ').slice(0, 200));
    if (d.method === 'Inspector.targetCrashed') exc.push('the page crashed (Inspector.targetCrashed)');
    if (d.method === 'Page.javascriptDialogOpening') { dlgs.push(p.type + ': ' + p.message.slice(0, 200)); send('Page.handleJavaScriptDialog', { accept: false }); }
    // a write is held: anything to the server's /api/ that is not a GET (the demo's door would write its repository)
    if (d.method === 'Fetch.requestPaused') {
      const r = p.request;
      if (r.method !== 'GET' && r.url.startsWith(U + 'api/')) { held.push(`${r.method} ${r.url.slice(U.length - 1).split('?')[0]}`); send('Fetch.failRequest', { requestId: p.requestId, errorReason: 'BlockedByClient' }); }
      else send('Fetch.continueRequest', { requestId: p.requestId });
    }
    if (d.method === 'Page.fileChooserOpened') {
      chooser.push(p.mode);
      cmd('DOM.describeNode', { backendNodeId: p.backendNodeId }).then(n => {
        const at = n.result?.node?.attributes ?? []; const acc = at[at.indexOf('accept') + 1] ?? '';
        chooser.push('accept ' + (at.includes('accept') ? acc : '(any)'));
        return cmd('DOM.setFileInputFiles', { backendNodeId: p.backendNodeId, files: [fixtureFor(at.includes('accept') ? acc : '')] });
      }).catch(e => chooser.push('fixture not given: ' + e.message));
    }
  });
  await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable'); await cmd('DOM.enable'); await cmd('Inspector.enable').catch(() => {});
  // every document starts with the auto refresh off (Off (paused)), before the page's own script reads it: a live
  // page's 30 s redraw never falls between a click's before and after (the bar's refresh select is still clicked)
  // and with the same theme and status colours: the bar's Theme and Colours buttons carry the stored choice in their
  // words ('Theme: light'), which a theme click changes for the whole browser - left as it was, a row listed as
  // 'Theme: auto' found 'Theme: light' on its fresh page when an earlier row had cycled it (the ninth run's 'gone')
  await cmd('Page.addScriptToEvaluateOnNewDocument', { source: "try { if (location.origin === " + JSON.stringify(new URL(U).origin) + ") { localStorage.setItem('pgvigil.refresh', '0'); localStorage.setItem('pgvigil.theme', 'light'); localStorage.setItem('pgvigil.status', 'solid'); } } catch (e) {}" });
  await cmd('Fetch.enable', { patterns: [{ urlPattern: U + 'api/*', requestStage: 'Request' }] });
  await cmd('Page.setInterceptFileChooserDialog', { enabled: true });
  // each download under its own GUID: a second save of the same file name (one deadlock's .xdl from two links) still
  // adds a file, so the folder's count grows on every download (with 'allow' a second save of one name did not)
  await cmd('Browser.setDownloadBehavior', { behavior: 'allowAndName', downloadPath: dl }).catch(() => {});
  await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
  await cmd('Emulation.setLocaleOverride', { locale: 'en-US' }).catch(() => null);
  await cmd('Page.navigate', { url: U }); await sleep(1200);
  await ev(`(() => { try { localStorage.setItem('pgvigil.theme', 'light'); } catch (e) {} })()`);
};
const ensure = async () => { if (!lost && ws) return; try { ws?.close(); } catch {} if (chrome) { try { chrome.kill('SIGKILL'); } catch {} chrome = null; await sleep(500); } await connect(); };
await connect();

// ---- a page: loaded, settled (no busy line in main or an open dialog; an instance page's header drawn) -------------
// a busy line: 'Loading' anything ('Loading the chart', chartkit.ts:40), or Reading / Running / Working / Checking /
// Searching / Looking with its ellipsis ('Reading...', 'Reading the heatmap ...', 'Working...', 'Looking again...');
// never a sentence or a link that only begins so - the Queries page's 'Running queries' (the link above its Active
// queries section, mssql_queries.ts:36 / :283) would read as busy for good
const BUSY_RE = String.raw`^Loading|^(Reading|Running|Working|Checking|Searching|Looking)\b.*(\.\.\.|\u2026)$`;
const busyText = t => new RegExp(BUSY_RE).test(t.trim());
// the fixture: the app's busy texts and the ones that only begin so (checked at the walker's start: exit 2 on a wrong one)
for (const [t, want] of [['Reading...', true], ['Reading ...', true], ['Reading the heatmap ...', true], ['Loading...', true], ['Loading the chart', true],
  ['Running...', true], ["Reading the instance's collections...", true], ['Running queries', false], ['Running now', false], ['Running at once', false],
  ['Running a report is off on this server.', false], ['Running queries of this instance at this snapshot', false],
  ['Working...', true], ['Working\u2026', true], ['Checking...', true], ['Searching...', true], ['Looking again...', true], ['Reading the session...', true],
  ['Working hours', false], ['Checking the login is off here.', false], ['Looking at a plan', false]]) {
  if (busyText(t) !== want) { console.error(`the busy rule's fixture: '${t}' read ${!want ? 'busy' : 'not busy'}`); process.exit(2); }
}
// where a busy line sits: main's paragraphs and status lines, a meta span ('Looking again...'), an open dialog's
const BUSYSEL = 'main p, main [role=status], main span.meta, dialog[open] p, dialog[open] [role=status]';
const BUSY = `[...document.querySelectorAll(${JSON.stringify(BUSYSEL)})].some(p => new RegExp(${JSON.stringify(BUSY_RE)}).test(p.textContent.trim()))`;
// the lines a page that did not settle still shows (which section was still reading at the cap)
const BUSYLINES = `[...document.querySelectorAll(${JSON.stringify(BUSYSEL)})].map(p => { const sec = p.closest('section, .card, dialog'); const h = sec?.querySelector('h2, h3, h4')?.textContent?.trim() ?? ''; return [h, p.textContent.trim()]; })
  .filter(([, t]) => new RegExp(${JSON.stringify(BUSY_RE)}).test(t)).map(([h, t]) => (h ? h + ': ' : '') + t.slice(0, 80)).slice(0, 8)`;
// settled: two quiet polls in a row (a page's status line goes in empty and gets its 'Loading...' a frame later)
const settled = async (cap = 20000) => {
  let quiet = 0;
  for (const t = Date.now(); Date.now() - t < cap; await sleep(200)) {
    if (lost) return false;
    const ok = await ev(`(() => { const m = document.querySelector('main'); return !!m && m.children.length > 0 && !(${BUSY}); })()`).catch(() => false);
    if (!ok) { quiet = 0; continue; }
    if (++quiet >= 2) {
      for (let i = 0; i < 50 && await ev(`/[?&]i=/.test(location.hash) && !document.querySelector('main .inst-header')`).catch(() => false); i++) await sleep(100);
      await sleep(400); return true;
    }
  }
  return false;
};
const ORIGIN = new URL(U).origin;
// every page starts with no stored state: a click's filter, frozen or hidden column, folder or range never reaches the
// next row (the page keeps them in its storage)
const freshOnce = async hash => { await ensure(); await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Storage.clearDataForOrigin', { origin: ORIGIN, storageTypes: 'local_storage,session_storage' }).catch(() => {}); await sleep(100); net = []; exc = []; dlgs = []; held = []; chooser = []; await cmd('Page.navigate', { url: U + hash }); await sleep(250);
  // a click of the bar may have switched the theme: every page starts light
  await ev(`(() => { try { localStorage.setItem('pgvigil.theme', 'light'); } catch (e) {} document.documentElement.setAttribute('data-theme', 'light'); })()`).catch(() => {});
  return settled(); };
// fresh: freshOnce, and once more on a browser started again when it was lost on the way (its CDP socket closed),
// in a command or while the page settled (settled() then answers false without a throw): a lost browser costs one
// page load, never the list or the walk
const fresh = async hash => {
  let why;
  try { const ok = await freshOnce(hash); if (ok || !lost) return ok; why = 'lost while the page settled'; } catch (e) { if (!lost) throw e; why = e.message; }
  console.error(`${label}: the browser was lost loading ${hash} (${why}): started again`);
  await ensure(); return await freshOnce(hash);
};
const tabsOf = async hash => { await fresh(hash); return await ev(`(() => { const t = document.querySelector('#tabs'); return t?.dataset.all ? JSON.parse(t.dataset.all) : [...(t?.querySelectorAll('a') ?? [])].map(a => a.getAttribute('href')); })()`) ?? []; };

// ---- list -----------------------------------------------------------------------------------------------------------
if (mode === 'list') {
  const [outFile, shardsArg] = [a5, a6];
  const shards = Math.max(1, Number(shardsArg) || 1);
  const t = await (await fetch(U + 'api/instances')).json();
  const fleet = t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])));
  const byName = (a, b) => String(a.name).localeCompare(String(b.name));
  const first = pred => fleet.filter(pred).sort(byName)[0];
  const pg = first(r => r.engine !== 'sqlserver' && r.platform === 'onprem') ?? first(r => r.engine !== 'sqlserver');
  const ms = first(r => r.engine === 'sqlserver' && r.platform === 'sqlserver') ?? first(r => r.engine === 'sqlserver');
  const pages = []; const notes = [];
  const add = (scope, engine, hash, inst) => { if (hash && !pages.some(p => p.hash === hash)) pages.push({ scope, engine, hash, tab: (/^#\/([^?]+)/.exec(hash) ?? [])[1] ?? hash, ...(inst ? { id: String(inst.instance_id), inst: inst.name } : {}) }); };
  for (const h of await tabsOf('#/summary')) add('root', null, String(h).replace(/^#?\/?/, '#/'));
  for (const [r, scope, eng] of [[pg, 'pg', 'postgres'], [ms, 'ms', 'sqlserver']]) {
    if (!r) { notes.push(`no ${eng} instance on the demo: its pages were not listed`); continue; }
    for (const h of await tabsOf(`#/summary?i=${r.instance_id}`)) add(scope, eng, String(h).replace(/^#?\/?/, '#/').replace(/i=\d+/, `i=${r.instance_id}`), r);
  }
  let pooler = null;
  for (const r of fleet.filter(x => x.engine !== 'sqlserver').sort(byName)) {
    if (r === pg) continue;
    const ts = await tabsOf(`#/summary?i=${r.instance_id}`);
    const h = ts.find(x => /#?\/?pooler\?/.test(x));
    if (h) { pooler = r; add('pg', 'postgres', String(h).replace(/^#?\/?/, '#/').replace(/i=\d+/, `i=${r.instance_id}`), r); break; }
  }
  if (!pooler && !pages.some(p => p.tab === 'pooler')) notes.push('no instance has the Pooler tab: the Pooler page was not listed');
  // the drill pages and the first alert: the first link of each kind a listed page holds, per engine
  const drillSeen = new Set();
  for (const p of [...pages]) {
    await fresh(p.hash);
    p.controls = await ev(`document.querySelectorAll('main a[href], main button, main select, main summary').length`).catch(() => 0);
    if (!p.engine && p.tab !== 'alerts') continue;
    const found = await ev(`(() => { const o = {}; for (const a of document.querySelectorAll('main a[href^="#/"]')) { const h = a.getAttribute('href'); const m = /^#\\/(db|table|index|job|compare|alert)\\?/.exec(h); if (m && !o[m[1]]) o[m[1]] = h; } return o; })()`).catch(() => ({}));
    for (const [kind, h] of Object.entries(found ?? {})) {
      const key = (p.engine ?? 'root') + ':' + kind;
      if (drillSeen.has(key)) continue; drillSeen.add(key);
      add(kind === 'alert' ? 'root' : p.scope, kind === 'alert' ? null : p.engine, h, kind === 'alert' ? null : (p.engine === 'sqlserver' ? ms : pg));
    }
  }
  if (!pages.some(p => p.tab === 'alert')) notes.push('no alert link found on the listed pages: the alert page was not listed');
  if (starts > 1) notes.push(`chromium started ${starts} time(s) for the list (a lost browser started again)`);
  // the cost a page is expected to take (Community tools and Custom reports hold most clicks) and the cap
  for (const p of pages) { p.cap = /^(community|customreports)$/.test(p.tab) ? 160 : 80; p.cost = 10 + Math.min(p.cap, p.controls ?? p.cap); }
  const bins = Array.from({ length: shards }, (_, k) => ({ k, cost: k === 0 ? 180 : 0, pages: [] }));
  for (const p of [...pages].sort((x, y) => y.cost - x.cost)) { const b = bins.reduce((m, x) => x.cost < m.cost ? x : m); b.pages.push(p); b.cost += p.cost; }
  const stem = outFile.replace(/\.json$/, '');
  for (const b of bins) fs.writeFileSync(`${stem}-${b.k}.json`, JSON.stringify({ shard: b.k, chrome: b.k === 0, pg: pg ? { id: String(pg.instance_id), name: pg.name } : null, ms: ms ? { id: String(ms.instance_id), name: ms.name } : null, pages: b.pages }));
  fs.writeFileSync(outFile, JSON.stringify({ pg: pg?.name, ms: ms?.name, pooler: pooler?.name ?? null, pages, notes, chromeStarts: starts }, null, 1));
  const n = s => pages.filter(p => p.scope === s).length;
  console.log(`listed: ${pages.length} pages (root ${n('root')}, PostgreSQL ${pg?.name} ${n('pg')}${pooler ? ' with the Pooler of ' + pooler.name : ''}, SQL Server ${ms?.name} ${n('ms')}) in ${shards} shard(s)`);
  for (const x of notes) console.log('note: ' + x);
  try { chrome?.kill('SIGTERM'); } catch {}
  process.exit(pages.length ? 0 : 1);
}

// ---- walk -----------------------------------------------------------------------------------------------------------
const shard = JSON.parse(fs.readFileSync(a5, 'utf8'));
const [outFile, shots] = [a6, a7];
fs.mkdirSync(shots, { recursive: true });
const state = `({ hash: location.hash, h2: document.querySelector('main h2')?.textContent ?? '',
  canvas: [...document.querySelectorAll('main canvas, dialog[open] canvas')].map(c => { try { return c.width + 'x' + c.height + ':' + c.toDataURL().length; } catch (e) { return 'x'; } }).join(','),
  html: (() => { const s = (document.querySelector('main')?.innerHTML ?? '') + '|' + [...document.querySelectorAll('dialog[open], #bar')].map(d => d.innerHTML).join('|') + '|' + [...document.querySelectorAll('main input, main select, dialog[open] input, dialog[open] select')].map(i => i.type === 'checkbox' || i.type === 'radio' ? i.checked : i.value).join('|'); let h = 2166136261; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return h >>> 0; })(),
  copied: window.__walkCopied ?? 0, focus: document.activeElement ? document.activeElement.tagName + (document.activeElement.getAttribute('aria-label') || document.activeElement.textContent || '').slice(0, 40) : '',
  errors: [...document.querySelectorAll('main .error, dialog[open] .error, #bar .error')].map(e => e.textContent.trim().slice(0, 300)).filter(Boolean),
  status: [...document.querySelectorAll('main [role=status], dialog[open] [role=status]')].filter(s => !s.matches('.filter-count')).map(s => s.textContent.trim()).filter(Boolean).join(' | ').slice(0, 300),
  dialog: document.querySelector('dialog[open]') ? (document.querySelector('dialog[open]').getAttribute('aria-label') || document.querySelector('dialog[open]').querySelector('h2, h3')?.textContent || '(untitled dialog)') : null,
  menu: [...document.querySelectorAll('[role=menu], .menu')].filter(m => m.getClientRects().length > 0).map(m => [...m.querySelectorAll('button, [role=menuitem]')].map(b => b.textContent.trim().slice(0, 50))).flat().slice(0, 30),
  mark: window.__walk === 1, open: document.querySelectorAll('details[open], [aria-expanded=true]').length, tree: document.querySelector('#tree')?.innerHTML.length ?? 0 })`;
// a control's words for its signature: its aria-label, else its text without a meta span beside its name (a length or
// an age that the clock changes: the range picker's 'Today' reads '20h 59m' at 20:59 and '21h' at 21:00, so a click
// after the hour found no control of the listed words), else its title, name or id; numbers folded to '#'. parts: the
// control's child nodes as { meta, text }; run in the page (inside SIG) and by the fixture below
function sigWords(label, parts, title, name, id) {
  const all = parts.map(p => p.text).join(''), own = parts.filter(p => !p.meta).map(p => p.text).join('');
  return (label || (own.trim() ? own : all) || title || name || id || '').replace(/\s+/g, ' ').trim().replace(/[0-9][0-9:.,\- ]*/g, '#').slice(0, 60);
}
// the fixture: the picker's lengths either side of a turn read as one control, quick ranges of two units stay apart (those
// of one unit share a signature, numbers folded, as before), a control with no meta span reads as before (checked at the
// walker's start: exit 2 on a wrong one)
{
  const m = (name, meta) => sigWords(null, [{ meta: false, text: name }, { meta: true, text: meta }], '', null, '');
  const p = text => sigWords(null, [{ meta: false, text }], '', null, '');
  for (const [got, want, what] of [[m('Today', '20h 59m'), m('Today', '21h'), 'Today across the hour'], [m('Week to date', '5d 23h'), m('Week to date', '6d'), 'Week to date across the day'],
    [m('Today', '<1m'), 'Today', 'Today at midnight'], [m('Last 5 minutes', '5m'), 'Last #minutes', 'a quick range'], [m('Last 4 hours', '4h'), 'Last #hours', 'another quick range'],
    [p('Refresh'), 'Refresh', 'a plain button'], [p('Run 3 checks'), 'Run #checks', 'a number in the words'],
    [sigWords('Range: Last hour', [{ meta: false, text: 'Last hour' }], '', null, ''), 'Range: Last hour', 'the aria-label first'],
    [sigWords(null, [{ meta: true, text: '3 rows' }], '', null, ''), '#rows', 'a meta span alone keeps its words'],
    [sigWords(null, [], 'Close', null, ''), 'Close', 'no words: the title']]) {
    if (got !== want) { console.error(`the signature's fixture (${what}): '${got}', want '${want}'`); process.exit(2); }
  }
}
// a control's signature: where it is, its tag, its words (sigWords); a grid cell's link by its column
const SIG = `(el => { const t = el.tagName, cell = el.closest('td'), W = ${sigWords};
  let w = W(el.getAttribute('aria-label'), [...el.childNodes].map(n => ({ meta: n.nodeType === 1 && n.matches('span.meta'), text: n.nodeType === 8 ? '' : n.textContent || '' })), el.title, el.getAttribute('name'), el.id);
  if (cell && (t === 'A' || t === 'BUTTON')) w = 'cell ' + cell.cellIndex;
  const where = el.closest('dialog[open]') ? 'dlg ' : el.closest('[role=menu], .menu') ? 'menu ' : el.closest('.inst-header') ? 'hdr ' : el.closest('#bar') ? 'bar ' : '';
  if (t === 'A') { const h = el.getAttribute('href') || ''; const [p, qs] = h.split('?'); return where + 'A ' + p + '?' + [...new URLSearchParams(qs || '').keys()].sort().join('&') + ' ' + w; }
  if (t === 'INPUT') return where + 'I' + el.type + ' ' + w; if (t === 'SELECT') return where + 'S ' + w; if (t === 'SUMMARY') return where + 'D ' + w; return where + 'B ' + w; })`;
const CTRL = 'main a[href], main button, main select, main summary, main input[type=file], main input[type=checkbox], main input[type=radio], dialog[open] button, dialog[open] a[href], dialog[open] select, dialog[open] input[type=checkbox], [role=menu] button, [role=menu] [role=menuitem], .menu button';
const BAR = ', #bar button, #bar a[href], #bar select';
const controls = withBar => ev(`(() => { const S = ${SIG}; const seen = new Map();
  for (const el of document.querySelectorAll(${JSON.stringify(CTRL)} + (${withBar} ? ${JSON.stringify(BAR)} : ''))) { if (el.getClientRects().length === 0 && el.tagName !== 'INPUT') continue; const s = S(el); if (!seen.has(s)) seen.set(s, { sig: s, n: 0, tag: el.tagName,
    what: (el.getAttribute('aria-label') || el.textContent || el.title || '').replace(/\\s+/g, ' ').trim().slice(0, 80), disabled: !!el.disabled || el.getAttribute('aria-disabled') === 'true',
    reason: [el.title, ...(el.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean).map(i => document.getElementById(i)?.textContent?.trim() ?? '')].filter(Boolean).join(' | ').slice(0, 240),
    href: el.getAttribute('href'), type: el.type || '', opts: el.tagName === 'SELECT' ? [...el.options].map(o => o.value) : null, cur: el.tagName === 'SELECT' ? el.value : null,
    on: ['aria-selected', 'aria-current'].some(a => (el.getAttribute(a) || 'false') !== 'false') || (el.type === 'radio' && el.checked) }); seen.get(s).n++; }
  return [...seen.values()]; })()`);
const offNotes = () => ev(`[...document.querySelectorAll('main p.meta, main p.note, main .note, main .off-reason, main [id^=off-], dialog[open] p')].map(p => p.textContent.trim()).filter(t => /off here|is off|read only|read-only|needs|refused|not configured|no read login|no monitoring login|-no-login|disabled|demo/i.test(t)).map(t => t.slice(0, 240))`);
// one step, given up to 5 s to find its control: a replay on a fresh page reaches a grid cell or a cell's button only
// once the page has redrawn it (on the shared box a redraw can take seconds), so 'gone' is said only after the wait
const actWait = async (sig, step, ms = 5000) => {
  for (const t = Date.now(); ; await sleep(250)) {
    const r = await act(sig, step);
    if ((r !== 'gone' && r !== 'no grid cell') || Date.now() - t >= ms) return r;
  }
};
// a step's control is on the page (nothing clicked), waited for up to ms
const there = async (sig, ms = 5000) => {
  for (const t = Date.now(); ; await sleep(250)) {
    const ok = sig === 'CTX' ? await ev(`!!document.querySelector('main table.grid tbody td')`).catch(() => false)
      : await ev(`(() => { const S = ${SIG}; return [...document.querySelectorAll(${JSON.stringify(CTRL + BAR)})].some(el => S(el) === ${JSON.stringify(sig)}); })()`).catch(() => false);
    if (ok || Date.now() - t >= ms) return ok;
  }
};
// a control's words at this moment (title, aria-describedby): a control found off at its click is judged as one found
// off in the list
const reasonOf = sig => ev(`(() => { const S = ${SIG}; const el = [...document.querySelectorAll(${JSON.stringify(CTRL + BAR)})].find(el => S(el) === ${JSON.stringify(sig)});
  return el ? [el.title, ...(el.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean).map(i => document.getElementById(i)?.textContent?.trim() ?? '')].filter(Boolean).join(' | ').slice(0, 240) : ''; })()`).catch(() => '');
// one step: the control by its signature, then a click (or a select's option, or a file input's fixture)
const act = async (sig, step) => {
  if (sig === 'CTX') return ev(`(() => { const td = document.querySelector('main table.grid tbody td'); if (!td) return 'no grid cell'; const r = td.getBoundingClientRect(); td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.x + 5, clientY: r.y + 5, button: 2 })); return 'ok'; })()`);
  const nth = Math.max(1, step?.nth ?? 1);
  const found = await cmd('Runtime.evaluate', { expression: `(() => { const S = ${SIG}; return [...document.querySelectorAll(${JSON.stringify(CTRL + BAR)})].filter(el => S(el) === ${JSON.stringify(sig)})[${nth - 1}] ?? null; })()` });
  const oid = found.result?.result?.objectId; if (!oid) return 'gone';
  if (/^(dlg |menu |hdr |bar )?Ifile /.test(sig)) {
    const acc = (await cmd('Runtime.callFunctionOn', { objectId: oid, functionDeclaration: 'function () { return this.accept || ""; }', returnByValue: true })).result?.result?.value ?? '';
    await cmd('DOM.setFileInputFiles', { objectId: oid, files: [fixtureFor(acc)] }); return 'ok';
  }
  if (step && step.opt !== undefined) { await cmd('Runtime.callFunctionOn', { objectId: oid, functionDeclaration: 'function (v) { this.value = v; this.dispatchEvent(new Event("change", { bubbles: true })); }', arguments: [{ value: step.opt }] }); return 'ok'; }
  // the click as a user's gesture (a file chooser opens only on one: menu-check's userGesture), with no scroll first:
  // the page closes an open grid menu on any scroll (ui.ts dropMenu)
  const r = await cmd('Runtime.callFunctionOn', { objectId: oid, functionDeclaration: 'function () { if (this.disabled) return "disabled"; this.click(); return "ok"; }', returnByValue: true, userGesture: true });
  return r.result?.result?.value ?? 'ok';
};
const shot = async name => { const d = await cmd('Page.captureScreenshot', { format: 'png' }).catch(() => null); if (d?.result?.data) fs.writeFileSync(path.join(shots, name + '.png'), Buffer.from(d.result.data, 'base64')); };
const shotName = p => `${p.scope}-${p.hash.slice(2).replace(/[^\w=-]+/g, '_').slice(0, 80)}`;
const out = { shard: shard.shard, pages: [], clicks: [], tree: [] };
const t0 = Date.now();
const save = () => fs.writeFileSync(outFile, JSON.stringify(out));
const hdrSeen = new Set();
// the downloads folder's whole files: never one still being written (.crdownload) or empty
const dlCount = () => fs.readdirSync(dl).filter(f => { if (f.endsWith('.crdownload')) return false; try { return fs.statSync(path.join(dl, f)).size > 0; } catch { return false; } }).length;
const verdict = (row, before, after, dl0) => {
  const newErr = (after.errors || []).filter(e => !(before.errors || []).includes(e));
  const apiBad = row.api.filter(x => x.status >= 400 || x.status === 0);
  row.status = after.status !== before.status ? after.status : '';
  // a save that failed says so in the grid's tools line (a status, gridtools.ts report): an error, never a status row
  // that meets a must row (review-17 B2)
  if (/(^| \| )Export failed/.test(row.status)) newErr.push(row.status);
  row.errors = newErr; row.to = after.hash; row.h2 = after.h2; row.dialog = after.dialog; row.menu = after.menu;
  const grew = dlCount() > dl0;
  if (row.held.length) return 'write held';
  if (!after.mark) return 'reloads';
  if (row.chooser.length) return 'chooser';
  if (apiBad.length) return 'api ' + [...new Set(apiBad.map(x => x.status))].join(',');
  if (newErr.length) return 'error';
  if (row.exc.length) return 'js-error';
  if (after.dialog && after.dialog !== before.dialog) return 'dialog';
  if (after.menu?.length && JSON.stringify(after.menu) !== JSON.stringify(before.menu)) return 'menu';
  if (after.hash !== before.hash) return 'navigates';
  // an item of the grid menu (a path under a grid's right-click): it closes the menu and puts the focus back on its
  // cell before it acts (treemenu.ts closeAll), so the menu's closing, a submenu parent's aria-expanded and the focus
  // say nothing of the item; a file or a copy is judged first (its menu's closing is no proof of either), and an item
  // that changed nothing else is NOTHING (review-17 B1). Outside the grid menu the order is as before
  if (row.path?.[0] === 'CTX' && row.path.length > 1) {
    if (grew) return 'download';
    if ((after.copied ?? 0) > (before.copied ?? 0)) return 'copies';
    if (row.status) return 'status';
    if (after.html !== before.html || after.canvas !== before.canvas || after.tree !== before.tree || (before.dialog && !after.dialog)) return 'redraws';
    if (row.jsDialogs.length) return 'js-dialog';
    if (row.api.some(x => x.status >= 200 && x.status < 300)) return 'reads';
    return 'NOTHING';
  }
  if (row.status) return 'status';
  if (after.open !== before.open) return 'expands';
  if (after.html !== before.html || after.canvas !== before.canvas || after.tree !== before.tree || (before.dialog && !after.dialog) || (before.menu?.length && !after.menu?.length)) return 'redraws';
  if (grew) return 'download';
  if (row.jsDialogs.length) return 'js-dialog';
  if ((after.copied ?? 0) > (before.copied ?? 0)) return 'copies';
  if (row.api.some(x => x.status >= 200 && x.status < 300)) return 'reads';
  if (row.on) return 'current';
  if (after.focus !== before.focus) return 'focus';
  return 'NOTHING';
};
// the verdict's fixture (checked at the walker's start: exit 2 on a wrong one): a grid menu item that only closed its
// menu (the focus back on the cell, its parent no longer expanded) is NOTHING; one that changed the grid redraws; a
// failed save is an error; outside the grid menu a closed menu is still a redraw
{
  const R = path => ({ path, held: [], chooser: [], api: [], exc: [], jsDialogs: [] });
  const B = { hash: '#/x', h2: '', canvas: '', html: 'grid', copied: 0, focus: 'BUTTONHide column a', errors: [], status: '', dialog: null, menu: ['Copy▸', 'Hide column a'], mark: true, open: 1, tree: 9 };
  const A = { ...B, menu: [], open: 0, focus: 'TDx' }, d0 = dlCount();
  for (const [got, want, what] of [[verdict(R(['CTX', 'menu B Hide column a']), B, A, d0), 'NOTHING', 'a grid menu item that did nothing'],
    [verdict(R(['CTX', 'menu B Copy▸', 'menu B Cell']), { ...B, open: 2 }, A, d0), 'NOTHING', 'a third-level item that did nothing'],
    [verdict(R(['CTX', 'menu B Hide column a']), B, { ...A, html: 'grid less a column' }, d0), 'redraws', 'a grid menu item that changed the grid'],
    [verdict(R(['CTX', 'menu B Export Excel']), B, { ...A, status: 'Export failed: no sheet' }, d0), 'error', 'a failed save'],
    [verdict(R(['CTX', 'menu B Copy▸', 'menu B Grid']), B, { ...A, copied: 1, status: 'Copied 3 rows' }, d0), 'copies', 'a copy that says so'],
    [verdict(R(['B Tools']), B, { ...B, menu: [] }, d0), 'redraws', 'a menu closed outside the grid menu']]) {
    if (got !== want) { console.error(`the verdict's fixture (${what}): '${got}', want '${want}'`); process.exit(2); }
  }
}
// the mark (a full reload loses it) and a copy counter: the clipboard's writes are counted in the page, never sent
const MARK = `(() => { window.__walk = 1; window.__walkCopied = 0; try { const c = navigator.clipboard; if (c && !c.__walk) { c.writeText = () => { window.__walkCopied++; return Promise.resolve(); }; c.write = () => { window.__walkCopied++; return Promise.resolve(); }; c.__walk = 1; } } catch (e) {}
  if (!document.__walk) { const ex = document.execCommand.bind(document); document.execCommand = (k, ...a) => { if (k === 'copy') window.__walkCopied++; return ex(k, ...a); }; document.__walk = 1; } })()`;
// the grid's own controls (the same component on every page): each at most GRID_MAX times a driver
const GRID_MAX = 3;
const gridKey = sig => { const m = /^(menu B (?:Freeze Column|Unfreeze Column|Filter by value|Exclude value|Hide the column|Sort|Copy|Rows:|Selected Cells|Clear filters|Group [Bb]y)|B Filter |S Group by a column|S Select the cells of a column|CTX)/.exec(sig); return m ? m[1] : null; };
const gridSeen = new Map();
// the grid's menu (CTX: a right-click on a grid's first cell opens GM's .tm-menu, web/src/gridtools.ts gridMenu): each
// item counted by its own path (GRID_MAX a driver), its varying words folded (a column's name, a cell's value, a tick,
// the submenu's arrow); what an item opens that is not the menu (the Columns... panel's controls) by its first word
// ('Icheckbox', 'B'; a gridKey control by its own key), as before.
// One 'CTX menu' count for every item reached three items a driver and left the rest unclicked (the GM walk rows)
// (the chooser's All, None and Toggle selected each keyed by its own words, as 'Show every column' was before task PGRID
// B05: a bare 'B' would share one count with every other button of the panel)
const gmWords = sig => !/^menu /.test(sig) ? (gridKey(sig) ?? (/^B (All|None|Toggle selected)$/.test(sig) ? sig : sig.replace(/\s.*$/, '')))
  : sig.replace(/▸$/, '').replace(/^menu B ✓ /, 'menu B ').replace(/^(menu B (?:Hide column|Freeze Column|Group by|Filter by value|Exclude value)\b).*/, '$1').replace(/^menu B \[.*\] .*/, 'menu B [column] statistics');
for (const [got, want] of [[gmWords('menu B Copy▸'), 'menu B Copy'], [gmWords('menu B ✓ Show with Row Numbers'), 'menu B Show with Row Numbers'], [gmWords('menu B ✓ Freeze Column'), 'menu B Freeze Column'], [gmWords('menu B Hide column Free space'), 'menu B Hide column'],
  [gmWords('menu B Filter by value: OK'), 'menu B Filter by value'], [gmWords('menu B [Free] Count: #| Sum: #'), 'menu B [column] statistics'], [gmWords('menu B Rows: #| Cols: #'), 'menu B Rows: #| Cols: #'],
  [gmWords('Icheckbox Free space'), 'Icheckbox'], [gmWords('B All'), 'B All'], [gmWords('B Toggle selected'), 'B Toggle selected'], [gmWords('B Reset this grid'), 'B']]) {
  if (got !== want) { console.error(`the grid menu's count fixture: '${got}', want '${want}'`); process.exit(2); }
}
const pagesOf = shard.pages;
const chromePage = shard.chrome ? [{ scope: 'root', engine: null, hash: '#/summary', tab: 'bar', bar: true, cap: 60 }] : [];
// the bar last: what its clicks keep (a theme, a range) never reaches another page's rows
for (const pg of [...pagesOf, ...chromePage]) {
  let queue;
  try {
    const okLoad = await fresh(pg.hash);
    const land = await ev(state).catch(e => ({ errors: [String(e)] }));
    out.pages.push({ scope: pg.scope, tab: pg.tab, hash: pg.hash, settled: okLoad, h2: land.h2, errors: land.errors ?? [], api: net.filter(x => x.status >= 400 || x.status === 0), exc: [...exc], off: await offNotes().catch(() => []), shot: pg.bar ? null : shotName(pg),
      busy: okLoad ? [] : await ev(BUSYLINES).catch(() => []) });
    if (!pg.bar) await shot(shotName(pg));
    const all = await controls(!!pg.bar);
    queue = all.filter(c => pg.bar ? /^bar /.test(c.sig) : !/^bar /.test(c.sig)).map(c => ({ path: [{ sig: c.sig }], c }));
  } catch (e) { out.pages.push({ scope: pg.scope, tab: pg.tab, hash: pg.hash, settled: false, h2: '', errors: ['(driver) ' + e.message], api: [], exc: [], off: [], lost }); console.error(`${label} ${pg.hash}: load failed: ${e.message}`); await ensure().catch(() => {}); save(); continue; }
  if (await ev(`!!document.querySelector('main table.grid tbody td')`).catch(() => false)) queue.push({ path: [{ sig: 'CTX' }], c: { sig: 'CTX', tag: 'TD', what: 'right-click on the first grid cell', n: 1 } });
  const done = new Set(); let budget = pg.cap ?? 80; let capped = 0, same = 0;
  while (queue.length) {
    const { path: p, c } = queue.shift();
    const key = p.map(s => s.sig + (s.opt !== undefined ? '=' + s.opt : '') + (s.nth ? ' [' + s.nth + ']' : '')).join(' > ');
    if (done.has(key)) continue; done.add(key);
    // the instance header's controls: once per engine (the same header on every page of the instance)
    if (p.length === 1 && /^hdr /.test(c.sig)) { const hk = (pg.engine ?? 'root') + ':' + c.sig; if (hdrSeen.has(hk)) continue; hdrSeen.add(hk); }
    // the grid's own controls: GRID_MAX times a driver, then counted as the same component
    const gk = p[0].sig === 'CTX' ? ['CTX', ...p.slice(1).map(s => gmWords(s.sig))].join(' > ') : gridKey(c.sig);
    if (gk) { const k = gk + (p[p.length - 1].opt !== undefined ? '=' + p[p.length - 1].opt : ''); const n = gridSeen.get(k) ?? 0; if (n >= GRID_MAX) { same++; continue; } gridSeen.set(k, n + 1); }
    // the grid menu's clicks are bounded by GRID_MAX a driver, not by the page's cap (its right-click comes last in the
    // queue: on a page at its cap it was never clicked)
    if (p[0].sig !== 'CTX' && budget-- <= 0) { capped++; out.clicks.push({ scope: pg.scope, page: pg.tab, hash: pg.hash, path: p.map(s => s.sig + (s.opt !== undefined ? ' = ' + s.opt : '')), tag: c.tag, what: c.what, kind: 'over the cap' }); continue; }
    const last = p[p.length - 1];
    const row = { scope: pg.scope, page: pg.tab, hash: pg.hash, path: p.map(s => s.sig + (s.opt !== undefined ? ' = ' + s.opt : '') + (s.nth ? ' [' + s.nth + ']' : '')), tag: c.tag, what: c.what, count: c.n, on: !!c.on };
    try {
      if (c.disabled) { row.kind = c.reason ? 'disabled' : 'off without words'; row.why = c.reason; row.off = await offNotes().catch(() => []); if (!c.reason && row.off.length) row.kind = 'disabled'; out.clicks.push(row); continue; }
      if (c.tag === 'A' && last.sig !== 'CTX' && !/^(dlg|menu) /.test(last.sig) && p.length === 1) {
        const h = c.href || '';
        if (h !== '' && h !== '#' && !h.startsWith('#/') && !h.startsWith('/api/')) { row.kind = 'outside'; row.href = h; out.clicks.push(row); continue; }
      }
      if (c.tag === 'A' && last.sig !== 'CTX' && !/^(dlg|menu) /.test(last.sig) && p.length === 1 && (c.href || '').startsWith('#/')) {
        const h = c.href;
        const okL = await fresh(h); const s = await ev(state).catch(e => ({ errors: [String(e)] }));
        row.href = h; row.landing = { hash: s.hash, h2: s.h2, errors: s.errors, settled: okL }; row.api = net.filter(x => x.status >= 400 || x.status === 0); row.exc = [...exc];
        row.kind = !okL ? 'link-stuck' : (s.errors?.length || row.api.length || row.exc.length) ? 'link-error' : 'link';
        out.clicks.push(row); continue;
      }
      if (c.tag === 'SELECT' && last.opt === undefined) {
        for (const o of (c.opts || []).filter(o => o !== c.cur).slice(0, 5)) queue.unshift({ path: [...p.slice(0, -1), { sig: last.sig, opt: o }], c: { ...c, what: c.what + ' = ' + o } });
        if (p[0].sig !== 'CTX') budget++;   // a path under a right-click took no unit of the page's cap
        continue;
      }
      // replay the path on a fresh page (once more from a fresh page when a step's control is lost: a late redraw can
      // close a menu an earlier step opened), wait for the last step's control without clicking it, and only then
      // read 'before': the page's own late draw never counts as the click's
      let replay = 'ok';
      for (let attempt = 0; attempt < 2; attempt++) {
        await fresh(pg.hash);
        replay = 'ok';
        for (const st of p.slice(0, -1)) { replay = await actWait(st.sig, st); if (replay !== 'ok') break; await sleep(350); await settled(30000); }
        if (replay === 'ok' && !(await there(last.sig))) replay = 'gone';
        if (replay !== 'gone' && replay !== 'no grid cell') break;
      }
      if (replay !== 'ok') { row.kind = 'not reached'; row.why = (p.length > 1 ? 'step ' : '') + replay; out.clicks.push(row); continue; }
      await ev(MARK);
      const before = await ev(state); const ctl0 = new Set((await controls(!!pg.bar)).map(x => x.sig));
      const dl0 = dlCount(); net = []; exc = []; dlgs = []; held = []; chooser = [];
      const r = await act(last.sig, last);
      if (r === 'disabled') {
        // found off at its click (it was on in the list): judged as one found off there - its words, or none
        row.why = await reasonOf(last.sig); row.off = await offNotes().catch(() => []);
        row.kind = row.why || row.off.length ? 'disabled' : 'off without words'; out.clicks.push(row); continue;
      }
      if (r !== 'ok') { row.kind = 'not reached'; row.why = r; out.clicks.push(row); continue; }
      await sleep(600);
      const okC = await settled(30000);
      if (chooser.length) { await sleep(800); await settled(15000); }
      // a link to the server's own file (a .xdl, a .sqlplan): its download is given up to 5 s to start
      if (c.tag === 'A' && /^\/api\//.test(c.href || '')) for (let i = 0; i < 25 && dlCount() <= dl0; i++) await sleep(200);
      // the grid menu's Export Excel and Export file items: the file is built in the page first, given up to 5 s to start
      if (p[0].sig === 'CTX' && /^menu B Export (Excel|file)/.test(p[1]?.sig ?? '') && !/▸$/.test(last.sig)) for (let i = 0; i < 25 && dlCount() <= dl0; i++) await sleep(200);
      const after = await ev(state).catch(e => ({ errors: ['(page gone) ' + e], mark: false }));
      row.api = [...net]; row.exc = [...exc]; row.jsDialogs = [...dlgs]; row.held = [...new Set(held)]; row.chooser = [...chooser];
      row.kind = verdict(row, before, after, dl0);
      if (row.kind === 'NOTHING') { await sleep(1200); if (dlCount() > dl0) row.kind = 'download'; }
      // a click whose page never settled (a 'Reading ...' line still up at the cap) is not judged by what changed
      if (!okC && !['write held', 'reloads', 'navigates', 'download', 'chooser'].includes(row.kind) && !/^api /.test(row.kind) && after.mark) {
        row.seen = row.kind; row.kind = 'click not settled'; row.why = (await ev(BUSYLINES).catch(() => [])).map(b => 'still: ' + b).join(' | ');
      }
      row.api = row.api.filter(x => x.status >= 400 || x.status === 0);
      out.clicks.push(row);
      // a grid cell's button (one per row: Draw, Graph) that only read: the first row's may be the one the page already
      // shows or one with nothing to draw, so the second of the same signature is clicked too, a row of its own ('[2]')
      if (row.kind === 'reads' && p.length === 1 && !last.nth && (c.n ?? 0) > 1 && /(^| )B cell \d+$/.test(last.sig)) {
        queue.unshift({ path: [{ sig: last.sig, nth: 2 }], c: { ...c, what: c.what + ' (the second row\'s)' } }); budget++;
      }
      // what the click added: one level deeper (not after a page change)
      if (p.length < 3 && after.mark && after.hash === before.hash) {
        const now = await controls(!!pg.bar).catch(() => []);
        for (const x of now.filter(x => !ctl0.has(x.sig)).slice(0, 25)) queue.push({ path: [...p, { sig: x.sig }], c: x });
      }
    } catch (e) { row.kind = lost ? 'browser lost' : 'driver error'; row.why = e.message; out.clicks.push(row); console.error(`${label}: ${row.kind} at ${key}: ${e.message}`); await ensure().catch(err => console.error('ensure: ' + err.message)); }
  }
  if (capped) out.pages[out.pages.length - 1].capped = capped;
  if (same) out.pages[out.pages.length - 1].same = same;
  save();
  console.error(`${label} ${pg.scope} ${pg.hash}: ${out.clicks.filter(x => x.hash === pg.hash).length} clicks${capped ? `, ${capped} over the cap` : ''}, ${Math.round((Date.now() - t0) / 1000)} s`);
}

// ---- the tree (the chrome shard): the fleet root's own folders (data-key r/...) opened and the tag folders' carets
// (f:...) each clicked once; the picked instance's own subtree (i<id>, i<id>/<folder>, its first database and that
// database's tables) opened; every caret of those clicked once and every leaf clicked from a fresh page, one leaf per
// route and parameter names (a database's or a table's leaf once) --------------------------------------------------
// the root last: its tag folders' carets close folders the instances' subtrees sit in
const treeScopes = shard.chrome ? [...(shard.pg ? [{ scope: 'pg', hash: `#/summary?i=${shard.pg.id}`, id: shard.pg.id }] : []), ...(shard.ms ? [{ scope: 'ms', hash: `#/summary?i=${shard.ms.id}`, id: shard.ms.id }] : []), { scope: 'root', hash: '#/summary' }] : [];
// the carets of a scope, by data-key: open = to be opened by openAll; all = to be clicked once
function caretKeys(sc) {
  const keys = [...document.querySelectorAll('#tree button.caret')].map(b => b.dataset.key || '');
  if (!sc.id) return { open: keys.filter(k => k.startsWith('r/')), all: keys.filter(k => k.startsWith('r/') || k.startsWith('f:')) };
  const own = keys.filter(k => k === 'i' + sc.id || k.startsWith('i' + sc.id + '/'));
  const firstDb = own.map(k => (new RegExp('^i' + sc.id + '/db/(\\d+)').exec(k) ?? [])[1]).find(Boolean);
  const ok = k => { const m = new RegExp('^i' + sc.id + '/db/(\\d+)').exec(k); return !m || m[1] === firstDb; };
  const mine = own.filter(ok);
  return { open: mine, all: mine };
}
function treeLeaves(sc) {
  const fold = h => h.replace(/=[^&]*/g, '=');
  const seen = new Map();
  for (const a of document.querySelectorAll('#tree a[href]')) {
    const h = a.getAttribute('href') || ''; const m = /[?&]i=(\d+)/.exec(h);
    if (sc.id ? m?.[1] !== sc.id : !!m) continue;
    if (a.closest('.tm-drive')) continue;   // a drive node: its own leaf below (treeDrives)
    if (!seen.has(fold(h))) seen.set(fold(h), [h, (a.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 60)]);
  }
  return [...seen.values()];
}
// the drive nodes under the scope's instance's Storage folder (treemenu.ts driveNodes): each by its volume, its link's
// address and words (the free space, of the total) and its bar (its level and the used share drawn); a node's link has
// the Storage tab's own address, so the leaves above (one per address) never reach it. state: still reading / an error
function treeDrives(sc) {
  const mine = d => /[?&]i=(\d+)/.exec(d.querySelector('a[href]')?.getAttribute('href') || '')?.[1] === String(sc.id);
  // one node per volume and address: an instance under two tag folders draws its Storage folder twice
  const seen = new Set();
  const nodes = [...document.querySelectorAll('#tree .tm-drive')].filter(mine).filter(d => { const k = (d.dataset.volume || '') + '|' + d.querySelector('a[href]').getAttribute('href'); if (seen.has(k)) return false; seen.add(k); return true; }).map(d => {
    const a = d.querySelector('a[href]'), bar = d.querySelector('.tm-bar'), fill = bar?.querySelector('span');
    return { vol: d.dataset.volume || '', href: a.getAttribute('href'), title: a.title || (a.textContent || '').trim(),
      bar: bar ? (bar.className.replace(/\btm-bar\b/, '').trim() || 'no level') + (fill ? ' ' + fill.style.width + ' used' : ' (no fill)') : '' };
  });
  const p = [...document.querySelectorAll('#tree p')].map(x => x.textContent.trim()).find(t => /^Reading the drives|^Drives: /.test(t)) ?? '';
  return { nodes, state: p };
}
const openAll = async sc => {
  for (let round = 0; round < 6; round++) {
    const want = (await call(caretKeys, sc).catch(() => ({ open: [] }))).open;
    const n = await ev(`(() => { const want = new Set(${JSON.stringify(want)}); let n = 0; for (const b of document.querySelectorAll('#tree button.caret')) if (want.has(b.dataset.key) && b.getAttribute('aria-expanded') === 'false') { b.click(); n++; } return n; })()`).catch(() => 0);
    if (!n) break; await sleep(700);
  }
};
for (const sc of treeScopes) {
  let carets, leaves;
  try { await fresh(sc.hash); await openAll(sc); carets = (await call(caretKeys, sc)).all; leaves = await call(treeLeaves, sc); out.tree.push({ scope: sc.scope, carets: carets.length, leaves: leaves.length }); }
  catch (e) { out.tree.push({ scope: sc.scope, page: 'tree', hash: sc.hash, path: ['(the tree)'], kind: 'driver error', why: e.message }); await ensure().catch(() => {}); continue; }
  for (const key of carets) {
    const row = { scope: sc.scope, page: 'tree', hash: sc.hash, path: ['tree caret ' + key.replace(/\d+/g, '#')], tag: 'BUTTON', what: key };
    try {
      await fresh(sc.hash); await openAll(sc); await ev(MARK);
      const before = await ev(state); const dl0 = dlCount(); net = []; exc = []; dlgs = []; held = []; chooser = [];
      const lab = await ev(`(() => { const b = [...document.querySelectorAll('#tree button.caret')].find(b => b.dataset.key === ${JSON.stringify(key)}); if (!b) return null; const l = b.getAttribute('aria-label'); b.click(); return l; })()`);
      if (lab === null) { row.kind = 'not reached'; row.why = 'gone'; out.tree.push(row); continue; }
      row.what = lab; await sleep(500);
      const after = await ev(state); row.api = [...net]; row.exc = [...exc]; row.jsDialogs = [...dlgs]; row.held = [...new Set(held)]; row.chooser = [...chooser];
      row.kind = verdict(row, before, after, dl0); row.api = row.api.filter(x => x.status >= 400 || x.status === 0);
    } catch (e) { row.kind = lost ? 'browser lost' : 'driver error'; row.why = e.message; await ensure().catch(() => {}); }
    out.tree.push(row);
  }
  for (const [href, what] of leaves) {
    const row = { scope: sc.scope, page: 'tree', hash: sc.hash, path: ['tree A ' + href.replace(/=[^&]*/g, '=')], tag: 'A', what, href };
    try {
      await fresh(sc.hash); await openAll(sc); net = []; exc = [];
      const h0 = await ev('location.hash').catch(() => '');
      const clickLeaf = () => ev(`(() => { const a = [...document.querySelectorAll('#tree a[href]')].find(a => a.getAttribute('href') === ${JSON.stringify(href)}); if (!a) return false; a.click(); return true; })()`);
      let clicked = await clickLeaf();
      // once more on the tree opened again, said in the row and the log: a leaf listed from this tree and gone in its own
      // pass (the root's Community tools once, its two neighbours found); the grade counts the leaves found so
      if (!clicked) {
        await sleep(1000); await openAll(sc); net = []; exc = []; clicked = await clickLeaf();
        if (clicked) { row.look = 2; console.error(`${label}: the tree leaf ${href} found on the second look`); }
      }
      if (!clicked) { row.kind = 'not reached'; row.why = 'not in the opened tree'; out.tree.push(row); continue; }
      await sleep(300);
      const okL = await settled(); const s = await ev(state).catch(e => ({ errors: [String(e)] }));
      row.api = net.filter(x => x.status >= 400 || x.status === 0); row.exc = [...exc]; row.landing = { hash: s.hash, h2: s.h2, errors: s.errors, settled: okL, busy: okL ? [] : await ev(BUSYLINES).catch(() => []) };
      // a leaf whose click left the page where it was (not its own address): NOTHING
      row.kind = !okL ? 'link-stuck' : (s.errors?.length || row.api.length || row.exc.length) ? 'link-error' : s.hash === href ? 'link' : s.hash === h0 ? 'NOTHING' : 'navigates';
    } catch (e) { row.kind = lost ? 'browser lost' : 'driver error'; row.why = e.message; await ensure().catch(() => {}); }
    out.tree.push(row);
  }
  // an instance's drive nodes (A22 / G05): each clicked from a fresh page as its own leaf, its bar in the row; none drawn
  // within 10 s of the Storage folder opening is a row 'not reached' with what the folder said
  if (sc.id) {
    const drivesOf = async () => { let d = { nodes: [], state: '' }; for (const t = Date.now(); Date.now() - t < 10000; await sleep(250)) { d = await call(treeDrives, sc).catch(() => d); if (d.nodes.length || /^Drives: /.test(d.state)) break; } return d; };
    let drives = { nodes: [], state: '' };
    try { await fresh(sc.hash); await openAll(sc); drives = await drivesOf(); }
    catch (e) { drives.state = 'driver error: ' + e.message; await ensure().catch(() => {}); }
    if (!drives.nodes.length) out.tree.push({ scope: sc.scope, page: 'tree', hash: sc.hash, path: ['tree drive (none)'], tag: 'A', kind: 'not reached', why: 'no drive node under the Storage folder' + (drives.state ? ': ' + drives.state : '') });
    for (const d of drives.nodes) {
      const row = { scope: sc.scope, page: 'tree', hash: sc.hash, path: ['tree drive ' + d.vol], tag: 'A', what: d.title, href: d.href, bar: d.bar };
      try {
        await fresh(sc.hash); await openAll(sc); await drivesOf(); net = []; exc = [];
        const h0 = await ev('location.hash').catch(() => '');
        const clicked = await ev(`(() => { const n = [...document.querySelectorAll('#tree .tm-drive')].find(n => n.dataset.volume === ${JSON.stringify(d.vol)} && n.querySelector('a[href]')?.getAttribute('href') === ${JSON.stringify(d.href)}); const a = n?.querySelector('a[href]'); if (!a) return false; a.click(); return true; })()`);
        if (!clicked) { row.kind = 'not reached'; row.why = 'the drive node gone'; out.tree.push(row); continue; }
        await sleep(300);
        const okL = await settled(); const s = await ev(state).catch(e => ({ errors: [String(e)] }));
        row.api = net.filter(x => x.status >= 400 || x.status === 0); row.exc = [...exc]; row.landing = { hash: s.hash, h2: s.h2, errors: s.errors, settled: okL, busy: okL ? [] : await ev(BUSYLINES).catch(() => []) };
        // a node with no bar drawn is NOTHING to the eye: it says nothing of the volume's space
        row.kind = !okL ? 'link-stuck' : (s.errors?.length || row.api.length || row.exc.length) ? 'link-error' : !d.bar ? 'NOTHING' : s.hash === d.href ? 'link' : s.hash === h0 ? 'NOTHING' : 'navigates';
        if (!d.bar) row.why = 'no bar beside the volume';
      } catch (e) { row.kind = lost ? 'browser lost' : 'driver error'; row.why = e.message; await ensure().catch(() => {}); }
      out.tree.push(row);
    }
  }
  save();
}
out.chromeStarts = starts; out.seconds = Math.round((Date.now() - t0) / 1000);
save();
console.error(`${label}: done in ${out.seconds} s, ${out.pages.length} pages, ${out.clicks.length} clicks, ${out.tree.filter(r => r.kind).length} tree rows, chromium started ${starts} time(s)`);
try { chrome?.kill('SIGTERM'); } catch {}
process.exit(0);
