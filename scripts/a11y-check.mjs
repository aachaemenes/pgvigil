// Accessibility check of the web UI with axe-core over a headless Chromium (CDP): every root tab and every
// tab of two PostgreSQL instances and of two SQL Server instances, in the light and the dark theme, against the WCAG 2.1 A and AA rules (Section 508
// points at WCAG 2.0 AA; 2.1 AA covers it). Usage:
//   node scripts/a11y-check.mjs <cdp port> <base url/> <path to axe.min.js> [<json out>]
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil demo ... -serve -listen 127.0.0.1:<port>
// Prints one line per page checked and a table of the violations (rule, impact, nodes, pages); the JSON
// out holds every violation with its nodes. The exit code is 0 when every page rendered and axe ran on
// it; the caller judges the violation count (scripts/proof-a11y.sh).
const [port, U, axePath, outPath] = process.argv.slice(2);
const fs = await import('node:fs');
const axeSrc = fs.readFileSync(axePath, 'utf8');
const inst = await (await fetch(U + 'api/instances')).json();
const rows = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const pick = (pred) => rows.find(pred);
const onprem = pick(r => r.platform === 'onprem') ?? rows[0];
const cloud = pick(r => r.platform === 'rds') ?? pick(r => r.platform === 'aurora') ?? rows[rows.length - 1];
// an Aurora instance with Performance Insights and Serverless v2 rows in the demo (the Load tab and the Capacity section render
// their charts there, not the PI-off paragraph), and the instance with the compare regressions (the Compare drill page)
const aurora = pick(r => String(r.name).endsWith('aurora-reporting01')) ?? cloud;
const regress = pick(r => String(r.name).endsWith('rds-orders01')) ?? cloud;
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
// the browser's end said in words (box runs of 2026-11-13 lost the socket after 364 and 518 pages with no reason printed):
// the socket's close and a crash of the page's renderer, each with the pages walked so far
let walked = 0;
ws.addEventListener('close', e => { console.log(`the browser's socket closed (code ${e.code}) after ${walked} page(s)`); process.exitCode = 3; });
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (d.method === 'Inspector.targetCrashed' || d.method === 'Inspector.detached') console.log(`the page's renderer: ${d.method} ${JSON.stringify(d.params ?? {})} after ${walked} page(s)`); });
await cmd('Inspector.enable'); await cmd('Performance.enable');
// every 50 pages the page's own weight: a long walk in ONE tab is how a DBA keeps the UI open all day
const weigh = async () => {
  const m = Object.fromEntries(((await cmd('Performance.getMetrics')).result?.metrics ?? []).map(x => [x.name, x.value]));
  console.log(`weight after ${walked} page(s): heap ${(m.JSHeapUsedSize / 1048576).toFixed(1)} of ${(m.JSHeapTotalSize / 1048576).toFixed(1)} MB, ${m.Nodes} DOM nodes, ${m.JSEventListeners} listeners, ${m.Documents} documents`);
};
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async (ms = 12000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    // rendered = the shell replaced its "Loading..." paragraph; an honest empty state ("No rows yet") is a rendered page too
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty'); return !(e && /^Loading/.test(e.textContent)) && m.children.length > 0; })()`);
    if (ok) {
      // an instance page's header (task 177 D29) follows the page when its read ends: waited for, up to 5 s
      for (let i = 0; i < 50 && await ev(`/[?&]i=/.test(location.hash) && !document.querySelector('main .inst-header')`); i++) await sleep(100);
      await sleep(300); return true;
    }
    await sleep(150);
  }
  return false;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
