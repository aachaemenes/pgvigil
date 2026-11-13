// The shared frame's browser checks (proof-frame.sh): a grid's column filter, its copy menu and the clipboard, a grid
// inside a grid's row, the Summary's Tests pane header, a chart legend's isolation, the crosshair readout, the auto
// refresh select, the filtered CSV export, a grid past its page, a pie's wedges, the status colours, the range
// control with its calendar periods and display time zone, the time strip above an event grid, and a new page opened at
// its top; and (task 152) a drag on a chart setting the page's range, one cursor across a page's charts, a setting change
// marked on its instance's charts, clickable slices with a Top N and a pie menu, Pick series, the range's steps and its
// typed form, the footer's status line, a second y axis and a server limit, the full-window view, the partial-window note.
//   node scripts/frame-check.mjs <cdp port> <base url/> <download folder>
//   FRAME_EXPECT_DOOR=<user>  the server is a demo serve with its write door, saving as this user (proof-frame.sh
//                             passes 'demo'); unset = a server without a door. Case X judges the footer against it.
// Prints one 'ok <case>: ...' line per case, or 'FAIL <case>: ...' and exits 1.
const [port, base, dl] = process.argv.slice(2);
const fs = await import('node:fs');
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
const origin = base.replace(/\/$/, '');
await send('Browser.grantPermissions', { permissions: ['clipboardReadWrite', 'clipboardSanitizedWrite'], origin });
await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: dl, eventsEnabled: true });
await send('Emulation.setFocusEmulationEnabled', { enabled: true });
await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
const go = async h => { await send('Page.navigate', { url: base + h }); for (let i = 0; i < 40; i++) { await sleep(250); if (await ev(`!!document.querySelector('main section, main .grid-box, main .chart') && !document.querySelector('main > p.empty[role=status]')`)) break; } await sleep(400); };
const inst = await (await fetch(base + 'api/instances')).json(); const c = inst.columns;
const idOf = n => inst.rows.find(r => String(r[c.indexOf('name')]) === n)[c.indexOf('instance_id')];
const filterIn = (sel, label, value) => `(async () => {
  const t = document.querySelector(${JSON.stringify(sel)}); const ths = [...t.querySelectorAll('thead tr:first-child th')];
  const i = ths.findIndex(th => th.textContent === ${JSON.stringify(label)}); if (i < 0) return 'no column ' + ${JSON.stringify(label)};
  if (t.querySelector('tr.filters').hidden) ths[i].querySelector('.filter-btn').click();
  const inp = t.querySelectorAll('tr.filters input')[i]; inp.value = ${JSON.stringify(value)}; inp.dispatchEvent(new Event('input'));
  await new Promise(r => setTimeout(r, 400));
  return i;
})()`;

// A. a number filter as the cell shows it, and the count line
await go('#/instances');
const total = await ev(`document.querySelectorAll('main table.grid tbody tr').length`);
await ev(filterIn('main table.grid', 'sessions', '>20'));
const a = await ev(`(() => { const t = document.querySelector('main table.grid'); const j = [...t.querySelectorAll('thead tr:first-child th')].findIndex(h => h.textContent === 'sessions');
  const shown = [...t.querySelectorAll('tbody tr')].map(tr => Number(tr.children[j].textContent.replace(/,/g, '')));
  return { n: shown.length, all: shown.every(v => v > 20), count: t.closest('.grid-box').querySelector('.filter-count').textContent }; })()`);
check('A filter', a.n > 0 && a.n < total && a.all && a.count === `${a.n} of ${total} rows shown (filtered)`, `'>20' on sessions: ${a.count}, every shown value > 20: ${a.all}`);

// B. the filtered CSV export: the rows the filter leaves, plus the header
for (const f of fs.readdirSync(dl)) fs.rmSync(`${dl}/${f}`);
await ev(`[...document.querySelectorAll('#bar button')].find(b => b.textContent === 'Export CSV').click()`);
let csv = '';
for (let i = 0; i < 40 && !csv; i++) { await sleep(250); csv = fs.readdirSync(dl).find(f => f.endsWith('.csv')) ?? ''; }
const lines = csv ? fs.readFileSync(`${dl}/${csv}`, 'utf8').trim().split(/\r?\n/) : [];
check('B export', lines.length === a.n + 1, `${csv || 'no .csv downloaded'}: ${lines.length} lines for ${a.n} rows shown and the header`);

// C. the copy menu: its items, Escape from outside the menu, the clipboard for cell / row / all, the status line
const menu = await ev(`(async () => {
  const td = document.querySelector('main table.grid tbody td:nth-child(2)'); td.tabIndex = -1; td.focus();
  td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 300, clientY: 300 }));
  const items = [...document.querySelectorAll('.menu button')].map(b => b.textContent).join('|');
  document.body.focus();
  document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  return { items, openAfter: !!document.querySelector('.menu') };
})()`);
// the grid's own three items first; the grid tools (gridtools.ts, task 153) add their lines after them
check('C menu', menu.items.startsWith(`Copy cell|Copy row|Copy all ${a.n} rows shown|`) && !menu.openAfter, `${menu.items}; open after Escape elsewhere: ${menu.openAfter}`);
const clip = [];
for (const k of [0, 1, 2]) clip.push(await ev(`(async () => {
  const td = document.querySelector('main table.grid tbody td:nth-child(2)');
  td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 300, clientY: 300 }));
  document.querySelectorAll('.menu button')[${k}].click(); await new Promise(r => setTimeout(r, 300));
  const got = await navigator.clipboard.readText();
  return { lines: got.split('\\n').length, first: got.split('\\n')[0], cell: td.textContent.trim(), status: td.closest('.grid-box').querySelector('.filter-count').textContent };
})()`));
check('C clipboard', clip[0].lines === 1 && clip[0].first === clip[0].cell && clip[1].lines === 2 && clip[1].first.startsWith('name\t') && clip[2].lines === a.n + 1 && clip[2].status.startsWith('Copied'),
  `cell '${clip[0].first}', row ${clip[1].lines} lines, all ${clip[2].lines} lines, status '${clip[2].status}'`);

// D. the browser's own menu stays on a link and on a filter field; the menu stays inside the window at its edge
const own = await ev(`(() => {
  const ev = t => { const e = new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 50, clientY: 50 }); t.dispatchEvent(e); const m = !!document.querySelector('.menu'); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' })); return e.defaultPrevented || m; };
  return { link: ev(document.querySelector('main table.grid tbody a[href]')), field: ev(document.querySelector('main table.grid tr.filters input')) };
})()`);
const edge = await ev(`(() => {
  const td = document.querySelector('main table.grid tbody td:nth-child(2)');
  td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: innerWidth - 5, clientY: innerHeight - 5 }));
  const r = document.querySelector('.menu').getBoundingClientRect(); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
  return { right: Math.round(r.right), bottom: Math.round(r.bottom), w: innerWidth, h: innerHeight };
})()`);
check('D own menu and edge', !own.link && !own.field && edge.right <= edge.w && edge.bottom <= edge.h, `link takes the copy menu: ${own.link}, field: ${own.field}; menu at the edge ends ${edge.right}x${edge.bottom} in ${edge.w}x${edge.h}`);

// E. a unit filter: '>500 MB' keeps the cells shown at or over 500 MB, whatever their unit
await go(`#/memory?i=${idOf('demo-onprem-erp01')}`);
const unit = await ev(`(async () => {
  const t = [...document.querySelectorAll('main table.grid')].find(g => [...g.querySelectorAll('thead th')].some(h => h.textContent === 'size in cache'));
  if (!t) return { none: true };
  const j = [...t.querySelectorAll('thead tr:first-child th')].findIndex(h => h.textContent === 'size in cache');
  const mb = s => { const m = /([\\d.,]+)\\s*(B|KB|MB|GB|TB)/.exec(s); return m ? Number(m[1].replace(/,/g, '')) * { B: 1 / 1048576, KB: 1 / 1024, MB: 1, GB: 1024, TB: 1048576 }[m[2]] : NaN; };
  const before = [...t.querySelectorAll('tbody tr')].map(tr => mb(tr.children[j].textContent));
  t.querySelector('thead tr:first-child th:nth-child(' + (j + 1) + ') .filter-btn').click();
  const inp = t.querySelectorAll('tr.filters input')[j]; inp.value = '>500 MB'; inp.dispatchEvent(new Event('input'));
  await new Promise(r => setTimeout(r, 400));
  const after = [...t.querySelectorAll('tbody tr')].map(tr => mb(tr.children[j].textContent));
  return { before: before.length, want: before.filter(v => v > 500).length, after: after.length, all: after.every(v => v > 500) };
})()`);
check('E unit filter', !unit.none && unit.after === unit.want && unit.all && unit.want < unit.before, unit.none ? 'no size in cache grid on Memory' : `'>500 MB': ${unit.after} of ${unit.before} rows kept, ${unit.want} shown over 500 MB`);

// F. a grid in a grid's row (a statement's History): its menu copies its own header, the outer copy leaves the panel out
let nested = null;
for (const h of [`#/statements?i=${idOf('demo-onprem-erp01')}&w=1d`, `#/slowqueries?i=${idOf('demo-onprem-erp01')}&w=1d`, `#/mssql_slow?i=${idOf('demo-onprem-sql01')}&w=1d`]) {
  await go(h);
  nested = await ev(`(async () => {
    const b = [...document.querySelectorAll('main table.grid tbody button')].find(x => x.textContent === 'History'); if (!b) return null;
    b.click(); for (let i = 0; i < 30 && !document.querySelector('tr.trend-row table.grid'); i++) await new Promise(r => setTimeout(r, 200));
    const inner = document.querySelector('tr.trend-row table.grid'); if (!inner) return null;
    const outer = inner.closest('tr.trend-row').closest('table.grid');
    const td = inner.querySelector(':scope > tbody > tr > td');   // its own body: the outer tbody holds the inner thead too
    td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 300, clientY: 300 }));
    const rowItem = [...document.querySelectorAll('.menu button')].find(x => x.textContent === 'Copy row');
    if (!rowItem) return { page: location.hash, rowHead: false, allLines: -1, outerRows: 0, why: 'the inner cell menu: ' + [...document.querySelectorAll('.menu button')].map(b => b.textContent).join('|') + ' (td in ' + td.closest('table').className + ', row parent ' + td.parentElement.parentElement.tagName + ')' };
    rowItem.click(); await new Promise(r => setTimeout(r, 300));
    const row = await navigator.clipboard.readText();
    const otd = outer.querySelector('tbody tr:not(.trend-row) td');
    otd.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 300, clientY: 300 }));
    [...document.querySelectorAll('.menu button')].find(x => x.textContent.startsWith('Copy all')).click(); await new Promise(r => setTimeout(r, 300));
    const all = await navigator.clipboard.readText();
    const innerHead = [...inner.querySelectorAll('thead tr:first-child th')].map(h => h.textContent).join('\\t');
    return { page: location.hash, rowHead: row.split('\\n')[0] === innerHead, allLines: all.split('\\n').length, outerRows: outer.querySelectorAll(':scope > tbody > tr:not(.trend-row)').length };
  })()`);
  if (nested) break;
}
check('F nested grid', !!nested && nested.rowHead && nested.allLines === nested.outerRows + 1, nested ? (nested.why ?? `${nested.page}: the inner row copies the inner header ${nested.rowHead}; outer copy ${nested.allLines} lines for ${nested.outerRows} rows`) : 'no History panel with a grid was found');

