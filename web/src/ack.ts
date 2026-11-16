// Acknowledge, mute and notes (task 118): the one store of 0073 as the pages use it. GET /api/ack reads it (the rows in
// force, the window's attempts, the held sends, the open alerts with their state, the Needs-attention rates); POST
// /api/ack makes one row and POST /api/ack/end ends one, through the actions door's write path (the UI login and the
// X-Pgvigil header; api.post). Nothing writes on a bare click: every write opens a dialog that says what it does, and
// the server answers with the row's id or the reason it refused. Who and when are the server's (the session's user).
import { get, post, Row, rowsOf, Table } from './api';
import { badge, el, fmtTime, offControl } from './ui';
import { fromInput, toInput } from './tz';
import { Can, markNeed, Need, needControl, roleWhy, routeWhy, WriteRoute } from './needs';

// AckDoor: the demo's write door (pgvigil demo -serve, task B7): the server's own writes stay off there (writable
// false with the reason), and the door writes as its user for the instances it names and for no other.
export interface AckDoor { user: string; instances: number[] }

export interface AckData {
  writable: boolean; reason?: string; user: string; door?: AckDoor | null;
  // what the session's role may do, as the server read it for this answer (B24f; needs.ts): it decides a write
  // control's role over the role the page signed in with
  can?: Can | null;
  acks?: Table | null; log?: Table | null; suppressed?: Table | null; alerts?: Table | null; attention?: Table | null;
  // the page's one visible sentence for a reason EVERY off control of the page shares (a server that writes nothing at
  // all): the page that draws the sentence sets it here, and an off control without a note of its own points at it
  // instead of repeating the words beside itself (pageNote). Never used where a door stands: there a control that is
  // off has a reason of its own.
  note?: HTMLElement;
}

// pageNote: the page's shared sentence for an off control, where the page set one and no door stands
export const pageNote = (d: AckData): HTMLElement | undefined => (d.door ? undefined : d.note);

export type AckKind = 'ack' | 'alert_ack' | 'note' | 'close' | 'blackout' | 'job' | 'silence' | 'mute' | 'noise';

export interface AckBody {
  kind: AckKind; instance_id?: number; check_key?: string; finding_key?: string; job_name?: string; tag?: string;
  match_text?: string; note?: string; seen_state?: string; starts_at?: string; until?: string; until_change?: boolean;
}

// loadAck reads the parts named (all when none); a server without the route answers writable false with the reason
export async function loadAck(parts: string[] = [], params: Record<string, string | number | undefined> = {}): Promise<AckData> {
  if (parts.length <= 1) return get<AckData>('ack', { ...params, part: parts[0] });
  const all = await Promise.all(parts.map(p => get<AckData>('ack', { ...params, part: p })));
  return Object.assign({}, ...all) as AckData;
}

export async function loadAckSafe(parts: string[], params: Record<string, string | number | undefined> = {}): Promise<AckData> {
  try { return await loadAck(parts, params); } catch (e) {
    return { writable: false, reason: e instanceof Error ? e.message : String(e), user: '' };
  }
}

// ackOn: can a write for this instance be made here? Yes on a server that writes (a signed-in serve), and on a demo
// serve for an instance of the demo's door. No instance = a write that names none (a rule on every instance, a root or
// tag level): the door never carries it. 'any' = a control whose instance is picked later (a bulk action over ticked
// rows, a dialog with an instance field): on wherever a door stands, and the server answers for each instance.
export type AckInstance = number | null | 'any';
export const ackOn = (d: AckData, instanceId?: AckInstance): boolean =>
  d.writable || (!!d.door && (instanceId === 'any' || (instanceId != null && d.door.instances.includes(Number(instanceId)))));

// ackWhy: the words of a control that is off, null when it is on. name: the instance as the page shows it.
export function ackWhy(d: AckData, instanceId?: AckInstance, name?: string): string | null {
  if (ackOn(d, instanceId)) return null;
  if (d.door && instanceId != null) return `${name ?? 'this instance'} is not one of this demo's instances: changing it needs pgvigil serve with a signed-in user`;
  if (d.door) return "this change would reach past the demo's instances: set it on one demo instance here, or use pgvigil serve with a signed-in user";
  return d.reason ?? 'acknowledgements are off';
}

