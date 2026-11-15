// The Availability tab of a SQL Server instance (phase 3 wave G, task 98): Always On availability groups as a grid of
// replicas and a grid of database replicas, the queues over the range as a chart with its table behind it, the
// failovers of the range, and database mirroring, log shipping and replication as sections that appear only where
// the server has them. A distributed group is drawn once, over its two member groups and their replicas, from the
// part of the API that looks past this instance. Data from /api/mssql/availability; the lead wires the tab
// (router.ts, main.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';
import { fleet, inTagScope } from './fleet';
import { thresholdDialog, ThresholdPlace } from './pg_backups';

type Parts = 'replicas' | 'databases' | 'distributed' | 'series' | 'failovers' | 'mirroring' | 'logshipping' | 'replication' | 'findings' | 'limits' | 'reads';

export const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');

// the findings grid of the SQL Server tabs (the views' own columns)
export const mssqlFindingCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'finding' }, { key: 'object' },
  { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime },
];

// jsonRows: a jsonb array of objects as grid rows
export function jsonRows(v: unknown): Row[] {
  if (Array.isArray(v)) return v as Row[];
  if (typeof v === 'string') try { const p: unknown = JSON.parse(v); return Array.isArray(p) ? p as Row[] : []; } catch { return []; }
  return [];
}

// words: a state as the server names it (NOT_SYNCHRONIZING) in lower-case words
export const words = (v: unknown) => v == null ? '' : String(v).toLowerCase().replace(/_/g, ' ');
export const yes = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';
const kb = (v: unknown) => v == null ? '' : fmtBytes(Number(v) * 1024);
const kbs = (v: unknown) => v == null ? '' : fmtBytes(Number(v) * 1024) + '/s';

// a state cell is marked by its word AND its colour: never by colour alone
const stateCls = (good: string[], warn: string[] = []) => (v: unknown) =>
  v == null ? '' : good.includes(String(v)) ? '' : warn.includes(String(v)) ? 'warn' : 'crit';

const replicaCols: Col[] = [
  { key: 'group_name', label: 'group' },
  // a distributed group's "replicas" are its two member groups: said in the cell, so a group's name is not read as a server's
  { key: 'replica_server', label: 'replica', fmt: (v, r) => String(v ?? '') + (r.is_distributed === true ? ' (member group)' : '') },
  { key: 'role', fmt: (v, r) => v == null ? 'not visible from here'
    : words(v) + (r.is_local !== true ? '' : r.is_distributed === true ? ' (this server\'s group)' : ' (this server)') },
  { key: 'availability_mode', label: 'commit mode', fmt: words },
  { key: 'failover_mode', label: 'failover', fmt: words },
  { key: 'connected_state', label: 'connected', fmt: words, cls: stateCls(['CONNECTED']) },
  { key: 'synchronization_health', label: 'health', fmt: words, cls: stateCls(['HEALTHY'], ['PARTIALLY_HEALTHY']) },
  { key: 'operational_state', label: 'operational', fmt: words },
  { key: 'secondary_connections', label: 'readable', fmt: words },
  { key: 'seeding_mode', label: 'seeding', fmt: words },
  { key: 'backup_priority', label: 'backup priority', num: true },
  { key: 'endpoint_url', label: 'endpoint' },
  { key: 'last_connect_error_text', label: 'last connect error', wide: true },
];

// dbStateCls: SYNCHRONIZING is the healthy state of an asynchronous-commit replica and amber only on a synchronous one
// (as the finding 'a synchronous replica is not synchronized'); a row whose commit mode is not known (a server without
// that column in its API) leaves SYNCHRONIZING unmarked. Suspended, and any state but the two, is red whatever the mode
// (as the finding 'a database is not synchronizing').
const dbStateCls = (v: unknown, r: Row) => r.is_suspended === true ? 'crit'
  : v == null || v === 'SYNCHRONIZED' ? ''
  : v === 'SYNCHRONIZING' ? (r.availability_mode === 'SYNCHRONOUS_COMMIT' ? 'warn' : '')
  : 'crit';

const dbCols: Col[] = [
  { key: 'group_name', label: 'group' },
  { key: 'database_name', label: 'database' },
  { key: 'replica_server', label: 'replica', fmt: (v, r) => String(v ?? '') + (r.is_primary_replica === true ? ' (primary)' : '') },
  { key: 'synchronization_state', label: 'state', fmt: (v, r) => words(v) + (r.is_suspended === true ? `, suspended${r.suspend_reason ? ' (' + words(r.suspend_reason) + ')' : ''}` : ''),
    cls: dbStateCls },
  { key: 'synchronization_health', label: 'health', fmt: words, cls: stateCls(['HEALTHY'], ['PARTIALLY_HEALTHY']) },
  { key: 'log_send_queue_kb', label: 'send queue', num: true, fmt: kb },
  { key: 'log_send_rate_kb_s', label: 'send rate', num: true, fmt: kbs },
  { key: 'redo_queue_kb', label: 'redo queue', num: true, fmt: kb },
  { key: 'redo_rate_kb_s', label: 'redo rate', num: true, fmt: kbs },
  { key: 'est_data_loss_s', label: 'est. data loss', num: true, fmt: fmtSecs },
  { key: 'est_recovery_s', label: 'est. recovery', num: true, fmt: fmtSecs },
  { key: 'last_commit_at', label: 'last commit', fmt: fmtTime },
  { key: 'last_hardened_at', label: 'last hardened', fmt: fmtTime },
  { key: 'last_received_at', label: 'last received', fmt: fmtTime },
  { key: 'last_redone_at', label: 'last redone', fmt: fmtTime },
];

const seriesCols: Col[] = [
  { key: 'snapshot_at', label: 'time', fmt: fmtTime },
  { key: 'log_send_queue_kb', label: 'send queue', num: true, fmt: kb },
  { key: 'redo_queue_kb', label: 'redo queue', num: true, fmt: kb },
  { key: 'est_recovery_s', label: 'worst est. recovery', num: true, fmt: fmtSecs },
  { key: 'est_data_loss_s', label: 'worst est. data loss', num: true, fmt: fmtSecs },
  { key: 'suspended', label: 'databases suspended', num: true },
];

const failoverCols: Col[] = [
  { key: 'at', label: 'seen at', fmt: fmtTime }, { key: 'group_name', label: 'group' },
  { key: 'old_primary', label: 'primary before' }, { key: 'new_primary', label: 'primary after' },
];

const listenerCols: Col[] = [{ key: 'dns_name', label: 'listener' }, { key: 'port', num: true }, { key: 'ip_configuration', label: 'addresses', wide: true }];
const clusterCols: Col[] = [
  { key: 'member_name', label: 'member' }, { key: 'member_type', label: 'type', fmt: words },
  { key: 'member_state', label: 'state', fmt: words, cls: stateCls(['UP']) }, { key: 'quorum_votes', label: 'votes', num: true },
];

const mirrorCols: Col[] = [
  { key: 'database_name', label: 'database' }, { key: 'role', fmt: words },
  { key: 'state', fmt: words, cls: stateCls(['SYNCHRONIZED'], ['SYNCHRONIZING', 'PENDING_FAILOVER']) },
  { key: 'safety_level', label: 'safety', fmt: words }, { key: 'partner_instance', label: 'partner' },
  { key: 'witness' }, { key: 'witness_state', label: 'witness state', fmt: words },
  { key: 'log_send_queue_kb', label: 'send queue', num: true, fmt: kb }, { key: 'redo_queue_kb', label: 'redo queue', num: true, fmt: kb },
];

const late = (_: unknown, r: Row) => r.threshold_minutes != null && Number(r.threshold_minutes) > 0
  && (r.age_minutes == null || Number(r.age_minutes) > Number(r.threshold_minutes)) ? 'warn' : '';
