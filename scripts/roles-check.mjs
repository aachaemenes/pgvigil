// The per-user roles as the pages draw them (task B24f, R4), over a headless Chromium (CDP): signed in as one user,
// every root page and every page of one PostgreSQL and one SQL Server instance is opened, and every control that
// carries data-need (a write control: web/src/needs.ts needControl) is read and judged against the user's role.
// Usage:
//   node scripts/roles-check.mjs <cdp port> <base url/> <user> <password> <viewer|operator|admin>
//   chromium --headless=new --remote-debugging-port=<p> about:blank &   pgvigil serve -config ... (the login on)
// A control whose need is ABOVE the role must be off (aria-disabled, or the disabled attribute): with the role's words
// as its title ('<what> needs the <need> role: <user> is a <role> ...') and a visible, non-empty description - or off
// for the server's own reason, which comes first (no door, an instance not opted in: counted as 'own'). A control at
// or below the role must not be off with the role's words. The pages of MUST carry a control of the need named, and
// the pages of WORDS show the role's words to a role below (the ack seat writes on this serve: scripts/proof-uiroles-
// pages.sh). Last a click: the instance header's Silence opens nothing where it is off for the role, and its dialog
// where it is on (closed again, nothing saved). Prints one line per page that holds such a control, each FAIL, the
// totals; exit 1 on any FAIL.
const [port, U, user, pw, role] = process.argv.slice(2);
const rank = { viewer: 1, operator: 2, admin: 3 };
const art = role === 'viewer' ? 'a' : 'an';
if (!rank[role]) { console.log(`FAIL: role '${role}' is not viewer, operator or admin`); process.exit(2); }
// [page key, need]: a control with data-need=<need> is drawn on that page for every role
const MUST = [['alerts', 'operator'], ['alertrules', 'admin'], ['pgthresholds', 'admin'], ['drives', 'admin'], ['customreports', 'admin'],
  ['reportmail', 'admin'], ['admin_instances', 'admin'], ['admin_applications', 'admin'], ['pg:summary', 'operator'], ['pg:plans', 'operator']];
