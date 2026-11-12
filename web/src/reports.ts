// The Reports tree (task 169; the stock reports of DBA Dash's Reports folder, F301-F308): a Reports folder at the root
// and on each instance, one page per report with the grids, columns, filters and toolbar of the window it mirrors, on
// both engines. A report with a PostgreSQL twin shows both engines in the same grids (the engine column says which);
// a report with none says 'SQL Server only' once. Every grid is ui.ts's grid() (the grid menu, the filters, the grid
// tools), named by its h3, so the shell's Export .xlsx gives one sheet per grid. Data: /api/reports?r=<report>
// (internal/web/q_reports.go); New / Deleted Databases read /api/dbchanges, the PostgreSQL deadlocks /api/pg/deadlocks
// and the PostgreSQL table sizes /api/tablesize, as their own pages do.
import { get, Row, rowsOf, Table } from './api';
import { donutChart, lineChart, Slice } from './chart';
import { deadlockSvg, DlGraph, graphFromRows, graphFromXml } from './deadlock_graph';
import { hrefWith } from './dbinfo';
import { fleet, tagsOf } from './fleet';
import type { Ctx } from './router';
import { href, rangeLabel, window_ } from './router';
import { sqlCell } from './sqlview';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid } from './ui';

type Render = (c: Ctx) => Promise<HTMLElement>;

// the reports by route, in the order of DBA Dash's Reports folder (the root's); router.ts' Reports groups (the lead's
// file) list the ones the root, a SQL Server instance (all but Deadlock Charts, Deadlocks, Query Stats Charts, Query
// Stats and Recycle Bin: the instance has those as tabs of its own) and a PostgreSQL instance (those, less Flushed
// Plans and Server Services: no twin) show
export const reportTabs: Record<string, string> = {
  rp_props: 'Database Extended Properties', rp_finder: 'Database Finder', rp_dlcharts: 'Deadlock Charts', rp_deadlocks: 'Deadlocks',
  rp_dbdeleted: 'Deleted Databases', rp_failed: 'Failed Logins', rp_flushed: 'Flushed Plans', rp_killed: 'Killed Sessions',
  rp_dbnew: 'New Databases', rp_qscharts: 'Query Stats Charts', rp_qs: 'Query Stats', rp_actions: 'User Actions',
  rp_roles: 'Server Role Members', rp_services: 'Server Services', rp_pwage: 'SQL Login Password Age', rp_tables: 'Table Size',
  rp_recycle: 'Recycle Bin',
};
const text = (v: unknown) => v == null ? '' : String(v);
const lsGet = (k: string) => { try { return localStorage.getItem('pgvigil.rp.' + k); } catch { return null; } };
const lsSet = (k: string, v: string) => { try { localStorage.setItem('pgvigil.rp.' + k, v); } catch { /* private window */ } };
const engName = (v: unknown) => v === 'sqlserver' ? 'SQL Server' : 'PostgreSQL';
const yes = (v: unknown) => v === true ? 'Y' : v === false ? 'N' : '';
const kb = (v: unknown) => v == null ? '' : fmtNum(Math.round(Number(v)));

// ---- the scope: one instance, a tag folder's instances, or the fleet

interface Scope { params: Record<string, string | number | undefined>; ids?: Set<number>; engines: Set<string>; count: number }
async function scopeOf(ctx: Ctx): Promise<Scope> {
  const f = await fleet();
  let rows = f.instances;
  if (ctx.instance) rows = rows.filter(r => Number(r.instance_id) === ctx.instance);
  else if (ctx.tag) rows = rows.filter(r => ctx.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(ctx.tag!));
  const ids = new Set(rows.map(r => Number(r.instance_id)));
  const engines = new Set(rows.map(r => r.engine === 'sqlserver' ? 'sqlserver' : 'postgres'));
  const params = ctx.instance ? { instance: ctx.instance } : ctx.tag ? { instances: [...ids].join(',') || '0' } : {};
  return { params, ids: ctx.instance || ctx.tag ? ids : undefined, engines, count: rows.length };
}
const inScope = (s: Scope) => (r: Row) => !s.ids || s.ids.has(Number(r.instance_id));
const groupsOf = async (): Promise<Map<number, string>> => new Map((await fleet()).instances.map(r => [Number(r.instance_id), tagsOf(r).join(', ')]));

// the instance column: a link to the instance's Summary (its own page set by engine)
const instCol = (ctx: Ctx, label = 'Instance'): Col => ({ key: 'instance', label, fmt: (v, r) => r.instance_id == null ? text(v)
  : el('a', { href: href(ctx, { tab: 'summary', instance: Number(r.instance_id), tag: undefined }) }, text(v)) });
const engCol: Col = { key: 'engine', label: 'Engine', fmt: engName };

// ---- the page frame: a heading, the report's own toolbar (its pickers), a body drawn again on every change

interface Picker { key: string; label: string; options: [string, string][]; def: string }
function pickerEl(p: Picker, on: () => void): { el: HTMLElement; value: () => string } {
  const id = 'rp-' + p.key;
  const sel = el('select', { id }, ...p.options.map(([v, l]) => el('option', { value: v }, l)));
  const saved = lsGet(p.key);
  sel.value = saved != null && p.options.some(o => o[0] === saved) ? saved : p.def;
  sel.addEventListener('change', () => { lsSet(p.key, sel.value); on(); });
  return { el: el('label', { for: id }, p.label + ' ', sel), value: () => sel.value };
}
const daysPicker = (key: string, def = '7'): Picker => ({ key, label: 'Days', def,
  options: [1, 2, 7, 14, 30, 60, 90, 180, 365].map(d => [String(d), d === 1 ? '1 Day' : `${d} Days`] as [string, string]) });

async function page(ctx: Ctx, key: string, pickers: Picker[], body: (v: Record<string, string>, s: Scope, out: HTMLElement) => Promise<void>,
                    extra: HTMLElement[] = [], ready?: (redraw: () => void) => void): Promise<HTMLElement> {
  const name = reportTabs[key];
  const sec = el('section', { class: 'report', 'data-report': key }, el('h2', {}, name + (ctx.tag ? ` (${ctx.tag})` : '')));
  const out = el('div', { 'aria-live': 'polite' });
  let seq = 0;
  const vals: { key: string; value: () => string }[] = [];
  async function draw() {
    const mine = ++seq;
    const v: Record<string, string> = {};
    for (const p of vals) v[p.key] = p.value();
    const box = el('div');
    try {
      const s = await scopeOf(ctx);
      await body(v, s, box);
    } catch (e) { box.replaceChildren(errorBox(e)); }
    if (mine === seq) out.replaceChildren(...box.childNodes);
  }
  const bar = el('div', { class: 'toolbar' });
  for (const p of pickers) { const x = pickerEl(p, () => { void draw(); }); vals.push({ key: p.key, value: x.value }); bar.append(x.el); }
  bar.append(...extra);
  if (bar.childNodes.length) sec.append(bar);
  sec.append(out);
  ready?.(() => { void draw(); });
  await draw();
  return sec;
}

// a part's state rows: 'not read on n of m instances' with each one's reason (DBA Dash's 'collection disabled on n of m')
function stateNote(rows: Row[], what: string): HTMLElement | '' {
  if (!rows.length) return '';
  const off = rows.filter(r => r.status !== 'read');
  if (!off.length) return '';
  const why = off.map(r => `${text(r.instance)}: ${r.status == null ? 'not read yet (the collection has not run there)' : `${text(r.status)}${r.note ? ' - ' + text(r.note) : ''}`}`);
  return el('p', { class: 'meta' }, badge(`${what} not read on ${off.length} of ${rows.length} instance(s)`, 'warn'), ' ', why.slice(0, 5).join('; ') + (why.length > 5 ? `; and ${why.length - 5} more` : ''));
}
const sqlServerOnly = (what: string) => el('p', { class: 'meta' }, badge('SQL Server only', 'none'), ` ${what}`);
const section = (h: string, ...kids: (Node | string)[]) => [el('h3', {}, h), ...kids];

// ---- Database Extended Properties (SQL Server; PostgreSQL: COMMENT ON DATABASE)

const propsView: Render = ctx => page(ctx, 'rp_props', [], async (_v, s, out) => {
  const d = await get<{ props: Table; state: Table; pgstate: Table }>('reports', { r: 'props', ...s.params });
  out.append(
    el('p', { class: 'meta' }, 'SQL Server: each database\'s extended properties (sys.extended_properties, class 0). PostgreSQL: each database\'s comment (COMMENT ON DATABASE) as the property "comment". Valid From: the read that first saw the value.'),
    stateNote(rowsOf(d.state), 'Extended properties'), stateNote(rowsOf(d.pgstate), 'Database comments'),
    ...section('Database Extended Properties', grid(rowsOf(d.props), [instCol(ctx), { key: 'database_name', label: 'Database' },
      { key: 'property', label: 'Property' }, { key: 'value', label: 'Value', wide: true }, { key: 'valid_from', label: 'Valid From', fmt: fmtTime }],
    'No database property is stored for this scope.')));
});

// ---- Database Finder: every database, with the pages that open it

