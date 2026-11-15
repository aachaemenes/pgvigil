// Unit tests of verdict.ts's verdict() (the instance card's state, sentence, reasons, notes). Node, no DOM: the module
// is bundled by esbuild (web's own) and its path given as the argument; the bundle's menus add document and window
// listeners when it loads and uPlot reads the pixel ratio, so these are stubbed first (no-op listeners).
//   web/node_modules/.bin/esbuild web/src/verdict.ts --bundle --format=esm --platform=neutral --main-fields=module,main --outfile=<tmp>/verdict.mjs
//   node web/src/verdict.test.mjs <tmp>/verdict.mjs
// scripts/proof-verdict.sh runs both first. Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed.
const noop = () => {};
globalThis.document ??= { addEventListener: noop, removeEventListener: noop, querySelector: () => null, documentElement: { dataset: {} } };
globalThis.matchMedia ??= () => ({ matches: false, addEventListener: noop, removeEventListener: noop });
globalThis.devicePixelRatio ??= 1;
globalThis.window ??= { addEventListener: noop, removeEventListener: noop, dispatchEvent: noop, matchMedia: globalThis.matchMedia };
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { verdict } = m;
let bad = 0;
const eq = (what, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};

const now = Date.parse('2026-11-14T18:00:00Z');
const ago = min => new Date(now - min * 60000).toISOString();
const cell = (level, text) => ({ level, n: 1, detail: [], text });
const item = (key, level) => ({ key, label: key, level, cell: cell(level, `${key} cell`), target: { tab: key } });
// a band as instheader.ts instBand returns it: its items worst first, level their worst, offline its own flag
const band = (items, extra = {}) => ({ level: Math.max(0, ...items.map(i => i.level)), word: '', cls: '', reasons: [], items, acked: [], offline: false, cells: {}, ...extra });
const pgRow = { instance_id: 1, name: 'x1', engine: 'postgres' };
const msRow = { instance_id: 2, name: 'x2', engine: 'sqlserver' };

