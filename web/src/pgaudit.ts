// The Audit tab of a PostgreSQL instance (task 157): pgaudit as the pgaudit collection reads it every minute.
// Health: whether the library is loaded, what pgaudit.log and pgaudit.role say at the server, on a database and on a
// role, whether parameters reach the log, where the log goes and whether pgvigil reads the audit lines from it.
// Events: the ROLE and DDL entries and the SETs that matter to an audit as rows (who, when, database, command,
// object), the failed sign-ins the log readers keep, and every other entry (READ, WRITE, FUNCTION, MISC, the other
// SETs) as counts per role, object and hour. A statement's text is shown only where the instance keeps it
// (audit_text: true in its configuration). Data from /api/pgaudit; the tab and its place in the tree are the
// shell's (router.ts, main.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { findingCols } from './memory';
import { sqlCell } from './sqlview';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';

type AuditParts = 'health' | 'settings' | 'databases' | 'findings' | 'rules' | 'events' | 'signins' | 'counts' | 'hours';

// auditKind: the status cell's colour class (off has none: the badge's own muted colour)
export const auditKind = (status: unknown): string => status === 'warning' ? 'warn' : status === 'ok' ? 'ok' : '';

// auditCell: the status cell as the Audit tab and a fleet grid show it
export function auditCell(h: Row | undefined): HTMLElement | string {
  if (!h) return '';
  return badge(String(h.cell ?? ''), auditKind(h.status));
}

// readAuditFleet: one row per PostgreSQL instance the collection has read (a fleet grid's Audit column)
export async function readAuditFleet(): Promise<Row[]> {
  const d = await get<{ instances: Table | null }>('pgaudit', {});
  return rowsOf(d.instances);
}

// auditFleetCell: the fleet Summary's Audit cell of a PostgreSQL instance from its readAuditFleet row: the colour from
// the health's status (warning: set but not loaded, or loaded and logging nothing; off: not loaded and nothing set, read
// and OK as the SQL Server cell's 'none' is - no audit asked for is not a fault), the text the Audit tab's status cell
// shows; no row = no read to judge; failed = the fleet read itself failed (never 'not yet' then)
export interface AuditFleetCell { level: 0 | 1; text: string; detail: string[]; none: boolean }
export function auditFleetCell(h: Row | undefined, failed: boolean): AuditFleetCell {
  if (failed) return { level: 0, text: 'read failed', detail: ['the read of the pgaudit cells failed (GET /api/pgaudit): this is not the instance\'s state'], none: true };
  if (!h) return { level: 0, text: 'not yet', detail: ['no pgaudit read stored for the instance yet (the pgaudit collection)'], none: true };
  const detail = [`pgaudit: ${String(h.cell ?? '')}`];
  if (h.log_read === 'not read') detail.push(`the audit lines are not read from the server log${h.log_read_reason ? ': ' + String(h.log_read_reason) : ''}`);
  const nf = Number(h.findings ?? 0);
  if (nf > 0) detail.push(`${nf} finding${nf === 1 ? '' : 's'} on the Audit tab`);
  if (h.snapshot_at != null) detail.push(`read ${fmtTime(h.snapshot_at)}`);
  return { level: h.status === 'warning' ? 1 : 0, text: String(h.cell ?? ''), detail, none: false };
}

const where = (r: Row): string =>
  r.scope === 'server' ? 'server' : r.scope === 'database' ? `database ${String(r.datname ?? '')}`
    : r.scope === 'role' ? `role ${String(r.rolname ?? '')}` : `role ${String(r.rolname ?? '')} in ${String(r.datname ?? '')}`;

const settingCols: Col[] = [
  { key: 'scope', label: 'set at', fmt: (_, r) => where(r) },
  { key: 'name', label: 'setting' },
  { key: 'value' },
  { key: 'source', label: 'source (server)' },
];

const dbCols: Col[] = [
  { key: 'datname', label: 'database' },
  { key: 'created', label: 'pgaudit extension', fmt: v => v ? 'created' : badge('not created', 'warn') },
  { key: 'version' },
  { key: 'read_at', label: 'read', fmt: fmtTime },
];

const windowText = (m: unknown): string => {
  const n = Number(m);
  return n % 1440 === 0 ? `${n / 1440} d` : n % 60 === 0 ? `${n / 60} h` : `${n} min`;
};

