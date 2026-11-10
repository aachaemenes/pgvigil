// The export of a tab (task 54): every grid on the page as a sheet of one .xlsx workbook, with the status colours the
// screen shows as fills, the numbers as numbers with their formats, a frozen header row with the filter on and the
// column widths from the content; a Summary sheet first (the instance, the tab, the window, the export time); the
// same rows as CSV beside it (one grid: a .csv; several: a .zip of one .csv per grid). It reads the rendered page and
// each grid's page model (ui.ts gridModel: the raw values in the order shown), so the file matches the screen; the
// server is untouched and nothing leaves the browser but the file the user saves. The workbook is written here
// (SpreadsheetML in a zip): no library, no dependency in the bundle.
import { fleet } from './fleet';
import { Ctx, drillTabs, instanceTabs, rangeLabel, rootTabs, window_ } from './router';
import { Col, el, fmtBytes, fmtNum, fmtSecs, fmtTime, gridModel } from './ui';

type Status = 'ok' | 'warn' | 'crit' | 'none';
type Kind = 'text' | 'int' | 'dec' | 'bytes' | 'secs' | 'nsecs' | 'msecs' | 'pct' | 'date';
interface Cell { v: string | number; kind: Kind; status?: Status; text: string; stamp?: string }   // stamp: a time's local text for the CSV
export interface Section { name: string; cols: string[]; rows: Cell[][]; note?: string }   // note: the page's 'the newest N of M' line above the grid

// ---- reading the page -----------------------------------------------------------------------------------

const pad = (n: number, w = 2) => String(n).padStart(w, '0');
const localStamp = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
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
    const dur = durParse(text);   // a millisecond duration as any tab writes it: the raw value rounds to the text shown
    if (dur && Math.abs(n - dur.ms) <= dur.tol) return { v: n, kind: 'msecs' };
    // a share: '12.5 %', a growth with its sign ('+3 %'), or one the page rounds to a whole percent
    const pct = new Set([fmtNum(n), (n > 0 ? '+' : '') + fmtNum(n), fmtNum(Math.round(n)), (n > 0 ? '+' : '') + fmtNum(Math.round(n))].map(x => norm(x + ' %')));
    if (pct.has(text)) return { v: n, kind: 'pct' };
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

// excelDate: the local wall-clock time the screen shows, as an Excel serial date (days since 1899-12-30), whole
// seconds (Excel rounds a fraction up in hh:mm:ss, the screen and the CSV cut it: the three agree on the floor).
export function excelDate(d: Date): number {
  return (Math.floor(d.getTime() / 1000) * 1000 - d.getTimezoneOffset() * 60000) / 86400000 + 25569;
}

const statuses: Status[] = ['crit', 'warn', 'ok', 'none'];
// statusOf: the colour the screen gives a cell: a status cell (the Summary grid's), else a badge or a dot in it.
function statusOf(td: Element): Status | undefined {
  const pick = (e: Element) => statuses.find(k => e.classList.contains(k));
  if (td.classList.contains('status')) return pick(td);
  const b = td.querySelector('.badge, .dot');
  return b ? pick(b) : undefined;
}

const text = (e: Element) => (e.textContent ?? '').replace(/\s+/g, ' ').trim();

function readGrid(table: HTMLTableElement): Pick<Section, 'cols' | 'rows'> {
  const ths = [...table.querySelectorAll('thead th')];
  const cols = ths.map(text);
  const numCol = ths.map(h => h.classList.contains('num'));
  const trs = [...table.querySelectorAll('tbody tr')];
  const m = gridModel(table);
  const data = m?.rows();
  const keys: (Col | undefined)[] = m && m.cols.length === cols.length ? m.cols : cols.map(() => undefined);
  const rows = trs.map((tr, i) => [...tr.children].map((td, j) => {
    const t = text(td);
    const raw = data && data.length === trs.length && keys[j] ? data[i][keys[j]!.key] : undefined;
    return { ...(raw !== undefined ? typed(raw, t) : numCol[j] ? fromText(t) : { v: t, kind: 'text' as Kind }), status: statusOf(td), text: t };
  }));
  return { cols, rows };
}

