// The Plan cache and Procedures pages' column groups in a headless Chromium (CDP), with axe-core on the pages as a
// reader with every group on sees them, in the light and the dark theme. Usage:
//   node scripts/cache-spread-page.mjs <cdp port> <base url/> <path to axe.min.js> <instance id>
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil serve ... -listen 127.0.0.1:<port> -no-login
// The instance is one whose store holds statements with extremes and at least one diagnostic, and a procedure
// (scripts/proof-mssql-cache-spread.sh serves its own). Per theme it reads the Plan cache page as it first shows (the
// four group boxes, 'Slow and frequent' and 'with a diagnostic' unticked; a diagnostics column; no group column),
// ticks the four groups (their columns appear, holding values), ticks 'with a diagnostic' (only rows with one stay)
// and runs axe (WCAG 2.1 A and AA) on that state; then the Procedures page's Extremes box the same way. One line per
// check; the exit code is 0 when every check held and axe found no violation node.
const [port, U, axePath, inst] = process.argv.slice(2);
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
// stuck: a page's grid did not draw, so nothing below can be read - what the page shows and what the browser
// reported, then the end
const stuck = async () => {
  console.log(`  the page: ${await ev('location.href')}`);
  console.log(`  its headings: ${JSON.stringify(await ev(`[...document.querySelectorAll('main h2, main h3')].map(x => x.textContent.slice(0, 50))`))}`);
  console.log(`  it reads: ${JSON.stringify(await ev(`(document.querySelector('main')?.innerText ?? 'no main element').slice(0, 600)`))}`);
  console.log(`  the browser reported: ${errs.length ? errs.slice(0, 6).join(' || ') : 'nothing'}`);
  const api = `${U}api/mssql/plancache?instance=${inst}&w=1h`;
  console.log(`  the page's own fetch of ${api}: ${await ev(`fetch(${JSON.stringify(api)}).then(async r => r.status + ' ' + (await r.text()).slice(0, 200)).catch(e => 'failed: ' + e)`, true)}`);
  console.log(`cache-spread page: ${bad} check(s) FAILED`);
  process.exit(1);
};
// until: the page's own state, asked until it holds (a read redraws the section) or the time is up
const until = async (expr, ms = 20000) => { const t = Date.now(); while (Date.now() - t < ms) { if (await ev(expr)) return true; await sleep(150); } return false; };
// the first grid after the heading whose text starts with the words: its header labels and its body rows
const gridOf = heading => `(() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent.startsWith(${JSON.stringify(heading)})); if (!h) return null;
  let n = h.nextElementSibling; while (n && !(n.matches('table.grid') || n.querySelector('table.grid'))) n = n.nextElementSibling;
  const t = n && (n.matches('table.grid') ? n : n.querySelector('table.grid')); if (!t) return null;
  const heads = [...t.querySelectorAll('thead tr:first-child th .th-label')].map(x => x.textContent.trim());
  const rows = [...t.querySelectorAll('tbody tr')].map(r => [...r.children].map(c => c.textContent.trim()));
  return { heads, rows }; })()`;
