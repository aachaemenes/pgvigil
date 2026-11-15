// The Collection Health tab (B6.2; DBA Dash 4.25.0's Checks > Collection Health) over the served demo
// (scripts/proof-collection-health.sh runs it): CH6 the tab at the root, a tag folder and an instance - its heading,
// its columns by name and in DBA Dash's order (an instance's tab without Instance; 'Row per collection' without
// Instance and Status Reason, with Instances and Failing Instances), the Status filter (each of DBA Dash's four words
// alone shows only its rows), the Show picker's two labels and its default ('Row per collection per instance'); CH7
// every landing - the Summary's Collection Health cell (a PostgreSQL and a SQL Server row) on that instance's tab,
// Instances on the per-instance rows of its collection, Failed and Errors on the error list of the row (its row count =
// the number clicked), Last Failure on the list over the API's errors_from .. errors_to, an Instance name on its own
// tab, and the grid's statuses = the API's (one judgement); the charts Runs and Cost drawn, Import Lag's place in words. The fixtures (proof-collection-health.sh): fx-chcrit
// (3 failures in a row, 40 minutes since its success: critical), fx-chrate (5 of 10 failed, the last failed:
// critical by rate), fx-chskip (skipped only: N/A).
// usage: node scripts/collection-health-check.mjs <cdp port> <base url ending in />
const [port, U] = process.argv.slice(2);
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async expr => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });

