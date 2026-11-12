// The Data Retention page (task 172; DBA Dash's Options > Data Retention, audit F407): every table of the repository
// with its size (its partitions, indexes and TOAST included), what the retention does to it, the time column a row
// delete compares, the table whose rows keep it ('same as'), its oldest partition or oldest row, the days that
// oldest row is from now (the actual retention), and what a purge with a given age would drop. The rules are read
// from pgvigil.purge() as installed (q_retention.go), so the page follows the function. The age itself is the -days
// of 'pgvigil purge', which the operator schedules; the page takes an age to preview and keeps it in this browser.
// Data: /api/retention?days=N.
import { get, Table, rowsOf } from './api';
import type { Ctx } from './router';
import { Col, el, errorBox, fmtBytes, fmtNum, grid } from './ui';

const lsGet = (k: string) => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* private window */ } };
const KEY = 'pgvigil.retentionDays';

interface Retention { days: number; purge_found: boolean; tables: Table | null }

// a date as a calendar day (a partition's month, an oldest row): the day only, no clock
const day = (v: unknown) => {
  if (v == null || v === '') return '';
  const d = new Date(String(v));
  return isNaN(d.getTime()) ? String(v) : d.toISOString().slice(0, 10);
};

// late: a table whose oldest row is older than its rule lets it keep (a month's partition up to 31 days more, a day's up
// to one): the purge is not scheduled, or runs with a longer age than the one previewed. Judged only where the server
// says the rule is the age alone (judged): a rule with conditions keeps older rows on purpose (a text a sample still
// names, the newest row of each instance).
function late(r: Record<string, unknown>, days: number): boolean {
  const a = Number(r.actual_days);
  if (r.judged !== true || r.actual_days == null || !Number.isFinite(a)) return false;
  if (r.retention === 'monthly partitions') return a > days + 31;
  return a > days + 1;
}

export async function retentionView(_ctx: Ctx): Promise<HTMLElement> {
  let days = Number(lsGet(KEY));
  if (!Number.isInteger(days) || days < 1 || days > 3650) days = 30;
  const sec = el('section', {}, el('h2', {}, 'Data retention'));
  const age = el('input', { type: 'number', min: '1', max: '3650', step: '1', value: String(days), id: 'ret-days', style: 'width:5rem' }) as HTMLInputElement;
  const apply = el('button', { type: 'button' }, 'Preview');
  const body = el('div');
  let seq = 0;
  async function draw() {
    const mine = ++seq;
    body.replaceChildren(el('p', { class: 'empty', role: 'status' }, 'Reading the repository...'));
    let d: Retention;
    try { d = await get<Retention>('retention', { days }); } catch (e) { if (mine === seq) body.replaceChildren(errorBox(e)); return; }
    if (mine !== seq) return;
    const rows = rowsOf(d.tables);
    const total = rows.reduce((a, r) => a + Number(r.size_bytes ?? 0), 0);
    const drop = rows.reduce((a, r) => a + Number(r.would_drop_bytes ?? 0), 0);
    const parts = rows.reduce((a, r) => a + Number(r.would_drop ?? 0), 0);
    const notPurged = rows.filter(r => r.note != null && String(r.note).startsWith('partitioned')).length;
    const lateN = rows.filter(r => late(r, days)).length;
    const cols: Col[] = [
      { key: 'schema_name', label: 'Schema' },
      { key: 'table_name', label: 'Table' },
      { key: 'size_bytes', label: 'Size', num: true, fmt: fmtBytes },
      { key: 'rows_estimate', label: 'Rows (estimate)', num: true, fmt: fmtNum },
      { key: 'retention', label: 'Retention', cls: (_v, r) => r.note != null && String(r.note).startsWith('partitioned') ? 'warn' : '' },
      { key: 'column_name', label: 'By column' },
      { key: 'same_as', label: 'Same as' },
      { key: 'partitions', label: 'Partitions', num: true, fmt: v => Number(v) > 0 ? fmtNum(v) : '' },
      { key: 'oldest_partition', label: 'Oldest partition', fmt: day },
      { key: 'oldest_row', label: 'Oldest row', fmt: day },
      { key: 'actual_days', label: 'Actual retention (days)', num: true, fmt: (v, r) => v == null ? '' : late(r, days) ? `${fmtNum(v)} (older than the age allows)` : fmtNum(v), cls: (_v, r) => late(r, days) ? 'warn' : '' },
      { key: 'would_drop', label: `Partitions a purge at ${days} days drops`, num: true, fmt: v => Number(v) > 0 ? fmtNum(v) : '' },
      { key: 'would_drop_bytes', label: 'Size it frees', num: true, fmt: v => Number(v) > 0 ? fmtBytes(v) : '' },
      { key: 'note', label: 'Note', wide: true },
    ];
    body.replaceChildren(
      el('p', { class: 'meta' }, `${fmtNum(rows.length)} tables, ${fmtBytes(total)} in all. `,
        parts > 0 ? `A purge at ${days} days would drop ${fmtNum(parts)} partition${parts === 1 ? '' : 's'} (${fmtBytes(drop)}) and the rows older than ${days} days.`
          : `A purge at ${days} days would drop no partition; the rows older than ${days} days go.`,
        lateN > 0 ? ` ${fmtNum(lateN)} table${lateN === 1 ? ' holds' : 's hold'} rows older than that age allows: the purge is not scheduled, or runs with a longer age.` : ''),
      ...(d.purge_found ? [] : [el('p', { class: 'error' }, 'pgvigil.purge() was not found in the repository: run pgvigil migrate.')]),
      ...(notPurged > 0 ? [el('p', { class: 'meta' }, `${notPurged} partitioned table${notPurged === 1 ? ' is' : 's are'} not named by the purge: marked in the Retention column and the Note.`)] : []),
      grid(rows, cols, 'No table in schema pgvigil.'));
  }
  const go = () => {
    const v = Math.trunc(Number(age.value));
    if (!Number.isFinite(v) || v < 1 || v > 3650) { age.setCustomValidity('1 to 3650 days'); age.reportValidity(); return; }
    age.setCustomValidity('');
    days = v; lsSet(KEY, String(v));
    void draw();
  };
  apply.addEventListener('click', go);
  age.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); go(); } });
  sec.append(
    el('p', { class: 'meta' }, 'The repository keeps every series until pgvigil purge removes it: a monthly partition once its whole month is older than the purge age (a daily one its day), the row-level tables their rows older than it, some under conditions of their own (the rules are read from the purge functions as installed). ',
      'The age is the -days of the scheduled pgvigil purge (deploy/pgvigil-purge.timer runs it with 30); this page does not change it.'),
    el('p', { class: 'meta' }, el('label', { for: 'ret-days' }, 'Purge age to preview (days) '), age, ' ', apply),
    body);
  await draw();
  return sec;
}