// onDoor: a demo serve whose writes go through the door alone (the server's own stay off)
export const onDoor = (d: AckData): boolean => !d.writable && !!d.door;

// doorRows: the instances a picker offers. On a demo serve the door's own alone - a control is never on for an
// instance the door would refuse - and every instance on any other server.
export const doorRows = (d: AckData, insts: Row[]): Row[] =>
  onDoor(d) ? insts.filter(i => d.door!.instances.includes(Number(i.instance_id))) : insts;

export interface AckResult { outcome: string; detail: string; ack_id?: number | null }
export const addAck = (b: AckBody) => post<AckResult>('ack', b);
export const endAck = (id: number) => post<AckResult>('ack/end', { ack_id: id });

export const liveRows = (d: AckData, kind?: AckKind): Row[] => rowsOf(d.acks).filter(r => r.live && (!kind || r.kind === kind));

// checkAcks: the Summary's acknowledged checks in force, by 'instance_id|check_key' (the newest one wins)
export function checkAcks(d: AckData): Map<string, Row> {
  const m = new Map<string, Row>();
  for (const r of liveRows(d, 'ack')) {
    const k = `${String(r.instance_id)}|${String(r.check_key)}`;
    if (!m.has(k)) m.set(k, r);   // rows come newest first
  }
  return m;
}

// ackHolds: an acknowledgement still covers a cell whose text reads `now` (until-change: the text it was given for)
export const ackHolds = (a: Row | undefined, now: string): boolean =>
  !!a && (!a.until_change || String(a.seen_state ?? '') === now);

// ackWords: who and when, and how long it stands
export function ackWords(a: Row): string {
  const until = a.until ? `until ${fmtTime(a.until)}` : '';
  const change = a.until_change ? `until it changes from '${String(a.seen_state ?? '').replace(/ #[0-9a-z]+$/, '')}'` : '';
  return `acknowledged by ${String(a.created_by)} ${fmtTime(a.created_at)}${[until, change].filter(Boolean).map(x => ', ' + x).join('')}`;
}

// seatWhy: ackWhy for a write of the same family under another noun (a threshold, a job exclusion: the server asks the
// same seat and says the same sentence with its own noun) - null when the control is on
export function seatWhy(d: AckData, noun: string, instanceId?: AckInstance, name?: string): string | null {
  const w = ackWhy(d, instanceId, name);
  return w == null ? null : w.replace('acknowledgements', noun);
}

// jobAcks: the job acknowledgements in force, by 'instance_id|job_name'
export function jobAcks(d: AckData): Map<string, Row> {
  const m = new Map<string, Row>();
  for (const r of liveRows(d, 'job')) {
    const k = `${String(r.instance_id)}|${String(r.job_name)}`;
    if (!m.has(k)) m.set(k, r);
  }
  return m;
}

// jobAckCell: a Jobs grid's Acknowledge cell (the Jobs pages call it: their WIRING). A failed job not acknowledged:
// an 'Acknowledge' button; acknowledged for this failure: the date and who, with 'Clear'; a newer failure than the one
// acknowledged: the button again (the old row lapses by itself). lastFail is the job's last failure time as the page
// has it; no failure = an empty cell. note: the page's one sentence for an Acknowledge that is off on this page (every
// row of the grid shares the reason - the server writes nothing, or the instance is not the demo's): the button points
// at it, and the cell - which Copy all and the exports carry - holds the button alone. name: the instance as the page
// shows it (the off button's own title then names it as the sentence does).
export function jobAckCell(d: AckData, instanceId: number, jobName: string, lastFail: unknown, after: () => void, note?: HTMLElement, name?: string): HTMLElement {
  const span = el('span', { style: 'white-space:nowrap' });
  if (lastFail == null || lastFail === '') return span;
  const a = jobAcks(d).get(`${instanceId}|${jobName}`);
  if (a && String(a.seen_state) === String(lastFail)) {
    span.append(el('span', { title: ackWords(a) }, `acknowledged ${fmtTime(a.created_at)}`), ' ');
    if (ackOn(d, instanceId)) span.append(endButton(Number(a.ack_id), `Clear the acknowledgement of ${jobName}`, after, 'Clear'));
    return span;
  }
  span.append(writeButton(d, 'Acknowledge', `Acknowledge ${jobName}`, () => ackDialog({
    title: `Acknowledge job ${jobName}`,
    what: `Its failure of ${fmtTime(lastFail)} is acknowledged: the cell loses its colour until the job fails again. Who and when are kept.`,
    body: { kind: 'job', instance_id: instanceId, job_name: jobName, seen_state: String(lastFail) },
    expiry: false, after,
  }), { instance: instanceId, name, note }));
  return span;
}

