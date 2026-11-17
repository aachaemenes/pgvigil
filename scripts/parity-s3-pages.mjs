// The pages P25 added (task 11b), each opened from the demo in the light and the dark theme: a picture of it, the
// WCAG 2.1 A / AA rules axe-core can judge (0 violation nodes allowed), and its data - a page whose grids hold no row
// and that draws no chart (only empty-state words) FAILs, and every empty-state paragraph a page shows is printed.
//   node scripts/parity-s3-pages.mjs <cdp port> <base url/> <axe.min.js> <shots folder>
// Prints 'ok' / 'FAIL' per theme and page, then 'total: <pages> page(s), <failed> failed, <nodes> violation node(s)';
// exits 1 when a page failed. Run by scripts/parity-s3-pages.sh.
import fs from 'node:fs';

const [port, base, axePath, out] = process.argv.slice(2);
const U = base.endsWith('/') ? base : base + '/';
const axeSrc = fs.readFileSync(axePath, 'utf8');
fs.mkdirSync(out, { recursive: true });

const inst = await (await fetch(U + 'api/instances')).json();
const rows = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const idOf = sfx => rows.find(r => String(r.name).endsWith(sfx))?.instance_id;
const sql01 = idOf('-onprem-sql01'), db01 = idOf('-azure-sqldb01');
if (!sql01 || !db01) { console.log(`FAIL the demo has no -onprem-sql01 (${sql01}) or -azure-sqldb01 (${db01})`); process.exit(1); }
const srv = 'demo-sqlsrv01', pool = 'pool-ledger';
const pages = [
  ['db-dbconfig', `#/mssqldb?i=${sql01}&db=Sales&dbtab=dbconfig`],
  ['db-snapshots', `#/mssqldb?i=${sql01}&db=Sales&dbtab=snapshots`],
  ['db-objexec', `#/mssqldb?i=${sql01}&db=Sales&dbtab=objexec`],
  ['db-performance', `#/mssqldb?i=${sql01}&db=Sales&dbtab=performance`],
  ['db-querystats', `#/mssqldb?i=${sql01}&db=Sales&dbtab=querystats`],
  ['performance-execstats', `#/performance?i=${sql01}`],
  ['procs-objexec', `#/mssqlprocs?i=${sql01}`],
  ['azuresummary', '#/azuresummary'],
  ['azuresummary-pool', `#/azuresummary?server=${srv}&pool=${pool}`],
  ['azureserver', `#/azureserver?server=${srv}`],
  ['azurepool', `#/azurepool?server=${srv}&pool=${pool}`],
  ['mssqlazure', `#/mssqlazure?i=${db01}`],
  ['mssqlpool', `#/mssqlpool?i=${db01}`],
  // P25 row 73 and (i): the database's Service Broker tab; the nodes' tabs (a bare node opens its first: the server's
  // Performance Summary, the pool's Pool)
  ['db-servicebroker', `#/mssqldb?i=${sql01}&db=Sales&dbtab=servicebroker`],
  ['azureserver-azuresummary', `#/azureserver?server=${srv}&ntab=azuresummary`],
  ['azurepool-azuresummary', `#/azurepool?server=${srv}&pool=${pool}&ntab=azuresummary`],
  ['azurepool-perfsummary', `#/azurepool?server=${srv}&pool=${pool}&ntab=perfsummary`],
  // the nodes' five other tabs, on the pooled databases' seeded requests, files and slow completions (Object Execution
  // shows its words: the statistics are not yet read on Azure SQL Database)
  ['azureserver-alerts', `#/azureserver?server=${srv}&ntab=alerts`],
  ['azureserver-slowqueries', `#/azureserver?server=${srv}&ntab=slowqueries`],
  ['azureserver-objexec', `#/azureserver?server=${srv}&ntab=objexec`],
  ['azureserver-running', `#/azureserver?server=${srv}&ntab=running`],
  ['azurepool-dbspace', `#/azurepool?server=${srv}&pool=${pool}&ntab=dbspace`],
];

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let seq = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++seq; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
// rendered = the shell replaced its "Loading..." paragraph and no part of the page still says Loading
const settled = async (ms = 15000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m || !m.children.length) return false;
      return ![...m.querySelectorAll('p.empty, p')].some(p => /^Loading/.test(p.textContent.trim())); })()`);
    if (ok) { await sleep(600); return true; }
    await sleep(150);
  }
  return false;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(800);

let failed = 0, nodes = 0, walked = 0;
for (const theme of ['light', 'dark']) {
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const [name, hash] of pages) {
    walked++;
    await cmd('Page.navigate', { url: U + hash }); await sleep(250); await cmd('Page.reload'); await sleep(250);
    if (!(await settled())) { failed++; console.log(`FAIL ${theme} ${name}: the page did not render in 15 s`); continue; }
    const seen = await ev(`(() => { const m = document.querySelector('main');
      const rowsDrawn = [...m.querySelectorAll('table tbody tr')].filter(tr => !tr.querySelector('td.empty, .empty')).length;
      const charts = m.querySelectorAll('.uplot, canvas, svg.chart').length;
      const empties = [...m.querySelectorAll('p.empty, .empty')].map(e => e.textContent.trim().replace(/\\s+/g, ' ').slice(0, 120)).filter(Boolean);
      return { rowsDrawn, charts, empties, h: Math.max(document.documentElement.scrollHeight, 1000) }; })()`);
    await cmd('Runtime.evaluate', { expression: axeSrc });
    const res = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] })
      .then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, t: (v.nodes[0]?.target ?? []).join(' ') }))))`, true));
    const n = res.reduce((a, v) => a + v.n, 0); nodes += n;
    const shot = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true, clip: { x: 0, y: 0, width: 1500, height: Math.min(seen.h, 6000), scale: 1 } });
    const file = `${out}/${name}-${theme}.png`;
    fs.writeFileSync(file, Buffer.from(shot.result?.data ?? '', 'base64'));
    const data = seen.rowsDrawn > 0 || seen.charts > 0;
    if (!data || n > 0) failed++;
    console.log(`${data && n === 0 ? 'ok  ' : 'FAIL'} ${theme} ${name}: ${seen.rowsDrawn} row(s), ${seen.charts} chart(s), axe ${n} node(s)${n ? ' (' + res.map(v => `${v.id} x${v.n} at ${v.t}`).join('; ').slice(0, 300) + ')' : ''}, shot ${file}${data ? '' : ' - NO DATA: only empty-state words'}`);
    for (const e of seen.empties) console.log(`   empty-state: ${e}`);
  }
}
// control audit row X1: on -sql01's Schema tab, each database link opens that database's Snapshot Summary on the SQL
// Server database page (#/mssqldb ... dbtab=snapshots), none the PostgreSQL drill (#/db); Sales must be among them
{
  walked++;
  await cmd('Page.navigate', { url: U + `#/schema?i=${sql01}` }); await sleep(250); await cmd('Page.reload'); await sleep(250);
  if (!(await settled())) { failed++; console.log('FAIL schema-dblink: the Schema tab did not render in 15 s'); }
  else {
    const l = await ev(`(() => [...document.querySelectorAll('main table a')].map(a => ({ t: a.textContent.trim(), h: a.getAttribute('href') ?? '' }))
      .filter(x => /^#\\/(db|mssqldb)\\?/.test(x.h)))()`);
    const bad = l.filter(x => { const q = new URLSearchParams(x.h.split('?')[1] ?? '');
      return !x.h.startsWith('#/mssqldb?') || q.get('dbtab') !== 'snapshots' || q.get('db') !== x.t; });
    const sales = l.some(x => x.t === 'Sales');
    if (bad.length || !sales) failed++;
    console.log(`${!bad.length && sales ? 'ok  ' : 'FAIL'} schema-dblink: ${l.length} database link(s), Sales ${sales ? 'present' : 'MISSING'}, ${bad.length} not to the Snapshot Summary${bad.length ? ': ' + bad.slice(0, 3).map(x => `${x.t} -> ${x.h}`).join('; ') : ''}`);
  }
}
console.log(`total: ${walked} page(s), ${failed} failed, ${nodes} violation node(s)`);
ws.close();
process.exit(failed ? 1 : 0);
