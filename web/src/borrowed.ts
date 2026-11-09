// The views borrowed from the DBA toolkits (task 21): Tables, Findings, the Statements sort and the slow
// executions of a window, and the DMS drain readout. Each takes the instance it shows (Findings: none =
// the fleet) and reads the API itself, so the shell only mounts it in a tab; the time range comes from
// the shell (pages.ts hands it over).
import { get, Row, rowsOf, Table } from './api';
import { badge, Col, el, fmtBytes, fmtNum, fmtSecs, fmtTime, grid } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const never = (v: unknown) => v == null ? 'never' : fmtTime(v);
const trunc = (v: unknown) => { const s = v == null ? '' : String(v); return s.length > 400 ? s.slice(0, 400) + '...' : s; };

// ---- Tables ---------------------------------------------------------------------------------------------

export async function tablesView(instance: number): Promise<HTMLElement> {
  const d = await get<{ databases: Table | null; tables: Table | null }>('tables', { instance });
  const dbs = rowsOf(d.databases), tabs = rowsOf(d.tables);
  const dbCols: Col[] = [
    { key: 'datname', label: 'database' },
    { key: 'user_tables', label: 'user tables', num: true },
    { key: 'never_vacuumed', label: 'never vacuumed', num: true },
    { key: 'never_analyzed', label: 'never analyzed', num: true },
    { key: 'big_tables', label: 'tables of 8 MB+', num: true },
    { key: 'big_never_vacuumed', label: '8 MB+ never vacuumed', num: true },
    { key: 'big_under_half_visible', label: '8 MB+ under half all-visible', num: true },
    { key: 'big_visible_pct', label: 'all-visible (8 MB+)', num: true, fmt: pct },
    { key: 'stats_reset', label: 'statistics since', fmt: v => v == null ? 'server start' : fmtTime(v) },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ];
  const tCols: Col[] = [
    { key: 'checks', fmt: v => v ? badge(String(v), 'warn') : '' },
    { key: 'datname', label: 'db' },
    { key: 'schema_name', label: 'schema' },
    { key: 'table_name', label: 'table' },
    { key: 'total_bytes', label: 'total', num: true, fmt: fmtBytes },
    { key: 'heap_bytes', label: 'heap', num: true, fmt: fmtBytes },
    { key: 'toast_bytes', label: 'TOAST', num: true, fmt: fmtBytes },
    { key: 'index_bytes', label: 'indexes', num: true, fmt: fmtBytes },
    { key: 'n_live_tup', label: 'live rows', num: true },
    { key: 'n_dead_tup', label: 'dead rows', num: true },
    { key: 'dead_pct', label: 'dead', num: true, fmt: pct },
    { key: 'all_visible_pct', label: 'all-visible', num: true, fmt: pct },
    { key: 'bloat_pct', label: 'bloat', num: true, fmt: (v, r) => r.stats_readable === false ? 'no access' : pct(v) },
    { key: 'bloat_bytes', label: 'bloat size', num: true, fmt: fmtBytes },
    { key: 'last_vacuum', label: 'last vacuum', fmt: never },
    { key: 'last_analyze', label: 'last analyze', fmt: never },
    { key: 'n_mod_since_analyze', label: 'changed since analyze', num: true },
    { key: 'xid_age', label: 'xid age', num: true },
    { key: 'seq_scan', label: 'seq scans', num: true },
    { key: 'idx_scan', label: 'index scans', num: true },
    { key: 'autovacuum_off', label: 'autovacuum', fmt: v => v ? badge('off', 'warn') : 'on' },
  ];
  return el('section', {}, el('h2', {}, 'Tables'),
    el('p', { class: 'meta' }, 'The biggest tables of each database, read hourly. "Never" means no vacuum or analyze recorded since the statistics reset.'),
    grid(dbs, dbCols, 'No table read yet: the tables collection runs hourly.'),
    el('h3', {}, 'Biggest tables'),
    grid(tabs, tCols, 'No tables yet.'));
}

// ---- Findings -------------------------------------------------------------------------------------------

