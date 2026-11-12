// The click map (task 176): from the Summary at the root, a tag folder and an instance of each engine, every link of
// the test grid, the instance grid and the Needs attention strip, the tree's Storage node, and every tab of the
// Storage folder, over a headless Chromium (CDP), each landing checked against DBA Dash's map (Checks/Summary.cs: the
// column-to-tab map L65, L607-627; the test links L731-789). Usage:
//   node scripts/click-check.mjs <cdp port> <base url/> [<json out>]
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil demo ... -serve -listen 127.0.0.1:<port>
// Every link's target is read from its href and checked; one link per column, engine and scope is also clicked and
// its landing read (the tab in the address, the page drawn with no error box); CLICK_ALL=1 clicks every link.
// A landing on Daily checks fails unless the map says so. Prints one line per link kind and a table; exit 1 on a FAIL.
const [port, U, outPath] = process.argv.slice(2);
const clickAll = process.env.CLICK_ALL === '1';
const fs = await import('node:fs');
const table = async p => { const t = await (await fetch(U + 'api/' + p)).json(); return t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]]))); };
const insts = await table('instances');
const pg = insts.find(r => r.engine !== 'sqlserver' && String(r.name).endsWith('onprem-erp01')) ?? insts.find(r => r.engine !== 'sqlserver');
const ms = insts.find(r => r.engine === 'sqlserver' && String(r.name).endsWith('sql01')) ?? insts.find(r => r.engine === 'sqlserver');
if (!pg || !ms) { console.log('FAIL the demo has no PostgreSQL or no SQL Server instance'); process.exit(1); }
// the tag folder: the tag most instances carry of those that hold both engines and are not on every instance (the
// demo's env:prod), so the folder is narrower than the root
const tagCount = new Map();
for (const r of insts) for (const t of (Array.isArray(r.tags) ? r.tags : [])) {
  const e = tagCount.get(t) ?? { n: 0, engines: new Set() }; e.n++; e.engines.add(r.engine === 'sqlserver' ? 'sqlserver' : 'postgres'); tagCount.set(t, e);
}
const tag = [...tagCount.entries()].filter(([, e]) => e.n < insts.length && e.engines.size === 2).sort((a, b) => b[1].n - a[1].n || (a[0] < b[0] ? -1 : 1))[0]?.[0];
if (!tag) { console.log('FAIL the demo has no tag that holds both engines and not every instance'); process.exit(1); }
const engineOf = new Map(insts.map(r => [Number(r.instance_id), r.engine === 'sqlserver' ? 'sqlserver' : 'postgres']));

// DBA Dash's map (task P08: the Summary's columns under DBA Dash's names, Checks/Summary.cs tabMapping): column (or
// test) -> the tab it lands on per engine, the view (cv) a SQL Server tab must open on, and DBA Dash's own target. A
// column DBA Dash does not have is checked against the never-Daily-checks rule alone.
const dbadash = {
  'Corruption':          { postgres: ['corruption'], sqlserver: ['mssqlchecks'], cv: { sqlserver: 'build' }, dd: 'Corruption -> the instance\'s corruption viewer (pgvigil: the Corruption page; SQL Server: the Checks page\'s suspect pages)' },
  'Last Good Check DB':  { postgres: ['corruption'], sqlserver: ['mssqlchecks'], cv: { sqlserver: 'databases' }, dd: 'Last Good Check DB -> Checks > Last Good CheckDB' },
  'SQL Agent Alerts':    { sqlserver: ['mssqlchecks'], cv: { sqlserver: 'alerts' }, dd: 'SQL Agent Alerts -> Configuration > SQL Agent Alerts' },
  'Backup FULL':         { postgres: ['backups'], sqlserver: ['mssqlbackups'], dd: 'Backup FULL -> HA/DR > Backups' },
  'Backup DIFF':         { sqlserver: ['mssqlbackups'], dd: 'Backup DIFF -> HA/DR > Backups' },
  'Backup LOG':          { postgres: ['backups'], sqlserver: ['mssqlbackups'], dd: 'Backup LOG -> HA/DR > Backups' },
  'Drive Space':         { postgres: ['drives'], sqlserver: ['drives'], dd: 'Drive Space -> Storage > Drives' },
  'Agent Jobs':          { postgres: ['jobsreport', 'jobs'], sqlserver: ['mssqljobs'], dd: 'Agent Jobs -> Jobs > Job Status' },
  'Log Shipping':        { postgres: ['pgbackups'], sqlserver: ['availability'], dd: 'Log Shipping -> HA/DR > Log Shipping' },
  'Mirroring':           { sqlserver: ['availability'], dd: 'Mirroring -> HA/DR > Mirroring' },
  'Availability Groups': { postgres: ['replication'], sqlserver: ['availability'], dd: 'Availability Groups -> HA/DR > Availability Groups' },
  'Log Space':           { sqlserver: ['dbfiles'], dd: 'Log Space -> Storage > Files' },
  'File Space':          { sqlserver: ['dbfiles'], dd: 'File Space -> Storage > Files' },
  'QS':                  { postgres: ['pgstate'], sqlserver: ['mssqlqs'], dd: 'QS -> Configuration > QS (PostgreSQL: the statement store on Server state)' },
  'Custom Checks':       { postgres: ['custom'], dd: 'Custom Checks -> Checks > Custom Checks' },
  'Snapshot Age':        { postgres: ['collectiondates'], sqlserver: ['collectiondates'], dd: 'Snapshot Age -> Checks > Collection Dates' },
  'Identity Columns':    { sqlserver: ['mssqlchecks'], cv: { sqlserver: 'identity' }, dd: 'Identity Columns -> Checks > Identity Columns' },
  'Database State':      { postgres: ['pgdboptions'], sqlserver: ['mssqlchecks'], cv: { sqlserver: 'databases' }, dd: 'Database State -> Configuration > DB Options' },
  '% Max Size':          { sqlserver: ['dbfiles'], dd: '% Max Size -> Storage > Files' },
  // the landing checked, the difference from DBA Dash's page named in the verdict (argued in the report)
  'Collection Errors (24hrs)': { postgres: ['collectiondates'], sqlserver: ['collectiondates'], dd: 'DBA Dash Errors (24hrs) -> Checks > DBA Dash ErrorLog',
    diff: 'pgvigil has no error-log page yet (E205, parity task P13): Collection dates, whose rows carry each collection\'s last error' },
};
// the differences named (pgvigil lands elsewhere, argued in the report): column -> words
const named = {};
// DBA Dash's cells that are text, not links (Checks/Summary.cs: no tab, no dialog)
const plainColumns = ['Memory Dump', 'Is Agent Running', 'DB Mail'];
// Instance Uptime: DBA Dash's Summary opens the Instance Uptime threshold dialog over the grid; the click must too
const dialogColumns = new Set(['Instance Uptime']);
// the test grid's names that open a page (pages.ts rootTabOf) and DBA Dash's target where it has one
const testWant = { 'Drive Space': 'drives', 'Backup FULL': 'backups', 'Backup LOG': 'backups', 'Agent Jobs': 'jobs', 'Snapshot Age': 'collectiondates',
  'Collection Errors (24hrs)': 'collectiondates', 'Last Good Check DB': 'corruption', 'Corruption': 'corruption', 'Log Space': 'dbfiles', 'File Space': 'dbfiles',
  'Availability Groups': 'pgreplication', 'Database State': 'mssqlrisks', 'Custom Checks': 'custom' };
