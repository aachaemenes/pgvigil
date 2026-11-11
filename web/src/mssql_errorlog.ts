// The SQL Server readers' tabs of an instance (task 149): Error log (the kept lines newest first, with a class, a text
// and a severity filter over the page's time range; the instance's own search strings), Default trace (file growths
// and shrinks, DBCC commands with who ran them, DDL) and System health (sp_server_diagnostics' four components as
// system_health recorded them). Each says what its reader could read: a missing right is shown as such, never as a
// failure. Data from /api/mssql/errorlog, /defaulttrace and /syshealth; the lead wires the tabs (router.ts, main.ts).
import { get, Row, rowsOf, Table } from './api';
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

// the findings of one reader's page (the instance's others are on the Findings page)
function findingsOf(t: Part, prefix: string[]): HTMLElement | null {
  const rows = rowsOf(t).filter(r => prefix.some(p => text(r.check_name).startsWith(p)));
  return rows.length ? el('section', {}, el('h3', {}, 'Findings'), grid(rows, findingCols)) : null;
}

const readerName: Record<string, string> = { errorlog: 'error log', defaulttrace: 'default trace', syshealth: 'system_health' };

// readerNote says what the reader's last read was: read (with what it covered), no right (what to grant), off, failed.
function readerNote(t: Part, reader: string): HTMLElement {
  const st = rowsOf(t).find(r => r.reader === reader);
  const what = readerName[reader] ?? reader;
  if (!st) return el('p', { class: 'meta' }, badge('not read yet', ''), ` The ${what} reader (every 5 minutes) has not read this instance yet.`);
  const read = `read ${fmtTime(st.snapshot_at)}`;
  switch (st.state) {
    case 'no right':
      return el('p', { class: 'meta' }, badge('no right', 'warn'), ` Not read, for lack of a right - not a failure: ${text(st.note)} (${read}).`);
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
    const f = findingsOf(d.findings, ['error log', 'a SQL Server reader']);
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
    const f = findingsOf(d.findings, ['default trace', 'a SQL Server reader']);
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
  { key: 'access_violation', label: 'access violation', num: true, cls: flag }, { key: 'dump_requests', label: 'dump requests', num: true, cls: flag },
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
const resourceCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'state', fmt: stateBadge },
  { key: 'last_notification', label: 'last notification', cls: v => text(v).endsWith('_LOW') ? 'warn' : '' },
  { key: 'oom_exceptions', label: 'out-of-memory exceptions', num: true, cls: flag },
  { key: 'pool_out_of_memory', label: 'pool out of memory', num: true, cls: flag },
  { key: 'available_physical_mb', label: 'available physical', num: true, fmt: mb },
  { key: 'working_set_mb', label: 'working set', num: true, fmt: mb },
  { key: 'system_memory_low', label: 'system memory low', num: true, cls: flag },
  { key: 'process_memory_low', label: 'process memory low', num: true, cls: flag },
  { key: 'target_committed_mb', label: 'target committed', num: true, fmt: mb },
  { key: 'current_committed_mb', label: 'committed', num: true, fmt: mb },
];
const issueCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'component' }, { key: 'state', fmt: stateBadge },
  { key: 'last_notification', label: 'last notification' },
];

export async function mssqlSysHealthView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `System health (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<string, Part>>('mssql/syshealth', { instance: ctx.instance, ...window_(ctx) });
    const f = findingsOf(d.findings, ['system_health', 'a SQL Server reader']);
    if (f) sec.append(f);
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
    sec.append(el('h3', {}, 'Results that were not CLEAN'), grid(rowsOf(d.issues), issueCols, 'Every result in this window was CLEAN.'));
    sec.append(el('h3', {}, 'SYSTEM'), el('p', { class: 'meta' }, 'Counters since the server started: a non-zero bad-page, access-violation, non-yielding or latch-warning figure stays until the server restarts.'),
      grid(rowsOf(d.system), systemCols, 'No SYSTEM result in this window.'));
    sec.append(el('h3', {}, 'RESOURCE (memory)'), grid(rowsOf(d.resource), resourceCols, 'No RESOURCE result in this window.'));
    sec.append(el('h3', {}, 'QUERY_PROCESSING (workers and tasks)'), grid(rowsOf(d.query_processing), qpCols, 'No QUERY_PROCESSING result in this window.'));
    sec.append(el('h3', {}, 'IO_SUBSYSTEM'), el('p', { class: 'meta' }, 'Only the results that saw a long IO (over 15 s) or an IO latch timeout, or were not CLEAN.'),
      grid(rowsOf(d.io), ioCols, 'No long IO and no IO latch timeout in this window.'));
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
