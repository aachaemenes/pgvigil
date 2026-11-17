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
// header, which the export honours. The one hook is the grid's menu: ui.ts sends a 'pgvigil:gridmenu' event (askGridMenu)
// and the tools build the menu from it, a page's own lines (the event's extra) at its end.
import { Cell, Kind, Meta, Section, Status, csv, exportGrid, fillOf, fontOf, fromText, gridMeta, headFill, linkFill, linkFont, readGrid, saveGridAs, statusOf, timeZone, typed } from './export';
import { openViewer } from './sqlview';
import { GridMenuAsk, cellText, copyText, el, fmtBytes, fmtNum, fmtSecs, gridModel, isCondList, offControl, quoteFilter } from './ui';
import { MenuItem, gridLines, showTreeMenu } from './treemenu';
import { Grid, htmlDoc, json, markdown, sqlScript, sqlWire, tsv } from './gridwriters';
import { get, post } from './api';
import { dialogRole } from './needs';
import { parse } from './router';
import { FLEET_OFF, SaveState, confirmWord, defaultTable, fromOff, saveKeys } from './savetable';
import { filterText, readFilterText } from './gridfilter';
import { AGG_NAMES, AGG_ORDER, AggKind, GCell, GValue, GroupSpec, groupBy } from './groupby';

// bars: a column's data bar by its name - behind the value (the default, the only style before task GM: a stored list of
// names loads as it), under the value, or a traffic light with the high values the worse or the better; the row
// headers (DBA Dash's Row Headers, task PGRID B07): rownum - shown with the row numbers (a counter, no column; a choice
// saved before B07 as 'Row numbers' on opens so), rowhead - shown with no number, neither - hidden; added: the rows' keys the page does not draw, drawn as columns at the grid's
// end (the chooser's undrawn data columns, task PGRID B05) - a key no longer offered is kept here and drawn never
type BarStyle = 'behind' | 'under' | 'worse' | 'better';
// a bar's options (DBA Dash's DataBarConfig, task PGRID B14): min / max - the values an empty / a full bar stand for
// (none: the smaller of 0 and the column's lowest, and its highest); warn / crit - where a traffic light turns amber /
// red, as % of that scale (none: DBA Dash's 20 and 50) or with values, as values in the column's own units; a bar with no
// option set is kept as its style alone (the form before the options)
interface BarSet { style: BarStyle; min?: number; max?: number; warn?: number; crit?: number; values?: boolean }
type Bar = BarStyle | BarSet;
const barOf = (b: Bar | undefined): BarSet | undefined => b === undefined ? undefined : typeof b === 'string' ? { style: b } : b;
const barKeep = (b: BarSet): Bar => b.min === undefined && b.max === undefined && b.warn === undefined && b.crit === undefined && !b.values ? b.style
  : { style: b.style, ...(b.min !== undefined ? { min: b.min } : {}), ...(b.max !== undefined ? { max: b.max } : {}), ...(b.warn !== undefined ? { warn: b.warn } : {}), ...(b.crit !== undefined ? { crit: b.crit } : {}), ...(b.values ? { values: true } : {}) };
interface Prefs { hidden: string[]; frozen: number; bars: Record<string, Bar>; rownum?: boolean; rowhead?: boolean; added?: string[] }
const BAR_STYLES: [BarStyle, string][] = [['behind', 'Behind value'], ['under', 'Under value'], ['worse', 'Traffic light (higher is worse)'], ['better', 'Traffic light (higher is better)']];
interface Grouping { spec: GroupSpec; box: HTMLElement }

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
const keptGroups = new Map<string, GroupSpec>();
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
function rawHeading(t: HTMLTableElement): string {
  let h = '';
  for (const e of document.querySelectorAll('h2, h3, h4, table.grid')) {
    if (e === t) break;
    if (e.tagName !== 'TABLE') h = label(e);
  }
  return h;
}
function headingOf(t: HTMLTableElement): string {
  return rawHeading(t).replace(/\s*\(.*\)$/, '');   // 'Jobs (last 24 hours)': the range is not part of the grid's name
}
// gridName: a grid's name in a saved view (VIEWS slice B): the page's own data-grid-name, else its heading without the
// scope ('Summary - tag x', fleet.ts tagWords) and then without the range ('Performance summary (last hour)'), so a
// view saved at the root applies under a tag folder and over another range
export function gridName(t: HTMLTableElement): string {
  return t.dataset.gridName || rawHeading(t).replace(/\s+-\s+(tag .*|the untagged instances|\(no [^)]*\))$/, '').replace(/\s*\(.*\)$/, '').trim();
}
function hash(s: string): string {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}
// the key: the page's own columns alone (a column the chooser added never changes which grid it is)
const isAdded = (h: Element | undefined) => !!h?.hasAttribute('data-gt-added');
const ownNames = (t: HTMLTableElement) => { const hs = heads(t); return names(t).filter((_, j) => !isAdded(hs[j])); };
const keyOf = (t: HTMLTableElement) => `pgvigil.grid.${(/^#\/([A-Za-z_]+)/.exec(location.hash)?.[1] ?? 'summary')}.${hash(headingOf(t) + '|' + ownNames(t).join('|'))}`;

// ---- a saved view's layouts (VIEWS slice B, views.ts) ------------------------------------------------------------
// While a view is loaded its layouts are a layer over the browser's own choices: every grid of the page is drawn from
// the layer alone (one the view does not name: with nothing hidden, frozen or barred - never the viewer's own), a
// change made meanwhile goes to the layer and marks the view changed, and dropping the layer ({None}, another page)
// gives the browser's own choices back. A layout matches a grid by its name (gridName); its hidden and barred columns
// apply where those columns still exist, its frozen count as far as the grid allows.
export interface Layout { grid: string; columns: string[]; hidden: string[]; frozen: number; bars: string[] }
let layer: Map<string, Prefs> | null = null;
const layerSeen = new Set<string>();
let layerEdited = false;
export function setLayer(ls: Layout[] | null) {
  layer = ls ? new Map(ls.filter(l => l && typeof l.grid === 'string').map(l => [l.grid, {
    hidden: Array.isArray(l.hidden) ? l.hidden.filter(x => typeof x === 'string') : [],
    frozen: Math.max(0, Math.min(MAX_FROZEN, Math.floor(Number(l.frozen) || 0))),
    // a view keeps its barred columns as a list of names (0259's stored form): each is GM's default style, 'behind',
    // as GM reads its own older list form (prefs below); a view does not keep a bar's other style
    bars: Array.isArray(l.bars) ? Object.fromEntries(l.bars.filter(x => typeof x === 'string').map(n => [n, 'behind' as BarStyle])) as Record<string, BarStyle> : {} }])) : null;
  layerSeen.clear();
  layerEdited = false;
  for (const t of document.querySelectorAll<HTMLTableElement>('table.grid')) apply(t);
}
// layerState: a view's layer is on; it was changed since it was set; the layouts it names whose grid has not been drawn
export function layerState(): { on: boolean; edited: boolean; missing: string[] } {
  // missing: only a layout that holds something (an empty one asks nothing of the page)
  return { on: layer !== null, edited: layerEdited, missing: layer ? [...layer.entries()].filter(([n, p]) => !layerSeen.has(n) && (p.hidden.length || p.frozen || Object.keys(p.bars).length)).map(([n]) => n) : [] };
}
// layoutsOf: the grids of the page as a view keeps them (what the layer or the browser draws them with now): a grid the
// page names (data-grid-name) always, any other only when something is hidden, frozen or barred on it - a heading that
// changes by itself (a 'since <time>', an open drill's 'Events: ...') is never kept for nothing (review M1)
export function layoutsOf(root: ParentNode = document): Layout[] {
  const out = new Map<string, Layout>();
  for (const t of root.querySelectorAll<HTMLTableElement>('main table.grid')) {
    const n = gridName(t);
    if (!n || out.has(n)) continue;
    const p = load(t);
    if (!t.dataset.gridName && !p.hidden.length && !p.frozen && !Object.keys(p.bars).length) continue;
    out.set(n, { grid: n, columns: names(t), hidden: p.hidden, frozen: p.frozen, bars: Object.keys(p.bars) });
  }
  return [...out.values()];
}

