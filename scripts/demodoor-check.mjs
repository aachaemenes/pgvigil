// The demo's write door in a browser that CLICKS (task B7; run by scripts/proof-demodoor.sh).
//   node scripts/demodoor-check.mjs <cdp port> <base url> <the real instance's name> [<folder for the shots> [<the rig, JSON>]]
//   the rig: { jobs: [{ id, name, tab }] the demo instances with a failed job run, seed: the instance of the seed's own
//   silence, tagged: a real instance tagged demo by hand, stale: an instance with the demo's tag and name prefix that
//   this demo process did not seed, real_id: the real instance's id (the proof gave it failed jobs and crash
//   restarts), gone: an alert channel the configuration no longer names, nologin: the base url of a pgvigil serve
//   -no-login on the same repository } - each as the proof read or made it.
// It drives the page as a visitor of `pgvigil demo -serve` would: a click, the dialog's Save, the page after it - and
// reads the acknowledge log beside it: a click that writes must leave EXACTLY the log rows it names above the newest
// one read before it (one; a dialog's N; the page's N - a Save bound twice writes two and fails), each of the kind,
// the operation and the instance the click names. A row waits for its OWN condition on the page (the state it then
// judges, polled for up to 15 s and read again once it holds), never a fixed time and one read: the proof runs
// beside others on a shared box. Every line is 'ok   <row>: ...' or 'FAIL <row>: ...'; a row that cannot find its
// control says what the page held instead. Exit 1 when any row failed.
// Needs node 22 or later (the global WebSocket and fetch).
import { mkdirSync, writeFileSync } from 'node:fs';
const [port, U, REAL, SHOTS, RIG] = process.argv.slice(2);
const rig = RIG ? JSON.parse(RIG) : {};
const failedJobs = rig.jobs ?? [], SEED = rig.seed ?? '', TAGGED = rig.tagged ?? '', NOLOGIN = rig.nologin ?? '';
const STALE = rig.stale ?? '', REAL_ID = Number(rig.real_id ?? 0), GONE = rig.gone ?? '';
if (SHOTS) mkdirSync(SHOTS, { recursive: true });

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
// a command the browser never answers (a hung renderer, a native dialog) ends the script with an error after 30 s,
// never a wait without end
const cmd = (method, params = {}) => new Promise((res, rej) => {
  const i = ++id;
  const t = setTimeout(() => { wait.delete(i); rej(new Error(`the browser did not answer ${method} in 30 s`)); }, 30000);
  wait.set(i, d => { clearTimeout(t); res(d); });
  ws.send(JSON.stringify({ id: i, method, params }));
});
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 15000) => {
  const t = Date.now();
  while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(150); }
  return null;
};
// the page is drawn: main holds something and no 'Loading' line (an expression, for use inside a row's own read)
const drawnJS = `(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty');
  return !(e && /^Loading/.test(e.textContent)) && m.children.length > 0; })()`;
const settled = () => until(drawnJS);
// a row's own condition: read() is polled until good(what it read) holds - and holds again 250 ms later, so a page
// caught half drawn is not taken - for up to ms; the last read is returned either way and the row judges on it
const reach = async (read, good, ms = 15000) => {
  const t = Date.now(); let v = await read();
  for (;;) {
    if (good(v)) { await sleep(250); v = await read(); if (good(v)) return v; }
    if (Date.now() - t >= ms) return v;
    await sleep(200); v = await read();
  }
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
const goTo = async (base, hash) => { await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: base + hash }); await sleep(400); await settled(); await sleep(600); };
const go = (hash) => goTo(U, hash);

let fails = 0;
const ok = (row, text) => console.log(`ok   ${row}: ${text}`);
const fail = (row, text) => { fails++; console.log(`FAIL ${row}: ${text}`); };
const judge = (row, good, text) => (good ? ok : fail)(row, text);

// a shot of the page as it stands (kept by the proof: what a visitor sees before and after a click); one that could
// not be taken is a FAIL line at the end, never a silent gap
const shotsMissed = [];
const shot = async (name) => {
  if (!SHOTS) return;
  const d = await cmd('Page.captureScreenshot', { format: 'png' });
  if (d.result?.data) writeFileSync(`${SHOTS}/${name}.png`, Buffer.from(d.result.data, 'base64')); else shotsMissed.push(name);
};

// the page's own fetch, so the header rule and the Host are the browser's
const api = (path) => ev(`fetch(${JSON.stringify('/api/' + path)}).then(r => r.json())`, true);
const tbl = (t) => (t?.rows ?? []).map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])));
// the acknowledge log, newest first, and what a click wrote: EVERY row above the newest one read before the click
// (the whole log, were that row no longer in it: the count then cannot fit and the row fails). wrote waits until the
// rows the click names are there (n), then until two reads 300 ms apart agree - a second write of a Save bound twice
// lands beside the first - and returns them all; a click that wrote nothing gives none, never an earlier click's row
const logRows = async () => tbl((await api('ack?part=log')).log);
const logKey = (l) => `${l.at}|${l.op}|${l.kind}|${l.ack_id}|${l.instance}`;
const mark = async () => logKey((await logRows())[0] ?? {});
const since = (rows, before) => { const i = rows.findIndex(l => logKey(l) === before); return i < 0 ? rows : rows.slice(0, i); };
const wrote = async (before, n = 1) => {
  const t = Date.now(); let a = since(await logRows(), before);
  while (a.length < n && Date.now() - t < 10000) { await sleep(200); a = since(await logRows(), before); }
  for (let i = 0; i < 10; i++) { await sleep(300); const b = since(await logRows(), before); if (b.length === a.length) return b; a = b; }
  return a;
};
const logLine = (l) => l ? `${l.ui_user} / ${l.client} / ${l.kind} / ${l.op} / ${l.outcome} / ${l.instance}` : 'no row';
// what a click wrote, for the row's line: the count and each row (the first four of many)
const logSaid = (ls) => `${ls.length} new log row(s)` + (ls.length ? `: ${ls.slice(0, 4).map(logLine).join(' | ')}${ls.length > 4 ? ' | ...' : ''}` : '');
const byDoor = (l, kind, op, instance) => !!l && l.ui_user === 'demo' && l.client === 'demo door' && l.kind === kind && l.op === op && l.outcome === 'done' && (Array.isArray(instance) ? instance.includes(String(l.instance)) : l.instance === instance);
// exactly n rows, every one the door's of this kind and operation for this instance (or one of these instances)
const allByDoor = (ls, n, kind, op, instance) => n > 0 && ls.length === n && ls.every(l => byDoor(l, kind, op, instance));
// a dialog's answer: 'done N of N saved' (never 'not saved ...' or 'partly done ...'), 'done ended'
const saved = (a) => { const m = /^done (\d+) of (\d+) saved$/.exec(a ?? ''); return !!m && m[1] === m[2]; };
const ended = (a) => a === 'done ended';
// the visible words an off control points at (aria-describedby), '' when it has none or they are not on the page
const offWordsJS = `(b) => { const n = b && b.getAttribute('aria-describedby') ? document.getElementById(b.getAttribute('aria-describedby')) : null;
  return n && n.offsetParent !== null ? n.textContent.trim() : ''; }`;
// the open write dialog: fill what it needs, Save, read its answer, Close - and wait until it is gone. What the page
// shows after it is the calling row's own condition to wait for
const dialogOpenJS = `!!document.querySelector('dialog.act-dialog[open]')`;
const saveDialog = async (note) => {
  const open = await until(dialogOpenJS);
  if (!open) return { opened: false, answer: '' };
  const title = await ev(`document.querySelector('dialog.act-dialog[open] h3')?.textContent ?? ''`);
  if (note) await ev(`(() => { const t = document.querySelector('dialog.act-dialog[open] textarea'); if (t) { t.value = ${JSON.stringify(note)}; t.dispatchEvent(new Event('input', { bubbles: true })); } })()`);
  await ev(`document.querySelector('dialog.act-dialog[open] button[type=submit]').click()`);
  const answer = await until(`(() => { const p = document.querySelector('dialog.act-dialog[open] p[role=status]'); const t = p ? p.textContent.trim() : ''; return t && t !== 'Saving...' ? t : ''; })()`, 15000) ?? '';
  await ev(`(() => { const b = [...document.querySelectorAll('dialog.act-dialog[open] button[type=button]')].find(x => /Close|Back/.test(x.textContent)); if (b) b.click(); })()`);
  await until(`!document.querySelector('dialog.act-dialog[open]')`);
  return { opened: true, title, answer };
};
// click the one button of main with this exact aria-label (and, when given, this text) that is on
const clickLabel = (label, text) => ev(`(() => { const b = [...document.querySelectorAll('main button[aria-label]')].find(x => x.getAttribute('aria-label') === ${JSON.stringify(label)}
  && ${text ? `x.textContent.trim() === ${JSON.stringify(text)} &&` : ''} x.getAttribute('aria-disabled') !== 'true' && !x.disabled); if (!b) return false; b.click(); return true; })()`);