// DBA Dash's column order (Checks/Summary.Designer.cs Columns.AddRange, under pgvigil's word for DBA Dash Errors)
const ddOrder = ['Instance', 'Memory Dump', 'Corruption', 'Last Good Check DB', 'SQL Agent Alerts', 'Backup FULL', 'Backup DIFF', 'Backup LOG', 'Drive Space',
  'Agent Jobs', 'Is Agent Running', 'Log Shipping', 'Mirroring', 'Availability Groups', 'Log Space', 'File Space', '% Max Size', 'Elastic Pool Storage', 'QS',
  'Custom Checks', 'Collection Errors (24hrs)', 'Snapshot Age', 'DB Mail', 'Identity Columns', 'Database State', 'Service Broker', 'Instance Uptime'];
// the cell texts proof-clickmap's T10 seeded: instance -> column -> text ('x*' = starts with x)
const expectText = JSON.parse(process.env.CLICK_EXPECT || '{}');
const dumpRoot = (process.env.CLICK_DUMP_ROOT || '').split('|');

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async (ms = 15000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^Loading/.test(e.textContent)) && m.children.length > 0 && !!m.querySelector('h2'); })()`);
    if (ok) { await sleep(400); return true; }
    await sleep(150);
  }
  return false;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
const go = async (hash) => { await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + hash }); await sleep(300); return settled(); };
const tabOf = h => { const m = /^#\/([^?]*)/.exec(h ?? ''); return m ? m[1] : ''; };
const paramsOf = h => new URLSearchParams((h ?? '').split('?')[1] ?? '');
// the page now: its tab, its instance, a heading, an error box
const landing = async () => ev(`(() => { const m = document.querySelector('main');
  const err = [...(m?.querySelectorAll('p.error') ?? [])].map(e => e.textContent.slice(0, 160));
  return { hash: location.hash, h2: m?.querySelector('h2')?.textContent?.trim() ?? '', err }; })()`);

const results = [];
let fails = 0;
const record = (r) => { results.push(r); if (r.verdict.startsWith('FAIL')) fails++; };
const verdictFor = (column, engine, tab) => {
  if (tab === 'checks') return 'FAIL lands on Daily checks';
  const m = dbadash[column];
  if (m && m[engine]) return !m[engine].includes(tab) ? `FAIL want ${m[engine].join(' or ')} (DBA Dash: ${m.dd})` : m.diff ? `named difference, argued: ${m.diff} (DBA Dash: ${m.dd})` : 'ok (DBA Dash: ' + m.dd + ')';
  if (m && !m[engine]) return `FAIL a ${column} link on ${engine}: the column has no read there`;
  if (named[column]) return 'named difference: ' + named[column];
  return 'ok (not in DBA Dash\'s map; not Daily checks)';
};

// collect: the links of the Summary now. kind: test (the test grid's name), cell (the instance grid), strip (Needs
// attention), name (the instance grid's instance name), check (an instance Summary's failing check), other
const collect = async () => ev(`(() => {
  const m = document.querySelector('main'); const out = [];
  for (const a of m.querySelectorAll('a[href^="#/"]')) {
    const h = a.getAttribute('href'); const lab = a.getAttribute('aria-label') ?? '';
    let kind = 'other', column = '';
    if (a.closest('.attention')) kind = 'strip';
    else if (a.classList.contains('cell-link') && /[?&]i=/.test(h)) { kind = 'cell'; column = lab.split(':')[0]; }
    else if (a.classList.contains('cell-link')) { kind = 'test'; column = a.textContent.trim(); }
    else if (a.closest('td') && /^#\\/summary\\?/.test(h) && /[?&]i=/.test(h)) kind = 'name';
    else if (a.closest('.checks-box')) { kind = 'check'; column = a.textContent.trim(); }
    const tr = a.closest('tr'); const inst = tr ? (tr.querySelector('td a[href*="summary?i="]')?.textContent ?? '') : '';
    out.push({ href: h, kind, column, text: (a.getAttribute('data-text') ?? a.textContent).trim().slice(0, 60), inst });
  }
  const buttons = [...m.querySelectorAll('button.cell-link')].filter(b => /show the instances where it is a warning or a critical/.test(b.getAttribute('aria-label') ?? '')).map(b => b.textContent.trim());
  return { links: out, buttons };
})()`);

const findLink = (href, column) => `[...document.querySelectorAll('main a')].find(x => x.getAttribute('href') === ${JSON.stringify(href)}${column ? ` && (x.getAttribute('aria-label') ?? '').startsWith(${JSON.stringify(column + ':')})` : ''})`;
const clickHref = async (scopeHash, href, column) => {
  await go(scopeHash);
  const ok = await ev(`(() => { const a = ${findLink(href, column)}; if (!a) return false; a.click(); return true; })()`);
  if (!ok) return { hash: '', h2: '', err: ['the link was not found on a fresh load of the page'] };
  for (let i = 0; i < 40 && (await ev('location.hash')) === '#' + scopeHash.replace(/^#/, ''); i++) await sleep(100);
  await settled();
  return landing();
};

// clickDialog: the cell's click opens the Uptime dialog over the Summary: the address stays, an open dialog names the
// instance and its warning and critical thresholds, in DBA Dash's layout ('Warning:' over its box, Root Threshold Config
// more than 100 px right of Inherit)
const clickDialog = async (scopeHash, href, column, inst) => {
  await go(scopeHash);
  const before = await ev('location.hash');
  const ok = await ev(`(() => { const a = ${findLink(href, column)}; if (!a) return false; a.click(); return true; })()`);
  if (!ok) return { ok: false, why: 'the link was not found on a fresh load of the page' };
  let d = null;
  for (let i = 0; i < 50 && !d; i++) {
    d = await ev(`(() => { const x = document.querySelector('dialog[open]'); if (!x) return null; const t = x.textContent;
      if (!/In force|could not be read/.test(t)) return null;
      const wi = x.querySelector('input[aria-label="Warning (mins)"]'), wl = wi && x.querySelector('label[for="' + wi.id + '"]');
      const inh = [...x.querySelectorAll('label')].find(l => l.textContent.trim() === 'Inherit'), rl = [...x.querySelectorAll('button')].find(b => b.textContent === 'Root Threshold Config');
      return { label: x.getAttribute('aria-label') ?? '', text: t.replace(/\\s+/g, ' ').slice(0, 400), hash: location.hash,
        above: !!(wi && wl) && wl.getBoundingClientRect().bottom <= wi.getBoundingClientRect().top + 2,
        rootRight: !!(inh && rl) && rl.getBoundingClientRect().left - inh.getBoundingClientRect().right > 100 }; })()`);
    if (!d) await sleep(100);
  }
  await ev(`(() => { const x = document.querySelector('dialog[open]'); if (x) { x.close(); x.remove(); } })()`);
  if (!d) return { ok: false, why: 'no dialog opened' };
  const want = inst ? d.label === 'Uptime Threshold Config ' + inst : true;
  const thr = /In force: (?:warning under [0-9.,\u202f\u00a0]+ mins|no warning), (?:critical under [0-9.,\u202f\u00a0]+ mins|no critical)/.test(d.text);
  const parts = ['Inherit', 'Enabled', 'Warning: ', 'Critical: ', ' mins', 'Uptime: ', 'Start Time: ', 'Clear Alert', 'Update'].filter(p => !d.text.includes(p));
  if (parts.length) return { ok: false, why: `DBA Dash's dialog lacks ${parts.join(', ')}: ${d.text.slice(0, 200)}` };
  if (d.hash !== before) return { ok: false, why: `the address changed to ${d.hash}` };
  if (!want) return { ok: false, why: `the dialog is not 'Uptime Threshold Config ${inst}': ${d.label}` };
  if (!thr) return { ok: false, why: `no thresholds in the dialog: ${d.text.slice(0, 160)}` };
  if (!d.above || !d.rootRight) return { ok: false, why: `not DBA Dash's layout: 'Warning:' over its box ${d.above}, Root Threshold Config at the right ${d.rootRight}` };
  return { ok: true, why: d.label, text: d.text };
};

