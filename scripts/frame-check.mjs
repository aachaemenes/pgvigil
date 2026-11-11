// The shared frame's browser checks (proof-frame.sh): a grid's column filter, its copy menu and the clipboard, a grid
// inside a grid's row, the Summary's Tests pane header, a chart legend's isolation, the crosshair readout, the auto
// refresh select, the filtered CSV export, a grid past its page and a pie's wedges.
//   node scripts/frame-check.mjs <cdp port> <base url/> <download folder>
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
check('C menu', menu.items === `Copy cell|Copy row|Copy all ${a.n} rows shown` && !menu.openAfter, `${menu.items}; open after Escape elsewhere: ${menu.openAfter}`);
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
await go(`#/counters?i=${idOf('demo-onprem-erp01')}`);
const still = await ev(`document.querySelector('#bar select[aria-label*="refresh"]')?.disabled ?? null`);
check('H refresh', !!live && live.n === 5 && live.v === '0' && !live.disabled && still === true, live ? `${live.n} choices on the Summary, Off stored '${live.v}'; disabled on Counters: ${still}` : 'no select on the Summary');

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

// J. a grid past its page (a job's All runs): 200 rows drawn and the 'show more' line; Copy all takes every row and
// leaves the grid as drawn; 'Show 200 more' draws 200 more and keeps the focus on the line; 'Show all' draws the rest
await go(`#/jobs?i=${idOf('demo-aurora-crm01')}&w=7d`);
const pg = await ev(`(async () => {
  const t = [...document.querySelectorAll('main table.grid')].find(x => Number(x.dataset.rows) > 200); if (!t) return null;
  const box = t.closest('.grid-box'), more = box.querySelector('.grid-more'), n = Number(t.dataset.rows);
  const drawn = () => t.querySelectorAll('tbody tr').length;
  const first = drawn(), line = more.hidden ? '' : more.textContent;
  const td = t.querySelector('tbody td'); const r = td.getBoundingClientRect();
  td.tabIndex = -1; td.focus();
  td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: r.left + 4, clientY: r.top + 4 }));
  const copyAll = [...document.querySelectorAll('.menu button')].find(b => b.textContent.startsWith('Copy all'));
  if (!copyAll) return { why: 'no Copy all in the menu: ' + [...document.querySelectorAll('.menu button')].map(b => b.textContent).join('|') };
  copyAll.click();
  await new Promise(r => setTimeout(r, 400));
  const lines = (await navigator.clipboard.readText()).split('\\n').length, afterCopy = drawn();
  more.querySelector('button').click(); await new Promise(r => setTimeout(r, 200));
  const second = drawn(), focusOnLine = more.contains(document.activeElement) && document.activeElement.tagName === 'BUTTON';
  const rest = more.hidden ? [] : [...more.querySelectorAll('button')];
  if (rest.length) { rest.pop().click(); await new Promise(r => setTimeout(r, 300)); }
  return { n, first, line, lines, afterCopy, second, focusOnLine, all: drawn(), hidden: more.hidden, focusGrid: document.activeElement === t.parentElement };
})()`);
check('J paging', !!pg && !pg.why && pg.first === 200 && pg.line.startsWith(`The first 200 of ${pg.n} rows`) && pg.lines === pg.n + 1 && pg.afterCopy === 200
  && pg.second === Math.min(400, pg.n) && (pg.n <= 400 || pg.focusOnLine) && pg.all === pg.n && pg.hidden && pg.focusGrid,
  pg?.why ?? (pg ? `${pg.n} rows: ${pg.first} drawn, '${pg.line.slice(0, 40)}...'; Copy all ${pg.lines - 1} rows, still ${pg.afterCopy} drawn; more ${pg.second} (focus on the line ${pg.focusOnLine}); all ${pg.all}, line hidden ${pg.hidden}, focus on the grid ${pg.focusGrid}` : 'no grid over 200 rows on the Jobs page'));

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

ws.close();
if (failed) { console.log(`FAIL ${failed} case(s)`); process.exit(1); }
console.log('frame: every case as expected');
