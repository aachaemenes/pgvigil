// The time strip (Darling's, above its event grids): a band over the page's window with the events' density drawn in
// it, sixty steps wide. A drag across it narrows the grid under it to the stretch dragged; so does a click on one step,
// Shift+click for a stretch up to the step clicked, or the keyboard (arrows, Home and End move, Shift with them
// stretches, Enter narrows, Escape shows everything). 'Whole range' puts every row back. The narrowing is the page's own: the rows are already
// read, nothing is asked of the server again, and the times it names are on the display zone's clock (tz.ts).
import { Row } from './api';
import { Col, el, grid } from './ui';
import { fmt } from './tz';

const STEPS = 60;
const WHOLE = 'Whole range. Drag across the strip to narrow the grid.';

// stripGrid: a grid of events under its strip. key names the row's time (an ISO text); win is the window the page read.
// Under two rows there is nothing to narrow: the grid alone.
export function stripGrid(title: string, win: { from: string; to: string }, rows: Row[], key: string, cols: Col[], empty = 'No rows.'): HTMLElement {
  const holder = el('div');
  const draw = (a?: number, b?: number) => {
    const all = a === undefined || b === undefined;
    holder.replaceChildren(grid(all ? rows : rows.filter(r => { const t = Date.parse(String(r[key])); return t >= a && t < b; }), cols, all ? empty : 'No row in the stretch chosen.'));
  };
  draw();
  const t0 = Date.parse(win.from), t1 = Date.parse(win.to);
  if (rows.length < 2 || !(t1 > t0)) return holder;
  return el('div', { class: 'strip-box' }, timeStrip(title, t0, t1, rows.map(r => Date.parse(String(r[key]))), draw), holder);
}

// timeStrip: the band alone. onNarrow gets the stretch as [from, to) in epoch milliseconds, or nothing for the whole
// range. A time outside the window counts in no step (the whole range still shows its row).
export function timeStrip(title: string, t0: number, t1: number, times: number[], onNarrow: (from?: number, to?: number) => void): HTMLElement {
  const step = (t1 - t0) / STEPS;
  const counts = new Array<number>(STEPS).fill(0);
  for (const t of times) if (t >= t0 && t <= t1) counts[Math.min(STEPS - 1, Math.floor((t - t0) / step))]++;
  const top = Math.max(1, ...counts);
  const bars = counts.map(n => {
    const b = el('span', { class: 'strip-step' });
    if (n) b.style.setProperty('--h', `${Math.max(14, Math.round(100 * n / top))}%`);
    return b;
  });
  const band = el('div', { class: 'strip-band', tabindex: '0', role: 'application', 'aria-roledescription': 'time strip',
    'aria-label': `${title}: ${times.length} rows over the range in ${STEPS} steps. Arrow keys, Home and End move, Shift with them stretches, Enter narrows the grid, Escape shows the whole range.` }, ...bars);
  const said = el('span', { class: 'meta', role: 'status' }, WHOLE);
  const whole = el('button', { type: 'button', class: 'link' }, 'Whole range');
  whole.hidden = true;

  let lo = -1, hi = -1;   // the stretch the grid is narrowed to (steps, both ends in it); -1 = the whole range
  let cur = 0;            // the keyboard's step
  let drag = -1;          // the step a drag began on
  let stretch = -1;       // the step a Shift+arrow stretch began on
  const edge = (i: number) => new Date(t0 + i * step);
  const words = (a: number, b: number) => `${fmt(edge(a))} to ${fmt(edge(b + 1))}`;
  const rowsIn = (a: number, b: number) => counts.slice(a, b + 1).reduce((s, v) => s + v, 0);
  const paint = (a: number, b: number) => bars.forEach((x, i) => {
    x.classList.toggle('out', a >= 0 && (i < a || i > b));
    x.classList.toggle('cur', document.activeElement === band && i === cur);
  });
  const apply = (a: number, b: number) => {
    lo = Math.min(a, b); hi = Math.max(a, b);
    paint(lo, hi);
    whole.hidden = false;
    said.textContent = `${words(lo, hi)}: ${rowsIn(lo, hi)} of ${times.length} rows.`;
    // the last step takes a row stamped at the window's very end
    onNarrow(t0 + lo * step, hi === STEPS - 1 ? t1 + 1 : t0 + (hi + 1) * step);
  };
  const clear = () => {
    lo = hi = -1; stretch = -1;
    paint(-1, -1);
    whole.hidden = true;
    said.textContent = WHOLE;
    onNarrow();
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
        said.textContent = `${words(a, b)}: ${rowsIn(a, b)} rows. Enter narrows the grid to it.`;
      } else {
        paint(lo, hi);
        said.textContent = `${words(cur, cur)}: ${counts[cur]} rows. Enter narrows the grid to this step.`;
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

  return el('div', { class: 'strip' },
    el('div', { class: 'strip-head' }, el('b', {}, title), said, whole),
    band,
    el('div', { class: 'strip-ends meta', 'aria-hidden': 'true' }, el('span', {}, fmt(new Date(t0))), el('span', {}, fmt(new Date(t1)))));
}
