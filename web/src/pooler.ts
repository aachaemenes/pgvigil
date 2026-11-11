// The Pooler tab of an instance (phase 3 wave F, task 62): a PgBouncer in front of the instance, read every minute
// through its admin console (the instance's pgbouncer: DSN, a stats_users login, SHOW only): the pools as last read
// (clients active and waiting, servers active and idle, the longest wait, the pool's size), the clients and servers
// over the window, the per-database rates, and SHOW DATABASES and SHOW CONFIG as read. An instance without the DSN
// has no pooler state: hasPooler(ctx) is false and the shell shows no Pooler tab. Data from /api/pooler; the lead
// wires the tab and the check (router.ts, main.ts).
//
// The pooler traced (task 128): SHOW CLIENTS and SHOW SERVERS as read (/api/pooler/conns). A client that waits inside
// PgBouncer is invisible to pg_stat_activity; the trace names the pool it waits on, that pool's servers, the backend
// each server runs (its remote_pid, joined to the activity snapshot of the same minute) and, where those backends wait
// on a lock, the chain's head: the session whose transaction holds them, with a link to it on Running queries.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, rangeLabel, window_ } from './router';
import { findingCols } from './memory';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';
import { sqlCell } from './sqlview';

type PoolerParts = 'state' | 'pools' | 'series' | 'stats' | 'findings';

const ms = (v: unknown) => v == null ? '' : Number(v) >= 1000 ? fmtNum(Math.round(Number(v) / 100) / 10) + ' s' : fmtNum(Math.round(Number(v))) + ' ms';
const us = (v: unknown) => v == null ? '' : ms(Number(v) / 1000);
const yes = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';

const poolCols: Col[] = [
  { key: 'database' }, { key: 'user' },
  { key: 'cl_active', label: 'clients active', num: true },
  { key: 'cl_waiting', label: 'clients waiting', num: true, cls: v => Number(v) > 0 ? 'warn' : '' },
  { key: 'sv_active', label: 'servers active', num: true },
  { key: 'sv_idle', label: 'servers idle', num: true },
  { key: 'sv_used', label: 'servers used', num: true },
  { key: 'pool_size', label: 'pool size', num: true },
  { key: 'pool_size_from', label: 'size set by', fmt: v => v === 'user' ? 'the user ([users])' : v === 'database' ? 'the database' : '' },
  { key: 'maxwait_ms', label: 'longest wait', num: true, fmt: ms },
  { key: 'pool_mode', label: 'mode' },
];

const statsCols: Col[] = [
  { key: 'database' },
  { key: 'query_rate', label: 'queries / s', num: true },
  { key: 'xact_rate', label: 'transactions / s', num: true },
  { key: 'avg_query_us', label: 'mean query time', num: true, fmt: us },
  { key: 'avg_wait_us', label: 'mean client wait', num: true, fmt: us },
  { key: 'total_query_count', label: 'queries (since start)', num: true },
  { key: 'total_xact_count', label: 'transactions (since start)', num: true },
];

const dbCols: Col[] = [
  { key: 'name', label: 'pooler database' }, { key: 'host' }, { key: 'port', num: true }, { key: 'database', label: 'server database' },
  { key: 'pool_size', label: 'pool size', num: true },
  { key: 'pool_size_from', label: 'size set by', fmt: v => v === 'user' ? 'the user ([users])' : v === 'database' ? 'the database' : '' }, { key: 'min_pool_size', label: 'min pool', num: true },
  { key: 'reserve_pool', label: 'reserve', num: true }, { key: 'pool_mode', label: 'mode' },
  { key: 'max_connections', label: 'max connections', num: true }, { key: 'current_connections', label: 'connections', num: true },
  { key: 'paused', fmt: yes }, { key: 'disabled', fmt: yes },
];

const confCols: Col[] = [{ key: 'key', label: 'setting' }, { key: 'value', wide: true }, { key: 'changeable', fmt: yes }];

// ---- the clients and servers (task 128)

export type ConnParts = 'read' | 'clients' | 'servers' | 'trace' | 'heads';

// poolerConns reads the clients, servers and trace of the pooler read nearest at (within two minutes, else the newest
// before it); null only when the server has no such endpoint (an older build): any other error is thrown.
export async function poolerConns(instance: number, at: string): Promise<Record<ConnParts, Table | null> | null> {
  try {
    return await get<Record<ConnParts, Table | null>>('pooler/conns', { instance, at });
  } catch (e) {
    if (e instanceof Error && e.message === 'no such endpoint') return null;
    throw e;
  }
}

// STALE_MS: a pooler read further than this from the page's time is not the pooler as it was then
export const STALE_MS = 120 * 1000;

