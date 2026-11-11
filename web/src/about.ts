// The About page (#/about): what this pgvigil is and where a problem goes. It shows the server's version line, the
// repository's server version and migration level, the engines monitored (versions and counts, never a name) and the
// browser, and 'Report a problem': a mailto link to the support address with those lines filled in. The link only
// opens the reader's own mail program; pgvigil sends nothing, here or anywhere. The page reads /api/health and
// /api/instances; the route, the page table's entry and the bar's link are the shell's (router.ts, main.ts).
import { get, Row, rowsOf } from './api';
import { Ctx, href } from './router';
import { copyText, el, props } from './ui';

export const supportAddress = 'support@pgvigil.com';
// GitHub's private vulnerability reporting: the report is seen by the maintainer alone until a fix is out
export const securityUrl = 'https://github.com/aachaemenes/pgvigil/security/advisories/new';
const MAX_ENGINE_LINES = 12;   // a mailto address has no fixed limit, but mail programs cut a long one: the body stays short

export interface AboutInfo {
  version: string;        // the server's version line ('pgvigil v0.4.0 (go1.27 linux/amd64; fips140 off)'); '' = not said
  repository: string;     // the repository's PostgreSQL version; '' = not said
  migration: string;      // the newest migration applied; '' = none read
  engines: string[];      // one line per engine, version and platform: '3 x PostgreSQL 18.1 (aurora)'
  browser: string;
}

const engineName = (e: unknown) => e === 'sqlserver' ? 'SQL Server' : 'PostgreSQL';

// engineLines: the instances counted per engine, version and platform, the most frequent first; no instance is named
export function engineLines(instances: Row[]): string[] {
  const n = new Map<string, number>();
  for (const r of instances) {
    const ver = String(r.server_version ?? '').trim() || 'version not read';
    const key = `${engineName(r.engine)} ${ver} (${String(r.platform ?? '') || 'platform not read'})`;
    n.set(key, (n.get(key) ?? 0) + 1);
  }
  const lines = [...n.entries()].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0])).map(([k, c]) => `${c} x ${k}`);
  return lines.length > MAX_ENGINE_LINES ? [...lines.slice(0, MAX_ENGINE_LINES), `and ${lines.length - MAX_ENGINE_LINES} more version(s)`] : lines;
}

// the short version of a version line: its second word ('pgvigil v0.4.0 (...)' gives 'v0.4.0')
export const shortVersion = (line: string) => line.trim().split(/\s+/)[1] ?? '';

// reportBody: the mail's text. The first lines are the reader's to write; the block under them is what pgvigil knows
// about itself. Nothing in it names a server, a database, a user or this site's address.
export function reportBody(a: AboutInfo): string {
  return [
    'What happened, what you expected instead, and the page it was on:',
    '',
    '',
    '',
    '--- filled in by pgvigil; change or remove anything before you send ---',
    'pgvigil: ' + (a.version || 'version not read'),
    'Repository: ' + (a.repository ? 'PostgreSQL ' + a.repository : 'version not read') + ', migration ' + (a.migration || 'not read'),
    'Monitored: ' + (a.engines.length ? a.engines.join('; ') : 'no instance yet'),
    'Browser: ' + a.browser,
  ].join('\r\n');
}

// reportMailto: the link 'Report a problem' opens (RFC 6068: the subject and the body percent-encoded, CRLF line ends)
export function reportMailto(a: AboutInfo): string {
  const v = shortVersion(a.version);
  const subject = 'pgvigil problem report' + (v ? ` (${v})` : '');
  return `mailto:${supportAddress}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(reportBody(a))}`;
}

// readAbout: the page's facts. A part that cannot be read stays empty and the page says so; the link still works.
export async function readAbout(): Promise<AboutInfo> {
  const [health, inst] = await Promise.all([
    get('health').then(t => rowsOf(t)[0] ?? {}),
    get('instances').then(rowsOf).catch(() => [] as Row[]),
  ]);
  return {
    version: String(health.version ?? '').trim(),
    repository: String(health.repository_version ?? '').trim(),
    migration: String(health.schema_version ?? '').trim().replace(/\.sql$/, ''),
    engines: engineLines(inst),
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
      ['Monitored', a.engines.length ? lines(a.engines) : 'no instance yet'],
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
    el('h2', {}, 'Security'),
    el('p', {}, 'A vulnerability is reported privately, not by mail: ',
      el('a', { href: securityUrl, target: '_blank', rel: 'noopener noreferrer' }, 'Report a vulnerability on GitHub'),
      ' (the report is private until a fix is released).'));
}