const scopes = [
  { name: 'root', hash: '#/summary' },
  { name: `tag ${tag}`, hash: `#/summary?tag=${encodeURIComponent(tag)}` },
  { name: `PostgreSQL ${pg.name}`, hash: `#/summary?i=${pg.instance_id}`, instance: Number(pg.instance_id) },
  { name: `SQL Server ${ms.name}`, hash: `#/summary?i=${ms.instance_id}`, instance: Number(ms.instance_id) },
];
for (const sc of scopes) {
  if (!(await go(sc.hash))) { record({ scope: sc.name, link: 'the Summary', expected: 'drawn', landed: 'not drawn', verdict: 'FAIL the Summary did not render' }); continue; }
  const { links, buttons } = await collect();
  // every link's target from its href; one click per kind, column and engine (CLICK_ALL: every link)
  const clicked = new Set();
  for (const l of links) {
    const tab = tabOf(l.href), inst = Number(paramsOf(l.href).get('i') ?? sc.instance ?? 0), engine = engineOf.get(inst) ?? '';
    let verdict;
    if (l.kind === 'cell') {
      verdict = verdictFor(l.column, engine, tab);
      const cv = dbadash[l.column]?.cv?.[engine];
      if (cv && paramsOf(l.href).get('cv') !== cv) verdict = `FAIL the ${engine} ${l.column} cell does not open its view (cv=${cv}; its href: ${l.href})`;
    } else if (l.kind === 'test') verdict = tab === 'checks' ? 'FAIL lands on Daily checks' : testWant[l.column] ? (testWant[l.column] === tab ? 'ok (DBA Dash: the test\'s own page)' : `FAIL want ${testWant[l.column]}`) : 'ok (the test\'s own page; not Daily checks)';
    else verdict = tab === 'checks' ? 'FAIL lands on Daily checks' : 'ok';
    const key = `${l.kind}|${l.column}|${engine}`;
    let landed = `${tab} (href)`;
    if (l.kind === 'cell' && dialogColumns.has(l.column)) {
      // the dialog: every Uptime cell is checked against its href only once per engine and scope, by a click
      if (clickAll || !clicked.has(key)) {
        clicked.add(key);
        const got = await clickDialog(sc.hash, l.href, l.column, l.inst || (sc.instance ? (sc.instance === Number(pg.instance_id) ? pg.name : ms.name) : ''));
        landed = got.ok ? `the Uptime dialog over the Summary (${got.why})` : 'no dialog';
        verdict = got.ok ? 'ok (DBA Dash: Instance Uptime -> its threshold dialog)' : `FAIL ${got.why}`;
      } else { landed = 'the Uptime dialog (not clicked: one per engine and scope)'; verdict = 'ok (DBA Dash: Instance Uptime -> its threshold dialog)'; }
      record({ scope: sc.name, kind: l.kind, column: l.column, engine, link: l.text, inst: l.inst, landed, href: l.href, verdict });
      continue;
    }
    if (clickAll || !clicked.has(key)) {
      clicked.add(key);
      const got = await clickHref(sc.hash, l.href, l.kind === 'cell' ? l.column : null);
      const gt = tabOf(got.hash);
      landed = `${gt} (clicked: ${got.h2.slice(0, 50)})`;
      if (gt !== tab) verdict = `FAIL clicked to ${gt}, its href says ${tab}`;
      else if (got.err.length) verdict = `FAIL the landing shows an error: ${got.err[0]}`;
      else if (!got.h2) verdict = 'FAIL the landing drew no page';
    }
    record({ scope: sc.name, kind: l.kind, column: l.column, engine, link: l.text, inst: l.inst, landed, href: l.href, verdict });
  }
  // a test without a page of its own filters the instance grid in place: the address stays on the Summary
  for (const b of buttons.slice(0, clickAll ? buttons.length : 3)) {
    await go(sc.hash);
    await ev(`(() => { const x = [...document.querySelectorAll('main button.cell-link')].find(e => e.textContent.trim() === ${JSON.stringify(b)}); x?.click(); })()`);
    await sleep(500);
    const h = await ev('location.hash');
    record({ scope: sc.name, kind: 'test-filter', column: b, engine: '', link: b, landed: tabOf(h), verdict: tabOf(h) === 'summary' ? 'ok (filters the instance grid; DBA Dash: the test\'s instances)' : `FAIL left the Summary for ${tabOf(h)}` });
  }
  // the tree's Storage node: its name opens the folder's first page, Drives (DBA Dash: Storage -> Drives); under an
  // instance the node shows once the instance's node is open: its caret is clicked first
  let caret = true;
  if (sc.instance) {
    await go(sc.hash);
    caret = await ev(`(() => { const b = [...document.querySelectorAll('#tree button.caret')].find(x => x.dataset.key === 'i${sc.instance}'); if (b && b.getAttribute('aria-expanded') !== 'true') b.click(); return !!b; })()`);
    await sleep(600);
  }
  const treeHref = await ev(`(() => { const want = ${JSON.stringify(sc.instance ? `i=${sc.instance}` : '')};
    const a = [...document.querySelectorAll('#tree a')].find(x => x.textContent.trim() === 'Storage' && (want ? x.getAttribute('href').includes(want) : !/[?&]i=/.test(x.getAttribute('href'))));
    return a ? a.getAttribute('href') : null; })()`);
  if (!treeHref) {
    // an instance's folders show once its node is open: open it by its own name in the tree
    record({ scope: sc.name, kind: 'tree', column: 'Storage', engine: '', link: 'tree Storage', landed: 'no Storage node with a link in the tree on this page', verdict: caret ? 'FAIL the tree has no Storage link' + (sc.instance ? ' under the instance after its node was opened' : '') : 'not shown: the instance\'s node sits in a closed folder of the tree on this page' });
  } else {
    if (!sc.instance) await go(sc.hash);
    await ev(`(() => { const a = [...document.querySelectorAll('#tree a')].find(x => x.getAttribute('href') === ${JSON.stringify(treeHref)}); a?.click(); })()`);
    await sleep(500); await settled();
    const got = await landing();
    record({ scope: sc.name, kind: 'tree', column: 'Storage', engine: '', link: 'tree Storage', landed: `${tabOf(got.hash)} (${got.h2.slice(0, 40)})`, verdict: tabOf(got.hash) === 'drives' && !got.err.length ? 'ok (DBA Dash: Storage -> Drives)' : `FAIL want drives, got ${tabOf(got.hash)} ${got.err[0] ?? ''}` });
  }
}

