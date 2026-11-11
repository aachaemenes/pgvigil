// The Statements page's filter panel and GROUP BY switch (parity3 task 125; PMM Query Analytics shots 20-21): each
// database, user and client host of the window with its share of the total time as a checkbox, and the statements
// grouped by statement, database, user or client host, each group with its share of the ticked total and of the
// instance's whole total (/api/stmtgroups).
//
// The ticks and the grouping ride the page's hash (sg=<group>, sdb / suser / scl repeated), so a link keeps them;
// the router keeps them on the Statements tab's own links through the lead's wiring.
import { Row, rowsOf, Table } from './api';
import { LoginRequired } from './api';
import { Ctx, window_ } from './router';
import { Col, el, errorBox, fmtNum, grid } from './ui';

export const groupKinds: [string, string][] = [['query', 'statement'], ['db', 'database'], ['user', 'user'], ['client', 'client host']];
const dims: [string, string, string][] = [['db', 'sdb', 'Database'], ['user', 'suser', 'User'], ['client', 'scl', 'Client host']];
export const notSampled = '(not sampled)';

export interface StmtGroups { facets: Table | null; groups: Table | null; totals: Table | null }

function hashQS(): URLSearchParams { return new URLSearchParams(location.hash.split('?')[1] ?? ''); }

// stmtTicks: the ticked values per dimension (an absent dimension = every value) and the grouping.
export function stmtTicks(): { group: string; ticks: Record<string, string[]> } {
  const q = hashQS();
  const g = q.get('sg') ?? 'query';
  const ticks: Record<string, string[]> = {};
  for (const [dim, param] of dims) { const v = q.getAll(param).filter(x => x !== ''); if (v.length) ticks[dim] = v.slice(0, 100); }
  return { group: groupKinds.some(k => k[0] === g) ? g : 'query', ticks };
}

// setHash: the page's hash with the ticks or the grouping changed (every other parameter kept).
function setHash(change: (q: URLSearchParams) => void): void {
  const [path, qs] = location.hash.split('?');
  const q = new URLSearchParams(qs ?? '');
  change(q);
  location.hash = path + '?' + q.toString();
}

// readStmtGroups: /api/stmtgroups for the page's window, ticks and grouping (repeated parameters: built here).
export async function readStmtGroups(ctx: Ctx, signal?: AbortSignal): Promise<StmtGroups> {
  const { group, ticks } = stmtTicks();
  const w = window_(ctx);
  const q = new URLSearchParams({ instance: String(ctx.instance), group });
  if (w.from) q.set('from', w.from);
  if (w.to) q.set('to', w.to);
  for (const [dim, vs] of Object.entries(ticks)) for (const v of vs) q.append(dim, v);
  const res = await fetch('/api/stmtgroups?' + q.toString(), { headers: { Accept: 'application/json' }, credentials: 'same-origin', signal });
  if (res.status === 401) throw new LoginRequired();
  const b = await res.json().catch(() => ({ error: res.statusText }));
  if (!res.ok) throw new Error((b as { error?: string }).error ?? res.statusText);
  return b as StmtGroups;
}

const ms = (v: unknown) => {
  if (v == null || v === '') return '';
  const n = Number(v);
  return n >= 60000 ? fmtNum(n / 60000) + ' min' : n >= 1000 ? fmtNum(n / 1000) + ' s' : fmtNum(n) + ' ms';
};
const pctTxt = (v: unknown) => v == null || v === '' ? '' : fmtNum(v) + ' %';

// shareCell: the share as a number and a thin bar (PMM's Load bar; pghero's grey percent beside the total).
export function shareCell(v: unknown, title = 'share of the total time'): HTMLElement {
  const n = Math.max(0, Math.min(100, Number(v) || 0));
  return el('span', { class: 'share', title, style: 'display:inline-flex;align-items:center;gap:.4rem;justify-content:flex-end;min-width:7.5em' },
    el('span', { 'aria-hidden': 'true', style: `display:inline-block;width:3em;height:.45rem;background:var(--line);border-radius:2px;overflow:hidden` },
      el('span', { style: `display:block;height:100%;width:${n}%;background:var(--accent)` })),
    el('span', {}, pctTxt(v)));
}

// totalWithShare: a total time with its share of the window's whole total in grey beside it (pghero's "1 min 85%").
export function totalWithShare(totalMs: unknown, whole: number): HTMLElement | string {
  if (totalMs == null || totalMs === '') return '';
  const t = Number(totalMs);
  const share = whole > 0 ? 100 * t / whole : null;
  return el('span', {}, ms(t), share == null ? '' : el('span', { class: 'meta', style: 'margin-left:.5em', title: 'share of all statements\' time in the window' }, fmtNum(Math.round(share * 10) / 10) + ' %'));
}

