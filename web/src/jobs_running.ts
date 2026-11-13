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
import { offBeside } from './ack';

type Kind = 'job_stop' | 'job_start';
interface OnOff { on: boolean; reason?: string }
// notes: per action, the page's one visible sentence where it is off for the WHOLE instance (every row's button shares
// that reason and points at it); a row's own reason stands beside its button
interface RunningState { actions: Record<Kind, OnOff>; running: Table | null; log: Table | null; notes?: Partial<Record<Kind, HTMLElement>> }
// an actions column and, where its action is off for the whole instance and a row shows it, the sentence that says why:
// the page places it by the grid. stopNote: that same sentence where it also speaks for Stop (both off for one reason:
// the page says it once, and the Running now panel is given it instead of saying it again). rows: the page's rows,
// handed over by the panel before it draws - whether a row shows the button is decided from them, never from the
// part of a long grid drawn so far.
type ActionCol = Col & { readonly offNote?: HTMLElement; readonly stopNote?: HTMLElement; rows?(all: Row[]): void };
const offWhy = (st: RunningState, kind: Kind): string => st.actions?.[kind]?.on ? '' : st.actions?.[kind]?.reason || 'job actions are off for this instance';

const labels: Record<Kind, string> = { job_stop: 'Stop', job_start: 'Run now' };
const text = (v: unknown) => v == null ? '' : String(v);
const outcomeBadge = (v: unknown) => badge(text(v), v === 'done' ? 'ok' : v === 'refused' ? 'warn' : 'crit');

// cronInWords: a pg_cron schedule in words beside its expression (minute hour day-of-month month day-of-week, the
// @ names, pg_cron's 'N seconds', '$' = the last day of the month); an expression it does not know is given back as it
// is, never guessed. A step reads 'every N' only when it divides its field (*/45 runs at :00 and :45: not every 45
// minutes); a day of the month and a day of the week both set read as either (cron runs the job on both).
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
  const even = (s: string, range: number) => { const m = /^\*\/(\d+)$/.exec(s); return m && +m[1] > 0 && range % +m[1] === 0 ? m[1] : null; };
  const listed = /^[\d,-]+$/;
  const mstep = even(mi, 60), hstep = even(ho, 24);
  if (/^\*\/\d+$/.test(mi) && !mstep) return e;
  if (/^\*\/\d+$/.test(ho) && !hstep) return e;
  if (mi === '*' && ho === '*') when = 'every minute';
  else if (mstep && ho === '*') when = `every ${mstep} minutes`;
  else if (num(mi) && num(ho)) when = `at ${pad(ho)}:${pad(mi)}`;
  else if (num(mi) && ho === '*') when = `at minute ${mi} of every hour`;
  else if (num(mi) && hstep) when = `at minute ${mi} of every ${hstep} hours`;
  else if (num(mi) && listed.test(ho)) when = `at minute ${mi} of hours ${list(ho)}`;
  else if (mstep && listed.test(ho)) when = `every ${mstep} minutes during hours ${list(ho)}`;
  else return e;
  if (![dom, mon, dow].every(f => f === '*' || f === '$' || listed.test(f) || /^\*\/\d+$/.test(f))) return e;
  const domWords = dom === '$' ? 'on the last day of the month' : /^\*\/\d+$/.test(dom) ? `every ${dom.slice(2)} days of the month` : `on day ${list(dom)} of the month`;
  const dowWords = /^\*\/\d+$/.test(dow) ? null : `on ${list(dow, days)}`;
  if (dow !== '*' && !dowWords) return e;
  const parts = [when];
  if (dom !== '*' && dow !== '*' && !dom.startsWith('*') && !dow.startsWith('*')) parts.push(`${domWords}, or ${dowWords}`);   // cron's OR
  else {
    if (dom !== '*') parts.push(domWords);
    if (dow !== '*') parts.push(dowWords!);
  }
  if (mon !== '*') parts.splice(1, 0, `in ${list(mon, months)}`);
  if (dom === '*' && mon === '*' && dow === '*' && !when.startsWith('every')) parts.push('every day');
  return parts.join(' ');
}

export async function runningState(instance: number | undefined): Promise<RunningState> {
  return get<RunningState>('jobs/running', { instance });
}

