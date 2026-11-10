// The SQL Server Running queries tab (task 96), in DBA Dash's shape: one snapshot of what ran on the server (a
// session that runs a request, holds an open transaction or blocks another), ONE LINE per session (a statement
// shows its first 80 characters and opens whole in the shared viewer), a slider with Earlier and Later over the
// kept minutes of the range, a 'Blocked (n)' filter, a group-by, and the blocking chains of the snapshot drawn as a
// tree with the head first. An address with at= (the fleet page's row) opens the snapshot at or before that time.
// Data from /api/mssql/running; the route and the tab's entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, isLive, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid } from './ui';
import { foldedGrid } from './running';
import { firstChars, sqlCell, whatIsThis } from './sqlview';

interface RunningData { state: Table | null; snapshots: Table | null; rows: Table | null; blocking: Table | null }

// the three notes that were paragraphs on the page: each is the title of a 'what is this' link now
const chainsNote = 'A head blocks others and waits behind no session: the cause of its chain is its transaction and its last statement, not the object '
  + 'the others wait on. A sleeping head with an open transaction is an application that left its transaction open; the statement shown is its last batch.';
const noHeadNote = 'These blocked rows have no head to name (a blocker that is not a session, or a cycle): see the "chain head" column of the sessions.';
const sessionsNote = 'A session that runs a request, holds an open transaction or blocks another. On a parallel request the CPU, reads and writes are '
  + 'marked "(coordinator)": the server keeps them for the coordinator task alone, and the sums over the request\'s tasks are beside them. '
  + 'On a sleeping row the statement is the last batch the session ran.';

const ms = (v: unknown) => v == null ? '' : fmtSecs(Math.floor(Number(v) / 1000));
const kb = (v: unknown) => v == null ? '' : fmtBytes(Number(v) * 1024);
const parallel = (r: Row) => Number(r.task_count) > 1 || Number(r.dop) > 1;
// a counter sys.dm_exec_requests keeps for the coordinator task alone is marked on a parallel request
const coord = (v: unknown, r: Row) => v == null ? '' : parallel(r)
  ? el('span', { title: 'A parallel request: this counter is its coordinator task\'s alone. The sums over its tasks are in the columns "tasks CPU" and "tasks IO".' }, fmtNum(v) + ' (coordinator)')
  : fmtNum(v);
const waitCell = (_v: unknown, r: Row) => r.wait_type == null ? ''
  : el('span', {}, String(r.wait_type).startsWith('LCK_') ? badge(String(r.wait_type), 'warn') : String(r.wait_type), ' ' + ms(r.wait_ms));
const sessionWaits = (v: unknown) => {
  if (typeof v !== 'string' || !v) return '';
  try {
    return (JSON.parse(v) as { wait: string; ms: number; tasks: number }[]).map(w => `${w.wait} ${fmtSecs(Math.floor(w.ms / 1000))} (${fmtNum(w.tasks)})`).join(', ');
  } catch { return ''; }
};
const statusCell = (v: unknown, r: Row) => v === 'sleeping' && Number(r.open_tran) > 0
  ? badge('sleeping, transaction open', 'warn') : String(v ?? '');
// clip: a long value on one line, whole in the cell's title
const clip = (n: number) => (v: unknown) => {
  const s = v == null ? '' : String(v);
  return s.length > n ? el('span', { title: s }, firstChars(s, n)) : s;
};
const sleeping = (r: Row) => r.request_id == null;
const stmtCell = (v: unknown, r: Row) => sqlCell(v, { heading: `session ${String(r.session_id)}: ${sleeping(r) ? 'last batch' : 'statement'}`,
  title: sleeping(r) ? 'This session runs no request: the text is the LAST batch it ran, not one running now.' : undefined });

// A head that itself waits behind something that is no session (an orphaned transaction, a latch without an
// owner) says so beside its badge: it is not the holder to kill.
const headCell = (r: Row) => r.chain_note == null ? badge('head', 'crit')
  : el('span', {}, badge('head', 'warn'), ' ' + String(r.chain_note) + ': not the holder, nothing to kill here');

