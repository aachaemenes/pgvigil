// The Running queries tab of a PostgreSQL instance, in DBA Dash's shape: one snapshot of pg_stat_activity, ONE LINE
// per session (a statement shows its first 80 characters and opens whole in the shared viewer), the snapshot's time
// between Earlier and Later buttons, a 'Blocked (n)' filter, a group-by that folds the grid into counted groups,
// and the blocking chains as an indented tree with the head first. Cancel and Terminate go through the actions
// door, the plan link opens the statement's plans, and the window half (what ran at least N seconds over the range)
// stays below, under the blocking history of the range (blocking_history.ts: the chains of the samples with their
// denominator, and who pinned the xmin horizon). Data: /api/activity (the snapshot), /api/running/snapshots (the
// steps) and /api/blocking/history.
//
// Behind a PgBouncer (task 128; an instance with a pooler read, /api/pooler/conns): the pooler read paired with the
// snapshot marks each session that is a pooler server ('pooler' column: which client it serves), and the status line
// counts the clients that wait INSIDE the pooler for a server, which pg_stat_activity cannot list, with the heads their
// pools' servers wait behind. The full trace is on the Pooler tab.
//
// The chain rules (the same as pgvigil.blocking_chains and the fleet page):
//   blocked     a session whose wait_event_type is Lock and that names a blocker; no other wait is blocking
//   head        a session a blocked one names that is not blocked itself: it holds and does not wait. The cause of
//               its chain is its transaction and its last statement, never the object the others wait on
//   blocks      the sessions behind a session at any depth (DBA Dash's 'blocked count recursive')
import { Activity, get, Row, rowsOf, Table } from './api';
import { actionsCol, actionsState } from './actions';
import { planLink } from './plan';
import { Ctx, href, isLive, window_ } from './router';
import { badge, Col, el, fmtNum, fmtSecs, fmtTime, grid } from './ui';
import { longRunsSection } from './window';
import { pgBlockingHistory } from './blocking_history';
import { sqlCell, whatIsThis } from './sqlview';
import { poolerConns, poolerKnown, STALE_MS } from './pooler';
import { fromInput, toInput } from './tz';

const TAB = 'activity';
const idleNote = 'This session is idle in a transaction: the text is the LAST statement it ran, not one running now.';
const headNote = 'A head blocks others and is not blocked itself. The cause of its chain is its transaction and its last statement, not the object the others wait on.';

// ---- chains

const pidsOf = (v: unknown): number[] => Array.isArray(v) ? v.map(Number).filter(n => n > 0)
  : typeof v === 'string' ? v.replace(/[{}]/g, '').split(',').map(Number).filter(n => n > 0) : [];
const isBlocked = (r: Row) => r.wait_event_type === 'Lock' && pidsOf(r.blocking_pids).length > 0;
const isIdle = (r: Row) => String(r.state ?? '').startsWith('idle');

export interface Chains {
  heads: number[];                 // the head with the most sessions behind it first
  behind: Map<number, number>;     // pid -> the sessions behind it, at any depth
  headOf: Map<number, number>;     // a blocked pid -> its chain's head (none: a cycle)
  tree: Row[];                     // the chains as rows: each head, then the sessions behind it, depth first
  blocked: number;
}

