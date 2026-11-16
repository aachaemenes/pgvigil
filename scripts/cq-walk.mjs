// The request queue's click walk (CQ-A): pgvigil serve in queue mode (actions.via queue) over two real servers, a
// headless Chromium clicking what a person clicks. Usage (scripts/proof-cq-walk.sh starts both):
//   node scripts/cq-walk.mjs <cdp port> <base url/> <ui user> <out folder> <sql server id> <postgresql id> <pg tool>
// The UI password comes in CQ_WALK_PW (never an argument). Rows, each 'ok' or 'FAIL' with what the page said:
//   W1 sign in (the login form's own POST /api/login from the page), the root draws
//   W2 / W4 Community tools of the SQL Server / PostgreSQL instance: the tool list, every off control and its words
//   W3 / W5 the tool's name opens its panel, Run sends it through the queue: the status line's words in order
//       (waiting / running on <host> / ran on <host> ... Request <n>.), the result's tables and rows on the page
//   W6 sp_WhoIsActive @delta_interval 50: Run, Cancel once the page says it runs (the page's wait answers at an end
//       or after 25 s; the worker reads a running cancel on its 5 s poll), the status line's end words saying cancel
//       and closed before ' Request <n>.'; the panel's result section: badge 'cancelled' (never 'failed'), its words
//       saying cancel as a note, no error box
//   W7 / W8 the Running pages of both instances in queue mode: every off control and its words
//   W9 sp_WhoIsActive @filter_type 'bogus' (the procedure's own RAISERROR): the status line's end is its words, closed
//       before ' Request <n>.'; the panel: badge 'failed' and the procedure's words in the panel (r10's W6 shot: a
//       queued end's '' refusal hid every failed run's words)
//   G3 / G5 / G6 / G9 (CQ-RUNSGRID) the page's 'Runs on this instance' grid after that row's request ends, with no
//       reload: one row more than just before the Run click, the newest that run's (tool, outcome; G9 the procedure's
//       words in its detail; G6 the outcome as the audit row stores a run cancelled while it ran), and the panel's
//       result badge as it was before the redraw; waits up to 10 s (the log answers 100 rows at most: the walk's
//       instances start empty)
//   G10 (CQ-RUNSGRID) a run whose panel is replaced while it runs (sp_WhoIsActive @delta_interval 8, then another
//       tool's name clicked): the grid still gains that run's row when it ends, up to 30 s
//   S3 (CQ-RUNSGRID) the shot overlay: the walk scrolls to the top for every full-page shot and back after it (a
//       full-page capture of a scrolled page paints the sticky header and tabs where the scroll left them); at the
//       scroll W3's run left (over 0) the sticky header's top is 0 - what put the band in r10 / r11's W3 shot; the
//       viewport there (S3-viewport) and the full-page shot (S3-top) kept
// A run's result counts only as the panel's own result section (section.report-result): its badge 'done' and a table
// with rows (the form's parameter table is not a result). An off control counts only with its words (title and the
// note a person reads); W2 wants one at least (the walk's SQL Server has no Darling Data installed).
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
const shot = async (name, full = true) => {
  // a full-page capture of a scrolled page paints the sticky header where the scroll left it (S3): taken at the top
  const y = full ? await ev('window.scrollY') : 0;
  if (y) { await ev('window.scrollTo(0, 0)'); await sleep(200); }
  const d = await cmd('Page.captureScreenshot', { format: 'png', captureBeyondViewport: full });
  if (y) await ev(`window.scrollTo(0, ${y})`);
  if (d.result?.data) fs.writeFileSync(`${out}/${name}.png`, Buffer.from(d.result.data, 'base64'));
};
const go = async (hash) => {
  // the address the page is already on: loaded again, since a navigation to it draws nothing (rg01's W9)
  if (await ev('location.href') === U + hash) await cmd('Page.reload', {}); else await cmd('Page.navigate', { url: U + hash });
  await sleep(400);
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
  const n = c.getAttribute('aria-describedby'); const note = ((n && document.getElementById(n)?.textContent) || '').trim(); const t = (c.title || '').trim();
  return { label: (c.getAttribute('aria-label') || c.textContent || '').trim().slice(0, 60), words: t && note && note !== t ? t + ' [note: ' + note + ']' : t || note }; })`);
const offWords = (o) => o.map(x => `${x.label}: ${x.words}`).join(' || ') || 'none';
const silent = (o) => o.filter(x => !x.words.trim()).map(x => x.label);
const tools = async (inst) => (await ev(`fetch('/api/community?instance=${inst}', {credentials: 'same-origin'}).then(r => r.json())`))?.tools ?? [];
// panel: the tool's own section - its h3 a direct child and a 'Run <name>' button in it (the page's first group heading
// can carry the tool's name too: sp_WhoIsActive's group is 'sp_WhoIsActive', so the page's own section, whose first h3
// it is, matched before the tool's panel had drawn - r08's W6)
// runsGrid: the 'Runs on this instance' grid as drawn - its data rows and its newest row by the grid's own column
// labels (the box after the heading: the grid itself, or a box holding it; an empty grid has no table.grid)
const runsGrid = () => ev(`(() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent === 'Runs on this instance');
  const b = h?.nextElementSibling; if (!b) return null;
  const t = b.matches('table.grid') ? b : b.querySelector('table.grid');
  if (!t) return { n: 0, first: null, said: b.textContent.trim().slice(0, 200) };
  const heads = [...t.querySelectorAll('thead th')].map(th => (th.querySelector('.th-label')?.textContent ?? th.textContent).trim());
  const trs = t.querySelectorAll('tbody tr'); const c = trs[0] ? [...trs[0].children].map(td => td.textContent.trim()) : [];
  return { n: trs.length, first: Object.fromEntries(heads.map((k, i) => [k, c[i] ?? ''])), said: b.querySelector('.error')?.textContent ?? '' }; })()`);
// gridRow: the grid after a run's end (CQ-RUNSGRID) - it redraws by itself: one row more than before the Run click,
// the newest that run's tool with an outcome in outcomes and good(newest); up to 10 s, no reload
const gridRow = async (g, page, r, tool, outcomes, good = () => true, ms = 10000) => {
  const before = r.before?.n ?? -1; let now = null; const t0 = Date.now();
  while (Date.now() - t0 < ms) { now = await runsGrid(); if (now && now.n > before && now.first?.tool === tool.id) break; await sleep(200); }
  const f = now?.first;
  // the open panel's result stays as it was (only the grid is drawn again)
  const badgeNow = r.res ? await ev(`(() => (${panel(tool.name)})?.querySelector('section.report-result .badge')?.textContent ?? '')()`) : '';
  row(g, page, `the 'Runs on this instance' grid after Request ${r.id}'s end, no reload`,
    `${before} row(s) just before the Run click, ${now?.n ?? 'no grid'} now; newest: ${f ? `${f.what} ${f.tool} ${f.outcome}, rows ${f.rows}, detail '${f.detail}'` : 'none'}${now?.said ? '; the grid says: ' + now.said : ''}${r.res ? `; the panel's badge '${badgeNow}' (was '${r.res.badge}')` : ''}`,
    !!(now && before >= 0 && now.n === before + 1 && f?.tool === tool.id && outcomes.includes(f?.outcome) && good(f) && (!r.res || badgeNow === r.res.badge)));
};
const panel = (name) => `[...document.querySelectorAll('main section')].find(s => s.querySelector(':scope > h3')?.textContent === ${JSON.stringify(name)}
  && [...s.querySelectorAll('button')].some(b => b.textContent === ${JSON.stringify('Run ' + name)}))`;

