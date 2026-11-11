// The grid tools (task 153): what a DBA Dash grid offers beyond sort and filter, on every grid of the UI. From the
// grid's own menu (right-click, the menu key or Shift+F10): copy the rows shown as Markdown or as HTML with the
// colours, hide a column, freeze the columns up to one, group by a column with a count and an aggregate (sum,
// average, min, max) of every number column, data bars on a number column, and 'Columns...': the chooser with all
// of it in one panel, each of them reachable by keyboard there. Ctrl+click (Cmd on a Mac) picks cells, Shift+click a
// rectangle, the chooser a whole column: the line above the grid says their count, sum, average, min and max. Which
// columns are hidden, how many are frozen and which carry bars is kept per browser (localStorage; in memory where the
// browser keeps nothing), per grid: the tab, the heading above the grid and its column names. A grouping and an open
// chooser hold while the page is loaded: a live tab draws its grids again every 30 seconds.
//
// The tools read the page as the export does (export.ts: the same cells, numbers and colours) and change only how the
// grid is drawn: classes on the table, a panel and a line beside it. A hidden column is marked data-gt-hidden on its
// header, which the export honours. The one hook is the grid's menu: ui.ts sends a 'pgvigil:gridmenu' event with the
// menu's items before it shows them, and the tools add theirs.
import { Cell, Kind, Status, fillOf, fontOf, fromText, headFill, linkFill, linkFont, readGrid, statusOf, typed } from './export';
import { cellText, copyText, el, fmtBytes, fmtNum, fmtSecs, gridModel } from './ui';

type Item = [string, () => void];
interface MenuDetail { table?: HTMLTableElement; td?: Element | null; items?: Item[] }
interface Prefs { hidden: string[]; frozen: number; bars: string[] }
type Agg = 'sum' | 'avg' | 'min' | 'max';
interface Grouping { col: string; agg: Agg; box: HTMLElement }

// MAX_COLS: the columns the hide rules reach; FREEZE_POS: the column positions the freeze rules reach; MAX_FROZEN: the
// columns frozen at most
const MAX_COLS = 80, FREEZE_POS = 24, MAX_FROZEN = 12;
const groupings = new WeakMap<HTMLTableElement, Grouping>();   // a grouped grid's panel
const panels = new WeakMap<HTMLTableElement, HTMLElement>();   // a grid's open chooser
const anchors = new WeakMap<HTMLTableElement, HTMLTableCellElement>();   // the cell a Shift+click measures from
// by the grid's key, so they hold when the page draws the grid again: the choices of a browser that keeps nothing,
// the grouping, the open chooser
const mem = new Map<string, Prefs>();
const keptGroups = new Map<string, { col: string; agg: Agg }>();
const openPanels = new Set<string>();
let ask: (t: HTMLTableElement) => void = () => { /* set by installGridTools: draw a grid's kept choices at the next frame */ };
let sizes: ResizeObserver | undefined;   // a frozen grid whose size changes (a details opened, the filter row) is measured again

// ---- the grid's identity and what is kept for it ------------------------------------------------------------

const heads = (t: HTMLTableElement) => [...t.querySelectorAll<HTMLTableCellElement>(':scope > thead > tr:first-child > th')];
// bodyRows: the grid's data rows as drawn (a statement's open History panel is a row of its own and none of them)
const bodyRows = (t: HTMLTableElement) => [...t.querySelectorAll<HTMLTableRowElement>(':scope > tbody > tr')].filter(tr => !tr.classList.contains('trend-row'));
const label = (th: Element) => { const c = th.cloneNode(true) as Element; c.querySelectorAll('.whatis, .filter-btn').forEach(b => b.remove()); return cellText(c); };
// names: a column's name for the tools: its header's words, an empty one 'column n', a repeat numbered
function names(t: HTMLTableElement): string[] {
  const seen = new Map<string, number>();
  return heads(t).map((h, j) => {
    const base = label(h) || `column ${j + 1}`, n = (seen.get(base) ?? 0) + 1;
    seen.set(base, n);
    return n > 1 ? `${base} (${n})` : base;
  });
}
function headingOf(t: HTMLTableElement): string {
  let h = '';
  for (const e of document.querySelectorAll('h2, h3, h4, table.grid')) {
    if (e === t) break;
    if (e.tagName !== 'TABLE') h = label(e);
  }
  return h.replace(/\s*\(.*\)$/, '');   // 'Jobs (last 24 hours)': the range is not part of the grid's name
}
function hash(s: string): string {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}
const keyOf = (t: HTMLTableElement) => `pgvigil.grid.${(/^#\/([A-Za-z_]+)/.exec(location.hash)?.[1] ?? 'summary')}.${hash(headingOf(t) + '|' + names(t).join('|'))}`;

