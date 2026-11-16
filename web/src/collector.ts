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
import { tagScopeIds, tagWords } from './fleet';
import { lineChart } from './chart';
import { tileRow } from './tiles';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtSecs, fmtTime, grid, panel, stateNote, tile } from './ui';

// connectSecs: a connect time in seconds as the page shows it ('0.12 s'; '-' when none was timed)
const connectSecs = (v: unknown): string => v == null || v === '' ? '-' : `${Number(v).toFixed(2)} s`;
// B24h: a round trip or a probe's answer in milliseconds ('-' when none)
const msOf = (v: unknown): string => v == null || v === '' ? '-' : `${Math.round(Number(v) * 1000)} ms`;
// the host's probe over the hour in words: its answer (method, answered of probed), or why there is none - not probed
// (by default a host is probed only after a failed collection), never answered (blocked or not allowed: no finding), or
// not answering since it last did
function probeWords(r: Row): string {
  const rounds = Number(r.probe_rounds_1h ?? 0), answered = Number(r.probe_answered_1h ?? 0);
  if (!rounds) return '-';
  if (answered > 0) return `${msOf(r.probe_avg_s)} (${String(r.probe_method ?? '')}, ${answered} of ${rounds})`;
  // a TCP probe goes to the port a connection of the instance opened: its silence is no blocked ICMP (the B24h-1 review
  // part b #11); an opened connection counts as an answer (part a #1), so 'never' is ICMP's case alone
  if (r.probe_last_answered == null) return String(r.probe_method ?? '') === 'tcp' ? 'no answer to the TCP handshake on its port' : 'never answered (blocked or not allowed)';
  return `not answering since ${fmtTime(r.probe_last_answered)}`;
}

type Parts = Record<string, Table | null>;

const stateWord: Record<string, string> = { up: 'Up', stopped: 'Stopped', ended: 'Ended', 'not seen': 'Not seen', retired: 'Retired' };
const stateKind: Record<string, string> = { up: 'ok', stopped: 'warn', ended: '', 'not seen': 'crit', retired: '' };
const sevKind: Record<string, string> = { critical: 'crit', warning: 'warn', info: '' };
const sevWord: Record<string, string> = { critical: 'Critical', warning: 'Warning', info: 'Info' };

// the service's state in words: a collector down (its 'collector or network' finding) first, then the collectors up (one
// per host), or how long the newest has not been seen
function serviceState(rows: Row[], findings: Row[] = []): { word: string; kind: string; sub: string } {
  // the parent's value is its host; its why is a field of its own (the API reads it off the detail)
  const down = findings.filter(r => r.setting === 'collector or network' && r.why === 'collector not seen');
  if (down.length) return { word: down.length === 1 ? 'Down' : `${down.length} down`, kind: 'crit', sub: down.map(r => String(r.value)).join(', ') + ' not seen for 5 minutes' };
  const live = rows.filter(r => r.state === 'up');
  if (live.length > 1) return { word: `${live.length} up`, kind: 'ok', sub: live.map(r => String(r.host)).join(', ') };
  if (live.length === 1) return { word: 'Up', kind: 'ok', sub: `beat ${fmtSecs(live[0].beat_age_secs)} ago` };
  const newest = (rs: Row[]) => rs.reduce<Row | undefined>((a, r) => a == null || String(r.beat_at) > String(a.beat_at) ? r : a, undefined);
  // the newest run among those not retired; only when every run is retired - each host's collector uninstalled with the
  // repository kept (import_collector_retire) - does the tile say so: no alert stands, and nothing writes here
  const last = newest(rows.filter(r => r.state !== 'retired')) ?? newest(rows);
  if (!last) return { word: 'Never seen', kind: 'crit', sub: 'no collector has beaten on this repository' };
  if (last.state === 'retired') return { word: 'Retired', kind: 'crit', sub: `the collector on ${last.host} was uninstalled ${fmtTime(last.retired_at)}; no collector writes here` };
  if (last.state === 'stopped') return { word: 'Stopped', kind: 'crit', sub: `stopped ${fmtTime(last.stopped_at)}` };
  return { word: `Not seen for ${fmtSecs(last.beat_age_secs)}`, kind: 'crit', sub: `the last beat ${fmtTime(last.beat_at)}` };
}

