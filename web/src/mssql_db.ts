// A SQL Server database's own page (P25, F101 / F103; DBA Dash's database node, GUI/Main.cs L1903-1914): its tab
// strip - Performance first, as DBA Dash opens a database on it - each tab the instance's page cut to this database.
// #/mssqldb?i=<instance>&db=<database name>[&dbtab=<tab>][&fg=<file group>]. The tree's database node links here
// (tree.ts, a wiring line of the join).
import { Ctx, href, window_ } from './router';
import { hashParam, hrefWith } from './dbinfo';
import { performanceView } from './performance';
import { mssqlFilesView } from './mssql_storage';
import { mssqlQueryStoreView } from './mssql_querystore';
import { dbSpaceView } from './drives';
import { mssqlPlanCacheView } from './mssql_plancache';
import { mssqlSlow } from './mssql_xe';
import { objectExecutionSection } from './mssql_objexec';
import { schemaDbSection } from './schema';
import { get, post, Row, rowsOf, Table } from './api';
import { InstanceRun, resultView } from './customreports';
import { fleet } from './fleet';
import { lineChart } from './chart';
import { badge, el, errorBox, fmtNum, fmtTime, grid } from './ui';

export const mssqlDbTab = 'mssqldb';

// DBA Dash's database tabs in its order (Main.cs GetAllowedTabs; Service Broker and sp_DBPermissions P25 rows 73 / 75; its
// Schema Snapshot tab of one object is a parity row); built: the ones this page cuts to the database
const tabs: [string, string][] = [
  ['performance', 'Performance'], ['objexec', 'Object Execution'], ['querystats', 'Query Stats'], ['slow', 'Slow Queries'],
  ['files', 'Files'], ['snapshots', 'Snapshot Summary'], ['dbspace', 'DB Space'], ['dbconfig', 'DB Configuration'],
  ['dboptions', 'DB Options'], ['qs', 'QS'], ['topqueries', 'Top Queries'], ['forcedplans', 'Forced Plans'], ['tuning', 'Tuning Recommendations'], ['servicebroker', 'Service Broker'], ['dbpermissions', 'sp_DBPermissions'],
];

// mssqlDbLink: a database of a SQL Server instance, opened on its page (the tab given, else Performance)
export const mssqlDbLink = (ctx: Ctx, db: string, tab?: string, instance = ctx.instance) =>
  hrefWith(ctx, mssqlDbTab, { db, dbtab: tab }, instance);

// the Query Store page's view for each of DBA Dash's Query Store tabs (mssql_querystore.ts: qs=, qdb= on the hash)
const qsViews: Record<string, string> = { qs: 'state', topqueries: 'top', forcedplans: 'forced', tuning: 'tuning' };

// dbOptions: one database's options (DBA Dash's DB Options: the database's row of the instance's option grid,
// /api/mssql/checks part=databases cut by db=), each option a row with the value read and a deviation's status
async function dbOptions(ctx: Ctx, db: string): Promise<HTMLElement> {
  const [d, c] = await Promise.all([
    get<{ databases: Table | null }>('mssql/checks', { instance: ctx.instance, part: 'databases', db }),
    get<{ columns: Table | null }>('mssql/checks', { instance: ctx.instance, part: 'columns' })]);
  const row = rowsOf(d.databases)[0];
  if (!row) return el('p', { class: 'empty' }, `No option read for ${db}: the mssql_checks collection reads sys.databases hourly.`);
  const opts = (row.options ?? {}) as Record<string, unknown>, dev = (row.deviations ?? {}) as Record<string, { status?: string }>;
  const rows = rowsOf(c.columns).map(k => ({ option: String(k.label), value: opts[String(k.key)] ?? '', best: String(k.best ?? ''), status: dev[String(k.key)]?.status ?? '' }));
  return el('div', {}, el('p', { class: 'meta' }, `state ${String(row.state ?? '')}; read ${String(row.snapshot_at ?? '')}`),
    grid(rows, [{ key: 'option' }, { key: 'value' }, { key: 'best', label: 'expected' },
      { key: 'status', label: 'check', fmt: v => v ? badge(String(v), v === 'critical' ? 'crit' : 'warn') : '' }], 'No option column.'));
}

