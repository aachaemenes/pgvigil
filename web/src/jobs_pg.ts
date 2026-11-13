// The Jobs tab of a PostgreSQL instance in DBA Dash's shape (task 110): pg_cron's and pgAgent's jobs one line each
// (the shared grid of mssql_jobs.ts with the database, the user, the command and the job page link), the picked job's
// history and changes, and every run of the range as the old page had it (pages.ts jobs(): nothing it showed is
// lost). Data from /api/jobs/history?engine=pg and /api/jobs. The lead points the 'jobs' tab here.
// Task 154: the shared panel carries the versions (pg_cron's and pgAgent's scripts with their diffs) and the status
// against the job thresholds. Task 161 (jobs_running.ts): the pg_cron schedule in words, Run now on a pgAgent job, and
// under the grid Running now with Stop, the pgAgent step log, the exclusions and the job actions' audit.
import { get, Row, rowsOf, Table } from './api';
import { jobLink } from './drill';
import { jobsPanel, oneLine } from './mssql_jobs';
import { cronInWords, jobsRunningPanel, pgJobActionCol } from './jobs_running';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtSecs, fmtTime, grid } from './ui';

const runBadge = (v: unknown) => {
  const s = String(v ?? '');
  return ['failed', 'internal error'].includes(s) ? badge(s, 'crit') : s === 'aborted' ? badge(s, 'warn') : s;
};

export async function jobsPgView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Jobs (${rangeLabel(ctx)})`));
  if (!ctx.instance) { sec.append(el('p', { class: 'empty' }, 'Pick an instance.')); return sec; }
  try {
    const run = await pgJobActionCol(ctx, () => window.dispatchEvent(new HashChangeEvent('hashchange')));
    const extra: Col[] = [
      { key: 'scheduler' },
      { key: 'datname', label: 'db' }, { key: 'run_as', label: 'run as' },
      { key: 'command', fmt: oneLine },
      { key: 'job_id', label: 'page', fmt: (v, r: Row) => jobLink(ctx, `#${String(v)}`, r.scheduler, Number(v)) },
      // task 161: the pg_cron schedule in words, Run now on a pgAgent job
      { key: '_schedule_words', label: 'schedule in words (cron.timezone)', fmt: (_v, r: Row) => r.scheduler === 'pg_cron' ? cronInWords(r.schedule) : '' },
      run,
    ];
    const panel = await jobsPanel(ctx, 'pg', extra);
    if (run.offNote) sec.append(run.offNote);   // Run now off for the whole instance, where a pgAgent job shows the button
    sec.append(panel);
    sec.append(await jobsRunningPanel(ctx, run.stopNote));   // one sentence above for Run now AND Stop: not said again below
    const d = await get<Record<'runs', Table | null>>('jobs', { instance: ctx.instance, ...window_(ctx), part: 'runs' });
    const runCols: Col[] = [
      { key: 'start_time', label: 'start', fmt: fmtTime },
      { key: 'duration_secs', label: 'took', num: true, fmt: fmtSecs },
      { key: 'status', fmt: runBadge },
      { key: 'scheduler' }, { key: 'job_name', label: 'job', fmt: (v, r) => jobLink(ctx, String(v ?? r.job_id), r.scheduler, r.job_id) },
      { key: 'run_id', label: 'run', num: true }, { key: 'datname', label: 'db' },
      { key: 'return_message', label: 'message', fmt: oneLine },
    ];
    sec.append(el('h3', {}, `All runs (${rangeLabel(ctx)})`), grid(rowsOf(d.runs), runCols, 'No job runs started in this range.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
