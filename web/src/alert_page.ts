// The page of one alert (task 151, K07.02): #/alert?k=<finding key>[&t=<unix seconds>][&v=now|firing], the address
// every sent alert line carries (alerts_base_url in the configuration). It shows the alert's card (severity, instance,
// the finding now or the last value sent, its threshold or suggested value, this firing's first send, how many times
// it fired), the fix statement with Copy (pgvigil.finding_fix: none when the detail says what to do), every firing of
// the alert, every send attempt that carried it, and what people did with it (acknowledgements, notes, mutes,
// dismissals). The links to the instance's pages open pinned to the firing's window ('at the firing') or to the last
// hour ('now'); the export buttons keep the page as a workbook (the report). Data from /api/alerts?k= (q_alerts.go);
// the route is the shell's (a WIRING BLOCK: router.ts and main.ts).
// Task 177 D30 (PerformanceMonitor's triage notebook, its Alert History > Open): the evidence of the alert's family read
// and drawn on the page itself at the firing - how to read it, the family's metrics charted around the firing
// (/api/metrics/series, the Metrics page's samples) and the sessions or requests at the first send (/api/activity,
// /api/mssql/running); the links stay for the rest.
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, href, MAX_RANGE_MS } from './router';
import { badge, Col, copyText, el, errorBox, fmtTime, grid, props } from './ui';
import { lineChart } from './chart';
import { fmtMetric } from './alert_rules';
import { exportButtons } from './export';
import { loadAckSafe, AckData, offBeside, writeButton } from './ack';
import { whatIsThis } from './sqlview';

interface AlertPageData { card: Table | null; occurrences: Table | null; sends: Table | null; notes: Table | null }

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const statusBadge = (v: unknown) => badge(String(v ?? ''), v === 'open' ? 'crit' : v === 'resolved' ? 'ok' : '');
const list = (v: unknown): string => Array.isArray(v) && v.length ? v.join(', ') : '';

// hashParam: one parameter of the page's own address
function hashParam(name: string): string | null {
  return new URLSearchParams(location.hash.split('?')[1] ?? '').get(name);
}

// alertHref: the address of an alert's page (the same form the sender writes into a message); with ctx the page's
// time range and tag ride along, as on every link (router.ts)
export function alertHref(key: unknown, at?: unknown, ctx?: Ctx): string {
  const base = ctx ? href(ctx, { tab: 'alert', instance: undefined }) : '#/alert?';
  const q = new URLSearchParams(base.split('?')[1] ?? '');
  q.set('k', String(key ?? ''));
  const t = at == null ? NaN : Date.parse(String(at));
  if (Number.isFinite(t)) q.set('t', String(Math.floor(t / 1000)));
  return `#/alert?${q}`;
}

// firingWindow: half an hour before the firing to half an hour after it cleared (open: to now), at most the server's
// longest window (the end is kept: the clearance is what a reader looks for)
export function firingWindow(firedAt: unknown, clearedAt: unknown, now = Date.now()): { from: string; to: string } {
  const f = Date.parse(String(firedAt ?? '')), c = clearedAt == null ? NaN : Date.parse(String(clearedAt));
  const to = Math.min(now, Number.isFinite(c) ? c + 1800e3 : now);
  const from = Math.max((Number.isFinite(f) ? f : now - 3600e3) - 1800e3, to - MAX_RANGE_MS);
  return { from: new Date(from).toISOString(), to: new Date(Math.max(to, from + 60e3)).toISOString() };
}

// pick: the firing the address names (the one whose period holds t), else the newest
function pick(occ: Row[], t: number | null): Row | undefined {
  if (t != null) {
    const hit = occ.find(o => {
      const f = Date.parse(String(o.fired_at)), c = o.cleared_at == null ? Infinity : Date.parse(String(o.cleared_at));
      return f - 120e3 <= t && t <= c;
    });
    if (hit) return hit;
  }
  return occ[0];
}