const pids = (v: unknown): string => Array.isArray(v) ? v.join(', ') : typeof v === 'string' ? v.replace(/[{}]/g, '').split(',').join(', ') : '';
const waitUs = (v: unknown) => v == null ? '' : us(v);
const stateCell = (v: unknown) => String(v ?? '').startsWith('waiting') ? badge(String(v), 'warn') : String(v ?? '');
const roleCell = (v: unknown) => v === 'head' ? badge('head', 'crit') : v === 'blocked' ? badge('blocked', 'warn') : String(v ?? '');
const backendCell = (v: unknown, r: Row) => r.backend_pid == null ? ''
  : r.backend_match === 'another backend'
    ? el('span', { class: 'meta', title: 'This pid is a session of another login or database on this instance: the server connects elsewhere (a replica, another instance, a second pooler)' }, 'another backend')
    : r.backend_state == null
      ? el('span', { class: 'meta', title: 'Not in the activity snapshot: the backend was idle between transactions (only active and idle-in-transaction sessions are sampled), or it runs on another host' }, 'not in the sample')
      : String(v ?? '');
const waitCell = (_v: unknown, r: Row) => r.backend_wait_type == null ? ''
  : r.backend_wait_type === 'Lock' ? badge(`Lock: ${String(r.backend_wait ?? '')}`, 'warn') : `${String(r.backend_wait_type)}: ${String(r.backend_wait ?? '')}`;

function runningLink(ctx: Ctx, at: unknown, pid: unknown, r?: Row): HTMLElement | string {
  if (pid == null) return '';
  if (r && r.backend_match != null && r.backend_match !== 'matched') return String(pid);   // not a session of this instance's snapshot
  return el('a', { href: href(ctx, { tab: 'activity', at: at == null ? undefined : String(at) }), title: 'Open Running queries at the activity snapshot paired with this read' }, `pid ${String(pid)}`);
}

