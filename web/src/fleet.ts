// The fleet's instances and daily-check rows, shared by the tree, the Summary grid and the checks page,
// fetched at most once per 25 s unless a refresh forces it.
import { get, Row, rowsOf, Table } from './api';
import { auditFleetCell, readAuditFleet } from './pgaudit';
import { versionCell } from './versions';

// mssql: the SQL Server instances' status cells (one row per instance and group) and their descriptions
// mssqlFailed: the SQL Server read itself failed (its cells then say so, never 'not yet')
// pgaudit: the PostgreSQL instances' pgaudit cells (readAuditFleet); pgauditFailed: that read failed
// collect: every instance's collection ages and errors (Snapshot Age, Collection Errors (24hrs)); roots: the root's uptime
// and memory dump thresholds (the Summary's Options dialogs)
export interface Fleet { instances: Row[]; checks: Row[]; versions: Row[]; mssql: Row[]; mssqlServers: Row[]; pgdb: Row[]; collect: Row[]; roots: Row[]; mssqlFailed: boolean; pgaudit: Row[]; pgauditFailed: boolean; at: number }
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
    get<{ cells: Table | null; servers: Table | null; pgdb: Table | null; collect: Table | null; roots: Table | null; failed?: boolean }>('mssql/summary', {})
      .catch(() => ({ cells: null, servers: null, pgdb: null, collect: null, roots: null, failed: true })),
    auditRead()])
    .then(([i, c, v, m, a]) => (cache = { instances: rowsOf(i), checks: rowsOf(c), versions: rowsOf(v.fleet), mssql: rowsOf(m.cells), mssqlServers: rowsOf(m.servers), pgdb: rowsOf(m.pgdb), collect: rowsOf(m.collect), roots: rowsOf(m.roots), mssqlFailed: m.failed === true, pgaudit: a.rows, pgauditFailed: a.failed, at: Date.now() }))
    .finally(() => { pending = null; });
  return pending;
}

export function forget() { cache = null; }

