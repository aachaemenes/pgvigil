// Sheet names of an exported workbook (export.ts: the bar's workbook, a grid's own export, the CSV zip's file names).
// Pure, no DOM: its unit tests run in Node (export_names.test.mjs, compiled by web's esbuild; scripts/proof-export.sh).
//
// A sheet is named by the screen's heading above its grid, cut to Excel's 31 characters; never numbered (X2: a ' (2)'
// names nothing). Where two names would be equal:
//   - two headings equal after the cut keep the start and the words where they part ('DatabaseBackup - USER_DAT… FULL');
//   - a heading equal in full to a name taken (the reserved 'History', the export's own 'About', a heading twice) is
//     named with the heading above it ('Trace flags History');
//   - two headings equal in full under one heading above: the number stays the last resort, so the file still opens
//     (Excel refuses two equal names) and the X rules fail it (xlsx-check.py X2).

export const SHEET_MAX = 31;
const REFUSED = /[\\/?*[\]:]/g;
// a time the heading carries is left out of the sheet's name (the grid's own title; 'About' holds the window): the page's
// own time shapes only - a date with a 4-digit year in any locale's order and a clock after it (tz.ts fmt, router.ts
// rangeLabel's two of them) - in brackets ('Jobs (read 11/13/2026, 05:25:00)', a chart's '(11/6/2026, 04:42:56 to ...)')
// or after a word ('Per day since 11/6/2026, 20:22'). An address, a version or a day alone is no read time and stays.
const DAY = String.raw`(?:\d{4}[/.-]\d{1,2}[/.-]\d{1,2}|\d{1,2}[/.-]\d{1,2}[/.-]\d{4})`;
const CLOCK = String.raw`,?\s*\d{1,2}:\d{2}(?::\d{2})?(?:\s*[AP]M)?`;
const READ_TIME = new RegExp(String.raw`\s*\((?:read\s+)?[^()]*${DAY}${CLOCK}[^()]*\)`, 'g');
const AT_TIME = new RegExp(String.raw`\s*(?:\b(?:since|from|until|to|at|as of|read|of)\s+)?${DAY}${CLOCK}`, 'gi');
// a rate's slash (Excel refuses '/' in a name): 'Transactions/s' reads 'Transactions per s'
const PER = /(\S)\/(s|sec|min|h|hr|day)\b/g;
// a bare count the heading carries in brackets ('Findings (16)': its rows, which 'About' holds) reads as a numbered repeat
// in a sheet's name (X2) and is left out too; a count with its word stays ('Fastest-growing tables (7 days)')
const COUNT = /\s*\(\d{1,3}(?:[,.\s\u202f\u00a0]\d{3})*\)$/;   // '(16)', '(1,234)', '(1 234)'; not an address '(10.0.0.5)'
const SEP = /[\s_.-]/;

// clean: each character Excel refuses a space, each run of spaces one space, spaces and quotes at either end off (Excel
// refuses a name that starts or ends with a quote; a refused character turned space no longer shields one)
const clean = (s: string) => s.replace(PER, '$1 per $2').replace(REFUSED, ' ').replace(/\s+/g, ' ').replace(/^[\s']+|[\s']+$/g, '');

// sheetTitle: the heading's words as a sheet name may hold them, not cut: a time and a bare count out, then clean
export function sheetTitle(n: string): string {
  const t = n.replace(READ_TIME, '').replace(AT_TIME, '').trim().replace(COUNT, '').trim() || n;
  return clean(t);
}

// ownName: a section the page names itself (data-sheet: a job's disclosure) that holds a heading of its own ('Steps',
// 'Step runs'): the page's name as it is (a job's name keeps every word: no time or count is taken out of it), then the
// heading's title ('jobA Steps')
export function ownName(own: string, heading: string): string {
  return clean(`${clean(own)} ${sheetTitle(heading)}`);
}