// writeButton: a button that opens a write's dialog; where the write cannot be made it is off with its reason in
// words on the page (ui.ts offControl: aria-disabled, the reason its description and visible text). instanceId: the
// at.instance: the instance the write names (none = a write wider than one instance; 'any' = picked later); at.name:
// that instance as the page shows it; at.note: the page's own visible sentence when it says this reason already (without
// one the reason is put beside the button once the caller has placed it); at.why: the words when the reason is the
// control's own (Send test on a demo serve); at.route: the route the dialog posts to when it is not POST /api/ack (a
// threshold, a test alert) - the button carries that route's need and is off below it with the role's words (B24f);
// at.need / at.what: a write that needs more than its route (wideMute: a mute, silence or blackout over more than one
// instance or with no end needs admin, checked in the handler).
export interface WriteAt { instance?: AckInstance; name?: string; note?: HTMLElement; why?: string | null; route?: WriteRoute; need?: Need; what?: string }
// wideMute: the need of a mute that always reaches past one instance (Mute similar, a rule from a dialog without an
// instance field) - the server's own words for it (q_ack.go)
export const wideMute: { need: Need; what: string } = { need: 'admin', what: 'a fleet-wide or open-ended mute' };
export function writeButton(d: AckData, label: string, aria: string, open: () => void, at: WriteAt = {}): HTMLButtonElement {
  const b = el('button', { type: 'button', class: 'link', 'aria-label': aria }, label);
  const why = at.why ?? ackWhy(d, at.instance, at.name);
  if (why) offBeside(b, why, at.note ?? pageNote(d)); else b.addEventListener('click', open);
  return needControl(b, at.route ?? 'ack', { can: d.can, need: at.need, what: at.what });
}

// offBeside: a control that is off, its reason in words on the page - the page's own sentence when one is given,
// else a note put beside the control once the caller has placed it (the caller appends the control in the same turn)
export function offBeside(b: HTMLElement, why: string, note?: HTMLElement): void {
  const made = offControl(b, why, note);
  if (!note) queueMicrotask(() => { if (b.parentNode && !made.parentNode) b.after(' ', made); });
}

// endButton: ends one row (unacknowledge, unsilence, remove a rule) after a confirm
export function endButton(id: number, aria: string, after: () => void, label = 'End'): HTMLButtonElement {
  const b = el('button', { type: 'button', class: 'link', 'aria-label': aria }, label);
  b.addEventListener('click', () => confirmDialog(aria + '?', 'The row stays in the store with who ended it and when.', label,
    async () => { const r = await endAck(id); return r; }, after, [], () => true, [], '', 'ack/end'));
  return needControl(b, 'ack/end');
}

const untilChoices: [string, number][] = [['1 hour', 1], ['4 hours', 4], ['1 day', 24], ['7 days', 168], ['no expiry', 0]];

export interface AckDialog {
  title: string; what: string; body: AckBody | AckBody[];
  expiry: boolean;            // an 'until' select
  untilChange?: boolean;      // the 'until the check changes' box (checked by default)
  noteField?: 'optional' | 'required' | 'label';
  matchFields?: boolean;      // a mute or noise rule's matchers (check, instance, tag, text)
  blackout?: boolean;         // a start and an end
  after: () => void;
}

