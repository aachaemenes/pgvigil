// The hash route: #/<tab>?i=<instance>&tag=<tag>&w=<preset>|from=..&to=..&<page params>.
// With i the tab is one of the instance tabs, without it one of the root (fleet) tabs.
// The time range rides on every link, so a tab change keeps it.

import { fmt, parts, zonedToUtc } from './tz';

export interface Range { preset?: string; from?: string; to?: string }
export interface Ctx {
  tab: string;
  instance?: number;
  tag?: string;
  range: Range;
  kind: string;          // the Metrics page's counter family (the old Counters kinds db, server, io, sessions still open theirs)
  logKind?: string;      // logs kind filter
  at?: string;           // activity snapshot
  task?: string;         // DMS task ARN
  taskInstance?: number;
  order?: string;        // statements sort
  minSecs?: number;      // statements and the running-queries window: executions seen running at least this long
  st?: string;           // running-queries window: 'active' | 'idle' (idle in transaction); unset = both
  user?: string;         // running-queries window: the session's user, database and application (exact)
  db?: string;
  app?: string;
  ms?: number;           // slow queries: the threshold in milliseconds
}

function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
export function rememberInstance(id?: number) { if (id) try { localStorage.setItem('pgvigil.instance', String(id)); } catch { /* private window */ } }

export const presets: Record<string, number> = { '15m': 900, '1h': 3600, '6h': 21600, '24h': 86400, '7d': 604800, '30d': 2592000 };
// Calendar periods that end now: they follow now like a preset, from the start of the day, the week (Monday) or the
// month on the display zone's clock (tz.ts). A period that has ended (yesterday, the week or month before) is a fixed
// from / to the range panel writes.
export const periods: Record<string, string> = { today: 'today', wtd: 'week to date', mtd: 'month to date' };
export const MAX_RANGE_MS = 31 * 86400e3;   // the longest window the server reads (internal/web maxWindow)
// periodStart: where a period of the instant `now` begins; back = whole periods earlier (1 = the one before)
export function periodStart(p: string, now: Date, back = 0): Date {
  const n = parts(now);
  if (p === 'mtd') return zonedToUtc(n.y, n.mo - back, 1);
  if (p === 'wtd') return zonedToUtc(n.y, n.mo, n.d - ((n.wd + 6) % 7) - 7 * back);
  return zonedToUtc(n.y, n.mo, n.d - back);
}
// capRange: a window cut at its start to the server's longest (a 31-day month with a fall-back hour is an hour over)
export function capRange(from: Date, to: Date): { from: Date; to: Date } {
  return to.getTime() - from.getTime() > MAX_RANGE_MS ? { from: new Date(to.getTime() - MAX_RANGE_MS), to } : { from, to };
}

export const rootTabs: Record<string, string> = { summary: 'Summary', checks: 'Daily checks', findings: 'Findings', instances: 'Instances', dms: 'DMS', jobs: 'Jobs', disks: 'Disk report', storage: 'Storage', backups: 'Backups', corruption: 'Corruption', extensions: 'Extensions', versions: 'Versions', roles: 'Roles', slowqueries: 'Slow queries', running: 'Running queries', indexes: 'Indexes', growth: 'Growth', dbadash: 'DBADash', custom: 'Custom report', alerts: 'Alerts', alertrules: 'Alert rules', perfsummary: 'Performance summary', jobstimeline: 'Jobs timeline', mssqltempdb: 'TempDB', dbchanges: 'New and dropped databases', diff: 'Diff', tablesize: 'Table size' };
export const instanceTabs: Record<string, string> = {
  summary: 'Summary', performance: 'Performance', activity: 'Running queries', statements: 'Statements', slowqueries: 'Slow queries', counters: 'Metrics', tables: 'Tables', vacuum: 'Vacuum',
  io: 'IO', load: 'Load', replication: 'Replication', jobs: 'Jobs', jobsreport: 'Job report', logs: 'Logs', dms: 'DMS', config: 'Configuration', findings: 'Findings',
  host: 'Host', storage: 'Storage', dbinfo: 'Database info', backups: 'Backups', corruption: 'Corruption', extensions: 'Extensions', versions: 'Versions', roles: 'Roles', waits: 'Waits', memory: 'Memory', pooler: 'Pooler', indexes: 'Indexes', schema: 'Schema', plans: 'Plans', actions: 'Actions log', custom: 'Custom', jobstimeline: 'Jobs timeline', connections: 'Connections', dbchanges: 'New and dropped databases',
};
const legacy: Record<string, string> = { overview: 'checks' };