// G. the Summary's Tests pane keeps its header in view while it scrolls, and is one tab stop
await go('#/summary');
const tests = await ev(`(async () => {
  const pane = document.querySelector('.grid-wrap.tests'); if (!pane) return null;
  pane.scrollTop = 200; await new Promise(r => setTimeout(r, 200));
  const th = pane.querySelector('thead th').getBoundingClientRect().top - pane.getBoundingClientRect().top;
  return { scrolled: pane.scrollTop, headerOffset: Math.round(th), stops: [pane, ...pane.querySelectorAll('[tabindex="0"]')].filter(e => e.getAttribute('tabindex') === '0').length };
})()`);
check('G tests pane', !!tests && (tests.scrolled === 0 || Math.abs(tests.headerOffset) <= 2) && tests.stops === 1, tests ? `scrolled ${tests.scrolled}, header ${tests.headerOffset} px from the pane's top, ${tests.stops} tab stop(s)` : 'no Tests pane');

// H. the auto refresh: five choices on a live page, Off stored; disabled on a page that never refreshes
const live = await ev(`(async () => { const s = document.querySelector('#bar select[aria-label^="Auto refresh"]'); if (!s) return null;
  const n = s.options.length; s.value = '0'; s.dispatchEvent(new Event('change')); await new Promise(r => setTimeout(r, 300));
  const v = localStorage.getItem('pgvigil.refresh'); localStorage.removeItem('pgvigil.refresh'); return { n, v, disabled: s.disabled }; })()`);
await go(`#/performance?i=${idOf('demo-onprem-erp01')}`);
const still = await ev(`document.querySelector('#bar select[aria-label*="refresh"]')?.disabled ?? null`);
check('H refresh', !!live && live.n === 5 && live.v === '0' && !live.disabled && still === true, live ? `${live.n} choices on the Summary, Off stored '${live.v}'; disabled on Performance: ${still}` : 'no select on the Summary');

// I. a legend's double-click isolates and restores; the readout follows the cursor
const iso = await ev(`(async () => {
  const rows = [...document.querySelector('.u-legend').querySelectorAll('.u-series')].slice(1);
  const shown = () => rows.filter(r => !r.classList.contains('u-off')).length;
  rows[0].dispatchEvent(new MouseEvent('dblclick', { bubbles: true })); await new Promise(r => setTimeout(r, 200)); const one = shown();
  rows[0].dispatchEvent(new MouseEvent('dblclick', { bubbles: true })); await new Promise(r => setTimeout(r, 200));
  const o = document.querySelector('.u-over'); o.scrollIntoView({ block: 'center' }); const r = o.getBoundingClientRect();
  o.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: r.left + r.width * 0.5, clientY: r.top + r.height / 2 })); await new Promise(r => setTimeout(r, 200));
  const t = o.querySelector('.u-tip');
  return { one, all: shown(), n: rows.length, tip: t && !t.hidden ? t.children.length : 0 };
})()`);
check('I chart', iso.one === 1 && iso.all === iso.n && iso.tip >= 2, `isolate ${iso.one} of ${iso.n}, restore ${iso.all}; readout ${iso.tip} line(s)`);

// M. a chart's menu (still on the Performance page of case I): the button in the chart's heading opens four choices; 'Copy
// data' puts the shown series on the clipboard, a row per point under a header of 'time' and the series' names, the
// time in local 'YYYY-MM-DD HH:MM:SS', and the chart says how many points it copied
const cm = await ev(`(async () => {
  const b = document.querySelector('main .chart button.chart-menu'); if (!b) return { why: 'no chart menu button on the Performance page' };
  b.click(); await new Promise(r => setTimeout(r, 150));
  const items = [...document.querySelectorAll('.menu button')].map(x => x.textContent);
  const copy = [...document.querySelectorAll('.menu button')].find(x => x.textContent === 'Copy data');
  if (!copy) return { why: 'no Copy data in the chart menu: ' + items.join('|') };
  copy.click(); await new Promise(r => setTimeout(r, 400));
  const lines = (await navigator.clipboard.readText()).split('\\n'), box = b.closest('.chart');
  return { items, lines: lines.length, head: lines[0].split('\\t'), series: box.querySelectorAll('.u-legend .u-series').length - 1,
    note: box.querySelector('.chart-note')?.textContent ?? '', firstTime: (lines[1] ?? '').split('\\t')[0], name: b.getAttribute('aria-label') };
})()`);
// a chart of two series or more adds Pick series (task 152)
check('M chart menu', !!cm && !cm.why && cm.items.join('|') === 'Copy image|Save image|Copy data|Export data (CSV)|Export Excel' + (cm.series >= 2 ? '|Pick series' : '') && cm.head[0] === 'time' && cm.head.length === cm.series + 1
  && cm.lines > 2 && /^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$/.test(cm.firstTime) && cm.note === `Copied ${cm.lines - 1} points` && String(cm.name).startsWith('Chart menu: '),
  cm?.why ?? `${cm.items.join('|')}; header ${cm.head.join(',')} for ${cm.series} series; ${cm.lines - 1} points from ${cm.firstTime}; note '${cm.note}'; named '${cm.name}'`);

// J. a grid past its page (a job's All runs; the proof seeds three days so the grid holds more than two pages): 200
// rows drawn and the 'show more' line; Copy all takes every row and leaves the grid as drawn; 'Show 200 more' draws 200
// more and keeps the focus on the line; 'Show all' draws the rest, hides the line and puts the focus on the grid. The
// buttons are found by their words, and a grid of 400 rows or fewer fails the case (the last two claims need a third page).
await go(`#/jobs?i=${idOf('demo-aurora-crm01')}&w=7d`);
const pg = await ev(`(async () => {
  const t = [...document.querySelectorAll('main table.grid')].find(x => Number(x.dataset.rows) > 200); if (!t) return null;
  const box = t.closest('.grid-box'), more = box.querySelector('.grid-more'), n = Number(t.dataset.rows);
  const drawn = () => t.querySelectorAll('tbody tr').length;
  const btn = w => more.hidden ? undefined : [...more.querySelectorAll('button')].find(b => b.textContent.trim().startsWith(w));
  const first = drawn(), line = more.hidden ? '' : more.textContent;
  const td = t.querySelector('tbody td'); const r = td.getBoundingClientRect();
  td.tabIndex = -1; td.focus();
  td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 4, clientY: r.top + 4 }));
  const copyAll = [...document.querySelectorAll('.menu button')].find(b => b.textContent.startsWith('Copy all'));
  if (!copyAll) return { why: 'no Copy all in the menu: ' + [...document.querySelectorAll('.menu button')].map(b => b.textContent).join('|') };
  copyAll.click();
  await new Promise(r => setTimeout(r, 400));
  const lines = (await navigator.clipboard.readText()).split('\\n').length, afterCopy = drawn();
  const moreBtn = btn('Show 200 more'); if (!moreBtn) return { why: "no 'Show 200 more' button on a grid of " + n + ' rows: ' + line };
  moreBtn.click(); await new Promise(r => setTimeout(r, 200));
  const second = drawn(), focusOnLine = more.contains(document.activeElement) && document.activeElement.tagName === 'BUTTON';
  const allBtn = btn('Show all'); if (!allBtn) return { why: "no 'Show all' button after the second page of " + n + ' rows' };
  allBtn.click(); await new Promise(r => setTimeout(r, 300));
  return { n, first, line, lines, afterCopy, second, focusOnLine, all: drawn(), hidden: more.hidden, focusGrid: document.activeElement === t.parentElement };
})()`);
check('J paging', !!pg && !pg.why && pg.n > 400 && pg.first === 200 && pg.line.startsWith(`The first 200 of ${pg.n} rows`) && pg.lines === pg.n + 1 && pg.afterCopy === 200
  && pg.second === 400 && pg.focusOnLine && pg.all === pg.n && pg.hidden && pg.focusGrid,
  pg?.why ?? (pg ? `${pg.n} rows (over 400: ${pg.n > 400}): ${pg.first} drawn, '${pg.line.slice(0, 40)}...'; Copy all ${pg.lines - 1} rows, still ${pg.afterCopy} drawn; more ${pg.second}, focus on the line ${pg.focusOnLine}; all ${pg.all}, line hidden ${pg.hidden}, focus on the grid ${pg.focusGrid}` : 'no grid over 200 rows on the Jobs page'));

// K. a pie's slices are filled wedges (a dashed stroke of width 2r left a notch at the centre): one wedge or disc per
// legend row, none stroked, the wedges' angles summing to the whole circle
await go(`#/storage?i=${idOf('demo-onprem-erp01')}&w=7d`);
const pies = await ev(`[...document.querySelectorAll('main .donut')].map(d => {
  const sl = [...d.querySelectorAll('svg path, svg circle')];
  const ang = p => { const m = p.getAttribute('d').match(/L([-0-9.]+) ([-0-9.]+) A[^ ]+ [^ ]+ 0 ([01]) 1 ([-0-9.]+) ([-0-9.]+)/);
    const a = (x, y) => Math.atan2(y - 60, x - 60); let v = a(+m[4], +m[5]) - a(+m[1], +m[2]); if (v < 0) v += 2 * Math.PI; if (m[3] === '1' && v < Math.PI) v += 2 * Math.PI; return v; };
  const total = sl.reduce((s, e) => s + (e.tagName === 'circle' ? 2 * Math.PI : ang(e)), 0);
  return { n: sl.length, rows: d.querySelectorAll('tbody tr').length, stroked: sl.filter(e => e.getAttribute('stroke-dasharray')).length, turns: total / (2 * Math.PI) };
})`);
check('K pies', pies.length >= 2 && pies.every(p => p.n === p.rows && p.stroked === 0 && Math.abs(p.turns - 1) < 0.001),
  pies.map(p => `${p.n} slice(s) for ${p.rows} row(s), ${p.turns.toFixed(4)} turn(s)`).join('; ') || 'no pie on the Storage page');

