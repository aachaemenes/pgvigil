// The live figures of an instance as Darling's PerformanceMonitor shows them on its server card and its server page
// header (task 177 D29): Total CPU (the SQL Server / other split), Threads (free or starved), Memory (grant waiters),
// Blocking (the recent hour's count and its longest wait), Deadlocks (the recent hour), Collectors (healthy, failing,
// not collected, no permission), 'N of M measured', the instance's freshness (online, stale, offline: no healthy
// collection for 30 minutes) and its silence. The fleet Summary shows them as columns (pages.ts), every instance page
// as its header and the breadcrumb as the band's dot (main.ts calls instanceFrame).
//
// The bands, thresholds and texts are PerformanceMonitor 3.12.0's (PerformanceMonitor.Common/ServerHealthBands.cs,
// Darling/PerformanceMonitor.Darling.Service/wwwroot/js/pages/fleet.js and server.js), ported:
//   MIT License. Copyright (c) 2026 Erik Darling, Darling Data LLC. Permission is hereby granted, free of charge, to
//   any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the
//   Software without restriction, including without limitation the rights to use, copy, modify, merge, publish,
//   distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
//   furnished to do so, subject to the following conditions: The above copyright notice and this permission notice
//   shall be included in all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS",
//   WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE
//   FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
//   OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
// pgvigil's own differences: PostgreSQL blocking is banded (pgvigil samples lock waits; PerformanceMonitor leaves a
// PostgreSQL target's blocking unbanded); a collection is failing when its last run failed and stale by its own
// interval (the footer's rule, q_frame.go), where PerformanceMonitor counts no success in 24 hours and a 2-minute
// cadence; an acknowledged check does not make the band (the Summary's rule).
import { Row, rowsOf, Table } from './api';
import { AckData, ackDialog, ackOn, ackWhy, cellAcked, checkAcks, endButton, loadAckSafe, offBeside, pageNote, writeButton } from './ack';
import { Cell, cells, cellTarget, cellText, Fleet, fleet, groups, labelOf, sinceState, Target, withTarget } from './fleet';
import { Ctx, href, isMssql } from './router';
import { ownPageAction } from './rowjump';
import { verdict, verdictCard } from './verdict';
import { el, fmtTime, pill } from './ui';

export type Band = 'crit' | 'warn' | 'ok' | 'unknown';
export interface Chip { key: string; label: string; value: string; detail: string; band: Band }
type Live = AckData & { live?: Table | null };

// PerformanceMonitor's constants (ServerHealthBands.cs): offline past 30 minutes without a collection, the newest
// collection searched over 48 hours, CPU 80 / 95 %, blocking 5 / 20 an hour and 10 / 60 seconds of wait, deadlocks 5 /
// 20 an hour, a failing share of collectors over 20 % critical, threads short under 10 % free or 20 waiting for a CPU
export const OFFLINE_MIN = 30;
// the repository's clock at the live read (its live_at), never the browser's: a jump box's clock 30 minutes off would
// show every instance offline or hide one that is
export const serverNow = (live: Row | undefined): number => { const t = Date.parse(String(live?.live_at ?? '')); return isNaN(t) ? Date.now() : t; };
const DARK_HOURS = 48;
const CPU_WARN = 80, CPU_CRIT = 95;
const BLOCK_WARN_H = 5, BLOCK_CRIT_H = 20, BLOCK_WARN_S = 10, BLOCK_CRIT_S = 60;
const DEADLOCK_WARN_H = 5, DEADLOCK_CRIT_H = 20;
const COLLECT_CRIT_PCT = 20;
const THREADS_FREE_PCT = 10, THREADS_CPU_WAIT = 20;
export const DARK_PAST_WINDOW = 'last collected more than 2 days ago';

