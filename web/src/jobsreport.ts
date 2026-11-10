// The Job report tab of one instance and the fleet Jobs root (task 38; DBADash's Jobs tab): every pg_cron or
// pgAgent job with its last run, runs, failures, average and longest run over 7 and 30 days, the failures in a
// row, the next run (pg_cron's from pgvigil's own schedule parser, pgAgent's its own) and a duration trend over
// the window (at least the last 7 days); at the root every failing, missed or over-average job of the fleet.
// Data from /api/jobsreport (?instance= for one instance). The shell mounts jobsReportView(ctx) and
// jobsReportFleetView(keep, instLink, ctx) (the lead wires the routes and the tabs); ctx makes each job name a link
// to its job page (task 65).
import { jobLink } from './drill';
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const failed = ['failed', 'internal error', 'aborted'];
const runBadge = (v: unknown, r: Row) => {
  const s = String(v ?? '');
  if (!s) return 'no run in 30 days';
  return badge(r.last_running ? 'running' : s, failed.includes(s) ? 'crit' : s === 'succeeded' ? 'ok' : 'warn');
};
// a short run keeps its tenths; a long one reads as minutes and hours
const dur = (v: unknown) => v == null ? '' : Number(v) < 60 ? fmtNum(v) + ' s' : fmtSecs(v);
const streak = (v: unknown) => Number(v) >= 3 ? badge(fmtNum(v), 'crit') : Number(v) > 0 ? badge(fmtNum(v), 'warn') : '0';
const fails = (v: unknown) => Number(v) > 0 ? badge(fmtNum(v), 'warn') : '0';
const weekMs = 7 * 24 * 3600 * 1000;
const jobLabel = (r: Row) => `${String(r.scheduler ?? '')} ${String(r.job_name ?? r.job_id ?? '')}`;

// statusRank orders the status column: failing or missed first, then over average, ok, disabled, gone
function statusRank(r: Row): number {
  if (r.is_present === false) return 6;
  if (r.active === false) return 5;
  if (Number(r.fail_streak) >= 3 || r.missed) return 0;
  if (r.over_average) return 1;
  if (Number(r.fail_streak) > 0) return 2;
  return r.schedule_note ? 3 : 4;
}
// withRank adds the rank the status column sorts by (the grid sorts on a row field)
const withRank = (rows: Row[]): Row[] => rows.map(r => ({ ...r, status_rank: statusRank(r) }));

// status sums up a job's problems in a word or two, the worst first
function status(r: Row): string | Node {
  if (r.is_present === false) return 'gone';
  if (r.active === false) return 'disabled';
  const out: Node[] = [];
  if (Number(r.fail_streak) >= 3) out.push(badge(`failing (${fmtNum(r.fail_streak)} in a row)`, 'crit'));
  else if (Number(r.fail_streak) > 0) out.push(badge('last run failed', 'warn'));
  if (r.missed) out.push(badge('missed', 'crit'));
  if (r.over_average) out.push(badge('over 2x average', 'warn'));
  if (r.schedule_note) out.push(badge('schedule not judged', ''));
  if (!out.length) return badge('ok', 'ok');
  const span = el('span');
  out.forEach((n, i) => { if (i) span.append(' '); span.append(n); });
  return span;
}

// withJobLinks: the job name opens the job page (task 65); fleet = each row's own instance
const withJobLinks = (cols: Col[], ctx?: Ctx, fleet = false): Col[] => !ctx ? cols : cols.map(c => c.key !== 'job_name' ? c
  : { ...c, fmt: (v: unknown, r: Row) => jobLink(ctx, String(v ?? r.job_id ?? ''), r.scheduler, r.job_id, fleet ? Number(r.instance_id) : ctx.instance) });

