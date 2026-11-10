// The SQL Server Waits tab (task 96): what the server waited on over the range, from the differences of
// sys.dm_os_wait_stats between two reads a minute apart: the top waits as a stacked chart with its numbers in a
// table behind it, and every wait type in a grid. The waits of idle background work are stored and listed last,
// outside the shares and the chart. Data from /api/mssql/waits; the route and the tab's entry are the shell's.
import { neutralColor, seriesColors } from './chart';
import { get, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

interface WaitsData { state: Table | null; reads: Table | null; events: Table | null; series: Table | null }

const paletteNow = () => [...seriesColors(), neutralColor()];
const msSecs = (v: unknown) => v == null ? '' : fmtSecs(Math.round(Number(v) / 1000));
const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';

const eventCols: Col[] = [
  { key: 'wait_type', label: 'wait type', fmt: v => String(v).startsWith('LCK_') ? badge(String(v), 'warn') : String(v) },
  { key: 'category', fmt: (v, r) => r.is_benign ? badge(String(v), '') : String(v ?? '') },
  { key: 'wait_ms', label: 'wait time', num: true, fmt: msSecs },
  { key: 'pct', label: 'share', num: true, fmt: pct },
  { key: 'waiting_tasks', label: 'waits', num: true },
  { key: 'avg_ms', label: 'average ms', num: true },
  { key: 'signal_pct', label: 'signal share', num: true, fmt: pct },
  { key: 'max_wait_ms', label: 'longest since the server started (ms)', num: true },
];

const SVG_NS = 'http://www.w3.org/2000/svg';
function svg(tag: string, attrs: Record<string, string>, ...kids: (Node | string)[]): SVGElement {
  const e = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const k of kids) e.append(k);
  return e;
}

// pivot turns (snapshot_at, wait_type, waiting) rows into one row per time with a column per wait type, the
// largest type first and 'other' last.
function pivot(rows: Row[]): { rows: Row[]; types: string[] } {
  const totals = new Map<string, number>();
  for (const r of rows) totals.set(String(r.wait_type), (totals.get(String(r.wait_type)) ?? 0) + Number(r.waiting));
  const types = [...totals.entries()].sort((a, b) => (a[0] === 'other' ? 1 : 0) - (b[0] === 'other' ? 1 : 0) || b[1] - a[1]).map(e => e[0]);
  const byTime = new Map<string, Row>();
  for (const r of rows) {
    const k = String(r.snapshot_at);
    if (!byTime.has(k)) byTime.set(k, Object.fromEntries([['snapshot_at', r.snapshot_at], ...types.map(t => [t, 0])]));
    byTime.get(k)![String(r.wait_type)] = Number(r.waiting);
  }
  return { rows: [...byTime.values()], types };
}

// stackedChart draws one bar per step, a segment per wait type. The picture is one named image; the legend names
// each colour and the table under it holds every number, so nothing is told by colour alone.
function stackedChart(title: string, p: { rows: Row[]; types: string[] }): HTMLElement {
  const box = el('div', { class: 'chart' }, el('h3', {}, title));
  if (!p.rows.length) { box.append(el('p', { class: 'empty' }, 'No wait in this window.')); return box; }
  const W = 720, H = 220, L = 46, B = 22, T = 6;
  const total = (r: Row) => p.types.reduce((a, t) => a + Number(r[t] ?? 0), 0);
  const max = Math.max(...p.rows.map(total), 0.001);
  const bw = (W - L) / p.rows.length;
  const peak = p.rows.reduce((a, r) => total(r) > total(a) ? r : a, p.rows[0]);
  const pic = svg('svg', { viewBox: `0 0 ${W} ${H}`, role: 'img', class: 'stacked',
    'aria-label': `${title}: ${p.rows.length} steps from ${fmtTime(p.rows[0].snapshot_at)} to ${fmtTime(p.rows[p.rows.length - 1].snapshot_at)}; `
      + `the peak is ${fmtNum(total(peak))} at ${fmtTime(peak.snapshot_at)}. The numbers are in the table below.` });
  pic.append(svg('line', { x1: String(L), y1: String(H - B), x2: String(W), y2: String(H - B), stroke: 'currentColor', 'stroke-opacity': '0.4' }),
    svg('text', { x: String(L - 4), y: String(T + 10), 'text-anchor': 'end', 'font-size': '11', fill: 'currentColor' }, fmtNum(max)),
    svg('text', { x: String(L - 4), y: String(H - B), 'text-anchor': 'end', 'font-size': '11', fill: 'currentColor' }, '0'),
    svg('text', { x: String(L), y: String(H - 6), 'font-size': '11', fill: 'currentColor' }, fmtTime(p.rows[0].snapshot_at)),
    svg('text', { x: String(W), y: String(H - 6), 'text-anchor': 'end', 'font-size': '11', fill: 'currentColor' }, fmtTime(p.rows[p.rows.length - 1].snapshot_at)));
  const pal = paletteNow();   // read once per chart: getComputedStyle per rectangle cost bars x types reads
  const colourOf = (t: string, ti: number) => t === 'other' ? pal[8] : pal[Math.min(ti, 7)];   // 'other' is always the neutral
  p.rows.forEach((r, i) => {
    let y = H - B;
    p.types.forEach((t, ti) => {
      const v = Number(r[t] ?? 0);
      if (v <= 0) return;
      const h = (H - B - T) * v / max;
      y -= h;
      pic.append(svg('rect', { x: String(L + i * bw + 0.5), y: String(y), width: String(Math.max(1, bw - 1)), height: String(h), fill: colourOf(t, ti) },
        svg('title', {}, `${fmtTime(r.snapshot_at)} ${t}: ${fmtNum(v)}`)));
    });
  });
  const legend = el('p', { class: 'meta' });
  p.types.forEach((t, ti) => {
    const sw = el('span', { class: 'swatch', 'aria-hidden': 'true' });
    sw.style.background = colourOf(t, ti);
    legend.append(sw, ' ' + t + '  ');
  });
  box.append(pic as unknown as HTMLElement, legend);
  return box;
}