const instLink = (ctx: Ctx, r: Row) => r.instance_id == null ? el('span', {}, String(r.instance ?? 'the repository'))
  : el('a', { href: href(ctx, { tab: 'collectiondates', instance: Number(r.instance_id), tag: undefined }) }, String(r.instance ?? ''));

export async function collectorView(ctx: Ctx): Promise<HTMLElement> {
  const tagged = ctx.tag && !ctx.instance ? ctx.tag : undefined;
  const sec = el('section', { class: 'collector' }, el('h2', {}, 'Collector' + (tagged ? ` - ${tagWords(tagged)}` : '')));
  let d: Parts;
  try { d = await get<Parts>('collector'); } catch (e) { sec.append(errorBox(e)); return sec; }
  // a tag folder's (TAGTREE; DBA Dash's tag folder's Checks over its own instances): the per-instance rows of the tag's
  // instances; a row of no instance (the collector's own, the repository's) and the service and repository panels stay
  let ids: Set<number> | null;
  try { ids = await tagScopeIds(ctx); } catch (e) { sec.append(errorBox(e)); return sec; }
  const inFolder = (r: Row) => !ids || r.instance_id == null || ids.has(Number(r.instance_id));
  const collectors = rowsOf(d.collectors), findings = rowsOf(d.findings).filter(inFolder), colls = rowsOf(d.collections), minutes = rowsOf(d.minutes);
  const load = rowsOf(d.load).filter(inFolder), streaks = rowsOf(d.streaks).filter(inFolder), tables = rowsOf(d.tables), waits = rowsOf(d.waits);
  const repo: Row = rowsOf(d.repository)[0] ?? {};
  const conns = rowsOf(d.connections), purges = rowsOf(d.purges);
  if (ids) sec.append(el('p', { class: 'meta' }, `In view: ${tagWords(tagged!)} - the instances' rows are its ${ids.size} instance(s); the service, the collections and the repository are the whole repository's.`));
  const st = serviceState(collectors, findings), me = collectors.find(r => r.state === 'up') ?? collectors[0];
  const wd = String(rowsOf(d.watchdog)[0]?.watchdog ?? '');
  const wdTile = wd === 'on' ? tile('Watchdog', 'On', '', { sub: 'serve sends the alert while a collector is down' })
    : wd === 'starting' ? tile('Watchdog', 'Starting', '', { sub: 'serve is reaching the alerts login and the repository (up to 40 s)' })
    : wd.startsWith('on;') ? tile('Watchdog', 'On', 'warn', { sub: wd.slice(4) })
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
      { key: 'stopped_at', label: 'stopped', fmt: fmtTime }, { key: 'retired_at', label: 'retired', fmt: fmtTime },
      { key: 'mem_bytes', label: 'memory', num: true, fmt: v => v == null ? '' : fmtBytes(v) },
      { key: 'goroutines', num: true, fmt: fmtNum }, { key: 'repo_conns', label: 'repository sessions', num: true, fmt: fmtNum },
    ] as Col[], 'No collector has beaten on this repository in the last 8 days: is pgvigil run started (the service, or a console)?'));

  // the collector's findings
  const find = panel('Findings', 'the collector and the repository, now',
    findings.length ? grid(findings, [
      { key: 'severity', fmt: v => badge(sevWord[String(v)] ?? String(v), sevKind[String(v)] ?? '') },
      { key: 'instance', fmt: (_v, r) => instLink(ctx, r) }, { key: 'setting', label: 'check' }, { key: 'value' },
      { key: 'detail', wide: true }, { key: 'at', label: 'since', fmt: fmtTime },
    ] as Col[]) : stateNote('empty', 'No finding: the collector beats, no collection fails three runs in a row, no login is refused, purge ran in the last 2 days, and in a month\'s last three days next month\'s partitions are made.'),
    // a forming wait that ended without a parent (task 201 DONE-2 N7): only while no parent stands on that host
    ...waits.map(r => el('p', { class: 'state' }, `The wait for a shared cause ended on ${r.host} at ${fmtTime(r.ended_at)} without one: new alerts of its ${fmtNum(r.instances)} failing instance(s) are sent as they come.`)));

  // the collections over 24 h
  const sum = (k: string) => colls.reduce((a, r) => a + Number(r[k] ?? 0), 0);
  const runs = sum('runs'), fails = sum('failures'), retried = sum('retries');
  const worst = colls.reduce<Row | null>((a, r) => r.p95_ms != null && (a == null || Number(r.p95_ms) > Number(a.p95_ms)) ? r : a, null);
  const failing = streaks.filter(r => Number(r.fail_streak) >= 3).length;
  const runsPanel = panel('Collections', 'last 24 h',
    tileRow('The collections over 24 hours',
      tile('Runs', fmtNum(runs)),
      tile('Failures', fmtNum(fails), fails ? 'warn' : '', { sub: runs ? `${(100 * fails / runs).toFixed(1)} % of runs` : undefined }),
      tile('Rows written', fmtNum(sum('rows_written'))),
      tile('Slowest p95', worst ? fmtNum(worst.p95_ms) : '-', '', { unit: worst ? 'ms' : undefined, sub: worst ? String(worst.collection) : undefined }),
      tile('Failing now', fmtNum(failing), failing ? 'crit' : '', { sub: 'three runs in a row or more' }),
      // N4: an import PostgreSQL ended as a deadlock's victim and pgvigil took again (stored once); shown when above 0
      ...(retried ? [tile('Retried after a deadlock', fmtNum(retried), 'warn', { sub: 'imports taken again; one that failed every try counts in Failures' })] : [])),
    minutes.length >= 2
      ? lineChart('Runs and failures per minute', minutes,
          [{ key: 'runs', label: 'runs' }, { key: 'failures', label: 'failures' }, { key: 'rows_written', label: 'rows written' }],
          v => v.toLocaleString(), { ownSpan: true, marks: false, y2: { keys: ['rows_written'], unit: 'rows' } })
      : stateNote('empty', 'No minute of runs in the last 24 hours: the collector has not beaten, or it is new (a beat a minute).'),
    // B6.4: the run duration a minute - its p95 over every collection (most runs slower) and its longest run (one
    // collection running long, which moves no p95 among a minute's many runs: B6.2 part c #8)
    ...(minutes.length >= 2 ? [lineChart('Run duration per minute (p95 and longest, ms)', minutes, [{ key: 'p95_ms', label: 'p95 (ms)' }, { key: 'max_ms', label: 'longest (ms)' }],
      v => v.toLocaleString(), { ownSpan: true, marks: false, unit: 'ms' })] : []),
    // B6.2: each instance's collections judged by DBA Dash's rule
    el('p', { class: 'meta' }, el('a', { href: href(ctx, { tab: 'collectionhealth' }) }, 'Collection Health'), ': each collection\'s status per instance by DBA Dash\'s rule, its failure rates and its errors.'),
    grid(colls, [
      { key: 'collection' }, { key: 'engine' },
      // a failure count opens the collector's error log of that collection over 24 h, its errors only (the count is the
      // heartbeat's runs that ended with an error, the list collection_log's rows: the two can differ)
      { key: 'runs', num: true, fmt: fmtNum }, { key: 'failures', num: true, fmt: (v, r) => !Number(v) ? fmtNum(v) : el('a', {
        href: `#/collectorerrors?w=24h&view=error&type=Error&coll=${encodeURIComponent(String(r.collection))}`,
        title: 'The errors kept for this collection in the last 24 hours, on every instance. The count is the collector\'s runs that ended with an error, over the whole repository and per engine; the list is the error log\'s rows: the two can differ.' }, fmtNum(v)) },
      { key: 'failure_pct', label: 'failure %', num: true, fmt: v => v == null ? '' : `${v}` },
      { key: 'retries', label: 'retried after a deadlock', num: true, fmt: v => Number(v ?? 0) ? fmtNum(v) : '' },
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
      { key: 'connect_avg_s', label: 'connect avg (1 h)', num: true, fmt: connectSecs },
      { key: 'connect_max_s', label: 'connect max (1 h)', num: true, fmt: connectSecs },
      { key: 'rt_avg_s', label: 'round trip avg (1 h)', num: true, fmt: msOf },
      { key: 'rt_max_s', label: 'round trip max (1 h)', num: true, fmt: msOf },
      { key: 'probe_avg_s', label: 'host probe (1 h)', fmt: (_v, r) => probeWords(r) },
    ] as Col[], 'No run in the last 24 hours.'),
    el('p', { class: 'meta' }, 'Round trip: one \'SELECT 1\' a minute on a collection\'s own connection - the network there and back and the server\'s answer, '
      + 'not the network alone; over its round_trip_time threshold (0.040 s by default, warning only) it raises \'query round trip slow\'. '
      + 'Host probe: the TCP handshake to the address the instance\'s last connection used (ICMP comes later), by default only after a failed collection '
      + '(probe_every_minute: each minute); a host that never answered is shown, never a finding; a listener or balancer answers for the servers behind it.'),
    el('p', { class: 'meta' }, 'Counted at every connect a collection makes, a per-database connect included (each collection connects and closes; '
      + 'every collector of the instance summed). A login refused (PostgreSQL 28P01 / 28000, SQL Server 18456) is retried at every run: a changed password can lock the login out. '
      + 'Connect avg / max: from the call to the open connection - DNS, the TLS handshake, the login and the collector\'s own CPU; an Entra token fetch left out - over the hour. '
      + 'An instance whose last 5 written minutes average over its connect_time threshold (1.00 s / 2.50 s by default; on Thresholds at the root, a tag or a PostgreSQL instance) raises \'slow connect\'; '
      + 'most of a server\'s instances, or most of the servers a collector reads, slow at once raise one \'slow connects\' instead '
      + '(a member over its level is still sent).'));

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
  // the remote collectors (docs/remote-collector.md): drawn only where a site's bundles have been loaded
  const remote = rowsOf(d.remote ?? null);
  const silenceKind: Record<string, string> = { ok: 'ok', warning: 'warn', critical: 'crit', 'no bundle yet': 'none' };
  if (remote.length) sec.append(panel('Remote collectors', 'sites pgvigil cannot reach: each collector\'s newest bundle and how ingest took them',
    el('p', { class: 'meta' }, 'A remote instance is as fresh as its site\'s bundles: its pages say \'as of\' the newest bundle, its findings fire as late '
      + 'as the bundle interval plus the transfer, and a finding of it clears no sooner than its bundle interval plus the site\'s expected_every. '
      + 'No live door reaches it: actions, EXPLAIN and every other live read are off on it, with the reason shown.'),
    grid(remote, [
      { key: 'site' }, { key: 'collector' },
      { key: 'silence', fmt: (v: unknown) => badge(v === 'ok' ? 'sending' : String(v), silenceKind[String(v)] ?? ''),
        title: 'no bundle for 2 x the site\'s expected_every: warning; 6 x: critical' },
      { key: 'newest_bundle_at', label: 'newest bundle', fmt: fmtTime },
      { key: 'expected_every_secs', label: 'expected every', num: true, fmt: (v: unknown) => v == null ? '' : fmtSecs(v) },
      { key: 'heartbeat_at', label: 'collector beat', fmt: fmtTime }, { key: 'host' }, { key: 'pgvigil_version', label: 'version' },
      { key: 'instances', num: true, fmt: fmtNum }, { key: 'fail_streak', label: 'fail streak', num: true, fmt: fmtNum },
      { key: 'gaps', num: true, fmt: fmtNum }, { key: 'set_aside', label: 'set aside', num: true, fmt: fmtNum },
      { key: 'newest_set_aside_reason', label: 'newest set-aside reason', wide: true },
      { key: 'late', num: true, fmt: fmtNum }, { key: 'conflicts', num: true, fmt: fmtNum },
    ] as Col[], 'No remote collector.')));
  // the Parquet export (pgvigil export): drawn only where one is configured or has run
  let x: Parts | null = null;
  try { x = await get<Parts>('export'); } catch (e) { sec.append(errorBox(e)); }
  const xruns = rowsOf(x?.runs ?? null), xstate = rowsOf(x?.state ?? null), xsvc = rowsOf(x?.service ?? null);
  if (xruns.length || xstate.length) sec.append(panel('Parquet export', 'pgvigil export: the last windows it wrote',
    ...xsvc.map(r => el('p', { class: 'meta' }, badge('behind or failing', 'crit'), ' ', String(r.detail ?? ''))),
    ...xstate.map(r => el('p', { class: 'meta' }, `${r.name} to ${r.destination}: newest window ended ${r.newest_window_to ? fmtTime(r.newest_window_to) : 'never'}`
      + (r.hours_behind == null ? '' : ` (${fmtNum(r.hours_behind)} h ago)`) + `; last run ${fmtTime(r.last_run_at)}.`)),
    grid(xruns, [
      { key: 'name', label: 'export' }, { key: 'window_from', label: 'window from', fmt: fmtTime }, { key: 'pass' },
      { key: 'outcome', fmt: (v: unknown) => badge(String(v), v === 'ok' ? 'ok' : 'crit') },
      { key: 'finished_at', label: 'finished', fmt: fmtTime }, { key: 'duration_ms', label: 'duration (ms)', num: true, fmt: fmtNum },
      { key: 'tables', num: true, fmt: fmtNum }, { key: 'files', num: true, fmt: fmtNum }, { key: 'rows', num: true, fmt: fmtNum },
      { key: 'bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'error', wide: true },
    ] as Col[], 'The export is configured and has written no window yet.')));
  return sec;
}

