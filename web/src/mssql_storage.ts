// The Storage and Database files tabs of a SQL Server instance (task 99; the SQL Server side of the storage rings,
// DBA Dash's pie charts): a ring per volume of used against free, a ring of the space each database holds on the
// instance, a ring of each file within a database, each slice with its size and share in the table beside it; a days
// selector (7 to 365) that redraws the size lines, the ring of growth and the growth figures; every volume, database
// and file in a grid. Data from /api/mssql/storage (mssql_storage, read hourly).
import { get, Row, rowsOf, Table } from './api';
import { donutChart, lineChart, volumeBars } from './chart';
import { hashParam, hrefWith, series } from './dbinfo';
import { Ctx, window_ } from './router';
import { badge, Col, el, fmtBytes, fmtNum, fmtTime, grid, tile } from './ui';

// The tab keys of the slice's pages (the router's entries carry the same keys).
export const mssqlStorageTab = 'mssqlstorage';
export const mssqlFilesTab = 'mssqlfiles';

type Parts = Record<'volumes' | 'databases' | 'files' | 'series' | 'checks', Table | null>;

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const pctTxt = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';
// a volume's free per cent judged as the Drives page judges it (drives_now's status: the threshold in force, task 176)
const lvlOf = (r: Row) => r.status === 'critical' ? 'crit' : r.status === 'warning' ? 'warn' : r.status === 'ok' ? 'ok' : '';
const freeTxt = (v: unknown, r: Row) => v == null ? '' : lvlOf(r) === 'crit' || lvlOf(r) === 'warn' ? badge(pctTxt(v), lvlOf(r)) : pctTxt(v);
// the free cells in the colour of the volume's threshold (the root's, a tag's, the instance's or its own; DBA Dash's 20 / 10 by default), as the export writes them
const freeCls = (v: unknown, r: Row) => v == null || r.free_pct == null ? '' : lvlOf(r);
const signed = (v: unknown) => v == null ? 'too little history' : Number(v) < 0 ? '-' + fmtBytes(-Number(v)) : '+' + fmtBytes(v);
const perDay = (v: unknown) => v == null ? 'too little history' : (Number(v) < 0 ? '-' + fmtBytes(-Number(v)) : fmtBytes(v)) + ' / day';
// a file's growth step: a size, a per cent of the file, or none
const growthTxt = (_v: unknown, r: Row) => Number(r.growth_pct) > 0 ? `${fmtNum(r.growth_pct)} %`
  : Number(r.growth_bytes) > 0 ? fmtBytes(r.growth_bytes) : 'does not grow';
const maxTxt = (v: unknown) => v == null ? 'until the volume is full' : fmtBytes(v);
const usedTxt = (v: unknown, r: Row) => r.used_read ? fmtBytes(v) : el('span', { class: 'meta', title: String(r.used_note ?? '') }, 'used not read');

const checkCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'check' }, { key: 'object' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
];

const volCols: Col[] = [
  { key: 'volume' },
  { key: 'logical_name', label: 'label' },
  { key: 'free_pct', label: 'free', num: true, fmt: freeTxt, cls: freeCls },
  { key: 'free_bytes', label: 'free size', num: true, fmt: fmtBytes, cls: freeCls },
  { key: 'used_bytes', label: 'used', num: true, fmt: fmtBytes },
  { key: 'total_bytes', label: 'size', num: true, fmt: fmtBytes },
  { key: 'files', label: 'database files', num: true },
  { key: 'file_system', label: 'file system' },
  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
];

