// The Maintenance tab of a SQL Server instance (task 410, migration 0161): Ola Hallengren's maintenance solution -
// every rule met or not (where it is installed and its version, each job it makes with its schedule and clean-up age,
// a command that failed in the last day), the jobs that run it with their schedules and last runs, each database's
// last maintenance from the solution's CommandLog, the CommandLog over the window with its failures first, and each
// database's data purity flag. Data from /api/mssql/maintenance (mssql_maintenance, read hourly; the jobs from
// mssql_jobs). Nothing here starts a job: the Jobs page and the actions door do.
import { get, Row, rowsOf, Table } from './api';
import { jobLink } from './drill';
import { Ctx, window_ } from './router';
import { zoneName } from './tz';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

// The tab key of the slice's page (the router's entry carries the same key).
export const mssqlMaintenanceTab = 'mssqlmaintenance';

type Parts = Record<'checks' | 'parts' | 'databases' | 'jobs' | 'last' | 'commandlog' | 'runs', Table | null>;

// The status word carries the meaning, the colour repeats it: green met; amber info (shown, never a finding) and
// warning; red critical; off, not read and not applicable stay grey - never green.
const statusCls = (s: unknown): string => s === 'ok' ? 'status ok' : s === 'info' || s === 'warning' ? 'status warn' : s === 'critical' ? 'status crit' : '';
// msdb's last outcome: 5 with no last run is a job never run (the solution's fresh jobs), 2 a retry
const outcome = (v: unknown, r: Row): string => v == null || (Number(v) === 5 && r.last_run_at == null) ? 'never run'
  : Number(v) === 1 ? 'succeeded' : Number(v) === 0 ? 'failed' : Number(v) === 2 ? 'retry' : Number(v) === 3 ? 'cancelled' : 'unknown';
const listText = (v: unknown): string => Array.isArray(v) ? v.map(String).join(', ') : v == null ? '' : String(v);
const secs = (v: unknown): string => v == null ? '' : `${fmtNum(v)} s`;

