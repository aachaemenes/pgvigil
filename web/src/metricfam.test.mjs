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
  call('no collection cut: the instance\'s series (the worst collection each hour)', () => m.subSeries('collection', 'sales', undefined), undefined);
  // the B6g-4 fold (the lead's 14:5x #6 (a)): the empty cut of the Collection family is the worst collection each hour
  call('the picker\'s words', () => [m.subWords('collection'), m.subWords('database')],
    [{ noun: 'collection', all: 'the worst collection', label: 'Collection', none: 'the worst collection each hour' },
     { noun: 'database', all: 'all databases (summed)', label: 'Database', none: 'all databases summed' }]);
  call('the tick\'s key, kept per browser', () => m.collectionTickKey, 'pgvigil.metricsCollection');
  // the fold's #5: a link that names the family shows it while the tick is off
  call('a link naming the Collection family shows it unticked', () => m.visibleFamilies(fams, false, 'collection').map(f => f[0]), ['sessions', 'database', 'host', 'collection']);
  call('... any other link does not', () => m.visibleFamilies(fams, false, 'database').map(f => f[0]), ['sessions', 'database', 'host']);
  // the fold's #7: a rule's sub-series named by its family
  call('a rule\'s sub-series word by its metric', () => [m.subNoun('collection.cpu_ms'), m.subNoun('database.commits_s'), m.subNoun('sessions.active')],
    ['collection', 'database', 'database']);
  // the fold's #4: storage that throws keeps the tick for the page's life
  call('the tick with storage off', () => {
    const t = m.tickStore(() => ({ getItem() { throw new Error('SecurityError'); }, setItem() { throw new Error('SecurityError'); } }));
    const before = t.get(m.collectionTickKey); t.set(m.collectionTickKey, '1'); return [before, t.get(m.collectionTickKey)];
  }, [null, '1']);
  call('the tick with storage on', () => {
    const box = new Map(); const t = m.tickStore(() => ({ getItem: k => box.get(k) ?? null, setItem: (k, v) => { box.set(k, v); } }));
    t.set(m.collectionTickKey, '1'); return [t.get(m.collectionTickKey), box.get(m.collectionTickKey)];
  }, ['1', '1']);
}
console.log(bad ? `metricfam: ${bad} FAIL` : 'metricfam: 0 FAIL');
process.exit(bad ? 1 : 0);
