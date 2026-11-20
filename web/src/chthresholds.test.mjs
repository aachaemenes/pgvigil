// Unit rows of Collection Health's thresholds dialog (chthresholds.ts; B6g-2, N33 / N41): DBA Dash's dialog
// (CollectionHealthThresholdsDialog.cs, 4.25.0) - the 'Apply to' scopes of a row, a scope's own live row, what a scope
// inherits setting by setting (CollectionHealthThresholds_Get.sql: this instance and collection reads this instance,
// this collection on every instance, then everything; this instance and this collection on every instance read
// everything; everything reads the defaults), the values' words, and the write a Save sends.
// Node, no DOM: chthresholds.ts bundled.
//   node web/src/chthresholds.test.mjs <tmp>/chthresholds.mjs
let bad = 0;
let m;
try { m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href); }
catch (e) { bad++; console.log(`FAIL chthresholds module did not load: ${e instanceof Error ? e.message.split('\n')[0] : String(e)}`); }
const call = (what, fn, want) => {
  let got;
  try { got = fn(); } catch (e) { bad++; console.log(`FAIL ${what}: ${e instanceof Error ? e.message : String(e)}`); return; }
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
if (m) {
  const live = [
    { instance_id: 7, collection: 'activity', warn_fails_in_row: 2 },                   // this instance and collection
    { instance_id: 7, collection: null, warn_fail_minutes: 20, min_runs: 8, crit_fail_pct: 30 },   // this instance, every collection
    { instance_id: null, collection: 'activity', crit_fail_pct: '40.00' },                // this collection, every instance (numeric as text)
    { instance_id: null, collection: null, min_runs: 6, dont_monitor: false },            // everything
    { instance_id: 9, collection: 'activity', warn_fails_in_row: 5 },                     // another instance's: never read here
  ];
  const sc = m.chScopes ? m.chScopes(7, 'sql07', 'activity') : [];
  const [ic, ia, ac, aa] = sc;
  call('the four scopes of a row, in DBA Dash\'s words and order', () => sc.map(s => [s.key, s.words, s.instance_id, s.collection]),
    [['ic', 'activity on sql07', 7, 'activity'], ['ia', 'All collections on sql07', 7, null], ['ac', 'activity on all instances', null, 'activity'], ['aa', 'All collections on all instances', null, null]]);
  call('a row with no instance (the collection grain): this collection on every instance, everything', () => m.chScopes(null, '', 'activity').map(s => s.key), ['ac', 'aa']);
  call('a scope\'s own live row', () => m.ownRow(live, ia)?.warn_fail_minutes, 20);
  call('a scope with no row of its own', () => m.ownRow([], ic), null);
  call('another instance\'s row is never this scope\'s', () => m.ownRow([live[4]], ic), null);
  // what each scope inherits, setting by setting
  call('this instance and collection inherits minutes from this instance\'s row', () => m.inheritedOf(live, sc, ic, 'warn_fail_minutes'), { value: 20, from: 'All collections on sql07' });
  // the middle levels' order - this instance's row over this collection's row on every instance
  call('... the critical per cent from this instance\'s row, over this collection\'s on every instance', () => m.inheritedOf(live, sc, ic, 'crit_fail_pct'), { value: 30, from: 'All collections on sql07' });
  const live2 = [{ instance_id: null, collection: 'activity', crit_fail_pct: '40.00' }, { instance_id: null, collection: null, crit_fail_pct: 45, min_runs: 6 }];
  call('... and this collection\'s row on every instance over everything\'s', () => m.inheritedOf(live2, sc, ic, 'crit_fail_pct'), { value: 40, from: 'activity on all instances' });
  call('... a setting no level sets: DBA Dash\'s default', () => m.inheritedOf(live, sc, ic, 'crit_fails_in_row'), { value: 3, from: 'DBA Dash\'s default' });
  // the key a collection's row on every instance sets (40), so a read of ac for the ia level fails here
  call('every collection on the instance inherits from everything, never from one collection\'s row', () => m.inheritedOf(live, sc, ia, 'crit_fail_pct'), { value: 50, from: 'DBA Dash\'s default' });
  call('... everything\'s value over the default', () => m.inheritedOf(live2, sc, ia, 'crit_fail_pct'), { value: 45, from: 'All collections on all instances' });
  call('... and the minimum runs from everything', () => m.inheritedOf(live, sc, ia, 'min_runs'), { value: 6, from: 'All collections on all instances' });
  call('this collection on every instance never reads this instance\'s row', () => m.inheritedOf(live, sc, ac, 'warn_fail_minutes'), { value: 10, from: 'DBA Dash\'s default' });
  call('everything inherits the defaults, never its own row', () => m.inheritedOf(live, sc, aa, 'min_runs'), { value: 5, from: 'DBA Dash\'s default' });
  call('Don\'t monitor\'s default is No (monitored)', () => m.inheritedOf([], sc, ic, 'dont_monitor'), { value: false, from: 'DBA Dash\'s default' });
  call('the eight settings in DBA Dash\'s order', () => m.chSettings.map(s => s.key),
    ['warn_fails_in_row', 'warn_fail_minutes', 'crit_fails_in_row', 'crit_fail_minutes', 'warn_fail_pct', 'crit_fail_pct', 'min_runs', 'dont_monitor']);
  call('their labels in DBA Dash\'s words', () => m.chSettings.map(s => s.label),
    ['Failed runs in a row', 'And failing for at least (minutes)', 'Failed runs in a row', 'And failing for at least (minutes)',
     'Warning: failed or partly failed %', 'Critical: failed %', 'Only with at least this many runs', 'Don\'t monitor (always N/A)']);
  call('a value\'s words: Yes / No, a number to two places at most', () => [m.chFormat(true), m.chFormat(false), m.chFormat('40.00'), m.chFormat(12.5), m.chFormat(3)], ['Yes', 'No', '40', '12.5', '3']);
  // the write a Save sends: the ticked values only (an unticked one inherits), the scope by its keys
  call('a Save of two ticked values on this instance and collection', () => m.chPayload(ic, { warn_fails_in_row: 4, crit_fail_pct: 60, min_runs: null }, null),
    { op: 'set', instance_id: 7, collection: 'activity', warn_fails_in_row: 4, crit_fail_pct: 60 });
  call('... on everything: no instance_id, no collection', () => m.chPayload(aa, { dont_monitor: true }, null), { op: 'set', dont_monitor: true });
  call('a Save with every value unticked on a scope that has its own row: inherit', () => m.chPayload(ia, {}, live[1]), { op: 'inherit', instance_id: 7 });
  call('... on a scope with none: nothing to send', () => m.chPayload(ic, { warn_fails_in_row: null }, null), null);
  call('Don\'t monitor unticked is inherit, ticked false is a value', () => m.chPayload(ic, { dont_monitor: false }, null), { op: 'set', instance_id: 7, collection: 'activity', dont_monitor: false });
}
console.log(bad ? `chthresholds: ${bad} FAIL` : 'chthresholds: 0 FAIL');
process.exit(bad ? 1 : 0);