function dbCols(ctx: Ctx): Col[] {
  return [
    { key: 'database_name', label: 'database', fmt: v => el('a', { href: hrefWith(ctx, mssqlFilesTab, { db: String(v ?? '') }) }, String(v ?? '')) },
    { key: 'database_state', label: 'state' },
    { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
    { key: 'data_bytes', label: 'data files', num: true, fmt: fmtBytes },
    { key: 'log_bytes', label: 'log files', num: true, fmt: fmtBytes },
    { key: 'used_bytes', label: 'used inside', num: true, fmt: usedTxt },
    { key: 'files', num: true },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ];
}

// mssqlStorageView is the Storage tab of a SQL Server instance.
export async function mssqlStorageView(ctx: Ctx): Promise<HTMLElement> {
  const [d, depth] = await Promise.all([get<Parts>('mssql/storage', { instance: ctx.instance, days: 30 }),
    depthGet(ctx, { parts: 'forecast,space,tempdb,tempdb_series,growth,tables_read,paths,drives,orphans,checks,runs,pending' })]);
  const vols = withForecast(rowsOf(d.volumes), depth), dbs = rowsOf(d.databases), checks = rowsOf(d.checks);
  const sum = (k: string) => dbs.reduce((a, r) => a + Number(r[k] ?? 0), 0);
  const lowest = vols.filter(v => v.free_pct != null).sort((a, b) => Number(a.free_pct) - Number(b.free_pct))[0];
  const sec = el('section', {}, el('h2', {}, 'Storage'));
  sec.append(el('div', { class: 'tiles' },
    tile('databases', String(dbs.length)),
    tile('data files', fmtBytes(sum('data_bytes')) || '-'),
    tile('log files', fmtBytes(sum('log_bytes')) || '-'),
    tile('least free volume', lowest ? `${pctTxt(lowest.free_pct)} on ${String(lowest.volume)}` : '-',
      lowest ? (lvlOf(lowest) === 'ok' ? '' : lvlOf(lowest)) : ''),
  ));
  if (!dbs.length) {
    // the depth's own sections were read apart from the files (IO, tempdb, the counters) and say for themselves what was not
    sec.append(el('p', { class: 'empty' }, 'No file read yet: the mssql_storage collection runs hourly and needs VIEW ANY DEFINITION.'),
      ...await storageDepthSections(ctx, depth));
    return sec;
  }

  // volumes as bars, used against size; the databases as a pie of what each holds; then the growth of a chosen number of days
  const pies = el('div', { class: 'charts' });
  const bars = volumeBars('Volumes', vols.filter(v => v.used_bytes != null && v.free_bytes != null)
    .map(v => ({ name: String(v.volume ?? ''), used: Number(v.used_bytes), free: Number(v.free_bytes), status: v.status == null ? undefined : String(v.status) })), fmtBytes);
  pies.append(donutChart('Databases by size', dbs.map(r => ({ label: String(r.database_name ?? ''), value: Number(r.size_bytes ?? 0),
    href: hrefWith(ctx, mssqlFilesTab, { db: String(r.database_name ?? '') }) })), fmtBytes));
  pies.append(donutChart('Data against log', [{ label: 'data files', value: sum('data_bytes') }, { label: 'log files', value: sum('log_bytes') }], fmtBytes, 8, true));
  sec.append(el('h3', {}, 'Space at a glance'), bars, pies, growthPanel(ctx, d));

  if (checks.length) sec.append(el('h3', {}, 'Checks'), grid(checks, checkCols));
  sec.append(el('h3', {}, 'Volumes'),
    el('p', { class: 'meta' }, 'The volumes the database files sit on, as the server reads them (sys.dm_os_volume_stats). '
      + 'A SQL Server on Linux names no mount point: the files\' directory stands for the volume, and two directories on one file system show the same size and free space.'),
    grid(vols, [...volCols.slice(0, 5), ...forecastCols, ...volCols.slice(5)], 'No volume read: the login needs VIEW SERVER STATE for the volumes\' total and free space.'));
  sec.append(el('h3', {}, 'Databases'),
    el('p', { class: 'meta' }, 'A database\'s name opens its files. Used inside: the space in use within the files, read where the login can enter the database.'),
    grid(dbs, dbCols(ctx)));
  sec.append(...await storageDepthSections(ctx, depth));
  return sec;
}

// growthPanel: the days selector over the database sizes: the size lines of the window, a ring of the growth each
// database holds in it, and the figures. A window longer than the history says how many days it really has.
const growthDays = [7, 30, 90, 180, 365];
function growthPanel(ctx: Ctx, first: Parts): HTMLElement {
  const out = el('div', {});
  const buttons = growthDays.map(n => el('button', { type: 'button', 'aria-pressed': 'false' }, `${n} days`));
  let asked = 0;
  const show = async (n: number, b: HTMLButtonElement) => {
    buttons.forEach(x => x.setAttribute('aria-pressed', x === b ? 'true' : 'false'));
    const mine = ++asked;
    out.replaceChildren(el('p', { class: 'meta' }, 'Reading the sizes...'));
    let d: Parts;
    try {
      // the tab's own read is the 30-day one: the first draw reuses it
      d = n === 30 && mine === 1 ? first : await get<Parts>('mssql/storage', { instance: ctx.instance, days: n });
    } catch (e) {
      if (mine === asked) out.replaceChildren(el('p', { class: 'empty' }, 'The sizes could not be read: ' + String((e as Error).message ?? e)));
      return;
    }
    if (mine !== asked) return;          // a later click answered first
    const dbs = rowsOf(d.databases).filter(r => r.first_at != null);
    const ds = series(rowsOf(d.series), r => String(r.database_name), 'size_bytes');
    if (!dbs.length || ds.rows.length < 2) {
      out.replaceChildren(el('p', { class: 'empty' }, 'Not enough size history yet: the mssql_storage collection runs hourly.'));
      return;
    }
    const oldest = Math.min(...dbs.map(r => Date.parse(String(r.first_at))));
    const span = Math.max((Date.now() - oldest) / 86400e3, 1 / 24);
    const vols = rowsOf(d.volumes).filter(v => v.first_at != null);
    out.replaceChildren(
      el('p', { class: 'meta' }, `${fmtNum(span)} days of history` + (span < n - 1 ? ` (the ${n}-day window holds no more yet)` : '')
        + '. Grown: the size now minus the oldest size of the window; the lines are the eight largest databases.'),
      el('div', { class: 'charts' },
        lineChart(`Database sizes, ${n} days`, ds.rows, ds.series, v => fmtBytes(v), { ownSpan: true }),
        donutChart(`Growth by database, ${n} days`, dbs.map(r => ({ label: String(r.database_name), value: Number(r.grown_bytes ?? 0),
          href: hrefWith(ctx, mssqlFilesTab, { db: String(r.database_name ?? '') }) })), fmtBytes,
          8, false, 'No database grew in this window.')),
      el('details', {}, el('summary', {}, `Database sizes, ${n} days: the numbers`),
        grid(ds.rows, [{ key: 'snapshot_at', label: 'at', fmt: fmtTime }, ...ds.series.map(x => ({ key: x.key, label: x.label, num: true, fmt: fmtBytes }))])),
      el('h4', {}, `Database growth, ${n} days`),
      grid(dbs, [
        { key: 'database_name', label: 'database' },
        { key: 'first_bytes', label: 'at the start', num: true, fmt: fmtBytes },
        { key: 'size_bytes', label: 'now', num: true, fmt: fmtBytes },
        { key: 'grown_bytes', label: 'grown', num: true, fmt: signed },
        { key: 'per_day', label: 'per day', num: true, fmt: perDay },
        { key: 'first_at', label: 'history from', fmt: fmtTime },
      ]),
      el('h4', {}, `Volume growth, ${n} days`),
      grid(vols, [
        { key: 'volume' },
        { key: 'used_bytes', label: 'used now', num: true, fmt: fmtBytes },
        { key: 'grown_bytes', label: 'used grew by', num: true, fmt: signed },
        { key: 'per_day', label: 'per day', num: true, fmt: perDay },
        { key: 'free_bytes', label: 'free now', num: true, fmt: fmtBytes },
        { key: 'first_at', label: 'history from', fmt: fmtTime },
      ], 'No volume history yet.'));
  };
  buttons.forEach((b, i) => b.addEventListener('click', () => { void show(growthDays[i], b); }));
  const box = el('div', {}, el('h3', {}, 'Database growth'),
    el('div', { class: 'seg', role: 'group', 'aria-label': 'Days of growth' }, el('span', { class: 'meta' }, 'Window:'), ...buttons), out);
  void show(30, buttons[1]);
  return box;
}

const fileCols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'file_name', label: 'file' },
  { key: 'type_desc', label: 'type', fmt: v => String(v ?? '').toLowerCase() },
  { key: 'filegroup' },
  { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
  { key: 'used_bytes', label: 'used', num: true, fmt: usedTxt },
  { key: 'free_in_file_bytes', label: 'free in the file', num: true, fmt: (v, r) => r.used_read ? fmtBytes(v) : '' },
  { key: 'max_size_bytes', label: 'max size', num: true, fmt: maxTxt },
  { key: 'growth_bytes', label: 'growth', num: true, fmt: growthTxt },
  { key: 'volume' },
  { key: 'state_desc', label: 'state', fmt: v => String(v ?? '').toLowerCase() },
  { key: 'size_changed_at', label: 'size changed', fmt: (v, r) => v == null ? '' : `${fmtTime(v)} (was ${fmtBytes(r.previous_size_bytes)})` },
  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  { key: 'physical_name', label: 'path' },
];