const tabsOf = async (hash) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(300); await settled();
  // every page of the scope: the strip shows one group of tabs, its data-all lists them all
  return await ev(`(() => { const t = document.querySelector('#tabs'); return t.dataset.all ? JSON.parse(t.dataset.all) : [...t.querySelectorAll('a')].map(a => a.getAttribute('href')); })()`);
};
const rootTabs = await tabsOf('#/summary');
const instTabs = await tabsOf(`#/summary?i=${onprem.instance_id}`);
const pages = [...rootTabs];
for (const t of instTabs) { pages.push(t.replace(/i=\d+/, `i=${onprem.instance_id}`)); pages.push(t.replace(/i=\d+/, `i=${cloud.instance_id}`)); }
for (const t of instTabs) if (/#\/(load|host|summary)\?/.test(t)) pages.push(t.replace(/i=\d+/, `i=${aurora.instance_id}`));
// a SQL Server instance has its own tabs: every one of them on the demo's primary (the pair's findings) and on the
// managed instance (no availability group, no Agent jobs: the empty states)
const sqlPrimary = pick(r => r.engine === 'sqlserver' && String(r.name).endsWith('sql01')) ?? pick(r => r.engine === 'sqlserver');
const sqlManaged = pick(r => r.engine === 'sqlserver' && String(r.name).endsWith('sql03') && r !== sqlPrimary);
let sqlPages = 0;
for (const x of [sqlPrimary, sqlManaged]) {
  if (!x) continue;
  for (const t of await tabsOf(`#/summary?i=${x.instance_id}`)) { pages.push(t.replace(/i=\d+/, `i=${x.instance_id}`)); sqlPages++; }
}
console.log(`SQL Server pages in the check: ${sqlPages}`);
// the drill pages the tab strip does not list: the Compare page (under Statements) on the instance with regressions
pages.push(`#/compare?i=${regress.instance_id}&w=7d`);
// the DBADash door's instance page (the demo's repository and its second instance)
pages.push('#/dbadash?dr=dbadash-demo&di=2');
// the Memory tab on the instance with pg_buffercache and temp spills, the Pooler tab on the one with a PgBouncer (hidden elsewhere)
const erp = pick(r => String(r.name).endsWith('onprem-erp01')) ?? onprem;
const crm = pick(r => String(r.name).endsWith('aurora-crm01')) ?? cloud;
pages.push(`#/memory?i=${erp.instance_id}`);
pages.push(`#/pooler?i=${crm.instance_id}`);
// the pooler traced (task 128): the Pooler tab with clients, servers and a trace, and Running queries' pooler marks
const hr = pick(r => String(r.name).endsWith('onprem-hr01')) ?? onprem;
pages.push(`#/pooler?i=${hr.instance_id}`, `#/activity?i=${hr.instance_id}`);
const all = []; let failed = 0; const perRule = new Map();
// every control that is off and shown has a visible, non-empty reason as its description (aria-describedby): EVERY
// page fails without it, the instance header's controls with their page (task B7 DONE-2; the rule began on the three
// pages of wave 4 - Community tools, Custom reports, Report mail - with every other page listed for task B2)
const offCheck = () => ev(`(() => {
  const vis = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
  const ctl = [...document.querySelectorAll('main button, main input, main select, main textarea, dialog button')]
    .filter(e => (e.disabled || e.getAttribute('aria-disabled') === 'true') && vis(e));
  // a reason is words: a badge word alone ('off', 'not checked', ...) is none, and so is a sentence that ends at its
  // colon with nothing after it ('Update is off:') - the same rule as proof-demodoor's R12
  const said = x => { const t = x.textContent.replace(/^\\s*(off|not checked|demo|note|on|declined)\\b/i, '').trim(); return t.length > 0 && !/:\\s*\\.?$/.test(t); };
  const bad = ctl.filter(e => !(e.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean).some(i => { const x = document.getElementById(i); return vis(x) && said(x); }));
  const name = e => (e.tagName + ' ' + (e.textContent || e.getAttribute('aria-label') || '').trim()).slice(0, 60);
  // the instance header (instheader.ts) sits above every instance page: its controls are its own page's, listed apart
  return { own: bad.filter(e => !e.closest('.inst-header')).map(name), header: bad.filter(e => e.closest('.inst-header')).map(e => 'header ' + name(e)) };
})()`);
let offFail = 0; let selftest = null;
// the status style is remembered per origin too: every page in the solid style (the default), and the pages that carry
// status cells again in the quiet one
pages.push('#/summary|range');   // the Summary once more with the range panel open, so axe scans the panel too
// a Diff with both sides picked (the walk above opens only its empty form): two instances, then one instance at two times
pages.push(`#/diff?m=i&a=${onprem.instance_id}&b=${cloud.instance_id}`, `#/diff?m=t&a=${onprem.instance_id}&ta=${encodeURIComponent(new Date(Date.now() - 86400e3).toISOString())}`);
const statusPages = pages.filter(h => /^#\/(summary|perfsummary|dbadash|alerts)\b/.test(h));
for (const [style, list] of [['solid', pages], ['quiet', statusPages]])
for (const theme of ['light', 'dark']) {
  // the theme is remembered per origin: set it on a page of the UI (not on about:blank), and pin the media query too
  await cmd('Page.navigate', { url: U + '#/summary' }); await sleep(300); await settled();
  await ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); localStorage.setItem('pgvigil.status', ${JSON.stringify(style)}); 'ok'`);
  await cmd('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
  for (const entry of list) {
    const [hash, open] = entry.split('|');   // '<page>|range' = that page with the range panel open
    await cmd('Page.navigate', { url: U + hash }); await sleep(250);
    const ok = await settled();
    if (!ok) { failed++; console.log(`FAIL render ${style} ${theme} ${entry}`); continue; }
    // a Diff address with its picks renders its result, not an error box: the 'The two sides' heading appears within 8 s
    // (the walk's bare Diff page is the empty form, with no result by design)
    if (/^#\/diff\?(.*&)?a=/.test(hash)) {
      const drawn = await ev(`(async () => { for (let i = 0; i < 32; i++) { if ([...document.querySelectorAll('[aria-label="Diff result"] h3')].some(h => h.textContent === 'The two sides')) return true; await new Promise(r => setTimeout(r, 250)); } return false; })()`, true);
      if (!drawn) { failed++; console.log(`FAIL render ${style} ${theme} ${entry}: no Diff result ('The two sides')`); continue; }
    }
    if (open === 'range') {
      // opened only when it is closed (a second click would close it)
      const shown = await ev(`(async () => { if (!document.querySelector('#bar [role="dialog"]')) document.querySelector('#bar [aria-haspopup="dialog"]')?.click(); await new Promise(r => setTimeout(r, 300)); return !!document.querySelector('#bar [role="dialog"]'); })()`, true);
      if (!shown) { failed++; console.log(`FAIL render ${style} ${theme} ${entry}: the range panel did not open`); continue; }
    }
    const offRead = await offCheck();
    if (selftest === null) {
      // five off buttons without a reason, each a way to miss one: no description, a description that names no element,
      // a hidden one, one that holds only a badge word, one that ends at its colon
      await ev(`(() => { const m = document.querySelector('main');
        const mk = (t, d) => { const b = document.createElement('button'); b.textContent = 'planted ' + t; b.setAttribute('aria-disabled', 'true'); if (d) b.setAttribute('aria-describedby', d); m.append(b); };
        const span = (id, text, hidden) => { const s = document.createElement('span'); s.id = id; s.textContent = text; s.hidden = hidden; m.append(s); };
        span('planted-hidden', 'a reason', true); span('planted-word', 'off', false); span('planted-colon', 'Update is off:', false);
        mk('none'); mk('missing', 'planted-missing'); mk('hidden', 'planted-hidden'); mk('word', 'planted-word'); mk('colon', 'planted-colon'); return 1; })()`);
      selftest = (await offCheck()).own.length - offRead.own.length;
      await ev(`(() => { [...document.querySelectorAll('main button')].filter(b => b.textContent.startsWith('planted ')).forEach(b => b.remove());
        ['planted-hidden', 'planted-word', 'planted-colon'].forEach(i => document.getElementById(i)?.remove()); return 1; })()`);
      console.log(`off-reason self-test: planted off buttons without a reason counted ${selftest} of 5`);
      if (selftest !== 5) failed++;
    }
    const offBad = [...offRead.header, ...offRead.own];
    if (offBad.length) {
      console.log(`off  ${style} ${theme} ${entry}: ${offBad.length} off control(s) without a visible reason: ${offBad.slice(0, 4).join('; ')}`);
      offFail++;
    }
    await cmd('Runtime.evaluate', { expression: axeSrc });
    const res = await ev(`axe.run(document, { runOnly: { type: 'tag', values: ['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa'] }, resultTypes: ['violations'] }).then(r => JSON.stringify({ v: r.violations.map(v => ({ id: v.id, impact: v.impact, help: v.help, nodes: v.nodes.map(n => ({ target: n.target, html: n.html.slice(0, 160), summary: n.failureSummary?.slice(0, 200) })) })), passes: r.passes.length }))`, true);
    const r = JSON.parse(res);
    const n = r.v.reduce((a, v) => a + v.nodes.length, 0);
    console.log(`${n ? 'viol ' : 'ok   '}${style} ${theme} ${entry}: ${r.v.length} rule(s), ${n} node(s), ${r.passes} rules passed`);
    walked++; if (walked % 50 === 0) await weigh();
    for (const v of r.v) {
      all.push({ theme, style, page: entry, ...v });
      const k = perRule.get(v.id) ?? { impact: v.impact, help: v.help, nodes: 0, pages: new Set() };
      k.nodes += v.nodes.length; k.pages.add(style + ' ' + theme + ' ' + entry); perRule.set(v.id, k);
    }
  }
}
console.log('');
console.log('rule | impact | nodes | pages | help');
for (const [rule, k] of [...perRule.entries()].sort((a, b) => b[1].nodes - a[1].nodes)) console.log(`${rule} | ${k.impact} | ${k.nodes} | ${k.pages.size} | ${k.help}`);
console.log(`total: ${perRule.size} rule(s), ${all.reduce((a, v) => a + v.nodes.length, 0)} node(s) over ${pages.length * 2} page renders; ${failed} page(s) failed to render`);
console.log(`off-reason: ${offFail} page render(s) with an off control without its reason (every page is held to it)`);
if (outPath) fs.writeFileSync(outPath, JSON.stringify({ pages, violations: all }, null, 1));
ws.close();
process.exit(failed || offFail ? 1 : 0);
