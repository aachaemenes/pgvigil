// Custom reports (task 170; DBA Dash's custom reports): the DBA's own SQL, or a procedure, saved as a report with
// parameters, column formats, colour rules (ok / warn / crit by a column's value) and a folder of the tree shared by all
// users; run on the repository (the store) or, read-only, on a chosen instance or a tag's instances. The result is
// pgvigil's grid (its menus, the export, the grid tools): the formats and the colour rules are applied here, on the
// screen, as status cells, so the Excel export and a mailed page carry the colours the window shows.
// Data: GET /api/customreports (the tree, the definitions, the log) and ?report=N; POST /api/customreports (a save, a
// move, a delete, a folder change) and /api/customreports/run (internal/web/q_customreports.go).
// The shell mounts customReportsView(ctx) as the root tab 'customreports' and as an instance tab (the run's target
// defaults to that instance); the page's own address: #/customreports?report=N (&run=1 runs it on open, &p.<name>=<value>
// fills a parameter), ?edit=N, ?new=1&folder=<path> (the lead wires the route and the tree's Custom reports folder).
import { reloadTree } from './tree';
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, window_ } from './router';
import { fleetWideNote, folderWords, inTagScope, tagWords, writtenTag } from './fleet';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, gridModel, GridMenuAsk, MenuLine, offControl, showMenu } from './ui';
import { Can, markNeed, routeWhy } from './needs';
import { gridFiltered, gridHidden, gridMenu, resetGrid, setGridDefault } from './gridtools';
import { firstChars, openViewer } from './sqlview';
import { CHART_TYPES, ChartDef, ChartSet, ChartType, chartTypeNames, drawChart } from './crchart';
import { instanceTabs, mssqlInstanceTabs } from './router';

// picker: how the run's form offers the value (DBA Dash's Pickers, L95) - a list, a text box (Enter runs) or a query's
// values (its first column the value, its second the words); menu = on the run's toolbar first
export interface Picker { kind: 'list' | 'text' | 'query'; values?: string[]; query?: string; menu?: boolean }
export interface Param { name: string; type: string; label?: string; default?: string; required?: boolean; picker?: Picker }
// tooltip: the header's title (Set Column Tooltip, L117); utc: a time shown as stored, in UTC (Convert to local time zone off, L118)
export interface ColFmt { set: number; column: string; label?: string; format?: string; decimals?: number; hidden?: boolean; tooltip?: string; utc?: boolean }
export interface Rule { set: number; column: string; eval?: string; cond: string; value1?: string; value2?: string; status: string; case_sensitive?: boolean }
export interface ReportDef {
  report_id?: number; name: string; description?: string; folder: string; engine: string; kind: string; body: string;
  params: Param[]; columns: ColFmt[]; rules: Rule[]; timeout_secs: number; max_rows: number; version?: number;
  visibility?: Visibility; access?: string[];   // 0372's view: who sees it, which roles open it (a list: Q160 is open)
  status_from_messages?: boolean;               // the run's own NOTICE / PRINT messages as its status (L90)
  collections?: string[];                       // the collections its data comes from (Associate Collection, L98)
  sets?: SetView[];                             // a result set's name and whether All shows it (L102, L110)
  pair?: { report_id: number; label: string };  // the switch button's report and words (L106)
  url?: string; url_label?: string;             // a link under the description (L107)
  layout?: SavedLayout;                         // Save Layout: every viewer's default (L109, L208)
  links?: Link[];                               // a column's cells as links (Add Link, L120, L125-L128)
  charts?: ChartDef[];                          // a result set as a chart (Add Chart, L130-L135)
  system_charts?: string[];                     // the instance's own charts beside it (L131): cpu, waits, io, blocking
}
// a link on a result set's column: url / text use the target column's value (the column itself when none); drill opens
// another report with its parameters from the row (map: its parameter -> this row's column); tree opens the row's
// instance at a tab
export interface Link { set?: number; column: string; kind: 'url' | 'text' | 'drill' | 'tree'; target_column?: string; syntax?: string;
  report_id?: number; map?: Record<string, string>; open?: 'new' | 'same' | 'panel'; instance_column?: string; database_column?: string; tab?: string }
// LinkCtx: what a report page gives setGrid for its links (the drill-down's address and its panel)
export interface LinkCtx { links: Link[]; drillHref: (l: Link, from: Record<string, string>) => string; panel: (l: Link, from: Record<string, string>) => void; range: () => string }
export interface SavedLayout { sets?: { set: number; hidden?: string[] }[]; grid_off?: boolean; heights?: Record<string, number>; chart_layout?: string; chart_location?: string; charts_off?: boolean }
export interface SetView { set: number; name?: string; in_all?: boolean }
export interface Visibility { engines?: string[]; tags?: string[]; include?: string[]; exclude?: string[] }
// matches: whether an instance meets a report's visibility rules (the server's visibleOn, internal/web/q_customreports_view.go)
export function matches(v: Visibility | undefined, i: { name: string; engine: string; tags: string[] }): boolean {
  if (!v) return true;
  if (v.include?.includes(i.name)) return true;
  if (v.exclude?.includes(i.name)) return false;
  if (v.engines?.length && !v.engines.includes(i.engine)) return false;
  if (v.tags?.length && !i.tags.some(t => v.tags!.includes(t))) return false;
  return true;
}
export interface ResultSet { columns: string[]; types: string[]; rows: unknown[][]; truncated?: boolean }
export interface InstanceRun { instance_id?: number; instance: string; engine: string; outcome: string; error?: string; duration_ms: number; rows: number; sets: ResultSet[]; declined?: boolean; messages?: string[] }
// store: why a report on the store cannot run here (REPORT ROLE: reports_dsn, a login IN ROLE pgvigil_reader alone),
// absent when it can
// can: what the session's role may do (B24f): a run is open to every role, a save, move or delete needs admin
interface State { enabled: boolean; reason?: string; store?: string; store_text?: string; can?: Can | null }

const engineName: Record<string, string> = { store: 'the repository', postgres: 'PostgreSQL instances', sqlserver: 'SQL Server instances' };
export const condNames: Record<string, string> = {
  eq: 'equals', ne: 'does not equal', gt: 'greater than', gte: 'at least', lt: 'less than', lte: 'at most', between: 'between',
  contains: 'contains', not_contains: 'does not contain', begins: 'begins with', ends: 'ends with', isnull: 'is empty', notnull: 'is not empty', all: 'always',
};
const formatNames: Record<string, string> = {
  '': 'as returned', text: 'text', number: 'number', int: 'whole number', bytes: 'bytes', kb: 'kilobytes', mb: 'megabytes',
  secs: 'seconds as a duration', ms: 'milliseconds as a duration', pct: 'percent', time: 'date and time', date: 'date',
};
const typeNames: Record<string, string> = { text: 'text', int: 'whole number', number: 'number', bool: 'true / false', timestamp: 'date and time', date: 'date' };
const statusNames: Record<string, string> = { ok: 'OK (green)', warn: 'Warning (amber)', crit: 'Critical (red)' };

// ---- the colour rules and the formats -------------------------------------------------------------------------------

const asNum = (v: unknown): number | null => {
  if (typeof v === 'number') return isFinite(v) ? v : null;
  if (typeof v !== 'string' || v.trim() === '') return null;
  const n = Number(v.trim());
  return isFinite(n) ? n : null;
};
// a date or a time as one clock: a value without a zone (a rule's 2026-11-11, a SQL Server datetime's
// 2026-11-11 00:00:00) is read on the browser's clock for both sides alike; one with a zone (Z, +01:00) is its instant
const asTime = (v: unknown): number | null => {
  if (typeof v !== 'string' || !/^\d{4}-\d\d-\d\d/.test(v.trim())) return null;
  const s = v.trim().replace(' ', 'T');
  const t = Date.parse(/^\d{4}-\d\d-\d\d$/.test(s) ? s + 'T00:00:00' : s);
  return isNaN(t) ? null : t;
};

// ruleMatch is DBA Dash's CellHighlightingRule condition: a number compares as a number when the value and the rule's
// value both read as one, a date as a date, anything else as text (case-blind unless the rule says otherwise).
export function ruleMatch(r: Rule, v: unknown): boolean {
  if (r.cond === 'all') return true;
  if (r.cond === 'isnull') return v == null || v === '';
  if (r.cond === 'notnull') return !(v == null || v === '');
  if (v == null) return false;
  const text = typeof v === 'object' ? JSON.stringify(v) : String(v);
  const a = r.value1 ?? '', b = r.value2 ?? '';
  const fold = (s: string) => r.case_sensitive ? s : s.toLowerCase();
  switch (r.cond) {
    case 'contains': return fold(text).includes(fold(a));
    case 'not_contains': return !fold(text).includes(fold(a));
    case 'begins': return fold(text).startsWith(fold(a));
    case 'ends': return fold(text).endsWith(fold(a));
  }
  let x: number | null = asNum(v), p: number | null = asNum(a), q: number | null = asNum(b);
  if (x == null || p == null || (r.cond === 'between' && q == null)) { x = asTime(v); p = asTime(a); q = asTime(b); }
  if (x != null && p != null && (r.cond !== 'between' || q != null)) {
    switch (r.cond) {
      case 'eq': return x === p;
      case 'ne': return x !== p;
      case 'gt': return x > p;
      case 'gte': return x >= p;
      case 'lt': return x < p;
      case 'lte': return x <= p;
      case 'between': return x >= Math.min(p, q as number) && x <= Math.max(p, q as number);
    }
  }
  const c = fold(text).localeCompare(fold(a));
  switch (r.cond) {
    case 'eq': return c === 0;
    case 'ne': return c !== 0;
    case 'gt': return c > 0;
    case 'gte': return c >= 0;
    case 'lt': return c < 0;
    case 'lte': return c <= 0;
    case 'between': return c >= 0 && fold(text).localeCompare(fold(b)) <= 0;
  }
  return false;
}

// cellStatus: the first rule of the set and column that matches colours the cell (DBA Dash's rule set order). own is
// the cell's column index: a rule judges the cell's own value unless it names another column (the first of that name),
// so of two columns with one name each is judged on its own value
export function cellStatus(rules: Rule[], set: number, own: number, row: Record<string, unknown>, names: string[]): string {
  const col = names[own] ?? '';
  for (const r of rules) {
    if (r.set !== set || r.column.toLowerCase() !== col.toLowerCase()) continue;
    const judged = r.eval ? names.findIndex(n => n.toLowerCase() === r.eval!.toLowerCase()) : own;
    if (judged < 0) continue;
    if (ruleMatch(r, row['c' + judged])) return r.status;
  }
  return '';
}

// asUTC: a time as stored, in UTC (a column whose Convert to local time zone is off)
const asUTC = (v: unknown): string => { const d = new Date(String(v)); return isNaN(d.getTime()) ? String(v) : d.toISOString().replace('T', ' ').slice(0, 19) + ' UTC'; };
function fmtCell(v: unknown, type: string, f?: ColFmt): string {
  if (v == null) return '';
  if (f?.utc && (f.format === 'time' || (!f.format && type === 'time')) && typeof v === 'string' && /T/.test(v)) return asUTC(v);
  const fmtKind = f?.format ?? '';
  const d = f?.decimals;
  const n = asNum(v);
  const fixed = (x: number) => d == null ? fmtNum(x) : x.toLocaleString(undefined, { minimumFractionDigits: d, maximumFractionDigits: d });
  switch (fmtKind) {
    case 'text': return typeof v === 'object' ? JSON.stringify(v) : String(v);
    case 'number': return n == null ? String(v) : fixed(n);
    case 'int': return n == null ? String(v) : Math.round(n).toLocaleString();
    case 'bytes': return n == null ? String(v) : fmtBytes(n);
    case 'kb': return n == null ? String(v) : fmtBytes(n * 1024);
    case 'mb': return n == null ? String(v) : fmtBytes(n * 1024 * 1024);
    case 'secs': return n == null ? String(v) : fmtSecs(n);
    case 'ms': return n == null ? String(v) : Math.abs(n) < 1000 ? `${fixed(n)} ms` : fmtSecs(n / 1000);
    case 'pct': return n == null ? String(v) : `${fixed(n)} %`;
    case 'time': return typeof v === 'string' && /T/.test(v) ? fmtTime(v) : String(v);
    case 'date': return typeof v === 'string' ? v.slice(0, 10) : String(v);
  }
  if (type === 'number' && n != null) return fixed(n);
  if (type === 'time') return fmtTime(v);
  if (Array.isArray(v)) return v.map(x => x == null ? '' : typeof x === 'object' ? JSON.stringify(x) : String(x)).join(', ');
  if (typeof v === 'object') return JSON.stringify(v);
  // SQL Server's binary (0x and its hex, internal/mssqlread Cell): past 32 bytes cut, its length said (parity set 3, L205)
  if (typeof v === 'string' && v.length > 66 && /^0x[0-9A-F]+$/.test(v)) return `${v.slice(0, 66)}... (${fmtNum((v.length - 2) / 2)} bytes)`;
  return String(v);
}
const numericFormat = new Set(['number', 'int', 'bytes', 'kb', 'mb', 'secs', 'ms', 'pct']);

