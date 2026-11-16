// Metrics (task 131; DBA Dash's Metrics grid, in place of the Counters charts on a PostgreSQL instance and new on a
// SQL Server one): one grid per counter family with the max, min, average and newest value of every counter over the
// time range, the warning and critical thresholds in force for the row, the four figures coloured by them, and a chart
// opened from any row with the thresholds drawn as flat lines. A threshold IS an alert rule (alert_rules.ts): 'New
// threshold' and 'Edit' open the rule dialog, 'Override here' makes this instance's own rule over a wider one. Every
// figure comes from a series the repository already holds (no new collection); the grid, a row's chart and the rule's
// evaluation read the same samples (pgvigil.metric_points). Data from /api/metrics and /api/metrics/series. The page
// keeps the old Counters address: ?kind= is the family (db, server, io and sessions still open theirs; none = all) and
// ?mdb= one database's series of the Database family. The route and the tab are the shell's.
import { get, post, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { conditionWords, fmtMetric, ruleButton, ruleDialog, RulesDoor, scopeWords, stateBadge, unitWord } from './alert_rules';
import { Ctx, href, rangeLabel, window_ } from './router';
import { whatIsThis } from './sqlview';
import { Col, el, errorBox, fmtNum, fmtTime, grid, offControl } from './ui';

interface MetricsData extends RulesDoor { engine: string; grid?: Table | null; databases: Table | null; families: Table | null }
interface SeriesData { step_secs: number; series: Table | null; metric: Table | null }

// the Counters page's kinds, kept as addresses of their families
const legacyKind: Record<string, string> = { db: 'database' };

const statusClass = (s: unknown) => s === 'critical' ? 'crit' : s === 'warning' ? 'warn' : s === 'ok' ? 'ok' : '';

const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));

