// Azure SQL Database's resource use and tier (B2a): the instance's Azure tab (DBA Dash's Azure DB tab,
// AzureDBResourceStats.cs) and the fleet's Azure Summary (DBA Dash's AzureSummary.cs). Data from /api/mssql/azuredb and
// /api/azuredb/summary: mssql_azuredb_resources (a minute a database from sys.dm_db_resource_stats, which keeps about
// an hour of 15-second rows: a longer outage, a failover or a serverless pause is a gap), mssql_azuredb_governance (the
// tier, hourly) and mssql_storage (the database's files). Every average over the window weighs each minute by its
// samples (DBA Dash's average over the view's rows); a maximum is the largest 15-second figure.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, href, window_ } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid } from './ui';

const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const mb = (v: unknown) => v == null ? '' : fmtNum(v) + ' MB';
const num = (v: unknown) => v == null ? '' : fmtNum(v);
const buckets = ['under 10 %', '10-20 %', '20-30 %', '30-40 %', '40-50 %', '50-60 %', '60-70 %', '70-80 %', '80-90 %', '90 % and over'];
const tone: Record<string, string> = { ok: 'ok', warning: 'warn', critical: 'crit' };

// share of the samples at 70 % and over (the histogram's last three buckets), as the Performance summary's 'hot' share
function hot(hist: unknown): string {
  const h = Array.isArray(hist) ? hist.map(Number) : [];
  const all = h.reduce((a, b) => a + b, 0);
  return all > 0 ? fmtNum(Math.round(1000 * (h[7] + h[8] + h[9]) / all) / 10) + ' %' : '';
}

type Parts = Record<'tier' | 'summary' | 'minutes' | 'gaps', Table | null>;

