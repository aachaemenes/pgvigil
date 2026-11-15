// Task 413 (B22): the Connections page's 'Sessions and requests' part (SQLWATCH's Instance Overview session and request
// counts, Power BI's top-N, SQLMonitor's and Opserver's sessions by login, status, interface and address). One user /
// system rule on every part: sys.dm_exec_sessions.is_user_process over all sessions. Data: GET /api/mssql/sessions
// (internal/web/q_mssql_sessions.go): the per-minute counts (mssql_sessions), the 5-minute group reads (activity's one
// read), the top requests over the window (mssql_requests). mssqlConnectionsView appends it (the WIRING line).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, window_ } from './router';
import { Col, el, fmtNum, fmtTime, grid, tile } from './ui';

type Parts = 'counts' | 'reads' | 'login' | 'status' | 'interface' | 'address' | 'isolation' | 'top' | 'activity' | 'policy';

const ACTIVE_TRAN_OFF = 'Active transactions: off until the Databases counters collector (mssql_counters_db) is part of this build; '
  + 'it reads Databases / Active Transactions per database, the one series this chart draws.';
const measures: [string, string, (v: unknown) => string][] = [
  ['cpu_ms', 'CPU', v => `${fmtNum(v)} ms`], ['logical_reads', 'logical reads', fmtNum], ['tempdb_alloc_kb', 'tempdb allocated', v => `${fmtNum(v)} KB`],
  ['granted_memory_kb', 'memory grant', v => `${fmtNum(v)} KB`], ['elapsed_ms', 'duration', v => `${fmtNum(v)} ms`],
];
const dims: [string, string, string][] = [
  ['login', 'Sessions by login', 'login'], ['status', 'Sessions by status', 'status'], ['interface', 'Sessions by network interface', 'interface'],
  ['address', 'Sessions by client address', 'client address'], ['isolation', 'Sessions by isolation level', 'isolation level'],
];
const sum = (r: Row, keys: string[]) => keys.reduce((a, k) => a + Number(r[k] ?? 0), 0);

