// The Performance summary (plan task 108): DBA Dash's Performance Summary for both engines, one row per instance in
// the scope over the range, every column sortable by a header click. A cell carries a status fill only past its line
// (the thresholds below, listed under the page's 'thresholds' link); every other cell is plain. A value the
// repository does not hold is a muted word ('no host read', 'not read'), never a zero. Data from /api/perfsummary.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, href, rangeLabel, window_ } from './router';
import { Col, el, fmtBytes, fmtNum, fmtSecs, grid } from './ui';

interface Data { pg: Table | null; mssql: Table | null }

// the lines a value must pass for a fill: [warning, critical]
export const thresholds = {
  cpu_max: [75, 90] as const,     // %
  lock_ms_s: [100, 1000] as const, // ms of lock wait per second
};

const lvl = (v: unknown, t: readonly [number, number]) => v == null ? '' : Number(v) > t[1] ? 'crit' : Number(v) > t[0] ? 'warn' : '';
const muted = (t: string, why: string) => el('span', { class: 'meta', title: why }, t);
const isMs = (r: Row) => r.engine === 'sqlserver';

// a data bar: the value's share of 100 %, the number beside it (a bar alone never carries the value)
function dataBar(v: unknown, level: string): Node {
  const n = Number(v);
  const fill = el('span', { class: 'bar-fill ' + (level || 'plain') });
  fill.style.width = Math.max(0.5, Math.min(100, n)).toFixed(1) + '%';
  if (!level) fill.style.background = 'var(--accent)';
  const bar = el('span', { class: 'bar', 'aria-hidden': 'true' }, fill);
  bar.style.cssText = 'display:inline-block;width:3.5rem;height:.7rem;vertical-align:middle;margin-right:.3rem';
  return el('span', { style: 'white-space:nowrap' }, bar,
    el('span', {}, fmtNum(n) + ' %' + (level === 'crit' ? ' critical' : level === 'warn' ? ' warning' : '')));
}

// the CPU histogram: ten bars for the share of samples in each 10 % bucket; only the buckets from 70 % up are coloured
function histogram(h: unknown): Node {
  const counts = Array.isArray(h) ? h.map(Number) : [];
  const total = counts.reduce((a, b) => a + b, 0);
  if (!total) return muted('-', 'no CPU sample in the range');
  const share = counts.map(c => 100 * c / total);
  const label = share.map((s, i) => `${i * 10}-${i * 10 + 10} %: ${Math.round(s)} %`).join(', ');
  const box = el('span', { style: 'display:inline-flex;align-items:flex-end;gap:1px;height:1.4rem;width:6rem;border-bottom:1px solid var(--line)', role: 'img', 'aria-label': 'share of CPU samples per 10 % bucket: ' + label, title: label });
  share.forEach((s, i) => {
    const b = el('span');
    b.style.cssText = 'flex:1;background:' + (i >= 9 ? 'var(--crit)' : i >= 7 ? 'var(--warn)' : 'var(--muted)');
    b.style.height = Math.max(s > 0 ? 2 : 0, s).toFixed(0) + '%';
    box.append(b);
  });
  return box;
}

const ms = (v: unknown) => v == null ? '' : fmtNum(v);
// a value the repository does not hold: SQL Server 'not read' (no collector yet), PostgreSQL the reason it is missing
const absent = (r: Row, why: string, msWhy = 'no mssql_cpu / mssql_fileio read in the range') => isMs(r) ? muted('not read', msWhy) : muted('not read', why);
// a column one engine has no figure for
const na = (what: string) => muted('n/a', what);
// a wait class with no figure: the activity estimate gives Lock alone; no wait read at all = not read
const waitCell = (v: unknown, r: Row) => v != null ? ms(v)
  : r.wait_source === 'activity' ? muted('n/a', 'pg_wait_sampling is not installed: the activity samples give the Lock estimate only')
  : muted('not read', 'no wait read in the range');
const STALE_SECS = 180;

