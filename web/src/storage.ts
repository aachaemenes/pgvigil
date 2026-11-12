// The Storage tab and the fleet Storage root (task 45; DBADash's drives view): every volume with its free
// space, its growth per day over 7 and 30 days and the days until it is full; the RDS volume against its
// autoscaling maximum and the Aurora cluster volume against 128 TiB; the WAL directory, the tablespaces, the
// temporary files; each database's growth and days to double, the fastest-growing tables; at the root the
// fleet's volumes, the soonest full first, and the repository's own size. Data from /api/storage and
// /api/storage/fleet.
import { get, Row, rowsOf, Table } from './api';
import { donutChart, lineChart, volumeBars } from './chart';
import { series } from './dbinfo';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtBytes, fmtNum, fmtTime, grid, props, tile } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const pctTxt = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
// a volume's free per cent judged as the Drives page judges it (drives_now's status: the threshold in force, task 176)
const lvlOf = (r: Row) => r.status === 'critical' ? 'crit' : r.status === 'warning' ? 'warn' : r.status === 'ok' ? 'ok' : '';
const freeTxt = (v: unknown, r: Row) => v == null ? '' : lvlOf(r) === 'crit' || lvlOf(r) === 'warn' ? badge(pctTxt(v), lvlOf(r)) : pctTxt(v);
// the free cells in the colour of the volume's threshold (the root's, a tag's, the instance's or its own; 10 / 5 by default), as the export writes them
const freeCls = (v: unknown, r: Row) => v == null || r.free_pct == null ? '' : lvlOf(r);
const perDay = (v: unknown) => v == null ? 'too little history' : (Number(v) < 0 ? '-' + fmtBytes(-Number(v)) : fmtBytes(v)) + ' / day';
// a forecast past ten years is not a date anyone plans to
const dayTxt = (v: unknown) => Number(v) > 3650 ? 'over 10 years' : fmtNum(v) + ' days';
const days = (v: unknown) => v == null ? '' : Number(v) > 3650 ? dayTxt(v) : Number(v) < 7 ? badge(fmtNum(v) + ' days', 'crit') : Number(v) < 30 ? badge(fmtNum(v) + ' days', 'warn') : fmtNum(v) + ' days';
// 'full in' in its own rule's colour (under 7 days critical, under 30 a warning, else OK); a forecast past ten years is not judged (grey)
const daysCls = (v: unknown) => v == null ? '' : Number(v) > 3650 ? 'status none' : Number(v) < 7 ? 'crit' : Number(v) < 30 ? 'warn' : 'ok';
const volName = (v: unknown, r: Row) => String(v ?? '') + (r.holds_data ? ' (data)' : '')
  + (r.kind === 'rds' && r.autoscaling ? (r.at_maximum ? ' (autoscaling at its maximum)' : ' (autoscaling)') : '');

const volCols: Col[] = [
  { key: 'volume', fmt: volName },
  { key: 'days_until_full', label: 'full in', num: true, fmt: days, cls: daysCls },
  { key: 'free_pct', label: 'free', num: true, fmt: freeTxt, cls: freeCls },
  { key: 'free_bytes', label: 'free size', num: true, fmt: fmtBytes, cls: freeCls },
  { key: 'used_bytes', label: 'used', num: true, fmt: fmtBytes },
  { key: 'total_bytes', label: 'size', num: true, fmt: fmtBytes },
  { key: 'capacity_bytes', label: 'grows to', num: true, fmt: (v, r) => v != null && v !== r.total_bytes ? fmtBytes(v) : '' },
  { key: 'headroom_bytes', label: 'room left', num: true, fmt: fmtBytes },
  { key: 'growth_7d_per_day', label: 'growth (7 d)', num: true, fmt: perDay },
  { key: 'growth_30d_per_day', label: 'growth (30 d)', num: true, fmt: perDay },
  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
];

