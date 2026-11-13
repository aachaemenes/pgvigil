// The export of a tab (task 54; the workbook as DBA Dash writes its own, task 153 and parity P03): every grid on the page
// as a sheet of one .xlsx workbook, each grid with rows a real Excel table (sortable, filterable, no table style) under
// a blue header row in white bold, every cell in the colour the screen gives it (a status cell, a badge, a dot, a data
// bar's fill, a warning or critical mark in it, a cell class of the page's own rule; the worst when it holds several)
// in a plain (not bold) font and a value cell in the colour its row shows beside it, a link cell as DBA Dash's link
// column (a light fill, the link blue), no other cell filled, the numbers as numbers (a count or a decimal General, a
// share '0.0%', a time 'yyyy-MM-dd HH:mm': DBA Dash's formats), no frozen pane, and each column as wide as its widest
// cell the way DBA Dash's writer measures it (ClosedXML AdjustToContents, capped at 150); a
// column hidden with the grid tools (gridtools.ts) is left out, as on the screen; a Summary sheet first (the instance,
// the tab, the window, the export time); the same rows as CSV beside it (one grid: a .csv; several: a .zip of one
// .csv per grid). It reads the rendered page and each grid's page model (ui.ts gridModel: the raw values in the order
// shown), so the file matches the screen; the server is untouched and nothing leaves the browser but the file the
// user saves. The workbook is written here (SpreadsheetML in a zip): no library, no dependency in the bundle.
// Besides the bar's buttons: Export Excel on every grid's menu (that grid's workbook), on every chart's menu (chart.ts:
// its numbers) and, on the fleet Summary, the bar's Export to Excel drop-down (Export Summary / Export Test Summary).
import { fleet } from './fleet';
import { installGridTools } from './gridtools';
import { Ctx, drillTabs, instanceTabs, mssqlInstanceTabs, parse, rangeLabel, rootTabs, window_ } from './router';
import { fileStamp, offsetLabel, offsetMin, stamp, zoneChoice, zoneName } from './tz';
import { Col, cellText, el, fmtBytes, fmtNum, fmtSecs, fmtTime, gridModel, showMenu } from './ui';

export type Status = 'ok' | 'warn' | 'crit' | 'none' | 'ack';
export type Kind = 'text' | 'int' | 'dec' | 'bytes' | 'secs' | 'nsecs' | 'msecs' | 'pct' | 'date';
export interface Cell { v: string | number; kind: Kind; status?: Status; link?: boolean; head?: boolean; text: string; stamp?: string }   // link: the screen draws the cell as a link   // head: a heading inside a sheet (the Summary sheet's list of sheets)   // stamp: a time's local text for the CSV
export interface Section { name: string; cols: string[]; rows: Cell[][]; note?: string; sample?: string }   // note: the page's 'the newest N of M' line above the grid   // sample: the mark of a stored sample's grid (a demo instance's community tool, community.ts data-sample): in the Summary sheet's note, the mail's line above the grid and a CSV's first line

// ---- reading the page -----------------------------------------------------------------------------------

const localStamp = stamp;   // 'YYYY-MM-DD HH:MM:SS' on the display zone's clock (tz.ts): what the screen shows
const isoTime = /^\d{4}-\d\d-\d\dT/;
const numText = /^-?\d+(\.\d+)?([eE][-+]?\d+)?$/;

function numeric(raw: unknown): number | undefined {
  if (typeof raw === 'number') return isFinite(raw) ? raw : undefined;
  if (typeof raw === 'string' && numText.test(raw)) {
    const n = Number(raw);
    if (!isFinite(n)) return undefined;
    if (/^-?\d+$/.test(raw) && !Number.isSafeInteger(n)) return undefined;   // a bigint past 2^53 stays text, exact
    return n;
  }
  return undefined;
}

// typed: the raw value as the screen shows it. A number is written as a number only when the cell's text is one of
// ui.ts's renderings of it (so a cell a formatter replaced with words, 'never' or 'no access', stays those words).
// The page's text is read with its whitespace collapsed (a locale's grouping space, U+202F in fr-FR, becomes a plain
// space), so each rendering is collapsed the same way before the comparison.
const norm = (s: string) => s.replace(/\s+/g, ' ').trim();

export function typed(raw: unknown, text: string): Pick<Cell, 'v' | 'kind' | 'stamp'> {
  if (text === '') return { v: '', kind: 'text' };
  if (typeof raw === 'string' && isoTime.test(raw) && norm(fmtTime(raw)) === text) {
    const d = new Date(raw);
    if (!isNaN(d.getTime())) return { v: excelDate(d), kind: 'date', stamp: localStamp(d) };
  }
  // a text that only looks like a number (a role or database named '0042', a '+5') is kept as the text it is
  if (typeof raw === 'string' && /^[+0]\d/.test(raw)) return { v: text, kind: 'text' };
  const n = numeric(raw);
  if (n !== undefined) {
    if (norm(fmtBytes(raw)) === text) return { v: n, kind: 'bytes' };
    if (norm(fmtSecs(raw)) === text) return n >= 0 ? { v: n / 86400, kind: 'secs' } : { v: n, kind: 'nsecs' };
    const dur = durParse(text);
    // a duration kept in seconds and shown under a minute as '12.2 s' (the Jobs tabs; a longer one is fmtSecs's '1m 5s'):
    // the same Excel time as the rest of its column. Read before the millisecond form: '0 s' fits both, and only a
    // seconds column writes it (a millisecond formatter writes '0 ms'); a millisecond value shown as '3.72 s' is 1,000
    // times its text and never fits here.
    if (dur && / s$/.test(text) && Math.abs(n * 1000 - dur.ms) <= dur.tol) return n >= 0 ? { v: n / 86400, kind: 'secs' } : { v: n, kind: 'nsecs' };
    // a millisecond duration as any tab writes it: the raw value rounds to the text shown
    if (dur && Math.abs(n - dur.ms) <= dur.tol) return { v: n, kind: 'msecs' };
    // a share: '12.5 %', a growth with its sign ('+3 %'), or one the page rounds to a whole percent
    const pct = new Set([fmtNum(n), (n > 0 ? '+' : '') + fmtNum(n), fmtNum(Math.round(n)), (n > 0 ? '+' : '') + fmtNum(Math.round(n))].map(x => norm(x + ' %')));
    if (pct.has(text)) return { v: n / 100, kind: 'pct' };   // a share under a percent format: Excel's own percent, 12.5 % = 0.125
    if (norm(fmtNum(raw)) === text || String(raw) === text) return { v: n, kind: Number.isInteger(n) ? 'int' : 'dec' };
  }
  return { v: text, kind: 'text' };
}

