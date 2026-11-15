// The Summary's dead clicks: from the fleet Summary at the root and at a tag folder, every heading of the test grid and
// the instance grid, every cell of the test grid (at the tag folder one per column and zero / non-zero), one cell per
// column, engine and text shape of the instance grid, every reason of the Needs attention strip and every part of the
// counts line is clicked where a person clicks it (the middle of its text, after scrolling it into view), and the page
// is read before and after. A click is ALIVE when the address changes, a dialog or a menu opens, a sort mark changes,
// or the text in view changes (a sort, a filter, a panel drawn, a scroll to the result); DEAD otherwise, and a dead
// click FAILS, except where DBA Dash's own cell is text, not a link (Checks/Summary.Designer.cs: Memory Dump, Is Agent
// Running, DB Mail are DataGridViewTextBoxColumn) - their headings still sort and are clicked like every other.
// A dead click whose change landed only outside the view ('below the fold') is a FAIL too: nobody saw it.
// Usage:
//   node scripts/summary-clicks.mjs <cdp port> <base url/> <out dir>
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil demo ... -serve -listen 127.0.0.1:<port>
// Writes <out dir>/summary-clicks.json (every click, its effect, its verdict; saved after each scope) and
// <out dir>/summary-<scope>-dead.png (the Summary with every dead text outlined, the whole page). Prints one line per
// click and 'clicks: <n>; <m> FAIL; <g> GONE; <k> plain' last; exit 1 on a FAIL or a VOID scope. Every CDP call has
// 15 s: a hung page or a closed socket FAILS the click it was on, a new tab is opened and the walk goes on (three in a
// row end the scope); a browser dialog is dismissed and counted as the click's effect.
// The demo keeps writing samples while the walk runs, so a text read at the scope's start can be gone when its turn
// comes: it is looked for again in a fresh read by its PLACE (the part and column it stood in: a grid's column, a
// strip reason's name, a counts-line part, an element's place on an instance page) and what that place shows now is
// clicked. Only a place that is gone itself is 'GONE (the demo's state changed)' - counted apart from FAIL, each one
// printed; a scope with over 2 % of its clicks GONE is VOID and fails the walk. A FAIL stays a click that did nothing.
const [port, U, outDir] = process.argv.slice(2);
const fs = await import('node:fs');
fs.mkdirSync(outDir, { recursive: true });
const table = async p => { const t = await (await fetch(U + 'api/' + p)).json(); return t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]]))); };
const insts = await table('instances');
const engineByName = new Map(insts.map(r => [String(r.name), r.engine === 'sqlserver' ? 'sqlserver' : 'postgres']));
// the tag folder: the tag most instances carry of those not on every instance that holds both engines
const tagCount = new Map();
for (const r of insts) for (const t of (Array.isArray(r.tags) ? r.tags : [])) {
  const e = tagCount.get(t) ?? { n: 0, engines: new Set() }; e.n++; e.engines.add(r.engine === 'sqlserver' ? 'sqlserver' : 'postgres'); tagCount.set(t, e);
}
const tag = [...tagCount.entries()].filter(([, e]) => e.n < insts.length && e.engines.size === 2).sort((a, b) => b[1].n - a[1].n || (a[0] < b[0] ? -1 : 1))[0]?.[0];
// the instance Summary of one PostgreSQL and one SQL Server instance (the demo's erp01 and sql01 where present): its
// header (the band word, the status line, the reasons, the six chips: CPU ... Deadlocks ... Collectors) and its page
const pgI = insts.find(r => r.engine !== 'sqlserver' && String(r.name).endsWith('onprem-erp01')) ?? insts.find(r => r.engine !== 'sqlserver');
const msI = insts.find(r => r.engine === 'sqlserver' && String(r.name).endsWith('sql01')) ?? insts.find(r => r.engine === 'sqlserver');
const want = new Set((process.env.SUMCLICK_SCOPES || 'root,tag,instance').split(','));
// each scope opened at the address the app's own links give it (the window w=1h: router.ts href), so a link to the
// page it is on changes nothing in the walk either (the review of 823e113, finding 2)
const scopes = [...(want.has('root') ? [['root', '#/summary?w=1h']] : []), ...(tag && want.has('tag') ? [[`tag ${tag}`, '#/summary?tag=' + encodeURIComponent(tag) + '&w=1h']] : []),
  ...(want.has('instance') ? [pgI, msI].filter(Boolean).map(r => [`instance ${r.name}`, `#/summary?i=${r.instance_id}&w=1h`]) : [])];
