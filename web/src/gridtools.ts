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
import { Cell, Kind, Meta, Section, Status, csv, exportGrid, fillOf, fontOf, fromText, headFill, linkFill, linkFont, readGrid, saveGridAs, statusOf, timeZone, typed } from './export';
import { GridMenuAsk, cellText, copyText, el, fmtBytes, fmtNum, fmtSecs, gridModel, isCondList, offControl, quoteFilter } from './ui';
import { MenuItem, gridLines, showTreeMenu } from './treemenu';
import { Grid, htmlDoc, json, markdown, sqlScript, tsv } from './gridwriters';

// bars: a column's data bar by its name - behind the value (the default, the only style before task GM: a stored list of
// names loads as it), under the value, or a traffic light with the high values the worse or the better; rownum: the row
// numbers drawn (a counter, no column)
type BarStyle = 'behind' | 'under' | 'worse' | 'better';
interface Prefs { hidden: string[]; frozen: number; bars: Record<string, BarStyle>; rownum?: boolean }
const BAR_STYLES: [BarStyle, string][] = [['behind', 'Behind value'], ['under', 'Under value'], ['worse', 'Traffic light (higher is worse)'], ['better', 'Traffic light (higher is better)']];
type Agg = 'sum' | 'avg' | 'min' | 'max';
interface Grouping { col: string; agg: Agg; box: HTMLElement }

// MAX_COLS: the columns the hide rules reach; FREEZE_POS: the column positions the freeze rules reach; MAX_FROZEN: the
// columns frozen at most
const MAX_COLS = 80, FREEZE_POS = 24, MAX_FROZEN = 12;
const groupings = new WeakMap<HTMLTableElement, Grouping>();   // a grouped grid's panel
const panels = new WeakMap<HTMLTableElement, HTMLElement>();   // a grid's open chooser
const panelBacks = new WeakMap<HTMLTableElement, HTMLElement | null>();   // where an open chooser's Close sends the focus
const panelStates = new WeakMap<HTMLTableElement, () => void>();   // an open chooser's read of its off buttons
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
  const none: Prefs = { hidden: [], frozen: 0, bars: {} }, k = keyOf(t);
  let raw: string | null = null;
  try { raw = localStorage.getItem(k); } catch { /* the browser refuses storage: what this page load chose is in mem */ }
  if (raw === null) return mem.get(k) ?? none;
  try {
    const p = JSON.parse(raw) as Partial<Prefs> | null;
    if (!p || typeof p !== 'object') return none;
    const list = (v: unknown) => Array.isArray(v) ? v.filter(x => typeof x === 'string') as string[] : [];
    const styles = new Set(BAR_STYLES.map(x => x[0]));
    const bars: Record<string, BarStyle> = Array.isArray(p.bars) ? Object.fromEntries(list(p.bars).map(n => [n, 'behind' as BarStyle]))
      : p.bars && typeof p.bars === 'object' ? Object.fromEntries(Object.entries(p.bars).filter(([, v]) => styles.has(v as BarStyle))) as Record<string, BarStyle> : {};
    return { hidden: list(p.hidden), frozen: Math.max(0, Math.min(MAX_FROZEN, Math.floor(Number(p.frozen) || 0))), bars, rownum: p.rownum === true };
  } catch { return none; }   // a value another version wrote
}
function save(t: HTMLTableElement, p: Prefs) {
  const k = keyOf(t), empty = !p.hidden.length && !p.frozen && !Object.keys(p.bars).length && !p.rownum;
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
  t.classList.toggle('gt-rownum', !!p.rownum);
  bars(t, p, ns);
}

