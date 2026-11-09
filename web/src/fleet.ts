// The fleet's instances and daily-check rows, shared by the tree, the Summary grid and the checks page,
// fetched at most once per 25 s unless a refresh forces it.
import { get, Row, rowsOf } from './api';

export interface Fleet { instances: Row[]; checks: Row[]; at: number }
let cache: Fleet | null = null;
let pending: Promise<Fleet> | null = null;

export async function fleet(force = false): Promise<Fleet> {
  if (!force && cache && Date.now() - cache.at < 25000) return cache;
  if (pending) return pending;
  pending = Promise.all([get('instances'), get('overview')])
    .then(([i, c]) => (cache = { instances: rowsOf(i), checks: rowsOf(c), at: Date.now() }))
    .finally(() => { pending = null; });
  return pending;
}

export function forget() { cache = null; }

// Status groups: one coloured cell each on the Summary grid. A group's checks are the overview's
// check_group names; activity is read from the instance row's latest session summary.
export interface Group { key: string; label: string; checks: string[]; tab: string }
export const groups: Group[] = [
  { key: 'collect', label: 'Collection', checks: ['collection failing', 'collection stale'], tab: 'summary' },
  { key: 'activity', label: 'Activity', checks: [], tab: 'activity' },
  { key: 'replication', label: 'Replication', checks: ['replication'], tab: 'replication' },
  { key: 'jobs', label: 'Jobs', checks: ['jobs'], tab: 'jobs' },
  { key: 'dms', label: 'DMS', checks: ['dms'], tab: 'dms' },
  { key: 'tables', label: 'Tables', checks: ['tables'], tab: 'tables' },
  { key: 'vacuum', label: 'Vacuum', checks: ['vacuum'], tab: 'vacuum' },
  { key: 'dbhealth', label: 'Deadlocks / checksums', checks: ['deadlocks and checksums'], tab: 'counters' },
  { key: 'host', label: 'Host', checks: ['host'], tab: 'host' },
  { key: 'disk', label: 'Disk', checks: ['disk'], tab: 'host' },
  { key: 'storage', label: 'Storage', checks: ['storage'], tab: 'storage' },
];

export type Level = 0 | 1 | 2;   // ok, warning, critical
export interface Cell { level: Level; n: number; detail: string[]; none?: boolean }   // none = no data to judge

const sevLevel = (s: unknown): Level => s === 'critical' ? 2 : 1;

// activityCell: lock waiters now, an idle-in-transaction session over 5 min, an active one over 1 h.
function activityCell(r: Row): Cell {
  if (r.activity_at == null) return { level: 0, n: 0, detail: ['no activity sample yet'], none: true };
  const d: string[] = [];
  const wl = Number(r.waiting_lock ?? 0), idle = Number(r.longest_idle_txn_secs ?? 0), act = Number(r.longest_active_secs ?? 0);
  if (wl > 0) d.push(`${wl} session(s) waiting on a lock`);
  if (idle > 300) d.push(`idle in transaction for ${Math.round(idle / 60)} min`);
  if (act > 3600) d.push(`a statement active for ${Math.round(act / 60)} min`);
  return { level: d.length ? 1 : 0, n: d.length, detail: d };
}

export function cells(f: Fleet, r: Row): Record<string, Cell> {
  const id = Number(r.instance_id);
  const mine = f.checks.filter(c => Number(c.instance_id) === id);
  const out: Record<string, Cell> = {};
  for (const g of groups) {
    if (g.key === 'activity') { out[g.key] = activityCell(r); continue; }
    const hit = mine.filter(c => g.checks.includes(String(c.check_group)));
    // Host and Disk read "no sample" on an instance the host collection has never reached (no system_stats, no
    // CloudWatch door: Azure, Cloud SQL): an empty check list there is not OK
    if ((g.key === 'host' || g.key === 'disk') && r.host_at == null && hit.length === 0) {
      out[g.key] = { level: 0, n: 0, detail: ['no host sample yet'], none: true };
      continue;
    }
    out[g.key] = {
      level: hit.reduce<Level>((a, c) => Math.max(a, sevLevel(c.severity)) as Level, 0),
      n: hit.length,
      detail: hit.map(c => `${c.check_name}: ${c.object ?? ''} ${c.detail ?? ''}`.trim()),
    };
  }
  return out;
}

export function worst(f: Fleet, r: Row): Level {
  return Object.values(cells(f, r)).reduce<Level>((a, c) => Math.max(a, c.level) as Level, 0);
}

export const levelClass = ['ok', 'warn', 'crit'];
export const cellClass = (c: Cell) => c.none ? 'none' : levelClass[c.level];
export const cellText = (c: Cell) => c.none ? 'no sample' : c.level === 0 ? 'OK' : `${c.n} ${c.level === 2 ? 'critical' : 'warning'}`;

export function tagsOf(r: Row): string[] {
  const t = r.tags;
  return Array.isArray(t) && t.length ? t.map(String) : [];
}
