// Unit tests of export_names.ts (a workbook's sheet names). Node, no DOM: the module is compiled by esbuild (web's own)
// and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/export_names.ts --format=esm --outfile=<tmp>/export_names.mjs
//   node web/src/export_names.test.mjs <tmp>/export_names.mjs
// scripts/proof-export.sh runs both first. Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { sheetNames, sheetTitle, parted, SHEET_MAX } = m;
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
eq('title: a count in brackets stays', sheetTitle('Fastest-growing tables (7 days)'), 'Fastest-growing tables (7 days)');

// one name: as the heading, cut at 31
eq('a heading as it is', sheetNames(['Backups']), ['Backups']);
eq('cut at 31, a trailing space off', sheetNames(['Top statements by total time (last 1h)']), ['Top statements by total time (l']);
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

// every name made above: 1 to 31 characters, no character Excel refuses, no quote at either end
const wrong = all.filter(s => typeof s === 'string' && (s.length < 1 || s.length > SHEET_MAX || /[\\/?*[\]:]/.test(s) || /^'|'$/.test(s)));
eq(`every name 1-${SHEET_MAX} characters, no refused character, no quote at an end (${all.length} names)`, wrong, []);

console.log(`${n - bad} of ${n} ok`);
process.exit(bad ? 1 : 0);
