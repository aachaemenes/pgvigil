// The imported SQL Server servers (tasks 55, 75, 168): the instances of the source repositories the configuration's
// dbadash: list names, read with a read-only login, shown as pgvigil's own SQL Server instances. The source product is
// named once, on the repositories' settings line of the Imported servers page, and credited on the About page and in
// THIRD-PARTY-NOTICES.
//   #/dbadash                      every repository and every instance (one row each, a cell per Summary status)
//   #/dbadash?dr=<repo>            one repository
//   #/dbadash?dr=<repo>&di=<id>[&dp=<tab>][&ds=<snapshot>|latest]  one instance of a repository that pgvigil holds no
//                                  instance for: the SQL Server tab set (router.ts mssqlInstanceGroups), each tab from
//                                  the repository's live screens or its one 'not read' line (tabSources below). An
//                                  instance pgvigil holds (imported, or collected under the same @@SERVERNAME) opens
//                                  at its own pgvigil instance instead.
//   #/<tab>?i=<id> of an imported server (made by pgvigil import dbadash, not collected by pgvigil): main.ts asks
//                                  importedPage() for every tab: pgvigil's store where the import fills what the
//                                  native page reads, else the repository's live screen, else one 'not read' line.
// The live screens are ONE call of the repository's own procedure for the instance (pinned 4.24.1; another version is
// said on the page); every result set a grid. Kill on a session and Start / Stop on a job go through the actions door
// of the SQL Server instance pgvigil collects under the same @@SERVERNAME (mssql_actions.ts), off with the reason when
// there is none. The tree's folders ('Imported: <repository>') are dbadashFolders, drawn by tree.ts.
import { get, LoginRequired, Row, rowsOf, Table } from './api';
import { mssqlJobCol, mssqlKillCol } from './mssql_actions';
import { Ctx, href, mssqlInstanceGroups, mssqlInstanceTabs, window_ } from './router';
import { hashParam } from './dbinfo';
import { badge, Col, dot, el, errorBox, fmtTime, grid, props, tile } from './ui';

interface DBADashData { repositories: Table | null; fleet: Table | null; checks: Table | null; imported?: Table | null }
interface DBADashInstance { instance: Table | null; statuses: Table | null; changes: Table | null; pgvigil?: Table | null }
interface PageSet { columns: { name: string; type: string }[]; rows: unknown[][]; truncated?: boolean }
interface PageReply { page: string; title: string; procedure: string; version: string; proven: boolean; note?: string; results: PageSet[]; ms: number; instance?: string; machine?: string }
type Render = (c: Ctx) => Promise<HTMLElement>;

// the source's status codes and pgvigil's colour for each: 1 Critical, 2 Warning, 6 Warning (low) are the two alarm
// levels; N/A, Information and Disabled are shown muted; Acknowledged muted and marked (blue in the solid status
// style); OK green.
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

// ---- which pgvigil instance a repository instance is (task 168)

// Imported: a repository instance and the pgvigil SQL Server instance that stands for it; collected = pgvigil reads the
// server itself (its own pages), else it is an imported server (made by pgvigil import dbadash under the display name)
export interface Imported { repo: string; sourceId: number; instanceId: number; name: string; collected: boolean }
const matches = (d: DBADashData): Imported[] => rowsOf(d.imported).map(r => ({
  repo: String(r.repository), sourceId: Number(r.source_id), instanceId: Number(r.instance_id), name: String(r.name), collected: r.collected === true,
}));
// pgvigilOf: the pgvigil instance of one repository instance, the collected one first (the API's order)
const pgvigilOf = (d: DBADashData, repo: string, id: number) => matches(d).find(m => m.repo === repo && m.sourceId === id);

// importedOf: the repository instance an imported server came from; undefined for a server pgvigil collects, or one no
// repository lists
export async function importedOf(instance: number | undefined): Promise<Imported | undefined> {
  if (!instance) return undefined;
  const ms = matches(await dbadashData()).filter(m => m.instanceId === instance);
  return ms.some(m => m.collected) ? undefined : ms[0];
}
// isImported: main.ts's question for a SQL Server instance (a failed read = not imported: its own pages)
export async function isImported(instance: number | undefined): Promise<boolean> {
  try {
    return (await importedOf(instance)) !== undefined;
  } catch (e) {
    if (e instanceof LoginRequired) throw e;
    return false;
  }
}

