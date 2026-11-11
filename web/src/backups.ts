// The Backups tab and the fleet Backups root (task 33): the WAL archiver (pg_stat_archiver: archived and failed
// files, the last of each, the archive lag, the trend), and through the AWS door on RDS and Aurora the backup
// retention, the latest restorable time and the snapshots; the four rules (the archiver failing, the last archive
// older than the threshold, retention under 7 days, no snapshot in 24 h). pgBackRest and barman are not read.
// Data from /api/backups and /api/backups/fleet.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, el, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const yesNo = (v: unknown) => v == null ? '' : v ? 'yes' : 'no';
const ageTxt = (v: unknown) => v == null ? '' : fmtSecs(v) + ' ago';
const snapAge = (v: unknown) => v == null ? '' : Number(v) > 86400 ? badge(ageTxt(v), 'warn') : ageTxt(v);
const retTxt = (v: unknown) => v == null ? '' : Number(v) === 0 ? badge('off (0 days)', 'crit') : Number(v) < 7 ? badge(fmtNum(v) + ' days', 'warn') : fmtNum(v) + ' days';

// archiverState is the archiver's one-word state for a tile and the fleet grid.
function archiverState(s: Row): [string, string] {
  if (s.archive_mode == null) return ['not read', ''];
  if (s.archiver_failing) return ['failing', 'crit'];
  if (!s.archiving) return [s.archive_mode === 'off' ? 'off' : s.is_replica ? 'standby (not archiving)' : 'no command set', ''];
  const old = s.archive_age_s != null && Number(s.archive_age_s) > Number(s.archive_warn_minutes ?? 60) * 60;
  if (s.wal_waiting && (old || s.last_archived_time == null)) return ['behind', 'warn'];
  return ['archiving', 'ok'];
}

export async function backupsView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Record<'status' | 'snapshots' | 'series' | 'findings', Table | null>>('backups', { instance: ctx.instance, ...window_(ctx) });
  const s = rowsOf(d.status)[0] ?? {};
  const snaps = rowsOf(d.snapshots), findings = rowsOf(d.findings), series = rowsOf(d.series);
  const sec = el('section', {}, el('h2', {}, `Backups (${rangeLabel(ctx)})`));
  if (!rowsOf(d.status).length) {
    sec.append(el('p', { class: 'empty' }, 'No backups read yet: the backups collection runs every 5 minutes.'));
    return sec;
  }
  const [state, kind] = archiverState(s);
  const cloud = s.cloud_resource != null;
  sec.append(el('div', { class: 'tiles' },
    tile('WAL archiver', state, kind),
    tile('last archived', s.archive_age_s == null ? '-' : fmtSecs(s.archive_age_s) + ' ago'),
    tile('archive lag', s.archive_lag_bytes == null ? '-' : fmtBytes(s.archive_lag_bytes)),
    ...(cloud ? [
      tile('retention', s.retention_days == null ? '-' : fmtNum(s.retention_days) + ' days',
        s.retention_days == null ? '' : Number(s.retention_days) === 0 ? 'crit' : Number(s.retention_days) < 7 ? 'warn' : 'ok'),
      tile('newest snapshot', s.newest_snapshot_age_s == null ? 'none' : fmtSecs(s.newest_snapshot_age_s) + ' ago',
        s.newest_snapshot_age_s == null || Number(s.newest_snapshot_age_s) > 86400 ? 'warn' : 'ok'),
    ] : []),
  ));

  if (findings.length) {
    sec.append(el('h3', {}, 'Findings'), grid(findings, [
      { key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'rule' }, { key: 'value', wide: true },
      { key: 'suggested', wide: true }, { key: 'detail', label: 'why it matters', wide: true }, { key: 'at', label: 'read', fmt: fmtTime },
    ]));
  }

  sec.append(el('h3', {}, 'WAL archiver'),
    el('p', { class: 'meta' }, 'pg_stat_archiver since its last reset. The archive lag is the WAL written since the end of the last archived '
      + 'file: under one segment is normal (the current segment is archived when it is full or archive_timeout switches it). '
      + `The age rule fires when WAL is waiting and the last archive is older than ${fmtNum(s.archive_warn_minutes ?? 60)} minutes.`),
    props([
      ['archive_mode', `${String(s.archive_mode ?? '')}${s.archive_set === false ? ' (no archive_command or archive_library set)' : ''}${s.is_replica ? ', a standby' : ''}`],
      ['archived', `${fmtNum(s.archived_count)} files; the last ${String(s.last_archived_wal ?? '-')} at ${fmtTime(s.last_archived_time) || '-'}`],
      ['failed', s.failed_count ? `${fmtNum(s.failed_count)} attempts; the last ${String(s.last_failed_wal ?? '-')} at ${fmtTime(s.last_failed_time)}` : 'none'],
      ['archive lag', s.archive_lag_bytes == null ? '- (a standby has no current WAL position)' : `${fmtBytes(s.archive_lag_bytes)} (segment ${fmtBytes(s.wal_segment_bytes)})`],
      ['statistics reset', fmtTime(s.stats_reset) || 'never'],
      ['read', fmtTime(s.archiver_read_at)],
    ]));
  sec.append(el('div', { class: 'charts' },
    lineChart('Files archived and failed', series, [{ key: 'archived', label: 'archived' }, { key: 'failed', label: 'failed' }]),
    lineChart('Archive lag', series, [{ key: 'archive_lag_bytes', label: 'WAL waiting' }], v => fmtBytes(v))));

  if (cloud) {
    sec.append(el('h3', {}, s.resource_kind === 'cluster' ? 'Aurora cluster backups' : 'RDS backups'),
      props([
        [s.resource_kind === 'cluster' ? 'cluster' : 'DB instance', String(s.cloud_resource)],
        ['backup retention', retTxt(s.retention_days)],
        ['backup window (UTC)', String(s.backup_window ?? '-')],
        ['latest restorable time', s.latest_restorable_time == null ? 'none' : `${fmtTime(s.latest_restorable_time)} (${ageTxt(s.restorable_age_s)})`],
        ...(s.earliest_restorable_time != null ? [['earliest restorable time', fmtTime(s.earliest_restorable_time)] as [string, string]] : []),
        ['snapshots listed', `${fmtNum(s.automated_count)} automated, ${fmtNum(s.manual_count)} manual (the newest 20 of each kept)`],
        ['read', fmtTime(s.cloud_read_at)],
      ]),
      lineChart('Latest restorable time, age', series, [{ key: 'restorable_age_s', label: 'age' }], v => fmtSecs(v)),
      el('h3', {}, 'Snapshots'),
      grid(snaps, [
        { key: 'snapshot', wide: true }, { key: 'snapshot_type', label: 'type' }, { key: 'status' },
        { key: 'created_at', label: 'created', fmt: fmtTime },
        { key: 'allocated_gib', label: 'size', num: true, fmt: v => v == null || Number(v) === 0 ? '' : fmtNum(v) + ' GiB' },
        { key: 'encrypted', fmt: yesNo },
      ], 'No snapshot listed.'));
  } else {
    sec.append(el('p', { class: 'meta' }, 'Snapshots and retention are read on RDS and Aurora through an aws: block with the DB instance or cluster. '
      + 'pgBackRest and barman keep their catalogs outside the server and are not read.'));
  }
  return sec;
}

