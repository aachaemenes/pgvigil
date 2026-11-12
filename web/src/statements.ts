// PostgreSQL depth on the statements page (task 155, migration 0095): two sections the Statements tab shows under its
// top statements - the depth of pg_stat_statements over the window (planning time and its share, JIT, WAL records and
// full-page images, parallel workers planned and launched, generic and custom plans, local and temp blocks, the share of
// the server's execution time) and the functions of pg_stat_user_functions (calls, total and self time, per call, the
// share of every function's time). Both read GET /api/pgdepth; the sort is picked inside the section (no route change).
import { get, Row, rowsOf, Table } from './api';
import { badge, Col, el, fmtBytes, fmtNum, grid } from './ui';
import { whatIsThis } from './sqlview';

export interface Window { from: string; to: string }

const ms = (v: unknown) => v == null ? '' : fmtNum(v) + ' ms';
const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const short = (v: unknown) => { const s = String(v ?? ''); return s.length > 120 ? s.slice(0, 120) + '...' : s; };

// depthError: what a section shows when its read fails (the route not served yet answers 404)
export function depthError(what: string, e: unknown): HTMLElement {
  return el('p', { class: 'error', role: 'alert' }, `${what} could not be read: ${e instanceof Error ? e.message : String(e)}`);
}

const depthOrders: [string, string][] = [['plan', 'planning time'], ['time', 'execution time'], ['jit', 'JIT time'], ['wal', 'WAL bytes'],
  ['fpi', 'full-page images'], ['workers', 'workers not launched']];

const depthCols: Col[] = [
  { key: 'query', wide: true, fmt: short },
  { key: 'datname', label: 'database' },
  { key: 'calls', num: true, fmt: fmtNum },
  { key: 'total_exec_ms', label: 'execution', num: true, fmt: ms },
  { key: 'server_pct', label: 'of the server', num: true, fmt: pct },
  { key: 'plans', num: true, fmt: fmtNum },
  { key: 'total_plan_ms', label: 'planning', num: true, fmt: ms },
  { key: 'mean_plan_ms', label: 'per plan', num: true, fmt: ms },
  { key: 'plan_pct', label: 'planning share', num: true, fmt: pct, cls: v => Number(v) >= 50 ? 'warn' : '' },
  { key: 'generic_plan_calls', label: 'generic plans', num: true, fmt: fmtNum },
  { key: 'custom_plan_calls', label: 'custom plans', num: true, fmt: fmtNum },
  { key: 'jit_functions', label: 'JIT functions', num: true, fmt: fmtNum },
  { key: 'jit_ms', label: 'JIT time', num: true, fmt: ms },
  { key: 'jit_pct', label: 'JIT share', num: true, fmt: pct, cls: v => Number(v) >= 20 ? 'warn' : '' },
  { key: 'wal_records', label: 'WAL records', num: true, fmt: fmtNum },
  { key: 'wal_fpi', label: 'full-page images', num: true, fmt: fmtNum },
  { key: 'fpi_pct', label: 'FPI share', num: true, fmt: pct },
  { key: 'wal_bytes', label: 'WAL', num: true, fmt: fmtBytes },
  { key: 'wal_buffers_full', label: 'WAL buffers full', num: true, fmt: fmtNum },
  { key: 'workers_to_launch', label: 'workers planned', num: true, fmt: fmtNum },
  { key: 'workers_launched', label: 'launched', num: true, fmt: fmtNum },
  { key: 'workers_missing', label: 'not launched', num: true, fmt: fmtNum, cls: v => Number(v) > 0 ? 'warn' : '' },
  { key: 'local_blks_read', label: 'local blks read', num: true, fmt: fmtNum },
  { key: 'temp_blks_written', label: 'temp blks written', num: true, fmt: fmtNum },
];