// runTool: open the tool's panel by its name, set its inputs, Run, follow the status line to its end
const runTool = async (r, page, tool, inputs = {}, cancelWhenRunning = false) => {
  const opened = await ev(`(() => { const b = [...document.querySelectorAll('main button.link')].find(b => b.textContent === ${JSON.stringify(tool.name)});
    if (!b || b.getAttribute('aria-disabled') === 'true') return false; b.click(); return true; })()`);
  if (!opened) { row(r, page, `the tool ${tool.name}`, 'no clickable tool of that name on the page', false); return null; }
  if (!await until(`!!(${panel(tool.name)})`)) { row(r, page, tool.name, 'its panel never drew', false); await shot(`${r}-no-panel`); return null; }
  for (const [k, v] of Object.entries(inputs)) {
    const set = await ev(`(() => { const i = [...(${panel(tool.name)}).querySelectorAll('input')].find(i => { const l = (i.getAttribute('aria-label') ?? '').toLowerCase(); return l === ${JSON.stringify('@' + k)} || l.startsWith(${JSON.stringify('@' + k + ' (')}); });
      if (!i) return false; i.value = ${JSON.stringify(v)}; i.dispatchEvent(new Event('input', {bubbles: true})); return true; })()`);
    if (!set) {
      const labels = await ev(`[...(${panel(tool.name)}).querySelectorAll('input')].map(i => i.getAttribute('aria-label')).slice(0, 40).join(', ')`);
      row(r, page, `${tool.name} input ${k}`, `no such input in the panel (its inputs: ${labels})`, false); await shot(`${r}-no-input`); return null;
    }
  }
  const runWords = 'Run ' + tool.name;
  const before = await runsGrid();   // the runs grid just before the click (G rows)
  const clicked = await ev(`(() => { const b = [...(${panel(tool.name)}).querySelectorAll('button')].find(b => b.textContent === ${JSON.stringify(runWords)});
    if (!b || b.getAttribute('aria-disabled') === 'true') return b ? 'off: ' + (b.title || '') : null; b.click(); return 'clicked'; })()`);
  if (clicked !== 'clicked') { row(r, page, runWords, clicked ?? 'no Run button', false); return null; }
  const seen = []; let cancelled = false; const t0 = Date.now();
  for (;;) {
    const st = await ev(`(() => { const s = (${panel(tool.name)})?.querySelector(':scope > p[role="status"]'); return s ? s.textContent : ''; })()`);
    if (st && seen[seen.length - 1] !== st) seen.push(st);
    if (cancelWhenRunning && !cancelled && /^Running on /.test(st)) {
      cancelled = await ev(`(() => { const b = [...(${panel(tool.name)}).querySelectorAll(':scope > p[role="status"] button')].find(b => b.textContent === 'Cancel'); if (!b) return false; b.click(); return true; })()`);
      if (cancelled) await shot(`${r}-cancel-asked`);
    }
    if (/Request \d+\.$/.test(st.trim()) && !/^(Waiting|Running) /.test(st) && !/Cancel$/.test(st.trim())) break;
    if (Date.now() - t0 > 150000) break;
    await sleep(100);
  }
  const end = seen[seen.length - 1] ?? '';
  const id = Number((end.match(/Request (\d+)\./) ?? [])[1] ?? 0);
  if (id) made.push(`${r} ${id}`);
  const res = await ev(`(() => { const s = ${panel(tool.name)}; const x = s?.querySelector('section.report-result');
    if (!x) return { badge: '', tables: 0, rows: [], err: 'no result section', note: '' };
    const ts = [...x.querySelectorAll('table')].filter(t => !t.classList.contains('grid-empty'));
    return { badge: x.querySelector('.badge')?.textContent ?? '', tables: ts.length, rows: ts.map(t => t.querySelectorAll('tbody tr').length),
      err: [...x.querySelectorAll('.error')].map(e => e.textContent).join(' | ').slice(0, 300),
      note: [...x.querySelectorAll('p.empty, p.refused')].map(e => e.textContent).join(' | ').slice(0, 300) }; })()`);
  await shot(`${r}-${tool.id}`);
  return { seen, end, id, res, cancelled, before };
};

