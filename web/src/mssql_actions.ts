// The actions door of a SQL Server instance in the UI (task 75): Kill on a Running queries row, Start and Stop on a
// Jobs row, and the per-instance Actions log. A button first asks the server to read the target through the read
// login (the session with its login, host, program, open transaction count and last statement; the job with its
// name, owner and state) and shows it; the confirm step sends those values back with a typed reason and a typed
// confirmation, and the server sends KILL / sp_start_job / sp_stop_job through the instance's actions login only
// when the target is still the one shown. A button is disabled, with the reason as its title, when the instance has
// no actions_dsn or its actions: list does not name the action. Data from /api/mssql/actions/*.
//
// The Running queries tab imports mssqlKillCol, the Jobs tab mssqlJobCol: one function each.
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, el, errorBox, fmtTime, grid, props } from './ui';
import { offBeside } from './ack';

type Kind = 'kill' | 'job_start' | 'job_stop';
interface OnOff { enabled: boolean; reason?: string }
// notes: per action, the page's visible sentence where it is off for the WHOLE instance (every row's button of that
// kind shares the reason and points at it); a row's own reason ('a system session') stands beside its button
export interface MssqlActionsState { actions: Record<Kind, OnOff>; log: Table | null; notes?: Partial<Record<Kind, HTMLElement>> }
// an actions column and, where its action is off for the whole instance, the sentence that says why: the page that
// builds the grid places it above the grid (the column's off buttons point at it)
// rows: the page's rows, handed over before the grid draws: the sentence is then given to the page only where a row
// will show a button that points at it (no job, or only system sessions: no sentence standing alone)
export type ActionCol = Col & { readonly offNote?: HTMLElement; rows?(all: Row[]): void };

interface Target {
  session_id?: number; login_time?: string; login?: string; host?: string; program?: string; database?: string; status?: string;
  open_transaction_count?: number; statement?: string; job_id?: string; job_name?: string; job_owner?: string; job_state?: string;
}
interface Preview { ok: boolean; reason?: string; statement: string; target: Target }

const off = (why: string): MssqlActionsState => ({
  actions: { kill: { enabled: false, reason: why }, job_start: { enabled: false, reason: why }, job_stop: { enabled: false, reason: why } }, log: null,
});

export async function mssqlActionsState(instance: number | undefined): Promise<MssqlActionsState> {
  if (!instance) return off('no instance');
  try {
    return await get<MssqlActionsState>('mssql/actions/state', { instance });
  } catch (e) {
    // a server built without the door, or the demo serve: the buttons stay disabled with the reason
    return off(e instanceof Error ? e.message : String(e));
  }
}

const labels: Record<Kind, string> = { kill: 'Kill', job_start: 'Start', job_stop: 'Stop' };
const titles: Record<Kind, string> = {
  kill: 'KILL: end the session (its open transaction rolls back)',
  job_start: 'sp_start_job: start the job now',
  job_stop: 'sp_stop_job: stop the running job',
};

// own: the cell's one note for a reason that is the ROW's own (a row with two buttons says it once, after the pair)
function button(ctx: Ctx, st: MssqlActionsState, kind: Kind, why: string, r: Row, after: () => void, own?: HTMLElement): HTMLButtonElement {
  const b = el('button', { type: 'button', class: 'act-' + kind, style: 'font-size:12px;padding:0 .4rem;margin-right:.2rem' }, labels[kind]);
  const reason = why || (st.actions[kind]?.enabled ? '' : st.actions[kind]?.reason || 'actions are off for this instance');
  if (reason) {
    // off: the button stays reachable by keyboard and its reason is words on the page - the page's sentence for this
    // kind where the action is off for the whole instance (st.notes), in the cell where the reason is this row's own
    offBeside(b, reason, why ? own : st.notes?.[kind]);
    b.style.opacity = '.55';
    b.style.cursor = 'not-allowed';
  } else {
    b.title = titles[kind];
    b.addEventListener('click', () => { void confirmAction(ctx, kind, r, after); });
  }
  return b;
}