const labelJS = (label) => `[...document.querySelectorAll('main button[aria-label]')].some(x => x.getAttribute('aria-label') === ${JSON.stringify(label)})`;
const hasLabel = (label) => ev(labelJS(label));
// the acknowledged cells on the page, -1 while the page is not drawn (a redraw in flight is never read as 'none')
const ackCells = () => ev(`${drawnJS} ? document.querySelectorAll('main .ack').length : -1`);

// the Summary's toolbar: Options, then the items named, each clicked once it is drawn (a submenu is drawn by its
// parent's click). The page's own 30 s refresh drops an open menu: an item that has not appeared in 1.5 s means the
// menu went away under the walk, and the whole walk is done ONCE more from Options (the last item acts, so a walk
// that reached it is never repeated). ok, and in words what happened
const menuWalk = async (...items) => {
  let said = '';
  for (let attempt = 1; attempt <= 2; attempt++) {
    const o = await until(`(() => { const b = [...document.querySelectorAll('button.tb-btn')].find(x => x.textContent.trim() === 'Options'); if (!b) return false; b.click(); return true; })()`, 5000);
    if (!o) { said = 'no Options button in the toolbar'; continue; }
    let missed = '';
    for (const re of items) {
      const hit = await until(`(() => { const b = [...document.querySelectorAll('[role=menu] [role=menuitem]')].find(x => ${re}.test(x.textContent)); if (!b) return false; b.click(); return true; })()`, 1500);
      if (hit !== true) { missed = `no item ${re} in the menu, which held ${JSON.stringify(await ev(`[...document.querySelectorAll('[role=menu] [role=menuitem]')].map(x => x.textContent)`))}`; break; }
    }
    if (!missed) return { ok: true, said: `Options > ${items.length} item(s) clicked${attempt > 1 ? ` on the second walk (the first: ${said})` : ''}` };
    said = missed;
  }
  return { ok: false, said };
};
const dumpDlg = `document.querySelector('dialog.act-dialog[open][aria-label="Memory Dump Thresholds"]')`;
const openDump = async () => {
  const w = await menuWalk('/^Memory Dumps/', '/^Configure Thresholds/');
  return { menus: w.said, open: w.ok ? !!(await until(`!!${dumpDlg}`)) : false };
};
const closeDump = async () => { await ev(`${dumpDlg}?.querySelector('button[aria-label=Close]')?.click()`); await until(`!${dumpDlg}`); };
// the dialog's Clear as it stands: on or off, how it is off, its words, and the date beside it
const dumpClear = () => ev(`(() => { const off = ${offWordsJS}; const b = [...(${dumpDlg}?.querySelectorAll('button') ?? [])].find(x => x.textContent.trim() === 'Clear'); if (!b) return null;
  return { off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled, words: off(b), date: b.parentElement?.previousElementSibling?.textContent.trim() ?? '' }; })()`);

// ---- the door, as the page is told
const ack0 = await (async () => { await go('#/summary'); return api('ack?part=acks'); })();
const doorIds = ack0.door?.instances ?? [];
judge('door', ack0.writable === false && ack0.door?.user === 'demo' && doorIds.length > 0,
  `GET /api/ack: writable ${ack0.writable}, door user '${ack0.door?.user}', ${doorIds.length} instance(s)`);
const doorNames = tbl(await api('instances')).filter(i => doorIds.includes(Number(i.instance_id))).map(i => String(i.name));
const seatJS = `document.querySelector('[data-part=seat]')?.textContent ?? ''`;
const seat = await until(seatJS) ?? '';   // the footer's seat is filled when its own read ends
judge('seat', /saved as user demo/.test(seat) && /nothing reaches a server/.test(seat), `the footer says whose door this is: '${seat}'`);

// ---- R1 the Summary's strip: Acknowledge on the first line that needs attention
const strip = await ev(`[...document.querySelectorAll('.attention-row')].map(r => { const b = r.querySelector('button[aria-label^="Acknowledge "]');
  const m = /[?&]i=(\\d+)/.exec(r.querySelector('strong a')?.getAttribute('href') ?? '');
  return { name: r.querySelector('strong')?.textContent.trim() ?? '', id: m ? Number(m[1]) : 0, btn: !!b, off: b?.getAttribute('aria-disabled') === 'true' || !!b?.disabled }; })`);
await shot('1-summary-before');
// what Allen saw under the strip at 19:03: 'Acknowledge is off: acknowledgements need the UI login: this server runs with -no-login'
const offSaid = await ev(`(/Acknowledge is off[^.]*/.exec(document.querySelector('main')?.textContent ?? '') ?? [''])[0]`);
const line = (strip ?? []).find(r => r.btn && !r.off && r.name !== REAL);
let acked = '';
if (!line) fail('R1', `no line of the strip has an Acknowledge that is on: ${JSON.stringify((strip ?? []).slice(0, 6))}`);
else {
  const before = await ackCells(), m0 = await mark();
  await ev(`[...document.querySelectorAll('.attention-row')].find(r => r.querySelector('strong')?.textContent.trim() === ${JSON.stringify(line.name)}).querySelector('button[aria-label^="Acknowledge "]').click()`);
  await until(dialogOpenJS); await shot('2-summary-acknowledge-dialog');
  const d = await saveDialog('demo door proof');
  // its own condition: the line has left the strip, more cells read acknowledged, its checks are listed
  const page = await reach(async () => ({ cells: await ackCells(),
    still: await ev(`[...document.querySelectorAll('.attention-row strong')].some(s => s.textContent.trim() === ${JSON.stringify(line.name)})`),
    listed: await ev(`[...document.querySelectorAll('main details li')].filter(li => li.textContent.includes(${JSON.stringify(line.name)}) && /acknowledged by demo/.test(li.textContent)).length`) }),
    v => v.cells > before && !v.still && v.listed > 0);
  await shot('3-summary-after-acknowledge');
  // the dialog saves one acknowledgement per cell of the line: N of N, and the log gains exactly those N rows
  const n = Number((/^done (\d+) of \d+ saved$/.exec(d.answer ?? '') ?? [])[1] ?? 0);
  const logs = await wrote(m0, n);
  acked = line.name;
  judge('R1', !offSaid && d.opened && saved(d.answer) && !page.still && page.cells > before && page.listed > 0 && allByDoor(logs, n, 'ack', 'add', line.name),
    `${line.name}: the page says 'Acknowledge is off' nowhere (${offSaid ? `it says '${offSaid}'` : 'true'}); the dialog '${d.title}' answered '${d.answer}'; its line left the strip (${!page.still}); acknowledged cells ${before} -> ${page.cells}; ${page.listed} of its checks listed 'acknowledged by demo'; ${logSaid(logs)} (want ${n}, each demo / demo door / ack / add / done / ${line.name})`);
}

