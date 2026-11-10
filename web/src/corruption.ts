// The Corruption views (task 34): per instance the three settings that decide whether damage is seen (data
// checksums, ignore_checksum_failure, zero_damaged_pages), the server log's corruption events of 30 days, amcheck's
// newest run per database and check (an opt-in collection: off until the instance's schedules name it) with its last
// runs, and the corruption findings; and the fleet root, one row per instance. corruptionCell is the Summary column's
// reading of a fleet row. Each view reads /api/corruption itself; the routes and the tree entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { badge, Col, el, fmtTime, grid, tile } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const n = (v: unknown) => Number(v ?? 0);
const onBad = (v: unknown) => v === 'on' ? badge('on', 'crit') : String(v ?? '');
const checksums = (v: unknown, r: Row) => v == null ? '' : v === 'off' ? badge('off', r.platform === 'aurora' ? '' : 'warn') : String(v);
const statusBadge = (v: unknown) => badge(String(v ?? ''), v === 'corrupt' ? 'crit' : v === 'error' || v === 'partial' ? 'warn' : '');

export type CorruptionLevel = 0 | 1 | 2;   // ok, warning, critical (the Summary grid's levels)

// corruptionCell: critical on a corruption event in 24 h, amcheck damage, ignore_checksum_failure or
// zero_damaged_pages on; warning when checksums are off (not Aurora: its storage checks its own pages);
// an instance with no read is 'none'.
export function corruptionCell(r: Row): { level: CorruptionLevel; text: string; detail: string[]; none?: boolean } {
  if (r.snapshot_at == null) return { level: 0, text: 'no sample', detail: [], none: true };
  const d: string[] = [];
  let level: CorruptionLevel = 0;
  if (n(r.events_24h) > 0) { level = 2; d.push(`${r.events_24h} corruption event(s) in the log in 24 h`); }
  if (n(r.amcheck_corrupt) > 0) { level = 2; d.push(`amcheck found ${r.amcheck_corrupt} damaged relation(s)`); }
  if (r.ignore_checksum_failure === 'on') { level = 2; d.push('ignore_checksum_failure is on'); }
  if (r.zero_damaged_pages === 'on') { level = 2; d.push('zero_damaged_pages is on'); }
  if (r.data_checksums === 'off' && r.platform !== 'aurora') { level = Math.max(level, 1) as CorruptionLevel; d.push('data checksums are off'); }
  const text = level === 2 ? (n(r.events_24h) > 0 ? `${r.events_24h} event(s)` : 'damage') : level === 1 ? 'no checksums' : 'ok';
  return { level, text, detail: d };
}

const fleetCols = (instLink?: (name: string, id: unknown) => Node): Col[] => [
  { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
  { key: 'platform' },
  { key: 'data_checksums', label: 'checksums', fmt: checksums },
  { key: 'ignore_checksum_failure', label: 'ignore_checksum_failure', fmt: onBad },
  { key: 'zero_damaged_pages', label: 'zero_damaged_pages', fmt: onBad },
  { key: 'events_24h', label: 'events 24 h', num: true, fmt: v => n(v) > 0 ? badge(String(v), 'crit') : '' },
  { key: 'events_7d', label: 'events 7 d', num: true, fmt: v => n(v) > 0 ? String(v) : '' },
  { key: 'last_event', label: 'last event', fmt: v => v == null ? '' : fmtTime(v) },
  { key: 'amcheck_last_run', label: 'amcheck run', fmt: v => v == null ? 'not scheduled' : fmtTime(v) },
  { key: 'amcheck_checked', label: 'relations checked', num: true },
  { key: 'amcheck_corrupt', label: 'damaged', num: true, fmt: v => n(v) > 0 ? badge(String(v), 'crit') : '' },
];

// corruptionFleetView: the fleet root. keep narrows it to a tag folder; instLink links an instance to its tab.
export async function corruptionFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const d = await get<{ fleet: Table | null }>('corruption', {});
  let rows = rowsOf(d.fleet);
  if (keep) rows = rows.filter(keep);
  const hit = rows.filter(r => corruptionCell(r).level === 2).length;
  const off = rows.filter(r => r.data_checksums === 'off' && r.platform !== 'aurora').length;
  return el('section', {}, el('h2', {}, 'Corruption'),
    el('p', { class: 'meta' }, `${rows.length} instance(s): ${hit} with damage reported or a setting that hides it, ${off} without data checksums.`),
    grid(rows, fleetCols(instLink), 'No instance read yet.'));
}

interface CorrInstance { summary: Table | null; findings: Table | null; events: Table | null; amcheck: Table | null; runs: Table | null }

