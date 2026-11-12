// The daily health calendar of one instance (task 177 D29): Darling's PerformanceMonitor's Daily Health Calendar on
// the instance's Summary. A month of UTC days, each banded Healthy, Warning or Critical by the day's signals (GET
// /api/healthcal, q_healthcal.go), a day with no collection 'no data' (a gap, never healthy), a future day 'not yet'.
// Previous / Next month (Next disabled on the current month), This month, Show as table / Show as calendar; a click on
// a day opens why it has its band, its figures and links to the pages that hold its rows.
//
// The band rule, its thresholds and its words are PerformanceMonitor 3.12.0's (PerformanceMonitor.Common/
// DailyHealthBand.cs, Darling/.../wwwroot/js/pages/daily-calendar.js, server-tabs.js), ported under its licence:
//   MIT License. Copyright (c) 2026 Erik Darling, Darling Data LLC. (The full notice: instheader.ts.)
// Critical: deadlocks or blocking at its critical rate (20 an hour; blocking also a 60 s wait), a severe memory
// event, or high-CPU reads (80 % and over) at least max(6, 1.25 per hour of the day). Warning: deadlocks or blocking
// at the warning rate (5 an hour; blocking also a 10 s wait), high-CPU reads at least max(1, 0.25 per hour), a memory
// pressure event, a collection error, or an alert; under an hour (today's first) any deadlock or blocking is a warning.
// pgvigil's own: the signals are pgvigil's samples (q_healthcal.go); collection errors without a run count (pgvigil
// logs failed runs only: PerformanceMonitor's rule without one, any error a warning, where its own takes over 20 % of
// the runs); PostgreSQL has no memory signal; the day's unique queries are not read.
import { get, Row, rowsOf, Table } from './api';
import { Band, blockingBand, deadlockBand } from './instheader';
import { Ctx, href } from './router';
import { el, grid, Col } from './ui';

type DayBand = Band | 'nodata' | 'future';
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const DAYS = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const word: Record<DayBand, string> = { ok: 'Healthy', warn: 'Warning', crit: 'Critical', unknown: 'no data', nodata: 'no data', future: 'not yet' };
const n = (v: unknown) => v == null ? 0 : Number(v);
const plural = (k: number, one: string, many = one + 's') => `${k} ${k === 1 ? one : many}`;

// dayBand: PerformanceMonitor's DailyHealthBandCalculator over pgvigil's signals
export function dayBand(d: Row): DayBand {
  if (!d.has_data) return 'nodata';
  const h = Math.max(n(d.hours), 1 / 60);
  const peak = d.peak_block_s == null ? null : n(d.peak_block_s);
  // under an hour PerformanceMonitor gives no rate: any deadlock or blocking is a warning (blocking's wait arm first)
  const dl = h < 1 ? (n(d.deadlocks) > 0 ? 'warn' : 'ok') : deadlockBand(n(d.deadlocks), h);
  const bl = h < 1 ? (peak != null && peak >= 60 ? 'crit' : (peak != null && peak >= 10) || n(d.blocking) > 0 ? 'warn' : 'ok') : blockingBand(n(d.blocking), peak, h);
  const hot = n(d.high_cpu);
  const cpuCrit = hot >= Math.max(6, 1.25 * h), cpuWarn = hot >= Math.max(1, 0.25 * h);
  if (dl === 'crit' || bl === 'crit' || n(d.mem_crit) > 0 || cpuCrit) return 'crit';
  // collection errors: pgvigil logs failed runs only, no run count - PerformanceMonitor's rule without one: any error
  if (dl === 'warn' || bl === 'warn' || cpuWarn || n(d.mem_pressure) > 0 || n(d.errors) > 0 || n(d.alerts) >= 1) return 'warn';
  return 'ok';
}

// dayReasons: why the day has its band, in PerformanceMonitor's words
export function dayReasons(d: Row): string[] {
  if (!d.has_data) return ['No collection this day.'];
  const h = Math.max(n(d.hours), 1 / 60), out: string[] = [];
  if (n(d.deadlocks) > 0) out.push(`${plural(n(d.deadlocks), 'deadlock')} (${h < 1 ? 'under an hour' : `${(n(d.deadlocks) / h).toFixed(1)}/hr`})`);
  if (n(d.errors) > 0) out.push(`${n(d.errors)} collection errors`);
  if (n(d.high_cpu) > 0) out.push(`${plural(n(d.high_cpu), 'high-CPU sample')}`);
  if (n(d.blocking) > 0) out.push(`${n(d.blocking)} blocking events (${h < 1 ? 'under an hour' : `${(n(d.blocking) / h).toFixed(1)} reports/hr`}${d.peak_block_s != null ? `, peak block ${n(d.peak_block_s).toFixed(1)} s` : ''})`);
  if (n(d.mem_crit) > 0) out.push(`${plural(n(d.mem_crit), 'severe memory-pressure event')}`);
  if (n(d.mem_pressure) > 0) out.push(`${plural(n(d.mem_pressure), 'memory-pressure event')}`);
  if (n(d.alerts) > 0) out.push(`${plural(n(d.alerts), 'alert')}`);
  return out.length ? out : ['No issues detected.'];
}

