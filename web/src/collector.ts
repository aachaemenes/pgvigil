// The Collector page (task 201; PerformanceMonitor's Collection Health learned from, pgvigil's own page): is `pgvigil run`
// up, and is it collecting into the repository? The service (each run of a collector seen in the last 8 days: up,
// stopped, not seen; many collectors may share a repository, one per host; serve's watchdog on or off), the findings, each collection's runs over 24 h (failures, p50 / p95 duration,
// rows written, the read-to-store lag) and a chart of the runs per minute, the collections failing now, pgvigil's own
// load on each monitored server (connections opened and attempted per minute, logins refused), and the repository (size,
// growth per day, rows written per minute, the largest tables, its connections, the purges). collectorLine is the
// line an instance's Collection dates page shows. Data from GET /api/collector.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { href } from './router';
import { lineChart } from './chart';
import { tileRow } from './tiles';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, panel, stateNote, tile } from './ui';

type Parts = Record<string, Table | null>;

const stateWord: Record<string, string> = { up: 'Up', stopped: 'Stopped', ended: 'Ended', 'not seen': 'Not seen' };
const stateKind: Record<string, string> = { up: 'ok', stopped: 'warn', ended: '', 'not seen': 'crit' };
const sevKind: Record<string, string> = { critical: 'crit', warning: 'warn', info: '' };
const sevWord: Record<string, string> = { critical: 'Critical', warning: 'Warning', info: 'Info' };

// the service's state in words: the collectors up (one per host), or how long the newest has not been seen
function serviceState(rows: Row[]): { word: string; kind: string; sub: string } {
  const live = rows.filter(r => r.state === 'up');
  if (live.length > 1) return { word: `${live.length} up`, kind: 'ok', sub: live.map(r => String(r.host)).join(', ') };
  if (live.length === 1) return { word: 'Up', kind: 'ok', sub: `beat ${fmtSecs(live[0].beat_age_secs)} ago` };
  const last = rows.reduce<Row | undefined>((a, r) => a == null || String(r.beat_at) > String(a.beat_at) ? r : a, undefined);   // the newest run
  if (!last) return { word: 'Never seen', kind: 'crit', sub: 'no collector has beaten on this repository' };
  if (last.state === 'stopped') return { word: 'Stopped', kind: 'crit', sub: `stopped ${fmtTime(last.stopped_at)}` };
  return { word: `Not seen for ${fmtSecs(last.beat_age_secs)}`, kind: 'crit', sub: `the last beat ${fmtTime(last.beat_at)}` };
}

const instLink = (ctx: Ctx, r: Row) => r.instance_id == null ? el('span', {}, String(r.instance ?? 'the repository'))
  : el('a', { href: href(ctx, { tab: 'collectiondates', instance: Number(r.instance_id), tag: undefined }) }, String(r.instance ?? ''));

