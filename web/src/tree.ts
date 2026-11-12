// The left tree: "All instances", then the folders, a status dot per instance from the overview checks rolled up
// per folder (a folder is as bad as its worst instance), a search box, folders that collapse (remembered per
// browser), and a button that hides the whole tree.
// Folders: with the config's ui.group_by empty, one folder per tag (an instance with two tags is in both; none =
// "untagged"); with group_by [env, team], a level per key in that order (env folders, team folders inside), an
// instance without the key under "(no env)". Values are ordered by ui.env_order (prod first), then by name. A
// tag is a plain word (key "tag") or key:value; the written form (prod, env:prod) is the tag scope the pages take
// (#/...?tag=env:prod), so only a top-level folder links: a nested one names a combination no single tag scopes.
// Under each instance (task 65; DBADash's tree: instance > child folders > database > objects): a caret opens its
// folders, closed by default: Configuration, Checks, Replication and Storage open their tabs; Databases loads the
// instance's databases on first open (one /api/dbinfo read), each database a node to its page with a Tables folder
// that loads that database's largest tables (one /api/drill/db read); Jobs loads its jobs (one /api/jobs read). Each
// read asks only for the part it shows (part=databases | tables | jobs; a server without the part selector answers
// with the whole page, which still works) and is kept 30 minutes: the lists change hourly.
// Every link keeps the time range. The search still finds instances; an open instance shows its folders under it.
// Also the helpers the Summary and the instance header use: tag columns and a tag filter, and tag chips.
import { get, LoginRequired, Row, rowsOf, Table } from './api';
import { poolerCached } from './pooler';
import { Ctx, href, drillHome, groupsFor, isMssql, rootGroups, rootTabs, tabsFor } from './router';
import { Fleet, forget, Level, tagsOf, worst } from './fleet';
import { hashParam, hrefWith } from './dbinfo';
import { dot, el, fmtBytes } from './ui';
import { dbadashFolders } from './dbadash';
import { driveNodes } from './treemenu';

const UNTAGGED = 'untagged';

function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function lsSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private window */ } }

// ---- tags as pairs

export interface Tag { key: string; value: string }

// parseTag reads the written form: 'prod' is key tag, 'env:prod' splits at the first ':' (config.ParseTag's rule).
export function parseTag(s: string): Tag {
  const i = s.indexOf(':');
  return i > 0 ? { key: s.slice(0, i).trim().toLowerCase(), value: s.slice(i + 1).trim() } : { key: 'tag', value: s.trim() };
}
export const tagText = (t: Tag) => t.key === 'tag' ? t.value : `${t.key}:${t.value}`;
export const pairsOf = (r: Row): Tag[] => tagsOf(r).map(parseTag);
export const valuesOf = (r: Row, key: string): string[] => pairsOf(r).filter(t => t.key === key).map(t => t.value);

// the ui: block, read once from /api/tags (a server without the route: no grouping, the default order)
export interface TagUI { group_by: string[]; env_order: string[]; overridden: Map<number, Set<string>> }
const DEFAULT_ORDER = ['prod', 'production', 'prd', 'staging', 'stage', 'uat', 'qa', 'test', 'dev', 'development'];
let ui: TagUI = { group_by: [], env_order: DEFAULT_ORDER, overridden: new Map() };
let uiAt = 0;
let uiPending: Promise<TagUI> | null = null;

export async function tagUI(force = false): Promise<TagUI> {
  if (!force && uiAt && Date.now() - uiAt < 60000) return ui;
  if (uiPending) return uiPending;
  uiPending = get<{ group_by: string[]; env_order: string[]; pairs: Table | null }>('tags')
    .then(d => {
      const ov = new Map<number, Set<string>>();
      const cols = d.pairs?.columns ?? [];
      const [iI, kI, sI] = ['instance_id', 'key', 'source'].map(c => cols.indexOf(c));
      for (const p of d.pairs?.rows ?? []) {
        if (p[sI] !== 'override') continue;
        const id = Number(p[iI]);
        if (!ov.has(id)) ov.set(id, new Set());
        ov.get(id)!.add(String(p[kI]));
      }
      ui = { group_by: d.group_by ?? [], env_order: d.env_order?.length ? d.env_order.map(v => v.trim().toLowerCase()) : DEFAULT_ORDER, overridden: ov };
      uiAt = Date.now();
      return ui;
    })
    .catch(() => { uiAt = Date.now(); return ui; })
    .finally(() => { uiPending = null; });
  return uiPending;
}