function load(t: HTMLTableElement): Prefs {
  const none: Prefs = { hidden: [], frozen: 0, bars: {} }, k = keyOf(t);
  if (layer) { const n = gridName(t); layerSeen.add(n); return layer.get(n) ?? none; }
  let raw: string | null = null;
  try { raw = localStorage.getItem(k); } catch { /* the browser refuses storage: what this page load chose is in mem */ }
  if (raw === null) return mem.get(k) ?? none;
  try {
    const p = JSON.parse(raw) as Partial<Prefs> | null;
    if (!p || typeof p !== 'object') return none;
    const list = (v: unknown) => Array.isArray(v) ? v.filter(x => typeof x === 'string') as string[] : [];
    const styles = new Set(BAR_STYLES.map(x => x[0]));
    const fin = (x: unknown) => typeof x === 'number' && Number.isFinite(x) ? x : undefined;
    const bars: Record<string, Bar> = Array.isArray(p.bars) ? Object.fromEntries(list(p.bars).map(n => [n, 'behind' as BarStyle]))
      : p.bars && typeof p.bars === 'object' ? Object.fromEntries(Object.entries(p.bars as Record<string, unknown>).flatMap(([n, v]): [string, Bar][] => {
        if (typeof v === 'string') return styles.has(v as BarStyle) ? [[n, v as BarStyle]] : [];
        const o = v && typeof v === 'object' ? v as Record<string, unknown> : null;
        return o && styles.has(o.style as BarStyle) ? [[n, barKeep({ style: o.style as BarStyle, min: fin(o.min), max: fin(o.max), warn: fin(o.warn), crit: fin(o.crit), values: o.values === true })]] : [];
      })) : {};
    return { hidden: list(p.hidden), frozen: Math.max(0, Math.min(MAX_FROZEN, Math.floor(Number(p.frozen) || 0))), bars, rownum: p.rownum === true, rowhead: p.rowhead === true && p.rownum !== true, added: list(p.added) };
  } catch { return none; }   // a value another version wrote
}
function save(t: HTMLTableElement, p: Prefs) {
  if (layer) {   // a loaded view's grid: the change is the view's until it is saved (views.ts), the browser's own untouched
    layer.set(gridName(t), p);
    layerEdited = true;
    window.dispatchEvent(new CustomEvent('pgvigil:layer'));
    apply(t, p);
    return;
  }
  const k = keyOf(t), empty = !p.hidden.length && !p.frozen && !Object.keys(p.bars).length && !p.rownum && !p.rowhead && !p.added?.length;
  if (empty) mem.delete(k); else mem.set(k, p);
  try {
    if (empty) localStorage.removeItem(k); else localStorage.setItem(k, JSON.stringify(p));
  } catch { /* a private window: the choice holds while the page is loaded (mem) */ }
  apply(t, p);
}

// ---- the undrawn data columns (task PGRID B05) ------------------------------------------------------------------

// neverOf: the keys a page holds back on purpose (a masked text's raw form, an internal id, a sort value of a column it
// hides itself): its grid's data-gt-never, a JSON array of keys, empty by default
function neverOf(t: HTMLTableElement): Set<string> {
  try {
    const v = JSON.parse(t.getAttribute('data-gt-never') ?? '[]') as unknown;
    return new Set(Array.isArray(v) ? v.filter((x): x is string => typeof x === 'string') : []);
  } catch { return new Set(); }   // a page's list that does not read: nothing held back beyond the '_' rule
}
// offered: the keys the grid's rows carry and no column of the page draws, in the order first met - never a key
// starting '_' (a page's own working value) nor one the page holds back
function offered(t: HTMLTableElement): string[] {
  const m = gridModel(t);
  if (!m?.keys) return [];
  const hs = heads(t), own = new Set(m.cols.filter((_, j) => !isAdded(hs[j])).map(c => c.key)), never = neverOf(t);
  return m.keys().filter(k => !own.has(k) && !k.startsWith('_') && !never.has(k));
}
// addedOf: the kept added columns the grid offers now (a key held back since, or gone from the rows, is not drawn)
const addedOf = (t: HTMLTableElement, p: Prefs) => { const o = new Set(offered(t)); return (p.added ?? []).filter(k => o.has(k)); };

// ---- drawing what is kept ------------------------------------------------------------------------------------

// apply: the hidden columns (a class per column and data-gt-hidden on the header, which the export reads), the frozen
// ones (sticky, each at the width of the ones before it) and the data bars. p: the choice just made; without it the
// kept one. The hidden columns are written first, then every width is read in one pass, then the frozen ones written.
function apply(t: HTMLTableElement, p: Prefs = load(t)) {
  gridModel(t)?.extra?.(addedOf(t, p));   // the added columns first: the rules below read the headers drawn
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
  t.classList.toggle('gt-rowhead', !p.rownum && !!p.rowhead);
  bars(t, p, ns);
}