// linkCell: a cell with its column's link (L125-L128): a URL only when the value is an http(s) address (any other value
// is no link), a text in the code viewer, a drill-down (a new tab, this one, or a panel under the report), the row's
// instance at a tab of the tree
const textLangs: Record<string, string> = { '': 'none', sql: 'SQL', json: 'JSON', markdown: 'Markdown', xml: 'XML' };
function linkCell(l: Link, shown: string, at: (col: string) => unknown, ctx: LinkCtx): string | Node {
  const val = (c?: string) => { const v = at(c || l.column); return v == null ? '' : typeof v === 'object' ? JSON.stringify(v) : String(v); };
  switch (l.kind) {
    case 'url': {
      const u = val(l.target_column).trim();
      let ok = false;
      try { ok = /^https?:\/\//i.test(u) && !!new URL(u).host; } catch { ok = false; }
      return ok ? el('a', { href: u, target: '_blank', rel: 'noopener noreferrer' }, shown || u) : shown;
    }
    case 'text': {
      const t = val(l.target_column);
      if (!t) return shown;
      let pretty = t;
      if (l.syntax === 'json') { try { pretty = JSON.stringify(JSON.parse(t), null, 2); } catch { pretty = t; } }
      const b = el('button', { type: 'button', class: 'link sqlcell', 'data-full': t, title: `Show the whole ${textLangs[l.syntax ?? ''] === 'none' ? 'text' : textLangs[l.syntax ?? '']}` }, firstChars(shown || t, 80));
      b.addEventListener('click', ev => { ev.stopPropagation(); openViewer(l.target_column || l.column, pretty, true, l.syntax ?? ''); });
      return b;
    }
    case 'drill': {
      const from = Object.fromEntries(Object.entries(l.map ?? {}).map(([p, c]) => [p, val(c)]));
      const a = el('a', { href: ctx.drillHref(l, from) }, shown || '(open)');
      if ((l.open ?? 'new') === 'new') { a.target = '_blank'; a.rel = 'noopener'; }
      // a panel under the report; Ctrl+click (or the middle button) opens the address in a new tab as any link
      if (l.open === 'panel') a.addEventListener('click', ev => { if (ev.ctrlKey || ev.metaKey || ev.shiftKey) return; ev.preventDefault(); ctx.panel(l, from); });
      return a;
    }
    case 'tree': {
      const iid = Number(val(l.instance_column));
      if (!Number.isInteger(iid) || iid <= 0) return shown;
      const db = l.database_column ? val(l.database_column) : '';
      return el('a', { href: `#/${l.tab ?? 'summary'}?i=${iid}${db ? '&db=' + encodeURIComponent(db) : ''}${ctx.range()}` }, shown || String(iid));
    }
  }
  return shown;
}

// setGrid draws one result set with the report's formats and colour rules (and, on the report's own page, its links)
export function setGrid(set: ResultSet, idx: number, cols: ColFmt[] = [], rules: Rule[] = [], links?: LinkCtx): HTMLElement {
  const rows = set.rows.map(r => Object.fromEntries(r.map((v, i) => ['c' + i, v])));
  const gcols: Col[] = [];
  const colOf = (n: string) => set.columns.findIndex(c => c.toLowerCase() === n.toLowerCase());
  set.columns.forEach((name, i) => {
    const f = cols.find(c => c.set === idx && c.column.toLowerCase() === name.toLowerCase());
    if (f?.hidden) return;
    const type = set.types[i] ?? 'text';
    const hasRule = rules.some(r => r.set === idx && r.column.toLowerCase() === name.toLowerCase());
    gcols.push({
      key: 'c' + i, label: f?.label || name || `(column ${i + 1})`, title: f?.tooltip || undefined,
      num: f?.format ? numericFormat.has(f.format) : type === 'number',
      wide: type === 'text' && !f?.format,
      fmt: (v, row) => {
        const shown = fmtCell(v, type, f), l = links?.links.find(x => (x.set ?? 0) === idx && x.column.toLowerCase() === name.toLowerCase());
        return l && links ? linkCell(l, shown, c => { const k = colOf(c); return k < 0 ? undefined : row['c' + k]; }, links) : shown;
      },
      cls: hasRule ? (_v, row) => cellStatus(rules, idx, i, row, set.columns) : undefined,
    });
  });
  return grid(rows, gcols, 'The result set has no rows.');
}

// resultView draws a run's answer: per instance its outcome, its error, and each result set as a grid
export function resultView(runs: InstanceRun[], def?: Pick<ReportDef, 'columns' | 'rules'>, title = 'Result'): HTMLElement {
  const box = el('section', { class: 'report-result' });
  for (const run of runs) {
    const many = runs.length > 1 || run.instance !== 'store';
    const head = el('h3', {}, many ? `${title}: ${run.instance}` : title);
    // declined: a community procedure looked at this server and said no in its own words (stored failed: it ran)
    const plain = run.outcome === 'refused' || !!run.declined;
    const kind = run.outcome === 'done' ? 'ok' : plain ? 'warn' : 'crit';
    box.append(head, el('p', { class: 'meta' }, badge(run.declined ? 'declined' : run.outcome, kind),
      ` ${fmtNum(run.rows)} rows in ${fmtNum(run.duration_ms)} ms${run.sets.length > 1 ? `, ${run.sets.length} result sets` : ''}`));
    // refused = pgvigil sent nothing (a login, a right, a setting it knows); declined = the procedure's own no: their
    // words as a plain note; failed = the call broke: an error box
    if (run.error) box.append(plain ? el('p', { class: 'meta refused', role: 'note' }, run.error) : errorBox(run.error));
    run.sets.forEach((s, i) => {
      if (run.sets.length > 1) box.append(el('h3', {}, `${many ? run.instance + ': ' : ''}result set ${i + 1}`));
      if (s.truncated) box.append(el('p', { class: 'meta' }, `Cut at ${fmtNum(s.rows.length)} rows (the report's row cap, or the run's 24 MB).`));
      box.append(setGrid(s, i, def?.columns, def?.rules));
    });
    if (!run.sets.length && run.outcome === 'done') box.append(el('p', { class: 'empty' }, 'The run returned no result set.'));
  }
  return box;
}

// ---- reading the definitions ------------------------------------------------------------------------------------

// viewOf: 0372's view column as the definition's own keys (an empty view, '{}': none of them - the report as before)
type ViewKeys = Pick<ReportDef, 'visibility' | 'access' | 'status_from_messages' | 'collections' | 'sets' | 'pair' | 'url' | 'url_label' | 'layout' | 'links' | 'charts' | 'system_charts'>;
function viewOf(v: unknown): ViewKeys {
  const o = v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : {};
  const out: ViewKeys = {};
  if (o.visibility && typeof o.visibility === 'object') out.visibility = o.visibility as Visibility;
  if (Array.isArray(o.access) && o.access.length) out.access = o.access.map(String);
  if (o.status_from_messages === true) out.status_from_messages = true;
  if (Array.isArray(o.collections) && o.collections.length) out.collections = o.collections.map(String);
  if (Array.isArray(o.sets) && o.sets.length) out.sets = (o.sets as SetView[]).filter(x => x && Number.isInteger(x.set));
  const pr = o.pair as { report_id?: unknown; label?: unknown } | undefined;
  if (pr && typeof pr === 'object' && Number(pr.report_id) > 0) out.pair = { report_id: Number(pr.report_id), label: String(pr.label ?? '') };
  if (typeof o.url === 'string' && o.url) { out.url = o.url; if (typeof o.url_label === 'string' && o.url_label) out.url_label = o.url_label; }
  if (o.layout && typeof o.layout === 'object' && !Array.isArray(o.layout)) out.layout = o.layout as SavedLayout;
  if (Array.isArray(o.links) && o.links.length) out.links = (o.links as Link[]).filter(x => x && typeof x.column === 'string');
  if (Array.isArray(o.charts) && o.charts.length) out.charts = (o.charts as ChartDef[]).filter(x => x && CHART_TYPES.includes(x.type) && Array.isArray(x.metrics));
  if (Array.isArray(o.system_charts) && o.system_charts.length) out.system_charts = o.system_charts.map(String);
  return out;
}

// saveDef writes a report's whole definition back (a change made on its own page: a result set's name, its layout);
// the definition's version moves on, so the next save from this page is not refused as another user's
async function saveDef(def: ReportDef): Promise<void> {
  const r = await post<{ version?: number }>('customreports', { ...def, op: 'edit' });
  if (typeof r.version === 'number') def.version = r.version;
}

// askText: one line of text in a dialog (Rename and the column items of the result sets); null = cancelled
export function askText(heading: string, label: string, value: string): Promise<string | null> {
  return new Promise(done => {
    const back = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const input = el('input', { type: 'text', 'aria-label': label, value, size: '40' }) as HTMLInputElement;
    const ok = el('button', { type: 'submit' }, 'OK'), cancel = el('button', { type: 'button' }, 'Cancel');
    const form = el('form', { method: 'dialog' }, el('h3', {}, heading), el('p', {}, el('label', {}, label + ' ', input)), el('div', { class: 'toolbar' }, ok, cancel));
    const dlg = el('dialog', { class: 'cr-ask', 'aria-label': heading }, form) as HTMLDialogElement;
    let out: string | null = null;
    form.addEventListener('submit', e => { e.preventDefault(); out = input.value; dlg.close(); });
    cancel.addEventListener('click', () => dlg.close());
    dlg.addEventListener('close', () => { dlg.remove(); if (back?.isConnected) back.focus(); done(out); });
    document.body.append(dlg);
    dlg.showModal();
    input.select();
  });
}

// highlightDialog: Highlight Cell Value (DBA Dash L123) - the colour rule dialog prefilled with the column and the
// value clicked; null = cancelled
function highlightDialog(column: string, value: string): Promise<{ cond: string; value: string; status: string } | null> {
  return new Promise(done => {
    const back = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const col = el('input', { type: 'text', 'aria-label': 'Column', value: column, readonly: '' }) as HTMLInputElement;
    const cond = sel('Condition', condNames, 'eq');
    const val = el('input', { type: 'text', 'aria-label': 'Value', value, size: '30' }) as HTMLInputElement;
    const st = sel('Status', statusNames, 'warn');
    const form = el('form', { method: 'dialog' }, el('h3', {}, 'Highlight Cell Value'),
      el('p', { class: 'meta' }, 'A colour rule for the column: the first rule that matches colours the cell (saved with the report).'),
      el('div', { class: 'toolbar' }, el('label', {}, 'Column ', col), el('label', {}, 'when ', cond), el('label', {}, 'Value ', val), el('label', {}, 'Status ', st)),
      el('div', { class: 'toolbar' }, el('button', { type: 'submit' }, 'Save'), el('button', { type: 'button', class: 'cr-cancel' }, 'Cancel')));
    const dlg = el('dialog', { class: 'cr-ask', 'aria-label': 'Highlight Cell Value' }, form) as HTMLDialogElement;
    let out: { cond: string; value: string; status: string } | null = null;
    form.addEventListener('submit', e => { e.preventDefault(); out = { cond: cond.value, value: val.value, status: st.value }; dlg.close(); });
    form.querySelector('.cr-cancel')!.addEventListener('click', () => dlg.close());
    dlg.addEventListener('close', () => { dlg.remove(); if (back?.isConnected) back.focus(); done(out); });
    document.body.append(dlg);
    dlg.showModal();
    val.select();
  });
}

// linkDialog: Add Link (DBA Dash L120) - None, URL (with its trust words), Text (its syntax), Drill Down (the report,
// where it opens, each of its parameters from a column of this row), Navigate Tree (the instance and database columns,
// the tab); the target column a URL or a text takes its value from. 'none' = the link removed, null = cancelled
const linkKinds: Record<string, string> = { '': 'None', url: 'URL', text: 'Text', drill: 'Drill Down', tree: 'Navigate Tree' };
const openKinds: Record<string, string> = { new: 'a new tab', same: 'this tab (Back returns)', panel: 'a panel under the report' };
function linkDialog(columns: string[], column: string, set: number, cur?: Link): Promise<Link | 'none' | null> {
  return new Promise(done => {
    const back = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const colOpts = (none = false) => Object.fromEntries([...(none ? [['', '(none)']] : []), ...columns.map(c => [c, c])]);
    const kind = sel('Link type', linkKinds, cur?.kind ?? '');
    const tcol = sel('Target column', colOpts(), cur?.target_column || column);
    const trust = el('p', { class: 'meta warn' }, 'Open only links you trust: the address comes from the report\'s data, and a click opens it in a new tab. A value that is no http or https address is no link.');
    const syntax = sel('Syntax', textLangs, cur?.syntax ?? '');
    const report = el('select', { 'aria-label': 'Report' }) as HTMLSelectElement;
    const open = sel('Open in', openKinds, cur?.open ?? 'new');
    const maps = el('div', { class: 'toolbar' });
    const icol = sel('Instance column', colOpts(), cur?.instance_column ?? columns.find(c => /instance_?id/i.test(c)) ?? columns[0]);
    const dcol = sel('Database column', colOpts(true), cur?.database_column ?? '');
    const tabs = sel('Tab', Object.fromEntries([...Object.entries(instanceTabs), ...Object.entries(mssqlInstanceTabs)].map(([k, v]) => [k, `${v} (${k})`])), cur?.tab ?? 'activity');
    const parts: Record<string, HTMLElement> = {
      url: el('div', {}, el('div', { class: 'toolbar' }, el('label', {}, 'Target column ', tcol)), trust),
      text: el('div', { class: 'toolbar' }, el('label', {}, 'Syntax ', syntax)),
      drill: el('div', {}, el('div', { class: 'toolbar' }, el('label', {}, 'Report ', report), el('label', {}, 'Open in ', open)), maps),
      tree: el('div', { class: 'toolbar' }, el('label', {}, 'Instance column ', icol), el('label', {}, 'Database column ', dcol), el('label', {}, 'Tab ', tabs)),
    };
    // the target column serves a URL and a text: one control, shown with either
    const show = () => {
      for (const [k, e] of Object.entries(parts)) e.hidden = k !== kind.value && !(k === 'url' && kind.value === 'text');
      trust.hidden = kind.value !== 'url';
    };
    // the drill-down's parameters: the chosen report's, each from a column (the one of its name when there is one)
    const mapSels = new Map<string, HTMLSelectElement>();
    const loadParams = async () => {
      maps.replaceChildren(); mapSels.clear();
      if (!report.value) return;
      try {
        const got = rowsOf((await get<{ report: Table | null }>('customreports', { report: Number(report.value) })).report);
        const ps = got.length ? defOf(got[0]).params : [];
        if (!ps.length) { maps.append(el('p', { class: 'meta' }, 'The report takes no parameter.')); return; }
        for (const p of ps) {
          const now = cur?.report_id === Number(report.value) ? cur.map?.[p.name] : columns.find(c => c.toLowerCase() === p.name.toLowerCase());
          const x = sel(`Parameter ${p.name} from`, colOpts(true), now ?? '');
          mapSels.set(p.name, x);
          maps.append(el('label', {}, `${p.label || p.name} from `, x));
        }
      } catch (e) { maps.append(errorBox(e)); }
    };
    void get<{ reports: Table | null }>('customreports').then(l => {
      for (const r of rowsOf(l.reports)) report.append(el('option', { value: String(r.report_id) }, String(r.name)));
      if (cur?.report_id) report.value = String(cur.report_id);
      return loadParams();
    }).catch(e => { maps.append(errorBox(e)); });
    report.addEventListener('change', () => { void loadParams(); });
    kind.addEventListener('change', show);
    const form = el('form', { method: 'dialog' }, el('h3', {}, `Add Link: ${column}`),
      el('div', { class: 'toolbar' }, el('label', {}, 'Link type ', kind)), ...Object.values(parts),
      el('div', { class: 'toolbar' }, el('button', { type: 'submit' }, 'Save'), el('button', { type: 'button', class: 'cr-cancel' }, 'Cancel')));
    show();
    const dlg = el('dialog', { class: 'cr-ask', 'aria-label': `Add Link: ${column}` }, form) as HTMLDialogElement;
    let out: Link | 'none' | null = null;
    form.addEventListener('submit', e => {
      e.preventDefault();
      const base = { set: set || undefined, column };
      switch (kind.value) {
        case 'url': out = { ...base, kind: 'url', target_column: tcol.value !== column ? tcol.value : undefined }; break;
        case 'text': out = { ...base, kind: 'text', target_column: tcol.value !== column ? tcol.value : undefined, syntax: syntax.value || undefined }; break;
        case 'drill': out = { ...base, kind: 'drill', report_id: Number(report.value), open: open.value as Link['open'],
          map: Object.fromEntries([...mapSels].filter(([, x]) => x.value).map(([p, x]) => [p, x.value])) }; break;
        case 'tree': out = { ...base, kind: 'tree', instance_column: icol.value, database_column: dcol.value || undefined, tab: tabs.value }; break;
        default: out = 'none';
      }
      if (out !== 'none' && out.kind === 'drill' && !out.report_id) { out = null; return; }
      dlg.close();
    });
    form.querySelector('.cr-cancel')!.addEventListener('click', () => dlg.close());
    dlg.addEventListener('close', () => { dlg.remove(); if (back?.isConnected) back.focus(); done(out); });
    document.body.append(dlg);
    dlg.showModal();
    kind.focus();
  });
}

// chartDialog: Add Chart / Configure (DBA Dash L130, L133, L135) - the type, the result set, the X column, the metric
// columns, the column that splits them into series, the title, the X bound to the page's time window, an overlay (another
// set's metric as a line), the parameter that hides the chart while it holds a value; null = cancelled
export function chartDialog(columns: string[], params: string[], cur?: ChartDef): Promise<ChartDef | null> {
  return new Promise(done => {
    const back = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    const list = el('datalist', { id: 'cr-chart-cols' }, ...columns.map(c => el('option', { value: c })));
    const text = (label: string, v = '', size = '18') => el('input', { type: 'text', 'aria-label': label, value: v, size, list: 'cr-chart-cols' }) as HTMLInputElement;
    const type = sel('Chart type', Object.fromEntries(CHART_TYPES.map(t => [t, chartTypeNames[t]])), cur?.type ?? 'Line');
    const set = el('input', { type: 'text', 'aria-label': 'Result set (1 = the first)', value: String((cur?.set ?? 0) + 1), size: '3', inputmode: 'numeric' }) as HTMLInputElement;
    const x = text('X column', cur?.x ?? columns[0] ?? ''), metrics = text('Metric columns (comma-separated)', (cur?.metrics ?? []).join(', '), '30');
    const series = text('Series column (empty = one series per metric)', cur?.series ?? ''), title = text('Title (empty = the metrics by X)', cur?.title ?? '', '30');
    const xr = check('Bind the X axis to the time range', cur?.x_range);
    const oSet = el('input', { type: 'text', 'aria-label': 'Overlay result set (empty = none)', value: cur?.overlay ? String(cur.overlay.set + 1) : '', size: '3' }) as HTMLInputElement;
    const oMetric = text('Overlay metric column', cur?.overlay?.metric ?? '');
    const hide = sel('Hidden while this parameter holds a value', Object.fromEntries([['', '(never hidden)'], ...params.map(p => [p, p])]), cur?.hidden_when ?? '');
    const said = el('p', { class: 'meta', role: 'alert' });
    const form = el('form', { method: 'dialog' }, el('h3', {}, cur ? 'Configure the chart' : 'Add Chart'), list,
      el('div', { class: 'toolbar' }, el('label', {}, 'Chart type ', type), el('label', {}, 'Result set ', set), el('label', {}, 'X ', x)),
      el('div', { class: 'toolbar' }, el('label', {}, 'Metrics ', metrics), el('label', {}, 'Series ', series)),
      el('div', { class: 'toolbar' }, el('label', {}, 'Title ', title), el('label', {}, xr, ' X bound to the time range')),
      el('div', { class: 'toolbar' }, el('label', {}, 'Overlay: result set ', oSet), el('label', {}, 'metric ', oMetric)),
      el('div', { class: 'toolbar' }, el('label', {}, 'Hidden while ', hide)), said,
      el('div', { class: 'toolbar' }, el('button', { type: 'submit' }, 'Save'), el('button', { type: 'button', class: 'cr-cancel' }, 'Cancel')));
    const dlg = el('dialog', { class: 'cr-ask', 'aria-label': cur ? 'Configure the chart' : 'Add Chart' }, form) as HTMLDialogElement;
    let out: ChartDef | null = null;
    form.addEventListener('submit', e => {
      e.preventDefault();
      const ms = metrics.value.split(',').map(m => m.trim()).filter(Boolean), n = Number(set.value || 1) - 1, on = Number(oSet.value) - 1;
      if (!x.value.trim() || !ms.length || !Number.isInteger(n) || n < 0) { said.textContent = 'A chart needs its X column, a metric and its result set (1 or more).'; return; }
      out = { type: type.value as ChartType, set: n, x: x.value.trim(), metrics: ms, series: series.value.trim() || undefined, title: title.value.trim() || undefined,
        x_range: xr.checked || undefined, overlay: oSet.value.trim() && Number.isInteger(on) && on >= 0 && oMetric.value.trim() ? { set: on, metric: oMetric.value.trim() } : undefined,
        hidden_when: hide.value || undefined };
      dlg.close();
    });
    form.querySelector('.cr-cancel')!.addEventListener('click', () => dlg.close());
    dlg.addEventListener('close', () => { dlg.remove(); if (back?.isConnected) back.focus(); done(out); });
    document.body.append(dlg);
    dlg.showModal();
    type.focus();
  });
}

// confirmDialog: a yes / no in words (Delete All Charts); true = the action confirmed
function confirmDialog(words: string, yes: string): Promise<boolean> {
  return new Promise(done => {
    const back = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    let ok = false;
    const y = el('button', { type: 'button' }, yes), n = el('button', { type: 'button' }, 'Cancel');
    const dlg = el('dialog', { class: 'cr-ask', 'aria-label': yes }, el('p', {}, words), el('div', { class: 'toolbar' }, y, n)) as HTMLDialogElement;
    y.addEventListener('click', () => { ok = true; dlg.close(); });
    n.addEventListener('click', () => dlg.close());
    dlg.addEventListener('close', () => { dlg.remove(); if (back?.isConnected) back.focus(); done(ok); });
    document.body.append(dlg);
    dlg.showModal();
    n.focus();
  });
}

// scriptOf: Script Report (DBA Dash L111) - the report's SQL, then its whole definition as POST /api/customreports
// takes it ('op': 'add' makes it again); its visibility rules name this server's own instances and are left out, as DBA
// Dash's script leaves the tag and instance visibility out
export function scriptOf(d: ReportDef): string {
  const { report_id: _id, version: _v, visibility: _vis, ...rest } = d;
  return `-- Script Report: ${d.name}\n-- its ${d.kind === 'procedure' ? 'procedure' : 'SQL'}, then its definition as POST /api/customreports takes it ('op': 'add' makes it again;\n`
    + `-- the visibility rules name this server's own instances and are left out)\n\n${d.kind === 'procedure' ? 'procedure ' + d.body : d.body}\n\n`
    + JSON.stringify({ op: 'add', ...rest }, null, 2) + '\n';
}
function defOf(r: Row): ReportDef {
  const arr = <T>(v: unknown): T[] => Array.isArray(v) ? v as T[] : [];
  return {
    report_id: Number(r.report_id), name: String(r.name ?? ''), description: r.description == null ? '' : String(r.description),
    folder: String(r.folder ?? ''), engine: String(r.engine), kind: String(r.kind), body: String(r.body ?? ''),
    params: arr<Param>(r.params), columns: arr<ColFmt>(r.columns), rules: arr<Rule>(r.rules),
    timeout_secs: Number(r.timeout_secs ?? 30), max_rows: Number(r.max_rows ?? 5000), version: Number(r.version ?? 1),
    ...viewOf(r.view),
  };
}

function hashParams(): URLSearchParams { return new URLSearchParams(location.hash.split('?')[1] ?? ''); }
function go(q: Record<string, string>) {
  const keep = hashParams(), out = new URLSearchParams();
  for (const k of ['i', 'w', 'from', 'to', 'tag']) { const v = keep.get(k); if (v) out.set(k, v); }
  for (const [k, v] of Object.entries(q)) out.set(k, v);
  location.hash = '#/customreports' + (out.toString() ? '?' + out : '');
}

// tagQ: the tag folder a fleet page was opened under, kept on the page's own links (TAGALL); '' at the root and on an
// instance's page
const tagQ = (ctx: Ctx) => ctx.tag && !ctx.instance ? 'tag=' + encodeURIComponent(ctx.tag) : '';

interface Inst { id: number; name: string; engine: string; tags: string[] }
async function instances(): Promise<Inst[]> {
  const t = await get<Table>('instances');
  return rowsOf(t).map(r => ({ id: Number(r.instance_id), name: String(r.name), engine: String(r.engine ?? 'postgres'), tags: Array.isArray(r.tags) ? (r.tags as unknown[]).map(String) : [] }));
}

// logOutcome: a log row's outcome; a community run the procedure declined in its own words is stored failed (it reached
// the server) and shown as declined, a note, on every log that lists it
export function logOutcome(v: unknown, r: Row): HTMLElement {
  const o = String(v ?? ''), dec = o === 'failed' && / declined: /.test(String(r.detail ?? ''));
  return badge(dec ? 'declined' : o, o === 'done' ? 'ok' : o === 'refused' || dec ? 'warn' : 'crit');
}

const logCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'ui_user', label: 'who' },
  { key: 'op', label: 'what' },
  { key: 'report_name', label: 'report' },
  { key: 'instance', label: 'ran on' },
  { key: 'outcome', fmt: logOutcome },
  { key: 'rows', num: true },
  { key: 'duration_ms', label: 'took (ms)', num: true },
  { key: 'detail', wide: true },
  { key: 'client' },
];

