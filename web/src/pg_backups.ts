// The PostgreSQL twins of DBA Dash's backup, role-change and state cells (task 162; migration 0103, internal/web/q_pg_backups.go).
//   pgBackupsView           one instance's Base backups tab: each tool the server's commands name (pgBackRest, barman), its
//                           last base backup with its kind, size and the WAL archived since, every backup listed, a
//                           standby's replay (a file-fed one's delay), the rules hit, the thresholds with their dialog
//   pgStateView             one instance's Server state tab: the role and timeline with every role change, the crash
//                           restarts from the log with Acknowledge, pg_stat_statements' state, uptime and the amcheck age
//                           per database, each with its thresholds
//   pgReplicationFleetView  the fleet Replication page: the clusters by system identifier, one row per link, Patroni's
//                           members where its REST port answered, the fleet's role changes
//   pgThresholdsView        the fleet Thresholds page: every key at the root, a tag, an instance or a database
//   pgBaseBackupsFleetSection  the base-backup section of the fleet Backups root (the join adds it to backups.ts)
// Every write goes through a dialog that says what it changes; the server answers done or the reason it refused.
import { get, post, Row, rowsOf, Table } from './api';
import { AckBody, ackDialog, loadAckSafe, writeButton } from './ack';
import { Ctx, href } from './router';
import { fleet, tagsOf } from './fleet';
import { badge, Col, el, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';

type Parts<K extends string> = Record<K, Table | null>;

const sev = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const yes = (v: unknown, bad = false) => v == null ? '' : v === true ? badge('yes', bad ? 'crit' : 'ok') : badge('no', bad ? '' : 'warn');
const num = (v: unknown) => v == null || v === '' ? NaN : Number(v);
const hours = (v: unknown) => isNaN(num(v)) ? '' : num(v) < 48 ? `${fmtNum(v)} h` : `${(num(v) / 24).toFixed(1)} d`;
const stateBadge = (v: unknown) => badge(String(v ?? ''), v === 'ok' ? 'ok' : v === 'error' ? 'crit' : v === 'running' || v === 'no_binary' ? 'warn' : '');

function instLink(ctx: Ctx, name: unknown, id: unknown, tab: string): Node {
  return el('a', { href: href(ctx, { tab, instance: Number(id), tag: undefined }) }, String(name ?? ''));
}

// tagIds: the instances of the tag folder in view (none = every instance)
async function tagIds(ctx: Ctx): Promise<Set<number> | null> {
  if (!ctx.tag) return null;
  const f = await fleet();
  return new Set(f.instances.filter(r => tagsOf(r).includes(ctx.tag!)).map(r => Number(r.instance_id)));
}

// ---- thresholds ------------------------------------------------------------------------------------------

export interface ThresholdPlace { level: 'root' | 'tag' | 'instance' | 'database'; instance_id?: number; tag?: string; datname?: string; where: string }

// thresholdLine: the value in force for a key, its level said ("default" = built in)
export function thresholdLine(t: Row): string {
  const u = String(t.unit ?? ''), dir = t.direction === 'under' ? 'under' : 'over';
  const w = t.warn == null ? '' : `warning ${dir} ${fmtNum(t.warn)} ${u}`, c = t.crit == null ? '' : `critical ${dir} ${fmtNum(t.crit)} ${u}`;
  const lv = t.level === 'tag' ? `tag ${String(t.tag)}` : String(t.level ?? 'default');
  return `${[c, w].filter(Boolean).join(', ') || 'not judged'} (${lv})`;
}

// thresholdDialog: set a key's warning and critical at one place, or make the place inherit the level above.
export function thresholdDialog(key: Row, place: ThresholdPlace, current: Row | undefined, after: () => void) {
  const u = String(key.unit ?? ''), dir = key.direction === 'under' ? 'under' : 'over';
  const own = current && current.level === place.level ? current : undefined;
  const inp = (lab: string, v: unknown) => el('input', { type: 'number', min: '0', step: 'any', max: String(key.max_value ?? ''), 'aria-label': lab, value: v == null ? '' : String(v), style: 'width:7rem' });
  const warn = inp('warning', own ? own.warn : ''), crit = inp('critical', own ? own.crit : '');
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const save = el('button', { type: 'submit' }, 'Set'), inherit = el('button', { type: 'button' }, 'Inherit'), back = el('button', { type: 'button' }, 'Back');
  if (!own) inherit.disabled = true;
  const what = `${String(key.label)} at ${place.where}. A ${dir === 'over' ? 'value past' : 'value under'} the warning is a warning, past the critical a critical; an empty box is not judged at this level. Inherit ends this level's own row, so the level above applies. Who and when are kept.`;
  const form = el('form', { method: 'dialog' }, el('h3', {}, `Threshold: ${String(key.key)}`), el('p', {}, what),
    el('p', { class: 'meta' }, `In force now: ${current ? thresholdLine({ ...current, unit: u, direction: dir }) : 'the default'}; built-in default: ${thresholdLine({ warn: key.warn_default, crit: key.crit_default, unit: u, direction: dir, level: 'default' })}.`),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, `Warning ${dir} (${u}) `, warn)),
    el('div', { style: 'margin:.3rem 0' }, el('label', {}, `Critical ${dir} (${u}) `, crit)),
    msg, el('div', { style: 'margin-top:.6rem' }, save, ' ', inherit, ' ', back));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': `Threshold ${String(key.key)}` }, form);
  let done = false;
  const close = () => { dlg.close(); dlg.remove(); if (done) after(); };
  back.addEventListener('click', close);
  dlg.addEventListener('cancel', () => { dlg.remove(); if (done) after(); });
  const send = async (op: 'set' | 'inherit') => {
    save.disabled = inherit.disabled = true;
    msg.textContent = 'Saving...';
    const body: Record<string, unknown> = { op, key: key.key, level: place.level, instance_id: place.instance_id, tag: place.tag, datname: place.datname };
    if (op === 'set') { body.warn = warn.value === '' ? null : warn.value; body.crit = crit.value === '' ? null : crit.value; }
    try {
      const r = await post<{ outcome: string; detail: string }>('pg/thresholds', body);
      done = true;
      msg.replaceChildren(badge(r.outcome, 'ok'), ' ', r.detail);
    } catch (e) {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      save.disabled = false; inherit.disabled = !own;
    }
    back.textContent = 'Close';
  };
  form.addEventListener('submit', ev => { ev.preventDefault(); void send('set'); });
  inherit.addEventListener('click', () => void send('inherit'));
  document.body.append(dlg);
  dlg.showModal();
  warn.focus();
}

