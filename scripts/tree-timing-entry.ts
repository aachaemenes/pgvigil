// TAGTREE's draw() timing (the design pass's #8): the side tree drawn from a synthetic fleet of 2,124 instances (one
// written tag each, one in four SQL Server; ui.group_by empty, so one folder per tag, every folder open - the default),
// timed in the page: seven draws after a warm one, the median - the draw alone (building the nodes) and the draw with
// the layout it costs (a read of offsetHeight forces style and layout inside the timed window; the TAGTREE review B #7).
// Two shapes: 60 tags of about 35 instances, 300 tags of
// about 7. Written into <pre id="out"> for chromium --dump-dom (scripts/tree-timing.sh); no server, no API read
// succeeds (the tree's reads fail and change nothing drawn).
import { mountTree, updateTree } from '../web/src/tree';
import { parse } from '../web/src/router';
import type { Fleet } from '../web/src/fleet';

const out: string[] = [];
const host = document.getElementById('tree')!;
mountTree(host);
const fleetOf = (n: number, tags: number): Fleet => ({
  instances: Array.from({ length: n }, (_, i) => ({ instance_id: i + 1, name: `inst${String(i + 1).padStart(5, '0')}`,
    engine: i % 4 === 0 ? 'sqlserver' : 'postgres', tags: [`site:s${(i % tags) + 1}`] })),
  checks: [], versions: [], mssql: [], mssqlServers: [], pgdb: [], collect: [], roots: [], mssqlFailed: false, pgaudit: [], pgauditFailed: false, at: Date.now(),
});
for (const [n, tags] of [[2124, 60], [2124, 300]]) {
  const f = fleetOf(n, tags);
  const ctx = parse();
  updateTree(f, ctx);
  const ms: number[] = [], lay: number[] = [];
  for (let k = 0; k < 7; k++) { const t = performance.now(); updateTree(f, ctx); ms.push(performance.now() - t); }
  for (let k = 0; k < 7; k++) { const t = performance.now(); updateTree(f, ctx); void host.offsetHeight; lay.push(performance.now() - t); }
  ms.sort((a, b) => a - b); lay.sort((a, b) => a - b);
  out.push(`shape ${n} instances / ${tags} tags (about ${Math.round(n / tags)} each): draw median ${ms[3].toFixed(1)} ms (min ${ms[0].toFixed(1)}, max ${ms[6].toFixed(1)}), `
    + `with its layout ${lay[3].toFixed(1)} ms (min ${lay[0].toFixed(1)}, max ${lay[6].toFixed(1)}); `
    + `${host.querySelectorAll('*').length} nodes in the tree, ${host.querySelectorAll('.folder').length} tag folders, `
    + `${host.querySelectorAll('button.caret[data-key^="t:"]').length} of their own folders`);
}
document.getElementById('out')!.textContent = out.join('\n');
