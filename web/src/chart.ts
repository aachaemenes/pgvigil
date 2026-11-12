import uPlot from 'uplot';
import { get, Row, rowsOf, Table } from './api';
import { href, MAX_RANGE_MS, parse, window_ } from './router';
import { copyText, el, saveBlob, showMenu } from './ui';
import { exportChart } from './export';
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
  frameReads.clear(); pageWin = undefined;   // and reads its own frame
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

// ---- the frame a chart of one instance reads besides its own rows (/api/frame/events, internal/web/q_frame.go): the
// marks on its time axis (setting changes, restarts, failovers, deadlocks) and the server limits it may draw as lines.
// One read per instance and window for the whole page: the charts of a page share it, a new page reads again.
export interface FrameMark { at: number; kind: string; label: string; tab: string; ofKind: number }
interface FrameRead { marks: FrameMark[]; limits: Map<string, number> }
const frameReads = new Map<string, Promise<FrameRead>>();
// the page's window, taken once per address and draw (a preset's now moves): a page builds its charts before the frame
// clears the last page's (main.ts render), so the address is the key, not the clearing alone
let pageWin: { key: string; from: number; to: number } | undefined;
const minute = 60000;
function pageWindow(): { from: number; to: number } {
  if (!pageWin || pageWin.key !== location.hash) {
    const w = window_(parse()), to = Math.ceil(Date.parse(w.to) / minute) * minute;
    // whole minutes outward, then cut to the server's longest again (a 31-day window with ends inside a minute)
    pageWin = { key: location.hash, from: Math.max(Math.floor(Date.parse(w.from) / minute) * minute, to - MAX_RANGE_MS), to };
  }
  return pageWin;
}
function frameRead(instance: number, from: number, to: number): Promise<FrameRead> {
  const key = `${instance}|${from}|${to}`;
  let p = frameReads.get(key);
  if (!p) {
    p = get<{ events: Table; limits: Table }>('frame/events', { instance, from: new Date(from).toISOString(), to: new Date(to).toISOString() })
      .then(d => ({
        marks: rowsOf(d.events).map(r => ({ at: Date.parse(String(r.at)), kind: String(r.kind), label: String(r.label ?? ''), tab: String(r.tab ?? ''), ofKind: Number(r.of_kind ?? 0) })).filter(m => !Number.isNaN(m.at)),
        limits: new Map(rowsOf(d.limits).filter(r => r.value != null).map(r => [String(r.name), Number(r.value)])),
      }))
      .catch(() => ({ marks: [], limits: new Map<string, number>() }));   // a failed read draws the chart without its marks
    frameReads.set(key, p);
  }
  return p;
}
// the window a chart's frame read covers: the page's, or the chart's own span when the chart draws a longer one (the
// Storage tab's days): its last 31 days at most, the server's longest
function chartWindow(xs: number[]): { from: number; to: number } {
  const w = pageWindow(), a = xs[0] * 1000, b = xs[xs.length - 1] * 1000;
  if (a >= w.from - 0.1 * (w.to - w.from)) return w;
  const to = Math.ceil(b / minute) * minute;
  return { from: Math.max(Math.floor(a / minute) * minute, to - MAX_RANGE_MS), to };
}
const markWords: Record<string, string> = { setting: 'Setting change', restart: 'Restart', failover: 'Failover', deadlock: 'Deadlock' };
const markPlural: Record<string, string> = { setting: 'setting changes', restart: 'restarts', failover: 'failovers', deadlock: 'deadlocks' };
const markColour = (kind: string) => { const p = seriesColors(); return ({ setting: p[3], restart: p[7], failover: p[6], deadlock: p[1] } as Record<string, string>)[kind] ?? neutralColor(); };
// a mark's link: its rows' page over ten minutes around it (a deadlock opens the log's deadlocks)
function markHref(m: FrameMark): string {
  const ctx = parse();
  return href(ctx, { tab: m.tab || 'summary', range: { from: new Date(m.at - 5 * minute).toISOString(), to: new Date(m.at + 5 * minute).toISOString() },
    at: undefined, ...(m.tab === 'logs' ? { logKind: 'deadlock' } : {}) });
}

// A line drawn across a chart at a value: a threshold (the page's own rule, always drawn: the chart's scale takes it in)
// or a server limit (max_connections). A limit far above the chart's values (over four times its peak) is not drawn, so
// the series keep their height; the note under the chart names it instead.
export interface ChartLine { value: number; label: string; kind?: 'threshold' | 'limit'; level?: 'warning' | 'critical'; y2?: boolean }
export interface ChartOpts {
  stacked?: boolean;
  unit?: string;                                                       // the left axis's unit, written on the axis
  y2?: { keys: string[]; fmt?: (v: number) => string; unit?: string };  // series drawn against a second axis on the right
  lines?: ChartLine[];                                                 // threshold lines of the caller's own
  limits?: string[];                                                   // server limits by name (q_frame.go): 'max_connections'
  marks?: boolean;                                                     // false: no event marks (default: marked on an instance page)
  ownSpan?: boolean;                                                   // the chart draws a span of its own (the Storage days), not the page's: no partial-window note
}
const LINE_REACH = 4;