// ---- the page ---------------------------------------------------------------------------------------------------

export async function customReportsView(ctx: Ctx): Promise<HTMLElement> {
  const q = hashParams();
  if (q.get('report')) return reportPage(ctx, Number(q.get('report')), q);
  if (q.get('edit')) return editorPage(ctx, Number(q.get('edit')));
  if (q.get('new')) return editorPage(ctx, 0, q.get('folder') ?? '');
  return treePage(ctx);
}

function folderTree(folders: string[]): string[] {
  const all = new Set<string>();
  for (const f of folders) { const p = f.split('/'); for (let i = 1; i <= p.length; i++) all.add(p.slice(0, i).join('/')); }
  return [...all].sort((a, b) => a.localeCompare(b));
}

async function treePage(ctx: Ctx): Promise<HTMLElement> {
  // 0372: the list as this scope sees it (an instance's or a tag folder's: the reports' visibility rules)
  const d = await get<{ state: State; folders: Table | null; reports: Table | null; log: Table | null }>('customreports', { i: ctx.instance, tag: tagQ(ctx) ? ctx.tag : undefined });
  const reports = rowsOf(d.reports).map(defOf);
  const folders = folderTree(rowsOf(d.folders).map(r => String(r.folder)));
  const sec = el('section', {}, el('h2', {}, 'Custom reports' + (tagQ(ctx) ? ` - ${tagWords(ctx.tag!)}` : '')));
  const msg = el('p', { class: 'meta', role: 'status' });
  const newBtn = markNeed(el('button', { type: 'button' }, 'New report'), 'customreports'), folderBtn = markNeed(el('button', { type: 'button' }, 'New folder'), 'customreports');
  // off: every writing control says why beside it (one line under the toolbar, their description) - the server's own
  // reason first, then the role (B24f: a report is a shared view written against servers; changing one needs admin)
  const off = d.state.enabled ? (routeWhy('customreports', d.state.can) ?? '') : (d.state.reason || 'Saving or running a report is off on this server.');
  const offNote = el('p', { class: 'meta off-reason' }, off);
  // TEXT-NOW (decision T3): a store report reads stored statement text as stored, whatever an instance's policy is now
  const storeText = d.state.store_text ? el('p', { class: 'meta said' }, d.state.store_text) : null;
  if (off) for (const b of [newBtn, folderBtn]) offControl(b, off, offNote);
  newBtn.addEventListener('click', () => go({ new: '1' }));
  const folderIn = el('input', { type: 'text', 'aria-label': 'New folder path (parts joined by /)', placeholder: 'Ops/Daily' }) as HTMLInputElement;
  folderBtn.addEventListener('click', async () => {
    try { const r = await post<{ detail: string }>('customreports', { op: 'folder_add', folder: folderIn.value }); msg.textContent = r.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  sec.append(el('div', { class: 'toolbar' }, newBtn, el('span', {}, folderIn, ' ', folderBtn)), msg);
  if (off) sec.append(offNote);
  if (storeText) sec.append(storeText);
  sec.append(el('p', { class: 'meta' }, 'Each report is the DBA\'s own SQL (or a procedure) with its parameters, column formats and colour rules, in folders every user shares. '
    + 'A report on the repository reads pgvigil\'s own tables; a PostgreSQL or SQL Server report runs read-only on a chosen instance or on a tag\'s instances, '
    + 'under its timeout and a 2 s lock timeout, and every run is audited (the log below).'));
  if (ctx.instance) sec.append(el('p', { class: 'meta' }, 'Opened from an instance: a report run from here goes to that instance (a repository report: about it).'));
  // under a tag folder: the reports are the repository's; a run from here goes to the folder's instances (reportPage)
  const wide = fleetWideNote(ctx, 'The reports, their folders and the activity log are one list');
  if (wide) sec.append(wide);

  const byFolder = (f: string) => reports.filter(r => r.folder === f);
  const reportCols: Col[] = [
    { key: 'name', label: 'report', fmt: (v, r) => el('a', { href: `#/customreports?report=${String(r.report_id)}${ctx.instance ? '&i=' + ctx.instance : ''}${tagQ(ctx) ? '&' + tagQ(ctx) : ''}` }, String(v)) },
    { key: 'engine', label: 'runs on', fmt: v => engineName[String(v)] ?? String(v) },
    { key: 'kind', fmt: v => v === 'procedure' ? 'procedure' : 'SQL' },
    { key: 'description', wide: true },
    { key: 'updated_by', label: 'changed by' },
    { key: 'updated_at', label: 'changed', fmt: fmtTime },
    { key: 'actions', label: 'actions', fmt: (_v, r) => reportActions(r as unknown as ReportDef, folders, msg, off, offNote) },
  ];
  const tops = byFolder('');
  sec.append(el('h3', {}, 'Top level'), grid(tops as unknown as Row[], reportCols, 'No report at the top level.'));
  for (const f of folders) {
    const depth = f.split('/').length - 1;
    const h = el('h3', { style: `margin-left:${depth * 1.2}rem` }, 'Folder ' + f);
    sec.append(h, folderActions(f, msg, off, offNote),
      grid(byFolder(f) as unknown as Row[], reportCols, 'No report in this folder.'));
  }
  if (!reports.length) sec.append(el('p', { class: 'empty' }, 'No custom report yet: New report saves the first one.'));
  sec.append(el('h3', {}, 'Recent activity'), grid(rowsOf(d.log), logCols, 'Nothing was saved or run yet.'));
  return sec;
}

// reportActions: Open, Edit, Move to folder, Delete (a second click confirms)
function reportActions(r: ReportDef, folders: string[], msg: HTMLElement, off: string, offNote: HTMLElement): HTMLElement {
  const box = el('span', { class: 'row-actions' });
  const id = String(r.report_id);
  const edit = markNeed(el('button', { type: 'button', class: 'link' }, 'Edit'), 'customreports');
  edit.addEventListener('click', () => go({ edit: id }));
  const listId = 'crf-' + id;
  const to = el('input', { type: 'text', list: listId, 'aria-label': `Move ${r.name} to the folder`, placeholder: 'folder (empty = top)', size: '14' }) as HTMLInputElement;
  const dl = el('datalist', { id: listId }, ...folders.map(f => el('option', { value: f })));
  const move = markNeed(el('button', { type: 'button', class: 'link' }, 'Move to folder'), 'customreports');
  move.addEventListener('click', async () => {
    try { const x = await post<{ detail: string }>('customreports', { op: 'move', report_id: r.report_id, folder: to.value }); msg.textContent = x.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  const del = markNeed(el('button', { type: 'button', class: 'link' }, 'Delete'), 'customreports');
  let armed = false;
  del.addEventListener('click', async () => {
    if (!armed) { armed = true; del.textContent = `Delete ${r.name}: click again`; return; }
    try { const x = await post<{ detail: string }>('customreports', { op: 'delete', report_id: r.report_id }); msg.textContent = x.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  if (off) for (const b of [edit, move, del]) offControl(b, off, offNote);
  box.append(edit, ' ', to, dl, ' ', move, ' ', del);
  return box;
}

function folderActions(f: string, msg: HTMLElement, off: string, offNote: HTMLElement): HTMLElement {
  const name = el('input', { type: 'text', value: f, 'aria-label': `New path of the folder ${f}`, size: '18' }) as HTMLInputElement;
  const ren = markNeed(el('button', { type: 'button', class: 'link' }, 'Rename'), 'customreports');
  ren.addEventListener('click', async () => {
    try { const x = await post<{ detail: string }>('customreports', { op: 'folder_rename', folder: f, new_folder: name.value }); msg.textContent = x.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  const del = markNeed(el('button', { type: 'button', class: 'link' }, 'Delete folder'), 'customreports');
  del.addEventListener('click', async () => {
    try { const x = await post<{ detail: string }>('customreports', { op: 'folder_delete', folder: f }); msg.textContent = x.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  const add = markNeed(el('button', { type: 'button', class: 'link' }, 'New report here'), 'customreports');
  add.addEventListener('click', () => go({ new: '1', folder: f }));
  if (off) for (const b of [ren, del, add]) offControl(b, off, offNote);
  // Rename waits for a new path (the same path is no rename), the words beside it
  const renWhy = el('span', { class: 'meta off-reason' });
  const same = () => { if (off) return; const why = name.value.trim() === f ? 'type the new path' : null; renWhy.textContent = why ?? ''; offControl(ren, why, renWhy); };
  name.addEventListener('input', same); same();
  return el('div', { class: 'toolbar' }, el('span', {}, name, ' ', ren, ' ', renWhy), del, add);
}

type Field = HTMLInputElement | HTMLSelectElement;
// paramField is one parameter's field: its picker's (a select of the list's or the query's values, or a text box) or the
// plain typed field; filled from the address (p.<name>) or its default. A query picker's options come later (loadPicker).
function paramField(p: Param, q: URLSearchParams): Field {
  const v = q.get('p.' + p.name) ?? p.default ?? '';
  const label = p.label || p.name;
  if (p.picker?.kind === 'list' || p.picker?.kind === 'query') {
    const s = el('select', { name: p.name, 'aria-label': label }) as HTMLSelectElement;
    for (const x of p.picker.values ?? []) s.append(el('option', { value: x }, x === '' ? '(the default)' : x));
    s.dataset.want = v;
    if (v !== '' && [...s.options].some(o => o.value === v)) s.value = v;
    return s;
  }
  if (p.picker?.kind === 'text') return el('input', { type: 'text', name: p.name, 'aria-label': label, value: v }) as HTMLInputElement;
  return paramInput(p, v);
}

// paramInput is a plain parameter's field (a report before pickers: unchanged)
function paramInput(p: Param, v: string): HTMLInputElement {
  const attrs: Record<string, string> = { name: p.name, 'aria-label': `${p.label || p.name} (${typeNames[p.type] ?? p.type})`, value: v };
  if (p.type === 'int' || p.type === 'number') { attrs.type = 'text'; attrs.inputmode = 'decimal'; }
  else if (p.type === 'date') attrs.type = 'date';
  else attrs.type = 'text';
  if (p.type === 'timestamp') attrs.placeholder = '2026-11-11T08:00:00Z';
  if (p.type === 'bool') attrs.placeholder = 'true or false';
  if (p.required) attrs.required = '';
  return el('input', attrs) as HTMLInputElement;
}

async function reportPage(ctx: Ctx, id: number, q: URLSearchParams): Promise<HTMLElement> {
  const [d, insts] = await Promise.all([
    get<{ state: State; report: Table | null; log: Table | null }>('customreports', { report: id }),
    instances().catch(() => [] as Inst[]),
  ]);
  const rows = rowsOf(d.report);
  if (!rows.length) return el('p', { class: 'empty' }, `No report ${id}.`);
  const def = defOf(rows[0]);
  const sec = el('section', {}, el('h2', {}, def.name));
  const crumbs = el('p', { class: 'meta' }, el('a', { href: '#/customreports' + (ctx.instance ? '?i=' + ctx.instance : tagQ(ctx) ? '?' + tagQ(ctx) : '') }, 'Custom reports'),
    def.folder ? ' / ' + def.folder.split('/').join(' / ') : '', ` - runs on ${engineName[def.engine] ?? def.engine}, version ${def.version}`);
  sec.append(crumbs);
  if (def.description) sec.append(el('p', {}, def.description));
  // the URL label (DBA Dash L107): the report's own link, in a new tab
  if (def.url) sec.append(el('p', {}, el('a', { href: def.url, target: '_blank', rel: 'noopener noreferrer' }, def.url_label || def.url)));

  // the target: the store runs about one instance, a tag's or every active one; an instance report on one instance or a tag's.
  // Under a tag folder (TAGALL) the instance picker lists the folder's instances and the tag picker its tag alone, the
  // target that tag: a run never reaches past the folder unless 'every active instance' is picked. The folders of no tag
  // ('untagged', '<key>:') are no tag a run can name: their target is one of their instances.
  const folderTag = tagQ(ctx) ? ctx.tag : undefined;
  const runTag = writtenTag(folderTag);
  const mine = insts.filter(i => (def.engine === 'store' || i.engine === def.engine) && (!folderTag || inTagScope(folderTag, { tags: i.tags })));
  const tags = folderTag ? (runTag && mine.length ? [runTag] : []) : [...new Set(mine.flatMap(i => i.tags))].sort();
  const target = el('select', { 'aria-label': 'Run on' }) as HTMLSelectElement;
  if (def.engine === 'store') target.append(el('option', { value: 'fleet' }, 'every active instance'));
  target.append(el('option', { value: 'instance' }, 'one instance'));
  if (tags.length) target.append(el('option', { value: 'tag' }, 'the instances of a tag'));
  const instSel = el('select', { 'aria-label': 'Instance' }) as HTMLSelectElement;
  for (const i of mine) instSel.append(el('option', { value: String(i.id) }, i.name));
  const tagSel = el('select', { 'aria-label': 'Tag' }) as HTMLSelectElement;
  for (const t of tags) tagSel.append(el('option', { value: t }, t));
  const want = Number(q.get('i') ?? ctx.instance ?? 0);
  // an address naming an instance that is not active here (disabled in Admin > Instances, or removed) keeps it as the
  // target: its run says why, never another instance's run in its place (a mailed page names its instance)
  const gone = !!want && !insts.some(i => i.id === want);
  if (gone) instSel.append(el('option', { value: String(want) }, `instance ${want} (not active here)`));
  if (want && (gone || mine.some(i => i.id === want))) { instSel.value = String(want); target.value = 'instance'; }
  else if (q.get('tag') && tags.includes(q.get('tag')!)) { tagSel.value = q.get('tag')!; target.value = 'tag'; }
  else if (def.engine !== 'store' || (folderTag && mine.length)) target.value = 'instance';
  const instBox = el('label', {}, 'Instance ', instSel), tagBox = el('label', {}, 'Tag ', tagSel);
  const showTarget = () => { instBox.hidden = target.value !== 'instance'; tagBox.hidden = target.value !== 'tag'; };
  target.addEventListener('change', showTarget); showTarget();

  const inputs = def.params.map(p => paramField(p, q));
  // a picker away from its parameter's default is marked (DBA Dash draws the picker bold), the words in its title
  const labels = def.params.map((p, i) => el('label', {}, `${p.label || p.name} `, inputs[i]));
  const mark = (i: number) => {
    const p = def.params[i], off = !!p.picker && p.default != null && inputs[i].value !== p.default;
    labels[i].classList.toggle('not-default', off);
    if (off) labels[i].title = `${p.label || p.name} is not at its default (${p.default === '' ? 'empty' : p.default})`; else labels[i].removeAttribute('title');
  };
  const runBtn = el('button', { type: 'button' }, 'Run');
  // Cancel (DBA Dash L89): stops the run's request; the server's context ends and the statement with it on either engine
  const cancelBtn = el('button', { type: 'button', disabled: '' }, 'Cancel') as HTMLButtonElement;
  let running: AbortController | null = null;
  cancelBtn.addEventListener('click', () => { running?.abort(); });
  // off with the page's own words: the server's door, or (an instance report) no active instance of its engine to run on
  const noInst = def.engine !== 'store' && !mine.length && !gone;
  const runWhy = !d.state.enabled ? (d.state.reason || 'Running a report is off on this server.')
    : def.engine === 'store' && d.state.store ? d.state.store
    : noInst ? `No active ${def.engine === 'sqlserver' ? 'SQL Server' : 'PostgreSQL'} instance${folderTag ? ` in ${folderWords(folderTag)}` : ''} to run it on.` : '';
  // 'said': report mail carries this paragraph's words (reportmail.ts notesOf) - a run that is not made says why
  const runOff = el('p', { class: 'meta off-reason said' }, runWhy);
  if (runWhy) offControl(runBtn, runWhy, runOff);
  const storeTextRun = def.engine === 'store' && d.state.store_text ? el('p', { class: 'meta said' }, d.state.store_text) : null;
  const editBtn = el('a', { href: `#/customreports?edit=${def.report_id}${tagQ(ctx) ? '&' + tagQ(ctx) : ''}` }, 'Edit this report');
  // the menu bar's pickers first (DBA Dash's Menu Bar), then the parameters in their order
  const order = def.params.map((_, i) => i).sort((a, b) => Number(!def.params[a].picker?.menu) - Number(!def.params[b].picker?.menu));
  // Trigger Collection (DBA Dash L98): the collections the report names; this server starts a collection on its
  // schedule only, so the button is off and its words give the run by hand for the instance picked
  const trigBtn = def.collections?.length ? el('button', { type: 'button' }, 'Trigger Collection') : null;
  const trigOff = el('p', { class: 'meta off-reason' });
  const trigWords = () => {
    if (!trigBtn) return;
    const who = target.value === 'instance' && instSel.selectedOptions[0] ? instSel.selectedOptions[0].textContent!.replace(/ \(not active here\)$/, '') : '<name>';
    const w = `Trigger Collection is off: this server starts ${def.collections!.join(', ')} on ${def.collections!.length > 1 ? 'their' : 'its'} schedule only. `
      + 'One run by hand on the server: ' + def.collections!.map(c => `pgvigil collect -config pgvigil.yaml -once ${c} -instance ${who}`).join('; ') + '.';
    trigOff.textContent = w;
    offControl(trigBtn, w, trigOff);
  };
  // the switch button (DBA Dash L106): opens the paired report on the same target with the parameters both declare
  // (their values carried by name in the address; the pair fills only its own); Back returns here
  const pairBtn = def.pair ? el('button', { type: 'button' }, def.pair.label || 'Switch report') : null;
  pairBtn?.addEventListener('click', () => {
    const qq: Record<string, string> = { report: String(def.pair!.report_id) };
    def.params.forEach((p, i) => { if (inputs[i].value !== '') qq['p.' + p.name] = inputs[i].value; });
    if (target.value === 'instance' && instSel.value) qq.i = instSel.value;
    else if (target.value === 'tag' && tagSel.value) qq.tag = tagSel.value;
    if (lastRuns) qq.run = '1';
    go(qq);
  });
  const form = el('div', { class: 'toolbar' }, el('label', {}, 'Run on ', target), instBox, tagBox,
    ...order.map(i => labels[i]), runBtn, cancelBtn, ...(trigBtn ? [trigBtn] : []), ...(pairBtn ? [pairBtn] : []), editBtn);
  sec.append(form);
  if (trigBtn) { sec.append(trigOff); trigWords(); }
  if (folderTag) sec.append(el('p', { class: 'meta' }, `Opened from ${folderWords(folderTag)}: a run from here goes to its instances`
    + (runTag ? '.' : ', one at a time (the folder is no tag a run can name).')));
  if (runWhy) sec.append(runOff);
  if (storeTextRun) sec.append(storeTextRun);
  if (def.engine === 'store' && !mine.length) sec.append(el('p', { class: 'empty' }, folderTag ? `No active instance in ${folderWords(folderTag)}.` : 'No active instance: a run reads none.'));
  const status = el('p', { class: 'meta', role: 'status' });
  const out = el('div', {});

  // ---- the result sets (DBA Dash L102-L115): Select Results, Restore Default View, Toggle Grid / Charts, Fit to one
  // screen, Script Report; with several sets each in a box with its toolbar and a bottom edge that resizes it
  let lastRuns: InstanceRun[] | null = null;
  let only = '', maxed: HTMLElement | null = null, gridOff = false, fit = false;
  const heights = new Map<string, number>();
  const setName = (i: number) => def.sets?.find(x => x.set === i)?.name || `result set ${i + 1}`;
  const inAll = (i: number) => def.sets?.find(x => x.set === i)?.in_all !== false;
  const selRes = el('select', { 'aria-label': 'Select Results' }) as HTMLSelectElement;
  const selBox = el('label', {}, 'Select Results ', selRes);
  const restoreBtn = el('button', { type: 'button' }, 'Restore Default View');
  const gridBtn = el('button', { type: 'button', 'aria-pressed': 'false' }, 'Toggle Grid');
  // Toggle Charts: the charts' panel shown or not (off with its reason while the report has none)
  const chartsBtn = el('button', { type: 'button', 'aria-pressed': 'false' }, 'Toggle Charts');
  const fitBox = el('input', { type: 'checkbox' }) as HTMLInputElement;
  const fitLabel = el('label', {}, fitBox, ' Fit to one screen');
  const scriptBtn = el('button', { type: 'button' }, 'Script Report');
  scriptBtn.addEventListener('click', () => openViewer(`Script Report: ${def.name}`, scriptOf(def)));
  // Save Layout / Reset Layout (DBA Dash L109, L208): the sets' hidden columns, the grids shown or not and the sets'
  // heights, saved with the report as every viewer's default; a viewer's own browser choices are drawn over it
  const saveLayBtn = el('button', { type: 'button' }, 'Save Layout'), resetLayBtn = el('button', { type: 'button' }, 'Reset Layout');
  const viewBar = el('div', { class: 'toolbar cr-view-bar' }, selBox, restoreBtn, gridBtn, chartsBtn, fitLabel, saveLayBtn, resetLayBtn, scriptBtn);
  // a change on the page (Rename, the layout, the column items) saves the report: an admin's (B24f), with the server's
  // own reason first
  const renameWhy = !d.state.enabled ? (d.state.reason || 'saving is off on this server') : (routeWhy('customreports', d.state.can) ?? '');
  const layWhy = () => renameWhy ? 'Saving the layout saves the report: ' + renameWhy : '';
  const resetWhy = () => renameWhy ? 'Resetting the layout saves the report: ' + renameWhy : def.layout ? '' : 'no layout is saved with the report';
  const layState = () => { offControl(saveLayBtn, layWhy() || (lastRuns ? null : 'run the report first: the layout is read from its grids')); offControl(resetLayBtn, resetWhy() || null); };
  layState();
  if (def.layout?.grid_off) gridOff = true;
  for (const [k, v] of Object.entries(def.layout?.heights ?? {})) heights.set(`0:${k}`, v);
  const apply = () => {
    const boxes = [...out.querySelectorAll<HTMLElement>('.cr-set')];
    for (const b of boxes) {
      const i = Number(b.dataset.set);
      b.hidden = maxed ? b !== maxed : !(only ? setName(i) === only : inAll(i));
      const g = b.querySelector<HTMLElement>('.cr-set-grid');
      if (g) g.hidden = gridOff;
      const mx = b.querySelector<HTMLElement>('.cr-set-max');
      if (mx) { mx.textContent = maxed === b ? 'Show All Sets' : 'Maximize'; mx.setAttribute('aria-pressed', String(maxed === b)); }
    }
    const shown = boxes.filter(b => !b.hidden && b.querySelector('.cr-set-sep'));
    // fit: the shown sets share one screen (100 px each at least); else each keeps the height it was dragged to
    const each = Math.max(100, Math.floor((window.innerHeight - 160) / Math.max(1, shown.length)));
    for (const b of boxes) {
      const h = fit && shown.length > 1 && !b.hidden ? each : heights.get(b.dataset.key ?? '');
      b.style.height = h ? `${h}px` : '';
      b.querySelector('.cr-set-sep')?.setAttribute('aria-valuenow', String(Math.round(h ?? b.getBoundingClientRect().height)));
    }
    gridBtn.setAttribute('aria-pressed', String(gridOff));
  };
  // the links (L120, L125-L128): a drill-down's address carries the page's range, target and parameters (the user's
  // filters, by name: the target fills only its own) and the row's values for the target's parameters; a panel draws
  // the target's run under the report
  const carried = () => { const q = new URLSearchParams(), h = hashParams(); for (const k of ['w', 'from', 'to']) { const v = h.get(k); if (v) q.set(k, v); } return q; };
  const pageParams = (): Record<string, string> => Object.fromEntries(def.params.map((p, i) => [p.name, inputs[i].value] as [string, string]).filter(([, v]) => v !== ''));
  const child = el('section', { class: 'cr-child', hidden: '' });
  const openPanel = async (l: Link, from: Record<string, string>) => {
    const close = el('button', { type: 'button' }, 'Close the panel');
    close.addEventListener('click', () => { child.hidden = true; child.replaceChildren(); });
    child.hidden = false;
    child.replaceChildren(el('h3', {}, 'Drill-down'), close, el('p', { class: 'meta', role: 'status' }, 'Running the report...'));
    try {
      const got = rowsOf((await get<{ report: Table | null }>('customreports', { report: l.report_id })).report);
      if (!got.length) throw new Error(`No report ${l.report_id}: the link names a report that is gone.`);
      const tdef = defOf(got[0]), b = runBody();
      const r = await post<{ runs: InstanceRun[] }>('customreports/run', { ...b, report_id: tdef.report_id, params: { ...pageParams(), ...from },
        target: tdef.engine === 'store' || b.target !== 'fleet' ? b.target : 'instance' });
      child.replaceChildren(el('h3', {}, `Drill-down: ${tdef.name}`), close, resultView(r.runs, tdef, tdef.name));
    } catch (e) { child.replaceChildren(el('h3', {}, 'Drill-down'), close, errorBox(e)); }
  };
  const linkCtx: LinkCtx = {
    get links() { return def.links ?? []; },
    range: () => { const q = carried().toString(); return q ? '&' + q : ''; },
    drillHref: (l, from) => {
      const q = carried();
      if (target.value === 'instance' && instSel.value) q.set('i', instSel.value);
      else if (target.value === 'tag' && tagSel.value) q.set('tag', tagSel.value);
      for (const [k, v] of Object.entries({ ...pageParams(), ...from })) q.set('p.' + k, v);
      q.set('report', String(l.report_id)); q.set('run', '1');
      return '#/customreports?' + q.toString();
    },
    panel: (l, from) => { void openPanel(l, from); },
  };
  // a set's box: one set draws as before (its grid); several get the toolbar (Maximize, the name, Columns, Copy, Clear
  // Filter - marked while a filter is on -, Rename) and the separator under it
  const setBox = (run: InstanceRun, ri: number, s: ResultSet, i: number): HTMLElement => {
    const several = run.sets.length > 1;
    const b = el('div', { class: 'cr-set' });
    b.dataset.set = String(i); b.dataset.key = `${ri}:${i}`;
    const g = el('div', { class: 'cr-set-grid' }, setGrid(s, i, def.columns, def.rules, linkCtx));
    const t = () => g.querySelector<HTMLTableElement>('table.grid');
    // the saved layout: this set's hidden columns, every viewer's default until the viewer's browser keeps its own
    const lay = def.layout?.sets?.find(x => x.set === i);
    const tt0 = t();
    if (lay?.hidden?.length && tt0) setGridDefault(tt0, { hidden: lay.hidden });
    if (several) {
      const act = (label: string, sub?: string) => (back: HTMLElement) => {
        const tt = t(); if (!tt) return;
        const m = gridMenu(tt, null, null, back).find(x => x.label === label);
        const x = sub ? m?.sub?.find(y => y.label === sub) : m;
        x?.act?.();
      };
      const btn = (label: string, f: (b: HTMLElement) => void, cls = '') => { const x = el('button', { type: 'button', class: cls }, label); x.addEventListener('click', () => f(x)); return x; };
      const mx = btn('Maximize', () => { maxed = maxed === b ? null : b; apply(); }, 'cr-set-max');
      const clr = btn('Clear Filter', x => { act('Clear filters')(x); mark(); });
      const mark = () => { const tt = t(); clr.classList.toggle('not-default', !!tt && gridFiltered(tt)); };
      g.addEventListener('input', () => setTimeout(mark, 0));
      const ren = btn('Rename', () => { void renameSet(i); });
      if (renameWhy) offControl(ren, 'Renaming a result set saves the report: ' + renameWhy);
      b.append(el('div', { class: 'cr-set-bar' }, mx, el('h4', { class: 'cr-set-name' }, setName(i)), btn('Columns', act('Columns...')), btn('Copy', act('Copy', 'Grid')), clr, ren));
    }
    if (s.truncated) b.append(el('p', { class: 'meta' }, `Cut at ${fmtNum(s.rows.length)} rows (the report's row cap, or the run's 24 MB).`));
    b.append(g);
    if (several) {
      // the bottom edge (DBA Dash L115): dragged, or moved by the arrow keys, 100 px at least
      const sep = el('div', { class: 'cr-set-sep', role: 'separator', tabindex: '0', 'aria-orientation': 'horizontal', 'aria-label': `Resize ${setName(i)}`,
        'aria-valuemin': '100', 'aria-valuemax': '4000' });
      const setH = (h: number) => { const v = Math.max(100, Math.min(4000, Math.round(h))); heights.set(b.dataset.key!, v); b.style.height = `${v}px`; sep.setAttribute('aria-valuenow', String(v)); };
      sep.addEventListener('keydown', e => {
        const k = (e as KeyboardEvent).key, now = b.getBoundingClientRect().height;
        if (k === 'ArrowDown' || k === 'ArrowUp') { e.preventDefault(); setH(now + (k === 'ArrowDown' ? 20 : -20)); }
      });
      sep.addEventListener('pointerdown', e => {
        const y0 = e.clientY, h0 = b.getBoundingClientRect().height;
        sep.setPointerCapture(e.pointerId);
        const move = (m: PointerEvent) => setH(h0 + m.clientY - y0);
        const up = () => { sep.removeEventListener('pointermove', move); sep.removeEventListener('pointerup', up); };
        sep.addEventListener('pointermove', move); sep.addEventListener('pointerup', up);
      });
      b.append(sep);
    }
    return b;
  };
  const draw = () => {
    if (!lastRuns) return;
    const runs = lastRuns, box = el('section', { class: 'report-result' });
    for (const [ri, run] of runs.entries()) {
      const many = runs.length > 1 || run.instance !== 'store';
      const plain = run.outcome === 'refused' || !!run.declined;
      box.append(el('h3', {}, many ? `${def.name}: ${run.instance}` : def.name), el('p', { class: 'meta' }, badge(run.declined ? 'declined' : run.outcome, run.outcome === 'done' ? 'ok' : plain ? 'warn' : 'crit'),
        ` ${fmtNum(run.rows)} rows in ${fmtNum(run.duration_ms)} ms${run.sets.length > 1 ? `, ${run.sets.length} result sets` : ''}`));
      if (run.error) box.append(plain ? el('p', { class: 'meta refused', role: 'note' }, run.error) : errorBox(run.error));
      if (run.sets.length) box.append(el('div', { class: 'cr-sets' }, ...run.sets.map((s, i) => setBox(run, ri, s, i))));
      else if (run.outcome === 'done') box.append(el('p', { class: 'empty' }, 'The run returned no result set.'));
    }
    out.replaceChildren(box);
    // Select Results: All and each set's name, with several sets only
    const n = Math.max(0, ...runs.map(r => r.sets.length));
    const names = [...new Set(Array.from({ length: n }, (_, i) => setName(i)))];
    selRes.replaceChildren(el('option', { value: '' }, 'All'), ...names.map(x => el('option', { value: x }, x)));
    if (!names.includes(only)) only = '';
    selRes.value = only;
    selBox.hidden = n < 2; fitLabel.hidden = n < 2;
    apply();
    layState();
    drawCharts();
  };
  // saveWith: a change made on the page, saved with the report; the page drawn again from the saved definition
  const saveWith = async (patch: Partial<ReportDef>, said: string) => {
    const keys = Object.keys(patch) as (keyof ReportDef)[];
    const was = Object.fromEntries(keys.map(k => [k, def[k]])) as Partial<ReportDef>;
    Object.assign(def, patch);
    try { await saveDef(def); draw(); status.textContent = said; }
    catch (e) { Object.assign(def, was); status.textContent = 'Not saved: ' + (e instanceof Error ? e.message : String(e)); }
  };
  saveLayBtn.addEventListener('click', () => {
    const sets: { set: number; hidden?: string[] }[] = [];
    for (const b of out.querySelectorAll<HTMLElement>('.cr-set')) {
      const tb = b.querySelector<HTMLTableElement>('table.grid');
      if (!tb || b.dataset.key?.split(':')[0] !== '0') continue;   // the first run's sets: every run draws the same ones
      const hidden = gridHidden(tb);
      if (hidden.length) sets.push({ set: Number(b.dataset.set), hidden });
    }
    const hs = Object.fromEntries([...heights].filter(([k]) => k.startsWith('0:')).map(([k, v]) => [k.slice(2), v]));
    const layout: SavedLayout = { sets: sets.length ? sets : undefined, grid_off: gridOff || undefined, heights: Object.keys(hs).length ? hs : undefined,
      chart_layout: chartLayout !== 'auto' ? chartLayout : undefined, chart_location: chartLoc !== 'top' ? chartLoc : undefined, charts_off: chartsOff || undefined };
    void saveWith({ layout: Object.values(layout).some(v => v !== undefined) ? layout : undefined }, 'The layout is saved with the report: every viewer opens it so (a viewer\'s own choices drawn over it).');
  });
  resetLayBtn.addEventListener('click', () => {
    for (const t of out.querySelectorAll<HTMLTableElement>('table.grid')) resetGrid(t);
    gridOff = false; heights.clear();
    void saveWith({ layout: undefined }, 'The saved layout is cleared: the grids are drawn as the report returns them.');
  });

  // Edit Report (DBA Dash's column and cell menu, L116-L118, L123): a grid's right-click menu gets the report's own
  // items for the column or the cell clicked, each saved with the report
  out.addEventListener('pgvigil:gridmenu', e => {
    const q0 = (e as CustomEvent<GridMenuAsk>).detail;
    if (!q0?.table || q0.done) return;
    const box = q0.table.closest<HTMLElement>('.cr-set');
    const run = lastRuns?.[Number(box?.dataset.key?.split(':')[0] ?? -1)], si = Number(box?.dataset.set ?? -1), set = run?.sets[si];
    if (!box || !set) return;
    const cell = (q0.th ?? q0.td) as HTMLTableCellElement | null;
    const key = cell ? gridModel(q0.table)?.cols[cell.cellIndex]?.key : undefined;
    const ci = key ? Number(key.slice(1)) : -1, name = set.columns[ci];
    const off = renameWhy ? 'Changing the report saves it: ' + renameWhy : undefined;
    if (name == null) { q0.more.push({ label: 'Edit Report', sub: [{ label: 'Rename Column', off: 'right-click a column\'s header or cell' }] }); return; }
    const f = def.columns.find(c => c.set === si && c.column.toLowerCase() === name.toLowerCase());
    const withCol = (change: (x: ColFmt) => void) => {
      const cols = def.columns.map(c => ({ ...c })), k = cols.findIndex(c => c.set === si && c.column.toLowerCase() === name.toLowerCase());
      const x: ColFmt = k >= 0 ? cols[k] : { set: si, column: name };
      change(x);
      if (k < 0) cols.push(x);
      return cols;
    };
    const isTime = set.types[ci] === 'time' || f?.format === 'time';
    const sub: MenuLine[] = [
      { label: 'Rename Column', off, act: () => { void askText(`Rename the column ${name}`, 'Column name (empty = as the report returns it)', f?.label ?? name).then(v => {
        if (v == null) return;
        void saveWith({ columns: withCol(x => { x.label = v.trim() && v.trim() !== name ? v.trim() : undefined; }) }, `The column ${name} is shown as '${v.trim() || name}' (saved with the report).`);
      }); } },
      { label: 'Set Column Tooltip', off, act: () => { void askText(`Set the tooltip of ${f?.label || name}`, 'Tooltip (empty = none)', f?.tooltip ?? '').then(v => {
        if (v == null) return;
        void saveWith({ columns: withCol(x => { x.tooltip = v.trim() || undefined; }) }, `The column ${name}'s tooltip is saved with the report.`);
      }); } },
      { label: 'Convert to local time zone', checked: isTime && !f?.utc, off: off ?? (isTime ? undefined : 'not a date and time column'), act: () => {
        void saveWith({ columns: withCol(x => { x.utc = x.utc ? undefined : true; }) }, f?.utc ? `${name} is shown in this browser's time zone.` : `${name} is shown as stored, in UTC.`);
      } },
      { label: 'Highlight Cell Value', off: off ?? (q0.td ? undefined : 'right-click a cell: its value is the rule\'s'), act: () => {
        const tr = q0.td!.parentElement as HTMLTableRowElement, idx = [...tr.parentElement!.children].indexOf(tr);
        const raw = gridModel(q0.table!)?.rows()[idx]?.[key!];
        void highlightDialog(name, raw == null ? q0.td!.textContent?.trim() ?? '' : String(raw)).then(r => {
          if (!r) return;
          void saveWith({ rules: [...def.rules, { set: si, column: name, cond: r.cond, value1: r.value, status: r.status }] }, `A colour rule on ${name} is saved with the report (${condNames[r.cond]} ${r.value}).`);
        });
      } },
    ];
    sub.push({ label: 'Add Link', off, act: () => {
      const cur = def.links?.find(x => (x.set ?? 0) === si && x.column.toLowerCase() === name.toLowerCase());
      void linkDialog(set.columns, name, si, cur).then(r => {
        if (r == null) return;
        const keep = (def.links ?? []).filter(x => x !== cur);
        const links = r === 'none' ? keep : [...keep, r];
        void saveWith({ links: links.length ? links : undefined }, r === 'none' ? `The link on ${name} is removed (saved with the report).` : `${name}'s cells are links now (saved with the report).`);
      });
    } });
    q0.more.push({ label: 'Edit Report', sub });
  });
  const renameSet = async (i: number) => {
    const now = setName(i), v = await askText(`Rename ${now}`, 'Result set name', now);
    if (v == null) return;
    const keep = def.sets ?? [], cur = keep.find(x => x.set === i);
    const sets = [...keep.filter(x => x.set !== i), { ...cur, set: i, name: v.trim() || undefined }].sort((a, b) => a.set - b.set);
    const was = def.sets;
    def.sets = sets;
    try { await saveDef(def); if (only === now) only = setName(i); draw(); status.textContent = `Result set ${i + 1} is named '${setName(i)}' (saved with the report).`; }
    catch (e) { def.sets = was; status.textContent = 'Not renamed: ' + (e instanceof Error ? e.message : String(e)); }
  };
  selRes.addEventListener('change', () => { only = selRes.value; maxed = null; apply(); });
  gridBtn.addEventListener('click', () => { gridOff = !gridOff; apply(); });
  fitBox.addEventListener('change', () => { fit = fitBox.checked; apply(); });
  restoreBtn.addEventListener('click', () => {
    for (const t of out.querySelectorAll<HTMLTableElement>('table.grid')) resetGrid(t);
    only = ''; maxed = null; gridOff = false; fit = false; fitBox.checked = false; heights.clear();
    draw();
  });
  const onResize = () => { if (!out.isConnected) { window.removeEventListener('resize', onResize); return; } if (fit) apply(); };
  window.addEventListener('resize', onResize);
  // ---- the charts (DBA Dash L130-L135): the report's own (a result set drawn, crchart.ts) and the instance's system
  // charts, in a panel whose layout (rows, columns, auto) and place (top, bottom, left, right) the page chooses
  let chartLayout = def.layout?.chart_layout ?? 'auto', chartLoc = def.layout?.chart_location ?? 'top', chartsOff = !!def.layout?.charts_off;
  let sysOn: string[] = [...(def.system_charts ?? [])];
  const chartsBox = el('div', { class: 'cr-charts' }), body = el('div', { class: 'cr-body' }, chartsBox, out);
  const layoutSel = sel('Chart Layout', { auto: 'auto', rows: 'one per row', columns: 'side by side' }, chartLayout);
  const locSel = sel('Chart Location', { top: 'above the grids', bottom: 'under the grids', left: 'left of the grids', right: 'right of the grids' }, chartLoc);
  const addChartBtn = el('button', { type: 'button' }, 'Add Chart'), delChartsBtn = el('button', { type: 'button' }, 'Delete All Charts');
  const sysBtn = el('button', { type: 'button' }, 'Add System Chart'), sysSaveBtn = el('button', { type: 'button' }, 'Save System Chart State');
  const chartBar = el('div', { class: 'toolbar cr-chart-bar' }, addChartBtn, sysBtn, sysSaveBtn, el('label', {}, 'Chart Layout ', layoutSel), el('label', {}, 'Chart Location ', locSel), delChartsBtn);
  const sysNames: Record<string, string> = { cpu: 'CPU', waits: 'Waits', io: 'IO', blocking: 'Blocking' };
  const sysInstance = () => target.value === 'instance' && Number(instSel.value) > 0 ? Number(instSel.value) : 0;
  const placeCharts = () => {
    chartsBox.dataset.layout = chartLayout; chartsBox.dataset.location = chartLoc; body.dataset.location = chartLoc;
    const any = !!def.charts?.length || sysOn.length > 0;
    chartsBox.hidden = chartsOff || !any;
    offControl(chartsBtn, any ? null : 'the report has no chart');
    chartsBtn.setAttribute('aria-pressed', String(!chartsOff && any));
    offControl(delChartsBtn, renameWhy ? 'Deleting the charts saves the report: ' + renameWhy : def.charts?.length ? null : 'the report has no chart');
    offControl(addChartBtn, renameWhy ? 'Adding a chart saves the report: ' + renameWhy : lastRuns ? null : 'run the report first: a chart is drawn from its result sets');
    offControl(sysBtn, sysInstance() ? null : 'a system chart is one instance\'s: run the report on one instance');
    offControl(sysSaveBtn, renameWhy ? 'Saving the system charts saves the report: ' + renameWhy : null);
  };
  // a point clicked: the drill-down of the report's link on the chart's metric (else its X) column, from that row
  const pointDrill = (c: ChartDef, sets: ChartSet[]) => (row: number) => {
    const set = sets[c.set], cols = [...c.metrics, c.x].map(x => x.toLowerCase());
    const l = def.links?.find(x => (x.set ?? 0) === c.set && x.kind === 'drill' && cols.includes(x.column.toLowerCase()));
    if (!l || !set) return;
    const at = (col: string) => { const k = set.columns.findIndex(x => x.toLowerCase() === col.toLowerCase()); const v = k < 0 ? null : set.rows[row]?.[k]; return v == null ? '' : String(v); };
    const from = Object.fromEntries(Object.entries(l.map ?? {}).map(([p, col]) => [p, at(col)]));
    if (l.open === 'panel') linkCtx.panel(l, from);
    else if (l.open === 'same') location.hash = linkCtx.drillHref(l, from);
    else window.open(linkCtx.drillHref(l, from), '_blank', 'noopener');
  };
  // the system charts: the instance's Performance series (GET /api/performance) - CPU, the waits, the IO, the blocked
  // sessions - each drawn as a line over the time range
  let sysSeq = 0;
  const drawSystem = async (into: HTMLElement[]) => {
    const inst = sysInstance(), my = ++sysSeq;
    if (!sysOn.length) return;
    if (!inst) { into.forEach(b => b.replaceWith(el('p', { class: 'meta' }, 'The system charts are one instance\'s: run the report on one instance.'))); return; }
    let d: Record<string, Table | null>;
    try { d = await get<Record<string, Table | null>>('performance', { instance: inst, ...window_(ctx) }); }
    catch (e) { into.forEach(b => b.replaceChildren(errorBox(e))); return; }
    if (my !== sysSeq) return;
    sysOn.forEach((k, i) => {
      const part = k === 'blocking' ? d.sessions : d[k];
      const t = part ? { columns: part.columns, rows: part.rows as unknown[][] } : { columns: [], rows: [] };
      const nums = t.columns.filter((c, j) => c !== 'snapshot_at' && t.rows.some(r => r[j] != null && !isNaN(Number(r[j]))) && (k !== 'blocking' || /block/i.test(c)));
      const txt = t.columns.find((c, j) => c !== 'snapshot_at' && !nums.includes(c) && t.rows.some(r => typeof r[j] === 'string' && isNaN(Number(r[j]))));
      const box = nums.length ? drawChart({ type: 'Line', set: 0, x: 'snapshot_at', metrics: nums.slice(0, 4), series: txt, title: `${sysNames[k]} (the instance's own)`, x_range: true }, [t], { window: { from: Date.parse(window_(ctx).from), to: Date.parse(window_(ctx).to) } })
        : el('figure', { class: 'cr-chart' }, el('figcaption', {}, sysNames[k]), el('p', { class: 'meta' }, `No ${sysNames[k]} read for this instance in the range.`));
      box.dataset.type = 'system:' + k;
      into[i]?.replaceWith(box);
    });
  };
  const drawCharts = () => {
    placeCharts();
    const run = lastRuns?.find(r => r.sets.length);
    const sets: ChartSet[] = run ? run.sets.map(x => ({ columns: x.columns, rows: x.rows })) : [];
    const w = window_(ctx), win = { from: Date.parse(w.from), to: Date.parse(w.to) };
    const hidden = (c: ChartDef) => !!c.hidden_when && def.params.some((p, i) => p.name === c.hidden_when && inputs[i].value.trim() !== '');
    const own = (def.charts ?? []).map((c, i) => { if (hidden(c)) return null; const b = drawChart(c, sets, { window: win, onPoint: pointDrill(c, sets) }); b.dataset.index = String(i); return b; }).filter((b): b is HTMLElement => !!b);
    const sysBoxes = sysOn.map(k => { const b = el('figure', { class: 'cr-chart' }, el('figcaption', {}, sysNames[k] + ': reading...')); b.dataset.type = 'system:' + k; return b; });
    chartsBox.replaceChildren(...own, ...sysBoxes);
    if (run && run.instance !== 'store' && (lastRuns?.length ?? 0) > 1) chartsBox.append(el('p', { class: 'meta' }, `The charts draw ${run.instance}'s result sets (the first instance of the run).`));
    void drawSystem(sysBoxes);
  };
  layoutSel.addEventListener('change', () => { chartLayout = layoutSel.value; placeCharts(); });
  locSel.addEventListener('change', () => { chartLoc = locSel.value; placeCharts(); });
  chartsBtn.addEventListener('click', () => { chartsOff = !chartsOff; placeCharts(); });
  addChartBtn.addEventListener('click', () => {
    const run = lastRuns?.find(r => r.sets.length);
    void chartDialog(run?.sets[0]?.columns ?? [], def.params.map(p => p.name)).then(c => { if (c) void saveWith({ charts: [...(def.charts ?? []), c] }, 'The chart is saved with the report.'); });
  });
  delChartsBtn.addEventListener('click', () => {
    void confirmDialog(`Delete the report's ${def.charts?.length ?? 0} chart(s)? The report is saved without them.`, 'Delete all charts').then(ok => { if (ok) void saveWith({ charts: undefined }, 'The charts are deleted (saved with the report).'); });
  });
  sysBtn.addEventListener('click', () => {
    const r = sysBtn.getBoundingClientRect();
    showMenu(r.left, r.bottom, Object.entries(sysNames).filter(([k]) => !sysOn.includes(k)).map(([k, v]) => [v, () => { sysOn = [...sysOn, k]; drawCharts(); }] as [string, () => void]), sysBtn);
  });
  sysSaveBtn.addEventListener('click', () => { void saveWith({ system_charts: sysOn.length ? [...sysOn] : undefined }, 'The system charts are saved with the report.'); });
  // a chart's own menu (DBA Dash L133): Configure, Move Up, Move Down, Delete - each saved with the report
  chartsBox.addEventListener('contextmenu', e => {
    const box = (e.target as Element).closest<HTMLElement>('.cr-chart');
    if (!box) return;
    e.preventDefault();
    const back = document.activeElement instanceof HTMLElement ? document.activeElement : null;
    if (box.dataset.type?.startsWith('system:')) {
      const k = box.dataset.type.slice(7);
      showMenu(e.clientX, e.clientY, [['Remove (Save System Chart State keeps it so)', () => { sysOn = sysOn.filter(x => x !== k); drawCharts(); }]], back);
      return;
    }
    const i = Number(box.dataset.index), list = def.charts ?? [];
    const moved = (j: number) => { const a = [...list]; [a[i], a[j]] = [a[j], a[i]]; return a; };
    const no = renameWhy ? () => { status.textContent = 'Not saved: changing a chart saves the report: ' + renameWhy; } : null;
    showMenu(e.clientX, e.clientY, [
      ['Configure', no ?? (() => { const run = lastRuns?.find(r => r.sets.length); void chartDialog(run?.sets[list[i].set]?.columns ?? [], def.params.map(p => p.name), list[i]).then(c => { if (c) void saveWith({ charts: list.map((x, j) => j === i ? c : x) }, 'The chart is saved with the report.'); }); })],
      ['Move Up', no ?? (() => { if (i > 0) void saveWith({ charts: moved(i - 1) }, 'The chart moved up (saved with the report).'); })],
      ['Move Down', no ?? (() => { if (i < list.length - 1) void saveWith({ charts: moved(i + 1) }, 'The chart moved down (saved with the report).'); })],
      ['Delete', no ?? (() => { void saveWith({ charts: list.filter((_, j) => j !== i).length ? list.filter((_, j) => j !== i) : undefined }, 'The chart is deleted (saved with the report).'); })],
    ], back);
  });
  placeCharts();
  sec.append(viewBar, chartBar, status, body, child);

  // a query picker's values: its query run on the report's target (POST .../run with 'picker'), audited as a run; the
  // first column the value, the second (when there is one) the words; a list that cannot be read says so in its options
  const runBody = () => { const w = window_(ctx); return { report_id: def.report_id, target: target.value, instance_id: Number(instSel.value), tag: tagSel.value, from: w.from, to: w.to }; };
  const loadPicker = async (i: number) => {
    const p = def.params[i], s = inputs[i] as HTMLSelectElement;
    const keep = s.value || s.dataset.want || '';
    const one = (value: string, words: string, off = false) => { const o = el('option', { value }, words) as HTMLOptionElement; o.disabled = off; return o; };
    if (runWhy) { s.replaceChildren(one('', 'the list is not read: ' + runWhy, true)); return; }
    s.replaceChildren(one(keep, 'reading the list...'));
    try {
      const r = await post<{ runs: InstanceRun[] }>('customreports/run', { ...runBody(), picker: p.name, params: {} });
      const seen = new Map<string, string>(), errs: string[] = [];
      for (const x of r.runs) {
        if (x.outcome !== 'done') { errs.push(x.error || x.outcome); continue; }
        for (const row of x.sets[0]?.rows ?? []) { const v = row[0] == null ? '' : String(row[0]); if (!seen.has(v)) seen.set(v, row.length > 1 && row[1] != null ? String(row[1]) : v); }
      }
      s.replaceChildren(...[...seen].map(([v, w]) => one(v, w)));
      if (!seen.size) s.append(one('', errs.length ? 'Error loading the list: ' + errs[0] : 'the list is empty', true));
      if (keep && seen.has(keep)) s.value = keep;
    } catch (e) { s.replaceChildren(one('', 'Error loading the list: ' + (e instanceof Error ? e.message : String(e)), true)); }
    mark(i);
  };
  const loadPickers = () => Promise.all(def.params.map((p, i) => p.picker?.kind === 'query' ? loadPicker(i) : Promise.resolve()));

  // hh:mm:ss of a run's time (the status strip's timer, DBA Dash L90)
  const clock = (ms: number) => { const s = Math.floor(ms / 1000), p = (n: number) => String(n).padStart(2, '0'); return `${p(Math.floor(s / 3600))}:${p(Math.floor(s / 60) % 60)}:${p(s % 60)}`; };
  // a later run (a picker changed while one ran) replaces the earlier: its request is stopped and its answer dropped
  let seq = 0;
  const run = async () => {
    // a required parameter left empty: no run, the words and a way to it (DBA Dash L92)
    const empty = def.params.findIndex((p, i) => p.required && inputs[i].value.trim() === '');
    if (empty >= 0) {
      const go = el('button', { type: 'button', class: 'link' }, 'Set Parameters');
      go.addEventListener('click', () => inputs[empty].focus());
      status.replaceChildren('Parameters are required to run the report. ', go);
      return;
    }
    const my = ++seq;
    running?.abort();
    const ctl = new AbortController();
    running = ctl; cancelBtn.disabled = false;
    const t0 = Date.now();
    status.textContent = `Running ${clock(0)}`;
    const tick = setInterval(() => { if (my === seq) status.textContent = `Running ${clock(Date.now() - t0)}`; }, 1000);
    offControl(runBtn, 'running', status);
    const params: Record<string, string> = {};
    def.params.forEach((p, i) => { params[p.name] = inputs[i].value; });
    try {
      const r = await post<{ runs: InstanceRun[]; ran_at: string }>('customreports/run', { ...runBody(), params }, ctl.signal);
      if (my !== seq) return;
      lastRuns = r.runs; draw();
      // the report's own messages in place of 'Completed' (DBA Dash's ShowInfoMessages), per instance when several ran
      const said = def.status_from_messages ? r.runs.filter(x => x.messages?.length).map(x => (r.runs.length > 1 ? x.instance + ': ' : '') + x.messages!.join(' / ')) : [];
      status.textContent = said.length ? `${said.join('; ')} (completed in ${clock(Date.now() - t0)}, ran at ${fmtTime(r.ran_at)})`
        : `Completed in ${clock(Date.now() - t0)} (ran at ${fmtTime(r.ran_at)}).`;
    } catch (e) {
      if (my !== seq) return;
      if (ctl.signal.aborted) { status.textContent = `Cancelled after ${clock(Date.now() - t0)}: the statement was stopped on the server.`; }
      else { out.replaceChildren(errorBox(e)); status.textContent = ''; }
    } finally {
      clearInterval(tick);
      if (my === seq) {
        running = null; cancelBtn.disabled = true;
        offControl(runBtn, runWhy || null, runWhy ? runOff : status);
      }
    }
  };
  runBtn.addEventListener('click', () => { void run(); });
  // a picker runs the report when it changes (DBA Dash refreshes on a picked item), a text picker on Enter
  def.params.forEach((p, i) => {
    if (!p.picker) return;
    mark(i);
    if (p.picker.kind === 'text') {
      inputs[i].addEventListener('input', () => mark(i));
      inputs[i].addEventListener('keydown', e => { if ((e as KeyboardEvent).key === 'Enter') { e.preventDefault(); void run(); } });
    } else inputs[i].addEventListener('change', () => { mark(i); if (!runWhy) void run(); });
  });
  const retarget = () => { trigWords(); void loadPickers(); if (sysOn.length) drawCharts(); else placeCharts(); };
  for (const x of [target, instSel, tagSel]) x.addEventListener('change', retarget);
  await loadPickers();
  // a repository report runs on open (DBA Dash's custom reports run when opened); an instance report on the button,
  // or on open when the address says run=1 (a mailed or linked page)
  // a run only where it may: a store report without its login is not run on open (no refused row per page view); its
  // off words stand in the page, and a mailed render carries them (reportmail.ts notesOf reads p.said)
  if (d.state.enabled && !runWhy && (mine.length || gone) && (def.engine === 'store' || q.get('run') === '1')) await run();

  const det = el('details', {}, el('summary', {}, 'Definition'));
  det.append(el('pre', { class: 'sql', tabindex: '0' }, def.kind === 'procedure' ? 'procedure ' + def.body : def.body));
  // a report with a picker shows each parameter's picker too (a report without one: the grid as before)
  const pickerWords = (v: unknown) => { const x = v as Picker | undefined; return !x ? '' : (x.kind === 'list' ? 'a list: ' + (x.values ?? []).join(', ') : x.kind === 'query' ? 'a query\'s values' : 'a text box') + (x.menu ? ', on the menu bar' : ''); };
  if (def.params.length) det.append(el('h3', {}, 'Parameters'), grid(def.params as unknown as Row[], [
    { key: 'name' }, { key: 'type', fmt: v => typeNames[String(v)] ?? String(v) }, { key: 'label' }, { key: 'default' }, { key: 'required', fmt: v => v ? 'yes' : '' },
    ...(def.params.some(p => p.picker) ? [{ key: 'picker', fmt: pickerWords } as Col] : [])]));
  if (def.columns.length) det.append(el('h3', {}, 'Column formats'), grid(def.columns as unknown as Row[], [
    { key: 'set', label: 'result set', num: true, fmt: v => String(Number(v) + 1) }, { key: 'column' }, { key: 'label' },
    { key: 'format', fmt: v => formatNames[String(v ?? '')] ?? String(v) }, { key: 'decimals', num: true }, { key: 'hidden', fmt: v => v ? 'hidden' : '' }]));
  if (def.rules.length) det.append(el('h3', {}, 'Colour rules (the first that matches colours the cell)'), grid(def.rules as unknown as Row[], [
    { key: 'set', label: 'result set', num: true, fmt: v => String(Number(v) + 1) }, { key: 'column', label: 'colours' },
    { key: 'eval', label: 'judged on', fmt: (v, r) => String(v || r.column) }, { key: 'cond', label: 'when', fmt: v => condNames[String(v)] ?? String(v) },
    { key: 'value1', label: 'value' }, { key: 'value2', label: 'and' }, { key: 'status', fmt: v => badge(statusNames[String(v)] ?? String(v), String(v)) }]));
  det.append(el('p', { class: 'meta' }, `Timeout ${def.timeout_secs} s, at most ${fmtNum(def.max_rows)} rows per result set.`));
  sec.append(det, el('h3', {}, 'Runs and changes of this report'), grid(rowsOf(d.log), logCols, 'Not run yet.'));
  return sec;
}

// ---- the editor -------------------------------------------------------------------------------------------------

function sel(label: string, opts: Record<string, string>, value: string): HTMLSelectElement {
  const s = el('select', { 'aria-label': label }) as HTMLSelectElement;
  for (const [k, v] of Object.entries(opts)) s.append(el('option', { value: k }, v));
  s.value = value;
  return s;
}
const inp = (label: string, value: string | number | undefined, attrs: Record<string, string> = {}) =>
  el('input', { type: 'text', 'aria-label': label, value: value == null ? '' : String(value), ...attrs }) as HTMLInputElement;
const check = (label: string, on: boolean | undefined) => { const c = el('input', { type: 'checkbox', 'aria-label': label }) as HTMLInputElement; c.checked = !!on; return c; };

// rowsEditor: a table of rows, each a set of fields, with Add and Remove (the parameters, the formats, the rules)
function rowsEditor<T>(title: string, headers: string[], items: T[], make: (x: Partial<T>, n: number) => { cells: HTMLElement[]; read: () => T }, blank: Partial<T>): { box: HTMLElement; read: () => T[] } {
  const body = el('tbody');
  const readers: (() => T)[] = [];
  const rows: HTMLTableRowElement[] = [];
  const addRow = (x: Partial<T>) => {
    const n = rows.length + 1;
    const m = make(x, n);
    const rm = el('button', { type: 'button', class: 'link' }, 'Remove');
    const tr = el('tr', {}, ...m.cells.map(c => el('td', {}, c)), el('td', {}, rm));
    rm.addEventListener('click', () => { const i = rows.indexOf(tr); rows.splice(i, 1); readers.splice(i, 1); tr.remove(); });
    rows.push(tr); readers.push(m.read); body.append(tr);
  };
  items.forEach(addRow);
  const add = el('button', { type: 'button' }, 'Add');
  add.setAttribute('aria-label', 'Add to ' + title);
  add.addEventListener('click', () => addRow(blank));
  const table = el('table', { class: 'props' }, el('thead', {}, el('tr', {}, ...headers.map(h => el('th', {}, h)), el('th', {}, ''))), body);
  return { box: el('div', {}, el('h3', {}, title), el('div', { class: 'grid-wrap', tabindex: '0' }, table), add), read: () => readers.map(r => r()) };
}

async function editorPage(ctx: Ctx, id: number, folder = ''): Promise<HTMLElement> {
  const list = await get<{ state: State; folders: Table | null; reports: Table | null }>('customreports');
  let def: ReportDef = { name: '', description: '', folder, engine: 'store', kind: 'sql', body: '', params: [], columns: [], rules: [], timeout_secs: 30, max_rows: 5000 };
  if (id) {
    const d = await get<{ report: Table | null }>('customreports', { report: id });
    const r = rowsOf(d.report);
    if (!r.length) return el('p', { class: 'empty' }, `No report ${id}.`);
    def = defOf(r[0]);
  }
  const sec = el('section', {}, el('h2', {}, id ? `Edit ${def.name}` : 'New custom report'));
  // the server's own reason first, then the role (B24f: saving a report needs admin), in one sentence Save points at
  const saveWhy = list.state.enabled ? (routeWhy('customreports', list.state.can) ?? '') : (list.state.reason ?? '');
  const saveOff = list.state.enabled && !saveWhy ? null : el('p', { class: 'meta off-reason' }, 'Saving is off here: ' + saveWhy);
  if (saveOff) sec.append(saveOff);
  const folders = folderTree(rowsOf(list.folders).map(r => String(r.folder)));
  const name = inp('Name', def.name, { size: '40' });
  const desc = el('textarea', { 'aria-label': 'Description', rows: '2', cols: '80' }, def.description ?? '') as HTMLTextAreaElement;
  const fold = inp('Folder (parts joined by /, empty = the top)', def.folder, { list: 'cr-folders', size: '30' });
  const dl = el('datalist', { id: 'cr-folders' }, ...folders.map(f => el('option', { value: f })));
  const engine = sel('Runs on', { store: 'the repository (pgvigil\'s own tables)', postgres: 'PostgreSQL instances (read-only)', sqlserver: 'SQL Server instances (read-only)' }, def.engine);
  const kind = sel('Kind', { sql: 'SQL', procedure: 'a procedure (or a PostgreSQL function) by name' }, def.kind);
  const body = el('textarea', { 'aria-label': 'The SQL, or the procedure\'s name', rows: '14', cols: '100', class: 'sql', spellcheck: 'false' }, def.body) as HTMLTextAreaElement;
  const timeout = inp('Timeout (seconds, 1 to 60)', def.timeout_secs, { size: '4', inputmode: 'numeric' });
  const maxRows = inp('Rows per result set at most (1 to 50000)', def.max_rows, { size: '6', inputmode: 'numeric' });
  sec.append(
    el('p', {}, el('label', {}, 'Name ', name)),
    el('p', {}, el('label', {}, 'Description', el('br'), desc)),
    el('p', {}, el('label', {}, 'Folder ', fold), dl),
    el('div', { class: 'toolbar' }, el('label', {}, 'Runs on ', engine), el('label', {}, 'Kind ', kind),
      el('label', {}, 'Timeout (s) ', timeout), el('label', {}, 'Rows at most ', maxRows)),
    el('p', {}, el('label', {}, 'SQL (or the procedure\'s name)', el('br'), body)),
    el('p', { class: 'meta' }, 'Parameters are @name in the SQL on both engines; every run also passes @from and @to (the page\'s time range) and, on the repository, '
      + '@instance_ids (the instances the run is about, an int[]). A procedure report is called with the parameters given a value, by name. '
      + 'One statement on PostgreSQL; a batch on SQL Server (no GO lines).'));

  // a parameter's picker (DBA Dash's Edit Pickers, L95): a list (its values one per line), a text box, or a query whose
  // first column is the value and second the words, run on the report's target; on the menu bar or under the parameters
  const pickerKinds: Record<string, string> = { '': 'none (a plain field)', list: 'a list', text: 'a text box (Enter runs)', query: 'a query\'s values' };
  const params = rowsEditor<Param>('Parameters', ['name', 'type', 'label', 'default', 'required', 'picker', 'its values (one per line) or its query', 'menu bar'], def.params, (x, n) => {
    const a = inp(`Parameter ${n} name`, x.name), t = sel(`Parameter ${n} type`, typeNames, x.type ?? 'text'), l = inp(`Parameter ${n} label`, x.label),
      dv = inp(`Parameter ${n} default`, x.default), rq = check(`Parameter ${n} required`, x.required),
      pk = sel(`Parameter ${n} picker`, pickerKinds, x.picker?.kind ?? ''),
      pv = el('textarea', { 'aria-label': `Parameter ${n} picker values (one per line) or query`, rows: '2', cols: '28', spellcheck: 'false' },
        x.picker?.kind === 'query' ? x.picker.query ?? '' : (x.picker?.values ?? []).join('\n')) as HTMLTextAreaElement,
      mb = check(`Parameter ${n} picker on the menu bar`, x.picker?.menu);
    const picker = (): Picker | undefined => {
      const k = pk.value as Picker['kind'] | '';
      if (!k) return undefined;
      const menu = mb.checked || undefined;
      if (k === 'list') return { kind: k, values: pv.value.split('\n').map(v => v.trim()).filter((v, i, all) => v !== '' && all.indexOf(v) === i), menu };
      if (k === 'query') return { kind: k, query: pv.value.trim(), menu };
      return { kind: k, menu };
    };
    return { cells: [a, t, l, dv, rq, pk, pv, mb], read: () => ({ name: a.value.trim(), type: t.value, label: l.value.trim() || undefined, default: dv.value.trim() || undefined, required: rq.checked || undefined, picker: picker() }) };
  }, { type: 'text' });
  const columns = rowsEditor<ColFmt>('Column formats', ['result set', 'column', 'label', 'format', 'decimals', 'hidden'], def.columns, (x, n) => {
    const s = inp(`Format ${n} result set (1 = the first)`, (x.set ?? 0) + 1, { size: '3', inputmode: 'numeric' }), c = inp(`Format ${n} column`, x.column),
      l = inp(`Format ${n} label`, x.label), f = sel(`Format ${n} format`, formatNames, x.format ?? ''), dd = inp(`Format ${n} decimals`, x.decimals, { size: '3', inputmode: 'numeric' }),
      h = check(`Format ${n} hidden`, x.hidden);
    return { cells: [s, c, l, f, dd, h], read: () => ({ set: Math.max(0, Number(s.value || 1) - 1), column: c.value.trim(), label: l.value.trim() || undefined, format: f.value || undefined, decimals: dd.value.trim() === '' ? undefined : Number(dd.value), hidden: h.checked || undefined }) };
  }, { set: 0 });
  const rules = rowsEditor<Rule>('Colour rules (the first that matches colours the cell)', ['result set', 'colour the column', 'judged on (empty = the same)', 'when', 'value', 'and', 'status', 'case-sensitive'], def.rules, (x, n) => {
    const s = inp(`Rule ${n} result set (1 = the first)`, (x.set ?? 0) + 1, { size: '3', inputmode: 'numeric' }), c = inp(`Rule ${n} column it colours`, x.column),
      e = inp(`Rule ${n} column judged`, x.eval), k = sel(`Rule ${n} condition`, condNames, x.cond ?? 'gt'), v1 = inp(`Rule ${n} value`, x.value1, { size: '10' }),
      v2 = inp(`Rule ${n} second value (between)`, x.value2, { size: '10' }), st = sel(`Rule ${n} status`, statusNames, x.status ?? 'warn'), cs = check(`Rule ${n} case-sensitive`, x.case_sensitive);
    return { cells: [s, c, e, k, v1, v2, st, cs], read: () => ({ set: Math.max(0, Number(s.value || 1) - 1), column: c.value.trim(), eval: e.value.trim() || undefined, cond: k.value, value1: v1.value || undefined, value2: v2.value || undefined, status: st.value, case_sensitive: cs.checked || undefined }) };
  }, { set: 0, cond: 'gt', status: 'warn' });
  sec.append(params.box, columns.box, rules.box);

  // who sees the report (DBA Dash's Visibility..., L84) and who opens it (its access, L85: a list of role names)
  const insts = await instances().catch(() => [] as Inst[]);
  const vis = def.visibility ?? {};
  const box = (label: string, on: boolean) => { const c = el('input', { type: 'checkbox', 'aria-label': label }) as HTMLInputElement; c.checked = on; return c; };
  const engBoxes = [['postgres', 'PostgreSQL'], ['sqlserver', 'SQL Server']].map(([k, l]) => ({ k, c: box(l, !!vis.engines?.includes(k)), l }));
  const allTags = [...new Set(insts.flatMap(i => i.tags))].sort();
  const tagBoxes = allTags.map(t => ({ k: t, c: box('Tag ' + t, !!vis.tags?.includes(t)), l: t }));
  const multi = (label: string, chosen: string[] = []) => { const s = el('select', { multiple: '', size: '6', 'aria-label': label }) as HTMLSelectElement;
    for (const i of insts) { const o = el('option', { value: i.name }, i.name) as HTMLOptionElement; o.selected = chosen.includes(i.name); s.append(o); } return s; };
  const inc = multi('Include instances', vis.include), exc = multi('Exclude instances', vis.exclude);
  const filterBox = el('input', { type: 'search', 'aria-label': 'Filter the instance lists', size: '20' }) as HTMLInputElement;
  filterBox.addEventListener('input', () => { for (const s of [inc, exc]) for (const o of s.options) o.hidden = !!filterBox.value && !o.value.toLowerCase().includes(filterBox.value.toLowerCase()); });
  const picked = (s: HTMLSelectElement) => [...s.selectedOptions].map(o => o.value);
  const readVis = (): Visibility | undefined => {
    const v: Visibility = { engines: engBoxes.filter(b => b.c.checked).map(b => b.k), tags: tagBoxes.filter(b => b.c.checked).map(b => b.k), include: picked(inc), exclude: picked(exc) };
    return v.engines!.length || v.tags!.length || v.include!.length || v.exclude!.length ? v : undefined;
  };
  const warn = el('p', { class: 'meta warn', role: 'status' });
  const recheck = () => { const v = readVis(); warn.textContent = v && !insts.some(i => matches(v, i)) ? 'These rules match no instance: the report is listed on none of them (only on the fleet).' : ''; };
  const clear = el('button', { type: 'button' }, 'Clear Rules');
  clear.addEventListener('click', () => { for (const b of [...engBoxes, ...tagBoxes]) b.c.checked = false; for (const s of [inc, exc]) for (const o of s.options) o.selected = false; recheck(); });
  const visField = el('fieldset', {}, el('legend', {}, 'Visibility (where the report is listed; no rule = everywhere)'),
    el('p', {}, 'Instance types ', ...engBoxes.flatMap(b => [el('label', {}, b.c, ' ' + b.l), ' '])),
    allTags.length ? el('p', {}, 'Tags (any value of the tag) ', ...tagBoxes.flatMap(b => [el('label', {}, b.c, ' ' + b.l), ' '])) : el('p', { class: 'meta' }, 'No instance carries a tag.'),
    el('p', {}, el('label', {}, 'Filter ', filterBox)),
    el('div', { class: 'toolbar' }, el('label', {}, 'Include (always listed) ', inc), el('label', {}, 'Exclude (never listed) ', exc)),
    el('p', {}, clear), warn);
  visField.addEventListener('change', recheck); recheck();
  const roles = [['viewer', 'Viewer'], ['operator', 'Operator'], ['admin', 'Admin']].map(([k, l]) => ({ k, c: box('Access ' + l, !!def.access?.includes(k)), l }));
  const accField = el('fieldset', {}, el('legend', {}, 'Access (the roles that open and run it; none ticked = every role; an admin always may)'),
    el('p', {}, ...roles.flatMap(b => [el('label', {}, b.c, ' ' + b.l), ' '])));
  sec.append(visField, accField);
  // the run's own messages as its status (L90) and the collections its data comes from (Associate Collection, L98)
  const fromMsgs = check('Status from messages', def.status_from_messages);
  const colls = inp('Associate Collection (comma-separated)', (def.collections ?? []).join(', '), { size: '40', placeholder: 'activity, waits' });
  sec.append(el('fieldset', {}, el('legend', {}, 'The run'),
    el('p', {}, el('label', {}, fromMsgs, ' Status from messages: the run\'s own RAISE NOTICE / INFO (PostgreSQL) or PRINT and RAISERROR (SQL Server) messages are its status in place of \'Completed\'')),
    el('p', {}, el('label', {}, 'Associate Collection (the collections the report\'s data comes from, comma-separated; its Trigger Collection button names them) ', colls))));
  // the page's link (DBA Dash's URL label, L107) and the switch button to a paired report (L106)
  const urlIn = inp('URL (http or https; opens in a new tab)', def.url, { size: '50', placeholder: 'https://wiki.example/runbook' });
  const urlLabel = inp('URL label (empty = the URL itself)', def.url_label, { size: '30' });
  const pairId = inp('Switch to report (its number)', def.pair?.report_id, { size: '6', inputmode: 'numeric' });
  const pairLabel = inp('Switch button words', def.pair?.label, { size: '20', placeholder: 'Charts' });
  sec.append(el('fieldset', {}, el('legend', {}, 'The page'),
    el('div', { class: 'toolbar' }, el('label', {}, 'URL ', urlIn), el('label', {}, 'URL label ', urlLabel)),
    el('div', { class: 'toolbar' }, el('label', {}, 'Switch to report ', pairId), el('label', {}, 'Switch button words ', pairLabel)),
    el('p', { class: 'meta' }, 'The switch button opens the other report on the same target with the parameters both reports declare; Back returns. '
      + (def.sets?.length ? 'The result sets\' names are kept as they are (Rename on the report\'s page).' : ''))));
  // the charts (DBA Dash L130): each drawn from a result set; Add Chart here or on the report's page after a run
  let charts: ChartDef[] = [...(def.charts ?? [])];
  const chartList = el('ul', { class: 'cr-chart-list' });
  const listCharts = () => chartList.replaceChildren(...(charts.length ? charts.map((c, i) => {
    const rm = el('button', { type: 'button', class: 'link' }, 'Remove');
    rm.addEventListener('click', () => { charts = charts.filter((_, j) => j !== i); listCharts(); });
    return el('li', {}, `${chartTypeNames[c.type]}: ${c.title || `${c.metrics.join(', ')} by ${c.x}`} (result set ${c.set + 1}) `, rm);
  }) : [el('li', { class: 'meta' }, 'No chart.')]));
  const addChart = el('button', { type: 'button' }, 'Add Chart');
  addChart.addEventListener('click', () => { void chartDialog([], params.read().map(p => p.name).filter(Boolean)).then(c => { if (c) { charts = [...charts, c]; listCharts(); } }); });
  listCharts();
  sec.append(el('fieldset', {}, el('legend', {}, 'Charts'), chartList, addChart,
    def.system_charts?.length ? el('p', { class: 'meta' }, `System charts kept: ${def.system_charts.join(', ')} (Add System Chart on the report's page).`) : ''));

  const msg = el('p', { class: 'meta', role: 'status' });
  const save = markNeed(el('button', { type: 'button' }, 'Save'), 'customreports');
  if (saveOff) offControl(save, saveWhy || 'saving is off on this server', saveOff);
  save.addEventListener('click', async () => {
    const out: ReportDef & { op: string } = {
      op: id ? 'edit' : 'add', report_id: id || undefined, version: def.version, name: name.value, description: desc.value, folder: fold.value,
      engine: engine.value, kind: kind.value, body: body.value, params: params.read(), columns: columns.read(), rules: rules.read(),
      timeout_secs: Number(timeout.value || 30), max_rows: Number(maxRows.value || 5000),
      visibility: readVis(), access: roles.filter(b => b.c.checked).map(b => b.k),
      status_from_messages: fromMsgs.checked || undefined,
      collections: colls.value.split(',').map(c => c.trim()).filter(Boolean),
      sets: def.sets,   // named on the report's page: kept as they are
      charts: charts.length ? charts : undefined, system_charts: def.system_charts, layout: def.layout, links: def.links,
      url: urlIn.value.trim() || undefined, url_label: urlLabel.value.trim() || undefined,
      pair: pairId.value.trim() ? { report_id: Number(pairId.value), label: pairLabel.value.trim() } : undefined,
    };
    try {
      const r = await post<{ detail: string; report_id: number }>('customreports', out);
      msg.textContent = r.detail;
      reloadTree('r/reports/cr');   // the tree's Custom reports nodes show the new or renamed report at once
      go({ report: String(r.report_id ?? id) });
    } catch (e) { msg.textContent = 'Not saved: ' + (e instanceof Error ? e.message : String(e)); }
  });
  const cancel = el('a', { href: (id ? `#/customreports?report=${id}` : '#/customreports') + (tagQ(ctx) ? (id ? '&' : '?') + tagQ(ctx) : '') }, 'Cancel');
  sec.append(el('div', { class: 'toolbar' }, save, cancel), msg);
  return sec;
}
