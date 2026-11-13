// The demo's write door in a browser that CLICKS (task B7; run by scripts/proof-demodoor.sh).
//   node scripts/demodoor-check.mjs <cdp port> <base url> <the real instance's name> [<folder for the shots> [<the rig, JSON>]]
//   the rig: { jobs: [{ id, name, tab }] the demo instances with a failed job run, seed: the instance of the seed's own
//   silence, tagged: a real instance tagged demo by hand, nologin: the base url of a pgvigil serve -no-login on the same
//   repository } - each as the proof read or made it.
// It drives the page as a visitor of `pgvigil demo -serve` would: a click, the dialog's Save, the page after it - and
// reads the acknowledge log beside it: every click that writes must leave a NEWER log row than the newest one read
// before it, of the kind, the operation and the instance the click names. Every line is 'ok   <row>: ...' or
// 'FAIL <row>: ...'; a row that cannot find its control says what the page held instead. Exit 1 when any row failed.
// Needs node 22 or later (the global WebSocket and fetch).
import { mkdirSync, writeFileSync } from 'node:fs';
const [port, U, REAL, SHOTS, RIG] = process.argv.slice(2);
const rig = RIG ? JSON.parse(RIG) : {};
const failedJobs = rig.jobs ?? [], SEED = rig.seed ?? '', TAGGED = rig.tagged ?? '', NOLOGIN = rig.nologin ?? '';
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
const settled = () => until(`(() => { const m = document.querySelector('main'); if (!m) return false; const e = m.querySelector('p.empty');
  return !(e && /^Loading/.test(e.textContent)) && m.children.length > 0; })()`);
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
// the acknowledge log's newest row, and the row a click wrote: the newest one when it is not the one read before the
// click (an empty row otherwise, so a click that wrote nothing is never judged on an earlier click's row)
const lastLog = async () => tbl((await api('ack?part=log')).log)[0] ?? {};
const logKey = (l) => `${l.at}|${l.op}|${l.kind}|${l.ack_id}|${l.instance}`;
const mark = async () => logKey(await lastLog());
const wrote = async (before) => { const l = await lastLog(); return logKey(l) === before ? {} : l; };
const logLine = (l) => `${l.ui_user} / ${l.client} / ${l.kind} / ${l.op} / ${l.outcome} / ${l.instance}`;
const byDoor = (l, kind, op, instance) => l.ui_user === 'demo' && l.client === 'demo door' && l.kind === kind && l.op === op && l.outcome === 'done' && l.instance === instance;
// a dialog's answer: 'done N of N saved' (never 'not saved ...' or 'partly done ...'), 'done ended'
const saved = (a) => { const m = /^done (\d+) of (\d+) saved$/.exec(a ?? ''); return !!m && m[1] === m[2]; };
const ended = (a) => a === 'done ended';
// the visible words an off control points at (aria-describedby), '' when it has none or they are not on the page
const offWordsJS = `(b) => { const n = b && b.getAttribute('aria-describedby') ? document.getElementById(b.getAttribute('aria-describedby')) : null;
  return n && n.offsetParent !== null ? n.textContent.trim() : ''; }`;
