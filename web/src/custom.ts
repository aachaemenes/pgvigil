// The Custom tab of one instance and the Custom report at the root (task 61; DBADash's custom checks and report):
// each check the configuration's custom: list runs on the instance, with its latest value or row count against its
// thresholds, its chart over the time range and the rows of its latest run; at the root every check of the fleet,
// the worst first. Data from /api/custom (?instance= for one instance). The shell mounts customView(ctx) and
// customReportView(keep, instLink) (the lead wires the route and the tabs).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

const statusRank: Record<string, number> = { critical: 0, error: 1, warning: 2 };
const rank = (r: Row): number => statusRank[String(r.status)] ?? (r.overdue ? 3 : r.status ? 4 : 5);
const withRank = (rows: Row[]): Row[] => rows.map(r => ({ ...r, status_rank: rank(r) }));

// statusCell: the latest run's status, and 'not run' when the check missed two of its cadences
function statusCell(r: Row): Node {
  const s = String(r.status ?? '');
  const span = el('span');
  if (!s) span.append(badge('never run', 'warn'));
  else span.append(badge(s, s === 'critical' || s === 'error' ? 'crit' : s === 'warning' ? 'warn' : 'ok'));
  if (r.overdue && s) span.append(' ', badge('not run in 2 cadences', 'warn'));
  return span;
}
const num = (v: unknown) => v == null ? '' : fmtNum(v);
const valueCell = (r: Row): string => r.status === 'error' ? '' : r.rule === 'rows' ? `${fmtNum(r.row_count)} rows` : r.value == null ? 'no value' : num(r.value);
const thresholds = (r: Row): string => {
  const p: string[] = [];
  if (r.warning != null) p.push(`warning ${String(r.compare)} ${num(r.warning)}`);
  if (r.critical != null) p.push(`critical ${String(r.compare)} ${num(r.critical)}`);
  return p.length ? p.join(', ') : 'none';
};
const ruleCell = (r: Row): string => r.rule === 'rows' ? 'row count' : `value${r.value_column ? ' (' + String(r.value_column) + ')' : ''}`;

const checkCols: Col[] = [
  { key: 'check_name', label: 'check' },
  { key: 'status_rank', label: 'status', num: true, fmt: (_v, r) => statusCell(r) },
  { key: 'value', label: 'value', num: true, fmt: (_v, r) => valueCell(r) },
  { key: 'thresholds', label: 'thresholds', fmt: (_v, r) => thresholds(r) },
  { key: 'rule', fmt: (_v, r) => ruleCell(r) },
  { key: 'last_run', label: 'last run', fmt: fmtTime },
  { key: 'every_secs', label: 'every', num: true, fmt: v => fmtSecs(v) },
  { key: 'duration_ms', label: 'took (ms)', num: true },
  { key: 'targets', label: 'runs on' },
  { key: 'error', label: 'error or note', wide: true, fmt: (v, r) => String(v ?? r.note ?? '') },
  { key: 'description', wide: true },
];

// rowsGrid shows a run's kept rows under their own column names
function rowsGrid(r: Row): HTMLElement {
  const cols = Array.isArray(r.columns) ? (r.columns as unknown[]).map(String) : [];
  if (!r.rows_kept) return el('p', { class: 'meta' }, String(r.note ?? 'The rows of this run were not kept.'));
  const data = Array.isArray(r.rows) ? (r.rows as unknown[][]).map(x => Object.fromEntries(cols.map((_c, i) => ['c' + i, x[i]]))) : [];
  return grid(data, cols.map((c, i) => ({ key: 'c' + i, label: c, wide: true })), 'The latest run returned no rows.');
}

