// A statement's trend under its row (parity2 task 121; Darling 13.8 shot 92's History): a History button in a grid
// row opens a row under it with the statement's figures per interval over the page's window, and closes it again.
// Two sources (/api/stmttrend): a pg_stat_statements row (queryid: calls, rows, mean time, and the longest run of
// the same shape the server log recorded) and a slow-event shape of either engine (shape: events, failed, mean and
// longest duration, rows, mean CPU).
//
// trendCol(ctx, keyOf) is the grid column; keyOf picks the statement of a row (null = no button on that row).
// The Slow queries pages (slow.ts) use it; the Statements grid gets it through the lead's wiring (borrowed.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, window_ } from './router';
import { Col, el, errorBox, fmtNum, grid } from './ui';

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
  const box = el('div', { class: 'trend' });
  try {
    const p: Record<string, string | number | undefined> = { instance: k.instance, ...window_(ctx) };
    if (k.queryid != null) { p.queryid = String(k.queryid); if (k.db) p.db = String(k.db); }
    else { p.shape = String(k.shape); if (k.min) p.min = k.min; }
    const d = await get<Record<'meta' | 'trend', Table | null>>('stmttrend', p);
    const rows = rowsOf(d.trend), meta = rowsOf(d.meta)[0] ?? {};
    const every = `every ${fmtNum(Number(meta.secs ?? 60) / 60)} min`;
    box.append(el('p', { class: 'meta' }, `History of ${k.label} (${every}, from ${String(meta.source ?? '')}).`));
    if (k.queryid != null) {
      box.append(el('div', { class: 'charts' },
        lineChart('Mean and longest run', rows, [{ key: 'mean_ms', label: 'mean' }, { key: 'log_max_ms', label: 'longest (server log)' }], ms),
        lineChart('Calls and rows', rows, [{ key: 'calls', label: 'calls' }, { key: 'rows', label: 'rows' }])));
      box.append(el('p', { class: 'meta' }, 'The longest run comes from the server log (statements over log_min_duration_statement of the same shape): '
        + 'pg_stat_statements keeps no maximum per interval, so an interval with nothing logged has none.'));
    } else {
      box.append(el('div', { class: 'charts' },
        lineChart('Mean and longest', rows, [{ key: 'mean_ms', label: 'mean' }, { key: 'max_ms', label: 'longest' }], ms),
        lineChart('Events and rows', rows, [{ key: 'events', label: 'events' }, { key: 'failed', label: 'failed' }, { key: 'rows', label: 'rows' }])));
    }
    const cols: Col[] = k.queryid != null
      ? [{ key: 'snapshot_at', label: 'from' }, { key: 'calls', num: true }, { key: 'rows', num: true },
         { key: 'mean_ms', label: 'mean', num: true, fmt: msCell }, { key: 'total_ms', label: 'total', num: true, fmt: msCell },
         { key: 'log_max_ms', label: 'longest (log)', num: true, fmt: msCell }, { key: 'log_events', label: 'logged runs', num: true }]
      : [{ key: 'snapshot_at', label: 'from' }, { key: 'events', num: true }, { key: 'failed', num: true },
         { key: 'mean_ms', label: 'mean', num: true, fmt: msCell }, { key: 'max_ms', label: 'longest', num: true, fmt: msCell },
         { key: 'rows', num: true }, { key: 'mean_cpu_ms', label: 'mean CPU', num: true, fmt: msCell }];
    box.append(el('details', {}, el('summary', {}, 'The numbers as a table'), grid(rows, cols, 'Nothing in this window.')));
  } catch (e) {
    box.append(errorBox(e));
  }
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
        const row = el('tr', { class: 'trend-row' }, td);
        tr.after(row); open.set(tr, row);
        b.textContent = 'Hide history'; b.setAttribute('aria-expanded', 'true');
        void trendPanel(ctx, k).then(p => td.replaceChildren(p));
      });
      return b;
    },
  };
}
