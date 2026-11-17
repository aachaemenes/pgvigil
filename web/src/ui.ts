// DOM helpers and formatters. Data is always set as text, never parsed as HTML.
import { ApiError, ReadWindow, readWindowOf } from './api';
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
  title?: string;         // the header's tooltip (a column DBA Dash describes in its own words)
}

// The page model of a rendered grid, kept beside its table for the export (export.ts): the columns and the
// rows in the order the screen shows them now, their raw values unformatted, so a number exports as a number.
// rows: the grid's rows as filtered and sorted; allRows: each of them as a table row, the ones not drawn yet (past the
// grid's page) built off the screen, so the export and Copy all take every row without drawing them
// text: a row's cell as the screen words it (the grid menu's statistics read the rows without building them)
// keys: every key the grid's rows carry, in the order first met (the chooser's undrawn data columns, task PGRID B05);
// extra: the columns the grid draws beyond the page's own - a key each, its label the key, its header data-gt-added -
// set whole (the ones given, in that order; none = the page's own alone); a set equal to the drawn one draws nothing
export interface GridModel { cols: Col[]; rows(): Record<string, unknown>[]; allRows?(): HTMLTableRowElement[]; text?(r: Record<string, unknown>, c: Col): string;
  keys?(): string[]; extra?(keys: string[]): void;
  // all: every row the grid was given, whatever its filters or scope (Save Table > Script Data Table, task PGRID B04)
  all?(): Record<string, unknown>[] }
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
  const t = text.replace(/(?<=\d)[\s\u00a0\u202f]+(?=\d)/g, '');   // a space between two digits groups ('1 234'); '18m 0s' keeps its own
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
  const m = num ? /^(<>|>=|<=|>|<|=)\s*(.+)$/.exec(f) : null;
  const want = m ? reading(typedNumber(m[2]), true) : null;
  if (m && want) {
    const got = reading(words);
    if (!got) return false;                                    // an empty or 'n/a' cell is not a number
    // a bare number compares with the first number the cell shows; a unit compares within its own class
    const v = want.scale === 'plain' ? (got.scale === 'plain' ? got.n : Number(/-?\d+(?:\.\d+)?/.exec(words)?.[0] ?? NaN)) : got.scale === want.scale ? got.n : NaN;
    if (Number.isNaN(v)) return false;
    const x = want.n, eq = Math.abs(v - x) <= 1e-9 * Math.max(1, Math.abs(x));
    return m[1] === '<>' ? !eq : m[1] === '>' ? v > x && !eq : m[1] === '<' ? v < x && !eq : m[1] === '>=' ? v > x || eq : m[1] === '<=' ? v < x || eq : eq;
  }
  const w = words.toLowerCase();
  return f.startsWith('!') ? !w.includes(f.slice(1).toLowerCase()) : w.includes(f.toLowerCase());
}

