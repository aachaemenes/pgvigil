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
export const mssqlConnectionsTab = 'mssqlconnections';

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
  const d = await get<Record<'latest' | 'cpu' | 'sched' | 'counters' | 'checks' | 'newest' | 'threadpool' | 'connectfail' | 'findings', Table | null>>('mssql/cpu', { instance: ctx.instance, ...window_(ctx) });
  const l = rowsOf(d.latest)[0], cpu = rowsOf(d.cpu), sched = rowsOf(d.sched), counters = rowsOf(d.counters);
  const checks = [...rowsOf(d.checks), ...rowsOf(d.findings)];
  const n = rowsOf(d.newest)[0], tpool = rowsOf(d.threadpool), fails = rowsOf(d.connectfail);
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
  // task 177 D14: a collection that could not connect leaves a gap; a server whose workers are all busy takes no login
  if (fails.length) {
    const f = fails[0];
    sec.append(el('p', { class: 'meta', 'data-connectfail': String(fails.length) },
      badge('possibly a worker shortage', 'warn'), ` ${fmtNum(fails.length)} collection(s) could not connect to this server in the range, the last at ${fmtTime(f.snapshot_at)} `
      + `(${String(f.collection)}: ${String(f.note ?? '').slice(0, 300)}). A server whose worker threads are all busy (THREADPOOL) takes no new login, so its reads stop `
      + 'while it lasts and the charts show a gap; the server being down, the network or the login can do the same. After it, the cumulative \'Wait for the worker\' counters '
      + '(Metrics) and THREADPOOL in the waits show whether workers ran out.'));
  }

  // the scheduler pressure at the newest read, with the sentence a DBA reads first: pgvigil's level (0124's
  // mssql_sched_levels for the newest read of the range; the same rule here for an older read), and PerformanceMonitor's
  // ClassifyCpuSchedulerPressure word for word as a labelled second line (task 177 D14)
  if (l && l.schedulers != null) {
    const per = Number(l.runnable_per_sched ?? 0), wq = Number(l.work_queue ?? 0), wpct = Number(l.worker_pct ?? 0);
    const level = n ? String(n.level) : per >= 1 || wq > 0 ? 'HIGH' : per >= 0.25 || wpct >= 80 ? 'ELEVATED' : 'NORMAL';
    const verdict = n ? String(n.verdict) : wq > 0 ? `${fmtNum(wq)} task(s) wait for a worker thread: THREADPOOL waits follow; find what holds the workers (blocking, parallel queries) before raising max worker threads.`
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
      ...(n && n.offline_cpus != null ? [tile('CPUs offline', fmtNum(n.offline_cpus), Number(n.offline_cpus) > 0 ? 'warn' : '')] : []),
      ...(n && n.nodes_total != null ? [tile('NUMA nodes online', `${fmtNum(n.nodes_online)} of ${fmtNum(n.nodes_total)}`, Number(n.nodes_online) < Number(n.nodes_total) ? 'warn' : '')] : []),
    ), el('p', { class: 'meta', 'data-verdict': level }, verdict));
    if (n) {
      sec.append(el('p', { class: 'meta', 'data-pm-level': String(n.pm_level) },
        el('strong', {}, 'PerformanceMonitor: '), `${String(n.pm_level)} - ${String(n.pm_recommendation)}`,
        ' (its runnable-task bands over 50, 20 and 10 tasks on the whole server, then worker use over 90 %, then its warnings; '
        + 'its queued requests are Resource Governor\'s, not the worker queue)'));
      sec.append(mssqlThreadRow(n), threadpoolBlock(n, tpool), cpuInfoLine(n));
    }
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
// the grants (Darling 13.4, DBA Dash's Memory tab); task 177 D13, in PerformanceMonitor's Memory tab's order: the plan
// cache trend, the resource monitor's pressure events, the grants per resource pool and per semaphore over the range
// and at the newest read, the workload groups and pools, the queries holding or waiting for a grant, the caches
// (sp_PressureDetector's) and the plan cache by type with its bloat level.
type MemoryParts = 'latest' | 'series' | 'clerks' | 'clerk_stats' | 'checks' | 'pools_window' | 'semaphores_window' | 'pools_newest'
  | 'semaphores_newest' | 'pool_series' | 'rmon' | 'rmon_hourly' | 'caches' | 'plancache' | 'plancache_types' | 'plancache_trend'
  | 'grants_now' | 'rg' | 'skipped';
