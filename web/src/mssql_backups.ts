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
import { get, post, Row, rowsOf, Table } from './api';
import { hashParam, hrefWith } from './dbinfo';
import { fleet, tagsOf } from './fleet';
import { Ctx } from './router';
import { mssqlFindingCols, words } from './mssql_hadr';
import { badge, Col, copyText, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, GridMenuAsk, offControl, props, tile } from './ui';
import { dialogRole, needControl } from './needs';

type Parts = 'databases' | 'findings' | 'limits';
type FileParts = 'sets' | 'files' | 'writers' | 'roots' | 'findings' | 'read' | 'checks' | 'path' | 'check_findings';

// a status is its word and its colour, never the colour alone
// the word's colour: never red, late amber (red for a full backup), ok green, not judged grey; a date and an age take their status's colour
const statusCls = (v: unknown) => v === 'never' ? 'crit' : v === 'late' ? 'warn' : v === 'ok' ? 'ok' : v === 'not judged' ? 'status none' : '';
const critIfFull = (v: unknown) => v === 'late' ? 'crit' : statusCls(v);
const follows = (status: string, full = false) => (v: unknown, r: Row) => v == null || v === '' ? '' : full ? critIfFull(r[status]) : statusCls(r[status]);
const hours = (v: unknown) => v == null ? '' : Number(v) >= 48 ? fmtNum(Math.round(Number(v) / 2.4) / 10) + ' d' : fmtNum(Math.round(Number(v) * 10) / 10) + ' h';
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
    cls: (v, r) => !v ? '' : r.replicas_unseen === true ? 'warn' : 'ok' },
  { key: 'not_judged', label: 'judged', fmt: v => v ? `no: ${String(v)}` : 'yes' },
  { key: 'full_status', label: 'full', cls: critIfFull },
  { key: 'full_at', label: 'last full', fmt: when('full_from'), cls: follows('full_status', true) },
  // the ages as numbers under their unit, on this tab and the fleet's (a unit in a cell is text in the export, X16; a
  // fmtSecs '1m 9s' under a unit header too, X15): hours to two places, whole minutes
  { key: 'full_age_hours', label: 'full age (hours)', num: true, fmt: v => v == null ? '' : fmtNum(v), cls: follows('full_status', true) },
  { key: 'diff_status', label: 'differential', cls: statusCls },
  { key: 'diff_at', label: 'last differential', fmt: when('diff_from'), cls: follows('diff_status') },
  { key: 'log_status', label: 'log', cls: statusCls },
  { key: 'log_at', label: 'last log', fmt: when('log_from'), cls: follows('log_status') },
  { key: 'log_age_minutes', label: 'log age (minutes)', num: true, fmt: v => v == null ? '' : fmtNum(Math.round(Number(v))), cls: follows('log_status') },
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
      ...(lp ? checkProps(rowsOf(lp.path)[0]) : []),
    ]));
    const findings = [...rowsOf(d.findings), ...(lp ? [...rowsOf(lp.findings), ...rowsOf(lp.check_findings)] : [])];
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
    if (lp) sec.append(...checkParts(lp, nameCell));
    // the database's backup and restore history and Verify (task 301b): its own reads, only for the database asked
    const more = lp && asked != null && picked ? await historyParts(ctx, asked, String(picked.database_name ?? asked)) : [];
    if (lp) sec.append(...locationParts(lp, asked ?? undefined, picked != null, more));
    else if (locErr) sec.append(errorBox(locErr));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// locationParts: the Last backup panel of the database asked for, then every file of the server's sets (the export's
// Files sheet), the log writers and the destinations seen.
function locationParts(lp: Record<FileParts, Table | null>, asked: string | undefined, listed: boolean, more: HTMLElement[] = []): HTMLElement[] {
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
    out.push(...more);
  }
  out.push(el('h3', { id: 'mssql-backups-files' }, 'Backup files'),
    el('p', { class: 'meta' }, 'Every file of the backups kept above, of every database: each stripe and each mirror, the path whole as msdb holds it.'),
    el('div', { id: 'mssql-backups-files-grid' }, grid(files, fileCols, 'mssql_backup_files has stored no backup file of this server.')));
  return out;
}

