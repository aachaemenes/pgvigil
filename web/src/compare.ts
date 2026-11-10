// The Compare tab of the Statements page (task 57; DBADash's Object Execution Compare, pg_profile's differential
// report): the window picker's range against the same range one day and seven days earlier, per statement its calls,
// total and mean time and pages a call (shared blocks hit + read) in each, and the ratios; the grid is sorted by the
// largest ratio, and a statement's button opens its own history (the window and the seven days before it) under the
// grid. A ratio of 10 or more on a statement with 1,000 calls or more in the window is a regression (the Findings carry
// it from compare_findings). Data from /api/compare; the route and the Statements page's link are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { readSets, setLabel, setsByRole, setsKey } from './sessionsets';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

interface CompareData { windows: Table | null; rows: Table | null }
interface HistoryData { history: Table | null }

const ratioMin = 10, callsMin = 1000, limit = 200;

const ms = (v: unknown) => v == null ? '' : fmtNum(Math.round(Number(v) * 100) / 100) + ' ms';
const whole = (v: unknown) => v == null ? '' : fmtNum(Math.round(Number(v)));

// ratio: 'x12.3', marked when it is a regression (10 or more on a statement with 1,000 calls or more in the window)
function ratio(v: unknown, r: Row): string | Node {
  if (v == null) return '';
  const n = Number(v), t = 'x' + fmtNum(n >= 100 ? Math.round(n) : Math.round(n * 10) / 10);
  return n >= ratioMin && Number(r.calls) >= callsMin ? badge(t, 'warn') : t;
}

// status: a baseline's figures, or why there are none
function baseline(prefix: 'd1' | 'd7'): (v: unknown, r: Row) => string | Node {
  return (v, r) => {
    const st = String(r[prefix + '_status'] ?? '');
    if (st === 'no baseline') return badge('no baseline', '');
    if (st === 'not run') return 'not run';
    if (st === 'partial') return el('span', { title: 'the statement began in this window\'s second half: no ratio' }, whole(v) + ' (partial)');
    return whole(v);
  };
}

// setsCell: the SETs and RESETs the statement's roles ran in its database in the window (task 58), planner ones marked;
// null = not read. The rest are counted on a button that writes the whole list into the region under the grid (keyboard
// and screen reader reach it; a title alone does not). A labelled control's name begins with its visible text (WCAG
// 2.5.3, axe label-content-name-mismatch).
function setsCell(byRole: Map<string, Row[]> | null, out: HTMLElement): (v: unknown, r: Row) => string | Node {
  return (_, r) => {
    if (!byRole) return 'not read';
    const roles = Array.isArray(r.usenames) ? r.usenames.map(String) : [];
    const sets = roles.flatMap(k => byRole.get(setsKey(k, r.datname)) ?? []);
    if (sets.length === 0) return 'none';
    // the planner ones by name, the rest as a count; every SET in the title (the cell stays one line in a wide grid)
    const all = sets.map(x => `${setLabel(x)} (${String(x.rolname)}, ${fmtNum(x.calls_in_window)})`).join('; ');
    const box = el('span', { title: all });
    const planner = sets.filter(x => x.fires), rest = sets.length - planner.length;
    planner.forEach((x, i) => {
      if (i) box.append(' ');
      box.append(badge(`${setLabel(x)} (${fmtNum(x.calls_in_window)})`, 'warn'));
    });
    if (rest) {
      const text = `${planner.length ? '+' : ''}${rest} other`;
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `${text}: list the ${sets.length} session SETs of statement ${String(r.queryid)}'s roles in ${String(r.datname ?? 'its database')}` }, text);
      b.addEventListener('click', () => {
        out.replaceChildren(el('h3', { tabindex: '-1' }, `Session SETs of the roles of statement ${String(r.queryid)} in ${String(r.datname ?? 'its database')} in the window`),
          el('ul', {}, ...sets.map(x => el('li', {}, `${setLabel(x)} (${String(x.rolname)}, ${fmtNum(x.calls_in_window)} calls)${x.fires ? ': a planner setting changed by the sessions' : ''}`))));
        (out.querySelector('h3') as HTMLElement | null)?.focus();
      });
      box.append(planner.length ? ' ' : '', b);
    }
    return box;
  };
}

function cols(onOpen: (r: Row) => void, byRole: Map<string, Row[]> | null, out: HTMLElement): Col[] {
  return [
    { key: 'queryid', label: 'statement', fmt: (v, r) => {
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `${String(v)}: open the history of this statement` }, String(v));
      b.addEventListener('click', () => onOpen(r));
      return b;
    } },
    { key: 'max_ratio', label: 'largest ratio', num: true, fmt: ratio },
    { key: 'max_ratio_of', label: 'of' },
    { key: 'calls', num: true, fmt: whole },
    { key: 'd1_calls', label: 'calls 1 day earlier', num: true, fmt: baseline('d1') },
    { key: 'd7_calls', label: 'calls 7 days earlier', num: true, fmt: baseline('d7') },
    { key: 'd1_calls_ratio', label: 'calls x 1 d', num: true, fmt: ratio },
    { key: 'd7_calls_ratio', label: 'calls x 7 d', num: true, fmt: ratio },
    { key: 'total_exec_ms', label: 'total time', num: true, fmt: ms },
    { key: 'd1_total_ratio', label: 'time x 1 d', num: true, fmt: ratio },
    { key: 'd7_total_ratio', label: 'time x 7 d', num: true, fmt: ratio },
    { key: 'mean_exec_ms', label: 'mean', num: true, fmt: ms },
    { key: 'd1_mean_exec_ms', label: 'mean 1 d', num: true, fmt: ms },
    { key: 'd7_mean_exec_ms', label: 'mean 7 d', num: true, fmt: ms },
    { key: 'pages_per_call', label: 'pages a call', num: true, fmt: whole },
    { key: 'd1_pages_per_call', label: 'pages a call 1 d', num: true, fmt: baseline('d1') },
    { key: 'd7_pages_per_call', label: 'pages a call 7 d', num: true, fmt: baseline('d7') },
    { key: 'd1_ppc_ratio', label: 'pages x 1 d', num: true, fmt: ratio },
    { key: 'd7_ppc_ratio', label: 'pages x 7 d', num: true, fmt: ratio },
    { key: 'datname', label: 'database' },
    { key: 'usenames', label: 'roles' },
    { key: 'sets', label: 'session SETs of its roles in its database (window)', fmt: setsCell(byRole, out) },
    // cut to one line here (23 columns squeeze a wrapping cell into a tall row); the whole text in the title and the history
    { key: 'query', fmt: v => { const t = String(v ?? ''); return el('span', { title: t }, t.length > 80 ? t.slice(0, 80) + '...' : t); } },
  ];
}