// dbConfiguration: one database's scoped configuration (DBA Dash's DB Configuration; 0391, /api/mssql/checks
// part=scoped_config and scoped_changes cut by db=): each setting as last read, a value not the default marked, then
// the changes the hourly reads saw
async function dbConfiguration(ctx: Ctx, db: string): Promise<HTMLElement> {
  const [c, x] = await Promise.all([
    get<{ scoped_config: Table | null }>('mssql/checks', { instance: ctx.instance, part: 'scoped_config', db }),
    get<{ scoped_changes: Table | null }>('mssql/checks', { instance: ctx.instance, part: 'scoped_changes', db })]);
  const rows = rowsOf(c.scoped_config);
  if (!rows.length) return el('p', { class: 'empty' }, `No scoped configuration read for ${db}: the mssql_confcheck collection reads sys.database_scoped_configurations hourly (SQL Server 2016 and later).`);
  const note = rows.find(r => r.note);
  return el('div', {},
    note ? el('p', { class: 'meta' }, `The last read did not read ${db}: ${String(note.note)} - these are the values read before.`) : '',
    grid(rows, [
      { key: 'name' }, { key: 'value' },
      { key: 'value_for_secondary', label: 'for secondaries', fmt: v => v == null ? 'as the primary' : String(v) },
      { key: 'is_default', label: 'default', fmt: v => v == null ? 'not read' : v ? 'yes' : badge('changed', 'warn') },
      { key: 'is_present', label: 'in the view', fmt: v => v ? 'yes' : 'no longer' },
    ], 'No setting.'),
    el('h3', {}, 'Changes'),
    grid(rowsOf(x.scoped_changes), [{ key: 'changed_at', label: 'seen at', fmt: fmtTime }, { key: 'name' }, { key: 'old_value', label: 'from' },
      { key: 'new_value', label: 'to', fmt: v => v == null ? 'left the view' : String(v) }], 'No change seen since the first read.'));
}

// snapshotSummary: DBA Dash's database Snapshot Summary, which is its SCHEMA snapshots (Changes.SchemaSnapshots: the
// snapshot and validated dates, the created / modified / dropped objects, each with its diff) - the Schema tab's section
// for this database (schema.ts schemaDbSection: the read, the range's changes with their diffs, the objects), the
// database found by its name in the instance's schema read
async function snapshotSummary(ctx: Ctx, db: string): Promise<HTMLElement> {
  const d = await get<{ databases: Table | null }>('schema', { instance: ctx.instance, ...window_(ctx) });
  const row = rowsOf(d.databases).find(r => String(r.datname) === db);
  if (!row) return el('p', { class: 'empty' }, `No schema read of ${db} yet: the mssql_schema collection reads each database's objects and their changes (Schema tab).`);
  return schemaDbSection(ctx, row.dbid as number);
}

