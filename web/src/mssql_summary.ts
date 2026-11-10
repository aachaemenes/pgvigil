// The Summary of one SQL Server instance: what the server is (the base collection's description), which status
// groups are not OK (each a link to its page), and the findings the wave's collections raise for it.
import { get, Row, rowsOf } from './api';
import { cellClass, cells, cellText, fleet, groups } from './fleet';
import { Ctx, href } from './router';
import { badge, el, fmtTime, grid, props, Col } from './ui';

const sev = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const findingCols: Col[] = [
  { key: 'severity', fmt: sev }, { key: 'setting', label: 'check' }, { key: 'value', label: 'object' },
  { key: 'detail' }, { key: 'at', label: 'seen', fmt: fmtTime },
];

export async function mssqlSummary(ctx: Ctx): Promise<HTMLElement> {
  const [f, fi] = await Promise.all([fleet(), get('findings', { instance: ctx.instance })]);
  const r = f.instances.find(x => Number(x.instance_id) === ctx.instance);
  if (!r) return el('p', { class: 'empty' }, 'This instance is not in the repository (or no longer active).');
  const c = cells(f, r);
  const s: Row = f.mssqlServers.find(x => Number(x.instance_id) === ctx.instance) ?? {};
  const sec = el('section', {}, el('h2', {}, String(r.name), ' ', badge('SQL Server', ''), ...(r.platform && r.platform !== 'sqlserver' ? [' ', badge(String(r.platform), '')] : [])));
  const mine = groups.filter(g => g.key === 'collect' || g.mssql);
  const notOk = mine.filter(g => !c[g.key].none && c[g.key].level > 0);
  const unread = mine.filter(g => c[g.key].none);
  sec.append(el('p', { class: 'meta counts' }, notOk.length === 0 ? 'No warning or critical' : 'Not OK: ',
    ...notOk.flatMap((g, i) => {
      const x = c[g.key];
      const a = el('a', { class: cellClass(x), href: href(ctx, { tab: g.mssql?.[1] ?? 'summary' }) }, `${g.mssql?.[2] ?? g.label} ${cellText(x)}`);
      if (x.detail.length) a.title = x.detail.join('\n');
      return i ? [', ', a] : [a];
    }),
    unread.length ? `; not read yet: ${unread.map(g => g.mssql?.[2] ?? g.label).join(', ')}.` : '.'));
  const mem = (v: unknown) => v == null ? '' : `${(Number(v) / 1024).toLocaleString(undefined, { maximumFractionDigits: 1 })} GB`;
  const yn = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';
  sec.append(el('h3', {}, 'Server'), props([
    ['version', [s.product_version, s.product_level, s.product_update_level].filter(Boolean).map(String).join(' ') || String(r.server_version ?? '')],
    ['edition', String(s.edition ?? '')],
    ['server', [s.server_name, s.machine_name && s.machine_name !== s.server_name ? `(machine ${String(s.machine_name)})` : ''].filter(Boolean).map(String).join(' ')],
    ['started', s.started_at ? `${fmtTime(s.started_at)} (${cellText(c.uptime)})` : ''],
    ['SQL Server Agent', c.agent.none ? '' : c.agent.detail.join(' ')],
    ['Database Mail', c.dbmail.none ? '' : c.dbmail.detail.join(' ')],
    ['memory dumps', c.dumps.none ? '' : c.dumps.detail.join(' ')],
    ['processors', s.cpu_count == null ? '' : String(s.cpu_count)],
    ['memory', s.physical_memory_mb == null ? '' : `${mem(s.physical_memory_mb)} in the machine, ${mem(s.committed_target_mb)} the server's target`],
    ['clustered', yn(s.is_clustered)], ['Always On enabled', yn(s.is_hadr_enabled)],
    ['collation', String(s.server_collation ?? '')],
    ['virtual machine', String(s.virtual_machine_type ?? '').toLowerCase()],
    ['tags', Array.isArray(r.tags) ? r.tags.map(String).join(', ') : ''],
    ['description read', s.snapshot_at ? fmtTime(s.snapshot_at) : 'not yet'],
  ]));
  const rows = rowsOf(fi).filter(x => Number(x.instance_id) === ctx.instance && x.severity !== 'info');
  sec.append(el('h3', {}, `Findings (${rows.length})`), grid(rows, findingCols, 'No warning or critical finding on this instance.'));
  return sec;
}
