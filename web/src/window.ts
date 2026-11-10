import { get, rowsOf, Table } from './api';
import { slowCols } from './borrowed';
import { planLink } from './plan';
import { Ctx, href, rangeLabel, window_ } from './router';
import { Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid } from './ui';

// The window half of the Running queries tab: what ran, or sat idle in a transaction, for at least N seconds anywhere
// in the chosen range (the state, user, database and application filters ride in the hash), and the per-sample summary
// of the range, a sample's time opening that snapshot. Sampled once a minute, so a duration is a floor.
export async function longRunsSection(ctx: Ctx): Promise<HTMLElement> {
  const minSecs = ctx.minSecs ?? 60;
  const w = { instance: ctx.instance, ...window_(ctx) };
  const [runs, samples] = await Promise.all([
    get('slow', { ...w, min: minSecs, state: ctx.st, user: ctx.user, db: ctx.db, app: ctx.app }).catch((e: unknown) => e),
    get('counters', { ...w, kind: 'sessions' }).catch((e: unknown) => e)]);
  const box = el('div', { class: 'window' });
  box.append(el('h3', {}, `Over this window (${rangeLabel(ctx)})`), filters(ctx, minSecs),
    el('p', { class: 'meta' }, 'From the running-queries samples: an active statement by how long it had run, an idle-in-transaction session by how long it had sat idle '
      + '(its transaction age beside it; a statement that ran and then sat idle is two rows); a duration is a floor (the statement ended between its last sample and the next), and a run shorter than the sampling interval can go unseen.'));
  box.append(runs instanceof Error ? errorBox(runs) : grid(rowsOf(runs as Table), runCols(ctx), 'Nothing ran or sat idle in a transaction that long in this window.'));
  box.append(el('h3', {}, 'Per sample'));
  if (samples instanceof Error) box.append(errorBox(samples));
  else {
    const all = rowsOf(samples as Table).reverse();
    const shown = all.slice(0, 500);
    if (all.length > shown.length) box.append(el('p', { class: 'meta' }, `The newest ${fmtNum(shown.length)} of ${fmtNum(all.length)} samples; the Counters tab charts them all.`));
    box.append(grid(shown, sampleCols(ctx), 'No activity sample in this window.'));
  }
  return box;
}

function filters(ctx: Ctx, minSecs: number): HTMLElement {
  const state = el('select', { 'aria-label': 'state' },
    ...[['', 'any sampled state'], ['active', 'active'], ['idle', 'idle in transaction']].map(([v, l]) =>
      el('option', v === (ctx.st ?? '') ? { value: v, selected: 'selected' } : { value: v }, l)));
  const min = el('input', { type: 'number', min: '0', max: '86400', step: '1', value: String(minSecs), style: 'width:5em', 'aria-label': 'seconds at least' });
  const text = (name: string, v?: string) => el('input', { type: 'text', maxlength: '64', value: v ?? '', placeholder: name + ' (exact)', title: `the session's ${name}, an exact and case-sensitive match`, style: 'width:10em', 'aria-label': name });
  const user = text('user', ctx.user), db = text('database', ctx.db), app = text('application', ctx.app);
  const apply = el('button', { type: 'button' }, 'Apply');
  const go = () => {
    const v = Number(min.value);
    location.hash = href(ctx, { tab: 'activity', minSecs: Number.isFinite(v) ? Math.min(86400, Math.max(0, Math.trunc(v))) : minSecs,
      st: state.value || undefined, user: user.value.trim() || undefined, db: db.value.trim() || undefined, app: app.value.trim() || undefined });
  };
  apply.addEventListener('click', go);
  for (const i of [min, user, db, app]) i.addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
  return el('div', { class: 'picker' }, state, ' for at least ', min, ' s ', user, ' ', db, ' ', app, ' ', apply);
}

function runCols(ctx: Ctx): Col[] {
  const rest = slowCols.filter(c => c.key !== 'at_least_secs' && c.key !== 'query');
  return [
    { key: 'at_least_secs', label: 'ran or idle for', num: true, fmt: fmtSecs },
    { key: 'txn_secs', label: 'txn age', num: true, fmt: fmtSecs },
    ...rest,
    { key: 'client' },
    { key: 'query', wide: true, fmt: v => String(v ?? '').slice(0, 300) },
    { key: 'plan_link', label: 'plan', fmt: (_, r) => r.query ? planLink(ctx.instance!, { stmt: r.query, db: r.datname }) : '' },
    { key: 'last_seen', label: 'snapshot', fmt: v => el('a', { href: href(ctx, { tab: 'activity', at: String(v) }) }, 'open') },
  ];
}

function sampleCols(ctx: Ctx): Col[] {
  return [
    { key: 'snapshot_at', label: 'sample', fmt: v => el('a', { href: href(ctx, { tab: 'activity', at: String(v) }) }, fmtTime(v)) },
    { key: 'total', label: 'sessions', num: true },
    { key: 'active', num: true },
    { key: 'idle_in_txn', label: 'idle in txn', num: true },
    { key: 'waiting_lock', label: 'lock waits', num: true },
    { key: 'active_client_wait', label: 'client waits', num: true },
    { key: 'longest_active_secs', label: 'longest active', num: true, fmt: fmtSecs },
    { key: 'longest_idle_txn_secs', label: 'longest idle', num: true, fmt: fmtSecs },
    { key: 'oldest_xmin_age', label: 'oldest xmin age', num: true },
  ];
}
