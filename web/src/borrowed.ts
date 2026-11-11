// The views borrowed from the DBA toolkits (task 21): Tables, Findings, the Statements sort and the slow
// executions of a window, and the DMS drain readout. Each takes the instance it shows (Findings: none =
// the fleet) and reads the API itself, so the shell only mounts it in a tab; the time range comes from
// the shell (pages.ts hands it over); Tables also takes the shell's ctx, so a table name links to its page (task 65).
import { tableLink } from './dbinfo';
import type { Ctx } from './router';
import { window_ } from './router';
import { get, Row, rowsOf, Table } from './api';
import { alertCol } from './alerts';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid } from './ui';
import { sqlCell, whatIsThis } from './sqlview';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const never = (v: unknown) => v == null ? 'never' : fmtTime(v);

// unused: no sequential and no index scan of the table since the statistics reset (pghero's UNUSED mark, here on a
// table: it is written or kept, never read). A table without indexes has idx_scan NULL.
export const isUnused = (r: Row) => r.seq_scan != null && Number(r.seq_scan) === 0 && (r.idx_scan == null || Number(r.idx_scan) === 0);
const sizeWithTag = (v: unknown, r: Row) => {
  if (!isUnused(r)) return fmtBytes(v);
  const b = badge('UNUSED', 'warn');
  b.title = 'No sequential or index scan since the statistics reset';
  return el('span', {}, fmtBytes(v), ' ', b);
};

// ---- Tables ---------------------------------------------------------------------------------------------

export async function tablesView(instance: number, ctx?: Ctx): Promise<HTMLElement> {
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
    { key: 'table_name', label: 'table', fmt: (v, r) => ctx ? tableLink(ctx, String(v ?? ''), r.dbid, r.relid) : String(v ?? '') },
    { key: 'total_bytes', label: 'total', num: true, fmt: sizeWithTag },
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
  const unused = tabs.filter(isUnused).length;
  return el('section', {}, el('h2', {}, 'Tables'),
    el('p', { class: 'meta' }, 'The biggest tables of each database, read hourly. "Never" means no vacuum or analyze recorded since the statistics reset.'
      + (unused ? ` ${unused} of them UNUSED: no sequential or index scan since the statistics reset.` : '')),
    grid(dbs, dbCols, 'No table read yet: the tables collection runs hourly.'),
    ctx ? await busiestView(instance, ctx).catch(e => errorBox(e)) : '',
    el('h3', {}, 'Biggest tables'),
    grid(tabs, tCols, 'No tables yet.'));
}

// ---- The busiest tables over the window (pgwatch's Tables Overview) -------------------------------------

const topChoices = [5, 10, 25];