let keysCache: Row[] | null = null;
async function thresholdKeys(): Promise<Row[]> {
  if (!keysCache) keysCache = rowsOf((await get<Parts<'keys'>>('pg/thresholds', { part: 'keys' })).keys);
  return keysCache;
}

// thresholdsSection: an instance's keys with the value in force and a Change button each (the instance level).
async function thresholdsSection(rows: Row[], instanceId: number, name: string, after: () => void): Promise<HTMLElement> {
  const keys = await thresholdKeys().catch(() => [] as Row[]);
  const cols: Col[] = [
    { key: 'label', label: 'threshold' },
    { key: 'level', label: 'in force', fmt: (_v, r) => thresholdLine(r) },
    { key: 'key', label: '', fmt: v => {
      const k = keys.find(x => x.key === v);
      if (!k) return '';
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `Change ${String(v)} for ${name}` }, 'Change');
      b.addEventListener('click', () => thresholdDialog(k, { level: 'instance', instance_id: instanceId, where: `the instance ${name}` }, rows.find(x => x.key === v), after));
      return b;
    } },
  ];
  return el('section', {}, el('h3', {}, 'Thresholds'), el('p', { class: 'meta' }, 'Set here for this instance; the Thresholds page sets them for the fleet, a tag or a database.'), grid(rows, cols, 'No threshold keys (the repository is older than 0103).'));
}

// ---- Base backups tab ------------------------------------------------------------------------------------