// L. the status colours: solid by default (an OK cell filled DBA Dash's green, a grid's header its blue), 'Colours'
// switches to quiet (the OK cell unfilled, the header the page's), the choice survives a reload, a second click is solid
await go('#/summary');
const colours = async () => JSON.parse(await ev(`(() => { const ok = document.querySelector('main td.status.ok'), th = document.querySelector('main table.grid > thead th');
  const b = [...document.querySelectorAll('header button, #bar button')].find(x => x.textContent.startsWith('Colours:'));
  return JSON.stringify({ attr: document.documentElement.getAttribute('data-status'), ok: ok ? getComputedStyle(ok).backgroundColor : 'no ok cell', th: th ? getComputedStyle(th).backgroundColor : 'no header', btn: b ? b.textContent : 'no button', stored: localStorage.getItem('pgvigil.status') }); })()`));
const clickColours = () => ev(`[...document.querySelectorAll('header button, #bar button')].find(x => x.textContent.startsWith('Colours:'))?.click(); 'ok'`);
const transparent = c => c === 'rgba(0, 0, 0, 0)' || c === 'transparent';
const solid1 = await colours();
await clickColours(); await sleep(200); const quiet1 = await colours();
await go('#/alerts'); await go('#/summary'); const quiet2 = await colours();
await clickColours(); await sleep(200); const solid2 = await colours();
check('L colours', solid1.attr === null && solid1.ok === 'rgb(0, 102, 56)' && solid1.th === 'rgb(0, 79, 131)' && solid1.btn === 'Colours: solid'
  && quiet1.attr === 'quiet' && transparent(quiet1.ok) && quiet1.th !== 'rgb(0, 79, 131)' && quiet1.btn === 'Colours: quiet' && quiet1.stored === 'quiet'
  && quiet2.attr === 'quiet' && transparent(quiet2.ok) && solid2.attr === null && solid2.ok === 'rgb(0, 102, 56)' && solid2.stored === 'solid',
  `solid: OK cell ${solid1.ok}, header ${solid1.th}, '${solid1.btn}'; quiet: attr ${quiet1.attr}, OK cell ${quiet1.ok}, header ${quiet1.th}, '${quiet1.btn}', stored ${quiet1.stored}; after another page: attr ${quiet2.attr}; back: OK cell ${solid2.ok}, stored ${solid2.stored}`);

// N. the range control: its panel (the quick ranges, the calendar periods, a start and an end, the zone chooser). The
// browser's own zone is pinned to America/Los_Angeles for the case, so it does not lean on the machine's. A fixed range
// of 12:00 to 13:00 UTC shows as 04:00 to 05:00 under the browser's zone; in the zone Asia/Tokyo (chosen without the
// chooser losing its place) as 21:00 to 22:00 in the two inputs and in the button's window text, and an end typed as
// 23:00 is applied as 14:00 UTC; 'Yesterday' is one whole day that ends at the zone's midnight; 'Today' is a period that
// follows now (w=today, the page still live); a chart's legend (uPlot's clock) and its readout (tz.ts) name the same
// minute, 17 hours later than under the browser's zone; a Log events row reads as the zone writes its instant; the zone
// survives a reload; Escape closes the panel with the focus back on its button; 'Browser time' puts the browser's own
// offset back; a click outside closes the panel
{   // its own scope: the names below are the case's alone
  await send('Emulation.setTimezoneOverride', { timezoneId: 'America/Los_Angeles' });
  await send('Page.reload'); await sleep(1500);   // the page starts over on the pinned zone
  const rangeBtn = `document.querySelector('#bar [aria-haspopup="dialog"]')`;
  const rangePanel = `document.querySelector('#bar [role="dialog"][aria-label="Time range"]')`;
  const zoneSel = `${rangePanel}.querySelector('select[aria-label="display time zone"]')`;
  const openRange = async () => { if (!(await ev(`!!${rangePanel}`))) await ev(`${rangeBtn}.click(); 'ok'`); await sleep(150); };
  const pickRange = async text => { await openRange(); const r = await ev(`(() => { const b = [...${rangePanel}.querySelectorAll('button')].find(x => x.firstChild?.textContent === ${JSON.stringify(text)}); if (!b) return 'no item ' + ${JSON.stringify(text)}; b.click(); return 'ok'; })()`); await sleep(700); return r; };
  // the choice rests 400 ms before it is taken (a closed list fires a change per key): wait it out and the redraw after it
  const setZone = async z => { await openRange(); const r = await ev(`(() => { const s = ${zoneSel}; if (![...s.options].some(o => o.value === ${JSON.stringify(z)})) return 'no zone ' + ${JSON.stringify(z)}; window.__zsel = s; s.value = ${JSON.stringify(z)}; s.dispatchEvent(new Event('change')); return 'ok'; })()`); await sleep(1500); return r; };
  const hashOf = async () => new URLSearchParams((await ev(`location.hash`)).split('?')[1] ?? '');
  const zoneTag = () => ev(`document.querySelector('#bar .range-zone-tag')?.textContent ?? 'no tag'`);
  const inputs = () => ev(`(() => { const p = ${rangePanel}; return { from: p.querySelector('input[aria-label="from"]').value, to: p.querySelector('input[aria-label="to"]').value, tag: document.querySelector('#bar .range-zone-tag').textContent }; })()`);
  // the middle point of the page's first chart: the readout's time (tz.ts) and the legend's (uPlot through tzDate), as minutes of the day
  const chartClock = () => ev(`(async () => { const o = document.querySelector('main .u-over'); if (!o) return null; o.scrollIntoView({ block: 'center' }); await new Promise(r => setTimeout(r, 200)); const r = o.getBoundingClientRect();
    o.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: r.left + r.width * 0.5, clientY: r.top + r.height / 2 })); await new Promise(r => setTimeout(r, 300));
    const tip = o.querySelector('.u-tip-time')?.textContent ?? '', leg = o.closest('.uplot').querySelector('.u-legend .u-series .u-value')?.textContent ?? '';
    const a = /(\\d{1,2}):(\\d{2}):\\d{2}/.exec(tip), b = /(\\d{1,2}):(\\d{2})\\s*(am|pm)/i.exec(leg);
    return { tip, leg, tipMin: a ? (Number(a[1]) % 24) * 60 + Number(a[2]) : -1, legMin: b ? (Number(b[1]) % 12 + (b[3].toLowerCase() === 'pm' ? 12 : 0)) * 60 + Number(b[2]) : -2 }; })()`);
  const erp = idOf('demo-onprem-erp01');
  const dayTo = new Date(Math.floor(Date.now() / 60000) * 60000), dayFrom = new Date(dayTo.getTime() - 86400e3), day = `from=${dayFrom.toISOString()}&to=${dayTo.toISOString()}`;

  await go('#/summary?from=2026-01-15T12:00:00.000Z&to=2026-01-15T13:00:00.000Z');
  await openRange();
  const shape = await ev(`(() => { const p = ${rangePanel}; if (!p) return null;
    return { groups: [...p.querySelectorAll('legend')].map(l => l.textContent).join('|'), items: p.querySelectorAll('button[aria-pressed]').length, zones: ${zoneSel}.options.length,
             expanded: ${rangeBtn}.getAttribute('aria-expanded'), inside: p.getBoundingClientRect().left >= 0 && p.getBoundingClientRect().right <= innerWidth }; })()`);
  const local = await inputs();
  const zoneSet = await setZone('Asia/Tokyo');
  const tokyo = await ev(`(() => { const p = ${rangePanel}; const f = d => new Date(d).toLocaleString(undefined, { hour12: false, timeZone: 'Asia/Tokyo' });
    return { tag: document.querySelector('#bar .range-zone-tag').textContent, from: p.querySelector('input[aria-label="from"]').value, to: p.querySelector('input[aria-label="to"]').value,
             title: ${rangeBtn}.title, want: f('2026-01-15T12:00:00.000Z') + ' to ' + f('2026-01-15T13:00:00.000Z'), stored: localStorage.getItem('pgvigil.tz'), same: ${zoneSel} === window.__zsel }; })()`);
  // a typed end of 23:00 on the zone's clock is 14:00 UTC: Apply writes that instant, the start stays 12:00 UTC
  await ev(`(() => { const p = ${rangePanel}; p.querySelector('input[aria-label="to"]').value = '2026-01-15T23:00'; [...p.querySelectorAll('button')].find(b => b.textContent === 'Apply').click(); return 'ok'; })()`); await sleep(700);
  const applied = await hashOf();
  // a run in the minute before Tokyo's midnight or the two after it waits them out: the day must not turn between this
  // script's midnight and the page's, and a period seconds old reads a minute (router.ts)
  { const t = (Date.now() + 9 * 3600e3) % 86400e3; if (t < 120e3 || t > 86400e3 - 60e3) await sleep(185e3); }
  const picked = await pickRange('Yesterday'); const yest = await hashOf();
  const yFrom = Date.parse(yest.get('from') ?? ''), yTo = Date.parse(yest.get('to') ?? '');
  const midnight = Math.floor((Date.now() + 9 * 3600e3) / 86400e3) * 86400e3 - 9 * 3600e3;   // Tokyo's midnight today, as an instant
  const yText = await ev(`${rangeBtn}.textContent`);
  await pickRange('Today'); const today = await hashOf();
  const live = await ev(`(() => { const f = d => new Date(d).toLocaleString(undefined, { hour12: false, timeZone: 'Asia/Tokyo' });
    return { text: ${rangeBtn}.textContent, title: ${rangeBtn}.title, want: f(${midnight}) + ' to ', refresh: !!document.querySelector('#bar select[aria-label="Auto refresh of a live page"]') }; })()`);
  // a chart and a grid under the zone, on a fixed day so both zones read the same points
  await go(`#/performance?i=${erp}&${day}`);
  const chartTokyo = await chartClock();
  const logsApi = await (await fetch(`${base}api/logs?instance=${erp}&${day}`)).json();
  const firstAt = logsApi.events.rows[0]?.[logsApi.events.columns.indexOf('at')];
  await go(`#/logs?i=${erp}&${day}`);
  const gridTokyo = firstAt ? await ev(`(() => { const want = new Date(${JSON.stringify(firstAt)}).toLocaleString(undefined, { hour12: false, timeZone: 'Asia/Tokyo' });
    return { want, found: [...document.querySelectorAll('main table.grid > tbody > tr > td:first-child')].some(td => td.textContent === want) }; })()`) : null;
  await send('Page.reload'); await sleep(1500); await go('#/summary?w=today');
  const kept = { tag: await zoneTag(), stored: await ev(`localStorage.getItem('pgvigil.tz')`) };
  await openRange();
  const esc = await ev(`(async () => { document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); await new Promise(r => setTimeout(r, 150));
    return { gone: !${rangePanel}, focus: document.activeElement === ${rangeBtn}, expanded: ${rangeBtn}.getAttribute('aria-expanded') }; })()`);
  await setZone('local');
  const back = await ev(`(() => { const m = -new Date().getTimezoneOffset(), a = Math.abs(m), two = n => String(n).padStart(2, '0');
    return { tag: document.querySelector('#bar .range-zone-tag').textContent, want: 'UTC' + (m < 0 ? '-' : '+') + two(Math.floor(a / 60)) + ':' + two(a % 60), stored: localStorage.getItem('pgvigil.tz') }; })()`);
  await ev(`document.body.dispatchEvent(new MouseEvent('mousedown', { bubbles: true })); 'ok'`); await sleep(150);
  const shut = await ev(`!${rangePanel}`);
  // another address while the panel is open (the browser's Back, a link followed by the keyboard): the panel closes and
  // the focus that was in it goes back to the range button, never to the page's body
  await openRange();
  const moved = await ev(`(async () => { const inPanel = ${rangePanel}?.contains(document.activeElement) ?? false;
    location.hash = location.hash.startsWith('#/instances') ? '#/summary' : '#/instances'; await new Promise(r => setTimeout(r, 400));
    return { inPanel, gone: !${rangePanel}, onBtn: document.activeElement === ${rangeBtn}, body: document.activeElement === document.body }; })()`);
  await go(`#/performance?i=${erp}&${day}`);
  const chartLocal = await chartClock();
  await send('Emulation.setTimezoneOverride', { timezoneId: '' });
  const ahead = chartTokyo && chartLocal ? (chartTokyo.tipMin - chartLocal.tipMin + 1440) % 1440 : -1;   // Tokyo is 17 h ahead of Los Angeles in November and 16 h in its summer
  check('N range', !!shape && shape.groups === 'Quick ranges|Calendar periods|A start and an end|Type a range' && shape.items === 16 && shape.zones > 2 && shape.expanded === 'true' && shape.inside
    && local.from === '2026-01-15T04:00' && local.to === '2026-01-15T05:00' && local.tag === 'UTC-08:00'
    && zoneSet === 'ok' && tokyo.tag === 'UTC+09:00' && tokyo.from === '2026-01-15T21:00' && tokyo.to === '2026-01-15T22:00' && tokyo.title === tokyo.want && tokyo.stored === 'Asia/Tokyo' && tokyo.same
    && applied.get('from') === '2026-01-15T12:00:00.000Z' && applied.get('to') === '2026-01-15T14:00:00.000Z'
    && picked === 'ok' && yTo === midnight && yTo - yFrom === 86400e3 && !yest.get('w') && /^Range: .+ - .+$/.test(yText)
    && today.get('w') === 'today' && !today.get('from') && live.text === 'Range: Today' && live.title.startsWith(live.want) && live.title.endsWith('(follows now)') && live.refresh
    && !!chartTokyo && chartTokyo.tipMin >= 0 && chartTokyo.tipMin === chartTokyo.legMin && !!chartLocal && chartLocal.tipMin === chartLocal.legMin && (ahead === 17 * 60 || ahead === 16 * 60)
    && !!gridTokyo && gridTokyo.found
    && kept.tag === 'UTC+09:00' && kept.stored === 'Asia/Tokyo' && esc.gone && esc.focus && esc.expanded === 'false'
    && back.tag === back.want && back.stored === 'local' && shut && moved.inPanel && moved.gone && moved.onBtn && !moved.body,
    `panel ${shape?.groups} with ${shape?.items} ranges and ${shape?.zones} zones, inside the window ${shape?.inside}; browser zone: inputs ${local.from} to ${local.to}, tag ${local.tag}; Asia/Tokyo (${zoneSet}): tag ${tokyo.tag}, inputs ${tokyo.from} to ${tokyo.to}, the window text as the zone writes it ${tokyo.title === tokyo.want}, the chooser kept its place ${tokyo.same}; Apply wrote ${applied.get('from')} to ${applied.get('to')}; Yesterday (${picked}): ${(yTo - yFrom) / 3600e3} h ending at the zone's midnight ${yTo === midnight}, '${yText}'; Today: w=${today.get('w')}, '${live.text}', from the zone's midnight ${live.title.startsWith(live.want)}, live ${live.refresh}; chart under Tokyo: readout '${chartTokyo?.tip}' and legend '${chartTokyo?.leg}', under the browser's zone '${chartLocal?.tip}' and '${chartLocal?.leg}', ${ahead / 60} h apart; a log row as the zone writes it ${gridTokyo?.found} ('${gridTokyo?.want}'); after a reload: tag ${kept.tag}, stored ${kept.stored}; Escape: closed ${esc.gone}, focus on the button ${esc.focus}; browser time: tag ${back.tag} (wanted ${back.want}), stored ${back.stored}; a click outside closed it ${shut}; another address with the focus in it: closed ${moved.gone}, the focus on the button ${moved.onBtn}`);
}