const boxes = `Object.fromEntries([...document.querySelectorAll('main .toolbar label')].filter(l => l.querySelector('input[type=checkbox]')).map(l => [l.textContent.trim(), l.querySelector('input').checked]))`;
const tick = words => ev(`(() => { const l = [...document.querySelectorAll('main .toolbar label')].find(l => l.textContent.trim() === ${JSON.stringify(words)}); if (!l) return false; l.querySelector('input').click(); return true; })()`);
const axe = async where => {
  await ev(axeSrc + '; "ok"');
  const res = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, nodes: v.nodes.length, first: (v.nodes[0]?.html ?? '').slice(0, 160) }))))`, true));
  const nodes = res.reduce((a, v) => a + v.nodes, 0);
  check(nodes === 0, `${where}: axe, ${res.length} rule(s), ${nodes} node(s)${res.map(v => ` [${v.id} x${v.nodes}: ${v.first}]`).join('')}`);
};
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Log.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const GROUPS = { Times: ['plan generation', 'CLR time (ms)', 'peak CPU (ms/s)'],
  Extremes: ['min CPU (ms)', 'max CPU (ms)', 'min duration (ms)', 'max duration (ms)', 'min physical reads', 'max physical reads', 'min rows', 'max rows', 'min spilled pages', 'max spilled pages'],
  'Memory grants': ['min grant (KB)', 'max used grant (KB)', 'min ideal grant (KB)', 'max ideal grant (KB)'],
  Parallelism: ['min DOP', 'min reserved threads', 'max reserved threads', 'min used threads', 'max used threads'] };
const groupCols = Object.values(GROUPS).flat();
const PROC = ['min CPU (ms)', 'max CPU (ms)', 'min duration (ms)', 'max duration (ms)', 'min logical reads', 'max logical reads', 'min physical reads', 'max physical reads',
  'min writes', 'max writes', 'min spilled pages', 'max spilled pages'];
for (const theme of ['light', 'dark']) {
  // the theme and the pages' remembered boxes are per origin: set on a page of the UI, the boxes forgotten
  await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(500);
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); sessionStorage.clear(); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  // a full load of the page (from about:blank, so the theme just set is read at the start): a hash change followed
  // by Page.reload can reload the page before the hash is committed (the dark pass of run 3 stayed on the Summary)
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(200);
  await cmd('Page.navigate', { url: `${U}#/mssqlplancache?i=${inst}` }); await sleep(300);
  check(await until(`location.hash.startsWith('#/mssqlplancache')`, 5000), `${theme} Plan cache: the page's address is the Plan cache's`);
  const stmts = gridOf('Statements over the range');
  if (!check(await until(`!!(${stmts})`), `${theme} Plan cache: the statements' grid drew`)) await stuck();
  let b = await ev(boxes), g = await ev(stmts);
  const off = ['Times', 'Extremes', 'Memory grants', 'Parallelism', 'Slow and frequent', 'with a diagnostic'];
  check(off.every(k => b[k] === false), `${theme} Plan cache: the six boxes are there and unticked at first (${JSON.stringify(b)})`);
  check(g.heads.includes('diagnostics') && !groupCols.some(c => g.heads.includes(c)), `${theme} Plan cache: a diagnostics column and no group column at first (${g.heads.length} columns)`);
  const before = g.rows.length;
  for (const k of Object.keys(GROUPS)) await tick(k);
  await until(`(${stmts})?.heads.includes('max used threads')`, 5000);
  g = await ev(stmts);
  for (const [k, cols] of Object.entries(GROUPS)) check(cols.every(c => g.heads.includes(c)), `${theme} Plan cache: ${k} on shows ${cols.join(', ')}`);
  const at = c => g.heads.indexOf(c);
  const filled = c => g.rows.filter(r => r[at(c)] !== '' && r[at(c)] !== 'not read').length;
  check(filled('max CPU (ms)') > 0 && filled('plan generation') > 0 && filled('max used threads') > 0, `${theme} Plan cache: the groups hold values (max CPU on ${filled('max CPU (ms)')} of ${g.rows.length} rows, plan generation on ${filled('plan generation')}, max used threads on ${filled('max used threads')})`);
  const withDiag = g.rows.filter(r => r[at('diagnostics')] !== '').length;
  check(withDiag > 0 && g.rows.some(r => /^Row count variance \(/.test(r[at('diagnostics')])), `${theme} Plan cache: ${withDiag} of ${g.rows.length} rows carry a diagnostic, one of them 'Row count variance'`);
  await tick('with a diagnostic');
  await until(`(${stmts})?.rows.length === ${withDiag}`, 5000);
  g = await ev(stmts);
  check(g.rows.length === withDiag && g.rows.length < before && g.rows.every(r => r[g.heads.indexOf('diagnostics')] !== ''), `${theme} Plan cache: 'with a diagnostic' keeps ${g.rows.length} of ${before} rows, each with one`);
  b = await ev(boxes);
  check(['Times', 'Extremes', 'Memory grants', 'Parallelism', 'with a diagnostic'].every(k => b[k] === true) && b['Slow and frequent'] === false, `${theme} Plan cache: the boxes say what is on`);
  await axe(`${theme} Plan cache, every group on`);

  await cmd('Page.navigate', { url: `${U}#/mssqlprocs?i=${inst}` }); await sleep(300);
  const procs = gridOf('Procedures (');
  if (!check(await until(`!!(${procs})`), `${theme} Procedures: the grid drew`)) await stuck();
  b = await ev(boxes); g = await ev(procs);
  check(b.Extremes === false && !PROC.some(c => g.heads.includes(c)), `${theme} Procedures: the Extremes box unticked and no extreme column at first`);
  await tick('Extremes');
  await until(`(${procs})?.heads.includes('max spilled pages')`, 20000);
  g = await ev(procs);
  check(PROC.every(c => g.heads.includes(c)) && g.rows.some(r => r[g.heads.indexOf('max CPU (ms)')] !== '' && r[g.heads.indexOf('max CPU (ms)')] !== 'not read'), `${theme} Procedures: Extremes on shows its ${PROC.length} columns, with values`);
  await axe(`${theme} Procedures, Extremes on`);
}
console.log(bad ? `cache-spread page: ${bad} check(s) FAILED` : 'cache-spread page: OK');
process.exit(bad ? 1 : 0);