const mbOf = (v: unknown) => v == null ? '-' : fmtNum(Math.round(Number(v) / 102.4) / 10) + ' MB';
const grantWindowCols = (bySem: boolean): Col[] => [
  { key: 'pool_name', label: 'pool', fmt: (v, r) => String(v ?? 'pool ' + String(r.pool_id)) },
  ...(bySem ? [{ key: 'semaphore_id', label: 'semaphore', num: true, fmt: (v: unknown) => v === 0 ? '0 (regular)' : v === 1 ? '1 (small query)' : String(v ?? '') }] : []),
  { key: 'snapshots', label: 'reads', num: true },
  { key: 'peak_waiters', label: 'peak waiters', num: true },
  { key: 'peak_waiters_at', label: 'peak waiters at', fmt: fmtTime },
  { key: 'peak_granted_kb', label: 'peak granted', num: true, fmt: mbOf },
  { key: 'peak_granted_at', label: 'peak granted at', fmt: fmtTime },
  { key: 'min_available_kb', label: 'least available', num: true, fmt: mbOf },
  { key: 'timeouts', label: 'timeouts', num: true },
  { key: 'forced_grants', label: 'forced grants', num: true },
  { key: 'first_at', label: 'first', fmt: fmtTime },
  { key: 'last_at', label: 'last', fmt: fmtTime },
];
const grantNewestCols = (bySem: boolean): Col[] => [
  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  { key: 'pool_name', label: 'pool', fmt: (v, r) => String(v ?? 'pool ' + String(r.pool_id)) },
  ...(bySem ? [{ key: 'semaphore_id', label: 'semaphore', num: true, fmt: (v: unknown) => v === 0 ? '0 (regular)' : v === 1 ? '1 (small query)' : String(v ?? '') },
    { key: 'target_kb', label: 'target', num: true, fmt: mbOf }, { key: 'max_target_kb', label: 'max target', num: true, fmt: mbOf },
    { key: 'total_kb', label: 'total', num: true, fmt: mbOf }] : []),
  { key: 'granted_kb', label: 'granted', num: true, fmt: mbOf },
  { key: 'used_kb', label: 'used', num: true, fmt: mbOf },
  { key: 'available_kb', label: 'available', num: true, fmt: mbOf },
  { key: 'grantees', label: 'grantees', num: true },
  { key: 'waiters', label: 'waiters', num: true },
  { key: 'timeouts_delta', label: 'timeouts (since the read before)', num: true },
  { key: 'forced_delta', label: 'forced grants (since the read before)', num: true },
  { key: 'timeouts_total', label: 'timeouts since start', num: true },
  { key: 'forced_total', label: 'forced since start', num: true },
];
export async function mssqlMemoryView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<MemoryParts, Table | null>>('mssql/memory', { instance: ctx.instance, ...window_(ctx) });
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
    ['workspace memory', l.max_workspace_kb == null ? 'not read' : `${kb(l.granted_workspace_kb)} granted of ${kb(l.max_workspace_kb)} (Maximum Workspace Memory: `
      + 'a grant over 15 % of it is raised, sp_BlitzFirst 46)'],
    ['In-Memory OLTP and the token cache', `MEMORYCLERK_XTP ${kb(l.xtp_kb)}; TokenAndPermUserStore ${kb(l.tokenperm_kb)}`
      + (l.clerks_kb ? ` (${fmtNum(Math.round(1000 * Number(l.tokenperm_kb ?? 0) / Number(l.clerks_kb)) / 10)} % of all clerks)` : '')],
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
  const pcBox = el('div', { class: 'charts' });
  pcBox.append(lineChart('Plan cache: single-use and multi-use plans', rowsOf(d.plancache_trend),
    [{ key: 'single_use_mb', label: 'single-use plans' }, { key: 'multi_use_mb', label: 'multi-use plans' }], mb));
  sec.append(pcBox);
  sec.append(grid(stats, [
    { key: 'clerk_type', label: 'clerk type' },
    { key: 'current_kb', label: 'pages (current)', num: true, fmt: kb },
    { key: 'current_pct', label: '% of clerks', num: true, fmt: pct },
    { key: 'max_kb', label: 'max', num: true, fmt: kb },
    { key: 'avg_kb', label: 'avg', num: true, fmt: kb },
    { key: 'min_kb', label: 'min', num: true, fmt: kb },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ], 'No clerk read in this range.'));
  memoryD13(sec, d, mb);
  sec.append(checksBlock(checks, 'No memory check raised (available physical memory low; queries waiting for memory grants in 3 of 15 minutes; '
    + 'grant timeouts; a low-memory notification; In-Memory OLTP and the token cache; a grant over 15 % of workspace; plan cache bloat '
    + 'with optimize for ad hoc off; instant file initialization off).'));
  return sec;
}

