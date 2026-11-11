// The Audit tab of a SQL Server instance (task 158): SQL Server Audit as a DBA defined it on the server, read and
// never changed. First the health - every server audit with its state, target, on-failure action, queue delay,
// file and size, its specifications and their actions, the newest event read - then the events of the audits that
// write to a file: failed sign-ins and the changes an auditor asks about (role membership, permissions, logins and
// passwords, DDL, the audit itself) as rows, everything else as counts per hour, login and object. A login that
// may not read the audit files sees the health only, and the page says so; an Application or Security log target
// is named as not readable through T-SQL. Data from /api/mssql/audit; the route and the tab's entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { stripGrid } from './timestrip';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtTime, grid, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlAuditTab = 'mssqlaudit';

type Part = 'state' | 'read' | 'status' | 'findings' | 'audits' | 'specs' | 'by_category' | 'events' | 'counted' | 'counted_by_category' | 'series';
type Parts = Record<Part, Table | null>;

const text = (v: unknown) => v == null ? '' : String(v);
const sevBadge = (v: unknown) => badge(text(v), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
// prose in a grid cell: wraps inside a block that keeps its own width (a grid wider than the page squeezes a plain
// wrapping cell to a few characters and its row grows to hundreds of pixels)
const PROSE = 'display:inline-block;min-width:22rem;max-width:40rem;white-space:normal';
const prose = (v: unknown) => v == null || v === '' ? '' : el('span', { style: PROSE }, text(v));
// a path's last element, for a Windows or a Linux path
const baseName = (v: unknown) => text(v).replace(/^.*[\\/]/, '');

const CATEGORIES = ['failed sign-in', 'audit', 'role', 'permission', 'principal', 'ddl'];
const categoryLabel: Record<string, string> = {
  'failed sign-in': 'failed sign-ins', audit: 'audit changes', role: 'role membership', permission: 'permissions',
  principal: 'logins and passwords', ddl: 'DDL',
};

// the events filter is remembered per instance for the session
const categoryOf = new Map<number, string>();

// the state of an audit in a word and a colour; the word carries the meaning, never the colour alone
function stateBadge(v: unknown): HTMLElement {
  const s = text(v);
  return badge(s === 'failed' ? 'failed' : s === 'stopped' ? 'not started' : s || 'unknown',
    s === 'started' ? 'ok' : s === 'failed' ? 'crit' : s === 'stopped' || s === 'shutting down' ? 'warn' : '');
}

// what became of an audit's events at the last read
function readCell(v: unknown, r: Row): string | Node {
  const note = text(r.read_note);
  switch (text(v)) {
    case 'read':
      return el('span', { style: PROSE }, badge('read', 'ok'), ` ${fmtNum(r.new_events ?? 0)} listed, ${fmtNum(r.counted_events ?? 0)} counted at the last read`, note ? `. ${note}` : '');
    case 'waiting':
      return el('span', { style: PROSE }, badge('nothing read yet', ''), ` ${note}`);
    case 'behind':
      return el('span', { style: PROSE }, badge('behind', 'warn'), ` ${note}`);
    case 'no right':
      return el('span', { style: PROSE }, badge('health only', ''), ` ${note}`);
    case 'not readable':
      return el('span', { style: PROSE }, badge('not readable through T-SQL', ''), ` ${note}`);
    case 'error':
      return el('span', { style: PROSE }, badge('read failed', 'warn'), ` ${note}`);
    case '':
      return '';
  }
  return el('span', { style: PROSE }, badge('not read', ''), ` ${note}`);
}

const fileLimit = (r: Row): string => {
  if (r.max_file_size_mb == null) return '';
  const size = Number(r.max_file_size_mb) === 0 ? 'no size limit' : `${fmtNum(r.max_file_size_mb)} MB a file`;
  const roll = Number(r.max_files ?? 0) > 0 ? `${fmtNum(r.max_files)} files, then audited actions fail`
    : Number(r.max_rollover_files ?? 0) >= 2147483647 ? 'unlimited rollover' : `${fmtNum(r.max_rollover_files)} rollover files`;
  return `${size}, ${roll}`;
};

const auditCols: Col[] = [
  { key: 'name', label: 'audit' },
  { key: 'state', fmt: stateBadge },
  { key: 'state_since', label: 'in this state since', fmt: fmtTime },
  { key: 'target', fmt: v => text(v) || 'not known' },
  { key: 'on_failure', label: 'on failure', fmt: v => text(v).toLowerCase() },
  { key: 'queue_delay_ms', label: 'queue delay (ms)', num: true, fmt: v => v == null ? '' : Number(v) === 0 ? '0 (synchronous)' : fmtNum(v) },
  { key: 'specifications', num: true },
  { key: 'last_event_at', label: 'last event read', fmt: fmtTime },
  { key: 'read_state', label: 'its events', fmt: readCell },
  { key: 'log_file_path', label: 'folder' },
  { key: 'current_file', label: 'file written now', fmt: baseName },
  { key: 'file_size_bytes', label: 'file size', num: true, fmt: fmtBytes },
  { key: 'max_file_size_mb', label: 'file limits', fmt: (_, r) => fileLimit(r) },
  { key: 'predicate', label: 'filter', wide: true },
  { key: 'modified_at', label: 'modified', fmt: fmtTime },
];

const specCols: Col[] = [
  { key: 'scope', fmt: (v, r) => v === 'database' ? `database ${text(r.database_name)}` : 'server' },
  { key: 'name', label: 'specification' },
  { key: 'is_enabled', label: 'state', fmt: v => v === true ? badge('on', 'ok') : badge('off', 'warn') },
  { key: 'audit_name', label: 'audit', fmt: (v, r) => v == null ? badge('no such audit on this server', 'warn') : `${text(v)} (${r.audit_state === 'stopped' ? 'not started' : text(r.audit_state)})` },
  { key: 'action_count', label: 'actions', num: true },
  { key: 'actions', label: 'what it records', fmt: prose },
  { key: 'modified', label: 'modified (server clock)' },
];

const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'finding' }, { key: 'object' },
  { key: 'detail', fmt: prose }, { key: 'at', fmt: fmtTime },
];

