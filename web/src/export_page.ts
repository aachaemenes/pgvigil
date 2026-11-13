// The page sheet: sheet 1 of the bar's workbook, the page as it shows it, top to bottom (the design lines E2-1' to
// E2-14', notes/teams/pdfp-relw2c-s2-report.md): the title rows, then every block of #main the page shows, in page
// order - a heading, a line of text (a note, a meta line, the header strip's top line), a grid with the rows it draws
// (at most GRID_PAGE) and its 'The first 200 of n rows' line pointing at the grid's own sheet, a property card, cards
// side by side (tiles, the header strip's chips, the health calendar's days: one column each), a closed disclosure's
// line ('closed on the page; its rows on sheet <name>'), a chart's line (its picture: the next step). Each cell takes
// the colour the page's own CSS gives it and its marks (export_colours.ts), interaction states excluded. Blocks the
// page sets side by side (two charts, a card beside a grid) are stacked, and a line says so.
// A block the page does not show (display none, visibility hidden, a visually-hidden note, a closed disclosure's
// content) is not on this sheet; a grid in it keeps its own sheet (export.ts walk).
import type { Cell, Look, Meta, Section } from './export';
import { cellWords, chartSection, headingText, textPx, timeZone, typed } from './export';
import { pictureOf, pngBytes, SCALE, svgSource, themeColours } from './export_chart';
import type { PictureBox } from './export_chart';
import type { Placed } from './export_chart';
import { stamp } from './tz';
import { borderLeftOf, hex, paintOf, parseColour, textLook } from './export_colours';
import { gridModel } from './ui';

export interface PageSheet { name: string; rows: Cell[][]; widths: number[]; freeze: number; pictures: Placed[]; charts: Section[] }   // charts: each picture's numbers, the sheets after the grids'

const flat = (s: string | null | undefined) => (s ?? '').replace(/\s+/g, ' ').trim();
const CONTROL = 'button, input, select, textarea, label, nav, form, [role=tablist], [role=toolbar], .seg, .subtabs, .filter-btn, .whatis, .chart-menu, .toolbar';

// seen: whether the page shows e (the browser's own answer first: a closed disclosure's content, visibility, opacity 0),
// 'contents' for a box that is only its children
function seen(e: Element): 'no' | 'yes' | 'contents' {
  const cs = getComputedStyle(e);
  if (cs.display === 'none') return 'no';
  if (cs.display === 'contents') return 'contents';
  if (e.checkVisibility && !e.checkVisibility({ opacityProperty: true, visibilityProperty: true, contentVisibilityAuto: true })) return 'no';
  if (cs.visibility !== 'visible' || Number(cs.opacity) === 0) return 'no';
  const r = e.getBoundingClientRect();
  if ((r.width <= 1 && r.height <= 1) || (r.width === 0 && r.height === 0)) return 'no';
  return 'yes';
}

