// Documentation links (task 412, B19; SQLMonitor's links, Microsoft's pages first): a wait type links to Microsoft's
// sys.dm_os_wait_stats page (one table of every type, no anchor per type) and then to SQLskills' page of the type; an
// error number to Microsoft's page of its number range (a page per number exists only 'where applicable', so the range
// page, which always exists); a build to its own page, which the API reads at serve time from the build catalogue
// (build_url, build_url_words; newest_url, newest_url_words). Every link opens in a new tab and says so in its
// accessible name; no text of those pages is copied here.
import { el } from './ui';

export const msWaitsUrl = 'https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-os-wait-stats-transact-sql';
export const sqlskillsWaitUrl = (type: string) => 'https://www.sqlskills.com/help/waits/' + encodeURIComponent(type.toLowerCase());
const msErrorsBase = 'https://learn.microsoft.com/en-us/sql/relational-databases/errors-events/database-engine-events-and-errors-';

// Microsoft's error range pages (database-engine-events-and-errors, read 11-15): 0-999, a page per thousand up to
// 10000-10999, then the wider ranges below; 50,000 and above are user-defined messages (no page)
const errorRanges: [number, number][] = [
  [0, 999], [1000, 1999], [2000, 2999], [3000, 3999], [4000, 4999], [5000, 5999], [6000, 6999], [7000, 7999], [8000, 8999],
  [9000, 9999], [10000, 10999], [11000, 12999], [13000, 13999], [14000, 14999], [15000, 15999], [16000, 17999],
  [18000, 18999], [19000, 20999], [21000, 21999], [22000, 22999], [23000, 25999], [26000, 27999], [28000, 30999],
  [31000, 41399], [41400, 49999],
];

// docLink: one link that opens in a new tab: the visible words short, the accessible name and the title whole
export function docLink(href: string, words: string, full = words): HTMLElement {
  const name = `${full} (opens in a new tab)`;
  return el('a', { href, target: '_blank', rel: 'noopener noreferrer', class: 'doclink', title: name, 'aria-label': name }, words);
}

// errorRange: the Microsoft range page of an error number, or null (a user-defined message, a negative or no number)
export function errorRange(n: number): [number, number] | null {
  if (!Number.isInteger(n) || n < 0) return null;
  return errorRanges.find(([lo, hi]) => n >= lo && n <= hi) ?? null;
}
export const errorRangeUrl = ([lo, hi]: [number, number]) => `${msErrorsBase}${lo}-to-${hi}`;

// errorCell: an error number with its range page beside it; 50,000 and above say 'a user-defined message'; 0 or none
// is empty (a job step that raised none)
export function errorCell(v: unknown): HTMLElement | string {
  if (v == null || v === '' || Number(v) === 0) return '';
  const n = Number(v), r = errorRange(n);
  if (r) return el('span', {}, String(v), ' ', docLink(errorRangeUrl(r), 'Microsoft', `Microsoft: database engine errors ${r[0]} to ${r[1]}`));
  return el('span', { title: n >= 50000 ? 'a user-defined message: no Microsoft page' : '' }, String(v), n >= 50000 ? ' (a user-defined message)' : '');
}

// waitDocs: the two links of a wait type, to put beside the type's own cell text
export function waitDocs(type: unknown): HTMLElement | string {
  const t = String(type ?? '').trim();
  if (!t) return '';
  return el('span', { class: 'doclinks' }, ' ',
    docLink(msWaitsUrl, 'Microsoft', `Microsoft: ${t} in the wait types list`), ' ',
    docLink(sqlskillsWaitUrl(t), 'SQLskills', `SQLskills: ${t}`));
}

// waitDocsNote: said once on a page that links wait types (SQLskills' library holds most types, not every one)
export const waitDocsNote = () => el('p', { class: 'meta' },
  'Wait types link to Microsoft\'s list of wait types and to SQLskills\' page of the type; SQLskills\' library holds most types, '
  + 'and a type it lacks opens its not-found page.');

// buildDocs: a build's links from the API's row (build_url and newest_url; none when the catalogue lacks the major)
export function buildDocs(r: Record<string, unknown>): HTMLElement | string {
  if (!r.build_url) return '';
  const parts: (Node | string)[] = [docLink(String(r.build_url), String(r.build_url_words ?? 'Microsoft'))];
  if (r.newest_url) parts.push(' - the newest build ' + String(r.newest_build ?? '') + ': ', docLink(String(r.newest_url), String(r.newest_url_words ?? 'Microsoft')));
  return el('span', { class: 'doclinks' }, ...parts);
}