function readProps(table: HTMLTableElement): Pick<Section, 'cols' | 'rows'> {
  const rows = [...table.querySelectorAll('tr')].map(tr => {
    const th = tr.querySelector('th'), td = tr.querySelector('td');
    const a = th ? text(th) : '', b = td ? text(td) : '';
    return [{ v: a, kind: 'text' as Kind, text: a }, { v: b, kind: 'text' as Kind, status: td ? statusOf(td) : undefined, text: b }];
  });
  return { cols: ['item', 'value'], rows };
}

// sections: every grid and property card on the page, in page order, each named by the heading above it.
export function sections(root: ParentNode, fallback: string): Section[] {
  let heading = fallback;
  const out: Section[] = [];
  for (const e of root.querySelectorAll('h2, h3, h4, table.grid, table.props')) {
    if (e.tagName !== 'TABLE') { heading = text(e) || fallback; continue; }
    const t = e as HTMLTableElement;
    // a 'the newest 500 of 1,234 samples' line right above the grid rides into the Summary sheet: the rows taken are not all
    const prev = (t.parentElement?.classList.contains('grid-wrap') ? t.parentElement : t).previousElementSibling;
    const note = prev && prev.matches('p.meta') && /\d\S* of \d/.test(text(prev)) ? text(prev) : undefined;
    out.push({ name: heading, ...(t.classList.contains('grid') ? readGrid(t) : readProps(t)), note });
  }
  return out;
}

// ---- the workbook -----------------------------------------------------------------------------------------

