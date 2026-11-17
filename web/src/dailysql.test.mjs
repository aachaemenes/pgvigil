// Unit tests of dailysql.ts (DAILY-SQL): a SQL Server instance's Daily checks rows out of its Summary cells, the failed
// read's row, the reader's order and the acknowledged split. Node, no DOM: the module is bundled by esbuild (web's own)
// and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/dailysql.ts --bundle --format=esm --platform=neutral --outfile=<tmp>/dailysql.mjs
//   node web/src/dailysql.test.mjs <tmp>/dailysql.mjs
// Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { cellRows, failedRow, failedRows, emptyWords, readerOrder, splitAcked, leftOut } = m;
let bad = 0;
const eq = (what, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
const cell = (key, label, level, text, extra = {}) => ({ key, label, level, text, detail: [`${key} detail`], ...extra });
const inst = { id: 7, name: 'sql01' };
const cells = [
  cell('jobs', 'Agent Jobs', 2, '1 critical', { at: '2026-11-16T01:00:00Z' }),
  cell('dumps', 'Memory Dump', 1, '3 files warning'),
  cell('full', 'Backup FULL', 0, 'OK'),
  cell('checkdb', 'Last Good Check DB', 1, '1 warning, stale'),
  cell('diff', 'Backup DIFF', 0, 'not yet', { none: true }),
  cell('qs', 'QS', 1, '1 warning', { none: true }),          // a cell with no count is drawn 'none': no row whatever its level
  cell('activity', 'Activity', 2, '1 critical'),              // blocking: left out
  cell('errors', 'Collection Errors (24hrs)', 2, '2 critical'), // failing now: the overview's 'collection failing' rows already
  cell('snapshot', 'Snapshot Age', 1, '1 warning'),
  cell('disk', 'Drive Space', 2, '1 critical', { detail: Array.from({ length: 14 }, (_, i) => `v${i}`) }),
];
const rows = cellRows(inst, cells);
eq('a row per cell at warning or critical, none for OK, a cell with no count, blocking, Snapshot Age and Collection Errors at critical',
  rows.map(r => r.cell), ['jobs', 'dumps', 'checkdb', 'disk']);
eq('the severity is the cell level, the check its column, the object its words, the instance its own',
  rows.map(r => [r.severity, r.check_name, r.object, r.instance, r.instance_id]),
  [['critical', 'Agent Jobs', '1 critical', 'sql01', 7], ['warning', 'Memory Dump', '3 files warning', 'sql01', 7],
   ['warning', 'Last Good Check DB', '1 warning, stale', 'sql01', 7], ['critical', 'Drive Space', '1 critical', 'sql01', 7]]);
eq('when: the cell\'s own time, else null', rows.map(r => r.at), ['2026-11-16T01:00:00Z', null, null, null]);
eq('the detail: twelve lines at most, then the count of the rest', rows[3].detail.split('; ').slice(-2), ['v11', '... 2 more']);
eq('the groups left out', [...leftOut].sort(), ['activity', 'snapshot']);
// review-28 code S6, the lead 11-16 20:01: a collection that failed in the last 24 hours and runs well now - Collection
// Errors at warning - is a row on either engine (no overview row holds that state)
const rec = cellRows({ id: 8, name: 'pg-b' }, [cell('errors', 'Collection Errors (24hrs)', 1, '3', { at: '2026-11-16T02:00:00Z' })]);
eq('Collection Errors at warning: one warning row, its column, its words, its cell',
  rec.map(r => [r.severity, r.check_name, r.object, r.instance, r.cell, r.at]), [['warning', 'Collection Errors (24hrs)', '3', 'pg-b', 'errors', '2026-11-16T02:00:00Z']]);
// review-28 code S2: every row acknowledged is not 'All checks pass'
eq('the empty grid with nothing acknowledged', emptyWords(0).startsWith('All checks pass: '), true);
eq('the empty grid with rows acknowledged', emptyWords(2), 'No open check: 2 acknowledged, listed below.');
const f = failedRow('500: cells: boom');
eq('the failed read: one critical row naming no instance', [f.severity, f.instance, f.instance_id, f.check_name, f.object], ['critical', '', null, 'check could not run', 'SQL Server status cells']);
eq('its detail says the read and what is missing', /GET \/api\/mssql\/summary failed \(500: cells: boom\)/.test(f.detail), true);
// review-28 code S4: the failed read is a row only where the fleet holds a SQL Server instance
eq('the failed read on a fleet with a SQL Server instance', failedRows(true, ['postgres', 'sqlserver'], 'x').length, 1);
eq('the failed read on a PostgreSQL-only fleet: no row', failedRows(true, ['postgres', 'postgres'], 'x'), []);
eq('a read that did not fail: no row', failedRows(false, ['sqlserver'], 'x'), []);
const pg = [
  { severity: 'warning', instance: 'pg-a', instance_id: 1, check_name: 'collection stale', object: 'x' },
  { severity: 'critical', instance: 'pg-a', instance_id: 1, check_name: 'collection failing', object: 'y' },
  { severity: 'critical', instance: '', instance_id: null, check_name: 'check could not run', object: 'jobs' },
];
eq('the reader\'s order over both engines: critical first, then instance, check, object',
  readerOrder([...pg, ...rows]).map(r => `${r.severity[0]} ${r.instance} ${r.check_name}`),
  ['c  check could not run', 'c pg-a collection failing', 'c sql01 Agent Jobs', 'c sql01 Drive Space', 'w pg-a collection stale', 'w sql01 Last Good Check DB', 'w sql01 Memory Dump']);
const sp = splitAcked([...pg, ...rows], r => r.cell === 'dumps' || r.check_name === 'collection failing' ? 'acknowledged by ann' : null);
eq('the acknowledged rows apart, with their words; the rest open, in order',
  [sp.open.map(r => r.cell ?? r.check_name), sp.acked.map(r => [r.cell ?? r.check_name, r.acknowledged])],
  [['collection stale', 'check could not run', 'jobs', 'checkdb', 'disk'], [['collection failing', 'acknowledged by ann'], ['dumps', 'acknowledged by ann']]]);
eq('no cell, no row', cellRows(inst, []), []);
if (bad) { console.log(`FAIL dailysql.test.mjs: ${bad} row(s)`); process.exit(1); }
console.log('ok   dailysql.test.mjs: every row');