// mssqlFilesView is the Database files tab: one database's files as rings and a grid (?db=<name>; the largest
// database when none is named), with a selector of the instance's databases and every file below.
export async function mssqlFilesView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Pick<Parts, 'databases' | 'files' | 'checks'>>('mssql/storage', { instance: ctx.instance, days: 30 });
  const dbs = rowsOf(d.databases), all = rowsOf(d.files);
  const sec = el('section', {}, el('h2', {}, 'Database files'));
  if (!all.length) {
    sec.append(el('p', { class: 'empty' }, 'No file read yet: the mssql_storage collection runs hourly and needs VIEW ANY DEFINITION.'));
    return sec;
  }
  const asked = hashParam('db');
  const db = dbs.find(r => r.database_name === asked) ?? dbs[0];
  const name = String(db?.database_name ?? '');
  const pick = el('select', { id: 'mssql-files-db' }, ...dbs.map(r => {
    const o = el('option', { value: String(r.database_name) }, `${String(r.database_name)} (${fmtBytes(r.size_bytes)})`);
    if (r.database_name === name) o.selected = true;
    return o;
  }));
  pick.addEventListener('change', () => { location.hash = hrefWith(ctx, mssqlFilesTab, { db: pick.value }); });
  sec.append(el('p', {}, el('label', { for: 'mssql-files-db' }, 'Database '), pick));
  if (asked && asked !== name) sec.append(el('p', { class: 'meta' }, `No database named ${asked} was read on this instance; showing ${name}.`));

  const files = all.filter(f => f.database_name === name);
  const read = files.filter(f => f.used_read);
  const used = read.reduce((a, f) => a + Number(f.used_bytes ?? 0), 0), size = read.reduce((a, f) => a + Number(f.size_bytes ?? 0), 0);
  const pies = el('div', { class: 'charts' },
    donutChart(`Files of ${name} by size`, files.map(f => ({ label: `${String(f.file_name ?? f.file_id)} (${String(f.type_desc ?? '').toLowerCase()})`, value: Number(f.size_bytes ?? 0) })), fmtBytes, 12));
  if (read.length) {
    pies.append(donutChart(read.length === files.length ? `Used against free inside the files of ${name}` : `Used against free inside the ${read.length} file(s) read of ${name}`,
      [{ label: 'used', value: used }, { label: 'free in the files', value: Math.max(size - used, 0) }], fmtBytes, 8, true));
  } else {
    pies.append(el('div', { class: 'chart' }, el('h3', {}, `Used against free inside the files of ${name}`),
      el('p', { class: 'empty' }, String(files[0]?.used_note ?? 'used not read'))));
  }
  sec.append(pies);
  const checks = rowsOf(d.checks).filter(c => String(c.object ?? '') === name || String(c.object ?? '').startsWith(name + ': '));
  if (checks.length) sec.append(el('h3', {}, 'Checks'), grid(checks, checkCols));
  sec.append(el('h3', {}, `Files of ${name}`), grid(files, fileCols.slice(1)));
  sec.append(...await databaseDepthSections(ctx, name));
  sec.append(el('h3', {}, 'Every file of the instance'),
    el('p', { class: 'meta' }, 'Growth: the step the file grows by, a size or a per cent of the file. Max size: where growth stops. '
      + 'Used: the space in use inside the file; "used not read" where the login cannot enter the database (the cell\'s title says why).'),
    grid(all, fileCols));
  return sec;
}

// ---- task 407: storage depth (SQLWATCH, SQLMonitor, dbachecks, Telegraf, windows_exporter) ---------------------------
// Data from /api/mssql/storage_depth, /api/mssql/dbio and /api/mssql/counters. A part whose collection did not run says
// 'not read' and why, in grey; it is never shown as met.

type DepthParts = Record<'forecast' | 'space' | 'tempdb' | 'tempdb_series' | 'growth' | 'tables_read' | 'paths' | 'drives'
  | 'orphans' | 'checks' | 'runs' | 'pending' | 'space_series' | 'tables' | 'table_series', Table | null>;

async function depthGet(ctx: Ctx, extra: Record<string, string | number | undefined>): Promise<DepthParts | Error> {
  try {
    return await get<DepthParts>('mssql/storage_depth', { instance: ctx.instance, ...window_(ctx), ...extra });
  } catch (e) {
    return e instanceof Error ? e : new Error(String(e));
  }
}

// notRead: a grey line saying what was not read and why (a collector's note that already says 'not read: ' keeps one;
// a collection switched off says 'off', never 'not read')
const notRead = (why: string) => {
  const t = why.replace(/^not read: /, '');
  return el('p', { class: 'empty' }, t.startsWith('off: ') ? t : 'not read: ' + t);
};
// greyNA: a cell that was not read, grey, never blank and never green
const greyNA = (what = 'not read') => badge(what, '');

// the newest run of a collection as a reason, when it did not read: '' when it read; 'off: ...' when the instance's
// configuration switches it off (the rows shown, if any, are its last read)
function runGap(depth: DepthParts, collection: string, what: string): string {
  const r = rowsOf(depth.runs).find(x => x.collection === collection);
  if (r?.status === 'off') return `off: ${what} - ${collection} is switched off for this instance (its disabled list in pgvigil.yaml); what is shown is its last read`;
  if (!r || r.snapshot_at == null) return `${what}: ${collection} has not run on this instance yet`;
  if (r.status === 'skipped' || r.status === 'error' || r.status === 'failed') return `${what}: ${String(r.note ?? r.status)}`;
  return '';
}

// withForecast: the volumes with their growth per day and days until full (a Linux file system's directories each get its row)
function withForecast(vols: Row[], depth: DepthParts | Error): Row[] {
  if (depth instanceof Error) return vols.map(v => ({ ...v, forecast_read: false }));
  const by = new Map<string, Row>();
  for (const f of rowsOf(depth.forecast)) {
    by.set(String(f.volume), f);
    for (const dir of String(f.directories ?? '').split(', ').filter(Boolean)) by.set(dir, f);
  }
  return vols.map(v => {
    const f = by.get(String(v.volume));
    return f ? { ...v, growth_30d_per_day: f.growth_30d_per_day, growth_7d_per_day: f.growth_7d_per_day, days_until_full: f.days_until_full,
      days_until_full_7: f.days_until_full_7 } : { ...v, forecast_read: false };
  });
}

