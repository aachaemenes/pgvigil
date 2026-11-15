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
// critical by rate), fx-chskip (skipped only: N/A), fx-chhour (one failure 10 minutes into the previous UTC hour: the
// Failed link's counted window). The review of B6.2, part b added: each status alone = the API's count, every row drawn,
// the tag and instance levels by their rows, Last Failure by the run's own times and opened, Instances opened, the
// words and pickers of #8 - #11, and a FAIL per named row on a red run.
// usage: CH_NOW=<the fixtures' clock, ISO UTC> CH_HOUR=<fx-chhour's hour, ISO UTC> node scripts/collection-health-check.mjs <cdp port> <base url ending in />
// (proof-collection-health.sh sets both from its one clock read: the rows grade the fixtures by their own times, never
// the check's clock - the review B6f3 #3 / #12)
const [port, U] = process.argv.slice(2);
const fxNow = Date.parse(process.env.CH_NOW ?? ''), fxHour = Date.parse(process.env.CH_HOUR ?? '');
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
    if (await ev(`[...document.querySelectorAll('main h2')].some(h => h.textContent.trim() === 'Collection Health') && !!document.querySelector('main section[data-drawn] .ch-grid table thead')`)) break;
    await sleep(150);
  }
  await sleep(300);
  return ev(`(() => {
    const sec = [...document.querySelectorAll('main section')].find(s => s.querySelector('h2')?.textContent.trim() === 'Collection Health');
    if (!sec) return null;
    const t = sec.querySelector('.ch-grid table');
    const heads = [...(t?.querySelectorAll('thead th') ?? [])].map(th => (th.querySelector('.th-label') ?? th).textContent.trim());
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
// drawnAs: the page's own mark that a draw with these statuses and this grain has ended (up to 15 s)
const drawnAs = async want => { for (let i = 0; i < 100; i++) { if (await ev(`document.querySelector('main section[data-drawn]')?.dataset.drawn === ${JSON.stringify(want)}`)) return true; await sleep(150); } return false; };
const setShow = v => ev(`(() => { const s = document.querySelector('main #ch-show'); if (!s) return false; s.value = ${JSON.stringify(v)}; s.dispatchEvent(new Event('change', { bubbles: true })); return true; })()`);

const COLS = ['Instance', 'Collection', 'Status', 'Status Reason', 'Runs', 'Succeeded %', 'Failed %', 'Failed % 24hrs', 'Succeeded', 'Partial', 'Failed', 'Import Failed',
  'Failures In A Row', 'Last Run', 'Last Success', 'Last Failure', 'Avg Duration (ms)', 'Max Duration (ms)',
  'Avg CPU (ms)', 'Max CPU (ms)', 'Total CPU (ms)', 'Avg Logical Reads', 'Total Logical Reads', 'Avg Import (ms)', 'Max Import (ms)', 'Rows', 'Errors', 'Thresholds'];
const BYCOLL = ['Collection', 'Status', 'Instances', 'Failing Instances', ...COLS.slice(4)];
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const LAG = 'pgvigil writes into the repository inside the run that collected: no queue stands between the two, so there is no import lag (Avg Import is the write\'s own time)';

// CH6 the tab at three levels
for (const [lvl, hash, want] of [['root', '#/collectionhealth?w=24h', COLS], ['tag ' + tag, `#/collectionhealth?tag=${encodeURIComponent(tag ?? '')}&w=24h`, COLS],
  ['instance fx-chcrit', `#/collectionhealth?i=${crit?.instance_id}&w=24h`, COLS.slice(1)]]) {
  const p = await open(hash);
  say(!!p, 'CH6 ' + lvl, p ? 'the tab drew' : 'no Collection Health tab (no h2 or no grid)');
  // no tab: each named row FAILs on its own, so a red run shows every row red (the review of B6.2, part b #3f)
  if (!p) { for (const r of ['columns', 'Show', 'Status filter', 'charts', 'rows']) say(false, `CH6 ${lvl} ${r}`, 'no tab'); continue; }
  say(eq(p.heads, want), 'CH6 ' + lvl + ' columns', p.heads.join(' | '));
  say(eq(p.show?.labels, ['Row per collection per instance', 'Row per collection']) && p.show?.value === 'instance', 'CH6 ' + lvl + ' Show', JSON.stringify(p.show));
  say(eq(p.status.map(s => s.v).sort(), ['critical', 'na', 'ok', 'warning']) && p.status.every(s => s.on), 'CH6 ' + lvl + ' Status filter', JSON.stringify(p.status));
  // the charts: Runs and Cost drawn, Import Lag in words where DBA Dash shows it (the lead's 23:2x words), never dropped silently
  const charts = await ev(`(() => { const sec = [...document.querySelectorAll('main section')].find(s => s.querySelector('h2')?.textContent.trim() === 'Collection Health');
    return { titles: [...(sec?.querySelectorAll('.chart-title, figcaption, h3') ?? [])].map(e => e.textContent.trim()), lag: (sec?.textContent ?? '').includes(${JSON.stringify(LAG)}) }; })()`);
  say(charts.titles.some(t => /^Runs/.test(t)) && charts.titles.some(t => /Time spent collecting/.test(t)) && charts.lag, 'CH6 ' + lvl + ' charts', JSON.stringify(charts));
  // the level's rows (the review of B6.2, part b #3c): at the tag every row's instance carries it; at fx-chcrit the rows
  // are the API's for that instance, status for status
  if (lvl.startsWith('tag ')) {
    const tagged = new Set(insts.filter(r => (r.tags ?? []).includes(tag)).map(r => r.name));
    const out = p.rows.filter(x => !tagged.has(x.Instance?.text));
    say(p.rows.length > 0 && out.length === 0, `CH6 ${lvl} rows`, `${p.rows.length} row(s), ${out.length} of an instance without the tag${out.length ? ': ' + out.slice(0, 3).map(x => x.Instance?.text).join(', ') : ''}`);
  } else if (lvl.startsWith('instance ')) {
    const a = await api({ instance: String(crit?.instance_id) }) ?? [];
    const got = p.rows.map(x => `${x.Collection.text}|${x.Status.text}`).sort(), want = a.map(x => `${x.collection}|${word[x.status] ?? x.status}`).sort();
    say(a.length > 0 && eq(got, want), `CH6 ${lvl} rows`, `page ${got.join(', ')} | API ${want.join(', ')}`);
  } else say(p.rows.length > 0, `CH6 ${lvl} rows`, `${p.rows.length} row(s)`);
}
// the Status filter and the Show picker at the root
const allRows = await api({});
{
  const p0 = await open('#/collectionhealth?w=24h');
  if (p0) {
    for (const [v, w] of [['critical', 'Critical'], ['warning', 'Warning'], ['na', 'N/A'], ['ok', 'OK']]) {
      await setStatus(v); await drawnAs(`${v}|instance`);
      const p = await ev(`document.querySelectorAll('main .ch-grid table tbody tr').length`);
      const st = await ev(`(() => { const t = document.querySelector('main .ch-grid table'); if (!t) return []; const hs = [...t.querySelectorAll('thead th')].map(th => (th.querySelector('.th-label') ?? th).textContent.trim()); const k = hs.indexOf('Status'); return [...t.querySelectorAll('tbody tr')].map(tr => tr.children[k]?.textContent.trim()); })()`);
      // as many rows as the API holds of that status, above 0 (the demo has each; the review of B6.2, part b #3a: an
      // error box or a page that sends a word the API refuses drew no grid and passed)
      const want = (allRows ?? []).filter(x => (x.status === 'n/a' ? 'na' : x.status) === v).length;
      say(st.every(s => s === w) && st.length > 0 && st.length === Math.min(want, 200), `CH6 Status ${w} alone`, `${p} row(s): ${[...new Set(st)].join(', ') || 'none'}; the API ${want}`);
    }
    await setStatus(null); await setShow('collection'); await drawnAs('critical,warning,na,ok|collection');
    const heads = await ev(`[...document.querySelectorAll('main .ch-grid table thead th')].map(th => (th.querySelector('.th-label') ?? th).textContent.trim())`);
    say(eq(heads, BYCOLL), 'CH6 Row per collection columns', heads.join(' | '));
    // CH16 (the review of B6g-1 part b #1): a PostgreSQL collection's row per collection says 'not read by pgvigil' in
    // its five cost cells, as its rows per instance do (collection names never cross engines)
    const rc = await ev(`(() => { const t = document.querySelector('main .ch-grid table'); const hs = [...t.querySelectorAll('thead th')].map(th => (th.querySelector('.th-label') ?? th).textContent.trim());
      return [...t.querySelectorAll('tbody tr')].map(tr => Object.fromEntries(hs.map((h, i) => [h, tr.children[i]?.textContent.trim() ?? '']))); })()`);
    const costCols = ['Total CPU (ms)', 'Avg CPU (ms)', 'Max CPU (ms)', 'Avg Logical Reads', 'Total Logical Reads'];
    const pgc = (rc ?? []).filter(r => !String(r['Collection']).startsWith('mssql_') && Number(String(r['Runs']).replace(/[^0-9]/g, '')) > 0);
    const pgcBad = pgc.filter(r => !costCols.every(k => r[k] === 'not read by pgvigil'));
    say(pgc.length > 0 && pgcBad.length === 0, 'CH16 a PostgreSQL collection per collection: the five cost cells say not read by pgvigil',
      `${pgc.length} collection(s), ${pgcBad.length} otherwise${pgcBad.length ? ': ' + pgcBad.slice(0, 3).map(r => r['Collection'] + ' [' + costCols.map(k => r[k]).join(' | ') + ']').join('; ') : ''}`);
  } else for (const r of ['Status Critical alone', 'Status Warning alone', 'Status N/A alone', 'Status OK alone', 'Row per collection columns']) say(false, 'CH6 ' + r, 'no tab');
}

