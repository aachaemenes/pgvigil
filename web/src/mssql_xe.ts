// The Extended Events tabs of a SQL Server instance (phase 3 wave G, task 97): Deadlocks (the list of the range, one
// deadlock opened as its processes and resources with the victim marked, the graph XML as an .xdl download), Blocked
// reports (grouped by the blocking statement, the head's side first; sp_HumanEventsBlockViewer's report columns,
// findings and blocked-wait rollups below: darling-open D04), Slow queries (by statement shape, with the
// events of one shape and the Attentions section). Each says "not installed" with the script's name where the
// server's DBA has not created the session, and "stopped" where the session is defined and not started.
// Data from /api/mssql/xe and its detail routes; the lead wires the tabs (router.ts, main.ts, pages.ts).
import { get, post, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, offControl, props, tile } from './ui';
import { errorCell } from './doclinks';
import { stripGrid } from './timestrip';
import { planSourcesCol } from './mssql_plancache';

type XEParts = 'state' | 'findings' | 'deadlocks' | 'blocked' | 'block_findings' | 'block_rollup' | 'slow_shapes' | 'slow_series' | 'attentions' | 'ag_events';
type XE = Record<XEParts, Table | null>;

// the form follows the server's platform (server, rds, cloudsql, azuresqlmi, azuresqldb: docs/sqlserver-xe.md); the page
// names the flag, not one form, since the bare command prints the server form, which RDS and Cloud SQL refuse
const SCRIPT = 'pgvigil mssql-xe -print -form <the server\'s form>';
const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : 'none');
const ms = (v: unknown) => v == null ? '' : fmtNum(v) + ' ms';
const secs = (v: unknown) => v == null ? '' : fmtNum(Math.round(Number(v) / 100) / 10) + ' s';
const text = (v: unknown) => v == null ? '' : String(v);

const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'finding' }, { key: 'object', wide: true },
  { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
];

async function load(ctx: Ctx, part?: XEParts, win = window_(ctx)): Promise<XE> {
  return get<XE>('mssql/xe', { instance: ctx.instance, ...win, part });
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
      ' writes (the form: server, rds, cloudsql, azuresqlmi or azuresqldb, docs/sqlserver-xe.md), for the server\'s DBA to run.');
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
  if (st.truncated === true) p.append(' Its ring buffer output came back cut at the last read: the newest events are the ones missing; an event_file target keeps the whole history.');
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
    sec.append(stripGrid('Deadlocks', window_(ctx), rows, 'event_at', cols, 'No deadlock in this window.'), panel.box);
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- Blocked reports

// one report a row: the blocking side first, then the blocked side (sp_HumanEventsBlockViewer's columns, darling-open D04)
const reportCols: Col[] = [
  { key: 'event_at', label: 'report at', fmt: fmtTime },
  { key: 'contentious_object', label: 'object' },
  { key: 'blocking_spid', label: 'blocking session', num: true },
  { key: 'blocking_status', label: 'its status', fmt: v => v === 'sleeping' ? badge('sleeping', 'warn') : text(v), cls: v => v == null || v === '' || v === 'sleeping' ? '' : 'status ok' },
  { key: 'blocking_isolation', label: 'its isolation level' },
  { key: 'blocking_trancount', label: 'its open transactions', num: true },
  { key: 'blocking_transaction_name', label: 'its transaction name' },
  { key: 'blocking_last_batch', label: 'its last batch started (server clock)' },
  { key: 'blocking_last_batch_completed', label: 'its last batch completed (server clock)' },
  { key: 'blocking_last_tran_started', label: 'its transaction started (server clock)' },
  { key: 'blocking_log_used', label: 'its log used (bytes)', num: true },
  { key: 'blocking_priority', label: 'its priority', num: true },
  { key: 'blocking_login', label: 'its login' }, { key: 'blocking_host', label: 'its host' }, { key: 'blocking_program', label: 'its program' },
  { key: 'blocked_spid', label: 'blocked session', num: true },
  { key: 'wait_ms', label: 'blocked for', num: true, fmt: secs },
  { key: 'lock_mode', label: 'lock wanted' }, { key: 'wait_resource', label: 'resource' }, { key: 'database_name', label: 'database' },
  { key: 'resource_owner_type', label: 'resource owner' },
  { key: 'blocked_isolation', label: 'blocked isolation level' },
  { key: 'blocked_status', label: 'blocked status' },
  { key: 'blocked_trancount', label: 'blocked open transactions', num: true },
  { key: 'blocked_transaction_name', label: 'blocked transaction name' },
  { key: 'blocked_last_tran_started', label: 'blocked transaction started (server clock)' },
  { key: 'blocked_log_used', label: 'blocked log used (bytes)', num: true },
  { key: 'blocked_login', label: 'blocked login' }, { key: 'blocked_host', label: 'blocked host' }, { key: 'blocked_program', label: 'blocked program' },
  { key: 'blocked_statement', label: 'blocked statement', wide: true },
  { key: 'source', label: 'read from', fmt: v => v === 'system_health' ? 'system_health (blockingTasks)' : 'pgvigil\'s session' },
];