const shipCols: Col[] = [
  { key: 'role' }, { key: 'database_name', label: 'database' },
  { key: 'primary_server', label: 'primary', fmt: (v, r) => r.role === 'secondary' ? `${String(v ?? '')}.${String(r.primary_database ?? '')}` : String(v ?? '') },
  { key: 'last_backup_at', label: 'last backup', fmt: fmtTime }, { key: 'last_copied_at', label: 'last copy', fmt: fmtTime },
  { key: 'last_restored_at', label: 'last restore', fmt: fmtTime },
  // an empty cell is never filled: a secondary with no restore yet says so in words
  { key: 'age_minutes', label: 'age at the read (min)', num: true, fmt: (v, r) => v == null ? (late(v, r) ? 'none read' : '') : fmtNum(v), cls: late },
  { key: 'threshold_minutes', label: 'threshold (min)', num: true },
  { key: 'alert_enabled', label: 'alert', fmt: yes },
  { key: 'last_restored_file', label: 'last file', wide: true, fmt: (v, r) => String(v ?? r.last_backup_file ?? r.last_copied_file ?? '') },
];

const statusCls = (v: unknown) => v === 6 ? 'crit' : v === 5 ? 'warn' : '';
const pubCols: Col[] = [
  { key: 'publisher' }, { key: 'publisher_db', label: 'database' }, { key: 'publication' },
  { key: 'publication_type', label: 'type' }, { key: 'articles', num: true }, { key: 'distribution_db', label: 'distribution database' },
];
const subCols: Col[] = [
  { key: 'publication' }, { key: 'publisher_db', label: 'from' },
  { key: 'subscriber', fmt: (v, r) => `${String(v ?? '')}.${String(r.subscriber_db ?? '')}` },
  { key: 'subscription_type', label: 'type' }, { key: 'status', cls: (_, r) => statusCls(r.runstatus) },
  { key: 'undistributed', label: 'undistributed commands', num: true },
  { key: 'est_catchup_s', label: 'est. to deliver', num: true, fmt: fmtSecs },
  { key: 'latency_ms', label: 'latency (ms)', num: true }, { key: 'last_run_at', label: 'last report', fmt: fmtTime },
  { key: 'status_text', label: 'message', wide: true },
];
const agentCols: Col[] = [
  { key: 'agent_type', label: 'agent' }, { key: 'agent_name', label: 'name' }, { key: 'publisher_db', label: 'database' },
  { key: 'publication' }, { key: 'status', cls: (_, r) => statusCls(r.runstatus) },
  { key: 'last_run_at', label: 'last report', fmt: fmtTime }, { key: 'status_text', label: 'message', wide: true },
];

// groupKind: what a group is, in words (the catalog's own flags)
function groupKind(r: Row): string {
  const parts: string[] = [];
  if (r.is_distributed === true) parts.push('distributed (its replicas are its two member groups)');
  if (r.is_contained === true) parts.push('contained');
  if (r.cluster_type != null) parts.push(String(r.cluster_type).toLowerCase() === 'none' ? 'clusterless' : `cluster type ${String(r.cluster_type).toLowerCase()}`);
  return parts.join(', ');
}

// state: a connected state and a health in words, marked when either is not the good one (the word carries it, the
// colour only repeats it)
function stateNote(connected: unknown, health: unknown): HTMLElement | null {
  const parts = [connected, health].filter(v => v != null).map(words);
  if (!parts.length) return null;
  const bad = (connected != null && connected !== 'CONNECTED') || (health != null && health !== 'HEALTHY');
  return bad ? badge(parts.join(', '), health === 'PARTIALLY_HEALTHY' && (connected == null || connected === 'CONNECTED') ? 'warn' : 'crit')
    : el('span', { class: 'meta' }, parts.join(', '));
}

// distributedTree: every distributed group the instance is part of as ONE group over its two member groups, each
// member group over its replicas (rows of the API's part "distributed": one per replica of a member group, read from
// the monitored instance that is that member group's primary; a member group whose primary is not monitored comes
// as one row without a replica). The global primary and the forwarder are named as such; a replica that is a
// monitored instance links to its own Availability tab. A member group whose primary's instance was not read in the
// last five minutes says so, with the time of that read: its replicas' states are that read's, not now's.
export function distributedTree(ctx: Ctx, rows: Row[]): HTMLElement {
  const box = el('div', { class: 'dag' });
  // by the group's id: two distributed groups of one name on unrelated servers are two groups
  for (const id of [...new Set(rows.map(r => String(r.dag_id)))]) {
    const mine = rows.filter(r => String(r.dag_id) === id), dag = String(mine[0].dag_name);
    const node = (role: string) => mine.find(r => r.dag_role === role);
    const where = (r: Row | undefined) => r ? `${String(r.replica_server)} (primary of ${String(r.member)})${r.replica_stale === true ? `, as last read ${fmtTime(r.replica_seen_at)}` : ''}`
      : 'not known: no active instance reads the primary of that member group';
    // the oldest read the tree is drawn from, not the newest: one side read a minute ago does not date the other side's rows
    const times = mine.flatMap(r => [r.seen_at, r.replica_seen_at]).filter(v => v != null).map(String).sort();
    box.append(el('h4', {}, `${dag} (distributed availability group)`), props([
      ['global primary', where(node('global primary'))],
      ['forwarder', where(node('forwarder'))],
      ['read', times.length ? (times[0] === times[times.length - 1] ? fmtTime(times[0]) : `between ${fmtTime(times[0])} and ${fmtTime(times[times.length - 1])}`) : ''],
    ]));
    const members = el('ul', {});
    for (const m of [...new Set(mine.map(r => String(r.member)))]) {
      const reps = mine.filter(r => String(r.member) === m), first = reps[0];
      const role = first.member_role == null ? 'role not known' : `${words(first.member_role)} of ${dag}`;
      const stale = reps.some(r => r.replica_stale === true);
      const li = el('li', { 'data-member': m, 'data-member-role': String(first.member_role ?? ''), 'data-stale': String(stale) },
        el('strong', {}, m), ` availability group, ${role}`);
      const link = stateNote(first.member_connected, first.member_health);
      if (link) li.append(', ', link);
      if (first.member_mode != null) li.append(el('span', { class: 'meta' }, `, ${words(first.member_mode)}`));
      if (stale) li.append(' ', badge(`stale: its replicas as last read ${fmtTime(first.replica_seen_at)}`, 'warn'));
      const servers = el('ul', {});
      for (const r of reps) {
        if (r.replica_server == null) continue;
        const name = String(r.replica_server);
        const item = el('li', { 'data-replica': name, 'data-role': String(r.dag_role ?? '') });
        item.append(r.replica_instance_id != null && r.is_this_instance !== true
          ? el('a', { href: href(ctx, { tab: 'availability', instance: Number(r.replica_instance_id) }) }, name) : el('strong', {}, name));
        item.append(` ${String(r.dag_role ?? (r.replica_role == null ? 'role not visible' : words(r.replica_role)))}`);
        if (r.is_this_instance === true) item.append(' (this server)');
        // a stale read's states are that read's: said as such, never drawn as the state now
        const then = [r.replica_connected, r.replica_health].filter(v => v != null).map(words).join(', ');
        const st = r.replica_stale === true ? null : stateNote(r.replica_connected, r.replica_health);
        if (st) item.append(', ', st);
        else if (r.replica_stale === true && then) item.append(el('span', { class: 'meta' }, `, at that read ${then}`));
        if (r.replica_instance_id == null) item.append(el('span', { class: 'meta' }, ', not monitored'));
        servers.append(item);
      }
      if (servers.childElementCount) li.append(servers);
      else li.append(el('p', { class: 'meta' }, `No active instance reads the primary of ${m}${first.member_url ? ` (its listener: ${String(first.member_url)})` : ''}: `
        + 'add it as an instance, or resume it, to see its replicas. A distributed group is listed on the primary of each member group only.'));
      members.append(li);
    }
    box.append(el('ul', { 'data-dag': dag }, el('li', {}, el('strong', {}, dag), members)));
  }
  return box;
}

