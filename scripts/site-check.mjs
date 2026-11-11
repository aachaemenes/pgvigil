// The site's browser check (proof-site.sh): every page of docs/ (pgvigil.com) at 1440 and 390 px wide in the light and
// the dark scheme. Per render: no sideways scroll, the header still at the top of the window after a scroll down, the
// phone menu shown and the wide links hidden at 390 (the reverse at 1440), every image loaded, and axe-core's WCAG 2.1
// A / AA rules with 0 violation nodes; a full-page PNG per render. Then every link of every page answers (a page of
// the site by the local server, an outside one by a GET that follows redirects).
//   node scripts/site-check.mjs <cdp port> <base url/> <path to axe.min.js> <out dir> [--no-net]
// Prints one 'ok' or 'FAIL' line per render and per link; exit 1 when any FAIL.
const [port, base, axePath, out, ...flags] = process.argv.slice(2);
const fs = await import('node:fs');
const noNet = flags.includes('--no-net');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(); const loaded = [];
ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } else if (d.method === 'Page.loadEventFired') loaded.push(1); };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => {
  const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
};
let failed = 0;
const say = (okay, what) => { console.log(`${okay ? 'ok  ' : 'FAIL'} ${what}`); if (!okay) failed++; };
await send('Page.enable');
fs.mkdirSync(out, { recursive: true });

const pages = fs.readdirSync('docs').filter(f => f.endsWith('.html')).sort();
const links = new Map();   // href -> the first page that names it
for (const page of pages) for (const width of [1440, 390]) for (const scheme of ['light', 'dark']) {
  const name = `${page.replace('.html', '')}-${width}-${scheme}`;
  await send('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: width < 600 });
  await send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: scheme }] });
  loaded.length = 0;
  await send('Page.navigate', { url: base + page });
  for (let i = 0; i < 40 && !loaded.length; i++) await sleep(100);
  await ev(`Promise.all([...document.images].map(i => i.loading === 'lazy' ? (i.loading = 'eager', i.decode().catch(() => 0)) : i.decode().catch(() => 0)))`);
  await sleep(200);
  const r = await ev(`(async () => {
    const de = document.documentElement, head = document.querySelector('header.top');
    const sideways = de.scrollWidth - innerWidth;
    window.scrollTo(0, Math.min(1200, de.scrollHeight)); await new Promise(r => setTimeout(r, 150));
    const stuck = de.scrollHeight <= innerHeight + 10 || Math.round(head.getBoundingClientRect().top) === 0;
    window.scrollTo(0, 0);
    const shown = el => !!el && getComputedStyle(el).display !== 'none';
    const broken = [...document.images].filter(i => !i.complete || i.naturalWidth === 0).map(i => i.getAttribute('src'));
    const hrefs = [...document.querySelectorAll('a[href]')].map(a => a.getAttribute('href'));
    return { sideways, stuck, links: shown(document.querySelector('.links')), menu: shown(document.querySelector('.menu')), broken, hrefs,
             bg: getComputedStyle(document.body).backgroundColor, h: de.scrollHeight, title: document.title };
  })()`);
  await ev(axeSrc);
  const ax = JSON.parse(await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] })
    .then(r => JSON.stringify(r.violations.map(v => ({ id: v.id, n: v.nodes.length, first: v.nodes[0]?.target?.join(' ') }))))`));
  const nodes = ax.reduce((s, v) => s + v.n, 0);
  await send('Emulation.setDeviceMetricsOverride', { width, height: Math.min(r.h, 9000), deviceScaleFactor: 1, mobile: width < 600 });
  await sleep(150);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${out}/${name}.png`, Buffer.from(shot.result.data, 'base64'));
  const navOk = width < 600 ? (r.menu && !r.links) : (r.links && !r.menu);
  say(r.sideways <= 0 && r.stuck && navOk && !r.broken.length && nodes === 0,
    `${name}: '${r.title}', sideways ${r.sideways} px, header held ${r.stuck}, nav ${width < 600 ? 'menu' : 'links'} ${navOk}, images broken ${r.broken.length ? r.broken.join(' ') : 0}, axe ${nodes} node(s)${nodes ? ' ' + JSON.stringify(ax) : ''}, page ${r.h} px, body ${r.bg}`);
  for (const h of r.hrefs) if (!links.has(h)) links.set(h, page);
}
ws.close();

for (const [h, page] of links) {
  if (h.startsWith('#')) { say(h === '#main', `link ${h} on ${page}: only the skip link may jump inside a page`); continue; }
  const abs = /^https?:/.test(h) ? h : new URL(h, base).href;
  if (/^https?:/.test(h) && noNet) { console.log(`n/a  link ${h} (--no-net)`); continue; }
  let st = 0;
  try { st = (await fetch(abs.split('#')[0], { redirect: 'follow', headers: { 'user-agent': 'site-check' } })).status; } catch (e) { st = String(e.message).slice(0, 60); }
  say(st === 200, `link ${h} on ${page}: ${st}`);
}
if (failed) { console.log(`FAIL ${failed} check(s)`); process.exit(1); }
console.log(`site: ${pages.length} pages x 2 widths x 2 schemes as expected, ${links.size} links answer`);
