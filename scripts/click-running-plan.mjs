// The demo's running plans, clicked (scripts/proof-demo-running-plan.sh part C): on each SQL Server instance's Running
// queries (#/mssql_running?i=N) a request's Plan button lists the plans pgvigil holds for its hashes; the 'running'
// row's Open draws the plan (the 'Query plan:' viewer: Statement 1, an operator grid, no error box) and the status line
// says demo data. On a PostgreSQL instance's Running queries (#/activity?i=N) the page says PostgreSQL keeps no plan of
// a running statement. Usage (a headless Chromium on the CDP port, the demo served at the base url):
//   node scripts/click-running-plan.mjs <cdp port> <base url/> <sql server ids, comma separated> <postgresql id>
// Prints one line per instance; exit 1 on a FAIL.
const [port, U, msIds, pgId] = process.argv.slice(2);
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
const sleep = ms => new Promise(r => setTimeout(r, ms));
// until(expr): the expression's value once truthy, or null after ms
const until = async (expr, ms = 15000) => {
  const t = Date.now();
  while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(200); }
  return null;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
const go = async (hash) => {
  await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + hash }); await sleep(300);
  return until(`(() => { const m = document.querySelector('main'); const e = m?.querySelector('p.empty');
    return !!m?.querySelector('h2') && !(e && /^Loading/.test(e.textContent)); })()`);
};
let fails = 0;
const fail = (w) => { fails++; console.log(`FAIL ${w}`); };

for (const ms of msIds.split(',').filter(Boolean)) {
  if (!await go(`#/mssql_running?i=${ms}`)) { fail(`#/mssql_running?i=${ms}: the page never drew`); continue; }
  // the request grid's Plan buttons (planSourcesCol): each lists the sources of its row's hashes
  const n = await ev(`document.querySelectorAll('main button[aria-label^="Plans of query hash"]').length`);
  if (!n) { fail(`#/mssql_running?i=${ms}: no Plan button in the request grid (${await ev(`document.querySelector('main')?.innerText.slice(0, 300)`)})`); continue; }
  let drawn = null;
  for (let k = 0; k < n && !drawn; k++) {
    await ev(`document.querySelectorAll('main button[aria-label^="Plans of query hash"]')[${k}].click()`);
    const listed = await until(`(() => { const b = document.querySelector('main .running-plans'); const t = b?.innerText ?? '';
      return /Reading/.test(t) || !t ? null : t; })()`);
    const open = await ev(`!!document.querySelector('main .running-plans button[aria-label="Open: the running plan"]')`);
    if (!open) { console.log(`     #/mssql_running?i=${ms} Plan ${k + 1} of ${n}: no running plan listed (${String(listed).replace(/\s+/g, ' ').slice(0, 200)})`); continue; }
    await ev(`document.querySelector('main .running-plans button[aria-label="Open: the running plan"]').click()`);
    drawn = await until(`(() => { const d = document.querySelector('dialog.fd-viewer[open]'); if (!d) return null;
      const h3 = d.querySelector('h3')?.textContent ?? ''; const ops = d.querySelectorAll('table tbody tr').length;
      const err = [...d.querySelectorAll('p.error')].map(e => e.textContent).join(' | ');
      const stmt = [...d.querySelectorAll('h4')].some(h => /^Statement 1/.test(h.textContent));
      const status = document.querySelector('main .running-plans p[role="status"]')?.textContent ?? '';
      return { h3, ops, err, stmt, status }; })()`);
    if (!drawn) console.log(`     #/mssql_running?i=${ms} Plan ${k + 1}: Open drew no viewer (${await ev(`document.querySelector('main .running-plans p[role="status"]')?.textContent ?? ''`)})`);
  }
  if (!drawn) { fail(`#/mssql_running?i=${ms}: no Plan button of ${n} lands on a drawn plan`); continue; }
  const why = [];
  if (!/^Query plan: /.test(drawn.h3)) why.push(`the viewer's title ${JSON.stringify(drawn.h3)}`);
  if (!drawn.stmt) why.push('no Statement 1');
  if (drawn.ops < 1) why.push('no operator row');
  if (drawn.err) why.push(`an error box: ${drawn.err}`);
  if (!/demo data/.test(drawn.status)) why.push(`the status line does not say demo data: ${JSON.stringify(drawn.status)}`);
  if (why.length) fail(`#/mssql_running?i=${ms}: ${why.join('; ')}`);
  else console.log(`ok   #/mssql_running?i=${ms}: Plan -> running -> Open drew '${drawn.h3}', ${drawn.ops} operator row(s); status: ${drawn.status}`);
  await ev(`document.querySelector('dialog.fd-viewer[open]')?.close()`);
}

if (pgId) {
  if (!await go(`#/activity?i=${pgId}`)) fail(`#/activity?i=${pgId}: the page never drew`);
  else {
    const said = await ev(`/PostgreSQL keeps no plan of a running statement/.test(document.querySelector('main')?.innerText ?? '')`);
    if (said) console.log(`ok   #/activity?i=${pgId}: 'PostgreSQL keeps no plan of a running statement'`);
    else fail(`#/activity?i=${pgId}: the page does not say 'PostgreSQL keeps no plan of a running statement'`);
  }
}
ws.close();
console.log(fails ? `click-running-plan: ${fails} FAIL` : 'click-running-plan: 0 FAIL');
process.exit(fails ? 1 : 0);