// orderValues: env_order's values first in its order, the rest by name, the "(no key)" bucket last.
export function rankOf(v: string): number {
  const i = ui.env_order.indexOf(v.toLowerCase());
  return i < 0 ? ui.env_order.length : i;
}
export function cmpValues(a: string, b: string): number {
  const na = a.startsWith('(no '), nb = b.startsWith('(no ');
  if (na !== nb) return na ? 1 : -1;
  return rankOf(a) - rankOf(b) || a.localeCompare(b);
}

// ---- the tree

const collapsed = new Set<string>(JSON.parse(lsGet('pgvigil.collapsed') ?? '[]') as string[]);
let filter = '';
let last: { f: Fleet; ctx: Ctx } | null = null;

const search = el('input', { type: 'search', placeholder: 'Find instance, database, table', 'aria-label': 'find an instance, a database or a table by name' });
const list = el('div', { class: 'tree-list' });
search.addEventListener('input', () => { filter = search.value.trim().toLowerCase(); draw(); findNames(search.value.trim()); });

// The same box finds databases and tables by a part of their name across the fleet (/api/search): asked 300 ms
// after the last key, from two characters; the read of an older text is aborted (the server's query ends with it),
// so a typing user holds one connection of the UI pool at most. The instances are filtered in the page as before;
// the found names are listed under the tree, each a link to its page. One line that stays in the page (said, the
// live region: never re-created by a draw) tells a screen reader what was found, once per answer.
const FOUND_SHOWN = 50, FIND_MAX = 128;
let found: { q: string; rows?: Row[]; err?: string } | null = null;
let findTimer: number | undefined;
let findAbort: AbortController | null = null;
const said = el('p', { class: 'sr-only', role: 'status', 'aria-live': 'polite', style: 'position:absolute;left:-10000px;width:1px;height:1px;overflow:hidden' });
const say = (t: string) => { if (said.textContent !== t) said.textContent = t; };
function findNames(q: string) {
  window.clearTimeout(findTimer);
  findAbort?.abort(); findAbort = null;
  if ([...q].length < 2 || [...q].length > FIND_MAX) { if (found) { found = null; draw(); } say(''); return; }
  findTimer = window.setTimeout(() => {
    found = { q };
    draw();
    const ac = findAbort = new AbortController();
    get('search', { q }, ac.signal).then(t => {
      if (found?.q !== q || ac.signal.aborted) return;
      const rows = rowsOf(t);
      found = { q, rows }; draw();
      const n = (k: string) => { const c = rows.filter(r => r.kind === k).length; return c > FOUND_SHOWN ? `more than ${FOUND_SHOWN}` : String(c); };
      say(`${n('database')} databases and ${n('table')} tables found for ${q}`);
    }).catch((e: unknown) => {
      if (found?.q !== q || ac.signal.aborted) return;
      if (e instanceof LoginRequired) { found = null; draw(); return; }
      found = { q, err: e instanceof Error ? e.message : String(e) }; draw();
      say('The search failed: ' + found.err);
    });
  }, 300);
}
function foundNames(ctx: Ctx): HTMLElement[] {
  if (!found) return [];
  const head = (t: string) => el('div', { class: 'folder-head', role: 'heading', 'aria-level': '2' }, el('span', { class: 'folder-name' }, t));
  const note = (t: string, cls = 'empty') => el('p', { class: cls, style: 'padding:.1rem .4rem' }, t);
  if (found.err) return [head('Databases and tables'), note('Could not search: ' + found.err, 'error')];
  if (!found.rows) return [head('Databases and tables'), note('Searching...')];
  const out: HTMLElement[] = [];
  const part = (kind: string, title: string, line: (r: Row) => HTMLElement) => {
    const rows = found!.rows!.filter(r => r.kind === kind);
    const more = rows.length > FOUND_SHOWN;
    out.push(head(`${title} named like "${found!.q}" (${more ? FOUND_SHOWN + '+' : rows.length})`));
    if (rows.length === 0) out.push(note('None.'));
    for (const r of rows.slice(0, FOUND_SHOWN)) out.push(el('div', { style: nodeStyle(0) }, line(r)));
    if (more) out.push(note(`The first ${FOUND_SHOWN}; type more of the name.`));
  };
  part('database', 'Databases', r => leaf(`${String(r.datname)}  -  ${String(r.instance)}`,
    hrefWith(ctx, 'db', { db: String(r.dbid) }, Number(r.instance_id)), false, `database ${String(r.datname)} on ${String(r.instance)}, ${fmtBytes(r.bytes)}`));
  part('table', 'Tables', r => leaf(`${String(r.schema_name)}.${String(r.table_name)}  -  ${String(r.datname)} on ${String(r.instance)}`,
    hrefWith(ctx, 'table', { db: String(r.dbid), rel: String(r.relid) }, Number(r.instance_id)), false,
    `table ${String(r.schema_name)}.${String(r.table_name)} in ${String(r.datname)} on ${String(r.instance)}, ${fmtBytes(r.bytes)}`));
  return out;
}