const jobCols: Col[] = [
  { key: 'job_name', label: 'job', fmt: (v, r) => String(v ?? r.job_id ?? '') },
  { key: 'scheduler' },
  { key: 'status_rank', label: 'status', num: true, fmt: (_v, r) => status(r) },
  { key: 'schedule', fmt: (v, r) => String(v ?? '') + (r.schedule_note ? ` (${String(r.schedule_note)})` : '') },
  { key: 'last_status', label: 'last run', fmt: runBadge },
  { key: 'last_start', label: 'last start', fmt: fmtTime },
  { key: 'last_duration_secs', label: 'took', num: true, fmt: dur },
  { key: 'next_run', label: 'next run', fmt: (v, r) => r.active === false || r.is_present === false ? '' : fmtTime(v) },
  { key: 'fail_streak', label: 'failed in a row', num: true, fmt: streak },
  { key: 'runs_7d', label: 'runs 7 d', num: true },
  { key: 'failures_7d', label: 'failed 7 d', num: true, fmt: fails },
  { key: 'avg_7d_secs', label: 'avg 7 d', num: true, fmt: dur },
  { key: 'max_7d_secs', label: 'max 7 d', num: true, fmt: dur },
  { key: 'runs_30d', label: 'runs 30 d', num: true },
  { key: 'failures_30d', label: 'failed 30 d', num: true, fmt: fails },
  { key: 'avg_30d_secs', label: 'avg 30 d', num: true, fmt: dur },
  { key: 'max_30d_secs', label: 'max 30 d', num: true, fmt: dur },
  { key: 'last_ok', label: 'last success', fmt: fmtTime },
  { key: 'datname', label: 'db' },
  { key: 'run_as', label: 'run as' },
  { key: 'last_message', label: 'last message', wide: true },
  { key: 'command', wide: true },
];

// pivot turns the trend rows (one per bucket and job) into one row per bucket with a column per job.
function pivot(rows: Row[], value: string): { rows: Row[]; series: { key: string; label: string }[] } {
  const by = new Map<string, Row>(), series = new Map<string, string>();
  for (const r of rows) {
    const k = `j_${String(r.scheduler)}_${String(r.job_id)}`;
    series.set(k, `${String(r.scheduler)} ${String(r.job_name)}`);
    const at = String(r.snapshot_at);
    if (!by.has(at)) by.set(at, { snapshot_at: at });
    by.get(at)![k] = r[value];
  }
  return { rows: [...by.values()].sort((a, b) => String(a.snapshot_at).localeCompare(String(b.snapshot_at))),
           series: [...series].map(([key, label]) => ({ key, label })) };
}

