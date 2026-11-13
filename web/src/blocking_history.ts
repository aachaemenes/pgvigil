// The blocking history of an instance over the range (task 120). Data from /api/blocking/history.
//
// PostgreSQL (pgBlockingHistory, under the Running queries snapshot): the chains of the activity samples with their
// denominator (Darling 14.2): captures, captures with blocking and their share, the worst chain and its root's state,
// captures with a cycle; a chart of the blocked sessions and the longest blocked per step; one row per head
// TRANSACTION (its samples as root, its states, how often idle in transaction, its transaction's age, victims, direct,
// depth, its last statement), each opening the Running snapshot of its last capture; and which session pinned the
// xmin horizon (Darling 14.3): what holds it now, and per session how many captures it held the oldest xmin in.
// SQL Server (mssqlBlockingTrend, under the Running queries snapshot): the blocked sessions, the longest wait and the
// summed wait per step from the minute snapshots (Darling 13.5's Blocking snapshot trend), the blocked-process reports
// per step beside them, and the blocked / blocking pairs the snapshots saw over the range, each opening the Running
// queries snapshot where it was last seen (PerformanceMonitor's Blocking view; darling-open D04).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';
import { sqlCell, whatIsThis } from './sqlview';

type PgParts = 'meta' | 'summary' | 'episodes' | 'trend' | 'xmin_summary' | 'xmin_pins' | 'xmin_now';
type MsParts = 'meta' | 'trend' | 'deadlock_trend' | 'pairs';

const sampledNote = 'From the activity samples (pg_stat_activity once a minute: active and idle-in-transaction sessions and every blocker a Lock '
  + 'waiter names). A chain shorter than a minute can fall between two captures, so every count is a floor. A head blocks others and is not '
  + 'blocked itself; the cause of its chain is its transaction and its last statement, not the object the others wait on. The longest blocked '
  + 'is the age of the waiter\'s statement at the capture (the lock wait itself is not sampled).';
const xminNote = 'A session with a backend_xmin keeps vacuum from removing rows deleted after it: the oldest one of a capture pins the horizon. '
  + 'An idle-in-transaction session under READ COMMITTED has no xmin between statements: it holds its locks but pins nothing. '
  + 'Replication slots, prepared transactions and standbys pin it too: those are in "now" from the latest vacuum read.';

// cutNote: the history reads the newest seven days of a longer range
function cutNote(meta: Row | undefined): HTMLElement | null {
  return meta?.cut === true ? el('p', { class: 'meta' }, `The history reads at most seven days: ${fmtTime(meta.from_at)} to ${fmtTime(meta.to_at)}.`) : null;
}
const stepWord = (meta: Row | undefined) => {
  const s = Number(meta?.step_secs ?? 60);
  return s % 3600 === 0 ? `${s / 3600} h` : s % 60 === 0 ? `${s / 60} min` : `${s} s`;
};
const secs = (v: unknown) => v == null ? '' : fmtSecs(v);
const stateCell = (v: unknown) => String(v ?? '').startsWith('idle in transaction') ? badge(String(v), 'warn') : String(v ?? '');

export async function pgBlockingHistory(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { class: 'blocking-history' }, el('h3', {}, `Blocking history (${rangeLabel(ctx)}) `, whatIsThis(sampledNote, 'Blocking history')));
  try {
    const d = await get<Record<PgParts, Table | null>>('blocking/history', { instance: ctx.instance, ...window_(ctx) });
    const meta = rowsOf(d.meta)[0];
    const cut = cutNote(meta);
    if (cut) sec.append(cut);
    const sum = rowsOf(d.summary)[0] ?? {};
    const n = Number(sum.captures ?? 0), withB = Number(sum.with_blocking ?? 0);
    sec.append(el('div', { class: 'tiles' },
      tile('captures', fmtNum(n)),
      tile('with blocking', fmtNum(withB), withB ? 'warn' : ''),
      tile('of captures', n ? fmtNum(sum.pct_with_blocking ?? 0) + ' %' : '-'),
      tile('worst chain victims', sum.worst_victims == null ? '-' : fmtNum(sum.worst_victims)),
      tile('its root\'s state', String(sum.worst_root_state ?? '-'), String(sum.worst_root_state ?? '').startsWith('idle in transaction') ? 'warn' : ''),
      tile('captures with a cycle', fmtNum(sum.with_cycle ?? 0), Number(sum.with_cycle ?? 0) ? 'warn' : '')));
    if (!n) { sec.append(el('p', { class: 'empty' }, 'No activity capture in this window.')); return sec; }
    const trend = rowsOf(d.trend);
    if (withB) {
      sec.append(el('div', { class: 'charts' },
        lineChart(`Blocked sessions (the most in one capture, per ${stepWord(meta)})`, trend, [{ key: 'blocked_max', label: 'blocked' }]),
        lineChart(`Longest blocked and oldest root transaction (per ${stepWord(meta)})`, trend,
          [{ key: 'longest_blocked_secs', label: 'longest blocked' }, { key: 'oldest_root_xact_secs', label: 'oldest root transaction' }], v => fmtSecs(v))));
    }
    const cols: Col[] = [
      { key: 'last_at', label: 'last seen', fmt: (v) => el('a', { href: href(ctx, { tab: 'activity', at: String(v) }), title: 'The Running queries snapshot of this capture' }, fmtTime(v)) },
      { key: 'first_at', label: 'first seen', fmt: fmtTime },
      { key: 'head_pid', label: 'root pid', num: true, fmt: v => String(v) },
      { key: 'head_datname', label: 'database' }, { key: 'head_usename', label: 'user' }, { key: 'head_application', label: 'application' },
      { key: 'last_state', label: 'root state', fmt: stateCell },
      { key: 'idle_in_txn_samples', label: 'idle in transaction', num: true, fmt: (v, r) => Number(v) ? `${fmtNum(v)} of ${fmtNum(r.samples)}` : 'no' },
      { key: 'xact_secs', label: 'transaction age', num: true, fmt: secs },
      { key: 'victims', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : '' },
      { key: 'direct', num: true },
      { key: 'depth', num: true },
      { key: 'longest_blocked_secs', label: 'longest blocked', num: true, fmt: secs },
      { key: 'samples', label: 'samples as root', num: true },
      { key: 'head_query', label: 'root\'s last statement', fmt: (v, r) => sqlCell(v, { heading: `pid ${String(r.head_pid)}: last statement`,
        title: String(r.last_state ?? '').startsWith('idle') ? 'The root was idle: this is the LAST statement it ran, not one running.' : undefined }) },
    ];
    const ep = rowsOf(d.episodes);
    sec.append(el('h4', {}, 'Chains by root transaction'),
      grid(ep, cols, 'No blocking chain in any capture of this window.'));
    if (ep.length >= 500) sec.append(el('p', { class: 'meta' }, 'The 500 roots with the most captures.'));
    sec.append(xminSection(d));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}