// the series a reader picked or hid on a chart (its legend, Pick series), kept per page and chart title across a refresh
// and a change of range: a page's address without its range
const picked = new Map<string, Set<string>>();
const pageScope = () => { const h = location.hash.split('?'), q = new URLSearchParams(h[1] ?? ''); for (const k of ['w', 'from', 'to']) q.delete(k); return h[0] + '?' + q; };

// lineChart draws one chart of the named series over snapshot_at.
// stacked: the series are running totals (the caller sums them), drawn as filled bands from zero, each down to the
// one below it (uPlot's bands), so a band's height is that series' share and the top line is the total.
// Every chart (task 152, K09.03): a drag across it sets the page's range (the address, so every chart and grid reads
// again); one cursor runs across the page's charts; on an instance's page its setting changes, restarts, failovers and
// deadlocks are marked on the time axis, each mark a link to its rows; o.y2 draws named series on a second axis, o.lines
// and o.limits draw thresholds and server limits; the heading's buttons open the chart menu and a full-window view.
// A chart whose reads start well after the window's start, or that holds under three reads, says so under it (K09.02).
export function lineChart(title: string, rows: Row[], series: { key: string; label: string }[],
                          fmt: (v: number) => string = v => v.toLocaleString(), o: ChartOpts = {}): HTMLElement {
  const box = el('div', { class: 'chart' }, el('h3', {}, title));
  if (rows.length < 2) { box.append(el('p', { class: 'empty' }, rows.length ? 'Only one read in this window: a chart needs two.' : 'Not enough snapshots in this window.')); return box; }
  const xs = rows.map(r => new Date(String(r.snapshot_at)).getTime() / 1000);
  const data: uPlot.AlignedData = [xs, ...series.map(s => rows.map(r => r[s.key] == null ? null : Number(r[s.key])))];
  const holder = el('div');
  box.append(holder);
  // the span drawn, for a check that reads where a mark or a drag falls (the x scale is the data's own span)
  box.dataset.first = new Date(xs[0] * 1000).toISOString(); box.dataset.last = new Date(xs[xs.length - 1] * 1000).toISOString();
  const notes = el('p', { class: 'meta chart-notes' });
  box.append(notes);
  const say = () => { notes.textContent = [axesNote, partial, lineNote, markNote].filter(Boolean).join(' '); notes.hidden = !notes.textContent; };
  // the partial-window notes: the data starts after the window's start by more than two read intervals and a twentieth
  // of the window (a collection started late, an instance added in the window), or the window holds under three reads
  let partial = '', lineNote = '', markNote = '', axesNote = '';
  // the axes' units are drawn on the canvas: written here too, with the series each axis carries
  if (o.y2?.keys.length) axesNote = `Left axis: ${o.unit ?? 'values'} (${series.filter(s => !o.y2!.keys.includes(s.key)).map(s => s.label).join(', ')}); right axis: ${o.y2.unit ?? 'values'} (${series.filter(s => o.y2!.keys.includes(s.key)).map(s => s.label).join(', ')}).`;
  // a read is a row with a value: a page that lays its series on the window's steps (Performance) has rows without one
  const reads = rows.filter(r => series.some(s => r[s.key] != null)).length;
  if (!o.ownSpan) {
    const at0 = xs.findIndex((_, i) => series.some(s => rows[i][s.key] != null));
    const w = pageWindow(), first = xs[Math.max(0, at0)] * 1000, len = w.to - w.from;
    const step = xs.length > 1 ? (xs[xs.length - 1] - xs[0]) * 1000 / (xs.length - 1) : 0;
    if (at0 >= 0 && first > w.from + Math.max(2 * step, 0.05 * len) && first < w.to && xs[xs.length - 1] * 1000 <= w.to + minute)
      partial = `The data starts at ${fmtZone(new Date(first))}, ${spanWords(first - w.from)} after the window's start.`;
  }
  if (reads < 3) partial = (partial ? partial + ' ' : '') + (reads === 1 ? 'Only one read in this window.' : reads === 0 ? 'No read with a value in this window.' : `Only ${reads} reads in this window.`);
  say();
  // axis text and grid lines follow the page theme (light or dark)
  const css = getComputedStyle(document.documentElement);
  const fg = css.getPropertyValue('--muted').trim() || '#5d6676', grid = css.getPropertyValue('--line').trim() || '#dde1e8';
  const axis = { stroke: fg, grid: { stroke: grid, width: 1 }, ticks: { stroke: grid, width: 1 } };
  const palette = seriesColors();
  const zone = zoneChoice();
  const on2 = new Set(o.y2?.keys ?? []);
  const fmtOf = (si: number) => si > 0 && on2.has(series[si - 1].key) ? (o.y2?.fmt ?? fmt) : fmt;
  // the lines: the caller's, then the server limits once the frame read names them
  const lines: ChartLine[] = [...(o.lines ?? [])];
  const reach = (scale: string, max: number) => {
    let hi = max;
    for (const l of lines) if (!!l.y2 === (scale === 'y2') && isFinite(l.value) && (l.kind !== 'limit' || l.value <= LINE_REACH * Math.max(max, 1e-9))) hi = Math.max(hi, l.value);
    return hi;
  };
  const ranged = !!(o.lines?.length || o.limits?.length);
  const yRange = (scale: string) => (_u: uPlot, min: number, max: number): uPlot.Range.MinMax => uPlot.rangeNum(Math.min(min, 0), reach(scale, max), 0.1, true);
  const opts: uPlot.Options = {
    width: 560, height: 220,
    series: [{}, ...series.map((s, i) => ({ label: s.label, stroke: colorAt(palette, i), width: o.stacked ? 1 : 2,
                                            scale: on2.has(s.key) ? 'y2' : 'y',
                                            fill: o.stacked ? withAlpha(colorAt(palette, i), 0.45) : undefined,
                                            // stacked: the data are running totals, the legend (the screen reader's form) gives the
                                            // band's own value, as the tooltip does
                                            value: (u: uPlot, v: number | null, si: number, idx: number | null) => v == null ? ''
                                              : fmtOf(si)(o.stacked && si > 1 && idx != null ? v - (Number(u.data[si - 1][idx] ?? 0)) : v) }))],
    bands: o.stacked ? series.slice(1).map((_, i) => ({ series: [i + 2, i + 1] as [number, number] })) : undefined,
    axes: [{ ...axis },
      { ...axis, values: (_u: uPlot, vs: number[]) => vs.map(v => fmt(v)), size: fitAxis, ...(o.unit ? { label: o.unit, labelSize: 18 } : {}) },
      ...(on2.size ? [{ ...axis, scale: 'y2', side: 1, grid: { show: false }, values: (_u: uPlot, vs: number[]) => vs.map(v => (o.y2?.fmt ?? fmt)(v)),
                        size: (u: uPlot, vals: string[] | null, ai: number, cyc: number) => fitOwn(u, vals, ai, cyc), ...(o.y2?.unit ? { label: o.y2.unit, labelSize: 18 } : {}) }] : [])],
    plugins: [tooltipPlugin(fmtOf, !!o.stacked), framePlugin(lines, () => markState)],
    // the time axis and the legend's time on the display zone's clock (the browser's own needs nothing); the zone is the
    // one the chart was built in: a chart still on the page after a change of zone keeps reading its own
    ...(zone === 'local' ? {} : { tzDate: (ts: number) => uPlot.tzDate(new Date(ts * 1000), zone) }),
    scales: { x: { time: true },
      ...(o.stacked ? { y: { range: (_u: uPlot, _min: number, max: number): uPlot.Range.MinMax => [0, reach('y', max > 0 ? max * 1.05 : 1)] } } : ranged ? { y: { range: yRange('y') } } : {}),
      ...(on2.size && ranged ? { y2: { range: yRange('y2') } } : {}) },
    // a drag across the plot sets the page's range; the cursor of every chart on the page follows the one under the
    // pointer (by time: charts of other spans follow where they hold it). Only the cursor's moves are shared: a drag on
    // one chart is that chart's own
    cursor: { drag: { x: true, y: false, setScale: false },
              sync: { key: 'pgvigil-page', setSeries: false, scales: ['x', null], filters: { pub: (type: string) => type !== 'mousedown' && type !== 'mouseup' && type !== 'dblclick' } } },
  };
  let markState: { marks: FrameMark[] } = { marks: [] };
  const hiddenKey = pageScope() + '|' + title;
  // size to the container once it is in the page
  requestAnimationFrame(() => {
    opts.width = Math.max(300, holder.clientWidth || 560);
    if (!holder.isConnected) return;     // the page was replaced before this frame
    // a panel that redraws itself (the Storage tab's days selector) leaves its old charts off the page: free them
    for (let i = live.length - 1; i >= 0; i--) if (!live[i].root.isConnected) live.splice(i, 1)[0].destroy();
    // the series hidden here before (a refresh, a range change): hidden from the start
    const hidden = picked.get(hiddenKey);
    if (hidden) opts.series.forEach((s, j) => { if (j > 0 && hidden.has(String(s.label))) s.show = false; });
    opts.hooks = {
      setSelect: [u => {
        if (u.select.width < 3) return;
        const a = u.posToVal(u.select.left, 'x') * 1000, b = u.posToVal(u.select.left + u.select.width, 'x') * 1000;
        u.setSelect({ left: 0, top: 0, width: 0, height: 0 }, false);
        dragRange(a, b);
      }],
      setSeries: [u => { picked.set(hiddenKey, new Set(u.series.filter((s, j) => j > 0 && !s.show).map(s => String(s.label)))); }],
    };
    const u = new uPlot(opts, data, holder);
    live.push(u);
    isolateOnDoubleClick(u);
    chartMenu(box, title, u, !!o.stacked);
    fullWindow(box, title, u, hiddenKey);
    // the frame read: the marks of the page's instance and the limits the chart names; a fleet page has neither
    const inst = parse().instance;
    if (!inst || (o.marks === false && !o.limits?.length)) return;
    const w = chartWindow(xs);
    void frameRead(inst, w.from, w.to).then(f => {
      if (!u.root.isConnected) return;
      const added: string[] = [];
      for (const name of o.limits ?? []) {
        const v = f.limits.get(name);
        if (v === undefined || !isFinite(v)) continue;
        lines.push({ value: v, label: `${name} ${fmt(v)}`, kind: 'limit' });
        added.push(name);
      }
      if (o.marks !== false) markState = { marks: f.marks.filter(m => m.at >= xs[0] * 1000 && m.at <= xs[xs.length - 1] * 1000) };
      const peak = Math.max(0, ...series.filter(s => !on2.has(s.key)).flatMap(s => rows.map(r => Number(r[s.key] ?? 0))).filter(isFinite));
      const far = lines.filter(l => !l.y2 && l.kind === 'limit' && l.value > LINE_REACH * Math.max(peak, 1e-9));
      lineNote = lines.length ? `Lines: ${lines.map(l => `${l.kind === 'limit' ? 'limit' : 'threshold'} ${l.label}`).join(', ')}` +
        (far.length ? ` (${far.map(l => l.label).join(', ')} above the chart: over ${LINE_REACH} times its peak).` : '.') : '';
      const counts = new Map<string, number>(), capped = new Map<string, number>();
      for (const m of markState.marks) { counts.set(m.kind, (counts.get(m.kind) ?? 0) + 1); if (m.ofKind > (capped.get(m.kind) ?? 0)) capped.set(m.kind, m.ofKind); }
      // a kind past the server's cap says so: the newest of the window's count
      const word = (k: string, n: number) => n === 1 ? (markWords[k] ?? k).toLowerCase() : markPlural[k] ?? k;
      markNote = counts.size ? 'Marked: ' + [...counts].map(([k, n]) => {
        const all = capped.get(k) ?? n;
        return all > n && f.marks.filter(m => m.kind === k).length < all ? `the newest ${n} of ${all} ${word(k, all)}` : `${n} ${word(k, n)}`;
      }).join(', ') + '.' : '';
      say();
      // the marks are links out of the keyboard's way (tabindex -1, hundreds on a long window): their one tab stop is
      // this list under the chart, closed until opened
      box.querySelector('details.chart-marks')?.remove();
      if (markState.marks.length) {
        const list = el('ul', { style: 'margin:.2rem 0 0;padding-left:1.2rem;max-height:12rem;overflow:auto' },
          ...markState.marks.map(m => el('li', {}, el('a', { href: markHref(m) }, `${markWords[m.kind] ?? m.kind} at ${fmtZone(new Date(m.at))}: ${m.label}`))));
        box.append(el('details', { class: 'chart-marks meta' }, el('summary', {}, `The ${markState.marks.length} marks, each with its rows`), list));
      }
      if (added.length) u.setData(u.data); else u.redraw(false, false);
    });
  });
  return box;
}

