// The DBADash door's views (task 55): the SQL Server instances of the DBADash repositories the configuration names,
// with the statuses of DBADash's own Summary screen (DBADash's column headers and its words: Critical, Warning, N/A,
// OK, Acknowledged ...). pgvigil collects nothing from SQL Server: every status here is DBADash's, read every 5 minutes
// from its repository with a read-only login.
//   #/dbadash                      every repository and every instance (one row each, a cell per DBADash status)
//   #/dbadash?dr=<repo>            one repository
//   #/dbadash?dr=<repo>&di=<id>    one DBADash instance: its statuses, the last collection, the repository it came from,
//                                  and the status changes of the window
// The tree's folders ("DBADash: <repository>", a node per SQL Server instance) are dbadashFolders, which the shell's
// tree.ts draws below the PostgreSQL folders. A DBADash GUI has no URL: the page names the instance and the repository
// and links nowhere outside pgvigil.
import { get, LoginRequired, Row, rowsOf, Table } from './api';
import { Ctx, href, window_ } from './router';
import { hashParam } from './dbinfo';
import { badge, Col, dot, el, fmtTime, grid, props, tile } from './ui';

interface DBADashData { repositories: Table | null; fleet: Table | null; checks: Table | null }
interface DBADashInstance { instance: Table | null; statuses: Table | null; changes: Table | null }

// DBADash's codes (DBADashStatusEnum) and pgvigil's colour for each: 1 Critical, 2 Warning, 6 Warning (low) are the
// two alarm levels; N/A, Acknowledged, Information and Disabled are shown muted; OK green.
export const words: Record<number, string> = { 1: 'Critical', 2: 'Warning', 3: 'N/A', 4: 'OK', 5: 'Acknowledged', 6: 'Warning (low)', 7: 'Information', 8: 'Disabled' };
export const codeClass = (c: unknown) => c === 1 ? 'crit' : c === 2 || c === 6 ? 'warn' : c === 4 ? 'ok' : 'none';
export const levelWords = ['OK', 'Warning', 'Critical'];
// ldot: the status dot with its word for a screen reader as well as the eye (the level is never colour alone)
function ldot(level: number, word: string): HTMLElement {
  const d = dot(level, word);
  d.setAttribute('role', 'img');
  d.setAttribute('aria-label', word);
  return d;
}
export const codeLevel = (c: unknown): 0 | 1 | 2 => c === 1 ? 2 : c === 2 || c === 6 ? 1 : 0;
const num = (v: unknown) => v == null ? undefined : Number(v);

// one read of every repository and instance, kept 25 s (the tree and the pages share it); a failure is kept 30 s
let cache: { at: number; d?: DBADashData; err?: string; login?: boolean } | null = null;
let pending: Promise<DBADashData> | null = null;
export async function dbadashData(force = false): Promise<DBADashData> {
  if (!force && cache?.d && Date.now() - cache.at < 25000) return cache.d;
  if (pending) return pending;
  pending = get<DBADashData>('dbadash', {})
    .then(d => { cache = { at: Date.now(), d }; return d; })
    .finally(() => { pending = null; });
  return pending;
}

// dbadashHref: the page's link (the time range kept; no instance or tag scope: DBADash instances are not pgvigil's)
export function dbadashHref(ctx: Ctx, repo?: string, id?: unknown): string {
  const base = href(ctx, { tab: 'dbadash', instance: undefined, tag: undefined });
  const q = new URLSearchParams(base.split('?')[1] ?? '');
  for (const k of ['dr', 'di']) q.delete(k);
  if (repo) q.set('dr', repo);
  if (repo && id != null) q.set('di', String(id));
  return `#/dbadash?${q}`;
}

// the Summary cell of one status: DBADash's word, its detail as the title, coloured by the code
function statusCell(code: unknown, label: string, detail?: unknown, to?: string): HTMLElement {
  const c = num(code);
  const text = c == null ? 'none' : words[c] ?? String(c);
  const a = to ? el('a', { href: to, class: 'cell-link' }, text) : el('span', { class: 'cell-link' }, text);
  a.title = `${label}: ${text}${detail ? ' - ' + String(detail) : ''}`;
  return a;
}

