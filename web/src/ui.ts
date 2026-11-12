// DOM helpers and formatters. Data is always set as text, never parsed as HTML.
import { fmt } from './tz';

export function el<K extends keyof HTMLElementTagNameMap>(
  tag: K, attrs: Record<string, string> = {}, ...kids: (Node | string | null | undefined)[]
): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  for (const k of kids) if (k !== null && k !== undefined) e.append(k);
  return e;
}

export function fmtTime(v: unknown): string {
  if (typeof v !== 'string') return v == null ? '' : String(v);
  const d = new Date(v);
  return isNaN(d.getTime()) ? v : fmt(d);
}

export function fmtSecs(v: unknown): string {
  if (v == null || v === '') return '';
  let s = Number(v);
  if (!isFinite(s)) return String(v);
  const neg = s < 0; s = Math.abs(s);
  const d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), r = Math.floor(s % 60);
  const t = d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : m ? `${m}m ${r}s` : `${r}s`;
  return neg ? '-' + t : t;
}

export function fmtBytes(v: unknown): string {
  if (v == null || v === '') return '';
  let n = Number(v);
  if (!isFinite(n)) return String(v);
  const u = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  let i = 0;
  while (Math.abs(n) >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return (i ? n.toFixed(1) : String(Math.round(n))) + ' ' + u[i];
}

export function fmtNum(v: unknown): string {
  if (v == null || v === '') return '';
  const n = Number(v);
  if (!isFinite(n)) return String(v);
  return n.toLocaleString(undefined, { maximumFractionDigits: 2 });
}

export function fmtAny(v: unknown): string {
  if (v == null) return '';
  if (Array.isArray(v)) return v.join(', ');
  if (typeof v === 'object') return JSON.stringify(v);
  if (typeof v === 'string' && /^\d{4}-\d\d-\d\dT/.test(v)) return fmtTime(v);
  return String(v);
}

export interface Col {
  key: string;
  label?: string;
  fmt?: (v: unknown, row: Record<string, unknown>) => string | Node;
  num?: boolean;          // right-aligned, sorted numerically
  wide?: boolean;         // long text, clipped with a title
  cls?: (v: unknown, row: Record<string, unknown>) => string;   // an extra cell class (a status colour)
}

// The page model of a rendered grid, kept beside its table for the export (export.ts): the columns and the
// rows in the order the screen shows them now, their raw values unformatted, so a number exports as a number.
// rows: the grid's rows as filtered and sorted; allRows: each of them as a table row, the ones not drawn yet (past the
// grid's page) built off the screen, so the export and Copy all take every row without drawing them
export interface GridModel { cols: Col[]; rows(): Record<string, unknown>[]; allRows?(): HTMLTableRowElement[] }
const models = new WeakMap<HTMLTableElement, GridModel>();
export function gridModel(t: HTMLTableElement): GridModel | undefined { return models.get(t); }

// a cell's words as the screen means them: a statement shown as its first characters carries the whole text in
// data-full, a colour-only status cell its words in data-text (export.ts reads cells the same way)
export function cellText(e: Element): string {
  return e.querySelector('[data-full]')?.getAttribute('data-full')
    ?? ((e.textContent ?? '').replace(/\s+/g, ' ').trim() || (e.querySelector('[data-text]')?.getAttribute('data-text') ?? ''));
}

// copyText puts text on the clipboard (the async API on a secure origin, a hidden textarea elsewhere); true = copied
export async function copyText(t: string): Promise<boolean> {
  try { await navigator.clipboard.writeText(t); return true; } catch { /* not a secure origin, or refused: the fallback */ }
  const ta = el('textarea', { 'aria-hidden': 'true', style: 'position:fixed;left:-9999px' }) as HTMLTextAreaElement;
  ta.value = t; document.body.append(ta); ta.select();
  try { return document.execCommand('copy'); } catch { return false; } finally { ta.remove(); }
}

// saveBlob hands the browser a file to save under a name
export function saveBlob(blob: Blob, name: string) {
  const a = el('a', { href: URL.createObjectURL(blob), download: name });
  a.hidden = true;
  document.body.append(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(a.href), 60000);
}

// A number as the cell SHOWS it, never its raw value (a size shown as '1.5 GB' is bytes underneath, a duration shown as
// '18m 0s' milliseconds or seconds): a filter compares what the reader sees. A size or a duration is read into one
// scale (bytes; seconds), so '>500 MB' or '>10m' compares across the cell's own units; a bare number compares with the
// number shown ('>5' on '1.5 GB' is false). Commas are thousands separators. null = not a number.
const sizeUnits: Record<string, number> = { b: 1, kb: 1024, mb: 1024 ** 2, gb: 1024 ** 3, tb: 1024 ** 4, pb: 1024 ** 5 };
const timeUnits: Record<string, number> = { ms: 0.001, s: 1, m: 60, min: 60, h: 3600, d: 86400 };
interface Reading { n: number; scale: 'size' | 'time' | 'plain' }
// fmtNum writes a bare number in the browser's locale ('1,234.5', '1.234,5', '1 234,5'); fmtBytes and fmtSecs write a
// unit's number with a '.' and no grouping. plainNumber reads the locale's form back.
const localeMarks = (() => {
  const parts = new Intl.NumberFormat(undefined).formatToParts(1234567.5);
  return { group: parts.find(p => p.type === 'group')?.value ?? ',', decimal: parts.find(p => p.type === 'decimal')?.value ?? '.' };
})();
function plainNumber(text: string): number | null {
  const t = text.split(localeMarks.group).join('').replace(/[\u00a0\u202f]/g, '').split(localeMarks.decimal).join('.');
  const m = /-?\d+(?:\.\d+)?/.exec(t);
  return m ? Number(m[0]) : null;
}
// what the reader TYPES, in any form ('1000.5', '1,000.5', '1.000,5', '1000,5'): of '.' and ',' the last one present is
// the decimal mark and the other groups; a lone ',' is the decimal mark only where the locale writes it so. The result
// is written with '.' and no grouping, the form reading() takes for a unit's number.
function typedNumber(text: string): string {
  const t = text.replace(/[\s\u00a0\u202f]+(?=\d)/g, '');
  const dot = t.lastIndexOf('.'), comma = t.lastIndexOf(',');
  if (dot >= 0 && comma >= 0) return dot > comma ? t.replace(/,/g, '') : t.replace(/\./g, '').replace(',', '.');
  if (comma >= 0) return localeMarks.decimal === ',' && t.indexOf(',') === comma ? t.replace(',', '.') : t.replace(/,/g, '');
  return t;
}
function reading(text: string, typed = false): Reading | null {
  const t = text.trim().toLowerCase();
  const parts = [...t.matchAll(/(\d+(?:\.\d+)?)\s*(pb|tb|gb|mb|kb|b|ms|min|s|m|h|d)?\b/g)];
  if (!parts.length) return null;
  const neg = /^-/.test(t) ? -1 : 1;   // fmtSecs puts one sign before every part ('-5m 3s' is -303 s)
  const u = parts[0][2];
  if (u && u in sizeUnits) return { n: neg * Number(parts[0][1]) * sizeUnits[u], scale: 'size' };
  if (u && u in timeUnits) {   // '18m 0s', '1h 2m': every part summed
    let sec = 0;
    for (const p of parts) { if (!p[2] || !(p[2] in timeUnits)) break; sec += Number(p[1]) * timeUnits[p[2]]; }
    return { n: neg * sec, scale: 'time' };
  }
  const n = typed ? Number(/-?\d+(?:\.\d+)?/.exec(t)?.[0] ?? NaN) : plainNumber(t);
  return n == null || Number.isNaN(n) ? null : { n, scale: 'plain' };
}
// a filter's test on one cell's words: '>5', '<10', '>=', '<=', '=3', '>500 MB', '<10m' compare a number column as
// shown (reading()); anything else is a case-insensitive part of the words ('!x' = does not contain x)
export function passes(f: string, words: string, num: boolean): boolean {
  const m = num ? /^(>=|<=|>|<|=)\s*(.+)$/.exec(f) : null;
  const want = m ? reading(typedNumber(m[2]), true) : null;
  if (m && want) {
    const got = reading(words);
    if (!got) return false;                                    // an empty or 'n/a' cell is not a number
    // a bare number compares with the first number the cell shows; a unit compares within its own class
    const v = want.scale === 'plain' ? (got.scale === 'plain' ? got.n : Number(/-?\d+(?:\.\d+)?/.exec(words)?.[0] ?? NaN)) : got.scale === want.scale ? got.n : NaN;
    if (Number.isNaN(v)) return false;
    const x = want.n, eq = Math.abs(v - x) <= 1e-9 * Math.max(1, Math.abs(x));
    return m[1] === '>' ? v > x && !eq : m[1] === '<' ? v < x && !eq : m[1] === '>=' ? v > x || eq : m[1] === '<=' ? v < x || eq : eq;
  }
  const w = words.toLowerCase();
  return f.startsWith('!') ? !w.includes(f.slice(1).toLowerCase()) : w.includes(f.toLowerCase());
}

// one small menu at a time (the grids' copy menu): Escape, a click elsewhere or a choice closes it and gives the focus back
let openMenu: { box: HTMLElement; back: HTMLElement | null } | null = null;
function closeMenu() { if (!openMenu) return; const m = openMenu; openMenu = null; m.box.remove(); if (m.back?.isConnected) m.back.focus(); }
document.addEventListener('mousedown', e => { if (openMenu && !openMenu.box.contains(e.target as Node)) closeMenu(); });
// Escape closes it wherever the focus went; Tab out of it closes it too
document.addEventListener('keydown', e => { if (openMenu && e.key === 'Escape') { e.preventDefault(); closeMenu(); } });
document.addEventListener('focusin', e => { if (openMenu && !openMenu.box.contains(e.target as Node)) dropMenu(); });
// a page change, a re-render (main.ts render calls it) or a scroll leaves no menu behind: the page under it is gone or moved
export const dropMenu = () => { if (openMenu) { openMenu.box.remove(); openMenu = null; } };
window.addEventListener('hashchange', dropMenu);
window.addEventListener('scroll', dropMenu, true);
export function showMenu(x: number, y: number, items: [string, () => void][], back: HTMLElement | null) {
  closeMenu();
  const box = el('div', { class: 'menu', role: 'menu', style: `left:${x}px;top:${y}px` });
  for (const [label, act] of items) {
    const b = el('button', { type: 'button', role: 'menuitem' }, label);
    b.addEventListener('click', () => { closeMenu(); act(); });
    box.append(b);
  }
  box.addEventListener('keydown', e => {
    const bs = [...box.querySelectorAll('button')], i = bs.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === 'Escape') { e.preventDefault(); closeMenu(); }
    else if (e.key === 'ArrowDown') { e.preventDefault(); bs[(i + 1) % bs.length].focus(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); bs[(i - 1 + bs.length) % bs.length].focus(); }
  });
  // a grid inside a modal dialog (the file viewers, task 172): the menu goes into that dialog, the top layer, or it would
  // sit under it, inert
  (back?.closest('dialog[open]') ?? document.body).append(box);
  // kept inside the window: a right-click near the right or bottom edge opens it leftward or upward
  const r = box.getBoundingClientRect();
  if (r.right > innerWidth - 4) box.style.left = `${Math.max(4, x - r.width)}px`;
  if (r.bottom > innerHeight - 4) box.style.top = `${Math.max(4, y - r.height)}px`;
  openMenu = { box, back };
  (box.querySelector('button') as HTMLButtonElement).focus();
}