// DBA Dash's text cells (not links): a dead click there is DBA Dash's too
const plainColumns = new Set(['Memory Dump', 'Crash restarts', 'Is Agent Running', 'DB Mail']);

// the browser: one tab over CDP; every call has a time limit (a hung page or a closed socket FAILS the click it was
// on, then a new tab is opened and the walk goes on from the next target); a browser dialog (alert, confirm) is
// dismissed and recorded as the click's effect
const CALL_MS = 15000;
let ws = null, targetId = '', id = 0;
const wait = new Map(), dialogs = [];
const cmd = (method, params = {}, ms = CALL_MS) => new Promise((res, rej) => {
  if (!ws || ws.readyState !== 1) return rej(new Error('the CDP socket is not open'));
  const i = ++id;
  const t = setTimeout(() => { wait.delete(i); rej(new Error(`the page hung (${method} over ${ms / 1000} s)`)); }, ms);
  wait.set(i, { res: d => { clearTimeout(t); res(d); }, rej: e => { clearTimeout(t); rej(e); } });
  ws.send(JSON.stringify({ id: i, method, params }));
});
const connect = async (url, tid) => {
  const sock = new WebSocket(url);
  await new Promise((res, rej) => { sock.addEventListener('open', res, { once: true }); sock.addEventListener('error', () => rej(new Error('the CDP socket did not open')), { once: true }); });
  sock.addEventListener('message', m => {
    const d = JSON.parse(m.data);
    if (d.method === 'Page.javascriptDialogOpening') {
      dialogs.push(String(d.params?.message ?? ''));
      sock.send(JSON.stringify({ id: ++id, method: 'Page.handleJavaScriptDialog', params: { accept: false } }));
      return;
    }
    if (wait.has(d.id)) { const w = wait.get(d.id); wait.delete(d.id); w.res(d); }
  });
  sock.addEventListener('close', () => { if (ws !== sock) return; for (const w of wait.values()) w.rej(new Error('the CDP socket closed')); wait.clear(); });
  ws = sock; targetId = tid;
  await cmd('Page.enable'); await cmd('Runtime.enable');
  await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
};
// a new tab (the old one closed when it still answers)
const freshTab = async () => {
  const old = targetId;
  try { ws?.close(); } catch { /* gone already */ }
  const t = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  await connect(t.webSocketDebuggerUrl, t.id);
  if (old) await fetch(`http://127.0.0.1:${port}/json/close/${old}`).catch(() => null);
};
{
  const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const pg = list.find(t => t.type === 'page');
  await connect(pg.webSocketDebuggerUrl, pg.id);
}
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
// the Summary is drawn: its instance grid (or its empty one) is on the page and nothing says Loading
const drawn = async (ms = 20000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m || !m.querySelector('h2')) return false;
      const e = m.querySelector('p.empty'); if (e && /^Loading/.test(e.textContent)) return false;
      return !/^#\\/summary/.test(location.hash) || !!m.querySelector('.summary-instances table'); })()`);
    if (ok) { await sleep(400); return true; }
    await sleep(150);
  }
  return false;
};
const go = async hash => { await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + hash }); await sleep(300); return drawn(); };
// a fresh Summary: an open dialog or menu closed (Escape), no count picked (the pick survives in sessionStorage), the
// page drawn again by the app's own redraw (a hashchange; the address set back when a click left it), the window at
// the top. The first draw of a scope loads the app (go).
const key = async k => { await cmd('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code: k, windowsVirtualKeyCode: 27 }); await cmd('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code: k, windowsVirtualKeyCode: 27 }); };
const reset = async (hash, load = false) => {
  // the app's own refresh is Off (paused) for the whole walk: a refresh landing between a click's two looks would
  // read as the click's change (the review of 823e113, finding 3)
  if (load) { await go(hash); await ev(`(() => { sessionStorage.removeItem('pgvigil.summaryPick'); localStorage.setItem('pgvigil.refresh', '0'); return true; })()`); await go(hash); await ev('window.scrollTo(0, 0)'); return; }
  await key('Escape'); await key('Escape');
  // the page on screen is marked first: the app keeps it until its new read (main.ts), so the walk waits until it is gone
  await ev(`(() => { sessionStorage.removeItem('pgvigil.summaryPick'); document.querySelectorAll('dialog[open]').forEach(d => d.close());
    for (const c of document.querySelector('main')?.children ?? []) c.setAttribute('data-walkold', '1');
    if (location.hash !== ${JSON.stringify(hash)}) location.hash = ${JSON.stringify(hash)}; else window.dispatchEvent(new HashChangeEvent('hashchange')); return true; })()`);
  for (const t = Date.now(); Date.now() - t < 20000; await sleep(150)) if (!(await ev(`!!document.querySelector('main [data-walkold]')`))) break;
  await sleep(250); await drawn(); await ev('window.scrollTo(0, 0)');
};

