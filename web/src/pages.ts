import { level, tileLimits, tileWall } from './tiles';
import { DMS, get, Row, rowsOf, Table } from './api';
import { planLink } from './plan';
import { dmsDrainView, findingsView, slowCols, statementOrders, stmtCols } from './borrowed';
import { lineChart } from './chart';
import { Cell, cellClass, cells, cellText, checkLabel, Fleet, fleet, forget, Group, groups, notReadYet, summaryText, tagsOf } from './fleet';
import { Ctx, href, rangeLabel, window_ } from './router';
import { stripGrid } from './timestrip';
import { functionsView, statementDepthView } from './statements';
import { badge, Col, dot, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, showMenu, tile } from './ui';
import { diskReportView } from './host';
import { storageFleetView } from './storage';
import { dbinfoFleetView } from './dbinfo';
import { sessionSetsSection } from './sessionsets';
import { pgConfigSection } from './pgconfig';
import { backupsFleetView } from './backups';
import { corruptionFleetView } from './corruption';
import { extensionsFleetView } from './extensions';
import { versionsFleetView } from './versions';
import { dmsIOView } from './io';
import { applyTagFilter, tagFilterBar, tagUI } from './tree';
import { jobsReportFleetView } from './jobsreport';
import { rolesFleetView } from './roles';
import { indexesFleetView } from './indexes';
import { slowFleetView } from './slow';
import { trendCol } from './stmt_trend';
import { readStmtGroups, stmtGroupsSection, totalWithShare } from './stmt_filter';
import { customReportView } from './custom';
import { whatIsThis } from './sqlview';
import { logsGroupedView } from './logs_grouped';
import { openDumpDialog, openUptimeDialog, summaryCellAction } from './uptimedialog';
import { AckBody, AckData, ackDialog, ackHolds, ackOn, ackWords, addAck, checkAcks, endButton, loadAckSafe, writeButton } from './ack';
import { healthCalendar } from './healthcal';
import { bandClass, cellState, Chip, clockOf, freshness, serverNow, lastCollected, liveChips, measured, silenceButton, silencedMark, statusWord } from './instheader';

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
    { key: 'check_name', label: 'check', fmt: v => checkLabel(v) },
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
    { key: 'platform' },
    { key: 'server_version', label: 'version', wide: true },
    { key: 'is_replica', label: 'role', fmt: v => v ? 'replica' : 'primary' },
    { key: 'postmaster_start', label: 'started', fmt: fmtTime },
    { key: 'total', label: 'sessions', num: true },
    { key: 'active', num: true },
    { key: 'idle_in_txn', label: 'idle in txn', num: true },
    // the instance tile's own limits (tiles.ts blocked): 1 a warning, 5 critical
    { key: 'waiting_lock', label: 'lock waits', num: true, cls: v => { const l = level(v, tileLimits.blocked); return l == null ? '' : ['ok', 'warn', 'crit'][l]; } },
    { key: 'longest_active_secs', label: 'longest active', num: true, fmt: fmtSecs },
    { key: 'oldest_xmin_age', label: 'oldest xmin age', num: true },
    { key: 'collections_failing', label: 'failing', num: true },
    { key: 'activity_at', label: 'last sample', fmt: fmtTime },
  ];
  return el('section', {}, el('h2', {}, 'Instances' + scopeLabel(ctx)), grid(rows, cols, 'No instances yet: run the collector.'));
}



export async function statements(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const order = statementOrders.some(o => o[0] === ctx.order) ? ctx.order! : 'time';
  const minSecs = ctx.minSecs ?? 5;
  const w = { instance: ctx.instance, ...range(ctx) };
  // the slow read and the filter panel's read are separate: a failure of either shows under its own heading, the top statements stay
  const [st, slow, groups, depth, funcs] = await Promise.all([get('statements', { ...w, order, limit: 100 }), get('slow', { ...w, min: minSecs }).catch((e: unknown) => e),
    readStmtGroups(ctx).catch((e: unknown) => e instanceof Error ? e : new Error(String(e))),
    // the depth sections (task 155): a failed read is an error box in its own place, the top statements stay
    statementDepthView(ctx.instance!, range(ctx), rangeLabel(ctx)).catch((e: unknown) => errorBox(e)),
    functionsView(ctx.instance!, range(ctx), rangeLabel(ctx)).catch((e: unknown) => errorBox(e))]);
  const sortBar = el('div', { class: 'subtabs' }, ...statementOrders.map(([k, l]) =>
    el('a', { href: href(ctx, { tab: 'statements', order: k }), class: k === order ? 'on' : '' }, 'by ' + l)),
    el('a', { href: href(ctx, { tab: 'compare' }) }, 'compare with 1 and 7 days earlier'));
  const minIn = el('input', { type: 'number', min: '0', max: '86400', step: '1', value: String(minSecs), style: 'width:5em', 'aria-label': 'seconds at least' });
  minIn.addEventListener('change', () => {
    const v = Number(minIn.value);
    if (Number.isFinite(v)) location.hash = href(ctx, { tab: 'statements', minSecs: Math.min(86400, Math.max(0, Math.trunc(v))) });
  });
  // the share of all statements' time beside a statement's total (pghero): the whole is every statement of the window, not the top 100
  const whole = groups instanceof Error ? 0 : Number(rowsOf(groups.totals)[0]?.total_ms ?? 0);
  const cols = stmtCols(order).map(c => c.key === 'total_exec_ms' ? { ...c, label: 'total time', fmt: (v: unknown) => totalWithShare(v, whole) } : c);
  const stmtRowCols = [{ key: 'plan_link', label: 'plan', fmt: (_: unknown, r: Row) => planLink(ctx.instance!, { queryid: r.queryid, db: r.datname, stmt: r.query }) },
    trendCol(ctx, r => r.queryid == null ? null : { instance: ctx.instance!, queryid: r.queryid, db: r.datname, label: String(r.query ?? '').slice(0, 60) })];
  return el('section', {}, stmtGroupsSection(groups, stmtRowCols, `Statements by database, user and client host (${rangeLabel(ctx)})`),
    el('h2', {}, `Top statements by ${statementOrders.find(o => o[0] === order)?.[1]} (${rangeLabel(ctx)})`), sortBar,
    grid(rowsOf(st), [...cols, ...stmtRowCols], 'No statement deltas in this window (pg_stat_statements missing, or fewer than two snapshots).'),
    depth, funcs,
    el('h3', {}, 'Ran at least ', minIn, ' s in this window'),
    el('p', { class: 'meta' }, 'From the running-queries samples: a duration is a floor (the statement ended between its last sample and the next); an idle-in-transaction session is timed from when it went idle (the Running queries tab filters these by state, user, database and application).'),
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
  const sec = el('section', {}, el('h2', {}, 'DMS replication tasks' + (ctx.instance ? '' : scopeLabel(ctx)) + ' ', whatIsThis('The newest state of each task; the time range applies only to the replication instance IO charts below.', 'DMS replication tasks')));
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
    { key: 'stop_reason', label: 'stop reason' },   // plain text on one line (a wide cell set it in monospace and wrapped it)
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
  if (ris.length) sec.append(await dmsIOView(range(ctx), ctx.instance, ids ? (r: Row) => ids.has(Number(r.instance_id)) : undefined));
  return sec;
}

export { errorBox };

// cellState (what 'until the check changes' compares) lives in instheader.ts: the instance header judges the band
// with it too

// the Summary's own settings, kept per browser: Test Summary Max Height % (DBA Dash's 10 % ... 90 %, 70 % by default)
// and Show Test Summary
const maxHeights = [10, 20, 30, 40, 50, 60, 70, 80, 90];
const readSetting = (k: string): string | null => { try { return localStorage.getItem(k); } catch { return null; } };
const writeSetting = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* private window */ } };

