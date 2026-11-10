import uPlot from 'uplot';
import { Row } from './api';
import { el } from './ui';

// live charts, destroyed before the next page is drawn (each holds window listeners)
const live: uPlot[] = [];
// fitAxis sizes the value axis to its longest label (uPlot's own axis-autosize demo): a fixed 70 px cut '4,000 ms/s'
function fitAxis(u: uPlot, values: string[] | null, axisIdx: number, cycleNum: number): number {
  const a = u.axes[axisIdx] as uPlot.Axis & { _size?: number };
  if (cycleNum > 1 && a._size) return a._size;
  let size = ((a.ticks as { size?: number } | undefined)?.size ?? 10) + (a.gap ?? 5);
  const longest = (values ?? []).reduce((acc, v) => (v.length > acc.length ? v : acc), '');
  if (longest) { u.ctx.font = (a.font as unknown as string[] | undefined)?.[0] ?? u.ctx.font; size += u.ctx.measureText(longest).width / devicePixelRatio; }
  return Math.ceil(Math.max(size, 40));
}

export function destroyCharts() { while (live.length) live.pop()!.destroy(); }

// The series colours: one categorical order per theme (the stylesheet's --s1..--s8, each set validated for
// colour-blind separation of neighbours and, on the dark surface, 3:1 contrast), assigned in order and never cycled
// past the eighth: a ninth series and 'other' take the neutral.
const fallback = ['#2a78d6', '#eb6834', '#1baf7a', '#eda100', '#e87ba4', '#008300', '#6250d6', '#e34948'];
export function seriesColors(): string[] {
  const css = getComputedStyle(document.documentElement);
  return fallback.map((f, i) => css.getPropertyValue(`--s${i + 1}`).trim() || f);
}
export const neutralColor = () => getComputedStyle(document.documentElement).getPropertyValue('--muted').trim() || '#868e96';
const colorAt = (p: string[], i: number) => i < p.length ? p[i] : neutralColor();

// lineChart draws one chart of the named series over snapshot_at.
export function lineChart(title: string, rows: Row[], series: { key: string; label: string }[],
                          fmt: (v: number) => string = v => v.toLocaleString()): HTMLElement {
  const box = el('div', { class: 'chart' }, el('h3', {}, title));
  if (rows.length < 2) { box.append(el('p', { class: 'empty' }, 'Not enough snapshots in this window.')); return box; }
  const xs = rows.map(r => new Date(String(r.snapshot_at)).getTime() / 1000);
  const data: uPlot.AlignedData = [xs, ...series.map(s => rows.map(r => r[s.key] == null ? null : Number(r[s.key])))];
  const holder = el('div');
  box.append(holder);
  // axis text and grid lines follow the page theme (light or dark)
  const css = getComputedStyle(document.documentElement);
  const fg = css.getPropertyValue('--muted').trim() || '#5d6676', grid = css.getPropertyValue('--line').trim() || '#dde1e8';
  const axis = { stroke: fg, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid, width: 1 } };
  const palette = seriesColors();
  const opts: uPlot.Options = {
    width: 560, height: 220,
    series: [{}, ...series.map((s, i) => ({ label: s.label, stroke: colorAt(palette, i), width: 2,
                                            value: (_u: uPlot, v: number | null) => v == null ? '' : fmt(v) }))],
    axes: [{ ...axis }, { ...axis, values: (_u: uPlot, vs: number[]) => vs.map(v => fmt(v)), size: fitAxis }],
    scales: { x: { time: true } },
  };
  // size to the container once it is in the page
  requestAnimationFrame(() => {
    opts.width = Math.max(300, holder.clientWidth || 560);
    if (!holder.isConnected) return;     // the page was replaced before this frame
    // a panel that redraws itself (the Storage tab's days selector) leaves its old charts off the page: free them
    for (let i = live.length - 1; i >= 0; i--) if (!live[i].root.isConnected) live.splice(i, 1)[0].destroy();
    live.push(new uPlot(opts, data, holder));
  });
  return box;
}

// One share of a donutChart: its label, its value, the page it opens (optional).
export interface Slice { label: string; value: number; href?: string }

const SVG_NS = 'http://www.w3.org/2000/svg';
function svg(tag: string, attrs: Record<string, string>, ...kids: (Node | string)[]): SVGElement {
  const e = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const k of kids) e.append(k);
  return e;
}

