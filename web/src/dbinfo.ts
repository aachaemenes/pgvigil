// The Database info tab and the fleet Growth root (task 37; DBADash's Database tab): each database's facts
// (owner, encoding, collation and its provider, the collation version against the library's, connection limit,
// default tablespace and its size, allow connections, template, extensions), its size and growth over 7 and 30
// days, the tablespaces, the size history of the largest databases and tables; at the root the fleet's top
// growers over 7 and 30 days. Data from /api/dbinfo and /api/dbinfo/fleet.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, window_ } from './router';
import { badge, Col, el, fmtBytes, fmtNum, fmtTime, grid, tile } from './ui';

// hashParam reads a page parameter the router does not know (db, rel, job, idx) from the hash.
export function hashParam(name: string): string | undefined {
  const qs = location.hash.split('?')[1] ?? '';
  const v = new URLSearchParams(qs).get(name);
  return v == null || v === '' ? undefined : v;
}

// hrefWith is the router's link to a tab (instance, tag and time range kept) plus page parameters of its own.
export function hrefWith(ctx: Ctx, tab: string, extra: Record<string, string | number | undefined>, instance = ctx.instance): string {
  const base = href(ctx, { tab, instance, tag: instance ? undefined : ctx.tag });
  const q = new URLSearchParams(base.split('?')[1] ?? '');
  for (const [k, v] of Object.entries(extra)) if (v !== undefined && v !== '') q.set(k, String(v));
  return `#/${tab}?${q}`;
}

export const link = (text: string, to: string) => el('a', { href: to }, text);
export const grownTxt = (v: unknown) => v == null ? 'too little history' : Number(v) < 0 ? '-' + fmtBytes(-Number(v)) : '+' + fmtBytes(v);
export const pctTxt = (v: unknown) => v == null ? '' : (Number(v) > 0 ? '+' : '') + fmtNum(v) + ' %';
const perDay = (v: unknown) => v == null ? '' : (Number(v) < 0 ? '-' + fmtBytes(-Number(v)) : fmtBytes(v)) + ' / day';
const yesNo = (v: unknown) => v == null ? '' : v ? 'yes' : 'no';
const limitTxt = (v: unknown) => v == null ? '' : Number(v) < 0 ? 'none' : fmtNum(v);

// series turns long rows (snapshot_at, label, bytes) into one row per snapshot with a column per label, in the
// order the labels first appear sorted by their newest size, largest first.
export function series(rows: Row[], label: (r: Row) => string, val: string): { rows: Row[]; series: { key: string; label: string }[] } {
  const last = new Map<string, number>();
  const by = new Map<string, Row>();
  for (const r of rows) {
    const k = label(r), t = String(r.snapshot_at);
    if (r[val] != null) last.set(k, Number(r[val]));
    if (!by.has(t)) by.set(t, { snapshot_at: t });
    by.get(t)![k] = r[val] == null ? null : Number(r[val]);
  }
  const keys = [...last.entries()].sort((a, b) => b[1] - a[1]).map(e => e[0]);
  return { rows: [...by.values()].sort((a, b) => Date.parse(String(a.snapshot_at)) - Date.parse(String(b.snapshot_at))), series: keys.map(k => ({ key: k, label: k })) };
}

// dbLink: a database name opening its drill-down page (task 48), the time range kept.
export const dbLink = (ctx: Ctx, name: unknown, dbid: unknown, instance = ctx.instance) =>
  link(String(name ?? ''), hrefWith(ctx, 'db', { db: String(dbid) }, instance));
// tableLink: a table name opening its page.
export const tableLink = (ctx: Ctx, text: string, dbid: unknown, relid: unknown, instance = ctx.instance) =>
  link(text, hrefWith(ctx, 'table', { db: String(dbid), rel: String(relid) }, instance));