const repoState = (r: Row) => r.status === 'ok'
  ? `read ${fmtTime(r.ok_at)}; DBADash refreshed its Summary ${r.refreshed_at ? fmtTime(r.refreshed_at) : '(never)'}${r.version ? `; DBADash ${String(r.version)}` : ''}`
  : `not read: ${String(r.reason ?? 'no reason recorded')} (tried ${fmtTime(r.read_at)}${r.ok_at ? `, last read ${fmtTime(r.ok_at)}` : ', never read'})`;

// the fleet grid: one row per instance, one cell per DBADash status in DBADash's column order
function fleetGrid(ctx: Ctx, rows: Row[], checks: Row[]): HTMLElement {
  const cols: Col[] = [
    { key: 'level', label: 'level', fmt: v => ldot(Number(v ?? 0), levelWords[Number(v ?? 0)]) },
    { key: 'display_name', label: 'instance', fmt: (v, r) => el('a', { href: dbadashHref(ctx, String(r.repository), r.instance_id) }, String(v)) },
    { key: 'repository' },
    { key: 'last_collection', label: 'last collection', fmt: v => v == null ? 'never' : fmtTime(v) },
    ...checks.map(c => ({
      key: 's_' + String(c.status_key), label: String(c.label),
      cls: (_v: unknown, r: Row) => 'status ' + codeClass(num((r.statuses as Record<string, unknown> | null)?.[String(c.status_key)])),
      fmt: (_v: unknown, r: Row) => statusCell((r.statuses as Record<string, unknown> | null)?.[String(c.status_key)], String(c.label), undefined,
        dbadashHref(ctx, String(r.repository), r.instance_id)),
    }) as Col),
  ];
  return grid(rows, cols, 'No SQL Server instance read from DBADash yet.');
}

// dbadashView: the page (#/dbadash with dr and di as above)
export async function dbadashView(ctx: Ctx): Promise<HTMLElement> {
  const repo = hashParam('dr'), id = hashParam('di');
  if (repo && id) return instanceView(ctx, repo, Number(id));
  const d = await dbadashData(true);
  const repos = rowsOf(d.repositories).filter(r => !repo || r.repository === repo);
  const rows = rowsOf(d.fleet).filter(r => !repo || r.repository === repo)
    .sort((a, b) => Number(b.level ?? 0) - Number(a.level ?? 0) || String(a.display_name).localeCompare(String(b.display_name)));
  const sec = el('section', {}, el('h2', {}, repo ? `DBADash: ${repo}` : 'DBADash'));
  if (repos.length === 0) {
    sec.append(el('p', { class: 'empty' }, repo
      ? `No DBADash repository named ${repo} in the configuration.`
      : 'No DBADash repository is configured (the dbadash: list of pgvigil.yaml; docs/dbadash.md).'));
    return sec;
  }
  const n = [0, 0, 0];
  for (const r of rows) n[Number(r.level ?? 0)]++;
  sec.append(el('p', { class: 'meta' }, 'The statuses of DBADash\'s own Summary, read from its repository; pgvigil collects nothing from SQL Server.'),
    el('div', { class: 'tiles' }, tile('SQL Server instances', String(rows.length)), tile('Critical instances', String(n[2]), n[2] ? 'crit' : 'ok'),
      tile('Warning instances', String(n[1]), n[1] ? 'warn' : 'ok'), tile('Repositories not read', String(repos.filter(r => r.status !== 'ok').length),
        repos.some(r => r.status !== 'ok') ? 'warn' : 'ok')),
    el('h3', {}, 'Repositories'),
    grid(repos, [
      { key: 'repository', fmt: v => el('a', { href: dbadashHref(ctx, String(v)) }, String(v)) },
      { key: 'status', fmt: v => v === 'ok' ? badge('read', 'ok') : badge('not read', 'warn') },
      { key: 'reason', wide: true },
      { key: 'ok_at', label: 'last read', fmt: v => v == null ? 'never' : fmtTime(v) },
      { key: 'refreshed_at', label: 'DBADash Summary refreshed', fmt: v => v == null ? '' : fmtTime(v) },
      { key: 'version', label: 'DBADash version' },
      { key: 'instance_count', label: 'instances', num: true },
      { key: 'critical', label: 'instances critical', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'crit') : String(v ?? '') },
      { key: 'warning', label: 'instances warning', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : String(v ?? '') },
    ]),
    el('h3', {}, 'Summary'),
    fleetGrid(ctx, rows, rowsOf(d.checks)));
  return sec;
}