// the demo writes samples while the walk runs, so a number in a text can move between the read and the click: a
// text is found again by its SHAPE (each number any number), and an instance page's text by its words where its
// place moved (a reason added or gone above it)
const HELP = String.raw`
  const esc = s => s.replace(/[.*+?^{}$()|[\]\\]/g, '\\$&');
  const shape = s => esc(s).replace(/[0-9]+(?:[.,][0-9]+)*/g, '[0-9][0-9.,]*');
  const normT = s => s.replace(/\s+/g, ' ').trim();
  const sameShape = (a, b) => new RegExp('^' + shape(b) + '$').test(a);
`;
// the page's parts as in-page code: the two grids, the strip, the counts line
const PARTS = HELP + `
  const upperT = () => document.querySelector('main .grid-wrap.tests table.grid');
  const lowerT = () => document.querySelector('main .summary-instances table.grid');
  const heads = t => t ? [...t.querySelectorAll('thead tr:first-child > th')] : [];
  const bodyRows = t => t ? [...t.querySelectorAll('tbody > tr')] : [];
  const txt = e => (e?.textContent ?? '').replace(/\\s+/g, ' ').trim();
  const headText = th => txt(th.querySelector('.th-label') ?? th);
  const rowByFirst = (t, first) => bodyRows(t).find(tr => txt(tr.children[0]) === first);
  const rowByInst = (t, name) => bodyRows(t).find(tr => txt(tr.children[0]).startsWith(name));
  const stripRow = name => [...document.querySelectorAll('main .attention .attention-row')].find(r => txt(r.querySelector('strong')) === name);
  // the element a target names
  const find = d => {
    if (d.part === 'testhead') return heads(upperT())[d.col]?.querySelector('.th-label') ?? heads(upperT())[d.col];
    if (d.part === 'insthead') return heads(lowerT())[d.col]?.querySelector('.th-label') ?? heads(lowerT())[d.col];
    if (d.part === 'testcell') return rowByFirst(upperT(), d.row)?.children[d.col];
    if (d.part === 'instcell') return rowByInst(lowerT(), d.row)?.children[d.col];
    if (d.part === 'strip') return stripRow(d.row);
    if (d.part === 'counts') return document.querySelector('main p.counts');
    if (d.part === 'inst') {
      const m = document.querySelector('main'); let e = m; for (const i of d.path) { e = e?.children[i]; }
      const holds = x => !!x && [...x.childNodes].some(n => n.nodeType === 3 && sameShape(normT(n.textContent), d.text));
      if (holds(e)) return e;
      // found again by its shape: a bare number only inside the box it was in (any number on the page would match it:
      // the review of 823e113, finding 13), any other text anywhere on the page
      let box = m; if (/^[0-9][0-9.,]*$/.test(d.text)) for (const i of d.path.slice(0, -1)) box = box?.children[i];
      return [...(box?.querySelectorAll('*') ?? [])].find(holds) ?? null;
    }
    return null;
  };
  // the text range a person clicks: the target's own text, or (strip, counts) the words d.text inside it
  const rangeOf = (root, words) => {
    const w = document.createTreeWalker(root, NodeFilter.SHOW_TEXT); const nodes = []; let n;
    while ((n = w.nextNode())) if (n.textContent.trim()) nodes.push(n);
    if (!nodes.length) return null;
    const r = document.createRange();
    if (!words) { r.setStart(nodes[0], 0); const last = nodes[nodes.length - 1]; r.setEnd(last, last.textContent.length); return r; }
    // the first text node that holds the words' start; the range runs to the words' end or the node's end
    const head = words.slice(0, Math.min(words.length, 12));
    for (const x of nodes) { const i = x.textContent.indexOf(head); if (i >= 0) { r.setStart(x, i); r.setEnd(x, Math.min(x.textContent.length, i + words.length)); return r; } }
    const re = new RegExp(shape(head));
    for (const x of nodes) { const mm = re.exec(x.textContent); if (mm) { r.setStart(x, mm.index); r.setEnd(x, Math.min(x.textContent.length, mm.index + words.length)); return r; } }
    return null;
  };
`;
// every target of the page now (enumerated once per scope; each is found again after a reload)
const enumerate = full => ev(`(() => { ${PARTS}
  const out = [];
  // an instance's Summary: every short text node, visible, outside a form control, one target each (an element's
  // texts around its links are clicked apart: 'Not OK: ' is not the link after it); its place is a child-index path
  // from main (the page draws the same shape on a reload). Plain by kind: a heading, a properties table's label or
  // value, a label (its words end with ':'), a text marked data-nolink (DBA Dash's text cells, a page's own name)
  if (/[?&]i=/.test(location.hash)) {
    const m = document.querySelector('main');
    const pathOf = e => { const p = []; while (e && e !== m) { p.unshift([...e.parentElement.children].indexOf(e)); e = e.parentElement; } return p; };
    // a box clipped to a pixel (a screen reader's words: .visually-hidden, a chart legend's Time row): nobody sees its
    // text, nobody clicks it - a click at its place lands on whatever is drawn there
    const clips = [...m.querySelectorAll('*')].filter(a => { const r = a.getBoundingClientRect(); return r.width <= 1 && r.height <= 1 && (r.width > 0 || r.height > 0) && getComputedStyle(a).overflow !== 'visible'; });
    for (const e of m.querySelectorAll('*')) {
      if (e.closest('select, option, input, textarea, script, style, svg, [hidden]')) continue;
      const r = e.getBoundingClientRect(); if (r.width === 0 || r.height === 0) continue;
      // drawn off the page (a screen reader's words: position absolute, left -10000px): nobody clicks it
      if (r.right <= 0 || r.left >= document.documentElement.scrollWidth) continue;
      if (clips.some(c => c.contains(e))) continue;
      // a disabled control is plain only when it says why (its title, or the off-reason words beside it)
      const offBtn = e.closest('button:disabled, [aria-disabled="true"]');
      // a control first (the review of 823e113, finding 4): a link or a button inside a heading, a label or a value is
      // clicked like any other, never called plain by the place it sits in
      const base = offBtn && (offBtn.title || offBtn.parentElement?.querySelector('.off-reason')) ? 'off'
        : e.closest('a, button') ? 'control'
        : e.closest('h1, h2, h3, h4, h5, h6') ? 'heading'
        : e.closest('table.props th, dt, .healthcal-head, .healthcal-month, .healthcal > p.meta, .off-reason, .u-legend .u-series:first-child') ? 'label'
        : e.closest('table.props td, dd') ? 'value'
        : e.closest('[data-nolink]') ? 'nolink'
        : e.closest('tbody td') && e.closest('tr')?.querySelector('a[href], button:not(:disabled)') ? 'cell' : 'text';
      // its place, for a text that changed before its turn: the element's path and which of its texts it is; in a
      // grid's body the grid, the column and the row (the place is the grid's column: any row of it will do)
      const td = e.closest('tbody td'), tbl = td?.closest('table');
      const cellAt = td && tbl ? { grid: pathOf(tbl).join('.'), gcol: td.cellIndex, grow: td.parentElement.sectionRowIndex, sub: pathOf(e).slice(pathOf(td).length).join('.') } : {};
      let nth = 0;
      for (const n of e.childNodes) {
        if (n.nodeType !== 3) continue;
        const own = n.textContent.replace(/\\s+/g, ' ').trim();
        if (!own || /^[·,:;.()\\/|+-]+$/.test(own)) continue;
        const kind = base === 'text' && /:$/.test(own) ? 'label' : base;
        out.push({ part: 'inst', path: pathOf(e), nth: nth++, ...cellAt, label: (e.closest('[class]')?.className || e.tagName).toString().split(' ')[0], text: own, kind });
      }
    }
    return out;
  }
  heads(upperT()).forEach((th, i) => out.push({ part: 'testhead', col: i, label: headText(th), text: headText(th) }));
  const uh = heads(upperT()).map(headText);
  const seen = new Set();
  for (const tr of bodyRows(upperT())) [...tr.children].forEach((td, j) => {
    const t = txt(td); if (!t) return;
    const k = j === 0 ? 'name|' + t : j + '|' + (t === '0' ? 'zero' : 'n');
    if (!${full} && seen.has(k)) return; seen.add(k);
    out.push({ part: 'testcell', row: txt(tr.children[0]), col: j, label: uh[j], text: t });
  });
  heads(lowerT()).forEach((th, i) => out.push({ part: 'insthead', col: i, label: headText(th), text: headText(th) }));
  const lh = heads(lowerT()).map(headText);
  for (const tr of bodyRows(lowerT())) [...tr.children].forEach((td, j) => {
    const t = txt(td); if (!t) return;
    const inst = txt(tr.children[0].querySelector('a') ?? tr.children[0]);
    out.push({ part: 'instcell', row: inst, col: j, label: lh[j], text: t, shape: t.replace(/[0-9]+([.,][0-9]+)?/g, '9') });
  });
  for (const r of document.querySelectorAll('main .attention .attention-row')) {
    const name = txt(r.querySelector('strong'));
    // the reasons: the line's text after the name, split at its separators
    const rest = txt(r).slice(name.length).replace(/(Critical|Warning)\\s*Acknowledge.*$/, '').trim();
    for (const w of rest.split(' · ').map(s => s.replace(/\\s*\\+\\d+ more$/, '').trim()).filter(Boolean)) out.push({ part: 'strip', row: name, label: w.replace(/\\s.*$/, ''), text: w });
    // its '+n more' (the line's other reasons shown in place) is clicked as well (the review of 823e113, finding 10)
    const more = [...r.querySelectorAll('button')].find(b => /^\\+\\d+ more$/.test(txt(b)));
    if (more) out.push({ part: 'strip', row: name, label: '+n more', text: txt(more) });
  }
  const counts = document.querySelector('main p.counts');
  if (counts) for (const w of txt(counts).split(/[:,;]\\s*/).map(s => s.trim()).filter(s => /[0-9]/.test(s))) out.push({ part: 'counts', label: w.replace(/^[0-9]+ (of [0-9]+ )?/, ''), text: w });
  return out;
})()`);

