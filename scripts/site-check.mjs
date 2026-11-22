// The site's browser check (proof-site.sh): every page of docs/ (pgvigil.com) at 1440 and 390 px wide in the light and
// the dark scheme. Per render: the scheme taken (the page's background is the scheme's), no sideways scroll, the header
// still at the top of the window after a scroll down, the phone menu shown and the wide links hidden at 390 (the reverse
// at 1440), at 390 the menu opened (its six links shown, axe run with it open), every image loaded, and axe-core's WCAG
// 2.1 A / AA rules plus heading-order, page-has-heading-one, landmark-one-main and landmark-unique with 0 violation nodes;
// a full-page PNG per render. A layout line per render: at 1440 the prose starts at the h1's left edge and no paragraph
// or list item is wider than the text column; a grid's last card ends at the grid's right edge; a section's paragraphs
// and list items, a row's text and the steps in the ink colour; no filled button in the header; no style attribute; both
// colour schemes declared. A page line per page: the two icons linked and served; a page with og:image gives its size,
// its alt and the twitter card; the service install's two blocks each under its own heading; the jobs picture's row in
// jobs words alone. Then the icons are the app's own bytes, the sitemap lists every page once with a lastmod on or after
// the day the page last changed (git, or the file PGVIGIL_SITE_DATES names: '<page> <yyyy-mm-dd>' per line), every link
// of every page answers 200 (a page of the site by the local server, an outside one by a GET that follows redirects,
// 20 s at most), and a link's #anchor exists on its page (GitHub's 'user-content-' ids; '#readme' is the repository
// page's own README box and is not checked); an outside 429 prints n/a.
//   node scripts/site-check.mjs <cdp port> <base url/> <path to axe.min.js> <out dir> [--no-net]
// Prints one 'ok' or 'FAIL' line per render, per layout, per page, for the icons, the sitemap and per link; exit 1 when
// any FAIL.
const [port, base, axePath, out, ...flags] = process.argv.slice(2);
const fs = await import('node:fs');
const noNet = flags.includes('--no-net');
const TEXT = 720;   // the text column's width in px (site.css .text)
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
  const want = scheme === 'dark' ? 'rgb(15, 18, 22)' : 'rgb(255, 255, 255)';
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
  // at phone width the menu is opened first, so its links are seen and scanned
  const menu = width < 600 ? await ev(`(async () => { const d = document.querySelector('details.menu'); d.querySelector('summary').click(); await new Promise(r => setTimeout(r, 150));
    const links = [...d.querySelectorAll('nav a')].filter(a => a.getBoundingClientRect().height > 0).length; return { open: d.open, links }; })()`) : null;
  await ev(axeSrc);
  // two scans one after the other (axe runs one at a time): the WCAG rules, then the heading and landmark rules
  const ax = JSON.parse(await ev(`(async () => {
      const a = await axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] });
      const b = await axe.run(document, { runOnly: { type: 'rule', values: ['heading-order', 'page-has-heading-one', 'landmark-one-main', 'landmark-unique'] }, resultTypes: ['violations'] });
      return JSON.stringify([...a.violations, ...b.violations].map(v => ({ id: v.id, n: v.nodes.length, first: v.nodes[0]?.target?.join(' ') })));
    })()`));
  const nodes = ax.reduce((s, v) => s + v.n, 0);
  if (menu) await ev(`document.querySelector('details.menu').open = false; 'ok'`);
  await send('Emulation.setDeviceMetricsOverride', { width, height: Math.min(r.h, 9000), deviceScaleFactor: 1, mobile: width < 600 });
  await sleep(150);
  const shot = await send('Page.captureScreenshot', { format: 'png' });
  fs.writeFileSync(`${out}/${name}.png`, Buffer.from(shot.result.data, 'base64'));
  const navOk = width < 600 ? (r.menu && !r.links && !!menu && menu.open && menu.links === 6) : (r.links && !r.menu);
  say(r.bg === want && r.sideways <= 0 && r.stuck && navOk && !r.broken.length && nodes === 0,
    `${name}: '${r.title}', body ${r.bg} (${r.bg === want ? 'the scheme' : 'wanted ' + want}), sideways ${r.sideways} px, header held ${r.stuck}, nav ${width < 600 ? `menu opened ${menu?.open} with ${menu?.links} links` : 'links'} ${navOk}, images broken ${r.broken.length ? r.broken.join(' ') : 0}, axe ${nodes} node(s)${nodes ? ' ' + JSON.stringify(ax) : ''}, page ${r.h} px`);
  for (const h of r.hrefs) if (!links.has(h)) links.set(h, page);

  // the layout: at 1440 the prose and the section headings start at the h1's left edge and no paragraph or list item is
  // wider than the text column; a grid's last card ends at the grid's right edge (no card left alone in a row); a
  // section's paragraphs and list items, a row's text and the steps in the ink colour (the grey is the captions');
  // no filled button in the header, which keeps its Download link; no style attribute; both colour schemes declared
  const wide = width >= 1200;
  const lay = await ev(`(() => {
    const box = e => e.getBoundingClientRect(), ink = getComputedStyle(document.body).color;
    const label = e => e.tagName.toLowerCase() + (e.className ? '.' + String(e.className).trim().replace(/\\s+/g, '.') : '');
    const left = e => { const s = getComputedStyle(e); return box(e).left + parseFloat(s.paddingLeft) + parseFloat(s.borderLeftWidth); };
    const h1 = document.querySelector('main h1'), x0 = h1 ? box(h1).left : NaN;
    const offset = ${wide} ? [...document.querySelectorAll('main .text, main h2')].filter(e => !e.closest('.grid2, .row'))
      .filter(e => !(Math.abs(left(e) - x0) <= 1)).map(e => label(e) + ' at ' + Math.round(left(e)) + ' (the h1 at ' + Math.round(x0) + ')') : [];
    const tooWide = ${wide} ? [...document.querySelectorAll('main p, main li')].filter(e => box(e).width > ${TEXT} + 1)
      .map(e => label(e) + ' "' + e.textContent.trim().slice(0, 24) + '" ' + Math.round(box(e).width) + ' px') : [];
    const alone = [...document.querySelectorAll('main .grid2')].filter(g => g.lastElementChild && Math.abs(box(g.lastElementChild).right - box(g).right) > 1)
      .map(g => 'its last card ' + Math.round(box(g.lastElementChild).width) + ' of ' + Math.round(box(g).width) + ' px');
    const grey = [...document.querySelectorAll('main section.plain p, main section.plain li, main .row p, main ol.steps li')]
      .filter(e => getComputedStyle(e).color !== ink).length;
    const filled = [...document.querySelectorAll('header.top .btn')].filter(b => getComputedStyle(b).backgroundColor !== 'rgba(0, 0, 0, 0)').length;
    return { offset, tooWide, alone, grey, filled, download: !!document.querySelector('header.top .links a[href$="/releases/latest"]'),
             styled: document.querySelectorAll('[style]').length, scheme: getComputedStyle(document.documentElement).colorScheme };
  })()`);
  const list = (a, at390) => !wide && at390 ? 'not read at 390' : a.length ? 'NO ' + a.join(', ') : 'yes';
  say(!lay.offset.length && !lay.tooWide.length && !lay.alone.length && !lay.grey && !lay.filled && lay.download && !lay.styled && lay.scheme === 'light dark',
    `${name} layout: prose at the h1's left ${list(lay.offset, true)}; within the text width ${list(lay.tooWide, true)}; grid rows full ${list(lay.alone)}; prose in the ink colour ${lay.grey ? 'NO ' + lay.grey + ' in grey' : 'yes'}; header buttons filled ${lay.filled}${lay.download ? '' : ', no Download'}; style attributes ${lay.styled}; color-scheme '${lay.scheme}'`);

  // the page, once: the two icons linked and served; a page with og:image gives its size (the picture's own), its alt and
  // the twitter card; the service install's two blocks, each under its own heading; the jobs picture's row in jobs words
  if (width === 1440 && scheme === 'light') {
    const c = await ev(`(async () => {
      const q = s => document.querySelector(s), qa = s => [...document.querySelectorAll(s)];
      const served = async (sel, h) => { if (!q(sel)) return 'not linked'; try { const r = await fetch(h); return r.status + ' ' + (r.headers.get('content-type') || ''); } catch (e) { return String(e).slice(0, 40); } };
      const icons = { ico: await served('link[rel="icon"][href="favicon.ico"]', 'favicon.ico'), touch: await served('link[rel="apple-touch-icon"][href="img/icon-180.png"]', 'img/icon-180.png') };
      const meta = p => (q('meta[property="' + p + '"]') || q('meta[name="' + p + '"]'))?.getAttribute('content') ?? null;
      const og = meta('og:image') && { img: meta('og:image'), w: meta('og:image:width'), h: meta('og:image:height'), alt: meta('og:image:alt'), card: meta('twitter:card') };
      const svc = qa('main h2').find(e => e.textContent.trim() === 'Install as a service')?.closest('section');
      const blocks = svc ? [...svc.querySelectorAll('pre')].map(p => (p.previousElementSibling?.tagName === 'H3' ? p.previousElementSibling.textContent.trim() : '(no heading)') + ': ' +
        [/install\\.sh/.test(p.textContent) && 'install.sh', /install\\.ps1/.test(p.textContent) && 'install.ps1'].filter(Boolean).join(' and ')) : null;
      const jobs = qa('main .row').find(r => r.querySelector('img[src="img/jobs.png"]'))?.querySelector('.row-text');
      return { icons, og, blocks, jobs: jobs ? jobs.textContent.replace(/\\s+/g, ' ').trim() : null };
    })()`);
    const iconOk = /^200 image\//.test(c.icons.ico) && /^200 image\//.test(c.icons.touch);
    let ogSay = 'no og:image', ogOk = true;
    if (c.og) {
      let w = 0, h = 0;
      try { const png = fs.readFileSync('docs' + new URL(c.og.img).pathname); w = png.readUInt32BE(16); h = png.readUInt32BE(20); } catch { /* the picture is not in docs/ */ }
      ogOk = !!w && c.og.w === String(w) && c.og.h === String(h) && !!c.og.alt && c.og.card === 'summary_large_image';
      ogSay = `og:image ${c.og.img} (${w} x ${h}) width ${c.og.w} height ${c.og.h}, alt ${c.og.alt ? 'given' : 'none'}, twitter:card ${c.og.card}`;
    }
    const blocksOk = !c.blocks || (c.blocks.length === 2 && /^Linux.*: install\.sh$/.test(c.blocks[0]) && /^Windows.*: install\.ps1$/.test(c.blocks[1]));
    const jobsOk = c.jobs === null || !/backup|storage|volume/i.test(c.jobs);
    say(iconOk && ogOk && blocksOk && jobsOk, `${page} page: icons favicon.ico ${c.icons.ico}, img/icon-180.png ${c.icons.touch}; ${ogSay}` +
      (c.blocks ? `; the service install's blocks ${c.blocks.length}: ${c.blocks.join(' | ')}` : '') + (c.jobs !== null ? `; the jobs picture's row: "${c.jobs.slice(0, 80)}"${jobsOk ? '' : ' names more than jobs'}` : ''));
  }
}
ws.close();

