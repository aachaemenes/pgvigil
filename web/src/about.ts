// The About page (#/about): what this pgvigil is and where a problem goes. It shows the server's version line, the
// repository's server version and migration level, the engines monitored (versions and counts, never a name) and the
// browser, and 'Report a problem': a mailto link to the support address with those lines filled in. The link only
// opens the reader's own mail program: pgvigil sends no report itself. The page reads /api/health and
// /api/instances, and still opens when either fails (that is when a problem is reported); the route, the page
// table's entry and the bar's link are the shell's (router.ts, main.ts).
import { get, LoginRequired, Row, rowsOf } from './api';
import { Ctx, href } from './router';
import { copyText, el, props } from './ui';

export const supportAddress = 'support@pgvigil.com';
// GitHub's private vulnerability reporting: the report stays between its reporter and the maintainers until the
// advisory is published
export const securityUrl = 'https://github.com/aachaemenes/pgvigil/security/advisories/new';
const MAX_ENGINE_LINES = 12;
// a mailto address has no fixed limit, but mail programs cut or refuse a long one: the encoded body stays under this
const MAX_BODY_ENCODED = 1500;

export interface AboutInfo {
  version: string;           // the server's version line ('pgvigil v0.4.0 (go1.27 linux/amd64; fips140 off)'); '' = not read
  repository: string;        // the repository's PostgreSQL version; '' = not read
  migration: string;         // the newest migration applied; '' = not read
  engines: string[] | null;  // one line per engine, version and platform ('3 x PostgreSQL 18.1 (aurora)'); null = not read
  browser: string;
}

const engineName = (e: unknown) => e === 'sqlserver' ? 'SQL Server' : 'PostgreSQL';
// a SQL Server reports the first line of @@VERSION ('Microsoft SQL Server 2022 (RTM-CU14) (KB...) - 16.0.4135.4 (X64)'):
// its build number says the same in a fraction of the length; any other long version text is cut
function shortServerVersion(engine: unknown, v: unknown): string {
  const s = String(v ?? '').trim();
  if (!s) return 'version not read';
  const build = engine === 'sqlserver' ? /\d+\.\d+\.\d+\.\d+/.exec(s)?.[0] : undefined;
  return build ?? (s.length > 48 ? s.slice(0, 48) + '...' : s);
}

// engineLines: the instances counted per engine, version and platform, the most frequent first; no instance is named
export function engineLines(instances: Row[]): string[] {
  const n = new Map<string, number>();
  for (const r of instances) {
    const key = `${engineName(r.engine)} ${shortServerVersion(r.engine, r.server_version)} (${String(r.platform ?? '') || 'platform not read'})`;
    n.set(key, (n.get(key) ?? 0) + 1);
  }
  return [...n.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([k, c]) => `${c} x ${k}`);
}

// the short version of a version line: its second word ('pgvigil v0.4.0 (...)' gives 'v0.4.0')
export const shortVersion = (line: string) => line.trim().split(/\s+/)[1] ?? '';

// the body with the first `lines` engine lines and a count of the rest
function bodyWith(a: AboutInfo, lines: number): string {
  const e = a.engines;
  const monitored = e === null ? 'not read' : e.length === 0 ? 'no instance yet'
    : e.slice(0, lines).join('; ') + (e.length > lines ? `; and ${e.length - lines} more version(s)` : '');
  return [
    'What happened, what you expected instead, and the page it was on:',
    '',
    '',
    '',
    '--- filled in by pgvigil; change or remove anything before you send ---',
    'pgvigil: ' + (a.version || 'version not read'),
    'Repository: ' + (a.repository ? 'PostgreSQL ' + a.repository : 'version not read') + ', migration ' + (a.migration || 'not read'),
    'Monitored: ' + monitored,
    'Browser: ' + a.browser,
  ].join('\r\n');
}

// reportBody: the mail's text. The first lines are the reader's to write; the block under them is what pgvigil knows
// about itself. Nothing in it names a server, a database, a user or this site's address. At most MAX_ENGINE_LINES
// engine lines, and fewer while the encoded text is over MAX_BODY_ENCODED (a fleet of many versions): the rest is a count.
export function reportBody(a: AboutInfo): string {
  let lines = Math.min(MAX_ENGINE_LINES, a.engines?.length ?? 0);
  let body = bodyWith(a, lines);
  while (lines > 1 && encodeURIComponent(body).length > MAX_BODY_ENCODED) body = bodyWith(a, --lines);
  return body;
}