const eventCols: Col[] = [
  { key: 'event_at', label: 'when', fmt: fmtTime },
  { key: 'category', fmt: v => categoryLabel[text(v)] ?? text(v) },
  { key: 'action', fmt: (v, r) => r.succeeded === false && r.category !== 'failed sign-in' ? el('span', {}, text(v), ' ', badge('denied', 'warn')) : text(v) },
  { key: 'class_name', label: 'on a' },
  { key: 'login_name', label: 'login', fmt: (v, r) => r.session_login ? `${text(v)} (session: ${text(r.session_login)})` : text(v) },
  { key: 'target_login', label: 'for login / user', fmt: (v, r) => [text(v), text(r.target_user)].filter((x, i, a) => x && a.indexOf(x) === i).join(' / ') },
  { key: 'database_name', label: 'database' },
  { key: 'object_name', label: 'object', fmt: (v, r) => [text(r.schema_name), text(v)].filter(Boolean).join('.') },
  { key: 'client_ip', label: 'from' }, { key: 'application' }, { key: 'host' },
  { key: 'reason', fmt: (v, r) => prose(r.error_state != null ? `${reasonOf(v)} (error ${text(r.error_number)}, state ${text(r.error_state)})` : reasonOf(v)) },
  { key: 'statement', wide: true },
  { key: 'audit_name', label: 'audit' },
];

// A failed sign-in's reason without what its row already shows in columns of their own: the login in front
// ("Login failed for user 'x'. Reason: ") and the client's address behind ("[CLIENT: 10.0.0.9]").
function reasonOf(v: unknown): string {
  return text(v).replace(/^Login failed for user '.*?'\.\s*Reason:\s*/, '').replace(/\s*\[CLIENT:[^\]]*\]\s*$/, '');
}

const countedCols: Col[] = [
  { key: 'category' }, { key: 'action' },
  { key: 'login_name', label: 'login' }, { key: 'database_name', label: 'database' },
  { key: 'object_name', label: 'object', fmt: (v, r) => [text(r.schema_name), text(v)].filter(Boolean).join('.') },
  { key: 'events', num: true },
  { key: 'not_succeeded', label: 'denied or failed', num: true },
  { key: 'hours', label: 'hours with events', num: true },
  { key: 'last_hour', label: 'last hour seen', fmt: fmtTime },
];

const seriesCols: Col[] = [
  { key: 'snapshot_at', label: 'hour from', fmt: fmtTime },
  { key: 'failed_signins', label: 'failed sign-ins', num: true }, { key: 'changes', label: 'changes listed', num: true },
  { key: 'reads', label: 'reads counted', num: true }, { key: 'writes', label: 'writes counted', num: true },
  { key: 'other_counted', label: 'other counted', num: true },
];

