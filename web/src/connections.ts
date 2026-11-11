// Connection sources (task 127; pghero's Connections): every client connection of the window grouped by application,
// user, database and client, with its states, from the connections collection (a count per source each minute; idle
// connections included). The group switch rolls the table up to fewer dimensions. Above the grid a stacked chart of
// the connections over the window by one dimension (task 132; Darling's Application Connections is a grid alone: the
// chart is pgvigil's own): the eight largest sources by name, the rest as one band, each point the average per read
// of its bucket, so the bands sum to the instance's connections. Data: /api/connections (chart= adds the series).
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';
import { donutChart, lineChart } from './chart';

const dims: [string, string, string][] = [['application', 'application_name', 'application'], ['user', 'usename', 'user'],
  ['database', 'datname', 'database'], ['client', 'client', 'client']];
const keyOf = 'pgvigil.connBy', keyChart = 'pgvigil.connChart';

function loadBy(): string[] {
  try {
    const v = (localStorage.getItem(keyOf) ?? '').split(',').filter(x => dims.some(d => d[0] === x));
    return v.length ? v : dims.map(d => d[0]);
  } catch { return dims.map(d => d[0]); }
}

const blank = (v: unknown) => v == null ? '' : v === '' ? '(none)' : String(v);

function loadChart(): string {
  try { const v = localStorage.getItem(keyChart) ?? ''; return dims.some(d => d[0] === v) ? v : 'application'; } catch { return 'application'; }
}
// a bucket's width in the largest unit that reads well: 60 s '1 min', 2,040 s '34 min', 8,940 s '2.5 h'
const bucketLabel = (secs: number) => secs >= 86400 ? `${+(secs / 86400).toFixed(1)} d` : secs >= 5400 ? `${+(secs / 3600).toFixed(1)} h` : `${Math.round(secs / 60)} min`;

// seriesChart: the series part (one row per bucket and source, in rank order) as a stacked chart. lineChart's stacked
// bands take running totals, so each bucket's values are summed here in rank order: the largest source is the lowest
// band and the top line is the instance's total.
function seriesChart(series: Row[], meta: Row, dimLabel: string): HTMLElement {
  const names = new Map<number, string>();   // rank -> the series' label
  for (const r of series) {
    const k = Number(r.rank);
    if (!names.has(k)) names.set(k, r.folded === true ? `other (${fmtNum(r.sources)} more)` : blank(r.source));
  }
  const ranks = [...names.keys()].sort((a, b) => a - b);
  const byBucket = new Map<string, Row>();
  for (const r of series) {
    const at = String(r.snapshot_at);
    let row = byBucket.get(at);
    if (!row) { row = { snapshot_at: at }; byBucket.set(at, row); }
    row['v' + Number(r.rank)] = Number(r.avg_conns ?? 0);
  }
  const rows = [...byBucket.values()].sort((a, b) => Date.parse(String(a.snapshot_at)) - Date.parse(String(b.snapshot_at)));
  for (const row of rows) {
    let sum = 0;
    for (const k of ranks) { sum += Number(row['v' + k] ?? 0); row['s' + k] = sum; }
  }
  const title = `Connections over time by ${dimLabel} (average per read, buckets of ${bucketLabel(Number(meta.step_secs ?? 60))})`;
  return lineChart(title, rows, ranks.map(k => ({ key: 's' + k, label: names.get(k)! })), v => fmtNum(v), { stacked: true });
}

export async function connectionsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Connections'));
  const body = el('div');
  let by = loadBy(), chartBy = loadChart();
  const chartSel = el('select', { id: 'conn-chart-by' }, ...dims.map(([k, , label]) => el('option', { value: k }, label)));
  chartSel.value = chartBy;
  chartSel.addEventListener('change', () => {
    chartBy = chartSel.value;
    try { localStorage.setItem(keyChart, chartBy); } catch { /* private window */ }
    void draw();
  });
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
  let seq = 0;
  async function draw() {
    const mine = ++seq, want = [...by], wantChart = chartBy;
    type Parts = Record<'sources' | 'meta' | 'series' | 'series_meta', Table | null>;
    let d: Parts;
    try { d = await get<Parts>('connections', { instance: ctx.instance, ...window_(ctx), by: want.join(','), chart: wantChart }); }
    catch (e) { if (mine === seq) body.replaceChildren(errorBox(e)); return; }
    if (mine !== seq) return;   // a newer grouping was chosen while this one loaded: its columns would not fit these rows
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
    const series = rowsOf(d.series);
    const chartLabel = dims.find(x => x[0] === wantChart)?.[2] ?? wantChart;
    const pies = (['database', 'user'] as const).filter(k => by.includes(k)).map(k => pie(k === 'database' ? 'By database (average)' : 'By user (average)', k === 'database' ? 'datname' : 'usename'));
    body.replaceChildren(
      el('p', { class: 'meta' }, `${fmtNum(nowTotal)} connection(s) at the newest read (${fmtTime(meta.last_read) || 'none'})`
        + (meta.max_connections ? ` of max_connections ${fmtNum(meta.max_connections)}` : '')
        + `; ${fmtNum(meta.reads)} read(s) in the window, one a minute. Average: the connections per read over every read of the window; `
        + 'peak: the most at one read. "State not shown": sessions of other users the monitoring login may not see the state of (grant it pg_monitor).'),
      series.length ? el('div', { class: 'charts' }, seriesChart(series, rowsOf(d.series_meta)[0] ?? {}, chartLabel)) : '',
      pies.length ? el('div', { class: 'charts' }, ...pies) : '',
      grid(rows as Row[], cols, 'No connection read in this window: the connections collection runs every minute.'));
  }
  sec.append(el('div', { class: 'toolbar' }, el('label', { for: 'conn-chart-by' }, 'Chart by ', chartSel)), boxes, body);
  await draw();
  return sec;
}