// ackDialog: the one dialog every write goes through - what it does, its fields, then the server's answer
export function ackDialog(o: AckDialog) {
  const fields: HTMLElement[] = [];
  // a mute, a silence or a blackout over more than one instance (no instance, a tag) or open-ended (no end, or an end
  // more than 7 days away) needs the admin role (the handler checks it: wideMute; a one-alert mute is one scope).
  // Below admin a row that reaches wide makes Save need admin; else the dialog offers no 'no expiry' and holds a
  // blackout's end to 7 days, and says why (null for an admin and with the login off)
  const rows0 = Array.isArray(o.body) ? o.body : [o.body];
  const scoped = rows0.filter(b => b.kind === 'mute' || b.kind === 'silence' || b.kind === 'blackout');
  const wideWhy = scoped.length ? roleWhy(wideMute.need, wideMute.what) : null;
  const wide = !!wideWhy && scoped.some(b => b.tag || !(Number(b.instance_id) > 0 || (b.kind === 'mute' && b.finding_key)));
  const openEnded = wide ? null : wideWhy;
  const untilSel = el('select', { 'aria-label': 'until' }, ...untilChoices.filter(([, h]) => h > 0 || !openEnded).map(([t, h]) => el('option', { value: String(h) }, t)));
  if (o.expiry) {
    untilSel.value = '24'; fields.push(el('label', {}, 'Until ', untilSel));
    if (openEnded) fields.push(el('p', { class: 'meta' }, `'no expiry' is not offered here: ${openEnded}.`));
  }
  const change = el('input', { type: 'checkbox', checked: '' });
  if (o.untilChange) fields.push(el('label', {}, change, ' or until the check changes'));
  const note = el('textarea', { rows: '3', maxlength: '2000', 'aria-label': o.noteField === 'label' ? 'label' : 'note', style: 'width:100%' });
  if (o.noteField) fields.push(el('label', {}, o.noteField === 'label' ? 'Label (shown beside matching alerts)' : o.noteField === 'required' ? 'Note' : 'Note (optional)', el('br'), note));
  const m = {
    check: el('input', { type: 'text', 'aria-label': 'check', maxlength: '200' }),
    tag: el('input', { type: 'text', 'aria-label': 'tag', maxlength: '200' }),
    text: el('input', { type: 'text', 'aria-label': 'text', maxlength: '200' }),
  };
  const base = Array.isArray(o.body) ? o.body[0] : o.body;
  if (o.matchFields) {
    m.check.value = base.check_key ?? ''; m.tag.value = base.tag ?? ''; m.text.value = base.match_text ?? '';
    fields.push(el('p', { class: 'meta' }, 'An alert matches when every field filled matches (check: its source or setting; text: in its source, setting or value).'),
      el('span', {}, el('label', {}, 'Check ', m.check), ' ', el('label', {}, 'Tag ', m.tag), ' ', el('label', {}, 'Text ', m.text)));
  }
  const local = (t: Date) => toInput(t);
  const from = el('input', { type: 'datetime-local', 'aria-label': 'from' }), to = el('input', { type: 'datetime-local', 'aria-label': 'to' });
  if (o.blackout) {
    const n = new Date(); from.value = local(n); to.value = local(new Date(n.getTime() + 2 * 3600000));
    fields.push(el('span', {}, el('label', {}, 'From ', from), ' ', el('label', {}, 'to ', to)));
  }
  const build = (): AckBody[] => (Array.isArray(o.body) ? o.body : [o.body]).map(b => {
    const x: AckBody = { ...b };
    // the 7-day choice ends 10 minutes short of 168 h (the lead 11-15 19:3x): the server measures the ceiling by its own
    // clock, and a browser clock ahead of it would else make an operator's 7-day mute open-ended
    if (o.expiry && Number(untilSel.value) > 0) x.until = new Date(Date.now() + Number(untilSel.value) * 3600000 - (Number(untilSel.value) >= 168 ? 600e3 : 0)).toISOString();
    if (o.untilChange) x.until_change = change.checked;
    if (o.noteField && note.value.trim()) x.note = note.value.trim();
    if (o.matchFields) {
      x.check_key = m.check.value.trim() || undefined; x.tag = m.tag.value.trim() || undefined; x.match_text = m.text.value.trim() || undefined;
    }
    if (o.blackout) { x.starts_at = fromInput(from.value).toISOString(); x.until = fromInput(to.value).toISOString(); }
    return x;
  });
  const noteOK = () => (o.noteField !== 'required' && o.noteField !== 'label') || note.value.trim().length > 0;
  // a blackout's end at most 7 days after its start (or now) below admin (the lead 13:3x)
  const inCeiling = () => !o.blackout || !openEnded
    || fromInput(to.value).getTime() - Math.max(Date.now(), fromInput(from.value).getTime()) <= 7 * 86400e3 - 600e3;   // 10 minutes of margin for the browser's clock (review-21 N1)
  const valid = () => noteOK() && inCeiling();
  const needs = () => !noteOK() ? (o.noteField === 'label' ? 'a label' : 'a note') : `an end at most 7 days after the start (${openEnded})`;
  confirmDialog(o.title, o.what, 'Save', async () => {
    const rows = build();
    if (!rows.length) return { outcome: 'nothing to do', detail: 'every row picked already holds this' };
    // one post per row: a refusal part way leaves the rows before it written, and the answer says which
    let done = 0;
    const refused: string[] = [];
    for (const b of rows) {
      try { await addAck(b); done++; } catch (e) { refused.push(e instanceof Error ? e.message : String(e)); }
    }
    // nothing saved: one row says its reason; several say how many were refused, each distinct reason once
    if (done === 0) throw new Error(rows.length > 1 ? `0 of ${rows.length} saved; ${refused.length} refused: ${[...new Set(refused)].join('; ')}` : refused[0] ?? 'refused');
    return { outcome: refused.length ? 'partly done' : 'done',
      detail: `${done} of ${rows.length} saved` + (refused.length ? `; ${refused.length} refused: ${[...new Set(refused)].join('; ')}` : '') };
  }, o.after, fields, valid, [note, from, to], needs, 'ack', wide ? wideMute : undefined);
}

