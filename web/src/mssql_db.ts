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
import { compareCell, schemaDbSection } from './schema';
import { get, post, Row, rowsOf, Table } from './api';
import { InstanceRun, resultView } from './customreports';
import { needControl } from './needs';
import { cutWords, endView, isQueued, Queued, waitRequest } from './request';
import { fleet } from './fleet';
import { lineChart } from './chart';
import { badge, el, errorBox, fmtNum, fmtTime, grid, offControl, saveBlob } from './ui';
import { zip } from './export';
import { fileStamp } from './tz';

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

// configuredOnly (control audit D2): DBA Dash's Filter > Configured Only on one database - the settings whose value is
// not the default (DBConfiguration_Get's @ConfiguredOnly); 0391's is_default (is_value_default after the 0375 merge)
const configuredOnly = (rows: Row[]) => rows.filter(r => r.is_default === false);

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
  // DBA Dash's Filter > Configured Only, ticked as there: untick it for every setting
  const only = el('input', { type: 'checkbox', checked: 'checked' }) as HTMLInputElement;
  const box = el('div');
  const draw = () => box.replaceChildren(grid(only.checked ? configuredOnly(rows) : rows, [
    { key: 'name' }, { key: 'value' },
    { key: 'value_for_secondary', label: 'for secondaries', fmt: v => v == null ? 'as the primary' : String(v) },
    { key: 'is_default', label: 'default', fmt: v => v == null ? 'not read' : v ? 'yes' : badge('changed', 'warn') },
    { key: 'is_present', label: 'in the view', fmt: v => v ? 'yes' : 'no longer' },
  ], only.checked ? `Every setting of ${db} is at its default (Configured Only: untick it for every setting).` : 'No setting.'));
  only.addEventListener('change', draw);
  draw();
  return el('div', {},
    note ? el('p', { class: 'meta' }, `The last read did not read ${db}: ${String(note.note)} - these are the values read before.`) : '',
    el('div', { class: 'toolbar', role: 'group', 'aria-label': 'DB Configuration filter' }, el('label', {}, only, ' ', 'Configured Only')), box,
    el('h3', {}, 'Changes'),
    grid(rowsOf(x.scoped_changes), [{ key: 'changed_at', label: 'seen at', fmt: fmtTime }, { key: 'name' }, { key: 'old_value', label: 'from' },
      { key: 'new_value', label: 'to', fmt: v => v == null ? 'left the view' : String(v) }], 'No change seen since the first read.'));
}

// snapshotSummary: DBA Dash's database Snapshot Summary, which is its SCHEMA snapshots (Changes.SchemaSnapshots: the
// snapshot and validated dates, the created / modified / dropped objects, each with its diff) - the Schema tab's section
// for this database (schema.ts schemaDbSection: the read, the range's changes with their diffs, the objects), the
// database found by its name in the instance's schema read
async function snapshotSummary(ctx: Ctx, db: string): Promise<HTMLElement> {
  // the name to its id through the collection's own row per database (part mssql_dbs: every database it has seen, the
  // never-read and not-readable ones too, a gone one left out), so a database no longer read still shows its history,
  // and the page says why a database has no read (review t11-4 SHOULD 4)
  const [m, s] = await Promise.all([
    get<{ mssql_dbs: Table | null }>('schema', { instance: ctx.instance, ...window_(ctx), part: 'mssql_dbs' }),
    get<{ state: Table | null }>('schema', { instance: ctx.instance, ...window_(ctx), part: 'state' })]);
  const row = rowsOf(m.mssql_dbs).find(r => String(r.datname) === db), st = rowsOf(s.state)[0];
  if (!row) {
    const why = !st ? 'the mssql_schema collection has not run on this instance yet'
      : st.status === 'skipped' ? `the mssql_schema collection is off on this instance: ${String(st.note ?? '')}`
      : st.status === 'error' ? `the mssql_schema collection's last run failed: ${String(st.note ?? '')}`
      : 'the mssql_schema collection holds no current row for it - it never read it (it reads the databases of mssql_schema.databases), or the database is gone (its changes stay on the instance\'s Schema tab)';
    return el('p', { class: 'empty' }, `No schema read of ${db}: ${why}.`);
  }
  const [snaps, sec] = await Promise.all([ddlSnapshots(ctx, row.dbid as number), schemaDbSection(ctx, row.dbid as number)]);
  if (row.state !== 'read' && row.state !== 'seen') {
    const p = el('p', { class: 'meta' }, badge(String(row.state ?? 'not read'), 'warn'),
      ` the collection's last pass of ${db}${row.note ? ': ' + String(row.note) : ''}.`);
    const h = sec.firstElementChild;
    if (h) h.after(p); else sec.prepend(p);
  }
  // DBA Dash's snapshot list first (control audit D3 a), then the Schema tab's section for the range
  return el('div', {}, snaps, sec);
}

