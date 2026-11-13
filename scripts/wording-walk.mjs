// The wording walk (the pre-publish walk, DONE-1): every page an instance of each engine reaches, and the fleet pages
// on a tag folder of one engine, read as a reader sees them and checked for the other engine's words
// (scripts/wording-match.mjs; the words, the allow rows and the expected reds beside it). Usage:
//   node scripts/wording-walk.mjs <cdp port> <base url/> <json out> [<shots dir>]
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil demo ... -serve -listen 127.0.0.1:<port>
// The scopes (the design D2 as folded): two PostgreSQL instances (the first on-premises and the first RDS one by
// name) and the instance with the Pooler tab; two SQL Server instances (the first 'sqlserver' and the first
// 'azuresqlmi'); the tag held by most instances of exactly one engine, per engine (ties by name); the drill pages a
// visited page links to (db, table, index, job, compare: the first of each kind per engine); the mixed root's
// Summary and Alerts, and the first alert, read only for their row-scoped elements, each against its row's engine.
// Prints one RED line per distinct red (its pages counted), the grade against scripts/wording-expected.txt, and
// 'wording walk: OK' or 'wording walk: FAIL (...)'; exit 1 on a FAIL. The JSON out holds every page and every red.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { check, grade, loadAllow, loadExpected, loadWords, validateExpected } from './wording-match.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const [port, base, outFile, shots] = process.argv.slice(2);
if (!port || !base || !outFile) { console.error('usage: node scripts/wording-walk.mjs <cdp port> <base url/> <json out> [<shots dir>]'); process.exit(2); }
const U = base.endsWith('/') ? base : base + '/';
const words = loadWords(fs.readFileSync(path.join(here, 'wording-words.txt'), 'utf8'));
const allow = loadAllow(fs.readFileSync(path.join(here, 'wording-allow.txt'), 'utf8'));
const expected = loadExpected(fs.readFileSync(path.join(here, 'wording-expected.txt'), 'utf8'));
const unknown = validateExpected(expected, words);
if (unknown.length) { for (const u of unknown) console.log('FAIL ' + u); process.exit(1); }

// the fleet, its engines and its user-data names (U)
const inst = await (await fetch(U + 'api/instances')).json();
const fleet = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const engineOf = new Map(fleet.map(r => [String(r.instance_id), r.engine === 'sqlserver' ? 'sqlserver' : 'postgres']));
const tagsOf = r => (Array.isArray(r.tags) ? r.tags : String(r.tags ?? '').split(/[\s,{}]+/)).filter(Boolean);
const globalNames = new Set();
for (const r of fleet) {
  globalNames.add(String(r.name));
  for (const t of tagsOf(r)) { globalNames.add(t); if (t.includes(':')) for (const p of t.split(':')) globalNames.add(p); }
  for (const k of ['host', 'dbname', 'databases']) if (r[k]) for (const v of String(r[k]).split(/[\s,{}]+/)) if (v) globalNames.add(v);
}
const byName = (a, b) => String(a.name).localeCompare(String(b.name));
const first = pred => fleet.filter(pred).sort(byName)[0];
const pgOnprem = first(r => r.engine !== 'sqlserver' && r.platform === 'onprem');
const pgCloud = first(r => r.engine !== 'sqlserver' && r.platform === 'rds') ?? first(r => r.engine !== 'sqlserver' && r.platform !== 'onprem');
const msPrimary = first(r => r.engine === 'sqlserver' && r.platform === 'sqlserver');
const msManaged = first(r => r.engine === 'sqlserver' && r.platform === 'azuresqlmi');
// the tag held by most instances of exactly one engine (ties by name)
const tagCount = new Map();
for (const r of fleet) for (const t of tagsOf(r)) { const c = tagCount.get(t) ?? { n: 0, engines: new Set() }; c.n++; c.engines.add(engineOf.get(String(r.instance_id))); tagCount.set(t, c); }
const oneTag = e => [...tagCount.entries()].filter(([t, c]) => c.engines.size === 1 && c.engines.has(e) && t !== 'demo').sort((a, b) => b[1].n - a[1].n || a[0].localeCompare(b[0]))[0]?.[0];
const pgTag = oneTag('postgres'), msTag = oneTag('sqlserver');