function load(t: HTMLTableElement): Prefs {
  const none: Prefs = { hidden: [], frozen: 0, bars: [] }, k = keyOf(t);
  let raw: string | null = null;
  try { raw = localStorage.getItem(k); } catch { /* the browser refuses storage: what this page load chose is in mem */ }
  if (raw === null) return mem.get(k) ?? none;
  try {
    const p = JSON.parse(raw) as Partial<Prefs> | null;
    if (!p || typeof p !== 'object') return none;
    const list = (v: unknown) => Array.isArray(v) ? v.filter(x => typeof x === 'string') as string[] : [];
    return { hidden: list(p.hidden), frozen: Math.max(0, Math.min(MAX_FROZEN, Math.floor(Number(p.frozen) || 0))), bars: list(p.bars) };
  } catch { return none; }   // a value another version wrote
}
function save(t: HTMLTableElement, p: Prefs) {
  const k = keyOf(t), empty = !p.hidden.length && !p.frozen && !p.bars.length;
  if (empty) mem.delete(k); else mem.set(k, p);
  try {
    if (empty) localStorage.removeItem(k); else localStorage.setItem(k, JSON.stringify(p));
  } catch { /* a private window: the choice holds while the page is loaded (mem) */ }
  apply(t, p);
}

// ---- drawing what is kept ------------------------------------------------------------------------------------

// apply: the hidden columns (a class per column and data-gt-hidden on the header, which the export reads), the frozen
// ones (sticky, each at the width of the ones before it) and the data bars. p: the choice just made; without it the
// kept one. The hidden columns are written first, then every width is read in one pass, then the frozen ones written.
function apply(t: HTMLTableElement, p: Prefs = load(t)) {
  const ns = names(t), hs = heads(t);
  if (!hs.length) return;
  const hidden = new Set(p.hidden.filter(n => ns.includes(n)));
  if (hidden.size >= ns.length) hidden.clear();   // a grid never loses every column
  for (const c of [...t.classList]) if (/^gt-[hf]\d+$/.test(c)) t.classList.remove(c);
  hs.forEach((h, j) => {
    const hide = hidden.has(ns[j]) && j < MAX_COLS;
    h.toggleAttribute('data-gt-hidden', hide);
    if (hide) t.classList.add(`gt-h${j + 1}`);
  });
  const freeze: number[] = [];
  hs.forEach((h, j) => { if (freeze.length < Math.min(p.frozen, MAX_FROZEN) && j < FREEZE_POS && !h.hasAttribute('data-gt-hidden')) freeze.push(j); });
  const widths = freeze.map(j => hs[j].getBoundingClientRect().width);
  let left = 0;
  freeze.forEach((j, k) => {
    t.classList.add(`gt-f${j + 1}`);
    t.style.setProperty(`--gt-l${j + 1}`, `${left}px`);
    left += widths[k];
  });
  t.toggleAttribute('data-gt-frozen', freeze.length > 0);
  // the frozen cells' z-index stays inside the grid's own scroll box: never over the page's sticky header and tabs
  const wrap = t.closest<HTMLElement>('.grid-wrap');
  if (wrap) wrap.style.isolation = freeze.length ? 'isolate' : '';
  if (freeze.length) sizes?.observe(t); else sizes?.unobserve(t);
  bars(t, p, ns);
}

// bars: a bar behind each number above zero of a column, its length the value's share of the column's largest (the
// rows drawn; a cell the page colours carries none). A screen aid: the export writes the number.
function bars(t: HTMLTableElement, p: Prefs, ns: string[]) {
  const on = new Set(p.bars.map(n => ns.indexOf(n)).filter(j => j >= 0));
  const had = t.hasAttribute('data-gt-bars');
  if (!on.size && !had) return;
  t.toggleAttribute('data-gt-bars', on.size > 0);
  const trs = bodyRows(t);
  const m = gridModel(t), data = m?.rows(), modelled = !!(data && m && m.cols.length === ns.length);
  ns.forEach((_, j) => {
    const vals = trs.map((tr, i) => on.has(j) ? numberAt(t, tr.children[j], modelled ? data![i]?.[m!.cols[j].key] : undefined)?.n : undefined);
    const max = Math.max(0, ...vals.map(v => v ?? 0));
    trs.forEach((tr, i) => {
      const td = tr.children[j] as HTMLElement | undefined, v = vals[i];
      if (!td) return;
      const share = v !== undefined && v > 0 && max > 0 && !statusOf(td) ? Math.max(1, Math.round(v / max * 100)) : 0;
      td.classList.toggle('gt-bar', share > 0);
      if (share > 0) td.style.setProperty('--gt-share', `${share}%`); else td.style.removeProperty('--gt-share');
    });
  });
}

// ---- a cell as a number --------------------------------------------------------------------------------------