function actButton(ctx: Ctx, st: RunningState, kind: Kind, why: string, r: Row, after: () => void): HTMLButtonElement {
  const b = el('button', { type: 'button', class: 'act-' + kind, style: 'font-size:12px;padding:0 .4rem;margin-right:.2rem' }, labels[kind]);
  const reason = why || offWhy(st, kind);
  if (reason) {
    // off: reachable by keyboard, its reason words on the page - the page's one sentence where the action is off for
    // the whole instance, beside the button where the reason is this row's own
    offBeside(b, reason, why ? undefined : st.notes?.[kind]);
    b.style.opacity = '.55';
    b.style.cursor = 'not-allowed';
  } else {
    b.title = kind === 'job_stop' ? 'cancel the backend that runs this run (pg_cancel_backend)' : 'run the job now (jobnextrun = now())';
    b.addEventListener('click', () => { void confirmJobAction(ctx, kind, r, after); });
  }
  return b;
}

// pgJobActionCol is the PostgreSQL jobs grid's column: Run now on a pgAgent job (pg_cron has no run-now call).
export async function pgJobActionCol(ctx: Ctx, after: () => void): Promise<ActionCol> {
  let st: RunningState;
  try { st = await runningState(ctx.instance); } catch (e) {
    const why = e instanceof Error ? e.message : String(e);
    st = { actions: { job_stop: { on: false, reason: why }, job_start: { on: false, reason: why } }, running: null, log: null };
  }
  // Run now off for the whole instance: its one sentence, handed to the page only where a pgAgent row shows the button
  // (a pg_cron job has no run-now call: its cell reads '-'). Where Stop is off for the same reason the sentence names
  // both, so the page says that reason once (stopNote)
  const startWhy = offWhy(st, 'job_start'), both = startWhy !== '' && startWhy === offWhy(st, 'job_stop');
  const note = startWhy ? el('p', { class: 'meta' }, `${both ? 'Run now and Stop are' : 'Run now is'} off for this instance: ${startWhy}`) : undefined;
  // what the sentence says, for the Running now panel's own read to compare (a page reads the state twice)
  if (note) { note.dataset.why = startWhy; note.dataset.stop = both ? '1' : '0'; }
  st.notes = { ...st.notes, job_start: note };
  // a row's own reason for an off Run now, '' when the row has none
  const rowWhy = (r: Row): string => r.dropped_at != null ? 'the job is no longer on the server' : r.enabled === false ? 'the job is disabled: pgAgent runs no disabled job' : '';
  let shown = false;
  return {
    key: '_actions', label: 'action',
    rows(all: Row[]) { shown = all.some(r => r.scheduler === 'pgagent' && rowWhy(r) === ''); },
    get offNote() { return shown ? note : undefined; },
    get stopNote() { return shown && both ? note : undefined; },
    fmt: (_v, r) => {
      if (r.scheduler !== 'pgagent') return el('span', { class: 'meta', title: 'pg_cron runs a job at its schedule only: it has no run-now call' }, '-');
      const why = rowWhy(r);
      if (!why) shown = true;   // a caller that hands over no rows: the first such row drawn
      return el('span', { style: 'white-space:nowrap' }, actButton(ctx, st, 'job_start', why, { ...r, job_name: r.name }, after));
    },
  };
}