// schemaSnapshotsView (control audit D3 c): DBA Dash's Snapshot Summary over every instance, the root page 'Schema
// Snapshots' (the wiring patch) - DDLSnapshotInstanceSummary_Get's Instance, Last Updated and Last Validated over
// /api/schema part=ddl_instances (the tag folder's instances under ?tag=); its Instance link (sinst=) opens that
// instance's snapshots over its databases (ddlSnapshots with a DB column), as DBA Dash's drills in
export async function schemaSnapshotsView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Schema Snapshots'));
  const si = Number(hashParam('sinst'));
  if (si > 0) {
    sec.append(el('p', {}, el('a', { href: hrefWith(ctx, 'schemasnapshots', {}, undefined) }, 'All instances')), await ddlSnapshots(ctx, null, si));
    return sec;
  }
  try {
    const d = await get<{ ddl_instances: Table | null }>('schema', { part: 'ddl_instances', tag: ctx.tag });
    sec.append(grid(rowsOf(d.ddl_instances), [
      { key: 'instance', label: 'Instance', fmt: (v, r) => el('a', { href: hrefWith(ctx, 'schemasnapshots', { sinst: String(r.instance_id) }, undefined) }, String(v)) },
      { key: 'engine' }, { key: 'databases', label: 'databases', num: true },
      { key: 'last_updated', label: 'Last Updated', fmt: fmtTime }, { key: 'last_validated', label: 'Last Validated', fmt: fmtTime },
    ], 'No instance has a schema read yet (the mssql_schema and schema collections).'));
  } catch (e) { sec.append(errorBox(e)); }
  return sec;
}

