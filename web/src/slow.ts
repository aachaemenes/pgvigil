// The Slow queries tab and its fleet root (task 36; DBADash's slow queries): the statements the server log
// recorded over log_min_duration_statement (the CloudWatch reader on RDS and Aurora, the server-log file
// reader on-prem), with a threshold picker, a per-day histogram by duration band, the top statement shapes
// by count and by total time (each linked to the Statements tab, with the pg_stat_statements queryid of the
// same shape where there is one), the newest slow statements, and the activity sampler's long runs. At the
// root the fleet's shapes and the slow time per instance. Data from /api/slowqueries. The shell mounts
// slowView(ctx) on the instance tab and slowFleetView(ctx, keep, instLink) on the root (the lead wires them).
// The threshold rides in the hash as ms= (read and written here; the router does not carry it).
import { slowCols } from './borrowed';
import { get, Row, rowsOf, Table } from './api';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid, props, tile } from './ui';

type Parts = 'meta' | 'sources' | 'histogram' | 'top_count' | 'top_total' | 'recent' | 'sampled' | 'instances';

// the picker's choices in milliseconds; 0 = everything the log holds
export const thresholds: [number, string][] = [
  [0, 'all logged'], [100, '100 ms'], [500, '500 ms'], [1000, '1 s'], [5000, '5 s'], [10000, '10 s'], [30000, '30 s'], [60000, '1 min'],
];
const defaultMs = 1000;

// thresholdOf reads ms= from the hash (the router keeps the rest).
export function thresholdOf(): number {
  const q = new URLSearchParams(location.hash.split('?')[1] ?? '');
  const v = Number(q.get('ms'));
  return q.has('ms') && Number.isFinite(v) && v >= 0 && v <= 86400000 ? Math.trunc(v) : defaultMs;
}

function withMs(link: string, ms: number): string {
  const [p, qs] = link.split('?');
  const q = new URLSearchParams(qs ?? '');
  q.set('ms', String(ms));
  return `${p}?${q}`;
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
    el('a', { href: withMs(href(ctx, { tab }), v), class: v === ms ? 'on' : '' }, l)));
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
  return el('div', {}, legend, el('div', { class: 'grid-wrap' }, t));
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
    { key: 'example', label: 'slowest example', wide: true, fmt: clip }];
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

