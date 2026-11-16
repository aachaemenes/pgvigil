// Admin > Backup ages (task 405, PerformanceMonitor 3.13.0's Changed 46): the full backup hours and log backup minutes a
// SQL Server database is judged by, set for a tag or for one database (an instance's own ages stay in pgvigil.yaml's
// mssql_thresholds). The narrowest wins: a database row, then the instance's yaml, then its tags (the strictest), then
// the default (168 h, 60 min); 0 = not judged. Data from /api/mssql/protection; writes ride the UI login and the
// actions door's audit login; off, every control says why.
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { el, errorBox, fmtTime, grid, offControl } from './ui';

export async function adminProtectionView(_ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Backup ages (SQL Server)'));
  type Data = { writable?: boolean; reason?: string; overrides: Table | null; log: Table | null };
  let d: Data;
  try { d = await get<Data>('mssql/protection'); } catch (e) { sec.append(errorBox(e)); return sec; }
  const off = d.writable ? null : (d.reason ?? 'not writable here');
  sec.append(el('p', { class: 'meta' }, 'A database is judged late when its newest full backup is older than its full backup hours, or its newest log backup older than its log backup minutes. Set them here for a tag or for one database; an instance\'s own ages are set in pgvigil.yaml (mssql_thresholds). The narrowest wins: a database row, then the instance\'s pgvigil.yaml, then its tags (the strictest when two disagree), then the default of 168 hours and 60 minutes. 0 = not judged.'),
    ...(off ? [el('p', { class: 'meta' }, `Edits are off here: ${off}`)] : []));
  const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const send = async (body: Record<string, unknown>) => {
    try {
      const r = await post<{ outcome: string; detail: string }>('mssql/protection', body);
      said.textContent = `${r.outcome}: ${r.detail}`;
      window.dispatchEvent(new HashChangeEvent('hashchange'));
    } catch (e) { said.textContent = 'Not written: ' + (e instanceof Error ? e.message : String(e)); }
  };
  const scope = el('select', { 'aria-label': 'Scope' }, el('option', { value: 'tag' }, 'a tag'), el('option', { value: 'database' }, 'one database')) as HTMLSelectElement;
  const tag = el('input', { type: 'text', 'aria-label': 'Tag', placeholder: 'tag (key:value or value)', maxlength: '200' }) as HTMLInputElement;
  const inst = el('select', { 'aria-label': 'Instance' }) as HTMLSelectElement;
  const db = el('input', { type: 'text', 'aria-label': 'Database', placeholder: 'database', maxlength: '128' }) as HTMLInputElement;
  const full = el('input', { type: 'number', min: '0', step: 'any', 'aria-label': 'Full backup hours', placeholder: 'full backup hours' }) as HTMLInputElement;
  const logm = el('input', { type: 'number', min: '0', step: 'any', 'aria-label': 'Log backup minutes', placeholder: 'log backup minutes' }) as HTMLInputElement;
  const note = el('input', { type: 'text', 'aria-label': 'Note', placeholder: 'note (optional)', maxlength: '500' }) as HTMLInputElement;
  const showScope = () => { tag.hidden = scope.value !== 'tag'; inst.hidden = scope.value !== 'database'; db.hidden = scope.value !== 'database'; };
  scope.addEventListener('change', showScope);
  try {
    const all = rowsOf(await get<Table>('instances')).filter(r => r.engine === 'sqlserver');
    inst.replaceChildren(...all.map(r => el('option', { value: String(r.instance_id) }, String(r.name))));
  } catch { /* the instance list is needed for a database row only */ }
  showScope();
  const num = (i: HTMLInputElement): number | null => i.value.trim() === '' ? null : Number(i.value);
  const save = el('button', { type: 'button' }, 'Save row') as HTMLButtonElement;
  save.addEventListener('click', () => {
    if (num(full) === null && num(logm) === null) { said.textContent = 'Set the full backup hours, the log backup minutes, or both.'; return; }
    void send({ op: 'add', scope: scope.value, tag: tag.value.trim(), instance_id: Number(inst.value || 0), database_name: db.value.trim(),
      full_backup_hours: num(full), log_backup_minutes: num(logm), note: note.value.trim() });
  });
  const saveNote = offControl(save, off);
  sec.append(el('h3', {}, 'Set an age'),
    el('div', { class: 'toolbar', style: 'flex-wrap:wrap;gap:.5rem' }, scope, tag, inst, db, full, logm, note, save, saveNote), said);
  const endCell = (_v: unknown, r: Row) => {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `End row ${String(r.override_id)}` }, 'End') as HTMLButtonElement;
    b.addEventListener('click', () => { void send({ op: 'end', override_id: Number(r.override_id) }); });
    const short = off ? el('span', { class: 'off-reason' }, 'off here: the line above says why') : undefined;
    return el('span', {}, b, ' ', offControl(b, off, short));
  };
  const age = (v: unknown, unit: string) => v == null ? 'not set' : Number(v) === 0 ? 'not judged (0)' : `${String(v)} ${unit}`;
  sec.append(el('h3', {}, 'Rows made here'), grid(rowsOf(d.overrides), [
    { key: 'scope', label: 'for', fmt: (_v, r) => r.scope === 'tag' ? `tag ${String(r.tag)}` : `${String(r.instance_name)}: ${String(r.database_name)}` },
    { key: 'full_backup_hours', label: 'full backup', fmt: v => age(v, 'hours') },
    { key: 'log_backup_minutes', label: 'log backup', fmt: v => age(v, 'minutes') },
    { key: 'note' }, { key: 'created_by', label: 'by' }, { key: 'created_at', label: 'at', fmt: fmtTime }, { key: '_end', label: 'end', fmt: endCell },
  ], 'No row: every database is judged by its instance\'s pgvigil.yaml or the defaults.'));
  sec.append(el('h3', {}, 'The log'), grid(rowsOf(d.log), [
    { key: 'at', fmt: fmtTime }, { key: 'ui_user', label: 'by' }, { key: 'op' }, { key: 'outcome' }, { key: 'detail' },
  ], 'No attempt yet.'));
  return sec;
}