export async function metricsView(ctx: Ctx): Promise<HTMLElement> {
  if (!ctx.instance) return el('p', { class: 'empty' }, 'Pick an instance in the tree on the left.');
  const q = new URLSearchParams(location.hash.split('?')[1] ?? '');
  const asked = q.get('kind') ?? 'all';
  const mdb = q.get('mdb')?.slice(0, 200) || undefined;
  const sec = el('section', {}, el('h2', {}, `Metrics (${rangeLabel(ctx)})`));
  const w = window_(ctx);
  let d: MetricsData;
  try { d = await get<MetricsData>('metrics', { instance: ctx.instance, ...w, part: 'families' }); } catch (e) { sec.append(errorBox(e)); return sec; }
  const dbs = rowsOf(d.databases).map(r => String(r.datname));
  const families: [string, string][] = rowsOf(d.families).map(f => [String(f.family), String(f.family_label)]);
  const kind = families.some(([k]) => k === (legacyKind[asked] ?? asked)) ? legacyKind[asked] ?? asked : 'all';
  // each family in view is its own read: a long range costs one family's read per request, and a family that fails
  // or times out shows its error under its own heading while the others draw
  const shown = families.filter(([k]) => kind === 'all' || kind === k);
  const reads = await Promise.all(shown.map(([k]) => get<MetricsData>('metrics', { instance: ctx.instance, ...w, db: mdb, family: k })
    .then(x => rowsOf(x.grid)).catch((e: unknown) => e instanceof Error ? e : new Error(String(e)))));
  const rows = reads.flatMap(x => x instanceof Error ? [] : x);
  // a link to this page: the family, and the database cut while the Database family is in view
  // (set or taken out here whatever the shell's own links keep, so 'all databases' always clears it)
  const link = (k: string, db?: string) => {
    const [path, qs] = href(ctx, { tab: ctx.tab, kind: k }).split('?');
    const p = new URLSearchParams(qs ?? '');
    if (db && (k === 'all' || k === 'database')) p.set('mdb', db); else p.delete('mdb');
    return `${path}?${p}`;
  };

  const withRule = rows.filter(r => r.rule_id != null).length, sampled = rows.filter(r => Number(r.samples) > 0).length;
  sec.append(el('p', { class: 'meta' },
    `${rows.length} counter(s)${kind === 'all' ? '' : ' in this family'}, ${sampled} with samples in the range, ${withRule} with a threshold. `,
    whatIsThis('Max, min, average and the newest value of every counter over the time range, from the samples the collector already stores (a cumulative counter is shown as its rate per interval; a counter reset gives no point). A row with a threshold shows its warning and critical values and colours each of the four figures by them; the threshold is an alert rule (the Alert rules page), judged by the alert sender on the same samples: the rule column says what it last made of it. The narrowest rule covering the instance is the one in force: this instance\'s own over a tag\'s over the fleet\'s. Chart draws a row over the range with its thresholds as flat lines.', 'Metrics')));
  // the page's one sentence where thresholds cannot be written here: every off control below points at it
  if (!d.writable) { d.note = el('p', { class: 'meta' }, `Thresholds are read only here: ${d.reason ?? ''}`); sec.append(d.note); }
  sec.append(el('div', { class: 'subtabs' }, ...[['all', 'all'], ...families].map(([k, label]) =>
    el('a', { href: link(k, mdb), class: k === kind ? 'on' : '', ...(k === kind ? { 'aria-current': 'true' } : {}) }, label))));
  if (!families.length) { sec.append(el('p', { class: 'empty' }, 'No counter is known for this instance.')); return sec; }

  for (const [i, [, famLabel]] of shown.entries()) {
    const read = reads[i];
    if (read instanceof Error) { sec.append(el('h3', {}, famLabel), errorBox(read)); continue; }
    const famRows = read;
    const perDb = famRows.some(r => r.per_database);
    const head = el('h3', {}, famLabel);
    const box = el('div', {});
    const chartsBox = el('div', { class: 'charts' });
    const open = new Map<string, HTMLElement>();          // the charts drawn, by counter key
    const btns = new Map<string, HTMLButtonElement>();    // each row's Chart button as the grid last drew it
    const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
    const cut = (r: Row) => r.per_database ? mdb : undefined;

    const toggleChart = async (r: Row) => {
      const key = String(r.key);
      const had = open.get(key);
      if (had) { had.remove(); open.delete(key); btns.get(key)?.setAttribute('aria-pressed', 'false'); return; }
      const holder = el('div', {}, el('p', { class: 'meta', role: 'status' }, `Reading ${String(r.label)}...`));
      open.set(key, holder);
      chartsBox.append(holder);
      btns.get(key)?.setAttribute('aria-pressed', 'true');
      try {
        const s = await get<SeriesData>('metrics/series', { instance: ctx.instance, metric: key, ...w, db: cut(r) });
        const m = rowsOf(s.metric)[0] ?? {};
        // the thresholds ride every point as flat lines
        const pts = rowsOf(s.series).map(p => ({ ...p, warning: m.warning ?? null, critical: m.critical ?? null }));
        const bucketed = Number(s.step_secs) > 1;
        const series = [
          { key: 'value', label: bucketed ? `${String(r.label)} (average per ${fmtNum(Number(s.step_secs) / 60)} min)` : String(r.label) },
          ...(bucketed ? [{ key: 'max_value', label: 'highest' }, { key: 'min_value', label: 'lowest' }] : []),
          ...(m.warning != null ? [{ key: 'warning', label: `warning (${String(m.op)} ${fmtMetric(m.warning, r.unit)})` }] : []),
          ...(m.critical != null ? [{ key: 'critical', label: `critical (${String(m.op)} ${fmtMetric(m.critical, r.unit)})` }] : []),
        ];
        const title = `${famLabel}: ${String(r.label)}${cut(r) ? ` [${cut(r)}]` : ''} (${unitWord(r.unit)})`;
        holder.replaceChildren(lineChart(title, pts, series, v => fmtMetric(v, r.unit)));
      } catch (e) {
        holder.replaceChildren(el('h3', {}, String(r.label)), errorBox(e));
      }
    };

    const figure = (key: string, label: string): Col => ({
      key, label, num: true,
      // task 402: a floored row under its floor is N/A, grey ('status none', the not-judged class of mssql_backups.ts)
      cls: (v, r) => { if (v == null && (r.floor != null || r.na_why != null) && Number(r.samples) > 0) return 'status none';
        const c = statusClass(r[key.replace('_value', '_status')]); return c ? 'status ' + c : ''; },
      fmt: (v, r) => {
        if (v == null) {
          // task 402: a floored metric (0152's metric_floors) under its floor has no value: N/A, grey, in words, with or
          // without a rule's state; the current cell names the input's current rate from the same grid
          if ((r.floor == null && r.na_why == null) || Number(r.samples) === 0) return '';
          // a metric not judged under a condition of its own (0152's metric_na_reasons): its reason, never a bare N/A
          const inp = famRows.find(x => x.key === r.floor_input && (x.database ?? null) === (r.database ?? null))?.current_value;
          const why = r.na_why != null ? `N/A: ${String(r.na_why)}`
            : `N/A: too few ${String(r.floor_unit)}/s to judge (${inp == null ? 'not read' : fmtNum(Math.floor(100 * Number(inp)) / 100)}/s, the floor ${fmtNum(Number(r.floor))}/s)`;
          if (key === 'current_value') return why;
          // the max, min and average cells: N/A with the same words as their title (boxfix S1: never a bare N/A)
          return el('span', { title: why, 'aria-label': why }, 'N/A');
        }
        const st = r[key.replace('_value', '_status')];
        if (st == null) return fmtMetric(v, r.unit);
        // the status is a word in the cell too (never the colour alone; a copy or an export carries it)
        const t = el('span', { class: 'cell-link' }, fmtMetric(v, r.unit) + (st === 'ok' ? '' : ` (${String(st)})`));
        t.title = `${String(st)}: the threshold is ${conditionWords(r)}`;
        return t;
      },
    });
    const cols: Col[] = [
      { key: 'label', label: 'counter', fmt: (v, r) => el('span', { title: `${String(r.key)}, in ${unitWord(r.unit)}` }, String(v ?? '')) },
      ...(perDb && mdb ? [{ key: 'database', fmt: (v: unknown, r: Row) => r.per_database ? String(v ?? '') : '(the instance)' }] as Col[] : []),
      figure('max_value', 'max'), figure('min_value', 'min'), figure('avg_value', 'avg'), figure('current_value', 'current'),
      { key: 'samples', num: true },
      { key: 'current_at', label: 'last sample', fmt: fmtTime },
      { key: 'warning', num: true, fmt: (v, r) => v == null ? '' : `${String(r.op)} ${fmtMetric(v, r.unit)}` },
      { key: 'critical', num: true, fmt: (v, r) => v == null ? '' : `${String(r.op)} ${fmtMetric(v, r.unit)}` },
      { key: 'rule_id', label: 'rule', fmt: (v, r) => v == null ? '' : el('span', {},
        `${Number(r.for_minutes) > 0 ? `for ${String(r.for_minutes)} min` : 'at the first sample'}, ${scopeWords(r.rule_scope, r.rule_target)}${r.rule_database != null ? `, database ${String(r.rule_database)}` : ''}: `,
        // task 402: a seeded rule that is off colours the row and sends nothing; its state is never judged
        r.rule_enabled === false ? 'off: colours only, no alert' : r.rule_state == null ? 'not judged yet' : stateBadge(r.rule_state, r.rule_held, r.na_why)), cls: (v, r) => v != null && r.rule_state == null ? 'status none' : '' },
      { key: '_threshold', label: 'threshold', fmt: (_v, r) => thresholdCell(d, ctx.instance!, r, cut(r)) },
      { key: '_chart', label: 'chart', fmt: (_v, r) => {
        const b = el('button', { type: 'button', class: 'toggle', 'aria-pressed': String(open.has(String(r.key))), 'aria-label': `Chart ${famLabel}: ${String(r.label)}` }, 'Chart');
        b.addEventListener('click', () => { void toggleChart(r); });
        btns.set(String(r.key), b);
        return el('span', { class: 'seg', style: 'margin:0' }, b);
      } },
    ];
    // every row's chart at once (the Counters page drew a family's charts together)
    const allBtn = el('button', { type: 'button', class: 'link', 'aria-label': `Chart every row of ${famLabel}` }, 'Chart every row');
    allBtn.addEventListener('click', async () => {
      const todo = famRows.filter(r => !open.has(String(r.key)) && Number(r.samples) > 0);
      said.textContent = todo.length ? `Drawing ${todo.length} chart(s)...` : 'Every row with samples is charted already.';
      for (const r of todo) await toggleChart(r);
      if (todo.length) said.textContent = `${todo.length} chart(s) drawn under the grid.`;
    });
    const tools = el('div', { class: 'toolbar' }, el('div', { class: 'seg' }, allBtn));
    if (perDb && dbs.length) {
      const sel = el('select', { 'aria-label': `${famLabel}: database` }, el('option', { value: '' }, 'all databases (summed)'), ...dbs.map(n => el('option', { value: n }, n)));
      if (mdb && !dbs.includes(mdb)) sel.append(el('option', { value: mdb }, mdb));
      sel.value = mdb ?? '';
      sel.addEventListener('change', () => { location.hash = link(kind, sel.value || undefined); });
      tools.append(el('label', {}, 'Database ', sel));
      // a rule without a database judges the summed series only: it is not shown as one database's threshold
      if (mdb) tools.append(el('span', { class: 'meta' }, `The thresholds shown for ${mdb} are the rules that name that database; a rule without a database watches all databases summed, and shows under 'all databases'.`));
    }
    box.append(grid(famRows, cols, 'No counter in this family.'));
    sec.append(head, tools, said, box, chartsBox);
  }
  if (d.engine === 'sqlserver') sec.append(await mssqlCounters(ctx));
  return sec;
}

