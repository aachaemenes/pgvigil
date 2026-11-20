// Unit tests of settings_model.ts (ST5b: the model the Settings panel and the tree's Pause/Resume Collections and
// Configure Schedule share). Node, no DOM: the module is compiled by esbuild (web's own) and its path given as the
// argument.
//   web/node_modules/.bin/esbuild web/src/settings_model.ts --format=esm --outfile=<tmp>/settings_model.mjs
//   node web/src/settings_model.test.mjs <tmp>/settings_model.mjs
// scripts/proof-admin-instance-settings.sh part U runs it after the web build. Every row prints 'ok' or 'FAIL'; the exit is 1
// when any failed. The rows check that a dialog's Save keeps what it does not touch.
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
let bad = 0, n = 0;
// the objects compared with their keys sorted (the stored jsonb has no key order)
const canon = v => Array.isArray(v) ? v.map(canon) : v && typeof v === 'object'
  ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canon(v[k])])) : v;
const eq = (what, f) => {
  n++;
  let got, want;
  try { [got, want] = f(); } catch (e) { bad++; console.log(`FAIL ${what}: ${e.message}`); return; }
  const g = JSON.stringify(canon(got)), w = JSON.stringify(canon(want));
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
const fn = name => { if (typeof m[name] !== 'function') throw new Error(`${name} is not a function of the model`); return m[name]; };

const th = { redo_queue_kb: 1024, full_backup_hours: 0.5, backup_exclude: ['tmp%'] };
const cat = { mssql_jobs: { default_s: 300, builtin_s: 300 }, mssql_ag: { default_s: 60, builtin_s: 60 }, mssql_backups: { default_s: 0, builtin_s: 3600 } };
const full = { schedules: { mssql_jobs: 600, mssql_ag: 120 }, query_text: 'none', thresholds: th };

// M3: a pause and a resume through the dialog's decision keep the thresholds, query_text and the untouched schedule
eq('a pause keeps thresholds, query_text and the other schedule; its own 600 s kept', () => [
  fn('pauseResumeOf')(full, { mssql_jobs: false }, cat, { mssql_jobs: 600, mssql_ag: 120 }),
  { schedules: { mssql_jobs: 0, mssql_ag: 120 }, paused: { mssql_jobs: 600 }, query_text: 'none', thresholds: th }]);
eq('the resume writes the 600 s back and takes the paused key away', () => [
  fn('pauseResumeOf')({ schedules: { mssql_jobs: 0, mssql_ag: 120 }, paused: { mssql_jobs: 600 }, query_text: 'none', thresholds: th },
    { mssql_jobs: true }, cat, { mssql_jobs: 0, mssql_ag: 120 }), full]);
eq('a tick left as it was changes nothing', () => [fn('pauseResumeOf')(full, { mssql_ag: true }, cat, { mssql_jobs: 600, mssql_ag: 120 }), full]);
eq('a resume of a collection off for every instance by the file gives its built-in interval', () => [
  fn('pauseResumeOf')({ query_text: 'full' }, { mssql_backups: true }, cat, { mssql_backups: 0 }), { schedules: { mssql_backups: 3600 }, query_text: 'full' }]);
// m2: off in the panel AND off by the file's global line: the resume gives the built-in interval, never 'default' (off)
eq('m2: a resume of a collection off here and in the file gives its built-in interval', () => [
  fn('pauseResumeOf')({ schedules: { mssql_backups: 0 } }, { mssql_backups: true }, cat, { mssql_backups: 0 }), { schedules: { mssql_backups: 3600 } }]);
eq('a resume of a collection off here alone takes its key away (its default runs)', () => [
  fn('pauseResumeOf')({ schedules: { mssql_jobs: 0 }, thresholds: th }, { mssql_jobs: true }, cat, { mssql_jobs: 0 }), { thresholds: th }]);
// m1: a pause of a collection already paused keeps the own interval (serve's interval may still say it runs)
eq('m1: pausedOf on a paused collection keeps its own 600 s', () => [
  m.pausedOf({ schedules: { mssql_jobs: 0 }, paused: { mssql_jobs: 600 } }, 'mssql_jobs'), { schedules: { mssql_jobs: 0 }, paused: { mssql_jobs: 600 } }]);
eq('m1: a stale running interval does not undo a pause (the stored 0 is read first)', () => [
  fn('pauseResumeOf')({ schedules: { mssql_jobs: 0 }, paused: { mssql_jobs: 600 } }, { mssql_jobs: false }, cat, { mssql_jobs: 600 }),
  { schedules: { mssql_jobs: 0 }, paused: { mssql_jobs: 600 } }]);
eq('offOf: an own value first, else the interval in force', () => [
  [fn('offOf')({ schedules: { a: 0 } }, 'a', 600), fn('offOf')({ schedules: { a: 60 } }, 'a', 0), fn('offOf')({}, 'a', 0), fn('offOf')({}, 'a', 60), fn('offOf')({}, 'a', null)],
  [true, false, true, false, false]]);
eq('fileOffOf: off by the file = default 0 with a built-in interval (an opt-in has none)', () => [
  [fn('fileOffOf')(cat.mssql_backups), fn('fileOffOf')(cat.mssql_jobs), fn('fileOffOf')({ default_s: 0, builtin_s: 0 }), fn('fileOffOf')(undefined)],
  [true, false, false, false]]);
eq('a pause of a collection with no own interval keeps nothing', () => [m.pausedOf({ query_text: 'none' }, 'mssql_jobs'), { schedules: { mssql_jobs: 0 }, query_text: 'none' }]);
// the panel's thresholds: a key taken away leaves the others; none left takes the key away
eq('withThresholds: a key taken away leaves the others and query_text', () => [
  m.withThresholds({ thresholds: th, query_text: 'none' }, { redo_queue_kb: 1024 }), { thresholds: { redo_queue_kb: 1024 }, query_text: 'none' }]);
eq('withThresholds: none left takes the key away', () => [m.withThresholds({ thresholds: th, schedules: { mssql_jobs: 60 } }, {}), { schedules: { mssql_jobs: 60 } }]);
eq('withSchedule: a value set by hand ends that pause alone', () => [
  m.withSchedule({ schedules: { a: 0, b: 0 }, paused: { a: 600, b: 900 } }, 'a', 120), { schedules: { a: 120, b: 0 }, paused: { b: 900 } }]);
eq('goDuration never writes d; parseEvery and checkEvery', () => [
  [m.goDuration(86400), m.goDuration(90), m.goDuration(600), m.parseEvery('2d'), m.parseEvery('5'), m.parseEvery('off'), m.parseEvery('x'), m.checkEvery(30, 60, 2592000)],
  ['24h', '90s', '10m', 172800, 300, 0, null, 'an interval set here is 1m or more']]);
console.log(`${n - bad} of ${n} ok`);
process.exit(bad ? 1 : 0);
