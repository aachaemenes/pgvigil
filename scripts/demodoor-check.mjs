// The demo's write door in a browser that CLICKS (task B7; run by scripts/proof-demodoor.sh).
//   node scripts/demodoor-check.mjs <cdp port> <base url> <the real instance's name> [<folder for the shots>]
// It drives the page as a visitor of `pgvigil demo -serve` would: a click, the dialog's Save, the page after it - and
// reads the acknowledge log beside it. Every line is 'ok   <row>: ...' or 'FAIL <row>: ...'; a row that cannot find
// its control says what the page held instead. Exit 1 when any row failed.
import { mkdirSync, writeFileSync } from 'node:fs';
const [port, U, REAL, SHOTS] = process.argv.slice(2);
if (SHOTS) mkdirSync(SHOTS, { recursive: true });

const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
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
const go = async (hash) => { await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + hash }); await sleep(400); await settled(); await sleep(600); };

// a shot of the page as it stands (kept by the proof: what a visitor sees before and after each click)
const shot = async (name) => { if (!SHOTS) return; const d = await cmd('Page.captureScreenshot', { format: 'png' });
  if (d.result?.data) writeFileSync(`${SHOTS}/${name}.png`, Buffer.from(d.result.data, 'base64')); };

let fails = 0;
const ok = (row, text) => console.log(`ok   ${row}: ${text}`);
const fail = (row, text) => { fails++; console.log(`FAIL ${row}: ${text}`); };
const judge = (row, good, text) => (good ? ok : fail)(row, text);

// the page's own fetch, so the header rule and the Host are the browser's
const api = (path) => ev(`fetch(${JSON.stringify('/api/' + path)}).then(r => r.json())`, true);
const tbl = (t) => (t?.rows ?? []).map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]])));
const lastLog = async () => tbl((await api('ack?part=log')).log)[0] ?? {};
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

// ---- the door, as the page is told
const ack0 = await (async () => { await go('#/summary'); return api('ack?part=acks'); })();
judge('door', ack0.writable === false && ack0.door?.user === 'demo' && (ack0.door?.instances ?? []).length > 0,
  `GET /api/ack: writable ${ack0.writable}, door user '${ack0.door?.user}', ${(ack0.door?.instances ?? []).length} instance(s)`);
const seat = await ev(`document.querySelector('[data-part=seat]')?.textContent ?? ''`);
judge('seat', /saved as user demo/.test(seat) && /nothing reaches a server/.test(seat), `the footer says whose door this is: '${seat}'`);

// ---- R1 the Summary's strip: Acknowledge on the first line that needs attention
const strip = await ev(`[...document.querySelectorAll('.attention-row')].map(r => { const b = r.querySelector('button[aria-label^="Acknowledge "]');
  const m = /[?&]i=(\\d+)/.exec(r.querySelector('strong a')?.getAttribute('href') ?? '');
  return { name: r.querySelector('strong')?.textContent.trim() ?? '', id: m ? Number(m[1]) : 0, btn: !!b, off: b?.getAttribute('aria-disabled') === 'true' || !!b?.disabled }; })`);
await shot('1-summary-before');
const line = (strip ?? []).find(r => r.btn && !r.off && r.name !== REAL);
const ackCells = () => ev(`document.querySelectorAll('main .ack').length`);
let acked = '';
if (!line) fail('R1', `no line of the strip has an Acknowledge that is on: ${JSON.stringify((strip ?? []).slice(0, 6))}`);
else {
  const before = await ackCells();
  await ev(`[...document.querySelectorAll('.attention-row')].find(r => r.querySelector('strong')?.textContent.trim() === ${JSON.stringify(line.name)}).querySelector('button[aria-label^="Acknowledge "]').click()`);
  await sleep(300); await shot('2-summary-acknowledge-dialog');
  const d = await saveDialog('demo door proof');
  await shot('3-summary-after-acknowledge');
  const after = await ackCells();
  const still = await ev(`[...document.querySelectorAll('.attention-row strong')].some(s => s.textContent.trim() === ${JSON.stringify(line.name)})`);
  const listed = await ev(`[...document.querySelectorAll('main details li')].filter(li => li.textContent.includes(${JSON.stringify(line.name)}) && /acknowledged by demo/.test(li.textContent)).length`);
  const log = await lastLog();
  acked = line.name;
  judge('R1', d.opened && /saved/.test(d.answer) && !still && after > before && listed > 0 && log.ui_user === 'demo' && log.outcome === 'done' && log.client === 'demo door',
    `${line.name}: the dialog '${d.title}' answered '${d.answer}'; its line left the strip (${!still}); acknowledged cells ${before} -> ${after}; ${listed} of its checks listed 'acknowledged by demo'; the log's newest row ${log.ui_user} / ${log.client} / ${log.op} / ${log.outcome}`);
}