interface Num { n: number; kind: Kind }
// numberAt: the number a cell holds, in its unit's base (bytes, seconds, milliseconds, a percent figure): the page
// model's raw value when the grid has one, else the text of a number column; undefined = not a number (words, a time)
function numberAt(t: HTMLTableElement, td: Element | undefined, raw: unknown): Num | undefined {
  if (!td) return undefined;
  const text = cellText(td);
  if (text === '') return undefined;
  const j = [...td.parentElement!.children].indexOf(td);
  return numOf(raw !== undefined ? typed(raw, text) : heads(t)[j]?.classList.contains('num') ? fromText(text) : undefined);
}
// numOf: an exported cell's number in its unit's base (a duration is stored in days, a share as a fraction)
function numOf(c: Pick<Cell, 'v' | 'kind'> | undefined): Num | undefined {
  if (!c || typeof c.v !== 'number' || c.kind === 'date') return undefined;
  return { n: c.kind === 'secs' ? c.v * 86400 : c.kind === 'pct' ? c.v * 100 : c.v, kind: c.kind === 'nsecs' ? 'secs' : c.kind === 'dec' ? 'int' : c.kind };
}
const round = (n: number) => Math.round(n * 100) / 100;
// show: a number back in its unit, as the screen writes one
function show(n: number, kind: Kind): string {
  if (kind === 'bytes') return fmtBytes(Math.round(n));
  if (kind === 'secs') return Math.abs(n) < 60 ? `${fmtNum(round(n))} s` : fmtSecs(n);
  if (kind === 'msecs') return `${fmtNum(round(n))} ms`;
  if (kind === 'pct') return `${fmtNum(round(n))} %`;
  return fmtNum(round(n));
}
function summary(ns: Num[]): string {
  if (!ns.length) return 'no number among them';
  const kinds = new Set(ns.map(x => x.kind));
  if (kinds.size > 1) return `${ns.length} numbers in different units: no sum`;
  const k = ns[0].kind, v = ns.map(x => x.n), sum = v.reduce((a, b) => a + b, 0);
  return `sum ${show(sum, k)} · avg ${show(sum / v.length, k)} · min ${show(Math.min(...v), k)} · max ${show(Math.max(...v), k)}` + ` (${ns.length} number${ns.length === 1 ? '' : 's'})`;
}

// ---- the selection and its line -----------------------------------------------------------------------------

const boxOf = (t: HTMLTableElement): Element => t.closest('.grid-box') ?? t.closest('.grid-wrap') ?? t;
const wrapOf = (t: HTMLTableElement): Element => { const w = t.closest('.grid-wrap'); return w && boxOf(t).contains(w) ? w : t; };
// lineOf: the tools' status line of a grid, if it has one yet; line: the same, made when it is first needed
function lineOf(t: HTMLTableElement): HTMLElement | null {
  const box = boxOf(t);
  if (box.classList.contains('grid-box')) return box.querySelector<HTMLElement>(':scope > .gt-stats');
  const prev = box.previousElementSibling;
  return prev?.classList.contains('gt-stats') ? prev as HTMLElement : null;
}
function line(t: HTMLTableElement): HTMLElement {
  let p = lineOf(t);
  if (!p) {
    const box = boxOf(t);
    p = el('p', { class: 'meta gt-stats', role: 'status' });
    if (box.classList.contains('grid-box')) box.insertBefore(p, wrapOf(t)); else box.before(p);
  }
  return p;
}
const picked = (t: HTMLTableElement) => [...t.querySelectorAll<HTMLTableCellElement>(':scope > tbody > tr > td.gt-sel')];
const colOf = (td: Element) => [...td.parentElement!.children].indexOf(td);
function stats(t: HTMLTableElement) {
  const sel = picked(t);
  if (!sel.length) { const had = lineOf(t); if (had) had.textContent = ''; return; }
  const p = line(t);
  const m = gridModel(t), data = m?.rows(), n = heads(t).length;
  const trs = bodyRows(t), modelled = !!(data && m && m.cols.length === n && data.length >= trs.length);
  const nums = sel.map(td => {
    const i = trs.indexOf(td.parentElement as HTMLTableRowElement), j = colOf(td);
    return numberAt(t, td, modelled && i >= 0 ? data![i]?.[m!.cols[j].key] : undefined);
  }).filter((x): x is Num => !!x);
  p.textContent = `${sel.length} cell${sel.length === 1 ? '' : 's'} selected: ${summary(nums)}`;
}
function clear(t: HTMLTableElement) {
  const sel = picked(t);
  if (!sel.length) return;
  sel.forEach(td => td.classList.remove('gt-sel'));
  anchors.delete(t);
  stats(t);
}
// pickColumn: every drawn cell of a column (the chooser's way to a selection without a mouse); -1 = none
function pickColumn(t: HTMLTableElement, j: number) {
  picked(t).forEach(td => td.classList.remove('gt-sel'));
  anchors.delete(t);
  if (j >= 0) for (const tr of bodyRows(t)) tr.children[j]?.classList.add('gt-sel');
  stats(t);
}
function onClick(e: MouseEvent) {
  const hit = (e.target as Element | null)?.closest?.('td');
  const tr = hit?.parentElement, body = tr?.parentElement, t = body?.parentElement;
  if (!hit || !tr || !body || !t || body.tagName !== 'TBODY' || t.tagName !== 'TABLE' || !t.classList.contains('grid') || tr.classList.contains('trend-row')) return;
  const td = hit as HTMLTableCellElement, table = t as HTMLTableElement;
  const mod = e.ctrlKey || e.metaKey;
  if (!mod && !e.shiftKey) { clear(table); return; }
  if ((e.target as Element).closest('a[href], button, input, select, textarea, summary')) return;   // a link's own Ctrl+click opens a tab
  e.preventDefault();
  const from = anchors.get(table);
  if (e.shiftKey && from?.isConnected) {
    const rows = bodyRows(table), hs = heads(table);
    const r0 = rows.indexOf(from.parentElement as HTMLTableRowElement), r1 = rows.indexOf(tr as HTMLTableRowElement), c0 = colOf(from), c1 = colOf(td);
    if (!mod) picked(table).forEach(x => x.classList.remove('gt-sel'));
    for (let r = Math.max(0, Math.min(r0, r1)); r <= Math.max(r0, r1); r++) {
      for (let c = Math.min(c0, c1); c <= Math.max(c0, c1); c++) {
        const x = rows[r]?.children[c] as HTMLElement | undefined;
        if (x && !hs[c]?.hasAttribute('data-gt-hidden')) x.classList.add('gt-sel');
      }
    }
    window.getSelection()?.removeAllRanges();   // the browser's own Shift+click selects the text between
  } else {
    td.classList.toggle('gt-sel');
    anchors.set(table, td);
  }
  stats(table);
}