// sp_HumanEventsBlockViewer's findings over the stored reports (its check ids, groups and words; migration 0116)
const blockFindingCols: Col[] = [
  { key: 'check_id', label: 'check', num: true, fmt: v => String(v) },
  { key: 'finding_group', label: 'group' },
  { key: 'database_name', label: 'database' },
  { key: 'object_name', label: 'object' },
  { key: 'finding', wide: true },
];

const rollupWords: Record<string, [string, string]> = {
  lead: ['Blocked wait by lead blocker', 'lead blocker (its last statement)'],
  object: ['Blocked wait by object', 'object'],
  database: ['Blocked wait by database', 'database'],
  login: ['Blocked wait by the blocking login, application and host', 'blocking login / application / host'],
};

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

// chainTimeline (the chains of the range, Power BI's blocking timeline): one bar per chain - a head and its transaction,
// from its first to its last snapshot - coloured by its longest wait as 'a blocking chain' judges one (over 5 min
// critical, over 30 s warning), the head's login, program and statement in its title and in the grid under it
const chainCols: Col[] = [
  { key: 'head_session_id', label: 'head session', num: true, fmt: v => String(v ?? '') },
  { key: 'first_at', label: 'first seen', fmt: fmtTime }, { key: 'last_at', label: 'last seen', fmt: fmtTime },
  { key: 'snapshots', num: true }, { key: 'longest_wait_ms', label: 'longest wait', num: true, fmt: secs },
  // the bar's colour as a word: the band 'a blocking chain' judges its longest wait in
  { key: 'band', label: 'as a blocking chain', fmt: v => v === 'crit' ? badge('critical', 'crit') : v === 'warn' ? badge('warning', 'warn') : '' },
  { key: 'victims_max', label: 'most victims', num: true },
  { key: 'head_login', label: 'head login' }, { key: 'head_program', label: 'head program' }, { key: 'head_database', label: 'database' },
  { key: 'statement', label: 'head statement (its last)', wide: true, fmt: v => text(v) },
];
// the band of a chain's longest wait as 'a blocking chain' judges one (over 5 min critical, over 30 s warning)
const chainBand = (ms: number) => ms > 300000 ? 'crit' : ms > 30000 ? 'warn' : 'none';
function chainTimeline(rows: Row[], from: string, to: string): Element {
  // a time axis on top (five ticks), then one bar per chain; drawn at the page's width (the viewBox scales with it, the
  // bars keep their height whatever their number) inside a box that scrolls past 24rem
  const t0 = Date.parse(from), t1 = Date.parse(to), W = 800, H = 14, G = 4, A = 22, ns = 'http://www.w3.org/2000/svg';
  const x = (t: number) => Math.max(0, Math.min(W, (t - t0) / Math.max(1, t1 - t0) * W));
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('class', 'chain-timeline');
  svg.setAttribute('viewBox', `0 0 ${W} ${A + rows.length * (H + G) + G}`);
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', `${rows.length} blocking chain(s) over the range, one bar each from its first to its last snapshot; the grid below lists them`);
  for (let k = 0; k <= 4; k++) {
    const tx = k * W / 4, at = new Date(t0 + (t1 - t0) * k / 4).toISOString();
    const tick = document.createElementNS(ns, 'line');
    tick.setAttribute('class', 'chain-tick');
    tick.setAttribute('x1', String(tx)); tick.setAttribute('x2', String(tx)); tick.setAttribute('y1', String(A - 6)); tick.setAttribute('y2', String(A + rows.length * (H + G)));
    const label = document.createElementNS(ns, 'text');
    label.setAttribute('class', 'chain-tick-label');
    label.setAttribute('x', String(tx)); label.setAttribute('y', String(A - 9));
    label.setAttribute('text-anchor', k === 0 ? 'start' : k === 4 ? 'end' : 'middle');
    label.textContent = fmtTime(at);
    svg.append(tick, label);
  }
  rows.forEach((r, i) => {
    const a = x(Date.parse(String(r.first_at))), b = x(Date.parse(String(r.last_at)));
    const bar = document.createElementNS(ns, 'rect');
    bar.setAttribute('class', `chain-bar ${chainBand(Number(r.longest_wait_ms ?? 0))}`);
    bar.setAttribute('x', String(a)); bar.setAttribute('y', String(A + G + i * (H + G)));
    bar.setAttribute('width', String(Math.max(3, b - a))); bar.setAttribute('height', String(H));
    const title = document.createElementNS(ns, 'title');
    title.textContent = `session ${String(r.head_session_id)}: login ${String(r.head_login ?? '?')}, program ${String(r.head_program ?? '?')}, `
      + `the longest wait ${secs(r.longest_wait_ms)}; ${text(r.statement).slice(0, 200)}`;
    bar.append(title);
    svg.append(bar);
  });
  return el('div', { class: 'chain-scroll' }, svg as unknown as HTMLElement);
}

