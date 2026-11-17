// The object page (OBJ, the lead's 11-17 13:27 / 13:42: DBA Dash's object window - DBADashGUI/Performance/
// ObjectDetailControl.cs in DetailForm): one procedure, function or trigger of a SQL Server instance, the object in the
// address (#/mssqlobject?i=&db=&obj=[&otab=]; every link to it a real href, so Ctrl+click opens a browser tab - DBA
// Dash's new window), its tabs in DBA Dash's order. The name is read as DBA Dash reads it (one, two or three parts,
// [brackets] and "quotes" whole: the server's splitObjectName); the lookup (/api/mssql/procs part=object_lookup) finds
// it in the window's execution statistics and the schema snapshot - several matches are said with the one shown, none
// is said (DBA Dash's status line). A tab the lookup cannot fill is left out and said why (DBA Dash's BuildTabs). The
// hash window is sqltoolsbuild-s3's page (#/qhash): linked from here, not built here.
import { get, Row, rowsOf, Table } from './api';
import { hashParam, hrefWith } from './dbinfo';
import { Ctx, window_ } from './router';
import { badge, el, errorBox } from './ui';

export const mssqlObjectTab = 'mssqlobject';

// mssqlObjectHref: an object of a SQL Server instance's database, opened on its page (the tab given, else the first)
export const mssqlObjectHref = (ctx: Ctx, db: string, obj: string, tab?: string, instance = ctx.instance) =>
  hrefWith(ctx, mssqlObjectTab, { db, obj, otab: tab }, instance);

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
  sec.append(el('p', { class: 'empty' }, `${tabs.find(([k]) => k === tab)![1]}: not built yet (OBJ's next rows).`));
  return sec;
}