export async function collectorView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', { class: 'collector' }, el('h2', {}, 'Collector'));
  let d: Parts;
  try { d = await get<Parts>('collector'); } catch (e) { sec.append(errorBox(e)); return sec; }
  const collectors = rowsOf(d.collectors), findings = rowsOf(d.findings), colls = rowsOf(d.collections), minutes = rowsOf(d.minutes);
  const load = rowsOf(d.load), streaks = rowsOf(d.streaks), tables = rowsOf(d.tables);
  const repo: Row = rowsOf(d.repository)[0] ?? {};
  const conns = rowsOf(d.connections), purges = rowsOf(d.purges);
  const st = serviceState(collectors), me = collectors.find(r => r.state === 'up') ?? collectors[0];
  const wd = String(rowsOf(d.watchdog)[0]?.watchdog ?? '');
  const wdTile = wd === 'on' ? tile('Watchdog', 'On', '', { sub: 'serve sends the alert while a collector is down' })
    : wd ? tile('Watchdog', 'Off', 'warn', { sub: wd.replace(/^off: /, '') }) : tile('Watchdog', '-', '', { sub: 'not this process' });

  // the service
  const svc = panel('Service', 'pgvigil run, now',
    tileRow('The collector service',
      tile('State', st.word, st.kind, { sub: st.sub, pill: st.kind === 'ok' ? false : undefined }),
      tile('Host', String(me?.host ?? '-'), '', { sub: me ? `${me.runs_as}, ${me.os}` : undefined }),
      tile('Version', String(me?.version ?? '-'), '', { sub: me ? `pid ${me.pid}` : undefined }),
      tile('Started', me ? fmtTime(me.started_at) : '-', '', { sub: me?.state === 'up' ? `up ${fmtSecs((Date.now() - Date.parse(String(me.started_at))) / 1000)}` : undefined }),
      tile('Memory', me?.mem_bytes == null ? '-' : fmtBytes(me.mem_bytes), '', { sub: me?.goroutines == null ? undefined : `${fmtNum(me.goroutines)} goroutines` }),
      tile('Instances', me?.instances == null ? '-' : fmtNum(me.instances), '', { sub: 'ran a collection in the last minute' }),
      wdTile),
    grid(collectors, [
      { key: 'state', fmt: v => badge(stateWord[String(v)] ?? String(v), stateKind[String(v)] ?? '') },
      { key: 'host' }, { key: 'runs_as', label: 'runs as' }, { key: 'os', label: 'OS' }, { key: 'version' }, { key: 'pid', num: true },
      { key: 'started_at', label: 'started', fmt: fmtTime }, { key: 'beat_at', label: 'last beat', fmt: fmtTime },
      { key: 'beat_age_secs', label: 'beat age', num: true, fmt: v => v == null ? '' : fmtSecs(v) },
      { key: 'stopped_at', label: 'stopped', fmt: fmtTime },
      { key: 'mem_bytes', label: 'memory', num: true, fmt: v => v == null ? '' : fmtBytes(v) },
      { key: 'goroutines', num: true, fmt: fmtNum }, { key: 'repo_conns', label: 'repository sessions', num: true, fmt: fmtNum },
    ] as Col[], 'No collector has beaten on this repository in the last 8 days: is pgvigil run started (the service, or a console)?'));

  // the collector's findings
  const find = panel('Findings', 'the collector and the repository, now',
    findings.length ? grid(findings, [
      { key: 'severity', fmt: v => badge(sevWord[String(v)] ?? String(v), sevKind[String(v)] ?? '') },
      { key: 'instance', fmt: (_v, r) => instLink(ctx, r) }, { key: 'setting', label: 'check' }, { key: 'value' },
      { key: 'detail', wide: true }, { key: 'at', label: 'since', fmt: fmtTime },
    ] as Col[]) : stateNote('empty', 'No finding: the collector beats, no collection fails three runs in a row, no login is refused, purge ran in the last 2 days.'));

  // the collections over 24 h
  const sum = (k: string) => colls.reduce((a, r) => a + Number(r[k] ?? 0), 0);
  const runs = sum('runs'), fails = sum('failures');
  const worst = colls.reduce<Row | null>((a, r) => r.p95_ms != null && (a == null || Number(r.p95_ms) > Number(a.p95_ms)) ? r : a, null);
  const failing = streaks.filter(r => Number(r.fail_streak) >= 3).length;
  const runsPanel = panel('Collections', 'last 24 h',
    tileRow('The collections over 24 hours',
      tile('Runs', fmtNum(runs)),
      tile('Failures', fmtNum(fails), fails ? 'warn' : '', { sub: runs ? `${(100 * fails / runs).toFixed(1)} % of runs` : undefined }),
      tile('Rows written', fmtNum(sum('rows_written'))),
      tile('Slowest p95', worst ? fmtNum(worst.p95_ms) : '-', '', { unit: worst ? 'ms' : undefined, sub: worst ? String(worst.collection) : undefined }),
      tile('Failing now', fmtNum(failing), failing ? 'crit' : '', { sub: 'three runs in a row or more' })),
    minutes.length >= 2
      ? lineChart('Runs and failures per minute', minutes,
          [{ key: 'runs', label: 'runs' }, { key: 'failures', label: 'failures' }, { key: 'rows_written', label: 'rows written' }],
          v => v.toLocaleString(), { ownSpan: true, marks: false, y2: { keys: ['rows_written'], unit: 'rows' } })
      : stateNote('empty', 'No minute of runs in the last 24 hours: the collector has not beaten, or it is new (a beat a minute).'),
    grid(colls, [
      { key: 'collection' }, { key: 'engine' },
      { key: 'runs', num: true, fmt: fmtNum }, { key: 'failures', num: true, fmt: fmtNum },
      { key: 'failure_pct', label: 'failure %', num: true, fmt: v => v == null ? '' : `${v}` },
      { key: 'avg_ms', label: 'avg (ms)', num: true, fmt: fmtNum }, { key: 'p50_ms', label: 'p50 (ms)', num: true, fmt: fmtNum },
      { key: 'p95_ms', label: 'p95 (ms)', num: true, fmt: fmtNum }, { key: 'max_ms', label: 'max (ms)', num: true, fmt: fmtNum },
      { key: 'rows_written', label: 'rows written', num: true, fmt: fmtNum },
      { key: 'lag_secs', label: 'newest read', num: true, fmt: v => v == null ? '' : `${fmtSecs(v)} ago` },
      { key: 'oldest_lag_secs', label: 'oldest instance\'s newest read', num: true, fmt: v => v == null ? '' : `${fmtSecs(v)} ago` },
      { key: 'last_minute', label: 'last run', fmt: fmtTime },
    ] as Col[], 'No collection ran in the last 24 hours.'),
    el('p', { class: 'meta' }, 'p50 and p95 come from each minute\'s duration histogram (powers of two in ms): an estimate within its bucket. '
      + 'Newest read: now against the newest row stored by the collection on any instance; the oldest instance\'s newest read is the instance furthest behind.'));

  const failPanel = panel('Failing now', 'failed runs in a row, per instance and collection',
    streaks.length ? grid(streaks, [
      { key: 'instance', fmt: (_v, r) => instLink(ctx, r) }, { key: 'collection' },
      { key: 'fail_streak', label: 'failed in a row', num: true, fmt: fmtNum },
      { key: 'failing_since', label: 'since', fmt: fmtTime }, { key: 'last_run_at', label: 'last run', fmt: fmtTime },
      { key: 'last_error', label: 'error', wide: true },
    ] as Col[]) : stateNote('empty', 'No collection is failing now.'));

  // pgvigil's own load on the monitored servers
  const authed = load.filter(r => Number(r.auth_failures_24h ?? 0) > 0).length;
  const loadPanel = panel('Load on the monitored servers', 'connections pgvigil opened, last hour; logins refused, last 24 h',
    tileRow('pgvigil\'s load',
      tile('Connections per minute', fmtNum(Math.round(load.reduce((a, r) => a + Number(r.conns_per_min ?? 0), 0))), '',
        { sub: `${fmtNum(Math.round(load.reduce((a, r) => a + Number(r.attempts_per_min ?? 0), 0)))} attempted, over ${fmtNum(load.length)} instance(s)` }),
      tile('Logins refused', fmtNum(load.reduce((a, r) => a + Number(r.auth_failures_24h ?? 0), 0)), authed ? 'crit' : '', { sub: `${authed} instance(s), 24 h` })),
    grid(load, [
      { key: 'instance', fmt: (_v, r) => instLink(ctx, r) }, { key: 'engine' },
      { key: 'conns_per_min', label: 'connections / min', num: true, fmt: fmtNum },
      { key: 'attempts_per_min', label: 'attempts / min', num: true, fmt: fmtNum },
      { key: 'conns_peak_min', label: 'busiest minute', num: true, fmt: fmtNum },
      { key: 'runs_1h', label: 'runs (1 h)', num: true, fmt: fmtNum }, { key: 'failures_1h', label: 'failures (1 h)', num: true, fmt: fmtNum },
      { key: 'auth_failures_1h', label: 'logins refused (1 h)', num: true, fmt: fmtNum },
      { key: 'auth_failures_24h', label: 'logins refused (24 h)', num: true, fmt: fmtNum },
    ] as Col[], 'No run in the last 24 hours.'),
    el('p', { class: 'meta' }, 'Counted at every connect a collection makes, a per-database connect included (each collection connects and closes; '
      + 'every collector of the instance summed). A login refused (PostgreSQL 28P01 / 28000, SQL Server 18456) is retried at every run: a changed password can lock the login out.'));

  // the repository
  const total = conns.reduce((a, r) => a + Number(r.connections ?? 0), 0);
  const repoPanel = panel('Repository', 'the PostgreSQL database pgvigil writes to',
    tileRow('The repository',
      tile('Size', repo.size_bytes == null ? '-' : fmtBytes(repo.size_bytes)),
      tile('Growth per day', repo.growth_per_day_bytes == null ? '-' : fmtBytes(repo.growth_per_day_bytes), '',
        { sub: repo.size_then_at ? `since ${fmtTime(repo.size_then_at)}` : 'needs an hour of beats' }),
      tile('Rows written per minute', repo.rows_per_min == null ? '-' : fmtNum(repo.rows_per_min), '', { sub: 'the last hour' }),
      tile('Connections', fmtNum(total), '', { sub: 'every application, now' }),
      tile('Last purge', repo.purge_at ? fmtTime(repo.purge_at) : 'never', repo.purge_at && Date.now() - Date.parse(String(repo.purge_at)) < 2 * 86400e3 ? '' : 'warn',
        { sub: repo.purge_at ? `${fmtNum(repo.purge_partitions)} partition(s), ${fmtNum(repo.purge_rows)} row(s); kept ${repo.purge_days} days` : 'purge() has not run' })),
    el('h4', {}, 'Largest tables'),
    grid(tables, [
      { key: 'table_name', label: 'table' }, { key: 'bytes', label: 'size', num: true, fmt: fmtBytes },
      { key: 'parts', label: 'partitions', num: true, fmt: fmtNum }, { key: 'rows_estimate', label: 'rows (estimate)', num: true, fmt: fmtNum },
    ] as Col[], 'No table read.'),
    el('h4', {}, 'Connections'),
    grid(conns, [{ key: 'application' }, { key: 'state' }, { key: 'connections', num: true, fmt: fmtNum }] as Col[], 'No connection read.'),
    el('h4', {}, 'Purges'),
    grid(purges, [
      { key: 'finished_at', label: 'finished', fmt: fmtTime }, { key: 'duration_ms', label: 'duration (ms)', num: true, fmt: fmtNum },
      { key: 'days', label: 'days kept', num: true }, { key: 'partitions', label: 'partitions dropped', num: true, fmt: fmtNum },
      { key: 'rows_deleted', label: 'rows deleted', num: true, fmt: fmtNum }, { key: 'dropped', label: 'what it dropped', wide: true },
    ] as Col[], 'purge() has not run on this repository: pgvigil purge daily keeps it to the retention.'));

  sec.append(svc, find, runsPanel, failPanel, loadPanel, repoPanel);
  return sec;
}

