// The Versions views (task 49): the fleet root (one row per instance: major.minor, the newest minor of its
// major, how many minors behind, end of life, pending maintenance, last restart) and the per-instance tab (the
// version history, the RDS / Aurora upgrade targets and pending maintenance, the cluster's instances, the
// collation check). The release-table columns come from the server's built-in table (internal/versions).
// versionCell is the Summary column's reading of a fleet row. Each view reads the API itself; the routes and
// the tree entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { badge, Col, el, fmtTime, grid } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const yn = (v: unknown) => v == null ? '' : v ? 'yes' : 'no';
const ver = (r: Row) => r.major != null ? `${r.major}.${r.minor}` : String(r.server_version ?? '');

export type VersionLevel = 0 | 1 | 2;   // ok, warning, critical (the Summary grid's levels)

// versionCell: critical when the major is past its end of life; warning when the major ends within 6 months,
// the server is 2 or more minors behind, AWS will apply maintenance on its own within 14 days, the engine version
// is deprecated or a collation version changed; a server
// with no version read is 'none'.
export function versionCell(r: Row): { level: VersionLevel; text: string; detail: string[]; none?: boolean } {
  if (r.server_version_num == null) return { level: 0, text: 'no sample', detail: [], none: true };
  const d: string[] = [];
  let level: VersionLevel = 0;
  if (r.eol_passed) { level = 2; d.push(`PostgreSQL ${r.major} reached end of life ${r.eol}`); }
  else if (r.eol_in_months != null && Number(r.eol_in_months) < 6) { level = 1; d.push(`PostgreSQL ${r.major} ends ${r.eol}`); }
  if (Number(r.behind_by ?? 0) >= 2) { level = Math.max(level, 1) as VersionLevel; d.push(`${r.behind_by} minors behind ${r.major}.${r.latest_minor}`); }
  if (r.next_maintenance && new Date(String(r.next_maintenance)).getTime() - Date.now() < 14 * 86400e3) {
    level = Math.max(level, 1) as VersionLevel; d.push(`maintenance applied by AWS from ${fmtTime(r.next_maintenance)}`);
  }
  if (r.engine_status === 'deprecated') { level = Math.max(level, 1) as VersionLevel; d.push(`engine version ${r.engine_version} is deprecated`); }
  if (Number(r.collation_mismatches ?? 0) > 0) { level = Math.max(level, 1) as VersionLevel; d.push(`${r.collation_mismatches} database(s) with a changed collation version`); }
  return { level, text: ver(r) + (Number(r.behind_by ?? 0) > 0 ? ` (-${r.behind_by})` : ''), detail: d };
}

const behind = (v: unknown, r: Row) => r.newer_than_table ? 'newer than the table'
  : v == null ? '' : Number(v) === 0 ? 'current' : badge(`${v} behind`, Number(v) >= 2 ? 'warn' : '');
const eol = (v: unknown, r: Row) => v == null ? '' : r.eol_passed ? badge(`ended ${v}`, 'crit')
  : Number(r.eol_in_months) < 6 ? badge(`${v} (${r.eol_in_months} mo)`, 'warn') : `${v} (${r.eol_in_months} mo)`;

const fleetCols = (instLink?: (name: string, id: unknown) => Node): Col[] => [
  { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
  { key: 'platform' },
  { key: 'server_version', label: 'version', fmt: (_v, r) => ver(r) },
  { key: 'latest_minor', label: 'newest minor', fmt: (v, r) => v == null ? '' : `${r.major}.${v} (${r.latest_released})` },
  { key: 'behind_by', label: 'behind', num: true, fmt: behind },
  { key: 'released_days_ago', label: 'minor released', num: true, fmt: v => v == null ? '' : `${v} days ago` },
  { key: 'eol', label: 'end of life', fmt: eol },
  { key: 'engine_version', label: 'engine version', fmt: (v, r) => {
      const t = [v, r.aurora_version].filter(x => x != null && x !== '').join(' / ');
      return r.engine_status === 'deprecated' ? badge(t + ' deprecated', 'warn') : t;
    } },
  // dated: AWS applies it on its own (warn); undated: it waits for someone to apply or schedule it
  { key: 'pending_actions', label: 'pending maintenance', num: true, fmt: (v, r) => Number(v) === 0 || v == null ? ''
      : r.next_maintenance ? badge(`${v} from ${fmtTime(r.next_maintenance)}`, 'warn') : badge(`${v} undated`, '') },
  { key: 'auto_minor_version_upgrade', label: 'auto minor upgrade', fmt: yn },
  { key: 'maintenance_window', label: 'window' },
  { key: 'last_restart', label: 'last restart', fmt: fmtTime },
  { key: 'last_change', label: 'last change', fmt: (v, r) => v == null ? '' : `${v}: ${r.last_change_from ?? ''} -> ${r.last_change_to ?? ''} (${fmtTime(r.last_change_at)})` },
  { key: 'extensions_outdated', label: 'extensions outdated', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : '' },
  { key: 'collation_mismatches', label: 'collation', num: true, fmt: v => Number(v) > 0 ? badge(`${v} changed`, 'warn') : '' },
];

// versionsFleetView: the fleet root. keep narrows it to a tag folder; instLink links an instance to its Versions tab.
export async function versionsFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const d = await get<{ fleet: Table | null }>('versions', {});
  let rows = rowsOf(d.fleet);
  if (keep) rows = rows.filter(keep);
  const asOf = rows.find(r => r.release_table_as_of)?.release_table_as_of;
  const ended = rows.filter(r => r.eol_passed).length, behindN = rows.filter(r => Number(r.behind_by ?? 0) > 0).length;
  const pending = rows.filter(r => Number(r.pending_actions ?? 0) > 0).length;
  return el('section', {}, el('h2', {}, 'Versions'),
    el('p', { class: 'meta' }, `${rows.length} instance(s): ${ended} on a major past its end of life, ${behindN} behind the newest minor, ${pending} with pending maintenance.` +
      (asOf ? ` Release table as of ${asOf}.` : '')),
    grid(rows, fleetCols(instLink), 'No instance read yet.'));
}

