// The fleet's instances and daily-check rows, shared by the tree, the Summary grid and the checks page,
// fetched at most once per 25 s unless a refresh forces it.
import { get, Row, rowsOf, Table } from './api';
import { auditFleetCell, readAuditFleet } from './pgaudit';
import { versionCell } from './versions';

// mssql: the SQL Server instances' status cells (one row per instance and group) and their descriptions
// mssqlFailed: the SQL Server read itself failed (its cells then say so, never 'not yet')
// pgaudit: the PostgreSQL instances' pgaudit cells (readAuditFleet); pgauditFailed: that read failed
export interface Fleet { instances: Row[]; checks: Row[]; versions: Row[]; mssql: Row[]; mssqlServers: Row[]; pgdb: Row[]; mssqlFailed: boolean; pgaudit: Row[]; pgauditFailed: boolean; at: number }
let cache: Fleet | null = null;
let pending: Promise<Fleet> | null = null;
// the pgaudit cells are read at most every 5 minutes, a forced refresh included (the Summary's auto refresh forces one
// every 30 s): GET /api/pgaudit counts every instance's findings, a plan the server can estimate past jit_above_cost -
// on a store of 12 instances, about 18 ms over 12,000 pgaudit_events and 1.5 s over 600,000, all but 40 ms of it the
// JIT compile (40 ms with jit off; task 167's measurement); the pgaudit collection itself reads health once a minute
const auditTTL = 300000;
let audit: { rows: Row[]; failed: boolean; at: number } | null = null;
function auditRead(): Promise<{ rows: Row[]; failed: boolean }> {
  if (audit && Date.now() - audit.at < auditTTL) return Promise.resolve(audit);
  return readAuditFleet().then(rows => ({ rows, failed: false }), () => ({ rows: [] as Row[], failed: true }))
    .then(a => (audit = a.failed ? null : { ...a, at: Date.now() }, a));   // a failed read is tried again at the next fleet read
}

export async function fleet(force = false): Promise<Fleet> {
  if (!force && cache && Date.now() - cache.at < 25000) return cache;
  if (pending) return pending;
  // the versions read is optional: a repository not yet migrated to 0035 (or any failure there) costs the Version
  // column only, never the tree and the Summary
  // the SQL Server read is optional the same way (a repository before 0064, a failure): its rows then say 'not yet'
  // the pgaudit read too (a repository before 0100, a failure): the PostgreSQL Audit cells then say 'read failed'
  pending = Promise.all([get('instances'), get('overview'), get<{ fleet: Table | null }>('versions', {}).catch(() => ({ fleet: null })),
    get<{ cells: Table | null; servers: Table | null; pgdb: Table | null; failed?: boolean }>('mssql/summary', {}).catch(() => ({ cells: null, servers: null, pgdb: null, failed: true })),
    auditRead()])
    .then(([i, c, v, m, a]) => (cache = { instances: rowsOf(i), checks: rowsOf(c), versions: rowsOf(v.fleet), mssql: rowsOf(m.cells), mssqlServers: rowsOf(m.servers), pgdb: rowsOf(m.pgdb), mssqlFailed: m.failed === true, pgaudit: a.rows, pgauditFailed: a.failed, at: Date.now() }))
    .finally(() => { pending = null; });
  return pending;
}

export function forget() { cache = null; }

