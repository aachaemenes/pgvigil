// Azure SQL Database's resource use and tier (B2a): the instance's Azure tab (DBA Dash's Azure DB tab,
// AzureDBResourceStats.cs) and the fleet's Azure Summary (DBA Dash's AzureSummary.cs). Data from /api/mssql/azuredb and
// /api/azuredb/summary: mssql_azuredb_resources (a minute a database from sys.dm_db_resource_stats, which keeps about
// an hour of 15-second rows: a longer outage, a failover or a serverless pause is a gap), mssql_azuredb_governance (the
// tier, hourly) and mssql_storage (the database's files). Every average over the window weighs each minute by its
// samples (DBA Dash's average over the view's rows); a maximum is the largest 15-second figure.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, window_ } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid } from './ui';

const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const mb = (v: unknown) => v == null ? '' : fmtNum(v) + ' MB';
const num = (v: unknown) => v == null ? '' : fmtNum(v);
const buckets = ['under 10 %', '10-20 %', '20-30 %', '30-40 %', '40-50 %', '50-60 %', '60-70 %', '70-80 %', '80-90 %', '90 % and over'];
const tone: Record<string, string> = { ok: 'ok', warning: 'warn', critical: 'crit', stale: 'warn' };
// a numeric column: sorted and filtered as a number (ui.ts grid)
const n = (key: string, label: string, fmt: (v: unknown) => string = num): Col => ({ key, label, fmt, num: true });

type Parts = Record<'tier' | 'summary' | 'minutes' | 'gaps', Table | null>;

export async function mssqlAzureView(ctx: Ctx): Promise<HTMLElement> {
  const [d, st] = await Promise.all([get<Parts>('mssql/azuredb', { instance: ctx.instance, ...window_(ctx) }),
    get<{ state: Table | null }>('mssql/state', { instance: ctx.instance, collections: 'mssql_azuredb_resources,mssql_azuredb_governance' }).catch(() => null)]);
  const tier = rowsOf(d.tier)[0], sum = rowsOf(d.summary)[0], minutes = rowsOf(d.minutes), gaps = rowsOf(d.gaps);
  const skipped = rowsOf(st?.state).filter(r => r.status === 'skipped');
  const sec = el('section', {}, el('h2', {}, 'Azure SQL Database'));
  if (!tier || (tier.tier_read_at == null && tier.resources_read_at == null)) {
    sec.append(el('p', { class: 'empty' }, 'No read of this database\'s resource use or tier: mssql_azuredb_resources (every minute) and ' +
      'mssql_azuredb_governance (hourly) read an Azure SQL Database; the login needs VIEW DATABASE STATE, and on Basic, S0, S1 or in an ' +
      'elastic pool ##MS_ServerStateReader## for the tier\'s limits.'));
    return sec;
  }
  // a DTU database by its tier, or by its minutes when the tier is not read (it needs ##MS_ServerStateReader## on Basic,
  // S0, S1 and in a pool; the minutes need VIEW DATABASE STATE only)
  const dtu = tier.dtu_limit != null || (sum != null && sum.max_dtu_limit != null);
  for (const r of skipped) sec.append(el('p', { class: 'meta' }, `Not read on this instance: ${String(r.collection)} is skipped (${String(r.note ?? '')}).`));
  const tierSkipped = skipped.some(r => r.collection === 'mssql_azuredb_governance');
  sec.append(el('p', { class: 'meta counts' },
    tier.service_objective == null ? (tierSkipped ? 'The tier is not read (above)' + (dtu && sum ? `; its minutes give ${num(sum.max_dtu_limit)} DTUs. ` : '. ') : 'The tier is not read yet. ') : `${String(tier.edition ?? '')} ${String(tier.service_objective)}` +
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
    ], tierSkipped ? 'The tier is not read: mssql_azuredb_governance is skipped (above).' : 'The tier is not read yet.'));
  const sumCols: Col[] = [
    n('samples', '15-second samples'), n('minutes', 'minutes'),
    n('avg_cpu_percent', 'CPU avg', pct), n('max_cpu_percent', 'CPU max', pct),
    n('avg_data_io_percent', 'data IO avg', pct), n('max_data_io_percent', 'data IO max', pct),
    n('avg_log_write_percent', 'log write avg', pct), n('max_log_write_percent', 'log write max', pct),
    ...(dtu ? [n('avg_dtu_percent', 'DTU avg', pct), n('max_dtu_percent', 'DTU max', pct),
      n('avg_dtu', 'DTUs used avg'), n('max_dtu', 'DTUs used max'), n('unused_dtu', 'DTUs unused at the max')] : []),
  ];
  sec.append(el('h3', {}, 'This window'), el('p', { class: 'meta' }, 'Percentages of the database\'s limit' + (tier.pool ? ', as the elastic pool sets it for its databases' : '') +
    (dtu ? '; DTU % per sample is the greatest of CPU, data IO and log write (DBA Dash\'s rule).' : '; a vCore database has no DTU figures.')),
    grid(sum && Number(sum.samples) > 0 ? [sum] : [], sumCols, 'No minute of this database in the window.'));
  if (sum && Number(sum.samples) > 0) {
    const hist = (k: string) => (Array.isArray(sum[k]) ? (sum[k] as unknown[]).map(Number) : []);
    const h = { cpu: hist('cpu_hist'), data: hist('data_hist'), log: hist('log_hist'), dtu: hist('dtu_hist') };
    const rows: Row[] = buckets.map((b, i) => ({ bucket: b, cpu: h.cpu[i] ?? 0, data: h.data[i] ?? 0, log: h.log[i] ?? 0, dtu: h.dtu[i] ?? 0 }));
    sec.append(el('h3', {}, 'How the samples spread'), el('p', { class: 'meta' }, 'The count of 15-second samples in each band of the limit (DBA Dash\'s histograms).'),
      grid(rows, [{ key: 'bucket', label: 'band' }, n('cpu', 'CPU'), n('data', 'data IO'), n('log', 'log write'), ...(dtu ? [n('dtu', 'DTU')] : [])]));
  }
  // DBA Dash's Azure DB tab draws the figures over time: the window's minutes (at most a day of them), oldest first
  const asc = [...minutes].reverse();
  sec.append(el('div', { class: 'charts' },
    lineChart('Resource use (% of the limit)', asc, [{ key: 'avg_cpu_percent', label: 'CPU avg %' }, { key: 'avg_data_io_percent', label: 'data IO avg %' },
      { key: 'avg_log_write_percent', label: 'log write avg %' }, ...(dtu ? [{ key: 'avg_dtu_percent', label: 'DTU avg %' }] : [])], v => fmtNum(v) + ' %'),
    lineChart('Largest 15-second sample (% of the limit)', asc, [{ key: 'max_cpu_percent', label: 'CPU max %' }, { key: 'max_data_io_percent', label: 'data IO max %' },
      { key: 'max_log_write_percent', label: 'log write max %' }, ...(dtu ? [{ key: 'max_dtu_percent', label: 'DTU max %' }] : [])], v => fmtNum(v) + ' %')));
  sec.append(el('h3', {}, 'Minutes'), el('p', { class: 'meta' }, 'Newest first, at most a day; each the average of its 15-second rows, the maximum their largest.'),
    grid(minutes, [
      { key: 'minute', fmt: fmtTime }, n('samples', 'samples'),
      n('avg_cpu_percent', 'CPU avg', pct), n('max_cpu_percent', 'CPU max', pct),
      n('avg_data_io_percent', 'data IO avg', pct), n('max_data_io_percent', 'data IO max', pct),
      n('avg_log_write_percent', 'log write avg', pct), n('max_log_write_percent', 'log write max', pct),
      n('avg_memory_usage_percent', 'memory', pct),
      ...(dtu ? [n('avg_dtu_percent', 'DTU avg', pct), n('max_dtu_percent', 'DTU max', pct)] : []),
      n('max_worker_percent', 'workers', pct), n('max_session_percent', 'sessions', pct),
    ], 'No minute in the window.'));
  return sec;
}