// hasAvailability: whether the server has an availability group, a mirrored database, log shipping or replication
// (a read that stored a row); the shell's check before it shows the tab
export async function hasAvailability(instance: number): Promise<boolean> {
  const d = await get<Record<'reads', Table | null>>('mssql/availability', { instance, part: 'reads' });
  return rowsOf(d.reads).some(r => Number(r.row_count ?? 0) > 0);
}

export async function mssqlAvailability(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Availability (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<Parts, Table | null>>('mssql/availability', { instance: ctx.instance, ...window_(ctx) });
    const replicas = rowsOf(d.replicas), dbs = rowsOf(d.databases), mirroring = rowsOf(d.mirroring);
    const shipping = rowsOf(d.logshipping), repl = rowsOf(d.replication), reads = rowsOf(d.reads);
    const agRead = reads.find(r => r.collection === 'mssql_ag');

    const findings = rowsOf(d.findings);
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, mssqlFindingCols));

    sec.append(el('h3', {}, 'Availability groups'));
    if (!replicas.length) {
      const why = agRead?.status === 'skipped' ? `mssql_ag is skipped: ${String(agRead.note ?? '')}.`
        : agRead?.status === 'error' ? `mssql_ag failed: ${String(agRead.note ?? '')}.`
        : agRead ? 'The last read found no availability group on this server.'
        : 'mssql_ag has not run on this server yet.';
      sec.append(el('p', { class: 'empty' }, why));
    } else {
      if (agRead?.status === 'skipped' || agRead?.status === 'error') sec.append(el('p', { class: 'meta' }, badge(String(agRead.status), 'warn'),
        ` mssql_ag: ${String(agRead.note ?? '')}. What follows is its last read (${fmtTime(replicas[0].snapshot_at)}).`));
      const groups = [...new Set(replicas.map(r => String(r.group_name)))];
      const notOk = dbs.filter(r => r.is_suspended === true || !['SYNCHRONIZED', 'SYNCHRONIZING'].includes(String(r.synchronization_state))).length;
      const sum = (k: string) => dbs.reduce((s, r) => s + Number(r[k] ?? 0), 0);
      sec.append(el('div', { class: 'tiles' },
        tile('groups', fmtNum(groups.length)),
        tile('replicas not connected', fmtNum(replicas.filter(r => r.connected_state != null && r.connected_state !== 'CONNECTED').length),
          replicas.some(r => r.connected_state != null && r.connected_state !== 'CONNECTED') ? 'crit' : ''),
        tile('databases not synchronizing', fmtNum(notOk), notOk ? 'crit' : ''),
        tile('log waiting to be sent', kb(sum('log_send_queue_kb'))),
        tile('log waiting to be redone', kb(sum('redo_queue_kb'))),
      ));
      // the distributed groups first, each over its member groups; below them every group as this server reads it
      const dist = rowsOf(d.distributed);
      if (dist.length) sec.append(distributedTree(ctx, dist));
      for (const g of groups) {
        const first = replicas.find(r => r.group_name === g)!;
        // a group's name is matched as the API ties it (any case); a member group of two distributed groups names both
        const over = [...new Set(dist.filter(r => String(r.member).toLowerCase() === g.toLowerCase()).map(r => String(r.dag_name)))];
        sec.append(el('h4', {}, g), props([
          ['primary', String(first.primary_replica ?? 'not known') + (first.is_distributed === true ? ' (a member group)' : '')],
          ['kind', groupKind(first) || 'availability group'],
          ...(over.length ? [['member of', `the distributed group${over.length > 1 ? 's' : ''} ${over.join(', ')}`] as [string, string]] : []),
          ['group health', words(first.group_health) || 'not visible from here'],
          ['backup preference', words(first.backup_preference)],
          ['last read', fmtTime(first.snapshot_at)],
        ]));
        const ls = jsonRows(first.listeners);
        if (ls.length) sec.append(el('h5', {}, 'Listeners'), grid(ls, listenerCols));
      }
      sec.append(el('h4', {}, 'Replicas'),
        el('p', { class: 'meta' }, 'A secondary sees only its own replica\'s state; open the primary for every replica. A replica\'s role is what the server '
          + 'reports: on some managed read replicas the reported role is not the whole story, so backups are judged wherever they ran, never by role.'),
        grid(replicas, replicaCols));
      sec.append(el('h4', {}, 'Databases'), grid(dbs, dbCols, 'No database replica is visible from this server.'));
      const cluster = replicas[0].cluster;
      const members = jsonRows(cluster);
      if (members.length) sec.append(el('h4', {}, 'Cluster members'), grid(members, clusterCols));

      const series = rowsOf(d.series);
      // the chart draws bytes (the server reads kilobytes): its numbers carry the unit its axis shows (export.ts chartSection)
      const inBytes = (v: unknown) => v == null ? null : Number(v) * 1024;
      sec.append(lineChart('Log waiting to be sent and to be redone (all database replicas)', series.map(r => ({ ...r, send_bytes: inBytes(r.log_send_queue_kb), redo_bytes: inBytes(r.redo_queue_kb) })), [
        { key: 'send_bytes', label: 'send queue' }, { key: 'redo_bytes', label: 'redo queue' },
      ], v => fmtBytes(v)));
      const det = el('details', {}, el('summary', {}, 'The chart\'s numbers as a table'), grid(series, seriesCols, 'No read in this window.'));
      sec.append(det);
      const lim = rowsOf(d.limits)[0];
      if (lim) sec.append(el('p', { class: 'meta' }, `A finding is raised when a database replica's send queue stays over ${kb(lim.log_send_queue_kb)} `
        + `or its redo queue over ${kb(lim.redo_queue_kb)} in every read of five minutes.`));
      sec.append(el('h4', {}, 'Failovers in this window'), grid(rowsOf(d.failovers), failoverCols, 'No change of a primary was seen in this window.'));
    }

    // the sections below exist only where the server has the feature
    if (mirroring.length) sec.append(el('h3', {}, 'Database mirroring'), grid(mirroring, mirrorCols),
      el('p', { class: 'meta' }, 'Counts, the partner\'s state and the role changes: ', el('a', { href: href(ctx, { tab: 'mssqlmirroring' }) }, 'HA/DR > Mirroring'), '.'));
    if (shipping.length) sec.append(el('h3', {}, 'Log shipping'), grid(shipping, shipCols),
      el('p', { class: 'meta' }, 'Every restoring database judged from restore history: ', el('a', { href: href(ctx, { tab: 'mssqllogshipping' }) }, 'HA/DR > Log Shipping'), '.'));
    if (repl.length) {
      sec.append(el('h3', {}, 'Replication (as this distributor knows it)'),
        el('h4', {}, 'Publications'), grid(repl.filter(r => r.kind === 'publication'), pubCols, 'No publication.'),
        el('h4', {}, 'Subscriptions'), grid(repl.filter(r => r.kind === 'subscription'), subCols, 'No subscription.'),
        el('h4', {}, 'Log reader, snapshot and merge agents'), grid(repl.filter(r => r.kind === 'agent'), agentCols, 'No agent.'));
    }
    // a collection that could not read in full, or at all, says so with its reason; what is shown above is then its last read
    const notOk = reads.filter(r => r.status === 'partial' || r.status === 'error' || (r.status === 'skipped' && r.collection !== 'mssql_ag'));
    for (const r of notOk) sec.append(el('p', { class: 'meta' }, badge(String(r.status), 'warn'),
      ` ${String(r.collection)}: ${String(r.note ?? '')}${r.snapshot_at ? ` (last read ${fmtTime(r.snapshot_at)})` : ''}`));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

// ---- The HA/DR folder's SQL Server pages in DBA Dash's shape (task 383): Availability Groups, Mirroring, Log Shipping,
// each at the root, a tag folder and one instance, from /api/mssql/hadr/fleet (internal/web/q_mssql_hadr.go). The
// columns, their order, colours and drills are DBA Dash 4.25.0's (DBADashGUI/HA/AG.cs, Mirroring.cs, LogShippingView.cs);
// where pgvigil differs the page's note line says how and why. The lead wires the tabs (router.ts, main.ts, fleet.ts).