// ---- the copies ----------------------------------------------------------------------------------------------

export interface Sheet { cols: string[]; rows: Cell[][]; num?: boolean[] }

// shown: the grid as the copies take it: every row the filter leaves (also past the grid's page), the columns not
// hidden; with a selection, the rows and columns that hold a selected cell, a cell outside it empty
function shown(t: HTMLTableElement): Sheet {
  const g = readGrid(t, true), hs = heads(t);
  const keep = hs.map(h => !h.hasAttribute('data-gt-hidden'));
  const sel = picked(t);
  if (!sel.length) return { cols: g.cols.filter((_, j) => keep[j]), rows: g.rows.map(r => r.filter((_, j) => keep[j] ?? true)), num: hs.map(h => h.classList.contains('num')).filter((_, j) => keep[j]) };
  // a drawn row's place among the data rows is its place in the grid's rows as read (both leave out a History panel)
  const trs = bodyRows(t);
  const at = sel.map(td => [trs.indexOf(td.parentElement as HTMLTableRowElement), colOf(td)] as [number, number]).filter(x => x[0] >= 0);
  const has = new Set(at.map(x => x.join(',')));
  const rs = [...new Set(at.map(x => x[0]))].sort((a, b) => a - b), cs = [...new Set(at.map(x => x[1]))].sort((a, b) => a - b);
  const blank: Cell = { v: '', kind: 'text', text: '' };
  return { cols: cs.map(c => g.cols[c] ?? ''), rows: rs.map(r => cs.map(c => has.has(`${r},${c}`) ? g.rows[r]?.[c] ?? blank : blank)), num: cs.map(c => !!hs[c]?.classList.contains('num')) };
}