// chainsOf builds the chains of one snapshot from its session rows. heads: the stored chain rows (blocking_chains),
// read only for a head whose own row the sample does not hold (an autovacuum worker, a session gone by the read).
export function chainsOf(sessions: Row[], stored: Row[] = []): Chains {
  const byPid = new Map<number, Row>();
  for (const r of sessions) byPid.set(Number(r.pid), r);
  const kids = new Map<number, number[]>();
  for (const r of sessions) {
    if (!isBlocked(r)) continue;
    for (const b of pidsOf(r.blocking_pids)) {
      if (b === Number(r.pid)) continue;
      if (!kids.has(b)) kids.set(b, []);
      kids.get(b)!.push(Number(r.pid));
    }
  }
  const blockedPid = (p: number) => { const r = byPid.get(p); return !!r && isBlocked(r); };
  const reach = (p: number, seen: Set<number>) => { for (const k of kids.get(p) ?? []) if (!seen.has(k)) { seen.add(k); reach(k, seen); } return seen; };
  const behind = new Map<number, number>();
  for (const p of kids.keys()) { const s = reach(p, new Set<number>()); s.delete(p); behind.set(p, s.size); }
  const heads = [...kids.keys()].filter(p => !blockedPid(p)).sort((a, b) => (behind.get(b) ?? 0) - (behind.get(a) ?? 0) || a - b);
  const headOf = new Map<number, number>();
  const tree: Row[] = [];
  const placed = new Set<number>();
  const age = (p: number) => Number(byPid.get(p)?.query_secs ?? 0);
  const walk = (p: number, depth: number, head: number, seen: Set<number>) => {
    for (const k of [...(kids.get(p) ?? [])].sort((a, b) => age(b) - age(a) || a - b)) {
      if (seen.has(k)) continue;
      seen.add(k); placed.add(k);
      if (!headOf.has(k)) headOf.set(k, head);
      tree.push({ ...byPid.get(k)!, _depth: depth, _role: kids.has(k) ? 'blocked, and blocks' : 'blocked', _behind: behind.get(k) ?? 0 });
      walk(k, depth + 1, head, seen);
    }
  };
  for (const h of heads) {
    const own = byPid.get(h);
    const st = stored.find(c => Number(c.head_pid) === h);
    tree.push(own ? { ...own, _depth: 0, _role: 'head', _behind: behind.get(h) ?? 0 }
      : { pid: h, state: st?.head_state ?? 'not in the sample', backend_type: st?.head_backend_type, query: st?.head_query, _depth: 0, _role: 'head', _behind: behind.get(h) ?? 0, _absent: true });
    walk(h, 1, h, new Set([h]));
  }
  // blocked sessions no head leads to wait on each other: a deadlock the server has not broken yet
  for (const r of sessions) {
    if (isBlocked(r) && !placed.has(Number(r.pid))) tree.push({ ...r, _depth: 0, _role: 'in a cycle (no head)', _behind: behind.get(Number(r.pid)) ?? 0 });
  }
  return { heads, behind, headOf, tree, blocked: sessions.filter(isBlocked).length };
}

// ---- the folded grid (both engines' pages)

export interface Fold {
  store: string;                              // the sessionStorage key the filter and the group live under
  rows: Row[];
  cols: Col[];
  empty: string;
  blocked: number;                            // the n of 'Blocked (n)'
  inChain: (r: Row) => boolean;               // a blocked session or one that blocks: what the filter keeps
  waiting: (r: Row) => boolean;               // a blocked session (counted per group)
  age: (r: Row) => number | null;             // seconds, the longest per group
  ageLabel: string;
  groups: [string, (r: Row) => string][];     // label, the group a row falls in
}

interface FoldState { blocked: boolean; by: string; pick: string | null }

function loadState(key: string): FoldState {
  try {
    const p = JSON.parse(sessionStorage.getItem(key) ?? 'null') as Partial<FoldState> | null;
    if (p) return { blocked: p.blocked === true, by: typeof p.by === 'string' ? p.by : '', pick: typeof p.pick === 'string' ? p.pick : null };
  } catch { /* private window, or a value of an older build */ }
  return { blocked: false, by: '', pick: null };
}