// bars: a column's data bar (the rows drawn; a cell the page colours carries none): behind each number above zero or
// under it, its length the value's share of the column's largest; or a traffic light, the column's range in thirds,
// the top third red and the bottom green (higher is worse) or the reverse (higher is better). A screen aid in the
// tools' own classes (never ok / warn / crit, which the export reads as a status): no file carries it.
function bars(t: HTMLTableElement, p: Prefs, ns: string[]) {
  const on = new Map(Object.entries(p.bars).map(([n, st]) => [ns.indexOf(n), st] as [number, BarStyle]).filter(([j]) => j >= 0));
  const had = t.hasAttribute('data-gt-bars');
  if (!on.size && !had) return;
  t.toggleAttribute('data-gt-bars', on.size > 0);
  const trs = bodyRows(t);
  const m = gridModel(t), data = m?.rows(), modelled = !!(data && m && m.cols.length === ns.length);
  ns.forEach((_, j) => {
    const st = on.get(j);
    const vals = trs.map((tr, i) => st ? numberAt(t, tr.children[j], modelled ? data![i]?.[m!.cols[j].key] : undefined)?.n : undefined);
    const nums = vals.filter((v): v is number => v !== undefined);
    const max = Math.max(0, ...nums), lo = nums.length ? Math.min(...nums) : 0, hi = nums.length ? Math.max(...nums) : 0;
    trs.forEach((tr, i) => {
      const td = tr.children[j] as HTMLElement | undefined, v = vals[i];
      if (!td) return;
      const own = !!statusOf(td);
      const share = (st === 'behind' || st === 'under') && v !== undefined && v > 0 && max > 0 && !own ? Math.max(1, Math.round(v / max * 100)) : 0;
      td.classList.toggle('gt-bar', share > 0);
      td.classList.toggle('gt-bar-under', share > 0 && st === 'under');
      if (share > 0) td.style.setProperty('--gt-share', `${share}%`); else td.style.removeProperty('--gt-share');
      let light = '';
      if ((st === 'worse' || st === 'better') && v !== undefined && !own) {
        const third = hi > lo ? (v - lo) / (hi - lo) : 0.5, top = third >= 2 / 3, bottom = third <= 1 / 3;
        light = top ? (st === 'worse' ? 'r' : 'g') : bottom ? (st === 'worse' ? 'g' : 'r') : 'a';
      }
      for (const x of ['r', 'a', 'g']) td.classList.toggle('gt-tl-' + x, light === x);
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

// homeOf: the grid's current cell, its one tab stop (ui.ts grid); a table outside grid() itself
const homeOf = (t: HTMLTableElement): HTMLElement | null => t.querySelector<HTMLElement>(':scope > thead > tr > th[tabindex="0"], :scope > tbody > tr > td[tabindex="0"]') ?? (t.tabIndex >= 0 ? t : t.closest<HTMLElement>('.grid-wrap[tabindex]'));   // a page's own table: its focusable wrap
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
  if (panels.get(t)?.isConnected) panelStates.get(t)?.();   // the selection changed: an open chooser's Reset reads it
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

export interface Sheet { cols: string[]; rows: Cell[][]; num?: boolean[]; borders?: boolean }   // borders: each cell's thin border (a mail's grid, as its header table)

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
// pasted into shows them: the export's header blue, each status fill with its text colour, a link cell's light fill and blue;
// no cell border in a copy (DBA Dash's copy draws none); a mail's grid keeps its thin borders, as the mail's header table
// (s.borders: reportmail.ts mailHtml)
export function toHtml(s: Sheet): string {
  const base = `${s.borders ? 'border:1px solid #c8ccd4;' : ''}padding:3px 8px;font:11pt Calibri,Arial,sans-serif;white-space:nowrap`;
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
  off.addEventListener('click', () => { group(t, null); redrawPanel(t); homeOf(t)?.focus(); });
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

// redrawPanel: a choice made outside an open chooser (the grid's menu, the group box's Ungroup) draws it again from
// what is kept, so its ticks and its off buttons say what is now true; the focus stays where it is
function redrawPanel(t: HTMLTableElement) {
  if (panels.get(t)?.isConnected) chooser(t, panelBacks.get(t) ?? null, false);
}

// chooser: the panel with every tool of a grid: each column's tick, its data bars, the frozen columns, the group-by,
// a column's cells for the selection line. back: where the focus returns on Close; focus false = drawn again after
// the page redrew the grid, without taking the focus from where it is.
function chooser(t: HTMLTableElement, back: HTMLElement | null, focus = true) {
  panels.get(t)?.remove();
  const ns = names(t), hs = heads(t), p = load(t), k = keyOf(t);
  const hidden = new Set(p.hidden.filter(n => ns.includes(n))), barsOn = new Set(Object.keys(p.bars).filter(n => ns.includes(n)));
  const box = el('div', { class: 'gt-panel', role: 'dialog', 'aria-label': 'Columns of this grid' });
  const close = () => {
    box.remove(); panels.delete(t); openPanels.delete(k);
    const to = back && back.isConnected && back.tabIndex >= 0 ? back : homeOf(t);   // else the grid's current cell (its one tab stop)
    to?.focus();
  };
  // a bar ticked here keeps its style (behind the value when new); the row numbers stay as they are
  const now = (): Prefs => ({ hidden: [...hidden], frozen: Number(freeze.value) || 0, bars: Object.fromEntries([...barsOn].map(n => [n, p.bars[n] ?? 'behind' as BarStyle])), rownum: p.rownum });
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
  reset.addEventListener('click', () => { hidden.clear(); barsOn.clear(); freeze.value = '0'; save(t, { ...now(), rownum: false }); group(t, null); pickColumn(t, -1); chooser(t, back); });
  const done = el('button', { type: 'button' }, 'Close');
  done.addEventListener('click', close);
  box.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); } });
  // Show every column with none hidden, Reset this grid with nothing changed from its default: a click would change
  // nothing - each off with its reason, read again on every change in the panel (the walk's NOTHING rows)
  const offNote = el('span', { class: 'off-reason' });
  const offState = () => {
    const noneHidden = hidden.size === 0;
    const plain = noneHidden && barsOn.size === 0 && (Number(freeze.value) || 0) === 0 && !groupings.get(t) && picked(t).length === 0 && !p.rownum;
    const why = [noneHidden ? 'every column is shown' : '', plain ? 'nothing in this grid is changed from its default' : ''].filter(Boolean);
    offNote.textContent = why.join('; ');
    offControl(all, noneHidden ? 'every column is shown' : null, offNote);
    offControl(reset, plain ? 'nothing in this grid is changed from its default' : null, offNote);
  };
  box.addEventListener('change', offState);
  all.addEventListener('click', offState);
  offState();
  box.append(el('p', { class: 'meta' }, 'Columns of this grid: shown when ticked. The choice is kept in this browser.'), list,
    el('p', {}, el('label', {}, 'Freeze the first ', freeze, ' column(s)'), ' ', el('label', {}, 'Group by ', by), ' ', el('label', {}, 'Sum the cells of ', sum)),
    el('p', {}, all, ' ', reset, ' ', done, ' ', offNote));
  const host = boxOf(t);
  if (host.classList.contains('grid-box')) host.insertBefore(box, host.firstChild); else host.before(box);
  panels.set(t, box);
  panelBacks.set(t, back);
  panelStates.set(t, offState);
  openPanels.add(k);
  if (focus) (box.querySelector('input') as HTMLElement | null)?.focus();
}

// ---- the menu (task GM: DBA Dash's grid menu) ------------------------------------------------------------------

// the copies' and the files' grid: every row the filters leave in the shown order, the columns not hidden; sel = the
// selection's rows and columns when there is one (the copies' 'Selected' and their Markdown / JSON)
function gridOf(t: HTMLTableElement, sel: boolean): Grid {
  const s = sel ? shown(t) : (() => { const g = readGrid(t); return { cols: g.cols, rows: g.rows, num: heads(t).filter(h => !h.hasAttribute('data-gt-hidden')).map(h => h.classList.contains('num')) }; })();
  return { ...s, sample: t.closest('[data-sample]')?.getAttribute('data-sample') ?? undefined };
}
// copyBoth: HTML with the colours and its plain words on the clipboard (copyByEvent where ClipboardItem is refused)
async function copyBoth(h: string, plain: string): Promise<boolean> {
  try {
    await navigator.clipboard.write([new ClipboardItem({ 'text/html': new Blob([h], { type: 'text/html' }), 'text/plain': new Blob([plain], { type: 'text/plain' }) })]);
    return true;
  } catch { return copyByEvent(h, plain); }
}
const filterable = (t: HTMLTableElement) => !!t.querySelector(':scope > thead > tr.filters');
const filterInputs = (t: HTMLTableElement) => [...t.querySelectorAll<HTMLInputElement>(':scope > thead > tr.filters input')];
const filtered = (t: HTMLTableElement) => filterInputs(t).some(i => i.value.trim() !== '');
function setFilter(t: HTMLTableElement, j: number, v: string) {
  const row = t.querySelector<HTMLTableRowElement>(':scope > thead > tr.filters'), inp = filterInputs(t)[j];
  if (!row || !inp) return;
  if (row.hidden) heads(t)[j]?.querySelector<HTMLButtonElement>('.filter-btn')?.click();
  inp.value = v;
  inp.dispatchEvent(new Event('input'));
}
// addCond: a condition the menu writes (quoted, ui.ts compileFilter) AND the column's filter; a typed one there is kept
// with its meaning (words quoted as words, '!x' as not those words, an operator with its number as it is)
function addCond(t: HTMLTableElement, j: number, cond: string) {
  const f = filterInputs(t)[j]?.value.trim() ?? '', num = !!heads(t)[j]?.classList.contains('num');
  const keep = !f || (f.includes('"') ? isCondList(f, num) : /^(<>|>=|<=|>|<|=)\s*\S/.test(f));
  const was = keep ? f : f.startsWith('!') ? '!' + quoteFilter(f.slice(1)) : quoteFilter(f);
  setFilter(t, j, was ? `${was} & ${cond}` : cond);
}
// a dialog of the tools in the grid's own host (a grid in a modal dialog: that dialog), the focus back on close
function toolDialog(t: HTMLTableElement, label: string, back: HTMLElement | null, ...kids: (Node | string)[]): HTMLDialogElement {
  const d = el('dialog', { class: 'gt-dialog', 'aria-label': label }, el('h3', {}, label), ...kids) as HTMLDialogElement;
  d.addEventListener('close', () => { d.remove(); if (back?.isConnected) back.focus(); });
  (t.closest('dialog[open]') ?? document.body).append(d);
  d.showModal();
  return d;
}
// filterPrompt: All filters' operator with the clicked value to change (Like's _ and % escaped: the value as it is)
function filterPrompt(t: HTMLTableElement, j: number, op: string, value: string, back: HTMLElement | null) {
  const n = names(t)[j];
  const like = /like$/i.test(op);
  const inp = el('input', { type: 'text', 'aria-label': `${n} ${op}`, size: '40' }) as HTMLInputElement;
  inp.value = like ? value.replace(/[\\%_]/g, '\\$&') : value;
  const cancel = el('button', { type: 'button' }, 'Cancel');
  const form = el('form', { method: 'dialog' }, el('p', {}, el('label', {}, `${n} ${op} `, inp)),
    el('p', { class: 'meta' }, like ? '% any run of characters, _ one character, \\% \\_ \\\\ themselves' : 'The rows whose value meets it stay; the column\'s filter keeps what it held.'),
    el('p', {}, el('button', { type: 'submit' }, 'Filter'), ' ', cancel));
  const d = toolDialog(t, `Filter ${n}`, back, form);
  form.addEventListener('submit', e => { e.preventDefault(); const v = inp.value; d.close(); if (v !== '') addCond(t, j, like ? `${op.toLowerCase()} ${quoteFilter(v)}` : op + quoteFilter(v)); });
  cancel.addEventListener('click', () => d.close());
  inp.focus(); inp.select();
}
// transpose: rows as columns (a column's name, then its value in each row), in a dialog with Copy; the grid form shows
// 50 rows and says so, its Copy takes every row
const CAP = 50;
function transpose(t: HTMLTableElement, rows: number[] | 'all', back: HTMLElement | null) {
  const g = gridOf(t, false), all = rows === 'all' ? g.rows : rows.map(i => g.rows[i]).filter(Boolean);
  const drawn = all.slice(0, CAP);
  const table = el('table', { class: 'gt-table' }, el('tbody', {}, ...g.cols.map((c, k) => el('tr', {}, el('th', { scope: 'row' }, c), ...drawn.map(r => el('td', g.num?.[k] ? { class: 'num' } : {}, r[k]?.text ?? ''))))));
  const copy = el('button', { type: 'button' }, 'Copy'), close = el('button', { type: 'button' }, 'Close');
  const said = el('span', { class: 'meta', role: 'status' });
  const name = headingOf(t) || 'grid';
  const d = toolDialog(t, `Transposed ${name}`, back,
    ...(all.length > CAP ? [el('p', { class: 'meta' }, `The first ${CAP} of ${fmtNum(all.length)} rows: a transposed grid is a column per row, so the dialog stops at ${CAP}; Copy takes every row.`)] : []),
    el('div', { class: 'gt-scroll' }, table), el('p', {}, copy, ' ', close, ' ', said));
  copy.addEventListener('click', () => {
    const text = g.cols.map((c, k) => [c, ...all.map(r => (r[k]?.text ?? '').replace(/[\t\r\n]+/g, ' '))].join('\t')).join('\n');
    void copyText(text).then(ok => { said.textContent = ok ? `Copied ${all.length} rows transposed` : 'Not copied: the browser refused the clipboard'; });
  });
  close.addEventListener('click', () => d.close());
}

// gridMenu: the grid's whole menu, DBA Dash's order. td: the clicked cell, th: the clicked header cell, neither: the grid
// itself. Every item acts or says why it cannot, in words in the item.
export function gridMenu(t: HTMLTableElement, td: Element | null, th: Element | null, back: HTMLElement | null): MenuItem[] {
  const ns = names(t), hs = heads(t), p = load(t), plain = !t.classList.contains('grid');   // plain: the group panel's table
  const j = td && td.parentElement ? colOf(td) : th ? hs.indexOf(th as HTMLTableCellElement) : -1;
  const n = j >= 0 ? ns[j] : undefined;
  const sel = picked(t), trs = bodyRows(t), none = trs.length === 0 ? 'No data to copy' : undefined;
  const g = (s: boolean) => gridOf(t, s);
  const tell = (what: string) => (ok: boolean) => said(t, what)(ok);
  const then = (f: () => void) => () => { f(); redrawPanel(t); };
  const lines = gridLines(t, td, j);
  const out: MenuItem[] = [];
  // 1. Copy (DD:438-447: Grid, Column, Cell, Row, Selected, As Markdown, As JSON)
  // Grid: the tab-separated words with the HTML table in the screen's colours beside them (main's 'Copy the rows as HTML
  // with the colours' kept: a paste into a mail or a document keeps the colours), a stored sample's mark first in both
  const copy: MenuItem[] = [{ label: 'Grid', off: none, act: () => { const x = g(false); void copyBoth((x.sample ? `<p>${html(x.sample)}</p>` : '') + toHtml(x), (x.sample ? x.sample + '\n' : '') + tsv(x)).then(tell(`${x.rows.length} rows`)); } }];
  if (j >= 0) copy.push({ label: 'Column', off: none, act: () => {
    const x = g(false), k = x.cols.indexOf(readGrid(t, true).cols[j]), at = k >= 0 ? k : 0;
    void copyText(x.rows.map(r => (r[at]?.text ?? '').replace(/[\t\r\n]+/g, ' ')).join('\n')).then(tell(`the column ${n}`));
  } });
  if (td) {
    copy.push({ label: 'Cell', act: () => { void copyText(cellText(td)).then(tell('the cell')); } });
    copy.push({ label: 'Row', act: () => {
      const x = g(false), keep = hs.map(h => !h.hasAttribute('data-gt-hidden'));
      const row = [...td.parentElement!.children].filter((_, k) => keep[k]).map(c => cellText(c).replace(/[\t\r\n]+/g, ' ')).join('\t');
      void copyText(x.cols.join('\t') + '\n' + row).then(tell('the row'));
    } });
  }
  if (td || th) copy.push({ label: 'Selected', off: none ?? (sel.length ? undefined : 'no cell is selected'), act: () => {
    const x = g(true);
    void copyBoth((x.sample ? `<p>${html(x.sample)}</p>` : '') + toHtml(x), tsv(x, false)).then(tell(`${sel.length} cells`));
  } });
  copy.push({ label: 'As Markdown', off: none, sub: [false, true].map(pr => ({ label: pr ? 'Prettified' : 'Standard', act: () => { const x = g(sel.length > 0); void copyText(markdown(x, pr)).then(tell(`${x.rows.length} rows as Markdown`)); } })) });
  copy.push({ label: 'As JSON', off: none, sub: [false, true].map(pr => ({ label: pr ? 'Prettified' : 'Compact', act: () => { const x = g(sel.length > 0); void copyText(json(x, pr)).then(tell(`${x.rows.length} rows as JSON`)); } })) });
  if (none) copy.forEach(c => { c.off = none; delete c.sub; });
  out.push({ label: 'Copy', sub: copy });
  if (plain) { out.push({ sep: true, label: '' }, ...lines.info); return out; }
  // 2. Export Excel, 3. Export file
  const report = (x: Promise<string>) => { void x.then(f => { line(t).textContent = 'Exported ' + f; }, (e: unknown) => { const l = line(t); l.textContent = 'Export failed: ' + (e instanceof Error ? e.message : String(e)); }); };
  out.push({ label: 'Export Excel', act: () => report(exportGrid(t)) });
  const file = (label: string, ext: string, type: string, write: (x: Grid, sec: Section, m: Meta) => string) =>
    ({ label, act: () => report(saveGridAs(t, ext, (sec, m) => new Blob([write({ cols: sec.cols, rows: sec.rows, num: g(false).num, sample: sec.sample, name: sec.name }, sec, m)], { type }))) });
  const head = (sec: Section, m: Meta) => ({ title: `${sec.name} (${m.instance}, ${m.tab}, ${m.window})`, zone: timeZone(m.at), at: m.at.toISOString() });
  out.push({ label: 'Export file', sub: [
    file('CSV', 'csv', 'text/csv;charset=utf-8', (_x, sec) => csv(sec)),
    file('JSON', 'json', 'application/json', x => json(x, true) + '\n'),
    file('Markdown', 'md', 'text/markdown;charset=utf-8', x => markdown(x, true)),
    file('HTML', 'html', 'text/html;charset=utf-8', (x, sec, m) => htmlDoc(x, `${sec.name} - ${m.instance}`)),
    file('SQL (INSERT) for PostgreSQL', 'pg.sql', 'application/sql', (x, sec, m) => sqlScript(x, 'postgres', head(sec, m))),
    file('SQL (INSERT) for SQL Server', 'mssql.sql', 'application/sql', (x, sec, m) => '﻿' + sqlScript(x, 'sqlserver', head(sec, m))),
  ] });
  // 4. Transpose, 5. Select
  if (!th) {
    const selRows = [...new Set(sel.map(c => trs.indexOf(c.parentElement as HTMLTableRowElement)).filter(i => i >= 0))].sort((a, b) => a - b);
    const tp: MenuItem[] = [];
    if (td) tp.push({ label: 'This row', act: () => transpose(t, [trs.indexOf(td.parentElement as HTMLTableRowElement)], back) });
    tp.push({ label: 'Selected rows', off: none ?? (selRows.length ? undefined : 'no cell is selected'), act: () => transpose(t, selRows, back) });
    tp.push({ label: 'Grid', off: none, act: () => transpose(t, 'all', back) });
    out.push({ label: 'Transpose', sub: tp });
  }
  if (lines.select.length) out.push({ label: 'Select', sub: lines.select });
  if (sel.length) out.push({ label: 'Clear the selection', act: () => clear(t) });
  // 6. the columns: the chooser, the row numbers, hide / freeze / group, the data bar
  out.push({ sep: true, label: '' }, { label: 'Columns...', act: () => chooser(t, back) }, { label: 'Row numbers', checked: !!p.rownum, act: then(() => save(t, { ...p, rownum: !p.rownum })) });
  const visible = hs.filter(h => !h.hasAttribute('data-gt-hidden')).length;
  const frozen = [...t.classList].filter(c => /^gt-f\d+$/.test(c)).length;
  if (n !== undefined) {
    if (visible > 1) out.push({ label: `Hide column ${n}`, act: then(() => save(t, { ...p, hidden: [...new Set([...p.hidden, n])] })) });
    const upTo = hs.slice(0, j + 1).filter(h => !h.hasAttribute('data-gt-hidden')).length;
    if (j < FREEZE_POS && upTo <= MAX_FROZEN && upTo < visible && frozen !== upTo) out.push({ label: `Freeze the columns up to ${n}`, act: then(() => save(t, { ...p, frozen: upTo })) });
    if (groupings.get(t)?.col !== n) out.push({ label: `Group by ${n}`, act: then(() => group(t, n)) });
  }
  if (frozen) out.push({ label: 'Unfreeze the columns', act: then(() => save(t, { ...p, frozen: 0 })) });
  if (groupings.has(t)) out.push({ label: 'Ungroup', act: then(() => group(t, null)) });
  if (n !== undefined && hs[j].classList.contains('num')) {
    const st = p.bars[n];
    const pick = (to: BarStyle | null) => then(() => { const b = { ...p.bars }; if (to) b[n] = to; else delete b[n]; save(t, { ...p, bars: b }); });
    out.push({ label: 'Data bar', sub: [...BAR_STYLES.map(([k, l]) => ({ label: l, checked: st === k, act: pick(k) })), { label: 'Remove', off: st ? undefined : `no data bar on ${n}`, act: pick(null) }] });
  }
  // 7. the filters (a grid with a filter row): by the clicked value, by a selection in one column, any operator, clear
  out.push({ sep: true, label: '' });
  if (td && filterable(t)) {
    const v = cellText(td).replace(/\s+/g, ' ').trim(), short = v.length > 30 ? v.slice(0, 30) + '...' : v;   // as the filter compares (ui.ts shownWords)
    if (v !== '') {
      out.push({ label: `Filter by value: ${short}`, act: () => addCond(t, j, '=' + quoteFilter(v)) });
      out.push({ label: `Exclude value: ${short}`, act: () => addCond(t, j, '<>' + quoteFilter(v)) });
    }
    const inCol = sel.length > 1 && sel.every(c => colOf(c) === j) ? [...new Set(sel.map(c => cellText(c).replace(/\s+/g, ' ').trim()))] : [];
    if (inCol.length) {
      const list = inCol.map(quoteFilter).join(',');
      out.push({ label: 'Filter by these values', act: () => { clear(t); addCond(t, j, 'in:' + list); } });
      out.push({ label: 'Exclude these values', act: () => { clear(t); addCond(t, j, '!in:' + list); } });
    }
    const num = hs[j].classList.contains('num');
    out.push({ label: 'All filters', sub: [...(num ? [] : ['Like', 'Not like']), '=', '<>', '>', '<', '>=', '<='].map(op => ({ label: op, act: () => filterPrompt(t, j, op, v, back) })) });
  }
  out.push({ label: 'Clear filters', off: filtered(t) ? undefined : 'no filter is set', act: () => filterInputs(t).forEach((i, k) => { if (i.value) setFilter(t, k, ''); }) });
  // 8. the counts and the statistics
  out.push({ sep: true, label: '' }, ...lines.info);
  return out;
}
// emptyMenu: a grid empty from the start (ui.ts: its header alone, the columns in its p.empty's data-cols)
function emptyMenu(p: Element): MenuItem[] {
  let cols: string[] = [];
  try { cols = JSON.parse(p.getAttribute('data-cols') ?? '[]') as string[]; } catch { /* none read */ }
  const none = 'No data to copy';
  return [
    { label: 'Copy', sub: ['Grid', 'As Markdown', 'As JSON'].map(label => ({ label, off: none })) },
    { label: 'Export Excel', act: () => { void exportGrid(p).catch((e: unknown) => {
      const box = p.closest('.empty-grid') ?? p.parentElement;
      if (!box) return;
      let l = box.querySelector<HTMLElement>(':scope > .gt-stats');
      if (!l) { l = el('p', { class: 'meta gt-stats', role: 'status' }); box.append(l); }
      l.textContent = 'Export failed: ' + (e instanceof Error ? e.message : String(e));
    }); } },
    { sep: true, label: '' },
    { label: 'Columns...', off: 'no rows: the columns are chosen on a grid with rows' },
    { label: 'Clear filters', off: 'no filter is set' },
    { sep: true, label: '' },
    { label: `Rows: 0 | Cols: ${fmtNum(cols.length)}`, info: true, act: () => { void copyText(`Rows: 0 | Cols: ${cols.length}`); } },
  ];
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
    + '.grid td.gt-bar.gt-bar-under{background-size:100% 4px;background-position:0 100%;background-repeat:no-repeat}'
    + '.grid td.gt-tl-r{background-color:rgba(217,48,37,.3)}.grid td.gt-tl-a{background-color:rgba(242,153,0,.3)}.grid td.gt-tl-g{background-color:rgba(30,142,62,.3)}'
    // the row numbers: a counter in a cell the CSS draws before each row (no column: hide, freeze and filter keep theirs)
    + 'table.grid.gt-rownum > tbody{counter-reset:gtrow}table.grid.gt-rownum > tbody > tr:not(.trend-row){counter-increment:gtrow}'
    + 'table.grid.gt-rownum > tbody > tr:not(.trend-row)::before{content:counter(gtrow);display:table-cell;padding:.2rem .5rem;color:var(--muted);text-align:right;font-variant-numeric:tabular-nums}'
    + 'table.grid.gt-rownum > thead > tr::before{content:"";display:table-cell}table.grid.gt-rownum > thead > tr:first-child::before{content:"#";color:var(--muted);padding:.2rem .5rem}'
    + '.gt-dialog{max-width:min(90vw,70rem);background:var(--card);color:var(--fg);border:1px solid var(--line)}.gt-dialog .gt-scroll{max-height:60vh}'
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
  // the grid's menu (ui.ts askGridMenu): built here and shown in the grid's host - the open dialog it sits in, else the body
  document.addEventListener('pgvigil:gridmenu', e => {
    const d = (e as CustomEvent<GridMenuAsk>).detail;
    if (!d || d.done) return;
    const items = d.table ? gridMenu(d.table, d.td, d.th, d.back) : d.empty ? emptyMenu(d.empty) : null;
    if (!items) return;
    d.done = true;
    const host = (d.table ?? d.empty)?.closest('dialog[open]') ?? undefined;
    showTreeMenu(d.x, d.y, items, d.back, 'Grid menu', host);
  });
  document.addEventListener('click', onClick);
  document.addEventListener('mousedown', e => {   // a Shift+click on a cell extends the tools' selection, not the browser's text selection
    if (e.shiftKey && (e.target as Element | null)?.closest?.('table.grid > tbody > tr > td') && !(e.target as Element).closest('a[href], button, input, select, textarea')) e.preventDefault();
  });
  window.addEventListener('resize', () => document.querySelectorAll<HTMLTableElement>('table.grid[data-gt-frozen]').forEach(ask));
}