// confirmDialog: a modal with what the write does, its fields, Save / Back, and the answer in place
// needs: what Save waits for while valid() is false ('a note'): said in words under the fields, and Save is off the B7
// way meanwhile (aria-disabled, described by those words) - never a Save that is greyed without a word. route: the
// route Save posts to: below its need Save is off with the role's words in the same place (B24f), whatever the fields
// hold - a dialog opened from a menu or a link says so before anything is typed.
// needOver: a need above the route's (wideMute: a row that reaches past one instance). The answer's 'can' that drew the
// control that opened the dialog decides here too (needs.ts lastCan).
function confirmDialog(title: string, what: string, go: string, run: () => Promise<AckResult>, after: () => void,
  fields: HTMLElement[] = [], valid: () => boolean = () => true, watch: HTMLElement[] = [], needs: string | (() => string) = '',
  route: WriteRoute = 'ack', needOver?: { need: Need; what: string }) {
  const ok = markNeed(el('button', { type: 'submit' }, go), route);
  if (needOver) ok.dataset.need = needOver.need;
  const role = needOver ? roleWhy(needOver.need, needOver.what) : routeWhy(route);
  const needText = () => (typeof needs === 'function' ? needs() : needs) || 'the fields above';
  const no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const needP = el('p', { class: 'meta' });
  let saving = false;
  const check = () => {
    if (saving) return;
    const why = role ?? (valid() ? null : `Saving needs ${needText()}`);
    needP.textContent = why ? why + '.' : '';
    offControl(ok, why, needP);
  };
  for (const w of watch) w.addEventListener('input', check);
  check();
  const form = el('form', { method: 'dialog' }, el('h3', {}, title), el('p', {}, what),
    ...fields.map(f => el('div', { style: 'margin:.3rem 0' }, f)), needP, msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': title }, form);
  let done = false;
  const close = () => { dlg.close(); dlg.remove(); if (done) after(); };
  no.addEventListener('click', close);
  dlg.addEventListener('cancel', () => { dlg.remove(); if (done) after(); });
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (saving || role || !valid()) return;   // off is off: an Enter in a field submits the form too
    saving = true;
    offControl(ok, null, needP);
    ok.disabled = true;
    msg.textContent = 'Saving...';
    try {
      const r = await run();
      done = true;
      msg.replaceChildren(badge(r.outcome, 'ok'), ' ', r.detail);
      no.textContent = 'Close';
    } catch (e) {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      no.textContent = 'Close';
    }
  });
  document.body.append(dlg);
  dlg.showModal();
  (dlg.querySelector('input,select,textarea,button') as HTMLElement | null)?.focus();
}
