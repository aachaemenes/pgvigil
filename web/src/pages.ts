import { Activity, get, Row, rowsOf } from './api';
import { lineChart } from './chart';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid } from './ui';

export interface Ctx { instance?: number; window: string; kind: string; at?: string }

const windows: Record<string, number> = { '15m': 900, '1h': 3600, '6h': 21600, '24h': 86400, '7d': 604800 };
function range(w: string) {
  const to = new Date();
  const from = new Date(to.getTime() - (windows[w] ?? 3600) * 1000);
  return { from: from.toISOString(), to: to.toISOString() };
}

function needInstance(ctx: Ctx): HTMLElement | null {
  return ctx.instance ? null : el('p', { class: 'empty' }, 'Pick an instance at the top.');
}

const truncQuery = (v: unknown) => { const s = v == null ? '' : String(v); return s.length > 400 ? s.slice(0, 400) + '...' : s; };

export async function overview(): Promise<HTMLElement> {
  const [checks, inst] = await Promise.all([get('overview'), get('instances')]);
  const rows = rowsOf(checks);
  const insts = rowsOf(inst);
  const crit = rows.filter(r => r.severity === 'critical').length;
  const warn = rows.length - crit;
  const tiles = el('div', { class: 'tiles' },
    tile('Instances', String(insts.length), ''),
    tile('Critical', String(crit), crit ? 'crit' : 'ok'),
    tile('Warnings', String(warn), warn ? 'warn' : 'ok'),
    tile('Lock waiters now', String(insts.reduce((a, r) => a + Number(r.waiting_lock ?? 0), 0)), ''));
  const cols: Col[] = [
    { key: 'severity', fmt: v => badge(String(v), v === 'critical' ? 'crit' : 'warn') },
    { key: 'instance', fmt: (v, r) => link(String(v), `#/activity?i=${r.instance_id}`) },
    { key: 'check_name', label: 'check' },
    { key: 'object' },
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'detail', wide: true },
  ];
  return el('section', {}, el('h2', {}, 'Daily checks'), tiles,
    grid(rows, cols, 'All checks pass: no failing or stale collections, replication problems, failed jobs, deadlocks or checksum failures.'));
}

function tile(label: string, value: string, kind: string) {
  return el('div', { class: 'tile ' + kind }, el('div', { class: 'tile-v' }, value), el('div', { class: 'tile-l' }, label));
}
function link(text: string, href: string) { return el('a', { href }, text); }

export async function instances(): Promise<HTMLElement> {
  const rows = rowsOf(await get('instances'));
  const cols: Col[] = [
    { key: 'name', fmt: (v, r) => link(String(v), `#/activity?i=${r.instance_id}`) },
    { key: 'platform' },
    { key: 'server_version', label: 'version', wide: true },
    { key: 'is_replica', label: 'role', fmt: v => v ? 'replica' : 'primary' },
    { key: 'postmaster_start', label: 'started', fmt: fmtTime },
    { key: 'total', label: 'sessions', num: true },
    { key: 'active', num: true },
    { key: 'idle_in_txn', label: 'idle in txn', num: true },
    { key: 'waiting_lock', label: 'lock waits', num: true },
    { key: 'longest_active_secs', label: 'longest active', num: true, fmt: fmtSecs },
    { key: 'oldest_xmin_age', label: 'oldest xmin age', num: true },
    { key: 'collections_failing', label: 'failing', num: true },
    { key: 'activity_at', label: 'last sample', fmt: fmtTime },
  ];
  return el('section', {}, el('h2', {}, 'Instances'), grid(rows, cols, 'No instances yet: run the collector.'));
}

