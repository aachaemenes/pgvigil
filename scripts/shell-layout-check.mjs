// The page's shell laid out as the window and the header let it be, over a headless Chromium (CDP), signed in as one
// user on a serve with the login on:
//   S1  the tree under the header (1366 x 768, light and dark): with a long custom range label the signed-in header takes
//       three lines or more; the page scrolled, the tree's top and its first row sit at or below the header's bottom
//       and its bottom at the window's - no row hidden under the header, none past the window. A header of fewer than
//       three lines is NOT PROVEN (the case is not made), never a pass.
//   S2  the tree hidden (1280 x 800 and 1600 x 900): the page's content as wide as the window less its margins
//   S1b the same tree when the header grows while the page is scrolled: the page scrolled under the default range, then
//       the long range applied - the header taller, the tree's top and first row at or below its new bottom
//   S3  the tree's search box (1280 x 800 and 1600 x 900): its placeholder's words inside the box
//   S4  the search box's accessible name starts with the words it shows (WCAG 2.5.3 Label in Name)
// A shot of each case. SHELL_SWAP=<folder> serves that folder's app.js and app.css in place of the server's (the page
// before a change, over the same serve).
// Usage: node scripts/shell-layout-check.mjs <cdp port> <base url/> <user> <password> <out dir>
// Prints one line per row ('ok' / 'FAIL' / 'NOT PROVEN' with what was read) and 'shell-layout: <n> ok, <m> FAIL,
// <k> NOT PROVEN'; exit 1 on a FAIL, 2 when the sign-in fails.
import { readFileSync, writeFileSync } from 'node:fs';
const [port, U, user, pw, OUT] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map(), handlers = [];
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); return; } for (const h of handlers) h(d); });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const size = (w, h) => cmd('Emulation.setDeviceMetricsOverride', { width: w, height: h, deviceScaleFactor: 1, mobile: false });
const theme = t => cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: t }] });
const shot = async name => { const d = await cmd('Page.captureScreenshot', { format: 'png' }); if (d.result?.data) writeFileSync(`${OUT}/${name}.png`, Buffer.from(d.result.data, 'base64')); };
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable');
if (process.env.SHELL_SWAP) {
  const files = { 'app.js': readFileSync(`${process.env.SHELL_SWAP}/app.js`), 'app.css': readFileSync(`${process.env.SHELL_SWAP}/app.css`) };
  handlers.push(async d => {
    if (d.method !== 'Fetch.requestPaused') return;
    const name = new URL(d.params.request.url).pathname.split('/').pop();
    if (files[name]) await cmd('Fetch.fulfillRequest', { requestId: d.params.requestId, responseCode: 200,
      responseHeaders: [{ name: 'Content-Type', value: name.endsWith('.js') ? 'text/javascript' : 'text/css' }], body: files[name].toString('base64') });
    else await cmd('Fetch.continueRequest', { requestId: d.params.requestId });
  });
  await cmd('Fetch.enable', { patterns: [{ urlPattern: '*app.js*' }, { urlPattern: '*app.css*' }] });
  await cmd('Network.setCacheDisabled', { cacheDisabled: true });
  console.log(`(the page is drawn by ${process.env.SHELL_SWAP}'s app.js and app.css)`);
}
// auto refresh off: a page redrawn under the read would be read half drawn
await cmd('Page.addScriptToEvaluateOnNewDocument', { source: `try { localStorage.setItem('pgvigil.refresh', '0'); } catch (e) {}` });
await size(1366, 768); await theme('light');
await cmd('Page.navigate', { url: U }); await sleep(1000);
// sign in from the page itself: the session cookie is the page's own
const code = await ev(`fetch('/api/login', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
  body: JSON.stringify({ username: ${JSON.stringify(user)}, password: ${JSON.stringify(pw)} }) }).then(r => r.status)`, true);
