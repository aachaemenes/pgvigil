// The Availability page's drawing of a distributed availability group, read in a headless Chromium
// (scripts/proof-mssql-dag.sh): the group drawn once, over its two member groups and their replicas.
//   node scripts/dag/page-check.mjs <cdp port> <base url> <cases.json>
// cases.json is a list of
//   { label, instance, dag, tree, global, forwarder, forwarderStale, memberOf, link: { replica, instance } | null,
//     grid: "<cell text>" | null, stale: [<member group whose replicas the page must mark as a stale read>, ...] }
// tree is what the page must draw, as "<group>: <member>[<ROLE>]: <replica>=<role>[*], ...; <member>[...]: ..." with * on
// the replica the page marks as this server. It is read twice: from the words on the page, and from the nodes' own
// attributes; both must be the expected tree.
// forwarderStale: the forwarder's line must go on with ', as last read <time>' (its member group's read is a stale one).
// dbCells: [{ group, replica, database, state, cls }] - rows of the Databases grid: the state cell's words and its status
//   class ('' none, 'warn', 'crit'); replica is matched as the cell begins (a primary's cell says '<name> (primary)').
// Prints one 'ok <case>: ...' line per check, or 'FAIL ...' and exits 1.
const [port, base, casesFile] = process.argv.slice(2);
const fs = await import('node:fs');
const cases = JSON.parse(fs.readFileSync(casesFile, 'utf8'));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const tabs = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const ws = new WebSocket(tabs.find(t => t.type === 'page').webSocketDebuggerUrl);
await new Promise(r => ws.addEventListener('open', r));
let id = 0; const wait = new Map();
let thrown = [];   // what the page's own script threw or logged as an error, per case
ws.addEventListener('message', m => {
  const d = JSON.parse(m.data);
  if (d.method === 'Runtime.exceptionThrown') thrown.push(d.params.exceptionDetails?.exception?.description ?? d.params.exceptionDetails?.text ?? 'exception');
  if (d.method === 'Runtime.consoleAPICalled' && d.params.type === 'error') thrown.push('console.error: ' + d.params.args.map(a => a.value ?? a.description ?? '').join(' '));
  if (wait.has(d.id)) { wait.get(d.id)(d); wait.delete(d.id); }
});
const cmd = (method, params = {}) => new Promise(r => { const i = ++id; wait.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const ev = async e => {
  const d = await cmd('Runtime.evaluate', { expression: e, returnByValue: true, awaitPromise: true });
  if (d.result?.exceptionDetails) throw new Error(JSON.stringify(d.result.exceptionDetails).slice(0, 400));
  return d.result?.result?.value;
};
const until = async (expr, ms = 20000) => { const t = Date.now(); while (Date.now() - t < ms) { const v = await ev(expr); if (v) return v; await sleep(200); } return null; };
let failed = 0;
const check = (label, ok, what) => { if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${label}: ${what}`); };
await cmd('Page.enable'); await cmd('Runtime.enable');
await cmd('Emulation.setDeviceMetricsOverride', { width: 1500, height: 1200, deviceScaleFactor: 1, mobile: false });

// what the page draws, read from the DOM alone
const READ = `(() => {
  const main = document.querySelector('main');
  const text = e => (e?.textContent ?? '').trim();
  const propsAfter = h => { let e = h?.nextElementSibling; while (e && !e.querySelector?.('table.props') && !e.matches?.('table.props')) { if (/^H[1-6]$/.test(e.tagName)) return {}; e = e.nextElementSibling; }
    return Object.fromEntries([...(e?.querySelectorAll('table.props tr') ?? [])].map(tr => [text(tr.querySelector('th')), text(tr.querySelector('td'))])); };
  const uls = [...main.querySelectorAll('ul[data-dag]')];
  const own = (li, sel) => [...li.querySelectorAll(sel)];
  // a node's own words: its text without the lists and notes nested in it
  const words = li => { const c = li.cloneNode(true); for (const n of c.querySelectorAll('ul, p')) n.remove(); return text(c); };
  // the tree from the nodes' attributes ...
  const attrTree = uls.map(u => u.dataset.dag + ': ' + own(u, 'li[data-member]').map(m => m.dataset.member + '[' + m.dataset.memberRole + ']: '
    + own(m, 'li[data-replica]').map(r => r.dataset.replica + '=' + r.dataset.role + (words(r).includes('(this server)') ? '*' : '')).join(', ')).join('; ')).join(' | ');
  // ... and from the words a reader sees: '<group> availability group, <role> of <distributed group>', '<server> <role>[ (this server)]'
  const textTree = uls.map(u => text(u.querySelector(':scope > li > strong')) + ': ' + own(u, 'li[data-member]').map(m => {
    const w = /^(\\S+) availability group, (primary|secondary) of (\\S+?)(,| |$)/.exec(words(m));
    return (w ? w[1] + '[' + w[2].toUpperCase() + ']' : '?[' + words(m) + ']') + ': ' + own(m, 'li[data-replica]').map(r => {
      const x = /^(\\S+) (global primary|forwarder|secondary)( \\(this server\\))?(,|$)/.exec(words(r));
      return x ? x[1] + '=' + x[2] + (x[3] ? '*' : '') : '?' + words(r);
    }).join(', ');
  }).join('; ')).join(' | ');
  const h4 = t => [...main.querySelectorAll('h4')].filter(h => text(h) === t);
  const dagHead = uls.length ? h4(uls[0].dataset.dag + ' (distributed availability group)') : [];
  const roles = uls.flatMap(u => own(u, 'li[data-replica]')).map(r => r.dataset.role);
  return {
    hash: location.hash, attrTree, textTree, trees: uls.length, heads: dagHead.length, dagProps: propsAfter(dagHead[0]),
    globals: roles.filter(r => r === 'global primary').length, forwarders: roles.filter(r => r === 'forwarder').length,
    errors: [...main.querySelectorAll('p.error')].map(text),
    // a read the page marks as error, partial or skipped: a line with a badge in front of the collection's name
    readNotes: [...main.querySelectorAll('p.meta')].filter(p => p.firstElementChild?.matches('.badge')).map(text),
    memberProps: Object.fromEntries([...main.querySelectorAll('h4')].map(h => [text(h), propsAfter(h)])),
    before: Object.fromEntries([...main.querySelectorAll('h4')].map(h => [text(h), !!uls[0] && !!(uls[0].compareDocumentPosition(h) & Node.DOCUMENT_POSITION_FOLLOWING)])),
    links: Object.fromEntries(uls.flatMap(u => own(u, 'li[data-replica]')).map(r => [r.dataset.replica, r.querySelector('a')?.getAttribute('href') ?? ''])),
    cells: [...main.querySelectorAll('table.grid td')].map(text),
    stale: uls.flatMap(u => own(u, 'li[data-member][data-stale="true"]')).filter(m => words(m).includes('stale: its replicas as last read')).map(m => m.dataset.member),
    // the Databases grid: the one grid with the columns database, replica, state and redo queue
    dbRows: (() => {
      const heads = t => [...t.querySelectorAll('thead tr:first-child th')].map(text);
      const t = [...main.querySelectorAll('table.grid')].find(t => ['database', 'replica', 'state', 'redo queue'].every(k => heads(t).includes(k)));
      if (!t) return null;
      const h = heads(t);
      return [...t.querySelectorAll('tbody tr')].map(tr => { const cell = k => tr.children[h.indexOf(k)];
        return { group: text(cell('group')), replica: text(cell('replica')), database: text(cell('database')), state: text(cell('state')),
          cls: ['warn', 'crit', 'ok'].filter(c => cell('state')?.classList.contains(c)).join(' ') }; });
    })(),
  };
})()`;

for (const c of cases) {
  // a document of its own per case: from a blank page, so the tree read is never the case before's
  await cmd('Page.navigate', { url: 'about:blank' });
  await until(`location.href === 'about:blank'`, 5000);
  thrown = [];
  await cmd('Page.navigate', { url: `${base}/#/availability?i=${c.instance}` });
  const mine = `location.hash.startsWith('#/availability?i=${c.instance}') && !!document.querySelector('main')`;
  const drawn = await until(`${mine} && (!!document.querySelector('main ul[data-dag]') || !!document.querySelector('main p.error'))`);
  if (!drawn) { check(c.label, false, `the page drew no distributed group in 20 s${thrown.length ? ' (' + thrown.join(' / ') + ')' : ''}`); continue; }
  await sleep(500);
  const p = await ev(READ);
  check(c.label, new URLSearchParams(p.hash.split('?')[1] ?? '').get('i') === String(c.instance), `the page read is instance ${c.instance}'s (${p.hash})`);
  check(c.label, p.errors.length === 0 && p.readNotes.length === 0 && thrown.length === 0,
    `no error box, no read marked error, partial or skipped, no exception${[...p.errors, ...p.readNotes, ...thrown].length ? ': ' + [...p.errors, ...p.readNotes, ...thrown].join(' / ') : ''}`);
  check(c.label, p.textTree === c.tree, `the tree as its words draw it: ${p.textTree}${p.textTree === c.tree ? '' : '   WANT ' + c.tree}`);
  check(c.label, p.attrTree === c.tree, `the tree as its nodes are marked: ${p.attrTree === c.tree ? 'the same' : p.attrTree + '   WANT ' + c.tree}`);
  check(c.label, p.trees === 1 && p.heads === 1, `the distributed group is drawn once (${p.trees} tree(s), ${p.heads} heading(s))`);
  check(c.label, p.globals === 1 && p.forwarders === 1, `one global primary and one forwarder are named (${p.globals}, ${p.forwarders})`);
  const fw = p.dagProps['forwarder'] ?? '';
  check(c.label, p.dagProps['global primary'] === c.global && (c.forwarderStale ? fw.startsWith(c.forwarder + ', as last read ') && fw.length > c.forwarder.length + 16 : fw === c.forwarder),
    `global primary '${p.dagProps['global primary']}', forwarder '${fw}'`);
  if (c.memberOf) {
    check(c.label, p.before[c.memberOf] === true, `the distributed group is drawn above the member group ${c.memberOf}`);
    check(c.label, p.memberProps[c.memberOf]?.['member of'] === `the distributed group ${c.dag}`, `${c.memberOf} says what it is a member of: '${p.memberProps[c.memberOf]?.['member of']}'`);
  }
  if (c.link) {
    const h = p.links[c.link.replica] ?? '';
    check(c.label, h.startsWith('#/availability') && new URLSearchParams(h.split('?')[1] ?? '').get('i') === String(c.link.instance),
      `${c.link.replica} links to its own instance's Availability tab (${h || 'no link'})`);
  }
  if (c.grid) check(c.label, p.cells.includes(c.grid), `the Replicas grid names a member group as one: '${c.grid}'`);
  for (const w of c.dbCells ?? []) {
    const row = (p.dbRows ?? []).find(r => r.group === w.group && r.database === w.database && r.replica.startsWith(w.replica));
    check(c.label, !!row && row.state === w.state && row.cls === w.cls,
      `the Databases grid's state of ${w.group} / ${w.replica} / ${w.database}: ${row ? `'${row.state}', class '${row.cls}'` : 'no such row'} (want '${w.state}', class '${w.cls}')`);
  }
  check(c.label, JSON.stringify(p.stale) === JSON.stringify(c.stale ?? []), `member groups marked as a stale read: [${p.stale.join(', ')}]${JSON.stringify(p.stale) === JSON.stringify(c.stale ?? []) ? '' : '   WANT [' + (c.stale ?? []).join(', ') + ']'}`);
}
ws.close();
process.exit(failed ? 1 : 0);