// confirmJobAction: the row as shown, the typed reason and the job's name typed to confirm; the server checks the
// target again before it sends anything.
export async function confirmJobAction(ctx: Ctx, kind: Kind, r: Row, after: () => void) {
  const job = text(r.job_name ?? r.name).trim();
  const what = kind === 'job_stop' ? `Stop the running job ${job}` : `Run the pgAgent job ${job} now`;
  const no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta', role: 'status' });
  const reason = el('textarea', { rows: '3', maxlength: '500', 'aria-label': 'reason', placeholder: 'Why (kept in the actions log)', style: 'width:100%' });
  const typed = el('input', { type: 'text', 'aria-label': "type the job's name to confirm", placeholder: job, autocomplete: 'off' });
  const go = el('button', { type: 'submit', disabled: '' }, `${labels[kind]} ${job}`);
  let busy = false;   // one action per dialog: a keystroke after the send never arms the button again
  const check = () => { go.disabled = busy || typed.value.trim() !== job || reason.value.trim().length < 5; };
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
    if (busy) return;
    busy = true; sent = true;          // sent from here: a dialog closed while the request runs still redraws the grid
    go.disabled = true; reason.readOnly = true; typed.readOnly = true;
    msg.textContent = 'Sending...';
    try {
      const out = await post<{ outcome: string; detail: string; statement?: string }>(kind === 'job_stop' ? 'jobs/actions/stop' : 'jobs/actions/start', {
        instance_id: ctx.instance, scheduler: r.scheduler, job_id: Number(r.job_id), job_name: text(r.job_name ?? r.name), run_id: Number(r.run_id ?? 0),
        job_pid: Number(r.job_pid ?? 0), reason: reason.value, confirm: typed.value.trim(),
      });
      msg.replaceChildren(badge(out.outcome, 'ok'), ' ', out.detail, out.statement ? el('span', {}, ' (', el('code', {}, out.statement), ')') : '');
    } catch (e) {
      const m = e instanceof Error ? e.message : String(e);
      // a 500 that starts 'done:' was sent and only its audit row failed
      msg.replaceChildren(m.startsWith('done:') ? badge('done, not audited', 'warn') : badge('not done', 'crit'), ' ', m);
    }
    no.textContent = 'Close';
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
    box.dataset.read = 'ok';
    box.replaceChildren(
      el('h4', {}, `Steps (${rangeLabel(ctx)})`), grid(rowsOf(d.steps), stepCols, 'No step ran in this range (the step log is read by the collection job_steps).'),
      el('h4', {}, 'Step runs (the newest 1,000)'), grid(rowsOf(d.step_runs), stepRunCols, 'No step run in this range.'));
  } catch (e) {
    box.replaceChildren(errorBox(e));
  }
}

