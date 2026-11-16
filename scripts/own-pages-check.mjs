// B24 OWN's pages in the browser (proof-b24own-pages.sh): the switch 'Show pgvigil's own sessions (n hidden)', the
// 'pgvigil' mark, own=1 kept across the snapshot steps, the figures' words, the alert page's reads. Its cases and their
// expected results: proof-b24own-pages.sh's header (the staged read T and its rows).
//   OP_U / OP_PW (a UI user), OP_MS (the SQL Server instance id), OP_PG (the PostgreSQL instance id), OP_SHOTS (a
//   folder: the SHOTS case saves the five pages' pictures there; unset = no SHOTS case)
//   node scripts/own-pages-check.mjs <cdp port> <base url/>
// The page contract (the design's O1-O3, FOLD O5-O8): the switch is input[type=checkbox][data-own-switch] in a label
// reading "Show pgvigil's own sessions (n hidden)"; a shown own row holds span.own-mark 'pgvigil'; a figure counted from
// the server's summary says "n of the sessions above are pgvigil's own" (waiting: "n of the waiting tasks above"); each id cell of a read that hides is own.ts
// withMark's span[data-own-id="<id>"]; a read from before the flag says, in p.own-note, "this read
// is from before pgvigil marked its own sessions: nothing in it is hidden"; the wait-types grid says "pgvigil's own tasks
// are left out unless the switch is on".
// Prints one 'ok <case>: ...' line per case, or 'FAIL <case>: ...', and exits 1 when one failed.
const [port, base] = process.argv.slice(2);
const E = process.env;
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(), reqs = [];
ws.onmessage = m => {
  const d = JSON.parse(m.data);
  if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); }
  if (d.method === 'Network.requestWillBeSent') reqs.push(d.params.request.url);
};
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => {
  const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true, userGesture: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
};
await send('Network.enable');
await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false });
let failed = 0;
const check = (name, okay, detail) => { console.log(`${okay ? 'ok  ' : 'FAIL'} ${name}: ${detail}`); if (!okay) failed++; return okay; };
const ready = `!!document.querySelector('main section, main table.grid, main .empty-grid, main p.error') && !document.querySelector('main > p.empty[role=status]')`;
const settle = async () => { for (let i = 0; i < 60; i++) { await sleep(250); if (await ev(ready)) break; } await sleep(1500); };
const go = async h => { await send('Page.navigate', { url: 'about:blank' }); await sleep(150); await send('Page.navigate', { url: base + h }); await settle(); };
const keys = async () => Object.fromEntries(new URLSearchParams((await ev('location.hash')).split('?')[1] ?? ''));
// ids: each id's row among the id cells of the reads that hide (own.ts withMark: span[data-own-id] in the session / pid
// column) - 'pgvigil' (marked), 'listed' or 'absent'; an absent id that another cell of a main grid holds (a blocker
// column, another grid of the page) says where: 'absent (also in <heading> / <column>)'
const ids = list => ev(`(() => { const want = ${JSON.stringify(list.map(String))};
  const idCells = [...document.querySelectorAll('main table.grid tbody td [data-own-id]')];
  const heading = t => { let h = null; for (const x of document.querySelectorAll('main h2, main h3')) if (x.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING) h = x; return h ? h.textContent.replace(/\\s+/g, ' ').trim().slice(0, 40) : '?'; };
  return Object.fromEntries(want.map(w => {
    const c = idCells.find(x => x.dataset.ownId === w);
    if (c) return [w, c.closest('tr').querySelector('.own-mark')?.textContent.trim() || 'listed'];
    const other = [...document.querySelectorAll('main table.grid tbody td')].find(td => td.textContent.trim() === w || td.textContent.trim().startsWith(w + ' '));
    if (!other) return [w, 'absent'];
    const t = other.closest('table'), th = t.querySelectorAll('thead th')[other.cellIndex];
    return [w, 'absent (also in ' + heading(t) + ' / ' + (th ? th.textContent.trim() : '?') + ')']; })); })()`);
// gone: not among the id cells of the reads that hide ('absent', or 'absent (also in ...)': another grid of the page, such
// as who pins the xmin horizon, may list the session)
const gone = v => typeof v === 'string' && v.startsWith('absent');
const sw = () => ev(`(() => { const i = document.querySelector('input[type=checkbox][data-own-switch]'); return i ? { on: i.checked, label: i.closest('label')?.textContent.replace(/\\s+/g, ' ').trim() } : null; })()`);
const text = () => ev(`document.querySelector('main')?.textContent.replace(/\\s+/g, ' ') ?? ''`);
const tick = async () => { await ev(`document.querySelector('input[type=checkbox][data-own-switch]').click(); 'ok'`); await settle(); };
const clickText = async t => { const ok = await ev(`(() => { const b = [...document.querySelectorAll('main button, main a')].find(x => x.textContent.trim() === ${JSON.stringify(t)}); if (!b) return false; b.click(); return true; })()`); await settle(); return ok; };
const run = async (name, f) => { try { await f(); } catch (e) { check(name, false, `threw: ${String(e?.message ?? e).slice(0, 300)}`); } };
const noSwitch = async name => { if (await sw() === null) { check(name, false, `no own switch (no input[data-own-switch]); the rows: ${JSON.stringify(await ids(name.startsWith('O1') || name === 'O2c' ? [70001, 70002, 70003, 70004, 70005] : [901, 902, 903, 904, 905]))}`); return true; } return false; };