export async function azureSummaryView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<{ databases: Table | null }>('azuredb/summary', { ...window_(ctx), ...(ctx.tag ? { tag: ctx.tag } : {}) });
  const rows = rowsOf(d.databases);
  const sec = el('section', {}, el('h2', {}, 'Azure Summary'),
    el('p', { class: 'meta' }, 'Every Azure SQL Database pgvigil reads, over the window: its resource use as a share of its limit (each average weighs ' +
      'the minutes by their 15-second samples; a maximum is the largest sample), the share of samples at 70 % and over, and its PRIMARY data files ' +
      'against their max size (DBA Dash\'s % Max Size: warning over 80 %, critical over 90 %; stale when the files were read over 3 hours ago). ' +
      'Sorted as DBA Dash sorts it, the most unused DTUs first. Not as DBA Dash: the four histograms show as the share of samples at 70 % and over ' +
      '(the instance\'s Azure tab has them whole), and a window over a day reads the minutes (DBA Dash reads hourly rows there; pgvigil has no hourly rollup yet).'));
  const name = (v: unknown, r: Row) => el('a', { href: href(ctx, { instance: Number(r.instance_id), tag: undefined, tab: 'mssqlazure' }) }, String(v));
  sec.append(grid(rows, [
    { key: 'instance', label: 'database (instance)', fmt: name }, { key: 'service_objective', label: 'tier', fmt: (v, r) => v == null ? (r.tier_read ? '' : el('span', { class: 'meta' }, 'not read')) : String(v) },
    n('dtu_limit', 'DTUs'), n('cpu_limit', 'vCores'), { key: 'pool', label: 'elastic pool' },
    n('avg_cpu_percent', 'CPU avg', pct), n('max_cpu_percent', 'CPU max', pct), n('cpu_hot_pct', 'CPU samples at 70 %+', pct),
    n('avg_data_io_percent', 'data IO avg', pct), n('max_data_io_percent', 'data IO max', pct), n('data_hot_pct', 'data IO samples at 70 %+', pct),
    n('avg_log_write_percent', 'log write avg', pct), n('max_log_write_percent', 'log write max', pct), n('log_hot_pct', 'log write samples at 70 %+', pct),
    n('avg_dtu_percent', 'DTU avg', pct), n('max_dtu_percent', 'DTU max', pct), n('dtu_hot_pct', 'DTU samples at 70 %+', pct),
    n('unused_dtu', 'DTUs unused at the max'),
    n('samples', 'samples'), n('gap_minutes', 'minutes in gaps', v => Number(v) > 0 ? num(v) : ''),
    n('allocated_mb', 'allocated', mb), n('used_mb', 'used', mb), n('max_size_mb', 'max size', mb),
    n('allocated_pct', '% max size (allocated)', pct), n('used_pct', '% max size (used)', pct),
    { key: 'pctmax_status', label: '% Max Size', fmt: v => v == null ? el('span', { class: 'meta' }, 'not read') : badge(String(v), tone[String(v)] ?? '') },
    { key: 'files_read_at', label: 'files read', fmt: fmtTime },
  ], 'No Azure SQL Database is read in this scope.'));
  return sec;
}