// ddDuration: DBA Dash's SecondsToHumanDuration - 'DD HH:MM:SS', or '<n> Days' from 100 days on
export function ddDuration(secs: unknown): string {
  if (secs == null || secs === '') return '';
  const n = Math.trunc(Number(secs));
  if (!Number.isFinite(n)) return '';
  const a = Math.abs(n);
  if (a >= 8640000) return `${Math.trunc(n / 86400)} Days`;
  const p2 = (x: number) => String(x).padStart(2, '0');
  return `${n < 0 ? '-' : ''}${p2(Math.trunc(a / 86400))} ${p2(Math.trunc(a / 3600) % 24)}:${p2(Math.trunc(a / 60) % 60)}:${p2(a % 60)}`;
}
// an estimate's words (AvailabilityGroupSummary_Get.sql:83-84): -1 the primary, -2 not known
const estimate = (v: unknown) => v == null ? '' : Number(v) === -1 ? 'None (Primary)' : Number(v) === -2 ? 'Unknown' : ddDuration(v);
// a status cell's colour, DBA Dash's: critical red, warning amber (WarningLow drawn amber, its title says 'low'), OK green
const stCls = (st: unknown) => st === 'critical' ? 'status crit' : st === 'warning' || st === 'warninglow' ? 'status warn' : st === 'ok' ? 'status ok' : '';
// a count column's rule (AG.cs): critical over the limit, OK at 0, nothing between
const countCls = (over: number) => (v: unknown) => Number(v) > over ? 'status crit' : Number(v) === 0 ? 'status ok' : '';
const healthCls = (v: unknown) => v == null ? '' : v === 'HEALTHY' ? 'status ok' : v === 'PARTIALLY_HEALTHY' ? 'status warn' : 'status crit';
const statusWord: Record<string, string> = { critical: 'Critical', warning: 'Warning', warninglow: 'Warning (low)', ok: 'OK', na: 'N/A' };

// the scope of a page: one instance, a tag folder's SQL Server instances, or the fleet
// (a folder holding exactly one SQL Server instance is shown as that instance, as DBA Dash shows Detail when its
// InstanceIDs.Count is 1; one is that instance's id then)
async function hadrScope(ctx: Ctx): Promise<{ params: Record<string, string | number>; folder: boolean; one?: number }> {
  if (ctx.instance) return { params: { instance: ctx.instance }, folder: false, one: ctx.instance };
  const f = await fleet();
  const ids = f.instances.filter(r => r.engine === 'sqlserver' && (!ctx.tag || inTagScope(ctx.tag, r))).map(r => Number(r.instance_id));
  if (ids.length === 1) return { params: { instance: ids[0] }, folder: false, one: ids[0] };
  if (!ctx.tag) return { params: {}, folder: true };
  return { params: { instances: ids.join(',') || '0' }, folder: true };
}

// the Instance drill (AG.cs:694-706, LogShippingView.cs:267-287): the same page at that instance; its Back returns to
// the folder it came from (AG.cs:576-578 'Navigate Back'), kept for the tab in this browser tab only
const backKey = (tab: string) => `pgvigil.hadrBack.${tab}`;
function instLink(ctx: Ctx, tab: string, id: unknown, name: unknown): HTMLElement {
  const a = el('a', { href: href(ctx, { tab, instance: Number(id), tag: undefined }) }, String(name ?? ''));
  a.addEventListener('click', () => { try { sessionStorage.setItem(backKey(tab), location.hash); } catch { /* private window */ } });
  return a;
}
function backButton(ctx: Ctx, tab: string): HTMLElement {
  let to: string | null = null;
  try {
    if (ctx.instance) to = sessionStorage.getItem(backKey(tab));
    else sessionStorage.removeItem(backKey(tab));   // at the folder: a key the browser's own Back left is stale
  } catch { to = null; }
  const b = el('button', { type: 'button', title: 'Navigate Back: the folder this instance was opened from' }, 'Back');
  if (!to) b.setAttribute('disabled', '');
  b.addEventListener('click', () => { try { sessionStorage.removeItem(backKey(tab)); } catch { /* */ } if (to) location.hash = to; });
  return b;
}

// the events range of Role Changes and AlwaysOn Health Events (AG.cs:592-602): DBA Dash's list
// (DateRangeToolStripMenuItem.cs L137-156), 30 Days by default, at least an hour; its date and month pickers are
// pgvigil's Custom from / to. Kept per viewer.
const rangeChoices: [string, number][] = [['1 Hr', 1], ['2 Hr', 2], ['3 Hr', 3], ['6 Hr', 6], ['12 Hr', 12], ['1 Day', 24], ['2 Days', 48],
  ['3 Days', 72], ['7 Days', 168], ['14 Days', 336], ['28 Days', 672], ['30 Days', 720], ['60 Days', 1440], ['90 Days', 2160],
  ['180 Days', 4320], ['1 year', 8784]];
const rangeKey = 'pgvigil.hadrEventsRange';
function eventsRange(onChange: () => void): { node: HTMLElement; params: () => Record<string, string> } {
  let saved = '720';
  try { saved = localStorage.getItem(rangeKey) ?? '720'; } catch { /* private window */ }
  const sel = el('select', { 'aria-label': 'Date range for role changes and AlwaysOn health events' },
    ...rangeChoices.map(([lab, h]) => el('option', { value: String(h) }, lab)), el('option', { value: 'custom' }, 'Custom'));
  sel.value = rangeChoices.some(([, h]) => String(h) === saved) || saved === 'custom' ? saved : '720';
  const from = el('input', { type: 'datetime-local', 'aria-label': 'from' }), to = el('input', { type: 'datetime-local', 'aria-label': 'to' });
  const note = el('span', { class: 'meta', role: 'status' });
  const custom = el('span', {}, ' from ', from, ' to ', to, ' ', note);
  custom.hidden = sel.value !== 'custom';
  const fire = () => { custom.hidden = sel.value !== 'custom'; try { localStorage.setItem(rangeKey, sel.value); } catch { /* */ } onChange(); };
  sel.addEventListener('change', fire); from.addEventListener('change', fire); to.addEventListener('change', fire);
  const params = (): Record<string, string> => {
    note.textContent = '';
    if (sel.value === 'custom') {
      const f = from.value ? new Date(from.value) : null, t = to.value ? new Date(to.value) : null;
      if (f && t && t.getTime() - f.getTime() >= 3600e3) return { from: f.toISOString(), to: t.toISOString() };
      note.textContent = 'Custom needs a from and a to an hour or more apart: the last 30 days are shown.';
      return {};
    }
    const now = Date.now();
    return { from: new Date(now - Number(sel.value) * 3600e3).toISOString(), to: new Date(now).toISOString() };
  };
  return { node: el('label', {}, 'Events ', sel, custom), params };
}

const snapCols = (dateKey: string | null): Col[] => [
  ...(dateKey ? [{ key: dateKey, label: 'Snapshot Date', fmt: fmtTime, cls: (_: unknown, r: Row) => stCls(r.snapshot_status) } as Col] : []),
  { key: 'snapshot_age_secs', label: 'Snapshot Age', num: true, fmt: ddDuration, cls: (_, r) => stCls(r.snapshot_status) },
];

// AG.cs:483-536: the Role Changes grid
function roleChangeCols(ctx: Ctx, tab: string, first: Col[]): Col[] {
  return [
    { key: 'instance', label: 'Instance', fmt: (v, r) => instLink(ctx, tab, r.instance_id, v) },
    ...first,
    { key: 'change', label: 'Change', cls: v => String(v).startsWith('Became') ? 'status warn' : '' },   // DBA Dash's Information rows: uncoloured
    { key: 'previous_role', label: 'Previous Role' }, { key: 'new_role', label: 'New Role' },
    { key: 'changed_after', label: 'Changed After', fmt: fmtTime }, { key: 'changed_before', label: 'Changed Before', fmt: fmtTime },
    { key: 'duration_s', label: 'Duration', num: true, fmt: ddDuration },
    { key: 'failover_type', label: 'Failover Type' }, { key: 'reason', label: 'Reason', wide: true }, { key: 'source', label: 'Source' },
  ];
}

