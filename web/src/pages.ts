import { Activity, DMS, get, Row, rowsOf, Table } from './api';
import { dmsDrainView, findingsView, slowCols, statementOrders, stmtCols } from './borrowed';
import { lineChart } from './chart';
import { cellClass, cells, cellText, Fleet, fleet, groups, tagsOf } from './fleet';
import { Ctx, href, isLive, rangeLabel, window_ } from './router';
import { badge, Col, dot, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';

export type { Ctx };
const range = window_;

function needInstance(ctx: Ctx): HTMLElement | null {
  return ctx.instance ? null : el('p', { class: 'empty' }, 'Pick an instance in the tree on the left.');
}

// inTag keeps the fleet rows of the tag folder picked in the tree (none = every instance).
function inTag(ctx: Ctx, rows: Row[]): Row[] {
  if (!ctx.tag) return rows;
  return rows.filter(r => ctx.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(ctx.tag!));
}
const scopeLabel = (ctx: Ctx) => ctx.tag ? ` - tag ${ctx.tag}` : '';
const instLink = (ctx: Ctx, text: string, id: unknown, tab = 'summary') => link(text, href(ctx, { tab, instance: Number(id), tag: undefined, at: undefined, task: undefined, taskInstance: undefined }));

const truncQuery = (v: unknown) => { const s = v == null ? '' : String(v); return s.length > 400 ? s.slice(0, 400) + '...' : s; };

export async function checks(ctx: Ctx): Promise<HTMLElement> {
  const f = await fleet();
  const insts = inTag(ctx, f.instances);
  const ids = new Set(insts.map(r => Number(r.instance_id)));
  // a check that could not run names no instance: it shows under every scope
  const rows = f.checks.filter(r => r.instance_id == null || ids.has(Number(r.instance_id)));
  const crit = rows.filter(r => r.severity === 'critical').length;
  const warn = rows.length - crit;
  const tiles = el('div', { class: 'tiles' },
    tile('Instances', String(insts.length), ''),
    tile('Critical', String(crit), crit ? 'crit' : 'ok'),
    tile('Warnings', String(warn), warn ? 'warn' : 'ok'),
    tile('Lock waiters now', String(insts.reduce((a, r) => a + Number(r.waiting_lock ?? 0), 0)), ''));
  const cols: Col[] = [
    { key: 'severity', fmt: v => badge(String(v), v === 'critical' ? 'crit' : 'warn') },
    { key: 'instance', fmt: (v, r) => r.instance_id == null ? String(v ?? '') : instLink(ctx, String(v), r.instance_id, groupTab(r.check_group)) },
    { key: 'check_name', label: 'check' },
    { key: 'object' },
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'detail', wide: true },
  ];
  return el('section', {}, el('h2', {}, 'Daily checks' + scopeLabel(ctx)), el('p', { class: 'meta' }, 'The state now; the time range applies to the instance tabs.'), tiles,
    grid(rows, cols, 'All checks pass: no failing or stale collections, replication problems, failed jobs, deadlocks or checksum failures.'));
}

function groupTab(g: unknown): string { return groups.find(x => x.checks.includes(String(g)))?.tab ?? 'summary'; }
function link(text: string, href: string) { return el('a', { href }, text); }