export async function activity(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const a = await get<Activity>('activity', { instance: ctx.instance, at: ctx.at });
  const sec = el('section', {}, el('h2', {}, 'Running queries'), snapshotPicker(ctx));
  if (!a.snapshot_at) { sec.append(el('p', { class: 'empty' }, 'No activity snapshot for this instance yet.')); return sec; }
  const sum = rowsOf(a.summary)[0] ?? {};
  sec.append(el('p', { class: 'meta' }, `Snapshot ${fmtTime(a.snapshot_at)}: ${fmtNum(sum.total)} sessions, ${fmtNum(sum.active)} active, ` +
    `${fmtNum(sum.idle_in_txn)} idle in transaction, ${fmtNum(sum.waiting_lock)} waiting on a lock.`));

  const chains = rowsOf(a.chains);
  sec.append(el('h3', {}, 'Blocking chains'));
  if (chains.length === 0) sec.append(el('p', { class: 'empty' }, 'No lock waits in this snapshot.'));
  else {
    const heads = new Map<number, Row[]>();
    for (const c of chains) { const h = Number(c.head_pid); if (!heads.has(h)) heads.set(h, []); heads.get(h)!.push(c); }
    for (const [h, list] of heads) {
      const first = list[0];
      const box = el('div', { class: 'chain' },
        el('div', { class: 'chain-head' }, badge('HEAD', 'crit'), ` pid ${h} - ${first.head_state ?? ''} (${first.head_backend_type ?? ''}) - ${list.length} waiter(s)`
          + (list.some(x => x.in_cycle) ? ' - cycle' : '')),
        el('pre', { class: 'sql' }, String(first.head_query ?? '(no statement text)')));
      for (const w of list) {
        box.append(el('div', { class: 'chain-w', style: `margin-left:${Number(w.depth) * 1.2}rem` },
          `pid ${w.pid} depth ${w.depth} - ${w.state ?? ''} ${w.wait_event ?? ''}: `, el('code', {}, truncQuery(w.waiter_query))));
      }
      sec.append(box);
    }
  }

  sec.append(el('h3', {}, 'Sessions'));
  const cols: Col[] = [
    { key: 'pid', num: true, fmt: (v, r) => r.is_blocker ? el('b', {}, String(v)) : String(v) },
    { key: 'state' },
    { key: 'wait_event_type', label: 'wait type' },
    { key: 'wait_event', label: 'wait' },
    { key: 'blocking_pids', label: 'blocked by' },
    { key: 'query_secs', label: 'query age', num: true, fmt: fmtSecs },
    { key: 'xact_secs', label: 'txn age', num: true, fmt: fmtSecs },
    { key: 'backend_xmin_age', label: 'xmin age', num: true },
    { key: 'datname', label: 'db' },
    { key: 'usename', label: 'user' },
    { key: 'application_name', label: 'app' },
    { key: 'client' },
    { key: 'query', wide: true, fmt: truncQuery },
  ];
  sec.append(grid(rowsOf(a.sessions), cols, 'No active or idle-in-transaction sessions in this snapshot.'));
  return sec;
}

// snapshotPicker moves the page to the snapshot at or before a chosen local time; empty = latest.
function snapshotPicker(ctx: Ctx): HTMLElement {
  const input = el('input', { type: 'datetime-local', step: '1', 'aria-label': 'snapshot time' });
  if (ctx.at) {
    const d = new Date(ctx.at);
    input.value = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 19);
  }
  const go = (at?: string) => { location.hash = `#/activity?i=${ctx.instance}` + (at ? `&at=${encodeURIComponent(at)}` : ''); };
  // the picker has whole seconds and snapshots have fractions: take the end of the chosen second
  input.addEventListener('change', () => { go(input.value ? new Date(new Date(input.value).getTime() + 999).toISOString() : undefined); });
  const latest = el('button', { type: 'button' }, 'Latest');
  latest.addEventListener('click', () => go());
  return el('div', { class: 'picker' }, 'Snapshot at or before ', input, ' ', latest, ctx.at ? el('span', { class: 'meta' }, ' (history: auto refresh off)') : null);
}

