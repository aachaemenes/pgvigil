// The Waits tab (task 41): what the server's sessions waited on over the window, by event and by statement, the
// samples per event type over time, and the blocking tree of the newest activity snapshot. With pg_wait_sampling the
// numbers are its 10 ms samples (so time); without it they are the activity samples (one look at every active session
// a minute), and the page says so. Data from /api/waits; the route and the tree entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

interface WaitsData { state: Table | null; events: Table | null; series: Table | null; queries: Table | null; locktree: Table | null }

const sourceText: Record<string, string> = {
  pg_wait_sampling: 'pg_wait_sampling: every backend sampled every profile period (10 ms by default)',
  pgms_wait_sampling: 'pgms_wait_sampling: Azure\'s aggregated wait samples',
  activity: 'the activity samples: one look at every active session a minute (install pg_wait_sampling for 10 ms samples and wait time)',
};

// waitClass colours the event type the way the Running queries page reads it: Lock is blocking, the rest is not.
const typeBadge = (v: unknown) => badge(String(v ?? ''), v === 'Lock' ? 'warn' : '');
const secs = (v: unknown) => v == null ? '' : fmtSecs(Math.round(Number(v)));

const eventCols: Col[] = [
  { key: 'event_type', label: 'type', fmt: typeBadge },
  { key: 'event' },
  { key: 'samples', num: true },
  { key: 'wait_secs', label: 'wait time', num: true, fmt: secs },
  { key: 'pct', label: 'share', num: true, fmt: v => v == null ? '' : fmtNum(v) + ' %' },
];

const queryCols: Col[] = [
  { key: 'queryid', label: 'query id', fmt: v => v == null || Number(v) === 0 ? '' : String(v) },
  { key: 'samples', num: true },
  { key: 'wait_secs', label: 'wait time', num: true, fmt: secs },
  { key: 'top_wait', label: 'mostly' },
  { key: 'query', wide: true },
];

const treeCols: Col[] = [
  { key: 'pid', fmt: (v, r) => el('span', { style: `padding-left:${(Number(r.level) - 1) * 1.2}em` }, (Number(r.level) > 1 ? '└ ' : '') + String(v)) },
  { key: 'blocked', label: 'blocks', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : '' },
  { key: 'state', fmt: v => v === 'idle in transaction' ? badge(String(v), 'warn') : String(v ?? '') },
  { key: 'wait' },
  { key: 'xact_start', label: 'transaction since', fmt: fmtTime },
  { key: 'datname', label: 'database' }, { key: 'usename', label: 'user' }, { key: 'application_name', label: 'application' },
  { key: 'query', label: 'statement (the last one, on an idle row)', wide: true },
];

// pivot turns (snapshot_at, event_type, samples) rows into one row per time with a column per event type.
function pivot(rows: Row[]): { rows: Row[]; types: string[] } {
  const totals = new Map<string, number>();
  for (const r of rows) totals.set(String(r.event_type), (totals.get(String(r.event_type)) ?? 0) + Number(r.samples));
  const types = [...totals.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8).map(e => e[0]);
  const byTime = new Map<string, Row>();
  for (const r of rows) {
    const k = String(r.snapshot_at);
    if (!byTime.has(k)) byTime.set(k, Object.fromEntries([['snapshot_at', r.snapshot_at], ...types.map(t => [t, 0])]));
    if (types.includes(String(r.event_type))) byTime.get(k)![String(r.event_type)] = Number(r.samples);
  }
  return { rows: [...byTime.values()], types };
}

export async function waitsView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<WaitsData>('waits', { instance: ctx.instance, ...window_(ctx) });
  const events = rowsOf(d.events), st = rowsOf(d.state)[0];
  const sec = el('section', {}, el('h2', {}, `Waits (${rangeLabel(ctx)})`));
  const source = String(events[0]?.source ?? (st?.status === 'ok' ? 'pg_wait_sampling' : 'activity'));
  sec.append(el('p', { class: 'meta' }, 'Source: ' + (sourceText[source] ?? source) + '.'
    + (st?.status === 'skipped' ? ` The waits collection is skipped here: ${String(st.note ?? '')}.` : '')
    + (st?.status === 'error' ? ` The waits collection failed: ${String(st.note ?? '')}.` : '')));
  if (events.length === 0) {
    sec.append(el('p', { class: 'empty' }, 'No wait sample in this window.'));
  } else {
    const total = events.reduce((a, r) => a + Number(r.samples), 0);
    const lock = events.filter(r => r.event_type === 'Lock').reduce((a, r) => a + Number(r.samples), 0);
    const cpu = events.filter(r => r.event_type === 'CPU').reduce((a, r) => a + Number(r.samples), 0);
    const waitTotal = events.reduce((a, r) => a + Number(r.wait_secs ?? 0), 0);
    sec.append(el('div', { class: 'tiles' },
      tile('samples', fmtNum(total)),
      tile(source === 'activity' ? 'session samples' : 'wait time', source === 'activity' ? fmtNum(total) : fmtSecs(Math.round(waitTotal))),
      tile('on CPU (no wait event)', total ? fmtNum(Math.round(100 * cpu / total)) + ' %' : '-'),
      tile('lock waits', total ? fmtNum(Math.round(100 * lock / total)) + ' %' : '-', lock > 0 ? 'warn' : 'ok')));
    const p = pivot(rowsOf(d.series));
    sec.append(el('div', { class: 'charts' }, lineChart('Samples per event type', p.rows, p.types.map(t => ({ key: t, label: t })))));
    sec.append(el('h3', {}, 'Wait events'), grid(events, eventCols));
    sec.append(el('h3', {}, 'Statements that waited most'), grid(rowsOf(d.queries), queryCols,
      'No statement identified (query ids need compute_query_id, on by default with pg_stat_statements).'));
  }
  const tree = rowsOf(d.locktree);
  sec.append(el('h3', {}, 'Lock tree'), el('p', { class: 'meta' },
    (tree.length ? `The activity snapshot of ${fmtTime(tree[0].snapshot_at)}. ` : '')
    + 'Level 1 is a head: it holds a lock others wait for and waits on no one; the cause is its transaction and its last '
    + 'statement, not the object the others wait on. An idle-in-transaction head is the application holding its transaction open.'),
    grid(tree, treeCols, 'No session waited on a lock in the newest activity snapshot of this window.'));
  return sec;
}
