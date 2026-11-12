// The SQL Server Waits tab (task 96): what the server waited on over the range, from the differences of
// sys.dm_os_wait_stats between two reads a minute apart: the top waits as a stacked chart with its numbers in a
// table behind it, and every wait type in a grid. The waits of idle background work are stored and listed last,
// outside the shares and the chart. Data from /api/mssql/waits; the route and the tab's entry are the shell's.
// The grid's rate columns and its descriptions (DBA Dash's Waits: Wait Time ms/sec, ms/sec/core, Description) come
// from /api/mssql/waitinfo: each wait type's time per second of the reads' covered seconds, that per scheduler, what
// a wait type means and, for a type without its own text, what its family (the start of its name) means.
// The findings, the signal ratio and SOS_SCHEDULER_YIELD tiles, the roll-up by category and the grant semaphores by
// resource pool (task 177, D03) come from /api/mssql/waitfindings: sp_PerfCheck's, sp_BlitzFirst's and sp_Blitz's
// checks and thresholds over the same range (0115).
import { neutralColor, seriesColors } from './chart';
import { get, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';
import { waitingLink } from './darling_waiting';

interface WaitsData { state: Table | null; reads: Table | null; events: Table | null; series: Table | null }
interface WaitInfo { cores: Table | null; rates: Table | null; types: Table | null; families: Table | null }
interface WaitFindings { findings: Table | null; shares: Table | null; rollup: Table | null; pools: Table | null }

const paletteNow = () => [...seriesColors(), neutralColor()];
const msSecs = (v: unknown) => v == null ? '' : fmtSecs(Math.round(Number(v) / 1000));
const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const kb = (v: unknown) => v == null ? '' : fmtBytes(Number(v) * 1024);
const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');

// the findings over the range: each with its source's check and priority in the text
const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge },
  { key: 'check_name', label: 'finding' },
  { key: 'object', label: 'wait' },
  { key: 'detail', fmt: v => el('span', { style: 'display:inline-block;min-width:28rem;max-width:52rem;white-space:normal' }, String(v ?? '')) },
  { key: 'source', fmt: (v, r) => `${String(v ?? '')} ${String(r.source_check ?? '')}` },
];
// the real waits of the range by the category of the grid below
const rollupCols: Col[] = [
  { key: 'category' },
  { key: 'wait_ms', label: 'wait time', num: true, fmt: msSecs },
  { key: 'pct', label: 'share', num: true, fmt: pct },
  { key: 'wait_types', label: 'wait types', num: true },
  { key: 'waiting_tasks', label: 'waits', num: true },
  { key: 'signal_ms', label: 'signal wait', num: true, fmt: msSecs },
  { key: 'top_wait', label: 'largest wait type' },
];
// the grant semaphores of the newest memory read in the range, per resource pool
const poolCols: Col[] = [
  { key: 'pool_name', label: 'resource pool', fmt: (v, r) => `${String(v ?? r.pool_id)}` },
  { key: 'semaphore_id', label: 'semaphore', fmt: v => Number(v) === 1 ? 'small queries' : 'regular' },
  { key: 'available_kb', label: 'available', num: true, fmt: kb },
  { key: 'granted_kb', label: 'granted', num: true, fmt: kb },
  { key: 'used_kb', label: 'used', num: true, fmt: kb },
  { key: 'target_kb', label: 'target', num: true, fmt: kb },
  { key: 'max_target_kb', label: 'max target', num: true, fmt: kb },
  { key: 'grantees', label: 'granted queries', num: true },
  { key: 'waiters', label: 'waiting queries', num: true },
  { key: 'forced_grants', label: 'forced grants (range)', num: true },
  { key: 'timeout_errors', label: 'grant timeouts (range)', num: true },
];