// toMarkdown: a pipe table of the words on the screen; a number column right-aligned. The characters Markdown reads
// as markup (in a query's count(*), a name's underscores) are escaped, so the words paste as they are.
export function toMarkdown(s: Sheet): string {
  const cell = (v: string) => v.replace(/[\\|*_`<[\]]/g, '\\$&').replace(/[\r\n]+/g, ' ');
  const row = (vs: string[]) => `| ${vs.map(cell).join(' | ')} |`;
  return [row(s.cols.map(c => c || ' ')), `| ${s.cols.map((_, j) => s.num?.[j] ? '---:' : '---').join(' | ')} |`, ...s.rows.map(r => row(s.cols.map((_, j) => r[j]?.text ?? '')))].join('\n') + '\n';
}

const rgb = (argb: string) => '#' + argb.slice(2).toLowerCase();
const html = (v: string) => v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
// toHtml: a table that carries its colours in each cell's own style, so a mail, a document or a spreadsheet it is
// pasted into shows them: the export's header blue, each status fill with its text colour, a link cell's light fill and blue
export function toHtml(s: Sheet): string {
  const base = 'border:1px solid #c8ccd4;padding:3px 8px;font:11pt Calibri,Arial,sans-serif;white-space:nowrap';
  const th = (c: string) => `<th style="${base};background:${rgb(headFill)};color:#ffffff;font-weight:bold;text-align:left">${html(c)}</th>`;
  const td = (c: Cell | undefined, j: number) => {
    const st: Status | undefined = c?.status;
    const css = [base, st ? `background:${rgb(fillOf[st])};color:${rgb(fontOf[st])}` : c?.link ? `background:${rgb(linkFill)};color:${rgb(linkFont)}` : '',
      s.num?.[j] ? 'text-align:right' : ''].filter(Boolean).join(';');
    return `<td style="${css}"${st ? ` data-status="${st}"` : ''}>${html(c?.text ?? '')}</td>`;
  };
  return '<table style="border-collapse:collapse">'
    + `<thead><tr>${s.cols.map(th).join('')}</tr></thead>`
    + `<tbody>${s.rows.map(r => `<tr>${s.cols.map((_, j) => td(r[j], j)).join('')}</tr>`).join('')}</tbody></table>`;
}

// copyByEvent: the older way onto the clipboard, for a browser without ClipboardItem or a page not on a secure
// origin: a copy command whose event is given the HTML and the plain words. false = the browser did not take it.
function copyByEvent(h: string, plain: string): boolean {
  let done = false;
  const on = (e: ClipboardEvent) => {
    if (!e.clipboardData) return;
    e.clipboardData.setData('text/html', h);
    e.clipboardData.setData('text/plain', plain);
    e.preventDefault();
    done = true;
  };
  document.addEventListener('copy', on, true);
  try { document.execCommand('copy'); } catch { /* refused: done stays false */ } finally { document.removeEventListener('copy', on, true); }
  return done;
}
// copyHtml: the table on the clipboard as HTML, with the tab-separated words beside it for a plain-text paste; never
// the markup itself as text
async function copyHtml(s: Sheet): Promise<boolean> {
  const h = toHtml(s);
  const plain = [s.cols, ...s.rows.map(r => s.cols.map((_, j) => r[j]?.text ?? ''))].map(r => r.map(v => v.replace(/[\t\r\n]+/g, ' ')).join('\t')).join('\n');
  try {
    await navigator.clipboard.write([new ClipboardItem({ 'text/html': new Blob([h], { type: 'text/html' }), 'text/plain': new Blob([plain], { type: 'text/plain' }) })]);
    return true;
  } catch { return copyByEvent(h, plain); }
}
function said(t: HTMLTableElement, what: string) {
  return (ok: boolean) => {
    const p = line(t);
    p.textContent = ok ? 'Copied ' + what : 'Not copied: the browser refused the clipboard';
    window.setTimeout(() => { if (p.textContent?.startsWith('Copied') || p.textContent?.startsWith('Not copied')) stats(t); }, 2500);
  };
}

// ---- group by ------------------------------------------------------------------------------------------------

// group: a panel above the grid: one line per value of a column (the rows the filter leaves), its row count and one
// aggregate of every number column, the largest group first. It follows the grid's filters; the grid itself stays.
// col null = no grouping. The grouping is kept by the grid's key while the page is loaded.
function group(t: HTMLTableElement, col: string | null, agg: Agg = groupings.get(t)?.agg ?? 'sum') {
  groupings.get(t)?.box.remove();
  groupings.delete(t);
  const k = keyOf(t);
  if (col === null) { keptGroups.delete(k); return; }
  const ns = names(t), at = ns.indexOf(col);
  if (at < 0) return;
  keptGroups.set(k, { col, agg });
  const g = readGrid(t, true), hs = heads(t);
  const numCols = ns.map((_, j) => j).filter(j => j !== at && !hs[j].hasAttribute('data-gt-hidden') && g.rows.some(r => !!numOf(r[j])));
  const groups = new Map<string, { rows: number; nums: Num[][] }>();
  for (const r of g.rows) {
    const key = r[at]?.text ?? '';
    let x = groups.get(key);
    if (!x) { x = { rows: 0, nums: numCols.map(() => []) }; groups.set(key, x); }
    x.rows++;
    numCols.forEach((j, n) => { const v = numOf(r[j]); if (v) x!.nums[n].push(v); });
  }
  const one = (v: Num[]): string => {
    if (!v.length) return '';
    if (new Set(v.map(x => x.kind)).size > 1) return 'mixed units';
    const xs = v.map(x => x.n), sum = xs.reduce((a, b) => a + b, 0);
    return show(agg === 'sum' ? sum : agg === 'avg' ? sum / xs.length : agg === 'min' ? Math.min(...xs) : Math.max(...xs), v[0].kind);
  };
  const pick = el('select', { 'aria-label': 'The aggregate of each number column' }) as HTMLSelectElement;
  for (const [v, l] of [['sum', 'sum'], ['avg', 'average'], ['min', 'min'], ['max', 'max']]) pick.append(el('option', v === agg ? { value: v, selected: '' } : { value: v }, l));
  pick.addEventListener('change', () => { group(t, col, pick.value as Agg); (groupings.get(t)?.box.querySelector('select') as HTMLElement | null)?.focus(); });
  const off = el('button', { type: 'button', class: 'link' }, 'Ungroup');
  off.addEventListener('click', () => { group(t, null); (wrapOf(t) as HTMLElement).focus?.(); });
  const table = el('table', { class: 'gt-table' },
    el('thead', {}, el('tr', {}, el('th', { scope: 'col' }, ns[at]), el('th', { scope: 'col', class: 'num' }, 'rows'), ...numCols.map(j => el('th', { scope: 'col', class: 'num' }, `${ns[j]} (${agg})`)))),
    el('tbody', {}, ...[...groups.entries()].sort((a, b) => b[1].rows - a[1].rows || a[0].localeCompare(b[0])).map(([key, x]) =>
      el('tr', {}, el('th', { scope: 'row' }, key || '(empty)'), el('td', { class: 'num' }, fmtNum(x.rows)), ...x.nums.map(v => el('td', { class: 'num' }, one(v)))))));
  const box = el('div', { class: 'gt-groups', role: 'group', 'aria-label': `Grouped by ${ns[at]}` },
    el('p', { class: 'meta' }, `Grouped by ${ns[at]}: ${fmtNum(groups.size)} group${groups.size === 1 ? '' : 's'} of ${fmtNum(g.rows.length)} rows; each number column's `, pick, ' ', off),
    el('div', { class: 'gt-scroll', tabindex: '0', role: 'region', 'aria-label': `The groups by ${ns[at]}` }, table));
  const host = boxOf(t);
  if (host.classList.contains('grid-box')) host.insertBefore(box, wrapOf(t)); else host.before(box);
  groupings.set(t, { col, agg, box });
}

// ---- the chooser ---------------------------------------------------------------------------------------------

// chooser: the panel with every tool of a grid: each column's tick, its data bars, the frozen columns, the group-by,
// a column's cells for the selection line. back: where the focus returns on Close; focus false = drawn again after
// the page redrew the grid, without taking the focus from where it is.
function chooser(t: HTMLTableElement, back: HTMLElement | null, focus = true) {
  panels.get(t)?.remove();
  const ns = names(t), hs = heads(t), p = load(t), k = keyOf(t);
  const hidden = new Set(p.hidden.filter(n => ns.includes(n))), barsOn = new Set(p.bars.filter(n => ns.includes(n)));
  const box = el('div', { class: 'gt-panel', role: 'dialog', 'aria-label': 'Columns of this grid' });
  const close = () => {
    box.remove(); panels.delete(t); openPanels.delete(k);
    const to = back && back.isConnected && back.tabIndex >= 0 ? back : wrapOf(t) as HTMLElement;   // a cell cannot take the focus: the grid's scroll box does
    to.focus?.();
  };
  const now = (): Prefs => ({ hidden: [...hidden], frozen: Number(freeze.value) || 0, bars: [...barsOn] });
  const list = el('div', { class: 'gt-cols' });
  ns.forEach((n, j) => {
    const tick = el('input', { type: 'checkbox' }) as HTMLInputElement;
    tick.checked = !hidden.has(n);
    tick.addEventListener('change', () => {
      if (tick.checked) hidden.delete(n); else hidden.add(n);
      if (hidden.size >= ns.length) { hidden.delete(n); tick.checked = true; }   // the last column stays
      save(t, now());
    });
    const row = el('div', { class: 'gt-col' }, el('label', {}, tick, ' ', n));
    if (hs[j].classList.contains('num')) {
      const bar = el('input', { type: 'checkbox', 'aria-label': `Data bars on ${n}` }) as HTMLInputElement;
      bar.checked = barsOn.has(n);
      bar.addEventListener('change', () => { if (bar.checked) barsOn.add(n); else barsOn.delete(n); save(t, now()); });
      row.append(' ', el('label', { class: 'meta' }, bar, ' data bars'));
    }
    list.append(row);
  });
  const freeze = el('input', { type: 'number', min: '0', max: String(Math.min(MAX_FROZEN, ns.length - 1)), value: String(Math.min(p.frozen, Math.max(0, ns.length - 1))), 'aria-label': 'Columns frozen at the left' }) as HTMLInputElement;
  freeze.addEventListener('change', () => { freeze.value = String(Math.max(0, Math.min(Number(freeze.max), Math.floor(Number(freeze.value) || 0)))); save(t, now()); });
  const by = el('select', { 'aria-label': 'Group by a column' }, el('option', { value: '' }, 'no grouping')) as HTMLSelectElement;
  ns.forEach(n => by.append(el('option', groupings.get(t)?.col === n ? { value: n, selected: '' } : { value: n }, n)));
  by.addEventListener('change', () => group(t, by.value || null));
  // the selection without a mouse: a column's cells, their count and sum in the line above the grid
  const sum = el('select', { 'aria-label': 'Select the cells of a column: their count, sum, average, min and max show above the grid' }, el('option', { value: '' }, 'no column')) as HTMLSelectElement;
  ns.forEach((n, j) => { if (!hidden.has(n)) sum.append(el('option', { value: String(j) }, n)); });
  sum.addEventListener('change', () => pickColumn(t, sum.value === '' ? -1 : Number(sum.value)));
  const all = el('button', { type: 'button' }, 'Show every column');
  all.addEventListener('click', () => { hidden.clear(); list.querySelectorAll<HTMLInputElement>('.gt-col > label:first-child input').forEach(i => { i.checked = true; }); save(t, now()); });
  const reset = el('button', { type: 'button' }, 'Reset this grid');
  reset.addEventListener('click', () => { hidden.clear(); barsOn.clear(); freeze.value = '0'; save(t, now()); group(t, null); pickColumn(t, -1); chooser(t, back); });
  const done = el('button', { type: 'button' }, 'Close');
  done.addEventListener('click', close);
  box.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); } });
  box.append(el('p', { class: 'meta' }, 'Columns of this grid: shown when ticked. The choice is kept in this browser.'), list,
    el('p', {}, el('label', {}, 'Freeze the first ', freeze, ' column(s)'), ' ', el('label', {}, 'Group by ', by), ' ', el('label', {}, 'Sum the cells of ', sum)),
    el('p', {}, all, ' ', reset, ' ', done));
  const host = boxOf(t);
  if (host.classList.contains('grid-box')) host.insertBefore(box, host.firstChild); else host.before(box);
  panels.set(t, box);
  openPanels.add(k);
  if (focus) (box.querySelector('input') as HTMLElement | null)?.focus();
}

