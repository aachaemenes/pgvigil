// The verdict card (scripts/proof-verdict.sh runs it over the served demo): on every instance's Summary, the card's
// state follows the header (its badge word and its status line), its reasons are the header's band items in the same
// order, the sentence is plain words, a PostgreSQL card holds no SQL Server word, 'Not judged' lists only the row's
// engine's groups; the fixtures (proof-verdict.sh) give a never-read, a stale and an offline instance.
// usage: node scripts/verdict-check.mjs <cdp port> <base url ending in />
const [port, U] = process.argv.slice(2);
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
ws.addEventListener('message', m => { const d = JSON.parse(m.data); if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); } });
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async (expr, awaitPromise = false) => {
  const d = await cmd('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 300));
  return d.result?.result?.value;
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1000, deviceScaleFactor: 1, mobile: false });

const table = async p => { const t = await (await fetch(U + 'api/' + p)).json(); return t.rows.map(r => Object.fromEntries(t.columns.map((c, i) => [c, r[i]]))); };
const insts = (await table('instances')).filter(r => r.is_active !== false);

// the groups of one engine (web/src/fleet.ts groups: mssqlOnly, and the PostgreSQL groups with no SQL Server read)
const mssqlOnly = new Set(['alerts', 'diff', 'agent', 'mirroring', 'logspace', 'filespace', 'pctmax', 'elasticpool', 'qs', 'dbmail', 'identity', 'servicebroker']);
const pgOnly = new Set(['custom', 'pgss', 'dms', 'tables', 'vacuum', 'host', 'io', 'roles', 'indexes', 'version']);
// words a PostgreSQL card must not hold (SQL Server's own names; the wording walk's rule)
const msWords = /SQL Server|SQL Agent|\bAgent\b|CHECKDB|Memory Dump|Backup LOG|Backup DIFF|Log Space|Database Mail|DB Mail|Query Store|Service Broker|Mirroring|Elastic Pool|Identity Columns|TempDB|msdb/;
// a plain sentence: no DMV, setting or SQL name (an underscore name, a dotted system name)
const technical = /\b\w+_\w+\b|\bsys\.|\bdm_|\bpg_/i;

let fails = 0;
const say = (ok, row, what) => { if (!ok) fails++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${row}: ${what}`); };

const read = async iid => {
  await cmd('Page.navigate', { url: 'about:blank' });
  await cmd('Page.navigate', { url: `${U}#/summary?i=${iid}&w=1h` });
  for (let i = 0; i < 100; i++) {
    const ok = await ev(`!!document.querySelector('main > .inst-header') && !!document.querySelector('main .verdict-card')`);
    if (ok) break;
    await sleep(150);
  }
  await sleep(200);
  return ev(`(() => {
    const h = document.querySelector('main > .inst-header'), c = document.querySelector('main .verdict-card');
    const w = h?.querySelector('.band-word');
    const groups = s => [...(c?.querySelectorAll(s) ?? [])].map(e => e.dataset.group);
    return { header: !!h, card: !!c, word: w?.textContent.trim() ?? '', status: h?.querySelector('.status-line')?.textContent.trim() ?? '',
      hgroups: (w?.dataset.groups ?? '').split(' ').filter(Boolean),
      state: c?.dataset.state ?? '', sentence: c?.querySelector('.verdict-sentence')?.textContent.trim() ?? '',
      reasons: [...(c?.querySelectorAll('.verdict-reasons li') ?? [])].map(li => ({ g: li.dataset.group, phrase: li.dataset.phrase ?? '', text: li.textContent.trim(), href: li.querySelector('a')?.getAttribute('href') ?? '' })),
      acked: groups('.verdict-acked [data-group]'), notJudged: groups('.verdict-notjudged [data-group]'),
      text: c?.textContent ?? '' };
  })()`);
};

// the state the header implies: Awaiting -> unread; Offline / Critical -> problem; Warning, or OK with a late
// collection (the status word 'Warning') -> warning; OK -> ok
const implied = x => x.status.startsWith('Awaiting') && x.word === 'OK' ? 'unread'
  : x.word === 'Offline' || x.word === 'Critical' ? 'problem'
  : x.word === 'Warning' || (x.word === 'OK' && x.status.startsWith('Warning')) ? 'warning' : x.word === 'OK' ? 'ok' : '?';

