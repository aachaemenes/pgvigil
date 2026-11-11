// The global time range, top right (Darling's range control in DBA Dash's plain manner): a button that names the range,
// the display zone's offset beside it, and under the button a panel with the quick ranges that follow now, the calendar
// periods, a start / end picker and the display time-zone chooser (tz.ts). The control is ONE node for the life of the
// page (main.ts keeps it in the bar), so a refresh while the panel is open neither closes it nor takes the focus.
import { capRange, Ctx, href, MAX_RANGE_MS, periods, periodStart, presets, Range, window_ } from './router';
import { el } from './ui';
import { browserZone, fmt, fromInput, offsetLabel, setZone, toInput, zoneChoice, zoneName, zones } from './tz';

const quick: Record<string, string> = { '15m': 'Last 15 minutes', '1h': 'Last hour', '6h': 'Last 6 hours', '24h': 'Last 24 hours', '7d': 'Last 7 days', '30d': 'Last 30 days' };

// span: a length by its two largest units ('14h 17m', '1d 14h', '7d'); under a minute reads '<1m'
function span(ms: number): string {
  const m = Math.floor(ms / 60000), d = Math.floor(m / 1440), h = Math.floor((m % 1440) / 60), mi = m % 60;
  if (d) return h ? `${d}d ${h}h` : `${d}d`;
  if (h) return mi ? `${h}h ${mi}m` : `${h}h`;
  return m ? `${m}m` : '<1m';
}
const short = (d: Date) => fmt(d, { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
// what the button reads: the range by its name, a typed one by its two ends
function label(ctx: Ctx): string {
  const p = ctx.range.preset;
  if (p) return quick[p] ?? (periods[p] ? periods[p][0].toUpperCase() + periods[p].slice(1) : 'Last ' + p);
  return `${short(new Date(ctx.range.from ?? ''))} - ${short(new Date(ctx.range.to ?? ''))}`;
}

let root: HTMLElement | undefined, btn: HTMLButtonElement, zoneTag: HTMLElement;
let panel: HTMLElement | undefined;
let cur: Ctx;
let zoneChanged: () => void = () => { /* rangePicker sets it */ };

// rangePicker returns the control, made once and brought up to the page's range on every call; onZone draws the page
// again after another display zone was chosen.
export function rangePicker(ctx: Ctx, onZone: () => void): HTMLElement {
  cur = ctx; zoneChanged = onZone;
  if (!root) {
    // the zone's offset is the button's description, so a screen reader hears it with the range
    zoneTag = el('span', { class: 'meta range-zone-tag', id: 'range-zone' });
    btn = el('button', { type: 'button', class: 'range-btn', 'aria-haspopup': 'dialog', 'aria-expanded': 'false', 'aria-describedby': 'range-zone' });
    btn.addEventListener('click', () => { if (panel) close(false); else open(); });
    const r = root = el('div', { class: 'range' }, btn, zoneTag);
    // Escape closes the panel and returns to the button; a click or a Tab that leaves the control closes it too, and so
    // do a resize (the panel was placed for the window as it was) and another address (the browser's Back or a link
    // followed by the keyboard: the panel belongs to the page it was opened on; a refresh of the same page keeps it)
    r.addEventListener('keydown', e => { if (e.key === 'Escape' && panel) { e.preventDefault(); e.stopPropagation(); close(true); } });
    r.addEventListener('focusout', e => { const to = e.relatedTarget as Node | null; if (panel && to && !r.contains(to)) close(false); });
    document.addEventListener('mousedown', e => { if (panel && !r.contains(e.target as Node)) close(false); });
    window.addEventListener('resize', () => close(false));
    window.addEventListener('hashchange', () => close(false));
  }
  sync();
  return root;
}

// closeRange: the panel shut without moving the focus (the sign-in form empties the bar the control sits in)
export function closeRange() { close(false); }

function sync() {
  const w = window_(cur);
  btn.textContent = 'Range: ' + label(cur);
  btn.title = `${fmt(new Date(w.from))} to ${fmt(new Date(w.to))}${cur.range.preset ? ' (follows now)' : ''}`;
  zoneTag.textContent = offsetLabel(new Date());
  zoneTag.title = `Times are in ${zoneName()}${zoneChoice() === 'local' ? " (the browser's zone)" : ''}`;
}

function open() {
  if (!root) return;
  const p = panel = build();
  root.append(p);
  btn.setAttribute('aria-expanded', 'true');
  // kept inside the window: the panel starts under the button and moves left as far as it must
  const r = root.getBoundingClientRect(), w = p.offsetWidth;
  let left = 0;
  if (r.left + w > innerWidth - 8) left = innerWidth - 8 - w - r.left;
  if (r.left + left < 8) left = 8 - r.left;
  p.style.left = `${left}px`;
  (p.querySelector<HTMLElement>('[aria-pressed="true"]') ?? p.querySelector<HTMLElement>('button'))?.focus();
}

function close(refocus: boolean) {
  if (!panel) return;
  panel.remove(); panel = undefined;
  btn.setAttribute('aria-expanded', 'false');
  if (refocus) btn.focus();
}

function go(range: Range) {
  close(true);
  location.hash = href(cur, { tab: cur.tab, range, at: undefined });
}

function build(): HTMLElement {
  // the three groups that depend on the clock and the zone: built once here and again in place after a change of zone
  const groups = (): [HTMLElement, HTMLElement, HTMLElement, string] => {
    const now = new Date();
    const fixed = (from: Date, to: Date): Range => { const w = capRange(from, to); return { from: w.from.toISOString(), to: w.to.toISOString() }; };
    const isCur = (r: Range) => r.preset ? cur.range.preset === r.preset : !cur.range.preset && cur.range.from === r.from && cur.range.to === r.to;
    const item = (text: string, right: string, r: Range) => {
      const b = el('button', { type: 'button', class: 'range-item', 'aria-pressed': isCur(r) ? 'true' : 'false' }, el('span', {}, text), el('span', { class: 'meta' }, right));
      b.addEventListener('click', () => go(r));
      return b;
    };
    // a length is the window's as it is read: cut to the server's longest like the window itself
    const len = (a: Date, b: Date) => { const w = capRange(a, b); return span(w.to.getTime() - w.from.getTime()); };

    const quickSet = el('fieldset', {}, el('legend', {}, 'Quick ranges'),
      ...Object.keys(presets).map(p => item(quick[p] ?? 'Last ' + p, p, { preset: p })));

    // the day, the week (from Monday) and the month on the display zone's clock: the one running, and the one before it
    const day0 = periodStart('today', now), week0 = periodStart('wtd', now), month0 = periodStart('mtd', now);
    const day1 = periodStart('today', now, 1), week1 = periodStart('wtd', now, 1), month1 = periodStart('mtd', now, 1);
    const calSet = el('fieldset', {}, el('legend', {}, 'Calendar periods'),
      item('Today', len(day0, now), { preset: 'today' }),
      item('Yesterday', len(day1, day0), fixed(day1, day0)),
      item('Week to date', len(week0, now), { preset: 'wtd' }),
      item('Previous week', len(week1, week0), fixed(week1, week0)),
      item('Month to date', len(month0, now), { preset: 'mtd' }),
      item('Previous month', len(month1, month0), fixed(month1, month0)));

    const w = window_(cur);
    const from = el('input', { type: 'datetime-local', 'aria-label': 'from' }), to = el('input', { type: 'datetime-local', 'aria-label': 'to' });
    from.value = toInput(new Date(w.from)); to.value = toInput(new Date(w.to));
    const apply = el('button', { type: 'button' }, 'Apply');
    const err = el('span', { class: 'error', role: 'alert' });
    apply.addEventListener('click', () => {
      const f = fromInput(from.value), t = fromInput(to.value);
      if (isNaN(f.getTime()) || isNaN(t.getTime()) || f >= t) { err.textContent = 'from must be before to'; return; }
      if (t.getTime() - f.getTime() > MAX_RANGE_MS) { err.textContent = '31 days at most'; return; }
      go({ from: f.toISOString(), to: t.toISOString() });
    });
    const pickSet = el('fieldset', { class: 'range-pick' }, el('legend', {}, 'A start and an end'), from, ' to ', to, ' ', apply, ' ', err);
    return [quickSet, calSet, pickSet, ` Times are in ${zoneName()} (${offsetLabel(now)} now); every page, chart and export follows.`];
  };
  let [quickSet, calSet, pickSet, note] = groups();
  const noteEl = el('span', { class: 'meta' }, note);

  const sel = el('select', { 'aria-label': 'display time zone' });
  const opt = (v: string, text: string) => { const o = el('option', { value: v }, text); if (v === zoneChoice()) o.selected = true; return o; };
  sel.append(opt('local', `Browser time (${browserZone()})`), ...zones().map(z => opt(z, z)));
  // a closed list fires a change on every arrow key and typed letter: the choice is taken once it rests, the page is
  // drawn again once, and the list itself stays where it is, so the focus never leaves it (the groups above are
  // rebuilt in place on the new clock). A panel closed before the choice rested still takes it.
  let resting: number | undefined;
  sel.addEventListener('change', () => {
    window.clearTimeout(resting);
    resting = window.setTimeout(() => {
      setZone(sel.value);
      zoneChanged();
      if (!sel.isConnected) return;
      const [q, c, k, n] = groups();
      quickSet.replaceWith(q); calSet.replaceWith(c); pickSet.replaceWith(k);
      quickSet = q; calSet = c; pickSet = k; noteEl.textContent = n;
    }, 400);
  });
  const zoneSet = el('p', { class: 'range-zone' }, el('label', {}, 'Display time zone ', sel), noteEl);

  return el('div', { class: 'range-panel', role: 'dialog', 'aria-label': 'Time range' }, quickSet, calSet, pickSet, zoneSet);
}