// every tab of the Storage folder at each scope: drawn, no error box
// S: the Summary's shape (task P08), at the root: DBA Dash's two grids (headers, the test names' fill and order, the
// instance grid's column order, the cells that are text, the texts T10 seeded), its toolbar and Refresh Time, the
// Options menu (Memory Dumps, Instance Uptime, Test Summary Max Height %) and the two threshold dialogs
const shape = (column, landed, good, why) => record({ scope: 'root', kind: 'shape', column, engine: '', link: column, landed, verdict: good ? `ok (${why})` : `FAIL ${why}` });
const clickTb = label => ev(`(() => { const b = [...document.querySelectorAll('.summary-toolbar button')].find(x => x.textContent.trim() === ${JSON.stringify(label)}); if (!b) return false; b.click(); return true; })()`);
const menuItems = () => ev(`[...document.querySelectorAll('div.menu button[role="menuitem"]')].map(b => b.textContent)`);
const clickItem = label => ev(`(() => { const b = [...document.querySelectorAll('div.menu button[role="menuitem"]')].find(x => x.textContent.startsWith(${JSON.stringify(label)}) || x.textContent.endsWith(' ' + ${JSON.stringify(label)})); if (!b) return false; b.click(); return true; })()`);
const openDialog = async () => {
  for (let i = 0; i < 50; i++) {
    const d = await ev(`(() => { const x = document.querySelector('dialog[open]'); if (!x || !/In force|Set on the root|The default|could not be read/.test(x.textContent)) return null;
      const v = s => x.querySelector('input[aria-label="' + s + '"]');
      return { label: x.getAttribute('aria-label'), text: x.textContent.replace(/ +/g, ' ').slice(0, 600), crit: v('Critical Threshold (Hrs)')?.value ?? null, warn: v('Warning Threshold (Hrs)')?.value ?? null,
        inheritDisabled: x.querySelector('input[type=checkbox]')?.disabled ?? null, inheritOn: x.querySelector('input[type=checkbox]')?.checked ?? null,
        warnEditable: (() => { const w = x.querySelector('input[aria-label="Warning (mins)"]'); return !!w && !w.disabled && !w.closest('fieldset:disabled'); })(),
        boxRight: (() => { const b = v('Warning Threshold (Hrs)'), c = x.querySelector('input[aria-label="Warning Threshold (Hrs): judged"]'); return !!(b && c) && c.getBoundingClientRect().left >= b.getBoundingClientRect().right; })(),
        ackLeft: (() => { const b = v('Warning Threshold (Hrs)'), l = b && x.querySelector('label[for="' + b.id + '"]'), a = [...x.querySelectorAll('button')].find(y => y.textContent === 'Acknowledge'); return !!(l && a) && Math.abs(a.getBoundingClientRect().left - l.getBoundingClientRect().left) <= 2; })() }; })()`);
    if (d) return d;
    await sleep(100);
  }
  return null;
};
// the words appear in this order in the text (DBA Dash's tab order)
const wordsInOrder = (t, words) => words.map(w => t.indexOf(w)).every((p, i, a) => p >= 0 && (i === 0 || p > a[i - 1]));
const closeDialog = () => ev(`(() => { const x = document.querySelector('dialog[open]'); if (x) { x.close(); x.remove(); } })()`);
await ev(`(() => { try { localStorage.removeItem('pgvigil.summaryTestsMaxPct'); localStorage.removeItem('pgvigil.summaryShowTests'); localStorage.removeItem('pgvigil.summaryFocus'); sessionStorage.removeItem('pgvigil.summaryPick'); } catch (e) {} })()`);
if (!(await go('#/summary'))) shape('the Summary', 'not drawn', false, 'the Summary did not render');
else {
  const sh = await ev(`(() => {
    const m = document.querySelector('main');
    const head = t => t ? [...t.querySelectorAll('thead tr:first-child th')].map(th => (th.firstChild && th.firstChild.nodeType === 3 ? th.firstChild.nodeValue : th.textContent).trim()) : [];
    const tests = m.querySelector('.tests table.grid'), inst = m.querySelector('.summary-instances table.grid');
    const testRows = tests ? [...tests.querySelectorAll('tbody tr')].map(tr => { const td = [...tr.children]; return { name: td[0].textContent.trim(), cls: td[0].className, n: td.slice(1, 6).map(x => Number(x.textContent.trim())) }; }) : [];
    const ih = head(inst), cells = {};
    if (inst) for (const tr of inst.querySelectorAll('tbody tr')) {
      const tds = [...tr.children], o = {};
      ih.forEach((h, i) => { if (tds[i]) o[h] = { text: tds[i].textContent.trim(), link: !!tds[i].querySelector('a'), cls: tds[i].className }; });
      cells[o.Instance ? o.Instance.text : ''] = o;
    }
    const plain = ${JSON.stringify(plainColumns)};
    const plainLinks = [...m.querySelectorAll('a.cell-link')].map(a => (a.getAttribute('aria-label') ?? '').split(':')[0]).filter(c => plain.includes(c));
    const tb = m.querySelector('.summary-toolbar'), rt = tb && tb.querySelector('.refresh-time'), icon = rt && rt.querySelector('[role="img"]'), upper = m.querySelector('.tests');
    return { th: head(tests), ih, testRows, cells, plainLinks, buttons: tb ? [...tb.querySelectorAll('button')].map(b => b.textContent.trim()) : [],
      rt: rt ? rt.textContent : '', icon: icon ? icon.getAttribute('aria-label') : '', maxH: upper ? upper.style.maxHeight : '', upperHidden: upper ? upper.hidden : null };
  })()`);
  const wantTh = ['Test', 'Instance Count OK', 'Instance Count Warning', 'Instance Count Critical', 'Instance Count N/A', 'Instance Count Acknowledged'];
  shape('test grid headers', sh.th.join(' | '), sh.th.join('|') === wantTh.join('|'), sh.th.join('|') === wantTh.join('|') ? 'DBA Dash\'s six' : `want ${wantTh.join(' | ')}`);
  const names = sh.testRows.map(t => t.name), sorted = [...names].sort((x, y) => x.localeCompare(y));
  shape('test order', `${names.length} tests`, names.length > 0 && names.join('|') === sorted.join('|'), names.length ? 'by the test\'s name, as DBA Dash sorts them' : 'no test listed');
  const fillOf = n => n[2] ? 'crit' : n[1] ? 'warn' : n[0] ? 'ok' : n[4] ? 'none ack' : 'none';
  const badFill = sh.testRows.filter(t => !t.cls.split(' ').includes('status') || !(' ' + t.cls + ' ').includes(' ' + fillOf(t.n) + ' '));
  shape('test name fill', `${sh.testRows.length - badFill.length} of ${sh.testRows.length} filled with the worst count`, !badFill.length && sh.testRows.length > 0,
    badFill.length ? 'not filled with the worst count: ' + badFill.map(t => `${t.name} (${t.cls}; ${t.n.join('/')})`).slice(0, 4).join(', ') : 'DBA Dash\'s DgvTests_RowsAdded');
  const hidden = sh.testRows.filter(t => t.n[0] + t.n[1] + t.n[2] === 0);
  shape('tests listed', `${sh.testRows.length} tests`, !hidden.length, hidden.length ? 'listed with no OK, warning or critical instance: ' + hidden.map(t => t.name).join(', ') : 'each with an OK, warning or critical instance (DBA Dash\'s TestRowFilter)');
  const pos = sh.ih.map(h => ddOrder.indexOf(h)), dd = pos.filter(x => x >= 0), firstOwn = pos.findIndex(x => x < 0);
  const inOrder = sh.ih[0] === 'Instance' && dd.every((x, i) => i === 0 || x > dd[i - 1]) && (firstOwn < 0 || pos.slice(firstOwn).every(x => x < 0));
  shape('instance grid columns', sh.ih.slice(0, 26).join(' | '), inOrder, inOrder ? `Instance, ${dd.length - 1} of DBA Dash's columns in its order, then pgvigil's` : 'not in DBA Dash\'s order');
  shape('plain cells', sh.plainLinks.length ? sh.plainLinks.join(', ') : 'no link', !sh.plainLinks.length, sh.plainLinks.length ? 'a link where DBA Dash\'s cell is text' : 'Memory Dump, Is Agent Running and DB Mail are text, as DBA Dash\'s');
  for (const [inst, want] of Object.entries(expectText)) for (const [col, text] of Object.entries(want)) {
    const got = sh.cells[inst] && sh.cells[inst][col];
    const good = !!got && (text.endsWith('*') ? got.text.startsWith(text.slice(0, -1)) : got.text === text);
    shape(`${col} text`, `${inst}: ${got ? got.text : 'no cell'}`, good, good ? `DBA Dash's text '${text}'` : `want '${text}'`);
  }
  if (expectText['demo-onprem-sql01']?.['Instance Uptime']) {
    const t = sh.testRows.find(x => x.name === 'Instance Uptime');
    shape('Instance Uptime acknowledged', t ? t.n.join('/') : 'no row', !!t && t.n[4] >= 1, t && t.n[4] >= 1 ? 'counted under Instance Count Acknowledged' : 'the acknowledged cell is not counted');
  }
  const tbWant = ['Refresh', 'View', 'Options', 'Clear Filter'].filter(b => !sh.buttons.includes(b));
  shape('toolbar', sh.buttons.join(', '), !tbWant.length, tbWant.length ? 'lacks ' + tbWant.join(', ') : 'Refresh, View, Options, Clear Filter');
  shape('Refresh Time', `${sh.rt.trim()} [${sh.icon}]`, sh.rt.startsWith('Refresh Time: ') && sh.icon === 'current', 'DBA Dash\'s Refresh Time with its OK tick');
  shape('Test Summary Max Height %', sh.maxH, sh.maxH === '70vh' && sh.upperHidden === false, 'the test pane at 70 % by default');
  // Options and its three sub-menus
  await clickTb('Options'); await sleep(200);
  const opt = await menuItems();
  const optWant = ['Memory Dumps', 'Instance Uptime', 'Test Summary Max Height %'];
  shape('Options menu', opt.join(' | '), optWant.every((w, i) => (opt[i] ?? '').startsWith(w)) && opt.length === 3, 'DBA Dash\'s three');
  await clickItem('Test Summary Max Height %'); await sleep(200);
  const pcts = await menuItems();
  const pctOk = pcts.length === 9 && pcts.some(x => x.includes('70%') && x !== '70%') && ['10%', '50%', '90%'].every(x => pcts.some(y => y.endsWith(x)));
  await clickItem('40%'); await sleep(200);
  const h40 = await ev(`document.querySelector('main .tests').style.maxHeight`);
  shape('Test Summary Max Height % menu', `${pcts.join(' ')}; 40% -> ${h40}`, pctOk && h40 === '40vh', '10% ... 90%, 70% ticked; 40% sizes the pane');
  await ev(`(() => { try { localStorage.removeItem('pgvigil.summaryTestsMaxPct'); } catch (e) {} })()`);
  await clickTb('Options'); await sleep(200); await clickItem('Memory Dumps'); await sleep(200);
  const dm = await menuItems();
  await clickItem('Configure Thresholds');
  const dd1 = await openDialog(); await closeDialog();
  const dumpOk = !!dd1 && dd1.label === 'Memory Dump Thresholds' && (dumpRoot.length < 2 || (Number(dd1.crit) === Number(dumpRoot[0]) && Number(dd1.warn) === Number(dumpRoot[1])))
    && dd1.boxRight && dd1.ackLeft && wordsInOrder(dd1.text, ['Warning Threshold (Hrs)', 'Critical Threshold (Hrs)', 'Acknowledge', 'Clear', 'Cancel', 'Update']);
  shape('Memory Dump Thresholds', dd1 ? `${dm.join(' | ')}; ${dd1.label}: critical ${dd1.crit}, warning ${dd1.warn}` : 'no dialog', dumpOk && dm.join('|') === 'Acknowledge Dumps|Configure Thresholds',
    dumpOk ? 'Memory Dumps > Acknowledge Dumps / Configure Thresholds; the root threshold shown; DBA Dash\'s order: Warning, Critical (each box then its check box), Acknowledge (under the labels), Clear, Cancel, Update'
      : `want the root ${dumpRoot.join(' / ')} in DBA Dash's order (check box after its box ${dd1?.boxRight}, Acknowledge under the Warning label ${dd1?.ackLeft}): ${dd1 ? dd1.text.slice(0, 240) : ''}`);
  await clickTb('Options'); await sleep(200); await clickItem('Instance Uptime'); await sleep(200);
  const um = await menuItems();
  await clickItem('Configure Thresholds');
  const ud = await openDialog(); await closeDialog();
  shape('Uptime Threshold Config (root)', ud ? `${um.join(' | ')}; ${ud.label}; Inherit ${ud.inheritOn ? 'on' : 'off'}${ud.inheritDisabled ? ' (disabled)' : ''}, Warning box ${ud.warnEditable ? 'editable' : 'disabled'}` : 'no dialog', !!ud && ud.label === 'Uptime Threshold Config (root)' && ud.inheritDisabled === true && ud.inheritOn === false && ud.warnEditable === true && um.join('|') === 'Acknowledge Uptime|Configure Thresholds' && ud.text.includes('Clear ALL Alerts'),
    'Instance Uptime > Acknowledge Uptime / Configure Thresholds; the root\'s dialog, Inherit off and disabled, its Warning box editable, Clear ALL Alerts');
  await clickTb('View'); await sleep(200);
  const vm = await menuItems(); await ev(`document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))`);
  shape('View menu', vm.join(' | '), vm.length === 2 && vm[0].endsWith('Focused View') && vm[1].endsWith('Show Test Summary') && vm[1] !== 'Show Test Summary', 'Focused View, Show Test Summary (ticked)');
}

