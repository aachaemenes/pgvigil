// The PostgreSQL Jobs page's twins of DBA Dash's Running Jobs, Agent Job Actions, job exclusions and per-step job stats
// (task 161), for jobs_pg.ts to append under the jobs grid:
//   - Running now: every pg_cron / pgAgent run the newest read still saw running - started, running for, the job's
//     average over its successful runs of 30 days, the estimated end from it, over twice the average marked, pgAgent's
//     current step - with Stop (the run's backend cancelled through the actions door);
//   - pgJobActionCol: the jobs grid's column with Run now on a pgAgent job (jobnextrun = now());
//   - the pgAgent step log: per step of each pgAgent job its runs, outcomes and durations in the range, and its runs;
//   - Exclusions: the patterns that leave pg_cron / pgAgent jobs out of the job checks, fleet-wide or this instance's;
//   - the job actions' audit rows.
// Stop and Run now are off by default (the instance's actions: list in the config) and every attempt is audited.
// Data: /api/jobs/running, /api/jobs/actions/stop|start, /api/jobs/steps, /api/jobs/exclusions, /api/jobs/history.
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, props } from './ui';

type Kind = 'job_stop' | 'job_start';
interface OnOff { on: boolean; reason?: string }
interface RunningState { actions: Record<Kind, OnOff>; running: Table | null; log: Table | null }

const labels: Record<Kind, string> = { job_stop: 'Stop', job_start: 'Run now' };
const text = (v: unknown) => v == null ? '' : String(v);
const outcomeBadge = (v: unknown) => badge(text(v), v === 'done' ? 'ok' : v === 'refused' ? 'warn' : 'crit');

// cronInWords: a pg_cron schedule in words beside its expression (minute hour day-of-month month day-of-week, the
// @ names, pg_cron's 'N seconds'); an expression it does not know is given back as it is.
export function cronInWords(expr: unknown): string {
  const e = text(expr).trim();
  const named: Record<string, string> = {
    '@yearly': 'at 00:00 on 1 January', '@annually': 'at 00:00 on 1 January', '@monthly': 'at 00:00 on day 1 of every month',
    '@weekly': 'at 00:00 every Sunday', '@daily': 'at 00:00 every day', '@midnight': 'at 00:00 every day', '@hourly': 'at minute 0 of every hour',
    '@reboot': 'when pg_cron starts',
  };
  if (named[e]) return named[e];
  const sec = /^(\d+) seconds?$/.exec(e);
  if (sec) return `every ${sec[1]} second${sec[1] === '1' ? '' : 's'}`;
  const f = e.split(/\s+/);
  if (f.length !== 5) return e;
  const [mi, ho, dom, mon, dow] = f;
  const days = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const months = ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const num = (s: string) => /^\d+$/.test(s);
  const pad = (s: string) => s.padStart(2, '0');
  const list = (s: string, names?: string[]) => s.split(',').map(p => {
    const r = /^(\d+)-(\d+)$/.exec(p);
    if (r) return names ? `${names[+r[1]] ?? r[1]} to ${names[+r[2]] ?? r[2]}` : `${r[1]} to ${r[2]}`;
    return names && num(p) ? (names[+p] ?? p) : p;
  }).join(', ');
  let when: string;
  const step = /^\*\/(\d+)$/.exec(mi);
  if (mi === '*' && ho === '*') when = 'every minute';
  else if (step && ho === '*') when = `every ${step[1]} minutes`;
  else if (num(mi) && num(ho)) when = `at ${pad(ho)}:${pad(mi)}`;
  else if (num(mi) && ho === '*') when = `at minute ${mi} of every hour`;
  else if (num(mi) && /^\*\/\d+$/.test(ho)) when = `at minute ${mi} of every ${ho.slice(2)} hours`;
  else if (num(mi) && /^[\d,-]+$/.test(ho)) when = `at minute ${mi} of hours ${list(ho)}`;
  else if (step && /^[\d,-]+$/.test(ho)) when = `every ${step[1]} minutes during hours ${list(ho)}`;
  else return e;
  const parts = [when];
  if (dom !== '*') parts.push(/^\*\/\d+$/.test(dom) ? `every ${dom.slice(2)} days of the month` : `on day ${list(dom)} of the month`);
  if (mon !== '*') parts.push(`in ${list(mon, months)}`);
  if (dow !== '*') parts.push(`on ${list(dow, days)}`);
  if (dom === '*' && mon === '*' && dow === '*' && !when.startsWith('every')) parts.push('every day');
  return parts.join(' ');
}