const eventCols: Col[] = [
  { key: 'wait_type', label: 'wait type', fmt: v => waitingLink(String(v), String(v).startsWith('LCK_') ? badge(String(v), 'warn') : String(v)) },
  { key: 'category', fmt: (v, r) => r.is_benign ? badge(String(v), '') : String(v ?? '') },
  { key: 'wait_ms', label: 'wait time', num: true, fmt: msSecs },
  { key: 'pct', label: 'share', num: true, fmt: pct },
  { key: 'waiting_tasks', label: 'waits', num: true },
  { key: 'avg_ms', label: 'average ms', num: true },
  { key: 'signal_pct', label: 'signal share', num: true, fmt: pct },
  { key: 'max_wait_ms', label: 'longest since the server started (ms)', num: true },
];
// the columns /api/mssql/waitinfo adds: the rates after the wait time, the description last
// three decimals, as the API rounds them: a rate under 0.005 would read 0 with the grid's two
const rate = (v: unknown) => v == null ? '' : Number(v).toLocaleString(undefined, { maximumFractionDigits: 3 });
const rateCols: Col[] = [
  { key: 'ms_per_sec', label: 'wait time (ms/sec)', num: true, fmt: rate },
  { key: 'ms_per_sec_core', label: 'wait time (ms/sec/core)', num: true, fmt: rate },
];
// the text wraps inside a block of its own width: left to the table, a column of wrapping text in a grid wider than
// the page shrinks to one character and its row grows thousands of pixels tall
const descCol: Col = { key: 'description', fmt: v => el('span', { style: 'display:inline-block;min-width:28rem;max-width:44rem;white-space:normal' }, String(v ?? '')) };
const idleText = 'Idle background work: a system task waiting for something to do. Kept, and never ranked.';

