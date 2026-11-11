// The Slow queries tab and its fleet root (task 36; DBADash's slow queries): the statements the server log
// recorded over log_min_duration_statement (the CloudWatch reader on RDS and Aurora, the server-log file
// reader on-prem), with a threshold picker, a per-day histogram by duration band, the top statement shapes
// by count and by total time (each linked to the Statements tab, with the pg_stat_statements queryid of the
// same shape where there is one), the newest slow statements, and the activity sampler's long runs. At the
// root the fleet's shapes and the slow time per instance. Data from /api/slowqueries. The shell mounts
// slowView(ctx) on the instance tab and slowFleetView(ctx, keep, instLink) on the root (the lead wires them).
// The threshold rides in the hash as ms= (read and written here; the router does not carry it).
// Parity2 task 121 (DBA Dash 04, 16, 81; Darling 13.8 shot 92): a History button under each shape opens its trend
// (stmt_trend.ts), and slowGroupsPanel is DBA Dash's Slow Queries grid over both engines (/api/slow/groups and
// /api/slow/events): a free Group By, a database filter, ten duration buckets, Failed and the totals, every count a
// button that lists its events (time, client, application, user, database, duration, result) below. Both pages here
// carry it; the SQL Server Slow queries tab (mssql_xe.ts) gets it through the lead's wiring.
// Parity3 task 126 (pgBadger General Activity, Histogram of query times): slowLatencyPanel on the instance tab, the
// hourly p90 / p95 / p99 and the duration histogram of the logged statements (/api/slow/percentiles).
import { planLink } from './plan';
import { slowCols } from './borrowed';
import { get, Row, rowsOf, Table } from './api';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';
import { sqlCell, whatIsThis } from './sqlview';
import { trendCol } from './stmt_trend';
import { lineChart } from './chart';
import { zoneName } from './tz';

type Parts = 'meta' | 'sources' | 'totals' | 'histogram' | 'top' | 'recent' | 'sampled' | 'instances';

// byRank: one top list from the reply's rows (each carries its rank by count and by total time).
const byRank = (rows: Row[], key: 'rank_count' | 'rank_total', limit = 50) =>
  rows.filter(r => Number(r[key]) <= limit).sort((a, b) => Number(a[key]) - Number(b[key]));

// the picker's choices in milliseconds; 0 = everything the log holds
export const thresholds: [number, string][] = [
  [0, 'all logged'], [100, '100 ms'], [500, '500 ms'], [1000, '1 s'], [5000, '5 s'], [10000, '10 s'], [30000, '30 s'], [60000, '1 min'],
];
const defaultMs = 1000;

// thresholdOf is the threshold the router carries in the hash (ms=), kept across a range change on this tab.
export function thresholdOf(ctx: Ctx): number {
  return ctx.ms ?? defaultMs;
}

const msTxt = (v: unknown) => {
  if (v == null || v === '') return '';
  const n = Number(v);
  return n >= 60000 ? fmtNum(n / 60000) + ' min' : n >= 1000 ? fmtNum(n / 1000) + ' s' : fmtNum(n) + ' ms';
};
const clip = (v: unknown) => { const s = v == null ? '' : String(v); return s.length > 400 ? s.slice(0, 400) + '...' : s; };
const bands: [string, string, string][] = [
  ['under_1s', 'under 1 s', '#4dabf7'], ['s1_to_10', '1-10 s', '#fab005'], ['s10_to_60', '10-60 s', '#f76707'], ['over_60s', 'over 1 min', '#e03131'],
];

// picker: the threshold choices as links (the current one marked), and the log's own floor.
function picker(ctx: Ctx, ms: number, tab: string): HTMLElement {
  return el('div', { class: 'subtabs' }, el('span', {}, 'Threshold:'), ...thresholds.map(([v, l]) =>
    el('a', { href: href(ctx, { tab, ms: v }), class: v === ms ? 'on' : '' }, l)));
}

