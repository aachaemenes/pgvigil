// The global time range, top right (Darling's range control in DBA Dash's plain manner): a button that names the range,
// the display zone's offset beside it, and under the button a panel with the quick ranges that follow now, the calendar
// periods, a start / end picker and the display time-zone chooser (tz.ts). The control is ONE node for the life of the
// page (main.ts keeps it in the bar), so a refresh while the panel is open neither closes it nor takes the focus.
import { capRange, Ctx, href, MAX_RANGE_MS, periods, periodStart, presets, Range, window_ } from './router';
import { el } from './ui';
import { browserZone, fmt, fromInput, offsetLabel, parts, setZone, toInput, zonedToUtc, zoneChoice, zoneName, zones } from './tz';

// Task 152 (K09.02): besides the panel, the control has Earlier and Later buttons that move the window by its own length
// (keys [ and ]), and Zoom out that doubles it about its middle (key -; a preset that follows now takes the next preset
// at least twice its length); the panel has a typed range ('now-6h', 'now/d', 'now-2d to now-1d', two dates) whose
// parsed ends show as it is typed.
const quick: Record<string, string> = { '5m': 'Last 5 minutes', '15m': 'Last 15 minutes', '30m': 'Last 30 minutes', '1h': 'Last hour', '4h': 'Last 4 hours', '6h': 'Last 6 hours',
  '24h': 'Last 24 hours', '2d': 'Last 2 days', '7d': 'Last 7 days', '30d': 'Last 30 days' };

// parseTyped reads a range as typed: one end ('now-6h': from then to now) or two joined by 'to' (or '..'). An end is
// 'now', 'now' with steps (-6h, +30m, -2d, -1w; m is minutes), either of them rounded down to the start of its day,
// week (Monday) or month on the display zone's clock ('now/d', 'now-1d/d', 'now/w', 'now/M'), or a date with an
// optional time on that clock ('2026-01-15', '2026-01-15 12:00'). A rounded end is the period's start, so
// 'now-1d/d to now/d' is yesterday. Days and weeks are steps of the zone's calendar (now-1d is this time yesterday, 23
// or 25 hours back across a clock change); minutes and hours are lengths. A date that does not exist (2026-02-30) and
// an end past now are refused. A typed range that ends now and names a preset or a calendar period ('now-6h',
// 'now/d') is that preset and follows now; any other is a fixed from / to.
const unitMs: Record<string, number> = { m: 60e3, h: 3600e3, d: 86400e3, w: 7 * 86400e3 };
const roundTo: Record<string, string> = { d: 'today', w: 'wtd', M: 'mtd' };
type End = { at: Date; now: boolean; steps: number; round?: string; ms: number };
function typedEnd(t: string, now: Date): End | null {
  const rel = /^now((?:\s*[+-]\s*\d+\s*[mhdw])*)\s*(?:\/\s*([dwM]))?$/.exec(t);
  if (rel) {
    let ms = 0, days = 0, steps = 0;
    for (const m of rel[1].matchAll(/([+-])\s*(\d+)\s*([mhdw])/g)) {
      const n = (m[1] === '-' ? -1 : 1) * Number(m[2]);
      if (m[3] === 'd' || m[3] === 'w') days += n * (m[3] === 'w' ? 7 : 1); else ms += n * unitMs[m[3]];
      steps++;
    }
    let at = now;
    if (days) { const p = parts(now); at = zonedToUtc(p.y, p.mo, p.d + days, p.h, p.mi, p.s); }
    at = new Date(at.getTime() + ms);
    if (rel[2]) at = periodStart(roundTo[rel[2]], at);
    // ms: the step's length as a preset would read it (a day 86 400 s), for the preset match below
    return { at, now: true, steps, round: rel[2], ms: ms + days * 86400e3 };
  }
  const abs = /^(\d{4})-(\d\d)-(\d\d)(?:[ T](\d\d):(\d\d)(?::(\d\d))?)?$/.exec(t);
  if (abs) {
    const want = [1, 2, 3, 4, 5, 6].map(i => Number(abs[i] ?? 0));
    const at = zonedToUtc(want[0], want[1], want[2], want[3], want[4], want[5]);
    if (isNaN(at.getTime())) return null;
    // a date or time that does not exist rolls over (30 February is 2 March): refused, unless only a clock change moved it
    const p = parts(at);
    if (p.y !== want[0] || p.mo !== want[1] || p.d !== want[2] || (p.h !== want[3] && Math.abs(p.h - want[3]) > 1) || want[4] > 59 || want[5] > 59) return null;
    return { at, now: false, steps: 0, ms: 0 };
  }
  return null;
}
export function parseTyped(text: string, now: Date = new Date()): { range: Range; from: Date; to: Date } | { error: string } {
  const t = text.trim();
  if (!t) return { error: 'type a range: now-6h, now/d, now-2d to now-1d, or two dates' };
  const sides = t.split(/\s+to\s+|\s*\.\.\s*/i);
  if (sides.length > 2) return { error: "one 'to' at most" };
  const a = typedEnd(sides[0].trim(), now), b = sides.length === 2 ? typedEnd(sides[1].trim(), now) : { at: now, now: true, steps: 0, ms: 0 } as End;
  if (!a) return { error: `not a time: '${sides[0].trim()}'` };
  if (!b) return { error: `not a time: '${sides[1].trim()}'` };
  if (a.at >= b.at) return { error: 'the start must be before the end' };
  if (b.at.getTime() > now.getTime() + 60000) return { error: 'the end is past now' };
  if (b.at.getTime() - a.at.getTime() > MAX_RANGE_MS) return { error: '31 days at most' };
  // ends now: a preset of that length, or the period running ('now/d' alone)
  if (b.now && b.steps === 0 && !b.round && a.now) {
    if (a.steps === 0 && a.round) { const p = roundTo[a.round]; if (periods[p]) return { range: { preset: p }, from: a.at, to: b.at }; }
    if (a.steps === 1 && !a.round) { const p = Object.keys(presets).find(k => presets[k] * 1000 === -a.ms); if (p) return { range: { preset: p }, from: a.at, to: b.at }; }
  }
  return { range: { from: a.at.toISOString(), to: b.at.toISOString() }, from: a.at, to: b.at };
}