async function runningState(instance: number | undefined): Promise<RunningState> {
  return get<RunningState>('jobs/running', { instance });
}

function actButton(ctx: Ctx, st: RunningState, kind: Kind, why: string, r: Row, after: () => void): HTMLButtonElement {
  const b = el('button', { type: 'button', class: 'act-' + kind, style: 'font-size:12px;padding:0 .4rem;margin-right:.2rem' }, labels[kind]);
  const reason = why || (st.actions?.[kind]?.on ? '' : st.actions?.[kind]?.reason || 'job actions are off for this instance');
  if (reason) {
    // off: reachable by keyboard so its reason can be read (a disabled button takes no focus)
    b.setAttribute('aria-disabled', 'true');
    b.setAttribute('aria-label', `${labels[kind]}: off. ${reason}`);
    b.title = reason;
    b.style.opacity = '.55';
    b.style.cursor = 'not-allowed';
  } else {
    b.title = kind === 'job_stop' ? 'cancel the backend that runs this run (pg_cancel_backend)' : 'run the job now (jobnextrun = now())';
    b.addEventListener('click', () => { void confirmJobAction(ctx, kind, r, after); });
  }
  return b;
}

// pgJobActionCol is the PostgreSQL jobs grid's column: Run now on a pgAgent job (pg_cron has no run-now call).
export async function pgJobActionCol(ctx: Ctx, after: () => void): Promise<Col> {
  let st: RunningState;
  try { st = await runningState(ctx.instance); } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    st = { actions: { job_stop: { on: false, reason: why }, job_start: { on: false, reason: why } }, running: null, log: null };
  }
  return {
    key: '_actions', label: 'action',
    fmt: (_v, r) => {
      if (r.scheduler !== 'pgagent') return el('span', { class: 'meta', title: 'pg_cron runs a job at its schedule only: it has no run-now call' }, '-');
      const why = r.dropped_at != null ? 'the job is no longer on the server' : r.enabled === false ? 'the job is disabled: pgAgent runs no disabled job' : '';
      return el('span', { style: 'white-space:nowrap' }, actButton(ctx, st, 'job_start', why, { ...r, job_name: r.name }, after));
    },
  };
}