export async function mssqlMaintenanceView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Maintenance'));
  let d: Parts;
  try {
    d = await get<Parts>('mssql/maintenance', { instance: ctx.instance, ...window_(ctx) });
  } catch (e) {
    sec.append(errorBox(e instanceof Error ? e : new Error(String(e))));
    return sec;
  }
  const checks = rowsOf(d.checks), count = (s: string) => checks.filter(r => r.status === s).length;
  sec.append(
    el('p', { class: 'meta' }, 'Ola Hallengren\'s maintenance solution as this instance holds it: where it is installed and its version, '
      + 'each job it makes with its schedule and clean-up age, and the history in its CommandLog. The jobs and the ages are judged as '
      + 'dbachecks judges them; a job the solution makes that is not here is shown as not present, a warning only where an expected value '
      + 'says the site expects it (the Configuration tab\'s Checks, kind job). Without the solution the page says not installed, never a warning.'),
    el('p', { class: 'meta' }, badge('ok', 'ok'), ' met; ', badge('info', 'warn'), ' shown, never raised as a finding; ', badge('warning', 'warn'), ' and ',
      badge('critical', 'crit'), ' a finding; ', badge('off', ''), ' not expected here; ', badge('not read', ''), ' with the reason beside it, never green.'),
    el('p', { class: 'meta counts' }, `${checks.length} rows: ${count('critical')} critical, ${count('warning')} warning, ${count('info')} info, ${count('ok')} ok, `
      + `${count('off')} off, ${count('not read')} not read.`),
    grid(checks, [
      { key: 'check_name', label: 'check' }, { key: 'object', label: 'on' }, { key: 'value' }, { key: 'expected' },
      { key: 'set_at', label: 'set at', fmt: v => v == null ? '' : String(v) }, { key: 'source' },
      { key: 'status', cls: v => statusCls(v) }, { key: 'detail', wide: true }, { key: 'at', label: 'read', fmt: fmtTime },
    ], 'No rule to show: the mssql_maintenance collection has not read this instance yet.'));

  // what the read covered
  const parts = rowsOf(d.parts).filter(p => p.note);
  if (parts.length) sec.append(...parts.map(p => el('p', { class: p.is_read === false ? 'empty' : 'meta' }, `${String(p.part)}: ${String(p.note)}`)));
  sec.append(grid(rowsOf(d.runs), [{ key: 'collection' }, { key: 'status', fmt: v => v == null ? 'no run yet' : String(v) },
    { key: 'snapshot_at', label: 'last run', fmt: fmtTime }, { key: 'note', wide: true }]));

  // the jobs
  sec.append(el('h3', {}, 'Jobs'), el('p', { class: 'meta' }, 'The jobs that run the solution, as its rules match them: by what a step calls '
    + '(a procedure with its parameters, a clean-up), else the solution\'s description and the role\'s name. Each with its role and the clean-up age its steps name. '
    + 'The solution makes its jobs without schedules: a job with none runs only when started by hand. A job\'s name opens its history.'),
  grid(rowsOf(d.jobs), [
    { key: 'name', label: 'job', fmt: (v, r) => jobLink(ctx, String(v ?? ''), 'sqlagent', r.job_id) }, { key: 'role' }, { key: 'enabled', cls: v => v === true ? 'status ok' : 'status warn', fmt: v => v === true ? 'enabled' : 'disabled' },
    { key: 'enabled_schedules', label: 'enabled schedules', num: true, cls: v => Number(v ?? 0) > 0 ? '' : 'status warn', fmt: fmtNum },
    { key: 'schedule_text', label: 'schedules', wide: true }, { key: 'next_run_at', label: 'next run', fmt: fmtTime },
    { key: 'last_outcome', label: 'last outcome', cls: v => Number(v) === 0 ? 'status warn' : Number(v) === 1 ? 'status ok' : '', fmt: outcome },
    { key: 'last_run_at', label: 'last run', fmt: fmtTime }, { key: 'last_duration_s', label: 'duration', num: true, fmt: secs },
    { key: 'cleanup_age', label: 'clean-up age', fmt: v => v == null ? '' : String(v) },
    { key: 'ola_made', label: 'made by the solution', fmt: v => v === true ? 'yes' : '' },
  ], 'No job runs the solution.'));

  // each database's last maintenance
  sec.append(el('h3', {}, 'Last maintenance per database'), el('p', { class: 'meta' }, 'From the solution\'s CommandLog as read: the newest successful command of each kind. A backup\'s kind is read from its whole command on the server '
      + '(native, LiteSpeed, Red Gate SQL Backup, SQL Safe, Data Domain Boost); the integrity check is the CHECKDB family (CHECKDB, CHECKALLOC, CHECKTABLE, CHECKCATALOG, CHECKFILEGROUP).'),
    grid(rowsOf(d.last), [
      { key: 'database_name', label: 'database' }, { key: 'last_full', label: 'full backup', fmt: fmtTime }, { key: 'last_diff', label: 'differential', fmt: fmtTime },
      { key: 'last_log', label: 'log backup', fmt: fmtTime }, { key: 'last_integrity', label: 'integrity check', fmt: fmtTime },
      { key: 'last_index', label: 'index or statistics', fmt: fmtTime }, { key: 'index_seconds', label: 'its duration', num: true, fmt: secs }, { key: 'failed', label: 'failed commands', num: true, cls: v => Number(v ?? 0) > 0 ? 'status warn' : '', fmt: fmtNum },
    ], 'No CommandLog row read yet.'));

  // the CommandLog over the window
  const log = rowsOf(d.commandlog);
  sec.append(el('h3', {}, 'CommandLog'), el('p', { class: 'meta' }, `The solution's commands that started in the chosen window, failures first${log.length >= 2000 ? ' (the first 2,000)' : ''}. `
    + `Times are stored in UTC (converted from the server's own clock at the read) and shown in ${zoneName()}. ` + 'A failed command\'s message is the one CommandLog keeps; where it keeps none, the job\'s history has it.'),
  grid(log, [
    { key: 'database_name', label: 'database' }, { key: 'object_name', label: 'object', fmt: (v, r) => [r.schema_name, v, r.index_name ?? r.statistics_name].filter(x => x != null && x !== '').map(String).join('.') },
    { key: 'command_type', label: 'command' }, { key: 'start_at', label: 'started', fmt: fmtTime }, { key: 'seconds', num: true, fmt: secs },
    { key: 'status', cls: v => v === 'ok' ? 'status ok' : v === 'failed' ? 'status warn' : '' },
    { key: 'error_number', label: 'error', num: true, fmt: v => v == null || Number(v) === 0 ? '' : String(v) },
    { key: 'error_message', label: 'message', wide: true }, { key: 'log_database', label: 'CommandLog in' },
  ] as Col[], 'No CommandLog row in this window.'));

  // where the solution is and each database's purity flag
  sec.append(el('h3', {}, 'Databases'), el('p', { class: 'meta' }, 'Each database the read looked into: the solution\'s objects seen there and their version, '
    + 'whether its CommandLog is read, and its data purity flag (DBCC DBINFO: off only for a database made before SQL Server 2005 that no CHECKDB WITH DATA_PURITY has run on).'),
  grid(rowsOf(d.databases).map((r: Row) => ({ ...r, version: Object.values((r.versions ?? {}) as Record<string, unknown>).map(String).filter((v, i, a) => a.indexOf(v) === i).join(', ') })), [
    { key: 'database_name', label: 'database' },
    { key: 'objects', label: 'the solution\'s objects', fmt: (v, r) => r.install_read === true ? listText(v) || 'none' : '' },
    { key: 'version' }, { key: 'note', label: 'read', fmt: (v, r) => r.install_read === true ? 'read' : badge(String(v ?? 'not read'), '') },
    { key: 'commandlog_note', label: 'CommandLog', fmt: v => v == null ? '' : badge(String(v), '') },
    { key: 'purity_on', label: 'data purity', cls: v => v === true ? 'status ok' : v === false ? 'status warn' : '',
      fmt: (v, r) => r.purity_read !== true ? badge(String(r.purity_note ?? 'not read'), '') : v === true ? 'on' : 'off' },
    { key: 'create_version', label: 'create version', num: true, fmt: fmtNum },
  ], 'No database was read.'));
  return sec;
}
