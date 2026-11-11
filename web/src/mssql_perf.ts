// The CPU, Memory, File IO and TempDB pages of a SQL Server instance (task 119; Darling's CPU, Memory, File I/O and
// I/O Trends tabs, DBA Dash's Performance, Memory and TempDB). Data from /api/mssql/cpu, /api/mssql/memory,
// /api/mssql/fileio and /api/mssql/tempdb (the collections mssql_cpu, mssql_memory and mssql_fileio every minute,
// mssql_tempdb hourly). Every chart shares the range's time axis.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtBytes, fmtNum, fmtTime, grid, props, tile } from './ui';

// The tab keys of the slice's pages (the router's entries carry the same keys).
export const mssqlCpuTab = 'mssqlcpu';
export const mssqlMemoryTab = 'mssqlmemory';
export const mssqlFileIOTab = 'mssqlfileio';
export const mssqlTempdbTab = 'mssqltempdb';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const pct = (v: unknown) => v == null ? '-' : fmtNum(v) + ' %';
const kb = (v: unknown) => v == null ? '-' : fmtBytes(Number(v) * 1024);
const ms = (v: unknown) => v == null ? '' : fmtNum(v) + ' ms';
const yes = (v: unknown) => v == null ? '-' : v ? 'yes' : 'no';

const checkCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'check' }, { key: 'object' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
];

function checksBlock(rows: Row[], none: string): HTMLElement {
  return el('div', {}, el('h3', {}, 'Checks'), rows.length ? grid(rows, checkCols) : el('p', { class: 'meta' }, none));
}

// pivot: (snapshot_at, key, value) rows into one row per step with a column per key; keys in the order given
function pivot(rows: Row[], keyCol: string, valCol: string, bySize = false): { rows: Row[]; keys: string[] } {
  const keys: string[] = [];
  const tot = new Map<string, number>();
  const by = new Map<string, Row>();
  for (const r of rows) {
    const k = String(r[keyCol]), t = String(r.snapshot_at);
    if (!keys.includes(k)) keys.push(k);
    tot.set(k, (tot.get(k) ?? 0) + Number(r[valCol] ?? 0));
    if (!by.has(t)) by.set(t, { snapshot_at: r.snapshot_at });
    by.get(t)![k] = r[valCol];
  }
  const out = [...by.values()].sort((a, b) => Date.parse(String(a.snapshot_at)) - Date.parse(String(b.snapshot_at)));
  // by name, or the largest first (bySize); '(other)' last, so the named series take the first colours
  const named = keys.filter(k => k !== '(other)').sort(bySize ? (x, y) => (tot.get(y) ?? 0) - (tot.get(x) ?? 0) : undefined);
  return { rows: out, keys: [...named, ...keys.filter(k => k === '(other)')] };
}

// stepNote: what one step of the charts is
const stepNote = (ctx: Ctx) => el('p', { class: 'meta' }, `${rangeLabel(ctx)}; one point = the average of the reads in its step (about 120 steps over the range, a minute at least)`);

const empty = (what: string, coll: string, cadence: string) =>
  el('p', { class: 'empty' }, `No ${what} read in this range: the ${coll} collection runs ${cadence} and needs VIEW SERVER STATE `
    + '(VIEW SERVER PERFORMANCE STATE is enough on SQL Server 2022 and later).');

