// VIEWS slice B in the browser (proof-views-b.sh): the View control on the Summary, the Performance Summary and Slow
// Queries - save, load, the default on entering, {None}, the layouts layer, the shared views, the conflict, the time
// range, a shared link, the mail render. Its cases and their expected results: proof-views-b.sh's header.
//   VB_U1 / VB_U1PW (a shared editor), VB_U2 / VB_U2PW (not), VB_TAG (a tag of the demo fleet), VB_MSSQL (a SQL Server
//   instance id), VB_PG (a PostgreSQL instance id, for SHOTS), VB_CASES (space-separated case names; empty = all),
//   VB_SHOTS (a folder: the SHOTS case saves the five pages' pictures there; unset = no SHOTS case)
//   node scripts/views-b-check.mjs <cdp port> <base url/>
// The page contract it checks (the design's B1-B7 and FOLD V1-V7): the View button carries data-view-control and reads
// 'View: <name>' or 'View: None' (+ ' (changed)'); its menu is ui.ts' role=menu of role=menuitem buttons - the page's own
// items, '{None}', each view by name with '(shared)' or '(mine)' and ' - default', the loaded one ticked '✓ ', then
// 'Save', 'Save as...', 'Rename...', 'Delete...' (an off item aria-disabled="true", its reason in its title); the save
// dialog dialog[aria-label="Save view"] holds input[name=name], input[name=default], input[name=visibility] (me |
// everyone), input[name=folder], input[name=range] and a 'Save' button; the lines under the toolbar are p.view-note;
// each grid a view keeps carries data-grid-name.
// Prints one 'ok <case>: ...' line per case, or 'FAIL <case>: ...', and exits 1 when one failed.
const [port, base] = process.argv.slice(2);
const E = process.env, only = (E.VB_CASES ?? '').split(/\s+/).filter(Boolean);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const connect = async wsUrl => {
  const ws = new WebSocket(wsUrl); await new Promise(r => ws.onopen = r);
  let id = 0; const pend = new Map(), reqs = [];
  ws.onmessage = m => {
    const d = JSON.parse(m.data);
    if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); }
    if (d.method === 'Network.requestWillBeSent') reqs.push(d.params.request.url);
  };
  const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
  const ev = async e => {
    const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true, userGesture: true });
    if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
    return r.result?.result?.value;
  };
  await send('Network.enable');
  await send('Emulation.setDeviceMetricsOverride', { width: 1400, height: 900, deviceScaleFactor: 1, mobile: false });
  return { send, ev, reqs, ws };
};
const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const A = await connect(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
let P = A;   // the page the helpers drive
let failed = 0;
const check = (name, okay, detail) => { console.log(`${okay ? 'ok  ' : 'FAIL'} ${name}: ${detail}`); if (!okay) failed++; return okay; };
const ready = `!!document.querySelector('main section, main .grid-box, main table.grid, main .empty-grid') && !document.querySelector('main > p.empty[role=status]')`;
const go = async (h, blank = true) => {
  if (blank) { await P.send('Page.navigate', { url: 'about:blank' }); await sleep(150); }
  await P.send('Page.navigate', { url: base + h });
  for (let i = 0; i < 80; i++) { await sleep(250); if (await P.ev(ready)) break; }
  await sleep(1200);
};
const clickLink = async (sel, text) => {   // a link the page drew: a same-document navigation (no reload)
  const okay = await P.ev(`(() => { const a = [...document.querySelectorAll(${JSON.stringify(sel)})].find(x => x.textContent.trim() === ${JSON.stringify(text)}); if (!a) return false; a.click(); return true; })()`);
  for (let i = 0; i < 60; i++) { await sleep(250); if (await P.ev(ready)) break; }
  await sleep(1200);
  return okay;
};
const hash = () => P.ev('location.hash');
const keys = async () => Object.fromEntries(new URLSearchParams((await hash()).split('?')[1] ?? ''));
const api = (path, body) => P.ev(`fetch(${JSON.stringify(path)}, { method: ${body ? "'POST'" : "'GET'"}, headers: { 'X-Pgvigil': '1', 'Content-Type': 'application/json' }, credentials: 'same-origin'${body ? `, body: ${JSON.stringify(JSON.stringify(body))}` : ''} }).then(async r => ({ code: r.status, body: await r.json().catch(() => null) }))`);
const login = async (u, pw) => { await go('#/about'); await api('/api/logout', {}); const r = await api('/api/login', { username: u, password: pw }); if (r.code !== 200) throw new Error(`login ${u}: ${r.code}`); };
const vcText = () => P.ev(`document.querySelector('[data-view-control]')?.textContent.trim() ?? null`);
const noControl = async name => { const t = await vcText(); if (t === null) { check(name, false, 'no View control (no [data-view-control] on the page)'); return true; } return false; };
const openMenu = async () => { await P.ev(`document.querySelector('[data-view-control]').click(); 'ok'`); await sleep(300); return P.ev(`[...document.querySelectorAll('div.menu[role=menu] [role=menuitem]')].map(b => b.textContent.trim() + (b.getAttribute('aria-disabled') === 'true' ? ' [off: ' + (b.title || '') + ']' : ''))`); };
const pick = async re => {   // opens the menu and clicks the first item matching re; the items seen
  const items = await openMenu();
  const hit = await P.ev(`(() => { const b = [...document.querySelectorAll('div.menu[role=menu] [role=menuitem]')].find(x => new RegExp(${JSON.stringify(re.source)}).test(x.textContent.trim())); if (!b || b.getAttribute('aria-disabled') === 'true') return false; b.click(); return true; })()`);
  for (let i = 0; i < 40; i++) { await sleep(250); if (await P.ev(ready)) break; }
  await sleep(1200);
  return { hit, items };
};
const saveAs = async (name, o = {}) => {
  const { hit } = await pick(/^Save as/);
  if (!hit) return { error: 'no Save as item' };
  await sleep(300);
  const r = await P.ev(`(() => {
    const d = document.querySelector('dialog[aria-label="Save view"]'); if (!d) return 'no dialog';
    const f = n => d.querySelector('[name="' + n + '"]');
    f('name').value = ${JSON.stringify(name)}; f('name').dispatchEvent(new Event('input', { bubbles: true }));
    f('default').checked = ${!!o.def};
    const v = d.querySelector('input[name=visibility][value=${o.everyone ? 'everyone' : 'me'}]'); if (!v || v.disabled) return 'visibility off: ' + (v?.title || '');
    v.checked = true;
    f('range').checked = ${!!o.range};
    const b = [...d.querySelectorAll('button')].find(x => x.textContent.trim() === 'Save'); if (!b) return 'no Save button';
    b.click(); return 'ok';
  })()`);
  for (let i = 0; i < 40; i++) { await sleep(250); if (!(await P.ev(`!!document.querySelector('dialog[aria-label="Save view"][open]')`))) break; }
  await sleep(1500);
  return { result: r, id: (await keys()).view, notes: await notes() };
};
const notes = () => P.ev(`[...document.querySelectorAll('p.view-note')].map(p => p.textContent.trim())`);
const grid = n => `document.querySelector('table.grid[data-grid-name="${n}"]')`;
const hiddenCols = n => P.ev(`[...(${grid(n)}?.querySelectorAll('thead th[data-gt-hidden]') ?? [])].map(h => h.textContent.trim())`);
const hideCol = async (n, j) => {   // the grid's own menu: 'Hide column <c>' on a cell of column j
  const col = await P.ev(`(() => { const t = ${grid(n)}; const td = t?.querySelector('tbody tr td:nth-child(${j + 1})'); if (!td) return null;
    td.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true, clientX: 200, clientY: 200 })); return t.querySelectorAll('thead th')[${j}].textContent.trim(); })()`);
  await sleep(300);
  const hit = await P.ev(`(() => { const b = [...document.querySelectorAll('div.menu[role=menu] [role=menuitem]')].find(x => x.textContent.startsWith('Hide column')); if (!b) return false; b.click(); return true; })()`);
  await sleep(500);
  return hit ? col : null;
};
const focusedOnly = () => P.ev(`(() => { const t = ${grid('Instances')}; if (!t) return null; const rs = [...t.querySelectorAll('tbody tr')]; return { rows: rs.length, allBad: rs.every(r => !!r.querySelector('td.status.warn, td.status.crit')) }; })()`);
const run = async (name, f) => {
  if (only.length && !only.includes(name)) return;
  try { await f(); } catch (e) { check(name, false, `threw: ${String(e?.message ?? e).slice(0, 300)}`); }
};
const S = {};   // ids kept between cases
const sel = (label, v) => P.ev(`(() => { const s = document.querySelector('select[aria-label="${label}"]'); if (!s) return false; s.value = ${JSON.stringify(v)}; s.dispatchEvent(new Event('change', { bubbles: true })); return true; })()`);

await login(E.VB_U1, E.VB_U1PW);

await run('W1', async () => {
  await go('#/summary?view=none'); if (await noControl('W1')) return;
  await pick(/Focused View$/);
  const s = await saveAs('f1', { def: true });
  S.f1 = s.id;
  if (!check('W1', !!s.id && s.result === 'ok', `Save as 'f1': ${s.result}, view=${s.id}, notes ${JSON.stringify(s.notes)}`)) return;
  await go('#/slowqueries');
  await clickLink('nav a, #tabs a, a', 'Summary');
  const k = await keys(), f = await focusedOnly(), t = await vcText();
  check('W1', k.view === S.f1 && k.focus === '1' && f?.allBad && /^View: f1/.test(t ?? ''), `entering the Summary from Slow Queries: view=${k.view} focus=${k.focus}, button '${t}', the instance grid ${JSON.stringify(f)}`);
});
await run('W1b', async () => {
  await go('#/summary?view=none'); if (await noControl('W1b')) return;
  await P.ev(`localStorage.setItem('pgvigil.summaryFocus', '1'); 'ok'`);
  await go('#/summary?view=none');
  const s = await saveAs('f1b');
  await P.ev(`localStorage.removeItem('pgvigil.summaryFocus'); 'ok'`);
  await go('#/summary?view=none');
  await pick(/^f1b/);
  const f = await focusedOnly(), k = await keys();
  check('W1b', s.id && k.focus === '1' && f?.allBad, `saved with localStorage focus=1 and no keys, loaded with it cleared: focus=${k.focus}, the grid ${JSON.stringify(f)}`);
});
await run('W1c', async () => {
  await go('#/summary'); if (await noControl('W1c')) return;
  const k = await keys(), f = await focusedOnly();
  check('W1c', k.view === S.f1 && f?.allBad, `a fresh load of #/summary: view=${k.view} (f1 ${S.f1}), the grid ${JSON.stringify(f)}`);
});
await run('W1d', async () => {
  await go('#/summary'); if (await noControl('W1d')) return;
  await pick(/^\{None\}/);
  const h = await hash();
  await P.send('Page.reload'); await sleep(2500);
  const k = await keys(), t = await vcText();
  check('W1d', k.view === 'none' && /^View: None/.test(t ?? ''), `{None} then a reload: ${h} -> view=${k.view}, button '${t}'`);
});
await run('W2', async () => {
  await go('#/perfsummary'); if (await noControl('W2')) return;
  const col = await hideCol('Performance summary', 3);
  const s = await saveAs('p1');
  S.p1 = s.id; S.p1col = col;
  // the hide above went into this browser's own choices (no view was loaded): cleared, so the rows below see a viewer
  // whose own layout shows the column - the view's layer alone hides it (the browser is shared by u1 and u2)
  await P.ev(`Object.keys(localStorage).filter(k => k.startsWith('pgvigil.grid.')).forEach(k => localStorage.removeItem(k)); 'ok'`);
  await pick(/^\{None\}/); const off = await hiddenCols('Performance summary');
  await pick(/^p1/); const on = await hiddenCols('Performance summary');
  check('W2', !!col && !!s.id && !off.includes(col) && on.includes(col), `hid '${col}', saved p1 (${s.id}); {None}: hidden ${JSON.stringify(off)}; p1: hidden ${JSON.stringify(on)}`);
});
await run('W2b', async () => {
  await go(`#/perfsummary?view=${S.p1}`); if (await noControl('W2b')) return;
  await P.send('Page.reload'); await sleep(2500);
  const h = await hiddenCols('Performance summary');
  check('W2b', h.includes(S.p1col), `a reload on p1: hidden ${JSON.stringify(h)}`);
});
await run('W2c', async () => {
  await go(`#/perfsummary?view=${S.p1}`); if (await noControl('W2c')) return;
  await clickLink('nav a, #tabs a, a', 'Summary');
  await clickLink('nav a, #tabs a, a', 'Performance summary');
  const h = await hiddenCols('Performance summary'), k = await keys();
  check('W2c', !h.includes(S.p1col) && !k.view, `a tab away and back: view=${k.view ?? '(none)'}, hidden ${JSON.stringify(h)}`);
});
await run('W2d', async () => {
  await login(E.VB_U2, E.VB_U2PW);
  await go(`#/perfsummary?view=${S.p1}`);
  if (!(await noControl('W2d'))) {
    const n = await notes(), h = await hiddenCols('Performance summary');
    check('W2d', n.some(x => x === `view ${S.p1} is not yours to open: its address applied, its layouts not`) && !h.includes(S.p1col), `u2 on u1's personal p1: notes ${JSON.stringify(n)}, hidden ${JSON.stringify(h)}`);
  }
  await login(E.VB_U1, E.VB_U1PW);
});
await run('W2e', async () => {
  if (!E.VB_TAG) { check('W2e', false, 'the demo fleet has no tag'); return; }
  await go(`#/perfsummary?tag=${encodeURIComponent(E.VB_TAG)}&w=6h&view=${S.p1}`); if (await noControl('W2e')) return;
  const h = await hiddenCols('Performance summary'), n = await notes();
  check('W2e', h.includes(S.p1col) && !n.some(x => /skipped/.test(x)), `p1 under tag ${E.VB_TAG} over 6 h: hidden ${JSON.stringify(h)}, notes ${JSON.stringify(n)}`);
});
await run('W3', async () => {
  await go('#/slowqueries?view=none'); if (await noControl('W3')) return;
  await sel('Group By', 'database'); await sleep(1500);
  await sel('Top', '1000'); await sleep(1500);
  const { items } = await pick(/^(✓ )?Auto Size Columns/);
  const words = items.find(x => /Auto Size Columns/.test(x)) ?? '';
  const s = await saveAs('sq1', { everyone: true });
  S.sq1 = s.id; S.sq1hash = await hash();
  await login(E.VB_U2, E.VB_U2PW);
  await go('#/slowqueries?view=none');
  const it = await openMenu(); await P.ev(`document.body.click(); 'ok'`);
  const listed = it.find(x => /^sq1/.test(x)) ?? '';
  await pick(/^sq1/);
  const k = await keys();
  const oneLine = await P.ev(`(() => { const c = document.querySelector('main table.grid td.wide'); return c ? getComputedStyle(c).whiteSpace : 'no long-text cell'; })()`);
  const it2 = await openMenu(); await P.ev(`document.body.click(); 'ok'`);
  const saveOff = it2.find(x => /^Save( |$)/.test(x)) ?? '';
  check('W3', /long text on one line/.test(words) && /\(shared\)/.test(listed) && k.g === 'database' && k.top === '1000' && k.fit === '1' && oneLine === 'nowrap' && /\[off: .+\]/.test(saveOff),
    `the item '${words}'; u2 lists '${listed}', picks it: g=${k.g} top=${k.top} fit=${k.fit}, a long-text cell ${oneLine}; u2's '${saveOff}'`);
  await login(E.VB_U1, E.VB_U1PW);
});
await run('W3b', async () => {
  if (!E.VB_MSSQL) { check('W3b', false, 'the demo fleet has no SQL Server instance'); return; }
  await go(`#/mssql_slow?i=${E.VB_MSSQL}&view=none`); if (await noControl('W3b')) return;
  await sel('Group By', 'database'); await sleep(1500);
  const s = await saveAs('ms1');
  // the range panel (rangepicker.ts: its items are links built by href, the router's keep rule under test)
  await P.ev(`document.querySelector('#bar [aria-haspopup="dialog"]').click(); 'ok'`); await sleep(300);
  const ok1 = await P.ev(`(() => { const b = [...document.querySelectorAll('#bar [role="dialog"][aria-label="Time range"] button.range-item')].find(x => x.firstChild.textContent === 'Last 6 hours'); if (!b) return false; b.click(); return true; })()`);
  for (let i = 0; i < 40; i++) { await sleep(250); if (await P.ev(ready)) break; }
  await sleep(1200);
  const k = await keys();
  check('W3b', !!s.id && ok1 && k.w === '6h' && k.g === 'database' && k.view === s.id, `mssql_slow: saved ms1 (${s.id}); after the range panel's 'Last 6 hours' (${ok1}): w=${k.w} g=${k.g} view=${k.view}`);
});
await run('W4', async () => {
  await go(`#/perfsummary?view=${S.p1}`); if (await noControl('W4')) return;
  const t2 = await A.send('Target.createTarget', { url: base + `#/perfsummary?view=${S.p1}` });
  await sleep(3000);
  const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  const B = await connect(list.find(t => t.id === t2.result.targetId).webSocketDebuggerUrl);
  await sleep(1500);
  const saveIn = async X => { P = X; const r = await pick(/^Save$/); await sleep(1500); const n = await notes(); P = A; return { r, n }; };
  const a = await saveIn(A), b = await saveIn(B);
  P = B; const loadBtn = await P.ev(`[...document.querySelectorAll('p.view-note button')].map(x => x.textContent.trim())`); P = A;
  await A.send('Target.closeTarget', { targetId: t2.result.targetId }); B.ws.close();
  check('W4', a.r.hit && !a.n.some(x => /stored/.test(x)) && b.n.some(x => /version|changed since/.test(x)) && loadBtn.includes('Load the stored one'), `tab A saved (notes ${JSON.stringify(a.n)}); tab B: notes ${JSON.stringify(b.n)}, buttons ${JSON.stringify(loadBtn)}`);
});
await run('W5', async () => {
  await go('#/slowqueries?view=none'); if (await noControl('W5')) return;
  A.reqs.length = 0;
  await sel('Top', 'all'); await sleep(2500);
  const r = A.reqs.filter(u => u.includes('/api/slow/groups'));
  check('W5', r.some(u => /[?&]top=all(&|$)/.test(u)), `Top ALL asked: ${JSON.stringify(r.map(u => u.replace(/^.*\?/, '?')).slice(-2))}`);
});
await run('W5b', async () => {
  if (!E.VB_TAG) { check('W5b', false, 'the demo fleet has no tag'); return; }
  await go(`#/slowqueries?tag=${encodeURIComponent(E.VB_TAG)}&view=none`); if (await noControl('W5b')) return;
  A.reqs.length = 0;
  await sel('Top', 'all'); await sleep(2500);
  const r = A.reqs.filter(u => u.includes('/api/slow/groups'));
  check('W5b', r.some(u => /[?&]top=all(&|$)/.test(u)) && !r.some(u => /[?&]top=500(&|$)/.test(u)), `under tag ${E.VB_TAG}: ${JSON.stringify(r.map(u => u.replace(/^.*\?/, '?')).slice(-2))}`);
});
await run('W6', async () => {
  await go('#/perfsummary?w=6h&view=none'); if (await noControl('W6')) return;
  const off = await saveAs('p6off'), on = await saveAs('p6', { range: true });
  const g = id => api(`/api/views?id=${id}`).then(r => { const v = r.body?.view; const row = v ? Object.fromEntries(v.columns.map((c, i) => [c, v.rows[0][i]])) : {}; return row.state ?? null; });
  const sOff = await g(off.id), sOn = await g(on.id);
  await go('#/perfsummary?w=1h&view=none');
  await pick(/^p6( |$)/);
  const k = await keys();
  check('W6', !!sOff && !sOff.range && sOn?.range?.w === '6h' && k.w === '6h', `p6off's state.range ${JSON.stringify(sOff?.range ?? null)}; p6's ${JSON.stringify(sOn?.range ?? null)}; picking p6 from 1h: w=${k.w}`);
});
await run('W7', async () => {
  if (!S.sq1hash) { check('W7', false, 'no sq1 address (W3 did not save it)'); return; }
  await login(E.VB_U2, E.VB_U2PW);
  await go(S.sq1hash);
  const k = await keys(), t = await vcText();
  check('W7', t !== null && k.g === 'database' && k.top === '1000' && k.fit === '1' && /^View: sq1/.test(t ?? ''), `u2 opens u1's link ${S.sq1hash}: g=${k.g} top=${k.top} fit=${k.fit}, button '${t}'`);
  await login(E.VB_U1, E.VB_U1PW);
});
await run('W8', async () => {
  // u1's own default f1 (W1) and a shared default 'fdef', both focused: a mail render applies neither
  await go('#/summary?view=none&focus=0'); if (await noControl('W8')) return;
  await P.ev(`localStorage.removeItem('pgvigil.summaryFocus'); 'ok'`);
  await go('#/summary?view=none&focus=0');
  const all = await focusedOnly();
  await pick(/Focused View$/);
  const s = await saveAs('fdef', { def: true, everyone: true });
  await P.ev(`localStorage.removeItem('pgvigil.summaryFocus'); 'ok'`);
  await go('#/summary?mailrender=000000000000000000000000000000000000000000000000');
  const k = await keys(), f = await focusedOnly();
  await go(`#/perfsummary?view=${S.p1}&mailrender=000000000000000000000000000000000000000000000000`);
  const h = await hiddenCols('Performance summary');
  check('W8', !!s.id && k.view === undefined && f?.rows === all?.rows && !h.includes(S.p1col), `a mail render of #/summary: view=${k.view ?? '(none)'}, ${f?.rows} instance rows (unfocused ${all?.rows}); of p1: hidden ${JSON.stringify(h)}`);
});

// SHOTS (the design's P2; only with VB_SHOTS = a folder): each of the five view pages with its View menu open, in the
// light and the dark theme, saved as views-b-<page>-<theme>.png to sit beside the audit's DBA Dash shots of the page
if (E.VB_SHOTS) await run('SHOTS', async () => {
  const fs = await import('node:fs');
  const pages = [['summary', '#/summary?view=none'], ['perfsummary', '#/perfsummary?view=none'], ['slowqueries', '#/slowqueries?view=none'],
    ...(E.VB_PG ? [['slowqueries-instance', `#/slowqueries?i=${E.VB_PG}&view=none`]] : []),
    ...(E.VB_MSSQL ? [['mssql-slow', `#/mssql_slow?i=${E.VB_MSSQL}&view=none`]] : [])];
  const made = [];
  for (const theme of ['light', 'dark']) {
    await go('#/about');
    await P.ev(`localStorage.setItem('pgvigil.theme', ${JSON.stringify(theme)}); 'ok'`);
    await P.send('Emulation.setEmulatedMedia', { features: [{ name: 'prefers-color-scheme', value: theme }] });
    for (const [name, h] of pages) {
      await go(h);
      if (await vcText() === null) continue;
      await openMenu();
      const d = await P.send('Page.captureScreenshot', { format: 'png' });
      if (d.result?.data) { fs.writeFileSync(`${E.VB_SHOTS}/views-b-${name}-${theme}.png`, Buffer.from(d.result.data, 'base64')); made.push(`${name}-${theme}`); }
    }
  }
  check('SHOTS', made.length === pages.length * 2, `${made.length} of ${pages.length * 2} pictures in ${E.VB_SHOTS}: ${made.join(', ')}`);
});

console.log(failed ? `${failed} case(s) failed` : 'all cases ok');
process.exit(failed ? 1 : 0);