// collectorLine: the line on an instance's Collection dates page - the collector's state, this instance's load and
// what fails on it - each a link to the Collector page.
export async function collectorLine(ctx: Ctx): Promise<HTMLElement> {
  const box = el('p', { class: 'meta collector-line' });
  if (!ctx.instance) return box;
  let d: Parts;
  try { d = await get<Parts>('collector', { instance: ctx.instance }); } catch (e) { return errorBox(e); }
  const st = serviceState(rowsOf(d.collectors)), l = rowsOf(d.load)[0], failing = rowsOf(d.streaks).filter(r => Number(r.fail_streak) >= 3);
  const own = rowsOf(d.findings).filter(r => r.instance_id != null);
  box.append(el('a', { href: href(ctx, { tab: 'collector', instance: undefined, tag: undefined }) }, 'Collector'), ': ',
    badge(st.word, st.kind), ` ${st.sub}. This instance: `,
    l ? `${fmtNum(l.conns_per_min ?? 0)} connection(s) per minute, ${fmtNum(l.auth_failures_24h ?? 0)} login(s) refused in 24 h` : 'no run in 24 h',
    `; ${failing.length ? failing.map(r => `${r.collection} failed ${r.fail_streak} in a row`).join(', ') : 'no collection failing'}`,
    own.length ? `; ${own.length} finding(s)` : '', '.');
  return box;
}