// mssqlKillCol is the Running queries grid's last column: Kill on a row with a session_id (a user session), disabled
// with the reason otherwise. It reads the instance's door itself; after runs once an action is done.
// offSentences: what the page says ONCE, above the grid, for the kinds given that are off for the whole instance - a
// reason every row shares never stands beside each row's button (Copy all and the exports carry a cell's text). One
// sentence where all of them are off for one shared reason ('Start and Stop are off for this instance: R'); else one
// per kind that is off ('Stop is off for this instance: R' - the instance's actions: list names one kind and not the
// other, or their reasons differ); a kind that is on gets none. It sets st.notes, which the buttons point at, and
// returns the element for the page to place (none when every kind is on).
function offSentences(st: MssqlActionsState, kinds: Kind[]): HTMLElement | undefined {
  const why = (k: Kind) => st.actions[k]?.enabled ? '' : st.actions[k]?.reason || 'actions are off for this instance';
  const offKinds = kinds.filter(k => why(k) !== '');
  if (!offKinds.length) return undefined;
  const notes: Partial<Record<Kind, HTMLElement>> = {};
  const said: HTMLElement[] = [];
  if (offKinds.length === kinds.length && new Set(kinds.map(why)).size === 1) {
    const p = el('p', { class: 'meta' }, `${kinds.map(k => labels[k]).join(' and ')} ${kinds.length > 1 ? 'are' : 'is'} off for this instance: ${why(kinds[0])}`);
    for (const k of kinds) notes[k] = p;
    said.push(p);
  } else {
    for (const k of offKinds) { const p = el('p', { class: 'meta' }, `${labels[k]} is off for this instance: ${why(k)}`); notes[k] = p; said.push(p); }
  }
  st.notes = { ...st.notes, ...notes };
  return said.length === 1 ? said[0] : el('div', {}, ...said);
}
export async function mssqlKillCol(ctx: Ctx, after: () => void): Promise<ActionCol> {
  const st = await mssqlActionsState(ctx.instance);
  const note = offSentences(st, ['kill']);
  // a row whose Kill points at the sentence: a user session (a system session or a row without an id says its own)
  let shown: boolean | undefined;
  return {
    key: '_actions', label: 'action',
    rows(all: Row[]) { shown = all.some(r => { const id = Number(r.session_id); return Number.isInteger(id) && id > 50; }); },
    get offNote() { return shown === false ? undefined : note; },
    fmt: (_v, r) => {
      const id = Number(r.session_id);
      const why = !Number.isInteger(id) || id <= 0 ? 'this row has no session id' : id <= 50 ? 'a system session' : '';
      return el('span', { style: 'white-space:nowrap' }, button(ctx, st, 'kill', why, r, after));
    },
  };
}

// mssqlJobCol is the Jobs grid's last column: Start and Stop on a row with a job_id.
export async function mssqlJobCol(ctx: Ctx, after: () => void): Promise<ActionCol> {
  const st = await mssqlActionsState(ctx.instance);
  const note = offSentences(st, ['job_start', 'job_stop']);
  // a row whose Start and Stop point at the sentence: a job with its id (a row without one says its own)
  let shown: boolean | undefined;
  return {
    key: '_actions', label: 'action',
    rows(all: Row[]) { shown = all.some(r => r.job_id != null && r.job_id !== ''); },
    get offNote() { return shown === false ? undefined : note; },
    fmt: (_v, r) => {
      const why = r.job_id == null || r.job_id === '' ? 'this row has no job id' : '';
      // the row's own reason once in the cell: both buttons point at it
      const own = why ? el('span', { class: 'off-reason' }, why) : undefined;
      return el('span', { style: 'white-space:nowrap' }, button(ctx, st, 'job_start', why, r, after, own), button(ctx, st, 'job_stop', why, r, after, own), ...(own ? [' ', own] : []));
    },
  };
}

