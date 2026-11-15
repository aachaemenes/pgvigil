// Where a PostgreSQL server's base backups and WAL go (task 302): 'base backups to', 'WAL to' and 'restore from' as
// the newest backup_dest read named them (each with its source: archive_command, archive_library, restore_command, or
// the tool's own configuration when read_tools is on), the managed platforms' line, and a person's entry shown BESIDE
// a read value, never over it. Data from /api/pg/backup_dest; the lead wires the section into the Base backups tab and
// the fleet columns into the fleet Backups section (pg_backups.ts: one import and a few lines each).
import { get, Row, rowsOf, Table } from './api';
import { AckData, offBeside, seatWhy } from './ack';
import { badge, Col, el, errorBox, fmtTime, grid, props } from './ui';

type Parts = 'destinations' | 'dests' | 'reads' | 'settings' | 'findings' | 'history' | 'door';

const readWord: Record<string, string> = { off: 'not read: the tool read is off for this instance', ok: 'read', no_binary: 'no binary on the collector host', error: 'error' };

// the line of one role: what was read (or why nothing was), the entry beside it
function roleLine(r: Row): Node {
  const out = el('span', {});
  if (r.platform_line) out.append(String(r.platform_line));
  else if (r.read_text) out.append(String(r.read_text), r.confirmed === true ? ' ' : '', r.confirmed === true ? badge('confirmed', 'ok') : '');
  else out.append(el('em', {}, String(r.not_known ?? 'not known')));
  if (r.entered_text) {
    out.append(el('br', {}), el('span', { class: 'meta' }, `entered by ${String(r.entered_by)} on ${fmtTime(r.entered_at)}: `), String(r.entered_text),
      r.entered_note ? el('span', { class: 'meta' }, ` (${String(r.entered_note)})`) : '',
      r.entered_beside_read === true ? el('span', { class: 'meta' }, ' - beside the value read, which it does not replace') : '',
      r.read_changed_since_entry === true ? el('span', { class: 'meta' }, ' ', badge('the read changed after this entry', 'warn')) : '');
  }
  return out;
}

// entryDialog: a person's destination for one role; an empty text ends the entry in force.
function entryDialog(instanceId: number, name: string, r: Row, after: () => void) {
  const text = el('input', { type: 'text', maxlength: '500', 'aria-label': 'where the backups go', value: String(r.entered_text ?? ''), style: 'width:28rem' });
  const note = el('input', { type: 'text', maxlength: '500', 'aria-label': 'a note', value: String(r.entered_note ?? ''), style: 'width:28rem' });
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const save = el('button', { type: 'submit' }, 'Save'), back = el('button', { type: 'button' }, 'Back');
  const form = el('form', { method: 'dialog' }, el('h3', {}, `${String(r.label)}: ${name}`),
    el('p', {}, 'Name where they go - a host and a directory, a bucket, a share. Never a password, a key or a signed URL: such an entry is refused. An empty text ends the entry in force; who and when are kept.'),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Where ', text)), el('div', { style: 'margin:.3rem 0' }, el('label', {}, 'Note ', note)),
    msg, el('div', { style: 'margin-top:.6rem' }, save, ' ', back));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': `${String(r.label)} for ${name}` }, form);
  let done = false;
  const close = () => { dlg.close(); dlg.remove(); if (done) after(); };
  back.addEventListener('click', close);
  dlg.addEventListener('cancel', () => { dlg.remove(); if (done) after(); });
  form.addEventListener('submit', ev => {
    ev.preventDefault();
    save.disabled = true;
    msg.textContent = 'Saving...';
    void (async () => {
      try {
        const res = await fetch('/api/pg/backup_dest', { method: 'POST', credentials: 'same-origin',
          headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
          body: JSON.stringify({ instance_id: instanceId, role: r.role, text: text.value, note: note.value }) });
        let b: { outcome?: string; detail?: string; error?: string } = {};
        try { b = await res.json(); } catch { /* an empty body */ }
        if (!res.ok) throw new Error(b.outcome ? `${b.outcome}: ${b.detail ?? ''}` : b.error ?? `${res.status} ${res.statusText}`);
        done = true;
        msg.replaceChildren(badge('saved', 'ok'));
      } catch (e) {
        msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
        save.disabled = false;
      }
      back.textContent = 'Close';
    })();
  });
  document.body.append(dlg);
  dlg.showModal();
  text.focus();
}

