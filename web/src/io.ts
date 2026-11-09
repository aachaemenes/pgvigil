// The IO views (task 43): an instance's IO tab - the platform's storage metrics (CloudWatch, RDS and Aurora),
// pg_stat_io, pg_stat_database's IO time, the checkpointer, the top statements by IO and the IO findings - and
// the DMS page's IO panel for the replication instances. Each reads the API itself; the window comes from the
// shell (pages.ts hands it over), like the borrowed views.
import { get, Row, rowsOf, Table } from './api';
import { stmtCols } from './borrowed';
import { lineChart } from './chart';
import { badge, Col, el, fmtBytes, fmtNum, fmtTime, grid } from './ui';

export interface Window { from: string; to: string }

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const ms = (v: number) => fmtNum(v) + ' ms';
const pctFmt = (v: number) => fmtNum(v) + ' %';
const bytesS = (v: number) => fmtBytes(v) + '/s';

// pivot turns long rows (snapshot_at, metric, value) into one row per time with a key per metric; scale maps a
// metric to a factor (CloudWatch reports RDS latency in seconds, the charts show milliseconds).
function pivot(rows: Row[], scale: Record<string, number> = {}): Row[] {
  const by = new Map<string, Row>();
  for (const r of rows) {
    const t = String(r.snapshot_at);
    let o = by.get(t);
    if (!o) { o = { snapshot_at: t }; by.set(t, o); }
    if (r.value != null) o[String(r.metric)] = Number(r.value) * (scale[String(r.metric)] ?? 1);
  }
  return [...by.values()].sort((a, b) => String(a.snapshot_at).localeCompare(String(b.snapshot_at)));
}

const has = (rows: Row[], keys: string[]) => rows.some(r => keys.some(k => r[k] != null));

interface ChartSet { title: string; series: { key: string; label: string }[]; fmt?: (v: number) => string }

// charts draws the sets that have data (an RDS instance has no Volume* series, Aurora no balances).
function charts(rows: Row[], sets: ChartSet[]): HTMLElement[] {
  return sets.filter(c => has(rows, c.series.map(s => s.key))).map(c => lineChart(c.title, rows, c.series, c.fmt));
}

const platformSets: ChartSet[] = [
  { title: 'Storage IOPS', series: [{ key: 'ReadIOPS', label: 'read' }, { key: 'WriteIOPS', label: 'write' }] },
  { title: 'Storage latency', series: [{ key: 'ReadLatency', label: 'read' }, { key: 'WriteLatency', label: 'write' }], fmt: ms },
  { title: 'Storage throughput', series: [{ key: 'ReadThroughput', label: 'read' }, { key: 'WriteThroughput', label: 'write' }, { key: 'StorageNetworkThroughput', label: 'storage network' }], fmt: bytesS },
  { title: 'Disk queue depth', series: [{ key: 'DiskQueueDepth', label: 'queue' }] },
  { title: 'Burst balances (RDS)', series: [{ key: 'EBSIOBalance%', label: 'EBS IO' }, { key: 'EBSByteBalance%', label: 'EBS bytes' }, { key: 'BurstBalance', label: 'gp2 burst' }], fmt: pctFmt },
  { title: 'Cluster volume IOs per 5 min (Aurora, billed)', series: [{ key: 'VolumeReadIOPs', label: 'read' }, { key: 'VolumeWriteIOPs', label: 'write' }] },
];

const latestCols: Col[] = [
  { key: 'metric' },
  { key: 'value', num: true, fmt: (v, r) => {
    const u = String(r.unit ?? '');
    if (v == null) return '';
    if (u === 's') return ms(Number(v) * 1000);
    if (u === 'bytes/s') return bytesS(Number(v));
    if (u === 'bytes') return fmtBytes(v);
    if (u === 'percent') return pctFmt(Number(v));
    return fmtNum(v) + (u ? ' ' + u : '');
  } },
  { key: 'stat' },
  { key: 'at', label: 'datapoint', fmt: fmtTime },
  { key: 'dim', label: 'read from' },
];

const byKindCols: Col[] = [
  { key: 'backend_type', label: 'backend' },
  { key: 'object' },
  { key: 'context' },
  { key: 'reads', num: true },
  { key: 'read_bytes', label: 'read', num: true, fmt: fmtBytes },
  { key: 'ms_per_read', label: 'ms / read', num: true },
  { key: 'writes', num: true },
  { key: 'write_bytes', label: 'written', num: true, fmt: fmtBytes },
  { key: 'ms_per_write', label: 'ms / write', num: true },
  { key: 'writebacks', num: true },
  { key: 'extends', num: true },
  { key: 'hit_pct', label: 'hit', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' %' },
  { key: 'evictions', num: true },
  { key: 'fsyncs', num: true },
];

