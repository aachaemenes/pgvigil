// B24 OWN's pages in the browser (proof-b24own-pages.sh): the switch 'Show pgvigil's own sessions (n hidden)', the
// 'pgvigil' mark, own=1 kept across the snapshot steps, the figures' words, the alert page's reads. Its cases and their
// expected results: proof-b24own-pages.sh's header (the staged read T and its rows).
//   OP_U / OP_PW (a UI user), OP_MS (the SQL Server instance id), OP_PG (the PostgreSQL instance id), OP_SHOTS (a
//   folder: the SHOTS case saves the five pages' pictures there; unset = no SHOTS case)
//   node scripts/own-pages-check.mjs <cdp port> <base url/>
// The page contract (the design's O1-O3, FOLD O5-O8): the switch is input[type=checkbox][data-own-switch] in a label
// reading "Show pgvigil's own sessions (n hidden)"; a shown own row holds span.own-mark 'pgvigil'; a figure counted from
// the server's summary says "includes n of pgvigil's own"; a read from before the flag says, in p.own-note, "this read
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
const ids = list => ev(`(() => { const want = ${JSON.stringify(list.map(String))}; const cells = [...document.querySelectorAll('main table.grid tbody td')];
  return Object.fromEntries(want.map(w => { const td = cells.find(c => c.textContent.trim() === w || c.textContent.trim().startsWith(w + ' '));
    return [w, td ? (td.closest('tr').querySelector('.own-mark')?.textContent.trim() || 'listed') : 'absent']; })); })()`);
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
  const def = r['70001'] === 'absent' && r['70002'] === 'absent' && r['70003'] === 'listed' && r['70004'] === 'listed' && r['70005'] === 'pgvigil';
  check('O1', def && !s.on && /\(2 hidden\)/.test(s.label) && t.includes("includes 3 of pgvigil's own"), `by default: ${JSON.stringify(r)}, the switch '${s.label}', 'includes 3' ${t.includes("includes 3 of pgvigil's own")}`);
  await tick();
  const k = await keys(), r2 = await ids([70001, 70002]);
  check('O1 switch', k.own === '1' && r2['70001'] === 'pgvigil' && r2['70002'] === 'pgvigil', `ticked: own=${k.own}, ${JSON.stringify(r2)}`);
  await clickText('Earlier');
  const k2 = await keys(), t2 = await text();
  await clickText('Latest');
  const k3 = await keys(), r3 = await ids([70001, 70002, 70003, 70004, 70005]), t3 = await text();
  check('O1 steps', k2.own === '1' && k3.own === '1' && Object.values(r3).every(v => v !== 'absent'), `Earlier: own=${k2.own}; Latest: own=${k3.own}, ${JSON.stringify(r3)}`);
  check('O9', t2.includes(NOTE) && !t3.includes(NOTE), `the read before T says it: ${t2.includes(NOTE)}; read T does not: ${!t3.includes(NOTE)}`);
});
await run('O2', async () => {
  await go(`#/mssql_running?i=${E.OP_MS}`); if (await noSwitch('O2')) return;
  const r = await ids([901, 902, 903, 904, 905]), s = await sw(), t = await text();
  const def = r['901'] === 'absent' && r['902'] === 'absent' && r['903'] === 'listed' && r['904'] === 'listed' && r['905'] === 'pgvigil';
  check('O2', def && /\(2 hidden\)/.test(s.label) && t.includes("includes 3 of pgvigil's own"), `by default: ${JSON.stringify(r)}, the switch '${s.label}', 'includes 3' ${t.includes("includes 3 of pgvigil's own")}`);
  await tick();
  reqs.length = 0;
  await clickText('Earlier');
  const sent = reqs.filter(u => u.includes('/api/mssql/running'));
  await clickText('Latest');
  const r2 = await ids([901, 902]), k = await keys();
  check('O2 steps', sent.length > 0 && sent.every(u => /[?&]own=1(&|$)/.test(u)) && k.own === '1' && r2['901'] === 'pgvigil' && r2['902'] === 'pgvigil',
    `the reads after Earlier: ${JSON.stringify(sent.map(u => u.replace(/^.*\?/, '?')))}; Latest: own=${k.own}, ${JSON.stringify(r2)}`);
});
await run('O2b', async () => {
  await go(`#/mssql_waiting?i=${E.OP_MS}`); if (await noSwitch('O2b')) return;
  const r = await ids([902, 903, 905]), s = await sw(), t = await text();
  check('O2b', r['902'] === 'absent' && r['903'] === 'listed' && r['905'] === 'pgvigil' && /\(1 hidden\)/.test(s.label) && t.includes("pgvigil's own tasks are left out unless the switch is on"),
    `${JSON.stringify(r)}, the switch '${s.label}', the wait-types line ${t.includes("pgvigil's own tasks are left out unless the switch is on")}`);
});
await run('O2c', async () => {
  await go(`#/waiting?i=${E.OP_PG}`); if (await noSwitch('O2c')) return;
  const r = await ids([70002, 70005]), s = await sw();
  check('O2c', r['70002'] === 'absent' && r['70005'] === 'pgvigil' && /\(1 hidden\)/.test(s.label), `${JSON.stringify(r)}, the switch '${s.label}'`);
});
await run('O2d', async () => {
  await go(`#/mssqlqueries?i=${E.OP_MS}`);
  const t = await text(), r = await ids([901, 902]);
  check('O2d', /Active queries[^]*\(2 hidden\)/.test(t) && r['901'] === 'absent' && r['902'] === 'absent', `'(2 hidden)' by Active queries: ${/Active queries[^]*\(2 hidden\)/.test(t)}; ${JSON.stringify(r)}`);
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