// An acknowledgement's state of a cell: until-change acknowledgements of uptime and memory dumps change with the start
// or the newest dump only, never with the hours their text counts (DBA Dash: an acknowledgement holds until a restart
// or a dump after it); every other cell by its words and its checks' details.
export function cellState(c: Cell, key = ''): string {
  if ((key === 'uptime' || key === 'dumps') && c.since != null) return sinceState(c.since);
  let h = 5381;
  for (const ch of c.detail.join('\n')) h = ((h * 33) ^ ch.charCodeAt(0)) >>> 0;
  return `${cellText(c)} #${h.toString(36)}`;
}

const num = (v: unknown): number | null => v == null || v === '' ? null : Number(v);
const pct = (v: number) => `${Math.round(v)}%`;
const mb = (kb: number) => kb >= 1048576 ? `${(kb / 1048576).toFixed(1)} GB` : `${Math.round(kb / 1024)} MB`;
const gbOf = (bytes: number) => `${(bytes / 1073741824).toFixed(1)} GB`;
const ms = (s: number) => s >= 60 ? `${(s / 60).toFixed(1)} min` : s >= 1 ? `${s.toFixed(1)} s` : `${Math.round(s * 1000)} ms`;

// PerformanceMonitor's relTime (util.js): just now, Nm ago, Nh ago, Nd ago, then the time itself past 30 days
export function relTime(at: unknown, now = Date.now()): string {
  const t = Date.parse(String(at));
  if (isNaN(t)) return '';
  const min = Math.floor((now - t) / 60000);
  if (min < 1) return 'just now';
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  return day <= 30 ? `${day}d ago` : fmtTime(at);
}

export type Freshness = 'online' | 'stale' | 'offline' | 'awaiting';
// online, stale (a collection past its interval: the footer's rule), offline (no healthy collection for 30 minutes),
// awaiting (no collection ever)
export function freshness(r: Row | undefined, now = Date.now()): Freshness {
  if (!r || r.last_collect_at == null) return 'awaiting';
  if (now - Date.parse(String(r.last_collect_at)) > OFFLINE_MIN * 60000) return 'offline';
  return Number(r.coll_stale ?? 0) > 0 ? 'stale' : 'online';
}
// PerformanceMonitor's 'last collect <clock>' (its localClock: hours and minutes)
export const clockOf = (at: unknown) => new Date(String(at)).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
export const statusWord: Record<Freshness, string> = { online: 'Online', stale: 'Warning', offline: 'Offline', awaiting: 'Awaiting first collection' };
// the age an offline instance shows instead of its figures
export function lastCollected(r: Row | undefined, now = Date.now()): string {
  const at = r?.last_collect_at;
  if (at == null || now - Date.parse(String(at)) > DARK_HOURS * 3600000) return DARK_PAST_WINDOW;
  return `last collected ${relTime(at, now)}`;
}

// PerformanceMonitor's blocking band over a window of h hours (its minimum window is 1 hour)
export function blockingBand(count: number, longestS: number | null, h = 1): Band {
  if (longestS != null && longestS >= BLOCK_CRIT_S) return 'crit';
  if (count / h >= BLOCK_CRIT_H) return 'crit';
  if (longestS != null && longestS >= BLOCK_WARN_S) return 'warn';
  return count / h >= BLOCK_WARN_H ? 'warn' : 'ok';
}
export function deadlockBand(count: number, h = 1): Band {
  return count / h >= DEADLOCK_CRIT_H ? 'crit' : count / h >= DEADLOCK_WARN_H ? 'warn' : 'ok';
}
export const cpuBand = (v: number | null): Band => v == null ? 'unknown' : v >= CPU_CRIT ? 'crit' : v >= CPU_WARN ? 'warn' : 'ok';