// PerformanceMonitor's perfmon panel's default counters (server-tabs.js PERFMON_DEFAULT_COUNTERS) and its chart cap
// (MAX_COUNTERS_CHARTED)
const pmDefaultCounters = ['Batch Requests/sec', 'SQL Compilations/sec', 'SQL Re-Compilations/sec', 'Query optimizations/sec', 'Network IO waits'];
const maxCharted = 10;

// a write's outcome across the page's redraw (adminCountersView)
let carriedSaid = '';

// what a series' figure is, by its kind (0152: the arithmetic follows the type SQL Server gives the counter)
const kindWords: Record<string, string> = {
  rate: 'per second', count: 'change per read', fraction: '% of its base', average: 'average per event over the read',
  gauge: 'value as it stands', unpaired: 'as read (its base was not in the read)',
};

// the figure of a row in words: a fraction in %, the rest as numbers; a rate before its second read says so
function figureText(r: Row): string {
  const k = String(r.kind ?? 'gauge');
  if (r.figure == null) {
    if (k === 'rate') return 'no rate yet';
    if (k === 'count') return 'no change yet';
    if (k === 'average') return r.dbase === 0 ? 'no event in the read' : 'no average yet';
    if (k === 'unpaired') return fmtNum(r.value);
    if (k === 'fraction' && Number(r.base) === 0) return 'base 0 in the read';
    return '';
  }
  return k === 'fraction' ? fmtNum(Number(r.figure).toFixed(2)) + ' %' : fmtNum(r.figure);
}

