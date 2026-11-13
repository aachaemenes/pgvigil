// The Elastic pool page of an Azure SQL Database in a pool (CLOUDSQL C4): DBA Dash's 'Elastic Pool Storage' status for
// the database's pool, the pool grid of DBA Dash's Azure Summary (storage now, the window's averages and maxima), the
// pool's databases pgvigil reads, and the pool's minutes (DBA Dash's Pool tab). Data from /api/mssql/pool (mssql_pool:
// a minute a pool, from sys.dm_elastic_pool_resource_stats, which keeps about 40 minutes: a longer outage is a gap).
import { get, rowsOf, Table } from './api';
import { Ctx, window_ } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid } from './ui';

type Parts = Record<'status' | 'summary' | 'members' | 'minutes', Table | null>;
const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const gb = (v: unknown) => v == null ? '' : fmtNum(v) + ' GB';
const tone: Record<string, string> = { OK: 'ok', Warning: 'warn', Critical: 'crit', 'N/A': '' };

// hasPool: whether the database is in a pool now (mssql_pool_storage_status names its pool: read within 10 minutes);
// the instance's Elastic pool tab is shown only then, as the Availability tab is only where it has a read
export async function hasPool(instance: number): Promise<boolean> {
  const d = await get<Pick<Parts, 'status'>>('mssql/pool', { instance, part: 'status' });
  return rowsOf(d.status).some(r => r.pool != null);
}

export async function mssqlPoolView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Parts>('mssql/pool', { instance: ctx.instance, ...window_(ctx) });
  const status = rowsOf(d.status)[0], summary = rowsOf(d.summary)[0], members = rowsOf(d.members), minutes = rowsOf(d.minutes);
  const sec = el('section', {}, el('h2', {}, 'Elastic pool'));
  if (!status || status.pool == null) {
    sec.append(el('p', { class: 'empty' }, 'No pool read for this database: mssql_pool reads an Azure SQL Database in an elastic pool every minute ' +
      '(the login needs ##MS_ServerStateReader##, and the pool\'s name: the tag pool:<name>, or a login that may read sys.database_service_objectives).'));
    return sec;
  }
  const word = String(status.status ?? 'N/A');
  sec.append(el('p', { class: 'meta counts' }, `Pool ${String(status.pool)} on ${String(status.server)}: Elastic Pool Storage `,
    badge(word, tone[word] ?? ''),
    status.allocated_storage_percent == null ? '' : ` (${pct(status.allocated_storage_percent)} of the pool's maximum data size allocated, ${fmtTime(status.minute)})`,
    status.warning == null || status.critical == null ? '; no threshold set: N/A' : `; warning over ${fmtNum(Number(status.warning) * 100)} %, critical over ${fmtNum(Number(status.critical) * 100)} %`, '.'));
  const sumCols: Col[] = [
    { key: 'pool' }, { key: 'minutes', label: 'minutes read', fmt: v => fmtNum(v) },
    { key: 'allocated_storage_percent', label: 'allocated', fmt: pct }, { key: 'used_storage_percent', label: 'used', fmt: pct },
    { key: 'storage_limit_gb', label: 'max data size', fmt: gb }, { key: 'used_storage_gb', label: 'used', fmt: gb }, { key: 'free_storage_gb', label: 'free', fmt: gb },
    { key: 'avg_cpu_percent', label: 'CPU avg', fmt: pct }, { key: 'max_cpu_percent', label: 'CPU max', fmt: pct },
    { key: 'avg_data_io_percent', label: 'data IO avg', fmt: pct }, { key: 'max_data_io_percent', label: 'data IO max', fmt: pct },
    { key: 'avg_log_write_percent', label: 'log write avg', fmt: pct }, { key: 'max_log_write_percent', label: 'log write max', fmt: pct },
    { key: 'avg_edtu_percent', label: 'eDTU avg', fmt: pct }, { key: 'max_edtu_percent', label: 'eDTU max', fmt: pct },
    { key: 'max_worker_percent', label: 'workers max', fmt: pct }, { key: 'max_session_percent', label: 'sessions max', fmt: pct },
  ];
  sec.append(el('h3', {}, 'The pool in this window'),
    el('p', { class: 'meta' }, 'Percentages of the pool\'s limits, as Microsoft\'s view gives them; the pool\'s DTU or vCore limit is not in the view. eDTU is shown for a DTU pool only.'),
    grid(summary && Number(summary.minutes) > 0 ? [summary] : [], sumCols, 'No minute of this pool in the window.'));
  sec.append(el('h3', {}, 'Its databases pgvigil reads'), grid(members, [
    { key: 'name', label: 'database (instance)' }, { key: 'seen_at', label: 'last read in this pool', fmt: fmtTime },
  ], 'None.'));
  sec.append(el('h3', {}, 'Minutes'), el('p', { class: 'meta' }, 'Newest first; each the average of the view\'s few-second rows (maximum CPU: the largest of them), stored by the first database read.'),
    grid(minutes, [
      { key: 'minute', fmt: fmtTime }, { key: 'avg_cpu_percent', label: 'CPU avg', fmt: pct }, { key: 'max_cpu_percent', label: 'CPU max', fmt: pct },
      { key: 'avg_data_io_percent', label: 'data IO', fmt: pct }, { key: 'avg_log_write_percent', label: 'log write', fmt: pct },
      { key: 'avg_edtu_percent', label: 'eDTU', fmt: pct }, { key: 'max_worker_percent', label: 'workers', fmt: pct },
      { key: 'max_session_percent', label: 'sessions', fmt: pct }, { key: 'allocated_storage_percent', label: 'allocated', fmt: pct },
      { key: 'read_through', label: 'read through' },
    ], 'No minute in the window.'));
  return sec;
}