// The tab strip stays short: a scope's main tabs, and every other page under a folder of the tree with its own short
// row of tabs (DBA Dash's Configuration / Checks / HA/DR / Storage / Jobs folders). A page's address does not change:
// rootTabs and instanceTabs still name every page; a group only says which pages share a strip.
export interface TabGroup { key: string; name: string; tabs: string[] }
export const rootGroups: TabGroup[] = [
  { key: 'main', name: '', tabs: ['summary', 'alerts', 'alertrules', 'perfsummary', 'slowqueries', 'running', 'findings', 'instances'] },
  { key: 'checks', name: 'Checks', tabs: ['checks', 'corruption', 'custom'] },
  { key: 'conf', name: 'Configuration', tabs: ['versions', 'extensions', 'roles', 'diff'] },
  { key: 'hadr', name: 'HA/DR', tabs: ['backups', 'dms'] },
  { key: 'storage', name: 'Storage', tabs: ['disks', 'storage', 'growth', 'tablesize', 'dbchanges', 'indexes', 'mssqltempdb'] },
  { key: 'jobs', name: 'Jobs', tabs: ['jobs', 'jobstimeline'] },
  { key: 'doors', name: 'Doors', tabs: ['dbadash'] },
];
export const instanceGroups: TabGroup[] = [
  { key: 'main', name: '', tabs: ['summary', 'performance', 'activity', 'slowqueries', 'statements', 'plans', 'waits', 'memory', 'findings', 'logs'] },
  { key: 'checks', name: 'Checks', tabs: ['corruption', 'vacuum', 'indexes', 'custom'] },
  { key: 'conf', name: 'Configuration', tabs: ['config', 'extensions', 'versions', 'roles', 'schema', 'actions'] },
  { key: 'perf', name: 'Performance', tabs: ['counters', 'host', 'io', 'load', 'connections', 'pooler'] },
  { key: 'hadr', name: 'HA/DR', tabs: ['replication', 'backups', 'dms'] },
  { key: 'storage', name: 'Storage', tabs: ['storage', 'dbinfo', 'dbchanges', 'tables'] },
  { key: 'jobs', name: 'Jobs', tabs: ['jobs', 'jobsreport', 'jobstimeline'] },
];
// A SQL Server instance has its own pages (the engine of the instance chooses the tab set; a PostgreSQL page is
// never offered for it, and the other way round). Summary and Findings are shared: both read by instance.
export const mssqlInstanceTabs: Record<string, string> = {
  summary: 'Summary', performance: 'Performance', mssql_running: 'Running queries', mssql_slow: 'Slow queries', mssql_waits: 'Waits', mssql_deadlocks: 'Deadlocks',
  mssql_blocked: 'Blocked reports', findings: 'Findings', availability: 'Availability', mssqlbackups: 'Backups', mssqljobs: 'Jobs',
  mssqlstorage: 'Storage', mssqlfiles: 'Database files', rowversions: 'Row versions', mssqlconfig: 'Configuration', mssqlactions: 'Actions log', jobstimeline: 'Jobs timeline',
  mssqlcpu: 'CPU', mssqlmemory: 'Memory', mssqlfileio: 'File IO', mssqltempdb: 'TempDB', mssqlqs: 'Query Store', counters: 'Metrics',
  mssqlprocs: 'Procedures', mssqlindexlocks: 'Index locks', mssqlproperties: 'Properties', mssqlaudit: 'Audit',
};
export const mssqlInstanceGroups: TabGroup[] = [
  { key: 'main', name: '', tabs: ['summary', 'performance', 'mssql_running', 'mssql_slow', 'mssql_waits', 'mssql_deadlocks', 'mssql_blocked', 'findings'] },
  { key: 'hadr', name: 'HA/DR', tabs: ['availability', 'mssqlbackups'] },
  { key: 'perf', name: 'Performance', tabs: ['counters', 'mssqlcpu', 'mssqlmemory', 'mssqlfileio', 'mssqlqs', 'mssqlprocs', 'mssqlindexlocks'] },
  { key: 'storage', name: 'Storage', tabs: ['mssqlstorage', 'mssqlfiles', 'rowversions', 'mssqltempdb'] },
  { key: 'jobs', name: 'Jobs', tabs: ['mssqljobs', 'jobstimeline'] },
  { key: 'conf', name: 'Configuration', tabs: ['mssqlconfig', 'mssqlproperties', 'mssqlaudit', 'mssqlactions'] },
];
export const isMssql = (engine: unknown) => engine === 'sqlserver';
export const tabsFor = (engine: unknown) => isMssql(engine) ? mssqlInstanceTabs : instanceTabs;
export const groupsFor = (engine: unknown) => isMssql(engine) ? mssqlInstanceGroups : instanceGroups;