// offNote: the page's sentence that says why exclusions cannot be written here; an off End points at it
const exclCols = (writable: boolean, after: () => void, offNote?: HTMLElement): Col[] => [
  { key: 'level', fmt: v => v === 'root' ? 'every instance' : 'this instance' },
  { key: 'match_on', label: 'on' }, { key: 'pattern', fmt: v => el('code', {}, text(v)) },
  { key: 'jobs_taken', label: 'jobs it takes here', num: true, fmt: fmtNum }, { key: 'jobs', label: 'which', wide: true },
  { key: 'note', wide: true }, { key: 'created_by', label: 'by' }, { key: 'created_at', label: 'since', fmt: fmtTime },
  {
    key: 'exclusion_id', label: 'end', fmt: v => {
      const b = el('button', { type: 'button', style: 'font-size:12px;padding:0 .4rem' }, 'End');
      if (!writable) { offBeside(b, 'exclusions cannot be written on this server', offNote); return b; }
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

// jobsRunningPanel: Running now, the pgAgent step log, the exclusions and the job actions' log. stopNote: the page's
// sentence above that already says why Stop is off (with Run now, for one shared reason): an off Stop points at it and
// the panel does not say the reason a second time.
export async function jobsRunningPanel(ctx: Ctx, stopNote?: HTMLElement): Promise<HTMLElement> {
  const box = el('div', { class: 'jobs-running' });
  const redraw = () => { void jobsRunningPanel(ctx, stopNote).then(n => box.replaceWith(n)); };
  try {
    // each part on its own: a failed exclusions or jobs read never hides Running now and its Stop buttons
    const [st, exR, jobsR] = await Promise.all([
      runningState(ctx.instance),
      get<{ writable: boolean; reason?: string; exclusions: Table | null }>('jobs/exclusions', { instance: ctx.instance }).then(v => ({ v }), (e: unknown) => ({ e })),
      get<Record<'jobs', Table | null>>('jobs/history', { instance: ctx.instance, ...window_(ctx), engine: 'pg', part: 'jobs' }).then(v => ({ v }), (e: unknown) => ({ e })),
    ]);
    const running = rowsOf(st.running);
    const cols: Col[] = [
      { key: 'job_name', label: 'job' }, { key: 'scheduler' }, { key: 'run_id', label: 'run', num: true },
      { key: 'start_time', label: 'started', fmt: fmtTime },
      { key: 'running_secs', label: 'running for', num: true, fmt: (v, r) => r.over_average === true ? badge(fmtSecs(v), 'warn') : fmtSecs(v) },
      { key: 'avg_secs', label: 'average', num: true, fmt: (v, r) => v == null ? 'no successful run in 30 days' : `${fmtSecs(v)} (${fmtNum(r.ok_runs)} runs)` },
      {
        key: 'estimated_end', label: 'estimated end', fmt: (v, r) => {
          if (v == null) return '-';
          const shown = Date.parse(String(v)) < Date.now() ? `${fmtTime(v)} (passed)` : fmtTime(v);
          return r.over_average === true ? badge(shown, 'warn') : shown;
        },
      },
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
    // Stop on or off for the whole instance, said once: under the grid - or, where the page above says it in one
    // sentence with Run now (stopNote: the page that gives it has placed it), by that sentence alone. An off Stop of a
    // row points at the words
    const stopWhy = offWhy(st, 'job_stop');
    // the sentence above speaks for Stop only while this panel's own read gives the same reason; where it does not (a
    // read failed on one side), the sentence above is cut back to Run now and this panel says Stop's state itself
    const same = !!stopNote && stopWhy !== '' && stopNote.dataset.stop === '1' && stopNote.dataset.why === stopWhy;
    if (stopNote && !same && stopNote.dataset.stop === '1') { stopNote.textContent = `Run now is off for this instance: ${stopNote.dataset.why ?? ''}`; stopNote.dataset.stop = '0'; }
    const above = same ? stopNote : undefined;
    const stopSaid = above ? null : el('span', {}, stopWhy ? `Stop is off: ${stopWhy}` : 'Stop is on for this instance.');
    if (stopWhy) st.notes = { ...st.notes, job_stop: above ?? stopSaid! };
    box.append(el('h3', {}, `Running now${read}`),
      grid(running, cols, 'No pg_cron or pgAgent run is running at the newest read.'),
      el('p', { class: 'meta' }, 'Estimated end = the start plus the job\'s average over its successful runs of 30 days; amber = running over twice that average (and 10 s more) with 3 runs or more behind it. ', ...(stopSaid ? [stopSaid] : [])));
    // the pgAgent step log, one disclosure per pgAgent job
    if ('e' in jobsR) box.append(el('h3', {}, 'pgAgent steps'), errorBox(jobsR.e));
    const agentJobs = 'v' in jobsR ? rowsOf(jobsR.v.jobs).filter(j => j.scheduler === 'pgagent') : [];
    if (agentJobs.length) {
      box.append(el('h3', {}, `pgAgent steps (${rangeLabel(ctx)})`));
      for (const j of agentJobs) {
        const inner = el('div', {});
        const d = el('details', {}, el('summary', {}, `${text(j.name)} (job ${text(j.job_id)})`), inner);
        d.addEventListener('toggle', () => { if (d.open && inner.dataset.read !== 'ok') void stepLog(ctx, text(j.job_id), inner); });
        box.append(d);
      }
    }
    // the exclusions
    box.append(el('h3', {}, 'Left out of the job checks'));
    if ('e' in exR) {
      box.append(errorBox(exR.e));
    } else {
    const ex = exR.v;
    const ex_ = rowsOf(ex.exclusions);
    // exclusions cannot be written here: the page's one sentence, placed under the grid; an off End points at it
    const exclOff = ex.writable ? undefined : el('p', { class: 'meta' }, `Exclusions cannot be written here: ${ex.reason || 'exclusions are off on this server'}`);
    box.append(
      el('p', { class: 'meta' }, 'A job whose name or command is like a pattern (* any text, ? one character, any case) is left out of the job checks: its status, the Summary\'s Jobs cell, the overview\'s failed-job check and the job findings. The grids still list it and its runs.'),
      grid(ex_, exclCols(ex.writable, redraw, exclOff), 'No exclusion: every pg_cron and pgAgent job is checked.'),
      ex.writable ? exclusionForm(ctx, redraw) : exclOff!);
    }
    const log = rowsOf(st.log);
    if (log.length) box.append(el('h3', {}, 'Job actions (the audit, newest 200)'), grid(log, logCols));
  } catch (e) {
    box.append(errorBox(e));
  }
  return box;
}
