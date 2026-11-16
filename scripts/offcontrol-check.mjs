// The 406 offControl row, clicked (scripts/proof-406-offcontrol.sh part O): an off plan read or Evict is drawn disabled
// with its reason in words beside it. O1 the Plan cache page's Cached plans grid; O2 a running request's plan sources.
// Usage (a headless Chromium on the CDP port, the demo served at the base url, the stage made):
//   node scripts/offcontrol-check.mjs <cdp port> <base url/> <sql01 id> <query hash> <plan hash>
// Prints one line per case; exit 1 on a FAIL.
const [port, U, ms, QH, PH] = process.argv.slice(2);
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(list.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (expr, ms = 15000) => {
  const t = Date.now();
  while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(200); }
  return null;
};
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1600, height: 1000, deviceScaleFactor: 1, mobile: false });
const go = async (hash) => {
  await cmd('Page.navigate', { url: 'about:blank' }); await cmd('Page.navigate', { url: U + hash }); await sleep(300);
  return until(`(() => { const m = document.querySelector('main'); const e = m?.querySelector('p.empty');
    return !!m?.querySelector('h2') && !(e && /^Loading/.test(e.textContent)); })()`);
};
let fails = 0;
const fail = (w) => { fails++; console.log(`FAIL ${w}`); };
// offState(scope, matcher): each button under the scope (a CSS selector) whose aria-label or text the matcher's source
// matches: its label, aria-disabled, and the words of the note its aria-describedby names (that note on the page)
const offState = (scope, re) => ev(`(() => { const s = document.querySelector(${JSON.stringify(scope)}); if (!s) return null;
  const re = new RegExp(${JSON.stringify(re.source)});
  return [...s.querySelectorAll('button')].filter(b => re.test(b.getAttribute('aria-label') || '') || re.test(b.textContent.trim())).map(b => {
    const n = b.getAttribute('aria-describedby') ? document.getElementById(b.getAttribute('aria-describedby')) : null;
    return { text: b.textContent.trim(), label: b.getAttribute('aria-label') || '', off: b.getAttribute('aria-disabled'),
      note: n && n.isConnected && !n.hidden ? n.textContent.trim() : null };
  }); })()`);
const isOff = (b, words) => b.off === 'true' && !!b.note && (typeof words === 'string' ? b.note.startsWith(words) : words.test(b.note));
// the server's own reason for the staged entry (the demo serve: no read login, no actions door): the stage must reach it
const ent = await (await fetch(`${U}api/mssql/plancache/entries?instance=${ms}&db=5&key=${encodeURIComponent(QH)}`)).json();
const FO = String(ent.fetch_off ?? '');
if (!FO) fail(`the stage does not reach the off path: the entries reply says the plan read is on (${JSON.stringify(ent).slice(0, 200)})`);
else console.log(`     the server's reason: ${FO}`);
// what the scope holds instead, for a FAIL line
const holds = scope => ev(`(document.querySelector(${JSON.stringify(scope)})?.innerText ?? '(no such element)').replace(/\\s+/g, ' ').slice(0, 400)`);

