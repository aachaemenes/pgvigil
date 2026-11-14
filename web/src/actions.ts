// The actions door in the UI (task 39): Cancel and Terminate buttons on a Running queries session row, and
// the per-instance Actions log. A button sends pg_cancel_backend / pg_terminate_backend through the
// instance's actions login (actions_dsn) after a typed reason and a typed confirmation (the pid); the post
// carries the X-Pgvigil header (api.post). A button is disabled, with the reason as its title, when the
// instance has no actions_dsn, the server runs without the UI login, the row is a superuser's session or
// not a client backend, or the row has no backend_start. The server checks every one of these again and
// refuses a pid whose backend_start is not the row's (the pid reused). Data from /api/actions/log.
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, el, errorBox, fmtTime, grid } from './ui';
import { offBeside } from './ack';

// note: the page's one visible sentence where Cancel and Terminate are off for the WHOLE instance (every row's buttons
// share that reason and point at it: the page that builds the grid sets it); a row's own reason stands beside its buttons
export interface ActionsState { enabled: boolean; reason?: string; superusers: string[]; log: Table | null; note?: HTMLElement }

export async function actionsState(instance: number | undefined): Promise<ActionsState> {
  if (!instance) return { enabled: false, reason: 'no instance', superusers: [], log: null };
  try {
    return await get<ActionsState>('actions/log', { instance });
  } catch (e) {
    // a server built without the door, or the demo serve: the buttons stay disabled with the reason
    return { enabled: false, reason: e instanceof Error ? e.message : String(e), superusers: [], log: null };
  }
}

// whyDisabled: the reason a row's buttons are off, or '' when they are on.
export function whyDisabled(st: ActionsState, r: Row): string {
  if (!st.enabled) return st.reason || 'actions are off for this instance';
  if (r.backend_type != null && r.backend_type !== 'client backend') return `backend type ${String(r.backend_type)}: not a client session`;
  if (r.usename != null && st.superusers.includes(String(r.usename))) return `a superuser's session (${String(r.usename)}): out of the actions login's reach`;
  if (r.backend_start == null || r.backend_start === '') return 'this row has no backend_start: the session cannot be matched';
  return '';
}

// actionsCol is the Sessions grid's last column: Cancel and Terminate, or the pair off with the reason in words.
export function actionsCol(ctx: Ctx, st: ActionsState, after: () => void): Col {
  return {
    key: '_actions', label: 'action',
    fmt: (_v, r) => {
      const why = whyDisabled(st, r);
      // a row's own reason is said ONCE in its cell, after the pair, and both buttons point at it (the same words
      // beside each button stood twice in the cell and in its exported text)
      const own = why && st.enabled ? el('span', { class: 'off-reason' }, why) : undefined;
      const mk = (kind: 'cancel' | 'terminate', label: string) => {
        const b = el('button', { type: 'button', class: 'act-' + kind, style: 'font-size:12px;padding:0 .4rem;margin-right:.2rem' }, label);
        if (why) offBeside(b, why, st.enabled ? own : st.note);
        else {
          b.title = kind === 'cancel' ? 'pg_cancel_backend: stop the running statement, keep the session' : 'pg_terminate_backend: end the session (its open transaction rolls back)';
          b.addEventListener('click', () => confirmAction(ctx, kind, r, after));
        }
        return b;
      };
      return el('span', { style: 'white-space:nowrap' }, mk('cancel', 'Cancel'), mk('terminate', 'Terminate'), ...(own ? [' ', own] : []));
    },
  };
}

// confirmAction opens the typed confirmation: a reason (kept in the audit) and the pid typed again.
function confirmAction(ctx: Ctx, kind: 'cancel' | 'terminate', r: Row, after: () => void) {
  const pid = String(r.pid);
  const reason = el('textarea', { rows: '3', maxlength: '500', 'aria-label': 'reason', placeholder: 'Why (kept in the actions log)', style: 'width:100%' });
  const typed = el('input', { type: 'text', inputmode: 'numeric', 'aria-label': 'type the pid to confirm', placeholder: pid, autocomplete: 'off' });
  const go = el('button', { type: 'submit', disabled: '' }, kind === 'cancel' ? `Cancel pid ${pid}` : `Terminate pid ${pid}`);
  const no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta' });
  const check = () => { go.disabled = typed.value.trim() !== pid || reason.value.trim().length < 5; };
  reason.addEventListener('input', check);
  typed.addEventListener('input', check);
  const what = kind === 'cancel'
    ? 'pg_cancel_backend stops the statement this session runs; the session and its connection stay.'
    : 'pg_terminate_backend ends the session: its connection closes and its open transaction rolls back.';
  const form = el('form', { method: 'dialog' },
    el('h3', {}, `${kind === 'cancel' ? 'Cancel' : 'Terminate'} pid ${pid}`),
    el('p', {}, what),
    el('p', { class: 'meta' }, `${String(r.usename ?? '')} on ${String(r.datname ?? '')}, ${String(r.application_name ?? '')} from ${String(r.client ?? '')}; session started ${fmtTime(r.backend_start)}.`),
    el('label', {}, 'Reason', el('br'), reason), el('br'),
    el('label', {}, `Type the pid ${pid} to confirm `, typed), el('br'),
    msg, el('div', { style: 'margin-top:.6rem' }, go, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:34rem' }, form);
  const close = () => { dlg.close(); dlg.remove(); };
  no.addEventListener('click', close);
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    go.disabled = true;
    msg.textContent = 'Sending...';
    try {
      const out = await post<{ outcome: string; detail: string }>('actions/' + kind, {
        instance_id: ctx.instance, pid: Number(r.pid), backend_start: String(r.backend_start), reason: reason.value, confirm: typed.value.trim(),
      });
      msg.replaceChildren(badge(out.outcome, 'ok'), ' ', out.detail);
      no.textContent = 'Close';
      no.addEventListener('click', after, { once: true });
    } catch (e) {
      msg.replaceChildren(badge('not done', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      no.textContent = 'Close';
    }
  });
  document.body.append(dlg);
  dlg.showModal();
  reason.focus();
}

const outcomeBadge = (v: unknown) => badge(String(v ?? ''), v === 'done' ? 'ok' : v === 'refused' ? 'warn' : 'crit');

const logCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'action' },
  { key: 'outcome', fmt: outcomeBadge },
  { key: 'pid', num: true, fmt: v => String(v ?? '') },
  { key: 'target_user', label: 'session user' },
  { key: 'target_app', label: 'app' },
  { key: 'ui_user', label: 'by' },
  { key: 'client', label: 'from' },
  { key: 'reason', wide: true },
  { key: 'detail', wide: true },
  { key: 'backend_start', label: 'session started', fmt: fmtTime },
];

// actionsLogView is the per-instance Actions log tab.
export async function actionsLogView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Actions log'));
  let st: ActionsState;
  try {
    st = await get<ActionsState>('actions/log', { instance: ctx.instance });
  } catch (e) {
    sec.append(errorBox(e));
    return sec;
  }
  sec.append(el('p', { class: 'meta' }, st.enabled
    ? `Cancel and Terminate are on for this instance (Running queries, Sessions grid). Superuser roles, out of reach: ${st.superusers.join(', ') || 'none'}.`
    : `Cancel and Terminate are off for this instance: ${st.reason ?? ''}.`));
  sec.append(el('p', { class: 'meta' }, 'Every attempt is kept: done, refused (a check said no and nothing was sent) or failed (the signal could not be sent). The newest 500.'));
  sec.append(grid(rowsOf(st.log), logCols, 'No action has been attempted on this instance.'));
  return sec;
}
