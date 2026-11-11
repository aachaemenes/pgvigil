// Accessibility check of the web UI with axe-core over a headless Chromium (CDP): every root tab and every
// tab of two PostgreSQL instances and of two SQL Server instances, in the light and the dark theme, against the WCAG 2.1 A and AA rules (Section 508
// points at WCAG 2.0 AA; 2.1 AA covers it). Usage:
//   node scripts/a11y-check.mjs <cdp port> <base url/> <path to axe.min.js> [<json out>]
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil demo ... -serve -listen 127.0.0.1:<port>
// Prints one line per page checked and a table of the violations (rule, impact, nodes, pages); the JSON
// out holds every violation with its nodes. The exit code is 0 when every page rendered and axe ran on
// it; the caller judges the violation count (scripts/proof-a11y.sh).
const [port, U, axePath, outPath] = process.argv.slice(2);
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const inst = await (await fetch(U + 'api/instances')).json();
const rows = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const pick = (pred) => rows.find(pred);
const onprem = pick(r => r.platform === 'onprem') ?? rows[0];
const cloud = pick(r => r.platform === 'rds') ?? pick(r => r.platform === 'aurora') ?? rows[rows.length - 1];
// an Aurora instance with Performance Insights and Serverless v2 rows in the demo (the Load tab and the Capacity section render
// their charts there, not the PI-off paragraph), and the instance with the compare regressions (the Compare drill page)
const aurora = pick(r => String(r.name).endsWith('aurora-reporting01')) ?? cloud;
const regress = pick(r => String(r.name).endsWith('rds-orders01')) ?? cloud;
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async (ms = 12000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    // rendered = the shell replaced its "Loading..." paragraph; an honest empty state ("No rows yet") is a rendered page too
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^Loading/.test(e.textContent)) && m.children.length > 0; })()`);
    if (ok) { await sleep(300); return true; }
    await sleep(150);
  }
  return false;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const tabsOf = async (hash) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(300); await settled();
  // every page of the scope: the strip shows one group of tabs, its data-all lists them all
  return await ev(`(() => { const t = document.querySelector('#tabs'); return t.dataset.all ? JSON.parse(t.dataset.all) : [...t.querySelectorAll('a')].map(a => a.getAttribute('href')); })()`);
};
const rootTabs = await tabsOf('#/summary');
const instTabs = await tabsOf(`#/summary?i=${onprem.instance_id}`);
const pages = [...rootTabs];
for (const t of instTabs) { pages.push(t.replace(/i=\d+/, `i=${onprem.instance_id}`)); pages.push(t.replace(/i=\d+/, `i=${cloud.instance_id}`)); }
for (const t of instTabs) if (/#\/(load|host|summary)\?/.test(t)) pages.push(t.replace(/i=\d+/, `i=${aurora.instance_id}`));
// a SQL Server instance has its own tabs: every one of them on the demo's primary (the pair's findings) and on the
// managed instance (no availability group, no Agent jobs: the empty states)
const sqlPrimary = pick(r => r.engine === 'sqlserver' && String(r.name).endsWith('sql01')) ?? pick(r => r.engine === 'sqlserver');
const sqlManaged = pick(r => r.engine === 'sqlserver' && String(r.name).endsWith('sql03') && r !== sqlPrimary);
let sqlPages = 0;
for (const x of [sqlPrimary, sqlManaged]) {
  if (!x) continue;
  for (const t of await tabsOf(`#/summary?i=${x.instance_id}`)) { pages.push(t.replace(/i=\d+/, `i=${x.instance_id}`)); sqlPages++; }
}
console.log(`SQL Server pages in the check: ${sqlPages}`);
// the drill pages the tab strip does not list: the Compare page (under Statements) on the instance with regressions
pages.push(`#/compare?i=${regress.instance_id}&w=7d`);
// the DBADash door's instance page (the demo's repository and its second instance)
pages.push('#/dbadash?dr=dbadash-demo&di=2');
// the Memory tab on the instance with pg_buffercache and temp spills, the Pooler tab on the one with a PgBouncer (hidden elsewhere)
const erp = pick(r => String(r.name).endsWith('onprem-erp01')) ?? onprem;
const crm = pick(r => String(r.name).endsWith('aurora-crm01')) ?? cloud;
pages.push(`#/memory?i=${erp.instance_id}`);
pages.push(`#/pooler?i=${crm.instance_id}`);
// the pooler traced (task 128): the Pooler tab with clients, servers and a trace, and Running queries' pooler marks
const hr = pick(r => String(r.name).endsWith('onprem-hr01')) ?? onprem;
pages.push(`#/pooler?i=${hr.instance_id}`, `#/activity?i=${hr.instance_id}`);
const all = []; let failed = 0; const perRule = new Map();
// the status style is remembered per origin too: every page in the solid style (the default), and the pages that carry
// status cells again in the quiet one
const statusPages = pages.filter(h => /^#\/(summary|perfsummary|dbadash|alerts)\b/.test(h));
for (const [style, list] of [['solid', pages], ['quiet', statusPages]])
for (const theme of ['light', 'dark']) {
  // the theme is remembered per origin: set it on a page of the UI (not on about:blank), and pin the media query too
  await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(300); await settled();
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); localStorage.setItem('pgvigil.status', ${JSON.stringify(style)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const hash of list) {
    await cmd('Page.navigate', { url: U + hash }); await sleep(250);
    const ok = await settled();
    if (!ok) { failed++; console.log(`FAIL render ${style} ${theme} ${hash}`); continue; }
    await cmd('Runtime.evaluate', { expression: axeSrc });
    const res = await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify({ v: r.violations.map(v => ({ id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.map(n => ({ target: n.target, html: n.html.slice(0, 160), summary: n.failureSummary?.slice(0, 200) })) })), passes: r.passes.length }))`, true);
    const r = JSON.parse(res);
    const n = r.v.reduce((a, v) => a + v.nodes.length, 0);
    console.log(`${n ? 'viol ' : 'ok   '}${style} ${theme} ${hash}: ${r.v.length} rule(s), ${n} node(s), ${r.passes} rules passed`);
    for (const v of r.v) {
      all.push({ theme, style, page: hash, ...v });
      const k = perRule.get(v.id) ?? { impact: v.impact, help: v.help, nodes: 0, pages: new Set() };
      k.nodes += v.nodes.length; k.pages.add(style + ' ' + theme + ' ' + hash); perRule.set(v.id, k);
    }
  }
}
console.log('');
console.log('rule | impact | nodes | pages | help');
for (const [rule, k] of [...perRule.entries()].sort((a, b) => b[1].nodes - a[1].nodes)) console.log(`${rule} | ${k.impact} | ${k.nodes} | ${k.pages.size} | ${k.help}`);
console.log(`total: ${perRule.size} rule(s), ${all.reduce((a, v) => a + v.nodes.length, 0)} node(s) over ${pages.length * 2} page renders; ${failed} page(s) failed to render`);
if (outPath) fs.writeFileSync(outPath, JSON.stringify({ pages, violations: all }, null, 1));
ws.close();
process.exit(failed ? 1 : 0);