// ---- the menu ------------------------------------------------------------------------------------------------

// menuItems: the tools' lines of a grid's menu; td: the cell under the pointer (its column is the one hidden, frozen
// to, grouped by or given bars; none when the menu was opened from the keyboard: the chooser has them all)
export function menuItems(t: HTMLTableElement, td: Element | null, back: HTMLElement | null = null): Item[] {
  const ns = names(t), hs = heads(t), p = load(t);
  const j = td && td.parentElement ? colOf(td) : -1;
  const n = j >= 0 ? ns[j] : undefined;
  const sel = picked(t).length, what = sel ? 'the selection' : 'the rows';
  const visible = hs.filter(h => !h.hasAttribute('data-gt-hidden')).length;
  const frozen = [...t.classList].filter(c => /^gt-f\d+$/.test(c)).length;
  const barred = new Set(p.bars);
  const items: Item[] = [
    [`Copy ${what} as Markdown`, () => { const s = shown(t); void copyText(toMarkdown(s)).then(said(t, `${s.rows.length} rows as Markdown`)); }],
    [`Copy ${what} as HTML with the colours`, () => { const s = shown(t); void copyHtml(s).then(said(t, `${s.rows.length} rows as HTML`)); }],
  ];
  if (n !== undefined) {
    if (visible > 1) items.push([`Hide column ${n}`, () => save(t, { ...p, hidden: [...new Set([...p.hidden, n])] })]);
    const upTo = hs.slice(0, j + 1).filter(h => !h.hasAttribute('data-gt-hidden')).length;
    if (j < FREEZE_POS && upTo <= MAX_FROZEN && upTo < visible && frozen !== upTo) items.push([`Freeze the columns up to ${n}`, () => save(t, { ...p, frozen: upTo })]);
    if (groupings.get(t)?.col !== n) items.push([`Group by ${n}`, () => group(t, n)]);
    if (hs[j].classList.contains('num')) {
      const on = barred.has(n);
      items.push([on ? `No data bars on ${n}` : `Data bars on ${n}`, () => save(t, { ...p, bars: on ? p.bars.filter(x => x !== n) : [...p.bars, n] })]);
    }
  }
  if (frozen) items.push(['Unfreeze the columns', () => save(t, { ...p, frozen: 0 })]);
  if (groupings.has(t)) items.push(['Ungroup', () => group(t, null)]);
  if (sel) items.push(['Clear the selection', () => clear(t)]);
  items.push(['Columns...', () => chooser(t, back)]);
  return items;
}