// mssqlFileIOView: read and write latency by database and file type, MB/s per file, the files grid (Darling 13.6 and
// 13.7, DBA Dash's IO Performance chart).
export async function mssqlFileIOView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'latency' | 'throughput' | 'files' | 'checks' | 'logflush' | 'findings', Table | null>>('mssql/fileio', { instance: ctx.instance, ...window_(ctx) });
  const lat = rowsOf(d.latency), thr = rowsOf(d.throughput), files = rowsOf(d.files), checks = [...rowsOf(d.checks), ...rowsOf(d.findings)];
  const flush = rowsOf(d.logflush);
  const sec = el('section', {}, el('h2', {}, `File IO (${rangeLabel(ctx)})`));
  // the log flushes are mssql_activity's (task 177 D14): they show without a file IO read too
  if (!files.length) { sec.append(empty('file IO', 'mssql_fileio', 'every minute'), await logFlushBlock(ctx, flush)); return sec; }
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
    // task 177 D14: sp_PressureDetector's KB per read and per write (file stats)
    { key: '_kb_read', label: 'KB per read', num: true, fmt: (_v, row) => Number(row.reads) > 0 ? fmtNum(Math.round(10 * Number(row.read_bytes) / 1024 / Number(row.reads)) / 10) : '' },
    { key: 'write_ms', label: 'write latency', num: true, fmt: ms, cls: (v, row) => row.type_desc === 'LOG' && Number(v) >= 20 ? 'warn' : '' },
    { key: 'writes', num: true },
    { key: 'write_bytes', label: 'written', num: true, fmt: fmtBytes },
    { key: '_kb_write', label: 'KB per write', num: true, fmt: (_v, row) => Number(row.writes) > 0 ? fmtNum(Math.round(10 * Number(row.write_bytes) / 1024 / Number(row.writes)) / 10) : '' },
    { key: 'stall_ms', label: 'stall', num: true, fmt: ms },
    { key: 'physical_name', label: 'path', wide: true },
  ]));
  sec.append(await logFlushBlock(ctx, flush));
  sec.append(checksBlock(checks, 'No file IO check raised (data file reads at 50 ms or more, log writes at 20 ms or more, data file writes over 100 ms, over the last hour with 1,000 operations).'));
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
  const d = await get<Record<'layout' | 'files' | 'checks' | 'holders' | 'holders_read', Table | null>>('mssql/tempdb', ctx.instance ? { instance: ctx.instance } : {});
  const k = keep ?? (() => true);
  const layout = rowsOf(d.layout).filter(k), files = rowsOf(d.files).filter(k), checks = rowsOf(d.checks).filter(k);
  const fleet = !ctx.instance;
  const sec = el('section', {}, el('h2', {}, 'TempDB'),
    el('p', { class: 'meta' }, 'Microsoft\'s guidance: with eight logical processors or fewer, as many data files as processors; with more, eight, '
      + 'then more by fours only while allocation contention stays; every data file the same size and growth. Trace flags 1117 and 1118 are no longer '
      + 'required from SQL Server 2016 (their behaviour is tempdb\'s default).'));
  if (!layout.length) {
    sec.append(el('p', { class: 'empty' }, 'No tempdb layout read yet: the mssql_tempdb collection runs hourly (the CPU count needs VIEW SERVER STATE).'));
    // the holders are mssql_activity's (task 177 D14): they show without a layout read too
    if (!fleet) sec.append(tempdbHolders(rowsOf(d.holders), rowsOf(d.holders_read)[0]));
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
  if (!fleet) sec.append(tempdbHolders(rowsOf(d.holders), rowsOf(d.holders_read)[0]));
  return sec;
}

// tempdbHolders (task 177 D14): the sessions holding tempdb at the newest mssql_activity read of the last 15 minutes,
// sp_PressureDetector's allocations and current pages per session: sys.dm_db_task_space_usage (running tasks) and
// sys.dm_db_session_space_usage (what the session's finished tasks hold, so an idle session keeping temp tables shows)
// summed; 'none' only when that read ran and was not refused
function tempdbHolders(rows: Row[], read?: Row): HTMLElement {
  const box = el('div', {}, el('h3', {}, 'Sessions holding tempdb'));
  const refused = ((read?.skipped ?? []) as { read?: string; error?: string }[]).find(s => s.read === 'sys.dm_db_session_space_usage');
  box.append(el('p', { class: 'meta', 'data-holders': read == null ? 'not read' : refused ? 'refused' : String(rows.length) }, rows.length
    ? `The newest mssql_activity read (every 5 minutes), ${fmtTime(rows[0].snapshot_at)}: the 20 sessions with the most tempdb allocated (sp_PressureDetector's figures: allocated, and current = allocated less deallocated; a running request's tasks and the session's finished ones summed, the running part also apart).`
    : read == null ? 'Not read in the last 15 minutes: mssql_activity reads the sessions holding tempdb every 5 minutes (it needs VIEW SERVER STATE).'
    : refused ? `The server refused the read at ${fmtTime(read.snapshot_at)}: ${String(refused.error ?? '').slice(0, 300)}`
    : `No session held tempdb at the read of ${fmtTime(read.snapshot_at)}.`));
  if (rows.length) box.append(grid(rows, [
    { key: 'session_id', label: 'session', num: true }, { key: 'login_name', label: 'login' }, { key: 'program_name', label: 'program' },
    { key: 'host_name', label: 'host' }, { key: 'status' }, { key: 'open_tran', label: 'open transactions', num: true },
    { key: 'alloc_kb', label: 'allocated', num: true, fmt: kb }, { key: 'current_kb', label: 'current', num: true, fmt: kb },
    { key: 'user_kb', label: 'user objects', num: true, fmt: kb }, { key: 'internal_kb', label: 'internal objects', num: true, fmt: kb },
    { key: 'task_alloc_kb', label: 'allocated (running tasks)', num: true, fmt: kb }, { key: 'task_current_kb', label: 'current (running tasks)', num: true, fmt: kb },
    { key: 'last_request_end', label: 'last request ended', fmt: fmtTime },
  ]));
  return box;
}