// ---- R1b an instance's own page (a DEMO instance): Acknowledge there
{
  const other = (strip ?? []).find(r => r.btn && !r.off && r.name !== REAL && r.name !== acked && r.id > 0);
  if (!other) fail('R1b', `no second line of the strip with an Acknowledge that is on and an instance link: ${JSON.stringify((strip ?? []).slice(0, 6))}`);
  else {
    await go(`#/summary?i=${other.id}`);
    await shot('4-instance-page-before');
    const here = await ev(`(() => { const rows = [...document.querySelectorAll('main .attention-row')]; const b = rows.map(r => r.querySelector('button[aria-label^="Acknowledge "]')).find(x => x && x.getAttribute('aria-disabled') !== 'true' && !x.disabled);
      if (!b) return { clicked: false, hash: location.hash, h2: document.querySelector('main h2')?.textContent ?? '', buttons: [...document.querySelectorAll('main button')].map(x => x.textContent.trim()).filter(Boolean).slice(0, 40) };
      b.click(); return { clicked: true, hash: location.hash, h2: document.querySelector('main h2')?.textContent ?? '' }; })()`);
    if (!here.clicked) fail('R1b', `${other.name}'s page (${here.hash}, '${here.h2}') has no Acknowledge that is on; its buttons: ${JSON.stringify(here.buttons)}`);
    else {
      const d = await saveDialog('demo door proof, the instance page');
      await shot('5-instance-page-after-acknowledge');
      const still = await ev(`[...document.querySelectorAll('main .attention-row strong')].some(s => s.textContent.trim() === ${JSON.stringify(other.name)})`);
      const log = await lastLog();
      judge('R1b', d.opened && /saved/.test(d.answer) && !still && log.ui_user === 'demo' && log.outcome === 'done' && log.instance === other.name,
        `${other.name}'s own page (${here.hash}): '${d.title}' answered '${d.answer}'; its line left (${!still}); the log's newest row ${log.ui_user} / ${log.instance} / ${log.op} / ${log.outcome}`);
    }
    await go('#/summary');
  }
}

// ---- R3 Unacknowledge one of them from the acknowledged list: the cell is back
if (acked) {
  await ev(`(() => { const d = [...document.querySelectorAll('main details')].find(x => /acknowledged check/.test(x.querySelector('summary')?.textContent ?? '')); if (d) d.open = true; })()`);
  const before = await ackCells();
  const found = await ev(`(() => { const li = [...document.querySelectorAll('main details li')].find(x => x.textContent.includes(${JSON.stringify(acked)})); const b = li?.querySelector('button'); if (!b) return false; b.click(); return true; })()`);
  if (!found) fail('R3', `no Unacknowledge button beside ${acked}'s acknowledged checks`);
  else {
    const d = await saveDialog();
    const after = await ackCells();
    const log = await lastLog();
    judge('R3', d.opened && /ended/.test(d.answer) && after < before && log.op === 'end' && log.ui_user === 'demo' && log.outcome === 'done',
      `${acked}: '${d.title}' answered '${d.answer}'; acknowledged cells ${before} -> ${after}; the log's newest row ${log.ui_user} / ${log.op} / ${log.outcome}`);
  }
}

// ---- R2 a cell through the toolbar: Options > Memory Dumps > Acknowledge Dumps
{
  const menuClick = (re) => ev(`(() => { const b = [...document.querySelectorAll('[role=menu] [role=menuitem]')].find(x => ${re}.test(x.textContent)); if (!b) return [...document.querySelectorAll('[role=menu] [role=menuitem]')].map(x => x.textContent); b.click(); return true; })()`);
  const opened = await ev(`(() => { const b = [...document.querySelectorAll('button.tb-btn')].find(x => x.textContent.trim() === 'Options'); if (!b) return false; b.click(); return true; })()`);
  await sleep(300);
  const m1 = opened ? await menuClick('/^Memory Dumps/') : null; await sleep(300);
  const m2 = m1 === true ? await menuClick('/^Acknowledge Dumps/') : null;
  const said = m2 === true ? await until(`(() => { const t = [...document.querySelectorAll('main p, main span')].map(x => x.textContent).find(x => /Memory dumps acknowledged on|No Memory dumps cell|Acknowledge is off/.test(x)); return t || ''; })()`, 15000) : '';
  const log = await lastLog();
  judge('R2', /Memory dumps acknowledged on [1-9]/.test(said ?? '') && !/not saved/.test(said ?? '') && log.ui_user === 'demo' && log.outcome === 'done',
    `Options > Memory Dumps > Acknowledge Dumps: the page said '${said}' (menus: Options ${opened}, ${JSON.stringify(m1)}, ${JSON.stringify(m2)}); the log's newest row ${log.ui_user} / ${log.op} / ${log.outcome}`);
}