// findingsView: one instance's findings, or the fleet's (keep narrows the fleet to a tag folder; instLink
// turns the instance name into a link to that instance's Findings tab).
export async function findingsView(instance?: number, keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  let rows = rowsOf(await get('findings', { instance }));
  if (keep) rows = rows.filter(keep);
  const crit = rows.filter(r => r.severity === 'critical').length, warn = rows.filter(r => r.severity === 'warning').length;
  const cols: Col[] = [
    { key: 'severity', fmt: sevBadge },
    ...(instance ? [] : [{ key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') } as Col, { key: 'platform' } as Col]),
    { key: 'setting' },
    { key: 'value', fmt: (v, r) => r.is_set ? String(v ?? '') : String(v ?? '') + ' (default)' },
    { key: 'suggested' },
    { key: 'detail', wide: true },
    { key: 'platforms', label: 'applies to' },
    { key: 'source' },
  ];
  return el('section', {}, el('h2', {}, 'Findings'),
    el('p', { class: 'meta' }, `${crit} critical, ${warn} warning, ${rows.length - crit - warn} advice. Parameters off their recommended range for the platform, from the latest settings read.`),
    grid(rows, cols, 'No findings: every checked parameter is in its recommended range.'));
}

// ---- Statements: the sorts top_statements_by knows and the slow executions of a window -----------------

export const statementOrders: [string, string][] = [['time', 'total time'], ['calls', 'calls'], ['io', 'IO'], ['mean', 'mean time'], ['rows', 'rows'], ['temp', 'temp'], ['wal', 'WAL']];

export function stmtCols(order: string): Col[] {
  const lead: Record<string, Col> = {
    time: { key: 'total_exec_ms', label: 'total ms', num: true },
    calls: { key: 'calls', num: true },
    io: { key: 'io_blks', label: 'IO blocks', num: true },
    mean: { key: 'mean_exec_ms', label: 'mean ms', num: true },
    rows: { key: 'rows', num: true },
    temp: { key: 'temp_blks_written', label: 'temp blks written', num: true },
    wal: { key: 'wal_bytes', label: 'WAL', num: true, fmt: fmtBytes },
  };
  const rest: Col[] = [
    { key: 'total_exec_ms', label: 'total ms', num: true }, { key: 'calls', num: true }, { key: 'mean_exec_ms', label: 'mean ms', num: true },
    { key: 'rows', num: true }, { key: 'io_blks', label: 'IO blocks', num: true }, { key: 'shared_blks_read', label: 'blks read', num: true },
    { key: 'hit_pct', label: 'hit', num: true, fmt: pct }, { key: 'temp_blks_written', label: 'temp blks written', num: true },
    { key: 'wal_bytes', label: 'WAL', num: true, fmt: fmtBytes },
  ].filter(c => c.key !== (lead[order] ?? lead.time).key);
  return [lead[order] ?? lead.time, ...rest, { key: 'datname', label: 'db' }, { key: 'usename', label: 'user' },
    { key: 'queryid' }, { key: 'query', wide: true, fmt: trunc }];
}

export const slowCols: Col[] = [
  { key: 'at_least_secs', label: 'at least', num: true, fmt: fmtSecs },
  { key: 'state' },
  { key: 'top_wait', label: 'mostly' },
  { key: 'was_blocked', label: 'blocked', fmt: v => v ? badge('blocked', 'warn') : '' },
  { key: 'was_blocker', label: 'blocker', fmt: v => v ? badge('blocker', 'crit') : '' },
  { key: 'first_seen', label: 'first seen', fmt: fmtTime },
  { key: 'last_seen', label: 'last seen', fmt: fmtTime },
  { key: 'pid', num: true },
  { key: 'datname', label: 'db' },
  { key: 'usename', label: 'user' },
  { key: 'application_name', label: 'application' },
  { key: 'query', wide: true, fmt: trunc },
];

// ---- DMS drain ------------------------------------------------------------------------------------------

// dmsDrainView renders the drain readout rows the /api/dms reply carries under "drain" (the caller scopes
// them to the tag folder like the task rows).
export function dmsDrainView(rows: Row[]): HTMLElement {
  const eta = (v: unknown, r: Row) => v != null ? fmtSecs(v)
    : Number(r.latency_target_s ?? 0) > 0 && r.speed_x != null ? 'not draining' : '';
  const cols: Col[] = [
    { key: 'instance' },
    { key: 'task_id', label: 'task' },
    { key: 'status' },
    { key: 'latency_target_s', label: 'behind', num: true, fmt: fmtSecs },
    { key: 'reader_at', label: 'reader at', fmt: fmtTime },
    { key: 'speed_x', label: 'speed', num: true, fmt: v => v == null ? '' : fmtNum(v) + 'x' },
    { key: 'eta_secs', label: 'caught up in', num: true, fmt: eta },
    { key: 'rows_behind', label: 'rows behind', num: true },
    { key: 'rows_in_s', label: 'rows in / s', num: true },
    { key: 'rows_out_s', label: 'rows out / s', num: true },
    { key: 'eta_rows_secs', label: 'rows drained in', num: true, fmt: v => v == null ? '' : fmtSecs(v) },
    { key: 'spilling', label: 'spill', fmt: (v, r) => v ? badge(`disk ${fmtNum(r.disk_source)} / ${fmtNum(r.disk_target)}`, 'warn') : 'none' },
    { key: 'validated', label: 'validated', num: true },
    { key: 'pending', label: 'pending', num: true },
    { key: 'failed', label: 'failed', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : fmtNum(v) },
    { key: 'suspended', label: 'suspended', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : fmtNum(v) },
    { key: 'pending_records', label: 'records pending', num: true },
  ];
  return el('div', {}, el('h3', {}, 'Drain and validation'),
    el('p', { class: 'meta' }, 'Speed compares the target latency with the sample 10-30 minutes older (1x = keeping pace). Do not stop or restart a task while it spills to disk.'),
    grid(rows, cols, 'No running tasks.'));
}