export async function instances(ctx: Ctx): Promise<HTMLElement> {
  const rows = inTag(ctx, (await fleet()).instances);
  const cols: Col[] = [
    { key: 'name', fmt: (v, r) => instLink(ctx, String(v), r.instance_id) },
    { key: 'tags', fmt: v => Array.isArray(v) ? v.join(', ') : '' },
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
  return el('section', {}, el('h2', {}, 'Instances' + scopeLabel(ctx)), grid(rows, cols, 'No instances yet: run the collector.'));
}

export async function activity(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const at = ctx.at ?? (isLive(ctx) ? undefined : range(ctx).to);
  const a = await get<Activity>('activity', { instance: ctx.instance, at });
  const sec = el('section', {}, el('h2', {}, 'Running queries'), snapshotPicker(ctx, at));
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
function snapshotPicker(ctx: Ctx, at?: string): HTMLElement {
  const input = el('input', { type: 'datetime-local', step: '1', 'aria-label': 'snapshot time' });
  if (at) {
    const d = new Date(at);
    input.value = new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 19);
  }
  const go = (t?: string) => { location.hash = href(ctx, { tab: 'activity', at: t }); };
  // the picker has whole seconds and snapshots have fractions: take the end of the chosen second
  input.addEventListener('change', () => { go(input.value ? new Date(new Date(input.value).getTime() + 999).toISOString() : undefined); });
  // under a custom range the page shows the range's end: Latest returns to a range that follows now
  const latest = el('button', { type: 'button', title: isLive(ctx) ? 'The newest snapshot' : 'The newest snapshot (switches the range to the last hour)' }, 'Latest');
  latest.addEventListener('click', () => {
    location.hash = isLive(ctx) ? href(ctx, { tab: 'activity', at: undefined }) : href(ctx, { tab: 'activity', at: undefined, range: { preset: '1h' } });
  });
  const hist = ctx.at ? ' (history: auto refresh off)' : at ? ' (the end of the custom range: auto refresh off)' : '';
  return el('div', { class: 'picker' }, 'Snapshot at or before ', input, ' ', latest, hist ? el('span', { class: 'meta' }, hist) : null);
}

export async function statements(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const order = statementOrders.some(o => o[0] === ctx.order) ? ctx.order! : 'time';
  const minSecs = ctx.minSecs ?? 5;
  const w = { instance: ctx.instance, ...range(ctx) };
  // the slow read is separate: its failure shows under its own heading, the top statements stay
  const [st, slow] = await Promise.all([get('statements', { ...w, order, limit: 100 }), get('slow', { ...w, min: minSecs }).catch((e: unknown) => e)]);
  const sortBar = el('div', { class: 'subtabs' }, ...statementOrders.map(([k, l]) =>
    el('a', { href: href(ctx, { tab: 'statements', order: k }), class: k === order ? 'on' : '' }, 'by ' + l)));
  const minIn = el('input', { type: 'number', min: '0', max: '86400', step: '1', value: String(minSecs), style: 'width:5em', 'aria-label': 'seconds at least' });
  minIn.addEventListener('change', () => {
    const v = Number(minIn.value);
    if (Number.isFinite(v)) location.hash = href(ctx, { tab: 'statements', minSecs: Math.min(86400, Math.max(0, Math.trunc(v))) });
  });
  return el('section', {}, el('h2', {}, `Top statements by ${statementOrders.find(o => o[0] === order)?.[1]} (${rangeLabel(ctx)})`), sortBar,
    grid(rowsOf(st), stmtCols(order), 'No statement deltas in this window (pg_stat_statements missing, or fewer than two snapshots).'),
    el('h3', {}, 'Ran at least ', minIn, ' s in this window'),
    el('p', { class: 'meta' }, 'From the running-queries samples: a duration is a floor (the statement ended between its last sample and the next); an idle-in-transaction session is timed from its transaction start.'),
    slow instanceof Error ? errorBox(slow) : grid(rowsOf(slow as Table), slowCols, 'Nothing seen running that long in this window.'));
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
  const rows = rowsOf(await get('counters', { instance: ctx.instance, kind, ...range(ctx) }));
  const tabs = el('div', { class: 'subtabs' }, ...Object.keys(counterSets).map(k =>
    el('a', { href: href(ctx, { tab: 'counters', kind: k }), class: k === kind ? 'on' : '' }, k)));
  const charts = el('div', { class: 'charts' }, ...counterSets[kind].map(c => lineChart(c.title, rows, c.series, c.fmt)));
  return el('section', {}, el('h2', {}, `Counters (${rangeLabel(ctx)})`), tabs, charts);
}

const taskBadge = (v: unknown) => {
  const s = String(v ?? '');
  const kind = ['failed', 'failed-move', 'error'].includes(s) ? 'crit' : s === 'running' ? 'ok' : ['stopped', 'stopping', 'starting', 'ready'].includes(s) ? 'warn' : '';
  return badge(s, kind);
};

export async function dms(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<DMS>('dms', { instance: ctx.instance, task: ctx.task, task_instance: ctx.taskInstance });
  // a tag folder picked in the tree scopes the fleet DMS tab like the other root tabs
  const ids = ctx.tag && !ctx.instance ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const scoped = (rows: Row[]) => ids ? rows.filter(r => ids.has(Number(r.instance_id))) : rows;
  const tasks = scoped(rowsOf(d.tasks)), ris = scoped(rowsOf(d.instances)), tables = rowsOf(d.tables);
  const sec = el('section', {}, el('h2', {}, 'DMS replication tasks' + (ctx.instance ? '' : scopeLabel(ctx))), el('p', { class: 'meta' }, 'The newest state of each task; the time range does not apply.'));
  const taskCols: Col[] = [
    { key: 'instance', fmt: (v, r) => instLink(ctx, String(v), r.instance_id, 'dms') },
    { key: 'task_id', label: 'task', fmt: (v, r) => link(String(v), href(ctx, { tab: 'dms', task: String(r.task_arn), taskInstance: Number(r.instance_id) })) },
    { key: 'status', fmt: taskBadge },
    { key: 'migration_type', label: 'type' },
    { key: 'progress_pct', label: 'full load %', num: true },
    { key: 'tables', num: true, fmt: (v, r) => r.tables_partial ? fmtNum(v) + '+ (cut)' : fmtNum(v) },
    { key: 'tables_errored', label: 'errored', num: true },
    { key: 'latency_source_s', label: 'latency source', num: true, fmt: fmtSecs },
    { key: 'latency_target_s', label: 'latency target', num: true, fmt: fmtSecs },
    { key: 'incoming_changes', label: 'incoming changes', num: true },
    { key: 'elapsed_secs', label: 'full load time', num: true, fmt: fmtSecs },   // ElapsedTimeMillis is the full load's duration on a live task, not the task's age
    { key: 'ri_id', label: 'replication instance' },
    { key: 'stop_reason', label: 'stop reason', wide: true },
    { key: 'last_failure', label: 'last failure', wide: true },
    { key: 'snapshot_at', label: 'seen', fmt: fmtTime },
    { key: 'is_present', label: 'present', fmt: v => v ? 'yes' : 'gone' },
  ];
  sec.append(grid(tasks, taskCols, 'No DMS tasks: name them under an instance\'s aws.dms.tasks in the collector config.'));
  if (tasks.length) sec.append(dmsDrainView(scoped(rowsOf(d.drain))));
  if (ctx.task) {
    const t = tasks.find(r => r.task_arn === ctx.task && (!ctx.taskInstance || Number(r.instance_id) === ctx.taskInstance));
    sec.append(el('h3', {}, `Tables of ${t ? String(t.task_id) : ctx.task}`), el('p', { class: 'meta' }, link('all tasks', href(ctx, { tab: 'dms', task: undefined, taskInstance: undefined }))));
    const tableCols: Col[] = [
      { key: 'schema_name', label: 'schema' },
      { key: 'table_name', label: 'table' },
      { key: 'table_state', label: 'state' },
      { key: 'full_load_rows', label: 'full load rows', num: true },
      { key: 'full_load_error_rows', label: 'load errors', num: true },
      { key: 'inserts', num: true },
      { key: 'updates', num: true },
      { key: 'deletes', num: true },
      { key: 'ddls', num: true },
      { key: 'validation_state', label: 'validation' },
      { key: 'validation_failed', label: 'failed', num: true },
      { key: 'validation_pending', label: 'pending', num: true },
      { key: 'last_update', label: 'updated', fmt: fmtTime },
      { key: 'validation_detail', label: 'detail', wide: true },
    ];
    sec.append(grid(tables, tableCols, 'No table statistics for this task yet (it has not started).'));
  }
  sec.append(el('h3', {}, 'Replication instances'));
  const riCols: Col[] = [
    { key: 'instance', fmt: (v, r) => instLink(ctx, String(v), r.instance_id, 'dms') },
    { key: 'ri_id', label: 'identifier' },
    { key: 'status' },
    { key: 'class' },
    { key: 'engine_version', label: 'engine' },
    { key: 'tasks', num: true },
    { key: 'cpu_pct', label: 'CPU %', num: true },
    { key: 'freeable_bytes', label: 'freeable memory', num: true, fmt: fmtBytes },
    { key: 'swap_bytes', label: 'swap', num: true, fmt: fmtBytes },
    { key: 'free_storage_bytes', label: 'free storage', num: true, fmt: fmtBytes },
    { key: 'allocated_gb', label: 'storage GB', num: true },
    { key: 'multi_az', label: 'multi-AZ', fmt: v => v ? 'yes' : 'no' },
    { key: 'az' },
    { key: 'pending', wide: true },
    { key: 'snapshot_at', label: 'seen', fmt: fmtTime },
  ];
  sec.append(grid(ris, riCols, 'No replication instances yet.'));
  return sec;
}

export { errorBox };

// ---- fleet Summary: one row per instance, one coloured cell per check group (DBADash's Summary tab)

export async function fleetSummary(ctx: Ctx): Promise<HTMLElement> {
  const f = await fleet();
  const insts = inTag(ctx, f.instances);
  const rows = insts.map(r => {
    const c = cells(f, r);
    const row: Row = { ...r, _cells: c, _worst: Math.max(...Object.values(c).map(x => x.level)) };
    for (const g of groups) row['g_' + g.key] = c[g.key].level * 1000 + c[g.key].n;   // sorts by level, then count
    return row;
  });
  rows.sort((a, b) => Number(b._worst) - Number(a._worst) || String(a.name).localeCompare(String(b.name)));
  const n = [0, 0, 0];
  for (const r of rows) n[Number(r._worst)]++;
  const tiles = el('div', { class: 'tiles' },
    tile('Instances', String(rows.length)),
    tile('Critical', String(n[2]), n[2] ? 'crit' : 'ok'),
    tile('Warning', String(n[1]), n[1] ? 'warn' : 'ok'),
    tile('OK', String(n[0]), 'ok'),
    tile('Lock waiters now', String(insts.reduce((a, r) => a + Number(r.waiting_lock ?? 0), 0))));
  const statusCol = (g: typeof groups[number]): Col => ({
    key: 'g_' + g.key, label: g.label,
    cls: (_v, r) => 'status ' + cellClass((r._cells as ReturnType<typeof cells>)[g.key]),
    fmt: (_v, r) => {
      const c = (r._cells as ReturnType<typeof cells>)[g.key];
      const a = el('a', { href: href(ctx, { tab: g.tab, instance: Number(r.instance_id), tag: undefined }), class: 'cell-link' }, cellText(c));
      if (c.detail.length) a.title = c.detail.slice(0, 12).join('\n') + (c.detail.length > 12 ? `\n... ${c.detail.length - 12} more` : '');
      return a;
    },
  });
  const cols: Col[] = [
    { key: '_worst', label: '', fmt: v => dot(Number(v)) },
    { key: 'name', label: 'instance', fmt: (v, r) => instLink(ctx, String(v), r.instance_id) },
    { key: 'platform' },
    { key: 'is_replica', label: 'role', fmt: v => v ? 'replica' : 'primary' },
    ...groups.map(statusCol),
    { key: 'total', label: 'sessions', num: true },
    { key: 'waiting_lock', label: 'lock waits', num: true },
    { key: 'server_version', label: 'version', fmt: v => String(v ?? '').split(' ').slice(0, 2).join(' ') },
    { key: 'activity_at', label: 'last sample', fmt: fmtTime },
  ];
  const broken = f.checks.filter(r => r.instance_id == null);
  return el('section', {}, el('h2', {}, 'Summary' + scopeLabel(ctx)),
    el('p', { class: 'meta' }, 'The state now, one row per instance; a cell opens that instance at the matching tab, its hover lists the checks.'),
    tiles,
    broken.length ? el('p', { class: 'error' }, `${broken.length} check(s) could not run: see Daily checks.`) : null,
    grid(rows, cols, 'No instances yet: run the collector.'));
}

// ---- instance Summary

export async function instanceSummary(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const [f, dbs, sess, db] = await Promise.all([
    fleet(), get('databases', { instance: ctx.instance }),
    get('counters', { instance: ctx.instance, kind: 'sessions', ...range(ctx) }),
    get('counters', { instance: ctx.instance, kind: 'db', ...range(ctx) }),
  ]);
  const r = f.instances.find(x => Number(x.instance_id) === ctx.instance);
  if (!r) return el('p', { class: 'empty' }, 'This instance is not in the repository (or no longer active).');
  const c = cells(f, r);
  const mine = f.checks.filter(x => Number(x.instance_id) === ctx.instance);
  const sec = el('section', {}, el('h2', {}, String(r.name), ' ', badge(String(r.platform ?? ''), ''), ' ', badge(r.is_replica ? 'replica' : 'primary', '')));
  sec.append(el('div', { class: 'groups' }, ...groups.map(g => {
    const x = c[g.key];
    const a = el('a', { class: 'group ' + cellClass(x), href: href(ctx, { tab: g.tab }) },
      el('span', { class: 'group-l' }, g.label), el('span', { class: 'group-v' }, cellText(x)));
    if (x.detail.length) a.title = x.detail.join('\n');
    return a;
  })));
  sec.append(el('div', { class: 'tiles' },
    tile('Sessions', fmtNum(r.total)), tile('Active', fmtNum(r.active)),
    tile('Idle in txn', fmtNum(r.idle_in_txn), Number(r.idle_in_txn) ? 'warn' : ''),
    tile('Lock waits', fmtNum(r.waiting_lock), Number(r.waiting_lock) ? 'warn' : ''),
    tile('Longest active', fmtSecs(r.longest_active_secs) || '0s'),
    tile('Oldest xmin age', fmtNum(r.oldest_xmin_age)),
    tile('Failing collections', fmtNum(r.collections_failing), Number(r.collections_failing) ? 'crit' : '')));
  const two = el('div', { class: 'two' });
  two.append(el('div', {}, el('h3', {}, 'Instance'), props([
    ['version', String(r.server_version ?? '')],
    ['started', fmtTime(r.postmaster_start)],
    ['max connections', fmtNum(r.max_connections)],
    ['data checksums', String(r.data_checksums ?? '')],
    ['pg_stat_statements', r.has_pg_stat_statements ? 'yes' : 'no'],
    ['tags', tagsOf(r).join(', ')],
    ['last seen', fmtTime(r.last_seen)],
    ['last activity sample', fmtTime(r.activity_at)],
  ])));
  const checkCols: Col[] = [
    { key: 'severity', fmt: v => badge(String(v), v === 'critical' ? 'crit' : 'warn') },
    { key: 'check_name', label: 'check', fmt: (v, x) => link(String(v), href(ctx, { tab: groupTab(x.check_group) })) },
    { key: 'object' },
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'detail', wide: true },
  ];
  two.append(el('div', {}, el('h3', {}, 'Failing checks'), grid(mine, checkCols, 'All checks pass on this instance.')));
  sec.append(two);
  sec.append(el('h3', {}, `Activity (${rangeLabel(ctx)})`), el('div', { class: 'charts' },
    lineChart('Sessions', rowsOf(sess), [{ key: 'total', label: 'total' }, { key: 'active', label: 'active' }, { key: 'idle_in_txn', label: 'idle in txn' }, { key: 'waiting_lock', label: 'lock waits' }]),
    lineChart('Transactions / s', rowsOf(db), [{ key: 'commits_s', label: 'commits' }, { key: 'rollbacks_s', label: 'rollbacks' }])));
  const dbCols: Col[] = [
    { key: 'datname', label: 'database' },
    { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
    { key: 'xid_age', label: 'xid age', num: true },
    { key: 'mxid_age', label: 'mxid age', num: true },
    { key: 'owner' },
    { key: 'encoding' },
    { key: 'can_connect', label: 'connect', fmt: v => v == null ? '' : v ? 'yes' : 'no' },
    { key: 'is_present', label: 'present', fmt: v => v ? 'yes' : 'dropped' },
    { key: 'snapshot_at', label: 'seen', fmt: fmtTime },
  ];
  sec.append(el('h3', {}, 'Databases'), grid(rowsOf(dbs), dbCols, 'No database inventory yet (the databases collection runs hourly).'));
  return sec;
}

// ---- Replication

// pivot turns long rows (snapshot_at, series name, value) into one row per snapshot with a column per
// series, keeping the n series with the largest peak.
function pivot(rows: Row[], name: (r: Row) => string, val: (r: Row) => number | null, n = 8) {
  const peak = new Map<string, number>();
  for (const r of rows) { const v = val(r); if (v != null) peak.set(name(r), Math.max(peak.get(name(r)) ?? 0, v)); }
  const keep = [...peak.entries()].sort((a, b) => b[1] - a[1]).slice(0, n).map(e => e[0]);
  const by = new Map<string, Row>();
  for (const r of rows) {
    const k = name(r); if (!keep.includes(k)) continue;
    const t = String(r.snapshot_at);
    if (!by.has(t)) by.set(t, { snapshot_at: t });
    by.get(t)![k] = val(r);
  }
  return { rows: [...by.values()], series: keep.map(k => ({ key: k, label: k })) };
}

export async function replication(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const d = await get<Record<'latest' | 'checks' | 'series' | 'series_meta', Table>>('replication', { instance: ctx.instance, ...range(ctx) });
  const sec = el('section', {}, el('h2', {}, 'Replication'));
  const checkCols: Col[] = [
    { key: 'check_name', label: 'check', fmt: v => badge(String(v), String(v).startsWith('slot WAL status') ? 'crit' : 'warn') },
    { key: 'object' }, { key: 'value', num: true }, { key: 'unit' }, { key: 'state' }, { key: 'snapshot_at', label: 'seen', fmt: fmtTime },
  ];
  sec.append(el('h3', {}, 'Checks'), grid(rowsOf(d.checks), checkCols, 'No replication problems in the newest snapshot.'));
  const latest = rowsOf(d.latest);
  const cols: Col[] = [
    { key: 'kind' }, { key: 'key', label: 'name' }, { key: 'state' },
    { key: 'lag_bytes', label: 'lag / retained', num: true, fmt: fmtBytes },
    { key: 'lag_secs', label: 'lag', num: true, fmt: v => v == null ? '' : Number(v) < 1 ? Number(v).toFixed(3) + 's' : fmtSecs(v) },
    { key: 'active', fmt: v => v == null ? '' : v ? 'yes' : 'no' },
    { key: 'snapshot_at', label: 'seen', fmt: fmtTime },
    { key: 'detail', wide: true, fmt: v => { const s = JSON.stringify(v ?? {}); return s.length > 300 ? s.slice(0, 300) + '...' : s; } },
  ];
  sec.append(el('h3', {}, 'Newest snapshot'), grid(latest, cols, 'No replication objects in the last day (no senders, slots, subscriptions or a receiver).'));
  const series = rowsOf(d.series);
  const name = (r: Row) => `${r.kind} ${r.key}`;
  const secs = pivot(series, name, r => r.lag_secs == null ? null : Number(r.lag_secs));
  const bytes = pivot(series, name, r => r.lag_bytes == null ? null : Number(r.lag_bytes));
  const meta = rowsOf(d.series_meta)[0] ?? {};
  const step = Number(meta.step_secs ?? 60), capped = series.length >= Number(meta.cap ?? Infinity);
  sec.append(el('h3', {}, `Lag (${rangeLabel(ctx)})`),
    el('p', { class: capped ? 'error' : 'meta' }, `Each point is the largest lag in a ${fmtSecs(step)} bucket.` +
      (capped ? ` Too many objects for this range: the oldest points are cut, the chart starts at ${fmtTime(series[0]?.snapshot_at)}. Pick a shorter range.` : '')),
    el('div', { class: 'charts' },
    lineChart('Replay lag (s)', secs.rows, secs.series),
    lineChart('Lag / retained WAL', bytes.rows, bytes.series, fmtBytes)));
  return sec;
}

// ---- Jobs

const runBadge = (v: unknown) => {
  const s = String(v ?? '');
  return s ? badge(s, ['failed', 'internal error', 'aborted'].includes(s) ? 'crit' : s === 'succeeded' ? 'ok' : 'warn') : '';
};

export async function jobs(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const d = await get<Record<'jobs' | 'runs', Table>>('jobs', { instance: ctx.instance, ...range(ctx) });
  const jobCols: Col[] = [
    { key: 'scheduler' }, { key: 'job_id', label: 'id', num: true }, { key: 'job_name', label: 'name' }, { key: 'schedule' },
    { key: 'active', fmt: v => v == null ? '' : v ? 'yes' : 'no' },
    { key: 'last_status', label: 'last run', fmt: runBadge },
    { key: 'last_start', label: 'last start', fmt: fmtTime },
    { key: 'last_duration_secs', label: 'took', num: true, fmt: fmtSecs },
    { key: 'next_run', label: 'next run', fmt: fmtTime },
    { key: 'datname', label: 'db' }, { key: 'run_as', label: 'run as' },
    { key: 'is_present', label: 'present', fmt: v => v ? 'yes' : 'gone' },
    { key: 'command', wide: true },
  ];
  const runCols: Col[] = [
    { key: 'start_time', label: 'start', fmt: fmtTime },
    { key: 'duration_secs', label: 'took', num: true, fmt: fmtSecs },
    { key: 'status', fmt: runBadge },
    { key: 'scheduler' }, { key: 'job_name', label: 'job', fmt: (v, r) => String(v ?? r.job_id) },
    { key: 'run_id', label: 'run', num: true }, { key: 'datname', label: 'db' },
    { key: 'return_message', label: 'message', wide: true },
  ];
  return el('section', {}, el('h2', {}, 'Jobs'),
    grid(rowsOf(d.jobs), jobCols, 'No scheduled jobs (pg_cron or pgAgent not installed, or nothing scheduled).'),
    el('h3', {}, `Runs (${rangeLabel(ctx)})`), grid(rowsOf(d.runs), runCols, 'No job runs started in this range.'));
}

// ---- Logs

const logKinds: Record<string, string> = { slow: 'slow statements', lock_wait: 'lock waits', deadlock: 'deadlocks', auth_fail: 'failed logins' };

export async function logs(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const kind = ctx.logKind && logKinds[ctx.logKind] ? ctx.logKind : undefined;
  const d = await get<Record<'counts' | 'events', Table>>('logs', { instance: ctx.instance, kind, ...range(ctx) });
  const counts = new Map(rowsOf(d.counts).map(r => [String(r.kind), Number(r.events)]));
  const total = [...counts.values()].reduce((a, b) => a + b, 0);
  const tabs = el('div', { class: 'subtabs' },
    el('a', { href: href(ctx, { tab: 'logs', logKind: '' }), class: kind ? '' : 'on' }, `all (${total})`),
    ...Object.entries(logKinds).map(([k, l]) => el('a', { href: href(ctx, { tab: 'logs', logKind: k }), class: k === kind ? 'on' : '' }, `${l} (${counts.get(k) ?? 0})`)));
  const cols: Col[] = [
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'kind', fmt: v => badge(logKinds[String(v)] ?? String(v), v === 'deadlock' ? 'crit' : v === 'slow' ? '' : 'warn') },
    { key: 'duration_ms', label: 'ms', num: true },
    { key: 'pid', num: true }, { key: 'datname', label: 'db' }, { key: 'usename', label: 'user' }, { key: 'client' },
    { key: 'statement', wide: true }, { key: 'detail', wide: true },
  ];
  return el('section', {}, el('h2', {}, `Log events (${rangeLabel(ctx)})`), tabs,
    grid(rowsOf(d.events), cols, 'No log events in this range (the logs collection reads the server log where it is configured).'));
}

