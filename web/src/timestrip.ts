// The time strip (Darling's, above its event grids): a band over the page's window with the events' density drawn in
// it, sixty steps wide. A drag across it narrows the grid under it to the stretch dragged; so does a click on one step,
// Shift+click for a stretch up to the step clicked, or the keyboard (arrows, Home and End move, Shift with them
// stretches, Enter narrows, Escape shows everything). 'Whole range' puts every row back. The narrowing is the page's
// own: the rows are already read, nothing is asked of the server again, and the grid keeps its sort, filters and paging
// (ui.ts narrowGrid). The times it names are on the display zone's clock (tz.ts).
// rereadStrip (task 177 D10, PerformanceMonitor's time slicer over its Query Store grid, time-slicer.js:115-122) is the
// other mode: the band draws a measure per step (the store's duration, not a count of rows), and a drag hands the
// stretch, snapped out to whole steps of the caller's own (a store's interval), back to the caller, which reads its grid
// again for it; stripOverlay draws one picked row's own measure as a line over the band.
import { Row } from './api';
import { Col, el, grid, narrowGrid } from './ui';
import { href, parse } from './router';
import { fmt, offsetLabel, offsetMin } from './tz';

const STEPS = 60;
const WHOLE = 'Whole range. Drag across the strip to narrow the grid.';

// A narrow outlives a redraw of the same page (the 30 s refresh, a return to the browser tab, a zone change): kept per
// address and strip as an instant pair, put back on the steps of the redrawn strip while it still lies in its window.
const kept = new Map<string, [number, number]>();
const keyOf = (title: string) => location.hash + '|' + title;

// stripGrid: a grid of events under its strip. key names the row's time (an ISO text); win is the window the page's read
// used (the same object, so a preset's 'now' is the read's); cap is the read's row limit: a read that came back full
// holds only the newest rows, so the strip starts at the oldest row read and says so instead of drawing the older part
// of the window as empty. Under two rows there is nothing to narrow: the grid alone.
export function stripGrid(title: string, win: { from: string; to: string }, rows: Row[], key: string, cols: Col[], empty = 'No rows.', cap = 0): HTMLElement {
  const g = grid(rows, cols, empty);
  let t0 = Date.parse(win.from);
  const t1 = Date.parse(win.to);
  if (rows.length < 2 || !(t1 > t0)) return g;
  const times = rows.map(r => Date.parse(String(r[key])));
  let capped = '';
  if (cap > 0 && rows.length >= cap) {
    const oldest = Math.min(...times.filter(t => !Number.isNaN(t)));
    if (oldest > t0 && oldest < t1) {
      t0 = oldest;
      capped = `The read holds the newest ${cap.toLocaleString()} rows only: the strip starts at the oldest of them, ${fmt(new Date(oldest))}.`;
    }
  }
  const narrow = (a?: number, b?: number, words = '') => {
    if (a === undefined || b === undefined) narrowGrid(g, undefined);
    else narrowGrid(g, r => { const t = Date.parse(String(r[key])); return t >= a && t < b; }, words);
  };
  return el('div', { class: 'strip-box' }, timeStrip(title, t0, t1, times, narrow, capped), g);
}

