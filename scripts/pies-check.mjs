// pies-check.mjs: the Storage pies answer the pointer as DBA Dash 4.24.1's do (a user's report of 2026-11-13: its pies
// are interactive and grow, with a table next to them, and pgvigil's were not), with the rows of the
// design pass 20261113-053822 (finding 11). Driven by scripts/proof-pies.sh over the Chrome DevTools Protocol with REAL
// pointer, touch and key events (a hover cannot be faked by a DOM click). Every row is graded by what the page shows,
// never by an attribute the product writes for the proof: a slice's wedge is found by where its colour is drawn and the
// legend's order, its geometry by the legend's shares, the expected page of a click from the API's own rows.
// usage: node scripts/pies-check.mjs <cdp port> <base url> <shots dir or ''> <rig json>
// Each row prints 'ok   <page> '<pie>': <row>: ...' or 'FAIL ...'; the last line 'pies-check: every row ok' or
// 'pies-check: N row(s) FAILED'. The row names (for the control's per-row expected in proof-pies.sh): size, labels,
// hover, other-hover, legend, rest, away, escape, redraw, menu, export, swatch, click, grid-link, ctrl-click, no-target,
// other-click, touch, pan, edge.
import { mkdirSync, writeFileSync } from 'node:fs';
const [port, U, SHOTS, RIG] = process.argv.slice(2);
const rig = JSON.parse(RIG);
if (SHOTS) mkdirSync(SHOTS, { recursive: true });
let fails = 0;
const ok = s => console.log(`ok   ${s}`);
const fail = s => { console.log(`FAIL ${s}`); fails++; };
const row = (good, tag, name, s) => good ? ok(`${tag}: ${name}: ${s}`) : fail(`${tag}: ${name}: ${s}`);

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise((res, rej) => {
  const i = ++id;
  const t = setTimeout(() => { wait.delete(i); rej(new Error(`the browser did not answer ${method} in 30 s`)); }, 30000);
  wait.set(i, d => { clearTimeout(t); res(d); });
  ws.send(JSON.stringify({ id: i, method, params }));
});
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 15000) => {
  const t = Date.now();
  while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(100); }
  return null;
};
const mouse = (type, x, y, extra = {}) => cmd('Input.dispatchMouseEvent', { type, x, y, button: 'none', ...extra });
const clickAt = async (x, y, button = 'left', modifiers = 0) => {
  await mouse('mouseMoved', x, y, { modifiers });
  await mouse('mousePressed', x, y, { button, clickCount: 1, modifiers });
  await mouse('mouseReleased', x, y, { button, clickCount: 1, modifiers });
};
// a tap of a finger: one touch down and up at a point (Input.dispatchTouchEvent; the browser makes the pointer events of
// type touch and the click from it). Input.synthesizeTapGesture reached the page as pointerdown / pointerup of type
// touch with no click at all in this headless Chromium (pdfp-pies-f2: the page heard no click of either tap). Touch
// emulation is on from the touch row's first tap until the second tap's page is read; the mouse rows keep a pointer
// that hovers
const touchOn = () => cmd('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 1 });
const touchOff = () => cmd('Emulation.setTouchEmulationEnabled', { enabled: false });
const tap = async (x, y) => {
  await cmd('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y, id: 1 }] });
  await sleep(50);
  await cmd('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
};
const key = async (k, code, vk) => {
  await cmd('Input.dispatchKeyEvent', { type: 'keyDown', key: k, code, windowsVirtualKeyCode: vk });
  await cmd('Input.dispatchKeyEvent', { type: 'keyUp', key: k, code, windowsVirtualKeyCode: vk });
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });

const go = async (hash) => {
  await ev(`location.href = ${JSON.stringify(U + '/' + hash)}`);
  await sleep(300);
  return until(`(() => { const m = document.querySelector('main'); if (!m || /Loading/.test(m.textContent.slice(0, 400))) return false;
    const d = [...m.querySelectorAll('.chart.donut')]; return d.length > 0 && d.every(x => x.querySelector('table.legend, .chart-state, p.empty')); })()`, 20000);
};
// the pie by its title (a title ending in '*' matches by its start: 'Growth by database, 7 days', 'Files of x by size')
const pieJS = (title) => title.endsWith('*')
  ? `[...document.querySelectorAll('main .chart.donut')].find(b => (b.querySelector('h3')?.firstChild?.textContent ?? '').trim().startsWith(${JSON.stringify(title.slice(0, -1))}))`
  : `[...document.querySelectorAll('main .chart.donut')].find(b => (b.querySelector('h3')?.firstChild?.textContent ?? '').trim() === ${JSON.stringify(title)})`;
// the page's helpers, defined once per page load: the legend rows, the wedges found by drawing, the geometry from the
// legend's shares (the slices are drawn in the legend's order from the top, clockwise)
const HELP = `window.__pie = {
  norm(c) { const d = document.createElement('div'); d.style.color = c; document.body.append(d); const v = getComputedStyle(d).color; d.remove(); return v; },
  legend(b) { return [...b.querySelectorAll('table.legend tbody tr')].map(tr => ({ name: (tr.cells[0]?.textContent ?? '').trim(), size: (tr.cells[1]?.textContent ?? '').trim(),
    share: (tr.cells[2]?.textContent ?? '').trim(), colour: this.norm(tr.querySelector('.swatch')?.style.background ?? ''), hot: tr.classList.contains('hot') })); },
  // the cumulative fractions of each slice, from the legend's shares
  spans(b) { const L = this.legend(b); const v = L.map(r => parseFloat(r.share.replace(',', '.')) || 0); const t = v.reduce((a, x) => a + x, 0) || 1;
    let o = 0; return v.map(x => { const s = [o, o + x / t]; o += x / t; return s; }); },
  // the point at fraction f of the circle (0 at the top, clockwise) and a share k of the radius, in the window
  point(b, f, k) { const s = b.querySelector('svg'); const r = s.getBoundingClientRect(); const a = 2 * Math.PI * f - Math.PI / 2;
    const R = (54 / 120) * r.width; return { x: r.left + r.width / 2 + k * R * Math.cos(a), y: r.top + r.height / 2 + k * R * Math.sin(a) }; },
  // the drawn wedges in legend order: the shape under each slice's middle point (its colour checked against the legend)
  wedges(b) { const sp = this.spans(b), L = this.legend(b); return sp.map(([a, z], i) => { const p = this.point(b, (a + z) / 2, 0.75);
    const e = document.elementFromPoint(p.x, p.y); const sh = e && b.querySelector('svg').contains(e) && /^(path|circle)$/.test(e.tagName) ? e : null;
    const c = sh ? this.norm(sh.getAttribute('fill') !== 'none' ? sh.getAttribute('fill') : sh.getAttribute('stroke')) : null;
    return sh && c === L[i].colour ? sh : null; }); },
  moved(e) { const t = getComputedStyle(e).transform; const a = e.getAttribute('transform') || ''; return (t && t !== 'none' && !/^matrix\\(1, 0, 0, 1, 0, 0\\)$/.test(t)) || /translate\\(/.test(a); },
  tip() { const t = [...document.querySelectorAll('.pie-tip')].find(x => x.offsetParent !== null && getComputedStyle(x).visibility !== 'hidden' && !x.hidden); if (!t) return null;
    const rows = [...t.querySelectorAll('.pie-tip-row, tr')].map(r => ({ cells: [...r.children].map(c => c.textContent.trim()), hot: r.classList.contains('hot') }));
    const rc = t.getBoundingClientRect(); return { rows, more: (t.querySelector('.pie-tip-more, p')?.textContent ?? '').trim(), rect: [rc.left, rc.top, rc.right, rc.bottom] }; },
  state(b) { const L = this.legend(b), W = [...b.querySelectorAll('svg path, svg circle')];
    return { legend: L, tip: this.tip(), hotRows: L.map((r, i) => r.hot ? i : -1).filter(i => i >= 0),
      popped: W.filter(e => this.moved(e)).map(e => W.indexOf(e)), hotWedges: b.querySelectorAll('svg path.hot, svg circle.hot').length }; },
};
'ok'`;
const S = (title, expr) => ev(`(() => { const b = ${pieJS(title)}; if (!b) return null; return ${expr}; })()`);
const state = title => S(title, `__pie.state(b)`);
const wedgePoint = async (title, k, rad = 0.75) => {
  await S(title, `(b.querySelector('svg').scrollIntoView({ block: 'center' }), 1)`);
  await sleep(350);   // the scroll's own event a frame later (a scroll puts the box away)
  return S(title, `(() => { const sp = __pie.spans(b)[${k}]; return sp ? __pie.point(b, (sp[0] + sp[1]) / 2, ${rad}) : null; })()`);
};
const tipMatches = (s, k) => {
  // every row of the box = the legend's row, in order (15 at most around the hovered one), the hovered one marked
  if (!s?.tip) return 'no box';
  const L = s.legend, rows = s.tip.rows;
  const n = Math.min(L.length, 15);
  if (rows.length !== n) return `${rows.length} rows, the legend ${L.length}`;
  const lo = L.length > 15 ? Math.max(0, Math.min(k - 7, L.length - 15)) : 0;
  for (let j = 0; j < n; j++) {
    const lr = L[lo + j], tr = rows[j], txt = tr.cells.join(' ');
    if (tr.cells[0] !== lr.name || !txt.includes(lr.size) || !txt.includes(lr.share)) return `row ${j} '${txt}' against the legend's '${lr.name} ${lr.size} ${lr.share}'`;
    if (tr.hot !== (lo + j === k)) return `row ${j} marked ${tr.hot}`;
  }
  if (L.length > 15 && !/^\.\.\. \d+ more$/.test(s.tip.more)) return `no '... n more' line ('${s.tip.more}')`;
  return '';
};

for (const pg of rig.pages) {
  console.log(`== ${pg.name}: ${pg.hash}`);
  if (!await go(pg.hash)) { fail(`${pg.name}: the page or its pies did not draw in 20 s`); continue; }
  await ev(HELP);
  for (const pie of pg.pies) {
    const tag = `${pg.name} '${pie.title}'`;
    // a pie drawn later than the page (the Growth panels) is waited for, its first days button pressed if need be
    let s0 = await until(`(() => { const b = ${pieJS(pie.title)}; return b && b.querySelector('table.legend') ? 1 : null; })()`, 8000);
    if (!s0 && pie.days) { await ev(`[...document.querySelectorAll('main button')].find(x => x.textContent.trim() === ${JSON.stringify(pie.days)})?.click()`);
      s0 = await until(`(() => { const b = ${pieJS(pie.title)}; return b && b.querySelector('table.legend') ? 1 : null; })()`, 15000); }
    if (!s0) { fail(`${tag}: no such pie with a legend (titles: ${await ev(`JSON.stringify([...document.querySelectorAll('main .chart.donut h3')].map(h => h.firstChild?.textContent))`)})`); continue; }
    await ev(HELP);
    const st0 = await state(pie.title);
    if (st0.legend.length < 2) { fail(`${tag}: the legend holds ${st0.legend.length} slice(s); the rows need 2 or more`); continue; }
    // size (P0): the drawn side by the caller's table
    const w = await S(pie.title, `Math.round(b.querySelector('svg').getBoundingClientRect().width)`);
    const [lo, hi] = pie.size === 'big' ? [300, 520] : [150, 200];
    row(w >= lo && w <= hi, tag, 'size', `drawn ${w} px across (want ${lo}-${hi}: ${pie.size})`);
    // labels (P4): every label drawn is '<name> <size> (<share>)' or the share as a whole number of its slice, lies
    // inside its wedge and overlaps no other; a big pie's largest slice carries the long form
    const lab = await S(pie.title, `(() => { const s = b.querySelector('svg'), sp = __pie.spans(b), L = __pie.legend(b);
      const T = [...s.querySelectorAll('text')].filter(t => t.textContent.trim() && getComputedStyle(t).display !== 'none');
      const bad = [], boxes = [], longOn = [];
      for (const t of T) { const bb = t.getBBox(); const cx = bb.x + bb.width / 2 - 60, cy = bb.y + bb.height / 2 - 60;
        const f = ((Math.atan2(cy, cx) + Math.PI / 2) / (2 * Math.PI) + 1) % 1; const k = sp.findIndex(([a, z]) => f >= a && f <= z);
        if (k < 0) { bad.push('no slice under ' + t.textContent); continue; }
        const long = L[k].name + ' ' + L[k].size + ' (' + L[k].share + ')', short = Math.round(parseFloat(L[k].share.replace(',', '.'))) + ' %';
        const txt = t.textContent.trim(); if (txt !== long && txt !== short) bad.push(JSON.stringify(txt) + ' on ' + L[k].name);
        if (txt === long) longOn.push(k);
        for (const [x, y] of [[bb.x, bb.y], [bb.x + bb.width, bb.y], [bb.x, bb.y + bb.height], [bb.x + bb.width, bb.y + bb.height]]) {
          const dx = x - 60, dy = y - 60, rad = Math.hypot(dx, dy), g = ((Math.atan2(dy, dx) + Math.PI / 2) / (2 * Math.PI) + 1) % 1;
          const whole = sp[k][1] - sp[k][0] > 0.9999;
          if (rad > 54.5 || (!whole && (g < sp[k][0] - 1e-6 || g > sp[k][1] + 1e-6))) { bad.push(JSON.stringify(txt) + ' outside its wedge'); break; } }
        for (const o of boxes) if (bb.x < o.x + o.width && o.x < bb.x + bb.width && bb.y < o.y + o.height && o.y < bb.y + bb.height) bad.push(JSON.stringify(txt) + ' overlaps');
        boxes.push(bb);
        for (const a of ['fill', 'stroke', 'font-size']) if (!t.getAttribute(a)) bad.push(JSON.stringify(txt) + ' has no ' + a + ' attribute');
        // the halo wide enough to be the letters' background (WCAG 1.4.3: white on the dark theme's slices alone is 3.1-3.9:1)
        const fsz = parseFloat(t.getAttribute('font-size') ?? ''), sw = parseFloat(t.getAttribute('stroke-width') ?? '');
        if (!(sw >= 0.38 * fsz) || t.getAttribute('stroke-linejoin') !== 'round') bad.push(JSON.stringify(txt) + ' halo ' + (sw / fsz).toFixed(2) + ' of its size, joins ' + t.getAttribute('stroke-linejoin') + ' (want 0.4, round)');
      }
      return { n: T.length, texts: T.map(t => t.textContent.trim()), bad, longOn }; })()`);
    row(lab.n > 0 && !lab.bad.length, tag, 'labels', `${lab.n} drawn, ${lab.longOn.length} in the long form (${lab.texts.slice(0, 6).join(' | ')})${lab.bad.length ? '; ' + lab.bad.slice(0, 4).join('; ') : ''}`);
    // hover the SECOND-largest wedge: the box = the legend row by row with it marked, it alone popped out, its row marked
    let p = await wedgePoint(pie.title, 1);
    await mouse('mouseMoved', p.x, p.y);
    const s1 = await until(`(() => { const b = ${pieJS(pie.title)}; const s = b && __pie.state(b); return s && s.tip ? s : null; })()`, 2000);
    const m1 = s1 ? tipMatches(s1, 1) : 'no box in 2 s';
    row(s1 && !m1 && s1.popped.join() === '1' && s1.hotRows.join() === '1', tag, 'hover',
      `the pointer on '${st0.legend[1].name}' -> ${m1 || 'the box lists the legend with it marked'}; popped ${JSON.stringify(s1?.popped)}; legend rows marked ${JSON.stringify(s1?.hotRows)} (want [1], [1])`);
    if (SHOTS && pie.shot) writeFileSync(`${SHOTS}/${pg.name}-${pie.shot}-hover.png`, Buffer.from((await cmd('Page.captureScreenshot', { format: 'png' })).result.data, 'base64'));
    // export (blocker 1): the picture serialized while a slice is popped carries no transform, its labels their attributes
    const ex = await S(pie.title, `(() => { const s = b.querySelector('svg'); const x = new XMLSerializer().serializeToString(s);
      return { transform: /transform/i.test(x), popped: __pie.state(b).popped.length }; })()`);
    row(ex && !ex.transform && ex.popped === 1, tag, 'export', `serialized while '${st0.legend[1].name}' is popped: ${ex?.transform ? 'a transform in the copy' : 'no transform in the copy'}, popped ${ex?.popped} (want none in the copy, 1 on the page)`);
    // swatch (finding 5): the box's squares are not the legend's .swatch
    const sw = await S(pie.title, `[b.querySelectorAll('.swatch').length, __pie.legend(b).length]`);
    row(sw && sw[0] === sw[1], tag, 'swatch', `${sw?.[0]} .swatch in the chart box with the box shown, ${sw?.[1]} legend rows`);
    // rest (finding 4): the pointer at 10 % of the radius on the popped slice's middle line stays marked for 1 s
    const sp1 = await S(pie.title, `__pie.spans(b)[1]`);
    const pr = await S(pie.title, `__pie.point(b, ${(sp1[0] + sp1[1]) / 2}, 0.1)`);
    await ev(`(() => { const b = ${pieJS(pie.title)}; window.__toggles = 0; window.__mo?.disconnect();
      window.__mo = new MutationObserver(ms => { for (const m of ms) if (m.attributeName === 'class' || m.attributeName === 'transform') window.__toggles++; });
      window.__mo.observe(b.querySelector('svg'), { subtree: true, attributes: true, attributeFilter: ['class', 'transform'] }); return 1; })()`);
    await mouse('mouseMoved', pr.x, pr.y);
    await sleep(1000);
    const rest = await ev(`(() => { window.__mo.disconnect(); const b = ${pieJS(pie.title)}; return { toggles: window.__toggles, s: __pie.state(b) }; })()`);
    row(rest.toggles <= 2 && rest.s.popped.join() === '1' && !!rest.s.tip, tag, 'rest',
      `the pointer resting at 10 % of the radius on its middle line for 1 s: ${rest.toggles} class / transform changes, popped ${JSON.stringify(rest.s.popped)}, box ${rest.s.tip ? 'shown' : 'gone'} (want at most 2, [1], shown)`);
    // other-hover: the 'other (n)' wedge marks its own row
    const kOther = st0.legend.findIndex(r => /^other \(\d+\)/.test(r.name));
    if (kOther >= 0) {
      p = await wedgePoint(pie.title, kOther);
      await mouse('mouseMoved', p.x, p.y);
      // the box marks the row at once; the slices move in a 0.12 s transition (app.css .pop): read after it settles
      // (pdfp-pies-f1 read slice 1 still on its way back: 'popped [1]')
      const so0 = await until(`(() => { const b = ${pieJS(pie.title)}; const s = b && __pie.state(b); return s && s.tip && s.tip.rows.some(r => r.hot) ? s : null; })()`, 2000);
      if (so0) await sleep(250);
      const so = so0 ? await state(pie.title) : null;
      const hotRow = so?.tip?.rows.find(r => r.hot);
      row(!!hotRow && /^other \(\d+\)$/.test(hotRow.cells[0]) && so.popped.join() === String(kOther), tag, 'other-hover', `the pointer on 'other' -> marked row '${hotRow?.cells.join(' ')}', popped ${JSON.stringify(so?.popped)}`);
    }
    // legend: a legend row marks its wedge
    const lp = await S(pie.title, `(() => { const tr = b.querySelectorAll('table.legend tbody tr')[1]; tr.scrollIntoView({ block: 'center' }); const r = tr.cells[1].getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()`);
    await sleep(300);
    await mouse('mouseMoved', lp.x, lp.y);
    const sl = await until(`(() => { const b = ${pieJS(pie.title)}; const s = b && __pie.state(b); return s && s.hotRows.join() === '1' && s.popped.join() === '1' ? s : null; })()`, 2000);
    row(!!sl, tag, 'legend', `the pointer on the legend row '${st0.legend[1].name}' -> ${sl ? 'its wedge popped and its row marked' : JSON.stringify(await state(pie.title))}`);
    // away: the box gone, nothing marked
    await mouse('mouseMoved', 3, 3);
    const sa = await until(`(() => { const b = ${pieJS(pie.title)}; const s = b && __pie.state(b); return s && !s.tip && !s.popped.length && !s.hotRows.length && !s.hotWedges ? s : null; })()`, 2000);
    row(!!sa, tag, 'away', sa ? 'the pointer away -> no box, nothing marked' : `the pointer away -> ${JSON.stringify(await state(pie.title))}`);
    // escape: shown, then Escape -> gone
    p = await wedgePoint(pie.title, 0);
    await mouse('mouseMoved', p.x, p.y);
    const shown = await until(`(() => { const b = ${pieJS(pie.title)}; return b && __pie.tip() ? 1 : null; })()`, 2000);
    await key('Escape', 'Escape', 27);
    const gone = await until(`__pie.tip() ? null : 1`, 1000);
    row(!!shown && !!gone, tag, 'escape', `the box ${shown ? 'shown' : 'never shown'}, then Escape -> ${gone ? 'gone' : 'still shown'}`);
    // menu: a right click -> the chart menu, the box put away
    p = await wedgePoint(pie.title, 0);
    await mouse('mouseMoved', p.x, p.y);
    await until(`__pie.tip() ? 1 : null`, 1000);
    await clickAt(p.x, p.y, 'right');
    const items = await until(`(() => { const m = document.querySelector('.menu'); return m ? { items: [...m.querySelectorAll('button')].map(b => b.textContent.trim()), tip: !!__pie.tip() } : null; })()`, 2000);
    const want = ['Copy image', 'Save image', 'Copy data', 'Export data (CSV)', 'Export Excel'];
    row(!!items && want.every(x => items.items.includes(x)) && !items.tip, tag, 'menu', `a right click -> ${items ? items.items.join(' | ') : 'no menu'}; the box ${items?.tip ? 'still shown' : 'gone'}`);
    await key('Escape', 'Escape', 27);
    await ev(`document.querySelector('.menu')?.remove(); 1`);
    // redraw (finding 5): shown, then the chart drawn again under the pointer (its Top N, else the page's Refresh). The
    // pointer comes from outside the picture: after the menu row it rests on the wedge with the box put away, and a move
    // inside one wedge sends no pointerover (pdfp-pies-f1: 'the box never shown')
    await mouse('mouseMoved', 3, 3);
    await until(`__pie.tip() ? null : 1`, 1000);
    p = await wedgePoint(pie.title, 0);
    await mouse('mouseMoved', p.x, p.y);
    const shown2 = await until(`__pie.tip() ? 1 : null`, 2000);
    const how = await S(pie.title, `(() => { const sel = b.querySelector('select.donut-top'); if (sel && sel.options.length > 1) { sel.selectedIndex = (sel.selectedIndex + 1) % sel.options.length; sel.dispatchEvent(new Event('change', { bubbles: true })); return 'its Top N'; }
      const r = [...document.querySelectorAll('main button')].find(x => x.textContent.trim() === 'Refresh'); if (r) { r.click(); return 'Refresh'; } return ''; })()`);
    if (how) {
      await sleep(1500);
      // no STALE state (the pass's 'no tooltip remains'): the old box and pop-out are gone with the old picture; Chromium
      // sends pointerover to the new wedge under the resting pointer, so one fresh box is right when it marks that
      // wedge's row and that wedge alone stands out
      const after = await ev(`(() => { const tips = [...document.querySelectorAll('.pie-tip')].filter(t => t.offsetParent !== null && !t.hidden);
        const all = [...document.querySelectorAll('main .chart.donut svg path, main .chart.donut svg circle')].filter(e => __pie.moved(e)).length;
        const b = ${pieJS(pie.title)}; const W = b ? [...b.querySelectorAll('svg path, svg circle')] : []; const L = b ? __pie.legend(b) : [];
        const e = document.elementFromPoint(${p.x}, ${p.y}); const under = e ? W.indexOf(e) : -1;
        return { tips: tips.length, all, popped: W.filter(x => __pie.moved(x)).map(x => W.indexOf(x)), under: under >= 0 ? under : null,
          under_name: under >= 0 ? L[under]?.name ?? null : null,
          marked: tips[0] ? [...tips[0].querySelectorAll('.pie-tip-row.hot')].map(r => r.children[0]?.textContent.trim()) : [] }; })()`);
      const fresh = after.tips === 1 && after.all === 1 && after.under !== null && after.popped.join() === String(after.under)
        && after.marked.length === 1 && after.marked[0] === after.under_name;
      row(!!shown2 && ((after.tips === 0 && after.all === 0) || fresh), tag, 'redraw',
        `the box ${shown2 ? 'shown' : 'never shown'}, then ${how} -> ${after.tips} box(es), ${after.all} popped slice(s)${after.tips || after.all ? `: the box marks ${JSON.stringify(after.marked)}, popped ${JSON.stringify(after.popped)}, under the pointer ${after.under === null ? 'no wedge' : `${after.under} '${after.under_name}'`}` : ''} (want no stale state: none, or one box for the wedge under the resting pointer, it alone popped)`);
      await ev(`localStorage.clear(); 1`);
      await go(pg.hash); await ev(HELP);
      await until(`(() => { const b = ${pieJS(pie.title)}; return b && b.querySelector('table.legend') ? 1 : null; })()`, 15000);
      if (pie.days && !await S(pie.title, '1')) { await ev(`[...document.querySelectorAll('main button')].find(x => x.textContent.trim() === ${JSON.stringify(pie.days)})?.click()`);
        await until(`(() => { const b = ${pieJS(pie.title)}; return b && b.querySelector('table.legend') ? 1 : null; })()`, 15000); }
    }
    // the expected page of a click: from the API's own rows and the slice's name (never from the wedge's data-href)
    let target = null;
    if (pie.target) {
      const L = (await state(pie.title)).legend;
      target = await ev(`(async () => { const name = ${JSON.stringify(L[0].name)}; const t = ${JSON.stringify(pie.target)};
        const api = async (q) => { const r = await fetch('/api/' + q, { headers: { 'X-Pgvigil': '1' } }); return r.json(); };
        const rows = (j, p) => { const x = j[p]; return x ? x.rows.map(r => Object.fromEntries(x.columns.map((c, i) => [c, r[i]]))) : []; };
        if (t.kind === 'instance') { const r = rows(await api(t.api), t.part).find(r => String(r[t.name]) === name); return r ? { re: '^#/dbspace\\\\?(.*&)?i=' + r.instance_id + '(&|$)', h2: null } : null; }
        if (t.kind === 'pgdb') { const r = rows(await api(t.api), t.part).find(r => String(r[t.name]) === name); return r && r.dbid != null ? { re: '^#/db\\\\?(.*&)?db=' + r.dbid + '(&|$)', h2: 'Database ' + name } : null; }
        if (t.kind === 'msfiles') return { re: '^#/mssqlfiles\\\\?(.*&)?db=' + encodeURIComponent(name).replace(/[.*+?^$()|[\\]\\\\]/g, '\\\\$&') + '(&|$)', db: name };
        return null; })()`, true);
      if (!target) fail(`${tag}: click: the API gives no target for '${L[0].name}' (${JSON.stringify(pie.target)})`);
    }
    // grid-link (finding 13): the grid's link of the largest database = the slice's page
    if (pie.gridLink && target) {
      const L = (await state(pie.title)).legend;
      const hrefs = await ev(`[...document.querySelectorAll('main table.grid tbody tr')].map(tr => tr.cells[0]).filter(c => c && c.textContent.trim() === ${JSON.stringify(L[0].name)}).map(c => c.querySelector('a')?.getAttribute('href') ?? null)`);
      row(!!hrefs?.length && hrefs.every(h => h && new RegExp(target.re).test(h)), tag, 'grid-link', `the grid's '${L[0].name}' cell links ${JSON.stringify(hrefs)} (want /${target.re}/)`);
    }
    // ctrl-click (finding 14): Ctrl and a wedge with a page -> a new tab with it, this page stays
    if (target) {
      await ev(`window.__opened = []; window.open = (u) => { window.__opened.push(String(u)); return null; }; 1`);
      p = await wedgePoint(pie.title, 0);
      const before = await ev('location.hash');
      await clickAt(p.x, p.y, 'left', 2);
      await sleep(600);
      const o = await ev(`({ opened: window.__opened, hash: location.hash })`);
      row(o.hash === before && o.opened.length === 1 && new RegExp(target.re).test(o.opened[0].replace(/^.*#/, '#')), tag, 'ctrl-click', `Ctrl + click on '${(await state(pie.title))?.legend?.[0]?.name}' -> opened ${JSON.stringify(o.opened)}, this page ${o.hash === before ? 'kept' : 'left for ' + o.hash}`);
      if (o.hash !== before) { await go(pg.hash); await ev(HELP); }
    }
    // touch (finding 6): the first tap shows the box and stays, a second tap on the slice follows its page
    if (target && pie.touch) {
      p = await wedgePoint(pie.title, 0);
      const before = await ev('location.hash');
      await ev(`(() => { window.__tev = []; if (!window.__tevOn) { window.__tevOn = 1; for (const t of ['pointerdown', 'pointerup', 'click'])
        document.addEventListener(t, e => window.__tev.push(t + ':' + (e.pointerType ?? '-') + ':' + (e.target?.getAttribute?.('data-slice') ?? e.target?.tagName ?? '?')), true); } return 1; })()`);
      await touchOn();
      await tap(p.x, p.y);
      await sleep(400);
      const t1 = await ev(`({ hash: location.hash, tip: !!__pie.tip() })`);
      await tap(p.x, p.y);
      const t2 = await until(`location.hash !== ${JSON.stringify(before)} ? location.hash : null`, 3000);
      await touchOff();
      const good = t1.hash === before && t1.tip && !!t2 && new RegExp(target.re).test(t2);
      const tev = good ? '' : `; the page heard ${JSON.stringify(await ev('window.__tev ?? []'))}`;
      row(good, tag, 'touch', `the first tap -> ${t1.tip ? 'the box' : 'no box'}, ${t1.hash === before ? 'this page kept' : 'left for ' + t1.hash}; the second -> ${t2 ?? 'nothing'}${tev}`);
      await go(pg.hash); await ev(HELP);
    }
    // pan (review 20261113-102227 finding 2): a finger that starts on a wedge and pans the page ends with no click; the
    // next MOUSE click on the wedge still opens its page (a held first tap would swallow it)
    if (target && pie.touch) {
      p = await wedgePoint(pie.title, 0);
      await ev(`(() => { window.__tev = []; if (!window.__tevOn) { window.__tevOn = 1; for (const t of ['pointerdown', 'pointerup', 'pointercancel', 'click'])
        document.addEventListener(t, e => window.__tev.push(t + ':' + (e.pointerType ?? '-') + ':' + (e.target?.getAttribute?.('data-slice') ?? e.target?.tagName ?? '?')), true); } return 1; })()`);
      await touchOn();
      await cmd('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: p.x, y: p.y, id: 1 }] });
      for (let i = 1; i <= 6; i++) { await sleep(30); await cmd('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: p.x, y: p.y - 30 * i, id: 1 }] }); }
      await cmd('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
      await touchOff();
      await sleep(400);
      const heard = await ev('window.__tev ?? []');
      const before = await ev('location.hash');
      p = await wedgePoint(pie.title, 0);
      await clickAt(p.x, p.y);
      const t3 = await until(`location.hash !== ${JSON.stringify(before)} ? location.hash : null`, 3000);
      row(!!t3 && new RegExp(target.re).test(t3) && !heard.some(x => x.startsWith('click:')), tag, 'pan',
        `a pan from the wedge (the page heard ${JSON.stringify(heard)}), then a mouse click on it -> ${t3 ?? 'nothing'} (want its page, no click from the pan)`);
      await go(pg.hash); await ev(HELP);
    }
    // click: a wedge with a page -> the API's page, drawn (the database page's heading, the files tab's database)
    if (target) {
      p = await wedgePoint(pie.title, 0);
      const before = await ev('location.hash');
      await clickAt(p.x, p.y);
      const after = await until(`location.hash !== ${JSON.stringify(before)} ? location.hash : null`, 3000);
      let drew = null;
      if (after && new RegExp(target.re).test(after)) {
        drew = target.h2 ? await until(`(() => { const h = document.querySelector('main h2'); return h && h.textContent.trim() === ${JSON.stringify(target.h2)} ? h.textContent.trim() : null; })()`, 20000)
          : target.db ? await until(`(() => { const s = document.querySelector('#mssql-files-db'); return s && s.value === ${JSON.stringify(target.db)} ? 'the files of ' + s.value : null; })()`, 20000)
          : await until(`(() => { const h = document.querySelector('main h2'); return h ? h.textContent.trim() : null; })()`, 20000);
      }
      // the page a click lands on, shot as drawn (the lead's 'a click landing')
      if (SHOTS && pie.shot && drew) writeFileSync(`${SHOTS}/${pg.name}-${pie.shot}-click.png`, Buffer.from((await cmd('Page.captureScreenshot', { format: 'png' })).result.data, 'base64'));
      row(!!drew, tag, 'click', `a click on '${st0.legend[0].name}' -> ${after ?? before + ' (unchanged)'}${drew ? `, drew '${drew}'` : ` (want /${target.re}/ and ${target.h2 ? `'${target.h2}'` : target.db ? `the files of '${target.db}'` : 'a heading'})`}`);
      if (!await go(pg.hash)) { fail(`${pg.name}: the page did not draw again after the click`); break; }
      await ev(HELP);
    }
    // no-target (blocker 3): no wedge opens a page, a click leaves the address
    if (pie.noTarget) {
      p = await wedgePoint(pie.title, 0);
      const before = await ev('location.hash');
      await clickAt(p.x, p.y);
      await sleep(800);
      const nt = await ev(`({ hash: location.hash, href: document.querySelectorAll('main .chart.donut svg [data-href]').length })`);
      row(nt.hash === before, tag, 'no-target', `a click on '${st0.legend[0].name}' -> ${nt.hash === before ? 'the address kept' : nt.hash}`);
      await mouse('mouseMoved', 3, 3);
    }
    // edge: the box inside the window for the slice nearest the window's right edge. The pointer comes from outside the
    // picture: the scroll that centres the pie puts the box away, and a move inside one wedge sends no pointerover
    // (pdfp-pies-f4: after the click row the pointer rested on erp's wedge, whose span holds the pie's right side)
    if (pie.edge) {
      await mouse('mouseMoved', 3, 3);
      await until(`__pie.tip() ? null : 1`, 1000);
      const pe = await S(pie.title, `(() => { const s = b.querySelector('svg'); s.scrollIntoView({ block: 'center' }); const sp = __pie.spans(b); let best = null;
        sp.forEach(([a, z], k) => { for (let f = a + 0.02 * (z - a); f < z; f += (z - a) / 20) { const q = __pie.point(b, f, 0.9); if (document.elementFromPoint(q.x, q.y)?.closest('svg') === s && (!best || q.x > best.x)) best = { ...q, k }; } });
        return best; })()`);
      await sleep(350);
      await mouse('mouseMoved', pe.x, pe.y);
      const te = await until(`__pie.tip()`, 2000);
      const vw = await ev('[innerWidth, innerHeight]');
      // the box beside the pointer (14 px right), flipped to its left where it would pass the window's right edge less 4
      // px (chart.ts place()); pie.edge 'flip': a pie at the window's right, where the flip must happen (review finding 3)
      const wantFlip = !!te && pe.x + 14 + (te.rect[2] - te.rect[0]) > vw[0] - 4;
      const side = te ? (te.rect[2] <= pe.x ? 'left of the pointer' : te.rect[0] >= pe.x ? 'right of the pointer' : 'over the pointer') : '';
      row(!!te && te.rect[0] >= 0 && te.rect[1] >= 0 && te.rect[2] <= vw[0] - 4 && te.rect[3] <= vw[1] && side === (wantFlip ? 'left of the pointer' : 'right of the pointer')
        && (pie.edge !== 'flip' || wantFlip), tag, 'edge',
        `the pointer at x ${Math.round(pe.x)} of ${vw[0]} -> the box ${te ? `at [${te.rect.map(Math.round).join(', ')}], ${side}` : 'not shown'} (inside 0 0 ${vw[0] - 4} ${vw[1]}; ${wantFlip ? 'flipped' : 'not flipped'}${pie.edge === 'flip' ? ', the flip wanted' : ''})`);
      await mouse('mouseMoved', 3, 3);
    }
    // other-click (finding 9): every slice for this draw, the select says All, the focus on it, the note says so, nothing kept
    if (pie.other && kOther >= 0) {
      await ev(`localStorage.clear(); 1`);
      const n = Number(/\((\d+)\)/.exec(st0.legend[kOther].name)[1]);
      const cellText = await S(pie.title, `b.querySelectorAll('table.legend tbody tr')[${kOther}].cells[0].textContent.trim()`);
      p = await wedgePoint(pie.title, kOther);
      await clickAt(p.x, p.y);
      const oc = await until(`(() => { const b = ${pieJS(pie.title)}; const L = b && __pie.legend(b); return L && L.length === ${st0.legend.length - 1 + n} ? { legend: L.length,
        sel: b.querySelector('select.donut-top')?.value, focus: document.activeElement === b.querySelector('select.donut-top'), note: (b.querySelector('.chart-note')?.textContent ?? '').trim(),
        kept: Object.keys(localStorage).filter(k => k.startsWith('pgvigil.topn.')) } : null; })()`, 3000);
      row(!!oc && oc.sel === '0' && oc.focus && /^Showing all \d+ slices$/.test(oc.note) && !oc.kept.length && cellText === st0.legend[kOther].name, tag, 'other-click',
        `the 'other' cell read '${cellText}'; a click -> ${oc ? `${oc.legend} slices, the select ${oc.sel}, the focus ${oc.focus ? 'on it' : 'elsewhere'}, the note '${oc.note}', kept ${JSON.stringify(oc.kept)}` : 'the legend did not grow'}`);
      await ev(`localStorage.clear(); 1`);
      await go(pg.hash); await ev(HELP);
    }
  }
  if (SHOTS) for (const theme of ['light', 'dark']) {
    await ev(`document.documentElement.setAttribute('data-theme', '${theme}'); 1`);
    const first = pg.pies.find(x => x.shot);
    if (first) { const q = await wedgePoint(first.title, 0); if (q) await mouse('mouseMoved', q.x, q.y); await sleep(500); }
    writeFileSync(`${SHOTS}/${pg.name}-${theme}.png`, Buffer.from((await cmd('Page.captureScreenshot', { format: 'png' })).result.data, 'base64'));
    await mouse('mouseMoved', 3, 3);
  }
  await ev(`document.documentElement.removeAttribute('data-theme'); 1`);
  if (SHOTS) {
    await cmd('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
    await sleep(600);
    const first = pg.pies.find(x => x.shot);
    if (first) { const q = await wedgePoint(first.title, 0); if (q) await mouse('mouseMoved', q.x, q.y); await sleep(500); }
    writeFileSync(`${SHOTS}/${pg.name}-1280.png`, Buffer.from((await cmd('Page.captureScreenshot', { format: 'png' })).result.data, 'base64'));
    await mouse('mouseMoved', 3, 3);
    await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
  }
}
console.log(fails ? `pies-check: ${fails} row(s) FAILED` : 'pies-check: every row ok');
ws.close();
process.exit(fails ? 1 : 0);