// backupsFleetView: every instance's archiver and cloud backups, the failing first (keep narrows it to a tag
// folder; instLink makes the instance name a link to its Backups tab).
export async function backupsFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const d = await get<Record<'instances', Table | null>>('backups/fleet');
  let rows = rowsOf(d.instances);
  if (keep) rows = rows.filter(keep);
  const failing = rows.filter(r => r.archiver_failing).length;
  const short = rows.filter(r => r.retention_days != null && Number(r.retention_days) < 7).length;
  const stale = rows.filter(r => r.retention_days != null && (r.newest_snapshot_age_s == null || Number(r.newest_snapshot_age_s) > 86400)).length;
  return el('section', {}, el('h2', {}, 'Backups'),
    el('div', { class: 'tiles' },
      tile('instances', String(rows.length)),
      tile('archiver failing', String(failing), failing ? 'crit' : 'ok'),
      tile('retention under 7 days', String(short), short ? 'warn' : 'ok'),
      tile('no snapshot in 24 h', String(stale), stale ? 'warn' : 'ok')),
    grid(rows, [
      { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
      { key: 'platform' },
      { key: 'worst', label: 'findings', fmt: (v, r) => v == null ? '' : badge(`${fmtNum(r.findings)} ${String(v)}`, v === 'critical' ? 'crit' : 'warn') },
      { key: 'archiver_failing', label: 'archiver', fmt: (_v, r) => { const [t, k] = archiverState(r); return k ? badge(t, k) : t; } },
      { key: 'archive_age_s', label: 'last archived', num: true, fmt: ageTxt, cls: (v, r) => v == null ? '' : archiverState(r)[1] },
      { key: 'archive_lag_bytes', label: 'archive lag', num: true, fmt: fmtBytes },
      { key: 'failed_count', label: 'failed', num: true },
      { key: 'retention_days', label: 'retention', num: true, fmt: retTxt, cls: v => v == null ? '' : Number(v) === 0 ? 'crit' : Number(v) < 7 ? 'warn' : 'ok' },
      { key: 'restorable_age_s', label: 'restorable', num: true, fmt: ageTxt },
      { key: 'newest_snapshot_age_s', label: 'newest snapshot', num: true, fmt: snapAge, cls: v => v == null ? '' : Number(v) > 86400 ? 'warn' : 'ok' },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], 'No backups read yet.'));
}
