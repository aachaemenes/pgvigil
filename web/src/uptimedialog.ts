// The Summary's threshold dialogs (tasks 176b, P08), DBA Dash's two:
// - Uptime Threshold Config (Checks/UptimeThresholdConfig): from an Instance Uptime cell for that instance, or from the
//   Summary's Options > Instance Uptime > Configure Thresholds for the root. Inherit (the instance takes the tag's, the
//   root's or the default), Root Threshold Config, Enabled, Warning / Critical in minutes, the uptime and the start time,
//   Clear Alert (Clear ALL Alerts at the root) and Update. One store for both engines: 162's thresholds, key 'uptime'
//   (0113 lets a SQL Server instance hold it), kept in hours; the dialog shows minutes as DBA Dash's does.
// - Memory Dump Thresholds (Checks/MemoryDumpThresholdsConfig): from Options > Memory Dumps > Configure Thresholds,
//   the root's only: Critical and Warning Threshold (Hrs), each with its check box (unchecked = not judged), the time
//   dumps were last acknowledged with Clear and Acknowledge, Update and Cancel. Key 'crash' (0117): SQL Server's memory
//   dumps and PostgreSQL's crash restarts, DBA Dash's 48 / 168 hours by default.
// The writes go through POST /api/pg/thresholds with its doors (the header, a signed-in user, the actions
// configuration); Clear Alert and Acknowledge are pgvigil's acknowledgements (POST /api/ack), held until the start or
// the newest dump changes. summaryCellAction is the Summary cell's hook: Uptime opens its dialog in place.
import { get, Row, rowsOf, Table } from './api';
import { addAck, checkAcks, endAck, loadAckSafe, liveRows } from './ack';
import { humanize, sinceState } from './fleet';
import { badge, el, fmtTime } from './ui';

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

// the root's row of a key and its defaults (GET /api/mssql/summary's roots part)
async function rootOf(key: 'uptime' | 'crash'): Promise<Row | undefined> {
  try { return rowsOf((await get<Record<'roots', Table | null>>('mssql/summary', { part: 'roots' })).roots).find(r => r.key === key); } catch { return undefined; }
}

const num = (v: unknown): number | null => v == null || v === '' ? null : Number(v);
const minsOf = (hours: unknown): string => { const h = num(hours); return h == null ? '' : String(Math.round(h * 60 * 100) / 100); };

// the dialog's frame: a modal with DBA Dash's title, a close button, and a status line for the outcome; done() marks
// a change, and the Summary redraws when the dialog closes
function frame(title: string, instanceId: number) {
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const x = el('button', { type: 'button', class: 'link', 'aria-label': 'Close', style: 'float:right' }, '✕');
  const form = el('form', { method: 'dialog', class: 'threshold-dialog' }, x, el('h3', {}, title));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:38rem', 'aria-label': title, 'data-instance': String(instanceId) }, form);
  let changed = false;
  dlg.addEventListener('close', () => { dlg.remove(); if (changed) window.dispatchEvent(new HashChangeEvent('hashchange')); });
  x.addEventListener('click', () => dlg.close());
  const said = (ok: boolean, text: string) => msg.replaceChildren(badge(ok ? 'done' : 'not saved', ok ? 'ok' : 'crit'), ' ', text);
  return { form, dlg, msg, said, done: () => { changed = true; }, show: (focus: HTMLElement) => { form.append(msg); document.body.append(dlg); dlg.showModal(); focus.focus(); } };
}
const row = (...kids: (Node | string)[]) => el('div', { style: 'display:flex;gap:.8rem;align-items:center;margin:.45rem 0;flex-wrap:wrap' }, ...kids);
const check = (label: string, on: boolean) => { const c = el('input', { type: 'checkbox' }) as HTMLInputElement; c.checked = on; return { box: c, label: el('label', {}, c, ' ', label) }; };
const number = (label: string, v: string, max: unknown) => el('input', { type: 'number', min: '0', step: 'any', ...(max == null ? {} : { max: String(max) }), 'aria-label': label, value: v, style: 'width:7rem' }) as HTMLInputElement;