// Status groups: one coloured cell each on the Summary grid. A group's checks are the overview's
// check_group names (names: only the check names it keeps of them); activity is read from the instance row's latest
// session summary.
// mssql: the group's key in the SQL Server read (/api/mssql/summary), the SQL Server tab its cell opens, the group's
// name on a SQL Server page, and the view (cv) of that tab; a group without it is a PostgreSQL check.
// dd: one of DBA Dash's Summary tests (task P08: its name, its column order, Checks/Summary.Designer.cs); the others are
// pgvigil's own, after them. plain: DBA Dash's cell is text, not a link (Memory Dump, Is Agent Running, DB Mail).
// both: read for either engine from the collect part (Snapshot Age, Collection Errors (24hrs)).
export interface Group { key: string; label: string; checks: string[]; tab: string; kind?: string; mssql?: [string, string, string?, string?]; mssqlOnly?: boolean; names?: (checkName: string, checkGroup: string) => boolean; dd?: boolean; plain?: boolean; both?: boolean; cv?: string }   // kind: the Metrics family a PostgreSQL cell opens; cv: the view of a PostgreSQL tab
// PostgreSQL's Backup FULL takes the base backups and the managed service's snapshots and retention (0103 names the
// retention row by its threshold: 'retention under <n> days', 'retention at or under <n> days'); Backup LOG the
// archiver (WAL)
const fullBackupCheck = (n: string) => n.startsWith('retention ') || n === 'no snapshot in 24 h';
export const groups: Group[] = [
  // DBA Dash's Summary tests in its column order (Instance, then MemoryDumpStatus ... UptimeStatus)
  { key: 'dumps', label: 'Memory Dump', checks: ['crashes'], tab: 'pgstate', mssql: ['dumps', 'summary', 'Memory dumps'], dd: true, plain: true },
  { key: 'corruption', label: 'Corruption', checks: ['corruption'], tab: 'corruption', mssql: ['corruption', 'mssqlchecks', 'Suspect pages', 'build'], dd: true },
  { key: 'checkdb', label: 'Last Good Check DB', checks: ['amcheck age'], tab: 'corruption', mssql: ['checkdb', 'mssqlchecks', 'Last good CHECKDB', 'databases'], dd: true },
  { key: 'alerts', label: 'SQL Agent Alerts', checks: [], tab: 'summary', mssql: ['alerts', 'mssqlchecks', 'Agent alerts', 'alerts'], mssqlOnly: true, dd: true },
  { key: 'full', label: 'Backup FULL', checks: ['base backups', 'backups'], names: (n, grp) => grp === 'base backups' || fullBackupCheck(n), tab: 'backups', mssql: ['full', 'mssqlbackups', 'Full backups'], dd: true },
  { key: 'diff', label: 'Backup DIFF', checks: [], tab: 'summary', mssql: ['diff', 'mssqlbackups', 'Differential backups'], mssqlOnly: true, dd: true },
  { key: 'log', label: 'Backup LOG', checks: ['backups'], names: n => !fullBackupCheck(n), tab: 'backups', mssql: ['log', 'mssqlbackups', 'Log backups'], dd: true },
  { key: 'disk', label: 'Drive Space', checks: ['disk', 'storage'], tab: 'drives', mssql: ['disk', 'drives', 'Drive space'], dd: true },
  { key: 'jobs', label: 'Agent Jobs', checks: ['jobs', 'jobs report'], tab: 'jobsreport', mssql: ['jobs', 'mssqljobs'], dd: true },
  { key: 'agent', label: 'Is Agent Running', checks: [], tab: 'summary', mssql: ['agent', 'mssqljobs', 'SQL Server Agent'], mssqlOnly: true, dd: true, plain: true },
  { key: 'logship', label: 'Log Shipping', checks: ['log shipping'], tab: 'pgbackups', mssql: ['logship', 'availability', 'Log shipping'], dd: true },
  { key: 'mirroring', label: 'Mirroring', checks: [], tab: 'summary', mssql: ['mirroring', 'availability', 'Mirroring'], mssqlOnly: true, dd: true },
  { key: 'replication', label: 'Availability Groups', checks: ['replication'], tab: 'replication', mssql: ['availability', 'availability', 'Availability'], dd: true },
  { key: 'logspace', label: 'Log Space', checks: [], tab: 'summary', mssql: ['logspace', 'dbfiles', 'Log space'], mssqlOnly: true, dd: true },
  { key: 'filespace', label: 'File Space', checks: [], tab: 'summary', mssql: ['filespace', 'dbfiles', 'File space'], mssqlOnly: true, dd: true },
  { key: 'pctmax', label: '% Max Size', checks: [], tab: 'summary', mssql: ['pctmax', 'dbfiles', 'Files at their max size'], mssqlOnly: true, dd: true },
  // Azure SQL Database's elastic pools and Service Broker: pgvigil reads neither yet, so both stay N/A and hidden
  { key: 'elasticpool', label: 'Elastic Pool Storage', checks: [], tab: 'summary', mssqlOnly: true, dd: true },
  { key: 'qs', label: 'QS', checks: ['statement store'], tab: 'pgstate', mssql: ['qs', 'mssqlqs', 'Query Store'], dd: true },
  { key: 'custom', label: 'Custom Checks', checks: ['custom'], tab: 'custom', dd: true },
  { key: 'errors', label: 'Collection Errors (24hrs)', checks: ['collection failing'], tab: 'collectiondates', mssql: ['errors', 'collectiondates', 'Collection errors'], dd: true, both: true },
  { key: 'snapshot', label: 'Snapshot Age', checks: ['collection stale'], tab: 'collectiondates', mssql: ['snapshot', 'collectiondates', 'Collection'], dd: true, both: true },
  { key: 'dbmail', label: 'DB Mail', checks: [], tab: 'summary', mssql: ['dbmail', 'summary', 'Database Mail'], mssqlOnly: true, dd: true, plain: true },
  { key: 'identity', label: 'Identity Columns', checks: [], tab: 'summary', mssql: ['identity', 'mssqlchecks', 'Identity columns', 'identity'], mssqlOnly: true, dd: true },
  { key: 'dbstate', label: 'Database State', checks: [], tab: 'pgdboptions', mssql: ['dbstate', 'mssqlchecks', 'Database state', 'databases'], dd: true },
  { key: 'servicebroker', label: 'Service Broker', checks: [], tab: 'summary', mssqlOnly: true, dd: true },
  { key: 'uptime', label: 'Instance Uptime', checks: ['uptime'], tab: 'pgstate', mssql: ['uptime', 'summary'], dd: true },
  // pgvigil's own, after DBA Dash's (PostgreSQL's checks DBA Dash has no column for, and the two both engines share)
  { key: 'activity', label: 'Activity', checks: [], tab: 'activity', mssql: ['blocking', 'mssql_running', 'Blocking'] },
  { key: 'dbhealth', label: 'Deadlocks / checksums', checks: ['deadlocks and checksums'], tab: 'counters', kind: 'database', mssql: ['events', 'mssql_deadlocks', 'Deadlocks and blocked reports'] },
  { key: 'audit', label: 'Audit', checks: [], tab: 'audit', mssql: ['audit', 'mssqlaudit', 'SQL Server Audit'] },
  { key: 'dms', label: 'DMS', checks: ['dms'], tab: 'dms' },
  { key: 'tables', label: 'Tables', checks: ['tables'], tab: 'tables' },
  { key: 'vacuum', label: 'Vacuum', checks: ['vacuum'], tab: 'vacuum' },
  { key: 'host', label: 'Host', checks: ['host', 'pi'], tab: 'host' },   // 'pi': cache starved by the ACU floor (the Capacity section sits on the Host tab)
  { key: 'io', label: 'IO', checks: ['io'], tab: 'io' },
  { key: 'roles', label: 'Roles', checks: ['roles'], tab: 'roles' },
  { key: 'indexes', label: 'Indexes', checks: ['indexes'], tab: 'indexes' },
  { key: 'version', label: 'Version', checks: [], tab: 'versions' },   // from the versions fleet read, not a check group
];

