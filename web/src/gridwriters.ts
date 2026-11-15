// The grid menu's writers (task GM, DBA Dash's grid menu: Copy > As Markdown / As JSON, Export file > CSV / JSON /
// Markdown / HTML / SQL (INSERT) for PostgreSQL / for SQL Server): each takes the grid as the copies and the export read it
// (the shown rows in the shown order, the hidden columns left out: gridtools.ts shown, export.ts readGrid) and returns
// the text. A value comes from export.ts rawValue (an empty cell null, a duration in seconds, a percent as shown, a time
// ISO 8601 with its offset); the words a cell shows go where a form writes words (Markdown). Nothing is fetched or sent:
// the text goes to the clipboard or to a file the browser saves.
import { Cell, fillOf, fontOf, headFill, linkFill, linkFont, rawValue, Status } from './export';

// a grid as the writers take it: its header, its rows, which columns are numbers (Markdown aligns them right), a stored
// sample's mark (community.ts data-sample: written first in every form, so a copy is never read as the instance's own)
export interface Grid { cols: string[]; rows: Cell[][]; num?: boolean[]; sample?: string; name?: string }

const NUMBER_KINDS = new Set(['int', 'dec', 'bytes', 'secs', 'nsecs', 'msecs', 'pct', 'days']);
// numberCol: every non-empty cell of the column has a number kind (one text among them makes it a text column)
function numberCol(g: Grid, j: number): boolean {
  let any = false;
  for (const r of g.rows) { const c = r[j]; if (!c || c.v === '') continue; if (typeof c.v !== 'number' || !NUMBER_KINDS.has(c.kind)) return false; any = true; }
  return any;
}
const words = (c: Cell | undefined) => (c?.text ?? '').replace(/[\t\r\n]+/g, ' ');

// keys: the header as object keys and column names: duplicates numbered name_1, name_2 (DBA Dash's JSON); empty = ''
function keys(cols: string[]): string[] {
  const seen = new Map<string, number>();
  return cols.map(c => { const n = seen.get(c) ?? 0; seen.set(c, n + 1); return n ? `${c}_${n}` : c; });
}

// ---- Markdown -------------------------------------------------------------------------------------------------

