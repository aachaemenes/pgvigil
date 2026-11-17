// A custom report's charts (parity set 3, task 10; DBA Dash's Add Chart, L130-L135): drawn from a result set as SVG -
// Line, StackedArea, Column, StackedColumn, Pie (a doughnut) and Scatter - over a time, number or category X. Each
// point keeps its row (data-row) so a click on it opens the drill-down of the report's link (customreports.ts). The
// page's shell charts (chart.ts) are uPlot canvases for time series; a report's X may be a category, and its points
// are links, so these draw their own marks.
import { seriesColors } from './chart';
import { el, fmtNum, fmtTime } from './ui';

export const CHART_TYPES = ['StackedArea', 'StackedColumn', 'Column', 'Line', 'Pie', 'Scatter'] as const;
export type ChartType = typeof CHART_TYPES[number];
export const chartTypeNames: Record<ChartType, string> = {
  StackedArea: 'Stacked area', StackedColumn: 'Stacked column', Column: 'Column', Line: 'Line', Pie: 'Pie (doughnut)', Scatter: 'Scatter',
};
// a chart of a report: its result set, the X column, the metric columns, the column whose values split them into series;
// x_range: the X bound to the page's time window; overlay: another set's metric drawn over it as a line; hidden_when:
// the parameter whose value, when set, hides the chart
export interface ChartDef {
  type: ChartType; set: number; x: string; metrics: string[]; series?: string; title?: string;
  x_range?: boolean; overlay?: { set: number; metric: string }; hidden_when?: string;
}
export interface ChartSet { columns: string[]; rows: unknown[][] }

const NS = 'http://www.w3.org/2000/svg';
const svgEl = (tag: string, attrs: Record<string, string | number>, ...kids: (Node | string)[]) => {
  const e = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
  e.append(...kids);
  return e;
};
const W = 640, H = 260, M = { l: 56, r: 12, t: 12, b: 34 };

type XKind = 'time' | 'num' | 'cat';
interface Series { name: string; pts: { x: unknown; y: number; row: number }[]; line?: boolean }

const asTime = (v: unknown) => typeof v === 'string' && /^\d{4}-\d\d-\d\d[T ]/.test(v) ? Date.parse(v) : NaN;
const asNum = (v: unknown) => v == null || v === '' ? NaN : Number(v);

// shape: the series a chart draws, from its set's rows (a series per metric, or per metric and series value)
function shape(def: ChartDef, set: ChartSet, over?: ChartSet): { kind: XKind; series: Series[]; cats: string[] } | string {
  const ix = (c: string) => set.columns.findIndex(x => x.toLowerCase() === c.toLowerCase());
  const xi = ix(def.x), si = def.series ? ix(def.series) : -1, mis = def.metrics.map(ix);
  if (xi < 0) return `the result set has no column ${def.x}`;
  const bad = def.metrics.filter((_, i) => mis[i] < 0);
  if (bad.length) return `the result set has no column ${bad.join(', ')}`;
  if (def.series && si < 0) return `the result set has no column ${def.series}`;
  const xs = set.rows.map(r => r[xi]);
  const kind: XKind = xs.length && xs.every(v => v == null || !isNaN(asTime(v))) ? 'time' : xs.every(v => v == null || !isNaN(asNum(v))) ? 'num' : 'cat';
  const by = new Map<string, Series>();
  set.rows.forEach((r, row) => {
    mis.forEach((mi, k) => {
      const y = asNum(r[mi]);
      if (isNaN(y)) return;
      const name = si >= 0 ? (def.metrics.length > 1 ? `${def.metrics[k]} ${String(r[si] ?? '')}` : String(r[si] ?? '(none)')) : def.metrics[k];
      let s = by.get(name);
      if (!s) by.set(name, s = { name, pts: [] });
      s.pts.push({ x: r[xi], y, row });
    });
  });
  const series = [...by.values()];
  if (def.overlay && over) {
    const oi = over.columns.findIndex(x => x.toLowerCase() === def.overlay!.metric.toLowerCase()), ox = over.columns.findIndex(x => x.toLowerCase() === def.x.toLowerCase());
    if (oi >= 0 && ox >= 0) series.push({ name: `${def.overlay.metric} (overlay)`, line: true, pts: over.rows.map((r, row) => ({ x: r[ox], y: asNum(r[oi]), row: -1 - row })).filter(p => !isNaN(p.y)) });
  }
  const cats = kind === 'cat' ? [...new Set(xs.map(v => String(v ?? '')))] : [];
  return { kind, series, cats };
}

const tickWords = (kind: XKind, v: number) => kind === 'time' ? fmtTime(new Date(v).toISOString()) : fmtNum(v);

