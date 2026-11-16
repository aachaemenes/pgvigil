// The export of a tab (task 54; the workbook as DBA Dash writes its own, task 153 and parity P03): every grid on the page
// as a sheet of one .xlsx workbook, each grid with rows a real Excel table (sortable, filterable, no table style) under
// a blue header row in white bold, every cell in the colour the screen gives it (a status cell, a badge, a dot, a data
// bar's fill, a warning or critical mark in it, a cell class of the page's own rule; the worst when it holds several)
// in a plain (not bold) font and a value cell in the colour its row shows beside it, a link cell as DBA Dash's link
// column (a light fill, the link blue), no other cell filled, the numbers as numbers (a count or a decimal General, a
// share '0.0%', a time 'yyyy-MM-dd HH:mm': DBA Dash's formats), no frozen pane, and each column as wide as its widest
// cell the way DBA Dash's writer measures it (ClosedXML AdjustToContents, capped at 150); a
// column hidden with the grid tools (gridtools.ts) is left out, as on the screen; an 'About' sheet last (the instance,
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
import { Col, cellText, el, fmtBytes, fmtNum, fmtSecs, fmtTime, gridModel, readWindowWords, showMenu } from './ui';
import { cutReads } from './api';
import { readRows } from './export_colours';
import { ownName, sheetNames, sheetTitle } from './export_names';
import { drawingRels, drawingXml, pictureOf } from './export_chart';
import type { ChartNumbers, PictureBox } from './export_chart';
import { cellLook, gridHeadLook, headLook, withDot } from './export_page';
import type { LookCache, PageSheet } from './export_page';

export type Status = 'ok' | 'warn' | 'crit' | 'none' | 'ack';
export type Kind = 'text' | 'int' | 'dec' | 'bytes' | 'secs' | 'nsecs' | 'msecs' | 'pct' | 'date' | 'bool' | 'days' | 'day';   // bool: v 1 or 0, written as an Excel boolean (P3)   // days: a count of days the page writes 'n days'   // day: a date alone (v its Excel serial, stamp 'YYYY-MM-DD')
export interface Cell { v: string | number; kind: Kind; status?: Status; link?: boolean; head?: boolean; text: string; stamp?: string;   // link: the screen draws the cell as a link   // head: a heading inside a sheet (written in the header row's style)   // stamp: a time's local text for the CSV
  per?: string;   // a size per a time ('381.5 MB / day': kind 'bytes', per 'day')
  dp?: number;   // (X13) a grid sheet's number shown with the decimals its column shows on the page: '0.0' for 1 (a share: '0%' for 0); the value stays exact
  look?: Look;   // the cell's look as the page's own CSS paints it (export_colours.ts, export_page.ts): when set, the file writes it and nothing else
  runs?: { text: string; color?: string; bold?: boolean; italic?: boolean; underline?: boolean; pt?: number }[];   // rich text: words in their own colours (a dot's run before a cell's words)
  jump?: number;   // the page sheet: a link to grid k's own sheet ('{sheet}' in the words is its name)
  fmt?: string;   // the page sheet (E2-15, F2): the number format that shows the value as the page's words ('#,##0.0', a size's unit, the page's date form)
  sheets?: number[];   // the page sheet: '{sheet:k}' in the words is grid k's sheet name
  grp?: boolean }   // (X7) the page's figure groups its thousands ('1,672.00'): its column's fixed decimals grouped ('#,##0.00')
// Look: a cell's look in the file: its fill and text colour ('RRGGBB'), weight, slant, underline, size in points, wrapped
// words, a thick left border in a colour (a tile's stripe)
export interface Look { fill?: string; color?: string; bold?: boolean; italic?: boolean; underline?: boolean; pt?: number; wrap?: boolean; border?: string; valign?: 'top' | 'middle'; halign?: 'right' | 'center' }   // valign: as the page aligns the cell (a cell with a look and none: top)
export interface Section { name: string; cols: string[]; rows: Cell[][]; note?: string; heads?: Look[]; sample?: string; within?: string; own?: boolean; items?: boolean; read?: string }   // own: the name is the page's own (data-sheet: kept whole, export_names.ts ownName)   // items: an Item | Value | Status section (itemSection)   // within: the heading above the one that names it (export_names.ts sheetNames: a name taken in full falls back on it)   // note: the page's 'the newest N of M' line above the grid   // heads: the header cells' looks as the page draws them   // sample: the mark of a stored sample's grid (a demo instance's community tool, community.ts data-sample): in About's line of its sheet and a CSV's first line (a sample is never mailed: only pgvigil demo -serve shows one, and it sends no mail)   // read: a list cut to its part's reach, what it read ('This list reads the newest 31 days of this window: ...'): in its note on 'About' and the line above its CSV's header

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

export function typed(raw: unknown, text: string): Pick<Cell, 'v' | 'kind' | 'stamp' | 'per'> {
  if (text === '') return { v: '', kind: 'text' };
  // (P3, the lead 22:34) a boolean the page writes as its yes / no or true / false: an Excel boolean on a grid sheet
  // (DBA Dash's file: TRUE / FALSE cells); the page sheet keeps the page's words (export_page.ts gridBlock)
  if (typeof raw === 'boolean' && [raw ? 'yes' : 'no', String(raw)].includes(text.toLowerCase())) return { v: raw ? 1 : 0, kind: 'bool' };
  // (X9) a cell the page writes as yes or no whatever lies under it (a count shown 'no' when it is zero): the boolean of the word
  const yn = yesNo(text);
  if (yn) return yn;
  if (typeof raw === 'string' && isoTime.test(raw) && norm(fmtTime(raw)) === text) {
    const d = new Date(raw);
    if (!isNaN(d.getTime())) return { v: excelDate(d), kind: 'date', stamp: localStamp(d) };
  }
  // (X7, X8) a date alone the server sends as text ('2026-11-11', a date column) and the page writes as it is: a date cell
  // under 'yyyy-MM-dd'
  if (typeof raw === 'string' && raw.slice(0, 10) === text) { const day = dayCell(text); if (day) return day; }
  // a text that only looks like a number (a role or database named '0042', a '+5') is kept as the text it is
  if (typeof raw === 'string' && /^[+0]\d/.test(raw)) return { v: text, kind: 'text' };
  const n = numeric(raw);
  if (n !== undefined) {
    if (norm(fmtBytes(raw)) === text) return { v: n, kind: 'bytes' };
    // a size a page writes in its own unit with the locale's number ('1,536 MB', '100,5 MB': fmtNum(v) + ' MB'): bytes
    const sw = /^(.+) (B|KB|MB|GB|TB|PB)$/.exec(text);
    if (sw && norm(fmtNum(n)) === sw[1]) return { v: n * 1024 ** UNITS.indexOf(sw[2]), kind: 'bytes' };
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
    // (X7) a count of days as the pages write it ('233.3 days', a badge's 'off (0 days)', storage.ts's 'over 10 years' past
    // 3,650): the days, a number in its column's one unit (gridSection: the header says '(days)')
    const dm = /^(?:off \()?(.+) days?\)?$/.exec(text);
    if (dm && norm(fmtNum(n)) === dm[1] || /^over \d+ years$/.test(text) && n > 3650) return { v: n, kind: 'days' };
    // (X7) a size per day as the pages write it ('381.5 MB / day', '-2.0 GB / day'): the bytes, its unit chosen per column
    const rm = /^(.+) \/ day$/.exec(text);
    if (rm && norm(n < 0 ? '-' + fmtBytes(-n) : fmtBytes(n)) === rm[1]) return { v: n, kind: 'bytes', per: 'day' };
    if (norm(fmtNum(raw)) === text || String(raw) === text) return { v: n, kind: Number.isInteger(n) ? 'int' : 'dec' };
    // a figure the page rounds to a whole number first ('61,075' for 61074.6: fmtNum(Math.round(v))): the raw value
    if (norm(fmtNum(Math.round(n))) === text) return { v: n, kind: Number.isInteger(n) ? 'int' : 'dec' };
    // a figure the page writes in a fixed count of decimals ('12.0': DB Space's one decimal always, DBA Dash's; fr-FR
    // '12,0'; a custom report's column of set decimals): the number, a decimal even when it is whole, so its column's
    // format shows the decimals the page shows ('0.0')
    const fx = digitsOf(text).split('.')[1]?.length ?? 0;
    if (fx >= 1 && fx <= 6 && norm(n.toLocaleString(undefined, { minimumFractionDigits: fx, maximumFractionDigits: fx })) === text) return { v: n, kind: 'dec' };
  }
  return { v: text, kind: 'text' };
}

// bareNumber: words that are a bare number in the locale ('3', '1,234', '5432'), as that number
export function bareNumber(text: string): Pick<Cell, 'v' | 'kind'> | undefined {
  const d = digitsOf(text);
  if (!d || !(norm(fmtNum(Number(d))) === text || /^-?\d+$/.test(text)) || /^[+0]\d/.test(text)) return undefined;
  const k = Number(d);
  return { v: k, kind: Number.isInteger(k) ? 'int' : 'dec' };
}