if (code !== 200) { console.log(`FAIL shell-layout: the sign-in of ${user} answered ${code}`); process.exit(2); }
let ok = 0, fail = 0, np = 0;
const row = (name, pass, got) => { pass ? ok++ : fail++; console.log(`${pass ? 'ok  ' : 'FAIL'} shell-layout: ${name}: ${JSON.stringify(got)}`); };
const notProven = (name, why) => { np++; console.log(`NOT PROVEN shell-layout: ${name}: ${JSON.stringify(why)}`); };
const settle = async () => {
  for (let i = 0; i < 100; i++) {
    const done = await ev(`(() => { const m = document.querySelector('main'); return !!m && m.children.length > 0 && !/^Loading/.test(m.textContent.trim()) && !!document.querySelector('#tree .tree-root'); })()`);
    if (done) { await sleep(700); return true; }
    await sleep(200);
  }
  return false;
};
// a custom range that ends in the past: today 07:13 to 10:43 on the browser's clock, yesterday's before 10:43
const open = async hashFrom => {
  await cmd('Page.navigate', { url: 'about:blank' }); await sleep(150);
  await cmd('Page.navigate', { url: U + hashFrom }); return settle();
};
const longRange = await ev(`(() => { const d = new Date(); if (d.getHours() * 60 + d.getMinutes() < 10 * 60 + 50) d.setDate(d.getDate() - 1);
  const a = new Date(d), z = new Date(d); a.setHours(7, 13, 0, 0); z.setHours(10, 43, 0, 0);
  return 'from=' + encodeURIComponent(a.toISOString()) + '&to=' + encodeURIComponent(z.toISOString()); })()`);
// the header's lines: its own boxes (and the bar's) grouped by their top
const READ = `(() => { const h = document.querySelector('header'), t = document.getElementById('tree'), r0 = document.querySelector('#tree .tree-root');
  const top = [...h.querySelectorAll(':scope > *, #bar > *')].filter(e => { const r = e.getBoundingClientRect(), s = getComputedStyle(e); return r.width > 0 && r.height > 0 && s.display !== 'none' && e.id !== 'bar'; })
    .map(e => Math.round(e.getBoundingClientRect().top)).sort((a, b) => a - b);
  let lines = 0, last = -99; for (const y of top) { if (y - last > 6) lines++; last = y; }
  const hb = h.getBoundingClientRect(), tb = t.getBoundingClientRect(), rb = r0 ? r0.getBoundingClientRect() : null;
  const range = [...h.querySelectorAll('button, select')].map(e => e.textContent.replace(/\\s+/g, ' ').trim()).find(x => /^Range:/.test(x)) ?? '';
  const who = [...h.querySelectorAll('button, a, span')].map(e => e.textContent.trim()).filter(x => /^Sign out$/i.test(x)).length;
  return { lines, headerBottom: Math.round(hb.bottom), treeTop: Math.round(tb.top), treeBottom: Math.round(tb.bottom), firstRowTop: rb ? Math.round(rb.top) : null,
    innerHeight, scrollY: Math.round(scrollY), range, signOut: who }; })()`;