export async function perfSummaryView(ctx: Ctx): Promise<HTMLElement> {
  const win = window_(ctx);
  const d = await get<Data>('perfsummary', { ...win, tag: ctx.tag });
  const end = Date.parse(win.to);
  // the 'now' columns: the newest snapshot inside the range; one older than three minutes before the range's end is
  // not now (a collection that stopped) and its figures are not shown as current
  const nowCell = (v: unknown, r: Row, f: (x: unknown) => string) => {
    if (r.now_at == null) return muted('not read', 'no snapshot in the range');
    const age = Math.max(0, (end - Date.parse(String(r.now_at))) / 1000);
    if (age > STALE_SECS) return muted('stale', `the newest snapshot in the range is ${fmtSecs(age)} older than its end`);
    return el('span', { title: `snapshot ${fmtSecs(age)} before the range's end` }, v == null ? '' : f(v));
  };
  const rows = [...rowsOf(d.pg), ...rowsOf(d.mssql)];
  const sec = el('section', {}, el('h2', {}, `Performance summary (${rangeLabel(ctx)})${ctx.tag ? ' - tag ' + ctx.tag : ''}`));
  const th = el('details', {}, el('summary', {}, 'thresholds'), el('ul', {},
    el('li', {}, `CPU max: warning over ${thresholds.cpu_max[0]} %, critical over ${thresholds.cpu_max[1]} %`),
    el('li', {}, `Lock wait: warning over ${thresholds.lock_ms_s[0]} ms/sec, critical over ${thresholds.lock_ms_s[1]} ms/sec`),
    el('li', {}, 'every other cell is plain; a value not held is a muted word, never 0'),
    el('li', {}, 'waits: PostgreSQL wait_sample (pg_wait_sampling) by event type; without it Lock alone, from the sessions seen waiting each minute; SQL Server by wait category'),
    el('li', {}, 'SQL Server: CPU from the scheduler monitor (the machine; the SQL Server share in the cell\'s title), transactions/s from Transactions/sec, IO from sys.dm_io_virtual_file_stats; memory columns are SQL Server only')));
  sec.append(th);
  const link = (r: Row, tab: string) => el('a', { href: href(ctx, { tab, instance: Number(r.instance_id), tag: undefined }) }, String(r.instance));
  const notRead = (_r: Row) => muted('not read', 'no mssql_cpu read in the range (VIEW SERVER STATE)');
  const cols: Col[] = [
    { key: 'instance', fmt: (_v, r) => link(r, 'performance') },
    { key: 'engine', fmt: v => v === 'sqlserver' ? 'SQL Server' : 'PostgreSQL' },
    { key: 'cpu_avg', label: 'CPU avg', num: true, fmt: (v, r) => v == null ? (isMs(r) ? notRead(r) : muted('no host read', 'no host sample in the range'))
      : isMs(r) && r.cpu_sql_avg != null ? el('span', { title: `SQL Server ${fmtNum(r.cpu_sql_avg)} %` }, dataBar(v, '')) : dataBar(v, '') },
    { key: 'cpu_max', label: 'CPU max', num: true, cls: v => lvl(v, thresholds.cpu_max) ? 'status ' + lvl(v, thresholds.cpu_max) : '',
      fmt: (v, r) => v == null ? (isMs(r) ? notRead(r) : muted('no host read', 'no host sample in the range')) : dataBar(v, lvl(v, thresholds.cpu_max)) },
    // sorted by the share of samples at 70 % and over; drawn as the ten buckets
    { key: 'cpu_hot_pct', label: 'CPU histogram', num: true, fmt: (_v, r) => r.cpu_hist == null && isMs(r) ? notRead(r) : histogram(r.cpu_hist) },
    { key: 'active_avg', label: 'active avg', num: true },
    { key: 'active_max', label: 'active max', num: true },
    { key: 'lock_ms_s', label: 'critical: Lock (ms/s)', num: true, cls: v => lvl(v, thresholds.lock_ms_s) ? 'status ' + lvl(v, thresholds.lock_ms_s) : '',
      fmt: (v, r) => v == null ? muted('-', 'no wait read') : el('span', { title: r.wait_source === 'activity' ? 'from the sessions seen waiting each minute (no pg_wait_sampling)' : String(r.wait_source ?? '') },
        ms(v) + (r.wait_source === 'activity' ? ' *' : '') + (lvl(v, thresholds.lock_ms_s) === 'crit' ? ' critical' : lvl(v, thresholds.lock_ms_s) === 'warn' ? ' warning' : '')) },
    { key: 'io_ms_s', label: 'IO (ms/s)', num: true, fmt: waitCell },
    { key: 'lwlock_ms_s', label: 'LWLock / latch (ms/s)', num: true, fmt: waitCell },
    { key: 'ipc_ms_s', label: 'IPC / parallelism (ms/s)', num: true, fmt: waitCell },
    { key: 'client_ms_s', label: 'Client (ms/s)', num: true, fmt: waitCell },
    { key: 'total_ms_s', label: 'total wait (ms/s)', num: true, fmt: waitCell },
    { key: 'signal_pct', label: 'signal wait %', num: true, fmt: (v, r) => isMs(r) ? ms(v) : muted('n/a', 'a SQL Server measure') },
    { key: 'tps', label: 'transactions/s', num: true, fmt: (v, r) => v == null ? absent(r, 'no database counters in the range') : fmtNum(v) },
    { key: 'commits_s', label: 'commits/s', num: true, fmt: (v, r) => isMs(r) ? na('a PostgreSQL counter') : v == null ? absent(r, 'no database counters in the range') : fmtNum(v) },
    { key: 'rollbacks_s', label: 'rollbacks/s', num: true, fmt: (v, r) => isMs(r) ? na('a PostgreSQL counter') : v == null ? absent(r, 'no database counters in the range') : fmtNum(v) },
    { key: 'batch_s', label: 'batch requests/s', num: true, fmt: (v, r) => !isMs(r) ? na('a SQL Server counter') : v == null ? absent(r, '') : fmtNum(v) },
    { key: 'read_ms', label: 'read latency (ms)', num: true, fmt: (v, r) => v == null ? absent(r, 'neither pg_stat_io with track_io_timing nor CloudWatch latency in the range')
      : el('span', { title: String(r.latency_source ?? '') }, ms(v)) },
    { key: 'write_ms', label: 'write latency (ms)', num: true, fmt: (v, r) => v == null ? absent(r, 'neither pg_stat_io with track_io_timing nor CloudWatch latency in the range')
      : el('span', { title: String(r.latency_source ?? '') }, ms(v)) },
    { key: 'mb_s', label: 'MB/s', num: true, fmt: (v, r) => v == null ? absent(r, 'neither pg_stat_io (PostgreSQL 16+) nor CloudWatch throughput in the range')
      : el('span', { title: String(r.io_source ?? '') }, ms(v)) },
    { key: 'temp_bytes_s', label: 'temp/s', num: true, fmt: (v, r) => isMs(r) ? na('a PostgreSQL counter') : v == null ? absent(r, 'no database counters in the range') : fmtBytes(v) },
    { key: 'mem_total_pct', label: 'memory: total of target', num: true, fmt: (v, r) => !isMs(r) ? na('a SQL Server measure') : v == null ? absent(r, '', 'no mssql_memory read in the range') : fmtNum(v) + ' %' },
    { key: 'mem_available_pct', label: 'OS memory available', num: true, fmt: (v, r) => !isMs(r) ? na('a SQL Server measure') : v == null ? absent(r, '', 'no mssql_memory read in the range') : fmtNum(v) + ' %' },
    { key: 'ple_min', label: 'PLE lowest (s)', num: true, fmt: (v, r) => !isMs(r) ? na('a SQL Server measure') : v == null ? absent(r, '', 'no mssql_memory read in the range') : fmtNum(v) },
    { key: 'grants_waiting_max', label: 'memory grants waiting', num: true, cls: v => Number(v) > 0 ? 'status warn' : '',
      fmt: (v, r) => !isMs(r) ? na('a SQL Server measure') : v == null ? absent(r, '', 'no mssql_memory read in the range') : fmtNum(v) },
    { key: 'now_longest_stmt_secs', label: 'longest statement now', num: true, fmt: (v, r) => nowCell(v, r, fmtSecs) },
    { key: 'now_oldest_xact_secs', label: 'oldest transaction now', num: true, fmt: (v, r) => nowCell(v, r, fmtSecs) },
    { key: 'now_blocked', label: 'blocked now', num: true, fmt: (v, r) => nowCell(v, r, fmtNum) },
  ];
  sec.append(el('p', { class: 'meta' }, `${rows.length} instance(s); * = Lock wait estimated from the activity samples`));
  sec.append(grid(rows, cols, 'No instance in this scope.'));
  return sec;
}
