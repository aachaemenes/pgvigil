// Collection Performance (B6g-3, N42): DBA Dash 4.25.0's Collection Performance report (CollectionPerformanceReport.cs,
// CollectionPerformance_Get.sql) - a collection's duration, CPU, logical reads and import over time and how its runs
// went, opened from the Collection Health grid (Collection, Runs, Avg Duration, Max Duration, Total CPU) over the range
// that grid was read with. Its charts 2 x 2 (Duration, CPU, Logical Reads, Runs), its grid the Hour rows (every run,
// summed over the collectors) and the Run rows (pgvigil keeps a failed or partial run one by one: never all the runs).
// At the root, a tag folder (its instances) or an instance. Data from GET /api/collectionperf.
import { get, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { window_ } from './router';
import { fleet, inTagScope, tagWords } from './fleet';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';
import { lineChart } from './chart';
import { chartHours, perfCapWords, perfCell, perfCutWords } from './chhealth';

const cap = 5000;   // DBA Dash's @MaxRows (the read asks one more)

export async function collectionPerfView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { class: 'collectionperf' }, el('h2', {}, 'Collection Performance'));
  const coll = new URLSearchParams(location.hash.split('?')[1] ?? '').get('collection') ?? '';
  let params: Record<string, string | number | undefined> = {}, folder = ' of the fleet';
  try {
    if (ctx.instance) { params = { instance: ctx.instance }; folder = ''; }
    else if (ctx.tag) {
      const f = await fleet();
      params = { instances: f.instances.filter(r => inTagScope(ctx.tag!, r)).map(r => Number(r.instance_id)).join(',') || '0' };
      folder = ` of ${tagWords(ctx.tag)}`;
    }
  } catch (e) { sec.append(errorBox(e)); return sec; }
  const w = window_(ctx);
  let d: Record<'rows' | 'charts' | 'meta', Table | null>;
  try { d = await get<Record<'rows' | 'charts' | 'meta', Table | null>>('collectionperf', { ...params, ...w, ...(coll ? { collection: coll } : {}) }); }
  catch (e) { sec.append(errorBox(e)); sec.dataset.drawn = '1'; return sec; }
  const all = rowsOf(d.rows), rows = all.slice(0, cap), pts = rowsOf(d.charts), meta = rowsOf(d.meta)[0] ?? {};
  sec.append(el('p', { class: 'meta' }, [
    `${coll ? `Collection ${coll}` : 'Every collection'}${folder}, ${fmtTime(w.from)} to ${fmtTime(w.to)}.`,
    'Hour: every run of the hour, summed over the collectors that ran it. Run: one run that failed or was partial - pgvigil keeps only those one by one, with their duration; their CPU, logical reads and import are kept by the hour (\'hourly only\').',
    perfCutWords(w.from, String(meta.kept_from ?? ''), Number(meta.days ?? 8), v => fmtTime(v)),
    perfCapWords(all.length, cap),
    'Import CPU, Import Logical Reads and Import Lag are not read: pgvigil writes into the repository inside the run that collected (no queue, so no lag) and does not measure the write\'s own CPU or reads.',
  ].filter(Boolean).join(' ')));
  // the charts: DBA Dash's 2 x 2 (ChartLayoutColumns 2), from the hours only; a range under two whole hours has one
  // point at most, said in each chart's place (as Collection Health's)
  const n = (v: unknown) => v == null ? null : Number(v);
  const series = pts.map(r => ({
    snapshot_at: r.at, collect_avg: n(r.collect_avg_ms), collect_max: n(r.collect_max_ms), import_avg: n(r.import_avg_ms), import_max: n(r.import_max_ms),
    cpu_avg: n(r.cpu_avg_ms), cpu_max: n(r.cpu_max_ms), reads: n(r.reads_avg),
    failed: Number(r.failed ?? 0), fp: Number(r.failed ?? 0) + Number(r.partial ?? 0), all: Number(r.failed ?? 0) + Number(r.partial ?? 0) + Number(r.succeeded ?? 0),
  }));
  const hourly = (title: string) => el('div', { class: 'chart' }, el('h3', {}, title), el('p', { class: 'meta' }, 'The charts are hourly: pick a range of 2 hours or more.'));
  const few = chartHours(w.from, w.to) < 2;
  const chart = (title: string, s: { key: string; label: string; color?: string }[], o: Record<string, unknown> = {}) =>
    few ? hourly(title) : lineChart(title, series, s, v => v.toLocaleString(), { marks: false, ...o });
  sec.append(el('div', { class: 'cp-charts', style: 'display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,28rem),1fr));gap:.5rem' },
    chart('Duration (ms)', [{ key: 'collect_avg', label: 'Collect avg' }, { key: 'collect_max', label: 'Collect max' }, { key: 'import_avg', label: 'Import avg' }, { key: 'import_max', label: 'Import max' }], { unit: 'ms' }),
    // DBA Dash's third line (Import avg, the repository's CPU) is not read by pgvigil: said above
    chart('CPU (ms)', [{ key: 'cpu_avg', label: 'Collect avg' }, { key: 'cpu_max', label: 'Collect max' }], { unit: 'ms' }),
    chart('Logical Reads', [{ key: 'reads', label: 'Collect avg' }]),
    // Runs as stacked areas of running totals, as Collection Health's Runs chart (the review of B6.2, part b #14)
    chart('Runs', [{ key: 'failed', label: 'Failed', color: '--crit' }, { key: 'fp', label: 'Partial', color: '--warn' }, { key: 'all', label: 'Succeeded', color: '--ok' }], { stacked: true })));
  const cell = (key: string): Col['fmt'] => (v, r) => perfCell(key, v, r) ?? fmtNum(v);
  const cols: Col[] = [
    ...(ctx.instance ? [] : [{ key: 'instance', label: 'Instance' } as Col]),
    { key: 'collection', label: 'Collection' },
    { key: 'at', label: 'Date', fmt: fmtTime, title: 'When the run ended - or the hour, for an Hour row' },
    { key: 'period', label: 'Period', title: 'Run: one run that failed or was partial (pgvigil keeps no ok run one by one).  Hour: every run of the hour, summed over the collectors that ran it.' },
    { key: 'outcome', label: 'Outcome', fmt: v => v == null ? '' : badge(String(v), v === 'Failed' ? 'crit' : 'warn') },
    { key: 'runs', label: 'Runs', num: true, fmt: fmtNum },
    { key: 'failed', label: 'Failed', num: true, fmt: fmtNum, title: 'Failed runs, those that failed at the write into the repository too (DBA Dash\'s Failed and Import Failed together).' },
    { key: 'partial', label: 'Partial', num: true, fmt: fmtNum, title: 'Runs that ended partial (DBA Dash\'s Retried / Partial: pgvigil retries nothing).' },
    { key: 'duration_ms', label: 'Duration (ms)', num: true, fmt: fmtNum, title: 'The run\'s duration, or the average for an hour (over the runs that ran: skips left out)' },
    { key: 'max_duration_ms', label: 'Max Duration (ms)', num: true, fmt: fmtNum },
    { key: 'cpu_ms', label: 'CPU (ms)', num: true, fmt: cell('cpu_ms'), title: 'CPU on the monitored instance (the run\'s own session on SQL Server, read at the run\'s end), the average over the runs that read it' },
    { key: 'logical_reads', label: 'Logical Reads', num: true, fmt: cell('logical_reads') },
    { key: 'import_ms', label: 'Import (ms)', num: true, fmt: cell('import_ms'), title: 'The write into the repository alone, the average over the runs that wrote or tried to' },
    { key: 'import_cpu_ms', label: 'Import CPU (ms)', num: true, fmt: cell('import_cpu_ms') },
    { key: 'import_logical_reads', label: 'Import Logical Reads', num: true, fmt: cell('import_logical_reads') },
    { key: 'import_lag_s', label: 'Import Lag (sec)', num: true, fmt: cell('import_lag_s') },
  ];
  sec.append(el('div', { class: 'cp-grid' }, grid(rows, cols, 'No run in the range: pick a wider range, or another collection.')));
  sec.dataset.drawn = '1';
  return sec;
}

