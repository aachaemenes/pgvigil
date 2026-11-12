// Collection dates (task 176b): DBA Dash's Checks > Collection Dates, the page its Summary's Collection cell (Snapshot
// Age) opens. One row per instance and collection: its status (critical: the last run failed; warning: older than the
// daily check 'collection stale' allows, three of its intervals; ok; disabled where its interval is 0), the last run,
// its age, the age it may reach (the warning threshold), the schedule, the next run, the last success and the last
// error kept, the run's duration and note. At the root, a tag folder (its instances) or an instance.
// Data from GET /api/collectiondates.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { href } from './router';
import { fleet, tagsOf } from './fleet';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid } from './ui';

const word: Record<string, string> = { critical: 'Critical', warning: 'Warning', ok: 'OK', disabled: 'Disabled' };
const kind: Record<string, string> = { critical: 'crit', warning: 'warn', ok: 'ok', disabled: '' };
const lsGet = (k: string) => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* private window */ } };

export async function collectionDatesView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Collection dates'));
  const opts: [string, string][] = [['all', 'All'], ['critical,warning', 'Critical, Warning'], ['critical', 'Critical'], ['warning', 'Warning'], ['ok', 'OK'], ['disabled', 'Disabled']];
  const statusSel = el('select', { id: 'cd-status' }, ...opts.map(([v, l]) => el('option', { value: v }, l)));
  const saved = lsGet('pgvigil.collectionDatesStatus');
  statusSel.value = opts.some(o => o[0] === saved) ? saved! : 'all';
  const refresh = el('button', { type: 'button', title: 'Read the collection dates again' }, 'Refresh');
  const body = el('div');
  let seq = 0;
  async function draw() {
    const mine = ++seq;
    let rows: Row[];
    let folder = '';
    try {
      const params: Record<string, string | number | undefined> = {};
      if (ctx.instance) params.instance = ctx.instance;
      else if (ctx.tag) {
        const f = await fleet();
        params.instances = f.instances.filter(r => ctx.tag === 'untagged' ? tagsOf(r).length === 0 : tagsOf(r).includes(ctx.tag!)).map(r => Number(r.instance_id)).join(',') || '0';
        folder = ` of the folder ${ctx.tag}`;
      } else folder = ' of the fleet';
      rows = rowsOf((await get<Record<'collections', Table | null>>('collectiondates', params)).collections);
    } catch (e) { if (mine === seq) body.replaceChildren(errorBox(e)); return; }
    if (mine !== seq) return;
    const want = statusSel.value === 'all' ? null : statusSel.value.split(',');
    const shown = want ? rows.filter(r => want.includes(String(r.status))) : rows;
    const n = (s: string) => rows.filter(r => r.status === s).length;
    const cols: Col[] = [
      ...(ctx.instance ? [] : [{ key: 'instance', fmt: (v: unknown, r: Row) => el('a', { href: href(ctx, { tab: 'collectiondates', instance: Number(r.instance_id), tag: undefined }) }, String(v ?? '')) } as Col]),
      { key: 'collection', label: 'reference' },
      { key: 'status', fmt: v => badge(word[String(v)] ?? String(v), kind[String(v)] ?? '') },
      { key: 'snapshot_at', label: 'snapshot date', fmt: fmtTime },
      { key: 'age_secs', label: 'snapshot age', num: true, fmt: v => v == null ? '' : fmtSecs(v) },
      { key: 'stale_secs', label: 'warning threshold', num: true, fmt: (v, r) => r.status === 'disabled' ? '' : `older than ${fmtSecs(v)}` },
      { key: 'last_status', label: 'critical threshold', fmt: (_v, r) => r.status === 'disabled' ? '' : 'the last run failed' },
      { key: 'interval_secs', label: 'schedule', num: true, fmt: v => v == null ? 'not known' : Number(v) === 0 ? 'disabled' : `every ${fmtSecs(v)}` },
      { key: 'next_run', label: 'next run', fmt: fmtTime },
      { key: 'last_success', label: 'last success', fmt: (v, r) => v == null ? (r.last_status === 'ok' ? '' : 'not kept (the last run failed)') : fmtTime(v) },
      { key: 'last_error_at', label: 'last error', fmt: fmtTime },
      { key: 'duration_ms', label: 'duration (ms)', num: true, fmt: fmtNum },
      { key: 'note', wide: true },
    ];
    body.replaceChildren(
      el('p', { class: 'meta' }, `${fmtNum(rows.length)} collection(s)${folder}: ${n('critical')} critical, ${n('warning')} warning, ${n('ok')} OK, ${n('disabled')} disabled. `
        + 'Critical: the last run failed. Warning: the last run is older than three of the collection\'s intervals (300 s at least), the daily check \'collection stale\'. '
        + 'The schedule is the collector\'s interval for the collection; the next run is the last run plus it.'),
      grid(shown, cols, want ? 'No collection matches the filter: show All to list every collection.' : 'No collection has run yet.'));
  }
  statusSel.addEventListener('change', () => { lsSet('pgvigil.collectionDatesStatus', statusSel.value); void draw(); });
  refresh.addEventListener('click', () => void draw());
  sec.append(el('div', { class: 'toolbar' }, refresh, ' ', el('label', { for: 'cd-status' }, 'Status ', statusSel)), body);
  await draw();
  return sec;
}
