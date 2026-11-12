// The Query Store page of a SQL Server instance (task 129; DBA Dash's Query Store Top Queries, Forced Plans and
// QS options grids, Darling's Query Store tab): five views of what the mssql_querystore collection read from each
// database's store (hourly): Top (the window's queries by duration, CPU, reads, memory grant, waits or executions;
// a query opens its plans over time with a .sqlplan download per plan; under it PerformanceMonitor's compare with
// an earlier window), Regressed (PerformanceMonitor's regressions and pgvigil's duration test, per query, against a
// baseline: the 7 days before by default), Forced plans (with the failure count and reason), Tuning (the automatic
// tuning recommendations and options) and Store state (actual against desired, the read-only reason, size against
// max). Data from /api/mssql/querystore and its two detail routes.
//
// The view, the sort, the database and Regressed's baseline ride the page's hash (qs=, qo=, qdb=, qb=), read here as
// stmt_filter.ts reads its own; the lead's wiring keeps them on the tab's own links (router.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { qsOverlay, qsStrip } from './mssql_queries';
import { Ctx, rangeLabel, window_ } from './router';
import { sqlCell } from './sqlview';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlQueryStoreTab = 'mssqlqs';

type Parts = 'state' | 'totals' | 'series' | 'top' | 'regressed' | 'regressed_skipped' | 'forced' | 'tuning' | 'tuning_options' | 'checks';
type QS = Partial<Record<Parts, Table | null>>;   // the page asks for its view's parts: the others are absent

const views: [string, string][] = [['top', 'Top'], ['regressed', 'Regressed'], ['forced', 'Forced plans'], ['tuning', 'Tuning'], ['state', 'Store state']];
const orders: [string, string, string][] = [
  ['duration', 'duration', 'duration_ms'], ['cpu', 'CPU', 'cpu_ms'], ['reads', 'logical reads', 'logical_reads'],
  ['memory', 'memory grant', ''], ['waits', 'waits', 'wait_ms'], ['executions', 'executions', 'executions'],
];