export async function mssqlBlocked(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Blocked reports (${rangeLabel(ctx)})`));
  try {
    const d = await load(ctx);
    const f = findingsOf(d, ['blocked-process reports naming the same head statement', 'a capture is not installed', 'a capture is stopped', 'the ring buffer dropped events']);
    if (f) sec.append(f);
    sec.append(captureNote(d, 'blocked', 'blocked-process'));
    const lost = await xeLossNote(ctx, 'blocked').catch(() => null);
    if (lost) sec.append(lost);
    sec.append(el('p', { class: 'meta' }, 'One row per blocking statement, the blocking side first: SQL Server raises a blocked-process report for a task '
      + 'blocked longer than the server\'s blocked process threshold, and again each time that long passes, so a long block is several reports.'));
    const rows = rowsOf(d.blocked);
    const panel = detailPanel('The reports of one blocking statement');
    const cols: Col[] = [
      { key: 'blocking_statement', label: 'blocking statement (the blocking session\'s last batch)', wide: true, fmt: v => text(v) || '(no input buffer)' },
      { key: 'head_key', label: 'open', fmt: (_, r) => openButton('Open', `the reports blocked by ${(text(r.blocking_statement) || 'a session without an input buffer').slice(0, 80)}`, () => { void openHead(ctx, r, panel); }) },
      { key: 'blocking_spid', label: 'blocking session', num: true },
      { key: 'blocking_status', label: 'its status' },
      { key: 'blocking_login', label: 'its login' }, { key: 'blocking_program', label: 'its program' },
      { key: 'reports', num: true }, { key: 'blocked_sessions', label: 'blocked sessions', num: true },
      { key: 'worst_wait_ms', label: 'longest block', num: true, fmt: secs },
      { key: 'total_wait_ms', label: 'blocked wait', num: true, fmt: secs },
      { key: 'database_names', label: 'databases' },
      { key: 'first_at', label: 'first report', fmt: fmtTime }, { key: 'last_at', label: 'last report', fmt: fmtTime },
    ];
    sec.append(grid(rows, cols, 'No blocked-process report in this window.'), panel.box);
    // the chains of the range from the minute snapshots (every edition, no threshold needed)
    const w = window_(ctx);
    const chains = rowsOf((await get<Record<string, Table | null>>('blocking/history', { instance: ctx.instance, ...w, part: 'chains' })).chains)
      .map(r => ({ ...r, band: chainBand(Number(r.longest_wait_ms ?? 0)) }));
    sec.append(el('h3', {}, 'Chains over the range'),
      el('p', { class: 'meta' }, 'One bar per blocking chain the Running queries snapshots saw: a head session and its transaction, from its first to its last snapshot, '
        + 'red where its longest wait passed 5 minutes, amber past 30 seconds (as the finding \'a blocking chain\' judges). A chain shorter than a minute can fall between two snapshots.'),
      chains.length ? chainTimeline(chains, w.from, w.to) : '', grid(chains, chainCols, 'No snapshot of this window saw a blocking chain.'));
    sec.append(el('h3', {}, 'Findings over the range'),
      el('p', { class: 'meta' }, 'sp_HumanEventsBlockViewer\'s findings (Erik Darling, MIT), made from the stored reports with its rules: '
        + 'each report counts as its blocked side and its blocking side, and a count is of blocked transactions. '
        + 'The object is the lock\'s resource as pgvigil\'s waiting-tasks read decoded it; a lock no read decoded keeps the procedure\'s own \'Unresolved\' label.'),
      grid(rowsOf(d.block_findings), blockFindingCols, 'No finding: no blocked-process report in this window.'));
    const roll = rowsOf(d.block_rollup);
    for (const dim of ['lead', 'object', 'database', 'login']) {
      const [title, nameLabel] = rollupWords[dim];
      sec.append(el('h3', {}, title), grid(roll.filter(r => r.dimension === dim), [
        { key: 'name', label: nameLabel, wide: dim === 'lead' },
        ...(dim === 'database' ? [] : [{ key: 'database_name', label: 'database' } as Col]),
        { key: 'total_wait_ms', label: 'blocked wait', num: true, fmt: secs },
        { key: 'longest_wait_ms', label: 'longest', num: true, fmt: secs },
        { key: 'blocked_sessions', label: 'blocked transactions', num: true },
        { key: 'reports', num: true },
        { key: 'first_at', label: 'first report', fmt: fmtTime }, { key: 'last_at', label: 'last report', fmt: fmtTime },
      ], 'No blocked-process report in this window.'));
    }
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
  { key: 'result', fmt: v => v == null || v === 'OK' ? text(v) : badge(text(v), 'warn'), cls: v => v === 'OK' ? 'status ok' : '' },
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
  // task 402 (B24 Fixed 1): why an attention is not in the client timeouts rate (0153's mssql_attention_left_out); blank = it counts
  { key: 'left_out', label: 'left out', fmt: v => v == null ? '' : String(v) },
];

async function openShape(ctx: Ctx, row: Row, panel: ReturnType<typeof detailPanel>) {
  const planBox = el('div', { class: 'xe-plans' });
  try {
    const t = await get<Table>('mssql/xe/slow', { instance: ctx.instance, ...window_(ctx), shape: text(row.shape_key) });
    panel.show(
      el('pre', { class: 'sql', tabindex: '0' }, text(row.shape) || '(no statement text is stored for these events)'),
      el('p', { class: 'meta' }, 'The slowest 500 completions of this shape in the window. A completion\'s query hash and plan hash are those of the '
        + 'longest statement it ran (SQL Server gives the completion itself none); they match Query Store and sys.dm_exec_query_stats.'),
      grid(rowsOf(t), [...eventCols, planSourcesCol(ctx, planBox)], 'No completion of this shape in this window.'),
      planBox,   // task 406 (SQLWATCH COL#27): a completion's plan by its hashes
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
    sec.append(await xeSlowTrend(ctx).catch(e => errorBox(e)));

    const att = el('section', {}, el('h3', {}, 'Attentions'), captureNote(d, 'attention', 'attention'),
      el('p', { class: 'meta' }, 'An attention is a client cancelling its request: a command timeout in the application, or a user pressing cancel. '
        + 'The statement is what was running; the time shown is how long the interrupt itself took, not how long the request had run. '
        + '\'left out\' names why an attention is not in the client timeouts rate (Metrics, Extended Events): SSMS IntelliSense, the VS Code '
        + 'mssql metadata connections, a cancel under 1 ms that came with no statement (a command that had already finished), Azure Data Studio\'s '
        + 'metadata statements, pgvigil\'s own reads; a blank one counts. A real timeout usually takes under 1 ms to interrupt too: it counts when the server sent its statement (recorded even when none is stored).'),
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
  { key: 'error_number', label: 'error', num: true, fmt: errorCell }, { key: 'family' },
  { key: 'ddl_phase', label: 'DDL phase' },
  { key: 'statement', label: 'DDL', wide: true }, { key: 'message', wide: true },
];

export async function mssqlAgEvents(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h3', {}, `Availability events (AlwaysOn_health, ${rangeLabel(ctx)})`));
  try {
    const win = window_(ctx);   // one window for the read and its strip
    const d = await load(ctx, undefined, win);
    const st = rowsOf(d.state).find(r => r.capture === 'ag');
    if (!st) sec.append(el('p', { class: 'meta' }, 'Always On is not enabled on this instance, or the reader has not read it yet.'));
    else if (st.state !== 'running') {
      sec.append(el('p', { class: 'meta' }, badge(text(st.state), 'warn'),
        ' SQL Server\'s AlwaysOn_health session is not running on this instance; pgvigil reads it and never starts it.'));
    }
    const f = findingsOf(d, ['an availability replica changed role or state']);
    if (f) sec.append(f);
    sec.append(stripGrid('Availability events', win, rowsOf(d.ag_events), 'event_at', agCols, 'No availability event in this window.', 500));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- the optional captures (task 411): waits over a threshold, query warnings, page splits and cache misses counted,
// module runs over a threshold, and the sessions' script and settings. Data from /api/mssql/xecaptures; the tabs are the
// shell's (the join's wiring: router.ts / main.ts).

type XCParts = 'state' | 'waits_by_type' | 'waits_series' | 'waits_top' | 'waits' | 'plan_text' | 'warnings_by_event' | 'warnings_top'
  | 'warning_counts' | 'modules' | 'trend' | 'lost' | 'settings' | 'config';
type XC = Record<XCParts, Table | null> & { script?: string; drop?: string; writable?: boolean; reason?: string; text_policy?: string };

// a list setting's entries, verbatim (a pattern's [_] and an entry's comma kept as they are)
function listEntries(v: unknown): string[] {
  try { const a = JSON.parse(text(v)); return Array.isArray(a) ? a.map(x => String(x)) : []; } catch { return []; }
}

async function loadXC(ctx: Ctx, extra: Record<string, string | undefined> = {}): Promise<XC> {
  return get<XC>('mssql/xecaptures', { instance: ctx.instance, ...window_(ctx), ...extra });
}

const captureWords: Record<string, string> = { waits: 'waits over the threshold', warnings: 'query warnings', warncounts: 'page splits and cache misses', modules: 'procedure runs' };

// xcNote says what an optional capture's state means: not installed (the script on the XE captures tab), stopped (the
// DBA's step), running (what the last read found)
function xcNote(ctx: Ctx, d: XC, capture: string): HTMLElement {
  const st = rowsOf(d.state).find(r => r.capture === capture);
  const tab = el('a', { href: href(ctx, { tab: 'mssql_xecaptures' }) }, 'XE captures');
  if (!st) return el('p', { class: 'meta' }, badge('not read yet', ''), ' The captures reader (mssql_xe_captures, every minute) has not read this instance yet.');
  if (st.state === 'not installed') {
    return el('p', { class: 'meta' }, badge('not installed', ''), ` This server has no session of pgvigil for ${captureWords[capture]}: it is optional and off until the server's DBA runs the script on the `, tab, ' tab. pgvigil does not create it.');
  }
  if (st.state === 'stopped') {
    return el('p', { class: 'meta' }, badge('stopped', 'warn'), ` The session ${text(st.session_name)} is defined and not started (since ${fmtTime(st.state_since)}).`);
  }
  const p = el('p', { class: 'meta' }, badge('running', 'ok'), ` session ${text(st.session_name)}, target ${text(st.target)}, read ${fmtTime(st.snapshot_at)}.`);
  if (st.lost_at != null) p.append(` ${fmtNum(st.lost_events)} event(s) were lost at the read of ${fmtTime(st.lost_at)}.`);
  if (st.note) p.append(` ${text(st.note)}`);
  return p;
}

