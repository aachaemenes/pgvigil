// Unit tests of requestend.ts (a queued request's end: stateWords, asRun) for every end state, with the repository's
// '' and with null for words a state lacks. Node, no DOM: the module is bundled by esbuild (web's own) and its path
// given as the argument; ui.ts adds document and window listeners when it loads, so these are stubbed first.
//   web/node_modules/.bin/esbuild web/src/requestend.ts --bundle --format=esm --platform=neutral --main-fields=module,main --outfile=<tmp>/requestend.mjs
//   node web/src/requestend.test.mjs <tmp>/requestend.mjs
// Every row prints 'ok' or 'FAIL'; the exit is 1 when any failed. No time field is given, so no row reads the locale.
const noop = () => {};
globalThis.document ??= { addEventListener: noop, removeEventListener: noop, querySelector: () => null, documentElement: { dataset: {} } };
globalThis.matchMedia ??= () => ({ matches: false, addEventListener: noop, removeEventListener: noop });
globalThis.devicePixelRatio ??= 1;
globalThis.window ??= { addEventListener: noop, removeEventListener: noop, dispatchEvent: noop, matchMedia: globalThis.matchMedia };
const m = await import(new URL(process.argv[2], 'file://' + process.cwd() + '/').href);
const { stateWords, asRun } = m;
let bad = 0;
const eq = (what, got, want) => {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g === w) console.log('ok   ' + what); else { bad++; console.log(`FAIL ${what}: got ${g}, want ${w}`); }
};
const end = (state, x = {}) => ({ request_id: 7, state, ...x });

// stateWords: the status line's words before ' Request <n>.'
eq('waiting, no time', stateWords(end('waiting')), 'Waiting for the collector to take it.');
eq('running on a host, no time', stateWords(end('running', { taken_host: 'h1' })), 'Running on h1.');
eq('done, no host, no time', stateWords(end('done')), 'Ran on the collector.');
eq('done on a host', stateWords(end('done', { taken_host: 'h1', refusal: '' })), 'Ran on h1.');
eq('cancelled while it ran (the worker\'s words, no stop)', stateWords(end('cancelled', { outcome: 'cancelled by its asker while it ran', refusal: '' })), 'cancelled by its asker while it ran.');
eq('cancelled before a collector took it', stateWords(end('cancelled', { outcome: 'cancelled before a collector took it', refusal: null })), 'cancelled before a collector took it.');
eq('cancelled, outcome \'\'', stateWords(end('cancelled', { outcome: '', refusal: '' })), 'Cancelled.');
eq('cancelled, no outcome', stateWords(end('cancelled')), 'Cancelled.');
eq('refused, its words', stateWords(end('refused', { refusal: 'timeout_secs is 1 to 60', outcome: '' })), 'timeout_secs is 1 to 60.');
eq('refused, its words with a stop', stateWords(end('refused', { refusal: 'No right.', outcome: '' })), 'No right.');
eq('refused, refusal \'\'', stateWords(end('refused', { refusal: '', outcome: '' })), 'Refused.');
eq('failed, the driver\'s words, refusal \'\'', stateWords(end('failed', { outcome: 'mssql: Valid filter types are: session, program, database, login, host', refusal: '' })),
  'mssql: Valid filter types are: session, program, database, login, host.');
eq('failed, outcome \'\'', stateWords(end('failed', { outcome: '', refusal: '' })), 'failed.');
eq('expired, no outcome (the sweep\'s NULL)', stateWords(end('expired', { outcome: null, refusal: null })), 'No collector took it before it expired: it was never run.');
eq('expired, outcome \'\'', stateWords(end('expired', { outcome: '' })), 'No collector took it before it expired: it was never run.');
eq('lost, its words', stateWords(end('lost', { outcome: 'the collector on h1 stopped while running it' })), 'the collector on h1 stopped while running it.');
eq('lost, no outcome', stateWords(end('lost')), 'The collector stopped while running it: it may or may not have run.');
eq('an unknown state, outcome \'\'', stateWords(end('odd', { outcome: '' })), 'odd.');
eq('words ending in ? kept', stateWords(end('failed', { outcome: 'which database?' })), 'which database?');
eq('words ending in ! kept', stateWords(end('failed', { outcome: 'stop!' })), 'stop!');
eq('trailing blanks trimmed, the stop kept', stateWords(end('failed', { outcome: 'it broke.  ' })), 'it broke.');

// asRun: the end as the direct reply's one run (resultView draws it)
const run = (e) => asRun(e, 'i1', 'sqlserver');
const pick = (r) => ({ outcome: r.outcome, error: r.error ?? null, rows: r.rows, duration_ms: r.duration_ms, declined: r.declined ?? null });
eq('failed, refusal \'\': its words are the error', pick(run(end('failed', { outcome: 'boom', refusal: '', rows: 0, duration_ms: 12 }))),
  { outcome: 'failed', error: 'boom', rows: 0, duration_ms: 12, declined: null });
eq('refused: the refusal is the error', pick(run(end('refused', { refusal: 'no right', outcome: '' }))),
  { outcome: 'refused', error: 'no right', rows: 0, duration_ms: 0, declined: null });
eq('failed, no words but the result\'s', pick(run(end('failed', { refusal: null, outcome: null, result: { error: 'e1', duration_ms: 50 } }))),
  { outcome: 'failed', error: 'e1', rows: 0, duration_ms: 50, declined: null });
eq('failed, every word empty: no error', pick(run(end('failed', { refusal: '', outcome: '', result: { error: '' } }))),
  { outcome: 'failed', error: null, rows: 0, duration_ms: 0, declined: null });
eq('done, result error \'\': no error', pick(run(end('done', { refusal: '', outcome: 'sp_Blitz on i1: 1 set(s), 15 row(s)', rows: 15, duration_ms: 8173, result: { error: '', sets: [] } }))),
  { outcome: 'done', error: null, rows: 15, duration_ms: 8173, declined: null });
eq('done, the result\'s own error kept', pick(run(end('done', { refusal: '', outcome: 'x', result: { error: 'a warning', sets: [] } }))),
  { outcome: 'done', error: 'a warning', rows: 0, duration_ms: 0, declined: null });
eq('declined (stored failed): its flag and words', pick(run(end('failed', { refusal: '', outcome: 'No valid databases found to process.', result: { declined: true } }))),
  { outcome: 'failed', error: 'No valid databases found to process.', rows: 0, duration_ms: 0, declined: true });
const set = { columns: ['a'], rows: [[1]], truncated: true };
eq('a cut result: the sets\' own cut mark dropped', run(end('done', { result: { cut: 'cut at 1 rows: queue mode keeps 8 MB', sets: [set] } })).sets.map(s => s.truncated), [false]);
eq('no cut: the set\'s mark kept', run(end('done', { result: { sets: [set] } })).sets.map(s => s.truncated), [true]);
eq('the instance and engine as given', (({ instance, engine }) => ({ instance, engine }))(run(end('done'))), { instance: 'i1', engine: 'sqlserver' });

console.log(bad ? `requestend: ${bad} FAIL` : 'requestend: every row ok');
process.exit(bad ? 1 : 0);
