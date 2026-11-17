// Unit tests of export_text.ts (task PGRID, P-opengrid's fault on the base: the Instances grid's version '17.10' was
// written to the JSON file as the number 17.1, so Open Grid drew another version). Node, no DOM: the module is compiled
// by esbuild (web's own) and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/export_text.ts --format=esm --outfile=<tmp>/export_text.mjs
//   node web/src/export_text.test.mjs <tmp>/export_text.mjs
// scripts/proof-gridmenu.sh part U runs it after the web build. Every row prints 'ok' or 'FAIL'; the exit is 1 when any
// failed. Written before export_text.ts (red first: no module to compile; the browser's red row is P-opengrid).
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { labelText } = m;
let bad = 0, n = 0;
const eq = (what, got, want) => {
  n++;
  if (got === want) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); }
};
// a label: the number's own text is another text, so the text is kept
for (const s of ['17.10', '1.0', '16.00', '0.50', '1e3', '2E2', '-0', '1.10e2']) eq(`'${s}' is kept as text`, labelText(s), true);
// a number exactly as written: it writes back the same text
for (const s of ['17.1', '16.4', '5432', '0', '-3', '0.5', '12.25', '100']) eq(`'${s}' is its number`, labelText(s), false);
// the round trip the JSON form makes: a kept text comes back as it was, a number as its own text
for (const s of ['17.10', '16.4', '5432', '1.0']) {
  const v = labelText(s) ? s : Number(s);
  eq(`'${s}' through JSON reads back as itself`, String(JSON.parse(JSON.stringify(v))), s);
}
console.log(`exporttext: ${n} rows, ${bad} FAIL`);
process.exit(bad ? 1 : 0);