// ---- starting ------------------------------------------------------------------------------------------------

const css = () => {
  const row = 'tr:not(.trend-row)';   // a statement's open History panel spans the grid: no column rule reaches into it
  const hide = Array.from({ length: MAX_COLS }, (_, j) => `table.grid.gt-h${j + 1} > * > ${row} > :nth-child(${j + 1})`).join(',') + '{display:none}';
  const freeze = Array.from({ length: FREEZE_POS }, (_, j) => {
    const n = j + 1, at = `table.grid.gt-f${n}`;
    return `${at} > * > ${row} > :nth-child(${n}){position:sticky;left:var(--gt-l${n},0);z-index:1}`
      // a frozen cell covers what scrolls under it: the page's background, unless the cell has a fill of its own (a
      // status cell: solid in the default style; in the quiet style an OK or unsampled one has none)
      + `${at} > tbody > ${row} > :nth-child(${n}):not(.status),${at} > thead > tr.filters > :nth-child(${n}){background-color:var(--bg)}`
      + `:root[data-status="quiet"] ${at} > tbody > ${row} > :nth-child(${n}):is(.status.ok,.status.none){background-color:var(--bg)}`
      + `${at} > thead > tr > :nth-child(${n}){z-index:3}`;
  }).join('');
  return hide + freeze
    + 'table.grid[data-gt-frozen] > thead > tr > th{z-index:2}'
    + '.grid td.gt-sel{outline:2px solid var(--accent);outline-offset:-2px}'
    + '.grid td.gt-bar{background-image:linear-gradient(to right,rgba(43,100,207,.28) var(--gt-share,0%),transparent var(--gt-share,0%));'
    + 'background-image:linear-gradient(to right,color-mix(in srgb,var(--accent) 28%,transparent) var(--gt-share,0%),transparent var(--gt-share,0%))}'
    + '.gt-stats:empty{display:none}.gt-stats{margin:.2rem 0}'
    + '.gt-panel,.gt-groups{border:1px solid var(--line);background:var(--card);color:var(--fg);padding:.5rem .8rem;margin:.3rem 0}'
    + '.gt-panel p,.gt-groups p{margin:.3rem 0}.gt-cols{display:grid;grid-template-columns:repeat(auto-fill,minmax(16rem,1fr));gap:.1rem 1rem;max-height:16rem;overflow:auto}'
    + '.gt-panel input[type=number]{width:4rem}.gt-scroll{overflow:auto;max-height:18rem}'
    + '.gt-table{border-collapse:collapse;font-variant-numeric:tabular-nums}.gt-table th,.gt-table td{padding:.2rem .6rem;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap;font-weight:400}'
    + '.gt-table thead th{color:var(--muted)}.gt-table .num{text-align:right}';
};

