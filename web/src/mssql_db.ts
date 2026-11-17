// A SQL Server database's own page (P25, F101 / F103; DBA Dash's database node, GUI/Main.cs L1903-1914): its tab
// strip - Performance first, as DBA Dash opens a database on it - each tab the instance's page cut to this database.
// #/mssqldb?i=<instance>&db=<database name>[&dbtab=<tab>][&fg=<file group>]. The tree's database node links here
// (tree.ts, a wiring line of the join).
import { Ctx } from './router';
import { hashParam, hrefWith } from './dbinfo';
import { performanceView } from './performance';
import { mssqlFilesView } from './mssql_storage';
import { el } from './ui';

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

export async function mssqlDbView(ctx: Ctx): Promise<HTMLElement> {
  const db = hashParam('db');
  if (!db) return el('section', {}, el('h2', {}, 'Database'), el('p', { class: 'empty' }, 'No database named (db=).'));
  const asked = hashParam('dbtab');
  const tab = tabs.some(([k]) => k === asked) ? asked! : 'performance';
  const fg = hashParam('fg');
  const strip = el('nav', { class: 'subtabs', 'aria-label': `${db}'s pages` }, ...tabs.map(([k, label]) =>
    el('a', { href: hrefWith(ctx, mssqlDbTab, { db, dbtab: k }), class: k === tab ? 'on' : '', ...(k === tab ? { 'aria-current': 'page' } : {}) }, label)));
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
    default:
      body = el('p', { class: 'empty' }, `${tabs.find(([k]) => k === tab)![1]} for ${db}: not on this page yet.`);
  }
  sec.append(body);
  return sec;
}