// O. the time strip above an event grid: the Log events of demo-onprem-erp01 over a fixed day ending three minutes back
// (a demo tick then adds no row the API read did not count). The grid is sorted by 'ms' first. A drag over the strip's
// right half narrows the grid to the rows of that half (counted here from the same API read), keeps the sort, and its
// count line names the stretch (the export carries that line); 'Whole range' puts every row back; on the keyboard Home,
// three steps right, two more with Shift and Enter narrow to steps 3 to 5; a Shift+click on step 10 stretches that to
// steps 3-10; Escape shows the whole range again and hides 'Whole range'. Then demo-onprem-sql01's Deadlocks page carries
// a strip when its read holds two deadlocks or more
{   // its own scope
  const to = new Date(Math.floor(Date.now() / 60000) * 60000 - 3 * 60000), from = new Date(to.getTime() - 86400e3);
  const q = `from=${from.toISOString()}&to=${to.toISOString()}`, erp = idOf('demo-onprem-erp01');
  const api = await (await fetch(`${base}api/logs?instance=${erp}&${q}`)).json();
  const at = api.events.rows.map(r => Date.parse(r[api.events.columns.indexOf('at')]));
  const step = 86400e3 / 60, inSteps = (a, b) => at.filter(t => t >= from.getTime() + a * step && (b === 59 ? t <= to.getTime() : t < from.getTime() + (b + 1) * step)).length;
  await go(`#/logs?i=${erp}&${q}`);
  const band = `document.querySelector('main [aria-roledescription="time strip"]')`;
  const state = () => ev(`(() => { const b = ${band}; if (!b) return null; const box = b.closest('.strip-box'), t = box.querySelector('table.grid');
    const j = [...t.querySelectorAll('thead tr:first-child th')].findIndex(h => h.textContent === 'ms');
    const ms = [...t.querySelectorAll('tbody tr')].map(tr => tr.children[j]?.textContent.replace(/,/g, '').trim()).filter(v => v).map(Number);
    return { said: box.querySelector('[role="status"]').textContent, total: Number(t.dataset.rows), steps: b.children.length, dim: b.querySelectorAll('.out').length,
             count: box.querySelector('.filter-count').textContent, sorted: ms.every((v, i) => i === 0 || ms[i - 1] <= v),
             whole: !box.querySelector('.strip-head button').hidden, label: b.getAttribute('aria-label'), rect: JSON.parse(JSON.stringify(b.getBoundingClientRect())) }; })()`);
  const s0 = await state();
  let dragged = null, redrawn = null, back = null, keyed = null, shifted = null, esc = null;
  if (s0) {
    await ev(`[...${band}.closest('.strip-box').querySelectorAll('table.grid thead tr:first-child th')].find(h => h.textContent === 'ms').click(); 'ok'`); await sleep(200);
    await ev(`${band}.scrollIntoView({ block: 'center' }); 'ok'`); await sleep(200);
    const r = (await state()).rect, y = r.top + r.height / 2, x = i => r.left + (i + 0.5) * r.width / 60;
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: x(30), y, button: 'left', buttons: 1, clickCount: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: x(45), y, button: 'left', buttons: 1 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x(59), y, button: 'left', buttons: 0, clickCount: 1 });
    await sleep(300); dragged = await state();
    await ev(`${band}.closest('.strip-box').querySelector('.strip-head button').click(); 'ok'`); await sleep(300); back = await state();
    await ev(`(() => { const b = ${band}; b.focus(); const k = (key, shiftKey = false) => b.dispatchEvent(new KeyboardEvent('keydown', { key, shiftKey, bubbles: true, cancelable: true }));
      k('Home'); k('ArrowRight'); k('ArrowRight'); k('ArrowRight'); k('ArrowRight', true); k('ArrowRight', true); k('Enter'); return 'ok'; })()`);
    await sleep(300); keyed = await state();
    // the page drawn again as a return to the browser tab draws it (main.ts): a fresh grid, the narrow put back on it
    await ev(`document.dispatchEvent(new Event('visibilitychange')); 'ok'`); await sleep(2500); redrawn = await state();
    const r2 = (await state()).rect, y2 = r2.top + r2.height / 2, x2 = i => r2.left + (i + 0.5) * r2.width / 60;
    await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: x2(10), y: y2, button: 'left', buttons: 1, clickCount: 1, modifiers: 8 });
    await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: x2(10), y: y2, button: 'left', buttons: 0, clickCount: 1, modifiers: 8 });
    await sleep(300); shifted = await state();
    await ev(`${band}.focus(); ${band}.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); 'ok'`); await sleep(300); esc = await state();
  }
  const n = at.length, right = inSteps(30, 59), mid = inSteps(3, 5), wide = inSteps(3, 10), whole = 'Whole range. Drag across the strip to narrow the grid.';
  // the Deadlocks page of a SQL Server instance: a strip when its read holds two deadlocks or more
  const sql = idOf('demo-onprem-sql01');
  const dl = await (await fetch(`${base}api/mssql/xe?instance=${sql}&part=deadlocks&${q}`)).json();
  const nDl = dl.deadlocks?.rows?.length ?? 0;
  await go(`#/mssql_deadlocks?i=${sql}&${q}`);
  const dlStrip = await ev(`!!document.querySelector('main [aria-roledescription="time strip"]')`);
  check('O time strip', !!s0 && n >= 2 && right > 0 && mid > 0 && s0.steps === 60 && s0.said === whole && s0.total === n && !s0.whole && s0.label.startsWith(`Log events: ${n} rows`)
    && !!dragged && dragged.said.endsWith(`: ${right} of ${n} rows.`) && dragged.total === right && dragged.dim === 30 && dragged.whole && right < n && dragged.sorted
    && dragged.count.startsWith(`${right} of ${n} rows shown (the stretch `)
    && !!back && back.said === whole && back.total === n && back.dim === 0 && !back.whole && back.sorted && back.count === ''
    && !!keyed && keyed.said.endsWith(`: ${mid} of ${n} rows.`) && keyed.total === mid && keyed.dim === 57
    && !!redrawn && redrawn.total === mid && redrawn.whole && redrawn.said === keyed.said && redrawn.dim === 57
    && !!shifted && shifted.said.endsWith(`: ${wide} of ${n} rows.`) && shifted.total === wide && shifted.dim === 52
    && !!esc && esc.said === whole && esc.total === n && esc.dim === 0 && !esc.whole
    && dlStrip === (nDl >= 2),
    s0 ? `${n} log events, ${s0.steps} steps, ${s0.total} in the grid; sorted by ms, a drag over steps 30-59: '${dragged?.said}' (wanted ${right}), ${dragged?.total} in the grid, '${dragged?.count}', still sorted ${dragged?.sorted}, ${dragged?.dim} steps dimmed; Whole range: ${back?.total} in the grid, ${back?.dim} dimmed, still sorted ${back?.sorted}; keys to steps 3-5: '${keyed?.said}' (wanted ${mid}), ${keyed?.dim} dimmed; drawn again: ${redrawn?.total} in the grid, '${redrawn?.said}', ${redrawn?.dim} dimmed; Shift+click on step 10: '${shifted?.said}' (wanted ${wide}), ${shifted?.dim} dimmed; Escape: ${esc?.total} in the grid, Whole range hidden ${!esc?.whole}; Deadlocks of sql01: ${nDl} in the read, a strip ${dlStrip}`
       : `no strip on the Log events page (${n} events from the API)`);
}