// ddlSnapshots (control audit D3 a): DBA Dash's Snapshot Summary list of one database (SchemaSnapshots.cs,
// DDLSnapshots_Get over /api/schema part=ddl_snapshots): its schema snapshots newest first - the first read its
// baseline - paged with Previous / Next and Page Size; a snapshot's Objects button lists them below (DDLSnapshotDiff_Get:
// part=ddl_snapshot_objects; View = its definition after, Diff = the Schema tab's compare)
async function ddlSnapshots(ctx: Ctx, dbid: number | null, instance = ctx.instance): Promise<HTMLElement> {
  const size = el('select', { 'aria-label': 'Page Size' }, ...[100, 200, 500, 1000, 5000].map(n => el('option', { value: String(n) }, String(n)))) as HTMLSelectElement;
  const prev = el('button', { type: 'button' }, 'Previous') as HTMLButtonElement, next = el('button', { type: 'button' }, 'Next') as HTMLButtonElement;
  const at = el('span', { class: 'meta' }), list = el('div'), objs = el('div');
  const cutCell = (v: unknown, r: Row) => r.cut ? `${String(v ?? '')} ...` : String(v ?? '');
  let page = 1, seq = 0;
  // DBA Dash's Export (control audit D3 b): every object as it stood at the snapshot, one .sql file each, in a zip
  const exportAt = async (r: Row, b: HTMLButtonElement) => {
    b.disabled = true;
    try {
      const d = await get<{ ddl_at: Table | null }>('schema', { instance, ...window_(ctx), part: 'ddl_at', db: String(r.dbid), snap_at: String(r.snapshot_at) });
      const at = new Date(String(r.snapshot_at)), enc = new TextEncoder(), safe = (v: unknown) => String(v ?? '').replace(/[^A-Za-z0-9._-]+/g, '_');
      const files = rowsOf(d.ddl_at).map(o => ({
        name: `${safe(o.schema_name)}.${safe(o.object_name)}.${safe(o.kind)}.sql`,
        data: enc.encode(`-- ${String(o.kind)} ${String(o.identity)} as pgvigil stored it at ${fmtTime(r.snapshot_at)} (a definition past 20,000 characters is stored cut;\n` +
          `-- a body under a masking policy is stored as its hash)\n${String(o.definition ?? '')}\n`),
      }));
      saveBlob(await zip(files, at), `${safe(r.database)}-schema-${fileStamp(at)}.zip`);
    } catch (e) { objs.replaceChildren(errorBox(e)); } finally { b.disabled = false; }
  };
  const pick = async (r: Row) => {
    objs.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    try {
      const d = await get<{ ddl_snapshot_objects: Table | null }>('schema',
        { instance, ...window_(ctx), part: 'ddl_snapshot_objects', db: String(r.dbid), snap_at: String(r.snapshot_at) });
      objs.replaceChildren(el('h4', {}, `The snapshot of ${fmtTime(r.snapshot_at)}${r.baseline ? ' (the first read: every object it found)' : ''}`),
        grid(rowsOf(d.ddl_snapshot_objects), [
          { key: 'object_name', label: 'Object Name' }, { key: 'schema_name', label: 'Schema Name' }, { key: 'kind', label: 'type' },
          { key: 'change', label: 'Action' }, { key: 'attribute', label: 'what changed' },
          { key: 'after', label: 'View', wide: true, fmt: cutCell },
          { key: 'diff', label: 'Diff', fmt: (v, x) => x.baseline ? '' : compareCell(ctx)(v, x) },
        ], 'No object in this snapshot.'));
    } catch (e) { objs.replaceChildren(errorBox(e)); }
  };
  const draw = async () => {
    const mine = ++seq;
    try {
      const d = await get<{ ddl_snapshots: Table | null }>('schema',
        { instance, ...window_(ctx), part: 'ddl_snapshots', db: dbid == null ? undefined : String(dbid), size: size.value, page });
      if (mine !== seq) return;
      const rows = rowsOf(d.ddl_snapshots);
      prev.disabled = page <= 1;
      next.disabled = rows.length < Number(size.value);
      at.textContent = ` Page ${page} `;
      list.replaceChildren(grid(rows, [
        // the instance's list (DBA Dash's Instance link: every database's snapshots) names each row's database
        ...(dbid == null ? [{ key: 'database', label: 'DB' }] : []),
        { key: 'snapshot_at', label: 'Snapshot Date', fmt: fmtTime }, { key: 'validated_at', label: 'Validated Date', fmt: fmtTime },
        { key: 'valid_for_days', label: 'Valid For (Days)', num: true }, { key: 'days_since_validation', label: 'Days Since Validation', num: true },
        { key: 'created', label: 'Created', num: true }, { key: 'modified', label: 'Modified', num: true }, { key: 'dropped', label: 'Dropped', num: true },
        { key: 'objects', label: 'objects', fmt: (_, r) => { const b = el('button', { type: 'button' }, 'Objects'); b.addEventListener('click', () => void pick(r)); return b; } },
        { key: 'export', label: 'Export', fmt: (_, r) => { const b = el('button', { type: 'button' }, 'Export') as HTMLButtonElement; b.addEventListener('click', () => void exportAt(r, b)); return b; } },
      ], page > 1 ? 'No more snapshots: this page is past the last.' : 'No schema snapshot of this database yet: the first read is its baseline.'));
    } catch (e) { if (mine === seq) list.replaceChildren(errorBox(e)); }
  };
  prev.addEventListener('click', () => { if (page > 1) { page--; void draw(); } });
  next.addEventListener('click', () => { page++; void draw(); });
  size.addEventListener('change', () => { page = 1; void draw(); });
  await draw();
  return el('section', {}, el('h3', {}, 'Snapshots'),
    el('div', { class: 'toolbar', role: 'group', 'aria-label': 'Snapshot pages' }, prev, at, next, el('label', {}, ' Page Size ', size)), list, objs);
}

