// The hash route: #/<tab>?i=<instance>&tag=<tag>&w=<preset>|from=..&to=..&<page params>.
// With i the tab is one of the instance tabs, without it one of the root (fleet) tabs.
// The time range rides on every link, so a tab change keeps it.

export interface Range { preset?: string; from?: string; to?: string }
export interface Ctx {
  tab: string;
  instance?: number;
  tag?: string;
  range: Range;
  kind: string;          // counters kind
  logKind?: string;      // logs kind filter
  at?: string;           // activity snapshot
  task?: string;         // DMS task ARN
  taskInstance?: number;
  order?: string;        // statements sort
  minSecs?: number;      // statements: executions seen running at least this long
  ms?: number;           // slow queries: the threshold in milliseconds
}

function lsGet(k: string): string | null { try { return localStorage.getItem(k); } catch { return null; } }
export function rememberInstance(id?: number) { if (id) try { localStorage.setItem('pgvigil.instance', String(id)); } catch { /* private window */ } }

export const presets: Record<string, number> = { '15m': 900, '1h': 3600, '6h': 21600, '24h': 86400, '7d': 604800, '30d': 2592000 };

export const rootTabs: Record<string, string> = { summary: 'Summary', checks: 'Daily checks', findings: 'Findings', instances: 'Instances', dms: 'DMS', jobs: 'Jobs', disks: 'Disk report', storage: 'Storage', extensions: 'Extensions', versions: 'Versions', roles: 'Roles', slowqueries: 'Slow queries' };
export const instanceTabs: Record<string, string> = {
  summary: 'Summary', activity: 'Running queries', statements: 'Statements', slowqueries: 'Slow queries', counters: 'Counters', tables: 'Tables', vacuum: 'Vacuum',
  io: 'IO', replication: 'Replication', jobs: 'Jobs', jobsreport: 'Job report', logs: 'Logs', dms: 'DMS', config: 'Configuration', findings: 'Findings',
  host: 'Host', storage: 'Storage', extensions: 'Extensions', versions: 'Versions', roles: 'Roles', actions: 'Actions log',
};
const legacy: Record<string, string> = { overview: 'checks' };

export function parse(): Ctx {
  const h = location.hash.replace(/^#\/?/, '');
  const [p, qs] = h.split('?');
  const q = new URLSearchParams(qs ?? '');
  const name = legacy[p] ?? p;
  // an instance-only tab without i (an old bookmark) opens the instance last viewed in this browser
  const instance = Number(q.get('i')) || (instanceTabs[name] && !rootTabs[name] && !q.get('tag') ? Number(lsGet('pgvigil.instance')) || undefined : undefined);
  const tabs = instance ? instanceTabs : rootTabs;
  const from = q.get('from') ?? undefined, to = q.get('to') ?? undefined;
  const custom = from && to && !isNaN(Date.parse(from)) && !isNaN(Date.parse(to)) && Date.parse(from) < Date.parse(to);
  const w = q.get('w') ?? '';
  return {
    tab: tabs[name] ? name : 'summary',
    instance,
    tag: q.get('tag') ?? undefined,
    range: custom ? { from, to } : { preset: presets[w] ? w : '1h' },
    kind: q.get('kind') ?? 'db',
    logKind: q.get('lk') ?? undefined,
    at: q.get('at') ?? undefined,
    task: q.get('task') ?? undefined,
    taskInstance: Number(q.get('ti')) || undefined,
    order: q.get('order') ?? undefined,
    minSecs: q.has('min') && Number.isFinite(Number(q.get('min'))) ? Math.min(86400, Math.max(0, Math.trunc(Number(q.get('min'))))) : undefined,
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
  if (c.tab === 'logs') page('logKind', 'lk');
  if (c.tab === 'activity') page('at', 'at');
  if (c.tab === 'dms') { page('task', 'task'); page('taskInstance', 'ti'); }
  if (c.tab === 'statements') { page('order', 'order'); page('minSecs', 'min'); }
  if (c.tab === 'slowqueries') page('ms', 'ms');
  return `#/${c.tab}?${q}`;
}

// window gives the API's from/to: a preset ends now, a custom range is fixed.
export function window_(ctx: Ctx): { from: string; to: string } {
  if (ctx.range.from && ctx.range.to) return { from: new Date(ctx.range.from).toISOString(), to: new Date(ctx.range.to).toISOString() };
  const to = new Date();
  return { from: new Date(to.getTime() - (presets[ctx.range.preset ?? '1h'] ?? 3600) * 1000).toISOString(), to: to.toISOString() };
}

export function rangeLabel(ctx: Ctx): string {
  if (ctx.range.preset) return 'last ' + ctx.range.preset;
  const f = (s?: string) => new Date(s ?? '').toLocaleString(undefined, { hour12: false });
  return `${f(ctx.range.from)} to ${f(ctx.range.to)}`;
}

// isLive: a preset range follows now (auto refresh); a custom range is history.
export function isLive(ctx: Ctx): boolean { return !!ctx.range.preset; }