// ---- R1b a DEMO instance's own pages. An instance's own Summary page draws no Acknowledge (the strip with it is the
// fleet Summary's; vis-b7a printed that page's buttons), so the row clicks what an instance's pages do offer:
// (a) the header's Silence, then Unsilence, on its Summary page; (b) the Acknowledge of a failed job on its Jobs page.
// The instance is one with a failed job run - another than R1's and than the one the seed silenced, where there is
// one (an instance the seed silenced starts with Unsilence: the row then ends that silence first and silences after,
// and says so in its line).
{
  const inst = failedJobs.find(j => j.name !== acked && j.name !== SEED) ?? failedJobs.find(j => j.name !== SEED) ?? failedJobs[0];
  if (!inst) fail('R1b', `the repository holds no demo instance with a failed job run (the proof's own read: ${JSON.stringify(failedJobs)}): no Acknowledge under an instance to click`);
  else {
    const head = () => ev(`(() => { const h = document.querySelector('.inst-header'); if (!h) return { found: false, hash: location.hash };
      const b = h.querySelector('button.silence-btn');
      return { found: true, hash: location.hash, name: h.querySelector('.inst-name')?.textContent.trim() ?? '', btn: b ? b.textContent.trim() : '',
        off: !b || b.getAttribute('aria-disabled') === 'true' || b.disabled, bell: !!h.querySelector('.silenced-bell') }; })()`);
    const headClick = (text) => ev(`(() => { const b = document.querySelector('.inst-header button.silence-btn');
      if (!b || b.textContent.trim() !== ${JSON.stringify(text)} || b.getAttribute('aria-disabled') === 'true' || b.disabled) return false; b.click(); return true; })()`);
    // (a) the header of the instance's own Summary page
    await go(`#/summary?i=${inst.id}`);
    const h0 = await reach(head, v => v.found && v.name === inst.name && ['Silence', 'Unsilence'].includes(v.btn));
    await shot('4-instance-page-before');
    if (!h0.found || h0.name !== inst.name || h0.off || !['Silence', 'Unsilence'].includes(h0.btn))
      fail('R1b-a', `${inst.name}'s own page (#/summary?i=${inst.id}): the header's Silence is not there, or off: ${JSON.stringify(h0)}`);
    else {
      const steps = [];
      for (const want of (h0.btn === 'Silence' ? ['Silence', 'Unsilence'] : ['Unsilence', 'Silence'])) {
        const m0 = await mark();
        const clicked = await headClick(want);
        const d = clicked ? await saveDialog(want === 'Silence' ? 'demo door proof, the instance page' : undefined) : { opened: false, answer: '' };
        // its own condition: the header shows the other button, with the silenced mark after Silence and without it after Unsilence
        const next = want === 'Silence' ? 'Unsilence' : 'Silence';
        const h = await reach(head, v => v.found && v.btn === next && v.bell === (want === 'Silence'), clicked ? 15000 : 0);
        const logs = clicked ? await wrote(m0, 1) : [];
        await shot(want === 'Silence' ? '4b-instance-page-silenced' : '4c-instance-page-unsilenced');
        steps.push({ want, clicked, answer: d.answer, log: logSaid(logs), bell: !!h.bell, next: h.btn,
          good: clicked && d.opened && (want === 'Silence' ? saved(d.answer) && allByDoor(logs, 1, 'silence', 'add', inst.name) && h.bell === true && h.btn === 'Unsilence'
            : ended(d.answer) && allByDoor(logs, 1, 'silence', 'end', inst.name) && h.bell === false && h.btn === 'Silence') });
      }
      judge('R1b-a', steps.every(x => x.good), `${inst.name}'s own page (${h0.hash}), the header: ` + steps.map(x =>
        `'${x.want}' clicked ${x.clicked}, answered '${x.answer}', the header then ${x.bell ? 'with' : 'without'} the silenced mark and '${x.next}', ${x.log} (want 1)`).join('; '));
    }
    // (b) the Acknowledge of a failed job on the instance's own Jobs page
    await go(`#/${inst.tab}?i=${inst.id}`);
    const jobBtn = `[...document.querySelectorAll('main button[aria-label^="Acknowledge "]')].find(x => x.textContent.trim() === 'Acknowledge' && x.getAttribute('aria-disabled') !== 'true' && !x.disabled)`;
    await until(`!!(${jobBtn})`, 15000);
    // the grid is wider than the window: the job's cell is brought into view for the shot
    await ev(`(${jobBtn})?.scrollIntoView({ block: 'center', inline: 'center' })`); await sleep(200);
    await shot('5-instance-jobs-before');
    const m0 = await mark();
    const job = await ev(`(() => { const b = ${jobBtn};
      if (!b) return { clicked: false, hash: location.hash, h2: document.querySelector('main h2')?.textContent ?? '', buttons: [...document.querySelectorAll('main button')].map(x => x.textContent.trim() + (x.getAttribute('aria-disabled') === 'true' || x.disabled ? ' (off)' : '')).filter(Boolean).slice(0, 40) };
      const label = b.getAttribute('aria-label'); b.click(); return { clicked: true, hash: location.hash, label }; })()`);
    if (!job.clicked) fail('R1b-b', `${inst.name}'s Jobs page (${job.hash}, '${job.h2}') has no Acknowledge that is on; its buttons: ${JSON.stringify(job.buttons)}`);
    else {
      await until(dialogOpenJS); await shot('5b-instance-jobs-acknowledge-dialog');
      const d = await saveDialog();
      const clear = 'Clear the acknowledgement of ' + job.label.replace(/^Acknowledge /, '');
      const cell = await until(`(() => { const c = [...document.querySelectorAll('main button[aria-label]')].find(x => x.getAttribute('aria-label') === ${JSON.stringify(clear)});
        return c ? { text: c.parentElement.textContent.trim(), clearOn: c.getAttribute('aria-disabled') !== 'true' && !c.disabled } : null; })()`);
      const again = await hasLabel(job.label);
      await ev(`[...document.querySelectorAll('main button[aria-label]')].find(x => x.getAttribute('aria-label') === ${JSON.stringify(clear)})?.scrollIntoView({ block: 'center', inline: 'center' })`); await sleep(200);
      await shot('5c-instance-jobs-acknowledged');
      const logs = await wrote(m0, 1);
      judge('R1b-b', d.opened && saved(d.answer) && !!cell && cell.clearOn && /^acknowledged /.test(cell.text) && !again && allByDoor(logs, 1, 'job', 'add', inst.name),
        `${inst.name}'s Jobs page (${job.hash}): '${job.label}' clicked, '${d.title}' answered '${d.answer}'; its cell then reads '${cell?.text ?? ''}' (Clear on: ${cell?.clearOn ?? false}), the Acknowledge button gone (${!again}); ${logSaid(logs)} (want 1)`);
    }
    await go('#/summary');
  }
}

// ---- R3 Unacknowledge one of them from the acknowledged list: the cell is back
if (acked) {
  await ev(`(() => { const d = [...document.querySelectorAll('main details')].find(x => /acknowledged check/.test(x.querySelector('summary')?.textContent ?? '')); if (d) d.open = true; })()`);
  const before = await reach(ackCells, v => v > 0), m0 = await mark();
  const found = await ev(`(() => { const li = [...document.querySelectorAll('main details li')].find(x => x.textContent.includes(${JSON.stringify(acked)})); const b = li?.querySelector('button'); if (!b) return false; b.click(); return true; })()`);
  if (!found) fail('R3', `no Unacknowledge button beside ${acked}'s acknowledged checks`);
  else {
    const d = await saveDialog();
    // its own condition: the page is drawn again with fewer acknowledged cells
    const after = await reach(ackCells, v => v >= 0 && v < before);
    const logs = await wrote(m0, 1);
    judge('R3', d.opened && ended(d.answer) && after >= 0 && after < before && allByDoor(logs, 1, 'ack', 'end', acked),
      `${acked}: '${d.title}' answered '${d.answer}'; acknowledged cells ${before} -> ${after}; ${logSaid(logs)} (want 1)`);
  }
}