// mssqlCpuView: the CPU chart (SQL Server, other processes), the scheduler pressure tiles with a verdict, the scheduler
// trend and the throughput counters (Darling 13.3, DBA Dash's Performance CPU chart).
export async function mssqlCpuView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'latest' | 'cpu' | 'sched' | 'counters' | 'checks', Table | null>>('mssql/cpu', { instance: ctx.instance, ...window_(ctx) });
  const l = rowsOf(d.latest)[0], cpu = rowsOf(d.cpu), sched = rowsOf(d.sched), counters = rowsOf(d.counters), checks = rowsOf(d.checks);
  const sec = el('section', {}, el('h2', {}, `CPU (${rangeLabel(ctx)})`));
  if (!l && !cpu.length) { sec.append(empty('CPU', 'mssql_cpu', 'every minute')); return sec; }
  sec.append(stepNote(ctx));
  const box = el('div', { class: 'charts' });
  box.append(lineChart('CPU utilization (scheduler monitor, one record a minute)', cpu,
    [{ key: 'sql_pct', label: 'SQL Server %' }, { key: 'other_pct', label: 'other processes %' }, { key: 'total_pct', label: 'total %' }], v => fmtNum(v) + ' %'));
  if (cpu.length && !cpu.some(r => r.machine_read)) {
    sec.append(el('p', { class: 'meta' }, 'A Linux host: SQL Server on Linux writes no idle figure in the scheduler monitor\'s records (always 0), '
      + 'so only the SQL Server process\'s CPU is drawn; the other processes and the machine\'s total are not read.'));
  }
  sec.append(box);

  // the scheduler pressure at the newest read, with the sentence a DBA reads first
  if (l && l.schedulers != null) {
    const per = Number(l.runnable_per_sched ?? 0), wq = Number(l.work_queue ?? 0), wpct = Number(l.worker_pct ?? 0);
    const level = per >= 1 || wq > 0 ? 'HIGH' : per >= 0.25 || wpct >= 80 ? 'ELEVATED' : 'NORMAL';
    const verdict = wq > 0 ? `${fmtNum(wq)} task(s) wait for a worker thread: THREADPOOL waits follow; find what holds the workers (blocking, parallel queries) before raising max worker threads.`
      : per >= 1 ? 'Work is ready and waits for a CPU on every scheduler: SOS_SCHEDULER_YIELD and signal waits follow; the queries using the most CPU are the lever.'
      : per >= 0.25 ? 'Some tasks wait for a CPU: worth a look if it lasts.'
      : wpct >= 80 ? 'Most worker threads are in use: blocking or many parallel queries hold them.'
      : 'No CPU scheduler pressure at the newest read.';
    sec.append(el('h3', {}, `Scheduler pressure (${fmtTime(l.snapshot_at)})`), el('div', { class: 'tiles' },
      tile('pressure', level, level === 'HIGH' ? 'crit' : level === 'ELEVATED' ? 'warn' : ''),
      tile('schedulers', fmtNum(l.schedulers)),
      tile('runnable tasks', fmtNum(l.runnable_tasks), per >= 1 ? 'warn' : ''),
      tile('runnable per scheduler', fmtNum(l.runnable_per_sched)),
      tile('work queue', fmtNum(l.work_queue), wq > 0 ? 'warn' : ''),
      tile('pending disk IO', fmtNum(l.pending_io)),
      tile('workers', `${fmtNum(l.current_workers)} of ${fmtNum(l.max_workers)}`, wpct >= 80 ? 'warn' : ''),
      tile('worker use', pct(l.worker_pct)),
      tile('active workers', fmtNum(l.active_workers)),
    ), el('p', { class: 'meta' }, verdict));
  }
  const box2 = el('div', { class: 'charts' });
  box2.append(lineChart('CPU scheduler trend', sched,
    [{ key: 'runnable_tasks', label: 'runnable tasks' }, { key: 'runnable_max', label: 'runnable tasks (max)' }, { key: 'work_queue', label: 'work queue' }, { key: 'pending_io', label: 'pending disk IO' }]));
  box2.append(lineChart('Workers', sched, [{ key: 'current_workers', label: 'current workers' }, { key: 'active_workers', label: 'active workers' }, { key: 'max_workers', label: 'max worker threads' }]));
  box2.append(lineChart('Batch requests and compilations per second', counters,
    [{ key: 'batch_s', label: 'batch requests/s' }, { key: 'transactions_s', label: 'transactions/s' }, { key: 'compiles_s', label: 'compilations/s' }, { key: 'recompiles_s', label: 'recompilations/s' }]));
  sec.append(box2);
  if (l && l.batch_s != null && Number(l.batch_s) > 0) {
    const ratio = 100 * Number(l.compiles_s ?? 0) / Number(l.batch_s);
    sec.append(el('p', { class: 'meta' }, `At the newest read: ${fmtNum(l.batch_s)} batch requests/s, ${fmtNum(l.compiles_s)} compilations/s `
      + `(${fmtNum(Math.round(ratio))} % of the batches${ratio >= 10 ? ': many plans are compiled, not reused (ad hoc SQL, OPTION RECOMPILE)' : ''}).`));
  }
  sec.append(checksBlock(checks, 'No CPU or scheduler check raised (CPU at 90 % or more over 15 minutes; a runnable task per scheduler, or a work queue, over 15 minutes).'));
  return sec;
}

