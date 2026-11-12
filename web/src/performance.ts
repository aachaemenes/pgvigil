// The instance Performance page (plan task 108, DBA Dash's Performance tab): small charts over the range on one time
// axis (every part is cut into the same steps; the lines break where the samples stop for a while), each chart's title
// a link to the detailed page. Built with chart.ts's lineChart as it is. Data from /api/performance.
// Task 177 D29 (Darling's PerformanceMonitor's Overview timeline): a SQL Server instance's buffer pool chart (MB, the
// Memory page's series, /api/mssql/memory part=series), and the zoom's chip: a drag on any chart sets the page's range
// (chart.ts: every chart reads it), and this page then says 'Zoomed: <from> → <to>' with a '×' (Reset zoom) back to
// the range before the drag (PerformanceMonitor 3.12.0's overview-strips.js chip, MIT License, Copyright (c) 2026 Erik
// Darling, Darling Data LLC; the full notice: instheader.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { mssqlCpuTab, mssqlFileIOTab, mssqlMemoryTab, mssqlTempdbTab } from './mssql_perf';
import { Ctx, href, rangeLabel, window_ } from './router';
import { el, fmtBytes, fmtNum } from './ui';

type Parts = 'meta' | 'grid' | 'cpu' | 'sessions' | 'waits' | 'db' | 'io';

// align puts a part's rows onto the shared steps (a missing step = null values: a gap in the line)
function align(gridRows: Row[], rows: Row[], keys: string[]): Row[] {
  const by = new Map(rows.map(r => [new Date(String(r.snapshot_at)).getTime(), r]));
  return gridRows.map(g => {
    const r = by.get(new Date(String(g.snapshot_at)).getTime());
    return Object.fromEntries([['snapshot_at', g.snapshot_at], ...keys.map(k => [k, r ? r[k] ?? null : null])]);
  });
}

// pivotWaits: (step, event_type, ms_s) rows into one row per step with a column per class, the largest first
function pivotWaits(gridRows: Row[], rows: Row[]): { rows: Row[]; series: { key: string; label: string }[] } {
  const tot = new Map<string, number>();
  for (const r of rows) tot.set(String(r.event_type), (tot.get(String(r.event_type)) ?? 0) + Number(r.ms_s));
  // the seven largest classes, the rest summed into 'other' so the top of the stack is the total
  const ranked = [...tot.entries()].sort((a, b) => b[1] - a[1]).map(e => e[0]);
  const types = ranked.length > 8 ? [...ranked.slice(0, 7), 'other'] : ranked;
  const shown = new Set(types);
  const by = new Map<number, Row>();
  for (const r of rows) {
    const t = new Date(String(r.snapshot_at)).getTime();
    if (!by.has(t)) by.set(t, {});
    const k = shown.has(String(r.event_type)) ? String(r.event_type) : 'other';
    const row = by.get(t)!;
    row[k] = Number(row[k] ?? 0) + Number(r.ms_s);
  }
  // stacked: each series is the running total of the classes up to it, so the lines read as a stacked area
  const out = gridRows.map(g => {
    const r = by.get(new Date(String(g.snapshot_at)).getTime());
    const row: Row = { snapshot_at: g.snapshot_at };
    let acc = 0;
    for (const t of types) { if (r) { acc += r[t] == null ? 0 : Number(r[t]); row[t] = acc; } else row[t] = null; }
    return row;
  });
  return { rows: out, series: types.map(t => ({ key: t, label: t + ' (stacked)' })) };
}