// ---- what each SQL Server tab shows for an imported server (docs/dbadash.md has this table)

// store: what pgvigil import dbadash copies into the tables the native page reads (an imported server: the native page);
// screen: the repository's live screen (a procedure of pages.go, or 'summary' / 'properties': the stored read of task 55);
// read: what reads the tab for a server pgvigil collects itself (the 'not read' line's words).
interface Source { store?: string; screen?: string; extra?: string; read?: string }
const own = 'pgvigil\'s own collection of the server (an instances: entry with engine: sqlserver)';
export const tabSources: Record<string, Source> = {
  summary: { screen: 'summary' },
  performance: { screen: 'performance' },
  mssql_running: { screen: 'running' },
  mssql_slow: { read: `${own}: its Extended Events session` },
  mssql_waits: { read: `${own}: its wait statistics read` },
  mssql_deadlocks: { read: `${own}: its system_health deadlock read` },
  mssql_blocked: { read: `${own}: its blocked process report read` },
  findings: { read: `${own}: pgvigil's checks run over what it collects` },
  availability: { read: `${own}: its Always On and log shipping reads` },
  mssqlbackups: { screen: 'backups' },
  mssqljobs: { screen: 'jobs', extra: 'alerts' },
  mssqlstorage: { store: 'the volume samples and database sizes', screen: 'drives' },
  mssqlfiles: { screen: 'dbfiles' },
  rowversions: { read: `${own}: its version store read` },
  mssqlconfig: { screen: 'configuration' },
  mssqlactions: { read: 'the actions door of a server pgvigil collects itself (its actions_dsn and actions: list)' },
  jobstimeline: { store: 'the job outcomes' },
  mssqlcpu: { store: 'the CPU minutes' },
  mssqlmemory: { read: `${own}: its memory read` },
  mssqlfileio: { read: `${own}: its file IO read` },
  mssqltempdb: { read: `${own}: its tempdb read` },
  mssqlqs: { read: `${own}: its Query Store read` },
  counters: { read: `${own}: its performance counter read` },
  mssqlprocs: { read: `${own}: its procedure statistics read` },
  mssqlindexlocks: { read: `${own}: its index operational statistics read` },
  mssqlproperties: { screen: 'properties' },
  mssqlaudit: { read: `${own}: its audit read` },
  mssqlplancache: { read: `${own}: its plan cache read` },
  mssqlindexes: { read: `${own}: its index read` },
  mssqlchecks: { read: `${own}: its configuration checks` },
  mssqlerrorlog: { read: `${own}: its error log reader` },
  mssqltrace: { read: `${own}: its default trace reader` },
  mssqlhealth: { read: `${own}: its system_health reader` },
};
// the screen keys of task 75's links (dp=) and the tab each now opens
const legacyDp: Record<string, string> = { '': 'summary', running: 'mssql_running', sessions: 'mssql_running', backups: 'mssqlbackups', jobs: 'mssqljobs',
  drives: 'mssqlstorage', dbfiles: 'mssqlfiles', configuration: 'mssqlconfig', alerts: 'mssqljobs' };

// Mode: where a tab is drawn: at a pgvigil instance (instance set; native = main.ts's SQL Server pages) or on the
// repository instance's own page (#/dbadash?dr=&di=)
interface Mode { repo: string; id: number; instance?: number; native?: Record<string, Render> }

// dbadashHref: the repository pages' link (the time range kept; no instance or tag scope)
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
// tabHref: one tab of an instance in its mode; ds = a running-queries snapshot ('latest' = the newest)
function tabHref(ctx: Ctx, m: Mode, tab: string, ds?: string): string {
  if (!m.instance) return dbadashHref(ctx, m.repo, m.id, tab, ds);
  const h = href(ctx, { tab, instance: m.instance, tag: undefined });
  return ds ? `${h}${h.includes('?') ? '&' : '?'}ds=${encodeURIComponent(ds)}` : h;
}