// drawChart: one chart's box (.cr-chart, data-type), its SVG and a line of words under it (what it shows, or why not)
export function drawChart(def: ChartDef, sets: ChartSet[], o: { window?: { from: number; to: number }; onPoint?: (row: number) => void } = {}): HTMLElement {
  const box = el('figure', { class: 'cr-chart' });
  box.dataset.type = def.type;
  if (def.x_range) box.dataset.xRange = 'window';
  const title = def.title || `${def.metrics.join(', ')} by ${def.x}${def.series ? ' and ' + def.series : ''}`;
  box.append(el('figcaption', {}, title));
  const set = sets[def.set];
  if (!set) { box.append(el('p', { class: 'meta' }, `No result set ${def.set + 1} in this run.`)); return box; }
  const sh = shape(def, set, def.overlay ? sets[def.overlay.set] : undefined);
  if (typeof sh === 'string') { box.append(el('p', { class: 'meta' }, `Not drawn: ${sh}.`)); return box; }
  if (!sh.series.some(s => s.pts.length)) { box.append(el('p', { class: 'meta' }, 'Not drawn: no number in the metric columns.')); return box; }
  const colors = seriesColors(), color = (i: number) => colors[i % colors.length];
  const svg = svgEl('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', 'aria-label': title, class: 'cr-svg' });
  box.append(svg);
  const legend = el('p', { class: 'meta cr-legend' }, ...sh.series.flatMap((s, i) => [el('span', { style: `color:${color(i)}` }, '■'), ` ${s.name} `]));
  if (def.type === 'Pie') {
    // a doughnut: the first metric summed per X value
    const sums = new Map<string, number>();
    for (const s of sh.series) for (const p of s.pts) sums.set(String(p.x ?? ''), (sums.get(String(p.x ?? '')) ?? 0) + Math.max(0, p.y));
    const total = [...sums.values()].reduce((a, b) => a + b, 0);
    if (!total) { box.replaceChildren(box.firstChild!, el('p', { class: 'meta' }, 'Not drawn: the values add up to 0.')); return box; }
    const cx = W / 2, cy = H / 2, r1 = H / 2 - 10, r0 = r1 * 0.55;
    let a = -Math.PI / 2;
    [...sums].forEach(([k, v], i) => {
      const b = a + 2 * Math.PI * v / total, large = b - a > Math.PI ? 1 : 0, pt = (r: number, t: number) => `${cx + r * Math.cos(t)},${cy + r * Math.sin(t)}`;
      const d = v >= total ? `M${pt(r1, 0)}A${r1},${r1} 0 1 1 ${pt(r1, Math.PI)}A${r1},${r1} 0 1 1 ${pt(r1, 0)}Z` : `M${pt(r1, a)}A${r1},${r1} 0 ${large} 1 ${pt(r1, b)}L${pt(r0, b)}A${r0},${r0} 0 ${large} 0 ${pt(r0, a)}Z`;
      svg.append(svgEl('path', { d, fill: color(i), class: 'series' }, svgEl('title', {}, `${k}: ${fmtNum(v)} (${fmtNum(100 * v / total)} %)`)));
      a = b;
    });
    box.append(el('p', { class: 'meta cr-legend' }, ...[...sums.keys()].flatMap((k, i) => [el('span', { style: `color:${color(i)}` }, '■'), ` ${k} `])));
    return box;
  }
  // the X scale: a band per category, else the values' span (or the page's window)
  const allX = sh.series.flatMap(s => s.pts.map(p => sh.kind === 'time' ? asTime(p.x) : asNum(p.x))).filter(v => !isNaN(v));
  let x0 = Math.min(...allX), x1 = Math.max(...allX);
  if (def.x_range && o.window && sh.kind === 'time') { x0 = o.window.from; x1 = o.window.to; }
  if (x0 === x1) { x0 -= 1; x1 += 1; }
  const band = sh.kind === 'cat' ? (W - M.l - M.r) / Math.max(1, sh.cats.length) : 0;
  const px = (v: unknown) => sh.kind === 'cat' ? M.l + band * (sh.cats.indexOf(String(v ?? '')) + 0.5) : M.l + (W - M.l - M.r) * (((sh.kind === 'time' ? asTime(v) : asNum(v)) - x0) / (x1 - x0));
  // the Y scale: stacked types add up per X
  const stacked = def.type === 'StackedArea' || def.type === 'StackedColumn';
  const own = sh.series.filter(s => !s.line), keyOf = (v: unknown) => String(v ?? '');
  const tops = new Map<string, number>();
  if (stacked) for (const s of own) for (const p of s.pts) tops.set(keyOf(p.x), (tops.get(keyOf(p.x)) ?? 0) + p.y);
  const ys = stacked ? [...tops.values(), ...sh.series.filter(s => s.line).flatMap(s => s.pts.map(p => p.y))] : sh.series.flatMap(s => s.pts.map(p => p.y));
  const y0 = Math.min(0, ...ys), y1 = Math.max(...ys, y0 + 1);
  const py = (v: number) => H - M.b - (H - M.t - M.b) * ((v - y0) / (y1 - y0));
  // the axes: the zero line, the Y's ends, three X words
  svg.append(svgEl('line', { x1: M.l, x2: W - M.r, y1: py(Math.max(0, y0)), y2: py(Math.max(0, y0)), class: 'cr-axis' }),
    svgEl('text', { x: M.l - 4, y: py(y1) + 4, 'text-anchor': 'end', class: 'cr-tick' }, fmtNum(y1)),
    svgEl('text', { x: M.l - 4, y: py(y0) + 4, 'text-anchor': 'end', class: 'cr-tick' }, fmtNum(y0)));
  if (sh.kind === 'cat') sh.cats.slice(0, 12).forEach(c => svg.append(svgEl('text', { x: px(c), y: H - 12, 'text-anchor': 'middle', class: 'cr-tick' }, c.length > 14 ? c.slice(0, 13) + '...' : c)));
  else [x0, (x0 + x1) / 2, x1].forEach((v, i) => svg.append(svgEl('text', { x: M.l + (W - M.l - M.r) * i / 2, y: H - 12, 'text-anchor': ['start', 'middle', 'end'][i], class: 'cr-tick' }, tickWords(sh.kind, v))));
  const base = new Map<string, number>();
  own.forEach((s, i) => {
    const g = svgEl('g', { class: 'series', fill: color(i), stroke: color(i) });
    svg.append(g);
    const pts = [...s.pts].sort((a, b) => px(a.x) - px(b.x));
    if (def.type === 'Column' || def.type === 'StackedColumn') {
      const n = def.type === 'Column' ? own.length : 1, wBand = sh.kind === 'cat' ? band : (W - M.l - M.r) / Math.max(2, new Set(pts.map(p => keyOf(p.x))).size + 1);
      const w = Math.max(2, wBand * 0.8 / n);
      for (const p of pts) {
        const under = stacked ? base.get(keyOf(p.x)) ?? 0 : 0, top = under + p.y;
        if (stacked) base.set(keyOf(p.x), top);
        const x = px(p.x) - wBand * 0.4 + (def.type === 'Column' ? i * w : 0);
        g.append(svgEl('rect', { x, y: Math.min(py(top), py(under)), width: w, height: Math.abs(py(under) - py(top)), 'data-row': p.row, stroke: 'none' }, svgEl('title', {}, `${s.name}: ${fmtNum(p.y)}`)));
      }
    } else if (def.type === 'StackedArea') {
      const top = pts.map(p => { const under = base.get(keyOf(p.x)) ?? 0; base.set(keyOf(p.x), under + p.y); return { x: px(p.x), y0: py(under), y1: py(under + p.y) }; });
      if (top.length) g.append(svgEl('path', { d: `M${top.map(t => `${t.x},${t.y1}`).join('L')}L${[...top].reverse().map(t => `${t.x},${t.y0}`).join('L')}Z`, 'fill-opacity': 0.5, stroke: 'none' }));
    } else if (def.type === 'Line') {
      if (pts.length > 1) g.append(svgEl('path', { d: 'M' + pts.map(p => `${px(p.x)},${py(p.y)}`).join('L'), fill: 'none', 'stroke-width': 2 }));
      for (const p of pts) g.append(svgEl('circle', { cx: px(p.x), cy: py(p.y), r: 2.5, 'data-row': p.row }, svgEl('title', {}, `${s.name}: ${fmtNum(p.y)}`)));
    } else {   // Scatter
      for (const p of pts) g.append(svgEl('circle', { cx: px(p.x), cy: py(p.y), r: 4, 'data-row': p.row, 'fill-opacity': 0.8 }, svgEl('title', {}, `${s.name}: ${fmtNum(p.y)}`)));
    }
  });
  // the overlay: another set's metric as a line over the chart
  sh.series.filter(s => s.line).forEach((s, k) => {
    const pts = [...s.pts].sort((a, b) => px(a.x) - px(b.x)), c = color(own.length + k);
    svg.append(svgEl('g', { class: 'series cr-overlay', stroke: c, fill: 'none' }, svgEl('path', { d: 'M' + pts.map(p => `${px(p.x)},${py(p.y)}`).join('L'), 'stroke-width': 2, 'stroke-dasharray': '6 3' })));
  });
  // a point's click opens its row's drill-down (the report's link on the metric or the X column)
  if (o.onPoint) svg.addEventListener('click', e => {
    const t = (e.target as Element).closest('[data-row]');
    const row = t ? Number(t.getAttribute('data-row')) : NaN;
    if (row >= 0) o.onPoint!(row);
  });
  box.append(legend);
  return box;
}
