// The Vacuum tab of one instance: the autovacuum state, its checks, what vacuums now, the tables over or
// near their thresholds, the never or long unvacuumed ones, wraparound per database, who holds the xmin
// horizon back, and the vacuum runs of the window (at least the last 7 days). The shell mounts it as
// vacuumView(ctx) (the lead wires the route and the tab).
import { get, Row, rowsOf, Table } from './api';
import { Ctx, window_ } from './router';
import { badge, Col, el, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

type Parts = 'state' | 'checks' | 'running' | 'tables' | 'wraparound' | 'holders' | 'history';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const never = (v: unknown) => v == null ? 'never' : fmtTime(v);
const yes = (v: unknown, kind = 'warn') => v ? badge('yes', kind) : '';
const ratio = (v: unknown) => v == null ? '' : fmtNum(v) + 'x';
const ratioCls = (v: unknown) => Number(v) >= 1 ? 'warn' : '';
const weekMs = 7 * 24 * 3600 * 1000;

export async function vacuumView(ctx: Ctx): Promise<HTMLElement> {
  const w = window_(ctx);
  const d = await get<Record<Parts, Table | null>>('vacuum', { instance: ctx.instance, ...w });
  const st = rowsOf(d.state)[0] as Row | undefined;
  const checks = rowsOf(d.checks), running = rowsOf(d.running), tables = rowsOf(d.tables);
  const wrap = rowsOf(d.wraparound), holders = rowsOf(d.holders), history = rowsOf(d.history);

  const sec = el('section', {}, el('h2', {}, 'Vacuum'));
  if (!st) {
    sec.append(el('p', { class: 'empty' }, 'No vacuum read yet: the vacuum collection runs every minute, vacuum_tables hourly (PostgreSQL 13 or later, primaries only).'));
    return sec;
  }
  const stale = Number(st.read_secs_ago) > 600;
  const over = tables.filter(r => r.over_vacuum || r.over_insert);
  const maxWrap = wrap.reduce((m, r) => Math.max(m, Number(r.xid_freeze_pct ?? 0)), 0);
  sec.append(el('div', { class: 'tiles' },
    tile('autovacuum', String(st.autovacuum ?? '?'), st.autovacuum === 'on' ? '' : 'crit'),
    tile('workers running', `${fmtNum(st.workers_running)} of ${fmtNum(st.max_workers)}`,
      Number(st.workers_running) >= Number(st.max_workers) && Number(st.max_workers) > 0 ? 'warn' : ''),
    tile('vacuums / analyzes now', `${fmtNum(st.vacuums_running)} / ${fmtNum(st.analyzes_running)}`),
    tile('tables over threshold', fmtNum(over.length), over.length ? 'warn' : ''),
    tile('oldest database, % of freeze max', fmtNum(maxWrap) + ' %', maxWrap > 50 ? 'warn' : ''),
    tile('checks', fmtNum(checks.length), checks.some(c => c.severity === 'critical') ? 'crit' : checks.length ? 'warn' : '')));
  sec.append(el('p', { class: 'meta' },
    `Minute read ${fmtTime(st.snapshot_at)}${stale ? ' (over 10 minutes old: "running now" is empty)' : ''}; settings and tables read hourly, last ${st.settings_at ? fmtTime(st.settings_at) : 'never'}. `
    + `Thresholds: vacuum ${fmtNum(st.vacuum_threshold)} + ${fmtNum(st.vacuum_scale_factor)} x rows`
    + (st.vacuum_max_threshold != null && Number(st.vacuum_max_threshold) >= 0 ? ` (at most ${fmtNum(st.vacuum_max_threshold)})` : '')
    + (st.insert_threshold != null ? `, insert ${Number(st.insert_threshold) < 0 ? 'off' : fmtNum(st.insert_threshold) + ' + ' + fmtNum(st.insert_scale_factor) + ' x rows'}` : '')
    + `, analyze ${fmtNum(st.analyze_threshold)} + ${fmtNum(st.analyze_scale_factor)} x rows; freeze max age ${fmtNum(st.freeze_max_age)}; `
    + `cost limit ${fmtNum(st.cost_limit)}, delay ${fmtNum(st.cost_delay_ms)} ms; naptime ${fmtSecs(st.naptime_secs)}; `
    + (Number(st.log_min_duration_ms) < 0 ? 'autovacuum runs are not logged (log_autovacuum_min_duration -1).' : `autovacuum runs over ${fmtNum(st.log_min_duration_ms)} ms are logged.`)));

  if (checks.length) {
    sec.append(el('h3', {}, 'Checks'), grid(checks, [
      { key: 'severity', fmt: sevBadge },
      { key: 'check_name', label: 'check' },
      { key: 'object' },
      { key: 'detail', wide: true },
      { key: 'at', fmt: fmtTime },
    ]));
  }

  sec.append(el('h3', {}, 'Running now'), grid(running, [
    { key: 'kind' },
    { key: 'pid', num: true },
    { key: 'datname', label: 'db' },
    { key: 'table_name', label: 'table' },
    { key: 'is_auto', label: 'by', fmt: v => v ? 'autovacuum' : 'manual' },
    { key: 'is_wraparound', label: 'wraparound', fmt: v => yes(v, 'crit') },
    { key: 'phase', fmt: (v, r) => r.wait_event_type === 'Lock' ? badge(String(v ?? 'waiting for its lock'), 'warn') : String(v ?? '') },
    { key: 'scanned_pct', label: 'heap scanned', num: true, fmt: pct },
    { key: 'heap_blks_total', label: 'heap blocks', num: true },
    { key: 'index_vacuum_count', label: 'index passes', num: true },
    { key: 'dead_tuples', label: 'dead tuples found', num: true },
    { key: 'elapsed_secs', label: 'elapsed', num: true, fmt: fmtSecs, cls: v => Number(v) >= 3600 ? 'warn' : '' },
    { key: 'wait_event', label: 'wait', fmt: (v, r) => v ? `${r.wait_event_type}:${v}` : '' },
    { key: 'blocking_pids', label: 'blocked by', fmt: v => Array.isArray(v) && v.length ? v.join(', ') : '' },
    { key: 'query', wide: true },
  ], stale ? 'The minute read is over 10 minutes old.' : 'Nothing vacuums or analyzes now.'));

  const tCols: Col[] = [
    { key: 'datname', label: 'db' },
    { key: 'schema_name', label: 'schema' },
    { key: 'table_name', label: 'table' },
    { key: 'n_live_tup', label: 'live rows', num: true },
    { key: 'n_dead_tup', label: 'dead rows', num: true },
    { key: 'vac_threshold', label: 'vacuum at', num: true, fmt: v => fmtNum(Math.round(Number(v))) },
    { key: 'dead_ratio', label: 'dead / threshold', num: true, fmt: ratio, cls: ratioCls },
    { key: 'ins_ratio', label: 'inserts / threshold', num: true, fmt: ratio, cls: ratioCls },
    { key: 'anl_ratio', label: 'changes / analyze threshold', num: true, fmt: ratio, cls: ratioCls },
    { key: 'hours_over', label: 'hours over', num: true, cls: v => Number(v) >= 6 ? 'warn' : '' },
    { key: 'autovacuum_enabled', label: 'autovacuum', fmt: (v, r) => v === false ? badge('off', 'warn') : r.has_own_settings ? 'own settings' : 'on' },
    { key: 'last_autovacuum', label: 'last autovacuum', fmt: never },
    { key: 'last_vacuum', label: 'last vacuum', fmt: never },
    { key: 'last_autoanalyze', label: 'last autoanalyze', fmt: never },
    { key: 'freeze_pct', label: 'xid age, % of freeze max', num: true, fmt: pct, cls: v => Number(v) > 50 ? 'warn' : '' },
  ];
  sec.append(el('h3', {}, 'Tables over or near a threshold'),
    el('p', { class: 'meta' }, 'Thresholds as autovacuum computes them: the table\'s own reloptions over the server settings, base + scale factor x reltuples. A ratio of 1x or more is over. Read hourly per database, at most 50 tables per database.'),
    grid(tables.filter(r => Number(r.dead_ratio) >= 0.5 || Number(r.ins_ratio) >= 0.5 || Number(r.anl_ratio) >= 1), tCols, 'No table is over or near a threshold.'));
  const weekAgo = Date.now() - weekMs;
  const unvac = tables.filter(r => r.autovacuum_enabled === false || (r.last_vacuum == null && r.last_autovacuum == null)
    || Date.parse(String(r.last_autovacuum ?? r.last_vacuum ?? '')) < weekAgo);
  sec.append(el('h3', {}, 'Never or long unvacuumed, or autovacuum off'),
    el('p', { class: 'meta' }, '"Never" means no vacuum since the statistics reset; long means over 7 days with dead rows.'),
    grid(unvac, tCols, 'None.'));

  sec.append(el('h3', {}, 'Wraparound'), grid(wrap, [
    { key: 'datname', label: 'database' },
    { key: 'xid_age', label: 'xid age', num: true },
    { key: 'xid_freeze_pct', label: '% of freeze max', num: true, fmt: pct, cls: v => Number(v) > 100 ? 'crit' : Number(v) > 50 ? 'warn' : '' },
    { key: 'mxid_age', label: 'multixact age', num: true },
    { key: 'mxid_freeze_pct', label: '% of mxid freeze max', num: true, fmt: pct, cls: v => Number(v) > 50 ? 'warn' : '' },
    { key: 'xid_horizon_pct', label: '% of 2^31', num: true, fmt: pct },
    { key: 'user_tables', label: 'user tables', num: true },
    { key: 'over_vacuum', label: 'over vacuum threshold', num: true },
    { key: 'over_insert', label: 'over insert threshold', num: true },
    { key: 'over_analyze', label: 'over analyze threshold', num: true },
    { key: 'autovacuum_off', label: 'autovacuum off', num: true },
    { key: 'never_vacuumed', label: 'never vacuumed', num: true },
    { key: 'tables_at', label: 'tables read', fmt: v => v == null ? 'not read' : fmtTime(v) },
  ], 'No wraparound read yet: vacuum_tables runs hourly.'));

  sec.append(el('h3', {}, 'Oldest xmin holders'),
    el('p', { class: 'meta' }, 'What keeps vacuum from removing dead rows: sessions (the latest activity sample), replication slots, prepared transactions, standbys with hot_standby_feedback.'),
    grid(holders, [
      { key: 'holder' },
      { key: 'name' },
      { key: 'datname', label: 'db' },
      { key: 'xmin_age', label: 'xmin age', num: true },
      { key: 'catalog_xmin_age', label: 'catalog xmin age', num: true },
      { key: 'active', fmt: v => v == null ? '' : v ? 'yes' : 'no' },
      { key: 'since', fmt: fmtTime },
      { key: 'detail', wide: true },
    ], 'No xmin holder in the latest reads.'));

  const from = new Date(Math.min(Date.parse(w.from), Date.parse(w.to) - weekMs));
  sec.append(el('h3', {}, 'Vacuum runs'),
    el('p', { class: 'meta' }, `From ${fmtTime(from.toISOString())}: the runs seen in the minute samples (a run shorter than a minute can be missed; elapsed is at least) and, where the server log is read, its "automatic vacuum of table" entries.`),
    grid(history, [
      { key: 'started_at', label: 'started', fmt: fmtTime },
      { key: 'kind' },
      { key: 'datname', label: 'db' },
      { key: 'table_name', label: 'table' },
      { key: 'is_auto', label: 'by', fmt: v => v ? 'autovacuum' : 'manual' },
      { key: 'is_wraparound', label: 'wraparound', fmt: v => yes(v, 'crit') },
      { key: 'elapsed_secs', label: 'elapsed', num: true, fmt: fmtSecs },
      { key: 'last_phase', label: 'last phase' },
      { key: 'heap_blks_scanned', label: 'heap scanned', num: true },
      { key: 'heap_blks_total', label: 'heap blocks', num: true },
      { key: 'dead_tuples', label: 'dead tuples', num: true },
      { key: 'waited_lock', label: 'waited on a lock', fmt: v => yes(v) },
      { key: 'source' },
      { key: 'detail', wide: true },
    ], 'No vacuum run seen in this window.'));
  return sec;
}
