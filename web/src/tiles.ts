// The instance tile wall (task 127; pgwatch's Health Check): the numbers a DBA reads first, each coloured against its
// threshold, and the safety settings as on / off tiles. The instance Summary places it (tileWall); the data is
// /api/tiles, the newest activity read of the window and the cache hit over the window.
import { get, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { window_ } from './router';
import { el, fmtNum, fmtSecs, fmtTime, tile } from './ui';
import { whatIsThis } from './sqlview';

// The thresholds, each [warn, crit]; a value at or past one takes its colour. Exported for the proof and the docs.
export const tileLimits = {
  xminAge: [1_000_000, 100_000_000],     // transactions the oldest session snapshot holds vacuum back
  idleInTxn: [1, 5],                     // sessions idle in a transaction
  idleTxnSecs: [60, 600],                // the longest of them, seconds: crit past 10 minutes whatever the count
  blocked: [1, 5],                       // sessions waiting on a lock
  longestSecs: [60, 600],                // the longest running statement, seconds
  connPct: [75, 90],                     // connections used of max_connections, %
  hitPct: [95, 90],                      // cache hit %, lower is worse: warn under 95, crit under 90
};

// tileRow (task 183, the tile kit): tiles side by side as one named group, each a card (ui.ts tile: a stripe in its state
// colour, a small label over a large figure, a pill on a warning or a critical one); the row wraps to the panel's width
export function tileRow(label: string, ...tiles: HTMLElement[]): HTMLElement {
  return el('div', { class: 'tiles', role: 'group', 'aria-label': label }, ...tiles);
}

// level: 0 ok, 1 warn, 2 crit; NULL = not read.
export function level(v: unknown, [warn, crit]: number[], lowerIsWorse = false): number | null {
  if (v == null || v === '') return null;
  const n = Number(v);
  if (!isFinite(n)) return null;
  if (lowerIsWorse) return n < crit ? 2 : n < warn ? 1 : 0;
  return n >= crit ? 2 : n >= warn ? 1 : 0;
}

const kindOf = (l: number | null) => l == null ? '' : ['ok', 'warn', 'crit'][l];
const words = (l: number | null) => l == null ? 'not read' : ['ok', 'warning', 'critical'][l];

// safety: a setting's tile colour; NULL = not read.
export function safety(name: string, v: unknown): number | null {
  if (v == null || v === '') return null;
  const s = String(v).toLowerCase();
  switch (name) {
    case 'fsync': case 'full_page_writes': return s === 'on' ? 0 : 2;
    case 'synchronous_commit': return s === 'off' ? 1 : 0;
    case 'data_checksums': return s === 'on' ? 0 : 1;
    case 'wal_level': return s === 'minimal' ? 1 : 0;
  }
  return null;
}

// tileWall: the wall for one instance (ctx.instance), at the end of ctx's window.
export async function tileWall(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<{ tiles: Table | null }>('tiles', { instance: ctx.instance, ...window_(ctx) });
  const t = rowsOf(d.tiles)[0] ?? {};
  const one = (label: string, value: unknown, text: string, l: number | null, help: string) => {
    const e = tile(label, value == null ? 'not read' : text, kindOf(l));
    e.setAttribute('title', `${help} (${words(l)})`);
    // the colour's meaning as text for a screen reader (the tile's own text is read as it is); the pill says it to the eye
    e.querySelector('.pill')?.setAttribute('aria-hidden', 'true');
    e.append(el('span', { style: 'position:absolute;left:-10000px;width:1px;height:1px;overflow:hidden' }, `, ${words(l)}`));
    return e;
  };
  const idleL = Math.max(level(t.idle_in_txn, tileLimits.idleInTxn) ?? -1, Number(t.idle_in_txn) > 0 ? level(t.longest_idle_txn_secs, tileLimits.idleTxnSecs) ?? -1 : -1);
  const numbers = tileRow('Instance health',
    one('xmin horizon age', t.oldest_xmin_age, fmtNum(t.oldest_xmin_age), level(t.oldest_xmin_age, tileLimits.xminAge),
      'age(backend_xmin) of the oldest client session: how many transactions vacuum is held back by'),
    one('idle in transaction', t.idle_in_txn,
      fmtNum(t.idle_in_txn) + (Number(t.idle_in_txn) > 0 && t.longest_idle_txn_secs != null ? ` (${fmtSecs(t.longest_idle_txn_secs)})` : ''),
      idleL < 0 ? null : idleL, 'sessions idle inside an open transaction, and the longest of them'),
    one('blocked sessions', t.waiting_lock, fmtNum(t.waiting_lock), level(t.waiting_lock, tileLimits.blocked),
      'sessions waiting on a lock (wait_event_type Lock)'),
    one('longest query', t.longest_active_secs, fmtSecs(t.longest_active_secs), level(t.longest_active_secs, tileLimits.longestSecs),
      'the longest running statement of an active session'),
    one('connections used', t.conn_used_pct, `${fmtNum(t.conn_used_pct)} % (${fmtNum(t.total)} / ${fmtNum(t.max_connections)})`,
      level(t.conn_used_pct, tileLimits.connPct), 'client connections of max_connections'),
    one('cache hit', t.hit_pct, fmtNum(t.hit_pct) + ' %', level(t.hit_pct, tileLimits.hitPct, true),
      'blks_hit / (blks_hit + blks_read) over the window, every database'),
  );
  const set = (name: string, label: string, help: string) => {
    const v = t[name], l = safety(name, v);
    return one(label, v, String(v ?? ''), l, help);
  };
  const settings = tileRow('Safety settings',
    set('fsync', 'fsync', 'off: a crash can corrupt the cluster'),
    set('full_page_writes', 'full_page_writes', 'off: a torn page after a crash cannot be repaired'),
    set('synchronous_commit', 'synchronous_commit', 'off: a crash can lose the last commits (no corruption)'),
    set('data_checksums', 'data checksums', 'off: a corrupted page is not detected when read'),
    set('wal_level', 'wal_level', 'minimal: no physical replica, no point-in-time recovery from the archive'),
  );
  return el('div', { class: 'tile-wall panel' },
    el('h3', {}, 'Health ', whatIsThis(`From the newest activity read of the window (${t.activity_at ? fmtTime(t.activity_at) : 'none'}), `
      + 'the cache hit over the whole window, the settings from the newest instance read'
      + (t.settings_at ? ` (${fmtTime(t.settings_at)})` : '') + '. Hover a tile for its meaning.', 'Health')),
    numbers, settings);
}