// logFlushBlock (task 177 D14): log bytes flushed per second per database (the Databases object's Log Bytes
// Flushed/sec, read every 5 minutes): the five busiest databases charted, every database in a grid
async function logFlushBlock(ctx: Ctx, rows: Row[]): Promise<HTMLElement> {
  const box = el('div', {}, el('h3', {}, 'Log bytes flushed per database'),
    el('p', { class: 'meta' }, 'From mssql_activity\'s per-database counters (the Databases object\'s Log Bytes Flushed/sec), read every 5 minutes.'));
  if (!rows.length) {
    box.append(el('p', { class: 'meta' }, 'No per-database log counters in this window.'));
    return box;
  }
  const top = rows.slice(0, 5);
  try {
    const s = await get<Record<'series', Table | null>>('mssql/counters', { instance: ctx.instance, ...window_(ctx), part: 'series', series: top.map(r => String(r.series_id)).join(',') });
    const name = new Map(top.map(r => [String(r.series_id), String(r.database_name)]));
    const pts = pivot(rowsOf(s.series).map(r => ({ ...r, db: name.get(String(r.series_id)) ?? String(r.series_id) })), 'db', 'value');
    const charts = el('div', { class: 'charts' });
    charts.append(lineChart('Log bytes flushed per second (the five busiest databases)', pts.rows, pts.keys.map(k => ({ key: k, label: k })), v => fmtBytes(v) + '/s'));
    box.append(charts);
  } catch (e) {
    box.append(el('p', { class: 'meta' }, 'The log flush series could not be read: ' + (e instanceof Error ? e.message : String(e))));
  }
  box.append(grid(rows, [
    { key: 'database_name', label: 'database' },
    { key: 'avg_bytes_s', label: 'average', num: true, fmt: v => v == null ? '' : fmtBytes(v) + '/s' },
    { key: 'max_bytes_s', label: 'highest', num: true, fmt: v => v == null ? '' : fmtBytes(v) + '/s' },
    { key: 'reads', label: 'reads with a rate', num: true }, { key: 'last_at', label: 'last read', fmt: fmtTime },
  ]));
  return box;
}