const finderView: Render = ctx => {
  const like = el('input', { type: 'search', id: 'rp-finder-like', placeholder: 'name or LIKE pattern', 'aria-label': 'Search (LIKE)' }) as HTMLInputElement;
  like.value = lsGet('finder-like') ?? '';
  const go = el('button', { type: 'button' }, 'Search');
  let redraw: (() => void) | undefined;
  go.addEventListener('click', () => { lsSet('finder-like', like.value); redraw?.(); });
  like.addEventListener('keydown', e => { if (e.key === 'Enter') go.click(); });
  return page(ctx, 'rp_finder', [
    { key: 'finder-top', label: 'Top', def: '1000', options: [['100', '100'], ['500', '500'], ['1000', '1,000'], ['5000', '5,000']] },
    { key: 'finder-system', label: 'System Databases', def: '0', options: [['0', 'Exclude'], ['1', 'Include']] },
  ], async (v, s, out) => {
    const groups = await groupsOf();
    const d = await get<{ databases: Table }>('reports', { r: 'finder', ...s.params, top: v['finder-top'], system: v['finder-system'], like: like.value.trim() || undefined });
    const rows = rowsOf(d.databases).map(r => ({ ...r, group: groups.get(Number(r.instance_id)) ?? '' }));
    const ms = (r: Row) => r.engine === 'sqlserver';
    const at = (r: Row, tab: string, extra: Record<string, string | number | undefined> = {}) => hrefWith(ctx, tab, extra, Number(r.instance_id));
    const lk = (label: string, to: (r: Row) => string | null): Col => ({ key: 'link_' + label, label, fmt: (_v, r) => { const h = to(r); return h ? el('a', { href: h }, label) : ''; } });
    const cols: Col[] = [instCol(ctx), { key: 'group', label: 'Instance group' }, engCol,
      { key: 'database_name', label: 'Database', fmt: (v, r) => ms(r) ? text(v) : r.dbid != null ? el('a', { href: at(r, 'dbinfo', { db: Number(r.dbid) }) }, text(v)) : text(v) },
      lk('Performance', r => at(r, 'performance')),
      lk('Object Execution', r => ms(r) ? at(r, 'mssqlprocs') : at(r, 'statements')),
      lk('Slow Queries', r => ms(r) ? at(r, 'mssql_slow') : at(r, 'slowqueries')),
      lk('Files', r => ms(r) ? at(r, 'mssqlfiles') : at(r, 'storage')),
      lk('DB Space', r => ms(r) ? at(r, 'mssqlstorage') : r.dbid != null ? at(r, 'dbinfo', { db: Number(r.dbid) }) : null),
      lk('DB Configuration', r => ms(r) ? at(r, 'mssqlconfig') : at(r, 'config')),
      lk('DB Options', r => ms(r) ? at(r, 'mssqlchecks') : at(r, 'pgdboptions')),
      lk('QS', r => ms(r) ? at(r, 'mssqlqs', { qdb: text(r.database_name) }) : null),
      lk('Top Queries', r => ms(r) ? at(r, 'mssqlqs', { qdb: text(r.database_name), qs: 'top' }) : at(r, 'statements')),
      lk('Forced Plans', r => ms(r) ? at(r, 'mssqlqs', { qdb: text(r.database_name), qs: 'forced' }) : null),
      { key: 'state', label: 'State' }, { key: 'size_bytes', label: 'Size', num: true, fmt: fmtBytes },
    ];
    out.append(el('p', { class: 'meta' }, `${fmtNum(rows.length)} database(s)${rows.length >= Number(v['finder-top']) ? ` (the first ${fmtNum(rows.length)}: raise Top for more)` : ''}. `
      + 'Search (LIKE): a name part, or a pattern with % and _. A link opens the database\'s instance on that page (QS: the Query Store of SQL Server; PostgreSQL has none).'),
    ...section('Database Finder', grid(rows, cols, 'No database matches.')));
  }, [el('label', { for: 'rp-finder-like' }, 'Search (LIKE) ', like), go], r => { redraw = r; });
};

// ---- Deadlocks and Deadlock Charts (both engines)

interface Proc { [k: string]: unknown; victim?: boolean }
interface Dl {
  n: number; instance_id: number; instance: string; engine: string; event_at: string; event_key: string; has_graph: boolean;
  processes: Proc[]; resources: Row[]; signature: string; objects: string; procedures: string; parallel: boolean;
  victim: Proc | undefined; sessions: number;
}

// the shape of a deadlock, stable over its occurrences (DBA Dash's signature: the code involved, the objects and the
// lock modes; spids, times, hosts, logins and literal values left out), as 0x and 16 hex digits
const normSql = (s: string) => s.replace(/'(?:[^']|'')*'/g, '?').replace(/\b\d+(\.\d+)?\b/g, '?').replace(/\s+/g, ' ').trim().toLowerCase();
// a lock's name without what changes on every occurrence: PostgreSQL names a row lock by its transaction ('transaction
// 745') or its tuple ('tuple (0,2) of relation 16384 of database 5'); a relation's or a database's OID stays
const normName = (s: string) => s.replace(/\btransaction \d+/g, 'transaction ?').replace(/\btuple \(\d+,\d+\)/g, 'tuple (?)').toLowerCase();
function fnv(s: string, seed: number): number {
  let h = seed >>> 0;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h >>> 0;
}
export function deadlockSignature(processes: Proc[], resources: Row[]): string {
  const parts: string[] = [];
  for (const p of processes) parts.push(`process|${p.proc ? text(p.proc).toLowerCase() : normSql(text(p.statement))}|isolation=${text(p.isolation).toLowerCase()}|victim=${p.victim === true}|wants=${text(p.waits_mode)} on ${normName(text(p.waits_on))}|relation=${text(p.relation).toLowerCase()}`);
  for (const r of resources) parts.push(`resource|${text(r.type)}|object=${normName(text(r.object))}|index=${text(r.index).toLowerCase()}|mode=${text(r.mode)}`);
  const s = parts.sort().join('\n');
  return '0x' + [fnv(s, 0x811c9dc5), fnv(s, 0x050c5d1f)].map(h => h.toString(16).toUpperCase().padStart(8, '0')).join('');
}

const PG_DEADLOCK_INSTANCES = 25;
async function loadDeadlocks(ctx: Ctx, s: Scope): Promise<{ list: Dl[]; notes: string[] }> {
  const w = window_(ctx);
  const d = await get<{ deadlocks: Table; pg: Table }>('reports', { r: 'deadlocks', ...s.params, ...w });
  const list: Dl[] = [];
  const notes: string[] = [];
  const add = (r: Row, engine: string, procs: Proc[], res: Row[]) => {
    const victim = procs.find(p => p.victim === true);
    const spids = procs.map(p => p.spid).filter(x => x != null);
    // the objects: SQL Server's waited-on objects; PostgreSQL's relations (its lock names are transactions and tuples)
    const objects = engine === 'postgres'
      ? [...new Set(procs.map(p => text(p.relation)).filter(Boolean))].sort().join(', ') || text(r.relations)
      : [...new Set(procs.map(p => text(p.waits_on)).concat(res.map(x => text(x.object))).filter(Boolean))].sort().join(', ') || text(r.object_names);
    // a deadlock whose processes were not taken apart is its own row, never one signature for all of them
    const signature = procs.length ? deadlockSignature(procs, res) : `not parsed (${engine === 'sqlserver' ? 'SQL Server' : 'PostgreSQL'} ${text(r.event_key).slice(0, 12)})`;
    list.push({ n: 0, instance_id: Number(r.instance_id), instance: text(r.instance), engine, event_at: text(r.event_at), event_key: text(r.event_key),
      has_graph: r.has_graph === true, processes: procs, resources: res, signature, objects,
      procedures: [...new Set(procs.map(p => text(p.proc)).filter(Boolean))].sort().join(', '),
      parallel: new Set(spids).size < spids.length, victim, sessions: new Set(spids).size || procs.length });
  };
  const ms = rowsOf(d.deadlocks);
  for (const r of ms) add(r, 'sqlserver', Array.isArray(r.processes) ? r.processes as Proc[] : [], Array.isArray(r.resources) ? r.resources as Row[] : []);
  if (ms.length >= 2000) notes.push('SQL Server: the newest 2,000 deadlocks of the range only (a shorter range reads them all)');
  // PostgreSQL: each instance with deadlocks in the range, from its own Deadlocks tab's read (the log's DETAIL lines taken apart)
  const pg = rowsOf(d.pg);
  const reads = await Promise.all(pg.slice(0, PG_DEADLOCK_INSTANCES).map(p =>
    get<{ deadlocks: Row[]; more?: boolean }>('pg/deadlocks', { instance: Number(p.instance_id), ...w }).then(x => ({ p, x }), e => ({ p, e }))));
  for (const r of reads) {
    if ('e' in r) { notes.push(`${text(r.p.instance)}: ${r.e instanceof Error ? r.e.message : String(r.e)}`); continue; }
    for (const x of r.x.deadlocks ?? []) add({ ...x, instance_id: r.p.instance_id, instance: r.p.instance }, 'postgres', Array.isArray(x.processes) ? x.processes as Proc[] : [], Array.isArray(x.resources) ? x.resources as Row[] : []);
    if (r.x.more) notes.push(`${text(r.p.instance)}: the newest ${fmtNum((r.x.deadlocks ?? []).length)} of ${fmtNum(r.p.deadlocks)} only`);
  }
  if (pg.length > PG_DEADLOCK_INSTANCES) notes.push(`${pg.length - PG_DEADLOCK_INSTANCES} more PostgreSQL instance(s) with deadlocks are not read here (open their own Deadlocks tab)`);
  list.sort((a, b) => Date.parse(b.event_at) - Date.parse(a.event_at));
  list.forEach((x, i) => { x.n = i + 1; });
  return { list, notes };
}