// what the last read could read, in words. state: the collection's last run (a skipped or failed run says why).
function readNote(read: Row | undefined, audits: Row[], state: Row | undefined): HTMLElement {
  const run = state && state.status !== 'ok' ? ` The mssql_audit collection's last run (${fmtTime(state.snapshot_at)}): ${text(state.status)}${state.note ? ' - ' + text(state.note) : ''}.` : '';
  if (!read) {
    if (state && state.status === 'skipped') {
      return el('p', { class: 'meta' }, badge('not read', ''), ` The audit of this instance is not read: ${text(state.note)}.`);
    }
    return el('p', { class: 'meta' }, badge('not read yet', ''),
      ' The audit reader (mssql_audit, every five minutes) has not read this instance yet. It needs VIEW ANY DEFINITION for the audits and their specifications, and VIEW SERVER STATE for which of them is started.' + run);
  }
  const p = el('p', { class: 'meta' }, `Read ${fmtTime(read.snapshot_at)}.${run} `);
  if (read.defs_read !== true) p.append(badge('audit list not readable', 'warn'), ' The login lacks VIEW ANY DEFINITION: only the audits the server runs now are known, without their target and specifications. ');
  if (read.state_read !== true) p.append(badge('state not readable', 'warn'), ' The login lacks VIEW SERVER STATE: which audit is started is judged by its switch alone. ');
  const fileAudits = audits.filter(a => a.target === 'file').length;
  if (read.events_readable === true) {
    p.append(`The login may read the audit files (${text(read.events_right)}). `);
  } else if (fileAudits > 0) {
    p.append(badge('health only', ''), ` The login lacks ${text(read.events_right)}: the health of ${fmtNum(fileAudits)} file audit(s) is read, their events are not. This is the login's choice of rights, not a failure of the collection. `);
  } else if (read.defs_read !== true) {
    // without the audit list the targets are not known: nothing can be said about file audits
    p.append(badge('health only', ''), ` The login lacks ${text(read.events_right)}: no audit's events are read. `);
  } else {
    p.append(`The login lacks ${text(read.events_right)}; no audit on this server writes to a file. `);
  }
  p.append(read.text_stored === true
    ? 'Statement text of the listed events is stored (audit_text is on for this instance).'
    : 'Statement text is not stored: who, when, from where and on what object only (audit_text is off, or query_text is none).');
  if (Number(read.databases_skipped ?? 0) > 0) {
    p.append(` ${fmtNum(read.databases_skipped)} database(s) were not asked for their audit specification (${text(read.skipped_names)}${Number(read.databases_skipped) > 10 ? ', ...' : ''}).`);
  }
  if (read.note) p.append(` ${text(read.note)}.`);
  return p;
}

// why: what to say under an empty list when the events are not read at all
async function eventsBlock(ctx: Ctx, win: { from: string; to: string }, category: string, why: string, first?: Table | null): Promise<HTMLElement> {
  const t = first !== undefined ? first : (await get<Parts>('mssql/audit', { instance: ctx.instance, ...win, part: 'events', category })).events;
  const rows = rowsOf(t);
  const empty = (category ? `No ${categoryLabel[category] ?? category} event in this window.` : 'No listed event in this window.') + why;
  return el('div', {}, stripGrid('Audit events', win, rows, 'event_at', eventCols, empty, 1000));
}