// cut: the first n UTF-16 units (Excel's count), never half of a character past the BMP, a space or a quote at the end
// off; head: the same before an ellipsis, a separator at the end off too
const upTo = (s: string, n: number) => { let k = Math.min(n, s.length); if (k < s.length && /[\uD800-\uDBFF]/.test(s[k - 1] ?? '')) k--; return s.slice(0, k); };
const cut = (s: string, n: number) => upTo(s, n).replace(/[\s']+$/, '');
const head = (s: string, n: number) => upTo(s, n).replace(/[\s'_.-]+$/, '');

// parted: a title longer than a sheet holds, against the others its cut meets: its start, then '…' and the words where it
// parts from them (from the start of the word, a word ending at a space, '_', '.' or '-'); '' when no word parts them
export function parted(t: string, others: string[]): string {
  const lo = t.toLowerCase();
  let p = lo.length;
  for (const o of others) {
    const ol = o.toLowerCase();
    if (ol === lo) continue;
    let i = 0;
    while (i < p && i < ol.length && lo[i] === ol[i]) i++;
    p = i;
  }
  if (p >= lo.length) return '';
  // they part where a word ends: the next word on; inside a word: from its start
  if (SEP.test(t[p])) while (p < t.length && SEP.test(t[p])) p++;
  else while (p > 0 && !SEP.test(t[p - 1])) p--;
  const tail = t.slice(p).trim(), gap = p > 0 && /\s/.test(t[p - 1]) ? '… ' : '…';
  if (!tail) return '';
  if (tail.length + gap.length > SHEET_MAX - 4) return cut('…' + tail, SHEET_MAX);   // no room for the start: the words where they part on
  return head(t, SHEET_MAX - gap.length - tail.length) + gap + tail;
}

// under: the heading above, then the title ('Trace flags History'); too long: the heading above cut before an ellipsis
const under = (up: string, t: string): string => {
  const both = `${up} ${t}`;
  if (both.length <= SHEET_MAX) return clean(both);
  return clean(t.length <= SHEET_MAX - 6 ? `${head(up, SHEET_MAX - 2 - t.length)}… ${t}` : cut(both, SHEET_MAX));
};

// sheetNames: names[i] the heading above sheet i's grid, within[i] the heading above that one (an h4's h3, an h3's h2;
// a grid its disclosure names: the heading above the disclosure); taken: names the workbook holds already ('History'
// is Excel's, 'About' the export's last sheet, a page sheet's name)
// own[i]: names[i] is the page's own name (ownName, a data-sheet's): kept as it is, cleaned only
export function sheetNames(names: string[], taken: string[] = [], within: (string | undefined)[] = [], own: boolean[] = []): string[] {
  const used = new Set(['history', 'about', ...taken.map(x => x.toLowerCase())]);
  const titles = names.map((n, i) => (own[i] ? clean(n) : sheetTitle(n)) || 'Sheet');
  // a cut inside a bracket at the end leaves the bracket out ('jobA Step runs (the newest 1,000)' -> 'jobA Step runs')
  const shut = (c: string, t: string) => t.length > SHEET_MAX && /\s\([^)]*$/.test(c) ? c.replace(/\s\([^)]*$/, '') || c : c;
  const first = titles.map(t => shut(cut(t, SHEET_MAX), t) || 'Sheet');
  // the titles whose cut meets another's: each keeps the words where they part
  const byCut = new Map<string, number[]>();
  first.forEach((c, i) => byCut.set(c.toLowerCase(), [...(byCut.get(c.toLowerCase()) ?? []), i]));
  const out: string[] = [];
  titles.forEach((t, i) => {
    const group = byCut.get(first[i].toLowerCase()) ?? [];
    const cands: string[] = [];
    if (group.length > 1 && t.length > SHEET_MAX) { const p = parted(t, group.map(k => titles[k])); if (p) cands.push(clean(p)); }
    cands.push(first[i]);
    const up = sheetTitle(within[i] ?? '');
    if (up && up.toLowerCase() !== t.toLowerCase()) cands.push(under(up, t));
    let s = cands.find(c => !used.has(c.toLowerCase()));
    // the last resort: two headings equal in full under one heading (the X rules fail it: name the page)
    for (let k = 2; !s; k++) { const c = cut(first[i], SHEET_MAX - ` (${k})`.length) + ` (${k})`; if (!used.has(c.toLowerCase())) s = c; }
    used.add(s.toLowerCase());
    out.push(s);
  });
  return out;
}