export async function storageView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'volumes' | 'objects' | 'databases' | 'tables' | 'series' | 'temp' | 'checks', Table | null>>('storage', { instance: ctx.instance, ...window_(ctx) });
  const vols = rowsOf(d.volumes), objs = rowsOf(d.objects), temp = rowsOf(d.temp)[0] ?? {};
  const wal = objs.find(o => o.kind === 'wal'), rds = objs.find(o => o.kind === 'rds'), aur = objs.find(o => o.kind === 'aurora_volume');
  const soonest = vols.find(v => v.days_until_full != null);
  const sec = el('section', {}, el('h2', {}, `Storage (${rangeLabel(ctx)})`));
  sec.append(el('div', { class: 'tiles' },
    tile('soonest full', soonest ? dayTxt(soonest.days_until_full) : 'not growing',
      soonest ? (Number(soonest.days_until_full) < 7 ? 'crit' : Number(soonest.days_until_full) < 30 ? 'warn' : '') : ''),
    tile('WAL directory', wal ? fmtBytes(wal.size_bytes) : '-'),
    tile('temp files (24 h)', temp.temp_bytes_24h == null ? '-' : fmtBytes(temp.temp_bytes_24h)),
    tile('databases', fmtBytes(rowsOf(d.databases).reduce((a, r) => a + Number(r.size_bytes ?? 0), 0))),
  ));

  // volumes as bars, used against size (DBA Dash's drive bars); the databases as a pie of what each holds; then
  // the growth of a chosen number of days
  const pies = el('div', { class: 'charts' });
  const bars = volumeBars('Volumes', vols.filter(v => v.used_bytes != null && v.free_bytes != null)
    .map(v => ({ name: String(v.volume ?? ''), used: Number(v.used_bytes), free: Number(v.free_bytes), note: v.holds_data ? '(data)' : undefined, status: v.status == null ? undefined : String(v.status) })), fmtBytes);
  pies.append(donutChart('Databases by size',
    rowsOf(d.databases).map(r => ({ label: String(r.datname ?? ''), value: Number(r.size_bytes ?? 0) })), fmtBytes));
  sec.append(el('h3', {}, 'Space at a glance'), bars, pies, growthPanel(ctx));

  const checks = rowsOf(d.checks);
  if (checks.length) {
    sec.append(el('h3', {}, 'Checks'), grid(checks, [
      // 0033's 'volume under 10 % free' is the headroom against the volume's capacity (RDS autoscaling), not the drive
      // threshold: shown as such (the check's key stays for alert rules and acknowledgements)
      { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'check', fmt: v => v === 'volume under 10 % free' ? 'capacity headroom under 10 %' : String(v ?? '') }, { key: 'object' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
    ]));
  }
  sec.append(el('h3', {}, 'Volumes'),
    el('p', { class: 'meta' }, 'Days until full: the space left over the growth per day, at the 7- and the 30-day line, the sooner shown. '
      + 'A growth line needs a day (7 d) or a week (30 d) of history. On-prem volumes come from system_stats (the Host tab); '
      + 'an RDS volume with storage autoscaling is measured to its maximum; the Aurora cluster volume to 128 TiB.'),
    grid(vols, volCols, 'No volume read: on-prem the host collection needs system_stats; RDS and Aurora an aws: block.'));

  if (rds || aur) {
    const pairs: [string, string | Node][] = [];
    if (rds) {
      pairs.push(['RDS allocated', fmtBytes(rds.allocated_bytes)],
        ['storage autoscaling', rds.autoscaling ? (rds.at_maximum ? `on, at its maximum of ${fmtBytes(rds.max_allocated_bytes)}` : `on, up to ${fmtBytes(rds.max_allocated_bytes)}`) : 'off'],
        ['storage type', `${String(rds.storage_type ?? '')}${rds.iops ? `, ${fmtNum(rds.iops)} IOPS` : ''}${rds.throughput ? `, ${fmtNum(rds.throughput)} MiB/s` : ''}`]);
    }
    if (aur) {
      pairs.push(['Aurora cluster volume', `${fmtBytes(aur.size_bytes)} of ${fmtBytes(aur.limit_bytes)} (${fmtNum(aur.limit_pct)} %)`],
        ['VolumeBytesUsed at', fmtTime(aur.metrics_at)]);
    }
    sec.append(el('h3', {}, 'Platform storage'), props(pairs));
  }

  sec.append(el('h3', {}, 'Databases'), grid(rowsOf(d.databases), [
    { key: 'datname', label: 'database' },
    { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
    { key: 'growth_7d_per_day', label: 'growth (7 d)', num: true, fmt: perDay },
    { key: 'growth_30d_per_day', label: 'growth (30 d)', num: true, fmt: perDay },
    { key: 'days_to_double', label: 'doubles in', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' days' },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ], 'No database read yet: the databases collection runs hourly.'));

  const tabs = rowsOf(d.tables);
  if (tabs.length) {
    sec.append(el('h3', {}, 'Fastest-growing tables (7 days)'), grid(tabs, [
      { key: 'datname', label: 'db' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
      { key: 'total_bytes', label: 'size', num: true, fmt: fmtBytes },
      { key: 'growth_7d_per_day', label: 'growth', num: true, fmt: perDay },
      { key: 'days_to_double', label: 'doubles in', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' days' },
    ]));
  }

  sec.append(el('h3', {}, 'WAL and tablespaces'), grid(objs.filter(o => o.kind === 'wal' || o.kind === 'tablespace'), [
    { key: 'name' }, { key: 'kind' }, { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
    { key: 'files', label: 'WAL files', num: true }, { key: 'location' }, { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ], 'No storage read yet: the storage collection runs every 15 minutes.'));
  const s = rowsOf(d.series);
  sec.append(el('div', { class: 'charts' },
    lineChart('WAL directory', s, [{ key: 'wal_bytes', label: 'pg_wal' }], v => fmtBytes(v)),
    lineChart(aur ? 'Aurora cluster volume' : 'Tablespaces', s,
      aur ? [{ key: 'aurora_volume_bytes', label: 'VolumeBytesUsed' }] : [{ key: 'tablespace_bytes', label: 'all tablespaces' }], v => fmtBytes(v))));
  return sec;
}

// growthPanel: the days selector (7 to 365) over the database sizes: the size lines of the window, a ring of the
// growth each database holds in it, and the numbers. The sizes are read hourly (/api/dbinfo's series of the largest
// databases); a window longer than the history says how many days it really has.
const growthDays = [7, 30, 90, 180, 365];
function growthPanel(ctx: Ctx): HTMLElement {
  const out = el('div', {});
  const buttons = growthDays.map(n => el('button', { type: 'button', 'aria-pressed': 'false' }, `${n} days`));
  let asked = 0;
  const show = async (n: number, b: HTMLButtonElement) => {
    buttons.forEach(x => x.setAttribute('aria-pressed', x === b ? 'true' : 'false'));
    const mine = ++asked, to = new Date();
    out.replaceChildren(el('p', { class: 'meta' }, 'Reading the sizes...'));
    let d: Record<'db_series', Table | null>;
    try {
      d = await get<Record<'db_series', Table | null>>('dbinfo',
        { instance: ctx.instance, part: 'db_series', from: new Date(to.getTime() - n * 86400e3).toISOString(), to: to.toISOString() });
    } catch (e) {
      if (mine === asked) out.replaceChildren(el('p', { class: 'empty' }, 'The sizes could not be read: ' + String((e as Error).message ?? e)));
      return;
    }
    if (mine !== asked) return;          // a later click answered first
    const ds = series(rowsOf(d.db_series), r => String(r.datname), 'size_bytes');
    if (ds.rows.length < 2) { out.replaceChildren(el('p', { class: 'empty' }, 'Not enough size history yet: the databases collection runs hourly.')); return; }
    const t0 = Date.parse(String(ds.rows[0].snapshot_at)), t1 = Date.parse(String(ds.rows[ds.rows.length - 1].snapshot_at));
    const span = Math.max((t1 - t0) / 86400e3, 1 / 24);
    const rows: Row[] = ds.series.map(x => {
      const vals = ds.rows.map(r => r[x.key]).filter(v => v != null).map(Number);
      const first = vals[0], last = vals[vals.length - 1];
      return { datname: x.label, first_bytes: first, last_bytes: last, grown_bytes: last - first, per_day: (last - first) / span };
    });
    out.replaceChildren(
      el('p', { class: 'meta' }, `The largest ${ds.series.length} databases over ${fmtNum(span)} days of history`
        + (span < n - 1 ? ` (the ${n}-day window holds no more yet)` : '') + '. Grown: the newest size minus the oldest of the window.'),
      el('div', { class: 'charts' },
        lineChart(`Database sizes, ${n} days`, ds.rows, ds.series, v => fmtBytes(v), { ownSpan: true }),
        donutChart(`Growth by database, ${n} days`, rows.map(r => ({ label: String(r.datname), value: Number(r.grown_bytes) })), fmtBytes,
          8, false, 'No database grew in this window.')),
      el('h4', {}, `Database growth, ${n} days`),
      grid(rows, [
        { key: 'datname', label: 'database' },
        { key: 'first_bytes', label: 'at the start', num: true, fmt: fmtBytes },
        { key: 'last_bytes', label: 'now', num: true, fmt: fmtBytes },
        { key: 'grown_bytes', label: 'grown', num: true, fmt: fmtBytes },
        { key: 'per_day', label: 'per day', num: true, fmt: fmtBytes },
      ]));
  };
  buttons.forEach((b, i) => b.addEventListener('click', () => { void show(growthDays[i], b); }));
  const box = el('div', {}, el('h3', {}, 'Database growth'),
    el('div', { class: 'seg', role: 'group', 'aria-label': 'Days of growth' }, el('span', { class: 'meta' }, 'Window:'), ...buttons), out);
  void show(30, buttons[1]);
  return box;
}

// storageFleetView: the fleet's volumes, the soonest full first (keep narrows it to a tag folder; instLink makes
// the instance name a link to its Storage tab), and the repository's own size.
export async function storageFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const d = await get<Record<'volumes' | 'repository', Table | null>>('storage/fleet');
  let rows = rowsOf(d.volumes);
  if (keep) rows = rows.filter(keep);
  const repo = rowsOf(d.repository)[0] ?? {};
  const soon = rows.filter(r => r.days_until_full != null && Number(r.days_until_full) < 30).length;
  const low = rows.filter(r => r.headroom_pct != null && Number(r.headroom_pct) < 10).length;
  return el('section', {}, el('h2', {}, 'Storage'),
    el('div', { class: 'tiles' },
      tile('volumes', String(rows.length)),
      tile('full within 30 days', String(soon), soon ? 'warn' : 'ok'),
      tile('under 10 % free', String(low), low ? 'warn' : 'ok'),
      tile('repository', fmtBytes(repo.database_bytes) || '-')),
    el('p', { class: 'meta' }, 'Every volume of the fleet, the soonest full first. '
      + `The repository (this database) holds ${fmtBytes(repo.schema_bytes) || '-'} of pgvigil tables, ${fmtBytes(repo.history_bytes) || '-'} of it monthly history partitions.`),
    grid(rows, [
      { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
      { key: 'platform' },
      ...volCols,
    ], 'No volume read yet.'));
}