// the deadlocks of one scope and range, kept while the page is open: a picker only regroups them
function deadlockCache(ctx: Ctx) {
  let key = '', got: Promise<{ list: Dl[]; notes: string[] }> | undefined;
  return (s: Scope) => {
    const k = JSON.stringify([s.params, ctx.range]);
    if (k !== key || !got) { key = k; got = loadDeadlocks(ctx, s); got.catch(() => { key = ''; }); }
    return got;
  };
}

const groupBy: [string, string, (p: Proc) => string][] = [
  ['Application', 'Application', p => text(p.program)], ['Database', 'Database', p => text(p.database)], ['Login', 'Login', p => text(p.login)],
  ['Host', 'Host', p => text(p.host)], ['Procedure', 'Procedure', p => text(p.proc)],
];
const processesPicker: Picker = { key: 'dl-processes', label: 'Processes', def: 'all', options: [['all', 'All involved'], ['victims', 'Victims only']] };
const procsOf = (d: Dl, mode: string) => mode === 'victims' ? d.processes.filter(p => p.victim === true) : d.processes;

async function graphPanel(ctx: Ctx, d: Dl, panel: HTMLElement) {
  const q = new URLSearchParams({ instance: String(d.instance_id), at: d.event_at, key: d.event_key });
  const xdl = `/api/mssql/xe/deadlock.xdl?${q}`;
  // SQL Server: the XML the server wrote where it is kept (as the instance's Deadlocks tab draws it); else the processes
  let g: DlGraph | null = null;
  if (d.engine === 'sqlserver' && d.has_graph) {
    try { const res = await fetch(xdl, { credentials: 'same-origin' }); if (res.ok) g = graphFromXml(await res.text()); } catch { /* drawn from the processes below */ }
  }
  g ??= graphFromRows(d.processes, d.resources);
  const save = d.engine === 'sqlserver' && d.has_graph ? el('a', { href: xdl, download: '', class: 'button' }, 'Save XML (.xdl)') : '';
  const tab = d.engine === 'sqlserver' ? 'mssql_deadlocks' : 'pg_deadlocks';
  panel.replaceChildren(el('h4', { tabindex: '-1' }, `Deadlock #${d.n}: ${d.instance}, ${fmtTime(d.event_at)}`),
    el('p', { class: 'meta' }, `${d.processes.length} process(es), victim ${d.victim ? text(d.victim.spid ?? d.victim.process) : 'not named'}; signature ${d.signature}. `,
      el('a', { href: href(ctx, { tab, instance: d.instance_id, tag: undefined }) }, 'The instance\'s Deadlocks tab'), ' ', save),
    g ? el('div', { class: 'deadlock-graph-box grid-wrap', tabindex: '0' }, deadlockSvg(g)) : el('p', { class: 'empty' }, 'No process to draw: the deadlock\'s detail is not stored (the query_text policy).'));
  (panel.firstElementChild as HTMLElement).focus();
}

const deadlocksView: Render = ctx => {
  const cache = deadlockCache(ctx);
  // the signature and the Grouped value the grids are narrowed to: kept across a picker change, cleared by Clear Filter
  let sig = '', val = '';
  return page(ctx, 'rp_deadlocks', [processesPicker,
    { key: 'dl-group', label: 'Group By', def: 'Application', options: groupBy.map(g => [g[0], g[1]] as [string, string]) }], async (v, s, out) => {
    const { list, notes } = await cache(s);
    const mode = v['dl-processes'];
    const by = groupBy.find(g => g[0] === v['dl-group']) ?? groupBy[0];
    const panel = el('div', { class: 'deadlock-panel' });
    const graphCol: Col = { key: 'graph', label: 'Graph', fmt: (_v, r) => {
      const d = r.dl as Dl;
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `Graph: deadlock #${d.n}, ${fmtTime(d.event_at)}` }, 'Graph');
      b.addEventListener('click', () => { void graphPanel(ctx, d, panel); }); return b; } };
    const body = el('div');
    function drawGrids() {
      const ds = list.filter(d => (!sig || d.signature === sig) && (!val || procsOf(d, mode).some(p => (by[2](p) || '(none)') === val)));
      // Signatures (of every deadlock of the range: the filters narrow the grids below it)
      const sigs = new Map<string, Dl[]>();
      for (const d of list) { const a = sigs.get(d.signature) ?? []; a.push(d); sigs.set(d.signature, a); }
      const sigRows = [...sigs.entries()].map(([k, a]) => ({ signature: k, occurrences: a.length, victims: a.reduce((n, d) => n + d.processes.filter(p => p.victim === true).length, 0),
        instances: new Set(a.map(d => d.instance_id)).size, first_seen: a[a.length - 1].event_at, last_seen: a[0].event_at, objects: a[0].objects, procedures: a[0].procedures,
        parallel: a.filter(d => d.parallel).length })).sort((a, b) => b.occurrences - a.occurrences);
      const filterBtn = (x: unknown, set: (k: string) => void, what: string) => { const b = el('button', { type: 'button', class: 'link', title: `Show the deadlocks of this ${what} only` }, text(x)); b.addEventListener('click', () => { set(text(x)); drawGrids(); }); return b; };
      const sigCols: Col[] = [{ key: 'signature', label: 'Signature', fmt: x => filterBtn(x, k => { sig = k; }, 'signature') },
        { key: 'occurrences', label: 'Occurrences', num: true }, { key: 'victims', label: 'Victims', num: true }, { key: 'instances', label: 'Instances', num: true },
        { key: 'first_seen', label: 'First Seen', fmt: fmtTime }, { key: 'last_seen', label: 'Last Seen', fmt: fmtTime },
        { key: 'objects', label: 'Objects', wide: true }, { key: 'procedures', label: 'Procedures', wide: true }, { key: 'parallel', label: 'Parallel', num: true }];
      // Grouped: by the chosen value over the processes (all, or the victims only) of the deadlocks the signature leaves
      const groups = new Map<string, { deadlocks: Set<Dl>; victims: number; procs: number; first: string; last: string }>();
      for (const d of list.filter(x => !sig || x.signature === sig)) for (const p of procsOf(d, mode)) {
        const k = by[2](p) || '(none)';
        const g = groups.get(k) ?? { deadlocks: new Set<Dl>(), victims: 0, procs: 0, first: d.event_at, last: d.event_at };
        g.deadlocks.add(d); g.procs++; if (p.victim === true) g.victims++;
        if (Date.parse(d.event_at) < Date.parse(g.first)) g.first = d.event_at;
        if (Date.parse(d.event_at) > Date.parse(g.last)) g.last = d.event_at;
        groups.set(k, g);
      }
      const grpRows = [...groups.entries()].map(([k, g]) => ({ value: k, deadlocks: g.deadlocks.size, victim_processes: g.victims, processes: g.procs, first_seen: g.first, last_seen: g.last }))
        .sort((a, b) => b.deadlocks - a.deadlocks);
      const dlRows = ds.map(d => ({ dl: d, n: d.n, instance_id: d.instance_id, instance: d.instance, engine: d.engine, event_at: d.event_at,
        victim_procedure: d.victim?.proc ?? null, victim_statement: d.victim?.statement ?? null, victim_database: d.victim?.database ?? null,
        victim_app: d.victim?.program ?? null, victim_login: d.victim?.login ?? null, victim_host: d.victim?.host ?? null, objects: d.objects,
        signature: d.signature, processes: d.processes.length, victims: d.processes.filter(p => p.victim === true).length,
        survivors: d.processes.filter(p => p.victim !== true).length, sessions: d.sessions, resources: d.resources.length, parallel: d.parallel }));
      const partRows = ds.flatMap(d => procsOf(d, mode).map(p => ({ dl: d, n: d.n, instance_id: d.instance_id, instance: d.instance, event_at: d.event_at,
        victim: p.victim === true, database: p.database ?? null, procedure: p.proc ?? null, statement: p.statement ?? null, application: p.program ?? null,
        login: p.login ?? null, host: p.host ?? null, lock_mode: p.lock_mode ?? p.waits_mode ?? null, wait_resource: p.wait_resource ?? p.waits_on ?? null,
        wait_ms: p.wait_ms ?? null, log_used: p.log_used ?? null, isolation: p.isolation ?? null, transaction: p.transaction ?? null,
        trancount: p.trancount ?? null, status: p.status ?? null, spid: p.spid ?? null, last_batch: p.last_batch ?? null })));
      const stmt = (h: string) => (x: unknown) => sqlCell(x, { heading: h });
      const clear = () => { const b = el('button', { type: 'button' }, 'Clear Filter'); b.addEventListener('click', () => { sig = ''; val = ''; drawGrids(); }); return b; };
      body.replaceChildren(
        sig || val ? el('p', { class: 'meta' }, [sig ? `Signature ${sig}` : '', val ? `${by[1]} ${val}` : ''].filter(Boolean).join(', ') + ' only. ', clear()) : '',
        ...section('Signatures', grid(sigRows, sigCols, 'No deadlock in this range.')),
        ...section('Grouped', grid(grpRows, [{ key: 'value', label: 'Value', fmt: x => filterBtn(x, k => { val = k; }, by[1].toLowerCase()) },
          { key: 'deadlocks', label: 'Deadlocks', num: true },
          { key: 'victim_processes', label: 'Victim Processes', num: true }, { key: 'processes', label: 'Processes', num: true },
          { key: 'first_seen', label: 'First Seen', fmt: fmtTime }, { key: 'last_seen', label: 'Last Seen', fmt: fmtTime }], 'No deadlock in this range.')),
        ...section('Deadlocks', grid(dlRows, [{ key: 'n', label: 'Deadlock #', num: true }, instCol(ctx), engCol, { key: 'event_at', label: 'Event Time', fmt: fmtTime }, graphCol,
          { key: 'victim_procedure', label: 'Victim Procedure' }, { key: 'victim_statement', label: 'Victim Statement', fmt: stmt('Victim statement') },
          { key: 'victim_database', label: 'Victim Database' }, { key: 'victim_app', label: 'Victim Application' }, { key: 'victim_login', label: 'Victim Login' },
          { key: 'victim_host', label: 'Victim Host' }, { key: 'objects', label: 'Objects', wide: true }, { key: 'signature', label: 'Signature' },
          { key: 'processes', label: 'Processes', num: true }, { key: 'victims', label: 'Victims', num: true }, { key: 'survivors', label: 'Survivors', num: true },
          { key: 'sessions', label: 'Sessions', num: true }, { key: 'resources', label: 'Resources', num: true }, { key: 'parallel', label: 'Parallel', fmt: yes }], 'No deadlock in this range.')),
        ...section('Participants', grid(partRows, [{ key: 'n', label: 'Deadlock #', num: true }, instCol(ctx), { key: 'event_at', label: 'Event Time', fmt: fmtTime }, graphCol,
          { key: 'victim', label: 'Victim', fmt: x => x === true ? badge('victim', 'crit') : '' }, { key: 'database', label: 'Database' }, { key: 'procedure', label: 'Procedure' },
          { key: 'statement', label: 'Statement', fmt: stmt('Statement') }, { key: 'application', label: 'Application' }, { key: 'login', label: 'Login' }, { key: 'host', label: 'Host' },
          { key: 'lock_mode', label: 'Lock Mode' }, { key: 'wait_resource', label: 'Wait Resource', wide: true }, { key: 'wait_ms', label: 'Wait Time (ms)', num: true },
          { key: 'log_used', label: 'Log Used', num: true }, { key: 'isolation', label: 'Isolation Level' }, { key: 'transaction', label: 'Transaction' },
          { key: 'trancount', label: 'Tran Count', num: true }, { key: 'status', label: 'Status' }, { key: 'spid', label: 'SPID', num: true },
          { key: 'last_batch', label: 'Batch Started', fmt: fmtTime }], 'No process to list.')),
        panel);
    }
    out.append(el('p', { class: 'meta' }, `${fmtNum(list.length)} deadlock(s) in ${rangeLabel(ctx)}. Signature: the shape of a deadlock (the code involved with its literal values taken out, the objects and the lock modes), so one problem that recurs is one row; a link narrows the grids under it to that signature, a Grouped value to that value. `
      + 'Grouped: the processes by the Group By value; Processes picks all involved or the victims only. Graph: draws the deadlock below the grids. PostgreSQL deadlocks come from the server log (each instance\'s Deadlocks tab has the detail); the log does not carry the isolation level, the transaction or the log used.'),
    notes.length ? el('p', { class: 'meta' }, badge('Not all read', 'warn'), ' ' + notes.join('; ')) : '', body);
    drawGrids();
  });
};