// the open write dialog: fill what it needs, Save, read its answer, Close
const saveDialog = async (note) => {
  const open = await until(`!!document.querySelector('dialog.act-dialog[open]')`, 5000);
  if (!open) return { opened: false, answer: '' };
  const title = await ev(`document.querySelector('dialog.act-dialog[open] h3')?.textContent ?? ''`);
  if (note) await ev(`(() => { const t = document.querySelector('dialog.act-dialog[open] textarea'); if (t) { t.value = ${JSON.stringify(note)}; t.dispatchEvent(new Event('input', { bubbles: true })); } })()`);
  await ev(`document.querySelector('dialog.act-dialog[open] button[type=submit]').click()`);
  const answer = await until(`(() => { const p = document.querySelector('dialog.act-dialog[open] p[role=status]'); const t = p ? p.textContent.trim() : ''; return t && t !== 'Saving...' ? t : ''; })()`, 15000) ?? '';
  await ev(`(() => { const b = [...document.querySelectorAll('dialog.act-dialog[open] button[type=button]')].find(x => /Close|Back/.test(x.textContent)); if (b) b.click(); })()`);
  await sleep(1500); await settled();
  return { opened: true, title, answer };
};
// click the one button of main with this exact aria-label (and, when given, this text) that is on
const clickLabel = (label, text) => ev(`(() => { const b = [...document.querySelectorAll('main button[aria-label]')].find(x => x.getAttribute('aria-label') === ${JSON.stringify(label)}
  && ${text ? `x.textContent.trim() === ${JSON.stringify(text)} &&` : ''} x.getAttribute('aria-disabled') !== 'true' && !x.disabled); if (!b) return false; b.click(); return true; })()`);
const hasLabel = (label) => ev(`[...document.querySelectorAll('main button[aria-label]')].some(x => x.getAttribute('aria-label') === ${JSON.stringify(label)})`);

// ---- the door, as the page is told
const ack0 = await (async () => { await go('#/summary'); return api('ack?part=acks'); })();
const doorIds = ack0.door?.instances ?? [];
judge('door', ack0.writable === false && ack0.door?.user === 'demo' && doorIds.length > 0,
  `GET /api/ack: writable ${ack0.writable}, door user '${ack0.door?.user}', ${doorIds.length} instance(s)`);
const doorNames = tbl(await api('instances')).filter(i => doorIds.includes(Number(i.instance_id))).map(i => String(i.name));
const seat = await ev(`document.querySelector('[data-part=seat]')?.textContent ?? ''`);
judge('seat', /saved as user demo/.test(seat) && /nothing reaches a server/.test(seat), `the footer says whose door this is: '${seat}'`);

// ---- R1 the Summary's strip: Acknowledge on the first line that needs attention
const strip = await ev(`[...document.querySelectorAll('.attention-row')].map(r => { const b = r.querySelector('button[aria-label^="Acknowledge "]');
  const m = /[?&]i=(\\d+)/.exec(r.querySelector('strong a')?.getAttribute('href') ?? '');
  return { name: r.querySelector('strong')?.textContent.trim() ?? '', id: m ? Number(m[1]) : 0, btn: !!b, off: b?.getAttribute('aria-disabled') === 'true' || !!b?.disabled }; })`);
