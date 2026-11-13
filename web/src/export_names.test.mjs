// Unit tests of export_names.ts (a workbook's sheet names). Node, no DOM: the module is compiled by esbuild (web's own)
// and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/export_names.ts --format=esm --outfile=<tmp>/export_names.mjs
//   node web/src/export_names.test.mjs <tmp>/export_names.mjs
// scripts/proof-export.sh runs both first. Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { sheetNames, sheetTitle, parted, ownName, SHEET_MAX } = m;
let bad = 0, n = 0;
const all = [];
const eq = (what, got, want) => {
  n++;
  if (Array.isArray(got)) all.push(...got);
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};

// sheetTitle: the heading's words a sheet may hold, a time left out
eq('title: a time in brackets out', sheetTitle('Jobs (read 11/13/2026, 05:25:00)'), 'Jobs');
eq('title: a time after a word out (en-US)', sheetTitle('Per day since 11/6/2026, 20:22'), 'Per day');
eq('title: a time after a word out (de-DE), the words after it kept', sheetTitle('Per day since 06.11.2026, 20:22 (the whole fleet)'), 'Per day (the whole fleet)');
eq('title: a time after a word out (fr-FR, no comma)', sheetTitle('Per day since 06/11/2026 20:22'), 'Per day');
eq('title: a refused character a space, runs of spaces one', sheetTitle('a/b:  c'), 'a b c');
eq('title: the quotes at either end off', sheetTitle("'quoted'"), 'quoted');
eq('title: a count with its word stays', sheetTitle('Fastest-growing tables (7 days)'), 'Fastest-growing tables (7 days)');
eq('title: a bare count in brackets out (it reads as a numbered repeat)', sheetTitle('Findings (16)'), 'Findings');
eq('title: a bare count in the locale grouping out', sheetTitle('Findings (1,234)'), 'Findings');

// one name: as the heading, cut at 31
eq('a heading as it is', sheetNames(['Backups']), ['Backups']);
eq('cut at 31 inside a bracket at the end: the bracket out', sheetNames(['Top statements by total time (last 1h)']), ['Top statements by total time']);
eq('cut at 31, a trailing space off', sheetNames(['Top statements by total time for the fleet']), ['Top statements by total time fo']);
eq('a time left out of the name', sheetNames(['Jobs (read 11/13/2026, 05:25:00)']), ['Jobs']);

// two headings equal after the cut: the start and the words where they part, never a number
eq('three jobs equal after the cut keep the word that differs', sheetNames([
  'DatabaseBackup - USER_DATABASES - FULL', 'DatabaseBackup - USER_DATABASES - DIFF', 'DatabaseBackup - USER_DATABASES - LOG']),
  ['DatabaseBackup - USER_DAT… FULL', 'DatabaseBackup - USER_DAT… DIFF', 'DatabaseBackup - USER_DATA… LOG']);
eq('a heading of 31 and a longer one it starts: the short one whole, the long one its next word', sheetNames([
  'DatabaseBackup - USER_DATABASES', 'DatabaseBackup - USER_DATABASES - FULL']),
  ['DatabaseBackup - USER_DATABASES', 'DatabaseBackup - USER_DAT… FULL']);
eq('words joined by _: the part after the last shared _', sheetNames([
  'ServerA_DatabaseBackup_USER_DATABASES_FULL', 'ServerA_DatabaseBackup_USER_DATABASES_DIFF']),
  ['ServerA_DatabaseBackup_USE…FULL', 'ServerA_DatabaseBackup_USE…DIFF']);
eq('parted: one title against another', parted('DatabaseBackup - USER_DATABASES - FULL', ['DatabaseBackup - USER_DATABASES - DIFF']),
  'DatabaseBackup - USER_DAT… FULL');
eq('parted: no word parts two equal titles', parted('Steps', ['Steps']), '');

// a heading equal in full to a name taken: the heading above it first
eq("the reserved 'History' under its heading", sheetNames(['History'], [], ['Trace flags']), ['Trace flags History']);
eq("the export's own 'About' under its heading", sheetNames(['About'], [], ['Server']), ['Server About']);
eq('two equal headings under two headings: the second with its own', sheetNames(['Findings', 'Findings'], [], ['Jobs', 'Roles']), ['Findings', 'Roles Findings']);
eq('a long heading above: cut before an ellipsis', sheetNames(['History'], [], ['Default privileges (ALTER DEFAULT PRIVILEGES)']), ['Default privileges (AL… History']);
eq('a name the workbook holds already (a page sheet) under its heading', sheetNames(['Storage'], ['Storage'], ['Fleet']), ['Fleet Storage']);