// statementDepthView: the depth of the window's statements, sorted by the picked order (planning time first).
export async function statementDepthView(instance: number, win: Window, label = ''): Promise<HTMLElement> {
  const sec = el('section', { class: 'pg-depth' }, el('h3', {}, 'Statement depth' + (label ? ` (${label})` : '') + ' ',
    whatIsThis('pg_stat_statements beyond time and calls, over the window: planning (track_planning must be on for plans and '
      + 'planning time), JIT (15+), WAL records and full-page images (13+; a high full-page-image share follows checkpoints), '
      + 'parallel workers planned and launched (18+; workers not launched means max_parallel_workers ran out), generic and custom '
      + 'plan counts (where the installed pg_stat_statements has them: not in 1.12, PostgreSQL 18\'s), local and temp blocks. '
      + 'A blank cell: the server\'s pg_stat_statements has no such column. "Of the server" is the statement\'s share of the '
      + 'execution time of every statement in the window.', 'Statement depth')));
  const pick = el('select', { 'aria-label': 'sort the statement depth by' },
    ...depthOrders.map(([k, l]) => el('option', { value: k }, 'by ' + l)));
  const body = el('div', {});
  const draw = async () => {
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    try {
      const d = await get<Record<string, Table>>('pgdepth', { instance, part: 'statements', order: pick.value, limit: 100, ...win });
      body.replaceChildren(grid(rowsOf(d.rows), depthCols,
        'No statement deltas in this window (pg_stat_statements missing, or fewer than two reads).'));
    } catch (e) { body.replaceChildren(depthError('The statement depth', e)); }
  };
  pick.addEventListener('change', () => { void draw(); });
  sec.append(el('p', { class: 'meta' }, 'Sort ', pick), body);
  await draw();
  return sec;
}

const fnOrders: [string, string][] = [['total', 'total time'], ['self', 'self time'], ['calls', 'calls'], ['mean', 'time per call']];

const fnCols: Col[] = [
  { key: 'datname', label: 'database' },
  { key: 'schema_name', label: 'schema' },
  { key: 'func_name', label: 'function', fmt: (v, r) => `${String(v ?? '')}(${String(r.args ?? '')})` },
  { key: 'calls', num: true, fmt: fmtNum },
  { key: 'total_ms', label: 'total', num: true, fmt: ms },
  { key: 'self_ms', label: 'self', num: true, fmt: ms },
  { key: 'mean_ms', label: 'per call', num: true, fmt: ms },
  { key: 'self_mean_ms', label: 'self per call', num: true, fmt: ms },
  { key: 'share_pct', label: 'of all functions', num: true, fmt: pct },
];

// functionsView: pg_stat_user_functions over the window, every database the collection read, with each database's
// track_functions (none - the server's default - leaves the view empty there).
export async function functionsView(instance: number, win: Window, label = ''): Promise<HTMLElement> {
  const sec = el('section', { class: 'pg-depth' }, el('h3', {}, 'Functions' + (label ? ` (${label})` : '') + ' ',
    whatIsThis('pg_stat_user_functions per database, read every 5 minutes by the functions collection: calls, total time (with the '
      + 'functions it calls) and self time (without them) over the window. track_functions = pl counts PL/pgSQL and other '
      + 'procedural functions, all counts SQL and C functions too; none (the default) counts nothing. An SQL function the '
      + 'planner inlines is never counted.', 'Functions')));
  const pick = el('select', { 'aria-label': 'sort the functions by' }, ...fnOrders.map(([k, l]) => el('option', { value: k }, 'by ' + l)));
  const dbLine = el('p', { class: 'meta' });
  const body = el('div', {});
  const draw = async () => {
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    try {
      const d = await get<Record<string, Table>>('pgdepth', { instance, part: 'functions', order: pick.value, limit: 100, ...win });
      const dbs = rowsOf(d.databases);
      const off = dbs.filter((r: Row) => r.track_functions === 'none');
      dbLine.replaceChildren(dbs.length === 0 ? 'No database read yet by the functions collection.'
        : `${dbs.length} database(s) read; track_functions: `, ...dbs.map((r: Row) =>
          badge(`${String(r.datname)} ${String(r.track_functions ?? '?')}`, r.track_functions === 'none' ? 'warn' : '')));
      body.replaceChildren(grid(rowsOf(d.rows), fnCols, off.length === dbs.length && dbs.length
        ? 'track_functions is none in every database read: no function statistics are kept (set it to pl or all).'
        : 'No function ran in this window (or fewer than two reads).'));
    } catch (e) { dbLine.replaceChildren(); body.replaceChildren(depthError('The function statistics', e)); }
  };
  pick.addEventListener('change', () => { void draw(); });
  sec.append(dbLine, el('p', { class: 'meta' }, 'Sort ', pick), body);
  await draw();
  return sec;
}