await shot('1-summary-before');
// what Allen saw under the strip at 19:03: 'Acknowledge is off: acknowledgements need the UI login: this server runs with -no-login'
const offSaid = await ev(`(/Acknowledge is off[^.]*/.exec(document.querySelector('main')?.textContent ?? '') ?? [''])[0]`);
const line = (strip ?? []).find(r => r.btn && !r.off && r.name !== REAL);
const ackCells = () => ev(`document.querySelectorAll('main .ack').length`);
let acked = '';
if (!line) fail('R1', `no line of the strip has an Acknowledge that is on: ${JSON.stringify((strip ?? []).slice(0, 6))}`);
else {
  const before = await ackCells(), m0 = await mark();
  await ev(`[...document.querySelectorAll('.attention-row')].find(r => r.querySelector('strong')?.textContent.trim() === ${JSON.stringify(line.name)}).querySelector('button[aria-label^="Acknowledge "]').click()`);
  await sleep(300); await shot('2-summary-acknowledge-dialog');
  const d = await saveDialog('demo door proof');
  await shot('3-summary-after-acknowledge');
  const after = await ackCells();
  const still = await ev(`[...document.querySelectorAll('.attention-row strong')].some(s => s.textContent.trim() === ${JSON.stringify(line.name)})`);
  const listed = await ev(`[...document.querySelectorAll('main details li')].filter(li => li.textContent.includes(${JSON.stringify(line.name)}) && /acknowledged by demo/.test(li.textContent)).length`);
  const log = await wrote(m0);
  acked = line.name;
  judge('R1', !offSaid && d.opened && saved(d.answer) && !still && after > before && listed > 0 && byDoor(log, 'ack', 'add', line.name),
    `${line.name}: the page says 'Acknowledge is off' nowhere (${offSaid ? `it says '${offSaid}'` : 'true'}); the dialog '${d.title}' answered '${d.answer}'; its line left the strip (${!still}); acknowledged cells ${before} -> ${after}; ${listed} of its checks listed 'acknowledged by demo'; the log's new row ${logLine(log)}`);
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
    await shot('4-instance-page-before');
    const h0 = await head();
    if (!h0.found || h0.name !== inst.name || h0.off || !['Silence', 'Unsilence'].includes(h0.btn))
      fail('R1b-a', `${inst.name}'s own page (#/summary?i=${inst.id}): the header's Silence is not there, or off: ${JSON.stringify(h0)}`);
    else {
      const steps = [];
      for (const want of (h0.btn === 'Silence' ? ['Silence', 'Unsilence'] : ['Unsilence', 'Silence'])) {
        const m0 = await mark();
        const clicked = await headClick(want);
        const d = clicked ? await saveDialog(want === 'Silence' ? 'demo door proof, the instance page' : undefined) : { opened: false, answer: '' };
        const log = await wrote(m0), h = await head();
        await shot(want === 'Silence' ? '4b-instance-page-silenced' : '4c-instance-page-unsilenced');
        steps.push({ want, clicked, answer: d.answer, log: logLine(log), bell: !!h.bell, next: h.btn,
          good: clicked && d.opened && (want === 'Silence' ? saved(d.answer) && byDoor(log, 'silence', 'add', inst.name) && h.bell === true && h.btn === 'Unsilence'
            : ended(d.answer) && byDoor(log, 'silence', 'end', inst.name) && h.bell === false && h.btn === 'Silence') });
      }
      judge('R1b-a', steps.every(x => x.good), `${inst.name}'s own page (${h0.hash}), the header: ` + steps.map(x =>
        `'${x.want}' clicked ${x.clicked}, answered '${x.answer}', the header then ${x.bell ? 'with' : 'without'} the silenced mark and '${x.next}', the log's new row ${x.log}`).join('; '));
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
      await sleep(300); await shot('5b-instance-jobs-acknowledge-dialog');
      const d = await saveDialog();
      const clear = 'Clear the acknowledgement of ' + job.label.replace(/^Acknowledge /, '');
      const cell = await until(`(() => { const c = [...document.querySelectorAll('main button[aria-label]')].find(x => x.getAttribute('aria-label') === ${JSON.stringify(clear)});
        return c ? { text: c.parentElement.textContent.trim(), clearOn: c.getAttribute('aria-disabled') !== 'true' && !c.disabled } : null; })()`, 10000);
      const again = await hasLabel(job.label);
      await ev(`[...document.querySelectorAll('main button[aria-label]')].find(x => x.getAttribute('aria-label') === ${JSON.stringify(clear)})?.scrollIntoView({ block: 'center', inline: 'center' })`); await sleep(200);
      await shot('5c-instance-jobs-acknowledged');
      const log = await wrote(m0);
      judge('R1b-b', d.opened && saved(d.answer) && !!cell && cell.clearOn && /^acknowledged /.test(cell.text) && !again && byDoor(log, 'job', 'add', inst.name),
        `${inst.name}'s Jobs page (${job.hash}): '${job.label}' clicked, '${d.title}' answered '${d.answer}'; its cell then reads '${cell?.text ?? ''}' (Clear on: ${cell?.clearOn ?? false}), the Acknowledge button gone (${!again}); the log's new row ${logLine(log)}`);
    }
    await go('#/summary');
  }
}