// the instance grid's cells: one per column, engine and text shape (digits as 9) - every one at the root with
// CLICK_ALL=1
const thin = (targets, all) => {
  const seen = new Set();
  return targets.filter(t => {
    if (t.part !== 'instcell' || all) return true;
    const k = [t.col, engineByName.get(t.row) ?? '?', t.shape].join('|');
    if (seen.has(k)) return false; seen.add(k); return true;
  });
};
// scroll the target into view and give the point a person clicks (the middle of its text), or why there is none
const locate = d => ev(`(() => { ${PARTS}
  const d = ${JSON.stringify(d)}; const e = find(d);
  if (!e) return { why: 'not on the page after the reload' };
  e.scrollIntoView({ block: 'center', inline: 'nearest' });
  const r = rangeOf(e, d.part === 'strip' || d.part === 'counts' || d.part === 'inst' ? d.text : null);
  if (!r) return { why: 'no text of it found' };
  const b = [...r.getClientRects()].find(x => x.width > 0 && x.height > 0) ?? r.getBoundingClientRect();
  if (!b || b.width === 0) return { why: 'its text is not drawn' };
  const x = b.left + Math.min(b.width / 2, 40), y = b.top + b.height / 2;
  const hit = document.elementFromPoint(x, y);
  // the point a person clicks must be on the target itself: another element over it (a sticky bar, a menu) would take
  // the click, and its effect would be counted as the target's (the review of 823e113, finding 13)
  if (hit && !(e === hit || e.contains(hit) || hit.contains(e))) return { why: 'another element is over its text: ' + hit.tagName.toLowerCase() + (typeof hit.className === 'string' && hit.className ? '.' + hit.className.split(' ')[0] : '') };
  return { x, y, hit: hit ? hit.tagName.toLowerCase() + (hit.className && typeof hit.className === 'string' ? '.' + hit.className.split(' ')[0] : '') : '' };
})()`);
// what a person can see, and what the page holds: the text in view by place, the text anywhere, the sort marks, an
// open dialog or menu, the address (the Refresh Time's clock left out: it moves by itself)
const snap = () => ev(`(() => {
  const vh = innerHeight, vw = innerWidth, inView = [], all = [];
  const w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT); let n;
  while ((n = w.nextNode())) {
    const t = n.textContent.trim(); const p = n.parentElement;
    if (!t || !p || p.closest('[hidden], .refresh-time, script, style')) continue;
    const r = p.getBoundingClientRect(); if (r.width === 0 && r.height === 0) continue;
    all.push(t);
    if (r.bottom > 0 && r.top < vh && r.right > 0 && r.left < vw) inView.push(Math.round(r.top) + ':' + Math.round(r.left) + ':' + t);
  }
  const vis = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const modal = [...document.querySelectorAll('dialog[open], [role=dialog], [role=menu], .menu')].filter(vis).length;
  const sort = [...document.querySelectorAll('th[aria-sort]')].map(t => t.getAttribute('aria-sort')).join(',');
  // a chart legend's series switched off (uPlot's u-off), a pressed or selected control: a change drawn on a canvas
  const marks = [...document.querySelectorAll('.u-off, [aria-pressed="true"], [aria-selected="true"]')].length;
  const tab = document.querySelector('#tabs [aria-current="page"]')?.getAttribute('href') ?? '';
  return { hash: location.hash, tab, modal, sort, marks, view: inView.join('\\n'), all: all.join('\\n') };
})()`);
const mouse = async (type, x, y) => cmd('Input.dispatchMouseEvent', { type, x, y, button: type === 'mouseMoved' ? 'none' : 'left', clickCount: type === 'mouseMoved' ? 0 : 1 });

