// The left tree: "All instances", then the folders, a status dot per instance from the overview checks rolled up
// per folder (a folder is as bad as its worst instance), a search box, folders that collapse (remembered per
// browser), and a button that hides the whole tree.
// Folders: with the config's ui.group_by empty, one folder per tag (an instance with two tags is in both; none =
// "untagged"); with group_by [env, team], a level per key in that order (env folders, team folders inside), an
// instance without the key under "(no env)". Values are ordered by ui.env_order (prod first), then by name. A
// tag is a plain word (key "tag") or key:value; the written form (prod, env:prod) is the tag scope the pages take
// (#/...?tag=env:prod), so only a top-level folder links: a nested one names a combination no single tag scopes.
// Also the helpers the Summary and the instance header use: tag columns and a tag filter, and tag chips.
import { get, Row, Table } from './api';
import { Ctx, href } from './router';
import { Fleet, Level, tagsOf, worst } from './fleet';
import { Col, dot, el } from './ui';

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
  if (!last) return;
  const { f, ctx } = last;
  const rootTab = ctx.instance ? 'summary' : ctx.tab;
  const all = el('a', { class: 'tree-root' + (!ctx.instance && !ctx.tag ? ' on' : ''), href: href(ctx, { tab: rootTab, instance: undefined, tag: undefined }) },
    dot(rollup(f, f.instances)), `All instances (${f.instances.length})`);
  const match = (r: Row) => !filter || String(r.name).toLowerCase().includes(filter);
  const render = (fo: Folder, depth: number): HTMLElement | null => {
    const shown = fo.rows.filter(match);
    if (filter && shown.length === 0) return null;
    const shut = collapsed.has(fo.path) && !filter;
    const caret = el('button', { type: 'button', class: 'caret', 'aria-label': shut ? 'expand' : 'collapse' }, shut ? '▸' : '▾');
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
          const tab = ctx.instance ? ctx.tab : 'summary';
          ul.append(el('a', { class: 'inst' + (id === ctx.instance ? ' on' : ''), href: href(ctx, { tab, instance: id, tag: undefined, at: undefined, task: undefined, taskInstance: undefined }), title: `${r.platform ?? ''} ${r.server_version ?? ''}` },
            dot(worst(f, r)), String(r.name)));
        }
      }
      box.append(ul);
    }
    return box;
  };
  const out: HTMLElement[] = [all];
  for (const fo of foldersFor(f.instances, ui.group_by, 0, '')) { const e = render(fo, 0); if (e) out.push(e); }
  if (f.instances.length === 0) out.push(el('p', { class: 'empty' }, 'No instances yet: run the collector.'));
  list.replaceChildren(...out);
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