// checkLabel: a daily check's name as the UI shows it. 0033's 'volume under 10 % free' is shown as 'capacity headroom
// under 10 %' everywhere (the Storage pages' word for it, task 176b); the key stays for alert rules and acknowledgements.
export const checkLabel = (name: unknown): string => String(name ?? '') === 'volume under 10 % free' ? 'capacity headroom under 10 %' : String(name ?? '');

export type Level = 0 | 1 | 2;   // ok, warning, critical
// none = no data to judge; text overrides the OK / n warning reading; since and value: what DBA Dash's cell text is made
// of (summaryText): the time it counts from (a start, the newest dump, the oldest CHECKDB ...) and the read's own word
export interface Cell { level: Level; n: number; detail: string[]; none?: boolean; text?: string; since?: unknown; value?: string }

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

// collectCell: Snapshot Age and Collection Errors (24hrs) of an instance of either engine, from the collect part:
// Snapshot Age is a warning while a collection is stale (older than three of its intervals: the daily check
// 'collection stale'), its text the youngest to the oldest last run (DBA Dash's 'x minutes to y minutes'); Collection
// Errors is critical while a collection's last run failed, a warning for an error in the last 24 hours, its text that
// count (DBA Dash's CollectionErrorStatus: retries warning, failures critical)
function collectCell(f: Fleet, id: number, key: string): Cell {
  const x = f.collect.find(c => Number(c.instance_id) === id);
  if (!x) return f.mssqlFailed ? { level: 0, n: 0, detail: ['the read of the collection dates failed (GET /api/mssql/summary)'], none: true, text: 'read failed' }
    : { level: 0, n: 0, detail: ['no collection has run for this instance yet'], none: true, text: 'not yet' };
  const lines = Array.isArray(x.detail) ? x.detail.map(String) : [];
  if (key === 'errors') {
    const failing = Number(x.failing ?? 0), e24 = Number(x.errors_24h ?? 0);
    const detail = [...lines.filter(l => l.endsWith('the last run failed')), `${e24} collection error(s) in the last 24 hours`];
    return { level: failing ? 2 : e24 ? 1 : 0, n: failing || e24, detail, value: String(e24) };
  }
  if (x.age_min_secs == null) return { level: 0, n: 0, detail: ['no collection has run for this instance yet'], none: true, text: 'not yet' };
  const stale = Number(x.stale ?? 0);
  const lo = humanize(Number(x.age_min_secs), 1, 'minute', 'year'), hi = humanize(Number(x.age_max_secs), 1, 'minute', 'year');
  return { level: stale ? 1 : 0, n: stale, value: lo === hi ? hi : `${lo} to ${hi}`,
    detail: stale ? lines.filter(l => !l.endsWith('the last run failed')) : [`the youngest collection ran ${lo} ago, the oldest ${hi} ago`] };
}

