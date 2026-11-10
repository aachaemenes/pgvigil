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
import { Ctx, href, drillHome } from './router';
import { Fleet, forget, Level, tagsOf, worst } from './fleet';
import { hashParam, hrefWith } from './dbinfo';
import { Col, dot, el, fmtBytes } from './ui';

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

const search = el('input', { type: 'search', placeholder: 'Find instance', 'aria-label': 'find instance' });
const list = el('div', { class: 'tree-list' });
search.addEventListener('input', () => { filter = search.value.trim().toLowerCase(); draw(); });

export function mountTree(host: HTMLElement) {
  const hide = el('button', { type: 'button', class: 'tree-hide', title: 'Hide the tree' }, '«');
  hide.addEventListener('click', () => setTreeHidden(true));
  host.replaceChildren(el('div', { class: 'tree-top' }, search, hide), list);
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
function toggle(key: string) {
  if (opened.has(key)) opened.delete(key); else opened.add(key);
  // closing and opening a folder retries a read that failed (an error is never kept past the user's own retry)
  if (loads.get(key)?.err) loads.delete(key);
  try { sessionStorage.setItem('pgvigil.treeOpen', JSON.stringify([...opened])); } catch { /* private window */ }
  draw();
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
function folder(key: string, name: string, depth: number, kids: () => HTMLElement[], to?: string, on = false): HTMLElement {
  const head = el('div', { class: 'tree-node', style: rowStyle + ';' + nodeStyle(depth) }, caretFor(key, name),
    to ? el('a', { class: 'inst' + (on ? ' on' : ''), href: to, style: 'flex:1' }, name) : el('span', { class: 'folder-name', style: 'padding:.2rem .4rem' }, name));
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
function instanceFolders(ctx: Ctx, id: number, depth: number): HTMLElement[] {
  const here = ctx.instance === id;
  const tabLink = (tab: string) => href(ctx, { tab, instance: id, tag: undefined, at: undefined, task: undefined, taskInstance: undefined });
  const tabFolder = (k: string, name: string, tabs: [string, string][]) =>
    folder(`i${id}/${k}`, name, depth, () => tabs.map(([tab, label]) => el('div', { style: nodeStyle(depth + 1) }, leaf(label, tabLink(tab), here && ctx.tab === tab))));
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
      }, hrefWith(ctx, 'db', { db: dbid }, id), false);
      // the database node: its page, and under it the Tables folder
      return folder(`i${id}/db/${dbid}`, String(r.datname), depth + 1, () => [tables],
        hrefWith(ctx, 'db', { db: dbid }, id), here && ctx.tab === 'db' && curDb === dbid);
    });
  }, tabLink('dbinfo'), false);

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

  return [
    tabFolder('conf', 'Configuration', [['config', 'Configuration'], ['extensions', 'Extensions'], ['versions', 'Versions'], ['roles', 'Roles']]),
    tabFolder('checks', 'Checks', [['summary', 'Daily checks (summary)'], ['findings', 'Findings']]),
    tabFolder('repl', 'Replication', [['replication', 'Replication'], ['dms', 'DMS']]),
    tabFolder('storage', 'Storage', [['storage', 'Storage'], ['dbinfo', 'Database info'], ['backups', 'Backups']]),
    databases,
    jobs,
  ];
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
    caret.addEventListener('click', () => {
      if (collapsed.has(fo.path)) collapsed.delete(fo.path); else collapsed.add(fo.path);
      lsSet('pgvigil.collapsed', JSON.stringify([...collapsed]));
      draw();
    });
    const text = `${fo.label} (${fo.rows.length})`;
    const label = fo.tag
      ? el('a', { class: 'folder-name' + (!ctx.instance && ctx.tag === fo.tag ? ' on' : ''), href: href(ctx, { tab: rootTab, instance: undefined, tag: fo.tag }) }, text)
      : el('span', { class: 'folder-name' + (fo.muted ? ' muted' : ''), title: depth > 0 ? 'A nested folder: open its top folder for a tag scope' : '' }, text);
    const box = el('div', { class: 'folder', style: depth ? 'margin-left:.8rem' : '' }, el('div', { class: 'folder-head' }, caret, dot(rollup(f, fo.rows)), label));
    if (!shut) {
      const ul = el('div', { class: 'folder-items' });
      if (fo.kids.length) {
        for (const k of fo.kids) { const e = render(k, depth + 1); if (e) ul.append(e); }
      } else {
        for (const r of shown) {
          const id = Number(r.instance_id);
          const tab = ctx.instance ? (drillHome[ctx.tab] ?? ctx.tab) : 'summary';   // a drill page's link to another instance lands on its home tab
          const key = `i${id}`;
          ul.append(el('div', { class: 'tree-inst', style: rowStyle }, caretFor(key, String(r.name)),
            el('a', { class: 'inst' + (id === ctx.instance ? ' on' : ''), style: 'flex:1;min-width:0', href: href(ctx, { tab, instance: id, tag: undefined, at: undefined, task: undefined, taskInstance: undefined }), title: `${r.platform ?? ''} ${r.server_version ?? ''}` },
              dot(worst(f, r)), String(r.name))));
          if (opened.has(key)) ul.append(...instanceFolders(ctx, id, 1));
        }
      }
      box.append(ul);
    }
    return box;
  };
  const out: HTMLElement[] = [all];
  for (const fo of foldersFor(f.instances, ui.group_by, 0, '')) { const e = render(fo, 0); if (e) out.push(e); }
  if (f.instances.length === 0) out.push(el('p', { class: 'empty' }, 'No instances yet: run the collector.'));
  // a redraw replaces every node: a caret that had the keyboard focus gets it back (by its key), so a keyboard or
  // screen-reader user stays where they were after opening a folder and after its children arrive
  // an instance in two tag folders has two carets with one key: the focus goes back to the same copy (its index)
  const active = (document.activeElement as HTMLElement | null)?.closest<HTMLElement>('#tree button.caret');
  const focused = active?.dataset.key;
  const sameKey = (k: string) => [...list.querySelectorAll<HTMLElement>(`button.caret[data-key="${CSS.escape(k)}"]`)];
  const copy = focused ? sameKey(focused).indexOf(active!) : -1;
  list.replaceChildren(...out);
  if (focused) { const all = sameKey(focused); (all[copy] ?? all[0])?.focus(); }
}