// timeStrip: the band alone. onNarrow gets the stretch as [from, to) in epoch milliseconds with its words, or nothing
// for the whole range. A time outside the window counts in no step (the whole range still shows its row).
// o.weights: each time's own amount (a measure in place of a count, rereadStrip); o.unit words an amount ('rows' by default).
export interface StripOpts { weights?: number[]; unit?: (n: number) => string }
export function timeStrip(title: string, t0: number, t1: number, times: number[], onNarrow: (from?: number, to?: number, words?: string) => void, note = '',
                          o: StripOpts = {}): HTMLElement {
  const step = (t1 - t0) / STEPS;
  const counts = new Array<number>(STEPS).fill(0);
  let inWindow = 0;
  times.forEach((t, i) => {
    if (!(t >= t0 && t <= t1)) return;
    const n = o.weights ? Number(o.weights[i]) || 0 : 1;
    counts[Math.min(STEPS - 1, Math.floor((t - t0) / step))] += n; inWindow += n;
  });
  const unit = o.unit ?? ((n: number) => `${n} rows`);
  const top = Math.max(1, ...counts);
  const bars = counts.map(n => {
    const b = el('span', { class: 'strip-step' });
    if (n) b.style.setProperty('--h', `${Math.max(14, Math.round(100 * n / top))}%`);
    return b;
  });
  // a time with its zone offset where the stretch crosses a clock change (a repeated hour reads twice otherwise)
  const at = (t: number, other: number) => fmt(new Date(t)) + (offsetMin(new Date(t)) !== offsetMin(new Date(other)) ? ' ' + offsetLabel(new Date(t)) : '');
  const ends = `${at(t0, t1)} to ${at(t1, t0)}`;
  const band = el('div', { class: 'strip-band', tabindex: '0', role: 'application', 'aria-roledescription': 'time strip',
    'aria-label': `${title}: ${unit(inWindow)} from ${ends} in ${STEPS} steps. Arrow keys, Home and End move, Shift with them stretches, Enter narrows the grid, Escape shows the whole range.` }, ...bars);
  const said = el('span', { class: 'meta', role: 'status' }, WHOLE);
  const whole = el('button', { type: 'button', class: 'link' }, 'Whole range');
  whole.hidden = true;
  // the stretch as the page's range (task 152): every chart and grid of the page reads it, and the address keeps it
  const asRange = el('button', { type: 'button', class: 'link strip-as-range', title: "Read the whole page over this stretch: it becomes the page's range" }, 'Use as the range');
  asRange.hidden = true;
  asRange.addEventListener('click', () => {
    if (lo < 0) return;
    const minute = 60000, from = Math.floor(edge(lo) / minute) * minute, to = Math.max(from + minute, Math.ceil((hi === STEPS - 1 ? t1 : edge(hi + 1)) / minute) * minute);
    const ctx = parse();
    location.hash = href(ctx, { tab: ctx.tab, range: { from: new Date(from).toISOString(), to: new Date(to).toISOString() }, at: undefined });
  });

  let lo = -1, hi = -1;   // the stretch the grid is narrowed to (steps, both ends in it); -1 = the whole range
  let cur = 0;            // the keyboard's step
  let drag = -1;          // the step a drag began on
  let stretch = -1;       // the step a Shift+arrow stretch began on
  const edge = (i: number) => t0 + i * step;
  const words = (a: number, b: number) => `${at(edge(a), edge(b + 1))} to ${at(b === STEPS - 1 ? t1 : edge(b + 1), edge(a))}`;
  const rowsIn = (a: number, b: number) => counts.slice(a, b + 1).reduce((s, v) => s + v, 0);
  const paint = (a: number, b: number) => bars.forEach((x, i) => {
    x.classList.toggle('out', a >= 0 && (i < a || i > b));
    x.classList.toggle('cur', document.activeElement === band && i === cur);
  });
  const apply = (a: number, b: number) => {
    lo = Math.min(a, b); hi = Math.max(a, b);
    paint(lo, hi);
    whole.hidden = false; asRange.hidden = false;
    // without a unit the strip keeps its sentence ('12 of 40 rows.'); an amount words both ends
    said.textContent = o.unit ? `${words(lo, hi)}: ${unit(rowsIn(lo, hi))} of ${unit(inWindow)}.` : `${words(lo, hi)}: ${rowsIn(lo, hi)} of ${inWindow} rows.`;
    // the last step takes a row stamped at the window's very end
    const from = edge(lo), to = hi === STEPS - 1 ? t1 + 1 : edge(hi + 1);
    kept.set(keyOf(title), [from, to]);
    onNarrow(from, to, words(lo, hi));
  };
  const clear = () => {
    const was = lo >= 0;
    lo = hi = -1; stretch = -1;
    paint(-1, -1);
    whole.hidden = true; asRange.hidden = true;
    said.textContent = WHOLE;
    kept.delete(keyOf(title));
    if (was) onNarrow();   // Escape on a pending Shift-stretch with nothing narrowed leaves the grid as it is
  };
  whole.addEventListener('click', () => { clear(); band.focus(); });

  const stepAt = (x: number) => { const r = band.getBoundingClientRect(); return Math.max(0, Math.min(STEPS - 1, Math.floor((x - r.left) / r.width * STEPS))); };
  band.addEventListener('pointerdown', e => {
    if (e.button !== 0) return;
    const s = stepAt(e.clientX);
    drag = e.shiftKey && lo >= 0 ? (s < lo ? hi : lo) : s;   // Shift+click: from the far end of the stretch already chosen
    cur = s;
    try { band.setPointerCapture(e.pointerId); } catch { /* a pointer that cannot be captured: the drag ends where it leaves the band */ }
    paint(Math.min(drag, s), Math.max(drag, s));
  });
  band.addEventListener('pointermove', e => {
    if (drag < 0) return;
    cur = stepAt(e.clientX);
    paint(Math.min(drag, cur), Math.max(drag, cur));
  });
  band.addEventListener('pointerup', e => {
    if (drag < 0) return;
    if (band.hasPointerCapture(e.pointerId)) band.releasePointerCapture(e.pointerId);
    const from = drag; drag = -1;
    apply(from, stepAt(e.clientX));
  });
  band.addEventListener('pointercancel', () => { drag = -1; paint(lo, hi); });

  band.addEventListener('keydown', e => {
    if (e.key === 'ArrowLeft' || e.key === 'ArrowRight' || e.key === 'Home' || e.key === 'End') {
      e.preventDefault();
      if (!e.shiftKey) stretch = -1; else if (stretch < 0) stretch = cur;
      cur = e.key === 'Home' ? 0 : e.key === 'End' ? STEPS - 1 : Math.max(0, Math.min(STEPS - 1, cur + (e.key === 'ArrowLeft' ? -1 : 1)));
      if (stretch >= 0) {
        const a = Math.min(stretch, cur), b = Math.max(stretch, cur);
        paint(a, b);
        said.textContent = `${words(a, b)}: ${unit(rowsIn(a, b))}. Enter narrows the grid to it.`;
      } else {
        paint(lo, hi);
        said.textContent = `${words(cur, cur)}: ${unit(counts[cur])}. Enter narrows the grid to this step.`;
      }
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      apply(stretch >= 0 ? stretch : cur, cur);
      stretch = -1;
    } else if (e.key === 'Escape' && (lo >= 0 || stretch >= 0)) {
      e.preventDefault();
      clear();
    }
  });
  band.addEventListener('focus', () => paint(lo, hi));
  band.addEventListener('blur', () => { stretch = -1; paint(lo, hi); });

  // the narrow this page had before its redraw, on this strip's steps, while it still lies in the window
  const before = kept.get(keyOf(title));
  if (before && before[0] >= t0 && before[0] < t1) {
    const a = Math.max(0, Math.min(STEPS - 1, Math.floor((before[0] - t0) / step)));
    const b = Math.max(a, Math.min(STEPS - 1, Math.ceil((Math.min(before[1], t1) - t0) / step) - 1));
    apply(a, b);
  } else kept.delete(keyOf(title));

  return el('div', { class: 'strip' },
    el('div', { class: 'strip-head' }, el('b', {}, title), said, whole, asRange),
    ...(note ? [el('p', { class: 'meta strip-note' }, note)] : []),
    band,
    el('div', { class: 'strip-ends meta', 'aria-hidden': 'true' }, el('span', {}, at(t0, t1)), el('span', {}, at(t1, t0))));
}