// memoryD13: the sections of task 177 D13 below the clerks, PerformanceMonitor's order (server-tabs.js, the Memory tab).
function memoryD13(sec: HTMLElement, d: Record<MemoryParts, Table | null>, mb: (v: number) => string): void {
  // the resource monitor's records: per hour the samples with an indicator of 2 or more (PerformanceMonitor), and all
  const hourly = rowsOf(d.rmon_hourly).map(r => ({ ...r, snapshot_at: r.at }));
  const rmon = rowsOf(d.rmon);
  const pBox = el('div', { class: 'charts' });
  // a point is an hour, not a read: under three hours (a 1 h window gives two: the function, as PerformanceMonitor's
  // pressureEventBuckets, takes every hour from the one holding the window's start to the one holding its end) the
  // chart's own note would count the hours as reads, so the hours are written out, each counted within the window only
  const hourWords = (h: Row) => el('span', { 'data-at': String(h.at) }, `the hour from ${fmtTime(h.at)}: SQL Server `
    + `${fmtNum(h.sql_medium)} medium, ${fmtNum(h.sql_severe)} severe; operating system ${fmtNum(h.os_medium)} medium, ${fmtNum(h.os_severe)} severe`);
  const hourLine = el('p', { class: 'meta', 'data-hours': String(hourly.length) }, hourly.length
    ? `The window falls in ${hourly.length === 1 ? 'one hour' : 'two hours'}, each counted within the window only (the chart is drawn from three): `
    : 'No hour in this window.');
  hourly.forEach((h, i) => hourLine.append(...(i ? ['. ', hourWords(h)] : [hourWords(h)])));
  if (hourly.length) hourLine.append('.');
  pBox.append(hourly.length >= 3
    ? lineChart('Memory pressure events per hour', hourly, [{ key: 'sql_medium', label: 'SQL Server (medium)' },
      { key: 'sql_severe', label: 'SQL Server (severe)' }, { key: 'os_medium', label: 'operating system (medium)' },
      { key: 'os_severe', label: 'operating system (severe)' }], v => fmtNum(v))
    : el('div', { class: 'chart' }, el('h3', {}, 'Memory pressure events per hour'), hourLine));
  sec.append(el('h3', {}, 'Memory pressure events'), el('p', { class: 'meta' },
    'The resource monitor ring buffer (RING_BUFFER_RESOURCE_MONITOR), every record of the range: an hour counts a record when the process '
    + '(SQL Server) or the system (operating system) indicator reads 2 or more, 2 medium, 3 or more severe; an hour without one counts 0. '
    + `${fmtNum(rmon.length)} record(s) in the range.`), pBox,
  grid(rmon, [
    { key: 'sample_at', label: 'time', fmt: fmtTime },
    { key: 'notification', label: 'notification' },
    { key: 'ind_process', label: 'process', num: true },
    { key: 'ind_system', label: 'system', num: true },
    { key: 'avail_phys_kb', label: 'available physical', num: true, fmt: mbOf },
    { key: 'avail_vas_kb', label: 'available virtual', num: true, fmt: mbOf },
  ], 'No resource monitor record in this range.'));

  // the grants per resource pool: per step, over the range, at the newest read; then per semaphore
  const ps = rowsOf(d.pool_series);
  const wt = pivot(ps, 'pool', 'waiters'), gr = pivot(ps, 'pool', 'granted_mb'), to = pivot(ps.map(r => ({ ...r, tf: Number(r.timeouts ?? 0) + Number(r.forced_grants ?? 0) })), 'pool', 'tf');
  const gBox = el('div', { class: 'charts' });
  gBox.append(lineChart('Memory grant waiters per pool', wt.rows, wt.keys.map(k => ({ key: k, label: k })), v => fmtNum(v)));
  gBox.append(lineChart('Memory granted per pool', gr.rows, gr.keys.map(k => ({ key: k, label: k })), mb));
  gBox.append(lineChart('Grant timeouts and forced grants per pool', to.rows, to.keys.map(k => ({ key: k, label: k })), v => fmtNum(v)));
  sec.append(el('h3', {}, 'Memory grants per resource pool'), el('p', { class: 'meta' },
    'sys.dm_exec_query_resource_semaphores per read, a pool\'s semaphores with a max target summed (sp_PressureDetector\'s and '
    + 'PerformanceMonitor\'s filter); the timeouts and forced grants are the counters\' growth between reads.'), gBox,
  el('h3', {}, 'Memory grant pressure (every read of the range, per pool)'),
  grid(rowsOf(d.pools_window), grantWindowCols(false), 'No memory grant read in this range.'),
  el('h3', {}, 'Memory grants (the newest read of the range, per pool: a moment, not the range)'),
  grid(rowsOf(d.pools_newest), grantNewestCols(false), 'No memory grant read in this range.'),
  el('h3', {}, 'Resource semaphore pressure (every read of the range, per semaphore)'),
  grid(rowsOf(d.semaphores_window), grantWindowCols(true), 'No semaphore read in this range.'),
  el('h3', {}, 'Resource semaphores (the newest read of the range)'),
  grid(rowsOf(d.semaphores_newest), grantNewestCols(true), 'No semaphore read in this range.'));

  // the Resource Governor: each workload group with its limits beside its pool's
  sec.append(el('h3', {}, 'Workload groups and resource pools (the newest read)'), grid(rowsOf(d.rg), [
    { key: 'pool_name', label: 'pool' },
    { key: 'min_memory_pct', label: 'pool min memory %', num: true },
    { key: 'max_memory_pct', label: 'pool max memory %', num: true },
    { key: 'target_memory_kb', label: 'pool target', num: true, fmt: mbOf },
    { key: 'used_memory_kb', label: 'pool used', num: true, fmt: mbOf },
    { key: 'used_memgrant_kb', label: 'pool grants used', num: true, fmt: mbOf },
    { key: 'memgrant_waiters', label: 'pool grant waiters', num: true },
    { key: 'memgrant_timeouts', label: 'pool grant timeouts', num: true },
    { key: 'group_name', label: 'group' },
    { key: 'importance', label: 'importance' },
    { key: 'max_grant_pct', label: 'max grant % (the cap)', num: true },
    { key: 'grant_timeout_sec', label: 'grant timeout s', num: true, fmt: v => v === 0 ? '0 (the default)' : fmtNum(v) },
    { key: 'max_dop', label: 'max DOP', num: true },
    { key: 'max_cpu_sec', label: 'max CPU s', num: true },
    { key: 'max_requests', label: 'max requests', num: true },
    { key: 'reduced_grants', label: 'reduced grants', num: true },
    { key: 'requests', label: 'requests', num: true },
    { key: 'active_requests', label: 'active', num: true },
    { key: 'queued_requests', label: 'queued', num: true },
    { key: 'max_request_grant_kb', label: 'largest grant', num: true, fmt: mbOf },
  ], 'The workload groups were not read.'));

  // the queries holding or waiting for a grant at the newest read (sp_PressureDetector's list, sp_BlitzWho's cost)
  const gn = rowsOf(d.grants_now);
  sec.append(el('h3', {}, 'Queries with memory grants (the newest read)'), el('p', { class: 'meta' },
    'sys.dm_exec_query_memory_grants, the 50 largest asks: a row with no grant time waits for its grant (its place in the queue is the wait order).'),
  grid(gn, [
    { key: 'session_id', label: 'session', num: true },
    { key: 'database_name', label: 'database' },
    { key: 'grant_at', label: 'granted at', fmt: (v, r) => v == null ? 'waiting since ' + fmtTime(r.request_at) : fmtTime(v) },
    { key: 'wait_time_ms', label: 'waited', num: true, fmt: ms },
    { key: 'requested_kb', label: 'requested', num: true, fmt: mbOf },
    { key: 'granted_kb', label: 'granted', num: true, fmt: mbOf },
    { key: 'used_kb', label: 'used', num: true, fmt: mbOf },
    { key: 'max_used_kb', label: 'max used', num: true, fmt: mbOf },
    { key: 'ideal_kb', label: 'ideal', num: true, fmt: mbOf },
    { key: 'required_kb', label: 'required', num: true, fmt: mbOf },
    { key: 'query_cost', label: 'query cost', num: true, fmt: v => v == null ? '-' : fmtNum(Math.round(Number(v) * 100) / 100) },
    { key: 'dop', label: 'DOP', num: true },
    { key: 'queue_id', label: 'queue', num: true },
    { key: 'wait_order', label: 'wait order', num: true },
    { key: 'is_next_candidate', label: 'next candidate', fmt: yes },
    { key: 'is_small', label: 'small query', fmt: yes },
    { key: 'pool_id', label: 'pool', num: true },
    { key: 'wait_type', label: 'longest wait', fmt: (v, r) => v == null ? '' : String(v) + ' ' + ms(r.wait_ms) },
    { key: 'statement', label: 'statement', wide: true },
  ], 'No query held or waited for a memory grant at the newest read.'));

  // the caches (sp_PressureDetector's) and the plan cache by type (PerformanceMonitor's)
  sec.append(el('h3', {}, 'Caches (the newest read, the 20 largest)'), grid(rowsOf(d.caches), [
    { key: 'cache_name', label: 'cache' },
    { key: 'pages_kb', label: 'pages', num: true, fmt: mbOf },
    { key: 'pages_in_use_kb', label: 'in use', num: true, fmt: mbOf },
    { key: 'entries', label: 'entries', num: true },
    { key: 'entries_in_use', label: 'entries in use', num: true },
  ], 'No cache read in this range.'));
  const pc = rowsOf(d.plancache)[0];
  sec.append(el('h3', {}, 'Plan cache (the newest read)'));
  if (pc) {
    const lvl = String(pc.bloat_level ?? '');
    sec.append(el('div', { class: 'tiles' },
      tile('bloat', lvl, lvl === 'NORMAL' ? '' : 'warn'),
      tile('plans', fmtNum(pc.plans)),
      tile('single-use', fmtNum(pc.single_use_plans)),
      tile('single-use %', pct(pc.single_use_pct)),
      tile('cached plans size', kb(pc.size_kb)),
      tile('single-use size', kb(pc.single_use_kb)),
      tile('wasted %', pct(pc.wasted_pct)),
      tile('optimize for ad hoc', pc.optimize_for_ad_hoc == null ? 'not read' : Number(pc.optimize_for_ad_hoc) === 1 ? 'on' : 'off')),
    el('p', { class: 'meta' }, `${String(pc.recommendation ?? '')} (PerformanceMonitor's levels: single-use plans over 50 % CRITICAL, over 30 % HIGH, over 20 % MEDIUM).`));
  } else sec.append(el('p', { class: 'meta' }, 'No plan cache read in this range.'));
  sec.append(el('h3', {}, 'Plan cache by type'), grid(rowsOf(d.plancache_types), [
    { key: 'cache_type', label: 'cache' },
    { key: 'object_type', label: 'object type' },
    { key: 'plans', label: 'plans', num: true },
    { key: 'size_kb', label: 'size', num: true, fmt: kb },
    { key: 'single_use_plans', label: 'single-use', num: true },
    { key: 'single_use_kb', label: 'single-use size', num: true, fmt: kb },
    { key: 'avg_use_count', label: 'avg uses', num: true },
  ], 'No plan cache read in this range.'));
  for (const s of rowsOf(d.skipped)) sec.append(el('p', { class: 'meta' }, `Not read at ${fmtTime(s.snapshot_at)}: ${String(s.read)} (${String(s.error)}).`));
}