const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge },
  { key: 'setting', label: 'finding' },
  { key: 'value' },
  { key: 'suggested' },
  { key: 'detail', wide: true },
  { key: 'at', label: 'when', fmt: fmtTime },
];

type IOReply = Record<'state' | 'platform_latest' | 'platform' | 'pgio' | 'pgio_by' | 'dbtime' | 'checkpoints' | 'statements' | 'findings', Table | null>;

// ioView is one instance's IO tab over the window; label names the window in the heading.
export async function ioView(instance: number, win: Window, label = ''): Promise<HTMLElement> {
  const d = await get<IOReply>('io', { instance, ...win });
  const st = rowsOf(d.state)[0] ?? {};
  const managed = st.platform === 'rds' || st.platform === 'aurora';
  const ver = Number(st.server_version_num ?? 0);
  const timing = st.track_io_timing === 'on';
  const sec = el('section', {}, el('h2', {}, 'IO' + (label ? ` (${label})` : '')));

  const findings = rowsOf(d.findings);
  sec.append(el('h3', {}, 'Findings'),
    grid(findings, findingCols, 'No IO findings: balances, queue depth, read latency and the checkpoint mix are in range.'));

  // the platform's view of the storage
  sec.append(el('h3', {}, 'Storage (CloudWatch)'));
  const plat = pivot(rowsOf(d.platform), { ReadLatency: 1000, WriteLatency: 1000 });
  const latest = rowsOf(d.platform_latest);
  if (!latest.length && !plat.length) {
    sec.append(el('p', { class: 'empty' }, managed
      ? 'No CloudWatch IO rows yet: the io collection needs aws.cluster (Aurora) or aws.db_instance (RDS) in the instance\'s aws: block, and runs every 5 minutes.'
      : 'CloudWatch storage metrics exist for RDS and Aurora only; on this platform the host\'s disks are read by the host collection.'));
  } else {
    sec.append(el('p', { class: 'meta' }, '5-minute CloudWatch datapoints; an Aurora cluster reads the cluster dimension (its members together).'),
      grid(latest, latestCols, 'No datapoint in the last day.'),
      el('div', { class: 'charts' }, ...charts(plat, platformSets)));
  }

  // the server's view
  sec.append(el('h3', {}, 'pg_stat_io'));
  const pgio = rowsOf(d.pgio);
  if (ver && ver < 160000) {
    sec.append(el('p', { class: 'empty' }, 'pg_stat_io exists from PostgreSQL 16; this server reports none.'));
  } else {
    sec.append(el('div', { class: 'charts' },
      lineChart('IO bytes / s', pgio, [{ key: 'read_bytes_s', label: 'read' }, { key: 'write_bytes_s', label: 'write' }, { key: 'extend_bytes_s', label: 'extend' }], bytesS),
      lineChart('IOs / s', pgio, [{ key: 'reads_s', label: 'reads' }, { key: 'writes_s', label: 'writes' }, { key: 'evictions_s', label: 'evictions' }]),
      ...(timing ? [lineChart('Time per IO', pgio, [{ key: 'ms_per_read', label: 'read' }, { key: 'ms_per_write', label: 'write' }], ms)] : [])),
      el('h3', {}, 'By backend, object and context'),
      grid(rowsOf(d.pgio_by), byKindCols, 'No pg_stat_io rows in this window: the iostats collection runs every 5 minutes.'));
  }

  sec.append(el('h3', {}, 'Read and write time (pg_stat_database)'));
  if (!timing) {
    sec.append(el('p', { class: 'meta' }, `track_io_timing is ${st.track_io_timing ?? 'unknown'}: the read and write times stay 0 until it is on.`));
  }
  const dbt = rowsOf(d.dbtime);
  sec.append(el('div', { class: 'charts' },
    lineChart('IO time per second', dbt, [{ key: 'read_ms_s', label: 'read' }, { key: 'write_ms_s', label: 'write' }], ms),
    lineChart('Time per block read', dbt, [{ key: 'ms_per_blk_read', label: 'read' }], ms)));

  sec.append(el('h3', {}, 'Checkpoints'));
  const ck = rowsOf(d.checkpoints);
  sec.append(el('div', { class: 'charts' },
    lineChart('Checkpoints per interval', ck, [{ key: 'checkpoints_timed', label: 'timed' }, { key: 'checkpoints_req', label: 'requested' }]),
    lineChart('Checkpoint buffers / s', ck, [{ key: 'buffers_checkpoint_s', label: 'written' }])));

  sec.append(el('h3', {}, 'Top statements by IO'),
    el('p', { class: 'meta' }, 'Shared blocks read plus temp blocks read and written, over the window.'),
    grid(rowsOf(d.statements), stmtCols('io'), 'No statements in this window (pg_stat_statements is needed).'));
  return sec;
}