// ---- R3 Unacknowledge one of them from the acknowledged list: the cell is back
if (acked) {
  await ev(`(() => { const d = [...document.querySelectorAll('main details')].find(x => /acknowledged check/.test(x.querySelector('summary')?.textContent ?? '')); if (d) d.open = true; })()`);
  const before = await ackCells(), m0 = await mark();
  const found = await ev(`(() => { const li = [...document.querySelectorAll('main details li')].find(x => x.textContent.includes(${JSON.stringify(acked)})); const b = li?.querySelector('button'); if (!b) return false; b.click(); return true; })()`);
  if (!found) fail('R3', `no Unacknowledge button beside ${acked}'s acknowledged checks`);
  else {
    const d = await saveDialog();
    const after = await ackCells();
    const log = await wrote(m0);
    judge('R3', d.opened && ended(d.answer) && after < before && byDoor(log, 'ack', 'end', acked),
      `${acked}: '${d.title}' answered '${d.answer}'; acknowledged cells ${before} -> ${after}; the log's new row ${logLine(log)}`);
  }
}

// ---- R2 a cell through the toolbar: Options > Memory Dumps > Acknowledge Dumps
{
  const menuClick = (re) => ev(`(() => { const b = [...document.querySelectorAll('[role=menu] [role=menuitem]')].find(x => ${re}.test(x.textContent)); if (!b) return [...document.querySelectorAll('[role=menu] [role=menuitem]')].map(x => x.textContent); b.click(); return true; })()`);
  const m0 = await mark();
  const opened = await ev(`(() => { const b = [...document.querySelectorAll('button.tb-btn')].find(x => x.textContent.trim() === 'Options'); if (!b) return false; b.click(); return true; })()`);
  await sleep(300);
  const m1 = opened ? await menuClick('/^Memory Dumps/') : null; await sleep(300);
  const m2 = m1 === true ? await menuClick('/^Acknowledge Dumps/') : null;
  const said = m2 === true ? await until(`(() => { const t = [...document.querySelectorAll('main p, main span')].map(x => x.textContent).find(x => /Memory dumps acknowledged on|No Memory dumps cell|Acknowledge is off/.test(x)); return t || ''; })()`, 15000) : '';
  const log = await wrote(m0);
  judge('R2', /Memory dumps acknowledged on [1-9]/.test(said ?? '') && !/not saved/.test(said ?? '') && log.ui_user === 'demo' && log.client === 'demo door' && log.kind === 'ack' && log.op === 'add' && log.outcome === 'done' && doorNames.includes(String(log.instance)),
    `Options > Memory Dumps > Acknowledge Dumps: the page said '${said}' (menus: Options ${opened}, ${JSON.stringify(m1)}, ${JSON.stringify(m2)}); the log's new row ${logLine(log)}`);
}

// ---- R7 the instances that are not the demo's - a real one, and a real one tagged demo by hand: off, each with its
// reason in words on the page; a demo instance's Silence is on
{
  await go('#/summary');
  const silenceOf = (name) => ev(`(() => { const off = ${offWordsJS};
    const rows = [...document.querySelectorAll('main tr')].filter(tr => [...tr.querySelectorAll('td, th')].some(c => c.textContent.trim() === ${JSON.stringify(name)}));
    const b = rows.map(tr => tr.querySelector('button.silence-btn')).find(Boolean);
    return b ? { found: true, off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled, words: off(b), label: b.textContent.trim() } : { found: false, rows: rows.length }; })()`);
  const real = await silenceOf(REAL);
  const tagged = TAGGED ? await silenceOf(TAGGED) : null;
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
  const offRight = (x, name) => !!x && x.found && x.off && !x.disabledAttr && x.words.includes(`${name} is not one of this demo's instances`);
  judge('R7', offRight(real, REAL) && (!TAGGED || offRight(tagged, TAGGED)) && !!demoRow,
    `${REAL}'s Silence on the Summary: ${JSON.stringify(real)}; ${TAGGED || 'no tagged instance'}'s (tagged demo by hand): ${JSON.stringify(tagged)}; a demo instance's Silence is on ('${demoRow}')`);
}

