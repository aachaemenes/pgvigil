// A SQL Server database's own page (P25, F101 / F103; DBA Dash's database node, GUI/Main.cs L1903-1914): its tab
// strip - Performance first, as DBA Dash opens a database on it - each tab the instance's page cut to this database.
// #/mssqldb?i=<instance>&db=<database name>[&dbtab=<tab>][&fg=<file group>]. The tree's database node links here
// (tree.ts, a wiring line of the join).
import { Ctx } from './router';
import { hashParam, hrefWith } from './dbinfo';
import { performanceView } from './performance';
import { mssqlFilesView } from './mssql_storage';
import { mssqlQueryStoreView } from './mssql_querystore';
import { dbSpaceView } from './drives';
import { mssqlPlanCacheView } from './mssql_plancache';
import { get, rowsOf, Table } from './api';
import { badge, el, grid } from './ui';

export const mssqlDbTab = 'mssqldb';

// the 13 tabs in DBA Dash's order; built: the ones this page cuts to the database
const tabs: [string, string][] = [
  ['performance', 'Performance'], ['objexec', 'Object Execution'], ['querystats', 'Query Stats'], ['slow', 'Slow Queries'],
  ['files', 'Files'], ['snapshots', 'Snapshot Summary'], ['dbspace', 'DB Space'], ['dbconfig', 'DB Configuration'],
  ['dboptions', 'DB Options'], ['qs', 'QS'], ['topqueries', 'Top Queries'], ['forcedplans', 'Forced Plans'], ['tuning', 'Tuning Recommendations'],
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
    case 'querystats':
      // DBA Dash's Query Stats (sys.dm_exec_query_stats per database and query hash) = the instance's Plan cache page
      // fixed on this database
      body = await mssqlPlanCacheView(ctx, db);
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
    default:
      body = el('p', { class: 'empty' }, `${tabs.find(([k]) => k === tab)![1]} for ${db}: not on this page yet.`);
  }
  sec.append(body);
  return sec;
}