await go('#/about');
const lg = await ev(`fetch('/api/login', { method: 'POST', headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, body: JSON.stringify({ username: ${JSON.stringify(E.OP_U)}, password: ${JSON.stringify(E.OP_PW)} }) }).then(r => r.status)`);
if (lg !== 200) { console.log(`FAIL login: ${lg}`); process.exit(1); }
const NOTE = 'this read is from before pgvigil marked its own sessions: nothing in it is hidden';

await run('O1', async () => {
  await go(`#/activity?i=${E.OP_PG}`); if (await noSwitch('O1')) return;
  const r = await ids([70001, 70002, 70003, 70004, 70005]), s = await sw(), t = await text();
  const def = gone(r['70001']) && gone(r['70002']) && r['70003'] === 'listed' && r['70004'] === 'listed' && r['70005'] === 'pgvigil';
  check('O1', def && !s.on && /\(2 hidden\)/.test(s.label) && /3 of the sessions above are pgvigil's own/.test(t), `by default: ${JSON.stringify(r)}, the switch '${s.label}', '3 of the sessions above' ${/3 of the sessions above are pgvigil's own/.test(t)}`);
  await ev(`document.querySelector('input[type=checkbox][data-own-switch]').focus(); 'ok'`);
  await tick();
  const k = await keys(), r2 = await ids([70001, 70002]);
  const focused = await ev(`!!document.activeElement?.matches('input[type=checkbox][data-own-switch]')`);
  check('O1 switch', k.own === '1' && r2['70001'] === 'pgvigil' && r2['70002'] === 'pgvigil' && focused, `ticked: own=${k.own}, ${JSON.stringify(r2)}, the focus back on the switch ${focused}`);
  await clickText('Earlier');
  const k2 = await keys(), t2 = await text();
  await clickText('Latest');
  const k3 = await keys(), r3 = await ids([70001, 70002, 70003, 70004, 70005]), t3 = await text();
  check('O1 steps', k2.own === '1' && k3.own === '1' && Object.values(r3).every(v => !gone(v)), `Earlier: own=${k2.own}; Latest: own=${k3.own}, ${JSON.stringify(r3)}`);
  check('O9', t2.includes(NOTE) && !t3.includes(NOTE), `the read before T says it: ${t2.includes(NOTE)}; read T does not: ${!t3.includes(NOTE)}`);
});
await run('O2', async () => {
  await go(`#/mssql_running?i=${E.OP_MS}`); if (await noSwitch('O2')) return;
  const r = await ids([901, 902, 903, 904, 905]), s = await sw(), t = await text();
  const def = gone(r['901']) && gone(r['902']) && r['903'] === 'listed' && r['904'] === 'listed' && r['905'] === 'pgvigil';
  check('O2', def && /\(2 hidden\)/.test(s.label) && /3 of the sessions above are pgvigil's own/.test(t), `by default: ${JSON.stringify(r)}, the switch '${s.label}', '3 of the sessions above' ${/3 of the sessions above are pgvigil's own/.test(t)}`);
  await tick();
  reqs.length = 0;
  await clickText('Earlier');
  const sent = reqs.filter(u => u.includes('/api/mssql/running')), tE = await text();
  await clickText('Latest');
  const r2 = await ids([901, 902]), k = await keys();
  check('O2 steps', sent.length > 0 && sent.every(u => /[?&]own=1(&|$)/.test(u)) && k.own === '1' && r2['901'] === 'pgvigil' && r2['902'] === 'pgvigil' && tE.includes(NOTE),
    `the reads after Earlier: ${JSON.stringify(sent.map(u => u.replace(/^.*\?/, '?')))}, its note ${tE.includes(NOTE)}; Latest: own=${k.own}, ${JSON.stringify(r2)}`);
});
await run('O2e', async () => {
  // review part 2 M1: on SQL Server Running queries the slider moves without a navigation; ticking the switch keeps the
  // snapshot it was on
  await go(`#/mssql_running?i=${E.OP_MS}`); if (await noSwitch('O2e')) return;
  await clickText('Earlier');
  const before = await ev(`document.querySelector('b.snap-time')?.textContent ?? ''`);
  await tick();
  const k = await keys(), after = await ev(`document.querySelector('b.snap-time')?.textContent ?? ''`);
  check('O2e', k.own === '1' && !!k.at && before !== '' && after === before, `Earlier: '${before}'; ticked: own=${k.own} at=${k.at ?? '(none)'}, '${after}'`);
});
await run('O2f', async () => {
  // review part 2 L5: with a wait filter the count is said to be the snapshot's
  await go(`#/mssql_running?i=${E.OP_MS}&wait=LCK_M_S`); if (await noSwitch('O2f')) return;
  const s = await sw();
  check('O2f', /\(2 hidden in this snapshot\)/.test(s.label), `wait=LCK_M_S: the switch '${s.label}'`);
});
await run('O2b', async () => {
  await go(`#/mssql_waiting?i=${E.OP_MS}`); if (await noSwitch('O2b')) return;
  const r = await ids([902, 903, 905]), s = await sw(), t = await text();
  const words2 = /2 of the waiting tasks above are pgvigil's own/.test(t);
  check('O2b', gone(r['902']) && r['903'] === 'listed' && r['905'] === 'pgvigil' && /\(1 hidden\)/.test(s.label) && t.includes("pgvigil's own tasks are left out unless the switch is on") && words2,
    `${JSON.stringify(r)}, the switch '${s.label}', the wait-types line ${t.includes("pgvigil's own tasks are left out unless the switch is on")}, '2 of the waiting tasks above' ${words2}`);
});
await run('O2c', async () => {
  await go(`#/waiting?i=${E.OP_PG}`); if (await noSwitch('O2c')) return;
  const r = await ids([70002, 70005]), s = await sw();
  check('O2c', gone(r['70002']) && r['70005'] === 'pgvigil' && /\(1 hidden\)/.test(s.label), `${JSON.stringify(r)}, the switch '${s.label}'`);
});
await run('O2d', async () => {
  await go(`#/mssqlqueries?i=${E.OP_MS}`);
  const t = await text(), r = await ids([901, 902]);
  check('O2d', /Active queries[^]*\(2 hidden\)/.test(t) && gone(r['901']) && gone(r['902']), `'(2 hidden)' by Active queries: ${/Active queries[^]*\(2 hidden\)/.test(t)}; ${JSON.stringify(r)}`);
});
await run('O3', async () => {
  await go('#/alerts?w=7d');
  const a = await ev(`(() => { const x = [...document.querySelectorAll('main a')].find(l => /#\\/alert\\?/.test(l.getAttribute('href') || '')); return x ? x.getAttribute('href') : null; })()`);
  if (!a) { check('O3', false, 'the demo alerts list has no alert link'); return; }
  reqs.length = 0;
  await go(a.replace(/^.*#/, '#')); await sleep(2000);
  const sent = reqs.filter(u => /\/api\/(mssql\/running|activity)\?/.test(u));
  const link = await ev(`(() => { const l = [...document.querySelectorAll('main a')].find(x => x.textContent.trim() === 'Running queries'); return l ? l.getAttribute('href') : null; })()`);
  check('O3', sent.length > 0 && sent.every(u => /[?&]own=1(&|$)/.test(u)) && /[?&]own=1(&|$)/.test(link ?? ''), `the alert ${a}: its reads ${JSON.stringify(sent.map(u => u.replace(/^.*\/api\//, '')))}, its Running queries link ${link}`);
});

// SHOTS (the design's P2; only with OP_SHOTS = a folder): the five own pages with the switch off, in the light and the
// dark theme, saved as own-<page>-<theme>.png
if (E.OP_SHOTS) await run('SHOTS', async () => {
  const fs = await import('node:fs');
  const pages = [['running-pg', `#/activity?i=${E.OP_PG}`], ['running-mssql', `#/mssql_running?i=${E.OP_MS}`],
    ['waiting-pg', `#/waiting?i=${E.OP_PG}`], ['waiting-mssql', `#/mssql_waiting?i=${E.OP_MS}`], ['queries-mssql', `#/mssqlqueries?i=${E.OP_MS}`]];
  const made = [];
  for (const theme of ['light', 'dark']) {
    await go('#/about');
    await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
    await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
    for (const [name, h] of pages) {
      await go(h);
      const d = await send('Page.captureScreenshot', { format: 'png' });
      if (d.result?.data) { fs.writeFileSync(`${E.OP_SHOTS}/own-${name}-${theme}.png`, Buffer.from(d.result.data, 'base64')); made.push(`${name}-${theme}`); }
    }
  }
  check('SHOTS', made.length === pages.length * 2, `${made.length} of ${pages.length * 2} pictures in ${E.OP_SHOTS}: ${made.join(', ')}`);
});

console.log(failed ? `${failed} case(s) failed` : 'all cases ok');
process.exit(failed ? 1 : 0);