// collectorLine: the line on an instance's Collection dates page - the collector's state, this instance's load and
// what fails on it - each a link to the Collector page.
export async function collectorLine(ctx: Ctx): Promise<HTMLElement> {
  const box = el('p', { class: 'meta collector-line' });
  if (!ctx.instance) return box;
  let d: Parts;
  try { d = await get<Parts>('collector', { instance: ctx.instance }); } catch (e) { return errorBox(e); }
  const st = serviceState(rowsOf(d.collectors), rowsOf(d.findings)), l = rowsOf(d.load)[0], failing = rowsOf(d.streaks).filter(r => Number(r.fail_streak) >= 3);
  const own = rowsOf(d.findings).filter(r => r.instance_id != null);
  box.append(el('a', { href: href(ctx, { tab: 'collector', instance: undefined, tag: undefined }) }, 'Collector'), ': ',
    badge(st.word, st.kind), ` ${st.sub}. This instance: `,
    l ? `${fmtNum(l.conns_per_min ?? 0)} connection(s) per minute, ${fmtNum(l.auth_failures_24h ?? 0)} login(s) refused in 24 h`
      + (l.connect_avg_s == null ? '' : `, connect ${connectSecs(l.connect_avg_s)} on average in the last hour (the longest ${connectSecs(l.connect_max_s)})`) : 'no run in 24 h',
    `; ${failing.length ? failing.map(r => `${r.collection} failed ${r.fail_streak} in a row`).join(', ') : 'no collection failing'}`,
    own.length ? `; ${own.length} finding(s)` : '', '.');
  return box;
}