// groupOf: the group whose strip a page shows (a drill page: its home tab's); a page in no group shows the main one
export function groupOf(groups: TabGroup[], tab: string): TabGroup {
  const t = drillHome[tab] ?? tab;
  return groups.find(g => g.tabs.includes(t)) ?? groups[0];
}
// the drill-down pages of one instance (drill.ts): reached by links, not shown in the tab strip
export const drillTabs: Record<string, string> = { db: 'Database', table: 'Table', job: 'Job', index: 'Index', compare: 'Compare' };
// the tab a drill page belongs to: marked in the strip, and where the tree's link to another instance lands
export const drillHome: Record<string, string> = { db: 'dbinfo', table: 'dbinfo', index: 'dbinfo', job: 'jobs', compare: 'statements' };

export function parse(): Ctx {
  const h = location.hash.replace(/^#\/?/, '');
  const [p, qs] = h.split('?');
  const q = new URLSearchParams(qs ?? '');
  const name = legacy[p] ?? p;
  // an instance-only tab without i (an old bookmark) opens the instance last viewed in this browser
  const instance = Number(q.get('i')) || ((instanceTabs[name] || mssqlInstanceTabs[name] || drillTabs[name]) && !rootTabs[name] && !q.get('tag') ? Number(lsGet('pgvigil.instance')) || undefined : undefined);
  const tabs = instance ? instanceTabs : rootTabs;
  const from = q.get('from') ?? undefined, to = q.get('to') ?? undefined;
  const custom = from && to && !isNaN(Date.parse(from)) && !isNaN(Date.parse(to)) && Date.parse(from) < Date.parse(to);
  const w = q.get('w') ?? '';
  return {
    tab: tabs[name] || (instance && (drillTabs[name] || mssqlInstanceTabs[name])) ? name : 'summary',
    instance,
    tag: q.get('tag') ?? undefined,
    range: custom ? { from, to } : { preset: presets[w] || periods[w] ? w : '1h' },
    kind: q.get('kind') ?? 'all',
    logKind: q.get('lk') ?? undefined,
    at: q.get('at') ?? undefined,
    task: q.get('task') ?? undefined,
    taskInstance: Number(q.get('ti')) || undefined,
    order: q.get('order') ?? undefined,
    minSecs: q.has('min') && Number.isFinite(Number(q.get('min'))) ? Math.min(86400, Math.max(0, Math.trunc(Number(q.get('min'))))) : undefined,
    // the running-queries window's filters ride the activity tab alone (a drill page's db= is an oid, not a name)
    st: name === 'activity' && (q.get('st') === 'active' || q.get('st') === 'idle') ? q.get('st')! : undefined,
    user: name === 'activity' ? q.get('user')?.slice(0, 64) || undefined : undefined,
    db: name === 'activity' ? q.get('db')?.slice(0, 64) || undefined : undefined,
    app: name === 'activity' ? q.get('app')?.slice(0, 64) || undefined : undefined,
    ms: q.has('ms') && Number.isFinite(Number(q.get('ms'))) ? Math.min(86400000, Math.max(0, Math.trunc(Number(q.get('ms'))))) : undefined,
  };
}

// href keeps the instance or tag, and the range; page parameters only when given in over or still on that tab.
export function href(ctx: Ctx, over: Partial<Ctx> & { tab: string }): string {
  const c: Ctx = { ...ctx, ...over };
  const keep = over.tab === ctx.tab && c.instance === ctx.instance;
  const q = new URLSearchParams();
  if (c.instance) q.set('i', String(c.instance));
  else if (c.tag) q.set('tag', c.tag);
  if (c.range.preset) q.set('w', c.range.preset);
  else if (c.range.from && c.range.to) { q.set('from', c.range.from); q.set('to', c.range.to); }
  const page = (k: keyof Ctx, name: string) => {
    const v = k in over ? over[k] : keep ? ctx[k] : undefined;
    if (v !== undefined && v !== '') q.set(name, String(v));
  };
  if (c.tab === 'counters') page('kind', 'kind');
  // the Metrics page's database cut stays on its own links: a range change keeps the database in view
  if (keep && c.tab === 'counters') {
    const v = new URLSearchParams(location.hash.split('?')[1] ?? '').get('mdb');
    if (v) q.set('mdb', v);
  }
  if (c.tab === 'logs') page('logKind', 'lk');
  if (c.tab === 'activity') { page('at', 'at'); page('minSecs', 'min'); page('st', 'st'); page('user', 'user'); page('db', 'db'); page('app', 'app'); }
  if (c.tab === 'dms') { page('task', 'task'); page('taskInstance', 'ti'); }
  if (c.tab === 'statements') { page('order', 'order'); page('minSecs', 'min'); }
  // the Statements page's ticks and grouping (stmt_filter.ts) stay on its own links: a sort or a range change keeps them
  if (keep && c.tab === 'statements') {
    const cur = new URLSearchParams(location.hash.split('?')[1] ?? '');
    for (const k of ['sg', 'sdb', 'suser', 'scl']) for (const v of cur.getAll(k)) q.append(k, v);
  }
  if (c.tab === 'slowqueries') page('ms', 'ms');
  // the Query Store page's view, sort and database (mssql_querystore.ts) stay on its own links
  if (keep && c.tab === 'mssqlqs') {
    const cur = new URLSearchParams(location.hash.split('?')[1] ?? '');
    for (const k of ['qs', 'qo', 'qdb']) { const v = cur.get(k); if (v) q.set(k, v); }
  }
  // the Database info and drill-down pages keep their own parameters (db, rel, scheduler, job, idx) on a link to the
  // same page, so a range change stays on the same database, table, job or index
  if (keep && (drillTabs[c.tab] || c.tab === 'dbinfo')) {
    const cur = new URLSearchParams(location.hash.split('?')[1] ?? '');
    for (const k of ['db', 'rel', 'scheduler', 'job', 'idx']) { const v = cur.get(k); if (v) q.set(k, v); }
  }
  if (keep && c.tab === 'dbadash') {
    const cur = new URLSearchParams(location.hash.split('?')[1] ?? '');
    for (const k of ['dr', 'di']) { const v = cur.get(k); if (v) q.set(k, v); }
  }
  // the Diff page's picks (diff.ts: mode, the two sides, their databases and times, identical rows) stay on a range change
  if (keep && c.tab === 'diff') {
    const cur = new URLSearchParams(location.hash.split('?')[1] ?? '');
    for (const k of ['m', 'a', 'b', 'dba', 'dbb', 'ta', 'tb', 'all']) { const v = cur.get(k); if (v) q.set(k, v); }
  }
  return `#/${c.tab}?${q}`;
}

// window gives the API's from/to: a preset or a calendar period ends now, a custom range is fixed.
export function window_(ctx: Ctx): { from: string; to: string } {
  if (ctx.range.from && ctx.range.to) return { from: new Date(ctx.range.from).toISOString(), to: new Date(ctx.range.to).toISOString() };
  const to = new Date(), p = ctx.range.preset ?? '1h';
  if (periods[p]) {
    // a period seconds old (just past midnight) still reads a minute, so no page is asked for an empty window
    const w = capRange(new Date(Math.min(periodStart(p, to).getTime(), to.getTime() - 60000)), to);
    return { from: w.from.toISOString(), to: w.to.toISOString() };
  }
  return { from: new Date(to.getTime() - (presets[p] ?? 3600) * 1000).toISOString(), to: to.toISOString() };
}

export function rangeLabel(ctx: Ctx): string {
  if (ctx.range.preset) return periods[ctx.range.preset] ?? 'last ' + ctx.range.preset;
  const f = (s?: string) => fmt(new Date(s ?? ''));
  return `${f(ctx.range.from)} to ${f(ctx.range.to)}`;
}

// isLive: a preset range or a calendar period follows now (auto refresh); a custom range is history.
export function isLive(ctx: Ctx): boolean { return !!ctx.range.preset; }