// ---- R2 a cell through the toolbar: Options > Memory Dumps > Acknowledge Dumps, on the MIXED store. The real
// instance's Memory Dump cell is critical too (the proof gave it crash restarts): the demo's instances are
// acknowledged, the real one is left alone and COUNTED - never a request the door refuses, never 'not saved'
// ---- R2b the same menu's Configure Thresholds, Clear: it ends the demo's acknowledgements of Memory Dump cells and
// leaves alone the one of the real instance tagged demo by hand (the proof's own row), counted in its answer
{
  const cells0 = await reach(ackCells, v => v >= 0);
  // what the page answers to Acknowledge Dumps (its note is made anew with every draw of the page)
  const ackDumps = async () => {
    const w = await menuWalk('/^Memory Dumps/', '/^Acknowledge Dumps/');
    const said = w.ok ? await until(`(() => { const t = [...document.querySelectorAll('main p, main span')].map(x => x.textContent).find(x => /Memory dumps acknowledged on|No Memory dumps cell|No demo instance has a Memory dumps cell|Acknowledge is off/.test(x)); return t || ''; })()`) ?? '' : '';
    return { menus: w.said, said };
  };
  const m0 = await mark();
  const a1 = await ackDumps();
  const said = a1.said;
  const sm = /Memory dumps acknowledged on ([1-9]\d*) instance\(s\) until a newer dump; 1 instance\(s\) not the demo's left alone\./.exec(said);
  const n = Number((/Memory dumps acknowledged on (\d+) instance/.exec(said) ?? [])[1] ?? 0);
  const logs = await wrote(m0, n);
  // the page draws itself again a moment after the answer: waited for before the next menu is opened
  const cells1 = await reach(ackCells, v => v >= cells0 + n && n > 0, n > 0 ? 15000 : 0);
  // N is the page's own word: the same item AGAIN must find none left (a walk that stopped early, or said less than it
  // did, shows here) - the demo's cells are all acknowledged, the real instance's is still left alone, nothing is written
  const m0b = await mark();
  const a2 = n > 0 ? await ackDumps() : { menus: 'not clicked', said: '' };
  const logsB = n > 0 ? await wrote(m0b, 0) : [];
  const none = a2.said.trim() === "No demo instance has a Memory dumps cell with a warning or a critical to acknowledge; 1 instance(s) not the demo's left alone.";
  judge('R2', !!sm && !/not saved|refused/.test(said) && allByDoor(logs, n, 'ack', 'add', doorNames) && none && logsB.length === 0,
    `Options > Memory Dumps > Acknowledge Dumps: the page said '${said}' (${a1.menus}); ${logSaid(logs)} (want ${n}, each an acknowledgement of a demo instance by demo / demo door); the same item again: '${a2.said}' (${a2.menus}), ${logSaid(logsB)} (want 0)`);

  const m3 = await mark();
  const d1 = await openDump();
  const clear = d1.open ? await ev(`(() => { const b = [...${dumpDlg}.querySelectorAll('button')].find(x => x.textContent.trim() === 'Clear'); if (!b) return 'absent'; if (b.disabled || b.getAttribute('aria-disabled') === 'true') return 'off'; b.click(); return 'clicked'; })()`) : 'no dialog';
  const answer = clear === 'clicked' ? await until(`${dumpDlg}?.querySelector('p[role=status]')?.textContent.trim() ?? ''`) ?? '' : '';
  if (d1.open) await closeDump();
  const cm = /^done ([1-9]\d*) acknowledgement\(s\) ended: the dumps show again; 1 acknowledgement\(s\) of instances not the demo's left alone\.$/.exec(answer);
  const k = Number((/^done (\d+) acknowledgement/.exec(answer) ?? [])[1] ?? 0);
  const logs2 = clear === 'clicked' ? await wrote(m3, k) : [];
  // k is the dialog's own word: it must cover what R2 just acknowledged (N), and the proof reads from the store
  // afterwards that no acknowledgement the page made through the door is still live
  judge('R2b', !!cm && k >= n && n > 0 && allByDoor(logs2, k, 'ack', 'end', doorNames),
    `Options > Memory Dumps > Configure Thresholds (${d1.menus}; the dialog open ${d1.open}), Clear ${clear}: answered '${answer}'; ${logSaid(logs2)} (want ${k}, not under R2's ${n}, each an end of a demo instance's acknowledgement by demo / demo door)`);

  // ---- R2c the same dialog again. The one Memory Dump acknowledgement still in force is the real instance's (the
  // proof's own row): Clear has nothing it may end here - off, aria-disabled (never the disabled attribute without
  // words), its reason in words - and the date beside it is not that instance's acknowledgement: it reads 'Not
  // acknowledged' with the count of the instances left alone, so a mixed store is not read as 'nothing is acknowledged'
  await reach(ackCells, v => v >= 0 && v < cells1, k > 0 ? 15000 : 0);   // the page drawn again after Clear
  const d2 = await openDump();
  const c2 = d2.open ? await dumpClear() : null;
  if (d2.open) await closeDump();
  judge('R2c', !!c2 && c2.off && !c2.disabledAttr && /are of instances that are not the demo's/.test(c2.words) && c2.date === "Not acknowledged (1 instance(s) not the demo's left alone)",
    `the dialog again (${d2.menus}; open ${d2.open}), only the real instance's acknowledgement in force: Clear ${JSON.stringify(c2)}`);
}

// ---- R7 the instances that are not the demo's - a real one, a real one tagged demo by hand, and one with the demo's
// tag AND its name prefix that this demo process did not seed: off, each with its reason in words on the page; a demo
// instance's Silence is on
{
  await go('#/summary');
  const silenceOf = (name) => ev(`(() => { const off = ${offWordsJS};
    const rows = [...document.querySelectorAll('main tr')].filter(tr => [...tr.querySelectorAll('td, th')].some(c => c.textContent.trim() === ${JSON.stringify(name)}));
    const b = rows.map(tr => tr.querySelector('button.silence-btn')).find(Boolean);
    return b ? { found: true, off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled, words: off(b), label: b.textContent.trim() } : { found: false, rows: rows.length }; })()`);
  const real = await reach(() => silenceOf(REAL), v => !!v && v.found);   // the grid is drawn when its row is there
  const tagged = TAGGED ? await silenceOf(TAGGED) : null;
  const stale = STALE ? await silenceOf(STALE) : null;
  await shot('6-summary-mixed-store');
  // the real instance's row brought into view: where its off Silence and the words beside it land on the page
  await ev(`(() => { const rows = [...document.querySelectorAll('main tr')].filter(tr => [...tr.querySelectorAll('td, th')].some(c => c.textContent.trim() === ${JSON.stringify(REAL)}));
    const b = rows.map(tr => tr.querySelector('button.silence-btn')).find(Boolean);
    const n = b && b.getAttribute('aria-describedby') ? document.getElementById(b.getAttribute('aria-describedby')) : null;
    if (b) (n ?? b).scrollIntoView({ block: 'center', inline: 'end' }); })()`);
  await sleep(300); await shot('6b-summary-real-instance-silence-off');
  // a Silence (not an Unsilence) that is on, in the row of an instance the door names
  const demoRow = await ev(`(() => { const ids = ${JSON.stringify(doorIds)};
    for (const tr of document.querySelectorAll('main tr')) { const b = tr.querySelector('button.silence-btn'); const m = /[?&]i=(\\d+)/.exec(tr.querySelector('a[href*="i="]')?.getAttribute('href') ?? '');
      if (b && m && ids.includes(Number(m[1])) && b.textContent.trim() === 'Silence' && b.getAttribute('aria-disabled') !== 'true' && !b.disabled) return b.getAttribute('aria-label'); }
    return ''; })()`);
  const offRight = (x, name) => !!x && x.found && x.off && !x.disabledAttr && x.label === 'Silence' && x.words.includes(`${name} is not one of this demo's instances`);
  judge('R7', offRight(real, REAL) && (!TAGGED || offRight(tagged, TAGGED)) && (!STALE || offRight(stale, STALE)) && !!demoRow,
    `${REAL}'s Silence on the Summary: ${JSON.stringify(real)}; ${TAGGED || 'no tagged instance'}'s (tagged demo by hand): ${JSON.stringify(tagged)}; ${STALE || 'no stale instance'}'s (the demo's tag and prefix, not seeded by this process): ${JSON.stringify(stale)}; a demo instance's Silence is on ('${demoRow}')`);
}

// ---- R6 a silence on a demo instance from the Summary's row, then the Unsilence of THAT instance
{
  const m0 = await mark();
  const label = await ev(`(() => { const b = [...document.querySelectorAll('main button.silence-btn')].find(x => x.getAttribute('aria-disabled') !== 'true' && !x.disabled && x.textContent.trim() === 'Silence'); if (!b) return ''; b.click(); return b.getAttribute('aria-label'); })()`);
  const who = (/^Silence all alerts for '(.*)'$/.exec(label ?? '') ?? [])[1] ?? '';
  if (!who) fail('R6', `no Silence button that is on (its label: '${label}')`);
  else {
    const d = await saveDialog('demo door proof');
    // its own condition: that instance's row now offers Unsilence
    const drawn = !!(await until(labelJS(`Unsilence '${who}'`)));
    const logs = await wrote(m0, 1);
    const m1 = await mark();
    const un = drawn ? await clickLabel(`Unsilence '${who}'`, 'Unsilence') : false;
    const d2 = un ? await saveDialog() : { opened: false, answer: '' };
    // and after it: its Silence is back
    const back = un ? !!(await until(labelJS(label))) : false;
    const logs2 = un ? await wrote(m1, 1) : [];
    judge('R6', d.opened && saved(d.answer) && allByDoor(logs, 1, 'silence', 'add', who) && un && ended(d2.answer) && back && allByDoor(logs2, 1, 'silence', 'end', who),
      `'${label}': '${d.answer}' (${logSaid(logs)}, want 1); 'Unsilence '${who}'' drawn ${drawn} and clicked ${un}, answered '${d2.answer}', its Silence back ${back} (${logSaid(logs2)}, want 1)`);
  }
}