// ---- fleet Summary: DBA Dash's Summary (Checks/Summary.cs, task P08): its test grid over its instance grid, one
// coloured cell per test and instance under DBA Dash's names and in its column order (pgvigil's own tests after them),
// each cell's text as DBA Dash writes it and a link where DBA Dash's is one, the toolbar's Refresh, View, Options and
// Clear Filter and the Refresh Time with its tick; pgvigil's tag filter, Sort and Needs attention strip stay beside it

export async function fleetSummary(ctx: Ctx): Promise<HTMLElement> {
  // the acknowledgements in force and the Needs-attention rates (task 118); a server without them: no ack, no rate
  // the live read (task 177 D29) apart: a failure there never takes the acknowledgements and the rates with it
  const [f, , ad, lvd] = await Promise.all([fleet(), tagUI(), loadAckSafe(['acks', 'attention']), loadAckSafe(['live'])]);
  // the page's one sentence where no acknowledgement can be written at all: every off control of the page points at
  // it (the strip's Acknowledge, the grid's Silence). On a demo serve the door writes for the demo's own instances, and
  // a control of another instance says its own reason beside itself.
  const offP = ad.writable || ad.door ? null : el('p', { class: 'meta' }, `Acknowledge is off: ${ad.reason ?? ''}`);
  ad.note = offP ?? undefined;
  const acks = checkAcks(ad);
  const rates = new Map(rowsOf(ad.attention).map(r => [Number(r.instance_id), r]));
  // PerformanceMonitor's live figures per instance (task 177 D29, instheader.ts): the chips as columns, the freshness
  const lives = new Map(rowsOf((lvd as AckData & { live?: Table | null }).live ?? null).map(r => [Number(r.instance_id), r]));
  const nowMs = serverNow(lives.values().next().value);
  const scope = inTag(ctx, f.instances);
  const filterBar = tagFilterBar(scope);   // built first: it drops a remembered filter this scope no longer carries
  const insts = applyTagFilter(scope);
  type Acked = Record<string, Row>;
  const cellsOf = (r: Row) => r._cells as Record<string, Cell>;
  const rows = insts.map(r => {
    const c = cells(f, r);
    // an acknowledged cell (in force, and for until-change the same state it was given for) loses its colour and its
    // weight: it is counted as acknowledged, never as warning or critical
    const acked: Acked = {};
    for (const g of groups) {
      const a = acks.get(`${String(r.instance_id)}|${g.key}`);
      if (a && !c[g.key].none && c[g.key].level > 0 && ackHolds(a, cellState(c[g.key], g.key))) acked[g.key] = a;
    }
    const lv = lives.get(Number(r.instance_id));
    const chips = liveChips(lv, nowMs);
    const row: Row = { ...r, _cells: c, _acked: acked, _live: lv, _chips: chips, _fresh: freshness(lv, nowMs),
      _worst: Math.max(0, ...groups.filter(g => !acked[g.key]).map(g => c[g.key].level)) };
    for (const ch of chips) row['m_' + ch.key] = ch.band === 'unknown' ? -1 : ch.band === 'crit' ? 2 : ch.band === 'warn' ? 1 : 0;
    row.m_measured = measured(chips)[0];
    for (const g of groups) row['g_' + g.key] = acked[g.key] ? -1 : c[g.key].level * 1000 + c[g.key].n;   // sorts by level, then count
    return row;
  });
  // Sort (Darling's): severity (then name), name, or CPU (the newest host sample, highest first; none last)
  type SortBy = 'severity' | 'name' | 'cpu';
  let sortBy: SortBy = (() => { const v = readSetting('pgvigil.summarySort'); return v === 'name' || v === 'cpu' ? v : 'severity'; })();
  const cpuOf = (r: Row) => { const v = rates.get(Number(r.instance_id))?.cpu_pct; return v == null ? -1 : Number(v); };
  const sortRows = () => rows.sort((a, b) => sortBy === 'name' ? String(a.name).localeCompare(String(b.name))
    : sortBy === 'cpu' ? cpuOf(b) - cpuOf(a) || String(a.name).localeCompare(String(b.name))
    : Number(b._worst) - Number(a._worst) || String(a.name).localeCompare(String(b.name)));
  sortRows();
  const n = [0, 0, 0];
  let offline = 0;
  for (const r of rows) { if (r._fresh === 'offline') offline++; else n[Number(r._worst)]++; }
  // Blocking (recent): every instance's blocking of the last hour, coloured by the worst instance's band
  const blockRecent = rows.reduce((a, r) => a + Number((r._live as Row | undefined)?.blocking ?? 0), 0);
  const blockBandOf = (r: Row) => (r._chips as Chip[]).find(x => x.key === 'blocking')?.band ?? 'unknown';
  const blockWorst = rows.some(r => blockBandOf(r) === 'crit') ? 'crit' : rows.some(r => blockBandOf(r) === 'warn') ? 'warn' : '';
  const nAck = rows.reduce((a, r) => a + Object.keys(r._acked as Acked).length, 0);
  // one line of counts where a row of tiles stood: the grid is the page (DBA Dash's Summary)
  const waiters = insts.reduce((a, r) => a + Number(r.waiting_lock ?? 0), 0);
  const tiles = el('p', { class: 'meta counts' },
    `${insts.length === scope.length ? rows.length : `${rows.length} of ${scope.length}`} instances: `,
    el('span', { class: n[2] ? 'crit' : '' }, `${n[2]} critical`), ', ', el('span', { class: n[1] ? 'warn' : '' }, `${n[1]} warning`), `, ${n[0]} OK, `,
    el('span', { class: offline ? 'muted offline-count' : 'offline-count' }, `${offline} offline`), `, ${nAck} check(s) acknowledged; `,
    el('span', { class: `blocking-recent ${blockWorst}`, title: 'Blocking (recent): the blocking events of every instance in the last hour, coloured by the worst instance\'s band (PerformanceMonitor\'s: 5 / 20 an hour, 10 / 60 seconds of wait)' },
      `${blockRecent} blocking (recent)`),
    waiters ? `; ${waiters} lock waiters now` : '');
  // a cell's page: the column's tab for the instance (DBA Dash's tabMapping), with the view a SQL Server tab opens on
  const cellHref = (g: Group, r: Row): string => {
    const ms = r.engine === 'sqlserver';
    const base = href(ctx, { tab: ms ? g.mssql?.[1] ?? 'summary' : g.tab, instance: Number(r.instance_id), tag: undefined, ...(!ms && g.kind ? { kind: g.kind } : {}) });
    const cv = ms ? g.mssql?.[3] : g.cv;
    return cv ? `${base}${base.includes('?') ? '&' : '?'}cv=${cv}` : base;
  };
  const statusCol = (g: Group): Col => ({
    key: 'g_' + g.key, label: g.label,
    cls: (_v, r) => (r._acked as Acked)[g.key] ? 'status none ack' : 'status ' + cellClass(cellsOf(r)[g.key]),
    fmt: (_v, r) => {
      const all = cellsOf(r), c = all[g.key];
      const ak = (r._acked as Acked)[g.key];
      const t = summaryText(g, c, r, all);
      // the cell's text is DBA Dash's ('View', '1 day, 14 hours', 'Never' ...); the reading behind it ('2 warning')
      // is its name for a screen reader and the export, and the checks behind it its title
      const text = ak ? `ack: ${t.text || cellText(c)}` : t.text;
      const reading = cellText(c);
      const tip = (ak ? ackWords(ak) + (c.detail.length ? '\n' : '') : '') + c.detail.slice(0, 12).join('\n') + (c.detail.length > 12 ? `\n... ${c.detail.length - 12} more` : '');
      if (!t.link) {
        const s = el('span', { 'data-text': reading }, text);
        if (tip) s.title = tip;
        return s;
      }
      const a = el('a', { href: cellHref(g, r), class: 'cell-link', 'aria-label': `${g.label}: ${text}${text === reading ? '' : ` (${reading})`}${ak ? ', ' + ackWords(ak) : ''}`, 'data-text': reading }, text);
      if (tip) a.title = tip;
      summaryCellAction(a, g.key, r);
      return a;
    },
  });
  // a PerformanceMonitor chip as a Summary column: the value in a cell filled by its band (unknown: N/A's grey), the
  // detail its title and part of its name
  const chipCol = (k: string): Col => {
    const label = k === 'cpu' ? 'Total CPU' : k[0].toUpperCase() + k.slice(1);
    return {
      key: 'm_' + k, label, num: false,
      cls: (_v, r) => { const c = (r._chips as Chip[]).find(x => x.key === k); return 'status ' + bandClass(c?.band ?? 'unknown'); },
      fmt: (_v, r) => {
        const c = (r._chips as Chip[]).find(x => x.key === k);
        if (!c) return '';
        const s = el('span', { 'data-text': c.value }, c.value, c.detail ? el('span', { class: 'visually-hidden' }, `, ${c.detail}`) : null);
        if (c.detail) s.title = c.detail;
        return s;
      },
    };
  };
  // DBA Dash's columns in its order, then pgvigil's own tests, then pgvigil's other columns
  const cols: Col[] = [
    // an instance added on Admin > Instances and not read yet says so beside its name (its cells are all 'not yet')
    { key: 'name', label: 'Instance', fmt: (v, r) => { const nr = notReadYet(r); const a = instLink(ctx, String(v), r.instance_id);
      return nr ? el('span', {}, a, ' ', el('span', { class: 'meta not-read' }, nr)) : a; } },
    ...groups.filter(g => g.dd).map(statusCol),
    ...groups.filter(g => !g.dd).map(statusCol),
    // PerformanceMonitor's server card as columns (task 177 D29): each chip's value, its detail in the cell's title
    // and its name, its band the fill; then 'N of M measured', the instance's freshness and its silence
    ...(['cpu', 'threads', 'memory', 'blocking', 'collectors'] as const).map(k => chipCol(k)),
    { key: 'm_measured', label: 'Measured', num: true, fmt: (_v, r) => { const [a, b] = measured(r._chips as Chip[]); return el('span', { 'data-text': `${a} of ${b}` }, `${a} of ${b}`); } },
    { key: '_fresh', label: 'Collection', fmt: (_v, r) => {
      const lv = r._live as Row | undefined, fr = r._fresh as ReturnType<typeof freshness>;
      const t = fr === 'awaiting' ? statusWord.awaiting : fr === 'offline' ? `${statusWord.offline} · ${lastCollected(lv, nowMs)}`
        : `${statusWord[fr]} · last collect ${clockOf(lv?.last_collect_at)}`;
      return el('span', { class: fr === 'offline' ? 'muted' : fr === 'online' ? '' : 'warn' }, t);
    } },
    { key: '_silence', label: 'Alerts', fmt: (_v, r) => {
      const lv = r._live as Row | undefined;
      return el('span', { class: 'silence-cell' }, silencedMark(lv) ?? '', ' ', silenceButton(ad, r, lv, () => { forget(); window.dispatchEvent(new HashChangeEvent('hashchange')); }));
    } },
    { key: 'platform', label: 'Platform' },
    { key: 'is_replica', label: 'Role', fmt: v => v ? 'replica' : 'primary' },
    { key: 'total', label: 'Sessions', num: true },
    // no colour here: the Activity cell judges lock waits, and acknowledging it takes the line out of the colour
    { key: 'waiting_lock', label: 'Lock Waits', num: true },
    { key: 'activity_at', label: 'Last Sample', fmt: fmtTime },
  ];
  const broken = f.checks.filter(r => r.instance_id == null);
  // The test grid (DBA Dash's upper grid): one row per test over the scope the tree gives (the fleet, a tag folder, the
  // tag filter), with how many instances are OK, warning, critical, N/A and acknowledged. A count is a button: it
  // narrows the instance grid below to those instances and shows that test's column only (DBA Dash's FilterByStatus);
  // the same button again, or Clear Filter, shows them all. An acknowledged cell counts under Acknowledged only.
  type Bucket = 'ok' | 'warn' | 'crit' | 'na' | 'ack' | 'bad';   // 'bad': warning or critical (a test name without a page of its own)
  const bucketOf = (r: Row, key: string): Exclude<Bucket, 'bad'> => {
    const c = cellsOf(r)[key];
    if ((r._acked as Acked)[key]) return 'ack';
    return c.none ? 'na' : c.level === 2 ? 'crit' : c.level === 1 ? 'warn' : 'ok';
  };
  // the picked count survives the page's 30-second redraw (sessionStorage, as the focused view survives it)
  let pick: { key: string; label: string; b: Bucket } | null = (() => {
    try {
      const p = JSON.parse(sessionStorage.getItem('pgvigil.summaryPick') ?? 'null') as { key?: string; b?: string } | null;
      const g = p && groups.find(x => x.key === p.key);
      return g && p && (p.b === 'ok' || p.b === 'warn' || p.b === 'crit' || p.b === 'na' || p.b === 'ack' || p.b === 'bad') ? { key: g.key, label: g.label, b: p.b as Bucket } : null;
    } catch { return null; }
  })();
  const setPick = (p: typeof pick) => {
    pick = p;
    try { if (p) sessionStorage.setItem('pgvigil.summaryPick', JSON.stringify({ key: p.key, b: p.b })); else sessionStorage.removeItem('pgvigil.summaryPick'); } catch { /* private window */ }
  };
  const lower = el('div', { class: 'summary-instances' });
  // DBA Dash's toolbar button: enabled while a filter is set
  const clear = el('button', { type: 'button', class: 'clear-filter' }, 'Clear Filter');
  const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const note = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const words: Record<Bucket, string> = { ok: 'OK', warn: 'warning', crit: 'critical', na: 'N/A', ack: 'acknowledged', bad: 'warning or critical' };
  // The focused view (DBA Dash's View > Focused View, the same rules): only what needs a look - the instances with a
  // warning or a critical status, the tests with one, and the status columns that hold one. Out of it, a status column
  // in which every instance is N/A is still left out (DBA Dash's SetStatusColumnVisibility).
  let focus = readSetting('pgvigil.summaryFocus') === '1';
  let showTests = readSetting('pgvigil.summaryShowTests') !== '0';
  let maxPct = (() => { const v = Number(readSetting('pgvigil.summaryTestsMaxPct')); return maxHeights.includes(v) ? v : 70; })();
  const bad = (r: Row, key: string) => { const b = bucketOf(r, key); return b === 'warn' || b === 'crit'; };
  // its own scroll, as DBA Dash's upper pane, at most Test Summary Max Height % of the window: the instance grid below
  // stays on the first screen
  const upper = el('div', { class: 'grid-wrap tests', tabindex: '0', role: 'region', 'aria-label': 'Test Summary' });
  const sizeUpper = () => { upper.style.maxHeight = `${maxPct}vh`; upper.hidden = !showTests; };
  sizeUpper();
  // the instances both grids speak of: all in scope, or in the focused view those with a warning or a critical
  const base = () => focus ? rows.filter(r => groups.some(g => bad(r, g.key))) : rows;
  const countBtns = new Map<string, HTMLElement>();
  const drawLower = () => {
    const live = groups.filter(g => rows.some(r => focus ? bad(r, g.key) : bucketOf(r, g.key) !== 'na'));
    const keep = new Set(live.map(g => 'g_' + g.key));
    let shown = base();
    const inFocus = shown.length;
    if (pick && !live.some(g => g.key === pick!.key) && pick.b !== 'na') setPick(null);   // its test is not on the page (the focused view, a new scope)
    if (pick) shown = rows.filter(r => pick!.b === 'bad' ? bad(r, pick!.key) : bucketOf(r, pick!.key) === pick!.b);
    for (const [k, b] of countBtns) b.setAttribute('aria-pressed', String(!!pick && k === pick.key + '|' + pick.b));
    clear.disabled = !pick;
    said.replaceChildren(pick ? `${shown.length} instance(s) with ${pick.label} ${words[pick.b]}.` : focus ? `${inFocus} of ${rows.length} instance(s) need a look.` : `${rows.length} instance(s).`);
    // a picked test: its column alone among the status columns (DBA Dash's FilterByStatus hides the others)
    const shownCols = cols.filter(c => !c.key.startsWith('g_') || (pick ? c.key === 'g_' + pick.key : keep.has(c.key)));
    // DBA Dash's empty grid is its header row alone; the words stay for a screen reader
    lower.replaceChildren(grid(shown, shownCols,
      rows.length === 0 ? 'No instances yet: run the collector.' : pick ? 'No instance matches.' : focus ? 'Nothing needs a look: every sampled check is OK.' : 'No instance matches.'));
  };
  // The test grid counts every instance in scope, in the focused view too (DBA Dash counts the whole table; the view
  // only chooses which tests are listed), so a count and the rows its click leaves agree: a picked count shows its
  // instances whatever the view (DBA Dash's FilterByStatus replaces the focused filter). It is rebuilt only when the
  // view changes, never on a count click: the clicked button keeps the keyboard focus.
  const drawUpper = () => {
    const tests = groups.map(g => {
      const c: Record<Exclude<Bucket, 'bad'>, number> = { ok: 0, warn: 0, crit: 0, na: 0, ack: 0 };
      for (const r of rows) c[bucketOf(r, g.key)]++;   // every instance in scope, the focused view too (DBA Dash's GroupSummaryByTest)
      // the test name's fill: its worst count (DBA Dash's DgvTests_RowsAdded: critical, then warning, then OK, then
      // acknowledged; N/A only when nothing else)
      return { key: g.key, test: g.label, ...c, _worst: c.crit ? 'crit' : c.warn ? 'warn' : c.ok ? 'ok' : c.ack ? 'none ack' : 'none' } as Row;
    });
    // by the test's name (DBA Dash sorts the grid by its display text); listed while an instance is OK, warning or
    // critical in it (DBA Dash's TestRowFilter), in the focused view while one is warning or critical
    tests.sort((x, y) => String(x.test).localeCompare(String(y.test)));
    const t = tests.filter(x => focus ? Number(x.warn) + Number(x.crit) > 0 : Number(x.ok) + Number(x.warn) + Number(x.crit) > 0);
    countBtns.clear();
    const g = grid(t, testCols, focus ? 'No test has a warning or a critical instance.' : 'No test has a sampled instance.');
    g.querySelector('.grid-wrap')?.removeAttribute('tabindex');   // the pane around it is the scroll region the keyboard reaches
    upper.replaceChildren(g);
  };
  const setFocus = (v: boolean) => {
    focus = v;
    writeSetting('pgvigil.summaryFocus', focus ? '1' : '');
    setPick(null);   // a count picked in the other view spoke of another set of instances
    drawUpper(); drawLower();
  };
  clear.addEventListener('click', () => { setPick(null); drawLower(); });
  const countCol = (b: Bucket, label: string): Col => ({
    key: b, label, num: true,
    cls: v => 'status ' + (b === 'ok' || Number(v) === 0 ? 'ok' : b === 'na' ? 'none' : b === 'ack' ? 'none ack' : b),
    fmt: (v, r) => {
      const bt = el('button', { type: 'button', class: 'cell-link link', 'aria-pressed': 'false', 'aria-label': `${String(r.test)}: ${String(v)} instance(s) ${words[b]}; show them below` }, String(v));
      countBtns.set(String(r.key) + '|' + b, bt);
      bt.addEventListener('click', () => {
        setPick(pick && pick.key === r.key && pick.b === b ? null : { key: String(r.key), label: String(r.test), b });
        drawLower();
      });
      return bt;
    },
  });
  // DBA Dash's test link (Checks/Summary.cs DgvTests_CellContentClick, tabMapping): the test's own page over the scope
  // (Drive Space -> Drives, Backup FULL / LOG -> Backups, Agent Jobs -> Jobs, Snapshot Age -> Collection Dates ...); a
  // test without a page of its own (Memory Dump, Instance Uptime, Is Agent Running, DB Mail ...) filters the instance
  // grid below to the instances where it is a warning or a critical. Never the Daily checks list.
  const rootTabOf: Record<string, string> = {
    full: 'backups', diff: 'backups', log: 'backups', disk: 'drives', jobs: 'jobs', errors: 'collectiondates', snapshot: 'collectiondates',
    checkdb: 'corruption', corruption: 'corruption', logspace: 'dbfiles', filespace: 'dbfiles', replication: 'pgreplication', custom: 'custom',
    dbstate: 'mssqlrisks', activity: 'running', dms: 'dms', tables: 'tablesize', roles: 'roles', indexes: 'indexes', version: 'versions',
  };
  const testLink = (r: Row, text: string): HTMLElement => {
    const tab = rootTabOf[String(r.key)];
    if (tab) return el('a', { class: 'cell-link', href: href(ctx, { tab, instance: undefined }) }, text);
    const b = el('button', { type: 'button', class: 'cell-link link', 'aria-label': `${text}: show the instances where it is a warning or a critical` }, text);
    b.addEventListener('click', () => {
      setPick(pick && pick.key === r.key && pick.b === 'bad' ? null : { key: String(r.key), label: text, b: 'bad' });
      drawLower();
    });
    return b;
  };
  const testCols: Col[] = [
    // the name cell filled with its row's worst state (G02, DBA Dash's DgvTests_RowsAdded)
    { key: 'test', label: 'Test', cls: (_v, r) => 'status ' + String(r._worst), fmt: (v, r) => testLink(r, String(v)) },
    countCol('ok', 'Instance Count OK'), countCol('warn', 'Instance Count Warning'), countCol('crit', 'Instance Count Critical'),
    countCol('na', 'Instance Count N/A'), countCol('ack', 'Instance Count Acknowledged'),
  ];
  // ---- Needs attention (Darling's Fleet Overview strip): one line per instance with a warning or a critical cell not
  // acknowledged, its reasons (blocking / deadlocks of the last 15 minutes as a count and a rate per hour, then the
  // cells), its band, and Acknowledge (a dialog: the checks of the line, until a time and / or until they change)
  const strip = el('div', { class: 'attention', role: 'region', 'aria-label': 'Needs attention' });
  const sortSel = el('select', { 'aria-label': 'Sort' }, ...(['severity', 'name', 'cpu'] as SortBy[]).map(v => el('option', { value: v }, v === 'cpu' ? 'CPU' : v[0].toUpperCase() + v.slice(1))));
  sortSel.value = sortBy;
  const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
  let allLines = false;
  const drawStrip = () => {
    const lines = rows.filter(r => Number(r._worst) > 0).map(r => {
      const c = cellsOf(r), acked = r._acked as Acked;
      const open = groups.filter(g => !c[g.key].none && c[g.key].level > 0 && !acked[g.key]);
      const reasons = open.map(g => `${g.label} ${cellText(c[g.key])}`);
      const rt = rates.get(Number(r.instance_id));
      const per = (k: string, label: string) => {
        const v = Number(rt?.[k] ?? 0), mins = Number(rt?.window_minutes ?? 15);
        return v > 0 ? `${label} ${v} (${(v * 60 / mins).toFixed(1)}/hr)` : '';
      };
      const shown = [per('blocking', 'Blocking'), per('deadlocks', 'Deadlocks'), ...reasons].filter(Boolean);
      const body: AckBody[] = open.map(g => ({ kind: 'ack', instance_id: Number(r.instance_id), check_key: g.key, seen_state: cellState(c[g.key], g.key) }));
      const lvl = Number(r._worst);
      return el('div', { class: 'attention-row', style: `display:flex;gap:.8rem;align-items:baseline;padding:.25rem .5rem;border-left:3px solid var(${lvl === 2 ? '--crit' : '--warn'});margin:.2rem 0` },
        dot(lvl), el('strong', {}, instLink(ctx, String(r.name), r.instance_id)),
        el('span', { style: 'flex:1' }, shown.slice(0, 4).join(' · ') + (shown.length > 4 ? ` · +${shown.length - 4} more` : '')),
        badge(lvl === 2 ? 'Critical' : 'Warning', lvl === 2 ? 'crit' : 'warn'),
        writeButton(ad, 'Acknowledge', `Acknowledge ${String(r.name)}: ${reasons.join(', ')}`, () => ackDialog({
          title: `Acknowledge ${String(r.name)}`,
          what: `${open.map(g => `${g.label} (${cellText(c[g.key])})`).join(', ')}: each cell loses its colour and is counted as acknowledged. Who and when are kept.`,
          body, expiry: true, untilChange: true, noteField: 'optional', after: redraw,
        }), { instance: Number(r.instance_id), name: String(r.name), note: offP ?? undefined }));
    });
    const ackList = rows.flatMap(r => Object.entries(r._acked as Acked).map(([k, a]) => {
      const g = groups.find(x => x.key === k)!;
      return el('li', {}, `${String(r.name)}: ${g.label} (${cellText(cellsOf(r)[k])}), ${ackWords(a)} `,
        ackOn(ad, Number(r.instance_id)) ? endButton(Number(a.ack_id), `Unacknowledge ${String(r.name)} ${g.label}`, redraw, 'Unacknowledge') : null);
    }));
    strip.replaceChildren(...[el('h3', {}, 'Needs attention ', whatIsThis('One line per instance with a warning or a critical cell that is not acknowledged: blocking and deadlocks of the last 15 minutes as a count and a rate per hour, then the cells. Acknowledge takes the line\'s cells out of the colour until a time or until the cell changes; they are counted under Instance Count Acknowledged.', 'Needs attention')),
      lines.length ? el('div', {}, ...(allLines ? lines : lines.slice(0, 8)),
        lines.length > 8 ? (() => { const b = el('button', { type: 'button', class: 'link', 'aria-expanded': String(allLines) }, allLines ? 'Show the first 8' : `Show all ${lines.length}`); b.addEventListener('click', () => { allLines = !allLines; drawStrip(); }); return b; })() : null) : el('p', { class: 'empty' }, rows.length ? 'Nothing needs attention: no warning or critical cell that is not acknowledged.' : 'No instances yet.'),
      ackList.length ? el('details', {}, el('summary', {}, `${ackList.length} acknowledged check(s)`), el('ul', {}, ...ackList)) : null,
      ad.writable ? null : ad.door ? el('p', { class: 'meta', 'data-part': 'demo-door' }, `Demo: what you acknowledge here is saved as user ${ad.door.user}, on the demo's own instances only; nothing reaches a server.`) : offP].filter((x): x is NonNullable<typeof x> => x !== null));
  };
  sortSel.addEventListener('change', () => {
    sortBy = sortSel.value as SortBy;
    writeSetting('pgvigil.summarySort', sortBy);
    sortRows(); drawStrip(); drawLower();
  });
  // ---- DBA Dash's toolbar: Refresh, View, Options, Clear Filter, and the Refresh Time
  // Acknowledge Dumps / Acknowledge Uptime (DBA Dash's Options menu): every Memory Dump or Instance Uptime cell in
  // scope with a warning or a critical is acknowledged until its newest dump or its start changes
  // it answers what it did (the dialogs show it: the page's note sits behind their modal)
  const ackAll = async (key: 'dumps' | 'uptime', what: string): Promise<{ done: number; text: string }> => {
    const said = (done: number, text: string) => { note.textContent = text; return { done, text }; };
    if (!ad.writable && !ad.door) return said(0, `Acknowledge is off: ${ad.reason ?? ''}`);
    const open = rows.filter(r => { const c = cellsOf(r)[key]; return !c.none && c.level > 0 && !(r._acked as Acked)[key]; });
    // on a demo serve the door's instances alone are acknowledged; the others are left alone - never asked for, the
    // door would refuse each - and counted in the answer
    const todo = open.filter(r => ackOn(ad, Number(r.instance_id)));
    const alone = open.length > todo.length ? `; ${open.length - todo.length} instance(s) not the demo's left alone` : '';
    if (!todo.length) return said(0, alone ? `No demo instance has a ${what} cell with a warning or a critical to acknowledge${alone}.` : `No ${what} cell with a warning or a critical to acknowledge.`);
    let done = 0;
    const failed: string[] = [];
    for (const r of todo) {
      try {
        await addAck({ kind: 'ack', instance_id: Number(r.instance_id), check_key: key, seen_state: cellState(cellsOf(r)[key], key), until_change: true });
        done++;
      } catch (e) { failed.push(`${String(r.name)}: ${e instanceof Error ? e.message : String(e)}`); }
    }
    if (done) setTimeout(redraw, 1200);
    return said(done, `${what} acknowledged on ${done} instance(s) until ${key === 'dumps' ? 'a newer dump' : 'the next restart'}${alone}${failed.length ? `; not saved: ${failed.join('; ')}` : ''}.`);
  };
  const tbButton = (label: string, menu?: boolean) => el('button', { type: 'button', class: 'tb-btn', ...(menu ? { 'aria-haspopup': 'menu' } : {}) }, label);
  const refresh = tbButton('Refresh');
  refresh.addEventListener('click', () => { forget(); redraw(); });
  const below = (b: HTMLElement, dx = 0, dy = 0): [number, number] => { const r = b.getBoundingClientRect(); return [r.left + dx, r.bottom + dy]; };
  const tick = (on: boolean, label: string) => `${on ? '✓ ' : ''}${label}`;
  const view = tbButton('View', true);
  view.addEventListener('click', () => showMenu(...below(view), [
    [tick(focus, 'Focused View'), () => setFocus(!focus)],
    [tick(showTests, 'Show Test Summary'), () => { showTests = !showTests; writeSetting('pgvigil.summaryShowTests', showTests ? '1' : '0'); sizeUpper(); }],
  ], view));
  const options = tbButton('Options', true);
  const sub = (items: [string, () => void][]) => () => showMenu(...below(options, 24, 8), items, options);
  options.addEventListener('click', () => showMenu(...below(options), [
    ['Memory Dumps ▸', sub([['Acknowledge Dumps', () => void ackAll('dumps', 'Memory dumps')], ['Configure Thresholds', () => void openDumpDialog(() => ackAll('dumps', 'Memory dumps'))]])],
    ['Instance Uptime ▸', sub([['Acknowledge Uptime', () => void ackAll('uptime', 'Instance uptime')], ['Configure Thresholds', () => void openUptimeDialog(-1, () => ackAll('uptime', 'Instance uptime'))]])],
    ['Test Summary Max Height % ▸', sub(maxHeights.map(p => [tick(p === maxPct, `${p}%`), () => { maxPct = p; writeSetting('pgvigil.summaryTestsMaxPct', String(p)); sizeUpper(); }] as [string, () => void]))],
  ], options));
  // DBA Dash's 'Refresh Time: <time>' with its icon: OK, a warning when the read is over 10 minutes old, critical over 60
  const ageMin = (Date.now() - f.at) / 60000;
  const rt = ageMin > 60 ? ['crit', '✖', 'over an hour old'] : ageMin > 10 ? ['warn', '⚠', 'over 10 minutes old'] : ['ok', '✔', 'current'];
  const refreshTime = el('span', { class: 'refresh-time', style: 'margin-left:auto;white-space:nowrap' }, `Refresh Time: ${new Date(f.at).toLocaleString()} `,
    el('span', { role: 'img', 'aria-label': rt[2], title: rt[2], style: `color:var(--${rt[0]})` }, rt[1]));
  drawStrip(); drawUpper(); drawLower();
  return el('section', { class: 'fleet-summary' }, el('h2', {}, 'Summary' + scopeLabel(ctx)),
    el('div', { class: 'toolbar summary-toolbar', style: 'display:flex;flex-wrap:wrap;gap:.4rem;align-items:center' },
      refresh, view, options, clear, el('label', {}, 'Sort ', sortSel), filterBar, refreshTime),
    note,
    tiles,
    broken.length ? el('p', { class: 'error' }, `${broken.length} check(s) could not run: see Daily checks.`) : null,
    strip,
    upper,
    said,
    lower);
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
  // one line of statuses where two rows of tiles stood: only the groups that are not OK are named, each a link
  // to its tab; the session figures are rows of the Instance list below
  const notOk = groups.filter(g => !c[g.key].none && c[g.key].level > 0);
  // a cell without a read is named; an n/a cell is not (the other engine's check: QS, SQL Agent Alerts ... on PostgreSQL)
  const noRead = groups.filter(g => c[g.key].none && c[g.key].text !== 'n/a');
  sec.append(el('p', { class: 'meta counts' }, notOk.length === 0 ? (noRead.length ? `No warning or critical; no sample for: ${noRead.map(g => g.label).join(', ')}.` : 'Every check group is OK.') : 'Not OK: ',
    ...notOk.flatMap((g, i) => {
      const x = c[g.key];
      const a = el('a', { class: cellClass(x), href: href(ctx, { tab: g.tab }) }, `${g.label} ${cellText(x)}`);
      if (x.detail.length) a.title = x.detail.join('\n');
      return i ? [', ', a] : [a];
    })));
  sec.append(await tileWall(ctx).catch(e => errorBox(e)));
  const two = el('div', { class: 'two' });
  two.append(el('div', {}, el('h3', {}, 'Instance'), props([
    ['version', String(r.server_version ?? '')],
    ['started', fmtTime(r.postmaster_start)],
    ['sessions', `${fmtNum(r.total)} (${fmtNum(r.active)} active, ${fmtNum(r.idle_in_txn)} idle in transaction, ${fmtNum(r.waiting_lock)} waiting on a lock)`],
    ['longest active', fmtSecs(r.longest_active_secs) || '0s'],
    ['oldest xmin age', fmtNum(r.oldest_xmin_age)],
    ['failing collections', fmtNum(r.collections_failing)],
    ['max connections', fmtNum(r.max_connections)],
    ['data checksums', String(r.data_checksums ?? '')],
    ['pg_stat_statements', r.has_pg_stat_statements ? 'yes' : 'no'],
    ['tags', tagsOf(r).join(', ')],
    ['last seen', notReadYet(r) || fmtTime(r.last_seen)],
    ['last activity sample', fmtTime(r.activity_at)],
  ])));
  const checkCols: Col[] = [
    { key: 'severity', fmt: v => badge(String(v), v === 'critical' ? 'crit' : 'warn') },
    { key: 'check_name', label: 'check', fmt: (v, x) => link(String(v), href(ctx, { tab: groupTab(x.check_group) })) },
    { key: 'object' },
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'detail', wide: true },
  ];
  two.append(el('div', { class: 'checks-box' }, el('h3', {}, 'Failing checks'), grid(mine, checkCols, 'All checks pass on this instance.')));
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
  // PerformanceMonitor's Daily Health Calendar (task 177 D29, healthcal.ts): read after the page is drawn
  sec.append(healthCalendar(ctx, 'postgres'));
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


