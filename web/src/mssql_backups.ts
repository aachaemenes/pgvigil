// The Backups tab of a SQL Server instance (phase 3 wave G, task 98): per database the last full, differential and
// log backup, where it ran, and its age AT THE READ against the threshold of its type. A database in an
// availability group shows the newest backup any monitored replica took. Data from /api/mssql/backups; the lead
// wires the tab (router.ts, main.ts).
//   mssqlBackups               the tab; opened with a database in its address (#/mssqlbackups?i=<id>&db=<name>, the
//                              fleet page's database link) that database's row is first and marked
//   mssqlBackupsFleetSection   the SQL Server sections of the fleet's Backups page, DBA Dash's root Backups: its Summary
//                              grid (one row per instance) and its Detail grid (one row per database, Problems or All),
//                              with the backup findings of every instance in view between them. The same API with no
//                              instance. main.ts appends it below PostgreSQL's sections (the lead's wiring).
import { get, Row, rowsOf, Table } from './api';
import { hashParam, hrefWith } from './dbinfo';
import { fleet, tagsOf } from './fleet';
import { Ctx } from './router';
import { mssqlFindingCols, words } from './mssql_hadr';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, offControl, props, tile } from './ui';

type Parts = 'databases' | 'findings' | 'limits';

// a status is its word and its colour, never the colour alone
// the word's colour: never red, late amber (red for a full backup), ok green, not judged grey; a date and an age take their status's colour
const statusCls = (v: unknown) => v === 'never' ? 'crit' : v === 'late' ? 'warn' : v === 'ok' ? 'ok' : v === 'not judged' ? 'status none' : '';
const critIfFull = (v: unknown) => v === 'late' ? 'crit' : statusCls(v);
const follows = (status: string, full = false) => (v: unknown, r: Row) => v == null || v === '' ? '' : full ? critIfFull(r[status]) : statusCls(r[status]);
const hours = (v: unknown) => v == null ? '' : Number(v) >= 48 ? fmtNum(Math.round(Number(v) / 2.4) / 10) + ' d' : fmtNum(Math.round(Number(v) * 10) / 10) + ' h';
const minutes = (v: unknown) => v == null ? '' : fmtSecs(Number(v) * 60);
// when: the time, and on an availability group the instance whose msdb holds the backup
const when = (from: string) => (v: unknown, r: Row) => !v ? '' : fmtTime(v) + (r.ag_name && r[from] ? ` (on ${String(r[from])})` : '');

const cols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'recovery_model', label: 'recovery model', fmt: words },
  { key: 'ag_name', label: 'availability group', fmt: (v, r) => !v ? '' : `${String(v)} (${String(r.replicas_monitored ?? 0)} of ${String(r.replicas_total ?? 0)} replicas monitored)`,
    cls: (_, r) => r.replicas_unseen === true ? 'warn' : '' },
  { key: 'not_judged', label: 'judged', fmt: v => v ? `no: ${String(v)}` : 'yes' },
  { key: 'full_status', label: 'full', cls: critIfFull },
  { key: 'full_at', label: 'last full', fmt: when('full_from'), cls: follows('full_status', true) },
  { key: 'full_age_hours', label: 'full age', num: true, fmt: hours, cls: follows('full_status', true) },
  { key: 'diff_status', label: 'differential', cls: statusCls },
  { key: 'diff_at', label: 'last differential', fmt: when('diff_from'), cls: follows('diff_status') },
  { key: 'log_status', label: 'log', cls: statusCls },
  { key: 'log_at', label: 'last log', fmt: when('log_from'), cls: follows('log_status') },
  { key: 'log_age_minutes', label: 'log age', num: true, fmt: minutes, cls: follows('log_status') },
  { key: 'nul_at', label: 'backup to NUL', fmt: (v, r) => !v ? '' : `${String(r.nul_type ?? '')} ${fmtTime(v)}`, cls: v => v ? 'warn' : '' },
  // this server's own record of the full backup shown; blank where that backup ran on another replica (open it there)
  { key: 'full_bytes', label: 'full size', num: true, fmt: fmtBytes },
  { key: 'full_compressed_bytes', label: 'compressed', num: true, fmt: fmtBytes },
  { key: 'full_duration_s', label: 'full took', num: true, fmt: fmtSecs },
  { key: 'full_device', label: 'device', fmt: (v, r) => v == null ? (r.full_copy_only === true ? 'copy-only' : '')
    : String(v) + (r.full_copy_only === true ? ', copy-only' : '') + (r.full_snapshot === true ? ', snapshot' : '') },
  // a path stays on one line: cut with an ellipsis, the whole path in the cell's title and in its text (so a copy or an
  // export takes all of it); a wrapping path made every row about three lines tall
  { key: 'full_device_name', label: 'to', fmt: v => v == null || v === '' ? '' : el('span', { class: 'mono', title: String(v),
    style: 'display:block;max-width:24rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px' }, String(v)) },
];

