// The Restore chain tab of a SQL Server instance (task 304): per database what a restore from the backups msdb lists
// would take and how far it reaches - the newest start set (a full, its differential, or a newer copy-only full), then the
// log backups in LSN order, with where each ran and every file. Data from /api/mssql/restore (the verdicts and steps the
// repository decided at the last read); the lead wires the tab (router.ts, main.ts). pgvigil writes no RESTORE statement
// and runs none: 'Copy the file list' copies the paths in restore order, nothing else. An LSN is shown as the text the API
// gives (up to 25 digits: never a JavaScript number, never compared here).
import { get, Row, rowsOf, Table } from './api';
import { hashParam, hrefWith } from './dbinfo';
import { Ctx } from './router';
import { Col, copyText, el, errorBox, fmtNum, fmtTime, grid, offControl, props } from './ui';

type Parts = 'databases' | 'steps' | 'files';

const stateWord: Record<string, string> = {
  whole: 'restorable', broken: 'broken', held: 'held: not judged yet', 'no full': 'no full backup', none: 'no backup read',
};
const stateCls = (v: unknown) => v === 'broken' || v === 'no full' ? 'warn' : v === 'whole' ? 'ok' : 'status none';
const roleWord: Record<string, string> = { full: 'full', copy_full: 'full (copy-only)', diff: 'differential', log: 'log' };

const platformLine: Record<string, string> = {
  rdssqlserver: 'Amazon RDS keeps this instance\'s automated backups itself (storage snapshots, restored to a point in time by RDS): the chain below is only of the native backups msdb lists, and a break here raises no finding.',
  azuresqlmi: 'Azure SQL Managed Instance backs up every database itself and restores to a point in time on the service: the chain below is only of what msdb lists, and a break here raises no finding.',
};