// busiestView: the top N tables by sequential scans, inserts, updates and deletes over the shell's window, from the
// table_activity collection (the read-to-read rises of pg_stat_user_tables, every 5 minutes).
export async function busiestView(instance: number, ctx: Ctx): Promise<HTMLElement> {
  let n = 5;
  try { const v = Number(localStorage.getItem('pgvigil.tablesTopN')); if (topChoices.includes(v)) n = v; } catch { /* private window */ }
  const sel = el('select', { 'aria-label': 'Top N' }, ...topChoices.map(x => el('option', { value: String(x) }, `top ${x}`)));
  sel.value = String(n);
  const body = el('div');
  const name = (v: unknown, r: Row) => {
    const t = `${String(r.schema_name ?? '')}.${String(v ?? '')}`;
    return tableLink(ctx, t, r.dbid, r.relid);
  };
  let seq = 0;
  async function draw() {
    const mine = ++seq, want = n;
    let d: { tables: Table | null; meta: Table | null };
    try { d = await get<{ tables: Table | null; meta: Table | null }>('tables/top', { instance, ...window_(ctx), n: want }); }
    catch (e) { if (mine === seq) body.replaceChildren(errorBox(e)); return; }
    if (mine !== seq) return;   // a newer choice was made while this one loaded
    const rows = rowsOf(d.tables), meta = rowsOf(d.meta)[0] ?? {};
    const part = (title: string, rank: string, lead: Col, extra: Col[]) => {
      const rs = rows.filter(r => r[rank] != null && Number(r[rank]) <= n).sort((a, b) => Number(a[rank]) - Number(b[rank]));
      return el('div', {}, el('h4', {}, title), grid(rs, [{ key: 'datname', label: 'db' }, { key: 'table_name', label: 'table', fmt: name }, lead, ...extra,
        { key: 'first_at', label: 'counted from', fmt: fmtTime }], 'No table moved by this measure in the window.'));
    };
    const pctHot = (v: unknown, r: Row) => Number(r.n_tup_upd) > 0 ? fmtNum(Math.round(1000 * Number(v ?? 0) / Number(r.n_tup_upd)) / 10) + ' %' : '';
    body.replaceChildren(
      el('p', { class: 'meta' }, `Over ${fmtTime(meta.from_at)} to ${fmtTime(meta.to_at)} (at most the last 7 days of the range): the sum of the rises between the table activity reads (every 5 minutes; ${fmtNum(meta.reads)} in the window, the newest `
        + `${fmtTime(meta.last_read) || 'none'}), the read before the window as the base. A table read first inside the window counts from that read (counted from). `
        + 'A statistics reset counts what the counter rose by since it.'),
      el('div', { class: 'top-n' },
        part('Most sequential scans', 'rank_seq', { key: 'seq_scan', label: 'seq scans', num: true },
          [{ key: 'seq_tup_read', label: 'rows read by them', num: true }, { key: 'idx_scan', label: 'index scans', num: true }]),
        part('Most inserts', 'rank_ins', { key: 'n_tup_ins', label: 'rows inserted', num: true }, []),
        part('Most updates', 'rank_upd', { key: 'n_tup_upd', label: 'rows updated', num: true },
          [{ key: 'n_tup_hot_upd', label: 'HOT', num: true, fmt: pctHot }]),
        part('Most deletes', 'rank_del', { key: 'n_tup_del', label: 'rows deleted', num: true }, [])));
  }
  sel.addEventListener('change', () => {
    n = Number(sel.value);
    try { localStorage.setItem('pgvigil.tablesTopN', String(n)); } catch { /* private window */ }
    void draw();
  });
  await draw();
  return el('div', {}, el('h3', {}, 'Busiest tables in the window ', sel), body);
}

// ---- Findings -------------------------------------------------------------------------------------------

// findingsView: one instance's findings, or the fleet's (keep narrows the fleet to a tag folder; instLink
// turns the instance name into a link to that instance's Findings tab).
export async function findingsView(instance?: number, keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  // an instance with no settings read yet has no findings either: the empty text must not call it clean
  const [f, cfg] = await Promise.all([get('findings', { instance }), instance ? get<{ state: Table | null }>('config', { instance }) : Promise.resolve(null)]);
  let rows = rowsOf(f);
  if (keep) rows = rows.filter(keep);
  const noRead = !!instance && rowsOf(cfg?.state).length === 0;
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
    alertCol,
  ];
  return el('section', {}, el('h2', {}, 'Findings'),
    el('p', { class: 'meta' }, `${crit} critical, ${warn} warning, ${rows.length - crit - warn} advice. Parameters off their recommended range for the platform, from the latest settings read.`),
    grid(rows, cols, noRead ? 'No settings read for this instance yet: the instance collection runs hourly.' : 'No findings: every checked parameter is in its recommended range.'));
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
    { key: 'queryid' }, { key: 'query', label: 'statement', fmt: v => sqlCell(v) }];
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
  { key: 'query', label: 'statement', fmt: v => sqlCell(v) },   // one line; a click opens the whole text (sqlview.ts)
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
  return el('div', {}, el('h3', {}, 'Drain and validation ', whatIsThis('Speed compares the target latency with the sample 10-30 minutes older (1x = keeping pace). Do not stop or restart a task while it spills to disk.', 'Drain and validation')),
    grid(rows, cols, 'No running tasks.'));
}
