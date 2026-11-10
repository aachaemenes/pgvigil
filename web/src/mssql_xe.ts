// The Extended Events tabs of a SQL Server instance (phase 3 wave G, task 97): Deadlocks (the list of the range, one
// deadlock opened as its processes and resources with the victim marked, the graph XML as an .xdl download), Blocked
// reports (grouped by the blocking statement, the head's side first), Slow queries (by statement shape, with the
// events of one shape and the Attentions section). Each says "not installed" with the script's name where the
// server's DBA has not created the session, and "stopped" where the session is defined and not started.
// Data from /api/mssql/xe and its detail routes; the lead wires the tabs (router.ts, main.ts, pages.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';

type XEParts = 'state' | 'findings' | 'deadlocks' | 'blocked' | 'slow_shapes' | 'slow_series' | 'attentions' | 'ag_events';
type XE = Record<XEParts, Table | null>;

const SCRIPT = 'pgvigil mssql-xe -print';
const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const ms = (v: unknown) => v == null ? '' : fmtNum(v) + ' ms';
const secs = (v: unknown) => v == null ? '' : fmtNum(Math.round(Number(v) / 100) / 10) + ' s';
const text = (v: unknown) => v == null ? '' : String(v);

const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'finding' }, { key: 'object', wide: true },
  { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
];

async function load(ctx: Ctx, part?: XEParts): Promise<XE> {
  return get<XE>('mssql/xe', { instance: ctx.instance, ...window_(ctx), part });
}

// The findings of the tab's own checks (the instance's other findings are on the Findings page).
function findingsOf(d: XE, names: string[]): HTMLElement | null {
  const rows = rowsOf(d.findings).filter(r => names.includes(String(r.check_name)));
  return rows.length ? el('section', {}, el('h3', {}, 'Findings'), grid(rows, findingCols)) : null;
}

// captureNote says what a capture's state means for the page: nothing for a running session, the script's name for
// one that is not installed, the DBA's step for one that is stopped.
function captureNote(d: XE, capture: string, what: string): HTMLElement {
  const st = rowsOf(d.state).find(r => r.capture === capture);
  if (!st) {
    return el('p', { class: 'meta' }, badge('not read yet', ''), ` The Extended Events reader (mssql_xe, every minute) has not read this instance yet.`);
  }
  const read = `read ${fmtTime(st.snapshot_at)}`;
  if (st.state === 'not installed') {
    const p = el('p', { class: 'meta' }, badge('not installed', 'warn'),
      ` This server has no ${what} session of pgvigil. pgvigil does not create one: the script is what `, el('code', {}, SCRIPT),
      ' writes, for the server\'s DBA to run (docs/sqlserver-xe.md).');
    if (st.source === 'system_health') p.append(' Until then the deadlock reports below are the ones SQL Server\'s own system_health session kept.');
    p.append(` (${read})`);
    return p;
  }
  if (st.state === 'stopped') {
    return el('p', { class: 'meta' }, badge('stopped', 'warn'),
      ` The session ${text(st.session_name)} is defined and not started (since ${fmtTime(st.state_since)}): nothing is captured until the server's DBA starts it `,
      el('code', {}, `ALTER EVENT SESSION [${text(st.session_name)}] ON SERVER STATE = START`), `. (${read})`);
  }
  const bits = [`session ${text(st.session_name)}`, `target ${text(st.target)}`];
  if (st.buffer_kb != null) bits.push(`${fmtNum(st.buffer_kb)} KB`);
  if (st.threshold_s != null) bits.push(Number(st.threshold_s) === 0
    ? 'the server\'s blocked process threshold is 0: SQL Server raises no report until its DBA sets one'
    : `blocked process threshold ${fmtNum(st.threshold_s)} s`);
  if (st.counter != null) bits.push(`${fmtNum(st.counter)} attention(s) counted since the session started`);
  if (Number(st.unknown_events ?? 0) > 0) bits.push(`${fmtNum(st.unknown_events)} event(s) of a kind the reader does not store`);
  const p = el('p', { class: 'meta' }, badge('running', 'ok'), ` ${bits.join(', ')} (${read}).`);
  if (st.lost_at != null) p.append(` Events were lost: ${fmtNum(st.lost_events)} at the read of ${fmtTime(st.lost_at)}.`);
  if (st.note) p.append(` ${text(st.note)}`);
  return p;
}

