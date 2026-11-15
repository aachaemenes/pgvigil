// The Summary of one SQL Server instance: what the server is (the base collection's description), which status
// groups are not OK (each a link to its page), and the findings the wave's collections raise for it.
import { get, Row, rowsOf, Table } from './api';
import { AckData, loadAckSafe } from './ack';
import { alertHref } from './alert_page';
import { cellClass, cells, cellTarget, cellText, fleet, groups, withTarget } from './fleet';
import { Ctx, href } from './router';
import { badge, el, fmtTime, grid, props, Col } from './ui';
import { healthCalendar } from './healthcal';
import { jumpWhenDrawn, markRows, ownPageAction } from './rowjump';

const sev = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
// the check opens the finding's own page (alert_page.ts: the finding as it stands, its fix, its firings), as a row of
// the Alerts page does; one link a row, the cells beside it text (DBA Dash's grids)
const findingCols = (ctx: Ctx): Col[] => [
  // the severity is a status text: a link where the check's link goes
  { key: 'severity', fmt: (v, r) => r.finding_key == null ? sev(v) : el('a', { href: alertHref(r.finding_key, undefined, ctx), class: 'cell-link', 'aria-label': `${String(v ?? '')}: ${String(r.setting ?? '')}` }, sev(v)) },
  { key: 'setting', label: 'check', fmt: (v, r) => r.finding_key == null ? String(v ?? '') : el('a', { href: alertHref(r.finding_key, undefined, ctx) }, String(v ?? '')) },
  { key: 'value', label: 'object' },
  { key: 'detail' }, { key: 'at', label: 'seen', fmt: fmtTime },
  // PerformanceMonitor's Occurrences and First seen (task 177 D29): from the alert history (GET /api/ack part=seen):
  // how many times the finding was raised anew and when first; '-' for a finding never sent
  { key: '_occ', label: 'occurrences', num: true, fmt: v => v == null ? '-' : String(v) },
  { key: '_first', label: 'first seen', fmt: v => v == null ? '-' : fmtTime(v) },
];

export async function mssqlSummary(ctx: Ctx): Promise<HTMLElement> {
  const [f, fi, sn] = await Promise.all([fleet(), get('findings', { instance: ctx.instance }),
    loadAckSafe(['seen'], { instance: ctx.instance }) as Promise<AckData & { seen?: Table | null }>]);
  const seen = new Map(rowsOf(sn.seen ?? null).map(x => [`${String(x.setting ?? '')}\x1f${String(x.value ?? '')}`, x]));
  const r = f.instances.find(x => Number(x.instance_id) === ctx.instance);
  if (!r) return el('p', { class: 'empty' }, 'This instance is not in the repository (or no longer active).');
  const c = cells(f, r);
  const s: Row = f.mssqlServers.find(x => Number(x.instance_id) === ctx.instance) ?? {};
  const sec = el('section', {}, el('h2', {}, String(r.name), ' ', badge('SQL Server', ''), ...(r.platform && r.platform !== 'sqlserver' ? [' ', badge(String(r.platform), '')] : [])));
  const mine = groups.filter(g => g.key === 'collect' || g.mssql);
  const notOk = mine.filter(g => !c[g.key].none && c[g.key].level > 0);
  const unread = mine.filter(g => c[g.key].none && c[g.key].text !== 'n/a');
  const notHere = mine.filter(g => c[g.key].none && c[g.key].text === 'n/a');
  // every group named is a link to its page - the header's own target (cellTarget: the tab, the view it opens on and
  // its status filter, so 'Suspect pages' opens the checks page's Build view here as its reason does in the header);
  // one whose page is this Summary answers here (rowjump.ts: Memory dumps and DB Mail jump to their Server card row,
  // Instance Uptime opens its dialog)
  const named = (g: typeof mine[number], words: string, cls = '') => {
    const t = cellTarget(g, r);
    const a = el('a', { class: cls, href: withTarget(href(ctx, { tab: t.tab }), t), 'data-group': g.key }, words) as HTMLAnchorElement;
    return t.tab !== ctx.tab || ownPageAction(a, g.key, Number(r.instance_id), true) ? a : el('span', { class: cls, 'data-group': g.key, 'data-nolink': 'this page' }, words);
  };
  const sep = (xs: HTMLElement[]) => xs.flatMap((a, i) => i ? [', ', a] : [a]);
  sec.append(el('p', { class: 'meta counts' }, notOk.length === 0 ? 'No warning or critical' : 'Not OK: ',
    ...sep(notOk.map(g => {
      const x = c[g.key];
      const a = named(g, `${g.mssql?.[2] ?? g.label} ${cellText(x)}`, cellClass(x));
      if (x.detail.length) a.title = x.detail.join('\n');
      return a;
    })),
    ...(unread.length ? ['; not read yet: ', ...sep(unread.map(g => named(g, g.mssql?.[2] ?? g.label)))] : []),
    ...(notHere.length ? ['; skipped on this instance (each page says why): ', ...sep(notHere.map(g => named(g, g.mssql?.[2] ?? g.label))), '.'] : ['.'])));
  const mem = (v: unknown) => v == null ? '' : `${(Number(v) / 1024).toLocaleString(undefined, { maximumFractionDigits: 1 })} GB`;
  const yn = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';
  const server = props([
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
  ]);
  // the rows a status text of this page jumps to (Memory dumps, DB Mail), and the one the address names (row=)
  markRows(server);
  sec.append(el('h3', {}, 'Server'), server);
  jumpWhenDrawn(sec);
  const rows = rowsOf(fi).filter(x => Number(x.instance_id) === ctx.instance && x.severity !== 'info').map(x => {
    const k = seen.get(`${String(x.setting ?? '')}\x1f${String(x.value ?? '')}`);
    return { ...x, _occ: k?.occurrences ?? null, _first: k?.first_seen ?? null };
  });
  sec.append(el('h3', {}, `Findings (${rows.length})`), grid(rows, findingCols(ctx), 'No warning or critical finding on this instance.'));
  // PerformanceMonitor's Daily Health Calendar (task 177 D29, healthcal.ts): read after the page is drawn
  sec.append(healthCalendar(ctx, 'sqlserver'));
  return sec;
}
