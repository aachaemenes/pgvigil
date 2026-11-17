// The Plan cache tab of a SQL Server instance (task 150; sp_QuickieCache's and sp_BlitzCache's reads): the cached
// statements' work over the range, from the differences of sys.dm_exec_query_stats between two reads five minutes
// apart, with a scope for the databases that have no Query Store; and what the cache holds per database (single-use
// plans, one statement compiled into many plans, how recent the plans are) with its two lists. Data from
// /api/mssql/plancache; the route and the tab's entry are the shell's.
//
// Beside the statements' counters (0342): four column groups, each off until its box is ticked (PerformanceMonitor's
// Top Queries groups: Times, Extremes, Memory grants, Parallelism) - the smallest and the largest single run the
// server kept for the plans that ran in the range; a Diagnostics column with sp_QuickieCache's row-count variance,
// parameter-sniffing and wasteful-grant words; and dbatools' Get-DbaQueryExecutionTime filter as one preset. The
// extremes are a part of their own (part=extremes), asked beside the first read and joined by database and query key.
import { get, post, Row, rowsOf, Table } from './api';
import { mssqlActionsState } from './mssql_actions';
import { openText } from './filedrop';
import { lineChart } from './chart';
import { queryHistory } from './mssql_queries';
import { compareSection, everywherePanel, planStatsPanel, statementSearch } from './mssql_querystore';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, offControl, tile } from './ui';
import { markNeed, needControl } from './needs';

// The tab key of the page (the router's entry carries the same key).
export const mssqlPlanCacheTab = 'mssqlplancache';

type Parts = Record<'state' | 'reads' | 'databases' | 'totals' | 'top' | 'series' | 'health' | 'singles' | 'duplicates' | 'findings', Table | null>;
const LIMIT = 1000;
// dbatools 2.9.1's Get-DbaQueryExecutionTime defaults (MinExecMs, MinExecs, MaxResultsPerDb), on the range's figures
const SLOW = { min_avg_cpu_ms: 500, min_executions: 100, per_db: 100 };
const GROUPS: [string, string][] = [['times', 'Times'], ['extremes', 'Extremes'], ['grants', 'Memory grants'], ['parallelism', 'Parallelism']];
// what part=extremes adds to a statement's row
const EXT_KEYS = ['plan_generation', 'clr_ms', 'clr_reads', 'ext_intervals', 'peak_cpu_ms_s', 'min_cpu_ms', 'max_cpu_ms', 'min_duration_ms', 'max_duration_ms',
  'min_physical_reads', 'max_physical_reads', 'min_rows', 'max_rows', 'min_spills', 'max_spills', 'min_grant_kb', 'min_ideal_grant_kb', 'max_ideal_grant_kb',
  'min_dop', 'min_reserved_threads', 'max_reserved_threads', 'min_used_threads', 'max_used_threads', 'judged_at', 'life_executions', 'diagnostics'];
