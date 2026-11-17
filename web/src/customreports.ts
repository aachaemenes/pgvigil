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
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, offControl } from './ui';
import { Can, markNeed, routeWhy } from './needs';

// picker: how the run's form offers the value (DBA Dash's Pickers, L95) - a list, a text box (Enter runs) or a query's
// values (its first column the value, its second the words); menu = on the run's toolbar first
export interface Picker { kind: 'list' | 'text' | 'query'; values?: string[]; query?: string; menu?: boolean }
export interface Param { name: string; type: string; label?: string; default?: string; required?: boolean; picker?: Picker }
export interface ColFmt { set: number; column: string; label?: string; format?: string; decimals?: number; hidden?: boolean }
export interface Rule { set: number; column: string; eval?: string; cond: string; value1?: string; value2?: string; status: string; case_sensitive?: boolean }
export interface ReportDef {
  report_id?: number; name: string; description?: string; folder: string; engine: string; kind: string; body: string;
  params: Param[]; columns: ColFmt[]; rules: Rule[]; timeout_secs: number; max_rows: number; version?: number;
  visibility?: Visibility; access?: string[];   // 0372's view: who sees it, which roles open it (a list: Q160 is open)
  status_from_messages?: boolean;               // the run's own NOTICE / PRINT messages as its status (L90)
  collections?: string[];                       // the collections its data comes from (Associate Collection, L98)
}
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

function fmtCell(v: unknown, type: string, f?: ColFmt): string {
  if (v == null) return '';
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

// setGrid draws one result set with the report's formats and colour rules
export function setGrid(set: ResultSet, idx: number, cols: ColFmt[] = [], rules: Rule[] = []): HTMLElement {
  const rows = set.rows.map(r => Object.fromEntries(r.map((v, i) => ['c' + i, v])));
  const gcols: Col[] = [];
  set.columns.forEach((name, i) => {
    const f = cols.find(c => c.set === idx && c.column.toLowerCase() === name.toLowerCase());
    if (f?.hidden) return;
    const type = set.types[i] ?? 'text';
    const hasRule = rules.some(r => r.set === idx && r.column.toLowerCase() === name.toLowerCase());
    gcols.push({
      key: 'c' + i, label: f?.label || name || `(column ${i + 1})`,
      num: f?.format ? numericFormat.has(f.format) : type === 'number',
      wide: type === 'text' && !f?.format,
      fmt: v => fmtCell(v, type, f),
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
type ViewKeys = Pick<ReportDef, 'visibility' | 'access' | 'status_from_messages' | 'collections'>;
function viewOf(v: unknown): ViewKeys {
  const o = v && typeof v === 'object' && !Array.isArray(v) ? v as Record<string, unknown> : {};
  const out: ViewKeys = {};
  if (o.visibility && typeof o.visibility === 'object') out.visibility = o.visibility as Visibility;
  if (Array.isArray(o.access) && o.access.length) out.access = o.access.map(String);
  if (o.status_from_messages === true) out.status_from_messages = true;
  if (Array.isArray(o.collections) && o.collections.length) out.collections = o.collections.map(String);
  return out;
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
  const form = el('div', { class: 'toolbar' }, el('label', {}, 'Run on ', target), instBox, tagBox,
    ...order.map(i => labels[i]), runBtn, cancelBtn, ...(trigBtn ? [trigBtn] : []), editBtn);
  sec.append(form);
  if (trigBtn) { sec.append(trigOff); trigWords(); }
  if (folderTag) sec.append(el('p', { class: 'meta' }, `Opened from ${folderWords(folderTag)}: a run from here goes to its instances`
    + (runTag ? '.' : ', one at a time (the folder is no tag a run can name).')));
  if (runWhy) sec.append(runOff);
  if (storeTextRun) sec.append(storeTextRun);
  if (def.engine === 'store' && !mine.length) sec.append(el('p', { class: 'empty' }, folderTag ? `No active instance in ${folderWords(folderTag)}.` : 'No active instance: a run reads none.'));
  const status = el('p', { class: 'meta', role: 'status' });
  const out = el('div', {});
  sec.append(status, out);

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
      out.replaceChildren(resultView(r.runs, def, def.name));
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
  const retarget = () => { trigWords(); void loadPickers(); };
  for (const x of [target, instSel, tagSel]) x.addEventListener('change', retarget);
  await loadPickers();
  // a repository report runs on open (DBA Dash's custom reports run when opened); an instance report on the button,
  // or on open when the address says run=1 (a mailed or linked page)
  // a run only where it may: a store report without its login is not run on open (no refused row per page view); its
  // off words stand in the page, and a mailed render carries them (reportmail.ts notesOf reads p.said)
  if (d.state.enabled && !runWhy && (mine.length || gone) && (def.engine === 'store' || q.get('run') === '1')) await run();

  const det = el('details', {}, el('summary', {}, 'Definition'));
  det.append(el('pre', { class: 'sql', tabindex: '0' }, def.kind === 'procedure' ? 'procedure ' + def.body : def.body));
  if (def.params.length) det.append(el('h3', {}, 'Parameters'), grid(def.params as unknown as Row[], [
    { key: 'name' }, { key: 'type', fmt: v => typeNames[String(v)] ?? String(v) }, { key: 'label' }, { key: 'default' }, { key: 'required', fmt: v => v ? 'yes' : '' }]));
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

  const params = rowsEditor<Param>('Parameters', ['name', 'type', 'label', 'default', 'required'], def.params, (x, n) => {
    const a = inp(`Parameter ${n} name`, x.name), t = sel(`Parameter ${n} type`, typeNames, x.type ?? 'text'), l = inp(`Parameter ${n} label`, x.label),
      dv = inp(`Parameter ${n} default`, x.default), rq = check(`Parameter ${n} required`, x.required);
    return { cells: [a, t, l, dv, rq], read: () => ({ name: a.value.trim(), type: t.value, label: l.value.trim() || undefined, default: dv.value.trim() || undefined, required: rq.checked || undefined }) };
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

  const msg = el('p', { class: 'meta', role: 'status' });
  const save = markNeed(el('button', { type: 'button' }, 'Save'), 'customreports');
  if (saveOff) offControl(save, saveWhy || 'saving is off on this server', saveOff);
  save.addEventListener('click', async () => {
    const out: ReportDef & { op: string } = {
      op: id ? 'edit' : 'add', report_id: id || undefined, version: def.version, name: name.value, description: desc.value, folder: fold.value,
      engine: engine.value, kind: kind.value, body: body.value, params: params.read(), columns: columns.read(), rules: rules.read(),
      timeout_secs: Number(timeout.value || 30), max_rows: Number(maxRows.value || 5000),
      visibility: readVis(), access: roles.filter(b => b.c.checked).map(b => b.k),
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