// serviceBroker: DBA Dash's database Service Broker tab (P25 row 73; 0392, the mssql_service_broker collection every 5
// minutes): the user queues as last read (receive disabled = DBA Dash's poison mark; a missing activation procedure),
// each queue's depth over the window, the transmission queue's groups, the conversations by state, the instance's
// endpoint and the Broker counters as rates. DBA Dash shows the tab only when the database has the broker; this page
// keeps it last and says so in words when there is nothing to show.
async function serviceBroker(ctx: Ctx, db: string): Promise<HTMLElement> {
  const part = <T extends string>(p: T, win = false) =>
    get<Record<T, Table | null>>('mssql/checks', { instance: ctx.instance, part: p, db, ...(win ? window_(ctx) : {}) }).then(d => rowsOf(d[p]));
  const [queues, depth, trans, convs, eps, counters, state] = await Promise.all([part('broker_queues'), part('broker_depth', true),
    part('broker_transmission'), part('broker_conversations'), part('broker_endpoint'), part('broker_counters', true), part('broker_state')]);
  const st = state[0];
  if (!queues.length && !trans.length && !convs.length) {
    return el('p', { class: 'empty' }, `No Service Broker read of ${db}: the mssql_service_broker collection reads, every 5 minutes, each database ` +
      `with the broker on that the login may enter (none here, or not read yet)` + (st?.note ? ` - its last run: ${String(st.note)}` : '') + '.');
  }
  const yes = (v: unknown) => v == null ? '' : v ? 'yes' : 'no';
  const note = queues.find(r => r.note);
  // the depth per queue over the window: one series a queue (by its schema and name)
  const names = [...new Set(depth.map(r => `${String(r.schema_name)}.${String(r.queue_name)}`))];
  const at = new Map<string, Row>();
  for (const r of depth) {
    const k = String(r.snapshot_at);
    const row = at.get(k) ?? { snapshot_at: r.snapshot_at };
    row[`${String(r.schema_name)}.${String(r.queue_name)}`] = r.message_count;
    at.set(k, row);
  }
  const cNames = [...new Set(counters.map(r => String(r.counter_name) + (r.instance_name ? ` (${String(r.instance_name)})` : '')))];
  const cAt = new Map<string, Row>();
  for (const r of counters) {
    const k = String(r.snapshot_at);
    const row = cAt.get(k) ?? { snapshot_at: r.snapshot_at };
    row[String(r.counter_name) + (r.instance_name ? ` (${String(r.instance_name)})` : '')] = r.per_sec;
    cAt.set(k, row);
  }
  return el('div', {},
    note ? el('p', { class: 'meta' }, `The last read did not read ${db}: ${String(note.note)} - these are the values read before.`) : '',
    el('h3', {}, 'Queues'),
    grid(queues, [
      { key: 'schema_name', label: 'schema' }, { key: 'queue_name', label: 'queue' },
      { key: 'is_receive_enabled', label: 'receive', fmt: v => v === false ? badge('disabled (a poison message?)', 'crit') : yes(v) },
      { key: 'is_enqueue_enabled', label: 'enqueue', fmt: v => v === false ? badge('disabled', 'warn') : yes(v) },
      { key: 'message_count', label: 'messages', num: true, fmt: (v, r) => v == null ? (r.is_retention_enabled ? el('span', { class: 'meta', title: 'a RETENTION queue also holds received messages: its count is read from the queue, and was not this time' }, 'not read') : '') : fmtNum(v) },
      { key: 'oldest_message_at', label: 'oldest ready message', fmt: fmtTime },
      { key: 'activated_tasks', label: 'readers running', num: true }, { key: 'max_readers', label: 'max readers', num: true },
      { key: 'activation_procedure', label: 'activation', fmt: (v, r) => v == null ? (r.is_activation_enabled ? 'on, no procedure' : '') : r.activation_procedure_exists === false ? badge(`${String(v)} (missing)`, 'crit') : String(v) },
      { key: 'monitor_state', label: 'monitor' }, { key: 'monitor_last_activated', label: 'last activated', fmt: fmtTime },
      { key: 'is_present', label: 'in the database', fmt: v => v ? 'yes' : 'no longer' }, { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], 'No user queue in this database.'),
    names.length ? lineChart('Queue depth (messages)', [...at.values()], names.map(n => ({ key: n, label: n })), v => fmtNum(v)) : '',
    el('h3', {}, 'Transmission queue'),
    grid(trans, [{ key: 'to_service_name', label: 'to service' }, { key: 'transmission_status', label: 'status', fmt: v => v ? String(v) : 'not sent yet' },
      { key: 'message_count', label: 'messages', num: true }, { key: 'oldest_enqueue_at', label: 'oldest', fmt: fmtTime }], 'Nothing waits to be sent.'),
    el('h3', {}, 'Conversations'),
    grid(convs, [{ key: 'state' }, { key: 'conversation_count', label: 'conversations', num: true }], 'No conversation endpoint.'),
    el('h3', {}, 'Endpoint (the instance)'),
    grid(eps, [{ key: 'endpoint_name', label: 'endpoint' }, { key: 'state_desc', label: 'state' }, { key: 'port', num: true },
      { key: 'connection_count', label: 'connections', num: true }, { key: 'connected_count', label: 'connected', num: true },
      { key: 'login_failed_count', label: 'login failed', num: true }, { key: 'last_activity_at', label: 'last activity', fmt: fmtTime }],
      'No Service Broker endpoint on this instance (messages stay within it), or the endpoint was not read.'),
    cNames.length ? lineChart('Broker counters (per second)', [...cAt.values()], cNames.map(n => ({ key: n, label: n })), v => fmtNum(v)) : '');
}

// dbPermissions: DBA Dash's database sp_DBPermissions tab (P25 row 75): Kenneth Fisher's sp_DBPermissions (SQLStudies,
// MIT) run through the Community tools door with @DBName = the database, its result sets as grids. DBA Dash runs it as
// the tab opens; here a run is the door's - audited, under its role - so it runs on a click. Words when it is not
// installed (the Community tools page prints its install script: the pinned file, its SHA256 checked first), on Azure
// SQL Database (DBA Dash's own list marks it so) and when the door is off.
async function dbPermissions(ctx: Ctx, db: string): Promise<HTMLElement> {
  const inst = (await fleet()).instances.find(r => Number(r.instance_id) === ctx.instance);
  if (inst?.platform === 'azuresqldb') {
    return el('p', { class: 'empty' }, `sp_DBPermissions does not run on Azure SQL Database (DBA Dash's own list marks it so): ${db} has no tab of it here.`);
  }
  const d = await get<{ enabled: boolean; reason?: string; tools: { id: string; installed: boolean | null; state: string }[] }>('community', { instance: ctx.instance, database: 'master' });
  const tools = el('a', { href: href(ctx, { tab: 'community' }) }, 'Community tools');
  if (!d.enabled) return el('p', { class: 'empty' }, `The Community tools door is off here${d.reason ? `: ${d.reason}` : ''}.`);
  const t = d.tools.find(x => x.id === 'sp_DBPermissions');
  if (!t || t.installed === false) {
    return el('p', { class: 'empty' }, 'sp_DBPermissions is not installed on this instance (in master): the ', tools,
      ' page prints its install script - the file at the commit pgvigil was tested with, its SHA256 checked before it runs.');
  }
  const res = el('div'), status = el('span', { class: 'meta' });
  const run = el('button', { type: 'button' }, `Run sp_DBPermissions for ${db}`) as HTMLButtonElement;
  run.addEventListener('click', async () => {
    run.disabled = true; status.textContent = 'Running...';
    try {
      const r = await post<{ runs?: InstanceRun[]; ran_at?: string }>('community/run', { instance_id: ctx.instance, tool: 'sp_DBPermissions', database: 'master', params: { DBName: db } });
      if (r.runs) {
        res.replaceChildren(resultView(r.runs, undefined, 'sp_DBPermissions'));
        status.textContent = r.ran_at ? `Ran at ${fmtTime(r.ran_at)}.` : '';
      } else {
        res.replaceChildren(el('p', { class: 'meta' }, 'Asked of the collector (queue mode): its answer is on the ', tools, ' page.'));
        status.textContent = '';
      }
    } catch (e) { res.replaceChildren(errorBox(e)); status.textContent = ''; } finally { run.disabled = false; }
  });
  return el('div', {}, el('p', { class: 'meta' }, `sp_DBPermissions for ${db}: its principals, their role memberships and their permissions, each with the statement that would recreate it. A run is the Community tools door's, audited.`),
    el('div', { class: 'toolbar' }, run, ' ', status), res);
}

export async function mssqlDbView(ctx: Ctx): Promise<HTMLElement> {
  const db = hashParam('db');
  if (!db) return el('section', {}, el('h2', {}, 'Database'), el('p', { class: 'empty' }, 'No database named (db=).'));
  const asked = hashParam('dbtab');
  const tab = tabs.some(([k]) => k === asked) ? asked! : 'performance';
  const fg = hashParam('fg');
  const strip = el('nav', { class: 'subtabs', 'aria-label': `${db}'s pages` }, ...tabs.map(([k, label]) =>
    el('a', { href: hrefWith(ctx, mssqlDbTab, { db, dbtab: k, ...(qsViews[k] ? { qdb: db, qs: qsViews[k] } : {}) }), class: k === tab ? 'on' : '', ...(k === tab ? { 'aria-current': 'page' } : {}) }, label)));
  const sec = el('section', {}, el('h2', {}, `Database ${db}`), strip);
  let body: HTMLElement;
  switch (tab) {
    case 'performance':
      body = await performanceView(ctx, { db, filegroup: fg, pick: f => { location.hash = hrefWith(ctx, mssqlDbTab, { db, dbtab: 'performance', fg: f }); } });
      break;
    case 'files':
      // the instance's Database files page reads db= by itself (mssql_storage.ts)
      body = await mssqlFilesView(ctx);
      break;
    case 'objexec':
      // DBA Dash's Object Execution on the database (F102): its procedures, functions and triggers in one grid
      body = el('section', {}, objectExecutionSection(ctx, db));
      break;
    case 'querystats':
      // DBA Dash's Query Stats (sys.dm_exec_query_stats per database and query hash) = the instance's Plan cache page
      // fixed on this database
      body = await mssqlPlanCacheView(ctx, db);
      break;
    case 'slow':
      // the instance's Slow queries read with db= (/api/mssql/xe: the events that ran in this database)
      body = await mssqlSlow(ctx);
      break;
    case 'snapshots':
      body = await snapshotSummary(ctx, db);
      break;
    case 'dbconfig':
      body = await dbConfiguration(ctx, db);
      break;
    case 'dboptions':
      body = await dbOptions(ctx, db);
      break;
    case 'dbspace':
      // the instance's DB Space read with db= (/api/dbspace: this database's row and its own history)
      body = await dbSpaceView(ctx);
      break;
    case 'qs': case 'topqueries': case 'forcedplans': case 'tuning': {
      // the Query Store page reads its database and view from the hash: this tab's own, put there first (a link from
      // the tree or a range change carries neither)
      const q = new URLSearchParams(location.hash.split('?')[1] ?? '');
      if (q.get('qdb') !== db || !q.get('qs')) {
        q.set('qdb', db);
        if (!q.get('qs')) q.set('qs', qsViews[tab]);
        history.replaceState(null, '', `${location.pathname}${location.search}#/${mssqlDbTab}?${q}`);
      }
      body = await mssqlQueryStoreView(ctx);
      break;
    }
    case 'servicebroker':
      body = await serviceBroker(ctx, db);
      break;
    case 'dbpermissions':
      body = await dbPermissions(ctx, db);
      break;
    default:
      body = el('p', { class: 'empty' }, `${tabs.find(([k]) => k === tab)![1]} for ${db}: not on this page yet.`);
  }
  sec.append(body);
  return sec;
}