// the site's icons are the app's own files, byte for byte
const same = (a, b) => { try { return fs.readFileSync(a).equals(fs.readFileSync(b)); } catch { return false; } };
const icoSame = same('docs/favicon.ico', 'internal/web/dist/favicon.ico'), touchSame = same('docs/img/icon-180.png', 'internal/web/dist/icon-180.png');
say(icoSame && touchSame, `icons: docs/favicon.ico ${icoSame ? 'is' : 'is NOT'} internal/web/dist/favicon.ico, docs/img/icon-180.png ${touchSame ? 'is' : 'is NOT'} internal/web/dist/icon-180.png`);

// the sitemap: every page once, each lastmod on or after the day its page last changed - git's last commit of the page
// (today for a page changed and not committed), or, where the tree carries no history, the file PGVIGIL_SITE_DATES names
{
  const { execFileSync } = await import('node:child_process');
  const git = (...a) => execFileSync('git', a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  const given = process.env.PGVIGIL_SITE_DATES ? Object.fromEntries(fs.readFileSync(process.env.PGVIGIL_SITE_DATES, 'utf8').split('\n')
    .map(l => l.trim().split(/\s+/)).filter(f => f.length === 2)) : {};
  const changed = p => { try { return git('status', '--porcelain', '--', `docs/${p}`) ? new Date().toLocaleDateString('en-CA') : git('log', '-1', '--format=%cs', '--', `docs/${p}`) || given[p] || null; } catch { return given[p] || null; } };
  const sm = [...fs.readFileSync('docs/sitemap.xml', 'utf8').matchAll(/<loc>([^<]+)<\/loc>\s*<lastmod>([^<]+)<\/lastmod>/g)]
    .map(m => ({ page: new URL(m[1]).pathname.slice(1) || 'index.html', mod: m[2] }));
  const listed = pages.map(p => [p, sm.filter(s => s.page === p).length]), extra = sm.filter(s => !pages.includes(s.page)).map(s => s.page);
  const dated = sm.filter(s => pages.includes(s.page)).map(s => ({ ...s, changed: changed(s.page) }));
  const undated = dated.filter(d => !d.changed).map(d => d.page);
  say(listed.every(([, n]) => n === 1) && !extra.length && dated.every(d => !d.changed || d.mod >= d.changed),
    `sitemap: ${dated.map(d => `${d.page} ${d.mod}${!d.changed ? '' : d.mod >= d.changed ? '' : ' (the page changed ' + d.changed + ')'}`).join(', ')}` +
    (listed.some(([, n]) => n !== 1) ? `; listed ${listed.filter(([, n]) => n !== 1).map(([p, n]) => p + ' ' + n + ' times').join(', ')}` : '') + (extra.length ? `; no such page ${extra.join(' ')}` : ''));
  if (undated.length) console.log(`n/a  sitemap: the day ${undated.join(' ')} last changed (no git history here and no PGVIGIL_SITE_DATES line)`);
}

for (const [h, page] of links) {
  if (h.startsWith('#')) { say(h === '#main', `link ${h} on ${page}: only the skip link may jump inside a page`); continue; }
  // a mail link is not fetched: its address is checked for its shape
  if (h.startsWith('mailto:')) { say(/^mailto:[^@\s]+@[^@\s]+\.[a-z]{2,}$/i.test(h), `link ${h} on ${page}: a mail address`); continue; }
  const abs = /^https?:/.test(h) ? h : new URL(h, base).href;
  if (/^https?:/.test(h) && noNet) { console.log(`n/a  link ${h} (--no-net)`); continue; }
  let st = 0, body = '';
  const frag = abs.includes('#') ? abs.split('#')[1] : '';
  try {
    const res = await fetch(abs.split('#')[0], { redirect: 'follow', headers: { 'user-agent': 'site-check' }, signal: AbortSignal.timeout(20000) });
    st = res.status; if (frag) body = await res.text();
  } catch (e) { st = String(e.message).slice(0, 60); }
  if (st === 429) { console.log(`n/a  link ${h} on ${page}: 429, the site refused a script for now`); continue; }
  const anchored = !frag || frag === 'readme' || body.includes(`id="user-content-${frag}"`) || body.includes(`"user-content-${frag}"`) || body.includes(`id="${frag}"`);
  say(st === 200 && anchored, `link ${h} on ${page}: ${st}${frag && frag !== 'readme' ? `, #${frag} ${anchored ? 'found' : 'NOT on the page'}` : ''}`);
}
if (failed) { console.log(`FAIL ${failed} check(s)`); process.exit(1); }
console.log(`site: ${pages.length} pages x 2 widths x 2 schemes as expected, ${links.size} links answer`);