export function mountTree(host: HTMLElement) {
  const hide = el('button', { type: 'button', class: 'tree-hide', title: 'Hide the tree' }, '«');
  hide.addEventListener('click', () => setTreeHidden(true));
  host.replaceChildren(el('div', { class: 'tree-top' }, search, hide), said, list);
}

export function setTreeHidden(h: boolean) {
  document.body.classList.toggle('tree-hidden', h);
  lsSet('pgvigil.treeHidden', h ? '1' : '');
}
export function treeHiddenSaved(): boolean { return lsGet('pgvigil.treeHidden') === '1'; }

export function updateTree(f: Fleet, ctx: Ctx) {
  last = { f, ctx };
  draw();
  // the ui: block arrives once; the tree redraws with it (the first paint never waits on it)
  if (!uiAt) void tagUI().then(() => { if (last) draw(); });
}

// ---- the instance's folders (task 65)

// which instance nodes and folders are open: for the browser session only, so a new session starts closed
const opened = new Set<string>((() => { try { return JSON.parse(sessionStorage.getItem('pgvigil.treeOpen') ?? '[]') as string[]; } catch { return []; } })());
function flip(key: string) {
  if (opened.has(key)) opened.delete(key); else opened.add(key);
  // closing and opening a folder retries a read that failed (an error is never kept past the user's own retry)
  if (loads.get(key)?.err) loads.delete(key);
  try { sessionStorage.setItem('pgvigil.treeOpen', JSON.stringify([...opened])); } catch { /* private window */ }
}
function toggle(key: string) { flip(key); draw(); }
// reloadTree: the folder reads under a key (i5, i5/jobs; '' = all) dropped and the tree drawn, so each open folder reads
// again (the tree menu's Refresh, task 172)
export function reloadTree(prefix = '') {
  for (const k of [...loads.keys()]) if (!prefix || k === prefix || k.startsWith(prefix + '/')) loads.delete(k);
  draw();
}

// nameOpens: a click on a node's NAME opens the node too, as a click on its caret does (the caret stays, for
// opening a node without leaving the page and for the keyboard). A closed node opens and its link is followed; the
// node whose page is already shown, or a name that is no link, closes again on the next click. A click with a
// modifier key or another button (a new tab) is the browser's alone. The draw waits for the link's own navigation.
// The second click of a double-click is ignored (a double-click opens, as in a desktop tree, and never flips the
// node back). The name carries the node's key, so a redraw gives the keyboard focus back to it (draw()).
function nameOpens<T extends HTMLElement>(name: T, key: string, isOpen: boolean, on: boolean, change: () => void): T {
  name.dataset.nk = key;
  name.addEventListener('click', ev => {
    const e = ev as MouseEvent;
    if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey || e.detail > 1) return;
    if (isOpen && !on) return;
    change();
    setTimeout(draw, 0);
  });
  return name;
}