const seen = { ok: 0, warning: 0, problem: 0, unread: 0 };
const byName = {};
for (const r of insts) {
  const name = String(r.name), pg = r.engine !== 'sqlserver';
  const x = await read(Number(r.instance_id));
  byName[name] = x;
  if (!x.card) { say(false, `card ${name}`, `no verdict card on its Summary (header ${x.header ? 'shown' : 'missing'})`); continue; }
  if (!name.startsWith('fx-')) seen[x.state] = (seen[x.state] ?? 0) + 1;
  const want = implied(x);
  say(x.state === want, `state ${name}`, `card '${x.state}', the header '${x.word}' / '${x.status.slice(0, 40)}' -> '${want}'; '${x.sentence.slice(0, 120)}'`);
  const cg = x.reasons.map(q => q.g).join(' '), hg = x.hgroups.join(' ');
  say(cg === hg, `reasons ${name}`, `card [${cg}] header [${hg}]`);
  say(!technical.test(x.sentence), `plain ${name}`, technical.test(x.sentence) ? `a technical name in '${x.sentence}'` : 'no DMV, setting or SQL name in the sentence');
  if (pg) say(!msWords.test(x.text), `engine words ${name}`, msWords.test(x.text) ? `a SQL Server word: '${x.text.match(msWords)[0]}'` : 'no SQL Server word on a PostgreSQL card');
  const wrong = x.notJudged.filter(g => (pg ? mssqlOnly : pgOnly).has(g) || cg.split(' ').includes(g));
  say(wrong.length === 0, `not judged ${name}`, `[${x.notJudged.join(' ')}]${wrong.length ? ` - the other engine's or a judged group: ${wrong.join(' ')}` : ''}`);
  const dead = x.reasons.filter(q => !q.href.startsWith('#/'));
  say(dead.length === 0, `links ${name}`, `${x.reasons.length} reason(s), ${dead.length} without a page link`);
}
say(seen.ok > 0 && seen.warning > 0 && seen.problem > 0, 'states seen', `among the demo's instances: ok ${seen.ok}, warning ${seen.warning}, problem ${seen.problem}, unread ${seen.unread} (each of the first three at least once, or the rows prove less)`);

// demo-onprem-sql01 (Critical in DBA Dash's shot): 'has a problem' and its first critical reason in the sentence
const s1 = byName['demo-onprem-sql01'];
if (!s1?.card) say(false, 'sql01', 'no card for demo-onprem-sql01');
else {
  const first = s1.reasons[0]?.phrase ?? '';
  say(s1.state === 'problem' && first !== '' && s1.sentence.startsWith(`demo-onprem-sql01 has a problem: ${first}`), 'sql01', `'${s1.sentence}' (its first reason '${first}')`);
}
// the fixtures (proof-verdict.sh): never read, one collection late, nothing read for 40 minutes
const fu = byName['fx-unread'], fs = byName['fx-stale'], fo = byName['fx-offline'];
say(!!fu?.card && fu.state === 'unread' && fu.sentence.startsWith('pgvigil has not read fx-unread yet'), 'never read', `'${fu?.state}' '${fu?.sentence ?? 'no card'}'`);
say(!!fs?.card && fs.state === 'warning' && fs.sentence.startsWith('fx-stale needs a look: ') && /\blate\b/.test(fs.sentence) && /\b1\b/.test(fs.sentence), 'stale', `'${fs?.state}' '${fs?.sentence ?? 'no card'}'`);
const om = /^pgvigil has not read fx-offline for (\d+) minutes/.exec(fo?.sentence ?? '');
say(!!fo?.card && fo.state === 'problem' && !!om && Number(om[1]) >= 35 && Number(om[1]) <= 60, 'offline', `'${fo?.state}' '${fo?.sentence ?? 'no card'}'`);

console.log(`verdict cards: ${insts.length} instance(s) read; ${fails} FAIL`);
ws.close();
process.exit(fails ? 1 : 0);