const deadlockChartsView: Render = ctx => {
  const cache = deadlockCache(ctx);
  return page(ctx, 'rp_dlcharts', [
    { key: 'dl-slices', label: 'Slices', def: '8', options: [['5', '5'], ['8', '8'], ['10', '10'], ['20', '20']] }, processesPicker], async (v, s, out) => {
    const { list, notes } = await cache(s);
    const w = window_(ctx);
    const from = Date.parse(w.from), to = Date.parse(w.to);
    const step = Math.max(60, Math.ceil((to - from) / 1000 / 120)) * 1000;
    const buckets = new Map<number, { sqlserver: number; postgres: number }>();
    for (let t = Math.floor(from / step) * step; t <= to; t += step) buckets.set(t, { sqlserver: 0, postgres: 0 });
    for (const d of list) { const t = Math.floor(Date.parse(d.event_at) / step) * step; const b = buckets.get(t); if (b) b[d.engine as 'sqlserver' | 'postgres']++; }
    const series = [...buckets.entries()].sort((a, b) => a[0] - b[0]).map(([t, b]) => ({ snapshot_at: new Date(t).toISOString(), deadlocks: b.sqlserver + b.postgres, sqlserver: b.sqlserver, postgres: b.postgres }));
    const both = s.engines.size > 1;
    const slices = Number(v['dl-slices']);
    const by = (f: (p: Proc, d: Dl) => string, perDeadlock = false): Slice[] => {
      const m = new Map<string, number>();
      for (const d of list) {
        if (perDeadlock) { const k = f({}, d) || '(none)'; m.set(k, (m.get(k) ?? 0) + 1); continue; }
        const seen = new Set<string>();
        for (const p of procsOf(d, v['dl-processes'])) { const k = f(p, d) || '(none)'; if (!seen.has(k)) { seen.add(k); m.set(k, (m.get(k) ?? 0) + 1); } }
      }
      return [...m.entries()].map(([label, value]) => ({ label, value }));
    };
    out.append(el('p', { class: 'meta' }, `${fmtNum(list.length)} deadlock(s) in ${rangeLabel(ctx)}, a point per ${fmtSecs(step / 1000)}. Each ring counts deadlocks: one with two processes of one application counts once for it.`),
      notes.length ? el('p', { class: 'meta' }, badge('Not all read', 'warn'), ' ' + notes.join('; ')) : '',
      el('div', { class: 'charts' }, lineChart('Over Time', series, both ? [{ key: 'sqlserver', label: 'SQL Server' }, { key: 'postgres', label: 'PostgreSQL' }] : [{ key: 'deadlocks', label: 'Deadlocks' }], v2 => fmtNum(v2), { unit: 'count', marks: false })),
      el('div', { class: 'charts donuts' },
        donutChart('Signature', by((_p, d) => d.signature, true), undefined, slices),
        donutChart('Application', by(p => text(p.program)), undefined, slices),
        donutChart('Database', by(p => text(p.database)), undefined, slices),
        donutChart('Login', by(p => text(p.login)), undefined, slices),
        donutChart('Host', by(p => text(p.host)), undefined, slices),
        donutChart('Procedure', by(p => text(p.proc)), undefined, slices)));
  });
};

// ---- New Databases, Deleted Databases (both engines: /api/dbchanges)

function dbChangesReport(key: 'rp_dbnew' | 'rp_dbdeleted'): Render {
  return ctx => page(ctx, key, [daysPicker(key + '-days', '30')], async (v, s, out) => {
    const d = await get<{ changes: Table }>('dbchanges', { instance: ctx.instance, days: v[key + '-days'] });
    const rows = rowsOf(d.changes).filter(inScope(s)).filter(r => r.change === (key === 'rp_dbnew' ? 'new' : 'dropped'));
    const mb = (x: unknown) => x == null ? '' : fmtNum(Math.round(Number(x) / 1048576));
    const created: Col = { key: 'created', label: 'Created Date', fmt: (_x, r) => r.created_at != null ? fmtTime(r.created_at)
      : key === 'rp_dbnew' ? el('span', { title: 'PostgreSQL keeps no creation time: created between these two reads' }, `${r.created_after ? fmtTime(r.created_after) : 'before'} to ${fmtTime(r.first_seen)}`)
        : r.first_seen ? 'first read ' + fmtTime(r.first_seen) : '' };
    const cols: Col[] = key === 'rp_dbnew'
      ? [instCol(ctx), engCol, { key: 'datname', label: 'DB' }, created, { key: 'size_bytes', label: 'Size (MB)', num: true, fmt: mb }]
      : [instCol(ctx), engCol, { key: 'datname', label: 'DB' }, created,
        { key: 'at', label: '~Deleted Date', fmt: (x, r) => el('span', { title: 'between the last read that listed it and the next read' }, `${fmtTime(x)}${r.dropped_by ? ' to ' + fmtTime(r.dropped_by) : ''}`) },
        { key: 'size_bytes', label: 'Size MB', num: true, fmt: mb }];
    out.append(el('p', { class: 'meta' }, `${fmtNum(rows.length)} database(s) ${key === 'rp_dbnew' ? 'created' : 'dropped'} in the last ${v[key + '-days']} day(s). `
      + (key === 'rp_dbnew' ? 'SQL Server: the server\'s own creation time; PostgreSQL keeps none: the two reads it was created between.' : 'The drop is seen between the last read that listed the database and the next (hence ~); the size is its last read.')),
    ...section(reportTabs[key], grid(rows, cols, `No database ${key === 'rp_dbnew' ? 'created' : 'dropped'} in this time.`)));
  });
}

