// The Deadlocks tab of a PostgreSQL instance (task 161; DBA Dash's Deadlocks report, graph window and charts): the
// deadlocks the log reader stored in the range, counted beside pg_stat_database's counter; grouped by the statements
// and relations involved (one row per group, its count and its latest); the deadlocks over time and by database,
// user, application and relation; and one deadlock opened as a DRAWN graph - the SQL Server page's drawing
// (deadlock_graph.ts) of the cycle PostgreSQL's DETAIL lines describe: each process a box with its statement, the
// victim marked, each lock between them with who holds it and who waits for it - and its participants as a grid.
// Data: /api/pg/deadlocks (internal/web/q_pg_deadlocks.go).
import { get, Row } from './api';
import { donutChart, lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';
import { deadlockSvg, graphFromRows } from './deadlock_graph';
import { sqlCell } from './sqlview';

interface DlCount { name: string; deadlocks: number; processes: number; last: string }
interface PgDeadlocks {
  deadlocks: Row[]; more: boolean; total: number; groups: Row[]; trend: Row[]; step_secs: number;
  by_database: DlCount[]; by_user: DlCount[]; by_application: DlCount[]; by_relation: DlCount[];
  counter: { deadlocks: number; databases: number };
}

const text = (v: unknown) => v == null ? '' : String(v);

const procCols: Col[] = [
  { key: 'victim', label: 'victim', fmt: v => v === true ? badge('victim', 'crit') : '' },
  { key: 'process', label: 'process' }, { key: 'spid', label: 'pid', num: true },
  { key: 'login', label: 'user', fmt: v => v == null ? 'not sampled' : text(v) },
  { key: 'program', label: 'application' }, { key: 'database' },
  { key: 'waits_mode', label: 'lock wanted' }, { key: 'waits_on', label: 'on', wide: true },
  { key: 'blocked_by', label: 'blocked by' },
  { key: 'relation', fmt: (v, r) => v == null ? '' : r.relation_from === 'statement' ? `${text(v)} (from the statement)` : r.relation_from === 'context' ? `${text(v)} (from CONTEXT)` : text(v) },
  { key: 'statement', fmt: (v, r) => sqlCell(v, { heading: `${text(r.process)}: statement` }) },
];

const resCols: Col[] = [
  { key: 'type', label: 'lock' }, { key: 'object', wide: true },
  { key: 'owners', label: 'held by', fmt: v => Array.isArray(v) ? v.map(o => `${text((o as Row).process)} (${text((o as Row).mode)})`).join(', ') : '' },
  { key: 'waiters', label: 'wanted by', fmt: v => Array.isArray(v) ? v.map(o => `${text((o as Row).process)} (${text((o as Row).mode)})`).join(', ') : '' },
];

// openDeadlock draws one deadlock with its participants and locks; focus moves to its heading when a click opened it
function openDeadlock(d: Row, panel: HTMLElement, focus = false) {
  const g = graphFromRows(d.processes, d.resources);
  const who = [d.victim_user == null ? null : text(d.victim_user), d.database == null ? null : `on ${text(d.database)}`].filter(Boolean).join(' ');
  const head = props([
    ['when', fmtTime(d.event_at)], ['victim', `pid ${text(d.victim_pid)}${who ? ` (${who})` : ''}`],
    ['processes', fmtNum(d.process_count)], ['relations', text(d.relations) || 'not named'], ['locks wanted', text(d.lock_modes)],
    ['group', `#${text(d.group)}`],
  ]);
  const h = el('h3', { tabindex: '-1' }, `The deadlock of ${fmtTime(d.event_at)}`);
  panel.replaceChildren(h, head);
  if (focus) h.focus();
  if (d.parsed !== true || !g) {
    panel.append(el('p', { class: 'empty' }, 'This deadlock has no DETAIL lines to draw: the instance\'s query_text policy is none (no detail is stored), or the log entry was cut short.'));
    return;
  }
  panel.append(
    el('h4', {}, `Graph (${g.processes.length} processes)`),
    el('p', { class: 'meta' }, 'From the log\'s DETAIL lines: a process waits for the lock named, held by the process that blocks it. The holder\'s own mode is not in the log: a transaction\'s holder holds ExclusiveLock on it, any other lock\'s holder a conflicting mode.'),
    el('div', { class: 'deadlock-graph-box grid-wrap', tabindex: '0' }, deadlockSvg(g)),
    el('h4', {}, 'Participants'), grid(Array.isArray(d.processes) ? d.processes as Row[] : [], procCols, 'No process.'),
    el('h4', {}, 'Locks'), grid(Array.isArray(d.resources) ? d.resources as Row[] : [], resCols, 'No lock.'));
}

const countCols: Col[] = [
  { key: 'name' }, { key: 'deadlocks', num: true, fmt: fmtNum }, { key: 'processes', label: 'processes in them', num: true, fmt: fmtNum },
  { key: 'last', label: 'last', fmt: fmtTime },
];

export async function pgDeadlocksView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Deadlocks (${rangeLabel(ctx)})`));
  if (!ctx.instance) { sec.append(el('p', { class: 'empty' }, 'Pick an instance.')); return sec; }
  try {
    const d = await get<PgDeadlocks>('pg/deadlocks', { instance: ctx.instance, ...window_(ctx) });
    const rows = d.deadlocks ?? [];
    const n = rows.length, total = Number(d.total ?? n);
    const counted = Number(d.counter?.deadlocks ?? 0);
    sec.append(el('div', { class: 'tiles' },
      tile('in the log', fmtNum(total), total ? 'warn' : ''),
      tile('pg_stat_database counted', fmtNum(counted), counted > total ? 'warn' : ''),
      tile('groups', fmtNum((d.groups ?? []).length) + (d.more ? ' (newest 500)' : '')),
      tile('last', n ? fmtTime(rows[0].event_at) : '-')));
    if (d.more) sec.append(el('p', { class: 'meta' }, `The chart counts all ${fmtNum(total)} deadlocks of the range; the groups, the breakdowns and the list read the newest 500.`));
    if (counted > total) {
      sec.append(el('p', { class: 'meta' }, 'pg_stat_database counted more deadlocks than the log holds: the log reader may not read this server\'s log (the Logs tab says why), or its entries were cut.'));
    }
    if (n) {
      const step = d.step_secs >= 3600 ? `${d.step_secs / 3600} h` : `${Math.round(d.step_secs / 60)} min`;
      sec.append(el('div', { class: 'charts' }, lineChart(`Deadlocks per ${step}`, d.trend ?? [], [{ key: 'deadlocks', label: 'deadlocks' }])));
      const slices = (l: DlCount[]) => (l ?? []).map(c => ({ label: c.name, value: c.deadlocks }));
      sec.append(el('div', { class: 'charts' },
        donutChart('By database', slices(d.by_database)), donutChart('By user', slices(d.by_user)),
        donutChart('By application', slices(d.by_application)), donutChart('By relation', slices(d.by_relation))));
      sec.append(el('p', { class: 'meta' }, 'A deadlock counts once in each database, user, application and relation its processes had. The application comes from the activity samples (the pid seen within 90 seconds before), "not sampled" otherwise; a relation named "(from the statement)" is the statement\'s target, the log naming only a transaction.'));
    }
    const panel = el('section', { class: 'detail' });
    const byKey = new Map(rows.map(r => [text(r.event_key), r]));
    const openBtn = (r: Row, label: string) => {
      // the name starts with the visible words (a voice command says what it sees)
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `${label}: the deadlock of ${fmtTime(r.event_at)}` }, label);
      b.addEventListener('click', () => openDeadlock(r, panel, true));
      return b;
    };
    const groupCols: Col[] = [
      { key: 'group', label: '#', num: true }, { key: 'deadlocks', num: true, fmt: fmtNum },
      { key: 'first', fmt: fmtTime }, { key: 'last', fmt: fmtTime },
      { key: 'statements', wide: true, fmt: v => Array.isArray(v) ? el('div', {}, ...v.map(s => el('div', {}, el('code', {}, text(s))))) : '' },
      { key: 'relations', wide: true }, { key: 'lock_modes', label: 'locks wanted' }, { key: 'databases' }, { key: 'users' },
      { key: 'latest_key', label: 'graph', fmt: v => { const r = byKey.get(text(v)); return r ? openBtn(r, 'Latest graph') : ''; } },
    ];
    sec.append(el('h3', {}, 'Grouped by the statements and relations involved'),
      grid(d.groups ?? [], groupCols, 'No deadlock in this range.'));
    const cols: Col[] = [
      { key: 'event_at', label: 'when', fmt: fmtTime },
      { key: 'event_key', label: 'graph', fmt: (_v, r) => openBtn(r, `Graph (${fmtNum(r.process_count)} processes)`) },
      { key: 'group', label: 'group', num: true },
      { key: 'victim_pid', label: 'victim pid', num: true }, { key: 'victim_user', label: 'victim user' },
      { key: 'victim_program', label: 'victim application' }, { key: 'database' },
      { key: 'relations', wide: true }, { key: 'lock_modes', label: 'locks wanted' },
      { key: 'victim_statement', label: 'the victim\'s statement', fmt: (v, r) => sqlCell(v, { heading: `the victim of ${fmtTime(r.event_at)}: statement` }) },
    ];
    sec.append(el('h3', {}, `Deadlocks${d.more ? ' (the newest 500)' : ''}`), grid(rows, cols, 'No deadlock in this range.'), panel);
    sec.append(el('h3', {}, 'By database'), grid(d.by_database as unknown as Row[], countCols, '-'),
      el('h3', {}, 'By user'), grid(d.by_user as unknown as Row[], countCols, '-'),
      el('h3', {}, 'By application'), grid(d.by_application as unknown as Row[], countCols, '-'),
      el('h3', {}, 'By relation'), grid(d.by_relation as unknown as Row[], countCols, '-'));
    // the newest opens by itself, so the page shows a drawn graph without a click
    if (n) openDeadlock(rows[0], panel);
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
