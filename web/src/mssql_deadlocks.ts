// The Deadlocks tab of a SQL Server instance (task 120; it takes the place of the list in mssql_xe.ts): the capture's
// state and the tab's findings, the deadlocks per step over the range (Darling 13.5's Deadlock trend), the list, and
// one deadlock opened as a DRAWN graph (deadlock_graph.ts: the sessions as boxes with their statement's first line,
// the victim marked VICTIM, the resources between them, the edges labelled with the lock mode) with Save XML, the
// victim's details, and the processes and resources as grids (the picture's text form).
// Data: /api/mssql/xe (state, findings, deadlocks), /api/mssql/xe/deadlock and deadlock.xdl, /api/blocking/history.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';
import { DlGraph, deadlockSvg, graphFromRows, graphFromXml, resourceKind, sessionName } from './deadlock_graph';
import { sqlCell } from './sqlview';

const text = (v: unknown) => v == null ? '' : String(v);
const ms = (v: unknown) => v == null ? '' : fmtNum(v) + ' ms';
const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const CHECKS = ['deadlocks in the last hour', 'a capture is not installed', 'a capture is stopped', 'the ring buffer dropped events'];

// stateLine: the deadlock capture as the reader last saw it (the Extended Events tabs' wording, shortened)
function stateLine(st: Row | undefined): HTMLElement {
  if (!st) return el('p', { class: 'meta' }, badge('not read yet', ''), ' The Extended Events reader (mssql_xe, every minute) has not read this instance yet.');
  const read = ` (read ${fmtTime(st.snapshot_at)})`;
  if (st.state === 'not installed') {
    return el('p', { class: 'meta' }, badge('not installed', 'warn'), ' This server has no deadlock session of pgvigil (', el('code', {}, 'pgvigil mssql-xe -print'),
      ' writes it for the server\'s DBA).', st.source === 'system_health' ? ' The deadlocks below are the ones SQL Server\'s own system_health session kept.' : '', read);
  }
  if (st.state === 'stopped') return el('p', { class: 'meta' }, badge('stopped', 'warn'), ` The session ${text(st.session_name)} is defined and not started: nothing is captured.`, read);
  return el('p', { class: 'meta' }, badge('running', 'ok'), ` session ${text(st.session_name)}, target ${text(st.target)}`, read,
    st.lost_at != null ? ` Events were lost: ${fmtNum(st.lost_events)} at the read of ${fmtTime(st.lost_at)}.` : '');
}

const processCols: Col[] = [
  { key: 'victim', label: 'victim', fmt: v => v === true ? badge('victim', 'crit') : '' },
  { key: 'spid', label: 'session', num: true },
  { key: 'login' }, { key: 'host' }, { key: 'program' }, { key: 'database' },
  { key: 'waits_on', label: 'waited on' }, { key: 'waits_mode', label: 'lock wanted' },
  { key: 'wait_ms', label: 'waited', num: true, fmt: ms },
  { key: 'wait_resource', label: 'wait resource' },
  { key: 'isolation' }, { key: 'trancount', label: 'open transactions', num: true },
  { key: 'log_used', label: 'log used (bytes)', num: true },
  { key: 'proc', label: 'procedure' },
  { key: 'statement', fmt: (v, r) => sqlCell(v, { heading: `session ${text(r.spid)}: statement` }) },
];
const holders = (v: unknown) => Array.isArray(v) ? v.map(x => `${text((x as Row).spid ?? (x as Row).process ?? '?')} (${text((x as Row).mode ?? '?')})`).join(', ') : '';
const resourceCols: Col[] = [
  { key: 'type', label: 'lock', fmt: v => resourceKind(String(v ?? '')) }, { key: 'object' }, { key: 'index' }, { key: 'mode', label: 'granted mode' },
  { key: 'owners', label: 'held by session (mode)', fmt: holders },
  { key: 'waiters', label: 'waited for by session (mode)', fmt: holders },
];