export async function dbinfoView(ctx: Ctx): Promise<HTMLElement> {
  const db = hashParam('db');
  const d = await get<Record<'databases' | 'tablespaces' | 'db_series' | 'table_series' | 'series_meta', Table | null>>('dbinfo',
    { instance: ctx.instance, ...window_(ctx), db });
  const all = rowsOf(d.databases);
  const dbs = all.filter(r => r.is_present), gone = all.filter(r => !r.is_present);
  const user = dbs.filter(r => !r.is_template);
  const meta = rowsOf(d.series_meta)[0] ?? {};
  const mism = dbs.filter(r => r.collation_mismatch);
  const sec = el('section', {}, el('h2', {}, 'Database info'));
  sec.append(el('div', { class: 'tiles' },
    tile('databases', String(user.length)),
    tile('total size', fmtBytes(user.reduce((a, r) => a + Number(r.size_bytes ?? 0), 0)) || '-'),
    tile('grown (7 d)', grownTxt(user.some(r => r.grown_7d_bytes != null) ? user.reduce((a, r) => a + Number(r.grown_7d_bytes ?? 0), 0) : null)),
    tile('collation version changed', String(mism.length), mism.length ? 'warn' : 'ok'),
  ));
  if (mism.length) {
    sec.append(el('p', { class: 'meta' }, 'A collation version changed: the operating system library sorts differently from when the indexes '
      + 'on text were built. Reindex the text indexes, then ALTER DATABASE ... REFRESH COLLATION VERSION (the Versions tab has the detail).'));
  }
  const cols: Col[] = [
    { key: 'datname', label: 'database', fmt: (v, r) => dbLink(ctx, v, r.dbid) },
    { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
    { key: 'grown_7d_bytes', label: 'grown (7 d)', num: true, fmt: grownTxt },
    { key: 'grown_30d_bytes', label: 'grown (30 d)', num: true, fmt: grownTxt },
    { key: 'growth_7d_per_day', label: 'per day (7 d)', num: true, fmt: perDay },
    { key: 'owner' }, { key: 'encoding' },
    { key: 'lc_collate', label: 'collation' }, { key: 'lc_ctype', label: 'ctype' },
    { key: 'locale_provider', label: 'provider', fmt: (v, r) => String(v ?? '') + (r.locale && r.locale !== r.lc_collate ? ` (${String(r.locale)})` : '') },
    { key: 'collation_recorded', label: 'collation version', fmt: (v, r) => r.collation_mismatch ? badge(`${String(v)} -> ${String(r.collation_actual)}`, 'warn') : String(v ?? '') },
    { key: 'conn_limit', label: 'conn limit', num: true, fmt: limitTxt },
    { key: 'tablespace', fmt: (v, r) => String(v ?? '') + (r.tablespace_bytes != null ? ` (${fmtBytes(r.tablespace_bytes)})` : '') },
    { key: 'allow_conn', label: 'allow conn', fmt: yesNo },
    { key: 'is_template', label: 'template', fmt: yesNo },
    { key: 'can_connect', label: 'login connects', fmt: yesNo },
    { key: 'xid_age', label: 'xid age', num: true, fmt: fmtNum },
    { key: 'extension_count', label: 'ext.', num: true },
    { key: 'extensions', wide: true },
    { key: 'tables_read', label: 'tables read', num: true },
    { key: 'comment', wide: true },
    { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ];
  sec.append(el('h3', {}, 'Databases'),
    el('p', { class: 'meta' }, 'Grown: the newest size minus the oldest in the last 7 or 30 days (a growth line needs a day or a week of history). '
      + 'Collation and locale come from the versions collection, the tablespace sizes from storage, the extensions from extensions; '
      + 'tables read: the tables collection keeps the largest tables of each database.'),
    grid(dbs, cols, 'No database read yet: the databases collection runs hourly.'));
  if (gone.length) {
    sec.append(el('h3', {}, 'Dropped databases'), grid(gone, [
      { key: 'datname', label: 'database' }, { key: 'owner' }, { key: 'size_bytes', label: 'last size', num: true, fmt: fmtBytes },
      { key: 'first_seen', label: 'first seen', fmt: fmtTime }, { key: 'snapshot_at', label: 'last seen', fmt: fmtTime },
    ]));
  }
  sec.append(el('h3', {}, 'Tablespaces'), grid(rowsOf(d.tablespaces), [
    { key: 'name' }, { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'location' },
    { key: 'default_for', label: 'default for', wide: true }, { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ], 'No tablespace read yet: the storage collection runs every 15 minutes.'));

  const winTxt = `${fmtTime(meta.from_at)} to ${fmtTime(meta.to_at)}`;
  const ds = series(rowsOf(d.db_series), r => String(r.datname), 'size_bytes');
  const ts = series(rowsOf(d.table_series), r => String(r.label), 'total_bytes');
  const dbName = db ? String(all.find(r => String(r.dbid) === db)?.datname ?? 'database ' + db) : '';
  const scope = el('p', { class: 'meta' }, `Size history ${winTxt} (at least 7 days: the sizes are read hourly). Tables: `,
    db ? el('span', {}, `the largest of ${dbName} (`, link('every database', hrefWith(ctx, 'dbinfo', {})), ')')
      : 'the largest of the instance; pick a database to narrow them: ',
    ...(db ? [] : user.slice(0, 12).flatMap((r, i) => [i ? ', ' : '', link(String(r.datname), hrefWith(ctx, 'dbinfo', { db: String(r.dbid) }))])));
  sec.append(el('h3', {}, 'Size history'), scope, el('div', { class: 'charts' },
    lineChart('Databases (the largest ' + ds.series.length + ')', ds.rows, ds.series, v => fmtBytes(v)),
    lineChart('Tables (the largest ' + ts.series.length + ')', ts.rows, ts.series, v => fmtBytes(v))));
  return sec;
}

// dbinfoFleetView: the fleet's top growers over 7 and 30 days (keep narrows to a tag folder).
export async function dbinfoFleetView(ctx: Ctx, keep?: (r: Row) => boolean): Promise<HTMLElement> {
  const d = await get<Record<'databases' | 'tables', Table | null>>('dbinfo/fleet');
  let dbs = rowsOf(d.databases), tabs = rowsOf(d.tables);
  if (keep) { dbs = dbs.filter(keep); tabs = tabs.filter(keep); }
  const instCol: Col = { key: 'instance', fmt: (v, r) => link(String(v ?? ''), hrefWith(ctx, 'dbinfo', {}, Number(r.instance_id))) };
  const growth: Col[] = [
    { key: 'grown_7d_bytes', label: 'grown (7 d)', num: true, fmt: grownTxt },
    { key: 'grown_7d_pct', label: '7 d %', num: true, fmt: pctTxt },
    { key: 'grown_30d_bytes', label: 'grown (30 d)', num: true, fmt: grownTxt },
    { key: 'grown_30d_pct', label: '30 d %', num: true, fmt: pctTxt },
    { key: 'growth_7d_per_day', label: 'per day (7 d)', num: true, fmt: perDay },
  ];
  return el('section', {}, el('h2', {}, 'Growth'),
    el('div', { class: 'tiles' },
      tile('growing databases', String(dbs.length)),
      tile('grown (7 d)', fmtBytes(dbs.reduce((a, r) => a + Math.max(0, Number(r.grown_7d_bytes ?? 0)), 0)) || '-'),
      tile('growing tables', String(tabs.length))),
    el('p', { class: 'meta' }, 'The databases and tables of the fleet that grew the most over the last 7 days, with their 30-day growth: '
      + 'the newest size minus the oldest of the window. Tables: the largest of each database (the tables collection).'),
    el('h3', {}, 'Databases'),
    grid(dbs, [instCol, { key: 'platform' },
      { key: 'datname', label: 'database', fmt: (v, r) => dbLink(ctx, v, r.dbid, Number(r.instance_id)) },
      { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes }, ...growth], 'No database grew in the last 30 days (or the history is under a day).'),
    el('h3', {}, 'Tables'),
    grid(tabs, [instCol,
      { key: 'datname', label: 'db' }, { key: 'schema_name', label: 'schema' },
      { key: 'table_name', label: 'table', fmt: (v, r) => tableLink(ctx, String(v ?? ''), r.dbid, r.relid, Number(r.instance_id)) },
      { key: 'total_bytes', label: 'size', num: true, fmt: fmtBytes }, ...growth], 'No table grew in the last 30 days (or the history is under a day).'));
}