// mssqlCounters (task 177 D14, task 401 B3): a SQL Server instance's performance counters in PerformanceMonitor's
// perfmon panel's shape: the newest read as a grid (the instance's counter list: Admin > Counters; instance counters
// every minute, per-database ones every 5 minutes) and a chart of up to ten series picked in it, one series per
// counter and instance. Each row's figure follows its kind: a rate per second, a count's change per read, a fraction
// of its base in %, an average over its base between two reads, a gauge as it stands. Then the batch response
// histogram (Batch Resp Statistics) over the range and the listed counters the newest read did not have. Data from
// /api/mssql/counters and /api/mssql/counteradmin.
async function mssqlCounters(ctx: Ctx): Promise<HTMLElement> {
  const box = el('div', { class: 'mssql-counters' }, el('h3', {}, 'Performance counters (sys.dm_os_performance_counters)'));
  const w = window_(ctx);
  let rows: Row[];
  try { rows = rowsOf((await get<Record<'now', Table | null>>('mssql/counters', { instance: ctx.instance, ...w, part: 'now' })).now); } catch (e) { box.append(errorBox(e)); return box; }
  box.append(el('p', { class: 'meta' }, 'The counters read are the instance\'s list: ',
    el('a', { href: href(ctx, { tab: 'admin_counters', instance: undefined }) }, 'Admin > Counters'), ' adds or removes one for the fleet, a tag or this instance.'));
  if (!rows.length) {
    box.append(el('p', { class: 'empty' }, 'No performance counter read in this range: mssql_counters reads the instance counters every minute, mssql_counters_db the per-database ones every 5 minutes.'));
  } else {
    const key = (r: Row) => String(r.series_id);
    const name = (r: Row) => `${String(r.counter)}${r.inst && r.inst !== '_Total' ? ` [${String(r.inst)}]` : ''}`;
    const picked = new Set<string>();
    for (const c of pmDefaultCounters) {
      const hit = rows.find(r => r.scope === 'instance' && r.counter === c && (r.inst === '_Total' || !rows.some(x => x.counter === c && x.inst === '_Total')));
      if (hit && picked.size < maxCharted) picked.add(key(hit));
    }
    const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
    const chartBox = el('div', { class: 'charts' });
    const draw = async () => {
      const ids = [...picked];
      said.textContent = `${ids.length} of at most ${maxCharted} series charted.`;
      if (!ids.length) { chartBox.replaceChildren(el('p', { class: 'meta' }, 'Check at least one counter to chart it.')); return; }
      try {
        const s = rowsOf((await get<Record<'series', Table | null>>('mssql/counters', { instance: ctx.instance, ...w, part: 'series', series: ids.join(',') })).series);
        const at = new Map<string, Row>();
        for (const p of s) {
          const k = String(p.snapshot_at);
          const row = at.get(k) ?? { snapshot_at: p.snapshot_at };
          row['s' + String(p.series_id)] = p.value;
          at.set(k, row);
        }
        const byId = new Map(rows.map(r => [key(r), r]));
        chartBox.replaceChildren(lineChart('Performance counters (each series in its own figure: see the kind column)', [...at.values()],
          ids.map(id => ({ key: 's' + id, label: byId.has(id) ? `${name(byId.get(id)!)} (${String(byId.get(id)!.kind) === 'count' ? 'change summed per step of the chart' : kindWords[String(byId.get(id)!.kind)] ?? ''})` : id })), v => fmtNum(v)));
      } catch (e) { chartBox.replaceChildren(errorBox(e)); }
    };
    const boxes: HTMLInputElement[] = [];
    const cap = () => { for (const b of boxes) b.disabled = !b.checked && picked.size >= maxCharted; };
    const cols: Col[] = [
      { key: '_pick', label: 'chart', fmt: (_v, r) => {
        const b = el('input', { type: 'checkbox', 'aria-label': `Chart ${name(r)} (${String(r.object)})` }) as HTMLInputElement;
        b.checked = picked.has(key(r));
        b.addEventListener('change', () => { if (b.checked) picked.add(key(r)); else picked.delete(key(r)); cap(); void draw(); });
        boxes.push(b);
        return b;
      } },
      { key: 'object' }, { key: 'counter' }, { key: 'inst', label: 'instance' },
      { key: 'figure', num: true, fmt: (_v, r) => figureText(r) },
      { key: 'kind', fmt: v => el('span', { title: kindWords[String(v)] ?? '' }, String(v ?? '')) },
      { key: 'value', label: 'raw value', num: true, fmt: v => fmtNum(v) },
      { key: 'base', num: true, fmt: (v, r) => r.kind === 'fraction' || r.kind === 'average' ? fmtNum(v) : '' },
      { key: 'scope', label: 'read', fmt: v => v === 'database' ? 'every 5 minutes' : 'every minute' },
      { key: 'snapshot_at', label: 'newest read', fmt: fmtTime },
    ];
    box.append(el('p', { class: 'meta' }, `${rows.length} counter row(s) at the newest read. A rate or count that never counted since the server started has the figure 0 and an average reads 'no event in the read' (the read names it, no row is stored for it); a gauge has its row at every read.`),
      grid(rows, cols), said, chartBox);
    cap();
    await draw();
  }
  box.append(await counterHistogram(ctx), await counterAbsent(ctx));
  return box;
}