// ---- Failed Logins (SQL Server's error log, PostgreSQL's log): DBA Dash's five grids

const failedView: Render = ctx => page(ctx, 'rp_failed', [daysPicker('failed-days')], async (v, s, out) => {
  const d = await get<{ server: Table; logins: Table; clients: Table; messages: Table; failed: Table }>('reports', { r: 'failed', ...s.params, days: v['failed-days'] });
  const server = rowsOf(d.server), rows = rowsOf(d.failed);
  const total = server.reduce((n, r) => n + Number(r.failed_logins ?? 0), 0);
  const fresh = (r: Row) => r.snapshot_at == null ? '' : Date.now() - Date.parse(text(r.snapshot_at)) < 3 * 3600e3 ? 'ok' : Date.now() - Date.parse(text(r.snapshot_at)) < 86400e3 ? 'warn' : 'crit';
  const status = (r: Row) => r.read_status == null ? 'not read yet' : r.read_status === 'read' || r.read_status === 'ok' ? 'OK' : `${text(r.read_status)}${r.read_note ? ': ' + text(r.read_note) : ''}`;
  const off = server.filter(r => !(r.read_status === 'read' || r.read_status === 'ok' || r.read_status === 'partial'));
  const sum = (label: string): Col[] => [{ key: 'value', label }, { key: 'failed_logins', label: 'Failed Logins', num: true }, { key: 'instances', label: 'Instances', num: true },
    { key: 'first_failed', label: 'First Failed Login', fmt: fmtTime }, { key: 'last_failed', label: 'Last Failed Login', fmt: fmtTime }];
  out.append(el('p', { class: 'meta' }, `${fmtNum(total)} failed login(s) in the last ${v['failed-days']} day(s). `
    + 'SQL Server: the error log\'s "Login failed" lines (error 18456; the server logs failed logins by default), read hourly by the mssql_reports collection, three hours back each time; '
    + 'PostgreSQL: the server log\'s authentication failures. The summaries count every failure of the scope; Detail lists the newest 5,000.'),
  off.length ? el('p', { class: 'meta' }, badge(`Failed logins not read on ${off.length} of ${server.length} instance(s)`, 'warn'), ' ' + off.slice(0, 5).map(r => `${text(r.instance)}: ${status(r)}`).join('; ')) : '',
  ...section('Server Summary', grid(server, [instCol(ctx), engCol, { key: 'failed_logins', label: 'Failed Logins', num: true },
    { key: 'first_failed', label: 'First Failed Login', fmt: fmtTime }, { key: 'last_failed', label: 'Last Failed Login', fmt: fmtTime },
    { key: 'snapshot_age', label: 'Snapshot Age', num: true, fmt: (_x, r) => r.snapshot_at == null ? '' : fmtSecs((Date.now() - Date.parse(text(r.snapshot_at))) / 1000) },
    { key: 'snapshot_at', label: 'Snapshot Date', fmt: fmtTime, cls: (_x, r) => fresh(r) },
    { key: 'read_status', label: 'Snapshot Status', fmt: (_x, r) => status(r), cls: (_x, r) => r.read_status === 'read' || r.read_status === 'ok' ? 'ok' : r.read_status == null ? '' : 'warn' }], 'No instance in this scope.')),
  ...section('Login Summary', grid(rowsOf(d.logins), sum('Login'), 'No failed login in this time.')),
  ...section('Client Summary', grid(rowsOf(d.clients), sum('Client'), 'No failed login in this time.')),
  ...section('Message Summary', grid(rowsOf(d.messages), sum('Message'), 'No failed login in this time.')),
  ...section('Detail', grid(rows, [instCol(ctx), engCol, { key: 'at', label: 'Log Date', fmt: fmtTime }, { key: 'login_name', label: 'Login' }, { key: 'client', label: 'Client' },
    { key: 'database_name', label: 'Database' }, { key: 'reason', label: 'Reason', wide: true }, { key: 'message', label: 'Text', wide: true }], 'No failed login in this time.')));
});

// ---- Flushed Plans (SQL Server only)

const flushedView: Render = ctx => page(ctx, 'rp_flushed', [daysPicker('flushed-days')], async (v, s, out) => {
  const d = await get<{ flushed: Table }>('reports', { r: 'flushed', ...s.params, days: v['flushed-days'] });
  out.append(s.engines.has('postgres') ? sqlServerOnly('PostgreSQL has no plan cache to flush (a plan lives in its session).') : '',
    el('p', { class: 'meta' }, 'Each plan cache flush the server recorded: DBCC FREEPROCCACHE, FREESYSTEMCACHE, FLUSHPROCINDB and FREESESSIONCACHE from the default trace (who ran it, from where), and the error log\'s "cachestore flush" lines (a flush by RECONFIGURE, ALTER DATABASE or memory pressure is logged there with no session).'),
    ...section('Flushed Plans', grid(rowsOf(d.flushed), [instCol(ctx), { key: 'at', label: 'Flushed At', fmt: fmtTime }, { key: 'login_name', label: 'Flushed By' },
      { key: 'session_id', label: 'Session ID', num: true }, { key: 'host_name', label: 'Host' }, { key: 'program_name', label: 'Program' }, { key: 'database_name', label: 'Database' },
      { key: 'command', label: 'Command' }, { key: 'text', label: 'Text', fmt: x => sqlCell(x, { heading: 'Flush' }) }, { key: 'source', label: 'Source' }], 'No plan cache flush in this time.')));
});

// ---- Killed Sessions, User Actions (pgvigil's actions log; PostgreSQL's pgaudit)

const actionCols = (ctx: Ctx, killed: boolean): Col[] => killed
  ? [instCol(ctx), engCol, { key: 'at', label: 'Killed At', fmt: fmtTime }, { key: 'ui_user', label: 'Killed By' }, { key: 'session_id', label: 'Session ID', num: true },
    { key: 'target_user', label: 'Login' }, { key: 'target_host', label: 'Host' }, { key: 'target_app', label: 'Program' }, { key: 'action', label: 'Action' },
    { key: 'outcome', label: 'Outcome', cls: x => x === 'done' ? 'ok' : x === 'failed' ? 'crit' : x === 'refused' ? 'warn' : '' },
    { key: 'reason', label: 'Reason', wide: true }, { key: 'detail', label: 'Server Message', wide: true }, { key: 'client', label: 'Client' }]
  : [{ key: 'at', label: 'Date', fmt: fmtTime }, { key: 'ui_user', label: 'User' }, { key: 'client', label: 'Client' }, { key: 'action', label: 'Action' },
    instCol(ctx), engCol, { key: 'target', label: 'Target', fmt: (x, r) => text(x ?? (r.session_id != null ? 'session ' + text(r.session_id) : '')) },
    { key: 'reason', label: 'Reason', wide: true },
    { key: 'outcome', label: 'Outcome', cls: x => x === 'done' ? 'ok' : x === 'failed' ? 'crit' : x === 'refused' ? 'warn' : '' }, { key: 'detail', label: 'Server Message', wide: true }];

const killedView: Render = ctx => page(ctx, 'rp_killed', [daysPicker('killed-days')], async (v, s, out) => {
  const d = await get<{ killed: Table }>('reports', { r: 'killed', ...s.params, days: v['killed-days'] });
  out.append(el('p', { class: 'meta' }, 'Every kill (SQL Server), terminate and cancel (PostgreSQL) asked for through pgvigil\'s actions door, done, refused or failed, with who asked, why and what the server said.'),
    ...section('Killed Sessions', grid(rowsOf(d.killed), actionCols(ctx, true), 'No session killed through pgvigil in this time.')));
});

const actionsView: Render = ctx => page(ctx, 'rp_actions', [daysPicker('actions-days')], async (v, s, out) => {
  const d = await get<{ actions: Table; audit: Table }>('reports', { r: 'actions', ...s.params, days: v['actions-days'] });
  out.append(el('p', { class: 'meta' }, 'Who did what through pgvigil (the actions log: kills, cancels, terminations, job starts and stops, EXPLAIN ANALYZE, hypothetical indexes), and on PostgreSQL what pgaudit logged of the role and DDL statements run on the server itself.'),
    ...section('User Actions', grid(rowsOf(d.actions), actionCols(ctx, false), 'No action through pgvigil in this time.')),
    ...(s.engines.has('postgres') ? section('Server Actions (pgaudit: ROLE and DDL)', grid(rowsOf(d.audit), [instCol(ctx), { key: 'at', label: 'Date', fmt: fmtTime },
      { key: 'usename', label: 'User' }, { key: 'datname', label: 'Database' }, { key: 'client', label: 'Client' }, { key: 'class', label: 'Class' }, { key: 'command', label: 'Command' },
      { key: 'object_type', label: 'Object Type' }, { key: 'object_name', label: 'Object' }, { key: 'target_role', label: 'Role' },
      { key: 'statement', label: 'Statement', fmt: x => sqlCell(x, { heading: 'Statement' }) }], 'No ROLE or DDL entry: pgaudit is not loaded, or logged none in this time.')) : []));
});

