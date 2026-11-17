// Unit tests of savetable.ts (task PGRID 7b, Save Table's From items: what From Data Table writes, where, and the
// confirmation). Node, no DOM: the module is compiled by esbuild (web's own) and its path given as the argument.
//   web/node_modules/.bin/esbuild web/src/savetable.ts --format=esm --outfile=<tmp>/savetable.mjs
//   node web/src/savetable.test.mjs <tmp>/savetable.mjs
// scripts/proof-gridmenu.sh part U runs it after the web build. Every row prints 'ok' or 'FAIL'; the exit is 1 when any
// failed. Written before savetable.ts (red first: no module to compile).
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { saveKeys, fromOff, confirmWord, FLEET_OFF } = m;
let bad = 0, n = 0;
const eq = (what, got, want) => {
  n++;
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};

// the lead 11-17 02:17 (S8): From Data Table writes every row with the page's DRAWN columns plus the chooser's ADDED
// ones - never a key merely offered, a '_' key or a held-back one
eq('drawn then added, in that order', saveKeys(['name', 'calls'], ['queryid'], []), ['name', 'calls', 'queryid']);
eq('nothing added: the drawn columns alone', saveKeys(['name', 'calls'], [], []), ['name', 'calls']);
eq("a '_' key never written", saveKeys(['name', '_row'], ['_sort'], []), ['name']);
eq('a held-back key never written, drawn or added', saveKeys(['name', 'query_raw'], ['plan_raw'], ['query_raw', 'plan_raw']), ['name']);
eq('an added key the page also draws written once', saveKeys(['name', 'calls'], ['calls'], []), ['name', 'calls']);

// the target is the page's OWN instance; a fleet page's two From items stay in the menu, off with words
eq('the fleet words', FLEET_OFF, "off: a fleet page's rows come from many instances; save from the instance's own page");
eq('a fleet page: off with the fleet words even when the door is on', fromOff(true, ''), FLEET_OFF);
eq("a fleet page: the fleet words before the server's", fromOff(true, 'off: an administrator turns on doors: save_table in pgvigil.yaml'), FLEET_OFF);
eq("an instance's page: the server's off words", fromOff(false, "off: this instance's actions: list does not name save_table"), "off: this instance's actions: list does not name save_table");
eq("an instance's page with the door on: on", fromOff(false, ''), '');

// review-29 S7: the confirmation types the target, never the table name
eq('the confirmation word', confirmWord('demo-onprem-sql01', 'Sales'), 'demo-onprem-sql01/Sales');

console.log(`savetable: ${n} rows, ${bad} FAIL`);
process.exit(bad ? 1 : 0);