// serviceBroker: DBA Dash's database Service Broker tab (P25 row 73; 0392, the mssql_service_broker collection every 5
// minutes): the user queues as last read (receive disabled = DBA Dash's poison mark; a missing activation procedure),
// each queue's depth over the window, the transmission queue's groups, the conversations by state, the instance's
// endpoint and the Broker counters as rates. DBA Dash shows the tab only when the database has the broker; this page
// keeps it last and says so in words when there is nothing to show.
async function serviceBroker(ctx: Ctx, db: string): Promise<HTMLElement> {
  const part = <T extends string>(p: T, win = false) =>
    get<Record<T, Table | null>>('mssql/checks', { instance: ctx.instance, part: p, db, ...(win ? window_(ctx) : {}) }).then(d => rowsOf(d[p]));
  const [queues, depth, trans, convs, eps, counters, state, read] = await Promise.all([part('broker_queues'), part('broker_depth', true),
    part('broker_transmission'), part('broker_conversations'), part('broker_endpoint'), part('broker_counters', true), part('broker_state'),
    part('broker_read')]);
  const st = state[0], rd = read[0];
  // the database's read state (review t11-8 items 3 / 4): why it was not read, or what the read left out
  const readLine = rd?.note ? el('p', { class: 'meta' }, badge('note', 'warn'),
    rd.read_at ? ` read ${fmtTime(rd.read_at)}; ${String(rd.note)}.` : ` not read: ${String(rd.note)}.`) : '';
  if (!queues.length && !trans.length && !convs.length) {
    return el('div', {}, readLine, el('p', { class: 'empty' }, `No Service Broker read of ${db}: the mssql_service_broker collection reads, every 5 minutes, each database ` +
      `with the broker on that the login may enter` + (rd?.note ? '' : ' (none here, or not read yet)') + (st?.note ? ` - its last run: ${String(st.note)}` : '') + '.'));
  }
  // the depth and the counters keep the window's newest 20,000 samples (review t11-8 item 6)
  const cutWords = (rows: Row[], what: string) => rows.length >= 20000 ? el('p', { class: 'meta' }, `Only the newest 20,000 ${what} of the range are drawn: narrow the range for older ones.`) : '';
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
    note ? el('p', { class: 'meta' }, `The last read did not read ${db}: ${String(note.note)} - these are the values read before.`) : readLine,
    el('h3', {}, 'Queues'),
    grid(queues, [
      { key: 'schema_name', label: 'schema' }, { key: 'queue_name', label: 'queue' },
      { key: 'is_receive_enabled', label: 'receive', fmt: v => v === false ? badge('disabled (a poison message?)', 'crit') : yes(v) },
      { key: 'is_enqueue_enabled', label: 'enqueue', fmt: v => v === false ? badge('disabled', 'warn') : yes(v) },
      { key: 'message_count', label: 'messages', num: true, fmt: (v, r) => v == null ? (r.is_retention_enabled ? el('span', { class: 'meta', title: 'a RETENTION queue also holds received messages: its count is read from the queue, and was not this time' }, 'not read') : '') : fmtNum(v) },
      // a queue whose own read was refused says why (review t11-8 item 12: the documented login holds no SELECT on it)
      { key: 'oldest_message_at', label: 'oldest ready message', fmt: (v, r) => v != null ? fmtTime(v) : r.oldest_note ? el('span', { class: 'meta' }, String(r.oldest_note)) : '' },
      { key: 'activated_tasks', label: 'readers running', num: true }, { key: 'max_readers', label: 'max readers', num: true },
      { key: 'activation_procedure', label: 'activation', fmt: (v, r) => v == null ? (r.is_activation_enabled ? 'on, no procedure' : '') : r.activation_procedure_exists === false ? badge(`${String(v)} (missing)`, 'crit') : String(v) },
      { key: 'monitor_state', label: 'monitor' }, { key: 'monitor_last_activated', label: 'last activated', fmt: fmtTime },
      { key: 'is_present', label: 'in the database', fmt: v => v ? 'yes' : 'no longer' }, { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], 'No user queue in this database.'),
    names.length ? lineChart('Queue depth (messages)', [...at.values()], names.map(n => ({ key: n, label: n })), v => fmtNum(v)) : '', cutWords(depth, 'depth samples'),
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
    cNames.length ? lineChart('Broker counters (per second)', [...cAt.values()], cNames.map(n => ({ key: n, label: n })), v => fmtNum(v)) : '', cutWords(counters, 'counter rates'));
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
  // review t11-9 item 12: the procedure splices @DBName into its own statements (the pinned file L260, L459, L736) and
  // reads every database for 'All': such a name is refused here, with why
  if (db.includes("'") || db.toLowerCase() === 'all') {
    return el('p', { class: 'empty' }, `sp_DBPermissions is not run for ${db}: the procedure splices the database name into its own statements, so a name that holds a quote breaks it, and the name All reads every database.`);
  }
  const d = await get<{ enabled: boolean; reason?: string; tools: { id: string; installed: boolean | null; state: string; on?: boolean; needs?: { what: string; how?: string; state: string }[] }[] }>('community', { instance: ctx.instance, database: 'master' });
  const tools = el('a', { href: href(ctx, { tab: 'community' }) }, 'Community tools');
  // review t11-9 item 15: the reason alone (a failed connection, a demo instance, a sysadmin read login, the door off)
  if (!d.enabled) return el('p', { class: 'empty' }, d.reason ? `sp_DBPermissions cannot run here: ${d.reason}.` : 'sp_DBPermissions cannot run here.');
  const t = d.tools.find(x => x.id === 'sp_DBPermissions');
  if (!t || t.installed === false) {
    return el('p', { class: 'empty' }, 'sp_DBPermissions is not installed on this instance (in master): the ', tools,
      ' page prints its install script - the file at the commit pgvigil was tested with, its SHA256 checked before it runs.');
  }
  // review t11-9 item 5: the server's own words for what the tool lacks here (a login that cannot see the procedure, no
  // EXECUTE on it: each with its line), never the tab's guess
  if (t.on === false) {
    return el('div', {}, el('p', { class: 'empty' }, 'sp_DBPermissions cannot run here as things stand:'),
      el('ul', {}, ...(t.needs ?? []).map(n => el('li', {}, n.what, n.how ? el('span', { class: 'meta' }, ` - ${n.how}`) : ''))));
  }
  const notes = (t.needs ?? []).filter(n => n.state === 'note').map(n => n.what);
  const res = el('div'), status = el('span', { class: 'meta', role: 'status' });
  // review t11-9 item 2: the run needs operator - a viewer sees the button off and why
  const run = needControl(el('button', { type: 'button' }, `Run sp_DBPermissions for ${db}`), 'community/run');
  run.addEventListener('click', async () => {
    status.textContent = 'Running...'; offControl(run, 'running', status);
    try {
      const r = await post<{ runs: InstanceRun[]; ran_at?: string } | Queued>('community/run', { instance_id: ctx.instance, tool: 'sp_DBPermissions', database: 'master', params: { DBName: db } });
      // review t11-9 item 3: in queue mode the collector runs it; its answer is waited for and drawn here
      if (isQueued(r)) {
        res.replaceChildren();
        const e = await waitRequest(r, status, res);
        res.replaceChildren(...cutWords(e), endView(e, String(inst?.name ?? ctx.instance), 'sqlserver', 'sp_DBPermissions'));
      } else {
        res.replaceChildren(resultView(r.runs, undefined, 'sp_DBPermissions'));
        status.textContent = r.ran_at ? `Ran at ${fmtTime(r.ran_at)}.` : '';
      }
    } catch (e) { res.replaceChildren(errorBox(e)); status.textContent = ''; } finally { offControl(run, null, status); }
  });
  return el('div', {}, el('p', { class: 'meta' }, `sp_DBPermissions for ${db}: its principals, their role memberships and their permissions, each with the statement that would recreate it. A run is the Community tools door's, audited.`),
    el('p', { class: 'meta' }, 'Runs on one instance go one at a time here (the procedure keeps its rows in global temp tables); a run of DBA Dash\'s own tab at the same moment would still cross its results.'),
    notes.length ? el('p', { class: 'meta', role: 'note' }, notes.join(' ')) : '',
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