// the children a folder loads on its first open: one API read, kept 30 minutes (the databases, tables and jobs
// collections run hourly; a read past that is redone on the next draw, the old rows shown meanwhile). A failed read
// is kept 30 seconds, or until the folder is closed and opened again, then read again.
// A read that meets the login (the session expired) keeps a 'login' entry for those 30 seconds too and does not draw:
// the folder is not read again on every draw (a draw that found no entry would read, meet the login, draw, read ...),
// and the shell's render, started once with the fleet read dropped from its cache, meets the login on that read and
// shows the sign-in (a page drawn from the cached fleet, the Summary, would never meet it).
interface Load { at: number; rows?: Row[]; err?: string; pending?: boolean; login?: boolean }
const loads = new Map<string, Load>();
const LOAD_TTL = 1800000, ERR_TTL = 30000;
const TABLES_SHOWN = 15, JOBS_SHOWN = 30;
function loaded(key: string, read: () => Promise<Row[]>): Load {
  const l = loads.get(key);
  if (l && (l.pending || Date.now() - l.at < (l.err ? ERR_TTL : LOAD_TTL))) return l;
  const next: Load = { at: Date.now(), pending: true, rows: l?.rows };
  loads.set(key, next);
  read().then(rows => { loads.set(key, { at: Date.now(), rows }); draw(); }, e => {
    if (e instanceof LoginRequired) {
      loads.set(key, { at: Date.now(), err: 'the session has ended: sign in again', login: true });
      forget();
      rerender();
      return;
    }
    loads.set(key, { at: Date.now(), err: e instanceof Error ? e.message : String(e) });
    draw();
  });
  return next;
}

const nodeStyle = (depth: number) => `margin-left:${(depth * 0.8).toFixed(1)}rem`;
const rowStyle = 'display:flex;align-items:center';

// caretFor: the open / close button of a node, its state for a screen reader too
function caretFor(key: string, what: string): HTMLButtonElement {
  const isOpen = opened.has(key);
  const b = el('button', { type: 'button', class: 'caret', 'data-key': key, 'aria-expanded': String(isOpen), 'aria-label': `${isOpen ? 'close' : 'open'} ${what}` }, isOpen ? '▾' : '▸');
  b.addEventListener('click', () => toggle(key));
  return b;
}

// leaf: a link node in the tree, marked on when it is the page shown
const leaf = (text: string, to: string, on: boolean, title = '', lvl?: Level) =>
  el('a', { class: 'inst' + (on ? ' on' : ''), href: to, title: title || text }, ...(lvl === undefined ? [] : [dot(lvl)]), text);

// folder: a caret, a name (a link when it opens a page) and, when open, its children
// shown: the name's link is the page already shown (a click then closes the node) where the name is not the one highlighted
function folder(key: string, name: string, depth: number, kids: () => HTMLElement[], to?: string, on = false, shown = on): HTMLElement {
  const isOpen = opened.has(key);
  const head = el('div', { class: 'tree-node', style: rowStyle + ';' + nodeStyle(depth) }, caretFor(key, name),
    to ? nameOpens(el('a', { class: 'inst' + (on ? ' on' : ''), href: to, style: 'flex:1' }, name), key, isOpen, shown, () => flip(key))
       : nameOpens(el('span', { class: 'folder-name', style: 'padding:.2rem .4rem;cursor:pointer;flex:1' }, name), key, isOpen, true, () => flip(key)));
  const box = el('div', {}, head);
  if (opened.has(key)) box.append(...kids());
  return box;
}

// loading / failed / empty lines under a folder that reads its children (announced: a screen reader hears them change)
function state(l: Load, depth: number, empty: string): HTMLElement | null {
  const st = 'padding:.1rem .4rem;' + nodeStyle(depth);
  if (l.err) return el('p', { class: 'error', style: st, role: 'status', 'aria-live': 'polite' }, 'Could not load: ' + l.err);
  if (!l.rows) return el('p', { class: 'empty', style: st, role: 'status', 'aria-live': 'polite' }, 'Loading...');
  if (l.rows.length === 0) return el('p', { class: 'empty', style: st, role: 'status', 'aria-live': 'polite' }, empty);
  return null;
}