// fenced: a row that throws is a FAIL row with the error's words, and the walk goes on
const fenced = async (r, page, fn) => { try { await fn(); } catch (e) { row(r, page, 'the row', `the walk itself failed here: ${String(e?.message ?? e).slice(0, 300)}`, false); } };
// W1 sign in: the page's own login form
await fenced('W1', 'the sign-in', async () => {
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
});

const enginePages = [['W2', 'W3', msId, 'sp_Blitz', 'SQL Server', true], ['W4', 'W5', pgId, pgTool, 'PostgreSQL', false]];
for (const [rl, rr, inst, toolId, engine, needOff] of enginePages) {
  const page = `#/community?i=${inst} (${engine})`;
  let ts = [];
  await fenced(rl, page, async () => {
    if (!await go(`#/community?i=${inst}`)) { row(rl, page, 'the page', 'never drew', false); return; }
    ts = await tools(inst);
    const o = await offs();
    await shot(`${rl}-tools`);
    const mute = silent(o);
    row(rl, page, 'the tool list', `${ts.length} tools; ${o.length} off control(s): ${offWords(o)}${mute.length ? '; WITHOUT WORDS: ' + mute.join(', ') : ''}`,
      ts.length > 0 && !mute.length && (!needOff || o.length > 0));
  });
  await fenced(rr, page, async () => {
    const tool = ts.find(t => t.id === toolId);
    if (!tool) { row(rr, page, toolId, 'not in the instance\'s tool list', false); return; }
    const r = await runTool(rr, page, tool);
    if (!r) return;
    const good = r.id > 0 && /^Ran on /.test(r.end) && r.res.badge === 'done' && r.res.tables > 0 && r.res.rows.some(n => n > 0) && !r.res.err;
    row(rr, page, `${tool.name} -> Run ${tool.name}`, `status: ${r.seen.join(' -> ')}; result: badge '${r.res.badge}', ${r.res.tables} table(s), rows ${JSON.stringify(r.res.rows)}${r.res.err ? '; error: ' + r.res.err : ''}${r.res.note ? '; note: ' + r.res.note : ''}`, good);
    await gridRow('G' + rr.slice(1), page, r, tool, ['done']);
    if (rr !== 'W3') return;
    // S3: the shot overlay - at the scroll the run left, the sticky header is engaged (its top 0, the page under it):
    // a full-page capture there paints it at that scroll, which put the band in r10 / r11's W3 shot; shot() now
    // takes every full-page shot at the top
    const m = await ev(`(() => { const h = document.querySelector('header')?.getBoundingClientRect(); const i = document.querySelector('main .community-intro')?.getBoundingClientRect();
      return h && i ? { y: Math.round(window.scrollY), ht: Math.round(h.top), hb: Math.round(h.bottom), it: Math.round(i.top) } : null; })()`);
    await shot('S3-viewport', false);
    await shot('S3-top');
    const top = await ev('Math.round(window.scrollY)');
    row('S3', page, 'the shot overlay: the sticky header at the scroll the run left; every full-page shot taken at the top',
      m ? `scrollY ${m.y}: the header's top ${m.ht} px, its bottom ${m.hb} px, the instance line at ${m.it} px (scrolled under it); the scroll back at ${top} after the shots` : 'no header or no instance line on the page',
      !!m && m.y > 0 && m.ht === 0 && m.it < m.hb && top === m.y);
  });
}

