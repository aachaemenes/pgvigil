// The fleet's SQL Server backups in the browser (proof-fleet-mssql.sh, FLEET MSSQL DONE-1): the SQL Server sections of
// #/backups below PostgreSQL's, the instances tile over both engines, Problems and All, Configure off with its reason,
// the instance and database links landing on the tab with the row first, and the views of one engine or one instance.
//   node scripts/fleet-mssql-check.mjs <cdp port> <base url/>
//   FM_S1 / FM_S3 the demo's sql01 / sql03 instance_id; FM_NULDB sql01's database with a backup to NUL; FM_PROBLEMS /
//   FM_ALL the hand counts of the databases under Problems and of all; FM_INSTS '<active instances>|<SQL Server ones>'
// Prints one 'ok <case>: ...' line per case, or 'FAIL <case>: ...' and exits 1.
const [port, base] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl); await new Promise(r => ws.onopen = r);
let id = 0; const pend = new Map(); ws.onmessage = m => { const d = JSON.parse(m.data); if (d.id && pend.has(d.id)) { pend.get(d.id)(d); pend.delete(d.id); } };
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => {
  const r = await send('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true, userGesture: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
};
let failed = 0;
const check = (name, okay, detail) => { console.log(`${okay ? 'ok  ' : 'FAIL'} ${name}: ${detail}`); if (!okay) failed++; };
await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
const go = async h => {
  await send('Page.navigate', { url: 'about:blank' }); await sleep(200);   // a full load each time: a same-hash navigation draws nothing
  await send('Page.navigate', { url: base + h });
  for (let i = 0; i < 80; i++) { await sleep(250); if (await ev(`!!document.querySelector('main section') && !document.querySelector('main > p.empty[role=status]')`)) break; }
  await sleep(2500);   // the page's sections are drawn one after the other
};
const { FM_S1: s1, FM_S3: s3, FM_NULDB: nul } = process.env;
const problems = Number(process.env.FM_PROBLEMS), all = Number(process.env.FM_ALL);
const [insts, sqls] = (process.env.FM_INSTS ?? '0|0').split('|').map(Number);
// a grid's body rows inside a box (a grid with no row draws .empty-grid and none)
const rowsIn = sel => `[...document.querySelectorAll('${sel} table.grid > tbody > tr')].filter(tr => !tr.classList.contains('trend-row'))`;
const sect = `document.querySelector('#mssql-backups-fleet')`;
const state = `(() => { const s = ${sect}; if (!s) return null;
  const h2s = [...document.querySelectorAll('main h2')].map(h => h.textContent);
  const tile = [...document.querySelectorAll('main .tile')].find(t => t.querySelector('.tile-l')?.textContent === 'instances');
  const cfg = [...s.querySelectorAll('button')].find(b => b.textContent === 'Configure');
  const inst = ${rowsIn('#mssql-backups-fleet-instances')}.map(tr => [...tr.cells].map(td => td.textContent));
  const dbs = ${rowsIn('#mssql-backups-fleet-databases')};
  return { h2s, tile: tile ? [tile.querySelector('.tile-v')?.textContent, tile.querySelector('.tile-sub')?.textContent] : null,
           cfg: cfg ? [cfg.getAttribute('aria-disabled'), document.getElementById(cfg.getAttribute('aria-describedby') ?? '')?.textContent ?? ''] : null,
           inst, filter: s.querySelector('#mssql-backups-fleet-filter')?.value, said: s.querySelector('#mssql-backups-fleet-count')?.textContent,
           dbs: dbs.map(tr => tr.cells[0].textContent + '|' + tr.cells[1].textContent), empty: s.querySelector(':scope > p.empty')?.textContent ?? '',
           pgEmpty: [...document.querySelectorAll('main p.empty')].map(p => p.textContent).filter(t => t.startsWith('No PostgreSQL')) }; })()`;

try {
  // B2. the root page
  await go('#/backups?w=1h');
  const b2 = await ev(state);
  const iBase = b2 ? b2.h2s.indexOf('Base backups (pgBackRest, barman)') : -1, iSql = b2 ? b2.h2s.indexOf('SQL Server backups') : -1;
  const unread = b2 ? b2.inst.filter(r => r[r.length - 1] === 'mssql_backups has not run on this server yet').length : 0;
  check('B2 page', !!b2 && iBase >= 0 && iSql > iBase && b2.tile?.[0] === String(insts) && b2.tile?.[1] === `${insts - sqls} PostgreSQL, ${sqls} SQL Server`
    && b2.inst.length === sqls && unread === 1 && b2.filter === 'problems' && b2.said === `${problems} of ${all} databases` && b2.dbs.length === problems
    && b2.dbs.some(d => d.endsWith('|' + nul)) && b2.cfg?.[0] === 'true' && b2.cfg[1].includes('pgvigil.yaml'),
    b2 ? `h2 ${JSON.stringify(b2.h2s)}; tile ${JSON.stringify(b2.tile)} (want ${insts}, '${insts - sqls} PostgreSQL, ${sqls} SQL Server'); ${b2.inst.length} instance rows, ${unread} unread; `
      + `filter ${b2.filter}, '${b2.said}' (want '${problems} of ${all} databases'), ${b2.dbs.length} rows, ${nul} among them ${b2.dbs.some(d => d.endsWith('|' + nul))}; Configure ${JSON.stringify(b2.cfg)}`
      : 'no #mssql-backups-fleet section on #/backups');

  // B2. All
  if (b2) {
    await ev(`(() => { const p = document.querySelector('#mssql-backups-fleet-filter'); p.value = 'all'; p.dispatchEvent(new Event('change')); return 1; })()`);
    await sleep(2500);
    const b2a = await ev(state);
    check('B2 all', b2a.said === `${all} of ${all} databases` && b2a.dbs.length === all, `'${b2a.said}', ${b2a.dbs.length} rows (want ${all})`);
  } else check('B2 all', false, 'no section');

  // B3. the links
  const links = await ev(`(() => {
    const inst = [...document.querySelectorAll('#mssql-backups-fleet-instances table.grid > tbody > tr')].map(tr => tr.cells[0].querySelector('a')?.getAttribute('href') ?? '');
    const db = [...document.querySelectorAll('#mssql-backups-fleet-databases table.grid > tbody > tr')].find(tr => tr.cells[1].textContent === ${JSON.stringify(nul)} && (tr.cells[0].querySelector('a')?.getAttribute('href') ?? '').includes('i=${s1}'));
    return { inst, db: db ? db.cells[1].querySelector('a')?.getAttribute('href') ?? '' : '' }; })()`);
  const instOk = links.inst.some(h => h.startsWith('#/mssqlbackups?') && new URLSearchParams(h.split('?')[1]).get('i') === s1);
  const dbq = new URLSearchParams((links.db.split('?')[1]) ?? '');
  let b3 = null;
  if (links.db) {
    await go(links.db);
    b3 = await ev(`(() => ({ said: document.querySelector('#mssql-backups-picked')?.textContent ?? '',
      first: (() => { const h = [...document.querySelectorAll('main h3')].find(x => x.textContent === 'Databases'); let n = h?.nextElementSibling;
        while (n && !n.querySelector('table.grid')) n = n.nextElementSibling;
        return n?.querySelector('table.grid > tbody > tr')?.cells[0].textContent ?? ''; })() }))()`);
  }
  check('B3 clicks', instOk && links.db.startsWith('#/mssqlbackups?') && dbq.get('i') === s1 && dbq.get('db') === nul
    && b3?.said === `Opened for the database ${nul}: its row is the first below.` && b3?.first === nul,
    `instance links ${JSON.stringify(links.inst)}; ${nul}'s link '${links.db}'; the tab: '${b3?.said ?? ''}', first row '${b3?.first ?? ''}'`);

  // B4. one engine, one instance
  await go('#/backups?tag=erp&w=1h');
  const erp = await ev(state);
  await go('#/backups?tag=sales&w=1h');
  const sales = await ev(state);
  await go('#/backups?tag=ledger&w=1h');
  const ledger = await ev(state);
  check('B4 views', erp?.empty === 'No SQL Server instance in this view.' && sales?.pgEmpty.includes('No PostgreSQL instance in this view.') && sales?.inst.length === 2
    && ledger?.filter === 'all' && ledger?.inst.length === 1 && ledger.inst[0][ledger.inst[0].length - 1] === 'mssql_backups has not run on this server yet' && ledger.dbs.length === 0,
    `erp '${erp?.empty ?? 'no section'}'; sales ${JSON.stringify(sales?.pgEmpty)} with ${sales?.inst.length} instance rows; ledger filter ${ledger?.filter}, `
      + `${ledger?.inst.length} instance row(s) ${JSON.stringify(ledger?.inst.map(r => r[r.length - 1]))}, ${ledger?.dbs.length} databases (sql03 = ${s3})`);
} catch (e) {
  console.log(`FAIL check stopped: ${e.message}`);
  process.exit(2);
}
console.log(failed ? `FAIL ${failed} case(s)` : 'fleet-mssql-check: ok');
process.exit(failed ? 1 : 0);
