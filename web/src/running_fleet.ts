// The fleet's Running queries page (DBA Dash's Running Queries at the root): one row per instance from its NEWEST
// snapshot, both engines, every column sortable; a row opens that instance's Running queries at that snapshot. A
// status line of totals stands above the grid and a 'Blocked only' toggle keeps the instances with a blocked
// session. A snapshot older than three minutes is marked stale in muted text: its numbers are the last ones read,
// not the state now. Data: /api/running/fleet; the scope is the tag folder of the tree and the tag filter.
import { get, Row, rowsOf, Table } from './api';
import { fleet, tagsOf } from './fleet';
import { Ctx, href } from './router';
import { applyTagFilter, tagFilterBar, tagUI } from './tree';
import { badge, Col, el, fmtNum, fmtSecs, fmtTime, grid } from './ui';
import { sqlCell, whatIsThis } from './sqlview';

const STALE_SECS = 180;
const STORE = 'pgvigil.running.fleet.blocked';
const note = 'One row per instance from its newest snapshot. Blocked: a session waiting on a lock another session holds. '
  + 'Chain heads: the sessions that block others and are not blocked themselves. Longest blocked wait: on SQL Server the wait the server measured; '
  + 'on PostgreSQL the age of the oldest blocked statement, the most its wait can be (pg_stat_activity has no start of a wait). '
  + 'A snapshot older than 3 minutes is stale: its numbers are the last ones read.';

const engineName = (v: unknown) => v === 'sqlserver' ? 'SQL Server' : 'PostgreSQL';
const isStale = (r: Row) => r.snapshot_at != null && Number(r.age_secs) > STALE_SECS;

// runningHref: the instance's Running queries at one snapshot (the SQL Server tab reads at= from the address itself)
function runningHref(ctx: Ctx, r: Row): string {
  const id = Number(r.instance_id);
  if (r.engine !== 'sqlserver') return href(ctx, { tab: 'activity', instance: id, tag: undefined, at: r.snapshot_at == null ? undefined : String(r.snapshot_at) });
  const base = href(ctx, { tab: 'mssql_running', instance: id, tag: undefined });
  return r.snapshot_at == null ? base : `${base}&at=${encodeURIComponent(String(r.snapshot_at))}`;
}

export async function runningFleet(ctx: Ctx): Promise<HTMLElement> {
  const [d, f] = await Promise.all([get<{ rows: Table | null }>('running/fleet'), fleet(), tagUI()]);
  // the scope: the tag folder picked in the tree, then the tag filter of the bar (as on the Summary)
  const inFolder = ctx.tag ? f.instances.filter(r => ctx.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(ctx.tag!)) : f.instances;
  const filterBar = tagFilterBar(inFolder);   // built first: it drops a remembered filter this scope no longer carries
  const ids = new Set(applyTagFilter(inFolder).map(r => Number(r.instance_id)));
  const rows = rowsOf(d.rows).filter(r => ids.has(Number(r.instance_id)));

  const withBlocked = rows.filter(r => Number(r.blocked) > 0);
  const blocked = withBlocked.reduce((a, r) => a + Number(r.blocked), 0);
  const longest = withBlocked.reduce<number | null>((m, r) => r.longest_wait_secs == null ? m : Math.max(m ?? 0, Number(r.longest_wait_secs)), null);
  const stale = rows.filter(isStale).length, never = rows.filter(r => r.snapshot_at == null).length;
  const status = el('p', { class: 'meta counts running-status' },
    el('span', { class: blocked ? 'crit' : '' }, `Blocked sessions: ${fmtNum(blocked)} on ${withBlocked.length} instance(s)` + (blocked ? `, longest wait ${fmtSecs(longest) || '0s'}` : '')),
    `; ${rows.length} instance(s)` + (stale ? `, ${stale} stale` : '') + (never ? `, ${never} without a snapshot` : ''), ' ', whatIsThis(note, 'Running queries'));

  const waitKind = (v: unknown) => Number(v) > 300 ? 'crit' : Number(v) > 30 ? 'warn' : '';
  const open = (text: string, r: Row) => el('a', { href: runningHref(ctx, r), class: 'row-open', title: 'Running queries of this instance at this snapshot' }, text);
  const cols: Col[] = [
    { key: 'instance', fmt: (v, r) => open(String(v), r) },
    { key: 'engine', fmt: engineName },
    { key: 'snapshot_at', label: 'snapshot', fmt: v => v == null ? el('span', { class: 'meta' }, 'no snapshot') : fmtTime(v) },
    { key: 'age_secs', label: 'age', num: true, fmt: (v, r) => v == null ? '' : isStale(r) ? el('span', { class: 'meta stale' }, `${fmtSecs(v)} stale`) : fmtSecs(v) || '0s' },
    { key: 'sessions', num: true },
    { key: 'active', num: true },
    { key: 'idle_in_txn', label: 'idle in transaction', num: true },
    { key: 'blocked', num: true, fmt: v => v == null ? '' : Number(v) > 0 ? badge(fmtNum(v), 'crit') : '0' },
    { key: 'heads', label: 'chain heads', num: true },
    { key: 'longest_wait_secs', label: 'longest blocked wait', num: true, fmt: v => v == null ? '' : waitKind(v) ? badge(fmtSecs(v), waitKind(v)) : fmtSecs(v) || '0s' },
    { key: 'longest_stmt_secs', label: 'longest statement', num: true, fmt: fmtSecs },
    { key: 'longest_stmt', label: 'statement', fmt: (v, r) => sqlCell(v, { heading: `${String(r.instance)}: the longest running statement (session ${String(r.longest_stmt_session ?? '')})` }) },
    { key: 'oldest_txn_secs', label: 'oldest transaction', num: true, fmt: fmtSecs },
  ];

  let only = (() => { try { return sessionStorage.getItem(STORE) === '1'; } catch { return false; } })();
  const toggle = el('button', { type: 'button', class: 'toggle', 'aria-pressed': String(only) }, 'Blocked only');
  const holder = el('div', { class: 'running-fleet' });
  const draw = () => {
    holder.replaceChildren(grid(only ? withBlocked : rows, cols,
      rows.length === 0 ? 'No instances in this scope.' : 'No instance has a blocked session in its newest snapshot.'));
  };
  toggle.addEventListener('click', () => {
    only = !only; toggle.setAttribute('aria-pressed', String(only));
    try { sessionStorage.setItem(STORE, only ? '1' : ''); } catch { /* private window */ }
    draw();
  });
  // a click anywhere on a row opens what its instance link opens (the link itself is the keyboard's way in)
  holder.addEventListener('click', ev => {
    const t = ev.target as HTMLElement;
    if (t.closest('a, button, th')) return;
    const a = t.closest('tr')?.querySelector<HTMLAnchorElement>('a.row-open');
    if (a) location.hash = a.getAttribute('href')!;
  });
  draw();
  return el('section', {}, el('h2', {}, 'Running queries' + (ctx.tag ? ` - tag ${ctx.tag}` : '')), filterBar,
    el('div', { class: 'seg' }, toggle), status, holder);
}
