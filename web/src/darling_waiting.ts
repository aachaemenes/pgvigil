// The Waiting tasks tab (task 177, darling-open D01): what every waiting task waits on, read by read.
//   SQL Server  #/mssql_waiting?i=<id>[&at=<read>][&wt=<wait type>]  every task of sys.dm_os_waiting_tasks each minute
//               (PerformanceMonitor's waiting-tasks read, Darling Data, MIT: internal/mssql/darling_waiting.go): the
//               session, its exec context (a parallel request has one task per context), the wait, the blocker, the
//               resource decoded to database, object and index, the request's statement; the range's wait types,
//               each a link to the tasks waiting on it. The Waits tab links here with wt= (the lead's line).
//   PostgreSQL  #/waiting?i=<id>[&at=..][&wt=<type:event>]  the waiting backends of the running-queries samples
//               (0002): the backend, its parallel leader (a worker is sampled only when it blocks a lock waiter), the wait event, how long, the blocking pids, the query.
// One read at a time: the newest of the range unless at= names one, with Earlier / Later / Latest.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, href, window_ } from './router';
import { hashParam } from './dbinfo';
import { Col, el, fmtNum, fmtTime, grid, tile } from './ui';

interface WaitingData { snapshots?: Table | null; tasks?: Table | null; bytype?: Table | null; pg?: Table | null; pgbytype?: Table | null }

// the tab's own link: one read (at) and one wait (wt), the range kept
function waitingHref(ctx: Ctx, tab: string, at?: string, wt?: string): string {
  const h = href(ctx, { tab });
  const q = new URLSearchParams(h.split('?')[1] ?? '');
  for (const k of ['at', 'wt']) q.delete(k);
  if (at) q.set('at', at);
  if (wt) q.set('wt', wt);
  return `#/${tab}?${q}`;
}
const ms = (v: unknown) => v == null ? '' : Number(v) >= 60000 ? fmtSecsShort(Number(v) / 1000) : `${fmtNum(Number(v))} ms`;
function fmtSecsShort(s: number): string {
  if (s < 3600) return `${Math.floor(s / 60)} min ${Math.round(s % 60)} s`;
  return `${Math.floor(s / 3600)} h ${Math.round((s % 3600) / 60)} min`;
}
// a read's time exactly as the API wrote it (microseconds kept): at= must name the read itself, not a millisecond before it
const iso = (v: unknown) => String(v ?? '');
// a long text on one line, the whole of it as the title (a statement, a resource as read)
const oneLine = (v: unknown, n = 120) => { const s = String(v ?? '').replace(/\s+/g, ' ').trim(); return s.length > n ? el('span', { title: s }, s.slice(0, n) + '...') : s; };
// blocked by another session (a parallel request's exchange waits name its own session: not a block)
const byOther = (r: Row) => r.blocking_session_id != null && Number(r.blocking_session_id) !== Number(r.session_id);

// readNav: the read in view, Earlier / Later / Latest over the range's reads
function readNav(ctx: Ctx, tab: string, reads: string[], cur: string | undefined, wt: string | undefined, label: string): HTMLElement {
  const i = cur ? reads.indexOf(cur) : -1;
  const earlier = i > 0 ? reads[i - 1] : undefined;
  const later = i >= 0 && i < reads.length - 1 ? reads[i + 1] : undefined;
  const link = (text: string, at: string | undefined, latest = false) => at || latest
    ? el('a', { href: waitingHref(ctx, tab, latest ? undefined : at, wt) }, text)
    : el('span', { class: 'meta', 'aria-disabled': 'true' }, text);
  return el('p', { class: 'meta', role: 'group', 'aria-label': `${label} in view` },
    `${label} ${cur ? fmtTime(cur) : '(none in the range)'} (${reads.length} in the range): `,
    link('Earlier', earlier), ' / ', link('Later', later), ' / ', link('Latest', undefined, i !== reads.length - 1));
}

function filterLine(ctx: Ctx, tab: string, at: string | undefined, wt: string | undefined, what: string): HTMLElement | string {
  return wt ? el('p', { class: 'meta' }, `Only the ${what} waiting on ${wt} (`, el('a', { href: waitingHref(ctx, tab, at) }, 'show every wait'), ').') : '';
}

// waitingLink: a wait type of the Waits tab as a link to the Waiting tasks filtered to it (the instance and the range
// of the page it is on kept); inner is what the cell showed
export function waitingLink(waitType: string, inner: Node | string): HTMLElement {
  const cur = new URLSearchParams(location.hash.split('?')[1] ?? '');
  const q = new URLSearchParams();
  for (const k of ['i', 'w', 'from', 'to']) { const v = cur.get(k); if (v) q.set(k, v); }
  q.set('wt', waitType);
  return el('a', { href: `#/mssql_waiting?${q}`, title: `the tasks waiting on ${waitType}` }, inner);
}

