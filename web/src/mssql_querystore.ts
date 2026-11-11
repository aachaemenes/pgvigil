// The Query Store page of a SQL Server instance (task 129; DBA Dash's Query Store Top Queries, Forced Plans and
// QS options grids, Darling's Query Store tab): five views of what the mssql_querystore collection read from each
// database's store (hourly): Top (the window's queries by duration, CPU, reads, memory grant, waits or executions;
// a query opens its plans over time with a .sqlplan download per plan), Regressed (the window against the window
// before it, per plan), Forced plans (with the failure count and reason), Tuning (the automatic tuning
// recommendations and options) and Store state (actual against desired, the read-only reason, size against max).
// Data from /api/mssql/querystore and its two detail routes.
//
// The view, the sort and the database ride the page's hash (qs=, qo=, qdb=), read here as stmt_filter.ts reads its
// own; the lead's wiring keeps them on the tab's own links (router.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { sqlCell } from './sqlview';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlQueryStoreTab = 'mssqlqs';

type Parts = 'state' | 'totals' | 'series' | 'top' | 'regressed' | 'forced' | 'tuning' | 'tuning_options' | 'checks';
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
    tile('logical reads', fmtNum(t.logical_reads)), tile('wait time', dur(t.wait_ms)),
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
  out.push(grid(rows, cols, 'No query ran in the store\'s intervals of this range.'), panel.box);
  out.push(el('div', { class: 'charts' },
    lineChart('The store over time: duration and CPU of every plan', series, [{ key: 'duration_ms', label: 'duration' }, { key: 'cpu_ms', label: 'CPU' }], v => dur(v)),
    lineChart('The store over time: executions', series, [{ key: 'executions', label: 'executions' }])));
  out.push(numbersOf(series, [
    { key: 'snapshot_at', label: 'from', fmt: fmtTime }, { key: 'executions', num: true }, { key: 'duration_ms', label: 'duration', num: true, fmt: dur },
    { key: 'cpu_ms', label: 'CPU', num: true, fmt: dur }, { key: 'logical_reads', label: 'logical reads', num: true }, { key: 'wait_ms', label: 'wait time', num: true, fmt: dur },
  ]));
  return out;
}

// ---- Regressed