// rereadStrip: the band over a measure (points: a time and its amount, one per step of the caller's series); a drag, a
// click or the keyboard picks a stretch, snapped out to whole multiples of snapMs from the epoch (a store's interval),
// and reread gets it as ISO times with its words, or nothing for the whole range. 'Use as the range' works as on every
// strip. The caller's grid is read again for the stretch; nothing is narrowed in the page.
export function rereadStrip(title: string, win: { from: string; to: string }, points: { t: number; v: number }[], unit: (n: number) => string,
                            snapMs: number, reread: (from?: string, to?: string, words?: string) => void, note = ''): HTMLElement {
  const t0 = Date.parse(win.from), t1 = Date.parse(win.to);
  return timeStrip(title, t0, t1, points.map(p => p.t), (a, b, words) => {
    if (a === undefined || b === undefined) { reread(); return; }
    const from = Math.max(t0, Math.floor(a / snapMs) * snapMs), to = Math.min(t1, Math.max(from + snapMs, Math.ceil(b / snapMs) * snapMs));
    reread(new Date(from).toISOString(), new Date(to).toISOString(), words);
  }, note, { weights: points.map(p => p.v), unit });
}

// stripOverlay: one row's own measure drawn as a line over a strip's band (PerformanceMonitor's row overlay over its time
// slicer, server-tabs.js:1146-1150), scaled to its own largest point; an empty list takes the line away. The line is a
// picture of what the row's own chart and grid say in numbers: hidden from a screen reader, which reads label instead.
export function stripOverlay(strip: HTMLElement, t0: number, t1: number, points: { t: number; v: number | null }[], label: string): void {
  const band = strip.querySelector<HTMLElement>('.strip-band');
  if (!band) return;
  band.querySelector('svg.strip-overlay')?.remove();
  strip.querySelector('.strip-overlay-note')?.remove();
  const pts = points.filter(p => p.v != null && p.t >= t0 && p.t <= t1);
  if (!pts.length || !(t1 > t0)) return;
  const top = Math.max(...pts.map(p => Number(p.v))) || 1;
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('class', 'strip-overlay');
  svg.setAttribute('viewBox', '0 0 1000 100');
  svg.setAttribute('preserveAspectRatio', 'none');
  svg.setAttribute('aria-hidden', 'true');
  svg.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none;overflow:visible';
  const line = document.createElementNS(ns, 'polyline');
  line.setAttribute('points', pts.map(p => `${(1000 * (p.t - t0) / (t1 - t0)).toFixed(1)},${(96 - 92 * Number(p.v) / top).toFixed(1)}`).join(' '));
  line.setAttribute('fill', 'none');
  line.setAttribute('stroke', 'var(--text)');
  line.setAttribute('stroke-width', '2');
  line.setAttribute('vector-effect', 'non-scaling-stroke');
  svg.append(line);
  if (getComputedStyle(band).position === 'static') band.style.position = 'relative';
  band.append(svg);
  band.after(el('p', { class: 'meta strip-overlay-note' }, label));
}
