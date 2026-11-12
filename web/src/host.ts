// The Host tab (task 32): what the host is (OS, CPU, memory), its CPU, memory, load and device IO over the
// window, the volumes with their free share, and the host and disk checks; and the fleet Disk report at the
// root: every volume at or under a free-% threshold, the fullest first. Data from /api/host and /api/disks.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const pctTxt = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
// a volume's level: the Drives page's judgement of the same drive (drives_now's status: the threshold in force for it,
// task 176b: one rule), read into _drive_status by withDriveStatus; a volume the Drives page does not list is judged by
// the drive default, DBA Dash's (under 20 % free a warning, under 10 % critical)
const levelOf = (r: Row): string => r._drive_status === 'critical' ? 'crit' : r._drive_status === 'warning' ? 'warn' : r._drive_status === 'ok' ? 'ok'
  : r.free_pct == null ? '' : Number(r.free_pct) < 10 ? 'crit' : Number(r.free_pct) < 20 ? 'warn' : 'ok';
const freeTxt = (v: unknown, r: Row) => { const l = v == null ? '' : levelOf(r); return v == null ? '' : l === 'crit' || l === 'warn' ? badge(pctTxt(v), l) : pctTxt(v); };
// the free cells in the colour of that judgement, as the export writes them
const freeCls = (v: unknown, r: Row) => v == null || r.free_pct == null ? '' : levelOf(r);
// withDriveStatus: each volume row's drives_now status by instance and mount point (GET /api/drives, every status)
async function withDriveStatus(rows: Row[], instance?: number): Promise<Row[]> {
  try {
    const d = await get<Record<'drives', Table | null>>('drives', { status: 'all', ...(instance ? { instance } : {}) });
    const st = new Map(rowsOf(d.drives).map(x => [`${String(x.instance_id)}|${String(x.drive)}`, String(x.status)]));
    return rows.map((r): Row => ({ ...r, _drive_status: st.get(`${String(r.instance_id ?? instance)}|${String(r.mount_point)}`) }));
  } catch { return rows; }
}

const diskCols: Col[] = [
  { key: 'mount_point', label: 'volume' },
  { key: 'free_pct', label: 'free', num: true, fmt: freeTxt, cls: freeCls },
  { key: 'free_bytes', label: 'free size', num: true, fmt: fmtBytes, cls: freeCls },
  { key: 'used_bytes', label: 'used', num: true, fmt: fmtBytes },
  { key: 'total_bytes', label: 'size', num: true, fmt: fmtBytes },
  { key: 'holds_data', label: 'data directory', fmt: v => v ? 'yes' : '' },
  { key: 'device' },
  { key: 'fs_type', label: 'type' },
  { key: 'source', label: 'door' },
  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
];