// instanceLinks: the instance's pages that explain an alert, opened on the window chosen
function instanceLinks(ctx: Ctx, instanceId: number, engine: unknown, win: { from: string; to: string } | null, firedAt: unknown, source: unknown): HTMLElement {
  const range = win ? { from: win.from, to: win.to } : { preset: '1h' };
  const mk = (tab: string, label: string, over: Partial<Ctx> = {}) => el('a', { href: href(ctx, { tab, instance: instanceId, range, ...over }) }, label);
  const links: HTMLElement[] = [mk('summary', 'Summary'), mk('findings', 'Findings'), mk('counters', 'Metrics'), mk('performance', 'Performance')];
  if (engine === 'sqlserver') links.push(mk('mssql_running', 'Running queries'), mk('mssql_waits', 'Waits'), mk('mssql_blocked', 'Blocked reports'));
  else {
    // the running queries at the firing: the activity snapshot nearest the first send
    const at = win && firedAt != null ? { at: new Date(Date.parse(String(firedAt))).toISOString() } : {};
    links.push(mk('activity', 'Running queries', at), mk('waits', 'Waits'), mk('logs', 'Logs'));
    if (String(source ?? '').includes('vacuum') || String(source ?? '') === 'pg_gather') links.push(mk('vacuum', 'Vacuum'), mk('config', 'Configuration'));
  }
  const out = el('p', { class: 'meta' }, win ? 'The instance at the firing: ' : 'The instance now: ');
  links.forEach((a, i) => { if (i) out.append(' · '); out.append(a); });
  return out;
}