// ---- Server Role Members (SQL Server server roles; PostgreSQL superusers and pg_* roles), with the two pivots

const rolesView: Render = ctx => page(ctx, 'rp_roles', [], async (_v, s, out) => {
  const d = await get<{ members: Table; roles: Table; state: Table }>('reports', { r: 'roles', ...s.params });
  const all = rowsOf(d.members);
  const roleNames = rowsOf(d.roles).map(r => `${text(r.engine)}:${text(r.role_name)}`);
  const admin = new Set(['sqlserver:sysadmin', 'postgres:superuser', 'postgres:rds_superuser', 'postgres:azure_pg_admin', 'postgres:cloudsqlsuperuser', 'postgres:alloydbsuperuser']);
  const choices: [string, string][] = [['admin', 'sysadmin / superuser'], ...roleNames.filter(k => !admin.has(k))
    .map(k => [k, `${k.split(':').slice(1).join(':')} (${engName(k.split(':')[0])})`] as [string, string])];
  const sel = el('select', { id: 'rp-role' }, ...choices.map(([k, l]) => el('option', { value: k }, l)));
  const saved = lsGet('role');
  sel.value = saved && choices.some(c => c[0] === saved) ? saved : 'admin';
  const grids = el('div');
  const draw = () => {
    const want = sel.value;
    const rows = all.filter(r => want === 'admin' ? admin.has(`${text(r.engine)}:${text(r.role_name)}`) : `${text(r.engine)}:${text(r.role_name)}` === want);
    const insts = [...new Set(rows.map(r => text(r.instance)))].sort();
    const logins = [...new Set(rows.map(r => text(r.login_name)))].sort();
    const has = new Set(rows.map(r => `${text(r.instance)}\u0000${text(r.login_name)}`));
    const byLogin = logins.map(l => { const r0 = rows.find(r => r.login_name === l)!; const o: Row = { login_name: l, login_type: r0.login_type, type_desc: r0.type_desc };
      for (const i of insts) o['i:' + i] = has.has(`${i}\u0000${l}`) ? 'A' : '-'; return o; });
    const byInst = insts.map(i => { const o: Row = { instance: i, instance_id: rows.find(r => r.instance === i)?.instance_id };
      for (const l of logins) o['l:' + l] = has.has(`${i}\u0000${l}`) ? 'A' : '-'; return o; });
    const mark = (x: unknown) => x === 'A' ? 'ok' : '';
    grids.replaceChildren(
      ...section('Normal', grid(rows, [instCol(ctx), engCol, { key: 'role_name', label: 'Role' }, { key: 'login_name', label: 'Login' }, { key: 'login_type', label: 'Type' },
        { key: 'type_desc', label: 'Type Description' }, { key: 'is_disabled', label: 'Is Disabled', fmt: yes }, { key: 'created_at', label: 'Created Date', fmt: fmtTime },
        { key: 'modified_at', label: 'Modified Date', fmt: fmtTime }], 'No member of this role is stored for this scope.')),
      ...section('Pivot By Instance', grid(byLogin, [{ key: 'login_name', label: 'Login' }, { key: 'login_type', label: 'Type' }, { key: 'type_desc', label: 'Type Description' },
        ...insts.map(i => ({ key: 'i:' + i, label: i, cls: mark }))], 'Nothing to pivot.')),
      ...section('Pivot By User', grid(byInst, [instCol(ctx), ...logins.map(l => ({ key: 'l:' + l, label: l, cls: mark }))], 'Nothing to pivot.')));
  };
  sel.addEventListener('change', () => { lsSet('role', sel.value); draw(); });
  out.append(el('div', { class: 'toolbar' }, el('label', { for: 'rp-role' }, 'Role ', sel)),
    el('p', { class: 'meta' }, 'SQL Server: the members of each server role (sys.server_role_members). PostgreSQL: the superusers (an attribute, shown as the role "superuser"), the direct members of the predefined pg_* roles and of the managed services\' admin roles (rds_superuser, azure_pg_admin, cloudsqlsuperuser, alloydbsuperuser: sysadmin / superuser shows them too). A = a member, - = not. Type: S SQL login, U Windows login, G Windows group, R server role; PostgreSQL L a login role, R a role that cannot log in.'),
    stateNote(rowsOf(d.state), 'The server role members'), grids);
  draw();
});

// ---- SQL Login Password Age (SQL Server; PostgreSQL: expiry and password method)

const buckets: [string, (d: number) => boolean][] = [['0-1 Days', d => d <= 1], ['2-7 Days', d => d >= 2 && d <= 7], ['8-14 Days', d => d >= 8 && d <= 14],
  ['15-30 Days', d => d >= 15 && d <= 30], ['31-90 Days', d => d >= 31 && d <= 90], ['91-180 Days', d => d >= 91 && d <= 180], ['181-365 Days', d => d >= 181 && d <= 365], ['>1 Year', d => d > 365]];

const pwAgeView: Render = ctx => page(ctx, 'rp_pwage', [
  { key: 'pw-top', label: 'Top', def: '1000', options: [['10', '10'], ['20', '20'], ['50', '50'], ['100', '100'], ['1000', '1,000'], ['5000', '5,000']] },
  { key: 'pw-days', label: 'Password Age (Days)', def: '0', options: [['0', 'Any'], ['30', '> 30'], ['60', '> 60'], ['90', '> 90'], ['180', '> 180'], ['365', '> 365']] },
  { key: 'pw-disabled', label: 'Disabled Logins', def: '0', options: [['0', 'Exclude'], ['1', 'Include']] }], async (v, s, out) => {
  const d = await get<{ logins: Table; pg: Table; state: Table }>('reports', { r: 'pwage', ...s.params, disabled: v['pw-disabled'] });
  // Password Age (Days) narrows both grids, as DBA Dash's: older than that many days (Any keeps the unknown ages too)
  const min = Number(v['pw-days']), top = Number(v['pw-top']);
  const logins = rowsOf(d.logins).filter(r => min === 0 || (r.password_age_days != null && Number(r.password_age_days) > min));
  const per = new Map<string, Row>();
  for (const r of logins) {
    const k = text(r.instance_id);
    const a = per.get(k) ?? { instance_id: r.instance_id, instance: r.instance, logins: 0, max_age: null as number | null, unknown: 0, ...Object.fromEntries(buckets.map(b => [b[0], 0])) };
    a.logins = Number(a.logins) + 1;
    if (r.password_age_days == null) a.unknown = Number(a.unknown) + 1;
    else {
      const age = Number(r.password_age_days);
      a.max_age = a.max_age == null ? age : Math.max(Number(a.max_age), age);
      const b = buckets.find(x => x[1](age)); if (b) a[b[0]] = Number(a[b[0]]) + 1;
    }
    per.set(k, a);
  }
  // the oldest first, the unknown ages last
  const oldest = [...logins].sort((a, b) => (b.password_age_days == null ? -1 : Number(b.password_age_days)) - (a.password_age_days == null ? -1 : Number(a.password_age_days)));
  const ageCls = (x: unknown) => x == null ? '' : Number(x) > 365 ? 'crit' : Number(x) > 90 ? 'warn' : '';
  out.append(stateNote(rowsOf(d.state), 'The SQL logins'),
    ...(s.engines.has('sqlserver') ? [
      ...section('Summary', grid([...per.values()], [instCol(ctx), { key: 'logins', label: 'SQL Logins', num: true },
        { key: 'max_age', label: 'Max Password Age (Days)', num: true, cls: ageCls }, ...buckets.map(b => ({ key: b[0], label: b[0], num: true })),
        { key: 'unknown', label: 'Unknown', num: true }], 'No SQL login is stored for this scope.')),
      ...section('Oldest Passwords', grid(oldest.slice(0, top), [instCol(ctx), { key: 'login_name', label: 'Login' }, { key: 'is_disabled', label: 'Is Disabled', fmt: yes },
        { key: 'created_at', label: 'Created Date', fmt: fmtTime }, { key: 'modified_at', label: 'Modified Date', fmt: fmtTime },
        { key: 'password_set_at', label: 'Password Last Set', fmt: fmtTime }, { key: 'password_age_days', label: 'Password Age (Days)', num: true, cls: ageCls },
        { key: 'is_policy_checked', label: 'Policy Checked', fmt: yes }, { key: 'is_expiration_checked', label: 'Expiration Checked', fmt: yes },
        { key: 'is_expired', label: 'Expired', fmt: yes, cls: x => x === true ? 'crit' : '' }, { key: 'is_locked', label: 'Locked', fmt: yes, cls: x => x === true ? 'warn' : '' }],
      'No SQL login password of this age.'))] : []));
  if (s.engines.has('postgres')) {
    const pg = rowsOf(d.pg);
    const pgPer = new Map<string, Row>();
    for (const r of pg) {
      const k = text(r.instance_id);
      const a = pgPer.get(k) ?? { instance_id: r.instance_id, instance: r.instance, roles: 0, superusers: 0, expired: 0, expiring: 0, no_expiry: 0, scram: 0, md5: 0, none: 0, other: 0, not_read: 0 };
      a.roles = Number(a.roles) + 1;
      if (r.is_superuser === true) a.superusers = Number(a.superusers) + 1;
      const left = r.days_until_expiration == null ? null : Number(r.days_until_expiration);
      if (left == null) a.no_expiry = Number(a.no_expiry) + 1; else if (left < 0) a.expired = Number(a.expired) + 1; else if (left <= 30) a.expiring = Number(a.expiring) + 1;
      const m = r.method === 'scram-sha-256' ? 'scram' : r.method === 'md5' ? 'md5' : r.method === 'none' ? 'none' : r.method == null ? 'not_read' : 'other';
      a[m] = Number(a[m]) + 1;
      pgPer.set(k, a);
    }
    out.append(el('h3', {}, 'PostgreSQL login roles'),
      el('p', { class: 'meta' }, 'PostgreSQL keeps no time a password was set, so there is no password age: the twin is the expiry (VALID UNTIL) and the password method (md5 is deprecated; scram-sha-256 is the default since PostgreSQL 14). The method is read from pg_authid, which only a superuser login may read; it is "not read" otherwise.'),
      grid([...pgPer.values()], [instCol(ctx), { key: 'roles', label: 'Login Roles', num: true }, { key: 'superusers', label: 'Superusers', num: true },
        { key: 'expired', label: 'Expired', num: true, cls: x => Number(x) > 0 ? 'crit' : '' }, { key: 'expiring', label: 'Expiring in 30 Days', num: true, cls: x => Number(x) > 0 ? 'warn' : '' },
        { key: 'no_expiry', label: 'No Expiry', num: true }, { key: 'scram', label: 'scram-sha-256', num: true }, { key: 'md5', label: 'md5', num: true, cls: x => Number(x) > 0 ? 'warn' : '' },
        { key: 'none', label: 'No Password', num: true }, { key: 'other', label: 'Other Method', num: true }, { key: 'not_read', label: 'Method Not Read', num: true }], 'No PostgreSQL login role is stored for this scope.'),
      el('h3', {}, 'PostgreSQL password expiry'),
      grid(pg, [instCol(ctx), { key: 'role_name', label: 'Role' }, { key: 'is_superuser', label: 'Superuser', fmt: yes },
        { key: 'valid_until', label: 'Valid Until', fmt: x => x == null ? 'no expiry' : fmtTime(x) },
        { key: 'days_until_expiration', label: 'Days Until Expiration', num: true, cls: x => x == null ? '' : Number(x) < 0 ? 'crit' : Number(x) <= 30 ? 'warn' : '' },
        { key: 'method', label: 'Password Method', fmt: (x, r) => x == null ? `not read${r.method_note ? ' (' + text(r.method_note) + ')' : ''}` : text(x), cls: x => x === 'md5' ? 'warn' : '' }],
      'No PostgreSQL login role is stored for this scope.'));
  }
});