// ---- S1: the tree under the header, signed in, the long range label, the page scrolled
for (const th of ['light', 'dark']) {
  await theme(th); await size(1366, 768);
  const drawn = await open(`#/?${longRange}`);
  await ev(`window.scrollTo(0, document.documentElement.scrollHeight)`); await sleep(500);
  const g = await ev(READ);
  await shot(`shell-tree-under-header-${th}-1366x768`);
  const name = `S1 the tree under the header, signed in, the range '${g.range}', the page scrolled (1366 x 768, ${th})`;
  if (!drawn || g.signOut < 1) { notProven(name, { drawn, ...g, why: 'the page did not draw signed in' }); continue; }
  if (g.lines < 3 || g.scrollY < 1) { notProven(name, { ...g, why: g.lines < 3 ? 'the header holds fewer than three lines: the case is not made' : 'the page did not scroll' }); continue; }
  row(name, g.firstRowTop != null && g.treeTop >= g.headerBottom - 0.5 && g.firstRowTop >= g.headerBottom - 0.5 && g.treeBottom <= g.innerHeight + 0.5, g);
}
// ---- S1b: the header grows while the page is scrolled: at 1600 x 900 under the default range, scrolled, then the long
// range applied; where that does not grow it (the bar may hold both labels on its lines), the window narrowed to 1100,
// still scrolled - either way the header's height changes under a scrolled page
{
  await theme('light'); await size(1600, 900);
  await open('#/');
  await ev(`window.scrollTo(0, document.documentElement.scrollHeight)`); await sleep(500);
  const g1 = await ev(READ);
  await ev(`(() => { location.hash = '#/?' + ${JSON.stringify(longRange)}; return true; })()`); await settle();
  await ev(`window.scrollTo(0, document.documentElement.scrollHeight)`); await sleep(700);
  let g2 = await ev(READ), how = 'the long range applied';
  if (!(g2.headerBottom > g1.headerBottom)) {
    await size(1100, 900); await sleep(700);
    await ev(`window.scrollTo(0, document.documentElement.scrollHeight)`); await sleep(500);
    g2 = await ev(READ); how = 'the long range, then the window narrowed to 1100';
  }
  await shot('shell-tree-under-grown-header-light');
  const name = `S1b the tree under the header after it grew with the page scrolled (${how}: ${g1.lines} lines, then ${g2.lines})`;
  if (!(g2.headerBottom > g1.headerBottom) || g2.scrollY < 1) notProven(name, { before: g1, after: g2, why: 'the header did not grow, or the page did not scroll' });
  else row(name, g2.firstRowTop != null && g2.treeTop >= g2.headerBottom - 0.5 && g2.firstRowTop >= g2.headerBottom - 0.5 && g2.treeBottom <= g2.innerHeight + 0.5, { before: g1, after: g2 });
}
await theme('light');
// ---- S2 and S3, at two window sizes
for (const [w, h] of [[1280, 800], [1600, 900]]) {
  await size(w, h);
  await open('#/');
  // S3: the placeholder's words measured in the box's own font against the room inside its padding
  const p = await ev(`(() => { const i = document.querySelector('#tree .tree-top input'); if (!i) return null; const s = getComputedStyle(i);
    const c = document.createElement('canvas').getContext('2d'); c.font = s.font;
    const room = i.clientWidth - parseFloat(s.paddingLeft) - parseFloat(s.paddingRight);
    return { placeholder: i.placeholder, text: Math.ceil(c.measureText(i.placeholder).width), room: Math.floor(room), font: s.font }; })()`);
  await shot(`shell-search-box-${w}x${h}`);
  row(`S3 the tree's search box shows its placeholder whole (${w} x ${h})`, !!p && p.text <= p.room, p);
  // S4: the box's accessible name (its aria-label, which names an input before its placeholder or title) starts with the
  // words the box shows
  if (w === 1280) {
    const n = await ev(`(() => { const i = document.querySelector('#tree .tree-top input'); if (!i) return null; const norm = s => String(s ?? '').replace(/\\s+/g, ' ').trim().toLowerCase();
      const name = i.getAttribute('aria-label') ?? (i.labels?.[0]?.textContent ?? '') ?? ''; return { name, placeholder: i.placeholder, title: i.title, starts: norm(name).startsWith(norm(i.placeholder)) }; })()`);
    row(`S4 the tree's search box: its accessible name starts with the words it shows`, !!n && !!n.placeholder && n.starts, n);
  }
  // S2: the tree hidden by its own control
  await ev(`document.querySelector('#tree .tree-hide')?.click()`); await sleep(600);
  const c = await ev(`(() => { const t = document.getElementById('tree'), c = document.getElementById('content'), r = c.getBoundingClientRect();
    return { treeShown: getComputedStyle(t).display !== 'none', contentLeft: Math.round(r.left), contentWidth: Math.round(r.width), windowWidth: document.documentElement.clientWidth }; })()`);
  await shot(`shell-tree-hidden-${w}x${h}`);
  row(`S2 the tree hidden: the content as wide as the window (${w} x ${h})`, !c.treeShown && Math.abs(c.contentLeft) <= 1 && Math.abs(c.contentWidth - c.windowWidth) <= 1, c);
  await ev(`document.getElementById('show-tree')?.click()`); await sleep(400);
}
console.log(`shell-layout: ${ok} ok, ${fail} FAIL, ${np} NOT PROVEN`);
ws.close();
process.exit(fail ? 1 : 0);