// the last resort, said: two headings equal in full under one heading (xlsx-check.py X2 fails it)
eq('the last resort: equal in full, nothing above', sheetNames(['Steps', 'Steps']), ['Steps', 'Steps (2)']);

// only the page's own time shapes leave a name (a date with a 4-digit year and a clock): an address, a version, a day
// alone, a job's or a check's own words stay
eq('title: an address stays', sheetTitle('Copy backups to 10.0.0.5'), 'Copy backups to 10.0.0.5');
eq('title: a version stays', sheetTitle('Instances on 16.0.4135.4'), 'Instances on 16.0.4135.4');
eq('title: an extension version stays', sheetTitle('pg_stat_statements 1.10.0'), 'pg_stat_statements 1.10.0');
eq('title: a release number stays', sheetTitle('Release 1.2.3 notes'), 'Release 1.2.3 notes');
eq('title: a day without a clock stays', sheetTitle('Archive 2024-01-15 FULL'), 'Archive 2024-01-15 FULL');
eq('title: a time after "of" out', sheetTitle('The deadlock of 11/13/2026, 05:25:00'), 'The deadlock');
eq('title: a range in brackets out', sheetTitle('Sessions (11/6/2026, 04:42:56 to 11/13/2026, 04:42:56)'), 'Sessions');
eq("title: a rate's slash reads 'per'", sheetTitle('Transactions/s'), 'Transactions per s');
eq('three jobs that differ by an address keep it', sheetNames(['Backup (10.0.0.5)', 'Backup (10.0.0.6)', 'Backup (10.0.0.7)']),
  ['Backup (10.0.0.5)', 'Backup (10.0.0.6)', 'Backup (10.0.0.7)']);
eq('three jobs that differ by a day keep it', sheetNames(['Purge 2024-01-01', 'Purge 2025-01-01', 'Purge 2026-01-01']),
  ['Purge 2024-01-01', 'Purge 2025-01-01', 'Purge 2026-01-01']);

// a section the page names itself (a job's disclosure) holding headings of its own: the job's name, then the heading
// without its time ('jobA Steps')
eq('ownName: the job, then the heading without its range', ownName('jobA', 'Steps (11/6/2026, 20:22:00 to 11/13/2026, 20:22:00)'), 'jobA Steps');
eq('three pgAgent jobs opened: every sheet names its job', sheetNames(['jobA', 'jobB', 'jobC'].flatMap(j =>
  [ownName(j, 'Steps (11/6/2026, 20:22:00 to 11/13/2026, 20:22:00)'), ownName(j, 'Step runs (the newest 1,000)')])),
  ['jobA Steps', 'jobA Step runs', 'jobB Steps', 'jobB Step runs', 'jobC Steps', 'jobC Step runs']);

// a tail too long for the room after the start: the words where the titles part, not the end they share
const P = 'Maintenance plan - nightly run ', S = ' to the archive share and verify';
const three = sheetNames([P + 'alpha' + S, P + 'beta' + S, P + 'gamma' + S]);
eq('three long titles parting early keep the word that differs', three.map(x => ['alpha', 'beta', 'gamma'].find(w => x.includes(w)) ?? x), ['alpha', 'beta', 'gamma']);

// no quote at either end, a refused character beside it too; no character split at the cut
eq('title: quotes inside refused characters off', sheetTitle("/'abc'/"), 'abc');
eq('a refused character then a quote: the quote off', sheetNames(["*'abc"]), ['abc']);
eq('under a heading: no quote at the end', sheetNames(["Settings for 'x'"], ["Settings for 'x"], ['Roles']).map(x => /'$/.test(x)), [false]);
eq('a character past the BMP at the cut is not split', sheetNames(['A'.repeat(30) + '\u{1F600}…']).map(x => /[\uD800-\uDBFF]$/.test(x)), [false]);

// every name made above: 1 to 31 characters, no character Excel refuses, no quote at either end, no lone surrogate
const wrong = all.filter(s => typeof s === 'string' && (s.length < 1 || s.length > SHEET_MAX || /[\\/?*[\]:]/.test(s) || /^'|'$/.test(s) || /[\uD800-\uDBFF]$/.test(s)));
eq(`every name 1-${SHEET_MAX} characters, no refused character, no quote at an end, no lone surrogate (${all.length} names)`, wrong, []);

console.log(`${n - bad} of ${n} ok`);
process.exit(bad ? 1 : 0);