// ---- a cell's look: the page's CSS for the cell and its marks ------------------------------------------------
const BADGE = '.badge';
// a chart legend's colour square (a .swatch: an empty span painted only by its background) is carried as a '■' run in
// its colour before its words, as a .dot is a '●' (a colour is never the only carrier: its name follows it); the
// swatch is painted inline at draw time in the screen theme's colour, so it is mapped to the light theme's as the
// chart's own picture is (svgSource); toLight is set by pageSheet for its run
const SWATCH = '.swatch';
let toLight = (c: string): string => c;
function lightOf(screen: string[]): (c: string) => string {
  const light = themeColours(), key = (s: string | undefined) => { const q = parseColour(s); return q ? hex(q) : ''; };
  const map = new Map(screen.map((s, i) => [key(s), key(light[i])] as [string, string]).filter(([a, b]) => a && b && a !== b));
  return c => map.get(c) ?? c;
}
// markOf: a dot's or a swatch's glyph and colour (a swatch's in the light theme)
function markOf(x: Element, base: Element): { glyph: string; color: string } {
  const q = paintOf(x, base), sw = x.matches(SWATCH);
  return { glyph: sw ? '■ ' : '● ', color: sw ? toLight(q.fill ?? q.text) : q.fill ?? q.text };
}
// pageLines: the lines the page draws an element's words on - its text nodes' own line boxes, grouped by their place
// (a td's box is as tall as its row, so its height says nothing of its words)
export function pageLines(e: Element): number {
  const doc = e.ownerDocument, w = doc.createTreeWalker(e, 4);   // NodeFilter.SHOW_TEXT
  const rs: DOMRect[] = [];
  for (let n = w.nextNode(); n; n = w.nextNode()) {
    if (!n.textContent?.trim()) continue;
    const r = doc.createRange(); r.selectNodeContents(n);
    rs.push(...[...r.getClientRects()].filter(x => x.width > 0 && x.height > 0));
  }
  rs.sort((a, b) => a.top - b.top);
  let lines = 0, bottom = -Infinity;
  for (const x of rs) if (x.top >= bottom - 2) { lines++; bottom = x.bottom; } else bottom = Math.max(bottom, x.bottom);
  return lines;
}
// firstText: the element holding the first words the cell shows (the one the eye reads), the cell itself when its own
// text comes first
function firstText(td: Element): Element {
  const w = td.ownerDocument.createTreeWalker(td, NodeFilter.SHOW_TEXT);
  for (let n = w.nextNode(); n; n = w.nextNode()) {
    const p = n.parentElement;
    if (!p || !flat(n.textContent)) continue;
    if (p.closest(CONTROL) && p.closest(CONTROL) !== td && td.contains(p.closest(CONTROL))) continue;
    return p;
  }
  return td;
}
// shape: the cell's structure without its words (each element's tag, class and inline style) and its row's class: two
// cells of one table with the same shape get the same colours from the page's CSS (app.css has no rule on an
// attribute's value other than these, no :nth-child on rows), so one read serves both
function shape(td: Element): string {
  let k = (td.parentElement?.className ?? '') + '\u0001' + td.className + '{' + (td.getAttribute('style') ?? '') + '}';
  for (const x of td.querySelectorAll('*')) k += x.tagName + '.' + x.className + '{' + (x.getAttribute('style') ?? '') + '}';
  return k;
}
export type LookCache = Map<string, CellLook>;
export interface CellLook { look: Look; dot?: { color: string; name: string; glyph?: string } }
// cellLook: a grid cell's fill, text colour, weight and underline (E2-4', E2-5'): the cell's own fill; else the fill of a
// badge or pill in it (the whole cell takes the badge's tint and its text colour, bold as the badge is); the text colour
// of the element whose words come first; a dot's colour and name (a rich-text run before the cell's words)
export function cellLook(td: Element, table: Element, cache?: LookCache): CellLook {
  const key = cache ? shape(td) : '';
  const hit = cache?.get(key);
  if (hit) return hit;
  const p = paintOf(td, table);
  const look: Look = {};
  const b = td.querySelector(BADGE);
  if (!p.fill && b && seen(b) === 'yes') {
    const q = paintOf(b, table);
    look.fill = q.fill; look.color = q.text;
    if (textLook(b, td).bold) look.bold = true;
  } else {
    look.fill = p.fill;
    const r = firstText(td);
    const l = textLook(r, td);
    look.color = r === td ? p.text : paintOf(r, table).text;
    if (l.bold) look.bold = true;
    if (l.underline) look.underline = true;
  }
  if (!look.fill) delete look.fill;
  const d = td.querySelector('.dot, ' + SWATCH);
  let dot: CellLook['dot'];
  if (d && seen(d) === 'yes') {
    const q = markOf(d, table);
    dot = { color: q.color, name: d.matches(SWATCH) ? '' : flat(d.getAttribute('aria-label') || d.getAttribute('title') || ''), ...(d.matches(SWATCH) ? { glyph: q.glyph } : {}) };
  }
  const out = { look, ...(dot ? { dot } : {}) };
  cache?.set(key, out);
  return out;
}
// headLook: a header cell's look (the page's th: its fill, white text, its weight), wrapped when the page wraps it, in the
// middle of its row as the page sets it (app.css '.grid > thead th' vertical-align: middle)
export function headLook(th: Element, table: Element): Look {
  const p = paintOf(th, table), l = textLook(th.querySelector('.th-label') ?? th, th);
  return { ...(p.fill ? { fill: p.fill } : {}), color: p.text, ...(l.bold ? { bold: true } : {}), ...(pageLines(th.querySelector('.th-label') ?? th) > 1 ? { wrap: true } : {}), valign: 'middle' };
}
// gridHeadLook: the look the page gives a grid's header cell, for a sheet whose header row is the export's own (a
// property card's 'item | value': the page draws no header over a card): a probe header in the page, read and removed
// in the same task
export function gridHeadLook(root: Element): Look {
  const t = root.ownerDocument.createElement('table');
  t.className = 'grid'; t.setAttribute('aria-hidden', 'true');
  t.innerHTML = '<thead><tr><th><span class="th-label">x</span></th></tr></thead>';
  const wrap = root.ownerDocument.createElement('div');
  wrap.className = 'grid-wrap'; wrap.style.cssText = 'position: fixed; left: -100000px; top: 0; visibility: hidden';
  wrap.append(t); root.append(wrap);
  try { return headLook(t.querySelector('th')!, t); } finally { wrap.remove(); }
}
// withDot: a text cell's words after the dot's '●' in the dot's colour; a dot with no word beside it adds its name (a
// colour is never the only carrier of a state, WCAG 1.4.1); a number keeps its number and leaves the dot out
export function withDot(c: Cell, l: CellLook): Cell {
  if (!l.dot || typeof c.v === 'number') return c;
  const words = c.v === '' ? l.dot.name : c.v, g = l.dot.glyph ?? '● ';
  return { ...c, v: g + words, text: c.text || words, runs: [{ text: g, color: l.dot.color }, { text: words, color: c.look?.color, bold: c.look?.bold }] };
}

