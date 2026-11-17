// The Azure logical server and elastic pool nodes (P25 task 7: DBA Dash's server and pool nodes, each with its own
// tabs): #/azureserver?server=<name> and #/azurepool?server=<name>&pool=<name>, pages of the root (a tag folder's
// under ?tag=). Each is the Azure Summary cut to its node (/api/azuredb/summary server= / pool=: its databases, its
// elastic pools, its Service Objectives changes and its Resource Governance); the pool's page adds the Elastic pool
// page of one of its databases (a pool is read through its members: pools.ts).
import { azureSummaryView } from './azuredb';
import { hashParam } from './dbinfo';
import { mssqlPoolView } from './pools';
import { Ctx } from './router';
import { el } from './ui';

export async function azureServerView(ctx: Ctx): Promise<HTMLElement> {
  const server = hashParam('server');
  if (!server) return el('section', {}, el('h2', {}, 'Logical server'),
    el('p', { class: 'empty' }, 'No logical server named in the address: open one from the Azure Summary\'s logical server column or the tree\'s Azure folder.'));
  return azureSummaryView(ctx, { server });
}

export async function azurePoolView(ctx: Ctx): Promise<HTMLElement> {
  const server = hashParam('server'), pool = hashParam('pool');
  if (!server || !pool) return el('section', {}, el('h2', {}, 'Elastic pool'),
    el('p', { class: 'empty' }, 'No elastic pool named in the address (a pool is named with its logical server): open one from the Azure Summary\'s Elastic pools grid or the tree\'s Azure folder.'));
  const sec = await azureSummaryView(ctx, { server, pool });
  // the pool's own minutes and storage (DBA Dash's Pool tab), read through one of its databases
  const member = Number(sec.dataset.member);
  if (member) sec.append(await mssqlPoolView({ ...ctx, instance: member }));
  return sec;
}