const destCols: Col[] = [
  { key: 'role', label: 'for' }, { key: 'source' }, { key: 'tool' }, { key: 'dest_kind', label: 'kind' }, { key: 'host' }, { key: 'container', label: 'bucket / container' },
  { key: 'path' }, { key: 'repo_key', label: 'repository' }, { key: 'detail', wide: true }, { key: 'secret_seen', label: 'a credential in it', fmt: v => v === true ? 'yes (not stored)' : '' },
  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
];

// pgBackupDestSection: one instance's 'Where the backups go' (the Base backups tab). ad: who may enter a destination
// here (the acknowledgement seat, as the thresholds).
export async function pgBackupDestSection(instanceId: number, name: string, ad: AckData, after: () => void): Promise<HTMLElement> {
  const sec = el('section', { id: 'pg-backup-dest' }, el('h3', {}, 'Where the backups go'));
  try {
    const d = await get<Record<Parts, Table | null>>('pg/backup_dest', { instance: instanceId });
    const roles = rowsOf(d.destinations), reads = rowsOf(d.reads), set = rowsOf(d.settings)[0];
    // the server's own off words first (a demo serve carries no entry whatever the seat says), then the seat's
    const doorOff = String(rowsOf(d.door)[0]?.off ?? '');
    const why = doorOff || (seatWhy(ad, 'backup destinations', instanceId, name) ?? '');
    const note = why ? el('p', { class: 'meta' }, `Destinations are read only here: ${why}`) : null;
    sec.append(el('p', { class: 'meta' }, 'Read from the server\'s archive_command, archive_library and restore_command (no command text is kept), and from the backup tool\'s own '
      + 'configuration on the collector\'s host when the instance has backups: read_tools: true in pgvigil.yaml. A destination a person enters is shown beside the one read.'));
    if (note) sec.append(note);
    sec.append(props(roles.map((r): [string, string | Node] => {
      const edit = el('button', { type: 'button', class: 'link', 'aria-label': `Edit ${String(r.label)} for ${name}` }, 'Edit');
      if (note) offBeside(edit, why, note); else edit.addEventListener('click', () => entryDialog(instanceId, name, r, after));
      return [String(r.label), el('span', {}, roleLine(r), ' ', edit)];
    })));
    if (set && set.standby_archives === false) sec.append(el('p', { class: 'meta' }, 'This standby does not archive: archive_mode on archives on a primary only (always archives in recovery too).'));
    if (reads.length) {
      sec.append(el('h4', {}, 'The tool reads'), grid(reads, [{ key: 'tool' }, { key: 'name', label: 'stanza / server' },
        { key: 'state', fmt: v => readWord[String(v)] ?? String(v ?? '') }, { key: 'message', wide: true }, { key: 'snapshot_at', label: 'read', fmt: fmtTime }], 'No tool read.'));
    }
    sec.append(el('h4', {}, 'Every destination read'), grid(rowsOf(d.dests), destCols, 'backup_dest has not stored a read of this server yet (every 15 minutes).'));
    const f = rowsOf(d.findings);
    if (f.length) sec.append(el('h4', {}, 'Findings'), grid(f, [{ key: 'severity' }, { key: 'check_name', label: 'check' }, { key: 'object' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime }], ''));
    const h = rowsOf(d.history);
    if (h.length) sec.append(el('h4', {}, 'Entries and their history'), grid(h, [{ key: 'role', label: 'for' }, { key: 'dest_text', label: 'entered', wide: true }, { key: 'note' },
      { key: 'entered_by', label: 'by' }, { key: 'entered_at', label: 'on', fmt: fmtTime }, { key: 'ended_at', label: 'ended', fmt: fmtTime }, { key: 'ended_by', label: 'ended by' }], ''));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// pgBackupDestFleet: every instance's 'base backups to' and 'WAL to', by instance id (the fleet Backups section's two
// columns).
export async function pgBackupDestFleet(): Promise<Map<number, Row>> {
  const d = await get<Record<'fleet', Table | null>>('pg/backup_dest/fleet');
  return new Map(rowsOf(d.fleet).map(r => [Number(r.instance_id), r]));
}

// the read value, and a person's entry apart from it (never as if read)
const withEntry = (entered: string) => (v: unknown, r: Row) => {
  const e = r[entered];
  return e ? `${String(v ?? '')} (entered: ${String(e)})` : String(v ?? '');
};
export const pgBackupDestFleetCols: Col[] = [
  { key: 'base_to', label: 'base backups to', wide: true, fmt: withEntry('base_entered') }, { key: 'wal_to', label: 'WAL to', wide: true, fmt: withEntry('wal_entered') },
];