// histogram: one row per day, a bar per duration band scaled to the busiest day, the count and the total.
function histogram(rows: Row[], tz: string): HTMLElement {
  if (!rows.length) return el('p', { class: 'empty' }, 'No slow statement in these days.');
  const peak = Math.max(...rows.map(r => Number(r.statements ?? 0)), 1);
  const legend = el('p', { class: 'meta' }, `Per day (${tz}): `, ...bands.flatMap(([, l, c]) => [
    el('span', { style: `display:inline-block;width:10px;height:10px;margin:0 4px 0 10px;background:${c}` }), l]));
  const t = el('table', { class: 'grid' }, el('thead', {}, el('tr', {},
    el('th', {}, 'day'), el('th', {}, 'by duration'), el('th', { class: 'num' }, 'statements'), el('th', { class: 'num' }, 'total time'), el('th', { class: 'num' }, 'longest'))));
  const body = el('tbody');
  for (const r of rows) {
    const bar = el('div', { style: 'display:flex;height:14px;min-width:240px' });
    for (const [k, l, c] of bands) {
      const n = Number(r[k] ?? 0);
      if (!n) continue;
      const seg = el('div', { style: `width:${(100 * n / peak).toFixed(2)}%;background:${c}` });
      seg.title = `${l}: ${fmtNum(n)}`;
      bar.append(seg);
    }
    body.append(el('tr', {}, el('td', {}, String(r.day ?? '')), el('td', {}, bar), el('td', { class: 'num' }, fmtNum(r.statements)),
      el('td', { class: 'num' }, msTxt(r.total_ms)), el('td', { class: 'num' }, msTxt(r.max_ms))));
  }
  t.append(body);
  return el('div', {}, legend, el('div', { class: 'grid-wrap', tabindex: '0' }, t));
}