const cols: Col[] = [
  { key: 'session_id', label: 'session', num: true, fmt: v => String(v) },
  { key: 'status', fmt: statusCell },
  { key: 'command' },
  { key: 'wait_type', label: 'waiting on', fmt: waitCell },
  { key: 'wait_resource', label: 'wait resource', fmt: clip(60) },
  { key: 'blocking_session_id', label: 'blocked by', num: true, fmt: v => Number(v) ? String(v) : '' },
  { key: 'head_session_id', label: 'chain head', num: true, fmt: (v, r) => v == null ? String(r.chain_note ?? '') : Number(r.chain_depth) === 0 ? headCell(r) : String(v) },
  { key: 'victims', label: 'blocks', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : '' },
  { key: 'elapsed_ms', label: 'running for', num: true, fmt: ms },
  { key: 'tran_age_ms', label: 'transaction open for', num: true, fmt: ms },
  { key: 'database_name', label: 'database' }, { key: 'login_name', label: 'login' }, { key: 'program_name', label: 'program', fmt: clip(40) },
  { key: 'host_name', label: 'host' },
  { key: 'statement', fmt: stmtCell },
  { key: 'percent_complete', label: '% done', num: true, fmt: v => Number(v) > 0 ? fmtNum(v) + ' %' : '' },
  { key: 'cpu_ms', label: 'CPU ms', num: true, fmt: coord },
  { key: 'logical_reads', label: 'logical reads', num: true, fmt: coord },
  { key: 'reads', label: 'physical reads', num: true, fmt: coord },
  { key: 'writes', num: true, fmt: coord },
  { key: 'dop', label: 'DOP', num: true },
  { key: 'task_count', label: 'tasks', num: true },
  { key: 'tasks_cpu_ms', label: 'tasks CPU ms', num: true },
  { key: 'tasks_physical_io', label: 'tasks IO', num: true },
  { key: 'granted_memory_kb', label: 'granted memory', num: true, fmt: kb },
  { key: 'tempdb_current_kb', label: 'tempdb now', num: true, fmt: kb },
  { key: 'tempdb_alloc_kb', label: 'tempdb allocated', num: true, fmt: kb },
  { key: 'open_tran', label: 'open tran', num: true },
  { key: 'tran_log_bytes', label: 'log written', num: true, fmt: v => v == null ? '' : fmtBytes(v) },
  { key: 'transaction_id', label: 'transaction id', fmt: v => v == null ? '' : String(v) },
  { key: 'isolation_level', label: 'isolation' },
  { key: 'session_waits', label: 'largest session waits', fmt: v => clip(60)(sessionWaits(v)) },
  { key: 'query_hash', label: 'query hash' }, { key: 'query_plan_hash', label: 'plan hash' },
  { key: 'sql_handle', label: 'sql handle', fmt: clip(18) }, { key: 'plan_handle', label: 'plan handle', fmt: clip(18) },
];

const treeCols: Col[] = [
  { key: 'session_id', label: 'session', fmt: (v, r) => el('span', { style: `padding-left:${Number(r.tree_depth) * 1.2}em` }, (Number(r.tree_depth) > 0 ? '└ ' : '') + String(v)) },
  { key: 'tree_role', label: 'role', fmt: (v, r) => v === 'head' ? headCell(r) : String(v ?? '') },
  { key: 'victims', label: 'blocks', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : '' },
  { key: 'status', fmt: statusCell },
  { key: 'wait_type', label: 'waiting on', fmt: waitCell },
  { key: 'wait_resource', label: 'wait resource', fmt: clip(60) },
  { key: 'tran_age_ms', label: 'transaction open for', num: true, fmt: ms },
  { key: 'database_name', label: 'database' }, { key: 'login_name', label: 'login' }, { key: 'program_name', label: 'program', fmt: clip(40) },
  { key: 'statement', fmt: stmtCell },
];