let installed = false;
// installGridTools: once per page load. The kept choices are drawn on every grid as it appears and after each of its
// redraws (a sort, a filter, 'show more', a live tab's refresh); the menu's lines come on the grid's
// 'pgvigil:gridmenu' event.
export function installGridTools() {
  if (installed || typeof document === 'undefined') return;
  installed = true;
  document.head.append(el('style', { id: 'gt-style' }, css()));
  const due = new Set<HTMLTableElement>();
  let asked = false;
  const run = () => {
    asked = false;
    const ts = [...due];
    due.clear();
    for (const t of ts) {
      if (!t.isConnected) continue;
      apply(t);
      const k = keyOf(t), g = groupings.get(t) ?? keptGroups.get(k);
      if (g) group(t, g.col, g.agg);
      // a chooser open when the page drew the grid again comes back; it takes the focus only if the redraw lost it
      if (openPanels.has(k) && !panels.get(t)?.isConnected) chooser(t, null, document.activeElement === document.body || document.activeElement === null);
      if (lineOf(t)?.textContent?.includes('selected')) stats(t);
    }
  };
  ask = (t: HTMLTableElement) => { due.add(t); if (!asked) { asked = true; requestAnimationFrame(run); } };
  if (typeof ResizeObserver !== 'undefined') sizes = new ResizeObserver(es => { for (const e of es) if (e.target instanceof HTMLTableElement) ask(e.target); });
  const isGrid = (e: Element | null): e is HTMLTableElement => !!e && e.tagName === 'TABLE' && e.classList.contains('grid');
  new MutationObserver(ms => {
    for (const m of ms) {
      const at = m.target as Element;
      if (at.closest?.('.gt-groups, .gt-panel, .gt-stats')) continue;   // the tools' own panels
      if (at.tagName === 'TBODY' && isGrid(at.parentElement)) { ask(at.parentElement); continue; }
      for (const n of m.addedNodes) {
        if (!(n instanceof Element) || n.classList.contains('gt-groups') || n.classList.contains('gt-panel') || n.classList.contains('gt-stats')) continue;
        if (isGrid(n)) ask(n);
        else if (n.tagName !== 'TR' && n.tagName !== 'TD') n.querySelectorAll<HTMLTableElement>('table.grid').forEach(ask);
      }
    }
  }).observe(document.body, { childList: true, subtree: true });
  document.querySelectorAll<HTMLTableElement>('table.grid').forEach(ask);
  document.addEventListener('pgvigil:gridmenu', e => {
    const d = (e as CustomEvent<MenuDetail>).detail;
    if (d?.table && Array.isArray(d.items)) d.items.push(...menuItems(d.table, d.td ?? null, (d.td as HTMLElement | null) ?? null));
  });
  document.addEventListener('click', onClick);
  document.addEventListener('mousedown', e => {   // a Shift+click on a cell extends the tools' selection, not the browser's text selection
    if (e.shiftKey && (e.target as Element | null)?.closest?.('table.grid > tbody > tr > td') && !(e.target as Element).closest('a[href], button, input, select, textarea')) e.preventDefault();
  });
  window.addEventListener('resize', () => document.querySelectorAll<HTMLTableElement>('table.grid[data-gt-frozen]').forEach(ask));
}