const storageScopes = [
  { name: 'root', q: '' }, { name: `tag ${tag}`, q: `?tag=${encodeURIComponent(tag)}` },
  { name: `PostgreSQL ${pg.name}`, q: `?i=${pg.instance_id}` }, { name: `SQL Server ${ms.name}`, q: `?i=${ms.instance_id}` },
];
for (const s of storageScopes) {
  await go(`#/drives${s.q}`);
  const tabs = await ev(`[...document.querySelectorAll('#tabs a')].map(a => [a.getAttribute('href'), a.textContent.trim()])`);
  for (const [h, label] of tabs) {
    await go(h);
    const got = await landing();
    const ok = tabOf(got.hash) === tabOf(h) && got.h2 && !got.err.length;
    record({ scope: s.name, kind: 'storage-tab', column: label, engine: '', link: label, landed: `${tabOf(got.hash)} (${got.h2.slice(0, 40)})`, verdict: ok ? 'ok' : `FAIL ${got.err[0] ?? 'not drawn'}` });
  }
}

// a drive's Files link (task 176b, DBA Dash's): on an instance's Drives page every drive's link opens Files with that
// drive, and the grid holds that drive's files only (the instance's data directory, WAL or tablespaces on PostgreSQL)
const filesSeen = new Map();
for (const s of storageScopes.slice(2)) {
  await go(`#/drives${s.q}`);
  const fl = await ev(`[...document.querySelectorAll('main a')].filter(a => (a.getAttribute('aria-label') ?? '').startsWith('Files on ')).map(a => [a.getAttribute('href'), a.getAttribute('aria-label')])`);
  if (!fl.length) record({ scope: s.name, kind: 'drive-files', column: 'Files', engine: '', link: 'Files', landed: 'no Files link', verdict: 'FAIL the Drives page has no drive Files link' });
  for (const [h, lab] of fl) {
    const drive = paramsOf(h).get('drive');
    await go(h);
    const got = await landing();
    const cells = await ev(`(() => { const t = document.querySelector('main table.grid'); if (!t) return null; const hs = [...t.querySelectorAll('thead tr:first-child th')].map(x => x.textContent.trim());
      const j = hs.findIndex(x => x.startsWith('drive')); if (j < 0) return { j }; return { j, drives: [...t.querySelectorAll('tbody tr')].map(tr => tr.children[j]?.textContent.trim() ?? '') }; })()`);
    const all = cells && cells.drives ? cells.drives : [];
    // a drive that holds no file draws the empty line, no grid (each instance must still list a file on some drive, below)
    const empty = cells == null && await ev(`!!document.querySelector('main p.empty')`);
    const okL = tabOf(got.hash) === 'dbfiles' && drive && got.h2 === `Files on ${drive}` && !got.err.length && (empty || (cells != null && cells.j >= 0 && all.every(d => d === drive)));
    filesSeen.set(s.name, (filesSeen.get(s.name) ?? 0) + all.length);
    record({ scope: s.name, kind: 'drive-files', column: 'Files', engine: '', link: lab, landed: `${tabOf(got.hash)} (${got.h2.slice(0, 40)}; ${all.length} file(s))`,
      href: h, verdict: okL ? `ok (DBA Dash: a drive's Files: ${all.length} file(s), each on ${drive})` : `FAIL ${got.err[0] ?? ''} want Files on ${drive}, got ${tabOf(got.hash)} '${got.h2}' with drives [${[...new Set(all)].join(', ')}]` });
  }
}