export async function hostView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'latest' | 'disks' | 'series' | 'io' | 'checks', Table | null>>('host', { instance: ctx.instance, ...window_(ctx) });
  const h = rowsOf(d.latest)[0];
  const sec = el('section', {}, el('h2', {}, `Host (${rangeLabel(ctx)})`));
  if (!h) {
    sec.append(el('p', { class: 'empty' }, 'No host read yet. On-prem the host collection needs the system_stats extension in the database pgvigil connects to and '
      + 'GRANT monitor_system_stats to its login; on RDS / Aurora an aws: block in the config. Without either door it is skipped (Configuration shows why).'));
    return sec;
  }
  const cloud = h.source === 'cloudwatch';
  // the swap check's thresholds (0021 host_checks): RDS / Aurora over 1 GB; on-prem over 5 % of the swap and over 256 MB
  const sw = Number(h.swap_used ?? 0);
  const swapHigh = cloud ? sw > 2 ** 30 : sw > 0.05 * Number(h.swap_total ?? 0) && sw > 256 * 2 ** 20;
  const memUsedPct = h.mem_total ? 100 * Number(h.mem_used) / Number(h.mem_total) : null;
  sec.append(el('div', { class: 'tiles' },
    tile('CPU', h.cpu_pct == null ? '-' : fmtNum(h.cpu_pct) + ' %', Number(h.cpu_pct) > 90 ? 'warn' : ''),
    cloud ? tile('freeable memory', fmtBytes(h.mem_free) || '-')
      : tile('memory used', memUsedPct == null ? '-' : fmtNum(Math.round(memUsedPct)) + ' %'),
    tile('swap used', fmtBytes(h.swap_used) || '-', swapHigh ? 'warn' : ''),
    cloud ? tile('connections', fmtNum(h.connections) || '-') : tile('load (1 min)', fmtNum(h.load1) || '-'),
  ));
  const pairs: [string, string | Node][] = [
    ['door', cloud ? `CloudWatch (${String(h.aws_resource ?? '')})` : `system_stats ${String(h.extension_version ?? '')}`],
    ['operating system', String(h.os_name ?? '')],
  ];
  if (h.os_version) pairs.push([cloud ? 'instance class' : 'kernel', String(h.os_version)]);
  if (!cloud) {
    pairs.push(['architecture', String(h.architecture ?? '')], ['host name', String(h.host_name ?? '')],
      ['CPU', `${String(h.cpu_model ?? '')}${h.cpu_cores ? `, ${fmtNum(h.cpu_cores)} cores` : ''}${h.logical_cpus ? `, ${fmtNum(h.logical_cpus)} logical` : ''}`],
      ['memory', fmtBytes(h.mem_total)], ['swap', fmtBytes(h.swap_total)], ['up for', fmtSecs(h.uptime_secs)]);
  }
  pairs.push(['sample', fmtTime(h.snapshot_at) + (h.metrics_at ? ` (CloudWatch datapoint ${fmtTime(h.metrics_at)})` : '')]);
  sec.append(props(pairs));

  const checks = rowsOf(d.checks);
  if (checks.length) {
    sec.append(el('h3', {}, 'Checks'), grid(checks, [
      { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'check' }, { key: 'object' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
    ]));
  }
  sec.append(el('h3', {}, 'Volumes'), grid(await withDriveStatus(rowsOf(d.disks).filter(r => r.is_present !== false), ctx.instance), diskCols, 'No volume read.'));

  const s = rowsOf(d.series), io = rowsOf(d.io);
  const charts = el('div', { class: 'charts' },
    lineChart('CPU %', s, cloud ? [{ key: 'cpu_pct', label: 'CPU' }]
      : [{ key: 'cpu_pct', label: 'total' }, { key: 'cpu_user_pct', label: 'user' }, { key: 'cpu_system_pct', label: 'system' }, { key: 'cpu_iowait_pct', label: 'IO wait' }]),
    lineChart('Memory', s, cloud ? [{ key: 'mem_free', label: 'freeable' }, { key: 'swap_used', label: 'swap used' }]
      : [{ key: 'mem_used', label: 'used' }, { key: 'mem_free', label: 'free' }, { key: 'swap_used', label: 'swap used' }], v => fmtBytes(v)),
    cloud ? lineChart('Connections', s, [{ key: 'connections', label: 'connections' }]) : lineChart('Load (1 min)', s, [{ key: 'load1', label: 'load' }]),
  );
  if (!cloud) {
    charts.append(
      lineChart('Device IO (bytes / s)', io, [{ key: 'read_bytes_s', label: 'read' }, { key: 'write_bytes_s', label: 'write' }], v => fmtBytes(v)),
      lineChart('Device IO time per operation (ms, worst device)', io, [{ key: 'read_ms_per_op', label: 'read' }, { key: 'write_ms_per_op', label: 'write' }]));
  }
  sec.append(charts);
  return sec;
}

// diskReportView: the fleet's volumes at or under the chosen free % (keep narrows it to a tag folder;
// instLink makes the instance name a link to its Host tab).
export async function diskReportView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Disk report'));
  const body = el('div');
  const pick = el('select', { 'aria-label': 'free space threshold' }, ...[10, 20, 50, 100].map(n => el('option', n === 20 ? { value: String(n), selected: '' } : { value: String(n) },
    n === 100 ? 'every volume' : `${n} % free or less`)));
  const cols: Col[] = [
    { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
    { key: 'platform' },
    ...diskCols,
  ];
  async function draw() {
    try {
      let rows = rowsOf(await get('disks', { under: pick.value }));
      if (keep) rows = rows.filter(keep);
      rows = await withDriveStatus(rows);
      body.replaceChildren(el('p', { class: 'meta' }, `${rows.length} volume(s). Each is judged by its drive threshold (the Drives page's: by default under 20 % free a warning, under 10 % critical). `
        + 'On-prem volumes come from system_stats, RDS storage from CloudWatch; an Aurora cluster volume grows by itself (Storage).'),
        grid(rows, cols, 'No volume at or under this free share.'));
    } catch (e) {
      body.replaceChildren(el('p', { class: 'error' }, 'Error: ' + (e instanceof Error ? e.message : String(e))));
    }
  }
  pick.addEventListener('change', () => { void draw(); });
  sec.append(el('p', {}, 'Show ', pick), body);
  await draw();
  return sec;
}