// spanWords: a length by its two largest units ('35m', '2h 5m', '1d 3h')
function spanWords(ms: number): string {
  const m = Math.round(ms / minute), d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60), mi = m % 60;
  return d ? (h ? `${d}d ${h}h` : `${d}d`) : h ? (mi ? `${h}h ${mi}m` : `${h}h`) : `${mi}m`;
}

// dragRange: the page's range set to a stretch dragged on a chart (whole minutes, one minute at least, the server's
// longest at most), every page parameter kept: the address changes, so the page and every chart and grid on it read again
function dragRange(a: number, b: number) {
  let from = Math.floor(Math.min(a, b) / minute) * minute, to = Math.ceil(Math.max(a, b) / minute) * minute;
  if (to - from < minute) to = from + minute;
  if (to - from > MAX_RANGE_MS) from = to - MAX_RANGE_MS;
  const ctx = parse();
  location.hash = href(ctx, { tab: ctx.tab, range: { from: new Date(from).toISOString(), to: new Date(to).toISOString() }, at: undefined });
}

// fitOwn sizes a second value axis to its own longest label (fitAxis keeps one width for the left axes of a page)
function fitOwn(u: uPlot, values: string[] | null, axisIdx: number, cycleNum: number): number {
  const a = u.axes[axisIdx] as uPlot.Axis & { _size?: number };
  if (cycleNum > 1 && a._size) return a._size;
  const longest = (values ?? []).reduce((acc, v) => (v.length > acc.length ? v : acc), '');
  u.ctx.font = (a.font as unknown as string[] | undefined)?.[0] ?? u.ctx.font;
  return Math.ceil(Math.max(40, 15 + (longest ? u.ctx.measureText(longest).width / devicePixelRatio : 0) + (a.label ? 18 : 0)));
}