// counterHistogram: the Batch Resp Statistics buckets over the range (T41): how many batches ended in each elapsed-time
// bucket and how many used that much CPU, the changes of the cumulative buckets summed over the range's reads; each
// row's bar is its share of the range's batches, the number beside it
async function counterHistogram(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('div', {}, el('h3', {}, `Batch response times (Batch Resp Statistics, ${rangeLabel(ctx)})`));
  let rows: Row[];
  try { rows = rowsOf((await get<Record<'histogram', Table | null>>('mssql/counteradmin', { instance: ctx.instance, ...window_(ctx), part: 'histogram' })).histogram); } catch (e) { sec.append(errorBox(e)); return sec; }
  const total = (k: string) => rows.reduce((a, r) => a + Number(r[k] ?? 0), 0);
  const te = total('elapsed_batches'), tc = total('cpu_batches');
  if (!rows.length || !rows.some(r => Number(r.reads) > 0)) {
    sec.append(el('p', { class: 'empty' }, 'No two reads of Batch Resp Statistics in this range: the histogram is the change between reads (the server counts since it started).'));
    return sec;
  }
  const bar = (n: unknown, t: number) => {
    const pct = t > 0 ? 100 * Number(n ?? 0) / t : 0;
    return el('span', { style: 'display:inline-flex;align-items:center;gap:.4rem' },
      el('span', { 'aria-hidden': 'true', style: `display:inline-block;height:.7rem;width:${Math.max(0, Math.min(100, pct)) * 1.2}px;background:var(--accent, currentColor)` }),
      `${fmtNum(n)} (${pct.toFixed(1)} %)`);
  };
  const label = (r: Row) => r.hi_ms == null ? `${fmtNum(r.lo_ms)} ms or more` : `${fmtNum(r.lo_ms)} to ${fmtNum(r.hi_ms)} ms`;
  sec.append(el('p', { class: 'meta' }, `${fmtNum(te)} batch(es) ended in the range by elapsed time, ${fmtNum(tc)} by CPU time.`),
    grid(rows, [
      { key: 'bucket', label: 'bucket', fmt: (_v, r) => label(r) },
      { key: 'elapsed_batches', label: 'batches by elapsed time', fmt: v => bar(v, te) },
      { key: 'elapsed_total_ms', label: 'their elapsed ms', num: true, fmt: v => fmtNum(v) },
      { key: 'cpu_batches', label: 'batches by CPU time', fmt: v => bar(v, tc) },
      { key: 'cpu_total_ms', label: 'their CPU ms', num: true, fmt: v => fmtNum(v) },
    ]));
  return sec;
}