export async function customView(ctx: Ctx): Promise<HTMLElement> {
  const w = window_(ctx);
  const d = await get<Record<'checks' | 'series' | 'findings' | 'gone', Table | null>>('custom', { instance: ctx.instance, from: w.from, to: w.to });
  const checks = withRank(rowsOf(d.checks)), series = rowsOf(d.series), gone = rowsOf(d.gone);
  const sec = el('section', {}, el('h2', {}, 'Custom checks'));
  if (!checks.length) {
    sec.append(el('p', { class: 'empty' }, 'No custom check runs on this instance: the configuration\'s custom: list names none for it '
      + '(a check runs on the instances and tags it names, or on every instance when it names neither). The catalogue of ready-made checks is in docs/custom.md.'));
    if (gone.length) sec.append(el('h3', {}, 'Taken off this instance'), grid(gone, [{ key: 'check_name', label: 'check' }, { key: 'targets', label: 'ran on' }, { key: 'gone_at', label: 'gone since', fmt: fmtTime }]));
    return sec;
  }
  const count = (s: string) => checks.filter(r => r.status === s).length;
  const crit = count('critical'), warn = count('warning'), err = count('error'), late = checks.filter(r => r.overdue).length;
  sec.append(el('div', { class: 'tiles' },
    tile('checks', fmtNum(checks.length)),
    tile('critical', fmtNum(crit), crit ? 'crit' : 'ok'),
    tile('warning', fmtNum(warn), warn ? 'warn' : 'ok'),
    tile('failed', fmtNum(err), err ? 'crit' : 'ok'),
    tile('not run in 2 cadences', fmtNum(late), late ? 'warn' : 'ok')));
  sec.append(el('p', { class: 'meta' },
    'Each check is the DBA\'s own SQL from the configuration, run by the collector as the instance\'s monitoring login in a read-only '
    + 'transaction that is rolled back, under the collector\'s statement and lock timeouts: a statement that writes fails and is shown as the check\'s error. '
    + 'A value check judges its value column (or the column named value, else the first) of the first row; a row-count check judges the rows returned. '
    + 'Critical is tested before warning; no value (no row, or NULL) judges nothing. At most 100 rows of a run are kept, and only under query_text full.'));
  sec.append(el('h3', {}, 'Checks'), grid(checks, checkCols));

  const span = Date.parse(w.to) - Date.parse(w.from);
  sec.append(el('h3', {}, `Values over ${rangeLabel(ctx)}`));
  const charts = el('div', { class: 'charts' });
  for (const c of checks) {
    const pts = series.filter(s => s.check_name === c.check_name).map(s => ({
      snapshot_at: s.snapshot_at, value: s.value,
      warning: c.warning, critical: c.critical,
    }));
    const lines = [{ key: 'value', label: c.rule === 'rows' ? 'rows' : String(c.value_column ?? 'value') }];
    if (c.warning != null) lines.push({ key: 'warning', label: 'warning' });
    if (c.critical != null) lines.push({ key: 'critical', label: 'critical' });
    charts.append(lineChart(`${String(c.check_name)} (${c.rule === 'rows' ? 'row count' : 'value'}, ${span > 6 * 3600 * 1000 ? 'the furthest past its thresholds per step' : 'per run'})`,
      pts, lines, v => fmtNum(v)));
  }
  sec.append(charts);

  sec.append(el('h3', {}, 'Latest rows and SQL'));
  for (const c of checks) {
    const det = el('details', {}, el('summary', {}, `${String(c.check_name)}: ${c.status ? String(c.status) : 'never run'}, ${fmtNum(c.row_count ?? 0)} rows`));
    det.append(rowsGrid(c), el('pre', { class: 'sql', tabindex: '0' }, String(c.sql ?? '')));
    sec.append(det);
  }
  if (gone.length) sec.append(el('h3', {}, 'Taken off this instance'), grid(gone, [{ key: 'check_name', label: 'check' }, { key: 'targets', label: 'ran on' }, { key: 'gone_at', label: 'gone since', fmt: fmtTime }]));
  return sec;
}

// customReportView: every check of the fleet with its latest run, the worst first (keep narrows it to a tag folder;
// instLink makes the instance name a link to its Custom tab).
export async function customReportView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const d = await get<Record<'report', Table | null>>('custom');
  let rows = withRank(rowsOf(d.report));
  if (keep) rows = rows.filter(keep);
  const count = (s: string) => rows.filter(r => r.status === s).length;
  const crit = count('critical'), warn = count('warning'), err = count('error'), late = rows.filter(r => r.overdue).length;
  const names = new Set(rows.map(r => String(r.check_name))), insts = new Set(rows.map(r => String(r.instance_id)));
  return el('section', {}, el('h2', {}, 'Custom report'),
    el('div', { class: 'tiles' },
      tile('checks', `${fmtNum(names.size)} on ${fmtNum(insts.size)} instances`),
      tile('critical', fmtNum(crit), crit ? 'crit' : 'ok'),
      tile('warning', fmtNum(warn), warn ? 'warn' : 'ok'),
      tile('failed', fmtNum(err), err ? 'crit' : 'ok'),
      tile('not run in 2 cadences', fmtNum(late), late ? 'warn' : 'ok')),
    el('p', { class: 'meta' }, 'Every custom check of every active instance with its latest run: critical, failed, warning and not run first. '
      + 'Each instance\'s Custom tab has the chart and the rows.'),
    grid(rows, [
      { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
      { key: 'platform' },
      ...checkCols.filter(c => !['duration_ms', 'description'].includes(c.key)),
    ], 'No custom check runs in the fleet: the configuration has no custom: list, or it names no instance.'));
}
