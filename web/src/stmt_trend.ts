// A statement's trend under its row (parity2 task 121; Darling 13.8 shot 92's History): a History button in a grid
// row opens a row under it with the statement's figures per interval over the page's window, and closes it again.
// Two sources (/api/stmttrend): a pg_stat_statements row (queryid: calls, rows, mean time, and the longest run of
// the same shape the server log recorded) and a slow-event shape of either engine (shape: events, failed, mean and
// longest duration, rows, mean CPU).
//
// trendCol(ctx, keyOf) is the grid column; keyOf picks the statement of a row (null = no button on that row).
// The Slow queries pages (slow.ts) use it; the Statements grid gets it through the lead's wiring (borrowed.ts).
//
// parity3 task 125 (pgwatch's Query ID drill, shot 52, and its Time Lag Comparison): a pg_stat_statements row's panel
// shows calls, time per call and the buffers per interval, a compare of the window with one day earlier and with a
// chosen lag (1 h / 1 d / 7 d / a date; /api/stmtlag), and the statement's suggested index (plan.ts suggestBox).
import { get, Row, rowsOf, Table } from './api';
import { suggestBox } from './plan';
import { lineChart } from './chart';
import { Ctx, window_ } from './router';
import { Col, el, errorBox, fmtNum, grid } from './ui';
import { fmt as fmtZone, fromInput, toInput } from './tz';

export interface TrendKey {
  instance: number;
  queryid?: unknown;   // a pg_stat_statements queryid
  db?: unknown;        // its database (the row's datname), optional
  shape?: unknown;     // a slow-event shape key
  min?: number;        // the slow page's threshold (ms) for a shape
  label: string;       // what the opened row is about (its first characters)
}

const ms = (v: number) => v >= 60000 ? fmtNum(v / 60000) + ' min' : v >= 1000 ? fmtNum(v / 1000) + ' s' : fmtNum(v) + ' ms';
const msCell = (v: unknown) => v == null || v === '' ? '' : ms(Number(v));
const open = new WeakMap<HTMLTableRowElement, HTMLTableRowElement>();

