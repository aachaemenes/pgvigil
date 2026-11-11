// The DBADash door's views (task 55): the SQL Server instances of the DBADash repositories the configuration names,
// with the statuses of DBADash's own Summary screen (DBADash's column headers and its words: Critical, Warning, N/A,
// OK, Acknowledged ...). pgvigil collects nothing from SQL Server: every status here is DBADash's, read every 5 minutes
// from its repository with a read-only login.
//   #/dbadash                      every repository and every instance (one row each, a cell per DBADash status)
//   #/dbadash?dr=<repo>            one repository
//   #/dbadash?dr=<repo>&di=<id>    one DBADash instance: its statuses, the last collection, the repository it came from,
//                                  and the status changes of the window
//   #/dbadash?dr=<repo>&di=<id>&dp=<page>[&ds=<snapshot>]  one of DBADash's own screens for the instance (task 75):
//                                  ONE call of DBADash's procedure for it (Performance Summary, Running Queries and a
//                                  snapshot's sessions, Backups, Agent Jobs, Drives, DB Space, Configuration, SQL Agent
//                                  Alerts), every result set a grid; Kill on a session and Start / Stop on a job go
//                                  through the actions door of the SQL Server instance pgvigil monitors under the same
//                                  @@SERVERNAME (mssql_actions.ts), off with the reason when there is none
// The tree's folders ("DBADash: <repository>", a node per SQL Server instance) are dbadashFolders, which the shell's
// tree.ts draws below the PostgreSQL folders. A DBADash GUI has no URL: the page names the instance and the repository
// and links nowhere outside pgvigil.
import { get, LoginRequired, Row, rowsOf, Table } from './api';
import { mssqlJobCol, mssqlKillCol } from './mssql_actions';
import { Ctx, href, window_ } from './router';
import { hashParam } from './dbinfo';
import { badge, Col, dot, el, errorBox, fmtTime, grid, props, tile } from './ui';

interface DBADashData { repositories: Table | null; fleet: Table | null; checks: Table | null }
interface DBADashInstance { instance: Table | null; statuses: Table | null; changes: Table | null; pgvigil?: Table | null }
interface PageSet { columns: { name: string; type: string }[]; rows: unknown[][]; truncated?: boolean }
interface PageReply { page: string; title: string; procedure: string; version: string; proven: boolean; note?: string; results: PageSet[]; ms: number; instance?: string; machine?: string }

// DBADash's codes (DBADashStatusEnum) and pgvigil's colour for each: 1 Critical, 2 Warning, 6 Warning (low) are the
// two alarm levels; N/A, Information and Disabled are shown muted; Acknowledged muted and marked (blue in the solid
// status style); OK green.
export const words: Record<number, string> = { 1: 'Critical', 2: 'Warning', 3: 'N/A', 4: 'OK', 5: 'Acknowledged', 6: 'Warning (low)', 7: 'Information', 8: 'Disabled' };
export const codeClass = (c: unknown) => c === 1 ? 'crit' : c === 2 || c === 6 ? 'warn' : c === 4 ? 'ok' : c === 5 ? 'none ack' : 'none';
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
export function dbadashHref(ctx: Ctx, repo?: string, id?: unknown, page?: string, snapshot?: string): string {
  const base = href(ctx, { tab: 'dbadash', instance: undefined, tag: undefined });
  const q = new URLSearchParams(base.split('?')[1] ?? '');
  for (const k of ['dr', 'di', 'dp', 'ds']) q.delete(k);
  if (repo) q.set('dr', repo);
  if (repo && id != null) q.set('di', String(id));
  if (repo && id != null && page) q.set('dp', page);
  if (repo && id != null && page && snapshot) q.set('ds', snapshot);
  return `#/dbadash?${q}`;
}

// the instance page's screens: the Summary (task 55's read of dbo.Summary) and DBADash's procedures, in task 75's order
const screens: [string, string][] = [['', 'Summary'], ['performance', 'Performance Summary'], ['running', 'Running Queries'], ['backups', 'Backups'],
  ['jobs', 'Agent Jobs'], ['drives', 'Drives'], ['dbfiles', 'DB Space'], ['configuration', 'Configuration'], ['alerts', 'SQL Agent Alerts']];
