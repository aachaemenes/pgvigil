// The instance Performance page (plan task 108, DBA Dash's Performance tab): small charts over the range on one time
// axis (every part is cut into the same steps, and a step without a sample is a gap), each chart's title a link to
// the detailed page. Built with chart.ts's lineChart as it is. Data from /api/performance.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
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
  const types = [...tot.entries()].sort((a, b) => b[1] - a[1]).map(e => e[0]).slice(0, 8);
  const by = new Map<number, Row>();
  for (const r of rows) {
    const t = new Date(String(r.snapshot_at)).getTime();
    if (!by.has(t)) by.set(t, {});
    by.get(t)![String(r.event_type)] = Number(r.ms_s);
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

function titled(chart: HTMLElement, text: string, link: string): HTMLElement {
  const h = chart.querySelector('h3');
  if (h) h.replaceChildren(el('a', { href: link }, text));
  return chart;
}

export async function performanceView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<Parts, Table | null>>('performance', { instance: ctx.instance, ...window_(ctx) });
  const meta = rowsOf(d.meta)[0] ?? {};
  // the shared steps: those of the range's grid that hold a sample in any part (a collection read every 15 minutes
  // in an older stretch would otherwise break every line into dots); every chart takes the same steps
  const seen = new Set<number>();
  for (const k of ['cpu', 'sessions', 'waits', 'db', 'io'] as Parts[]) for (const r of rowsOf(d[k])) seen.add(new Date(String(r.snapshot_at)).getTime());
  const g = rowsOf(d.grid).filter(r => seen.has(new Date(String(r.snapshot_at)).getTime()));
  const ms = meta.engine === 'sqlserver';
  const to = (tab: string, extra: Record<string, string> = {}) => href(ctx, { tab, ...extra });
  const sec = el('section', {}, el('h2', {}, `Performance (${rangeLabel(ctx)})`));
  sec.append(el('p', { class: 'meta' }, `one step = ${fmtNum(Number(meta.step_secs ?? 60) / 60)} min; every chart shares the time axis`));
  const box = el('div', { class: 'charts' });
  const ms_s = (v: number) => fmtNum(v) + ' ms/s';
  if (ms) {
    box.append(el('div', { class: 'chart' }, el('h3', {}, 'CPU'), el('p', { class: 'empty' }, 'not read: no CPU collection on SQL Server yet')));
    box.append(titled(lineChart('Requests', align(g, rowsOf(d.sessions), ['requests', 'blocked', 'sessions']),
      [{ key: 'requests', label: 'requests' }, { key: 'blocked', label: 'blocked' }, { key: 'sessions', label: 'sessions' }]), 'Requests and blocked sessions', to('mssql_running')));
    const w = pivotWaits(g, rowsOf(d.waits));
    box.append(titled(lineChart('Waits', w.rows, w.series, ms_s), 'Waits by category (ms of wait per second, stacked)', to('mssql_waits')));
    box.append(el('div', { class: 'chart' }, el('h3', {}, 'Transactions and IO'), el('p', { class: 'empty' }, 'not read: not collected on SQL Server yet')));
  } else {
    const cpu = rowsOf(d.cpu);
    box.append(cpu.length
      ? titled(lineChart('CPU', align(g, cpu, ['cpu_avg', 'cpu_max', 'iowait_avg']),
          [{ key: 'cpu_avg', label: 'CPU avg %' }, { key: 'cpu_max', label: 'CPU max %' }, { key: 'iowait_avg', label: 'IO wait %' }], v => fmtNum(v) + ' %'), `CPU (${String(meta.host_source ?? 'host')})`, to('host'))
      : el('div', { class: 'chart' }, el('h3', {}, el('a', { href: to('host') }, 'CPU')), el('p', { class: 'empty' }, 'no host read for this instance')));
    box.append(titled(lineChart('Sessions', align(g, rowsOf(d.sessions), ['active', 'idle_in_txn', 'waiting_lock']),
      [{ key: 'active', label: 'active' }, { key: 'idle_in_txn', label: 'idle in transaction' }, { key: 'waiting_lock', label: 'waiting on a lock' }]), 'Sessions by state', to('counters', { kind: 'sessions' })));
    const wr = rowsOf(d.waits), w = pivotWaits(g, wr);
    const src = wr.length && wr[0].source === 'activity' ? ' - from the activity samples' : '';
    box.append(titled(lineChart('Waits', w.rows, w.series, ms_s), `Waits by class (ms of wait per second, stacked${src})`, to('waits')));
    box.append(titled(lineChart('Transactions', align(g, rowsOf(d.db), ['commits_s', 'rollbacks_s']),
      [{ key: 'commits_s', label: 'commits/s' }, { key: 'rollbacks_s', label: 'rollbacks/s' }]), 'Transactions per second', to('counters', { kind: 'db' })));
    const io = align(g, rowsOf(d.io), ['read_ms', 'write_ms', 'read_mb_s', 'write_mb_s', 'cw_read_ms', 'cw_write_ms', 'cw_read_mb_s', 'cw_write_mb_s']);
    const cw = io.some(r => r.cw_read_ms != null);
    box.append(titled(lineChart('IO latency', io, [{ key: 'read_ms', label: 'read ms (pg_stat_io)' }, { key: 'write_ms', label: 'write ms (pg_stat_io)' },
      ...(cw ? [{ key: 'cw_read_ms', label: 'read ms (CloudWatch)' }, { key: 'cw_write_ms', label: 'write ms (CloudWatch)' }] : [])], v => fmtNum(v) + ' ms'), 'IO latency', to('io')));
    box.append(titled(lineChart('IO throughput', io, [{ key: 'read_mb_s', label: 'read MB/s (pg_stat_io)' }, { key: 'write_mb_s', label: 'write MB/s (pg_stat_io)' },
      ...(cw ? [{ key: 'cw_read_mb_s', label: 'read MB/s (CloudWatch)' }, { key: 'cw_write_mb_s', label: 'write MB/s (CloudWatch)' }] : [])], v => fmtNum(v) + ' MB/s'), 'IO throughput', to('counters', { kind: 'io' })));
    box.append(titled(lineChart('Temp', align(g, rowsOf(d.db), ['temp_bytes_s']), [{ key: 'temp_bytes_s', label: 'temp bytes/s' }], v => fmtBytes(v) + '/s'), 'Temp usage', to('counters', { kind: 'db' })));
  }
  sec.append(box);
  const more = ms ? [['Waits', 'mssql_waits'], ['Running queries', 'mssql_running']]
    : [['Load', 'load'], ['Counters', 'counters'], ['IO', 'io'], ['Host', 'host'], ['Waits', 'waits'], ['Memory', 'memory'], ['Pooler', 'pooler']];
  const nav = el('p', { class: 'meta' }, 'detail: ');
  more.forEach(([t, tab], i) => { nav.append(el('a', { href: to(tab) }, t)); if (i < more.length - 1) nav.append(' | '); });
  sec.append(nav);
  return sec;
}