const tzOf = () => { try { return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'; } catch { return 'UTC'; } };

function floorNote(src: Row[], ms: number): string {
  const floors = [...new Set(src.map(s => s.log_min_duration_statement).filter(v => v != null).map(String))];
  return `Statements the server logged at or over ${msTxt(ms) || '0 ms'} `
    + `(log_min_duration_statement ${floors.length ? floors.join(', ') : 'unknown'}: a statement under it is never logged, and -1 logs none). `
    + 'A shape groups the statements whose text differs only in literals and parameters; the queryid is the pg_stat_statements row of the same shape.';
}

export async function slowView(ctx: Ctx): Promise<HTMLElement> {
  const ms = thresholdOf(), tz = tzOf();
  const d = await get<Record<Parts, Table | null>>('slowqueries', { instance: ctx.instance, ...window_(ctx), min: ms, tz });
  const src = rowsOf(d.sources), hist = rowsOf(d.histogram), byCount = rowsOf(d.top_count), byTotal = rowsOf(d.top_total);
  const recent = rowsOf(d.recent), sampled = rowsOf(d.sampled);
  const meta = rowsOf(d.meta)[0] ?? {};
  const n = byCount.reduce((a, r) => a + Number(r.statements ?? 0), 0);
  const total = byCount.reduce((a, r) => a + Number(r.total_ms ?? 0), 0);
  const longest = byCount.reduce((a, r) => Math.max(a, Number(r.max_ms ?? 0)), 0);
  const fed = src.filter(s => s.reader != null);
  const sec = el('section', {}, el('h2', {}, `Slow queries (${rangeLabel(ctx)})`), picker(ctx, ms, ctx.tab));
  sec.append(el('div', { class: 'tiles' },
    tile('slow statements', fmtNum(n), n ? 'warn' : ''),
    tile('shapes', fmtNum(byCount.length)),
    tile('total time', msTxt(total) || '0 ms'),
    tile('longest', msTxt(longest) || '-'),
    tile('long runs sampled', fmtNum(sampled.length))));
  sec.append(el('p', { class: 'meta' }, floorNote(src, ms)));
  sec.append(el('h3', {}, 'Log readers'), fed.length ? grid(fed, sourceCols(false))
    : el('p', { class: 'empty' }, 'No log reader has run on this instance: RDS and Aurora need an aws: block (the logs collection); '
      + 'on-prem the serverlog collection needs logging_collector on and the read grant (its last run names what is missing).'));
  sec.append(el('h3', {}, `Per day since ${fmtTime(meta.histogram_from)}`), histogram(hist, String(meta.tz ?? tz)));
  sec.append(el('h3', {}, 'Top by count'), grid(byCount, topCols(ctx, 'count', false), 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Top by total time'), grid(byTotal, topCols(ctx, 'total', false), 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Newest slow statements'), grid(recent, recentCols, 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Long runs seen by the activity sampler'),
    el('p', { class: 'meta' }, 'From the activity samples, not the log: an execution seen running at least the threshold (whole seconds, at least 1 s); '
      + 'sampled, so the duration is a floor. It also catches a statement the log missed (still running, or under log_min_duration_statement).'),
    grid(sampled, slowCols, 'No execution seen running that long in this window.'));
  return sec;
}

// slowFleetView: the fleet root (keep narrows it to a tag folder; instLink makes an instance name a link to its tab).
export async function slowFleetView(ctx: Ctx, keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const ms = thresholdOf(), tz = tzOf();
  const d = await get<Record<Parts, Table | null>>('slowqueries', { ...window_(ctx), min: ms, tz, limit: keep ? 500 : 50 });
  const k = (rows: Row[]) => keep ? rows.filter(keep) : rows;
  const insts = k(rowsOf(d.instances)), byCount = k(rowsOf(d.top_count)).slice(0, 50), byTotal = k(rowsOf(d.top_total)).slice(0, 50);
  const src = k(rowsOf(d.sources)), meta = rowsOf(d.meta)[0] ?? {};
  const n = insts.reduce((a, r) => a + Number(r.statements ?? 0), 0);
  const skipped = src.filter(s => s.status === 'skipped' || s.status === 'error').length;
  const unread = src.filter(s => s.reader == null).length;
  const sec = el('section', {}, el('h2', {}, `Slow queries (${rangeLabel(ctx)})`), picker(ctx, ms, ctx.tab));
  sec.append(el('div', { class: 'tiles' },
    tile('slow statements', fmtNum(n), n ? 'warn' : ''),
    tile('instances with slow statements', fmtNum(insts.length)),
    tile('readers skipped or failing', fmtNum(skipped), skipped ? 'warn' : 'ok'),
    tile('instances without a log reader', fmtNum(unread))));
  sec.append(el('p', { class: 'meta' }, floorNote(src, ms)));
  sec.append(el('h3', {}, 'Per instance'), grid(insts, [
    { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') }, { key: 'platform' },
    { key: 'statements', label: 'count', num: true }, { key: 'total_ms', label: 'total time', num: true, fmt: msTxt },
    { key: 'max_ms', label: 'longest', num: true, fmt: msTxt }, { key: 'last_at', label: 'last', fmt: fmtTime },
  ], 'No slow statement in this window.'));
  // the histogram is the whole fleet's; under a tag folder it says so rather than mixing scopes
  sec.append(el('h3', {}, `Per day since ${fmtTime(meta.histogram_from)}${keep ? ' (the whole fleet)' : ''}`), histogram(rowsOf(d.histogram), String(meta.tz ?? tz)));
  sec.append(el('h3', {}, 'Top by count'), grid(byCount, topCols(ctx, 'count', true, instLink), 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Top by total time'), grid(byTotal, topCols(ctx, 'total', true, instLink), 'No slow statement in this window.'));
  sec.append(el('h3', {}, 'Log readers'), props([['what feeds this', 'RDS and Aurora: the logs collection (CloudWatch Logs, an aws: block). '
    + 'On-prem: the serverlog collection (logging_collector on, GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text, bigint, bigint, boolean) to the monitoring login).']]),
  grid(src, sourceCols(true, instLink), 'No instance.'));
  return sec;
}
