// The 7-day end of an operator's Silence as the dialog makes it (task B24f; the lead 11-15 19:3x, review-20 jw1 S1), over
// a headless Chromium (CDP): signed in as an operator, with the page's clock 60 s AHEAD of the server's, the instance
// header's Silence on one PostgreSQL instance's Summary, '7 days' picked in its 'until' choice and saved, is DONE. The
// server measures the 7-day ceiling by its own clock (internal/web/roles.go openEnded), so the dialog's 7 days must end
// short of it: a browser clock ahead of the server's by up to 10 minutes still saves.
// Usage:
//   node scripts/roles-mute-week.mjs <cdp port> <base url/> <user> <password>
// The instance is a PostgreSQL one other than roles-check.mjs's (its click row reads that one's Silence), so the
// silence this row saves changes no other row. The answer is the server's own: POST /api/ack's status and body from the network log.
// Prints one 'ok' or 'FAIL' line (the 7-day row) and exits 1 on FAIL, 2 when it could not run.
const [port, U, user, pw] = process.argv.slice(2);
const AHEAD_MS = 60000;
const t = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
const ws = new WebSocket(t.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.addEventListener('open', r); ws.addEventListener('error', j); });
let id = 0; const wait = new Map(); const acks = [];
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.id && wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); return; }
  if (d.method === 'Network.responseReceived' && /\/api\/ack$/.test(new URL(d.params.response.url).pathname)) acks.push({ req: d.params.requestId, status: d.params.response.status });
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 20000) => { for (const t0 = Date.now(); Date.now() - t0 < ms; await sleep(200)) if (await ev(expr)) return true; return false; };
const done = async (line, rc) => { console.log(line); await fetch(`http://127.0.0.1:${port}/json/close/${t.id}`).catch(() => {}); process.exit(rc); };
await cmd('Page.enable'); await cmd('Runtime.enable'); await cmd('Network.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });
// the page's clock AHEAD_MS ahead of the server's, in every document of this tab (Date.now and new Date())
await cmd('Page.addScriptToEvaluateOnNewDocument', { source: `try { localStorage.setItem('pgvigil.refresh', '0'); } catch (e) {}
(() => { const RD = Date, off = ${AHEAD_MS}; class D extends RD { constructor(...a) { if (a.length) super(...a); else super(RD.now() + off); } static now() { return RD.now() + off; } } globalThis.Date = D; })();` });
await cmd('Page.navigate', { url: U }); await sleep(800);
const code = await ev(`fetch('/api/login', { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
  body: JSON.stringify({ username: ${JSON.stringify(user)}, password: ${JSON.stringify(pw)} }) }).then(r => r.status)`, true);
if (code !== 200) await done(`FAIL week: the sign-in of ${user} answered ${code}`, 2);
const inst = await ev(`fetch('/api/instances', { credentials: 'same-origin' }).then(r => r.json())`, true);
const rows = inst.rows.map(r => Object.fromEntries(inst.columns.map((c, i) => [c, r[i]])));
const pgs = rows.filter(r => r.engine !== 'sqlserver');
const theirs = pgs.find(r => r.platform === 'onprem') ?? pgs[0];   // roles-check.mjs's pick
const pg = pgs.find(r => r !== theirs);
if (!pg) await done(`FAIL week: the store holds fewer than two PostgreSQL instances (${rows.length} instances): the demo was not seeded`, 2);
await cmd('Page.navigate', { url: U + `#/summary?i=${pg.instance_id}` }); await sleep(400);
const ahead = await ev(`Date.now() - (performance.timeOrigin + performance.now())`);
if (!(Math.abs(ahead - AHEAD_MS) < 2000)) await done(`FAIL week: the page's clock is ${ahead} ms ahead, not ${AHEAD_MS} (the override did not take)`, 2);
const sil = `[...document.querySelectorAll('[data-need="operator"]')].find(e => /^Silence/.test((e.textContent || '').trim()))`;
if (!await until(`!!${sil}`)) await done(`FAIL week: no Silence with data-need=operator on #/summary?i=${pg.instance_id} (${String(pg.name)})`, 1);
const o = await ev(`(async () => {
  const b = ${sil};
  if (b.getAttribute('aria-disabled') === 'true') return { step: 'Silence is off: ' + b.title };
  b.click(); await new Promise(r => setTimeout(r, 700));
  const d = document.querySelector('dialog[open]'); if (!d) return { step: 'no dialog opened' };
  const sel = d.querySelector('select[aria-label="until"]');
  const opt = sel && [...sel.options].find(x => x.textContent.trim() === '7 days');
  if (!opt) return { step: 'no 7 days choice', choices: sel ? [...sel.options].map(x => x.textContent) : null };
  sel.value = opt.value; sel.dispatchEvent(new Event('change', { bubbles: true }));
  const save = [...d.querySelectorAll('button')].find(x => x.textContent.trim() === 'Save');
  if (!save || save.getAttribute('aria-disabled') === 'true' || save.disabled) return { step: 'Save is off: ' + (save?.title ?? 'none') };
  save.click();
  return { step: 'saved', title: d.getAttribute('aria-label') || '' };
})()`, true);
if (o.step !== 'saved') await done(`FAIL week: as ${user} (operator) on ${String(pg.name)}: ${JSON.stringify(o).slice(0, 300)}`, 1);
for (let i = 0; i < 50 && !acks.length; i++) await sleep(200);
if (!acks.length) await done(`FAIL week: no POST /api/ack answered in 10 s after Save on ${String(pg.name)}`, 1);
await sleep(300);
const a = acks[0];
const body = await cmd('Network.getResponseBody', { requestId: a.req });
const text = String(body.result?.body ?? '').replace(/\s+/g, ' ').slice(0, 300);
if (a.status === 200 && /"outcome":"done"/.test(text)) await done(`ok   week: an operator's Silence of ${String(pg.name)} with '7 days' picked in the dialog, the page's clock ${AHEAD_MS / 1000} s ahead of the server's: done (${a.status} ${text})`, 0);
await done(`FAIL week: an operator's Silence of ${String(pg.name)} with '7 days' picked, the page's clock ${AHEAD_MS / 1000} s ahead: ${a.status} ${text}`, 1);