// badgeCell: a badge or pill as a cell of its own: its tint, its text colour, its weight
function badgeCell(x: Element, base: Element): Cell {
  const q = paintOf(x, base), l = textLook(x, x), t = flat(x.textContent);
  return { v: t, kind: 'text', text: t, look: { ...(q.fill ? { fill: q.fill } : {}), color: q.text, ...(l.bold ? { bold: true } : {}) } };
}

// ---- a line of text: runs of words in their colours, a badge its own cell ------------------------------------
interface Run { text: string; color?: string; bold?: boolean; italic?: boolean; underline?: boolean; pt?: number }
function lineCells(e: Element, base: Element): Cell[] {
  const out: Cell[] = [];
  let runs: Run[] = [];
  const close = () => {
    const t = flat(runs.map(r => r.text).join(''));
    if (t) {
      const r0 = runs.find(r => flat(r.text)) ?? runs[0];
      const same = runs.every(r => !flat(r.text) || (r.color === r0.color && !!r.bold === !!r0.bold && !!r.underline === !!r0.underline));
      const look: Look = { color: r0.color, ...(r0.bold ? { bold: true } : {}), ...(r0.italic ? { italic: true } : {}), ...(r0.underline ? { underline: true } : {}), ...(r0.pt ? { pt: r0.pt } : {}) };
      const trimmed = runs.map((r, i) => ({ ...r, text: i === 0 ? r.text.replace(/^\s+/, '') : r.text })).filter(r => r.text);
      if (trimmed.length) trimmed[trimmed.length - 1].text = trimmed[trimmed.length - 1].text.replace(/\s+$/, '');
      out.push({ v: t, kind: 'text', text: t, look, ...(same ? {} : { runs: trimmed.map(r => ({ ...r, text: r.text.replace(/\s+/g, ' ') })) }) });
    }
    runs = [];
  };
  let mark = false;   // the run before is a swatch's '■ ': the page's space after it is that run's
  const visit = (n: Node) => {
    if (n.nodeType === 3) {
      const p = n.parentElement!;
      const s0 = (n.textContent ?? '').replace(/\s+/g, ' '), s = mark ? s0.replace(/^ /, '') : s0;
      mark = false;
      if (!s) return;
      const l = textLook(p, e);
      runs.push({ text: s, color: paintOf(p, base).text, ...(l.bold ? { bold: true } : {}), ...(l.italic ? { italic: true } : {}), ...(l.underline ? { underline: true } : {}), ...(l.pt ? { pt: l.pt } : {}) });
      return;
    }
    if (n.nodeType !== 1) return;
    const x = n as Element;
    if (x !== e && (x.matches(CONTROL) || seen(x) === 'no')) return;
    if (x !== e && x.matches(BADGE)) {
      close();
      const c = badgeCell(x, base);
      if (c.text) out.push(c);
      return;
    }
    if (x !== e && x.matches(SWATCH)) {
      const q = markOf(x, base);
      runs.push({ text: q.glyph, color: q.color });
      mark = true;
      return;
    }
    if (x !== e && x.matches('.dot')) {
      const q = paintOf(x, base);
      runs.push({ text: '● ', color: q.fill ?? q.text });
      const name = flat(x.getAttribute('aria-label') || x.getAttribute('title') || '');
      // a dot with no word after it in this line: its name
      if (name && !flat(x.nextSibling?.textContent ?? '') && !x.nextElementSibling) runs.push({ text: name + ' ', color: paintOf(e, base).text });
      return;
    }
    for (const c of x.childNodes) visit(c);
  };
  visit(e);
  close();
  // a line drawn with a stripe at its left (a 'Needs attention' row): the stripe on its first cell
  const stripe = borderLeftOf(e);
  if (stripe && out[0]) out[0] = { ...out[0], look: { ...out[0].look, border: stripe } };
  return out;
}