// ---- Server Services (SQL Server only)

const servicesView: Render = ctx => page(ctx, 'rp_services', [{ key: 'svc-type', label: 'Service Type', def: '', options: [['', 'All'], ['SQL Server', 'SQL Server'],
  ['SQL Server Agent', 'SQL Server Agent'], ['Full-text', 'Full-text'], ['Launchpad', 'Launchpad'], ['PolyBase', 'PolyBase']] }], async (v, s, out) => {
  const d = await get<{ services: Table; state: Table }>('reports', { r: 'services', ...s.params });
  const rows = rowsOf(d.services).filter(r => !v['svc-type'] || r.service_type === v['svc-type']);
  const fresh = (x: unknown) => x == null ? '' : Date.now() - Date.parse(text(x)) < 2 * 3600e3 ? 'ok' : Date.now() - Date.parse(text(x)) < 86400e3 ? 'warn' : 'crit';
  out.append(s.engines.has('postgres') ? sqlServerOnly('PostgreSQL runs as one service the operating system keeps; its Host page has what pgvigil reads of the host.') : '',
    stateNote(rowsOf(d.state), 'The service file names'),
    ...section('Server Services', grid(rows, [instCol(ctx), { key: 'service_type', label: 'Service Type' }, { key: 'service_name', label: 'Service Name' },
      { key: 'startup_type', label: 'Startup Type', cls: x => x === 'Automatic' ? 'ok' : x === 'Disabled' ? 'warn' : '' },
      { key: 'status', label: 'Status', cls: x => x === 'Running' ? 'ok' : x === 'Stopped' ? 'crit' : x ? 'warn' : '' }, { key: 'process_id', label: 'Process ID', num: true },
      { key: 'last_startup_at', label: 'Last Startup Time', fmt: fmtTime }, { key: 'service_account', label: 'Service Account' },
      { key: 'is_managed_account', label: 'Managed Service Account?', fmt: yes }, { key: 'filename', label: 'FileName', wide: true },
      { key: 'is_clustered', label: 'Is Clustered', fmt: yes }, { key: 'cluster_nodename', label: 'Cluster Node Name' },
      { key: 'ifi_enabled', label: 'Instant File Initialization Enabled', fmt: yes, cls: (x, r) => r.service_type === 'SQL Server' ? (x === true ? 'ok' : x === false ? 'warn' : '') : '' },
      { key: 'snapshot_at', label: 'Snapshot Date', fmt: fmtTime, cls: fresh }], 'No service is stored for this scope.')));
});

// ---- Table Size (SQL Server: the mssql_reports read; PostgreSQL: the tables collection)

const tablesView: Render = ctx => page(ctx, 'rp_tables', [
  { key: 'ts-top', label: 'Top', def: '100', options: [['20', '20'], ['50', '50'], ['100', '100'], ['500', '500']] },
  { key: 'ts-days', label: 'Growth Days', def: '7', options: [['1', '1'], ['7', '7'], ['14', '14'], ['30', '30']] }], async (v, s, out) => {
  const top = Number(v['ts-top']), days = Number(v['ts-days']);
  const rows: Row[] = [];
  let note: HTMLElement | '' = '';
  if (s.engines.has('sqlserver')) {
    const d = await get<{ tables: Table; state: Table }>('reports', { r: 'tables', ...s.params, top, days });
    rows.push(...rowsOf(d.tables).map(r => ({ ...r, engine: 'sqlserver' })));
    note = stateNote(rowsOf(d.state), 'The SQL Server table sizes');
  }
  if (s.engines.has('postgres')) {
    const to = new Date(), from = new Date(to.getTime() - days * 86400e3);
    const t = await get<{ tables: Table }>('tablesize', { from: from.toISOString(), to: to.toISOString(), top, order: 'size', instances: s.ids ? ([...s.ids].join(',') || '0') : undefined });
    for (const r of rowsOf(t.tables)) rows.push({ instance_id: r.instance_id, instance: r.instance, engine: 'postgres', snapshot_at: r.read_at, database_name: r.datname,
      schema_name: r.schema_name, table_name: r.table_name, row_count: r.n_live_tup,
      reserved_kb: r.total_bytes == null ? null : Number(r.total_bytes) / 1024, used_kb: r.total_bytes == null ? null : Number(r.total_bytes) / 1024,
      data_kb: r.heap_bytes == null ? null : (Number(r.heap_bytes) + Number(r.toast_bytes ?? 0)) / 1024, index_kb: r.index_bytes == null ? null : Number(r.index_bytes) / 1024,
      avg_rows_per_day: r.rows_per_day, avg_kb_per_day: r.bytes_per_day == null ? null : Number(r.bytes_per_day) / 1024 });
  }
  rows.sort((a, b) => Number(b.reserved_kb ?? 0) - Number(a.reserved_kb ?? 0));
  const shown = rows.slice(0, top);
  const status = (r: Row) => r.snapshot_at == null ? '' : Date.now() - Date.parse(text(r.snapshot_at)) < 2 * 86400e3 ? 'OK' : 'Stale';
  out.append(note, el('p', { class: 'meta' }, `The ${fmtNum(shown.length)} largest table(s) of ${s.count} instance(s) at each one's newest read; Avg per Day: the growth against the read nearest ${days} day(s) before. `
    + 'SQL Server: sys.dm_db_partition_stats (reserved and used pages; data = the heap or clustered index, index = the other indexes). PostgreSQL: the table with its TOAST (data) and its indexes; reserved = used = the total. Snapshot Status: OK within 2 days, else Stale.'),
  ...section('Table Size', grid(shown.map(r => ({ ...r, status: status(r) })), [instCol(ctx), engCol, { key: 'snapshot_at', label: 'Snapshot Date', fmt: fmtTime },
    { key: 'status', label: 'SnapshotStatus', cls: x => x === 'OK' ? 'ok' : x === 'Stale' ? 'warn' : '' }, { key: 'database_name', label: 'DB' }, { key: 'schema_name', label: 'Schema Name' },
    { key: 'table_name', label: 'Object Name' }, { key: 'row_count', label: 'Rows', num: true }, { key: 'reserved_kb', label: 'Reserved KB', num: true, fmt: kb },
    { key: 'used_kb', label: 'Used KB', num: true, fmt: kb }, { key: 'data_kb', label: 'Data KB', num: true, fmt: kb }, { key: 'index_kb', label: 'Index KB', num: true, fmt: kb },
    { key: 'avg_rows_per_day', label: 'Avg Rows Per Day', num: true }, { key: 'avg_kb_per_day', label: 'Avg KB Per Day', num: true, fmt: kb },
    { key: 'calc_days', label: 'Calc Days', num: true }], 'No table size is stored for this scope.')));
});

