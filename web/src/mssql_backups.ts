// The Backups tab of a SQL Server instance (phase 3 wave G, task 98): per database the last full, differential and
// log backup, where it ran, and its age AT THE READ against the threshold of its type. A database in an
// availability group shows the newest backup any monitored replica took. Data from /api/mssql/backups; the lead
// wires the tab (router.ts, main.ts).
//   mssqlBackups               the tab; opened with a database in its address (#/mssqlbackups?i=<id>&db=<name>, the
//                              fleet page's database link) that database's row is first and marked, and its Last backup
//                              panel is open under the grid (DBA Dash's drill from a database: every set kept, then the
//                              Files of each, every path whole with a copy button; task 301, /api/mssql/backup_files)
//   mssqlBackupsFleetSection   the SQL Server sections of the fleet's Backups page, DBA Dash's root Backups: its Summary
//                              grid (one row per instance) and its Detail grid (one row per database, Problems or All),
//                              with the backup findings of every instance in view between them. The same API with no
//                              instance. main.ts appends it below PostgreSQL's sections (the lead's wiring).
import { get, Row, rowsOf, Table } from './api';
import { hashParam, hrefWith } from './dbinfo';
import { fleet, tagsOf } from './fleet';
import { Ctx } from './router';
import { mssqlFindingCols, words } from './mssql_hadr';
import { badge, Col, copyText, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, offControl, props, tile } from './ui';

type Parts = 'databases' | 'findings' | 'limits';
type FileParts = 'sets' | 'files' | 'writers' | 'roots' | 'findings' | 'read';

// a status is its word and its colour, never the colour alone
// the word's colour: never red, late amber (red for a full backup), ok green, not judged grey; a date and an age take their status's colour
const statusCls = (v: unknown) => v === 'never' ? 'crit' : v === 'late' ? 'warn' : v === 'ok' ? 'ok' : v === 'not judged' ? 'status none' : '';
const critIfFull = (v: unknown) => v === 'late' ? 'crit' : statusCls(v);
const follows = (status: string, full = false) => (v: unknown, r: Row) => v == null || v === '' ? '' : full ? critIfFull(r[status]) : statusCls(r[status]);
const hours = (v: unknown) => v == null ? '' : Number(v) >= 48 ? fmtNum(Math.round(Number(v) / 2.4) / 10) + ' d' : fmtNum(Math.round(Number(v) * 10) / 10) + ' h';
const minutes = (v: unknown) => v == null ? '' : fmtSecs(Number(v) * 60);
// when: the time, and on an availability group the instance whose msdb holds the backup
const when = (from: string) => (v: unknown, r: Row) => !v ? '' : fmtTime(v) + (r.ag_name && r[from] ? ` (on ${String(r[from])})` : '');

const typeWord = { full: 'full', diff: 'differential', log: 'log' } as const;
const yesNo = (v: unknown) => v == null ? '' : v === true ? 'yes' : 'no';
// a flag of DBA Dash's Detail per type ('full checksum', 'differential checksum', 'log checksum')
const flagCols = (k: string, words: string): Col[] => (['full', 'diff', 'log'] as const).map(t => ({ key: `${t}_${k}`, label: `${typeWord[t]} ${words}`, fmt: yesNo }));
// a 'to' cell: one line, cut with an ellipsis, the whole text in its title (a copy or an export takes all of it); the full's
// copy-only and snapshot marks after it - of the stored set shown there (0140's full_to_copy_only / full_to_snapshot),
// never mssql_backup_state's, which the hourly backup read may not have caught up with (F2)
const toCell = (v: unknown, full?: Row) => {
  const marks = full ? (full.full_to_copy_only === true ? ', copy-only' : '') + (full.full_to_snapshot === true ? ', snapshot' : '') : '';
  if (v == null || v === '') return marks.slice(2);
  const t = String(v) + marks;
  return el('span', { class: 'mono', title: t, style: 'display:block;max-width:24rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px' }, t);
};