// the platform as the page's Admin words it (admin_instances.ts platOpts); a key that only names the engine, or 'auto',
// is no platform word
const PLATFORM: Record<string, string> = { onprem: 'on premises', rds: 'Amazon RDS', aurora: 'Aurora', azure: 'Azure', cloudsql: 'Cloud SQL',
  alloydb: 'AlloyDB', azuresqldb: 'Azure SQL Database', azuresqlmi: 'Azure SQL Managed Instance' };
export const platformWords = (key: string | undefined): string | undefined => key ? PLATFORM[key] : undefined;

// measured: the pixels a cell's words take in the file's font (Calibri 11 at its size; export.ts textPx), with the
// cell's padding: the width a line of words needs, or the width each wrapped line has
export const measured = (t: string, bold: boolean, pt = 11): number => 1.0738 * textPx(t, bold, false) * pt / 11 + 6;
const colPx = (w: number | undefined) => Math.round((w && w > 0 ? w : 8.43) * 7) + 5;   // 0: no width set, Excel's 8.43
// flow: a line's cells laid left to right as the page sets them, each from the first column past the end of the one
// before (its words measured), so a badge never cuts the words before it; the last runs over the empty cells after it
function flow(row: Cell[], widths: number[]): Cell[] {
  const out: (Cell | undefined)[] = [];
  let col = 0;
  row.forEach((c, k) => {
    out[col] = c;
    if (k === row.length - 1) return;
    const t = c.runs ? c.runs.map(r => r.text).join('') : String(c.v);
    let need = measured(t, !!c.look?.bold, c.look?.pt), j = col;
    while (need > 0) { need -= colPx(widths[j]); j++; }
    col = Math.max(j, col + 1);
  });
  return Array.from(out) as Cell[];
}

// ---- the walk ----------------------------------------------------------------------------------------------
interface Block { rows: Cell[][]; rect: DOMRect; grid?: { th: number[] }; flow?: boolean; cards?: number[]; label?: number; table?: boolean; pic?: Omit<Placed, 'row' | 'col'> }
const txt = (v: string, look: Look = {}): Cell => ({ v, kind: 'text', text: v, look });