// Status groups: one coloured cell each on the Summary grid. A group's checks are the overview's
// check_group names; activity is read from the instance row's latest session summary.
// mssql: the group's key in the SQL Server read (/api/mssql/summary) and the SQL Server tab its cell opens; a group
// without it is a PostgreSQL check.
export interface Group { key: string; label: string; checks: string[]; tab: string; kind?: string; mssql?: [string, string, string?]; mssqlOnly?: boolean }   // kind: the Metrics family a PostgreSQL cell opens   // the third: the group's name on a SQL Server page
export const groups: Group[] = [
  { key: 'collect', label: 'Collection', checks: ['collection failing', 'collection stale'], tab: 'summary' },
  { key: 'activity', label: 'Activity', checks: [], tab: 'activity', mssql: ['blocking', 'mssql_running', 'Blocking'] },
  { key: 'replication', label: 'Replication', checks: ['replication'], tab: 'replication', mssql: ['availability', 'availability', 'Availability'] },
  { key: 'jobs', label: 'Jobs', checks: ['jobs', 'jobs report'], tab: 'jobsreport', mssql: ['jobs', 'mssqljobs'] },
  { key: 'custom', label: 'Custom', checks: ['custom'], tab: 'custom' },
  { key: 'dms', label: 'DMS', checks: ['dms'], tab: 'dms' },
  { key: 'tables', label: 'Tables', checks: ['tables'], tab: 'tables' },
  { key: 'vacuum', label: 'Vacuum', checks: ['vacuum'], tab: 'vacuum' },
  { key: 'dbhealth', label: 'Deadlocks / checksums', checks: ['deadlocks and checksums'], tab: 'counters', kind: 'database', mssql: ['events', 'mssql_deadlocks', 'Deadlocks and blocked reports'] },
  { key: 'host', label: 'Host', checks: ['host', 'pi'], tab: 'host' },   // 'pi': cache starved by the ACU floor (the Capacity section sits on the Host tab)
  { key: 'disk', label: 'Disk', checks: ['disk'], tab: 'drives', mssql: ['disk', 'drives', 'Drive space'] },
  { key: 'storage', label: 'Storage', checks: ['storage'], tab: 'drives', mssql: ['storage', 'dbfiles'] },
  { key: 'backups', label: 'Backups', checks: ['backups', 'base backups', 'log shipping'], tab: 'backups', mssql: ['backups', 'mssqlbackups'] },
  // DBA Dash's Summary columns (plan task 106), both engines
  { key: 'uptime', label: 'Uptime', checks: ['uptime'], tab: 'pgstate', mssql: ['uptime', 'summary'] },
  { key: 'dbstate', label: 'Database state', checks: [], tab: 'dbinfo', mssql: ['dbstate', 'mssqlfiles'] },
  // SQL Server only until the PostgreSQL equivalents are built (the scheduler alive); Memory dumps' PostgreSQL twin is the log's
  // crash restarts, QS's is pg_stat_statements' state (task 162: the Server state tab)
  { key: 'agent', label: 'Agent', checks: [], tab: 'summary', mssql: ['agent', 'mssqljobs', 'SQL Server Agent'], mssqlOnly: true },
  { key: 'dbmail', label: 'DB Mail', checks: [], tab: 'summary', mssql: ['dbmail', 'summary', 'Database Mail'], mssqlOnly: true },
  { key: 'dumps', label: 'Dumps / crashes', checks: ['crashes'], tab: 'pgstate', mssql: ['dumps', 'summary', 'Memory dumps'] },
  { key: 'qs', label: 'QS', checks: ['statement store'], tab: 'pgstate', mssql: ['qs', 'mssqlqs', 'Query Store'] },
  // both engines: SQL Server Audit from the SQL Server read, pgaudit from the pgaudit fleet read (the instance's Audit tab)
  { key: 'audit', label: 'Audit', checks: [], tab: 'audit', mssql: ['audit', 'mssqlaudit', 'SQL Server Audit'] },
  { key: 'corruption', label: 'Corruption', checks: ['corruption', 'amcheck age'], tab: 'corruption' },
  { key: 'io', label: 'IO', checks: ['io'], tab: 'io' },
  { key: 'roles', label: 'Roles', checks: ['roles'], tab: 'roles' },
  { key: 'indexes', label: 'Indexes', checks: ['indexes'], tab: 'indexes' },
  { key: 'version', label: 'Version', checks: [], tab: 'versions' },   // from the versions fleet read, not a check group
];

export type Level = 0 | 1 | 2;   // ok, warning, critical
export interface Cell { level: Level; n: number; detail: string[]; none?: boolean; text?: string }   // none = no data to judge; text overrides the OK / n warning reading

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

// versionCellOf: the Summary's Version cell from the instance's versions_fleet row (versionCell's reading: EOL,
// minors behind, deprecated engine, maintenance due, collations); no row or no version read yet = none.
function versionCellOf(f: Fleet, id: number): Cell {
  const v = f.versions.find(x => Number(x.instance_id) === id);
  if (!v) return { level: 0, n: 0, detail: ['no version read yet'], none: true };
  const c = versionCell(v);
  return { level: c.level, n: c.detail.length, detail: c.detail, none: c.none, text: c.none ? undefined : c.text };
}