// foldedGrid: a toolbar ('Blocked (n)', 'Group by') over a grid. With a group chosen the grid folds into one counted
// row per group; a group's name opens its sessions, 'All groups' folds them again. The choice survives the page's
// own 30-second redraw (sessionStorage).
export function foldedGrid(f: Fold): HTMLElement {
  const st = loadState(f.store);
  if (st.by && !f.groups.some(g => g[0] === st.by)) { st.by = ''; st.pick = null; }
  const save = () => { try { sessionStorage.setItem(f.store, JSON.stringify(st)); } catch { /* private window */ } };
  const holder = el('div');
  const said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const blockedBtn = el('button', { type: 'button', class: 'toggle', 'aria-pressed': String(st.blocked) }, `Blocked (${f.blocked})`);
  blockedBtn.title = 'Only the sessions of a blocking chain: the blocked ones and the ones that block them';
  const sel = el('select', { 'aria-label': 'group by' }, el('option', { value: '' }, 'no grouping'),
    ...f.groups.map(g => el('option', g[0] === st.by ? { value: g[0], selected: 'selected' } : { value: g[0] }, g[0])));
  const all = el('button', { type: 'button', class: 'link' }, 'All groups');
  const draw = () => {
    const base = st.blocked ? f.rows.filter(f.inChain) : f.rows;
    const keyOf = f.groups.find(g => g[0] === st.by)?.[1];
    if (!keyOf) {
      said.replaceChildren(`${base.length} of ${f.rows.length} session(s).`);
      holder.replaceChildren(grid(base, f.cols, st.blocked ? 'No session is blocked in this snapshot.' : f.empty));
      return;
    }
    if (st.pick != null && !base.some(r => keyOf(r) === st.pick)) st.pick = null;   // the picked group left the snapshot
    if (st.pick != null) {
      const rows = base.filter(r => keyOf(r) === st.pick);
      said.replaceChildren(`${st.by} ${st.pick || '(none)'}: ${rows.length} session(s). `, all);
      holder.replaceChildren(grid(rows, f.cols, f.empty));
      return;
    }
    const by = new Map<string, Row>();
    for (const r of base) {
      const k = keyOf(r);
      const g = by.get(k) ?? { group: k, sessions: 0, blocked: 0, longest: null };
      g.sessions = Number(g.sessions) + 1;
      if (f.waiting(r)) g.blocked = Number(g.blocked) + 1;
      const a = f.age(r);
      if (a != null && (g.longest == null || a > Number(g.longest))) g.longest = a;
      by.set(k, g);
    }
    const groups = [...by.values()].sort((a, b) => Number(b.sessions) - Number(a.sessions) || String(a.group).localeCompare(String(b.group)));
    said.replaceChildren(`${groups.length} group(s) by ${st.by}, ${base.length} session(s).`);
    holder.replaceChildren(grid(groups, [
      { key: 'group', label: st.by, fmt: v => {
        const b = el('button', { type: 'button', class: 'link', title: 'Show the sessions of this group' }, String(v) || '(none)');
        b.addEventListener('click', () => { st.pick = String(v); save(); draw(); all.focus(); });
        return b;
      } },
      { key: 'sessions', num: true },
      { key: 'blocked', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'crit') : '0' },
      { key: 'longest', label: f.ageLabel, num: true, fmt: fmtSecs },
    ], st.blocked ? 'No session is blocked in this snapshot.' : f.empty));
  };
  blockedBtn.addEventListener('click', () => { st.blocked = !st.blocked; blockedBtn.setAttribute('aria-pressed', String(st.blocked)); save(); draw(); });
  sel.addEventListener('change', () => { st.by = sel.value; st.pick = null; save(); draw(); });
  all.addEventListener('click', () => { st.pick = null; save(); draw(); sel.focus(); });
  draw();
  return el('div', { class: 'folded' }, el('div', { class: 'seg' }, blockedBtn, el('label', {}, 'Group by ', sel), said), holder);
}

// ---- the snapshot row: Earlier, the time, Later, Latest, and the picker

interface Steps { shown?: unknown; earlier?: unknown; later?: unknown; latest?: unknown }