// facetPanel: the checkbox groups, each value with its share; a tick narrows the page at once.
function facetPanel(facets: Row[]): HTMLElement {
  const { ticks } = stmtTicks();
  const box = el('div', { class: 'facets', role: 'group', 'aria-label': 'Filter the statements', style: 'flex:0 0 17rem;max-width:100%;border:1px solid var(--line);background:var(--card);padding:.6rem;border-radius:6px' });
  const reset = el('button', { type: 'button', class: 'link' }, 'Reset all');
  reset.addEventListener('click', () => setHash(q => { for (const [, p] of dims) q.delete(p); }));
  box.append(el('div', { style: 'display:flex;justify-content:space-between;align-items:baseline' }, el('strong', {}, 'Filters'), reset));
  for (const [dim, param, label] of dims) {
    const vals = facets.filter(f => f.dim === dim);
    const fs = el('fieldset', { style: 'border:0;padding:0;margin:.6rem 0 0' },
      el('legend', { style: 'display:flex;justify-content:space-between;width:100%;font-weight:600;border-bottom:1px solid var(--line)' }, label, el('span', { class: 'meta' }, String(vals.length))));
    if (vals.length === 0) fs.append(el('p', { class: 'meta' }, 'none in this window'));
    for (const f of vals.slice(0, 50)) {
      const v = String(f.value ?? '');
      const id = `sf-${dim}-${encodeURIComponent(v)}`;
      const cb = el('input', { type: 'checkbox', id }) as HTMLInputElement;
      cb.checked = (ticks[dim] ?? []).includes(v);
      cb.addEventListener('change', () => setHash(q => {
        const cur = q.getAll(param).filter(x => x !== v);
        q.delete(param);
        for (const x of cb.checked ? [...cur, v] : cur) q.append(param, x);
      }));
      const shown = v === '' ? '(none)' : v;
      fs.append(el('div', { style: 'display:flex;align-items:center;gap:.35rem;margin:.15rem 0' }, cb,
        el('label', { for: id, title: `${shown}: ${fmtNum(f.statements)} statements, ${ms(f.total_ms)}`, style: 'flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap' }, shown),
        el('span', { class: 'meta', style: 'font-variant-numeric:tabular-nums' }, pctTxt(f.share_pct))));
    }
    if (vals.length > 50) fs.append(el('p', { class: 'meta' }, `and ${vals.length - 50} more (the 50 with the most time are listed)`));
    box.append(fs);
  }
  return box;
}

// stmtGroupsSection: the panel beside the grouped grid; extra adds the statement row's own cells (plan, history).
export function stmtGroupsSection(d: StmtGroups | Error, extra: Col[] = [], title = 'Statements by database, user and client host'): HTMLElement {
  if (d instanceof Error) return el('section', {}, el('h2', {}, title), errorBox(d));
  const { group, ticks } = stmtTicks();
  const tot = rowsOf(d.totals)[0] ?? {};
  const whole = Number(tot.total_ms ?? 0), filtered = Number(tot.filtered_ms ?? 0);
  const switcher = el('div', { class: 'subtabs', role: 'group', 'aria-label': 'Group by' }, el('span', { class: 'meta', style: 'align-self:center' }, 'Group by'),
    ...groupKinds.map(([k, l]) => {
      const a = el('a', { href: '#', class: k === group ? 'on' : '', 'aria-pressed': String(k === group) }, l);
      a.addEventListener('click', ev => { ev.preventDefault(); setHash(q => { if (k === 'query') q.delete('sg'); else q.set('sg', k); }); });
      return a;
    }));
  const first: Col = group === 'query'
    ? { key: 'query', label: 'statement', wide: true, fmt: v => { const s = String(v ?? '').replace(/\s+/g, ' '); return s.length > 160 ? s.slice(0, 160) + '...' : s; } }
    : { key: 'grp', label: groupKinds.find(k => k[0] === group)![1], fmt: v => String(v ?? '') === '' ? '(none)' : String(v) };
  const cols: Col[] = [first,
    { key: 'total_ms', label: 'total time', num: true, fmt: ms },
    { key: 'share_pct', label: 'share', num: true, fmt: v => shareCell(v, 'share of the ticked statements\' total time') },
    { key: 'share_all_pct', label: 'of all', num: true, fmt: pctTxt },
    { key: 'calls', num: true }, { key: 'mean_ms', label: 'mean', num: true, fmt: ms },
    { key: 'rows', num: true }, { key: 'io_blks', label: 'IO blocks', num: true }, { key: 'hit_pct', label: 'hit', num: true, fmt: pctTxt },
    ...(group === 'query' ? [{ key: 'datname', label: 'db' }, { key: 'usename', label: 'user' }, { key: 'queryid' }, ...extra] as Col[] : [{ key: 'statements', num: true }] as Col[])];
  const ticked = Object.entries(ticks).map(([k, vs]) => `${dims.find(x => x[0] === k)![2].toLowerCase()} ${vs.join(', ')}`).join('; ');
  const head = el('p', { class: 'meta' }, ticked
    ? `Ticked: ${ticked}. ${ms(filtered)} of ${ms(whole)} (${whole > 0 ? fmtNum(Math.round(1000 * filtered / whole) / 10) : 0} %) of all statements' time in the window.`
    : `All statements: ${ms(whole)} in the window, ${fmtNum(tot.statements ?? 0)} statements.`);
  const right = el('div', { style: 'flex:1 1 32rem;min-width:0' }, switcher, head,
    grid(rowsOf(d.groups), cols, 'No statement deltas match in this window (pg_stat_statements missing, fewer than two snapshots, or nothing ticked ran).'));
  const sampled = tot.sampled_pct == null ? null : Number(tot.sampled_pct);
  right.append(el('p', { class: 'meta' }, 'Client host: pg_stat_statements keeps none, so a statement\'s time is split over the hosts the running-queries samples saw it from '
    + '(PostgreSQL 14+, compute_query_id), in proportion to the samples: an estimate. A statement never sampled is "' + notSampled + '"'
    + (sampled == null ? '.' : `; ${fmtNum(sampled)} % of this window's time was sampled.`)));
  return el('section', {}, el('h2', {}, title),
    el('div', { style: 'display:flex;flex-wrap:wrap;gap:1rem;align-items:flex-start' }, facetPanel(rowsOf(d.facets)), right));
}