const ruleCols: Col[] = [
  { key: 'fires', label: 'state', fmt: (v, r) => !r.is_enabled ? badge('off', '') : v ? badge('firing', r.severity === 'critical' ? 'crit' : r.severity === 'info' ? '' : 'warn') : 'quiet' },
  { key: 'name', label: 'rule' },
  { key: 'what', label: 'entries', fmt: (v, r) => (v === 'AUTH_FAIL' ? 'failed sign-ins' : String(v))
      + (r.command_like ? `, command like ${String(r.command_like)}` : '') + (r.object_like ? `, object like ${String(r.object_like)}` : '') },
  { key: 'min_count', label: 'fires at', num: true },
  { key: 'window_minutes', label: 'within', fmt: windowText },
  { key: 'severity' },
  { key: 'hits', label: 'in its window now', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'last_at', label: 'newest', fmt: fmtTime },
  { key: 'note', wide: true },
];

const eventCols = (text: boolean): Col[] => [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'usename', label: 'who' },
  { key: 'datname', label: 'database' },
  { key: 'class' },
  { key: 'command' },
  { key: 'object_type', label: 'object type' },
  { key: 'object_name', label: 'object' },
  { key: 'target_role', label: 'role named' },
  { key: 'client' },
  { key: 'audit_type', label: 'audit' },
  ...(text ? [
    { key: 'statement', wide: true, fmt: (v: unknown) => sqlCell(v, { heading: 'Audited statement' }) },
    { key: 'parameters', wide: true },
  ] as Col[] : []),
];

const signinCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'usename', label: 'who' },
  { key: 'datname', label: 'database' },
  { key: 'client' },
  { key: 'detail', label: 'message', wide: true },
];

const countCols: Col[] = [
  { key: 'usename', label: 'role' },
  { key: 'datname', label: 'database' },
  { key: 'class' },
  { key: 'command' },
  { key: 'object_type', label: 'object type' },
  { key: 'object_name', label: 'object' },
  { key: 'entries', num: true },
  { key: 'first_hour', label: 'first hour', fmt: fmtTime },
  { key: 'last_hour', label: 'last hour', fmt: fmtTime },
];

// hoursByClass: the hourly counts as one row per hour with a column per class, for the chart. An hour with no entry
// between the first and the last is a row of zeros (a line drawn across it would read as the hours beside it); total
// is every entry of the window.
export function hoursByClass(hours: Row[]): { rows: Row[]; classes: string[]; total: number } {
  const classes = [...new Set(hours.map(r => String(r.class)))].sort();
  const byHour = new Map<number, Row>();
  let total = 0;
  for (const r of hours) {
    const t = new Date(String(r.snapshot_at)).getTime();
    if (isNaN(t)) continue;
    if (!byHour.has(t)) byHour.set(t, { snapshot_at: r.snapshot_at, ...Object.fromEntries(classes.map(c => [c, 0])) });
    byHour.get(t)![String(r.class)] = Number(r.entries ?? 0);
    total += Number(r.entries ?? 0);
  }
  const times = [...byHour.keys()].sort((a, b) => a - b);
  const HOUR = 3600000;
  if (times.length > 1 && (times[times.length - 1] - times[0]) / HOUR <= 31 * 24) {
    for (let t = times[0] + HOUR; t < times[times.length - 1]; t += HOUR) {
      if (!byHour.has(t)) byHour.set(t, { snapshot_at: new Date(t).toISOString(), ...Object.fromEntries(classes.map(c => [c, 0])) });
    }
  }
  return { rows: [...byHour.entries()].sort((a, b) => a[0] - b[0]).map(e => e[1]), classes, total };
}

function logLine(h: Row): Node {
  if (h.log_read === 'ok') {
    return el('span', {}, `read (${String(h.log_source ?? '')}); the newest entry ${h.last_entry_at ? fmtTime(h.last_entry_at) : 'none yet'}`);
  }
  if (h.log_read === 'off') return el('span', {}, 'nothing to read: pgaudit is not loaded');
  return el('span', {}, badge('not read', 'warn'), ` ${String(h.log_read_reason ?? '')}`);
}

