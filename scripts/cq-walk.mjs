// The request queue's click walk (CQ-A): pgvigil serve in queue mode (actions.via queue) over two real servers, a
// headless Chromium clicking what a person clicks. Usage (scripts/proof-cq-walk.sh starts both):
//   node scripts/cq-walk.mjs <cdp port> <base url/> <ui user> <out folder> <sql server id> <postgresql id> <pg tool>
// The UI password comes in CQ_WALK_PW (never an argument). Rows, each 'ok' or 'FAIL' with what the page said:
//   W1 sign in (the login form's own POST /api/login from the page), the root draws
//   W2 / W4 Community tools of the SQL Server / PostgreSQL instance: the tool list, every off control and its words
//   W3 / W5 the tool's name opens its panel, Run sends it through the queue: the status line's words in order
//       (waiting / running on <host> / ran on <host> ... Request <n>.), the result's tables and rows on the page
//   W6 sp_WhoIsActive @delta_interval 30: Run, Cancel while it runs, the status line's end words
//   W7 / W8 the Running pages of both instances in queue mode: every off control and its words
// Writes <out>/clicks.tsv (row, page, clicked, what the page said), <out>/requests.txt (the request ids the walk made,
// one 'row id' per line) and a shot per row (<out>/W<n>-<what>.png). Exit 1 on a FAIL.
const [port, U, user, out, msId, pgId, pgTool] = process.argv.slice(2);
const fs = await import('node:fs');
fs.mkdirSync(out, { recursive: true });
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let seq = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++seq; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 20000) => {
  const t = Date.now();
  while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(200); }
  return null;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1100, deviceScaleFactor: 1, mobile: false });
const shot = async (name) => {
  const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true });
  if (d.result?.data) fs.writeFileSync(`${out}/${name}.png`, Buffer.from(d.result.data, 'base64'));
};
const go = async (hash) => {
  await cmd('Page.navigate', { url: U + hash }); await sleep(400);
  return until(`(() => { const m = document.querySelector('main'); const e = m?.querySelector('p.empty, p.meta');
    return !!m?.querySelector('h2') && !(e && /^Loading/.test(e.textContent)); })()`);
};
const rows = []; let fails = 0;
const row = (r, page, clicked, said, good) => {
  const line = `${good ? 'ok  ' : 'FAIL'} ${r} ${page}: ${clicked} -> ${String(said).replace(/\s+/g, ' ').slice(0, 600)}`;
  console.log(line); if (!good) fails++;
  rows.push([r, page, clicked, String(said).replace(/[\t\n]+/g, ' '), good ? 'ok' : 'FAIL'].join('\t'));
};
const made = [];
// offs: every off control in main, its label and its words (title, else the note it points to)
const offs = () => ev(`[...document.querySelectorAll('main [aria-disabled="true"]')].map(c => {
  const n = c.getAttribute('aria-describedby'); const w = c.title || (n && document.getElementById(n)?.textContent) || '';
  return (c.getAttribute('aria-label') || c.textContent || '').trim().slice(0, 60) + ': ' + w.trim(); })`);
const tools = async (inst) => (await ev(`fetch('/api/community?instance=${inst}', {credentials: 'same-origin'}).then(r => r.json())`))?.tools ?? [];
const panel = (name) => `[...document.querySelectorAll('main section')].find(s => s.querySelector('h3')?.textContent === ${JSON.stringify(name)})`;

// runTool: open the tool's panel by its name, set its inputs, Run, follow the status line to its end
const runTool = async (r, page, tool, inputs = {}, cancelWhenRunning = false) => {
  const opened = await ev(`(() => { const b = [...document.querySelectorAll('main button.link')].find(b => b.textContent === ${JSON.stringify(tool.name)});
    if (!b || b.getAttribute('aria-disabled') === 'true') return false; b.click(); return true; })()`);
  if (!opened) { row(r, page, `the tool ${tool.name}`, 'no clickable tool of that name on the page', false); return null; }
  if (!await until(`!!(${panel(tool.name)})?.querySelector('button')`)) { row(r, page, tool.name, 'its panel never drew', false); return null; }
  for (const [k, v] of Object.entries(inputs)) {
    const set = await ev(`(() => { const i = [...(${panel(tool.name)}).querySelectorAll('input')].find(i => (i.getAttribute('aria-label') ?? '').toLowerCase().includes(${JSON.stringify(k)}));
      if (!i) return false; i.value = ${JSON.stringify(v)}; i.dispatchEvent(new Event('input', {bubbles: true})); return true; })()`);
    if (!set) { row(r, page, `${tool.name} input ${k}`, 'no such input in the panel', false); return null; }
  }
  const runWords = 'Run ' + tool.name;
  const clicked = await ev(`(() => { const b = [...(${panel(tool.name)}).querySelectorAll('button')].find(b => b.textContent === ${JSON.stringify(runWords)});
    if (!b || b.getAttribute('aria-disabled') === 'true') return b ? 'off: ' + (b.title || '') : null; b.click(); return 'clicked'; })()`);
  if (clicked !== 'clicked') { row(r, page, runWords, clicked ?? 'no Run button', false); return null; }
  const seen = []; let cancelled = false; const t0 = Date.now();
  for (;;) {
    const st = await ev(`(() => { const s = (${panel(tool.name)})?.querySelector('p[role="status"]'); return s ? s.textContent : ''; })()`);
    if (st && seen[seen.length - 1] !== st) seen.push(st);
    if (cancelWhenRunning && !cancelled && /^Running on /.test(st)) {
      await shot(`${r}-running`);
      cancelled = await ev(`(() => { const b = [...(${panel(tool.name)}).querySelectorAll('p[role="status"] button')].find(b => b.textContent === 'Cancel'); if (!b) return false; b.click(); return true; })()`);
    }
    if (/Request \d+\.$/.test(st.trim()) && !/^(Waiting|Running) /.test(st) && !/Cancel$/.test(st.trim())) break;
    if (Date.now() - t0 > 150000) break;
    await sleep(100);
  }
  const end = seen[seen.length - 1] ?? '';
  const id = Number((end.match(/Request (\d+)\./) ?? [])[1] ?? 0);
  if (id) made.push(`${r} ${id}`);
  const res = await ev(`(() => { const s = ${panel(tool.name)}; const ts = [...s.querySelectorAll('table')];
    return { tables: ts.length, rows: ts.map(t => t.querySelectorAll('tbody tr').length), err: [...s.querySelectorAll('.error')].map(e => e.textContent).join(' | ').slice(0, 300) }; })()`);
  await shot(`${r}-${tool.id}`);
  return { seen, end, id, res, cancelled };
};