// trendPanel: the charts and their numbers for one statement (also usable on its own).
export async function trendPanel(ctx: Ctx, k: TrendKey): Promise<HTMLElement> {
  const box = el('div', { class: 'trend', style: 'white-space:normal' });
  try {
    const w = window_(ctx);
    const p: Record<string, string | number | undefined> = { instance: k.instance, ...w };
    if (k.queryid != null) { p.queryid = String(k.queryid); if (k.db) p.db = String(k.db); }
    else { p.shape = String(k.shape); if (k.min) p.min = k.min; }
    const d = await get<Record<'meta' | 'trend', Table | null>>('stmttrend', p);
    const meta = rowsOf(d.meta)[0] ?? {};
    // every interval of the window gets a row: one with nothing has zero counts and no times, so the chart shows a
    // quiet interval as zero (or a gap) instead of joining the points either side of it
    const step = Number(meta.secs ?? 60) * 1000, got = new Map(rowsOf(d.trend).map(r => [new Date(String(r.snapshot_at)).getTime(), r]));
    const zero: Row = k.queryid != null ? { calls: 0, rows: 0, total_ms: 0, log_events: 0 } : { events: 0, failed: 0 };
    const rows: Row[] = [];
    for (let t = new Date(w.from).getTime(); t < new Date(w.to).getTime(); t += step) rows.push(got.get(t) ?? { snapshot_at: new Date(t).toISOString(), ...zero });
    // a series with no value in the window is left out (PostgreSQL's log has no rows, CPU or failures)
    const some = (ss: { key: string; label: string }[]) => ss.filter(x => rows.some(r => r[x.key] != null && Number(r[x.key]) !== 0));
    const every = `every ${fmtNum(Number(meta.secs ?? 60) / 60)} min`;
    box.append(el('p', { class: 'meta' }, `History of ${k.label} (${every}, from ${String(meta.source ?? '')}).`));
    if (k.queryid != null) {
      // per call: the interval's buffers over its calls (an interval with no call has none)
      for (const r of rows) {
        const c = Number(r.calls ?? 0);
        r.hit_per_call = c > 0 ? Number(r.shared_blks_hit ?? 0) / c : null;
        r.read_per_call = c > 0 ? Number(r.shared_blks_read ?? 0) / c : null;
      }
      box.append(el('div', { class: 'charts' },
        lineChart('Calls', rows, [{ key: 'calls', label: 'calls' }]),
        lineChart('Time per call and longest run', rows, some([{ key: 'mean_ms', label: 'per call' }, { key: 'log_max_ms', label: 'longest (server log)' }]), ms),
        lineChart('Buffers', rows, some([{ key: 'shared_blks_hit', label: 'shared hit' }, { key: 'shared_blks_read', label: 'shared read' },
          { key: 'temp_blks_written', label: 'temp written' }])),
        lineChart('Buffers per call', rows, some([{ key: 'hit_per_call', label: 'hit / call' }, { key: 'read_per_call', label: 'read / call' }])),
        lineChart('Rows', rows, [{ key: 'rows', label: 'rows' }])));
      box.append(el('p', { class: 'meta' }, 'The longest run comes from the server log (statements over log_min_duration_statement of the same shape): '
        + 'pg_stat_statements keeps no maximum per interval, so an interval with nothing logged has none. A buffer is 8 kB.'));
      // the compare and the suggestion read on their own: the panel (and its charts) goes on screen without waiting for them
      const lag = el('div', {}, el('p', { class: 'meta' }, 'Reading the compare...')), sug = el('div', {});
      box.append(lag, sug);
      void lagBox(ctx, k).then(b => lag.replaceChildren(b));
      void suggestBox({ instance: k.instance, queryid: k.queryid, db: k.db }).then(b => sug.replaceChildren(b));
    } else {
      box.append(el('div', { class: 'charts' },
        lineChart('Mean and longest', rows, [{ key: 'mean_ms', label: 'mean' }, { key: 'max_ms', label: 'longest' }], ms),
        lineChart('Events and rows', rows, some([{ key: 'events', label: 'events' }, { key: 'failed', label: 'failed' }, { key: 'rows', label: 'rows' }]))));
    }
    const cols: Col[] = k.queryid != null
      ? [{ key: 'snapshot_at', label: 'from' }, { key: 'calls', num: true }, { key: 'rows', num: true },
         { key: 'mean_ms', label: 'mean', num: true, fmt: msCell }, { key: 'total_ms', label: 'total', num: true, fmt: msCell },
         { key: 'shared_blks_hit', label: 'hit', num: true }, { key: 'shared_blks_read', label: 'read', num: true },
         { key: 'temp_blks_written', label: 'temp written', num: true },
         { key: 'log_max_ms', label: 'longest (log)', num: true, fmt: msCell }, { key: 'log_events', label: 'logged runs', num: true }]
      : [{ key: 'snapshot_at', label: 'from' }, { key: 'events', num: true }, { key: 'failed', num: true },
         { key: 'mean_ms', label: 'mean', num: true, fmt: msCell }, { key: 'max_ms', label: 'longest', num: true, fmt: msCell },
         { key: 'rows', num: true }, { key: 'mean_cpu_ms', label: 'mean CPU', num: true, fmt: msCell }];
    box.append(el('details', {}, el('summary', {}, 'The numbers as a table'), grid(rows.filter(r => Number(r.calls ?? r.events ?? 0) > 0), cols, 'Nothing in this window.')));
  } catch (e) {
    box.append(errorBox(e));
  }
  return box;
}

const lagChoices: [string, number][] = [['1 h', 3600], ['1 d', 86400], ['7 d', 604800]];
const dayLag = new Map<string, string>(); // the chosen lag per statement, kept while the page lives