export async function pgauditView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Audit (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<AuditParts, Table | null>>('pgaudit', { instance: ctx.instance, ...window_(ctx) });
    const h = rowsOf(d.health)[0];
    if (!h) {
      sec.append(el('p', { class: 'empty' }, 'The pgaudit collection has not read this instance yet (it runs every minute).'));
      return sec;
    }
    const events = rowsOf(d.events), signins = rowsOf(d.signins), counts = rowsOf(d.counts);
    // the tile's total is the hours' (every entry of the window); the grid below lists the 2,000 largest groups
    const { rows: hourRows, classes, total: counted } = hoursByClass(rowsOf(d.hours));
    sec.append(el('div', { class: 'tiles' },
      tile('pgaudit', String(h.cell ?? ''), auditKind(h.status) === 'warn' ? 'warn' : ''),
      tile('role, DDL and audited SET entries', fmtNum(events.length) + (events.length >= 1000 ? '+' : '')),
      tile('failed sign-ins', fmtNum(signins.length) + (signins.length >= 500 ? '+' : ''), signins.length ? 'warn' : ''),
      tile('counted entries', fmtNum(counted)),
    ));
    sec.append(props([
      ['status', auditCell(h)],
      ['library', (h.loaded ? 'loaded' : 'not loaded') + (h.preload_libraries == null ? '' : ` (shared_preload_libraries: ${String(h.preload_libraries) || 'empty'})`)],
      ['pgaudit.log at the server', String(h.server_log ?? (h.loaded ? 'none' : ''))],
      ['pgaudit.role (object auditing)', String(h.server_role ?? '') || 'not set'],
      ['set on databases and roles', `${fmtNum(h.scoped)} value(s), ${fmtNum(h.scoped_logging)} of them logging`],
      ['parameters in the log', h.parameter_on ? badge('pgaudit.log_parameter on', 'warn') : 'no'],
      ['the server log', String(h.log_where ?? '')],
      ['audit lines', logLine(h)],
      ['statement text kept', h.keep_text ? 'yes (audit_text: true): the text of the entries kept as rows, under the instance\'s query_text policy'
        : 'no: class, command and object only (audit_text: true in the instance\'s configuration keeps it)'],
      ['last read', fmtTime(h.snapshot_at)],
    ]));
    const findings = rowsOf(d.findings);
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, findingCols));

    sec.append(el('h3', {}, 'Settings'),
      el('p', { class: 'meta' }, 'Every pgaudit.* value in force somewhere: the server\'s (as the monitoring session sees them, with their source), '
        + 'and each ALTER DATABASE / ALTER ROLE ... SET. A role\'s or a database\'s value replaces the server\'s for its sessions.'),
      grid(rowsOf(d.settings), settingCols, h.loaded ? 'No pgaudit setting read.' : 'pgaudit is not loaded and nothing sets a pgaudit.* value.'));
    const dbs = rowsOf(d.databases);
    if (h.loaded) {
      sec.append(el('h3', {}, 'The extension per database'),
        el('p', { class: 'meta' }, 'From the extensions collection (hourly). Without CREATE EXTENSION pgaudit a database\'s DDL entries carry no object type and name.'),
        grid(dbs, dbCols, 'The extensions collection has not read this instance yet.'));
    }

    sec.append(el('h3', {}, 'Alert rules'),
      el('p', { class: 'meta' }, 'A rule that fires is a finding of this instance and reaches the alert channels like any other. '
        + 'The rules are rows of pgvigil.pgaudit_rules in the repository (docs/audit.md says how to change one).'),
      grid(rowsOf(d.rules), ruleCols, 'No rule.'));

    sec.append(el('h3', {}, 'Role, DDL and audited SET entries'),
      el('p', { class: 'meta' }, 'pgaudit\'s ROLE and DDL entries, and each SET or RESET of a setting that changes who the session is, what is '
        + 'audited or logged, or what the server enforces (pgaudit.*, every log_* setting, session_authorization to a named role, row_security, '
        + 'session_replication_role, allow_system_table_mods); newest first, 1,000 at most. Where pgaudit names no object the role, '
        + 'the granted object and the setting\'s name are read from the statement; a value is never kept.'),
      grid(events, eventCols(Boolean(h.keep_text) || events.some(r => r.statement != null)),
        h.log_read === 'ok' ? 'No such entry in this window.' : 'The audit lines are not read on this instance.'));

    sec.append(el('h3', {}, 'Failed sign-ins'),
      el('p', { class: 'meta' }, 'From the server log\'s own messages (the log readers), with or without pgaudit; 500 at most.'),
      grid(signins, signinCols, 'No failed sign-in in this window.'));

    sec.append(el('h3', {}, 'Counted entries'),
      el('p', { class: 'meta' }, 'READ, WRITE, FUNCTION and MISC entries and every other SET (MISC_SET, by the setting\'s name; SET ROLE with the role taken) '
        + 'are counted, never kept: per role, database, command and object, by the hour (UTC). '
        + 'A relation is named when pgaudit writes it (pgaudit.log_relation on, or object auditing through pgaudit.role).'));
    if (hourRows.length >= 2) sec.append(lineChart('Audited statements per hour', hourRows, classes.map(c => ({ key: c, label: c }))));
    if (counts.length >= 2000) sec.append(el('p', { class: 'meta' }, 'The 2,000 largest groups are listed; the tile and the chart count every entry.'));
    sec.append(grid(counts, countCols, 'No counted entry in this window.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