// ---- R6 a silence on a demo instance from the Summary's row, then the Unsilence of THAT instance
{
  const m0 = await mark();
  const label = await ev(`(() => { const b = [...document.querySelectorAll('main button.silence-btn')].find(x => x.getAttribute('aria-disabled') !== 'true' && !x.disabled && x.textContent.trim() === 'Silence'); if (!b) return ''; b.click(); return b.getAttribute('aria-label'); })()`);
  const who = (/^Silence all alerts for '(.*)'$/.exec(label ?? '') ?? [])[1] ?? '';
  if (!who) fail('R6', `no Silence button that is on (its label: '${label}')`);
  else {
    const d = await saveDialog('demo door proof');
    const log = await wrote(m0);
    const m1 = await mark();
    const un = await clickLabel(`Unsilence '${who}'`, 'Unsilence');
    const d2 = un ? await saveDialog() : { opened: false, answer: '' };
    const log2 = await wrote(m1);
    judge('R6', d.opened && saved(d.answer) && byDoor(log, 'silence', 'add', who) && un && ended(d2.answer) && byDoor(log2, 'silence', 'end', who),
      `'${label}': '${d.answer}' (the log's new row ${logLine(log)}); 'Unsilence '${who}'' drawn and clicked ${un}, answered '${d2.answer}' (the log's new row ${logLine(log2)})`);
  }
}

// ---- R4 a note on an open alert of a demo instance (Alerts: tick one, Add notes to selected alerts)
{
  await go('#/alerts');
  const ticked = await ev(`(() => { const names = ${JSON.stringify(doorNames)};
    for (const tr of document.querySelectorAll('main table tbody tr')) { const c = tr.querySelector('input[type=checkbox]'); if (!c) continue;
      const n = [...tr.querySelectorAll('td')].map(td => td.textContent.trim()).find(t => names.includes(t)); if (n) { c.click(); return n; } }
    return ''; })()`);
  const m0 = await mark();
  const btn = await ev(`(() => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent.trim() === 'Add notes to selected alerts'); if (!b) return 'absent'; if (b.getAttribute('aria-disabled') === 'true' || b.disabled) return 'off'; b.click(); return 'clicked'; })()`);
  const d = btn === 'clicked' ? await saveDialog('seen by the demo door proof') : { opened: false, answer: '' };
  const log = await wrote(m0);
  judge('R4', !!ticked && d.opened && saved(d.answer) && byDoor(log, 'note', 'add', ticked),
    `an alert of ${ticked || 'no demo instance'} ticked, 'Add notes to selected alerts' ${btn}: '${d.title}' answered '${d.answer}'; the log's new row ${logLine(log)}`);
  await shot('7-alerts-after-note');
  // what stays off on the Alerts page says why in words: Send test, Mute similar
  const offs = await ev(`(() => { const off = ${offWordsJS}; const pick = (re) => { const b = [...document.querySelectorAll('main button')].find(x => re.test(x.textContent.trim())); return b ? { off: b.getAttribute('aria-disabled') === 'true', words: off(b) } : null; };
    return { test: pick(/^Send test$/), similar: pick(/^Mute similar$/) }; })()`);
  judge('R9a', !!offs.test && offs.test.off && /runs no sender/.test(offs.test.words) && !!offs.similar && offs.similar.off && /reach past the demo's instances/.test(offs.similar.words),
    `on the Alerts page: Send test ${JSON.stringify(offs.test)}, Mute similar ${JSON.stringify(offs.similar)}`);
}