// instanceFolders: what opens under an instance node
function instanceFolders(ctx: Ctx, id: number, depth: number, engine?: unknown): HTMLElement[] {
  const here = ctx.instance === id;
  const tabLink = (tab: string) => href(ctx, { tab, instance: id, tag: undefined, at: undefined, task: undefined, taskInstance: undefined });
  const tabFolder = (k: string, name: string, tabs: [string, string][]) =>
    folder(`i${id}/${k}`, name, depth, () => [...tabs.map(([tab, label]) => el('div', { style: nodeStyle(depth + 1) }, leaf(label, tabLink(tab), here && ctx.tab === tab))),
      ...(k === 'storage' ? driveNodes(ctx, id, engine, depth + 1, draw) : [])]);
  const instanceTabs = tabsFor(engine), instanceGroups = groupsFor(engine);
  // a SQL Server instance: its tab groups only (its databases and jobs are pages, not tree nodes yet)
  if (isMssql(engine)) return instanceGroups.filter(g => g.key !== 'main').map(g => tabFolder(g.key, g.name, g.tabs.map(t => [t, instanceTabs[t]] as [string, string])));
  const curDb = here ? hashParam('db') : undefined, curRel = here ? hashParam('rel') : undefined, curJob = here ? hashParam('job') : undefined;

  const databases = folder(`i${id}/db`, 'Databases', depth, () => {
    const l = loaded(`i${id}/db`, async () => {
      const d = await get<Record<'databases', Table | null>>('dbinfo', { instance: id, part: 'databases' });
      return rowsOf(d.databases).filter(r => r.is_present && !r.is_template);
    });
    const s = state(l, depth + 1, 'No database read yet (hourly).');
    if (s) return [s];
    return l.rows!.map(r => {
      const dbid = String(r.dbid);
      const tables = folder(`i${id}/db/${dbid}/t`, 'Tables', depth + 2, () => {
        const lt = loaded(`i${id}/db/${dbid}/t`, async () => {
          const d = await get<Record<'tables', Table | null>>('drill/db', { instance: id, db: dbid, part: 'tables' });
          return rowsOf(d.tables);
        });
        const st = state(lt, depth + 3, 'No table read in this database.');
        if (st) return [st];
        const shown = lt.rows!.slice(0, TABLES_SHOWN).map(t => el('div', { style: nodeStyle(depth + 3) },
          leaf(`${String(t.schema_name)}.${String(t.table_name)}`, hrefWith(ctx, 'table', { db: dbid, rel: String(t.relid) }, id),
            here && ctx.tab === 'table' && curDb === dbid && curRel === String(t.relid), `${String(t.schema_name)}.${String(t.table_name)}, ${fmtBytes(t.total_bytes)}`)));
        if (lt.rows!.length > TABLES_SHOWN) {
          shown.push(el('div', { style: nodeStyle(depth + 3) }, leaf(`all ${lt.rows!.length} tables...`, hrefWith(ctx, 'db', { db: dbid }, id), false)));
        }
        return shown;
      }, hrefWith(ctx, 'db', { db: dbid }, id), false, here && ctx.tab === 'db' && curDb === dbid);
      // the database node: its page, and under it the Tables folder
      return folder(`i${id}/db/${dbid}`, String(r.datname), depth + 1, () => [tables],
        hrefWith(ctx, 'db', { db: dbid }, id), here && ctx.tab === 'db' && curDb === dbid);
    });
  }, tabLink('dbinfo'), false, here && ctx.tab === 'dbinfo');

  const jobs = folder(`i${id}/jobs`, 'Jobs', depth, () => {
    const l = loaded(`i${id}/jobs`, async () => {
      const d = await get<Record<'jobs', Table | null>>('jobs', { instance: id, part: 'jobs' });
      return rowsOf(d.jobs).filter(r => r.is_present);
    });
    const s = state(l, depth + 1, 'No scheduled job.');
    if (s) return [s];
    const shown = l.rows!.slice(0, JOBS_SHOWN).map(r => {
      const failed = ['failed', 'internal error', 'aborted'].includes(String(r.last_status ?? ''));
      return el('div', { style: nodeStyle(depth + 1) }, leaf(String(r.job_name ?? r.job_id), hrefWith(ctx, 'job', { scheduler: String(r.scheduler), job: String(r.job_id) }, id),
        here && ctx.tab === 'job' && curJob === String(r.job_id) && hashParam('scheduler') === String(r.scheduler),
        `${String(r.scheduler)} job ${String(r.job_id)}${r.last_status ? ', last run ' + String(r.last_status) : ''}`, failed ? 2 : 0));
    });
    if (l.rows!.length > JOBS_SHOWN) shown.push(el('div', { style: nodeStyle(depth + 1) }, leaf(`all ${l.rows!.length} jobs...`, tabLink('jobs'), false)));
    return shown;
  }, tabLink('jobs'), here && ctx.tab === 'jobs');

  // one folder per tab group of router.ts (the strip shows the same tabs once inside); the Pooler leaf only where a
  // pooler read exists; Jobs is the folder above, with its jobs under it
  const groupFolders = instanceGroups.filter(g => g.key !== 'main' && g.key !== 'jobs').map(g =>
    tabFolder(g.key, g.name, g.tabs.filter(t => t !== 'pooler' || poolerCached(id)).map(t => [t, instanceTabs[t]] as [string, string])));
  return [...groupFolders, databases, jobs];
}