const daysTxt = (v: unknown, r: Row) => {
  if (r.forecast_read === false) return greyNA();
  if (v == null) return r.growth_30d_per_day == null ? 'too little history' : 'not filling';
  const n = Number(v);
  const t = `${fmtNum(n)} days`;
  return n < 7 ? badge(t, 'crit') : n < 30 ? badge(t, 'warn') : t;
};
const forecastCols: Col[] = [
  { key: 'growth_30d_per_day', label: 'growth / day (30 days)', num: true, fmt: (v, r) => r.forecast_read === false ? greyNA() : perDay(v) },
  { key: 'days_until_full', label: 'days until full', num: true, fmt: daysTxt },
  { key: 'days_until_full_7', label: 'at the 7-day rate', num: true, fmt: (v, r) => r.forecast_read === false ? greyNA() : v == null ? '' : `${fmtNum(v)} days` },
];

const pct = (v: unknown) => v == null ? '' : `${fmtNum(v)} %`;
const kb = (v: unknown) => v == null ? '' : fmtBytes(Number(v) * 1024);
const kbSigned = (v: unknown) => v == null ? '' : signed(Number(v) * 1024);

// storageDepthSections: the Storage tab's depth, after its own grids
async function storageDepthSections(ctx: Ctx, depth: DepthParts | Error): Promise<HTMLElement[]> {
  const out: HTMLElement[] = [];
  if (depth instanceof Error) return [el('h3', {}, 'Storage depth'), el('p', { class: 'empty' }, 'The storage depth could not be read: ' + depth.message)];
  const checks = rowsOf(depth.checks);
  // the checks' inputs: a collection that did not read leaves its checks unjudged, never 'none raised'
  const gaps = ([['mssql_storage', 'the files, volumes and space split'], ['mssql_versionstore', 'tempdb\'s pages'],
    ['mssql_storage_depth', 'the paths, drives and folders']] as [string, string][]).map(([c, w]) => runGap(depth, c, w)).filter(Boolean);
  out.push(el('h3', {}, 'Storage depth checks'), checks.length ? grid(checks, checkCols)
    : el('p', { class: 'meta' }, (gaps.length ? 'No storage depth check raised on what was read' : 'No storage depth check raised')
      + ' (a volume full within 30 days, tempdb data files filling, more than one log file, '
      + 'a file under 20 % free inside it, a filegroup unbalanced, a small growth step, model\'s growth, tempdb on C: or with a max size, '
      + 'the default paths on C:, an orphaned database file).'),
    ...gaps.map(g => notRead(g + ': its checks are not judged')));
  const platform = String(rowsOf(depth.paths)[0]?.host_platform ?? '');
  out.push(spaceSection(ctx, depth), tempdbSection(depth), await activitySection(ctx), tablesPanel(ctx, depth), await ioSection(ctx, depth), await bufferPoolSection(ctx),
    drivesSection(depth), hostDoorSection(platform));
  return out;
}

// the space inside each database: sp_spaceused's split, the data files' unallocated space, the log
function spaceSection(ctx: Ctx, depth: DepthParts): HTMLElement {
  const box = el('div', {}, el('h3', {}, 'Space inside the databases'));
  const gap = runGap(depth, 'mssql_storage', 'the space split');
  const rows = rowsOf(depth.space);
  if (!rows.some(r => r.snapshot_at != null)) {
    box.append(notRead(gap || 'no database\'s space split was read yet: mssql_storage reads it hourly where the login has VIEW SERVER STATE '
      + '(or VIEW SERVER PERFORMANCE STATE on 2022) and VIEW ANY DEFINITION'));
    if (!rows.length) return box;
  }
  const na = (f: (v: unknown) => string | Node) => (v: unknown, r: Row): string | Node => r.snapshot_at == null ? greyNA() : f(v);
  box.append(el('p', { class: 'meta' }, 'As sp_spaceused counts it (sys.dm_db_partition_stats): reserved pages hold data, indexes and unused space; '
    + 'unallocated is the data files\' space no object has yet. Memory-optimized tables keep no pages here.'),
    grid(rows, [
      { key: 'database_name', label: 'database', fmt: v => el('a', { href: hrefWith(ctx, mssqlFilesTab, { db: String(v ?? '') }) }, String(v ?? '')) },
      { key: 'data_bytes', label: 'data', num: true, fmt: na(fmtBytes) },
      { key: 'index_bytes', label: 'index', num: true, fmt: na(fmtBytes) },
      { key: 'unused_bytes', label: 'unused', num: true, fmt: na(fmtBytes) },
      { key: 'reserved_bytes', label: 'reserved', num: true, fmt: na(fmtBytes) },
      { key: 'unallocated_bytes', label: 'unallocated', num: true, fmt: na(fmtBytes) },
      { key: 'log_used_bytes', label: 'log used', num: true, fmt: v => v == null ? greyNA() : fmtBytes(v) },
      { key: 'log_size_bytes', label: 'log size', num: true, fmt: na(fmtBytes) },
      { key: 'snapshot_at', label: 'read', fmt: (v, r) => v == null ? String(r.not_read_note ?? 'not read in the last day').replace(/^used not read: /, 'not read: ') : fmtTime(v) },
    ]));
  return box;
}

// tempdb against what it can still grow to
function tempdbSection(depth: DepthParts): HTMLElement {
  const box = el('div', {}, el('h3', {}, 'tempdb: what fills it, against its capacity'));
  const gap = runGap(depth, 'mssql_versionstore', 'tempdb\'s pages');
  const c = rowsOf(depth.tempdb)[0];
  if (!c) {
    box.append(notRead(gap || 'no tempdb read yet: mssql_versionstore reads it every minute with VIEW SERVER STATE'));
    return box;
  }
  const lvl = c.used_pct == null ? '' : Number(c.used_pct) > 80 ? 'crit' : Number(c.used_pct) > 50 ? 'warn' : 'ok';
  box.append(el('div', { class: 'tiles' },
    tile('used of capacity', c.used_pct == null ? 'capacity not known' : pct(c.used_pct), lvl),
    tile('used', fmtBytes(c.used_bytes)),
    tile('capacity', c.capacity_bytes == null ? 'not known' : fmtBytes(c.capacity_bytes)),
    tile('user objects', fmtBytes(c.user_object_bytes)),
    tile('internal objects', fmtBytes(c.internal_object_bytes)),
    tile('version store', fmtBytes(c.version_store_bytes))),
  el('p', { class: 'meta' }, c.capacity_unknown
    ? 'Capacity not known: tempdb\'s data files were not read (mssql_storage), or a file may grow without limit and its volume\'s free space was not read (mssql_storage needs VIEW SERVER STATE for the volumes).'
    : `Capacity: the data files' ${fmtBytes(c.size_bytes)} now and ${fmtBytes(c.growth_room_bytes)} they can still grow by`
      + (c.no_growth ? ': the files are set not to grow' : c.volume_limited ? ', limited by the volume\'s free space' : ', limited by their max size')
      + '. Over 50 % is a warning, over 80 % critical, on the newest read.'));
  const ser = rowsOf(depth.tempdb_series);
  if (ser.length) {
    box.append(lineChart('tempdb by what fills it', ser.map(r => {
      const u = Number(r.user_object_bytes ?? 0), i = u + Number(r.internal_object_bytes ?? 0), v = i + Number(r.version_store_bytes ?? 0);
      return { snapshot_at: r.snapshot_at, user: u, internal: i, version: v, mixed: v + Number(r.mixed_extent_bytes ?? 0), size: Number(r.size_bytes ?? 0) };
    }), [{ key: 'user', label: 'user objects' }, { key: 'internal', label: 'internal objects' }, { key: 'version', label: 'version store' },
      { key: 'mixed', label: 'mixed extents' }, { key: 'size', label: 'free, up to the data files\' size' }], v => fmtBytes(v), { stacked: true }));
  }
  return box;
}

