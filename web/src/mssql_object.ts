// The object page (OBJ, the lead's 11-17 13:27 / 13:42: DBA Dash's object window - DBADashGUI/Performance/
// ObjectDetailControl.cs in DetailForm): one procedure, function or trigger of a SQL Server instance, the object in the
// address (#/mssqlobject?i=&db=&obj=[&otab=]; every link to it a real href, so Ctrl+click opens a browser tab - DBA
// Dash's new window), its tabs in DBA Dash's order. The name is read as DBA Dash reads it (one, two or three parts,
// [brackets] and "quotes" whole: the server's splitObjectName); the lookup (/api/mssql/procs part=object_lookup) finds
// it in the window's execution statistics and the schema snapshot - several matches are said with the one shown, none
// is said (DBA Dash's status line). A tab the lookup cannot fill is left out and said why (DBA Dash's BuildTabs). The
// hash window is sqltoolsbuild-s3's page (#/qhash): linked from here, not built here.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { hashParam, hrefWith } from './dbinfo';
import { Ctx, window_ } from './router';
import { compareCell } from './schema';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

export const mssqlObjectTab = 'mssqlobject';

// mssqlObjectHref: an object of a SQL Server instance's database, opened on its page (the tab given, else the first)
export const mssqlObjectHref = (ctx: Ctx, db: string, obj: string, tab?: string, instance = ctx.instance) =>
  hrefWith(ctx, mssqlObjectTab, { db, obj, otab: tab }, instance);

