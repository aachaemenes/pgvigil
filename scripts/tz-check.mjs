// The zone arithmetic of web/src/tz.ts and router.ts's periodStart, checked offline at the edges a browser run would
// need a clock change to reach (proof-frame.sh bundles the two files with esbuild and passes the bundle):
//   node scripts/tz-check.mjs <bundle.mjs>
// Each line is one wall-clock time in one zone and the instant it must be. A time a daylight-saving jump skips lands on
// the far side of the jump; a time a fall-back repeats may be either of its two passes (tz.ts says so) and is checked as
// one of them. Prints 'ok' or 'FAIL' per check and exits 1 when one failed.
const store = new Map();
globalThis.localStorage = { getItem: k => store.has(k) ? store.get(k) : null, setItem: (k, v) => { store.set(k, String(v)); } };
const tz = await import(new URL(process.argv[2], `file://${process.cwd()}/`).href);
let failed = 0, n = 0;
const check = (name, got, ...want) => { n++; const ok = want.includes(got); if (!ok) failed++; console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}: ${got}${ok ? '' : ' (wanted ' + want.join(' or ') + ')'}`); };
const at = (zone, y, mo, d, h = 0, mi = 0) => { tz.setZone(zone); return tz.zonedToUtc(y, mo, d, h, mi).toISOString(); };
const clock = (zone, iso) => { tz.setZone(zone); const p = tz.parts(new Date(iso)); return `${p.d} ${String(p.h).padStart(2, '0')}:${String(p.mi).padStart(2, '0')}`; };

// America/New_York 2026: clocks jump 02:00 -> 03:00 on 8 March, fall back 02:00 -> 01:00 on 1 November
check('New York, 01:30 before the jump', at('America/New_York', 2026, 3, 8, 1, 30), '2026-03-08T06:30:00.000Z');
check('New York, 02:30 inside the jump lands at 03:30', at('America/New_York', 2026, 3, 8, 2, 30), '2026-03-08T07:30:00.000Z');
check('New York, 01:30 of the repeated hour', at('America/New_York', 2026, 11, 1, 1, 30), '2026-11-01T05:30:00.000Z', '2026-11-01T06:30:00.000Z');
check('New York, midnight of the 25-hour day', at('America/New_York', 2026, 11, 1), '2026-11-01T04:00:00.000Z');
check('New York, midnight after it', at('America/New_York', 2026, 11, 2), '2026-11-02T05:00:00.000Z');
// Australia/Sydney 2026 (east of UTC, the southern year): back 03:00 -> 02:00 on 5 April, jump 02:00 -> 03:00 on 4 October
check('Sydney, 02:30 of the repeated hour', at('Australia/Sydney', 2026, 4, 5, 2, 30), '2026-04-04T15:30:00.000Z', '2026-04-04T16:30:00.000Z');
check('Sydney, 02:30 inside the jump lands at 03:30', at('Australia/Sydney', 2026, 10, 4, 2, 30), '2026-10-03T16:30:00.000Z');
// Australia/Lord_Howe: a half-hour jump, 02:00 -> 02:30 on 4 October
check('Lord Howe, 02:15 inside the half-hour jump lands at 02:45', clock('Australia/Lord_Howe', at('Australia/Lord_Howe', 2026, 10, 4, 2, 15)), '4 02:45');
// a jump at midnight: the day starts at 01:00
check('Santiago, midnight of 6 September does not exist: 01:00', clock('America/Santiago', at('America/Santiago', 2026, 9, 6)), '6 01:00');
check('Cairo, midnight of 24 April does not exist: 01:00', clock('Africa/Cairo', at('Africa/Cairo', 2026, 4, 24)), '24 01:00');
// offsets that are not whole hours
tz.setZone('Asia/Kathmandu'); check('Kathmandu offset', tz.offsetLabel(new Date('2026-06-01T00:00:00Z')), 'UTC+05:45');
tz.setZone('Asia/Kolkata'); check('Kolkata offset', tz.offsetLabel(new Date('2026-06-01T00:00:00Z')), 'UTC+05:30');
tz.setZone('Asia/Kathmandu'); check('Kathmandu, a typed 10:00', tz.fromInput('2026-06-01T10:00').toISOString(), '2026-06-01T04:15:00.000Z');
check('Kathmandu, the same instant back in the input', tz.toInput(new Date('2026-06-01T04:15:00.000Z')), '2026-06-01T10:00');
tz.setZone('America/Los_Angeles'); check('Los Angeles offset in winter and in summer', tz.offsetLabel(new Date('2026-01-15T12:00:00Z')) + ' ' + tz.offsetLabel(new Date('2026-07-15T12:00:00Z')), 'UTC-08:00 UTC-07:00');
// the calendar periods (UTC keeps the arithmetic plain to read)
tz.setZone('UTC');
const jan = new Date('2026-01-15T12:00:00Z'), apr = new Date('2026-04-01T09:00:00Z');   // 1 April 2026 is a Wednesday
check('today', tz.periodStart('today', jan).toISOString(), '2026-01-15T00:00:00.000Z');
check('yesterday', tz.periodStart('today', jan, 1).toISOString(), '2026-01-14T00:00:00.000Z');
check('month to date', tz.periodStart('mtd', jan).toISOString(), '2026-01-01T00:00:00.000Z');
check("January's previous month is December of the year before", tz.periodStart('mtd', jan, 1).toISOString(), '2025-12-01T00:00:00.000Z');
check('a week whose Monday lies in the month before', tz.periodStart('wtd', apr).toISOString(), '2026-03-30T00:00:00.000Z');
check('the week before it', tz.periodStart('wtd', apr, 1).toISOString(), '2026-03-23T00:00:00.000Z');
// a period on a zone's own clock: Tokyo's day starts at 15:00 UTC of the day before
tz.setZone('Asia/Tokyo'); check('today in Tokyo', tz.periodStart('today', jan).toISOString(), '2026-01-14T15:00:00.000Z');
// the server's longest window: exactly 31 days passes, a millisecond more is cut at its start
const t1 = new Date('2026-03-01T00:00:00Z');
check('31 days pass', tz.capRange(new Date(t1.getTime() - tz.MAX_RANGE_MS), t1).from.toISOString(), '2026-01-29T00:00:00.000Z');
check('31 days and a millisecond are cut', tz.capRange(new Date(t1.getTime() - tz.MAX_RANGE_MS - 1), t1).from.toISOString(), '2026-01-29T00:00:00.000Z');
// a name the browser does not know falls back to its own zone
tz.setZone('Not/AZone'); check('an unknown zone', tz.zoneChoice(), 'local');
if (failed) { console.log(`FAIL ${failed} of ${n} zone checks`); process.exit(1); }
console.log(`tz: ${n} checks as expected`);
