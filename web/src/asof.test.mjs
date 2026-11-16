// Unit tests of a remote instance's freshness: asof.ts (the 'as of' line, the site's silence) and instheader.ts's
// freshness() for a remote instance's live row. Node, no DOM: each module is bundled by esbuild (web's own) and the
// two bundles' paths given as the arguments, instheader first; the menus' listeners and uPlot's pixel ratio stubbed
// as verdict.test.mjs does.
//   web/node_modules/.bin/esbuild web/src/instheader.ts --bundle --format=esm --platform=neutral --main-fields=module,main --outfile=<tmp>/instheader.mjs
//   web/node_modules/.bin/esbuild web/src/asof.ts --bundle --format=esm --platform=neutral --main-fields=module,main --outfile=<tmp>/asof.mjs
//   node web/src/asof.test.mjs <tmp>/instheader.mjs <tmp>/asof.mjs
// Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const noop = () => {};
globalThis.document ??= { addEventListener: noop, removeEventListener: noop, querySelector: () => null, documentElement: { dataset: {} } };
globalThis.matchMedia ??= () => ({ matches: false, addEventListener: noop, removeEventListener: noop });
globalThis.devicePixelRatio ??= 1;
globalThis.window ??= { addEventListener: noop, removeEventListener: noop, dispatchEvent: noop, matchMedia: globalThis.matchMedia };
const load = p => import(new URL(p, 'file://' + process.cwd() + '/').href);
const { freshness } = await load(process.argv[2]);
const { asOfLine, quietLine } = await load(process.argv[3]);
let bad = 0;
const eq = (what, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};

const now = Date.parse('2026-11-16T18:00:00Z');
const ago = min => new Date(now - min * 60000).toISOString();
const clock = at => new Date(at).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
// a remote instance's live row: its newest healthy collection 50 minutes back, inside a bundle whose window ended 45
// minutes back; the site's bundles come every hour (a copy), each covering 5 minutes
const remote = (asOfMin, lastMin, extra = {}) => ({ last_collect_at: ago(lastMin), coll_stale: 0, as_of: ago(asOfMin), site: 'site1',
  collector: 'c1', interval_secs: 300, expected_every_secs: 3600, ...extra });

eq('a remote instance 45 min after its newest bundle (the site sends every hour) is online, not offline',
  freshness(remote(45, 50), now), 'online');
eq("its 'as of' line names the bundle's end, the collector, the site and the interval",
  asOfLine(remote(45, 50)), `as of ${clock(ago(45))} (remote collector c1 of site site1, a bundle every 5 min)`);
eq('no silence inside 2 x expected_every', quietLine(remote(45, 50), now), '');
eq('a remote instance whose site sent nothing for 2 x expected_every is offline',
  freshness(remote(125, 130), now), 'offline');
eq('and says why in its finding\'s words', quietLine(remote(125, 130), now), 'site site1 has gone quiet: last bundle 2h ago');
eq('a remote collector that collected nothing healthy for 30 minutes before its newest bundle: offline',
  freshness(remote(10, 45), now), 'offline');
eq('a collection stale against as_of (coll_stale from the live read) is stale, as for any instance',
  freshness(remote(10, 12, { coll_stale: 1 }), now), 'stale');
eq('an hourly site: a bundle every 60 min', asOfLine(remote(5, 6, { interval_secs: 3600 })),
  `as of ${clock(ago(5))} (remote collector c1 of site site1, a bundle every 60 min)`);
// an instance the hub reads itself keeps PerformanceMonitor's rule (offline after 30 minutes by the repository's clock)
eq('a pgvigil.yaml instance 50 min after its newest collection is offline', freshness({ last_collect_at: ago(50), coll_stale: 0 }, now), 'offline');
eq('and has no as-of line', asOfLine({ last_collect_at: ago(5) }), '');
process.exit(bad ? 1 : 0);