// O1: the Plan cache page, the staged statement's Cached plans
if (!await go(`#/mssqlplancache?i=${ms}`)) fail(`O1 #/mssqlplancache?i=${ms}: the page never drew`);
else {
  const has = await until(`!!document.querySelector('main button[aria-label="Cached plans of ${QH}"]')`);
  if (!has) fail(`O1: no 'Cached plans' button for ${QH} on the Plan cache page (${await holds('main')})`);
  else {
    await ev(`document.querySelector('main button[aria-label="Cached plans of ${QH}"]').click()`);
    const box = await until(`(() => { const h = [...document.querySelectorAll('main h4')].find(x => /^Cached plans of /.test(x.textContent));
      if (!h) return null; h.parentElement.setAttribute('data-offc', 'o1'); return !!h.parentElement.querySelector('table tbody tr'); })()`);
    if (!box) fail(`O1: the Cached plans box never listed its entry (${await holds('main [data-offc="o1"]')})`);
    else {
      const reads = await offState('main [data-offc="o1"]', /^(Download \.sqlplan|Open|Download batch|Open batch)(:|$)/);
      const evict = await offState('main [data-offc="o1"]', /^(Evict|Evict the plan )/);
      const why = [];
      for (const t of ['Download .sqlplan', 'Open', 'Download batch', 'Open batch']) {
        const b = reads.find(x => x.text === t);
        if (!b) why.push(`no '${t}' button`);
        else if (!isOff(b, FO)) why.push(`'${t}' ${JSON.stringify(b)}`);
      }
      const e = evict.find(x => x.text === 'Evict');
      if (!e) why.push(`no 'Evict' button`);
      else if (!isOff(e, /^Evict is off for this instance: /)) why.push(`'Evict' ${JSON.stringify(e)}`);
      // an off button does nothing when clicked: no dialog opens
      if (!why.length) {
        await ev(`[...document.querySelectorAll('main [data-offc="o1"] button')].filter(b => /^(Open|Evict)$/.test(b.textContent.trim())).forEach(b => b.click())`);
        await sleep(600);
        const dlg = await ev(`[...document.querySelectorAll('dialog[open]')].map(d => d.querySelector('h3,h2')?.textContent ?? 'a dialog').join(' | ')`);
        if (dlg) why.push(`a click on an off button opened: ${dlg}`);
      }
      if (why.length) fail(`O1: ${why.join('; ')} (the box: ${await holds('main [data-offc="o1"]')})`);
      else console.log(`ok   O1: the Cached plans row's four plan reads off ('${reads[0].note.slice(0, 120)}'), Evict off ('${e.note.slice(0, 120)}'); a click opened nothing`);
    }
  }
}

// O2: the request's plan sources on Running queries
if (!await go(`#/mssql_running?i=${ms}`)) fail(`O2 #/mssql_running?i=${ms}: the page never drew`);
else {
  const sel = `main button[aria-label="Plans of query hash ${QH}, plan hash ${PH}"]`;
  if (!await until(`!!document.querySelector(${JSON.stringify(sel)})`)) fail(`O2: no Plan button for ${QH} / ${PH} in the request grid`);
  else {
    await ev(`document.querySelector(${JSON.stringify(sel)}).click()`);
    const listed = await until(`(() => { const t = document.querySelector('main .running-plans')?.innerText ?? ''; return /Reading/.test(t) || !t ? null : t; })()`);
    if (!listed) fail('O2: the plan sources never drew in 15 s');
    else {
      const pc = await offState('main .running-plans', /: the plan cache plan$/);
      const run = await offState('main .running-plans', /: the running plan$/);
      const why = [];
      for (const t of ['Download .sqlplan', 'Open']) {
        const b = pc.find(x => x.text === t);
        if (!b) why.push(`no '${t}' button on the 'plan cache' row`);
        else if (!isOff(b, `Plan cache: ${FO}`)) why.push(`'${t}: the plan cache plan' ${JSON.stringify(b)}`);
      }
      const ro = run.find(x => x.text === 'Open');
      if (ro && ro.off === 'true') why.push(`the running row's Open is off: ${JSON.stringify(ro)}`);
      if (why.length) fail(`O2: ${why.join('; ')} (the sources: ${String(listed).replace(/\s+/g, ' ').slice(0, 400)})`);
      else console.log(`ok   O2: the 'plan cache' row's Download .sqlplan and Open off ('${pc[0].note.slice(0, 120)}'); ${ro ? "the 'running' row's Open on" : "no 'running' row for these hashes"}`);
    }
  }
}
ws.close();
console.log(fails ? `offcontrol-check: ${fails} FAIL` : 'offcontrol-check: 0 FAIL');
process.exit(fails ? 1 : 0);