const num3 = (v: unknown) => v == null ? '' : Number(v).toLocaleString(undefined, { maximumFractionDigits: 3 });
const secs = (v: unknown) => v == null ? '' : num3(Math.round(Number(v)) / 1000);
const pct = (v: unknown) => v == null ? '' : `${Number(v).toLocaleString(undefined, { maximumFractionDigits: 1 })} %`;
// over warn a warning; over info a note (N/A, as every info level); under it judged and fine (OK)
const level = (v: unknown, warn: number, info: number) => v == null || v === '' ? '' : Number(v) > warn ? 'warn' : Number(v) > info ? 'status none' : 'status ok';
// a figure of the extremes part: blank on a row the part had nothing for, "not read" where the stored figure is NULL
const ext = (f: (v: unknown) => string) => (v: unknown, r: Row) => r.has_extremes === false ? '' : v == null ? 'not read' : f(v);
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
  const saved = (() => { try { return JSON.parse(sessionStorage.getItem(store) ?? '{}') as { db?: string; noqs?: boolean; groups?: string[]; slow?: boolean; diag?: boolean }; } catch { return {}; } })();
  let database = saved.db ?? '', noqs = saved.noqs ?? false, slow = saved.slow ?? false, onlyDiag = saved.diag ?? false;
  const groupsOn = new Set<string>((saved.groups ?? []).filter(g => GROUPS.some(([k]) => k === g)));
  let last: { d: Parts; x: Row[]; xerr: unknown } | null = null;
  const sel = el('select', { 'aria-label': 'Database' }, el('option', { value: '' }, 'every database'));
  const chk = el('input', { type: 'checkbox' }) as HTMLInputElement;
  chk.checked = noqs;
  const body = el('div');
  let seq = 0;

  async function draw() {
    const mine = ++seq;
    last = null;   // a box ticked while this read runs, or after it fails, paints nothing of an older read
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    let d: Parts;
    const q = { instance: ctx.instance, ...window_(ctx), db: database || undefined, scope: noqs ? 'noqs' : undefined, ...(slow ? SLOW : {}) };
    // the extremes: a part of their own, asked beside the first read; without them the statements stand as they are
    const ext = get<{ extremes: Table | null }>('mssql/plancache', { ...q, part: 'extremes' })
      .then(r => ({ x: rowsOf(r.extremes), xerr: null as unknown }), (e: unknown) => ({ x: [] as Row[], xerr: e }));
    try {
      d = await get<Parts>('mssql/plancache', q);
    } catch (e) {
      if (mine === seq) body.replaceChildren(errorBox(e));
      return;
    }
    const x = await ext;
    if (mine !== seq) return;
    last = { d, ...x };
    paint();
  }

  // paint draws the last read: a column group's box redraws without reading again
  function paint() {
    if (!last) return;
    const { d, x, xerr } = last;
    const dbs = rowsOf(d.databases), top = rowsOf(d.top), reads = rowsOf(d.reads)[0], tot = rowsOf(d.totals)[0] ?? {};
    const byKey = new Map(x.map(r => [`${String(r.database_id)}|${String(r.query_key)}`, r]));
    for (const r of top) {
      const e = byKey.get(`${String(r.database_id)}|${String(r.query_key)}`);
      r.has_extremes = e != null;
      if (e) { e.ext_intervals = e.intervals; for (const k of EXT_KEYS) r[k] = e[k]; }
    }
    const shown = onlyDiag ? top.filter(r => r.diagnostics) : top;
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
      { key: 'severity', fmt: v => badge(String(v), v === 'warning' ? 'warn' : 'none') },
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
        // PerformanceMonitor's History per row (D10): the query's average CPU and duration per execution over the range
        { key: 'history', label: 'history', fmt: (_, r) => {
          const b = el('button', { type: 'button', class: 'link', 'aria-label': `History of ${String(r.query_key)}` }, 'History');
          b.addEventListener('click', () => {
            hist.replaceChildren(el('p', { class: 'meta', role: 'status' }, 'Reading the history ...'));
            queryHistory(ctx, r.database_id, r.query_key, `${String(r.database)} ${String(r.query_key)}`)
              .then(h => { hist.replaceChildren(h); hist.scrollIntoView({ block: 'nearest' }); }).catch(e => hist.replaceChildren(errorBox(e)));
          });
          return b;
        } },
        // the cache entries of the row (task 406): each plan handle with its own .sqlplan, read on demand
        { key: 'cached_plans', label: 'cached plans', fmt: (_, r) => {
          const b = el('button', { type: 'button', class: 'link', 'aria-label': `Cached plans of ${String(r.query_key)}` }, 'Cached plans');
          b.addEventListener('click', () => { void cachedPlans(ctx, r, hist); });
          return b;
        } },
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
        { key: 'spills', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : '0', cls: v => Number(v) > 0 ? '' : 'status ok' },
        { key: 'max_grant_kb', label: 'max grant (KB)', num: true },
        { key: 'grant_used_pct', label: 'grant used', num: true, fmt: pct },
        { key: 'max_dop', label: 'max DOP', num: true },
        { key: 'diagnostics', label: 'diagnostics', wide: true, fmt: v => v ? String(v) : '',
          title: 'sp_QuickieCache\'s rules on the statement\'s newest read of the range, its figures since the plans were compiled: row count variance (the largest run returned 100 times the smallest or more), parameter sniffing (over 3 executions; a run under 0.70 or over 1.30 of the average CPU, else of the average physical reads over 1,000), wasteful grant (over 1 MB granted, under 10 % used). It counts the plans that ran in that read; sp_QuickieCache counts every cached plan of the hash.' },
        ...(groupsOn.has('times') ? [
          { key: 'plan_generation', label: 'plan generation', num: true, fmt: ext(fmtNum), title: 'plan_generation_num: how often the plan was recompiled, the largest of the plans that ran' },
          { key: 'clr_ms', label: 'CLR time (ms)', num: true, fmt: (v: unknown, r: Row) => r.has_extremes === false ? '' : v == null ? 'not read'
            : Number(r.clr_reads) < Number(r.ext_intervals) ? `${num3(v)} (${fmtNum(r.clr_reads)} of ${fmtNum(r.ext_intervals)} reads)` : num3(v),
            title: 'total_clr_time over the range\'s reads that had the figure: time inside CLR code (a CLR module, FORMAT(), a hierarchyid or spatial method)' },
          { key: 'peak_cpu_ms_s', label: 'peak CPU (ms/s)', num: true, fmt: ext(num3), title: 'The statement\'s busiest single read of the range: its CPU over that read\'s own seconds' },
        ] as Col[] : []),
        ...(groupsOn.has('extremes') ? [
          { key: 'min_cpu_ms', label: 'min CPU (ms)', num: true, fmt: ext(num3) }, { key: 'max_cpu_ms', label: 'max CPU (ms)', num: true, fmt: ext(num3) },
          { key: 'min_duration_ms', label: 'min duration (ms)', num: true, fmt: ext(num3) }, { key: 'max_duration_ms', label: 'max duration (ms)', num: true, fmt: ext(num3) },
          { key: 'min_physical_reads', label: 'min physical reads', num: true, fmt: ext(fmtNum) }, { key: 'max_physical_reads', label: 'max physical reads', num: true, fmt: ext(fmtNum) },
          { key: 'min_rows', label: 'min rows', num: true, fmt: ext(fmtNum) }, { key: 'max_rows', label: 'max rows', num: true, fmt: ext(fmtNum) },
          { key: 'min_spills', label: 'min spilled pages', num: true, fmt: ext(fmtNum) }, { key: 'max_spills', label: 'max spilled pages', num: true, fmt: ext(fmtNum) },
        ] as Col[] : []),
        ...(groupsOn.has('grants') ? [
          { key: 'min_grant_kb', label: 'min grant (KB)', num: true, fmt: ext(fmtNum) },
          { key: 'max_used_grant_kb', label: 'max used grant (KB)', num: true, fmt: (v: unknown) => v == null ? '' : fmtNum(v) },
          { key: 'min_ideal_grant_kb', label: 'min ideal grant (KB)', num: true, fmt: ext(fmtNum) }, { key: 'max_ideal_grant_kb', label: 'max ideal grant (KB)', num: true, fmt: ext(fmtNum) },
        ] as Col[] : []),
        ...(groupsOn.has('parallelism') ? [
          { key: 'min_dop', label: 'min DOP', num: true, fmt: ext(fmtNum) },
          { key: 'min_reserved_threads', label: 'min reserved threads', num: true, fmt: ext(fmtNum) }, { key: 'max_reserved_threads', label: 'max reserved threads', num: true, fmt: ext(fmtNum) },
          { key: 'min_used_threads', label: 'min used threads', num: true, fmt: ext(fmtNum) }, { key: 'max_used_threads', label: 'max used threads', num: true, fmt: ext(fmtNum) },
        ] as Col[] : []),
        { key: 'plans', label: 'plans', num: true },
        { key: 'query_key', label: 'query hash' },
        { key: 'every', label: 'every instance', fmt: (_, r) => /^0x[0-9A-F]{1,16}$/i.test(String(r.query_key ?? ''))
          ? (() => { const b = el('button', { type: 'button', class: 'link', 'aria-label': `On every instance: ${String(r.query_key)}` }, 'On every instance');
              b.addEventListener('click', () => { hist.replaceChildren(everywherePanel(ctx, String(r.query_key))); }); return b; })() : '' },
        { key: 'last_seen', label: 'last ran before', fmt: fmtTime },
        // PerformanceMonitor's 'Hashes and handles' (D10, 0126): the statements cached at the last read
        { key: 'plan_hash', label: 'plan hash (cached now)' },
        { key: 'sql_handle', label: 'SQL handle (cached now)' },
        { key: 'plan_handle', label: 'plan handle (cached now)' },
      ];
      const hist = el('div', { class: 'pc-history' });
      const at = top.find(r => r.handles_at != null)?.handles_at;
      const matched = Number(top[0]?.matched ?? top.length);
      out.push(el('p', { class: 'meta' }, `${slow ? `Slow and frequent: an average CPU of ${fmtNum(SLOW.min_avg_cpu_ms)} ms or more over ${fmtNum(SLOW.min_executions)} executions or more in the range, of each database the first ${fmtNum(SLOW.per_db)} by average CPU (dbatools' Get-DbaQueryExecutionTime defaults; it reads the counts since compile, this the range). `
          + (matched > top.length ? `${fmtNum(matched)} statements match: the ${fmtNum(top.length)} with the most CPU. ` : `${fmtNum(top.length)} statements match, the most CPU first. `)
        : top.length >= LIMIT ? `The ${fmtNum(LIMIT)} with the most CPU. ` : `${fmtNum(top.length)} statements, the most CPU first. `}`
        + (onlyDiag ? `${fmtNum(shown.length)} of them carry a diagnostic. ` : '')
        + `Per second over the ${fmtSecs(Math.round(Number(reads?.covered_secs ?? 0)))} the reads cover. Max grant and DOP are the largest since the plans were compiled. `
        + 'The column groups hold the smallest and the largest single run the server kept for the plans that ran in the range, each since its compile, not the range\'s own; "not read": the server has no such column, or the reads came before pgvigil stored it; blank: no extremes for this statement in the range (its reads came before pgvigil stored them, or, in a range that reaches back before the upgrade, it ranks past the extremes\' first 1,000). '
        + `The hashes and handles are the query's statements in the cache at the last read${at ? ' (' + fmtTime(at) + ')' : ''}, one of each (PerformanceMonitor's): none for a query no longer cached.`),
        xerr ? el('div', {}, el('p', { class: 'meta' }, 'The extremes and the diagnostics were not read:'), errorBox(xerr)) : '',
        grid(shown, cols), hist,
        compareSection(ctx, 'plancache', { db: database || undefined, scope: noqs ? 'noqs' : undefined }));
    }

    out.push(runningPlansSection(ctx), statementSearch(ctx));

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

  const remember = () => { try { sessionStorage.setItem(store, JSON.stringify({ db: database, noqs, groups: [...groupsOn], slow, diag: onlyDiag })); } catch { /* private window */ } };
  sel.addEventListener('change', () => { database = sel.value; remember(); void draw(); });
  chk.addEventListener('change', () => { noqs = chk.checked; remember(); void draw(); });
  const box = (on: boolean, words: string, change: (on: boolean) => void) => {
    const c = el('input', { type: 'checkbox' }) as HTMLInputElement;
    c.checked = on;
    c.addEventListener('change', () => { change(c.checked); remember(); });
    return el('label', {}, c, ` ${words}`);
  };
  sec.append(el('div', { class: 'toolbar' }, el('label', {}, 'Database ', sel), el('label', {}, chk, ' only databases without Query Store')),
    el('div', { class: 'toolbar', role: 'group', 'aria-label': 'Statement columns and filters' }, el('span', { class: 'meta' }, 'Columns:'),
      ...GROUPS.map(([k, words]) => box(groupsOn.has(k), words, on => { if (on) groupsOn.add(k); else groupsOn.delete(k); paint(); })),
      box(slow, 'Slow and frequent', on => { slow = on; void draw(); }),
      box(onlyDiag, 'with a diagnostic', on => { onlyDiag = on; paint(); })),
    body);
  await draw();
  return sec;
}


// ---- the cache entries of one row and their plans, read on demand (task 406) -------------------------------------

type PlanReply = { state: string; words: string; plan_hash?: string; objtype?: string; database?: string; object?: string; bytes?: number; file?: string; plan?: string };

// planWords: what a read by handle said, as a line of the panel.
function planWords(p: PlanReply): string {
  const what = [p.objtype, p.object || p.database].filter(Boolean).join(' ');
  return `${p.words}${what ? ' (' + what + ')' : ''}${p.bytes ? `, ${fmtNum(Math.round(p.bytes / 1024))} KB` : ''}.`;
}

// openPlan draws a plan in the viewer with the reply's own words at its top: where it came from, and on the demo that it
// is demo data (the status line under the grid sits behind the dialog)
function openPlan(p: PlanReply, back: HTMLElement) {
  if (!p.plan || !p.file) return;
  const dlg = openText(p.file, p.plan, back, 'sqlplan');
  dlg.querySelector('.fd-body')?.prepend(el('p', { class: 'meta plan-words' }, planWords(p)));
}

// readPlan reads one entry's plan on demand: the statement at its offsets, or the whole batch.
async function readPlan(ctx: Ctx, e: Row, batch: boolean): Promise<PlanReply> {
  return get<PlanReply>('mssql/plancache/plan', {
    instance: ctx.instance, handle: String(e.plan_handle),
    start: batch ? 0 : Number(e.stmt_start), end: batch ? -1 : Number(e.stmt_end),
    hash: batch || e.plan_hash == null ? undefined : String(e.plan_hash),
  });
}

function saveFile(name: string, text: string) {
  const url = URL.createObjectURL(new Blob([text], { type: 'application/xml;charset=utf-8' }));
  const a = el('a', { href: url, download: name }) as HTMLAnchorElement;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

async function cachedPlans(ctx: Ctx, row: Row, box: HTMLElement) {
  box.replaceChildren(el('p', { class: 'meta', role: 'status' }, 'Reading the cache entries ...'));
  let d: { entries: Table | null; fetch_off: string; policy: string };
  try {
    d = await get('mssql/plancache/entries', { instance: ctx.instance, db: Number(row.database_id), key: String(row.query_key) });
  } catch (e) {
    box.replaceChildren(errorBox(e));
    return;
  }
  const entries = rowsOf(d.entries);
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  // the reason the plans are not read here, said once and named by every button it holds off
  const fetchOffNote = el('p', { class: 'meta' }, d.fetch_off || '');
  // the actions door's plan_evict (task 406): on, or off with its reason said once above the grid
  const st = await mssqlActionsState(ctx.instance);
  const evictOff = st.actions.plan_evict?.enabled ? '' : st.actions.plan_evict?.reason || 'actions are off for this instance';
  const evictNote = el('p', { class: 'meta' }, evictOff ? `Evict is off for this instance: ${evictOff}` : '');
  const evictBtn = (e: Row) => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `Evict the plan ${String(e.plan_handle)}` }, 'Evict') as HTMLButtonElement;
    if (evictOff) {
      b.style.opacity = '.55';
      b.style.cursor = 'not-allowed';
      // the button stays, drawn off and named by the note (B3 offControl); offControl returns the note, not the button
      offControl(b, evictOff, evictNote);
      return b;
    }
    b.addEventListener('click', () => { void evictDialog(ctx, String(e.plan_handle), b, () => { void cachedPlans(ctx, row, box); }); });
    return needControl(b, 'mssql/actions/run');   // the role (B24f): a plan's eviction needs operator
  };
  const act = (e: Row, label: string, batch: boolean, open: boolean) => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `${label}: ${String(e.plan_handle)} at ${String(e.stmt_start)}` }, label) as HTMLButtonElement;
    if (d.fetch_off) { offControl(b, d.fetch_off, fetchOffNote); return b; }
    b.addEventListener('click', async () => {
      status.textContent = 'Reading the plan on demand ...';
      try {
        const p = await readPlan(ctx, e, batch);
        status.textContent = planWords(p);
        if (p.plan && p.file) {
          if (open) openPlan(p, b);
          else saveFile(p.file, p.plan);
        }
      } catch (err) {
        status.textContent = err instanceof Error ? err.message : String(err);
      }
    });
    return b;
  };
  box.replaceChildren(
    el('h4', { tabindex: '-1' }, `Cached plans of ${String(row.database)} ${String(row.query_key)}`),
    el('p', { class: 'meta' }, 'The statement\'s entries in the plan cache at the last read (each a plan handle and the statement\'s place in its batch). '
      + 'A plan is read from the server when asked, through the read login: the statement\'s plan, or the plan of its whole batch or module. '
      + 'A plan hash that differs from the one read with the sample says the statement was compiled again since.'),
    d.fetch_off ? fetchOffNote : '',
    grid(entries, [
      { key: 'plan_handle', label: 'plan handle' }, { key: 'stmt_start', label: 'start', num: true }, { key: 'stmt_end', label: 'end', num: true },
      { key: 'plan_hash', label: 'plan hash' }, { key: 'creation_time', label: 'compiled (server clock)' },
      { key: 'execution_count', label: 'executions', num: true }, { key: 'cpu_ms', label: 'CPU (ms)', num: true, fmt: num3 },
      { key: 'download', label: 'statement plan', fmt: (_, e) => el('span', {}, act(e, 'Download .sqlplan', false, false), ' ', act(e, 'Open', false, true)) },
      { key: 'batch', label: 'batch plan', fmt: (_, e) => el('span', {}, act(e, 'Download batch', true, false), ' ', act(e, 'Open batch', true, true)) },
      { key: 'evict', label: 'remove from the cache', fmt: (_, e) => evictBtn(e) },
    ], 'The last plan cache read held no entry for this statement: it left the cache.'),
    evictOff ? evictNote : '', status);
  (box.firstElementChild as HTMLElement).focus();
}

// ---- the plans of running queries (task 406, DBA Dash 4.25.0's running query plans and live plans) ----------------

const RUNNING_ON_WORDS = 'Off for this instance: the collections mssql_running_plans and mssql_live_plans are off by default (an instance added on '
  + 'Admin > Instances has mssql_running_plans on). To switch them on for an instance of the configuration file, add under that instance '
  + '"schedules:" with the line "mssql_running_plans: 1m", and "mssql_live_plans: 1m" for live plans (SQL Server 2016 SP1, 2017 CU26, '
  + '2019 CU12 and later, Managed Instance, Azure SQL Database), then restart the collector. Each reads the running requests every minute; '
  + 'a plan is kept when its requests used 1 second of CPU, 50 MB of granted memory, ran 10 seconds, or two ran it at once (DBA Dash\'s thresholds).';

function runningPlansSection(ctx: Ctx): HTMLElement {
  const box = el('div', { class: 'pc-running' }, el('h3', {}, 'Plans of running queries'), el('p', { class: 'meta', role: 'status' }, 'Reading ...'));
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const statsBox = el('div', { class: 'pc-stats' });
  const fetchPlan = async (b: HTMLElement, q: Record<string, string | number | undefined>, open: boolean) => {
    status.textContent = 'Reading the kept plan ...';
    try {
      const p = await get<PlanReply>('mssql/runningplans/plan', { instance: ctx.instance, ...q });
      status.textContent = `${p.words}.`;
      if (p.plan && p.file) { if (open) openPlan(p, b); else saveFile(p.file, p.plan); }
    } catch (e) {
      status.textContent = e instanceof Error ? e.message : String(e);
    }
  };
  const btn = (label: string, aria: string, go: (b: HTMLElement) => void) => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': aria }, label);
    b.addEventListener('click', () => go(b));
    return b;
  };
  (async () => {
    let d: Record<'plans' | 'state' | 'live_read', Table | null>;
    try {
      d = await get('mssql/runningplans', { instance: ctx.instance, ...window_(ctx) });
    } catch (e) {
      box.replaceChildren(el('h3', {}, 'Plans of running queries'), errorBox(e));
      return;
    }
    const state = rowsOf(d.state), plans = rowsOf(d.plans), live = rowsOf(d.live_read)[0];
    const kids: (Node | string)[] = [el('h3', {}, 'Plans of running queries')];
    if (!state.length) kids.push(el('p', { class: 'meta' }, RUNNING_ON_WORDS));
    for (const st of state) if (st.status !== 'ok') kids.push(el('p', { class: 'meta' }, `The ${String(st.collection)} collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.`));
    if (state.length && !state.some(st => st.collection === 'mssql_live_plans')) kids.push(el('p', { class: 'meta' }, 'Live plans are off for this instance (mssql_live_plans: 1m under its schedules: switches them on where the build allows).'));
    if (live?.note) kids.push(el('p', { class: 'meta' }, `Live plans: ${String(live.note)}.`));
    if (state.length) {
      const key = (r: Row) => ({ qh: String(r.query_hash), ph: String(r.plan_hash), start: Number(r.stmt_start), end: Number(r.stmt_end) });
      kids.push(el('p', { class: 'meta' }, 'Each plan a running query used past DBA Dash\'s thresholds, read while it ran (the statement\'s plan by its handle). '
        + 'The figures are the largest one read saw. A live plan holds the operator counters of a long running request (60 seconds of CPU, or 5 minutes running while not blocked).'),
      grid(plans, [
        { key: 'database' }, { key: 'object_name', label: 'module' }, { key: 'query', label: 'statement', fmt: text, wide: true },
        { key: 'reasons', label: 'kept for', fmt: v => String(v ?? '').split(',').filter(Boolean).map(x => ({ cpu: 'CPU', grant: 'memory grant', count: 'requests', duration: 'running time' } as Record<string, string>)[x] ?? x).join(', ') },
        { key: 'max_requests', label: 'requests', num: true }, { key: 'max_cpu_ms', label: 'CPU (ms)', num: true },
        { key: 'max_grant_kb', label: 'grant (KB)', num: true }, { key: 'max_longest_ms', label: 'running (ms)', num: true },
        { key: 'first_seen', label: 'first seen', fmt: fmtTime }, { key: 'last_seen', label: 'last seen', fmt: fmtTime }, { key: 'reads', num: true },
        { key: 'plan', label: 'plan', fmt: (_, r) => r.has_plan
          ? el('span', {}, btn('Download .sqlplan', `Download .sqlplan: the plan of ${String(r.query_hash)}`, b => { void fetchPlan(b, key(r), false); }), ' ',
            btn('Open', `Open the plan of ${String(r.query_hash)}`, b => { void fetchPlan(b, key(r), true); }))
          : el('span', { class: 'meta' }, r.plan_state === 'policy' ? 'not kept: query_text is not "full"' : r.plan_state ? String(r.plan_state) + (r.plan_note ? ': ' + String(r.plan_note) : '') : 'not read yet') },
        { key: 'live', label: 'live plan', fmt: (_, r) => r.live_newest != null
          ? btn(`Open live (${fmtNum(r.live_captures)})`, `Open live (${fmtNum(r.live_captures)}): the newest live plan of ${String(r.query_hash)}`, b => { void fetchPlan(b, { ...key(r), live: Number(r.live_newest) }, true); })
          : el('span', { class: 'meta' }, Number(r.live_captures) > 0 ? 'not kept: query_text is not "full"' : 'none') },
        { key: 'stats_used', label: 'statistics', fmt: (_, r) => r.has_plan
          ? btn('Statistics used', `Statistics used by the plan of ${String(r.query_hash)}`, () => { statsBox.replaceChildren(planStatsPanel(ctx, { source: 'running', ...key(r) }, `the plan of ${String(r.query_hash)}`)); })
          : '' },
        { key: 'query_hash', label: 'query hash' }, { key: 'plan_hash', label: 'plan hash' },
      ], 'No running query met the thresholds in this range.'), status, statsBox);
    }
    box.replaceChildren(...kids);
  })();
  return box;
}

// ---- evict one plan through the actions door (task 406, Opserver's remove-plan) -------------------------------------

type EvictPreview = { ok: boolean; reason?: string; statement: string; what?: string; note?: string; confirm?: string;
  target: { plan_handle?: string; objtype?: string; plan_created?: string; plan_database?: string; plan_object?: string; plan_statements?: number;
    plan_uses?: number; plan_size_kb?: number; plan_batch?: string; plan_route?: string } };

async function evictDialog(ctx: Ctx, handle: string, back: HTMLElement, after: () => void) {
  const close = el('button', { type: 'button' }, 'Cancel');
  const body = el('div', {}, el('p', { class: 'meta', role: 'status' }, 'Reading the plan through the read login ...'));
  const dlg = el('dialog', { class: 'act-dialog', 'aria-label': 'Evict one plan from the plan cache', style: 'max-width:min(96vw,48rem)' },
    el('h3', {}, 'Evict one plan from the plan cache'), body, el('div', { style: 'margin-top:.6rem' }, close)) as HTMLDialogElement;
  close.addEventListener('click', () => dlg.close());
  dlg.addEventListener('close', () => { dlg.remove(); if (back.isConnected) back.focus(); });
  document.body.append(dlg);
  dlg.showModal();
  let pv: EvictPreview;
  try {
    pv = await post<EvictPreview>('mssql/actions/preview', { instance_id: ctx.instance, action: 'plan_evict', plan_handle: handle });
  } catch (e) {
    body.replaceChildren(errorBox(e));
    return;
  }
  const t = pv.target ?? {};
  const facts: [string, string][] = [
    ['removes', `the plan of ${pv.what ?? 'this batch'}: ${fmtNum(t.plan_statements ?? 0)} statement(s) compile again at their next run`],
    ['kind (objtype)', t.objtype ?? ''], ['compiled (server clock)', t.plan_created ?? ''], ['uses', fmtNum(t.plan_uses ?? 0)],
    ['size', `${fmtNum(t.plan_size_kb ?? 0)} KB`], ['route', t.plan_route === 'signed procedure' ? 'the signed procedure master.dbo.pgvigil_evict_plan (the actions login may EXECUTE it)'
      : t.plan_route === 'direct' ? 'DBCC FREEPROCCACHE itself (the actions login may not EXECUTE the signed procedure; DBCC needs its ALTER SERVER STATE)'
      : 'chosen when the evict runs, by the actions login\'s right on the signed procedure (it could not be asked now)'],
    ['plan handle', t.plan_handle ?? handle], ['statement', pv.statement],
  ];
  const kids: (Node | string)[] = [el('dl', { class: 'props' }, ...facts.flatMap(([k, v]) => [el('dt', {}, k), el('dd', {}, v)]))];
  if (t.plan_batch) kids.push(el('pre', { class: 'sql', tabindex: '0' }, t.plan_batch));
  if (pv.note) kids.push(el('p', { class: 'meta' }, `${pv.note}.`));
  if (!pv.ok) {
    kids.push(el('p', { class: 'error', role: 'alert' }, `Nothing to confirm: ${pv.reason ?? 'refused'}.`));
    body.replaceChildren(...kids);
    return;
  }
  // the plan's code (the server's, from the handle): typed beside the plan's own words and its handle
  const code = pv.confirm ?? '';
  const words = t.plan_object ? `${t.plan_object}${t.plan_database ? ` in ${t.plan_database}` : ''}`
    : t.plan_batch ? `the batch '${t.plan_batch.replace(/\s+/g, ' ').trim().slice(0, 60)}'` : (pv.what ?? 'this batch');
  const reason = el('textarea', { rows: '2', cols: '60', minlength: '5', maxlength: '500', 'aria-label': 'Reason (kept in the actions log)' }) as HTMLTextAreaElement;
  const confirm = el('input', { type: 'text', size: '10', autocomplete: 'off', 'aria-label': `Type ${code} to evict the plan of ${words} (handle ${t.plan_handle ?? handle})` }) as HTMLInputElement;
  const run = markNeed(el('button', { type: 'button' }, 'Evict the plan'), 'mssql/actions/run');
  const res = el('p', { role: 'status', 'aria-live': 'polite' });
  run.addEventListener('click', async () => {
    res.textContent = 'Sending ...';
    try {
      const r = await post<{ outcome: string; detail: string }>('mssql/actions/run', { instance_id: ctx.instance, action: 'plan_evict', plan_handle: t.plan_handle ?? handle,
        objtype: t.objtype ?? '', plan_created: t.plan_created ?? '', job_name: pv.what ?? '', reason: reason.value, confirm: confirm.value });
      res.textContent = `${r.outcome}: ${r.detail}`;
      after();
    } catch (e) {
      res.textContent = e instanceof Error ? e.message : String(e);
    }
  });
  kids.push(el('label', {}, 'Reason (kept in the actions log) ', reason),
    el('label', {}, `Type ${code} to evict the plan of ${words} (handle ${t.plan_handle ?? handle}) `, confirm), el('div', {}, run), res);
  body.replaceChildren(...kids);
  confirm.focus();
}

// ---- the plan of a slow or long-wait event (SQLWATCH COL#27) --------------------------------------------------------

// planSourcesCol: a 'plan' column for a grid whose rows carry database_name, query_hash and query_plan_hash (the Slow
// queries events, the running requests): its Plan button lists the plans pgvigil holds or can read for those hashes
// (a Query Store plan, a running query's kept plan, the plan cache's entries read on demand) in box, each with its
// .sqlplan and Open. The pages place box under their grid.
export function planSourcesCol(ctx: Ctx, box: HTMLElement): Col {
  return {
    key: '_plan', label: 'plan', fmt: (_, r) => {
      const qh = String(r.query_hash ?? ''), ph = String(r.query_plan_hash ?? ''), db = String(r.database_name ?? '');
      if (!/^0x[0-9A-F]{1,16}$/i.test(qh) || !/^0x[0-9A-F]{1,16}$/i.test(ph) || /^0x0+$/i.test(ph) || !db) return el('span', { class: 'meta' }, 'no plan hash');
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `Plans of query hash ${qh}, plan hash ${ph}` }, 'Plan');
      b.addEventListener('click', () => { void planSources(ctx, db, qh, ph, box); });
      return b;
    },
  };
}

async function planSources(ctx: Ctx, db: string, qh: string, ph: string, box: HTMLElement) {
  const title = `Plans of query hash ${qh}, plan hash ${ph} in ${db}`;
  box.replaceChildren(el('h4', { tabindex: '-1' }, title), el('p', { class: 'meta', role: 'status' }, 'Reading ...'));
  let d: { sources: Table | null; fetch_off?: string; running_off?: string };
  try {
    d = await get('mssql/plansources', { instance: ctx.instance, db, qh, ph });
  } catch (e) {
    box.replaceChildren(el('h4', {}, title), errorBox(e));
    return;
  }
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const show = async (b: HTMLElement, r: Row, open: boolean) => {
    status.textContent = 'Reading the plan ...';
    try {
      let p: PlanReply;
      if (r.source === 'Query Store') {
        const res = await fetch(`/api/mssql/querystore/plan.sqlplan?${new URLSearchParams({ instance: String(ctx.instance), db, plan: String(r.plan_id) })}`, { credentials: 'same-origin' });
        if (!res.ok) throw new Error(`the Query Store plan: ${res.status} ${res.statusText}`);
        p = { state: 'ok', words: 'the plan the Query Store keeps', plan: await res.text(), file: `plan-${db}-qs-${String(r.plan_id)}.sqlplan` };
      } else if (r.source === 'running') {
        p = await get<PlanReply>('mssql/runningplans/plan', { instance: ctx.instance, qh, ph, start: Number(r.stmt_start), end: Number(r.stmt_end) });
      } else {
        p = await get<PlanReply>('mssql/plancache/plan', { instance: ctx.instance, handle: String(r.plan_handle), start: Number(r.stmt_start), end: Number(r.stmt_end), hash: ph });
      }
      status.textContent = planWords(p);
      if (p.plan && p.file) { if (open) openPlan(p, b); else saveFile(p.file, p.plan); }
    } catch (e) {
      status.textContent = e instanceof Error ? e.message : String(e);
    }
  };
  // a source the server cannot read here is off with its words (the plan cache's: the policy, the read login, the audit
  // door; a running plan's: the policy)
  const offNote = el('p', { class: 'meta' }, [d.fetch_off ? `Plan cache: ${d.fetch_off}` : '', d.running_off ? `Running: ${d.running_off}.` : ''].filter(Boolean).join(' '));
  const btn = (label: string, r: Row, open: boolean) => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `${label}: the ${String(r.source)} plan` }, label) as HTMLButtonElement;
    const off = r.source === 'plan cache' ? d.fetch_off : r.source === 'running' ? d.running_off : '';
    if (off) { offControl(b, off, offNote); return b; }
    b.addEventListener('click', () => { void show(b, r, open); });
    return b;
  };
  box.replaceChildren(el('h4', { tabindex: '-1' }, title),
    el('p', { class: 'meta' }, 'The plans pgvigil holds or can read for this statement and plan hash: the Query Store\'s, the one kept while it ran, and the plan cache\'s entries (read from the server when asked, under the query_text policy "full").'),
    grid(rowsOf(d.sources), [
      { key: 'source' }, { key: 'database' }, { key: 'plan_id', label: 'Query Store plan', num: true }, { key: 'seen_at', label: 'last seen', fmt: fmtTime },
      { key: 'get', label: 'plan', fmt: (_, r) => r.has_plan ? el('span', {}, btn('Download .sqlplan', r, false), ' ', btn('Open', r, true)) : el('span', { class: 'meta' }, 'no plan kept') },
    ], 'pgvigil holds no plan of these hashes: the Query Store did not keep it, no running read met the thresholds, and the plan cache no longer holds it.'),
    d.fetch_off || d.running_off ? offNote : '', status);
  (box.firstElementChild as HTMLElement).focus();
}