// grid renders rows as a sortable table; clicking a header sorts by it. Every grid also has (Darling's grids):
// a filter per column (the funnel button in its header opens and closes the filter row; '>5', '>500 MB', '<10m', '!text'
// as in passes(): a number as the cell shows it),
// and a copy menu (right-click, or the menu key / Shift+F10 on the grid): the cell, its row, or every row shown, as
// tab-separated text with the headers. The export and the copy take the rows the filter leaves.
// GRID_PAGE: the rows a grid draws before its 'show more' line (a 1,000-run job history drew a 32,000 px page)
export const GRID_PAGE = 200;

// narrowGrid scopes a grid built by grid() to the rows a predicate keeps (the time strip's stretch), without building it
// again: its sort, filters, open filter row and 'show more' place stay; note names the scope in the grid's count line,
// which the export and Copy all carry. No predicate = every row again. false = el is not a grid of grid().
const scopes = new WeakMap<Element, (keep?: (r: Record<string, unknown>) => boolean, note?: string) => void>();
export function narrowGrid(box: Element, keep?: (r: Record<string, unknown>) => boolean, note = ''): boolean {
  const set = scopes.get(box);
  if (set) set(keep, note);
  return !!set;
}

export function grid(rows: Record<string, unknown>[], cols: Col[], empty = 'No rows.'): HTMLElement {
  if (rows.length === 0) return el('p', { class: 'empty' }, empty);
  let sortKey = '', asc = true;
  let shown = rows;
  let scope: ((r: Record<string, unknown>) => boolean) | undefined, scopeNote = '';   // narrowGrid's predicate and its words
  const filters = new Map<string, string>();
  const table = el('table', { class: 'grid' });
  const thead = el('thead'), tbody = el('tbody');
  const head = el('tr'), filterRow = el('tr', { class: 'filters', hidden: '' });
  const inputs = new Map<string, HTMLInputElement>();
  const filterBtns: HTMLButtonElement[] = [];
  for (const c of cols) {
    const name = c.label ?? c.key;
    const fb = el('button', { type: 'button', class: 'filter-btn', title: 'Filter ' + name, 'aria-label': 'Filter ' + name, 'aria-expanded': 'false' }) as HTMLButtonElement;   // its glyph is CSS (::before), so a header's text stays its label
    filterBtns.push(fb);
    fb.addEventListener('click', e => {
      e.stopPropagation();
      const open = filterRow.hasAttribute('hidden');
      filterRow.toggleAttribute('hidden', !open);   // a closed row keeps its filters (the buttons stay marked)
      for (const b of filterBtns) b.setAttribute('aria-expanded', String(open));
      if (open) inputs.get(c.key)!.focus();
    });
    const th = el('th', c.num ? { class: 'num' } : {}, name, fb);
    th.addEventListener('click', () => {
      asc = sortKey === c.key ? !asc : true; sortKey = c.key;
      draw();
    });
    head.append(th);
    const inp = el('input', { type: 'search', class: 'filter', 'aria-label': 'Filter ' + name + (c.num ? ' (>, <, = a number as shown, or with a unit: >500 MB, <10m)' : ''), placeholder: c.num ? '>5, <10m, >1 GB' : 'contains' }) as HTMLInputElement;
    let wait: number | undefined;   // a redraw a beat after the last key, not on every key
    inp.addEventListener('input', () => {
      window.clearTimeout(wait);
      wait = window.setTimeout(() => {
        const v = inp.value.trim();
        if (v) filters.set(c.key, v); else filters.delete(c.key);
        fb.classList.toggle('on', !!v);
        draw();
      }, 150);
    });
    inputs.set(c.key, inp);
    filterRow.append(el('td', c.num ? { class: 'num' } : {}, inp));
  }
  thead.append(head, filterRow);
  table.append(thead, tbody);
  const fmtCell = (c: Col, r: Record<string, unknown>) => { const v = r[c.key]; return c.fmt ? c.fmt(v, r) : (c.num ? fmtNum(v) : fmtAny(v)); };
  const words = (out: string | Node) => typeof out === 'string' ? out : cellText(el('span', {}, out instanceof Node ? out.cloneNode(true) : String(out)));
  const count = el('p', { class: 'meta filter-count', role: 'status' });
  // a long grid draws its first GRID_PAGE rows and a 'show more' line under them; filters, sorting, Copy all and the
  // export (models: shown) still see every row
  let limit = GRID_PAGE;
  const more = el('p', { class: 'meta grid-more', hidden: '' });
  function draw() {
    let data = scope ? rows.filter(scope) : [...rows];
    if (filters.size) {
      const active = cols.filter(c => filters.has(c.key));
      data = data.filter(r => active.every(c => passes(filters.get(c.key)!, words(fmtCell(c, r)), !!c.num)));
    }
    if (sortKey) {
      const col = cols.find(c => c.key === sortKey)!;
      data.sort((a, b) => {
        const x = a[sortKey], y = b[sortKey];
        if (x == null) return 1; if (y == null) return -1;
        const r = col.num ? Number(x) - Number(y) : String(x).localeCompare(String(y));
        return asc ? r : -r;
      });
    }
    shown = data;
    table.dataset.rows = String(data.length);
    const drawn = data.length > limit ? data.slice(0, limit) : data;
    const why = [scope ? 'the stretch ' + scopeNote : '', filters.size ? 'filtered' : ''].filter(Boolean).join('; ');
    count.textContent = why ? `${data.length} of ${rows.length} rows shown (${why})` : '';
    more.replaceChildren();
    more.toggleAttribute('hidden', drawn.length === data.length);
    if (drawn.length < data.length) {
      const next = Math.min(GRID_PAGE, data.length - drawn.length);
      const step = el('button', { type: 'button', class: 'link' }, `Show ${next} more`);
      // the clicked button is replaced: the focus goes to the next 'Show more', else to the grid (WCAG 2.4.3)
      const refocus = () => { ((more.querySelector('button') ?? table.parentElement) as HTMLElement | null)?.focus(); };
      step.addEventListener('click', () => { limit += GRID_PAGE; draw(); refocus(); });
      const all = el('button', { type: 'button', class: 'link' }, `Show all ${data.length}`);
      all.addEventListener('click', () => { limit = Infinity; draw(); refocus(); });
      more.append(`The first ${drawn.length} of ${data.length} rows. `, step, ' · ', all);
    }
    tbody.replaceChildren(...drawn.map(rowEl));
  }
  function rowEl(r: Record<string, unknown>): HTMLTableRowElement {
    const tr = el('tr') as HTMLTableRowElement;
    for (const c of cols) {
      const v = r[c.key];
      const out = fmtCell(c, r);
      const base = c.num ? 'num' : c.wide ? 'wide' : '';
      const own = c.cls ? c.cls(v, r) : '';
      // a rule's bare class (a Col's cls: 'warn', 'crit', 'ok') is a status cell: app.css draws only td.status.*
      const extra = /^(ok|warn|crit)$/.test(own) ? 'status ' + own : own;
      const cl = [base, extra].filter(Boolean).join(' ');
      const td = el('td', cl ? { class: cl } : {});
      if (c.wide && typeof out === 'string') td.title = out;
      td.append(out);
      tr.append(td);
    }
    return tr;
  }
  models.set(table, { cols, rows: () => shown,
    allRows: () => shown.length > limit ? shown.map(rowEl) : [...tbody.children] as HTMLTableRowElement[] });
  draw();
  const wrap = el('div', { class: 'grid-wrap', tabindex: '0' }, table);   // a scrollable region the keyboard can reach (WCAG 2.1.1)
  const tsv = (trs: Element[]) => trs.filter(tr => !tr.classList.contains('trend-row')).map(tr => [...tr.children].map(td => cellText(td).replace(/[\t\n]/g, ' ')).join('\t')).join('\n');
  const header = () => cols.map(c => c.label ?? c.key).join('\t');
  // a copy that says what it did, in the grid's own status line, for a moment
  const done = (what: string) => (ok: boolean) => {
    const before = count.textContent;
    count.textContent = ok ? 'Copied ' + what : 'Not copied: the browser refused the clipboard';
    window.setTimeout(() => { if (count.textContent?.startsWith('Copied') || count.textContent?.startsWith('Not copied')) count.textContent = before; }, 2500);
  };
  wrap.addEventListener('contextmenu', e => {
    // the browser's own menu stays on a field (paste), a link (open in a new tab), a button, and over selected text
    if ((e.target as Element).closest('input, textarea, select, button, a[href]') || String(window.getSelection() ?? '').trim()) return;
    // a grid inside a grid's row (a statement's History) answers for itself; the outer grid does not replace its menu
    if ((e.target as Element).closest('.grid-wrap') !== wrap) return;
    e.stopPropagation();
    const hit = (e.target as Element).closest('tbody td');
    const td = hit && hit.parentElement?.parentElement === tbody && !hit.parentElement.classList.contains('trend-row') ? hit : null;
    const items: [string, () => void][] = [];
    if (td) {
      items.push(['Copy cell', () => { void copyText(cellText(td)).then(done('the cell')); }]);
      items.push(['Copy row', () => { void copyText(header() + '\n' + tsv([td.parentElement!])).then(done('the row')); }]);
    }
    items.push([filters.size || scope ? `Copy all ${shown.length} rows shown` : 'Copy all rows', () => {
      // every row, the ones past the grid's page built off the screen (the grid itself stays as drawn)
      void copyText(header() + '\n' + tsv(models.get(table)!.allRows!())).then(done(shown.length + ' rows'));
    }]);
    // the grid tools (gridtools.ts) add their lines to this menu: the copies with the colours, the columns, the groups, the bars
    wrap.dispatchEvent(new CustomEvent('pgvigil:gridmenu', { bubbles: true, detail: { table, td, items } }));
    e.preventDefault();
    const r = (e.target as Element).getBoundingClientRect();
    const x = e.clientX || r.left + 8, y = e.clientY || r.top + 8;
    showMenu(x, y, items, (td as HTMLElement | null) ?? wrap);
  });
  const box = el('div', { class: 'grid-box' }, count, wrap, more);
  scopes.set(box, (keep, note = '') => { scope = keep; scopeNote = note; draw(); });
  return box;
}

export function badge(text: string, kind: string): HTMLElement {
  return el('span', { class: 'badge ' + kind }, text);
}

export function errorBox(e: unknown): HTMLElement {
  return el('p', { class: 'error' }, 'Error: ' + (e instanceof Error ? e.message : String(e)));
}

export function dot(level: number, title = ''): HTMLElement {
  const e = el('span', { class: 'dot ' + (['ok', 'warn', 'crit'][level] ?? 'none') });
  if (title) e.title = title;
  return e;
}

export function tile(label: string, value: string, kind = ''): HTMLElement {
  return el('div', { class: 'tile ' + kind }, el('div', { class: 'tile-v' }, value), el('div', { class: 'tile-l' }, label));
}

// props renders label/value pairs as a two-column card.
export function props(pairs: [string, string | Node][]): HTMLElement {
  const t = el('table', { class: 'props' });
  for (const [k, v] of pairs) t.append(el('tr', {}, el('th', {}, k), el('td', {}, v)));
  return el('div', { class: 'grid-wrap', tabindex: '0' }, t);
}
