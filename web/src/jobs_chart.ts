// A picked job's charts and step grid (task 132; DBA Dash's Job Stats: a duration and run-count chart over the range
// and one row per step with its outcomes and durations, and the step cut of the history). Two charts on one time
// axis: the average and longest duration per bucket, and the runs per bucket, succeeded and failed stacked. Under
// them the step grid; a step's button cuts the job's history (runs, counts and both charts) to that step. SQL Server
// stores msdb's step rows; pg_cron has no steps and pgAgent's step log rides on the run, so a PostgreSQL job has the
// outcome row alone and no cut. Data: the stats, series and series_meta parts of /api/jobs/history. The Jobs panel
// (mssql_jobs.ts) calls jobChartSection above its runs grid.
import { Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Col, el, fmtNum, fmtSecs, fmtTime, grid } from './ui';

export interface JobChartParts { stats?: Table | null; series?: Table | null; series_meta?: Table | null }
export interface JobChartOptions {
  engine: 'pg' | 'mssql';
  step?: number;                              // the step the history is cut to; unset = the job's own outcomes
  onStep?: (step?: number) => void;           // the page redraws the history for that step
}

const dur = (v: unknown) => v == null ? '' : Number(v) < 60 ? fmtNum(Math.round(Number(v) * 10) / 10) + ' s' : fmtSecs(v);
const bucketLabel = (secs: number) => secs % 86400 === 0 ? `${secs / 86400} d` : secs % 3600 === 0 ? `${secs / 3600} h` : `${Math.round(secs / 60)} min`;

export function jobChartSection(d: JobChartParts, o: JobChartOptions): HTMLElement {
  const box = el('div', { class: 'jobcharts' });
  const series = rowsOf(d.series), stats = rowsOf(d.stats), meta = rowsOf(d.series_meta)[0] ?? {};
  const cut = o.step != null ? stats.find(r => Number(r.step_id) === o.step) : undefined;
  const what = o.step != null ? `step ${o.step}${cut?.step_name ? ' ' + String(cut.step_name) : ''}` : 'the job';
  const total = series.reduce((a, r) => a + Number(r.runs ?? 0), 0);
  if (!total) {
    box.append(el('p', { class: 'empty' }, `No run of ${what} started in this range: nothing to chart.`));
  } else {
    // the run counts as running totals: lineChart's stacked bands take them summed (each band down to the one below)
    const stacked = series.map(r => {
      const ok = Number(r.succeeded ?? 0), bad = Number(r.failed ?? 0), other = Number(r.other ?? 0);
      return { snapshot_at: r.snapshot_at, s_ok: ok, s_bad: ok + bad, s_other: ok + bad + other } as Row;
    });
    const anyOther = series.some(r => Number(r.other ?? 0) > 0);
    box.append(
      el('p', { class: 'meta' }, `${fmtNum(total)} run(s) of ${what} in buckets of ${bucketLabel(Number(meta.step_secs ?? 60))}. `
        + 'A bucket without a run counts 0 and has no duration; a run that took 0 s still shows in the run count.'),
      el('div', { class: 'charts' },
        lineChart(`Duration of ${what}`, series, [{ key: 'avg_s', label: 'average' }, { key: 'max_s', label: 'longest' }], v => dur(v)),
        lineChart(`Runs of ${what}`, stacked,
          [{ key: 's_ok', label: 'succeeded' }, { key: 's_bad', label: 'failed' },
           ...(anyOther ? [{ key: 's_other', label: 'other (cancelled, retry, running)' }] : [])],
          v => fmtNum(v), { stacked: true })));
  }
  const pickCell = (r: Row): string | Node => {
    const id = Number(r.step_id), isCut = id === 0 ? o.step == null : o.step === id;
    if (isCut) return 'shown below';
    if (!o.onStep) return '';
    const b = el('button', { type: 'button', class: 'link' }, id === 0 ? 'Show the job\'s runs' : `Show step ${id} only`);
    b.addEventListener('click', () => o.onStep!(id === 0 ? undefined : id));
    return b;
  };
  const cols: Col[] = [
    { key: 'step_id', label: 'step', num: true, fmt: v => Number(v) === 0 ? '' : String(v) },
    { key: 'step_name', label: 'name' },
    { key: 'failed', num: true },
    { key: 'succeeded', num: true },
    { key: 'retry', num: true },
    { key: 'cancelled', num: true },
    { key: 'avg_s', label: 'average', num: true, fmt: dur },
    { key: 'max_s', label: 'longest', num: true, fmt: dur },
    { key: 'min_s', label: 'shortest', num: true, fmt: dur },
    { key: 'total_s', label: 'total', num: true, fmt: dur },
    { key: 'last_run_at', label: 'last run', fmt: fmtTime },
    ...(o.engine === 'mssql' ? [{ key: '_pick', label: 'history', fmt: (_v: unknown, r: Row) => pickCell(r) } as Col] : []),
  ];
  box.append(el('h4', {}, 'Steps'),
    grid(stats, cols, 'No run of this job in this range.'),
    el('p', { class: 'meta' }, o.engine === 'mssql'
      ? 'One row per step with a run in the range; the first row is the job\'s own outcome. A step\'s button cuts the charts, the counts and the runs below to that step\'s rows.'
      : 'A PostgreSQL job has the outcome row alone: pg_cron has no steps, and pgAgent\'s step log is kept on the run (its failed step is in the runs below).'));
  return box;
}