// the window moved by its length (dir -1 earlier, 1 later; never past now) or doubled about its middle (dir 0)
export function stepRange(ctx: Ctx, dir: -1 | 0 | 1, nowMs = Date.now()): Range | undefined {
  const w = window_(ctx), f = Date.parse(w.from), t = Date.parse(w.to), len = t - f;
  const fixed = (a: number, b: number): Range => { const c = capRange(new Date(a), new Date(b)); return { from: c.from.toISOString(), to: c.to.toISOString() }; };
  if (dir === 0) {
    const p = ctx.range.preset;
    if (p && presets[p]) {
      const next = Object.keys(presets).filter(k => presets[k] >= 2 * presets[p]).sort((x, y) => presets[x] - presets[y])[0];
      return next ? { preset: next } : fixed(nowMs - MAX_RANGE_MS, nowMs);
    }
    const mid = (f + t) / 2;
    let a = mid - len, b = mid + len;
    if (b > nowMs) { b = nowMs; a = nowMs - 2 * len; }
    return fixed(Math.max(a, b - MAX_RANGE_MS), b);
  }
  if (dir > 0 && (ctx.range.preset || t >= nowMs - 60000)) return undefined;   // already at now
  // a calendar period running now: Earlier is the whole period before it (yesterday, the week or the month before)
  const per = ctx.range.preset;
  if (dir < 0 && per && periods[per]) { const now = new Date(nowMs); return fixed(periodStart(per, now, 1).getTime(), periodStart(per, now).getTime()); }
  let a = f + dir * len, b = t + dir * len;
  if (b > nowMs) { b = nowMs; a = nowMs - len; }
  return fixed(a, b);
}

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