interface VerInstance { state: Table | null; history: Table | null; targets: Table | null; pending: Table | null; members: Table | null; collations: Table | null; findings: Table | null }

// versionsView: one instance.
export async function versionsView(instance: number): Promise<HTMLElement> {
  const d = await get<VerInstance>('versions', { instance });
  const st = rowsOf(d.state)[0];
  const sec = el('section', {}, el('h2', {}, 'Versions'));
  if (!st || st.server_version_num == null) {
    sec.append(el('p', { class: 'empty' }, 'No version read yet: the versions collection runs hourly.'));
    return sec;
  }
  const cell = versionCell(st);
  sec.append(el('p', { class: 'meta' }, `PostgreSQL ${ver(st)}` + (st.latest_minor != null ? `; the newest ${st.major}.x is ${st.major}.${st.latest_minor} (${st.latest_released})` : '') +
    (st.eol ? `; ${st.major} is supported until ${st.eol}` : '') + `. Last restart ${fmtTime(st.last_restart)}.` +
    (cell.detail.length ? ' ' + cell.detail.join('; ') + '.' : '')));
  sec.append(grid([st], fleetCols().slice(1)));
  const f = rowsOf(d.findings);
  if (f.length) sec.append(el('h3', {}, 'Findings'), grid(f, [{ key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'check' }, { key: 'value' },
    { key: 'suggested' }, { key: 'detail', wide: true }]));
  sec.append(el('h3', {}, 'Version history'), grid(rowsOf(d.history), [
    { key: 'changed_at', label: 'seen', fmt: fmtTime }, { key: 'applied_at', label: 'running since (restart)', fmt: fmtTime },
    { key: 'change' }, { key: 'old_value', label: 'from', wide: true }, { key: 'new_value', label: 'to', wide: true },
  ], 'No version change recorded since the first read.'));
  if (st.engine_version != null) {
    const two = el('div', { class: 'two' });
    two.append(el('div', {}, el('h3', {}, 'Pending maintenance'), grid(rowsOf(d.pending), [
      { key: 'action' }, { key: 'resource', fmt: v => String(v ?? '').replace(/^.*:/, '') },
      { key: 'current_apply', label: 'scheduled', fmt: fmtTime }, { key: 'auto_applied_after', label: 'auto after', fmt: fmtTime },
      { key: 'forced_apply', label: 'forced', fmt: fmtTime }, { key: 'opt_in_status', label: 'opt-in' },
      { key: 'is_present', label: 'state', fmt: v => v ? 'pending' : 'gone (applied or withdrawn)' }, { key: 'description', wide: true },
    ], 'No pending maintenance.')));
    two.append(el('div', {}, el('h3', {}, 'Upgrade targets'), grid(rowsOf(d.targets), [
      { key: 'engine_version', label: 'engine version' }, { key: 'is_major', label: 'major', fmt: yn },
      { key: 'auto_upgrade', label: 'auto upgrade', fmt: yn }, { key: 'description', wide: true },
    ], 'No upgrade target listed.')));
    sec.append(two);
    const m = rowsOf(d.members);
    if (m.length) sec.append(el('h3', {}, 'Instances'), grid(m, [
      { key: 'id' }, { key: 'is_writer', label: 'role', fmt: v => v ? 'writer' : 'reader' }, { key: 'class' },
      { key: 'engine_version', label: 'engine version' }, { key: 'auto_minor_version_upgrade', label: 'auto minor upgrade', fmt: yn },
      { key: 'maintenance_window', label: 'window' },
    ]));
  }
  sec.append(el('h3', {}, 'Collation versions'),
    el('p', { class: 'meta' }, 'The version each database recorded against the operating system library now (PostgreSQL 15+). A change means text indexes may be out of order until rebuilt.'),
    grid(rowsOf(d.collations), [
      { key: 'datname', label: 'database' }, { key: 'provider', fmt: v => ({ c: 'libc', i: 'ICU', b: 'builtin' } as Record<string, string>)[String(v)] ?? String(v ?? '') },
      { key: 'locale' }, { key: 'recorded_version', label: 'recorded' }, { key: 'actual_version', label: 'library now' },
      { key: 'mismatch', label: 'state', fmt: v => v ? badge('changed: REINDEX', 'warn') : '' },
    ], 'No collation read (PostgreSQL 14 or older, or not read yet).'));
  return sec;
}