// the page's own words and pickers (the review of B6.2, part b #8 - #11)
{
  // #9 no status ticked: the grid says so, the charts still drawn
  const p0 = await open('#/collectionhealth?w=24h');
  if (p0) {
    await ev(`(() => { for (const i of document.querySelectorAll('main input[name=ch-status]')) { i.checked = false; i.dispatchEvent(new Event('change', { bubbles: true })); } return true; })()`);
    await drawnAs('|instance');
    const t = await ev(`(() => { const sec = [...document.querySelectorAll('main section')].find(s => s.querySelector('h2')?.textContent.trim() === 'Collection Health');
      return { empty: (sec?.textContent ?? '').includes('No status is picked'), canvases: sec?.querySelectorAll('.chart canvas, .chart svg, .u-wrap').length ?? 0, note: (sec?.textContent ?? '').split('from the last success to the latest failure').length - 1 === 2 && !(sec?.textContent ?? '').includes('since the last success') }; })()`);
    say(t.empty && t.canvases > 0, 'CH6 no status ticked: the charts still drawn', JSON.stringify(t));
    // #10 the status rule in the docs' words: both halves measure from the last success to the latest failure (B6f3 #7)
    say(t.note, 'CH6 the status rule in docs/collection-health.md\'s words', String(t.note));
  } else for (const r of ['no status ticked: the charts still drawn', 'the status rule in docs/collection-health.md\'s words']) say(false, 'CH6 ' + r, 'no tab');
  // #8 a range of one whole hour: the charts' place says they are hourly
  const h0 = Math.floor(Date.now() / 3600e3) * 3600e3;
  const p1 = await open(`#/collectionhealth?from=${encodeURIComponent(new Date(h0 - 3600e3).toISOString())}&to=${encodeURIComponent(new Date(h0).toISOString())}`);
  const hourly = p1 ? await ev(`(document.querySelector('main')?.textContent ?? '').split('The charts are hourly').length - 1`) : 0;
  say(hourly === 2, 'CH6 one whole hour: the charts said hourly', `${hourly} chart place(s) say so`);
}