// framePlugin draws the lines and the marks over the plot as page elements (so a mark is a link a keyboard reaches and a
// check can read): a line is a dashed rule with its words at its right end; a mark a dashed upright at its moment with a
// diamond at the top that opens its rows. Both are placed again on every full redraw (a resize, new data, a scale).
function framePlugin(lines: ChartLine[], marks: () => { marks: FrameMark[] }): uPlot.Plugin {
  let layer: HTMLElement;
  return {
    hooks: {
      init: u => { layer = el('div', { class: 'chart-frame', style: 'position:absolute;inset:0;pointer-events:none' }); u.over.append(layer); },
      draw: u => {
        const css = getComputedStyle(document.documentElement);
        const ink = css.getPropertyValue('--fg').trim() || '#1d2330', card = css.getPropertyValue('--card').trim() || '#fff';
        const h = u.over.clientHeight, w = u.over.clientWidth, kids: HTMLElement[] = [];
        for (const l of lines) {
          const scale = l.y2 ? 'y2' : 'y';
          if (!u.scales[scale]) continue;
          const y = u.valToPos(l.value, scale);
          if (!isFinite(y) || y < 0 || y > h) continue;
          const col = l.kind === 'limit' || l.level === 'critical' ? (css.getPropertyValue('--crit').trim() || '#c92a2a') : (css.getPropertyValue('--warn').trim() || '#e67700');
          kids.push(el('div', { class: 'chart-line', 'data-kind': l.kind ?? 'threshold', 'data-value': String(l.value), 'aria-hidden': 'true',
            style: `position:absolute;left:0;right:0;top:${Math.round(y)}px;border-top:1px dashed ${col}` },
            el('span', { style: `position:absolute;right:2px;bottom:1px;font-size:11px;line-height:1;padding:0 2px;color:${ink};background:${card}` }, l.label)));
        }
        const x0 = u.scales.x.min ?? -Infinity, x1 = u.scales.x.max ?? Infinity;
        for (const m of marks().marks) {
          const t = m.at / 1000;
          if (t < x0 || t > x1) continue;
          const x = Math.round(u.valToPos(t, 'x'));
          if (x < 0 || x > w) continue;
          const col = markColour(m.kind), words = `${markWords[m.kind] ?? m.kind} at ${fmtZone(new Date(m.at))}: ${m.label}`;
          kids.push(el('div', { class: 'chart-mark-line', 'aria-hidden': 'true', style: `position:absolute;top:0;bottom:0;left:${x}px;border-left:1px dashed ${col}` }));
          kids.push(el('a', { class: 'chart-mark', href: markHref(m), tabindex: '-1', 'data-kind': m.kind, 'data-at': new Date(m.at).toISOString(), 'aria-label': words, title: words,
            style: `position:absolute;top:1px;left:${x - 5}px;width:10px;height:10px;transform:rotate(45deg);background:${col};pointer-events:auto` }));
        }
        layer.replaceChildren(...kids);
      },
    },
  };
}