// the Summary cell of one status: its word, its detail as the title, coloured by the code
function statusCell(code: unknown, label: string, detail?: unknown, to?: string): HTMLElement {
  const c = num(code);
  const text = c == null ? 'none' : words[c] ?? String(c);
  const a = to ? el('a', { href: to, class: 'cell-link' }, text) : el('span', { class: 'cell-link' }, text);
  a.title = `${label}: ${text}${detail ? ' - ' + String(detail) : ''}`;
  return a;
}

const repoState = (r: Row) => r.status === 'ok'
  ? `read ${fmtTime(r.ok_at)}; its Summary refreshed ${r.refreshed_at ? fmtTime(r.refreshed_at) : '(never)'}${r.version ? `; version ${String(r.version)}` : ''}`
  : `not read: ${String(r.reason ?? 'no reason recorded')} (tried ${fmtTime(r.read_at)}${r.ok_at ? `, last read ${fmtTime(r.ok_at)}` : ', never read'})`;

// instanceHref: where a repository instance opens: its pgvigil instance when pgvigil holds one, else its own page
function instanceHref(ctx: Ctx, d: DBADashData, repo: string, id: unknown): string {
  const pv = pgvigilOf(d, repo, Number(id));
  return pv ? href(ctx, { tab: 'summary', instance: pv.instanceId, tag: undefined }) : dbadashHref(ctx, repo, id);
}

// the fleet grid: one row per instance, one cell per Summary status in the source's column order
function fleetGrid(ctx: Ctx, d: DBADashData, rows: Row[], checks: Row[]): HTMLElement {
  const cols: Col[] = [
    { key: 'level', label: 'level', fmt: v => ldot(Number(v ?? 0), levelWords[Number(v ?? 0)]) },
    { key: 'display_name', label: 'instance', fmt: (v, r) => el('a', { href: instanceHref(ctx, d, String(r.repository), r.instance_id) }, String(v)) },
    { key: 'repository' },
    { key: 'pgvigil', label: 'in pgvigil', fmt: (_v, r) => { const pv = pgvigilOf(d, String(r.repository), Number(r.instance_id)); return pv ? (pv.collected ? 'collected' : 'imported') : 'not imported'; } },
    { key: 'last_collection', label: 'last collection', fmt: v => v == null ? 'never' : fmtTime(v) },
    ...checks.map(c => ({
      key: 's_' + String(c.status_key), label: String(c.label),
      cls: (_v: unknown, r: Row) => 'status ' + codeClass(num((r.statuses as Record<string, unknown> | null)?.[String(c.status_key)])),
      fmt: (_v: unknown, r: Row) => statusCell((r.statuses as Record<string, unknown> | null)?.[String(c.status_key)], String(c.label), undefined,
        instanceHref(ctx, d, String(r.repository), r.instance_id)),
    }) as Col),
  ];
  return grid(rows, cols, 'No SQL Server instance read from a repository yet.');
}

