// The Storage and Database files tabs of a SQL Server instance (task 99; the SQL Server side of the storage rings,
// DBA Dash's pie charts): a ring per volume of used against free, a ring of the space each database holds on the
// instance, a ring of each file within a database, each slice with its size and share in the table beside it; a days
// selector (7 to 365) that redraws the size lines, the ring of growth and the growth figures; every volume, database
// and file in a grid. Data from /api/mssql/storage (mssql_storage, read hourly).
import { get, Row, rowsOf, Table } from './api';
import { donutChart, lineChart, volumeBars } from './chart';
import { hashParam, hrefWith, series } from './dbinfo';
import { Ctx } from './router';
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
// the free cells in the colour of the volume's threshold (the root's, a tag's, the instance's or its own; 10 / 5 by default), as the export writes them
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
  const d = await get<Parts>('mssql/storage', { instance: ctx.instance, days: 30 });
  const vols = rowsOf(d.volumes), dbs = rowsOf(d.databases), checks = rowsOf(d.checks);
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
    sec.append(el('p', { class: 'empty' }, 'No file read yet: the mssql_storage collection runs hourly and needs VIEW ANY DEFINITION.'));
    return sec;
  }

  // volumes as bars, used against size; the databases as a pie of what each holds; then the growth of a chosen number of days
  const pies = el('div', { class: 'charts' });
  const bars = volumeBars('Volumes', vols.filter(v => v.used_bytes != null && v.free_bytes != null)
    .map(v => ({ name: String(v.volume ?? ''), used: Number(v.used_bytes), free: Number(v.free_bytes) })), fmtBytes);
  pies.append(donutChart('Databases by size', dbs.map(r => ({ label: String(r.database_name ?? ''), value: Number(r.size_bytes ?? 0),
    href: hrefWith(ctx, mssqlFilesTab, { db: String(r.database_name ?? '') }) })), fmtBytes));
  pies.append(donutChart('Data against log', [{ label: 'data files', value: sum('data_bytes') }, { label: 'log files', value: sum('log_bytes') }], fmtBytes, 8, true));
  sec.append(el('h3', {}, 'Space at a glance'), bars, pies, growthPanel(ctx, d));

  if (checks.length) sec.append(el('h3', {}, 'Checks'), grid(checks, checkCols));
  sec.append(el('h3', {}, 'Volumes'),
    el('p', { class: 'meta' }, 'The volumes the database files sit on, as the server reads them (sys.dm_os_volume_stats). '
      + 'A SQL Server on Linux names no mount point: the files\' directory stands for the volume, and two directories on one file system show the same size and free space.'),
    grid(vols, volCols, 'No volume read: the login needs VIEW SERVER STATE for the volumes\' total and free space.'));
  sec.append(el('h3', {}, 'Databases'),
    el('p', { class: 'meta' }, 'A database\'s name opens its files. Used inside: the space in use within the files, read where the login can enter the database.'),
    grid(dbs, dbCols(ctx)));
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
        donutChart(`Growth by database, ${n} days`, dbs.map(r => ({ label: String(r.database_name), value: Number(r.grown_bytes ?? 0) })), fmtBytes,
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
  sec.append(el('h3', {}, 'Every file of the instance'),
    el('p', { class: 'meta' }, 'Growth: the step the file grows by, a size or a per cent of the file. Max size: where growth stops. '
      + 'Used: the space in use inside the file; "used not read" where the login cannot enter the database (the cell\'s title says why).'),
    grid(all, fileCols));
  return sec;
}
