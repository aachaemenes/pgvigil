// The Plan cache tab of a SQL Server instance (task 150; sp_QuickieCache's and sp_BlitzCache's reads): the cached
// statements' work over the range, from the differences of sys.dm_exec_query_stats between two reads five minutes
// apart, with a scope for the databases that have no Query Store; and what the cache holds per database (single-use
// plans, one statement compiled into many plans, how recent the plans are) with its two lists. Data from
// /api/mssql/plancache; the route and the tab's entry are the shell's.
import { get, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlPlanCacheTab = 'mssqlplancache';

type Parts = Record<'state' | 'reads' | 'databases' | 'totals' | 'top' | 'series' | 'health' | 'singles' | 'duplicates' | 'findings', Table | null>;
const LIMIT = 1000;
const num3 = (v: unknown) => v == null ? '' : Number(v).toLocaleString(undefined, { maximumFractionDigits: 3 });
const secs = (v: unknown) => v == null ? '' : num3(Math.round(Number(v)) / 1000);
const pct = (v: unknown) => v == null ? '' : `${Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 })} %`;
const level = (v: unknown, warn: number, info: number) => Number(v) > warn ? 'warn' : Number(v) > info ? 'info' : '';
// a statement's text, its first characters shown and the whole kept for the copy and the export
const text = (v: unknown) => {
  const s = String(v ?? '');
  if (!s) return el('span', { class: 'meta' }, 'not read yet');
  return el('span', { 'data-full': s, title: s }, s.length > 160 ? s.slice(0, 160) + '...' : s);
};

export async function mssqlPlanCacheView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Plan cache (${rangeLabel(ctx)})`));
  sec.append(el('p', { class: 'meta' }, 'Source: sys.dm_exec_query_stats, read every five minutes; a figure is what ran between two reads, summed per database and query hash. '
    + 'Only what stays in the cache between two reads is seen: a statement compiled, run and evicted in between is in no read, so on a cache that turns over fast these are a floor. '
    + 'The databases whose Query Store is on have a fuller history on the Query Store tab; the scope below keeps the ones without.'));
  const store = `pgvigil.mssql.plancache.${String(ctx.instance)}`;
  const saved = (() => { try { return JSON.parse(sessionStorage.getItem(store) ?? '{}') as { db?: string; noqs?: boolean }; } catch { return {}; } })();
  let database = saved.db ?? '', noqs = saved.noqs ?? false;
  const sel = el('select', { 'aria-label': 'Database' }, el('option', { value: '' }, 'every database'));
  const chk = el('input', { type: 'checkbox' }) as HTMLInputElement;
  chk.checked = noqs;
  const body = el('div');
  let seq = 0;

  async function draw() {
    const mine = ++seq;
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    let d: Parts;
    try {
      d = await get<Parts>('mssql/plancache', { instance: ctx.instance, ...window_(ctx), db: database || undefined, scope: noqs ? 'noqs' : undefined });
    } catch (e) {
      if (mine === seq) body.replaceChildren(errorBox(e));
      return;
    }
    if (mine !== seq) return;
    const dbs = rowsOf(d.databases), top = rowsOf(d.top), reads = rowsOf(d.reads)[0], tot = rowsOf(d.totals)[0] ?? {};
    // a database remembered from before that the instance no longer lists stays in the list, so it can be left
    const opts = dbs.map(r => [String(r.database_id), `${String(r.database_name)}${r.query_store_on ? ' (Query Store on)' : ''}`] as [string, string]);
    if (database && !opts.some(o => o[0] === database)) opts.push([database, `database ${database} (not listed now)`]);
    sel.replaceChildren(el('option', { value: '' }, 'every database'), ...opts.map(([id, name]) => {
      const o = el('option', { value: id }, name);
      if (id === database) o.selected = true;
      return o;
    }));
    const out: (Node | string)[] = [];
    for (const st of rowsOf(d.state)) if (st.status !== 'ok') out.push(el('p', { class: 'meta' }, `The ${String(st.collection)} collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.`));
    const findings = rowsOf(d.findings);
    if (findings.length) out.push(el('h3', {}, 'Findings'), grid(findings, [
      { key: 'severity', fmt: v => badge(String(v), v === 'warning' ? 'warn' : 'info') },
      { key: 'check_name', label: 'check' }, { key: 'object', label: 'database' }, { key: 'detail', wide: true }, { key: 'at', label: 'read', fmt: fmtTime }]));

    out.push(el('h3', {}, 'Statements over the range'));
    if (Number(reads?.reads ?? 0) === 0) {
      out.push(el('p', { class: 'empty' }, 'No read took a difference in this range: the mssql_plancache collection runs every five minutes, needs VIEW SERVER STATE, and its first read only sets the starting counters.'));
    } else {
      if (Number(reads?.cut_reads ?? 0) > 0) out.push(el('p', { class: 'meta' }, `${fmtNum(reads?.cut_reads)} of the reads were cut: the cache held more statements than the collector's lists keep (the first 500 by CPU, duration, reads, executions, grant and spills).`));
      out.push(el('div', { class: 'tiles' },
        tile('statements that ran', fmtNum(tot.statements)), tile('executions', fmtNum(tot.executions)),
        tile('CPU (sec)', secs(tot.cpu_ms)), tile('duration (sec)', secs(tot.duration_ms)),
        tile('logical reads', fmtNum(tot.logical_reads)), tile('reads in the range', fmtNum(reads?.reads))));
      const series = rowsOf(d.series);
      out.push(el('div', { class: 'charts' },
        lineChart('Executions per second', series, [{ key: 'executions_s', label: 'executions/s' }]),
        lineChart('CPU and duration, ms per second', series, [{ key: 'cpu_ms_s', label: 'CPU ms/s' }, { key: 'duration_ms_s', label: 'duration ms/s' }])));
      const cols: Col[] = [
        { key: 'database' },
        { key: 'query_store_on', label: 'Query Store', fmt: v => v == null ? 'not read' : v ? 'on' : 'off' },
        { key: 'object_name', label: 'module' },
        { key: 'query', label: 'statement', fmt: text, wide: true },
        { key: 'executions', num: true },
        { key: 'cpu_ms', label: 'CPU (sec)', num: true, fmt: secs },
        { key: 'avg_cpu_ms', label: 'avg CPU (ms)', num: true, fmt: num3 },
        { key: 'duration_ms', label: 'duration (sec)', num: true, fmt: secs },
        { key: 'avg_duration_ms', label: 'avg duration (ms)', num: true, fmt: num3 },
        { key: 'logical_reads', label: 'logical reads', num: true },
        { key: 'avg_logical_reads', label: 'avg reads', num: true },
        { key: 'physical_reads', label: 'physical reads', num: true },
        { key: 'logical_writes', label: 'writes', num: true },
        { key: 'row_count', label: 'rows', num: true },
        { key: 'spills', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : '0' },
        { key: 'max_grant_kb', label: 'max grant (KB)', num: true },
        { key: 'grant_used_pct', label: 'grant used', num: true, fmt: pct },
        { key: 'max_dop', label: 'max DOP', num: true },
        { key: 'plans', label: 'plans', num: true },
        { key: 'query_key', label: 'query hash' },
        { key: 'last_seen', label: 'last ran before', fmt: fmtTime },
      ];
      out.push(el('p', { class: 'meta' }, `${top.length >= LIMIT ? `The ${fmtNum(LIMIT)} with the most CPU.` : `${fmtNum(top.length)} statements, the most CPU first.`} `
        + `Per second over the ${fmtSecs(Math.round(Number(reads?.covered_secs ?? 0)))} the reads cover. Max grant and DOP are the largest since the plans were compiled.`),
        grid(top, cols));
    }

    const health = rowsOf(d.health);
    out.push(el('h3', {}, 'What the cache holds (hourly)'));
    if (!health.length) out.push(el('p', { class: 'empty' }, 'Not read yet: the mssql_plancache_health collection runs hourly and needs VIEW SERVER STATE.'));
    else {
      out.push(grid(health, [
        { key: 'database' },
        { key: 'plans', num: true }, { key: 'plan_mb', label: 'plans (MB)', num: true },
        { key: 'single_use', label: 'single-use plans', num: true },
        { key: 'single_use_pct', label: 'single-use share', num: true, fmt: pct, cls: v => level(v, 75, 10) },
        { key: 'single_use_mb', label: 'single-use (MB)', num: true },
        { key: 'statements', num: true },
        { key: 'compiled_24h_pct', label: 'compiled in 24 h', num: true, fmt: pct, cls: v => level(v, 75, 101) },
        { key: 'compiled_4h', label: 'in 4 h', num: true }, { key: 'compiled_1h', label: 'in 1 h', num: true },
        { key: 'oldest_compile', label: 'oldest plan', fmt: fmtTime },
        { key: 'duplicate_pct', label: 'statements with several plans', num: true, fmt: pct, cls: v => level(v, 75, 5) },
        { key: 'duplicate_hashes', label: 'hashes with several plans', num: true },
        { key: 'snapshot_at', label: 'read', fmt: fmtTime },
      ]));
      out.push(el('h4', {}, 'The largest single-use plans'), grid(rowsOf(d.singles), [
        { key: 'database' }, { key: 'plan_kind', label: 'kind' }, { key: 'size_kb', label: 'size (KB)', num: true }, { key: 'query', label: 'statement', fmt: text, wide: true }],
        'No single-use plan in the cache.'));
      out.push(el('h4', {}, 'One statement, many plans'), grid(rowsOf(d.duplicates), [
        { key: 'database' }, { key: 'plans', num: true }, { key: 'statements', num: true }, { key: 'executions', num: true },
        { key: 'query_hash', label: 'query hash' }, { key: 'query', label: 'statement', fmt: text, wide: true }],
        'No query hash has more than one cached plan.'));
    }
    body.replaceChildren(...out);
  }

  const remember = () => { try { sessionStorage.setItem(store, JSON.stringify({ db: database, noqs })); } catch { /* private window */ } };
  sel.addEventListener('change', () => { database = sel.value; remember(); void draw(); });
  chk.addEventListener('change', () => { noqs = chk.checked; remember(); void draw(); });
  sec.append(el('div', { class: 'toolbar' }, el('label', {}, 'Database ', sel), el('label', {}, chk, ' only databases without Query Store')), body);
  await draw();
  return sec;
}