const cols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'recovery_model', label: 'recovery model', fmt: words },
  { key: 'ag_name', label: 'availability group', fmt: (v, r) => !v ? '' : `${String(v)} (${String(r.replicas_monitored ?? 0)} of ${String(r.replicas_total ?? 0)} replicas monitored)`,
    cls: (_, r) => r.replicas_unseen === true ? 'warn' : '' },
  { key: 'not_judged', label: 'judged', fmt: v => v ? `no: ${String(v)}` : 'yes' },
  { key: 'full_status', label: 'full', cls: critIfFull },
  { key: 'full_at', label: 'last full', fmt: when('full_from'), cls: follows('full_status', true) },
  { key: 'full_age_hours', label: 'full age', num: true, fmt: hours, cls: follows('full_status', true) },
  { key: 'diff_status', label: 'differential', cls: statusCls },
  { key: 'diff_at', label: 'last differential', fmt: when('diff_from'), cls: follows('diff_status') },
  { key: 'log_status', label: 'log', cls: statusCls },
  { key: 'log_at', label: 'last log', fmt: when('log_from'), cls: follows('log_status') },
  { key: 'log_age_minutes', label: 'log age', num: true, fmt: minutes, cls: follows('log_status') },
  { key: 'nul_at', label: 'backup to NUL', fmt: (v, r) => !v ? '' : `${String(r.nul_type ?? '')} ${fmtTime(v)}`, cls: v => v ? 'warn' : '' },
  // DBA Dash's Is Full / Diff / Log Damaged (Detail 15-17): of the newest set of the type (task 301's read)
  ...(['full', 'diff', 'log'] as const).map((t): Col => ({ key: `${t}_damaged`, label: `${typeWord[t]} damaged`, fmt: yesNo, cls: v => v === true ? 'crit' : '' })),
  // this server's own record of the full backup shown; blank where that backup ran on another replica (open it there)
  { key: 'full_bytes', label: 'full size', num: true, fmt: fmtBytes },
  { key: 'full_compressed_bytes', label: 'compressed', num: true, fmt: fmtBytes },
  { key: 'full_duration_s', label: 'full took', num: true, fmt: fmtSecs },
  // DBA Dash's Detail 46-60, in its order: checksum, compressed, password protected, encrypted, compression algorithm
  ...flagCols('checksum', 'checksum'), ...flagCols('compressed', 'compressed'), ...flagCols('password', 'password protected'),
  ...flagCols('encrypted', 'encrypted'),
  ...(['full', 'diff', 'log'] as const).map((t): Col => ({ key: `${t}_algorithm`, label: `${typeWord[t]} compression algorithm` })),
  // pgvigil's own, after DBA Dash's columns: where the newest set of each type went (the folder or a URL's container,
  // the files of a striped set, a mirror), the whole paths in the database's Last backup panel
  ...(['full', 'diff', 'log'] as const).map((t): Col => ({ key: `${t}_to`, label: `${typeWord[t]} to`, fmt: (v, r) => toCell(v, t === 'full' ? r : undefined) })),
];

// ---- where the backups went (task 301): DBA Dash's Last Backup grid and pgvigil's own after it -------------------

// the platforms that keep their backups themselves, in words (D5, D6, F12)
const platformLine: Record<string, string> = {
  azuresqldb: 'Azure SQL Database keeps its backups itself (point-in-time restore 1 to 35 days, 7 by default, Basic 1 to 7); they cannot be downloaded '
    + 'and no path exists; sys.dm_database_backups lists their times per database and returns nothing on Hyperscale - not read by pgvigil.',
  rdssqlserver: 'Amazon RDS: its automated backups are storage snapshots RDS keeps for the instance\'s retention period (not read by pgvigil: the SQL Server '
    + 'collector has no AWS door); a native backup goes to S3 through msdb.dbo.rds_backup_database and is listed in msdb as below; log backups cannot be '
    + 'taken by the user. Whether a backup sits on the database\'s own volume is not judged here.',
  azuresqlmi: 'Azure SQL Managed Instance backs up every database itself (retention 1 to 35 days, set on the service); msdb lists what it records (the '
    + 'system databases\' backups are not recorded there). Whether a backup sits on the database\'s own volume is not judged here.',
};