const text = (v: unknown) => v == null ? '' : String(v);
const dur = (v: unknown) => {
  if (v == null || v === '') return '';
  const n = Number(v), a = Math.abs(n);
  return a >= 60000 ? fmtNum(n / 60000) + ' min' : a >= 1000 ? fmtNum(n / 1000) + ' s' : fmtNum(n) + ' ms';
};
const mb = (v: unknown) => v == null || v === '' ? '' : fmtNum(v) + ' MB';
const times = (v: unknown) => v == null || v === '' ? '' : fmtNum(v) + ' x';
const yes = (v: unknown) => v == null ? '' : v ? 'yes' : 'no';
const sevBadge = (v: unknown) => badge(text(v), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const stmt = (v: unknown) => v == null || v === '' ? '(no text stored)' : sqlCell(v);
// a tinted cell (class 'status warn' / 'status crit') has no padding of its own: the stylesheet gives it to the
// cell's .cell-link, so a tinted cell's content rides one (bare text sat against the cell's top and side)
const tinted = (s: string | Node) => el('span', { class: 'cell-link' }, s);

function hashQS(): URLSearchParams { return new URLSearchParams(location.hash.split('?')[1] ?? ''); }

// hrefWith: the page's own address with one of its parameters changed (every other parameter kept).
function hrefWith(change: (q: URLSearchParams) => void): string {
  const [path, qs] = location.hash.split('?');
  const q = new URLSearchParams(qs ?? '');
  change(q);
  return path + '?' + q.toString();
}

// a link of the page redraws it: the focus goes back to the control that was used (keyboard users)
let refocus = '';
function keepFocus(e: HTMLElement): void {
  refocus = '';
  let tries = 0;
  const go = () => { if (e.isConnected) e.focus(); else if (++tries < 60) requestAnimationFrame(go); };
  requestAnimationFrame(go);
}

// switcher: a row of links that set one hash parameter (the views, the sort).
function switcher(label: string, param: string, items: [string, string][], current: string, first: string): HTMLElement {
  return el('div', { class: 'subtabs', role: 'group', 'aria-label': label },
    el('span', { class: 'meta', style: 'align-self:center' }, label),
    ...items.map(([k, l]) => {
      const a = el('a', { href: hrefWith(q => { if (k === first) q.delete(param); else q.set(param, k); }), id: `qs-${param}-${k}`,
        class: k === current ? 'on' : '', ...(k === current ? { 'aria-current': 'true' } : {}) }, l);
      if (refocus === a.id) keepFocus(a);
      a.addEventListener('click', () => { refocus = a.id; });
      return a;
    }));
}

// pivot: (snapshot_at, key, value) rows into one row per interval with a column per key.
function pivot(rows: Row[], keyCol: string, valCol: string): { rows: Row[]; keys: string[] } {
  const keys: string[] = [];
  const by = new Map<string, Row>();
  for (const r of rows) {
    const k = 'plan ' + text(r[keyCol]), t = text(r.snapshot_at);
    if (!keys.includes(k)) keys.push(k);
    if (!by.has(t)) by.set(t, { snapshot_at: r.snapshot_at });
    by.get(t)![k] = r[valCol];
  }
  return { rows: [...by.values()].sort((a, b) => Date.parse(text(a.snapshot_at)) - Date.parse(text(b.snapshot_at))), keys };
}

// numbersOf: the table behind a chart (a chart alone tells a screen reader nothing).
function numbersOf(rows: Row[], cols: Col[]): HTMLElement {
  return el('details', {}, el('summary', {}, 'The charts\' numbers as a table'), grid(rows, cols, 'No interval in this range.'));
}

function openButton(label: string, name: string, onOpen: () => void): HTMLElement {
  const b = el('button', { type: 'button', class: 'link', 'aria-label': `${label}: ${name}` }, label);
  b.addEventListener('click', onOpen);
  return b;
}

function detailPanel(title: string): { box: HTMLElement; show: (...kids: (Node | string)[]) => void } {
  const box = el('section', { class: 'detail', 'aria-live': 'polite' });
  return { box, show: (...kids) => { box.replaceChildren(el('h3', { tabindex: '-1' }, title), ...kids); (box.firstElementChild as HTMLElement).focus(); } };
}

// planFile: a plan's showplan XML as a download, or why there is none.
function planFile(ctx: Ctx, db: unknown, planId: unknown, state: unknown, note: unknown, inStore: unknown): HTMLElement | string {
  if (state === 'stored') {
    const q = new URLSearchParams({ instance: String(ctx.instance), db: text(db), plan: text(planId) });
    return el('a', { href: `/api/mssql/querystore/plan.sqlplan?${q}`, download: '', 'aria-label': `Download .sqlplan of plan ${text(planId)}` }, 'Download .sqlplan');
  }
  if (state === 'policy') return 'not stored: this instance\'s query_text policy is not "full"';
  if (state === 'too large') return text(note) || 'not stored: the plan is too large';
  return inStore === false ? 'the plan is no longer in the store' : 'not read yet (read when the plan is next among an interval\'s top plans)';
}

// ---- one query: its text, its plans in the window, their line per interval

let opening = 0;   // the newest Open wins: an older answer that arrives late is dropped

async function openQuery(ctx: Ctx, row: Row, panel: ReturnType<typeof detailPanel>) {
  const mine = ++opening;
  panel.show(el('p', { class: 'meta' }, `Reading query ${text(row.query_id)} of ${text(row.database_name)} ...`));
  try {
    const d = await get<Record<'query' | 'plans' | 'series', Table | null>>('mssql/querystore/query', {
      instance: ctx.instance, ...window_(ctx), db: text(row.database_name), query: text(row.query_id), hash: text(row.query_hash) });
    if (mine !== opening) return;
    const q = rowsOf(d.query)[0], plans = rowsOf(d.plans), series = rowsOf(d.series);
    const cols: Col[] = [
      { key: 'plan_id', label: 'plan', num: true, fmt: v => text(v) },
      { key: 'forced', fmt: (v, r) => v ? badge(`forced (${text(r.forcing_type).toLowerCase() || 'manual'})`, Number(r.force_failure_count) > 0 ? 'warn' : 'ok') : '' },
      { key: 'force_failure_count', label: 'force failures', num: true, fmt: (v, r) => r.forced ? fmtNum(v ?? 0) : '' },
      { key: 'force_failure_reason', label: 'last force failure' },
      { key: 'executions', num: true }, { key: 'failed', label: 'aborted or failed', num: true },
      { key: 'avg_duration_ms', label: 'avg duration', num: true, fmt: dur }, { key: 'max_duration_ms', label: 'max duration', num: true, fmt: dur },
      { key: 'avg_cpu_ms', label: 'avg CPU', num: true, fmt: dur },
      { key: 'avg_logical_reads', label: 'avg logical reads', num: true },
      { key: 'max_memory_mb', label: 'max memory grant', num: true, fmt: mb },
      { key: 'wait_ms', label: 'wait time', num: true, fmt: dur }, { key: 'max_dop', label: 'max DOP', num: true },
      { key: 'intervals', num: true },
      { key: 'first_execution', label: 'first execution', fmt: fmtTime }, { key: 'last_execution', label: 'last execution', fmt: fmtTime },
      { key: 'is_parallel', label: 'parallel', fmt: yes }, { key: 'compatibility_level', label: 'compat level', num: true, fmt: v => text(v) },
      { key: 'count_compiles', label: 'compiles', num: true },
      { key: 'initial_compile', label: 'first compiled', fmt: fmtTime }, { key: 'last_compile', label: 'last compiled', fmt: fmtTime },
      { key: 'plan_hash', label: 'plan hash' },
      { key: 'xml_state', label: 'plan XML', fmt: (v, r) => planFile(ctx, row.database_name, r.plan_id, v, r.xml_note, r.in_store) },
    ];
    const pd = pivot(series, 'plan_id', 'avg_duration_ms'), pc = pivot(series, 'plan_id', 'avg_cpu_ms');
    const charts = el('div', { class: 'charts' },
      lineChart('Average duration per interval, by plan', pd.rows, pd.keys.map(k => ({ key: k, label: k })), v => fmtNum(v) + ' ms'),
      lineChart('Average CPU per interval, by plan', pc.rows, pc.keys.map(k => ({ key: k, label: k })), v => fmtNum(v) + ' ms'));
    panel.show(
      props([
        ['database', text(row.database_name)],
        ['query', `${text(row.query_id)}${q?.object_name ? ' in ' + text(q.object_name) : ''}`],
        ['query hash', text(row.query_hash)],
        ['parameterization', text(q?.parameterization).toLowerCase() || '-'],
        ['plans', `${fmtNum(plans.length)} in this range's stored rows; the store holds ${q?.plan_count == null ? '?' : fmtNum(q.plan_count)}`],
        ['last execution', fmtTime(q?.last_execution)],
      ]),
      el('pre', { class: 'sql', tabindex: '0' }, text(q?.query) || '(no statement text is stored: the query_text policy of this instance is "none", or the query left the store)'),
      el('h4', {}, 'Plans'),
      grid(plans, cols, 'No stored row of this query in this range.'),
      charts,
      numbersOf(series, [
        { key: 'snapshot_at', label: 'interval from', fmt: fmtTime }, { key: 'plan_id', label: 'plan', num: true, fmt: v => text(v) },
        { key: 'executions', num: true }, { key: 'avg_duration_ms', label: 'avg duration', num: true, fmt: dur },
        { key: 'avg_cpu_ms', label: 'avg CPU', num: true, fmt: dur }, { key: 'avg_logical_reads', label: 'avg logical reads', num: true },
      ]),
      el('p', { class: 'meta' }, 'One point = one interval of the store in which the plan was among the interval\'s top plans. A line that starts where another ends '
        + 'is most often a plan that replaced another; a gap can also be an interval the plan ran in under every cut. '
        + 'Two lines at once are two plans in use (parameter-sensitive, or one per SET options).'),
    );
  } catch (e) {
    if (mine === opening) panel.show(errorBox(e));
  }
}

const openCol = (ctx: Ctx, panel: ReturnType<typeof detailPanel>): Col => ({
  key: 'open', label: 'plans',
  fmt: (_, r) => r.query_id == null ? '' : openButton('Open', `the plans of query ${text(r.query_id)} in ${text(r.database_name)}`, () => { void openQuery(ctx, r, panel); }),
});

// ---- the compare: PerformanceMonitor's top-compare.js (3.12.0, MIT License, Copyright (c) Erik Darling, Darling Data
// LLC) on pgvigil's stored rows: the range against the same span earlier, on the Query Store, Plan cache and
// Procedures grids. One section, the grids' pages place it under their grid (compareSection).

export type CompareKind = 'querystore' | 'plancache' | 'procs';
// PerformanceMonitor's picks (Off, Yesterday, Last week; its 'Same day last week' shifts as Last week does) and DBA
// Dash's Previous Period
const comparePicks: [string, string][] = [['', 'Off'], ['prev', 'Previous period'], ['day', 'Yesterday'], ['week', 'Last week']];
// a time in UTC and in the viewer's zone (the windows are UTC instants: across a change of the clocks the earlier
// window reads an hour off on the wall clock)
const both = (v: unknown) => v == null || v === '' ? '' : `${new Date(text(v)).toISOString().slice(0, 16).replace('T', ' ')} UTC (${fmtTime(v)} here)`;
const hoursOf = (secs: unknown) => fmtNum(Math.round(Number(secs ?? 0) / 360) / 10) + ' h';
// PerformanceMonitor's colour bands (top-compare.js:153-155): duration and CPU red over +25 %, green under -25 %;
// executions red over +100 %, green under -50 %
function band(up: number, down: number): Pick<Col, 'fmt' | 'cls'> {
  const cls = (v: unknown) => v == null || v === '' ? '' : Number(v) > up ? 'status crit' : Number(v) < down ? 'status ok' : '';
  return {
    fmt: v => { if (v == null || v === '') return ''; const t = (Number(v) > 0 ? '+' : '') + fmtNum(v) + ' %'; return cls(v) ? tinted(t) : t; },
    cls,
  };
}

// compareSection: the pick and, for any but Off, the windows, how much of each the stored rows cover, and the grid.
// filter: the page's own narrowing (db=, scope=) so the compare reads what its grid reads. The pick is remembered per
// page for the session.
export function compareSection(ctx: Ctx, kind: CompareKind, filter: Record<string, string | number | undefined>): HTMLElement {
  const store = `pgvigil.mssql.compare.${kind}`;
  let pick = (() => { try { return sessionStorage.getItem(store) ?? ''; } catch { return ''; } })();
  if (!comparePicks.some(c => c[0] === pick)) pick = '';
  const id = `cmp-${kind}`;
  const sel = el('select', { id }) as HTMLSelectElement;
  for (const [k, l] of comparePicks) sel.append(el('option', { value: k }, l));
  sel.value = pick;
  const body = el('div', { 'aria-live': 'polite' });
  const box = el('section', { class: 'compare' }, el('h3', {}, 'Compare with an earlier window'),
    el('div', { class: 'toolbar' }, el('label', { for: id }, 'Compare with '), sel), body);
  let seq = 0;
  async function draw() {
    const mine = ++seq;
    if (!pick) { body.replaceChildren(); return; }
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    const w = window_(ctx);
    const q = { instance: ctx.instance, ...w, ...filter, compare: pick };
    try {
      const [wd, cd] = await Promise.all([
        get<{ compare_windows: Table | null }>(`mssql/${kind}`, { ...q, part: 'compare_windows' }),
        get<{ compare: Table | null }>(`mssql/${kind}`, { ...q, part: 'compare' }),
      ]);
      if (mine !== seq) return;
      body.replaceChildren(...compareBody(kind, rowsOf(wd.compare_windows)[0] ?? {}, rowsOf(cd.compare)));
    } catch (e) {
      if (mine === seq) body.replaceChildren(errorBox(e));
    }
  }
  sel.addEventListener('change', () => {
    pick = sel.value;
    try { sessionStorage.setItem(store, pick); } catch { /* private window */ }
    void draw();
  });
  void draw();
  return box;
}

function compareBody(kind: CompareKind, w: Row, rows: Row[]): HTMLElement[] {
  const out: HTMLElement[] = [];
  out.push(el('p', { class: 'meta' }, `This range: ${both(w.now_from)} to ${both(w.now_to)}. Earlier window: ${both(w.before_from)} to ${both(w.before_to)}.`
    + (w.overlap ? ' The two windows overlap (the shift is shorter than the range): what ran in the overlap counts in both.' : '')));
  const held = kind === 'querystore'
    ? `The stored Query Store data starts ${w.data_from ? fmtTime(w.data_from) : 'after the earlier window'}; intervals with runs: ${fmtNum(w.now_intervals)} in this range, `
      + `${fmtNum(w.before_intervals)} in the earlier window (a store writes no interval for a minute in which nothing ran)`
    : `The reads cover ${hoursOf(w.now_covered_secs)} of this range (${fmtNum(w.now_reads)} reads) and ${hoursOf(w.before_covered_secs)} of the earlier window (${fmtNum(w.before_reads)} reads)`;
  out.push(el('p', { class: 'meta' }, `Baseline: ${text(w.coverage)}. ${held}.`));
  // PerformanceMonitor never draws every row as NEW: nothing in scope ran in the earlier window = no comparison
  const r0 = rows[0] ?? {};
  const before = Number(r0.n_both ?? 0) + Number(r0.n_not_kept_now ?? 0) + Number(r0.n_gone ?? 0);
  if (w.coverage === 'no baseline' || (rows.length > 0 && before === 0)) {
    out.push(el('p', { class: 'empty' }, 'No data for the comparison window: nothing was stored for the earlier window. The grid above is this range alone.'));
    return out;
  }
  if (kind === 'querystore') {
    out.push(el('p', { class: 'meta' }, `${fmtNum(r0.n_keys ?? 0)} queries (database and query hash) in the two windows: ${fmtNum(r0.n_both ?? 0)} in both, `
      + `${fmtNum(r0.n_new ?? 0)} new (first compiled after the earlier window), ${fmtNum(r0.n_not_kept_before ?? 0)} not kept before, ${fmtNum(r0.n_not_kept_now ?? 0)} not kept now. `
      + 'The store keeps each interval\'s top plans only: "not kept before" is a query with no kept row in the earlier window that was compiled before it '
      + '(it may have run then below the kept plans); "not kept now" a query with no kept row in this range (pgvigil does not read whether it still runs).'
      + (Number(w.no_hash_rows) > 0 ? ` ${fmtNum(w.no_hash_rows)} row(s) of this range have no query hash (the plan left the store between the read's two steps) and are left out.` : '')));
  } else {
    const cut = Number(w.now_cut_reads ?? 0) + Number(w.before_cut_reads ?? 0) + Number(w.edge_cut_reads ?? 0), reads = Number(w.now_reads ?? 0) + Number(w.before_reads ?? 0);
    out.push(el('p', { class: 'meta' }, `${fmtNum(r0.n_keys ?? 0)} ${kind === 'procs' ? 'procedures' : 'statements (database and query hash)'} in the two windows: `
      + `${fmtNum(r0.n_both ?? 0)} in both, ${fmtNum(r0.n_new ?? 0)} only in this range, ${fmtNum(r0.n_gone ?? 0)} only in the earlier window.`
      + (kind === 'plancache' && cut > 0 ? ` ${fmtNum(cut)} cut read(s) among the ${fmtNum(reads)} of the two windows and the read just before each (the cache held more statements than the collector's lists keep): `
        + 'a statement past the cut has no row in a cut read, so the grid says "not kept before" / "not kept now" in place of NEW / GONE.' : '')
      + (kind === 'procs' ? ' Procedures are matched by database and name, as PerformanceMonitor matches them (one dropped and created again is one row). '
        + 'A procedure compiled, run and dropped from the plan cache between two reads is in neither window, and on a server with more than 5,000 procedure plans '
        + 'a read keeps the 5,000 with the most CPU (pgvigil does not keep which reads were cut): there NEW and GONE can be a procedure past the cut.' : '')));
  }
  const status = (v: unknown, r: Row) => {
    const t = text(v);
    if (t === 'new') return badge(kind === 'querystore' ? `new: first compiled ${fmtTime(r.first_compile)}` : 'NEW', 'warn');
    if (t === 'gone') return badge('GONE', '');
    return t;
  };
  const keyCols: Col[] = kind === 'procs'
    ? [{ key: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'object_name', label: 'name' }]
    : kind === 'plancache'
      ? [{ key: 'database' }, { key: 'query_key', label: 'query hash' }, { key: 'object_name', label: 'object' }]
      : [{ key: 'database_name', label: 'database' }, { key: 'query_hash', label: 'query hash' }, { key: 'object_name', label: 'object' }];
  const cols: Col[] = [
    ...keyCols,
    { key: 'status', label: 'new / gone', fmt: status },
    { key: 'before_executions', label: 'executions before', num: true }, { key: 'executions', label: 'executions now', num: true },
    { key: 'executions_pct', label: 'executions +%', num: true, ...band(100, -50) },
    { key: 'before_avg_duration_ms', label: 'avg duration before', num: true, fmt: dur }, { key: 'avg_duration_ms', label: 'avg duration now', num: true, fmt: dur },
    { key: 'avg_duration_pct', label: 'avg duration +%', num: true, ...band(25, -25) },
    { key: 'before_avg_cpu_ms', label: 'avg CPU before', num: true, fmt: dur }, { key: 'avg_cpu_ms', label: 'avg CPU now', num: true, fmt: dur },
    { key: 'avg_cpu_pct', label: 'avg CPU +%', num: true, ...band(25, -25) },
    { key: 'before_duration_ms', label: 'total duration before', num: true, fmt: dur }, { key: 'duration_ms', label: 'total duration now', num: true, fmt: dur },
    ...(kind === 'procs' ? [] : [{ key: 'query', label: 'statement', fmt: stmt }] as Col[]),
  ];
  out.push(grid(rows, cols, kind === 'procs' ? 'No procedure ran in either window.' : 'No statement ran in either window.'),
    el('p', { class: 'meta' }, 'The rows: each window\'s first 100 by total duration, together (PerformanceMonitor\'s). New first, gone last, then the largest rise of the average duration. '
      + '+% is against the earlier window, blank where that was 0, and the averages\' blank on a row with nothing now (PerformanceMonitor shows -100 % there; here it may only have fallen below the kept rows). '
      + 'Red: duration or CPU per execution up more than 25 %, executions up more than 100 %; green: down more than 25 % (executions 50 %).'));
  return out;
}

// ---- Top

function topView(ctx: Ctx, d: QS, order: string): HTMLElement[] {
  const t = rowsOf(d.totals)[0] ?? {}, rows = rowsOf(d.top), series = rowsOf(d.series);
  const out: HTMLElement[] = [];
  if (!Number(t.intervals)) {
    out.push(el('p', { class: 'empty' }, 'No interval of a Query Store overlaps this range: pick a longer range (the collection runs hourly, and a store\'s interval is an hour unless its database says otherwise).'));
    return out;
  }
  const share = (kept: unknown, all: unknown) => Number(all) > 0 ? fmtNum(Math.round(1000 * Number(kept) / Number(all)) / 10) + ' %' : '-';
  out.push(el('div', { class: 'tiles' },
    tile('executions', fmtNum(t.executions)), tile('duration', dur(t.duration_ms)), tile('CPU', dur(t.cpu_ms)),
    tile('logical reads', fmtNum(t.logical_reads)), tile('wait time', t.wait_ms == null ? 'n/a' : dur(t.wait_ms)),
    tile('intervals', fmtNum(t.intervals)), tile('databases', fmtNum(t.databases))));
  out.push(el('p', { class: 'meta' }, `The tiles are the store's totals over every plan, ${fmtTime(t.first_start)} to ${fmtTime(t.last_end)} (every interval that overlaps the range; read ${fmtTime(t.read_at)}). `
    + `The list holds the plans in each interval's first 50 by duration, CPU, logical reads, memory grant or waits: ${share(t.kept_duration_ms, t.duration_ms)} of that duration, `
    + `${share(t.kept_cpu_ms, t.cpu_ms)} of the CPU, ${share(t.kept_executions, t.executions)} of the executions.`));
  out.push(switcher('Sort by', 'qo', orders.map(o => [o[0], o[1]] as [string, string]), order, 'duration'));
  const totalKey = orders.find(o => o[0] === order)![2];
  const whole = totalKey ? Number(t[totalKey]) : 0;
  const panel = detailPanel('One query');
  const cols: Col[] = [
    { key: 'database_name', label: 'database' },
    { key: 'query_id', label: 'query', num: true, fmt: v => v == null ? '(plans gone from the store)' : text(v) },
    openCol(ctx, panel),
    { key: 'object_name', label: 'object' },
    { key: 'executions', num: true },
    { key: 'duration_ms', label: 'total duration', num: true, fmt: dur },
    ...(totalKey ? [{ key: 'share', label: `share of all ${orders.find(o => o[0] === order)![1]}`, num: true, fmt: (_: unknown, r: Row) => share(r[totalKey], whole) }] as Col[] : []),
    { key: 'avg_duration_ms', label: 'avg duration', num: true, fmt: dur },
    { key: 'max_duration_ms', label: 'max duration', num: true, fmt: dur },
    { key: 'cpu_ms', label: 'total CPU', num: true, fmt: dur },
    { key: 'avg_cpu_ms', label: 'avg CPU', num: true, fmt: dur },
    { key: 'logical_reads', label: 'logical reads', num: true },
    { key: 'avg_logical_reads', label: 'avg logical reads', num: true },
    { key: 'physical_reads', label: 'physical reads', num: true },
    { key: 'logical_writes', label: 'writes', num: true },
    { key: 'row_count', label: 'rows', num: true },
    { key: 'max_memory_mb', label: 'max memory grant', num: true, fmt: mb },
    { key: 'wait_ms', label: 'wait time', num: true, fmt: dur },
    { key: 'top_wait', label: 'main wait' },
    { key: 'max_dop', label: 'max DOP', num: true },
    { key: 'plans', label: 'plans (in range)', num: true },
    { key: 'forced', fmt: v => v ? badge('forced', 'ok') : '' },
    { key: 'failed', label: 'aborted or failed', num: true },
    { key: 'last_execution', label: 'last execution', fmt: fmtTime },
    { key: 'query_hash', label: 'query hash' },
    { key: 'query', label: 'statement', fmt: stmt },
  ];
  // the share column sorts by the ordered total
  for (const r of rows) r.share = totalKey ? r[totalKey] : null;
  // PerformanceMonitor's strip over its Query Store grid: a drag reads the grid again for the stretch (its shares of the
  // stretch's own totals); a row's Draw puts its average duration per interval on the strip
  const gbox = el('div', {});
  const said = el('p', { class: 'meta', role: 'status' });
  const win = window_(ctx);
  const strip = qsStrip(win, series, (from, to, words) => {
    const p = { instance: ctx.instance, from: from ?? win.from, to: to ?? win.to, db: hashQS().get('qdb')?.slice(0, 128) || undefined, order, view: 'top' };
    void Promise.all([get<QS>('mssql/querystore', { ...p, part: 'top' }), get<QS>('mssql/querystore', { ...p, part: 'totals' })]).then(([a, b]) => {
      const rs = rowsOf(a.top), tt = rowsOf(b.totals)[0] ?? {};
      const all = totalKey ? Number(tt[totalKey]) : 0;
      for (const r of rs) r.share = totalKey ? r[totalKey] : null;
      const shareCol = cols.findIndex(c => c.key === 'share');
      const cs = shareCol < 0 ? cols : cols.map((c, i) => i === shareCol ? { ...c, fmt: (_: unknown, r: Row) => share(r[totalKey], all) } : c);
      said.textContent = from ? `The grid holds ${words ?? ''}, snapped to the store's intervals (${fmtTime(from)} to ${fmtTime(to)}); its shares are of that stretch.` : '';
      gbox.replaceChildren(grid(rs, cs, 'No query ran in the store\'s intervals of this stretch.'));
    }).catch(e => gbox.replaceChildren(errorBox(e)));
  });
  cols.splice(3, 0, { key: 'line', label: 'on the strip', fmt: (_, r) => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `Draw query ${text(r.query_id)} on the strip` }, 'Draw');
    b.addEventListener('click', () => { void qsOverlay(ctx, strip, r).catch(e => said.replaceChildren(errorBox(e))); });
    return b;
  } });
  gbox.replaceChildren(grid(rows, cols, 'No query ran in the store\'s intervals of this range.'));
  out.push(strip, said, gbox, panel.box);
  out.push(compareSection(ctx, 'querystore', { db: hashQS().get('qdb')?.slice(0, 128) || undefined }));
  out.push(el('div', { class: 'charts' },
    lineChart('The store over time: duration and CPU of every plan', series, [{ key: 'duration_ms', label: 'duration' }, { key: 'cpu_ms', label: 'CPU' }], v => dur(v)),
    lineChart('The store over time: executions', series, [{ key: 'executions', label: 'executions' }])));
  out.push(numbersOf(series, [
    { key: 'snapshot_at', label: 'from', fmt: fmtTime }, { key: 'executions', num: true }, { key: 'duration_ms', label: 'duration', num: true, fmt: dur },
    { key: 'cpu_ms', label: 'CPU', num: true, fmt: dur }, { key: 'logical_reads', label: 'logical reads', num: true }, { key: 'wait_ms', label: 'wait time', num: true, fmt: dur },
  ]));
  return out;
}

