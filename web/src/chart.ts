import uPlot from 'uplot';
import { Row } from './api';
import { el } from './ui';

// live charts, destroyed before the next page is drawn (each holds window listeners)
const live: uPlot[] = [];
// fitAxis sizes the value axis to its longest label (uPlot's own axis-autosize demo: a fixed 70 px cut '4,000 ms/s'),
// and every chart of the page takes the widest page's value axis, so stacked charts keep one time axis: when a chart
// widens it, the charts drawn before it are resized once (setSize recomputes their axes against the new width)
let widest = 0, realign = 0;
function fitAxis(u: uPlot, values: string[] | null, axisIdx: number, cycleNum: number): number {
  const a = u.axes[axisIdx] as uPlot.Axis & { _size?: number };
  if (cycleNum > 1 && a._size) return Math.max(a._size, widest);
  let size = ((a.ticks as { size?: number } | undefined)?.size ?? 10) + (a.gap ?? 5);
  const longest = (values ?? []).reduce((acc, v) => (v.length > acc.length ? v : acc), '');
  if (longest) { u.ctx.font = (a.font as unknown as string[] | undefined)?.[0] ?? u.ctx.font; size += u.ctx.measureText(longest).width / devicePixelRatio; }
  size = Math.ceil(Math.max(size, 40));
  if (size > widest) {
    widest = size;
    if (!realign) realign = requestAnimationFrame(() => { realign = 0; for (const c of live) c.setSize({ width: c.width, height: c.height }); });
  }
  return widest;
}

export function destroyCharts() {
  while (live.length) live.pop()!.destroy();
  widest = 0;   // the next page measures its own
  if (realign) { cancelAnimationFrame(realign); realign = 0; }
}

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
// a #rrggbb colour at an alpha, for a stacked band's fill (any other form is returned as it is)
const withAlpha = (c: string, a: number) => /^#[0-9a-f]{6}$/i.test(c)
  ? `rgba(${parseInt(c.slice(1, 3), 16)}, ${parseInt(c.slice(3, 5), 16)}, ${parseInt(c.slice(5, 7), 16)}, ${a})` : c;

// lineChart draws one chart of the named series over snapshot_at.
// stacked: the series are running totals (the caller sums them), drawn as filled bands from zero, each down to the
// one below it (uPlot's bands), so a band's height is that series' share and the top line is the total
export function lineChart(title: string, rows: Row[], series: { key: string; label: string }[],
                          fmt: (v: number) => string = v => v.toLocaleString(), o: { stacked?: boolean } = {}): HTMLElement {
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
    series: [{}, ...series.map((s, i) => ({ label: s.label, stroke: colorAt(palette, i), width: o.stacked ? 1 : 2,
                                            fill: o.stacked ? withAlpha(colorAt(palette, i), 0.45) : undefined,
                                            value: (_u: uPlot, v: number | null) => v == null ? '' : fmt(v) }))],
    bands: o.stacked ? series.slice(1).map((_, i) => ({ series: [i + 2, i + 1] as [number, number] })) : undefined,
    axes: [{ ...axis }, { ...axis, values: (_u: uPlot, vs: number[]) => vs.map(v => fmt(v)), size: fitAxis }],
    plugins: [tooltipPlugin(fmt, !!o.stacked)],
    scales: { x: { time: true }, ...(o.stacked ? { y: { range: (_u: uPlot, _min: number, max: number): uPlot.Range.MinMax => [0, max > 0 ? max * 1.05 : 1] } } : {}) },
  };
  // size to the container once it is in the page
  requestAnimationFrame(() => {
    opts.width = Math.max(300, holder.clientWidth || 560);
    if (!holder.isConnected) return;     // the page was replaced before this frame
    // a panel that redraws itself (the Storage tab's days selector) leaves its old charts off the page: free them
    for (let i = live.length - 1; i >= 0; i--) if (!live[i].root.isConnected) live.splice(i, 1)[0].destroy();
    const u = new uPlot(opts, data, holder);
    live.push(u);
    isolateOnDoubleClick(u);
  });
  return box;
}

// a legend entry: a click shows or hides its series (uPlot's own); a double-click shows that series alone, and a
// second double-click on the one series left shows them all again (Darling's charts)
function isolateOnDoubleClick(u: uPlot) {
  u.root.querySelectorAll('.u-legend .u-series').forEach((row, i) => {
    if (i === 0) return;   // the time column
    row.addEventListener('dblclick', e => {
      e.preventDefault();
      const alone = u.series.every((s, j) => j === 0 || (j === i) === !!s.show);
      u.batch(() => { for (let j = 1; j < u.series.length; j++) u.setSeries(j, { show: alone || j === i }); });
    });
  });
}

// the crosshair's readout: the time and each shown series' value beside the cursor (the legend above carries the
// same values for a screen reader; this box is for the eye and is hidden from assistive technology)
// stacked: the series are running totals (lineChart's bands), so the readout gives each band's own value (its total less
// the one below it), as the reader means 'IO: 42 ms/s'
function tooltipPlugin(fmt: (v: number) => string, stacked = false): uPlot.Plugin {
  let tip: HTMLElement;
  return {
    hooks: {
      init: u => { tip = el('div', { class: 'u-tip', 'aria-hidden': 'true', hidden: '' }); u.over.append(tip); },
      setCursor: u => {
        const { left, top, idx } = u.cursor;
        if (idx == null || left == null || left < 0 || top == null) { tip.hidden = true; return; }
        const t = new Date((u.data[0][idx] as number) * 1000).toLocaleString(undefined, { hour12: false });
        const lines = u.series.slice(1).map((s, j) => {
          const tot = u.data[j + 1][idx], below = stacked && j > 0 ? u.data[j][idx] : 0;
          const v = tot == null ? null : (tot as number) - ((below as number | null) ?? 0);
          const c = typeof s.stroke === 'function' ? (s.stroke as unknown as (u: uPlot, i: number) => string)(u, j + 1) : String(s.stroke ?? '');
          return s.show && v != null ? el('div', {}, el('span', { class: 'u-tip-key', style: `background:${c}` }), `${s.label}: ${fmt(v as number)}`) : null;
        }).filter((x): x is HTMLDivElement => x !== null);
        if (!lines.length) { tip.hidden = true; return; }
        tip.replaceChildren(el('div', { class: 'u-tip-time' }, t), ...lines);
        tip.hidden = false;
        const w = u.over.clientWidth, flip = left > w / 2;
        tip.style.left = flip ? '' : `${left + 12}px`;
        tip.style.right = flip ? `${w - left + 12}px` : '';
        tip.style.top = `${Math.max(0, top - 10)}px`;
      },
    },
  };
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