// mssqlWaitingView: a SQL Server instance's Waiting tasks tab
export async function mssqlWaitingView(ctx: Ctx): Promise<HTMLElement> {
  const w = window_(ctx), at = hashParam('at'), wt = hashParam('wt');
  const d = await get<WaitingData>('waiting', { instance: ctx.instance, from: w.from, to: w.to, ...(at ? { at } : {}), ...(wt ? { wait: wt } : {}) });
  const snaps = rowsOf(d.snapshots), tasks = rowsOf(d.tasks), types = rowsOf(d.bytype);
  const reads = snaps.map(r => iso(r.snapshot_at));
  const cur = tasks.length ? iso(tasks[0].snapshot_at) : at && reads.includes(at) ? at : reads.length && !at ? reads[reads.length - 1] : undefined;
  const snap = snaps.find(r => cur && iso(r.snapshot_at) === cur);
  const sec = el('section', {}, el('h2', {}, 'Waiting tasks'),
    el('p', { class: 'meta' }, 'Every task of sys.dm_os_waiting_tasks each minute (a parallel request has one task per exec context), with its blocker and the resource it waits for named down to the index; the benign waits are left out. PerformanceMonitor\'s read (Darling Data).'));
  if (!snaps.length) {
    sec.append(el('p', { class: 'empty' }, 'No read of the waiting tasks in this range: the collection mssql_waiting_tasks runs every minute on an instance whose login has VIEW SERVER STATE.'));
    return sec;
  }
  const blocked = tasks.filter(byOther).length;
  const sessions = new Set(tasks.map(r => r.session_id)).size;
  sec.append(el('div', { class: 'tiles' },
    tile(wt ? `Tasks waiting on ${wt}` : 'Tasks waiting', fmtNum(wt ? tasks.length : Number(snap?.tasks ?? tasks.length))),
    tile('Sessions', fmtNum(wt ? sessions : Number(snap?.sessions ?? sessions))),
    tile('Blocked by a session', fmtNum(blocked), blocked ? 'warn' : 'ok'),
    tile('THREADPOOL waiters', fmtNum(Number(snap?.threadpool ?? 0)), Number(snap?.threadpool ?? 0) ? 'crit' : 'ok'),
    tile('Longest wait', snap?.longest_ms == null ? 'none' : ms(snap.longest_ms))),
    readNav(ctx, 'mssql_waiting', reads, cur, wt, 'Read at'), filterLine(ctx, 'mssql_waiting', cur, wt, 'tasks'));
  if (snap && Number(snap.stored) < Number(snap.tasks)) sec.append(el('p', { class: 'meta' }, `The ${fmtNum(Number(snap.stored))} longest of ${fmtNum(Number(snap.tasks))} waiting tasks are kept for this read.`));
  if (snap?.decode_note) sec.append(el('p', { class: 'meta' }, `Not every resource was named: ${String(snap.decode_note)}.`));
  const cols: Col[] = [
    { key: 'session_id', label: 'session', num: true, fmt: (v, r) => Number(r.tasks_of_session) > 1 ? `${String(v)} (${String(r.tasks_of_session)} tasks)` : String(v ?? '') },
    { key: 'exec_context_id', label: 'context', num: true, fmt: v => String(v ?? '') },
    { key: 'wait_type', label: 'wait', fmt: v => el('a', { href: waitingHref(ctx, 'mssql_waiting', cur, String(v)), title: `the tasks waiting on ${String(v)}` }, String(v)) },
    { key: 'wait_ms', label: 'waited', num: true, fmt: v => ms(v) },
    { key: 'blocking_session_id', label: 'blocked by', num: true, fmt: (v, r) => v == null ? '' : !byOther(r)
      ? `own context ${String(r.blocking_exec_context_id ?? '')}`
      : `${String(v)}${r.blocking_exec_context_id != null && Number(r.blocking_exec_context_id) > 0 ? ` (context ${String(r.blocking_exec_context_id)})` : ''}` },
    { key: 'resource_kind', label: 'resource' },
    { key: 'object_name', label: 'object' },
    { key: 'index_name', label: 'index' },
    { key: 'database_name', label: 'database' },
    { key: 'command' },
    { key: 'request_status', label: 'status' },
    { key: 'statement', fmt: v => oneLine(v) },
    { key: 'resource_description', label: 'resource as read', fmt: v => oneLine(v, 60) },
  ];
  sec.append(el('h3', {}, 'The tasks of this read'), grid(tasks, cols, wt ? `No task waited on ${wt} in this read.` : 'No task waited in this read (beyond the benign waits).'));
  sec.append(el('h3', {}, 'Wait types over the range'),
    el('p', { class: 'meta' }, 'From the stored reads: how many tasks and sessions waited on each, counted read by read (a session waiting in two reads counts twice; a session id can go to a later session once its session ends), in how many reads, the longest wait seen and when it was last seen. A wait type opens the read where it was last seen, filtered to it.'),
    grid(types, [
      { key: 'wait_type', label: 'wait', fmt: (v, r) => el('a', { href: waitingHref(ctx, 'mssql_waiting', iso(r.last_seen), String(v)), title: `the read where ${String(v)} was last seen` }, String(v)) },
      { key: 'tasks', num: true }, { key: 'sessions', num: true }, { key: 'reads', num: true },
      { key: 'longest_ms', label: 'longest', num: true, fmt: v => ms(v) },
      { key: 'last_seen', label: 'last seen', fmt: v => fmtTime(v) },
    ], 'No task waited in any read of this range.'));
  return sec;
}

