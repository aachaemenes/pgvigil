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
// Writes <out dir>/summary-clicks.json (every click, its effect, its verdict) and <out dir>/summary-<scope>-dead.png
// (the Summary with every dead text outlined, the whole page). Prints one line per click and
// 'clicks: <n>; <m> FAIL; <k> plain' last; exit 1 on a FAIL.
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
const scopes = [...(want.has('root') ? [['root', '#/summary']] : []), ...(tag && want.has('tag') ? [[`tag ${tag}`, '#/summary?tag=' + encodeURIComponent(tag)]] : []),
  ...(want.has('instance') ? [pgI, msI].filter(Boolean).map(r => [`instance ${r.name}`, `#/summary?i=${r.instance_id}`]) : [])];
// DBA Dash's text cells (not links): a dead click there is DBA Dash's too
const plainColumns = new Set(['Memory Dump', 'Crash restarts', 'Is Agent Running', 'DB Mail']);

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
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
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
const go = async hash => { await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + hash }); await sleep(300); return drawn(); };
// a fresh Summary: an open dialog or menu closed (Escape), no count picked (the pick survives in sessionStorage), the
// page drawn again by the app's own redraw (a hashchange; the address set back when a click left it), the window at
// the top. The first draw of a scope loads the app (go).
const key = async k => { await cmd('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code: k, windowsVirtualKeyCode: 27 }); await cmd('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code: k, windowsVirtualKeyCode: 27 }); };
const reset = async (hash, load = false) => {
  if (load) { await go(hash); await ev(`sessionStorage.removeItem('pgvigil.summaryPick')`); await go(hash); await ev('window.scrollTo(0, 0)'); return; }
  await key('Escape'); await key('Escape');
  await ev(`(() => { sessionStorage.removeItem('pgvigil.summaryPick'); document.querySelectorAll('dialog[open]').forEach(d => d.close());
    if (location.hash !== ${JSON.stringify(hash)}) location.hash = ${JSON.stringify(hash)}; else window.dispatchEvent(new HashChangeEvent('hashchange')); return true; })()`);
  await sleep(250); await drawn(); await ev('window.scrollTo(0, 0)');
};

// the page's parts as in-page code: the two grids, the strip, the counts line
const PARTS = `
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
    if (d.part === 'inst') { let e = document.querySelector('main'); for (const i of d.path) { e = e?.children[i]; } return e ?? null; }
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
    return null;
  };
`;
// every target of the page now (enumerated once per scope; each is found again after a reload)
const enumerate = full => ev(`(() => { ${PARTS}
  const out = [];
  // an instance's Summary: every element with its own short words (a direct text node), visible, outside a form
  // control; its place is a child-index path from main (the page draws the same shape on a reload)
  if (/[?&]i=/.test(location.hash)) {
    const m = document.querySelector('main');
    const pathOf = e => { const p = []; while (e && e !== m) { p.unshift([...e.parentElement.children].indexOf(e)); e = e.parentElement; } return p; };
    for (const e of m.querySelectorAll('*')) {
      if (e.closest('select, option, input, textarea, script, style, svg, [hidden]')) continue;
      const own = [...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join(' ').replace(/\s+/g, ' ').trim();
      if (!own || own.length > 80 || /^[·,:;()\/|-]+$/.test(own)) continue;
      const r = e.getBoundingClientRect(); if (r.width === 0 || r.height === 0) continue;
      const kind = e.closest('h1, h2, h3, h4, h5, h6') ? 'heading' : e.closest('table.props th, dt') ? 'label' : e.closest('a, button') ? 'control' : 'text';
      out.push({ part: 'inst', path: pathOf(e), label: (e.closest('[class]')?.className || e.tagName).toString().split(' ')[0], text: own, kind });
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
  return { hash: location.hash, modal, sort, view: inView.join('\\n'), all: all.join('\\n') };
})()`);
const mouse = async (type, x, y) => cmd('Input.dispatchMouseEvent', { type, x, y, button: type === 'mouseMoved' ? 'none' : 'left', clickCount: type === 'mouseMoved' ? 0 : 1 });

