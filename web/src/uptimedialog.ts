// The Summary's threshold dialogs (tasks 176b, P08), DBA Dash's two:
// - Uptime Threshold Config (Checks/UptimeThresholdConfig): from an Instance Uptime cell for that instance, or from the
//   Summary's Options > Instance Uptime > Configure Thresholds for the root. Inherit (the instance takes the tag's, the
//   root's or the default), Root Threshold Config, Enabled, Warning / Critical in minutes, the uptime and the start time,
//   Clear Alert (Clear ALL Alerts at the root) and Update. One store for both engines: 162's thresholds, key 'uptime'
//   (0113 lets a SQL Server instance hold it), kept in hours; the dialog shows minutes as DBA Dash's does.
// - Memory Dump Thresholds (Checks/MemoryDumpThresholdsConfig): from Options > Memory Dumps > Configure Thresholds,
//   the root's only: Warning and Critical Threshold (Hrs), each with its check box (unchecked = not judged), Acknowledge,
//   the time dumps were last acknowledged and Clear, Cancel and Update (DBA Dash's order). Key 'crash' (0117): SQL Server's memory
//   dumps and PostgreSQL's crash restarts, DBA Dash's 48 / 168 hours by default.
// The writes go through POST /api/pg/thresholds with its doors (the header, a signed-in user, the actions
// configuration); Clear Alert and Acknowledge are pgvigil's acknowledgements (POST /api/ack), held until the start or
// the newest dump changes. summaryCellAction is the Summary cell's hook: Uptime opens its dialog in place.
import { get, Row, rowsOf, Table } from './api';
import { ackOn, ackWhy, addAck, checkAcks, endAck, loadAckSafe, liveRows, offBeside, onDoor, seatWhy } from './ack';
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
// whole minutes, as DBA Dash's boxes take them: the store keeps hours to two decimals (q_pg_backups.go sends '%.2f'), so
// 10 minutes is kept as 0.17 h; rounding to the minute gives back what was typed
const minsOf = (hours: unknown): string => { const h = num(hours); return h == null ? '' : String(Math.round(h * 60)); };
// what the Summary's Acknowledge Uptime / Dumps did (the dialog shows it)
type Acked = () => Promise<{ done: number; text: string }>;

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
// DBA Dash's forms place their fields on a grid: a column per label, box and check box (cells in reading order)
const table = (cols: number, ...cells: (Node | string)[]) => el('div', { style: `display:grid;grid-template-columns:repeat(${cols},max-content);column-gap:1.4rem;row-gap:.35rem;align-items:center;justify-items:start;margin:.45rem 0` }, ...cells);
const check = (label: string, on: boolean) => { const c = el('input', { type: 'checkbox' }) as HTMLInputElement; c.checked = on; return { box: c, label: el('label', {}, c, ' ', label) }; };
let seq = 0;   // the inputs' ids, unique on the page: a label never names a box in another dialog
const number = (label: string, v: string, max: unknown) => el('input', { type: 'number', id: `thr-${++seq}`, min: '0', step: 'any', ...(max == null ? {} : { max: String(max) }), 'aria-label': label, value: v, style: 'width:7rem' }) as HTMLInputElement;
const labelOf = (text: string, input: HTMLInputElement) => el('label', { for: input.id }, text);