// counterAbsent: the instance's listed counters its newest read did not have, and why (a version or edition without
// it, listed after the read, the catalogue not read yet)
async function counterAbsent(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('div', {}, el('h3', {}, 'Listed but not read'));
  try {
    const rows = rowsOf((await get<Record<'absent', Table | null>>('mssql/counteradmin', { instance: ctx.instance, part: 'absent' })).absent);
    sec.append(rows.length
      ? grid(rows, [{ key: 'object' }, { key: 'counter' }, { key: 'inst', label: 'instance', fmt: v => String(v || 'every instance') }, { key: 'scope', label: 'read', fmt: v => v === 'database' ? 'every 5 minutes' : 'every minute' }, { key: 'why' }])
      : el('p', { class: 'meta' }, 'Every listed counter was in the newest read of its scope; a scope with no read yet (the first 5 minutes of mssql_counters_db, or the collection off) is not judged here: the grid above says when its newest read was.'));
  } catch (e) { sec.append(errorBox(e)); }
  return sec;
}

// adminCountersView (Admin > Counters, task 401): the SQL Server counter list. Admin's rows (add or remove a counter
// for the fleet, a tag or one instance; the narrowest scope wins, and at one scope Admin's row wins over
// pgvigil.yaml's line), the defaults with what reads each, one instance's list with where each word comes from, the
// counters its server has, and the page's log. A counter a page or a rule reads cannot be removed: the store refuses
// it and says what reads it. Writes ride the UI login and the actions door's audit login; off, every control says why.
export async function adminCountersView(_ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Counters (SQL Server)'));
  type AdminData = { writable?: boolean; reason?: string; config: Table | null; defaults: Table | null; log: Table | null; catalog: Table | null };
  let d: AdminData;
  try { d = await get<AdminData>('mssql/counteradmin'); } catch (e) { sec.append(errorBox(e)); return sec; }
  const off = d.writable ? null : (d.reason ?? 'not writable here');
  sec.append(el('p', { class: 'meta' }, 'Each SQL Server instance reads the counters of its list: the defaults below, then pgvigil.yaml\'s mssql_counters lines (the root\'s, the instance\'s), then the rows here. For each counter the narrowest scope wins (an instance over a tag over the fleet); at one scope a row here wins over pgvigil.yaml. A change is read at the instance\'s next read.'),
    ...(off ? [el('p', { class: 'meta' }, `Edits are off here: ${off}`)] : []));
  const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite', tabindex: '-1' });
  if (carriedSaid) { said.textContent = carriedSaid; carriedSaid = ''; setTimeout(() => said.focus(), 0); }
  const send = async (body: Record<string, unknown>) => {
    try {
      const r = await post<{ outcome: string; detail: string }>('mssql/counteradmin', body);
      // the redraw rebuilds the page: the outcome is carried across it and the status line takes the focus (part 3's finding 6)
      carriedSaid = `${r.outcome}: ${r.detail}`;
      window.dispatchEvent(new HashChangeEvent('hashchange'));
    } catch (e) { said.textContent = 'Not written: ' + (e instanceof Error ? e.message : String(e)); }
  };

  // the add form
  const cat = rowsOf(d.catalog);
  const objects = [...new Set(cat.map(r => String(r.object)))].sort();
  const list = el('datalist', { id: 'ctr-objects' }, ...objects.map(o => el('option', { value: o })));
  const clist = el('datalist', { id: 'ctr-counters' });
  const scope = el('select', { 'aria-label': 'Scope' }, el('option', { value: 'fleet' }, 'the fleet'), el('option', { value: 'tag' }, 'a tag'), el('option', { value: 'instance' }, 'one instance')) as HTMLSelectElement;
  const tag = el('input', { type: 'text', 'aria-label': 'Tag', placeholder: 'tag (key:value or value)', maxlength: '200' }) as HTMLInputElement;
  const inst = el('select', { 'aria-label': 'Instance' }) as HTMLSelectElement;
  const object = el('input', { type: 'text', list: 'ctr-objects', 'aria-label': 'Object', placeholder: 'object, e.g. General Statistics', maxlength: '128' }) as HTMLInputElement;
  const counter = el('input', { type: 'text', list: 'ctr-counters', 'aria-label': 'Counter', placeholder: 'counter, e.g. Logins/sec', maxlength: '128' }) as HTMLInputElement;
  const cinst = el('input', { type: 'text', 'aria-label': 'Counter instance (empty = every instance)', placeholder: 'instance (empty = every one)', maxlength: '128' }) as HTMLInputElement;
  const action = el('select', { 'aria-label': 'Action' }, el('option', { value: 'add' }, 'add'), el('option', { value: 'remove' }, 'remove')) as HTMLSelectElement;
  const kind = el('select', { 'aria-label': 'Kind' }, el('option', { value: '' }, 'kind from its type'), el('option', { value: 'count' }, 'count since the start (65792)'), el('option', { value: 'rate' }, 'rate'), el('option', { value: 'gauge' }, 'gauge')) as HTMLSelectElement;
  const note = el('input', { type: 'text', 'aria-label': 'Note', placeholder: 'note (optional)', maxlength: '500' }) as HTMLInputElement;
  object.addEventListener('change', () => {
    clist.replaceChildren(...cat.filter(r => r.object === object.value).map(r => el('option', { value: String(r.counter) })));
  });
  const showScope = () => { tag.hidden = scope.value !== 'tag'; inst.hidden = scope.value !== 'instance'; };
  scope.addEventListener('change', showScope);
  try {
    const all = rowsOf(await get<Table>('instances')).filter(r => r.engine === 'sqlserver');
    inst.replaceChildren(...all.map(r => el('option', { value: String(r.instance_id) }, String(r.name))));
  } catch { /* the instance list is optional for fleet and tag rows */ }
  showScope();
  const save = el('button', { type: 'button' }, 'Save row') as HTMLButtonElement;
  save.addEventListener('click', () => {
    if (!object.value.trim() || !counter.value.trim()) { said.textContent = 'Name the object and the counter.'; return; }
    void send({ op: 'add', scope: scope.value, tag: tag.value, instance_id: Number(inst.value || 0), object: object.value.trim(), counter: counter.value.trim(),
      inst: cinst.value.trim(), action: action.value, kind: kind.value, note: note.value.trim() });
  });
  const saveNote = offControl(save, off);
  sec.append(el('h3', {}, 'Add or remove a counter'), list, clist,
    el('div', { class: 'toolbar', style: 'flex-wrap:wrap;gap:.5rem' }, scope, tag, inst, object, counter, cinst, action, kind, note, save, saveNote),
    // a kind is the whole series' (review part 2's 10): the store reads its past again under the new kind
    el('p', { class: 'meta' }, 'Kind: empty takes the kind of the layer below (a default\'s, else the one SQL Server types). A kind belongs to the counter\'s whole series: a change reads its past again under the new kind - gauge to rate leaves no points before the change, rate to gauge shows the raw totals since the server started.'),
    said);

  // Admin's live rows, each with its End
  const endCell = (_v: unknown, r: Row) => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `End row ${String(r.config_id)} (${String(r.object)} / ${String(r.counter)})` }, 'End') as HTMLButtonElement;
    // End asks first, as Alert rules' End does (part 3's NIT 10)
    b.addEventListener('click', () => { if (window.confirm(`End row ${String(r.config_id)} (${String(r.object)} / ${String(r.counter)})? The counter list goes back to the word below it.`)) void send({ op: 'end', config_id: Number(r.config_id) }); });
    // the page's 'Edits are off here' line carries the long reason; each row says it short, a space after the button
    // (proof5's shot read 'Endthe counter list ...' run together and cut at the table's edge)
    const short = off ? el('span', { class: 'off-reason' }, 'off here: the line above says why') : undefined;
    return el('span', {}, b, ' ', offControl(b, off, short));
  };
  const where = (r: Row) => r.scope === 'tag' ? `tag ${String(r.tag)}` : r.scope === 'instance' ? String(r.instance_name) : 'the fleet';
  sec.append(el('h3', {}, 'Rows made here'), grid(rowsOf(d.config), [
    { key: 'scope', label: 'for', fmt: (_v, r) => where(r) }, { key: 'action' }, { key: 'object' }, { key: 'counter' },
    { key: 'inst', label: 'instance', fmt: v => String(v || 'every one') }, { key: 'kind', fmt: v => String(v || 'from its type') },
    { key: 'note' }, { key: 'created_by', label: 'by' }, { key: 'created_at', label: 'at', fmt: fmtTime }, { key: '_end', label: 'end', fmt: endCell },
  ], 'No row: every instance reads the defaults and pgvigil.yaml\'s lines.'));

  // one instance's list, where each word comes from
  const pick = el('select', { 'aria-label': 'Instance to show' }, el('option', { value: '' }, 'pick an instance'), ...[...inst.options].map(o => el('option', { value: o.value }, o.text))) as HTMLSelectElement;
  const one = el('div', {});
  pick.addEventListener('change', async () => {
    if (!pick.value) { one.replaceChildren(); return; }
    one.replaceChildren(el('p', { class: 'meta', role: 'status' }, 'Reading...'));
    try {
      const x = await get<{ layers: Table | null; catalog: Table | null; absent: Table | null }>('mssql/counteradmin', { instance: pick.value, part: 'layers' });
      const lr = rowsOf(x.layers);
      const yr = lr.find(r => r.yaml_read_at != null)?.yaml_read_at;
      one.replaceChildren(
        el('p', { class: 'meta' }, yr ? `pgvigil.yaml's lines as its collector last handed them over at ${fmtTime(yr)}.` : 'Its collector has not run since this version: pgvigil.yaml\'s lines show after its first run.'),
        grid(lr, [
          { key: 'wins', label: 'in force', fmt: (v, r) => v ? 'yes' : r.blocked ? 'no: a page reads this counter, it stays' : 'no: another word wins (a narrower one, or a newer one at the same level)' }, { key: 'object' }, { key: 'counter' },
          { key: 'inst', label: 'instance', fmt: v => String(v || 'every one') }, { key: 'action' }, { key: 'source', label: 'from' },
          { key: 'used_by', label: 'read by' }, { key: 'scope', label: 'read', fmt: v => v === 'database' ? 'every 5 minutes' : 'every minute' },
        ]));
    } catch (e) { one.replaceChildren(errorBox(e)); }
  });
  sec.append(el('h3', {}, 'One instance\'s list'), el('label', {}, 'Instance ', pick), one);

  sec.append(el('h3', {}, 'The defaults'), grid(rowsOf(d.defaults), [
    { key: 'object' }, { key: 'counter' }, { key: 'kind', fmt: v => String(v || 'from its type') }, { key: 'scope', label: 'read', fmt: v => v === 'database' ? 'every 5 minutes' : 'every minute' },
    { key: 'used_by', label: 'read by (never removed)' }, { key: 'source', label: 'rows' },
  ]));
  sec.append(el('h3', {}, 'Counters the servers have'), el('p', { class: 'meta' }, 'Read once a day by mssql_counter_catalog on each SQL Server instance.'),
    grid(cat, [{ key: 'object' }, { key: 'counter' }, { key: 'cntr_type', label: 'type', num: true }, { key: 'servers', num: true }, { key: 'read_at', label: 'newest read', fmt: fmtTime }],
      'No catalogue read yet.'));
  sec.append(el('h3', {}, 'Log'), grid(rowsOf(d.log), [
    { key: 'at', fmt: fmtTime }, { key: 'ui_user', label: 'by' }, { key: 'op' }, { key: 'action' }, { key: 'object' }, { key: 'counter' },
    { key: 'scope' }, { key: 'outcome' }, { key: 'detail' },
  ], 'No attempt yet.'));
  return sec;
}

