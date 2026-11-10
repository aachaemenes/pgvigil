// The Jobs tab of a SQL Server instance (phase 3 wave G, task 98): the SQL Server Agent jobs with their last outcome,
// what runs now, the failed runs of the range with the step that failed and its message, and the runs per job over
// the range. Data from /api/mssql/jobs; the lead wires the tab (router.ts, main.ts).
import { get, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { jsonRows, mssqlFindingCols, yes } from './mssql_hadr';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

type Parts = 'jobs' | 'running' | 'failed' | 'runs' | 'findings' | 'read';

const outcomeCls = (_: unknown, r: Row) => r.last_outcome === 0 ? 'crit' : r.last_outcome === 3 ? 'warn' : '';
const outcomeText = (v: unknown) => v === 0 ? 'failed' : v === 1 ? 'succeeded' : v === 2 ? 'retry' : v === 3 ? 'cancelled' : v === 5 ? 'never run' : '';

const jobCols: Col[] = [
  { key: 'name', label: 'job' },
  { key: 'enabled', fmt: yes, cls: v => v === false ? 'warn' : '' },
  { key: 'last_outcome_text', label: 'last outcome', cls: outcomeCls },
  { key: 'last_run_at', label: 'last run', fmt: fmtTime },
  { key: 'last_duration_s', label: 'took', num: true, fmt: fmtSecs },
  { key: 'next_run_at', label: 'next run', fmt: (v, r) => v ? fmtTime(v) : Number(r.schedules ?? 0) === 0 ? 'no schedule' : Number(r.enabled_schedules ?? 0) === 0 ? 'schedule disabled' : '' },
  { key: 'running_since', label: 'running since', fmt: fmtTime },
  { key: 'schedule_names', label: 'schedules' },
  { key: 'owner' }, { key: 'category' },
  { key: 'last_message', label: 'last message', wide: true },
];

const runningCols: Col[] = [
  { key: 'name', label: 'job' }, { key: 'running_since', label: 'started', fmt: fmtTime },
  { key: 'running_s', label: 'running for (at the read)', num: true, fmt: fmtSecs },
  { key: 'avg_duration_s', label: 'average of its good runs', num: true, fmt: fmtSecs },
  { key: 'running_after_step', label: 'last step finished', num: true },
];

const failedCols: Col[] = [
  { key: 'run_at', label: 'run', fmt: fmtTime }, { key: 'job' },
  { key: 'step_id', label: 'step', num: true }, { key: 'step_name', label: 'step name' },
  { key: 'duration_s', label: 'took', num: true, fmt: fmtSecs },
  { key: 'sql_message_id', label: 'error', num: true, fmt: v => v == null || Number(v) === 0 ? '' : String(v) },
  { key: 'message', wide: true },
];

const runCols: Col[] = [
  { key: 'job' }, { key: 'runs', num: true }, { key: 'succeeded', num: true },
  { key: 'failed', num: true, cls: v => Number(v) > 0 ? 'crit' : '' }, { key: 'cancelled', num: true },
  { key: 'avg_duration_s', label: 'average (good runs)', num: true, fmt: fmtSecs },
  { key: 'max_duration_s', label: 'longest', num: true, fmt: fmtSecs },
  { key: 'last_run_at', label: 'last run', fmt: fmtTime },
];

const stepCols: Col[] = [
  { key: 'step_id', label: 'step', num: true }, { key: 'step_name', label: 'name' }, { key: 'subsystem' },
  { key: 'database_name', label: 'database' }, { key: 'last_outcome', label: 'last outcome', fmt: outcomeText, cls: v => v === 0 ? 'crit' : '' },
  { key: 'last_run_utc', label: 'last run', fmt: fmtTime }, { key: 'last_duration_s', label: 'took', num: true, fmt: fmtSecs },
];

export async function mssqlJobs(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Agent jobs (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<Parts, Table | null>>('mssql/jobs', { instance: ctx.instance, ...window_(ctx) });
    const jobs = rowsOf(d.jobs), running = rowsOf(d.running), failed = rowsOf(d.failed), read = rowsOf(d.read)[0];
    if (!read) {
      sec.append(el('p', { class: 'empty' }, 'mssql_jobs has not read this server yet. It needs a user in msdb with db_datareader; '
        + 'the Collections page says so when the login lacks it.'));
      return sec;
    }
    if (read.status && read.status !== 'ok') sec.append(el('p', { class: 'meta' }, badge(String(read.status), 'warn'), ` ${String(read.note ?? '')}`));
    sec.append(el('div', { class: 'tiles' },
      tile('jobs', fmtNum(jobs.length)),
      tile('last outcome failed', fmtNum(jobs.filter(j => j.last_outcome === 0).length), jobs.some(j => j.last_outcome === 0) ? 'crit' : ''),
      tile('failed runs in the window', fmtNum(failed.length), failed.length ? 'warn' : ''),
      tile('running now', fmtNum(running.length)),
      tile('disabled', fmtNum(jobs.filter(j => j.enabled === false).length)),
    ));
    const findings = rowsOf(d.findings);
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, mssqlFindingCols));
    sec.append(el('h3', {}, 'Running now'), grid(running, runningCols, 'No job was running at the last read.'));
    sec.append(el('h3', {}, 'Failed runs in this window'),
      grid(failed, failedCols, 'No job failed in this window.'));
    sec.append(el('h3', {}, 'Jobs'), el('p', { class: 'meta' }, `As read ${fmtTime(read.snapshot_at)}. A step's command is never read: it can hold a password.`),
      grid(jobs, jobCols, 'This server has no Agent job.'));
    sec.append(el('h3', {}, 'Runs per job in this window'), grid(rowsOf(d.runs), runCols, 'No run in this window.'));
    // the steps of each job, one disclosure per job: reachable by keyboard, named by the job
    if (jobs.length) {
      sec.append(el('h3', {}, 'Steps'));
      for (const j of jobs) {
        const steps = jsonRows(j.steps);
        if (!steps.length) continue;
        sec.append(el('details', {}, el('summary', {}, `${String(j.name)} (${steps.length} step${steps.length === 1 ? '' : 's'})`), grid(steps, stepCols)));
      }
    }
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