// sharedSteps: the grid's steps that hold a sample in any part (a collection read every 15 minutes in an older stretch
// would otherwise break every line into dots), plus one empty step inside each hole more than three times longer than
// the spacing on both sides of it (a collector that stopped; a sparser stretch is even, so it never breaks): the lines
// break there instead of joining across it. Every chart takes these steps.
function sharedSteps(grid: Row[], parts: Row[], stepSecs: number): Row[] {
  const ms = (r: Row) => new Date(String(r.snapshot_at)).getTime();
  const seen = new Set(parts.map(ms));
  const kept = grid.filter(r => seen.has(ms(r)));
  const gaps = kept.slice(1).map((r, i) => ms(r) - ms(kept[i]));   // gaps[i] lies between kept[i] and kept[i + 1]
  const out: Row[] = kept.slice(0, 1);
  for (let i = 1; i < kept.length; i++) {
    const gap = gaps[i - 1], side = Math.max(gaps[i - 2] ?? 0, gaps[i] ?? 0);
    if (side > 0 && gap > 3 * side) out.push({ snapshot_at: new Date(ms(kept[i - 1]) + stepSecs * 1000).toISOString() });
    out.push(kept[i]);
  }
  return out;
}

// the zoom: the address at a pointer press on the charts, then the address the drag made (sessionStorage: it survives
// the page's own redraw); a range change more than 5 seconds after the press is not a drag's
const ZOOM = 'pgvigil.perfZoom';
const ss = {
  get: (k: string): string | null => { try { return sessionStorage.getItem(k); } catch { return null; } },
  set: (k: string, v: string) => { try { sessionStorage.setItem(k, v); } catch { /* private window */ } },
  del: (k: string) => { try { sessionStorage.removeItem(k); } catch { /* private window */ } },
};
function zoomChip(ctx: Ctx): HTMLElement | null {
  const pressed = ss.get(ZOOM + '.before');
  ss.del(ZOOM + '.before');
  if (pressed) {
    const p = JSON.parse(pressed) as { hash: string; at: number };
    if (p.hash !== location.hash && Date.now() - p.at < 5000 && ctx.range.from && ctx.range.to) ss.set(ZOOM, JSON.stringify({ hash: location.hash, back: p.hash }));
  }
  const z = (() => { try { return JSON.parse(ss.get(ZOOM) ?? 'null') as { hash: string; back: string } | null; } catch { return null; } })();
  if (!z || z.hash !== location.hash || !ctx.range.from || !ctx.range.to) return null;
  const reset = el('button', { type: 'button', class: 'link drill-clear', title: 'Reset zoom', 'aria-label': 'Reset zoom' }, '×');
  reset.addEventListener('click', () => { ss.del(ZOOM); location.hash = z.back; });
  return el('p', { class: 'zoom-chip', role: 'status' },
    `Zoomed: ${new Date(ctx.range.from).toLocaleString()} → ${new Date(ctx.range.to).toLocaleString()} `, reset);
}

function titled(chart: HTMLElement, text: string, link: string): HTMLElement {
  const h = chart.querySelector('h3');
  if (h) h.replaceChildren(el('a', { href: link }, text));
  return chart;
}