// treeRows orders a snapshot's chain rows as a tree: each head, then the sessions it blocks, depth first, the
// longest waiter first. A head whose own row the read did not hold still opens its tree.
function treeRows(rows: Row[], heads: Row[]): Row[] {
  const first = new Map<number, Row>();
  for (const r of rows) if (!first.has(Number(r.session_id)) || Number(r.blocking_session_id)) first.set(Number(r.session_id), r);
  const kids = new Map<number, Row[]>();
  for (const r of first.values()) {
    const b = Number(r.blocking_session_id);
    if (b > 0 && b !== Number(r.session_id) && r.head_session_id != null) kids.set(b, [...(kids.get(b) ?? []), r]);
  }
  const out: Row[] = [];
  const walk = (id: number, depth: number, seen: Set<number>) => {
    for (const k of (kids.get(id) ?? []).sort((a, b) => Number(b.wait_ms) - Number(a.wait_ms))) {
      const kid = Number(k.session_id);
      if (seen.has(kid)) continue;
      seen.add(kid);
      out.push({ ...k, tree_depth: depth, tree_role: kids.has(kid) ? 'blocked, and blocks' : 'blocked' });
      walk(kid, depth + 1, seen);
    }
  };
  for (const h of heads) {
    const id = Number(h.head_session_id);
    const own = first.get(id);
    out.push(own ? { ...own, tree_depth: 0, tree_role: 'head', victims: h.victims }
      : { session_id: id, tree_depth: 0, tree_role: 'head', victims: h.victims, status: 'not in the read', statement: h.note });
    walk(id, 1, new Set([id]));
  }
  return out;
}

// body draws one snapshot. picked is the snapshot the slider chose; without it the page shows the newest of the
// window (the list is newest first), which is also the one the API returned. A quiet minute has no row to read
// its time from, so the time never comes from the rows.
function body(d: RunningData, picked?: unknown): HTMLElement {
  const box = el('div');
  const rows = rowsOf(d.rows), heads = rowsOf(d.blocking);
  const snaps = rowsOf(d.snapshots);
  const sum = picked === undefined ? snaps[0] : snaps.find(s => s.snapshot_at === picked);
  if (!sum) { box.append(el('p', { class: 'empty' }, 'No snapshot in this window.')); return box; }
  const src = el('span', { title: String(sum.source_note ?? '') }, sum.source === 'sp_whoisactive' ? 'sp_WhoIsActive' : 'the DMVs');
  // the status line of totals (DBA Dash's 'Blocked Sessions: 2, Blocked Wait Time ...'), then where the read came from
  const nBlocked = Number(sum.blocked), pending = Number(sum.memory_grants_pending ?? 0);
  box.append(el('p', { class: 'meta counts running-status' },
    el('span', { class: nBlocked ? (Number(sum.longest_wait_ms) > 300000 ? 'crit' : 'warn') : '' },
      `Blocked sessions: ${fmtNum(sum.blocked)}` + (nBlocked ? ` behind ${fmtNum(sum.heads)} head(s), longest wait ${ms(sum.longest_wait_ms) || '0s'}` : '')),
    `; sessions ${fmtNum(sum.sessions)}, requests ${fmtNum(sum.requests)}; `,
    el('span', { class: pending ? 'warn' : '' }, `memory grants pending ${fmtNum(pending)}`),
    `; snapshot ${fmtTime(sum.snapshot_at)} (the server's clock ${fmtTime(sum.server_utc)}), read in ${fmtNum(sum.read_ms)} ms from `, src));
  const tree = treeRows(rows, heads);
  const noHead = rows.filter(r => r.chain_note != null);
  if (tree.length || noHead.length) {
    box.append(el('h3', {}, 'Blocking chains ', whatIsThis(chainsNote, 'Blocking chains')), grid(tree, treeCols, 'No session was blocked behind a head in this snapshot.'));
    if (noHead.length) box.append(el('p', { class: 'meta' }, `${noHead.length} blocked row(s) without a head `, whatIsThis(noHeadNote, 'Blocked rows without a head')));
  }
  const text = (k: string) => (r: Row) => String(r[k] ?? '');
  const inChain = (r: Row) => r.head_session_id != null || r.chain_note != null || Number(r.blocking_session_id) > 0;
  box.append(el('h3', {}, 'Sessions and requests ', whatIsThis(sessionsNote, 'Sessions and requests')), foldedGrid({
    store: 'pgvigil.running.mssql', rows, cols, empty: 'Nothing ran and no transaction was open at this snapshot.',
    blocked: nBlocked, inChain, waiting: r => Number(r.blocking_session_id) > 0,
    age: r => r.elapsed_ms == null ? null : Math.floor(Number(r.elapsed_ms) / 1000), ageLabel: 'longest running for',
    groups: [['database', text('database_name')], ['login', text('login_name')], ['program', text('program_name')], ['status', text('status')], ['wait', text('wait_type')]],
  }));
  return box;
}