// CH16 (B6g-1): the cost cells themselves on the demo, a row per collection per instance over 24 hours. A SQL Server
// instance runs the mssql_ collections alone: each of its rows with a run holds its session's CPU and logical reads as
// numbers above 0; every PostgreSQL row says 'not read by pgvigil' in the five cost cells; a row with a success has an
// import time; the demo has no import failure.
{
  const p = await open('#/collectionhealth?w=24h');
  const num = c => { const t = (c?.text ?? '').replace(/[^0-9.]/g, ''); return t === '' ? NaN : Number(t); };
  const cost = ['Avg CPU (ms)', 'Max CPU (ms)', 'Total CPU (ms)', 'Avg Logical Reads', 'Total Logical Reads'];
  const ran = (p?.rows ?? []).filter(r => num(r['Runs']) > 0);
  const ms = ran.filter(r => r['Collection'].text.startsWith('mssql_')), pg = ran.filter(r => !r['Collection'].text.startsWith('mssql_'));
  const msBad = ms.filter(r => !cost.every(k => num(r[k]) > 0));
  say(ms.length > 0 && msBad.length === 0, 'CH16 SQL Server rows: CPU and logical reads as numbers above 0',
    `${ms.length} row(s) with a run, ${msBad.length} without${msBad.length ? ': ' + msBad.slice(0, 3).map(r => r['Instance'].text + ' ' + r['Collection'].text + ' [' + cost.map(k => r[k]?.text).join(' | ') + ']').join('; ') : ''}`);
  const pgBad = pg.filter(r => !cost.every(k => r[k]?.text === 'not read by pgvigil'));
  say(pg.length > 0 && pgBad.length === 0, 'CH16 PostgreSQL rows: the five cost cells say not read by pgvigil',
    `${pg.length} row(s) with a run, ${pgBad.length} otherwise${pgBad.length ? ': ' + pgBad.slice(0, 3).map(r => r['Instance'].text + ' ' + r['Collection'].text + ' [' + cost.map(k => r[k]?.text).join(' | ') + ']').join('; ') : ''}`);
  // the demo's own instances: the proof's fixtures (fx-...) write their hour rows by hand, with no import in them
  const wrote = ran.filter(r => num(r['Succeeded']) > 0 && !r['Instance'].text.startsWith('fx-'));
  const noImp = wrote.filter(r => !(num(r['Avg Import (ms)']) > 0 && num(r['Max Import (ms)']) > 0 && num(r['Max Import (ms)']) <= num(r['Max Duration (ms)'])));   // the longest import is inside the longest run (an average over failed runs too may be under it)
  say(wrote.length > 0 && noImp.length === 0, 'CH16 a demo row with a success has an import time, inside its longest run',
    `${wrote.length} demo row(s) with a success, ${noImp.length} without${noImp.length ? ': ' + noImp.slice(0, 3).map(r => r['Instance'].text + ' ' + r['Collection'].text + ' [' + r['Avg Import (ms)']?.text + ' avg, max ' + r['Max Import (ms)']?.text + ' of ' + r['Max Duration (ms)']?.text + ']').join('; ') : ''}`);
  const impFailed = ran.filter(r => num(r['Import Failed']) !== 0 && !r['Instance'].text.startsWith('fx-'));   // fx-chimport's are the proof's own (CH17)
  say(ran.length > 0 && impFailed.length === 0, 'CH16 Import Failed is 0 on the demo', `${ran.length} row(s) with a run, ${impFailed.length} demo row(s) with an import failure`);
}