const windowText: Record<string, string> = {
  ok: 'read',
  'no baseline': 'no baseline: the statements collection did not read the instance then',
};

// history draws one statement's calls, mean time and pages a call per step
async function history(ctx: Ctx, r: Row, out: HTMLElement): Promise<void> {
  out.replaceChildren(el('p', { class: 'meta' }, `Reading the history of statement ${String(r.queryid)}...`));
  try {
    const d = await get<HistoryData>('compare', { instance: ctx.instance, ...window_(ctx), queryid: String(r.queryid) });
    const rows = rowsOf(d.history);
    out.replaceChildren(
      el('h3', { tabindex: '-1' }, `Statement ${String(r.queryid)}: the window and the seven days before it`),
      el('p', { class: 'meta wide' }, String(r.query ?? '(no text)')),
      rows.length === 0 ? el('p', { class: 'empty' }, 'No delta of this statement in the window or the seven days before it.')
        : el('div', { class: 'charts' },
          lineChart('Calls per step', rows, [{ key: 'calls', label: 'calls' }]),
          lineChart('Mean time (ms)', rows, [{ key: 'mean_exec_ms', label: 'mean ms' }]),
          lineChart('Pages a call', rows, [{ key: 'pages_per_call', label: 'pages a call' }])),
      grid(rows, [{ key: 'snapshot_at', label: 'step ending', fmt: fmtTime }, { key: 'calls', num: true, fmt: whole },
        { key: 'total_exec_ms', label: 'total time', num: true, fmt: ms }, { key: 'mean_exec_ms', label: 'mean', num: true, fmt: ms },
        { key: 'pages_per_call', label: 'pages a call', num: true, fmt: whole }]));
    (out.querySelector('h3') as HTMLElement | null)?.focus();
  } catch (e) {
    out.replaceChildren(errorBox(e));
  }
}

export async function compareView(ctx: Ctx): Promise<HTMLElement> {
  // the SETs column reads the session_sets list beside the compare; its failure leaves the column 'not read'
  const [d, sets] = await Promise.all([get<CompareData>('compare', { instance: ctx.instance, ...window_(ctx), limit }),
    readSets(ctx).catch(() => null)]);
  const byRole = sets ? setsByRole(sets.sets) : null;
  const windows = rowsOf(d.windows), rows = rowsOf(d.rows);
  const sec = el('section', {}, el('h2', {}, `Compare: the statements of ${rangeLabel(ctx)} against one and seven days earlier`));
  sec.append(el('p', { class: 'meta' }, 'Each statement (its queryid) in the window against the same window one day and seven days '
    + 'earlier: calls, total and mean time, and pages a call (shared blocks hit + read). A ratio of '
    + `${ratioMin} or more on a statement with ${fmtNum(callsMin)} calls or more in the window is marked: it is a regression `
    + '(the Findings list the last 24 hours\' ones). "partial": the statement began in that window\'s second half, so it has '
    + 'figures and no ratio; "not run": the instance was read then and the statement did not run; '
    + '"no baseline": nothing was read then. The figures are pg_stat_statements deltas, each scaled by its share of the window. '
    + 'The session SETs column lists what the statement\'s roles SET or RESET in the window (the Configuration tab has them all): '
    + 'a planner setting there means the application planned the statement under it.'));
  sec.append(grid(windows, [
    { key: 'label', label: 'window' }, { key: 'from_at', label: 'from', fmt: fmtTime }, { key: 'to_at', label: 'to', fmt: fmtTime },
    { key: 'status', fmt: v => windowText[String(v)] ?? String(v ?? '') },
  ]));
  const regress = rows.filter(r => Number(r.calls) >= callsMin && Number(r.max_ratio) >= ratioMin).length;
  sec.append(el('p', { class: 'meta' }, (rows.length >= limit ? `The first ${limit} statements by the largest ratio (the window may hold more)` : `${rows.length} statement(s)`)
    + `, ${regress} regression(s) among them.`));
  const detail = el('div', { class: 'compare-history', 'aria-live': 'polite' });
  sec.append(grid(rows, cols((r) => { void history(ctx, r, detail); }, byRole, detail),
    'No statement deltas in this window (pg_stat_statements missing, or fewer than two snapshots).'), detail);
  return sec;
}
