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
// ... and that a TOP-LEVEL tag folder carries: under ui.group_by [k, ...] a 'k:<v>' (a bare
// value when k is 'tag'), else any written tag - a tag the root only keeps has no folder of its own to click
const groupBy = (await (await fetch(U + 'api/tags')).json()).group_by ?? [];
const topLevel = t => !groupBy.length || (groupBy[0] === 'tag' ? !String(t).includes(':') : String(t).toLowerCase().startsWith(groupBy[0].toLowerCase() + ':'));
const tag = [...tagCount.entries()].filter(([t, e]) => e.n < insts.length && e.engines.size === 2 && topLevel(t)).sort((a, b) => b[1].n - a[1].n || (a[0] < b[0] ? -1 : 1))[0]?.[0];
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
  // task 383: SQL Server's three HA cells land on the HA/DR folder's pages in DBA Dash's shape (the instance's own tab)
  'Log Shipping':        { postgres: ['pgbackups'], sqlserver: ['mssqllogshipping'], dd: 'Log Shipping -> HA/DR > Log Shipping' },
  'Mirroring':           { sqlserver: ['mssqlmirroring'], dd: 'Mirroring -> HA/DR > Mirroring' },
  'Availability Groups': { postgres: ['replication'], sqlserver: ['mssqlag'], dd: 'Availability Groups -> HA/DR > Availability Groups' },
  'Log Space':           { sqlserver: ['dbfiles'], dd: 'Log Space -> Storage > Files' },
  'File Space':          { sqlserver: ['dbfiles'], dd: 'File Space -> Storage > Files' },
  // PostgreSQL's own names of five of DBA Dash's columns (B7 DONE-3, the pgLabel item: web/src/fleet.ts labelOf): a
  // PostgreSQL row's cell is named so (its aria-label) on every scope, and a scope with no SQL Server names its column so
  'Crash restarts':      { postgres: ['pgstate'], dd: 'Memory Dump (PostgreSQL: its crash restarts) -> the instance\'s Server state' },
  'Last amcheck':        { postgres: ['corruption'], dd: 'Last Good Check DB (PostgreSQL: amcheck) -> the Corruption page' },
  'WAL archive':         { postgres: ['backups'], dd: 'Backup LOG (PostgreSQL: the WAL archiver) -> HA/DR > Backups' },
  'Jobs':                { postgres: ['jobsreport', 'jobs'], dd: 'Agent Jobs (PostgreSQL: pg_cron and pgAgent) -> Jobs > Job Status' },
  'Replication':         { postgres: ['replication'], dd: 'Availability Groups (PostgreSQL: replication) -> HA/DR' },
  // QS is SQL Server's Query Store alone (a QS link on a PostgreSQL instance FAILS: 'the column has no read there');
  // PostgreSQL's statement store has its own column, which SQL Server has no cell in
  'QS':                  { sqlserver: ['mssqlqs'], dd: 'QS -> Configuration > QS' },
  'pg_stat_statements':  { postgres: ['pgstate'], dd: 'no DBA Dash column: PostgreSQL has no Query Store, its statement store is on Server state' },
  // a SQL Server row's cell since ST6b (its custom findings, DBA Dash's custom check rows among them)
  'Custom Checks':       { postgres: ['custom'], sqlserver: ['custom'], dd: 'Custom Checks -> Checks > Custom Checks' },
  'Snapshot Age':        { postgres: ['collectiondates'], sqlserver: ['collectiondates'], dd: 'Snapshot Age -> Checks > Collection Dates' },
  'Identity Columns':    { sqlserver: ['mssqlchecks'], cv: { sqlserver: 'identity' }, dd: 'Identity Columns -> Checks > Identity Columns' },
  'Database State':      { postgres: ['pgdboptions'], sqlserver: ['mssqlchecks'], cv: { sqlserver: 'databases' }, dd: 'Database State -> Configuration > DB Options' },
  '% Max Size':          { sqlserver: ['dbfiles'], dd: '% Max Size -> Storage > Files' },
  // DBA Dash's text cells (no tab): pgvigil links them where their Needs attention reason links - the instance's Summary,
  // onto the Server card's row of the check (row=), or the check's page - every status text answers a click
  'Memory Dump':         { sqlserver: ['summary'], row: { sqlserver: 'dumps' }, dd: 'Memory Dump -> DBA Dash: text; pgvigil: the instance Summary\'s Server card row' },
  'DB Mail':             { sqlserver: ['summary'], row: { sqlserver: 'dbmail' }, dd: 'DB Mail -> DBA Dash: text; pgvigil: the instance Summary\'s Server card row' },
  'Is Agent Running':    { sqlserver: ['mssqljobs'], dd: 'Is Agent Running -> DBA Dash: text; pgvigil: the Jobs page, as its reason' },
  // the landing checked, the difference from DBA Dash's page named in the verdict (argued in the report)
  'Collection Health': { postgres: ['collectionhealth'], sqlserver: ['collectionhealth'], dd: 'DBA Dash 4.25.0 Collection Health -> Checks > Collection Health (4.24.1: Errors (24hrs) -> DBA Dash ErrorLog, P13\'s)' },
};
// the differences named (pgvigil lands elsewhere, argued in the report): column -> words
const named = {};
// DBA Dash's text cells (Checks/Summary.cs: no tab, no dialog): pgvigil's are links wherever they hold a text
const plainColumns = ['Memory Dump', 'Crash restarts', 'Is Agent Running', 'DB Mail'];
// Instance Uptime: DBA Dash's Summary opens the Instance Uptime threshold dialog over the grid; the click must too
const dialogColumns = new Set(['Instance Uptime']);
// the status filter a link's page must open on (fleet.ts mssqlStatus): % Max Size opens Files on the files the cell
// counts - its critical and warning ones - whatever filter the page has stored
const statusWant = { '% Max Size': 'critical,warning' };
// the test grid's names that open a page (pages.ts rootTabOf) and DBA Dash's target where it has one
const testWant = { 'Drive Space': 'drives', 'Backup FULL': 'backups', 'Backup LOG': 'backups', 'Agent Jobs': 'jobs', 'Snapshot Age': 'collectiondates',
  'Collection Health': 'collectionhealth', 'Last Good Check DB': 'corruption', 'Corruption': 'corruption', 'Log Space': 'dbfiles', 'File Space': 'dbfiles',
  // task 383: a scope with SQL Server names this column 'Availability Groups' (a PostgreSQL-only one 'Replication', below)
  '% Max Size': 'dbfiles', 'Availability Groups': 'mssqlag', 'Mirroring': 'mssqlmirroring', 'Log Shipping': 'mssqllogshipping', 'Database State': 'mssqlrisks', 'Custom Checks': 'custom',
  // the same tests under PostgreSQL's names, on a scope with no SQL Server instance (B7 DONE-3)
  'Last amcheck': 'corruption', 'WAL archive': 'backups', 'Jobs': 'jobs', 'Replication': 'pgreplication' };
// DBA Dash's column order (Checks/Summary.Designer.cs Columns.AddRange, under pgvigil's word for DBA Dash Errors)
const ddOrder = ['Instance', 'Memory Dump', 'Corruption', 'Last Good Check DB', 'SQL Agent Alerts', 'Backup FULL', 'Backup DIFF', 'Backup LOG', 'Drive Space',
  'Agent Jobs', 'Is Agent Running', 'Log Shipping', 'Mirroring', 'Availability Groups', 'Log Space', 'File Space', '% Max Size', 'Elastic Pool Storage', 'QS',
  'Custom Checks', 'Collection Health', 'Snapshot Age', 'DB Mail', 'Identity Columns', 'Database State', 'Service Broker', 'Instance Uptime'];
// the cell texts proof-clickmap's T10 seeded: instance -> column -> text ('x*' = starts with x)
const expectText = JSON.parse(process.env.CLICK_EXPECT || '{}');
const dumpRoot = (process.env.CLICK_DUMP_ROOT || '').split('|');

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
// an async expression needs awaitPromise: without it CDP hands back the pending Promise, serialised as {}
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
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

// TAGTREE (DBA Dash: Main.cs L95-110, a tag folder's own Configuration, Checks, HA/DR, Storage, Jobs, Reports, each over
// that folder's instances only, SQLTreeItem.cs L168-190): the tag folder of `tag` at the tree's top (its name a link that
// carries tag=<tag>) and, inside it, the folder of a group by its caret key 't:<folder path>/<group>', opened when closed;
// the folder name's href and its leaves [text, href], or why there is none
const tagFolder = (group, t = tag) => ev(`(async () => {
  const want = ${JSON.stringify('tag=' + encodeURIComponent(t))};
  const carries = a => ((a.getAttribute('href') || '').split('?')[1] || '').split('&').includes(want);
  const findCaret = () => { const top = [...document.querySelectorAll('#tree .folder')].find(f => [...f.querySelectorAll(':scope > .folder-head a')].some(carries));
    return top ? [...top.querySelectorAll('button.caret')].find(b => /^t:/.test(b.dataset.key || '') && b.dataset.key.endsWith('/' + ${JSON.stringify(group)})) ?? 'none' : null; };
  let c = findCaret();
  if (c === null) return { why: 'no tag folder whose name links ' + want };
  if (c === 'none') return { why: 'the tag folder holds no folder with a caret key t:.../' + ${JSON.stringify(group)} };
  if (c.getAttribute('aria-expanded') !== 'true') { c.click(); await new Promise(r => setTimeout(r, 500)); c = findCaret(); }
  const box = c && c !== 'none' ? c.closest('.tree-node')?.parentElement : null;
  if (!box) return { why: 'the folder was not drawn again after its caret was clicked' };
  return { key: c.dataset.key, name: box.querySelector(':scope > .tree-node a')?.getAttribute('href') ?? null,
    leaves: [...box.querySelectorAll(':scope > div:not(.tree-node) a.inst')].map(a => [a.textContent.trim(), a.getAttribute('href')]) };
})()`, true);
const treeClick = async h => { await ev(`(() => { const a = [...document.querySelectorAll('#tree a')].find(x => x.getAttribute('href') === ${JSON.stringify(h)}); a?.click(); return !!a; })()`); await sleep(500); await settled(); return landing(); };