// humanize: a time span in DBA Dash's words (Humanizer's TimeSpan.Humanize: the largest units first, weeks at most unless
// maxUnit says year, 'precision' units that are not zero, '1 day, 14 hours'); zero reads '0 <the smallest unit>s'.
// Humanizer's year is 365 days and its month 365.2425 / 12.
const units: [string, number][] = [['year', 31536000], ['month', 2629746], ['week', 604800], ['day', 86400], ['hour', 3600], ['minute', 60], ['second', 1]];
export function humanize(secs: number, precision = 1, minUnit: 'second' | 'minute' | 'day' = 'second', maxUnit: 'week' | 'year' = 'week'): string {
  if (!isFinite(secs)) return '';
  let left = Math.max(0, Math.floor(secs));
  const out: string[] = [];
  for (const [name, size] of units.slice(maxUnit === 'year' ? 0 : 2)) {
    const n = Math.floor(left / size);
    left -= n * size;
    if (n > 0 && out.length < precision) out.push(`${n} ${name}${n === 1 ? '' : 's'}`);
    if (name === minUnit) break;
  }
  return out.length ? out.join(', ') : `0 ${minUnit}s`;
}
// sinceState: the state an Instance Uptime or a Memory Dump acknowledgement holds for (until it changes): the start or
// the newest dump as a time, whatever the JSON spelling of it
export const sinceState = (v: unknown): string => `since ${Date.parse(String(v))}`;
const since = (v: unknown): number => v == null ? NaN : (Date.now() - Date.parse(String(v))) / 1000;
// midnights: the days between a time and now as DATEDIFF(d) counts them (date boundaries, here in UTC)
const midnights = (v: unknown): number => { const d = new Date(String(v)), n = new Date(); return Math.round((Date.UTC(n.getUTCFullYear(), n.getUTCMonth(), n.getUTCDate()) - Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())) / 86400000); };