// ---- Configuration: instance_state with the change history

export async function config(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const d = await get<Record<'state' | 'settings' | 'extensions' | 'history' | 'history_total', Table>>('config', { instance: ctx.instance, ...range(ctx) });
  const st = rowsOf(d.state)[0];
  const sec = el('section', {}, el('h2', {}, 'Configuration'));
  if (!st) { sec.append(el('p', { class: 'empty' }, 'No instance snapshot yet.')); return sec; }
  const yn = (v: unknown) => v == null ? '' : v ? 'yes' : 'no';
  const hist = rowsOf(d.history);
  const changed = new Set(hist.map(r => String(r.name)));
  const tot = rowsOf(d.history_total)[0] ?? {};
  sec.append(el('p', { class: 'meta' }, `Snapshot ${fmtTime(st.snapshot_at)}.`));
  const two = el('div', { class: 'two' });
  two.append(el('div', {}, el('h3', {}, 'Instance state'), props([
    ['platform', String(st.platform ?? '')], ['version', String(st.server_version ?? '')],
    ['role', st.is_replica ? 'replica' : 'primary'], ['started', fmtTime(st.postmaster_start)],
    ['server time zone', String(st.time_zone ?? '')], ['address', `${st.server_addr ?? ''}:${st.server_port ?? ''}`],
    ['shared_buffers', String(st.shared_buffers ?? '')], ['work_mem', String(st.work_mem ?? '')],
    ['max_connections', fmtNum(st.max_connections)], ['wal_level', String(st.wal_level ?? '')],
    ['track_io_timing', String(st.track_io_timing ?? '')], ['log_min_duration_statement', String(st.log_min_duration_statement ?? '')],
    ['data checksums', String(st.data_checksums ?? '')], ['databases', fmtNum(st.database_count)],
    ['pg_stat_statements', yn(st.has_pg_stat_statements)], ['pg_cron', yn(st.has_pg_cron)], ['pgAgent', yn(st.has_pgagent)],
    ['pg_wait_sampling', yn(st.has_wait_sampling)], ['log_fdw', yn(st.has_log_fdw)],
  ])));
  two.append(el('div', {}, el('h3', {}, 'Extensions'), grid(rowsOf(d.extensions), [{ key: 'name' }, { key: 'version' }], 'No extensions listed.')));
  sec.append(two);
  sec.append(el('h3', {}, `Setting changes (${rangeLabel(ctx)})`),
    el('p', { class: 'meta' }, `${hist.length} change(s) in this range; ${fmtNum(tot.changes ?? 0)} recorded in all` + (tot.last_change ? `, the newest ${fmtTime(tot.last_change)}.` : '.')),
    grid(hist, [{ key: 'changed_at', label: 'changed', fmt: fmtTime }, { key: 'name', label: 'setting' },
                { key: 'old_value', label: 'old', wide: true, fmt: v => v == null ? '(default)' : String(v) },
                { key: 'new_value', label: 'new', wide: true, fmt: v => v == null ? '(default)' : String(v) }],
         'No setting changed in this range.'));
  sec.append(el('h3', {}, 'Non-default settings'),
    grid(rowsOf(d.settings), [{ key: 'name', label: 'setting', fmt: v => changed.has(String(v)) ? el('b', { title: 'changed in this range' }, String(v) + ' *') : String(v) },
                              { key: 'value', wide: true }], 'No non-default settings recorded.'));
  return sec;
}

export type { Fleet };

// findings: one instance's parameter findings, or the fleet's scoped to the tag folder picked in the tree,
// each row linking to its instance's Findings tab.
export async function findings(ctx: Ctx): Promise<HTMLElement> {
  if (ctx.instance) return findingsView(ctx.instance);
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await findingsView(undefined, ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'findings'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}