// DBA Dash's Last Backup grid (LastBackup_Get, DisplayIndex 0-25) in its order, then pgvigil's own columns
const lastBackupCols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'recovery_model', label: 'recovery model', fmt: words },
  { key: 'backup_type', label: 'type', fmt: (v, r) => (typeWord[String(v) as keyof typeof typeWord] ?? String(v ?? '')) + (r.shown === true ? '' : ' (the last that is not copy-only)') },
  { key: 'start_at', label: 'start date', fmt: fmtTime },
  { key: 'finish_at', label: 'finish date', fmt: fmtTime },
  { key: 'duration_s', label: 'duration', num: true, fmt: fmtSecs },
  { key: 'size_bytes', label: 'backup size', num: true, fmt: fmtBytes },
  { key: 'mb_s', label: 'backup MB/s', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'compressed_bytes', label: 'backup size (compressed)', num: true, fmt: fmtBytes },
  { key: 'saving_pct', label: 'compression saving %', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'write_mb_s', label: 'backup write MB/s', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'is_partner', label: 'is partner backup', fmt: yesNo },
  { key: 'partner', label: 'partner' },
  { key: 'is_damaged', label: 'is damaged', fmt: yesNo, cls: v => v === true ? 'crit' : '' },
  { key: 'has_checksums', label: 'checksum', fmt: yesNo },
  { key: 'is_compressed', label: 'is compressed', fmt: yesNo },
  { key: 'is_password_protected', label: 'password protected', fmt: yesNo },
  { key: 'is_encrypted', label: 'encrypted', fmt: yesNo },
  { key: 'is_snapshot', label: 'snapshot backup', fmt: yesNo },
  { key: 'has_bulk_logged_data', label: 'has bulk logged data', fmt: yesNo },
  { key: 'is_readonly', label: 'readonly', fmt: yesNo },
  { key: 'is_force_offline', label: 'force offline', fmt: yesNo },
  { key: 'is_single_user', label: 'single user', fmt: yesNo },
  { key: 'key_algorithm', label: 'key algorithm' },
  { key: 'encryptor_type', label: 'encryptor type' },
  { key: 'compression_algorithm', label: 'compression algorithm' },
  // pgvigil's own (DBA Dash reads no media family: no path, device, stripe, mirror, login, name or software)
  { key: 'folder', label: 'to', fmt: v => toCell(v) },
  { key: 'family_count', label: 'files', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'mirror_count', label: 'mirrors', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'device_kind', label: 'device' },
  { key: 'user_name', label: 'taken by' },
  { key: 'machine_name', label: 'machine' },
  { key: 'set_name', label: 'set name' },
  { key: 'description', label: 'description', wide: true },
  { key: 'software_name', label: 'software' },
  { key: 'is_copy_only', label: 'copy-only', fmt: yesNo },
  { key: 'has_incomplete_metadata', label: 'incomplete metadata', fmt: yesNo },
  { key: 'diff_base', label: 'base', fmt: (v, r) => r.backup_type !== 'diff' ? '' : v == null ? 'a full not kept here' : String(v) },
  { key: 'media_password', label: 'media password', fmt: yesNo },
  { key: 'same_volume', label: 'on the database\'s volume', wide: true, fmt: v => v == null ? '' : String(v).replace(/^yes: /, 'yes - '),
    cls: v => String(v ?? '').startsWith('yes') ? 'warn' : String(v ?? '').startsWith('not judged') ? 'status none' : '' },
];

// a path whole, with its own Copy button; data-full makes the export and the grid's Copy all take the path alone (ui.ts cellText)
const pathCell = (v: unknown) => {
  if (v == null || v === '') return '';
  const path = String(v), said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const b = el('button', { type: 'button', class: 'link', 'aria-label': `Copy the path ${path}` }, 'Copy');
  b.addEventListener('click', () => { void copyText(path).then(ok => { said.textContent = ok ? ' copied' : ' copy refused'; }); });
  return el('span', { 'data-full': path, style: 'white-space:nowrap' }, el('code', { style: 'font-size:12px' }, path), ' ', b, said);
};
const fileCols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'backup_type', label: 'type', fmt: (v, r) => (typeWord[String(v) as keyof typeof typeWord] ?? String(v ?? '')) + (r.is_copy_only === true ? ', copy-only' : '') },
  { key: 'finish_at', label: 'finished', fmt: fmtTime },
  { key: 'family', label: 'file', fmt: (v, r) => `${String(v ?? '')} of ${String(r.family_count ?? '?')}` },
  { key: 'mirror', label: 'mirror', num: true },
  { key: 'device_kind', label: 'device' },
  { key: 'path', label: 'path', fmt: pathCell },
  { key: 'root', label: 'destination' },
];
const writerCols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'root', label: 'destination' },
  { key: 'device_kind', label: 'device' },
  { key: 'sets', label: 'log backups (7 days)', num: true },
  { key: 'last_at', label: 'last', fmt: fmtTime },
  { key: 'users', label: 'taken by' },
  { key: 'note', label: 'note' },
];
const rootCols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'backup_type', label: 'type', fmt: v => typeWord[String(v) as keyof typeof typeWord] ?? String(v ?? '') },
  { key: 'root', label: 'destination' },
  { key: 'first_seen', label: 'first seen', fmt: fmtTime },
  { key: 'last_seen', label: 'last seen', fmt: fmtTime },
];