// confirmJobAction: the row as shown, the typed reason and the job's name typed to confirm; the server checks the
// target again before it sends anything.
async function confirmJobAction(ctx: Ctx, kind: Kind, r: Row, after: () => void) {
  const job = text(r.job_name ?? r.name);
  const what = kind === 'job_stop' ? `Stop the running job ${job}` : `Run the pgAgent job ${job} now`;
  const no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta', role: 'status' });
  const reason = el('textarea', { rows: '3', maxlength: '500', 'aria-label': 'reason', placeholder: 'Why (kept in the actions log)', style: 'width:100%' });
  const typed = el('input', { type: 'text', 'aria-label': "type the job's name to confirm", placeholder: job, autocomplete: 'off' });
  const go = el('button', { type: 'submit', disabled: '' }, `${labels[kind]} ${job}`);
  const check = () => { go.disabled = typed.value.trim() !== job || reason.value.trim().length < 5; };
  reason.addEventListener('input', check);
  typed.addEventListener('input', check);
  const shown = kind === 'job_stop'
    ? props([['job', job], ['scheduler', text(r.scheduler)], ['run', text(r.run_id)], ['started', fmtTime(r.start_time)],
      ['running for', fmtSecs(r.running_secs)], ['backend', r.scheduler === 'pg_cron' ? `pid ${text(r.job_pid)} (the run's job_pid)` : 'found by the server: the session running the current step\'s code'],
      ['current step', text(r.current_step) || '-'], ['database', text(r.datname)], ['run as', text(r.run_as)]])
    : props([['job', job], ['job id', text(r.job_id)], ['scheduler', 'pgAgent']]);
  const body = el('div', {},
    el('p', {}, kind === 'job_stop'
      ? (r.scheduler === 'pg_cron'
        ? 'Stop cancels the run\'s statement (pg_cancel_backend on the run\'s backend): the run ends failed with "canceling statement due to user request". The job runs again at its next schedule.'
        : 'Stop cancels the running step\'s statement (pg_cancel_backend): the step fails, and the job goes on or fails by the step\'s "on error".')
      : 'Run now sets the job\'s next run to now (UPDATE pgagent.pga_job SET jobnextrun = now()): pgAgent starts it at its next poll, from its first step.'),
    shown,
    el('label', {}, 'Reason', el('br'), reason), el('br'),
    el('label', {}, 'Type the job\'s name to confirm ', typed), el('br'), msg);
  const form = el('form', { method: 'dialog' }, el('h3', {}, what), body, el('div', { style: 'margin-top:.6rem' }, go, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:40rem', 'aria-label': what }, form);
  let sent = false;
  dlg.addEventListener('close', () => { dlg.remove(); if (sent) after(); });
  no.addEventListener('click', () => dlg.close());
  document.body.append(dlg);
  dlg.showModal();
  reason.focus();
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    go.disabled = true;
    msg.textContent = 'Sending...';
    try {
      const out = await post<{ outcome: string; detail: string; statement?: string }>(kind === 'job_stop' ? 'jobs/actions/stop' : 'jobs/actions/start', {
        instance_id: ctx.instance, scheduler: r.scheduler, job_id: Number(r.job_id), job_name: job, run_id: Number(r.run_id ?? 0),
        job_pid: Number(r.job_pid ?? 0), reason: reason.value, confirm: typed.value.trim(),
      });
      sent = true;
      msg.replaceChildren(badge(out.outcome, 'ok'), ' ', out.detail, out.statement ? el('span', {}, ' (', el('code', {}, out.statement), ')') : '');
      no.textContent = 'Close';
    } catch (e) {
      sent = true;
      msg.replaceChildren(badge('not done', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      no.textContent = 'Close';
    }
  });
}

const stepCols: Col[] = [
  { key: 'step_id', label: 'step', num: true }, { key: 'step_name', label: 'name' },
  { key: 'runs', num: true, fmt: fmtNum }, { key: 'succeeded', num: true, fmt: fmtNum },
  { key: 'failed', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'crit') : fmtNum(v) },
  { key: 'ignored', label: 'failed, ignored', num: true, fmt: fmtNum }, { key: 'aborted', num: true, fmt: fmtNum },
  { key: 'avg_secs', label: 'average', num: true, fmt: fmtSecs }, { key: 'max_secs', label: 'longest', num: true, fmt: fmtSecs },
  { key: 'last_status', label: 'last', fmt: v => v === 'failed' ? badge('failed', 'crit') : v === 'aborted' ? badge('aborted', 'warn') : text(v) },
  { key: 'last_start', label: 'last run', fmt: fmtTime },
];
const stepRunCols: Col[] = [
  { key: 'start_time', label: 'start', fmt: fmtTime }, { key: 'run_id', label: 'run', num: true },
  { key: 'step_id', label: 'step', num: true }, { key: 'step_name', label: 'name' },
  { key: 'status', fmt: v => v === 'failed' ? badge('failed', 'crit') : v === 'aborted' || v === 'ignored' ? badge(text(v), 'warn') : text(v) },
  { key: 'result', num: true }, { key: 'duration_secs', label: 'took', num: true, fmt: fmtSecs },
  { key: 'output', wide: true, fmt: v => text(v).replace(/\s+/g, ' ').slice(0, 300) },
];

// the pgAgent step log of one job, opened from its disclosure
async function stepLog(ctx: Ctx, jobId: string, box: HTMLElement) {
  box.replaceChildren(el('p', { class: 'meta' }, 'Reading the step log...'));
  try {
    const d = await get<Record<'steps' | 'step_runs', Table | null>>('jobs/steps', { instance: ctx.instance, ...window_(ctx), job: jobId });
    box.replaceChildren(
      el('h4', {}, `Steps (${rangeLabel(ctx)})`), grid(rowsOf(d.steps), stepCols, 'No step ran in this range (the step log is read by the collection job_steps).'),
      el('h4', {}, 'Step runs (the newest 1,000)'), grid(rowsOf(d.step_runs), stepRunCols, 'No step run in this range.'));
  } catch (e) {
    box.replaceChildren(errorBox(e));
  }
}

const exclCols = (writable: boolean, after: () => void): Col[] => [
  { key: 'level', fmt: v => v === 'root' ? 'every instance' : 'this instance' },
  { key: 'match_on', label: 'on' }, { key: 'pattern', fmt: v => el('code', {}, text(v)) },
  { key: 'jobs_taken', label: 'jobs it takes here', num: true, fmt: fmtNum }, { key: 'jobs', label: 'which', wide: true },
  { key: 'note', wide: true }, { key: 'created_by', label: 'by' }, { key: 'created_at', label: 'since', fmt: fmtTime },
  {
    key: 'exclusion_id', label: 'end', fmt: v => {
      const b = el('button', { type: 'button', style: 'font-size:12px;padding:0 .4rem' }, 'End');
      if (!writable) { b.setAttribute('aria-disabled', 'true'); b.title = 'exclusions cannot be written on this server'; return b; }
      b.setAttribute('aria-label', `End exclusion ${text(v)}`);
      b.addEventListener('click', async () => {
        b.textContent = '...';
        try { await post('jobs/exclusions', { op: 'end', exclusion_id: Number(v) }); after(); } catch (e) { b.replaceWith(errorBox(e)); }
      });
      return b;
    },
  },
];

// the form that adds an exclusion
function exclusionForm(ctx: Ctx, after: () => void): HTMLElement {
  const level = el('select', { 'aria-label': 'level' }, el('option', { value: 'instance' }, 'this instance'), el('option', { value: 'root' }, 'every instance'));
  const on = el('select', { 'aria-label': 'match on' }, el('option', { value: 'name' }, 'the job\'s name'), el('option', { value: 'command' }, 'the job\'s command'));
  const pat = el('input', { type: 'text', maxlength: '300', 'aria-label': 'pattern', placeholder: 'tmp_* or *VACUUM*', autocomplete: 'off' });
  const note = el('input', { type: 'text', maxlength: '500', 'aria-label': 'note', placeholder: 'why (optional)' });
  const add = el('button', { type: 'submit' }, 'Leave out of the checks');
  const msg = el('span', { class: 'meta', role: 'status' });
  const f = el('form', { class: 'excl-form' }, 'Leave jobs whose ', on, ' is like ', pat, ' on ', level, ' ', note, ' ', add, ' ', msg);
  f.addEventListener('submit', async ev => {
    ev.preventDefault();
    msg.textContent = 'Writing...';
    try {
      await post('jobs/exclusions', { op: 'add', level: level.value, instance_id: ctx.instance, match_on: on.value, pattern: pat.value, note: note.value });
      after();
    } catch (e) {
      msg.replaceChildren(badge('not added', 'warn'), ' ', e instanceof Error ? e.message : String(e));
    }
  });
  return f;
}

const logCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime }, { key: 'action', fmt: v => v === 'job_stop' ? 'Stop' : v === 'job_start' ? 'Run now' : text(v) },
  { key: 'outcome', fmt: outcomeBadge }, { key: 'job' }, { key: 'target_id', label: 'job id' }, { key: 'pid', num: true },
  { key: 'statement', wide: true }, { key: 'ui_user', label: 'by' }, { key: 'client', label: 'from' },
  { key: 'reason', wide: true }, { key: 'detail', wide: true },
];