const results = [];
let fails = 0, plain = 0;
const line = r => `${r.verdict.startsWith('FAIL') ? 'FAIL' : r.verdict.startsWith('plain') ? 'plain' : 'ok  '} | ${r.scope} | ${r.part} | ${r.label} | ${String(r.text).slice(0, 40)}${r.row ? ' @ ' + r.row : ''} | ${r.effect}`;
for (const [scope, hash] of scopes) {
  await reset(hash, true);
  const targets = thin(await enumerate(process.env.CLICK_ALL === '1'), process.env.CLICK_ALL === '1');
  if (!scope.startsWith('instance') && (!targets.some(t => t.part === 'insthead') || !targets.some(t => t.part === 'testhead'))) {
    results.push({ scope, part: 'page', label: 'Summary', text: hash, effect: 'the Summary drew no test grid or no instance grid', verdict: 'FAIL' }); fails++; continue;
  }
  let dirty = false;
  for (const t of targets) {
    if (dirty) { await reset(hash); dirty = false; }
    const p = await locate(t);
    const r = { scope, ...t, engine: t.part === 'instcell' ? engineByName.get(t.row) ?? '' : '' };
    if (p.why) { r.effect = p.why; r.verdict = 'FAIL ' + p.why; results.push(r); fails++; console.log(line(r)); continue; }
    await mouse('mouseMoved', p.x, p.y); await sleep(150);
    const before = await snap();
    await mouse('mousePressed', p.x, p.y); await mouse('mouseReleased', p.x, p.y);
    await sleep(700);
    let after = await snap();
    if (after.hash !== before.hash) { await drawn(); after = await snap(); }
    const effects = [];
    if (after.hash !== before.hash) effects.push('lands on ' + after.hash);
    if (after.modal > before.modal) effects.push('opens a dialog or a menu');
    if (after.sort !== before.sort) effects.push('sort mark ' + (after.sort || 'none'));
    if (after.hash === before.hash && after.view !== before.view) effects.push('changes the view');
    const offView = after.hash === before.hash && after.view === before.view && after.all !== before.all;
    r.hit = p.hit;
    r.effect = effects.length ? effects.join('; ') : offView ? 'nothing in view (a change below the fold only)' : 'nothing';
    if (effects.length) { r.verdict = 'ok'; dirty = true; }
    else if (t.part === 'instcell' && plainColumns.has(t.label)) { r.verdict = 'plain (DBA Dash: a text cell, not a link)'; plain++; if (offView) dirty = true; }
    else if (t.part === 'inst' && (t.kind === 'heading' || t.kind === 'label')) { r.verdict = `plain (a ${t.kind}: it names what is beside it)`; plain++; if (offView) dirty = true; }
    else { r.verdict = 'FAIL dead click: ' + r.effect; fails++; if (offView) dirty = true; }
    results.push(r);
    console.log(line(r));
    await mouse('mouseMoved', 2, 2);
  }
  // the picture: the Summary with every dead text of this scope outlined in red, the whole page
  await reset(hash);
  const dead = results.filter(r => r.scope === scope && r.verdict.startsWith('FAIL') && r.part !== 'page');
  await ev(`(() => { ${PARTS}
    for (const d of ${JSON.stringify(dead)}) { const e = find(d); const box = d.part === 'inst' ? e : e?.closest('td, th, .attention-row, p') ?? e; if (box) box.style.outline = '3px solid #d00'; }
    window.scrollTo(0, 0); return true; })()`);
  const h = await ev('Math.ceil(document.documentElement.scrollHeight)');
  await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: Math.min(Math.max(h, 1000), 8000), deviceScaleFactor: 1, mobile: false });
  await sleep(500);
  const shot = await cmd('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${outDir}/summary-${scope.replace(/[^a-z0-9]+/gi, '-')}-dead.png`, Buffer.from(shot.result.data, 'base64'));
  await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
}
fs.writeFileSync(`${outDir}/summary-clicks.json`, JSON.stringify({ scopes, results }, null, 1));
// the dead list by part and column (what the fix works from)
const byCol = new Map();
for (const r of results.filter(x => x.verdict.startsWith('FAIL'))) {
  const k = `${r.part} | ${r.label}${r.engine ? ' (' + r.engine + ')' : ''}`;
  byCol.set(k, (byCol.get(k) ?? 0) + 1);
}
console.log('== dead, by part and column:');
for (const [k, n] of [...byCol.entries()].sort()) console.log(`DEAD ${k}: ${n}`);
console.log(`clicks: ${results.length}; ${fails} FAIL; ${plain} plain`);
ws.close();
process.exit(fails ? 1 : 0);
