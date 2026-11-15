// Unit rows of the Collection Health rules the Imported servers page and the tab share (the review B6f3 #9, #11):
// chhealth.ts - healthVersion (0138's dbadash_health_version, word for word), each header's tooltip by its label
// (4.25.0's, 4.24.1's, both on a mixed fleet), each row's landing by its own repository's version, and the charts'
// whole hours up to now (a range ending in the future has no hours past now). Node, no DOM: chhealth.ts bundled.
//   node web/src/chhealth.test.mjs <tmp>/chhealth.mjs
let bad = 0;
let m;
try { m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href); }
catch (e) { bad++; console.log(`FAIL chhealth module did not load: ${e instanceof Error ? e.message.split('\n')[0] : String(e)}`); }
const call = (what, fn, want) => {
  let got;
  try { got = fn(); } catch (e) { bad++; console.log(`FAIL ${what}: ${e instanceof Error ? e.message : String(e)}`); return; }
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
if (m) {
  // 0138's forms: digits and dots only, 4.25 or later
  for (const [v, want] of [['', false], ['4', false], ['4.24.99', false], ['4.25', true], ['4.25.0', true], ['4.25.0.7', true], ['5', true], ['4.25.0-rc1', false], [null, false]])
    call(`healthVersion(${JSON.stringify(v)})`, () => m.healthVersion(v), want);
  call('the tips of Collection Health', () => m.errColTips('Collection Health'), [m.collectionHealthTip]);
  call('the tips of Collection errors (24hrs)', () => m.errColTips('Collection errors (24hrs)'), [m.collectionErrorsTip241]);
  call('the tips of a mixed fleet\'s header: both, 4.25.0\'s first', () => m.errColTips('Collection Health / Collection errors (24hrs)'), [m.collectionHealthTip, m.collectionErrorsTip241]);
  call('another header: no tip', () => m.errColTips('Backup'), []);
  call('4.24.1\'s tooltip word for word (Summary.Designer.cs L433)', () => m.collectionErrorsTip241,
    'Count of errors encountered by the DBA Dash service during data collection or import for the instance.  Retries are highlighted as warning, failures are critical.');
  const rh = m.repoHealthOf([{ repository: 'a', version: '4.25.0' }, { repository: 'b', version: '4.24.1' }]);
  call('a mixed repositories table: each row lands by its own repository', () => [rh.get('a'), rh.get('b'), rh.get('c') ?? null], [true, false, null]);
  const H = 3600e3, now = Date.parse('2026-11-15T09:45:00Z');
  call('whole hours of a past range: 09:30 .. 11:20 = 3 (09, 10, 11)', () => m.chartHours('2026-11-15T09:30:00Z', '2026-11-15T11:20:00Z', now + 3 * H), 3);
  call('a range ending in the future counts no hour past now: 09:30 .. 12:00 read at 09:45 = 1', () => m.chartHours('2026-11-15T09:30:00Z', '2026-11-15T12:00:00Z', now), 1);
  call('a range on the hour: 08:00 .. 10:00 = 2', () => m.chartHours('2026-11-15T08:00:00Z', '2026-11-15T10:00:00Z', now + H), 2);
  // B6g-1 (N25 / N26): what a cost cell says when it holds no number - PostgreSQL's 'not read by pgvigil' (the lead's
  // words: nothing more is said of why), any other empty cell 'not read'; a number, zero too, is drawn as a number
  call('a cost cell with a number: drawn as a number', () => m.costWords(12, 'sqlserver'), null);
  call('a cost cell with 0: a number, not "not read"', () => m.costWords(0, 'sqlserver'), null);
  call('an empty cost cell of a PostgreSQL row', () => m.costWords(null, 'postgres'), 'not read by pgvigil');
  call('an empty cost cell of a SQL Server row (no run reached its end read)', () => m.costWords(null, 'sqlserver'), 'not read');
  call('an empty cost cell of a row per collection (no engine)', () => m.costWords(undefined, undefined), 'not read');
}
console.log(bad ? `chhealth: ${bad} FAIL` : 'chhealth: 0 FAIL');
process.exit(bad ? 1 : 0);