export async function mssqlAzureView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Parts>('mssql/azuredb', { instance: ctx.instance, ...window_(ctx) });
  const tier = rowsOf(d.tier)[0], sum = rowsOf(d.summary)[0], minutes = rowsOf(d.minutes), gaps = rowsOf(d.gaps);
  const sec = el('section', {}, el('h2', {}, 'Azure SQL Database'));
  if (!tier || (tier.tier_read_at == null && tier.resources_read_at == null)) {
    sec.append(el('p', { class: 'empty' }, 'No read of this database\'s resource use or tier: mssql_azuredb_resources (every minute) and ' +
      'mssql_azuredb_governance (hourly) read an Azure SQL Database; the login needs VIEW DATABASE STATE, and on Basic, S0, S1 or in an ' +
      'elastic pool ##MS_ServerStateReader## for the tier\'s limits.'));
    return sec;
  }
  const dtu = tier.dtu_limit != null;
  sec.append(el('p', { class: 'meta counts' },
    tier.service_objective == null ? 'The tier is not read yet. ' : `${String(tier.edition ?? '')} ${String(tier.service_objective)}` +
      (tier.slo_name ? ` (${String(tier.slo_name)})` : '') + (dtu ? `, ${num(tier.dtu_limit)} DTUs` : tier.cpu_limit != null ? `, ${num(tier.cpu_limit)} vCores` : '') +
      (tier.pool ? `, in the elastic pool ${String(tier.pool)}` : '') + `; this tier since ${fmtTime(tier.tier_since)}, read ${fmtTime(tier.tier_read_at)}. `,
    tier.newest_minute == null ? 'No minute of resource use stored yet.' : `Newest minute stored ${fmtTime(tier.newest_minute)}.`));
  if (tier.pool_note) sec.append(el('p', { class: 'meta' }, String(tier.pool_note)));
  if (gaps.length) {
    sec.append(el('p', { class: 'warn', role: 'note' }, `${gaps.length} gap(s) in this window: minutes the store does not have because ` +
      'the view no longer held them when they were read (the collector down over the view\'s hour, a failover or a serverless pause). ',
      gaps.map(g => `${fmtTime(g.gap_from)} to ${fmtTime(g.gap_to)} (${num(g.minutes)} minutes)`).join('; '), '.'));
  }
  const limits: Row[] = tier.service_objective == null ? [] : [{
    max_size_mb: tier.max_size_mb, usage_mb: tier.usage_mb, max_sessions: tier.max_sessions, max_workers: tier.max_workers, max_log_rate_mb_s: tier.max_log_rate_mb_s,
  }];
  sec.append(el('h3', {}, 'The tier\'s limits'), el('p', { class: 'meta' }, 'From sys.dm_user_db_resource_governance as last read; their history is on Properties (Changes).'),
    grid(limits, [
      { key: 'max_size_mb', label: 'max size', fmt: mb }, { key: 'usage_mb', label: 'local storage used', fmt: mb },
      { key: 'max_sessions', label: 'max sessions', fmt: num }, { key: 'max_workers', label: 'max worker threads', fmt: num },
      { key: 'max_log_rate_mb_s', label: 'max log rate (MB/s)', fmt: num },
    ], 'The tier is not read yet.'));
  const sumCols: Col[] = [
    { key: 'samples', label: '15-second samples', fmt: num }, { key: 'minutes', fmt: num },
    { key: 'avg_cpu_percent', label: 'CPU avg', fmt: pct }, { key: 'max_cpu_percent', label: 'CPU max', fmt: pct },
    { key: 'avg_data_io_percent', label: 'data IO avg', fmt: pct }, { key: 'max_data_io_percent', label: 'data IO max', fmt: pct },
    { key: 'avg_log_write_percent', label: 'log write avg', fmt: pct }, { key: 'max_log_write_percent', label: 'log write max', fmt: pct },
    ...(dtu ? [{ key: 'avg_dtu_percent', label: 'DTU avg', fmt: pct }, { key: 'max_dtu_percent', label: 'DTU max', fmt: pct },
      { key: 'avg_dtu', label: 'DTUs used avg', fmt: num }, { key: 'max_dtu', label: 'DTUs used max', fmt: num }, { key: 'unused_dtu', label: 'DTUs unused at the max', fmt: num }] as Col[] : []),
  ];
  sec.append(el('h3', {}, 'This window'), el('p', { class: 'meta' }, 'Percentages of the database\'s limit' + (tier.pool ? ', as the elastic pool sets it for its databases' : '') +
    (dtu ? '; DTU % per sample is the greatest of CPU, data IO and log write (DBA Dash\'s rule).' : '; a vCore database has no DTU figures.')),
    grid(sum && Number(sum.samples) > 0 ? [sum] : [], sumCols, 'No minute of this database in the window.'));
  if (sum && Number(sum.samples) > 0) {
    const hist = (k: string) => (Array.isArray(sum[k]) ? (sum[k] as unknown[]).map(Number) : []);
    const h = { cpu: hist('cpu_hist'), data: hist('data_hist'), log: hist('log_hist'), dtu: hist('dtu_hist') };
    const rows: Row[] = buckets.map((b, i) => ({ bucket: b, cpu: h.cpu[i] ?? 0, data: h.data[i] ?? 0, log: h.log[i] ?? 0, dtu: h.dtu[i] ?? 0 }));
    sec.append(el('h3', {}, 'How the samples spread'), el('p', { class: 'meta' }, 'The count of 15-second samples in each band of the limit (DBA Dash\'s histograms).'),
      grid(rows, [{ key: 'bucket', label: 'band' }, { key: 'cpu', label: 'CPU', fmt: num }, { key: 'data', label: 'data IO', fmt: num },
        { key: 'log', label: 'log write', fmt: num }, ...(dtu ? [{ key: 'dtu', label: 'DTU', fmt: num } as Col] : [])]));
  }
  sec.append(el('h3', {}, 'Minutes'), el('p', { class: 'meta' }, 'Newest first, at most a day; each the average of its 15-second rows, the maximum their largest.'),
    grid(minutes, [
      { key: 'minute', fmt: fmtTime }, { key: 'samples', fmt: num },
      { key: 'avg_cpu_percent', label: 'CPU avg', fmt: pct }, { key: 'max_cpu_percent', label: 'CPU max', fmt: pct },
      { key: 'avg_data_io_percent', label: 'data IO avg', fmt: pct }, { key: 'max_data_io_percent', label: 'data IO max', fmt: pct },
      { key: 'avg_log_write_percent', label: 'log write avg', fmt: pct }, { key: 'max_log_write_percent', label: 'log write max', fmt: pct },
      { key: 'avg_memory_usage_percent', label: 'memory', fmt: pct },
      ...(dtu ? [{ key: 'avg_dtu_percent', label: 'DTU avg', fmt: pct }, { key: 'max_dtu_percent', label: 'DTU max', fmt: pct }] as Col[] : []),
      { key: 'max_worker_percent', label: 'workers', fmt: pct }, { key: 'max_session_percent', label: 'sessions', fmt: pct },
    ], 'No minute in the window.'));
  return sec;
}