export async function mssqlWaitsView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<WaitsData>('mssql/waits', { instance: ctx.instance, ...window_(ctx) });
  const events = rowsOf(d.events), st = rowsOf(d.state)[0], reads = rowsOf(d.reads)[0];
  const sec = el('section', {}, el('h2', {}, `Waits (${rangeLabel(ctx)})`));
  sec.append(el('p', { class: 'meta' }, 'Source: sys.dm_os_wait_stats, read every minute; the numbers are what was waited between two reads. '
    + 'A wait is counted when it ends: a session still waiting shows on the Running queries tab now and here once its wait is over. '
    + 'The first read after a server restart, or after someone cleared the counters, stores nothing.'
    + (st && st.status !== 'ok' ? ` The mssql_waits collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.` : '')));
  if (events.length === 0) {
    sec.append(el('p', { class: 'empty' }, 'No wait sample in this window (the first read of an instance only sets the starting counters).'));
    return sec;
  }
  const real = events.filter(r => !r.is_benign);
  const waitMs = real.reduce((a, r) => a + Number(r.wait_ms), 0), signalMs = real.reduce((a, r) => a + Number(r.signal_ms), 0);
  const lockMs = real.filter(r => String(r.wait_type).startsWith('LCK_')).reduce((a, r) => a + Number(r.wait_ms), 0);
  const covered = Number(reads?.covered_secs ?? 0);
  sec.append(el('div', { class: 'tiles' },
    tile('wait time (idle background work left out)', msSecs(waitMs)),
    tile('tasks waiting on average', covered > 0 ? fmtNum(Math.round(100 * waitMs / 1000 / covered) / 100) : '-'),
    tile('signal share (waiting for a CPU)', waitMs ? pct(Math.round(1000 * signalMs / waitMs) / 10) : '-', waitMs && signalMs / waitMs > 0.25 ? 'warn' : ''),
    tile('lock waits', waitMs ? pct(Math.round(1000 * lockMs / waitMs) / 10) : '-', lockMs > 0 ? 'warn' : 'ok'),
    tile('reads in the range', fmtNum(reads?.reads ?? 0))));
  const p = pivot(rowsOf(d.series));
  sec.append(el('div', { class: 'charts' }, stackedChart('Tasks waiting on average, by wait type (the eight largest and the rest)', p)));
  const seriesCols: Col[] = [{ key: 'snapshot_at', label: 'step from', fmt: fmtTime }, ...p.types.map(t => ({ key: t, label: t, num: true } as Col))];
  const table = el('details', {}, el('summary', {}, 'The chart\'s numbers as a table'), grid(p.rows, seriesCols, 'No wait in this window.'));
  sec.append(table);
  sec.append(el('h3', {}, 'Wait types'), el('p', { class: 'meta' },
    'Share is of the wait time of the real waits. Signal share is the part of a wait spent runnable, waiting for a CPU: a high one over all '
    + 'waits points at CPU pressure. The rows marked "Idle background work" are queue readers and timers waiting for work; they are kept and never ranked.'),
    grid(events, eventCols));
  return sec;
}