// openUptimeDialog: DBA Dash's 'Uptime Threshold Config <instance>' for an instance, or the root's (instanceId -1);
// clearAll is the Summary's Acknowledge Uptime (the root's Clear ALL Alerts)
export async function openUptimeDialog(instanceId: number, clearAll?: Acked): Promise<void> {
  const root = instanceId < 0;
  let r: Row | undefined;
  if (root) r = await rootOf('uptime');
  else { try { r = rowsOf((await get<Record<'uptime', Table | null>>('uptime', { instance: instanceId })).uptime)[0]; } catch { r = undefined; } }
  const name = root ? '(root)' : r ? String(r.instance) : `instance ${instanceId}`;
  const f = frame(`Uptime Threshold Config ${name}`, instanceId);
  // who may write here (the acknowledgement seat: the threshold writes ask the same one). The root's threshold is
  // wider than one instance: off where the server writes nothing and on a demo serve, whose door carries one instance's
  // own; an instance that is not the demo's is off there too. Off = the reason in words in the dialog.
  const ad = await loadAckSafe(['acks']);
  const updWhy = seatWhy(ad, 'thresholds', root ? undefined : instanceId, name);
  const clrWhy = root ? null : ackWhy(ad, instanceId, name);
  // one sentence where both buttons are off for one reason (an instance that is not the demo's), named for both
  const updNote = updWhy ? el('p', { class: 'meta' }, `${updWhy === clrWhy ? 'Update and Clear Alert are' : 'Update is'} off: ${updWhy}`) : null;
  // in force: the instance's own, a tag's, the root's or the default; the root dialog shows the root's row or the default
  const own = root ? r?.threshold_id != null : r?.own_id != null;
  const warnNow = root ? (r?.threshold_id != null ? r.warn : r?.warn_default) : r?.warn;
  const critNow = root ? (r?.threshold_id != null ? r.crit : r?.crit_default) : r?.crit;
  const inherit = check('Inherit', !root && !own);   // the root: off (with no root row too) and disabled, its boxes editable
  inherit.box.disabled = root;   // the root inherits from nothing (DBA Dash: Inherit is off at the root)
  const enabled = check('Enabled', warnNow != null && critNow != null);
  const warn = number('Warning (mins)', minsOf(warnNow ?? r?.warn_default), r?.max_value == null ? null : Number(r.max_value) * 60);
  const crit = number('Critical (mins)', minsOf(critNow ?? r?.crit_default), r?.max_value == null ? null : Number(r.max_value) * 60);
  const rootLink = el('button', { type: 'button', class: 'link' }, 'Root Threshold Config');
  // DBA Dash's panel: 'Warning:' and 'Critical:' over their boxes, Enabled on the boxes' line, 'mins' after each
  const panel = el('fieldset', { style: 'border:none;padding:0;margin:0' },
    table(3, el('span', {}), labelOf('Warning: ', warn), labelOf('Critical: ', crit),
      enabled.label, el('span', {}, warn, ' mins'), el('span', {}, crit, ' mins')));
  const sync = () => { panel.disabled = inherit.box.checked; warn.disabled = crit.disabled = !enabled.box.checked; };
  inherit.box.addEventListener('change', sync); enabled.box.addEventListener('change', sync); sync();
  const started = root ? null : r?.started_at;
  // DBA Dash's 'Uptime: 1 hour, 20 minutes, 12 seconds' and '(Acknowledged)' after an acknowledgement newer than the start
  let acked = false;
  if (!root && started != null) {
    const a = checkAcks(ad).get(`${instanceId}|uptime`);
    acked = !!a && (!a.until_change || String(a.seen_state ?? '') === sinceState(started));
  }
  const uptime = started == null ? null : (Date.now() - Date.parse(String(started))) / 1000;
  const clear = el('button', { type: 'button' }, root ? 'Clear ALL Alerts' : 'Clear Alert');
  const update = el('button', { type: 'submit' }, 'Update');
  f.form.append(
    row(inherit.label, el('span', { style: 'flex:1' }), root ? '' : rootLink),   // DBA Dash: the link at the right
    panel,
    root ? el('p', { class: 'meta' }, 'The root threshold: every instance without its own or a tag\'s takes it.')
      : el('p', { style: 'font-style:italic' }, `Uptime: ${uptime == null ? 'not read yet' : humanize(uptime, 3)}${acked ? ' (Acknowledged)' : ''}`),
    root ? '' : el('p', { style: 'font-style:italic' }, `Start Time: ${started == null ? 'not read yet' : fmtTime(started)}`),
    el('p', { class: 'meta threshold-now' }, r
      ? `In force: ${warnNow == null ? 'no warning' : `warning under ${minsOf(warnNow)} mins`}, ${critNow == null ? 'no critical' : `critical under ${minsOf(critNow)} mins`}${root ? (r.threshold_id != null ? ' (set on the root)' : ' (the default)') : r.level === 'default' ? ' (the default)' : r.level === 'tag' ? ` (set on the tag ${String(r.tag)})` : ` (set on the ${String(r.level)})`}; the default: warning under ${minsOf(r.warn_default)} mins, critical under ${minsOf(r.crit_default)} mins.`
      : 'The instance or its threshold could not be read.'),
    row(clear, el('span', { style: 'flex:1' }), update), updNote ?? '');
  // every control of the dialog that is off says why: the seat's reason in the dialog's one sentence (both buttons
  // point at it where it is the same), a state of the button's own beside it, a threshold not read by the line that
  // says so - never the disabled attribute without a word
  if (updWhy && updNote) offBeside(update, updWhy, updNote);
  else if (!r) offBeside(update, 'the threshold could not be read', f.form.querySelector<HTMLElement>('p.threshold-now') ?? undefined);
  const clrOff = clrWhy ?? (root ? (clearAll ? null : "opened from an instance's dialog: Clear ALL Alerts is on the Summary's Options menu (Instance Uptime)")
    : started == null ? "the instance's start is not read yet" : acked ? 'acknowledged since this start' : null);
  if (clrOff) offBeside(clear, clrOff, clrWhy && clrWhy === updWhy && updNote ? updNote : undefined);
  rootLink.addEventListener('click', () => { f.dlg.close(); void openUptimeDialog(-1, clearAll); });
  clear.addEventListener('click', async () => {
    clear.disabled = true;
    try {
      if (root) {
        const res = clearAll ? await clearAll() : { done: 0, text: 'nothing to acknowledge from here' };
        f.said(res.done > 0, res.text);
        if (res.done) f.done(); else clear.disabled = false;
      } else {
        const res = await addAck({ kind: 'ack', instance_id: instanceId, check_key: 'uptime', seen_state: sinceState(started), until_change: true });
        f.said(true, `Alert cleared until the next restart (${res.outcome}).`);
        f.done();
      }
    } catch (e) { f.said(false, e instanceof Error ? e.message : String(e)); clear.disabled = false; }
  });
  f.form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (updWhy) { f.said(false, updWhy); return; }   // Enter in a field submits the form too: off is off
    if (!r) { f.said(false, 'the threshold could not be read'); return; }
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
export async function openDumpDialog(acknowledge?: Acked): Promise<void> {
  const r = await rootOf('crash');
  const f = frame('Memory Dump Thresholds', -1);
  // the root's thresholds: wider than one instance - off where the server writes nothing and on a demo serve, in words
  const ad = await loadAckSafe(['acks']);
  const updWhy = seatWhy(ad, 'thresholds');
  const updNote = updWhy ? el('p', { class: 'meta' }, `Update is off: ${updWhy}`) : null;
  const set = r?.threshold_id != null;
  const critV = set ? r?.crit : r?.crit_default, warnV = set ? r?.warn : r?.warn_default;
  const critOn = check('', critV != null), warnOn = check('', warnV != null);
  const crit = number('Critical Threshold (Hrs)', critV == null ? '0' : String(critV), r?.max_value);
  const warn = number('Warning Threshold (Hrs)', warnV == null ? '0' : String(warnV), r?.max_value);
  critOn.box.setAttribute('aria-label', 'Critical Threshold (Hrs): judged'); warnOn.box.setAttribute('aria-label', 'Warning Threshold (Hrs): judged');
  const sync = () => { crit.disabled = !critOn.box.checked; warn.disabled = !warnOn.box.checked; };
  critOn.box.addEventListener('change', sync); warnOn.box.addEventListener('change', sync); sync();
  // DBA Dash's {AckDate}: the newest acknowledgement of a Memory Dump cell still in force; Clear ends them all - on a
  // demo serve those of the door's instances alone: the others are left alone (never asked for, the door would refuse
  // each) and counted in the answer
  const allAcks = liveRows(ad, 'ack').filter(a => a.check_key === 'dumps');
  // what this server may end: all of them where it writes; the door's instances' on a demo serve; none elsewhere
  const ackRows = ad.writable ? allAcks : allAcks.filter(a => ackOn(ad, Number(a.instance_id) || null));
  const alone = onDoor(ad) && allAcks.length > ackRows.length ? `; ${allAcks.length - ackRows.length} acknowledgement(s) of instances not the demo's left alone` : '';
  // the instances behind those (one acknowledgement in force per instance, counted by instance all the same)
  const aloneN = alone ? new Set(allAcks.filter(a => !ackRows.includes(a)).map(a => String(a.instance_id ?? a.instance))).size : 0;
  // the date beside Clear is of what Clear would end here (a demo serve: its own instances'); a server that writes
  // nothing shows the newest in force
  const ackAt = (onDoor(ad) ? ackRows : allAcks).reduce<string | null>((a, x) => x.created_at != null && (a == null || String(x.created_at) > a) ? String(x.created_at) : a, null);
  const clearLink = el('button', { type: 'button', class: 'link' }, 'Clear');
  // acknowledgements stand that this server may not end: Clear is off with that reason in words (never on to be
  // refused once per row, never the disabled attribute without words); none stands at all: nothing to clear
  const clearWhy = ackRows.length || !allAcks.length ? null
    : onDoor(ad) ? "the acknowledgements in force are of instances that are not the demo's: ending them needs pgvigil serve with a signed-in user"
    : ackWhy(ad) ?? 'acknowledgements are off';
  // nothing in force at all: Clear is off with those words (the date beside it reads 'Not acknowledged')
  if (clearWhy || !allAcks.length) offBeside(clearLink, clearWhy ?? 'no Memory Dump acknowledgement is in force');
  const ackLink = el('button', { type: 'button', class: 'link' }, 'Acknowledge');
  if (!acknowledge) offBeside(ackLink, "opened without the Summary: Acknowledge is the Summary's Options > Memory Dumps > Acknowledge Dumps");
  const update = el('button', { type: 'submit' }, 'Update'), cancel = el('button', { type: 'button' }, 'Cancel');
  // DBA Dash's order (MemoryDumpThresholdsConfig.Designer.cs): Warning, then Critical, each label | box | check box;
  // Acknowledge | the acknowledge date | Clear; Cancel, Update. No acknowledgement: DBA Dash shows its stored
  // 1/1/1900; pgvigil stores none and says so
  f.form.append(
    table(3, labelOf('Warning Threshold (Hrs): ', warn), warn, warnOn.label,
      labelOf('Critical Threshold (Hrs): ', crit), crit, critOn.label,
      // (on a demo serve the date is of the demo's own instances: the others in force are counted beside it, so 'Not
      // acknowledged' on a mixed store is never read as 'nothing is acknowledged')
      ackLink, el('span', {}, (ackAt == null ? 'Not acknowledged' : fmtTime(ackAt)) + (aloneN ? ` (${aloneN} instance(s) not the demo's left alone)` : '')), el('span', {}, clearLink)),
    el('p', { class: 'meta threshold-now' }, r
      ? `${set ? 'Set on the root' : 'The default'}: critical when the newest memory dump (SQL Server) or crash restart (PostgreSQL) is under ${critV ?? '-'} hours old, warning under ${warnV ?? '-'}; the default ${r.crit_default} / ${r.warn_default} hours.`
      : 'The threshold could not be read.'),
    row(el('span', { style: 'flex:1' }), cancel, update), updNote ?? '');
  if (updWhy && updNote) offBeside(update, updWhy, updNote);
  else if (!r) offBeside(update, 'the threshold could not be read', f.form.querySelector<HTMLElement>('p.threshold-now') ?? undefined);
  cancel.addEventListener('click', () => f.dlg.close());
  ackLink.addEventListener('click', async () => {
    ackLink.disabled = true;
    try {
      const res = acknowledge ? await acknowledge() : { done: 0, text: 'nothing to acknowledge from here' };
      f.said(res.done > 0, res.text);
      if (res.done) f.done(); else ackLink.disabled = false;
    } catch (e) { f.said(false, e instanceof Error ? e.message : String(e)); ackLink.disabled = false; }
  });
  clearLink.addEventListener('click', async () => {
    clearLink.disabled = true;
    const failed: string[] = [];
    for (const a of ackRows) { try { await endAck(Number(a.ack_id)); } catch (e) { failed.push(e instanceof Error ? e.message : String(e)); } }
    f.said(!failed.length, failed.length ? `${failed.join('; ')}${alone}` : `${ackRows.length} acknowledgement(s) ended: the dumps show again${alone}.`);
    f.done();
  });
  f.form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (updWhy) { f.said(false, updWhy); return; }   // Enter in a field submits the form too: off is off
    if (!r) { f.said(false, 'the threshold could not be read'); return; }
    update.disabled = true;
    try {
      const a = await send({ op: 'set', key: 'crash', level: 'root', crit: critOn.box.checked && crit.value !== '' ? Number(crit.value) : null, warn: warnOn.box.checked && warn.value !== '' ? Number(warn.value) : null });
      f.said(true, `Thresholds updated: ${a.outcome}${a.detail ? ' - ' + a.detail : ''}`); f.done();
    } catch (e) { f.said(false, e instanceof Error ? e.message : String(e)); }
    update.disabled = false;
  });
  f.show(warn.disabled ? warnOn.box : warn);   // DBA Dash's first field: the warning box
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