function xminSection(d: Record<PgParts, Table | null>): HTMLElement {
  const box = el('section', { class: 'xmin-pins' }, el('h4', {}, 'Who pins the xmin horizon ', whatIsThis(xminNote, 'Who pins the xmin horizon')));
  const sum = rowsOf(d.xmin_summary)[0] ?? {};
  box.append(el('div', { class: 'tiles' },
    tile('captures with a session xmin', `${fmtNum(sum.with_xmin ?? 0)} of ${fmtNum(sum.captures ?? 0)}`),
    tile('idle-in-transaction sessions', fmtNum(sum.idle_in_txn_sessions ?? 0), Number(sum.idle_in_txn_sessions ?? 0) ? 'warn' : ''),
    tile('of them pinning nothing', fmtNum(sum.idle_in_txn_no_xmin ?? 0))));
  const now = rowsOf(d.xmin_now);
  box.append(el('h5', {}, 'Now (the latest reads)'), grid(now, [
    { key: 'holder' }, { key: 'name', label: 'pid or name' }, { key: 'datname', label: 'database' },
    { key: 'xmin_age', label: 'xmin age', num: true }, { key: 'catalog_xmin_age', label: 'catalog xmin age', num: true },
    { key: 'since', fmt: fmtTime }, { key: 'detail', wide: true },
  ], 'Nothing holds the horizon in the latest reads (none under ten minutes old).'));
  const withX = Number(sum.with_xmin ?? 0);
  box.append(el('h5', {}, 'Over the window, by session'), grid(rowsOf(d.xmin_pins), [
    { key: 'pid', num: true, fmt: v => String(v) },
    { key: 'pinned_samples', label: 'held the oldest xmin', num: true, fmt: v => `${fmtNum(v)} of ${fmtNum(withX)}` },
    { key: 'peak_xmin_age', label: 'peak xmin age', num: true },
    { key: 'peak_at', label: 'at', fmt: fmtTime },
    { key: 'state_at_peak', label: 'state then', fmt: stateCell },
    { key: 'xact_secs_at_peak', label: 'transaction age then', num: true, fmt: secs },
    { key: 'usename', label: 'user' }, { key: 'datname', label: 'database' }, { key: 'application_name', label: 'application' },
    { key: 'backend_type', label: 'backend' }, { key: 'samples', label: 'captures with an xmin', num: true },
    { key: 'first_at', label: 'first seen', fmt: fmtTime }, { key: 'last_at', label: 'last seen', fmt: fmtTime },
    { key: 'query_at_peak', label: 'statement then', fmt: (v, r) => sqlCell(v, { heading: `pid ${String(r.pid)}: statement at its peak xmin age` }) },
  ], 'No sampled session had an xmin in this window.'));
  return box;
}