let fails = 0, oks = 0;
const say = (ok, row, what) => { if (ok) oks++; else fails++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${row}: ${what}`); };
const table = async p => { const t = await (await fetch(U + 'api/' + p)).json(); return t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]]))); };
const insts = (await table('instances')).filter(r => r.is_active !== false);
const byName = n => insts.find(r => r.name === n);
const crit = byName('fx-chcrit');
const ms = insts.find(r => r.engine === 'sqlserver');
const tag = insts.flatMap(r => r.tags ?? []).find(t => String(t).includes(':')) ?? insts.flatMap(r => r.tags ?? [])[0];
// the API's rows (null when there is no API: the red run)
const api = async params => {
  try {
    const r = await fetch(U + 'api/collectionhealth?' + new URLSearchParams({ part: 'collections', from: new Date(Date.now() - 86400e3).toISOString(), ...params }));
    if (!r.ok) return null;
    const d = await r.json(); const t = d.collections;
    return t.rows.map(x => Object.fromEntries(t.columns.map((c, i) => [c, x[i]])));
  } catch { return null; }
};
const word = { critical: 'Critical', warning: 'Warning', 'n/a': 'N/A', ok: 'OK' };
const route = h => { const m = /^#\/([^?]*)\??(.*)$/.exec(h ?? ''); return m ? { tab: m[1], q: new URLSearchParams(m[2]) } : { tab: '', q: new URLSearchParams() }; };

// open a hash and wait for the tab's heading; the grid's headers and rows read back
const open = async hash => {
  await cmd('Page.navigate', { url: 'about:blank' });
  await cmd('Page.navigate', { url: U + hash });
  for (let i = 0; i < 100; i++) {
    if (await ev(`[...document.querySelectorAll('main h2')].some(h => h.textContent.trim() === 'Collection Health') && !!document.querySelector('main table thead')`)) break;
    await sleep(150);
  }
  await sleep(300);
  return ev(`(() => {
    const sec = [...document.querySelectorAll('main section')].find(s => s.querySelector('h2')?.textContent.trim() === 'Collection Health');
    if (!sec) return null;
    const t = sec.querySelector('table'), clean = s => s.replace(/[\\u25b2\\u25bc]/g, '').trim();
    const heads = [...(t?.querySelectorAll('thead th') ?? [])].map(th => clean(th.textContent));
    const rows = [...(t?.querySelectorAll('tbody tr') ?? [])].map(tr => {
      const cells = [...tr.children];
      const o = {};
      heads.forEach((h, i) => { const c = cells[i]; o[h] = { text: c?.textContent.trim() ?? '', links: Object.fromEntries([...(c?.querySelectorAll('a[data-land]') ?? [])].map(a => [a.dataset.land, a.getAttribute('href')])) }; });
      return o;
    });
    const show = sec.querySelector('#ch-show');
    return { heads, rows, show: show ? { value: show.value, labels: [...show.options].map(o => o.textContent.trim()) } : null,
      status: [...sec.querySelectorAll('input[name=ch-status]')].map(i => ({ v: i.value, on: i.checked })) };
  })()`);
};
const setStatus = only => ev(`(() => { for (const i of document.querySelectorAll('main input[name=ch-status]')) { i.checked = ${JSON.stringify(only)} === null || i.value === ${JSON.stringify(only)}; i.dispatchEvent(new Event('change', { bubbles: true })); } return true; })()`);
const setShow = v => ev(`(() => { const s = document.querySelector('main #ch-show'); if (!s) return false; s.value = ${JSON.stringify(v)}; s.dispatchEvent(new Event('change', { bubbles: true })); return true; })()`);

const COLS = ['Instance', 'Collection', 'Status', 'Status Reason', 'Runs', 'Succeeded %', 'Failed %', 'Failed % 24hrs', 'Succeeded', 'Partial', 'Failed',
  'Failures In A Row', 'Last Run', 'Last Success', 'Last Failure', 'Avg Duration (ms)', 'Max Duration (ms)', 'Rows', 'Errors', 'Thresholds'];
const BYCOLL = ['Collection', 'Status', 'Instances', 'Failing Instances', ...COLS.slice(4)];
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const LAG = 'pgvigil writes each collection in its own run: there is no import step to lag';

// CH6 the tab at three levels
for (const [lvl, hash, want] of [['root', '#/collectionhealth?w=24h', COLS], ['tag ' + tag, `#/collectionhealth?tag=${encodeURIComponent(tag ?? '')}&w=24h`, COLS],
  ['instance fx-chcrit', `#/collectionhealth?i=${crit?.instance_id}&w=24h`, COLS.slice(1)]]) {
  const p = await open(hash);
  say(!!p, 'CH6 ' + lvl, p ? 'the tab drew' : 'no Collection Health tab (no h2 or no grid)');
  if (!p) continue;
  say(eq(p.heads, want), 'CH6 ' + lvl + ' columns', p.heads.join(' | '));
  say(eq(p.show?.labels, ['Row per collection per instance', 'Row per collection']) && p.show?.value === 'instance', 'CH6 ' + lvl + ' Show', JSON.stringify(p.show));
  say(eq(p.status.map(s => s.v).sort(), ['critical', 'na', 'ok', 'warning']) && p.status.every(s => s.on), 'CH6 ' + lvl + ' Status filter', JSON.stringify(p.status));
  // the charts: Runs and Cost drawn, Import Lag in words where DBA Dash shows it (the lead's 23:2x words), never dropped silently
  const charts = await ev(`(() => { const sec = [...document.querySelectorAll('main section')].find(s => s.querySelector('h2')?.textContent.trim() === 'Collection Health');
    return { titles: [...(sec?.querySelectorAll('.chart-title, figcaption, h3') ?? [])].map(e => e.textContent.trim()), lag: (sec?.textContent ?? '').includes(${JSON.stringify(LAG)}) }; })()`);
  say(charts.titles.some(t => /^Runs/.test(t)) && charts.titles.some(t => /Time spent collecting/.test(t)) && charts.lag, 'CH6 ' + lvl + ' charts', JSON.stringify(charts));
}
// the Status filter and the Show picker at the root
{
  const p0 = await open('#/collectionhealth?w=24h');
  if (p0) {
    for (const [v, w] of [['critical', 'Critical'], ['warning', 'Warning'], ['na', 'N/A'], ['ok', 'OK']]) {
      await setStatus(v); await sleep(800);
      const p = await ev(`[...document.querySelectorAll('main section table tbody tr')].length`);
      const st = await ev(`(() => { const t = document.querySelector('main section table'); const hs = [...t.querySelectorAll('thead th')].map(th => th.textContent.trim()); const k = hs.indexOf('Status'); return [...t.querySelectorAll('tbody tr')].map(tr => tr.children[k]?.textContent.trim()); })()`);
      say(st.every(s => s === w) && (v !== 'critical' || st.length > 0), `CH6 Status ${w} alone`, `${p} row(s): ${[...new Set(st)].join(', ') || 'none'}`);
    }
    await setStatus(null); await setShow('collection'); await sleep(1000);
    const heads = await ev(`[...document.querySelectorAll('main section table thead th')].map(th => th.textContent.replace(/[\\u25b2\\u25bc]/g, '').trim())`);
    say(eq(heads, BYCOLL), 'CH6 Row per collection columns', heads.join(' | '));
  } else say(false, 'CH6 Status / Show', 'no tab');
}