// dbadashView: the Imported servers page (#/dbadash with dr, di, dp and ds as above)
export async function dbadashView(ctx: Ctx): Promise<HTMLElement> {
  const repo = hashParam('dr'), id = hashParam('di');
  if (repo && id) return repoInstanceView(ctx, repo, Number(id));
  const d = await dbadashData(true);
  const repos = rowsOf(d.repositories).filter(r => !repo || r.repository === repo);
  const rows = rowsOf(d.fleet).filter(r => !repo || r.repository === repo)
    .sort((a, b) => Number(b.level ?? 0) - Number(a.level ?? 0) || String(a.display_name).localeCompare(String(b.display_name)));
  const sec = el('section', {}, el('h2', {}, repo ? `Imported: ${repo}` : 'Imported servers'));
  if (repos.length === 0) {
    sec.append(el('p', { class: 'empty' }, repo
      ? `No repository named ${repo} in the configuration.`
      : 'No repository is configured (the dbadash: list of pgvigil.yaml; docs/dbadash.md).'));
    return sec;
  }
  const n = [0, 0, 0];
  for (const r of rows) n[Number(r.level ?? 0)]++;
  // the settings line: the one place the source product is named
  sec.append(el('p', { class: 'meta', 'data-source-line': '' }, 'Source: DBA Dash repositories (the dbadash: list of pgvigil.yaml), read every 5 minutes with a read-only login; their statuses below, their history copied by pgvigil import dbadash, their screens read live.'),
    el('div', { class: 'tiles' }, tile('SQL Server instances', String(rows.length)), tile('Critical instances', String(n[2]), n[2] ? 'crit' : 'ok'),
      tile('Warning instances', String(n[1]), n[1] ? 'warn' : 'ok'), tile('Repositories not read', String(repos.filter(r => r.status !== 'ok').length),
        repos.some(r => r.status !== 'ok') ? 'warn' : 'ok')),
    el('h3', {}, 'Repositories'),
    grid(repos, [
      { key: 'repository', fmt: v => el('a', { href: dbadashHref(ctx, String(v)) }, String(v)) },
      { key: 'status', fmt: v => v === 'ok' ? badge('read', 'ok') : badge('not read', 'warn') },
      { key: 'reason', wide: true },
      { key: 'ok_at', label: 'last read', fmt: v => v == null ? 'never' : fmtTime(v) },
      { key: 'refreshed_at', label: 'Summary refreshed', fmt: v => v == null ? '' : fmtTime(v) },
      { key: 'version', label: 'source version' },
      { key: 'instance_count', label: 'instances', num: true },
      { key: 'critical', label: 'instances critical', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'crit') : String(v ?? '') },
      { key: 'warning', label: 'instances warning', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : String(v ?? '') },
    ]),
    el('h3', {}, 'Summary'),
    fleetGrid(ctx, d, rows, rowsOf(d.checks)));
  return sec;
}

// importedPage: one tab of an imported server (main.ts, at a SQL Server instance); null = not an imported server, its
// own page
export async function importedPage(ctx: Ctx, native: Record<string, Render>): Promise<HTMLElement | null> {
  const imp = await importedOf(ctx.instance);
  if (!imp) return null;
  return tabView(ctx, { repo: imp.repo, id: imp.sourceId, instance: imp.instanceId, native }, ctx.tab);
}

// repoInstanceView: a repository instance's own page; one pgvigil holds opens at its pgvigil instance instead
async function repoInstanceView(ctx: Ctx, repo: string, id: number): Promise<HTMLElement> {
  const d = await dbadashData();
  const dp = hashParam('dp') ?? '';
  const tab = mssqlInstanceTabs[dp] ? dp : legacyDp[dp] ?? 'summary';
  const ds = hashParam('ds') ?? (dp === 'sessions' ? 'latest' : undefined);
  const pv = pgvigilOf(d, repo, id);
  if (pv) {
    const to = tabHref(ctx, { repo, id, instance: pv.instanceId }, tab, tab === 'mssql_running' ? ds : undefined);
    location.replace(to);
    return el('section', {}, el('p', { class: 'empty', role: 'status' }, `Opening ${pv.name} ...`));
  }
  const f = rowsOf(d.fleet).find(r => r.repository === repo && Number(r.instance_id) === id);
  const m: Mode = { repo, id };
  const sec = el('section', {});
  sec.append(el('h2', {}, f ? String(f.display_name) : `Instance ${id} of ${repo}`, ' ',
    el('span', { class: 'meta' }, `(SQL Server, imported: ${repo}; not yet one of pgvigil's instances)`)), groupNav(ctx, m, tab), await tabView(ctx, m, tab));
  return sec;
}