// PGVIGIL_CLICK_ONLY=noenv: the '(no env)' folder alone. The demo puts an env on
// every instance; proof-clickmap.sh adds instances with no tag after the main map and runs this. Under the demo's
// group_by [env] they are in '(no env)', whose name links ?tag=env: and whose own folders scope the same.
if (process.env.PGVIGIL_CLICK_ONLY === 'noenv') {
  const lines = [];
  const say = (ok, what, how) => lines.push(`${ok ? 'ok  ' : 'FAIL'} | tag env: | tag-tree | ${what} | - | 1 link(s) | ${how}`);
  const none = insts.filter(r => !(Array.isArray(r.tags) ? r.tags : []).some(t => /^env:/i.test(String(t)))).map(r => String(r.name)).sort();
  if (!none.length) say(false, 'instances', 'no instance without an env tag: the row proves nothing');
  else {
    await go('#/summary');
    const st = await tagFolder('storage', 'env:');
    say(!st.why, '(no env) folder', st.why ?? `its Storage folder ${st.key}, leaves: ${(st.leaves ?? []).map(l => l[0]).join(', ')}`);
    const drives = st.leaves?.find(([t]) => t === 'Drives')?.[1];
    if (!drives) say(false, 'Storage', 'no Drives leaf in the (no env) folder\'s own Storage');
    else {
      const got = await treeClick(drives);
      const okD = tabOf(got.hash) === 'drives' && paramsOf(got.hash).get('tag') === 'env:' && !got.err.length;
      say(okD, 'Storage', `${got.hash} (${got.h2.slice(0, 40)}) ${okD ? 'ok (lands on Drives scoped to the instances with no env)' : 'FAIL want drives with tag=env: and no error ' + (got.err[0] ?? '')}`);
    }
    // the folder's Summary lists exactly the instances with no env (fleet.ts inTagScope's '<key>:' rule)
    await go('#/summary?tag=env%3A');
    const listed = (await ev(`[...new Set([...document.querySelectorAll('main a')].map(a => a.textContent.trim()))]`)).filter(n => insts.some(r => String(r.name) === n)).sort();
    const h2 = (await landing()).h2;
    const okS = JSON.stringify(listed) === JSON.stringify(none) && h2.includes('(no env)');
    say(okS, 'Summary', `listed [${listed.join(', ')}], heading '${h2.slice(0, 50)}' ${okS ? "ok (the instances with no env, the heading '(no env)')" : `FAIL want [${none.join(', ')}] and '(no env)' in the heading`}`);
  }
  for (const l of lines) console.log(l);
  const nf = lines.filter(l => l.startsWith('FAIL')).length;
  console.log(`links: ${lines.length} ('(no env)' rows); ${nf} FAIL`);
  ws.close();
  process.exit(nf ? 1 : 0);
}

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
    const stWant = (l.kind === 'cell' && engine === 'sqlserver') || l.kind === 'test' ? statusWant[l.column] : undefined;
    if (stWant && !verdict.startsWith('FAIL') && paramsOf(l.href).get('status') !== stWant) verdict = `FAIL the ${l.column} ${l.kind} does not open its page on its status filter (status=${stWant}; its href: ${l.href})`;
    const rwWant = l.kind === 'cell' ? dbadash[l.column]?.row?.[engine] : undefined;
    if (rwWant && !verdict.startsWith('FAIL') && paramsOf(l.href).get('row') !== rwWant) verdict = `FAIL the ${l.column} cell does not name its Server card row (row=${rwWant}; its href: ${l.href})`;
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
      // a link with a status filter is clicked with the Files page's stored filter on All (the folder page's own
      // default is the filter asked for: without this its row could not fail), taken out again after the read
      if (stWant) await ev(`(() => { for (const k of ['pgvigil.filesStatus.folder', 'pgvigil.filesStatus.instance']) localStorage.setItem(k, 'all'); return true; })()`);
      const got = await clickHref(sc.hash, l.href, l.kind === 'cell' ? l.column : null);
      const gt = tabOf(got.hash);
      landed = `${gt} (clicked: ${got.h2.slice(0, 50)})`;
      if (gt !== tab) verdict = `FAIL clicked to ${gt}, its href says ${tab}`;
      else if (got.err.length) verdict = `FAIL the landing shows an error: ${got.err[0]}`;
      else if (!got.h2) verdict = 'FAIL the landing drew no page';
      else if (stWant && !verdict.startsWith('FAIL')) {
        // the page itself shows the filter the link asked for (the Status select), not its stored one
        const sel = await ev(`document.querySelector('main select#files-status')?.value ?? '(no Status select)'`);
        if (sel !== stWant) verdict = `FAIL the landing's Status filter shows '${sel}', the link asked for '${stWant}'`;
        else landed += `, Status ${sel} over a stored All`;
      }
      if (stWant) await ev(`(() => { for (const k of ['pgvigil.filesStatus.folder', 'pgvigil.filesStatus.instance']) localStorage.removeItem(k); return true; })()`);
      if (rwWant && !verdict.startsWith('FAIL')) {
        // the landing holds the check's Server card row at the top of the view, with the focus (the jump follows the header)
        let at = null;
        for (let i = 0; i < 40 && !(at = await ev(`(() => { const r = document.querySelector('main [data-row="${rwWant}"]'); if (!r || document.activeElement !== r) return null; const b = r.getBoundingClientRect(); return { top: Math.round(b.top), bars: Math.round(document.querySelector('#tabs')?.getBoundingClientRect().bottom ?? 0), vh: innerHeight, addr: location.hash }; })()`)); i++) await sleep(250);
        if (!at) verdict = `FAIL the landing's Server card row '${rwWant}' never took the focus`;
        else if (at.top < at.bars || at.top > at.vh / 3) verdict = `FAIL the row '${rwWant}' is not at the top of the view below the header and tabs (${at.top} px; the bars end at ${at.bars}, the view ${at.vh})`;
        else if (paramsOf(at.addr).get('row')) verdict = `FAIL the address keeps row= after the jump (${at.addr})`;
        else landed += `, the Server card row '${rwWant}' at ${at.top} px, focused`;
      }
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
  // the tag scope: the tag folder's OWN Storage (TAGTREE; the pass's #10), found by its 't:' caret key - its name lands on
  // Drives with tag=<tag> kept (the first 'Storage' without i= is the root's: the fleet's Drives, the tag lost)
  if (!sc.instance && sc.name.startsWith('tag ')) {
    await go(sc.hash);
    const ts = await tagFolder('storage');
    if (!ts.name) record({ scope: sc.name, kind: 'tree', column: 'Storage', engine: '', link: "the tag folder's Storage", landed: ts.why ?? "its Storage folder's name is no link", verdict: "FAIL no Storage folder of the tag folder's own with a link" });
    else {
      const got = await treeClick(ts.name);
      record({ scope: sc.name, kind: 'tree', column: 'Storage', engine: '', link: "the tag folder's Storage", landed: `${got.hash} (${got.h2.slice(0, 40)})`,
        verdict: tabOf(got.hash) === 'drives' && paramsOf(got.hash).get('tag') === tag && !got.err.length ? "ok (DBA Dash: a tag folder's Storage -> Drives; lands with tag= kept, no error - what the page lists is not read here)" : `FAIL want drives with tag=${tag}, got ${got.hash} ${got.err[0] ?? ''}` });
    }
  } else {
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
  }   // the tag scope's own Storage row above
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
    const plainLinks = [];
    for (const [name, o] of Object.entries(cells)) for (const c of plain) if (o[c] && o[c].text && !o[c].link) plainLinks.push(c + ' @ ' + name + ' (' + o[c].text + ')');
    const tb = m.querySelector('.summary-toolbar'), rt = tb && tb.querySelector('.refresh-time'), icon = rt && rt.querySelector('[role="img"]'), upper = m.querySelector('.tests');
    // the View control (views.ts viewControl, D16): its data-view-control attribute, its 'View' prefix only
    // when no button carries the attribute
    const vb = tb && (tb.querySelector('button[data-view-control]') ?? [...tb.querySelectorAll('button')].find(b => b.textContent.trim().startsWith('View')));
    return { th: head(tests), ih, testRows, cells, plainLinks, buttons: tb ? [...tb.querySelectorAll('button')].map(b => b.textContent.trim()) : [],
      view: vb ? { label: vb.textContent.trim(), byAttr: vb.hasAttribute('data-view-control') } : null,
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
  shape('status text cells', sh.plainLinks.length ? sh.plainLinks.join(', ') : 'every one with a text is a link', !sh.plainLinks.length, sh.plainLinks.length ? 'a status text that answers no click' : 'Memory Dump, Crash restarts, Is Agent Running and DB Mail: a link wherever they hold a text');
  for (const [inst, want] of Object.entries(expectText)) for (const [col, text] of Object.entries(want)) {
    const got = sh.cells[inst] && sh.cells[inst][col];
    const good = !!got && (text.endsWith('*') ? got.text.startsWith(text.slice(0, -1)) : got.text === text);
    shape(`${col} text`, `${inst}: ${got ? got.text : 'no cell'}`, good, good ? `DBA Dash's text '${text}'` : `want '${text}'`);
  }
  if (expectText['demo-onprem-sql01']?.['Instance Uptime']) {
    const t = sh.testRows.find(x => x.name === 'Instance Uptime');
    shape('Instance Uptime acknowledged', t ? t.n.join('/') : 'no row', !!t && t.n[4] >= 1, t && t.n[4] >= 1 ? 'counted under Instance Count Acknowledged' : 'the acknowledged cell is not counted');
  }
  // the View control's label is 'View: <the loaded view's name or None>', ' (changed)' after an edit of a loaded view
  const tbWant = ['Refresh', 'Options', 'Clear Filter'].filter(b => !sh.buttons.includes(b));
  const viewLabelOk = !!sh.view && /^View: \S/.test(sh.view.label);
  if (!viewLabelOk) tbWant.splice(1, 0, sh.view ? `View: <a name or None> (its label reads '${sh.view.label}')` : 'View');
  shape('toolbar', sh.buttons.join(', ') + (sh.view ? `; the View control found by ${sh.view.byAttr ? 'data-view-control' : 'its View prefix'}` : ''), !tbWant.length,
    tbWant.length ? 'lacks ' + tbWant.join(', ') : `Refresh, ${sh.view.label}, Options, Clear Filter`);
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
  // DBA Dash's View drop-down (views.ts viewControl, D16): the page's two toggles first, then {None}, the saved views and
  // Save / Save as... / Rename... / Delete...; the menu draws once the saved views are read, so it is waited for (3 s)
  const viewOpened = await ev(`(() => { const t = document.querySelector('.summary-toolbar'); const b = t && (t.querySelector('button[data-view-control]') ?? [...t.querySelectorAll('button')].find(x => x.textContent.trim().startsWith('View'))); if (!b) return false; b.click(); return true; })()`);
  let vm = [];
  for (let i = 0; viewOpened && i < 30 && !vm.length; i++) { await sleep(100); vm = (await menuItems()) ?? []; }
  await ev(`document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))`);
  const vNone = vm.findIndex(x => x.endsWith('{None}')), vSave = vm.findIndex(x => x === 'Save');
  const vmOk = vm.length >= 4 && vm[0].endsWith('Focused View') && vm[1].endsWith('Show Test Summary') && vm[1] !== 'Show Test Summary' && vNone === 2 && vSave > vNone;
  shape('View menu', viewOpened ? (vm.length ? vm.join(' | ').slice(0, 260) : 'the View control opened no menu') : 'no View control', vmOk,
    vmOk ? 'Focused View, Show Test Summary (ticked), then {None} and Save'
      : !viewOpened ? 'no View control to open' : !vm.length ? 'the View control opened no menu'
      : `want Focused View, Show Test Summary (ticked), then {None} (item ${vNone + 1}) and Save after it (item ${vSave + 1})`);
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

// P (task 177 D29): PerformanceMonitor's links and buttons on pgvigil - the instance header's name, the Summary
// row's Silence button (on for an instance the demo's write door carries: its confirm opens; anywhere else it is off -
// aria-disabled, never the disabled attribute - with its reason as visible words it is described by), the calendar's month
// buttons, a day and its drills (each to its page over that UTC day), Show as table, and the Performance page's zoom
// chip (its x back to the range before the zoom), on an instance of each engine
const pm = (scope, column, engine, landed, good, why) => record({ scope, kind: 'pm', column, engine, link: column, landed, verdict: good ? `ok (${why})` : `FAIL ${why}` });
// the own-page finder (in the page): a SQL Server Summary's status text of check KEY (Memory dumps, DB Mail) inside a
// box (the header's reasons, the verdict card's reasons, the Not OK line), marked data-cc-own for the click: every
// '+n more' of the header opened first (a reason past the first six is on the page too), then the text by its
// data-group ('group'), else a text of the box that names the check by its words and sits under no data-group
// ('words': it lost its data-group, so no row here and no twin rule of the walk can find it - the row FAILs it), else,
// where the box draws the band's own items (the header's reasons and the verdict card's: instheader.ts reasonLine,
// verdict.ts L72), KEY listed in the band word's data-groups ('missing': a reason of the band with no text of it in
// the box, whatever its words or element - the row FAILs it); null when the box holds no text of KEY and the band
// does not list it. The words are the product's: the header's column label, the verdict line's phrase (verdict.ts),
// the Not OK name (fleet.ts mssql[2])
const ownWords = { dumps: '^(memory dumps?\\b|the server wrote memory dumps)', dbmail: '^(db mail\\b|database mail\\b|the server cannot send mail)' };
const ownFind = (box, key, band = null) => `(() => { document.querySelectorAll('[data-cc-own]').forEach(e => e.removeAttribute('data-cc-own'));
  for (const m of [...document.querySelectorAll('main .inst-reason button')].filter(b => /^[+]\\d+ more$/.test(b.textContent.trim()))) m.click();
  const mark = (x, how) => { x.setAttribute('data-cc-own', '1'); const a = x.matches('a[href]') ? x : x.querySelector('a[href]'); return { how, link: !!a, text: x.textContent.trim().slice(0, 50) }; };
  for (const b of document.querySelectorAll(${JSON.stringify(box)})) { const x = b.querySelector(${JSON.stringify(`[data-group="${key}"]`)}); if (x) return mark(x, 'group'); }
  const w = new RegExp(${JSON.stringify(ownWords[key])}, 'i');
  for (const b of document.querySelectorAll(${JSON.stringify(box)})) for (const x of b.querySelectorAll('a, span, li')) if (!x.closest('[data-group]') && w.test(x.textContent.trim())) return mark(x, 'words');
  const bw = ${band ? `document.querySelector(${JSON.stringify(band)})` : 'null'};
  if (bw && (bw.getAttribute('data-groups') ?? '').split(' ').includes(${JSON.stringify(key)})) return { how: 'missing', link: false, text: '' };
  return null; })()`;
// the click on the marked text and its landing (in the page); { lost: true } when the mark is gone (the Summary's
// 30 s refresh drew the box again between the find and the click: the row finds it again once)
const ownClick = (key) => `(async () => { const x = document.querySelector('[data-cc-own]'); if (!x || !x.isConnected) return { lost: true };
  const a = x.matches('a[href]') ? x : x.querySelector('a[href]');
  window.scrollTo(0, 0); a.click();
  for (let i = 0; i < 20 && document.activeElement?.getAttribute('data-row') !== ${JSON.stringify(key)}; i++) await new Promise(r => setTimeout(r, 150));
  const r = document.querySelector('main [data-row="${key}"]'), b = r?.getBoundingClientRect();
  return { link: true, text: a.textContent.trim().slice(0, 50), focused: document.activeElement === r && !!r, top: b ? Math.round(b.top) : null, bars: Math.round(document.querySelector('#tabs')?.getBoundingClientRect().bottom ?? 0), vh: innerHeight, addr: location.hash }; })()`;
// the finder's planted self-test: three texts of Memory dumps that lost their data-group (wanted 'words': the row
// FAILs them), other words and another check's key in the same box (wanted null: not seen), a text with its
// data-group (wanted 'group'), a text of Memory dumps that only a '+1 more' draws (wanted 'words': the button is
// opened first), a band that lists dumps over a box whose text of it has other words (wanted 'missing') and the same
// band asked for dbmail, which it does not list (wanted null); planted in a box of its own under main, removed after
const ownPlant = `(() => { const d = document.createElement('div'); d.id = 'ccp'; d.innerHTML =
  '<div class="ccp-h"><span class="reason-text">Memory Dump 3 files warning</span>, <a class="cell-link" data-group="backuplog" href="#/backups">Backup LOG 1 warning</a></div>'
  + '<ul class="ccp-v"><li class="warn"><span class="verdict-text">the server wrote memory dumps (3 files warning)</span></li></ul>'
  + '<p class="ccp-n"><span class="warn">Memory dumps 3 files warning</span></p>'
  + '<p class="ccp-x"><span class="warn">Backup LOG 1 warning</span></p>'
  + '<p class="ccp-g"><a class="warn" data-group="dumps" href="#/summary">Memory dumps 3 files warning</a></p>'
  + '<div class="inst-reason ccp-m">' + ['drives', 'jobs', 'activity', 'backuplog', 'ag', 'filespace'].map(k => '<a class="cell-link" data-group="' + k + '" href="#/summary">' + k + ' 1 warning</a>').join(', ') + ', <button type="button" class="link">+1 more</button></div>'
  + '<span class="ccp-band" data-groups="backuplog dumps"></span>'
  + '<div class="ccp-d"><span class="reason-text">Crash dumps were written (3 files warning)</span></div>';
  const more = d.querySelector('.ccp-m button'); more.addEventListener('click', () => { const t = document.createElement('span'); t.className = 'reason-text'; t.textContent = 'Memory Dump 3 files warning'; more.replaceWith(t); });
  document.querySelector('main').append(d); return true; })()`;
const ownPlants = [['planted header text', '#ccp .ccp-h', 'dumps', null, 'words'], ['planted verdict text', '#ccp .ccp-v', 'dumps', null, 'words'],
  ['planted Not OK text', '#ccp .ccp-n', 'dumps', null, 'words'], ['planted other words', '#ccp .ccp-x', 'dumps', null, null],
  ['planted other check', '#ccp .ccp-h', 'dbmail', null, null], ['planted with its group', '#ccp .ccp-g', 'dumps', null, 'group'],
  ['planted past +1 more', '#ccp .ccp-m', 'dumps', null, 'words'], ['planted band, other words', '#ccp .ccp-d', 'dumps', '#ccp .ccp-band', 'missing'],
  ['planted band without the key', '#ccp .ccp-d', 'dbmail', '#ccp .ccp-band', null]];
let ownTested = false;
{
  if (await go('#/summary')) {
    const sb = await ev(`(() => { const tr = [...document.querySelectorAll('main .summary-instances tbody tr')].find(t => t.querySelector('td')?.textContent.trim() === ${JSON.stringify(pg.name)});
      const b = tr && [...tr.querySelectorAll('button')].find(x => /^(Silence|Unsilence)$/.test(x.textContent));
      if (!b) return null; const was = location.hash; b.click(); const d = document.querySelector('dialog[open]');
      // off = aria-disabled (ui.ts offControl), its reason the visible words it is described by; a click on it does nothing
      const n = b.getAttribute('aria-describedby') ? document.getElementById(b.getAttribute('aria-describedby')) : null;
      const out = { text: b.textContent, aria: b.getAttribute('aria-label'), off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled,
        words: n && n.offsetParent !== null ? n.textContent.trim() : '', dialog: d ? (d.querySelector('h3,h2')?.textContent ?? d.textContent.slice(0, 80)) : '', moved: location.hash !== was };
      if (d) { d.close(); d.remove(); } return out; })()`);
    pm('root', 'Silence (Summary row)', 'postgres', sb ? `${sb.text}: ${sb.off ? `off - ${sb.words || 'NO words on the page'}` : `dialog '${sb.dialog}'`}${sb.disabledAttr ? ' (the disabled attribute is set)' : ''}` : 'no button',
      !!sb && !sb.moved && !sb.disabledAttr && sb.aria === `Silence all alerts for '${pg.name}'` && (sb.off ? sb.words.length > 0 && sb.dialog === '' : sb.dialog.startsWith(`Silence all alerts for '${pg.name}'?`)),
      "PerformanceMonitor's Silence on the server's row: its confirm, or off (aria-disabled) with its reason in words");
  } else pm('root', 'Silence (Summary row)', 'postgres', 'the Summary did not draw', false, 'the Summary did not draw');
  for (const [inst, eng] of [[ms, 'sqlserver'], [pg, 'postgres']]) {
    const home = `#/summary?i=${inst.instance_id}`;
    if (!(await go(home))) { pm(`${eng} ${inst.name}`, 'header', eng, 'not drawn', false, 'the instance Summary did not draw'); continue; }
    for (let i = 0; i < 40 && !(await ev(`!!document.querySelector('main .inst-header') && !!document.querySelector('main .healthcal-grid')`)); i++) await sleep(250);
    // the header's name (the header and the breadcrumb's dot follow the page when their read ends: waited for): on the
    // instance's own Summary it is text - no header text links to the page it is on -, and from another tab of the
    // instance (Findings: both engines have it) it links to that Summary
    for (let i = 0; i < 50 && !(await ev(`!!document.querySelector('main .inst-header') && !!document.querySelector('#crumb .band-dot')`)); i++) await sleep(100);
    const nh = await ev(`(() => { const n = document.querySelector('main .inst-header .inst-name'); return n ? n.tagName + '|' + (n.getAttribute('href') ?? '') + '|' + n.textContent.trim() : ''; })()`);
    pm(`${eng} ${inst.name}`, 'header name', eng, nh, nh === `SPAN||${inst.name}`, "the header's name on its own Summary: text, no link to the page it is on");
    if (await go(`#/findings?i=${inst.instance_id}`)) {
      for (let i = 0; i < 40 && !(await ev(`!!document.querySelector('main .inst-header .inst-name')`)); i++) await sleep(250);
      const oh = await ev(`document.querySelector('main .inst-header .inst-name')?.getAttribute('href') ?? ''`);
      pm(`${eng} ${inst.name}`, 'header name (from Findings)', eng, oh, tabOf(oh) === 'summary' && paramsOf(oh).get('i') === String(inst.instance_id), "the header's name on another tab: a link to the instance's Summary");
    } else pm(`${eng} ${inst.name}`, 'header name (from Findings)', eng, 'not drawn', false, "the instance's Findings did not draw");
    if (!(await go(home))) { pm(`${eng} ${inst.name}`, 'header', eng, 'not drawn', false, 'the instance Summary did not draw again'); continue; }
    for (let i = 0; i < 40 && !(await ev(`!!document.querySelector('main .inst-header') && !!document.querySelector('#crumb .band-dot') && !!document.querySelector('main .healthcal-grid')`)); i++) await sleep(250);
    const dot = await ev(`(() => { const d = document.querySelector('#crumb .band-dot'); return d ? d.getAttribute('aria-label') : null; })()`);
    pm(`${eng} ${inst.name}`, 'breadcrumb dot', eng, String(dot), ['OK', 'Warning', 'Critical', 'Offline'].includes(dot), 'the band dot before the name in the breadcrumb, named by its word');
    // the own-page status texts: a SQL Server Summary's Memory dumps / DB Mail reason - in the
    // header, the verdict card and the Not OK line - is a link that jumps to its Server card row, the address unchanged
    if (eng === 'sqlserver' && !ownTested) {
      ownTested = true;
      await ev(ownPlant);
      const said = [];
      for (const [name, box, key, band, want] of ownPlants) { const f = await ev(ownFind(box, key, band)); said.push([name, f ? f.how : null, want]); }
      await ev(`document.getElementById('ccp')?.remove(); document.querySelectorAll('[data-cc-own]').forEach(e => e.removeAttribute('data-cc-own'))`);
      const asWanted = said.filter(([, got, want]) => got === want).length;
      pm(`${eng} ${inst.name}`, 'own-page self-test', eng, `${said.map(([n, got, want]) => `${n} -> ${got ?? 'not seen'}${got === want ? '' : ' (wanted ' + (want ?? 'not seen') + ')'}`).join(', ')} | ${asWanted} of ${ownPlants.length} as wanted`,
        asWanted === ownPlants.length, 'the own-page finder over planted texts: a text that lost its data-group is found by its words (past a +1 more too), a band reason with no text of it is missing, other words and checks are not seen, a data-group is found');
    }
    if (eng === 'sqlserver') for (const [where, box, band] of [['header reason', 'main .inst-reason', 'main .inst-header .band-word'], ['verdict reason', 'main .verdict-reasons', 'main .inst-header .band-word'], ['Not OK name', 'main p.counts', null]]) for (const key of ['dumps', 'dbmail']) {
      const was = await ev('location.hash');
      const row = `own-page ${key} (${where})`;
      // the find and the click, once more when the Summary drew the box again between them
      let f = null, got = null;
      for (let tries = 0; tries < 2; tries++) {
        f = await ev(ownFind(box, key, band));
        got = f?.how !== 'group' ? null : !f.link ? { link: false, text: f.text } : await ev(ownClick(key), true);
        if (!got?.lost) break;
      }
      if (f?.how === 'words') { pm(`${eng} ${inst.name}`, row, eng, `'${f.text}' has no data-group`, false, "a status text of this check that lost its data-group: no own-page row and no twin rule can find it"); continue; }
      if (f?.how === 'missing') { pm(`${eng} ${inst.name}`, row, eng, `the band word lists ${key}; no text of it in the ${where}s`, false, "a reason of the band has a text in this box that answers a click"); continue; }
      if (got?.lost) { pm(`${eng} ${inst.name}`, row, eng, 'drawn again between its find and its click, twice', false, 'a status text whose page is this one jumps to its Server card row'); continue; }
      if (!got) { pm(`${eng} ${inst.name}`, row, eng, 'not on this page', true, `not seen: ${key} is not a reason of ${inst.name} now`); continue; }
      const good = got.link && got.focused && got.top != null && got.top >= got.bars && got.top <= got.vh / 3 && got.addr === was;
      pm(`${eng} ${inst.name}`, row, eng, got.link ? `'${got.text}': focus ${got.focused}, the row at ${got.top} px (the bars end at ${got.bars}) of ${got.vh}, the address ${got.addr === was ? 'unchanged' : 'now ' + got.addr}` : `'${got.text}' is text`, good,
        "a status text whose page is this one jumps to its Server card row: at the top of the view, focused, the address unchanged");
      await ev('window.scrollTo(0, 0)');
    }
    // the calendar's month buttons
    const monthOf = () => ev(`document.querySelector('main .healthcal-month')?.textContent ?? ''`);
    const clickNav = async (name) => { await ev(`[...document.querySelectorAll('main .healthcal-nav button')].find(b => (b.getAttribute('aria-label') ?? b.textContent) === ${JSON.stringify(name)})?.click()`); for (let i = 0; i < 30 && await ev(`!!document.querySelector('main .healthcal-body p.meta') && /^Loading/.test(document.querySelector('main .healthcal-body p.meta').textContent)`); i++) await sleep(100); await sleep(200); };
    const m0 = await monthOf();
    // Next month on the current month: off - aria-disabled, never the disabled attribute - and described by visible words
    const nextOff = await ev(`(() => { const b = [...document.querySelectorAll('main .healthcal-nav button')].find(x => x.getAttribute('aria-label') === 'Next month'); if (!b) return null;
      const n = b.getAttribute('aria-describedby') ? document.getElementById(b.getAttribute('aria-describedby')) : null;
      return { off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled, words: n && n.offsetParent !== null ? n.textContent.trim() : '' }; })()`);
    await clickNav('Previous month'); const m1 = await monthOf();
    const back = await ev(`!![...document.querySelectorAll('main .healthcal-nav button')].find(b => b.getAttribute('aria-label') === 'Back to this month')`);
    await clickNav('Next month'); const m2 = await monthOf();
    await clickNav('Previous month'); await clickNav('Back to this month'); const m3 = await monthOf();
    pm(`${eng} ${inst.name}`, 'calendar months', eng, `${m0} -> ${m1} -> ${m2}; This month -> ${m3}; Next on this month: ${JSON.stringify(nextOff)}`,
      !!nextOff && nextOff.off && !nextOff.disabledAttr && nextOff.words === 'this is the current month' && m1 !== m0 && back && m2 === m0 && m3 === m0,
      "Previous / Next month (Next off on this month, saying 'this is the current month'), This month only away from it");
    await clickNav('Show as table');
    const tb = await ev(`({ grid: !!document.querySelector('main .healthcal-body table.grid, main .healthcal-body p.empty'), next: [...document.querySelectorAll('main .healthcal-nav button')].find(b => /Show as/.test(b.textContent))?.textContent })`);
    await clickNav('Show as calendar');
    const cal = await ev(`!!document.querySelector('main .healthcal-grid')`);
    pm(`${eng} ${inst.name}`, 'calendar table', eng, `table ${tb.grid}, then '${tb.next}', calendar again ${cal}`, tb.grid && tb.next === 'Show as calendar' && cal, 'Show as table / Show as calendar');
    // the newest day with data: its detail and its drills
    const day = await ev(`(async () => { const c = [...document.querySelectorAll('main .healthcal-cell')].filter(b => /^\\d+ (Healthy|Warning|Critical), /.test(b.getAttribute('aria-label'))).pop();
      if (!c) return null; c.click(); await new Promise(r => setTimeout(r, 300)); const d = document.querySelector('main .healthcal-day');
      return { label: c.getAttribute('aria-label'), why: d?.querySelector('p')?.textContent ?? '', drills: [...(d?.querySelectorAll('.healthcal-drills a') ?? [])].map(a => [a.textContent, a.getAttribute('href')]) }; })()`, true);
    // a day read that failed is recorded and its drills skipped; the zoom below still runs
    const dayOk = !!day && typeof day === 'object' && typeof day.label === 'string' && Array.isArray(day.drills);
    if (!day) pm(`${eng} ${inst.name}`, 'calendar day', eng, 'no day with data this month', false, 'the demo collects today: a day with data');
    else if (!dayOk) pm(`${eng} ${inst.name}`, 'calendar day', eng, `read back ${JSON.stringify(day).slice(0, 120)}`, false, "the day's click read no label");
    if (dayOk) {
      pm(`${eng} ${inst.name}`, 'calendar day', eng, `${day.label}; ${day.why}`, /^Why this day is (Healthy|Warning|Critical):$/.test(day.why) && day.label.split(', ')[0].replace(/^\d+ /, '') === day.why.replace(/^Why this day is (.*):$/, '$1'), "a day's click: why it has its band");
      const want = { 'View Deadlocks': eng === 'sqlserver' ? 'mssql_deadlocks' : 'pg_deadlocks', 'View Blocking': eng === 'sqlserver' ? 'mssql_blocked' : 'activity', 'View Top Queries': eng === 'sqlserver' ? 'mssql_slow' : 'statements' };
      const iso = (day.label.match(/\d{4}-\d{2}-\d{2}/) ?? [''])[0];
      for (const [t, h] of day.drills) {
        const ok0 = tabOf(h) === want[t] && paramsOf(h).get('from') === `${iso}T00:00:00Z` && (paramsOf(h).get('to') ?? '').startsWith(new Date(Date.parse(iso + 'T00:00:00Z') + 86400000).toISOString().slice(0, 10));
        await ev(`location.hash = ${JSON.stringify(h)}`); await settled(); const got = await landing();
        pm(`${eng} ${inst.name}`, `calendar ${t}`, eng, `${tabOf(got.hash)} (${got.h2.slice(0, 40)})`, ok0 && tabOf(got.hash) === want[t] && !got.err.length, `the day's ${t.replace('View ', '')} page over that UTC day`);
      }
      if (!day.drills.some(([t]) => t === 'View Top Queries')) pm(`${eng} ${inst.name}`, 'calendar View Top Queries', eng, 'missing', false, 'a day with data links its top queries');
    }
    // the Performance page's zoom: a real drag across the first chart (CDP mouse events: uPlot's own drag, chart.ts
    // sets the page's range); the chip ('Zoomed: from → to ×', shown while chartkit's zoom chain holds the address) and
    // every chart's 'Reset zoom' go to one place, the range before the FIRST drag. Three cases, each from a fresh chain:
    // one drag from the page's preset range and the chip's x; two drags, the chip's x and a chart's link the same
    // address; a custom range (not a drag's), a drag, then a chart's 'Reset zoom' back to that range and no chip.
    const perf = `#/performance?i=${inst.instance_id}`;
    const fresh = async (hash) => { await ev(`(() => { try { sessionStorage.removeItem('pgvigil.zoomBack'); } catch {} return true; })()`); return go(hash); };
    // a real mouse click (CDP: pointerdown, mousedown, mouseup, click) at the centre of the first element a selector finds
    const press = async (sel) => {
      const r = await ev(`(() => { const e = document.querySelector(${JSON.stringify(sel)}); if (!e) return null; e.scrollIntoView({ block: 'center' }); const b = e.getBoundingClientRect(); return { x: b.left + b.width / 2, y: b.top + b.height / 2 }; })()`);
      if (!r) return false;
      await cmd('Input.dispatchMouseEvent', { type: 'mouseMoved', x: r.x, y: r.y });
      await cmd('Input.dispatchMouseEvent', { type: 'mousePressed', x: r.x, y: r.y, button: 'left', buttons: 1, clickCount: 1 });
      await cmd('Input.dispatchMouseEvent', { type: 'mouseReleased', x: r.x, y: r.y, button: 'left', buttons: 0, clickCount: 1 });
      await sleep(300); await settled();
      return true;
    };
    const drag = async () => {
      // the header lands above the charts when its read ends: waited for before the chart is measured
      for (let i = 0; i < 50 && !(await ev(`!!document.querySelector('main .inst-header')`)); i++) await sleep(100);
      const before = await ev('location.hash');
      const r0 = await ev(`(() => { const o = document.querySelector('main .charts .u-over'); if (!o) return null; o.scrollIntoView({ block: 'center' }); const b = o.getBoundingClientRect(); return { x: b.left, y: b.top + b.height / 2, w: b.width }; })()`);
      if (!r0) return null;
      const x1 = r0.x + r0.w * 0.3, x2 = r0.x + r0.w * 0.8;
      await cmd('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x1, y: r0.y });
      await cmd('Input.dispatchMouseEvent', { type: 'mousePressed', x: x1, y: r0.y, button: 'left', buttons: 1, clickCount: 1 });
      for (let k = 1; k <= 6; k++) { await cmd('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x1 + (x2 - x1) * k / 6, y: r0.y, button: 'left', buttons: 1 }); await sleep(30); }
      await cmd('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x2, y: r0.y, button: 'left', buttons: 0, clickCount: 1 });
      for (let i = 0; i < 40 && (await ev('location.hash')) === before; i++) await sleep(100);
      await settled(); await sleep(400);
      for (let i = 0; i < 50 && !(await ev(`!!document.querySelector('main .charts .u-over')`)); i++) await sleep(100);   // the zoomed page's charts drawn
      const h = await ev('location.hash');
      return h !== before ? h : null;
    };
    const chipNow = () => ev(`(() => { const c = document.querySelector('main .zoom-chip'); return c ? { text: c.textContent, x: c.querySelector('[aria-label="Reset zoom"]')?.getAttribute('href') ?? null } : null; })()`);
    const resets = () => ev(`[...document.querySelectorAll('main .chart h3 a.chart-reset')].map(a => a.getAttribute('href'))`);
    if (await fresh(perf)) {
      // one drag from the preset range
      const p0 = await ev('location.hash');
      const z1 = await drag(); const c1 = await chipNow();
      await press('main .zoom-chip [aria-label="Reset zoom"]');
      const after = await ev('location.hash'), c1after = await chipNow();
      pm(`${eng} ${inst.name}`, 'Performance zoom', eng, `drag -> ${z1 && paramsOf(z1).get('from') ? 'a custom range' : z1}; ${(c1?.text ?? 'no chip').slice(0, 60)}; x -> ${after === p0 ? 'the range before' : after}${c1after ? ', a chip still there' : ''}`,
        !!z1 && !!paramsOf(z1).get('from') && !!c1 && c1.text.startsWith('Zoomed: ') && c1.text.includes('→') && after === p0 && !c1after,
        "a drag on a chart zooms every chart (the page's range); PerformanceMonitor's 'Zoomed: from → to' chip, its x back to the range before");
      // two drags: the chip's x and every chart's 'Reset zoom' go to the range before the first
      await fresh(perf);
      const q0 = await ev('location.hash');
      const d1 = await drag(), d2 = d1 ? await drag() : null;
      const c2 = await chipNow(), r2 = await resets();
      pm(`${eng} ${inst.name}`, 'zoom: two drags', eng, `chip x ${c2?.x ?? 'none'}; ${r2.length} chart link(s) ${[...new Set(r2)].join(', ')}; the start ${q0}`,
        !!d1 && !!d2 && d2 !== d1 && c2?.x === q0 && r2.length > 0 && r2.every(h => h === q0),
        "after two drags the chip's x and each chart's Reset zoom go to one place, the range before the first drag (design.md: 'Reset zoom' back to the range before the first drag)");
      // a custom range that no drag made, a drag, then a chart's 'Reset zoom': back to that range, no chip
      const custom = d1;   // the first drag's address, opened afresh: a custom range outside any chain
      if (custom && await fresh(custom)) {
        const c3a = await chipNow();
        const d3 = await drag();
        await press('main .chart h3 a.chart-reset');   // a real press: a press on it must never be taken for a drag
        const back = await ev('location.hash'), c3 = await chipNow();
        pm(`${eng} ${inst.name}`, 'zoom: Reset zoom from a custom range', eng, `${c3a ? 'a chip before the drag; ' : ''}drag ${d3 ? 'ok' : 'none'}; Reset zoom -> ${back === custom ? 'the custom range' : back}; chip ${c3 ? c3.text.slice(0, 40) : 'none'}`,
          !c3a && !!d3 && back === custom && !c3,
          "a chart's Reset zoom after a drag from a custom range goes back to that range and leaves no chip (it is never taken for a drag)");
      } else pm(`${eng} ${inst.name}`, 'zoom: Reset zoom from a custom range', eng, 'no custom range to open', false, 'the first case left no zoomed address');
    } else pm(`${eng} ${inst.name}`, 'Performance zoom', eng, 'not drawn', false, 'the Performance page did not draw');
  }
}

// TAGALL (a tag folder holds every page the root holds): every page a folder of 'All instances' lists (its caret key r/<group>) is listed by the tag folder's folder of the
// same group (t:<folder>/<group>), each link carrying tag=<tag>, and the tag's main strip carries every page of the root's
// main strip; the tag holds both engines (`tag` above), so no page is excused by its engine. One row per page missing.
{
  const sc = `tag ${tag}`;
  // a folder's pages by the tab of every link under it (a nested Custom reports folder counts as its tab), opened when closed
  const folderTabs = (keyRe, topLink) => ev(`(async () => {
    const want = ${JSON.stringify(topLink)};
    const scopeBox = () => want ? [...document.querySelectorAll('#tree .folder')].find(f => [...f.querySelectorAll(':scope > .folder-head a')].some(a => ((a.getAttribute('href') || '').split('?')[1] || '').split('&').includes(want))) : document.querySelector('#tree');
    // the tree draws after the page: wait for it (10 s)
    for (let i = 0; i < 50 && !(scopeBox()?.querySelector('button.caret')); i++) await new Promise(r => setTimeout(r, 200));
    // the top-level group folders only, on both sides: the root's 'r/<group>', the tag folder's 't:<its path>/<group>'
    // (tree.ts: its caret 'f:<path>', its groups at depth 0 only); a nested Custom reports folder ('.../reports/cr') counts
    // under its group by its links, never as a group of its own
    const own = want ? (scopeBox()?.querySelector(':scope > .folder-head button.caret')?.dataset.key ?? '') : '';
    const path = own.replace(/^f:/, ''), pre = want ? 't:' + (path.endsWith('/') ? path.slice(0, -1) : path) + '/' : 'r/';
    const isGroup = k => k.startsWith(pre) && /^[a-z]+$/.test(k.slice(pre.length));
    const carets = () => { const b = scopeBox(); return b ? [...b.querySelectorAll('button.caret')].filter(c => isGroup(c.dataset.key || '')) : []; };
    for (const c of carets()) if (c.getAttribute('aria-expanded') !== 'true') { c.click(); await new Promise(r => setTimeout(r, 300)); }
    const out = {};
    for (const c of carets()) {
      const g = (c.dataset.key || '').split('/').pop();
      const box = c.closest('.tree-node')?.parentElement;
      out[g] = box ? [...box.querySelectorAll('a')].map(a => a.getAttribute('href') || '').filter(h => h.startsWith('#/')).map(h => ({ tab: h.slice(2).split('?')[0], tagged: ((h.split('?')[1] || '').split('&')).includes(want) })) : [];
    }
    return out;
  })()`, true);
  await go(`#/summary`);
  const root = await folderTabs('', '');
  await go(`#/summary?tag=${encodeURIComponent(tag)}`);
  const inTag = await folderTabs('', 'tag=' + encodeURIComponent(tag));
  let missing = 0;
  for (const [g, links] of Object.entries(root)) {
    const have = new Set((inTag[g] ?? []).map(l => l.tab));
    for (const t of new Set(links.map(l => l.tab))) {
      if (have.has(t)) continue;
      missing++;
      record({ scope: sc, kind: 'tag-all', column: g, engine: '', link: `All instances > ${g} > ${t}`, landed: inTag[g] ? `the tag folder's ${g} lists ${[...have].join(', ') || 'nothing'}` : `the tag folder has no ${g} folder`, verdict: `FAIL ${t} is under All instances > ${g} and not under ${tag} > ${g}` });
    }
    for (const l of (inTag[g] ?? []).filter(l => !l.tagged)) missing++, record({ scope: sc, kind: 'tag-all', column: g, engine: '', link: `${tag} > ${g} > ${l.tab}`, landed: 'its link carries no tag=', verdict: `FAIL ${l.tab} under ${tag} > ${g} does not carry the tag` });
  }
  // the main strip: the root's main tabs against the tag's
  const strip = () => ev(`[...document.querySelectorAll('#tabs a:not(.tab-back)')].map(a => { const h = a.getAttribute('href') || ''; return [h.slice(2).split('?')[0], (h.split('?')[1] || '').split('&').includes(${JSON.stringify('tag=' + encodeURIComponent(tag))})]; })`);
  await go(`#/summary`);
  const rootStrip = (await strip()).map(([t]) => t);
  await go(`#/summary?tag=${encodeURIComponent(tag)}`);
  const tagStripRows = await strip();
  const tagStrip = new Set(tagStripRows.map(([t]) => t));
  for (const t of rootStrip.filter(t => !tagStrip.has(t))) { missing++; record({ scope: sc, kind: 'tag-all', column: 'main strip', engine: '', link: `the root strip's ${t}`, landed: `the tag's strip: ${[...tagStrip].join(', ')}`, verdict: `FAIL ${t} is on the root's strip and not on ${tag}'s` }); }
  for (const [t] of tagStripRows.filter(([, k]) => !k)) { missing++; record({ scope: sc, kind: 'tag-all', column: 'main strip', engine: '', link: `${tag}'s strip ${t}`, landed: 'its link carries no tag=', verdict: `FAIL ${t} on ${tag}'s strip does not carry the tag` }); }
  // a read of nothing is no 'ok': the root's eight folders of groups and a main strip must have been read
  const rootGroupsWant = ['conf', 'checks', 'hadr', 'storage', 'jobs', 'doors', 'admin', 'reports'];
  const unread = rootGroupsWant.filter(g => !root[g]?.length);
  if (unread.length || !rootStrip.length) { missing++; record({ scope: sc, kind: 'tag-all', column: 'the read', engine: '', link: 'All instances', landed: `root folders read: ${Object.keys(root).join(', ') || 'none'}; root strip: ${rootStrip.length} tab(s)`, verdict: `FAIL the root was not read (no ${unread.join(', ') || 'strip'})` }); }
  if (!missing) record({ scope: sc, kind: 'tag-all', column: 'every group', engine: '', link: `${Object.keys(root).length} root folders and the main strip`, landed: `${tag}'s folders hold every page`, verdict: 'ok (TAGALL: every root page under the tag folder)' });
}

// TAGALL pages (the design's T2 / T3): each page the tag folder gained, opened under ?tag=<tag>, is drawn with no error box,
// keeps the tag in its address, and says what it holds - its heading names the folder ('<page> - tag <tag>') or it carries
// the one line of a list or a setting for the whole repository (fleet.ts fleetWideNote, p.fleet-wide). One row per page.
{
  const sc = `tag ${tag}`;
  const pages = ['diff', 'pgthresholds', 'retention', 'dbadash', 'admin_instances', 'admin_applications', 'admin', 'rp_recycle', 'customreports', 'community', 'reportmail', 'alertrules'];
  const named = `tag ${tag}`;
  for (const t of pages) {
    const drawn = await go(`#/${t}?tag=${encodeURIComponent(tag)}`);
    const l = await landing();
    const wide = await ev(`!!document.querySelector('main p.fleet-wide')`);
    const kept = paramsOf(l.hash).get('tag') === tag && tabOf(l.hash) === t;
    const says = l.h2.includes(named) || wide;
    const verdict = !drawn ? 'FAIL not drawn (no heading in 15 s)' : l.err.length ? `FAIL an error box: ${l.err[0]}` : !kept ? `FAIL the address lost the tag or the page: ${l.hash}`
      : !says ? `FAIL it names no folder and says nothing of the whole repository (heading '${l.h2}')` : `ok (TAGALL page: ${wide ? 'the whole-repository line' : 'the heading names the folder'})`;
    record({ scope: sc, kind: 'tag-all-page', column: t, engine: '', link: `#/${t}?tag=${tag}`, landed: `${l.hash} - '${l.h2}'${wide ? ' + the whole-repository line' : ''}`, verdict });
  }
}

// TAGALL behaviour (the design's T2): what a page under ?tag=<tag> lists or picks is the
// folder's, and the root's is every instance's. Each row names what it read; a row the demo cannot judge says 'not seen'.
{
  const sc = `tag ${tag}`;
  const q = encodeURIComponent(tag);
  const tagsOfRow = r => Array.isArray(r.tags) ? r.tags.map(String) : [];
  const inTagIds = new Set(insts.filter(r => tagsOfRow(r).includes(tag)).map(r => String(r.instance_id)));
  const outside = insts.find(r => !inTagIds.has(String(r.instance_id)));
  const inside = insts.find(r => inTagIds.has(String(r.instance_id)));
  const row = (column, link, landed, verdict) => record({ scope: sc, kind: 'tag-all-t2', column, engine: '', link, landed, verdict });
  const same = (a, b) => a.length === b.size && a.every(x => b.has(x));
  const options = sel => ev(`[...document.querySelectorAll(${JSON.stringify(sel)} + ' option')].map(o => o.value).filter(Boolean)`);
  // Community tools: the instance picker
  await go('#/community'); const cRoot = await options('main select[aria-label="Instance"]');
  await go(`#/community?tag=${q}`); const cTag = await options('main select[aria-label="Instance"]');
  row('community', `#/community and #/community?tag=${tag}`, `root ${cRoot.length} option(s), the folder ${cTag.length}`,
    cRoot.length === insts.length && same(cTag, inTagIds) ? 'ok (TAGALL: the picker is the folder\'s; the root\'s every instance)' : `FAIL the picker: root ${cRoot.length} of ${insts.length}, the folder [${cTag.join(',')}] not its ${inTagIds.size} [${[...inTagIds].join(',')}]`);
  // Diff: both pickers; a pick outside the folder in the address is dropped and nothing is compared
  await go(`#/diff?tag=${q}`); const dA = await options('#diff-a');
  row('diff', `#/diff?tag=${tag}`, `picker A ${dA.length} option(s)`, same(dA, inTagIds) ? 'ok (TAGALL: picker A is the folder\'s)' : `FAIL picker A [${dA.join(',')}] not the folder's [${[...inTagIds].join(',')}]`);
  if (outside && inside) {
    await go(`#/diff?tag=${q}&m=i&a=${outside.instance_id}&b=${inside.instance_id}`); await sleep(2500);
    const d = await ev(`({ a: document.querySelector('#diff-a')?.value ?? 'none', grids: document.querySelectorAll('main [aria-label="Diff result"] table').length, said: (document.querySelector('main [aria-label="Diff result"]')?.textContent ?? '').slice(0, 120) })`);
    row('diff', `#/diff?tag=${tag}&a=${outside.name}`, `A '${d.a}', result tables ${d.grids}, '${d.said}'`, d.a === '' && d.grids === 0 ? 'ok (TAGALL: a pick outside the folder is dropped, nothing compared)' : `FAIL the outside pick ${outside.name} kept or compared (A '${d.a}', ${d.grids} result table(s))`);
  } else row('diff', 'an instance outside the folder', 'none', 'not seen: every instance is in the folder');
  // Admin > Overview > Servers: the folder's instances
  await go(`#/admin?tag=${q}&atab=servers`);
  for (let i = 0; i < 50 && !(await ev(`!!document.querySelector('main table.grid tbody tr')`)); i++) await sleep(200);
  const sv = await ev(`[...document.querySelectorAll('main table.grid tbody tr')].map(r => r.cells[0]?.textContent.trim())`);
  const want = new Set(insts.filter(r => inTagIds.has(String(r.instance_id))).map(r => String(r.name)));
  row('admin', `#/admin?tag=${tag}&atab=servers`, `${sv.length} server(s)`, same(sv, want) ? 'ok (TAGALL: Servers lists the folder\'s instances)' : `FAIL Servers [${sv.join(', ')}] not the folder's [${[...want].join(', ')}]`);
  // Thresholds: the instance places of the form and the scope line above the levels
  await go(`#/pgthresholds?tag=${q}`);
  const th = await ev(`(() => { const l = document.querySelector('main select[aria-label="level"]'); if (!l) return { why: 'no level picker' };
    if (![...l.options].some(o => o.value === 'instance')) return { why: 'no instance level' };
    l.value = 'instance'; l.dispatchEvent(new Event('change'));
    const p = [...document.querySelectorAll('main select[aria-label="where"] option')].map(o => o.value).filter(Boolean);
    const line = [...document.querySelectorAll('main p')].find(x => x.textContent.startsWith('In view:'));
    const lv = [...document.querySelectorAll('main h3')].find(x => x.textContent.startsWith('Set levels'));
    return { p, before: !!(line && lv && (line.compareDocumentPosition(lv) & Node.DOCUMENT_POSITION_FOLLOWING)) }; })()`);
  row('pgthresholds', `#/pgthresholds?tag=${tag}`, th.why ?? `places [${th.p.join(',')}], the scope line before the levels ${th.before}`,
    th.why ? `FAIL ${th.why}` : th.p.length && th.p.every(x => inTagIds.has(x)) && th.before ? 'ok (TAGALL: the places are the folder\'s; its scope line under the heading)' : `FAIL places [${th.p.join(',')}] (the folder's [${[...inTagIds].join(',')}]), the scope line before the levels ${th.before}`);
  // Applications: the folder's applications (a server's application is its tag application:<name>)
  const appsIn = new Set(insts.filter(r => inTagIds.has(String(r.instance_id))).flatMap(tagsOfRow).filter(t => t.toLowerCase().startsWith('application:')).map(t => t.slice(12).toLowerCase()));
  const openNames = () => ev(`[...document.querySelectorAll('main table.grid button[aria-label^="Open "]')].map(b => b.getAttribute('aria-label').slice(5))`);
  await go('#/admin_applications'); const aRoot = await openNames();
  await go(`#/admin_applications?tag=${q}`); const aTag = await openNames();
  const aWant = aRoot.filter(n => appsIn.has(n.toLowerCase()));
  row('admin_applications', `#/admin_applications?tag=${tag}`, `root [${aRoot.join(', ')}], the folder [${aTag.join(', ')}]`,
    aWant.length === aRoot.length ? `not seen: every application (${aRoot.length}) has a server in the folder` : same(aTag, new Set(aWant)) ? 'ok (TAGALL: the folder\'s applications)' : `FAIL the folder lists [${aTag.join(', ')}], its applications are [${aWant.join(', ')}]`);
  // Imported servers under a PostgreSQL-only tag: one line, no SQL Server grid (any written tag of PostgreSQL alone)
  const pgOnly = [...tagCount.entries()].filter(([, e]) => e.engines.size === 1 && e.engines.has('postgres')).map(([t]) => t).sort()[0];
  if (pgOnly) {
    await go(`#/dbadash?tag=${encodeURIComponent(pgOnly)}`);
    const dd = await ev(`({ said: (document.querySelector('main')?.textContent ?? '').includes('SQL Server servers only'), grids: document.querySelectorAll('main table.grid').length })`);
    row('dbadash', `#/dbadash?tag=${pgOnly}`, `the line ${dd.said}, ${dd.grids} grid(s)`, dd.said && dd.grids === 0 ? 'ok (TAGALL: a PostgreSQL-only folder: one line, no SQL Server grid)' : `FAIL under ${pgOnly}: the line ${dd.said}, ${dd.grids} grid(s)`);
    // ... and a top-level PostgreSQL-only tag folder carries no Doors folder (the engine rule)
    if (topLevel(pgOnly)) {
      await go(`#/summary?tag=${encodeURIComponent(pgOnly)}`); await sleep(800);
      const doors = await ev(`[...document.querySelectorAll('#tree button.caret')].some(c => /^t:.*\\/doors$/.test(c.dataset.key || '') && (c.closest('.folder')?.querySelector(':scope > .folder-head a')?.getAttribute('href') || '').includes(${JSON.stringify('tag=' + encodeURIComponent(pgOnly))}))`);
      row('doors', `the folder ${pgOnly}`, `a Doors folder ${doors}`, doors ? `FAIL the PostgreSQL-only folder ${pgOnly} carries Doors` : 'ok (TAGALL: no Doors folder where no SQL Server instance is)');
    } else row('doors', `the folder ${pgOnly}`, 'not a top-level folder', `not seen: ${pgOnly} has no folder of its own at the tree's top`);
  } else row('dbadash', 'a PostgreSQL-only tag', 'none', 'not seen: the demo has no tag of PostgreSQL instances alone');
  // Recycle Bin: an inactive instance is listed under a folder only when it carries the folder's tag (its row's tags)
  const rb = await (await fetch(U + 'api/reports?r=recycle')).json().catch(() => ({}));
  const rbT = rb.instances ?? {}, rbC = rbT.columns ?? [], rbRows = (rbT.rows ?? []).map(r => Object.fromEntries(rbC.map((c, i) => [c, r[i]])));
  const gone = rbRows.filter(r => r.is_active === false);
  if (!gone.length) row('rp_recycle', 'an inactive instance', `${rbRows.length} row(s), none inactive`, 'not seen: the demo has no inactive instance');
  else {
    await go(`#/rp_recycle?tag=${q}`); await sleep(500);
    const listed = await ev(`[...document.querySelectorAll('main table.grid tbody tr')].map(r => r.cells[1]?.textContent.trim())`);
    const wrong = gone.filter(r => !('tags' in r) || !tagsOfRow(r).includes(tag)).map(r => String(r.instance)).filter(n => listed.includes(n));
    row('rp_recycle', `#/rp_recycle?tag=${tag}`, `${gone.length} inactive at the root; listed [${listed.join(', ')}]`, !('tags' in gone[0]) ? 'FAIL the recycle read carries no tags' : wrong.length ? `FAIL inactive instances of other tags listed: ${wrong.join(', ')}` : 'ok (TAGALL: the inactive instances that carried the tag)');
  }
  // the folder of no tag says its own name in the whole-repository line
  await go('#/retention?tag=untagged');
  const ul = await ev(`document.querySelector('main p.fleet-wide')?.textContent ?? 'none'`);
  row('retention', '#/retention?tag=untagged', ul, ul === 'Data retention is one setting for the whole repository: the untagged folder shows all of it.' ? 'ok (TAGALL: the untagged folder named as such)' : `FAIL the line under untagged: '${ul}'`);
}

// TAGTREE rows: (a) the tag folder's own Jobs folder holds the Jobs page of that tag
{
  const sc = `tag ${tag}`;
  await go(`#/summary?tag=${encodeURIComponent(tag)}`);
  const tj = await tagFolder('jobs');
  const jobs = tj.leaves?.find(([t]) => t === 'Jobs')?.[1];
  if (!jobs) record({ scope: sc, kind: 'tag-tree', column: 'Jobs', engine: '', link: "the tag folder's Jobs", landed: tj.why ?? `leaves: ${(tj.leaves ?? []).map(l => l[0]).join(', ') || 'none'}`, verdict: "FAIL no Jobs leaf in the tag folder's own Jobs folder" });
  else {
    const got = await treeClick(jobs);
    record({ scope: sc, kind: 'tag-tree', column: 'Jobs', engine: '', link: "the tag folder's Jobs", landed: `${got.hash} (${got.h2.slice(0, 40)})`,
      verdict: tabOf(got.hash) === 'jobs' && paramsOf(got.hash).get('tag') === tag && !got.err.length ? "ok (DBA Dash: a tag folder's Jobs; lands with tag= kept, no error - what the page lists is not read here)" : `FAIL want jobs with tag=${tag}, got ${got.hash} ${got.err[0] ?? ''}` });
  }
  // (c) Alerts under the tag lists only the tag's instances' alerts and names the tag (DBA Dash: Main.cs L1820-1822 at a
  // tag folder); the root's Alerts must list an instance outside the tag, or the row proves nothing
  const tagNames = new Set(insts.filter(r => (Array.isArray(r.tags) ? r.tags : []).includes(tag)).map(r => String(r.name)));
  // the grids the page narrows by the tag (its in-view line): open alerts, the alert history, held sends, the send log;
  // the silenced servers, mute rules, known patterns and the acknowledge log are the repository's, said in that line
  const alertInstances = () => ev(`(() => { const out = []; let h3 = '';
    const narrowed = /^(Open alerts|Alert history|Held sends|Send log)/;
    for (const t of document.querySelectorAll('main h3, main table.grid')) {
      if (t.matches('h3')) { h3 = t.textContent.trim(); continue; }
      if (!narrowed.test(h3)) continue;
      const hs = [...t.querySelectorAll('thead th')].map(h => (h.querySelector('.th-label') ?? h).textContent.trim());
      const i = hs.findIndex(h => h === 'instance' || h === 'instance (one)');
      if (i < 0) continue;
      for (const tr of t.querySelectorAll('tbody tr')) { const v = tr.children[i]?.textContent.trim(); if (v) out.push(v); }
    }
    return { out, h2: document.querySelector('main h2')?.textContent.trim() ?? '' }; })()`);
  // a repository-wide alert (no instance: the collector, the repository) carries the name 'pgvigil' (0190's
  // alert_findings) and stays listed in every folder; proof-clickmap.sh seeds one standing
  const isRepo = n => n === 'pgvigil' && !insts.some(r => String(r.name) === 'pgvigil');
  await go('#/alerts'); const rootA = await alertInstances();
  const outside = [...new Set(rootA.out.filter(n => !tagNames.has(n) && !isRepo(n)))];
  const repoRoot = rootA.out.filter(isRepo).length;
  await go(`#/alerts?tag=${encodeURIComponent(tag)}`); const tagA = await alertInstances();
  const leak = [...new Set(tagA.out.filter(n => !tagNames.has(n) && !isRepo(n)))];
  const repoTag = tagA.out.filter(isRepo).length;
  record({ scope: sc, kind: 'tag-tree', column: 'Alerts', engine: '', link: `#/alerts?tag=${tag}`, landed: `${tagA.out.length} row(s) naming an instance, ${leak.length} outside the tag, ${repoTag} of the root's ${repoRoot} repository-wide; heading '${tagA.h2.slice(0, 50)}'`,
    verdict: outside.length === 0 ? "FAIL the root's Alerts lists no instance outside the tag: the row proves nothing"
      : repoRoot === 0 ? "FAIL the root's Alerts lists no repository-wide alert ('pgvigil'): the row proves nothing"
      : leak.length ? `FAIL ${leak.length} instance(s) outside ${tag} listed: ${leak.slice(0, 4).join(', ')}`
      : repoTag !== repoRoot ? `FAIL under ${tag} ${repoTag} of the root's ${repoRoot} repository-wide alert row(s) listed`
      : !tagA.h2.includes(tag) ? `FAIL the heading '${tagA.h2}' does not name ${tag}`
      : `ok (the root lists ${outside.length} instance(s) outside the tag; under it none; the ${repoRoot} repository-wide row(s) under it too)` });
}

// (d) under a kept tag no top folder carries whose instances are all SQL Server, the root's
// folders offer no page that holds PostgreSQL alone (router.ts pageEngine, read from each page's SQL) and still offer
// SQL Server options
{
  // router.ts pageEngine's PostgreSQL pages; custom left it with ST6 (mssql_custom writes the same tables: both engines'),
  // jobs and backups when both pages listed SQL Server rows too (the fleet Jobs page's SQL Agent rows, 4bfd03b0; the root
  // Backups page's SQL Server section, a606c77d): a SQL Server-only folder offers both (TAGALL: every root page under every tag folder)
  const pgOnly = new Set(['pgrisks', 'pgreplication', 'extensions', 'corruption', 'versions', 'tablesize', 'roles', 'dms', 'disks', 'storage', 'growth', 'indexes']);
  const bothEngines = [['backups', 'hadr', 'mssqllogshipping'], ['jobs', 'jobs', 'jobstimeline']];   // [page, its group, a SQL Server page of that group's strip]
  await go('#/summary');
  const tops = await ev(`[...document.querySelectorAll('#tree .folder > .folder-head a')].map(a => new URLSearchParams((a.getAttribute('href') || '').split('?')[1] || '').get('tag')).filter(Boolean)`);
  const carriers = new Map();
  for (const r of insts) for (const t of (Array.isArray(r.tags) ? r.tags : [])) { if (!carriers.has(t)) carriers.set(t, []); carriers.get(t).push(r); }
  const msTag = [...carriers.entries()].filter(([t, rs]) => !tops.includes(t) && rs.every(r => r.engine === 'sqlserver')).map(([t]) => t).sort()[0];
  if (!msTag) record({ scope: 'root', kind: 'tag-tree', column: 'engines', engine: 'sqlserver', link: '-', landed: `top folders: ${tops.join(', ')}`, verdict: 'FAIL no kept tag carried by SQL Server instances only: the row proves nothing' });
  else {
    await go(`#/summary?tag=${encodeURIComponent(msTag)}`);
    const leaves = await ev(`(async () => { const out = [];
      for (const g of ['conf', 'checks', 'hadr', 'storage', 'jobs']) {
        const find = () => document.querySelector('#tree button.caret[data-key="r/' + g + '"]');
        let c = find(); if (!c) continue;
        if (c.getAttribute('aria-expanded') !== 'true') { c.click(); await new Promise(r => setTimeout(r, 400)); c = find(); }
        const box = c?.closest('.tree-node')?.parentElement;
        if (box) for (const a of box.querySelectorAll(':scope > div:not(.tree-node) a.inst')) out.push(a.getAttribute('href'));
      }
      return out; })()`, true);
    const tabs = (leaves ?? []).map(tabOf), bad = tabs.filter(t => pgOnly.has(t)), lacks = bothEngines.map(([t]) => t).filter(t => !tabs.includes(t));
    record({ scope: `tag ${msTag}`, kind: 'tag-tree', column: 'engines', engine: 'sqlserver', link: `#/summary?tag=${msTag}`, landed: `${tabs.length} leaves in the root's folders: ${tabs.join(' ')}`.slice(0, 260),
      verdict: tabs.length === 0 ? "FAIL no leaf read in the root's folders"
        : bad.length ? `FAIL page(s) of PostgreSQL alone offered for a SQL Server-only tag: ${bad.join(', ')}`
        : !tabs.includes('mssqlrisks') ? 'FAIL SQL Server options is not offered'
        : lacks.length ? `FAIL page(s) that list SQL Server rows not offered for a SQL Server-only tag: ${lacks.join(', ')}`
        : `ok (${carriers.get(msTag).length} SQL Server instance(s); no page of PostgreSQL alone; SQL Server options, ${bothEngines.map(([t]) => t).join(' and ')} there)` });
    // the strips of those pages' groups, on a SQL Server page of each under that tag: the page is offered (main.ts tagPages)
    for (const [t, g, on] of bothEngines) {
      await go(`#/${on}?tag=${encodeURIComponent(msTag)}`);
      const gs = ((await ev(`[...document.querySelectorAll('#tabs a')].map(a => a.getAttribute('href'))`)) ?? []).map(tabOf);
      record({ scope: `tag ${msTag}`, kind: 'tag-tree', column: `strip ${g}`, engine: 'sqlserver', link: `#/${on}?tag=${msTag}`, landed: `the strip: ${gs.join(' ')}`.slice(0, 260),
        verdict: !gs.includes(on) ? `FAIL the strip does not hold ${on}`
          : !gs.includes(t) ? `FAIL the ${g} strip does not offer ${t} for a SQL Server-only tag (it lists SQL Server rows)`
          : `ok (the ${g} strip offers ${t})` });
    }
    // the Configuration strip on SQL Server options under that tag: no page of PostgreSQL alone (main.ts tagPages)
    await go(`#/mssqlrisks?tag=${encodeURIComponent(msTag)}`);
    const strip = ((await ev(`[...document.querySelectorAll('#tabs a')].map(a => a.getAttribute('href'))`)) ?? []).map(tabOf);
    const sbad = strip.filter(t => pgOnly.has(t));
    record({ scope: `tag ${msTag}`, kind: 'tag-tree', column: 'strip', engine: 'sqlserver', link: `#/mssqlrisks?tag=${msTag}`, landed: `the strip: ${strip.join(' ')}`.slice(0, 260),
      verdict: !strip.includes('mssqlrisks') ? 'FAIL the strip does not hold SQL Server options'
        : sbad.length ? `FAIL the strip offers page(s) of PostgreSQL alone for a SQL Server-only tag: ${sbad.join(', ')}`
        : 'ok (the Configuration strip holds no page of PostgreSQL alone)' });
  }
}

// (e) task 383, the HA/DR folder's pages (design section 8): a folder page's
// Instance link lands on the same page at that instance with Back on, and Back returns to the folder; a SQL Server
// instance's HA/DR strip holds DBA Dash's four tabs in its order; a PostgreSQL instance's strip none of the three
{
  const haOrder = ['mssqlbackups', 'mssqllogshipping', 'mssqlmirroring', 'mssqlag'];
  // each folder page and the collection it draws (q_mssql_hadr.go's hadrReads); CLICK_SEEDED (proof-clickmap.sh) names the
  // collections the demo's seed holds rows of: a page with no Instance link is 'not proven' only for a kind the seed holds
  // none of, and a FAIL for a kind it holds (or when CLICK_SEEDED is not given: what the data holds is then unknown)
  const haKinds = { mssqlag: ['mssql_ag', 'Availability Groups'], mssqlmirroring: ['mssql_mirroring', 'Mirroring'], mssqllogshipping: ['mssql_logshipping', 'Log Shipping'] };
  const seeded = process.env.CLICK_SEEDED == null ? null : new Set(process.env.CLICK_SEEDED.split(/\s+/).filter(Boolean));
  for (const t of ['mssqlag', 'mssqlmirroring', 'mssqllogshipping']) {
    await go(`#/${t}`);
    const link = await ev(`(() => { const x = [...document.querySelectorAll('main table a')].find(a => /[?&]i=\\d+/.test(a.getAttribute('href') || '')); return x ? x.getAttribute('href') : null; })()`);
    if (!link) {
      const [coll, name] = haKinds[t];
      record({ scope: 'root', kind: 'hadr', column: 'Instance drill', engine: 'sqlserver', link: `#/${t}`, landed: 'no row with an Instance link',
        verdict: seeded && !seeded.has(coll) ? `not proven: no ${name} row in this data (the seed holds no ${coll} row)`
          : `FAIL the folder page has no Instance link (${seeded ? `the seed holds ${coll} rows` : 'CLICK_SEEDED not given: what the data holds is unknown'})` });
      continue;
    }
    await ev(`(() => { [...document.querySelectorAll('main table a')].find(a => a.getAttribute('href') === ${JSON.stringify(link)})?.click(); })()`);
    await sleep(500); await settled();
    const got = await landing();
    const back = await ev(`(() => { const b = [...document.querySelectorAll('main .toolbar button')].find(x => x.textContent.trim() === 'Back'); return b ? !(b.disabled || b.getAttribute('aria-disabled') === 'true') : null; })()`);
    let backTo = '';
    if (back) { await ev(`(() => { [...document.querySelectorAll('main .toolbar button')].find(x => x.textContent.trim() === 'Back')?.click(); })()`); await sleep(500); await settled(); backTo = (await landing()).hash; }
    record({ scope: 'root', kind: 'hadr', column: 'Instance drill', engine: 'sqlserver', link, landed: `${got.hash}; Back ${back === null ? 'absent' : back ? 'on' : 'off'}${backTo ? ' -> ' + backTo : ''}`,
      verdict: tabOf(got.hash) !== t || !paramsOf(got.hash).get('i') ? `FAIL want ${t} at the instance, got ${got.hash}`
        : got.err.length ? `FAIL the landing shows an error: ${got.err[0]}`
        : back !== true ? 'FAIL Back is not on after the drill'
        : tabOf(backTo) !== t || paramsOf(backTo).get('i') ? `FAIL Back went to ${backTo}, want the folder's ${t}`
        : 'ok (DBA Dash: Instance -> the same page at that instance; Navigate Back -> the folder)' });
  }
  await go(`#/mssqlag?i=${ms.instance_id}`);
  const msStrip = ((await ev(`[...document.querySelectorAll('#tabs a')].map(a => a.getAttribute('href'))`)) ?? []).map(tabOf).filter(t => haOrder.includes(t));
  record({ scope: `instance ${ms.name}`, kind: 'hadr', column: 'HA/DR strip', engine: 'sqlserver', link: `#/mssqlag?i=${ms.instance_id}`, landed: msStrip.join(' '),
    verdict: msStrip.join(' ') === haOrder.join(' ') ? 'ok (DBA Dash: Backups, Log Shipping, Mirroring, Availability Groups)' : `FAIL want ${haOrder.join(' ')}` });
  await go(`#/backups?i=${pg.instance_id}`);
  const pgStrip = ((await ev(`[...document.querySelectorAll('#tabs a')].map(a => a.getAttribute('href'))`)) ?? []).map(tabOf);
  const pgBad = pgStrip.filter(t => haOrder.slice(1).includes(t));
  record({ scope: `instance ${pg.name}`, kind: 'hadr', column: 'HA/DR strip', engine: 'postgres', link: `#/backups?i=${pg.instance_id}`, landed: pgStrip.join(' ').slice(0, 200),
    verdict: pgBad.length ? `FAIL a PostgreSQL instance's strip offers ${pgBad.join(', ')}` : 'ok (none of the three SQL Server pages)' });
}
// task LSX: the Log Shipping Detail's Database button narrows pgvigil's own panel below DBA Dash's grids (the jobs, the
// agents' messages, the log backups outside log shipping) to that database: the panel's Database box takes the name and
// the panel draws its three grids with no error box. A demo with no log shipping Detail row cannot show it: said so.
{
  await go('#/mssqllogshipping');
  const pick = await ev(`(() => { const b = [...document.querySelectorAll('main table button.link')].find(x => /^Show log shipping's jobs/.test(x.getAttribute('aria-label') || '')); return b ? b.textContent : null; })()`);
  if (pick == null) {
    record({ scope: 'root', kind: 'hadr', column: 'Log Shipping panel', engine: 'sqlserver', link: '#/mssqllogshipping', landed: 'no Detail row with a Database button',
      verdict: 'not proven: no log shipping Detail row in this data' });
  } else {
    // the box before the click (it must read every database, or the click proves nothing), then the click, then every
    // Database cell of the panel's three grids: each the clicked name (ignoring case), or the grid empty
    const before = await ev(`(() => document.querySelector('main .mssql-hadr-logship-config select')?.value ?? null)()`);
    await ev(`(() => { [...document.querySelectorAll('main table button.link')].find(x => /^Show log shipping's jobs/.test(x.getAttribute('aria-label') || '') && x.textContent === ${JSON.stringify(pick)})?.click(); })()`);
    await sleep(300); await settled();
    const st = await ev(`(() => { const p = document.querySelector('main .mssql-hadr-logship-config'); if (!p) return null;
      const want = ${JSON.stringify(pick)}.toLowerCase(); let rows = 0; const other = [];
      for (const t of p.querySelectorAll('table:not(.grid-empty)')) {
        const i = [...t.querySelectorAll('thead th')].map(h => (h.querySelector('.th-label')?.textContent ?? h.textContent).trim()).indexOf('Database');
        if (i < 0) continue;
        for (const tr of t.querySelectorAll('tbody tr')) { const c = tr.children[i]; if (!c) continue; rows++; const v = c.textContent.trim(); if (v.toLowerCase() !== want) other.push(v); }
      }
      return { value: p.querySelector('select')?.value ?? null, grids: p.querySelectorAll('h4').length, err: p.querySelectorAll('.error').length, rows, other: other.slice(0, 5) }; })()`);
    record({ scope: 'root', kind: 'hadr', column: 'Log Shipping panel', engine: 'sqlserver', link: `#/mssqllogshipping Database ${pick}`,
      landed: st ? `before the click ${before === '' ? 'every database' : before}; Database box ${st.value}; ${st.grids} grids, ${st.rows} rows; ${st.err} error boxes` : 'no panel',
      verdict: pick === '' ? 'FAIL the Detail\'s Database button has no name'
        : !st ? 'FAIL the page has no log shipping panel'
        : before !== '' ? `FAIL the Database box read ${before} before the click (want every database)`
        : String(st.value).toLowerCase() !== pick.toLowerCase() ? `FAIL the Database box reads ${st.value}, want ${pick}`
        : st.grids !== 3 || st.err ? `FAIL ${st.grids} grids (want 3), ${st.err} error boxes`
        : st.other.length ? `FAIL the panel still lists other databases after the click: ${st.other.join(', ')}`
        : `ok (pgvigil's own: the panel narrowed to the clicked database, ${st.rows} row${st.rows === 1 ? '' : 's'} of it)` });
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
console.log(`links: ${results.length} (${byKind('cell')} instance-grid cells, ${byKind('shape')} Summary shape checks, ${byKind('test')} test names, ${byKind('test-filter')} test filters, ${byKind('strip')} Needs attention, ${byKind('name')} instance names, ${byKind('check')} failing checks, ${byKind('other')} other, ${byKind('tree')} tree nodes, ${byKind('storage-tab')} Storage tabs, ${byKind('drive-files')} drive Files links, ${byKind('pm')} PerformanceMonitor links and buttons); ${fails} FAIL`);
ws.close();
process.exit(fails ? 1 : 0);