export async function statements(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const rows = rowsOf(await get('statements', { instance: ctx.instance, ...range(ctx.window), limit: 100 }));
  const cols: Col[] = [
    { key: 'total_exec_ms', label: 'total ms', num: true },
    { key: 'calls', num: true },
    { key: 'mean_exec_ms', label: 'mean ms', num: true },
    { key: 'rows', num: true },
    { key: 'shared_blks_read', label: 'blks read', num: true },
    { key: 'shared_blks_hit', label: 'blks hit', num: true },
    { key: 'temp_blks_written', label: 'temp blks', num: true },
    { key: 'wal_bytes', label: 'WAL', num: true, fmt: fmtBytes },
    { key: 'datname', label: 'db' },
    { key: 'usename', label: 'user' },
    { key: 'queryid', label: 'queryid' },
    { key: 'query', wide: true, fmt: truncQuery },
  ];
  return el('section', {}, el('h2', {}, `Top statements (last ${ctx.window})`),
    grid(rows, cols, 'No statement deltas in this window (pg_stat_statements missing, or fewer than two snapshots).'));
}

const counterSets: Record<string, { title: string; series: { key: string; label: string }[]; fmt?: (v: number) => string }[]> = {
  db: [
    { title: 'Transactions / s', series: [{ key: 'commits_s', label: 'commits' }, { key: 'rollbacks_s', label: 'rollbacks' }] },
    { title: 'Blocks / s', series: [{ key: 'blks_read_s', label: 'read' }, { key: 'blks_hit_s', label: 'hit' }] },
    { title: 'Tuples / s', series: [{ key: 'tup_read_s', label: 'read' }, { key: 'tup_written_s', label: 'written' }] },
    { title: 'Temp bytes / s', series: [{ key: 'temp_bytes_s', label: 'temp' }], fmt: fmtBytes },
    { title: 'Deadlocks per interval', series: [{ key: 'deadlocks', label: 'deadlocks' }] },
  ],
  server: [
    { title: 'WAL bytes / s', series: [{ key: 'wal_bytes_s', label: 'WAL' }], fmt: fmtBytes },
    { title: 'Buffers / s', series: [{ key: 'buffers_written_s', label: 'written' }, { key: 'buffers_alloc_s', label: 'allocated' }] },
    { title: 'Checkpoints per interval', series: [{ key: 'checkpoints', label: 'all' }, { key: 'checkpoints_req', label: 'requested' }] },
  ],
  io: [
    { title: 'IO bytes / s (pg_stat_io)', series: [{ key: 'read_bytes_s', label: 'read' }, { key: 'write_bytes_s', label: 'write' }, { key: 'extend_bytes_s', label: 'extend' }], fmt: fmtBytes },
    { title: 'Buffer hits / s', series: [{ key: 'hits_s', label: 'hits' }] },
    { title: 'fsyncs / s', series: [{ key: 'fsyncs_s', label: 'fsyncs' }] },
  ],
  sessions: [
    { title: 'Sessions', series: [{ key: 'total', label: 'total' }, { key: 'active', label: 'active' }, { key: 'idle_in_txn', label: 'idle in txn' }, { key: 'waiting_lock', label: 'lock waits' }] },
    { title: 'Longest (s)', series: [{ key: 'longest_active_secs', label: 'active' }, { key: 'longest_idle_txn_secs', label: 'idle in txn' }] },
    { title: 'Oldest xmin age', series: [{ key: 'oldest_xmin_age', label: 'xmin age' }] },
  ],
};

export async function counters(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const kind = counterSets[ctx.kind] ? ctx.kind : 'db';
  const rows = rowsOf(await get('counters', { instance: ctx.instance, kind, ...range(ctx.window) }));
  const tabs = el('div', { class: 'tabs' }, ...Object.keys(counterSets).map(k =>
    el('a', { href: `#/counters?i=${ctx.instance}&kind=${k}&w=${ctx.window}`, class: k === kind ? 'on' : '' }, k)));
  const charts = el('div', { class: 'charts' }, ...counterSets[kind].map(c => lineChart(c.title, rows, c.series, c.fmt)));
  return el('section', {}, el('h2', {}, `Counters (last ${ctx.window})`), tabs, charts);
}

export { errorBox };