export async function mssqlBackups(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Backups'));
  try {
    const d = await get<Record<Parts, Table | null>>('mssql/backups', { instance: ctx.instance });
    let dbs = rowsOf(d.databases);
    const lim = rowsOf(d.limits)[0];
    // a database named in the address (the fleet page's link): its row first, and marked in words
    const asked = hashParam('db'), picked = asked == null ? undefined : dbs.find(r => r.database_name === asked);
    if (picked) dbs = [picked, ...dbs.filter(r => r !== picked)];
    if (lim?.status && lim.status !== 'ok') sec.append(el('p', { class: 'meta' }, badge(String(lim.status), 'warn'),
      ` mssql_backups: ${String(lim.note ?? '')}${lim.snapshot_at ? `. What follows is its last read (${fmtTime(lim.snapshot_at)}).` : ''}`));
    if (!lim || !lim.snapshot_at) {
      if (!lim?.status) sec.append(el('p', { class: 'empty' }, 'mssql_backups has not run on this server yet (hourly). It needs a user in msdb with db_datareader.'));
      return sec;
    }
    const count = (f: (r: Row) => boolean) => dbs.filter(f).length;
    const noFull = count(r => r.full_status === 'never' || r.full_status === 'late');
    const noLog = count(r => r.log_status === 'never' || r.log_status === 'late');
    sec.append(el('div', { class: 'tiles' },
      tile('databases', fmtNum(dbs.length)),
      tile('without a recent full backup', fmtNum(noFull), noFull ? 'crit' : ''),
      tile('without a recent log backup', fmtNum(noLog), noLog ? 'warn' : ''),
      tile('not judged', fmtNum(count(r => r.not_judged != null))),
    ));
    sec.append(props([
      ['read', `${fmtTime(lim.snapshot_at)} (hourly); every age is the age at that read`],
      ['thresholds', `full ${hours(lim.full_backup_hours)}, differential ${Number(lim.diff_backup_hours) > 0 ? hours(lim.diff_backup_hours) : 'not judged'}, `
        + `log ${String(lim.log_backup_minutes)} min; a database younger than ${String(lim.new_database_hours)} h is not judged`],
      ['not judged by name', String(lim.backup_exclude || 'none')],
      ['msdb\'s backup history reaches back to', lim.history_from ? fmtTime(lim.history_from) : 'msdb holds no backup history'],
    ]));
    const findings = rowsOf(d.findings);
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, mssqlFindingCols));
    sec.append(el('h3', {}, 'Databases'));
    if (asked != null) sec.append(el('p', { class: 'meta', id: 'mssql-backups-picked' }, picked
      ? `Opened for the database ${asked}: its row is the first below.`
      : `The database ${asked} is not in this server's last read.`));
    const tabCols = !picked ? cols : [{ ...cols[0], fmt: (v: unknown) => v === asked ? el('strong', { 'aria-current': 'true' }, String(v)) : String(v ?? '') }, ...cols.slice(1)];
    sec.append(
      el('p', { class: 'meta' }, 'msdb is each server\'s own record. A database in an availability group shows the newest backup of each type that any '
        + 'monitored replica took, with the instance it ran on (its size and device are on that instance\'s tab); a group with a replica that is not monitored is not alarmed on. '
        + 'A backup to the NUL device is no backup and is listed apart.'),
      grid(dbs, tabCols, 'The last read listed no database.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- the fleet's Backups page, the SQL Server sections ------------------------------------------------------

type FleetParts = 'by_instance' | 'databases' | 'findings';
const n0 = (v: unknown) => v == null ? 0 : Number(v);
const count = (bad = '') => ({ num: true, fmt: (v: unknown) => v == null ? '' : fmtNum(v), cls: (v: unknown) => bad && n0(v) > 0 ? bad : '' });
// a rate under a header that names its unit ('full MB/s'): the cell is the number, so the export keeps a number (X7)
const rate = (v: unknown) => v == null ? '' : fmtNum(v);
// where the thresholds are set, for the Configure control that cannot act here
const configureWhy = 'Backup thresholds are not set from this page: they are each instance\'s mssql_thresholds in pgvigil.yaml '
  + '(full_backup_hours, diff_backup_hours, log_backup_minutes, new_database_hours, nul_backup_days, backup_exclude) and reach the repository with the collector.';

const byInstanceCols = (ctx: Ctx): Col[] => [
  { key: 'instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', {}, Number(r.instance_id)) }, String(v ?? '')) },
  { key: 'findings', fmt: (v, r) => !n0(v) ? '' : badge(`${fmtNum(v)} ${String(r.worst)}`, r.worst === 'critical' ? 'crit' : r.worst === 'warning' ? 'warn' : '') },
  { key: 'databases', ...count() },
  { key: 'full_ok', label: 'full ok', ...count() }, { key: 'full_late', label: 'full late', ...count('crit') },
  { key: 'full_never', label: 'full never', ...count('crit') }, { key: 'full_not_judged', label: 'full not judged', ...count() },
  { key: 'diff_ok', label: 'differential ok', ...count() }, { key: 'diff_late', label: 'differential late', ...count('warn') },
  { key: 'diff_never', label: 'differential never', ...count('warn') }, { key: 'diff_not_judged', label: 'differential not judged', ...count() },
  { key: 'log_ok', label: 'log ok', ...count() }, { key: 'log_late', label: 'log late', ...count('warn') },
  { key: 'log_never', label: 'log never', ...count('warn') }, { key: 'log_not_judged', label: 'log not judged', ...count() },
  { key: 'nul_recent', label: 'backup to NUL', ...count('warn') },
  { key: 'model_full', label: 'full recovery', ...count() }, { key: 'model_bulk_logged', label: 'bulk-logged recovery', ...count() },
  { key: 'model_simple', label: 'simple recovery', ...count() },
  { key: 'oldest_full', label: 'oldest full', fmt: fmtTime }, { key: 'oldest_diff', label: 'oldest differential', fmt: fmtTime },
  { key: 'oldest_log', label: 'oldest log', fmt: fmtTime },
  { key: 'full_bytes', label: 'full size', num: true, fmt: fmtBytes },
  { key: 'full_compressed_bytes', label: 'compressed', num: true, fmt: (v, r) => v == null ? ''
    : fmtBytes(v) + (n0(r.full_bytes) > 0 ? ` (${fmtNum(Math.round((1 - n0(v) / n0(r.full_bytes)) * 100))} % saved)` : '') },
  { key: 'fulls_compressed', label: 'fulls compressed', fmt: (v, r) => !n0(r.fulls_here) ? '' : `${fmtNum(v)} of ${fmtNum(r.fulls_here)}` },
  { key: 'full_mb_s', label: 'full MB/s', num: true, fmt: rate }, { key: 'full_write_mb_s', label: 'full write MB/s', num: true, fmt: rate },
  { key: 'diff_bytes', label: 'differential size', num: true, fmt: fmtBytes }, { key: 'diff_mb_s', label: 'differential MB/s', num: true, fmt: rate },
  { key: 'fulls_snapshot', label: 'snapshot backups', fmt: (v, r) => !n0(r.fulls_here) ? '' : n0(v) === 0 ? 'NONE' : n0(v) === n0(r.fulls_here) ? 'ALL' : 'SOME' },
  { key: 'copy_only_fulls', label: 'copy-only fulls', ...count() },
  // no read: the tab's own line; a collection that last failed says its status and note beside its last read
  { key: 'snapshot_at', label: 'read', fmt: (v, r) => !v ? (r.status ? `${String(r.status)}: ${String(r.note ?? '')}` : 'mssql_backups has not run on this server yet')
    : fmtTime(v) + (r.status && r.status !== 'ok' ? ` (last run ${String(r.status)}: ${String(r.note ?? '')})` : ''),
    cls: (v, r) => !v || (r.status && r.status !== 'ok') ? 'warn' : '' },
];

