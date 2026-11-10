// The session SETs section of the Configuration tab (task 58): every SET, SET LOCAL and RESET the instance's sessions
// ran (pg_stat_statements' utility rows, read hourly by the session_sets collection), per role and database, with the
// calls in the window. A planner setting SET by the sessions in the window is the finding "a planner setting changed
// by the application's sessions": a plan measured in psql or pgAdmin runs without it and cannot show the application's
// plan. The Compare tab (compare.ts) shows the same rows beside a statement's roles (setsByRole). Data from
// /api/sessionsets; the Configuration tab's call to sessionSetsSection is the shell's.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

interface SessionSetsData { state: Table | null; sets: Table | null }

// valueText: the value as the text kept it, or why it is not there
export function valueText(r: Row): string {
  if (r.value != null) return r.value === '' ? "'' (empty)" : String(r.value);
  if (r.command === 'RESET') return '';
  return r.value_hidden ? '(hidden: PostgreSQL 17+ keeps $1)' : '(not kept: query_text policy)';
}

// setLabel: 'SET enable_hashjoin = off' in one line, for the Compare tab's column
export function setLabel(r: Row): string {
  const v = valueText(r);
  return `${String(r.command)} ${String(r.setting)}${r.command === 'RESET' ? '' : ' = ' + v}`;
}

const cols: Col[] = [
  { key: 'fires', label: 'finding', fmt: v => v ? badge('planner setting changed by the sessions', 'warn') : '' },
  { key: 'rolname', label: 'role' },
  { key: 'datname', label: 'database' },
  { key: 'command' },
  { key: 'setting', fmt: (v, r) => r.planner ? el('span', {}, el('strong', {}, String(v)), ' (planner)') : String(v ?? '') },
  { key: 'value', fmt: (_, r) => valueText(r) },
  { key: 'calls_in_window', label: 'calls in the window', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'calls', label: 'calls since the reset', num: true },
  { key: 'first_seen', label: 'first seen', fmt: fmtTime },
  { key: 'last_grew', label: 'last ran (read)', fmt: fmtTime },
  { key: 'query', label: 'statement text', wide: true },
];

// readSets: the state and the rows of the window
export async function readSets(ctx: Ctx): Promise<{ state?: Row; sets: Row[] }> {
  const d = await get<SessionSetsData>('sessionsets', { instance: ctx.instance, ...window_(ctx) });
  return { state: rowsOf(d.state)[0], sets: rowsOf(d.sets) };
}

// setsKey: a role in a database (a role's SETs in another database are not a statement's here)
export const setsKey = (rolname: unknown, datname: unknown): string => `${String(rolname ?? '')}\u0000${String(datname ?? '')}`;

// setsByRole: the SETs and RESETs that ran in the window (calls gained), by role and database, planner ones first
export function setsByRole(sets: Row[]): Map<string, Row[]> {
  const m = new Map<string, Row[]>();
  for (const r of sets) {
    if (r.calls_in_window == null || Number(r.calls_in_window) <= 0) continue;
    const k = setsKey(r.rolname, r.datname);
    if (!m.has(k)) m.set(k, []);
    m.get(k)!.push(r);
  }
  return m;
}

export async function sessionSetsSection(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h3', {}, `Settings changed by the sessions (${rangeLabel(ctx)})`));
  try {
    const { state, sets } = await readSets(ctx);
    sec.append(el('p', { class: 'meta' }, 'What the instance\'s sessions SET, SET LOCAL or RESET, from pg_stat_statements\' '
      + 'utility rows (read hourly). The server\'s and the roles\' settings are above; these are the ones the application '
      + 'changes for itself, which a plan measured in another session does not see. A planner setting (enable_*, *_cost, '
      + 'work_mem, jit, the collapse limits, geqo*, plan_cache_mode, default_statistics_target, effective_cache_size, '
      + 'hash_mem_multiplier, max_parallel_workers_per_gather) SET in the window to a value that is not the server\'s is a '
      + 'finding (a SET back to the server\'s value changes no plan). PostgreSQL 17 and later keep $1 in place of the value. '
      + 'The SETs pgvigil itself runs (its session setup, the index read\'s search_path, the Explain\'s plan_cache_mode) are left out under its role; its other SETs stay, '
      + 'so a login the application shares with the monitor still shows the application\'s. '
      + 'A row present is evidence; no row is inconclusive.'));
    if (!state) {
      sec.append(el('p', { class: 'empty' }, 'The session_sets collection has not read this instance yet.'));
      return sec;
    }
    if (state.status !== 'ok') {
      sec.append(el('p', { class: 'meta' }, badge('not available', 'warn'), ` ${String(state.reason ?? '')} (read ${fmtTime(state.snapshot_at)}).`
        + (sets.length ? ' The rows below are from earlier reads.' : '')));
    } else {
      sec.append(el('p', { class: 'meta' }, `Last read ${fmtTime(state.snapshot_at)}; pg_stat_statements.track_utility ${String(state.track_utility ?? '')}.`));
    }
    const fires = sets.filter(r => r.fires).length;
    if (fires) sec.append(el('p', {}, badge(`${fires} planner setting(s) changed by the sessions in the window`, 'warn')));
    sec.append(grid(sets, cols, 'No SET or RESET recorded for this instance.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