// liveChips: the six measures of PerformanceMonitor's card in its order (CPU, Threads, Memory, Blocking, Deadlocks,
// Collectors); an offline instance shows 'n/a' and when it was last collected instead of old figures
export function liveChips(r: Row | undefined, now = Date.now()): Chip[] {
  const fr = freshness(r, now);
  const sql = r?.engine === 'sqlserver';
  const out: Chip[] = [];
  const total = num(r?.cpu_pct), sqlPct = num(r?.cpu_sql), other = num(r?.cpu_other);
  // a Serverless v2 instance: its CPU is a share of the capacity allocated now, so the band and the detail are its
  // ACU utilisation against the configured ceiling (PerformanceMonitor's fleet.js #3281); without an ACU read the
  // band is unknown, never its CPU figure (ServerHealthBands.cs: 'Where no capacity reading exists the band is
  // Unknown, never Healthy')
  const acu = num(r?.acu_pct), maxAcu = num(r?.max_acu), serverless = r?.serverless === true;
  out.push({ key: 'cpu', label: sqlPct != null ? 'Total CPU' : 'CPU', value: total == null ? 'n/a' : pct(total),
    detail: acu != null ? `ACU ${pct(acu)}${maxAcu != null ? ` of ${maxAcu} configured` : ''}`
      : serverless ? 'no ACU read in the last 20 minutes'
      : sqlPct != null ? `SQL ${pct(sqlPct)}${other != null ? ` · other ${pct(other)}` : ''}` : total != null ? 'host' : '',
    band: acu != null ? cpuBand(acu) : serverless ? 'unknown' : cpuBand(total) });
  const maxW = num(r?.max_workers), cur = num(r?.current_workers), queue = num(r?.work_queue), runnable = num(r?.runnable_tasks);
  if (!sql) out.push({ key: 'threads', label: 'Threads', value: 'n/a', detail: 'PostgreSQL has no worker-thread pool', band: 'unknown' });
  else if (maxW == null || cur == null) out.push({ key: 'threads', label: 'Threads', value: 'n/a', detail: 'no scheduler read in the last 15 minutes', band: 'unknown' });
  else {
    const free = Math.max(maxW - cur, 0);
    const band: Band = (queue ?? 0) > 0 ? 'crit' : (runnable ?? 0) >= THREADS_CPU_WAIT || free < maxW * THREADS_FREE_PCT / 100 ? 'warn' : 'ok';
    out.push({ key: 'threads', label: 'Threads', value: (queue ?? 0) > 0 ? `${queue} starved` : `${free} free`, detail: `${cur} in use / ${maxW} threads`, band });
  }
  const totalKb = num(r?.total_kb), bp = num(r?.buffer_pool_kb), waiters = num(r?.grants_pending);
  if (sql && totalKb != null) {
    out.push({ key: 'memory', label: 'Memory', value: (waiters ?? 0) > 0 ? `${waiters} waiters` : 'ok',
      detail: `${mb(totalKb)}${bp != null ? ` · BP ${mb(bp)}` : ''}`, band: (waiters ?? 0) > 0 ? 'crit' : 'ok' });
  } else {
    const t = num(r?.mem_total), u = num(r?.mem_used);
    out.push({ key: 'memory', label: 'Memory', value: 'n/a',
      detail: sql ? 'no memory read in the last 15 minutes' : t != null && u != null ? `host ${gbOf(u)} of ${gbOf(t)} used; no grant queue` : 'no grant queue on PostgreSQL', band: 'unknown' });
  }
  const blocks = num(r?.blocking) ?? 0, longest = num(r?.longest_wait_s);
  out.push(r?.blocking_read ? { key: 'blocking', label: 'Blocking', value: String(blocks), detail: blocks > 0 && longest != null ? `max wait ${ms(longest)}` : '', band: blockingBand(blocks, longest) }
    : { key: 'blocking', label: 'Blocking', value: 'n/a', detail: 'no blocking read in the last hour', band: 'unknown' });
  const dl = num(r?.deadlocks) ?? 0;
  out.push(r?.deadlocks_read ? { key: 'deadlocks', label: 'Deadlocks', value: String(dl), detail: `${dl.toFixed(1)}/hr${r?.last_deadlock_at ? ` · last ${relTime(r.last_deadlock_at, now)}` : ''}`, band: deadlockBand(dl) }
    : { key: 'deadlocks', label: 'Deadlocks', value: 'n/a', detail: 'no deadlock read in the last hour', band: 'unknown' });
  const h = Number(r?.coll_healthy ?? 0), st = Number(r?.coll_stale ?? 0), f = Number(r?.coll_failing ?? 0), nc = Number(r?.coll_not_collected ?? 0), np = Number(r?.coll_no_permission ?? 0);
  const all = h + st + f + nc + np;
  const words = `${h} healthy · ${st ? `${st} warning · ` : ''}${f} failing${nc ? ` · ${nc} not collected` : ''}${np ? ` · ${np} no permission` : ''}`;
  if (fr === 'offline') out.push({ key: 'collectors', label: 'Collectors', value: 'Stale', detail: `no recent collection · ${r?.last_collect_at != null && now - Date.parse(String(r.last_collect_at)) <= DARK_HOURS * 3600000 ? `last ${relTime(r.last_collect_at, now)}` : DARK_PAST_WINDOW}`, band: 'crit' });
  else if (all === 0) out.push({ key: 'collectors', label: 'Collectors', value: 'n/a', detail: 'no collector banded yet', band: 'unknown' });
  else out.push({ key: 'collectors', label: 'Collectors', value: f ? `${f} failing` : 'OK', detail: words, band: f === 0 ? 'ok' : 100 * f / all > COLLECT_CRIT_PCT ? 'crit' : 'warn' });
  // an offline instance's figures are old: n/a, with when it was last collected (the collectors keep their state)
  if (fr === 'offline') for (const c of out) if (c.key !== 'collectors') { c.value = 'n/a'; c.detail = lastCollected(r, now); c.band = 'unknown'; }
  return out;
}