async function instanceView(ctx: Ctx, repo: string, id: number): Promise<HTMLElement> {
  const w = window_(ctx);
  const d = await get<DBADashInstance>('dbadash', { repo, id, from: w.from, to: w.to });
  const i = rowsOf(d.instance)[0];
  const sec = el('section', {});
  if (!i) {
    sec.append(el('h2', {}, `DBADash: ${repo}`), el('p', { class: 'empty' }, `DBADash instance ${id} of ${repo}: not in a configured repository, or never read.`));
    return sec;
  }
  const st = rowsOf(d.statuses);
  sec.append(el('h2', {}, String(i.display_name), ' ', el('span', { class: 'meta' }, `(SQL Server, from DBADash: ${repo})`)));
  if (i.repository_status !== 'ok') {
    sec.append(el('p', { class: 'error', role: 'status' }, `The repository was not read at its last try (${fmtTime(i.repository_read_at)}): ${String(i.repository_reason ?? '')}. The statuses below are from ${i.repository_ok_at ? fmtTime(i.repository_ok_at) : 'no read'}.`));
  }
  if (!i.is_present) sec.append(el('p', { class: 'meta' }, 'DBADash no longer lists this instance as active.'));
  sec.append(props([
    ['instance', String(i.instance)],
    ['DBADash connection', String(i.connection_id ?? '')],
    ['repository', el('a', { href: dbadashHref(ctx, repo) }, repo)],
    ['DBADash version', String(i.repository_version ?? '')],
    ['SQL Server', [i.product_version, i.edition].filter(Boolean).map(String).join(', ')],
    ['last collection by DBADash', i.last_collection == null ? 'never' : fmtTime(i.last_collection)],
    ['DBADash Summary refreshed', i.refreshed_at == null ? 'not yet' : fmtTime(i.refreshed_at)],
    ['read by pgvigil', i.summary_read_at == null ? 'never' : fmtTime(i.summary_read_at)],
    ...(i.paused_until ? [['collections paused until', fmtTime(i.paused_until)] as [string, string]] : []),
    ...(i.show_in_summary === false ? [['hidden', 'DBADash hides it from its Summary'] as [string, string]] : []),
  ]));
  sec.append(el('p', { class: 'meta' }, 'DBADash is a desktop application: there is no link to open this instance in it; open the repository above in DBADash\'s GUI.'));
  if (!st.length) {
    sec.append(el('p', { class: 'empty' }, 'DBADash has no Summary row for this instance yet (its Summary cache is refreshed by the GUI\'s Summary screen or the service\'s SummaryRefreshCron).'));
  } else {
    const nCrit = st.filter(r => r.code === 1).length, nWarn = st.filter(r => r.code === 2 || r.code === 6).length;
    sec.append(el('div', { class: 'tiles' }, tile('Critical', String(nCrit), nCrit ? 'crit' : 'ok'), tile('Warning', String(nWarn), nWarn ? 'warn' : 'ok'),
      tile('OK', String(st.filter(r => r.code === 4).length), 'ok')));
    // the Summary: a cell per status, in DBADash's column order, with its header and words
    const cells = el('table', { class: 'grid', 'aria-label': 'DBADash Summary' },
      el('thead', {}, el('tr', {}, ...st.map(r => el('th', { scope: 'col' }, String(r.label))))),
      el('tbody', {}, el('tr', {}, ...st.map(r => el('td', { class: 'status ' + codeClass(num(r.code)) }, statusCell(num(r.code), String(r.label), r.detail))))));
    sec.append(el('h3', {}, 'Summary'), el('div', { class: 'grid-wrap', tabindex: '0', role: 'region', 'aria-label': 'DBADash Summary, scrolls sideways' }, cells),
      el('h3', {}, 'Statuses'),
      grid(st, [
        { key: 'label', label: 'check' },
        { key: 'word', label: 'status', cls: (_v, r) => 'status ' + codeClass(num(r.code)), fmt: (_v, r) => statusCell(num(r.code), String(r.label), r.detail) },
        { key: 'detail', wide: true },
      ]));
  }
  const ch = rowsOf(d.changes);
  sec.append(el('h3', {}, 'Status changes in the window'),
    grid(ch, [
      { key: 'snapshot_at', label: 'read at', fmt: v => fmtTime(v) },
      { key: 'label', label: 'check' },
      { key: 'old_word', label: 'was', cls: (_v, r) => 'status ' + codeClass(num(r.old_code)), fmt: v => String(v ?? 'none') },
      { key: 'new_word', label: 'now', cls: (_v, r) => 'status ' + codeClass(num(r.new_code)), fmt: v => String(v ?? 'none') },
    ], 'No status changed in the window.'));
  return sec;
}