// reportMailto: the link 'Report a problem' opens (RFC 6068: the subject and the body percent-encoded, CRLF line ends)
export function reportMailto(a: AboutInfo): string {
  const v = shortVersion(a.version);
  const subject = 'pgvigil problem report' + (v ? ` (${v})` : '');
  return `mailto:${supportAddress}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(reportBody(a))}`;
}

// readAbout: the page's facts. A part that cannot be read is said as not read, never as empty, and the page still
// opens: a repository that does not answer is a problem to report. Only a missing login is passed on (the shell
// shows its sign-in form).
export async function readAbout(): Promise<AboutInfo> {
  const orLogin = (e: unknown) => { if (e instanceof LoginRequired) throw e; return null; };
  const [health, inst] = await Promise.all([
    get('health').then(t => (rowsOf(t)[0] ?? {}) as Row).catch(orLogin),
    get('instances').then(rowsOf).catch(orLogin),
  ]);
  return {
    version: String(health?.version ?? '').trim(),
    repository: String(health?.repository_version ?? '').trim(),
    migration: String(health?.schema_version ?? '').trim().replace(/\.sql$/, ''),
    engines: inst === null ? null : engineLines(inst),
    browser: navigator.userAgent,
  };
}

// aboutLink: the bar's way to the page, from any page (the address carries the time range like every link)
export function aboutLink(ctx: Ctx): HTMLElement {
  return el('a', { href: href(ctx, { tab: 'about', instance: undefined, tag: undefined }) }, 'About');
}

export async function aboutView(_ctx: Ctx): Promise<HTMLElement> {
  const a = await readAbout();
  const lines = (list: string[]) => { const d = el('div'); for (const l of list) d.append(el('div', {}, l)); return d; };
  const mail = el('a', { href: reportMailto(a) }, 'Report a problem');
  const body = reportBody(a);
  const copied = el('span', { class: 'meta', role: 'status' });
  const copy = el('button', { type: 'button', class: 'link' }, 'Copy these lines');
  copy.addEventListener('click', () => {
    void copyText(body.replace(/\r\n/g, '\n')).then(ok => { copied.textContent = ok ? ' Copied.' : ' Not copied: the browser refused the clipboard.'; });
  });
  return el('section', {},
    el('h2', {}, 'About pgvigil'),
    props([
      ['Version', a.version || 'not read'],
      ['Repository', (a.repository ? 'PostgreSQL ' + a.repository : 'version not read') + ', migration ' + (a.migration || 'not read')],
      ['Monitored', a.engines === null ? 'not read' : a.engines.length ? lines(a.engines) : 'no instance yet'],
      ['Browser', a.browser],
    ]),
    el('h2', {}, 'Support'),
    el('p', {}, 'Questions and problems go to ', el('a', { href: 'mailto:' + supportAddress }, supportAddress), '.'),
    el('p', {}, mail, ' opens a mail to that address in your own mail program, with the lines below filled in. ',
      'Nothing is sent until you send it there: pgvigil does not send a report itself.'),
    el('pre', { class: 'sql' }, body.replace(/\r\n/g, '\n')),   // wraps (pre.sql), so it never scrolls: no tab stop of its own
    el('p', {}, copy, copied),
    el('h2', {}, 'A report with more detail'),
    el('p', {}, 'On the host that runs pgvigil, ', el('code', {}, 'pgvigil report -config pgvigil.yaml'),
      ' writes a zip into the folder it is run in: the configuration with every secret and name masked, the versions, the repository\'s ',
      'migration level and the last collection errors. It sends nothing either: read it, then attach it to your mail.'),
    el('h2', {}, 'Thanks'),
    el('p', {}, 'The imported SQL Server servers are read from DBA Dash repositories; pgvigil\'s collection catalog and several of its SQL Server reads were shaped by DBA Dash (https://github.com/trimble-oss/dba-dash, MIT, Copyright 2022 Trimble, Inc.). Thank you to its author and contributors; THIRD-PARTY-NOTICES has the notice.'),
    el('h2', {}, 'Security'),
    el('p', {}, 'A vulnerability is reported privately, not by mail: ',
      el('a', { href: securityUrl, target: '_blank', rel: 'noopener noreferrer' }, 'Report a vulnerability on GitHub (opens in a new tab)'),
      '. The report stays between you and the maintainers until the advisory is published.'));
}