// ---- the evidence per alert family --------------------------------------------------------------------------------
// family: the reads that explain an alert of one kind (PerformanceMonitor opens an alert on a triage page per family):
// what to look at first, the metrics to chart around the firing per engine (metric_catalog keys with their label and
// unit), and the live read at the first send. The family is found by whole words of the alert's setting (a check's name),
// then of its source; a setting that is a parameter's name (pg_gather's and the setting rules': 'lock_timeout',
// 'autovacuum_max_workers') is a configuration finding, explained by the instance's load (The instance); an alert
// rule's alert charts the rule's own metric first.
interface Family { name: string; read: string; pg: [string, string, string][]; ms: [string, string, string][] }
const families: { test: RegExp; f: Family }[] = [
  { test: /\b(vacuum|autovacuum|xid|wraparound|dead tuples?|bloat|xmin|freeze)\b/i, f: { name: 'Vacuum',
    read: 'Vacuum falls behind when an old snapshot (a long transaction, an idle-in-transaction session, a replication slot) holds back the xmin horizon, or when autovacuum is off or slowed for the table. The oldest xmin age climbing with a long idle transaction names the holder.',
    pg: [['sessions.oldest_xmin_age', 'oldest xmin age', 'xids'], ['sessions.longest_idle_txn_secs', 'longest idle in transaction', 'secs'], ['sessions.longest_active_secs', 'longest active statement', 'secs']],
    ms: [['requests.requests', 'requests running', 'count']] } },
  { test: /\b(block(ed|ing|er|s)?|locks?|locked|deadlocks?|chains?)\b/i, f: { name: 'Blocking',
    read: 'A blocked session waits for one that holds a lock. The charts show how many waited around the firing; the grid lists the sessions at the first send, the blockers first. The cause is the blocking head\'s transaction and its last statement, never the object the others wait on: find the session nobody blocks that others wait for, and read what its transaction did.',
    pg: [['sessions.waiting_lock', 'waiting on a lock', 'count'], ['sessions.active', 'active sessions', 'count'], ['sessions.longest_idle_txn_secs', 'longest idle in transaction', 'secs']],
    ms: [['requests.blocked', 'processes blocked', 'count'], ['requests.heads', 'blocking chain heads', 'count'], ['requests.longest_wait_ms', 'longest wait', 'ms']] } },
  { test: /\b(replica(tion)?|replay|lag|slots?|wal|standby|availability group|ag|hadr|mirroring)\b/i, f: { name: 'Replication',
    read: 'Replication lag grows when the primary writes faster than a standby replays, or when a standby or a slot stops. The write rate around the firing tells a burst from a stop.',
    pg: [['server.wal_bytes_s', 'WAL bytes written', 'bytes_per_s'], ['sessions.active', 'active sessions', 'count']],
    ms: [['scheduler.transactions_s', 'transactions', 'per_s'], ['scheduler.pending_io', 'pending disk IO', 'count']] } },
  { test: /\b(cpu|schedulers?|runnable|workers?)\b/i, f: { name: 'CPU',
    read: 'CPU pressure shows as the instance\'s own share against the host\'s, and as tasks waiting for a scheduler. A rise that follows one statement points at that statement (the grid at the first send); a rise of every session together points at the load.',
    pg: [['host.cpu_pct', 'host CPU', 'pct'], ['host.cpu_iowait_pct', 'CPU in IO wait', 'pct'], ['sessions.active', 'active sessions', 'count']],
    ms: [['cpu.sql_pct', 'SQL Server CPU', 'pct'], ['cpu.total_pct', 'machine CPU', 'pct'], ['scheduler.runnable_tasks', 'runnable tasks', 'count']] } },
  { test: /\b(memory|grants?|ple|page life|swap|buffer pool)\b/i, f: { name: 'Memory',
    read: 'Memory pressure shows as grants waiting and a falling page life expectancy (SQL Server), or the host\'s used memory and swap (PostgreSQL). A grant queue that empties when one query ends names that query.',
    pg: [['host.mem_used_pct', 'host memory used', 'pct'], ['host.swap_used', 'swap used', 'bytes'], ['sessions.active', 'active sessions', 'count']],
    ms: [['memory.grants_pending', 'memory grants pending', 'count'], ['memory.ple', 'page life expectancy', 'secs'], ['memory.available_mb', 'memory available', 'mb']] } },
  { test: /\b(connections?|idle in transaction|too many clients)\b/i, f: { name: 'Connections',
    read: 'A connection alert is about how many sessions are open and what they do. Idle-in-transaction sessions hold locks and old snapshots; a pool that grows without work points at the application.',
    pg: [['sessions.connections_pct', 'connections used', 'pct'], ['sessions.idle_in_txn', 'idle in transaction', 'count'], ['sessions.total', 'sessions', 'count']],
    ms: [['requests.sessions', 'sessions', 'count'], ['requests.requests', 'requests running', 'count'], ['scheduler.active_workers', 'active workers', 'count']] } },
  { test: /\b(io|disk|storage|space|tempdb|files?|drives?|volumes?|growth|free)\b/i, f: { name: 'Storage and IO',
    read: 'A space alert is about what fills the volume and how fast; an IO alert about who waits on the disk. The charts show the IO wait around the firing; the Storage and Files pages hold the sizes.',
    pg: [['host.cpu_iowait_pct', 'CPU in IO wait', 'pct'], ['server.buffers_written_s', 'buffers written', 'per_s']],
    ms: [['scheduler.pending_io', 'pending disk IO', 'count'], ['memory.available_mb', 'memory available', 'mb']] } },
];
const anyFamily: Family = { name: 'The instance',
  read: 'The instance around the firing: its load and its sessions at the first send. The finding\'s detail above says what was judged; the links open the pages that hold the rest.',
  pg: [['sessions.active', 'active sessions', 'count'], ['host.cpu_pct', 'host CPU', 'pct']],
  ms: [['requests.requests', 'requests running', 'count'], ['cpu.total_pct', 'machine CPU', 'pct']] };
export function familyOf(source: unknown, setting: unknown): Family {
  const set = String(setting ?? ''), src = String(source ?? '').replace(/[_-]/g, ' ');   // 'mssql_hadr': its words
  if (/^[a-z][a-z0-9]*(_[a-z0-9]+)+$/.test(set)) return anyFamily;   // a parameter's name: a configuration finding
  return families.find(x => x.test.test(set))?.f ?? families.find(x => x.test.test(src))?.f ?? anyFamily;
}