// scopeFolders: the folders of the fleet or of a tag folder (the scope the page is in), each a short list of pages
function scopeFolders(ctx: Ctx): HTMLElement[] {
  const scope = ctx.instance ? undefined : ctx.tag;
  return rootGroups.filter(g => g.key !== 'main').map(g =>
    folder(`r/${g.key}`, g.name, 0, () => g.tabs.map(t => el('div', { style: nodeStyle(1) },
      leaf(rootTabs[t], href(ctx, { tab: t, instance: undefined, tag: scope, at: undefined, task: undefined, taskInstance: undefined }), !ctx.instance && ctx.tab === t)))));
}

const rollup = (f: Fleet, rows: Row[]) => rows.reduce<Level>((a, r) => Math.max(a, worst(f, r)) as Level, 0);

// a folder: its key path (collapse memory), its label, its scope link (top level only), its members, its children
interface Folder { path: string; label: string; tag?: string; muted?: boolean; rows: Row[]; kids: Folder[] }

function foldersFor(rows: Row[], keys: string[], level: number, parent: string): Folder[] {
  if (keys.length === 0) {
    // one folder per written tag; none = untagged
    const m = new Map<string, Row[]>();
    for (const r of rows) for (const t of (tagsOf(r).length ? tagsOf(r) : [UNTAGGED])) {
      if (!m.has(t)) m.set(t, []);
      m.get(t)!.push(r);
    }
    const names = [...m.keys()].sort((a, b) => a === UNTAGGED ? 1 : b === UNTAGGED ? -1 : cmpValues(parseTag(a).value, parseTag(b).value) || a.localeCompare(b));
    return names.map(t => ({ path: t, label: t, tag: t === UNTAGGED ? undefined : t, muted: t === UNTAGGED, rows: m.get(t)!, kids: [] }));
  }
  if (level >= keys.length) return [];
  const key = keys[level], none = `(no ${key})`;
  const m = new Map<string, Row[]>();
  for (const r of rows) for (const v of (valuesOf(r, key).length ? valuesOf(r, key) : [none])) {
    if (!m.has(v)) m.set(v, []);
    m.get(v)!.push(r);
  }
  return [...m.keys()].sort(cmpValues).map(v => {
    const path = `${parent}${key}=${v}/`;
    const isNone = v === none;
    return {
      path, label: isNone ? v : (key === 'tag' ? v : `${key}: ${v}`), muted: isNone,
      tag: level === 0 && !isNone ? tagText({ key, value: v }) : undefined,
      rows: m.get(v)!, kids: foldersFor(m.get(v)!, keys, level + 1, path),
    };
  });
}