export async function mssqlRestore(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Restore chain'));
  try {
    const asked = hashParam('db');
    const d = await get<Record<Parts, Table | null>>('mssql/restore', { instance: ctx.instance, db: asked });
    const dbs = rowsOf(d.databases);
    const platform = String(dbs[0]?.platform ?? '');
    if (platformLine[platform]) sec.append(el('p', { class: 'meta' }, platformLine[platform]));
    sec.append(el('p', { class: 'meta' }, 'From each database\'s newest start set - the newest full backup, its differential, or a newer copy-only full (it restores like any full) - '
      + 'then every log backup in LSN order, from every monitored replica of its availability group, on the recovery fork of the newest backup. A break is a log no msdb read holds; '
      + 'a gap is held, never called a break, while a replica\'s last read is older than the log after it ("not yet read"), while a read did not list every log back to the gap '
      + '("not read whole"), and in a distributed availability group, whose other side is not read ("not judged"). pgvigil writes and runs no restore.'));
    if (!dbs.length) {
      sec.append(el('p', { class: 'empty' }, 'mssql_restore_chain has not stored a read of this server yet (hourly; a user in msdb with db_datareader).'));
      return sec;
    }
    const dbCols: Col[] = [
      { key: 'database_name', label: 'database', fmt: v => v === asked ? el('strong', { 'aria-current': 'true' }, String(v))
        : el('a', { href: hrefWith(ctx, 'mssqlrestore', { db: String(v ?? '') }) }, String(v ?? '')) },
      { key: 'state', label: 'chain', fmt: v => stateWord[String(v)] ?? String(v ?? ''), cls: stateCls },
      { key: 'verdict', label: 'verdict', wide: true },
      { key: 'restorable_to', label: 'restorable to', fmt: fmtTime },
      { key: 'steps', label: 'steps', num: true },
      { key: 'logs_since', label: 'log backups since the start', num: true, fmt: (v, r) => v == null ? '' : fmtNum(v) + (r.capped === true ? ` (${fmtNum(r.logs_sent)} listed)` : '') },
      { key: 'server_gaps', label: 'gaps on this server', num: true, fmt: (v, r) => v == null || r.ag_name ? '' : fmtNum(v) },
      { key: 'ag_name', label: 'availability group' },
      { key: 'read_at', label: 'read', fmt: fmtTime },
    ];
    sec.append(el('h3', {}, 'Databases'), el('div', { id: 'mssql-restore-databases' }, grid(dbs, dbCols, 'No database read.')));
    if (asked == null) return sec;
    const mine = dbs.find(r => r.database_name === asked);
    if (!mine) {
      sec.append(el('p', { class: 'meta' }, `The database ${asked} is not in this server's last read.`));
      return sec;
    }
    const all = rowsOf(d.steps), steps = all.filter(r => Number(r.step) > 0), verdict = all.find(r => Number(r.step) === 0);
    const files = rowsOf(d.files);
    const ofStep = new Map<string, Row[]>();
    for (const f of files) {
      const k = String(f.backup_set_uuid);
      if (!ofStep.has(k)) ofStep.set(k, []);
      ofStep.get(k)!.push(f);
    }
    // the paths in restore order, one mirror (a restore names one copy of a mirrored set)
    const list = steps.flatMap(s => (ofStep.get(String(s.backup_set_uuid)) ?? []).filter(f => Number(f.mirror) === 0).map(f => String(f.path)));
    const copy = el('button', { type: 'button' }, 'Copy the file list'), said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
    const capped = mine.capped === true;
    // a step to a virtual device (a third-party tool) has a device name, not a path: a list from it would mislead
    const vdev = steps.some(s => (ofStep.get(String(s.backup_set_uuid)) ?? []).some(f => f.device_kind === 'virtual device'));
    const off = capped ? `Not every log backup since the start set was read (${fmtNum(mine.logs_sent)} of ${fmtNum(mine.logs_since)}): a list from it would miss some.`
      : vdev ? 'A step of this chain went to a virtual device (a third-party backup tool): its device name is not a file path; that step is restored through the tool.' : '';
    if (!off) copy.addEventListener('click', () => { void copyText(list.join('\n')).then(ok => { said.textContent = ok ? ` ${fmtNum(list.length)} paths copied` : ' copy refused'; }); });
    sec.append(el('h3', { id: 'mssql-restore-steps' }, `The chain of ${asked}`),
      props([['verdict', String(verdict?.marks ?? mine.verdict ?? '')], ['restorable to', verdict?.restorable_to ? fmtTime(verdict.restorable_to) : '']]),
      el('p', { class: 'meta' }, copy, ' ', ...(off ? [offControl(copy, off)] : []), said));
    if (Number(mine.partial_sets) > 0) {
      sec.append(el('p', { class: 'meta' }, `msdb lists ${fmtNum(mine.partial_sets)} partial or file backups of ${asked}: no chain here reads them.`));
    }
    const stepCols: Col[] = [
      { key: 'step', label: 'step', num: true },
      { key: 'role', label: 'backup', fmt: v => roleWord[String(v)] ?? String(v ?? '') },
      { key: 'finish_at', label: 'finished', fmt: fmtTime },
      { key: 'from_instance', label: 'ran on' },
      { key: 'first_lsn', label: 'first LSN', fmt: v => el('code', {}, String(v ?? '')) },
      { key: 'last_lsn', label: 'last LSN', fmt: v => el('code', {}, String(v ?? '')) },
      { key: 'family_count', label: 'files', num: true, fmt: (v, r) => v == null ? '' : fmtNum(v) + (Number(r.mirror_count) > 1 ? ', mirrored' : '') },
      { key: 'user_name', label: 'taken by' },
      { key: 'marks', label: 'marks', wide: true },
    ];
    sec.append(el('div', { id: 'mssql-restore-steps-grid' }, grid(steps, stepCols, 'No step: see the verdict.')));
    const stepOf = new Map(steps.map(s => [String(s.backup_set_uuid), s]));
    const fileRows: Row[] = files.filter(f => stepOf.has(String(f.backup_set_uuid))).map((f): Row => ({ ...f, step: stepOf.get(String(f.backup_set_uuid))!.step }))
      .sort((a, b) => Number(a.step) - Number(b.step) || Number(a.mirror) - Number(b.mirror) || Number(a.family) - Number(b.family));
    const pathCell = (v: unknown) => {
      const p = String(v ?? ''), s2 = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `Copy the path ${p}` }, 'Copy');
      b.addEventListener('click', () => { void copyText(p).then(ok => { s2.textContent = ok ? ' copied' : ' copy refused'; }); });
      return el('span', { 'data-full': p, style: 'white-space:nowrap' }, el('code', { style: 'font-size:12px' }, p), ' ', b, s2);
    };
    sec.append(el('h3', {}, `Files of the chain of ${asked}`),
      el('div', { id: 'mssql-restore-files' }, grid(fileRows, [
        { key: 'step', label: 'step', num: true }, { key: 'family', label: 'file', num: true }, { key: 'mirror', label: 'mirror', num: true },
        { key: 'device_kind', label: 'device' }, { key: 'path', label: 'path', fmt: pathCell }, { key: 'from_instance', label: 'ran on' },
      ], 'No file stored for these steps.')));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
