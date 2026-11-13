// The page range up to a year, in the browser (proof-range.sh, task RANGE DONE-1): DBA Dash's twenty lengths and its
// Date and Month lists in the range panel, a year's window said where a part reads less of it (the page's line, a
// grid's line, the workbook, the CSV, the mail body), Zoom out over the menu and off at a year, the auto refresh floor
// over a day, and what the repository keeps when the window starts before it.
//   node scripts/range-check.mjs <cdp port> <base url/> <download folder>
//   RANGE_ERP the demo's demo-onprem-erp01 instance_id; RANGE_ROWS_FROM, RANGE_PURGE_AT, RANGE_MONTHS_FROM (YYYY-MM-DD),
//   RANGE_DAYS_FROM (YYYY-MM-DD or empty): the hand reads of what the repository keeps (proof-range.sh, RB)
// Prints one 'ok <case>: ...' line per case, or 'FAIL <case>: ...' and exits 1.
const [port, base, dl] = process.argv.slice(2);
const fs = await import('node:fs');
const { execFileSync } = await import('node:child_process');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(); ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => {
  const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true, userGesture: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
};
let failed = 0;
const check = (name, okay, detail) => { console.log(`${okay ? 'ok  ' : 'FAIL'} ${name}: ${detail}`); if (!okay) failed++; };
await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dl, eventsEnabled: true });
await send('Emulation.setFocusEmulationEnabled', { enabled: true });
await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
await send('Emulation.setTimezoneOverride', { timezoneId: 'America/Los_Angeles' });
const go = async h => {
  await send('Page.navigate', { url: 'about:blank' }); await sleep(200);   // a full load each time: a same-hash navigation draws nothing
  await send('Page.navigate', { url: base + h });
  for (let i = 0; i < 60; i++) { await sleep(250); if (await ev(`!!document.querySelector('main section, main .grid-box, main .chart, main .empty-grid') && !document.querySelector('main > p.empty[role=status]')`)) break; }
  await sleep(800);
};
const params = async () => new URLSearchParams((await ev(`location.hash`)).split('?')[1] ?? '');
const rangeBtn = `document.querySelector('#bar [aria-haspopup="dialog"]')`;
const rangePanel = `document.querySelector('#bar [role="dialog"][aria-label="Time range"]')`;
const openRange = async () => { if (!(await ev(`!!${rangePanel}`))) await ev(`${rangeBtn}.click(); 'ok'`); await sleep(200); };
const erp = process.env.RANGE_ERP;
const words = `[...document.querySelectorAll('main .range-note p, main .read-window')].map(p => p.className + ': ' + p.textContent)`;

// R10 (its own pass, RANGE_CASE=R10, after proof-range.sh puts erp01's sizes 60 days back): a chart drawn over its
// own span longer than a part's reach (the Storage growth panel at 90 days on a 1-hour page) says its marks' read
// itself, and the page's line claims no cut for the 1-hour window
if (process.env.RANGE_CASE === 'R10') {
  await go(`#/storage?i=${erp}&w=1h`); await sleep(1500);
  await ev(`[...document.querySelectorAll('main button')].find(b => b.textContent === '90 days').click(); 'ok'`);
  await sleep(4500);
  const r10 = await ev(words);
  const said = await ev(`(document.querySelector('main').innerText.match(/Marks are read for the newest \\d+ days of this window: [^\\n]*/) ?? [''])[0]`);
  check('R10 own span', (await params()).get('w') === '1h' && !r10.some(t => t.startsWith('meta range-cut')) && /^Marks are read for the newest 31 days of this window: .+ to .+ \(this chart is longer than they read\)\.$/.test(said),
    `w=1h, growth 90 days: the page's line ${JSON.stringify(r10)}; the chart's '${said}'`);
  console.log(failed ? 'FAIL 1 case(s)' : 'range-check R10: ok');
  process.exit(failed ? 1 : 0);
}

// R1. the panel's quick ranges, Date and Month
await go('#/summary?w=1h');
await openRange();
const r1 = await ev(`(() => { const p = ${rangePanel};
  const sels = [...p.querySelectorAll('select.range-daymonth')];
  return { quick: [...p.querySelectorAll('fieldset.range-quick button.range-item')].map(b => b.firstChild.textContent),
           date: [...sels[0].options].slice(1).map(o => o.textContent), month: [...sels[1].options].slice(1).map(o => o.textContent),
           labels: sels.map(s => s.getAttribute('aria-label')) }; })()`);