const problems = (v: unknown) => {
  const list = Array.isArray(v) ? v as { relation?: string; message?: string }[] : [];
  if (!list.length) return '';
  return list.slice(0, 3).map(p => `${p.relation ?? '?'}: ${p.message ?? ''}`).join('; ') + (list.length > 3 ? `; +${list.length - 3} more` : '');
};

// corruptionView: one instance.
export async function corruptionView(instance: number): Promise<HTMLElement> {
  const d = await get<CorrInstance>('corruption', { instance });
  const st = rowsOf(d.summary)[0];
  const sec = el('section', {}, el('h2', {}, 'Corruption'));
  if (!st || st.snapshot_at == null) {
    sec.append(el('p', { class: 'empty' }, 'No instance read yet.'));
    return sec;
  }
  const cell = corruptionCell(st);
  sec.append(el('div', { class: 'tiles' },
    tile('data checksums', String(st.data_checksums ?? '?'), st.data_checksums === 'off' && st.platform !== 'aurora' ? 'warn' : ''),
    tile('ignore_checksum_failure', String(st.ignore_checksum_failure ?? '?'), st.ignore_checksum_failure === 'on' ? 'crit' : ''),
    tile('zero_damaged_pages', String(st.zero_damaged_pages ?? '?'), st.zero_damaged_pages === 'on' ? 'crit' : ''),
    tile('log events 24 h', String(st.events_24h ?? 0), n(st.events_24h) > 0 ? 'crit' : ''),
    tile('log events 7 d', String(st.events_7d ?? 0), n(st.events_7d) > 0 ? 'warn' : ''),
    tile('amcheck damaged', st.amcheck_last_run == null ? 'not run' : String(st.amcheck_corrupt ?? 0), n(st.amcheck_corrupt) > 0 ? 'crit' : '')));
  if (cell.detail.length) sec.append(el('p', { class: 'meta' }, cell.detail.join('; ') + '.'));
  const f = rowsOf(d.findings);
  if (f.length) sec.append(el('h3', {}, 'Findings'), grid(f, [{ key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'check' },
    { key: 'value' }, { key: 'suggested', wide: true }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime }]));

  sec.append(el('h3', {}, 'Server log events (30 days)'),
    el('p', { class: 'meta' }, 'Messages only damage raises: a failed page checksum, an invalid page header, a short read, a missing relation or status file, a missing TOAST chunk, a transaction id from before the table\'s freeze horizon. Read from the server log where pgvigil reads it (the logs or serverlog collection).'),
    grid(rowsOf(d.events), [
      { key: 'at', label: 'time', fmt: fmtTime }, { key: 'class', fmt: v => badge(String(v ?? ''), 'crit') },
      { key: 'message', wide: true }, { key: 'relation_path', label: 'file' }, { key: 'datname', label: 'database' },
      { key: 'usename', label: 'user' }, { key: 'statement', wide: true }, { key: 'detail', wide: true },
    ], 'No corruption message in the server log in 30 days (or the log is not read on this instance).'));

  sec.append(el('h3', {}, 'amcheck'),
    el('p', { class: 'meta' }, 'bt_index_check on every B-tree index and verify_heapam (PostgreSQL 14+) on every table, per database where the amcheck extension is installed and the monitoring login was granted EXECUTE. It reads every page it checks, so it runs only when the instance\'s schedules name amcheck.'),
    grid(rowsOf(d.amcheck), [
      { key: 'datname', label: 'database' }, { key: 'check_name', label: 'check' }, { key: 'status', fmt: statusBadge },
      { key: 'checked', num: true, fmt: (v, r) => `${v ?? 0} / ${r.total ?? 0}` }, { key: 'corrupt', label: 'damaged', num: true },
      { key: 'errors', label: 'not finished', num: true }, { key: 'problems', label: 'first messages', wide: true, fmt: problems },
      { key: 'note', wide: true }, { key: 'snapshot_at', label: 'run', fmt: fmtTime },
    ], 'amcheck has not run: name it under the instance\'s schedules (for example amcheck: 24h) to turn it on.'));
  const runs = rowsOf(d.runs);
  if (runs.length) sec.append(el('h3', {}, 'amcheck runs'), grid(runs, [
    { key: 'snapshot_at', label: 'run', fmt: fmtTime }, { key: 'datname', label: 'database' }, { key: 'check_name', label: 'check' },
    { key: 'status', fmt: statusBadge }, { key: 'checked', num: true }, { key: 'total', num: true },
    { key: 'corrupt', label: 'damaged', num: true }, { key: 'errors', label: 'not finished', num: true },
    { key: 'duration_ms', label: 'ms', num: true }, { key: 'note', wide: true },
  ]));
  return sec;
}