// ---- task 301b: the three checks, the database's backup and restore history, verify_backup ------------------------

// a check's words in their colour: amber where it is a finding, grey where it was not read or not judged
const checkCls = (v: unknown) => {
  const s = String(v ?? '');
  return s.startsWith('yes') || s === 'the file is gone' || s.startsWith('the folder ') ? 'warn' : s.startsWith('not ') ? 'status none' : '';
};
const checkCols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'recovery_model', label: 'recovery model', fmt: words },
  { key: 'pseudo_simple', label: 'pseudo-simple', wide: true, cls: checkCls },
  { key: 'file_full', label: 'newest full\'s file', wide: true, cls: checkCls },
  { key: 'file_diff', label: 'newest differential\'s file', wide: true, cls: checkCls },
  { key: 'file_log', label: 'newest log\'s file', wide: true, cls: checkCls },
];

// checkProps: the default backup path (Instance#14) and the checks' read, two lines of the tab's read block
function checkProps(p: Row | undefined): [string, string | Node][] {
  if (!p) return [];
  const run = (at: unknown, status: unknown, note: unknown, what: string) => !at
    ? (status ? `${what} ${String(status)}: ${String(note ?? '')}` : `${what} has not run on this server yet (hourly)`)
    : `${fmtTime(at)} (${what}, hourly${status && status !== 'ok' ? `; its last run ${String(status)}: ${String(note ?? '')}` : ''})`;
  const path = p.default_backup_path ? el('span', {}, el('code', {}, String(p.default_backup_path)), ' - ',
    el('span', { class: p.reachable === 'no' ? 'warn' : p.reachable == null ? 'status none' : '' }, String(p.default_backup_path_state ?? '')))
    : String(p.default_backup_path_state ?? 'not read');
  return [
    ['default backup path', p.checks_at ? path : run(null, p.checks_status, p.checks_note, 'mssql_backup_checks')],
    ['backup checks', `${run(p.checks_at, p.checks_status, p.checks_note, 'mssql_backup_checks')}; the files: ${String(p.files_state ?? 'not read')}`],
    ['backup and restore history', run(p.history_at, p.history_status, p.history_note, 'mssql_backup_history') + (p.restore_state && p.restore_state !== 'read'
      ? `; the restores: ${String(p.restore_state)} - the restores read before stay` : '')],
  ];
}

// checkParts: per database pseudo-simple (Database#39) and whether the newest backups' files are still there (Database#7)
function checkParts(lp: Record<FileParts, Table | null>, nameCell: (v: unknown) => string | Node): HTMLElement[] {
  const rows = rowsOf(lp.checks);
  if (!rows.length) return [];
  return [el('h3', { id: 'mssql-backups-checks' }, 'Backup checks'),
    el('p', { class: 'meta' }, 'Pseudo-simple: a database in FULL or BULK_LOGGED recovery whose log cannot be backed up yet (no full or differential backup since '
      + 'the log chain began): it behaves as SIMPLE until one is taken. An AUTO_CLOSE database is not read (the read would open it) unless the instance '
      + 'opts in (reads: auto_close_databases). The newest full, differential and log backup\'s file: whether the file msdb names is still there, as the '
      + 'SQL Server service account sees it (sys.dm_os_file_exists) - read only where the instance opts in (reads: backup_files), disk backups only.'),
    el('div', { id: 'mssql-backups-checks-grid' }, grid(rows, [{ ...checkCols[0], fmt: nameCell }, ...checkCols.slice(1)]))];
}

