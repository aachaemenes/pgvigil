// The Summary's Uptime dialog (task 176b): DBA Dash's Summary opens its Instance Uptime threshold dialog over the
// grid when the Uptime cell is clicked; this is that dialog for either engine. It shows the instance, its start time
// and uptime, the threshold in force and where it was set (the instance's own, a tag's, the root's or DBA Dash's
// default: warning under 48 hours, critical under 12), and sets the instance's own or ends it (inherit). One store for
// both engines: 162's thresholds, key 'uptime' (0113 lets a SQL Server instance hold it; the SQL Server summary reads
// pg_threshold(instance, 'uptime')). The write goes through POST /api/pg/thresholds with its doors (the header, a
// signed-in user, the actions configuration).
// summaryCellAction is the Summary cell's hook: Uptime opens the dialog in place, Database state on SQL Server opens
// the Checks page's Database options view (DBA Dash's DB Options).
import { get, Row, rowsOf, Table } from './api';
import { badge, el, fmtTime } from './ui';

const hoursText = (v: unknown) => v == null ? 'not judged' : `${Number(v).toLocaleString(undefined, { maximumFractionDigits: 2 })} hours`;
function ageText(from: unknown): string {
  if (from == null) return '';
  const s = Math.max(0, (Date.now() - new Date(String(from)).getTime()) / 1000);
  if (!isFinite(s)) return '';
  if (s < 3600) return `${Math.floor(s / 60)} min`;
  if (s < 2 * 86400) return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
  return `${Math.floor(s / 86400)} d ${Math.floor((s % 86400) / 3600)} h`;
}
const whereText = (r: Row) => r.level === 'default' ? 'the default' : r.level === 'tag' ? `set on the tag ${String(r.tag)}` : r.level === 'instance' ? 'set on this instance' : `set on the ${String(r.level)}`;

// a POST that shows a refusal as '<outcome>: <detail>' (the thresholds write answers 409 with {outcome, detail, error})
async function send(body: Record<string, unknown>): Promise<{ outcome: string; detail: string }> {
  const res = await fetch('/api/pg/thresholds', {
    method: 'POST', credentials: 'same-origin',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
    body: JSON.stringify(body),
  });
  let b: { outcome?: string; detail?: string; error?: string } = {};
  try { b = await res.json(); } catch { /* an empty or non-JSON body */ }
  if (!res.ok) throw new Error(b.outcome ? `${b.outcome}: ${b.detail ?? ''}` : b.error ?? `${res.status} ${res.statusText}`);
  return { outcome: String(b.outcome ?? 'done'), detail: String(b.detail ?? '') };
}

export async function openUptimeDialog(instanceId: number): Promise<void> {
  let r: Row | undefined;
  try { r = rowsOf((await get<Record<'uptime', Table | null>>('uptime', { instance: instanceId })).uptime)[0]; } catch { r = undefined; }
  const name = r ? String(r.instance) : `instance ${instanceId}`;
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const inp = (lab: string, v: unknown) => el('input', { type: 'number', min: '0', step: 'any', max: String(r?.max_value ?? ''), 'aria-label': lab, value: v == null ? '' : String(v), style: 'width:7rem' });
  const warn = inp('Warning: uptime under (hours)', r?.warn), crit = inp('Critical: uptime under (hours)', r?.crit);
  const save = el('button', { type: 'submit' }, 'Set'), inherit = el('button', { type: 'button' }, 'Inherit'), close = el('button', { type: 'button' }, 'Close');
  inherit.disabled = !r || r.own_id == null;
  if (!r) save.disabled = true;
  const started = r?.started_at;
  const form = el('form', { method: 'dialog', class: 'uptime-dialog' },
    el('h3', {}, `Instance Uptime: ${name}`),
    el('p', {}, started == null ? 'The start time is not read yet.' : `Started ${fmtTime(started)}, up ${ageText(started)}.`),
    el('p', { class: 'meta threshold-now' }, r
      ? `In force: warning under ${hoursText(r.warn)}, critical under ${hoursText(r.crit)} (${whereText(r)}). DBA Dash's default: warning under ${hoursText(r.warn_default)}, critical under ${hoursText(r.crit_default)}.`
      : 'The instance or its threshold could not be read.'),
    el('p', { class: 'meta' }, 'An uptime under the warning is a warning, under the critical a critical (a restart shows here). Set this instance\'s own, or Inherit to take the tag\'s, the root\'s or the default again.'),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Warning: uptime under (hours) ', warn)),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Critical: uptime under (hours) ', crit)),
    msg, el('div', { style: 'margin-top:.6rem' }, save, ' ', inherit, ' ', close));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': `Instance Uptime: ${name}`, 'data-instance': String(instanceId) }, form);
  let done = false;
  let ownNow = r != null && r.own_id != null;
  // closed by Close or Esc: the dialog's own close returns the focus to the cell, then it goes
  dlg.addEventListener('close', () => { dlg.remove(); if (done) window.dispatchEvent(new HashChangeEvent('hashchange')); });
  close.addEventListener('click', () => dlg.close());
  const go = async (op: 'set' | 'inherit') => {
    save.disabled = inherit.disabled = true;
    msg.textContent = 'Saving...';
    const body: Record<string, unknown> = { op, key: 'uptime', level: 'instance', instance_id: instanceId };
    if (op === 'set') { body.warn = warn.value === '' ? null : warn.value; body.crit = crit.value === '' ? null : crit.value; }
    try {
      const a = await send(body);
      done = true;
      msg.replaceChildren(badge(a.outcome, 'ok'), ' ', a.detail);
      ownNow = op === 'set';
      inherit.disabled = !ownNow;
    } catch (e) {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      inherit.disabled = !ownNow;
    }
    save.disabled = !r;
  };
  form.addEventListener('submit', ev => { ev.preventDefault(); void go('set'); });
  inherit.addEventListener('click', () => void go('inherit'));
  document.body.append(dlg);
  dlg.showModal();
  warn.focus();
}

// summaryCellAction: the Summary grid's cell link of a group, given what DBA Dash's Summary does on that cell. One
// call in pages.ts per cell link.
export function summaryCellAction(a: HTMLAnchorElement, key: string, r: Row): void {
  if (key === 'uptime') {
    a.addEventListener('click', e => {
      if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;   // a new tab keeps the link
      e.preventDefault();
      void openUptimeDialog(Number(r.instance_id));
    });
    a.setAttribute('aria-haspopup', 'dialog');
  }
  if (key === 'dbstate' && r.engine === 'sqlserver') a.setAttribute('href', String(a.getAttribute('href')) + '&cv=databases');
}