// ---- Regressed: PerformanceMonitor's Query Store regressions (3.12.0, QueryStoreRegressionRules.cs and its grid,
// server-tabs.js:4072-4111; MIT License, Copyright (c) Erik Darling, Darling Data LLC) beside pgvigil's duration test

// the baselines: PerformanceMonitor's 7 days before the range (its default) and the compare's shifts
const bases: [string, string][] = [['7d', 'The 7 days before (PerformanceMonitor)'], ['prev', 'Previous period'], ['day', 'Yesterday'], ['week', 'Last week']];
const sevCls = (v: unknown) => v === 'CRITICAL' ? 'status crit' : v === 'HIGH' ? 'status warn' : '';
const notApart = 'not read apart';

function regressedView(ctx: Ctx, d: QS, base: string): HTMLElement[] {
  const rows = rowsOf(d.regressed), skipped = rowsOf(d.regressed_skipped)[0] ?? {};
  const panel = detailPanel('One query');
  // a side with a row read before 0126 (or by an older collector) holds no split: its counts are unknown, never 0
  const split = (side: 'recent' | 'base') => (v: unknown, r: Row) =>
    Number(r[`${side}_unsplit`]) > 0 ? notApart : side === 'base' && !r.has_baseline ? 'no kept baseline' : v == null ? '' : fmtNum(v);
  const ms = (side: 'recent' | 'base') => (v: unknown, r: Row) =>
    side === 'base' && !r.has_baseline ? '' : Number(r[`${side}_unsplit`]) > 0 ? notApart : dur(v);
  const abortedTip = 'Timeouts (Aborted) is execution_type 3: "Client initiated aborted execution" (Microsoft): a timeout or a cancel by the client.';
  const cols: Col[] = [
    { key: 'severity', label: 'Severity', cls: sevCls, fmt: v => sevCls(v) ? tinted(text(v)) : text(v) },
    { key: 'raised_by', label: 'Why' },
    { key: 'database_name', label: 'Database' },
    { key: 'query', label: 'Query', fmt: stmt },
    { key: 'query_id', label: 'Query ID', num: true, fmt: v => text(v) },
    openCol(ctx, panel),
    // their own keys: the grid's column filters go by key, and the same counts come again under their groups
    { key: 'recent_timeouts', label: 'Recent Timeouts', num: true, fmt: split('recent') },
    { key: 'recent_errors', label: 'Recent Errors', num: true, fmt: split('recent') },
    { key: 'additional_duration_ms', label: 'Extra Duration', num: true, fmt: dur },
    { key: 'duration_regression_percent', label: 'Duration +%', num: true },
    { key: 'base_dur_ms', label: 'Baseline Duration', num: true, fmt: ms('base') },
    { key: 'recent_dur_ms', label: 'Recent Duration', num: true, fmt: ms('recent') },
    { key: 'cpu_regression_percent', label: 'CPU +%', num: true },
    { key: 'base_cpu_ms', label: 'Baseline CPU', num: true, fmt: ms('base') },
    { key: 'recent_cpu_ms', label: 'Recent CPU', num: true, fmt: ms('recent') },
    { key: 'base_execs', label: 'Base Execs', num: true, fmt: split('base') },
    { key: 'recent_execs', label: 'Recent Execs', num: true, fmt: split('recent') },
    { key: 'before_plans', label: 'Baseline Plans', num: true },
    { key: 'recent_plans', label: 'Recent Plans', num: true },
    { key: 'base_aborted_execs', label: 'Baseline Timeouts Execs', num: true, fmt: split('base') },
    { key: 'recent_aborted_execs', label: 'Recent Timeouts Execs', num: true, fmt: split('recent') },
    { key: 'base_aborted_cpu_ms', label: 'Baseline Timeouts CPU', num: true, fmt: ms('base') },
    { key: 'recent_aborted_cpu_ms', label: 'Recent Timeouts CPU', num: true, fmt: ms('recent') },
    { key: 'base_aborted_dur_ms', label: 'Baseline Timeouts Duration', num: true, fmt: ms('base') },
    { key: 'recent_aborted_dur_ms', label: 'Recent Timeouts Duration', num: true, fmt: ms('recent') },
    { key: 'base_aborted_per_hour', label: 'Baseline Timeouts Per Hour', num: true, fmt: split('base') },
    { key: 'recent_aborted_per_hour', label: 'Recent Timeouts Per Hour', num: true, fmt: split('recent') },
    { key: 'base_exception_execs', label: 'Baseline Errors Execs', num: true, fmt: split('base') },
    { key: 'recent_exception_execs', label: 'Recent Errors Execs', num: true, fmt: split('recent') },
    { key: 'base_exception_cpu_ms', label: 'Baseline Errors CPU', num: true, fmt: ms('base') },
    { key: 'recent_exception_cpu_ms', label: 'Recent Errors CPU', num: true, fmt: ms('recent') },
    { key: 'base_exception_dur_ms', label: 'Baseline Errors Duration', num: true, fmt: ms('base') },
    { key: 'recent_exception_dur_ms', label: 'Recent Errors Duration', num: true, fmt: ms('recent') },
    { key: 'base_exception_per_hour', label: 'Baseline Errors Per Hour', num: true, fmt: split('base') },
    { key: 'recent_exception_per_hour', label: 'Recent Errors Per Hour', num: true, fmt: split('recent') },
    { key: 'base_regular_per_hour', label: 'Baseline Execs/Hour', num: true, fmt: split('base') },
    { key: 'recent_regular_per_hour', label: 'Recent Execs/Hour', num: true, fmt: split('recent') },
    { key: 'last_execution', label: 'Last Exec', fmt: fmtTime },
    // pgvigil's duration test (task 129): the plan it names
    { key: 'plan_id', label: 'plan', num: true, fmt: v => text(v) },
    { key: 'new_plan', label: 'plan seen before', fmt: (v, r) => !r.has_baseline ? '' : v ? badge('not seen before', 'warn') : 'yes' },
    { key: 'forced', fmt: v => v ? badge('forced', 'ok') : '' },
    { key: 'duration_ratio', label: 'plan duration x', num: true, fmt: v => Number(v) >= 1.5 ? tinted(times(v)) : times(v), cls: v => Number(v) >= 1.5 ? 'status warn' : '' },
    { key: 'cpu_ratio', label: 'plan CPU x', num: true, fmt: v => Number(v) >= 1.5 ? tinted(times(v)) : times(v), cls: v => Number(v) >= 1.5 ? 'status warn' : '' },
    { key: 'object_name', label: 'object' },
  ];
  const baseWords = base === 'prev' ? 'the range of equal length before it' : base === 'day' ? 'the same range 24 hours earlier'
    : base === 'week' ? 'the same range 168 hours earlier' : 'the 7 days before it (PerformanceMonitor\'s baseline)';
  // a shift shorter than the range: the baseline holds part of the range itself
  const w = window_(ctx), span = Date.parse(w.to) - Date.parse(w.from);
  const shift = base === 'day' ? 864e5 : base === 'week' ? 6048e5 : 0;
  const overlap = shift > 0 && span > shift;
  const out: HTMLElement[] = [
    switcher('Baseline', 'qb', bases, base, '7d'),
    el('p', { class: 'meta' }, `One row per query, this range (${rangeLabel(ctx)}) against ${baseWords}. A row of the store (one kept plan in one interval) is placed by its last run, as PerformanceMonitor places it: `
      + 'in the range when its interval overlaps the range and it ran last at or after the range\'s start, in the baseline when it ran last inside the baseline. A query is listed when:'),
    ...(overlap ? [el('p', { class: 'meta' }, 'The baseline overlaps this range (the shift is shorter than the range): the runs of the shared part count on both sides, which hides a regression inside it. '
      + 'Pick a range shorter than the shift, or the 7 days before.')] : []),
    el('ul', { class: 'meta' },
      el('li', {}, 'cost (PerformanceMonitor): its Regular CPU per run is more than 25 % above the baseline\'s, and the rise times its recent Regular runs adds at least 1 s of CPU over the range;'),
      el('li', {}, 'timeouts / errors (PerformanceMonitor): at least 3 Aborted (Exception) runs in the range, and per hour at least 2 times the baseline\'s rate, or any where the baseline had none; '
        + 'per hour is over the clock hours of each window from its start, or from the database\'s first stored interval when that is later;'),
      el('li', {}, 'duration (pgvigil): one of its plans averages 1.5 times the query\'s average duration or CPU over the baseline (every execution type), or more, and at least 1 ms; that plan is the row\'s "plan".')),
    el('p', { class: 'meta' }, 'Severity is PerformanceMonitor\'s: a cost row by its Regular duration rise (over 100 % CRITICAL, 50 % HIGH, 25 % MEDIUM, else LOW); a timeouts or errors row HIGH at 5 times the baseline\'s rate '
      + '(or none before), else MEDIUM, never CRITICAL; a row raised by the duration test alone takes the same bands on its plan\'s ratio. '
      + `${abortedTip} Exception: the run ended in an error. Regular figures leave both out. `
      + '"No kept baseline": the query is in no kept row of the baseline (the store keeps each interval\'s top plans only): the cost and duration tests need one, the timeouts and errors tests count it as none. '
      + 'A query is one store\'s query id and its hash: a cleared store numbers its queries again, so a query is never compared across a clear.'),
  ];
  if (Number(skipped.queries) > 0) {
    out.push(el('p', { class: 'meta' }, `${fmtNum(skipped.queries)} quer${Number(skipped.queries) === 1 ? 'y has' : 'ies have'} failed runs stored before Aborted and Exception were kept apart `
      + `(the newest ${fmtTime(skipped.newest_unsplit)}): "${notApart}" in their cells, and the cost, timeouts and errors tests are not applied to them (never read as none).`));
  }
  out.push(grid(rows, cols, 'No query regressed among the stored rows: none passes a test against this baseline, or the baseline holds no kept row of it.'), panel.box);
  return out;
}