// fullWindow: a heading button that shows the chart over the window and back (Escape too); the chart is drawn again
// at the window's size and the focus stays on the button. A chart drawn again while open (a live page's refresh, a
// range change) opens again over the window: the choice is kept per page and chart title. The overlay sits under the
// menus (z-index 45 against the menu's 50), so the chart's own menu opens over it. Its Escape listener lives only while
// the view is open and goes with a chart taken off the page.
const fullOpen = new Set<string>();
function fullWindow(box: HTMLElement, title: string, u: uPlot, key: string) {
  const head = box.querySelector('h3');
  if (!head) return;
  for (const k of fullOpen) if (!k.startsWith(pageScope() + '|')) fullOpen.delete(k);   // another page's choice is not kept
  const btn = el('button', { type: 'button', class: 'chart-menu chart-full', 'aria-pressed': 'false', 'aria-label': `Full window: ${title}`, title: 'Show this chart over the whole window (Escape returns)' }, '\u2922') as HTMLButtonElement;
  let was: { w: number; h: number; style: string } | undefined;
  const esc = (e: KeyboardEvent) => {
    if (!box.isConnected) { document.removeEventListener('keydown', esc, true); return; }   // the chart left the page
    if (e.key === 'Escape' && was && !document.querySelector('.menu')) { e.preventDefault(); e.stopPropagation(); close(true); }
  };
  const close = (refocus: boolean) => {
    if (!was) return;
    box.setAttribute('style', was.style); box.classList.remove('chart-full-on');
    u.setSize({ width: was.w, height: was.h }); was = undefined;
    btn.setAttribute('aria-pressed', 'false');
    document.removeEventListener('keydown', esc, true);
    fullOpen.delete(key);
    if (refocus) btn.focus();
  };
  const open = () => {
    was = { w: u.width, h: u.height, style: box.getAttribute('style') ?? '' };
    const css = getComputedStyle(document.documentElement);
    box.classList.add('chart-full-on');
    box.setAttribute('style', `position:fixed;inset:0;z-index:45;overflow:auto;padding:1rem 1.5rem;background:${css.getPropertyValue('--card').trim() || css.getPropertyValue('--bg').trim() || '#fff'}`);
    u.setSize({ width: Math.max(300, innerWidth - 64), height: Math.max(220, innerHeight - 200) });
    btn.setAttribute('aria-pressed', 'true');
    document.addEventListener('keydown', esc, true);
    fullOpen.add(key);
  };
  btn.addEventListener('click', () => { if (was) close(true); else open(); });
  head.append(' ', btn);
  if (fullOpen.has(key)) open();
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
    // Export Excel (DBA Dash's chart menu): the same numbers as a workbook, a time as a time, each value a number
    ['Export Excel', () => {
      const cols = shown(), xs = u.data[0] as number[];
      const rows = xs.map((x, i) => [new Date(x * 1000), ...cols.map(c => {
        const tot = u.data[c.j][i], below = stacked && c.j > 1 ? u.data[c.j - 1][i] : 0;
        return tot == null ? null : Number(((tot as number) - ((below as number | null) ?? 0)).toPrecision(12));
      })]);
      void exportChart(title, ['time', ...cols.map(c => String(c.s.label ?? ''))], rows)
        .then(() => say(`Saved ${xs.length} points as Excel`), (x: unknown) => say('Export failed: ' + (x instanceof Error ? x.message : String(x))));
    }],
    ...(u.series.length > 2 ? [['Pick series', () => pickSeries(box, u, btn)] as [string, () => void]] : []),
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
function tooltipPlugin(fmtOf: (seriesIdx: number) => (v: number) => string, stacked = false): uPlot.Plugin {
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
          return s.show && v != null ? el('div', {}, el('span', { class: 'u-tip-key', style: `background:${c}` }), `${s.label}: ${fmtOf(j + 1)(v as number)}`) : null;
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

// pickSeries: the chart menu's 'Pick series' (DBA Dash's chart, part 1 J8: the server names picked on a chart): a box
// under the chart's heading with a tick per series by its name, All and None, and Done (Escape too) that closes it and
// gives the focus back to the menu button. A tick shows or hides its series at once; the choice is kept for the page
// (the chart's setSeries hook), so a refresh or another range keeps it.
function pickSeries(box: HTMLElement, u: uPlot, back: HTMLElement) {
  box.querySelector('.chart-pick')?.remove();
  const ticks = u.series.map((s, j) => {
    if (j === 0) return null;
    const c = el('input', { type: 'checkbox' }) as HTMLInputElement;
    c.checked = !!s.show;
    c.addEventListener('change', () => u.setSeries(j, { show: c.checked }));
    return el('label', { class: 'chart-pick-item' }, c, ' ', String(s.label ?? ''));
  }).filter((x): x is HTMLLabelElement => x !== null);
  const all = (show: boolean) => () => {
    u.batch(() => { for (let j = 1; j < u.series.length; j++) u.setSeries(j, { show }); });
    ticks.forEach(t => { (t.querySelector('input') as HTMLInputElement).checked = show; });
  };
  const bAll = el('button', { type: 'button' }, 'All'), bNone = el('button', { type: 'button' }, 'None'), done = el('button', { type: 'button' }, 'Done');
  bAll.addEventListener('click', all(true)); bNone.addEventListener('click', all(false));
  const panel = el('fieldset', { class: 'chart-pick', style: 'margin:.3rem 0;display:flex;flex-wrap:wrap;gap:.2rem .8rem;align-items:center' },
    el('legend', {}, 'Series shown'), ...ticks, el('span', {}, bAll, ' ', bNone, ' ', done));
  const close = () => { panel.remove(); back.focus(); };
  done.addEventListener('click', close);
  panel.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); } });
  box.querySelector('h3')?.after(panel);
  (panel.querySelector('input') as HTMLInputElement | null)?.focus();
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