// mssqlThreadRow: sp_PressureDetector's thread usage (CPU section, L4122-4256) at the newest read: total, used and
// available threads, threads waiting for a CPU, requests waiting for a thread, current workers, the Resource Governor
// workload groups' counters (Workload Group Stats; 'Queued requests' is Resource Governor's throttling at
// GROUP_MAX_REQUESTS, not the worker queue), the average runnable tasks per scheduler and its runnable-request line
function mssqlThreadRow(n: Row): HTMLElement {
  const box = el('div', {});
  const used = Number(n.active_workers ?? 0), max = Number(n.max_workers ?? 0);
  box.append(el('h3', {}, 'Thread usage (sp_PressureDetector)'), grid([{
    total_threads: n.max_workers, used_threads: n.active_workers, available_threads: max ? max - used : null,
    threads_waiting_for_cpu: n.runnable_tasks, requests_waiting_for_threads: n.work_queue, current_workers: n.current_workers,
    rg_active_requests: n.rg_active_requests, rg_queued_requests: n.rg_queued_requests, rg_blocked_tasks: n.rg_blocked_tasks,
    rg_parallel_threads: n.rg_parallel_threads,
    avg_runnable: Number(n.schedulers) > 0 ? Math.round(100 * Number(n.runnable_tasks ?? 0) / Number(n.schedulers)) / 100 : null,
  }], [
    { key: 'total_threads', label: 'total threads', num: true }, { key: 'used_threads', label: 'used threads', num: true },
    { key: 'available_threads', label: 'available threads', num: true },
    { key: 'threads_waiting_for_cpu', label: 'threads waiting for CPU', num: true },
    { key: 'requests_waiting_for_threads', label: 'requests waiting for threads', num: true },
    { key: 'current_workers', label: 'current workers', num: true },
    { key: 'rg_active_requests', label: 'active requests (workload groups)', num: true },
    { key: 'rg_queued_requests', label: 'queued requests (Resource Governor throttling)', num: true },
    { key: 'rg_blocked_tasks', label: 'blocked tasks', num: true },
    { key: 'rg_parallel_threads', label: 'active parallel threads', num: true },
    { key: 'avg_runnable', label: 'average runnable tasks per scheduler', num: true },
  ]));
  const pctRun = Number(n.runnable_pct), total = Number(n.requests);
  box.append(el('p', { class: 'meta', 'data-runnable-pct': n.runnable_pct == null ? '' : String(n.runnable_pct) },
    n.requests_at == null ? 'Runnable requests: no requests read within 30 s of this read.'
      : pctRun >= 10 && total >= 4 ? `${fmtNum(pctRun)}% of ${fmtNum(total)} queries are waiting to get on a CPU (the requests read at ${fmtTime(n.requests_at)}; sp_PressureDetector's line, shown at 10 % of 4 or more).`
      : `${fmtNum(n.runnable_requests)} of ${fmtNum(total)} requests runnable at the requests read of ${fmtTime(n.requests_at)} (sp_PressureDetector names it at 10 % of 4 or more).`));
  return box;
}

