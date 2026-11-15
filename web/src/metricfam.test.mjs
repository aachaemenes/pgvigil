// Unit rows of the Metrics page's Collection family (metricfam.ts; B6g-4, N30 / N31): hidden until 'Collection Metrics'
// is ticked, its read cut by its own collection (the sub-series slot: the lead's 07:4x SERIES (a)), its words.
//   node web/src/metricfam.test.mjs <tmp>/metricfam.mjs
let bad = 0;
let m;
try { m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href); }
catch (e) { bad++; console.log(`FAIL metricfam module did not load: ${e instanceof Error ? e.message.split('\n')[0] : String(e)}`); }
const call = (what, fn, want) => {
  let got;
  try { got = fn(); } catch (e) { bad++; console.log(`FAIL ${what}: ${e instanceof Error ? e.message : String(e)}`); return; }
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
if (m) {
  const fams = [['sessions', 'Sessions'], ['database', 'Database'], ['host', 'Host'], ['collection', 'Collection']];
  call('the Collection family hidden while not ticked', () => m.visibleFamilies(fams, false).map(f => f[0]), ['sessions', 'database', 'host']);
  call('... shown once ticked', () => m.visibleFamilies(fams, true).map(f => f[0]), ['sessions', 'database', 'host', 'collection']);
  call('a family read cut by its own sub-series: the collection family by the collection', () => [m.subSeries('collection', 'sales', 'activity'), m.subSeries('database', 'sales', 'activity'), m.subSeries('sessions', 'sales', 'activity')],
    ['activity', 'sales', 'sales']);
  call('no collection cut: the instance\'s collections summed', () => m.subSeries('collection', 'sales', undefined), undefined);
  call('the picker\'s words', () => [m.subWords('collection'), m.subWords('database')],
    [{ noun: 'collection', all: 'all collections (summed)', label: 'Collection' }, { noun: 'database', all: 'all databases (summed)', label: 'Database' }]);
  call('the tick\'s key, kept per browser', () => m.collectionTickKey, 'pgvigil.metricsCollection');
}
console.log(bad ? `metricfam: ${bad} FAIL` : 'metricfam: 0 FAIL');
process.exit(bad ? 1 : 0);