// ---- Query Stats, Query Stats Charts (SQL Server's plan cache; PostgreSQL's pg_stat_statements)

const qsCols = (ctx: Ctx, group: string): Col[] => [instCol(ctx), engCol,
  ...(group !== 'instance' ? [{ key: 'database_name', label: 'Database' }] : []),
  ...(group === 'query' || group === 'object' ? [{ key: 'object_name', label: 'Object' }] : []),
  ...(group === 'query' ? [{ key: 'query_key', label: 'Query Hash', fmt: (x: unknown, r: Row) => r.engine === 'sqlserver'
    ? el('a', { href: href(ctx, { tab: 'mssqlplancache', instance: Number(r.instance_id), tag: undefined }) }, text(x))
    : el('a', { href: href(ctx, { tab: 'statements', instance: Number(r.instance_id), tag: undefined }) }, text(x)) },
  { key: 'query_text', label: 'Text', fmt: (x: unknown) => sqlCell(x, { heading: 'Query' }) }] as Col[] : []),
  { key: 'executions', label: 'Executions', num: true }, { key: 'executions_per_min', label: 'Executions/min', num: true },
  { key: 'cpu_ms', label: 'Total CPU (ms)', num: true }, { key: 'avg_cpu_ms', label: 'Avg CPU (ms)', num: true },
  { key: 'duration_ms', label: 'Total Duration (ms)', num: true }, { key: 'avg_duration_ms', label: 'Avg Duration (ms)', num: true },
  { key: 'logical_reads', label: 'Logical Reads', num: true }, { key: 'avg_logical_reads', label: 'Avg Logical Reads', num: true },
  { key: 'physical_reads', label: 'Physical Reads', num: true }, { key: 'writes', label: 'Writes', num: true }, { key: 'row_count', label: 'Rows', num: true },
  { key: 'plans', label: 'Plans', num: true }, { key: 'max_grant_kb', label: 'Max Grant KB', num: true },
  ...(group !== 'query' ? [{ key: 'queries', label: 'Queries', num: true }] : [])];
const qsNote = 'SQL Server: what each cached statement did in the range (the plan cache read, mssql_plancache, every five minutes); PostgreSQL: pg_stat_statements\' deltas (the statements collection). PostgreSQL has no CPU time: its Total CPU is empty and the order by CPU takes its duration; its reads are shared blocks hit + read, its physical reads the blocks read, its writes the blocks written.';

const qsView: Render = ctx => page(ctx, 'rp_qs', [
  { key: 'qs-top', label: 'Top', def: '100', options: [['25', '25'], ['50', '50'], ['100', '100'], ['500', '500']] },
  { key: 'qs-group', label: 'Group By', def: 'query', options: [['query', 'Query'], ['object', 'Object'], ['database', 'Database'], ['instance', 'Instance']] },
  { key: 'qs-order', label: 'Order', def: 'cpu', options: [['cpu', 'CPU'], ['duration', 'Duration'], ['executions', 'Executions'], ['reads', 'Reads'], ['writes', 'Writes']] }], async (v, s, out) => {
  const d = await get<{ stats: Table }>('reports', { r: 'querystats', ...s.params, ...window_(ctx), top: v['qs-top'], group: v['qs-group'], order: v['qs-order'] });
  const rows = rowsOf(d.stats);
  out.append(el('p', { class: 'meta' }, `${fmtNum(rows.length)} row(s) in ${rangeLabel(ctx)}. ${qsNote}`),
    ...section('Query Stats', grid(rows, qsCols(ctx, v['qs-group']), 'No statement ran in this range (or the plan cache and statements collections are off).')));
});

const qsChartsView: Render = ctx => page(ctx, 'rp_qscharts', [], async (_v, s, out) => {
  const d = await get<{ series: Table; top: Table; meta: Table }>('reports', { r: 'qscharts', ...s.params, ...window_(ctx) });
  const step = Number(rowsOf(d.meta)[0]?.step_secs ?? 300);
  const pts = new Map<string, Row>();
  for (const r of rowsOf(d.series)) {
    const k = text(r.at);
    const p = pts.get(k) ?? { snapshot_at: r.at };
    const e = r.engine === 'sqlserver' ? 'ms' : 'pg';
    for (const m of ['executions', 'cpu_ms', 'duration_ms', 'logical_reads', 'physical_reads']) p[`${e}_${m}`] = r[m] == null ? null : Number(r[m]);
    pts.set(k, p);
  }
  const series = [...pts.values()];
  const both = s.engines.size > 1;
  const sr = (m: string) => both ? [{ key: 'ms_' + m, label: 'SQL Server' }, { key: 'pg_' + m, label: 'PostgreSQL' }] : [{ key: (s.engines.has('sqlserver') ? 'ms_' : 'pg_') + m, label: reportTabs.rp_qs }];
  const top = rowsOf(d.top);
  const slice = (m: string): Slice[] => top.map(r => ({ label: `${text(r.instance)}: ${text(r.query_text ?? r.query_key).slice(0, 60)}`, value: Number(r[m] ?? 0) }));
  out.append(el('p', { class: 'meta' }, `${rangeLabel(ctx)}, a point per ${fmtSecs(step)}. ${qsNote}`),
    el('div', { class: 'charts' },
      lineChart('Executions', series, sr('executions'), x => fmtNum(x), { marks: false }),
      s.engines.has('sqlserver') ? lineChart('CPU (ms)', series, [{ key: 'ms_cpu_ms', label: 'SQL Server' }], x => fmtNum(x), { marks: false }) : '',
      lineChart('Duration (ms)', series, sr('duration_ms'), x => fmtNum(x), { marks: false }),
      lineChart('Logical Reads', series, sr('logical_reads'), x => fmtNum(x), { marks: false })),
    el('div', { class: 'charts donuts' }, donutChart('Top queries by CPU', slice('cpu_ms'), x => fmtNum(x) + ' ms', 10), donutChart('Top queries by duration', slice('duration_ms'), x => fmtNum(x) + ' ms', 10)),
    ...section('Top queries', grid(top, qsCols(ctx, 'query'), 'No statement ran in this range.')));
});

// ---- Recycle Bin (the root only)

const recycleView: Render = ctx => page(ctx, 'rp_recycle', [], async (_v, s, out) => {
  const d = await get<{ instances: Table }>('reports', { r: 'recycle', ...(ctx.instance ? { instance: ctx.instance } : {}) });
  const rows = rowsOf(d.instances).filter(r => !s.ids || s.ids.has(Number(r.instance_id)) || r.is_active === false);
  out.append(el('p', { class: 'meta' }, 'Instances made inactive (kept with their history; nothing is collected from them) and active ones no collection has reached for a day (taken out of the configuration, or unreachable). '
    + 'Restore: name the instance in the configuration again (an inactive one is made active by its next collection). Delete: as the repository owner, DELETE FROM pgvigil.instances WHERE instance_id = <Connection ID> removes it and every row of it; the actions log keeps its rows under the instance\'s name.'),
  ...section('Recycle Bin', grid(rows, [{ key: 'instance_id', label: 'Connection ID', num: true }, { key: 'instance', label: 'Instance' }, engCol,
    { key: 'is_active', label: 'State', fmt: x => x === false ? 'inactive' : 'not collected for a day', cls: x => x === false ? '' : 'warn' },
    { key: 'last_collection', label: 'Last Collection Date', fmt: fmtTime }, { key: 'secs_since', label: 'Time Since Last Collection', num: true, fmt: fmtSecs },
    { key: 'restore', label: 'Restore', fmt: () => 'add it to the configuration' }, { key: 'delete', label: 'Delete', fmt: (_x, r) => `DELETE FROM pgvigil.instances WHERE instance_id = ${text(r.instance_id)}` }],
  'The recycle bin is empty: every instance is active and collected.')));
});

// every report page by its route: the root, an instance (main.ts's rootPages, instancePages and mssqlPages)
export const reportPages: Record<string, Render> = {
  rp_props: propsView, rp_finder: finderView, rp_dlcharts: deadlockChartsView, rp_deadlocks: deadlocksView,
  rp_dbdeleted: dbChangesReport('rp_dbdeleted'), rp_failed: failedView, rp_flushed: flushedView, rp_killed: killedView,
  rp_dbnew: dbChangesReport('rp_dbnew'), rp_qscharts: qsChartsView, rp_qs: qsView, rp_actions: actionsView,
  rp_roles: rolesView, rp_services: servicesView, rp_pwage: pwAgeView, rp_tables: tablesView, rp_recycle: recycleView,
};
