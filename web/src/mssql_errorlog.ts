// The SQL Server readers' tabs of an instance (task 149): Error log (the kept lines newest first, with a class, a text
// and a severity filter over the page's time range; the instance's own search strings), Default trace (file growths
// and shrinks, DBCC commands with who ran them, DDL) and System health (sp_server_diagnostics' four components as
// system_health recorded them, with PerformanceMonitor's System Events: the corruption and contention counter charts,
// the memory broker, memory node OOM, scheduler monitor and significant-wait grids of the events read beside them,
// task 177 D15). Each says what its reader could read: a missing right is shown as such, never as a failure. Data from /api/mssql/errorlog, /defaulttrace and /syshealth; the lead wires the tabs (router.ts, main.ts).
import { get, Row, rowsOf, Table } from './api';
import { waitingLink } from './darling_waiting';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';

type Part = Table | null;
const text = (v: unknown) => v == null ? '' : String(v);
const sevBadge = (v: unknown) => badge(text(v), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const ms = (v: unknown) => v == null ? '' : fmtNum(v) + ' ms';
const mb = (v: unknown) => v == null ? '' : fmtNum(v) + ' MB';

const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'finding' }, { key: 'object', wide: true },
  { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
];

// the findings of one reader's page (the instance's others are on the Findings page): the page's own checks, and the
// readers' state findings that name this page's reader
function findingsOf(t: Part, prefix: string[], reader: string): HTMLElement | null {
  const rows = rowsOf(t).filter(r => text(r.check_name).startsWith('a SQL Server reader')
    ? text(r.object).split(', ').includes(reader)
    : prefix.some(p => text(r.check_name).startsWith(p)));
  return rows.length ? el('section', {}, el('h3', {}, 'Findings'), grid(rows, findingCols)) : null;
}

const readerName: Record<string, string> = { errorlog: 'error log', defaulttrace: 'default trace', syshealth: 'system_health' };

// readerNote says what the reader's last read was: read (with what it covered), no right (what to grant), off, failed.
function readerNote(t: Part, reader: string): HTMLElement {
  const st = rowsOf(t).find(r => r.reader === reader);
  const what = readerName[reader] ?? reader;
  if (!st) {
    return el('p', { class: 'meta' }, badge('not read yet', ''), ` The ${what} reader (every 5 minutes) has not read this instance yet. `
      + 'Azure SQL Database has none of these sources: there it never runs (the Summary\'s collection panel says why).');
  }
  const read = `read ${fmtTime(st.snapshot_at)}`;
  switch (st.state) {
    case 'no right':
      return el('p', { class: 'meta' }, badge('no right', 'warn'), ` Not read, for lack of a right - not a failure: ${text(st.note)} (checked ${fmtTime(st.snapshot_at)}).`);
    case 'off':
      return el('p', { class: 'meta' }, badge('off', 'warn'), ` ${text(st.note)} (${read}).`);
    case 'failed':
      return el('p', { class: 'meta' }, badge('failed', 'crit'), ` ${text(st.note)} (${read}, failing since ${fmtTime(st.state_since)}).`);
  }
  const bits: string[] = [];
  if (st.scope) bits.push(text(st.scope));
  if (st.scanned != null) bits.push(`${fmtNum(st.scanned)} passed over and ${fmtNum(st.stored)} kept by the last read`);
  if (st.oldest_at) bits.push(`the trace holds events from ${fmtTime(st.oldest_at)}`);
  if (st.newest_at) bits.push(`read up to ${fmtTime(st.newest_at)}`);
  const p = el('p', { class: 'meta' }, badge('read', 'ok'), ` ${bits.join(', ')} (${read}).`);
  if (st.note) p.append(' ', el('strong', {}, text(st.note)));
  return p;
}

// ---- Error log