// openUptimeDialog: DBA Dash's 'Uptime Threshold Config <instance>' for an instance, or the root's (instanceId -1);
// clearAll is the Summary's Acknowledge Uptime (the root's Clear ALL Alerts)
export async function openUptimeDialog(instanceId: number, clearAll?: () => Promise<void>): Promise<void> {
  const root = instanceId < 0;
  let r: Row | undefined;
  if (root) r = await rootOf('uptime');
  else { try { r = rowsOf((await get<Record<'uptime', Table | null>>('uptime', { instance: instanceId })).uptime)[0]; } catch { r = undefined; } }
  const name = root ? '(root)' : r ? String(r.instance) : `instance ${instanceId}`;
  const f = frame(`Uptime Threshold Config ${name}`, instanceId);
  // in force: the instance's own, a tag's, the root's or the default; the root dialog shows the root's row or the default
  const own = root ? r?.threshold_id != null : r?.own_id != null;
  const warnNow = root ? (r?.threshold_id != null ? r.warn : r?.warn_default) : r?.warn;
  const critNow = root ? (r?.threshold_id != null ? r.crit : r?.crit_default) : r?.crit;
  const inherit = check('Inherit', !own);
  inherit.box.disabled = root;   // the root inherits from nothing (DBA Dash: Inherit is off at the root)
  const enabled = check('Enabled', warnNow != null && critNow != null);
  const warn = number('Warning (mins)', minsOf(warnNow ?? r?.warn_default), r?.max_value == null ? null : Number(r.max_value) * 60);
  const crit = number('Critical (mins)', minsOf(critNow ?? r?.crit_default), r?.max_value == null ? null : Number(r.max_value) * 60);
  const rootLink = el('a', { href: '#', role: 'button' }, 'Root Threshold Config');
  const panel = el('fieldset', { style: 'border:none;padding:0;margin:0' },
    row(enabled.label, el('label', {}, 'Warning: ', warn, ' mins'), el('label', {}, 'Critical: ', crit, ' mins')));
  const sync = () => { panel.disabled = inherit.box.checked; warn.disabled = crit.disabled = !enabled.box.checked; };
  inherit.box.addEventListener('change', sync); enabled.box.addEventListener('change', sync); sync();
  const started = root ? null : r?.started_at;
  // DBA Dash's 'Uptime: 1 hour, 20 minutes, 12 seconds' and '(Acknowledged)' after an acknowledgement newer than the start
  let acked = false;
  if (!root && started != null) {
    const a = checkAcks(await loadAckSafe(['acks'])).get(`${instanceId}|uptime`);
    acked = !!a && (!a.until_change || String(a.seen_state ?? '') === sinceState(started));
  }
  const uptime = started == null ? null : (Date.now() - Date.parse(String(started))) / 1000;
  const clear = el('button', { type: 'button' }, root ? 'Clear ALL Alerts' : 'Clear Alert');
  clear.disabled = root ? !clearAll : started == null || acked;
  const update = el('button', { type: 'submit' }, 'Update');
  if (!r) update.disabled = true;
  f.form.append(
    row(inherit.label, root ? '' : rootLink),
    panel,
    root ? el('p', { class: 'meta' }, 'The root threshold: every instance without its own or a tag\'s takes it.')
      : el('p', {}, `Uptime: ${uptime == null ? 'not read yet' : humanize(uptime, 3)}${acked ? ' (Acknowledged)' : ''}`),
    root ? '' : el('p', {}, `Start Time: ${started == null ? 'not read yet' : fmtTime(started)}`),
    el('p', { class: 'meta threshold-now' }, r
      ? `In force: ${warnNow == null ? 'no warning' : `warning under ${minsOf(warnNow)} mins`}, ${critNow == null ? 'no critical' : `critical under ${minsOf(critNow)} mins`}${root ? (r.threshold_id != null ? ' (set on the root)' : ' (the default)') : r.level === 'default' ? ' (the default)' : r.level === 'tag' ? ` (set on the tag ${String(r.tag)})` : ` (set on the ${String(r.level)})`}; the default: warning under ${minsOf(r.warn_default)} mins, critical under ${minsOf(r.crit_default)} mins.`
      : 'The instance or its threshold could not be read.'),
    row(clear, el('span', { style: 'flex:1' }), update));
  rootLink.addEventListener('click', e => { e.preventDefault(); f.dlg.close(); void openUptimeDialog(-1, clearAll); });
  clear.addEventListener('click', async () => {
    clear.disabled = true;
    try {
      if (root) { await clearAll?.(); f.said(true, 'Every Instance Uptime alert in the Summary is acknowledged until its next restart.'); }
      else {
        const res = await addAck({ kind: 'ack', instance_id: instanceId, check_key: 'uptime', seen_state: sinceState(started), until_change: true });
        f.said(true, `Alert cleared until the next restart (${res.outcome}).`);
      }
      f.done();
    } catch (e) { f.said(false, e instanceof Error ? e.message : String(e)); clear.disabled = false; }
  });
  f.form.addEventListener('submit', async ev => {
    ev.preventDefault();
    update.disabled = true;
    const body: Record<string, unknown> = root ? { op: 'set', key: 'uptime', level: 'root' }
      : inherit.box.checked ? { op: 'inherit', key: 'uptime', level: 'instance', instance_id: instanceId }
      : { op: 'set', key: 'uptime', level: 'instance', instance_id: instanceId };
    if (body.op === 'set') {
      const h = (v: string) => enabled.box.checked && v !== '' ? Number(v) / 60 : null;
      body.warn = h(warn.value); body.crit = h(crit.value);
    }
    try {
      if (body.op === 'inherit' && !own) f.said(true, 'Threshold updated: the instance already inherits.');
      else { const a = await send(body); f.said(true, `Threshold updated: ${a.outcome}${a.detail ? ' - ' + a.detail : ''}`); f.done(); }
    } catch (e) { f.said(false, e instanceof Error ? e.message : String(e)); }
    update.disabled = false;
  });
  f.show(root ? warn : inherit.box);
}