export async function mssqlBackups(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Backups'));
  try {
    const asked = hashParam('db');
    // the second read is task 301's (a store without it, or an older server, still draws the rest)
    const [d, loc] = await Promise.all([
      get<Record<Parts, Table | null>>('mssql/backups', { instance: ctx.instance }),
      get<Record<FileParts, Table | null>>('mssql/backup_files', { instance: ctx.instance }).catch((e: unknown) => e),
    ]);
    const locErr = loc instanceof Error ? loc : null, lp = locErr ? null : loc as Record<FileParts, Table | null>;
    let dbs = rowsOf(d.databases);
    const lim = rowsOf(d.limits)[0];
    const platform = String((await fleet()).instances.find(r => Number(r.instance_id) === Number(ctx.instance))?.platform ?? '');
    if (platformLine[platform]) sec.append(el('p', { class: 'meta', id: 'mssql-backups-platform' }, platformLine[platform]));
    // a database named in the address (the fleet page's link): its row first, and marked in words
    const picked = asked == null ? undefined : dbs.find(r => r.database_name === asked);
    if (picked) dbs = [picked, ...dbs.filter(r => r !== picked)];
    if (lim?.status && lim.status !== 'ok') sec.append(el('p', { class: 'meta' }, badge(String(lim.status), 'warn'),
      ` mssql_backups: ${String(lim.note ?? '')}${lim.snapshot_at ? `. What follows is its last read (${fmtTime(lim.snapshot_at)}).` : ''}`));
    if (!lim || !lim.snapshot_at) {
      if (!lim?.status) sec.append(el('p', { class: 'empty' }, 'mssql_backups has not run on this server yet (hourly). It needs a user in msdb with db_datareader.'));
      return sec;
    }
    const count = (f: (r: Row) => boolean) => dbs.filter(f).length;
    const noFull = count(r => r.full_status === 'never' || r.full_status === 'late');
    const noLog = count(r => r.log_status === 'never' || r.log_status === 'late');
    sec.append(el('div', { class: 'tiles' },
      tile('databases', fmtNum(dbs.length)),
      tile('without a recent full backup', fmtNum(noFull), noFull ? 'crit' : ''),
      tile('without a recent log backup', fmtNum(noLog), noLog ? 'warn' : ''),
      tile('not judged', fmtNum(count(r => r.not_judged != null))),
    ));
    const rd = lp ? rowsOf(lp.read)[0] : undefined;
    sec.append(props([
      ['read', `${fmtTime(lim.snapshot_at)} (hourly); every age is the age at that read`],
      ['thresholds', `full ${hours(lim.full_backup_hours)}, differential ${Number(lim.diff_backup_hours) > 0 ? hours(lim.diff_backup_hours) : 'not judged'}, `
        + `log ${String(lim.log_backup_minutes)} min; a database younger than ${String(lim.new_database_hours)} h is not judged`],
      ['not judged by name', String(lim.backup_exclude || 'none')],
      ['msdb\'s backup history reaches back to', lim.history_from ? fmtTime(lim.history_from) : 'msdb holds no backup history'],
      ['where the backups went', locErr ? `not read: ${locErr.message}` : !rd?.snapshot_at ? (rd?.status ? `mssql_backup_files ${String(rd.status)}: ${String(rd.note ?? '')}`
        : 'mssql_backup_files has not run on this server yet (hourly; a user in msdb with db_datareader)')
        : `${fmtTime(rd.snapshot_at)} (mssql_backup_files, hourly${rd.status && rd.status !== 'ok' ? `; its last run ${String(rd.status)}: ${String(rd.note ?? '')}` : ''})`],
    ]));
    const findings = [...rowsOf(d.findings), ...(lp ? rowsOf(lp.findings) : [])];
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, mssqlFindingCols));
    sec.append(el('h3', {}, 'Databases'));
    if (asked != null) sec.append(el('p', { class: 'meta', id: 'mssql-backups-picked' }, picked
      ? `Opened for the database ${asked}: its row is the first below.`
      : `The database ${asked} is not in this server's last read.`));
    // the database opens its Last backup panel (DBA Dash's drill from the Detail grid's Database link)
    const nameCell = (v: unknown) => v === asked ? el('strong', { 'aria-current': 'true' }, String(v))
      : el('a', { href: hrefWith(ctx, 'mssqlbackups', { db: String(v ?? '') }), title: 'Its last backups and every file' }, String(v ?? ''));
    sec.append(
      el('p', { class: 'meta' }, 'msdb is each server\'s own record. A database in an availability group shows the newest backup of each type that any '
        + 'monitored replica took, with the instance it ran on (its size and how long it took are on that instance\'s tab); a group with a replica that is not monitored is not alarmed on. '
        + 'A backup to the NUL device is no backup and is listed apart. Full to, differential to, log to: the folder (a URL\'s container) of the newest backup of the type, '
        + 'on whichever monitored replica it ran, and its file count when striped; open a database for every file.'),
      grid(dbs, [{ ...cols[0], fmt: nameCell }, ...cols.slice(1)], 'The last read listed no database.'));
    if (lp) sec.append(...locationParts(lp, asked ?? undefined, picked != null));
    else if (locErr) sec.append(errorBox(locErr));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// locationParts: the Last backup panel of the database asked for, then every file of the server's sets (the export's