function snapshotBar(ctx: Ctx, at: string | undefined, steps: Steps): HTMLElement {
  const go = (t?: string) => { location.hash = href(ctx, { tab: TAB, at: t }); };
  const step = (label: string, to: unknown, title: string) => {
    const b = el('button', { type: 'button', title }, label);
    if (to == null) b.disabled = true; else b.addEventListener('click', () => go(String(to)));
    return b;
  };
  const input = el('input', { type: 'datetime-local', step: '1', 'aria-label': 'snapshot at or before' });
  if (at) input.value = toInput(new Date(at), true);
  // the picker has whole seconds and snapshots have fractions: take the end of the chosen second
  input.addEventListener('change', () => { const t = input.value ? fromInput(input.value) : undefined; go(t && !isNaN(t.getTime()) ? new Date(t.getTime() + 999).toISOString() : undefined); });
  // under a custom range the page shows the range's end: Latest returns to a range that follows now
  const latest = el('button', { type: 'button', title: isLive(ctx) ? 'The newest snapshot' : 'The newest snapshot (switches the range to the last hour)' }, 'Latest');
  latest.addEventListener('click', () => {
    location.hash = isLive(ctx) ? href(ctx, { tab: TAB, at: undefined }) : href(ctx, { tab: TAB, at: undefined, range: { preset: '1h' } });
  });
  const newest = steps.shown != null && steps.shown === steps.latest;
  const hist = ctx.at ? 'history: auto refresh off' : at ? 'the end of the custom range: auto refresh off' : '';
  return el('div', { class: 'picker' },
    step('Earlier', steps.earlier, 'The snapshot before this one'), ' ',
    el('b', { class: 'snap-time' }, steps.shown == null ? 'no snapshot' : 'Snapshot ' + fmtTime(steps.shown)), ' ',
    step('Later', steps.later, 'The snapshot after this one'), ' ', latest,
    el('label', {}, ' at or before ', input),
    hist ? el('span', { class: 'meta' }, ` (${hist}${newest ? '; this is the newest' : ''})`) : null);
}

// ---- the page