// W6 Cancel through the queue: sp_WhoIsActive sampling 50 s (inside the form's 60 s timeout)
await fenced('W6', `#/community?i=${msId} (SQL Server)`, async () => {
  const page = `#/community?i=${msId} (SQL Server)`;
  if (!await go(`#/community?i=${msId}`)) { row('W6', page, 'the page', 'never drew', false); return; }
  const tool = (await tools(msId)).find(t => t.id === 'sp_WhoIsActive');
  if (!tool) { row('W6', page, 'sp_WhoIsActive', 'not in the tool list', false); return; }
  const r = await runTool('W6', page, tool, { delta_interval: '50' }, true);
  if (r) row('W6', page, `sp_WhoIsActive @delta_interval 50 -> Run -> Cancel while it runs`,
    `status: ${r.seen.join(' -> ')}; result: badge '${r.res.badge}'${r.res.err ? '; error: ' + r.res.err : ''}${r.res.note ? '; note: ' + r.res.note : ''}`,
    r.cancelled && r.id > 0 && !/^Ran on /.test(r.end) && /cancel/i.test(r.end) && /[.!?] Request \d+\.$/.test(r.end.trim())
      && r.res.badge === 'cancelled' && /cancel/i.test(r.res.note) && !r.res.err);
  // the audit row of a run cancelled while it ran: its outcome as stored ('failed' today), the row there
  if (r) await gridRow('G6', page, r, tool, ['failed', 'cancelled']);
});

// W9 a run that fails through the queue: sp_WhoIsActive's own refusal of a filter type it does not know
await fenced('W9', `#/community?i=${msId} (SQL Server)`, async () => {
  const page = `#/community?i=${msId} (SQL Server)`;
  if (!await go(`#/community?i=${msId}`)) { row('W9', page, 'the page', 'never drew', false); return; }
  const tool = (await tools(msId)).find(t => t.id === 'sp_WhoIsActive');
  if (!tool) { row('W9', page, 'sp_WhoIsActive', 'not in the tool list', false); return; }
  const r = await runTool('W9', page, tool, { filter_type: 'bogus' });
  if (r) row('W9', page, `sp_WhoIsActive @filter_type bogus -> Run`,
    `status: ${r.seen.join(' -> ')}; result: badge '${r.res.badge}'${r.res.err ? '; error: ' + r.res.err : ''}${r.res.note ? '; note: ' + r.res.note : ''}`,
    r.id > 0 && /Valid filter types/.test(r.end) && /[.!?] Request \d+\.$/.test(r.end.trim()) && r.res.badge === 'failed' && /Valid filter types/.test(r.res.err));
  if (r) await gridRow('G9', page, r, tool, ['failed'], f => /Valid filter types/.test(f.detail));
});

