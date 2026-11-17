// The Azure logical server and elastic pool nodes (P25 task 7 and (i): DBA Dash's server and pool nodes, each with its
// own tabs in DBA Dash's order, GUI/Main.cs L1887 / L1894): #/azureserver?server=<name>[&ntab=<tab>] and
// #/azurepool?server=<name>&pool=<name>[&ntab=<tab>], pages of the root (a tag folder's under ?tag=). A node's scope is
// its databases - /api/azuredb/summary part=databases cut by server= / pool= (and the tag folder): their instance ids -
// and each tab is the fleet page cut to those ids: the Azure Summary cut to the node (task 7), the others through one
// optional parameter of their page (the other slices' pages by scripts/NODETABS-wiring.patch). The pool's Pool tab is
// the Elastic pool page of one of its databases (a pool is read through its members: pools.ts), a member that holds the
// pool's own read first.
import { get, Row, rowsOf, Table } from './api';
import { alertsView } from './alerts';
import { AzureNode, azureSummaryView } from './azuredb';
import { hashParam, hrefWith } from './dbinfo';
import { dbSpaceView } from './drives';
import { objectExecutionSection } from './mssql_objexec';
import { perfSummaryView } from './perfsummary';
import { mssqlPoolView } from './pools';
import { Ctx, window_ } from './router';
import { runningFleet } from './running_fleet';
import { folderWords } from './fleet';
import { slowFleetView } from './slow';
import { el, errorBox } from './ui';

// DBA Dash's tabs, in its order (map rows 31-36 for a logical server, 53-59 for an elastic pool)
const serverTabs: [string, string][] = [['perfsummary', 'Performance Summary'], ['azuresummary', 'Azure Summary'], ['alerts', 'Alerts'], ['slowqueries', 'Slow Queries'], ['objexec', 'Object Execution'], ['running', 'Running Queries']];
const poolTabs: [string, string][] = [['pool', 'Pool'], ['perfsummary', 'Performance Summary'], ['azuresummary', 'Azure Summary'], ['slowqueries', 'Slow Queries'], ['objexec', 'Object Execution'], ['running', 'Running Queries'], ['dbspace', 'DB Space']];

// a node is azuredb.ts' AzureNode (review t11-7 item 9: no local Node shadowing the DOM's)
const nodeHref = (ctx: Ctx, node: AzureNode, ntab: string) =>
  hrefWith(ctx, node.pool ? 'azurepool' : 'azureserver', { server: node.server, pool: node.pool, ntab });

// nodeView: the node's heading, its tab strip and the tab asked for (ntab=; the first in DBA Dash's order when none)
async function nodeView(ctx: Ctx, node: AzureNode): Promise<HTMLElement> {
  const tabs = node.pool ? poolTabs : serverTabs;
  const asked = hashParam('ntab');
  const tab = tabs.some(([k]) => k === asked) ? asked! : tabs[0][0];
  const name = node.pool ? `Elastic pool ${node.pool} on ${node.server}` : `Logical server ${node.server}`;
  const strip = el('nav', { class: 'subtabs', 'aria-label': `${name}'s pages` }, ...tabs.map(([k, label]) =>
    el('a', { href: nodeHref(ctx, node, k), class: k === tab ? 'on' : '', ...(k === tab ? { 'aria-current': 'page' } : {}) }, label)));
  if (tab === 'azuresummary') {
    // review t11-7 item 3: a failed read is an error box under the strip, never the whole page
    try {
      const sec = await azureSummaryView(ctx, node);
      sec.insertBefore(strip, sec.children[1] ?? null);
      return sec;
    } catch (e) { return el('section', {}, el('h2', {}, name), strip, errorBox(e)); }
  }
  const sec = el('section', {}, el('h2', {}, name), strip);
  // the node's databases (the tag folder's scope included): their ids cut every other tab
  let rows: Row[];
  try {
    const d = await get<{ databases: Table | null }>('azuredb/summary', { ...window_(ctx), part: 'databases', server: node.server,
      ...(node.pool ? { pool: node.pool } : {}), ...(ctx.tag ? { tag: ctx.tag } : {}) });
    rows = rowsOf(d.databases);
  } catch (e) { sec.append(errorBox(e)); return sec; }
  if (!rows.length) {
    sec.append(el('p', { class: 'empty' }, `pgvigil reads no Azure SQL Database ${node.pool ? `in the elastic pool ${node.pool} of the logical server ${node.server}` : `on the logical server ${node.server}`}${ctx.tag ? ` in ${folderWords(ctx.tag)}` : ''}: this tab has nothing to show.`));
    return sec;
  }
  const ids = rows.map(r => Number(r.instance_id));
  const idset = new Set(ids);
  const keep = (r: Row) => idset.has(Number(r.instance_id));
  // the ids already hold the tag folder's cut: the fleet pages read without the tag, so they cut by the node alone
  const nctx: Ctx = { ...ctx, tag: undefined };
  try {
    switch (tab) {
      case 'pool': {
        // a member with the pool's own read first (review t11-3 SHOULD 2)
        const m = rows.find(r => r.pool_read) ?? rows[0];
        sec.append(await mssqlPoolView({ ...ctx, instance: Number(m.instance_id) }).catch(e => errorBox(e)));
        break;
      }
      case 'perfsummary': sec.append(await perfSummaryView(nctx, ids)); break;
      // review t11-7 item 5: what the node's Alerts holds
      case 'alerts': sec.append(el('p', { class: 'meta' }, `In view: the alerts of this node's ${ids.length} database(s) and the repository's own (the collector's, the repository's); the channels, mutes and silences are the whole repository's.`),
        await alertsView(nctx, keep)); break;
      // review t11-7 item 4: the fleet page reads the fleet's top 500 statement groups before the node's cut
      case 'slowqueries': sec.append(el('p', { class: 'meta' }, 'Slow Queries here is the fleet\'s top 500 statement groups of the range, cut to this node\'s databases: a group of the node outside the fleet\'s top 500 is not listed.'),
        await slowFleetView(nctx, keep)); break;
      // review t11-7 item 2: one Object Execution list reads at most 500 databases (nodeObjectsMax)
      case 'objexec': sec.append(ids.length > 500 ? el('p', { class: 'meta' }, `This node holds ${ids.length} databases: Object Execution reads the first 500 of them (the list's cap).`) : '',
        el('section', {}, objectExecutionSection(nctx, undefined, ids.slice(0, 500)))); break;
      case 'running': sec.append(await runningFleet(nctx, keep)); break;
      case 'dbspace': sec.append(await dbSpaceView(nctx, ids)); break;
    }
  } catch (e) { sec.append(errorBox(e)); }
  return sec;
}

export async function azureServerView(ctx: Ctx): Promise<HTMLElement> {
  const server = hashParam('server');
  if (!server) return el('section', {}, el('h2', {}, 'Logical server'),
    el('p', { class: 'empty' }, 'No logical server named in the address: open one from the Azure Summary\'s logical server column or the tree\'s Azure folder.'));
  return nodeView(ctx, { server });
}

export async function azurePoolView(ctx: Ctx): Promise<HTMLElement> {
  const server = hashParam('server'), pool = hashParam('pool');
  if (!server || !pool) return el('section', {}, el('h2', {}, 'Elastic pool'),
    el('p', { class: 'empty' }, 'No elastic pool named in the address (a pool is named with its logical server): open one from the Azure Summary\'s Elastic pools grid or the tree\'s Azure folder.'));
  return nodeView(ctx, { server, pool });
}