// the light theme's status colours (app.css :root): the cell's background and its text
const fillOf: Record<Status, string> = { ok: 'FFE3F4E6', warn: 'FFFFF1D6', crit: 'FFFDE2E2', none: 'FFEEF1F5' };
const fontOf: Record<Status, string> = { ok: 'FF237A35', warn: 'FF9A5A00', crit: 'FFC42626', none: 'FF5D6676' };
const headFill = 'FFDDE1E8';
// numFmt ids: 3 is Excel's built-in '#,##0'; 164 on are this file's own
const fmtId: Record<Kind, number> = { text: 0, int: 3, dec: 164, bytes: 165, secs: 166, pct: 167, date: 168, nsecs: 169, msecs: 170 };
const customFmts: [number, string][] = [[164, '#,##0.00'], [165, '#,##0" B"'], [166, '[h]:mm:ss'], [167, '#,##0.00" %"'], [168, 'yyyy-mm-dd hh:mm:ss'], [169, '#,##0" s"'], [170, '#,##0.###" ms"']];

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
  id(kind: Kind, status?: Status, head = false): number {
    const fill = head ? this.fill(headFill) : status ? this.fill(fillOf[status]) : 0;
    const font = head ? this.font('FF1D2330', true) : status ? this.font(fontOf[status], status !== 'none') : 0;
    const k = `${fmtId[kind]}|${fill}|${font}`;
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

// the width a cell's content needs, in Excel's character units
function widthOf(c: Cell): number {
  if (c.kind === 'date') return 19;
  if (c.kind === 'secs' || c.kind === 'nsecs') return 12;
  if (typeof c.v === 'number') return Math.round(Math.abs(c.v)).toLocaleString('en-US').length + (c.kind === 'int' ? 1 : 4);
  return c.text.length;
}

interface Sheet { name: string; head: string[]; rows: Cell[][]; freeze: boolean }

function sheetXml(sh: Sheet, st: Styles): string {
  const ncol = Math.max(sh.head.length, ...sh.rows.map(r => r.length), 1);
  const widths = Array.from({ length: ncol }, (_, j) => Math.min(60, Math.max(8, (sh.head[j] ?? '').length + 3, ...sh.rows.map(r => r[j] ? widthOf(r[j]) + 1 : 0))));
  const cell = (ref: string, c: Cell, s: number) => {
    if (typeof c.v === 'number') return `<c r="${ref}" s="${s}"><v>${String(c.v).toUpperCase()}</v></c>`;
    if (c.v === '') return s ? `<c r="${ref}" s="${s}"/>` : '';
    // Excel holds at most 32,767 characters in a cell (a longer one opens with a repair): the rest is cut, said in the cell
    const v = c.v.length > 32767 ? c.v.slice(0, 32700) + ' ... [cut at Excel\'s cell limit]' : c.v;
    return `<c r="${ref}" s="${s}" t="inlineStr"><is><t xml:space="preserve">${esc(v)}</t></is></c>`;
  };
  const hs = st.id('text', undefined, sh.freeze);
  const rows = [`<row r="1">${sh.head.map((h, j) => cell(colName(j) + '1', { v: h, kind: 'text', text: h }, hs)).join('')}</row>`];
  sh.rows.forEach((r, i) => rows.push(`<row r="${i + 2}">${r.map((c, j) => cell(colName(j) + (i + 2), c, st.id(c.kind, c.status))).join('')}</row>`));
  const last = `${colName(ncol - 1)}${sh.rows.length + 1}`;
  return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    + '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    + `<dimension ref="A1:${last}"/>`
    + (sh.freeze ? '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/><selection pane="bottomLeft" activeCell="A2" sqref="A2"/></sheetView></sheetViews>'
      : '<sheetViews><sheetView workbookViewId="0"/></sheetViews>')
    + '<sheetFormatPr defaultRowHeight="15"/>'
    + `<cols>${widths.map((w, j) => `<col min="${j + 1}" max="${j + 1}" width="${w}" customWidth="1"/>`).join('')}</cols>`
    + `<sheetData>${rows.join('')}</sheetData>`
    + (sh.freeze ? `<autoFilter ref="A1:${last}"/>` : '')
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

// timeZone: the browser's zone the times in the file are written in, 'America/Los_Angeles (UTC-08:00 at export)':
// each time carries its own date's offset (a window across a DST change holds two), so the offset is the export's.
export function timeZone(at: Date): string {
  const off = -at.getTimezoneOffset(), sign = off < 0 ? '-' : '+', a = Math.abs(off);
  let name = '';
  try { name = Intl.DateTimeFormat().resolvedOptions().timeZone ?? ''; } catch { /* no Intl: the offset alone */ }
  const utc = `UTC${sign}${pad(Math.floor(a / 60))}:${pad(a % 60)} at export`;
  return (name ? `${name} (${utc})` : utc) + ", the browser's; each time in its own date's offset";
}

export function workbook(meta: Meta, secs: Section[]): { name: string; data: Uint8Array }[] {
  const names = sheetNames(secs.map(s => s.name));
  const t = (v: string): Cell => ({ v, kind: 'text', text: v });
  const d = (v: Date): Cell => ({ v: excelDate(v), kind: 'date', text: '', stamp: localStamp(v) });
  const info: Cell[][] = [
    [t('Instance'), t(meta.instance)], [t('Tab'), t(meta.tab)],
    [t('Window'), t(meta.window)], [t('Window from'), d(meta.from)], [t('Window to'), d(meta.to)],
    [t('Exported at'), d(meta.at)], [t('Time zone'), t(timeZone(meta.at))], [t('Source'), t('pgvigil')], [t(''), t('')], [t('Sheet'), t('Rows'), t('Note')],
    ...secs.map((s, i) => [t(names[i]), { v: s.rows.length, kind: 'int' as Kind, text: '' }, t(s.note ?? '')]),
  ];
  const sheets: Sheet[] = [{ name: 'Summary', head: ['Item', 'Value', 'Note'], rows: info, freeze: false },
    ...secs.map((s, i) => ({ name: names[i], head: s.cols, rows: s.rows, freeze: true }))];
  const st = new Styles();
  const enc = new TextEncoder();
  const files = sheets.map((sh, i) => ({ name: `xl/worksheets/sheet${i + 1}.xml`, data: enc.encode(sheetXml(sh, st)) }));
  const x = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';
  const filters = sheets.map((sh, i) => sh.freeze
    ? `<definedName name="_xlnm._FilterDatabase" localSheetId="${i}" hidden="1">'${esc(sh.name.replace(/'/g, "''"))}'!$A$1:$${colName(Math.max(sh.head.length, 1) - 1)}$${sh.rows.length + 1}</definedName>` : '').join('');
  return [
    { name: '[Content_Types].xml', data: enc.encode(x + '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      + '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
      + '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
      + '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
      + sheets.map((_, i) => `<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>`).join('')
      + '</Types>') },
    { name: '_rels/.rels', data: enc.encode(x + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>') },
    { name: 'xl/workbook.xml', data: enc.encode(x + '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      + `<sheets>${sheets.map((sh, i) => `<sheet name="${esc(sh.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>`).join('')}</sheets>`
      + (filters ? `<definedNames>${filters}</definedNames>` : '') + '</workbook>') },
    { name: 'xl/_rels/workbook.xml.rels', data: enc.encode(x + '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      + sheets.map((_, i) => `<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>`).join('')
      + `<Relationship Id="rId${sheets.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>`) },
    { name: 'xl/styles.xml', data: enc.encode(st.xml()) },   // after the sheets: they register the styles they use
    ...files,
  ];
}

// ---- CSV --------------------------------------------------------------------------------------------------


// csv: RFC 4180 with a UTF-8 byte-order mark (Excel reads the encoding from it); a number as its plain value (a
// duration in seconds, a size in bytes, a share in percent), a time as the local time the screen shows; a text cell
// that a spreadsheet would read as a formula (= + - @ tab CR first) gets a leading apostrophe (OWASP CSV injection).
export function csv(s: Section): string {
  const val = (c: Cell): string => {
    if (typeof c.v === 'number') {
      if (c.kind === 'date') return c.stamp ?? '';
      if (c.kind === 'secs') return String(Math.round(c.v * 86400 * 1000) / 1000);
      if (c.kind === 'msecs') return String(c.v);   // the milliseconds, as the raw value
      return String(c.v);
    }
    return /^[=+\-@\t\r]/.test(c.v) ? "'" + c.v : c.v;
  };
  const q = (v: string) => /[",\r\n]|^\s|\s$/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
  return '﻿' + [s.cols.map(q).join(','), ...s.rows.map(r => r.map(c => q(val(c))).join(','))].join('\r\n') + '\r\n';
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
const fileStamp = (d: Date) => `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}`;

async function metaOf(ctx: Ctx): Promise<Meta> {
  let instance = ctx.tag ? 'tag ' + ctx.tag : 'fleet';
  if (ctx.instance) {
    instance = 'instance ' + ctx.instance;
    try { const r = (await fleet()).instances.find(x => Number(x.instance_id) === ctx.instance); if (r) instance = String(r.name); } catch { /* the id stands */ }
  }
  const w = window_(ctx);
  const tab = (ctx.instance ? instanceTabs[ctx.tab] ?? drillTabs[ctx.tab] : rootTabs[ctx.tab]) ?? ctx.tab;
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

// exportButtons: the bar's two buttons for the page under them (#main): the workbook and the CSV.
export function exportButtons(ctx: Ctx, root: () => HTMLElement | null = () => document.getElementById('main')): HTMLElement {
  const note = el('span', { class: 'meta', role: 'status' });
  const run = async (b: HTMLButtonElement, kind: 'xlsx' | 'csv') => {
    b.disabled = true; note.textContent = '';
    try {
      const m = await metaOf(ctx);
      const r = root();
      const secs = r ? sections(r, m.tab) : [];
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
  return el('span', { class: 'export' }, x, ' ', c, ' ', note);
}