const toolCols: Col[] = [
  { key: 'tool' }, { key: 'name', label: 'stanza / server' }, { key: 'state', fmt: stateBadge },
  { key: 'status_message', label: 'status', wide: true, fmt: (v, r) => String(v ?? r.message ?? '') },
  { key: 'last_label', label: 'last backup' }, { key: 'last_type', label: 'kind' },
  { key: 'last_stopped_at', label: 'ended', fmt: fmtTime }, { key: 'last_age_h', label: 'age', num: true, fmt: hours },
  { key: 'last_db_size_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'last_repo_bytes', label: 'in the repository', num: true, fmt: fmtBytes },
  { key: 'wal_since_bytes', label: 'WAL archived since', num: true, fmt: (v, r) => v == null ? '' : `${fmtBytes(v)}${r.wal_since_segments != null ? ` (${fmtNum(r.wal_since_segments)} files)` : ''}` },
  { key: 'full_stopped_at', label: 'last full', fmt: fmtTime }, { key: 'full_age_h', label: 'full age', num: true, fmt: hours },
  { key: 'backup_count', label: 'listed', num: true }, { key: 'archive_max', label: 'newest WAL in the archive' }, { key: 'read_at', label: 'read', fmt: fmtTime },
];

const backupCols: Col[] = [
  { key: 'tool' }, { key: 'name', label: 'stanza / server' }, { key: 'label' }, { key: 'backup_type', label: 'kind' }, { key: 'status', fmt: stateBadge },
  { key: 'started_at', label: 'started', fmt: fmtTime }, { key: 'stopped_at', label: 'ended', fmt: fmtTime }, { key: 'duration_s', label: 'took', num: true, fmt: fmtSecs },
  { key: 'db_size_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'backup_bytes', label: 'copied', num: true, fmt: fmtBytes },
  { key: 'repo_bytes', label: 'in the repository', num: true, fmt: fmtBytes }, { key: 'wal_start', label: 'first WAL' }, { key: 'wal_stop', label: 'last WAL' },
  { key: 'wal_since_bytes', label: 'WAL since', num: true, fmt: fmtBytes }, { key: 'prior', label: 'based on' }, { key: 'retention_status', label: 'retention' },
];

const checkCols: Col[] = [{ key: 'severity', fmt: sev }, { key: 'check_name', label: 'check' }, { key: 'object' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime }];

export async function pgBackupsView(ctx: Ctx): Promise<HTMLElement> {
  const id = ctx.instance!;
  const box = el('div');
  const draw = async () => {
    const d = await get<Parts<'detect' | 'tools' | 'backups' | 'replay' | 'checks' | 'thresholds'>>('pg/backups', { instance: id });
    const det = rowsOf(d.detect)[0], tools = rowsOf(d.tools), rep = rowsOf(d.replay)[0], checks = rowsOf(d.checks);
    const name = String((await fleet()).instances.find(r => Number(r.instance_id) === id)?.name ?? id);
    const out: HTMLElement[] = [el('h2', {}, 'Base backups')];
    if (!det) out.push(el('p', { class: 'meta' }, 'Not read yet: the backup_tools collection runs every 15 minutes on a self-managed server (RDS and Aurora: the Backups tab).'));
    else out.push(el('p', { class: 'meta' }, tools.length
      ? `The server's ${tools.map(t => String(t.tool)).filter((v, i, a) => a.indexOf(v) === i).join(' and ')} read from the collector's host ${fmtTime(det.snapshot_at)}.`
      : `Neither archive_command nor restore_command names pgBackRest or barman (read ${fmtTime(det.snapshot_at)}): no base backups to read. The WAL archiver is on the Backups tab.`));
    const crit = checks.filter(c => c.severity === 'critical').length;
    out.push(el('div', { class: 'tiles' },
      tile('tools read', String(tools.length)),
      tile('newest full backup', ((ages: number[]) => !tools.length ? '-' : ages.length ? hours(Math.min(...ages)) : 'none listed')(tools.map(t => num(t.full_age_h)).filter(x => !isNaN(x)))),
      tile('rules hit', String(checks.length), crit ? 'crit' : checks.length ? 'warn' : 'ok')));
    if (checks.length) out.push(el('section', {}, el('h3', {}, 'Rules hit'), grid(checks, checkCols)));
    if (tools.length) out.push(el('section', {}, el('h3', {}, 'By tool'), grid(tools, toolCols)));
    const bk = rowsOf(d.backups);
    if (bk.length) out.push(el('section', {}, el('h3', {}, `Backups listed (${bk.length})`), grid(bk, backupCols)));
    if (rep) {
      const fileFed = rep.has_receiver === false;
      out.push(el('section', {}, el('h3', {}, fileFed ? 'Log shipping: replay without a WAL receiver' : 'Standby replay'),
        props([
          ['WAL receiver', rep.has_receiver ? 'running (streaming: the Replication tab has its lag)' : 'none: fed by restore_command alone'],
          ['restore_command', rep.restore_command_set ? 'set' : 'not set'],
          ['last replayed commit', fmtTime(rep.last_replay_at)],
          ['replay delay', rep.replay_delay_secs == null ? '' : fmtSecs(Math.round(num(rep.replay_delay_secs)))],
          ['replay position', String(rep.replay_lsn ?? '')],
          ['paused', rep.replay_paused == null ? '' : rep.replay_paused ? 'yes' : 'no'],
          ['primary in the fleet', rep.primary_instance ? `${String(rep.primary_instance)} (last archived ${String(rep.primary_last_archived ?? '-')})` : 'not found (no instance with the same system identifier)'],
          ['caught up with its archive', rep.caught_up == null ? '' : rep.caught_up ? 'yes: nothing archived is left to replay' : 'no'],
          ['threshold', thresholdLine({ warn: rep.warn_min, crit: rep.crit_min, unit: 'minutes', direction: 'over', level: rep.threshold_level })],
        ])));
    }
    out.push(await thresholdsSection(rowsOf(d.thresholds), id, name, () => void draw()));
    box.replaceChildren(...out);
  };
  await draw();
  return box;
}

// pgBaseBackupsFleetSection: every self-managed instance's base backups by tool and every standby's replay.
export async function pgBaseBackupsFleetSection(ctx: Ctx): Promise<HTMLElement> {
  const [d, ids] = await Promise.all([get<Parts<'tools' | 'replay'>>('pg/backups/fleet', {}), tagIds(ctx)]);
  const keep = (r: Row) => !ids || ids.has(Number(r.instance_id));
  const tools = rowsOf(d.tools).filter(keep), rep = rowsOf(d.replay).filter(keep);
  const cols: Col[] = [
    { key: 'instance', fmt: (v, r) => instLink(ctx, v, r.instance_id, 'pgbackups') }, { key: 'tool' }, { key: 'name', label: 'stanza / server' },
    { key: 'state', fmt: stateBadge }, { key: 'worst', label: 'rules', fmt: v => v == null ? badge('ok', 'ok') : sev(v) },
    { key: 'last_label', label: 'last backup' }, { key: 'last_type', label: 'kind' }, { key: 'last_age_h', label: 'age', num: true, fmt: hours },
    { key: 'full_age_h', label: 'full age', num: true, fmt: hours }, { key: 'last_db_size_bytes', label: 'size', num: true, fmt: fmtBytes },
    { key: 'wal_since_bytes', label: 'WAL since', num: true, fmt: fmtBytes }, { key: 'message', wide: true },
  ];
  const rcols: Col[] = [
    { key: 'instance', fmt: (v, r) => instLink(ctx, v, r.instance_id, 'pgbackups') }, { key: 'has_receiver', label: 'receiver', fmt: v => v ? 'streaming' : 'none (file shipping)' },
    { key: 'replay_delay_secs', label: 'replay delay', num: true, fmt: v => v == null ? '' : fmtSecs(Math.round(num(v))) },
    { key: 'caught_up', label: 'caught up', fmt: v => yes(v) }, { key: 'primary_instance', label: 'primary' }, { key: 'replay_paused', label: 'paused', fmt: v => v ? badge('paused', 'warn') : '' },
    { key: 'last_replay_at', label: 'last replayed commit', fmt: fmtTime },
  ];
  return el('section', {}, el('h2', {}, 'Base backups (pgBackRest, barman)'),
    el('p', { class: 'meta' }, `${tools.length} tool read(s) on ${new Set(tools.map(t => t.instance_id)).size} instance(s); ${rep.length} standby(s).`),
    grid(tools, cols, 'No self-managed server names pgBackRest or barman in its archive_command or restore_command.'),
    el('h3', {}, 'Standbys: replay'), grid(rep, rcols, 'No standby read yet.'));
}

// ---- Server state tab ------------------------------------------------------------------------------------

const changeCols = (ctx: Ctx, withInstance: boolean): Col[] => [
  ...(withInstance ? [{ key: 'instance', fmt: (v: unknown, r: Row) => instLink(ctx, v, r.instance_id, 'pgstate') } as Col] : []),
  { key: 'changed_at', label: 'when', fmt: fmtTime }, { key: 'changed_at_source', label: 'time from' },
  { key: 'change', fmt: v => badge(String(v), v === 'promotion' || v === 'demotion' ? 'warn' : v === 'another cluster' ? 'crit' : '') },
  { key: 'from_role', label: 'from' }, { key: 'to_role', label: 'to' }, { key: 'from_timeline', label: 'timeline before', num: true }, { key: 'to_timeline', label: 'timeline', num: true },
  { key: 'postmaster_restarted', label: 'restarted', fmt: v => v ? 'yes' : 'no' },
  { key: 'held_secs', label: 'role held for', num: true, fmt: v => v == null ? 'since before the first read' : fmtSecs(v) },
  { key: 'prev_read_at', label: 'between the reads of', fmt: (v, r) => `${fmtTime(v)} and ${fmtTime(r.detected_at)}` },
];

export async function pgStateView(ctx: Ctx): Promise<HTMLElement> {
  const id = ctx.instance!;
  const box = el('div');
  const draw = async () => {
    const [d, ad, f] = await Promise.all([
      get<Parts<'role' | 'changes' | 'crashes' | 'crash_state' | 'stmt' | 'uptime' | 'amcheck' | 'patroni' | 'checks' | 'thresholds'>>('pg/state', { instance: id }),
      loadAckSafe(['acks']), fleet()]);
    const name = String(f.instances.find(r => Number(r.instance_id) === id)?.name ?? id);
    const role = rowsOf(d.role)[0], cs = rowsOf(d.crash_state)[0], st = rowsOf(d.stmt)[0], up = rowsOf(d.uptime)[0];
    const out: HTMLElement[] = [el('h2', {}, 'Server state')];
    const checks = rowsOf(d.checks);
    if (checks.length) out.push(el('section', {}, el('h3', {}, 'Rules hit'), grid(checks, checkCols)));
    // role and timeline
    out.push(el('section', {}, el('h3', {}, 'Role'), role ? props([
      ['role', role.is_replica ? 'standby (in recovery)' : 'primary'],
      ['timeline', `${String(role.timeline_id ?? '?')} (from the ${String(role.timeline_source || 'nowhere: not readable')})`],
      ['in this role since', role.since ? `${fmtTime(role.since)} (${String(role.since_source)})` : `before the first read, ${fmtTime(role.first_read_at)}`],
      ['system identifier', String(role.system_identifier ?? 'not readable (pg_control_system)')],
      ['cluster_name', String(role.cluster_name ?? '')],
      ['newest timeline history file', role.history_file ? `${String(role.history_file)}, ${fmtTime(role.history_at)}` : 'none in pg_wal (or not readable)'],
      ['read', fmtTime(role.read_at)],
    ]) : el('p', { class: 'meta' }, 'Not read yet (the rolechange collection, every minute).')));
    const ch = rowsOf(d.changes);
    out.push(el('section', {}, el('h3', {}, `Role changes (${ch.length})`), grid(ch, changeCols(ctx, false), 'No role change seen since pgvigil first read the server.')));
    const pat = rowsOf(d.patroni).filter(r => r.member != null);
    if (rowsOf(d.patroni).length) {
      const p0 = rowsOf(d.patroni)[0];
      out.push(el('section', {}, el('h3', {}, 'Patroni'), el('p', { class: 'meta' }, p0.ok ? `${String(p0.url)}: scope ${String(pat[0]?.scope ?? '')}` : `${String(p0.url)}: ${String(p0.message ?? 'no answer')}`),
        grid(pat, [{ key: 'member' }, { key: 'role' }, { key: 'state' }, { key: 'host' }, { key: 'port', num: true }, { key: 'timeline', num: true },
          { key: 'lag_bytes', label: 'lag', num: true, fmt: (v, r) => v == null ? String(r.lag_text ?? '') : fmtBytes(v) }], 'No member listed.')));
    }
    // crashes
    const crashes = rowsOf(d.crashes);
    const ackCol: Col = { key: 'ack_id', label: 'acknowledged', fmt: (v, r) => {
      if (v != null) return `by ${String(r.acked_by)} ${fmtTime(r.acked_at)}`;
      // the store clears every crash up to this acknowledgement (0103's pg_crashes) and a newer one opens the cell again;
      // until_change with a state no cell ever reads keeps the Summary's own greying out of it
      const body: AckBody = { kind: 'ack', instance_id: id, check_key: 'dumps', seen_state: `crash ${String(r.at)}`, until_change: true };
      return writeButton(ad, 'Acknowledge', `Acknowledge the crash of ${fmtTime(r.at)} on ${name}`, () => ackDialog({
        title: `Acknowledge the crash of ${fmtTime(r.at)}`,
        what: `The Summary's Crashes cell of ${name} loses this crash and every one before it; a newer crash colours it again. Who and when are kept.`,
        body, expiry: false, noteField: 'optional', after: () => void draw() }));
    } };
    out.push(el('section', {}, el('h3', {}, 'Crash restarts (30 days)'),
      cs ? el('p', { class: 'meta' }, `${fmtNum(cs.crashes_30d)} crash restart(s), ${fmtNum(cs.open_30d)} not acknowledged; the cell: ${String(cs.status)} (a crash within the hours: ${thresholdLine({ warn: cs.warn_h, crit: cs.crit_h, unit: 'hours', direction: 'under', level: cs.threshold_level })}).`) : '',
      grid(crashes, [{ key: 'at', label: 'when', fmt: fmtTime }, { key: 'signal', num: true }, { key: 'detail', wide: true }, { key: 'lines', label: 'log lines', num: true }, ackCol],
        'No crash restart in the server log of 30 days (the log reader must run: Logs tab).')));
    // statement store
    if (st) out.push(el('section', {}, el('h3', {}, 'Statement store (pg_stat_statements)'), props([
      ['available', yes(st.available) as Node], ['preloaded', yes(st.preloaded) as Node], ['created in a database read', yes(st.created) as Node],
      ['track', String(st.track ?? '')], ['max', st.max_entries == null ? '' : fmtNum(st.max_entries)],
      ['entries kept', `${fmtNum(st.entries)}${st.max_entries ? ` (${Math.round(100 * num(st.entries) / num(st.max_entries))} % of max)` : ''}`],
      ['evictions (dealloc) in 24 h', st.dealloc_24h == null ? 'not read (PostgreSQL 14 or later)' : num(st.dealloc_24h) > 0 ? badge(fmtNum(st.dealloc_24h), 'warn') : '0'],
      ['evictions since the reset', st.dealloc == null ? '' : fmtNum(st.dealloc)],
      ['last reset', fmtTime(st.stats_reset)], ['track_utility', String(st.track_utility ?? '')],
    ])));
    // uptime and amcheck
    if (up) out.push(el('section', {}, el('h3', {}, 'Uptime'), props([
      ['started', fmtTime(up.postmaster_start)], ['up for', hours(up.uptime_h)],
      ['state', sev(up.status === 'ok' ? '' : up.status)], ['thresholds', thresholdLine({ warn: up.warn_h, crit: up.crit_h, unit: 'hours', direction: 'under', level: up.threshold_level })],
    ])));
    const am = rowsOf(d.amcheck);
    const keys = await thresholdKeys().catch(() => [] as Row[]);
    const amKey = keys.find(k => k.key === 'amcheck_age');
    out.push(el('section', {}, el('h3', {}, 'amcheck: the last clean run per database'),
      grid(am, [{ key: 'datname', label: 'database' }, { key: 'last_ok_at', label: 'last clean run', fmt: v => v == null ? 'never' : fmtTime(v) },
        { key: 'age_days', label: 'age', num: true, fmt: v => v == null ? '' : `${fmtNum(v)} d` }, { key: 'last_status', label: 'newest run' },
        { key: 'threshold_level', label: 'thresholds', fmt: (v, r) => thresholdLine({ warn: r.warn_days, crit: r.crit_days, unit: 'days', direction: 'over', level: v }) },
        { key: 'datname', label: '', fmt: (v, r) => {
          if (!amKey) return '';
          const b = el('button', { type: 'button', class: 'link', 'aria-label': `Change the amcheck threshold of ${String(v)}` }, 'Change');
          b.addEventListener('click', () => thresholdDialog(amKey, { level: 'database', instance_id: id, datname: String(v), where: `the database ${String(v)} of ${name}` },
            { warn: r.warn_days, crit: r.crit_days, level: r.threshold_level }, () => void draw()));
          return b;
        } }], 'No database read yet.')));
    out.push(await thresholdsSection(rowsOf(d.thresholds), id, name, () => void draw()));
    box.replaceChildren(...out);
  };
  await draw();
  return box;
}

// ---- fleet Replication page ------------------------------------------------------------------------------

export async function pgReplicationFleetView(ctx: Ctx): Promise<HTMLElement> {
  const [d, ids] = await Promise.all([get<Parts<'links' | 'patroni' | 'changes'>>('pg/replication', {}), tagIds(ctx)]);
  const keep = (r: Row) => !ids || ids.has(Number(r.instance_id));
  const links = rowsOf(d.links).filter(keep), pat = rowsOf(d.patroni).filter(keep), ch = rowsOf(d.changes).filter(keep);
  const clusters = new Map<string, Row[]>();
  for (const r of links) {
    const k = String(r.system_identifier ?? `instance ${String(r.instance_id)}`);
    clusters.set(k, [...(clusters.get(k) ?? []), r]);
  }
  const cols: Col[] = [
    { key: 'instance', fmt: (v, r) => instLink(ctx, v, r.instance_id, 'replication') },
    { key: 'role', fmt: v => badge(String(v), v === 'primary' ? 'ok' : '') }, { key: 'timeline_id', label: 'timeline', num: true },
    { key: 'role_since', label: 'role since', fmt: fmtTime },
    { key: 'has_receiver', label: 'fed by', fmt: (v, r) => r.role === 'primary' ? '' : v ? `streaming from ${String(r.sender_host ?? '?')}` : 'restore_command (file shipping)' },
    { key: 'sync_state', label: 'sync', fmt: v => v == null ? '' : badge(String(v), v === 'sync' || v === 'quorum' ? 'ok' : '') },
    { key: 'sender_state', label: 'sender' },
    { key: 'replay_lag_bytes', label: 'replay lag', num: true, fmt: (v, r) => v == null ? '' : `${fmtBytes(v)}${r.replay_lag_secs != null ? `, ${fmtSecs(Math.round(num(r.replay_lag_secs)))}` : ''}` },
    { key: 'replay_delay_secs', label: 'replay delay', num: true, fmt: v => v == null ? '' : fmtSecs(Math.round(num(v))) },
    { key: 'slot_name', label: 'slot' }, { key: 'slot_retained_bytes', label: 'slot keeps', num: true, fmt: fmtBytes },
    { key: 'patroni_role', label: 'Patroni', fmt: (v, r) => v == null ? '' : `${String(v)} / ${String(r.patroni_state ?? '')}` },
    { key: 'changes_30d', label: 'role changes 30 d', num: true },
  ];
  const out: HTMLElement[] = [el('h2', {}, 'Replication'),
    el('p', { class: 'meta' }, `${clusters.size} cluster(s) by system identifier, ${links.length} member(s) in the fleet. A standby's sender row is the primary's pg_stat_replication row named by the standby's cluster_name or instance name, or its slot.`)];
  for (const [k, rows] of clusters) {
    const pri = rows.filter(r => r.role === 'primary');
    out.push(el('section', {}, el('h3', {}, `${String(rows[0].cluster ?? 'cluster')} (system ${k})`),
      el('p', { class: 'meta' }, pri.length === 1 ? `primary ${String(pri[0].instance)}, ${rows.length - 1} standby(s)` : pri.length ? `${pri.length} primaries: a split cluster or a standby not yet read` : 'no primary in the fleet'),
      grid(rows, cols)));
  }
  if (!clusters.size) out.push(el('p', { class: 'meta' }, 'No instance read by the rolechange collection yet.'));
  if (pat.length) out.push(el('section', {}, el('h3', {}, 'Patroni'),
    grid(pat, [{ key: 'scope' }, { key: 'instance', label: 'read through', fmt: (v, r) => instLink(ctx, v, r.instance_id, 'pgstate') }, { key: 'ok', label: 'answered', fmt: v => yes(v) },
      { key: 'member_list', label: 'members', wide: true, fmt: v => Array.isArray(v) ? v.map((m: Row) => `${String(m.member)} ${String(m.role)} ${String(m.state)}${m.lag_bytes != null ? ` lag ${fmtBytes(m.lag_bytes)}` : ''}`).join('; ') : '' },
      { key: 'message', wide: true }, { key: 'snapshot_at', label: 'read', fmt: fmtTime }])));
  out.push(el('section', {}, el('h3', {}, `Role changes (${ch.length})`), grid(ch, changeCols(ctx, true), 'No role change seen in the fleet.')));
  return el('div', {}, ...out);
}

// ---- fleet Thresholds page -------------------------------------------------------------------------------

export async function pgThresholdsView(ctx: Ctx): Promise<HTMLElement> {
  const box = el('div');
  const draw = async () => {
    keysCache = null;
    const d = await get<Parts<'keys' | 'rows' | 'tags' | 'instances'>>('pg/thresholds', {});
    const keys = rowsOf(d.keys), rows = rowsOf(d.rows), tags = rowsOf(d.tags).map(r => String(r.tag)), insts = rowsOf(d.instances);
    keysCache = keys;
    const out: HTMLElement[] = [el('h2', {}, 'Thresholds'),
      el('p', { class: 'meta' }, 'PostgreSQL state thresholds: the root applies to every instance, a tag to its instances (the first of an instance\'s tags in sort order that has a row), an instance to itself, a database to one database (amcheck). The nearest level wins; with none, the built-in default.')];
    const keyCols: Col[] = [
      { key: 'label', label: 'threshold' }, { key: 'unit' },
      { key: 'warn_default', label: 'built in', fmt: (_v, r) => thresholdLine({ ...r, warn: r.warn_default, crit: r.crit_default, level: 'default' }) },
      { key: 'key', label: 'root', fmt: (v, r) => {
        const own = rows.find(x => x.key === v && x.level === 'root');
        const b = el('button', { type: 'button', class: 'link', 'aria-label': `Change ${String(v)} at the root` }, own ? thresholdLine({ ...own, unit: r.unit, direction: r.direction }) : 'Set');
        b.addEventListener('click', () => thresholdDialog(r, { level: 'root', where: 'the root (every instance)' }, own ? { ...own } : undefined, () => void draw()));
        return b;
      } },
    ];
    out.push(el('section', {}, el('h3', {}, 'Keys'), grid(keys, keyCols)));
    // one more level: pick a key, a level and its place
    const kSel = el('select', { 'aria-label': 'threshold' }, ...keys.map(k => el('option', { value: String(k.key) }, String(k.label))));
    const lSel = el('select', { 'aria-label': 'level' });
    const pSel = el('select', { 'aria-label': 'where' });
    const db = el('input', { type: 'text', 'aria-label': 'database', placeholder: 'database', maxlength: '63', style: 'width:10rem' });
    const fill = () => {
      const k = keys.find(x => x.key === kSel.value);
      const lv = (Array.isArray(k?.levels) ? k!.levels as string[] : []).filter(l => l !== 'root');
      lSel.replaceChildren(...lv.map(l => el('option', { value: l }, l)));
      fillPlace();
    };
    const fillPlace = () => {
      const l = lSel.value;
      pSel.replaceChildren(...(l === 'tag' ? tags.map(t => el('option', { value: t }, t)) : insts.map(i => el('option', { value: String(i.instance_id) }, String(i.name)))));
      db.hidden = l !== 'database';
    };
    kSel.addEventListener('change', fill); lSel.addEventListener('change', fillPlace); fill();
    const open = el('button', { type: 'button' }, 'Set...');
    open.addEventListener('click', () => {
      const k = keys.find(x => x.key === kSel.value); if (!k) return;
      const l = lSel.value as ThresholdPlace['level'];
      const place: ThresholdPlace = l === 'tag' ? { level: 'tag', tag: pSel.value, where: `the tag ${pSel.value}` }
        : { level: l, instance_id: Number(pSel.value), datname: l === 'database' ? db.value.trim() : undefined,
            where: `${l === 'database' ? `the database ${db.value.trim()} of ` : 'the instance '}${pSel.selectedOptions[0]?.textContent ?? ''}` };
      const own = rows.find(x => x.key === k.key && x.level === l && (l === 'tag' ? x.tag === place.tag : Number(x.instance_id) === place.instance_id && (l !== 'database' || x.datname === place.datname)));
      thresholdDialog(k, place, own, () => void draw());
    });
    out.push(el('section', {}, el('h3', {}, 'A tag, an instance or a database'), el('p', {}, kSel, ' ', lSel, ' ', pSel, ' ', db, ' ', open)));
    const rowCols: Col[] = [
      { key: 'label', label: 'threshold' }, { key: 'level' },
      { key: 'instance', label: 'where', fmt: (v, r) => r.level === 'tag' ? `tag ${String(r.tag)}` : r.level === 'root' ? 'every instance' : `${String(v ?? '')}${r.datname ? ' / ' + String(r.datname) : ''}` },
      { key: 'warn', label: 'warning', num: true, fmt: (v, r) => v == null ? '' : `${fmtNum(v)} ${String(r.unit)}` }, { key: 'crit', label: 'critical', num: true, fmt: (v, r) => v == null ? '' : `${fmtNum(v)} ${String(r.unit)}` },
      { key: 'created_by', label: 'set by' }, { key: 'created_at', label: 'set', fmt: fmtTime },
    ];
    out.push(el('section', {}, el('h3', {}, `Set levels (${rows.length})`), grid(rows, rowCols, 'Nothing is set: every instance takes the built-in defaults.')));
    if (ctx.tag) out.push(el('p', { class: 'meta' }, `The tag folder ${ctx.tag} is in view: the page lists the whole fleet's levels.`));
    box.replaceChildren(...out);
  };
  await draw();
  return box;
}