// ---- Forced plans

function forcedView(ctx: Ctx, d: QS): HTMLElement[] {
  const rows = rowsOf(d.forced);
  const cols: Col[] = [
    { key: 'database_name', label: 'database' }, { key: 'query_id', label: 'query', num: true, fmt: v => text(v) },
    { key: 'plan_id', label: 'plan', num: true, fmt: v => text(v) },
    { key: 'object_name', label: 'object' },
    { key: 'query', label: 'statement', fmt: stmt },
    { key: 'forcing_type', label: 'plan forcing', fmt: v => text(v).toLowerCase() },
    { key: 'force_failure_count', label: 'force failures', num: true, fmt: v => Number(v) > 0 ? tinted(fmtNum(v)) : fmtNum(v), cls: v => Number(v) > 0 ? 'status warn' : '' },
    { key: 'force_failure_reason', label: 'last force failure' },
    { key: 'plan_count', label: 'plans of the query', num: true },
    { key: 'plan_last_execution', label: 'last execution (plan)', fmt: fmtTime },
    { key: 'query_last_execution', label: 'last execution (query)', fmt: fmtTime },
    { key: 'last_compile', label: 'last compiled', fmt: fmtTime },
    { key: 'query_hash', label: 'query hash' }, { key: 'plan_hash', label: 'plan hash' },
    { key: 'is_parallel', label: 'parallel', fmt: yes },
    { key: 'forced_seen', label: 'first seen forced', fmt: fmtTime },
    { key: 'xml_state', label: 'plan XML', fmt: (v, r) => planFile(ctx, r.database_name, r.plan_id, v, null, true) },
  ];
  return [
    el('p', { class: 'meta' }, 'Every plan forced in a database\'s store as the last read found it (the range does not narrow this list). '
      + 'A force failure means SQL Server could not use the forced plan and ran the query with another: the reason names why (an index dropped, a hint that no longer fits). '
      + 'pgvigil forces and unforces nothing: sys.sp_query_store_force_plan and sp_query_store_unforce_plan are the DBA\'s.'),
    grid(rows, cols, 'No forced plan in the stores read.'),
  ];
}