const bandCls = (b: DayBand) => b === 'crit' ? 'crit' : b === 'warn' ? 'warn' : b === 'ok' ? 'ok' : b === 'future' ? 'future' : 'nodata';
const iso = (d: Date) => d.toISOString().slice(0, 10);

// healthCalendar: the section, drawn at once and filled when its month is read (the Summary does not wait for it)
export function healthCalendar(ctx: Ctx, engine: unknown): HTMLElement {
  const now = new Date();
  const cur = { y: now.getUTCFullYear(), m: now.getUTCMonth() };
  const view = { ...cur };
  let asTable = false;
  const body = el('div', { class: 'healthcal-body' });
  const detail = el('div', { class: 'healthcal-day', role: 'region', 'aria-label': 'The day picked', 'aria-live': 'polite' });
  const sec = el('section', { class: 'healthcal', 'aria-label': 'Daily Health Calendar' },
    el('h3', {}, 'Daily Health Calendar ', el('span', { class: 'meta' }, 'month (UTC)')), body, detail,
    el('p', { class: 'meta' }, 'Days are UTC days. A day with no data was not collected, which is not the same as healthy.'));
  const sql = engine === 'sqlserver';
  const drills = (d: Row): HTMLElement[] => {
    const from = `${String(d.day).slice(0, 10)}T00:00:00Z`, to = new Date(Date.parse(from) + 86400000).toISOString();
    const at = (tab: string, label: string) => el('a', { href: href(ctx, { tab, range: { from, to } }) }, label);
    const out: HTMLElement[] = [];
    if (n(d.deadlocks) > 0) out.push(at(sql ? 'mssql_deadlocks' : 'pg_deadlocks', 'View Deadlocks'));
    if (n(d.blocking) > 0) out.push(at(sql ? 'mssql_blocked' : 'activity', 'View Blocking'));
    if (d.has_data) out.push(at(sql ? 'mssql_slow' : 'statements', 'View Top Queries'));
    return out;
  };
  const showDay = (d: Row | null, date: Date) => {
    const b: DayBand = d ? dayBand(d) : date.getTime() > now.getTime() ? 'future' : 'nodata';
    if (b === 'future') { detail.replaceChildren(el('h4', {}, 'Not yet'), el('p', {}, 'This day has not happened yet.')); return; }
    const reasons = d ? dayReasons(d) : ['No collection this day.'];
    detail.replaceChildren(
      el('h4', {}, `${DAYS[date.getUTCDay()]}, ${iso(date)} (UTC)`),
      el('p', {}, `Why this day is ${word[b]}:`),
      el('ul', {}, ...reasons.map(x => el('li', {}, x))),
      d && d.has_data ? el('p', { class: 'meta' }, `Top wait: ${d.top_wait ?? 'none read'}   High-CPU samples: ${n(d.high_cpu)}   Total wait: ${d.total_wait_s ?? 0} s   Unique queries: not read`) : '',
      ...(d ? [el('p', { class: 'healthcal-drills' }, ...drills(d).flatMap((a, i) => i ? [' ', a] : [a]))] : []));
  };
  const draw = async () => {
    const atCurrent = view.y === cur.y && view.m === cur.m;
    const label = `${MONTHS[view.m]} ${view.y} (UTC)`;
    const btn = (text: string, aria: string, go: () => void, disabled = false) => {
      const b = el('button', { type: 'button', class: 'tb-btn', 'aria-label': aria }, text);
      b.disabled = disabled;
      b.addEventListener('click', go);
      return b;
    };
    const step = (k: number) => () => { const t = new Date(Date.UTC(view.y, view.m + k, 1)); view.y = t.getUTCFullYear(); view.m = t.getUTCMonth(); detail.replaceChildren(); void draw(); };
    const nav = el('div', { class: 'toolbar healthcal-nav' },
      btn('‹', 'Previous month', step(-1)), el('span', { class: 'healthcal-month' }, label), btn('›', 'Next month', step(1), atCurrent),
      atCurrent ? '' : btn('This month', 'Back to this month', () => { view.y = cur.y; view.m = cur.m; detail.replaceChildren(); void draw(); }),
      // its words are its name (label-in-name); PerformanceMonitor's longer wording is its title
      (() => { const b = el('button', { type: 'button', class: 'tb-btn', title: asTable ? 'Show the month as a calendar' : 'Show the month as a table' }, asTable ? 'Show as calendar' : 'Show as table');
        b.addEventListener('click', () => { asTable = !asTable; void draw(); }); return b; })());
    body.replaceChildren(nav, el('p', { class: 'meta' }, `Loading ${MONTHS[view.m]} ${view.y}...`));
    let days: Row[] = [];
    try {
      const r = await get<{ days: Table | null }>('healthcal', { instance: ctx.instance, month: `${view.y}-${String(view.m + 1).padStart(2, '0')}` });
      days = rowsOf(r.days);
    } catch (e) {
      body.replaceChildren(nav, el('p', { class: 'error' }, `The month could not be read: ${e instanceof Error ? e.message : String(e)}`));
      return;
    }
    const byDay = new Map(days.map(d => [String(d.day).slice(0, 10), d]));
    if (asTable) {
      const rows = days.filter(d => d.has_data).reverse().map(d => ({ ...d, _band: word[dayBand(d)] }));
      const cols: Col[] = [
        { key: 'day', label: 'Date', fmt: v => String(v).slice(0, 10) }, { key: '_band', label: 'Band' },
        { key: 'top_wait', label: 'Top wait' }, { key: 'total_wait_s', label: 'Total wait (s)', num: true },
        { key: '_uq', label: 'Unique queries', fmt: () => 'not read' }, { key: 'blocking', label: 'Blocking', num: true },
        { key: 'peak_block_s', label: 'Peak block', fmt: v => v == null ? '' : `${n(v).toFixed(1)} s` }, { key: 'deadlocks', label: 'Deadlocks', num: true },
        { key: 'high_cpu', label: 'High CPU', num: true }, { key: 'mem_pressure', label: 'Mem pressure', num: true, fmt: v => v == null ? 'n/a' : String(v) },
        { key: 'alerts', label: 'Alerts', num: true }, { key: 'errors', label: 'Collection errors', num: true },
      ];
      body.replaceChildren(nav, grid(rows, cols, 'No collected days in this month. A day with any collection appears here, so a missing day is a gap in collection.'));
      return;
    }
    // the month's weeks, Sunday first; each day a button named by its date and band
    const first = new Date(Date.UTC(view.y, view.m, 1)), last = new Date(Date.UTC(view.y, view.m + 1, 0)).getUTCDate();
    const cells: HTMLElement[] = DAYS.map(x => el('div', { class: 'healthcal-head', 'aria-hidden': 'true' }, x.slice(0, 3)));
    for (let i = 0; i < first.getUTCDay(); i++) cells.push(el('div', { class: 'healthcal-pad', 'aria-hidden': 'true' }));
    for (let k = 1; k <= last; k++) {
      const date = new Date(Date.UTC(view.y, view.m, k)), key = iso(date), d = byDay.get(key) ?? null;
      const b: DayBand = date.getTime() > now.getTime() ? 'future' : d ? dayBand(d) : 'nodata';
      const tip = `${key} (UTC): ${word[b]}${b === 'nodata' ? '. No collection recorded for this day.' : b === 'future' ? '' : `. ${(d ? dayReasons(d) : []).join('; ')}`}`;
      const c = el('button', { type: 'button', class: `healthcal-cell ${bandCls(b)}${key === iso(now) ? ' today' : ''}`, 'aria-label': `${k} ${word[b]}, ${DAYS[date.getUTCDay()]} ${key}`, title: tip },
        el('span', { class: 'healthcal-num' }, String(k)), ' ', el('span', { class: 'healthcal-word' }, word[b]));
      c.addEventListener('click', () => { for (const x of body.querySelectorAll('.healthcal-cell[aria-pressed]')) x.removeAttribute('aria-pressed'); c.setAttribute('aria-pressed', 'true'); showDay(d, date); });
      cells.push(c);
    }
    body.replaceChildren(nav, el('div', { class: 'healthcal-grid', role: 'group', 'aria-label': `${MONTHS[view.m]} ${view.y}` }, ...cells));
  };
  void draw();
  return sec;
}
