// The Procedures tab of a SQL Server instance (task 130; DBA Dash's Object Execution): what each stored procedure
// did over the range, from the differences of sys.dm_exec_procedure_stats between two reads five minutes apart:
// executions, CPU, duration, reads and writes, as totals, per execution and per second. A database filter, the
// instance's totals over time, one row per procedure and, on a procedure's name, its own reads. Data from
// /api/mssql/procs; the route and the tab's entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { procHistory } from './mssql_queries';
import { compareSection } from './mssql_querystore';
import { rereadStrip, stripOverlay } from './timestrip';
import { Ctx, rangeLabel, window_ } from './router';
import { Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlProcsTab = 'mssqlprocs';

type Parts = Record<'state' | 'reads' | 'databases' | 'totals' | 'procs' | 'series' | 'func_state' | 'functions' | 'triggers', Table | null>;
const LIMIT = 2000;   // the grid's rows, as the API cuts them
// a figure the API rounds to three decimals is shown with all three (the grids' own two would turn 0.004 into 0)
const num3 = (v: unknown) => v == null ? '' : Number(v).toLocaleString(undefined, { maximumFractionDigits: 3 });
// a total in milliseconds, shown as seconds
const secs = (v: unknown) => v == null ? '' : num3(Math.round(Number(v)) / 1000);
// a figure the server may not have: "not read" for a NULL, never a 0
const nr = (f: (v: unknown) => string) => (v: unknown) => v == null ? 'not read' : f(v);

export async function mssqlProcsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Procedures (${rangeLabel(ctx)})`));
  sec.append(el('p', { class: 'meta' }, 'Source: sys.dm_exec_procedure_stats, read every five minutes; a figure is what ran between two reads. '
    + 'The view counts per cached plan: a procedure compiled, run and dropped from the plan cache between two reads is in no read, '
    + 'and the first read of an instance only sets the starting counters. The scalar functions and the triggers follow the procedures, '
    + 'from sys.dm_exec_function_stats and sys.dm_exec_trigger_stats read the same way.'));
  // the filter is a database of THIS instance: remembered per instance, by the database's id
  const store = `pgvigil.mssql.procs.db.${String(ctx.instance)}`;
  let database = (() => { try { return sessionStorage.getItem(store) ?? ''; } catch { return ''; } })();
  let extremes = (() => { try { return sessionStorage.getItem(`${store}.extremes`) === '1'; } catch { return false; } })();
  const sel = el('select', { 'aria-label': 'Database' }, el('option', { value: '' }, 'every database'));
  const body = el('div'), drill = el('div');
  let strip: HTMLElement | null = null;
  let seq = 0, drillSeq = 0;

  async function intervals(r: Row) {
    const mine = ++drillSeq;
    const name = `${r.schema_name ? String(r.schema_name) + '.' : ''}${String(r.object_name)}`;
    drill.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    try {
      const d = await get<{ intervals: Table | null }>('mssql/procs', { instance: ctx.instance, ...window_(ctx), db_id: Number(r.database_id), object: String(r.object_id), part: 'intervals' });
      if (mine !== drillSeq) return;
      drill.replaceChildren(el('h3', { tabindex: '-1' }, `${String(r.database)}: ${name}, read by read`), grid(rowsOf(d.intervals), [
        { key: 'snapshot_at', label: 'read', fmt: fmtTime },
        { key: 'interval_secs', label: 'interval', num: true, fmt: v => fmtSecs(Math.round(Number(v))) },
        { key: 'executions', num: true },
        { key: 'duration_ms', label: 'duration (ms)', num: true, fmt: num3 },
        { key: 'avg_duration_ms', label: 'avg duration (ms)', num: true, fmt: num3 },
        { key: 'cpu_ms', label: 'CPU (ms)', num: true, fmt: num3 },
        { key: 'avg_cpu_ms', label: 'avg CPU (ms)', num: true, fmt: num3 },
        { key: 'logical_reads', label: 'logical reads', num: true },
        { key: 'physical_reads', label: 'physical reads', num: true },
        { key: 'logical_writes', label: 'writes', num: true },
        { key: 'spills', label: 'spilled pages', num: true, fmt: v => v == null ? 'not read' : fmtNum(v) },
      ], 'No read of this procedure in the range.'));
      (drill.querySelector('h3') as HTMLElement).focus();   // the new block is announced and scrolled to
      const h = await procHistory(ctx, r.database_id, r.object_id, `${String(r.database)}: ${name}`);
      if (mine !== drillSeq) return;
      drill.append(h);
      if (strip) {
        const w = window_(ctx);
        const hd = await get<{ history: Table | null }>('mssql/procs', { instance: ctx.instance, ...w, db_id: Number(r.database_id), object: String(r.object_id), part: 'history' });
        if (mine === drillSeq) stripOverlay(strip, Date.parse(w.from), Date.parse(w.to), rowsOf(hd.history).map(x => ({ t: Date.parse(String(x.snapshot_at)), v: Number(x.duration_ms_s) })),
          `The line: ${String(r.database)}: ${name}, its Duration (ms/s) per step.`);
      }
    } catch (e) {
      if (mine === drillSeq) drill.replaceChildren(errorBox(e));
    }
  }

  // the columns of the three grids (procedures, functions, triggers): spills only where the view has them - the
  // function view has none at all, so its grid has no such column rather than "not read"
  function statCols(name: Col['fmt'], spills: boolean): Col[] {
    return [
      { key: 'database' },
      { key: 'schema_name', label: 'schema' },
      { key: 'object_name', label: 'name', ...(name ? { fmt: name } : {}) },
      { key: 'type_desc', label: 'type', fmt: v => String(v ?? '').replace(/_/g, ' ').toLowerCase() },
      { key: 'duration_ms', label: 'total duration (sec)', num: true, fmt: secs },
      { key: 'duration_ms_sec', label: 'duration (ms/sec)', num: true, fmt: num3 },
      { key: 'avg_duration_ms', label: 'avg duration (ms)', num: true, fmt: num3 },
      { key: 'executions', num: true },
      { key: 'executions_min', label: 'executions /min', num: true },
      { key: 'max_executions_min', label: 'max executions /min', num: true },
      { key: 'cpu_ms', label: 'total CPU (sec)', num: true, fmt: secs },
      { key: 'cpu_ms_sec', label: 'CPU (ms/sec)', num: true, fmt: num3 },
      { key: 'avg_cpu_ms', label: 'avg CPU (ms)', num: true, fmt: num3 },
      { key: 'logical_reads', label: 'logical reads', num: true },
      { key: 'avg_logical_reads', label: 'avg logical reads', num: true },
      { key: 'physical_reads', label: 'physical reads', num: true },
      { key: 'avg_physical_reads', label: 'avg physical reads', num: true },
      { key: 'logical_writes', label: 'writes', num: true },
      { key: 'avg_logical_writes', label: 'avg writes', num: true },
      // PerformanceMonitor's 'I/O and spills' (D10, 0126): total_spills, SQL Server 2016 SP2 / 2017 CU3 on
      ...(spills ? [
        { key: 'spills', label: 'Total spilled pages', num: true, fmt: (v: unknown, r: Row) => v == null ? 'not read' : Number(r.spill_reads) < Number(r.intervals) ? `${fmtNum(v)} (${fmtNum(r.spill_reads)} of ${fmtNum(r.intervals)} reads)` : fmtNum(v) },
        { key: 'avg_spills', label: 'Avg spilled pages', num: true, fmt: (v: unknown) => v == null ? '' : fmtNum(v) },
      ] as Col[] : []),
      // the Extremes group (0342), off until its box is ticked: the smallest and the largest single execution the
      // server kept for the plans that ran in the range, each since the plan was cached
      ...(extremes ? [
        { key: 'min_cpu_ms', label: 'min CPU (ms)', num: true, fmt: nr(num3) }, { key: 'max_cpu_ms', label: 'max CPU (ms)', num: true, fmt: nr(num3) },
        { key: 'min_duration_ms', label: 'min duration (ms)', num: true, fmt: nr(num3) }, { key: 'max_duration_ms', label: 'max duration (ms)', num: true, fmt: nr(num3) },
        { key: 'min_logical_reads', label: 'min logical reads', num: true, fmt: nr(fmtNum) }, { key: 'max_logical_reads', label: 'max logical reads', num: true, fmt: nr(fmtNum) },
        { key: 'min_physical_reads', label: 'min physical reads', num: true, fmt: nr(fmtNum) }, { key: 'max_physical_reads', label: 'max physical reads', num: true, fmt: nr(fmtNum) },
        { key: 'min_logical_writes', label: 'min writes', num: true, fmt: nr(fmtNum) }, { key: 'max_logical_writes', label: 'max writes', num: true, fmt: nr(fmtNum) },
        ...(spills ? [{ key: 'min_spills', label: 'min spilled pages', num: true, fmt: nr(fmtNum) }, { key: 'max_spills', label: 'max spilled pages', num: true, fmt: nr(fmtNum) }] : []),
      ] as Col[] : []),
      { key: 'last_seen', label: 'last ran before', fmt: fmtTime },
    ];
  }

  // the scalar functions and the triggers (0343, the collection mssql_funcstats), under the procedures: the page's
  // range and database, the busiest CPU first; a name opens nothing (the read-by-read view is the procedures')
  function others(d: Parts): Node[] {
    const fst = rowsOf(d.func_state)[0], fns = rowsOf(d.functions), trs = rowsOf(d.triggers);
    const out: Node[] = [];
    const most = (n: number) => n >= LIMIT ? `the ${fmtNum(LIMIT)} with the most CPU` : `${fmtNum(n)}, the most CPU first`;
    if (!fst) out.push(el('p', { class: 'meta' }, 'The mssql_funcstats collection has not run on this instance: it reads every five minutes, needs VIEW SERVER STATE, and its first read only sets the starting counters.'));
    else if (fst.status !== 'ok') out.push(el('p', { class: 'meta' }, `The mssql_funcstats collection's last run: ${String(fst.status)}${fst.note ? ' (' + String(fst.note) + ')' : ''}.`));
    const fcols = statCols(undefined, false);
    fcols.splice(4, 0, { key: 'inline_mark', label: 'inlining', fmt: v => String(v ?? ''),
      title: '"not inlineable": the definition holds a construct SQL Server cannot inline. "inlining off": it could be inlined and its INLINE option is OFF. '
        + 'Blank: it could be inlined and inlining is on, so it ran without it for the call\'s own reason (a hint, the database\'s setting or compatibility level, the form of the call). '
        + '"not read": the server is older than SQL Server 2019, the login cannot see the module, or the read failed.' });
    out.push(el('h3', {}, 'Functions (scalar, run without inlining)'),
      el('p', { class: 'meta' }, `${most(fns.length)}. sys.dm_exec_function_stats lists no table-valued function and no scalar function the server inlined: `
        + 'a function inlined into its callers is counted in their plans (the Plan cache tab). '
        + 'Inlining is read from sys.sql_modules at most hourly (SQL Server 2019 on): "not inlineable" - a construct of the definition prevents it; '
        + '"inlining off" - its INLINE option is OFF; blank - it could be inlined, and the call ran it without (a hint, the database\'s setting or level, the form of the call); '
        + '"not read" - an older server, a module the login cannot see, or a failed read. The function view has no spilled pages.'),
      grid(fns, fcols, 'No scalar function ran without inlining between the reads of this range.'));
    const tcols = statCols(undefined, true);
    tcols.splice(4, 0, { key: 'trigger_scope', label: 'scope', fmt: v => String(v ?? ''),
      title: 'A DDL or logon trigger: server or database, named from its catalog. Blank: a DML trigger, under its table\'s database.' });
    out.push(el('h3', {}, 'Triggers'),
      el('p', { class: 'meta' }, `${most(trs.length)}. sys.dm_exec_trigger_stats: a DML trigger under its database; a DDL or logon trigger with its scope (server or database), a server one under master.`),
      grid(trs, tcols, 'No trigger ran between the reads of this range.'));
    return out;
  }

  async function draw() {
    const mine = ++seq;
    drillSeq++;
    drill.replaceChildren();
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    let d: Parts;
    try {
      d = await get<Parts>('mssql/procs', { instance: ctx.instance, ...window_(ctx), db: database || undefined });
    } catch (e) {
      if (mine === seq) body.replaceChildren(errorBox(e));
      return;
    }
    if (mine !== seq) return;
    const procs = rowsOf(d.procs), dbs = rowsOf(d.databases), reads = rowsOf(d.reads)[0], st = rowsOf(d.state)[0], tot = rowsOf(d.totals)[0] ?? {};
    // the filter lists the range's databases; one remembered from another range stays listed so it can be left
    const opts = dbs.map(r => [String(r.database_id), String(r.database)] as [string, string]);
    if (database && !opts.some(o => o[0] === database)) opts.push([database, `database ${database} (nothing in this range)`]);
    const picked = opts.find(o => o[0] === database)?.[1] ?? '';
    sel.replaceChildren(el('option', { value: '' }, 'every database'), ...opts.map(([id, name]) => {
      const o = el('option', { value: id }, name);
      if (id === database) o.selected = true;
      return o;
    }));
    const out: (Node | string)[] = [];
    if (st && st.status !== 'ok') out.push(el('p', { class: 'meta' }, `The mssql_procstats collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.`));
    if (procs.length === 0) {
      out.push(el('p', { class: 'empty' }, Number(reads?.reads ?? 0) > 0
        ? `No stored procedure ran${picked ? ' in ' + picked : ''} between the ${fmtNum(reads?.reads)} reads of this range.`
        : 'No read took a difference in this range: the mssql_procstats collection runs every five minutes, needs VIEW SERVER STATE, and its first read only sets the starting counters.'));
      body.replaceChildren(...out, ...others(d));
      return;
    }
    // the tiles are the range's sums over every procedure, not only the rows the grid lists
    out.push(el('div', { class: 'tiles' },
      tile('procedures that ran', fmtNum(tot.procs)),
      tile('executions', fmtNum(tot.executions)),
      tile('duration (sec)', secs(tot.duration_ms)),
      tile('CPU (sec)', secs(tot.cpu_ms)),
      tile('logical reads', fmtNum(tot.logical_reads)),
      tile('reads in the range', fmtNum(reads?.reads ?? 0))));
    const series = rowsOf(d.series);
    out.push(el('div', { class: 'charts' },
      lineChart('Executions per second', series, [{ key: 'executions_s', label: 'executions/s' }]),
      lineChart('Duration and CPU, ms per second', series, [{ key: 'duration_ms_s', label: 'duration ms/s' }, { key: 'cpu_ms_s', label: 'CPU ms/s' }])));
    const open = (v: unknown, r: Row) => {
      const b = el('button', { type: 'button', class: 'link', title: 'This procedure read by read' }, String(v ?? ''));
      b.addEventListener('click', () => { void intervals(r); });
      return b;
    };
    const cols = statCols(open, true);
    const cut = procs.length >= LIMIT;
    const gbox = el('div', {}, grid(procs, cols)), said = el('p', { class: 'meta', role: 'status' }); let pAsked = 0;   // a newer drag's answer wins
    const win = window_(ctx);
    const pstrip = strip = rereadStrip('Procedure duration', win, series.map(x => ({ t: Date.parse(String(x.snapshot_at)), v: Number(x.duration_ms_s) || 0 })),
      n => `${num3(n)} ms/s summed`, 300e3, (from, to, words) => { const mine = ++pAsked;
        void get<Parts>('mssql/procs', { instance: ctx.instance, from: from ?? win.from, to: to ?? win.to, db: database || undefined, part: 'procs' }).then(x => { if (mine !== pAsked) return;
          said.textContent = from ? `The grid holds ${words ?? ''}, snapped to the five-minute reads (${fmtTime(from)} to ${fmtTime(to)}).` : '';
          gbox.replaceChildren(grid(rowsOf(x.procs), cols));
        }).catch(e => { if (mine === pAsked) gbox.replaceChildren(errorBox(e)); });
      }, 'Every procedure\'s duration per step. Drag across it to read the grid for that stretch; a procedure opened below draws its own on it.');
    out.push(el('h3', {}, cut ? `Procedures (the ${fmtNum(LIMIT)} with the most duration of ${fmtNum(tot.procs)})` : `Procedures (${procs.length}, the most duration first)`),
      el('p', { class: 'meta' }, 'Per second and per minute are over the seconds the range\'s reads cover '
        + `(${fmtSecs(Math.round(Number(reads?.covered_secs ?? 0)))}). A name opens that procedure read by read. `
        + 'Max executions /min is the procedure\'s busiest single read. '
        + '"object <id>": the name was not read (the procedure is gone, the read gave up on a lock, or the login may not see it). '
        + 'Spilled pages: "not read" where the server has no total_spills (before SQL Server 2016 SP2 and 2017 CU3) or the reads came before pgvigil stored it. '
        + (extremes ? 'Extremes: the smallest and the largest single execution the server kept for the plans that ran in the range, each since the plan was cached, not the range\'s own; "not read" as the spilled pages.' : '')),
      pstrip, said, gbox,
      compareSection(ctx, 'procs', { db: database || undefined }));
    body.replaceChildren(...out, ...others(d));
  }

  sel.addEventListener('change', () => {
    database = sel.value;
    try { sessionStorage.setItem(store, database); } catch { /* private window */ }
    void draw();
  });
  const exBox = el('input', { type: 'checkbox' }) as HTMLInputElement;
  exBox.checked = extremes;
  exBox.addEventListener('change', () => {
    extremes = exBox.checked;
    try { sessionStorage.setItem(`${store}.extremes`, extremes ? '1' : ''); } catch { /* private window */ }
    void draw();
  });
  sec.append(el('div', { class: 'toolbar' }, el('label', {}, 'Database ', sel), el('label', {}, exBox, ' Extremes')), body, drill);
  await draw();
  return sec;
}