// mssqlMemoryView: the tiles of the newest read, the memory trend, the clerks' trend with a picker, the clerks grid,
// the grants (Darling 13.4, DBA Dash's Memory tab).
export async function mssqlMemoryView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'latest' | 'series' | 'clerks' | 'clerk_stats' | 'checks', Table | null>>('mssql/memory', { instance: ctx.instance, ...window_(ctx) });
  const l = rowsOf(d.latest)[0], series = rowsOf(d.series), stats = rowsOf(d.clerk_stats), checks = rowsOf(d.checks);
  const sec = el('section', {}, el('h2', {}, `Memory (${rangeLabel(ctx)})`));
  if (!l) { sec.append(empty('memory', 'mssql_memory', 'every minute')); return sec; }
  const low = String(l.system_state ?? '').toLowerCase().includes('low');
  sec.append(el('h3', {}, `Newest read (${fmtTime(l.snapshot_at)})`), el('div', { class: 'tiles' },
    tile('physical', kb(l.physical_kb)),
    tile('available', kb(l.available_kb), low ? 'warn' : ''),
    tile('utilization', pct(l.used_pct)),
    tile('total server', kb(l.total_kb)),
    tile('target server', kb(l.target_kb)),
    tile('buffer pool', kb(l.buffer_pool_kb)),
    tile('plan cache (all cache stores)', kb(l.plan_cache_kb)),
    tile('stolen', kb(l.stolen_kb)),
    tile('page life expectancy', l.ple == null ? '-' : fmtNum(l.ple) + ' s'),
    tile('grants waiting', fmtNum(Math.max(Number(l.grants_pending ?? 0), Number(l.grants_waiting ?? 0), Number(l.sem_waiting ?? 0))),
      Number(l.grants_pending ?? 0) + Number(l.grants_waiting ?? 0) > 0 ? 'warn' : ''),
    tile('system state', String(l.system_state ?? '-'), low ? 'warn' : ''),
    tile('memory model', String(l.memory_model ?? '-')),
  ));
  sec.append(props([
    ['max server memory', l.max_server_memory_mb == null ? 'not read (mssql_instance)' : `${fmtNum(l.max_server_memory_mb)} MB`
      + (l.physical_kb ? ` (${fmtNum(Math.round(100 * Number(l.max_server_memory_mb) * 1024 / Number(l.physical_kb)))} % of physical)` : '')],
    ['SQL Server process working set', kb(l.process_kb) + (l.process_low ? ' - the process had a low-memory notification' : '')],
    ['committed / target', `${kb(l.committed_kb)} of ${kb(l.committed_target_kb)}`],
    ['memory grants', `${fmtNum(l.sem_granted ?? 0)} granted (${kb(l.sem_granted_kb)} of a ${kb(l.sem_target_kb)} target), ${fmtNum(l.sem_waiting ?? 0)} waiting; `
      + `largest grant ${kb(l.max_grant_kb)}, all grants ${kb(l.sum_grant_kb)}, largest asked ${kb(l.max_requested_kb)}`],
  ]));
  sec.append(stepNote(ctx));
  const mb = (v: number) => fmtNum(v) + ' MB';
  const box = el('div', { class: 'charts' });
  box.append(lineChart('Memory trend', series, [{ key: 'total_mb', label: 'total server' }, { key: 'target_mb', label: 'target' },
    { key: 'buffer_pool_mb', label: 'buffer pool' }, { key: 'plan_cache_mb', label: 'plan cache' }, { key: 'stolen_mb', label: 'stolen' }, { key: 'available_mb', label: 'available (OS)' }], mb));
  box.append(lineChart('Page life expectancy', series, [{ key: 'ple', label: 'PLE (avg)' }, { key: 'ple_min', label: 'PLE (lowest)' }], v => fmtNum(v) + ' s'));
  box.append(lineChart('Memory grants', series, [{ key: 'grants_granted', label: 'queries granted' }, { key: 'grants_waiting', label: 'queries waiting' }]));
  box.append(lineChart('Memory grant sizes', series, [{ key: 'max_grant_mb', label: 'largest grant' }, { key: 'sum_grant_mb', label: 'all grants' }], mb));
  sec.append(box);

  // the clerks' trend: the ten largest of the range and '(other)', a check box per clerk (up to ten drawn)
  const p = pivot(rowsOf(d.clerks), 'clerk_type', 'mb', true);
  const chosen = new Set(p.keys.slice(0, 5));   // the five largest, the buffer pool first (Darling's default)
  const holder = el('div', { class: 'charts' });
  const draw = () => holder.replaceChildren(lineChart(`Memory clerks trend (${chosen.size} of ${p.keys.length})`, p.rows,
    p.keys.filter(k => chosen.has(k)).map(k => ({ key: k, label: k })), mb));
  const picker = el('fieldset', { class: 'meta' }, el('legend', {}, 'Clerks (the ten largest of the range; up to ten drawn)'));
  for (const k of p.keys) {
    const cb = el('input', { type: 'checkbox' }) as HTMLInputElement;
    cb.checked = chosen.has(k);
    cb.addEventListener('change', () => { if (cb.checked) { if (chosen.size >= 10) { cb.checked = false; return; } chosen.add(k); } else chosen.delete(k); draw(); });
    picker.append(el('label', { style: 'margin-right:1em;white-space:nowrap' }, cb, ' ' + k));
  }
  draw();
  sec.append(el('h3', {}, 'Memory clerks'), picker, holder);
  sec.append(grid(stats, [
    { key: 'clerk_type', label: 'clerk type' },
    { key: 'current_kb', label: 'pages (current)', num: true, fmt: kb },
    { key: 'current_pct', label: '% of clerks', num: true, fmt: pct },
    { key: 'max_kb', label: 'max', num: true, fmt: kb },
    { key: 'avg_kb', label: 'avg', num: true, fmt: kb },
    { key: 'min_kb', label: 'min', num: true, fmt: kb },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ], 'No clerk read in this range.'));
  sec.append(checksBlock(checks, 'No memory check raised (available physical memory low; queries waiting for memory grants in 3 of 15 minutes).'));
  return sec;
}