// ---- a filter's conditions (task GM) ----------------------------------------------------------------------------
// A typed filter with no double quote keeps its meaning whole (passes: '>5', '!x', and 'R & D' is the words 'R & D').
// One with quotes is a list of conditions a row must all meet, joined by ' & ' outside the quotes (a quote inside one is
// doubled):  "x" the words hold x;  !"x" they do not;  ="x"  <>"x"  >"x"  <"x"  >="x"  <="x" (a number column compares
// the number shown, as passes does; a text column the words, case aside);  like "a%"  not like "a%" (% any run, _ one
// character, \% \_ \\ themselves);  in:"a","b"  !in:"a","b" (the words one of them / none of them);  an operator with a
// bare number (>5) as passes. A condition that reads as none of these makes the whole filter typed words again. The grid
// menu writes every condition quoted. compileFilter reads a filter once per redraw.
const QV = '"((?:[^"]|"")*)"';
const unq = (s: string) => s.replace(/""/g, '"');
export const quoteFilter = (v: string) => '"' + v.replace(/"/g, '""') + '"';
function splitConds(f: string): string[] {
  const out: string[] = []; let cur = '', q = false;
  for (let i = 0; i < f.length; i++) {
    const ch = f[i];
    if (ch === '"') { if (q && f[i + 1] === '"') { cur += '""'; i++; continue; } q = !q; cur += ch; continue; }
    if (!q && f.startsWith(' & ', i)) { out.push(cur.trim()); cur = ''; i += 2; continue; }
    cur += ch;
  }
  out.push(cur.trim());
  return out;
}
function likeRe(p: string): RegExp {
  let r = '';
  for (let i = 0; i < p.length; i++) {
    const ch = p[i];
    if (ch === '\\' && i + 1 < p.length) { r += p[++i].replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); continue; }
    if (ch === '%' && p[i - 1] === '%' && p[i - 2] !== '\\') continue;   // a run of % is one '.*' (no backtracking storm on a long cell)
    r += ch === '%' ? '.*' : ch === '_' ? '.' : ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp('^' + r + '$', 'is');
}
function condTest(c: string, num: boolean): ((w: string) => boolean) | undefined {
  let m = new RegExp('^(!?)' + QV + '$').exec(c);
  if (m) { const v = unq(m[2]).toLowerCase(), not = m[1] === '!'; return w => w.toLowerCase().includes(v) !== not; }
  m = new RegExp('^(<>|>=|<=|=|>|<)\\s*' + QV + '$').exec(c);
  if (m) {
    const op = m[1], v = unq(m[2]), n = num && reading(typedNumber(v), true);
    // <> keeps an empty cell (DBA Dash keeps a NULL row; task PGRID B11); words that are no number stay out
    if (n) return op === '<>' ? w => w === '' || (!!reading(w) && !passes('=' + v, w, true)) : w => passes(op + v, w, true);
    const lv = v.toLowerCase();
    return w => { const x = w.toLowerCase(), k = x.localeCompare(lv); return op === '=' ? x === lv : op === '<>' ? x !== lv : op === '>' ? k > 0 : op === '<' ? k < 0 : op === '>=' ? k >= 0 : k <= 0; };
  }
  m = new RegExp('^(not like|like)\\s+' + QV + '$', 'i').exec(c);
  if (m) { const re = likeRe(unq(m[2])), not = m[1].toLowerCase() === 'not like'; return w => re.test(w) !== not; }
  m = new RegExp('^(!?)in:\\s*(' + QV + '(?:\\s*,\\s*' + QV + ')*)$').exec(c);
  if (m) {
    const set = new Set([...m[2].matchAll(new RegExp(QV, 'g'))].map(x => unq(x[1]).toLowerCase())), not = m[1] === '!';
    return w => set.has(w.toLowerCase()) !== not;
  }
  if (/^(<>|>=|<=|>|<|=)\s*[^"\s]/.test(c) && !c.includes('"')) return w => passes(c, w, num);
  return undefined;
}
// isCondList: a filter with quotes that reads as a list of conditions (else compileFilter reads it as typed words)
export const isCondList = (f: string, num: boolean) => splitConds(f).every(c => !!condTest(c, num));
export function compileFilter(f: string, num: boolean): (w: string) => boolean {
  if (!f.includes('"')) return w => passes(f, w, num);
  const tests = splitConds(f).map(c => condTest(c, num));
  if (tests.some(t => !t)) return w => passes(f, w, num);
  return w => tests.every(t => t!(w));
}

// ---- the grid menu's ask (task GM) -----------------------------------------------------------------------------------
// ui.ts asks, gridtools.ts gridMenu answers (done): a grid of grid(), a table.grid a page draws itself, the group panel's
// .gt-table, a grid empty from the start (empty: its p.empty[data-cols], as the export reads it). A page adds its own
// lines to the end of the menu (extra: [label, action] pairs) from a listener on an element around its grid: the event
// bubbles there before it reaches gridtools' listener on the document (mssql_backups.ts: Verify this backup...).
export interface GridMenuAsk { table: HTMLTableElement | null; empty?: Element | null; td: Element | null; th: Element | null; x: number; y: number; back: HTMLElement; extra: [string, () => void][]; done: boolean }
export function askGridMenu(at: Element, d: Omit<GridMenuAsk, 'done' | 'extra'>): boolean {
  const detail: GridMenuAsk = { ...d, extra: [], done: false };
  at.dispatchEvent(new CustomEvent('pgvigil:gridmenu', { bubbles: true, detail }));
  return detail.done;
}
// every table.grid not drawn by grid() (a page's own, inside its own .grid-wrap or not), the group panel's table and a
// grid empty from the start: one handler for all of them (grid()'s own grids stop at their wrap, and their model skips them)
if (typeof document !== 'undefined') document.addEventListener('contextmenu', e => {
  const tgt = e.target;
  if (!(tgt instanceof Element) || tgt.closest('input, textarea, select, a[href]') || String(window.getSelection() ?? '').trim()) return;
  // a page's own focusable .grid-wrap (the menu key or Shift+F10 there) answers for its table
  const host = tgt.closest('table.grid, table.gt-table, .empty-grid') ?? (tgt.matches('.grid-wrap') ? tgt.querySelector('table.grid') : null);
  if (!host || (host instanceof HTMLTableElement && models.has(host))) return;
  const table = host.tagName === 'TABLE' ? host as HTMLTableElement : null;
  const cell = tgt.closest('td, th');
  const td = table && cell?.tagName === 'TD' && cell.closest('table') === table && cell.parentElement?.parentElement?.tagName === 'TBODY' ? cell : null;
  const th = table && cell?.tagName === 'TH' && cell.closest('table') === table && !!cell.closest('thead') ? cell : null;
  const r = tgt.getBoundingClientRect();
  const back = (document.activeElement instanceof HTMLElement ? document.activeElement : document.body);
  if (askGridMenu(host, { table, empty: table ? null : host.querySelector('p.empty[data-cols]'), td, th, x: e.clientX || r.left + 8, y: e.clientY || r.top + 8, back })) e.preventDefault();
});

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

// readWindowWords: what a list or a page read of a window longer than its reach, in words ('the newest 31 days of
// this window: <from> to <to>')
export function readWindowWords(rw: ReadWindow): string {
  const days = Math.round((Date.parse(rw.to) - Date.parse(rw.from)) / 86400e3);
  return `the newest ${days} days of this window: ${fmt(new Date(rw.from))} to ${fmt(new Date(rw.to))}`;
}
const readWindowNote = (rw: ReadWindow) => el('p', { class: 'meta read-window' }, `This list reads ${readWindowWords(rw)}.`);

export function grid(rows: Record<string, unknown>[], cols: Col[], empty = 'No rows.'): HTMLElement {
  // an empty grid is DBA Dash's: its header row alone (G08, task P08), drawn only (aria-hidden, not a .grid: the export,
  // the copy and the report mail still find the one p.empty and its data-cols), in a box that never scrolls; the words
  // stay for a screen reader and the proofs
  const rw = readWindowOf(rows);
  if (rows.length === 0) return el('div', { class: 'empty-grid', tabindex: '0', role: 'group', 'aria-label': 'Empty grid: ' + empty }, ...(rw ? [readWindowNote(rw)] : []),
    el('table', { class: 'grid-empty', 'aria-hidden': 'true' }, el('thead', {}, el('tr', {}, ...cols.map(c => el('th', c.title ? { title: c.title } : {}, el('span', { class: 'th-label' }, c.label ?? c.key)))))),
    el('p', { class: 'empty visually-hidden', 'data-cols': JSON.stringify(cols.map(c => c.label ?? c.key)) }, empty));
  let sortKey = '', asc = true;
  let shown = rows;
  let scope: ((r: Record<string, unknown>) => boolean) | undefined, scopeNote = '';   // narrowGrid's predicate and its words
  const filters = new Map<string, string>();
  const table = el('table', { class: 'grid' });
  const thead = el('thead'), tbody = el('tbody');
  const head = el('tr'), filterRow = el('tr', { class: 'filters', hidden: '' });
  const inputs = new Map<string, HTMLInputElement>();
  const filterBtns: HTMLButtonElement[] = [];
  cols = [...cols];   // the page's columns, then any the chooser adds (extra): the model's cols is this array
  const own = cols.length;
  // addHead: a column's header cell and its filter field; added: a column the chooser drew (data-gt-added)
  const addHead = (c: Col, added: boolean) => {
    const name = c.label ?? c.key;
    // (tabindex -1: the grid is one tab stop; F2 on its header cell opens the filter row - the ARIA grid pattern)
    const fb = el('button', { type: 'button', class: 'filter-btn', title: 'Filter ' + name, 'aria-label': 'Filter ' + name, 'aria-expanded': 'false', tabindex: '-1' }) as HTMLButtonElement;   // its glyph is CSS (::before), so a header's text stays its label
    filterBtns.push(fb);
    fb.addEventListener('click', e => {
      e.stopPropagation();
      const open = filterRow.hasAttribute('hidden');
      filterRow.toggleAttribute('hidden', !open);   // a closed row keeps its filters (the buttons stay marked)
      for (const b of filterBtns) b.setAttribute('aria-expanded', String(open));
      if (open) inputs.get(c.key)!.focus();
    });
    const th = el('th', { ...(c.num ? { class: 'num' } : {}), ...(c.title ? { title: c.title } : {}), ...(added ? { 'data-gt-added': '' } : {}) }, el('span', { class: 'th-label' }, name), fb);
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
  };
  for (const c of cols) addHead(c, false);
  // a filter row opened before a column was added: the new field opens with it (the buttons say the row's state)
  const syncFilterBtns = () => { const open = !filterRow.hasAttribute('hidden'); for (const b of filterBtns) b.setAttribute('aria-expanded', String(open)); };
  thead.append(head, filterRow);
  table.append(thead, tbody);
  const fmtCell = (c: Col, r: Record<string, unknown>) => { const v = r[c.key]; return c.fmt ? c.fmt(v, r) : (c.num ? fmtNum(v) : fmtAny(v)); };
  const shownWords = (w: string) => w.replace(/\s+/g, ' ').trim();   // what a cell shows (cellText's rule), the filter's side
  const words = (out: string | Node) => typeof out === 'string' ? out : cellText(el('span', {}, out instanceof Node ? out.cloneNode(true) : String(out)));
  const count = el('p', { class: 'meta filter-count', role: 'status' });
  // a long grid draws its first GRID_PAGE rows and a 'show more' line under them; filters, sorting, Copy all and the
  // export (models: shown) still see every row
  let limit = GRID_PAGE;
  const more = el('p', { class: 'meta grid-more', hidden: '' });
  function draw() {
    let data = scope ? rows.filter(scope) : [...rows];
    if (filters.size) {
      const active = cols.filter(c => filters.has(c.key)).map(c => [c, compileFilter(filters.get(c.key)!, !!c.num)] as const);
      data = data.filter(r => active.every(([c, t]) => t(shownWords(words(fmtCell(c, r))))));
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
      const refocus = () => { const b = more.querySelector('button') as HTMLElement | null; if (b) b.focus(); else rove(true); };
      step.addEventListener('click', () => { limit += GRID_PAGE; draw(); refocus(); });
      const all = el('button', { type: 'button', class: 'link' }, `Show all ${data.length}`);
      all.addEventListener('click', () => { limit = Infinity; draw(); refocus(); });
      more.append(`The first ${drawn.length} of ${data.length} rows. `, step, ' · ', all);
    }
    const had = tbody.contains(document.activeElement);
    tbody.replaceChildren(...drawn.map(rowEl));
    table.setAttribute('aria-rowcount', String(data.length));
    quiet(); rove(had);
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
  // ---- the keyboard (the ARIA grid pattern, task GM): the grid is one tab stop, its current cell (a roving tabindex);
  // the arrows, Home / End (Ctrl: the first / last row), PageUp / PageDown move it (PageDown past the drawn rows reaches
  // 'Show more'); Enter or F2 reaches a cell's own link or button (Escape there comes back to the cell); on a header
  // cell Enter sorts and F2 opens the filter row; the menu key or Shift+F10 opens the grid's menu at the cell
  table.setAttribute('role', 'grid');
  let cur: [number, number] = [0, 0];   // the current cell: its drawn row (-1 the header) and its column
  // a hidden column is data-gt-hidden on its header (gridtools.ts apply), read at once - a detached table has no style
  const vis = (j: number) => { const h = head.children[j] as HTMLElement | undefined; return !!h && !h.hasAttribute('data-gt-hidden'); };
  // the grid's rows: a statement's History (.trend-row) is not one of them
  const bodyRows = () => [...tbody.children].filter(tr => !tr.classList.contains('trend-row')) as HTMLElement[];
  const cellAt = (r: number, j: number) => (r < 0 ? head.children[j] : bodyRows()[r]?.children[j]) as HTMLElement | undefined;
  // a cell's place, null for a History row's cell
  const at = (cell: HTMLElement): [number, number] | null => {
    const tr = cell.parentElement!, r = tr === head ? -1 : bodyRows().indexOf(tr);
    return tr !== head && r < 0 ? null : [r, [...tr.children].indexOf(cell)];
  };
  const firstCol = () => { for (let j = 0; j < cols.length; j++) if (vis(j)) return j; return 0; };
  const lastCol = () => { for (let j = cols.length - 1; j >= 0; j--) if (vis(j)) return j; return 0; };
  const stepCol = (j: number, by: number) => { for (let k = j + by; k >= 0 && k < cols.length; k += by) if (vis(k)) return k; return j; };
  function rove(focus: boolean) {
    const n = bodyRows().length;
    if (cur[0] >= n) cur[0] = n - 1;
    if (!vis(cur[1])) cur[1] = firstCol();
    const c = cellAt(cur[0], cur[1]) ?? cellAt(-1, cur[1]);
    table.querySelectorAll<HTMLElement>(':scope > thead > tr > th[tabindex], :scope > tbody > tr > td[tabindex]').forEach(x => { if (x !== c) x.removeAttribute('tabindex'); });
    if (!c) return;
    c.tabIndex = 0;
    if (focus) { c.focus({ preventScroll: true }); c.scrollIntoView({ block: 'nearest', inline: 'nearest' }); }
  }
  // a cell's own links and buttons leave the tab order (Enter or F2 reaches them)
  function quiet() { tbody.querySelectorAll<HTMLElement>('a[href], button, input, select, textarea, summary, [tabindex]').forEach(x => { if (x.tagName !== 'TD') x.tabIndex = -1; }); }
  table.addEventListener('keydown', e => {
    const t = e.target as HTMLElement, cell = t.closest('td, th') as HTMLElement | null;
    if (!cell || cell.closest('table') !== table || cell.parentElement === filterRow) return;
    const place = at(cell);
    if (!place) return;
    if (t !== cell) { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); cur = place; rove(true); } return; }
    const [r, j] = place;
    cur = place;
    const last = bodyRows().length - 1;
    let to: [number, number] | null = null;
    if (e.key === 'ArrowDown') to = [Math.min(last, r + 1), j];
    else if (e.key === 'ArrowUp') to = [Math.max(-1, r - 1), j];
    else if (e.key === 'ArrowRight') to = [r, stepCol(j, 1)];
    else if (e.key === 'ArrowLeft') to = [r, stepCol(j, -1)];
    else if (e.key === 'Home') to = [e.ctrlKey ? 0 : r, firstCol()];
    else if (e.key === 'End') to = [e.ctrlKey ? last : r, lastCol()];
    else if (e.key === 'PageUp') to = [Math.max(r < 0 ? -1 : 0, r - 10), j];
    else if (e.key === 'PageDown') {
      if (r + 10 > last && !more.hidden) { e.preventDefault(); (more.querySelector('button') as HTMLElement | null)?.focus(); return; }
      to = [Math.min(last, r + 10), j];
    } else if (e.key === 'Enter' || e.key === 'F2') {
      e.preventDefault();
      if (r < 0) { if (e.key === 'Enter') cell.click(); else (cell.querySelector('.filter-btn') as HTMLElement | null)?.click(); return; }
      (cell.querySelector('a[href], button, input, select, textarea, summary') as HTMLElement | null)?.focus();
      return;
    } else if (e.key === 'ContextMenu' || (e.key === 'F10' && e.shiftKey)) {
      e.preventDefault();
      const b = cell.getBoundingClientRect();
      openGrid(cell, b.left + 8, b.bottom - 4, cell);
      return;
    }
    if (!to) return;
    e.preventDefault();
    cur = to; rove(true);
  });
  // every key the rows carry, in the order first met (the chooser's undrawn data columns)
  // read once: a grid's rows never change (a page draws a new grid for new rows), and the tools ask at every redraw
  let keyList: string[] | null = null;
  const keys = () => { if (!keyList) { const ks = new Set<string>(); for (const r of rows) for (const k of Object.keys(r)) ks.add(k); keyList = [...ks]; } return [...keyList]; };
  // extra: the added columns set whole; a key the page draws itself, or not in the rows, is never added; a number column
  // when every value it holds is a number
  const extra = (want: string[]) => {
    const mine = new Set(cols.slice(0, own).map(c => c.key)), have = new Set(keys());
    const next = [...new Set(want)].filter(k => !mine.has(k) && have.has(k));
    if (next.join('\u0000') === cols.slice(own).map(c => c.key).join('\u0000')) return;
    for (let j = cols.length - 1; j >= own; j--) {
      const c = cols[j];
      head.children[j]?.remove(); filterRow.children[j]?.remove(); filterBtns.splice(j, 1);
      inputs.delete(c.key); filters.delete(c.key);
      if (sortKey === c.key) sortKey = '';
      cols.splice(j, 1);
    }
    for (const k of next) {
      const vals = rows.map(r => r[k]).filter(v => v != null && v !== '');
      const c: Col = { key: k, label: k, num: vals.length > 0 && vals.every(v => typeof v === 'number') };
      cols.push(c); addHead(c, true);
    }
    syncFilterBtns();
    draw();
  };
  models.set(table, { cols, rows: () => shown,
    allRows: () => shown.length > limit ? shown.map(rowEl) : [...tbody.children] as HTMLTableRowElement[],
    text: (r, c) => words(fmtCell(c, r)), keys, extra, all: () => rows });
  draw();
  new MutationObserver(() => rove(document.activeElement === document.body)).observe(head, { attributes: true, subtree: true, attributeFilter: ['data-gt-hidden'] });
  const wrap = el('div', { class: 'grid-wrap' }, table);   // its scroll is the keyboard's through the table's current cell (one tab stop)
  const tsv = (trs: Element[]) => trs.filter(tr => !tr.classList.contains('trend-row')).map(tr => [...tr.children].map(td => cellText(td).replace(/[\t\n]/g, ' ')).join('\t')).join('\n');
  const header = () => cols.map(c => c.label ?? c.key).join('\t');
  // a copy that says what it did, in the grid's own status line, for a moment
  const done = (what: string) => (ok: boolean) => {
    const before = count.textContent;
    count.textContent = ok ? 'Copied ' + what : 'Not copied: the browser refused the clipboard';
    window.setTimeout(() => { if (count.textContent?.startsWith('Copied') || count.textContent?.startsWith('Not copied')) count.textContent = before; }, 2500);
  };
  // openGrid: the grid's menu (gridtools.ts gridMenu answers the ask) at a cell, a header cell or none; the cell becomes
  // the current one, so the menu gives the focus back to it. With no grid tools on the page: the three copies.
  function openGrid(cell: Element | null, x: number, y: number, back: HTMLElement) {
    const td = cell?.tagName === 'TD' && cell.parentElement?.parentElement === tbody && !cell.parentElement.classList.contains('trend-row') ? cell : null;
    const th = cell?.tagName === 'TH' && cell.parentElement === head ? cell : null;
    if (td) cur = [bodyRows().indexOf(td.parentElement!), [...td.parentElement!.children].indexOf(td)];
    else if (th) cur = [-1, [...head.children].indexOf(th)];
    if (td || th) rove(false);
    if (askGridMenu(table, { table, td, th, x, y, back: (td ?? th ?? back) as HTMLElement })) return;
    const items: [string, () => void][] = [];
    if (td) {
      items.push(['Copy cell', () => { void copyText(cellText(td)).then(done('the cell')); }]);
      items.push(['Copy row', () => { void copyText(header() + '\n' + tsv([td.parentElement!])).then(done('the row')); }]);
    }
    items.push([filters.size || scope ? `Copy all ${shown.length} rows shown` : 'Copy all rows', () => {
      void copyText(header() + '\n' + tsv(models.get(table)!.allRows!())).then(done(shown.length + ' rows'));
    }]);
    showMenu(x, y, items, (td as HTMLElement | null) ?? back);
  }
  wrap.addEventListener('contextmenu', e => {
    // the browser's own menu stays on a field (paste), a link (open in a new tab) and over selected text; a statement's
    // button (sqlview.ts) gets the grid's menu (its Copy > Cell is the whole statement)
    const tgt = e.target as Element;
    if (tgt.closest('input, textarea, select, a[href]') || String(window.getSelection() ?? '').trim()) return;
    // a grid inside a grid's row (a statement's History) answers for itself; the outer grid does not replace its menu
    if (tgt.closest('.grid-wrap') !== wrap) return;
    e.stopPropagation();
    e.preventDefault();
    const r = tgt.getBoundingClientRect();
    openGrid(tgt.closest('td, th'), e.clientX || r.left + 8, e.clientY || r.top + 8, table);
  });
  // a list whose part read only the newest part of a long window says so above itself, and its table carries the read
  // window for the export's sheet note (export.ts)
  if (rw) { table.dataset.readFrom = rw.from; table.dataset.readTo = rw.to; }
  const box = el('div', { class: 'grid-box' }, ...(rw ? [readWindowNote(rw)] : []), count, wrap, more);
  scopes.set(box, (keep, note = '') => { scope = keep; scopeNote = note; draw(); });
  return box;
}

// badge: a state's word as a pill (its tint behind its own colour; app.css .badge); in a solid status cell it takes the
// fill's text colour, no tint
export function badge(text: string, kind: string): HTMLElement {
  return el('span', { class: 'badge ' + kind }, text);
}
// pill: the short form of a state on a tile or a card (CRIT, WARN, OK), the same shape as a badge
export function pill(text: string, kind: string): HTMLElement {
  return el('span', { class: 'badge pill ' + kind }, text);
}

// offControl: a control that cannot act here says why in words (a control does its work, or it is off with its reason
// beside it). It stays in the tab order (aria-disabled, never the disabled attribute), a click on it (Enter and Space
// click too) does nothing, its reason is visible text and its description (aria-describedby), and title repeats it for
// a mouse. reasonEl: the visible text that already says it (a needs cell, a note above); none = a note made here,
// returned for the caller to place beside the control. reason null = on again.
let offSeq = 0;
export function offControl(c: HTMLElement, reason: string | null, reasonEl?: HTMLElement): HTMLElement {
  const made = c.dataset.offNote ? document.getElementById(c.dataset.offNote) : null;
  const note = reasonEl ?? (made && made.classList.contains('off-reason') ? made : el('span', { class: 'off-reason' }));
  if (!note.id) note.id = 'off-' + String(++offSeq);
  c.dataset.offNote = note.id;
  if (!c.dataset.offGuard) {
    c.dataset.offGuard = '1';
    c.addEventListener('click', e => { if (c.getAttribute('aria-disabled') === 'true') { e.preventDefault(); e.stopImmediatePropagation(); } }, { capture: true });
  }
  c.removeAttribute('disabled');
  if (reason) {
    c.setAttribute('aria-disabled', 'true');
    c.setAttribute('aria-describedby', note.id);
    c.title = reason;
    if (!reasonEl) note.textContent = reason;
  } else {
    c.removeAttribute('aria-disabled');
    c.removeAttribute('aria-describedby');
    c.removeAttribute('title');
    if (!reasonEl) note.textContent = '';
  }
  return note;
}

// errorDetails: the text an error box shows on Show details and gives to Copy details (DBA Dash 3.25's error dialog:
// Show Error Details / Copy Error Details). For a read or a write the server refused: the request's method and
// address, the HTTP status, the server's words and the time; for any other error its name, its message and where it
// was thrown. All of it is the viewer's own browser's - the address it asked and the answer it got - and never a
// request's body.
export function errorDetails(e: unknown, page = location.hash || '#/'): string {
  const out: string[] = [];
  if (e instanceof ApiError) out.push(`${e.method} ${e.url}`, `HTTP ${e.status}${e.statusText ? ' ' + e.statusText : ''}`, `The server's words: ${e.message}`, `At ${e.at.toISOString()}`);
  else if (e instanceof Error) {
    out.push(`${e.name}: ${e.message}`);
    for (const l of (e.stack ?? '').split('\n').slice(1, 7)) if (l.trim()) out.push(l.trim());
  } else out.push(String(e));
  out.push(`Page ${page}`);
  return out.join('\n');
}

// errorBox: the message as it always was (a p.error: 'Error: ' and the error's words), and under it Show details /
// Copy details. The details are drawn only while shown, so the box's text is the message until they are asked for.
let errorSeq = 0;
export function errorBox(e: unknown): HTMLElement {
  const text = errorDetails(e), id = `error-details-${++errorSeq}`;
  const pre = el('pre', { class: 'error-details', id, hidden: '' });
  const show = el('button', { type: 'button', class: 'link', 'aria-expanded': 'false', 'aria-controls': id }, 'Show details');
  show.addEventListener('click', () => {
    const open = show.getAttribute('aria-expanded') !== 'true';
    show.setAttribute('aria-expanded', String(open));
    show.textContent = open ? 'Hide details' : 'Show details';
    pre.textContent = open ? text : '';
    pre.toggleAttribute('hidden', !open);
  });
  const said = el('span', { class: 'meta', role: 'status' });
  const copy = el('button', { type: 'button', class: 'link' }, 'Copy details');
  copy.addEventListener('click', () => { void copyText(text).then(ok => { said.textContent = ok ? 'Copied.' : 'The browser refused the copy: show the details and copy them by hand.'; }); });
  return el('div', { class: 'error-box' }, el('p', { class: 'error' }, 'Error: ' + (e instanceof Error ? e.message : String(e))),
    el('p', { class: 'error-tools' }, show, ' ', copy, ' ', said), pre);
}

export function dot(level: number, title = ''): HTMLElement {
  const e = el('span', { class: 'dot ' + (['ok', 'warn', 'crit'][level] ?? 'none') });
  if (title) e.title = title;
  return e;
}

// tile: a card - a left stripe in its state colour (kind 'ok' | 'warn' | 'crit', '' for none), a small muted label over a
// large figure, an optional unit beside the figure and a sub line under it, and on a critical or a warning tile a CRIT
// or WARN pill (the state in words, not the colour alone; o.pill false leaves it out, a string names it). The figure
// (.tile-v) is the first child and the label (.tile-l) holds only its words: the proofs read both; app.css draws the
// label above the figure.
// A label that is itself a state's word ('Critical', 'Warnings') takes no pill: it would say the state twice.
export interface TileOpts { unit?: string; sub?: string | Node; pill?: string | false }
export function tile(label: string, value: string, kind = '', o: TileOpts = {}): HTMLElement {
  const said = /^(critical|warnings?|ok|healthy)$/i.test(label.trim());
  const word = o.pill === false || said ? '' : o.pill ?? (kind === 'crit' ? 'CRIT' : kind === 'warn' ? 'WARN' : '');
  return el('div', { class: 'tile ' + kind },
    el('div', { class: 'tile-v' }, value, o.unit ? el('span', { class: 'tile-unit' }, ' ' + o.unit) : null),
    el('div', { class: 'tile-l' }, label),
    word ? pill(word, kind) : null,
    o.sub ? el('div', { class: 'tile-sub' }, o.sub) : null);
}

// panel: a section as a card - its title, the window or the moment it covers beside it in the muted small text ('last
// 1h', 'latest snapshot'), then its content
export function panel(title: string, note: string, ...kids: (Node | string | null | undefined)[]): HTMLElement {
  return el('section', { class: 'panel' }, el('h3', { class: 'panel-head' }, title, note ? el('span', { class: 'panel-note' }, note) : null), ...kids);
}

// toolbar: one quiet bar of controls, its groups apart by a hairline; a pressed button (aria-pressed) is the active one
export function toolbar(...groups: (Node | Node[])[]): HTMLElement {
  return el('div', { class: 'toolbar quiet-bar', role: 'toolbar' }, ...groups.map(g => el('span', { class: 'tb-group' }, ...(Array.isArray(g) ? g : [g]))));
}

// The states a part of a page is in besides showing its data, one shape everywhere: empty (the words say what was
// looked for and the window), loading (a status a screen reader announces), stale (the newest read is old: the part is
// greyed and says when it was collected).
// Empty and loading carry the class 'empty' too: the proofs' settle checks wait while a p.empty says 'Loading'. A loading
// note goes in empty and gets its words a frame later, so a screen reader announces it (main.ts does the same).
export function stateNote(kind: 'empty' | 'loading' | 'stale', words: string): HTMLElement {
  const p = el('p', { class: kind === 'stale' ? 'state stale' : kind === 'empty' ? 'state empty' : 'state loading empty', ...(kind === 'loading' ? { role: 'status' } : {}) },
    kind === 'loading' ? '' : words);
  if (kind === 'loading') requestAnimationFrame(() => { p.textContent = words; });
  return p;
}
// markStale: the part is greyed (every child but the note) and says when it was collected, under its heading if it has one
export function markStale(box: HTMLElement, at: unknown): HTMLElement {
  box.classList.add('is-stale');
  const note = stateNote('stale', `Last collected ${fmtTime(at)}`), head = box.querySelector(':scope > h3, :scope > h2');
  if (head) head.after(note); else box.prepend(note);
  return box;
}

// props renders label/value pairs as a two-column card.
export function props(pairs: [string, string | Node][]): HTMLElement {
  const t = el('table', { class: 'props' });
  for (const [k, v] of pairs) t.append(el('tr', {}, el('th', {}, k), el('td', {}, v)));
  return el('div', { class: 'grid-wrap', tabindex: '0' }, t);
}