let root: HTMLElement | undefined, btn: HTMLButtonElement, zoneTag: HTMLElement, earlier: HTMLButtonElement, later: HTMLButtonElement, zoomOut: HTMLButtonElement;
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
    const stepBtn = (glyph: string, key: string, name: string, dir: -1 | 0 | 1) => {
      const b = el('button', { type: 'button', class: 'range-step', 'aria-label': name, 'aria-keyshortcuts': key, title: `${name} (${key})` }, glyph) as HTMLButtonElement;
      b.addEventListener('click', () => step(dir));
      return b;
    };
    earlier = stepBtn('\u2039', '[', 'Earlier: the window before this one', -1);
    later = stepBtn('\u203A', ']', 'Later: the window after this one', 1);
    zoomOut = stepBtn('\u2212', '-', 'Zoom out: twice the window', 0);
    const r = root = el('div', { class: 'range' }, earlier, btn, later, zoomOut, zoneTag);
    // the keys, anywhere on the page but in a field (a typed '-' or '[' stays the field's)
    document.addEventListener('keydown', e => {
      if (!r.isConnected || e.ctrlKey || e.metaKey || e.altKey || e.defaultPrevented) return;
      const t = e.target as HTMLElement | null;
      if (t instanceof Element && t.closest('input, textarea, select, [contenteditable=""], [contenteditable="true"]')) return;
      const dir = e.key === '[' ? -1 : e.key === ']' ? 1 : e.key === '-' ? 0 : null;
      if (dir === null) return;
      e.preventDefault();
      step(dir);
    });
    // Escape closes the panel and returns to the button; a click or a Tab that leaves the control closes it too, and so
    // do a resize (the panel was placed for the window as it was) and another address (the browser's Back or a link
    // followed by the keyboard: the panel belongs to the page it was opened on; a refresh of the same page keeps it)
    r.addEventListener('keydown', e => { if (e.key === 'Escape' && panel) { e.preventDefault(); e.stopPropagation(); close(true); } });
    r.addEventListener('focusout', e => { const to = e.relatedTarget as Node | null; if (panel && to && !r.contains(to)) close(false); });
    document.addEventListener('mousedown', e => { if (panel && !r.contains(e.target as Node)) close(false); });
    window.addEventListener('resize', () => close(false));
    window.addEventListener('hashchange', () => close(!!panel && panel.contains(document.activeElement)));   // a focus inside the panel goes back to the button, never to the page's body
  }
  sync();
  return root;
}

// closeRange: the panel shut without moving the focus (the sign-in form empties the bar the control sits in)
export function closeRange() { close(false); }

function step(dir: -1 | 0 | 1) {
  const r = stepRange(cur, dir);
  if (r) go(r);
}

function sync() {
  const w = window_(cur);
  // Later has nothing to show while the window ends now
  later.disabled = !stepRange(cur, 1);
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

  // a typed range: its parsed ends shown as it is typed, taken on Enter or Apply
  const typed = el('input', { type: 'text', class: 'range-typed', 'aria-label': 'a range as typed', 'aria-describedby': 'range-typed-preview', placeholder: 'now-6h, now/d, now-2d to now-1d', spellcheck: 'false', autocomplete: 'off' }) as HTMLInputElement;
  const preview = el('span', { class: 'meta', id: 'range-typed-preview', role: 'status' }, 'now-6h, now/d, now-1d/d to now/d, or two dates on the zone\'s clock');
  const take = el('button', { type: 'button' }, 'Apply');
  const read = () => parseTyped(typed.value);
  const show = () => {
    const p = read();
    preview.textContent = 'error' in p ? p.error : `${fmt(p.from)} to ${fmt(p.to)} (${span(p.to.getTime() - p.from.getTime())})${p.range.preset ? ', follows now' : ''}`;
    preview.classList.toggle('error', 'error' in p);
  };
  const use = () => { const p = read(); if ('error' in p) { show(); typed.focus(); return; } go(p.range); };
  typed.addEventListener('input', show);
  typed.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); use(); } });
  take.addEventListener('click', use);
  const typedSet = el('fieldset', { class: 'range-typed-set' }, el('legend', {}, 'Type a range'), typed, ' ', take, ' ', preview);
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

  return el('div', { class: 'range-panel', role: 'dialog', 'aria-label': 'Time range' }, quickSet, calSet, pickSet, typedSet, zoneSet);
}