// W1 sign in: the page's own login form
await cmd('Page.navigate', { url: U }); await sleep(800);
const form = await until(`!!document.querySelector('input[type="password"]')`, 15000);
if (form) {
  await ev(`(() => { const u = document.querySelector('input[autocomplete="username"], input[name="username"], input[type="text"]'); const p = document.querySelector('input[type="password"]');
    u.value = ${JSON.stringify(user)}; p.value = ${JSON.stringify(process.env.CQ_WALK_PW ?? '')};
    for (const i of [u, p]) i.dispatchEvent(new Event('input', {bubbles: true}));
    (p.form?.querySelector('button[type="submit"], button') ?? [...document.querySelectorAll('button')].find(b => /sign in|log in/i.test(b.textContent)))?.click(); })()`);
}
const inside = await until(`!document.querySelector('input[type="password"]') && !!document.querySelector('main h2')`, 20000);
await shot('W1-signed-in');
row('W1', 'the sign-in', form ? 'the login form: user, password, its button' : 'no login form drew', inside ? `signed in as ${user}; the page: ${await ev(`document.querySelector('main h2')?.textContent`)}` : 'still on the login form', !!(form && inside));

const enginePages = [['W2', 'W3', msId, 'sp_Blitz', 'SQL Server'], ['W4', 'W5', pgId, pgTool, 'PostgreSQL']];
for (const [rl, rr, inst, toolId, engine] of enginePages) {
  const page = `#/community?i=${inst} (${engine})`;
  if (!await go(`#/community?i=${inst}`)) { row(rl, page, 'the page', 'never drew', false); continue; }
  const ts = await tools(inst);
  const o = await offs();
  await shot(`${rl}-tools`);
  row(rl, page, 'the tool list', `${ts.length} tools; ${o.length} off control(s): ${o.join(' || ') || 'none'}`, ts.length > 0);
  const tool = ts.find(t => t.id === toolId);
  if (!tool) { row(rr, page, toolId, 'not in the instance\'s tool list', false); continue; }
  const r = await runTool(rr, page, tool);
  if (!r) continue;
  const good = r.id > 0 && /^Ran on /.test(r.end) && r.res.tables > 0 && !r.res.err;
  row(rr, page, `${tool.name} -> Run ${tool.name}`, `status: ${r.seen.join(' -> ')}; result: ${r.res.tables} table(s), rows ${JSON.stringify(r.res.rows)}${r.res.err ? '; error: ' + r.res.err : ''}`, good);
}

// W6 Cancel through the queue: sp_WhoIsActive sampling 30 s
{
  const page = `#/community?i=${msId} (SQL Server)`;
  if (await go(`#/community?i=${msId}`)) {
    const tool = (await tools(msId)).find(t => t.id === 'sp_WhoIsActive');
    const r = tool ? await runTool('W6', page, tool, { delta_interval: '30' }, true) : null;
    if (!tool) row('W6', page, 'sp_WhoIsActive', 'not in the tool list', false);
    else if (r) row('W6', page, `sp_WhoIsActive @delta_interval 30 -> Run -> Cancel while it runs`, `status: ${r.seen.join(' -> ')}`, r.cancelled && r.id > 0 && !/^Ran on /.test(r.end));
  } else row('W6', page, 'the page', 'never drew', false);
}

// W7 / W8 the Running pages: the action doors in queue mode
for (const [r, hash, engine] of [['W7', `#/mssql_running?i=${msId}`, 'SQL Server'], ['W8', `#/activity?i=${pgId}`, 'PostgreSQL']]) {
  if (!await go(hash)) { row(r, `${hash} (${engine})`, 'the page', 'never drew', false); continue; }
  await sleep(1500);
  const o = await offs();
  const notes = await ev(`[...document.querySelectorAll('main')].map(m => (m.innerText.match(/[^.\\n]*not through the queue yet[^.\\n]*/g) ?? []).slice(0, 3).join(' | ')).join('')`);
  await shot(`${r}-running-page`);
  row(r, `${hash} (${engine})`, 'the page in queue mode', `${o.length} off control(s): ${o.slice(0, 12).join(' || ') || 'none'}${notes ? '; the page says: ' + notes : ''}`, true);
}

fs.writeFileSync(`${out}/clicks.tsv`, 'row\tpage\tclicked\tthe page said\tgrade\n' + rows.join('\n') + '\n');
fs.writeFileSync(`${out}/requests.txt`, made.join('\n') + '\n');
ws.close();
console.log(fails ? `cq-walk: ${fails} FAIL` : `cq-walk: 0 FAIL, ${rows.length} rows`);
process.exit(fails ? 1 : 0);
