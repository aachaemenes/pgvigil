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
      sec.append(lineChart('Log waiting to be sent and to be redone (all database replicas)', series, [
        { key: 'log_send_queue_kb', label: 'send queue' }, { key: 'redo_queue_kb', label: 'redo queue' },
      ], v => fmtBytes(v * 1024)));
      const det = el('details', {}, el('summary', {}, 'The chart\'s numbers as a table'), grid(series, seriesCols, 'No read in this window.'));
      sec.append(det);
      const lim = rowsOf(d.limits)[0];
      if (lim) sec.append(el('p', { class: 'meta' }, `A finding is raised when a database replica's send queue stays over ${kb(lim.log_send_queue_kb)} `
        + `or its redo queue over ${kb(lim.redo_queue_kb)} in every read of five minutes.`));
      sec.append(el('h4', {}, 'Failovers in this window'), grid(rowsOf(d.failovers), failoverCols, 'No change of a primary was seen in this window.'));
    }

    // the sections below exist only where the server has the feature
    if (mirroring.length) sec.append(el('h3', {}, 'Database mirroring'), grid(mirroring, mirrorCols));
    if (shipping.length) sec.append(el('h3', {}, 'Log shipping'), grid(shipping, shipCols));
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