// Files sheet), the log writers and the destinations seen.
function locationParts(lp: Record<FileParts, Table | null>, asked: string | undefined, listed: boolean): HTMLElement[] {
  const out: HTMLElement[] = [];
  const sets = rowsOf(lp.sets), files = rowsOf(lp.files), writers = rowsOf(lp.writers), roots = rowsOf(lp.roots);
  if (asked != null && listed) {
    const mine = sets.filter(r => r.database_name === asked), myFiles = files.filter(r => r.database_name === asked);
    const all = el('button', { type: 'button' }, 'Copy every path'), said = el('span', { role: 'status', class: 'meta' });
    all.addEventListener('click', () => { void copyText(myFiles.map(r => String(r.path ?? '')).join('\n')).then(ok => { said.textContent = ok ? ` ${fmtNum(myFiles.length)} paths copied` : ' not copied: the browser refused the clipboard'; }); });
    out.push(el('h3', { id: 'mssql-backups-last' }, `Last backup: ${asked}`),
      el('p', { class: 'meta' }, 'DBA Dash\'s Last Backup grid in its order, then pgvigil\'s own columns. One row per type, the newest whatever its age; '
        + 'beside a copy-only full the newest full that is not copy-only (destinations and the volume are judged on it). Base: the full the differential restores on. '
        + 'A share is named as written (\\\\name, \\\\name.domain and \\\\10.1.2.3 are three destinations to pgvigil, and a DFS namespace hides its target); '
        + 'a URL\'s key, SAS or identity is never in msdb.'),
      el('div', { id: 'mssql-backups-last-grid' }, grid(mine, lastBackupCols, 'mssql_backup_files has stored no backup of this database.')),
      el('h3', {}, `Files: ${asked}`), el('p', { class: 'meta' }, all, said),
      el('div', { id: 'mssql-backups-last-files' }, grid(myFiles, fileCols, 'No file stored for this database.')));
    const myWriters = writers.filter(r => r.database_name === asked);
    if (myWriters.length) out.push(el('h3', {}, `Log backups of the last 7 days by destination: ${asked}`),
      el('p', { class: 'meta' }, 'Not copy-only, by the first file\'s destination; two destinations raise a warning, two logins to one destination are a note. '
        + 'Each replica\'s msdb is its own: a split between two replicas of a group is not seen here.'),
      grid(myWriters, writerCols));
    const myRoots = roots.filter(r => r.database_name === asked);
    if (myRoots.length) out.push(el('h3', {}, `Destinations seen: ${asked}`), grid(myRoots, rootCols));
  }
  out.push(el('h3', { id: 'mssql-backups-files' }, 'Backup files'),
    el('p', { class: 'meta' }, 'Every file of the backups kept above, of every database: each stripe and each mirror, the path whole as msdb holds it.'),
    el('div', { id: 'mssql-backups-files-grid' }, grid(files, fileCols, 'mssql_backup_files has stored no backup file of this server.')));
  return out;
}