// the browser
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
const call = (fn, arg) => ev(`(${fn.toString()})(${JSON.stringify(arg ?? null)})`);
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: 'light' }] });
await cmd('Emulation.setLocaleOverride', { locale: 'en-US' }).catch(() => null);

// settled: the shell replaced its 'Loading...' and an instance page's header came (a11y-check's rule)
const settled = async (ms = 15000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^Loading/.test(e.textContent)) && m.children.length > 0; })()`);
    if (ok) {
      for (let i = 0; i < 50 && await ev(`/[?&]i=/.test(location.hash) && !document.querySelector('main .inst-header')`); i++) await sleep(100);
      await sleep(400); return true;
    }
    await sleep(150);
  }
  return false;
};
const open = async (hash) => { await cmd('Page.navigate', { url: U + hash }); await sleep(250); return settled(); };
const tabsOf = async (hash) => { await open(hash); return await ev(`(() => { const t = document.querySelector('#tabs'); return t?.dataset.all ? JSON.parse(t.dataset.all) : [...(t?.querySelectorAll('a') ?? [])].map(a => a.getAttribute('href')); })()`) ?? []; };

// read (in the page): every element a reader sees, by kind; the user-data columns' cells and the tree's instance and
// tag names come back as names (U). row = true: only the mixed root's row-scoped elements, each with its instance.
function read(row) {
  const vis = e => { try { return e.checkVisibility ? e.checkVisibility() : !!e.offsetParent; } catch { return true; } };
  const txt = e => (e?.textContent ?? '').replace(/\s+/g, ' ').trim();
  const out = [], names = new Set(), seen = new Set();
  const push = (kind, text, iid) => { const t = String(text ?? '').replace(/\s+/g, ' ').trim(); const k = kind + '\u0001' + t + '\u0001' + (iid ?? ''); if (t && !seen.has(k)) { seen.add(k); out.push({ kind, text: t, iid }); } };
  const attrs = (x, iid) => { for (const a of ['title', 'aria-label', 'aria-description', 'placeholder', 'alt']) { const v = x.getAttribute?.(a); if (v) push('attr', v, iid); } };
  const iidOf = e => { const a = e.querySelector?.('a[href*="i="]') ?? (e.matches?.('a[href*="i="]') ? e : null); return a ? (/[?&]i=(\d+)/.exec(a.getAttribute('href')) ?? [])[1] : undefined; };
  const main = document.querySelector('main');
  if (!main) return { out, names: [] };
  const USER = /^(instance|instances|server|database|databases|db|file|file name|physical name|statement|query|query text|sql text|job|job name|login|login name|user|user name|host|host name|tag|tags|table|index|schema|object|role|program|application|client|session|name)$/i;
  for (const t of main.querySelectorAll('table')) {
    if (!vis(t)) continue;
    const heads = [...t.querySelectorAll('thead th')].map(h => txt(h).replace(/[▲▼↑↓]/g, '').trim());
    if (!row) heads.forEach(h => push('th', h));
    const user = new Set(heads.map((h, i) => USER.test(h) ? i : -1).filter(i => i >= 0));
    for (const tr of t.querySelectorAll('tbody tr')) {
      const iid = row ? iidOf(tr) : undefined;
      if (row && !iid) continue;
      [...tr.children].forEach((td, i) => {
        if (user.has(i)) { const v = txt(td); if (v) names.add(v); } else push('cell', txt(td), iid);
        for (const x of [td, ...td.querySelectorAll('*')]) attrs(x, iid);
      });
    }
  }
  for (const e of main.querySelectorAll('p, li')) {
    if (!vis(e) || e.closest('table') || (e.matches('li') && e.querySelector('p'))) continue;
    const iid = row ? iidOf(e) : undefined;
    if (row && !iid) continue;
    push('prose', txt(e), iid);
    if (row) for (const x of [e, ...e.querySelectorAll('*')]) attrs(x, iid);
  }
  if (row) return { out, names: [...names] };
  for (const e of main.querySelectorAll('h1, h2, h3, h4')) if (vis(e)) push('heading', [...e.childNodes].filter(c => !(c.nodeType === 1 && c.matches('button, select'))).map(c => c.textContent).join(' '));
  for (const e of document.querySelectorAll('main button, #bar button')) if (vis(e)) push('button', txt(e));
  for (const e of document.querySelectorAll('#tabs a')) if (vis(e)) push('tab', txt(e));
  for (const e of main.querySelectorAll('.tile-l')) if (vis(e)) push('tile', txt(e));
  for (const e of main.querySelectorAll('svg text, .legend, .chart-legend')) if (vis(e)) push('legend', txt(e));
  for (const e of main.querySelectorAll('option')) push('option', txt(e));
  for (const e of main.querySelectorAll('dialog[open], [role=dialog]')) push('dialog', txt(e));
  for (const x of document.querySelectorAll('main *, #tabs *, #bar *')) if (!x.closest('table') && vis(x)) attrs(x);
  // the tree: the current instance's own folders, or (on a fleet page) the scope's folders before the tag folders;
  // the instance rows and the tag folders' names are the user's
  const tree = document.querySelector('#tree');
  if (tree) {
    const cur = (/[?&]i=(\d+)/.exec(location.hash) ?? [])[1];
    let inBlock = false, beforeTag = true;
    for (const n of tree.querySelectorAll('.tree-inst, .tree-node, .folder-name')) {
      if (n.matches('.tree-inst')) { const a = n.querySelector('a.inst'); names.add(txt(a ?? n).replace(/^[^\w]+/, '').trim()); inBlock = !!cur && (/[?&]i=(\d+)/.exec(a?.getAttribute('href') ?? '') ?? [])[1] === cur; continue; }
      if (n.matches('.folder-name')) { names.add(txt(n)); beforeTag = false; inBlock = false; continue; }
      if (n.closest('.tree-inst')) continue;
      const own = [...n.childNodes].filter(c => !(c.nodeType === 1 && c.matches('.tree-node, ul, ol'))).map(c => c.textContent).join(' ');
      if (cur ? inBlock : beforeTag) push('tree', own);
    }
  }
  return { out, names: [...names] };
}
// the instance's tree menu, once per engine: its items as a reader sees them
function treeMenu() {
  const cur = (/[?&]i=(\d+)/.exec(location.hash) ?? [])[1];
  const a = [...document.querySelectorAll('#tree a.inst')].find(x => (/[?&]i=(\d+)/.exec(x.getAttribute('href') ?? '') ?? [])[1] === cur);
  if (!a) return null;
  const r = a.getBoundingClientRect();
  a.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 5, clientY: r.top + 5 }));
  return new Promise(res => setTimeout(() => {
    const items = [...document.querySelectorAll('[role=menu] [role=menuitem]')].map(b => b.textContent.replace(/\s+/g, ' ').trim());
    document.activeElement?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
    res(items);
  }, 300));
}
// the drill links a page holds (the first of each kind)
function drills() {
  const out = {};
  for (const a of document.querySelectorAll('main a[href^="#/"]')) { const m = /^#\/(db|table|index|job|compare)\?/.exec(a.getAttribute('href')); if (m && !out[m[1]]) out[m[1]] = a.getAttribute('href'); }
  const al = document.querySelector('main a[href^="#/alert?"]');
  if (al) out.alert = al.getAttribute('href');
  return out;
}

// the pages, each with its scope and engine
const pages = []; const notes = [];
const add = (scope, engine, hash) => { if (hash && !pages.some(p => p.hash === hash)) pages.push({ scope, engine, hash }); };
const instPages = async (r, only) => {
  if (!r) return;
  const eng = engineOf.get(String(r.instance_id)), scope = eng === 'sqlserver' ? 'ms-instance' : 'pg-instance';
  for (const t of await tabsOf(`#/summary?i=${r.instance_id}`)) {
    const h = String(t).replace(/^#?\/?/, '#/').replace(/i=\d+/, `i=${r.instance_id}`);
    if (!only || only.test(h)) add(scope, eng, h);
  }
};
await instPages(pgOnprem); await instPages(pgCloud); await instPages(msPrimary); await instPages(msManaged);
// the instance with the Pooler tab (main.ts: only where a pooler was read)
let pooler = null;
for (const r of fleet.filter(x => x.engine !== 'sqlserver').sort(byName)) {
  const ts = await tabsOf(`#/summary?i=${r.instance_id}`);
  if (ts.some(t => /#\/pooler\?/.test(t))) { pooler = r; break; }
}
if (pooler) await instPages(pooler, /#\/(pooler|summary)\?/); else notes.push('no instance has the Pooler tab: the Pooler page was not read');
for (const [tag, eng] of [[pgTag, 'postgres'], [msTag, 'sqlserver']]) {
  if (!tag) { notes.push(`no tag holds only ${eng} instances: its fleet scope was not read`); continue; }
  for (const t of await tabsOf(`#/summary?tag=${encodeURIComponent(tag)}`)) add(eng === 'sqlserver' ? 'ms-tag' : 'pg-tag', eng, String(t).replace(/^#?\/?/, '#/'));
}
for (const h of ['#/summary', '#/alerts']) add('root', null, h);

// walk
const t0 = Date.now(); const reds = []; const pageRows = []; const drillSeen = new Set(); const menuSeen = new Set();
if (shots) fs.mkdirSync(shots, { recursive: true });
for (let k = 0; k < pages.length; k++) {
  const p = pages[k]; const t1 = Date.now();
  const ok = await open(p.hash);
  const row = p.scope === 'root';
  const got = ok ? await call(read, row) : { out: [], names: [] };
  const names = [...globalNames, ...got.names];
  let n = 0;
  for (const e of got.out) {
    const eng = row ? engineOf.get(String(e.iid)) : p.engine;
    if (!eng) continue;
    const scope = row ? (eng === 'sqlserver' ? 'root-ms-row' : 'root-pg-row') : p.scope;
    for (const r of check({ text: e.text, kind: e.kind, page: p.hash.slice(2) }, { engine: eng, words, allow, names })) {
      reds.push({ scope, page: p.hash.slice(2), kind: e.kind, word: r.word, text: e.text.slice(0, 240), sentence: r.sentence.slice(0, 240), source: r.source }); n++;
    }
  }
  // once per engine: the instance's tree menu; on every page: the drill links and the first alert, read after
  if (!row && /-instance$/.test(p.scope) && !menuSeen.has(p.engine)) {
    const items = await call(treeMenu);
    if (items) { menuSeen.add(p.engine); for (const it of items) for (const r of check({ text: it, kind: 'menuitem', page: p.hash.slice(2) }, { engine: p.engine, words, allow, names })) { reds.push({ scope: p.scope, page: p.hash.slice(2), kind: 'menuitem', word: r.word, text: it, sentence: it, source: r.source }); n++; } }
  }
  if (ok) for (const [kind, h] of Object.entries(await call(drills) ?? {})) {
    const key = (p.engine ?? 'root') + ':' + kind;
    if (drillSeen.has(key)) continue; drillSeen.add(key);
    if (kind === 'alert') add('root', null, h); else if (p.engine) add(p.scope.replace('-tag', '-instance'), p.engine, h);
  }
  if (shots) { const s = await cmd('Page.captureScreenshot', { format: 'png' }); fs.writeFileSync(path.join(shots, `${String(k).padStart(3, '0')}-${p.hash.slice(2).replace(/[^\w=-]+/g, '_').slice(0, 80)}.png`), Buffer.from(s.result.data, 'base64')); }
  pageRows.push({ ...p, rendered: ok, elements: got.out.length, reds: n, ms: Date.now() - t1 });
  if (!ok) notes.push(`${p.hash} did not render in 15 s`);
}

// the table and the grade
const count = s => pageRows.filter(p => p.scope === s).length;
console.log(`picked: PostgreSQL ${pgOnprem?.name}, ${pgCloud?.name}${pooler ? ', the Pooler on ' + pooler.name : ''}; SQL Server ${msPrimary?.name}, ${msManaged?.name}; tags ${pgTag} (PostgreSQL), ${msTag} (SQL Server)`);
console.log(`pages: ${pageRows.length} (pg-instance ${count('pg-instance')}, ms-instance ${count('ms-instance')}, pg-tag ${count('pg-tag')}, ms-tag ${count('ms-tag')}, root ${count('root')}) in ${Math.round((Date.now() - t0) / 1000)} s; ${pageRows.reduce((a, p) => a + p.elements, 0)} elements read; ${pageRows.filter(p => !p.rendered).length} not rendered`);
const distinct = new Map();
for (const r of reds) { const k = [r.scope, r.kind, r.word, r.text].join('\u0001'); const d = distinct.get(k) ?? { ...r, pages: [] }; d.pages.push(r.page); distinct.set(k, d); }
for (const d of distinct.values()) console.log(`RED ${d.scope} ${d.kind} '${d.word}' on ${d.pages.length} page(s) (#/${d.pages[0]}${d.pages.length > 1 ? ' ...' : ''}): ${JSON.stringify(d.text.slice(0, 160))}`);
const g = grade(reds, expected);
for (const e of g.rows) {
  const where = `${e.scope} ${e.pageText} ${e.kind} '${e.word}'`;
  if (e.status === 'must') console.log(`${e.hits.length ? 'listed' : 'MISSING'} must ${where}: ${e.hits.length} red(s)${e.hits.length ? '' : ' (expected, not seen)'}; fix: ${e.fix}`);
  else if (e.status === 'may') console.log(`may ${e.hits.length ? 'seen' : 'not seen'} ${where}: ${e.hits.length} red(s); fix: ${e.fix}`);
  else console.log(`${e.hits.length ? 'SEEN' : 'gone'} must-not ${where}${e.hits.length ? ': ' + JSON.stringify(e.hits[0].text.slice(0, 120)) : ''}`);
}
const newDistinct = new Map();
for (const r of g.outside) { const k = [r.scope, r.kind, r.word].join('\u0001'); const d = newDistinct.get(k) ?? { ...r, pages: new Set() }; d.pages.add(r.page); newDistinct.set(k, d); }
for (const d of newDistinct.values()) console.log(`NEW ${d.scope} ${d.kind} '${d.word}' on ${d.pages.size} page(s) (#/${[...d.pages][0]}): ${JSON.stringify(d.text.slice(0, 160))} [${d.source}]`);
for (const n of notes) console.log('note: ' + n);
console.log('not read by the walk (the click-through opens them): the dialogs behind write controls (off on the demo without a login), the help shown only on a click; exports and mail carry the grids\' own th');
fs.writeFileSync(outFile, JSON.stringify({ picked: { pgOnprem: pgOnprem?.name, pgCloud: pgCloud?.name, pooler: pooler?.name, msPrimary: msPrimary?.name, msManaged: msManaged?.name, pgTag, msTag }, pages: pageRows, reds, grade: { mustMissing: g.mustMissing.map(e => e.word + ' ' + e.pageText), mustNotSeen: g.mustNotSeen.map(e => e.word + ' ' + e.pageText), outside: g.outside }, notes }, null, 1));
const bad = [g.mustMissing.length && `${g.mustMissing.length} must row(s) not seen`, g.mustNotSeen.length && `${g.mustNotSeen.length} must-not row(s) seen`, newDistinct.size && `${newDistinct.size} red(s) outside the expected file`, pageRows.some(p => !p.rendered) && 'a page did not render'].filter(Boolean);
console.log(bad.length ? `wording walk: FAIL (${bad.join('; ')})` : `wording walk: OK (${distinct.size} distinct red(s), each listed)`);
ws.close(); process.exit(bad.length ? 1 : 0);