// ---- R4 a note on an open alert of a demo instance (Alerts: tick one, Add notes to selected alerts)
{
  await go('#/alerts');
  // the first open alert of a demo instance, ticked once its row is drawn
  const ticked = await until(`(() => { const names = ${JSON.stringify(doorNames)};
    for (const tr of document.querySelectorAll('main table tbody tr')) { const c = tr.querySelector('input[type=checkbox]'); if (!c) continue;
      const n = [...tr.querySelectorAll('td')].map(td => td.textContent.trim()).find(t => names.includes(t)); if (n) { c.click(); return n; } }
    return ''; })()`) ?? '';
  const m0 = await mark();
  const btn = await ev(`(() => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent.trim() === 'Add notes to selected alerts'); if (!b) return 'absent'; if (b.getAttribute('aria-disabled') === 'true' || b.disabled) return 'off'; b.click(); return 'clicked'; })()`);
  const d = btn === 'clicked' ? await saveDialog('seen by the demo door proof') : { opened: false, answer: '' };
  // its own condition is the log itself: ONE note, on the alert ticked (a note on every alert of the instance writes more)
  const logs = btn === 'clicked' ? await wrote(m0, 1) : [];
  judge('R4', !!ticked && d.opened && saved(d.answer) && allByDoor(logs, 1, 'note', 'add', ticked),
    `an alert of ${ticked || 'no demo instance'} ticked, 'Add notes to selected alerts' ${btn}: '${d.title}' answered '${d.answer}'; ${logSaid(logs)} (want 1)`);
  await settled();
  await shot('7-alerts-after-note');
  // what stays off on the Alerts page says why in words: EVERY Send test - the one of a channel the configuration no
  // longer names among them (the proof put that channel into the store) - and Mute similar. Off means aria-disabled:
  // the disabled attribute would take the button out of the tab order, and its words out of a keyboard's reach
  const offs = await reach(() => ev(`(() => { const off = ${offWordsJS}; const of = (b) => ({ label: b.getAttribute('aria-label') ?? '', off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled, words: off(b) });
    const all = [...document.querySelectorAll('main button')];
    const s = all.find(x => /^Mute similar$/.test(x.textContent.trim()));
    return { tests: all.filter(x => /^Send test$/.test(x.textContent.trim())).map(of), similar: s ? of(s) : null }; })()`), v => v.tests.length >= (GONE ? 2 : 1) && !!v.similar);
  const goneTest = GONE ? offs.tests.find(t => t.label.endsWith(' ' + GONE)) : null;
  judge('R9a', offs.tests.length >= (GONE ? 2 : 1) && offs.tests.every(t => t.off && !t.disabledAttr && /runs no sender/.test(t.words)) && (!GONE || !!goneTest)
    && !!offs.similar && offs.similar.off && !offs.similar.disabledAttr && /reach past the demo's instances/.test(offs.similar.words),
    `on the Alerts page: ${offs.tests.length} Send test button(s) ${JSON.stringify(offs.tests.map(t => ({ ...t, words: t.words.slice(0, 60) })))}${GONE ? `, the one of '${GONE}' (no longer configured) among them: ${!!goneTest}` : ''}; Mute similar ${JSON.stringify(offs.similar)}`);

  // ---- R15 the Alerts page's pickers offer the DOOR's instances alone: a control is never on for an instance the door
  // would refuse. (a) the Instance list beside Silence and Blackout; (b) New mute rule's dialog: no 'any instance', the
  // door's instances alone, the first one picked
  const same = (a) => a.length === doorNames.length && [...a].sort().join('|') === [...doorNames].sort().join('|');
  const picker = await ev(`(() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent.trim() === 'Silenced servers and blackouts');
    const sel = h?.parentElement?.querySelector('select[aria-label=instance]'); if (!sel) return null;
    return { options: [...sel.options].map(o => o.textContent.trim()), picked: sel.selectedOptions[0]?.textContent.trim() ?? '' }; })()`);
  const newRule = await ev(`(() => { const b = [...document.querySelectorAll('main button[aria-label]')].find(x => x.getAttribute('aria-label') === 'New mute rule'); if (!b) return 'absent';
    if (b.getAttribute('aria-disabled') === 'true' || b.disabled) return 'off'; b.click(); return 'clicked'; })()`);
  const ruleDlg = `document.querySelector('dialog.act-dialog[open][aria-label="New mute rule"]')`;
  const ruleOpen = newRule === 'clicked' ? !!(await until(`!!${ruleDlg}`)) : false;
  const rule = ruleOpen ? await ev(`(() => { const sel = ${ruleDlg}.querySelector('select[aria-label=instance]'); if (!sel) return null;
    return { options: [...sel.options].map(o => o.textContent.trim()), values: [...sel.options].map(o => o.value), picked: sel.selectedOptions[0]?.textContent.trim() ?? '' }; })()`) : null;
  if (ruleOpen) { await shot('7b-alerts-new-mute-rule'); await ev(`[...${ruleDlg}.querySelectorAll('button[type=button]')].find(x => /Back|Close/.test(x.textContent))?.click()`); await until(`!${ruleDlg}`); }
  const brief = (x) => x ? `${x.options.length} option(s), the first '${x.options[0] ?? ''}', picked '${x.picked}', among them ${[REAL, TAGGED, STALE, 'any instance'].filter(t => t && x.options.includes(t)).join(', ') || 'none that the door refuses'}` : 'not found';
  judge('R15', !!picker && same(picker.options) && picker.picked === picker.options[0]
    && !!rule && same(rule.options) && !rule.values.includes('') && rule.picked === rule.options[0],
    `the Alerts page on a demo serve with ${doorNames.length} door instance(s): the Instance list of 'Silenced servers and blackouts': ${brief(picker)}; 'New mute rule' ${newRule}, its dialog's Instance list: ${brief(rule)}`);
}

// ---- R6b the demo's OWN seeded silence (stored by the instance's name, without an id) has its Unsilence on the
// Alerts page's list of silenced servers, and it works (the review's fold: the list drew no button for it). The button
// is the one that names the seed's instance: R6 ended its own silence, so no other is live.
{
  await go('#/alerts');
  const label = `Unsilence ${SEED}`;
  if (SEED) await until(labelJS(label));   // the list is drawn when its button is there
  const m0 = await mark();
  const clicked = SEED ? await clickLabel(label, 'Unsilence') : false;
  if (!clicked) fail('R6b', `the Alerts page offers no '${label}' that is on (the seed's silence); its silence and blackout buttons: ${JSON.stringify(await ev(`[...document.querySelectorAll('main button[aria-label]')].map(x => x.getAttribute('aria-label')).filter(t => /silence|blackout/i.test(t)).slice(0, 8)`))}`);
  else {
    const d = await saveDialog();
    // its own condition: the page is drawn and the seed's Unsilence is no longer on it
    const gone = !!(await until(`${drawnJS} && !(${labelJS(label)})`));
    const logs = await wrote(m0, 1);
    await shot('8-alerts-seed-silence-ended');
    judge('R6b', d.opened && ended(d.answer) && gone && allByDoor(logs, 1, 'silence', 'end', SEED),
      `the Alerts page's list of silenced servers: '${label}' clicked, answered '${d.answer}', its button gone (${gone}); ${logSaid(logs)} (want 1)`);
  }
}

// ---- R14 (DONE-2) a bulk action over a MIXED scope says how many were done and how many were refused, with the reason:
// on the Alerts page one alert of a demo instance and the real instance's alert (the proof put it into the store)
// ticked, Acknowledge alerts, Save - one saved, one refused by name, the log's new row the demo alert's
{
  await go('#/alerts');
  // the open alerts are drawn when the real instance's row is there
  await until(`[...document.querySelectorAll('main table tbody tr')].some(tr => [...tr.querySelectorAll('td')].some(td => td.textContent.trim() === ${JSON.stringify(REAL)}))`);
  const picked = await ev(`(() => { const names = ${JSON.stringify(doorNames)}; const out = { real: false, demo: '' };
    for (const tr of document.querySelectorAll('main table tbody tr')) { const c = tr.querySelector('input[type=checkbox]'); if (!c) continue;
      const cells = [...tr.querySelectorAll('td')].map(td => td.textContent.trim());
      if (!out.real && cells.includes(${JSON.stringify(REAL)})) { c.click(); out.real = true; continue; }
      const n = cells.find(t => names.includes(t));
      if (!out.demo && n && !cells.some(t => /acknowledged|held by/i.test(t))) { c.click(); out.demo = n; } }
    return out; })()`);
  const m0 = await mark();
  const btn = await ev(`(() => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent.trim() === 'Acknowledge alerts'); if (!b) return 'absent'; if (b.getAttribute('aria-disabled') === 'true' || b.disabled) return 'off'; b.click(); return 'clicked'; })()`);
  const d = btn === 'clicked' ? await saveDialog() : { opened: false, answer: '' };
  // ONE new log row: the demo alert's (the real instance's alert is refused before anything is written)
  const logs = btn === 'clicked' ? await wrote(m0, 1) : [];
  judge('R14', picked.real && !!picked.demo && d.opened && /^partly done 1 of 2 saved; 1 refused: /.test(d.answer) && d.answer.includes(`${REAL} is not one of this demo's instances`) && allByDoor(logs, 1, 'alert_ack', 'add', picked.demo),
    `the Alerts page: ${REAL}'s alert ticked ${picked.real}, an alert of ${picked.demo || 'no demo instance'} ticked, 'Acknowledge alerts' ${btn}: '${d.title}' answered '${d.answer}'; ${logSaid(logs)} (want 1)`);
}