// CH17 (the review of B6g-1 part b #2): fx-chimport - 3 failed runs, 2 of them at the write of collected rows. Failed
// reads 1 and Import Failed 2, and EACH links to the same list of its hours' errors, both kinds in it (DBA Dash links
// both counts to its errors: CollectionHealthView.cs L208-209)
{
  const p = await open('#/collectionhealth?w=24h');
  const row = (p?.rows ?? []).find(r => r['Instance']?.text === 'fx-chimport' && r['Collection']?.text === 'activity');
  say(!!row && row['Failed'].text === '1' && row['Import Failed'].text === '2', 'CH17 fx-chimport Failed 1, Import Failed 2',
    row ? `Failed ${row['Failed'].text}, Import Failed ${row['Import Failed'].text}` : 'not in the grid');
  // the two links open THE SAME list - the hours both counts are over (the review of B6g-1's folds #4: 'listed === 3'
  // alone passed whatever range Import Failed's link carried)
  const hf = row?.['Failed']?.links?.failed, hi = row?.['Import Failed']?.links?.importfailed;
  say(!!hf && !!hi && route(hf).q.get('from') === route(hi).q.get('from') && route(hf).q.get('to') === route(hi).q.get('to'), 'CH17 Import Failed opens the window Failed opens', `${hf ?? 'no link'} | ${hi ?? 'no link'}`);
  for (const [col, land] of [['Failed', 'failed'], ['Import Failed', 'importfailed']]) {
    const href = row?.[col]?.links?.[land];
    if (!href) { say(false, `CH17 ${col} -> the error list`, 'no link'); continue; }
    await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + href }); await sleep(2000);
    const listed = await ev(`document.querySelectorAll('main .ch-errors tbody tr').length`);
    say(listed === 3, `CH17 ${col} -> the error list`, `${listed} listed, the fixture's 3 errors (${href})`);
  }
}