// ---- Tuning

function tuningView(d: QS): HTMLElement[] {
  const recs = rowsOf(d.tuning), opts = rowsOf(d.tuning_options);
  const optCols: Col[] = [
    { key: 'database_name', label: 'database' }, { key: 'option_name', label: 'option' },
    { key: 'desired_state', label: 'desired', fmt: v => text(v).toLowerCase() },
    { key: 'actual_state', label: 'actual', fmt: v => text(v).toLowerCase() },
    { key: 'reason', label: 'why' }, { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ];
  const recCols: Col[] = [
    { key: 'database_name', label: 'database' }, { key: 'rec_type', label: 'type' },
    { key: 'rec_state', label: 'state', fmt: (v, r) => r.is_present ? text(v) : `${text(v) || '?'} (no longer listed)` },
    { key: 'state_reason', label: 'state reason' },
    { key: 'score', num: true },
    { key: 'reason' },   // one line: a 'wide' cell among seventeen columns wrapped at every word (a row 135 px tall)
    { key: 'query_id', label: 'query', num: true, fmt: v => text(v) },
    { key: 'regressed_plan_id', label: 'regressed plan', num: true, fmt: v => text(v) },
    { key: 'recommended_plan_id', label: 'recommended plan', num: true, fmt: v => text(v) },
    { key: 'valid_since', label: 'valid since', fmt: fmtTime }, { key: 'last_refresh', label: 'last refresh', fmt: fmtTime },
    { key: 'executed_at', label: 'applied', fmt: (v, r) => v == null ? '' : `${fmtTime(v)} by ${text(r.executed_by).toLowerCase() || '?'}` },
    { key: 'reverted_at', label: 'reverted', fmt: (v, r) => v == null ? '' : `${fmtTime(v)} by ${text(r.reverted_by).toLowerCase() || '?'}` },
    { key: 'script', label: 'script', fmt: v => v == null || v === '' ? '' : sqlCell(v, { heading: 'The recommendation\'s script', title: 'Show the script' }) },
    { key: 'object_name', label: 'object' },
    { key: 'query', label: 'statement', fmt: v => v == null || v === '' ? '' : sqlCell(v) },
    // PerformanceMonitor's First seen / Last seen (its plan corrections grid): the first read that listed the
    // recommendation and the last; its Captures is not kept (pgvigil stores the current state, not each read)
    { key: 'first_seen', label: 'first seen', fmt: fmtTime },
    { key: 'snapshot_at', label: 'last seen', fmt: fmtTime },
  ];
  return [
    el('p', { class: 'meta' }, 'SQL Server 2017 and later: the server\'s own plan-regression recommendations (sys.dm_db_tuning_recommendations) and each database\'s automatic tuning options. '
      + 'With FORCE_LAST_GOOD_PLAN on the server applies a recommendation itself and reverts it when it does not help; with it off the script is the DBA\'s to run. '
      + 'The list is the server\'s memory: a restart empties it, and a recommendation the server stopped listing inside the range stays here marked so. '
      + 'The statement beside a recommendation is the store\'s current query of that number.'),
    el('h3', {}, 'Recommendations'),
    grid(recs, recCols, 'No automatic tuning recommendation is listed for this range.'),
    el('h3', {}, 'Automatic tuning options'),
    grid(opts, optCols, 'No automatic tuning option read (SQL Server 2016 has none).'),
  ];
}

// ---- Store state (DBA Dash's QS grid)

function stateView(d: QS): HTMLElement[] {
  const rows = rowsOf(d.state);
  const lower = (v: unknown) => text(v).toLowerCase().replace(/_/g, ' ');
  const stateCls = (_: unknown, r: Row) => r.severity === 'critical' ? 'status crit' : r.severity === 'warning' ? 'status warn' : '';
  const cols: Col[] = [
    { key: 'database_name', label: 'database' },
    { key: 'severity', label: 'status', cls: stateCls,
      fmt: (v, r) => {
        const b = !r.options_read ? badge('not read', '') : v === 'critical' ? badge('critical', 'crit') : v === 'warning' ? badge('warning', 'warn')
          : v === 'info' ? badge('note', '') : r.actual_state === 'OFF' ? 'off' : badge('OK', 'ok');
        return stateCls(v, r) ? tinted(b) : b;
      } },
    { key: 'desired_state', label: 'desired state', fmt: lower },
    { key: 'actual_state', label: 'actual state', fmt: (v, r) => stateCls(v, r) ? tinted(lower(v)) : lower(v), cls: stateCls },
    { key: 'readonly_reasons', label: 'read-only reason', fmt: (v, r) => text(v) || (Number(r.readonly_reason) ? `reason ${text(r.readonly_reason)}` : '') },
    { key: 'capture_mode', label: 'query capture mode', fmt: lower },
    { key: 'cleanup_mode', label: 'size-based cleanup', fmt: lower },
    { key: 'wait_stats_mode', label: 'wait stats capture', fmt: lower },
    { key: 'stale_days', label: 'stale query threshold (days)', num: true },
    { key: 'max_plans_per_query', label: 'max plans per query', num: true },
    { key: 'current_mb', label: 'current size MB', num: true },
    { key: 'max_mb', label: 'max size MB', num: true },
    { key: 'used_pct', label: 'used', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' %' },
    { key: 'flush_interval_s', label: 'flush interval (sec)', num: true },
    { key: 'interval_minutes', label: 'interval length (min)', num: true },
    { key: 'policy_execution_count', label: 'policy execution count', num: true },
    { key: 'policy_stale_hours', label: 'policy stale threshold (hrs)', num: true },
    { key: 'policy_compile_cpu_ms', label: 'policy total compile time (ms)', num: true },
    { key: 'policy_exec_cpu_ms', label: 'policy total execution CPU time (ms)', num: true },
    // a judgement's sentence is in the grid under this one (here it made the row 280 px tall); the note stays on
    // one line: a 'wide' cell among twenty-two columns wraps at every word
    { key: 'note', label: 'not read because' },
    { key: 'newest_interval', label: 'newest interval stored', fmt: fmtTime },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ];
  // a flagged store's sentence, said by the view itself: the Checks above carry it only while the store's read is
  // under three hours old (the findings view), and the grid's colour has no such limit
  const flagged = rows.filter(r => r.severity != null && text(r.verdict) !== '');
  return [
    el('p', { class: 'meta' }, 'One row per database (master and tempdb have no Query Store). Critical: the store is in the ERROR state. Warning: it is read-only '
      + '(unless the database itself is read-only or a secondary replica), or off though a state was asked for. Note: a store at 90 % of its max size with size-based cleanup off. '
      + 'A store that is off because nobody asked for it is a choice, not a fault. What each flagged state means is listed under the grid.'),
    grid(rows, cols, 'No database read.'),
    ...(flagged.length ? [el('h3', {}, 'What each flagged state means'), grid(flagged, [
      { key: 'database_name', label: 'database' },
      { key: 'severity', label: 'status', fmt: v => v === 'info' ? badge('note', '') : sevBadge(v) },
      { key: 'verdict', label: 'what it means', wide: true },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], '')] : []),
  ];
}

// mssqlQueryStoreView: the page. The checks first, then the view the hash names.
export async function mssqlQueryStoreView(ctx: Ctx): Promise<HTMLElement> {
  const hq = hashQS();
  const view = views.some(v => v[0] === hq.get('qs')) ? hq.get('qs')! : 'top';
  const order = orders.some(o => o[0] === hq.get('qo')) ? hq.get('qo')! : 'duration';
  const db = (hq.get('qdb') ?? '').slice(0, 128);
  const base = bases.some(b => b[0] === hq.get('qb')) ? hq.get('qb')! : '7d';
  const sec = el('section', {}, el('h2', {}, `Query Store (${rangeLabel(ctx)})`));
  try {
    const d = await get<QS>('mssql/querystore', { instance: ctx.instance, ...window_(ctx), db: db || undefined, order, view,
      base: view === 'regressed' ? base : undefined });
    const state = rowsOf(d.state), checks = rowsOf(d.checks);
    if (!state.length) {
      sec.append(el('p', { class: 'empty' }, 'No Query Store read yet: the mssql_querystore collection runs hourly, on SQL Server 2016 and later, and needs VIEW SERVER STATE '
        + '(which gives VIEW DATABASE STATE in every database).'));
      return sec;
    }
    const on = state.filter(r => r.actual_state === 'READ_WRITE' || r.actual_state === 'READ_ONLY');
    sec.append(el('p', { class: 'meta' }, `Query Store is on in ${fmtNum(on.length)} of ${fmtNum(state.length)} databases (read ${fmtTime(state[0].snapshot_at)}). `
      + 'The figures are what each database\'s own store recorded; the collection reads them hourly and runs nothing else on the server.'));
    if (checks.length) {
      sec.append(el('h3', {}, 'Checks'), grid(checks, [
        { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'check' }, { key: 'object' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
      ]));
    }
    // the database: every view but Store state narrows to it
    const pick = el('select', { id: 'qs-db' }) as HTMLSelectElement;
    pick.append(el('option', { value: '' }, 'all databases'));
    const names = on.map(r => text(r.database_name));
    if (db && !names.includes(db)) names.push(db);
    for (const n of names) pick.append(el('option', { value: n }, n));
    pick.value = db;
    if (refocus === pick.id) keepFocus(pick);
    pick.addEventListener('change', () => { refocus = pick.id; location.hash = hrefWith(q => { if (pick.value) q.set('qdb', pick.value); else q.delete('qdb'); }); });
    sec.append(el('div', { style: 'display:flex;flex-wrap:wrap;gap:1rem;align-items:baseline' },
      switcher('View', 'qs', views, view, 'top'),
      el('label', { class: 'meta', for: 'qs-db' }, 'Database '), pick));
    const body = view === 'regressed' ? regressedView(ctx, d, base) : view === 'forced' ? forcedView(ctx, d) : view === 'tuning' ? tuningView(d)
      : view === 'state' ? stateView(d) : topView(ctx, d, order);
    sec.append(...body);
  } catch (e) {
    sec.append(errorBox(e));
  }
  refocus = '';   // a control this draw did not rebuild (an empty view) must not take the focus at a later draw
  return sec;
}