function screenNav(ctx: Ctx, repo: string, id: number, cur: string): HTMLElement {
  return el('nav', { class: 'subtabs', 'aria-label': 'DBADash screens' }, ...screens.map(([k, label]) => {
    const on = k === cur || (cur === 'sessions' && k === 'running');
    const a = el('a', { href: dbadashHref(ctx, repo, id, k || undefined), class: on ? 'on' : '' }, label);
    if (on) a.setAttribute('aria-current', 'page');
    return a;
  }), ' ');
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
  const repo = hashParam('dr'), id = hashParam('di'), page = hashParam('dp');
  if (repo && id && page) return pageView(ctx, repo, Number(id), page, hashParam('ds'));
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
  sec.append(el('h2', {}, String(i.display_name), ' ', el('span', { class: 'meta' }, `(SQL Server, from DBADash: ${repo})`)), screenNav(ctx, repo, id, ''));
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

// ---- DBADash's own screens (task 75): one procedure call, its result sets as grids

const numTypes = new Set(['INT', 'BIGINT', 'SMALLINT', 'TINYINT', 'DECIMAL', 'NUMERIC', 'FLOAT', 'REAL', 'MONEY', 'SMALLMONEY']);
// a DBADash status column (FullBackupStatus, JobStatus ...): its code with DBADash's word and colour
const isStatusCol = (c: { name: string; type: string }) => /Status$/.test(c.name) && (c.type === 'INT' || c.type === 'TINYINT' || c.type === 'SMALLINT');
// a snapshot time of RunningQueriesSummary_Get (UTC, as DBADash keeps it) as the sessions page's ds= value
const asUTC = (v: unknown) => String(v ?? '').replace(' ', 'T') + 'Z';

function setRows(set: PageSet): { cols: Col[]; rows: Row[] } {
  const names: string[] = [];
  for (const c of set.columns) {
    let n = c.name || '(no name)', k = 2;
    while (names.includes(n)) n = `${c.name}_${k++}`;
    names.push(n);
  }
  const cols: Col[] = set.columns.map((c, i) => {
    const key = names[i];
    if (isStatusCol(c)) {
      return { key, label: c.name, cls: (v: unknown) => 'status ' + codeClass(num(v)), fmt: (v: unknown) => statusCell(num(v), c.name) };
    }
    return { key, label: c.name, num: numTypes.has(c.type), wide: c.type === 'NVARCHAR' || c.type === 'VARCHAR' || c.type === 'XML' };
  });
  const rows = set.rows.map(r => Object.fromEntries(names.map((n, i) => [n, r[i]])) as Row);
  return { cols, rows };
}

async function pageView(ctx: Ctx, repo: string, id: number, page: string, snapshot?: string): Promise<HTMLElement> {
  const w = window_(ctx);
  const sec = el('section', {});
  // the instance's facts and pgvigil's own instance of the same server; a failed read leaves the actions off (said below)
  const head = await get<DBADashInstance>('dbadash', { repo, id, from: w.from, to: w.to })
    .catch((e: unknown) => { if (e instanceof LoginRequired) throw e; return null; });
  const i = head ? rowsOf(head.instance)[0] : undefined;
  const pg = head ? rowsOf(head.pgvigil)[0] : undefined;
  sec.append(el('h2', {}, i ? String(i.display_name) : `DBADash instance ${id}`, ' ', el('span', { class: 'meta' }, `(SQL Server, from DBADash: ${repo})`)),
    screenNav(ctx, repo, id, page));
  let d: PageReply;
  try {
    d = await get<PageReply>('dbadash', { repo, id, page, from: w.from, to: w.to, ...(snapshot ? { snapshot } : {}) });
  } catch (e) {
    if (e instanceof LoginRequired) throw e;
    sec.append(errorBox(e));
    return sec;
  }
  sec.append(el('h3', {}, d.title, page === 'sessions' ? (snapshot ? ` at ${fmtTime(snapshot)}` : ' (the latest snapshot)') : ''),
    el('p', { class: 'meta' }, `DBADash's own ${d.procedure}, called now for this instance through the repository's read login (${d.ms} ms); DBADash ${d.version || '(no version row)'}.`));
  if (!d.proven) sec.append(el('p', { class: 'error', role: 'status' }, d.note ?? 'not proven on this DBADash version'));
  // the actions: the SQL Server instance pgvigil monitors under the same server name AND machine name (a host renamed
  // without sp_dropserver keeps its old @@SERVERNAME, which a new server may carry), on the latest snapshot only (a past
  // snapshot's session id may belong to another session now); otherwise off with the reason
  const same = (a: unknown, b: unknown) => a != null && b != null && String(a) !== '' && String(a).toUpperCase() === String(b).toUpperCase();
  let why = '';
  if (!head) why = 'the instance\'s pgvigil match could not be read: reload the page';
  else if (!pg) why = `${i ? String(i.instance) : 'this instance'} is not a SQL Server instance pgvigil monitors (an instances: entry with engine: sqlserver, its actions_dsn and actions: list; docs/dbadash.md)`;
  else if (!same(d.instance, pg.server_name) || !same(d.machine, pg.machine_name)) {
    why = `DBA Dash knows this server as ${d.instance || '?'} on machine ${d.machine || '(none recorded)'}, pgvigil's instance ${String(pg.name)} as ${String(pg.server_name ?? '?')} on machine ${String(pg.machine_name ?? '?')}: they may be two servers under one name`;
  } else if (page === 'sessions' && snapshot) why = 'Kill is offered on the latest snapshot only: a past snapshot\'s session id may belong to another session now';
  const after = () => { window.dispatchEvent(new HashChangeEvent('hashchange')); };
  let actCol: Col | undefined;
  if (page === 'sessions' || page === 'jobs') {
    const label = page === 'sessions' ? 'Kill' : 'Start / Stop';
    if (!why && pg) {
      const actx = { ...ctx, instance: Number(pg.instance_id) };
      actCol = page === 'sessions' ? await mssqlKillCol(actx, after) : await mssqlJobCol(actx, after);
      sec.append(el('p', { class: 'meta' }, `Actions go through the actions door of pgvigil's own instance ${String(pg.name)}${Number(pg.matches) > 1 ? ` (one of ${String(pg.matches)} with this server name)` : ''}; every attempt is kept in its Actions log.`));
    } else {
      actCol = { key: '_actions', label: 'action', fmt: () => { const b = el('button', { type: 'button', 'aria-disabled': 'true', style: 'font-size:12px;padding:0 .4rem;opacity:.55;cursor:not-allowed', title: why }, label); b.setAttribute('aria-label', `${label}: off. ${why}`); return b; } };
      sec.append(el('p', { class: 'meta' }, `No action from this page: ${why}.`));
    }
  }
  if (!d.results.length) sec.append(el('p', { class: 'empty' }, 'The procedure returned no result set.'));
  d.results.forEach((set, n) => {
    const { cols, rows } = setRows(set);
    if (page === 'running') {
      const at = cols.find(c => c.key === 'SnapshotDateUTC');
      if (at) at.fmt = v => el('a', { href: dbadashHref(ctx, repo, id, 'sessions', asUTC(v)), title: 'the sessions of this snapshot' }, fmtTime(asUTC(v)));
    }
    if (actCol && n === 0) cols.push(actCol);
    if (d.results.length > 1) sec.append(el('h4', {}, `Result set ${n + 1}`));
    if (set.truncated) sec.append(el('p', { class: 'meta' }, 'The first 5000 rows of this result set.'));
    sec.append(grid(rows, cols, 'No rows.'));
  });
  if (page === 'running') sec.append(el('p', {}, el('a', { href: dbadashHref(ctx, repo, id, 'sessions') }, 'The latest snapshot\'s sessions')));
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