export async function mssqlSessionsPart(ctx: Ctx): Promise<HTMLElement> {
  const box = el('section', { class: 'mssql-sessions', 'aria-label': 'Sessions and requests' }, el('h3', {}, 'Sessions and requests'));
  const body = el('div', {}, el('p', { class: 'meta', role: 'status' }, 'Reading ...'));
  box.append(body);
  let at: string | undefined;
  let n = 5;
  const draw = async () => {
    let d: Record<Parts, Table | null>;
    try {
      d = await get('mssql/sessions', { instance: ctx.instance, ...window_(ctx), at, n });
    } catch (e) {
      body.replaceChildren(el('p', { class: 'error' }, e instanceof Error ? e.message : String(e)));
      return;
    }
    const counts = rowsOf(d.counts), last = counts[counts.length - 1];
    const kids: (Node | string)[] = [el('p', { class: 'meta' }, 'User and system sessions are told apart by the server\'s own flag (is_user_process) over every session, '
      + 'on this whole page. The counts are read every minute (mssql_sessions), pgvigil\'s own sessions left out; the groups every 5 minutes, every session.')];
    if (!last) kids.push(el('p', { class: 'empty' }, 'No per-minute session counts in this window (mssql_sessions, every minute).'));
    else {
      kids.push(el('div', { class: 'tiles' },
        tile('user sessions', fmtNum(sum(last, ['user_running', 'user_sleeping', 'user_dormant', 'user_preconnect', 'user_other']))),
        tile('system sessions', fmtNum(sum(last, ['system_running', 'system_sleeping', 'system_dormant', 'system_preconnect', 'system_other']))),
        tile('user requests running', fmtNum(sum(last, ['req_user_running', 'req_user_runnable']))),
        tile('user requests suspended', fmtNum(last.req_user_suspended)),
        tile('waiting tasks', fmtNum(last.waiting_tasks)), tile('longest wait', `${fmtNum(last.waiting_longest_ms)} ms`),
        tile('pgvigil\'s own sessions', fmtNum(last.own_sessions))));
      const charts = el('div', { class: 'charts' });
      charts.append(
        lineChart('Requests by status (user)', counts, [{ key: 'req_user_running', label: 'running' }, { key: 'req_user_runnable', label: 'runnable' },
          { key: 'req_user_suspended', label: 'suspended' }, { key: 'req_user_sleeping', label: 'sleeping' }, { key: 'req_user_background', label: 'background' }], v => fmtNum(v)),
        lineChart('Requests by status (system)', counts, [{ key: 'req_system_running', label: 'running' }, { key: 'req_system_runnable', label: 'runnable' },
          { key: 'req_system_suspended', label: 'suspended' }, { key: 'req_system_background', label: 'background' }], v => fmtNum(v)),
        lineChart('Sessions by status', counts, [{ key: 'user_running', label: 'user running' }, { key: 'user_sleeping', label: 'user sleeping' },
          { key: 'user_dormant', label: 'user dormant' }, { key: 'system_running', label: 'system running' }, { key: 'system_sleeping', label: 'system sleeping' }], v => fmtNum(v)),
        lineChart('Waiting tasks (user sessions, benign waits left out)', counts, [{ key: 'waiting_tasks', label: 'waiting tasks' }], v => fmtNum(v)),
        lineChart('Session CPU, reads and writes (every session, summed at each 5-minute read; counters since each session logged in)', rowsOf(d.activity),
          [{ key: 'cpu_ms', label: 'CPU (ms)' }, { key: 'reads', label: 'reads' }, { key: 'writes', label: 'writes' }], v => fmtNum(v)),
        el('div', { class: 'chart' }, el('h3', {}, 'Active transactions'), el('p', { class: 'meta' }, ACTIVE_TRAN_OFF)));
      kids.push(charts);
    }
    // the groups at one read: the newest of the window, or the one picked
    const reads = rowsOf(d.reads);
    if (reads.length) {
      const pick = el('select', { 'aria-label': 'The group read to show' }, ...reads.map(r => el('option', { value: String(r.snapshot_at) }, fmtTime(r.snapshot_at)))) as HTMLSelectElement;
      if (at) pick.value = at;
      pick.addEventListener('change', () => { at = pick.value; void draw(); });
      kids.push(el('p', {}, el('label', {}, 'Groups at the read ', pick)));
      const cols = (first: string): Col[] => [
        { key: 'name', label: first, fmt: (v, r) => r.is_other ? 'other (past the 50 largest)' : v == null ? 'none (no connection or no value)' : String(v) },
        { key: 'sessions', num: true }, { key: 'user_sessions', label: 'user', num: true }, { key: 'system_sessions', label: 'system', num: true },
        { key: 'running', num: true }, { key: 'sleeping', num: true }, { key: 'cpu_ms', label: 'CPU (ms)', num: true },
        { key: 'reads', num: true }, { key: 'writes', num: true }, { key: 'newest_login', label: 'newest login', fmt: fmtTime },
      ];
      for (const [k, title, first] of dims) kids.push(el('h4', {}, title), grid(rowsOf(d[k as Parts]), cols(first), 'No sessions at this read.'));
    } else kids.push(el('p', { class: 'empty' }, 'No 5-minute group read in this window (mssql_activity).'));
    // the top requests over the window
    const policy = String(rowsOf(d.policy)[0]?.query_text ?? '');
    const nPick = el('select', { 'aria-label': 'How many top requests per measure' }, ...[5, 10, 25].map(k => el('option', { value: String(k) }, String(k)))) as HTMLSelectElement;
    nPick.value = String(n);
    nPick.addEventListener('change', () => { n = Number(nPick.value); void draw(); });
    kids.push(el('h4', {}, 'Top requests over the window'), el('p', { class: 'meta' }, 'From the per-minute running-queries snapshot, which keeps user requests and sessions with an open transaction only: '
      + 'each request at its largest figure. ', el('label', {}, 'Show ', nPick, ' per measure.'),
      policy === 'none' ? ' Statements are not shown: this instance\'s query_text policy is "none".' : ''));
    const top = rowsOf(d.top);
    for (const [k, label, fmt] of measures) {
      kids.push(el('h5', {}, `By ${label}`), grid(top.filter(r => r.measure === k), [
        { key: 'rank', num: true }, { key: 'value', label, num: true, fmt: v => fmt(v) }, { key: 'session_id', label: 'session', num: true },
        { key: 'login_name', label: 'login' }, { key: 'program_name', label: 'program' }, { key: 'database_name', label: 'database' },
        { key: 'start_time', label: 'started', fmt: fmtTime }, { key: 'statement', wide: true },
      ], `No request with ${label} in this window.`));
    }
    body.replaceChildren(...kids);
  };
  await draw();
  return box;
}