// the locale's grouping and decimal characters, learnt from fmtNum (',' and '.' in en-US, U+202F and ',' in fr-FR)
const sep = (() => { const t = fmtNum(1234567.5); return { group: t[1], dec: t[t.length - 2] }; })();
// digitsOf: a number as the locale wrote it, back to JavaScript's form ('1,234.5' or '1 234,5' -> '1234.5'); '' = not one
function digitsOf(t: string): string {
  const d = t.split(sep.group).join('').split(sep.dec).join('.').replace(/[\s\u202f\u00a0']/g, '');
  return /^-?\d+(\.\d+)?$/.test(d) ? d : '';
}

// durParse: a millisecond duration as any tab's formatter writes it ('0.3 ms', '2,500 ms', '3.72 s', '75 s',
// '1.08 min'; slow.ts, drill.ts, plan.ts and io.ts each round their own way): the milliseconds the text shows and
// half the unit of its last digit, so a raw value counts as that duration when it rounds to the text.
export function durParse(text: string): { ms: number; tol: number } | undefined {
  const m = /^(.+) (ms|s|min)$/.exec(text);   // the number may carry the locale's grouping space
  if (!m) return undefined;
  const d = digitsOf(m[1]);
  if (!d) return undefined;
  const unit = m[2] === 'min' ? 60000 : m[2] === 's' ? 1000 : 1;
  const k = (d.split('.')[1] ?? '').length;
  return { ms: Number(d) * unit, tol: unit * (Math.pow(10, -k) / 2 + 1e-9) };
}

// fromText: a numeric column (its header carries the 'num' class) of a grid without a page model, read from the
// text alone: a count in the locale's grouping, or a duration; anything else stays text.
export function fromText(text: string): Pick<Cell, 'v' | 'kind'> {
  const dur = durParse(text);
  if (dur) return { v: dur.ms, kind: 'msecs' };
  const d = digitsOf(text);
  if (d && norm(fmtNum(Number(d))) === text) { const n = Number(d); return { v: n, kind: Number.isInteger(n) ? 'int' : 'dec' }; }
  return { v: text, kind: 'text' };
}

// excelDate: the wall-clock time the screen shows (the display zone's), as an Excel serial date (days since
// 1899-12-30), whole seconds (Excel rounds a fraction up in hh:mm:ss, the screen and the CSV cut it: the three agree on
// the floor).
export function excelDate(d: Date): number {
  return (Math.floor(d.getTime() / 1000) * 1000 + offsetMin(d) * 60000) / 86400000 + 25569;
}

const statuses: Status[] = ['crit', 'warn', 'ok', 'none'];
// the marks inside a cell that colour it on the screen: a badge, a dot, a data bar's fill (perfsummary.ts), a word the
// page marks warning or critical (a span with the class), a value whose text the page paints in the status colour
// itself (slow.ts: a failed count's color var(--crit)). Only a text colour counts there: a background set inline is a
// picture's part (perfsummary.ts histogram: its top bucket is var(--crit) also when it is empty and not drawn)
const marks = '.badge, .dot, .bar-fill, .crit, .warn, [style*="color"]';
// statusOf: the colour of a cell by the screen's own rule: a status cell (the Summary grid's), else the worst mark in it,
// else the class the page's own rule gave the cell without 'status'. ui.ts turns a Col's bare cls (ok, warn, crit)
// into a status cell, so no page draws the third kind today; it stays for a page that sets the class on a cell itself,
// and proof-export.sh's driver gives two cells one so the branch stays tested.
export function statusOf(td: Element): Status | undefined {
  const pick = (e: Element) => statuses.find(k => e.classList.contains(k));
  if (td.classList.contains('status')) return td.classList.contains('ack') ? 'ack' : pick(td);
  const found = new Set<Status>();
  for (const m of td.querySelectorAll(marks)) {
    const col = (m as HTMLElement).style?.color ?? '';
    const k = pick(m) ?? (col.includes('var(--crit)') ? 'crit' : col.includes('var(--warn)') ? 'warn' : undefined);
    if (k) found.add(k);
  }
  const worst = statuses.find(k => found.has(k));
  if (worst) return worst;
  return (['crit', 'warn', 'ok'] as Status[]).find(k => td.classList.contains(k));
}

// carry: a value cell takes the colour of the cell that judges it in its row (the page puts the verdict on the word:
// 'failing', 'late', 'failed', '4 %'; DBA Dash colours the value too: the date of the late backup, the time of the
// failed run). So the file colours these value cells where the screen leaves them plain. Column keys of the page
// models: the value's key, then the keys of the cells that may judge it. A cell with a colour of its own keeps it; an
// empty cell takes none.
const carry: Record<string, string[]> = {
  value: ['severity', 'check_name'],                                    // a finding's or a check's value
  archive_age_s: ['archiver_failing'],                                  // Backups: the last archived WAL's age by the archiver's state
  full_at: ['full_status'], full_age_hours: ['full_status'],            // SQL Server backups: each date and age by its type's status
  diff_at: ['diff_status'], log_at: ['log_status'], log_age_minutes: ['log_status'],
  last_run_at: ['last_outcome'], last_run_utc: ['last_outcome'],        // Jobs: the last run's time by its outcome
  last_start: ['last_status'],                                          // Job report: the same
  free_bytes: ['free_pct'],                                             // Storage, drives: the free size by the free share
};

// linkOf: a plain cell the screen draws as a link (a name that opens its page); a status cell keeps its status colours
const linkOf = (td: Element) => !td.classList.contains('status') && !!td.querySelector('a[href]') || undefined;

// a status cell that shows only its colour (a green Summary cell) carries its words in data-text; a statement cell
// shown as its first characters (sqlview.ts) carries the whole text in data-full, which the export writes instead
const text = (e: Element) => e.querySelector('[data-full]')?.getAttribute('data-full')
  ?? ((e.textContent ?? '').replace(/\s+/g, ' ').trim() || (e.querySelector('[data-text]')?.getAttribute('data-text') ?? ''));

// a heading's own words, without its 'what is this' button (sqlview.ts): they name a sheet and a CSV file
const headingText = (e: Element) => {
  const c = e.cloneNode(true) as Element;
  c.querySelectorAll('.whatis, .filter-btn').forEach(b => b.remove());
  return text(c);
};

// readGrid: a grid's header and its rows as cells. A column hidden with the grid tools (its header carries
// data-gt-hidden) is left out, as DBA Dash's export leaves out a hidden column; all = every column (the tools' own reads).
export function readGrid(table: HTMLTableElement, all = false): Pick<Section, 'cols' | 'rows'> {
  const ths = [...table.querySelectorAll(':scope > thead > tr:first-child > th')];
  const cols = ths.map(headingText);   // a header's words without its filter button (ui.ts grid)
  const numCol = ths.map(h => h.classList.contains('num'));
  const m = gridModel(table);
  // every row of the grid as filtered and sorted, also the ones past its page that are not drawn (ui.ts GRID_PAGE); a
  // statement's open History panel (a 'trend-row' under its row) is no data row: its own grid is a sheet of its own
  const trs = (m?.allRows ? m.allRows() : [...table.querySelectorAll<HTMLTableRowElement>(':scope > tbody > tr')]).filter(tr => !tr.classList.contains('trend-row'));
  const data = m?.rows();
  const keys: (Col | undefined)[] = m && m.cols.length === cols.length ? m.cols : cols.map(() => undefined);
  const at = new Map(keys.map((k, j) => [k?.key ?? '', j] as [string, number]));
  const rows = trs.map((tr, i) => {
    const r: Cell[] = [...tr.children].map((td, j) => {
      const t = text(td);
      const raw = data && data.length === trs.length && keys[j] ? data[i][keys[j]!.key] : undefined;
      return { ...(raw !== undefined ? typed(raw, t) : numCol[j] ? fromText(t) : { v: t, kind: 'text' as Kind }), status: statusOf(td), link: linkOf(td), text: t };
    });
    // the colours the row's own cells hold, read before any is carried: a carried colour is never carried on
    const own = r.map(c => c.status);
    r.forEach((c, j) => {
      const from = keys[j] ? carry[keys[j]!.key] : undefined;
      if (!from || c.status || c.text === '') return;
      for (const k of from) { const s = at.has(k) ? own[at.get(k)!] : undefined; if (s) { c.status = s; break; } }
    });
    return r;
  });
  const keep = ths.map(h => all || !h.hasAttribute('data-gt-hidden'));
  if (keep.every(Boolean)) return { cols, rows };
  return { cols: cols.filter((_, j) => keep[j]), rows: rows.map(r => r.filter((_, j) => keep[j] ?? true)) };
}

function readProps(table: HTMLTableElement): Pick<Section, 'cols' | 'rows'> {
  const rows = [...table.querySelectorAll('tr')].map(tr => {
    const th = tr.querySelector('th'), td = tr.querySelector('td');
    const a = th ? text(th) : '', b = td ? text(td) : '';
    return [{ v: a, kind: 'text' as Kind, text: a }, { v: b, kind: 'text' as Kind, status: td ? statusOf(td) : undefined, text: b }];
  });
  return { cols: ['item', 'value'], rows };
}

// ---- an empty grid's columns hidden with the grid tools -----------------------------------------------------
// The grid tools keep a grid's hidden columns per browser under the grid's key (gridtools.ts keyOf: the tab, the heading
// above the grid and its column names). A grid with no row is drawn as a note (ui.ts grid: its columns in data-cols),
// with no table to mark, so the export reads the same key itself: the heading as headingOf finds it, the names as
// names() numbers them. A choice a browser could not keep (a private window: the tools hold it in memory) is not seen.
function toolsHash(s: string): string {
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  return h.toString(36);
}
function hiddenOfEmpty(p: Element, cols: string[]): Set<number> {
  let h = '';
  for (const e of document.querySelectorAll('h2, h3, h4, p.empty[data-cols]')) {
    if (e === p) break;
    if (e.tagName !== 'P') { const c = e.cloneNode(true) as Element; c.querySelectorAll('.whatis, .filter-btn').forEach(b => b.remove()); h = cellText(c); }
  }
  h = h.replace(/\s*\(.*\)$/, '');
  const seen = new Map<string, number>();
  const ns = cols.map((c, j) => { const base = c || `column ${j + 1}`, n = (seen.get(base) ?? 0) + 1; seen.set(base, n); return n > 1 ? `${base} (${n})` : base; });
  const key = `pgvigil.grid.${(/^#\/([A-Za-z_]+)/.exec(location.hash)?.[1] ?? 'summary')}.${toolsHash(h + '|' + ns.join('|'))}`;
  let hidden: unknown = [];
  try { hidden = (JSON.parse(localStorage.getItem(key) ?? '{}') as { hidden?: unknown } | null)?.hidden ?? []; } catch { hidden = []; }
  const set = new Set(Array.isArray(hidden) ? hidden.filter(x => typeof x === 'string') as string[] : []);
  const out = new Set(ns.map((n, j) => set.has(n) && j < 80 ? j : -1).filter(j => j >= 0));   // gridtools.ts MAX_COLS: the columns its hide rules reach
  return out.size >= ns.length ? new Set() : out;   // a grid never loses every column (gridtools.ts apply)
}

// sections: every grid and property card on the page, in page order, each named by the heading above it. A heading
// inside a region of its own (the Summary's 'Needs attention' strip) names the grids of that region only: the grids
// after it keep the heading before it.
// empties: a grid with no row is a section too (the Export buttons, the grid's and the bar's Export Excel and the
// mail's workbook: a sheet of its header row, as DBA Dash writes one); the mail's body and the grid menu's own copy
// read the tables alone
export function sections(root: ParentNode, fallback: string, empties = false): Section[] {
  return walk(root, fallback, empties).map(f => f.sec);
}

// walk: sections() with the element each came from (a grid's menu exports the one it was opened on)
function walk(root: ParentNode, fallback: string, empties: boolean): { sec: Section; el: Element }[] {
  let outer = fallback, inner: { text: string; within: Element } | undefined;
  const out: { sec: Section; el: Element }[] = [];
  for (const e of root.querySelectorAll(empties ? 'h2, h3, h4, table.grid, table.props, p.empty[data-cols]' : 'h2, h3, h4, table.grid, table.props')) {
    if (e.tagName !== 'TABLE' && e.tagName !== 'P') {
      const within = e.closest('[role=region]');
      if (within) inner = { text: headingText(e) || fallback, within }; else { outer = headingText(e) || fallback; inner = undefined; }
      continue;
    }
    const heading = inner && inner.within.contains(e) ? inner.text : outer;
    // a grid with no row (ui.ts grid: its note carries its columns' names): a sheet of its header row alone, as DBA Dash
    // exports an empty grid (CommonShared.cs SaveDataGridViewsToXLSX: a sheet per grid, the header row, then the rows)
    if (e.tagName === 'P') {
      let cols: unknown = [];
      try { cols = JSON.parse((e as HTMLElement).dataset.cols ?? '[]'); } catch { cols = []; }
      if (Array.isArray(cols) && cols.length) {
        // DBA Dash writes the visible columns' headers only: a column the grid tools hide stays out here too
        const all = cols.map(String), hid = hiddenOfEmpty(e, all);
        const sample = e.closest('[data-sample]')?.getAttribute('data-sample') || undefined;
        out.push({ sec: { name: heading, cols: all.filter((_, j) => !hid.has(j)), rows: [], note: [sample, text(e)].filter(Boolean).join('; ') || undefined, sample }, el: e });
      }
      continue;
    }
    const t = e as HTMLTableElement;
    // a 'the newest 500 of 1,234 samples' line right above the grid rides into the Summary sheet: the rows taken are not all
    // ui.ts grid: table in .grid-wrap in .grid-box, whose first child is the 'n of m rows shown (filtered)' line
    const wrap = t.parentElement?.classList.contains('grid-wrap') ? t.parentElement : t;
    const box = wrap.parentElement?.classList.contains('grid-box') ? wrap.parentElement : wrap;
    const prev = box.previousElementSibling;
    const filtered = box !== wrap ? text(box.querySelector('.filter-count') ?? box) : '';
    // a stored sample's grid carries its mark first: never read as the instance's own data in a file or a mail
    const sample = t.closest('[data-sample]')?.getAttribute('data-sample') || undefined;
    const notes = [sample ?? '', prev && prev.matches('p.meta') && /\d\S* of \d/.test(text(prev)) ? text(prev) : '', box !== wrap && /filtered|the stretch/.test(filtered) ? filtered : ''].filter(Boolean);
    const note = notes.length ? notes.join('; ') : undefined;
    out.push({ sec: { name: heading, ...(t.classList.contains('grid') ? readGrid(t) : readProps(t)), note, sample }, el: t });
  }
  return out;
}

// ---- the workbook -----------------------------------------------------------------------------------------

// the status colours of an exported sheet are the screen's solid ones (DBA Dash's light theme: solid fills with white text,
// N/A grey with dark blue text, acknowledged blue; the orange carries the screen's dark text, DBA Dash's white on it is
// 2.5:1) in a plain font, as DBA Dash writes them, under a blue header with white bold text, whatever the theme or status
// style on screen
export const fillOf: Record<Status, string> = { ok: 'FF006638', warn: 'FFE49325', crit: 'FFAB1F26', none: 'FFE0E1E9', ack: 'FF1B6AA3' };
export const fontOf: Record<Status, string> = { ok: 'FFFFFFFF', warn: 'FF1D1300', crit: 'FFFFFFFF', none: 'FF004F83', ack: 'FFFFFFFF' };
export const headFill = 'FF0063A3';
export const linkFill = 'FFF1F1F6', linkFont = 'FF004F83';   // DBA Dash's link column: its fill and its text
// numFmt ids: 0 is General (DBA Dash writes a count or a decimal so); 165 on are this file's own: a share and a time in
// DBA Dash's formats (its P1 percent, its date), a size, a duration in pgvigil's units (the screen shows the unit; DBA Dash
// has no such kind)
const fmtId: Record<Kind, number> = { text: 0, int: 0, dec: 0, bytes: 165, secs: 166, pct: 167, date: 168, nsecs: 169, msecs: 170 };
// fmtOf: a cell's number format. A count of 12 digits or more (a PostgreSQL counter: blocks hit, tuples returned) under
// Excel's built-in '0' (1): General would show it as 9.87654E+11, six digits of it; DBA Dash's writer has no such count
const fmtOf = (c: Cell) => c.kind === 'int' && typeof c.v === 'number' && Math.abs(c.v) >= 1e11 ? 1 : fmtId[c.kind];
const customFmts: [number, string][] = [[165, '#,##0" B"'], [166, '[h]:mm:ss'], [167, '0.0%'], [168, 'yyyy-MM-dd HH:mm'], [169, '#,##0" s"'], [170, '#,##0.###" ms"']];

const esc = (s: string) => s.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function colName(i: number): string {
  let s = '';
  for (i++; i > 0; i = Math.floor((i - 1) / 26)) s = String.fromCharCode(65 + (i - 1) % 26) + s;
  return s;
}

// Styles: one cellXfs entry per (number format, fill, font) used; fills 0 and 1 are the two the format reserves.
class Styles {
  private xfs = new Map<string, number>([['0|0|0', 0]]);
  private fills = ['<fill><patternFill patternType="none"/></fill>', '<fill><patternFill patternType="gray125"/></fill>'];
  private fonts = ['<font><sz val="11"/><name val="Calibri"/></font>'];
  private fillIds = new Map<string, number>();
  private fontIds = new Map<string, number>();
  private fill(argb: string): number {
    let i = this.fillIds.get(argb);
    if (i === undefined) { i = this.fills.push(`<fill><patternFill patternType="solid"><fgColor rgb="${argb}"/><bgColor indexed="64"/></patternFill></fill>`) - 1; this.fillIds.set(argb, i); }
    return i;
  }
  private font(argb: string, bold: boolean): number {
    const k = argb + (bold ? 'b' : '');
    let i = this.fontIds.get(k);
    if (i === undefined) { i = this.fonts.push(`<font>${bold ? '<b/>' : ''}<sz val="11"/><color rgb="${argb}"/><name val="Calibri"/></font>`) - 1; this.fontIds.set(k, i); }
    return i;
  }
  id(fmt: number, status?: Status, head = false, link = false): number {
    const fill = head ? this.fill(headFill) : status ? this.fill(fillOf[status]) : link ? this.fill(linkFill) : 0;
    const font = head ? this.font('FFFFFFFF', true) : status ? this.font(fontOf[status], false) : link ? this.font(linkFont, false) : 0;
    const k = `${fmt}|${fill}|${font}`;
    let i = this.xfs.get(k);
    if (i === undefined) { i = this.xfs.size; this.xfs.set(k, i); }
    return i;
  }
  xml(): string {
    const xfs = [...this.xfs.keys()].map(k => {
      const [n, f, t] = k.split('|');
      return `<xf numFmtId="${n}" fontId="${t}" fillId="${f}" borderId="0" xfId="0"${n !== '0' ? ' applyNumberFormat="1"' : ''}${f !== '0' ? ' applyFill="1"' : ''}${t !== '0' ? ' applyFont="1"' : ''}/>`;
    });
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      + '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      + `<numFmts count="${customFmts.length}">${customFmts.map(([i, f]) => `<numFmt numFmtId="${i}" formatCode="${esc(f)}"/>`).join('')}</numFmts>`
      + `<fonts count="${this.fonts.length}">${this.fonts.join('')}</fonts>`
      + `<fills count="${this.fills.length}">${this.fills.join('')}</fills>`
      + '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>'
      + '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      + `<cellXfs count="${xfs.length}">${xfs.join('')}</cellXfs>`
      + '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>'
      + '</styleSheet>';
  }
}

// ---- the column widths, as DBA Dash's writer sets them --------------------------------------------------------
// ClosedXML's AdjustToContents (DBA Dash's export, capped at 150) measures each cell's text in Calibri 11 (Carlito, its
// metric twin, where Calibri is absent) and stores whole pixels: width = (px - 0.025625) / 7. Fitted on DBA Dash's own
// four exports (111 columns): a header cell (bold, its filter button beside it) 1.0286 x its text + 22.19 px, within
// 3.2 px; any other cell 1.0738 x its text + 0.52 px, within about 5 px (under 0.75 of a character).
// Carlito's advance widths, ASCII 32-126, in 1/2048 em: regular, bold
const ADV = [463, 667, 821, 1020, 1038, 1464, 1397, 452, 621, 621, 1020, 1020, 511, 627, 517, 791, 1038, 1038, 1038, 1038, 1038, 1038, 1038, 1038, 1038, 1038, 548, 548, 1020, 1020, 1020, 949, 1831, 1185, 1114, 1092, 1260, 1000, 941, 1292, 1276, 516, 653, 1064, 861, 1751, 1322, 1356, 1058, 1378, 1112, 941, 998, 1314, 1162, 1822, 1063, 998, 959, 628, 791, 628, 1020, 1020, 596, 981, 1076, 866, 1076, 1019, 625, 964, 1076, 470, 490, 931, 470, 1636, 1076, 1080, 1076, 1076, 714, 801, 686, 1076, 925, 1464, 887, 927, 809, 644, 943, 644, 1020];
const ADV_B = [463, 667, 898, 1020, 1038, 1493, 1443, 478, 638, 638, 1020, 1020, 528, 627, 547, 880, 1038, 1038, 1038, 1038, 1038, 1038, 1038, 1038, 1038, 1038, 565, 565, 1020, 1020, 1020, 949, 1840, 1241, 1148, 1084, 1291, 999, 940, 1305, 1292, 546, 678, 1120, 866, 1790, 1349, 1385, 1090, 1405, 1153, 968, 1014, 1337, 1211, 1856, 1128, 1064, 979, 665, 880, 665, 1020, 1020, 615, 1011, 1099, 857, 1099, 1031, 648, 971, 1099, 503, 523, 983, 503, 1666, 1099, 1101, 1099, 1099, 728, 817, 710, 1099, 969, 1526, 941, 970, 814, 704, 973, 704, 1020];
const MAX_WIDTH = 150, PX = 11 * 96 / 72 / 2048;
// textPx: the pixels a line of text takes in Calibri 11 (a character past ASCII: Carlito's Latin average, a wide one an em)
export function textPx(s: string, bold: boolean): number {
  const t = bold ? ADV_B : ADV;
  let u = 0;
  for (const ch of s) {
    const c = ch.codePointAt(0) ?? 32;
    u += c >= 32 && c <= 126 ? t[c - 32] : c >= 0x2e80 ? 2048 : bold ? 1030 : 1013;
    if (u * PX > MAX_WIDTH * 8) break;   // past the cap: the rest changes nothing
  }
  return u * PX;
}
// shown: the text Excel shows for a cell under its format (what the width is measured on)
export function shown(c: Cell): string {
  if (typeof c.v !== 'number') return c.v.split(/\r?\n/).reduce((a, b) => b.length > a.length ? b : a, '');
  const n = c.v;
  switch (c.kind) {
    case 'date': return (c.stamp ?? '').slice(0, 16);
    case 'pct': return (n * 100).toFixed(1) + '%';
    case 'bytes': return Math.round(n).toLocaleString('en-US') + ' B';
    case 'nsecs': return Math.round(n).toLocaleString('en-US') + ' s';
    case 'msecs': return n.toLocaleString('en-US', { maximumFractionDigits: 3 }) + ' ms';
    case 'secs': { const t = Math.round(n * 86400), a = Math.abs(t); return `${t < 0 ? '-' : ''}${Math.floor(a / 3600)}:${String(Math.floor(a / 60) % 60).padStart(2, '0')}:${String(a % 60).padStart(2, '0')}`; }
    default: return String(n);   // a General number as the writer's own text of it (DBA Dash's ClosedXML measures the value's string)
  }
}
// colWidth: a column's width from its cells' texts (head: the cell is a header, bold with its filter button)
export function colWidth(cells: { text: string; head: boolean }[]): number {
  const px = Math.round(Math.max(0, ...cells.map(c => c.text === '' ? 0 : c.head ? 1.0286 * textPx(c.text, true) + 22.19 : 1.0738 * textPx(c.text, false) + 0.52)));
  if (px <= 0) return 8.43;   // an empty column: Excel's default
  return Math.min(MAX_WIDTH, Math.round((px - 0.025625) / 7 * 1e6) / 1e6);
}

interface Sheet { name: string; head: string[]; rows: Cell[][]; data: boolean; table?: number }   // data: a grid's sheet (the Summary sheet is not one); table: the id of its Excel table part

// Shared: the workbook's shared strings. Only a table's header cells use them: Excel matches a table's column names
// against its header cells, and every writer Excel is known to accept (its own, DBA Dash's) stores those as shared
// strings; every other text stays inline in its cell.
class Shared {
  private ids = new Map<string, number>();
  id(v: string): number {
    let i = this.ids.get(v);
    if (i === undefined) { i = this.ids.size; this.ids.set(v, i); }
    return i;
  }
  get size(): number { return this.ids.size; }
  xml(): string {
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      + `<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${this.ids.size}" uniqueCount="${this.ids.size}">`
      + [...this.ids.keys()].map(v => `<si><t xml:space="preserve">${esc(v)}</t></si>`).join('') + '</sst>';
  }
}

// tableHead: an Excel table wants every column named, each name once (case ignored): an empty heading becomes
// 'Column n', a repeat gets ' (2)'. The header cells carry the same words, or Excel repairs the file.
export function tableHead(head: string[], ncol: number): string[] {
  const used = new Set<string>();
  return Array.from({ length: ncol }, (_, j) => {
    const base = (head[j] ?? '').slice(0, 250) || `Column ${j + 1}`;
    let s = base;
    for (let i = 2; used.has(s.toLowerCase()); i++) s = `${base} (${i})`;
    used.add(s.toLowerCase());
    return s;
  });
}

// tableXml: the grid as a real Excel table (sortable, filterable, named), with no table style: the cells keep their own colours.
function tableXml(id: number, head: string[], nrow: number): string {
  const ref = `A1:${colName(head.length - 1)}${nrow + 1}`;
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + `<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="${id}" name="Table${id}" displayName="Table${id}" ref="${ref}" totalsRowShown="0">`
    + `<autoFilter ref="${ref}"/><tableColumns count="${head.length}">${head.map((h, j) => `<tableColumn id="${j + 1}" name="${esc(h)}"/>`).join('')}</tableColumns>`
    + '<tableStyleInfo showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>';   // DBA Dash's: no style name, so no stripe is drawn
}

function sheetXml(sh: Sheet, st: Styles, sst: Shared): string {
  const ncol = Math.max(sh.head.length, ...sh.rows.map(r => r.length), 1);
  const head = sh.table ? tableHead(sh.head, ncol) : sh.head;
  const widths = Array.from({ length: ncol }, (_, j) => colWidth([{ text: head[j] ?? '', head: true }, ...sh.rows.map(r => ({ text: r[j] ? shown(r[j]) : '', head: !!r[j]?.head }))]));
  const cell = (ref: string, c: Cell, s: number) => {
    if (typeof c.v === 'number') return `<c r="${ref}" s="${s}"><v>${String(c.v).toUpperCase()}</v></c>`;
    if (c.v === '') return s ? `<c r="${ref}" s="${s}"/>` : '';
    // Excel holds at most 32,767 characters in a cell (a longer one opens with a repair): the rest is cut, said in the cell
    const v = c.v.length > 32767 ? c.v.slice(0, 32700) + ' ... [cut at Excel\'s cell limit]' : c.v;
    return `<c r="${ref}" s="${s}" t="inlineStr"><is><t xml:space="preserve">${esc(v)}</t></is></c>`;
  };
  const hs = st.id(0, undefined, true);   // every sheet's header row, the Summary sheet's too
  const rows = [`<row r="1">${head.map((h, j) => sh.table ? `<c r="${colName(j)}1" s="${hs}" t="s"><v>${sst.id(h)}</v></c>` : cell(colName(j) + '1', { v: h, kind: 'text', text: h }, hs)).join('')}</row>`];
  // a cell has the fill the screen gives it and no other (DBA Dash bands no rows): a plain cell is unfilled
  sh.rows.forEach((r, i) => {
    rows.push(`<row r="${i + 2}">${r.map((c, j) => cell(colName(j) + (i + 2), c, st.id(fmtOf(c), c.status, !!c.head, c.link))).join('')}</row>`);
  });
  const last = `${colName(ncol - 1)}${sh.rows.length + 1}`;
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + `<dimension ref="A1:${last}"/>`
    + '<sheetViews><sheetView workbookViewId="0"/></sheetViews>'   // no frozen pane, as DBA Dash: a table shows its column names in place of the letters when scrolled
    + '<sheetFormatPr defaultRowHeight="15"/>'
    + `<cols>${widths.map((w, j) => `<col min="${j + 1}" max="${j + 1}" width="${w}" customWidth="1"/>`).join('')}</cols>`
    + `<sheetData>${rows.join('')}</sheetData>`
    + (sh.table ? '<tableParts count="1"><tablePart r:id="rId1"/></tableParts>' : sh.data ? `<autoFilter ref="A1:${last}"/>` : '')
    + '</worksheet>';
}

// sheetNames: the screen's heading, cut to Excel's 31 characters without the characters a sheet name refuses,
// a repeat numbered; 'Summary' is the export's own first sheet and 'History' is a name Excel reserves.
export function sheetNames(names: string[]): string[] {
  const used = new Set(['summary', 'history']);
  const cut = (s: string, n: number) => s.slice(0, n).replace(/[\s']+$/, '');
  return names.map(n => {
    const base = cut(n.replace(/[\\/?*[\]:]/g, ' ').replace(/^'+|'+$/g, '').replace(/\s+/g, ' ').trim(), 31) || 'Sheet';
    let s = base;
    for (let i = 2; used.has(s.toLowerCase()); i++) s = cut(base, 31 - ` (${i})`.length) + ` (${i})`;
    used.add(s.toLowerCase());
    return s;
  });
}

export interface Meta { instance: string; tab: string; from: Date; to: Date; window: string; at: Date }

// timeZone: the zone the times in the file are written in, 'America/Los_Angeles (UTC-08:00 at export)': the display
// zone (the browser's unless another was chosen in the range panel). Each time carries its own date's offset (a window
// across a DST change holds two), so the offset is the export's.
export function timeZone(at: Date): string {
  const whose = zoneChoice() === 'local' ? "the browser's" : 'the display zone chosen in the range panel';
  return `${zoneName()} (${offsetLabel(at)} at export), ${whose}; each time in its own date's offset`;
}

export function workbook(meta: Meta, secs: Section[]): { name: string; data: Uint8Array }[] {
  const names = sheetNames(secs.map(s => s.name));
  const t = (v: string): Cell => ({ v, kind: 'text', text: v });
  const h = (v: string): Cell => ({ v, kind: 'text', text: v, head: true });
  const d = (v: Date): Cell => ({ v: excelDate(v), kind: 'date', text: '', stamp: localStamp(v) });
  const info: Cell[][] = [
    [t('Instance'), t(meta.instance)], [t('Tab'), t(meta.tab)],
    [t('Window'), t(meta.window)], [t('Window from'), d(meta.from)], [t('Window to'), d(meta.to)],
    [t('Exported at'), d(meta.at)], [t('Time zone'), t(timeZone(meta.at))], [t('Source'), t('pgvigil')], [t(''), t('')], [h('Sheet'), h('Rows'), h('Note')],
    ...secs.map((s, i) => [t(names[i]), { v: s.rows.length, kind: 'int' as Kind, text: '' }, t(s.note ?? '')]),
  ];
  const sheets: Sheet[] = [{ name: 'Summary', head: ['Item', 'Value', 'Note'], rows: info, data: false },
    ...secs.map((s, i) => ({ name: names[i], head: s.cols, rows: s.rows, data: true }))];
  // every grid with rows is an Excel table (a table needs a data row: an empty grid keeps the plain filter)
  let tables = 0;
  for (const sh of sheets) if (sh.data && sh.rows.length > 0) sh.table = ++tables;
  const st = new Styles(), sst = new Shared();
  const enc = new TextEncoder();
  const files = sheets.map((sh, i) => ({ name: `xl/worksheets/sheet${i + 1}.xml`, data: enc.encode(sheetXml(sh, st, sst)) }));
  const x = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  const ncolOf = (sh: Sheet) => Math.max(sh.head.length, ...sh.rows.map(r => r.length), 1);
  const tableFiles = sheets.flatMap((sh, i) => sh.table ? [
    { name: `xl/tables/table${sh.table}.xml`, data: enc.encode(tableXml(sh.table, tableHead(sh.head, ncolOf(sh)), sh.rows.length)) },
    { name: `xl/worksheets/_rels/sheet${i + 1}.xml.rels`, data: enc.encode(x + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" Target="../tables/table${sh.table}.xml"/></Relationships>`) }] : []);
  const filters = sheets.map((sh, i) => sh.data && !sh.table
    ? `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">'${esc(sh.name.replace(/'/g, "''"))}'!$A$1:$${colName(Math.max(sh.head.length, 1) - 1)}$${sh.rows.length + 1}</definedName>` : '').join('');
  return [
    { name: '[Content_Types].xml', data: enc.encode(x + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
      + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      + '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      + sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')
      + sheets.map(sh => sh.table ? `<Override PartName="/xl/tables/table${sh.table}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>` : '').join('')
      + (sst.size ? '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>' : '')
      + '</Types>') },
    { name: '_rels/.rels', data: enc.encode(x + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>') },
    { name: 'xl/workbook.xml', data: enc.encode(x + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      + `<sheets>${sheets.map((sh, i) => `<sheet name="${esc(sh.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets>`
      + (filters ? `<definedNames>${filters}</definedNames>` : '') + '</workbook>') },
    { name: 'xl/_rels/workbook.xml.rels', data: enc.encode(x + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')
      + `<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>`
      + (sst.size ? `<Relationship Id="rId${sheets.length + 2}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/>` : '')
      + '</Relationships>') },
    { name: 'xl/styles.xml', data: enc.encode(st.xml()) },   // after the sheets: they register the styles they use
    ...(sst.size ? [{ name: 'xl/sharedStrings.xml', data: enc.encode(sst.xml()) }] : []),
    ...files, ...tableFiles,
  ];
}

// ---- CSV --------------------------------------------------------------------------------------------------


// csv: RFC 4180 with a UTF-8 byte-order mark (Excel reads the encoding from it); a number as its plain value (a
// duration in seconds, a size in bytes, a share in percent), a time as the screen shows it (the display time zone's clock); a text cell
// that a spreadsheet would read as a formula (= + - @ tab CR first) gets a leading apostrophe (OWASP CSV injection).
export function csv(s: Section): string {
  const val = (c: Cell): string => {
    if (typeof c.v === 'number') {
      if (c.kind === 'date') return c.stamp ?? '';
      if (c.kind === 'secs') return String(Math.round(c.v * 86400 * 1000) / 1000);
      if (c.kind === 'msecs') return String(c.v);   // the milliseconds, as the raw value
      if (c.kind === 'pct') return String(Math.round(c.v * 1e12) / 1e10);   // the percent figure (the cell holds the share): 12.5, not 0.125; ten decimals kept
      return String(c.v);
    }
    return /^[=+\-@\t\r]/.test(c.v) ? "'" + c.v : c.v;
  };
  const q = (v: string) => /[",\r\n]|^\s|\s$/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
  // a stored sample's file starts with its mark, a line of its own above the header
  return '﻿' + [...(s.sample ? [q(s.sample)] : []), s.cols.map(q).join(','), ...s.rows.map(r => r.map(c => q(val(c))).join(','))].join('\r\n') + '\r\n';
}

// ---- zip (the .xlsx container and the CSV bundle) ---------------------------------------------------------

const crcTable = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return t;
})();
export function crc32(b: Uint8Array): number {
  let c = 0xFFFFFFFF;
  for (let i = 0; i < b.length; i++) c = crcTable[(c ^ b[i]) & 0xFF] ^ (c >>> 8);
  return (c ^ 0xFFFFFFFF) >>> 0;
}

async function deflate(b: Uint8Array): Promise<Uint8Array | null> {
  if (typeof CompressionStream === 'undefined') return null;
  try {
    const s = new Blob([b as BlobPart]).stream().pipeThrough(new CompressionStream('deflate-raw'));
    return new Uint8Array(await new Response(s).arrayBuffer());
  } catch { return null; }   // a browser without deflate-raw: the entry is stored
}

export async function zip(files: { name: string; data: Uint8Array }[], at = new Date()): Promise<Blob> {
  const enc = new TextEncoder();
  const time = (at.getHours() << 11) | (at.getMinutes() << 5) | (at.getSeconds() >> 1);
  const date = ((Math.max(1980, at.getFullYear()) - 1980) << 9) | ((at.getMonth() + 1) << 5) | at.getDate();
  const parts: Uint8Array[] = [], central: Uint8Array[] = [];
  let off = 0;
  for (const f of files) {
    const name = enc.encode(f.name), crc = crc32(f.data);
    const z = await deflate(f.data);
    const packed = z && z.length < f.data.length ? z : f.data, method = packed === f.data ? 0 : 8;
    const h = new DataView(new ArrayBuffer(30));
    h.setUint32(0, 0x04034b50, true); h.setUint16(4, 20, true); h.setUint16(6, 0x0800, true); h.setUint16(8, method, true);
    h.setUint16(10, time, true); h.setUint16(12, date, true); h.setUint32(14, crc, true);
    h.setUint32(18, packed.length, true); h.setUint32(22, f.data.length, true); h.setUint16(26, name.length, true); h.setUint16(28, 0, true);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true); c.setUint16(4, 20, true); c.setUint16(6, 20, true); c.setUint16(8, 0x0800, true); c.setUint16(10, method, true);
    c.setUint16(12, time, true); c.setUint16(14, date, true); c.setUint32(16, crc, true);
    c.setUint32(20, packed.length, true); c.setUint32(24, f.data.length, true); c.setUint16(28, name.length, true);
    c.setUint32(42, off, true);
    parts.push(new Uint8Array(h.buffer), name, packed);
    central.push(new Uint8Array(c.buffer), name);
    off += 30 + name.length + packed.length;
  }
  const size = central.reduce((n, b) => n + b.length, 0);
  const e = new DataView(new ArrayBuffer(22));
  e.setUint32(0, 0x06054b50, true); e.setUint16(8, files.length, true); e.setUint16(10, files.length, true);
  e.setUint32(12, size, true); e.setUint32(16, off, true);
  return new Blob([...parts, ...central, new Uint8Array(e.buffer)] as BlobPart[]);
}

// ---- the buttons ------------------------------------------------------------------------------------------

const safe = (s: string) => s.replace(/[^A-Za-z0-9._-]+/g, '-').replace(/^-+|-+$/g, '') || 'x';

async function metaOf(ctx: Ctx): Promise<Meta> {
  let instance = ctx.tag ? 'tag ' + ctx.tag : 'fleet';
  if (ctx.instance) {
    instance = 'instance ' + ctx.instance;
    try { const r = (await fleet()).instances.find(x => Number(x.instance_id) === ctx.instance); if (r) instance = String(r.name); } catch { /* the id stands */ }
  }
  const w = window_(ctx);
  const tab = (ctx.instance ? instanceTabs[ctx.tab] ?? mssqlInstanceTabs[ctx.tab] ?? drillTabs[ctx.tab] : rootTabs[ctx.tab]) ?? ctx.tab;
  return { instance, tab, from: new Date(w.from), to: new Date(w.to), window: rangeLabel(ctx), at: new Date() };
}

export function exportName(m: Meta, ext: string): string {
  return `${safe(m.instance)}_${safe(m.tab)}_${fileStamp(m.from)}_${fileStamp(m.to)}.${ext}`;
}

function save(blob: Blob, name: string) {
  const a = el('a', { href: URL.createObjectURL(blob), download: name });
  a.hidden = true;
  document.body.append(a);
  a.click();
  a.remove();
  window.setTimeout(() => URL.revokeObjectURL(a.href), 60000);
}

const XLSX = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

// oneFile: a workbook of one grid or one chart (the Summary sheet, then its own), named
// <instance>_<tab>_<sheet>_<from>_<to>.xlsx
async function oneFile(m: Meta, sec: Section): Promise<string> {
  const z = await zip(workbook(m, [sec]), m.at);
  const name = `${safe(m.instance)}_${safe(m.tab)}_${safe(sheetNames([sec.name])[0])}_${fileStamp(m.from)}_${fileStamp(m.to)}.xlsx`;
  save(new Blob([z], { type: XLSX }), name);
  return name;
}

// exportGrid: one grid's workbook (a grid's menu: Export Excel; the Summary's Export to Excel items), read as the bar's
// export reads it (the same heading, cells, colours, hidden columns); an empty grid (its note) is a sheet of its header
// row. name: the sheet's name instead of the heading's.
export async function exportGrid(g: Element, name?: string, ctx: Ctx = parse()): Promise<string> {
  const m = await metaOf(ctx);
  const root = g.closest('dialog') ?? document.getElementById('main') ?? document.body;
  const found = walk(root, m.tab, true).find(f => f.el === g)?.sec
    ?? (g.tagName === 'TABLE' && g.classList.contains('grid') ? { name: m.tab, ...readGrid(g as HTMLTableElement) } : undefined);
  if (!found) throw new Error('no grid here');
  return oneFile(m, name ? { ...found, name } : found);
}

// exportChart: a chart's numbers as a workbook (a chart's menu: Export Excel; chart.ts): one sheet named by the chart's
// title, a time as a time ('yyyy-MM-dd HH:mm'), a number as a number, a share (kind 'pct', the fraction) as '0.0%'
export async function exportChart(title: string, cols: string[], rows: (string | number | Date | null | undefined)[][], kinds: (Kind | undefined)[] = [], ctx: Ctx = parse()): Promise<string> {
  const m = await metaOf(ctx);
  const cell = (v: string | number | Date | null | undefined, j: number): Cell => {
    if (v instanceof Date) return { v: excelDate(v), kind: 'date', text: '', stamp: localStamp(v) };
    if (typeof v === 'number' && isFinite(v)) return { v, kind: kinds[j] ?? (Number.isInteger(v) ? 'int' : 'dec'), text: String(v) };
    const t = v == null || typeof v === 'number' ? '' : v;
    return { v: t, kind: 'text', text: t };
  };
  return oneFile(m, { name: title || 'Chart', cols, rows: rows.map(r => r.map(cell)) });
}

// tell: a word in the grid's own count line for a moment (ui.ts grid: the 'n of m rows' line above it)
function tell(g: Element, what: string) {
  const count = g.closest('.grid-box')?.querySelector('.filter-count');
  if (!count) return;
  const before = count.textContent;
  count.textContent = what;
  window.setTimeout(() => { if (count.textContent === what) count.textContent = before; }, 2500);
}

// the grid's menu (ui.ts sends 'pgvigil:gridmenu' with its items): Export Excel after the copies, where DBA Dash's grid
// menu has it (Copy, then Export Excel)
let menuOn = false;
function installGridExport() {
  if (menuOn || typeof document === 'undefined') return;
  menuOn = true;
  document.addEventListener('pgvigil:gridmenu', e => {
    const d = (e as CustomEvent<{ table?: HTMLTableElement; items?: [string, () => void][] }>).detail;
    if (!d?.table || !Array.isArray(d.items)) return;
    const t = d.table;
    let at = 0;
    d.items.forEach((it, i) => { if (/^Copy\b/.test(it[0])) at = i + 1; });
    d.items.splice(at, 0, ['Export Excel', () => {
      void exportGrid(t).then(n => tell(t, 'Exported ' + n), (x: unknown) => tell(t, 'Export failed: ' + (x instanceof Error ? x.message : String(x))));
    }]);
  });
}

// summaryExport: the fleet Summary's Export to Excel drop-down (DBA Dash's Summary toolbar): Export Summary (the
// instance grid) or Export Test Summary (the grid of tests), each a workbook of that grid alone
function summaryExport(ctx: Ctx, root: () => HTMLElement | null, note: HTMLElement): HTMLElement {
  const b = el('button', { type: 'button', 'aria-haspopup': 'menu', title: 'The instance grid or the test grid as an Excel workbook' }, 'Export to Excel ', el('span', { 'aria-hidden': 'true' }, '\u25BE')) as HTMLButtonElement;
  const one = (tests: boolean) => {
    note.textContent = '';
    const r = root();
    const all = r ? [...r.querySelectorAll('table.grid, p.empty[data-cols]')].filter(g => !g.closest('.attention')) : [];
    const g = tests ? all.find(x => x.closest('.tests')) : [...all].reverse().find(x => !x.closest('.tests'));
    if (!g) { note.textContent = 'Nothing to export: the grid is not on this page.'; return; }
    void exportGrid(g, tests ? 'Test Summary' : 'Instance Summary', ctx).catch((x: unknown) => { note.textContent = 'Export failed: ' + (x instanceof Error ? x.message : String(x)); });
  };
  b.addEventListener('click', () => {
    const at = b.getBoundingClientRect();
    showMenu(at.left, at.bottom + 2, [['Export Summary', () => one(false)], ['Export Test Summary', () => one(true)]], b);
  });
  return b;
}

// exportButtons: the bar's two buttons for the page under them (#main): the workbook and the CSV. The grid tools
// (gridtools.ts: the column chooser, the copies with the colours, the selection's sums, the groups, the data bars)
// start with the bar: they answer the grids' own menu and touch nothing until asked.
export function exportButtons(ctx: Ctx, root: () => HTMLElement | null = () => document.getElementById('main')): HTMLElement {
  installGridTools();
  installGridExport();   // after the tools: its line goes after their copies
  const note = el('span', { class: 'meta', role: 'status' });
  const run = async (b: HTMLButtonElement, kind: 'xlsx' | 'csv') => {
    b.disabled = true; note.textContent = '';
    try {
      const m = await metaOf(ctx);
      const r = root();
      const secs = r ? sections(r, m.tab, true) : [];
      if (secs.length === 0) { note.textContent = 'Nothing to export: no grid on this page.'; return; }
      if (kind === 'xlsx') {
        const z = await zip(workbook(m, secs), m.at);
        save(new Blob([z], { type: XLSX }), exportName(m, 'xlsx'));
      } else if (secs.length === 1) {
        save(new Blob([csv(secs[0])], { type: 'text/csv;charset=utf-8' }), exportName(m, 'csv'));
      } else {
        const names = sheetNames(secs.map(s => s.name)), enc = new TextEncoder();
        const z = await zip(secs.map((s, i) => ({ name: `${String(i + 1).padStart(2, '0')}_${safe(names[i])}.csv`, data: enc.encode(csv(s)) })), m.at);
        save(new Blob([z], { type: 'application/zip' }), exportName(m, 'csv.zip'));
      }
    } catch (e) {
      note.textContent = 'Export failed: ' + (e instanceof Error ? e.message : String(e));
    } finally { b.disabled = false; }
  };
  const x = el('button', { type: 'button', title: 'Every grid of this tab as an Excel workbook, with its colours and number formats' }, 'Export .xlsx');
  const c = el('button', { type: 'button', title: 'The same rows as CSV (several grids: a .zip of one CSV each)' }, 'Export CSV');
  x.addEventListener('click', () => { void run(x, 'xlsx'); });
  c.addEventListener('click', () => { void run(c, 'csv'); });
  const sum = !ctx.instance && ctx.tab === 'summary' ? [summaryExport(ctx, root, note), ' '] : [];
  return el('span', { class: 'export' }, ...sum, x, ' ', c, ' ', note);
}