export function connSections(ctx: Ctx, d: Record<ConnParts, Table | null>): HTMLElement[] {
  const read = rowsOf(d.read)[0];
  if (!read) {
    return [el('h3', {}, 'Clients and servers (SHOW CLIENTS, SHOW SERVERS)'),
      el('p', { class: 'empty' }, 'Not read yet: the pooler\'s console refused SHOW CLIENTS or SHOW SERVERS, or no read of them is stored for this time.')];
  }
  const actAt = read.activity_at;
  const out: HTMLElement[] = [];
  const asOf = window_(ctx).to;
  const behind = new Date(asOf).getTime() - new Date(String(read.read_at)).getTime();
  if (behind > STALE_MS) {
    out.push(el('p', { class: 'meta' }, badge('stale', 'warn'), ` The newest read of the clients and servers is ${fmtSecs(behind / 1000)} older than the page's time `
      + `(${fmtTime(asOf)}): the pooler was not read since. What follows is the pooler as it was at ${fmtTime(read.read_at)}.`));
  }
  const pairing = actAt == null
    ? 'No activity snapshot within two minutes of this read: the servers\' backends are not joined.'
    : `Pooler read ${fmtTime(read.read_at)}, joined to the activity snapshot of ${fmtTime(actAt)}. In transaction mode which client a server serves can change between the two.`;

  // the trace: each pool with clients waiting or a server in a chain, then each head behind it
  const trace = rowsOf(d.trace), heads = rowsOf(d.heads);
  out.push(el('h3', {}, 'Trace: who the pooler\'s clients wait for'), el('p', { class: 'meta' }, pairing));
  if (!trace.length) {
    out.push(el('p', { class: 'empty' }, 'No client waits in the pooler and no server\'s backend is in a blocking chain at this read.'));
  } else {
    const lines = el('ul', { class: 'pooler-trace' });
    for (const t of trace) {
      const busy = `${fmtNum(t.servers_active)} of ${fmtNum(t.servers)} server(s) busy`;
      const blocked = Number(t.servers_blocked) > 0 ? `, ${fmtNum(t.servers_blocked)} of them blocked on a lock` : '';
      const hp = pids(t.head_pids), own = pids(t.heading_pids);
      lines.append(el('li', {},
        el('b', {}, `${String(t.database)}/${String(t.user)}`), ': ',
        Number(t.clients_waiting) > 0 ? badge(`${fmtNum(t.clients_waiting)} client(s) waiting`, 'warn') : '0 clients waiting',
        Number(t.clients_waiting) > 0 ? ` (longest ${us(t.longest_wait_us)})` : '',
        `; ${busy}${blocked}`,
        hp ? `; behind head pid ${hp}` : Number(t.clients_waiting) > 0 ? '; no server\'s backend waits on a lock: the pool is busy, not blocked' : '',
        own ? `; its own server (pid ${own}) heads a chain` : '',
        Number(t.servers_elsewhere) > 0 ? `; ${fmtNum(t.servers_elsewhere)} server(s) whose pid is another login's session here (not this instance's backends)` : ''));
    }
    out.push(lines);
    if (heads.length) {
      out.push(grid(heads, [
        { key: 'head_pid', label: 'head', fmt: v => runningLink(ctx, actAt, v) },
        { key: 'head_state', label: 'head state', fmt: v => String(v ?? '') === 'idle in transaction' ? badge(String(v), 'crit') : String(v ?? 'not in the sample') },
        { key: 'head_application', label: 'head application' },
        { key: 'head_via_pooler', label: 'head through the pooler', fmt: (v, r) => v === true ? `yes: serves ${String(r.head_client_application ?? 'a client')}` : v === false ? 'no (a direct session)' : '' },
        { key: 'servers_behind', label: 'pooler servers blocked behind it', num: true },
        { key: 'clients_waiting', label: 'clients waiting in those pools', num: true, cls: v => Number(v) > 0 ? 'warn' : '' },
        { key: 'longest_wait_us', label: 'longest client wait', num: true, fmt: waitUs },
        { key: 'pools', fmt: pids },
        { key: 'head_query', label: 'head\'s last statement', fmt: (v, r) => sqlCell(v, { heading: `pid ${String(r.head_pid)}: last statement` }) },
      ]));
      out.push(el('p', { class: 'meta' }, 'The cause of a chain is the head\'s transaction and its last statement, not the object the others wait on. '
        + 'Idle in transaction at the head = the application holds the transaction open.'));
    }
  }

  // the clients kept and the servers
  const clients = rowsOf(d.clients), servers = rowsOf(d.servers);
  const cut = Number(read.clients_read) - Number(read.clients_kept);
  out.push(el('h3', {}, 'Clients (SHOW CLIENTS)'),
    el('p', { class: 'meta' }, `${fmtNum(read.clients_read)} client(s) read; ${fmtNum(read.clients_kept)} kept (not idle, the longest waits first`
      + `${cut > 0 ? `; ${fmtNum(cut)} idle or past the cap not stored` : ''}). A waiting client has no server yet: pg_stat_activity cannot see it.`),
    grid(clients, [
      { key: 'state', fmt: stateCell },
      { key: 'wait_us', label: 'waiting for', num: true, fmt: (v, r) => String(r.state ?? '').startsWith('waiting') ? waitUs(v) : '' },
      { key: 'application_name', label: 'application' }, { key: 'database' }, { key: 'user' },
      { key: 'addr', label: 'client address', fmt: (v, r) => v == null ? '' : `${String(v)}:${String(r.port ?? '')}` },
      { key: 'request_time', label: 'last request', fmt: fmtTime },
      { key: 'connect_time', label: 'connected', fmt: fmtTime },
      { key: 'backend_pid', label: 'served by backend', fmt: (v, r) => runningLink(ctx, actAt, v, r) },
      { key: 'backend_state', label: 'backend state', fmt: backendCell },
      { key: 'role', label: 'in a chain', fmt: roleCell },
      { key: 'head_pid', label: 'chain head', fmt: (v, r) => r.role === 'head' ? '' : runningLink(ctx, actAt, v) },
    ], 'No client other than idle ones at this read.'));
  out.push(el('h3', {}, 'Servers (SHOW SERVERS)'),
    el('p', { class: 'meta' }, 'remote_pid is the backend\'s pid in PostgreSQL: the bridge from the pooler to Running queries and the blocking chain.'),
    grid(servers, [
      { key: 'backend_pid', label: 'backend pid (remote_pid)', fmt: (v, r) => runningLink(ctx, actAt, v, r) },
      { key: 'state', label: 'pooler state' },
      { key: 'paired_application', label: 'serving client', fmt: (v, r) => v == null && r.paired_addr == null ? '' : `${String(v ?? '')}${r.paired_addr ? ` (${String(r.paired_addr)})` : ''}` },
      { key: 'database' }, { key: 'user' },
      { key: 'backend_state', label: 'backend state', fmt: backendCell },
      { key: 'backend_wait', label: 'backend wait', fmt: waitCell },
      { key: 'backend_query_secs', label: 'query age', num: true, fmt: fmtSecs },
      { key: 'backend_xact_secs', label: 'transaction age', num: true, fmt: fmtSecs },
      { key: 'role', label: 'in a chain', fmt: roleCell },
      { key: 'blocking_pids', label: 'blocked by', fmt: pids },
      { key: 'head_pid', label: 'chain head', fmt: (v, r) => r.role === 'head' ? '' : runningLink(ctx, actAt, v) },
      { key: 'backend_query', label: 'statement', fmt: (v, r) => sqlCell(v, { heading: `pid ${String(r.backend_pid)}: ${String(r.backend_state ?? '').startsWith('idle') ? 'last statement' : 'statement'}` }) },
    ], 'No server connection at this read.'));
  return out;
}