// P. a link to another page opens that page at its top, wherever the reader stood on the page before (Allen
// 2026-11-11: 'when I click on something it takes me down to the page and I have to scroll all the way up'): the
// fleet Summary scrolled to its end, the lowest link in it to an instance's Summary (a page taller than the window)
// clicked like a reader would; the new page must be seen rendered and be taller than the window, so a page that never
// rendered or one too short to scroll cannot pass by itself
{   // its own scope
  await go('#/summary');
  const low = await ev(`(() => { const path = h => h.split('?')[0] + '|' + (new URLSearchParams(h.split('?')[1] ?? '').get('i') ?? '');
    const here = path(location.hash), ls = [...document.querySelectorAll('main a[href^="#/summary?"]')].filter(a => /[?&]i=\\d/.test(a.getAttribute('href')) && path(a.getAttribute('href')) !== here);
    const a = ls[ls.length - 1]; if (!a) return null; a.scrollIntoView({ block: 'end' });
    return { href: a.getAttribute('href'), y: Math.round(window.scrollY), tall: document.documentElement.scrollHeight > innerHeight + 200 }; })()`);
  let after = null;
  if (low) {
    await ev(`(() => { const a = [...document.querySelectorAll('main a[href^="#/"]')].filter(x => x.getAttribute('href') === ${JSON.stringify(low.href)}).pop();
      a.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window })); return 'ok'; })()`);
    let seen = false;
    for (let i = 0; i < 40 && !seen; i++) { await sleep(250); seen = await ev(`location.hash === ${JSON.stringify(low.href)} && !!document.querySelector('main section, main .grid-box, main .chart') && !document.querySelector('main > p.empty[role=status]')`); }
    await sleep(600);
    after = { ...(await ev(`({ hash: location.hash, y: Math.round(window.scrollY), tall: document.documentElement.scrollHeight > innerHeight + 200 })`)), seen };
  }
  check('P new page at its top', !!low && low.tall && low.y > 0 && !!after && after.hash === low.href && after.seen && after.tall && after.y === 0,
    low ? `the Summary ${low.tall ? 'taller' : 'NOT taller'} than the window, scrolled to ${low.y} px; '${low.href}' clicked: ${after?.hash === low.href ? 'opened' : 'NOT opened'}, rendered ${after?.seen}, ${after?.tall ? 'taller' : 'NOT taller'} than the window, at ${after?.y} px` : 'no link to an instance Summary on the fleet Summary');
}

// ---- task 152 (K09.01-K09.03, part 1 J8): the footer, the range's steps and typed form, and the charts' frame
const charts = () => ev(`[...document.querySelectorAll('main .chart')].filter(c => c.querySelector('.u-over')).map(c => ({ title: c.querySelector('h3')?.firstChild?.textContent ?? '', first: c.dataset.first, last: c.dataset.last }))`);
const params = async () => new URLSearchParams((await ev(`location.hash`)).split('?')[1] ?? '');
const waitCharts = async () => { for (let i = 0; i < 40; i++) { if (await ev(`document.querySelectorAll('main .u-over').length > 0 && !document.querySelector('main > p.empty[role=status]')`)) break; await sleep(250); } await sleep(600); };
const fixedDay = (() => { const to = new Date(Math.floor(Date.now() / 60000) * 60000 - 3 * 60000); return { from: new Date(to.getTime() - 86400e3), to }; })();
const dayQ = `from=${fixedDay.from.toISOString()}&to=${fixedDay.to.toISOString()}`;

// Q. a drag across a chart sets the page's range: on erp01's Performance page over a fixed day, a drag from 40 % to 60 %
// of the first chart's plot writes from / to into the address (whole minutes, within two minutes and a pixel's worth of
// the dragged times read off the chart's own span), drops w=, and every chart of the page drawn again inside that range
{
  const erp = idOf('demo-onprem-erp01');
  await go(`#/performance?i=${erp}&${dayQ}`); await waitCharts();
  const before = await charts();
  await ev(`document.querySelector('main .u-over').scrollIntoView({ block: 'center' }); 'ok'`); await sleep(200);
  const r = await ev(`JSON.parse(JSON.stringify(document.querySelector('main .u-over').getBoundingClientRect()))`);
  const y = r.top + r.height / 2, xa = r.left + 0.4 * r.width, xb = r.left + 0.6 * r.width;
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: xa, y });
  await send('Input.dispatchMouseEvent', { type: 'mousePressed', x: xa, y, button: 'left', buttons: 1, clickCount: 1 });
  for (let k = 1; k <= 5; k++) await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: xa + k * (xb - xa) / 5, y, button: 'left', buttons: 1 });
  await send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: xb, y, button: 'left', buttons: 0, clickCount: 1 });
  await sleep(500); await waitCharts();
  const q = await params(), f = Date.parse(q.get('from') ?? ''), t = Date.parse(q.get('to') ?? '');
  const c0 = before[0] ?? {}, s0 = Date.parse(c0.first), s1 = Date.parse(c0.last), px = (s1 - s0) / r.width;
  const wantF = s0 + 0.4 * (s1 - s0), wantT = s0 + 0.6 * (s1 - s0), tol = 120e3 + 2 * px;
  const after = await charts();
  const inside = after.filter(c => Date.parse(c.first) >= f - (t - f) / 10 && Date.parse(c.last) <= t + (t - f) / 10).length;
  check('Q drag sets the range', before.length >= 2 && !q.get('w') && Math.abs(f - wantF) <= tol && Math.abs(t - wantT) <= tol && f % 60000 === 0 && t % 60000 === 0
    && (await ev(`location.hash.startsWith('#/performance?')`)) && after.length === before.length && inside === after.length,
    `${before.length} charts; a drag over 40-60 % of '${c0.title}' wrote ${q.get('from')} to ${q.get('to')} (wanted about ${new Date(wantF).toISOString()} to ${new Date(wantT).toISOString()}, within ${Math.round(tol / 1000)} s), w=${q.get('w')}; after it ${inside} of ${after.length} charts drawn inside the range`);
}

// R. one cursor across the page: the pointer over the first chart's middle shows the readout on every chart of the page
// whose span holds that moment, each naming the same time
{
  const erp = idOf('demo-onprem-erp01');
  await go(`#/performance?i=${erp}&${dayQ}`); await waitCharts();
  await ev(`document.querySelector('main .u-over').scrollIntoView({ block: 'center' }); 'ok'`); await sleep(200);
  const r = await ev(`JSON.parse(JSON.stringify(document.querySelector('main .u-over').getBoundingClientRect()))`);
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: r.left + r.width * 0.5, y: r.top + r.height / 2 }); await sleep(400);
  const tips = await ev(`[...document.querySelectorAll('main .u-over')].map(o => { const t = o.querySelector('.u-tip'); return t && !t.hidden ? (t.querySelector('.u-tip-time')?.textContent ?? '') : null; })`);
  const shown = tips.filter(x => x !== null);
  check('R one cursor', tips.length >= 2 && shown.length === tips.length && shown.every(x => x === shown[0]) && !!shown[0],
    `${shown.length} of ${tips.length} charts show the readout, times ${[...new Set(shown)].join(' | ')}`);
  await send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: 5, y: 5 });
}

