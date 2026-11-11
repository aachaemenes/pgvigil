// The Procedures tab of a SQL Server instance (task 130; DBA Dash's Object Execution): what each stored procedure
// did over the range, from the differences of sys.dm_exec_procedure_stats between two reads five minutes apart:
// executions, CPU, duration, reads and writes, as totals, per execution and per second. A database filter, the
// instance's totals over time, one row per procedure and, on a procedure's name, its own reads. Data from
// /api/mssql/procs; the route and the tab's entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { Col, el, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlProcsTab = 'mssqlprocs';

type Parts = Record<'state' | 'reads' | 'databases' | 'procs' | 'series', Table | null>;
const STORE = 'pgvigil.mssql.procs.db';
const ms = (v: unknown) => v == null ? '' : fmtNum(v);
// a total in milliseconds as seconds with three decimals (DBA Dash's 'Total Duration (sec)')
const secs = (v: unknown) => v == null ? '' : fmtNum(Math.round(Number(v)) / 1000);

export async function mssqlProcsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Procedures (${rangeLabel(ctx)})`));
  sec.append(el('p', { class: 'meta' }, 'Source: sys.dm_exec_procedure_stats, read every five minutes; a figure is what ran between two reads. '
    + 'The view counts per cached plan: a procedure compiled, run and dropped from the plan cache between two reads is in no read, '
    + 'and the first read of an instance only sets the starting counters. Stored procedures only; triggers and functions are not here.'));
  let database = (() => { try { return sessionStorage.getItem(STORE) ?? ''; } catch { return ''; } })();
  const sel = el('select', { 'aria-label': 'Database' }, el('option', { value: '' }, 'every database'));
  const body = el('div'), drill = el('div');
  let seq = 0, drillSeq = 0;

  async function intervals(r: Row) {
    const mine = ++drillSeq;
    const name = `${r.schema_name ? String(r.schema_name) + '.' : ''}${String(r.object_name)}`;
    drill.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    const d = await get<{ intervals: Table | null }>('mssql/procs', { instance: ctx.instance, ...window_(ctx), db_id: Number(r.database_id), object: String(r.object_id), part: 'intervals' });
    if (mine !== drillSeq) return;
    drill.replaceChildren(el('h3', { tabindex: '-1' }, `${String(r.database)}: ${name}, read by read`), grid(rowsOf(d.intervals), [
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
      { key: 'interval_secs', label: 'interval', num: true, fmt: v => fmtSecs(Math.round(Number(v))) },
      { key: 'executions', num: true },
      { key: 'duration_ms', label: 'duration (ms)', num: true, fmt: ms },
      { key: 'avg_duration_ms', label: 'avg duration (ms)', num: true, fmt: ms },
      { key: 'cpu_ms', label: 'CPU (ms)', num: true, fmt: ms },
      { key: 'avg_cpu_ms', label: 'avg CPU (ms)', num: true, fmt: ms },
      { key: 'logical_reads', label: 'logical reads', num: true },
      { key: 'physical_reads', label: 'physical reads', num: true },
      { key: 'logical_writes', label: 'writes', num: true },
    ], 'No read of this procedure in the range.'));
    (drill.querySelector('h3') as HTMLElement).focus();   // the new block is announced and scrolled to
  }

  async function draw() {
    const mine = ++seq;
    drillSeq++;
    drill.replaceChildren();
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    const d = await get<Parts>('mssql/procs', { instance: ctx.instance, ...window_(ctx), database: database || undefined });
    if (mine !== seq) return;
    const procs = rowsOf(d.procs), dbs = rowsOf(d.databases), reads = rowsOf(d.reads)[0], st = rowsOf(d.state)[0];
    // the filter lists the range's databases; one remembered from another range stays listed so it can be left
    const names = dbs.map(r => String(r.database));
    if (database && !names.includes(database)) names.push(database);
    sel.replaceChildren(el('option', { value: '' }, 'every database'), ...names.map(n => {
      const o = el('option', { value: n }, n);
      if (n === database) o.selected = true;
      return o;
    }));
    const out: (Node | string)[] = [];
    if (st && st.status !== 'ok') out.push(el('p', { class: 'meta' }, `The mssql_procstats collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.`));
    if (procs.length === 0) {
      out.push(el('p', { class: 'empty' }, Number(reads?.reads ?? 0) > 0
        ? `No stored procedure ran${database ? ' in ' + database : ''} between the ${fmtNum(reads?.reads)} reads of this range.`
        : 'No read took a difference in this range: the mssql_procstats collection runs every five minutes, needs VIEW SERVER STATE, and its first read only sets the starting counters.'));
      body.replaceChildren(...out);
      return;
    }
    const sum = (k: string) => procs.reduce((a, r) => a + Number(r[k] ?? 0), 0);
    out.push(el('div', { class: 'tiles' },
      tile('procedures that ran', fmtNum(procs.length)),
      tile('executions', fmtNum(sum('executions'))),
      tile('duration (sec)', secs(sum('duration_ms'))),
      tile('CPU (sec)', secs(sum('cpu_ms'))),
      tile('logical reads', fmtNum(sum('logical_reads'))),
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
    const cols: Col[] = [
      { key: 'database' },
      { key: 'schema_name', label: 'schema' },
      { key: 'object_name', label: 'name', fmt: open },
      { key: 'type_desc', label: 'type', fmt: v => String(v ?? '').replace(/_/g, ' ').toLowerCase() },
      { key: 'duration_ms', label: 'total duration (sec)', num: true, fmt: secs },
      { key: 'duration_ms_sec', label: 'duration (ms/sec)', num: true, fmt: ms },
      { key: 'avg_duration_ms', label: 'avg duration (ms)', num: true, fmt: ms },
      { key: 'executions', num: true },
      { key: 'executions_min', label: 'executions /min', num: true },
      { key: 'max_executions_min', label: 'max executions /min', num: true },
      { key: 'cpu_ms', label: 'total CPU (sec)', num: true, fmt: secs },
      { key: 'cpu_ms_sec', label: 'CPU (ms/sec)', num: true, fmt: ms },
      { key: 'avg_cpu_ms', label: 'avg CPU (ms)', num: true, fmt: ms },
      { key: 'logical_reads', label: 'logical reads', num: true },
      { key: 'avg_logical_reads', label: 'avg logical reads', num: true },
      { key: 'physical_reads', label: 'physical reads', num: true },
      { key: 'avg_physical_reads', label: 'avg physical reads', num: true },
      { key: 'logical_writes', label: 'writes', num: true },
      { key: 'avg_logical_writes', label: 'avg writes', num: true },
      { key: 'last_seen', label: 'last ran before', fmt: fmtTime },
    ];
    out.push(el('h3', {}, `Procedures (${procs.length}${procs.length >= 2000 ? ', the 2,000 with the most duration' : ''}, the most duration first)`),
      el('p', { class: 'meta' }, 'Per second and per minute are over the seconds the range\'s reads cover '
        + `(${fmtSecs(Math.round(Number(reads?.covered_secs ?? 0)))}). A name opens that procedure read by read. `
        + 'Max executions /min is the procedure\'s busiest single read. '
        + '"object <id>": the name was not read (the procedure is gone, the read gave up on a lock, or the login may not see it).'),
      grid(procs, cols));
    body.replaceChildren(...out);
  }

  sel.addEventListener('change', () => {
    database = sel.value;
    try { sessionStorage.setItem(STORE, database); } catch { /* private window */ }
    void draw();
  });
  sec.append(el('div', { class: 'toolbar' }, el('label', {}, 'Database ', sel)), body, drill);
  await draw();
  return sec;
}