// ---- Availability Groups (AG.cs; AvailabilityGroupSummary_Get / AvailabilityGroup_Get / ...RoleChanges_Get / ...HealthEvents_Get)
export async function mssqlAgView(ctx: Ctx): Promise<HTMLElement> {
  const tab = 'mssqlag';
  const sec = el('section', { class: 'mssql-hadr-ag' }, el('h2', {}, 'Availability Groups'));
  const body = el('div');
  const refresh = el('button', { type: 'button' }, 'Refresh');
  const range = eventsRange(() => void draw());
  const sc = await hadrScope(ctx);
  async function draw() {
    let d: Record<string, Table | null>;
    try { d = await get<Record<string, Table | null>>('mssql/hadr/fleet', { page: 'ag', ...sc.params, ...range.params() }); } catch (e) { body.replaceChildren(errorBox(e)); return; }
    const rc = grid(rowsOf(d.role_changes), roleChangeCols(ctx, tab, [{ key: 'group_name', label: 'Availability Group' }, { key: 'replica_server', label: 'Replica Server' }]),
      'No role change in this range.');
    if (sc.folder) {
      const cols: Col[] = [
        { key: 'instance', label: 'Instance', fmt: (v, r) => instLink(ctx, tab, r.instance_id, v) },
        { key: 'primary_replicas', label: 'Primary Replicas', num: true }, { key: 'secondary_replicas', label: 'Secondary Replicas', num: true },
        { key: 'readable_secondaries', label: 'Readable Secondaries', num: true }, { key: 'async_commit', label: 'Async Commit', num: true },
        { key: 'sync_commit', label: 'Sync Commit', num: true },
        // DBA Dash 4.25.0 writes '> 1' here (AG.cs:73-78); its own 2022 grid coloured it at > 0 (commit ac1e7dcee AG.cs:147), as
        // its twin Remote Not Synchronizing still is: pgvigil follows the 2022 rule (the lead's D3)
        { key: 'not_synchronizing', label: 'Not Synchronizing', num: true, cls: countCls(0) },
        { key: 'synchronizing', label: 'Synchronizing', num: true },
        { key: 'synchronized', label: 'Synchronized', num: true, cls: (_, r) => stCls(r.synchronized_status),
          fmt: (v, r) => r.synchronized_status === 'warninglow' ? el('span', { title: 'Warning (low)', 'aria-label': `${String(v ?? '')}, Warning (low)` }, String(v ?? '')) : String(v ?? '') },
        { key: 'reverting', label: 'Reverting', num: true, cls: countCls(0) }, { key: 'initializing', label: 'Initializing', num: true, cls: countCls(0) },
        { key: 'remote_not_synchronizing', label: 'Remote Not Synchronizing', num: true, cls: countCls(0) },
        { key: 'remote_synchronizing', label: 'Remote Synchronizing', num: true }, { key: 'remote_synchronized', label: 'Remote Synchronized', num: true },
        { key: 'remote_reverting', label: 'Remote Reverting', num: true, cls: countCls(0) },
        { key: 'remote_initializing', label: 'Remote Initializing', num: true, cls: countCls(0) },
        { key: 'sync_health', label: 'Sync Health', cls: healthCls },
        ...snapCols('snapshot_date'),
        { key: 'max_secondary_lag_s', label: 'Max Secondary Lag', num: true, fmt: ddDuration },
        { key: 'max_data_loss_s', label: 'Max Estimated Data Loss', num: true, fmt: estimate },
        { key: 'max_recovery_s', label: 'Max Estimated Recovery Time', num: true, fmt: estimate },
        { key: 'avg_redo_queue_kb', label: 'Avg Redo Queue Size (KB)', num: true }, { key: 'avg_send_queue_kb', label: 'Avg Log Send Queue Size (KB)', num: true },
      ];
      body.replaceChildren(el('h3', {}, 'Availability Group Summary'), grid(rowsOf(d.summary), cols, 'No availability group database on these instances.'),
        el('h3', {}, 'Role Changes'), rc);
    } else {
      const cols: Col[] = [
        { key: 'database_name', label: 'Database' }, { key: 'group_name', label: 'Availability Group' }, { key: 'replica_server', label: 'Replica Server' },
        { key: 'synchronization_state', label: 'Sync State', cls: (_, r) => healthCls(r.synchronization_health) },
        { key: 'synchronization_health', label: 'Sync Health', cls: healthCls },
        { key: 'suspend_reason', label: 'Suspend Reason' }, { key: 'database_state', label: 'Database State' },
        { key: 'is_local', label: 'Is Local', fmt: yes }, { key: 'availability_mode', label: 'Availability Mode' },
        { key: 'failover_mode', label: 'Failover Mode' }, { key: 'is_primary', label: 'Is Primary', fmt: yes },
        { key: 'primary_connections', label: 'Primary Connections' }, { key: 'secondary_connections', label: 'Secondary Connections' },
        ...snapCols('snapshot_date'),
        { key: 'secondary_lag_s', label: 'Secondary Lag', num: true, fmt: (v, r) => r.secondary_lag_words != null ? String(r.secondary_lag_words) : ddDuration(v) },
        { key: 'data_loss_s', label: 'Estimated Data Loss', num: true, fmt: estimate }, { key: 'recovery_s', label: 'Estimated Recovery Time', num: true, fmt: estimate },
        { key: 'redo_queue_kb', label: 'Log Redo Queue Size (KB)', num: true }, { key: 'log_send_queue_kb', label: 'Log Send Queue Size (KB)', num: true },
      ];
      const evCols: Col[] = [
        { key: 'event_at', label: 'Event Time', fmt: fmtTime }, { key: 'event_name', label: 'Event' }, { key: 'ag_name', label: 'Availability Group' },
        { key: 'replica_name', label: 'Replica' }, { key: 'database_name', label: 'Database' }, { key: 'component', label: 'Component' },
        { key: 'previous_state', label: 'Previous State' }, { key: 'current_state', label: 'Current State' },
        { key: 'ddl_action', label: 'DDL Action' }, { key: 'ddl_phase', label: 'DDL Phase' }, { key: 'error_number', label: 'Error Number', num: true },
        { key: 'details', label: 'Details', wide: true },
      ];
      const he = rowsOf(d.health_events);
      body.replaceChildren(el('h3', {}, 'Availability Group Detail'), grid(rowsOf(d.detail), cols, 'No availability group database on this instance.'),
        el('h3', {}, 'Role Changes'), rc, el('h3', {}, 'AlwaysOn Health Events'),
        ...(he.length > 5000 ? [el('p', { class: 'meta', role: 'status' }, 'More than 5000 events in this range: the newest 5000 are shown. Narrow the range to see older ones.')] : []),
        grid(he.slice(0, 5000), evCols, 'No AlwaysOn_health event in this range.'));
    }
  }
  refresh.addEventListener('click', () => void draw());
  sec.append(el('div', { class: 'toolbar' }, refresh, ' ', backButton(ctx, tab), ' ', range.node),
    el('p', { class: 'meta' }, 'Counts are of database replicas, as DBA Dash counts them. Estimated Data Loss is pgvigil\'s own estimate (the commit-time '
      + 'difference, with the last hardened time where that is not read); Not Synchronizing is red from 1, as DBA Dash\'s own grid had it before its '
      + '4.x port; Snapshot Age is coloured as the Collection dates page judges the read. Role changes come from AlwaysOn_health (XE, exact times) or '
      + 'from pgvigil\'s reads (Snapshot, the minute before); a primary left in RESOLVING writes no Snapshot row. Health Events\' Database and Component '
      + 'are empty: pgvigil\'s reader does not store them. DBA Dash\'s Configure Metrics and '
      + 'Trigger Collection are not here: pgvigil stores every read and collects on its own interval.'), body);
  await draw();
  return sec;
}