// a restore's type as restorehistory names it
const restoreTypeWord: Record<string, string> = { D: 'database', F: 'file', G: 'filegroup', I: 'differential', L: 'log', V: 'verify only' };
const restoreCols: Col[] = [
  { key: 'restore_at', label: 'restored', fmt: fmtTime },
  { key: 'destination_database_name', label: 'database' },
  { key: 'restore_type', label: 'restore type', fmt: v => restoreTypeWord[String(v)] ?? String(v ?? '') },
  { key: 'user_name', label: 'by' },
  { key: 'is_replace', label: 'replace', fmt: yesNo },
  { key: 'is_recovery', label: 'with recovery', fmt: yesNo },
  { key: 'stop_at', label: 'stop at', fmt: fmtTime },
  { key: 'source_server', label: 'backup of server' },
  { key: 'source_database', label: 'backup of database' },
  { key: 'source_type', label: 'backup type', fmt: v => typeWord[String(v) as keyof typeof typeWord] ?? String(v ?? '') },
  { key: 'source_finish_at', label: 'backup finished', fmt: fmtTime },
  { key: 'source_path', label: 'backup file', fmt: pathCell },
];

interface VerifyOnOff { enabled: boolean; reason?: string }
interface VerifySet { backup_set_uuid: string; database: string; backup_type: string; finish_utc: string; position: number; has_checksums: boolean; size_bytes: number; paths: string[] | null; not_offered?: string }
interface VerifyPreview { ok: boolean; reason?: string; statement?: string; set: VerifySet }

const verifyCls = (v: unknown) => v === 'done' ? 'ok' : v === 'failed' ? 'crit' : v === 'started' ? 'status none' : v ? 'warn' : '';
// the newest verify of the set (the actions log), and Verify where it is on and the set is a disk backup; the cell's
// words alone go to a copy or the export (data-full)
const verifyCell = (on: VerifyOnOff, open: (r: Row) => void) => (v: unknown, r: Row) => {
  const said = v ? `${String(v)} ${fmtTime(r.verify_at)}${r.verify_user ? ` by ${String(r.verify_user)}` : ''}` : 'never';
  const out = el('span', { 'data-full': said, 'data-verify-uuid': String(r.backup_set_uuid ?? ''), style: 'white-space:nowrap' },
    el('span', { class: verifyCls(v), title: String(r.verify_detail ?? '') }, said));
  if (on.enabled && r.device_kind !== 'disk') {
    out.append(el('span', { class: 'meta', style: 'margin-left:.4rem' }, 'not offered: not a disk backup'));
  } else if (on.enabled) {
    const b = el('button', { type: 'button', class: 'act-verify', style: 'font-size:12px;padding:0 .4rem;margin-left:.4rem', title: 'RESTORE VERIFYONLY of this backup' }, 'Verify');
    b.addEventListener('click', () => open(r));
    out.append(needControl(b, 'mssql/actions/verify/preview'));   // the role (B24f): a verify is an operator's
  }
  return out;
};
const historyCols = (verify: Col): Col[] => [
  // DBA Dash's Last Backup columns that msdb's history holds, in its order (its partner pair is the log-shipping
  // partner's backup, which a server's own history does not hold)
  { key: 'database_name', label: 'database' },
  { key: 'recovery_model', label: 'recovery model', fmt: words },
  { key: 'backup_type', label: 'type', fmt: (v, r) => (typeWord[String(v) as keyof typeof typeWord] ?? String(v ?? '')) + (r.is_copy_only === true ? ', copy-only' : '') },
  { key: 'start_at', label: 'start date', fmt: fmtTime },
  { key: 'finish_at', label: 'finish date', fmt: fmtTime },
  { key: 'duration_s', label: 'duration', num: true, fmt: fmtSecs },
  { key: 'size_bytes', label: 'backup size', num: true, fmt: fmtBytes },
  { key: 'mb_s', label: 'backup MB/s', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'compressed_bytes', label: 'backup size (compressed)', num: true, fmt: fmtBytes },
  { key: 'saving_pct', label: 'compression saving %', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'write_mb_s', label: 'backup write MB/s', num: true, fmt: v => v == null ? '' : fmtNum(v) },
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
  // pgvigil's own
  verify,
  { key: 'path', label: 'to (the first file)', fmt: pathCell },
  { key: 'family_count', label: 'files', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'position', label: 'position in the file', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'device_kind', label: 'device' },
  { key: 'user_name', label: 'taken by' },
  { key: 'machine_name', label: 'machine' },
  { key: 'set_name', label: 'set name' },
  { key: 'is_copy_only', label: 'copy-only', fmt: yesNo },
  { key: 'first_lsn', label: 'first LSN' },
  { key: 'last_lsn', label: 'last LSN' },
  { key: 'checkpoint_lsn', label: 'checkpoint LSN' },
  { key: 'database_backup_lsn', label: 'database backup LSN' },
  { key: 'differential_base_guid', label: 'base (a differential\'s full)' },
  { key: 'backup_set_uuid', label: 'backup set' },
];

