import uPlot from 'uplot';
import { Row } from './api';
import { el } from './ui';

// live charts, destroyed before the next page is drawn (each holds window listeners)
const live: uPlot[] = [];
export function destroyCharts() { while (live.length) live.pop()!.destroy(); }

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
  // axis text and grid lines follow the page theme (light or dark)
  const css = getComputedStyle(document.documentElement);
  const fg = css.getPropertyValue('--muted').trim() || '#5d6676', grid = css.getPropertyValue('--line').trim() || '#dde1e8';
  const axis = { stroke: fg, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid, width: 1 } };
  const opts: uPlot.Options = {
    width: 560, height: 220,
    series: [{}, ...series.map((s, i) => ({ label: s.label, stroke: palette[i % palette.length], width: 1.5,
                                            value: (_u: uPlot, v: number | null) => v == null ? '' : fmt(v) }))],
    axes: [{ ...axis }, { ...axis, values: (_u: uPlot, vs: number[]) => vs.map(v => fmt(v)), size: 70 }],
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
  const r = 42, c = 2 * Math.PI * r;
  const ring = svg('svg', { viewBox: '0 0 120 120', role: 'img',
    'aria-label': `${title}: ` + parts.map(s => `${s.label} ${fmt(s.value)} (${share(s.value)})`).join(', ') });
  const body = el('tbody');
  let off = 0;
  parts.forEach((s, i) => {
    const color = palette[i % palette.length], len = c * s.value / total;
    const arc = svg('circle', { cx: '60', cy: '60', r: String(r), fill: 'none', stroke: color, 'stroke-width': '20',
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
  const mid = svg('text', { x: '60', y: '64', 'text-anchor': 'middle', class: 'donut-total' }, fmt(total));
  ring.append(mid);
  box.append(el('div', { class: 'donut-body' }, ring as unknown as HTMLElement,
    el('table', { class: 'legend' },
      el('thead', {}, el('tr', {}, el('th', { scope: 'col' }, 'name'), el('th', { scope: 'col', class: 'num' }, 'size'), el('th', { scope: 'col', class: 'num' }, 'share'))),
      body)));
  return box;
}