// ---- Logs

// every kind the two log readers store (internal/logparse): the four base ones always get a sub-tab, the rest when they have rows in the range
const logKinds: Record<string, string> = {
  slow: 'slow statements', lock_wait: 'lock waits', deadlock: 'deadlocks', auth_fail: 'failed logins', plan: 'auto_explain plans', corruption: 'corruption',
  connection_limit: 'connection limits', connection_lost: 'connections lost', timeout: 'timeouts', canceled: 'cancellations', autovacuum_cancel: 'autovacuum cancelled',
  vacuum_skipped: 'vacuum skipped', wraparound: 'wraparound', checkpoint_frequent: 'frequent checkpoints', crash: 'crashes', out_of_memory: 'out of memory',
  archive_failed: 'archiving failed', standby_conflict: 'standby conflicts', serialization_failure: 'serialization failures', temp_file: 'temporary files',
  error: 'errors', checkpoint: 'checkpoints',
};
const logKindsAlways = new Set(['slow', 'lock_wait', 'deadlock', 'auth_fail']);
const critKinds = new Set(['deadlock', 'crash', 'out_of_memory', 'wraparound', 'corruption']);

export async function logs(ctx: Ctx): Promise<HTMLElement> {
  const need = needInstance(ctx); if (need) return need;
  const groupedTab = el('a', { href: href(ctx, { tab: 'logs', logKind: 'grouped' }), class: ctx.logKind === 'grouped' ? 'on' : '' }, 'grouped by message');
  if (ctx.logKind === 'grouped') {
    const v = await logsGroupedView(ctx);
    v.insertBefore(el('div', { class: 'subtabs' }, el('a', { href: href(ctx, { tab: 'logs', logKind: '' }) }, 'all events'), groupedTab), v.children[1] ?? null);
    return v;
  }
  const kind = ctx.logKind && logKinds[ctx.logKind] ? ctx.logKind : undefined;
  const win = range(ctx);   // one window for the read and its strip (a preset's 'now' is the read's)
  const d = await get<Record<'counts' | 'events', Table>>('logs', { instance: ctx.instance, kind, ...win });
  const counts = new Map(rowsOf(d.counts).map(r => [String(r.kind), Number(r.events)]));
  const total = [...counts.values()].reduce((a, b) => a + b, 0);
  const tabs = el('div', { class: 'subtabs' },
    groupedTab,
    el('a', { href: href(ctx, { tab: 'logs', logKind: '' }), class: kind ? '' : 'on' }, `all (${total})`),
    ...Object.entries(logKinds).filter(([k]) => logKindsAlways.has(k) || (counts.get(k) ?? 0) > 0 || k === kind).map(([k, l]) => el('a', { href: href(ctx, { tab: 'logs', logKind: k }), class: k === kind ? 'on' : '' }, `${l} (${counts.get(k) ?? 0})`)));
  const cols: Col[] = [
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'kind', fmt: v => badge(logKinds[String(v)] ?? String(v), critKinds.has(String(v)) ? 'crit' : v === 'slow' || v === 'plan' ? '' : 'warn') },
    { key: 'duration_ms', label: 'ms', num: true },
    { key: 'pid', num: true }, { key: 'datname', label: 'db' }, { key: 'usename', label: 'user' }, { key: 'client' },
    { key: 'statement', wide: true }, { key: 'detail', wide: true },
  ];
  return el('section', {}, el('h2', {}, `Log events (${rangeLabel(ctx)})`), tabs,
    stripGrid('Log events', win, rowsOf(d.events), 'at', cols, 'No log events in this range (the logs collection reads the server log where it is configured).', 1000));
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
  // the settings with their unit, default, source, what a change needs and pending restart (pgconfig.ts, task 132)
  sec.append(await pgConfigSection(ctx, changed));
  sec.append(await sessionSetsSection(ctx));
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