export async function runningView(ctx: Ctx): Promise<HTMLElement> {
  if (!ctx.instance) return el('p', { class: 'empty' }, 'Pick an instance in the tree on the left.');
  const at = ctx.at ?? (isLive(ctx) ? undefined : window_(ctx).to);
  const [a, act] = await Promise.all([get<Activity>('activity', { instance: ctx.instance, at }), actionsState(ctx.instance)]);
  // the steps around the snapshot the activity read chose, read after it (two parallel reads of 'the newest' can
  // straddle a new minute's snapshot); a convenience: a server without the endpoint leaves the buttons off
  const stepsT = a.snapshot_at
    ? await get<{ steps: Table | null }>('running/snapshots', { instance: ctx.instance, at: a.snapshot_at }).catch(() => ({ steps: null }))
    : { steps: null };
  const steps: Steps = rowsOf(stepsT.steps)[0] ?? { shown: a.snapshot_at };
  // the pooler read of the same minute, where the instance has a pooler (task 128); a failed read leaves the page as it was
  // only a read within two minutes of the snapshot: an older one says nothing of these sessions (pids are reused)
  const pcAny = a.snapshot_at && await poolerKnown(ctx.instance).catch(() => false)
    ? await poolerConns(ctx.instance, String(a.snapshot_at)).catch(() => null) : null;
  const readAt = rowsOf(pcAny?.read ?? null)[0]?.read_at;
  const pc = readAt != null && Math.abs(new Date(String(readAt)).getTime() - new Date(String(a.snapshot_at)).getTime()) <= STALE_MS ? pcAny : null;
  const viaPooler = new Map<number, Row>();
  for (const r of rowsOf(pc?.servers ?? null)) if (r.backend_pid != null && r.backend_match === 'matched') viaPooler.set(Number(r.backend_pid), r);
  const sec = el('section', {}, el('h2', {}, 'Running queries'), snapshotBar(ctx, at, steps));
  if (!a.snapshot_at) { sec.append(el('p', { class: 'empty' }, 'No activity snapshot for this instance yet.')); return sec; }
  const sum = rowsOf(a.summary)[0] ?? {};
  const sessions = rowsOf(a.sessions);
  const ch = chainsOf(sessions, rowsOf(a.chains));
  const maxOf = (rows: Row[], key: string) => rows.reduce<number | null>((m, r) => r[key] == null ? m : Math.max(m ?? 0, Number(r[key])), null);
  const longestWait = maxOf(sessions.filter(isBlocked), 'query_secs');
  const longestStmt = maxOf(sessions.filter(r => r.state === 'active' && (r.backend_type ?? 'client backend') === 'client backend'), 'query_secs');
  const oldestTxn = maxOf(sessions, 'xact_secs');
  // the status line of totals (DBA Dash's 'Blocked Sessions: 2, Blocked Wait Time ...')
  sec.append(el('p', { class: 'meta counts running-status' },
    el('span', { class: ch.blocked ? 'crit' : '' }, `Blocked sessions: ${fmtNum(ch.blocked)}` + (ch.blocked ? ` behind ${ch.heads.length} head(s), longest blocked ${fmtSecs(longestWait) || '0s'}` : '')),
    `; sessions ${fmtNum(sum.total)}, active ${fmtNum(sum.active)}, idle in transaction ${fmtNum(sum.idle_in_txn)}`,
    `; longest statement ${longestStmt == null ? '-' : fmtSecs(longestStmt)}, oldest transaction ${oldestTxn == null ? '-' : fmtSecs(oldestTxn)}`));
  if (pc && rowsOf(pc.read).length) {
    const trace = rowsOf(pc.trace);
    const waiting = trace.reduce((n, t) => n + Number(t.clients_waiting ?? 0), 0);
    const longest = trace.reduce((m, t) => Math.max(m, Number(t.longest_wait_us ?? 0)), 0);
    const heads = [...new Set(rowsOf(pc.heads).map(h => String(h.head_pid)))];
    sec.append(el('p', { class: 'meta pooler-status' },
      el('span', { class: waiting ? 'warn' : '' }, `Pooler: ${fmtNum(waiting)} client(s) waiting in PgBouncer for a server`),
      waiting ? ` (longest ${fmtSecs(longest / 1e6)}; not in pg_stat_activity)` : '',
      heads.length ? `; its servers wait behind head pid ${heads.join(', ')}` : '',
      `; ${fmtNum(viaPooler.size)} session(s) below are pooler servers (read ${fmtTime(rowsOf(pc.read)[0].read_at)}). `,
      el('a', { href: href(ctx, { tab: 'pooler', at: undefined }) }, 'The trace on the Pooler tab')));
  }
  const poolerCell = (_v: unknown, r: Row) => {
    const s = viaPooler.get(Number(r.pid));
    if (!s) return '';
    const who = s.paired_application ?? s.paired_addr;
    return el('span', { title: `PgBouncer server connection (remote_pid ${String(r.pid)}) of pool ${String(s.database)}/${String(s.user)}` },
      who == null ? 'pooler server (no client paired)' : `pooler: ${String(who)}`);
  };

  const after = () => { location.hash = href(ctx, { tab: TAB, at: undefined }); };
  const actions = actionsCol(ctx, act, after);
  const waitCell = (_v: unknown, r: Row) => r.wait_event_type == null ? ''
    : r.wait_event_type === 'Lock' ? badge(`Lock: ${String(r.wait_event ?? '')}`, 'warn') : `${String(r.wait_event_type)}: ${String(r.wait_event ?? '')}`;
  const stmtCell = (v: unknown, r: Row) => sqlCell(v, { heading: `pid ${String(r.pid)}: ${isIdle(r) ? 'last statement' : 'statement'}`, title: isIdle(r) ? idleNote : undefined });
  const planCell = (_v: unknown, r: Row) => r.query ? planLink(ctx.instance!, { stmt: r.query, db: r.datname }) : '';

  if (ch.tree.length) {
    const treeCols: Col[] = [
      { key: 'pid', fmt: (v, r) => el('span', { style: `padding-left:${Number(r._depth) * 1.2}em` }, (Number(r._depth) > 0 ? '└ ' : '') + String(v)) },
      { key: '_role', label: 'role', fmt: v => v === 'head' ? badge('head', 'crit') : String(v ?? '') },
      { key: '_behind', label: 'blocks', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : '' },
      { key: 'state', fmt: (v, r) => r._absent ? el('span', { class: 'meta', title: 'The head\'s own row is not in this sample (a background worker, or a session gone by the read).' }, String(v ?? '')) : String(v ?? '') },
      { key: 'wait_event', label: 'wait', fmt: waitCell },
      { key: 'query_secs', label: 'query age', num: true, fmt: fmtSecs },
      { key: 'xact_secs', label: 'transaction age', num: true, fmt: fmtSecs },
      { key: 'datname', label: 'database' }, { key: 'usename', label: 'user' }, { key: 'application_name', label: 'application' },
      ...(viaPooler.size ? [{ key: '_pooler', label: 'pooler', fmt: poolerCell }] : []),
      // the head's statement is its LAST statement when it is idle in transaction: the cell's title says so
      { key: 'query', label: 'statement', fmt: stmtCell },
      { key: 'plan_link', label: 'plan', fmt: planCell },
      actions,
    ];
    const g = grid(ch.tree, treeCols);
    g.classList.add('chain-tree');
    sec.append(el('h3', {}, 'Blocking chains ', whatIsThis(headNote, 'Blocking chains')), g);
  }

  const rows = sessions.map(r => {
    const pid = Number(r.pid), head = ch.heads.includes(pid);
    return { ...r, _blockedby: isBlocked(r) ? pidsOf(r.blocking_pids).join(', ') : '',   // a stale blocker of a non-Lock wait is no blocker
      _head: head ? 'head' : ch.headOf.has(pid) ? String(ch.headOf.get(pid)) : isBlocked(r) ? 'cycle' : '',
      _behind: ch.behind.get(pid) ?? 0, _wait: r.wait_event_type == null ? '' : `${String(r.wait_event_type)}: ${String(r.wait_event ?? '')}` };
  });
  const cols: Col[] = [
    { key: 'pid', num: true, fmt: v => String(v) },
    { key: 'state' },
    { key: '_wait', label: 'wait', fmt: waitCell },
    { key: '_blockedby', label: 'blocked by' },
    { key: '_head', label: 'chain head', fmt: v => v === 'head' ? badge('head', 'crit') : v === 'cycle' ? el('span', { title: 'Blocked sessions that wait on each other: no head to name' }, 'cycle') : v ? `pid ${String(v)}` : '' },
    { key: '_behind', label: 'blocks', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : '' },
    { key: 'query_secs', label: 'query age', num: true, fmt: fmtSecs },
    { key: 'xact_secs', label: 'transaction age', num: true, fmt: fmtSecs },
    { key: 'backend_xmin_age', label: 'xmin age', num: true },
    { key: 'datname', label: 'database' },
    { key: 'usename', label: 'user' },
    { key: 'application_name', label: 'application' },
    { key: 'client' },
    ...(viaPooler.size ? [{ key: '_pooler', label: 'pooler', fmt: poolerCell }] : []),
    { key: 'query', label: 'statement', fmt: stmtCell },
    { key: 'plan_link', label: 'plan', fmt: planCell },
    actions,
  ];
  const text = (k: string) => (r: Row) => String(r[k] ?? '');
  sec.append(el('h3', {}, 'Sessions'), foldedGrid({
    store: `pgvigil.running.pg.${ctx.instance}`, rows, cols, empty: 'No active or idle-in-transaction sessions in this snapshot.',
    blocked: ch.blocked, inChain: r => r._head !== '', waiting: isBlocked,
    age: r => r.query_secs == null ? null : Number(r.query_secs), ageLabel: 'longest query age',
    groups: [['database', text('datname')], ['user', text('usename')], ['application', text('application_name')], ['state', text('state')], ['wait', text('_wait')]],
  }));
  // the chains over the range with their denominator, and who pinned the xmin horizon (task 120)
  const [hist, longRuns] = await Promise.all([pgBlockingHistory(ctx), longRunsSection(ctx)]);
  sec.append(hist, longRuns);
  return sec;
}