export async function mssqlBackupsFleetSection(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { id: 'mssql-backups-fleet' }, el('h2', {}, 'SQL Server backups'));
  try {
    // the instances in view come from the fleet list and its engines, never from which rows a read returned
    const inView = (await fleet()).instances.filter(r => r.engine === 'sqlserver'
      && (!ctx.tag || (ctx.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(ctx.tag))));
    if (!inView.length) {
      sec.append(el('p', { class: 'empty' }, 'No SQL Server instance in this view.'));
      return sec;
    }
    const ids = new Set(inView.map(r => Number(r.instance_id)));
    const keep = (r: Row) => ids.has(Number(r.instance_id));
    // DBA Dash's default (CustomReportView.cs ResetStatusFilter): a view of one instance lists every database, a view
    // of more the ones with a problem
    let problems = inView.length > 1;
    const d = await get<Record<FleetParts, Table | null>>('mssql/backups', { problems: problems ? 1 : undefined });
    const inst = rowsOf(d.by_instance).filter(keep), findings = rowsOf(d.findings).filter(keep);
    const sum = (k: string) => inst.reduce((a, r) => a + n0(r[k]), 0);
    const noFull = sum('full_late') + sum('full_never'), noLog = sum('log_late') + sum('log_never'), unread = inst.filter(r => !r.snapshot_at).length;
    sec.append(el('div', { class: 'tiles' },
      tile('SQL Server instances', fmtNum(inst.length)),
      tile('databases', fmtNum(sum('databases'))),
      tile('without a recent full backup', fmtNum(noFull), noFull ? 'crit' : ''),
      tile('without a recent log backup', fmtNum(noLog), noLog ? 'warn' : ''),
      tile('not judged', fmtNum(sum('not_judged'))),
      ...(unread ? [tile('instances not read', fmtNum(unread), 'warn')] : [])));
    const cfg = el('button', { type: 'button' }, 'Configure');
    sec.append(el('p', { class: 'meta' }, cfg, ' ', offControl(cfg, configureWhy)));

    sec.append(el('h3', {}, 'SQL Server backups by instance'),
      el('p', { class: 'meta' }, 'One row per SQL Server instance in view, as each was last read (hourly); every count is of its databases at that read. '
        + 'Oldest: the oldest last backup among the databases judged for that type. Sizes and rates are each server\'s own msdb record: '
        + 'a backup that ran on another replica of an availability group counts on that replica\'s row. MB/s is the summed size over the summed duration.'),
      el('div', { id: 'mssql-backups-fleet-instances' }, grid(inst, byInstanceCols(ctx), 'No SQL Server instance in this view.')));

    if (findings.length) sec.append(el('h3', {}, 'SQL Server backup findings'),
      el('div', { id: 'mssql-backups-fleet-findings' }, grid(findings, [{ key: 'instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', {}, Number(r.instance_id)) }, String(v ?? '')) }, ...mssqlFindingCols])));

    const fleetCols: Col[] = [
      { key: 'instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', {}, Number(r.instance_id)) }, String(v ?? '')) },
      { ...cols[0], fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', { db: String(v ?? '') }, Number(r.instance_id)) }, String(v ?? '')) },
      ...cols.slice(1),
    ];
    const total = sum('databases');
    const pick = el('select', { id: 'mssql-backups-fleet-filter' }, el('option', { value: 'problems' }, 'Problems'), el('option', { value: 'all' }, 'All')) as HTMLSelectElement;
    pick.value = problems ? 'problems' : 'all';
    const said = el('span', { id: 'mssql-backups-fleet-count', role: 'status' });
    const box = el('div', { id: 'mssql-backups-fleet-databases' });
    const draw = (rows: Row[]) => {
      said.textContent = `${fmtNum(rows.length)} of ${fmtNum(total)} databases`;
      box.replaceChildren(grid(rows, fleetCols, problems
        ? 'No database of the SQL Server instances in view has a late or missing backup or a recent backup to NUL.' : 'The last reads listed no database.'));
    };
    // a later pick wins over a slower earlier read; a failed read clears the count beside it
    let pickSeq = 0;
    pick.addEventListener('change', () => {
      const mine = ++pickSeq;
      problems = pick.value === 'problems';
      said.textContent = '';
      box.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
      get<Record<FleetParts, Table | null>>('mssql/backups', { problems: problems ? 1 : undefined, part: 'databases' })
        .then(x => { if (mine === pickSeq) draw(rowsOf(x.databases).filter(keep)); })
        .catch(e => { if (mine === pickSeq) { said.textContent = ''; box.replaceChildren(errorBox(e)); } });
    });
    sec.append(el('h3', {}, 'SQL Server databases'),
      el('p', { class: 'meta' }, el('label', { for: 'mssql-backups-fleet-filter' }, 'Show '), pick, ' ', said),
      el('p', { class: 'meta' }, 'Problems: a full, differential or log backup that is late or was never taken, or a backup to the NUL device inside the instance\'s '
        + 'nul_backup_days. A view of one instance opens on All. The database opens its instance\'s Backups tab with its row first; pgvigil keeps the newest backup '
        + 'of each type per database, not a history of backups. Full size, compressed, took, device and path are of a full backup that ran on the row\'s own server '
        + '(blank where it ran on another replica: open that instance). Not read by pgvigil: backup checksums, encryption, password protection, the compression '
        + 'algorithm, damaged and partial or filegroup backups, the partner replica\'s backup.'),
      box);
    draw(rowsOf(d.databases).filter(keep));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