// late collections: counted in the sentence whatever the band holds (the design pass's part 2 #1), named in a note from
// Snapshot Age's own lines, never counted twice; a Snapshot Age acknowledged keeps them out of the sentence and the state
const snap = (...names) => ({ level: 1, n: names.length, detail: names.map(x => `${x}: stale, the last run 2026-11-14 14:00 UTC`) });
const judged = { full: { level: 0, n: 0, detail: [] } };
{
  const v = verdict(pgRow, { coll_stale: 1, last_collect_at: ago(1) }, now, band([item('snapshot', 1)], { cells: { ...judged, snapshot: snap('activity') } }), 'stale');
  eq('stale + a warning: the state', v.state, 'warning');
  eq('stale + a warning: the sentence names its first reason and the late collection',
    v.sentence, "x1 needs a look: some of its data is out of date; 1 of pgvigil's collections of it is late.");
  eq('stale + a warning: the late collection named in a note, its count not said again', v.notes, ['Late: activity.']);
}
{
  const v = verdict(pgRow, { coll_stale: 2, last_collect_at: ago(1) }, now, band([item('disk', 2), item('snapshot', 1)], { cells: { snapshot: snap('activity', 'dbstats') } }), 'stale');
  eq('stale + a critical: the state', v.state, 'problem');
  eq('stale + a critical: the sentence', v.sentence, "x1 has a problem: a drive is nearly full and 1 more; 2 of pgvigil's collections of it are late.");
  eq('stale + a critical: both named', v.notes, ['Late: activity, dbstats.']);
}
{
  const v = verdict(pgRow, { coll_stale: 3, last_collect_at: ago(1) }, now, band([]), 'stale');
  eq('stale alone (Snapshot Age not read): warning', [v.state, v.sentence], ['warning', "x1 needs a look: 3 of pgvigil's collections of it are late."]);
}
{
  const v = verdict(pgRow, { coll_stale: 1, last_collect_at: ago(1) }, now, band([], { acked: [item('snapshot', 1)], cells: { ...judged, snapshot: snap('activity') } }), 'stale');
  eq('stale, Snapshot Age acknowledged: OK as the band, the late collection in the notes',
    [v.state, v.sentence, v.notes], ['ok', 'x1 looks healthy: nothing needs attention.', ["1 of pgvigil's collections of it is late (Snapshot Age is acknowledged).", 'Late: activity.']]);
}
{
  const v = verdict(pgRow, { coll_stale: 1, last_collect_at: ago(1) }, now, band([item('disk', 1)], { acked: [item('snapshot', 1)], cells: { ...judged, snapshot: snap('activity') } }), 'stale');
  eq('stale, Snapshot Age acknowledged + a warning: no late clause in the sentence', v.sentence, 'x1 needs a look: a drive is filling up.');
}
// the other states
{
  const v = verdict(pgRow, { coll_stale: 0, last_collect_at: ago(1) }, now, band([], { cells: judged }), 'online');
  eq('online, nothing: OK', [v.state, v.sentence, v.notes], ['ok', 'x1 looks healthy: nothing needs attention.', []]);
}
{
  const v = verdict(msRow, { coll_stale: 0, last_collect_at: ago(1) }, now, band([item('disk', 1)]), 'online');
  eq('online + a warning: its phrase', [v.state, v.sentence], ['warning', 'x2 needs a look: a drive is filling up.']);
}
{
  eq('Deadlocks: each engine its own words', [verdict(pgRow, {}, now, band([item('dbhealth', 1)]), 'online').sentence, verdict(msRow, {}, now, band([item('dbhealth', 1)]), 'online').sentence],
    ['x1 needs a look: deadlocks or checksum failures were seen.', 'x2 needs a look: deadlocks or long blocking were seen.']);
}
// an all-clear only where checks were read (the review's blocker 2)
{
  const rf = { level: 0, n: 0, detail: [], none: true, text: 'read failed' }, ny = { level: 0, n: 0, detail: [], none: true, text: 'not yet' }, na = { level: 0, n: 0, detail: [], none: true, text: 'n/a' };
  const all = (c, extra = {}) => ({ disk: c, full: c, snapshot: c, errors: c, agent: na, ...extra });
  const v1 = verdict(msRow, { coll_stale: 0, last_collect_at: ago(1) }, now, band([], { cells: all(rf) }), 'online');
  eq('every read failed: OK as the header, nothing judged said', [v1.state, v1.sentence], ['ok', 'x2: pgvigil could not read its checks just now, so nothing is judged.']);
  const v2 = verdict(msRow, { coll_stale: 0, last_collect_at: ago(1) }, now, band([], { cells: { ...all(rf), full: { level: 0, n: 0, detail: [] }, snapshot: { level: 0, n: 0, detail: [] } } }), 'online');
  eq('some reads failed: the count said', v2.sentence, 'x2: no check pgvigil could read is failing; 2 of its checks could not be read just now.');
  const v3 = verdict(pgRow, { coll_stale: 0, last_collect_at: ago(1) }, now, band([], { cells: all(ny) }), 'online');
  eq('no result yet: nothing judged said', v3.sentence, 'x1: none of its checks has a result yet, so nothing is judged.');
}
{
  const v = verdict(pgRow, { coll_stale: 0 }, now, band([]), 'awaiting');
  eq('never read: unread', [v.state, v.sentence], ['unread', 'pgvigil has not read x1 yet.']);
}
{
  const v = verdict(pgRow, undefined, now, band([]), 'awaiting');
  eq('no live read: unread, said', [v.state, v.sentence], ['unread', 'pgvigil has not read x1 yet: no live read of it answered.']);
}
{
  const v = verdict(pgRow, { coll_stale: 0 }, now, band([item('snapshot', 1)]), 'awaiting');
  eq('awaiting + an older reason: warning and its note', [v.state, v.notes], ['warning', ['No collection of it has ended well yet: these come from older reads.']]);
}
{
  const v = verdict(pgRow, { coll_stale: 0, last_collect_at: ago(40) }, now, band([item('snapshot', 1)], { level: 2, offline: true }), 'offline');
  eq('offline: problem, the minutes, offline its first reason', [v.state, v.sentence, v.reasons.map(r => r.key)], ['problem', 'pgvigil has not read x1 for 40 minutes.', ['offline', 'snapshot']]);
  const d = verdict(pgRow, { coll_stale: 0, last_collect_at: ago(3 * 1440 + 125) }, now, band([], { level: 2, offline: true }), 'offline');
  eq('offline for days: in days', d.sentence, 'pgvigil has not read x1 for 3 days.');
}
// not judged: the Summary's 'no sample' cells of the row's engine, never 'n/a'
{
  const cells = { disk: { level: 0, n: 0, detail: [], none: true, text: 'no sample' }, agent: { level: 0, n: 0, detail: [], none: true, text: 'n/a' }, full: { level: 0, n: 0, detail: [] } };
  const v = verdict(pgRow, { coll_stale: 0, last_collect_at: ago(1) }, now, band([], { cells }), 'online');
  eq('not judged: no sample only', v.notJudged.map(g => g.key), ['disk']);
}

console.log(`verdict unit: ${bad} FAIL`);
process.exit(bad ? 1 : 0);
