// The left tree: "All instances", then one folder per tag (an instance with two tags is in both; none =
// "untagged"), a status dot per instance from the overview checks, a search box, folders that collapse
// (remembered per browser), and a button that hides the whole tree.
import { Row } from './api';
import { Ctx, href } from './router';
import { Fleet, Level, tagsOf, worst } from './fleet';
import { dot, el } from './ui';

const UNTAGGED = 'untagged';

function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function lsSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private window */ } }

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

export function updateTree(f: Fleet, ctx: Ctx) { last = { f, ctx }; draw(); }

function draw() {
  if (!last) return;
  const { f, ctx } = last;
  const folders = new Map<string, Row[]>();
  for (const r of f.instances) for (const t of (tagsOf(r).length ? tagsOf(r) : [UNTAGGED])) {
    if (!folders.has(t)) folders.set(t, []);
    folders.get(t)!.push(r);
  }
  const names = [...folders.keys()].sort((a, b) => a === UNTAGGED ? 1 : b === UNTAGGED ? -1 : a.localeCompare(b));
  const rootTab = ctx.instance ? 'summary' : ctx.tab;
  const all = el('a', { class: 'tree-root' + (!ctx.instance && !ctx.tag ? ' on' : ''), href: href(ctx, { tab: rootTab, instance: undefined, tag: undefined }) },
    dot(f.instances.reduce<Level>((a, r) => Math.max(a, worst(f, r)) as Level, 0)), `All instances (${f.instances.length})`);
  const out: HTMLElement[] = [all];
  for (const t of names) {
    const members = folders.get(t)!.filter(r => !filter || String(r.name).toLowerCase().includes(filter));
    if (filter && members.length === 0) continue;
    const shut = collapsed.has(t) && !filter;
    const caret = el('button', { type: 'button', class: 'caret', 'aria-label': shut ? 'expand' : 'collapse' }, shut ? '▸' : '▾');
    caret.addEventListener('click', () => {
      if (collapsed.has(t)) collapsed.delete(t); else collapsed.add(t);
      lsSet('pgvigil.collapsed', JSON.stringify([...collapsed]));
      draw();
    });
    const lvl = folders.get(t)!.reduce<Level>((a, r) => Math.max(a, worst(f, r)) as Level, 0);
    const label = t === UNTAGGED
      ? el('span', { class: 'folder-name muted' }, `${t} (${folders.get(t)!.length})`)
      : el('a', { class: 'folder-name' + (!ctx.instance && ctx.tag === t ? ' on' : ''), href: href(ctx, { tab: rootTab, instance: undefined, tag: t }) }, `${t} (${folders.get(t)!.length})`);
    const folder = el('div', { class: 'folder' }, el('div', { class: 'folder-head' }, caret, dot(lvl), label));
    if (!shut) {
      const ul = el('div', { class: 'folder-items' });
      for (const r of members) {
        const id = Number(r.instance_id);
        const tab = ctx.instance ? ctx.tab : 'summary';
        ul.append(el('a', { class: 'inst' + (id === ctx.instance ? ' on' : ''), href: href(ctx, { tab, instance: id, tag: undefined, at: undefined, task: undefined, taskInstance: undefined }), title: `${r.platform ?? ''} ${r.server_version ?? ''}` },
          dot(worst(f, r)), String(r.name)));
      }
      folder.append(ul);
    }
    out.push(folder);
  }
  if (f.instances.length === 0) out.push(el('p', { class: 'empty' }, 'No instances yet: run the collector.'));
  list.replaceChildren(...out);
}
