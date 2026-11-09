import uPlot from 'uplot';
import { Row } from './api';
import { el } from './ui';

const palette = ['#2f6fdf', '#d9480f', '#2b8a3e', '#ae3ec9', '#e8590c', '#1098ad', '#5c940d', '#c2255c'];

// lineChart draws one chart of the named series over snapshot_at.
export function lineChart(title: string, rows: Row[], series: { key: string; label: string }[],
                          fmt: (v: number) => string = v => v.toLocaleString()): HTMLElement {
  const box = el('div', { class: 'chart' }, el('h3', {}, title));
  if (rows.length < 2) { box.append(el('p', { class: 'empty' }, 'Not enough snapshots in this window.')); return box; }
  const xs = rows.map(r => new Date(String(r.snapshot_at)).getTime() / 1000);
  const data: uPlot.AlignedData = [xs, ...series.map(s => rows.map(r => r[s.key] == null ? null : Number(r[s.key])))];
  const holder = el('div');
  box.append(holder);
  const opts: uPlot.Options = {
    width: 560, height: 220,
    series: [{}, ...series.map((s, i) => ({ label: s.label, stroke: palette[i % palette.length], width: 1.5,
                                            value: (_u: uPlot, v: number | null) => v == null ? '' : fmt(v) }))],
    axes: [{}, { values: (_u: uPlot, vs: number[]) => vs.map(v => fmt(v)), size: 70 }],
    scales: { x: { time: true } },
  };
  // size to the container once it is in the page
  requestAnimationFrame(() => {
    opts.width = Math.max(300, holder.clientWidth || 560);
    new uPlot(opts, data, holder);
  });
  return box;
}