// ---- DMS replication instance IO panel ------------------------------------------------------------------

const dmsCols: Col[] = [
  { key: 'instance' },
  { key: 'ri_id', label: 'replication instance' },
  { key: 'class' },
  { key: 'read_iops', label: 'read IOPS', num: true },
  { key: 'write_iops', label: 'write IOPS', num: true },
  { key: 'read_latency_ms', label: 'read ms', num: true, fmt: (v, r) => latBadge(v, r) },
  { key: 'write_latency_ms', label: 'write ms', num: true, fmt: (v, r) => latBadge(v, r) },
  { key: 'read_bytes_s', label: 'read / s', num: true, fmt: fmtBytes },
  { key: 'write_bytes_s', label: 'write / s', num: true, fmt: fmtBytes },
  { key: 'queue_depth', label: 'queue', num: true, fmt: v => v != null && Number(v) > 10 ? badge(fmtNum(v), 'warn') : fmtNum(v) },
  { key: 'net_rx_bytes_s', label: 'network in / s', num: true, fmt: fmtBytes },
  { key: 'net_tx_bytes_s', label: 'network out / s', num: true, fmt: fmtBytes },
  { key: 'free_storage_bytes', label: 'free storage', num: true, fmt: fmtBytes },
  { key: 'free_pct', label: 'free', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' %' },
  { key: 'metrics_at', label: 'datapoint', fmt: fmtTime },
];
function latBadge(v: unknown, _r: Row): string | HTMLElement {
  return v != null && Number(v) > 20 ? badge(fmtNum(v), 'warn') : fmtNum(v);
}

const dmsSets: ChartSet[] = [
  { title: 'IOPS', series: [{ key: 'read_iops', label: 'read' }, { key: 'write_iops', label: 'write' }] },
  { title: 'Latency (worst per bucket)', series: [{ key: 'read_latency_ms', label: 'read' }, { key: 'write_latency_ms', label: 'write' }], fmt: ms },
  { title: 'Throughput', series: [{ key: 'read_bytes_s', label: 'read' }, { key: 'write_bytes_s', label: 'write' }, { key: 'net_rx_bytes_s', label: 'network in' }, { key: 'net_tx_bytes_s', label: 'network out' }], fmt: bytesS },
  { title: 'Disk queue depth (worst per bucket)', series: [{ key: 'queue_depth', label: 'queue' }] },
];

// dmsIOView is the DMS page's IO panel (instance: one instance's replication instances, none = every one;
// keep scopes the rows to the page's tag folder like the task rows).
export async function dmsIOView(win: Window, instance?: number, keep?: (r: Row) => boolean): Promise<HTMLElement> {
  const d = await get<Record<'instances' | 'series', Table | null>>('dmsio', { instance, ...win });
  let ris = rowsOf(d.instances), series = rowsOf(d.series);
  if (keep) { ris = ris.filter(keep); series = series.filter(keep); }
  const box = el('div', {}, el('h3', {}, 'Replication instance IO'),
    el('p', { class: 'meta' }, 'AWS/DMS storage and network metrics, the newest minute; latency in milliseconds. A queue over 10 or a latency over 20 ms means the instance\'s storage limits the task: more allocated storage (gp2 IOPS grow with size) or a larger class.'),
    grid(ris.filter(r => r.is_present !== false), dmsCols, 'No replication instance IO read yet.'));
  const byRI = new Map<string, Row[]>();
  for (const r of series) {
    const k = `${r.instance_id}|${r.ri_arn}`;
    if (!byRI.has(k)) byRI.set(k, []);
    byRI.get(k)!.push(r);
  }
  for (const rows of [...byRI.values()].slice(0, 4)) {
    box.append(el('h4', {}, String(rows[0].ri_id ?? rows[0].ri_arn)), el('div', { class: 'charts' }, ...charts(rows, dmsSets)));
  }
  if (byRI.size > 4) box.append(el('p', { class: 'meta' }, `${byRI.size - 4} more replication instance(s): pick an instance to see its own.`));
  return box;
}