// lagBox: the window against one day earlier (day over day) and against a chosen lag or date (pgwatch's Time Lag
// Comparison); a compared window with no snapshot says "no data", never zero.
async function lagBox(ctx: Ctx, k: TrendKey): Promise<HTMLElement> {
  const box = el('div', { class: 'lag', style: 'white-space:normal' });
  const key = `${k.instance}:${String(k.queryid)}:${String(k.db ?? '')}`;
  const draw = async (choice: string) => {
    dayLag.set(key, choice);
    const w = window_(ctx);
    const p: Record<string, string | number | undefined> = { instance: k.instance, ...w, queryid: String(k.queryid), db: k.db ? String(k.db) : undefined };
    if (choice.startsWith('at:')) p.at = choice.slice(3); else p.lag = Number(choice);   // 'at:' holds the instant, never the typed text
    const bar = el('div', { class: 'subtabs', role: 'group', 'aria-label': 'Compare with' }, el('span', { class: 'meta', style: 'align-self:center' }, 'Compare with'),
      ...lagChoices.map(([l, secs]) => {
        const a = el('a', { href: '#', class: choice === String(secs) ? 'on' : '', ...(choice === String(secs) ? { 'aria-current': 'true' } : {}) }, l + ' earlier');
        a.addEventListener('click', ev => { ev.preventDefault(); void draw(String(secs)); });
        return a;
      }));
    const dateIn = el('input', { type: 'datetime-local', 'aria-label': 'Compare with the window starting at', value: choice.startsWith('at:') ? toInput(new Date(choice.slice(3))) : '' }) as HTMLInputElement;
    // the typed time is the display zone's clock (tz.ts); what is kept is its instant, so a change of zone shows the same moment
    dateIn.addEventListener('change', () => { const t = fromInput(dateIn.value); if (!isNaN(t.getTime())) void draw('at:' + t.toISOString()); });
    bar.append(el('label', { class: 'meta', style: 'align-self:center' }, 'or from ', dateIn));
    let body: HTMLElement;
    try {
      const d = await get<Record<'lag', Table | null>>('stmtlag', p);
      const rs = rowsOf(d.lag);
      const now = rs[0] ?? {};
      const labels = ['this window', 'one day earlier', choice.startsWith('at:') ? 'from the chosen time' : `${lagChoices.find(c => String(c[1]) === choice)?.[0] ?? ''} earlier`];
      const vs = (v: unknown, base: unknown) => {
        if (v == null || base == null || Number(v) === 0) return '';
        const x = 100 * (Number(base) - Number(v)) / Number(v);
        return (x > 0 ? '+' : '') + fmtNum(Math.round(x)) + ' %';
      };
      const table = rs.map((r, i) => ({ ...r, label: labels[i] ?? '', change: i === 0 ? '' : vs(r.mean_ms, now.mean_ms), calls_change: i === 0 ? '' : vs(r.calls, now.calls) }));
      body = grid(table, [
        { key: 'label', label: 'window' },
        { key: 'from_at', label: 'from', fmt: v => fmtZone(new Date(String(v)), {}) },
        { key: 'calls', num: true, fmt: (v, r) => Number(r.instance_snapshots ?? 0) === 0 ? 'no data' : fmtNum(Math.round(Number(v ?? 0))) },
        { key: 'calls_change', label: 'now vs then', num: true },
        { key: 'mean_ms', label: 'time per call', num: true, fmt: msCell },
        { key: 'change', label: 'now vs then', num: true },
        { key: 'total_ms', label: 'total', num: true, fmt: msCell },
        { key: 'shared_blks_read', label: 'read', num: true, fmt: v => v == null ? '' : fmtNum(Math.round(Number(v))) },
        { key: 'shared_blks_hit', label: 'hit', num: true, fmt: v => v == null ? '' : fmtNum(Math.round(Number(v))) },
        { key: 'snapshots', label: 'its snapshots', num: true },
      ]);
    } catch (e) { body = errorBox(e); }
    box.replaceChildren(el('h4', {}, 'Then and now'), bar, body,
      el('p', { class: 'meta' }, '"now vs then": this window against that one (+ = it is higher now). "no data": pgvigil read no statements then (not collected or purged).'));
  };
  await draw(dayLag.get(key) ?? '3600');
  return box;
}

// trendCol: a History button per row; the opened row spans the grid under it (a sort redraws the grid and closes it).
export function trendCol(ctx: Ctx, keyOf: (r: Row) => TrendKey | null, label = 'history'): Col {
  return {
    key: '_trend', label,
    fmt: (_v, r) => {
      const k = keyOf(r);
      if (!k || (k.queryid == null && !k.shape)) return '';
      const b = el('button', { type: 'button', class: 'link', 'aria-expanded': 'false', title: `History of ${k.label}` }, 'History');
      b.addEventListener('click', () => {
        const tr = b.closest('tr') as HTMLTableRowElement | null;
        if (!tr) return;
        const was = open.get(tr);
        if (was) { was.remove(); open.delete(tr); b.textContent = 'History'; b.setAttribute('aria-expanded', 'false'); return; }
        const td = el('td', { colspan: String(tr.children.length) }, el('p', { class: 'meta' }, 'Reading...'));
        // a wide grid scrolls sideways: the panel keeps to the visible width, pinned to its left edge
        const wrap = tr.closest('.grid-wrap') as HTMLElement | null;
        const fit = (p: HTMLElement) => { if (wrap?.clientWidth) { p.style.position = 'sticky'; p.style.left = '0'; p.style.width = `${wrap.clientWidth - 24}px`; } return p; };
        const row = el('tr', { class: 'trend-row' }, td);
        tr.after(row); open.set(tr, row);
        b.textContent = 'Hide history'; b.setAttribute('aria-expanded', 'true');
        void trendPanel(ctx, k).then(p => td.replaceChildren(fit(p)));
      });
      return b;
    },
  };
}