// 'N of M measured': the measures with a reading (a band other than unknown) of the six
export function measured(chips: Chip[]): [number, number] { return [chips.filter(c => c.band !== 'unknown').length, chips.length]; }
export const bandClass = (b: Band) => b === 'crit' ? 'crit' : b === 'warn' ? 'warn' : b === 'ok' ? 'ok' : 'none';
const bandBadge: Partial<Record<Band, string>> = { crit: 'CRIT', warn: 'WARN' };

// chipTab: the page a chip opens on its instance (a chip is a link, as every status text of the Summary is): CPU the
// host's (PostgreSQL) or the CPU page (SQL Server), Threads the connections (PostgreSQL has no worker-thread pool) or
// the CPU page's schedulers, Memory, Blocking and Deadlocks their own pages, Collectors the collection dates
export function chipTab(key: string, ms: boolean): string | undefined {
  switch (key) {
    case 'cpu': return ms ? 'mssqlcpu' : 'host';
    case 'threads': return ms ? 'mssqlcpu' : 'connections';
    case 'memory': return ms ? 'mssqlmemory' : 'memory';
    case 'blocking': return ms ? 'mssql_blocked' : 'activity';
    case 'deadlocks': return ms ? 'mssql_deadlocks' : 'pg_deadlocks';
    case 'collectors': return 'collectiondates';
  }
  return undefined;
}

// the chip as PerformanceMonitor draws it: label (with CRIT / WARN), value, detail; its band is its edge colour; with
// a target (to) the whole chip is a link to its page
export function chipEl(c: Chip, to?: string): HTMLElement {
  const b = bandBadge[c.band];
  const word = b ? (c.band === 'crit' ? 'critical' : 'warning') : '';
  const name = `${c.label}: ${c.value}${c.detail ? `, ${c.detail}` : ''}${word ? `, ${word}` : ''}`;
  // the link's name is its content: an aria-label that does not hold the words in view fails WCAG 2.5.3 (axe's
  // label-content-name-mismatch), so the link carries none and the band's word - the pill shows it as CRIT / WARN,
  // kept out of the reading - is text only a screen reader gets
  const kids = [el('div', { class: 'chip-label' }, c.label, b ? hidden(pill(b, bandClass(c.band))) : null,
      to && word ? el('span', { class: 'visually-hidden' }, `, ${word}`) : null),
    el('div', { class: 'chip-value' }, c.value),
    c.detail ? el('div', { class: 'chip-detail' }, c.detail) : null];
  return to ? el('a', { class: `chip band-${bandClass(c.band)}`, href: to }, ...kids)
    : el('div', { class: `chip band-${bandClass(c.band)}`, role: 'group', 'aria-label': name }, ...kids);
}