// disks and storage: the fleet Disk report and the Storage root, scoped to the tag folder like findings,
// each row linking to its instance's Host or Storage tab.
export async function disks(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await diskReportView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'host'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}
export async function growth(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await dbinfoFleetView(ctx, ids ? r => ids.has(Number(r.instance_id)) : undefined);
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

export async function storage(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await storageFleetView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'storage'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

export async function backups(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await backupsFleetView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'backups'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

export async function corruption(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await corruptionFleetView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'corruption'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

// extensions and versions: the fleet roots (which servers have an extension; every server's version against the
// release table), scoped to the tag folder like findings, each row linking to its instance's tab.
export async function extensions(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await extensionsFleetView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'extensions'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}
export async function versions(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await versionsFleetView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'versions'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

// jobsRoot is the fleet's Jobs page: the failing, missed and over-average jobs of every instance in scope.
export async function jobsRoot(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await jobsReportFleetView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'jobsreport'), ctx);
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

// customRoot is the fleet's Custom report: every custom check of every instance in scope, the worst first (task 61).
export async function customRoot(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await customReportView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'custom'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

// roles is the fleet's Roles page: superusers and login roles per server, in scope.
export async function roles(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await rolesFleetView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'roles'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

// indexes is the fleet's Indexes page: every instance's unused, redundant, duplicate and invalid indexes, per instance in scope.
export async function indexes(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await indexesFleetView(ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'indexes'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}

// slows is the fleet's Slow queries page: the slowest statements over the window, per instance in scope.
export async function slows(ctx: Ctx): Promise<HTMLElement> {
  const ids = ctx.tag ? new Set(inTag(ctx, (await fleet()).instances).map(r => Number(r.instance_id))) : null;
  const view = await slowFleetView(ctx, ids ? r => ids.has(Number(r.instance_id)) : undefined, (name, id) => instLink(ctx, name, id, 'slowqueries'));
  if (ctx.tag) view.querySelector('h2')?.append(scopeLabel(ctx));
  return view;
}