// ---- R6b the demo's OWN seeded silence (stored by the instance's name, without an id) has its Unsilence on the
// Alerts page's list of silenced servers, and it works (the review's fold: the list drew no button for it). The button
// is the one that names the seed's instance: R6 ended its own silence, so no other is live.
{
  await go('#/alerts');
  const label = `Unsilence ${SEED}`;
  const m0 = await mark();
  const clicked = SEED ? await clickLabel(label, 'Unsilence') : false;
  if (!clicked) fail('R6b', `the Alerts page offers no '${label}' that is on (the seed's silence); its silence and blackout buttons: ${JSON.stringify(await ev(`[...document.querySelectorAll('main button[aria-label]')].map(x => x.getAttribute('aria-label')).filter(t => /silence|blackout/i.test(t)).slice(0, 8)`))}`);
  else {
    const d = await saveDialog();
    const log = await wrote(m0);
    const still = await hasLabel(label);
    await shot('8-alerts-seed-silence-ended');
    judge('R6b', d.opened && ended(d.answer) && !still && byDoor(log, 'silence', 'end', SEED),
      `the Alerts page's list of silenced servers: '${label}' clicked, answered '${d.answer}', its button gone (${!still}); the log's new row ${logLine(log)}`);
  }
}

// ---- R10 a server that writes nothing at all (pgvigil serve -no-login on the same repository): a page says the reason
// ONCE and every off control points at that one sentence - never the same words beside each control, never inside a
// grid cell (Copy all and the exports carry a cell's text)
if (NOLOGIN) {
  const fj = failedJobs[0];
  const read = async (hash, shotName) => {
    await goTo(NOLOGIN, hash); await sleep(200);
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
  for (const [hash, what, shotName] of pagesOff) got.push({ what, ...(await read(hash, shotName)) });
  judge('R10', got.every(g => g.off > 0 && g.undescribed === 0 && g.unseen === 0 && g.repeated === 0 && g.noteCells === 0 && g.times === 1 && g.cells === 0),
    'pgvigil serve -no-login on the same repository: ' + got.map(g => `${g.what}: ${g.off} off control(s), ${g.undescribed} without a description, ${g.unseen} pointing at words not on the page, ${g.sentences} sentence(s) of which ${g.repeated} repeated, its words ${g.times} time(s) on the page and in ${g.cells} grid cell(s), ${g.noteCells} note(s) inside a grid cell ('${g.first}')`).join('; '));
}

// ---- R12 (DONE-2) every page of the MIXED store: a control that is off says why in words on the page. The walk is
// the tab strip's own list (as scripts/a11y-check.mjs reads it) at the root and on four instances - a PostgreSQL demo
// instance on premises, the demo's Aurora instance with a failed job, the demo's SQL Server primary, and the real
// instance beside them - each page once, and on each the rule proof-a11y applies to three pages: every control that
// is off and shown (the disabled attribute or aria-disabled) has a visible, non-empty description (aria-describedby)
// that is words, not a badge alone.
{
  const offOnPage = () => ev(`(() => {
    const vis = e => !!(e && e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden');
    const ctl = [...document.querySelectorAll('main button, main input, main select, main textarea, dialog button')]
      .filter(e => (e.disabled || e.getAttribute('aria-disabled') === 'true') && vis(e));
    const said = x => x.textContent.replace(/^\\s*(off|not checked|demo|note|on|declined)\\b/i, '').trim().length > 0;
    const bad = ctl.filter(e => !(e.getAttribute('aria-describedby') || '').split(/\\s+/).filter(Boolean).some(i => { const x = document.getElementById(i); return vis(x) && said(x); }));
    return { off: ctl.length, bad: bad.map(e => (e.tagName + ' ' + (e.textContent || e.getAttribute('aria-label') || '').trim()).slice(0, 40)) }; })()`);
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
  let offSeen = 0; const bad = [], unrendered = [];
  for (const [what, h] of pages) {
    await cmd('Page.navigate', { url: U + h }); await sleep(250);
    if (!(await settled())) { unrendered.push(h); continue; }
    await sleep(250);
    const r = await offOnPage();
    const sh = shotOf.find(([re, name]) => re.test(h) && !shotDone.has(name));
    if (sh && r.off > 0) {
      shotDone.add(sh[1]);
      await ev(`[...document.querySelectorAll('main button')].find(b => b.getAttribute('aria-disabled') === 'true' || b.disabled)?.scrollIntoView({ block: 'center', inline: 'center' })`);
      await sleep(250); await shot(sh[1]);
    }
    offSeen += r.off;
    if (r.bad.length) bad.push(`${h} (${what}): ${r.bad.length} - ${[...new Set(r.bad)].slice(0, 5).join('; ')}`);
  }
  judge('R12', pages.length > 100 && bad.length === 0 && unrendered.length === 0,
    `${pages.length} pages of the mixed store walked (${walk.map(w => w[0]).join(', ')}), ${offSeen} off control(s) seen; ${unrendered.length} page(s) did not render${unrendered.length ? ` (${unrendered.slice(0, 5).join(', ')})` : ''}; ${bad.length} page(s) with an off control without its reason in words${bad.length ? ':' : ''}`);
  for (const b of bad) console.log(`     R12 ${b}`);
}

// ---- R13 (DONE-2) the threshold dialogs on a demo serve: a level wider than one instance is OFF in words BEFORE a
// request is made (never a control that is on and then answers 403), and one demo instance's own level is on
{
  const stJS = `(b) => b ? { found: true, off: b.getAttribute('aria-disabled') === 'true' || b.disabled, words: (${offWordsJS})(b) } : { found: false, off: false, words: '' }`;
  const openTitle = () => ev(`document.querySelector('dialog.act-dialog[open]')?.getAttribute('aria-label') ?? ''`);
  const closeDialog = async () => { await ev(`document.querySelector('dialog.act-dialog[open]')?.close()`); await sleep(200); };
  // (a) Drives at the root: the toolbar's Configure sets the ROOT's level - off; a demo drive's own Configure is on
  await go('#/drives');
  const drv = await ev(`(() => { const st = ${stJS}; const isOn = b => b.getAttribute('aria-disabled') !== 'true' && !b.disabled;
    const tb = [...document.querySelectorAll('main .toolbar button')].find(b => b.textContent.trim() === 'Configure');
    const own = [...document.querySelectorAll('main button[aria-label^="Configure the thresholds of "]')];
    const on = own.find(isOn); if (on) on.click();
    return { root: st(tb), drives: own.length, on: own.filter(isOn).length }; })()`);
  await sleep(400);
  const drvOpened = await openTitle(); await closeDialog();
  // (b) the Thresholds page: the root's Change buttons off for the page's one sentence; 'Set...' on - a tag picked is
  // answered in words beside the button and no dialog opens, a demo instance picked opens the dialog
  await go('#/pgthresholds');
  const thr = await ev(`(() => { const off = ${offWordsJS};
    const roots = [...document.querySelectorAll('main button[aria-label$=" at the root"]')];
    const set = [...document.querySelectorAll('main button')].find(b => b.textContent.trim() === 'Set...');
    return { roots: roots.length, rootsOff: roots.filter(b => b.getAttribute('aria-disabled') === 'true').length, words: roots[0] ? off(roots[0]) : '',
      setOn: !!set && set.getAttribute('aria-disabled') !== 'true' && !set.disabled,
      levels: [...(document.querySelector('main select[aria-label="level"]')?.options ?? [])].map(o => o.value) }; })()`);
  const pickLevel = (lv) => ev(`(() => { const l = document.querySelector('main select[aria-label="level"]'); if (!l || ![...l.options].some(o => o.value === ${JSON.stringify(lv)})) return false;
    l.value = ${JSON.stringify(lv)}; l.dispatchEvent(new Event('change', { bubbles: true })); return true; })()`);
  const clickSet = () => ev(`(() => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent.trim() === 'Set...'); if (b) b.click(); return !!b; })()`);
  let tagSaid = '', tagOpened = '', instOpened = '';
  if (await pickLevel('tag')) {
    await clickSet(); await sleep(400);
    tagSaid = await ev(`[...document.querySelectorAll('main [role=status]')].map(x => x.textContent.trim()).find(t => /^Not set:/.test(t)) ?? ''`);
    tagOpened = await openTitle(); await closeDialog();
  }
  if (await pickLevel('instance')) {
    await ev(`(() => { const p = document.querySelector('main select[aria-label="where"]'); const o = p && [...p.options].find(x => ${JSON.stringify(doorIds)}.includes(Number(x.value)));
      if (o) { p.value = o.value; p.dispatchEvent(new Event('change', { bubbles: true })); } })()`);
    await clickSet(); await sleep(400);
    instOpened = await openTitle(); await closeDialog();
  }
  // (c) the root's two dialogs from the Summary's Options menu: Update off, its reason words in the dialog
  const viaOptions = async (first, second) => {
    await go('#/summary');
    const item = (re) => ev(`(() => { const b = [...document.querySelectorAll('[role=menu] [role=menuitem]')].find(x => ${re}.test(x.textContent)); if (!b) return false; b.click(); return true; })()`);
    const o = await ev(`(() => { const b = [...document.querySelectorAll('button.tb-btn')].find(x => x.textContent.trim() === 'Options'); if (!b) return false; b.click(); return true; })()`);
    await sleep(300); const a = o && await item(first); await sleep(300); const b = a && await item(second); await sleep(600);
    const r = await ev(`(() => { const st = ${stJS}; const d = document.querySelector('dialog.act-dialog[open]'); if (!d) return { open: false, title: '', update: st(null) };
      return { open: true, title: d.getAttribute('aria-label') ?? '', update: st([...d.querySelectorAll('button')].find(x => x.textContent.trim() === 'Update')) }; })()`);
    await closeDialog();
    return { menus: [o, a, b], ...r };
  };
  const dump = await viaOptions('/^Memory Dumps/', '/^Configure Thresholds/');
  const upt = await viaOptions('/^Instance Uptime/', '/^Configure Thresholds/');
  const wide = (w) => /reach past the demo's instances/.test(w ?? '');
  judge('R13', drv.root.found && drv.root.off && wide(drv.root.words) && drv.on > 0 && /^Drive space thresholds: the drive /.test(drvOpened)
    && thr.roots > 0 && thr.rootsOff === thr.roots && /^Demo: a threshold is set here for one demo instance/.test(thr.words) && thr.setOn
    && /^Not set: /.test(tagSaid) && wide(tagSaid) && !tagOpened && /^Threshold /.test(instOpened)
    && dump.open && dump.update.off && wide(dump.update.words) && upt.open && upt.update.off && wide(upt.update.words),
    `Drives at the root: the toolbar's Configure ${JSON.stringify(drv.root)}; ${drv.on} of ${drv.drives} drives' own Configure on, one clicked: '${drvOpened}'. `
    + `Thresholds: ${thr.rootsOff} of ${thr.roots} root Change buttons off ('${(thr.words ?? '').slice(0, 70)}...'); Set... on ${thr.setOn} (levels ${JSON.stringify(thr.levels)}); a tag picked: '${tagSaid}' (a dialog: '${tagOpened}'); a demo instance picked: '${instOpened}'. `
    + `Options > Memory Dumps > Configure Thresholds: '${dump.title}' Update ${JSON.stringify(dump.update)} (menus ${JSON.stringify(dump.menus)}); Options > Instance Uptime > Configure Thresholds: '${upt.title}' Update ${JSON.stringify(upt.update)} (menus ${JSON.stringify(upt.menus)})`);
}

if (shotsMissed.length) fail('shots', `not taken: ${shotsMissed.join(', ')}`);
ws.close();
console.log(fails ? `demodoor-check: ${fails} row(s) FAILED` : 'demodoor-check: every row ok');
process.exit(fails ? 1 : 0);