// openButton is a row's button that loads its detail into the panel below the grid.
function openButton(label: string, name: string, onOpen: () => void): HTMLElement {
  const b = el('button', { type: 'button', class: 'link', 'aria-label': `${label}: ${name}` }, label);
  b.addEventListener('click', onOpen);
  return b;
}

function detailPanel(title: string): { box: HTMLElement; show: (...kids: (Node | string)[]) => void } {
  const box = el('section', { class: 'detail', 'aria-live': 'polite' });
  return { box, show: (...kids) => { box.replaceChildren(el('h3', { tabindex: '-1' }, title), ...kids); (box.firstElementChild as HTMLElement).focus(); } };
}

// ---- Deadlocks

const processCols: Col[] = [
  { key: 'victim', label: 'victim', fmt: v => v === true ? badge('victim', 'crit') : '' },
  { key: 'spid', label: 'session', num: true },
  { key: 'login' }, { key: 'host' }, { key: 'program' }, { key: 'database' },
  { key: 'waits_on', label: 'waited on' }, { key: 'waits_mode', label: 'lock wanted' },
  { key: 'wait_ms', label: 'waited', num: true, fmt: ms },
  { key: 'isolation' }, { key: 'trancount', label: 'open transactions', num: true },
  { key: 'log_used', label: 'log used (bytes)', num: true },
  { key: 'proc', label: 'procedure' },
  { key: 'statement', wide: true },
];

const holders = (v: unknown) => Array.isArray(v)
  ? v.map(x => `${text((x as Row).spid ?? '?')} (${text((x as Row).mode ?? '?')})`).join(', ') : '';

const resourceCols: Col[] = [
  { key: 'type', label: 'lock' }, { key: 'object' }, { key: 'index' }, { key: 'mode' },
  { key: 'owners', label: 'held by session (mode)', fmt: holders },
  { key: 'waiters', label: 'waited for by session (mode)', fmt: holders },
];

async function openDeadlock(ctx: Ctx, row: Row, panel: ReturnType<typeof detailPanel>) {
  try {
    const t = await get<Table>('mssql/xe/deadlock', { instance: ctx.instance, at: String(row.event_at), key: String(row.event_key) });
    const d = rowsOf(t)[0];
    if (!d) { panel.show(el('p', { class: 'empty' }, 'This deadlock is no longer stored.')); return; }
    const q = new URLSearchParams({ instance: String(ctx.instance), at: String(row.event_at), key: String(row.event_key) });
    const download = d.has_graph === true
      ? el('a', { href: `/api/mssql/xe/deadlock.xdl?${q}`, download: '' }, 'Download the deadlock graph (.xdl, opens in SSMS)')
      : el('span', {}, 'The graph XML is not stored: it carries statement text, and this instance\'s query_text policy is not "full".');
    panel.show(
      props([
        ['when', fmtTime(d.event_at)],
        ['read from', d.source === 'system_health' ? 'system_health (SQL Server\'s own session)' : text(d.session_name)],
        ['processes', `${fmtNum(d.process_count)}, ${fmtNum(d.victim_count)} chosen as victim`],
        ['databases', text(d.database_names)],
        ['objects', text(d.object_names)],
        ['graph', download],
      ]),
      el('h4', {}, 'Processes'),
      grid((d.processes as Row[] | null) ?? [], processCols, 'The graph could not be taken apart; download it instead.'),
      el('h4', {}, 'Resources'),
      grid((d.resources as Row[] | null) ?? [], resourceCols, 'No resource in the graph.'),
    );
  } catch (e) {
    panel.show(errorBox(e));
  }
}