// groupNav: the SQL Server tab set on a repository instance's own page, as the strip and the tree's folders show it at a
// pgvigil instance: the main tabs and the groups (Logs, HA/DR, Performance ...), the open group's tabs below
function groupNav(ctx: Ctx, m: Mode, cur: string): HTMLElement {
  const g = mssqlInstanceGroups.find(x => x.tabs.includes(cur)) ?? mssqlInstanceGroups[0];
  const link = (k: string, label: string, on: boolean, current: boolean) => {
    const a = el('a', { href: tabHref(ctx, m, k), class: on ? 'on' : '' }, label);
    if (current) a.setAttribute('aria-current', 'page');
    return a;
  };
  const [main, ...rest] = mssqlInstanceGroups;
  const box = el('div', {},
    el('nav', { class: 'subtabs', 'aria-label': 'SQL Server pages' },
      ...main.tabs.map(k => link(k, mssqlInstanceTabs[k] ?? k, k === cur, k === cur)),
      ...rest.map(x => link(x.tabs[0], x.name, x === g, false))));
  if (g !== main) {
    box.append(el('nav', { class: 'subtabs', 'aria-label': `${g.name} pages` }, ...g.tabs.map(k => link(k, mssqlInstanceTabs[k] ?? k, k === cur, k === cur))));
  }
  // every tab of the set, for a check that walks them all (proof-dbadash-door.sh G)
  box.dataset.all = JSON.stringify(Object.keys(mssqlInstanceTabs).map(k => tabHref(ctx, m, k)));
  return box;
}

// notRead: the one line of a tab that has no source for an imported server
function notRead(tab: string, what: string, h2: boolean): HTMLElement {
  return el('section', { 'data-source': 'none' }, ...(h2 ? [el('h2', {}, mssqlInstanceTabs[tab] ?? tab)] : []),
    el('p', { class: 'empty notread' }, `not read for an imported server: ${what}`));
}

// tabView: one tab of the SQL Server tab set for a repository instance (an imported server at its pgvigil instance, or
// the repository instance's own page)
async function tabView(ctx: Ctx, m: Mode, tab: string): Promise<HTMLElement> {
  const src = tabSources[tab] ?? { read: own };
  const h2 = m.instance !== undefined;   // at a pgvigil instance the page names itself; on its own page the instance is the heading
  const page = m.native?.[tab];
  if (src.store && m.instance && page) {
    const v = await page({ ...ctx, instance: m.instance, tab });
    v.dataset.source = 'store';
    v.prepend(el('p', { class: 'meta' }, `An imported server: ${src.store} here are the ones pgvigil import dbadash copied from ${m.repo}; what pgvigil's own collection fills stays empty.`));
    return v;
  }
  if (src.screen) return screenTab(ctx, m, tab, src, h2);
  return notRead(tab, src.store ? `pgvigil import dbadash -repo ${m.repo} -instance ${m.id} copies ${src.store}` : src.read ?? own, h2);
}

async function screenTab(ctx: Ctx, m: Mode, tab: string, src: Source, h2: boolean): Promise<HTMLElement> {
  const sec = el('section', { 'data-source': 'screen' }, ...(h2 ? [el('h2', {}, mssqlInstanceTabs[tab] ?? tab, ' ', el('span', { class: 'meta' }, `(imported: ${m.repo})`))] : []));
  let rows = 0;
  if (src.screen === 'summary') rows = await summaryInto(sec, ctx, m);
  else if (src.screen === 'properties') rows = await propertiesInto(sec, ctx, m);
  else {
    const ds = tab === 'mssql_running' ? hashParam('ds') : undefined;
    rows = await screenInto(sec, ctx, m, ds ? 'sessions' : src.screen!, ds === 'latest' ? undefined : ds);
    if (src.extra) rows += await screenInto(sec, ctx, m, src.extra);
  }
  sec.dataset.rows = String(rows);
  return sec;
}