// openDumpDialog: DBA Dash's 'Memory Dump Thresholds' (the root's); acknowledge is the Summary's Acknowledge Dumps
export async function openDumpDialog(acknowledge?: () => Promise<void>): Promise<void> {
  const r = await rootOf('crash');
  const f = frame('Memory Dump Thresholds', -1);
  const set = r?.threshold_id != null;
  const critV = set ? r?.crit : r?.crit_default, warnV = set ? r?.warn : r?.warn_default;
  const critOn = check('', critV != null), warnOn = check('', warnV != null);
  const crit = number('Critical Threshold (Hrs)', critV == null ? '0' : String(critV), r?.max_value);
  const warn = number('Warning Threshold (Hrs)', warnV == null ? '0' : String(warnV), r?.max_value);
  critOn.box.setAttribute('aria-label', 'Critical Threshold (Hrs): judged'); warnOn.box.setAttribute('aria-label', 'Warning Threshold (Hrs): judged');
  const sync = () => { crit.disabled = !critOn.box.checked; warn.disabled = !warnOn.box.checked; };
  critOn.box.addEventListener('change', sync); warnOn.box.addEventListener('change', sync); sync();
  // DBA Dash's {AckDate}: the newest acknowledgement of a Memory Dump cell still in force; Clear ends them all
  const ackRows = liveRows(await loadAckSafe(['acks']), 'ack').filter(a => a.check_key === 'dumps');
  const ackAt = ackRows.reduce<string | null>((a, x) => x.created_at != null && (a == null || String(x.created_at) > a) ? String(x.created_at) : a, null);
  const clearLink = el('button', { type: 'button', class: 'link' }, 'Clear');
  clearLink.disabled = ackRows.length === 0;
  const ackLink = el('button', { type: 'button', class: 'link' }, 'Acknowledge');
  ackLink.disabled = !acknowledge;
  const update = el('button', { type: 'submit' }, 'Update'), cancel = el('button', { type: 'button' }, 'Cancel');
  if (!r) update.disabled = true;
  f.form.append(
    row(critOn.label, el('label', {}, 'Critical Threshold (Hrs): ', crit)),
    row(warnOn.label, el('label', {}, 'Warning Threshold (Hrs): ', warn)),
    row(el('span', {}, ackAt == null ? 'Not acknowledged' : `Acknowledged ${fmtTime(ackAt)}`), clearLink, ackLink),
    el('p', { class: 'meta threshold-now' }, r
      ? `${set ? 'Set on the root' : 'The default'}: critical when the newest memory dump (SQL Server) or crash restart (PostgreSQL) is under ${critV ?? '-'} hours old, warning under ${warnV ?? '-'}; the default ${r.crit_default} / ${r.warn_default} hours.`
      : 'The threshold could not be read.'),
    row(el('span', { style: 'flex:1' }), update, cancel));
  cancel.addEventListener('click', () => f.dlg.close());
  ackLink.addEventListener('click', async () => {
    ackLink.disabled = true;
    try { await acknowledge?.(); f.said(true, 'Memory dumps acknowledged until a newer dump.'); f.done(); } catch (e) { f.said(false, e instanceof Error ? e.message : String(e)); }
  });
  clearLink.addEventListener('click', async () => {
    clearLink.disabled = true;
    const failed: string[] = [];
    for (const a of ackRows) { try { await endAck(Number(a.ack_id)); } catch (e) { failed.push(e instanceof Error ? e.message : String(e)); } }
    f.said(!failed.length, failed.length ? failed.join('; ') : `${ackRows.length} acknowledgement(s) ended: the dumps show again.`);
    f.done();
  });
  f.form.addEventListener('submit', async ev => {
    ev.preventDefault();
    update.disabled = true;
    try {
      const a = await send({ op: 'set', key: 'crash', level: 'root', crit: critOn.box.checked && crit.value !== '' ? Number(crit.value) : null, warn: warnOn.box.checked && warn.value !== '' ? Number(warn.value) : null });
      f.said(true, `Thresholds updated: ${a.outcome}${a.detail ? ' - ' + a.detail : ''}`); f.done();
    } catch (e) { f.said(false, e instanceof Error ? e.message : String(e)); }
    update.disabled = false;
  });
  f.show(critOn.box);
}

// summaryCellAction: the Summary grid's cell link of a group, given what DBA Dash's Summary does on that cell
// (Checks/Summary.cs DgvSummary_CellContentClick): Instance Uptime opens its dialog over the grid; every other cell
// keeps its link to the column's tab. One call in pages.ts per cell link.
export function summaryCellAction(a: HTMLAnchorElement, key: string, r: Row): void {
  if (key === 'uptime') {
    a.addEventListener('click', e => {
      if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;   // a new tab keeps the link
      e.preventDefault();
      void openUptimeDialog(Number(r.instance_id));
    });
    a.setAttribute('aria-haspopup', 'dialog');
  }
}