// thresholdCell: the row's write links - a new threshold where none is in force; Edit for the rule in force, and
// 'Override here' when that rule is wider than this instance (or than the database in view)
function thresholdCell(d: RulesDoor, instance: number, r: Row, db: string | undefined): HTMLElement {
  const span = el('span', { style: 'white-space:nowrap' });
  const name = String(r.label);
  if (r.rule_id == null) {
    span.append(ruleButton(d, 'New threshold', `New threshold for ${name}`, () => { void ruleDialog({ door: d, metric: String(r.key), instanceId: instance, database: db, after: redraw }); }));
    return span;
  }
  span.append(ruleButton(d, 'Edit', `Edit the threshold of ${name} (rule ${String(r.rule_id)}, ${scopeWords(r.rule_scope, r.rule_target)})`, () => { void editRule(d, Number(r.rule_id)); }));
  const own = r.rule_scope === 'instance' && (db == null || r.rule_database === db);
  if (!own) {
    span.append(' · ', ruleButton(d, 'Override here', `Override here: the threshold of ${name} for this instance${db ? `, database ${db}` : ''}`, () => {
      void ruleDialog({ door: d, metric: String(r.key), instanceId: instance, database: db, prefill: { op: r.op, warning: r.warning, critical: r.critical, for_minutes: r.for_minutes }, after: redraw });
    }));
  }
  return span;
}

// editRule opens the rule in force for editing: its whole row is read first (the grid carries only its condition)
async function editRule(d: RulesDoor, ruleId: number) {
  try {
    const all = rowsOf((await get<{ rules: Table | null }>('alertrules', { part: 'rules' })).rules);
    const rule = all.find(x => Number(x.rule_id) === ruleId && x.live);
    if (!rule) { window.alert(`Rule ${ruleId} is no longer live: reload the page.`); return; }
    void ruleDialog({ door: d, rule, after: redraw });
  } catch (e) {
    window.alert('The rule could not be read: ' + (e instanceof Error ? e.message : String(e)));
  }
}
