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
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid } from './ui';

export interface Param { name: string; type: string; label?: string; default?: string; required?: boolean }
export interface ColFmt { set: number; column: string; label?: string; format?: string; decimals?: number; hidden?: boolean }
export interface Rule { set: number; column: string; eval?: string; cond: string; value1?: string; value2?: string; status: string; case_sensitive?: boolean }
export interface ReportDef {
  report_id?: number; name: string; description?: string; folder: string; engine: string; kind: string; body: string;
  params: Param[]; columns: ColFmt[]; rules: Rule[]; timeout_secs: number; max_rows: number; version?: number;
}
export interface ResultSet { columns: string[]; types: string[]; rows: unknown[][]; truncated?: boolean }
export interface InstanceRun { instance_id?: number; instance: string; engine: string; outcome: string; error?: string; duration_ms: number; rows: number; sets: ResultSet[] }
interface State { enabled: boolean; reason?: string }

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
    const kind = run.outcome === 'done' ? 'ok' : run.outcome === 'refused' ? 'warn' : 'crit';
    box.append(head, el('p', { class: 'meta' }, badge(run.outcome, kind),
      ` ${fmtNum(run.rows)} rows in ${fmtNum(run.duration_ms)} ms${run.sets.length > 1 ? `, ${run.sets.length} result sets` : ''}`));
    if (run.error) box.append(errorBox(run.error));
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

function defOf(r: Row): ReportDef {
  const arr = <T>(v: unknown): T[] => Array.isArray(v) ? v as T[] : [];
  return {
    report_id: Number(r.report_id), name: String(r.name ?? ''), description: r.description == null ? '' : String(r.description),
    folder: String(r.folder ?? ''), engine: String(r.engine), kind: String(r.kind), body: String(r.body ?? ''),
    params: arr<Param>(r.params), columns: arr<ColFmt>(r.columns), rules: arr<Rule>(r.rules),
    timeout_secs: Number(r.timeout_secs ?? 30), max_rows: Number(r.max_rows ?? 5000), version: Number(r.version ?? 1),
  };
}

function hashParams(): URLSearchParams { return new URLSearchParams(location.hash.split('?')[1] ?? ''); }
function go(q: Record<string, string>) {
  const keep = hashParams(), out = new URLSearchParams();
  for (const k of ['i', 'w', 'from', 'to', 'tag']) { const v = keep.get(k); if (v) out.set(k, v); }
  for (const [k, v] of Object.entries(q)) out.set(k, v);
  location.hash = '#/customreports' + (out.toString() ? '?' + out : '');
}

interface Inst { id: number; name: string; engine: string; tags: string[] }
async function instances(): Promise<Inst[]> {
  const t = await get<Table>('instances');
  return rowsOf(t).map(r => ({ id: Number(r.instance_id), name: String(r.name), engine: String(r.engine ?? 'postgres'), tags: Array.isArray(r.tags) ? (r.tags as unknown[]).map(String) : [] }));
}

const logCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'ui_user', label: 'who' },
  { key: 'op', label: 'what' },
  { key: 'report_name', label: 'report' },
  { key: 'instance', label: 'ran on' },
  { key: 'outcome', fmt: v => badge(String(v ?? ''), v === 'done' ? 'ok' : v === 'refused' ? 'warn' : 'crit') },
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
  const d = await get<{ state: State; folders: Table | null; reports: Table | null; log: Table | null }>('customreports');
  const reports = rowsOf(d.reports).map(defOf);
  const folders = folderTree(rowsOf(d.folders).map(r => String(r.folder)));
  const sec = el('section', {}, el('h2', {}, 'Custom reports'));
  const msg = el('p', { class: 'meta', role: 'status' });
  const newBtn = el('button', { type: 'button' }, 'New report'), folderBtn = el('button', { type: 'button' }, 'New folder');
  if (!d.state.enabled) { newBtn.setAttribute('disabled', ''); folderBtn.setAttribute('disabled', ''); }
  newBtn.addEventListener('click', () => go({ new: '1' }));
  const folderIn = el('input', { type: 'text', 'aria-label': 'New folder path (parts joined by /)', placeholder: 'Ops/Daily' }) as HTMLInputElement;
  folderBtn.addEventListener('click', async () => {
    try { const r = await post<{ detail: string }>('customreports', { op: 'folder_add', folder: folderIn.value }); msg.textContent = r.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  sec.append(el('div', { class: 'toolbar' }, newBtn, el('span', {}, folderIn, ' ', folderBtn)), msg);
  if (!d.state.enabled) sec.append(el('p', { class: 'meta' }, 'Saving and running are off here: ' + (d.state.reason ?? '')));
  sec.append(el('p', { class: 'meta' }, 'Each report is the DBA\'s own SQL (or a procedure) with its parameters, column formats and colour rules, in folders every user shares. '
    + 'A report on the repository reads pgvigil\'s own tables; a PostgreSQL or SQL Server report runs read-only on a chosen instance or on a tag\'s instances, '
    + 'under its timeout and a 2 s lock timeout, and every run is audited (the log below).'));
  if (ctx.instance) sec.append(el('p', { class: 'meta' }, 'Opened from an instance: a report run from here goes to that instance (a repository report: about it).'));

  const byFolder = (f: string) => reports.filter(r => r.folder === f);
  const reportCols: Col[] = [
    { key: 'name', label: 'report', fmt: (v, r) => el('a', { href: `#/customreports?report=${String(r.report_id)}${ctx.instance ? '&i=' + ctx.instance : ''}` }, String(v)) },
    { key: 'engine', label: 'runs on', fmt: v => engineName[String(v)] ?? String(v) },
    { key: 'kind', fmt: v => v === 'procedure' ? 'procedure' : 'SQL' },
    { key: 'description', wide: true },
    { key: 'updated_by', label: 'changed by' },
    { key: 'updated_at', label: 'changed', fmt: fmtTime },
    { key: 'actions', label: 'actions', fmt: (_v, r) => reportActions(r as unknown as ReportDef, folders, msg, d.state.enabled) },
  ];
  const tops = byFolder('');
  sec.append(el('h3', {}, 'Top level'), grid(tops as unknown as Row[], reportCols, 'No report at the top level.'));
  for (const f of folders) {
    const depth = f.split('/').length - 1;
    const h = el('h3', { style: `margin-left:${depth * 1.2}rem` }, 'Folder ' + f);
    sec.append(h, folderActions(f, msg, d.state.enabled),
      grid(byFolder(f) as unknown as Row[], reportCols, 'No report in this folder.'));
  }
  if (!reports.length) sec.append(el('p', { class: 'empty' }, 'No custom report yet: New report saves the first one.'));
  sec.append(el('h3', {}, 'Recent activity'), grid(rowsOf(d.log), logCols, 'Nothing was saved or run yet.'));
  return sec;
}

// reportActions: Open, Edit, Move to folder, Delete (a second click confirms)
function reportActions(r: ReportDef, folders: string[], msg: HTMLElement, on: boolean): HTMLElement {
  const box = el('span', { class: 'row-actions' });
  const id = String(r.report_id);
  const edit = el('button', { type: 'button', class: 'link' }, 'Edit');
  edit.addEventListener('click', () => go({ edit: id }));
  const listId = 'crf-' + id;
  const to = el('input', { type: 'text', list: listId, 'aria-label': `Move ${r.name} to the folder`, placeholder: 'folder (empty = top)', size: '14' }) as HTMLInputElement;
  const dl = el('datalist', { id: listId }, ...folders.map(f => el('option', { value: f })));
  const move = el('button', { type: 'button', class: 'link' }, 'Move to folder');
  move.addEventListener('click', async () => {
    try { const x = await post<{ detail: string }>('customreports', { op: 'move', report_id: r.report_id, folder: to.value }); msg.textContent = x.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  const del = el('button', { type: 'button', class: 'link' }, 'Delete');
  let armed = false;
  del.addEventListener('click', async () => {
    if (!armed) { armed = true; del.textContent = `Delete ${r.name}: click again`; return; }
    try { const x = await post<{ detail: string }>('customreports', { op: 'delete', report_id: r.report_id }); msg.textContent = x.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  if (!on) for (const b of [edit, move, del]) b.setAttribute('disabled', '');
  box.append(edit, ' ', to, dl, ' ', move, ' ', del);
  return box;
}

function folderActions(f: string, msg: HTMLElement, on: boolean): HTMLElement {
  const name = el('input', { type: 'text', value: f, 'aria-label': `New path of the folder ${f}`, size: '18' }) as HTMLInputElement;
  const ren = el('button', { type: 'button', class: 'link' }, 'Rename');
  ren.addEventListener('click', async () => {
    try { const x = await post<{ detail: string }>('customreports', { op: 'folder_rename', folder: f, new_folder: name.value }); msg.textContent = x.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  const del = el('button', { type: 'button', class: 'link' }, 'Delete folder');
  del.addEventListener('click', async () => {
    try { const x = await post<{ detail: string }>('customreports', { op: 'folder_delete', folder: f }); msg.textContent = x.detail; location.reload(); }
    catch (e) { msg.textContent = e instanceof Error ? e.message : String(e); }
  });
  const add = el('button', { type: 'button', class: 'link' }, 'New report here');
  add.addEventListener('click', () => go({ new: '1', folder: f }));
  if (!on) for (const b of [ren, del, add]) b.setAttribute('disabled', '');
  return el('div', { class: 'toolbar' }, el('span', {}, name, ' ', ren), del, add);
}

// paramInput is one parameter's field, filled from the address (p.<name>) or its default
function paramInput(p: Param, q: URLSearchParams): HTMLInputElement {
  const v = q.get('p.' + p.name) ?? p.default ?? '';
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
  const crumbs = el('p', { class: 'meta' }, el('a', { href: '#/customreports' + (ctx.instance ? '?i=' + ctx.instance : '') }, 'Custom reports'),
    def.folder ? ' / ' + def.folder.split('/').join(' / ') : '', ` - runs on ${engineName[def.engine] ?? def.engine}, version ${def.version}`);
  sec.append(crumbs);
  if (def.description) sec.append(el('p', {}, def.description));

  // the target: the store runs about one instance, a tag's or every active one; an instance report on one instance or a tag's
  const mine = insts.filter(i => def.engine === 'store' || i.engine === def.engine);
  const tags = [...new Set(mine.flatMap(i => i.tags))].sort();
  const target = el('select', { 'aria-label': 'Run on' }) as HTMLSelectElement;
  if (def.engine === 'store') target.append(el('option', { value: 'fleet' }, 'every active instance'));
  target.append(el('option', { value: 'instance' }, 'one instance'));
  if (tags.length) target.append(el('option', { value: 'tag' }, 'the instances of a tag'));
  const instSel = el('select', { 'aria-label': 'Instance' }) as HTMLSelectElement;
  for (const i of mine) instSel.append(el('option', { value: String(i.id) }, i.name));
  const tagSel = el('select', { 'aria-label': 'Tag' }) as HTMLSelectElement;
  for (const t of tags) tagSel.append(el('option', { value: t }, t));
  const want = Number(q.get('i') ?? ctx.instance ?? 0);
  if (want && mine.some(i => i.id === want)) { instSel.value = String(want); target.value = 'instance'; }
  else if (q.get('tag') && tags.includes(q.get('tag')!)) { tagSel.value = q.get('tag')!; target.value = 'tag'; }
  else if (def.engine !== 'store') target.value = 'instance';
  const instBox = el('label', {}, 'Instance ', instSel), tagBox = el('label', {}, 'Tag ', tagSel);
  const showTarget = () => { instBox.hidden = target.value !== 'instance'; tagBox.hidden = target.value !== 'tag'; };
  target.addEventListener('change', showTarget); showTarget();

  const inputs = def.params.map(p => paramInput(p, q));
  const runBtn = el('button', { type: 'button' }, 'Run');
  if (!d.state.enabled) runBtn.setAttribute('disabled', '');
  const editBtn = el('a', { href: `#/customreports?edit=${def.report_id}` }, 'Edit this report');
  const form = el('div', { class: 'toolbar' }, el('label', {}, 'Run on ', target), instBox, tagBox,
    ...def.params.map((p, i) => el('label', {}, `${p.label || p.name} `, inputs[i])), runBtn, editBtn);
  sec.append(form);
  if (!d.state.enabled) sec.append(el('p', { class: 'meta' }, 'Running is off here: ' + (d.state.reason ?? '')));
  if (!mine.length) sec.append(el('p', { class: 'empty' }, `No active ${def.engine === 'sqlserver' ? 'SQL Server' : 'PostgreSQL'} instance to run it on.`));
  const status = el('p', { class: 'meta', role: 'status' });
  const out = el('div', {});
  sec.append(status, out);

  const run = async () => {
    status.textContent = 'Running...';
    runBtn.setAttribute('disabled', '');
    const w = window_(ctx);
    const params: Record<string, string> = {};
    def.params.forEach((p, i) => { params[p.name] = inputs[i].value; });
    try {
      const r = await post<{ runs: InstanceRun[]; ran_at: string }>('customreports/run', {
        report_id: def.report_id, target: target.value, instance_id: Number(instSel.value), tag: tagSel.value, from: w.from, to: w.to, params,
      });
      out.replaceChildren(resultView(r.runs, def, def.name));
      status.textContent = `Ran at ${fmtTime(r.ran_at)}.`;
    } catch (e) {
      out.replaceChildren(errorBox(e));
      status.textContent = '';
    } finally {
      if (d.state.enabled) runBtn.removeAttribute('disabled');
    }
  };
  runBtn.addEventListener('click', () => { void run(); });
  // a repository report runs on open (DBA Dash's custom reports run when opened); an instance report on the button,
  // or on open when the address says run=1 (a mailed or linked page)
  if (d.state.enabled && mine.length && (def.engine === 'store' || q.get('run') === '1')) await run();

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

async function editorPage(_ctx: Ctx, id: number, folder = ''): Promise<HTMLElement> {
  const list = await get<{ state: State; folders: Table | null; reports: Table | null }>('customreports');
  let def: ReportDef = { name: '', description: '', folder, engine: 'store', kind: 'sql', body: '', params: [], columns: [], rules: [], timeout_secs: 30, max_rows: 5000 };
  if (id) {
    const d = await get<{ report: Table | null }>('customreports', { report: id });
    const r = rowsOf(d.report);
    if (!r.length) return el('p', { class: 'empty' }, `No report ${id}.`);
    def = defOf(r[0]);
  }
  const sec = el('section', {}, el('h2', {}, id ? `Edit ${def.name}` : 'New custom report'));
  if (!list.state.enabled) sec.append(el('p', { class: 'meta' }, 'Saving is off here: ' + (list.state.reason ?? '')));
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

  const msg = el('p', { class: 'meta', role: 'status' });
  const save = el('button', { type: 'button' }, 'Save');
  if (!list.state.enabled) save.setAttribute('disabled', '');
  save.addEventListener('click', async () => {
    const out: ReportDef & { op: string } = {
      op: id ? 'edit' : 'add', report_id: id || undefined, version: def.version, name: name.value, description: desc.value, folder: fold.value,
      engine: engine.value, kind: kind.value, body: body.value, params: params.read(), columns: columns.read(), rules: rules.read(),
      timeout_secs: Number(timeout.value || 30), max_rows: Number(maxRows.value || 5000),
    };
    try {
      const r = await post<{ detail: string; report_id: number }>('customreports', out);
      msg.textContent = r.detail;
      reloadTree('r/reports/cr');   // the tree's Custom reports nodes show the new or renamed report at once
      go({ report: String(r.report_id ?? id) });
    } catch (e) { msg.textContent = 'Not saved: ' + (e instanceof Error ? e.message : String(e)); }
  });
  const cancel = el('a', { href: id ? `#/customreports?report=${id}` : '#/customreports' }, 'Cancel');
  sec.append(el('div', { class: 'toolbar' }, save, cancel), msg);
  return sec;
}