// bars: a column's data bar (the rows drawn; a cell the page colours carries none): behind each number or under it, its
// length the value's place on the scale (from the bar's Minimum, else the smaller of 0 and the column's lowest, to its
// Maximum, else the column's highest); or a traffic light (DBA Dash's DataBarSettings.ColorFor): red at or above
// Critical at, amber at or above Warning at, else green - % of the scale measured up for 'higher is worse' and down for
// 'higher is better', or with 'Thresholds are values' the values themselves (at or below them for 'higher is better').
// A screen aid in the tools' own classes (never ok / warn / crit, which the export reads as a status): no file carries it.
function bars(t: HTMLTableElement, p: Prefs, ns: string[]) {
  const on = new Map(Object.entries(p.bars).map(([n, b]) => [ns.indexOf(n), barOf(b)!] as [number, BarSet]).filter(([j]) => j >= 0));
  const had = t.hasAttribute('data-gt-bars');
  if (!on.size && !had) return;
  t.toggleAttribute('data-gt-bars', on.size > 0);
  const trs = bodyRows(t);
  const m = gridModel(t), data = m?.rows(), modelled = !!(data && m && m.cols.length === ns.length);
  ns.forEach((_, j) => {
    const b = on.get(j), st = b?.style;
    const vals = trs.map((tr, i) => st ? numberAt(t, tr.children[j], modelled ? data![i]?.[m!.cols[j].key] : undefined)?.n : undefined);
    const nums = vals.filter((v): v is number => v !== undefined);
    const lo = nums.length ? Math.min(...nums) : 0, hi = nums.length ? Math.max(...nums) : 0;
    const mn = b?.min ?? Math.min(0, lo), mx = b?.max ?? hi;
    const place = (v: number) => mx > mn ? Math.min(1, Math.max(0, (v - mn) / (mx - mn))) : 0;
    trs.forEach((tr, i) => {
      const td = tr.children[j] as HTMLElement | undefined, v = vals[i];
      if (!td) return;
      const own = !!statusOf(td);
      const share = (st === 'behind' || st === 'under') && v !== undefined && v > mn && mx > mn && !own ? Math.max(1, Math.round(place(v) * 100)) : 0;
      td.classList.toggle('gt-bar', share > 0);
      td.classList.toggle('gt-bar-under', share > 0 && st === 'under');
      if (share > 0) td.style.setProperty('--gt-share', `${share}%`); else td.style.removeProperty('--gt-share');
      let light = '';
      if ((st === 'worse' || st === 'better') && v !== undefined && !own) {
        const warn = b!.warn ?? 20, crit = b!.crit ?? 50, better = st === 'better';
        if (b!.values) light = (better ? v <= crit : v >= crit) ? 'r' : (better ? v <= warn : v >= warn) ? 'a' : 'g';
        else { const at = (better ? 1 - place(v) : place(v)) * 100; light = at >= crit ? 'r' : at >= warn ? 'a' : 'g'; }
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

// ---- group by (task PGRID B10: DBA Dash's Group By dialog) --------------------------------------------------

// group: a panel above the grid with the grouped rows (groupby.ts: the rows the filters leave, grouped by the spec's
// columns, with its counts and aggregates under DBA Dash's names), the largest group first. It follows the grid's
// filters; the grid itself stays. A group's row (a click, or Enter on its key) filters the grid to that group's values
// (DBA Dash's drill: ANDed with what the filter row holds; Clear filters undoes it). spec null = no grouping. The
// grouping is kept by the grid's key while the page is loaded.
function group(t: HTMLTableElement, spec: GroupSpec | null) {
  groupings.get(t)?.box.remove();
  groupings.delete(t);
  const k = keyOf(t);
  if (spec === null) { keptGroups.delete(k); return; }
  const ns = names(t), g = readGrid(t, true);
  const cells: GCell[][] = g.rows.map(r => ns.map((_, j) => { const c = r[j], v = numOf(c); return v ? { text: c?.text ?? '', n: v.n, kind: v.kind } : { text: c?.text ?? '' }; }));
  const res = groupBy(ns, cells, spec);
  if (!res.cols.length) { keptGroups.delete(k); return; }   // a key column gone from the grid: no grouping
  keptGroups.set(k, spec);
  const nk = spec.keys.length;
  const word = (v: GValue): string => v === null ? '' : 'text' in v ? v.text : v.pct ? `${fmtNum(Math.round(v.n * 10) / 10)} %` : show(v.n, (v.kind ?? 'int') as Kind);
  const drill = (key: string[]) => { if (!filterable(t)) return; clear(t); spec.keys.forEach((c, i) => { const j = ns.indexOf(c); if (j >= 0) addCond(t, j, '=' + quoteFilter(key[i])); }); };
  const body = el('tbody', {}, ...res.rows.map(r => {
    const keyBtn = el('button', { type: 'button', class: 'link', title: filterable(t) ? `Filter the grid to ${r.key.map((x, i) => `${spec.keys[i]} ${x || '(empty)'}`).join(', ')}` : '' }, r.key[0] || '(empty)');
    const tr = el('tr', {}, el('th', { scope: 'row' }, keyBtn), ...r.key.slice(1).map(x => el('td', {}, x || '(empty)')),
      ...r.vals.map((v, i) => el('td', /\| (Min|Max)$/.test(res.cols[nk + i]) && v !== null && 'text' in v ? {} : { class: 'num' }, word(v))));
    tr.addEventListener('click', e => { if ((e.target as Element).closest('a[href]')) return; drill(r.key); });
    return tr;
  }));
  const table = el('table', { class: 'gt-table' }, el('thead', {}, el('tr', {}, ...res.cols.map((c, i) => el('th', i < nk ? { scope: 'col' } : { scope: 'col', class: 'num' }, c)))), body);
  const off = el('button', { type: 'button', class: 'link' }, 'Ungroup');
  off.addEventListener('click', () => { group(t, null); redrawPanel(t); homeOf(t)?.focus(); });
  const box = el('div', { class: 'gt-groups', role: 'group', 'aria-label': `Grouped by ${spec.keys.join(', ')}` },
    el('p', { class: 'meta' }, `Grouped by ${spec.keys.join(', ')}: ${fmtNum(res.rows.length)} group${res.rows.length === 1 ? '' : 's'} of ${fmtNum(g.rows.length)} rows${filterable(t) ? "; a group's row filters the grid to it" : ''}. `, off),
    el('div', { class: 'gt-scroll', tabindex: '0', role: 'region', 'aria-label': `The groups by ${spec.keys.join(', ')}` }, table));
  const host = boxOf(t);
  if (host.classList.contains('grid-box')) host.insertBefore(box, wrapOf(t)); else host.before(box);
  groupings.set(t, { spec, box });
}
// numCols: the columns with a number in any row the filters leave (their Sum, Sum % and Avg are offered); the grid read once
const numCols = (t: HTMLTableElement): Set<number> => { const rs = readGrid(t, true).rows, out = new Set<number>(); names(t).forEach((_, j) => { if (rs.some(r => !!numOf(r[j]))) out.add(j); }); return out; };
// simpleGroup: the chooser's 'Group by' select - the column, its row count and the sum of every other shown number
// column (the panel before B10's dialog)
function simpleGroup(t: HTMLTableElement, col: string): GroupSpec {
  const ns = names(t), hs = heads(t), num = numCols(t);
  return { keys: [col], count: true, pct: false, aggs: ns.map((n, j) => ({ n, j })).filter(x => x.n !== col && !hs[x.j].hasAttribute('data-gt-hidden') && num.has(x.j)).map(x => ({ col: x.n, kinds: ['sum'] as AggKind[] })) };
}
// groupDialog: DBA Dash's Group By dialog - a row per shown column: Group By, then its aggregates (Count Distinct, Min
// and Max on every column; Sum, Sum % and Avg on a number column); Include Count (ticked) and Count % of Total; OK with
// no column to group by is refused in words. pre: the clicked column, ticked to group by (or the grouping in force).
function groupDialog(t: HTMLTableElement, pre: string | null, back: HTMLElement | null) {
  const ns = names(t), hs = heads(t), was = groupings.get(t)?.spec, num = numCols(t);
  const tick = (label: string, on: boolean) => { const c = el('input', { type: 'checkbox', 'aria-label': label }) as HTMLInputElement; c.checked = on; return c; };
  const rows = ns.map((n, j) => ({ n, j })).filter(x => !hs[x.j].hasAttribute('data-gt-hidden')).map(({ n, j }) => {
    const kinds: AggKind[] = num.has(j) ? AGG_ORDER : ['distinct', 'min', 'max'];
    const has = was?.aggs.find(a => a.col === n)?.kinds ?? [];
    return { n, key: tick(`Group By ${n}`, was ? was.keys.includes(n) : n === pre), aggs: new Map(kinds.map(k => [k, tick(`${AGG_NAMES[k]} ${n}`, has.includes(k))])) };
  });
  const incl = el('input', { type: 'checkbox' }) as HTMLInputElement; incl.checked = was ? was.count : true;
  const pct = el('input', { type: 'checkbox' }) as HTMLInputElement; pct.checked = !!was?.pct;
  const table = el('table', { class: 'gt-table' },
    el('thead', {}, el('tr', {}, el('th', { scope: 'col' }, 'Group By'), el('th', { scope: 'col' }, 'Column'), ...AGG_ORDER.map(k => el('th', { scope: 'col' }, AGG_NAMES[k])))),
    el('tbody', {}, ...rows.map(r => el('tr', {}, el('td', {}, r.key), el('th', { scope: 'row' }, r.n), ...AGG_ORDER.map(k => el('td', {}, r.aggs.get(k) ?? ''))))));
  const err = el('p', { class: 'error', role: 'alert' });
  const ok = el('button', { type: 'button' }, 'OK'), cancel = el('button', { type: 'button' }, 'Cancel');
  const d = toolDialog(t, 'Group By', back,
    el('p', { class: 'meta' }, 'Tick the columns to group by; for the others, the aggregates to show (Sum, Sum % and Avg on a number column). The groups show above the grid and follow its filters.'),
    el('div', { class: 'gt-scroll' }, table),
    el('p', {}, el('label', {}, incl, ' Include Count'), ' ', el('label', {}, pct, ' Count % of Total')), err, el('p', {}, ok, ' ', cancel));
  ok.addEventListener('click', () => {
    const keys = rows.filter(r => r.key.checked).map(r => r.n);
    if (!keys.length) { err.textContent = 'Tick at least one column to group by (its Group By box).'; return; }
    const aggs = rows.filter(r => !r.key.checked).map(r => ({ col: r.n, kinds: AGG_ORDER.filter(k => r.aggs.get(k)?.checked) })).filter(a => a.kinds.length);
    group(t, { keys, count: incl.checked, pct: pct.checked, aggs });
    redrawPanel(t);
    d.close();
  });
  cancel.addEventListener('click', () => d.close());
  (rows.find(r => r.n === pre)?.key ?? rows[0]?.key)?.focus();
}

// ---- the chooser ---------------------------------------------------------------------------------------------

// redrawPanel: a choice made outside an open chooser (the grid's menu, the group box's Ungroup) draws it again from
// what is kept, so its ticks and its off buttons say what is now true; the focus stays where it is
function redrawPanel(t: HTMLTableElement) {
  if (panels.get(t)?.isConnected) chooser(t, panelBacks.get(t) ?? null, false);
}

// chooser: the panel with every tool of a grid: each column's tick, its data bars, the frozen columns, the group-by,
// a column's cells for the selection line. back: where the focus returns on Close; focus false = drawn again after
// the page redrew the grid, without taking the focus from where it is (the names picked in its list are kept then).
// The list (DBA Dash's Columns dialog, task PGRID B05): the page's columns, then the rows' keys it does not draw
// ('not drawn by this page', unticked until drawn); one tab stop (a listbox): the arrows move, Space picks, Shift with
// an arrow picks a range, Ctrl+A picks every name; a click picks a name, Ctrl+click adds one, Shift+click a range. All
// ticks every column of the page, None unticks all but the first (a grid keeps one column), Toggle selected ticks or
// unticks each picked name.
const picksOf = new Map<string, Set<string>>();   // by the grid's key: the names picked in its open chooser
let colSeq = 0;
function chooser(t: HTMLTableElement, back: HTMLElement | null, focus = true) {
  panels.get(t)?.remove();
  const ns = names(t), hs = heads(t), p = load(t), k = keyOf(t);
  const own = ns.map((n, j) => ({ n, j })).filter(x => !isAdded(hs[x.j]));
  const first = own[0]?.n ?? '';
  const hidden = new Set(p.hidden.filter(n => ns.includes(n))), barsOn = new Set(Object.keys(p.bars).filter(n => ns.includes(n)));
  const added = new Set(addedOf(t, p));
  if (focus || !picksOf.has(k)) picksOf.set(k, new Set());
  const picks = picksOf.get(k)!;
  const box = el('div', { class: 'gt-panel', role: 'dialog', 'aria-label': 'Columns of this grid' });
  const close = () => {
    box.remove(); panels.delete(t); openPanels.delete(k); picksOf.delete(k);
    const to = back && back.isConnected && back.tabIndex >= 0 ? back : homeOf(t);   // else the grid's current cell (its one tab stop)
    to?.focus();
  };
  // a bar ticked here keeps its style (behind the value when new); the row numbers stay as they are
  const now = (): Prefs => ({ hidden: [...hidden], frozen: Number(freeze.value) || 0, bars: Object.fromEntries([...barsOn].map(n => [n, p.bars[n] ?? 'behind' as BarStyle])), rownum: p.rownum, rowhead: p.rowhead, added: [...added] });
  const said = el('span', { class: 'meta', role: 'status' });
  const list = el('div', { class: 'gt-cols', role: 'listbox', 'aria-multiselectable': 'true', tabindex: '0',
    'aria-label': 'The columns: the arrows move, Space picks a name, Shift with an arrow picks a range, Ctrl+A picks every name; Toggle selected ticks or unticks the picked names' });
  interface Item { name: string; row: HTMLElement; tick: HTMLInputElement; undrawn: boolean }
  const items: Item[] = [];
  let act = 0, anchor = -1;
  // shown: a name drawn now (a page's column not hidden, an added key ticked)
  const shownNow = (it: Item) => it.undrawn ? added.has(it.name) : !hidden.has(it.name);
  // keep: never every page column hidden - the grid's first stays, said in words
  const keep = () => { if (own.length && own.every(x => hidden.has(x.n))) { hidden.delete(first); said.textContent = `${first} stays: a grid keeps one column.`; } };
  const setShown = (it: Item, on: boolean) => { if (it.undrawn) { if (on) added.add(it.name); else added.delete(it.name); } else if (on) hidden.delete(it.name); else hidden.add(it.name); };
  const ticks = () => items.forEach(it => { it.tick.checked = shownNow(it); });
  const paint = () => {
    items.forEach((it, i) => { it.row.setAttribute('aria-selected', String(picks.has(it.name))); it.row.classList.toggle('gt-act', i === act); });
    if (items[act]) list.setAttribute('aria-activedescendant', items[act].row.id); else list.removeAttribute('aria-activedescendant');
    offState();
  };
  const range = (a: number, b: number) => { picks.clear(); for (let i = Math.min(a, b); i <= Math.max(a, b); i++) picks.add(items[i].name); };
  const addItem = (name: string, undrawn: boolean, j: number) => {
    const tick = el('input', { type: 'checkbox', tabindex: '-1' }) as HTMLInputElement;
    const nameEl = el('span', { class: 'gt-col-name' }, name);
    const row = el('div', { class: 'gt-col', role: 'option', id: `gt-col-${++colSeq}`, ...(undrawn ? { 'data-gt-undrawn': '' } : {}) }, el('label', {}, tick, ' ', nameEl));
    const it: Item = { name, row, tick, undrawn };
    tick.checked = shownNow(it);
    tick.addEventListener('change', () => { said.textContent = ''; setShown(it, tick.checked); keep(); ticks(); save(t, now()); });
    // a name picks (its tick is the checkbox alone): a click one, Ctrl+click (Cmd) adds or drops one, Shift+click a range
    nameEl.addEventListener('click', e => {
      e.preventDefault();
      const i = items.indexOf(it);
      if (e.shiftKey && anchor >= 0) range(anchor, i);
      else if (e.ctrlKey || e.metaKey) { if (picks.has(name)) picks.delete(name); else picks.add(name); anchor = i; }
      else { picks.clear(); picks.add(name); anchor = i; }
      act = i; paint(); list.focus();
    });
    if (undrawn) row.append(' ', el('span', { class: 'meta' }, 'not drawn by this page'));
    else if (hs[j]?.classList.contains('num')) {
      const bar = el('input', { type: 'checkbox', tabindex: '-1', 'aria-label': `Data bars on ${name}` }) as HTMLInputElement;
      bar.checked = barsOn.has(name);
      bar.addEventListener('change', () => { if (bar.checked) barsOn.add(name); else barsOn.delete(name); save(t, now()); });
      row.append(' ', el('label', { class: 'meta' }, bar, ' data bars'));
    }
    items.push(it); list.append(row);
  };
  own.forEach(x => addItem(x.n, false, x.j));
  offered(t).forEach(key => addItem(key, true, -1));
  list.addEventListener('keydown', e => {
    const n = items.length;
    if (!n) return;
    let to = -1;
    if (e.key === 'ArrowDown') to = Math.min(n - 1, act + 1);
    else if (e.key === 'ArrowUp') to = Math.max(0, act - 1);
    else if (e.key === 'Home') to = 0;
    else if (e.key === 'End') to = n - 1;
    else if (e.key === ' ') { e.preventDefault(); const nm = items[act].name; if (picks.has(nm)) picks.delete(nm); else picks.add(nm); anchor = act; paint(); return; }
    else if ((e.key === 'a' || e.key === 'A') && (e.ctrlKey || e.metaKey)) { e.preventDefault(); items.forEach(it => picks.add(it.name)); paint(); return; }
    else return;
    e.preventDefault();
    if (e.shiftKey) range(anchor >= 0 ? anchor : act, to);
    act = to; paint();
    items[act].row.scrollIntoView({ block: 'nearest' });
  });
  const freeze = el('input', { type: 'number', min: '0', max: String(Math.min(MAX_FROZEN, ns.length - 1)), value: String(Math.min(p.frozen, Math.max(0, ns.length - 1))), 'aria-label': 'Columns frozen at the left' }) as HTMLInputElement;
  freeze.addEventListener('change', () => { freeze.value = String(Math.max(0, Math.min(Number(freeze.max), Math.floor(Number(freeze.value) || 0)))); save(t, now()); });
  const by = el('select', { 'aria-label': 'Group by a column' }, el('option', { value: '' }, 'no grouping')) as HTMLSelectElement;
  ns.forEach(n => by.append(el('option', groupings.get(t)?.spec.keys[0] === n ? { value: n, selected: '' } : { value: n }, n)));
  by.addEventListener('change', () => group(t, by.value ? simpleGroup(t, by.value) : null));
  // the selection without a mouse: a column's cells, their count and sum in the line above the grid
  const sum = el('select', { 'aria-label': 'Select the cells of a column: their count, sum, average, min and max show above the grid' }, el('option', { value: '' }, 'no column')) as HTMLSelectElement;
  ns.forEach((n, j) => { if (!hidden.has(n)) sum.append(el('option', { value: String(j) }, n)); });
  sum.addEventListener('change', () => pickColumn(t, sum.value === '' ? -1 : Number(sum.value)));
  // DBA Dash's three: All, None, Toggle Selected
  const all = el('button', { type: 'button' }, 'All');
  all.addEventListener('click', () => { said.textContent = ''; hidden.clear(); ticks(); save(t, now()); offState(); });
  const none = el('button', { type: 'button' }, 'None');
  none.addEventListener('click', () => {
    own.forEach(x => { if (x.n !== first) hidden.add(x.n); }); hidden.delete(first); added.clear();
    said.textContent = `None: ${first} stays - a grid keeps one column.`;
    ticks(); save(t, now()); offState();
  });
  const toggle = el('button', { type: 'button' }, 'Toggle selected');
  toggle.addEventListener('click', () => {
    said.textContent = '';
    items.filter(it => picks.has(it.name)).forEach(it => setShown(it, !shownNow(it)));
    keep(); ticks(); save(t, now()); offState();
  });
  const reset = el('button', { type: 'button' }, 'Reset this grid');
  reset.addEventListener('click', () => { hidden.clear(); barsOn.clear(); added.clear(); freeze.value = '0'; save(t, { ...now(), rownum: false, rowhead: false, added: [] }); group(t, null); pickColumn(t, -1); chooser(t, back); });
  const done = el('button', { type: 'button' }, 'Close');
  done.addEventListener('click', close);
  box.addEventListener('keydown', e => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); close(); } });
  // a button whose click would change nothing is off with its reason, read again on every change in the panel (the
  // walk's NOTHING rows)
  const offNote = el('span', { class: 'off-reason' });
  function offState() {
    const allShown = hidden.size === 0, onlyFirst = own.every(x => x.n === first || hidden.has(x.n)) && added.size === 0;
    const plain = allShown && barsOn.size === 0 && added.size === 0 && (Number(freeze.value) || 0) === 0 && !groupings.get(t) && picked(t).length === 0 && !p.rownum && !p.rowhead;
    const why = { all: allShown ? 'every column is shown' : null, none: onlyFirst ? 'only the first column is shown' : null,
      toggle: picks.size ? null : 'no name is picked in the list', reset: plain ? 'nothing in this grid is changed from its default' : null };
    offNote.textContent = Object.values(why).filter(Boolean).join('; ');
    offControl(all, why.all, offNote);
    offControl(none, why.none, offNote);
    offControl(toggle, why.toggle, offNote);
    offControl(reset, why.reset, offNote);
  }
  box.addEventListener('change', offState);
  paint();
  box.append(el('p', { class: 'meta' }, 'Columns of this grid: shown when ticked. The choice is kept in this browser.'), list,
    el('p', {}, el('label', {}, 'Freeze the first ', freeze, ' column(s)'), ' ', el('label', {}, 'Group by ', by), ' ', el('label', {}, 'Sum the cells of ', sum)),
    el('p', {}, all, ' ', none, ' ', toggle, ' ', reset, ' ', done, ' ', said, ' ', offNote));
  const host = boxOf(t);
  if (host.classList.contains('grid-box')) host.insertBefore(box, host.firstChild); else host.before(box);
  panels.set(t, box);
  panelBacks.set(t, back);
  panelStates.set(t, offState);
  openPanels.add(k);
  if (focus) list.focus();
}

// ---- the menu (task GM: DBA Dash's grid menu) ------------------------------------------------------------------

// the copies' and the files' grid: every row the filters leave in the shown order, the columns not hidden; sel = the
// selection's rows and columns when there is one (the copies' 'Selected' and their Markdown / JSON)
function gridOf(t: HTMLTableElement, sel: boolean): Grid {
  const s = sel ? shown(t) : (() => { const g = readGrid(t); return { cols: g.cols, rows: g.rows, num: heads(t).filter(h => !h.hasAttribute('data-gt-hidden')).map(h => h.classList.contains('num')) }; })();
  return { ...s, sample: t.closest('[data-sample]')?.getAttribute('data-sample') ?? undefined };
}
// copyGrid: Copy > Grid's copy of a grid - the tab-separated words and the HTML table in the screen's colours - for a
// page's own Copy button (the Summary toolbar's Copy, task PGRID D20); the rows copied, or null when the clipboard
// refused
export async function copyGrid(t: HTMLTableElement): Promise<number | null> {
  const x = gridOf(t, false);
  const ok = await copyBoth((x.sample ? `<p>${html(x.sample)}</p>` : '') + toHtml(x), (x.sample ? x.sample + '\n' : '') + tsv(x));
  return ok ? x.rows.length : null;
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
// ---- Save Table (task PGRID B04, DBA Dash's) ---------------------------------------------------------------------
// dataTable: Script Data Table's grid - every row the page gave the grid whatever its filters, and every column the
// chooser offers (the page's own, then its undrawn data columns; never a '_' key or a held-back one), raw values
// as DBA Dash scripts its underlying DataTable
function dataTable(t: HTMLTableElement): Grid | null {
  const m = gridModel(t);
  if (!m?.all) return null;
  const hs = heads(t), own = m.cols.filter((_, j) => !isAdded(hs[j])), more = offered(t);
  return dataGrid(m.all(), [...own.map(c => c.key), ...more], [...own.map(c => c.label ?? c.key), ...more]);
}
// dataGrid: the page's rows under keys, raw values as DBA Dash scripts its underlying DataTable (Script Data Table's
// and From Data Table's one rule)
function dataGrid(all: Record<string, unknown>[], keys: string[], cols: string[]): Grid {
  const cell = (v: unknown): Cell => {
    if (v === null || v === undefined || v === '') return { v: '', kind: 'text', text: '' };
    if (typeof v === 'number' && Number.isFinite(v)) return { v, kind: Number.isInteger(v) ? 'int' : 'dec', text: String(v) };
    if (typeof v === 'boolean') return { v: v ? 1 : 0, kind: 'bool', text: v ? 'true' : 'false' };
    const s = typeof v === 'object' ? JSON.stringify(v) : String(v);
    return { v: s, kind: 'text', text: s };
  };
  const rows = all.map(r => keys.map(k => cell(r[k])));
  return { cols, rows, num: keys.map((_, j) => rows.some(r => typeof r[j].v === 'number' && r[j].kind !== 'bool') && rows.every(r => r[j].v === '' || (typeof r[j].v === 'number' && r[j].kind !== 'bool'))) };
}
// scriptTable: CREATE TABLE and its INSERTs (the export's sqlScript) in the code viewer, in the page's engine's dialect
// (a fleet page: PostgreSQL's)
function scriptTable(t: HTMLTableElement, what: 'Script Data Table' | 'Script Grid') {
  const g = what === 'Script Grid' ? gridOf(t, false) : dataTable(t);
  const name = headingOf(t) || 'grid';
  if (!g) { line(t).textContent = `${what}: this grid holds no rows of its own to script`; return; }
  void gridMeta().then(m => {
    const e = m.engine === 'SQL Server' ? 'sqlserver' : 'postgres';
    openViewer(`${what}: ${name}`, sqlScript(g, e, { title: `${name} (${m.instance}, ${m.tab}, ${m.window})`, zone: timeZone(m.at), at: m.at.toISOString() }));
  });
}
// ---- Save Table's From items (task 7b): a write door, an administrator's opt-in -------------------------------------
// The items stay in the menu, off with the first switch that is off (the lead 11-17 01:26 / 02:17): a fleet page's
// words (savetable.ts FLEET_OFF), else the server's for the page's own instance (GET actions/save_table: doors.save_table,
// the instance's actions: list, its actions_dsn, the admin role). The state is read once per instance when the page's
// grids are drawn, so the menu (built at the right-click, no wait) has it.
let saveSt: { id: number; st?: SaveState; err?: string } | null = null;
function saveState(): SaveState | string {
  const id = parse().instance;
  if (!id) return FLEET_OFF;
  if (saveSt?.id !== id) {
    const s: { id: number; st?: SaveState; err?: string } = { id };
    saveSt = s;
    get<SaveState>('actions/save_table', { instance_id: id }).then(st => { s.st = st; }, (e: unknown) => { s.err = e instanceof Error ? e.message : String(e); });
  }
  if (saveSt.st) return saveSt.st;
  return saveSt.err ? `off: whether Save Table is on here could not be read (${saveSt.err})` : 'off: reading whether Save Table is on for this instance';
}
function saveOff(): string {
  const s = saveState();
  return typeof s === 'string' ? s : fromOff(false, s.on ? '' : s.off);
}
// saveGrid: what a From item writes - From Grid the shown rows and columns (gridOf, as Script Grid); From Data Table
// every row the page gave the grid with the DRAWN columns plus the chooser's ADDED ones (savetable.ts saveKeys: never a
// column merely offered, a '_' key or a held-back one - the lead 11-17 02:17, review-29 S8)
function saveGrid(t: HTMLTableElement, from: 'data' | 'grid'): Grid | null {
  if (from === 'grid') return gridOf(t, false);
  const m = gridModel(t);
  if (!m?.all) return null;
  const hs = heads(t), own = m.cols.filter((_, j) => !isAdded(hs[j]));
  const keys = saveKeys(own.map(c => c.key), addedOf(t, load(t)), [...neverOf(t)]);
  const label = new Map(own.map(c => [c.key, c.label ?? c.key]));
  return dataGrid(m.all(), keys, keys.map(k => label.get(k) ?? k));
}
// saveDialog: the page's own instance (named, no picker), a database of its list, the schema pgvigil_saved, the table
// name (DBA Dash's default), what will be written, the typed '<instance>/<database>' (review-29 S7); Save posts the
// grid as data (gridwriters.ts sqlWire) and says the server's words
function saveDialog(t: HTMLTableElement, from: 'data' | 'grid', back: HTMLElement | null) {
  const st = saveState();
  const what = from === 'data' ? 'From Data Table' : 'From Grid';
  if (typeof st === 'string' || !st.on) return;   // the item is off then
  const g = saveGrid(t, from);
  if (!g || !g.cols.length) { line(t).textContent = `Save Table ${what}: this grid holds no rows of its own to save`; return; }
  const wire = sqlWire(g);
  const db = el('select', { 'aria-label': 'Database' }, ...st.databases.map(n => el('option', { value: n }, n))) as HTMLSelectElement;
  const name = el('input', { type: 'text', 'aria-label': 'Table name', size: '32', autocomplete: 'off' }) as HTMLInputElement;
  name.value = defaultTable(new Date());
  const typed = el('input', { type: 'text', 'aria-label': 'Type the instance and database to save', size: '32', autocomplete: 'off' }) as HTMLInputElement;
  const want = el('code', {}, '');
  const go = el('button', { type: 'submit', disabled: '' }, 'Save') as HTMLButtonElement;
  const role = dialogRole(go, 'actions/save_table');
  const cancel = el('button', { type: 'button' }, 'Cancel');
  const msg = el('p', { class: 'meta', role: 'status' });
  const check = () => {
    want.textContent = confirmWord(st.instance, db.value);
    if (!role.why) go.disabled = !db.value || !name.value.trim() || typed.value.trim() !== confirmWord(st.instance, db.value);
  };
  for (const f of [db, name, typed]) f.addEventListener('input', check);
  db.addEventListener('change', check);
  const form = el('form', { method: 'dialog' },
    el('p', {}, `${g.rows.length} row(s) and ${g.cols.length} column(s) of this grid, written as a NEW table on ${st.instance} through its actions login; pgvigil never overwrites a table.`),
    st.databases.length ? el('p', {}, el('label', {}, 'Database ', db)) : el('p', { class: 'meta' }, 'This instance lists no database a table may go into.'),
    el('p', {}, el('label', {}, `Schema ${st.schema ?? 'pgvigil_saved'}, table `, name)),
    el('p', {}, el('label', {}, 'Type ', want, ' to save ', typed)),
    role.note, msg, el('p', {}, go, ' ', cancel));
  const d = toolDialog(t, `Save Table ${what}`, back, form);
  cancel.addEventListener('click', () => d.close());
  check();
  form.addEventListener('submit', async e => {
    e.preventDefault();
    if (role.why || go.disabled) return;   // off is off: an Enter in a field submits the form too
    go.disabled = true;
    msg.textContent = 'Saving...';
    const body = { instance_id: parse().instance, database: db.value, table: name.value.trim(), from, confirm: typed.value.trim(),
      cols: g.cols.map((c, j) => ({ name: c, type: wire.kinds[j] })), rows: wire.rows };
    try {
      const r = await post<{ outcome: string; detail: string }>(`actions/save_table?instance_id=${encodeURIComponent(String(parse().instance))}`, body);
      msg.textContent = r.detail;
    } catch (err) {
      msg.textContent = err instanceof Error ? err.message : String(err);
      check();
    }
  });
  typed.focus();
}

// barOptions: DBA Dash's data bar Options (DataBarConfig, task PGRID B14): Style, Minimum and Maximum (empty: the
// grid's own values), and a traffic light's Warning at / Critical at with Thresholds are values; OK, Cancel, Remove. A
// field that is no number is refused in words naming it, the dialog open and the bar as it was. DBA Dash's two colour
// pickers are not offered: the bars keep the theme's colours, which hold their contrast in both themes (docs/export.md).
function barOptions(t: HTMLTableElement, n: string, back: HTMLElement | null) {
  const cur = barOf(load(t).bars[n]) ?? { style: 'behind' as BarStyle };
  const style = el('select', { 'aria-label': 'Style' }, ...BAR_STYLES.map(([k, l]) => el('option', k === cur.style ? { value: k, selected: '' } : { value: k }, l))) as HTMLSelectElement;
  const field = (label: string, v: number | undefined) => { const i = el('input', { type: 'text', inputmode: 'decimal', size: '10', 'aria-label': label }) as HTMLInputElement; i.value = v === undefined ? '' : String(v); return i; };
  const min = field("Minimum (empty: the smaller of 0 and the column's lowest value)", cur.min), max = field("Maximum (empty: the column's highest value)", cur.max);
  const warn = field('Warning at (a traffic light: % of the scale, or a value)', cur.warn ?? 20), crit = field('Critical at (a traffic light: % of the scale, or a value)', cur.crit ?? 50);
  const values = el('input', { type: 'checkbox', 'aria-label': 'Thresholds are values' }) as HTMLInputElement; values.checked = !!cur.values;
  const err = el('p', { class: 'error', role: 'alert' });
  const ok = el('button', { type: 'button' }, 'OK'), cancel = el('button', { type: 'button' }, 'Cancel'), remove = el('button', { type: 'button' }, 'Remove');
  const d = toolDialog(t, `Data bar: ${n}`, back,
    el('p', {}, el('label', {}, 'Style ', style)),
    el('p', {}, el('label', {}, 'Minimum ', min), ' ', el('label', {}, 'Maximum ', max)),
    el('p', { class: 'meta' }, "Leave Minimum and Maximum empty to scale the bars to the grid's own values."),
    el('p', {}, el('label', {}, 'Warning at ', warn), ' ', el('label', {}, 'Critical at ', crit), ' ', el('label', {}, values, ' Thresholds are values, not % of the scale')),
    err, el('p', {}, ok, ' ', cancel, ' ', remove));
  const read = (i: HTMLInputElement, name: string): number | undefined | string => {
    const x = i.value.trim().replace(/,/g, '');
    if (x === '') return undefined;
    const v = Number(x);
    return Number.isFinite(v) ? v : `${name}: '${i.value.trim()}' is not a number.`;
  };
  const put = (b: Bar | null) => { const p = load(t), bs = { ...p.bars }; if (b) bs[n] = b; else delete bs[n]; save(t, { ...p, bars: bs }); redrawPanel(t); };
  ok.addEventListener('click', () => {
    const got = [read(min, 'Minimum'), read(max, 'Maximum'), read(warn, 'Warning at'), read(crit, 'Critical at')];
    const bad = got.find((x): x is string => typeof x === 'string');
    if (bad) { err.textContent = bad; return; }
    const [lo, hi, w, c] = got as (number | undefined)[];
    if (lo !== undefined && hi !== undefined && lo >= hi) { err.textContent = 'Minimum: it must be under the Maximum.'; return; }
    put(barKeep({ style: style.value as BarStyle, min: lo, max: hi, warn: w === 20 && !values.checked ? undefined : w, crit: c === 50 && !values.checked ? undefined : c, values: values.checked }));
    d.close();
  });
  cancel.addEventListener('click', () => d.close());
  remove.addEventListener('click', () => { put(null); d.close(); });
  style.focus();
}
// editFilter: DBA Dash's Edit Filter (task PGRID B11) - the filter row's fields as one text, a line per column
// (gridfilter.ts); Apply writes each line into its column's field and empties the others (a field left as it was is
// not touched: the text applied unchanged changes nothing); a text it cannot read is refused in words naming the line,
// the dialog open and the filter row as it was
function editFilter(t: HTMLTableElement, back: HTMLElement | null) {
  const ns = names(t), ins = filterInputs(t);
  const area = el('textarea', { rows: '6', cols: '64', spellcheck: 'false', 'aria-label': "The grid's filter: one line per column, its name in brackets then its conditions" }) as HTMLTextAreaElement;
  area.value = filterText(ns.map((name, j) => ({ name, filter: ins[j]?.value ?? '' })));
  const err = el('p', { class: 'error', role: 'alert' });
  const apply = el('button', { type: 'button' }, 'Apply'), cancel = el('button', { type: 'button' }, 'Cancel');
  const d = toolDialog(t, 'Edit Filter', back,
    el('p', { class: 'meta' }, 'One line per column: [name] then its conditions as the filter row takes them (="x", <>"x", >5, like "a%", in:"a","b"; several joined by \' & \'). Every line is met; an empty text clears every filter.'),
    el('p', {}, area), err, el('p', {}, apply, ' ', cancel));
  apply.addEventListener('click', () => {
    const r = readFilterText(area.value, ns);
    if (!r.ok) { err.textContent = r.why; area.focus(); return; }
    r.filters.forEach((f, j) => { if ((ins[j]?.value.trim() ?? '') !== f) setFilter(t, j, f); });
    d.close();
  });
  cancel.addEventListener('click', () => d.close());
  area.focus();
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
  // Save Table (DBA Dash's: From Data Table, From Grid, Script Data Table, Script Grid)
  const sOff = none ?? (saveOff() || undefined);
  out.push({ label: 'Save Table', sub: [{ label: 'From Data Table', off: sOff, act: () => saveDialog(t, 'data', back) },
    { label: 'From Grid', off: sOff, act: () => saveDialog(t, 'grid', back) },
    { label: 'Script Data Table', act: () => scriptTable(t, 'Script Data Table') }, { label: 'Script Grid', off: none, act: () => scriptTable(t, 'Script Grid') }] });
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
  // Row Headers (DBA Dash's: Hide, Show, Show with Row Numbers): the one in force ticked and off with its words (a click
  // there would change nothing)
  const rh = p.rownum ? 'num' : p.rowhead ? 'show' : 'hide';
  const rhs: [string, string, string][] = [['hide', 'Hide', 'the row headers are hidden now'], ['show', 'Show', 'the row headers are shown now'], ['num', 'Show with Row Numbers', 'the row numbers are shown now']];
  out.push({ sep: true, label: '' }, { label: 'Columns...', act: () => chooser(t, back) },
    { label: 'Row Headers', sub: rhs.map(([k, l, now]) => ({ label: l, checked: rh === k, off: rh === k ? now : undefined, act: then(() => save(t, { ...p, rownum: k === 'num', rowhead: k === 'show' })) })) });
  const visible = hs.filter(h => !h.hasAttribute('data-gt-hidden')).length;
  const frozen = [...t.classList].filter(c => /^gt-f\d+$/.test(c)).length;
  if (n !== undefined) {
    if (visible > 1) out.push({ label: `Hide column ${n}`, act: then(() => save(t, { ...p, hidden: [...new Set([...p.hidden, n])] })) });
    // Freeze Column (DBA Dash's, task PGRID B09): this column and every shown one before it; ticked while this column
    // is frozen, and then a click unfreezes it and every one after it (as DBA Dash's column.Frozen = false)
    const upTo = hs.slice(0, j + 1).filter(h => !h.hasAttribute('data-gt-hidden')).length, isFrozen = frozen >= upTo;
    const cannot = isFrozen ? undefined : j >= FREEZE_POS || upTo > MAX_FROZEN ? `only the first ${MAX_FROZEN} columns can be frozen`
      : upTo >= visible ? 'the last column shown is never frozen: the frozen ones stay while the rest scroll' : undefined;
    out.push({ label: 'Freeze Column', checked: isFrozen, off: cannot, act: then(() => save(t, { ...p, frozen: isFrozen ? upTo - 1 : upTo })) });
  }
  out.push({ label: 'Group By...', act: () => groupDialog(t, n ?? null, back) });
  if (frozen) out.push({ label: 'Unfreeze Column', act: then(() => save(t, { ...p, frozen: 0 })) });
  if (groupings.has(t)) out.push({ label: 'Ungroup', act: then(() => group(t, null)) });
  if (n !== undefined && hs[j].classList.contains('num')) {
    // Data bar (DBA Dash's submenu, task PGRID B14): the styles, Options..., Copy to All Numeric Columns (the look, each
    // column on its own scale), Remove, Remove All Data Bars
    const cur = barOf(p.bars[n]), st = cur?.style;
    const pick = (to: BarStyle | null) => then(() => { const bs = { ...p.bars }; if (to) bs[n] = barKeep({ ...(cur ?? {}), style: to }); else delete bs[n]; save(t, { ...p, bars: bs }); });
    const others = hs.map((h, k) => ({ h, k })).filter(x => x.k !== j && x.h.classList.contains('num') && !x.h.hasAttribute('data-gt-hidden'));
    const anyBar = Object.keys(p.bars).some(b => ns.includes(b));
    out.push({ label: 'Data bar', sub: [...BAR_STYLES.map(([k, l]) => ({ label: l, checked: st === k, act: pick(k) })),
      { label: 'Options...', act: () => barOptions(t, n, back) },
      { label: 'Copy to All Numeric Columns', off: !cur ? `no data bar on ${n}` : !others.length ? 'no other number column is shown' : undefined,
        act: then(() => { const bs = { ...p.bars }; for (const x of others) bs[ns[x.k]] = barKeep({ style: cur!.style, warn: cur!.warn, crit: cur!.crit, values: cur!.values }); save(t, { ...p, bars: bs }); }) },
      { label: 'Remove', off: st ? undefined : `no data bar on ${n}`, act: pick(null) },
      { label: 'Remove All Data Bars', off: anyBar ? undefined : 'no data bar on this grid', act: then(() => save(t, { ...p, bars: {} })) }] });
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
  if (filterable(t)) out.push({ label: 'Edit Filter', act: () => editFilter(t, back) });
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
    + 'table.grid.gt-rowhead > tbody > tr:not(.trend-row)::before,table.grid.gt-rowhead > thead > tr::before{content:"";display:table-cell;padding:.2rem .5rem;background:var(--line)}'
    + 'table.grid.gt-rownum > tbody{counter-reset:gtrow}table.grid.gt-rownum > tbody > tr:not(.trend-row){counter-increment:gtrow}'
    + 'table.grid.gt-rownum > tbody > tr:not(.trend-row)::before{content:counter(gtrow);display:table-cell;padding:.2rem .5rem;color:var(--muted);text-align:right;font-variant-numeric:tabular-nums}'
    + 'table.grid.gt-rownum > thead > tr::before{content:"";display:table-cell}table.grid.gt-rownum > thead > tr:first-child::before{content:"#";color:var(--muted);padding:.2rem .5rem}'
    + '.gt-dialog{max-width:min(90vw,70rem);background:var(--card);color:var(--fg);border:1px solid var(--line)}.gt-dialog .gt-scroll{max-height:60vh}'
    + '.gt-stats:empty{display:none}.gt-stats{margin:.2rem 0}'
    + '.gt-panel,.gt-groups{border:1px solid var(--line);background:var(--card);color:var(--fg);padding:.5rem .8rem;margin:.3rem 0}'
    + '.gt-panel p,.gt-groups p{margin:.3rem 0}.gt-cols{display:grid;grid-template-columns:repeat(auto-fill,minmax(16rem,1fr));gap:.1rem 1rem;max-height:16rem;overflow:auto}'
    + '.gt-panel input[type=number]{width:4rem}.gt-scroll{overflow:auto;max-height:18rem}'
    + '.gt-col[aria-selected=true]{background:var(--sel,rgba(80,140,230,.22))}.gt-cols:focus-visible .gt-col.gt-act{outline:2px solid var(--fg);outline-offset:-2px}.gt-cols:focus-visible{outline:2px solid var(--line)}'
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
    saveState();   // the From items' state for the page's own instance, read before the first right-click
    const ts = [...due];
    due.clear();
    for (const t of ts) {
      if (!t.isConnected) continue;
      apply(t);
      const k = keyOf(t), g = groupings.get(t)?.spec ?? keptGroups.get(k);
      if (g) group(t, g);
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
    items.push(...d.extra.map(([label, act]) => ({ label, act })));   // a page's own lines, after the tools'
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