// the live read's columns per engine, in this order (the read's own row order kept: blockers first)
const pgCols = ['pid', 'state', 'wait_event_type', 'wait_event', 'blocking_pids', 'is_blocker', 'xact_secs', 'query_secs', 'usename', 'application_name', 'query'];
const msCols = ['session_id', 'blocking_session_id', 'head_session_id', 'status', 'wait_type', 'wait_ms', 'elapsed_ms', 'login_name', 'program_name', 'statement'];
// liveGrid: a read's rows as a grid of the engine's columns (the ones the read has), the statement wide; a PostgreSQL
// read's working sessions before its idle ones; at most 20 rows, the rest said
function liveGrid(rows: Row[], keys: string[], empty: string, idleLast: boolean): HTMLElement {
  if (idleLast) rows = [...rows.filter(r => r.state !== 'idle'), ...rows.filter(r => r.state === 'idle')];
  const have = keys.filter(k => rows.some(r => k in r));
  const cols: Col[] = have.map(k => ({ key: k, ...(/query|statement/.test(k) ? { wide: true } : {}) }));
  const g = grid(rows.slice(0, 20), cols, empty);
  return rows.length > 20 ? el('div', {}, g, el('p', { class: 'meta' }, `${rows.length - 20} more not shown: the instance's running queries page at that time holds them all.`)) : g;
}

let catalogKeys: Map<string, [string, string]> | null = null;   // 'family_label: label' -> [key, unit] (an alert rule's metric)
async function ruleMetric(setting: unknown): Promise<[string, string, string] | null> {
  if (!catalogKeys) {
    const d = await get<{ catalog: Table | null }>('alertrules', { part: 'catalog' });
    catalogKeys = new Map(rowsOf(d.catalog).map(c => [`${String(c.family_label)}: ${String(c.label)}`, [String(c.key), String(c.unit)] as [string, string]]));
  }
  const hit = catalogKeys.get(String(setting ?? ''));
  return hit ? [hit[0], String(setting), hit[1]] : null;
}

// evidence: the family's section of the page: how to read it, its charts over the window, the live read at the firing
// (with the read's own time and its distance from the first send) or, for an alert not sent yet, now
function evidence(instanceId: number, engine: unknown, win: { from: string; to: string } | null, firedAt: unknown, source: unknown, setting: unknown): HTMLElement {
  const rule = String(source ?? '') === 'alert rule';
  const f = rule ? { ...anyFamily, name: 'Alert rule', read: 'An alert rule judges one metric against its warning and critical values: its chart is first, with the instance\'s load and its sessions beside it.' } : familyOf(source, setting);
  const ms = engine === 'sqlserver';
  const range = win ?? { from: new Date(Date.now() - 3600e3).toISOString(), to: new Date().toISOString() };
  const when = win ? 'around the firing' : 'the last hour';
  const charts = el('div', { class: 'charts' });
  const live = el('div', {}, el('p', { class: 'meta' }, 'Reading the instance...'));
  const box = el('section', { class: 'evidence', 'aria-label': `Evidence: ${f.name}` },
    el('h3', {}, `Evidence: ${f.name} `, whatIsThis('The reads that explain an alert of this kind, made on this page: what to look at first, the family\'s metrics charted over the window (from half an hour before the first send to half an hour after the clear; the last hour for an alert not sent yet), and the sessions or requests the instance ran at the first send.', 'Evidence')),
    el('p', { class: 'how-to-read' }, f.read), charts, live);
  const chart = (key: string, label: string, unit: string) => {
    const holder = el('div', {}, el('h3', {}, label));
    charts.append(holder);
    void get<{ series: Table | null; step_secs?: number }>('metrics/series', { instance: instanceId, metric: key, from: range.from, to: range.to })
      .then(s => {
        // a window bucketed by the server (over about 20 hours) draws each bucket's average, highest and lowest
        const bucketed = Number(s.step_secs ?? 0) > 1;
        const series = bucketed ? [{ key: 'value', label: `${label} (average per ${Math.round(Number(s.step_secs) / 60)} min)` }, { key: 'max_value', label: 'highest' }, { key: 'min_value', label: 'lowest' }] : [{ key: 'value', label }];
        holder.replaceChildren(lineChart(`${label} (${when})`, rowsOf(s.series), series, v => fmtMetric(v, unit)));
      })
      .catch((e: unknown) => holder.replaceChildren(el('h3', {}, label), errorBox(e)));
  };
  void (rule ? ruleMetric(setting).catch(() => null) : Promise.resolve(null)).then(own => {
    for (const [key, label, unit] of [...(own ? [own] : []), ...(ms ? f.ms : f.pg)]) chart(key, label, unit);
  });
  const at = firedAt != null && win ? new Date(Date.parse(String(firedAt))).toISOString() : undefined;
  const title = el('h3', {}, `${ms ? 'Requests' : 'Sessions'} ${at ? 'at the first send' : 'now (not sent yet)'}`);
  const said = (snap: unknown) => {
    if (snap == null) return el('p', { class: 'meta' }, ms ? 'No request in the snapshot read (or no snapshot near enough).' : 'No snapshot was read.');
    const gap = at ? Math.round((Date.parse(at) - Date.parse(String(snap))) / 60000) : 0;
    return el('p', { class: 'meta' }, `The snapshot of ${fmtTime(snap)}` + (at ? (Math.abs(gap) > 15 ? `, ${gap} minutes before the first send: the activity collection read nothing nearer (the snapshot may say little of the firing).` : `, ${gap} minute(s) before the first send.`) : '.'));
  };
  (ms
    ? get<{ rows: Table | null }>('mssql/running', { instance: instanceId, at }).then(d => { const rows = rowsOf(d.rows); return el('div', {}, said(rows[0]?.snapshot_at), liveGrid(rows, msCols, 'No request was running in that snapshot.', false)); })
    : get<{ sessions: Table | null; snapshot_at?: unknown }>('activity', { instance: instanceId, at }).then(d => el('div', {}, said(d.snapshot_at), liveGrid(rowsOf(d.sessions), pgCols, 'No session in that snapshot.', true))))
    .then(g => live.replaceChildren(title, g))
    .catch((e: unknown) => live.replaceChildren(title, errorBox(e)));
  return box;
}