// mssqlBlockingTrend: the SQL Server Running page's trend of the range (Darling 13.5's Blocking snapshot trend) and the
// pairs of the range (PerformanceMonitor's Blocking view: who blocked whom, from the minute snapshots).
export async function mssqlBlockingTrend(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { class: 'blocking-history' }, el('h3', {}, `Blocking over the range (${rangeLabel(ctx)})`));
  try {
    const q = { instance: ctx.instance, ...window_(ctx) };
    const [d, p] = await Promise.all([
      get<Record<MsParts, Table | null>>('blocking/history', { ...q, part: 'trend' }),
      get<Record<MsParts, Table | null>>('blocking/history', { ...q, part: 'pairs' }),
    ]);
    const trend: Row[] = rowsOf(d.trend).map(r => ({
      ...r,
      longest_wait_s: r.longest_wait_ms == null ? null : Number(r.longest_wait_ms) / 1000,
      summed_wait_s: r.summed_wait_ms == null ? null : Number(r.summed_wait_ms) / 1000,
    }));
    const snaps = trend.reduce((a, r) => a + Number(r.snapshots ?? 0), 0), withB = trend.reduce((a, r) => a + Number(r.with_blocking ?? 0), 0);
    const worst = trend.reduce((a, r) => Math.max(a, Number(r.blocked_max ?? 0)), 0);
    const longest = trend.reduce((a, r) => Math.max(a, Number(r.longest_wait_s ?? 0)), 0);
    const reports = trend.reduce((a, r) => a + Number(r.reports ?? 0), 0);
    const step = trend.length > 1 ? (Date.parse(String(trend[1].snapshot_at)) - Date.parse(String(trend[0].snapshot_at))) / 1000 : 60;
    sec.append(el('div', { class: 'tiles' },
      tile('snapshots', fmtNum(snaps)),
      tile('with a blocked session', fmtNum(withB), withB ? 'warn' : ''),
      tile('of snapshots', snaps ? (Math.round(1000 * withB / snaps) / 10).toLocaleString() + ' %' : '-'),
      tile('most blocked at once', fmtNum(worst)),
      tile('longest wait', longest ? fmtSecs(Math.floor(longest)) : '-'),
      tile('blocked-process reports', fmtNum(reports), reports ? 'warn' : '')));
    if (Date.parse(window_(ctx).to) - Date.parse(window_(ctx).from) > 7 * 86400000) sec.append(el('p', { class: 'meta' }, 'The trend reads the newest seven days of the range.'));
    if (!snaps && !reports) { sec.append(el('p', { class: 'empty' }, 'No snapshot and no blocked-process report in this window.')); return sec; }
    const per = step % 3600 === 0 ? `${step / 3600} h` : `${Math.round(step / 60)} min`;
    sec.append(el('div', { class: 'charts' },
      lineChart(`Blocked sessions and heads (the most in one snapshot, per ${per})`, trend, [{ key: 'blocked_max', label: 'blocked' }, { key: 'heads_max', label: 'heads' }]),
      lineChart(`Longest and summed wait behind blockers (per ${per})`, trend,
        [{ key: 'longest_wait_s', label: 'longest wait' }, { key: 'summed_wait_s', label: 'summed wait (one snapshot)' }], v => fmtSecs(Math.floor(v))),
      lineChart(`Blocked-process reports (per ${per})`, trend, [{ key: 'reports', label: 'reports' }, { key: 'blocked_transactions', label: 'blocked transactions' }])));
    const pairs = rowsOf(p.pairs);
    // the note is the title of a 'what is this' link, as the page's other notes (mssql_running.ts): a page is its grids
    sec.append(el('h4', {}, 'Who blocked whom (the minute snapshots) ', whatIsThis('One row per blocked session and the session that blocked it, from the Running queries snapshots of the range: '
        + 'how often a snapshot saw the pair, first and last, the longest wait. A block shorter than a minute can fall between two snapshots.', 'Who blocked whom')),
      grid(pairs, [
        { key: 'blocked_session_id', label: 'blocked session', num: true, fmt: v => String(v) },
        { key: 'blocking_session_id', label: 'blocking session', num: true, fmt: v => String(v) },
        { key: 'head_session_id', label: 'head of its chain', num: true, fmt: v => v == null ? '' : String(v) },
        { key: 'snapshots', label: 'snapshots', num: true },
        { key: 'longest_wait_ms', label: 'longest wait', num: true, fmt: v => v == null ? '' : fmtSecs(Math.floor(Number(v) / 1000)) },
        { key: 'wait_types', label: 'wait types' }, { key: 'wait_resources', label: 'resources', wide: true },
        { key: 'database_name', label: 'database' }, { key: 'blocked_login', label: 'blocked login' }, { key: 'blocked_program', label: 'blocked program' },
        { key: 'blocking_login', label: 'blocking login' }, { key: 'blocking_program', label: 'blocking program' },
        { key: 'blocking_status', label: 'blocking status', fmt: v => v === 'sleeping' ? badge('sleeping', 'warn') : String(v ?? '') },
        { key: 'first_at', label: 'first seen', fmt: fmtTime },
        // the SQL Server tab reads at= from the address itself (href writes it for the PostgreSQL tab only; running_fleet.ts)
        { key: 'last_at', label: 'last seen', fmt: (v) => el('a', { href: `${href(ctx, { tab: 'mssql_running' })}&at=${encodeURIComponent(String(v))}`, title: 'The Running queries snapshot where this pair was last seen' }, fmtTime(v)) },
      ], 'No snapshot of this window saw a session blocked by another.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