function draw() {
  // the sign-in form is up: the tree waits for the next render after the sign-in (no folder read meanwhile)
  if (!last || document.body.classList.contains('signin')) return;
  const { f, ctx } = last;
  const rootTab = ctx.instance ? 'summary' : ctx.tab;
  const all = el('a', { class: 'tree-root' + (!ctx.instance && !ctx.tag ? ' on' : ''), href: href(ctx, { tab: rootTab, instance: undefined, tag: undefined }) },
    dot(rollup(f, f.instances)), `All instances (${f.instances.length})`);
  const match = (r: Row) => !filter || String(r.name).toLowerCase().includes(filter);
  const render = (fo: Folder, depth: number): HTMLElement | null => {
    const shown = fo.rows.filter(match);
    if (filter && shown.length === 0) return null;
    const shut = collapsed.has(fo.path) && !filter;
    const caret = el('button', { type: 'button', class: 'caret', 'data-key': 'f:' + fo.path, 'aria-expanded': String(!shut), 'aria-label': `${shut ? 'expand' : 'collapse'} ${fo.label}` }, shut ? '▸' : '▾');
    const flipFolder = () => {
      if (collapsed.has(fo.path)) collapsed.delete(fo.path); else collapsed.add(fo.path);
      lsSet('pgvigil.collapsed', JSON.stringify([...collapsed]));
    };
    caret.addEventListener('click', () => { flipFolder(); draw(); });
    // while a filter is typed every folder is drawn open: a click on a name then only follows its link
    const nameFlip = () => { if (!filter) flipFolder(); };
    const text = `${fo.label} (${fo.rows.length})`;
    const tagOn = !ctx.instance && ctx.tag === fo.tag;
    const label = fo.tag
      ? nameOpens(el('a', { class: 'folder-name' + (tagOn ? ' on' : ''), href: href(ctx, { tab: rootTab, instance: undefined, tag: fo.tag }) }, text), 'f:' + fo.path, !shut, tagOn, nameFlip)
      : nameOpens(el('span', { class: 'folder-name' + (fo.muted ? ' muted' : ''), style: 'cursor:pointer', title: depth > 0 ? 'A nested folder: open its top folder for a tag scope' : '' }, text), 'f:' + fo.path, !shut, true, nameFlip);
    const box = el('div', { class: 'folder', style: depth ? 'margin-left:.8rem' : '' }, el('div', { class: 'folder-head' }, caret, dot(rollup(f, fo.rows)), label));
    if (!shut) {
      const ul = el('div', { class: 'folder-items' });
      if (fo.kids.length) {
        for (const k of fo.kids) { const e = render(k, depth + 1); if (e) ul.append(e); }
      } else {
        for (const r of shown) {
          const id = Number(r.instance_id);
          // a drill page's link to another instance lands on its home tab; a page outside that instance's main tabs (a
          // folder's page, a page of the other engine) lands on its Summary: the name is always a way back to the main strip
          const want = ctx.instance ? (drillHome[ctx.tab] ?? ctx.tab) : 'summary';
          const tab = groupsFor(r.engine)[0].tabs.includes(want) ? want : 'summary';
          const key = `i${id}`;
          ul.append(el('div', { class: 'tree-inst', style: rowStyle }, caretFor(key, String(r.name)),
            nameOpens(el('a', { class: 'inst' + (id === ctx.instance ? ' on' : ''), style: 'flex:1;min-width:0', href: href(ctx, { tab, instance: id, tag: undefined, at: undefined, task: undefined, taskInstance: undefined }), title: `${r.platform ?? ''} ${r.server_version ?? ''}` },
              dot(worst(f, r)), String(r.name)), key, opened.has(key), id === ctx.instance && ctx.tab === tab && ctx.at == null && ctx.task == null, () => flip(key))));
          if (opened.has(key)) ul.append(...instanceFolders(ctx, id, 1, r.engine));
        }
      }
      box.append(ul);
    }
    return box;
  };
  const out: HTMLElement[] = [all, ...(filter ? [] : scopeFolders(ctx))];
  for (const fo of foldersFor(f.instances, ui.group_by, 0, '')) { const e = render(fo, 0); if (e) out.push(e); }
  if (f.instances.length === 0) out.push(el('p', { class: 'empty' }, 'No instances yet: run the collector.'));
  else if (filter && out.length === 1) out.push(el('p', { class: 'empty', style: 'padding:.1rem .4rem' }, 'No instance named like that.'));
  out.push(...dbadashFolders(ctx, draw, filter));
  out.push(...foundNames(ctx));
  // a redraw replaces every node: a caret that had the keyboard focus gets it back (by its key), so a keyboard or
  // screen-reader user stays where they were after opening a folder and after its children arrive
  // an instance in two tag folders has two carets with one key: the focus goes back to the same copy (its index)
  // a name that opens its node (nameOpens) gets the focus back the same way, by the node's key on it
  const active = (document.activeElement as HTMLElement | null)?.closest<HTMLElement>('#tree button.caret, #tree [data-nk]');
  const isName = active != null && !active.matches('button.caret');
  const focused = isName ? active.dataset.nk : active?.dataset.key;
  const sameKey = (k: string) => [...list.querySelectorAll<HTMLElement>(isName ? `[data-nk="${CSS.escape(k)}"]` : `button.caret[data-key="${CSS.escape(k)}"]`)];
  const copy = focused ? sameKey(focused).indexOf(active!) : -1;
  list.replaceChildren(...out);
  if (focused) { const all = sameKey(focused); (all[copy] ?? all[0])?.focus(); }
}