// S. a setting change is drawn on its instance's charts: the first PostgreSQL instance whose frame read over the last
// three days holds a 'setting' event; its Performance page over two hours either side: every chart whose span holds the
// moment has a setting mark at that instant, named with the event's words, placed at the moment's share of the chart's
// span (within 2 %); another instance's page over the same window draws exactly its own events; the mark opens its rows
// (the Configuration page over ten minutes around it)
{
  const ids = inst.rows.filter(r => String(r[c.indexOf('engine')] ?? 'postgres') !== 'sqlserver').map(r => r[c.indexOf('instance_id')]);
  const now = Date.now(), win = `from=${new Date(now - 3 * 86400e3 + 60e3).toISOString()}&to=${new Date(now).toISOString()}`;
  let hit = null, other = null;
  for (const id of ids) {
    const d = await (await fetch(`${base}api/frame/events?instance=${id}&${win}`)).json();
    const ev0 = (d.events?.rows ?? []).map(r => Object.fromEntries(d.events.columns.map((k, i) => [k, r[i]]))).find(e => e.kind === 'setting');
    if (ev0 && !hit) hit = { id, ev: ev0 }; else if (!ev0 && !other) other = id;
    if (hit && other) break;
  }
  let res = null, otherRes = null, opened = null;
  if (hit) {
    const at = Date.parse(hit.ev.at), w = `from=${new Date(at - 2 * 3600e3).toISOString()}&to=${new Date(at + 2 * 3600e3).toISOString()}`;
    await go(`#/performance?i=${hit.id}&${w}`); await waitCharts(); await sleep(800);
    res = await ev(`[...document.querySelectorAll('main .chart')].filter(c => c.querySelector('.u-over')).map(c => {
      const s0 = Date.parse(c.dataset.first), s1 = Date.parse(c.dataset.last), o = c.querySelector('.u-over').getBoundingClientRect();
      const m = [...c.querySelectorAll('a.chart-mark[data-kind="setting"]')].find(a => a.dataset.at === ${JSON.stringify(new Date(at).toISOString())});
      const r = m ? m.getBoundingClientRect() : null, list = c.querySelector('details.chart-marks');
      return { holds: s0 <= ${at} && ${at} <= s1, mark: !!m, label: m?.getAttribute('aria-label') ?? '', share: r ? ((r.left + r.width / 2) - o.left) / o.width : -1, want: (${at} - s0) / (s1 - s0),
               untabbed: !!m && m.getAttribute('tabindex') === '-1', listed: !!list && [...list.querySelectorAll('a')].some(a => a.textContent.includes(${JSON.stringify(hit.ev.label)})) };
    })`);
    // another instance's page over the same window: its marks are its own events, every one of them in each chart's span
    if (other) {
      const d = await (await fetch(`${base}api/frame/events?instance=${other}&${w}`)).json();
      const own = (d.events?.rows ?? []).map(r => new Date(r[d.events.columns.indexOf('at')]).toISOString());
      await go(`#/performance?i=${other}&${w}`); await waitCharts(); await sleep(800);
      const drawn = await ev(`[...document.querySelectorAll('main a.chart-mark')].map(a => a.dataset.at)`);
      otherRes = { own: own.length, drawn: drawn.length, foreign: drawn.filter(x => !own.includes(x)).length };
      await go(`#/performance?i=${hit.id}&${w}`); await waitCharts(); await sleep(800);
    }
    await ev(`(() => { const a = document.querySelector('main a.chart-mark[data-kind="setting"]'); if (a) a.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window })); return 'ok'; })()`);
    await sleep(600);
    const q = await params();
    opened = { hash: await ev(`location.hash.split('?')[0]`), from: q.get('from'), i: q.get('i') };
  }
  const holding = (res ?? []).filter(x => x.holds);
  check('S setting mark', !!hit && holding.length >= 2 && holding.every(x => x.mark && x.untabbed && x.listed && x.label.includes(hit.ev.label) && x.label.startsWith('Setting change at ') && Math.abs(x.share - x.want) <= 0.02)
    && (!other || (otherRes && otherRes.foreign === 0)) && !!opened && opened.hash === '#/config' && opened.i === String(hit.id) && Date.parse(opened.from) === Date.parse(hit.ev.at) - 5 * 60e3,
    hit ? `instance ${hit.id}: '${hit.ev.label}' at ${hit.ev.at}; ${holding.filter(x => x.mark).length} of ${holding.length} charts holding it carry the mark, shares ${holding.map(x => `${x.share.toFixed(3)}/${x.want.toFixed(3)}`).join(' ')}; another instance (${other}): ${otherRes ? `${otherRes.drawn} marks drawn, ${otherRes.own} own events, ${otherRes.foreign} foreign` : 'none without a setting change'}; the mark opened ${opened?.hash} i=${opened?.i} from ${opened?.from}`
        : 'no PostgreSQL instance with a setting change in the last three days');
}

// T. clickable slices, Top N and the pie's menu: on erp01's Database info page the 'Databases by size' wedge of a
// database opens that database's page (the address the slice names); a pie of over five slices offers its Top N: Top 5
// draws five wedges (four and 'other') and five legend rows, All draws every slice, the choice kept per browser; the pie
// menu offers the four items and Copy data copies every slice under a header
{
  const erp = idOf('demo-onprem-erp01');
  await go(`#/dbinfo?i=${erp}&w=24h`);
  const slice = await ev(`(() => { const d = [...document.querySelectorAll('main .donut')].find(x => x.querySelector('h3')?.firstChild?.textContent === 'Databases by size'); if (!d) return null;
    const w = d.querySelector('svg [data-href]'); if (!w) return { none: true }; const to = w.getAttribute('data-href');
    w.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window })); return { to }; })()`);
  await sleep(1500);
  const landed = await ev(`({ hash: location.hash, page: !!document.querySelector('main section, main .grid-box') })`);
  let top = null, menu = null;
  for (const h of [`#/dbinfo?i=${erp}&w=24h`, `#/connections?i=${erp}&w=24h`, `#/storage?i=${erp}&w=7d`, `#/dbinfo?i=${idOf('demo-rds-orders01')}&w=24h`]) {
    await go(h);
    top = await ev(`(async () => { const d = [...document.querySelectorAll('main .donut')].find(x => x.querySelector('select.donut-top')); if (!d) return null;
      const s = d.querySelector('select.donut-top'), title = d.querySelector('h3').firstChild.textContent, n = () => ({ wedges: d.querySelectorAll('svg path, svg circle').length, rows: d.querySelectorAll('tbody tr').length });
      s.value = '5'; s.dispatchEvent(new Event('change')); await new Promise(r => setTimeout(r, 150)); const five = n();
      const allOpt = [...s.options].find(o => o.value === '0'); s.value = '0'; s.dispatchEvent(new Event('change')); await new Promise(r => setTimeout(r, 150)); const every = n();
      const stored = Object.keys(localStorage).filter(k => k.startsWith('pgvigil.topn.')).map(k => localStorage.getItem(k));
      const b = d.querySelector('button.chart-menu'); b.click(); await new Promise(r => setTimeout(r, 150));
      const items = [...document.querySelectorAll('.menu button')].map(x => x.textContent);
      [...document.querySelectorAll('.menu button')].find(x => x.textContent === 'Copy data')?.click(); await new Promise(r => setTimeout(r, 400));
      const lines = (await navigator.clipboard.readText()).split('\\n');
      return { page: location.hash.split('?')[0], title, five, every, all: Number(allOpt.textContent.replace(/\\D/g, '')), stored, items, lines: lines.length, head: lines[0] }; })()`);
    if (top) break;
  }
  check('T slices, Top N, pie menu', !!slice && !slice.none && landed.hash === slice.to && landed.page && !!top && top.five.wedges === 5 && top.five.rows === 5 && top.every.rows === top.all && top.every.wedges === top.all
    && top.stored.includes('0') && top.items.join('|') === 'Copy image|Save image|Copy data|Export data (CSV)|Export Excel' && top.lines === top.all + 1 && top.head === 'name\tsize\tshare_pct',
    `${slice ? (slice.none ? 'no wedge with a page' : `the wedge opened ${landed.hash} (wanted ${slice.to}), rendered ${landed.page}`) : "no 'Databases by size' pie"}; ${top ? `${top.page} '${top.title}': Top 5 ${top.five.wedges} wedges / ${top.five.rows} rows, All ${top.every.wedges} / ${top.every.rows} of ${top.all}, stored ${top.stored.join(',')}; menu ${top.items.join('|')}; Copy data ${top.lines} lines '${top.head}'` : 'no pie over five slices on the pages tried'}`);
}

// U. Pick series: the chart menu's item opens a tick per series; unticking the first hides it on the legend, the choice
// stays after the page is drawn again, All shows every series again, Done gives the focus back to the menu button
{
  const erp = idOf('demo-onprem-erp01');
  await go(`#/performance?i=${erp}&${dayQ}`); await waitCharts();
  const title = await ev(`[...document.querySelectorAll('main .chart')].find(c => c.querySelectorAll('.u-legend .u-series').length > 2)?.querySelector('h3').firstChild.textContent ?? null`);
  const box = `[...document.querySelectorAll('main .chart')].find(c => c.querySelector('h3')?.firstChild?.textContent === ${JSON.stringify(title)})`;
  const off = () => ev(`(() => { const c = ${box}; return c ? [...c.querySelectorAll('.u-legend .u-series')].slice(1).map(r => r.classList.contains('u-off')) : null; })()`);
  let p1 = null, kept = null, back = null;
  if (title) {
    p1 = await ev(`(async () => { const c = ${box}; c.querySelector('button.chart-menu').click(); await new Promise(r => setTimeout(r, 150));
      const it = [...document.querySelectorAll('.menu button')].find(x => x.textContent === 'Pick series'); if (!it) return { why: 'no Pick series' }; it.click(); await new Promise(r => setTimeout(r, 150));
      const p = c.querySelector('fieldset.chart-pick'); const ticks = [...p.querySelectorAll('input[type=checkbox]')];
      ticks[0].click(); await new Promise(r => setTimeout(r, 150));
      return { ticks: ticks.length, focusIn: p.contains(document.activeElement) }; })()`);
    const offNow = await off();
    await ev(`document.dispatchEvent(new Event('visibilitychange')); 'ok'`); await sleep(2500); await waitCharts();
    kept = await off();
    back = await ev(`(async () => { const c = ${box}; c.querySelector('button.chart-menu').click(); await new Promise(r => setTimeout(r, 150));
      [...document.querySelectorAll('.menu button')].find(x => x.textContent === 'Pick series').click(); await new Promise(r => setTimeout(r, 150));
      const p = c.querySelector('fieldset.chart-pick'); [...p.querySelectorAll('button')].find(b => b.textContent === 'All').click(); await new Promise(r => setTimeout(r, 150));
      [...p.querySelectorAll('button')].find(b => b.textContent === 'Done').click(); await new Promise(r => setTimeout(r, 150));
      return { open: !!c.querySelector('fieldset.chart-pick'), focus: document.activeElement === c.querySelector('button.chart-menu') }; })()`);
    p1 = { ...p1, offNow };
  }
  const all = await off();
  check('U pick series', !!title && !!p1 && !p1.why && p1.ticks >= 2 && p1.offNow[0] === true && p1.offNow.slice(1).every(x => !x) && kept?.[0] === true && !!back && !back.open && back.focus && all.every(x => !x),
    title ? (p1?.why ?? `'${title}': ${p1.ticks} ticks; the first unticked: legend off ${JSON.stringify(p1.offNow)}; drawn again ${JSON.stringify(kept)}; All then Done: closed ${!back?.open}, focus on the menu button ${back?.focus}, legend ${JSON.stringify(all)}`) : 'no chart of three series or more on Performance');
}

