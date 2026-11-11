// Metrics (task 131; DBA Dash's Metrics grid, in place of the Counters charts on a PostgreSQL instance and new on a
// SQL Server one): one grid per counter family with the max, min, average and newest value of every counter over the
// time range, the warning and critical thresholds in force for the row, the four figures coloured by them, and a chart
// opened from any row with the thresholds drawn as flat lines. A threshold IS an alert rule (alert_rules.ts): 'New
// threshold' and 'Edit' open the rule dialog, 'Override here' makes this instance's own rule over a wider one. Every
// figure comes from a series the repository already holds (no new collection); the grid, a row's chart and the rule's
// evaluation read the same samples (pgvigil.metric_points). Data from /api/metrics and /api/metrics/series. The page
// keeps the old Counters address: ?kind= is the family (db, server, io and sessions still open theirs; none = all) and
// ?mdb= one database's series of the Database family. The route and the tab are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { conditionWords, fmtMetric, ruleButton, ruleDialog, RulesDoor, scopeWords, stateBadge, unitWord } from './alert_rules';
import { Ctx, href, rangeLabel, window_ } from './router';
import { whatIsThis } from './sqlview';
import { Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

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
  if (!d.writable) sec.append(el('p', { class: 'meta' }, `Thresholds are read only here: ${d.reason ?? ''}`));
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
      cls: (_v, r) => { const c = statusClass(r[key.replace('_value', '_status')]); return c ? 'status ' + c : ''; },
      fmt: (v, r) => {
        if (v == null) return '';
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
        r.rule_state == null ? 'not judged yet' : stateBadge(r.rule_state, r.rule_held)) },
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