// jsonRows: a jsonb array of objects as grid rows
function jsonRows(v: unknown): Row[] {
  if (Array.isArray(v)) return v as Row[];
  if (typeof v === 'string') try { const p = JSON.parse(v); return Array.isArray(p) ? p as Row[] : []; } catch { return []; }
  return [];
}

// hasPooler: whether the instance has a pooler read (the shell's check before it shows the Pooler tab)
export async function hasPooler(instance: number): Promise<boolean> {
  const d = await get<Record<'state', Table | null>>('pooler', { instance, part: 'state' });
  return rowsOf(d.state).length > 0;
}

const known = new Map<number, { has: boolean; at: number }>();
const KNOWN_FOR = 5 * 60 * 1000;

// poolerKnown answers whether the instance has a pooler read (a pgbouncer: DSN), cached five minutes per instance so the
// 30 s live render does not ask again; a failed read counts as none until the cache ages out.
export async function poolerKnown(instance: number): Promise<boolean> {
  const k = known.get(instance);
  if (k && Date.now() - k.at < KNOWN_FOR) return k.has;
  const has = await hasPooler(instance).catch(() => false);
  known.set(instance, { has, at: Date.now() });
  return has;
}

// poolerCached is the cached answer without a read (the tree's Pooler leaf): undefined before the first read.
export function poolerCached(instance: number): boolean | undefined { return known.get(instance)?.has; }

export async function pooler(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Pooler (${rangeLabel(ctx)})`));
  try {
    const w = window_(ctx);
    const [d, conns] = await Promise.all([get<Record<PoolerParts, Table | null>>('pooler', { instance: ctx.instance, ...w }), poolerConns(ctx.instance!, w.to).catch((e: unknown) => e instanceof Error ? e : new Error(String(e)))]);
    const st = rowsOf(d.state)[0];
    if (!st) {
      sec.append(el('p', { class: 'empty' }, 'No pooler read for this instance: its configuration names no pgbouncer: DSN (the pooler\'s admin console, '
        + 'dbname=pgbouncer, as a stats_users login), or the pgbouncer collection has not read it yet.'));
      return sec;
    }
    if (st.status !== 'ok') {
      sec.append(el('p', { class: 'meta' }, badge('not read', 'warn'), ` ${String(st.reason ?? '')} (tried ${fmtTime(st.snapshot_at)}; `
        + `last read ${st.last_ok ? fmtTime(st.last_ok) : 'never'}). The rows below are from the last read.`));
    }
    const pools = rowsOf(d.pools);
    const sum = (k: string) => pools.reduce((s, r) => s + Number(r[k] ?? 0), 0);
    const maxwait = pools.reduce((m, r) => Math.max(m, Number(r.maxwait_ms ?? 0)), 0);
    sec.append(el('div', { class: 'tiles' },
      tile('clients active', fmtNum(sum('cl_active'))),
      tile('clients waiting', fmtNum(sum('cl_waiting')), sum('cl_waiting') > 0 ? 'warn' : ''),
      tile('servers active', fmtNum(sum('sv_active'))),
      tile('longest wait', pools.length ? ms(maxwait) : '-', maxwait > 5000 ? 'crit' : ''),
    ));
    sec.append(props([
      ['pooler', String(st.version ?? '')],
      ['last read', fmtTime(st.last_ok ?? st.snapshot_at)],
    ]));
    const findings = rowsOf(d.findings);
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, findingCols));
    sec.append(el('h3', {}, 'Pools (SHOW POOLS)'), grid(pools, poolCols, 'No pool at the last read.'));
    // a failed read of the clients and servers shows its error in their place; the pools above stand
    if (conns instanceof Error) sec.append(el('h3', {}, 'Clients and servers (SHOW CLIENTS, SHOW SERVERS)'), errorBox(conns));
    else if (conns) sec.append(...connSections(ctx, conns));
    sec.append(lineChart('Clients and servers', rowsOf(d.series), [
      { key: 'cl_active', label: 'clients active' }, { key: 'cl_waiting', label: 'clients waiting' },
      { key: 'sv_active', label: 'servers active' }, { key: 'sv_idle', label: 'servers idle' },
    ]));
    sec.append(el('h3', {}, 'Rates (SHOW STATS)'),
      el('p', { class: 'meta' }, 'PgBouncer\'s own averages over its stats_period at the last read.'),
      grid(rowsOf(d.stats), statsCols, 'No database statistics at the last read.'));
    sec.append(el('h3', {}, 'Databases (SHOW DATABASES)'), grid(jsonRows(st.databases), dbCols, 'Not read yet.'));
    sec.append(el('h3', {}, 'Settings (SHOW CONFIG)'), grid(jsonRows(st.config), confCols, 'Not read yet.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