// ---- Mirroring (Mirroring.cs; DatabaseMirroringSummary_Get / DatabaseMirroring_Get) and its Role Changes (the lead's D1)
export async function mssqlMirroringView(ctx: Ctx): Promise<HTMLElement> {
  const tab = 'mssqlmirroring';
  const sec = el('section', { class: 'mssql-hadr-mirroring' }, el('h2', {}, 'Mirroring'));
  const body = el('div');
  let summary = true;
  const refresh = el('button', { type: 'button' }, 'Refresh');
  const toggle = el('button', { type: 'button' }, 'Detail');
  const range = eventsRange(() => void draw());
  const sc = await hadrScope(ctx);
  const witnessCls = (v: unknown) => v == null ? '' : Number(v) === 1 ? 'status ok' : Number(v) === 2 ? 'status crit' : '';
  const stateCls = (v: unknown, r: Row) => r.values_hidden === true || v == null ? '' : [4, 6].includes(Number(v)) ? 'status ok' : Number(v) === 2 ? 'status warn' : 'status crit';
  async function draw() {
    let d: Record<string, Table | null>;
    try { d = await get<Record<string, Table | null>>('mssql/hadr/fleet', { page: 'mirroring', ...sc.params, ...range.params() }); } catch (e) { body.replaceChildren(errorBox(e)); return; }
    const sumCols: Col[] = [
      { key: 'instance', label: 'Instance' },
      { key: 'principal_count', label: 'Principal Count', num: true }, { key: 'mirror_count', label: 'Mirror Count', num: true },
      { key: 'synchronized_count', label: 'Synchronized Count', num: true, cls: (_, r) => stCls(r.mirroring_status) },
      { key: 'suspended_count', label: 'Suspended Count', num: true }, { key: 'disconnected_count', label: 'Disconnected Count', num: true },
      { key: 'synchronizing_count', label: 'Synchronizing Count', num: true }, { key: 'pending_failover_count', label: 'Pending Failover Count', num: true },
      { key: 'not_synchronized_count', label: 'Not Synchronized Count', num: true },
      { key: 'witness_unknown_count', label: 'Witness Unknown Count', num: true }, { key: 'witness_connected_count', label: 'Witness Connected Count', num: true },
      { key: 'witness_disconnected_count', label: 'Witness Disconnected Count', num: true },
      { key: 'snapshot_age_secs', label: 'Snapshot Age (min)', num: true, fmt: v => v == null ? '' : String(Math.round(Number(v) / 60)), cls: (_, r) => stCls(r.snapshot_status) },
    ];
    const detCols: Col[] = [
      { key: 'instance', label: 'Instance' }, { key: 'database_name', label: 'DB' },
      { key: 'mirroring_state', label: 'mirroring_state', num: true, cls: stateCls }, { key: 'mirroring_state_desc', label: 'mirroring_state_desc' },
      { key: 'mirroring_role_desc', label: 'mirroring_role_desc' }, { key: 'mirroring_safety_level_desc', label: 'mirroring_safety_level_desc' },
      { key: 'mirroring_partner_name', label: 'mirroring_partner_name' }, { key: 'mirroring_partner_instance', label: 'mirroring_partner_instance' },
      { key: 'mirroring_witness_name', label: 'mirroring_witness_name' },
      { key: 'mirroring_witness_state', label: 'mirroring_witness_state', num: true, cls: witnessCls },
      { key: 'mirroring_witness_state_desc', label: 'mirroring_witness_state_desc' },
      { key: 'mirroring_connection_timeout', label: 'mirroring_connection_timeout', num: true },
      { key: 'partner_mirroring_state', label: 'partner_mirroring_state', num: true }, { key: 'partner_mirroring_state_desc', label: 'partner_mirroring_state_desc' },
      { key: 'snapshot_age_secs', label: 'SnapshotAge', num: true, fmt: v => v == null ? '' : String(Math.round(Number(v) / 60)), cls: (_, r) => stCls(r.snapshot_status) },
      // pgvigil's own, after DBA Dash's
      { key: 'partner_monitored_as', label: 'partner (pgvigil instance)' }, { key: 'role_sequence', label: 'role sequence', num: true },
      { key: 'log_send_queue_kb', label: 'send queue', fmt: kb }, { key: 'redo_queue_kb', label: 'redo queue', fmt: kb },
      { key: 'send_rate_kb_s', label: 'send rate', fmt: kbs }, { key: 'redo_rate_kb_s', label: 'redo rate', fmt: kbs },
      { key: 'txn_delay_ms', label: 'delay per write (ms)', num: true },
    ];
    const rcCols = roleChangeCols(ctx, tab, [{ key: 'database_name', label: 'Database' }, { key: 'partner', label: 'Partner' }])
      .concat([{ key: 'state_after', label: 'State After' }, { key: 'witness_after', label: 'Witness After' }]);
    body.replaceChildren(summary ? grid(rowsOf(d.summary), sumCols, 'No mirrored database on these instances.')
      : grid(rowsOf(d.detail), detCols, 'No mirrored database on these instances.'),
      el('h3', {}, 'Role Changes'), grid(rowsOf(d.role_changes), rcCols, 'No role change in this range.'));
  }
  refresh.addEventListener('click', () => void draw());
  toggle.addEventListener('click', () => { summary = !summary; toggle.textContent = summary ? 'Detail' : 'Summary'; void draw(); });
  sec.append(el('div', { class: 'toolbar' }, refresh, ' ', toggle, ' ', backButton(ctx, tab), ' ', range.node),
    el('p', { class: 'meta' }, 'Synchronized Count is green when every database is synchronized with its witness connected or unknown, amber when one is '
      + 'synchronizing or has no witness (DBA Dash\'s rule; pgvigil\'s Findings raise nothing for a session without a witness), red otherwise. A mirror '
      + 'read by a login that is not sysadmin shows its state on the principal only (Microsoft\'s rule for sys.database_mirroring): it counts in Mirror '
      + 'Count alone. A database whose partner pgvigil does not monitor keeps its row, its partner\'s columns empty (DBA Dash drops it). '
      + 'mirroring_safety_sequence and mirroring_redo_queue_type are not read. Role changes come from pgvigil\'s reads (the minute before); the old '
      + 'principal of a failover and back reads PRINCIPAL => PRINCIPAL with a higher role sequence.'), body);
  await draw();
  return sec;
}