// ---- R7 the instance that is not the demo's: off, with its reason in words on the page
{
  await go('#/summary');
  const real = await ev(`(() => { const off = ${offWordsJS};
    const rows = [...document.querySelectorAll('main tr')].filter(tr => [...tr.querySelectorAll('td, th')].some(c => c.textContent.trim() === ${JSON.stringify(REAL)}));
    const b = rows.map(tr => tr.querySelector('button.silence-btn')).find(Boolean);
    return b ? { found: true, off: b.getAttribute('aria-disabled') === 'true', disabledAttr: b.disabled, words: off(b), label: b.textContent.trim() } : { found: false, rows: rows.length }; })()`);
  await shot('6-summary-mixed-store');
  const demoRow = await ev(`(() => { const b = [...document.querySelectorAll('main button.silence-btn')].find(x => x.getAttribute('aria-disabled') !== 'true' && !x.disabled); return b ? b.getAttribute('aria-label') : ''; })()`);
  judge('R7', real?.found && real.off && !real.disabledAttr && real.words.includes(`${REAL} is not one of this demo's instances`) && !!demoRow,
    `${REAL}'s Silence on the Summary: ${JSON.stringify(real)}; a demo instance's Silence is on ('${demoRow}')`);
}

// ---- R6 a silence on a demo instance from the Summary's row, then Unsilence
{
  const name = await ev(`(() => { const b = [...document.querySelectorAll('main button.silence-btn')].find(x => x.getAttribute('aria-disabled') !== 'true' && !x.disabled && x.textContent.trim() === 'Silence'); if (!b) return ''; b.click(); return b.getAttribute('aria-label'); })()`);
  if (!name) fail('R6', 'no Silence button that is on');
  else {
    const d = await saveDialog('demo door proof');
    const log = await lastLog();
    const un = await ev(`(() => { const b = [...document.querySelectorAll('main button.silence-btn')].find(x => x.textContent.trim() === 'Unsilence' && x.getAttribute('aria-disabled') !== 'true'); if (!b) return false; b.click(); return true; })()`);
    const d2 = un ? await saveDialog() : { opened: false, answer: '' };
    const log2 = await lastLog();
    judge('R6', d.opened && /saved/.test(d.answer) && log.kind === 'silence' && log.ui_user === 'demo' && un && /ended/.test(d2.answer) && log2.op === 'end',
      `'${name}': '${d.answer}' (the log: ${log.ui_user} / ${log.kind} / ${log.outcome}); Unsilence drawn ${un}, answered '${d2.answer}' (the log: ${log2.op} / ${log2.outcome})`);
  }
}

// ---- R4 a note on an open alert (Alerts: tick one, Add notes to selected alerts)
{
  await go('#/alerts');
  const ticked = await ev(`(() => { const c = document.querySelector('main table input[type=checkbox]:not([aria-label*="all" i])') ?? document.querySelectorAll('main table input[type=checkbox]')[1]; if (!c) return false; c.click(); return true; })()`);
  const btn = await ev(`(() => { const b = [...document.querySelectorAll('main button')].find(x => x.textContent.trim() === 'Add notes to selected alerts'); if (!b) return 'absent'; if (b.getAttribute('aria-disabled') === 'true' || b.disabled) return 'off'; b.click(); return 'clicked'; })()`);
  const d = btn === 'clicked' ? await saveDialog('seen by the demo door proof') : { opened: false, answer: '' };
  const log = await lastLog();
  judge('R4', ticked && d.opened && /saved/.test(d.answer) && log.kind === 'note' && log.ui_user === 'demo' && log.outcome === 'done',
    `an alert ticked ${ticked}, 'Add notes to selected alerts' ${btn}: '${d.title}' answered '${d.answer}'; the log's newest row ${log.ui_user} / ${log.kind} / ${log.outcome}`);
  await shot('7-alerts-after-note');
  // what stays off on the Alerts page says why in words: Send test, Mute similar
  const offs = await ev(`(() => { const off = ${offWordsJS}; const pick = (re) => { const b = [...document.querySelectorAll('main button')].find(x => re.test(x.textContent.trim())); return b ? { off: b.getAttribute('aria-disabled') === 'true', words: off(b) } : null; };
    return { test: pick(/^Send test$/), similar: pick(/^Mute similar$/) }; })()`);
  judge('R9a', (!offs.test || (offs.test.off && /runs no sender/.test(offs.test.words))) && !!offs.similar && offs.similar.off && /reach past the demo's instances/.test(offs.similar.words),
    `on the Alerts page: Send test ${JSON.stringify(offs.test)}, Mute similar ${JSON.stringify(offs.similar)}`);
}

ws.close();
console.log(fails ? `demodoor-check: ${fails} row(s) FAILED` : 'demodoor-check: every row ok');
process.exit(fails ? 1 : 0);
