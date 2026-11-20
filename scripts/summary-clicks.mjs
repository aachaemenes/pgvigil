// The Summary's dead clicks: from the fleet Summary at the root and at a tag folder, every heading of the test grid and
// the instance grid, every cell of the test grid (at the tag folder one per column and zero / non-zero), one cell per
// column, engine and text shape of the instance grid, every reason of the Needs attention strip and every part of the
// counts line is clicked where a person clicks it (the middle of its text, after scrolling it into view), and the page
// is read before and after. A click is ALIVE when the address changes, a dialog or a menu opens, a sort mark changes,
// or the text in view changes (a sort, a filter, a panel drawn, a scroll to the result); DEAD otherwise, and a dead
// click FAILS.
// A dead click whose change landed only outside the view ('below the fold') is a FAIL too: nobody saw it. Every status
// text answers a click, DBA Dash's text cells (Memory Dump, Is Agent Running, DB Mail) too: a text left plain FAILS as
// 'dead twin' where a link of the same check (data-group) is on its page, and as 'dead status text' where it is in the
// warning or critical band's colour, unless it is a heading. A link that opens an outside page in a new tab (target
// _blank, an http(s) href: a vendor's document) is read, not clicked: 'opens <host> in a new tab', ok - its href read,
// the page never fetched (a click would open a tab the walk does not read and fetch a page off the machine).
// Usage:
//   node scripts/summary-clicks.mjs <cdp port> <base url/> <out dir>
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil demo ... -serve -listen 127.0.0.1:<port>
// Writes <out dir>/summary-clicks.json (every click, its effect, its verdict; saved after each scope) and
// <out dir>/summary-<scope>-dead.png (the Summary with every dead text outlined, the whole page). Prints one line per
// click and 'clicks: <n>; <m> FAIL; <g> GONE; <k> plain' last; exit 1 on a FAIL or a VOID scope. Every CDP call has
// 15 s: a hung page or a closed socket FAILS the click it was on, a new tab is opened and the walk goes on (three in a
// row end the scope); a browser dialog is dismissed and counted as the click's effect.
// The demo keeps writing samples while the walk runs, so a text read at the scope's start can be gone when its turn
// comes: it is looked for again in a fresh read by its PLACE (the part and column it stood in: a grid's column, a strip
// reason's name on its own instance line - the strip's 'Show all <n>' and the line's '+<n> more' pressed first -, a
// counts-line part, an element's place on an instance page) and what that place shows now is clicked. Only a place
// that is gone itself is 'GONE (the demo's state changed)' - counted apart from FAIL, each one printed; a scope with
// over 2 % of its clicks GONE is VOID and fails the walk. A FAIL stays a click that did nothing.
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
// page it is on changes nothing in the walk either
const scopes = [...(want.has('root') ? [['root', '#/summary?w=1h']] : []), ...(tag && want.has('tag') ? [[`tag ${tag}`, '#/summary?tag=' + encodeURIComponent(tag) + '&w=1h']] : []),
  ...(want.has('instance') ? [pgI, msI].filter(Boolean).map(r => [`instance ${r.name}`, `#/summary?i=${r.instance_id}&w=1h`]) : [])];

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
// the Summary is drawn and nothing says Loading: the fleet's when its instance grid (or its empty one) is on the page,
// an instance's when its header and its health calendar are (both follow the page when their own reads end; the
// fleet's grid is not on an instance's page, and asking for it there held every redraw its whole 20 s)
const drawn = async (ms = 20000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m || !m.querySelector('h2')) return false;
      const e = m.querySelector('p.empty'); if (e && /^Loading/.test(e.textContent)) return false;
      if (!/^#\\/summary/.test(location.hash)) return true;
      return /[?&]i=/.test(location.hash) ? !!m.querySelector('.inst-header') && !!m.querySelector('.healthcal-grid') : !!m.querySelector('.summary-instances table'); })()`);
    if (ok) { await sleep(400); return true; }
    await sleep(150);
  }
  return false;
};
// the page has stopped drawing: its text is the same on two looks 300 ms apart (the app's refresh is Off for the walk,
// so a drawn page stays as it is), 6 s at most - a part landing between a click's two looks would read as its change
const still = async () => {
  for (let i = 0, last = -1; i < 20; i++) {
    const n = await ev(`(document.querySelector('main')?.innerText ?? '').length`);
    if (n === last) return true;
    last = n; await sleep(300);
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
  // read as the click's change
  if (load) {
    await go(hash); await ev(`(() => { sessionStorage.removeItem('pgvigil.summaryPick'); localStorage.setItem('pgvigil.refresh', '0'); return true; })()`);
    // the scope's targets are read from this page: every late part on it first (3 s more, then still)
    await go(hash); await sleep(3000); await still(); await ev('window.scrollTo(0, 0)'); return;
  }
  await key('Escape'); await key('Escape');
  // the page on screen is marked first: the app keeps it until its new read (main.ts), so the walk waits until it is gone
  await ev(`(() => { sessionStorage.removeItem('pgvigil.summaryPick'); document.querySelectorAll('dialog[open]').forEach(d => d.close());
    for (const c of document.querySelector('main')?.children ?? []) c.setAttribute('data-walkold', '1');
    if (location.hash !== ${JSON.stringify(hash)}) location.hash = ${JSON.stringify(hash)}; else window.dispatchEvent(new HashChangeEvent('hashchange')); return true; })()`);
  for (const t = Date.now(); Date.now() - t < 20000; await sleep(150)) if (!(await ev(`!!document.querySelector('main [data-walkold]')`))) break;
  await sleep(250); await drawn(); await still(); await ev('window.scrollTo(0, 0)');
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
      // found again by its shape: a number - bare, or with a short unit ('0s', '14 %', '3 GB') - only inside the box it
      // was in (any such number on the page would match it: a tile's '0s' found again in another table's cell), any
      // other text anywhere on the page
      let box = m; if (/^[0-9][0-9.,]*\\s*(%|[a-z]{1,2})?$/i.test(d.text)) for (const i of d.path.slice(0, -1)) box = box?.children[i];
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
      // a control first: a link or a button inside a heading, a label or a value is
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
    // its '+n more' (the line's other reasons shown in place) is clicked as well
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
  // a link that opens an outside page in a new tab: its host, read from its href (the page is never fetched); the
  // target itself is the link or inside it - a cell whose click point lands on a link beside its own text is not read
  const ext = e.closest('a[target="_blank"][href]');
  // (inside this template a backslash is written twice, as the other patterns here: a lone one before '/' is dropped,
  // and the page would read '/^https?:/' with the rest of the line a comment)
  const out = ext && /^https?:\\/\\//i.test(ext.getAttribute('href') ?? '') ? new URL(ext.href).host : '';
  // the point a person clicks must be on the target itself: another element over it (a sticky bar, a menu) would take
  // the click, and its effect would be counted as the target's
  if (hit && !(e === hit || e.contains(hit) || hit.contains(e))) return { why: 'another element is over its text: ' + hit.tagName.toLowerCase() + (typeof hit.className === 'string' && hit.className ? '.' + hit.className.split(' ')[0] : '') };
  // the twin rule: a text of a check (data-group, on a fleet page with its instance's data-inst) beside which a link
  // of the same check is on the page - the text is dead where its twin answers
  // the check of the point clicked (a label holding a check's name is not that check); a fleet grid cell is the td
  // itself, whose link or text inside carries it
  const grp = (hit ?? e).closest('[data-group]') ?? (d.part === 'instcell' ? e.querySelector('[data-group]') : null), gk = grp ? grp.getAttribute('data-group') : '', gi = grp?.closest('[data-inst]')?.getAttribute('data-inst') ?? '';
  const live = x => x.matches('a[href], button:not(:disabled)') || !!x.querySelector('a[href], button:not(:disabled)');
  const twin = !!gk && [...document.querySelectorAll('main [data-group]')].some(o => o !== grp && !o.contains(e) && !e.contains(o)
    && o.getAttribute('data-group') === gk && (o.closest('[data-inst]')?.getAttribute('data-inst') ?? '') === gi && live(o)) ? gk : '';
  // the status rule: a text in the warning or the critical band's colour (its own colour, or a status cell's or a
  // badge's tint), never a heading
  const tint = c => { const q = document.createElement('span'); q.style.color = c; document.body.append(q); const v = getComputedStyle(q).color; q.remove(); return v; };
  const band = new Set([tint('var(--warn)'), tint('var(--crit)')]);
  const status = !e.closest('h1, h2, h3, h4, h5, h6') && (band.has(getComputedStyle(e).color) || !!e.closest('td.status.warn, td.status.crit, .badge.warn, .badge.crit'));
  return { x, y, twin, status, out, hit: hit ? hit.tagName.toLowerCase() + (hit.className && typeof hit.className === 'string' ? '.' + hit.className.split(' ')[0] : '') : '' };
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
  : t.part === 'strip' ? `strip '${t.row}' reason '${t.label === '+n more' ? t.label : stripName(t.text)}'`
  : t.part === 'counts' ? `counts '${t.label}'` : `${t.part} '${t.row ?? ''}' column ${t.col}`;
// the target at t's place in a fresh read (a grid's column: its nearest row at or above t's, else its first row), or
// none - the place is gone. A strip reason's place is its own instance line: another line's reason of the same name
// is another instance's, never clicked in its stead
const samePlace = (fresh, t) => {
  const at = fresh.filter(x => x.part === t.part && placeOf(x) === placeOf(t));
  if (t.part === 'inst' && t.grid != null) return at.filter(x => x.grow <= t.grow).sort((a, b) => b.grow - a.grow)[0] ?? at.sort((a, b) => a.grow - b.grow)[0];
  return at[0];
};
// the strip draws eight lines and four reasons a line: a line that moved past the eighth ('Show all <n>') or a reason
// past the fourth ('+<n> more') is still on the page, and is shown before its place is called gone
const showStrip = row => ev(`(() => { ${PARTS}
  const all = [...document.querySelectorAll('main .attention button')].find(b => /^Show all \\d+$/.test(txt(b)));
  if (all) all.click();
  const more = [...(stripRow(${JSON.stringify(row)})?.querySelectorAll('button') ?? [])].find(b => /^\\+\\d+ more$/.test(txt(b)));
  if (more) more.click();
  return !!all || !!more; })()`);
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
  // an outside page in a new tab: read, not clicked (the header)
  if (p.out) { r.hit = p.hit; r.effect = `opens ${p.out} in a new tab (its href read, the page not fetched)`; r.verdict = 'ok'; return { r, dirty: false }; }
  await mouse('mouseMoved', p.x, p.y); await sleep(150);
  const before = await snap(), d0 = dialogs.length;
  await mouse('mousePressed', p.x, p.y); await mouse('mouseReleased', p.x, p.y);
  await sleep(700);
  let after = await snap();
  if (after.hash !== before.hash) { await drawn(); after = await snap(); }
  const effects = [];
  // where it lands: the address, and a page the tab strip does not hold said so
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
  else if (p.twin) r.verdict = `FAIL dead twin: a link of the same check (${p.twin}) is on the page`;
  else if (p.status) r.verdict = 'FAIL dead status text: a warning or critical text that answers no click';
  else if (t.part === 'inst' && plainKinds[t.kind]) r.verdict = `plain (${plainKinds[t.kind]})`;
  else r.verdict = 'FAIL dead click: ' + r.effect;
  await mouse('mouseMoved', 2, 2);
  return { r, dirty };
};
// one target under a demo that keeps writing: a text gone at its turn is looked for by its place in a fresh read (three
// reads, 1.5 s apart) and what the place shows now is clicked; a place in none of them is GONE, never a FAIL
const clickLive = async (scope, t) => {
  let o = await clickOne(scope, t), opened = false;
  for (let k = 0; o.vanished && k < 3; k++) {
    if (k) await sleep(1500);   // a part the page was still drawing is there on the next look
    let now = samePlace(await enumerate(true), t);
    if (!now && t.part === 'strip' && await showStrip(t.row)) { opened = true; await sleep(300); now = samePlace(await enumerate(true), t); }
    if (!now) continue;
    o = await clickOne(scope, now);
    if (String(now.text) !== String(t.text)) o.r.was = t.text;
  }
  if (o.vanished) { o.r.effect = `${o.r.effect}; its place (${placeOf(t)}) was in none of three fresh reads`; o.r.verdict = "GONE (the demo's state changed)"; }
  // the strip opened by the search is closed again by the next target's fresh page
  return { ...o, dirty: o.dirty || opened };
};
// after a hang: a new tab, the scope loaded again
const recover = async hash => { await freshTab(); await reset(hash, true); };
// the planted self-test of the twin and status rules (once, on the first scope's page): three texts planted at the top
// of the page, each marked as text (data-nolink) and clicked as any target: a twin of a planted link of its own group
// (wanted 'FAIL dead twin'), a badge in the critical band and a text in the warning colour ('FAIL dead status text'),
// plain words, a text whose check's link is on another instance's line, a label holding a check's link ('plain'), and a
// link to an outside page in a new tab ('ok', read, not clicked) beside an in-app address in a new tab ('plain': only an
// http(s) href is read). A walk without the rules calls them all plain, and the self-test fails the walk
let selfTested = false;
const selfTest = async (scope) => {
  selfTested = true;
  await ev(`(() => { const m = document.querySelector('main'); const p = document.createElement('p'); p.setAttribute('data-walkplant', '1');
    p.innerHTML = '<span data-group="walkplant" data-nolink="this page">planted twin</span> <a data-group="walkplant" href="#/findings">planted link</a> <span class="badge crit" data-nolink="this page">planted critical</span> <span data-nolink="this page">planted words</span>'
      + ' <span data-nolink="this page" style="color: var(--warn)">planted warning colour</span>'
      + ' <span data-inst="1"><span data-group="walkplant3" data-nolink="this page">planted other instance</span></span> <span data-inst="2"><a data-group="walkplant3" href="#/findings">planted link 3</a></span>'
      + ' <span data-nolink="this page">planted label: <a data-group="walkplant2" href="#/findings">planted link 2</a></span> <a data-group="walkplant2" href="#/findings">planted link 2b</a>'
      + ' <a href="https://example.invalid/walkplant" target="_blank" rel="noopener">planted outside page</a>'
      + ' <a href="#/findings" target="_blank" rel="noopener">planted in-app tab</a>';
    m.prepend(p); window.scrollTo(0, 0); return true; })()`);
  // wanted: the twin and the two status texts (a badge's tint, a text in the warning colour) dead; plain words, a text
  // whose same check's link is on another instance's line, and a label holding a check's link plain; the outside page
  // read as ok, the in-app address in a new tab clicked as any target (plain)
  const want = [['planted twin', [0, 0], 'FAIL dead twin'], ['planted critical', [0, 2], 'FAIL dead status text'], ['planted words', [0, 3], 'plain'],
    ['planted warning colour', [0, 4], 'FAIL dead status text'], ['planted other instance', [0, 5, 0], 'plain'], ['planted label:', [0, 7], 'plain'],
    ['planted outside page', [0, 9], 'ok'], ['planted in-app tab', [0, 10], 'plain']];
  const got = []; let right = 0;
  for (const [text, path, w] of want) {
    const o = await clickOne(scope, { part: 'inst', path, nth: 0, label: 'self-test', text, kind: 'nolink' });
    got.push(`${text} -> ${o.r.verdict.slice(0, 48)}`);
    if (o.r.verdict.startsWith(w)) right++;
  }
  const said = `twin self-test | ${scope} | ${got.join(' | ')} | ${right} of ${want.length} as wanted`;
  if (right === want.length) console.log(said);
  else { fails++; console.log(`FAIL | ${said}`); results.push({ scope, part: 'self-test', label: 'twin self-test', text: got.join('; '), effect: `${right} of ${want.length}`, verdict: 'FAIL the twin self-test' }); }
};
for (const [scope, hash] of scopes) {
  let targets;
  try {
    await reset(hash, true);
    if (!selfTested) {
      await selfTest(scope);
      if (process.env.SUMCLICK_SELFTEST_ONLY === '1') break;
      await reset(hash);
    }
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