// ---- Log Shipping (LogShippingView.cs; LogShippingReport_Get): Summary per secondary instance and Detail per database,
// both from the one judge the findings read (the lead's D6)
export async function mssqlLogShippingView(ctx: Ctx): Promise<HTMLElement> {
  const tab = 'mssqllogshipping';
  const sec = el('section', { class: 'mssql-hadr-logshipping' }, el('h2', {}, 'Log Shipping'));
  const body = el('div');
  const sc = await hadrScope(ctx);
  // the status filter narrows the Detail only: DBA Dash's four check boxes, Critical + Warning in a folder and every
  // status at one instance (LogShippingReport_Get.sql:4-7, LogShippingView.cs:278-284); not kept: a drill resets it
  const stBoxes = (['critical', 'warning', 'na', 'ok'] as const).map(v => {
    const b = el('input', { type: 'checkbox', value: v, 'aria-label': statusWord[v] });
    b.checked = !sc.folder || v === 'critical' || v === 'warning';
    return b;
  });
  const statusParam = () => { const on = stBoxes.filter(b => b.checked).map(b => b.value); return on.length === 4 ? 'all' : on.length ? on.join(',') : 'none'; };
  const statusText = () => { const on = stBoxes.filter(b => b.checked).map(b => statusWord[b.value]); return on.length ? on.join(', ') : 'no status'; };
  const refresh = el('button', { type: 'button' }, 'Refresh');
  let keys: Row[] = [];
  const keyOf = (k: string) => keys.find(r => r.key === k);
  // Configure: one dialog per key, each opened with that key's threshold in force at the place (its level, tag, values)
  type KeyCur = (k: 'age' | 'latency') => Row;
  const configure = (place: ThresholdPlace, cur: KeyCur) => {
    const box = el('span', { class: 'meta' }, ' ');
    for (const [k, short, lab] of [['logship_restore_age', 'age', 'time since the last restore'], ['logship_restore_latency', 'latency', 'latency of the last']] as const) {
      const a = el('button', { type: 'button', class: 'link', 'aria-label': `Configure ${lab} at ${place.where}` }, lab);
      a.addEventListener('click', () => { const key = keyOf(k); if (key) thresholdDialog(key, place, cur(short), () => void draw()); });
      box.append(a, ' ');
    }
    return box;
  };
  const curOf = (r: Row): KeyCur => k => ({ level: r[`${k === 'age' ? 'threshold' : 'latency'}_level`] ?? r[`${k}_level`], tag: r[`${k === 'age' ? 'threshold' : 'latency'}_tag`] ?? r[`${k}_tag`],
    warn: r[`${k}_warn`], crit: r[`${k}_crit`] });
  const mins = (v: unknown) => v == null ? '' : ddDuration(Number(v) * 60);
  async function draw() {
    let d: Record<string, Table | null>;
    try { d = await get<Record<string, Table | null>>('mssql/hadr/fleet', { page: 'logshipping', ...sc.params, status: statusParam() }); } catch (e) { body.replaceChildren(errorBox(e)); return; }
    keys = rowsOf(d.thresholds);
    summaryRows = rowsOf(d.summary);
    const sumCols: Col[] = [
      { key: 'instance', label: 'Instance', fmt: (v, r) => instLink(ctx, tab, r.instance_id, v) },
      { key: 'primary_instances', label: 'Primary Instance' },
      { key: 'status', label: 'Status', fmt: v => statusWord[String(v)] ?? String(v ?? ''), cls: stCls },
      { key: 'log_shipped_dbs', label: 'Log Shipped DBs', num: true }, { key: 'warning_count', label: 'Warning', num: true },
      { key: 'critical_count', label: 'Critical', num: true }, { key: 'missing_count', label: 'Missing', num: true },
      { key: 'new_database_count', label: 'New DBs', num: true },
      { key: 'max_total_time_behind_min', label: 'Max Total Time Behind', num: true, fmt: mins }, { key: 'min_total_time_behind_min', label: 'Min Total Time Behind', num: true, fmt: mins },
      { key: 'avg_total_time_behind_min', label: 'Avg Total Time Behind', num: true, fmt: mins },
      { key: 'max_latency_of_last_min', label: 'Max Latency of Last', num: true, fmt: mins }, { key: 'min_latency_of_last_min', label: 'Min Latency of Last', num: true, fmt: mins },
      { key: 'avg_latency_of_last_min', label: 'Avg Latency of Last', num: true, fmt: mins },
      { key: 'max_time_since_last_min', label: 'Max Time Since Last', num: true, fmt: mins }, { key: 'min_time_since_last_min', label: 'Min Time Since Last', num: true, fmt: mins },
      { key: 'avg_time_since_last_min', label: 'Avg Time Since Last', num: true, fmt: mins },
      { key: 'snapshot_age_min', label: 'Snapshot Age', num: true, fmt: mins, cls: (_, r) => stCls(r.collection_status) },
      { key: 'backup_date_of_oldest_file', label: 'Backup Date of Oldest File', fmt: fmtTime }, { key: 'backup_date_of_newest_file', label: 'Backup Date of Newest File', fmt: fmtTime },
      { key: 'restore_date_of_oldest_file', label: 'Restore Date of Oldest File', fmt: fmtTime }, { key: 'restore_date_of_newest_file', label: 'Restore Date of Newest File', fmt: fmtTime },
      { key: 'instance_level_threshold', label: 'Configure', fmt: (v, r) => {
        const n = configure({ level: 'instance', instance_id: Number(r.instance_id), where: `the instance ${String(r.instance)}` }, curOf(r));
        if (v === true) n.style.fontWeight = 'bold';   // either key has the instance's own threshold
        return n;
      } },
    ];
    const detCols: Col[] = [
      { key: 'instance', label: 'Instance' },
      { key: 'database_name', label: 'Database', fmt: v => {   // pgvigil's own: a click narrows the panel below to this database
        const b = el('button', { type: 'button', class: 'link', 'aria-label': `Show log shipping's jobs and messages for ${String(v ?? '')}` }, String(v ?? ''));
        b.addEventListener('click', () => { dbPick.value = String(v ?? ''); drawPanel(); dbPick.focus(); });
        return b;
      } },
      { key: 'primary_server', label: 'Primary Instance' },
      { key: 'status', label: 'Status', fmt: (v, r) => (statusWord[String(v)] ?? String(v ?? '')) + (r.is_missing === true ? ' (Missing)' : r.is_new_database === true ? ' (New Database)' : ''), cls: stCls },
      { key: 'excluded_by', label: 'Excluded By' },
      { key: 'last_log_restore_at', label: 'Restore Date', fmt: fmtTime }, { key: 'last_log_backup_start_at', label: 'Backup Start Date', fmt: fmtTime },
      { key: 'total_time_behind_min', label: 'Total Time Behind', num: true, fmt: mins }, { key: 'latency_of_last_min', label: 'Latency of Last', num: true, fmt: mins },
      { key: 'time_since_last_min', label: 'Time Since Last', num: true, fmt: mins },
      { key: 'snapshot_age_min', label: 'Snapshot Age', num: true, fmt: mins, cls: (_, r) => stCls(r.snapshot_age_status) },
      { key: 'snapshot_at', label: 'Snapshot Date', fmt: fmtTime },
      { key: 'last_file', label: 'Last File', fmt: v => v == null ? '' : String(v).split(/[\\/]/).pop() ?? '' },
      { key: 'created_at', label: 'Create Date', fmt: fmtTime },
      { key: 'database_age_s', label: 'Database Age', num: true, fmt: v => v == null ? '' : ddDuration(v) },
      { key: 'threshold_level', label: 'Threshold Level', fmt: (v, r) => v === 'default' || v == null ? 'Root' : v === 'tag' ? `Tag ${String(r.threshold_tag)}` : String(v)[0].toUpperCase() + String(v).slice(1) },
      { key: 'kind', label: 'Configure', fmt: (v, r) => {
        if (v !== 'restore') return '';
        const n = configure({ level: 'database', instance_id: Number(r.instance_id), datname: String(r.database_name), where: `the database ${String(r.database_name)} on ${String(r.instance)}` }, curOf(r));
        if (r.threshold_level === 'database' || r.latency_level === 'database') n.style.fontWeight = 'bold';   // DBA Dash: ThresholdConfiguredLevel = 'Database'
        return n;
      } },
      // pgvigil's own, after DBA Dash's columns
      { key: 'checks', label: 'finding', wide: true },
    ];
    panelRows = { jobs: rowsOf(d.jobs), messages: rowsOf(d.messages), foreign: rowsOf(d.foreign) };
    const names = [...new Set([...panelRows.jobs, ...panelRows.messages, ...panelRows.foreign]
      .map(r => r.database_name).filter(v => v != null && v !== '').map(String))].sort();
    const keep = dbPick.value;
    dbPick.replaceChildren(el('option', { value: '' }, 'every database'), ...names.map(n => el('option', { value: n }, n)));
    dbPick.value = names.includes(keep) ? keep : '';
    body.replaceChildren(el('h3', {}, 'Summary'), grid(rowsOf(d.summary), sumCols, 'No log shipped database on these instances.'),
      el('h3', {}, 'Detail'), grid(rowsOf(d.detail), detCols, `No database matches the filter (${statusText()}).`), panel);
    drawPanel();
  }
  // ---- pgvigil's own panel below DBA Dash's grids (task LSX): what SQL Server's log shipping configuration and agents
  // say - its jobs, the agents' messages, log backups taken outside it - on the primary, the secondary and the monitor
  // alike (the Detail above lists restoring databases only)
  let panelRows: { jobs: Row[]; messages: Row[]; foreign: Row[] } = { jobs: [], messages: [], foreign: [] };
  const dbPick = el('select', { 'aria-label': 'Database' });
  const panelBody = el('div');
  const panel = el('section', { class: 'mssql-hadr-logship-config', 'aria-label': 'Log shipping configuration and agents' },
    el('h3', {}, 'Log shipping\'s own jobs and agents'),
    el('p', { class: 'meta' }, 'As SQL Server\'s log shipping configuration in msdb names them, where log shipping was set up with its procedures or the '
      + 'wizard (a pair restored by hand has none). Database ', dbPick, ' (or click a database above).'), panelBody);
  dbPick.addEventListener('change', () => drawPanel());
  const yesNo = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';
  const outcome: Record<string, string> = { '0': 'failed', '1': 'succeeded', '3': 'cancelled', '5': 'unknown' };
  function drawPanel() {
    const pick = dbPick.value;
    const mine = (r: Row) => !pick || String(r.database_name ?? '') === pick;
    const jobCols: Col[] = [
      { key: 'instance', label: 'Instance' }, { key: 'database_name', label: 'Database', fmt: v => v == null ? '(the monitor)' : String(v) },
      { key: 'role', label: 'Role' }, { key: 'job_role', label: 'Job' }, { key: 'job_name', label: 'Job Name', fmt: (v, r) => v == null ? `missing (id ${String(r.job_id ?? '?')})` : String(v) },
      { key: 'job_exists', label: 'Exists', fmt: yesNo, cls: v => v === false ? stCls('critical') : '' },
      { key: 'job_enabled', label: 'Enabled', fmt: yesNo, cls: v => v === false ? stCls('critical') : '' },
      { key: 'enabled_schedules', label: 'Schedules Running It', num: true, cls: (v, r) => r.job_exists === true && Number(v ?? 0) === 0 ? stCls('critical') : '' },
      { key: 'interval_min', label: 'Every (min)', num: true },
      { key: 'last_outcome', label: 'Last Outcome', fmt: v => v == null ? '' : outcome[String(v)] ?? String(v), cls: v => String(v) === '0' ? stCls('critical') : '' },
      { key: 'last_run_at', label: 'Last Run', fmt: fmtTime },
      { key: 'recovery_model', label: 'Recovery Model', cls: v => stCls(v === 'SIMPLE' ? 'critical' : v === 'BULK_LOGGED' ? 'warning' : '') },
      { key: 'restore_mode', label: 'Restore Mode', fmt: v => v == null ? '' : Number(v) === 1 ? 'STANDBY' : 'NORECOVERY' },
      { key: 'backup_directory', label: 'Backup Folder', wide: true },
      { key: 'snapshot_at', label: 'Read', fmt: fmtTime },
    ];
    const msgs = panelRows.messages.filter(mine);
    const noise = msgs.filter(r => r.standby_noise === true).length;
    const msgCols: Col[] = [
      { key: 'instance', label: 'Instance' }, { key: 'database_name', label: 'Database' }, { key: 'agent', label: 'Agent' },
      { key: 'logged_at', label: 'Logged', fmt: fmtTime }, { key: 'message', label: 'Message', wide: true },
      { key: 'source', label: 'Source' }, { key: 'rows_24h', label: 'Lines in 24 h', num: true },
    ];
    const forCols: Col[] = [
      { key: 'instance', label: 'Instance' }, { key: 'database_name', label: 'Database' }, { key: 'finished_at', label: 'Finished', fmt: fmtTime },
      { key: 'file_name', label: 'File', wide: true }, { key: 'device', label: 'Device' }, { key: 'backup_directory', label: 'Log Shipping Folder', wide: true },
    ];
    panelBody.replaceChildren(
      el('h4', {}, 'Jobs'), grid(panelRows.jobs.filter(mine), jobCols, 'No log shipping configuration read on these instances.'),
      el('h4', {}, 'The agents\' messages (24 hours)'),
      el('p', { class: 'meta' }, 'The newest 20 lines per agent and database from msdb.dbo.log_shipping_monitor_error_detail, and the restore job\'s runs '
        + 'that found nothing to apply. They raise no finding by themselves: the newest one is added to a database\'s finding when its log shipping is behind. '
        + (noise > 0 ? `${noise} read-only line${noise === 1 ? '' : 's'} of a STANDBY copy left out (expected while readers use it).` : '')),
      grid(msgs.filter(r => r.standby_noise !== true), msgCols, 'No agent logged an error in the 24 hours.'),
      el('h4', {}, 'Log backups outside log shipping (24 hours)'),
      el('p', { class: 'meta' }, 'Log backups of a log-shipped primary database that are not copy-only and are not log shipping\'s own: the secondaries never receive them.'),
      grid(panelRows.foreign.filter(mine), forCols, 'None in the 24 hours.'));
  }
  let summaryRows: Row[] = [];
  // the toolbar's Configure: each key at the root, and at the instance where one instance is in scope
  // (LogShippingView.cs:131-133); each dialog opened with the threshold in force there
  const keyNames = { logship_restore_age: 'time since the last restore', logship_restore_latency: 'latency of the last' } as const;
  const cfg = el('select', { 'aria-label': 'Configure' }, el('option', { value: '' }, 'Configure'),
    ...Object.entries(keyNames).map(([k, lab]) => el('option', { value: `root:${k}` }, `Thresholds (Root): ${lab}`)),
    ...Object.entries(keyNames).map(([k, lab]) => { const o = el('option', { value: `instance:${k}` }, `Thresholds (Instance): ${lab}`); o.disabled = !sc.one; return o; }));
  cfg.addEventListener('change', () => {
    const [lv, k] = cfg.value.split(':'); cfg.value = '';
    const key = keyOf(k);
    if (!key) return;
    if (lv === 'root') thresholdDialog(key, { level: 'root', where: 'the root (every SQL Server instance)' },
      key.root_own === true ? { level: 'root', warn: key.root_warn, crit: key.root_crit } : { level: 'default', warn: key.warn_default, crit: key.crit_default }, () => void draw());
    if (lv === 'instance' && sc.one) {
      const r = summaryRows.find(x => Number(x.instance_id) === sc.one);
      const short = k === 'logship_restore_age' ? 'age' : 'latency';
      thresholdDialog(key, { level: 'instance', instance_id: sc.one, where: 'this instance' }, r ? curOf(r)(short) : undefined, () => void draw());
    }
  });
  refresh.addEventListener('click', () => void draw());
  for (const b of stBoxes) b.addEventListener('change', () => void draw());
  sec.append(el('div', { class: 'toolbar' }, refresh, ' ', el('span', { role: 'group', 'aria-label': 'Status' }, 'Status ',
      ...stBoxes.flatMap(b => [el('label', {}, b, ' ', statusWord[b.value]), ' '])), ' ', cfg, ' ', backButton(ctx, tab)),
    el('p', { class: 'meta' }, 'Status is the judgment the Findings raise, from the same rows: the worst finding of the database, else OK where restore '
      + 'history judges it, else N/A with the reason in Excluded By (not read in 15 minutes; no log restore yet - DBA Dash calls that Critical, pgvigil waits '
      + 'for the restoring-days check; mirroring unknown). Mirrored, availability group and SIMPLE-recovery databases have no row, as in DBA Dash. Missing '
      + 'counts the log shipping copies that received a stream of log restores and no longer exist (pgvigil keeps no configured pairs, so a primary '
      + 'database that is not shipped is not counted). Durations are at this moment; the status is the last read\'s. DBA Dash\'s Exclusions, Pairs, '
      + 'Set Primary and Metric Collection are not here: pgvigil\'s exclusions are its rules.'), body);
  await draw();
  return sec;
}
