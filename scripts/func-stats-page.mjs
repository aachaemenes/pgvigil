// The Procedures page's Functions and Triggers sections in a headless Chromium (CDP), with axe-core on the page with
// the Extremes box ticked, in the light and the dark theme. Usage:
//   node scripts/func-stats-page.mjs <cdp port> <base url/> <path to axe.min.js> <instance id> [server]
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil serve ... -listen 127.0.0.1:<port> -no-login
// The instance is one whose store holds scalar functions with each of the four inlining marks and a DML and a
// database DDL trigger (scripts/proof-mssql-func-stats.sh serves its own); 'server': a server DDL trigger too. Per
// theme: the Functions grid with its line, an 'inlining' column holding 'not inlineable', 'inlining off', a blank and
// 'not read', and no spilled-pages column; the Triggers grid with a 'scope' column and the spilled pages; the
// Extremes box adds the extremes to both (none of spilled pages on the functions); axe (WCAG 2.1 A and AA). One line
// per check; the exit code is 0 when every check held and axe found no violation node.
const [port, U, axePath, inst, srv] = process.argv.slice(2);
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
// what the browser itself reported (an uncaught exception, console.error, a failed request): said when a page does not draw
const errs = [];
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') errs.push(`exception: ${d.params?.exceptionDetails?.exception?.description ?? d.params?.exceptionDetails?.text ?? ''}`.slice(0, 300));
  if (d.method === 'Runtime.consoleAPICalled' && d.params?.type === 'error') errs.push(`console.error: ${(d.params.args ?? []).map(a => a.value ?? a.description ?? '').join(' ')}`.slice(0, 300));
  if (d.method === 'Log.entryAdded' && d.params?.entry?.level === 'error') errs.push(`log: ${d.params.entry.text} ${d.params.entry.url ?? ''}`.slice(0, 300));
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
let bad = 0;
const check = (ok, words) => { console.log(`${ok ? 'ok  ' : 'FAIL'} ${words}`); if (!ok) bad++; return ok; };
// stuck: a grid did not draw, so nothing below can be read - what the page shows and what the browser reported, then the end
const stuck = async () => {
  console.log(`  the page: ${await ev('location.href')}`);
  console.log(`  its headings: ${JSON.stringify(await ev(`[...document.querySelectorAll('main h2, main h3')].map(x => x.textContent.slice(0, 50))`))}`);
  console.log(`  it reads: ${JSON.stringify(await ev(`(document.querySelector('main')?.innerText ?? 'no main element').slice(0, 600)`))}`);
  console.log(`  the browser reported: ${errs.length ? errs.slice(0, 6).join(' || ') : 'nothing'}`);
  const api = `${U}api/mssql/procs?instance=${inst}&w=6h&part=functions`;
  console.log(`  the page's own fetch of ${api}: ${await ev(`fetch(${JSON.stringify(api)}).then(async r => r.status + ' ' + (await r.text()).slice(0, 200)).catch(e => 'failed: ' + e)`, true)}`);
  console.log(`func-stats page: ${bad} check(s) FAILED`);
  process.exit(1);
};
// until: the page's own state, asked until it holds (a read redraws the section) or the time is up
const until = async (expr, ms = 20000) => { const t = Date.now(); while (Date.now() - t < ms) { if (await ev(expr)) return true; await sleep(150); } return false; };
// the first grid after the heading whose text starts with the words: its header labels, its body rows and the
// section's line (the p.meta right after the heading)
const gridOf = heading => `(() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent.startsWith(${JSON.stringify(heading)})); if (!h) return null;
  const line = h.nextElementSibling?.matches('p.meta') ? h.nextElementSibling.textContent : '';
  let n = h.nextElementSibling; while (n && !(n.matches('table.grid') || n.querySelector('table.grid'))) n = n.nextElementSibling;
  const t = n && (n.matches('table.grid') ? n : n.querySelector('table.grid')); if (!t) return null;
  const heads = [...t.querySelectorAll('thead tr:first-child th .th-label')].map(x => x.textContent.trim());
  const rows = [...t.querySelectorAll('tbody tr')].map(r => [...r.children].map(c => c.textContent.trim()));
  return { heads, rows, line }; })()`;