// V. the range's steps: on a fixed hour 12:00-13:00 UTC, Earlier is 11:00-12:00, Later back to 12:00-13:00, Zoom out
// 11:30-13:30, the key [ is Earlier; on the preset 1h Later is disabled and Zoom out is the preset 4h (the next at least
// twice as long); the key ] on a page whose range ends now leaves it as it is
{
  const at = s => Date.parse(`2026-01-15T${s}:00.000Z`);
  const press = async name => { await ev(`document.querySelector('#bar .range button[aria-label^=${JSON.stringify(name)}]').click(); 'ok'`); await sleep(700); const q = await params(); return [Date.parse(q.get('from') ?? ''), Date.parse(q.get('to') ?? ''), q.get('w')]; };
  await go('#/summary?from=2026-01-15T12:00:00.000Z&to=2026-01-15T13:00:00.000Z');
  const e1 = await press('Earlier'), l1 = await press('Later'), z1 = await press('Zoom out');
  await go('#/summary?from=2026-01-15T12:00:00.000Z&to=2026-01-15T13:00:00.000Z');
  await ev(`document.body.focus(); document.dispatchEvent(new KeyboardEvent('keydown', { key: '[', bubbles: true, cancelable: true })); 'ok'`); await sleep(700);
  const k1 = await params();
  await go('#/summary?w=1h');
  // Later on a range that ends now: off in its place - aria-disabled and focusable, never the disabled attribute - with
  // its reason as its description and its title
  const dis = await ev(`(() => { const b = document.querySelector('#bar .range button[aria-label^="Later"]'); const n = b.getAttribute('aria-describedby') ? document.getElementById(b.getAttribute('aria-describedby')) : null;
    return { off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled, described: n ? n.textContent.trim() : '', title: b.title, tab: b.tabIndex }; })()`);
  const zp = await press('Zoom out');
  await ev(`document.dispatchEvent(new KeyboardEvent('keydown', { key: ']', bubbles: true, cancelable: true })); 'ok'`); await sleep(500);
  const kp = await params();
  check('V range steps', e1[0] === at('11:00') && e1[1] === at('12:00') && l1[0] === at('12:00') && l1[1] === at('13:00') && z1[0] === at('11:30') && z1[1] === at('13:30')
    && Date.parse(k1.get('from')) === at('11:00') && dis.off && !dis.disabledAttr && dis.tab === 0 && dis.described === 'the range already ends now' && dis.title === 'the range already ends now'
    && zp[2] === '4h' && kp.get('w') === '4h',
    `Earlier ${new Date(e1[0]).toISOString()}-${new Date(e1[1]).toISOString()}; Later ${new Date(l1[0]).toISOString()}-${new Date(l1[1]).toISOString()}; Zoom out ${new Date(z1[0]).toISOString()}-${new Date(z1[1]).toISOString()}; key [ from ${k1.get('from')}; on 1h: Later off ${JSON.stringify(dis)}, Zoom out w=${zp[2]}, key ] w=${kp.get('w')}`);
}

// W. the typed range: 'now-6h' previews 'follows now' and Enter makes w=6h; 'now-1d/d to now/d' is yesterday (24 h, from
// the zone's midnight before) as a fixed range; 'soon' is refused in the preview and the address stays as it was
{
  await go('#/summary?w=1h');
  const panel = `document.querySelector('#bar [role="dialog"][aria-label="Time range"]')`;
  const open = async () => { if (!(await ev(`!!${panel}`))) await ev(`document.querySelector('#bar [aria-haspopup="dialog"]').click(); 'ok'`); await sleep(150); };
  const type = async (t, enter) => { await open(); return ev(`(async () => { const i = ${panel}.querySelector('input.range-typed'); i.value = ${JSON.stringify(t)}; i.dispatchEvent(new Event('input'));
    const pv = ${panel}.querySelector('#range-typed-preview').textContent; if (${!!enter}) i.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true, cancelable: true })); await new Promise(r => setTimeout(r, 700)); return pv; })()`); };
  const pv6 = await type('now-6h', true); const q6 = await params();
  const pvy = await type('now-1d/d to now/d', true); const qy = await params();
  const midnight = new Date(); midnight.setHours(0, 0, 0, 0);
  const before = await ev(`location.hash`);
  const pvb = await type('soon', true); const after = await ev(`location.hash`);
  await ev(`document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); 'ok'`);
  check('W typed range', pv6.endsWith(', follows now') && q6.get('w') === '6h' && /\(1d\)$/.test(pvy) && !qy.get('w') && Date.parse(qy.get('to')) === midnight.getTime() && Date.parse(qy.get('to')) - Date.parse(qy.get('from')) === 86400e3
    && pvb.startsWith('not a time') && before === after,
    `'now-6h': '${pv6}', w=${q6.get('w')}; 'now-1d/d to now/d': '${pvy}', ${qy.get('from')} to ${qy.get('to')}; 'soon': '${pvb}', address kept ${before === after}`);
}

// X. the footer's status line: on the Summary the instances as /api/instances counts them, the collections, the
// repository's size, the seat, the newest read and 'auto refresh every 30 s'; on a fixed window of Performance 'auto
// refresh not on this page'
{
  await go('#/summary?w=1h'); await sleep(500);
  const part = k => `document.querySelector('#status-line [data-part="${k}"]')?.textContent ?? ''`;
  const sum = await ev(`({ landmark: document.querySelector('#status-line')?.tagName, inst: ${part('instances')}, col: ${part('collections')}, repo: ${part('repository')}, seat: ${part('seat')}, newest: ${part('newest')}, refresh: ${part('refresh')} })`);
  await go(`#/performance?i=${idOf('demo-onprem-erp01')}&${dayQ}`); await sleep(500);
  const perf = await ev(part('refresh'));
  // the seat as the server's acknowledgement route says it (writable), the door's word as the actions log route
  // refuses or not; the frame routes refuse a missing instance and a window over 31 days (400)
  const ack = await (await fetch(`${base}api/ack?part=acks`)).json();
  const seatWant = `${ack.writable ? 'read-write' : 'read only'}, actions `;
  // what the footer's seat must read is the CALLER's to say (FRAME_EXPECT_DOOR), never the server's own word for it:
  // under it the acknowledgement route must name that door's user and the seat says once whose door it is (a demo
  // serve, task B7); without it the server must name no door and the seat reads its seat and the actions door (that
  // plain footer is also read by proof-demodoor's R10, on a serve -no-login)
  const expectDoor = process.env.FRAME_EXPECT_DOOR ?? '';
  const seatOk = expectDoor
    ? ack.door?.user === expectDoor && sum.seat === `demo: changes to the demo's own instances are saved as user ${expectDoor}; nothing reaches a server`
    : !ack.door && sum.seat.startsWith(seatWant) && /actions (on|off)$/.test(sum.seat);
  const noInst = (await fetch(`${base}api/frame/events`)).status;
  const tooLong = (await fetch(`${base}api/frame/events?instance=1&from=2026-01-01T00:00:00Z&to=2026-02-02T00:00:00Z`)).status;
  check('X footer', sum.landmark === 'FOOTER' && sum.inst.startsWith(`${inst.rows.length} instances (`) && /^collections: \d+ healthy, /.test(sum.col) && /^repository \d/.test(sum.repo)
    && seatOk && sum.newest.startsWith('newest read ') && sum.refresh === 'auto refresh every 30 s' && perf === 'auto refresh not on this page'
    && noInst === 400 && tooLong === 400,
    `${sum.inst} · ${sum.col} · ${sum.repo} · ${sum.seat} (expected: ${expectDoor ? `the door of user ${expectDoor}` : 'a server without a door'}; the ack route: writable ${ack.writable}${ack.door ? `, door user ${ack.door.user}` : ', no door'}) · ${sum.newest} · ${sum.refresh}; Performance: '${perf}'; /api/frame/events without an instance ${noInst}, over 32 days ${tooLong}`);
}