export function cells(f: Fleet, r: Row): Record<string, Cell> {
  const id = Number(r.instance_id);
  const mine = f.checks.filter(c => Number(c.instance_id) === id);
  const out: Record<string, Cell> = {};
  // a SQL Server instance: its Collection cell is judged like any other; a group with a SQL Server read takes its
  // cell from that read (no stored read of the group yet = 'not yet', never OK); a PostgreSQL-only group says so
  const otherEngine = r.engine != null && r.engine !== 'postgres';
  for (const g of groups) {
    if (otherEngine && g.key !== 'collect') {
      const m = g.mssql ? f.mssql.find(x => Number(x.instance_id) === id && x.key === g.mssql![0]) : undefined;
      const none = (text: string, why: string): Cell => ({ level: 0, n: 0, detail: [why], none: true, text });
      if (!g.mssql) out[g.key] = none('n/a', 'a PostgreSQL check: SQL Server has no such thing');
      else if (f.mssqlFailed) out[g.key] = none('read failed', 'the read of the SQL Server status cells failed (GET /api/mssql/summary): this is not the instance\'s state');
      else if (!m || m.state === 'never') out[g.key] = none('not yet', 'no read of this group stored for the instance yet');
      else {
        const crit = Number(m.critical ?? 0), warn = Number(m.warning ?? 0), state = String(m.state ?? 'ok');
        const detail = Array.isArray(m.detail) ? m.detail.map(String) : [];
        const age = m.read_at ? `the last read is from ${String(m.read_at).slice(0, 16).replace('T', ' ')} UTC` : 'no read is stored';
        const why = state === 'stale' ? `${age}: older than three of the collection's intervals` : state === 'failed' ? `the last run failed - ${String(m.err ?? '')}` : '';
        if (crit || warn) {
          // a critical or a warning shows whatever the read's state, with the state said beside it
          const word = crit ? 'critical' : 'warning', late = state === 'stale' ? ', stale' : state === 'failed' ? ', read failed' : '';
          out[g.key] = { level: crit ? 2 : 1, n: crit || warn, detail: why ? [...detail, why] : detail,
            text: m.value != null ? `${String(m.value)} ${word}${late}` : late ? `${crit || warn} ${word}${late}` : undefined };
        } else if (state === 'n/a') out[g.key] = none('n/a', 'the collections of this group do not run on this kind of server');
        else if (state === 'failed') out[g.key] = none('read failed', why);
        else if (state === 'stale') out[g.key] = none('stale', why);
        else if (!m.sampled) out[g.key] = none('not read', detail[0] ?? 'this part was not readable with the login\'s rights');
        else out[g.key] = { level: 0, n: 0, detail, ...(m.value != null ? { text: String(m.value) } : {}) };
      }
      continue;
    }
    if (g.key === 'audit') {
      const a = auditFleetCell(f.pgaudit.find(x => Number(x.instance_id) === id), f.pgauditFailed);
      out[g.key] = { level: a.level, n: a.level ? 1 : 0, detail: a.detail, none: a.none, text: a.text };
      continue;
    }
    if (g.mssqlOnly) { out[g.key] = { level: 0, n: 0, detail: ['a SQL Server check: nothing is read for it on PostgreSQL'], none: true, text: 'n/a' }; continue; }
    // Uptime on PostgreSQL: the postmaster's start from the instance row, judged by the 'uptime' check rows (task 162:
    // the thresholds in force, DBA Dash's defaults of critical under 12 hours and warning under 48 until one is set)
    if (g.key === 'uptime') {
      const t = r.postmaster_start == null ? NaN : Date.parse(String(r.postmaster_start));
      if (isNaN(t)) { out[g.key] = { level: 0, n: 0, detail: ['no start time read yet'], none: true }; continue; }
      const up = mine.filter(c => c.check_group === 'uptime');
      const h = Math.max(0, (Date.now() - t) / 3600000), level = up.reduce<Level>((a, c) => Math.max(a, sevLevel(c.severity)) as Level, 0);
      const age = h < 48 ? `${Math.floor(h)} h` : `${Math.floor(h / 24)} d`;
      out[g.key] = { level, n: level ? 1 : 0, text: level ? `${age} ${level === 2 ? 'critical' : 'warning'}` : age,
        detail: up.length ? up.map(c => String(c.detail ?? '')) : [`PostgreSQL started ${new Date(t).toISOString().slice(0, 16).replace('T', ' ')} UTC (within the uptime thresholds: the Thresholds page)`] };
      continue;
    }
    // Database state on PostgreSQL: an invalid database is critical, one that refuses connections a warning
    if (g.key === 'dbstate') {
      const d = f.pgdb.find(x => Number(x.instance_id) === id);
      if (!d) { out[g.key] = f.mssqlFailed ? { level: 0, n: 0, detail: ['the read of the database states failed (GET /api/mssql/summary)'], none: true, text: 'read failed' } : { level: 0, n: 0, detail: ['no database inventory read yet (hourly)'], none: true }; continue; }
      const crit = Number(d.critical ?? 0), warn = Number(d.warning ?? 0);
      out[g.key] = { level: crit ? 2 : warn ? 1 : 0, n: crit || warn, detail: Array.isArray(d.detail) ? d.detail.map(String) : [] };
      continue;
    }
    if (g.key === 'activity') { out[g.key] = activityCell(r); continue; }
    if (g.key === 'version') { out[g.key] = versionCellOf(f, id); continue; }
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
export const cellText = (c: Cell) => c.none ? c.text ?? 'no sample' : c.text ?? (c.level === 0 ? 'OK' : `${c.n} ${c.level === 2 ? 'critical' : 'warning'}`);

export function tagsOf(r: Row): string[] {
  const t = r.tags;
  return Array.isArray(t) && t.length ? t.map(String) : [];
}