// the Top N a reader chose on a pie, per pie title, remembered per browser
const TOPN = [5, 8, 10, 20];
const topKey = (title: string) => 'pgvigil.topn.' + title.replace(/\d+/g, '#');
function topGet(title: string): number | undefined { try { const v = localStorage.getItem(topKey(title)); return v === null ? undefined : Number(v); } catch { return undefined; } }
function topSet(title: string, n: number) { try { localStorage.setItem(topKey(title), String(n)); } catch { /* private window */ } }

// donutChart draws shares of a whole as a ring with the same numbers in a table beside it (DBA Dash's pie charts). The
// ring is one named image; the table is its accessible form and tells the slices apart by label, size and share, never
// by colour alone. Slices are drawn largest first unless keepOrder; past the Top N the smallest fold into 'other'. A
// slice with an href opens its page from its name in the table, and from its wedge on a click (part 1 J8: clickable
// slices; the keyboard's way is the table's link). Over five slices the heading offers the Top N (5, 8, 10, 20 or all;
// max is the default), kept per browser; its menu (the button, or a right-click on the ring) copies or saves the numbers
// or the picture.
export function donutChart(title: string, slices: Slice[], fmt: (v: number) => string = v => v.toLocaleString(),
                           max = 8, keepOrder = false, empty = 'Nothing to show yet.'): HTMLElement {
  return pieOrRing(title, slices, fmt, max, keepOrder, empty, 0);
}

// ringChart: the same chart drawn as a ring, its hole half the radius - DBA Dash's Deadlock Charts and Query Stats
// Charts rings (DeadlockChartsReport.cs, QueryStatsChartsReport.cs: InnerRadius = 0.5); every other pie stays a pie
export function ringChart(title: string, slices: Slice[], fmt: (v: number) => string = v => v.toLocaleString(),
                          max = 8, keepOrder = false, empty = 'Nothing to show yet.'): HTMLElement {
  return pieOrRing(title, slices, fmt, max, keepOrder, empty, 0.5);
}

