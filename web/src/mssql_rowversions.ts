// The Row versions tab of a SQL Server instance (task 95's SQL Server side): the tempdb version store's size and its
// generation and cleanup rates over the range, THE HOLDER - the oldest active snapshot transaction, with its session,
// login, program, age and last statement - named beside them, the store per database, and the persistent version
// store of accelerated database recovery. The heading is the one the PostgreSQL side (the xmin horizon and what
// holds it) shares. Data from /api/mssql/rowversions (mssql_versionstore, read every minute).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';

// The tab key of the page and the heading both engines' row versions pages carry.
export const mssqlRowVersionsTab = 'rowversions';
export const rowVersionsHeading = 'Row versions';

type Parts = Record<'latest' | 'series' | 'holders' | 'databases' | 'pvs' | 'checks', Table | null>;

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const kbs = (v: unknown) => v == null ? '' : fmtNum(v) + ' KB/s';
const stmt = (v: unknown) => el('pre', { class: 'sql', style: 'white-space:pre-wrap;margin:0' }, String(v ?? ''));

// numbers: the table behind a chart, folded until asked for.
function numbers(title: string, rows: Row[], cols: Col[]): HTMLElement {
  return el('details', {}, el('summary', {}, `${title}: the numbers`), grid(rows, cols, 'No read in this window.'));
}