export async function jobsReportView(ctx: Ctx): Promise<HTMLElement> {
  const w = window_(ctx);
  // the trend reads at least the last 7 days of the window's end
  const from = new Date(Math.min(Date.parse(w.from), Date.parse(w.to) - weekMs)).toISOString();
  const d = await get<Record<'jobs' | 'trend' | 'checks', Table | null>>('jobsreport', { instance: ctx.instance, from, to: w.to });
  const jobs = withRank(rowsOf(d.jobs)), checks = rowsOf(d.checks), trend = rowsOf(d.trend);
  const sec = el('section', {}, el('h2', {}, 'Job report'));
  if (!jobs.length) {
    sec.append(el('p', { class: 'empty' }, 'No scheduled jobs: pg_cron or pgAgent is not installed in the connected database, or nothing is scheduled (the jobs collection runs every minute).'));
    return sec;
  }
  const live = jobs.filter(r => r.is_present !== false && r.active !== false);
  const failing = live.filter(r => Number(r.fail_streak) >= 3).length, missed = live.filter(r => r.missed).length;
  const slow = live.filter(r => r.over_average).length;
  const runs7 = jobs.reduce((a, r) => a + Number(r.runs_7d ?? 0), 0), fail7 = jobs.reduce((a, r) => a + Number(r.failures_7d ?? 0), 0);
  sec.append(el('div', { class: 'tiles' },
    tile('jobs', `${fmtNum(live.length)} active of ${fmtNum(jobs.length)}`),
    tile('failing (3+ in a row)', fmtNum(failing), failing ? 'crit' : 'ok'),
    tile('missed schedule', fmtNum(missed), missed ? 'crit' : 'ok'),
    tile('over 2x average', fmtNum(slow), slow ? 'warn' : 'ok'),
    tile('runs / failed (7 d)', `${fmtNum(runs7)} / ${fmtNum(fail7)}`, fail7 ? 'warn' : '')));
  sec.append(el('p', { class: 'meta' },
    `Jobs read ${fmtTime(jobs[0].snapshot_at)}. Failing: the last 3 or more finished runs failed. Over 2x average: the latest run (a running one by its age) `
    + 'took over twice the average of the other successful runs of 30 days (3 or more) and 10 s more. Missed: pg_cron, no run since the scheduled '
    + 'time before the latest one (two scheduled runs without one; schedules rarer than about every 12 days are not judged, the history is 30 days); '
    + "pgAgent, its own next run over 5 minutes past. The schedule is read in pg_cron's cron.timezone; the times shown are this browser's local time; the next run is as of the read."));
  if (checks.length) {
    sec.append(el('h3', {}, 'Checks'), grid(checks, [
      { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'check' }, { key: 'object', label: 'job' },
      { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
    ]));
  }
  sec.append(el('h3', {}, 'Jobs'), grid(jobs, withJobLinks(jobCols, ctx)));
  const span = Date.parse(w.to) - Date.parse(from);
  const per = span > 72 * 3600 * 1000 ? 'day' : 'hour';
  const avg = pivot(trend, 'avg_secs'), max = pivot(trend, 'max_secs');
  sec.append(el('h3', {}, `Duration trend (${per === 'day' ? 'per day' : 'per hour'}, ${rangeLabel(ctx)}, at least 7 days)`),
    el('div', { class: 'charts' },
      lineChart(`Average run per ${per}`, avg.rows, avg.series, v => dur(v)),
      lineChart(`Longest run per ${per}`, max.rows, max.series, v => dur(v))));
  const fl = trend.filter(r => Number(r.failures) > 0);
  if (fl.length) {
    sec.append(el('h3', {}, `Failures per ${per}`), grid(fl, [
      { key: 'snapshot_at', label: per, fmt: fmtTime },
      { key: 'job_name', label: 'job', fmt: (_v, r) => jobLink(ctx, jobLabel(r), r.scheduler, r.job_id) },
      { key: 'failures', label: 'failed', num: true, fmt: fails },
      { key: 'runs', num: true },
    ]));
  }
  return sec;
}

// jobsReportFleetView: every failing, missed or over-average job of the fleet, the worst first (keep narrows it to
// a tag folder; instLink makes the instance name a link to its Job report tab).
export async function jobsReportFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node, ctx?: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'counts' | 'jobs', Table | null>>('jobsreport');
  let rows = withRank(rowsOf(d.jobs));
  if (keep) rows = rows.filter(keep);
  const c = rowsOf(d.counts)[0] ?? {};
  const failing = rows.filter(r => Number(r.fail_streak) >= 3).length, missed = rows.filter(r => r.missed).length;
  const slow = rows.filter(r => r.over_average).length, lastFailed = rows.filter(r => Number(r.fail_streak) > 0 && Number(r.fail_streak) < 3).length;
  return el('section', {}, el('h2', {}, 'Jobs'),
    el('div', { class: 'tiles' },
      tile('jobs in the fleet', keep ? '-' : `${fmtNum(c.jobs)} on ${fmtNum(c.instances)} instances`),
      tile('failing (3+ in a row)', fmtNum(failing), failing ? 'crit' : 'ok'),
      tile('missed schedule', fmtNum(missed), missed ? 'crit' : 'ok'),
      tile('last run failed', fmtNum(lastFailed), lastFailed ? 'warn' : 'ok'),
      tile('over 2x average', fmtNum(slow), slow ? 'warn' : 'ok')),
    el('p', { class: 'meta' }, 'Every active job of the fleet whose last finished run failed, that missed its schedule, or whose latest run took over twice its average; '
      + 'the failing and missed first. The rules are on each instance\'s Job report tab.'),
    grid(rows, [
      { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
      { key: 'platform' },
      ...withJobLinks(jobCols, ctx, true).filter(x => !['datname', 'run_as', 'command', 'runs_30d', 'failures_30d', 'avg_7d_secs', 'max_7d_secs'].includes(x.key)),
    ], 'No failing, missed or slow job in the fleet.'));
}
