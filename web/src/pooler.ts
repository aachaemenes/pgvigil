// The Pooler tab of an instance (phase 3 wave F, task 62): a PgBouncer in front of the instance, read every minute
// through its admin console (the instance's pgbouncer: DSN, a stats_users login, SHOW only): the pools as last read
// (clients active and waiting, servers active and idle, the longest wait, the pool's size), the clients and servers
// over the window, the per-database rates, and SHOW DATABASES and SHOW CONFIG as read. An instance without the DSN
// has no pooler state: hasPooler(ctx) is false and the shell shows no Pooler tab. Data from /api/pooler; the lead
// wires the tab and the check (router.ts, main.ts).
import { get, Row, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, rangeLabel, window_ } from './router';
import { findingCols } from './memory';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props, tile } from './ui';

type PoolerParts = 'state' | 'pools' | 'series' | 'stats' | 'findings';

const ms = (v: unknown) => v == null ? '' : Number(v) >= 1000 ? fmtNum(Math.round(Number(v) / 100) / 10) + ' s' : fmtNum(Math.round(Number(v))) + ' ms';
const us = (v: unknown) => v == null ? '' : ms(Number(v) / 1000);
const yes = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';

const poolCols: Col[] = [
  { key: 'database' }, { key: 'user' },
  { key: 'cl_active', label: 'clients active', num: true },
  { key: 'cl_waiting', label: 'clients waiting', num: true, cls: v => Number(v) > 0 ? 'warn' : '' },
  { key: 'sv_active', label: 'servers active', num: true },
  { key: 'sv_idle', label: 'servers idle', num: true },
  { key: 'sv_used', label: 'servers used', num: true },
  { key: 'pool_size', label: 'pool size', num: true },
  { key: 'pool_size_from', label: 'size set by', fmt: v => v === 'user' ? 'the user ([users])' : v === 'database' ? 'the database' : '' },
  { key: 'maxwait_ms', label: 'longest wait', num: true, fmt: ms },
  { key: 'pool_mode', label: 'mode' },
];

const statsCols: Col[] = [
  { key: 'database' },
  { key: 'query_rate', label: 'queries / s', num: true },
  { key: 'xact_rate', label: 'transactions / s', num: true },
  { key: 'avg_query_us', label: 'mean query time', num: true, fmt: us },
  { key: 'avg_wait_us', label: 'mean client wait', num: true, fmt: us },
  { key: 'total_query_count', label: 'queries (since start)', num: true },
  { key: 'total_xact_count', label: 'transactions (since start)', num: true },
];

const dbCols: Col[] = [
  { key: 'name', label: 'pooler database' }, { key: 'host' }, { key: 'port', num: true }, { key: 'database', label: 'server database' },
  { key: 'pool_size', label: 'pool size', num: true },
  { key: 'pool_size_from', label: 'size set by', fmt: v => v === 'user' ? 'the user ([users])' : v === 'database' ? 'the database' : '' }, { key: 'min_pool_size', label: 'min pool', num: true },
  { key: 'reserve_pool', label: 'reserve', num: true }, { key: 'pool_mode', label: 'mode' },
  { key: 'max_connections', label: 'max connections', num: true }, { key: 'current_connections', label: 'connections', num: true },
  { key: 'paused', fmt: yes }, { key: 'disabled', fmt: yes },
];

const confCols: Col[] = [{ key: 'key', label: 'setting' }, { key: 'value', wide: true }, { key: 'changeable', fmt: yes }];

// jsonRows: a jsonb array of objects as grid rows
function jsonRows(v: unknown): Row[] {
  if (Array.isArray(v)) return v as Row[];
  if (typeof v === 'string') try { const p = JSON.parse(v); return Array.isArray(p) ? p as Row[] : []; } catch { return []; }
  return [];
}

// hasPooler: whether the instance has a pooler read (the shell's check before it shows the Pooler tab)
export async function hasPooler(instance: number): Promise<boolean> {
  const d = await get<Record<'state', Table | null>>('pooler', { instance, part: 'state' });
  return rowsOf(d.state).length > 0;
}

export async function pooler(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Pooler (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<PoolerParts, Table | null>>('pooler', { instance: ctx.instance, ...window_(ctx) });
    const st = rowsOf(d.state)[0];
    if (!st) {
      sec.append(el('p', { class: 'empty' }, 'No pooler read for this instance: its configuration names no pgbouncer: DSN (the pooler\'s admin console, '
        + 'dbname=pgbouncer, as a stats_users login), or the pgbouncer collection has not read it yet.'));
      return sec;
    }
    if (st.status !== 'ok') {
      sec.append(el('p', { class: 'meta' }, badge('not read', 'warn'), ` ${String(st.reason ?? '')} (tried ${fmtTime(st.snapshot_at)}; `
        + `last read ${st.last_ok ? fmtTime(st.last_ok) : 'never'}). The rows below are from the last read.`));
    }
    const pools = rowsOf(d.pools);
    const sum = (k: string) => pools.reduce((s, r) => s + Number(r[k] ?? 0), 0);
    const maxwait = pools.reduce((m, r) => Math.max(m, Number(r.maxwait_ms ?? 0)), 0);
    sec.append(el('div', { class: 'tiles' },
      tile('clients active', fmtNum(sum('cl_active'))),
      tile('clients waiting', fmtNum(sum('cl_waiting')), sum('cl_waiting') > 0 ? 'warn' : ''),
      tile('servers active', fmtNum(sum('sv_active'))),
      tile('longest wait', pools.length ? ms(maxwait) : '-', maxwait > 5000 ? 'crit' : ''),
    ));
    sec.append(props([
      ['pooler', String(st.version ?? '')],
      ['last read', fmtTime(st.last_ok ?? st.snapshot_at)],
    ]));
    const findings = rowsOf(d.findings);
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, findingCols));
    sec.append(el('h3', {}, 'Pools (SHOW POOLS)'), grid(pools, poolCols, 'No pool at the last read.'));
    sec.append(lineChart('Clients and servers', rowsOf(d.series), [
      { key: 'cl_active', label: 'clients active' }, { key: 'cl_waiting', label: 'clients waiting' },
      { key: 'sv_active', label: 'servers active' }, { key: 'sv_idle', label: 'servers idle' },
    ]));
    sec.append(el('h3', {}, 'Rates (SHOW STATS)'),
      el('p', { class: 'meta' }, 'PgBouncer\'s own averages over its stats_period at the last read.'),
      grid(rowsOf(d.stats), statsCols, 'No database statistics at the last read.'));
    sec.append(el('h3', {}, 'Databases (SHOW DATABASES)'), grid(jsonRows(st.databases), dbCols, 'Not read yet.'));
    sec.append(el('h3', {}, 'Settings (SHOW CONFIG)'), grid(jsonRows(st.config), confCols, 'Not read yet.'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