// ---- the instance header's chips


// tagKeys: the keys in use, the group_by keys first in their order, then by name.
export function tagKeys(rows: Row[]): string[] {
  const ks = new Set<string>();
  for (const r of rows) for (const t of pairsOf(r)) ks.add(t.key);
  return [...ks].sort((a, b) => {
    const ia = ui.group_by.indexOf(a), ib = ui.group_by.indexOf(b);
    if (ia >= 0 || ib >= 0) return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib);
    return a === 'tag' ? -1 : b === 'tag' ? 1 : a.localeCompare(b);
  });
}

// withTagFields adds one sortable field per key: 't_<key>' = the values in env order, ranked so a header click
// sorts prod before staging before dev and an instance without the key last.
export function withTagFields(rows: Row[], keys = tagKeys(rows)): Row[] {
  return rows.map(r => {
    const out: Row = { ...r };
    for (const k of keys) {
      const vs = valuesOf(r, k).sort(cmpValues);
      out['t_' + k] = vs.length ? `${String(rankOf(vs[0])).padStart(3, '0')} ${vs.join(', ')}` : null;
    }
    return out;
  });
}

// the filter: one key and one value, kept for the browser session
let tf: Tag | null = (() => { try { const v = sessionStorage.getItem('pgvigil.tagFilter'); return v ? JSON.parse(v) as Tag : null; } catch { return null; } })();
function saveFilter() { try { sessionStorage.setItem('pgvigil.tagFilter', tf ? JSON.stringify(tf) : ''); } catch { /* private window */ } }

export function applyTagFilter(rows: Row[]): Row[] {
  if (!tf) return rows;
  const want = tf;
  return rows.filter(r => want.value === '' ? valuesOf(r, want.key).length === 0 : valuesOf(r, want.key).includes(want.value));
}

// tagFilterBar: a key select and a value select over the rows given (the scope before the filter); onChange
// redraws the caller's page (default: the shell's own re-render, which a hashchange event starts).
const rerender = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
export function tagFilterBar(rows: Row[], onChange: () => void = rerender): HTMLElement {
  const keys = tagKeys(rows);
  const keySel = el('select', { 'aria-label': 'filter by tag key' }, el('option', { value: '' }, 'any tag'), ...keys.map(k => el('option', { value: k }, k === 'tag' ? 'tag (plain)' : k)));
  const valSel = el('select', { 'aria-label': 'filter by tag value' });
  const eq = el('span', { 'aria-hidden': 'true' }, ' = ');
  const fillValues = () => {
    const k = keySel.value;
    const vs = [...new Set(rows.flatMap(r => valuesOf(r, k)))].sort(cmpValues);
    valSel.replaceChildren(...vs.map(v => el('option', { value: v }, v)), el('option', { value: '' }, `(no ${k})`));
    valSel.disabled = !k;
    valSel.style.display = k ? '' : 'none';
    eq.style.display = k ? '' : 'none';   // 'any tag =' with nothing after it read as a broken sentence
  };
  if (tf && keys.includes(tf.key)) keySel.value = tf.key; else if (tf) { tf = null; saveFilter(); }
  fillValues();
  // a remembered value that no instance carries any more (an override reset) would empty the grid: drop it
  if (tf && tf.value !== '' && !rows.some(r => valuesOf(r, tf!.key).includes(tf!.value))) { tf = null; saveFilter(); keySel.value = ''; fillValues(); }
  if (tf) valSel.value = tf.value;
  const changed = () => { tf = keySel.value ? { key: keySel.value, value: valSel.value } : null; saveFilter(); onChange(); };
  keySel.addEventListener('change', () => { fillValues(); changed(); });
  valSel.addEventListener('change', changed);
  return el('div', { class: 'meta tag-filter' }, 'Filter: ', keySel, eq, valSel);
}