const lineCols: Col[] = [
  { key: 'log_at', label: 'when', fmt: fmtTime },
  { key: 'severity', num: true, fmt: v => v == null ? '' : String(v), cls: v => Number(v) >= 20 ? 'crit' : Number(v) >= 17 ? 'warn' : '' },
  { key: 'error_number', label: 'error', num: true, fmt: v => v == null ? '' : String(v) },
  { key: 'class', fmt: v => v === 'corruption' ? badge('corruption', 'crit') : text(v) },
  { key: 'message', label: 'line', wide: true },
  { key: 'process' },
  { key: 'matched', label: 'matched', fmt: (v, r) => (Array.isArray(v) ? v.join(', ') : '') + (r.custom === true ? ' (own)' : '') },
  { key: 'logged_local', label: 'server clock' },
  { key: 'archive', num: true, fmt: v => v == null ? '' : Number(v) === 0 ? 'current' : `archive ${v}` },
];

const classCols: Col[] = [
  { key: 'class' }, { key: 'lines', num: true }, { key: 'severe', label: 'severity 17+', num: true },
  { key: 'own', label: 'own strings', num: true }, { key: 'last_at', label: 'last', fmt: fmtTime },
];

function searchNote(t: Part): HTMLElement {
  const r = rowsOf(t)[0];
  let list: string[] = [];
  try { list = r ? JSON.parse(text(r.strings)) as string[] : []; } catch { list = []; }
  if (!list.length) {
    return el('p', { class: 'meta' }, 'The lines kept are those sp_LogHunter\'s search strings find (less its noise list) and every error of severity 17 or higher. '
      + 'An instance may add its own strings: ', el('code', {}, 'SELECT pgvigil.mssql_errorlog_search_set(\'<instance>\', ARRAY[\'...\'], false);'),
      ' as the repository owner (docs/sqlserver-readers.md).');
  }
  return el('p', { class: 'meta' }, `This instance's own search strings (${list.length}${r.only_these === true ? ', searched alone: the shipped list is not' : ''}): `,
    el('code', {}, list.join(' | ')), ` (set ${fmtTime(r.updated_at)}).`);
}