// victimProps: the victim's details under the picture (Darling's 'SPID 84 (victim)' block)
function victimProps(g: DlGraph): HTMLElement | null {
  const v = g.processes.find(p => p.victim);
  if (!v) return null;
  return el('div', {}, el('h4', {}, `${sessionName(v)} (the victim)`), props([
    ['process', v.process], ['contended object', v.waits_on ?? ''], ['lock wanted', v.waits_mode ?? ''],
    ['wait resource', v.wait_resource ?? ''], ['waited', v.wait_ms == null ? '' : fmtNum(v.wait_ms) + ' ms'],
    ['login', [v.login, v.host].filter(Boolean).join(' @ ')], ['program', v.program ?? ''], ['database', v.database ?? ''],
    ['isolation', v.isolation ?? ''], ['open transactions', v.trancount == null ? '' : fmtNum(v.trancount)],
    ['log used', v.log_used == null ? '' : fmtNum(v.log_used) + ' bytes'],
  ]));
}

async function openDeadlock(ctx: Ctx, row: Row, panel: HTMLElement, focus = true) {
  const show = (...kids: (Node | string)[]) => {
    panel.replaceChildren(el('h3', { tabindex: '-1' }, `The deadlock of ${fmtTime(row.event_at)}`), ...kids);
    if (focus) (panel.firstElementChild as HTMLElement).focus();
  };
  try {
    const t = await get<Table>('mssql/xe/deadlock', { instance: ctx.instance, at: String(row.event_at), key: String(row.event_key) });
    const d = rowsOf(t)[0];
    if (!d) { show(el('p', { class: 'empty' }, 'This deadlock is no longer stored.')); return; }
    const q = new URLSearchParams({ instance: String(ctx.instance), at: String(row.event_at), key: String(row.event_key) });
    const xdl = `/api/mssql/xe/deadlock.xdl?${q}`;
    // the picture from the XML SQL Server wrote; where the XML is not kept, from the processes the collector took out of it
    let g: DlGraph | null = null, from = '';
    if (d.has_graph === true) {
      const res = await fetch(xdl, { credentials: 'same-origin' });
      if (res.ok) { g = graphFromXml(await res.text()); if (g) from = 'Drawn from the deadlock XML SQL Server wrote.'; }
    }
    if (!g) {
      g = graphFromRows(d.processes, d.resources);
      if (g) from = d.has_graph === true ? 'Drawn from the processes and resources the reader stored: the stored XML holds no process this page could read.'
        : 'Drawn from the processes and resources the reader stored: the XML itself is not kept under this instance\'s query_text policy.';
    }
    const save = d.has_graph === true
      ? el('a', { href: xdl, download: '', class: 'button' }, 'Save XML')
      : el('span', { class: 'meta' }, 'No XML to save: it carries statement text, and this instance\'s query_text policy is not "full".');
    show(
      props([
        ['when', fmtTime(d.event_at)],
        ['read from', d.source === 'system_health' ? 'system_health (SQL Server\'s own session)' : text(d.session_name)],
        ['processes', `${fmtNum(d.process_count)}, ${fmtNum(d.victim_count)} chosen as victim`],
        ['databases', text(d.database_names)], ['objects', text(d.object_names)],
        ['graph', el('span', {}, save, d.has_graph === true ? ' (an .xdl file: SSMS opens it as a deadlock graph)' : '')],
      ]),
      ...(g ? [el('h4', {}, `Graph (${g.processes.length} processes)`), el('p', { class: 'meta' }, from),
        el('div', { class: 'deadlock-graph-box grid-wrap', tabindex: '0' }, deadlockSvg(g))] : [el('p', { class: 'empty' }, 'The graph could not be taken apart; save the XML instead.')]),
      ...(g ? [victimProps(g)].filter((x): x is HTMLElement => !!x) : []),
      el('h4', {}, 'Processes'), grid(g ? g.processes as unknown as Row[] : [], processCols, 'No process in the graph.'),
      el('h4', {}, 'Resources'), grid(g ? g.resources as unknown as Row[] : [], resourceCols, 'No resource in the graph.'),
    );
  } catch (e) {
    show(errorBox(e));
  }
}