export async function mssqlDeadlocks(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Deadlocks (${rangeLabel(ctx)})`));
  try {
    const d = await load(ctx);
    const f = findingsOf(d, ['deadlocks in the last hour', 'a capture is not installed', 'a capture is stopped', 'the ring buffer dropped events']);
    if (f) sec.append(f);
    sec.append(captureNote(d, 'deadlocks', 'deadlock'));
    const rows = rowsOf(d.deadlocks);
    const panel = detailPanel('One deadlock');
    const cols: Col[] = [
      { key: 'event_at', label: 'when', fmt: fmtTime },
      { key: 'event_key', label: 'open', fmt: (_, r) => openButton('Open', `the deadlock of ${fmtTime(r.event_at)}`, () => { void openDeadlock(ctx, r, panel); }) },
      { key: 'process_count', label: 'processes', num: true },
      { key: 'victim_spid', label: 'victim session', num: true },
      { key: 'victim_login', label: 'victim login' },
      { key: 'victim_program', label: 'victim program' },
      { key: 'database_names', label: 'databases' },
      { key: 'object_names', label: 'objects', wide: true },
      { key: 'victim_statement', label: 'the victim\'s statement', wide: true },
      { key: 'source', label: 'read from', fmt: v => v === 'system_health' ? 'system_health' : 'pgvigil\'s session' },
    ];
    sec.append(el('div', { class: 'tiles' }, tile('deadlocks', fmtNum(rows.length) + (rows.length >= 500 ? '+' : ''))));
    sec.append(grid(rows, cols, 'No deadlock in this window.'), panel.box);
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- Blocked reports

const reportCols: Col[] = [
  { key: 'event_at', label: 'report at', fmt: fmtTime },
  { key: 'blocking_spid', label: 'blocking session', num: true },
  { key: 'blocking_status', label: 'its status' },
  { key: 'blocking_trancount', label: 'its open transactions', num: true },
  { key: 'blocking_login', label: 'its login' }, { key: 'blocking_host', label: 'its host' }, { key: 'blocking_program', label: 'its program' },
  { key: 'blocking_last_batch', label: 'its last batch started (server clock)' },
  { key: 'blocked_spid', label: 'blocked session', num: true },
  { key: 'wait_ms', label: 'blocked for', num: true, fmt: secs },
  { key: 'lock_mode', label: 'lock wanted' }, { key: 'wait_resource', label: 'resource' }, { key: 'database_name', label: 'database' },
  { key: 'blocked_login', label: 'blocked login' }, { key: 'blocked_program', label: 'blocked program' },
  { key: 'blocked_statement', label: 'blocked statement', wide: true },
];

async function openHead(ctx: Ctx, row: Row, panel: ReturnType<typeof detailPanel>) {
  try {
    const t = await get<Table>('mssql/xe/blocked', { instance: ctx.instance, ...window_(ctx), head: text(row.head_key) });
    panel.show(
      el('p', { class: 'meta' }, 'The blocking session\'s statement is its input buffer when the report was raised: the last batch it sent. '
        + 'A sleeping blocking session with an open transaction is an application that left its transaction open.'),
      el('pre', { class: 'sql', tabindex: '0' }, text(row.blocking_statement) || '(no input buffer in the report)'),
      grid(rowsOf(t), reportCols, 'No report of this statement in this window.'),
    );
  } catch (e) {
    panel.show(errorBox(e));
  }
}

export async function mssqlBlocked(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Blocked reports (${rangeLabel(ctx)})`));
  try {
    const d = await load(ctx);
    const f = findingsOf(d, ['blocked-process reports naming the same head statement', 'a capture is not installed', 'a capture is stopped', 'the ring buffer dropped events']);
    if (f) sec.append(f);
    sec.append(captureNote(d, 'blocked', 'blocked-process'));
    sec.append(el('p', { class: 'meta' }, 'One row per blocking statement, the blocking side first: SQL Server raises a blocked-process report for a task '
      + 'blocked longer than the server\'s blocked process threshold, and again each time that long passes, so a long block is several reports.'));
    const rows = rowsOf(d.blocked);
    const panel = detailPanel('The reports of one blocking statement');
    const cols: Col[] = [
      { key: 'blocking_statement', label: 'blocking statement (the head\'s last batch)', wide: true, fmt: v => text(v) || '(no input buffer)' },
      { key: 'head_key', label: 'open', fmt: (_, r) => openButton('Open', `the reports blocked by ${(text(r.blocking_statement) || 'a session without an input buffer').slice(0, 80)}`, () => { void openHead(ctx, r, panel); }) },
      { key: 'blocking_spid', label: 'blocking session', num: true },
      { key: 'blocking_status', label: 'its status' },
      { key: 'blocking_login', label: 'its login' }, { key: 'blocking_program', label: 'its program' },
      { key: 'reports', num: true }, { key: 'blocked_sessions', label: 'blocked sessions', num: true },
      { key: 'worst_wait_ms', label: 'longest block', num: true, fmt: secs },
      { key: 'database_names', label: 'databases' },
      { key: 'first_at', label: 'first report', fmt: fmtTime }, { key: 'last_at', label: 'last report', fmt: fmtTime },
    ];
    sec.append(grid(rows, cols, 'No blocked-process report in this window.'), panel.box);
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- Slow queries, with the Attentions section

const eventCols: Col[] = [
  { key: 'event_at', label: 'completed', fmt: fmtTime },
  { key: 'duration_ms', label: 'duration', num: true, fmt: ms }, { key: 'cpu_ms', label: 'cpu', num: true, fmt: ms },
  { key: 'logical_reads', label: 'logical reads', num: true }, { key: 'physical_reads', label: 'physical reads', num: true },
  { key: 'writes', num: true }, { key: 'row_count', label: 'rows', num: true },
  { key: 'result', fmt: v => v == null || v === 'OK' ? text(v) : badge(text(v), 'warn') },
  { key: 'login_name', label: 'login' }, { key: 'host_name', label: 'host' }, { key: 'program_name', label: 'program' },
  { key: 'database_name', label: 'database' }, { key: 'session_id', label: 'session', num: true },
  { key: 'query_hash', label: 'query hash' }, { key: 'query_plan_hash', label: 'plan hash' },
  { key: 'event_name', label: 'event', fmt: v => v === 'rpc_completed' ? 'procedure call' : 'batch' },
  { key: 'statement', wide: true },
];

const seriesCols: Col[] = [
  { key: 'snapshot_at', label: 'from', fmt: fmtTime }, { key: 'events', label: 'slow completions', num: true },
  { key: 'worst_ms', label: 'worst', num: true, fmt: ms }, { key: 'total_ms', label: 'total', num: true, fmt: ms },
];

const attentionCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'session_id', label: 'session', num: true },
  { key: 'login_name', label: 'login' }, { key: 'host_name', label: 'host' }, { key: 'program_name', label: 'program' },
  { key: 'database_name', label: 'database' },
  { key: 'interrupt_us', label: 'interrupt took (microseconds)', num: true },
  { key: 'statement', label: 'the cancelled statement', wide: true },
];