export async function mssqlAuditView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Audit (${rangeLabel(ctx)})`));
  try {
    const win = window_(ctx);   // one window for every read and for the strip
    const instance = Number(ctx.instance);
    const category = categoryOf.get(instance) ?? '';
    const d = await get<Parts>('mssql/audit', { instance: ctx.instance, ...win, category });
    const read = rowsOf(d.read)[0], audits = rowsOf(d.audits), specs = rowsOf(d.specs);
    const findings = rowsOf(d.findings), byCat = rowsOf(d.by_category), countedCat = rowsOf(d.counted_by_category);

    if (findings.length) sec.append(el('section', {}, el('h3', {}, 'Findings'), grid(findings, findingCols)));
    sec.append(readNote(read, audits, rowsOf(d.state)[0]));
    if (!read) return sec;

    // the health
    const started = audits.filter(a => a.state === 'started').length, failed = audits.filter(a => a.state === 'failed').length;
    const stopped = audits.filter(a => a.state === 'stopped').length;
    const switchedOn = audits.filter(a => a.state === 'started' || a.state === 'enabled').length;
    const stateRead = read.state_read === true;
    // a category's events: its listed rows plus what a read counted because it was over its row cap
    const n = (cat: string) => Number(byCat.find(r => r.category === cat)?.events ?? 0);
    const listed = (cat: string) => Number(byCat.find(r => r.category === cat)?.listed ?? 0);
    const overCap = byCat.reduce((a, r) => a + Number(r.counted_over ?? 0), 0);
    const counted = countedCat.reduce((a, r) => a + Number(r.events ?? 0), 0);
    // no audit's events were read at the last read and the window holds none: the event figures are unknown, not 0
    const unread = !audits.some(a => a.read_state === 'read' || a.read_state === 'behind' || a.read_state === 'error') && counted === 0 && byCat.length === 0;
    const ev = (v: number) => unread ? 'not read' : fmtNum(v);
    sec.append(el('div', { class: 'tiles' },
      // without the state view only the audits' switches are known: which of them runs is not
      stateRead ? tile('audits started', `${fmtNum(started)} of ${fmtNum(audits.length)}`)
        : tile('audits switched on (state not readable)', `${fmtNum(switchedOn)} of ${fmtNum(audits.length)}`),
      // a tile that marks something to look at says it in words too, never by its colour alone
      tile('audits not started', stopped ? `${fmtNum(stopped)} not started` : 'none', stopped ? 'warn' : ''),
      tile('audits failed', !stateRead ? 'not known' : failed ? `${fmtNum(failed)} failed` : 'none', failed ? 'crit' : ''),
      tile('failed sign-ins', ev(n('failed sign-in'))),
      tile('audit changes', ev(n('audit'))),
      tile('role, permission and login changes', ev(n('role') + n('permission') + n('principal'))),
      tile('DDL listed', ev(listed('ddl'))),
      tile('events counted (hours of the window)', ev(counted))));

    sec.append(el('h3', {}, 'Server audits'),
      grid(audits, auditCols, read.defs_read === true ? 'No server audit is defined on this server.' : 'No audit is known: the login cannot list them, and the server runs none now.'));
    sec.append(el('h3', {}, 'Audit specifications'),
      el('p', { class: 'meta' }, 'What each audit is told to record: a server specification names action groups for the whole server, a database '
        + 'specification names groups or single actions on a schema or an object. A specification that is off records nothing.'),
      grid(specs, specCols, 'No audit specification is defined.'));

    // the events
    const sel = el('select', { 'aria-label': 'Category of the listed events' }, el('option', { value: '' }, 'every category'));
    for (const c of CATEGORIES) {
      const o = el('option', { value: c }, `${categoryLabel[c]} (${fmtNum(listed(c))})`);
      if (c === category) o.selected = true;
      sel.append(o);
    }
    const why = read.events_readable === true ? '' : ` The audit files are not read: the login lacks ${text(read.events_right)}.`;
    const holder = el('div', { 'aria-live': 'polite' }, await eventsBlock(ctx, win, category, why, d.events));
    let asked = 0;   // the newest choice wins: an older read that answers late is dropped
    sel.addEventListener('change', () => {
      const mine = ++asked;
      categoryOf.set(instance, sel.value);
      holder.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
      eventsBlock(ctx, win, sel.value, why).then(b => { if (mine === asked) holder.replaceChildren(b); },
        e => { if (mine === asked) holder.replaceChildren(errorBox(e)); });
    });
    sec.append(el('h3', {}, 'Listed events'),
      el('p', { class: 'meta' }, 'Kept one row each: failed sign-ins, changes of role membership, permissions, logins and passwords, DDL '
        + '(but DDL inside tempdb and on statistics, which is counted) and changes of the audit itself. The newest 1,000 of the window. '
        + 'One read lists at most 20,000 events of an audit and counts the rest: they are in the figures above, in the chart and under '
        + 'Counted events, not in this list.',
        overCap > 0 ? el('span', { class: 'warn' }, ` In this window ${fmtNum(overCap)} such event(s) were counted and not listed.`) : ''),
      el('p', { class: 'meta' }, el('label', {}, 'Show ', sel)), holder);

    sec.append(el('h3', {}, 'Counted events'),
      el('p', { class: 'meta' }, 'Everything else an audit records - reads, writes, executions, sign-ins, batches - is counted per hour, login, '
        + 'database, object and action, and no row and no statement of it is kept. The counts of the hours this window touches, the 500 largest. '
        + '"Denied or failed" counts the actions whose permission check failed.'),
      grid(rowsOf(d.counted), countedCols, 'No counted event in these hours.' + why));

    const series = rowsOf(d.series);
    if (unread) {
      sec.append(el('h3', {}, 'Audit events per hour'), el('p', { class: 'empty' }, 'No audit\'s events are read on this instance: there is nothing to chart.' + why));
      return sec;
    }
    sec.append(lineChart('Audit events per hour', series, [
      { key: 'failed_signins', label: 'failed sign-ins' }, { key: 'changes', label: 'changes listed' },
      { key: 'reads', label: 'reads counted' }, { key: 'writes', label: 'writes counted' }, { key: 'other_counted', label: 'other counted' }]),
      el('details', {}, el('summary', {}, 'The chart\'s numbers as a table'), grid(series, seriesCols, 'No hour in this window.')));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