// [page key, need]: below the need, a control of that page is off with the ROLE's words (its server writes here)
const WORDS = [['alerts', 'operator'], ['pg:summary', 'operator'], ['pgthresholds', 'admin'], ['drives', 'admin'], ['admin_applications', 'admin']];

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
let walked = 0;
ws.addEventListener('close', e => { console.log(`FAIL: the browser's socket closed (code ${e.code}) after ${walked} page(s)`); process.exit(3); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const settled = async (ms = 20000) => {
  const t = Date.now();
  while (Date.now() - t < ms) {
    // rendered = the shell replaced its loading line (drawn empty, 'Loading...' a frame later: an empty status line is
    // not a page yet); an honest empty state ('No rows yet') is a rendered page too
    const ok = await ev(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector(':scope > p.empty');
      return !(e && (/^Loading/.test(e.textContent) || (e.getAttribute('role') === 'status' && e.textContent === ''))) && m.children.length > 0; })()`);
    if (ok) {
      for (let i = 0; i < 50 && await ev(`/[?&]i=/.test(location.hash) && !document.querySelector('main .inst-header')`); i++) await sleep(100);
      await sleep(400); return true;
    }
    await sleep(150);
  }
  return false;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
// auto refresh off in every document: a page redrawn under the read would be read half drawn
await cmd('Page.addScriptToEvaluateOnNewDocument', { source: `try { localStorage.setItem('pgvigil.refresh', '0'); } catch (e) {}` });
await cmd('Page.navigate', { url: U }); await sleep(800);

// sign in from the page itself: the session cookie is the page's own
const code = await ev(`fetch('/api/login', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
  body: JSON.stringify({ username: ${JSON.stringify(user)}, password: ${JSON.stringify(pw)} }) }).then(r => r.status)`, true);
if (code !== 200) { console.log(`FAIL: the sign-in of ${user} answered ${code}`); process.exit(2); }
const sess = await ev(`fetch('/api/session', { credentials: 'same-origin' }).then(r => r.json())`, true);
let fails = 0;
const bad = t => { fails++; console.log('FAIL ' + t); };
if (sess.user !== user || sess.role !== role) bad(`GET /api/session says ${JSON.stringify(sess)}, not ${user} as ${role}`);
else console.log(`ok   signed in: ${sess.user} (${sess.role})`);
const inst = await ev(`fetch('/api/instances', { credentials: 'same-origin' }).then(r => r.json())`, true);
const rows = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const pg = rows.find(r => r.engine !== 'sqlserver' && r.platform === 'onprem') ?? rows.find(r => r.engine !== 'sqlserver');
const ms = rows.find(r => r.engine === 'sqlserver' && String(r.name).endsWith('sql01')) ?? rows.find(r => r.engine === 'sqlserver');
if (!pg || !ms) { console.log(`FAIL: the store holds no PostgreSQL or no SQL Server instance (${rows.length} instances): the demo was not seeded`); process.exit(2); }

const tabsOf = async (hash) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(300);
  await cmd('Page.reload'); await sleep(300);   // a hash change alone keeps the document: the first page is loaded signed in
  await settled();
  return await ev(`(() => { const t = document.querySelector('#tabs'); return t && t.dataset.all ? JSON.parse(t.dataset.all) : []; })()`);
};
const pages = [];
for (const h of await tabsOf('#/summary')) pages.push(['', h]);
for (const h of await tabsOf(`#/summary?i=${pg.instance_id}`)) pages.push(['pg:', h]);
for (const h of await tabsOf(`#/summary?i=${ms.instance_id}`)) pages.push(['ms:', h]);
if (pages.length < 60) bad(`only ${pages.length} pages listed (the root's, ${pg.name}'s and ${ms.name}'s): the tab lists were not read`);

const header = await ev(`(() => { const x = document.getElementById('role-note'); return x ? x.textContent.replace(/\\s+/g, ' ').trim() : ''; })()`);
if (header.startsWith(`${user} (${role}`)) console.log(`ok   the header names the role: '${header}'`);
else bad(`the header's role line (#role-note) says '${header}', not '${user} (${role} ...'`);

const read = () => ev(`(() => {
  const vis = e => !!e && e.getClientRects().length > 0 && getComputedStyle(e).visibility !== 'hidden';
  const txt = x => (x.textContent || '').replace(/\\s+/g, ' ').trim();
  return [...document.querySelectorAll('[data-need]')].filter(vis).map(e => {
    const ids = (e.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean);
    return { need: e.dataset.need, what: (e.getAttribute('aria-label') || txt(e) || e.getAttribute('name') || e.tagName).slice(0, 70),
      off: e.disabled === true || e.getAttribute('aria-disabled') === 'true', title: e.title || '',
      desc: ids.map(i => { const x = document.getElementById(i); return x ? txt(x) : ''; }).join(' | '),
      descVis: ids.some(i => { const x = document.getElementById(i); return vis(x) && txt(x) !== ''; }) };
  });
})()`);

const anyRole = /needs the (viewer|operator|admin) role/;
const seen = new Map();    // 'key|need' -> { n, role, own, on }
const tot = { operator: { role: 0, own: 0, on: 0 }, admin: { role: 0, own: 0, on: 0 } };
let notRendered = 0, withControls = 0;
const ownWhy = new Map();
for (const [scope, hash] of pages) {
  await cmd('Page.navigate', { url: U + hash });
  await sleep(400);
  if (!await settled()) { notRendered++; bad(`${hash}: the page did not render in 20 s`); continue; }
  walked++;
  const key = scope + (hash.match(/^#\/([a-z_]+)/)?.[1] ?? hash);
  const cs = await read();
  if (!cs.length) continue;
  withControls++;
  const line = { role: 0, own: 0, on: 0 };
  for (const c of cs) {
    if (!rank[c.need] || c.need === 'viewer') { bad(`${hash} '${c.what}': data-need='${c.need}' is not operator or admin`); continue; }
    const above = rank[c.need] > rank[role];
    const mine = new RegExp(`needs the ${c.need} role: ${user} is an? ${role} `).test(c.title);
    let state;
    if (above) {
      if (!c.off) { bad(`${hash} '${c.what}' (needs ${c.need}): ON for ${art} ${role}`); continue; }
      if (mine) {
        if (!c.descVis) { bad(`${hash} '${c.what}' (needs ${c.need}): off with the role's words as its title and no visible description ('${c.desc.slice(0, 80)}')`); continue; }
        state = 'role';
      } else if (anyRole.test(c.title)) { bad(`${hash} '${c.what}' (needs ${c.need}): off with other role words: '${c.title.slice(0, 140)}'`); continue; }
      else { state = 'own'; const w = (c.title || c.desc).slice(0, 90); ownWhy.set(w, (ownWhy.get(w) ?? 0) + 1); }
    } else {
      if (c.off && anyRole.test(c.title)) { bad(`${hash} '${c.what}' (needs ${c.need}): off with the role's words for ${art} ${role}: '${c.title.slice(0, 140)}'`); continue; }
      state = c.off ? 'own' : 'on';
      if (c.off) { const w = (c.title || c.desc).slice(0, 90); ownWhy.set(w, (ownWhy.get(w) ?? 0) + 1); }
    }
    line[state]++; tot[c.need][state]++;
    const k = `${key}|${c.need}`, s = seen.get(k) ?? { n: 0, role: 0, own: 0, on: 0 };
    s.n++; s[state]++; seen.set(k, s);
  }
  console.log(`page ${hash}: ${cs.length} control(s) with a need - ${line.role} off for the role, ${line.own} off for the server's own reason, ${line.on} on`);
}
// a click: the instance header's Silence (or Unsilence) on the PostgreSQL instance's Summary. Off for the role, a click
// opens nothing; on, it opens its dialog, whose Save carries the need and is not off for the role. Nothing is saved.
await cmd('Page.navigate', { url: U + `#/summary?i=${pg.instance_id}` }); await sleep(400); await settled();
const click = await ev(`(async () => {
  const b = [...document.querySelectorAll('[data-need="operator"]')].find(e => /^(Silence|Unsilence)/.test((e.textContent || '').trim()));
  if (!b) return { found: false };
  const off = b.getAttribute('aria-disabled') === 'true';
  b.click();
  await new Promise(r => setTimeout(r, 700));
  const d = document.querySelector('dialog[open]');
  const out = { found: true, off, dialog: !!d, title: d ? (d.getAttribute('aria-label') || '') : '',
    save: d ? [...d.querySelectorAll('[data-need]')].map(e => ({ need: e.dataset.need, off: e.getAttribute('aria-disabled') === 'true', title: e.title })) : [] };
  if (d) { d.close(); d.remove(); }
  return out;
})()`, true);
if (!click.found) bad(`click: no Silence / Unsilence control with data-need=operator on #/summary?i=${pg.instance_id}`);
else if (rank.operator > rank[role]) {
  if (click.off && !click.dialog) console.log(`ok   click: the off Silence clicked as ${art} ${role}: nothing opened`);
  else bad(`click: Silence as ${art} ${role}: off ${click.off}, a dialog opened ${click.dialog} ('${click.title}')`);
} else if (!click.off && click.dialog && click.save.length && click.save.every(x => x.need === 'operator' && !anyRole.test(x.title))) console.log(`ok   click: Silence clicked as ${art} ${role}: '${click.title}' opened, its Save carries the operator need and is not off for the role`);
else bad(`click: Silence as ${role}: off ${click.off}, dialog ${click.dialog} ('${click.title}'), its controls ${JSON.stringify(click.save).slice(0, 200)}`);

for (const [k, need] of MUST) {
  const s = seen.get(`${k}|${need}`);
  if (s?.n) console.log(`ok   must ${k}: ${s.n} control(s) need ${need}`);
  else bad(`must ${k}: no control with data-need=${need} on that page`);
}
for (const [k, need] of WORDS) {
  const s = seen.get(`${k}|${need}`) ?? { n: 0, role: 0, own: 0, on: 0 };
  if (rank[need] > rank[role]) {
    if (s.role > 0) console.log(`ok   words ${k}: ${s.role} control(s) off with '... needs the ${need} role: ${user} is ${art} ${role} ...'`);
    else bad(`words ${k}: no control off with the ${need} role's words for ${art} ${role} (${s.n} with that need: ${s.own} off for the server's own reason, ${s.on} on)`);
  } else if (s.on > 0) console.log(`ok   on ${k}: ${s.on} control(s) of need ${need} on for ${art} ${role}`);
  else bad(`on ${k}: no control of need ${need} is on for ${art} ${role} (${s.n} with that need, ${s.own} off for the server's own reason)`);
}
for (const [w, n] of [...ownWhy].sort((a, b) => b[1] - a[1]).slice(0, 12)) console.log(`own  ${n} x '${w}'`);
console.log(`roles-check ${role}: ${walked} page(s) read, ${notRendered} not rendered, ${withControls} with a control that carries a need; `
  + `operator: ${tot.operator.role} off for the role, ${tot.operator.own} own reason, ${tot.operator.on} on; `
  + `admin: ${tot.admin.role} off for the role, ${tot.admin.own} own reason, ${tot.admin.on} on; ${fails} FAIL`);
process.exit(fails ? 1 : 0);
