// The drill-down pages (task 48; DBADash's per-object drill-down), reached from the Database info tab, the Growth root,
// the side tree's database, table and job nodes, and the Tables, Jobs, Job report and Indexes tabs (task 65): a
// database page, a table page, a job page and an index page, each under a
// breadcrumb instance > database > table that keeps the time range. Their parameters ride on the hash
// (#/db?i=..&db=<dbid>, #/table?..&db=&rel=<relid>, #/job?..&scheduler=&job=, #/index?..&db=&idx=<indexrelid>).
// Data from /api/drill/{db,table,job,index}.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { fleet } from './fleet';
import { Ctx, href, window_, rangeLabel } from './router';
import { dbLink, grownTxt, hashParam, hrefWith, link, tableLink } from './dbinfo';
import { schemaDbSection } from './schema';
import { badge, Col, el, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, props, tile } from './ui';

type Parts<K extends string> = Record<K, Table | null>;

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const yesNo = (v: unknown) => v == null ? '' : v ? 'yes' : 'no';
const ms = (v: unknown) => v == null ? '' : fmtNum(Math.round(Number(v) * 10) / 10) + ' ms';
const qtext = (v: unknown) => { const s = v == null ? '(no statement text: the query-text policy, or not read yet)' : String(v); return s.length > 600 ? s.slice(0, 600) + '...' : s; };
const pre = (v: unknown) => el('pre', { class: 'sql' }, String(v ?? ''));

// jobLink and indexLink open the job and index pages (the Jobs, Job report and Indexes tabs and the tree use them).
export const jobLink = (ctx: Ctx, text: string, scheduler: unknown, job: unknown, instance = ctx.instance) =>
  link(text, hrefWith(ctx, 'job', { scheduler: String(scheduler), job: String(job) }, instance));
export const indexLink = (ctx: Ctx, text: string, dbid: unknown, idx: unknown, instance = ctx.instance) =>
  link(text, hrefWith(ctx, 'index', { db: String(dbid), idx: String(idx) }, instance));

// crumbs: instance > [mid >] database > table > leaf, each a link but the last, the time range kept.
async function crumbs(ctx: Ctx, db?: { dbid: unknown; name: unknown }, table?: { relid: unknown; name: string }, leaf?: string, mid?: Node): Promise<HTMLElement> {
  let inst = 'instance ' + ctx.instance;
  try { const f = await fleet(); const r = f.instances.find(x => Number(x.instance_id) === ctx.instance); if (r) inst = String(r.name); } catch { /* the name is cosmetic */ }
  const parts: (Node | string)[] = [link(inst, href(ctx, { tab: 'summary' }))];
  if (mid) parts.push(' > ', mid);
  if (db) parts.push(' > ', !table && !leaf ? el('b', {}, String(db.name ?? '')) : dbLink(ctx, db.name, db.dbid));
  if (db && table) parts.push(' > ', !leaf ? el('b', {}, table.name) : tableLink(ctx, table.name, db.dbid, table.relid));
  if (leaf) parts.push(' > ', el('b', {}, leaf));
  return el('nav', { class: 'meta', 'aria-label': 'breadcrumb' }, ...parts);
}

const missing = (what: string) => el('p', { class: 'empty' }, `This page needs ${what} in its link (open it from the Database info, Growth, Jobs or Indexes tab).`);

const stmtCols: Col[] = [
  { key: 'datname', label: 'db' }, { key: 'usename', label: 'user' },
  { key: 'calls', num: true, fmt: v => fmtNum(Math.round(Number(v ?? 0))) },
  { key: 'total_exec_ms', label: 'total', num: true, fmt: ms }, { key: 'mean_exec_ms', label: 'mean', num: true, fmt: ms },
  { key: 'rows', num: true, fmt: v => fmtNum(Math.round(Number(v ?? 0))) },
  { key: 'hit_pct', label: 'cache hit', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' %' },
  { key: 'query', wide: true, fmt: qtext },
];

