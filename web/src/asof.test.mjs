// Unit tests of a remote instance's freshness (asof.ts: remoteFreshness, and freshness() - the header's rule, which asks
// it first -, the 'as of' line, the site's silence). Node, no DOM (asof.ts imports no page module): bundled by esbuild (web's
// own) and the bundle's path given as the argument.
//   web/node_modules/.bin/esbuild web/src/asof.ts --bundle --format=esm --platform=neutral --main-fields=module,main --outfile=<tmp>/asof.mjs
//   node web/src/asof.test.mjs <tmp>/asof.mjs
// Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const mod = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { remoteFreshness: freshness, asOfLine, quietLine } = mod;
// freshness(): the header's own rule (instheader.ts re-exports it from asof.ts: review B S7 / C S7) - a remote
// instance by its bundle and its site's cadence first, PerformanceMonitor's 30-minute rule for any other
const headerFreshness = typeof mod.freshness === 'function' ? mod.freshness : () => 'freshness() is not in asof.ts';
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
// an instance the hub reads itself is not asof.ts's: instheader.ts keeps PerformanceMonitor's rule for it
eq('a pgvigil.yaml instance has no remote freshness', freshness({ last_collect_at: ago(50), coll_stale: 0 }, now), null);
eq('and has no as-of line', asOfLine({ last_collect_at: ago(5) }), '');
eq("the header's freshness: a remote instance 45 min after its newest bundle on an hourly site is online (asof.ts first)",
  headerFreshness(remote(45, 50), now), 'online');
eq("the header's freshness: a pgvigil.yaml instance 50 min after its newest collection is offline (the 30-minute rule)",
  headerFreshness({ last_collect_at: ago(50), coll_stale: 0 }, now), 'offline');
eq("the header's freshness: a pgvigil.yaml instance 5 min after its newest collection, a collection stale, is stale",
  headerFreshness({ last_collect_at: ago(5), coll_stale: 1 }, now), 'stale');
eq("the header's freshness: no collection ever is awaiting", headerFreshness({ coll_stale: 0 }, now), 'awaiting');
eq("an instance whose collector is not known yet: 'a remote collector of site <s>'", asOfLine(remote(5, 6, { collector: null })),
  `as of ${clock(ago(5))} (a remote collector of site site1, a bundle every 5 min)`);
// review C S4: the silence is the hub's clock - when it last LOADED a bundle (loaded_at) - never the site's as_of: a site
// clock 3 h behind whose bundle the hub loaded 5 minutes ago is not quiet
eq('a site clock 3 h behind, its bundle loaded 5 min ago: online, not quiet',
  freshness(remote(180, 185, { loaded_at: ago(5) }), now), 'online');
eq('and no silence line', quietLine(remote(180, 185, { loaded_at: ago(5) }), now), '');
eq('a bundle loaded 3 h ago on an hourly site: quiet', freshness(remote(185, 190, { loaded_at: ago(180) }), now), 'offline');
// review C N4: the silence counts the bundle interval too: an hourly bundle on a site whose expected_every says 5 min is
// quiet only past 2 x 60 min
eq('an hourly bundle (expected_every 5 min) loaded 50 min ago: not quiet',
  freshness(remote(50, 55, { loaded_at: ago(50), interval_secs: 3600, expected_every_secs: 300 }), now), 'online');
// review C S5: an 'as of' that is not today names its day
const yesterday = new Date(now - 20 * 3600000);
const dayWords = yesterday.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
eq("an 'as of' 20 h back names its day", asOfLine(remote(20 * 60, 20 * 60 + 5, { loaded_at: ago(5) }), now).includes(dayWords), true);
process.exit(bad ? 1 : 0);