// ---- R16 the REAL instance's own pages on the demo serve: every Acknowledge there is off for ONE reason - the instance
// is not the demo's - and the page says it once, in one sentence that names the instance; every off Acknowledge points
// at that sentence, none carries the words beside itself inside its grid cell (Copy all and the exports carry a
// cell's text). The proof gave the instance two failed jobs (its Jobs page) and two crash restarts (its state page).
if (REAL_ID) {
  const ackOff = async (hash, shotName) => {
    await go(hash);
    const v = await reach(() => ev(`(() => { const vis = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
      const main = document.querySelector('main'); if (!main) return { off: 0 };
      const hdr = main.querySelector('.inst-header');
      const bs = [...main.querySelectorAll('button')].filter(b => b.textContent.trim() === 'Acknowledge' && b.getAttribute('aria-disabled') === 'true' && vis(b));
      const ids = [...new Set(bs.map(b => b.getAttribute('aria-describedby') || ''))];
      const n = ids.length === 1 && ids[0] ? document.getElementById(ids[0]) : null;
      const words = n && vis(n) ? n.textContent.trim() : '';
      const count = (el) => el && words ? el.innerText.split(words).length - 1 : 0;
      return { off: bs.length, on: [...main.querySelectorAll('button')].filter(b => b.textContent.trim() === 'Acknowledge' && b.getAttribute('aria-disabled') !== 'true' && vis(b)).length,
        disabledAttr: bs.filter(b => b.disabled).length, notes: ids.length, words, inCell: !!(n && n.closest('td')),
        times: count(main) - count(hdr), cells: words ? [...main.querySelectorAll('td')].filter(td => td.innerText.includes(words)).length : 0 }; })()`), x => x.off >= 2);
    if (shotName) { await ev(`[...document.querySelectorAll('main button')].find(b => b.textContent.trim() === 'Acknowledge')?.scrollIntoView({ block: 'center', inline: 'center' })`); await sleep(200); await shot(shotName); }
    return v;
  };
  const want = `Acknowledge is off: ${REAL} is not one of this demo's instances`;
  const got = [['its Jobs page', await ackOff(`#/jobs?i=${REAL_ID}`, '8b-real-instance-jobs')], ['its state page (crash restarts)', await ackOff(`#/pgstate?i=${REAL_ID}`, '8c-real-instance-crashes')]];
  judge('R16', got.every(([, g]) => g.off >= 2 && g.on === 0 && g.disabledAttr === 0 && g.notes === 1 && (g.words ?? '').startsWith(want) && !g.inCell && g.times === 1 && g.cells === 0),
    `${REAL} (not the demo's) on the demo serve: ` + got.map(([what, g]) => `${what}: ${g.off} Acknowledge off and ${g.on ?? 0} on, ${g.disabledAttr ?? 0} with the disabled attribute, pointing at ${g.notes ?? 0} sentence(s) ('${(g.words ?? '').slice(0, 120)}'), inside a grid cell ${g.inCell ?? false}, its words ${g.times ?? 0} time(s) on the page and in ${g.cells ?? 0} grid cell(s)`).join('; '));
}

// ---- R10 a server that writes nothing at all (pgvigil serve -no-login on the same repository): a page says the reason
// ONCE and every off control points at that one sentence - never the same words beside each control, never inside a
// grid cell (Copy all and the exports carry a cell's text)
if (NOLOGIN) {
  const fj = failedJobs[0];
  const read = async (hash, shotName) => {
    await goTo(NOLOGIN, hash);
    // the page is read once its off controls are drawn (a Jobs grid comes after its own reads)
    await until(`[...document.querySelectorAll('main button')].some(b => b.getAttribute('aria-disabled') === 'true' && !b.closest('.inst-header') && b.getClientRects().length > 0)`);
    if (shotName) await shot(shotName);
    return ev(`(() => { const vis = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
      // the instance header above an instance's page is its own (one control, its reason beside it): the page's rule
      // is read below it
      const main = document.querySelector('main'), hdr = main.querySelector('.inst-header');
      const off = [...main.querySelectorAll('button')].filter(b => b.getAttribute('aria-disabled') === 'true' && vis(b) && !b.closest('.inst-header'));
      const ids = off.map(b => b.getAttribute('aria-describedby') || '');
      const notes = [...new Set(ids.filter(Boolean))].map(i => document.getElementById(i));
      const texts = notes.map(n => n && vis(n) ? n.textContent.trim() : '');
      const first = texts.find(Boolean) ?? '';
      // the sentence as the page shows it: how often its words stand in the page's text, and in how many grid cells
      const count = (el) => el && first ? el.innerText.split(first).length - 1 : 0;
      const times = count(main) - count(hdr);
      const cells = first ? [...main.querySelectorAll('td')].filter(td => td.innerText.includes(first)).length : 0;
      return { off: off.length, undescribed: ids.filter(i => !i).length, unseen: texts.filter(t => !t).length, sentences: texts.filter(Boolean).length,
        repeated: texts.filter(Boolean).length - new Set(texts.filter(Boolean)).size, noteCells: main.querySelectorAll('td .off-reason').length, times, cells, first: first.slice(0, 110) }; })()`);
  };
  const pagesOff = [['#/summary', 'the Summary', '9-nologin-summary'], ['#/alerts', 'the Alerts page', '']];
  if (fj) pagesOff.push([`#/${fj.tab}?i=${fj.id}`, `${fj.name}'s Jobs page`, '']);
  const got = [];
  let seatPlain = '', clearPlain = null, dumpMenus = '';
  for (const [hash, what, shotName] of pagesOff) {
    got.push({ what, ...(await read(hash, shotName)) });
    if (seatPlain) continue;
    // the footer's seat on a serve WITHOUT a door, read on its first page: the plain words (proof-frame serves a demo
    // and so never draws them)
    seatPlain = await until(seatJS) ?? '';
    // and, on that page (the Summary), the dump dialog's Clear: an acknowledgement stands (the proof's own, of the real
    // instance) and this server ends none - off with the server's reason in words, never on to be refused per row
    const d = await openDump(); dumpMenus = d.menus;
    clearPlain = d.open ? await dumpClear() : null;
    if (d.open) await closeDump();
  }
  judge('R10', got.every(g => g.off > 0 && g.undescribed === 0 && g.unseen === 0 && g.repeated === 0 && g.noteCells === 0 && g.times === 1 && g.cells === 0) && /^read only, actions off$/.test(seatPlain)
    && !!clearPlain && clearPlain.off && !clearPlain.disabledAttr && /this server runs with -no-login/.test(clearPlain.words),
    'pgvigil serve -no-login on the same repository: ' + got.map(g => `${g.what}: ${g.off} off control(s), ${g.undescribed} without a description, ${g.unseen} pointing at words not on the page, ${g.sentences} sentence(s) of which ${g.repeated} repeated, its words ${g.times} time(s) on the page and in ${g.cells} grid cell(s), ${g.noteCells} note(s) inside a grid cell ('${g.first}')`).join('; ')
    + `; the footer's seat: '${seatPlain}' (want 'read only, actions off'); the Summary's dump dialog (${dumpMenus}), Clear: ${JSON.stringify(clearPlain)}`);
}

