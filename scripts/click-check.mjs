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

// DBA Dash's map, as pgvigil's columns and tests name it: column (or test) -> the tab it lands on per engine, and DBA
// Dash's own target. A column DBA Dash does not have is checked against the never-Daily-checks rule alone.
const dbadash = {
  Disk:        { postgres: ['drives'], sqlserver: ['drives'], dd: 'Drive Space -> Storage > Drives' },
  Storage:     { postgres: ['drives'], sqlserver: ['dbfiles'], dd: 'Drive Space -> Storage > Drives (PostgreSQL: volume checks); Log Space -> Storage > Files (SQL Server: file and log checks)' },
  Backups:     { postgres: ['backups'], sqlserver: ['mssqlbackups'], dd: 'Backup FULL / LOG -> HA/DR > Backups' },
  Jobs:        { postgres: ['jobsreport', 'jobs'], sqlserver: ['mssqljobs'], dd: 'Agent Jobs -> Jobs > Job Status' },
  Agent:       { sqlserver: ['mssqljobs'], dd: 'Is Agent Running -> Jobs' },
  Corruption:  { postgres: ['corruption'], dd: 'Last Good Check DB -> Checks > Last Good CheckDB' },
  // task 176b: the four the 176 map named as differences, now where DBA Dash's Summary opens them
  Collection:  { postgres: ['collectiondates'], sqlserver: ['collectiondates'], dd: 'Snapshot Age -> Checks > Collection Dates' },
  'Database state': { postgres: ['pgdboptions'], sqlserver: ['mssqlchecks'], dd: 'Database State -> Configuration > DB Options (SQL Server: the Checks page\'s Database options view)' },
  QS:          { postgres: ['pgstate'], sqlserver: ['mssqlqs'], dd: 'QS -> Configuration > QS (PostgreSQL: the statement store on Server state)' },
};
// the differences named (pgvigil lands elsewhere; the lead's call): column -> words
const named = {};
// Uptime: DBA Dash's Summary opens the Instance Uptime threshold dialog over the grid; the click must too
const dialogColumns = new Set(['Uptime']);
// the test grid's names that open a page (pages.ts rootTabOf) and DBA Dash's target where it has one
const testWant = { Disk: 'drives', Storage: 'drives', Backups: 'backups', Jobs: 'jobs' };

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
  if (m && m[engine]) return m[engine].includes(tab) ? 'ok (DBA Dash: ' + m.dd + ')' : `FAIL want ${m[engine].join(' or ')} (DBA Dash: ${m.dd})`;
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
// instance and its warning and critical thresholds
const clickDialog = async (scopeHash, href, column, inst) => {
  await go(scopeHash);
  const before = await ev('location.hash');
  const ok = await ev(`(() => { const a = ${findLink(href, column)}; if (!a) return false; a.click(); return true; })()`);
  if (!ok) return { ok: false, why: 'the link was not found on a fresh load of the page' };
  let d = null;
  for (let i = 0; i < 50 && !d; i++) {
    d = await ev(`(() => { const x = document.querySelector('dialog[open]'); if (!x) return null; const t = x.textContent;
      if (!/In force|could not be read/.test(t)) return null;
      return { label: x.getAttribute('aria-label') ?? '', text: t.replace(/\\s+/g, ' ').slice(0, 400), hash: location.hash }; })()`);
    if (!d) await sleep(100);
  }
  await ev(`(() => { const x = document.querySelector('dialog[open]'); if (x) { x.close(); x.remove(); } })()`);
  if (!d) return { ok: false, why: 'no dialog opened' };
  const want = inst ? d.label.includes(inst) && d.text.includes(inst) : true;
  const thr = /In force: warning under (?:[0-9.,\u202f\u00a0]+ hours|not judged), critical under (?:[0-9.,\u202f\u00a0]+ hours|not judged)/.test(d.text);
  if (d.hash !== before) return { ok: false, why: `the address changed to ${d.hash}` };
  if (!want) return { ok: false, why: `the dialog does not name ${inst}: ${d.label}` };
  if (!thr) return { ok: false, why: `no thresholds in the dialog: ${d.text.slice(0, 160)}` };
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
      if (l.column === 'Database state' && engine === 'sqlserver' && paramsOf(l.href).get('cv') !== 'databases') verdict = 'FAIL the SQL Server Database state cell does not open the Database options view (cv=databases)';
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
console.log(`links: ${results.length} (${byKind('cell')} instance-grid cells, ${byKind('test')} test names, ${byKind('test-filter')} test filters, ${byKind('strip')} Needs attention, ${byKind('name')} instance names, ${byKind('check')} failing checks, ${byKind('other')} other, ${byKind('tree')} tree nodes, ${byKind('storage-tab')} Storage tabs, ${byKind('drive-files')} drive Files links); ${fails} FAIL`);
ws.close();
process.exit(fails ? 1 : 0);
