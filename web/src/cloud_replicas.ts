// The provider replicas of an RDS or Cloud SQL instance (task 390b): a block under a PostgreSQL instance's Replication
// tab and an RDS for SQL Server instance's Availability tab. Data from /api/cloud/replicas: cloud_replicas (or
// mssql_cloud_replicas), every 5 minutes through the provider's own API (RDS DescribeDBInstances and CloudWatch
// ReplicaLag; Cloud SQL Admin and Cloud Monitoring), no SQL statement: a replica pgvigil does not connect to still has
// its lag. Each lag is to the replica's DIRECT upstream; a resource is one row whoever reads it.
import { get, rowsOf, Row, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, window_ } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid, props, tile } from './ui';
import { mssqlFindingCols } from './mssql_hadr';

type Parts = Record<'read' | 'resources' | 'series' | 'events' | 'findings', Table | null>;

const replTone = (v: unknown): string => {
  const s = String(v ?? '').toLowerCase();
  return s === '' ? '' : s === 'replicating' || s === 'running' ? 'ok' : 'crit';
};
const resourceCols = (ctx: Ctx): Col[] => [
  { key: 'resource_id', label: 'resource', fmt: (v, r) => r.self === true ? `${String(v)} (this instance)`
    : r.monitored_as != null ? el('a', { href: href(ctx, { tab: 'replication', instance: Number(r.monitored_as) }) }, String(v))
    : `${String(v)} (not monitored)` },
  { key: 'role', label: 'role', fmt: (v, r) => String(v ?? '') + (r.cascaded === true ? ' (cascaded: a replica that is a source)' : '') },
  { key: 'source_id', label: 'source' },
  { key: 'status', label: 'status' },
  { key: 'repl_status', label: 'replication', fmt: (v, r) => v == null || v === '' ? (r.role === 'replica' ? 'not reported yet' : '')
    : badge(String(v), replTone(v)) },
  { key: 'repl_note', label: 'the provider\'s words', wide: true },
  { key: 'lag_s', label: 'lag', fmt: v => v == null ? '' : `${fmtNum(v)} s`, num: true },
  { key: 'lag_at', label: 'lag at', fmt: v => fmtTime(v) },
  { key: 'byte_lag', label: 'byte lag', fmt: v => v == null ? '' : `${fmtNum(v)} bytes`, num: true },
  { key: 'region', label: 'region' },
  { key: 'snapshot_at', label: 'read', fmt: v => fmtTime(v) },
];
const eventCols: Col[] = [
  { key: 'at', label: 'seen', fmt: v => fmtTime(v) }, { key: 'prev_read_at', label: 'after the read at', fmt: v => fmtTime(v) },
  { key: 'resource_id', label: 'resource' }, { key: 'kind', label: 'change' }, { key: 'subject', label: 'of' },
  { key: 'old_value', label: 'from' }, { key: 'new_value', label: 'to', wide: true },
];

// pivot: the long series (snapshot_at, resource_id, value) of one metric as chart rows, oldest first, one column a resource
function pivot(rows: Row[], metric: string): { rows: Row[]; ids: string[] } {
  const by = new Map<string, Row>();
  const ids = new Set<string>();
  for (const r of rows) {
    if (r.metric !== metric) continue;
    const at = String(r.snapshot_at), id = String(r.resource_id);
    ids.add(id);
    const row = by.get(at) ?? { snapshot_at: at };
    row[id] = r.value;
    by.set(at, row);
  }
  return { rows: [...by.values()].sort((a, b) => Date.parse(String(a.snapshot_at)) - Date.parse(String(b.snapshot_at))), ids: [...ids].sort() };
}

// hasCloudReplicas: whether the instance's provider replicas were read (the shell's check for the block)
export async function hasCloudReplicas(instance: number): Promise<boolean> {
  const d = await get<Parts>('cloud/replicas', { instance, part: 'read' });
  return rowsOf(d.read)[0]?.has === true;
}

export async function cloudReplicasBlock(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { id: 'cloudreplicas' }, el('h3', {}, 'Replicas (provider)'));
  const d = await get<Parts>('cloud/replicas', { instance: ctx.instance, ...window_(ctx) });
  const read = rowsOf(d.read)[0], resources = rowsOf(d.resources), findings = rowsOf(d.findings);
  if (!read || read.has !== true) {
    // an instance with no door says nothing here (the block is an RDS or Cloud SQL instance's, opened in its config)
    if (read?.run_status == null) return el('span');
    sec.append(el('p', { class: 'empty' }, read.run_status === 'skipped' ? `The provider replicas are skipped: ${String(read.run_note ?? '')}.`
      : read.run_status === 'error' ? `The provider replica read failed: ${String(read.run_note ?? '')}.`
      : 'The provider replicas have not been read yet (every 5 minutes, through the provider\'s API).'));
    return sec;
  }
  if (findings.length) sec.append(el('h4', {}, 'Findings'), grid(findings, mssqlFindingCols));
  const replicas = resources.filter(r => r.role === 'replica');
  sec.append(el('div', { class: 'tiles' },
    tile('replicas', fmtNum(replicas.length)),
    tile('replication not normal', fmtNum(replicas.filter(r => replTone(r.repl_status) === 'crit').length),
      replicas.some(r => replTone(r.repl_status) === 'crit') ? 'crit' : ''),
  ));
  sec.append(props([
    ['provider', read.provider === 'aws' ? 'Amazon RDS' : 'Google Cloud SQL'],
    ['this instance\'s resource', String(read.resource_id ?? '')],
    ['last read', fmtTime(read.snapshot_at)],
    ...(Number(read.door_fails ?? 0) > 0 ? [['refused or failed calls', `${fmtNum(read.door_fails)} reads in a row since ${fmtTime(read.door_since)}: ${String(read.door_error ?? '')}`] as [string, string]] : []),
  ]));
  if (!resources.length) sec.append(el('p', { class: 'empty' }, 'The provider named no topology for this instance in its last read (see the refused calls above).'));
  else if (resources.length === 1 && resources[0].role === 'standalone') sec.append(el('p', { class: 'empty' }, 'No read replica: the provider names neither a source nor a replica of this instance.'));
  else sec.append(el('h4', {}, 'Source and replicas'), grid(resources, resourceCols(ctx)));
  const series = rowsOf(d.series);
  for (const [metric, title, fmt] of [['replica_lag', 'Replica lag (each to its direct source)', (v: number) => `${fmtNum(v)} s`],
    ['replica_byte_lag', 'Replica byte lag (Cloud SQL, replay)', (v: number) => `${fmtNum(v)} bytes`]] as [string, string, (v: number) => string][]) {
    const p = pivot(series, metric);
    if (p.rows.length) sec.append(lineChart(title, p.rows, p.ids.map(id => ({ key: id, label: id })), fmt));
  }
  sec.append(el('h4', {}, 'Changes'), grid(rowsOf(d.events), eventCols, 'No replica added, removed, promoted or changed status, and no provider failover, in this window.'));
  return sec;
}