// donutChart draws shares of a whole as a ring with the same numbers in a table beside it (DBA Dash's pie charts). The
// ring is one named image; the table is its accessible form and tells the slices apart by label, size and share, never
// by colour alone. Slices are drawn largest first unless keepOrder; past max the smallest fold into 'other'. A slice
// with an href opens its page from its name in the table.
export function donutChart(title: string, slices: Slice[], fmt: (v: number) => string = v => v.toLocaleString(),
                           max = 8, keepOrder = false, empty = 'Nothing to show yet.'): HTMLElement {
  const box = el('div', { class: 'chart donut' }, el('h3', {}, title));
  let parts = slices.filter(s => isFinite(s.value) && s.value > 0);
  if (!keepOrder) parts = [...parts].sort((a, b) => b.value - a.value);
  const total = parts.reduce((a, s) => a + s.value, 0);
  if (!parts.length) { box.append(el('p', { class: 'empty' }, empty)); return box; }
  if (parts.length > max) {
    const rest = parts.slice(max - 1);
    parts = [...parts.slice(0, max - 1), { label: `other (${rest.length})`, value: rest.reduce((a, s) => a + s.value, 0) }];
  }
  const share = (v: number) => (100 * v / total).toLocaleString(undefined, { maximumFractionDigits: 1 }) + ' %';
  const r = 27, c = 2 * Math.PI * r;   // a stroke of 2r on a circle of radius r fills the disc: a pie, not a ring
  const ring = svg('svg', { viewBox: '0 0 120 120', role: 'img',
    'aria-label': `${title}: ` + parts.map(s => `${s.label} ${fmt(s.value)} (${share(s.value)})`).join(', ') });
  const body = el('tbody');
  let off = 0;
  const palette = seriesColors();
  parts.forEach((s, i) => {
    const color = colorAt(palette, i), len = c * s.value / total;
    const arc = svg('circle', { cx: '60', cy: '60', r: String(r), fill: 'none', stroke: color, 'stroke-width': String(2 * r),
      'stroke-dasharray': `${len} ${c - len}`, 'stroke-dashoffset': String(-off), transform: 'rotate(-90 60 60)' },
      svg('title', {}, `${s.label}: ${fmt(s.value)} (${share(s.value)})`));
    off += len;
    // the ring is one image (no control inside an image: WCAG's nested-interactive); a slice's page opens from its
    // name in the table
    ring.append(arc);
    const sw = el('span', { class: 'swatch', 'aria-hidden': 'true' });
    sw.style.background = color;
    body.append(el('tr', {},
      el('td', {}, sw, s.href ? el('a', { href: s.href }, s.label) : s.label),
      el('td', { class: 'num' }, fmt(s.value)), el('td', { class: 'num' }, share(s.value))));
  });
  box.append(el('p', { class: 'meta', style: 'margin:0 0 .3rem' }, `total ${fmt(total)}`));
  box.append(el('div', { class: 'donut-body' }, ring as unknown as HTMLElement,
    el('table', { class: 'legend' },
      el('thead', {}, el('tr', {}, el('th', { scope: 'col' }, 'name'), el('th', { scope: 'col', class: 'num' }, 'size'), el('th', { scope: 'col', class: 'num' }, 'share'))),
      body)));
  return box;
}

// volumeBars draws each volume as one horizontal bar, used against its size (DBA Dash's drive bars): the filled part
// is the used share, coloured by the free share left (under 10 % warning, under 5 % critical; the status is also a
// word in the row, never the colour alone). The numbers stand beside the bar; the list is a table for a screen reader.
export interface Volume { name: string; used: number; free: number; note?: string }
export function volumeBars(title: string, vols: Volume[], fmt: (v: number) => string, empty = 'No volume read yet.'): HTMLElement {
  const box = el('div', { class: 'chart bars' }, el('h3', {}, title));
  const rows = vols.filter(v => isFinite(v.used) && isFinite(v.free) && v.used + v.free > 0);
  if (!rows.length) { box.append(el('p', { class: 'empty' }, empty)); return box; }
  const body = el('tbody');
  for (const v of rows) {
    const total = v.used + v.free, usedPct = 100 * v.used / total, freePct = 100 - usedPct;
    const level = freePct < 5 ? 'crit' : freePct < 10 ? 'warn' : 'ok';
    const word = level === 'crit' ? 'critical' : level === 'warn' ? 'warning' : 'OK';
    const pct = (n: number) => n.toLocaleString(undefined, { maximumFractionDigits: 1 }) + ' %';
    const fill = el('span', { class: 'bar-fill ' + level });
    fill.style.width = Math.max(0.5, Math.min(100, usedPct)).toFixed(1) + '%';
    body.append(el('tr', {},
      el('th', { scope: 'row' }, v.name, v.note ? el('span', { class: 'meta' }, ' ' + v.note) : ''),
      el('td', { class: 'bar-cell' }, el('span', { class: 'bar', role: 'img', 'aria-label': `${pct(usedPct)} used` }, fill)),
      el('td', { class: 'num' }, `${fmt(v.used)} of ${fmt(total)}`),
      el('td', { class: 'num' }, pct(usedPct) + ' used'),
      el('td', { class: 'num' }, fmt(v.free) + ' free'),
      el('td', {}, el('span', { class: 'badge ' + level }, word))));
  }
  box.append(el('table', { class: 'legend bars-table' },
    el('thead', {}, el('tr', {}, el('th', { scope: 'col' }, 'volume'), el('th', { scope: 'col' }, 'used'), el('th', { scope: 'col', class: 'num' }, 'used of size'),
      el('th', { scope: 'col', class: 'num' }, 'share'), el('th', { scope: 'col', class: 'num' }, 'free'), el('th', { scope: 'col' }, 'status'))),
    body));
  return box;
}
