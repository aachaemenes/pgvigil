// Connection sources (task 127; pghero's Connections): every client connection of the window grouped by application,
// user, database and client, with its states, from the connections collection (a count per source each minute; idle
// connections included). The group switch rolls the table up to fewer dimensions. Data: /api/connections.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { window_ } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid } from './ui';
import { donutChart } from './chart';

const dims: [string, string, string][] = [['application', 'application_name', 'application'], ['user', 'usename', 'user'],
  ['database', 'datname', 'database'], ['client', 'client', 'client']];
const keyOf = 'pgvigil.connBy';

function loadBy(): string[] {
  try {
    const v = (localStorage.getItem(keyOf) ?? '').split(',').filter(x => dims.some(d => d[0] === x));
    return v.length ? v : dims.map(d => d[0]);
  } catch { return dims.map(d => d[0]); }
}

const blank = (v: unknown) => v == null ? '' : v === '' ? '(none)' : String(v);

export async function connectionsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Connections'));
  const body = el('div');
  let by = loadBy();
  const boxes = el('fieldset', { class: 'filters' }, el('legend', {}, 'Group by'),
    ...dims.map(([k, , label]) => {
      const cb = el('input', { type: 'checkbox', id: 'conn-by-' + k });
      cb.checked = by.includes(k);
      cb.addEventListener('change', () => {
        by = dims.map(d => d[0]).filter(x => (document.getElementById('conn-by-' + x) as HTMLInputElement | null)?.checked);
        if (!by.length) { cb.checked = true; by = [k]; }
        try { localStorage.setItem(keyOf, by.join(',')); } catch { /* private window */ }
        void draw();
      });
      return el('label', { for: 'conn-by-' + k, style: 'margin-right: 1.2rem; white-space: nowrap' }, cb, ' ' + label);
    }));
  async function draw() {
    const d = await get<{ sources: Table | null; meta: Table | null }>('connections', { instance: ctx.instance, ...window_(ctx), by: by.join(',') });
    const rows = rowsOf(d.sources), meta = rowsOf(d.meta)[0] ?? {};
    const nowTotal = rows.reduce((a, r) => a + Number(r.now_total ?? 0), 0);
    const cols: Col[] = [
      ...dims.filter(x => by.includes(x[0])).map(([, key, label]) => ({ key, label, fmt: blank } as Col)),
      { key: 'avg_total', label: 'average', num: true },
      { key: 'peak_total', label: 'peak', num: true },
      { key: 'now_total', label: 'newest read', num: true },
      { key: 'share_pct', label: 'share', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' %' },
      { key: 'avg_active', label: 'active (avg)', num: true },
      { key: 'peak_active', label: 'active (peak)', num: true },
      { key: 'avg_idle', label: 'idle (avg)', num: true },
      { key: 'avg_idle_in_txn', label: 'idle in tx (avg)', num: true },
      { key: 'peak_idle_in_txn', label: 'idle in tx (peak)', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : fmtNum(v) },
      { key: 'peak_waiting_lock', label: 'waiting on a lock (peak)', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : fmtNum(v) },
      { key: 'avg_other', label: 'state not shown (avg)', num: true },
      { key: 'reads_seen', label: 'reads seen', num: true, fmt: (v, r) => `${fmtNum(v)} / ${fmtNum(r.reads)}` },
      { key: 'last_seen', label: 'last seen', fmt: fmtTime },
    ];
    const pie = (label: string, key: string) => {
      const m = new Map<string, number>();
      for (const r of rows) m.set(blank(r[key]), (m.get(blank(r[key])) ?? 0) + Number(r.avg_total ?? 0));
      return donutChart(label, [...m.entries()].sort((a, b) => b[1] - a[1]).map(([l, v]) => ({ label: l, value: v })), v => fmtNum(v));
    };
    const pies = (['database', 'user'] as const).filter(k => by.includes(k)).map(k => pie(k === 'database' ? 'By database (average)' : 'By user (average)', k === 'database' ? 'datname' : 'usename'));
    body.replaceChildren(
      el('p', { class: 'meta' }, `${fmtNum(nowTotal)} connection(s) at the newest read (${fmtTime(meta.last_read) || 'none'})`
        + (meta.max_connections ? ` of max_connections ${fmtNum(meta.max_connections)}` : '')
        + `; ${fmtNum(meta.reads)} read(s) in the window, one a minute. Average: the connections per read over every read of the window; `
        + 'peak: the most at one read. "State not shown": sessions of other users the monitoring login may not see the state of (grant it pg_monitor).'),
      pies.length ? el('div', { class: 'charts' }, ...pies) : '',
      grid(rows as Row[], cols, 'No connection read in this window: the connections collection runs every minute.'));
  }
  sec.append(boxes, body);
  await draw();
  return sec;
}