const wantQuick = ['Last 5 minutes', 'Last 10 minutes', 'Last 15 minutes', 'Last 30 minutes', 'Last hour', 'Last 2 hours', 'Last 3 hours', 'Last 6 hours',
  'Last 12 hours', 'Last 24 hours', 'Last 2 days', 'Last 3 days', 'Last 7 days', 'Last 14 days', 'Last 28 days', 'Last 30 days', 'Last 60 days', 'Last 90 days',
  'Last 180 days', 'Last year'];
const day = /^\d{4}-\d\d-\d\d \((Sun|Mon|Tue|Wed|Thu|Fri|Sat) - (Today|Yesterday|\d+ days ago)\)$/, mon = /^(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \((This Month|Last Month|\d+ months ago)\)$/;
check('R1 menu', r1.quick.join('|') === wantQuick.join('|') && r1.date.length === 15 && r1.date.every(t => day.test(t))
  && r1.date[0].endsWith('- Today)') && r1.date[1].endsWith('- Yesterday)') && r1.date[2].endsWith('- 2 days ago)') && r1.date[14].endsWith('- 14 days ago)')
  && r1.month.length === 13 && r1.month.every(t => mon.test(t)) && r1.month[0].endsWith('(This Month)') && r1.month[1].endsWith('(Last Month)')
  && r1.month[2].endsWith('(2 months ago)') && r1.month[12].endsWith('(12 months ago)') && r1.labels.every(l => l.includes('America/Los_Angeles')),
  `quick ${r1.quick.length}: ${r1.quick.join('|')}; Date ${r1.date.length}: ${r1.date[0]} .. ${r1.date[14]}; Month ${r1.month.length}: ${r1.month[0]} .. ${r1.month[12]}; labels ${r1.labels.join(' / ')}`);

// R2. 'Last year' on erp01's Statements: the page's line and the grid's line; at 7 days neither
await go(`#/statements?i=${erp}&w=1h`);
await openRange();
await ev(`[...${rangePanel}.querySelectorAll('button.range-item')].find(b => b.firstChild.textContent === 'Last year').click(); 'ok'`);
for (let i = 0; i < 40 && (await params()).get('w') !== '1y'; i++) await sleep(250);
await sleep(2500);
const yearW = (await params()).get('w');
const r2 = await ev(words);
await go(`#/statements?i=${erp}&w=7d`);
const r2b = await ev(words);
const cut = /^Parts of this page read the newest 31 days of this window: .+ to .+ \(the window is longer than they read\)\.$/;
check('R2 year', yearW === '1y' && r2.some(t => t.startsWith('meta range-cut: ') && cut.test(t.slice('meta range-cut: '.length)))
  && r2.some(t => /^meta read-window: This list reads the newest 31 days of this window: .+ to .+\.$/.test(t)) && r2b.length === 0,
  `w=${yearW}; at a year: ${JSON.stringify(r2).slice(0, 600)}; at 7 days: ${JSON.stringify(r2b)}`);

// R3. Date and Month go to the calendar's ranges: Today = w=today, Yesterday = the calendar's Yesterday, 2 days ago ends
// where Yesterday starts; This Month = w=mtd, Last Month = the calendar's Previous month, 2 months ago ends where it starts
// a pick alone never navigates (WCAG 3.2.2: arrowing through a closed select fires 'change'); its Show button does
const pick = async (which, value) => { await go('#/summary?w=1h'); await openRange();
  await ev(`(() => { const s = ${rangePanel}.querySelectorAll('select.range-daymonth')[${which}]; s.value = '${value}'; s.dispatchEvent(new Event('change')); return 'ok'; })()`);
  await sleep(600); const held = (await ev('location.hash')) === (await ev(`'#/summary?w=1h'`));
  const shown = await ev(`(() => { const p = ${rangePanel}; const s = p && p.querySelectorAll('select.range-daymonth')[${which}];
    const b = s && s.closest('.range-daymonth-row') && s.closest('.range-daymonth-row').querySelector('button.range-daymonth-go'); if (!b) return false; b.click(); return true; })()`);
  await sleep(1200); const q = await params(); return { w: q.get('w'), from: q.get('from'), to: q.get('to'), held, shown }; };
const cal = async name => { await go('#/summary?w=1h'); await openRange();
  await ev(`[...${rangePanel}.querySelectorAll('button.range-item')].find(b => b.firstChild.textContent === ${JSON.stringify(name)}).click(); 'ok'`);
  await sleep(1200); const q = await params(); return { w: q.get('w'), from: q.get('from'), to: q.get('to') }; };
const dToday = await pick(0, 0), dYest = await pick(0, 1), d2 = await pick(0, 2), cYest = await cal('Yesterday');
const mThis = await pick(1, 0), mLast = await pick(1, 1), m2 = await pick(1, 2), cPrev = await cal('Previous month');
const hours = r => (Date.parse(r.to) - Date.parse(r.from)) / 3600e3;
const picks = [dToday, dYest, d2, mThis, mLast, m2];
check('R3 date/month', picks.every(p => p.held && p.shown) && dToday.w === 'today' && dYest.from === cYest.from && dYest.to === cYest.to && !!dYest.from && d2.to === dYest.from && [23, 24, 25].includes(hours(d2))
  && mThis.w === 'mtd' && mLast.from === cPrev.from && mLast.to === cPrev.to && !!mLast.from && m2.to === mLast.from && hours(m2) >= 28 * 24 - 1 && hours(m2) <= 31 * 24 + 1,
  `a pick alone held the page ${picks.map(p => p.held).join('/')}, Show there ${picks.map(p => p.shown).join('/')}; Date: Today w=${dToday.w}; Yesterday ${dYest.from} - ${dYest.to} (calendar ${cYest.from} - ${cYest.to}); 2 days ago ${d2.from} - ${d2.to} (${hours(d2)} h); Month: This w=${mThis.w}; Last ${mLast.from} - ${mLast.to} (calendar ${cPrev.from} - ${cPrev.to}); 2 months ago ${m2.from} - ${m2.to}`);

// R4. Zoom out: 180 days to a year; off at a year with its words, the key '-' changing nothing; an old 4h address
const zoomBtn = `document.querySelector('#bar .range button[aria-label^="Zoom out"]')`;
const zoom = async () => { await ev(`${zoomBtn}.click(); 'ok'`); await sleep(1200); return (await params()).get('w'); };
await go('#/summary?w=180d');
const z180 = await zoom();
await go('#/summary?w=1y');
const off = await ev(`(() => { const b = ${zoomBtn}; const n = b.getAttribute('aria-describedby') ? document.getElementById(b.getAttribute('aria-describedby')) : null;
  return { off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled, described: n ? n.textContent.trim() : '', title: b.title }; })()`);
await ev(`document.dispatchEvent(new KeyboardEvent('keydown', { key: '-', bubbles: true, cancelable: true })); 'ok'`); await sleep(800);
const zKey = (await params()).get('w');
await go('#/summary?w=4h');
const label4 = await ev(`${rangeBtn}.textContent`);
const z4 = await zoom();
check('R4 zoom', z180 === '1y' && off.off && !off.disabledAttr && off.described === 'the range is already a year, the longest pgvigil reads' && zKey === '1y'
  && label4 === 'Range: Last 4 hours' && z4 === '12h',
  `180d -> ${z180}; at 1y: aria-disabled ${off.off}, disabled attribute ${off.disabledAttr}, described '${off.described}', title '${off.title}', key '-' -> ${zKey}; w=4h reads '${label4}', Zoom out -> ${z4}`);

// R5. the auto refresh over a day: 30 s and 1 min off, 5 min in force; under a day as chosen (30 s, the default)
const refresh = `(() => { const s = document.querySelector('#bar select[aria-label^="Auto refresh"]');
  return { off: [...s.options].filter(o => o.disabled).map(o => o.value).join(','), value: s.value, foot: document.getElementById('status-refresh')?.textContent ?? '' }; })()`;
await go('#/summary?w=7d'); await sleep(1500);
const rf7 = await ev(refresh);
await go('#/summary?w=1h'); await sleep(1500);
const rf1 = await ev(refresh);
check('R5 refresh', rf7.off === '30,60' && rf7.value === '300' && rf7.foot === 'auto refresh every 5 min (a window over a day)' && rf1.off === '' && rf1.value === '30' && rf1.foot === 'auto refresh every 30 s',
  `7 days: off '${rf7.off}', in force ${rf7.value}, '${rf7.foot}'; 1 hour: off '${rf1.off}', ${rf1.value}, '${rf1.foot}'`);

// R6. what the repository keeps, when the window starts before it: the Summary at 30 days; at 3 days nothing
const rowsFrom = process.env.RANGE_ROWS_FROM, purgeAt = process.env.RANGE_PURGE_AT, monthsFrom = process.env.RANGE_MONTHS_FROM, daysFrom = process.env.RANGE_DAYS_FROM;
await go('#/summary?w=30d'); await sleep(1500);
const r6 = await ev(`(() => { const p = document.querySelector('main .range-note .range-stored'); if (!p) return null;
  const f = s => new Date(s).toLocaleString(undefined, { hour12: false });
  const m = s => new Date(s + 'T00:00:00Z').toLocaleDateString(undefined, { month: 'long', year: 'numeric', timeZone: 'UTC' });
  const d = s => new Date(s + 'T00:00:00Z').toLocaleDateString(undefined, { day: 'numeric', month: 'long', year: 'numeric', timeZone: 'UTC' });
  return { text: p.textContent, link: p.querySelector('a')?.getAttribute('href') ?? '',
           want: [' the per-snapshot summaries from ' + f(${JSON.stringify(rowsFrom)}) + ' (pgvigil purge -days 10, last run ' + f(${JSON.stringify(purgeAt)}) + ')',
                  ...(${JSON.stringify(monthsFrom)} ? ['the monthly history from ' + m(${JSON.stringify(monthsFrom)})] : []),
                  ...(${JSON.stringify(daysFrom)} ? ['the daily history from ' + d(${JSON.stringify(daysFrom)}) + ' (UTC)'] : [])] }; })()`);
await go('#/summary?w=3d'); await sleep(1500);
const r6b = await ev(`!!document.querySelector('main .range-note .range-stored')`);
check('R6 retention', !!r6 && r6.text.startsWith('This window starts ') && r6.text.includes(', before what the repository keeps:') && r6.want.every(w => r6.text.includes(w))
  && r6.link.startsWith('#/retention') && !r6b,
  `30 days: '${r6?.text}' (link ${r6?.link}; wanted ${JSON.stringify(r6?.want)}); 3 days: line ${r6b}`);

// R7. the export of erp01's Statements at a year: the workbook's Summary 'Read' row and the list's note; the CSV's line
await go(`#/statements?i=${erp}&w=1y`); await sleep(1500);
for (const f of fs.readdirSync(dl)) fs.rmSync(`${dl}/${f}`, { recursive: true });
const grab = async (button, ext) => { await ev(`[...document.querySelectorAll('#bar button')].find(b => b.textContent === ${JSON.stringify(button)}).click(); 'ok'`);
  for (let i = 0; i < 60; i++) { await sleep(250); const f = fs.readdirSync(dl).find(x => x.endsWith(ext)); if (f) { await sleep(500); return `${dl}/${f}`; } } return ''; };
const xlsx = await grab('Export .xlsx', '.xlsx');
const strings = xlsx ? execFileSync('unzip', ['-p', xlsx], { maxBuffer: 64 << 20 }).toString() : '';
const csvFile = await grab('Export CSV', '.zip') || await grab('Export CSV', '.csv');
let csvLine = '';
if (csvFile.endsWith('.zip')) {
  const names = execFileSync('unzip', ['-Z1', csvFile]).toString().trim().split('\n');
  for (const n of names) { const t = execFileSync('unzip', ['-p', csvFile, n]).toString().replace(/^﻿/, ''); if (t.includes('This list reads')) { csvLine = t.split(/\r?\n/)[0]; break; } }
} else if (csvFile) csvLine = fs.readFileSync(csvFile, 'utf8').replace(/^﻿/, '').split(/\r?\n/)[0];
check('R7 export', strings.includes('Parts of this page read the newest 31 days of this window') && strings.includes('This list reads the newest 31 days of this window')
  && /^"?This list reads the newest 31 days of this window: /.test(csvLine),
  `${xlsx.split('/').pop() || 'no .xlsx'}: 'Read' words ${strings.includes('Parts of this page read the newest 31 days')}, the list's note ${strings.includes('This list reads the newest 31 days')}; ${csvFile.split('/').pop() || 'no CSV'}: first line '${csvLine.slice(0, 160)}'`);

// R8. the mail body the page builds (the door and the send answered by stubs in the page: nothing is sent)
const r8 = await ev(`(async () => {
  const real = window.fetch; let sent = null;
  window.fetch = async (u, o) => {
    const url = String(u);
    if (url.includes('/api/reportmail?') && url.includes('part=channels')) return new Response(JSON.stringify({ door: { writable: true, user: 'proof', browser: true, max_html: 2e7, max_xlsx: 2e7, max_recipients: 10, min_gap_secs: 0 },
      channels: { columns: ['name', 'destination'], rows: [['mail', 'admin@pgvigil.test']] } }), { status: 200, headers: { 'Content-Type': 'application/json' } });
    if (url.endsWith('/api/reportmail/send')) { sent = JSON.parse(o.body); return new Response(JSON.stringify({ outcome: 'ok', detail: 'mail queued (proof stub)', send_id: null }), { status: 200, headers: { 'Content-Type': 'application/json' } }); }
    return real(u, o);
  };
  [...document.querySelectorAll('#bar button')].find(b => b.textContent === 'Mail...').click();
  for (let i = 0; i < 40 && !document.querySelector('dialog textarea'); i++) await new Promise(r => setTimeout(r, 100));
  const d = document.querySelector('dialog'); if (!d) return { err: 'no dialog' };
  const ta = d.querySelector('textarea'); ta.value = 'dba@pgvigil.test'; ta.dispatchEvent(new Event('input', { bubbles: true }));
  [...d.querySelectorAll('button')].find(b => b.textContent === 'Send now').click();
  for (let i = 0; i < 100 && !sent; i++) await new Promise(r => setTimeout(r, 100));
  window.fetch = real;
  return sent ? { html: sent.html } : { err: 'nothing posted' };
})()`);
const html = r8.html ?? '';
check('R8 mail', /<th[^>]*>Read<\/th><td[^>]*>Parts of this page read the newest 31 days of this window: /.test(html) && html.includes('This list reads the newest 31 days of this window'),
  r8.err ?? `the body: 'Read' line ${/>Read<\/th>/.test(html)}, the page's words ${html.includes('Parts of this page read the newest 31 days')}, the list's note ${html.includes('This list reads the newest 31 days')} (${html.length} bytes)`);

// R9. a reply of the page before comes back after a newer draw began: never in the newer page's line (blocker 1). The
// 60-day page's statements read is held 3 s in the page, the address goes to 1 hour while it is held
const hold = await send('Page.addScriptToEvaluateOnNewDocument', { source: `(() => { const real = window.fetch;
  window.fetch = async (u, o) => { const s = String(u), q = new URLSearchParams(s.split('?')[1] ?? '');
    const long = s.includes('/api/statements?') && Date.parse(q.get('to')) - Date.parse(q.get('from')) > 40 * 86400e3;
    if (long) window.__held = true;
    const res = await real(u, o); if (long) await new Promise(r => setTimeout(r, 3000)); return res; }; })();` });
await send('Page.navigate', { url: 'about:blank' }); await sleep(200);
await send('Page.navigate', { url: base + `#/statements?i=${erp}&w=60d` });
for (let i = 0; i < 80 && !(await ev('!!window.__held')); i++) await sleep(125);
const heldSeen = await ev('!!window.__held');
await ev(`location.hash = '#/statements?i=${erp}&w=1h'; 'ok'`);
await sleep(4500);
const r9 = await ev(words), w9 = (await params()).get('w');
await send('Page.removeScriptToEvaluateOnNewDocument', { identifier: hold.result?.identifier });
check('R9 late reply', heldSeen && w9 === '1h' && !r9.some(t => t.startsWith('meta range-cut')),
  `the 60-day read held ${heldSeen}, then w=${w9}: ${JSON.stringify(r9).slice(0, 500)}`);

// R11. a page with two cut reads of one reach says the reach once (SQL Server File IO over 60 days: its fileio and its
// counters read, asked milliseconds apart)
await go(`#/mssqlfileio?i=${process.env.RANGE_SQL01}&w=60d`); await sleep(3000);
const cut11 = (await ev(words)).find(t => t.startsWith('meta range-cut: ')) ?? '';
const times11 = (cut11.match(/the newest 31 days of this window/g) ?? []).length;
check('R11 once', times11 === 1, `the reach said ${times11} time(s): ${cut11.slice(0, 400)}`);

if (failed) { console.log(`FAIL ${failed} case(s)`); process.exit(1); }
console.log('range-check: every case ok');
process.exit(0);
