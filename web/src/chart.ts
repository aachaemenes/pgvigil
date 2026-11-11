import uPlot from 'uplot';
import { Row } from './api';
import { copyText, el, saveBlob, showMenu } from './ui';
import { fileStamp, fmt as fmtZone, stamp, zoneChoice } from './tz';

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
  const zone = zoneChoice();
  const opts: uPlot.Options = {
    width: 560, height: 220,
    series: [{}, ...series.map((s, i) => ({ label: s.label, stroke: colorAt(palette, i), width: o.stacked ? 1 : 2,
                                            fill: o.stacked ? withAlpha(colorAt(palette, i), 0.45) : undefined,
                                            value: (_u: uPlot, v: number | null) => v == null ? '' : fmt(v) }))],
    bands: o.stacked ? series.slice(1).map((_, i) => ({ series: [i + 2, i + 1] as [number, number] })) : undefined,
    axes: [{ ...axis }, { ...axis, values: (_u: uPlot, vs: number[]) => vs.map(v => fmt(v)), size: fitAxis }],
    plugins: [tooltipPlugin(fmt, !!o.stacked)],
    // the time axis and the legend's time on the display zone's clock (the browser's own needs nothing); the zone is the
    // one the chart was built in: a chart still on the page after a change of zone keeps reading its own
    ...(zone === 'local' ? {} : { tzDate: (ts: number) => uPlot.tzDate(new Date(ts * 1000), zone) }),
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
    chartMenu(box, title, u, !!o.stacked);
  });
  return box;
}