export async function azureSummaryView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<{ databases: Table | null }>('azuredb/summary', { ...window_(ctx), ...(ctx.tag ? { tag: ctx.tag } : {}) });
  const rows = rowsOf(d.databases);
  const sec = el('section', {}, el('h2', {}, 'Azure Summary'),
    el('p', { class: 'meta' }, 'Every Azure SQL Database pgvigil reads, over the window: its resource use as a share of its limit (each average weighs ' +
      'the minutes by their 15-second samples; a maximum is the largest sample), the share of samples at 70 % and over, and its PRIMARY data files ' +
      'against their max size (DBA Dash\'s % Max Size: warning over 80 %, critical over 90 %).'));
  const name = (v: unknown, r: Row) => el('a', { href: href(ctx, { instance: Number(r.instance_id), tag: undefined, tab: 'mssqlazure' }) }, String(v));
  sec.append(grid(rows, [
    { key: 'instance', label: 'database (instance)', fmt: name }, { key: 'service_objective', label: 'tier' },
    { key: 'dtu_limit', label: 'DTUs', fmt: num }, { key: 'cpu_limit', label: 'vCores', fmt: num }, { key: 'pool', label: 'elastic pool' },
    { key: 'avg_cpu_percent', label: 'CPU avg', fmt: pct }, { key: 'max_cpu_percent', label: 'CPU max', fmt: pct },
    { key: 'cpu_hist', label: 'CPU samples at 70 %+', fmt: v => hot(v) },
    { key: 'avg_data_io_percent', label: 'data IO avg', fmt: pct }, { key: 'max_data_io_percent', label: 'data IO max', fmt: pct },
    { key: 'avg_log_write_percent', label: 'log write avg', fmt: pct }, { key: 'max_log_write_percent', label: 'log write max', fmt: pct },
    { key: 'avg_dtu_percent', label: 'DTU avg', fmt: pct }, { key: 'max_dtu_percent', label: 'DTU max', fmt: pct },
    { key: 'dtu_hist', label: 'DTU samples at 70 %+', fmt: v => hot(v) }, { key: 'unused_dtu', label: 'DTUs unused at the max', fmt: num },
    { key: 'samples', label: 'samples', fmt: num }, { key: 'gap_minutes', label: 'minutes in gaps', fmt: v => Number(v) > 0 ? num(v) : '' },
    { key: 'allocated_mb', label: 'allocated', fmt: mb }, { key: 'used_mb', label: 'used', fmt: mb }, { key: 'max_size_mb', label: 'max size', fmt: mb },
    { key: 'allocated_pct', label: '% max size (allocated)', fmt: pct }, { key: 'used_pct', label: '% max size (used)', fmt: pct },
    { key: 'pctmax_status', label: '% Max Size', fmt: v => v == null ? el('span', { class: 'meta' }, 'not read') : badge(String(v), tone[String(v)] ?? '') },
  ], 'No Azure SQL Database is read in this scope.'));
  return sec;
}