// historyParts: the database's Backup history (Verify in each disk row's cell and the grid's right-click menu) and its
// Restore history. Their own reads; a server without them (an older build) says so in their place.
async function historyParts(ctx: Ctx, asked: string, dbName: string): Promise<HTMLElement[]> {
  const orErr = (e: unknown) => e instanceof Error ? e : new Error(String(e));
  const [h, rs, st] = await Promise.all([
    get<Record<'history', Table | null>>('mssql/backup_files', { instance: ctx.instance, db: asked, part: 'history' }).catch(orErr),
    get<Record<'restores', Table | null>>('mssql/backup_files', { instance: ctx.instance, db: asked, part: 'restores' }).catch(orErr),
    get<{ actions?: Record<string, VerifyOnOff | undefined> }>('mssql/actions/state', { instance: ctx.instance }).catch(orErr),
  ]);
  const on: VerifyOnOff = st instanceof Error ? { enabled: false, reason: `the actions door could not be read: ${st.message}` }
    : st.actions?.verify_backup ?? { enabled: false, reason: 'this server\'s actions door does not offer verify_backup' };
  const out: HTMLElement[] = [];
  const box = el('div', { id: 'mssql-backups-history-grid' });
  let drawn: Row[] = [];
  const draw = (rows: Row[]) => {
    drawn = rows;
    box.replaceChildren(grid(rows, historyCols({ key: 'verify_outcome', label: 'last verify', fmt: verifyCell(on, open) }),
    'mssql_backup_history has stored no backup of this database.'));
  };
  // after a verify was sent: the grid read again, so its last verify cell shows 'started' and later the end
  const reload = () => {
    get<Record<'history', Table | null>>('mssql/backup_files', { instance: ctx.instance, db: asked, part: 'history' })
      .then(x => draw(rowsOf(x.history))).catch((e: unknown) => box.replaceChildren(errorBox(e)));
  };
  const open = (r: Row) => { void verifyDialog(ctx, r, dbName, reload); };
  out.push(el('h3', { id: 'mssql-backups-history' }, `Backup history: ${asked}`),
    el('p', { class: 'meta' }, 'The newest 10 backups of each type (copy-only apart) in this server\'s msdb, newest first (mssql_backup_history, hourly). '
      + 'DBA Dash has no history grid: its Last Backup columns that msdb\'s history holds, in its order, then pgvigil\'s own. Last verify: the newest '
      + 'RESTORE VERIFYONLY sent from pgvigil (the Actions log); Verify reads the backup\'s files on the server and checks them (no database is made).'));
  if (!on.enabled) out.push(el('p', { class: 'meta', id: 'mssql-backups-verify-off' }, `Verify is off for this instance: ${on.reason ?? 'actions are off for this instance'}`));
  if (h instanceof Error) box.append(el('p', { class: 'meta' }, `not read: ${h.message}`));
  else draw(rowsOf(h.history));
  // the grid's right-click menu (ui.ts askGridMenu; gridtools builds it, this page's line at its end): Verify on a disk
  // row of this grid only
  box.addEventListener('pgvigil:gridmenu', e => {
    const d = (e as CustomEvent<GridMenuAsk>).detail;
    const uuid = d.td?.parentElement?.querySelector('[data-verify-uuid]')?.getAttribute('data-verify-uuid');
    if (!on.enabled || !uuid || !d.table || !box.contains(d.table)) return;
    const r = drawn.find(x => x.backup_set_uuid === uuid);
    if (r && r.device_kind === 'disk') d.extra.push(['Verify this backup...', () => open(r)]);
  });
  out.push(box, el('h3', { id: 'mssql-backups-restores' }, `Restore history: ${asked}`),
    el('p', { class: 'meta' }, 'The newest 20 restores of each restore type into this database (msdb.dbo.restorehistory, read hourly), with the backup '
      + 'each restored. Restored and stop at: msdb keeps the server\'s local time with no offset; pgvigil turns it to UTC with the server\'s offset at '
      + 'the read, so a restore made before the clocks last changed (daylight saving) shows an hour off. Where the login may not read restorehistory, the read block above says so and the restores read before stay.'),
    el('div', { id: 'mssql-backups-restores-grid' }, rs instanceof Error ? el('p', { class: 'meta' }, `not read: ${rs.message}`)
      : grid(rowsOf(rs.restores), restoreCols, 'msdb holds no restore into this database (or the login may not read restorehistory).')));
  return out;
}