// CH18-CH21 (B6g-2, N33 / N41; design G3): the Thresholds cell opens DBA Dash's Collection Health Thresholds dialog
// (CollectionHealthThresholdsDialog.cs) on a demo instance's activity row - its four 'Apply to' levels, its eight
// settings in DBA Dash's words, each 'Inherited:' at DBA Dash's default; on the demo door a level over every instance is
// off with the door's words; Don't monitor saved on this instance and collection makes the row N/A with its reason and
// its Thresholds cell 'set on this instance and collection', Inherit All + Save brings the row back; a refusal of the
// repository's function reaches the page in its words (409, 'refused: ...')
{
  const th = async (inst, coll) => ev(`(() => {
    const t = document.querySelector('main .ch-grid table'); if (!t) return false;
    const heads = [...t.querySelectorAll('thead th')].map(th => (th.querySelector('.th-label') ?? th).textContent.trim());
    const ki = heads.indexOf('Instance'), kc = heads.indexOf('Collection'), kt = heads.indexOf('Thresholds');
    const tr = [...t.querySelectorAll('tbody tr')].find(tr => tr.children[ki]?.textContent.trim() === ${JSON.stringify(inst)} && tr.children[kc]?.textContent.trim() === ${JSON.stringify(coll)});
    const b = tr?.children[kt]?.querySelector('button'); if (!b) return false; b.click(); return true; })()`);
  const dlg = () => ev(`(() => { const d = document.querySelector('dialog.act-dialog[open]'); if (!d) return null;
    return { title: d.querySelector('h3')?.textContent ?? '', scopes: [...d.querySelectorAll('#ch-th-scope option')].map(o => o.textContent),
      labels: [...d.querySelectorAll('tbody td label')].map(l => l.textContent.trim()), inherited: [...d.querySelectorAll('tbody td span.meta')].map(x => x.textContent),
      off: d.querySelector('button[type=submit]')?.getAttribute('aria-disabled') ?? '', text: d.textContent ?? '', msg: d.querySelector('p[role=status]')?.textContent ?? '' }; })()`);
  const until = async (f, ms = 10000) => { for (let i = 0; i < ms / 150; i++) { const v = await f(); if (v) return v; await sleep(150); } return null; };
  const loaded = () => until(async () => { const d = await dlg(); return d && d.inherited.length === 8 && d.inherited.every(x => x.startsWith('Inherited:')) ? d : null; });
  const p = await open('#/collectionhealth?w=24h');
  const row = (p?.rows ?? []).find(r => (r['Instance']?.text ?? '').startsWith('demo-') && r['Collection']?.text === 'activity');
  const inst = row?.['Instance']?.text ?? '';
  const opened = row ? await th(inst, 'activity') : false;
  const d0 = opened ? await loaded() : null;
  say(!!d0 && d0.title === 'Collection Health Thresholds' && JSON.stringify(d0.scopes) === JSON.stringify([`activity on ${inst}`, `All collections on ${inst}`, 'activity on all instances', 'All collections on all instances'])
    && JSON.stringify(d0.labels) === JSON.stringify(['Failed runs in a row', 'And failing for at least (minutes)', 'Failed runs in a row', 'And failing for at least (minutes)', 'Warning: failed or partly failed %', 'Critical: failed %', 'Only with at least this many runs', 'Don\'t monitor (always N/A)']),
    'CH18 the Thresholds cell opens the dialog: its four levels and eight settings in DBA Dash\'s words', d0 ? `${inst}: ${d0.scopes.join(' / ')} | ${d0.labels.join(' / ')}` : (row ? 'no dialog' : 'no demo activity row'));
  const defs = ['1', '10', '3', '30', '10', '50', '5', 'No'].map(v => `Inherited: ${v} (DBA Dash's default)`);
  say(!!d0 && JSON.stringify(d0.inherited) === JSON.stringify(defs), 'CH18 every value inherits DBA Dash\'s default', d0 ? d0.inherited.join(' | ') : 'no dialog');
  // a level over every instance: off on the demo door, its words in the dialog; back on at the instance's level
  // both levels over every instance (the review of B6g-2 #11: index 3 alone passed a door that refused only everything)
  for (const [ix, words] of [['2', 'activity on all instances'], ['3', 'All collections on all instances']]) {
    await ev(`(() => { const s = document.querySelector('#ch-th-scope'); if (s) { s.value = '${ix}'; s.dispatchEvent(new Event('change')); } })()`); await sleep(300);
    const d1 = await dlg();
    say(!!d1 && d1.off === 'true' && /reach past the demo's instances/.test(d1.text), `CH19 ${words}: Save off with the door\'s words`, d1 ? `aria-disabled ${d1.off}; ${(d1.text.match(/Not written here:[^.]*\./) ?? [''])[0]}` : 'no dialog');
  }
  await ev(`(() => { const s = document.querySelector('#ch-th-scope'); if (s) { s.value = '0'; s.dispatchEvent(new Event('change')); } })()`); await sleep(300);
  const d2 = await dlg();
  say(!!d2 && d2.off !== 'true', `CH19 activity on ${inst}: Save on`, d2 ? `aria-disabled '${d2.off}'` : 'no dialog');
  // Don't monitor ticked and Yes on this instance and collection, saved
  await ev(`(() => { const d = document.querySelector('dialog.act-dialog[open]'); const rows = [...d.querySelectorAll('tbody tr')].filter(tr => tr.querySelector('td'));
    const last = rows[rows.length - 1]; const [tick, val] = last.querySelectorAll('input'); tick.click(); if (!val.checked) val.click();
    d.querySelector('button[type=submit]').click(); })()`);
  const saved = await until(async () => { const d = await dlg(); return d && /^(done|not saved)/.test(d.msg.trim()) ? d : null; });
  say(!!saved && saved.msg.includes(`Saved for activity on ${inst}`), 'CH20 Don\'t monitor saved on this instance and collection', saved ? saved.msg.slice(0, 160) : 'no answer in 10 s');
  await ev(`[...document.querySelectorAll('dialog.act-dialog[open] button')].find(b => b.textContent === 'Close')?.click()`);
  const p2 = await open('#/collectionhealth?w=24h');
  const r2 = (p2?.rows ?? []).find(r => r['Instance']?.text === inst && r['Collection']?.text === 'activity');
  say(!!r2 && r2['Status']?.text === 'N/A' && r2['Status Reason']?.text === 'not monitored (its Collection Health threshold)' && /set on this instance and collection/.test(r2['Thresholds']?.text ?? ''),
    'CH20 the row N/A, its reason and its Thresholds cell', r2 ? `${r2['Status']?.text} | ${r2['Status Reason']?.text} | ${r2['Thresholds']?.text}` : 'not in the grid');
  // Inherit All, Save: the level's own row ended, the row judged again
  const again = r2 ? await th(inst, 'activity') : false;
  const d3 = again ? await loaded() : null;
  if (d3) await ev(`(() => { const d = document.querySelector('dialog.act-dialog[open]'); [...d.querySelectorAll('button')].find(b => b.textContent === 'Inherit All').click(); d.querySelector('button[type=submit]').click(); })()`);
  const back = d3 ? await until(async () => { const d = await dlg(); return d && /^(done|not saved)/.test(d.msg.trim()) ? d : null; }) : null;
  await ev(`[...document.querySelectorAll('dialog.act-dialog[open] button')].find(b => b.textContent === 'Close')?.click()`);
  // the row judged again: its status as the API judges it now (the review of B6g-2 #13: a 24-hour page that crossed an
  // hour since the first read may have dropped an hour, so the status before the writes is no measure)
  const iid0 = insts.find(r => r.name === inst)?.instance_id;
  const now3 = iid0 == null ? null : (await api({ instance: iid0 }))?.find(x => x.collection === 'activity');
  const p3 = await open('#/collectionhealth?w=24h');
  const r3 = (p3?.rows ?? []).find(r => r['Instance']?.text === inst && r['Collection']?.text === 'activity');
  say(!!back && back.msg.includes('Saved for') && !!r3 && !!now3 && r3['Status']?.text === word[now3.status] && r3['Status']?.text !== 'N/A' && r3['Thresholds']?.text === row?.['Thresholds']?.text,
    'CH20 Inherit All + Save: the row judged again, its thresholds as before', `${back ? back.msg.slice(0, 80) : 'no answer'} | API ${now3?.status}, page ${r3?.['Status']?.text} / ${r3?.['Thresholds']?.text} (before ${row?.['Thresholds']?.text})`);
  // a refusal of the repository's function, in its words on the page (as post() shows it: the body's error)
  const iid = insts.find(r => r.name === inst)?.instance_id;
  const ref = iid == null ? null : await ev(`fetch('/api/collectionhealth/thresholds', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
    body: JSON.stringify({ op: 'set', instance_id: ${Number(iid)}, collection: 'activity', warn_fails_in_row: 0 }) }).then(async r => r.status + ' ' + ((await r.json()).error ?? '(no error key)'))`);
  say(/^409 refused: warn_fails_in_row must be a whole number from 1/.test(ref ?? ''), 'CH21 the API\'s 409 carries the refusal\'s words (what the page\'s post() shows)', String(ref).slice(0, 160));
}

// CH22-CH24 (B6g-3, N42, design G4): DBA Dash's Collection Performance report. CH22 every link of a row per collection
// per instance (Collection, Runs, Avg Duration, Max Duration, Total CPU) lands on #/collectionperf with the row's
// instance, its collection and the grid's range; a row per collection's links keep the page's scope (no instance).
// CH23 the report of fx-chimport's activity: its heading, the four charts (each drawn, or said hourly), its rows the
// API's, its three failed runs as Run rows (pgvigil keeps a failed run one by one) with 'hourly only' CPU, its Hour row.
// CH24 the cut and the cap words are absent on a range inside the hourly rows with few rows.
{
  const p = await open('#/collectionhealth?w=24h');
  const row = (p?.rows ?? []).find(r => r['Instance']?.text === 'fx-chimport' && r['Collection']?.text === 'activity');
  const want = { tab: 'collectionperf', i: String(byName('fx-chimport')?.instance_id ?? ''), collection: 'activity' };
  const lands = [['Collection', 'perf-collection'], ['Runs', 'perf-runs'], ['Avg Duration (ms)', 'perf-avg'], ['Max Duration (ms)', 'perf-max'], ['Total CPU (ms)', 'perf-cpu']];
  const hrefs = lands.map(([c, l]) => row?.[c]?.links?.[l]);
  const bad = hrefs.map((h, k) => [lands[k][0], h]).filter(([, h]) => { const r = route(h); return !h || r.tab !== want.tab || r.q.get('i') !== want.i || r.q.get('collection') !== want.collection || !r.q.get('from') || !r.q.get('to'); });
  const same = new Set(hrefs.map(h => { const r = route(h); return `${r.q.get('from')}|${r.q.get('to')}`; })).size === 1;
  say(!!row && bad.length === 0 && same, 'CH22 a row per instance: its five cells open the report of its instance and collection over one range',
    row ? (bad.length ? bad.map(([c, h]) => `${c}: ${h ?? 'no link'}`).join('; ') : `${hrefs[0]}`) : 'no fx-chimport row');
  // a row per collection: the links keep the scope (no i=)
  await ev(`(() => { const s = document.querySelector('#ch-show'); if (s) { s.value = 'collection'; s.dispatchEvent(new Event('change', { bubbles: true })); } })()`);
  await sleep(2500);
  const pc = await ev(`[...document.querySelectorAll('main .ch-grid tbody tr')].map(tr => [...tr.querySelectorAll('a[data-land^="perf-"]')].map(a => a.getAttribute('href'))).find(x => x.length > 0) ?? []`);
  say(pc.length >= 2 && pc.every(h => { const r = route(h); return r.tab === 'collectionperf' && !r.q.get('i') && !!r.q.get('collection'); }), 'CH22 a row per collection: its links keep the page\'s scope', (pc ?? []).slice(0, 2).join(' | ') || 'no link');
  // CH23 the report itself
  const h0 = hrefs[1];
  if (h0) {
    await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + h0 });
    for (let k = 0; k < 100; k++) { if (await ev(`!!document.querySelector('main section.collectionperf[data-drawn]')`)) break; await sleep(150); }
    await sleep(800);
    const rep = await ev(`(() => { const s = document.querySelector('main section.collectionperf'); if (!s) return null;
      const t = s.querySelector('.cp-grid table'); const heads = [...(t?.querySelectorAll('thead th') ?? [])].map(th => (th.querySelector('.th-label') ?? th).textContent.trim());
      const rows = [...(t?.querySelectorAll('tbody tr') ?? [])].map(tr => Object.fromEntries(heads.map((h, i) => [h, tr.children[i]?.textContent.trim() ?? ''])));
      const charts = [...s.querySelectorAll('.cp-charts .chart')].map(c => ({ title: c.querySelector('h3')?.firstChild?.textContent.trim() ?? '', drawn: !!c.querySelector('canvas, svg, .u-wrap') || /The charts are hourly/.test(c.textContent) }));
      return { title: s.querySelector('h2')?.textContent.trim(), meta: s.querySelector('p.meta')?.textContent ?? '', rows, charts }; })()`);
    const q = route(h0).q;
    let apiRows = null;
    try { const d = await (await fetch(U + 'api/collectionperf?' + new URLSearchParams({ part: 'rows', instance: q.get('i'), collection: 'activity', from: q.get('from'), to: q.get('to') }))).json(); apiRows = d.rows?.rows?.length ?? null; } catch { apiRows = null; }
    const titles = (rep?.charts ?? []).map(c => c.title);
    say(rep?.title === 'Collection Performance' && JSON.stringify(titles) === JSON.stringify(['Duration (ms)', 'CPU (ms)', 'Logical Reads', 'Runs']) && rep.charts.every(c => c.drawn),
      'CH23 the report: its heading and its four charts drawn', rep ? `${rep.title} | ${rep.charts.map(c => `${c.title} ${c.drawn ? 'drawn' : 'NOT drawn'}`).join(', ')}` : 'no report');
    say(!!rep && apiRows != null && rep.rows.length === apiRows, 'CH23 its rows are the API\'s', `${rep?.rows.length ?? 'no'} drawn, the API ${apiRows}`);
    const runs = (rep?.rows ?? []).filter(r => r['Period'] === 'Run'), hours = (rep?.rows ?? []).filter(r => r['Period'] === 'Hour');
    say(runs.length === 3 && runs.every(r => r['Outcome'] === 'Failed' && r['CPU (ms)'] === 'hourly only' && r['Import (ms)'] === 'hourly only') && hours.length >= 1 && hours.every(r => r['Import Lag (sec)'] === 'not read'),
      'CH23 fx-chimport: its three failed runs one by one (hourly only), its hour', `${runs.length} Run row(s) [${runs.map(r => r['Outcome'] + ' / ' + r['CPU (ms)']).join('; ')}], ${hours.length} Hour row(s)`);
    say(!!rep && !/are gone, so the report starts there/.test(rep.meta) && !/rows are listed: the range holds more/.test(rep.meta), 'CH24 a range inside the hourly rows, few rows: no cut, no cap said', (rep?.meta ?? '').slice(0, 160));
  } else for (const r of ['the report: its heading and its four charts drawn', 'its rows are the API\'s', 'fx-chimport: its three failed runs one by one (hourly only), its hour', 'a range inside the hourly rows, few rows: no cut, no cap said']) say(false, 'CH23 ' + r, 'no Runs link');
}

