// The 7-day end an operator picks in a dialog (task B24f; the lead 11-15 19:3x, review-20 jw1 S1, review-21), over a
// headless Chromium (CDP): signed in as an operator, the page's clock 60 s AHEAD of the server's, two dialogs with
// their 7-day choice picked and saved on one PostgreSQL instance - the instance header's Silence (its Summary, 'until'
// 7 days) and the Alerts page's New mute rule ('until' 7 days after the start, start at once). The server measures
// the 7-day ceiling by its own clock (internal/web/roles.go openEnded), so each dialog's 7 days must end short of it:
// a browser clock ahead of the server's by up to 10 minutes still saves. Each row reads the dialog's own POST /api/ack
// (its request's body and its answer, by request id: the pages' GET /api/ack reads share the path) and passes when the
// answer is 200 'done' AND the end it sent lies within (168 h - 11 min, 168 h] of the real clock.
// Usage:
//   node scripts/roles-mute-week.mjs <cdp port> <base url/> <user> <password>
// The instance is a PostgreSQL one other than roles-check.mjs's pick (its click row reads that one's Silence).
// Prints one 'ok' or 'FAIL' line per row; exit 1 on a FAIL, 2 when it could not run.
const [port, U, user, pw] = process.argv.slice(2);
const AHEAD_MS = 60000, H168 = 168 * 3600e3, LOW = H168 - 660e3;
const t = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
let id = 0; const wait = new Map();
let posts = new Map();   // requestId -> { body, sentAt (the real clock), status, done }
const isAck = u => { try { return new URL(u).pathname === '/api/ack'; } catch { return false; } };
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); return; }
  if (d.method === 'Network.requestWillBeSent' && d.params.request.method === 'POST' && isAck(d.params.request.url))
    posts.set(d.params.requestId, { body: d.params.request.postData ?? '', sentAt: Date.now(), status: 0 });
  if (d.method === 'Network.responseReceived' && posts.has(d.params.requestId)) posts.get(d.params.requestId).status = d.params.response.status;
  if (d.method === 'Network.loadingFinished' && posts.has(d.params.requestId)) posts.get(d.params.requestId).done = true;
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 20000) => { for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(200)) if (await ev(expr)) return true; return false; };
let fails = 0;
const say = (good, line) => { if (!good) fails++; console.log((good ? 'ok   week: ' : 'FAIL week: ') + line); };
const stop = async (line, rc) => { console.log(line); await fetch(`http://127.0.0.1:${port}/json/close/${t.id}`).catch(() => {}); process.exit(rc); };
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
// the page's clock AHEAD_MS ahead of the server's, in every document of this tab (Date.now and new Date())
await cmd('Page.addScriptToEvaluateOnNewDocument', { source: `try { localStorage.setItem('pgvigil.refresh', '0'); } catch (e) {}
(() => { const RD = Date, off = ${AHEAD_MS}; class D extends RD { constructor(...a) { if (a.length) super(...a); else super(RD.now() + off); } static now() { return RD.now() + off; } } globalThis.Date = D; })();` });
await cmd('Page.navigate', { url: U }); await sleep(800);
const code = await ev(`fetch('/api/login', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
  body: JSON.stringify({ username: ${JSON.stringify(user)}, password: ${JSON.stringify(pw)} }) }).then(r => r.status)`, true);
if (code !== 200) await stop(`FAIL week: the sign-in of ${user} answered ${code}`, 2);
const sess = await ev(`fetch('/api/session', { credentials: 'same-origin' }).then(r => r.json())`, true);
if (sess.user !== user || sess.role !== 'operator') await stop(`FAIL week: GET /api/session says ${JSON.stringify(sess)}, not ${user} as an operator`, 2);
const inst = await ev(`fetch('/api/instances', { credentials: 'same-origin' }).then(r => r.json())`, true);
const rows = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const pgs = rows.filter(r => r.engine !== 'sqlserver');
const theirs = pgs.find(r => r.platform === 'onprem') ?? pgs[0];   // roles-check.mjs's pick
const pg = pgs.find(r => r !== theirs);
if (!pg) await stop(`FAIL week: the store holds fewer than two PostgreSQL instances (${rows.length} instances): the demo was not seeded`, 2);
// open: the page loaded anew (the shell boots signed in as this user: a hash change after a sign-in does not redraw it)
const open = async hash => { await cmd('Page.navigate', { url: U + hash }); await sleep(300); await cmd('Page.reload', {}); await sleep(800); };
await open(`#/summary?i=${pg.instance_id}`);
const ahead = await ev(`Date.now() - (performance.timeOrigin + performance.now())`);
if (!(Math.abs(ahead - AHEAD_MS) < 2000)) await stop(`FAIL week: the page's clock is ${ahead} ms ahead, not ${AHEAD_MS} (the override did not take)`, 2);