// mssqlRowVersionsView is the Row versions tab of a SQL Server instance.
export async function mssqlRowVersionsView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Parts>('mssql/rowversions', { instance: ctx.instance, ...window_(ctx) });
  const l = rowsOf(d.latest)[0], s = rowsOf(d.series), holders = rowsOf(d.holders), checks = rowsOf(d.checks);
  const sec = el('section', {}, el('h2', {}, `${rowVersionsHeading} (${rangeLabel(ctx)})`),
    el('p', { class: 'meta' }, 'SQL Server keeps the old versions of changed rows in tempdb\'s version store (snapshot isolation, read committed snapshot, '
      + 'triggers, online index builds). Cleanup removes a version once no transaction can still read it: one long-open transaction holds the whole store back.'));
  if (!l) {
    sec.append(el('p', { class: 'empty' }, 'No read yet: the mssql_versionstore collection runs every minute and needs VIEW SERVER STATE.'));
    return sec;
  }
  const pct = l.tempdb_pct == null ? null : Number(l.tempdb_pct);
  sec.append(el('div', { class: 'tiles' },
    tile('version store', fmtBytes(l.reserved_bytes) || '0 B', pct != null && pct > 100 / 3 ? 'warn' : ''),
    tile('of tempdb\'s data files', pct == null ? '-' : fmtNum(pct) + ' %', pct != null && pct > 100 / 3 ? 'warn' : ''),
    tile('generation', l.generation_kb_s == null ? '-' : kbs(l.generation_kb_s)),
    tile('cleanup', l.cleanup_kb_s == null ? '-' : kbs(l.cleanup_kb_s)),
    tile('oldest snapshot transaction', l.holder_session_id == null ? 'none' : `session ${String(l.holder_session_id)}, ${fmtSecs(l.holder_elapsed_s)}`,
      l.holder_session_id != null && Number(l.holder_elapsed_s) >= 600 ? 'warn' : ''),
  ));

  // the holder, named beside the store
  sec.append(el('h3', {}, 'The holder'));
  if (l.holder_session_id == null) {
    sec.append(el('p', { class: 'meta' }, `No active transaction generated or read row versions at the last read (${fmtTime(l.snapshot_at)}): nothing holds cleanup back.`));
  } else {
    sec.append(el('p', { class: 'meta' }, 'The oldest active transaction that generates or may read row versions: cleanup cannot pass it. '
      + `${fmtNum(l.snapshot_tx_count)} such transaction(s) were active at the last read (${fmtTime(l.snapshot_at)}).`),
      props([
        ['session', String(l.holder_session_id)],
        ['login', String(l.holder_login ?? '')],
        ['program', String(l.holder_program ?? '')],
        ['host', String(l.holder_host ?? '')],
        ['session\'s database', String(l.holder_database ?? '')],
        ['kind', l.holder_is_snapshot ? 'a snapshot isolation transaction' : 'not snapshot isolation (read committed snapshot, a trigger, MARS or an online index build)'],
        ['transaction started', fmtTime(l.holder_started_at)],
        ['open for', fmtSecs(l.holder_elapsed_s)],
        ['last statement', l.holder_statement == null ? 'not read' : stmt(l.holder_statement)],
      ]));
  }
  if (checks.length) {
    sec.append(el('h3', {}, 'Checks'), grid(checks, [
      { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'check' }, { key: 'object' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
    ]));
  }

  sec.append(el('h3', {}, 'The store over the range'), el('div', { class: 'charts' },
    el('div', {},
      lineChart('Version store size', s, [{ key: 'reserved_bytes', label: 'reserved in tempdb' }, { key: 'store_bytes', label: 'Version Store Size counter' }], v => fmtBytes(v)),
      numbers('Version store size', s, [
        { key: 'snapshot_at', label: 'at', fmt: fmtTime },
        { key: 'reserved_bytes', label: 'reserved in tempdb', num: true, fmt: fmtBytes },
        { key: 'store_bytes', label: 'counter', num: true, fmt: fmtBytes },
        { key: 'tempdb_data_bytes', label: 'tempdb data files', num: true, fmt: fmtBytes },
        { key: 'holder_elapsed_s', label: 'oldest transaction open for', num: true, fmt: v => v == null ? '' : fmtSecs(v) },
      ])),
    el('div', {},
      lineChart('Generation and cleanup', s, [{ key: 'generation_kb_s', label: 'generation KB/s' }, { key: 'cleanup_kb_s', label: 'cleanup KB/s' }], v => fmtNum(v)),
      numbers('Generation and cleanup', s, [
        { key: 'snapshot_at', label: 'at', fmt: fmtTime },
        { key: 'generation_kb_s', label: 'generation', num: true, fmt: kbs },
        { key: 'cleanup_kb_s', label: 'cleanup', num: true, fmt: kbs },
      ]))));

  sec.append(el('h3', {}, 'Holders in the range'),
    el('p', { class: 'meta' }, 'Every transaction that was the oldest at a read of the range, the longest open first.'),
    grid(holders, [
      { key: 'session_id', label: 'session', num: true, fmt: v => String(v ?? '') },
      { key: 'login_name', label: 'login' },
      { key: 'program_name', label: 'program' },
      { key: 'host_name', label: 'host' },
      { key: 'database_name', label: 'session\'s database' },
      { key: 'started_at', label: 'transaction started', fmt: fmtTime },
      { key: 'elapsed_s', label: 'open for', num: true, fmt: fmtSecs },
      { key: 'first_seen', label: 'first seen', fmt: fmtTime },
      { key: 'last_seen', label: 'last seen', fmt: fmtTime },
      { key: 'reads', num: true },
      { key: 'statement', label: 'last statement', wide: true },
    ], 'No transaction held row versions at any read of this range.'));

  sec.append(el('h3', {}, 'The version store by database'),
    grid(rowsOf(d.databases), [
      { key: 'database_name', label: 'database' },
      { key: 'reserved_bytes', label: 'in the version store', num: true, fmt: fmtBytes },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], 'No database holds row versions in tempdb now (or the server is older than SQL Server 2016 SP2, which has no per-database figure).'));

  const pvs = rowsOf(d.pvs);
  sec.append(el('h3', {}, 'Persistent version store (accelerated database recovery)'),
    el('p', { class: 'meta' }, 'A database with accelerated database recovery keeps its row versions in itself, not in tempdb. Aborted transactions wait there for the cleaner.'),
    grid(pvs, [
      { key: 'database_name', label: 'database' },
      { key: 'adr_on', label: 'recovery', fmt: v => v ? 'accelerated' : 'off' },
      { key: 'pvs_bytes', label: 'version store', num: true, fmt: fmtBytes },
      { key: 'online_index_bytes', label: 'online index versions', num: true, fmt: fmtBytes },
      { key: 'aborted_tx_count', label: 'aborted transactions', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : fmtNum(v) },
      { key: 'oldest_tx_session_id', label: 'oldest transaction\'s session', num: true, fmt: v => String(v ?? '') },
      { key: 'oldest_tx_started_at', label: 'oldest transaction started', fmt: fmtTime },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], 'No database uses accelerated database recovery (or the server is older than SQL Server 2019).'));
  return sec;
}