// verifyDialog: the server reads the set (Preview), the dialog shows its files, the size it reads and whether its
// checksums are checked; the typed database name and a reason send RESTORE VERIFYONLY through the actions login. The
// verify runs on after the reply: its end goes to the Actions log and the grid's last verify.
async function verifyDialog(ctx: Ctx, r: Row, dbName: string, after: () => void) {
  const what = `Verify the ${typeWord[String(r.backup_type) as keyof typeof typeWord] ?? 'backup'} of ${dbName} finished ${fmtTime(r.finish_at)}`;
  const body = el('div', {}, el('p', { class: 'meta', role: 'status' }, 'Reading the backup set...'));
  const no = el('button', { type: 'button' }, 'Back');
  const form = el('form', { method: 'dialog' }, el('h3', {}, what), body);
  const foot = el('div', { style: 'margin-top:.6rem' }, no);
  form.append(foot);
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:44rem', 'aria-label': what }, form);
  let sent = false;
  dlg.addEventListener('close', () => { dlg.remove(); if (sent) after(); });
  no.addEventListener('click', () => dlg.close());
  document.body.append(dlg);
  dlg.showModal();
  let p: VerifyPreview;
  try {
    p = await post<VerifyPreview>('mssql/actions/verify/preview', { instance_id: ctx.instance, backup_set_uuid: String(r.backup_set_uuid ?? '') });
  } catch (e) {
    body.replaceChildren(errorBox(e));
    return;
  }
  const s = p.set, paths = s.paths ?? [];
  const shown = props([
    ['database', s.database], ['type', typeWord[s.backup_type as keyof typeof typeWord] ?? s.backup_type], ['finished (UTC)', s.finish_utc],
    ['backup set', s.backup_set_uuid], ['position in the file', String(s.position)],
    ['reads', `${fmtBytes(s.size_bytes)} from ${paths.length} file${paths.length === 1 ? '' : 's'} on the server${paths.some(x => x.startsWith('\\\\')) ? ', over the network for a share' : ''}`],
    ['checks', s.has_checksums ? 'the page checksums (WITH CHECKSUM) and the backup\'s structure' : 'the backup\'s structure only: it was taken without checksums (header-level only)'],
    ['files', el('div', {}, ...paths.map(x => el('div', {}, pathCell(x))))],
  ]);
  if (!p.ok) {
    body.replaceChildren(el('p', {}, badge('not possible', 'warn'), ' ', p.reason ?? s.not_offered ?? ''), shown);
    return;
  }
  // each field is named by the label that wraps it (WCAG 2.5.3: no aria-label that differs from the visible words)
  const reason = el('textarea', { rows: '3', maxlength: '500', placeholder: 'Why (kept in the actions log)', style: 'width:100%' });
  const typed = el('input', { type: 'text', placeholder: s.database, autocomplete: 'off' });
  const go = el('button', { type: 'submit', disabled: '' }, 'Verify');
  // the role (B24f, review-18 b24f2 B1): the dialog's own check backs the button that opened it
  const role = dialogRole(go, 'mssql/actions/verify/run');
  const msg = el('p', { class: 'meta', role: 'status' });
  const check = () => { if (!role.why) go.disabled = sent || typed.value.trim() !== s.database || reason.value.trim().length < 5; };
  reason.addEventListener('input', check);
  typed.addEventListener('input', check);
  body.replaceChildren(
    el('p', {}, 'RESTORE VERIFYONLY reads every file of the backup on the server and checks that it could be restored; it makes no database. '
      + 'It runs on the server after this dialog closes (up to the configured verify_timeout), one at a time per instance; its end goes to the Actions log.'),
    shown,
    el('p', { class: 'meta' }, 'The statement (the paths are parameters): ', el('code', {}, p.statement ?? '')),
    el('label', {}, 'Reason', el('br'), reason), el('br'),
    el('label', {}, 'Type the database\'s name to confirm ', typed), el('br'),
    role.note, msg);
  foot.prepend(go, ' ');
  reason.focus();
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (role.why || sent || go.disabled) return;   // off is off: an Enter in a field submits the form too
    sent = true; // one send per dialog: a second click, or an edit after the reply, sends nothing
    go.disabled = true;
    msg.textContent = 'Sending...';
    try {
      const out = await post<{ outcome: string; detail: string }>('mssql/actions/verify/run', {
        instance_id: ctx.instance, backup_set_uuid: s.backup_set_uuid, shown: s, reason: reason.value, confirm: typed.value.trim(),
      });
      msg.replaceChildren(badge(out.outcome, 'ok'), ' ', out.detail || 'the verify runs on the server; its end goes to the Actions log');
      go.remove();
      no.textContent = 'Close';
    } catch (e) {
      go.remove();
      msg.replaceChildren(badge('not started', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      no.textContent = 'Close';
    }
  });
}