// mssqlFileIOView: read and write latency by database and file type, MB/s per file, the files grid (Darling 13.6 and
// 13.7, DBA Dash's IO Performance chart).
export async function mssqlFileIOView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'latency' | 'throughput' | 'files' | 'checks', Table | null>>('mssql/fileio', { instance: ctx.instance, ...window_(ctx) });
  const lat = rowsOf(d.latency), thr = rowsOf(d.throughput), files = rowsOf(d.files), checks = rowsOf(d.checks);
  const sec = el('section', {}, el('h2', {}, `File IO (${rangeLabel(ctx)})`));
  if (!files.length) { sec.append(empty('file IO', 'mssql_fileio', 'every minute')); return sec; }
  sec.append(el('p', { class: 'meta' }, 'From sys.dm_io_virtual_file_stats: each minute\'s reads and writes per file and the time they stalled; the latency is the stall over the operations. '
    + 'The five busiest database and file type groups are drawn on their own, the rest as (other).'), stepNote(ctx));
  const r = pivot(lat.filter(x => x.read_ms != null), 'grp', 'read_ms'), w = pivot(lat.filter(x => x.write_ms != null), 'grp', 'write_ms');
  const box = el('div', { class: 'charts' });
  box.append(lineChart('Read latency (ms)', r.rows, r.keys.map(k => ({ key: k, label: k })), v => fmtNum(v) + ' ms'));
  box.append(lineChart('Write latency (ms)', w.rows, w.keys.map(k => ({ key: k, label: k })), v => fmtNum(v) + ' ms'));
  const rt = pivot(thr, 'file', 'read_mb_s'), wt = pivot(thr, 'file', 'write_mb_s');
  box.append(lineChart('Read MB/s (the five busiest files)', rt.rows, rt.keys.map(k => ({ key: k, label: k })), v => fmtNum(v) + ' MB/s'));
  box.append(lineChart('Write MB/s (the five busiest files)', wt.rows, wt.keys.map(k => ({ key: k, label: k })), v => fmtNum(v) + ' MB/s'));
  sec.append(box);
  sec.append(el('h3', {}, `File IO stats (${files.length} files, the most stall first)`), grid(files, [
    { key: 'database_name', label: 'database' },
    { key: 'file_name', label: 'file' },
    { key: 'type_desc', label: 'type' },
    { key: 'read_ms', label: 'read latency', num: true, fmt: ms, cls: (v, row) => row.type_desc !== 'LOG' && Number(v) >= 50 ? 'warn' : '' },
    { key: 'reads', num: true },
    { key: 'read_bytes', label: 'read', num: true, fmt: fmtBytes },
    { key: 'write_ms', label: 'write latency', num: true, fmt: ms, cls: (v, row) => row.type_desc === 'LOG' && Number(v) >= 20 ? 'warn' : '' },
    { key: 'writes', num: true },
    { key: 'write_bytes', label: 'written', num: true, fmt: fmtBytes },
    { key: 'stall_ms', label: 'stall', num: true, fmt: ms },
    { key: 'physical_name', label: 'path', wide: true },
  ]));
  sec.append(checksBlock(checks, 'No file IO check raised (data file reads at 50 ms or more, log writes at 20 ms or more, over the last hour with 1,000 operations).'));
  sec.append(el('p', { class: 'meta' }, 'tempdb\'s layout: ', el('a', { href: href(ctx, { tab: mssqlTempdbTab }) }, 'TempDB'), '.'));
  return sec;
}