// the locale's grouping and decimal characters, learnt from fmtNum (',' and '.' in en-US, U+202F and ',' in fr-FR)
const sep = (() => { const t = fmtNum(1234567.5); return { group: t[1], dec: t[t.length - 2] }; })();
// grouped: a page figure written with the locale's thousands separator ('1,672.00'; fr-FR '1 672,00', its narrow space
// read as a space); a figure the page writes ungrouped ('1672.5', a port '5432') is not
const groupRe = new RegExp('\\d' + (/\s/.test(sep.group) ? '[\\s\\u202f\\u00a0]' : sep.group.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')) + '\\d{3}(?!\\d)');
const grouped = (t: string) => groupRe.test(t);
// digitsOf: a number as the locale wrote it, back to JavaScript's form ('1,234.5' or '1 234,5' -> '1234.5'); '' = not one
function digitsOf(t: string): string {
  const d = t.split(sep.group).join('').split(sep.dec).join('.').replace(/[\s\u202f\u00a0']/g, '');
  return /^-?\d+(\.\d+)?$/.test(d) ? d : '';
}

// yesNo: a cell whose whole text is yes or no, as the boolean of the word (X9: DBA Dash writes booleans as booleans)
export function yesNo(text: string): Pick<Cell, 'v' | 'kind'> | undefined {
  return /^(yes|no)$/i.test(text) ? { v: /^yes$/i.test(text) ? 1 : 0, kind: 'bool' } : undefined;
}
// dayCell: a date alone as the pages write it ('2026-11-11', the slow page's per-day grid, a chart's day): a date cell
// under 'yyyy-MM-dd' (X7, X8), never a false 00:00
export function dayCell(text: string): Pick<Cell, 'v' | 'kind' | 'stamp'> | undefined {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
  if (!m) return undefined;
  const t = Date.UTC(+m[1], +m[2] - 1, +m[3]);
  return isNaN(t) ? undefined : { v: t / 86400000 + 25569, kind: 'day', stamp: text };
}
// shownTime: a time as the page shows it (tz.ts fmt: toLocaleString with hour12 false, the locale's order of the parts) back
// to its Excel serial and its 'YYYY-MM-DD HH:MM:SS' stamp - the wall clock the screen shows, in the display zone; undefined
// for any other text
let timeRe: { re: RegExp; order: string[] } | undefined;
export function shownTime(text: string): Pick<Cell, 'v' | 'kind' | 'stamp'> | undefined {
  if (!timeRe) {
    const parts = new Intl.DateTimeFormat(undefined, { hour12: false, year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric', timeZone: 'UTC' }).formatToParts(new Date(Date.UTC(2026, 0, 2, 3, 4, 5)));
    const order: string[] = [];
    const re = parts.map(p => p.type === 'literal' ? p.value.replace(/\s+/g, ' ').replace(/[.*+?^${}()|[\]\\]/g, '\\$&').replace(/ /g, '\\s*') : (order.push(p.type), '(\\d{1,4})')).join('');
    timeRe = { re: new RegExp('^' + re + '$'), order };
  }
  const m = timeRe.re.exec(text);
  if (!m) return undefined;
  const at: Record<string, number> = {};
  timeRe.order.forEach((k, i) => { at[k] = Number(m[i + 1]); });
  const { year: y, month: mo, day: d, minute: mi, second: sec } = at;
  const h = at.hour === 24 ? 0 : at.hour;
  if (!(y > 1900 && mo >= 1 && mo <= 12 && d >= 1 && d <= 31 && h <= 23 && mi <= 59 && sec <= 59)) return undefined;
  const pad = (x: number) => String(x).padStart(2, '0');
  return { v: Date.UTC(y, mo - 1, d, h, mi, sec) / 86400000 + 25569, kind: 'date', stamp: `${y}-${pad(mo)}-${pad(d)} ${pad(h)}:${pad(mi)}:${pad(sec)}` };
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

// ---- the page sheet's number formats (E2-15, F2): a number shows the page's own words ------------------------
// numFmtOf: a count or a decimal as the page writes it - the locale's grouping where the page groups (a number of 1,000
// or more written with more than its digits), its decimals as many as the page shows; Excel and LibreOffice put the
// viewer's own grouping and decimal marks in place of ',' and '.'
export function numFmtOf(n: number, text: string): string {
  const dm = new RegExp('\\' + sep.dec + '(\\d+)$').exec(text.replace(/\s/g, ''));
  const k = dm ? dm[1].length : 0;
  const grouped = Math.abs(n) >= 1000 && !/^-?\d+$/.test(text.split(sep.dec)[0]);
  return (grouped ? '#,##0' : '0') + (k ? '.' + '0'.repeat(k) : '');
}
// sizeOf: a size as fmtBytes writes it ('312.6 MB', '7 B': a '.' decimal whatever the locale, ui.ts:29) - its unit,
// its power of 1024 and its decimals; undefined for other words
const UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
export function sizeOf(text: string): { unit: string; pow: number; k: number } | undefined {
  const m = /^-?\d+(?:\.(\d+))?\s(B|KB|MB|GB|TB|PB)$/.exec(text);
  return m ? { unit: m[2], pow: UNITS.indexOf(m[2]), k: m[1]?.length ?? 0 } : undefined;
}
// decimalsOf (X13): how many decimals a page's figure shows - a raw number the page prints as it is (v: the cell's value;
// JavaScript's form in any language), a size as fmtBytes writes it (under 1024, at most one decimal: '1.6 GB', '7 B', a
// rate '-2.0 GB / day'), a number in the locale's form with a unit or a percent sign ('12.35 ms', '1 536,5 MB', de-DE's
// '1.536 MB', '12,5 %', '233.3 days', 'off (0 days)'), a bare number ('17.35', '61,075'); undefined for words with no figure
// and for fmtSecs's whole units ('1m 5s': the page cuts the seconds it does not show, a format would round them)
export function decimalsOf(text: string, v?: number | string): number | undefined {
  const t = norm(text).replace(/^off \((.*)\)$/, '$1');
  if (typeof v === 'number' && String(v) === t && !/e/i.test(t)) return (t.split('.')[1] ?? '').length;
  const bare = t.replace(/ \/ day$/, '');
  if (/^-?\d{1,4}(?:\.\d)? (?:B|KB|MB|GB|TB|PB)$/.test(bare)) return sizeOf(bare.replace(/^-/, ''))!.k;
  if (/^-?\d+[dhms](?: \d+[hms])*$/.test(t)) return undefined;
  const m = /^[+-]?(.*?)(?: (?:%|ms|s|min|days?|B|KB|MB|GB|TB|PB)(?: \/ day)?)?$/.exec(t);
  const d = m ? digitsOf(m[1]) : '';
  return d ? (d.split('.')[1] ?? '').length : undefined;
}
// dateFmt: the page's date-and-time form (tz.ts fmt: toLocaleString with hour12 false) as an Excel format code, read
// from the locale's own parts of a date whose month, day and hour are one digit (a part written with two digits there
// is padded: 'mm', else 'm'); the zone does not change the parts' order
let dateCode = '';
export function dateFmt(): string {
  if (dateCode) return dateCode;
  const sample = new Date(Date.UTC(2026, 0, 2, 3, 4, 5));
  const parts = new Intl.DateTimeFormat(undefined, { hour12: false, year: 'numeric', month: 'numeric', day: 'numeric', hour: 'numeric', minute: 'numeric', second: 'numeric', timeZone: 'UTC' }).formatToParts(sample);
  const code: Record<string, (v: string) => string> = { year: v => v.length === 2 ? 'yy' : 'yyyy', month: v => v.length === 2 ? 'mm' : 'm', day: v => v.length === 2 ? 'dd' : 'd',
    hour: v => v.length === 2 ? 'hh' : 'h', minute: () => 'mm', second: () => 'ss' };
  // a literal of separators only ('/', ':', ', ', ' ', '.', '-') stands bare; any other is quoted
  dateCode = parts.map(p => code[p.type] ? code[p.type](p.value) : /^[/:,. -]*$/.test(p.value) ? p.value : '"' + p.value.replace(/"/g, '') + '"').join('');
  return dateCode;
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

// (No colour is carried from a judging cell to a value cell: the file follows the page, which leaves those value cells
// plain; design line C4, the export's E2 answer.)

// linkOf: a plain cell the screen draws as a link (a name that opens its page); a status cell keeps its status colours
const linkOf = (td: Element) => !td.classList.contains('status') && !!td.querySelector('a[href]') || undefined;

// a status cell that shows only its colour (a green Summary cell) carries its words in data-text; a statement cell
// shown as its first characters (sqlview.ts) carries the whole text in data-full, which the export writes instead
export const cellWords = (e: Element): string => text(e);
const text = (e: Element) => e.querySelector('[data-full]')?.getAttribute('data-full')
  ?? ((e.textContent ?? '').replace(/\s+/g, ' ').trim() || (e.querySelector('[data-text]')?.getAttribute('data-text') ?? ''));

// a heading's own words, without its 'what is this' button (sqlview.ts): they name a sheet and a CSV file
export const headingText = (e: Element): string => {
  const c = e.cloneNode(true) as Element;
  c.querySelectorAll('.whatis, .filter-btn, .chart-reset').forEach(b => b.remove());   // a drag's 'Reset zoom' link is no word of it
  return text(c);
};

// readGrid: a grid's header and its rows as cells. A column hidden with the grid tools (its header carries
// data-gt-hidden) is left out, as DBA Dash's export leaves out a hidden column; all = every column (the tools' own reads).
export function readGrid(table: HTMLTableElement, all = false): Pick<Section, 'cols' | 'rows' | 'heads'> {
  const ths = [...table.querySelectorAll(':scope > thead > tr:first-child > th')];
  const cols = ths.map(headingText);   // a header's words without its filter button (ui.ts grid)
  const numCol = ths.map(h => h.classList.contains('num'));
  const m = gridModel(table);
  // every row of the grid as filtered and sorted, also the ones past its page that are not drawn (ui.ts GRID_PAGE); a
  // statement's open History panel (a 'trend-row' under its row) is no data row: its own grid is a sheet of its own
  const trs = (m?.allRows ? m.allRows() : [...table.querySelectorAll<HTMLTableRowElement>(':scope > tbody > tr')]).filter(tr => !tr.classList.contains('trend-row'));
  const data = m?.rows();
  const keys: (Col | undefined)[] = m && m.cols.length === cols.length ? m.cols : cols.map(() => undefined);
  // each cell's look as the page's CSS paints it: a drawn row where it is, a row past the grid's page in a hidden copy of
  // the table (readRows), one read per cell shape (cache)
  const cache: LookCache = new Map();
  const looks = readRows(table, trs, tr => [...tr.children].map(td => cellLook(td, table, cache)));
  const rows = trs.map((tr, i) => [...tr.children].map((td, j) => {
    const t = text(td);
    const raw = data && data.length === trs.length && keys[j] ? data[i][keys[j]!.key] : undefined;
    const c: Cell = { ...(raw !== undefined ? typed(raw, t) : numCol[j] ? fromText(t) : yesNo(t) ?? dayCell(t) ?? { v: t, kind: 'text' as Kind }), status: statusOf(td), link: linkOf(td), text: t };
    // a status cell's model holds its level (the fleet Summary's 0 / 1 / 2), not its figure: words that are a bare number
    // are that number ('3' collection errors; on DBA Dash 4.25.0 '3' collections at warning or critical), as DBA Dash
    // writes its 'DBA Dash Errors (24hrs)' / 'Collection Health'
    if (td.classList.contains('status') && typeof c.v === 'string') { const b = bareNumber(t); if (b) Object.assign(c, b); }
    const l = looks[i]?.[j];
    return l ? withDot({ ...c, look: l.look }, l) : c;
  }));
  const heads = ths.map(th => headLook(th, table));
  const keep = ths.map(h => all || !h.hasAttribute('data-gt-hidden'));
  if (keep.every(Boolean)) return { cols, rows, heads };
  return { cols: cols.filter((_, j) => keep[j]), rows: rows.map(r => r.filter((_, j) => keep[j] ?? true)), heads: heads.filter((_, j) => keep[j]) };
}

function readProps(table: HTMLTableElement): Pick<Section, 'cols' | 'rows'> {
  const rows = [...table.querySelectorAll('tr')].map(tr => {
    const th = tr.querySelector('th'), td = tr.querySelector('td');
    const a = th ? text(th) : '', b = td ? text(td) : '';
    const la = th ? cellLook(th, table) : undefined, lb = td ? cellLook(td, table) : undefined;
    const ca: Cell = { v: a, kind: 'text' as Kind, text: a, ...(la ? { look: la.look } : {}) };
    const cb: Cell = { v: b, kind: 'text' as Kind, status: td ? statusOf(td) : undefined, text: b, ...(lb ? { look: lb.look } : {}) };
    return [la ? withDot(ca, la) : ca, lb ? withDot(cb, lb) : cb];
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
  const hs = headings(fallback);
  const out: { sec: Section; el: Element }[] = [];
  let cardHead: Look | undefined;   // a property card's sheet: its 'item | value' header in the page's grid-header look
  const cardHeads = () => { const l = cardHead ??= (root instanceof Element ? gridHeadLook(root) : undefined); return l ? [l, l] : undefined; };
  for (const e of root.querySelectorAll(empties ? 'h2, h3, h4, h5, table.grid, table.props, p.empty[data-cols]' : 'h2, h3, h4, h5, table.grid, table.props')) {
    if (e.tagName !== 'TABLE' && e.tagName !== 'P') { hs.see(e); continue; }
    const { heading, within, own } = hs.of(e);
    // a grid with no row (ui.ts grid: its note carries its columns' names): a sheet of its header row alone, as DBA Dash
    // exports an empty grid (CommonShared.cs SaveDataGridViewsToXLSX: a sheet per grid, the header row, then the rows)
    if (e.tagName === 'P') {
      let cols: unknown = [];
      try { cols = JSON.parse((e as HTMLElement).dataset.cols ?? '[]'); } catch { cols = []; }
      if (Array.isArray(cols) && cols.length) {
        // DBA Dash writes the visible columns' headers only: a column the grid tools hide stays out here too
        const all = cols.map(String), hid = hiddenOfEmpty(e, all);
        // the header row the page draws for it (ui.ts: a .grid-empty table beside the note): its cells' looks
        const drawn = e.parentElement?.querySelector(':scope > table.grid-empty');
        const ths = drawn ? [...drawn.querySelectorAll('th')] : [];
        const heads = ths.length === all.length ? ths.map(th => headLook(th, drawn!)).filter((_, j) => !hid.has(j)) : undefined;
        const sample = e.closest('[data-sample]')?.getAttribute('data-sample') || undefined;
        // a list whose part read only the newest part of a long window: its words (ui.ts grid) in the note and the CSV
        const rd = e.closest('.empty-grid')?.querySelector('.read-window');
        const read = rd ? text(rd) : undefined;
        out.push({ sec: { name: heading, within, ...(own ? { own } : {}), cols: all.filter((_, j) => !hid.has(j)), rows: [], note: [sample, read, text(e)].filter(Boolean).join('; ') || undefined, sample, ...(read ? { read } : {}), ...(heads ? { heads } : {}) }, el: e });
      }
      continue;
    }
    const t = e as HTMLTableElement;
    // a 'the newest 500 of 1,234 samples' line right above the grid rides into About's line of its sheet: the rows taken are not all
    // ui.ts grid: table in .grid-wrap in .grid-box, whose first child is the 'n of m rows shown (filtered)' line
    const wrap = t.parentElement?.classList.contains('grid-wrap') ? t.parentElement : t;
    const box = wrap.parentElement?.classList.contains('grid-box') ? wrap.parentElement : wrap;
    const prev = box.previousElementSibling;
    const filtered = box !== wrap ? text(box.querySelector('.filter-count') ?? box) : '';
    // a stored sample's grid carries its mark first: never read as the instance's own data in a file
    const sample = t.closest('[data-sample]')?.getAttribute('data-sample') || undefined;
    // a list whose part read only the newest part of a long window (ui.ts grid: data-read-from / -to): its sheet's note
    // and its CSV's first line say what was read, never the page's whole window
    const readWin = t.dataset.readFrom && t.dataset.readTo ? `This list reads ${readWindowWords({ from: t.dataset.readFrom, to: t.dataset.readTo })}.` : undefined;
    const notes = [sample ?? '', readWin ?? '', prev && prev.matches('p.meta') && /\d\S* of \d/.test(text(prev)) ? text(prev) : '', box !== wrap && /filtered|the stretch/.test(filtered) ? filtered : ''].filter(Boolean);
    const note = notes.length ? notes.join('; ') : undefined;
    const read = t.classList.contains('grid') ? readGrid(t) : { ...readProps(t), ...(cardHeads() ? { heads: cardHeads() } : {}) };
    out.push({ sec: { name: heading, within, ...(own ? { own } : {}), ...read, note, sample, ...(readWin ? { read: readWin } : {}) }, el: t });
  }
  distinct(out);
  return out;
}

// headings: the headings above a section as the walk meets them (h2 to h5), by level. A section is named by the nearest
// heading, its 'within' the one above that; a heading inside a region of its own (the Summary's 'Needs attention' strip)
// names the sections of that region only (the sections after it keep the heading before it); a section the page names
// itself - inside an element with data-sheet (a disclosure per job or per check under one heading, a totals grid under its
// grid's heading) that holds no heading the walk met - takes that name, the heading its 'within'; one that holds headings
// of its own (a pgAgent job's 'Steps' and 'Step runs') names each section by both: the page's name, then the heading's
// title ('jobA Steps': ownName), the heading above the disclosure its 'within'
function headings(fallback: string) {
  const lv: string[] = [];
  let outer = fallback, up: string | undefined, last: Element | undefined;
  let inner: { text: string; within: Element; up: string } | undefined;
  return {
    see(e: Element) {
      const t = headingText(e) || fallback, region = e.closest('[role=region]');
      if (region) { inner = { text: t, within: region, up: outer }; return; }
      const n = Number(e.tagName.slice(1));
      lv.length = n; lv[n] = t; outer = t; up = lv.slice(0, n).filter(Boolean).pop(); inner = undefined; last = e;
    },
    of(e: Element): { heading: string; within?: string; own?: boolean } {
      const inR = !!inner && inner.within.contains(e);
      const heading = inR ? inner!.text : outer, within = inR ? inner!.up : up;
      const own = e.closest('[data-sheet]'), name = own?.getAttribute('data-sheet')?.trim() ?? '';
      if (!name) return { heading, within };
      return last && own!.contains(last) ? { heading: ownName(name, heading), within, own: true } : { heading: name, within: heading, own: true };
    },
  };
}

// distinct (X2: a sheet's name says what it holds, never ' (2)'): sections that share a heading, each its own sheet - a
// property card takes ' properties' after the heading and a row of tiles ' tiles' (a grid keeps the heading, as DBA Dash
// names a grid by its title); a section the page names itself (a tile row's aria-label, data-sheet) keeps its name
function distinct(all: { sec: Section; el: Element }[]): void {
  const key = (f: { sec: Section }) => sheetTitle(f.sec.name).toLowerCase();
  const n = new Map<string, number>();
  for (const f of all) n.set(key(f), (n.get(key(f)) ?? 0) + 1);
  for (const f of all) {
    if ((n.get(key(f)) ?? 0) < 2 || f.el.matches('[aria-label]') || f.el.closest('[data-sheet]')) continue;
    const word = f.el.matches('table.props') ? 'properties' : f.el.matches('.tiles') ? 'tiles' : '';
    if (word) f.sec = { ...f.sec, name: `${f.sec.name} ${word}` };
  }
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
// (X7, X8) a grid sheet carries DBA Dash's formats only: General, '0', '0.0%' / '0.00%' and its date; a size or a
// millisecond or seconds column reaches the writer as plain numbers in one unit (gridSection)
const fmtId: Record<Kind, number> = { text: 0, int: 0, dec: 0, bytes: 0, secs: 0, pct: 167, date: 168, nsecs: 0, msecs: 0, bool: 0, days: 0, day: 169 };
// a share the page shows with two decimals ('12.50 %'): Excel's built-in '0.00%' (10), DBA Dash's P2
const twoPlaces = (c: Cell) => /\d[.,]\d\d\s*%$/.test(c.text);
// fmtOf: a cell's number format. A count of 12 digits or more (a PostgreSQL counter: blocks hit, tuples returned) under
// Excel's built-in '0' (1): General would show it as 9.87654E+11, six digits of it; DBA Dash's writer has no such count
const fmtOf = (c: Cell) => c.kind === 'int' && typeof c.v === 'number' && Math.abs(c.v) >= 1e11 ? 1 : c.kind === 'pct' && twoPlaces(c) ? 10 : fmtId[c.kind];
const customFmts: [number, string][] = [[167, '0.0%'], [168, 'yyyy-MM-dd HH:mm'], [169, 'yyyy-MM-dd']];   // 169: a date alone (a day column), never a false 00:00

const esc = (s: string) => s.replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, '')
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function colName(i: number): string {
  let s = '';
  for (i++; i > 0; i = Math.floor((i - 1) / 26)) s = String.fromCharCode(65 + (i - 1) % 26) + s;
  return s;
}

// Styles: one cellXfs entry per (number format, fill, font, border, wrap) used; fills 0 and 1 are the two the format
// reserves. A cell with a look (the page's CSS, export_page.ts) is written in that look; the old palette (fillOf, the
// blue header) is for the grid sheets' header rows and the cells with a status but no look.
class Styles {
  private xfs = new Map<string, number>([['0|0|0|0|', 0]]);   // style 0 (a cell typed in later) plain: no alignment, Excel's bottom (X0)
  private fills = ['<fill><patternFill patternType="none"/></fill>', '<fill><patternFill patternType="gray125"/></fill>'];
  private fonts = ['<font><sz val="11"/><name val="Calibri"/></font>'];
  private borders = ['<border><left/><right/><top/><bottom/><diagonal/></border>'];
  private fillIds = new Map<string, number>();
  private fontIds = new Map<string, number>([['|0|0|0|11', 0]]);
  private borderIds = new Map<string, number>();
  private fill(argb: string): number {
    let i = this.fillIds.get(argb);
    if (i === undefined) { i = this.fills.push(`<fill><patternFill patternType="solid"><fgColor rgb="${argb}"/><bgColor indexed="64"/></patternFill></fill>`) - 1; this.fillIds.set(argb, i); }
    return i;
  }
  private font(argb: string, bold: boolean, italic = false, underline = false, pt = 11): number {
    const k = `${argb}|${+bold}|${+italic}|${+underline}|${pt}`;
    let i = this.fontIds.get(k);
    if (i === undefined) {
      i = this.fonts.push(`<font>${bold ? '<b/>' : ''}${italic ? '<i/>' : ''}${underline ? '<u/>' : ''}<sz val="${pt}"/>${argb ? `<color rgb="${argb}"/>` : ''}<name val="Calibri"/></font>`) - 1;
      this.fontIds.set(k, i);
    }
    return i;
  }
  private border(argb: string): number {
    let i = this.borderIds.get(argb);
    if (i === undefined) { i = this.borders.push(`<border><left style="thick"><color rgb="${argb}"/></left><right/><top/><bottom/><diagonal/></border>`) - 1; this.borderIds.set(argb, i); }
    return i;
  }
  // al: the cell's alignment - '' none (a cell of the export's own: Excel's bottom), 't' top, 'm' middle, then 'r' right
  // or 'c' centred as the page aligns it (F2), then a 'w' when it wraps
  private xf(fmt: number, fill: number, font: number, border: number, al: string): number {
    const k = `${fmt}|${fill}|${font}|${border}|${al}`;
    let i = this.xfs.get(k);
    if (i === undefined) { i = this.xfs.size; this.xfs.set(k, i); }
    return i;
  }
  id(fmt: number, status?: Status, head = false, link = false): number {
    const fill = head ? this.fill(headFill) : status ? this.fill(fillOf[status]) : link ? this.fill(linkFill) : 0;
    const font = head ? this.font('FFFFFFFF', true) : status ? this.font(fontOf[status], false) : link ? this.font(linkFont, false) : 0;
    return this.xf(fmt, fill, font, 0, '');
  }
  // look: a cell in the page's look ('RRGGBB' colours)
  look(fmt: number, l: Look): number {
    const fill = l.fill ? this.fill('FF' + l.fill) : 0;
    const plain = !l.color && !l.bold && !l.italic && !l.underline && !l.pt;
    const font = plain ? 0 : this.font(l.color ? 'FF' + l.color : '', !!l.bold, !!l.italic, !!l.underline, l.pt ?? 11);
    return this.xf(fmt, fill, font, l.border ? this.border('FF' + l.border) : 0, (l.valign === 'middle' ? 'm' : 't') + (l.halign === 'right' ? 'r' : l.halign === 'center' ? 'c' : '') + (l.wrap ? 'w' : ''));
  }
  // code: a number format of the page sheet's own (F2): its id, 171 on (165-170 are the fixed ones)
  private codes = new Map<string, number>();
  code(f: string): number {
    let i = this.codes.get(f);
    if (i === undefined) { i = 171 + this.codes.size; this.codes.set(f, i); }
    return i;
  }
  xml(): string {
    const xfs = [...this.xfs.keys()].map(k => {
      const [n, f, t, b, a] = k.split('|');
      return `<xf numFmtId="${n}" fontId="${t}" fillId="${f}" borderId="${b}" xfId="0"${n !== '0' ? ' applyNumberFormat="1"' : ''}${f !== '0' ? ' applyFill="1"' : ''}${t !== '0' ? ' applyFont="1"' : ''}${b !== '0' ? ' applyBorder="1"' : ''}`
        + (a ? ` applyAlignment="1"><alignment${a[1] === 'r' ? ' horizontal="right"' : a[1] === 'c' ? ' horizontal="center"' : ''} vertical="${a.startsWith('m') ? 'center' : 'top'}"${a.endsWith('w') ? ' wrapText="1"' : ''}/></xf>` : '/>');
    });
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
      + '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      + `<numFmts count="${customFmts.length + this.codes.size}">${[...customFmts, ...[...this.codes].map(([f, i]) => [i, f] as [number, string])].map(([i, f]) => `<numFmt numFmtId="${i}" formatCode="${esc(f)}"/>`).join('')}</numFmts>`
      + `<fonts count="${this.fonts.length}">${this.fonts.join('')}</fonts>`
      + `<fills count="${this.fills.length}">${this.fills.join('')}</fills>`
      + `<borders count="${this.borders.length}">${this.borders.join('')}</borders>`
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
// textPx: the pixels a line of text takes in Calibri 11 (a character past ASCII: Carlito's Latin average, a wide one an em);
// cap: stop past 1,200 px (the width rule's 150 characters are 1,050 px), off for a wrapped line's count or a flowed segment
export function textPx(s: string, bold: boolean, cap = true): number {
  const t = bold ? ADV_B : ADV;
  let u = 0;
  for (const ch of s) {
    const c = ch.codePointAt(0) ?? 32;
    u += c >= 32 && c <= 126 ? t[c - 32] : c >= 0x2e80 ? 2048 : bold ? 1030 : 1013;
    if (cap && u * PX > MAX_WIDTH * 8) break;   // past the cap: the rest changes nothing to a width
  }
  return u * PX;
}
// linePx: a text cell's lines in pixels as written, each run at its own size and weight (a rich-text cell: a tile's large
// value and its small label on one line), the whole text measured (no cap)
export function linePx(c: Cell): number[] {
  const runs = c.runs ?? [{ text: String(c.v), bold: c.look?.bold, pt: c.look?.pt }];
  const out = [0];
  for (const r of runs) {
    String(r.text).split(/\r?\n/).forEach((part, k) => {
      if (k > 0) out.push(0);
      out[out.length - 1] += textPx(part, !!(r.bold ?? c.look?.bold), false) * (r.pt ?? c.look?.pt ?? 11) / 11;
    });
  }
  return out;
}
// shown: the text Excel shows for a cell under its format (what the width is measured on)
export function shown(c: Cell): string {
  if (typeof c.v !== 'number') return c.v.split(/\r?\n/).reduce((a, b) => b.length > a.length ? b : a, '');
  const n = c.v;
  // (X13) under the column's decimals: Excel's text of it (a negative figure keeps its minus also where it rounds to zero:
  // '-0.0')
  if (c.dp !== undefined) {
    const x = c.kind === 'pct' ? n * 100 : n;
    // a grouped column ('#,##0' ..) is drawn with its thousands separators: measured with them
    const t = Math.abs(x).toFixed(c.dp), [ip, fp] = t.split('.');
    const body = c.grp ? ip.replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (fp !== undefined ? '.' + fp : '') : t;
    return (x < 0 ? '-' : '') + body + (c.kind === 'pct' ? '%' : '');
  }
  switch (c.kind) {
    case 'date': return (c.stamp ?? '').slice(0, 16);
    case 'day': return (c.stamp ?? '').slice(0, 10);
    case 'bool': return n ? 'TRUE' : 'FALSE';   // as Excel draws a boolean
    case 'pct': return (n * 100).toFixed(twoPlaces(c) ? 2 : 1) + '%';
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

// Sheet: a grid's sheet (data: its header row, then its rows; table: the id of its Excel table part), the 'About'
// sheet, or the page sheet (page: its rows written as they are from row 1, no header row); heads: the
// header cells' looks as the page draws them; freeze: the rows that stay on screen; widths: the columns' widths as given
interface Sheet { name: string; head: string[]; rows: Cell[][]; data: boolean; table?: number; heads?: Look[]; page?: boolean; freeze?: number; widths?: number[]; drawing?: boolean }   // drawing: the page sheet's pictures (rId1 of its rels)

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
// (P2) an empty grid's table holds its header and ONE empty row (a table needs a data row; DBA Dash writes the same)
function tableXml(id: number, head: string[], nrow: number): string {
  const ref = `A1:${colName(head.length - 1)}${Math.max(nrow, 1) + 1}`;
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + `<table xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" id="${id}" name="Table${id}" displayName="Table${id}" ref="${ref}" totalsRowShown="0">`
    + `<autoFilter ref="${ref}"/><tableColumns count="${head.length}">${head.map((h, j) => `<tableColumn id="${j + 1}" name="${esc(h)}"/>`).join('')}</tableColumns>`
    + '<tableStyleInfo showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>';   // DBA Dash's: no style name, so no stripe is drawn
}

function sheetXml(sh: Sheet, st: Styles, sst: Shared, names: string[] = []): string {
  const ncol = Math.max(sh.head.length, ...sh.rows.map(r => r.length), 1);
  const head = sh.table ? tableHead(sh.head, ncol) : sh.head;
  const widths = sh.widths ? Array.from({ length: ncol }, (_, j) => sh.widths![j] ?? 0)
    : Array.from({ length: ncol }, (_, j) => colWidth([{ text: head[j] ?? '', head: true }, ...sh.rows.map(r => ({ text: r[j] ? shown(r[j]) : '', head: !!r[j]?.head }))]));
  const name = (c: Cell, s: string) => s.replace(/\{sheet(?::(\d+))?\}/g, (_, k) => names[(k !== undefined ? Number(k) : c.jump ?? -1) + 1] ?? '');
  const runXml = (r: NonNullable<Cell['runs']>[number]) => `<r><rPr>${r.bold ? '<b/>' : ''}${r.italic ? '<i/>' : ''}${r.underline ? '<u/>' : ''}<sz val="${r.pt ?? 11}"/>${r.color ? `<color rgb="FF${r.color}"/>` : ''}<rFont val="Calibri"/></rPr><t xml:space="preserve">${esc(r.text)}</t></r>`;
  const cell = (ref: string, c: Cell, s: number) => {
    if (c.kind === 'bool' && typeof c.v === 'number') return `<c r="${ref}" s="${s}" t="b"><v>${c.v ? 1 : 0}</v></c>`;
    if (typeof c.v === 'number') return `<c r="${ref}" s="${s}"><v>${String(c.v).toUpperCase()}</v></c>`;
    if (c.v === '') return s ? `<c r="${ref}" s="${s}"/>` : '';
    if (c.runs?.length) return `<c r="${ref}" s="${s}" t="inlineStr"><is>${c.runs.map(r => runXml({ ...r, text: name(c, r.text) })).join('')}</is></c>`;
    // Excel holds at most 32,767 characters in a cell (a longer one opens with a repair): the rest is cut, said in the cell
    const t = name(c, c.v);
    const v = t.length > 32767 ? t.slice(0, 32700) + ' ... [cut at Excel\'s cell limit]' : t;
    return `<c r="${ref}" s="${s}" t="inlineStr"><is><t xml:space="preserve">${esc(v)}</t></is></c>`;
  };
  // (X13) a grid sheet's number under its column's decimals as the page shows them: '0', '0.0' .. (a share: Excel's '0%')
  const fmtFor = (c: Cell) => c.fmt && typeof c.v === 'number' ? st.code(c.fmt)
    : c.dp !== undefined && typeof c.v === 'number' ? (c.kind === 'pct' ? 9 : st.code((c.grp ? '#,##' : '') + (c.dp ? '0.' + '0'.repeat(c.dp) : '0'))) : fmtOf(c);
  const styleOf = (c: Cell) => c.look ? st.look(fmtFor(c), c.look) : st.id(fmtFor(c), c.status, !!c.head, c.link);
  // a row's height: as tall as its largest font and, for a cell that wraps (a header the page wraps, a long text the page
  // shows on several lines, a card's line), as its lines at the column's width (each line measured as the width rule
  // measures a cell, a line 1.36 x the font's points); a row of 11-point single lines keeps the default (no height)
  const colPx = (j: number) => Math.round((widths[j] > 0 ? widths[j] : 8.43) * 7) + 5;
  const rowHt = (r: (Cell | undefined)[]): number | undefined => {
    let pt = 11, ht = 15;
    r.forEach((c, j) => {
      if (!c) return;
      const size = Math.max(c.look?.pt ?? 11, ...(c.runs ?? []).map(x => x.pt ?? 11));
      pt = Math.max(pt, size);
      if (!c.look?.wrap || typeof c.v === 'number') return;
      const room = Math.max(10, colPx(j) - 6);
      const lines = linePx(c).reduce((n, w) => n + Math.max(1, Math.ceil((1.0738 * w + 1) / room)), 0);
      ht = Math.max(ht, Math.ceil(lines * size * 1.36));
    });
    ht = Math.max(ht, Math.ceil(pt * 1.36));
    return ht > 15 ? ht : undefined;
  };
  const rows: string[] = [];
  const jumps: string[] = [];
  const first = sh.page ? 1 : 2;
  if (!sh.page) {
    const hs = st.id(0, undefined, true);   // the header row: the export's own (X4: one header style)
    const hcell = (j: number) => {
      const l = sh.heads?.[j], s = l ? st.look(0, l) : hs;
      return sh.table ? `<c r="${colName(j)}1" s="${s}" t="s"><v>${sst.id(head[j])}</v></c>` : cell(colName(j) + '1', { v: head[j], kind: 'text', text: head[j] }, s);
    };
    const h1 = rowHt(head.map((h, j): Cell => ({ v: h, kind: 'text', text: h, ...(sh.heads?.[j] ? { look: sh.heads[j] } : {}) })));
    rows.push(`<row r="1"${h1 ? ` ht="${h1}" customHeight="1"` : ''}>${head.map((_, j) => hcell(j)).join('')}</row>`);
  }
  // a cell has the look the page gives it and no other (DBA Dash bands no rows): a plain cell is unfilled
  sh.rows.forEach((r, i) => {
    const n = i + first;
    const ht = rowHt(r);
    rows.push(`<row r="${n}"${ht ? ` ht="${ht}" customHeight="1"` : ''}>${r.map((c, j) => {
      if (!c) return '';
      if (c.jump !== undefined && names[c.jump + 1]) jumps.push(`<hyperlink ref="${colName(j)}${n}" location="${esc(`'${names[c.jump + 1].replace(/'/g, "''")}'!A1`)}" display="${esc(names[c.jump + 1])}"/>`);
      return cell(colName(j) + n, c, styleOf(c));
    }).join('')}</row>`);
  });
  const last = `${colName(ncol - 1)}${Math.max(sh.rows.length + first - 1, sh.table ? 2 : 1)}`;   // an empty table's one empty row (P2)
  const pane = sh.freeze ? `<pane ySplit="${sh.freeze}" topLeftCell="A${sh.freeze + 1}" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A${sh.freeze + 1}" sqref="A${sh.freeze + 1}"/>` : '';
  const cols = widths.map((w, j) => w > 0 ? `<col min="${j + 1}" max="${j + 1}" width="${w}" customWidth="1"/>` : '').join('');
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + `<dimension ref="A1:${last}"/>`
    + `<sheetViews><sheetView workbookViewId="0">${pane}</sheetView></sheetViews>`
    + '<sheetFormatPr defaultRowHeight="15"/>'
    + (cols ? `<cols>${cols}</cols>` : '')
    + `<sheetData>${rows.join('')}</sheetData>`
    + (!sh.page && !sh.table && sh.data ? `<autoFilter ref="A1:${last}"/>` : '')
    + (jumps.length ? `<hyperlinks>${jumps.join('')}</hyperlinks>` : '')
    + (sh.drawing ? '<drawing r:id="rId1"/>' : '')
    + (sh.table ? '<tableParts count="1"><tablePart r:id="rId1"/></tableParts>' : '')
    + '</worksheet>';
}

// sheetNames, sheetTitle: export_names.ts (pure: its unit tests run in Node)

// ---- a grid sheet as DBA Dash writes one (X0, X7, X8) ------------------------------------------------------------
const DUR: Record<string, number> = { ms: 1, s: 1000, min: 60000 };
const sizeUnit = (n: number) => { let i = 0; for (let a = Math.abs(n); a >= 1024 && i < UNITS.length - 1; a /= 1024) i++; return UNITS[i]; };
// plainCell (X0): a grid cell is one of the named pairs (its status, or the link column's) or plain; the page's look, its
// rich runs, the page sheet's formats and jumps stay out
// a dot's glyph (export_page.ts withDot: its own coloured run before the words) goes with its run: the cell keeps the words
const dotless = (c: Cell): string | number => typeof c.v === 'string' && c.runs?.length === 2 && c.v === c.runs[0].text + c.runs[1].text ? c.runs[1].text : c.v;
// (X7) a decimal read straight from the page's figure keeps whether that figure groups its thousands (a size, a duration
// or a rate converted to its column's unit later is a figure of another unit: never grouped)
const plainCell = (c: Cell): Cell => ({ v: dotless(c), kind: c.kind, text: c.text, ...(c.status ? { status: c.status } : c.link ? { link: true } : {}), ...(c.stamp !== undefined ? { stamp: c.stamp } : {}), ...(c.per ? { per: c.per } : {}), ...((c.kind === 'dec' || c.kind === 'int') && typeof c.v === 'number' && grouped(c.text) ? { grp: true } : {}) });
// gridSection: a section as its grid sheet holds it. X7: a size column in ONE unit - its largest value's, as the page
// writes it - every size cell converted and unrounded, the unit in the header ('size (GB)'); a millisecond column the same
// with its time unit ('took (s)'). X8: a seconds column is numbers - in its one unit, or in seconds when the page mixes
// units ('4.4 s' beside ui.ts fmtSecs's '1m 5s'), as DBA Dash writes a seconds column. A count of days ('233.3 days')
// is numbers under '(days)'; a size per day ('381.5 MB / day') numbers in the unit the column shows most, '(MB/day)'; a
// size the server sends as words ('1024 MB', a file's growth) numbers like any size when every cell of its column is one;
// in a column of days or of a rate, a cell with no number in it ('never', '-', 'too little history') is left empty. A
// duration the page writes in words only (the Summary's ages, '3 days' since a dump: DBA Dash's Summary writes its ages as
// text) stays text. The page's header looks go too (X4: the one header style).
export function gridSection(s: Section): Section {
  const rows = s.rows.map(r => r.map(plainCell));
  const cols = [...s.cols];
  // an Item | Value | Status section's cells are typed by their own content (itemSection): a Value with a unit stays the
  // page's words, its column mixed per row; no column of it is converted
  if (s.items) { const { heads: _h, ...rest } = s; return { ...rest, cols, rows }; }
  const ncol = Math.max(cols.length, ...rows.map(r => r.length), 0);
  const unitOf = (j: number, u: string) => { if (j < cols.length) cols[j] = `${cols[j]} (${u})`; };
  const emptyWords = (j: number) => { for (const r of rows) { const c = r[j]; if (c && typeof c.v === 'string' && !/\d/.test(c.v)) c.v = ''; } };
  // (X13) the decimals the page shows in a column, the most any of its figures shows: every decimal cell of it under that
  // format ('1.6 GB', '336.0 MB' -> '0.0': 1.6328125 GB reads 1.6, the formula bar keeps it whole; '17.35' -> '0.00'); a
  // count stays General. A column whose texts carry more than 6 decimals is a raw value the page does not round (a chart's
  // series without a formatter): General as it is. A share column the page writes in whole percents: '0%'
  const decimals = (j: number) => {
    const decs = rows.map(r => r[j]).filter((c): c is Cell => !!c && typeof c.v === 'number' && c.kind === 'dec');
    const k = Math.max(-1, ...decs.map(c => decimalsOf(c.text, c.v) ?? -1));
    // the page's grouping carried, as its colours and decimals are: a column whose figures group their thousands is grouped
    // under its fixed decimals, '#,##0' .. '#,##0.000' (DBA Dash writes General); an ungrouped column stays ungrouped
    // a column of no decimals (DB Space at 0 places) also holds the figures that are whole numbers (typed int: a size of a
    // whole number of MB): one column, one format - '0' or '#,##0' for all of them; with decimals, an int keeps General
    const whole = k === 0 ? rows.map(r => r[j]).filter((c): c is Cell => !!c && typeof c.v === 'number' && c.kind === 'int') : [];
    const all = [...decs, ...whole];
    const grp = k >= 0 && k <= 3 && all.some(c => c.grp);
    for (const c of all) if (grp) c.grp = true; else delete c.grp;
    if (k >= 0 && k <= 6) for (const c of all) c.dp = k;
    // (a chart's share holds its fraction as text, not the page's percent: only a column of the page's own percents)
    const pcts = rows.map(r => r[j]).filter((c): c is Cell => !!c && typeof c.v === 'number' && c.kind === 'pct');
    if (pcts.length && pcts.every(c => / ?%$/.test(norm(c.text)) && decimalsOf(c.text) === 0)) for (const c of pcts) c.dp = 0;
  };
  for (let j = 0; j < ncol; j++) {
    const nums = rows.map(r => r[j]).filter((c): c is Cell => !!c && typeof c.v === 'number');
    const largest = (k: Kind, per = false) => nums.filter(c => c.kind === k && !!c.per === per).reduce<Cell | undefined>((a, c) => !a || Math.abs(c.v as number) > Math.abs(a.v as number) ? c : a, undefined);
    // a size per day: the unit the column's figures show most (zero left out of the count; a tie: the largest's)
    const rate = nums.filter(c => c.kind === 'bytes' && c.per);
    if (rate.length) {
      const unitIn = (c: Cell) => sizeOf(c.text.replace(/ \/ day$/, '').replace(/^-/, ''))?.unit;
      const seen = new Map<string, number>();
      for (const c of rate) { const u = unitIn(c); if (u && c.v !== 0) seen.set(u, (seen.get(u) ?? 0) + 1); }
      const most = Math.max(0, ...seen.values()), tied = [...seen].filter(([, k]) => k === most).map(([u]) => u);
      const top = largest('bytes', true)!, topUnit = unitIn(top);
      const unit = tied.length === 1 ? tied[0] : topUnit && tied.includes(topUnit) ? topUnit : tied.sort((a, b) => UNITS.indexOf(b) - UNITS.indexOf(a))[0] ?? sizeUnit(top.v as number);
      for (const c of rate) { c.v = (c.v as number) / 1024 ** UNITS.indexOf(unit); c.kind = 'dec'; delete c.per; }
      unitOf(j, `${unit}/day`);
      emptyWords(j);
    }
    if (nums.some(c => c.kind === 'days')) {
      for (const c of nums) if (c.kind === 'days') c.kind = Number.isInteger(c.v) ? 'int' : 'dec';
      unitOf(j, 'days');
      emptyWords(j);
    }
    // a size the server sends as words (a SQL Server file's growth '1024 MB'): numbers when every cell is a size; a
    // column holding a percent growth ('10 %') beside them stays the page's words (one unit cannot head it)
    const words = rows.map(r => r[j]).filter((c): c is Cell => !!c && typeof c.v === 'string' && c.v !== '');
    if (!nums.length && words.length && words.every(c => sizeOf(c.v as string))) {
      const at = words.map(c => { const z = sizeOf(c.v as string)!; return { c, b: Number((c.v as string).split(/\s/)[0]) * 1024 ** z.pow, z }; });
      const unit = at.reduce((a, x) => Math.abs(x.b) > Math.abs(a.b) ? x : a).z.unit;
      for (const x of at) { x.c.v = x.b / 1024 ** UNITS.indexOf(unit); x.c.kind = 'dec'; }
      unitOf(j, unit);
      decimals(j);
      continue;
    }
    const big = largest('bytes');
    if (big) {
      const unit = sizeOf(big.text)?.unit ?? sizeUnit(big.v as number), k = 1024 ** UNITS.indexOf(unit);
      for (const c of nums) if (c.kind === 'bytes') { c.v = (c.v as number) / k; c.kind = 'dec'; }
      if (j < cols.length) cols[j] = `${cols[j]} (${unit})`;
    }
    const long = largest('msecs');
    if (long) {
      const unit = /\s(ms|s|min)$/.exec(long.text)?.[1] ?? 'ms';
      for (const c of nums) if (c.kind === 'msecs') { c.v = (c.v as number) / DUR[unit]; c.kind = 'dec'; }
      if (j < cols.length) cols[j] = `${cols[j]} (${unit})`;
    }
    // a seconds column (fmtSecs, the Jobs tabs' '12.2 s'): numbers in one unit named in the header (X7, X8) - every cell
    // in one unit ('12.2 s'): that unit, as the millisecond column; units mixed ('4.4 s' beside fmtSecs's '3m 0s', which
    // also cuts its seconds off past an hour): seconds, the stored value, as DBA Dash writes a seconds column
    const secs = nums.filter(c => c.kind === 'secs' || c.kind === 'nsecs');
    if (secs.length) {
      const ms = (c: Cell) => c.kind === 'secs' ? (c.v as number) * 86400000 : (c.v as number) * 1000;
      const top = secs.reduce((a, c) => Math.abs(ms(c)) > Math.abs(ms(a)) ? c : a);
      const unit = secs.every(c => durParse(c.text)) ? /\s(ms|s|min)$/.exec(top.text)?.[1] ?? 's' : 's';
      for (const c of secs) { c.v = Number((ms(c) / DUR[unit]).toPrecision(15)); c.kind = 'dec'; }   // no float noise: 11 s, not 10.999999999999998, at any size
      if (j < cols.length && !long) cols[j] = `${cols[j]} (${unit})`;
    }
    decimals(j);
  }
  const { heads: _heads, ...rest } = s;
  return { ...rest, cols, rows };
}

// coreXml (D-A): the export's facts in the document's properties as well (File > Info in Excel)
function coreXml(meta: Meta): string {
  const iso = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, 'Z');
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
    + `<dc:title>${esc(`${meta.instance} - ${meta.tab}`)}</dc:title>`
    + `<dc:subject>${esc(`${meta.window}: ${localStamp(meta.from)} to ${localStamp(meta.to)}`)}</dc:subject>`
    + `<dc:description>${esc(`Window ${localStamp(meta.from)} to ${localStamp(meta.to)}; ${timeZone(meta.at)}; exported ${localStamp(meta.at)}; source pgvigil`)}</dc:description>`
    + '<dc:creator>pgvigil</dc:creator>'
    + `<dcterms:created xsi:type="dcterms:W3CDTF">${iso(meta.at)}</dcterms:created>`
    + '</cp:coreProperties>';
}

export interface Meta { instance: string; tab: string; from: Date; to: Date; window: string; at: Date; engine?: string; platform?: string; read?: string }   // engine, platform: an instance's (the page sheet's scope row)   // read: what the page's parts read when the server cut them to their reach (cutWords)

// timeZone: the zone the times in the file are written in, 'America/Los_Angeles (UTC-08:00 at export)': the display
// zone (the browser's unless another was chosen in the range panel). Each time carries its own date's offset (a window
// across a DST change holds two), so the offset is the export's.
export function timeZone(at: Date): string {
  const whose = zoneChoice() === 'local' ? "the browser's" : 'the display zone chosen in the range panel';
  return `${zoneName()} (${offsetLabel(at)} at export), ${whose}; each time in its own date's offset`;
}

// workbook: the sheets as a .xlsx's parts. The grid sheets first in page order, as DBA Dash writes them (gridSection;
// X1: the file opens on the first grid; X6: no frozen row), then the 'About' sheet LAST (D-A: the export's facts, also in
// the document's properties). A page sheet (export_page.ts, parked out of the export: D-B) still writes as sheet 1 with
// its grids in the page's looks when one is passed.
export function workbook(meta: Meta, given: Section[], page?: PageSheet): { name: string; data: Uint8Array }[] {
  const first = page ? page.name.slice(0, 31).replace(/[\\/?*[\]:]/g, ' ').trim() || 'Page' : '';
  const secs = page ? given : given.map(gridSection);
  const names = sheetNames(secs.map(s => s.name), first ? [first] : [], secs.map(s => s.within), secs.map(s => !!s.own));
  const t = (v: string): Cell => ({ v, kind: 'text', text: v });
  const d = (v: Date): Cell => ({ v: excelDate(v), kind: 'date', text: '', stamp: localStamp(v) });
  // About (D-A): Item | Value - the scope, the window, the zone with its offset, the export's time, the source, then each
  // grid sheet's rows and the page's note above it ('the newest 500 of N')
  const about: Cell[][] = [
    [t('Instance'), t(meta.instance)], [t('Tab'), t(meta.tab)],
    [t('Window'), t(meta.window)], [t('Window from'), d(meta.from)], [t('Window to'), d(meta.to)],
    [t('Exported at'), d(meta.at)], [t('Time zone'), t(timeZone(meta.at))], [t('Source'), t('pgvigil')],
    // the page's parts that read only the newest part of a long window: what they read (each sheet's row says its own)
    ...(meta.read ? [[t('Read'), t(meta.read)]] : []),
    ...secs.map((s, i) => [t(`Sheet ${names[i]}`), t(`${s.rows.length} row${s.rows.length === 1 ? '' : 's'}${s.note ? '; ' + s.note : ''}`)]),
    ...(secs.some(s => s.items) ? [[t('Item | Value sheets'), t('Each Value is typed by its own content: a time a date, a bare number a number, yes / no a boolean; a value with a unit (a size, a duration, a rate) is the page\'s text with its unit, as the page shows it.')]] : []),
  ];
  const pics = page?.pictures ?? [];
  const sheets: Sheet[] = [...(page ? [{ name: first, head: [], rows: page.rows, data: false, page: true, freeze: page.freeze, widths: page.widths, drawing: pics.length > 0 }] : []),
    ...secs.map((s, i) => ({ name: names[i], head: s.cols, rows: s.rows, data: true, ...(page && s.heads ? { heads: s.heads } : {}), ...(page ? { freeze: 1 } : {}) })),
    ...(page ? [] : [{ name: 'About', head: ['Item', 'Value'], rows: about, data: false }])];
  const all = sheets.map(sh => sh.name);
  // (P1, the lead 22:34) every grid sheet is one Excel table over the grid, an empty grid's too (P2: its header and one
  // empty row), as DBA Dash writes each sheet
  let tables = 0;
  for (const sh of sheets) if (sh.data) sh.table = ++tables;
  const st = new Styles(), sst = new Shared();
  const enc = new TextEncoder();
  const files = sheets.map((sh, i) => ({ name: `xl/worksheets/sheet${i + 1}.xml`, data: enc.encode(sheetXml(sh, st, sst, all)) }));
  const x = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  const ncolOf = (sh: Sheet) => Math.max(sh.head.length, ...sh.rows.map(r => r.length), 1);
  const tableFiles = sheets.flatMap((sh, i) => sh.table ? [
    { name: `xl/tables/table${sh.table}.xml`, data: enc.encode(tableXml(sh.table, tableHead(sh.head, ncolOf(sh)), sh.rows.length)) },
    { name: `xl/worksheets/_rels/sheet${i + 1}.xml.rels`, data: enc.encode(x + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + `<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/table" Target="../tables/table${sh.table}.xml"/></Relationships>`) }] : []);
  // the page sheet's pictures (export_chart.ts): one drawing, its pictures in xl/media, each one's alt text naming its
  // numbers sheet by name
  const named = (s: string) => s.replace(/\{sheet:(\d+)\}/g, (_, k) => all[Number(k) + 1] ?? '');
  const drawFiles = pics.length ? [
    { name: 'xl/worksheets/_rels/sheet1.xml.rels', data: enc.encode(x + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="../drawings/drawing1.xml"/></Relationships>') },
    { name: 'xl/drawings/drawing1.xml', data: enc.encode(drawingXml(pics.map(p => ({ ...p, descr: named(p.descr) })))) },
    { name: 'xl/drawings/_rels/drawing1.xml.rels', data: enc.encode(drawingRels(pics, 1)) },
    ...pics.map((p, i) => ({ name: `xl/media/image${i + 1}.png`, data: p.png })),
  ] : [];
  const filters = sheets.map((sh, i) => sh.data && !sh.table
    ? `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">'${esc(sh.name.replace(/'/g, "''"))}'!$A$1:$${colName(Math.max(sh.head.length, 1) - 1)}$${sh.rows.length + 1}</definedName>` : '').join('');
  return [
    { name: '[Content_Types].xml', data: enc.encode(x + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
      + (pics.length ? '<Default Extension="png" ContentType="image/png"/><Override PartName="/xl/drawings/drawing1.xml" ContentType="application/vnd.openxmlformats-officedocument.drawing+xml"/>' : '')
      + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      + '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      + sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')
      + sheets.map(sh => sh.table ? `<Override PartName="/xl/tables/table${sh.table}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/>` : '').join('')
      + (sst.size ? '<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>' : '')
      + '<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      + '</Types>') },
    { name: '_rels/.rels', data: enc.encode(x + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
      + '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>') },
    { name: 'docProps/core.xml', data: enc.encode(coreXml(meta)) },
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
    ...files, ...tableFiles, ...drawFiles,
  ];
}

// ---- CSV --------------------------------------------------------------------------------------------------


// csv: RFC 4180 with a UTF-8 byte-order mark (Excel reads the encoding from it); a number as its plain value (a
// duration in seconds, a size in bytes, a share in percent), a time as the screen shows it (the display time zone's clock); a text cell
// that a spreadsheet would read as a formula (= + - @ tab CR first) gets a leading apostrophe (OWASP CSV injection).
export function csv(s: Section): string {
  const val = (c: Cell): string => {
    if (typeof c.v === 'number') {
      if (c.kind === 'date' || c.kind === 'day') return c.stamp ?? '';
      if (c.kind === 'bool') return c.text;   // the CSV keeps the page's word for a boolean
      if (c.kind === 'secs') return String(Math.round(c.v * 86400 * 1000) / 1000);
      if (c.kind === 'msecs') return String(c.v);   // the milliseconds, as the raw value
      if (c.kind === 'pct') return String(Math.round(c.v * 1e12) / 1e10);   // the percent figure (the cell holds the share): 12.5, not 0.125; ten decimals kept
      return String(c.v);
    }
    // a cell that starts with = + - @ TAB CR, or with 's before one, gets one more ' (as the server's inventory CSV and
    // its import's undo: task 312, review P M-6 - "'=x" written as it is read back as =x)
    return /^'*[=+\-@\t\r]/.test(c.v) ? "'" + c.v : c.v;
  };
  const q = (v: string) => /[",\r\n]|^\s|\s$/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
  // a stored sample's file starts with its mark, a line of its own above the header; a list cut to its part's reach
  // says what it read on the next line
  return '﻿' + [...(s.sample ? [q(s.sample)] : []), ...(s.read ? [q(s.read)] : []), s.cols.map(q).join(','), ...s.rows.map(r => r.map(c => q(val(c))).join(','))].join('\r\n') + '\r\n';
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
  let engine: string | undefined, platform: string | undefined;
  if (ctx.instance) {
    instance = 'instance ' + ctx.instance;
    try {
      const r = (await fleet()).instances.find(x => Number(x.instance_id) === ctx.instance);
      if (r) {
        instance = String(r.name);
        engine = String(r.engine ?? 'postgres') === 'sqlserver' ? 'SQL Server' : 'PostgreSQL';
        if (r.platform) platform = String(r.platform);
      }
    } catch { /* the id stands */ }
  }
  const w = window_(ctx);
  const tab = (ctx.instance ? instanceTabs[ctx.tab] ?? mssqlInstanceTabs[ctx.tab] ?? drillTabs[ctx.tab] : rootTabs[ctx.tab]) ?? ctx.tab;
  const read = cutWords();
  return { instance, tab, from: new Date(w.from), to: new Date(w.to), window: rangeLabel(ctx), at: new Date(), ...(engine ? { engine } : {}), ...(platform ? { platform } : {}), ...(read ? { read } : {}) };
}

// cutWords: the page's reads the server cut to a part's reach (api.ts cutReads), in words, once per reach (its length in
// whole minutes: a draw's reads ask the window milliseconds apart, so their ends differ), the newest read of each; none =
// undefined
export function cutWords(): string | undefined {
  const byReach = new Map<number, { from: string; to: string }>();
  for (const c of cutReads()) {
    const k = Math.round((Date.parse(c.to) - Date.parse(c.from)) / 60e3), had = byReach.get(k);
    if (!had || Date.parse(c.to) > Date.parse(had.to)) byReach.set(k, { from: c.from, to: c.to });
  }
  return byReach.size ? 'Parts of this page read ' + [...byReach.values()].map(rw => readWindowWords(rw)).join('; ') + ' (the window is longer than they read)' : undefined;
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

// oneFile: a workbook of one grid or one chart (its sheet, then 'About'), named
// <instance>_<tab>_<sheet>_<from>_<to>.xlsx
async function oneFile(m: Meta, sec: Section): Promise<string> {
  const z = await zip(workbook(m, [sec]), m.at);
  const name = `${safe(m.instance)}_${safe(m.tab)}_${safe(sheetNames([sec.name], [], [sec.within], [!!sec.own])[0])}_${fileStamp(m.from)}_${fileStamp(m.to)}.xlsx`;
  save(new Blob([z], { type: XLSX }), name);
  return name;
}

// exportSection: a workbook of one section a caller built (its sheet, then 'About'), as exportGrid writes one grid's:
// the applications inventory writes its raw rows as text cells (task 312)
export async function exportSection(sec: Section, ctx: Ctx = parse()): Promise<string> {
  return oneFile(await metaOf(ctx), sec);
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

// chartSection: a chart's numbers as a sheet (its Export Excel's and the page export's numbers sheet): a time as a time,
// a day alone ('2026-11-11') as a date under 'yyyy-MM-dd', a number as a number, a share (kind 'pct', the fraction) as
// '0.0%'. A series with its axis's formatter (n.fmts: fmtBytes, fmtSecs, a millisecond one) is typed as the page's grids are
// (typed: bytes, seconds, milliseconds), so gridSection writes it in the unit the axis shows, named in its header
// ('erp (GB)', not bytes with no unit)
export function chartSection(title: string, n: ChartNumbers): Section {
  const kinds = n.kinds ?? [], fmts = n.fmts ?? [];
  const cell = (v: string | number | Date | null | undefined, j: number): Cell => {
    if (v instanceof Date) return { v: excelDate(v), kind: 'date', text: '', stamp: localStamp(v) };
    if (typeof v === 'number' && isFinite(v)) {
      const f = fmts[j], t = f && !kinds[j] ? typed(v, norm(f(v))) : undefined;
      if (t && typeof t.v === 'number' && t.kind !== 'bool') return { ...t, text: norm(f!(v)) };
      return { v, kind: kinds[j] ?? (Number.isInteger(v) ? 'int' : 'dec'), text: String(v) };
    }
    const t = v == null || typeof v === 'number' ? '' : v;
    const d = dayCell(t);
    return d ? { ...d, text: t } : { v: t, kind: 'text', text: t };
  };
  const rows = n.rows.map(r => r.map(cell)), cols = [...n.cols];
  // (the lead 13:44 (3)) the series one axis draws (one formatter) share its unit: the largest value's, as the axis shows it,
  // named in each series' header ('erp (GB)', 'postgres (GB)'), not a unit per series
  for (const f of new Set(fmts.filter((x): x is ((v: number) => string) => !!x))) {
    const js = cols.map((_, j) => j).filter(j => fmts[j] === f);
    const at = js.flatMap(j => rows.map(r => r[j]).filter((c): c is Cell => !!c && typeof c.v === 'number'));
    for (const [k, read] of [['bytes', (c: Cell) => sizeOf(c.text)?.unit], ['msecs', (c: Cell) => /\s(ms|s|min)$/.exec(c.text)?.[1]]] as [Kind, (c: Cell) => string | undefined][]) {
      const cs = at.filter(c => c.kind === k);
      if (!cs.length) continue;
      const top = cs.reduce((a, c) => Math.abs(c.v as number) > Math.abs(a.v as number) ? c : a);
      const unit = read(top) ?? (k === 'bytes' ? sizeUnit(top.v as number) : 'ms');
      const div = k === 'bytes' ? 1024 ** UNITS.indexOf(unit) : DUR[unit];
      for (const c of cs) { c.v = (c.v as number) / div; c.kind = 'dec'; }
      for (const j of js) if (rows.some(r => r[j] && cs.includes(r[j]))) cols[j] = `${cols[j]} (${unit})`;
    }
  }
  return { name: title || 'Chart', cols, rows };
}
// exportChart: a chart's numbers as a workbook (a chart's menu: Export Excel; chart.ts): one sheet named by the chart's
// title, a time as a time ('yyyy-MM-dd HH:mm'), a number as a number, a share (kind 'pct', the fraction) as '0.0%'
export async function exportChart(title: string, cols: string[], rows: (string | number | Date | null | undefined)[][], kinds: (Kind | undefined)[] = [], ctx: Ctx = parse(), fmts: ChartNumbers['fmts'] = []): Promise<string> {
  const m = await metaOf(ctx);
  return oneFile(m, chartSection(title, { cols, rows: rows.map(r => r.map(v => v ?? null)), kinds, fmts }));
}

// ---- the page's sections that are no grid (X12) ------------------------------------------------------------------
// AttentionBox: the fleet Summary's Needs attention strip (pages.ts) with every line it holds, also those past its first 8
export type AttentionBox = HTMLElement & { pgvItems?: () => { item: string; value: string; status: Status }[] };
const STATUS_WORD: Record<Status, string> = { ok: 'OK', warn: 'Warning', crit: 'Critical', none: 'N/A', ack: 'Acknowledged' };
// itemSection: tiles, a property card or the Needs attention lines as an Item | Value | Status table, the Status cell in
// its named pair (a value without a status: its Status cell empty)
// (the lead 13:44, X7-X9 on these sheets) each Value cell is typed by its own content, as Excel types cells: a time the page
// shows -> a date cell, a bare number -> a number (no 'Number Stored as Text'), yes / no -> a boolean; a value with a unit
// (a size, a duration, a rate) or with words stays the page's text (About says so), and so does a version ('collation
// version' '2.39': a number in its looks, not one in its meaning)
export function valueCell(v: string, item = ''): Cell {
  const text: Cell = { v, kind: 'text', text: v };
  if (v === '' || /\bversion\b/i.test(item)) return text;
  const yn = yesNo(v), tm = shownTime(v) ?? dayCell(v);
  if (yn) return { ...yn, text: v };
  if (tm) return { ...tm, text: v };
  const d = digitsOf(v);
  if (d && (norm(fmtNum(Number(d))) === v || /^-?\d+$/.test(v)) && !/^[+0]\d/.test(v)) { const n = Number(d); return { v: n, kind: Number.isInteger(n) ? 'int' : 'dec', text: v }; }   // '5432' too
  return text;
}
function itemSection(name: string, items: { item: string; value: string; status?: Status }[]): Section {
  const t = (v: string): Cell => ({ v, kind: 'text', text: v });
  return { name, items: true, cols: ['Item', 'Value', 'Status'], rows: items.map(x => [t(x.item), valueCell(x.value, x.item), x.status ? { ...t(STATUS_WORD[x.status]), status: x.status } : t('')]) };
}
// asItems: a property card read by readProps (item | value, the value cell in its status) as an Item | Value | Status table
function asItems(sec: Section): Section {
  return { ...itemSection(sec.name, sec.rows.map(r => ({ item: String(r[0]?.v ?? ''), value: String(r[1]?.v ?? ''), status: r[1]?.status }))), within: sec.within };
}
const shownEl = (e: Element) => !(e.closest('[hidden], details:not([open]) > :not(summary)') || (e as HTMLElement).offsetParent === null && getComputedStyle(e).position !== 'fixed');
// pageExtras: in page order, each heading's tiles (ui.ts tile: label, value, its pill's status), the fleet Summary's
// Needs attention lines (pages.ts: the instance, its reasons, its badge's level) and each chart's series as the chart's own
// Export Excel writes them (a time per row, a series per column); an SVG chart whose numbers the page shows as a table
// is that table's sheet already
function pageExtras(root: Element, fallback: string): { sec: Section; el: Element }[] {
  const out: { sec: Section; el: Element }[] = [];
  const hs = headings(fallback);
  for (const e of root.querySelectorAll('h2, h3, h4, h5, .tiles, .attention, .chart')) {
    if (/^H[2-5]$/.test(e.tagName)) { if (!e.closest('.chart, .attention')) hs.see(e); continue; }
    if (!shownEl(e)) continue;
    const { heading, within, own: ownSheet } = hs.of(e);
    if (e.matches('.tiles')) {
      const items = [...e.querySelectorAll(':scope > .tile')].filter(shownEl).map(x => ({
        item: text(x.querySelector('.tile-l') ?? x),
        value: [x.querySelector('.tile-v'), x.querySelector('.tile-sub')].filter((y): y is Element => !!y).map(text).join('; '),
        status: statuses.find(k => x.classList.contains(k)),
      }));
      // a row of tiles the page names (tiles.ts tileRow: its aria-label, 'Instance health') is that sheet's name
      const own = e.getAttribute('aria-label')?.trim();
      if (items.length) out.push({ sec: { ...itemSection(own || heading, items), within: own ? heading : within, ...(ownSheet && !own ? { own: true } : {}) }, el: e });
    } else if (e.matches('.attention')) {
      // every line with every reason (pages.ts gives the strip pgvItems: the page draws the first 8 lines and 4 reasons
      // of each until 'Show all'); a strip without it: its drawn lines
      const all = (e as AttentionBox).pgvItems?.();
      const items = all ?? [...e.querySelectorAll('.attention-row')].map(x => ({
        item: text(x.querySelector('strong') ?? x),
        value: text(x.querySelector('span[style*="flex"]') ?? x),
        status: x.querySelector('.badge.crit') ? 'crit' as Status : 'warn' as Status,
      }));
      if (items.length) out.push({ sec: itemSection('Needs attention', items), el: e });
    } else {
      const h = e.querySelector('h3, h4'), hc = h?.cloneNode(true) as Element | undefined;
      hc?.querySelectorAll('button, select, .chart-note, .chart-reset, .whatis, .filter-btn').forEach(b => b.remove());
      const title = hc ? (hc.textContent ?? '').replace(/\s+/g, ' ').trim() : heading;
      let table = false;
      for (let a: Element | null = e; a && a !== root && !table; a = a.parentElement) {
        const nx = a.nextElementSibling;
        if (nx?.tagName === 'DETAILS' && /numbers as a table/.test(nx.querySelector('summary')?.textContent ?? '')) table = true;
      }
      const nf = pictureOf(e)?.numbers ?? (table ? undefined : (e as PictureBox).pgvNumbers);
      const n = nf?.();
      if (n && n.rows.length) out.push({ sec: { ...chartSection(title || heading, n), within: title && title !== heading ? heading : within, ...(ownSheet && !title ? { own: true } : {}) }, el: e });
    }
  }
  return out;
}
// pageSections (X12): every section of the page in page order - grids, property cards as Item | Value | Status, tiles,
// the Needs attention lines, charts' series; the fleet Summary's two grids named 'Test Summary' and 'Instance Summary' on
// every route (X2, the names its drop-down gives them)
function pageSections(ctx: Ctx, root: Element, found: { sec: Section; el: Element }[], fallback: string): { sec: Section; el: Element }[] {
  const all = [...found.map(f => ({ ...f, sec: f.el.matches('table.props') ? asItems(f.sec) : f.sec })), ...pageExtras(root, fallback)];
  if (!ctx.instance && ctx.tab === 'summary') {
    const grids = all.filter(f => f.el.matches('table.grid, p.empty[data-cols]') && !f.el.closest('.attention'));
    const tests = grids.find(f => f.el.closest('.tests')), inst = [...grids].reverse().find(f => !f.el.closest('.tests'));
    if (tests) tests.sec = { ...tests.sec, name: 'Test Summary' };
    if (inst) inst.sec = { ...inst.sec, name: 'Instance Summary' };
  }
  all.sort((a, b) => a.el === b.el ? 0 : a.el.compareDocumentPosition(b.el) & Node.DOCUMENT_POSITION_FOLLOWING ? -1 : 1);
  distinct(all);
  return all;
}

// pageBook: the page under root as its workbook's sections and its grids, read as the bar's Export .xlsx reads them (the
// charts drawn first, the light theme around the reads) - the bar's workbook and CSV, and the mailed workbook
// (reportmail.ts), so the three name each grid alike (X2: the same names, never ' (2)'); names: each section's sheet name
export async function pageBook(ctx: Ctx, r: HTMLElement | null, tab: string, waitCharts = true): Promise<{ items: { sec: Section; el: Element }[]; found: { sec: Section; el: Element }[]; names: string[] }> {
  if (waitCharts) await chartsDrawn(r);
  // every read of the page from here to the workbook's parts runs in one task, after the last await (nothing is painted
  // between: the hidden copy of a grid's rows past its page, the colour probe and the charts drawn again come and go
  // unseen), under the light theme (E2-16: the file is light whatever the screen; 'auto' restored by removing the attribute)
  const html = document.documentElement, was = html.getAttribute('data-theme');
  html.setAttribute('data-theme', 'light');
  let found: { sec: Section; el: Element }[] = [], items: { sec: Section; el: Element }[] = [];
  try {
    found = r ? walk(r, tab, true) : [];
    // (X12, D-B) the page's sections in page order, a sheet each; the page sheet with pictures is parked
    if (r) items = pageSections(ctx, r, found, tab);
  } finally { if (was === null) html.removeAttribute('data-theme'); else html.setAttribute('data-theme', was); }
  const secs = items.map(f => gridSection(f.sec));
  return { items, found, names: sheetNames(secs.map(s => s.name), [], secs.map(s => s.within), secs.map(s => !!s.own)) };
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

// chartsDrawn: a chart of the page drawn by the time its picture is asked for - a box that is neither drawn (no
// picture to give, chart.ts) nor in a state of its own ('one read', 'no data') is waited for, 3 s at most; one still
// not drawn then says so on the page sheet
async function chartsDrawn(r: Element | null): Promise<void> {
  if (!r) return;
  const pending = () => [...r.querySelectorAll('.chart')].some(b => !(b as PictureBox).pgvPicture && !(b as PictureBox).pgvNumbers && !b.querySelector('.chart-state') && !!b.querySelector('.uplot, div:empty'));
  for (let t = 0; t < 30 && pending(); t++) await new Promise(res => setTimeout(res, 100));
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
      // the CSV reads the charts too only to name its files as the workbook names its sheets (3.6: one name per grid)
      const { items, found, names } = await pageBook(ctx, root(), m.tab, kind === 'xlsx');
      const secs = found.map(f => f.sec);
      if (kind === 'xlsx') {
        if (items.length === 0) { note.textContent = 'Nothing to export: no grid on this page.'; return; }
        const parts = workbook(m, items.map(f => f.sec));
        const z = await zip(parts, m.at);
        save(new Blob([z], { type: XLSX }), exportName(m, 'xlsx'));
      } else if (secs.length === 0) {
        note.textContent = 'Nothing to export: no grid on this page.'; return;
      } else if (secs.length === 1) {
        save(new Blob([csv(secs[0])], { type: 'text/csv;charset=utf-8' }), exportName(m, 'csv'));
      } else {
        // each CSV named by its grid's sheet name in the workbook (the Summary's 'Test Summary' / 'Instance Summary', a card
        // 'Database erp properties'), never a numbered repeat
        const own = sheetNames(secs.map(s => s.name), [], secs.map(s => s.within), secs.map(s => !!s.own)), enc = new TextEncoder();
        const nameOf = (i: number) => { const k = items.findIndex(f => f.el === found[i].el); return k >= 0 ? names[k] : own[i]; };
        const z = await zip(secs.map((s, i) => ({ name: `${String(i + 1).padStart(2, '0')}_${safe(nameOf(i))}.csv`, data: enc.encode(csv(s)) })), m.at);
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