// ---- the fleet's Backups page, the SQL Server sections ------------------------------------------------------

type FleetParts = 'by_instance' | 'databases' | 'findings';
const n0 = (v: unknown) => v == null ? 0 : Number(v);
// a count judged by its rule (bad over 0) is OK at 0: every cell of a status column carries a status, as DBA Dash's grids do
const count = (bad = '') => ({ num: true, fmt: (v: unknown) => v == null ? '' : fmtNum(v), cls: (v: unknown) => !bad || v == null ? '' : n0(v) > 0 ? bad : 'ok' });
// a rate under a header that names its unit ('full MB/s'): the cell is the number, so the export keeps a number (X7)
const rate = (v: unknown) => v == null ? '' : fmtNum(v);
// where the thresholds are set, for the Configure control that cannot act here
const configureWhy = 'Backup thresholds are not set from this page: they are each instance\'s mssql_thresholds in pgvigil.yaml, or for an instance '
  + 'added in Admin > Instances its Settings there (full_backup_hours, diff_backup_hours, log_backup_minutes, new_database_hours, nul_backup_days, backup_exclude), '
  + 'and reach the repository with the collector.';

const byInstanceCols = (ctx: Ctx): Col[] => [
  { key: 'instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', {}, Number(r.instance_id)) }, String(v ?? '')) },
  { key: 'findings', fmt: (v, r) => !n0(v) ? '' : badge(`${fmtNum(v)} ${String(r.worst)}`, r.worst === 'critical' ? 'crit' : r.worst === 'warning' ? 'warn' : 'none') },
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
    cls: (v, r) => !v || (r.status && r.status !== 'ok') ? 'warn' : 'ok' },
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
      get<Record<'by_instance' | 'findings' | 'check_findings', Table | null>>('mssql/backup_files').catch(() => null),
    ]);
    const texts = new Map(rowsOf(loc?.by_instance ?? null).map(r => [Number(r.instance_id), r]));
    const inst = rowsOf(d.by_instance).filter(keep).map(r => ({ ...texts.get(Number(r.instance_id)), ...r }));
    const findings = [...rowsOf(d.findings), ...rowsOf(loc?.findings ?? null), ...rowsOf(loc?.check_findings ?? null)].filter(keep);
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

    const fleetCols: Col[] = [
      { key: 'instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', {}, Number(r.instance_id)) }, String(v ?? '')) },
      { ...cols[0], fmt: (v, r) => el('a', { href: hrefWith(ctx, 'mssqlbackups', { db: String(v ?? '') }, Number(r.instance_id)) }, String(v ?? '')) },
      ...cols.slice(1),
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