// topCols: a shape's figures, its example and the link to the Statements tab of its instance.
function topCols(ctx: Ctx, lead: 'count' | 'total', fleet: boolean, instLink?: (name: string, id: unknown) => Node): Col[] {
  const count: Col = { key: 'statements', label: 'count', num: true };
  const total: Col = { key: 'total_ms', label: 'total time', num: true, fmt: msTxt };
  const cols: Col[] = [lead === 'count' ? count : total, lead === 'count' ? total : count,
    { key: 'mean_ms', label: 'mean', num: true, fmt: msTxt }, { key: 'max_ms', label: 'longest', num: true, fmt: msTxt },
    { key: 'last_at', label: 'last', fmt: fmtTime }, { key: 'databases', label: 'db' }, { key: 'users', label: 'user' },
    { key: 'queryid', label: 'statement', fmt: (v, r) => el('a', { href: href(ctx, { tab: 'statements', instance: Number(r.instance_id), tag: undefined }) },
      v == null ? 'Statements tab' : 'queryid ' + String(v)) },
    { key: 'example', label: 'slowest example', wide: true, fmt: clip },
    { key: 'shape_key', label: 'plan', fmt: (v, r) => planLink(Number(r.instance_id), { shape: v, stmt: r.example, db: String(r.databases ?? '').split(', ')[0] }) },
    trendCol(ctx, r => r.shape_key == null || r.instance_id == null ? null
      : { instance: Number(r.instance_id), shape: r.shape_key, min: thresholdOf(ctx), label: String(r.example ?? '').slice(0, 60) })];
  if (fleet) cols.unshift({ key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') });
  return cols;
}

// sourcesNote: which reader feeds this instance and how its last run ended (a skip names its reason).
function sourceCols(fleet: boolean, instLink?: (name: string, id: unknown) => Node): Col[] {
  const cols: Col[] = [
    { key: 'reader', fmt: v => v === 'serverlog' ? 'server log files' : v === 'logs' ? 'CloudWatch' : 'none' },
    { key: 'status', fmt: v => v == null ? '' : badge(String(v), v === 'ok' ? 'ok' : v === 'skipped' ? 'warn' : v === 'partial' ? 'warn' : 'crit') },
    { key: 'note', label: 'reason', wide: true },
    { key: 'last_run', label: 'last run', fmt: fmtTime },
    { key: 'log_min_duration_statement', label: 'log_min_duration_statement' },
    { key: 'last_slow_at', label: 'newest slow statement', fmt: fmtTime },
  ];
  if (fleet) cols.unshift({ key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') }, { key: 'platform' });
  return cols;
}

const recentCols: Col[] = [
  { key: 'at', fmt: fmtTime }, { key: 'duration_ms', label: 'duration', num: true, fmt: msTxt }, { key: 'pid', num: true },
  { key: 'datname', label: 'db' }, { key: 'usename', label: 'user' }, { key: 'client' }, { key: 'reader' },
  { key: 'statement', wide: true, fmt: clip },
];

const tzOf = () => zoneName();   // the display zone (tz.ts): the server cuts its hours and days on that clock

function floorNote(src: Row[], ms: number): string {
  const floors = [...new Set(src.map(s => s.log_min_duration_statement).filter(v => v != null).map(String))];
  return `Statements the server logged at or over ${msTxt(ms) || '0 ms'} `
    + `(log_min_duration_statement ${floors.length ? floors.join(', ') : 'unknown'}: a statement under it is never logged, and -1 logs none). `
    + 'A shape groups the statements whose text differs only in literals and parameters; the queryid is the pg_stat_statements row of the same shape.';
}

export async function slowView(ctx: Ctx): Promise<HTMLElement> {
  const ms = thresholdOf(ctx), tz = tzOf();
  const d = await get<Record<Parts, Table | null>>('slowqueries', { instance: ctx.instance, ...window_(ctx), min: ms, tz });
  const src = rowsOf(d.sources), hist = rowsOf(d.histogram), top = rowsOf(d.top);
  const byCount = byRank(top, 'rank_count'), byTotal = byRank(top, 'rank_total');
  const recent = rowsOf(d.recent), sampled = rowsOf(d.sampled);
  const meta = rowsOf(d.meta)[0] ?? {}, tot = rowsOf(d.totals)[0] ?? {};
  const n = Number(tot.statements ?? 0);
  const fed = src.filter(s => s.reader != null);
  // the log's floor note is the title of a 'what is this' link beside the heading, not a paragraph (one-line pages)
  const sec = el('section', {}, el('h2', {}, `Slow queries (${rangeLabel(ctx)}) `, whatIsThis(floorNote(src, ms), 'What the log holds')), picker(ctx, ms, ctx.tab));
  sec.append(el('div', { class: 'tiles' },
    tile('slow statements', fmtNum(n), n ? 'warn' : ''),
    tile('shapes', fmtNum(tot.shapes ?? 0)),
    tile('total time', msTxt(tot.total_ms) || '0 ms'),
    tile('longest', msTxt(tot.max_ms) || '-'),
    tile('long runs sampled', fmtNum(sampled.length))));
  sec.append(slowGroupsPanel(ctx));
  sec.append(el('h3', {}, 'Log readers'), fed.length ? grid(fed, sourceCols(false))
    : el('p', { class: 'empty' }, 'No log reader has run on this instance: RDS and Aurora need an aws: block (the logs collection); '
      + 'on-prem the serverlog collection needs logging_collector on and a read door (its last run names what is missing).'));
  sec.append(el('h3', {}, `Per day since ${fmtTime(meta.histogram_from)}`), histogram(hist, String(meta.tz ?? tz)));
  sec.append(slowLatencyPanel(ctx));
  sec.append(el('h3', {}, 'Top by count'), grid(byCount, topCols(ctx, 'count', false), 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Top by total time'), grid(byTotal, topCols(ctx, 'total', false), 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Newest slow statements'), grid(recent, recentCols, 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Long runs seen by the activity sampler ', whatIsThis('From the activity samples, not the log: an execution seen running at least the threshold (whole seconds, at least 1 s); '
      + 'sampled, so the duration is a floor. It also catches a statement the log missed (still running, or under log_min_duration_statement).', 'Long runs seen by the activity sampler')),
    grid(sampled, slowCols, 'No execution seen running that long in this window.'));
  return sec;
}

// slowFleetView: the fleet root (keep narrows it to a tag folder; instLink makes an instance name a link to its tab).
export async function slowFleetView(ctx: Ctx, keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const ms = thresholdOf(ctx), tz = tzOf();
  const d = await get<Record<Parts, Table | null>>('slowqueries', { ...window_(ctx), min: ms, tz, limit: keep ? 500 : 50 });
  const k = (rows: Row[]) => keep ? rows.filter(keep) : rows;
  // under a tag folder the fleet's ranks are re-counted over the folder's rows
  const rerank = (rows: Row[], key: 'rank_count' | 'rank_total') => [...rows].sort((a, b) => Number(a[key]) - Number(b[key])).slice(0, 50);
  const top = k(rowsOf(d.top));
  const insts = k(rowsOf(d.instances)), byCount = rerank(top, 'rank_count'), byTotal = rerank(top, 'rank_total');
  const src = k(rowsOf(d.sources)), meta = rowsOf(d.meta)[0] ?? {};
  const n = insts.reduce((a, r) => a + Number(r.statements ?? 0), 0);
  const skipped = src.filter(s => s.status === 'skipped' || s.status === 'error').length;
  const unread = src.filter(s => s.reader == null).length;
  // the log's floor note is the title of a 'what is this' link beside the heading, not a paragraph (one-line pages)
  const sec = el('section', {}, el('h2', {}, `Slow queries (${rangeLabel(ctx)}) `, whatIsThis(floorNote(src, ms), 'What the log holds')), picker(ctx, ms, ctx.tab));
  sec.append(el('div', { class: 'tiles' },
    tile('slow statements', fmtNum(n), n ? 'warn' : ''),
    tile('instances with slow statements', fmtNum(insts.length)),
    tile('readers skipped or failing', fmtNum(skipped), skipped ? 'warn' : 'ok'),
    tile('instances without a log reader', fmtNum(unread))));
  sec.append(slowGroupsPanel(ctx, { keep, instLink }));
  sec.append(el('h3', {}, 'Per instance'), grid(insts, [
    { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') }, { key: 'platform' },
    { key: 'statements', label: 'count', num: true }, { key: 'total_ms', label: 'total time', num: true, fmt: msTxt },
    { key: 'max_ms', label: 'longest', num: true, fmt: msTxt }, { key: 'last_at', label: 'last', fmt: fmtTime },
  ], 'No slow statement in this window.'));
  // the histogram is the whole fleet's; under a tag folder it says so rather than mixing scopes
  sec.append(el('h3', {}, `Per day since ${fmtTime(meta.histogram_from)}${keep ? ' (the whole fleet)' : ''}`), histogram(rowsOf(d.histogram), String(meta.tz ?? tz)));
  sec.append(el('h3', {}, 'Top by count'), grid(byCount, topCols(ctx, 'count', true, instLink), 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Top by total time'), grid(byTotal, topCols(ctx, 'total', true, instLink), 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Log readers'), props([
    ['RDS and Aurora', 'the logs collection: the postgresql log in CloudWatch Logs (an aws: block in the config)'],
    ['on-prem', 'the serverlog collection: logging_collector on, and a read door for the monitoring login'],
    ['the read door', 'recommended: the function pgvigil_read_log (SECURITY DEFINER, owned by a superuser), which serves only the files pg_ls_logdir() lists; '
      + 'the wide fallback: GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean), which also opens every file under '
      + 'the data directory (pg_hba.conf, server.key, the password hashes of pg_authid). pg_read_server_files alone opens neither.'],
  ]),
  grid(src, sourceCols(true, instLink), 'No instance.'));
  return sec;
}

// ---- DBA Dash's Slow Queries grid: Group By, the database filter, the buckets and the events behind a count ------

// the buckets as DBA Dash names them (pgvigil.slow_bucket, 0076)
export const slowBuckets = ['<5 sec', '5-10 sec', '10-20 sec', '20-30 sec', '30-60 sec', '1-5 min', '5-10 min', '10-30 min', '30-60 min', '1hr+'];
// the Group By choices (DBA Dash 04a's menu; Time - Custom is the page's own range)
export const slowGroupBy: [string, string][] = [
  ['instance', 'Instance'], ['database', 'Database Name'], ['app', 'App'], ['user', 'Username'], ['client', 'Client'],
  ['event_type', 'Event Type'], ['object', 'Object Name'], ['result', 'Result'], ['session', 'Session ID'], ['text', 'Text'],
  ['hour', 'Time - Hour'], ['day', 'Time - Day'], ['engine', 'Engine'],
];
const topChoices = [20, 50, 100, 500];
const secs = (v: unknown) => v == null || v === '' ? '' : fmtNum(v);
const resultBadge = (v: unknown) => v == null ? '' : badge(String(v), v === 'OK' ? 'ok' : 'crit');

export interface SlowGroupsOpts {
  keep?: (r: Row) => boolean;                          // a tag folder: only these instances (the fleet root)
  instLink?: (name: string, id: unknown) => Node;      // an instance name as a link to its tab
}

// slowGroupsPanel: the grid and its drill; its own state (group, database, top) lives in the panel, not the hash.
export function slowGroupsPanel(ctx: Ctx, o: SlowGroupsOpts = {}): HTMLElement {
  const fleet = !ctx.instance;
  let group = fleet ? 'instance' : 'database', db = '', top = 20, events_ = 'calls';
  // a reply that arrives after a newer request was sent is dropped (a quick change of Group By, two count clicks)
  let drawSeq = 0, drillSeq = 0;
  // the window is taken once per drawing, so a count and its drill read the same window
  let win = window_(ctx);
  const tz = tzOf(), ms = thresholdOf(ctx);
  const box = el('div', { class: 'slow-groups' });
  const body = el('div'), drill = el('div', { 'aria-live': 'polite' });
  const select = (label: string, choices: [string, string][], cur: string, on: (v: string) => void) => {
    const s = el('select', { 'aria-label': label });
    for (const [v, l] of choices) { const op = el('option', { value: v }, l); if (v === cur) op.selected = true; s.append(op); }
    s.addEventListener('change', () => on(s.value));
    return el('label', {}, label + ' ', s);
  };
  const base = () => ({ instance: ctx.instance, ...win, min: ms, tz, group, db: db || undefined, events: events_ });
  const noneLabel = () => group === 'app' ? '(none: the PostgreSQL log names no application)' : '(none)';
  const valueLabel = (v: unknown) => v == null ? noneLabel() : v === '' ? '(empty)' : String(v);

  async function events(r: Row | null, bucket?: number, failed = false) {
    const what = (r ? valueLabel(r.value) : 'every group')
      + (bucket != null ? `, ${slowBuckets[bucket]}` : '') + (failed ? ', failed' : '');
    const seq = ++drillSeq, gseq = drawSeq;
    drill.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    try {
      const p: Record<string, string | number | undefined> = { ...base() };
      // the query string cannot carry an empty value (get() drops it): the empty-string group is blank=1
      if (r) { if (r.value == null) p.null = 1; else if (r.value === '') p.blank = 1; else p.value = String(r.value); }
      if (bucket != null) p.bucket = bucket;
      if (failed) p.failed = 1;
      const d = await get<Record<'events' | 'meta', Table | null>>('slow/events', p);
      if (seq !== drillSeq || gseq !== drawSeq) return;
      const rows = rowsOf(d.events), m = rowsOf(d.meta)[0] ?? {};
      const cols: Col[] = [
        ...(fleet ? [{ key: 'instance', fmt: (v: unknown, x: Row) => o.instLink ? o.instLink(String(v), x.instance_id) : String(v ?? '') } as Col] : []),
        { key: 'database_name', label: 'database' }, { key: 'event_type', label: 'event type' }, { key: 'object_name', label: 'object' },
        { key: 'at', label: 'time', fmt: fmtTime }, { key: 'duration_ms', label: 'duration', num: true, fmt: msTxt },
        { key: 'cpu_ms', label: 'CPU', num: true, fmt: msTxt }, { key: 'logical_reads', label: 'logical reads', num: true },
        { key: 'physical_reads', label: 'physical reads', num: true }, { key: 'writes', num: true }, { key: 'row_count', label: 'rows', num: true },
        { key: 'user_name', label: 'user' }, { key: 'client' },
        { key: 'application', label: 'app', fmt: (v, x) => v == null ? '' : x.application_from === 'sample' ? `${String(v)} (sampled)` : String(v) },
        { key: 'result', fmt: resultBadge }, { key: 'session_id', label: 'session', num: true },
        { key: 'statement', fmt: v => sqlCell(v) },
        trendCol(ctx, x => x.shape_key == null ? null : { instance: Number(x.instance_id), shape: x.shape_key, min: ms, label: String(x.statement ?? '').slice(0, 60) }),
      ];
      const shown = o.keep ? rows.filter(o.keep) : rows;
      const counted = `${fmtNum(m.matched ?? 0)}${Number(m.matched) > Number(m.shown) ? ', the longest ' + fmtNum(m.shown) + ' read' : ''}`;
      // under a tag folder the cell counts the fleet; the list keeps the folder's instances
      const note = o.keep ? ` (${counted} in the fleet; ${fmtNum(shown.length)} of this folder's instances listed)` : ` (${counted})`;
      drill.replaceChildren(el('h4', {}, `Events: ${what}${note}`), grid(shown, cols, 'No event of this folder\'s instances in this cell.'));
    } catch (e) {
      if (seq === drillSeq) drill.replaceChildren(errorBox(e));
    }
  }

  // a count as a button that fills the events grid (an empty cell stays empty, as in DBA Dash)
  const countBtn = (n: unknown, r: Row | null, bucket?: number, failed = false, crit = false) => {
    if (!Number(n)) return '';
    const name = `${fmtNum(n)} ${failed ? 'failed ' : ''}events, ${r ? valueLabel(r.value) : 'all groups'}${bucket != null ? ', ' + slowBuckets[bucket] : ''}: list them`;
    const b = el('button', { type: 'button', class: 'link', 'aria-label': name }, fmtNum(n));
    if (crit) b.style.color = 'var(--crit)';
    b.addEventListener('click', () => { void events(r, bucket, failed); });
    return b;
  };

  async function draw() {
    const seq = ++drawSeq;
    win = window_(ctx);
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    drill.replaceChildren();
    try {
      const d = await get<Record<'groups' | 'totals' | 'dbs', Table | null>>('slow/groups', { ...base(), top: o.keep ? 500 : top });
      if (seq !== drawSeq) return;
      let rows = rowsOf(d.groups);
      // under a tag folder an instance group is kept when it is one of the folder's (other groups mix instances)
      if (o.keep && group === 'instance') rows = rows.filter(o.keep).slice(0, top);
      else if (o.keep) rows = rows.slice(0, top);
      const tot = rowsOf(d.totals)[0] ?? {};
      const dbs = rowsOf(d.dbs).map(r => [String(r.database), `${String(r.database)} (${fmtNum(r.events)})`] as [string, string]);
      const valueCol: Col = {
        key: 'value', label: slowGroupBy.find(g => g[0] === group)?.[1] ?? group, wide: group === 'text',
        fmt: (v, r) => v == null || v === '' ? valueLabel(v)
          : group === 'text' ? sqlCell(r.example)
          : group === 'instance' && o.instLink && r.instance_id != null ? o.instLink(String(v), r.instance_id) : String(v),
      };
      const cols: Col[] = [valueCol,
        ...slowBuckets.map((l, i) => ({ key: 'b' + i, label: l, num: true, fmt: (v: unknown, r: Row) => countBtn(v, r, i) } as Col)),
        { key: 'total', label: 'Total', num: true, fmt: (v, r) => countBtn(v, r) },
        { key: 'failed', label: 'Failed', num: true, fmt: (v, r) => countBtn(v, r, undefined, true, true) },
        { key: 'total_duration_s', label: 'Total Duration (sec)', num: true, fmt: secs },
        { key: 'total_cpu_s', label: 'Total CPU (sec)', num: true, fmt: secs },
        { key: 'logical_reads', label: 'Logical reads', num: true }, { key: 'physical_reads', label: 'Physical reads', num: true },
        { key: 'writes', label: 'Writes', num: true },
      ];
      if (group === 'text') cols.push(trendCol(ctx, r => r.instance_id == null || r.value == null ? null
        : { instance: Number(r.instance_id), shape: r.value, min: ms, label: String(r.example ?? '').slice(0, 60) }));
      const totalRow: Row = { ...tot, value: 'All' };
      const totCols: Col[] = [{ key: 'value', label: '' },
        ...slowBuckets.map((l, i) => ({ key: 'b' + i, label: l, num: true, fmt: (v: unknown) => countBtn(v, null, i) } as Col)),
        { key: 'total', label: 'Total', num: true, fmt: v => countBtn(v, null) },
        { key: 'failed', label: 'Failed', num: true, fmt: v => countBtn(v, null, undefined, true, true) },
        { key: 'total_duration_s', label: 'Total Duration (sec)', num: true, fmt: secs }, { key: 'total_cpu_s', label: 'Total CPU (sec)', num: true, fmt: secs },
        { key: 'groups', label: 'groups', num: true }];
      body.replaceChildren(
        el('div', { class: 'toolbar' },
          select('Group By', slowGroupBy, group, v => { group = v; void draw(); }),
          select('Database', [['', 'all databases'], ...dbs], db, v => { db = v; void draw(); }),
          select('Top', topChoices.map(n => [String(n), String(n)] as [string, string]), String(top), v => { top = Number(v); void draw(); }),
          select('Events', [['calls', 'calls (DBA Dash)'], ['all', 'calls and their statements']], events_, v => { events_ = v; void draw(); })),
        o.keep ? el('p', { class: 'meta' }, group === 'instance' ? 'Under a tag folder the grid keeps the folder\'s instances; the All row counts the whole fleet.'
          : 'Under a tag folder only Group By Instance keeps the folder\'s instances: this grouping and the All row count the whole fleet.') : '',
        grid(rows, cols, 'No slow event in this window.'),
        Number(tot.total) ? grid([totalRow], totCols) : '');
    } catch (e) {
      if (seq === drawSeq) body.replaceChildren(errorBox(e));
    }
  }
  box.append(el('h3', {}, 'Group by ', whatIsThis('Both engines: the PostgreSQL server log (a statement that finished; the log names no application, '
    + 'so a drilled event shows the application the activity sampler saw for its pid during the run, marked sampled) and the SQL Server slow '
    + 'capture (rpc, batch and statement completions with CPU, reads, writes, rows and the result). Every count opens its events below, '
    + 'the longest first. Failed: a SQL Server result other than OK (Error, Abort). Events: SQL Server stores a slow procedure call and, '
    + 'with the statement events on, its slow statements too; calls (the default) counts each call once, as DBA Dash does.', 'Slow queries by group')), body, drill);
  void draw();
  return box;
}

// ---- pgBadger's latency view (parity3 task 126): hourly p90 / p95 / p99 and the duration histogram ---------------

const pctCols: Col[] = [
  { key: 'hour' },
  { key: 'statements', label: 'count', num: true },
  { key: 'min_ms', label: 'min', num: true, fmt: msTxt }, { key: 'max_ms', label: 'max', num: true, fmt: msTxt },
  { key: 'avg_ms', label: 'mean', num: true, fmt: msTxt },
  { key: 'p90_ms', label: 'p90', num: true, fmt: msTxt }, { key: 'p95_ms', label: 'p95', num: true, fmt: msTxt },
  { key: 'p99_ms', label: 'p99', num: true, fmt: msTxt },
];

// durationHistogram: pgBadger's ten buckets as rows, a bar per bucket scaled to the largest share.
function durationHistogram(rows: Row[]): HTMLElement {
  const peak = Math.max(...rows.map(r => Number(r.pct ?? 0)), 1);
  const t = el('table', { class: 'grid' }, el('thead', {}, el('tr', {},
    el('th', {}, 'duration'), el('th', { class: 'num' }, 'statements'), el('th', { class: 'num' }, 'share'), el('th', {}, ''), el('th', { class: 'num' }, 'total time'))));
  const body = el('tbody');
  for (const r of rows) {
    const bar = el('div', { style: `height:12px;min-width:2px;width:${(100 * Number(r.pct ?? 0) / peak).toFixed(2)}%;background:var(--accent, #4dabf7)` });
    body.append(el('tr', {}, el('td', {}, String(r.label ?? '')), el('td', { class: 'num' }, fmtNum(r.statements)),
      el('td', { class: 'num' }, r.pct == null ? '' : fmtNum(r.pct) + ' %'), el('td', { style: 'min-width:240px' }, Number(r.statements) ? bar : ''),
      el('td', { class: 'num' }, msTxt(r.total_ms))));
  }
  t.append(body);
  return el('div', { class: 'grid-wrap', tabindex: '0' }, t);
}

// slowLatencyPanel: the logged statements' hourly percentiles and their duration histogram over the window, at the
// page's threshold. Every figure is of the statements the server logged, so the floor is said beside the heading.
export function slowLatencyPanel(ctx: Ctx): HTMLElement {
  const ms = thresholdOf(ctx), tz = tzOf();
  const box = el('div', { class: 'slow-latency' });
  const body = el('div', {}, el('p', { class: 'meta' }, 'Reading...'));
  box.append(el('h3', {}, 'Latency of the logged statements ', whatIsThis('Of the statements the server logged (log_min_duration_statement), at or over the '
    + 'threshold picked above: a statement under the server\'s floor is never in the log, so these are the percentiles of the logged statements, '
    + 'not of every statement the server ran. p90 / p95 / p99 are nearest-rank: the smallest logged duration with at least that share of the hour\'s '
    + 'statements at or under it (pgBadger\'s General Activity). The histogram uses pgBadger\'s buckets.', 'Latency of the logged statements')), body);
  void (async () => {
    try {
      const d = await get<Record<'hours' | 'histogram' | 'meta', Table | null>>('slow/percentiles', { instance: ctx.instance, ...window_(ctx), min: ms, tz });
      const hours = rowsOf(d.hours), m = rowsOf(d.meta)[0] ?? {};
      const floor = m.log_min_duration_statement == null ? 'unknown' : String(m.log_min_duration_statement);
      body.replaceChildren(
        el('p', { class: 'meta' }, `${fmtNum(m.statements ?? 0)} logged statement(s) at or over ${msTxt(ms) || '0 ms'}; the server's log_min_duration_statement `
          + `${floor} (as last read; a database or role setting can differ), hours in ${String(m.tz ?? tz)}.`),
        el('div', { class: 'charts' }, lineChart('Logged statement latency per hour', hours.map(r => ({ ...r, snapshot_at: r.hour_start })),
          [{ key: 'p90_ms', label: 'p90' }, { key: 'p95_ms', label: 'p95' }, { key: 'p99_ms', label: 'p99' }], v => msTxt(v))),
        grid(hours, pctCols, 'No logged statement in this window.'),
        el('h4', {}, 'Duration histogram'), durationHistogram(rowsOf(d.histogram)));
    } catch (e) {
      body.replaceChildren(errorBox(e));
    }
  })();
  return box;
}
