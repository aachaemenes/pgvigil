// The Backups tab of a SQL Server instance (phase 3 wave G, task 98): per database the last full, differential and
// log backup, where it ran, and its age AT THE READ against the threshold of its type. A database in an
// availability group shows the newest backup any monitored replica took. Data from /api/mssql/backups; the lead
// wires the tab (router.ts, main.ts).
import { get, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { mssqlFindingCols, words } from './mssql_hadr';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';

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
    const dbs = rowsOf(d.databases), lim = rowsOf(d.limits)[0];
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
    sec.append(el('h3', {}, 'Databases'),
      el('p', { class: 'meta' }, 'msdb is each server\'s own record. A database in an availability group shows the newest backup of each type that any '
        + 'monitored replica took, with the instance it ran on (its size and device are on that instance\'s tab); a group with a replica that is not monitored is not alarmed on. '
        + 'A backup to the NUL device is no backup and is listed apart.'),
      grid(dbs, cols, 'The last read listed no database.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