// fixLine: the statement with its Copy button; a setting's note on reload and restart
function fixLine(fix: unknown): HTMLElement {
  const text = String(fix ?? '');
  const said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const copy = el('button', { type: 'button', 'aria-label': 'Copy the fix statement' }, 'Copy');
  copy.addEventListener('click', async () => { said.textContent = (await copyText(text)) ? ' Copied.' : ' The browser refused the copy: select the text instead.'; });
  const box = el('div', { class: 'fix-line' }, el('h3', {}, 'Fix'),
    el('pre', { class: 'sql', style: 'white-space:pre-wrap;margin:.2rem 0' }, el('code', {}, text)), copy, said);
  if (text.startsWith('ALTER SYSTEM')) box.append(el('p', { class: 'meta' }, 'Run it as a superuser (on Aurora / RDS the parameter group holds the setting instead). A setting whose pg_settings.context is postmaster takes a restart besides the reload. pgvigil runs nothing: the statement is advice.'));
  else box.append(el('p', { class: 'meta' }, 'pgvigil runs nothing: the statement is advice, read it before you run it.'));
  return box;
}

// alertPageView: the page
export async function alertPageView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { class: 'alert-page' });
  const key = hashParam('k') ?? '';
  if (!/^[0-9a-f]{32}$/.test(key)) {
    sec.append(el('h2', {}, 'Alert'), el('p', {}, 'This address names no alert: it is opened from a sent alert\'s link or from a row of the Alerts page.'),
      el('p', {}, el('a', { href: href(ctx, { tab: 'alerts', instance: undefined }) }, 'Alerts')));
    return sec;
  }
  const tq = Number(hashParam('t'));
  const t = Number.isFinite(tq) && tq > 0 ? tq * 1000 : null;
  let d: AlertPageData;
  try { d = await get<AlertPageData>('alerts', { k: key }); } catch (e) { sec.append(el('h2', {}, 'Alert'), errorBox(e)); return sec; }
  const card = rowsOf(d.card)[0], occ = rowsOf(d.occurrences), sends = rowsOf(d.sends), notes = rowsOf(d.notes);
  const o = pick(occ, t);
  if (!o && !card) {
    sec.append(el('h2', {}, 'Alert'), el('p', {}, 'No alert with this key is in the store: it was never sent, or its rows were purged (the purge window). The finding itself is not standing now either.'),
      el('p', {}, el('a', { href: href(ctx, { tab: 'alerts', instance: undefined }) }, 'Alerts')));
    return sec;
  }
  const head = o ?? card!;
  const instanceId = Number(head.instance_id) || 0;
  const name = [head.source, head.setting].filter(x => x != null && x !== '').map(String).join(': ');
  sec.append(el('h2', {}, `Alert - ${name}`),
    el('p', { class: 'meta' }, `${String(head.instance ?? '')}${o ? `, fired ${fmtTime(o.fired_at)}` : ', not sent yet'}. `,
      whatIsThis('One alert: a finding the sender sent on one or more channels. Its firings are grouped over the channels (a firing ends when every channel\'s alert of it has cleared). The value is the finding\'s now when it still stands, else the last value sent. The links open the instance pinned to the firing\'s window, or to the last hour with the now switch. Export keeps the page as a workbook.', 'Alert page')));

  // the now / at-firing switch: where the links point (the address keeps it: v=now)
  let view: 'firing' | 'now' = hashParam('v') === 'now' || !o ? 'now' : 'firing';
  const linksBox = el('div', {});
  const seg = el('div', { class: 'seg', role: 'group', 'aria-label': 'Read the instance at' });
  const bFiring = el('button', { type: 'button', class: 'toggle' }, 'at the firing'), bNow = el('button', { type: 'button', class: 'toggle' }, 'now');
  seg.append(bFiring, bNow);
  // an alert that was never sent has no firing to read the instance at: off, with that reason after the pair
  if (!o) {
    const why = 'no firing of this alert is in the store (not sent yet, or its rows purged): there is no firing to read at';
    const said = el('span', { class: 'off-reason' }, why);
    offBeside(bFiring, why, said);
    seg.append(' ', said);
  }
  const win = o ? firingWindow(o.fired_at, o.cleared_at) : null;
  const drawLinks = () => {
    bFiring.setAttribute('aria-pressed', String(view === 'firing')); bNow.setAttribute('aria-pressed', String(view === 'now'));
    linksBox.replaceChildren(instanceId ? instanceLinks(ctx, instanceId, head.engine ?? card?.engine, view === 'firing' ? win : null, o?.fired_at, head.source)
      : el('p', { class: 'meta' }, 'The instance is no longer in the repository.'));
  };
  // the view rides in the address (v=now), so a range change, a reload and Copy link keep it
  const keepView = () => {
    const [path, qs] = location.hash.split('?');
    const q = new URLSearchParams(qs ?? '');
    if (view === 'now') q.set('v', 'now'); else q.delete('v');
    history.replaceState(null, '', `${path}?${q}`);
  };
  bFiring.addEventListener('click', () => { view = 'firing'; keepView(); drawLinks(); });
  bNow.addEventListener('click', () => { view = 'now'; keepView(); drawLinks(); });
  drawLinks();

  const door = await loadAckSafe(['log'], {});
  const dismissed = notes.find(n => n.kind === 'dismiss' && n.ended_at == null);
  const pairs: [string, string | Node][] = [
    ['Severity', sevBadge(card?.severity ?? head.severity)],
    ['Instance', instanceId ? el('a', { href: href(ctx, { tab: 'summary', instance: instanceId, range: win ? { from: win.from, to: win.to } : { preset: '1h' } }) }, String(head.instance ?? '')) : String(head.instance ?? '')],
    ['Alert', name],
    ['Value', card ? `${String(card.value ?? '')} (now)` : `${String(o?.value ?? '')} (last sent; the finding is gone now)`],
    ['Threshold', String(card?.threshold ?? o?.threshold ?? '') || 'none stated (a built-in check: its rule is in the detail)'],
    ['This firing', o ? `first sent ${fmtTime(o.fired_at)}, last sent ${fmtTime(o.last_sent_at)}, ${String(o.sends)} send(s) to ${list(o.channels)}` : 'not sent'],
    ['State', o ? el('span', {}, statusBadge(o.status), ' ', o.cleared_at != null ? `cleared ${fmtTime(o.cleared_at)}` : o.missing_since != null ? `the finding is gone since ${fmtTime(o.missing_since)} (waiting for the clear delay and a fresh read)` : 'standing') : 'not sent'],
    ['Firings', `${occ.length} in the store` + (occ.length > 1 ? `, the first ${fmtTime(occ[occ.length - 1].fired_at)}` : '')],
  ];
  if (card?.detail) pairs.push(['Detail', String(card.detail)]);
  if (card?.suggested) pairs.push(['Suggested', String(card.suggested)]);
  if (dismissed) pairs.push(['Dismissed', `by ${String(dismissed.by)} ${fmtTime(dismissed.at)}: ${String(dismissed.note ?? '')}`]);
  sec.append(el('div', { class: 'toolbar' }, seg, el('span', { class: 'meta' }, ' '), exportButtons(ctx, () => sec), copyLinkButton()), linksBox, props(pairs));
  const engine = head.engine ?? card?.engine;
  if (instanceId && engine != null) sec.append(evidence(instanceId, engine, win, o?.fired_at, head.source, head.setting));
  else if (instanceId) sec.append(el('p', { class: 'meta' }, 'No evidence drawn: the instance is no longer in the repository (its reads went with it).'));
  if (card?.fix) sec.append(fixLine(card.fix));
  else if (card) sec.append(el('p', { class: 'meta' }, 'No fix statement: the detail says what to do (a fix statement is given for a PostgreSQL setting with a one-word suggested value, and for a maintenance statement the detail spells out).'));
  sec.append(dismissBar(door, key, dismissed, instanceId || null, String(head.instance ?? '') || undefined));

  const occCols: Col[] = [
    { key: 'fired_at', label: 'fired', fmt: (v, r) => el('a', { href: alertHref(key, v, ctx), title: `firing ${String(r.occurrence)}` }, fmtTime(v)) },
    { key: 'cleared_at', label: 'cleared', fmt: fmtTime },
    { key: 'status', fmt: statusBadge },
    { key: 'severity', fmt: sevBadge },
    { key: 'value', wide: true },
    { key: 'threshold' },
    { key: 'channels', fmt: v => list(v) },
    { key: 'sends', num: true },
    { key: '_window', label: 'instance', fmt: (_v, r) => instanceId ? el('a', { href: href(ctx, { tab: 'summary', instance: instanceId, range: firingWindow(r.fired_at, r.cleared_at) }) }, 'open its window') : '' },
  ];
  sec.append(el('h3', {}, 'Firings of this alert'), grid(occ, occCols, 'Not sent yet: the finding stands, and no channel has sent it.'));
  const sendCols: Col[] = [
    { key: 'at', label: 'attempt', fmt: fmtTime },
    { key: 'channel' },
    { key: 'kind' },
    { key: 'destination', wide: true },
    { key: 'outcome', fmt: v => badge(String(v ?? ''), v === 'sent' ? 'ok' : v === 'failed' || v === 'refused' ? 'crit' : v === 'capped' ? 'warn' : '') },
    { key: 'n_firing', label: 'new', num: true },
    { key: 'n_repeat', label: 'repeated', num: true },
    { key: 'n_resolved', label: 'resolved', num: true },
    { key: 'error', wide: true },
  ];
  sec.append(el('h3', {}, 'Every send that carried it'), grid(sends, sendCols, 'No send attempt carried this alert.'));
  const noteCols: Col[] = [
    { key: 'at', label: 'when', fmt: fmtTime },
    { key: 'kind', fmt: v => ({ alert_ack: 'acknowledged', note: 'note', close: 'closed', mute: 'muted', noise: 'known pattern', dismiss: 'dismissed' } as Record<string, string>)[String(v)] ?? String(v ?? '') },
    { key: 'by' },
    { key: 'note', wide: true },
    { key: 'until', fmt: v => v == null ? '' : fmtTime(v) },
    { key: 'ended_at', label: 'ended', fmt: (v, r) => v == null ? (r.paused_at != null ? `paused ${fmtTime(r.paused_at)}` : '') : `${fmtTime(v)} by ${String(r.ended_by ?? '')}` },
  ];
  sec.append(el('h3', {}, 'What was done with it'), grid(notes, noteCols, 'Nobody acknowledged, noted, muted or dismissed this alert.'));
  return sec;
}