const tick = words => ev(`(() => { const l = [...document.querySelectorAll('main .toolbar label')].find(l => l.textContent.trim() === ${JSON.stringify(words)}); if (!l) return false; l.querySelector('input').click(); return true; })()`);
const axe = async where => {
  await ev(axeSrc + '; "ok"');
  const res = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, nodes: v.nodes.length, first: (v.nodes[0]?.html ?? '').slice(0, 160) }))))`, true));
  const nodes = res.reduce((a, v) => a + v.nodes, 0);
  check(nodes === 0, `${where}: axe, ${res.length} rule(s), ${nodes} node(s)${res.map(v => ` [${v.id} x${v.nodes}: ${v.first}]`).join('')}`);
};
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Log.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const EXT = ['min CPU (ms)', 'max CPU (ms)', 'min duration (ms)', 'max duration (ms)', 'min logical reads', 'max logical reads', 'min physical reads', 'max physical reads', 'min writes', 'max writes'];
const SPILL = ['Total spilled pages', 'Avg spilled pages'], SPILLX = ['min spilled pages', 'max spilled pages'];
const F = 'Functions (scalar, run without inlining)', T = 'Triggers';
for (const theme of ['light', 'dark']) {
  // the theme and the page's remembered boxes are per origin: set on a page of the UI, the boxes forgotten; then a
  // full load of the page from about:blank, so the theme just set is read at the start
  await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(500);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); sessionStorage.clear(); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  await cmd('Page.navigate', { url: `${U}#/mssqlprocs?i=${inst}` }); await sleep(300);
  check(await until(`location.hash.startsWith('#/mssqlprocs')`, 5000), `${theme} Procedures: the page's address is the Procedures tab's`);
  const fq = gridOf(F), tq = gridOf(T);
  if (!check(await until(`!!(${fq}) && !!(${tq})`), `${theme} Procedures: the Functions and the Triggers grids drew`)) await stuck();
  let f = await ev(fq), t = await ev(tq);
  check(/lists no table-valued function and no scalar function the server inlined/.test(f.line), `${theme} Functions: the section's line says what the view leaves out`);
  const im = f.heads.indexOf('inlining');
  const marks = new Set(f.rows.map(r => r[im]));
  check(im >= 0 && ['not inlineable', 'inlining off', '', 'not read'].every(m => marks.has(m)), `${theme} Functions: an 'inlining' column holding the four forms (${JSON.stringify([...marks])})`);
  check(!SPILL.some(c => f.heads.includes(c)), `${theme} Functions: no spilled-pages column (${f.heads.length} columns)`);
  const sc = t.heads.indexOf('scope'), scopes = new Set(t.rows.map(r => r[sc]));
  check(sc >= 0 && SPILL.every(c => t.heads.includes(c)) && scopes.has('database') && scopes.has('') && (!srv || scopes.has('server')),
    `${theme} Triggers: a 'scope' column (${JSON.stringify([...scopes])}) and the spilled pages`);
  check(!EXT.some(c => f.heads.includes(c) || t.heads.includes(c)), `${theme} Procedures: no extreme column with the Extremes box off`);
  await tick('Extremes');
  await until(`(${fq})?.heads.includes('max CPU (ms)') && (${tq})?.heads.includes('max spilled pages')`, 20000);
  f = await ev(fq); t = await ev(tq);
  const mx = f.heads.indexOf('max CPU (ms)');
  check(EXT.every(c => f.heads.includes(c)) && !SPILLX.some(c => f.heads.includes(c)) && f.rows.some(r => r[mx] !== '' && r[mx] !== 'not read'),
    `${theme} Functions: Extremes on shows its ${EXT.length} columns with values, no spilled-pages extreme`);
  check([...EXT, ...SPILLX].every(c => t.heads.includes(c)), `${theme} Triggers: Extremes on shows its ${EXT.length + SPILLX.length} columns`);
  await axe(`${theme} Procedures, Extremes on`);
}
console.log(bad ? `func-stats page: ${bad} check(s) FAILED` : 'func-stats page: OK');
process.exit(bad ? 1 : 0);