const mdCell = (v: string) => v.replace(/[\\|*_`<[\]]/g, '\\$&');
// markdown: a pipe table of the words shown; standard = DBA Dash's plain form, prettified = every column padded to its
// widest cell (one width a line); a number column right-aligned; a sample's mark the first line
export function markdown(g: Grid, pretty: boolean): string {
  const num = g.cols.map((_, j) => g.num?.[j] ?? numberCol(g, j));
  const table = [g.cols.map(c => mdCell(c || ' ')), ...g.rows.map(r => g.cols.map((_, j) => mdCell(words(r[j]))))];
  const w = g.cols.map((_, j) => Math.max(3, ...table.map(r => [...r[j]].length)));
  const pad = (v: string, j: number) => !pretty ? v : num[j] ? ' '.repeat(w[j] - [...v].length) + v : v + ' '.repeat(w[j] - [...v].length);
  const line = (r: string[]) => `| ${r.map(pad).join(' | ')} |`;
  const rule = `| ${g.cols.map((_, j) => { const d = '-'.repeat(pretty ? w[j] - (num[j] ? 1 : 0) : 3); return num[j] ? d + ':' : d; }).join(' | ')} |`;
  return (g.sample ? mdCell(g.sample) + '\n\n' : '') + [line(table[0]), rule, ...table.slice(1).map(line)].join('\n') + '\n';
}

// ---- JSON -----------------------------------------------------------------------------------------------------

// json: an array of objects keyed by the header (duplicates name_1), each value rawValue's; a sample's grid
// {"sample": "<its mark>", "rows": [...]} (a plain array otherwise)
export function json(g: Grid, pretty: boolean): string {
  const ks = keys(g.cols);
  const rows = g.rows.map(r => Object.fromEntries(ks.map((k, j) => [k, r[j] ? rawValue(r[j]) : null])));
  return JSON.stringify(g.sample ? { sample: g.sample, rows } : rows, null, pretty ? 2 : undefined);
}

// ---- tab-separated (Copy > Grid, Column, Row, Selected) ----------------------------------------------------------

export const tsv = (g: Grid, header = true) => [...(header ? [g.cols.map(c => c.replace(/[\t\r\n]+/g, ' '))] : []), ...g.rows.map(r => g.cols.map((_, j) => words(r[j])))].map(r => r.join('\t')).join('\n');

// ---- HTML (a whole document) ------------------------------------------------------------------------------------

const html = (v: string) => v.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const rgb = (argb: string) => '#' + argb.slice(2).toLowerCase();
// htmlDoc: the grid as a page of its own with each cell's colours (the export's header blue, a status fill with its
// text colour, a link cell's light fill), one class per distinct look in a style block (a 10,000-row grid is not a
// style per cell); the title and every word escaped
export function htmlDoc(g: Grid, title: string): string {
  const num = g.cols.map((_, j) => g.num?.[j] ?? numberCol(g, j));
  const looks = new Map<string, string>();
  const cls = (css: string) => { let k = looks.get(css); if (!k) { k = 'c' + looks.size; looks.set(css, k); } return k; };
  const td = (c: Cell | undefined, j: number) => {
    const st: Status | undefined = c?.status;
    const css = [st ? `background:${rgb(fillOf[st])};color:${rgb(fontOf[st])}` : c?.link ? `background:${rgb(linkFill)};color:${rgb(linkFont)}` : '', num[j] ? 'text-align:right' : ''].filter(Boolean).join(';');
    return css ? `<td class="${cls(css)}">${html(words(c))}</td>` : `<td>${html(words(c))}</td>`;
  };
  const body = g.rows.map(r => `<tr>${g.cols.map((_, j) => td(r[j], j)).join('')}</tr>`).join('\n');
  const style = 'table{border-collapse:collapse}th,td{border:1px solid #c8ccd4;padding:3px 8px;font:11pt Calibri,Arial,sans-serif;white-space:nowrap}'
    + `th{background:${rgb(headFill)};color:#ffffff;font-weight:bold;text-align:left}`
    + [...looks].map(([css, k]) => `.${k}{${css}}`).join('');
  return `<!doctype html>\n<html><head><meta charset="utf-8"><title>${html(title)}</title><style>${style}</style></head><body>\n`
    + (g.sample ? `<p>${html(g.sample)}</p>\n` : '')
    + `<table><thead><tr>${g.cols.map(c => `<th>${html(c)}</th>`).join('')}</tr></thead><tbody>\n${body}\n</tbody></table>\n</body></html>\n`;
}

// ---- SQL (INSERT) -----------------------------------------------------------------------------------------------

export type Engine = 'postgres' | 'sqlserver';
export interface SqlHead { title: string; zone: string; at: string }
const BATCH = 1000;   // rows a VALUES list holds (SQL Server takes 1,000 at most)
const bytes = (s: string) => new TextEncoder().encode(s).length;

// sqlNames: the header as column names: an empty one column_<n>, duplicates _1, cut to the engine's length with a
// suffix (SQL Server 128 characters, PostgreSQL 63 bytes), each quoted ("x" with " doubled, [x] with ] doubled)
function sqlNames(cols: string[], e: Engine): string[] {
  const named = keys(cols.map((c, j) => c.trim() === '' ? `column_${j + 1}` : c));
  const cut = named.map((n, j) => {
    if (e === 'sqlserver') return n.length > 128 ? n.slice(0, 120) + '_' + (j + 1) : n;
    if (bytes(n) <= 63) return n;
    let s = n; while (bytes(s + '_' + (j + 1)) > 63) s = s.slice(0, -1);
    return s + '_' + (j + 1);
  });
  return cut.map(n => e === 'sqlserver' ? '[' + n.replace(/]/g, ']]') + ']' : '"' + n.replace(/"/g, '""') + '"');
}

// a column's type from its cells' kinds: a number type only when every non-empty cell is a number (whole numbers alone:
// bigint), a time with its offset, a date, a boolean; anything else text
function sqlType(g: Grid, j: number, e: Engine): string {
  const cs = g.rows.map(r => r[j]).filter((c): c is Cell => !!c && c.v !== '');
  const all = (k: string) => cs.length > 0 && cs.every(c => typeof c.v === 'number' && c.kind === k);
  if (numberCol(g, j)) return cs.every(c => { const v = rawValue(c); return typeof v === 'number' && Number.isInteger(v) && Math.abs(v) <= Number.MAX_SAFE_INTEGER; }) ? (e === 'sqlserver' ? 'BIGINT' : 'bigint') : (e === 'sqlserver' ? 'DECIMAL(38,10)' : 'numeric');
  if (all('date')) return e === 'sqlserver' ? 'DATETIMEOFFSET' : 'timestamptz';
  if (all('day')) return e === 'sqlserver' ? 'DATE' : 'date';
  if (all('bool')) return e === 'sqlserver' ? 'BIT' : 'boolean';
  return e === 'sqlserver' ? 'NVARCHAR(MAX)' : 'text';
}

// sqlScript: a temp table and its rows as INSERT batches, DBA Dash's script shape for each engine. A string is quoted
// with ' doubled (N'' on SQL Server); PostgreSQL's script sets standard_conforming_strings on first, so a backslash is
// never an escape whatever the server's setting; NUL characters are dropped (neither engine stores one in text) and the
// header says so; a number is written from its value (String(n)), never the words shown; a time with its offset. The
// header names the grid, the zone, the export time and a sample's mark, each a comment line of its own.
export function sqlScript(g: Grid, e: Engine, head: SqlHead): string {
  const ms = e === 'sqlserver';
  const names = sqlNames(g.cols, e), types = g.cols.map((_, j) => sqlType(g, j, e));
  let nuls = 0;
  const str = (s: string) => { const t = s.replace(/\u0000/g, () => { nuls++; return ''; }); return (ms ? "N'" : "'") + t.replace(/'/g, "''") + "'"; };
  const text = ms ? 'NVARCHAR(MAX)' : 'text', bool = ms ? 'BIT' : 'boolean', num = new Set(ms ? ['BIGINT', 'DECIMAL(38,10)'] : ['bigint', 'numeric']);
  const lit = (c: Cell | undefined, j: number): string => {
    const v = c ? rawValue(c) : null;
    if (v === null) return 'NULL';
    if (types[j] === bool) return ms ? (v ? '1' : '0') : (v ? 'true' : 'false');
    if (num.has(types[j])) return String(v);
    // a text column: the words a boolean shows, a number's value written as text, any other value as it is
    return str(types[j] === text && typeof v === 'boolean' ? c!.text : String(v));
  };
  const tuples = g.rows.map(r => '(' + g.cols.map((_, j) => lit(r[j], j)).join(', ') + ')');
  const table = ms ? '#pgvigil_grid' : 'pg_temp.pgvigil_grid';
  const cols = names.join(', ');
  const inserts: string[] = [];
  for (let i = 0; i < tuples.length; i += BATCH) {
    inserts.push(`INSERT INTO ${table} (${cols}) VALUES\n${tuples.slice(i, i + BATCH).join(',\n')};` + (ms ? '\nGO' : ''));
  }
  const comment = (s: string) => '-- ' + s.replace(/[\r\n\u0000]+/g, ' ');
  const header = [
    comment(`pgvigil grid: ${head.title}; ${g.rows.length} row(s); exported ${head.at}`),
    comment(`times: ${head.zone} (each written with its own offset)`),
    ...(g.sample ? [comment(g.sample)] : []),
    ...(nuls ? [comment(`${nuls} NUL character(s) dropped: neither engine stores one in text`)] : []),
  ];
  const create = `(\n${names.map((n, j) => `  ${n} ${types[j]}${ms ? ' NULL' : ''}`).join(',\n')}\n)`;
  const body = ms
    ? ['SET NOCOUNT ON;', "IF OBJECT_ID('tempdb..#pgvigil_grid') IS NOT NULL DROP TABLE #pgvigil_grid;", 'GO', `CREATE TABLE #pgvigil_grid ${create};`, 'GO', ...inserts, 'SELECT * FROM #pgvigil_grid;', '-- DROP TABLE #pgvigil_grid;']
    : ['SET standard_conforming_strings = on;', "SET client_encoding = 'UTF8';", 'DROP TABLE IF EXISTS pg_temp.pgvigil_grid;', `CREATE TEMP TABLE pgvigil_grid ${create};`, ...inserts, 'SELECT * FROM pg_temp.pgvigil_grid;', '-- DROP TABLE pg_temp.pgvigil_grid;'];
  // the header is written last (the NUL count is known only after the rows); PostgreSQL's first statement stays the SET
  return [...header, ...body].join('\n') + '\n';
}