// the instance's band as the Summary judges it: its worst check not acknowledged, Offline first. Its items are the
// groups not OK and not acknowledged (worst first, then the Summary's order), each with its level, its cell and the
// page its Summary cell opens; acked the groups not OK an acknowledgement holds; reasons their words. The header and
// the verdict card (verdict.ts) both read this one result.
export interface BandItem { key: string; label: string; level: number; cell: Cell; target: Target }
export interface InstBand { level: number; word: string; cls: string; reasons: string[]; items: BandItem[]; acked: BandItem[]; offline: boolean; cells: Record<string, Cell> }
export function instBand(f: Fleet, r: Row, ad: AckData, live: Row | undefined, now = Date.now()): InstBand {
  const c = cells(f, r);
  const acks = checkAcks(ad);
  const pg = r.engine !== 'sqlserver';
  const held = (key: string) => !!cellAcked(acks, r.instance_id, key, c[key], cellState(c[key], key));
  const bad = groups.filter(g => !c[g.key].none && c[g.key].level > 0);
  const item = (g: typeof groups[number]): BandItem => ({ key: g.key, label: labelOf(g, pg), level: c[g.key].level, cell: c[g.key], target: cellTarget(g, r) });
  const items = bad.filter(g => !held(g.key)).sort((a, b) => c[b.key].level - c[a.key].level).map(item);
  const acked = bad.filter(g => held(g.key)).map(item);
  const level = Math.max(0, ...items.map(i => i.level));
  const reasons = items.map(i => `${i.label} ${cellText(i.cell)}`);
  if (freshness(live, now) === 'offline') return { level: 2, word: 'Offline', cls: 'none', reasons: ['Offline - no recent collection', ...reasons], items, acked, offline: true, cells: c };
  return { level, word: ['OK', 'Warning', 'Critical'][level], cls: ['ok', 'warn', 'crit'][level], reasons, items, acked, offline: false, cells: c };
}

// the band's dot (the breadcrumb, the header): its word is its name for a screen reader, the reasons its title
export function bandDot(b: InstBand): HTMLElement {
  const d = el('span', { class: `dot band-dot ${b.cls}`, role: 'img', 'aria-label': b.word });
  if (b.reasons.length) d.title = b.reasons.join('\n');
  return d;
}

// the silenced mark (PerformanceMonitor's muted bell: a masked vector drawn by app.css, never an emoji, which a
// browser without an emoji font draws as an empty box) and the Silence / Unsilence button of a row (the Alerts page's
// own write: an acknowledgement of kind 'silence', every alert of the server held and still logged), bordered as
// PerformanceMonitor's .silence-btn
export function silencedMark(live: Row | undefined): HTMLElement | null {
  if (live?.silence_id == null) return null;
  return el('span', { class: 'silenced-bell', role: 'img', 'aria-label': 'Alerts silenced',
    title: `Alerts silenced for this server${live.silenced_by ? ` by ${String(live.silenced_by)}` : ''}${live.silenced_until ? ` until ${fmtTime(live.silenced_until)}` : ''}` });
}
export function silenceButton(ad: AckData, r: Row, live: Row | undefined, after: () => void): HTMLElement {
  const name = String(r.name ?? live?.instance ?? '');
  if (live?.silence_id != null) {
    const b = endButton(Number(live.silence_id), `Unsilence '${name}'`, after, 'Unsilence');
    b.classList.add('silence-btn');
    // (a button off for the role keeps the role's words as its title: B24f)
    if (b.getAttribute('aria-disabled') !== 'true') b.title = 'Unsilence this server';
    const why = ackWhy(ad, Number(r.instance_id), name);
    if (why) offBeside(b, why, pageNote(ad));
    return b;
  }
  const b = writeButton(ad, 'Silence', `Silence all alerts for '${name}'`, () => ackDialog({
    title: `Silence all alerts for '${name}'?`,
    what: 'This holds every alert of the server; the held alerts are still logged (Held sends). Unsilence removes it.',
    body: { kind: 'silence', instance_id: Number(r.instance_id) }, expiry: true, noteField: 'optional', after }), { instance: Number(r.instance_id), name });
  b.classList.add('silence-btn');
  if (ackOn(ad, Number(r.instance_id)) && b.getAttribute('aria-disabled') !== 'true') b.title = 'Silence This Server';
  return b;
}