function copyLinkButton(): HTMLElement {
  const said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const b = el('button', { type: 'button', title: 'Copy the address of this page' }, 'Copy link');
  b.addEventListener('click', async () => { said.textContent = (await copyText(location.href)) ? ' Link copied.' : ' The browser refused the copy.'; });
  return el('span', {}, b, said);
}

// dismissBar: dismiss the alert with a reason, or end its dismissal
function dismissBar(door: AckData, key: string, dismissed: Row | undefined, instanceId: number | null, name?: string): HTMLElement {
  const redraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
  const said = el('span', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const bar = el('div', { class: 'seg' });
  // by the alert's own instance: on a demo serve the door writes for the demo's instances and for no other
  if (dismissed) bar.append(writeButton(door, 'Undismiss', 'Undismiss this alert', () => { void dismissEnd(key, said, redraw); }, { instance: instanceId, name }));
  else bar.append(writeButton(door, 'Dismiss', 'Dismiss this alert with a reason', () => dismissDialog([key], redraw), { instance: instanceId, name }));
  return el('div', {}, bar, said);
}

// dismissEnd: the dismissal of the alert ended, every outcome said beside the button
async function dismissEnd(key: string, said: HTMLElement, after: () => void) {
  let row: Row | undefined;
  try {
    const d = await get<{ dismissed: Table | null }>('alerts', { part: 'dismissed' });
    row = rowsOf(d.dismissed).find(r => r.finding_key === key && r.live);
  } catch (e) { said.textContent = ' Not ended: the dismissals could not be read: ' + (e instanceof Error ? e.message : String(e)); return; }
  if (!row) { said.textContent = ' This alert is no longer dismissed (someone ended it): the page is read again.'; window.setTimeout(after, 1500); return; }
  if (!window.confirm('Undismiss this alert? It shows on the open-alerts grid again; the dismissal stays in the store with who ended it.')) return;
  try { await post('alerts/dismiss', { op: 'end', dismiss_id: Number(row.dismiss_id) }); } catch (e) { said.textContent = ' Not ended: ' + (e instanceof Error ? e.message : String(e)); return; }
  after();
}

// the reasons offered first (any text is taken)
export const dismissReasons = ['tolerable for this server', 'controlled elsewhere (a policy, another tool)', 'a known pattern of this system', 'a test or lab instance'];

// dismissDialog: one reason for the alerts named; one post each, the answer in place
export function dismissDialog(keys: string[], after: () => void) {
  const opener = document.activeElement instanceof HTMLElement ? document.activeElement : null;
  const sel = el('select', { 'aria-label': 'reason' }, ...dismissReasons.map(r => el('option', { value: r }, r)), el('option', { value: '' }, 'another reason ...'));
  const other = el('input', { type: 'text', maxlength: '500', 'aria-label': 'another reason', style: 'width:100%' });
  const ok = el('button', { type: 'submit' }, 'Dismiss'), no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  // a typed reason wins over the list's pick: the text box is always there to be typed in
  const reason = () => (other.value.trim() || sel.value).trim();
  const check = () => { ok.disabled = reason() === ''; };
  sel.addEventListener('change', check); other.addEventListener('input', check);
  const form = el('form', { method: 'dialog' }, el('h3', {}, `Dismiss ${keys.length} alert(s)`),
    el('p', {}, 'A dismissed alert leaves the open-alerts grid (Show dismissed brings it back) and keeps its reason, who and when. It changes what the grid shows, not what is sent: a mute or an acknowledgement holds the sends.'),
    el('label', {}, 'Reason ', sel), el('div', { style: 'margin:.3rem 0' }, other), msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': 'Dismiss alerts' }, form);
  let done = false;
  const leave = () => { dlg.remove(); if (done) after(); else if (opener?.isConnected) opener.focus(); };
  no.addEventListener('click', () => { dlg.close(); leave(); });
  dlg.addEventListener('cancel', leave);
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (done) return;
    ok.disabled = true; msg.textContent = 'Saving...';
    let n = 0;
    const refused: string[] = [];
    for (const k of keys) {
      try { await post('alerts/dismiss', { op: 'add', finding_key: k, reason: reason() }); n++; } catch (e) { refused.push(e instanceof Error ? e.message : String(e)); }
    }
    done = n > 0;
    msg.replaceChildren(badge(refused.length ? (n ? 'partly done' : 'not saved') : 'done', refused.length ? 'warn' : 'ok'), ` ${n} of ${keys.length} dismissed` + (refused.length ? `; refused: ${refused.join('; ')}` : ''));
    no.textContent = 'Close';
    if (!done) ok.disabled = false;
  });
  check();
  document.body.append(dlg);
  dlg.showModal();
  sel.focus();
}