async function openShape(ctx: Ctx, row: Row, panel: ReturnType<typeof detailPanel>) {
  try {
    const t = await get<Table>('mssql/xe/slow', { instance: ctx.instance, ...window_(ctx), shape: text(row.shape_key) });
    panel.show(
      el('pre', { class: 'sql', tabindex: '0' }, text(row.shape) || '(no statement text is stored for these events)'),
      el('p', { class: 'meta' }, 'The slowest 500 completions of this shape in the window. A completion\'s query hash and plan hash are those of the '
        + 'longest statement it ran (SQL Server gives the completion itself none); they match Query Store and sys.dm_exec_query_stats.'),
      grid(rowsOf(t), eventCols, 'No completion of this shape in this window.'),
    );
  } catch (e) {
    panel.show(errorBox(e));
  }
}

export async function mssqlSlow(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Slow queries (${rangeLabel(ctx)})`));
  try {
    const d = await load(ctx);
    const f = findingsOf(d, ['a capture is not installed', 'a capture is stopped', 'the ring buffer dropped events']);
    if (f) sec.append(f);
    sec.append(captureNote(d, 'slow', 'slow-query'));
    sec.append(el('p', { class: 'meta' }, 'Batches and procedure calls that ran longer than the session\'s threshold (1 s unless the server\'s DBA set another '
      + 'in the script), grouped by statement shape: a procedure call by its procedure, anything else by its text without literals.'));
    const shapes = rowsOf(d.slow_shapes), series = rowsOf(d.slow_series);
    const panel = detailPanel('The events of one shape');
    const cols: Col[] = [
      { key: 'shape', label: 'statement shape', wide: true, fmt: v => text(v) || '(no statement text stored)' },
      { key: 'shape_key', label: 'open', fmt: (_, r) => openButton('Open', `the events of ${(text(r.shape) || 'the shape without text').slice(0, 80)}`, () => { void openShape(ctx, r, panel); }) },
      { key: 'events', label: 'count', num: true },
      { key: 'total_ms', label: 'total duration', num: true, fmt: ms },
      { key: 'worst_ms', label: 'worst', num: true, fmt: ms },
      { key: 'mean_ms', label: 'mean', num: true, fmt: ms },
      { key: 'cpu_ms', label: 'cpu', num: true, fmt: ms },
      { key: 'logical_reads', label: 'logical reads', num: true }, { key: 'writes', num: true },
      { key: 'not_ok', label: 'not OK', num: true },
      { key: 'database_names', label: 'databases' }, { key: 'query_hash', label: 'query hash' },
      { key: 'last_at', label: 'last', fmt: fmtTime },
    ];
    sec.append(grid(shapes, cols, 'No slow completion in this window.'), panel.box);
    // the chart, and the same numbers as a table behind it
    sec.append(lineChart('Slow completions over time', series, [{ key: 'events', label: 'completions' }]),
      el('details', {}, el('summary', {}, 'The chart\'s numbers as a table'), grid(series, seriesCols, 'No slow completion in this window.')));

    const att = el('section', {}, el('h3', {}, 'Attentions'), captureNote(d, 'attention', 'attention'),
      el('p', { class: 'meta' }, 'An attention is a client cancelling its request: a command timeout in the application, or a user pressing cancel. '
        + 'The statement is what was running; the time shown is how long the interrupt itself took, not how long the request had run.'),
      grid(rowsOf(d.attentions), attentionCols, 'No attention in this window.'));
    sec.append(att);
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- AlwaysOn_health's events: a section for the availability page (the lead or the HA/DR tab places it)

const agCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime },
  { key: 'is_failover', label: 'failover', fmt: v => v === true ? badge('failover', 'crit') : '' },
  { key: 'event_name', label: 'event' }, { key: 'ag_name', label: 'group' }, { key: 'replica_name', label: 'replica' },
  { key: 'previous_state', label: 'from' }, { key: 'current_state', label: 'to' },
  { key: 'error_number', label: 'error', num: true, fmt: v => v == null ? '' : String(v) }, { key: 'family' },
  { key: 'ddl_phase', label: 'DDL phase' },
  { key: 'statement', label: 'DDL', wide: true }, { key: 'message', wide: true },
];

export async function mssqlAgEvents(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h3', {}, `Availability events (AlwaysOn_health, ${rangeLabel(ctx)})`));
  try {
    const d = await load(ctx);
    const st = rowsOf(d.state).find(r => r.capture === 'ag');
    if (!st) sec.append(el('p', { class: 'meta' }, 'Always On is not enabled on this instance, or the reader has not read it yet.'));
    else if (st.state !== 'running') {
      sec.append(el('p', { class: 'meta' }, badge(text(st.state), 'warn'),
        ' SQL Server\'s AlwaysOn_health session is not running on this instance; pgvigil reads it and never starts it.'));
    }
    const f = findingsOf(d, ['an availability replica changed role or state']);
    if (f) sec.append(f);
    sec.append(grid(rowsOf(d.ag_events), agCols, 'No availability event in this window.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