// describe gives each wait row its rates and its description: the type's own text; else, for a wait of idle
// background work, the idle note (PREEMPTIVE_XE_DISPATCHER is idle, whatever its family says); else its family's
// text (the longest matching start of the name); else nothing.
function describe(events: Row[], info: WaitInfo): void {
  const rates = new Map(rowsOf(info.rates).map(r => [String(r.wait_type), r] as [string, Row]));
  const types = new Map(rowsOf(info.types).map(r => [String(r.wait_type), String(r.description)] as [string, string]));
  const families = rowsOf(info.families).map(r => [String(r.prefix), String(r.description)] as [string, string]).sort((a, b) => b[0].length - a[0].length);
  for (const e of events) {
    const w = String(e.wait_type), r = rates.get(w);
    e.ms_per_sec = r?.ms_per_sec ?? null;
    e.ms_per_sec_core = r?.ms_per_sec_core ?? null;
    e.description = types.get(w) ?? (e.is_benign ? idleText : families.find(f => w.startsWith(f[0]))?.[1] ?? '');
  }
}

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
  // one window for both reads, so the rates are over the same reads as the grid
  const win = window_(ctx);
  let infoErr = '', findErr = '';
  const [d, info, wf] = await Promise.all([
    get<WaitsData>('mssql/waits', { instance: ctx.instance, ...win }),
    get<WaitInfo>('mssql/waitinfo', { instance: ctx.instance, ...win }).catch((e: unknown) => { infoErr = e instanceof Error ? e.message : String(e); return null; }),
    get<WaitFindings>('mssql/waitfindings', { instance: ctx.instance, ...win }).catch((e: unknown) => { findErr = e instanceof Error ? e.message : String(e); return null; }),
  ]);
  const events = rowsOf(d.events), st = rowsOf(d.state)[0], reads = rowsOf(d.reads)[0];
  if (info) describe(events, info);
  const cores = info ? rowsOf(info.cores)[0] : undefined;
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
  const sh = wf ? rowsOf(wf.shares)[0] : undefined;
  // sp_PerfCheck's server information: the signal wait ratio over the waits off its benign list (Normal, Moderate from
  // 25 %, High from 50 %), SOS_SCHEDULER_YIELD as a share of the time read (listed from 10 %)
  const label = String(sh?.signal_label ?? '');
  const signalTile = sh?.signal_ratio != null
    ? tile('signal wait ratio (sp_PerfCheck: Moderate from 25 %, High from 50 %)', `${pct(sh.signal_ratio)} (${label})`, label.startsWith('High') ? 'crit' : label.startsWith('Moderate') ? 'warn' : 'ok')
    : tile('signal share (waiting for a CPU)', waitMs ? pct(Math.round(1000 * signalMs / waitMs) / 10) : '-', waitMs && signalMs / waitMs > 0.25 ? 'warn' : '');
  const sos = sh?.sos_pct;
  sec.append(el('div', { class: 'tiles' },
    tile('wait time (idle background work left out)', msSecs(waitMs)),
    tile('tasks waiting on average', covered > 0 ? fmtNum(Math.round(100 * waitMs / 1000 / covered) / 100) : '-'),
    signalTile,
    !sh || !Number(sh.reads) ? tile('SOS_SCHEDULER_YIELD, share of the time read (listed from 10 %)', '-')
      : tile('SOS_SCHEDULER_YIELD, share of the time read (listed from 10 %)', sos == null ? '0 %' : pct(sos), sh.sos_listed ? 'warn' : 'ok'),
    tile('lock waits', waitMs ? pct(Math.round(1000 * lockMs / waitMs) / 10) : '-', lockMs > 0 ? 'warn' : 'ok'),
    tile('reads in the range', fmtNum(reads?.reads ?? 0))));
  const found = wf ? rowsOf(wf.findings) : [];
  sec.append(el('h3', {}, 'Findings over this range'), el('p', { class: 'meta' }, !wf
    ? `The findings were not read (${findErr}).`
    : 'sp_PerfCheck\'s wait, signal, SOS_SCHEDULER_YIELD, tempdb page latch and forced grant checks, sp_BlitzFirst\'s poison waits and '
      + 'sp_Blitz\'s range-lock and CMEMTHREAD-on-NUMA checks, with their thresholds and words, over the reads of this range: where the '
      + 'procedure reads the time since the server started, these read the seconds the range\'s reads cover'
      + (sh ? ` (${fmtNum(Math.round(Number(sh.covered_secs ?? 0)))} s in ${fmtNum(sh.reads ?? 0)} reads)` : '') + '. The Findings tab lists those of the last 15 minutes.'),
    grid(found, findingCols, 'No wait finding over this range.'));
  const p = pivot(rowsOf(d.series));
  sec.append(el('div', { class: 'charts' }, stackedChart('Tasks waiting on average, by wait type (the eight largest and the rest)', p)));
  const seriesCols: Col[] = [{ key: 'snapshot_at', label: 'step from', fmt: fmtTime }, ...p.types.map(t => ({ key: t, label: t, num: true } as Col))];
  const table = el('details', {}, el('summary', {}, 'The chart\'s numbers as a table'), grid(p.rows, seriesCols, 'No wait in this window.'));
  sec.append(table);
  if (wf) sec.append(el('h3', {}, 'Wait time by category'), el('p', { class: 'meta' },
    'The real waits of the range (idle background work left out) summed by the category of the grid below; share is of their wait time.'),
    grid(rowsOf(wf.rollup), rollupCols, 'No wait in this window.'));
  sec.append(el('h3', {}, 'Wait types'), el('p', { class: 'meta' },
    'Share is of the wait time of the real waits. Signal share is the part of a wait spent runnable, waiting for a CPU: a high one over all '
    + 'waits points at CPU pressure. The rows marked "Idle background work" are queue readers and timers waiting for work; they are kept and never ranked.'),
    el('p', { class: 'meta' }, !info
      ? `The rates per second and the descriptions were not read (${infoErr}).`
      : 'Wait time (ms/sec) is a wait type\'s time over the seconds the range\'s reads cover: 1,000 means one task waiting the whole time. '
        + (cores ? `Per core divides it by the ${fmtNum(cores.schedulers)} schedulers that ran user work at ${fmtTime(cores.snapshot_at)} (VISIBLE ONLINE, from the CPU collection).`
          : 'Per core is empty: no scheduler count was read (the mssql_cpu collection has not run on this instance).')),
    // the rates stand after the wait time, the description at the end
    grid(events, info ? [...eventCols.slice(0, 3), ...rateCols, ...eventCols.slice(3), descCol] : eventCols));
  if (wf) {
    const pools = rowsOf(wf.pools);
    sec.append(el('h3', {}, 'Memory grants by resource pool'), el('p', { class: 'meta' },
      'sys.dm_exec_query_resource_semaphores at the range\'s newest memory read'
      + (pools.length ? ` (${fmtTime(pools[0].snapshot_at)})` : '') + ': each resource pool has a regular semaphore and one for small queries. '
      + 'Waiting queries wait RESOURCE_SEMAPHORE; a forced grant is a query that ran with its minimum memory after waiting too long.'),
      grid(pools, poolCols, 'No memory read in this window (the mssql_memory collection reads the semaphores every minute).'));
  }
  return sec;
}
