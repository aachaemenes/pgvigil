// Unit tests of gridfilter.ts (task PGRID B11, DBA Dash's Edit Filter: the grid's filter as one text and back). Node, no
// DOM: the module is compiled by esbuild (web's own) and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/gridfilter.ts --format=esm --outfile=<tmp>/gridfilter.mjs
//   node web/src/gridfilter.test.mjs <tmp>/gridfilter.mjs
// scripts/proof-gridmenu.sh part U runs it after the web build. Every row prints 'ok' or 'FAIL'; the exit is 1 when any
// failed. Written before gridfilter.ts (red first: no module to compile).
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { filterText, readFilterText } = m;
let bad = 0, n = 0;
const eq = (what, got, want) => {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
const refused = (what, got, ...parts) => {
  n++;
  const ok = got && got.ok === false && parts.every(p => p instanceof RegExp ? p.test(got.why) : got.why.includes(p));
  if (ok) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${JSON.stringify(got)}, want a refusal holding ${parts.map(String).join(', ')}`); }
};
const names = ['id', 'txt', 'we]ird"name', 'num', 'column 5'];
// the text: one line per column with a filter, in the columns' order, its name in brackets with a ] doubled
eq('none set: an empty text', filterText(names.map(name => ({ name, filter: '' }))), '');
eq('two set, the columns\' order', filterText([{ name: 'id', filter: '' }, { name: 'txt', filter: 'like "R%"' }, { name: 'num', filter: '>=13' }]), '[txt] like "R%"\n[num] >=13');
eq('a ] in a name doubled', filterText([{ name: 'we]ird"name', filter: 'like "o1%"' }]), '[we]]ird"name] like "o1%"');
eq('a filter of spaces is no filter', filterText([{ name: 'id', filter: '   ' }]), '');
eq('a filter trimmed', filterText([{ name: 'id', filter: '  >1  ' }]), '[id] >1');
// read back: one filter per column, '' where no line names it
eq('read: two lines', readFilterText('[txt] like "R%"\n[num] >=13', names), { ok: true, filters: ['', 'like "R%"', '', '>=13', ''] });
eq('read: a doubled ]', readFilterText('[we]]ird"name] like "o1%"', names), { ok: true, filters: ['', '', 'like "o1%"', '', ''] });
eq('read: a name with a space', readFilterText('[column 5] =""', names), { ok: true, filters: ['', '', '', '', '=""'] });
eq('read: blank lines and CRLF', readFilterText('\r\n[id] >1\r\n\r\n', names), { ok: true, filters: ['>1', '', '', '', ''] });
eq('read: an empty text clears every column', readFilterText('', names), { ok: true, filters: ['', '', '', '', ''] });
eq('read: a condition kept as typed (the filter row reads it)', readFilterText('[txt] "a" & !"b"', names), { ok: true, filters: ['', '"a" & !"b"', '', '', ''] });
for (const cols of [[{ name: 'id', filter: '>1' }, { name: 'txt', filter: 'like "R%"' }], [{ name: 'we]ird"name', filter: '<>"x]y"' }]]) {
  const all = names.map(name => ({ name, filter: cols.find(c => c.name === name)?.filter ?? '' }));
  eq(`round trip ${JSON.stringify(cols)}`, readFilterText(filterText(all), names), { ok: true, filters: all.map(c => c.filter) });
}
// refused in words naming the line
refused('no [column]', readFilterText('txt like "R%"', names), /line 1\b/i);
refused('a column the grid does not have', readFilterText('[nosuch] ="x"', names), /line 1\b/i, 'nosuch');
refused('a column on two lines', readFilterText('[id] >1\n[id] <5', names), /line 2\b/i, 'line 1');
refused('a name never closed', readFilterText('[id >1', names), /line 1\b/i);
refused('a column with no condition', readFilterText('[id]', names), /line 1\b/i, 'id');
refused('the second line bad, the first good', readFilterText('[id] >1\nnum >2', names), /line 2\b/i);
console.log(`gridfilter: ${n} rows, ${bad} FAIL`);
process.exit(bad ? 1 : 0);