// mssqlObjectCell: an object's name as a link to its page (schema.name in its database; the tab given) - every
// object-name cell of the app lands here (the cells in other slices' files: scripts/PARITY-S3-join-lines.sql line 13);
// a part holding a dot, a bracket or a quote goes in [brackets] (]] for a ]) so the page's name split reads it back
const quotePart = (s: string) => /[.\[\]"]/.test(s) ? `[${s.replace(/]/g, ']]')}]` : s;
export const mssqlObjectName = (schema: unknown, name: unknown): string =>
  schema == null || schema === '' ? quotePart(String(name ?? '')) : `${quotePart(String(schema))}.${quotePart(String(name ?? ''))}`;
export const mssqlObjectCell = (ctx: Ctx, db: string, schema: unknown, name: unknown, tab?: string, instance = ctx.instance): Node =>
  name == null || name === '' ? document.createTextNode('') : el('a', { href: mssqlObjectHref(ctx, db, mssqlObjectName(schema, name), tab, instance) }, String(name));

// DBA Dash's tabs in its order (ObjectDetailControl.BuildTabs)
const tabs: [string, string][] = [['objexec', 'Object Execution'], ['querystats', 'Query Stats'], ['running', 'Running Queries'], ['slow', 'Slow Queries'], ['qs', 'Query Store'], ['schema', 'Schema History']];

export async function mssqlObjectView(ctx: Ctx): Promise<HTMLElement> {
  const db = (hashParam('db') ?? '').slice(0, 128), obj = (hashParam('obj') ?? '').slice(0, 386);
  const sec = el('section', {}, el('h2', {}, obj ? `Object ${obj}` : 'Object'));
  if (!obj) {
    sec.append(el('p', { class: 'empty' }, 'No object named (obj=): the page opens from an object\'s name.'));
    return sec;
  }
  let found: Row[];
  try {
    found = rowsOf((await get<{ object_lookup: Table | null }>('mssql/procs',
      { instance: ctx.instance, ...window_(ctx), part: 'object_lookup', obj, ...(db ? { dbname: db } : {}) })).object_lookup);
  } catch (e) {
    sec.append(errorBox(e));
    return sec;
  }
  const o: Row | undefined = found[0];
  const where = o ? String(o.database_name ?? db) : db;
  const title = o ? `${String(o.schema_name ?? '')}.${String(o.object_name ?? '')}` : obj;
  // DBA Dash's status line: the type and the title; a note in the warning colour for several matches or none
  sec.append(el('p', { class: 'meta' }, `${o ? String(o.type_desc ?? o.kind ?? '') + ' ' : ''}${title}${where ? ' / ' + where : ''}`,
    found.length > 1 ? el('span', {}, ' ', badge('note', 'warn'), ` ${found.length} objects match the name ${String(o?.object_name ?? obj)} - showing the one in ${where}.`) : '',
    o ? '' : el('span', {}, ' ', badge('note', 'warn'), ` ${obj} is not in the store: no execution statistics in this range and no schema snapshot hold it, so only the tabs matched by its name are shown.`)));
  // the tabs DBA Dash would leave out (BuildTabs): Query Stats without the schema, Query Store without the database,
  // Schema History without the object in the store; Object Execution, Running and Slow Queries always (matched by name)
  const why: Record<string, string> = {};
  if (!o?.schema_name) why.querystats = 'its schema is not known';
  if (!where) why.qs = 'its database is not known';
  if (!o) why.schema = 'the store does not hold the object';
  const shown = tabs.filter(([k]) => !why[k]);
  const asked = hashParam('otab');
  const tab = shown.some(([k]) => k === asked) ? asked! : shown[0][0];
  sec.append(el('nav', { class: 'subtabs', 'aria-label': `${title}'s pages` }, ...shown.map(([k, label]) =>
    el('a', { href: mssqlObjectHref(ctx, where, obj, k), class: k === tab ? 'on' : '', ...(k === tab ? { 'aria-current': 'page' } : {}) }, label))));
  const left = tabs.filter(([k]) => why[k]);
  if (left.length) sec.append(el('p', { class: 'meta' }, 'Not shown: ' + left.map(([k, label]) => `${label} (${why[k]})`).join('; ') + '.'));
  const name = String(o?.object_name ?? obj), schema = o?.schema_name == null ? '' : String(o.schema_name);
  let body: HTMLElement;
  try {
    switch (tab) {
      case 'objexec': body = await objexecTab(ctx, o); break;
      case 'querystats': body = await statementsTab(ctx, o!); break;
      case 'running': body = runningTab(); break;
      case 'slow': body = await slowTab(ctx, name, where); break;
      case 'qs': body = qsTab(ctx, schema, name, where); break;
      case 'schema': body = await schemaTab(ctx, o!); break;
      default: body = el('p', { class: 'empty' }, 'No such tab.');
    }
  } catch (e) {
    body = errorBox(e);
  }
  sec.append(body);
  return sec;
}

// one part of /api/mssql/procs (the endpoint answers one part a call)
const procsPart = (ctx: Ctx, args: { part: string } & Record<string, string | number | undefined>) =>
  get<Record<string, Table | null>>('mssql/procs', { instance: ctx.instance, ...window_(ctx), ...args }).then(d => rowsOf(d[args.part]));
const ms = (v: unknown) => v == null ? '' : fmtNum(v);

// objexecTab: DBA Dash's Object Execution of the object (E5) - its kind's statistics by its ids: the range's steps
// (duration ms/sec and executions per second) and its reads, newest first
async function objexecTab(ctx: Ctx, o: Row | undefined): Promise<HTMLElement> {
  if (!o || o.object_id == null) return el('p', { class: 'empty' }, 'No execution statistics of this object in the range: no read of the procedure, function and trigger statistics held it.');
  const ids = { db_id: Number(o.database_id), object: String(o.object_id), kind: String(o.kind ?? 'procedure') };
  const [history, intervals] = await Promise.all([procsPart(ctx, { part: 'history', ...ids }), procsPart(ctx, { part: 'intervals', ...ids })]);
  const cols: Col[] = [
    { key: 'snapshot_at', label: 'read', fmt: fmtTime }, { key: 'interval_secs', label: 'seconds', num: true, fmt: ms },
    { key: 'executions', num: true, fmt: ms }, { key: 'duration_ms', label: 'duration (ms)', num: true, fmt: ms },
    { key: 'avg_duration_ms', label: 'avg duration (ms)', num: true, fmt: ms }, { key: 'cpu_ms', label: 'CPU (ms)', num: true, fmt: ms },
    { key: 'avg_cpu_ms', label: 'avg CPU (ms)', num: true, fmt: ms }, { key: 'logical_reads', label: 'logical reads', num: true, fmt: ms },
    { key: 'physical_reads', label: 'physical reads', num: true, fmt: ms }, { key: 'logical_writes', label: 'writes', num: true, fmt: ms },
  ];
  return el('section', {},
    lineChart('Duration (ms/sec) and executions per second', history, [{ key: 'duration_ms_s', label: 'duration ms/sec' }, { key: 'executions_s', label: 'executions/sec' }], v => fmtNum(v)),
    el('h3', {}, 'Its reads'), grid(intervals, cols, 'No read held it in the range.'));
}

// statementsTab: DBA Dash's Query Stats of the object (E7, its Query Stats report by @ObjectName) - the plan cache's
// statements whose module is the object, in its database (part=object_statements); a hash is text until the hash
// window (sqltoolsbuild-s3's #/qhash) lands: a join line
async function statementsTab(ctx: Ctx, o: Row): Promise<HTMLElement> {
  const rows = await procsPart(ctx, { part: 'object_statements', db_id: Number(o.database_id), module: `${String(o.schema_name)}.${String(o.object_name)}` });
  return el('section', {}, el('p', { class: 'meta' }, 'The plan cache\'s statements of this module in the range, the most CPU first (the Plan cache page\'s reads cut to it).'),
    grid(rows, [
      { key: 'query', label: 'statement', wide: true }, { key: 'executions', num: true, fmt: ms },
      { key: 'duration_ms', label: 'duration (ms)', num: true, fmt: ms }, { key: 'avg_duration_ms', label: 'avg duration (ms)', num: true, fmt: ms },
      { key: 'cpu_ms', label: 'CPU (ms)', num: true, fmt: ms }, { key: 'avg_cpu_ms', label: 'avg CPU (ms)', num: true, fmt: ms },
      { key: 'avg_logical_reads', label: 'avg logical reads', num: true, fmt: ms }, { key: 'physical_reads', label: 'physical reads', num: true, fmt: ms },
      { key: 'max_grant_kb', label: 'max grant (KB)', num: true, fmt: ms }, { key: 'plans', num: true, fmt: ms },
      { key: 'last_seen', label: 'last read', fmt: fmtTime }, { key: 'plan_hash', label: 'plan hash' }, { key: 'query_key', label: 'query hash' },
    ], 'No statement of this module in the plan cache\'s reads of the range.'));
}

// runningTab: DBA Dash's Running Queries of the object (E9) - the running requests carry no object column yet: it is
// qsdd-pgtwin's row (DBA Dash's Running Queries A18 / E15; the lead's 11-17 13:42 D2 (a)), read here through a join line
function runningTab(): HTMLElement {
  return el('p', { class: 'empty' }, `The running requests do not carry the object's name yet, so this tab cannot list its requests; the instance's Running queries page lists every request.`);
}

// slowTab: DBA Dash's Slow Queries fixed to the object (E10) - its bare name in its database, one row per client app
async function slowTab(ctx: Ctx, name: string, where: string): Promise<HTMLElement> {
  const rows = await procsPart(ctx, { part: 'object_slow', name, ...(where ? { dbname: where } : {}) });
  return el('section', {}, el('p', { class: 'meta' }, `The slow completions (rpc and batch) of ${name}${where ? ' in ' + where : ''} in the range, one row per client app.`),
    grid(rows, [
      { key: 'client_app', label: 'client app' }, { key: 'events', label: 'completions', num: true, fmt: ms },
      { key: 'total_ms', label: 'total (ms)', num: true, fmt: ms }, { key: 'worst_ms', label: 'worst (ms)', num: true, fmt: ms },
      { key: 'mean_ms', label: 'mean (ms)', num: true, fmt: ms }, { key: 'cpu_ms', label: 'CPU (ms)', num: true, fmt: ms },
      { key: 'logical_reads', label: 'logical reads', num: true, fmt: ms }, { key: 'writes', num: true, fmt: ms },
      { key: 'not_ok', label: 'not OK', num: true, fmt: ms }, { key: 'last_at', label: 'last', fmt: fmtTime },
    ], 'No slow completion of this object in the range.'));
}

// qsTab: DBA Dash's Query Store of the object (E11: its Top Queries) - the Query Store page's Top list with the object in
// its find box (QSPAR's qs=top&qid=<schema.name>&qdb=; the instance and the range kept)
function qsTab(ctx: Ctx, schema: string, name: string, where: string): HTMLElement {
  const qid = `${schema || 'dbo'}.${name}`;
  return el('p', {}, el('a', { href: hrefWith(ctx, 'mssqlqs', { qs: 'top', qid: qid, qdb: where }) }, `Top Queries of ${qid} in ${where}`),
    ' - the Query Store page\'s Top list with the object in its find box.');
}

// schemaTab: DBA Dash's Schema History of the object (E12) - its stored changes, the newest first, each with the Schema
// tab's compare (the whole before and after, side by side)
async function schemaTab(ctx: Ctx, o: Row): Promise<HTMLElement> {
  const rows = await procsPart(ctx, { part: 'object_schema', db_id: Number(o.database_id), schema: String(o.schema_name ?? ''), name: String(o.object_name ?? '') });
  const cut = (v: unknown, r: Row) => r.cut ? `${String(v ?? '')} ...` : String(v ?? '');
  return el('section', {}, el('p', { class: 'meta' }, 'Every stored change of this object (the range does not cut it), the newest first, 200 at most.'),
    grid(rows, [
      { key: 'snapshot_at', label: 'found', fmt: fmtTime }, { key: 'change' }, { key: 'attribute', label: 'what changed' },
      { key: 'before', wide: true, fmt: cut }, { key: 'after', wide: true, fmt: cut },
      { key: 'compare', label: 'before / after', fmt: compareCell(ctx) },
    ], 'No schema snapshots include this object.'));
}