// ---- the fleet's Backups page, the SQL Server sections ------------------------------------------------------

type FleetParts = 'by_instance' | 'databases' | 'findings';
const n0 = (v: unknown) => v == null ? 0 : Number(v);
const count = (bad = '') => ({ num: true, fmt: (v: unknown) => v == null ? '' : fmtNum(v), cls: (v: unknown) => bad && n0(v) > 0 ? bad : '' });
// a rate under a header that names its unit ('full MB/s'): the cell is the number, so the export keeps a number (X7)
const rate = (v: unknown) => v == null ? '' : fmtNum(v);
// where the thresholds are set, for the Configure control that cannot act here
const configureWhy = 'Backup thresholds are not set from this page: they are each instance\'s mssql_thresholds in pgvigil.yaml '
  + '(full_backup_hours, diff_backup_hours, log_backup_minutes, new_database_hours, nul_backup_days, backup_exclude) and reach the repository with the collector.';

const byInstanceCols = (ctx: Ctx): Col[] => [
  { key: 'instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', {}, Number(r.instance_id)) }, String(v ?? '')) },
  { key: 'findings', fmt: (v, r) => !n0(v) ? '' : badge(`${fmtNum(v)} ${String(r.worst)}`, r.worst === 'critical' ? 'crit' : r.worst === 'warning' ? 'warn' : '') },
  { key: 'databases', ...count() },
  { key: 'full_ok', label: 'full ok', ...count() }, { key: 'full_late', label: 'full late', ...count('crit') },
  { key: 'full_never', label: 'full never', ...count('crit') }, { key: 'full_not_judged', label: 'full not judged', ...count() },
  { key: 'diff_ok', label: 'differential ok', ...count() }, { key: 'diff_late', label: 'differential late', ...count('warn') },
  { key: 'diff_never', label: 'differential never', ...count('warn') }, { key: 'diff_not_judged', label: 'differential not judged', ...count() },
  { key: 'log_ok', label: 'log ok', ...count() }, { key: 'log_late', label: 'log late', ...count('warn') },
  { key: 'log_never', label: 'log never', ...count('warn') }, { key: 'log_not_judged', label: 'log not judged', ...count() },
  { key: 'nul_recent', label: 'backup to NUL', ...count('warn') },
  { key: 'model_full', label: 'full recovery', ...count() }, { key: 'model_bulk_logged', label: 'bulk-logged recovery', ...count() },
  { key: 'model_simple', label: 'simple recovery', ...count() },
  { key: 'oldest_full', label: 'oldest full', fmt: fmtTime }, { key: 'oldest_diff', label: 'oldest differential', fmt: fmtTime },
  { key: 'oldest_log', label: 'oldest log', fmt: fmtTime },
  { key: 'full_bytes', label: 'full size', num: true, fmt: fmtBytes },
  { key: 'full_compressed_bytes', label: 'compressed', num: true, fmt: (v, r) => v == null ? ''
    : fmtBytes(v) + (n0(r.full_bytes) > 0 ? ` (${fmtNum(Math.round((1 - n0(v) / n0(r.full_bytes)) * 100))} % saved)` : '') },
  { key: 'fulls_compressed', label: 'fulls compressed', fmt: (v, r) => !n0(r.fulls_here) ? '' : `${fmtNum(v)} of ${fmtNum(r.fulls_here)}` },
  { key: 'full_mb_s', label: 'full MB/s', num: true, fmt: rate }, { key: 'full_write_mb_s', label: 'full write MB/s', num: true, fmt: rate },
  { key: 'diff_bytes', label: 'differential size', num: true, fmt: fmtBytes }, { key: 'diff_mb_s', label: 'differential MB/s', num: true, fmt: rate },
  // DBA Dash's Summary 34-45 (task 301's read): 'n/m' over the databases judged that have a backup of the type
  ...(['checksums', 'compressed', 'password', 'encrypted'] as const).flatMap(k => (['full', 'diff', 'log'] as const).map((t): Col => ({
    key: `${t}_${k}`, label: `${typeWord[t]} ${k === 'password' ? 'password protected' : k}` }))),
  { key: 'fulls_snapshot', label: 'snapshot backups', fmt: (v, r) => !n0(r.fulls_here) ? '' : n0(v) === 0 ? 'NONE' : n0(v) === n0(r.fulls_here) ? 'ALL' : 'SOME' },
  // DBA Dash's Summary 48-50: the compression algorithms of the newest backups ('MS_XPRESS(12), ZSTD(3)'; SQL Server 2022 and later)
  ...(['full', 'diff', 'log'] as const).map((t): Col => ({ key: `${t}_algorithms`, label: `${typeWord[t]} compression algorithms` })),
  { key: 'copy_only_fulls', label: 'copy-only fulls', ...count() },
  // no read: the tab's own line; a collection that last failed says its status and note beside its last read
  { key: 'snapshot_at', label: 'read', fmt: (v, r) => !v ? (r.status ? `${String(r.status)}: ${String(r.note ?? '')}` : 'mssql_backups has not run on this server yet')
    : fmtTime(v) + (r.status && r.status !== 'ok' ? ` (last run ${String(r.status)}: ${String(r.note ?? '')})` : ''),
    cls: (v, r) => !v || (r.status && r.status !== 'ok') ? 'warn' : '' },
];