// per database: transactions and write transactions per second, log used %, active transactions (the counters read per
// database every 5 minutes), and log used % over the range
async function activitySection(ctx: Ctx): Promise<HTMLElement> {
  const box = el('div', {}, el('h3', {}, 'Transactions and log use per database'));
  let now: Row[] = [];
  try {
    now = rowsOf((await get<Record<'now', Table | null>>('mssql/counters', { instance: ctx.instance, ...window_(ctx), part: 'now' })).now);
  } catch (e) {
    box.append(notRead('the counters: ' + String((e as Error).message ?? e)));
    return box;
  }
  const want: [string, string][] = [['Transactions/sec', 'tx_s'], ['Write Transactions/sec', 'wtx_s'], ['Percent Log Used', 'log_pct'], ['Active Transactions', 'active']];
  const db = new Map<string, Row>();
  const have = new Set<string>();
  for (const r of now.filter(x => x.object === 'Databases' && x.inst !== '_Total')) {
    const k = want.find(w => w[0] === r.counter);
    if (!k) continue;
    have.add(k[1]);
    const row = db.get(String(r.inst)) ?? { database_name: r.inst, snapshot_at: r.snapshot_at };
    row[k[1]] = r.cumulative ? r.rate : r.value;
    db.set(String(r.inst), row);
  }
  const missing = want.filter(w => !have.has(w[1])).map(w => w[0]);
  if (!db.size) {
    box.append(notRead('no per-database counter in this range: mssql_activity reads them every 5 minutes'));
    return box;
  }
  if (missing.length) box.append(notRead(`${missing.join(', ')}: not collected on this pgvigil yet`));
  const cnt = (v: unknown) => v == null ? greyNA('not collected') : fmtNum(v);
  const rows = [...db.values()].sort((a, b) => Number(b.tx_s ?? 0) - Number(a.tx_s ?? 0));
  box.append(grid(rows, [
    { key: 'database_name', label: 'database' },
    { key: 'tx_s', label: 'transactions / s', num: true, fmt: cnt },
    { key: 'wtx_s', label: 'write transactions / s', num: true, fmt: cnt },
    { key: 'log_pct', label: 'log used', num: true, fmt: v => v == null ? greyNA('not collected') : pct(v), cls: v => v == null ? '' : Number(v) >= 90 ? 'crit' : Number(v) >= 75 ? 'warn' : '' },
    { key: 'active', label: 'active transactions', num: true, fmt: cnt },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ]));
  // log used % over the range: the ten fullest logs now
  const ids = now.filter(x => x.object === 'Databases' && x.counter === 'Percent Log Used' && x.inst !== '_Total')
    .sort((a, b) => Number(b.value ?? 0) - Number(a.value ?? 0)).slice(0, 10);
  if (ids.length) {
    try {
      const s = rowsOf((await get<Record<'series', Table | null>>('mssql/counters', { instance: ctx.instance, ...window_(ctx), part: 'series',
        series: ids.map(x => String(x.series_id)).join(',') })).series);
      const name = new Map(ids.map(x => [Number(x.series_id), String(x.inst)]));
      const p = series(s, r => name.get(Number(r.series_id)) ?? String(r.series_id), 'value');
      box.append(lineChart('Log used % per database (the ten fullest now)', p.rows, p.series, v => fmtNum(v) + ' %', { unit: '%' }));
    } catch (e) {
      box.append(notRead('the log used series: ' + String((e as Error).message ?? e)));
    }
  }
  return box;
}