// pivot turns rows of (snapshot_at, a group, a value) into one row per time with a key per group, the largest groups first
function pivot(rows: Row[], groupKey: string, valueKey: string, most = 8): { rows: Row[]; keys: string[] } {
  const totals = new Map<string, number>();
  for (const r of rows) totals.set(text(r[groupKey]), (totals.get(text(r[groupKey])) ?? 0) + Number(r[valueKey] ?? 0));
  const keys = [...totals.entries()].sort((a, b) => b[1] - a[1]).slice(0, most).map(e => e[0]);
  const at = new Map<string, Row>();
  for (const r of rows) {
    const g = text(r[groupKey]);
    if (!keys.includes(g)) continue;
    const t = text(r.snapshot_at ?? r.bucket_at);
    const row = at.get(t) ?? { snapshot_at: t };
    row[g] = Number(r[valueKey] ?? 0);
    at.set(t, row);
  }
  return { rows: [...at.values()].sort((a, b) => text(a.snapshot_at).localeCompare(text(b.snapshot_at))), keys };
}

export async function mssqlXEWaits(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Waits over the threshold (${rangeLabel(ctx)})`));
  try {
    const d = await loadXC(ctx);
    sec.append(xcNote(ctx, d, 'waits'),
      el('p', { class: 'meta' }, 'Each wait of a user session in a database that ended after the threshold (1,000 ms unless set otherwise on the XE captures tab): '
        + 'wait_info and wait_info_external, WAITFOR and BROKER_RECEIVE_WAITFOR left out. Durations in milliseconds; the statement as the instance\'s text policy keeps it.'));
    const byType = rowsOf(d.waits_by_type), top = rowsOf(d.waits_top);
    const total = byType.reduce((a, r) => a + Number(r.total_ms ?? 0), 0);
    sec.append(el('div', { class: 'tiles' }, tile('waits over the threshold', fmtNum(byType.reduce((a, r) => a + Number(r.waits ?? 0), 0))),
      tile('waited in all', ms(total)), tile('the largest category', byType.length ? text(byType[0].category) : 'none')));
    const pv = pivot(rowsOf(d.waits_series), 'category', 'waited_ms');
    sec.append(lineChart('Waited ms per hour, by category', pv.rows, pv.keys.map(k => ({ key: k, label: k })), v => fmtNum(v) + ' ms'),
      el('h3', {}, 'By wait type'),
      grid(byType, [{ key: 'wait_type', label: 'wait type' }, { key: 'category' }, { key: 'waits', num: true }, { key: 'total_ms', label: 'total', num: true, fmt: ms },
        { key: 'avg_ms', label: 'average', num: true, fmt: ms }, { key: 'max_ms', label: 'longest', num: true, fmt: ms }, { key: 'signal_ms', label: 'signal', num: true, fmt: ms }],
        'No wait over the threshold in this window.'));
    const textBox = el('div', { 'aria-live': 'polite' });
    sec.append(el('h3', {}, 'The 10 statements with the longest average wait'),
      grid(top, [{ key: 'query_plan_hash', label: 'plan hash' }, { key: 'waits', num: true }, { key: 'avg_ms', label: 'average', num: true, fmt: ms },
        { key: 'max_ms', label: 'longest', num: true, fmt: ms }, { key: 'database_name', label: 'database' },
        { key: 'statement', wide: true, fmt: (v, r) => v != null ? text(v) : /^0x/.test(text(r.query_plan_hash))
          ? openButton('Its text', `the statement of plan ${text(r.query_plan_hash)}`, () => {
            textBox.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
            loadXC(ctx, { part: 'plan_text', plan_hash: text(r.query_plan_hash) }).then(t => {
              const row = rowsOf(t.plan_text)[0];
              textBox.replaceChildren(row ? el('pre', {}, text(row.statement)) : el('p', { class: 'meta' }, 'No statement text of this plan is kept (the text policy, or no capture held it).'));
            }, e => textBox.replaceChildren(errorBox(e)));
          }) : '' }],
        'No wait over the threshold in this window.'), textBox,
      el('h3', {}, 'The newest waits'),
      grid(rowsOf(d.waits), [{ key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'wait_type', label: 'wait type' }, { key: 'category' },
        { key: 'duration_ms', label: 'waited', num: true, fmt: ms }, { key: 'signal_ms', label: 'signal', num: true, fmt: ms }, { key: 'session_id', label: 'session', num: true },
        { key: 'login_name', label: 'login' }, { key: 'host_name', label: 'host' }, { key: 'program_name', label: 'program' }, { key: 'database_name', label: 'database' },
        { key: 'statement', wide: true }], 'No wait over the threshold in this window.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

export async function mssqlXEWarnings(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Query warnings (${rangeLabel(ctx)})`));
  try {
    const d = await loadXC(ctx);
    sec.append(xcNote(ctx, d, 'warnings'),
      el('p', { class: 'meta' }, 'Sort and hash spills, exchange spills, a join with no predicate, a plan-affecting conversion, a missing column statistic, an '
        + 'unmatched filtered index, an optimizer time-out, a memory grant warning, an I/O over 15 s: counted per hour and plan, the newest event of each kept.'),
      grid(rowsOf(d.warnings_by_event), [{ key: 'event_name', label: 'warning' }, { key: 'events', num: true }, { key: 'plans', num: true }, { key: 'databases', num: true }],
        'No query warning in this window.'),
      el('h3', {}, 'Page splits and plan cache misses'), xcNote(ctx, d, 'warncounts'),
      grid(rowsOf(d.warning_counts), [{ key: 'event_name', label: 'event' }, { key: 'events', label: 'in this window', num: true },
        { key: 'total_since_start', label: 'since the session started', num: true },
        { key: 'restarted', label: 'note', fmt: v => v === true ? 'the session restarted in this window: its count began again' : '' }],
        'Nothing counted in this window.'),
      el('h3', {}, 'By warning, database and plan'),
      grid(rowsOf(d.warnings_top), [{ key: 'event_name', label: 'warning' }, { key: 'database_name', label: 'database' }, { key: 'query_plan_hash', label: 'plan hash' },
        { key: 'events', num: true }, { key: 'last_at', label: 'newest', fmt: fmtTime }, { key: 'detail', wide: true }, { key: 'statement', wide: true }],
        'No query warning in this window.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

export async function mssqlXEModules(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Procedure runs (${rangeLabel(ctx)})`));
  try {
    const d = await loadXC(ctx);
    sec.append(xcNote(ctx, d, 'modules'),
      el('p', { class: 'meta' }, 'A procedure, function or trigger whose whole run took longer than the threshold (5 s unless set otherwise; module_end, its '
        + 'duration in microseconds on the event, shown here in ms). The procedures and programs of the exclusion lists are left out.'),
      grid(rowsOf(d.modules), [{ key: 'event_at', label: 'when', fmt: fmtTime }, { key: 'database_name', label: 'database' }, { key: 'object_name', label: 'object' },
        { key: 'object_type', label: 'type' }, { key: 'duration_ms', label: 'ran', num: true, fmt: ms }, { key: 'row_count', label: 'rows', num: true },
        { key: 'session_id', label: 'session', num: true }, { key: 'login_name', label: 'login' }, { key: 'host_name', label: 'host' }, { key: 'program_name', label: 'program' }],
        'No procedure run over the threshold in this window.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// the XE captures tab: the four optional sessions' state, the settings and the script with them
export async function mssqlXECaptures(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'XE captures'));
  const body = el('div', { 'aria-live': 'polite' });
  sec.append(body);
  const form = el('select', { 'aria-label': 'The server\'s platform' }, ...['server', 'rds', 'cloudsql', 'azuresqlmi', 'azuresqldb'].map(f => el('option', { value: f }, f)));
  const fullOpt = el('option', { value: 'full' }, 'yes');
  const textSel = el('select', { 'aria-label': 'The script captures statement text' }, fullOpt, el('option', { value: 'none' }, 'no (query_text none)'));
  const id = el('input', { type: 'text', value: 'main', size: '12', 'aria-label': 'The install id in the session names' });
  let chosen: string | undefined; // the text choice the user made; until then the instance's own policy
  const textNote = el('p', { id: 'xc-text-note', class: 'meta' });
  const render = async () => {
    try {
      const d = await loadXC(ctx, { install_id: id.value.trim() || 'main', form: form.value, text: chosen });
      const policy = text(d.text_policy) || 'full';
      fullOpt.disabled = policy === 'none';
      if (chosen === undefined || policy === 'none') textSel.value = policy === 'none' ? 'none' : 'full';
      textNote.textContent = policy === 'none'
        ? 'This instance keeps no statement text (query_text none): the script never captures it.'
        : `This instance's statement-text policy is ${policy}: the script starts there.`;
      textSel.setAttribute('aria-describedby', 'xc-text-note');
      const why = d.writable ? '' : text(d.reason) || 'the settings cannot be edited on this server';
      const offNote = el('p', { id: 'xc-off-note', class: 'meta off-reason' }, `Editing is off here: ${why}.`);
      const editNote = el('div', { 'aria-live': 'polite' });
      const send = async (payload: Record<string, unknown>) => {
        try { await post('mssql/xecaptures/config', payload); await render(); } catch (e) { editNote.replaceChildren(errorBox(e)); }
      };
      const settingCols: Col[] = [
        { key: 'label', label: 'setting' },
        { key: 'value', fmt: (v, r) => r.value_kind === 'list'
          ? el('div', { class: 'xc-list' }, ...listEntries(v).map(x => el('div', {}, x)))
          : `${text(v)} ms` },
        { key: 'set_at', label: 'set at', fmt: (v, r) => v === 'default' ? 'the default' : v === 'tag' ? `the tag ${text(r.set_tag)}` : v === 'fleet' ? 'the fleet' : 'this instance' },
        { key: 'key', label: 'change for this instance', fmt: (_, r) => {
          // a list is edited one entry a line, verbatim (a comma may be part of an app name, [_] stays [_])
          const input = r.value_kind === 'list'
            ? el('textarea', { rows: '4', cols: '40', 'aria-label': `New value of ${text(r.label)}, one entry a line` }, listEntries(r.value).join('\n'))
            : el('input', { type: 'text', size: '30', 'aria-label': `New value of ${text(r.label)}`, placeholder: 'ms' });
          const save = el('button', { type: 'button', class: 'link' }, 'Save');
          const box = el('span', {}, input, ' ', save);
          if (why) { offControl(save, why, offNote); input.disabled = true; input.setAttribute('aria-describedby', 'xc-off-note'); return box; }
          save.addEventListener('click', () => {
            const raw = input.value.trim();
            const value = r.value_kind === 'list' ? JSON.stringify(raw ? raw.split('\n').map(x => x.trim()).filter(Boolean) : []) : raw;
            void send({ op: 'add', scope: 'instance', instance_id: Number(ctx.instance), key: text(r.key), value });
          });
          if (r.config_id != null && r.set_at !== 'default') {
            const clear = el('button', { type: 'button', class: 'link' }, 'Clear');
            clear.addEventListener('click', () => { void send({ op: 'end', config_id: Number(r.config_id) }); });
            box.append(' ', clear);
          }
          return box;
        } },
      ];
      const script = el('textarea', { readonly: '', rows: '18', cols: '110', 'aria-label': 'The script that makes the sessions' }, text(d.script));
      body.replaceChildren(
        el('p', { class: 'meta' }, 'Optional Extended Events sessions beside pgvigil\'s four: off until the server\'s DBA runs the script below; pgvigil never makes, '
          + 'changes or drops one. Each is its own session, pgvigil_<install id>_<capture>.'),
        el('h3', {}, 'The sessions'),
        grid(rowsOf(d.state), [{ key: 'capture', fmt: v => captureWords[text(v)] ?? text(v) }, { key: 'state', fmt: v => badge(text(v), v === 'running' ? 'ok' : v === 'stopped' ? 'warn' : '') },
          { key: 'session_name', label: 'session' }, { key: 'target' }, { key: 'new_events', label: 'events at the last read', num: true },
          { key: 'lost_events', label: 'lost', num: true }, { key: 'snapshot_at', label: 'read', fmt: fmtTime }],
          'Not read yet: the captures reader (mssql_xe_captures) runs every minute.'),
        el('h3', {}, 'Settings'),
        el('p', { class: 'meta' }, 'The thresholds and the exclusion lists go into the script and apply at every read too: a change takes effect at the next read; '
          + 'the session\'s own filter stays as it was made until the script runs again.'),
        ...(why ? [offNote] : []), editNote, grid(rowsOf(d.settings), settingCols),
        el('h3', {}, 'The script'),
        el('p', { class: 'meta' }, el('label', {}, 'Platform ', form), ' ', el('label', {}, 'Captures statement text ', textSel), ' ', el('label', {}, 'Install id ', id)),
        textNote,
        script,
        el('details', {}, el('summary', {}, 'The script that drops them'), el('pre', {}, text(d.drop))));
    } catch (e) {
      body.replaceChildren(errorBox(e));
    }
  };
  textSel.addEventListener('change', () => { chosen = textSel.value; void render(); });
  for (const c of [form, id]) c.addEventListener('change', () => { void render(); });
  await render();
  return sec;
}

// xeLossNote: the deadlock or blocked-process capture's loss in the window, said above its list (PerformanceMonitor
// 3.13 Added 25: an empty list is not read as none); null when nothing was lost in the window
export async function xeLossNote(ctx: Ctx, capture: 'deadlocks' | 'blocked'): Promise<HTMLElement | null> {
  const d = await loadXC(ctx, { part: 'lost' });
  const r = rowsOf(d.lost).find(x => x.capture === capture);
  return r ? el('p', { class: 'meta warn' }, badge('events lost', 'warn'),
    ` The last loss: ${fmtNum(r.lost_events)} event(s) of ${text(r.session_name)} were lost at the read of ${fmtTime(r.lost_at)}, so this window's list may miss them `
    + '(only the last loss is kept: an earlier one in this window is not shown).') : null;
}

// the slow capture's trend (SQLMonitor's XEvent Trend): per hour or day, by login, program, host or database
export async function xeSlowTrend(ctx: Ctx): Promise<HTMLElement> {
  const box = el('section', {}, el('h3', {}, 'The slow workload over time'));
  const by = el('select', { 'aria-label': 'Group by' }, ...['login', 'program', 'host', 'database'].map(x => el('option', { value: x }, x)));
  const bucket = el('select', { 'aria-label': 'Per' }, el('option', { value: 'hour' }, 'hour'), el('option', { value: 'day' }, 'day'));
  const holder = el('div', { 'aria-live': 'polite' });
  const draw = async () => {
    try {
      const d = await loadXC(ctx, { part: 'trend', by: by.value, bucket: bucket.value });
      const rows = rowsOf(d.trend);
      const cpu = pivot(rows, 'grp', 'cpu_ms'), n = pivot(rows, 'grp', 'events'), rd = pivot(rows, 'grp', 'logical_reads');
      holder.replaceChildren(
        lineChart(`CPU ms per ${bucket.value}, by ${by.value}`, cpu.rows, cpu.keys.map(k => ({ key: k, label: k })), v => fmtNum(v) + ' ms'),
        lineChart(`Completions per ${bucket.value}, by ${by.value}`, n.rows, n.keys.map(k => ({ key: k, label: k }))),
        lineChart(`Logical reads per ${bucket.value}, by ${by.value}`, rd.rows, rd.keys.map(k => ({ key: k, label: k }))),
        el('details', {}, el('summary', {}, 'The numbers as a table'),
          grid(rows, [{ key: 'bucket_at', label: 'from', fmt: fmtTime }, { key: 'grp', label: by.value }, { key: 'events', label: 'completions', num: true },
            { key: 'cpu_ms', label: 'cpu', num: true, fmt: ms }, { key: 'duration_ms', label: 'duration', num: true, fmt: ms }, { key: 'logical_reads', label: 'logical reads', num: true }],
          'No slow completion in this window.')));
    } catch (e) {
      holder.replaceChildren(errorBox(e));
    }
  };
  by.addEventListener('change', () => { void draw(); });
  bucket.addEventListener('change', () => { void draw(); });
  box.append(el('p', { class: 'meta' }, 'The completions of the slow capture (batches and procedure calls; not their statements, so nothing is counted twice), the eight largest groups. ',
    el('label', {}, 'By ', by), ' ', el('label', {}, 'per ', bucket)), holder);
  await draw();
  return box;
}