export async function mssqlErrorLogView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Error log (${rangeLabel(ctx)})`));
  const win = window_(ctx);
  try {
    const d = await get<Record<string, Part>>('mssql/errorlog', { instance: ctx.instance, ...win });
    const f = findingsOf(d.findings, ['error log'], 'errorlog');
    if (f) sec.append(f);
    sec.append(readerNote(d.state, 'errorlog'), searchNote(d.search));
    const classes = rowsOf(d.classes);
    const total = classes.reduce((n, r) => n + Number(r.lines ?? 0), 0);
    const severe = classes.reduce((n, r) => n + Number(r.severe ?? 0), 0);
    sec.append(el('div', { class: 'tiles' }, tile('lines kept', fmtNum(total)), tile('severity 17 or higher', fmtNum(severe), severe > 0 ? 'warn' : ''),
      tile('corruption', fmtNum(Number(classes.find(r => r.class === 'corruption')?.lines ?? 0)), classes.some(r => r.class === 'corruption') ? 'crit' : '')));
    sec.append(el('details', {}, el('summary', {}, 'Lines per class'), grid(classes, classCols, 'No line kept in this window.')));

    // the filters read the lines part again; the range is the page's
    const cls = el('select', { 'aria-label': 'class' }, el('option', { value: '' }, 'every class'),
      ...['corruption', 'memory', 'io', 'scheduler', 'availability', 'startup', 'config', 'general'].map(c => el('option', { value: c }, c)));
    const q = el('input', { type: 'search', placeholder: 'text in the line', 'aria-label': 'text in the line', maxlength: '200' });
    const sev = el('input', { type: 'checkbox', id: 'el-sev17' });
    const box = el('div', {});
    const show = (rows: Row[]) => box.replaceChildren(
      el('p', { class: 'meta' }, `${fmtNum(rows.length)}${rows.length >= 1000 ? '+ (the newest 1,000)' : ''} line(s), newest first; the server clock column is the time as the log wrote it.`),
      grid(rows, lineCols, 'No line in this window matches.'));
    show(rowsOf(d.lines));
    let seq = 0;
    const reload = async () => {
      const mine = ++seq;
      try {
        const t = await get<Record<string, Part>>('mssql/errorlog', { instance: ctx.instance, ...win, part: 'lines',
          class: cls.value || undefined, q: q.value.trim() || undefined, sev: sev.checked ? 17 : undefined });
        if (mine === seq) show(rowsOf(t.lines));
      } catch (e) {
        if (mine === seq) box.replaceChildren(errorBox(e));
      }
    };
    cls.addEventListener('change', () => { void reload(); });
    sev.addEventListener('change', () => { void reload(); });
    let timer = 0;
    q.addEventListener('input', () => { clearTimeout(timer); timer = window.setTimeout(() => { void reload(); }, 300); });
    sec.append(el('div', { class: 'toolbar' }, cls, q, el('label', { for: 'el-sev17' }, sev, ' severity 17 or higher only')), box);
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- Default trace

const growthSummaryCols: Col[] = [
  { key: 'database_name', label: 'database' }, { key: 'kind' }, { key: 'events', num: true },
  { key: 'slow', label: 'over 1 s', num: true, cls: v => Number(v) > 0 ? 'warn' : '' },
  { key: 'worst_ms', label: 'slowest', num: true, fmt: ms }, { key: 'total_ms', label: 'total time', num: true, fmt: ms },
  { key: 'size_mb', label: 'size change', num: true, fmt: mb }, { key: 'last_at', label: 'last', fmt: fmtTime },
];
const growthCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'kind', fmt: v => text(v).includes('shrink') ? badge(text(v), 'warn') : text(v) },
  { key: 'database_name', label: 'database' }, { key: 'file_name', label: 'file' },
  { key: 'duration_ms', label: 'took', num: true, fmt: ms, cls: v => Number(v) > 1000 ? 'warn' : '' },
  { key: 'size_change_mb', label: 'size change', num: true, fmt: mb },
  { key: 'program_name', label: 'program' }, { key: 'login_name', label: 'login' }, { key: 'session_id', label: 'session', num: true },
];
const disruptive = new Set(['DBCC FREEPROCCACHE', 'DBCC FREESYSTEMCACHE', 'DBCC DROPCLEANBUFFERS', 'DBCC WRITEPAGE']);
const dbccSummaryCols: Col[] = [
  { key: 'command', fmt: v => disruptive.has(text(v)) ? badge(text(v), 'warn') : text(v) }, { key: 'runs', num: true },
  { key: 'logins' }, { key: 'databases' }, { key: 'first_at', label: 'first', fmt: fmtTime }, { key: 'last_at', label: 'last', fmt: fmtTime },
];
const dbccCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'command' }, { key: 'database_name', label: 'database' },
  { key: 'login_name', label: 'login' }, { key: 'host_name', label: 'host' }, { key: 'program_name', label: 'program' },
  { key: 'session_id', label: 'session', num: true }, { key: 'statement', wide: true },
];
const ddlCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'action' }, { key: 'database_name', label: 'database' },
  { key: 'object_name', label: 'object' }, { key: 'object_type', label: 'type' }, { key: 'login_name', label: 'login' },
  { key: 'host_name', label: 'host' }, { key: 'program_name', label: 'program' },
];

export async function mssqlDefaultTraceView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Default trace (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<string, Part>>('mssql/defaulttrace', { instance: ctx.instance, ...window_(ctx) });
    const f = findingsOf(d.findings, ['default trace'], 'defaulttrace');
    if (f) sec.append(f);
    sec.append(readerNote(d.state, 'defaulttrace'));
    sec.append(el('h3', {}, 'File growths and shrinks'),
      el('p', { class: 'meta' }, 'A growth the server made by itself because the file was full; a session that needed the space waited for it. '
        + 'A growth over 1 s is a finding. A shrink here is AUTO_SHRINK at work (a DBCC SHRINKFILE is under DBCC commands).'),
      grid(rowsOf(d.growth_summary), growthSummaryCols, 'No growth or shrink in this window.'),
      el('details', {}, el('summary', {}, 'One by one'), grid(rowsOf(d.growths), growthCols, 'No growth or shrink in this window.')));
    sec.append(el('h3', {}, 'DBCC commands'),
      el('p', { class: 'meta' }, 'Who ran which DBCC command. FREEPROCCACHE, FREESYSTEMCACHE, DROPCLEANBUFFERS and WRITEPAGE are marked; '
        + 'a FREEPROCCACHE with a plan handle evicts one plan and is listed apart. pgvigil\'s own DBCC calls are left out.'),
      grid(rowsOf(d.dbcc_summary), dbccSummaryCols, 'No DBCC command in this window.'),
      el('details', {}, el('summary', {}, 'One by one'), grid(rowsOf(d.dbcc), dbccCols, 'No DBCC command in this window.')));
    sec.append(el('h3', {}, 'Schema changes (DDL)'),
      el('p', { class: 'meta' }, 'Objects created, dropped and altered outside tempdb, as the default trace recorded them (statistics left out).'),
      grid(rowsOf(d.ddl), ddlCols, 'No DDL in this window.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- System health

const stateBadge = (v: unknown) => badge(text(v), v === 'ERROR' ? 'crit' : v === 'WARNING' ? 'warn' : v === 'CLEAN' ? 'ok' : '');
const flag = (v: unknown) => Number(v) > 0 ? 'crit' : '';

const systemCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'state', fmt: stateBadge },
  { key: 'sql_cpu', label: 'SQL CPU %', num: true }, { key: 'system_cpu', label: 'system CPU %', num: true },
  { key: 'non_yielding', label: 'non-yielding', num: true, cls: flag }, { key: 'latch_warnings', label: 'latch warnings', num: true, cls: flag },
  { key: 'spinlock_backoffs', label: 'spinlock backoffs', num: true }, { key: 'sick_spinlock', label: 'sick spinlock', cls: v => v ? 'crit' : '' },
  { key: 'bad_pages_detected', label: 'bad pages', num: true, cls: flag }, { key: 'bad_pages_fixed', label: 'fixed', num: true },
  { key: 'access_violation', label: 'access violation', num: true, cls: flag },
  { key: 'write_access_violations', label: 'write access violations', num: true, cls: flag },
  { key: 'dump_requests', label: 'dump requests', num: true, cls: flag },
  { key: 'page_faults', label: 'page faults', num: true },
];
const qpCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'state', fmt: stateBadge },
  { key: 'pending_tasks', label: 'pending tasks', num: true, cls: v => Number(v) >= 10 ? 'warn' : '' },
  { key: 'oldest_pending_ms', label: 'oldest pending', num: true, fmt: ms },
  { key: 'max_workers', label: 'max workers', num: true }, { key: 'workers_created', label: 'workers', num: true },
  { key: 'workers_idle', label: 'idle', num: true }, { key: 'tasks_completed', label: 'tasks completed', num: true },
  { key: 'unresolvable_deadlock', label: 'unresolvable deadlock', num: true, cls: flag },
  { key: 'deadlocked_schedulers', label: 'deadlocked schedulers', num: true, cls: flag },
];
const ioCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'state', fmt: stateBadge },
  { key: 'interval_long_ios', label: 'long IOs', num: true, cls: flag }, { key: 'io_latch_timeouts', label: 'IO latch timeouts', num: true, cls: flag },
  { key: 'total_long_ios', label: 'long IOs since start', num: true },
  { key: 'longest', label: 'longest pending', wide: true, fmt: v => Array.isArray(v) ? v.map(x => `${text((x as Row).filePath)} ${fmtNum((x as Row).duration)} ms`).join('; ') : '' },
];
// a grid whose columns come in groups, each switched on and off by a check box above it (PerformanceMonitor's column
// groups, its defaults on): the base columns always, then each group's that is on
type ColGroup = { name: string; cols: Col[]; on: boolean };
function groupedGrid(title: string, rows: Row[], base: Col[], groups: ColGroup[], empty: string): HTMLElement {
  const box = el('div', { class: 'grouped-grid' });
  let current = grid(rows, [...base, ...groups.filter(g => g.on).flatMap(g => g.cols)], empty);
  const boxes = groups.map(g => {
    const cb = el('input', { type: 'checkbox' }) as HTMLInputElement;
    cb.checked = g.on;
    cb.addEventListener('change', () => {
      g.on = cb.checked;
      const next = grid(rows, [...base, ...groups.filter(x => x.on).flatMap(x => x.cols)], empty);
      current.replaceWith(next); current = next;
    });
    return el('label', {}, cb, ` ${g.name}`);
  });
  box.append(el('fieldset', { class: 'filters' }, el('legend', {}, `${title}: column groups`), ...boxes), current);
  return box;
}

const yes = (v: unknown) => Number(v) > 0 || v === 'true' ? 'warn' : '';
const kb = (v: unknown) => v == null ? '' : fmtNum(v) + ' KB';

const resourceBase: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'state', fmt: stateBadge },
  { key: 'last_notification', label: 'last notification', cls: v => text(v).endsWith('_LOW') ? 'warn' : '' },
  { key: 'oom_exceptions', label: 'out-of-memory exceptions', num: true, cls: flag },
  { key: 'pool_out_of_memory', label: 'pool out of memory', num: true, cls: flag },
  { key: 'target_committed_mb', label: 'target committed', num: true, fmt: mb },
  { key: 'current_committed_mb', label: 'committed', num: true, fmt: mb },
];
const resourceGroups = (): ColGroup[] => [
  { name: 'Process memory', on: true, cols: [
    { key: 'available_physical_mb', label: 'available physical', num: true, fmt: mb },
    { key: 'available_virtual_mb', label: 'available virtual', num: true, fmt: mb },
    { key: 'available_paging_mb', label: 'available paging file', num: true, fmt: mb },
    { key: 'working_set_mb', label: 'working set', num: true, fmt: mb },
    { key: 'pct_committed_in_ws', label: '% committed in working set', num: true },
    { key: 'page_faults', label: 'page faults', num: true },
  ] },
  { name: 'Pressure flags', on: false, cols: [
    { key: 'system_memory_high', label: 'system physical memory high', num: true },
    { key: 'system_memory_low', label: 'system physical memory low', num: true, cls: flag },
    { key: 'process_memory_low', label: 'process physical memory low', num: true, cls: flag },
    { key: 'process_virtual_low', label: 'process virtual memory low', num: true, cls: flag },
  ] },
];

// the events read beside the component results (0120): sp_HealthParser's columns, PerformanceMonitor's grids
const brokerCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'broker_id', label: 'broker id', num: true }, { key: 'broker' },
  { key: 'notification', cls: v => text(v) === 'SHRINK' ? 'warn' : '' }, { key: 'pool_metadata_id', label: 'pool metadata id', num: true },
  { key: 'delta_time', label: 'delta time', num: true }, { key: 'memory_ratio', label: 'memory ratio', num: true },
  { key: 'new_target', label: 'new target', num: true }, { key: 'overall', num: true }, { key: 'rate', num: true },
  { key: 'currently_predicated', label: 'predicated', num: true }, { key: 'currently_allocated', label: 'allocated', num: true },
  { key: 'previously_allocated', label: 'previously allocated', num: true },
];
const oomBase: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'node_id', label: 'node id', num: true },
  { key: 'memory_node_id', label: 'memory node id', num: true }, { key: 'memory_utilization_pct', label: 'memory utilization %', num: true },
];
const oomGroups = (): ColGroup[] => [
  { name: 'Memory sizes', on: false, cols: [
    { key: 'total_physical_memory_kb', label: 'total physical', num: true, fmt: kb },
    { key: 'available_physical_memory_kb', label: 'available physical', num: true, fmt: kb },
    { key: 'total_page_file_kb', label: 'total page file', num: true, fmt: kb },
    { key: 'available_page_file_kb', label: 'available page file', num: true, fmt: kb },
    { key: 'total_virtual_address_space_kb', label: 'total virtual address space', num: true, fmt: kb },
    { key: 'available_virtual_address_space_kb', label: 'available virtual address space', num: true, fmt: kb },
  ] },
  { name: 'Pool detail', on: false, cols: [
    { key: 'target_kb', label: 'target', num: true, fmt: kb }, { key: 'reserved_kb', label: 'reserved', num: true, fmt: kb },
    { key: 'committed_kb', label: 'committed', num: true, fmt: kb }, { key: 'shared_committed_kb', label: 'shared committed', num: true, fmt: kb },
    { key: 'awe_kb', label: 'AWE', num: true, fmt: kb }, { key: 'pages_kb', label: 'pages', num: true, fmt: kb },
  ] },
  { name: 'Failure', on: true, cols: [
    { key: 'failure_type', label: 'failure', cls: v => v ? 'crit' : '' }, { key: 'failure_value', label: 'failure value', num: true },
    { key: 'resources', wide: true }, { key: 'factor_text', label: 'factor' }, { key: 'factor_value', label: 'factor value', num: true },
    { key: 'last_error', label: 'last error' },
  ] },
  { name: 'Flags', on: false, cols: [
    { key: 'pool_metadata_id', label: 'pool metadata id', num: true }, { key: 'is_process_in_job', label: 'in a job' },
    { key: 'is_system_physical_memory_high', label: 'system physical memory high' },
    { key: 'is_system_physical_memory_low', label: 'system physical memory low', cls: yes },
    { key: 'is_process_physical_memory_low', label: 'process physical memory low', cls: yes },
    { key: 'is_process_virtual_memory_low', label: 'process virtual memory low', cls: yes },
  ] },
];
const schedulerCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime },
  { key: 'sql_cpu', label: 'SQL Server CPU %', num: true, cls: v => Number(v) >= 90 ? 'warn' : '' },
  { key: 'other_cpu', label: 'other processes CPU %', num: true, cls: v => Number(v) >= 50 ? 'warn' : '' },
  { key: 'system_idle', label: 'idle %', num: true },
  { key: 'memory_utilization', label: 'memory utilization %', num: true, cls: v => v != null && Number(v) <= 50 ? 'warn' : '' },
  { key: 'page_faults', label: 'page faults', num: true }, { key: 'working_set_delta_mb', label: 'working set change', num: true, fmt: mb },
];
const waitCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime },
  { key: 'wait_type', label: 'wait type', fmt: v => v ? waitingLink(text(v), text(v)) : '' },
  { key: 'duration_ms', label: 'duration', num: true, fmt: ms }, { key: 'signal_duration_ms', label: 'signal duration', num: true, fmt: ms },
  { key: 'wait_resource', label: 'wait resource', wide: true }, { key: 'session_id', label: 'session', num: true },
  { key: 'statement', wide: true },
];

// PerformanceMonitor's Corruption Events and Contention Events charts: each SYSTEM counter as the largest value in its
// time bucket; a counter no result carried in this window says so instead of drawing a zero line
const counterCharts = [
  { group: 'Corruption events', title: 'Bad pages', key: 'bad_pages', empty: 'No bad pages were reported' },
  { group: 'Corruption events', title: 'Dump requests', key: 'dump_requests', empty: 'No dump request count was reported' },
  { group: 'Corruption events', title: 'Access violations', key: 'access_violations', empty: 'No access violation count was reported' },
  { group: 'Corruption events', title: 'Write access violations', key: 'write_access_violations', empty: 'No write access violation count was reported' },
  { group: 'Contention events', title: 'Non-yielding tasks', key: 'non_yielding', empty: 'No non-yielding task count was reported' },
  { group: 'Contention events', title: 'Latch warnings', key: 'latch_warnings', empty: 'No latch warning count was reported' },
];
const whole = (v: number) => Math.round(v).toLocaleString();
const hasValue = (rows: Row[], key: string) => rows.some(r => r[key] != null && !Number.isNaN(Number(r[key])));
function emptyChart(title: string, words: string): HTMLElement {
  return el('div', { class: 'chart' }, el('h3', {}, title), el('p', { class: 'empty' }, words));
}
// one line per sick spinlock type: its largest backoffs per bucket of the series, a gap where the bucket did not name it
function spinlockChart(series: Row[], spins: Row[]): HTMLElement {
  const title = 'Contention events: sick spinlocks (backoffs)';
  const types = [...new Set(spins.map(r => text(r.spinlock_type)))].sort();
  if (!types.length) return emptyChart(title, 'No sick spinlock was reported in this window.');
  const at = (v: unknown) => new Date(text(v)).getTime();
  const rows = series.map(b => {
    const r: Row = { snapshot_at: b.snapshot_at };
    types.forEach((t, i) => { r['s' + i] = spins.find(x => text(x.spinlock_type) === t && at(x.snapshot_at) === at(b.snapshot_at))?.backoffs ?? null; });
    return r;
  });
  return lineChart(title, rows, types.map((t, i) => ({ key: 's' + i, label: t })), whole);
}
const issueCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'component' }, { key: 'state', fmt: stateBadge },
  { key: 'last_notification', label: 'last notification' },
];

export async function mssqlSysHealthView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `System health (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<string, Part>>('mssql/syshealth', { instance: ctx.instance, ...window_(ctx) });
    const f = findingsOf(d.findings, ['system_health'], 'syshealth');
    if (f) sec.append(f);
    const ef = rowsOf(d.event_findings);
    if (ef.length) sec.append(el('section', {}, el('h3', {}, 'Findings of the system events'), grid(ef, findingCols)));
    sec.append(readerNote(d.state, 'syshealth'),
      el('p', { class: 'meta' }, 'SQL Server checks four parts of itself every five minutes (sp_server_diagnostics) and its system_health session '
        + 'keeps each result; pgvigil reads that session and never changes it.'));
    const latest = rowsOf(d.latest);
    sec.append(el('div', { class: 'tiles' }, ...['SYSTEM', 'RESOURCE', 'QUERY_PROCESSING', 'IO_SUBSYSTEM'].map(c => {
      const r = latest.find(x => x.component === c);
      const s = r ? text(r.state) : 'no result';
      return tile(c.toLowerCase().replace('_', ' ') + (r ? ` (${fmtTime(r.event_at)})` : ''), s, s === 'ERROR' ? 'crit' : s === 'WARNING' ? 'warn' : s === 'CLEAN' ? 'ok' : '');
    })));
    const series = rowsOf(d.series);
    sec.append(lineChart('Results not CLEAN and pending tasks', series, [{ key: 'not_clean', label: 'results not CLEAN' }, { key: 'pending_tasks', label: 'pending tasks' }]),
      lineChart('CPU from the SYSTEM component (%)', series, [{ key: 'sql_cpu', label: 'SQL Server' }, { key: 'system_cpu', label: 'the machine' }]));
    const spins = rowsOf(d.spinlocks);
    // PerformanceMonitor leaves the counter cards out of a window with no system_health row: no SYSTEM result, no card
    // (an empty card would read as a clean server where nothing was read)
    const systemRead = hasValue(series, 'sql_cpu') || rowsOf(d.system).length > 0;
    if (!systemRead) sec.append(el('p', { class: 'meta' }, 'No SYSTEM result is stored for this window: the corruption and contention charts need one (the state above says why).'));
    if (systemRead && (counterCharts.some(c => hasValue(series, c.key)) || spins.length)) {
      sec.append(el('p', { class: 'meta' }, 'The corruption and contention counters are charted below (each point is the largest value in its time bucket); the raw rows follow.'));
    }
    if (systemRead) sec.append(el('div', { class: 'charts' },
      ...counterCharts.map(c => hasValue(series, c.key)
        ? lineChart(`${c.group}: ${c.title.toLowerCase()}`, series, [{ key: c.key, label: c.title }], whole)
        : emptyChart(`${c.group}: ${c.title.toLowerCase()}`, `${c.empty} in this window.`)),
      spinlockChart(series, spins)));
    const stored = series.reduce((n, r) => n + Number(r.results ?? 0), 0);
    sec.append(el('h3', {}, 'Results that were not CLEAN'), grid(rowsOf(d.issues), issueCols,
      stored > 0 ? 'Every result in this window was CLEAN.' : 'No system_health result is stored for this window (the state above says why).'));
    sec.append(el('h3', {}, 'SYSTEM'), el('p', { class: 'meta' }, 'Counters since the server started: a non-zero bad-page, access-violation, non-yielding or latch-warning figure stays until the server restarts.'),
      grid(rowsOf(d.system), systemCols, 'No SYSTEM result in this window.'));
    sec.append(el('h3', {}, 'RESOURCE (memory)'),
      groupedGrid('RESOURCE', rowsOf(d.resource), resourceBase, resourceGroups(), 'No RESOURCE result in this window.'));
    sec.append(el('h3', {}, 'QUERY_PROCESSING (workers and tasks)'), grid(rowsOf(d.query_processing), qpCols, 'No QUERY_PROCESSING result in this window.'));
    sec.append(el('h3', {}, 'IO_SUBSYSTEM'), el('p', { class: 'meta' }, 'Only the results that saw a long IO (over 15 s) or an IO latch timeout, or were not CLEAN.'),
      grid(rowsOf(d.io), ioCols, 'No long IO and no IO latch timeout in this window.'));
    sec.append(el('p', { class: 'meta' }, 'The four grids below hold the events system_health keeps beside the component results; pgvigil reads them from the '
      + 'version that added them on (a read already past older files does not go back), so an empty grid is what was stored, not proof of a quiet server.'));
    sec.append(el('h3', {}, 'Scheduler monitor'), el('p', { class: 'meta' }, 'The samples system_health keeps of SQL Server\'s CPU, the idle CPU and '
      + 'memory utilization (the share of SQL Server\'s committed memory in its working set), here those past one of sp_HealthParser\'s '
      + 'warnings: SQL Server at 90 % or more, other processes at 50 % or more, memory utilization at 50 or less. SQL Server on Linux writes '
      + 'the idle CPU as 0 in every sample, so there the idle and other processes\' shares are not read (blank).'),
      grid(rowsOf(d.scheduler), schedulerCols, Number(rowsOf(d.scheduler_samples)[0]?.samples ?? 0) > 0
        ? 'No stored scheduler monitor sample crossed a warning in this window.'
        : 'No scheduler monitor sample is stored for this window.'));
    sec.append(el('h3', {}, 'Memory broker'), el('p', { class: 'meta' }, 'The memory broker\'s notifications to its clerks (grow, shrink, stable) as system_health keeps them.'),
      grid(rowsOf(d.broker), brokerCols, 'No memory broker event is stored for this window.'));
    sec.append(el('h3', {}, 'Memory node OOM'),
      groupedGrid('Memory node OOM', rowsOf(d.node_oom), oomBase, oomGroups(), 'No memory node out-of-memory event is stored for this window.'));
    sec.append(el('h3', {}, 'Significant waits'), el('p', { class: 'meta' }, 'A real session waiting 500 ms or more on a wait type that is not idle '
      + '(system_health keeps a wait only when it is long: 15 s on a latch, 30 s on a lock); the wait type opens the Waiting tasks tab filtered to it.'),
      grid(rowsOf(d.waits), waitCols, 'No significant wait is stored for this window.'));
    const newest = latest.find(r => r.component === 'RESOURCE');
    if (newest) {
      const m = (newest.detail as Row | null)?.memory as Row | undefined;
      if (m) sec.append(el('details', {}, el('summary', {}, 'The newest memory report, as the server wrote it'),
        props(Object.entries(m).map(([k, v]) => [k, fmtNum(v)] as [string, string]))));
    }
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