export async function mssqlBackupsFleetSection(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { id: 'mssql-backups-fleet' }, el('h2', {}, 'SQL Server backups'));
  try {
    // the instances in view come from the fleet list and its engines, never from which rows a read returned
    const inView = (await fleet()).instances.filter(r => r.engine === 'sqlserver'
      && (!ctx.tag || (ctx.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(ctx.tag))));
    if (!inView.length) {
      sec.append(el('p', { class: 'empty' }, 'No SQL Server instance in this view.'));
      return sec;
    }
    const ids = new Set(inView.map(r => Number(r.instance_id)));
    const keep = (r: Row) => ids.has(Number(r.instance_id));
    // DBA Dash's default (CustomReportView.cs ResetStatusFilter): a view of one instance lists every database, a view
    // of more the ones with a problem
    let problems = inView.length > 1;
    const [d, loc] = await Promise.all([
      get<Record<FleetParts, Table | null>>('mssql/backups', { problems: problems ? 1 : undefined }),
      // task 301's texts and findings: a store without them still draws the rest
      get<Record<'by_instance' | 'findings', Table | null>>('mssql/backup_files').catch(() => null),
    ]);
    const texts = new Map(rowsOf(loc?.by_instance ?? null).map(r => [Number(r.instance_id), r]));
    const inst = rowsOf(d.by_instance).filter(keep).map(r => ({ ...texts.get(Number(r.instance_id)), ...r }));
    const findings = [...rowsOf(d.findings), ...rowsOf(loc?.findings ?? null)].filter(keep);
    const sum = (k: string) => inst.reduce((a, r) => a + n0(r[k]), 0);
    const noFull = sum('full_late') + sum('full_never'), noLog = sum('log_late') + sum('log_never'), unread = inst.filter(r => !r.snapshot_at).length;
    sec.append(el('div', { class: 'tiles' },
      tile('SQL Server instances', fmtNum(inst.length)),
      tile('databases', fmtNum(sum('databases'))),
      tile('without a recent full backup', fmtNum(noFull), noFull ? 'crit' : ''),
      tile('without a recent log backup', fmtNum(noLog), noLog ? 'warn' : ''),
      tile('not judged', fmtNum(sum('not_judged'))),
      ...(unread ? [tile('instances not read', fmtNum(unread), 'warn')] : [])));
    const cfg = el('button', { type: 'button' }, 'Configure');
    sec.append(el('p', { class: 'meta' }, cfg, ' ', offControl(cfg, configureWhy)));

    sec.append(el('h3', {}, 'SQL Server backups by instance'),
      el('p', { class: 'meta' }, 'One row per SQL Server instance in view, as each was last read (hourly); every count is of its databases at that read. '
        + 'Oldest: the oldest last backup among the databases judged for that type. Sizes and rates are each server\'s own msdb record: '
        + 'a backup that ran on another replica of an availability group counts on that replica\'s row. MB/s is the summed size over the summed duration.'),
      el('div', { id: 'mssql-backups-fleet-instances' }, grid(inst, byInstanceCols(ctx), 'No SQL Server instance in this view.')));

    if (findings.length) sec.append(el('h3', {}, 'SQL Server backup findings'),
      el('div', { id: 'mssql-backups-fleet-findings' }, grid(findings, [{ key: 'instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', {}, Number(r.instance_id)) }, String(v ?? '')) }, ...mssqlFindingCols])));

    // the ages as numbers under their unit (the tab writes '16.3 h' / '2.4 d' and '1h 5m'; a unit in a cell is text in
    // the export, X7): hours to two places, whole minutes; their colours as the tab's
    const ageNums: Record<string, Partial<Col>> = {
      full_age_hours: { label: 'full age (hours)', fmt: v => v == null ? '' : fmtNum(v) },
      log_age_minutes: { label: 'log age (minutes)', fmt: v => v == null ? '' : fmtNum(Math.round(Number(v))) },
    };
    const fleetCols: Col[] = [
      { key: 'instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', {}, Number(r.instance_id)) }, String(v ?? '')) },
      { ...cols[0], fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', { db: String(v ?? '') }, Number(r.instance_id)) }, String(v ?? '')) },
      ...cols.slice(1).map(c => ageNums[c.key] ? { ...c, ...ageNums[c.key] } : c),
    ];
    const total = sum('databases');
    const pick = el('select', { id: 'mssql-backups-fleet-filter' }, el('option', { value: 'problems' }, 'Problems'), el('option', { value: 'all' }, 'All')) as HTMLSelectElement;
    pick.value = problems ? 'problems' : 'all';
    const said = el('span', { id: 'mssql-backups-fleet-count', role: 'status' });
    const box = el('div', { id: 'mssql-backups-fleet-databases' });
    const draw = (rows: Row[]) => {
      said.textContent = `${fmtNum(rows.length)} of ${fmtNum(total)} databases`;
      box.replaceChildren(grid(rows, fleetCols, problems
        ? 'No database of the SQL Server instances in view has a late or missing backup or a recent backup to NUL.' : 'The last reads listed no database.'));
    };
    // a later pick wins over a slower earlier read; a failed read clears the count beside it
    let pickSeq = 0;
    pick.addEventListener('change', () => {
      const mine = ++pickSeq;
      problems = pick.value === 'problems';
      said.textContent = '';
      box.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
      get<Record<FleetParts, Table | null>>('mssql/backups', { problems: problems ? 1 : undefined, part: 'databases' })
        .then(x => { if (mine === pickSeq) draw(rowsOf(x.databases).filter(keep)); })
        .catch(e => { if (mine === pickSeq) { said.textContent = ''; box.replaceChildren(errorBox(e)); } });
    });
    sec.append(el('h3', {}, 'SQL Server databases'),
      el('p', { class: 'meta' }, el('label', { for: 'mssql-backups-fleet-filter' }, 'Show '), pick, ' ', said),
      el('p', { class: 'meta' }, 'Problems: a full, differential or log backup that is late or was never taken, or a backup to the NUL device inside the instance\'s '
        + 'nul_backup_days. A view of one instance opens on All. The database opens its instance\'s Backups tab with its row first; pgvigil keeps the newest backup '
        + 'of each type per database, not a history of backups. Full size, compressed and took are of a full backup that ran on the row\'s own server '
        + '(blank where it ran on another replica: open that instance). Full to, differential to, log to: the folder (a URL\'s container) of the newest backup of '
        + 'the type, on whichever monitored replica of the group it ran, and its file count when striped; the database\'s Backups tab lists every file. Not read by pgvigil: partial and filegroup backups (DBA Dash\'s '
        + 'Last Filegroup and Last Partial columns).'),
      box);
    draw(rowsOf(d.databases).filter(keep));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