// CH7 the landings
{
  // the Summary's cell, one PostgreSQL row (fx-chcrit) and one SQL Server row; a row is found by its instance link's
  // text - a never-read instance (fx-chcrit: planted, no last_seen) says 'not read yet' beside its name (vis-b6ch5)
  await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + '#/summary?w=24h' });
  for (let i = 0; i < 100 && !(await ev(`!!document.querySelector('main table thead')`)); i++) await sleep(150);
  await sleep(1500);
  for (const r of [crit, ms].filter(Boolean)) {
    const h = await ev(`(() => { for (const t of document.querySelectorAll('main table')) { const hs = [...t.querySelectorAll('thead th')].map(th => th.textContent.trim()); const k = hs.indexOf('Collection Health'); if (k < 0) continue;
      for (const tr of t.querySelectorAll('tbody tr')) if ((tr.children[0]?.querySelector('a') ?? tr.children[0])?.textContent.trim() === ${JSON.stringify(r.name)}) return tr.children[k]?.querySelector('a')?.getAttribute('href') ?? 'no link'; } return 'no cell'; })()`);
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
    // every row drawn (up to a grid's page), each with the API's status (the review of B6.2, part b #3b)
    say(bad.length === 0 && p.rows.length > 0 && p.rows.length === Math.min(rows.length, 200), 'CH7 grid = API statuses', `${p.rows.length} row(s) of the API's ${rows.length}, ${bad.length} differ${bad.length ? ': ' + bad.slice(0, 3).map(x => `${x.Instance.text}/${x.Collection.text} ${x.Status.text}`).join(', ') : ''}`);
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
    // Last Failure (the review of B6.2, part b #3d): the window by the rule over the run's own times - from its last
    // success (fx-chcrit: ok, then 3 failures), to its last failure + 1 hour - and its landing lists the 3 failures
    const lfh = row['Last Failure'].links.lastfailure, lf = route(lfh);
    // the window's start graded against the fixture's own ok run (CH_NOW - 40 min, within a second; B6f3 #12), its end
    // against the last failure the API reads + 1 h
    const okAt = isFinite(fxNow) ? fxNow - 40 * 60e3 : NaN, failAt = mine[0]?.last_failure;
    const wantTo = failAt ? Date.parse(failAt) + 3600e3 : NaN;
    say(lf.tab === 'collectionhealth' && isFinite(okAt) && Math.abs(Date.parse(lf.q.get('from')) - okAt) <= 1000 && Date.parse(lf.q.get('to')) === wantTo, 'CH7 Last Failure window',
      `${lfh ?? 'no link'} vs fx-chcrit's ok run ${isFinite(okAt) ? new Date(okAt).toISOString() : 'CH_NOW not set'} .. the last failure + 1 h`);
    if (lfh) {
      await cmd('Page.navigate', { url: U + lfh }); await sleep(2000);
      const listed = await ev(`document.querySelectorAll('main .ch-errors tbody tr').length`);
      say(listed === 3, 'CH7 Last Failure -> the error list', `${listed} listed, the fixture's 3 failures`);
    } else say(false, 'CH7 Last Failure -> the error list', 'no link');
  } else for (const c of ['Instance name', 'Failed', 'Errors', 'Last Failure window']) say(false, 'CH7 ' + c, 'no fx-chcrit row');
  // Instances (Row per collection) -> the per-instance rows of that collection
  const p2 = await open('#/collectionhealth?w=24h&grain=collection');
  const r2 = p2?.rows.find(x => x.Collection?.text === 'activity');
  const ih = route(r2?.Instances?.links?.instances);
  say(ih.tab === 'collectionhealth' && ih.q.get('grain') === 'instance' && ih.q.get('collection') === 'activity', 'CH7 Instances', r2?.Instances?.links?.instances ?? 'no link');
  // opened (the review of B6.2, part b #3e): every row of activity, as many as the API's per-instance activity rows
  if (r2?.Instances?.links?.instances) {
    const p3 = await open(r2.Instances.links.instances);
    const want = (rows ?? []).filter(x => x.collection === 'activity').length;
    say(!!p3 && p3.rows.length > 0 && p3.rows.every(x => x.Collection?.text === 'activity') && p3.rows.length === Math.min(want, 200), 'CH7 Instances -> the rows',
      `${p3?.rows.length ?? 0} row(s), the API's ${want}`);
  } else say(false, 'CH7 Instances -> the rows', 'no link');
  // Failed opens the window it counts (the review of B6.2, part b #1; fixture fx-chhour): a range that starts 20 minutes
  // into the hour of its one failure counts it, and the list Failed opens holds it
  const hr = byName('fx-chhour');
  if (hr) {
    // the hour of its failure as the fixture wrote it (CH_HOUR; B6f3 #3), the range from 20 minutes into it
    const p4 = isFinite(fxHour) ? await open(`#/collectionhealth?i=${hr.instance_id}&from=${encodeURIComponent(new Date(fxHour + 20 * 60e3).toISOString())}&to=${encodeURIComponent(new Date().toISOString())}`) : null;
    const r4 = p4?.rows.find(x => x.Collection?.text === 'activity');
    const fh = r4?.Failed?.links?.failed;
    if (fh) {
      await cmd('Page.navigate', { url: U + fh }); await sleep(2000);
      const listed = await ev(`document.querySelectorAll('main .ch-errors tbody tr').length`);
      say(r4.Failed.text === '1' && listed === 1, 'CH7 Failed -> the counted window (fx-chhour)', `Failed ${r4.Failed.text}, ${listed} listed (${fh})`);
    } else say(false, 'CH7 Failed -> the counted window (fx-chhour)', r4 ? `Failed ${r4.Failed?.text}: no link` : 'no fx-chhour row');
    // #11 the error list's window on the page's clock, no raw UTC
    const cap = await ev(`document.querySelector('main .ch-errors')?.parentElement?.querySelector('p.meta')?.textContent ?? document.querySelector('main p.meta')?.textContent ?? ''`);
    say(!/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(cap), 'CH7 the error list\'s window on the page\'s clock', cap.slice(0, 160));
  } else for (const r of ['Failed -> the counted window (fx-chhour)', 'the error list\'s window on the page\'s clock']) say(false, 'CH7 ' + r, 'no fx-chhour instance');
  // the rate and the skip fixtures as the API judges them
  const one = n => rows?.find(x => String(x.instance_id) === String(byName(n)?.instance_id) && x.collection === 'activity');
  say(one('fx-chrate')?.status === 'critical' && /% failed/.test(one('fx-chrate')?.status_reason ?? ''), 'CH7 API fx-chrate', JSON.stringify(one('fx-chrate') ?? null).slice(0, 160));
  say(one('fx-chskip')?.status === 'n/a', 'CH7 API fx-chskip', JSON.stringify(one('fx-chskip') ?? null).slice(0, 160));
}
console.log(`collection health: ${oks} ok; ${fails} FAIL`);
ws.close();
process.exit(fails ? 1 : 0);