// jobsRunningPanel: Running now, the pgAgent step log, the exclusions and the job actions' log.
export async function jobsRunningPanel(ctx: Ctx): Promise<HTMLElement> {
  const box = el('div', { class: 'jobs-running' });
  const redraw = () => { void jobsRunningPanel(ctx).then(n => box.replaceWith(n)); };
  try {
    const [st, ex, jobs] = await Promise.all([
      runningState(ctx.instance),
      get<{ writable: boolean; reason?: string; exclusions: Table | null }>('jobs/exclusions', { instance: ctx.instance }),
      get<Record<'jobs', Table | null>>('jobs/history', { instance: ctx.instance, ...window_(ctx), engine: 'pg', part: 'jobs' }),
    ]);
    const running = rowsOf(st.running);
    const cols: Col[] = [
      { key: 'job_name', label: 'job' }, { key: 'scheduler' }, { key: 'run_id', label: 'run', num: true },
      { key: 'start_time', label: 'started', fmt: fmtTime },
      { key: 'running_secs', label: 'running for', num: true, fmt: (v, r) => r.over_average === true ? badge(fmtSecs(v), 'warn') : fmtSecs(v) },
      { key: 'avg_secs', label: 'average', num: true, fmt: (v, r) => v == null ? 'no successful run in 30 days' : `${fmtSecs(v)} (${fmtNum(r.ok_runs)} runs)` },
      { key: 'estimated_end', label: 'estimated end', fmt: (v, r) => v == null ? '-' : r.over_average === true ? badge(`${fmtTime(v)} (passed)`, 'warn') : fmtTime(v) },
      { key: 'current_step', label: 'current step', fmt: (v, r) => v == null ? (r.scheduler === 'pgagent' ? '-' : 'no steps') : `${text(v)} (since ${fmtTime(r.current_step_start)})` },
      { key: 'job_pid', label: 'pid', num: true }, { key: 'datname', label: 'db' }, { key: 'run_as', label: 'run as' },
      { key: 'excluded_by', label: 'checks', fmt: v => v == null ? '' : badge('left out', '') },
      {
        key: '_stop', label: 'action', fmt: (_v, r) => {
          const why = r.scheduler === 'pg_cron' && (r.job_pid == null || Number(r.job_pid) <= 0) ? 'pg_cron has not recorded this run\'s backend (job_pid) yet' : '';
          return el('span', { style: 'white-space:nowrap' }, actButton(ctx, st, 'job_stop', why, r, redraw));
        },
      },
    ];
    const read = running.length ? ` (read ${fmtTime(running[0].read_at)})` : '';
    box.append(el('h3', {}, `Running now${read}`),
      grid(running, cols, 'No pg_cron or pgAgent run is running at the newest read.'),
      el('p', { class: 'meta' }, 'Estimated end = the start plus the job\'s average over its successful runs of 30 days; amber = running over twice that average (and 10 s more) with 3 runs or more behind it. ',
        st.actions?.job_stop?.on ? 'Stop is on for this instance.' : `Stop is off: ${st.actions?.job_stop?.reason ?? ''}`));
    // the pgAgent step log, one disclosure per pgAgent job
    const agentJobs = rowsOf(jobs.jobs).filter(j => j.scheduler === 'pgagent');
    if (agentJobs.length) {
      box.append(el('h3', {}, `pgAgent steps (${rangeLabel(ctx)})`));
      for (const j of agentJobs) {
        const inner = el('div', {});
        const d = el('details', {}, el('summary', {}, `${text(j.name)} (job ${text(j.job_id)})`), inner);
        d.addEventListener('toggle', () => { if (d.open && !inner.childElementCount) void stepLog(ctx, text(j.job_id), inner); });
        box.append(d);
      }
    }
    // the exclusions
    const ex_ = rowsOf(ex.exclusions);
    box.append(el('h3', {}, 'Left out of the job checks'),
      el('p', { class: 'meta' }, 'A job whose name or command is like a pattern (* any text, ? one character, any case) is left out of the job checks: its status, the Summary\'s Jobs cell, the overview\'s failed-job check and the job findings. The grids still list it and its runs.'),
      grid(ex_, exclCols(ex.writable, redraw), 'No exclusion: every pg_cron and pgAgent job is checked.'),
      ex.writable ? exclusionForm(ctx, redraw) : el('p', { class: 'meta' }, `Exclusions cannot be written here: ${ex.reason ?? ''}`));
    const log = rowsOf(st.log);
    if (log.length) box.append(el('h3', {}, 'Job actions (the audit, newest 200)'), grid(log, logCols));
  } catch (e) {
    box.append(errorBox(e));
  }
  return box;
}
