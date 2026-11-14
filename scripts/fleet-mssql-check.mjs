// The fleet's SQL Server backups in the browser (proof-fleet-mssql.sh, FLEET MSSQL DONE-1): the SQL Server sections of
// #/backups below PostgreSQL's, the instances tile over both engines, Problems and All, Configure off with its reason,
// the instance and database links landing on the tab with the row first, and the views of one engine or one instance.
//   node scripts/fleet-mssql-check.mjs <cdp port> <base url/>
//   FM_S1 / FM_S3 the demo's sql01 / sql03 instance_id; FM_NULDB sql01's database with a backup to NUL; FM_PROBLEMS /
//   FM_ALL the hand counts of the databases under Problems and of all; FM_INSTS '<active instances>|<SQL Server ones>';
//   FM_SJ / FM_PJ the seeded jobs' names; FM_JALL / FM_JPROB every job / the problem rows
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
    check('B2 all', !!b2a && b2a.said === `${all} of ${all} databases` && b2a.dbs.length === all, b2a ? `'${b2a.said}', ${b2a.dbs.length} rows (want ${all})` : 'the section went away');
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
  const salesPg = sales ? sales.h2s.filter(h => h === 'Base backups (pgBackRest, barman)') : [];
  check('B4 views', erp?.empty === 'No SQL Server instance in this view.' && sales?.pgEmpty.includes('No PostgreSQL instance in this view.') && salesPg.length === 0 && sales?.inst.length === 2
    && ledger?.filter === 'all' && ledger?.inst.length === 1 && ledger.inst[0][ledger.inst[0].length - 1] === 'mssql_backups has not run on this server yet' && ledger.dbs.length === 0,
    `erp '${erp?.empty ?? 'no section'}'; sales ${JSON.stringify(sales?.pgEmpty)}, PostgreSQL's Base backups ${salesPg.length ? 'DRAWN' : 'not drawn'}, ${sales?.inst.length} instance rows; ledger filter ${ledger?.filter}, `
      + `${ledger?.inst.length} instance row(s) ${JSON.stringify(ledger?.inst.map(r => r[r.length - 1]))}, ${ledger?.dbs.length} databases (sql03 = ${s3})`);

  // J2-J4. the fleet Jobs page
  const { FM_SJ: sj, FM_PJ: pj } = process.env;
  const jall = Number(process.env.FM_JALL), jprob = Number(process.env.FM_JPROB);
  const jstate = `(() => { const s = document.querySelector('#job-status-fleet'); if (!s) return null;
    const h3s = [...document.querySelectorAll('main h3')].map(h => h.textContent);
    const tb = document.querySelector('#job-status-grid table.grid');
    const heads = tb ? [...tb.querySelectorAll(':scope > thead > tr:first-child > th')].map(th => th.textContent.trim()) : [];
    const rows = tb ? [...tb.querySelectorAll(':scope > tbody > tr')].filter(tr => !tr.classList.contains('trend-row')) : [];
    const col = n => heads.findIndex(h => h.startsWith(n));
    return { h3s, filter: s.querySelector('#job-status-filter')?.value, said: s.querySelector('#job-status-count')?.textContent, ok7col: col('succeeded 7 days'),
             jobs: rows.map(tr => tr.cells[col('job')]?.textContent ?? ''), ok7: rows.map(tr => tr.cells[col('succeeded 7 days')]?.textContent ?? '') }; })()`;
  await go('#/jobs?w=1h');
  const j2 = await ev(jstate);
  const iS = j2 ? j2.h3s.indexOf('Job status') : -1, iP = j2 ? j2.h3s.indexOf('PostgreSQL schedule checks') : -1;
  check('J2 page', !!j2 && iS >= 0 && iP > iS && j2.filter === 'problems' && j2.said === `${jprob} of ${jall} jobs` && j2.jobs.length === jprob
    && j2.jobs.includes(sj) && j2.jobs.includes(pj),
    j2 ? `h3 ${JSON.stringify(j2.h3s)}; filter ${j2.filter}, '${j2.said}' (want '${jprob} of ${jall} jobs'), ${j2.jobs.length} rows, the seeded two there ${j2.jobs.includes(sj)} / ${j2.jobs.includes(pj)}` : 'no #job-status-fleet section on #/jobs');
  if (j2) {
    await sleep(4000);
    const j3 = await ev(jstate);
    const bad = j3 ? j3.ok7.filter(t => !/^\d[\d,]*$/.test(t)) : [];
    const seeded = j3 ? [j3.ok7[j3.jobs.indexOf(sj)], j3.ok7[j3.jobs.indexOf(pj)]] : [];
    check('J3 stats', !!j3 && j3.ok7col >= 0 && j3.ok7.length > 0 && bad.length === 0 && seeded[0] === '1' && seeded[1] === '1',
      j3 ? `the column at ${j3.ok7col}; ${j3.ok7.length} 'succeeded 7 days' cells, ${bad.length} not a number ${JSON.stringify(bad.slice(0, 2))}; the seeded two ${JSON.stringify(seeded)} (want ["1","1"]: one success each in 7 days)` : 'the section went away');
    await ev(`(() => { const p = document.querySelector('#job-status-filter'); p.value = 'all'; p.dispatchEvent(new Event('change')); return 1; })()`);
    await sleep(500);
    const ja = await ev(jstate);
    const clicked = await ev(`(() => { const b = [...document.querySelectorAll('#job-status-grid button')].find(b => b.textContent === ${JSON.stringify(sj)}); b?.click(); return !!b; })()`);
    await sleep(3000);
    const j4 = await ev(`(() => { const h = document.querySelector('#job-status-history'); return { head: h?.querySelector('h3')?.textContent ?? '',
      runs: [...(h?.querySelectorAll('table.grid > tbody > tr') ?? [])].length, open: h?.querySelector('a')?.getAttribute('href') ?? '' }; })()`);
    // the page's rows in the order the API gives at this moment (DBA Dash's; J1 checks the API's order by its rule)
    const live = await (await fetch(base + 'api/jobsreport?part=status')).json();
    const jorder = live.status.rows.map(r => r[live.status.columns.indexOf('job_name')]);
    const inOrder = !!ja && JSON.stringify(ja.jobs) === JSON.stringify(jorder);
    check('J2 all', !!ja && ja.said === `${jall} of ${jall} jobs` && ja.jobs.length === jall && inOrder,
      ja ? `'${ja.said}', ${ja.jobs.length} rows, in the API's order ${inOrder}${inOrder ? '' : ` (page ${JSON.stringify(ja.jobs.slice(0, 4))} vs API ${JSON.stringify(jorder.slice(0, 4))})`}` : 'the section went away');
    // SF4: 'Open the job on its instance' = the instance's Agent jobs tab with the job picked (job=<name>), its history open
    const oq = new URLSearchParams(j4.open.split('?')[1] ?? '');
    let tabHead = '';
    if (j4.open.startsWith('#/mssqljobs?')) {
      await go(j4.open);
      tabHead = await ev(`[...document.querySelectorAll('main .jobdetail h3')].map(h => h.textContent).find(t => t.startsWith(${JSON.stringify(sj + ': history')})) ?? ''`);
    }
    check('J4 history', clicked && j4.head === `demo-onprem-sql01 | ${sj}` && j4.runs === 2 && oq.get('i') === s1 && oq.get('job') === sj && tabHead !== '',
      clicked ? `'${j4.head}', ${j4.runs} run row(s); its link '${j4.open}' -> the tab's picked history '${tabHead}'` : `no button '${sj}' in the grid`);
  } else { check('J3 stats', false, 'no section'); check('J2 all', false, 'no section'); check('J4 history', false, 'no section'); }

  // S1. the fleet Summary's Agent Jobs link of sql01 lands on a page that names the seeded job
  await go('#/summary?w=1h');
  const sl = await ev(`[...document.querySelectorAll('main a')].map(a => a.getAttribute('href') ?? '').find(h => h.startsWith('#/mssqljobs?') && new URLSearchParams(h.split('?')[1]).get('i') === ${JSON.stringify(s1)}) ?? ''`);
  let landed = '';
  if (sl) { await go(sl); landed = await ev(`document.querySelector('main')?.textContent ?? ''`); }
  check('S1 link', !!sl && landed.includes(sj), sl ? `'${sl}' -> the page names '${sj}': ${landed.includes(sj)}` : `no #/mssqljobs link of sql01 (${s1}) on the Summary`);
} catch (e) {
  console.log(`FAIL check stopped: ${e.message}`);
  process.exit(2);
}
console.log(failed ? `FAIL ${failed} case(s)` : 'fleet-mssql-check: ok');
process.exit(failed ? 1 : 0);