export async function performanceView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<Parts, Table | null>>('performance', { instance: ctx.instance, ...window_(ctx) });
  const meta = rowsOf(d.meta)[0] ?? {};
  const g = sharedSteps(rowsOf(d.grid), (['cpu', 'sessions', 'waits', 'db', 'io'] as Parts[]).flatMap(k => rowsOf(d[k])), Number(meta.step_secs ?? 60));
  const ms = meta.engine === 'sqlserver';
  const to = (tab: string, extra: Record<string, string> = {}) => href(ctx, { tab, ...extra });
  const sec = el('section', {}, el('h2', {}, `Performance (${rangeLabel(ctx)})`));
  sec.append(el('p', { class: 'meta' }, `one step = ${fmtNum(Number(meta.step_secs ?? 60) / 60)} min; every chart shares the time axis; a drag on a chart zooms them all`));
  const chip = zoomChip(ctx);
  if (chip) sec.append(chip);
  const box = el('div', { class: 'charts' });
  box.addEventListener('pointerdown', () => ss.set(ZOOM + '.before', JSON.stringify({ hash: location.hash, at: Date.now() })));
  const ms_s = (v: number) => fmtNum(v) + ' ms/s';
  if (ms) {
    const cpu = rowsOf(d.cpu);
    box.append(cpu.length
      ? titled(lineChart('CPU', align(g, cpu, ['sql_avg', 'cpu_avg', 'cpu_max']),
          [{ key: 'sql_avg', label: 'SQL Server %' }, { key: 'cpu_avg', label: 'total %' }, { key: 'cpu_max', label: 'total max %' }], v => fmtNum(v) + ' %'),
          cpu.some(r => r.machine_read) ? 'CPU (scheduler monitor: SQL Server and the machine)' : 'CPU (scheduler monitor: SQL Server only, a Linux host)', to(mssqlCpuTab))
      : el('div', { class: 'chart' }, el('h3', {}, el('a', { href: to(mssqlCpuTab) }, 'CPU')),
          el('p', { class: 'empty' }, 'no CPU read in this range: the mssql_cpu collection runs every minute and needs VIEW SERVER STATE')));
    box.append(titled(lineChart('Requests', align(g, rowsOf(d.sessions), ['requests', 'blocked', 'sessions']),
      [{ key: 'requests', label: 'requests' }, { key: 'blocked', label: 'blocked' }, { key: 'sessions', label: 'sessions' }]), 'Requests and blocked sessions', to('mssql_running')));
    const w = pivotWaits(g, rowsOf(d.waits));
    box.append(titled(lineChart('Waits', w.rows, w.series, ms_s, { stacked: true }), 'Waits by category (ms of wait per second, stacked)', to('mssql_waits')));
    // the buffer pool (PerformanceMonitor's 'Buffer pool (MB)' strip: Database Cache Memory) with Total Server Memory
    const mem = await get<{ series: Table | null }>('mssql/memory', { instance: ctx.instance, ...window_(ctx), part: 'series' }).catch(() => null);
    const memRaw = rowsOf(mem?.series ?? null);
    // on the page's shared steps (the same window and step as /api/performance); the memory read's own points only
    // where its steps meet none of the page's
    const memAligned = align(g, memRaw, ['buffer_pool_mb', 'total_mb']);
    const memRows = memAligned.some(r => r.buffer_pool_mb != null) ? memAligned : memRaw;
    box.append(memRaw.length
      ? titled(lineChart('Buffer pool', memRows, [{ key: 'buffer_pool_mb', label: 'buffer pool' }, { key: 'total_mb', label: 'total server' }], v => fmtNum(v) + ' MB'),
          'Buffer pool (MB)', to(mssqlMemoryTab))
      : el('div', { class: 'chart' }, el('h3', {}, el('a', { href: to(mssqlMemoryTab) }, 'Buffer pool (MB)')),
          el('p', { class: 'empty' }, 'no memory read in this range: the mssql_memory collection runs every minute')));
    box.append(titled(lineChart('Transactions', align(g, rowsOf(d.db), ['batch_s', 'transactions_s', 'compiles_s']),
      [{ key: 'batch_s', label: 'batch requests/s' }, { key: 'transactions_s', label: 'transactions/s' }, { key: 'compiles_s', label: 'compilations/s' }]),
      'Batch requests and transactions per second', to(mssqlCpuTab)));
    const io = align(g, rowsOf(d.io), ['read_ms', 'write_ms', 'read_mb_s', 'write_mb_s']);
    box.append(titled(lineChart('IO latency', io, [{ key: 'read_ms', label: 'read ms' }, { key: 'write_ms', label: 'write ms' }], v => fmtNum(v) + ' ms'),
      'IO latency (all database files)', to(mssqlFileIOTab)));
    box.append(titled(lineChart('IO throughput', io, [{ key: 'read_mb_s', label: 'read MB/s' }, { key: 'write_mb_s', label: 'write MB/s' }], v => fmtNum(v) + ' MB/s'),
      'IO throughput (all database files)', to(mssqlFileIOTab)));
  } else {
    const cpu = rowsOf(d.cpu);
    box.append(cpu.length
      ? titled(lineChart('CPU', align(g, cpu, ['cpu_avg', 'cpu_max', 'iowait_avg']),
          [{ key: 'cpu_avg', label: 'CPU avg %' }, { key: 'cpu_max', label: 'CPU max %' }, { key: 'iowait_avg', label: 'IO wait %' }], v => fmtNum(v) + ' %',
          // the host check's own lines (0021: 'CPU over 90 % for 10 minutes', critical from 98 %)
          { lines: [{ value: 90, label: 'warning 90 %', kind: 'threshold', level: 'warning' }, { value: 98, label: 'critical 98 %', kind: 'threshold', level: 'critical' }] }), `CPU (${String(meta.host_source ?? 'host')})`, to('host'))
      : el('div', { class: 'chart' }, el('h3', {}, el('a', { href: to('host') }, 'CPU')), el('p', { class: 'empty' }, 'no host read for this instance')));
    box.append(titled(lineChart('Sessions', align(g, rowsOf(d.sessions), ['active', 'idle_in_txn', 'waiting_lock']),
      [{ key: 'active', label: 'active' }, { key: 'idle_in_txn', label: 'idle in transaction' }, { key: 'waiting_lock', label: 'waiting on a lock' }]), 'Sessions by state', to('counters', { kind: 'sessions' })));
    const wr = rowsOf(d.waits), w = pivotWaits(g, wr);
    const src = wr.length && wr[0].source === 'activity' ? ' - from the activity samples' : '';
    box.append(titled(lineChart('Waits', w.rows, w.series, ms_s, { stacked: true }), `Waits by class (ms of wait per second, stacked${src})`, to('waits')));
    box.append(titled(lineChart('Transactions', align(g, rowsOf(d.db), ['commits_s', 'rollbacks_s']),
      [{ key: 'commits_s', label: 'commits/s' }, { key: 'rollbacks_s', label: 'rollbacks/s' }], undefined, { unit: 'commits/s', y2: { keys: ['rollbacks_s'], unit: 'rollbacks/s' } }), 'Transactions per second', to('counters', { kind: 'db' })));
    const io = align(g, rowsOf(d.io), ['read_ms', 'write_ms', 'read_mb_s', 'write_mb_s', 'cw_read_ms', 'cw_write_ms', 'cw_read_mb_s', 'cw_write_mb_s']);
    const cw = io.some(r => r.cw_read_ms != null);
    box.append(titled(lineChart('IO latency', io, [{ key: 'read_ms', label: 'read ms (pg_stat_io)' }, { key: 'write_ms', label: 'write ms (pg_stat_io)' },
      ...(cw ? [{ key: 'cw_read_ms', label: 'read ms (CloudWatch)' }, { key: 'cw_write_ms', label: 'write ms (CloudWatch)' }] : [])], v => fmtNum(v) + ' ms'), 'IO latency', to('io')));
    box.append(titled(lineChart('IO throughput', io, [{ key: 'read_mb_s', label: 'read MB/s (pg_stat_io)' }, { key: 'write_mb_s', label: 'write MB/s (pg_stat_io)' },
      ...(cw ? [{ key: 'cw_read_mb_s', label: 'read MB/s (CloudWatch)' }, { key: 'cw_write_mb_s', label: 'write MB/s (CloudWatch)' }] : [])], v => fmtNum(v) + ' MB/s'), 'IO throughput', to('counters', { kind: 'io' })));
    box.append(titled(lineChart('Temp', align(g, rowsOf(d.db), ['temp_bytes_s']), [{ key: 'temp_bytes_s', label: 'temp bytes/s' }], v => fmtBytes(v) + '/s'), 'Temp usage', to('counters', { kind: 'db' })));
  }
  sec.append(box);
  const more = ms ? [['CPU', mssqlCpuTab], ['Memory', mssqlMemoryTab], ['File IO', mssqlFileIOTab], ['TempDB', mssqlTempdbTab], ['Metrics', 'counters'], ['Waits', 'mssql_waits'], ['Running queries', 'mssql_running']]
    : [['Load', 'load'], ['Metrics', 'counters'], ['IO', 'io'], ['Host', 'host'], ['Waits', 'waits'], ['Memory', 'memory'], ['Pooler', 'pooler']];
  const nav = el('p', { class: 'meta' }, 'detail: ');
  more.forEach(([t, tab], i) => { nav.append(el('a', { href: to(tab) }, t)); if (i < more.length - 1) nav.append(' | '); });
  sec.append(nav);
  return sec;
}