// G10 a run whose panel is replaced while it runs: the grid still gains its row when it ends (review finding 1)
await fenced('G10', `#/community?i=${msId} (SQL Server)`, async () => {
  const page = `#/community?i=${msId} (SQL Server)`;
  if (!await go(`#/community?i=${msId}`)) { row('G10', page, 'the page', 'never drew', false); return; }
  const ts = await tools(msId);
  const tool = ts.find(t => t.id === 'sp_WhoIsActive'), other = ts.find(t => t.id === 'sp_Blitz');
  if (!tool || !other) { row('G10', page, 'sp_WhoIsActive and sp_Blitz', 'not both in the tool list', false); return; }
  const click = (name) => ev(`(() => { const b = [...document.querySelectorAll('main button.link')].find(b => b.textContent === ${JSON.stringify(name)}); if (!b) return false; b.click(); return true; })()`);
  if (!await click(tool.name) || !await until(`!!(${panel(tool.name)})`)) { row('G10', page, tool.name, 'its panel never drew', false); return; }
  await ev(`(() => { const i = [...(${panel(tool.name)}).querySelectorAll('input')].find(i => (i.getAttribute('aria-label') ?? '').toLowerCase().startsWith('@delta_interval')); i.value = '8'; i.dispatchEvent(new Event('input', {bubbles: true})); })()`);
  const before = await runsGrid();
  await ev(`[...(${panel(tool.name)}).querySelectorAll('button')].find(b => b.textContent === ${JSON.stringify('Run ' + tool.name)}).click()`);
  const st = await until(`(() => { const s = (${panel(tool.name)})?.querySelector(':scope > p[role="status"]')?.textContent ?? ''; return /^Running on /.test(s) ? s : ''; })()`, 30000);
  const id = Number(((st ?? '').match(/Request (\d+)\./) ?? [])[1] ?? 0);
  if (id) made.push(`G10 ${id}`);
  if (!st || !await click(other.name) || !await until(`!!(${panel(other.name)}) && !(${panel(tool.name)})`)) { row('G10', page, `${tool.name} -> Run, then ${other.name}`, `the run never showed running (${st}) or the other panel never replaced it`, false); return; }
  await gridRow('G10', page, { id, before, res: null }, tool, ['done'], () => true, 30000);
});

// W7 / W8 the Running pages: the action doors in queue mode
for (const [r, hash, engine] of [['W7', `#/mssql_running?i=${msId}`, 'SQL Server'], ['W8', `#/activity?i=${pgId}`, 'PostgreSQL']]) {
  await fenced(r, `${hash} (${engine})`, async () => {
    if (!await go(hash)) { row(r, `${hash} (${engine})`, 'the page', 'never drew', false); return; }
    await sleep(1500);
    const o = await offs();
    const notes = await ev(`[...document.querySelectorAll('main')].map(m => (m.innerText.match(/[^.\\n]*not through the queue yet[^.\\n]*/g) ?? []).slice(0, 3).join(' | ')).join('')`);
    await shot(`${r}-running-page`);
    const mute = silent(o);
    row(r, `${hash} (${engine})`, 'the page in queue mode', `${o.length} off control(s): ${offWords(o.slice(0, 12))}${mute.length ? '; WITHOUT WORDS: ' + mute.join(', ') : ''}${notes ? '; the page says: ' + notes : ''}`, !mute.length);
  });
}

fs.writeFileSync(`${out}/clicks.tsv`, 'row\tpage\tclicked\tthe page said\tgrade\n' + rows.join('\n') + '\n');
fs.writeFileSync(`${out}/requests.txt`, made.join('\n') + '\n');
ws.close();
console.log(fails ? `cq-walk: ${fails} FAIL` : `cq-walk: 0 FAIL, ${rows.length} rows`);
process.exit(fails ? 1 : 0);