// row: the opener clicked, its dialog's 7-day choice picked, Save clicked; then its POST /api/ack graded
const row = async (name, opener, pick) => {
  if (!await until(`!!${opener}`)) return say(false, `${name}: no opener (${opener.slice(0, 120)}) on ${String(pg.name)}`);
  const o = await ev(`(async () => {
    const b = ${opener};
    if (b.getAttribute('aria-disabled') === 'true') return { step: 'the opener is off: ' + b.title };
    b.click(); await new Promise(r => setTimeout(r, 900));
    const d = document.querySelector('dialog[open]'); if (!d) return { step: 'no dialog opened' };
    ${pick}
    const save = [...d.querySelectorAll('button')].find(x => x.textContent.trim() === 'Save');
    if (!save) return { step: 'no Save', buttons: [...d.querySelectorAll('button')].map(x => x.textContent.trim()) };
    if (save.getAttribute('aria-disabled') === 'true' || save.disabled) return { step: 'Save is off: ' + (save.title || d.querySelector('p.meta')?.textContent || '') };
    window.__weekSave = save; return { step: 'ready' };
  })()`, true);
  if (o.step !== 'ready') return say(false, `${name}: ${JSON.stringify(o).slice(0, 300)}`);
  posts = new Map();
  await ev(`window.__weekSave.click(); 1`);
  for (let i = 0; i < 50 && ![...posts.values()].some(p => p.done); i++) await sleep(200);
  const [rid, p] = [...posts.entries()].find(([, x]) => x.done) ?? [];
  if (!p) return say(false, `${name}: no POST /api/ack answered in 10 s after Save on ${String(pg.name)}`);
  const body = String((await cmd('Network.getResponseBody', { requestId: rid })).result?.body ?? '').replace(/\s+/g, ' ').slice(0, 300);
  let sent = null; try { sent = JSON.parse(p.body).until ?? null; } catch { sent = null; }
  const lead = sent ? Date.parse(sent) - p.sentAt : NaN;
  const inWindow = lead > LOW && lead <= H168;
  const words = `${name} of ${String(pg.name)}, the page's clock ${AHEAD_MS / 1000} s ahead: ${p.status} ${body}; its end ${sent} = ${(lead / 3600e3).toFixed(4)} h after the real clock`;
  say(p.status === 200 && /"outcome":"done"/.test(body) && inWindow, words + (inWindow ? '' : ` (outside (${(LOW / 3600e3).toFixed(4)}, 168] h)`));
  await ev(`(() => { for (const d of document.querySelectorAll('dialog[open]')) { d.close(); d.remove(); } })()`);
};
await row("an operator's Silence with '7 days' picked", `[...document.querySelectorAll('[data-need="operator"]')].find(e => /^Silence/.test((e.textContent || '').trim()))`,
  `const sel = d.querySelector('select[aria-label="until"]'); const opt = sel && [...sel.options].find(x => x.textContent.trim() === '7 days');
    if (!opt) return { step: 'no 7 days choice', choices: sel ? [...sel.options].map(x => x.textContent) : null };
    sel.value = opt.value; sel.dispatchEvent(new Event('change', { bubbles: true }));`);
await open('#/alerts');
await row("an operator's New mute rule on one instance, '7 days after the start'", `[...document.querySelectorAll('main button')].find(e => /^New mute rule/.test((e.textContent || '').trim()))`,
  `const inst = d.querySelector('select[aria-label="instance"]'), sel = d.querySelector('select[aria-label="until"]'), now = d.querySelector('input[aria-label="start at once"]');
    if (!inst || !sel) return { step: 'no instance or until field (the rule dialog without the mutes read?)' };
    inst.value = ${JSON.stringify(String(pg.instance_id))}; inst.dispatchEvent(new Event('change', { bubbles: true }));
    if (inst.value !== ${JSON.stringify(String(pg.instance_id))}) return { step: 'the instance is not in the dialog list' };
    if (now && !now.checked) { now.checked = true; now.dispatchEvent(new Event('change', { bubbles: true })); }
    sel.value = '168'; sel.dispatchEvent(new Event('change', { bubbles: true }));
    if (sel.value !== '168') return { step: 'no 168 h choice' };`);
await stop(`roles-mute-week: ${fails} FAIL`, fails ? 1 : 0);