// threadpoolBlock: THREADPOOL at the waiting-tasks read nearest the newest scheduler read (D01's count, which takes
// every task, and its tasks of sessions over 50); sp_PressureDetector's words when there is none
function threadpoolBlock(n: Row, tasks: Row[]): HTMLElement {
  const box = el('div', {}, el('h3', {}, 'THREADPOOL waits'));
  if (n.threadpool_at == null) { box.append(el('p', { class: 'meta' }, 'No waiting-tasks read within 30 s of this read.')); return box; }
  const c = Number(n.threadpool ?? 0);
  box.append(el('p', { class: 'meta', 'data-threadpool': String(c) }, c === 0 ? `No current THREADPOOL waits (the waiting-tasks read at ${fmtTime(n.threadpool_at)}).`
    : `${fmtNum(c)} task(s) waited for a worker thread at ${fmtTime(n.threadpool_at)}, the longest ${fmtNum(n.threadpool_longest_ms)} ms; a task queued before its login has no session and is counted here only.`));
  if (tasks.length) box.append(grid(tasks, [{ key: 'session_id', label: 'session', num: true }, { key: 'wait_ms', label: 'waited', num: true, fmt: ms }, { key: 'snapshot_at', label: 'read', fmt: fmtTime }]));
  return box;
}

