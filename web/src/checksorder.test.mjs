// Unit tests of checksorder.ts (B20-4): the Daily checks page's worst-first order and the post's numbers. Node, no DOM:
// the module is bundled by esbuild (web's own) and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/checksorder.ts --bundle --format=esm --platform=neutral --outfile=<tmp>/checksorder.mjs
//   node web/src/checksorder.test.mjs <tmp>/checksorder.mjs
// Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { worstFirst, dailyPost } = m;
let bad = 0;
const eq = (what, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
const row = (severity, instance, id, check, object = '') => ({ severity, instance, instance_id: id, check_name: check, object });
// the reader's order: critical rows first, then by instance name, check, object (web.go overview)
const reader = [
  row('critical', '', null, 'check could not run', 'jobs'),
  row('critical', 'aaa', 1, 'collection failing', 'x'),
  row('critical', 'zzz', 3, 'collection failing', 'x'),
  row('critical', 'zzz', 3, 'collection failing', 'y'),
  row('warning', 'aaa', 1, 'collection stale', 'p'),
  row('warning', 'aaa', 1, 'collection stale', 'q'),
  row('warning', 'aaa', 1, 'collection stale', 'r'),
  row('warning', 'mmm', 2, 'job status', 'j'),
  row('warning', 'bbb', 4, 'job status', 'j'),
  row('warning', 'bbb', 4, 'job status', 'k'),
];
const names = rs => rs.map(r => `${r.instance || '-'}:${r.severity[0]}:${r.object}`);
eq('the rows naming no instance first, then instances by critical, warning count, name; each instance together, its own rows in the reader order',
  names(worstFirst(reader)),
  ['-:c:jobs', 'zzz:c:x', 'zzz:c:y', 'aaa:c:x', 'aaa:w:p', 'aaa:w:q', 'aaa:w:r', 'bbb:w:j', 'bbb:w:k', 'mmm:w:j']);
eq('the reader order is not changed in place', names(reader)[1], 'aaa:c:x');
eq('no rows', worstFirst([]), []);
eq('a tie on both counts goes by name, then by id', names(worstFirst([row('warning', 'b', 2, 'c'), row('warning', 'a', 9, 'c'), row('warning', 'a', 1, 'c', 'o')])),
  ['a:w:o', 'a:w:', 'b:w:']);
eq('the post: the counts of every row, the instance tile, the worst three instances with rows (none for the no-instance row)',
  dailyPost(worstFirst(reader), 7),
  { instances: 7, critical: 4, warnings: 6, worst: [{ name: 'zzz', critical: 2, warnings: 0 }, { name: 'aaa', critical: 1, warnings: 3 }, { name: 'bbb', critical: 0, warnings: 2 }] });
eq('a green day', dailyPost([], 5), { instances: 5, critical: 0, warnings: 0, worst: [] });
process.exit(bad ? 1 : 0);