// CH7 the landings
{
  // the Summary's cell, one PostgreSQL row (fx-chcrit) and one SQL Server row
  await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + '#/summary?w=24h' });
  for (let i = 0; i < 100 && !(await ev(`!!document.querySelector('main table thead')`)); i++) await sleep(150);
  await sleep(1500);
  for (const r of [crit, ms].filter(Boolean)) {
    const h = await ev(`(() => { for (const t of document.querySelectorAll('main table')) { const hs = [...t.querySelectorAll('thead th')].map(th => th.textContent.trim()); const k = hs.indexOf('Collection Health'); if (k < 0) continue;
      for (const tr of t.querySelectorAll('tbody tr')) if (tr.children[0]?.textContent.trim() === ${JSON.stringify(r.name)}) return tr.children[k]?.querySelector('a')?.getAttribute('href') ?? 'no link'; } return 'no cell'; })()`);
    const g = route(h);
    say(g.tab === 'collectionhealth' && g.q.get('i') === String(r.instance_id), `CH7 Summary cell ${r.engine} ${r.name}`, h);
  }
  const rows = await api({}), mine = rows?.filter(x => String(x.instance_id) === String(crit?.instance_id) && x.collection === 'activity') ?? [];
  const p = await open('#/collectionhealth?w=24h');
  const row = p?.rows.find(x => x.Instance?.text === 'fx-chcrit' && x.Collection?.text === 'activity');
  say(!!row, 'CH7 fx-chcrit activity row', row ? `${row.Status.text} | ${row['Status Reason'].text}` : 'not in the grid');
  say(!!rows && mine.length === 1 && mine[0].status === 'critical', 'CH7 API fx-chcrit', rows ? JSON.stringify(mine[0] ?? null).slice(0, 200) : 'no API');
  // the grid's statuses = the API's, every row drawn
  if (p && rows) {
    const A = new Map(rows.map(x => [`${insts.find(i => String(i.instance_id) === String(x.instance_id))?.name}|${x.collection}`, word[x.status] ?? x.status]));
    const bad = p.rows.filter(x => A.get(`${x.Instance.text}|${x.Collection.text}`) !== x.Status.text);
    say(bad.length === 0 && p.rows.length > 0, 'CH7 grid = API statuses', `${p.rows.length} row(s), ${bad.length} differ${bad.length ? ': ' + bad.slice(0, 3).map(x => `${x.Instance.text}/${x.Collection.text} ${x.Status.text}`).join(', ') : ''}`);
  } else say(false, 'CH7 grid = API statuses', 'no grid or no API');
  if (row) {
    const inst = route(row.Instance.links.instance);
    say(inst.tab === 'collectionhealth' && inst.q.get('i') === String(crit.instance_id), 'CH7 Instance name', row.Instance.links.instance ?? 'no link');
    for (const [col, land] of [['Failed', 'failed'], ['Errors', 'errors']]) {
      const href = row[col].links[land], n = Number(row[col].text.replace(/[^0-9]/g, ''));
      if (!href) { say(false, `CH7 ${col}`, 'no link'); continue; }
      await cmd('Page.navigate', { url: U + href }); await sleep(2000);
      const listed = await ev(`document.querySelectorAll('main .ch-errors tbody tr').length`);
      say(listed === n && n > 0, `CH7 ${col} -> the error list`, `${n} clicked, ${listed} listed (${href})`);
    }
    const lf = route(row['Last Failure'].links.lastfailure);
    const ef = mine[0]?.errors_from, et = mine[0]?.errors_to;
    say(lf.tab === 'collectionhealth' && !!ef && Date.parse(lf.q.get('from')) === Date.parse(ef) && Date.parse(lf.q.get('to')) === Date.parse(et), 'CH7 Last Failure window',
      `${row['Last Failure'].links.lastfailure ?? 'no link'} vs API ${ef} .. ${et}`);
  } else for (const c of ['Instance name', 'Failed', 'Errors', 'Last Failure window']) say(false, 'CH7 ' + c, 'no fx-chcrit row');
  // Instances (Row per collection) -> the per-instance rows of that collection
  const p2 = await open('#/collectionhealth?w=24h&grain=collection');
  const r2 = p2?.rows.find(x => x.Collection?.text === 'activity');
  const ih = route(r2?.Instances?.links?.instances);
  say(ih.tab === 'collectionhealth' && ih.q.get('grain') === 'instance' && ih.q.get('collection') === 'activity', 'CH7 Instances', r2?.Instances?.links?.instances ?? 'no link');
  // the rate and the skip fixtures as the API judges them
  const one = n => rows?.find(x => String(x.instance_id) === String(byName(n)?.instance_id) && x.collection === 'activity');
  say(one('fx-chrate')?.status === 'critical' && /% failed/.test(one('fx-chrate')?.status_reason ?? ''), 'CH7 API fx-chrate', JSON.stringify(one('fx-chrate') ?? null).slice(0, 160));
  say(one('fx-chskip')?.status === 'n/a', 'CH7 API fx-chskip', JSON.stringify(one('fx-chskip') ?? null).slice(0, 160));
}
console.log(`collection health: ${oks} ok; ${fails} FAIL`);
ws.close();
process.exit(fails ? 1 : 0);
