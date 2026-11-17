// Azure SQL Database's resource use and tier (B2a): the instance's Azure tab (DBA Dash's Azure DB tab,
// AzureDBResourceStats.cs) and the fleet's Azure Summary (DBA Dash's AzureSummary.cs). Data from /api/mssql/azuredb and
// /api/azuredb/summary: mssql_azuredb_resources (a minute a database from sys.dm_db_resource_stats, which keeps about
// an hour of 15-second rows: a longer outage, a failover or a serverless pause is a gap), mssql_azuredb_governance (the
// tier, hourly) and mssql_storage (the database's files). Every average over the window weighs each minute by its
// samples (DBA Dash's average over the view's rows); a maximum is the largest 15-second figure.
import { get, Row, rowsOf, Table } from './api';
import { ChartChoice, chartChoice, chartToolbar, dbMeasures, groupLabel, groupStep, layout, measureCharts, pickRows } from './azure_charts';
import { mssqlPropertiesTab } from './mssql_properties';
import { hrefWith } from './dbinfo';
import { folderWords, tagWords } from './fleet';
import { Ctx, href, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

const pct = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
const mb = (v: unknown) => v == null ? '' : fmtNum(v) + ' MB';
const num = (v: unknown) => v == null ? '' : fmtNum(v);
const buckets = ['under 10 %', '10-20 %', '20-30 %', '30-40 %', '40-50 %', '50-60 %', '60-70 %', '70-80 %', '80-90 %', '90 % and over'];
const tone: Record<string, string> = { ok: 'ok', warning: 'warn', critical: 'crit', stale: 'warn' };
// a numeric column: sorted and filtered as a number (ui.ts grid)
const n = (key: string, label: string, fmt: (v: unknown) => string = num): Col => ({ key, label, fmt, num: true });

// hist: DBA Dash's utilisation histogram column (P25 task 8) - the window's samples in ten 10 % buckets (0-10 % to
// 90-100 %), one bar each, its height the bucket's share of the samples; the counts in the title and the label
const hist = (key: string, label: string): Col => ({ key, label, fmt: v => {
  const b = Array.isArray(v) ? v.map(Number) : [];
  const all = b.reduce((x, y) => x + y, 0);
  if (!all) return '';
  const words = b.map((c, i) => `${i * 10}-${i * 10 + 10} %: ${c}`).join(', ');
  return el('span', { class: 'hist', role: 'img', 'aria-label': `${label}: ${words}`, title: words,
    style: 'display:inline-flex;align-items:flex-end;gap:1px;height:1.4em' },
  ...b.map((c, i) => el('span', { style: `display:inline-block;width:4px;height:${Math.max(c ? 8 : 0, Math.round(100 * c / all))}%;background:${i >= 7 ? 'var(--crit, #c33)' : 'var(--accent, #36c)'}` })));
} });

// sloJump: the Azure Summary's tier cell - a button that moves to the Service Objectives changes below, on this page.
// Never a '#azure-slo' link: the app routes on the hash, so that link opened the fleet Summary with the tag and the
// range dropped (review t11-3 BLOCKER 1).
const sloJump = (v: unknown): HTMLElement => {
  const b = el('button', { type: 'button', class: 'link', title: 'its changes: Service Objectives below' }, String(v));
  b.addEventListener('click', () => { const h = document.getElementById('azure-slo'); if (h) { h.tabIndex = -1; h.scrollIntoView({ block: 'start' }); h.focus(); } });
  return b;
};

type Parts = Record<'tier' | 'summary' | 'minutes' | 'hours' | 'days' | 'gaps', Table | null>;

export async function mssqlAzureView(ctx: Ctx): Promise<HTMLElement> {
  const [d, st] = await Promise.all([get<Parts>('mssql/azuredb', { instance: ctx.instance, ...window_(ctx) }),
    get<{ state: Table | null }>('mssql/state', { instance: ctx.instance, collections: 'mssql_azuredb_resources,mssql_azuredb_governance' }).catch(() => null)]);
  const tier = rowsOf(d.tier)[0], sum = rowsOf(d.summary)[0], minutes = rowsOf(d.minutes), hours = rowsOf(d.hours), gaps = rowsOf(d.gaps);
  // a window over a day reads its hours (B2a-N2: built hours and edge minutes, the summary's numbers)
  const byHour = Number(sum?.minutes ?? 0) > 1440 || minutes.length >= 1440;
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
  sec.append(el('h3', {}, 'The tier\'s limits'), el('p', { class: 'meta' }, 'From sys.dm_user_db_resource_governance as last read (the max size from ',
    'DATABASEPROPERTYEX). The tier\'s changes (objective, pool, DTU or vCore limit) are on ',
    el('a', { href: href(ctx, { tab: mssqlPropertiesTab }) }, 'Properties (Changes)'), ' and on the ',
    el('a', { href: href(ctx, { tab: 'azuresummary', instance: undefined }) }, 'Azure Summary'),
    ' under Service Objectives (changes); a change of these limits alone is listed on no page.'),
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
  // DBA Dash's Azure DB tab draws the figures over time: the window's minutes (at most a day of them), or past a day
  // its hours, oldest first - or, by the toolbar's Date Grouping, its minutes, hours or days (P25 task 10), the charts
  // laid one, two or three a row; the grid below follows the same grouping
  const days = rowsOf(d.days);
  // an hour's or a day's grid: its start, its minutes in the window (partial at an edge), its figures
  const bucketCols = (key: string): Col[] => [
      { key, fmt: fmtTime }, n('minutes', 'minutes'), { key: 'partial', label: '', fmt: v => v === true ? 'partial' : '' }, n('samples', 'samples'),
      n('avg_cpu_percent', 'CPU avg', pct), n('max_cpu_percent', 'CPU max', pct),
      n('avg_data_io_percent', 'data IO avg', pct), n('max_data_io_percent', 'data IO max', pct),
      n('avg_log_write_percent', 'log write avg', pct), n('max_log_write_percent', 'log write max', pct),
      n('avg_memory_usage_percent', 'memory', pct),
      ...(dtu ? [n('avg_dtu_percent', 'DTU avg', pct), n('max_dtu_percent', 'DTU max', pct)] : []),
      n('max_worker_percent', 'workers', pct), n('max_session_percent', 'sessions', pct),
    ];
  const words: Record<string, [string, string, string]> = {
    minute: ['Minutes', 'Newest first, at most a day; each the average of its 15-second rows, the maximum their largest.', 'No minute in the window.'],
    hour: ['Hours', 'Newest first (UTC hours); each the average of its 15-second rows, the maximum their largest; ' +
      'an hour at an edge of the window counts only its minutes inside it (marked partial).', 'No hour in the window.'],
    day: ['Days', 'Newest first (UTC days); each the average of its 15-second rows, the maximum their largest; ' +
      'a day at an edge of the window counts only its minutes inside it (marked partial).', 'No day in the window.'],
    step: ['Buckets', 'Newest first (UTC; each bucket starts a whole number of steps after 1900-01-01, as DBA Dash counts them); each the average of ' +
      'its 15-second rows, the maximum their largest; a bucket with fewer minutes than it spans (an edge of the window, or minutes not stored) is marked partial.', 'No bucket in the window.'],
  };
  const body = el('div');
  // control audit A1: DBA Dash's other steps read part=grouped&step=; the newest answer only is drawn
  let drawSeq = 0;
  const draw = (c: ChartChoice) => {
    const mine = ++drawSeq, step = groupStep(c.grouping);
    if (step == null) {
      const { rows, unit } = pickRows(c.grouping, { minutes, hours, days }, byHour);
      paint(c, rows, unit, '');
      return;
    }
    body.replaceChildren(el('p', { class: 'meta' }, `Reading the ${groupLabel(c.grouping)} buckets...`));
    get<{ grouped: Table | null }>('mssql/azuredb', { instance: ctx.instance, ...window_(ctx), part: 'grouped', step })
      .then(g => { if (mine === drawSeq) paint(c, rowsOf(g.grouped), 'step', groupLabel(c.grouping)); })
      .catch(e => { if (mine === drawSeq) body.replaceChildren(errorBox(e)); });
  };
  const paint = (c: ChartChoice, rows: Row[], unit: string, stepLabel: string) => {
    const asc = [...rows].reverse();
    // control audit A2: DBA Dash's measures, the ones chosen in the toolbar's Columns (its defaults Max CPU / Data / Log
    // Write %), one chart per axis
    const charts = layout(el('div', { class: 'charts' }, ...measureCharts(asc, dbMeasures, c, 'Resource use')), c.columns);
    const [head, meta, none] = words[unit];
    body.replaceChildren(charts, el('h3', {}, stepLabel ? `${head} of ${stepLabel}` : head), el('p', { class: 'meta' }, meta),
      unit === 'minute' ? grid(minutes, [
      { key: 'minute', fmt: fmtTime }, n('samples', 'samples'),
      n('avg_cpu_percent', 'CPU avg', pct), n('max_cpu_percent', 'CPU max', pct),
      n('avg_data_io_percent', 'data IO avg', pct), n('max_data_io_percent', 'data IO max', pct),
      n('avg_log_write_percent', 'log write avg', pct), n('max_log_write_percent', 'log write max', pct),
      n('avg_memory_usage_percent', 'memory', pct),
      ...(dtu ? [n('avg_dtu_percent', 'DTU avg', pct), n('max_dtu_percent', 'DTU max', pct)] : []),
      n('max_worker_percent', 'workers', pct), n('max_session_percent', 'sessions', pct),
    ], none) : grid(unit === 'step' ? rows : unit === 'day' ? days : hours, bucketCols(unit === 'step' ? 'snapshot_at' : unit), none));
  };
  sec.append(chartToolbar('mssqlazure', draw, dbMeasures), body);
  draw(chartChoice('mssqlazure'));
  return sec;
}

// AzureNode: DBA Dash's logical server or elastic pool node (P25 task 7, azure_nodes.ts) - the summary cut to it
export interface AzureNode { server: string; pool?: string }

// links to the node pages (azure_nodes.ts): a logical server, an elastic pool of it
const serverHref = (ctx: Ctx, server: string) => hrefWith(ctx, 'azureserver', { server });
const poolHref = (ctx: Ctx, server: string, pool: string) => hrefWith(ctx, 'azurepool', { server, pool });

// azureSummaryView: DBA Dash's Azure Summary of the scope, or of one logical server or elastic pool (node: the server and
// pool nodes' pages, P25 task 7). On a pool's page the section carries one member database's instance in
// data-member: the pool is read through its databases (pools.ts).
export async function azureSummaryView(ctx: Ctx, node?: AzureNode): Promise<HTMLElement> {
  const d = await get<{ databases: Table | null; pools: Table | null; slo_history: Table | null; governance: Table | null; pool_history: Table | null;
    pool_history_state: Table | null }>('azuredb/summary', { ...window_(ctx),
    ...(ctx.tag ? { tag: ctx.tag } : {}), ...(node ? { server: node.server, ...(node.pool ? { pool: node.pool } : {}) } : {}) });
  const rows = rowsOf(d.databases);
  // the read lists every Azure SQL Database of the scope (read or not): none = the scope holds none, so no grid of
  // Azure's columns and no word of them, the scope said instead (j15b's wording walk: 'elastic pool' under a
  // PostgreSQL tag)
  // under a tag folder (TAGALL) the read is the folder's: the heading names it, as Performance summary's does
  const head = (node ? (node.pool ? `Elastic pool ${node.pool} on ${node.server}` : `Logical server ${node.server}`) : 'Azure Summary') + (ctx.tag ? ` - ${tagWords(ctx.tag)}` : '');
  // where the databases are: the node's words, then the tag folder's
  const at = (node ? (node.pool ? `in the elastic pool ${node.pool} of the logical server ${node.server} ` : `on the logical server ${node.server} `) : '') +
    (ctx.tag ? `of ${folderWords(ctx.tag)} ` : '');
  if (!rows.length) {
    const where = ctx.tag ? folderWords(ctx.tag) : '';
    return el('section', {}, el('h2', {}, head), el('p', { class: 'empty' }, node
      ? `pgvigil reads no Azure SQL Database ${at.trimEnd()}: this page has nothing to show (the names come from the databases' own reads: the pool's member rows, the server's name, the tier).`
      : ctx.tag
        ? `${where.charAt(0).toUpperCase()}${where.slice(1)} holds no Azure SQL Database: this summary has nothing to show for it.`
        : 'pgvigil reads no Azure SQL Database: this summary has nothing to show.'));
  }
  const sec = el('section', {}, el('h2', {}, head),
    el('p', { class: 'meta' }, `Every Azure SQL Database ${at}pgvigil reads, over the window: its resource use as a share of its limit (each average weighs ` +
      'the minutes by their 15-second samples; a maximum is the largest sample), the share of samples at 70 % and over, and its PRIMARY data files ' +
      'against their max size (DBA Dash\'s % Max Size: warning over 80 %, critical over 90 %; stale when the files were read over 3 hours ago). ' +
      'Sorted as DBA Dash sorts it, the most unused DTUs first. The four histograms are DBA Dash\'s: the window\'s samples in ten 10 % buckets, ' +
      'beside the share at 70 % and over. Not as DBA Dash: a long window reads its built hours and its edge minutes (the minutes\' numbers exactly; DBA Dash rounds a window over a day to hours).'));
  // a read-only replica (its newest minute's replica_role over 0) reports its primary's names: DBA Dash's '(read-only)',
  // the role in words on its title (P25 finding L109)
  const roles: Record<string, string> = { '1': 'a high-availability replica', '2': 'a geo-replication forwarder', '3': 'a named replica' };
  const name = (v: unknown, r: Row) => el('a', { href: href(ctx, { instance: Number(r.instance_id), tag: undefined, tab: 'mssqlazure' }),
    ...(r.read_only ? { title: `Read through a read-only connection: ${roles[String(r.replica_role)] ?? 'a replica'} (replica role ${String(r.replica_role)})` } : {}) },
    String(v) + (r.read_only ? ' (read-only)' : ''));
  sec.append(grid(rows, [
    { key: 'instance', label: 'database (instance)', fmt: name }, { key: 'service_objective', label: 'tier', fmt: (v, r) => v == null ? (r.tier_read ? '' : el('span', { class: 'meta' }, 'not read')) : sloJump(v) },
    n('dtu_limit', 'DTUs'), n('cpu_limit', 'vCores'),
    { key: 'pool', label: 'elastic pool', fmt: (v, r) => v == null ? '' : r.server == null ? String(v) : el('a', { href: poolHref(ctx, String(r.server), String(v)) }, String(v)) },
    { key: 'server', label: 'logical server', fmt: v => v == null ? '' : el('a', { href: serverHref(ctx, String(v)) }, String(v)) },
    n('avg_cpu_percent', 'CPU avg', pct), n('max_cpu_percent', 'CPU max', pct), n('cpu_hot_pct', 'CPU samples at 70 %+', pct),
    n('avg_data_io_percent', 'data IO avg', pct), n('max_data_io_percent', 'data IO max', pct), n('data_hot_pct', 'data IO samples at 70 %+', pct),
    n('avg_log_write_percent', 'log write avg', pct), n('max_log_write_percent', 'log write max', pct), n('log_hot_pct', 'log write samples at 70 %+', pct),
    n('avg_dtu_percent', 'DTU avg', pct), n('max_dtu_percent', 'DTU max', pct), n('dtu_hot_pct', 'DTU samples at 70 %+', pct),
    n('unused_dtu', 'DTUs unused at the max'),
    hist('cpu_hist', 'CPU histogram'), hist('data_hist', 'data IO histogram'), hist('log_hist', 'log write histogram'), hist('dtu_hist', 'DTU histogram'),
    n('samples', 'samples'), n('gap_minutes', 'minutes in gaps', v => Number(v) > 0 ? num(v) : ''),
    n('allocated_mb', 'allocated', mb), n('used_mb', 'used', mb), n('max_size_mb', 'max size', mb),
    n('allocated_pct', '% max size (allocated)', pct), n('used_pct', '% max size (used)', pct),
    { key: 'pctmax_status', label: '% Max Size', fmt: v => v == null ? el('span', { class: 'meta' }, 'not read') : badge(String(v), tone[String(v)] ?? '') },
    { key: 'files_read_at', label: 'files read', fmt: fmtTime },
  ], 'No Azure SQL Database is read in this scope.'));
  // DBA Dash's separate Elastic Pool grid (P25 task 8): each pool of the scope's databases once (/api/azuredb/summary
  // part=pools); a pool's name opens its pool's page, the server its server's (task 7's nodes)
  const pools = rowsOf(d.pools);
  if (node?.pool) {
    // a member that holds the pool's own read first (pool_read: its member row); one known by its governance row
    // alone has no pool read to show (review t11-3 SHOULD 2)
    const inPool = rows.filter(x => x.pool != null && String(x.pool).toUpperCase() === node.pool!.toUpperCase());
    const m = inPool.find(x => x.pool_read) ?? inPool[0];
    if (m) sec.dataset.member = String(m.instance_id);
  }
  sec.append(el('h3', {}, 'Elastic pools'), grid(pools, [
    { key: 'pool', label: 'elastic pool', fmt: (v, r) => el('a', { href: poolHref(ctx, String(r.server), String(v)) }, String(v)) },
    { key: 'server', label: 'logical server', fmt: v => el('a', { href: serverHref(ctx, String(v)) }, String(v)) }, n('databases', 'databases read'),
    n('avg_cpu_percent', 'CPU avg', pct), n('max_cpu_percent', 'CPU max', pct),
    n('avg_data_io_percent', 'data IO avg', pct), n('max_data_io_percent', 'data IO max', pct),
    n('avg_log_write_percent', 'log write avg', pct), n('max_log_write_percent', 'log write max', pct),
    n('avg_edtu_percent', 'eDTU avg', pct), n('max_edtu_percent', 'eDTU max', pct),
    n('max_worker_percent', 'workers max', pct), n('max_session_percent', 'sessions max', pct),
    n('used_storage_percent', 'storage used', pct), n('allocated_storage_percent', 'storage allocated', pct),
    n('minutes', 'minutes'), { key: 'last_minute', label: 'last minute', fmt: fmtTime },
  ], 'No database of this scope is in an elastic pool pgvigil reads.'));
  // DBA Dash's Pool history (P25 task 9b): each change of a pool's DTU or storage limit, from master's
  // sys.elastic_pool_resource_stats through mssql_pool_limits - a read that needs dbmanager in master, an opt-in; a
  // pool none of whose databases read it gets the words, never an empty grid (the CPU limit is never shown: Microsoft
  // calls it informational, not supported)
  const states = rowsOf(d.pool_history_state), unread = states.filter(r => r.last_read == null);
  if (states.length) {
    sec.append(el('h3', {}, 'Pool history'));
    if (states.length > unread.length) {
      sec.append(grid(rowsOf(d.pool_history), [
        { key: 'pool', label: 'elastic pool', fmt: (v, r) => el('a', { href: poolHref(ctx, String(r.server), String(v)) }, String(v)) },
        { key: 'server', label: 'logical server' },
        // a change read after a gap in the reads is known only between two times (review t11-1 SHOULD 3)
        { key: 'changed_at', label: 'changed', fmt: (v, r) => r.changed_after != null ? `between ${fmtTime(r.changed_after)} and ${fmtTime(v)}` : fmtTime(v) },
        n('old_dtu_limit', 'DTU limit from'), n('new_dtu_limit', 'DTU limit to'),
        n('old_storage_limit_mb', 'storage limit from', mb), n('new_storage_limit_mb', 'storage limit to', mb),
      ], 'No change of a read pool\'s DTU or storage limit in what pgvigil has read (master keeps 14 days; pgvigil keeps what it read).'));
    }
    if (unread.length) {
      sec.append(el('p', { class: 'meta', role: 'note' }, 'Pool history - the pool\'s DTU and storage limits over time - is read from master\'s ' +
        'sys.elastic_pool_resource_stats, which needs the dbmanager role in the logical server\'s master: an opt-in, since that role can create and drop ' +
        'databases, which can cost money. Its block, commented out, is in the instance\'s rights script (Admin > Instances). That view keeps 14 days; ' +
        'pgvigil keeps what it read. The limits\' shares (CPU, data IO, log write, eDTU, workers, sessions, storage) are above, read through each pooled database.'),
      el('ul', {}, ...unread.map(r => el('li', {}, `${String(r.pool)} on ${String(r.server)}: ` +
        (r.read_until != null ? `read until ${fmtTime(r.read_until)}; since then: ` : '') +
        (r.skip_note ? `${String(r.skip_note)} (${fmtTime(r.skipped_at)})`
          : r.read_until != null ? 'its runs failed (Collection health names why)' : 'not read yet - mssql_pool_limits runs hourly on each pooled database')))));
    }
  }
  // DBA Dash's Azure Service Objectives and Resource Governance (P25 task 9): each tier change of these databases
  // (the governance history pgvigil keeps since it first read each one), and each database's governance row as last
  // read, its whole row in the viewer below the grid
  const slo = rowsOf(d.slo_history), gov = rowsOf(d.governance);
  const viewer = el('div', { 'aria-live': 'polite' });
  const dbLink = (v: unknown, r: Row) => el('a', { href: href(ctx, { instance: Number(r.instance_id), tag: undefined, tab: 'mssqlazure' }) }, String(v));
  const show = (r: Row) => {
    const g = (r.gov ?? {}) as Record<string, unknown>;
    viewer.replaceChildren(el('h4', { tabindex: '-1' }, `Resource governance of ${String(r.instance)}`),
      grid(Object.keys(g).sort().map(k => ({ setting: k, value: g[k] == null ? '' : String(g[k]) })), [{ key: 'setting' }, { key: 'value' }], 'No governance row read.'));
    (viewer.firstChild as HTMLElement).focus();
  };
  const gv = (k: string, label: string): Col => ({ key: k, label, num: true, fmt: (_v, r) => { const x = ((r.gov ?? {}) as Record<string, unknown>)[k]; return x == null ? '' : num(x); } });
  sec.append(el('h3', { id: 'azure-slo' }, 'Service Objectives (changes)'), grid(slo, [
    { key: 'instance', label: 'database (instance)', fmt: dbLink }, { key: 'changed_at', label: 'changed', fmt: fmtTime },
    { key: 'old_edition', label: 'edition from' }, { key: 'new_edition', label: 'edition to' },
    { key: 'old_service_objective', label: 'objective from' }, { key: 'new_service_objective', label: 'objective to' },
    n('old_dtu_limit', 'DTUs from'), n('new_dtu_limit', 'DTUs to'), n('old_cpu_limit', 'vCores from'), n('new_cpu_limit', 'vCores to'),
    { key: 'old_pool', label: 'pool from' }, { key: 'new_pool', label: 'pool to' },
  ], 'No tier change of these databases since pgvigil first read each one.'),
  el('h3', {}, 'Resource Governance'), grid(gov, [
    { key: 'instance', label: 'database (instance)', fmt: dbLink }, { key: 'service_objective', label: 'tier' },
    n('dtu_limit', 'DTUs'), n('cpu_limit', 'vCores'), { key: 'pool', label: 'elastic pool' },
    gv('max_sessions', 'max sessions'), gv('primary_group_max_workers', 'max workers'), gv('primary_max_log_rate', 'max log rate (bytes/s)'),
    gv('primary_group_max_io', 'max IOPS'), gv('max_db_memory', 'max memory'),
    { key: 'since', label: 'tier since', fmt: fmtTime },
    { key: 'view', label: 'viewer', fmt: (_v, r) => { const b = el('button', { type: 'button' }, 'View'); b.addEventListener('click', () => show(r)); return b; } },
  ], 'No governance row read for these databases (the mssql_azuredb_governance collection runs hourly).'), viewer);
  return sec;
}