// the tables that grew most and those that did not, over a chosen window; the databases not read are named
function tablesPanel(ctx: Ctx, first: DepthParts): HTMLElement {
  const out = el('div', {});
  const days = [7, 30, 90, 180, 365];
  const buttons = days.map(n => el('button', { type: 'button', 'aria-pressed': 'false' }, `${n} days`));
  let asked = 0;
  const show = async (n: number, b: HTMLButtonElement) => {
    buttons.forEach(x => x.setAttribute('aria-pressed', x === b ? 'true' : 'false'));
    const mine = ++asked;
    out.replaceChildren(el('p', { class: 'meta' }, 'Reading the tables...'));
    const d = n === 30 && mine === 1 ? first : await depthGet(ctx, { days: n, parts: 'growth,tables_read,runs' });
    if (mine !== asked) return;
    if (d instanceof Error) { out.replaceChildren(el('p', { class: 'empty' }, 'The tables could not be read: ' + d.message)); return; }
    const gap = runGap(d, 'mssql_tables', 'the tables');
    const unread = rowsOf(d.tables_read).filter(r => !r.read_ok);
    const tcol = (): Col[] => [
      { key: 'database_name', label: 'database', fmt: v => el('a', { href: hrefWith(ctx, mssqlFilesTab, { db: String(v ?? '') }) }, String(v ?? '')) },
      { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' }, { key: 'table_type', label: 'type' }, { key: 'compression' },
      { key: 'row_count', label: 'rows', num: true, fmt: fmtNum },
      { key: 'used_kb', label: 'used', num: true, fmt: kb },
    ];
    const growth = rowsOf(d.growth), grew = growth.filter(r => r.list === 'grew'), still = growth.filter(r => r.list === 'not_grown');
    out.replaceChildren(
      gap ? notRead(gap) : el('p', { class: 'meta' }, `Every table of every database read (mssql_tables, every 6 hours), against its size ${n} days ago. `
        + 'A database not read at both ends of the window is left out of both lists.'),
      el('h4', {}, `Grew most in ${n} days`),
      grid(grew, [...tcol(), { key: 'used_kb_grown', label: 'grew by', num: true, fmt: kbSigned }, { key: 'rows_grown', label: 'rows added', num: true, fmt: fmtNum },
        { key: 'kb_per_day', label: 'per day', num: true, fmt: v => v == null ? '' : kb(v) + ' / day' }], 'No table grew in this window, or too little history yet.'),
      el('h4', {}, `Did not grow in ${n} days` + (still.length ? ` (${fmtNum(still[0].tables_not_grown)} tables; the largest shown)` : '')),
      grid(still, tcol(), 'No table read at both ends of this window stood still.'),
      ...(unread.length ? [el('h4', {}, 'Databases whose tables were not read'), grid(unread, [{ key: 'database_name', label: 'database' },
        { key: 'note', label: 'why', wide: true }, { key: 'ok_at', label: 'last read whole', fmt: v => v == null ? 'never' : fmtTime(v) }])] : []));
  };
  buttons.forEach((b, i) => b.addEventListener('click', () => { void show(days[i], b); }));
  void show(30, buttons[1]);
  return el('div', {}, el('h3', {}, 'Tables: grew most, did not grow'),
    el('div', { class: 'seg', role: 'group', 'aria-label': 'Days of table growth' }, el('span', { class: 'meta' }, 'Window:'), ...buttons), out);
}

// IO per database (or per volume) over the range, the ten busiest charted, and the range beside a day or a week before
async function ioSection(ctx: Ctx, depth: DepthParts): Promise<HTMLElement> {
  const box = el('div', {}, el('h3', {}, 'IO per database'));
  const pend = rowsOf(depth.pending)[0];
  box.append(pend == null ? notRead(runGap(depth, 'mssql_fileio', 'the IOs pending') || 'the IOs pending: no file IO read in the last day')
    : pend.pending_ios == null ? notRead('the IOs pending: sys.dm_io_pending_io_requests was not read at the newest read')
    : el('p', { class: 'meta' }, `IOs pending at the newest read (${fmtTime(pend.snapshot_at)}): ${fmtNum(pend.pending_ios)}, `
      + `${fmtNum(pend.pending_in_os)} of them still with the operating system.`));
  const body = el('div', {});
  let by: 'database' | 'volume' = 'database', cmp: '1d' | '7d' = '1d', top = 10, asked = 0;
  const tops = [5, 10, 20];
  const byBtns = (['database', 'volume'] as const).map(k => el('button', { type: 'button', 'aria-pressed': String(k === by) }, `by ${k}`));
  const cmpBtns = (['1d', '7d'] as const).map(k => el('button', { type: 'button', 'aria-pressed': String(k === cmp) }, k === '1d' ? 'against a day earlier' : 'against a week earlier'));
  const topBtns = tops.map(n => el('button', { type: 'button', 'aria-pressed': String(n === top) }, `top ${n}`));
  const draw = async () => {
    byBtns.forEach((b, i) => b.setAttribute('aria-pressed', String(['database', 'volume'][i] === by)));
    cmpBtns.forEach((b, i) => b.setAttribute('aria-pressed', String(['1d', '7d'][i] === cmp)));
    topBtns.forEach((b, i) => b.setAttribute('aria-pressed', String(tops[i] === top)));
    const mine = ++asked, drawnBy = by, drawnCmp = cmp, drawnTop = top;
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading the IO...'));
    let d: Record<'grid' | 'series' | 'compare', Table | null>;
    try {
      d = await get('mssql/dbio', { instance: ctx.instance, ...window_(ctx), by: drawnBy, compare: drawnCmp, top: drawnTop });
    } catch (e) {
      if (mine !== asked) return;
      body.replaceChildren(el('p', { class: 'empty' }, 'The IO could not be read: ' + String((e as Error).message ?? e)));
      return;
    }
    if (mine !== asked) return; // a later click's reply draws instead
    const by_ = drawnBy;
    const g = rowsOf(d.grid);
    if (!g.length) { body.replaceChildren(notRead('no file IO in this range: mssql_fileio reads it every minute with VIEW SERVER STATE')); return; }
    const ms = (v: unknown) => v == null ? '' : `${fmtNum(v)} ms`;
    const s = rowsOf(d.series).map(r => ({ ...r, mb_s: (Number(r.read_bytes_s ?? 0) + Number(r.write_bytes_s ?? 0)) / 1048576 }));
    const mb = series(s, r => String(r.database_name), 'mb_s'), rl = series(s, r => String(r.database_name), 'read_latency_ms');
    body.replaceChildren(
      el('p', { class: 'meta' }, 'Each file\'s IO summed per ' + by_ + '; the latency is the stall over the operations, so the busier files weigh more. '
        + 'Queued: the time the resource governor held IO back (0 where no pool limits IO).'),
      ...(by_ === 'database' ? [el('div', { class: 'charts' },
        lineChart(`MB/s by database (the ${drawnTop} busiest)`, mb.rows, mb.series, v => fmtNum(v) + ' MB/s'),
        lineChart(`Read latency by database (the ${drawnTop} busiest)`, rl.rows, rl.series, v => fmtNum(v) + ' ms'))] : []),
      grid(g, [
        { key: 'name', label: by_ },
        { key: 'mb_s', label: 'MB/s', num: true, fmt: v => v == null ? '' : fmtNum(v) },
        { key: 'reads', num: true, fmt: fmtNum }, { key: 'read_bytes', label: 'read', num: true, fmt: fmtBytes },
        { key: 'read_latency_ms', label: 'read latency', num: true, fmt: ms },
        { key: 'writes', num: true, fmt: fmtNum }, { key: 'write_bytes', label: 'written', num: true, fmt: fmtBytes },
        { key: 'write_latency_ms', label: 'write latency', num: true, fmt: ms },
        { key: 'queued_ms', label: 'queued', num: true, fmt: ms },
      ]),
      el('h4', {}, `This range against ${drawnCmp === '1d' ? 'the same window a day earlier' : 'the same window a week earlier'}`),
      grid(rowsOf(d.compare), [
        { key: 'name', label: by_ },
        { key: 'mb_s', label: 'MB/s now', num: true, fmt: v => v == null ? 'none' : fmtNum(v) },
        { key: 'mb_s_before', label: 'MB/s then', num: true, fmt: v => v == null ? 'none' : fmtNum(v) },
        { key: 'read_latency_ms', label: 'read latency now', num: true, fmt: ms },
        { key: 'read_latency_ms_before', label: 'read latency then', num: true, fmt: ms },
        { key: 'write_latency_ms', label: 'write latency now', num: true, fmt: ms },
        { key: 'write_latency_ms_before', label: 'write latency then', num: true, fmt: ms },
      ], 'Nothing to compare.'));
  };
  byBtns.forEach((b, i) => b.addEventListener('click', () => { by = (['database', 'volume'] as const)[i]; void draw(); }));
  cmpBtns.forEach((b, i) => b.addEventListener('click', () => { cmp = (['1d', '7d'] as const)[i]; void draw(); }));
  topBtns.forEach((b, i) => b.addEventListener('click', () => { top = tops[i]; void draw(); }));
  box.append(el('div', { class: 'seg', role: 'group', 'aria-label': 'IO grouped by' }, ...byBtns),
    el('div', { class: 'seg', role: 'group', 'aria-label': 'IO compared with' }, ...cmpBtns),
    el('div', { class: 'seg', role: 'group', 'aria-label': 'Databases charted' }, ...topBtns), body);
  await draw();
  return box;
}

// buffer pool IO: bytes per second written (all, checkpoint, lazy writer) above the axis, read (all, read-ahead) below
async function bufferPoolSection(ctx: Ctx): Promise<HTMLElement> {
  const box = el('div', {}, el('h3', {}, 'Buffer pool IO'));
  const names: [string, string, number][] = [['Page writes/sec', 'written', 1], ['Checkpoint pages/sec', 'checkpoint', 1], ['Lazy writes/sec', 'lazy writer', 1],
    ['Page reads/sec', 'read', -1], ['Readahead pages/sec', 'read-ahead', -1]];
  try {
    const now = rowsOf((await get<Record<'now', Table | null>>('mssql/counters', { instance: ctx.instance, ...window_(ctx), part: 'now' })).now)
      .filter(r => String(r.object ?? '') === 'Buffer Manager');
    const picked = names.map(n => ({ n, r: now.find(r => r.counter === n[0]) })).filter(x => x.r);
    if (!picked.length) { box.append(notRead('no Buffer Manager counter in this range: mssql_cpu reads them every minute')); return box; }
    const s = rowsOf((await get<Record<'series', Table | null>>('mssql/counters', { instance: ctx.instance, ...window_(ctx), part: 'series',
      series: picked.map(x => String(x.r!.series_id)).join(',') })).series);
    const key = new Map(picked.map(x => [Number(x.r!.series_id), x.n]));
    const by = new Map<string, Row>();
    for (const r of s) {
      const n = key.get(Number(r.series_id));
      if (!n) continue;
      const t = String(r.snapshot_at);
      const row = by.get(t) ?? { snapshot_at: t };
      row[n[1]] = r.value == null ? null : Number(r.value) * 8192 * n[2];
      by.set(t, row);
    }
    const rows = [...by.values()].sort((a, b) => Date.parse(String(a.snapshot_at)) - Date.parse(String(b.snapshot_at)));
    box.append(el('p', { class: 'meta' }, 'Pages per second as bytes (8 KB a page): writes above the axis, reads below it.'),
      lineChart('Buffer pool IO', rows, picked.map(x => ({ key: x.n[1], label: x.n[2] < 0 ? `${x.n[1]} (below the axis)` : x.n[1] })),
        v => fmtBytes(Math.abs(v)) + '/s'));
  } catch (e) {
    box.append(notRead('the counters: ' + String((e as Error).message ?? e)));
  }
  return box;
}

// the fixed drives, the default paths and the orphaned files
function drivesSection(depth: DepthParts): HTMLElement {
  const box = el('div', {}, el('h3', {}, 'Fixed drives, default paths, orphaned files'));
  const p = rowsOf(depth.paths)[0];
  const gap = runGap(depth, 'mssql_storage_depth', 'the paths, drives and folders');
  if (!p) { box.append(notRead(gap || 'mssql_storage_depth has not read this instance yet')); return box; }
  const onC = (v: unknown) => p.host_platform === 'Windows' && /^c:/i.test(String(v ?? '')) ? badge(String(v), 'warn') : String(v ?? '');
  box.append(grid([{ what: 'default data path', path: p.default_data_path }, { what: 'default log path', path: p.default_log_path }],
    [{ key: 'what' }, { key: 'path', fmt: onC }]));
  if (p.host_platform !== 'Windows') box.append(el('p', { class: 'meta' }, 'The system drive rules (a path on C:) are not on Linux.'));
  if (!p.drives_read) box.append(notRead(String(p.drives_note ?? 'the fixed drives')));
  else {
    box.append(el('h4', {}, 'Fixed drives'), grid(rowsOf(depth.drives), [
      { key: 'drive' }, { key: 'drive_type', label: 'type' }, { key: 'free_bytes', label: 'free', num: true, fmt: fmtBytes },
      { key: 'total_bytes', label: 'size', num: true, fmt: v => v == null ? 'size not read' : fmtBytes(v) },
      { key: 'free_pct', label: 'free %', num: true, fmt: (v, r) => v == null ? '' : r.status === 'critical' ? badge(pct(v), 'crit') : r.status === 'warning' ? badge(pct(v), 'warn') : pct(v) },
      { key: 'files', label: 'database files', num: true },
    ]), el('p', { class: 'meta' }, 'Size not read: SQL Server gives only the free bytes of a drive without database files'
      + (p.host_platform === 'Linux' ? '; on Linux SQL Server lists only /.' : '.')));
  }
  if (!p.orphans_read) box.append(notRead(String(p.orphans_note ?? 'the folders')));
  else {
    const orph = rowsOf(depth.orphans);
    box.append(el('h4', {}, 'Data and log files no database lists'),
      grid(orph, [{ key: 'path', wide: true }, { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'snapshot_at', label: 'read', fmt: fmtTime },
        { key: 'note', label: 'note', wide: true, fmt: v => v == null ? '' : String(v) }],
        'None in the default paths or the folders holding a database file.'));
    if (p.orphans_note) box.append(el('p', { class: 'meta' }, String(p.orphans_note)));
  }
  return box;
}

// the Windows host's own disk counters: no door to read them yet; a Linux host has no Windows counters at all
function hostDoorSection(platform: string): HTMLElement {
  return el('div', {}, el('h3', {}, 'The host\'s disks'),
    platform === 'Linux'
      ? notRead('the Windows disk counters are not on Linux: the queue length, latency, IOPS and throughput per disk come from the Windows host')
      : notRead('pgvigil has no Windows host door yet: the logical and physical disks\' queue length, latency, IOPS and throughput, '
        + 'the volumes\' block size and allocation unit need it'));
}

// databaseDepthSections: the Database files tab's depth for one database - its space over a chosen window and every
// table, each drawn over the same window
async function databaseDepthSections(ctx: Ctx, db: string): Promise<HTMLElement[]> {
  const days = [7, 30, 90, 180, 365];
  const buttons = days.map(n => el('button', { type: 'button', 'aria-pressed': String(n === 30) }, `${n} days`));
  const body = el('div', {});
  let asked = 0;
  const show = async (n: number) => {
    buttons.forEach((b, i) => b.setAttribute('aria-pressed', String(days[i] === n)));
    const mine = ++asked;
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading the database\'s space and tables...'));
    const d = await depthGet(ctx, { db, days: n, parts: 'space_series,tables,tables_read,runs' });
    if (mine !== asked) return;
    body.replaceChildren(...(d instanceof Error ? [el('p', { class: 'empty' }, 'The storage depth could not be read: ' + d.message)] : databaseDepth(ctx, db, n, d)));
  };
  buttons.forEach((b, i) => b.addEventListener('click', () => { void show(days[i]); }));
  await show(30);
  return [el('div', { class: 'seg', role: 'group', 'aria-label': 'Days of space and table history' }, el('span', { class: 'meta' }, 'Window:'), ...buttons), body];
}