// confirmAction: the server reads the target, the dialog shows it, and the typed reason and confirmation send it.
async function confirmAction(ctx: Ctx, kind: Kind, r: Row, after: () => void) {
  const what = kind === 'kill' ? `Kill session ${String(r.session_id)}` : `${labels[kind]} the job`;
  const body = el('div', {}, el('p', { class: 'meta', role: 'status' }, kind === 'kill' ? 'Reading the session...' : 'Reading the job...'));
  const no = el('button', { type: 'button' }, 'Back');
  const form = el('form', { method: 'dialog' }, el('h3', {}, what), body);
  const foot = el('div', { style: 'margin-top:.6rem' }, no);
  form.append(foot);
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:40rem', 'aria-label': what }, form);
  // every way out (the button, Escape) ends in the dialog's close event: it leaves the page, and once an action
  // was sent the caller redraws its grid
  let sent = false;
  dlg.addEventListener('close', () => { dlg.remove(); if (sent) after(); });
  no.addEventListener('click', () => dlg.close());
  document.body.append(dlg);
  dlg.showModal();

  let p: Preview;
  try {
    p = await post<Preview>('mssql/actions/preview', { instance_id: ctx.instance, action: kind, session_id: Number(r.session_id ?? 0), job_id: String(r.job_id ?? '') });
  } catch (e) {
    body.replaceChildren(errorBox(e));
    return;
  }
  const t = p.target ?? {};
  const shown = kind === 'kill'
    ? props([
      ['session', String(t.session_id ?? r.session_id ?? '')],
      ['login', t.login ?? ''], ['host', t.host ?? ''], ['program', t.program ?? ''], ['database', t.database ?? ''],
      ['status', t.status ?? ''],
      ['open transactions', String(t.open_transaction_count ?? 0)],
      ['logged in', fmtTime(t.login_time)],
      ['last statement', el('pre', { class: 'sql', style: 'white-space:pre-wrap;margin:0;max-height:12rem;overflow:auto' }, t.statement || '(none read)')],
    ])
    : props([['job', t.job_name ?? ''], ['owner', t.job_owner ?? ''], ['state now', t.job_state ?? ''], ['job id', t.job_id ?? String(r.job_id ?? '')]]);
  if (!p.ok) {
    body.replaceChildren(el('p', {}, badge('not possible', 'warn'), ' ', p.reason ?? ''), ...(t.session_id || t.job_id ? [shown] : []));
    return;
  }
  const want = kind === 'kill' ? String(t.session_id) : String(t.job_name ?? '');
  const reason = el('textarea', { rows: '3', maxlength: '500', 'aria-label': 'reason', placeholder: 'Why (kept in the actions log)', style: 'width:100%' });
  const typed = el('input', { type: 'text', 'aria-label': kind === 'kill' ? 'type the session id to confirm' : 'type the job name to confirm', placeholder: want, autocomplete: 'off' });
  const go = el('button', { type: 'submit', disabled: '' }, kind === 'kill' ? `Kill session ${want}` : `${labels[kind]} ${want}`);
  const msg = el('p', { class: 'meta', role: 'status' });
  const check = () => { go.disabled = typed.value.trim() !== want || reason.value.trim().length < 5; };
  reason.addEventListener('input', check);
  typed.addEventListener('input', check);
  body.replaceChildren(
    el('p', {}, kind === 'kill'
      ? 'KILL ends the session: its connection closes and its open transaction rolls back (a long transaction takes as long to roll back).'
      : kind === 'job_start' ? 'sp_start_job starts the job now, from its first step.' : 'sp_stop_job asks the Agent to stop the running job.'),
    shown,
    el('p', { class: 'meta' }, 'The statement: ', el('code', {}, p.statement)),
    el('label', {}, 'Reason', el('br'), reason), el('br'),
    el('label', {}, kind === 'kill' ? `Type the session id ${want} to confirm ` : `Type the job's name to confirm `, typed), el('br'),
    msg);
  foot.prepend(go, ' ');
  reason.focus();
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    go.disabled = true;
    msg.textContent = 'Sending...';
    try {
      const out = await post<{ outcome: string; detail: string; server_message?: string }>('mssql/actions/run', {
        instance_id: ctx.instance, action: kind, session_id: Number(t.session_id ?? 0), login_time: t.login_time ?? '', login: t.login ?? '',
        job_id: t.job_id ?? '', job_name: t.job_name ?? '', reason: reason.value, confirm: typed.value.trim(),
      });
      sent = true;
      msg.replaceChildren(badge(out.outcome, 'ok'), ' ', out.detail);
      no.textContent = 'Close';
    } catch (e) {
      sent = true;                       // refused or failed: the row may have changed too
      msg.replaceChildren(badge('not done', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      no.textContent = 'Close';
    }
  });
}

const outcomeBadge = (v: unknown) => badge(String(v ?? ''), v === 'done' ? 'ok' : v === 'refused' ? 'warn' : 'crit');

const logCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'action' },
  { key: 'outcome', fmt: outcomeBadge },
  { key: 'statement', wide: true },
  { key: 'engine', label: 'door', fmt: v => v === 'sqlserver' ? 'SQL Server' : 'PostgreSQL routes' },
  { key: 'session_id', label: 'session', num: true, fmt: v => String(v ?? '') },
  { key: 'target_user', label: 'login / owner' },
  { key: 'target_app', label: 'program' },
  { key: 'target_host', label: 'host' },
  { key: 'job_name', label: 'job' },
  { key: 'ui_user', label: 'by' },
  { key: 'client', label: 'from' },
  { key: 'reason', wide: true },
  { key: 'detail', wide: true },
  { key: 'server_message', label: 'server message', wide: true },
  { key: 'login_time', label: 'session logged in', fmt: fmtTime },
];

// mssqlActionsLogView is the Actions log tab of a SQL Server instance.
export async function mssqlActionsLogView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Actions log'));
  let st: MssqlActionsState;
  try {
    st = await get<MssqlActionsState>('mssql/actions/state', { instance: ctx.instance });
  } catch (e) {
    sec.append(errorBox(e));
    return sec;
  }
  const rows: Row[] = (['kill', 'job_start', 'job_stop'] as Kind[]).map(k => ({
    action: k, what: titles[k], state: st.actions[k]?.enabled ? 'on' : 'off', reason: st.actions[k]?.reason ?? '',
  }));
  sec.append(el('h3', {}, 'What is on for this instance'), grid(rows, [
    { key: 'action' }, { key: 'what' },
    { key: 'state', fmt: v => badge(String(v), v === 'on' ? 'ok' : '') },
    { key: 'reason', label: 'why off', wide: true },
  ]));
  sec.append(el('h3', {}, 'Attempts'),
    el('p', { class: 'meta' }, 'Every attempt is kept: done, refused (a check said no and nothing was sent) or failed (the server refused the statement; its message is beside it). The newest 500.'),
    grid(rowsOf(st.log), logCols, 'No action has been attempted on this instance.'));
  return sec;
}
