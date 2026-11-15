// Azure SQL Database's geo-replication and failover groups (task 390a): a block under the instance's Availability tab.
// DBA Dash reads none of this; the shape is its availability group grid (one row per link, the state coloured, the lag).
// Data from /api/mssql/georepl: mssql_georepl (each minute, sys.dm_geo_replication_link_status in the database: the lag
// and the last replication are the primary's only) and mssql_failover_groups (every 5 minutes, Azure Resource Manager,
// through the instance's azure: block). A failover is seen as a role change between two reads (or, behind a failover
// group's listener, as the partner changing); the view cannot tell a planned failover from a forced one - the Activity
// Log's operations, when they are read, can.
import { get, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, window_ } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid, props, tile } from './ui';
import { jsonRows, mssqlFindingCols } from './mssql_hadr';

type Parts = Record<'read' | 'links' | 'groups' | 'series' | 'events' | 'findings', Table | null>;

const secs = (v: unknown) => v == null ? '' : fmtNum(v) + ' s';
const stateTone: Record<string, string> = { CATCH_UP: 'ok', SEEDING: 'warn', PENDING: 'warn', SUSPENDED: 'crit' };
const linkCols = (ctx: Ctx): Col[] => [
  { key: 'role_desc', label: 'this database' },
  { key: 'partner_server', label: 'partner', fmt: (v, r) => r.partner_instance_id != null
    ? el('a', { href: href(ctx, { tab: 'availability', instance: Number(r.partner_instance_id) }) }, `${String(v)}/${String(r.partner_database ?? '')}`)
    : `${String(v ?? '')}/${String(r.partner_database ?? '')} (not monitored)` },
  { key: 'replication_state_desc', label: 'state', fmt: v => badge(String(v ?? ''), stateTone[String(v)] ?? '') },
  { key: 'state_since', label: 'since', fmt: v => fmtTime(v) },
  { key: 'replication_lag_sec', label: 'lag', fmt: secs, num: true },
  { key: 'unsent_s', label: 'unsent window', fmt: secs, num: true },
  { key: 'ack_age_s', label: 'last acknowledgement', fmt: v => v == null ? '' : `${fmtNum(v)} s ago`, num: true },
  { key: 'last_commit', label: 'last commit', fmt: v => fmtTime(v) },
  { key: 'secondary_allow_connections_desc', label: 'readable secondary' },
  { key: 'snapshot_at', label: 'read', fmt: v => fmtTime(v) },
];
const groupCols: Col[] = [
  { key: 'group_name', label: 'failover group' }, { key: 'role', label: 'this server' },
  { key: 'replication_state', label: 'state' }, { key: 'rw_policy', label: 'failover policy' },
  { key: 'grace_minutes', label: 'grace (minutes)', fmt: v => v == null ? '' : fmtNum(v), num: true },
  { key: 'secondary_type', label: 'secondary' }, { key: 'ro_policy', label: 'read-only failover' },
  { key: 'partners', label: 'partners', fmt: v => jsonRows(v).map(p => `${String(p.server)} (${String(p.location ?? '')}, ${String(p.role ?? '')})`).join(', ') },
  { key: 'holds_database', label: 'holds this database', fmt: v => v === true ? 'yes' : 'no' },
  { key: 'snapshot_at', label: 'read', fmt: v => fmtTime(v) },
];
const eventCols: Col[] = [
  { key: 'at', label: 'seen', fmt: v => fmtTime(v) }, { key: 'prev_read_at', label: 'after the read at', fmt: v => fmtTime(v) },
  { key: 'what', label: 'of' }, { key: 'kind', label: 'change' }, { key: 'object', label: 'link or group' },
  { key: 'old_value', label: 'from' }, { key: 'new_value', label: 'to' },
];

// hasGeoRepl: whether the database has a link, a failover group of its servers, or an event of the last 24 hours (the
// shell's check for the tab: it stays after a link is removed, with the 'link removed' row)
export async function hasGeoRepl(instance: number): Promise<boolean> {
  const d = await get<Parts>('mssql/georepl', { instance, part: 'read' });
  const r = rowsOf(d.read)[0];
  return r != null && r.has === true;
}

export async function geoReplBlock(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { id: 'georepl' }, el('h3', {}, 'Geo-replication and failover groups'));
  const d = await get<Parts>('mssql/georepl', { instance: ctx.instance, ...window_(ctx) });
  const read = rowsOf(d.read)[0], links = rowsOf(d.links), groups = rowsOf(d.groups), findings = rowsOf(d.findings);
  // an Availability tab of another platform (an availability group's server) shows nothing of this block
  if (read?.platform !== 'azuresqldb') return el('span');
  if (!read || read.snapshot_at == null) {
    const why = read?.georepl_status === 'skipped' ? `mssql_georepl is skipped: ${String(read.georepl_note ?? '')}.`
      : read?.georepl_status === 'error' ? `mssql_georepl failed: ${String(read.georepl_note ?? '')}.`
      : 'mssql_georepl has not read this database yet (Azure SQL Database, every minute; the login needs VIEW DATABASE STATE).';
    sec.append(el('p', { class: 'empty' }, why));
    return sec;
  }
  if (findings.length) sec.append(el('h4', {}, 'Findings'), grid(findings, mssqlFindingCols));
  sec.append(el('div', { class: 'tiles' },
    tile('links', fmtNum(links.length)),
    tile('not catching up', fmtNum(links.filter(r => r.replication_state_desc !== 'CATCH_UP').length),
      links.some(r => r.replication_state_desc === 'SUSPENDED') ? 'crit' : links.some(r => r.replication_state_desc !== 'CATCH_UP') ? 'warn' : ''),
    tile('failover groups', fmtNum(groups.filter(g => g.holds_database === true).length)),
  ));
  sec.append(props([
    ['logical server read', String(read.server_read ?? '')],
    ['database', String(read.database_name ?? '')],
    ['last read', fmtTime(read.snapshot_at)],
  ]));
  if (!links.length) sec.append(el('p', { class: 'empty' }, 'No geo-replication link: this database is neither a geo-primary nor a geo-secondary.'));
  else {
    if (links.every(r => r.role_desc === 'SECONDARY' && r.partner_instance_id == null)) {
      sec.append(el('p', { class: 'meta' }, 'The lag is read on the primary, which pgvigil does not monitor here; the failover group\'s state shows below when its server is read.'));
    }
    sec.append(el('h4', {}, 'Links'), grid(links, linkCols(ctx)));
  }
  sec.append(el('h4', {}, 'Failover groups'));
  if (groups.length) sec.append(grid(groups, groupCols));
  else sec.append(el('p', { class: 'empty' }, read.groups_status === 'skipped' ? `mssql_failover_groups is skipped: ${String(read.groups_note ?? '')}.`
    : read.groups_status === 'error' ? `mssql_failover_groups failed: ${String(read.groups_note ?? '')}.`
    : 'No failover group read for this database\'s server (the azure: block names its server for the Resource Manager read).'));
  // the chart's x axis runs oldest first (uPlot's aligned data): the read answers newest first
  const series = rowsOf(d.series).slice().reverse();
  if (series.length) sec.append(lineChart('Replication lag and unsent window (the primary\'s)', series, [
    { key: 'replication_lag_sec', label: 'lag' }, { key: 'unsent_s', label: 'unsent window' },
  ], v => `${fmtNum(v)} s`));
  sec.append(el('h4', {}, 'Changes'), grid(rowsOf(d.events), eventCols, 'No link or failover group changed in this window.'));
  return sec;
}