// Y. a second y axis and a server limit: erp01's Transactions chart draws three axes, the right one written
// 'rollbacks/s'; its Connections page's chart names the limit max_connections at the frame read's value, drawn as a line
// when it lies within four times the chart's peak and named 'above the chart' otherwise
{
  const erp = idOf('demo-onprem-erp01');
  await go(`#/performance?i=${erp}&${dayQ}`); await waitCharts();
  const tx = await ev(`(() => { const c = [...document.querySelectorAll('main .chart')].find(x => (x.querySelector('h3')?.textContent ?? '').startsWith('Transactions per second')); if (!c) return null;
    return { axes: c.querySelectorAll('.u-axis').length, note: c.querySelector('.chart-notes')?.textContent ?? '' }; })()`);
  // the CPU chart's two thresholds (the host check's 90 % and 98 %): drawn as lines inside the plot, at their values'
  // heights in order (98 above 90), and named under the chart
  const th = await ev(`(() => { const c = [...document.querySelectorAll('main .chart')].find(x => (x.querySelector('h3')?.textContent ?? '').startsWith('CPU (')); if (!c) return null;
    const o = c.querySelector('.u-over').getBoundingClientRect(), ls = [...c.querySelectorAll('.chart-line[data-kind="threshold"]')];
    return { n: ls.length, values: ls.map(l => l.dataset.value), tops: ls.map(l => l.getBoundingClientRect().top - o.top), h: o.height, note: c.querySelector('.chart-notes')?.textContent ?? '' }; })()`);
  // every PostgreSQL instance's Connections page in turn, until one draws its limit as a line: each must name its
  // max_connections at the frame read's value, drawn as a line at that value or said to be above the chart
  const pgIds = inst.rows.filter(r => String(r[c.indexOf('engine')] ?? 'postgres') !== 'sqlserver').map(r => r[c.indexOf('instance_id')]);
  const seen = [];
  for (const id of pgIds) {
    const fr = await (await fetch(`${base}api/frame/events?instance=${id}&${dayQ}`)).json();
    const mc = (fr.limits?.rows ?? []).find(r => r[0] === 'max_connections')?.[1];
    await go(`#/connections?i=${id}&${dayQ}`); await waitCharts(); await sleep(800);
    const lim = await ev(`(() => { const c = [...document.querySelectorAll('main .chart')].find(x => x.querySelector('.u-over')); if (!c) return null;
      const l = c.querySelector('.chart-line[data-kind="limit"]'), o = c.querySelector('.u-over').getBoundingClientRect();
      return { note: c.querySelector('.chart-notes')?.textContent ?? '', line: l?.dataset.value ?? null, inside: l ? l.getBoundingClientRect().top >= o.top - 1 && l.getBoundingClientRect().top <= o.bottom + 1 : null }; })()`);
    if (!lim) continue;
    const named = mc != null && lim.note.includes(`limit max_connections ${Number(mc).toLocaleString()}`);
    seen.push({ id, mc, named, drawn: lim.line === String(Number(mc)) && lim.inside === true, above: lim.line === null && lim.note.includes('above the chart') });
    if (seen[seen.length - 1].drawn) break;
  }
  const drawnOne = seen.find(x => x.drawn);
  const t90 = th ? th.tops[th.values.indexOf('90')] : NaN, t98 = th ? th.tops[th.values.indexOf('98')] : NaN;
  check('Y second axis, threshold, limit', !!tx && tx.axes === 3 && tx.note.includes('Left axis: commits/s (commits/s); right axis: rollbacks/s (rollbacks/s).')
    && !!th && th.n === 2 && t98 >= 0 && t98 < t90 && t90 <= th.h && th.note.includes('threshold warning 90 %, threshold critical 98 %')
    && seen.length > 0 && seen.every(x => x.named && (x.drawn || x.above)),
    `Transactions: ${tx?.axes} axes, '${tx?.note}'; CPU: ${th?.n} threshold lines ${th?.values?.join(',')} at ${th?.tops?.map(Math.round).join(',')} px of ${Math.round(th?.h)}, note '${th?.note}'; Connections: ${seen.map(x => `i=${x.id} max_connections ${x.mc} ${x.drawn ? 'drawn' : x.above ? 'above the chart' : 'NEITHER'}${x.named ? '' : ' (not named)'}`).join('; ')}${drawnOne ? '' : '; no instance drew its limit as a line'}`);
}

// Z. the full-window view: the button draws the chart over the window (fixed, the plot at least the window's width less
// 100 px), aria-pressed true; Escape puts it back at its width with the focus on the button
{
  await go(`#/performance?i=${idOf('demo-onprem-erp01')}&${dayQ}`); await waitCharts();
  const fw = await ev(`(async () => { const c = document.querySelector('main .chart'); const b = c.querySelector('button.chart-full'); if (!b) return null; const w0 = c.querySelector('canvas').getBoundingClientRect().width;
    b.click(); await new Promise(r => setTimeout(r, 300)); const on = { pos: getComputedStyle(c).position, w: c.querySelector('canvas').getBoundingClientRect().width, pressed: b.getAttribute('aria-pressed') };
    document.dispatchEvent(new Event('visibilitychange')); await new Promise(r => setTimeout(r, 3000));   // the page drawn again: the chart opens full again
    const c2 = document.querySelector('main .chart'), b2 = c2.querySelector('button.chart-full');
    const again = { fresh: c2 !== c, pos: getComputedStyle(c2).position, pressed: b2.getAttribute('aria-pressed') };
    b2.focus(); document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true, cancelable: true })); await new Promise(r => setTimeout(r, 300));
    return { w0, on, again, pos: getComputedStyle(c2).position, w1: c2.querySelector('canvas').getBoundingClientRect().width, pressed: b2.getAttribute('aria-pressed'), focus: document.activeElement === b2, inner: innerWidth }; })()`);
  check('Z full window', !!fw && fw.on.pos === 'fixed' && fw.on.w >= fw.inner - 100 && fw.on.pressed === 'true' && fw.again.fresh && fw.again.pos === 'fixed' && fw.again.pressed === 'true'
    && fw.pos !== 'fixed' && Math.abs(fw.w1 - fw.w0) <= 1 && fw.pressed === 'false' && fw.focus,
    fw ? `full: ${fw.on.pos}, ${Math.round(fw.on.w)} of ${fw.inner} px, pressed ${fw.on.pressed}; drawn again: a new chart ${fw.again.fresh}, ${fw.again.pos}, pressed ${fw.again.pressed}; Escape: ${fw.pos}, ${Math.round(fw.w1)} px (was ${Math.round(fw.w0)}), pressed ${fw.pressed}, focus on the button ${fw.focus}` : 'no full-window button');
}

// AA. the partial-window note: erp01's Performance page over a day that starts a day before the demo's first read says
// where its data starts; over a day inside the seeded days the note is absent
{
  const erp = idOf('demo-onprem-erp01');
  const t = Date.now() - 2 * 86400e3, early = `from=${new Date(t - 2 * 86400e3).toISOString()}&to=${new Date(t).toISOString()}`;
  await go(`#/performance?i=${erp}&${early}`); await waitCharts();
  const late = await ev(`[...document.querySelectorAll('main .chart .chart-notes')].map(n => n.textContent).filter(t => t.includes('The data starts at')).length`);
  await go(`#/performance?i=${erp}&${dayQ}`); await waitCharts();
  const inside = await ev(`[...document.querySelectorAll('main .chart .chart-notes')].map(n => n.textContent).filter(t => t.includes('The data starts at')).length`);
  const n = (await charts()).length;
  // a window of the half hour before the first read and 90 s after it: under three reads, said under the charts
  await go(`#/performance?i=${erp}&${early}`); await waitCharts();
  // the two-day page's first point is the start of a coarse step: twelve minutes from it, read by the minute, name the
  // first read itself
  // the API's own rows over the half hour after that point name the first read itself
  const coarse = Date.parse((await charts())[0]?.first ?? '');
  let first = NaN, few = -1;
  if (!Number.isNaN(coarse)) {
    const pr = await (await fetch(`${base}api/performance?instance=${erp}&from=${new Date(coarse - 60e3).toISOString()}&to=${new Date(coarse + 30 * 60e3).toISOString()}`)).json();
    // the reads' parts only: the grid part is every step of the window, read or not
    const ts = ['cpu', 'sessions', 'db'].map(k => pr[k]).filter(t => t && Array.isArray(t.columns) && t.columns.includes('snapshot_at') && t.rows.length)
      .flatMap(t => t.rows.map(r => Date.parse(r[t.columns.indexOf('snapshot_at')])));
    first = ts.length ? Math.min(...ts) : NaN;
  }
  if (!Number.isNaN(first)) {
  await go(`#/performance?i=${erp}&from=${new Date(first - 1800e3).toISOString()}&to=${new Date(first + 90e3).toISOString()}`); await sleep(1500);
  few = await ev(`[...document.querySelectorAll('main .chart')].map(c => c.querySelector('.chart-notes')?.textContent || c.querySelector('p.empty')?.textContent || '').filter(t => /Only (one|1|2) read|needs two/.test(t)).length`);
  }
  // the Storage page on 30 days: a chart of the page's window starts late (the demo holds three days), the chart of
  // its own days does not say so
  await go(`#/storage?i=${erp}&w=30d`); await waitCharts();
  const st = await ev(`[...document.querySelectorAll('main .chart')].filter(c => c.querySelector('.u-over')).map(c => ({ t: c.querySelector('h3')?.firstChild?.textContent ?? '', late: (c.querySelector('.chart-notes')?.textContent ?? '').includes('The data starts at') }))`);
  const own = st.filter(x => x.t.startsWith('Database sizes')), wal = st.find(x => x.t === 'WAL directory');
  check('AA partial window', late >= 1 && inside === 0 && few >= 1 && own.length >= 1 && own.every(x => !x.late) && !!wal && wal.late,
    `a window starting a day before the first read: ${late} chart(s) note where the data starts; a seeded day: ${inside} of ${n} charts; the half hour before the first read (${Number.isNaN(first) ? 'NOT FOUND' : new Date(first).toISOString()}) and 90 s after it: ${few} chart(s) say under three reads; Storage on 30 days: ${own.map(x => `'${x.t}' ${x.late ? 'NOTED' : 'no note'}`).join(', ') || 'no own-span chart'}, 'WAL directory' ${wal ? (wal.late ? 'noted late' : 'NOT noted') : 'absent'}`);
}

// AB. a SQL Server instance's deadlocks marked: sql01's frame read over the fixed day holds as many deadlock marks as its
// deadlock read (api/mssql/xe part=deadlocks) and its Performance page draws them on a chart, in the chart's list too
{
  const sql = idOf('demo-onprem-sql01');
  const fr = await (await fetch(`${base}api/frame/events?instance=${sql}&${dayQ}`)).json();
  const marks = (fr.events?.rows ?? []).filter(r => r[fr.events.columns.indexOf('kind')] === 'deadlock').length;
  const dl = await (await fetch(`${base}api/mssql/xe?instance=${sql}&part=deadlocks&${dayQ}`)).json();
  const nDl = dl.deadlocks?.rows?.length ?? 0;
  await go(`#/performance?i=${sql}&${dayQ}`); await waitCharts(); await sleep(800);
  const drawn = await ev(`Math.max(0, ...[...document.querySelectorAll('main .chart')].map(c => c.querySelectorAll('a.chart-mark[data-kind="deadlock"]').length))`);
  const href0 = await ev(`document.querySelector('main a.chart-mark[data-kind="deadlock"]')?.getAttribute('href') ?? ''`);
  check('AB SQL Server deadlock marks', nDl >= 1 && marks === nDl && drawn >= 1 && drawn <= marks && href0.startsWith('#/mssql_deadlocks?'),
    `sql01: ${nDl} deadlocks in the read, ${marks} deadlock marks in the frame read, ${drawn} drawn on the busiest chart, the first opens ${href0.split('&')[0]}`);
}

ws.close();
if (failed) { console.log(`FAIL ${failed} case(s)`); process.exit(1); }
console.log('frame: every case as expected');