// tempdbCols: DBA Dash's TempDB grid (37, 66)
const tempdbCols = (fleet: boolean, ctx: Ctx): Col[] => [
  ...(fleet ? [{ key: 'instance', fmt: (v: unknown, row: Row) => el('a', { href: href(ctx, { tab: mssqlTempdbTab, instance: Number(row.instance_id) }) }, String(v ?? '')) }] : []),
  { key: 'data_files', label: '# data files', num: true },
  { key: 'insufficient_files', label: 'insufficient files', fmt: v => v == null ? 'not weighed' : v ? badge('yes', 'warn') : 'no' },
  { key: 'recommended_files', label: 'recommended (minimum)', num: true },
  { key: 'log_files', label: '# log files', num: true },
  { key: 'even_size', label: 'even sized', fmt: v => v ? 'yes' : badge('no', 'warn') },
  { key: 'even_growth', label: 'even growth', fmt: v => v ? 'yes' : badge('no', 'warn') },
  { key: 'total_mb', label: 'total size (MB)', num: true },
  { key: 'log_mb', label: 'log (MB)', num: true },
  { key: 'file_mb', label: 'file size (MB)', num: true },
  { key: 'max_growth_mb', label: 'max growth (MB)', num: true },
  { key: 'max_log_growth_mb', label: 'max log growth (MB)', num: true },
  { key: 'max_growth_pct', label: 'max growth %', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v) + ' %', 'info') : '0' },
  { key: 'max_log_growth_pct', label: 'max log growth %', num: true },
  { key: 'volumes', label: 'tempdb volume(s)', wide: true },
  { key: 'cpu_count', label: 'CPU count', num: true },
  { key: 'tf1117', label: 'T1117', fmt: yes },
  { key: 'tf1118', label: 'T1118', fmt: yes },
  { key: 'flags_required', label: 'trace flags required?', fmt: v => v ? 'yes (before 2016)' : 'no' },
  { key: 'memopt_metadata', label: 'memory-optimized metadata?', fmt: v => v == null ? 'n/a (before 2019, or Managed Instance)' : v ? 'yes' : 'no' },
  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
];

// mssqlTempdbView: one instance's tempdb layout, its files and its checks; at the root (no instance) every SQL
// Server instance's row (keep: a tag folder's instances only).
export async function mssqlTempdbView(ctx: Ctx, keep?: (r: Row) => boolean): Promise<HTMLElement> {
  const d = await get<Record<'layout' | 'files' | 'checks', Table | null>>('mssql/tempdb', ctx.instance ? { instance: ctx.instance } : {});
  const k = keep ?? (() => true);
  const layout = rowsOf(d.layout).filter(k), files = rowsOf(d.files).filter(k), checks = rowsOf(d.checks).filter(k);
  const fleet = !ctx.instance;
  const sec = el('section', {}, el('h2', {}, 'TempDB'),
    el('p', { class: 'meta' }, 'Microsoft\'s guidance: with eight logical processors or fewer, as many data files as processors; with more, eight, '
      + 'then more by fours only while allocation contention stays; every data file the same size and growth. Trace flags 1117 and 1118 are no longer '
      + 'required from SQL Server 2016 (their behaviour is tempdb\'s default).'));
  if (!layout.length) {
    sec.append(el('p', { class: 'empty' }, 'No tempdb read yet: the mssql_tempdb collection runs hourly (the CPU count needs VIEW SERVER STATE).'));
    return sec;
  }
  sec.append(grid(layout, tempdbCols(fleet, ctx)));
  if (!fleet) {
    sec.append(el('h3', {}, 'Files'), grid(files, [
      { key: 'file_id', label: 'id', num: true }, { key: 'file_name', label: 'file' }, { key: 'type_desc', label: 'type' },
      { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
      { key: 'growth_bytes', label: 'growth', num: true, fmt: (v, row) => Number(row.growth_pct) > 0 ? fmtNum(row.growth_pct) + ' %' : Number(v) > 0 ? fmtBytes(v) : 'does not grow' },
      { key: 'max_size_bytes', label: 'max', num: true, fmt: v => v == null ? 'until the volume is full' : fmtBytes(v) },
      { key: 'volume' }, { key: 'physical_name', label: 'path', wide: true },
    ]));
  }
  sec.append(el('h3', {}, 'Checks'), checks.length
    ? grid(checks, [...(fleet ? [{ key: 'instance' }] : []), ...checkCols])
    : el('p', { class: 'meta' }, 'No tempdb check raised: the data files match the recommended minimum, one size and one growth.'));
  return sec;
}