// ---- the tree's DBADash folders (drawn by tree.ts below the PostgreSQL folders)

function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function lsSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private window */ } }
const shut = new Set<string>((() => { try { return JSON.parse(lsGet('pgvigil.dbadashShut') ?? '[]') as string[]; } catch { return []; } })());

// dbadashFolders: one folder per configured repository, "DBADash: <name> (n)", a status dot rolled up from its
// instances, a node per SQL Server instance; a repository not read shows 'not read' and the reason under it. redraw is
// the tree's own draw (called when the read arrives or a caret is pressed); filter is the tree's search text.
export function dbadashFolders(ctx: Ctx, redraw: () => void, filter = ''): HTMLElement[] {
  if (!cache || (Date.now() - cache.at >= (cache.err ? 30000 : 25000) && !pending)) {
    dbadashData(true).then(() => redraw(), e => {
      cache = { at: Date.now(), err: e instanceof Error ? e.message : String(e), login: e instanceof LoginRequired };
      if (!(e instanceof LoginRequired)) redraw();
    });
  }
  if (!cache?.d) return cache?.err && !cache.login ? [el('p', { class: 'error', role: 'status' }, 'DBADash: could not load: ' + cache.err)] : [];
  const repos = rowsOf(cache.d.repositories), fleet = rowsOf(cache.d.fleet);
  const curRepo = ctx.tab === 'dbadash' ? hashParam('dr') : undefined, curId = ctx.tab === 'dbadash' ? hashParam('di') : undefined;
  const out: HTMLElement[] = [];
  for (const r of repos) {
    const name = String(r.repository);
    const all = fleet.filter(f => f.repository === name);
    const shown = all.filter(f => !filter || String(f.display_name).toLowerCase().includes(filter));
    if (filter && shown.length === 0) continue;
    const key = 'dd:' + name, closed = shut.has(key) && !filter;
    const caret = el('button', { type: 'button', class: 'caret', 'data-key': key, 'aria-expanded': String(!closed), 'aria-label': `${closed ? 'expand' : 'collapse'} DBADash ${name}` }, closed ? '▸' : '▾');
    caret.addEventListener('click', () => { if (shut.has(key)) shut.delete(key); else shut.add(key); lsSet('pgvigil.dbadashShut', JSON.stringify([...shut])); redraw(); });
    const lvl = all.reduce<0 | 1 | 2>((a, f) => Math.max(a, Number(f.level ?? 0)) as 0 | 1 | 2, 0);
    const label = el('a', { class: 'folder-name' + (curRepo === name && !curId ? ' on' : ''), href: dbadashHref(ctx, name), title: repoState(r) }, `DBADash: ${name} (${all.length})`);
    const box = el('div', { class: 'folder' }, el('div', { class: 'folder-head' }, caret, ldot(r.status === 'ok' ? lvl : 1, r.status === 'ok' ? levelWords[lvl] : 'not read'), label));
    if (!closed) {
      const ul = el('div', { class: 'folder-items' });
      if (r.status !== 'ok') ul.append(el('p', { class: 'error', style: 'padding:.1rem .4rem', role: 'status' }, `not read: ${String(r.reason ?? '')}`));
      for (const f of shown) {
        const on = curRepo === name && curId === String(f.instance_id);
        ul.append(el('div', { class: 'tree-inst', style: 'display:flex;align-items:center' },
          el('a', { class: 'inst' + (on ? ' on' : ''), style: 'flex:1;min-width:0', href: dbadashHref(ctx, name, f.instance_id), title: `SQL Server ${String(f.instance)}, from DBADash ${name}` },
            ldot(Number(f.level ?? 0), levelWords[Number(f.level ?? 0)]), String(f.display_name))));
      }
      if (r.status === 'ok' && all.length === 0) ul.append(el('p', { class: 'empty', style: 'padding:.1rem .4rem' }, 'No active instance in this repository.'));
      box.append(ul);
    }
    out.push(box);
  }
  return out;
}