// pgWaitingView: the PostgreSQL twin over the running-queries samples
export async function pgWaitingView(ctx: Ctx): Promise<HTMLElement> {
  const w = window_(ctx), at = hashParam('at'), wt = hashParam('wt');
  const d = await get<WaitingData>('waiting', { instance: ctx.instance, from: w.from, to: w.to, ...(at ? { at } : {}), ...(wt ? { wait: wt } : {}) });
  const rows = rowsOf(d.pg), types = rowsOf(d.pgbytype);
  const cur = rows.length ? iso(rows[0].snapshot_at) : at;
  const sec = el('section', {}, el('h2', {}, 'Waiting backends'),
    el('p', { class: 'meta' }, 'The backends that wait in a running-queries sample: active with a wait event (not the client\'s, an idle loop\'s or a timer\'s), and every lock waiter, with the pids that block it. A sample keeps client backends and the processes that block a lock waiter, so a parallel worker shows (with its leader) only when it blocks one. The lock\'s target relation is not sampled: Running queries shows the chain. One sample at a time: the newest of the range.'));
  const locks = rows.filter(r => r.wait_event_type === 'Lock').length;
  sec.append(el('div', { class: 'tiles' },
    tile(wt ? `Backends waiting on ${wt}` : 'Backends waiting', fmtNum(rows.length)),
    tile('Lock waits', fmtNum(locks), locks ? 'warn' : 'ok')),
    el('p', { class: 'meta' }, `Sample ${cur ? fmtTime(cur) : '(the newest)'}: `, el('a', { href: waitingHref(ctx, 'waiting', undefined, wt) }, 'Latest')),
    filterLine(ctx, 'waiting', cur, wt, 'backends'));
  const key = (r: Row) => `${String(r.wait_event_type)}:${String(r.wait_event)}`;
  sec.append(el('h3', {}, 'The backends of this sample'), grid(rows, [
    { key: 'pid', num: true, fmt: v => String(v ?? '') },
    { key: 'leader_pid', label: 'leader', num: true, fmt: (v, r) => v == null || v === r.pid ? '' : String(v) },
    { key: 'wait_event', label: 'wait', fmt: (_v, r) => el('a', { href: waitingHref(ctx, 'waiting', cur, key(r)), title: `the backends waiting on ${key(r)}` }, key(r)) },
    { key: 'in_state_s', label: 'in this state', num: true, fmt: v => v == null ? '' : `${String(v)} s` },
    { key: 'blocking_pids', label: 'blocked by', fmt: v => Array.isArray(v) ? v.join(', ') : String(v ?? '') },
    { key: 'datname', label: 'database' }, { key: 'usename', label: 'user' }, { key: 'application_name', label: 'application' },
    { key: 'state' }, { key: 'backend_type', label: 'backend' },
    { key: 'query', fmt: v => oneLine(v) },
  ], wt ? `No backend waited on ${wt} in this sample.` : 'No backend waited in the newest sample of this range (or no sample was taken in it).'));
  sec.append(el('h3', {}, 'Wait events over the range'),
    el('p', { class: 'meta' }, 'From the stored samples: how many sampled backends (client backends, and the processes that block a lock waiter) waited on each, counted sample by sample (a backend waiting in two samples counts twice; a pid can come back for a later backend), in how many samples, and when it was last seen. A wait event opens the sample where it was last seen, filtered to it.'),
    grid(types, [
      { key: 'wait_event', label: 'wait', fmt: (_v, r) => el('a', { href: waitingHref(ctx, 'waiting', iso(r.last_seen), key(r)), title: `the sample where ${key(r)} was last seen` }, key(r)) },
      { key: 'backends', num: true }, { key: 'samples', num: true }, { key: 'last_seen', label: 'last seen', fmt: v => fmtTime(v) },
    ], 'No backend waited in any sample of this range.'));
  return sec;
}
