// Unit tests of groupby.ts (task PGRID B10, DBA Dash's Group By dialog: the groups and their aggregates). Node, no DOM:
// the module is compiled by esbuild (web's own) and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/groupby.ts --format=esm --outfile=<tmp>/groupby.mjs
//   node web/src/groupby.test.mjs <tmp>/groupby.mjs
// scripts/proof-gridmenu.sh part U runs it after the web build. Every row prints 'ok' or 'FAIL'; the exit is 1 when any
// failed. Written before groupby.ts (red first: no module to compile).
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { groupBy } = m;
let bad = 0, n = 0;
const eq = (what, got, want) => {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
const near = (what, got, want, tol) => {
  n++;
  if (typeof got === 'number' && Math.abs(got - want) <= tol) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${JSON.stringify(got)}, want ${want} (within ${tol})`); }
};
// a grid: name, platform, sessions (a number; one empty), started (words that compare as dates do)
const cols = ['name', 'platform', 'sessions', 'started'];
const c = (text, num) => num === undefined ? { text } : { text, n: num, kind: 'int' };
const rows = [
  [c('a'), c('rds'), c('10', 10), c('2026-11-01')],
  [c('b'), c('rds'), c('30', 30), c('2026-11-03')],
  [c('c'), c('onprem'), c('5', 5), c('2026-11-02')],
  [c('d'), c('rds'), c(''), c('2026-11-04')],
  [c('e'), c(''), c('5', 5), c('')],
];
const spec = { keys: ['platform'], count: true, pct: true, aggs: [{ col: 'name', kinds: ['distinct'] }, { col: 'sessions', kinds: ['distinct', 'sum', 'sumpct', 'avg', 'min', 'max'] }, { col: 'started', kinds: ['min', 'max'] }] };
const g = groupBy(cols, rows, spec);
eq('the columns, DBA Dash\'s names', g.cols, ['platform', 'Count', 'Count %', 'name | Count Distinct', 'sessions | Count Distinct', 'sessions | Sum', 'sessions | Sum %', 'sessions | Avg', 'sessions | Min', 'sessions | Max', 'started | Min', 'started | Max']);
eq('the groups, the largest first, then by key', g.rows.map(r => r.key), [['rds'], [''], ['onprem']]);
const rds = g.rows[0].vals;
eq('Count', rds[0], { n: 3 });
near('Count % of Total', rds[1]?.n, 60, 1e-9);
eq('Count %: a percent', rds[1]?.pct, true);
eq('name | Count Distinct', rds[2], { n: 3 });
eq('sessions | Count Distinct (the empty cell one value)', rds[3], { n: 3 });
eq('sessions | Sum (the empty cell left out)', rds[4], { n: 40, kind: 'int' });
near('sessions | Sum % (of the grand 50)', rds[5]?.n, 80, 1e-9);
near('sessions | Avg (of the two numbers)', rds[6]?.n, 20, 1e-9);
eq('sessions | Min', rds[7], { n: 10, kind: 'int' });
eq('sessions | Max', rds[8], { n: 30, kind: 'int' });
eq('started | Min (words: the least)', rds[9], { text: '2026-11-01' });
eq('started | Max', rds[10], { text: '2026-11-04' });
const empty = g.rows[1].vals;
eq('the empty key\'s started | Min: none', empty[9], null);
eq('no number in a group: Sum none', groupBy(cols, [rows[3]], { keys: ['platform'], count: false, pct: false, aggs: [{ col: 'sessions', kinds: ['sum', 'avg', 'min'] }] }).rows[0].vals, [null, null, null]);
eq('two keys', groupBy(cols, rows, { keys: ['platform', 'sessions'], count: true, pct: false, aggs: [] }).rows.map(r => r.key.join('|')), ['|5', 'onprem|5', 'rds|', 'rds|10', 'rds|30']);   // the counts equal: by the keys, column by column, the empty one first, numbers as numbers
eq('a key the grid does not have: no groups', groupBy(cols, rows, { keys: ['nosuch'], count: true, pct: false, aggs: [] }), { cols: [], rows: [] });
eq('mixed units in one column: said', groupBy(['k', 'v'], [[c('x'), { text: '1 KB', n: 1024, kind: 'bytes' }], [c('x'), { text: '2 s', n: 2, kind: 'secs' }]], { keys: ['k'], count: false, pct: false, aggs: [{ col: 'v', kinds: ['sum'] }] }).rows[0].vals, [{ text: 'mixed units' }]);
console.log(`groupby: ${n} rows, ${bad} FAIL`);
process.exit(bad ? 1 : 0);
