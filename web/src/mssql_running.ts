// The SQL Server Running queries tab (task 96): one snapshot of what ran on the server (a session that runs a
// request, holds an open transaction or blocks another), a slider over the kept minutes of the range, and the
// blocking chains of the snapshot drawn as a tree with the head first. Data from /api/mssql/running; the route
// and the tab's entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, isLive, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

interface RunningData { state: Table | null; snapshots: Table | null; rows: Table | null; blocking: Table | null }

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

const cols: Col[] = [
  { key: 'session_id', label: 'session', num: true, fmt: v => String(v) },
  { key: 'status', fmt: statusCell },
  { key: 'command' },
  { key: 'wait_type', label: 'waiting on', fmt: waitCell },
  { key: 'wait_resource', label: 'wait resource' },
  { key: 'blocking_session_id', label: 'blocked by', num: true, fmt: v => Number(v) ? String(v) : '' },
  { key: 'head_session_id', label: 'chain head', num: true, fmt: (v, r) => v == null ? String(r.chain_note ?? '') : Number(r.chain_depth) === 0 ? badge('head', 'crit') : String(v) },
  { key: 'database_name', label: 'database' }, { key: 'login_name', label: 'login' }, { key: 'host_name', label: 'host' },
  { key: 'program_name', label: 'program' },
  { key: 'elapsed_ms', label: 'running for', num: true, fmt: ms },
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
  { key: 'tran_age_ms', label: 'transaction open for', num: true, fmt: ms },
  { key: 'tran_log_bytes', label: 'log written', num: true, fmt: v => v == null ? '' : fmtBytes(v) },
  { key: 'transaction_id', label: 'transaction id', fmt: v => v == null ? '' : String(v) },
  { key: 'isolation_level', label: 'isolation' },
  { key: 'session_waits', label: 'the session\'s largest waits (time, count)', fmt: sessionWaits },
  { key: 'statement', label: 'statement (the last batch, on a sleeping row)', wide: true },
  { key: 'query_hash', label: 'query hash' }, { key: 'query_plan_hash', label: 'plan hash' },
  { key: 'sql_handle', label: 'sql handle', wide: true }, { key: 'plan_handle', label: 'plan handle', wide: true },
];

const treeCols: Col[] = [
  { key: 'session_id', label: 'session', fmt: (v, r) => el('span', { style: `padding-left:${Number(r.tree_depth) * 1.2}em` }, (Number(r.tree_depth) > 0 ? '└ ' : '') + String(v)) },
  { key: 'tree_role', label: 'role', fmt: v => v === 'head' ? badge('head', 'crit') : String(v ?? '') },
  { key: 'victims', label: 'blocks', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : '' },
  { key: 'status', fmt: statusCell },
  { key: 'wait_type', label: 'waiting on', fmt: waitCell },
  { key: 'wait_resource', label: 'wait resource' },
  { key: 'tran_age_ms', label: 'transaction open for', num: true, fmt: ms },
  { key: 'database_name', label: 'database' }, { key: 'login_name', label: 'login' }, { key: 'program_name', label: 'program' },
  { key: 'statement', label: 'statement (the last batch, on a sleeping row)', wide: true },
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

function body(d: RunningData): HTMLElement {
  const box = el('div');
  const rows = rowsOf(d.rows), heads = rowsOf(d.blocking);
  const snaps = rowsOf(d.snapshots);
  const at = rows[0]?.snapshot_at ?? heads[0]?.snapshot_at;
  const sum = snaps.find(s => s.snapshot_at === at) ?? snaps[0];
  if (!sum) { box.append(el('p', { class: 'empty' }, 'No snapshot in this window.')); return box; }
  const shown = at ?? sum.snapshot_at;
  box.append(el('p', { class: 'meta' }, `Snapshot of ${fmtTime(shown)} (the server's own clock: ${fmtTime(sum.server_utc)}), read in ${fmtNum(sum.read_ms)} ms. `
    + `Source: ${sum.source === 'sp_whoisactive' ? 'sp_WhoIsActive, called where the server\'s DBA installed it' : 'the DMVs'} (${String(sum.source_note ?? '')}).`));
  box.append(el('div', { class: 'tiles' },
    tile('sessions listed', fmtNum(sum.sessions)),
    tile('requests running', fmtNum(sum.requests)),
    tile('sessions blocked', fmtNum(sum.blocked), Number(sum.blocked) ? 'warn' : 'ok'),
    tile('chain heads', fmtNum(sum.heads), Number(sum.heads) ? 'warn' : 'ok'),
    tile('longest wait behind a head', sum.longest_wait_ms == null ? '-' : ms(sum.longest_wait_ms), Number(sum.longest_wait_ms) > 300000 ? 'crit' : Number(sum.longest_wait_ms) > 30000 ? 'warn' : ''),
    tile('memory grants pending', fmtNum(sum.memory_grants_pending ?? 0), Number(sum.memory_grants_pending) ? 'warn' : 'ok')));
  box.append(el('h3', {}, 'Blocking chains'), el('p', { class: 'meta' },
    'A head blocks others and waits behind no session: the cause of its chain is its transaction and its last statement, not the object '
    + 'the others wait on. A sleeping head with an open transaction is an application that left its transaction open; the statement shown is its last batch.'),
    grid(treeRows(rows, heads), treeCols, 'No session was blocked in this snapshot.'));
  const noHead = rows.filter(r => r.chain_note != null);
  if (noHead.length) box.append(el('p', { class: 'meta' }, `${noHead.length} blocked row(s) have no head to name (a blocker that is not a session, or a cycle): see the "chain head" column below.`));
  box.append(el('h3', {}, 'Sessions and requests'), el('p', { class: 'meta' },
    'A session that runs a request, holds an open transaction or blocks another. On a parallel request the CPU, reads and writes are '
    + 'marked "(coordinator)": the server keeps them for the coordinator task alone, and the sums over the request\'s tasks are beside them.'),
    grid(rows, cols, 'Nothing ran and no transaction was open at this snapshot.'));
  return box;
}

export async function mssqlRunningView(ctx: Ctx): Promise<HTMLElement> {
  const win = window_(ctx);
  const d = await get<RunningData>('mssql/running', { instance: ctx.instance, ...win });
  const sec = el('section', {}, el('h2', {}, `Running queries (${rangeLabel(ctx)})`));
  const st = rowsOf(d.state)[0];
  if (st && st.status !== 'ok') sec.append(el('p', { class: 'meta' }, `The mssql_requests collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.`));
  const snaps = rowsOf(d.snapshots).reverse();   // oldest first: the slider runs left to right in time
  const holder = el('div');
  if (snaps.length > 1) {
    const slider = el('input', { type: 'range', id: 'mssql-snap', min: '0', max: String(snaps.length - 1), step: '1', value: String(snaps.length - 1) });
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
        const one = await get<RunningData>('mssql/running', { instance: ctx.instance, ...win, at: String(snaps[Number(slider.value)].snapshot_at) });
        if (mine === seq) holder.replaceChildren(body({ ...one, snapshots: d.snapshots }));
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
    sec.append(el('p', { class: 'range' }, el('label', { for: 'mssql-snap' }, `Snapshot (${snaps.length} kept in the range${isLive(ctx) ? '' : ', history'}): `),
      prev, ' ', slider, ' ', next, ' ', last, out));
  }
  holder.append(body(d));
  sec.append(holder);
  return sec;
}