// summaryText: the text DBA Dash's Summary cell shows (Checks/Summary.cs DgvSummary_RowAdded) and whether it is a link:
// 'View' on the columns that open a page, the age it counts (the uptime '1 day, 14 hours', the time since the newest
// dump or corruption, 'N days' since the oldest good CHECKDB or 'Never', the last alert 'Nhrs' / 'N days' or 'Never'),
// the error count, the snapshot ages; nothing where DBA Dash shows nothing (a green Is Agent Running, DB Mail). A
// cell without a read keeps pgvigil's word for it ('not yet', 'read failed', 'stale'), and a column the engine does
// not have is empty.
export function summaryText(g: Group, c: Cell, r: Row, all: Record<string, Cell>): { text: string; link: boolean } {
  const out = (text: string) => ({ text, link: !g.plain && text !== '' });
  if (c.none) return out(c.text === 'n/a' ? '' : c.text ?? 'no sample');
  const ms = r.engine === 'sqlserver';
  switch (g.key) {
    case 'dumps': return out(c.since == null ? '' : humanize(since(c.since)));
    case 'corruption': return out(ms ? (c.since == null ? '' : humanize(since(c.since))) : c.level ? cellText(c) : '');
    case 'checkdb':
      if (!ms) return out(c.level ? cellText(c) : 'View');
      return out(c.value === 'Never' ? 'Never' : c.since == null ? '' : `${midnights(c.since)} days`);
    case 'alerts': {
      if (c.since == null) return out('Never');
      const s = since(c.since);
      return out(s < 86400 ? `${Math.round(s / 3600)}hrs` : `${Math.round(s / 86400)} days`);
    }
    case 'jobs': return out(ms && all.agent && !all.agent.none && all.agent.level > 0 ? 'Not Running' : 'View');
    case 'agent': case 'dbmail': return out(c.level ? c.value ?? cellText(c) : '');
    case 'identity': {
      // '<per cent>|<days left>': DBA Dash's 'P1 / the days humanized from a day to a year' ('42.5% / 3 months')
      const [pct, days] = (c.value ?? '').split('|');
      return out(c.value == null ? '' : [pct ? `${pct}%` : '', days ? humanize(Number(days) * 86400, 1, 'day', 'year') : ''].filter(Boolean).join(' / '));
    }
    case 'errors': case 'snapshot': return out(c.value ?? cellText(c));
    case 'uptime': { const s = since(c.since); return out(isNaN(s) ? cellText(c) : humanize(s, 2)); }
    default: return out(g.dd ? 'View' : cellText(c));
  }
}

export function cells(f: Fleet, r: Row): Record<string, Cell> {
  const id = Number(r.instance_id);
  const mine = f.checks.filter(c => Number(c.instance_id) === id);
  const out: Record<string, Cell> = {};
  // Snapshot Age and Collection Errors are read alike for both engines (collectCell); on a SQL Server instance a group
  // with a SQL Server read takes its cell from that read (no stored read of the group yet = 'not yet', never OK); a
  // PostgreSQL-only group says so
  const otherEngine = r.engine != null && r.engine !== 'postgres';
  for (const g of groups) {
    if (g.both) { out[g.key] = collectCell(f, id, g.key); continue; }
    if (otherEngine) {
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
          out[g.key].since = m.since; out[g.key].value = m.value == null ? undefined : String(m.value);
        } else if (state === 'n/a') out[g.key] = none('n/a', 'the collections of this group do not run on this kind of server');
        else if (state === 'failed') out[g.key] = none('read failed', why);
        else if (state === 'stale') out[g.key] = none('stale', why);
        else if (!m.sampled) out[g.key] = none('not read', detail[0] ?? 'this part was not readable with the login\'s rights');
        else out[g.key] = { level: 0, n: 0, detail, since: m.since, ...(m.value != null ? { text: String(m.value), value: String(m.value) } : {}) };
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
      out[g.key] = { level, n: level ? 1 : 0, text: level ? `${age} ${level === 2 ? 'critical' : 'warning'}` : age, since: r.postmaster_start,
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
    const hit = mine.filter(c => g.checks.includes(String(c.check_group)) && (!g.names || g.names(String(c.check_name ?? ''), String(c.check_group))));
    // Host and Disk read "no sample" on an instance the host collection has never reached (no system_stats, no
    // CloudWatch door: Azure, Cloud SQL): an empty check list there is not OK
    if ((g.key === 'host' || g.key === 'disk') && r.host_at == null && hit.length === 0) {
      out[g.key] = { level: 0, n: 0, detail: ['no host sample yet'], none: true };
      continue;
    }
    out[g.key] = {
      level: hit.reduce<Level>((a, c) => Math.max(a, sevLevel(c.severity)) as Level, 0),
      n: hit.length,
      // Memory Dump on PostgreSQL: the newest crash restart's time (the 'crashes' rows' at), what its text counts from
      // and what its acknowledgement holds for
      ...(g.key === 'dumps' && hit.length ? { since: hit.map(c => String(c.at ?? '')).filter(Boolean).sort().pop() } : {}),
      detail: hit.map(c => `${checkLabel(c.check_name)}: ${c.object ?? ''} ${c.detail ?? ''}`.trim()),
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
