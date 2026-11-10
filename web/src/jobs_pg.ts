// The Jobs tab of a PostgreSQL instance in DBA Dash's shape (task 110): pg_cron's and pgAgent's jobs one line each
// (the shared grid of mssql_jobs.ts with the database, the user, the command and the job page link), the picked job's
// history and changes, and every run of the range as the old page had it (pages.ts jobs(): nothing it showed is
// lost). Data from /api/jobs/history?engine=pg and /api/jobs. The lead points the 'jobs' tab here.
import { get, Row, rowsOf, Table } from './api';
import { jobLink } from './drill';
import { jobsPanel, oneLine } from './mssql_jobs';
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
    const extra: Col[] = [
      { key: 'scheduler' },
      { key: 'datname', label: 'db' }, { key: 'run_as', label: 'run as' },
      { key: 'command', fmt: oneLine },
      { key: 'job_id', label: 'page', fmt: (v, r: Row) => jobLink(ctx, `#${String(v)}`, r.scheduler, Number(v)) },
    ];
    sec.append(await jobsPanel(ctx, 'pg', extra));
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