// cpuInfoLine: sp_PressureDetector's CPU details as last read (the columns this server has)
function cpuInfoLine(n: Row): HTMLElement {
  const i = (n.cpu_info ?? {}) as Record<string, unknown>;
  const parts: [string, string][] = [['socket_count', 'sockets'], ['numa_node_count', 'NUMA nodes'], ['cpu_count', 'logical CPUs'],
    ['cores_per_socket', 'cores per socket'], ['hyperthread_ratio', 'hyperthread ratio'], ['softnuma_configuration_desc', 'soft-NUMA'],
    ['scheduler_count', 'schedulers'], ['scheduler_total_count', 'schedulers in all']];
  const said = parts.filter(([k]) => i[k] != null).map(([k, w]) => `${w} ${typeof i[k] === 'number' ? fmtNum(i[k]) : String(i[k])}`);
  return el('p', { class: 'meta', 'data-cpuinfo': String(said.length) }, said.length ? `CPU details (sys.dm_os_sys_info, sp_PressureDetector's list): ${said.join(', ')}.`
    : 'CPU details: not read yet (mssql_activity reads them every 5 minutes).');
}

// mssqlConnectionsView (task 177 D14): a SQL Server instance's sessions in PerformanceMonitor's Activity tab's shape:
// its Sessions tiles (connections, running, sleeping, dormant, applications, when read) with its session totals (background,
// idle over 30 minutes, databases with a connection, the top application and host, the requests waiting for memory),
// its Session Stats Trend, and its Sessions by Application, here also by host and by database. Data from
// /api/mssql/connections (the collection mssql_activity, every 5 minutes).
export async function mssqlConnectionsView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'summary' | 'series' | 'applications' | 'hosts' | 'databases', Table | null>>('mssql/connections', { instance: ctx.instance, ...window_(ctx) });
  const s = rowsOf(d.summary)[0], series = rowsOf(d.series);
  const sec = el('section', {}, el('h2', {}, `Connections (${rangeLabel(ctx)})`));
  if (!s) { sec.append(empty('sessions', 'mssql_activity', 'every 5 minutes')); return sec; }
  sec.append(el('p', { class: 'meta' }, 'From sys.dm_exec_sessions every 5 minutes: the totals count the sessions over 50; the groups count the user sessions over 50 '
    + 'with a program name, pgvigil\'s own left out (PerformanceMonitor\'s Sessions and Sessions by Application). Waiting for memory: the requests '
    + 'whose wait type names memory at the requests read nearest the sessions read.'));
  sec.append(el('h3', {}, `Sessions (${fmtTime(s.snapshot_at)})`), el('div', { class: 'tiles' },
    tile('connections', fmtNum(s.sessions)), tile('running', fmtNum(s.running)), tile('sleeping', fmtNum(s.sleeping)),
    tile('dormant', fmtNum(s.dormant)), tile('applications', fmtNum(s.applications)), tile('background', fmtNum(s.background)),
    tile('idle over 30 min', fmtNum(s.idle_30min)), tile('databases with connections', fmtNum(s.databases)),
    tile('top application', s.top_application == null ? '-' : `${String(s.top_application)} (${fmtNum(s.top_application_sessions)})`),
    tile('top host', s.top_host == null ? '-' : `${String(s.top_host)} (${fmtNum(s.top_host_sessions)})`),
    tile('waiting for memory', s.requests_at == null ? 'not read' : fmtNum(s.waiting_for_memory)),
  ));
  const box = el('div', { class: 'charts' });
  box.append(lineChart('Session stats trend', series, [{ key: 'sessions', label: 'total' }, { key: 'running', label: 'running' },
    { key: 'sleeping', label: 'sleeping' }, { key: 'background', label: 'background' }, { key: 'dormant', label: 'dormant' },
    { key: 'idle_30min', label: 'idle over 30 min' }, { key: 'waiting_for_memory', label: 'waiting for memory' }], v => fmtNum(v)));
  sec.append(box);
  const cols = (first: string): Col[] => [
    { key: 'name', label: first }, { key: 'sessions', label: 'connections', num: true }, { key: 'running', num: true },
    { key: 'sleeping', num: true }, { key: 'dormant', num: true }, { key: 'cpu_ms', label: 'CPU', num: true, fmt: ms },
    { key: 'reads', num: true }, { key: 'writes', num: true }, { key: 'logical_reads', label: 'logical reads', num: true },
  ];
  sec.append(el('h3', {}, 'Sessions by application'), grid(rowsOf(d.applications), cols('application'), 'No user session with a program name at the newest read.'));
  sec.append(el('h3', {}, 'Sessions by host'), grid(rowsOf(d.hosts), cols('host'), 'No user session with a host name at the newest read.'));
  sec.append(el('h3', {}, 'Sessions by database'), grid(rowsOf(d.databases), cols('database'), 'No user session at the newest read.'));
  sec.append(el('p', { class: 'meta' }, 'The sessions running now: ', el('a', { href: href(ctx, { tab: 'mssql_running' }) }, 'Running queries'), '.'));
  return sec;
}