// ---- R12 (DONE-2) every page of the MIXED store: a control that is off says why in words on the page. The walk is
// the tab strip's own list (as scripts/a11y-check.mjs reads it) at the root and on four instances - a PostgreSQL demo
// instance on premises, the demo's Aurora instance with a failed job, the demo's SQL Server primary, and the real
// instance beside them - each page once, and on each the rule proof-a11y applies to three pages: every control that
// is off and shown (the disabled attribute or aria-disabled) has a visible, non-empty description (aria-describedby)
// that is words, not a badge alone, and not a sentence that ends at its colon ('... are off: ' with no reason after it).
// A page that drew only an error is NOT walked: it is listed and fails the row. The TOP BAR is walked on every page
// under its own rule (the lead 01:38): a control that is off there must be DESCRIBED (aria-describedby naming an
// element that holds words) - 'Later' while the range ends now by a description and its title, with no words in the
// bar (a pager's end), the Auto refresh select by the footer's own visible sentence (a form field). The scope, named
// in the ok line: the page's main and the top bar, on the tab strip's pages - not a drill page behind a row (a plan, a
// diff, one alert), and no dialog: the walk opens none (R2c, R7, R13 read their dialogs). Each page is read only once
// it is THIS page's drawing: a mark planted in main before the navigation is gone (render replaced main) and main holds
// more than the router's own 'Loading' note. The error-page rule skips the instance header (render puts the header
// before the view's error box). Both rules are tried on planted pages first (the self-test in the ok line).
{
  const offOnPage = () => ev(`(() => {
    const vis = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
    const ctl = [...document.querySelectorAll('main button, main input, main select, main textarea, dialog button')]
      .filter(e => (e.disabled || e.getAttribute('aria-disabled') === 'true') && vis(e));
    const said = x => { const t = x.textContent.replace(/^\\s*(off|not checked|demo|note|on|declined)\\b/i, '').trim(); return t.length > 0 && !/:\\s*\\.?$/.test(t); };
    const bad = ctl.filter(e => !(e.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean).some(i => { const x = document.getElementById(i); return vis(x) && said(x); }));
    // the top bar: off = described (the description need not be shown: no words are added to the bar)
    const bar = [...document.querySelectorAll('#bar button, #bar select, #bar input')].filter(e => (e.disabled || e.getAttribute('aria-disabled') === 'true') && vis(e));
    const name = e => (e.tagName + ' ' + (e.getAttribute('aria-label') || e.textContent || '').trim()).slice(0, 40);
    const barBad = bar.filter(e => !(e.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean).some(i => { const x = document.getElementById(i); return !!x && said(x); }));
    return { off: ctl.length, bad: bad.map(e => (e.tagName + ' ' + (e.textContent || e.getAttribute('aria-label') || '').trim()).slice(0, 40)),
      bar: bar.map(name), barBad: barBad.map(name),
      // with a top-bar line, what the footer said (a status read that failed takes the refresh words with it)
      foot: barBad.length ? (document.querySelector('footer')?.textContent ?? '').replace(/\\s+/g, ' ').trim().slice(0, 120) : '' }; })()`);
  // THIS page's drawing (finding 3 of DONE-2's review): the old page's main is marked, the mark must be gone (render
  // replaced main's children) and main must hold more than the router's own note (empty, then 'Loading...')
  const markJS = `(() => { const m = document.querySelector('main'); if (m) m.append(Object.assign(document.createElement('span'), { hidden: true, className: 'r12-mark' })); return 1; })()`;
  const ownDrawnJS = `(() => { const m = document.querySelector('main'); if (!m || m.querySelector('.r12-mark')) return false;
    const k = [...m.children]; return k.length > 0 && !(k.length === 1 && k[0].matches('p.empty[role=status]')); })()`;
  // a page whose view threw: render puts the instance header first and the error box after it
  const errJS = `(() => { const m = document.querySelector('main'); const k = m ? [...m.children].filter(c => !c.matches('.inst-header')) : [];
    return k.length > 0 && k.every(c => c.matches('p.error')) ? k[0].textContent.trim().slice(0, 120) : ''; })()`;
  // a page reached: by its hash, through about:blank where the browser already shows that hash (no hashchange then)
  const reach12 = async (h) => {
    if (await ev('location.hash') === h) { await goTo(U, h); return true; }
    await ev(markJS); await cmd('Page.navigate', { url: U + h });
    return !!(await until(ownDrawnJS, 15000));
  };
  const tabsOf = async (hash) => { await go(hash);
    return ev(`(() => { const t = document.querySelector('#tabs'); if (!t) return []; return t.dataset.all ? JSON.parse(t.dataset.all) : [...t.querySelectorAll('a')].map(a => a.getAttribute('href')); })()`); };
  const all = tbl(await api('instances'));
  const pickInst = (pred) => all.find(i => doorNames.includes(String(i.name)) && pred(i));
  const walk = [['the root', '#/summary', null],
    ['a PostgreSQL demo instance', null, pickInst(i => i.engine !== 'sqlserver' && i.platform === 'onprem')],
    ['the demo instance with a failed job', null, all.find(i => String(i.name) === (failedJobs[0]?.name ?? ''))],
    ['the demo SQL Server primary', null, pickInst(i => i.engine === 'sqlserver' && String(i.name).endsWith('sql01'))],
    [`the real instance ${REAL}`, null, all.find(i => String(i.name) === REAL)]];
  const pages = [], seen = new Set();
  for (const [what, hash, inst] of walk) {
    if (!hash && !inst) { fail('R12', `the walk found no instance for '${what}'`); continue; }
    for (const t of await tabsOf(hash ?? `#/summary?i=${inst.instance_id}`)) {
      const h = inst ? String(t).replace(/i=\d+/, `i=${inst.instance_id}`) : String(t);
      if (!seen.has(h)) { seen.add(h); pages.push([what, h]); }
    }
  }
  // a shot of the first page of each kind whose off controls say why since DONE-2 (how the words sit on the page),
  // its first off control brought into view
  const shotOf = [[/^#\/alertrules\b/, '12a-alert-rules'], [/^#\/admin_instances\b/, '12b-admin-instances'], [/^#\/activity\?/, '12c-activity'],
    [/^#\/counters\?/, '12d-counters'], [/^#\/plans\?/, '12e-plans'], [/^#\/mssql_running\?/, '12f-sqlserver-running'], [/^#\/mssqljobs\?/, '12g-sqlserver-jobs']];
  const shotDone = new Set();
  let offSeen = 0; const bad = [], unrendered = [], errored = [], barBad = [], barSeen = new Map();
  // the self-test of the two rules on planted pages (the first instance page of the walk): a main holding only the
  // router's note is not drawn; an instance header followed by an error box is an error page
  let selftest = 'not run';
  const firstInst = pages.find(([, h]) => /[?&]i=\d+/.test(h));
  if (firstInst && await reach12(firstInst[1]) && await until(`!!document.querySelector('main .inst-header')`, 15000)) {
    const noteOnly = await ev(`(() => { const m = document.querySelector('main'); const keep = [...m.children]; m.replaceChildren(Object.assign(document.createElement('p'), { className: 'empty', role: 'status', textContent: 'Loading...' }));
      const v = ${ownDrawnJS}; m.replaceChildren(...keep); return v; })()`);
    const errPlanted = await ev(`(() => { const m = document.querySelector('main'); const keep = [...m.children]; const hdr = m.querySelector('.inst-header');
      m.replaceChildren(...(hdr ? [hdr] : []), Object.assign(document.createElement('p'), { className: 'error', textContent: 'planted error' }));
      const v = ${errJS}; m.replaceChildren(...keep); return v; })()`);
    selftest = noteOnly === false && errPlanted === 'planted error' ? 'ok' : `FAILED (a note-only main drawn: ${noteOnly}; a planted error page read as '${errPlanted}')`;
  }
  for (const [what, h] of pages) {
    if (!(await reach12(h))) { unrendered.push(h); continue; }
    await sleep(150);
    // a page whose view threw (its main the instance header and an error box, or the box alone) was not drawn: it has
    // no control to judge and must not pass as walked
    const err = await ev(errJS);
    if (err) { errored.push(`${h}: ${err}`); continue; }
    const r = await offOnPage();
    const sh = shotOf.find(([re, name]) => re.test(h) && !shotDone.has(name));
    if (sh && r.off > 0) {
      shotDone.add(sh[1]);
      await ev(`[...document.querySelectorAll('main button')].find(b => b.getAttribute('aria-disabled') === 'true' || b.disabled)?.scrollIntoView({ block: 'center', inline: 'center' })`);
      await sleep(250); await shot(sh[1]);
    }
    offSeen += r.off;
    for (const n of r.bar) { const k = n.replace(/:.*/, ''); barSeen.set(k, (barSeen.get(k) ?? 0) + 1); }
    if (r.barBad.length) barBad.push(`${h}: ${[...new Set(r.barBad)].join('; ')} (the footer: '${r.foot}')`);
    if (r.bad.length) bad.push(`${h} (${what}): ${r.bad.length} - ${[...new Set(r.bad)].slice(0, 5).join('; ')}`);
  }
  // a shot of a kind whose page showed no off control is not taken: it is missing, said with the run's other shots
  for (const [, name] of shotOf) if (!shotDone.has(name)) shotsMissed.push(name);
  const bothBar = barSeen.has('BUTTON Later') && [...barSeen.keys()].some(k => k.startsWith('SELECT '));
  judge('R12', selftest === 'ok' && pages.length > 100 && bad.length === 0 && unrendered.length === 0 && errored.length === 0 && barBad.length === 0 && bothBar,
    `${pages.length} pages of the mixed store walked (${walk.map(w => w[0]).join(', ')}; each page's main and its top bar - no dialog is opened by the walk, not a drill page behind a row), each read once it was its own drawing; the rules' self-test on planted pages ${selftest}; ${offSeen} off control(s) seen; ${unrendered.length} page(s) not drawn in 15 s${unrendered.length ? ` (${unrendered.slice(0, 5).join(', ')})` : ''}; ${errored.length} page(s) drew only an error; ${bad.length} page(s) with an off control without its reason in words; the top bar's off controls (${[...barSeen].map(([n, c]) => `${n} on ${c} page(s)`).join(', ') || 'none seen'}; both kinds seen: ${bothBar}) described, not worded on the page: a pager's end and a form field - ${barBad.length} page(s) with one that is not described${bad.length || barBad.length ? ':' : ''}`);
  for (const b of errored) console.log(`     R12 error page ${b}`);
  for (const b of barBad.slice(0, 8)) console.log(`     R12 top bar ${b}`);
  for (const b of bad) console.log(`     R12 ${b}`);
}

// ---- R13 (DONE-2) the threshold dialogs on a demo serve: a level wider than one instance is OFF in words BEFORE a
// request is made (never a control that is on and then answers 403), and one demo instance's own level is on
{
  const stJS = `(b) => b ? { found: true, off: b.getAttribute('aria-disabled') === 'true' || b.disabled, words: (${offWordsJS})(b) } : { found: false, off: false, words: '' }`;
  const openTitle = () => ev(`document.querySelector('dialog.act-dialog[open]')?.getAttribute('aria-label') ?? ''`);
  const closeDialog = async () => { await ev(`document.querySelector('dialog.act-dialog[open]')?.close()`); await until(`!document.querySelector('dialog.act-dialog[open]')`, 5000); };
  // (a) Drives at the root: the toolbar's Configure sets the ROOT's level - off; a demo drive's own Configure is on
  await go('#/drives');
  await until(`[...document.querySelectorAll('main .toolbar button')].some(b => b.textContent.trim() === 'Configure')`);
  const drv = await ev(`(() => { const st = ${stJS}; const isOn = b => b.getAttribute('aria-disabled') !== 'true' && !b.disabled;
    const tb = [...document.querySelectorAll('main .toolbar button')].find(b => b.textContent.trim() === 'Configure');
    const own = [...document.querySelectorAll('main button[aria-label^="Configure the thresholds of "]')];
    const on = own.find(isOn); if (on) on.click();
    return { root: st(tb), drives: own.length, on: own.filter(isOn).length }; })()`);
  if (drv.on > 0) await until(dialogOpenJS, 5000);
  const drvOpened = await openTitle(); await closeDialog();
  // (b) the Thresholds page: the root's Change buttons off for the page's one sentence; 'Set...' on - a tag picked is
  // answered in words beside the button and no dialog opens, a demo instance picked opens the dialog
  await go('#/pgthresholds');
  await until(`[...document.querySelectorAll('main button')].some(b => b.textContent.trim() === 'Set...')`);
  const thr = await ev(`(() => { const off = ${offWordsJS};
    const roots = [...document.querySelectorAll('main button[aria-label$=" at the root"]')];
    const set = [...document.querySelectorAll('main button')].find(b => b.textContent.trim() === 'Set...');
    return { roots: roots.length, rootsOff: roots.filter(b => b.getAttribute('aria-disabled') === 'true').length, words: roots[0] ? off(roots[0]) : '',
      setOn: !!set && set.getAttribute('aria-disabled') !== 'true' && !set.disabled,
      levels: [...(document.querySelector('main select[aria-label="level"]')?.options ?? [])].map(o => o.value) }; })()`);
  const pickLevel = (lv) => ev(`(() => { const l = document.querySelector('main select[aria-label="level"]'); if (!l || ![...l.options].some(o => o.value === ${JSON.stringify(lv)})) return false;
    l.value = ${JSON.stringify(lv)}; l.dispatchEvent(new Event('change', { bubbles: true })); return true; })()`);
  const clickSet = () => ev(`(() => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent.trim() === 'Set...'); if (b) b.click(); return !!b; })()`);
  let tagSaid = '', tagOpened = '', instOpened = '', instPicked = '', instSubmit = null;
  if (await pickLevel('tag')) {
    await clickSet();
    // its own condition: the answer in words beside the button (a dialog that opened instead is read after it)
    tagSaid = await until(`[...document.querySelectorAll('main [role=status]')].map(x => x.textContent.trim()).find(t => /^Not set:/.test(t)) ?? ''`, 5000) ?? '';
    tagOpened = await openTitle(); await closeDialog();
  }
  if (await pickLevel('instance')) {
    // the instance picked is one the door carries (said in the line), and its dialog opens with its submit ON
    instPicked = await ev(`(() => { const p = document.querySelector('main select[aria-label="where"]'); const o = p && [...p.options].find(x => ${JSON.stringify(doorIds)}.includes(Number(x.value)));
      if (!o) return ''; p.value = o.value; p.dispatchEvent(new Event('change', { bubbles: true })); return o.value; })()`) ?? '';
    await clickSet(); await until(dialogOpenJS, 5000);
    instOpened = await openTitle();
    instSubmit = await ev(`(() => { const st = ${stJS}; const d = document.querySelector('dialog.act-dialog[open]'); return d ? st(d.querySelector('button[type=submit]')) : null; })()`);
    await closeDialog();
  }
  // (c) the root's two dialogs from the Summary's Options menu: Update off, its reason words in the dialog
  const viaOptions = async (first, second) => {
    await go('#/summary');
    const w = await menuWalk(first, second);   // redone once from Options when the page's refresh dropped the menu
    if (w.ok) await until(dialogOpenJS);
    const r = await ev(`(() => { const st = ${stJS}; const d = document.querySelector('dialog.act-dialog[open]'); if (!d) return { open: false, title: '', update: st(null) };
      return { open: true, title: d.getAttribute('aria-label') ?? '', update: st([...d.querySelectorAll('button')].find(x => x.textContent.trim() === 'Update')) }; })()`);
    await closeDialog();
    return { menus: w.said, ...r };
  };
  const dump = await viaOptions('/^Memory Dumps/', '/^Configure Thresholds/');
  const upt = await viaOptions('/^Instance Uptime/', '/^Configure Thresholds/');
  const wide = (w) => /reach past the demo's instances/.test(w ?? '');
  judge('R13', drv.root.found && drv.root.off && wide(drv.root.words) && drv.on > 0 && /^Drive space thresholds: the drive /.test(drvOpened)
    && thr.roots > 0 && thr.rootsOff === thr.roots && /^Demo: a threshold is set here for one demo instance/.test(thr.words) && thr.setOn
    && /^Not set: /.test(tagSaid) && wide(tagSaid) && !tagOpened && /^Threshold /.test(instOpened) && doorIds.includes(Number(instPicked)) && !!instSubmit && instSubmit.found && !instSubmit.off
    && dump.open && dump.title === 'Memory Dump Thresholds' && dump.update.off && wide(dump.update.words)
    && upt.open && /^Uptime Threshold Config \(root\)/.test(upt.title) && upt.update.off && wide(upt.update.words),
    `Drives at the root: the toolbar's Configure ${JSON.stringify(drv.root)}; ${drv.on} of ${drv.drives} drives' own Configure on, one clicked: '${drvOpened}'. `
    + `Thresholds: ${thr.rootsOff} of ${thr.roots} root Change buttons off ('${(thr.words ?? '').slice(0, 70)}...'); Set... on ${thr.setOn} (levels ${JSON.stringify(thr.levels)}); a tag picked: '${tagSaid}' (a dialog: '${tagOpened}'); a demo instance picked (id ${instPicked || 'none'}): '${instOpened}', its submit ${JSON.stringify(instSubmit)}. `
    + `Options > Memory Dumps > Configure Thresholds: '${dump.title}' Update ${JSON.stringify(dump.update)} (menus ${JSON.stringify(dump.menus)}); Options > Instance Uptime > Configure Thresholds: '${upt.title}' Update ${JSON.stringify(upt.update)} (menus ${JSON.stringify(upt.menus)})`);
}

if (shotsMissed.length) fail('shots', `not taken: ${shotsMissed.join(', ')}`);
ws.close();
console.log(fails ? `demodoor-check: ${fails} row(s) FAILED` : 'demodoor-check: every row ok');
process.exit(fails ? 1 : 0);