// pageSheet: the page sheet of #main (root), for the grids `grids` (export.ts walk's elements, in sheet order:
// sheet k + 2 is grids[k]); a jump to grid k is the cell's `jump`, a closed disclosure's line names its grids' sheets
// by `sheets` (export.ts resolves both once the sheets are named)
// screen: the chart colours under the screen's theme (export_chart.ts themeColours), read before the light theme is set
export function pageSheet(root: Element, m: Meta, grids: Element[], cache = new Map<Element, LookCache>(), screen: string[] = []): PageSheet {
  toLight = screen.length ? lightOf(screen) : (c: string) => c;
  try { return sheetOf(root, m, grids, cache, screen); } finally { toLight = (c: string) => c; }
}
function sheetOf(root: Element, m: Meta, grids: Element[], cache: Map<Element, LookCache>, screen: string[]): PageSheet {
  const blocks: Block[] = [];
  const charts: Section[] = [];
  let pics = 0;   // the SVG charts' pictures (a uPlot chart's count is its numbers sheet's)
  const muted = (e: Element) => paintOf(e, root).text;
  // the page's muted text colour (--text-muted), read from a probe in the page and removed in the same task
  const probe = root.ownerDocument.createElement('span');
  probe.style.color = 'var(--text-muted)'; probe.textContent = 'x'; root.append(probe);
  const quiet = paintOf(probe, root).text; probe.remove();

  const indexOf = (g: Element) => { const k = grids.indexOf(g); return k >= 0 ? k : undefined; };
  const lookCache = (t: Element) => { let c = cache.get(t); if (!c) { c = new Map(); cache.set(t, c); } return c; };

  const gridBlock = (t: HTMLTableElement) => {
    const ths = [...t.querySelectorAll(':scope > thead > tr:first-child > th')];
    const keep = ths.map(th => !th.hasAttribute('data-gt-hidden') && seen(th) !== 'no');
    const head = ths.filter((_, j) => keep[j]).map(th => ({ v: headingText(th), kind: 'text' as const, text: headingText(th), look: headLook(th, t) }));
    const model = gridModel(t), data = model?.rows(), cols = model?.cols;
    const trs = [...t.querySelectorAll<HTMLTableRowElement>(':scope > tbody > tr')].filter(tr => !tr.classList.contains('trend-row'));
    const lc = lookCache(t);
    const rows = trs.filter(tr => seen(tr) !== 'no').map(tr => {
      const i = trs.indexOf(tr);
      return [...tr.children].filter((_, j) => keep[j] ?? true).map(td => {
        const j = [...tr.children].indexOf(td);
        const words = cellWords(td);
        const raw = data && cols && cols.length === ths.length && i < data.length ? data[i][cols[j].key] : undefined;
        const ty = raw !== undefined ? typed(raw, words) : { v: words, kind: 'text' as const };
        // the page sheet is the view: a count or a decimal stays a number, every other kind is the words the page
        // shows (a size, a time, a duration, a share as their text; their formats are the next step)
        const v: Cell = ty.kind === 'int' || ty.kind === 'dec' ? { v: ty.v, kind: ty.kind, text: words } : { v: words, kind: 'text', text: words };
        const l = cellLook(td, t, lc);
        // a cell the page shows on more than one line wraps on the sheet too (its row as tall as its lines)
        return withDot({ ...v, look: pageLines(td) > 1 ? { ...l.look, wrap: true } : l.look }, l);
      });
    });
    const out: Cell[][] = [head, ...rows];
    // the page's 'The first 200 of n rows' line under the grid: its words, and the grid's own sheet to go to
    const more = t.closest('.grid-box')?.querySelector(':scope > .grid-more');
    const k = indexOf(t);
    if (more && seen(more) === 'yes') {
      const w = flat([...more.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join(' '));
      out.push([{ ...txt(w + (k !== undefined ? ' Every row: sheet {sheet}' : ''), { color: muted(more), underline: k !== undefined }), ...(k !== undefined ? { jump: k } : {}) }]);
    }
    return { rows: out, th: ths.filter((_, j) => keep[j]).map(th => th.getBoundingClientRect().width) };
  };
  const emptyGridBlock = (t: Element) => {
    const ths = [...t.querySelectorAll('th')];
    return { rows: [ths.map(th => ({ v: headingText(th), kind: 'text' as const, text: headingText(th), look: headLook(th, t) }))], th: ths.map(th => th.getBoundingClientRect().width) };
  };
  const propsBlock = (t: Element): Cell[][] => [...t.querySelectorAll('tr')].filter(tr => seen(tr) !== 'no').map(tr => {
    const th = tr.querySelector('th'), td = tr.querySelector('td');
    const cell = (x: Element | null) => {
      if (!x) return txt('');
      const l = cellLook(x, t), w = cellWords(x);
      return withDot({ ...txt(w), look: pageLines(x) > 1 ? { ...l.look, wrap: true } : l.look }, l);
    };
    return [cell(th), cell(td)];
  });
  const tableBlock = (t: Element): Cell[][] => [...t.querySelectorAll('tr')].filter(tr => seen(tr) !== 'no').map(tr =>
    [...tr.children].map(c => { const l = cellLook(c, t); return withDot({ ...txt(cellWords(c)), look: c.tagName === 'TH' ? { ...l.look, bold: true } : l.look }, l); }));
  // cards: items side by side (tiles, chips, the calendar's days), rows of them by their place on the page; each card a
  // column, its lines top to bottom as the page draws them, each with the card's fill and its left stripe
  let cardW: number[] = [];   // the last cards block's page widths per column (characters)
  const cardsBlock = (items: Element[]): Cell[][] => {
    cardW = [];
    const vis = items.filter(x => seen(x) === 'yes').map(x => ({ x, r: x.getBoundingClientRect() }));
    const bands: { top: number; items: typeof vis }[] = [];
    for (const it of vis.sort((a, b) => a.r.top - b.r.top || a.r.left - b.r.left)) {
      const band = bands.find(b => Math.abs(b.top - it.r.top) < 8);
      if (band) band.items.push(it); else bands.push({ top: it.r.top, items: [it] });
    }
    const out: Cell[][] = [];
    for (const band of bands) {
      const cols = band.items.sort((a, b) => a.r.left - b.r.left).map(({ x, r }, j) => {
        cardW[j] = Math.max(cardW[j] ?? 0, Math.min(40, Math.max(12, Math.round(r.width / 7 * 100) / 100)));
        const card = paintOf(x, x.parentElement), stripe = borderLeftOf(x);
        const frame: Look = { ...(card.fill ? { fill: card.fill } : {}), ...(stripe ? { border: stripe } : {}) };
        const parts = [...x.children].filter(c => seen(c) === 'yes' && !c.matches(CONTROL)).map(c => ({ c, r: c.getBoundingClientRect() }))
          .sort((a, b) => a.r.top - b.r.top || a.r.left - b.r.left);
        const lines: Cell[] = [];
        if (!parts.length) { const w = flat(x.textContent); lines.push({ ...txt(w), look: { ...frame, color: card.text, ...(pageLines(x) > 1 ? { wrap: true } : {}) } }); }
        for (const { c } of parts) {
          const cs = c.matches(BADGE) ? [badgeCell(c, x)] : lineCells(c, x);
          const wraps = !c.matches(BADGE) && pageLines(c) > 1;
          // a line's badge (a tile's pill) keeps its tint; its words keep their colour, size and weight, on the card's fill
          for (const one of cs) lines.push({ ...one, look: { ...frame, ...one.look, fill: one.look?.fill ?? frame.fill, border: stripe, ...(wraps ? { wrap: true } : {}) } });
        }
        return lines;
      });
      const h = Math.max(...cols.map(c => c.length));
      for (let i = 0; i < h; i++) out.push(cols.map(c => c[i] ?? { ...txt(''), look: c.length ? { fill: c[0].look?.fill, border: c[0].look?.border } : {} }));
    }
    return out;
  };

  const add = (e: Element, rows: Cell[][], grid?: { th: number[] }, more: Partial<Block> = {}) => { if (rows.length) blocks.push({ rows, rect: e.getBoundingClientRect(), ...(grid ? { grid } : {}), ...more }); };
  const line = (e: Element, rows: Cell[][]) => add(e, rows, undefined, { flow: true });
  const visit = (e: Element): void => {
    const s = seen(e);
    if (s === 'no') return;
    if (s === 'contents') { for (const c of e.children) visit(c); return; }
    if (e.matches(CONTROL)) return;
    if (e.tagName === 'DETAILS') {
      const sum = e.querySelector(':scope > summary');
      const line = sum ? lineCells(sum, root) : [];
      if (!(e as HTMLDetailsElement).open) {
        const ks = [...e.querySelectorAll('table.grid, p.empty[data-cols]')].map(indexOf).filter((k): k is number => k !== undefined);
        line.push({ ...txt(ks.length ? `(closed on the page; its rows on sheet ${ks.map(k => `{sheet:${k}}`).join(', ')})` : '(closed on the page)', { color: quiet, italic: true }), ...(ks.length ? { jump: ks[0], sheets: ks } : {}) });
        add(e, [line], undefined, { flow: true });
        return;
      }
      add(sum ?? e, [line], undefined, { flow: true });
      for (const c of e.children) if (c !== sum) visit(c);
      return;
    }
    if (e.matches('.chart')) {
      // the chart's title as the page words it, without its buttons, its menu's status words or its select
      const h = e.querySelector('h3, h4'), hc = h?.cloneNode(true) as Element | undefined;
      hc?.querySelectorAll('button, select, .chart-note, .whatis, .filter-btn').forEach(b => b.remove());
      const title = hc ? flat(hc.textContent) : flat(e.textContent).slice(0, 80);
      const head = txt(`Chart: ${title}`, { color: paintOf(h ?? e, root).text, bold: true });
      // the chart drawn again (export_chart.ts): its picture under its line, as wide as the chart on the page, the rows
      // under it kept for its height (15 pt each), its numbers on a sheet of their own after the grids'
      const rest = (plot: Element) => { for (const c of e.children) if (c !== h && c !== plot && !c.contains(plot)) visit(c); };   // its notes, its legend
      const pic = pictureOf(e), d = pic?.draw(SCALE);
      if (pic && d) {
        const k = grids.length + charts.length;
        charts.push(chartSection(title, pic.numbers()));
        const span = pic.first !== undefined && pic.last !== undefined ? `; ${stamp(new Date(pic.first))} to ${stamp(new Date(pic.last))}` : '';
        const descr = `${title}: ${pic.series().join(', ')}${span}; numbers on sheet {sheet:${k}}`;
        const n = Math.ceil(d.h * 0.75 / 15);
        add(e, [[head, { ...txt('(its numbers: sheet {sheet})', { color: quiet, italic: true, underline: true }), jump: k }], ...Array.from({ length: n }, (): Cell[] => [])],
          undefined, { flow: true, pic: { png: pngBytes(d.png), w: d.w, h: d.h, name: `Chart ${charts.length + pics}: ${title}`, descr } });
        const plot = e.querySelector('.uplot');
        if (plot) rest(plot);
        return;
      }
      // a chart the page draws as an SVG of its own (SQL Server Waits' bars, the rings): the SVG as its picture, its
      // numbers the grid of the page's 'numbers as a table' after it (E2-8: one, not two), its legend and notes after
      const sv = e.querySelector<SVGSVGElement>('svg[role=img]');
      if (sv && seen(sv) !== 'no' && sv.getBoundingClientRect().width > 0) {
        const s = svgSource(sv, screen.length ? screen : themeColours(), themeColours());
        let tab: Element | null = null;
        for (let a: Element | null = e; a && a !== root && !tab; a = a.parentElement) {
          const nx = a.nextElementSibling;
          if (nx?.tagName === 'DETAILS' && /numbers as a table/.test(nx.querySelector('summary')?.textContent ?? '')) tab = nx.querySelector('table.grid, p.empty[data-cols]');
        }
        const nf = (e as PictureBox).pgvNumbers;
        if (!tab && nf) charts.push(chartSection(title, nf()));
        const k = tab ? indexOf(tab) : nf ? grids.length + charts.length - 1 : undefined;
        const series = [...e.querySelectorAll('.swatch')].map(sw => flat(sw.nextSibling?.textContent)).filter(Boolean);
        const descr = `${title}${series.length ? ': ' + series.join(', ') : ''}${k !== undefined ? `; numbers on sheet {sheet:${k}}` : ''}`;
        const n = Math.ceil(s.h * 0.75 / 15);
        pics++;
        add(e, [[head, ...(k !== undefined ? [{ ...txt('(its numbers: sheet {sheet})', { color: quiet, italic: true, underline: true }), jump: k }] : [])], ...Array.from({ length: n }, (): Cell[] => [])],
          undefined, { flow: true, pic: { png: new Uint8Array(0), svg: { src: s.src, bg: getComputedStyle(root.ownerDocument.documentElement).getPropertyValue('--card').trim() || '#ffffff' }, w: s.w, h: s.h, name: `Chart ${charts.length + pics}: ${title}`, descr } });
        // its legend and notes: the ring keeps its legend table beside the SVG in one box, so the walk goes into a box
        // that holds the SVG (never the SVG itself)
        const into = (p: Element) => { for (const c of p.children) { if (c === h || c === sv) continue; if (c.contains(sv)) into(c); else visit(c); } };
        into(e);
        return;
      }
      // a chart the page draws in HTML (the Drives page's volume bars: a table): its line, then its content as any block
      if (!e.querySelector('.uplot, svg, canvas, .chart-state') && e.querySelector('table')) { line(e, [[head]]); for (const c of e.children) if (c !== h) visit(c); return; }
      // no picture: the page's own words in the chart's place (one read, no data), else why
      const st = e.querySelector('.chart-state');
      line(e, [[head, txt(st ? flat(st.textContent) : e.querySelector('.uplot') ? '(no picture: this build cannot draw it again; its numbers: the chart\'s menu, Export Excel)' : '(not drawn when exported)', { color: quiet, italic: true })]]);
      return;
    }
    if (e.matches('.grid-more')) return;   // its grid writes it, with the grid's sheet to go to
    if (/^H[1-6]$/.test(e.tagName)) { line(e, [lineCells(e, root)]); return; }
    if (e.matches('table.grid')) { const g = gridBlock(e as HTMLTableElement); add(e, g.rows, { th: g.th }); return; }
    if (e.matches('table.grid-empty')) { const g = emptyGridBlock(e); add(e, g.rows, { th: g.th }); return; }
    if (e.matches('table.props')) {
      // a property card's label column: as wide as its longest label (cap 40)
      const rows = propsBlock(e);
      const lw = Math.max(0, ...rows.map(r => r[0] ? measured(String(r[0].v), !!r[0].look?.bold) : 0));
      add(e, rows, undefined, { label: Math.min(40, Math.round((lw + 2) / 7 * 100) / 100) });
      return;
    }
    if (e.tagName === 'TABLE') { add(e, tableBlock(e), undefined, { table: true }); return; }
    // a row of tiles or chips: cards side by side (the tile wall, a heading over rows of tiles, is walked into)
    if (e.matches('.tiles, .chips')) { const cr = cardsBlock([...e.children]); add(e, cr, undefined, { cards: cardW }); return; }
    if (e.matches('.tile, .chip')) { const cr = cardsBlock([e]); add(e, cr, undefined, { cards: cardW }); return; }
    if (e.matches('.healthcal-grid')) { const cr = cardsBlock([...e.children]); add(e, cr, undefined, { cards: cardW }); return; }
    if (e.matches('canvas, svg, figure, img, .u-wrap')) { add(e, [[txt('Picture (the next step)', { color: quiet, italic: true })]]); return; }
    if (e.matches('ul, ol')) { line(e, [...e.children].filter(li => seen(li) === 'yes').map(li => lineCells(li, root))); return; }
    // a block whose content is words and inline marks only (no block of its own inside): one line
    const blockKids = [...e.children].filter(c => seen(c) !== 'no' && !c.matches(CONTROL) && !['inline', 'inline-block', 'inline-flex'].includes(getComputedStyle(c).display) && !c.matches(BADGE + ', .dot, a, span, b, strong, em, code, abbr, time'));
    if (!blockKids.length) { const cs = lineCells(e, root); if (cs.length) line(e, [cs]); return; }
    // words of its own beside its blocks: a line of those words first (the rest follows as blocks)
    const own = flat([...e.childNodes].filter(n => n.nodeType === 3).map(n => n.textContent).join(' '));
    if (own) add(e, [[txt(own, { color: paintOf(e, root).text })]]);
    for (const c of e.children) visit(c);
  };
  for (const c of root.children) visit(c);

  // the title rows (E2-3), then the blocks; a block the page sets beside the one before it is stacked under it, said
  const at = (d: Date) => stamp(d);
  // row 2, the scope: the engine, the platform and the header strip's word (its own tint) on an instance's page
  const word = root.querySelector('.inst-header .band-word');
  const pw = platformWords(m.platform);
  const scope: Cell[] = m.engine ? [txt(m.engine), ...(pw ? [txt(pw)] : []), ...(word && seen(word) === 'yes' ? [badgeCell(word, root)] : [])]
    : [txt(m.instance === 'fleet' ? 'Fleet' : m.instance)];
  const rows: Cell[][] = [
    [txt(`${m.tab} - ${m.instance}`, { bold: true, pt: 14 })],
    scope,
    [txt(`Window ${m.window} (${at(m.from)} - ${at(m.to)}); exported ${at(m.at)}, ${timeZone(m.at)}; colours as the page showed them. This sheet is the view of the page; compute on the grid sheets after it, which are also the tables to read with assistive technology.`, { color: quiet })],
    [],
  ];
  // the widths: a grid's columns from its header cells' page widths (cap 40); a property card's label column as wide as
  // its longest label; the columns no grid reaches from the cards' own page widths (min 12, cap 40)
  const widths: number[] = [];
  for (const b of blocks) if (b.grid) b.grid.th.forEach((px, j) => { widths[j] = Math.max(widths[j] ?? 0, Math.min(40, Math.round(px / 7 * 100) / 100)); });
  const gridCols = widths.length;
  for (const b of blocks) if (b.label) widths[0] = Math.max(widths[0] ?? 0, b.label);
  for (const b of blocks) if (b.cards) b.cards.forEach((w, j) => { if (j >= gridCols) widths[j] = Math.max(widths[j] ?? 0, w); });
  for (let j = 0; j < widths.length; j++) if (widths[j] === undefined) widths[j] = 0;
  // a grid's, a property card's, a card's or a plain table's (a ring's legend) words wider than their column at these
  // widths wrap when a cell with words or a fill is to their right on the row (else it would cut them); with nothing to
  // their right they run over the empty cells as the page's one line does (E2 1b, b1): only the page's own wrap wraps them
  const something = (c: Cell | undefined) => !!c && (String(c.v) !== '' || !!c.look?.fill || !!c.look?.border);
  for (const b of blocks) if (b.grid || b.label !== undefined || b.cards || b.table) for (const r of b.rows) r.forEach((c, j) => {
    if (!c || typeof c.v === 'number' || c.look?.wrap || !r.slice(j + 1).some(something)) return;
    const t = c.runs ? c.runs.map(x => x.text).join('') : c.v;
    if (t && measured(t, !!c.look?.bold, c.look?.pt) > colPx(widths[j])) r[j] = { ...c, look: { ...c.look, wrap: true } };
  });
  // the title rows' scope line flows too (its band word a badge)
  rows[1] = flow(rows[1], widths);
  let prev: DOMRect | undefined;
  const pictures: Placed[] = [];
  for (const b of blocks) {
    if (prev && b.rect.top < prev.bottom - 4 && b.rect.left >= prev.right - 4 && b.rect.height > 0)
      rows.push([txt('(beside the block above on the page)', { color: quiet, italic: true })]);
    if (b.pic) pictures.push({ ...b.pic, row: rows.length + 1, col: 0 });   // under the block's first row (its line)
    rows.push(...(b.flow ? b.rows.map(r => flow(r, widths)) : b.rows));
    prev = b.rect;
  }
  return { name: m.tab, rows, widths, freeze: 3, pictures, charts };
}