export async function mssqlRunningView(ctx: Ctx): Promise<HTMLElement> {
  // at= (the fleet page's row): the snapshot at or before that time; when it is older than the range, the hour up to it
  let win = window_(ctx);
  const at = ctx.at && !isNaN(Date.parse(ctx.at)) ? ctx.at : undefined;
  const widened = !!at && (Date.parse(at) <= Date.parse(win.from) || Date.parse(at) > Date.parse(win.to));
  if (at && widened) win = { from: new Date(Date.parse(at) - 3600000).toISOString(), to: new Date(Date.parse(at) + 1000).toISOString() };
  const d = await get<RunningData>('mssql/running', { instance: ctx.instance, ...win, at });
  const sec = el('section', {}, el('h2', {}, `Running queries (${widened ? 'the hour up to ' + fmtTime(at) : rangeLabel(ctx)})`));
  const st = rowsOf(d.state)[0];
  if (st && st.status !== 'ok') sec.append(el('p', { class: 'meta' }, `The mssql_requests collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.`));
  const snaps = rowsOf(d.snapshots).reverse();   // oldest first: the slider runs left to right in time
  // the stop the page opens on: the newest, or with at= the newest at or before it (the one the API returned)
  let start = snaps.length - 1;
  if (at) { start = -1; snaps.forEach((s, i) => { if (Date.parse(String(s.snapshot_at)) <= Date.parse(at)) start = i; }); }
  const holder = el('div');
  if (snaps.length > 1 && start >= 0) {
    const slider = el('input', { type: 'range', id: 'mssql-snap', min: '0', max: String(snaps.length - 1), step: '1', value: String(start) });
    const out = el('output', { for: 'mssql-snap' });
    const say = () => {
      const s = snaps[Number(slider.value)];
      const text = `${fmtTime(s.snapshot_at)}: ${fmtNum(s.sessions)} session(s), ${fmtNum(s.blocked)} blocked`;
      out.textContent = ' ' + text;
      slider.setAttribute('aria-valuetext', text);
    };
    let seq = 0;
    const load = async () => {
      say();
      const mine = ++seq;
      try {
        const pick = snaps[Number(slider.value)].snapshot_at;
        const one = await get<RunningData>('mssql/running', { instance: ctx.instance, ...win, at: String(pick) });
        if (mine === seq) holder.replaceChildren(body({ ...one, snapshots: d.snapshots }, pick));
      } catch (e) { if (mine === seq) holder.replaceChildren(errorBox(e)); }
    };
    const step = (by: number) => { slider.value = String(Math.min(snaps.length - 1, Math.max(0, Number(slider.value) + by))); void load(); };
    const prev = el('button', { type: 'button' }, 'Earlier'), next = el('button', { type: 'button' }, 'Later'), last = el('button', { type: 'button' }, 'Latest');
    prev.addEventListener('click', () => step(-1));
    next.addEventListener('click', () => step(1));
    last.addEventListener('click', () => step(snaps.length));
    slider.addEventListener('input', say);
    slider.addEventListener('change', () => void load());
    say();
    sec.append(el('p', { class: 'range' }, el('label', { for: 'mssql-snap' }, `Snapshot (${snaps.length} kept in the range${isLive(ctx) && !at ? '' : ', history'}): `),
      prev, ' ', slider, ' ', next, ' ', last, out));
  }
  holder.append(body(d, start >= 0 && snaps.length ? snaps[start].snapshot_at : at ? null : undefined));   // at= before the first kept snapshot: none to show
  sec.append(holder);
  return sec;
}