// ---- the instance header's chips

const chipStyle = 'display:inline-block;margin:0 .25rem;padding:0 .45rem;border:1px solid var(--line);border-radius:9px;font-size:12px;font-weight:400';

// tagChips: one chip per tag of an instance, its top-level folder link; a chip set by 'pgvigil tag' says so.
export function tagChips(ctx: Ctx, r: Row): HTMLElement {
  const ov = ui.overridden.get(Number(r.instance_id)) ?? new Set<string>();
  const ps = pairsOf(r).sort((a, b) => a.key.localeCompare(b.key) || cmpValues(a.value, b.value));
  return el('span', { class: 'tag-chips' }, ...ps.map(t => {
    const a = el('a', { class: 'tag-chip', style: chipStyle + (ov.has(t.key) ? ';border-style:dashed' : ''), href: href(ctx, { tab: 'summary', instance: undefined, tag: tagText(t) }) }, tagText(t));
    a.title = ov.has(t.key) ? `set by 'pgvigil tag' (a repository override of the config's ${t.key})` : 'from the config';
    return a;
  }));
}

// ---- the Summary's tag columns and filter

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

// tagCols: the Summary columns for withTagFields' fields (the label is the key; the cell shows the values).
export function tagCols(keys: string[]): Col[] {
  return keys.map(k => ({ key: 't_' + k, label: k === 'tag' ? 'tags' : k, fmt: (v: unknown) => v == null ? '' : String(v).slice(4) }));
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
  const fillValues = () => {
    const k = keySel.value;
    const vs = [...new Set(rows.flatMap(r => valuesOf(r, k)))].sort(cmpValues);
    valSel.replaceChildren(...vs.map(v => el('option', { value: v }, v)), el('option', { value: '' }, `(no ${k})`));
    valSel.disabled = !k;
    valSel.style.display = k ? '' : 'none';
  };
  if (tf && keys.includes(tf.key)) keySel.value = tf.key; else if (tf) { tf = null; saveFilter(); }
  fillValues();
  // a remembered value that no instance carries any more (an override reset) would empty the grid: drop it
  if (tf && tf.value !== '' && !rows.some(r => valuesOf(r, tf!.key).includes(tf!.value))) { tf = null; saveFilter(); keySel.value = ''; fillValues(); }
  if (tf) valSel.value = tf.value;
  const changed = () => { tf = keySel.value ? { key: keySel.value, value: valSel.value } : null; saveFilter(); onChange(); };
  keySel.addEventListener('change', () => { fillValues(); changed(); });
  valSel.addEventListener('change', changed);
  return el('div', { class: 'meta tag-filter' }, 'Filter: ', keySel, ' = ', valSel);
}