export async function mssqlDeadlocksView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Deadlocks (${rangeLabel(ctx)})`));
  try {
    const win = window_(ctx);
    const part = (p: string) => get<Record<string, Table | null>>('mssql/xe', { instance: ctx.instance, ...win, part: p });
    const [st, fi, dl, tr] = await Promise.all([part('state'), part('findings'), part('deadlocks'),
      get<Record<string, Table | null>>('blocking/history', { instance: ctx.instance, ...win, part: 'deadlock_trend' })]);
    const f = rowsOf(fi.findings).filter(r => CHECKS.includes(String(r.check_name)));
    if (f.length) sec.append(el('h3', {}, 'Findings'), grid(f, [
      { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'finding' }, { key: 'object', wide: true }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
    ]));
    sec.append(stateLine(rowsOf(st.state).find(r => r.capture === 'deadlocks')));
    const rows = rowsOf(dl.deadlocks);
    const trend = rowsOf(tr.deadlock_trend);
    const hours = Math.max(1 / 60, (Date.parse(win.to) - Date.parse(win.from)) / 3600000);
    const step = trend.length > 1 ? (Date.parse(String(trend[1].snapshot_at)) - Date.parse(String(trend[0].snapshot_at))) / 60000 : 1;
    sec.append(el('div', { class: 'tiles' },
      tile('deadlocks', fmtNum(rows.length) + (rows.length >= 500 ? '+' : ''), rows.length ? 'warn' : ''),
      tile('per hour', rows.length ? (Math.round(10 * rows.length / hours) / 10).toLocaleString() : '0'),
      tile('last', rows.length ? fmtTime(rows[0].event_at) : '-')));
    if (rows.length) sec.append(el('div', { class: 'charts' }, lineChart(`Deadlocks per ${step >= 60 ? step / 60 + ' h' : Math.round(step) + ' min'}`, trend,
      [{ key: 'deadlocks', label: 'deadlocks' }, { key: 'processes', label: 'processes in them' }])));
    const panel = el('section', { class: 'detail', 'aria-live': 'polite' });
    const open = (r: Row) => {
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `Graph: the deadlock of ${fmtTime(r.event_at)}` }, `Graph (${fmtNum(r.process_count)} processes)`);
      b.addEventListener('click', () => { void openDeadlock(ctx, r, panel); });
      return b;
    };
    const q = (r: Row) => new URLSearchParams({ instance: String(ctx.instance), at: String(r.event_at), key: String(r.event_key) });
    const cols: Col[] = [
      { key: 'event_at', label: 'when', fmt: fmtTime },
      { key: 'event_key', label: 'graph', fmt: (_, r) => open(r) },
      { key: 'has_graph', label: 'XML', fmt: (v, r) => v === true ? el('a', { href: `/api/mssql/xe/deadlock.xdl?${q(r)}`, download: '', 'aria-label': `Save XML: the deadlock of ${fmtTime(r.event_at)}` }, 'Save XML') : 'not kept' },
      { key: 'victim_spid', label: 'victim session', num: true },
      { key: 'victim_login', label: 'victim login' }, { key: 'victim_program', label: 'victim program' },
      { key: 'database_names', label: 'databases' }, { key: 'object_names', label: 'objects', wide: true },
      { key: 'victim_statement', label: 'the victim\'s statement', fmt: (v, r) => sqlCell(v, { heading: `the victim of ${fmtTime(r.event_at)}: statement` }) },
      { key: 'source', label: 'read from', fmt: v => v === 'system_health' ? 'system_health' : 'pgvigil\'s session' },
    ];
    sec.append(grid(rows, cols, 'No deadlock in this window.'), panel);
    // the newest opens by itself, so the page shows a drawn graph without a click
    if (rows.length) void openDeadlock(ctx, rows[0], panel, false);
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