// chartMenu: a chart's own menu (DBA Dash's chart menu, Darling's): the picture, or the numbers under it, copied or saved.
// The button in the chart's heading opens it (the keyboard's way) and so does a right-click on the plot. The numbers are
// the series shown, a row per point, the time as 'YYYY-MM-DD HH:MM:SS' in the display zone; a stacked chart gives each
// band's own value.
function chartMenu(box: HTMLElement, title: string, u: uPlot, stacked: boolean) {
  const head = box.querySelector('h3');
  if (!head) return;
  const note = el('span', { class: 'meta chart-note', role: 'status' });
  const btn = el('button', { type: 'button', class: 'chart-menu', 'aria-haspopup': 'menu', 'aria-label': `Chart menu: ${title}`, title: 'Copy or save this chart' }, '\u22EF') as HTMLButtonElement;
  const say = (t: string) => { note.textContent = t; };
  const fileName = (ext: string) => `${title.replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'chart'}_${fileStamp(new Date())}.${ext}`;
  const shown = () => u.series.map((s, j) => ({ s, j })).filter(x => x.j > 0 && x.s.show);
  const table = (sep: string): { text: string; rows: number } => {
    const q = (v: string) => sep === ',' && /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
    const cols = shown(), xs = u.data[0] as number[];
    const lines = [['time', ...cols.map(c => q(String(c.s.label ?? '')))].join(sep)];
    for (let i = 0; i < xs.length; i++) {
      lines.push([stamp(new Date(xs[i] * 1000)), ...cols.map(c => {
        const tot = u.data[c.j][i], below = stacked && c.j > 1 ? u.data[c.j - 1][i] : 0;
        return tot == null ? '' : String(Number(((tot as number) - ((below as number | null) ?? 0)).toPrecision(12)));
      })].join(sep));
    }
    return { text: lines.join('\n'), rows: xs.length };
  };
  // the picture: the plot as drawn, on the page's own background, under its title and over a legend of the series shown
  const image = (): Promise<Blob | null> => {
    const src = u.ctx.canvas, k = devicePixelRatio || 1, pad = 12 * k, th = 26 * k, lh = 24 * k;
    const css = getComputedStyle(document.documentElement);
    const bg = css.getPropertyValue('--card').trim() || '#fff', fg = css.getPropertyValue('--fg').trim() || '#1d2330';
    const c = document.createElement('canvas');
    c.width = src.width + 2 * pad; c.height = src.height + th + lh + 2 * pad;
    const g = c.getContext('2d');
    if (!g) return Promise.resolve(null);
    g.fillStyle = bg; g.fillRect(0, 0, c.width, c.height);
    g.fillStyle = fg; g.textBaseline = 'middle'; g.font = `${14 * k}px system-ui, sans-serif`;
    g.fillText(title, pad, pad + th / 2);
    g.drawImage(src, pad, pad + th);
    g.font = `${12 * k}px system-ui, sans-serif`;
    let x = pad; const y = pad + th + src.height + lh / 2;
    for (const { s, j } of shown()) {
      const col = typeof s.stroke === 'function' ? (s.stroke as unknown as (u: uPlot, i: number) => string)(u, j) : String(s.stroke ?? fg);
      g.fillStyle = col; g.fillRect(x, y - 5 * k, 10 * k, 10 * k);
      g.fillStyle = fg; const label = String(s.label ?? ''); g.fillText(label, x + 14 * k, y);
      x += 14 * k + g.measureText(label).width + 18 * k;
    }
    return new Promise(res => c.toBlob(res, 'image/png'));
  };
  const items: [string, () => void][] = [
    ['Copy image', () => { void (async () => {
      try {
        const b = await image();
        if (!b) throw new Error('no image');
        await navigator.clipboard.write([new ClipboardItem({ 'image/png': b })]);
        say('Copied the image');
      } catch { say('Not copied: the browser refused the clipboard'); }
    })(); }],
    ['Save image', () => { void image().then(b => { if (b) { saveBlob(b, fileName('png')); say('Saved the image'); } else say('No image could be made'); }); }],
    ['Copy data', () => { const t = table('\t'); void copyText(t.text).then(ok => say(ok ? `Copied ${t.rows} points` : 'Not copied: the browser refused the clipboard')); }],
    ['Export data (CSV)', () => { const t = table(','); saveBlob(new Blob([t.text + '\n'], { type: 'text/csv;charset=utf-8' }), fileName('csv')); say(`Saved ${t.rows} points`); }],
  ];
  btn.addEventListener('click', () => { const r = btn.getBoundingClientRect(); showMenu(r.left, r.bottom + 2, items, btn); });
  u.over.addEventListener('contextmenu', e => { e.preventDefault(); showMenu(e.clientX, e.clientY, items, btn); });
  head.append(' ', btn, note);
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
        const t = fmtZone(new Date((u.data[0][idx] as number) * 1000));
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
  // each slice a wedge path from the centre (a dashed stroke of width 2r left a notch where two dashes met at the centre)
  const r = 54;
  const at = (f: number) => { const a = 2 * Math.PI * f - Math.PI / 2; return `${(60 + r * Math.cos(a)).toFixed(3)} ${(60 + r * Math.sin(a)).toFixed(3)}`; };
  const ring = svg('svg', { viewBox: '0 0 120 120', role: 'img',
    'aria-label': `${title}: ` + parts.map(s => `${s.label} ${fmt(s.value)} (${share(s.value)})`).join(', ') });
  const body = el('tbody');
  let off = 0;
  const palette = seriesColors();
  parts.forEach((s, i) => {
    const color = colorAt(palette, i), f = s.value / total;
    const tip = svg('title', {}, `${s.label}: ${fmt(s.value)} (${share(s.value)})`);
    // a slice of (nearly) the whole: its arc's two ends round to one point and SVG drops it, so it is the disc itself,
    // drawn under the others
    const whole = f > 0.9999;
    const arc = whole
      ? svg('circle', { cx: '60', cy: '60', r: String(r), fill: color }, tip)
      : svg('path', { d: `M60 60 L${at(off)} A${r} ${r} 0 ${f > 0.5 ? 1 : 0} 1 ${at(off + f)} Z`, fill: color }, tip);
    off += f;
    // the ring is one image (no control inside an image: WCAG's nested-interactive); a slice's page opens from its
    // name in the table
    if (whole) ring.prepend(arc); else ring.append(arc);
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
