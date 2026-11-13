// Acknowledge, mute and notes (task 118): the one store of 0073 as the pages use it. GET /api/ack reads it (the rows in
// force, the window's attempts, the held sends, the open alerts with their state, the Needs-attention rates); POST
// /api/ack makes one row and POST /api/ack/end ends one, through the actions door's write path (the UI login and the
// X-Pgvigil header; api.post). Nothing writes on a bare click: every write opens a dialog that says what it does, and
// the server answers with the row's id or the reason it refused. Who and when are the server's (the session's user).
import { get, post, Row, rowsOf, Table } from './api';
import { badge, el, fmtTime, offControl } from './ui';
import { fromInput, toInput } from './tz';

// AckDoor: the demo's write door (pgvigil demo -serve, task B7): the server's own writes stay off there (writable
// false with the reason), and the door writes as its user for the instances it names and for no other.
export interface AckDoor { user: string; instances: number[] }

export interface AckData {
  writable: boolean; reason?: string; user: string; door?: AckDoor | null;
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
// has it; no failure = an empty cell.
export function jobAckCell(d: AckData, instanceId: number, jobName: string, lastFail: unknown, after: () => void): HTMLElement {
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
  }), { instance: instanceId }));
  return span;
}

// writeButton: a button that opens a write's dialog; where the write cannot be made it is off with its reason in
// words on the page (ui.ts offControl: aria-disabled, the reason its description and visible text). instanceId: the
// at.instance: the instance the write names (none = a write wider than one instance; 'any' = picked later); at.name:
// that instance as the page shows it; at.note: the page's own visible sentence when it says this reason already (without
// one the reason is put beside the button once the caller has placed it); at.why: the words when the reason is the
// control's own (Send test on a demo serve).
export interface WriteAt { instance?: AckInstance; name?: string; note?: HTMLElement; why?: string | null }
export function writeButton(d: AckData, label: string, aria: string, open: () => void, at: WriteAt = {}): HTMLButtonElement {
  const b = el('button', { type: 'button', class: 'link', 'aria-label': aria }, label);
  const why = at.why ?? ackWhy(d, at.instance, at.name);
  if (why) offBeside(b, why, at.note ?? pageNote(d)); else b.addEventListener('click', open);
  return b;
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
    async () => { const r = await endAck(id); return r; }, after));
  return b;
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
  const untilSel = el('select', { 'aria-label': 'until' }, ...untilChoices.map(([t, h]) => el('option', { value: String(h) }, t)));
  if (o.expiry) { untilSel.value = '24'; fields.push(el('label', {}, 'Until ', untilSel)); }
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
    if (o.expiry && Number(untilSel.value) > 0) x.until = new Date(Date.now() + Number(untilSel.value) * 3600000).toISOString();
    if (o.untilChange) x.until_change = change.checked;
    if (o.noteField && note.value.trim()) x.note = note.value.trim();
    if (o.matchFields) {
      x.check_key = m.check.value.trim() || undefined; x.tag = m.tag.value.trim() || undefined; x.match_text = m.text.value.trim() || undefined;
    }
    if (o.blackout) { x.starts_at = fromInput(from.value).toISOString(); x.until = fromInput(to.value).toISOString(); }
    return x;
  });
  const valid = () => (o.noteField !== 'required' && o.noteField !== 'label') || note.value.trim().length > 0;
  confirmDialog(o.title, o.what, 'Save', async () => {
    const rows = build();
    if (!rows.length) return { outcome: 'nothing to do', detail: 'every row picked already holds this' };
    // one post per row: a refusal part way leaves the rows before it written, and the answer says which
    let done = 0;
    const refused: string[] = [];
    for (const b of rows) {
      try { await addAck(b); done++; } catch (e) { refused.push(e instanceof Error ? e.message : String(e)); }
    }
    if (done === 0) throw new Error(refused[0] ?? 'refused');
    return { outcome: refused.length ? 'partly done' : 'done',
      detail: `${done} of ${rows.length} saved` + (refused.length ? `; refused: ${refused.join('; ')}` : '') };
  }, o.after, fields, valid, [note]);
}

// confirmDialog: a modal with what the write does, its fields, Save / Back, and the answer in place
function confirmDialog(title: string, what: string, go: string, run: () => Promise<AckResult>, after: () => void,
  fields: HTMLElement[] = [], valid: () => boolean = () => true, watch: HTMLElement[] = []) {
  const ok = el('button', { type: 'submit' }, go);
  const no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const check = () => { ok.disabled = !valid(); };
  for (const w of watch) w.addEventListener('input', check);
  check();
  const form = el('form', { method: 'dialog' }, el('h3', {}, title), el('p', {}, what),
    ...fields.map(f => el('div', { style: 'margin:.3rem 0' }, f)), msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': title }, form);
  let done = false;
  const close = () => { dlg.close(); dlg.remove(); if (done) after(); };
  no.addEventListener('click', close);
  dlg.addEventListener('cancel', () => { dlg.remove(); if (done) after(); });
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
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