// hole: the inner radius as a share of the outer one (0: a pie, each slice a wedge from the centre)
function pieOrRing(title: string, slices: Slice[], fmt: (v: number) => string, max: number, keepOrder: boolean, empty: string,
                   hole: number): HTMLElement {
  const box = el('div', { class: 'chart donut' }, el('h3', {}, title));
  let all = slices.filter(s => isFinite(s.value) && s.value > 0);
  if (!keepOrder) all = [...all].sort((a, b) => b.value - a.value);
  const total = all.reduce((a, s) => a + s.value, 0);
  if (!all.length) { box.append(el('p', { class: 'empty' }, empty)); return box; }
  const share = (v: number) => (100 * v / total).toLocaleString(undefined, { maximumFractionDigits: 1 }) + ' %';
  let top = topGet(title) ?? max;
  if (!(top === 0 || top >= 2)) top = max;   // 0 = all
  let parts: Slice[] = [];
  const fold = () => {
    parts = all;
    if (top > 0 && parts.length > top) {
      const rest = parts.slice(top - 1);
      parts = [...parts.slice(0, top - 1), { label: `other (${rest.length})`, value: rest.reduce((a, s) => a + s.value, 0) }];
    }
  };
  const body = el('div', { class: 'donut-body' });
  let ring: SVGElement;
  const draw = () => {
    fold();
    // each slice a wedge path from the centre (a dashed stroke of width 2r left a notch where two dashes met at the centre)
    const r = 54, r0 = r * hole;
    const at = (f: number, rad = r) => { const a = 2 * Math.PI * f - Math.PI / 2; return `${(60 + rad * Math.cos(a)).toFixed(3)} ${(60 + rad * Math.sin(a)).toFixed(3)}`; };
    // a ring's slice: the outer arc, in to the inner circle, the inner arc back; a ring's whole slice: a circle stroked
    // as wide as the ring
    const ringSlice = (from: number, f: number) => { const big = f > 0.5 ? 1 : 0;
      return `M${at(from)} A${r} ${r} 0 ${big} 1 ${at(from + f)} L${at(from + f, r0)} A${r0} ${r0} 0 ${big} 0 ${at(from, r0)} Z`; };
    ring = svg('svg', { viewBox: '0 0 120 120', role: 'img',
      'aria-label': `${title}: ` + parts.map(s => `${s.label} ${fmt(s.value)} (${share(s.value)})`).join(', ') });
    const tbody = el('tbody');
    let off = 0;
    const palette = seriesColors();
    parts.forEach((s, i) => {
      const color = colorAt(palette, i), f = s.value / total;
      const tip = svg('title', {}, `${s.label}: ${fmt(s.value)} (${share(s.value)})${s.href ? ' - click to open' : ''}`);
      // a slice of (nearly) the whole: its arc's two ends round to one point and SVG drops it, so it is the disc itself,
      // drawn under the others
      const whole = f > 0.9999;
      const arc = whole
        ? (hole > 0 ? svg('circle', { cx: '60', cy: '60', r: String((r + r0) / 2), fill: 'none', stroke: color, 'stroke-width': String(r - r0) }, tip)
                    : svg('circle', { cx: '60', cy: '60', r: String(r), fill: color }, tip))
        : svg('path', { d: hole > 0 ? ringSlice(off, f) : `M60 60 L${at(off)} A${r} ${r} 0 ${f > 0.5 ? 1 : 0} 1 ${at(off + f)} Z`, fill: color }, tip);
      off += f;
      // the ring is one image (no control inside an image: WCAG's nested-interactive): a wedge answers a pointer's click
      // only, and its page opens from its name in the table for the keyboard
      if (s.href) {
        const to = s.href;
        arc.setAttribute('data-href', to);
        arc.setAttribute('style', 'cursor:pointer');
        arc.addEventListener('click', () => { location.hash = to.replace(/^#/, ''); });
      }
      if (whole) ring.prepend(arc); else ring.append(arc);
      const sw = el('span', { class: 'swatch', 'aria-hidden': 'true' });
      sw.style.background = color;
      tbody.append(el('tr', {},
        el('td', {}, sw, s.href ? el('a', { href: s.href }, s.label) : s.label),
        el('td', { class: 'num' }, fmt(s.value)), el('td', { class: 'num' }, share(s.value))));
    });
    ring.addEventListener('contextmenu', e => { e.preventDefault(); showMenu(e.clientX, e.clientY, items, menuBtn); });
    body.replaceChildren(ring as unknown as HTMLElement,
      el('table', { class: 'legend' },
        el('thead', {}, el('tr', {}, el('th', { scope: 'col' }, 'name'), el('th', { scope: 'col', class: 'num' }, 'size'), el('th', { scope: 'col', class: 'num' }, 'share'))),
        tbody));
  };
  // the menu: the numbers (every slice, not only the Top N shown) or the picture of the ring with its legend
  const note = el('span', { class: 'meta chart-note', role: 'status' });
  const say = (t: string) => { note.textContent = t; };
  const fileName = (ext: string) => `${title.replace(/[^A-Za-z0-9]+/g, '_').replace(/^_+|_+$/g, '') || 'pie'}_${fileStamp(new Date())}.${ext}`;
  const table = (sep: string) => {
    const q = (v: string) => sep === ',' && /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
    return ['name' + sep + 'size' + sep + 'share_pct', ...all.map(s => [q(s.label), String(s.value), String(Number((100 * s.value / total).toPrecision(6)))].join(sep))].join('\n');
  };
  const image = (): Promise<Blob | null> => new Promise(res => {
    const css = getComputedStyle(document.documentElement);
    const bg = css.getPropertyValue('--card').trim() || '#fff', fg = css.getPropertyValue('--fg').trim() || '#1d2330';
    const k = devicePixelRatio || 1, side = 240 * k, pad = 12 * k, th = 26 * k, lh = 20 * k;
    const c = document.createElement('canvas');
    c.width = side + 2 * pad + 300 * k; c.height = Math.max(side, parts.length * lh) + th + 2 * pad;
    const g = c.getContext('2d');
    if (!g) { res(null); return; }
    const src = new XMLSerializer().serializeToString(ring);
    const img = new Image();
    img.onload = () => {
      g.fillStyle = bg; g.fillRect(0, 0, c.width, c.height);
      g.fillStyle = fg; g.textBaseline = 'middle'; g.font = `${14 * k}px system-ui, sans-serif`;
      g.fillText(title, pad, pad + th / 2);
      g.drawImage(img, pad, pad + th, side, side);
      g.font = `${12 * k}px system-ui, sans-serif`;
      const palette = seriesColors();
      parts.forEach((s, i) => {
        const y = pad + th + i * lh + lh / 2, x = 2 * pad + side;
        g.fillStyle = colorAt(palette, i); g.fillRect(x, y - 5 * k, 10 * k, 10 * k);
        g.fillStyle = fg; g.fillText(`${s.label}: ${fmt(s.value)} (${share(s.value)})`, x + 14 * k, y);
      });
      c.toBlob(res, 'image/png');
    };
    img.onerror = () => res(null);
    img.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(src.includes('xmlns=') ? src : src.replace('<svg', `<svg xmlns="${SVG_NS}"`));
  });
  const items: [string, () => void][] = [
    ['Copy image', () => { void (async () => {
      try { const b = await image(); if (!b) throw new Error('no image'); await navigator.clipboard.write([new ClipboardItem({ 'image/png': b })]); say('Copied the image'); }
      catch { say('Not copied: the browser refused the clipboard'); }
    })(); }],
    ['Save image', () => { void image().then(b => { if (b) { saveBlob(b, fileName('png')); say('Saved the image'); } else say('No image could be made'); }); }],
    ['Copy data', () => { void copyText(table('\t')).then(ok => say(ok ? `Copied ${all.length} slices` : 'Not copied: the browser refused the clipboard')); }],
    ['Export data (CSV)', () => { saveBlob(new Blob([table(',') + '\n'], { type: 'text/csv;charset=utf-8' }), fileName('csv')); say(`Saved ${all.length} slices`); }],
    // Export Excel: every slice as a row, its size a number and its share under '0.0%'
    ['Export Excel', () => {
      void exportChart(title, ['name', 'size', 'share'], all.map(s => [s.label, s.value, total ? s.value / total : null]), [undefined, undefined, 'pct'])
        .then(() => say(`Saved ${all.length} slices as Excel`), (x: unknown) => say('Export failed: ' + (x instanceof Error ? x.message : String(x))));
    }],
  ];
  const menuBtn = el('button', { type: 'button', class: 'chart-menu', 'aria-haspopup': 'menu', 'aria-label': `Chart menu: ${title}`, title: 'Copy or save this chart' }, '⋯') as HTMLButtonElement;
  menuBtn.addEventListener('click', () => { const r = menuBtn.getBoundingClientRect(); showMenu(r.left, r.bottom + 2, items, menuBtn); });
  const head = box.querySelector('h3')!;
  head.append(' ', menuBtn);
  if (all.length > TOPN[0]) {
    const sel = el('select', { class: 'donut-top', 'aria-label': `Slices shown: ${title}` }) as HTMLSelectElement;
    const choices = [...new Set([...TOPN, max])].filter(n => n < all.length).sort((a, b) => a - b);
    for (const n of choices) sel.append(el('option', { value: String(n), ...(n === top ? { selected: '' } : {}) }, `Top ${n}`));
    sel.append(el('option', { value: '0', ...(top === 0 || top >= all.length ? { selected: '' } : {}) }, `All ${all.length}`));
    sel.addEventListener('change', () => { top = Number(sel.value); topSet(title, top); draw(); });
    head.append(' ', sel);
  }
  head.append(note);
  draw();
  box.append(el('p', { class: 'meta', style: 'margin:0 0 .3rem' }, `total ${fmt(total)}`), body);
  return box;
}

// volumeBars draws each volume as one horizontal bar, used against its size (DBA Dash's drive bars): the filled part
// is the used share, coloured by the volume's status: the Drives page's judgement (drives_now: the threshold in force
// for that drive, task 176b: one rule), given by the caller; a volume without one is judged by the drive default,
// DBA Dash's (under 20 % free a warning, under 10 % critical). The status is also a word in the row, never the colour
// alone. The numbers stand beside the bar; the list is a table for a screen reader.
export interface Volume { name: string; used: number; free: number; note?: string; status?: string }
export function volumeBars(title: string, vols: Volume[], fmt: (v: number) => string, empty = 'No volume read yet.'): HTMLElement {
  const box = el('div', { class: 'chart bars' }, el('h3', {}, title));
  const rows = vols.filter(v => isFinite(v.used) && isFinite(v.free) && v.used + v.free > 0);
  if (!rows.length) { box.append(el('p', { class: 'empty' }, empty)); return box; }
  const body = el('tbody');
  for (const v of rows) {
    const total = v.used + v.free, usedPct = 100 * v.used / total, freePct = 100 - usedPct;
    const level = v.status === 'critical' ? 'crit' : v.status === 'warning' ? 'warn' : v.status === 'ok' ? 'ok' : freePct < 10 ? 'crit' : freePct < 20 ? 'warn' : 'ok';
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