function regressedView(ctx: Ctx, d: QS): HTMLElement[] {
  const rows = rowsOf(d.regressed);
  const panel = detailPanel('One query');
  const cols: Col[] = [
    { key: 'database_name', label: 'database' }, { key: 'query_id', label: 'query', num: true, fmt: v => text(v) },
    openCol(ctx, panel),
    { key: 'plan_id', label: 'plan', num: true, fmt: v => text(v) },
    { key: 'new_plan', label: 'plan seen before', fmt: v => v ? badge('not seen before', 'warn') : 'yes' },
    { key: 'forced', fmt: v => v ? badge('forced', 'ok') : '' },
    { key: 'extra_duration_ms', label: 'extra duration', num: true, fmt: dur },
    { key: 'avg_duration_ms', label: 'avg duration', num: true, fmt: dur },
    { key: 'before_avg_duration_ms', label: 'before', num: true, fmt: dur },
    { key: 'duration_ratio', label: 'duration x', num: true, fmt: times, cls: v => Number(v) >= 1.5 ? 'status warn' : '' },
    { key: 'avg_cpu_ms', label: 'avg CPU', num: true, fmt: dur },
    { key: 'before_avg_cpu_ms', label: 'CPU before', num: true, fmt: dur },
    { key: 'cpu_ratio', label: 'CPU x', num: true, fmt: times, cls: v => Number(v) >= 1.5 ? 'status warn' : '' },
    { key: 'avg_logical_reads', label: 'avg logical reads', num: true },
    { key: 'before_avg_logical_reads', label: 'reads before', num: true },
    { key: 'executions', num: true }, { key: 'before_executions', label: 'executions before', num: true },
    { key: 'before_plans', label: 'plans before', num: true },
    { key: 'last_execution', label: 'last execution', fmt: fmtTime },
    { key: 'object_name', label: 'object' },
    { key: 'query', label: 'statement', fmt: stmt },
  ];
  return [
    el('p', { class: 'meta' }, `A plan whose average duration or CPU in this range (${rangeLabel(ctx)}) is 1.5 times its query's average in the range of equal length before it, or more, and at least 1 ms. `
      + 'The query\'s average before is over all its stored plans, so a plan not seen before is weighed against what the query cost then; "extra duration" is what the difference cost over the range\'s executions. '
      + 'Only the stored rows are compared (each interval\'s top plans): "not seen before" means the plan is in no stored row of the range before, and a query that was in no interval\'s top plans before has no figure to be weighed against and is not listed.'),
    grid(rows, cols, 'No regressed plan among the stored rows of this range: each is within 1.5 times its query\'s average before, or the range before holds no stored row of its query.'),
    panel.box,
  ];
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
    { key: 'force_failure_count', label: 'force failures', num: true, cls: v => Number(v) > 0 ? 'status warn' : '' },
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
    { key: 'reason', wide: true },
    { key: 'query_id', label: 'query', num: true, fmt: v => text(v) },
    { key: 'regressed_plan_id', label: 'regressed plan', num: true, fmt: v => text(v) },
    { key: 'recommended_plan_id', label: 'recommended plan', num: true, fmt: v => text(v) },
    { key: 'valid_since', label: 'valid since', fmt: fmtTime }, { key: 'last_refresh', label: 'last refresh', fmt: fmtTime },
    { key: 'executed_at', label: 'applied', fmt: (v, r) => v == null ? '' : `${fmtTime(v)} by ${text(r.executed_by).toLowerCase() || '?'}` },
    { key: 'reverted_at', label: 'reverted', fmt: (v, r) => v == null ? '' : `${fmtTime(v)} by ${text(r.reverted_by).toLowerCase() || '?'}` },
    { key: 'script', label: 'script', fmt: v => v == null || v === '' ? '' : sqlCell(v, { heading: 'The recommendation\'s script', title: 'Show the script' }) },
    { key: 'object_name', label: 'object' },
    { key: 'query', label: 'statement', fmt: v => v == null || v === '' ? '' : sqlCell(v) },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
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
      fmt: (v, r) => !r.options_read ? badge('not read', '') : v === 'critical' ? badge('critical', 'crit') : v === 'warning' ? badge('warning', 'warn')
        : v === 'info' ? badge('note', '') : r.actual_state === 'OFF' ? 'off' : badge('OK', 'ok') },
    { key: 'desired_state', label: 'desired state', fmt: lower },
    { key: 'actual_state', label: 'actual state', fmt: lower, cls: stateCls },
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
    { key: 'verdict', label: 'what it means', wide: true, fmt: (v, r) => text(v) || text(r.note) },
    { key: 'newest_interval', label: 'newest interval stored', fmt: fmtTime },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ];
  return [
    el('p', { class: 'meta' }, 'One row per database (master and tempdb have no Query Store). Critical: the store is in the ERROR state. Warning: it is read-only '
      + '(unless the database itself is read-only or a secondary replica), or off though a state was asked for. Note: a store at 90 % of its max size with size-based cleanup off. '
      + 'A store that is off because nobody asked for it is a choice, not a fault.'),
    grid(rows, cols, 'No database read.'),
  ];
}

// mssqlQueryStoreView: the page. The checks first, then the view the hash names.
export async function mssqlQueryStoreView(ctx: Ctx): Promise<HTMLElement> {
  const hq = hashQS();
  const view = views.some(v => v[0] === hq.get('qs')) ? hq.get('qs')! : 'top';
  const order = orders.some(o => o[0] === hq.get('qo')) ? hq.get('qo')! : 'duration';
  const db = (hq.get('qdb') ?? '').slice(0, 128);
  const sec = el('section', {}, el('h2', {}, `Query Store (${rangeLabel(ctx)})`));
  try {
    const d = await get<QS>('mssql/querystore', { instance: ctx.instance, ...window_(ctx), db: db || undefined, order, view });
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
    const body = view === 'regressed' ? regressedView(ctx, d) : view === 'forced' ? forcedView(ctx, d) : view === 'tuning' ? tuningView(d)
      : view === 'state' ? stateView(d) : topView(ctx, d, order);
    sec.append(...body);
  } catch (e) {
    sec.append(errorBox(e));
  }
  refocus = '';   // a control this draw did not rebuild (an empty view) must not take the focus at a later draw
  return sec;
}