// ---- the database page
export async function dbPage(ctx: Ctx): Promise<HTMLElement> {
  const db = hashParam('db');
  if (!db) return missing('a database (db=)');
  const d = await get<Parts<'facts' | 'series' | 'tables' | 'extensions' | 'acl' | 'jobs' | 'slow' | 'statements' | 'series_meta'>>('drill/db',
    { instance: ctx.instance, db, ...window_(ctx) });
  const f = rowsOf(d.facts)[0];
  if (!f) return el('section', {}, await crumbs(ctx), el('p', { class: 'empty' }, `No database ${db} on this instance (the databases collection runs hourly).`));
  const sec = el('section', {}, await crumbs(ctx, { dbid: db, name: f.datname }), el('h2', {}, `Database ${String(f.datname)}` + (f.is_present ? '' : ' (dropped)')));
  sec.append(el('div', { class: 'tiles' },
    tile('size', fmtBytes(f.size_bytes) || '-'),
    tile('grown (7 d)', grownTxt(f.grown_7d_bytes)),
    tile('grown (30 d)', grownTxt(f.grown_30d_bytes)),
    tile('tables read', fmtNum(f.tables_read)),
    tile('collation version', f.collation_mismatch ? 'changed' : 'current', f.collation_mismatch ? 'warn' : 'ok')));
  sec.append(props([
    ['owner', String(f.owner ?? '')], ['encoding', String(f.encoding ?? '')],
    ['collation / ctype', `${String(f.lc_collate ?? '')} / ${String(f.lc_ctype ?? '')}`],
    ['locale provider', `${String(f.locale_provider ?? '')}${f.locale ? ' (' + String(f.locale) + ')' : ''}`],
    ['collation version', f.collation_mismatch ? `${String(f.collation_recorded)} recorded, the library has ${String(f.collation_actual)}` : String(f.collation_recorded ?? '')],
    ['connection limit', Number(f.conn_limit) < 0 ? 'none' : fmtNum(f.conn_limit)],
    ['tablespace', `${String(f.tablespace ?? '')}${f.tablespace_bytes != null ? ' (' + fmtBytes(f.tablespace_bytes) + ')' : ''}`],
    ['allow connections', yesNo(f.allow_conn)], ['template', yesNo(f.is_template)], ['the login connects', yesNo(f.can_connect)],
    ['xid age / mxid age', `${fmtNum(f.xid_age)} / ${fmtNum(f.mxid_age)}`],
    ['comment', String(f.comment ?? '')], ['first seen', fmtTime(f.first_seen)], ['read', fmtTime(f.snapshot_at)],
  ]));
  const meta = rowsOf(d.series_meta)[0] ?? {};
  sec.append(el('div', { class: 'charts' },
    lineChart(`Size (${fmtTime(meta.from_at)} to ${fmtTime(meta.to_at)})`, rowsOf(d.series), [{ key: 'size_bytes', label: String(f.datname) }], v => fmtBytes(v)),
    lineChart('Transaction-id age', rowsOf(d.series), [{ key: 'xid_age', label: 'age(datfrozenxid)' }], v => fmtNum(v))));

  sec.append(el('h3', {}, 'Tables'), grid(rowsOf(d.tables), [
    { key: 'table_name', label: 'table', fmt: (v, r) => tableLink(ctx, `${String(r.schema_name)}.${String(v)}`, db, r.relid) },
    { key: 'total_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'index_bytes', label: 'indexes', num: true, fmt: fmtBytes },
    { key: 'n_live_tup', label: 'live rows', num: true, fmt: fmtNum }, { key: 'dead_pct', label: 'dead %', num: true },
    { key: 'bloat_pct', label: 'bloat %', num: true }, { key: 'last_vacuum', label: 'vacuumed', fmt: fmtTime },
    { key: 'last_analyze', label: 'analyzed', fmt: fmtTime }, { key: 'seq_scan', label: 'seq scans', num: true, fmt: fmtNum },
    { key: 'idx_scan', label: 'idx scans', num: true, fmt: fmtNum }, { key: 'checks', fmt: v => v ? badge(String(v), 'warn') : '' },
  ], 'No table read in this database: the tables collection keeps the largest tables of each database it can connect to.'));

  sec.append(el('h3', {}, 'Extensions'), grid(rowsOf(d.extensions), [
    { key: 'name' }, { key: 'version', fmt: (v, r) => r.outdated ? badge(`${String(v)} (default ${String(r.default_version)})`, 'warn') : String(v ?? '') },
    { key: 'schema_name', label: 'schema' }, { key: 'comment', wide: true },
  ], 'No extension read for this database.'));

  sec.append(el('h3', {}, 'Access'), grid(rowsOf(d.acl), [
    { key: 'level' }, { key: 'object' }, { key: 'grantee' }, { key: 'privileges' }, { key: 'grantable', label: 'with grant option' },
    { key: 'grantor' }, { key: 'is_default', label: 'built-in default', fmt: yesNo },
  ], 'No ACL read for this database (the roles collection reads the databases the login may connect to).'));

  sec.append(el('h3', {}, 'Jobs'), grid(rowsOf(d.jobs), [
    { key: 'job_name', label: 'job', fmt: (v, r) => jobLink(ctx, String(v ?? r.job_id), r.scheduler, r.job_id) },
    { key: 'scheduler' }, { key: 'schedule' }, { key: 'active', fmt: yesNo }, { key: 'next_run', label: 'next run', fmt: fmtTime },
    { key: 'last_status', label: 'last', fmt: (v, r) => r.last_running ? badge('running', '') : v === 'succeeded' ? String(v) : v ? badge(String(v), 'crit') : '' },
    { key: 'last_start', label: 'started', fmt: fmtTime }, { key: 'last_duration_secs', label: 'took', num: true, fmt: fmtSecs },
    { key: 'failures_7d', label: 'failed (7 d)', num: true }, { key: 'fail_streak', label: 'failing in a row', num: true },
    { key: 'missed', fmt: v => v ? badge('missed', 'warn') : '' },
  ], 'No scheduled job runs in this database.'));

  sec.append(el('h3', {}, `Slow queries (${rangeLabel(ctx)})`), grid(rowsOf(d.slow), [
    { key: 'statements', label: 'count', num: true }, { key: 'total_ms', label: 'total', num: true, fmt: ms },
    { key: 'mean_ms', label: 'mean', num: true, fmt: ms }, { key: 'max_ms', label: 'longest', num: true, fmt: ms },
    { key: 'last_at', label: 'last', fmt: fmtTime }, { key: 'users' }, { key: 'example', wide: true, fmt: qtext },
  ], 'No slow statement logged in this database in the range (the server log reader, log_min_duration_statement).'));

  sec.append(el('h3', {}, `Top statements by total time (${rangeLabel(ctx)})`), grid(rowsOf(d.statements), stmtCols,
    'No statement in this database in the range (pg_stat_statements, the statements collection).'));
  sec.append(await schemaDbSection(ctx, db));
  return sec;
}

// ---- the table page
export async function tablePage(ctx: Ctx): Promise<HTMLElement> {
  const db = hashParam('db'), rel = hashParam('rel');
  if (!db || !rel) return missing('a database and a table (db=, rel=)');
  const d = await get<Parts<'table' | 'series' | 'vacuum' | 'checks' | 'indexes' | 'statements' | 'series_meta'>>('drill/table',
    { instance: ctx.instance, db, rel, ...window_(ctx) });
  const t = rowsOf(d.table)[0];
  if (!t) return el('section', {}, await crumbs(ctx), el('p', { class: 'empty' }, 'This table is not in the tables collection (it keeps the largest tables of each database).'));
  const name = `${String(t.schema_name)}.${String(t.table_name)}`;
  const sec = el('section', {}, await crumbs(ctx, { dbid: db, name: t.datname }, { relid: rel, name }),
    el('h2', {}, `Table ${name}` + (t.is_present ? '' : ' (no longer in the top tables, or dropped)')));
  const checks = rowsOf(d.checks);
  sec.append(el('div', { class: 'tiles' },
    tile('size', fmtBytes(t.total_bytes) || '-'), tile('live rows', fmtNum(t.n_live_tup)),
    tile('dead rows', t.dead_pct == null ? '-' : `${fmtNum(t.n_dead_tup)} (${fmtNum(t.dead_pct)} %)`),
    tile('bloat', t.bloat_pct == null ? '-' : `${fmtNum(t.bloat_pct)} % (${fmtBytes(t.bloat_bytes)})`),
    tile('checks', String(checks.length), checks.some(c => c.severity === 'critical') ? 'crit' : checks.length ? 'warn' : 'ok')));
  if (checks.length) sec.append(el('h3', {}, 'Checks'), grid(checks, [{ key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'check' }, { key: 'detail', wide: true }, { key: 'at', fmt: fmtTime }]));
  sec.append(props([
    ['heap / TOAST / indexes', `${fmtBytes(t.heap_bytes)} / ${fmtBytes(t.toast_bytes)} / ${fmtBytes(t.index_bytes)}`],
    ['all-visible', t.all_visible_pct == null ? '' : fmtNum(t.all_visible_pct) + ' %'],
    ['last vacuum (auto)', `${fmtTime(t.last_vacuum)} (${fmtTime(t.last_autovacuum)})`],
    ['last analyze (auto)', `${fmtTime(t.last_analyze)} (${fmtTime(t.last_autoanalyze)})`],
    ['vacuums / analyzes since the reset', `${fmtNum(t.vacuums)} / ${fmtNum(t.analyzes)}`],
    ['changed since analyze / inserted since vacuum', `${fmtNum(t.n_mod_since_analyze)} / ${fmtNum(t.n_ins_since_vacuum)}`],
    ['autovacuum triggers at (dead / inserts / changes)', `${fmtNum(t.vac_threshold == null ? null : Math.round(Number(t.vac_threshold)))} / ${fmtNum(t.ins_threshold == null ? null : Math.round(Number(t.ins_threshold)))} / ${fmtNum(t.anl_threshold == null ? null : Math.round(Number(t.anl_threshold)))}`],
    ['autovacuum', t.autovacuum_off ? 'off on this table' : t.has_own_settings ? 'its own settings' : 'the server settings'],
    ['xid age / freeze max age', `${fmtNum(t.xid_age)} / ${fmtNum(t.freeze_max_age)}`],
    ['seq scans / index scans', `${fmtNum(t.seq_scan)} / ${fmtNum(t.idx_scan)}`],
    ['first seen', fmtTime(t.first_seen)], ['read', fmtTime(t.snapshot_at)],
  ]));
  const s = rowsOf(d.series), meta = rowsOf(d.series_meta)[0] ?? {};
  sec.append(el('div', { class: 'charts' },
    lineChart(`Size (${fmtTime(meta.from_at)} to ${fmtTime(meta.to_at)})`, s, [{ key: 'total_bytes', label: 'total' }, { key: 'bloat_bytes', label: 'bloat' }], v => fmtBytes(v)),
    lineChart('Live and dead rows', s, [{ key: 'n_live_tup', label: 'live' }, { key: 'n_dead_tup', label: 'dead' }], v => fmtNum(v))));

  sec.append(el('h3', {}, `Vacuum and analyze runs (${rangeLabel(ctx)})`), grid(rowsOf(d.vacuum), [
    { key: 'started_at', label: 'started', fmt: fmtTime }, { key: 'kind' }, { key: 'is_auto', label: 'auto', fmt: yesNo },
    { key: 'is_wraparound', label: 'wraparound', fmt: v => v ? badge('yes', 'warn') : '' },
    { key: 'elapsed_secs', label: 'at least', num: true, fmt: fmtSecs }, { key: 'last_phase', label: 'phase' },
    { key: 'heap_blks_scanned', label: 'blocks scanned', num: true, fmt: fmtNum }, { key: 'dead_tuples', label: 'dead rows', num: true, fmt: fmtNum },
    { key: 'waited_lock', label: 'waited on a lock', fmt: v => v ? badge('yes', 'warn') : '' }, { key: 'source' }, { key: 'detail', wide: true },
  ], 'No vacuum or analyze of this table seen in the range (the vacuum collection samples each minute; the server log adds the autovacuum lines).'));

  sec.append(el('h3', {}, 'Indexes'),
    el('p', { class: 'meta' }, `Indexes total ${fmtBytes(t.index_bytes) || '-'}. The indexes collection keeps the indexes that cost without serving: unused, redundant, duplicate or invalid; those on this table are below.`),
    grid(rowsOf(d.indexes), [
      { key: 'index_name', label: 'index', fmt: (v, r) => indexLink(ctx, String(v ?? r.indexrelid), db, r.indexrelid) },
      { key: 'problems', fmt: v => badge(String(v ?? ''), String(v ?? '').match(/invalid|duplicate/) ? 'warn' : '') },
      { key: 'index_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'idx_scan', label: 'scans', num: true, fmt: fmtNum },
      { key: 'covered_by', label: 'covered by' }, { key: 'index_def', label: 'definition', wide: true },
    ], 'No index problem on this table.'));

  sec.append(el('h3', {}, `Statements that name it (${rangeLabel(ctx)})`),
    el('p', { class: 'meta' }, `Statements of this database whose text holds "${String(t.table_name)}" as a whole word, by total time: a same-named table in another schema or a column of that name matches too.`),
    grid(rowsOf(d.statements), stmtCols, 'No statement naming this table in the range.'));
  return sec;
}

// ---- the job page
export async function jobPage(ctx: Ctx): Promise<HTMLElement> {
  const sched = hashParam('scheduler'), job = hashParam('job');
  if (!sched || !job) return missing('a job (scheduler=, job=)');
  const d = await get<Parts<'job' | 'runs'>>('drill/job', { instance: ctx.instance, scheduler: sched, job, ...window_(ctx) });
  const j = rowsOf(d.job)[0];
  if (!j) return el('section', {}, await crumbs(ctx), el('p', { class: 'empty' }, `No ${sched} job ${job} on this instance.`));
  const runs = rowsOf(d.runs);
  const label = String(j.job_name ?? `job ${job}`);
  const nav = await crumbs(ctx, undefined, undefined, label, link('Jobs', href(ctx, { tab: 'jobs' })));
  const sec = el('section', {}, nav, el('h2', {}, `Job ${label} (${sched})` + (j.is_present ? '' : ' (removed)')));
  const failed = runs.filter(r => r.failed).length;
  sec.append(el('div', { class: 'tiles' },
    tile('last run', j.last_running ? 'running' : String(j.last_status ?? '-'), j.last_running ? '' : j.last_status === 'succeeded' ? 'ok' : j.last_status ? 'crit' : ''),
    tile('next run', fmtTime(j.next_run) || '-'),
    tile(`failed (${rangeLabel(ctx)})`, `${failed} of ${runs.length}`, failed ? 'crit' : 'ok'),
    tile('average (7 d)', j.avg_7d_secs == null ? '-' : fmtSecs(j.avg_7d_secs)),
    tile('missed', j.missed ? 'yes' : 'no', j.missed ? 'warn' : 'ok')));
  sec.append(props([
    ['schedule', String(j.schedule ?? '') + (j.schedule_note ? ` (${String(j.schedule_note)})` : '')], ['active', yesNo(j.active)],
    ['database', j.datname ? String(j.datname) : ''], ['runs as', String(j.run_as ?? '')],
    ['runs / failures (7 d)', `${fmtNum(j.runs_7d)} / ${fmtNum(j.failures_7d)}`], ['runs / failures (30 d)', `${fmtNum(j.runs_30d)} / ${fmtNum(j.failures_30d)}`],
    ['longest (7 d / 30 d)', `${fmtSecs(j.max_7d_secs)} / ${fmtSecs(j.max_30d_secs)}`], ['last success', fmtTime(j.last_ok)],
    ['failing in a row', fmtNum(j.fail_streak)], ['over its average', j.over_average ? 'yes: the last run took over twice the average' : 'no'],
    ['first seen', fmtTime(j.first_seen)], ['read', fmtTime(j.snapshot_at)],
  ]));
  sec.append(el('h3', {}, 'Command'), pre(j.command));
  const chartRows = runs.filter(r => r.duration_secs != null).map(r => ({ snapshot_at: r.start_time, duration_secs: r.duration_secs }))
    .sort((a, b) => Date.parse(String(a.snapshot_at)) - Date.parse(String(b.snapshot_at)));
  sec.append(el('div', { class: 'charts' }, lineChart('Run duration', chartRows as Row[], [{ key: 'duration_secs', label: 'seconds' }], v => fmtSecs(v))));
  sec.append(el('h3', {}, `Runs (${rangeLabel(ctx)})`), grid(runs, [
    { key: 'start_time', label: 'started', fmt: fmtTime }, { key: 'end_time', label: 'ended', fmt: fmtTime },
    { key: 'duration_secs', label: 'took', num: true, fmt: (v, r) => (r.running ? 'running ' : '') + fmtSecs(v) },
    { key: 'status', fmt: (v, r) => r.failed ? badge(String(v), 'crit') : String(v ?? '') },
    { key: 'return_message', label: 'message', wide: true }, { key: 'datname', label: 'db' }, { key: 'run_as', label: 'as' }, { key: 'job_pid', label: 'pid' },
  ], 'No run of this job started in the range.'));
  return sec;
}

// ---- the index page
export async function indexPage(ctx: Ctx): Promise<HTMLElement> {
  const db = hashParam('db'), idx = hashParam('idx');
  if (!db || !idx) return missing('a database and an index (db=, idx=)');
  const d = await get<Parts<'index'>>('drill/index', { instance: ctx.instance, db, idx });
  const rows = rowsOf(d.index), x = rows[0];
  if (!x) return el('section', {}, await crumbs(ctx), el('p', { class: 'empty' }, 'The indexes collection holds no row for this index: the inventory is read hourly on every database the monitoring login can connect to.'));
  const problems = rows.filter(r => r.problem != null);
  const name = `${String(x.schema_name ?? '')}.${String(x.index_name ?? idx)}`;
  const table = `${String(x.schema_name ?? '')}.${String(x.table_name ?? '')}`;
  const nav = x.relid != null ? await crumbs(ctx, { dbid: db, name: x.datname }, { relid: x.relid, name: table }, name)
    : await crumbs(ctx, { dbid: db, name: x.datname }, undefined, `${table} > ${name}`);
  const sec = el('section', {}, nav, el('h2', {}, `Index ${name}` + (x.is_present ? '' : ' (no longer found)')));
  sec.append(el('div', { class: 'tiles' },
    tile('size', fmtBytes(x.index_bytes) || '-'), tile('table size', fmtBytes(x.table_bytes) || '-'),
    tile('index scans', fmtNum(x.idx_scan)), tile('problems', problems.length ? problems.map(r => String(r.problem)).join(', ') : 'none', problems.some(r => r.severity === 'warning') ? 'warn' : '')));
  sec.append(props([
    ['access method', String(x.access_method ?? '')],
    ['scans counted since', x.stats_since ? fmtTime(x.stats_since) : 'unknown'],
    ['this server', x.is_replica ? 'a replica: it counts only its own reads' : 'the primary: it counts only its own reads, not the replicas\''],
    ['first seen', fmtTime(x.first_seen)], [x.problem == null ? 'last change (the inventory keeps a quiet index\'s row as it is)' : 'read', fmtTime(x.snapshot_at)],
  ]));
  sec.append(el('h3', {}, 'Definition'), pre(x.index_def));
  for (const r of problems) {
    sec.append(el('h3', {}, `${String(r.problem)} index`),
      r.finding ? el('p', {}, sevBadge(r.severity), ' ', String(r.finding), r.suggested ? ` Suggested: ${String(r.suggested)}.` : '')
        : el('p', { class: 'meta' }, r.problem === 'unused' ? 'Not a finding yet: an unused index counts once it is 10 MB or more, its counters have run 7 days and the server is not a replica.' : ''));
    if (r.covered_by) sec.append(props([['covered by', String(r.covered_by)], ['its definition', String(r.covered_by_def ?? '')], ...(r.supports_fk ? [['foreign key', 'it may serve a foreign key: check before dropping'] as [string, string]] : [])]));
    if (r.drop_sql) {
      sec.append(el('p', { class: 'meta' }, 'The lines below are text for a DBA to read and run by hand; pgvigil never runs them. Run the DROP alone, outside a transaction.'),
        el('h4', {}, 'Drop'), pre(r.drop_sql), el('h4', {}, 'Undo'), pre(r.undo_sql));
    }
  }
  return sec;
}