const results = [];
let fails = 0, plain = 0, gone = 0;
const voids = [];
const line = r => `${r.verdict.startsWith('FAIL') ? 'FAIL' : r.verdict.startsWith('GONE') ? 'GONE' : r.verdict.startsWith('plain') ? 'plain' : 'ok  '} | ${r.scope} | ${r.part} | ${r.label} | ${String(r.text).slice(0, 40)}${r.row ? ' @ ' + r.row : ''} | ${r.effect}${r.was ? ` (its place read '${String(r.was).slice(0, 40)}' at the scope's start)` : ''}`;
// a text's place (the walk's header): what a fresh read is searched by when the text itself is gone
const stripName = s => String(s).replace(/\s+[0-9(].*$/, '').replace(/\s+(critical|warning)$/i, '');
const placeOf = t => t.part === 'inst' ? (t.grid != null ? `grid ${t.grid} column ${t.gcol} ${t.sub}#${t.nth}` : `element ${t.path.join('.')}#${t.nth}`)
  : t.part === 'strip' ? `strip reason '${t.label === '+n more' ? t.label : stripName(t.text)}'`
  : t.part === 'counts' ? `counts '${t.label}'` : `${t.part} '${t.row ?? ''}' column ${t.col}`;
// the target at t's place in a fresh read: the same row where the place keeps one (a grid's nearest row at or above
// it, the strip's own instance line first), or none - the place is gone
const samePlace = (fresh, t) => {
  const at = fresh.filter(x => x.part === t.part && placeOf(x) === placeOf(t));
  if (t.part === 'inst' && t.grid != null) return at.filter(x => x.grow <= t.grow).sort((a, b) => b.grow - a.grow)[0] ?? at.sort((a, b) => a.grow - b.grow)[0];
  if (t.part === 'strip') return at.find(x => x.row === t.row) ?? at[0];
  return at[0];
};
const VANISHED = new Set(['not on the page after the reload', 'no text of it found']);
const fail = r => { results.push(r); fails++; console.log(line(r)); };
const save = () => fs.writeFileSync(`${outDir}/summary-clicks.json`, JSON.stringify({ scopes, results, dialogs, voids }, null, 1));
const plainKinds = { heading: 'a heading: it names what is beside it', label: 'a label: it names what is beside it',
  value: "a properties table's value", nolink: "marked as text (DBA Dash's text cell, or this page's own name)",
  off: 'a control that is off and says why', cell: "a grid cell whose row has its link (DBA Dash's grids: text beside the row's link)" };
// one click: the verdict of one target (throws when the page hangs or the socket closes)
const clickOne = async (scope, t) => {
  const p = await locate(t);
  const r = { scope, ...t, engine: t.part === 'instcell' ? engineByName.get(t.row) ?? '' : '' };
  if (p.why) { r.effect = p.why; r.verdict = 'FAIL ' + p.why; return { r, dirty: false, vanished: VANISHED.has(p.why) }; }
  await mouse('mouseMoved', p.x, p.y); await sleep(150);
  const before = await snap(), d0 = dialogs.length;
  await mouse('mousePressed', p.x, p.y); await mouse('mouseReleased', p.x, p.y);
  await sleep(700);
  let after = await snap();
  if (after.hash !== before.hash) { await drawn(); after = await snap(); }
  const effects = [];
  // where it lands: the address, and a page the tab strip does not hold said so (finding 14 of the review of 823e113)
  if (after.hash !== before.hash) effects.push('lands on ' + after.hash + (after.tab ? '' : ' (a page outside the tab strip)'));
  if (dialogs.length > d0) effects.push('opens a browser dialog: ' + dialogs.slice(d0).join(' / ').slice(0, 80));
  if (after.modal > before.modal) effects.push('opens a dialog or a menu');
  if (after.sort !== before.sort) effects.push('sort mark ' + (after.sort || 'none'));
  if (after.marks !== before.marks) effects.push('switches a series or a control (' + before.marks + ' -> ' + after.marks + ' marked)');
  if (after.hash === before.hash && after.view !== before.view) effects.push('changes the view');
  const offView = after.hash === before.hash && after.view === before.view && after.all !== before.all;
  r.hit = p.hit;
  r.effect = effects.length ? effects.join('; ') : offView ? 'nothing in view (a change below the fold only)' : 'nothing';
  let dirty = offView;
  if (effects.length) { r.verdict = 'ok'; dirty = true; }
  else if (t.part === 'instcell' && plainColumns.has(t.label)) r.verdict = 'plain (DBA Dash: a text cell, not a link)';
  else if (t.part === 'inst' && plainKinds[t.kind]) r.verdict = `plain (${plainKinds[t.kind]})`;
  else r.verdict = 'FAIL dead click: ' + r.effect;
  await mouse('mouseMoved', 2, 2);
  return { r, dirty };
};
// one target under a demo that keeps writing: a text gone at its turn is looked for by its place in a fresh read (three
// reads at most) and what the place shows now is clicked; a place that is gone is GONE, never a FAIL
const clickLive = async (scope, t) => {
  let o = await clickOne(scope, t);
  for (let k = 0; o.vanished && k < 2; k++) {
    const now = samePlace(await enumerate(true), t);
    if (!now) { o.r.effect = `${o.r.effect}; its place is gone too (${placeOf(t)})`; o.r.verdict = "GONE (the demo's state changed)"; return { ...o, vanished: false }; }
    o = await clickOne(scope, now);
    if (String(now.text) !== String(t.text)) o.r.was = t.text;
  }
  if (o.vanished) { o.r.effect = `${o.r.effect}; its place (${placeOf(t)}) changed at each of three reads`; o.r.verdict = "GONE (the demo's state changed)"; }
  return o;
};
// after a hang: a new tab, the scope loaded again
const recover = async hash => { await freshTab(); await reset(hash, true); };
for (const [scope, hash] of scopes) {
  let targets;
  try {
    await reset(hash, true);
    targets = thin(await enumerate(process.env.CLICK_ALL === '1'), process.env.CLICK_ALL === '1');
  } catch (e) {
    fail({ scope, part: 'page', label: 'Summary', text: hash, effect: 'the page did not load: ' + e.message, verdict: 'FAIL' });
    await freshTab().catch(() => null); save(); continue;
  }
  if (!scope.startsWith('instance') && (!targets.some(t => t.part === 'insthead') || !targets.some(t => t.part === 'testhead'))) {
    fail({ scope, part: 'page', label: 'Summary', text: hash, effect: 'the Summary drew no test grid or no instance grid', verdict: 'FAIL' }); save(); continue;
  }
  let dirty = false, hangs = 0;
  for (const t of targets) {
    try {
      if (dirty) { await reset(hash); dirty = false; }
      const o = await clickLive(scope, t);
      results.push(o.r); console.log(line(o.r));
      if (o.r.verdict.startsWith('FAIL')) fails++; else if (o.r.verdict.startsWith('GONE')) gone++; else if (o.r.verdict.startsWith('plain')) plain++;
      dirty = o.dirty; hangs = 0;
    } catch (e) {
      fail({ scope, ...t, effect: e.message, verdict: 'FAIL ' + e.message });
      if (++hangs >= 3) { fail({ scope, part: 'page', label: 'Summary', text: hash, effect: 'three hangs in a row: the rest of this scope is not clicked', verdict: 'FAIL' }); break; }
      try { await recover(hash); dirty = false; } catch (e2) { fail({ scope, part: 'page', label: 'Summary', text: hash, effect: 'no new tab after a hang: ' + e2.message, verdict: 'FAIL' }); break; }
    }
  }
  // the picture: the Summary with every dead text of this scope outlined in red, the whole page
  try {
    await reset(hash);
    const dead = results.filter(r => r.scope === scope && r.verdict.startsWith('FAIL') && r.part !== 'page');
    await ev(`(() => { ${PARTS}
      for (const d of ${JSON.stringify(dead)}) { const e = find(d); const box = d.part === 'inst' ? e : e?.closest('td, th, .attention-row, p') ?? e; if (box) box.style.outline = '3px solid #d00'; }
      window.scrollTo(0, 0); return true; })()`);
    const h = await ev('Math.ceil(document.documentElement.scrollHeight)');
    await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: Math.min(Math.max(h, 1000), 8000), deviceScaleFactor: 1, mobile: false });
    await sleep(500);
    const shot = await cmd('Page.captureScreenshot', { format: 'png' }, 60000);
    fs.writeFileSync(`${outDir}/summary-${scope.replace(/[^a-z0-9]+/gi, '-')}-dead.png`, Buffer.from(shot.result.data, 'base64'));
    await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
  } catch (e) {
    console.log(`note | ${scope} | no picture: ${e.message}`);
    await freshTab().catch(() => null);
  }
  // a scope that lost over 2 % of its clicks to the demo's changes proves nothing: VOID, and the walk fails on it
  const mine = results.filter(r => r.scope === scope), lost = mine.filter(r => r.verdict.startsWith('GONE')).length;
  if (lost > mine.length * 0.02) { voids.push(scope); console.log(`VOID | ${scope} | ${lost} of ${mine.length} clicks GONE: over 2 %, the scope proves nothing`); }
  save();
}
save();
// the dead list by part and column (what the fix works from)
const byCol = new Map();
for (const r of results.filter(x => x.verdict.startsWith('FAIL'))) {
  const k = `${r.part} | ${r.label}${r.engine ? ' (' + r.engine + ')' : ''}`;
  byCol.set(k, (byCol.get(k) ?? 0) + 1);
}
console.log('== dead, by part and column:');
for (const [k, n] of [...byCol.entries()].sort()) console.log(`DEAD ${k}: ${n}`);
console.log(`clicks: ${results.length}; ${fails} FAIL; ${gone} GONE; ${plain} plain${voids.length ? `; VOID: ${voids.join(', ')}` : ''}`);
try { ws?.close(); } catch { /* gone */ }
process.exit(fails || voids.length ? 1 : 0);