// the silenced instances for the tree's mark (tree.ts): read with the acknowledgements on each tree update, kept
// between draws; refreshSilenced says whether the set changed (the tree then draws again)
let silenced = new Set<number>();
export const silencedSet = (): Set<number> => silenced;
export async function refreshSilenced(): Promise<boolean> {
  const d = await loadAckSafe(['acks']);
  if (d.acks === undefined) return false;   // a failed read keeps the set it had: no bell disappears on one bad read
  const next = new Set(rowsOf(d.acks ?? null).filter(r => r.live && r.kind === 'silence' && r.instance_id != null).map(r => Number(r.instance_id)));
  const changed = next.size !== silenced.size || [...next].some(x => !silenced.has(x));
  silenced = next;
  return changed;
}
// a pill beside a chip's label: the chip's own name already says the band
function hidden(n: HTMLElement): HTMLElement { n.setAttribute('aria-hidden', 'true'); return n; }
export const treeBell = (): HTMLElement => el('span', { class: 'silenced-bell', role: 'img', 'aria-label': 'Alerts silenced', title: 'Alerts silenced for this server' });

// reasonLine: the header's reasons, each a link to the page of its cell (the Summary cell's own target, cellTarget),
// 'Offline' to the collection dates; one whose page is this one answers here (rowjump.ts: on a SQL Server Summary
// Memory dumps and DB Mail jump to their Server card row, Instance Uptime opens its dialog as DBA Dash's Uptime cell
// does) or is text; the first six, then '+n more', a button that shows the rest in place with the focus on the first
// one it adds
function reasonLine(ctx: Ctx, b: ReturnType<typeof instBand>, r: Row): HTMLElement {
  const to = (t: Target) => withTarget(href(ctx, { tab: t.tab, ...(t.kind ? { kind: t.kind } : {}) }), t);
  const links = [...(b.offline ? [{ key: 'offline', text: 'Offline - no recent collection', tab: 'collectiondates', href: href(ctx, { tab: 'collectiondates' }) }] : []),
    ...b.items.map(i => ({ key: i.key, text: `${i.label} ${cellText(i.cell)}`, tab: i.target.tab, href: to(i.target) }))];
  const box = el('div', { class: `meta inst-reason ${b.cls}` });
  const one = (x: typeof links[number]): HTMLElement => {
    const a = el('a', { class: 'cell-link', href: x.href, 'data-group': x.key }, x.text) as HTMLAnchorElement;
    // a reason whose page is this one answers here (rowjump.ts: Instance Uptime's dialog, a Server card row), else text
    if (x.tab !== ctx.tab || ownPageAction(a, x.key, Number(r.instance_id), isMssql(r.engine) && ctx.tab === 'summary')) return a;
    return el('span', { class: 'reason-text', 'data-group': x.key, 'data-nolink': 'this page' }, x.text);
  };
  const draw = (all: boolean) => {
    const parts: (string | HTMLElement)[] = [];
    const shown = (all ? links : links.slice(0, 6)).map(one);
    shown.forEach((x, i) => { if (i) parts.push(', '); parts.push(x); });
    if (!all && links.length > 6) { const more = el('button', { type: 'button', class: 'link', 'aria-expanded': 'false' }, `+${links.length - 6} more`); more.addEventListener('click', () => draw(true)); parts.push(', ', more); }
    box.replaceChildren(...parts);
    // the button is gone: the focus moves to the first reason it added (ui.ts's grid 'show more' does the same)
    if (all && links.length > 6) { const f = shown[6]; if (!f.matches('a')) f.tabIndex = -1; f.focus(); }
  };
  draw(false);
  return box;
}

