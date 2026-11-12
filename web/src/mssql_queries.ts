// The Queries page of a SQL Server instance (task 177 D10): PerformanceMonitor 3.12.0's Queries view (the server page's
// Queries tab, server-tabs.js; MIT License, Copyright (c) 2026 Erik Darling, Darling Data LLC) in its section order, on
// what pgvigil already stores. Each section but two is the head of a full tab: that tab's own read over the same range,
// its first rows, and a link to it (Running queries, Plan cache, Query Store, Slow queries). The query heatmap (the
// plan cache's stored reads in PerformanceMonitor's bins and buckets) and the Query Store's overhead (its QDS_* waits
// and its memory clerk) are this page's own. Every section reads when it first comes into view, by itself, so a slow
// one never holds the others; the page is off the 30 s refresh (main.ts).
//
// Also here, for the full tabs' wiring: queryHistory (one plan-cache query's average CPU and duration per execution,
// PerformanceMonitor's query trend) and procHistory (one procedure in PerformanceMonitor's four procedure metrics).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, rangeLabel, window_ } from './router';
import { sqlCell } from './sqlview';
import { rereadStrip, stripOverlay, timeStrip } from './timestrip';
import { Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

export const mssqlQueriesTab = 'mssqlqueries';
const HEAD = 10;   // a section's rows: the head of its full tab's own read

const text = (v: unknown) => v == null ? '' : String(v);
const dur = (v: unknown) => {
  if (v == null || v === '') return '';
  const n = Number(v), a = Math.abs(n);
  return a >= 60000 ? fmtNum(n / 60000) + ' min' : a >= 1000 ? fmtNum(n / 1000) + ' s' : fmtNum(n) + ' ms';
};
const stmt = (v: unknown) => v == null || v === '' ? '(no text stored)' : sqlCell(v);
const iso = (ms: number) => new Date(ms).toISOString();

// part: one section of the page, read the first time it comes into view (a browser without IntersectionObserver reads at
// once). The heading names the full tab it heads; read() fills the body or throws (an error box in the section only).
function part(id: string, title: string, link: [string, string] | null, read: (body: HTMLElement) => Promise<void>): HTMLElement {
  const body = el('div', { class: 'queries-body' }, el('p', { class: 'meta' }, 'Reads when it comes into view.'));
  const head = el('h3', { id: `q-${id}` }, title);
  const box = el('section', { class: 'queries-part', 'data-part': id, 'aria-labelledby': `q-${id}` }, head,
    ...(link ? [el('p', { class: 'meta' }, el('a', { href: link[0] }, link[1]))] : []), body);
  let started = false;
  const go = () => {
    if (started) return;
    started = true;
    body.replaceChildren(el('p', { class: 'meta', role: 'status' }, 'Reading ...'));
    read(body).catch(e => body.replaceChildren(errorBox(e)));
  };
  if (typeof IntersectionObserver === 'undefined') queueMicrotask(go);
  else {
    const io = new IntersectionObserver(es => { if (es.some(e => e.isIntersecting)) { io.disconnect(); go(); } }, { rootMargin: '200px' });
    io.observe(box);
  }
  return box;
}

// ---- the query heatmap: PerformanceMonitor's (query-heatmap.js, query-heatmap-model.js, DarlingQueryHeatmapReader.cs)

const METRICS: [string, string, string][] = [   // pgvigil's metric=, PerformanceMonitor's label, its words for the top cells
  ['duration', 'Duration (ms)', 'the slowest queries'], ['cpu', 'CPU (ms)', 'the queries using the most CPU'],
  ['writes', 'Logical Writes', 'the queries doing the most logical writes'], ['executions', 'Execution Count', 'the most-executed queries'],
];
const BUCKETS: Record<string, string[]> = {   // DarlingQueryHeatmapReader.cs:107-111, bottom (0) to top (6)
  duration: ['0-1ms', '1-10ms', '10-100ms', '100ms-1s', '1-10s', '10-100s', '>100s'],
  cpu: ['0-1ms', '1-10ms', '10-100ms', '100ms-1s', '1-10s', '10-100s', '>100s'],
  writes: ['0-1', '1-10', '10-100', '100-1K', '1K-10K', '10K-100K', '>100K'],
  executions: ['0-1', '1-10', '10-100', '100-1K', '1K-10K', '10K-100K', '>100K'],
};
const AT_QUERIES = 'Show Active Queries at This Time';   // query-heatmap.js:22
const REACH_MS = 168 * 3600e3;                            // DarlingMcpQueryHeatmapTools.cs:101-102
export const HEATMAP_LEGEND = 'Queries = distinct queries (database and query hash) whose 5-minute reads fell in this cell. '
  + 'PerformanceMonitor counts its 1-minute rows, so its counts run higher. A query that ran at two speeds in one bin counts in both cells.';
export const HEATMAP_TOO_LONG = 'the heatmap\'s read took too long for this range: pick 24 hours or less';

// shade: PerformanceMonitor's eight levels on a log scale against the busiest cell (query-heatmap-model.js:35-43)
function shade(count: number, max: number): number {
  if (!(count > 0)) return 0;
  if (!(max > 0)) return 1;
  return Math.min(8, Math.max(1, Math.ceil(8 * Math.log1p(Math.min(count, max)) / Math.log1p(max))));
}

// the Running queries page at a time, the range t +- 30 minutes (PerformanceMonitor's charts.js:1338, 1364)
export function runningAt(ctx: Ctx, t: number): string {
  return `${href(ctx, { tab: 'mssql_running', range: { from: iso(t - 1800e3), to: iso(t + 1800e3) } })}&at=${encodeURIComponent(iso(t))}`;
}

export function heatmapSection(ctx: Ctx): HTMLElement {
  const box = el('div', { class: 'heatmap' });
  const pick = el('select', { id: 'heat-metric' }) as HTMLSelectElement;
  for (const [v, label] of METRICS) pick.append(el('option', { value: v }, label));
  const out = el('div', {});
  box.append(el('p', {}, el('label', { for: 'heat-metric' }, 'Metric '), pick), out);
  const draw = async () => {
    const win = window_(ctx), from = Date.parse(win.from), to = Date.parse(win.to);
    if (to - from > REACH_MS + 60e3) {
      out.replaceChildren(el('p', { class: 'empty' }, 'The heatmap reaches 7 days (PerformanceMonitor\'s reach): pick 7 days or less.'));
      return;
    }
    out.replaceChildren(el('p', { class: 'meta', role: 'status' }, 'Reading the heatmap ...'));
    const metric = pick.value;
    let rows: Row[], reads: Row;
    try {
      const [h, r] = await Promise.all([
        get<{ heatmap: Table | null }>('mssql/plancache', { instance: ctx.instance, ...win, part: 'heatmap', metric }),
        get<{ reads: Table | null }>('mssql/plancache', { instance: ctx.instance, ...win, part: 'reads' }),
      ]);
      rows = rowsOf(h.heatmap); reads = rowsOf(r.reads)[0] ?? {};
    } catch (e) {
      // the UI pool's 15 s statement timeout cancelled the read: a plain line, never an error box or an empty grid
      out.replaceChildren(/statement timeout/.test(String((e as Error)?.message ?? e)) ? el('p', { class: 'empty heatmap-too-long' }, HEATMAP_TOO_LONG) : errorBox(e));
      return;
    }
    if (metric !== pick.value) return;   // a newer pick is reading
    const labels = BUCKETS[metric], top = METRICS.find(m => m[0] === metric)![2];
    if (!rows.length) {
      out.replaceChildren(el('p', { class: 'empty' }, 'No query of the plan cache\'s reads ran in this range (the mssql_plancache collection reads every five minutes).'));
      return;
    }
    const binMin = Number(rows[0].bin_minutes), binMs = binMin * 60e3, nCells = Number(rows[0].n_cells);
    const start = Math.floor(from / binMs) * binMs, cols = Math.max(1, Math.ceil((to - start) / binMs));
    const max = Math.max(...rows.map(r => Number(r.queries)));
    const cell = new Map<string, Row>();
    for (const r of rows) cell.set(`${Math.round((Date.parse(text(r.time_bin)) - start) / binMs)}:${r.bucket}`, r);
    const detail = el('div', { class: 'heatmap-detail', role: 'status' });
    const show = (r: Row) => {
      const t = Date.parse(text(r.time_bin));
      detail.replaceChildren(el('p', {},
        `${fmtTime(text(r.time_bin))} | ${labels[Number(r.bucket)]} | ${fmtNum(r.queries)} ${Number(r.queries) === 1 ? 'query' : 'queries'}; most executed: `,
        el('code', {}, text(r.query_key)), ` (${fmtNum(r.top_executions)} executions) ${text(r.top_query)} `,
        el('a', { href: runningAt(ctx, t + binMs / 2) }, AT_QUERIES)));
    };
    // the picture: a column per bin, a row per bucket (the largest at the top); a mouse picks a cell, the table below
    // carries every cell for a keyboard and a screen reader
    const pic = el('div', { class: 'heatmap-grid', 'aria-hidden': 'true' });
    pic.style.cssText = `display:grid;grid-template-columns:5.5rem repeat(${cols},minmax(2px,1fr));gap:1px;font-size:var(--fs-sm)`;
    for (let b = 6; b >= 0; b--) {
      pic.append(el('span', { class: 'meta' }, labels[b]));
      for (let c = 0; c < cols; c++) {
        const r = cell.get(`${c}:${b}`);
        const sq = el('span', { class: 'heatmap-cell' });
        sq.style.cssText = 'height:1.1rem;border-radius:1px;' + (r
          ? `background:color-mix(in srgb, var(--accent) ${Math.round(100 * shade(Number(r.queries), max) / 8)}%, var(--surface-card));cursor:pointer`
          : 'outline:1px solid var(--line);outline-offset:-1px');
        if (r) { sq.title = `${fmtTime(text(r.time_bin))} | ${labels[b]} | ${fmtNum(r.queries)} queries`; sq.addEventListener('click', () => show(r)); }
        pic.append(sq);
      }
    }
    const notes: HTMLElement[] = [el('p', { class: 'meta' }, `${binMin}-minute bins from the plan cache's stored reads, ${top} at the top. ${HEATMAP_LEGEND}`)];
    if (nCells > rows.length) notes.push(el('p', { class: 'meta' }, `The read returned only the most recent bins (${fmtNum(rows.length)} of ${fmtNum(nCells)} cells); the oldest are cut. Pick a shorter range to see them.`));
    if (Number(reads.cut_reads) > 0) notes.push(el('p', { class: 'meta' }, `${fmtNum(reads.cut_reads)} of ${fmtNum(reads.reads)} reads were cut at the collector's lists: a query past them is in no cell of those reads.`));
    const table = grid([...rows].reverse(), [
      { key: 'time_bin', label: 'Time Bin', fmt: fmtTime },
      { key: 'bucket', label: 'Magnitude', num: true, fmt: v => labels[Number(v)] ?? text(v) },
      { key: 'queries', label: 'Queries', num: true },
      { key: 'top_query', label: 'Most-Executed Query', fmt: v => text(v) || '(no text stored)' },
      { key: 'query_key', label: 'Query Hash' },
      { key: 'top_executions', label: 'its executions', num: true },
      { key: 'database', label: 'database' },
      { key: 'at', label: 'Running', fmt: (_, r) => el('a', { href: runningAt(ctx, Date.parse(text(r.time_bin)) + binMs / 2) }, AT_QUERIES) },
    ]);
    out.replaceChildren(...notes, pic, detail, table);
  };
  pick.addEventListener('change', () => { void draw(); });
  void draw();
  return box;
}

// ---- histories

// queryHistory: one plan-cache query ($dbId, its key) over the page's range: PerformanceMonitor's query trend
// (DarlingMcpTrendTools.cs:459-460) - average CPU and duration per execution at each point, here each of about 120
// steps weighted by its executions; a step with no run is a gap.
export async function queryHistory(ctx: Ctx, dbId: unknown, key: unknown, name: string): Promise<HTMLElement> {
  const d = await get<{ history: Table | null }>('mssql/plancache', { instance: ctx.instance, ...window_(ctx), db_id: text(dbId), key: text(key), part: 'history' });
  const rows = rowsOf(d.history);
  const cut = rows.reduce((s, r) => s + Number(r.cut_reads), 0), all = rows.reduce((s, r) => s + Number(r.reads), 0);
  const ran = rows.filter(r => Number(r.executions) > 0);
  if (!ran.length) return el('p', { class: 'empty' }, `${name} ran in no stored read of this range.`);
  return el('div', { class: 'query-history' },
    lineChart(`${name}: average duration and CPU per execution`, rows, [{ key: 'avg_duration_ms', label: 'avg duration' }, { key: 'avg_cpu_ms', label: 'avg CPU' }], v => dur(v)),
    el('p', { class: 'meta' }, `Each point is one step of the range's about 120 (${fmtNum(ran.length)} with runs, ${fmtNum(ran.reduce((s, r) => s + Number(r.executions), 0))} executions), its averages weighted by executions; a step without a run is a gap.`
      + (cut ? ` ${fmtNum(cut)} of ${fmtNum(all)} reads were cut at the collector's lists: the query may have run in them unlisted.` : '')));
}

const PROC_METRICS: [string, string][] = [   // PerformanceMonitor's stats-history.js:32-37, the first the default
  ['avg_duration_ms', 'Avg Duration (ms)'], ['avg_cpu_ms', 'Avg CPU (ms)'], ['duration_ms_s', 'Duration (ms/s)'], ['executions_s', 'Executions (per second)'],
];
let procPick = 0;

// procHistory: one procedure over the page's range in PerformanceMonitor's procedure history metrics, a Metric select
// over one chart.
export async function procHistory(ctx: Ctx, dbId: unknown, objectId: unknown, name: string): Promise<HTMLElement> {
  const d = await get<{ history: Table | null }>('mssql/procs', { instance: ctx.instance, ...window_(ctx), db_id: text(dbId), object: text(objectId), part: 'history' });
  const rows = rowsOf(d.history);
  const id = `proc-metric-${++procPick}`;
  const pick = el('select', { id }) as HTMLSelectElement;
  for (const [v, label] of PROC_METRICS) pick.append(el('option', { value: v }, label));
  const chart = el('div', {});
  const draw = () => {
    const [k, label] = PROC_METRICS.find(m => m[0] === pick.value)!;
    chart.replaceChildren(lineChart(`${name}: ${label}`, rows, [{ key: k, label }], v => k === 'executions_s' ? fmtNum(v) + ' /s' : k === 'duration_ms_s' ? fmtNum(v) + ' ms/s' : dur(v)));
  };
  pick.addEventListener('change', draw);
  draw();
  return el('div', { class: 'proc-history' }, el('p', {}, el('label', { for: id }, 'Metric '), pick), chart,
    el('p', { class: 'meta' }, 'Duration (ms/s) and Executions (per second) are over the seconds each step\'s reads cover; Avg Duration (ms) is the one over the other; a step without a run reads 0 per second and no averages.'));
}

// ---- the Query Store strip (PerformanceMonitor's 'Query Store duration' over its grid, server-tabs.js:1102, and its
// time slicer, time-slicer.js:115-122): the store's duration per step; a drag reads the grid again for the stretch,
// snapped out to the series' own step (the store's interval, or whole hours)

export function qsStrip(win: { from: string; to: string }, series: Row[], reread: (from?: string, to?: string, words?: string) => void): HTMLElement {
  const pts = series.map(r => ({ t: Date.parse(text(r.snapshot_at)), v: Number(r.duration_ms) || 0 }));
  const steps = pts.map(p => p.t).sort((a, b) => a - b);
  let snap = 3600e3;
  for (let i = 1; i < steps.length; i++) if (steps[i] - steps[i - 1] > 0) { snap = Math.min(snap, steps[i] - steps[i - 1]); }
  return rereadStrip('Query Store duration', win, pts, n => dur(n), snap, reread,
    'The store\'s duration over every plan per step. Drag across it to read the grid for that stretch, snapped to the store\'s intervals.');
}

// qsOverlay: one Query Store query's average duration per interval over the strip (PerformanceMonitor's row overlay)
export async function qsOverlay(ctx: Ctx, strip: HTMLElement, row: Row): Promise<void> {
  const win = window_(ctx);
  const d = await get<{ series: Table | null }>('mssql/querystore/query', { instance: ctx.instance, ...win, db: text(row.database_name), query: text(row.query_id), hash: text(row.query_hash) });
  const pts = rowsOf(d.series).map(r => ({ t: Date.parse(text(r.snapshot_at)), v: r.avg_duration_ms == null ? null : Number(r.avg_duration_ms) }));
  stripOverlay(strip, Date.parse(win.from), Date.parse(win.to), pts, `The line: query ${text(row.query_id)} of ${text(row.database_name)}, its average duration per interval (every plan).`);
}

// ---- the page

export async function mssqlQueriesView(ctx: Ctx): Promise<HTMLElement> {
  const win = window_(ctx), q = { instance: ctx.instance, ...win };
  const sec = el('section', {}, el('h2', {}, `Queries (${rangeLabel(ctx)})`),
    el('p', { class: 'meta' }, 'PerformanceMonitor\'s Queries view on what pgvigil stores: each section is the head of the tab it links to, read over the same range when it comes into view.'));
  let pc: Promise<Record<string, Table | null>> | null = null;   // the plan cache's series, read once for two sections
  const pcSeries = () => (pc ??= get<Record<string, Table | null>>('mssql/plancache', { ...q, part: 'series' }));

  sec.append(part('active', 'Active queries', [href(ctx, { tab: 'mssql_running' }), 'Running queries'], async body => {
    const d = await get<Record<string, Table | null>>('mssql/running', q);
    const snaps = rowsOf(d.snapshots), rows = rowsOf(d.rows);
    const t0 = Date.parse(win.from), t1 = Date.parse(win.to);
    const headGrid = (rs: Row[]) => grid(rs.slice(0, HEAD), [
      { key: 'session_id', label: 'session', num: true, fmt: v => String(v) }, { key: 'status' }, { key: 'wait_type', label: 'waiting on' },
      { key: 'elapsed_ms', label: 'running for', num: true, fmt: dur }, { key: 'database_name', label: 'database' }, { key: 'statement', fmt: stmt },
    ], 'No request in the newest snapshot of this range.');
    const g = el('div', {}, headGrid(rows));
    const at = el('p', { class: 'meta' }, snaps.length ? `The newest snapshot of the range, ${fmtTime(snaps[0].snapshot_at)}: its first ${HEAD} requests.` : '');
    const strip = timeStrip('Requests per snapshot', t0, t1, snaps.map(s => Date.parse(text(s.snapshot_at))), (_a, b) => {
      const when = b === undefined ? undefined : iso(Math.min(b, t1));
      void get<Record<string, Table | null>>('mssql/running', { ...q, at: when }).then(x => {
        const s = rowsOf(x.rows);
        at.textContent = when ? `The snapshot at or before ${fmtTime(when)}: its first ${HEAD} requests.` : `The newest snapshot of the range: its first ${HEAD} requests.`;
        g.replaceChildren(headGrid(s));
      }).catch(e => g.replaceChildren(errorBox(e)));
    }, snaps.length >= 1500 ? `The newest 1,500 snapshot times of the range (the Running page's own list).` : '',
    { weights: snaps.map(s => Number(s.requests) || 0), unit: n => `${fmtNum(n)} requests` });
    body.replaceChildren(strip, at, g);
  }));

  sec.append(part('duration', 'Query duration trend', [href(ctx, { tab: 'mssqlplancache' }), 'Plan cache'], async body => {
    const s = rowsOf((await pcSeries()).series);
    body.replaceChildren(lineChart('Query duration (every cached statement)', s, [{ key: 'duration_ms_s', label: 'duration ms/s' }, { key: 'cpu_ms_s', label: 'CPU ms/s' }], v => fmtNum(v) + ' ms/s'));
  }));

  sec.append(part('execs', 'Executions per second', [href(ctx, { tab: 'mssqlplancache' }), 'Plan cache'], async body => {
    const s = rowsOf((await pcSeries()).series);
    body.replaceChildren(lineChart('Executions per second (every cached statement)', s, [{ key: 'executions_s', label: 'executions/s' }], v => fmtNum(v) + ' /s'));
  }));

  sec.append(part('top', 'Top queries (plan cache)', [href(ctx, { tab: 'mssqlplancache' }), 'Plan cache: every query'], async body => {
    const top = rowsOf((await get<Record<string, Table | null>>('mssql/plancache', { ...q, part: 'top' })).top);
    const hist = el('div', {});
    const pickId = 'q-query';
    const pick = el('select', { id: pickId }) as HTMLSelectElement;
    pick.append(el('option', { value: '' }, 'pick a query'));
    top.slice(0, 100).forEach((r, i) => pick.append(el('option', { value: String(i) }, `${text(r.database)}: ${text(r.object_name) || text(r.query).slice(0, 60) || text(r.query_key)}`)));
    const showHist = (r: Row) => {
      hist.replaceChildren(el('p', { class: 'meta', role: 'status' }, 'Reading the history ...'));
      queryHistory(ctx, r.database_id, r.query_key, `${text(r.database)} ${text(r.query_key)}`).then(h => hist.replaceChildren(h)).catch(e => hist.replaceChildren(errorBox(e)));
    };
    pick.addEventListener('change', () => { const r = top[Number(pick.value)]; if (pick.value !== '' && r) showHist(r); else hist.replaceChildren(); });
    body.replaceChildren(grid(top.slice(0, HEAD), [
      { key: 'database' }, { key: 'object_name', label: 'object' },
      { key: 'executions', num: true }, { key: 'cpu_ms', label: 'total CPU', num: true, fmt: dur }, { key: 'avg_cpu_ms', label: 'avg CPU', num: true, fmt: dur },
      { key: 'duration_ms', label: 'total duration', num: true, fmt: dur }, { key: 'avg_duration_ms', label: 'avg duration', num: true, fmt: dur },
      { key: 'history', label: 'history', fmt: (_, r) => { const b = el('button', { type: 'button', class: 'link', 'aria-label': `History of ${text(r.query_key)}` }, 'History'); b.addEventListener('click', () => { pick.value = String(top.indexOf(r)); showHist(r); }); return b; } },
      { key: 'query', label: 'statement', fmt: stmt },
    ], 'No cached statement ran in this range.'), el('p', {}, el('label', { for: pickId }, 'Query '), pick), hist);
  }));

  sec.append(part('qs', 'Query Store', [href(ctx, { tab: 'mssqlqs' }), 'Query Store: Top'], async body => {
    const d = await get<Record<string, Table | null>>('mssql/querystore', { ...q, view: 'top' });
    const cols: Col[] = [
      { key: 'database_name', label: 'database' }, { key: 'query_id', label: 'query', num: true, fmt: v => text(v) },
      { key: 'executions', num: true }, { key: 'duration_ms', label: 'total duration', num: true, fmt: dur },
      { key: 'avg_duration_ms', label: 'avg duration', num: true, fmt: dur }, { key: 'avg_cpu_ms', label: 'avg CPU', num: true, fmt: dur },
      { key: 'line', label: 'on the strip', fmt: (_, r) => { const b = el('button', { type: 'button', class: 'link', 'aria-label': `Draw query ${text(r.query_id)} on the strip` }, 'Draw'); b.addEventListener('click', () => { void qsOverlay(ctx, strip, r).catch(e => said.replaceChildren(errorBox(e))); }); return b; } },
      { key: 'query', label: 'statement', fmt: stmt },
    ];
    const g = el('div', {}, grid(rowsOf(d.top).slice(0, HEAD), cols, 'No query ran in the store\'s intervals of this range.'));
    const said = el('p', { class: 'meta' }, `The store's first ${HEAD} queries by duration over the range.`);
    const strip = qsStrip(win, rowsOf(d.series), (from, to, words) => {
      void get<Record<string, Table | null>>('mssql/querystore', { ...q, from: from ?? win.from, to: to ?? win.to, view: 'top', part: 'top' }).then(x => {
        said.textContent = from ? `The store's first ${HEAD} queries by duration from ${words ?? ''} (snapped to the store's intervals: ${fmtTime(from)} to ${fmtTime(to)}).` : `The store's first ${HEAD} queries by duration over the range.`;
        g.replaceChildren(grid(rowsOf(x.top).slice(0, HEAD), cols, 'No query ran in the store\'s intervals of this stretch.'));
      }).catch(e => g.replaceChildren(errorBox(e)));
    });
    body.replaceChildren(strip, said, g);
  }));

  sec.append(part('regressed', 'Regressions', [`${href(ctx, { tab: 'mssqlqs' })}&qs=regressed`, 'Query Store: Regressed'], async body => {
    const d = await get<Record<string, Table | null>>('mssql/querystore', { ...q, view: 'regressed', base: '7d' });
    body.replaceChildren(grid(rowsOf(d.regressed).slice(0, HEAD), [
      { key: 'severity', label: 'Severity' }, { key: 'raised_by', label: 'Why' }, { key: 'database_name', label: 'Database' },
      { key: 'query_id', label: 'Query ID', num: true, fmt: v => text(v) }, { key: 'duration_regression_percent', label: 'Duration +%', num: true },
      { key: 'recent_timeouts', label: 'Recent Timeouts', num: true }, { key: 'recent_errors', label: 'Recent Errors', num: true },
      { key: 'query', label: 'Query', fmt: stmt },
    ], 'No query regressed against the 7 days before this range.'), el('p', { class: 'meta' }, 'Against PerformanceMonitor\'s baseline, the 7 days before the range.'));
  }));

  sec.append(part('heatmap', 'Query heatmap', null, async body => { body.replaceChildren(heatmapSection(ctx)); }));

  sec.append(part('overhead', 'Query Store overhead', null, async body => {
    const [o, m] = await Promise.all([
      get<Record<string, Table | null>>('mssql/querystore', { ...q, part: 'overhead' }),
      get<Record<string, Table | null>>('mssql/querystore', { ...q, part: 'qs_memory' }),
    ]);
    const waits = rowsOf(o.overhead), c = rowsOf(m.qs_memory)[0] ?? {};
    const types = waits.filter(w => w.wait_type != null);
    const perHour = types.reduce((s, w) => s + Number(w.wait_ms_per_hour), 0);
    const line = !waits.length ? 'No wait read in this range: nothing is known about Query Store\'s own waits.'
      : `Query Store's own waits: ${fmtNum(Math.round(perHour * 10) / 10)} ms per hour over ${fmtNum(Math.round(Number(waits[0].measured_secs)))} measured seconds (${fmtNum(waits[0].wait_reads)} wait reads), `
        + 'every QDS_* wait but the four sleep waits PerformanceMonitor leaves out (QDS_ASYNC_QUEUE, QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP, QDS_PERSIST_TASK_MAIN_LOOP_SLEEP, QDS_SHUTDOWN_QUEUE).';
    // PerformanceMonitor's clerk line, word for word (ViewerDataService.QueryStoreClutter.cs:294-301), with pgvigil's read
    const clerk = !Number(c.captures) ? 'No memory_clerks capture in this window, so nothing is known about MEMORYCLERK_QUERYDISKSTORE.'
      : !Number(c.clerk_samples) ? 'MEMORYCLERK_QUERYDISKSTORE never appeared in this window. pgvigil keeps the 25 largest clerks of each read, so that is a RANK, not a zero.'
      : `MEMORYCLERK_QUERYDISKSTORE: ${fmtNum(c.latest_mb)} MB latest, ${fmtNum(c.max_mb)} MB window max, on ${fmtNum(c.clerk_samples)} of ${fmtNum(c.captures)} captures.`
        + (text(c.latest_clerk_capture) === text(c.latest_capture) ? ' It is in the newest capture\'s top 25.' : ' It has since dropped out of the collector\'s top 25, so the latest figure is its last observed footprint, not its current one.');
    body.replaceChildren(el('p', { class: 'qs-overhead-line' }, line), el('p', { class: 'qs-memory-line' }, clerk),
      grid(types, [
        { key: 'wait_type', label: 'wait type' }, { key: 'wait_ms_per_hour', label: 'wait ms per hour', num: true },
        { key: 'wait_ms', label: 'wait ms', num: true }, { key: 'waiting_tasks', label: 'waiting tasks', num: true },
        { key: 'measured_secs', label: 'measured seconds', num: true, fmt: v => fmtNum(Math.round(Number(v))) }, { key: 'rows', num: true },
        { key: 'last_seen', label: 'last seen', fmt: fmtTime },
      ], 'No QDS_* wait grew in this range.'),
      el('p', { class: 'meta' }, 'Per server, never per database. pgvigil stores no wait delta across a restart or a reset, so PerformanceMonitor\'s unrateable rows have no counterpart here.'));
  }));

  sec.append(part('long', 'Long completions', [href(ctx, { tab: 'mssql_slow' }), 'Slow queries'], async body => {
    const d = await get<Record<string, Table | null>>('mssql/xe', { ...q, part: 'slow_shapes' });
    body.replaceChildren(grid(rowsOf(d.slow_shapes).slice(0, HEAD), [
      { key: 'shape', label: 'statement shape', wide: true, fmt: v => text(v) || '(no statement text stored)' },
      { key: 'events', num: true }, { key: 'total_ms', label: 'total', num: true, fmt: dur }, { key: 'worst_ms', label: 'worst', num: true, fmt: dur },
      { key: 'database_names', label: 'databases' }, { key: 'last_at', label: 'last', fmt: fmtTime },
    ], 'No batch or procedure call ran past the capture\'s threshold in this range (pgvigil\'s capture: 1 s; PerformanceMonitor\'s: 2 s).'));
  }));

  sec.append(part('tuning', 'Plan corrections and automatic tuning', [`${href(ctx, { tab: 'mssqlqs' })}&qs=tuning`, 'Query Store: Tuning'], async body => {
    const d = await get<Record<string, Table | null>>('mssql/querystore', { ...q, view: 'tuning' });
    body.replaceChildren(grid(rowsOf(d.tuning).slice(0, HEAD), [
      { key: 'database_name', label: 'database' }, { key: 'rec_type', label: 'type' }, { key: 'rec_state', label: 'state' },
      { key: 'query_id', label: 'query', num: true, fmt: v => text(v) }, { key: 'first_seen', label: 'first seen', fmt: fmtTime },
      { key: 'snapshot_at', label: 'last seen', fmt: fmtTime },
    ], 'No automatic tuning recommendation is listed for this range.'),
    grid(rowsOf(d.tuning_options), [
      { key: 'database_name', label: 'database' }, { key: 'option_name', label: 'option' }, { key: 'desired_state', label: 'desired' },
      { key: 'actual_state', label: 'actual' }, { key: 'reason', label: 'why' },
    ], 'No automatic tuning option read (SQL Server 2016 has none).'));
  }));
  return sec;
}