function databaseDepth(ctx: Ctx, db: string, n: number, d: DepthParts): HTMLElement[] {
  const out: HTMLElement[] = [];
  const sp = rowsOf(d.space_series);
  out.push(el('h3', {}, `Space inside ${db}, ${n} days`));
  if (sp.length >= 2) {
    out.push(lineChart(`Space inside ${db}`, sp.map(r => {
      const a = Number(r.data_bytes ?? 0), b = a + Number(r.index_bytes ?? 0), c = b + Number(r.unused_bytes ?? 0), u = c + Number(r.unallocated_bytes ?? 0);
      const l = u + Number(r.log_used_bytes ?? 0);
      return { snapshot_at: r.snapshot_at, data: a, index: b, unused: c, unallocated: u, log_used: l, log_free: l + Number(r.log_free_bytes ?? 0) };
    }), [{ key: 'data', label: 'data' }, { key: 'index', label: 'index' }, { key: 'unused', label: 'unused' }, { key: 'unallocated', label: 'unallocated' },
      { key: 'log_used', label: 'log used' }, { key: 'log_free', label: 'log free' }], v => fmtBytes(v), { stacked: true, ownSpan: true }));
  } else out.push(notRead(runGap(d, 'mssql_storage', 'the space split') || 'too little history yet: mssql_storage reads the split hourly'));
  const tables = rowsOf(d.tables);
  out.push(el('h3', {}, `Tables of ${db}` + (tables.length ? ` (${fmtNum(tables.length)})` : '')));
  const tr = rowsOf(d.tables_read).find(r => r.database_name === db);
  if (!tables.length) {
    out.push(db === 'tempdb' || db === 'model' ? notRead(`the tables of ${db}: tempdb and model are left out of the table read (a #table read once would be kept as gone)`)
      : tr?.read_ok ? el('p', { class: 'meta' }, `No user table in ${db} at its newest read (${fmtTime(tr.read_at)}).`)
      : notRead(tr && !tr.read_ok ? String(tr.note ?? 'the tables') : runGap(d, 'mssql_tables', 'the tables') || 'mssql_tables has not read this database yet'));
    return out;
  }
  if (tr && !tr.read_ok) out.push(el('p', { class: 'empty' }, `not read at the last pass: ${String(tr.note ?? '')}; the tables as last read`));
  const chart = el('div', {});
  let opened = 0;
  const open = async (schema: string, table: string) => {
    const mine = ++opened;
    chart.replaceChildren(el('p', { class: 'meta' }, `Reading ${schema}.${table}...`));
    const t = await depthGet(ctx, { db, days: n, schema, table, part: 'table_series' });
    if (mine !== opened) return; // a later click's table draws instead
    if (t instanceof Error) { chart.replaceChildren(el('p', { class: 'empty' }, 'The table\'s sizes could not be read: ' + t.message)); return; }
    const rows = rowsOf(t.table_series).map(r => ({ ...r, used: Number(r.used_kb ?? 0) * 1024, reserved: Number(r.reserved_kb ?? 0) * 1024 }));
    chart.replaceChildren(rows.length >= 2
      ? lineChart(`${schema}.${table}: size, ${n} days (a point each time it changed)`, rows, [{ key: 'used', label: 'used' }, { key: 'reserved', label: 'reserved' }],
        v => fmtBytes(v), { ownSpan: true })
      : el('p', { class: 'empty' }, `${schema}.${table} has not changed in ${n} days (or has one read): its size is ${fmtBytes(rows[0]?.used ?? 0)}.`));
  };
  out.push(el('p', { class: 'meta' }, `Every user table (mssql_tables, every 6 hours). A table's name draws its size over ${n} days. `
    + 'Compression: the heap or clustered index\'s partitions; "mixed" counts them.'),
  grid(tables, [
    { key: 'table_name', label: 'table', fmt: (v, r) => { const b = el('button', { type: 'button', class: 'link' }, `${String(r.schema_name)}.${String(v)}`);
      b.addEventListener('click', () => { void open(String(r.schema_name), String(v)); }); return b; } },
    { key: 'table_type', label: 'type', fmt: (v, r) => [v, r.temporal, r.graph].filter(Boolean).join(', ') },
    { key: 'compression' }, { key: 'partitions', num: true },
    { key: 'row_count', label: 'rows', num: true, fmt: fmtNum },
    { key: 'reserved_kb', label: 'reserved', num: true, fmt: kb }, { key: 'used_kb', label: 'used', num: true, fmt: kb },
    { key: 'data_kb', label: 'data', num: true, fmt: kb }, { key: 'index_kb', label: 'index', num: true, fmt: kb },
    { key: 'used_kb_grown', label: `grew, ${n} days`, num: true, fmt: (v, r) => v == null ? (r.first_seen ? 'too little history' : '') : kbSigned(v) },
    { key: 'kb_per_day', label: 'per day', num: true, fmt: v => v == null ? '' : kb(v) + ' / day' },
    { key: 'changed_at', label: 'last changed', fmt: fmtTime },
  ]), chart);
  return out;
}