// instanceFrame: one read for every instance page (main.ts): the header - the band dot and word (the Not OK reasons
// its title), the freshness line ('Online · last collect <time> · N of M measured'), the silence, the six chips - and
// the band's dot for the breadcrumb
export async function instanceFrame(ctx: Ctx, fleetRead?: Promise<Fleet>): Promise<{ header: HTMLElement; dot: HTMLElement } | null> {
  if (!ctx.instance) return null;
  // the live read apart from the acknowledgements: one failing never takes the other with it
  // the fleet read the page's own render made (a Refresh's forced read: the header's band agrees with the tree's)
  const [f, ad, lv] = await Promise.all([fleetRead ?? fleet(), loadAckSafe(['acks']), loadAckSafe(['live'], { instance: ctx.instance }) as Promise<Live>]);
  const r = f.instances.find(x => Number(x.instance_id) === ctx.instance);
  if (!r) return null;
  const live = rowsOf(lv.live ?? null).find(x => Number(x.instance_id) === ctx.instance);
  const now = serverNow(live);
  const b = instBand(f, r, ad, live, now);
  const chips = liveChips(live, now);
  const [n, m] = measured(chips);
  const fr = freshness(live, now);
  const status = fr === 'awaiting' ? statusWord.awaiting
    : `${statusWord[fr]} · ${fr === 'offline' ? lastCollected(live, now) : `last collect ${clockOf(live?.last_collect_at)}`}${n < m ? ` · ${n} of ${m} measured` : ''}`;
  const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
  // data-groups: the band's items in order (an offline band 'offline' first): the verdict card's reasons are these
  // the band word opens the instance's Findings (every finding behind the band, with its detail); the name, the band
  // word and the status line are never a link to the page they are on (there they are text: data-nolink); a reason of
  // this page answers here (reasonLine)
  const self = (tab: string) => tab === ctx.tab ? { 'data-nolink': 'this page' } : null;
  const linkOr = (tab: string, attrs: Record<string, string>, ...kids: (string | HTMLElement)[]) => self(tab)
    ? el('span', { ...attrs, ...self(tab)! }, ...kids) : el('a', { ...attrs, href: href(ctx, { tab }) }, ...kids);
  const word = linkOr('findings', { class: `badge band-word ${b.cls}`, 'data-groups': [...(b.offline ? ['offline'] : []), ...b.items.map(i => i.key)].join(' ') }, b.word);
  if (b.reasons.length) word.title = b.reasons.join('\n');
  const header = el('section', { class: 'inst-header panel', 'aria-label': `${String(r.name)}: ${b.word}` },
    el('div', { class: 'inst-header-top' }, bandDot(b), ' ', linkOr('summary', { class: 'inst-name' }, String(r.name)), ' ', word,
      silencedMark(live) ?? '', el('span', { class: `meta status-line${fr === 'awaiting' ? ' awaiting' : ''}` }, linkOr('collectiondates', { class: 'cell-link' }, status)),
      el('span', { style: 'margin-left:auto' }, silenceButton(ad, r, live, redraw))),
    b.reasons.length ? reasonLine(ctx, b, r) : null,
    el('div', { class: `chips${fr === 'offline' ? ' stale' : ''}` }, ...chips.map(c => { const t = chipTab(c.key, isMssql(r.engine)); if (t && t === ctx.tab) { const d = chipEl(c); d.dataset.nolink = 'this page'; return d; } return chipEl(c, t ? href(ctx, { tab: t }) : undefined); })),
    // the verdict card on the instance's Summary (both engines): a reading of this band and freshness, never another;
    // a fault in it leaves the header standing (instanceFrame's caller drops the whole header on a throw)
    ctx.tab === 'summary' ? (() => { try { return verdictCard(ctx, verdict(r, live, now, b, fr), isMssql(r.engine)); } catch { return null; } })() : null);
  return { header, dot: bandDot(b) };
}