// an instance whose drives' Files pages listed no file at all has proven nothing
for (const s of storageScopes.slice(2)) if (!filesSeen.get(s.name)) record({ scope: s.name, kind: 'drive-files', column: 'Files', engine: '', link: 'every drive', landed: 'no file listed on any drive', verdict: 'FAIL no drive of the instance lists a file' });

// the table: one line per kind / column / engine / scope (the clicked one; the hrefs of the rest checked)
const seen = new Map();
for (const r of results) {
  const k = `${r.scope}|${r.kind}|${r.column}|${r.engine}|${r.verdict.startsWith('FAIL') ? r.href ?? r.link : ''}`;
  const e = seen.get(k); if (e) e.n++; else seen.set(k, { ...r, n: 1 });
}
for (const r of seen.values()) console.log(`${r.verdict.startsWith('FAIL') ? 'FAIL' : 'ok  '} | ${r.scope} | ${r.kind} | ${r.column || '-'} | ${r.engine || '-'} | ${r.n} link(s) | ${r.landed} | ${r.verdict}`);
if (outPath) fs.writeFileSync(outPath, JSON.stringify({ tag, pg: pg.name, ms: ms.name, results }, null, 1));
const byKind = k => results.filter(r => r.kind === k).length;
console.log(`links: ${results.length} (${byKind('cell')} instance-grid cells, ${byKind('shape')} Summary shape checks, ${byKind('test')} test names, ${byKind('test-filter')} test filters, ${byKind('strip')} Needs attention, ${byKind('name')} instance names, ${byKind('check')} failing checks, ${byKind('other')} other, ${byKind('tree')} tree nodes, ${byKind('storage-tab')} Storage tabs, ${byKind('drive-files')} drive Files links); ${fails} FAIL`);
ws.close();
process.exit(fails ? 1 : 0);