// summaryInto: the source's Summary statuses for the instance (task 55's stored read) and the changes of the window
async function summaryInto(sec: HTMLElement, ctx: Ctx, m: Mode): Promise<number> {
  const w = window_(ctx);
  const d = await get<DBADashInstance>('dbadash', { repo: m.repo, id: m.id, from: w.from, to: w.to });
  const i = rowsOf(d.instance)[0];
  if (!i) {
    sec.append(el('p', { class: 'empty' }, `Instance ${m.id} of ${m.repo}: not in a configured repository, or never read.`));
    return 0;
  }
  if (i.repository_status !== 'ok') {
    sec.append(el('p', { class: 'error', role: 'status' }, `The repository was not read at its last try (${fmtTime(i.repository_read_at)}): ${String(i.repository_reason ?? '')}. The statuses below are from ${i.repository_ok_at ? fmtTime(i.repository_ok_at) : 'no read'}.`));
  }
  if (!i.is_present) sec.append(el('p', { class: 'meta' }, 'The repository no longer lists this instance as active.'));
  const st = rowsOf(d.statuses);
  sec.append(el('p', { class: 'meta' }, `The Summary statuses of ${String(i.display_name)} as the repository ${m.repo} keeps them, read every 5 minutes; last collection ${i.last_collection == null ? 'never' : fmtTime(i.last_collection)}.`));
  if (!st.length) {
    sec.append(el('p', { class: 'empty' }, 'The repository has no Summary row for this instance yet (its Summary cache is refreshed by its own GUI or service).'));
  } else {
    const nCrit = st.filter(r => r.code === 1).length, nWarn = st.filter(r => r.code === 2 || r.code === 6).length;
    sec.append(el('div', { class: 'tiles' }, tile('Critical', String(nCrit), nCrit ? 'crit' : 'ok'), tile('Warning', String(nWarn), nWarn ? 'warn' : 'ok'),
      tile('OK', String(st.filter(r => r.code === 4).length), 'ok')));
    // a cell per status, in the source's column order, with its header and words
    const cells = el('table', { class: 'grid', 'aria-label': 'Summary statuses' },
      el('thead', {}, el('tr', {}, ...st.map(r => el('th', { scope: 'col' }, String(r.label))))),
      el('tbody', {}, el('tr', {}, ...st.map(r => el('td', { class: 'status ' + codeClass(num(r.code)) }, statusCell(num(r.code), String(r.label), r.detail))))));
    sec.append(el('div', { class: 'grid-wrap', tabindex: '0', role: 'region', 'aria-label': 'Summary statuses, scrolls sideways' }, cells),
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
  return st.length;
}

// propertiesInto: the instance's facts as the repository records them (task 55's stored read)
async function propertiesInto(sec: HTMLElement, ctx: Ctx, m: Mode): Promise<number> {
  const w = window_(ctx);
  const d = await get<DBADashInstance>('dbadash', { repo: m.repo, id: m.id, from: w.from, to: w.to });
  const i = rowsOf(d.instance)[0];
  if (!i) {
    sec.append(el('p', { class: 'empty' }, `Instance ${m.id} of ${m.repo}: not in a configured repository, or never read.`));
    return 0;
  }
  const facts: [string, string | HTMLElement][] = [
    ['instance', String(i.instance)],
    ['connection', String(i.connection_id ?? '')],
    ['repository', el('a', { href: dbadashHref(ctx, m.repo) }, m.repo)],
    ['source version', String(i.repository_version ?? '')],
    ['SQL Server', [i.product_version, i.edition].filter(Boolean).map(String).join(', ')],
    ['last collection', i.last_collection == null ? 'never' : fmtTime(i.last_collection)],
    ['Summary refreshed', i.refreshed_at == null ? 'not yet' : fmtTime(i.refreshed_at)],
    ['read by pgvigil', i.summary_read_at == null ? 'never' : fmtTime(i.summary_read_at)],
    ...(i.paused_until ? [['collections paused until', fmtTime(i.paused_until)] as [string, string]] : []),
    ...(i.show_in_summary === false ? [['hidden', 'hidden from the repository\'s own Summary'] as [string, string]] : []),
  ];
  sec.append(props(facts), el('p', { class: 'meta' }, 'The repository belongs to a desktop application: there is no link to open this instance there.'));
  return facts.length;
}

// ---- the repository's own screens (task 75): one procedure call, its result sets as grids

const numTypes = new Set(['INT', 'BIGINT', 'SMALLINT', 'TINYINT', 'DECIMAL', 'NUMERIC', 'FLOAT', 'REAL', 'MONEY', 'SMALLMONEY']);
// a status column (FullBackupStatus, JobStatus ...): its code with its word and colour
const isStatusCol = (c: { name: string; type: string }) => /Status$/.test(c.name) && (c.type === 'INT' || c.type === 'TINYINT' || c.type === 'SMALLINT');
// a snapshot time of RunningQueriesSummary_Get (UTC, as the repository keeps it) as the sessions screen's ds= value
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

// screenInto: one screen appended to sec; the rows it showed (every result set)
async function screenInto(sec: HTMLElement, ctx: Ctx, m: Mode, page: string, snapshot?: string): Promise<number> {
  const w = window_(ctx);
  // the instance's facts and pgvigil's own instance of the same server; a failed read leaves the actions off (said below)
  const head = await get<DBADashInstance>('dbadash', { repo: m.repo, id: m.id, from: w.from, to: w.to })
    .catch((e: unknown) => { if (e instanceof LoginRequired) throw e; return null; });
  const i = head ? rowsOf(head.instance)[0] : undefined;
  const pg = head ? rowsOf(head.pgvigil)[0] : undefined;
  let d: PageReply;
  try {
    d = await get<PageReply>('dbadash', { repo: m.repo, id: m.id, page, from: w.from, to: w.to, ...(snapshot ? { snapshot } : {}) });
  } catch (e) {
    if (e instanceof LoginRequired) throw e;
    sec.append(errorBox(e));
    return 0;
  }
  sec.append(el('h3', {}, d.title, page === 'sessions' ? (snapshot ? ` at ${fmtTime(snapshot)}` : ' (the latest snapshot)') : ''),
    el('p', { class: 'meta' }, `The repository's own ${d.procedure}, called now for this instance through its read login (${d.ms} ms); version ${d.version || '(no version row)'}.`));
  if (!d.proven) sec.append(el('p', { class: 'error', role: 'status' }, d.note ?? 'not proven on this source version'));
  // the actions: the SQL Server instance pgvigil collects under the same server name AND machine name (a host renamed
  // without sp_dropserver keeps its old @@SERVERNAME, which a new server may carry), on the latest snapshot only (a past
  // snapshot's session id may belong to another session now); otherwise off with the reason
  const same = (a: unknown, b: unknown) => a != null && b != null && String(a) !== '' && String(a).toUpperCase() === String(b).toUpperCase();
  let why = '';
  if (!head) why = 'the instance\'s pgvigil match could not be read: reload the page';
  else if (!pg) why = `${i ? String(i.instance) : 'this instance'} is not a SQL Server instance pgvigil collects (an instances: entry with engine: sqlserver, its actions_dsn and actions: list; docs/dbadash.md)`;
  else if (!same(d.instance, pg.server_name) || !same(d.machine, pg.machine_name)) {
    why = `the repository knows this server as ${d.instance || '?'} on machine ${d.machine || '(none recorded)'}, pgvigil's instance ${String(pg.name)} as ${String(pg.server_name ?? '?')} on machine ${String(pg.machine_name ?? '?')}: they may be two servers under one name`;
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
  let n = 0;
  d.results.forEach((set, k) => {
    const { cols, rows } = setRows(set);
    n += rows.length;
    if (page === 'running') {
      const at = cols.find(c => c.key === 'SnapshotDateUTC');
      if (at) at.fmt = v => el('a', { href: tabHref(ctx, m, 'mssql_running', asUTC(v)), title: 'the sessions of this snapshot' }, fmtTime(asUTC(v)));
    }
    if (actCol && k === 0) cols.push(actCol);
    if (d.results.length > 1) sec.append(el('h4', {}, `Result set ${k + 1}`));
    if (set.truncated) sec.append(el('p', { class: 'meta' }, 'The first 5000 rows of this result set.'));
    sec.append(grid(rows, cols, 'No rows.'));
  });
  if (page === 'running') sec.append(el('p', {}, el('a', { href: tabHref(ctx, m, 'mssql_running', 'latest') }, 'The latest snapshot\'s sessions')));
  if (page === 'sessions') sec.append(el('p', {}, el('a', { href: tabHref(ctx, m, 'mssql_running') }, 'Back to the snapshots')));
  return n;
}

// ---- the tree's Imported folders (drawn by tree.ts below the instance folders)

function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
function lsSet(k: string, v: string) { try { localStorage.setItem(k, v); } catch { /* private window */ } }
const shut = new Set<string>((() => { try { return JSON.parse(lsGet('pgvigil.dbadashShut') ?? '[]') as string[]; } catch { return []; } })());

// dbadashFolders: one folder per configured repository, "Imported: <name> (n)", a status dot rolled up from its
// instances, a node per SQL Server instance (its pgvigil instance when pgvigil holds one, else its own page); a
// repository not read shows 'not read' and the reason under it. redraw is the tree's own draw (called when the read
// arrives or a caret is pressed); filter is the tree's search text.
export function dbadashFolders(ctx: Ctx, redraw: () => void, filter = ''): HTMLElement[] {
  if (!cache || (Date.now() - cache.at >= (cache.err ? 30000 : 25000) && !pending)) {
    dbadashData(true).then(() => redraw(), e => {
      cache = { at: Date.now(), err: e instanceof Error ? e.message : String(e), login: e instanceof LoginRequired };
      if (!(e instanceof LoginRequired)) redraw();
    });
  }
  if (!cache?.d) return cache?.err && !cache.login ? [el('p', { class: 'error', role: 'status' }, 'Imported servers: could not load: ' + cache.err)] : [];
  const d = cache.d;
  const repos = rowsOf(d.repositories), fleet = rowsOf(d.fleet);
  const curRepo = ctx.tab === 'dbadash' ? hashParam('dr') : undefined, curId = ctx.tab === 'dbadash' ? hashParam('di') : undefined;
  const out: HTMLElement[] = [];
  for (const r of repos) {
    const name = String(r.repository);
    const all = fleet.filter(f => f.repository === name);
    const shown = all.filter(f => !filter || String(f.display_name).toLowerCase().includes(filter));
    if (filter && shown.length === 0) continue;
    const key = 'dd:' + name, closed = shut.has(key) && !filter;
    const caret = el('button', { type: 'button', class: 'caret', 'data-key': key, 'aria-expanded': String(!closed), 'aria-label': `${closed ? 'expand' : 'collapse'} Imported ${name}` }, closed ? '▸' : '▾');
    caret.addEventListener('click', () => { if (shut.has(key)) shut.delete(key); else shut.add(key); lsSet('pgvigil.dbadashShut', JSON.stringify([...shut])); redraw(); });
    const lvl = all.reduce<0 | 1 | 2>((a, f) => Math.max(a, Number(f.level ?? 0)) as 0 | 1 | 2, 0);
    const label = el('a', { class: 'folder-name' + (curRepo === name && !curId ? ' on' : ''), href: dbadashHref(ctx, name), title: repoState(r) }, `Imported: ${name} (${all.length})`);
    const box = el('div', { class: 'folder' }, el('div', { class: 'folder-head' }, caret, ldot(r.status === 'ok' ? lvl : 1, r.status === 'ok' ? levelWords[lvl] : 'not read'), label));
    if (!closed) {
      const ul = el('div', { class: 'folder-items' });
      if (r.status !== 'ok') ul.append(el('p', { class: 'error', style: 'padding:.1rem .4rem', role: 'status' }, `not read: ${String(r.reason ?? '')}`));
      for (const f of shown) {
        const pv = pgvigilOf(d, name, Number(f.instance_id));
        const on = pv ? ctx.instance === pv.instanceId : curRepo === name && curId === String(f.instance_id);
        ul.append(el('div', { class: 'tree-inst', style: 'display:flex;align-items:center' },
          el('a', { class: 'inst' + (on ? ' on' : ''), style: 'flex:1;min-width:0', href: instanceHref(ctx, d, name, f.instance_id),
            title: `SQL Server ${String(f.instance)}, imported: ${name}${pv ? (pv.collected ? ' (pgvigil collects it)' : ` (pgvigil instance ${pv.name})`) : ' (not yet one of pgvigil\'s instances)'}` },
          ldot(Number(f.level ?? 0), levelWords[Number(f.level ?? 0)]), String(f.display_name))));
      }
      if (r.status === 'ok' && all.length === 0) ul.append(el('p', { class: 'empty', style: 'padding:.1rem .4rem' }, 'No active instance in this repository.'));
      box.append(ul);
    }
    out.push(box);
  }
  return out;
}
