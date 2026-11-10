// The Jobs tab of a SQL Server instance in DBA Dash's shape (task 110; DBA Dash 4.24.1's Agent Jobs grid, Job
// History and Job DDL History): one line per job (name | enabled | schedule | last run and outcome | the last failure's
// message | next run | runs / failures in the range | changed in the range), then for the picked job its runs over the
// range with a duration strip and the counts, and the changes to its definition, field by field, old against new.
// Above: the tiles, the job findings and what runs now (task 98). Data from /api/jobs/history?engine=mssql and
// /api/mssql/jobs. jobsPanel is shared with the PostgreSQL page (jobs_pg.ts).
import { get, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { mssqlFindingCols } from './mssql_hadr';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

const CUT = 200;

// oneLine: the first CUT characters of a text on one line; the whole text opens below it on a click
export function oneLine(v: unknown): string | Node {
  const s = String(v ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= CUT) return s;
  return el('details', { class: 'cut' }, el('summary', {}, s.slice(0, CUT) + '...'), el('pre', { class: 'sql' }, String(v)));
}

// the outcome as a word; a fill only where it is not ok (Few's rule: an OK cell carries no fill)
const outcomeBadge = (v: unknown): string | Node => {
  const s = String(v ?? '');
  if (s === 'failed') return badge('failed', 'crit');
  if (s === 'cancelled' || s === 'retry') return badge(s, 'warn');
  return s;
};
const dur = (v: unknown) => v == null ? '' : Number(v) < 60 ? fmtNum(Math.round(Number(v) * 10) / 10) + ' s' : fmtSecs(v);

// strip: the runs' durations over time as bars (oldest left); a failed or cancelled run is a hollow bar with a mark,
// so the outcome never rides on colour alone
function strip(runs: Row[]): HTMLElement {
  const rs = runs.filter(r => r.start_time && r.duration_s != null).reverse();
  if (rs.length < 2) return el('p', { class: 'empty' }, 'Too few runs in this range for a duration strip.');
  const W = 640, H = 60, max = Math.max(...rs.map(r => Number(r.duration_s))) || 1;
  const bw = Math.max(1, Math.min(12, W / rs.length - 1));
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', `0 0 ${W} ${H + 10}`);
  svg.setAttribute('class', 'jobstrip');
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', `durations of ${rs.length} runs, longest ${dur(max)}`);
  rs.forEach((r, i) => {
    const h = Math.max(1, Number(r.duration_s) / max * H), x = i * (W / rs.length);
    const bad = r.outcome === 'failed' || r.outcome === 'cancelled';
    const b = document.createElementNS(ns, 'rect');
    b.setAttribute('x', String(x)); b.setAttribute('y', String(H + 10 - h)); b.setAttribute('width', String(bw)); b.setAttribute('height', String(h));
    b.setAttribute('style', bad ? 'fill:none;stroke:var(--crit);stroke-width:1' : 'fill:var(--accent)');
    const t = document.createElementNS(ns, 'title');
    t.textContent = `${fmtTime(r.start_time)}: ${dur(r.duration_s)}, ${String(r.outcome ?? '')}`;
    b.append(t);
    svg.append(b);
    if (bad) {
      const m = document.createElementNS(ns, 'text');
      m.setAttribute('x', String(x)); m.setAttribute('y', String(Math.max(8, H + 8 - h))); m.setAttribute('style', 'fill:var(--crit);font-size:9px');
      m.textContent = 'x';
      svg.append(m);
    }
  });
  return el('div', { class: 'chart' }, svg as unknown as HTMLElement);
}

const runCols: Col[] = [
  { key: 'start_time', label: 'start', fmt: fmtTime },
  { key: 'duration_s', label: 'took', num: true, fmt: dur },
  { key: 'outcome', fmt: outcomeBadge },
  { key: 'failed_step', label: 'step that failed' },
  { key: 'sql_message_id', label: 'error', num: true, fmt: v => v == null || Number(v) === 0 ? '' : String(v) },
  { key: 'sql_severity', label: 'severity', num: true, fmt: v => v == null || Number(v) === 0 ? '' : String(v) },
  { key: 'retries', num: true, fmt: v => v == null ? '' : fmtNum(v) },
  { key: 'message', fmt: oneLine },
];

interface Change { field: string; old: unknown; new: unknown }

// changes: one block per version, newest first; a version in the range opens by itself
function changes(rows: Row[], from: string, to: string): HTMLElement {
  const box = el('div');
  if (!rows.length) { box.append(el('p', { class: 'empty' }, 'No version of this job is kept yet.')); return box; }
  for (const v of rows) {
    const list = (Array.isArray(v.changes) ? v.changes : typeof v.changes === 'string' ? JSON.parse(v.changes) : []) as Change[];
    const at = String(v.valid_from), inRange = at > from && at <= to;
    const what = Number(v.version_no) === 1 ? 'first seen' : v.dropped ? 'dropped' : `${list.length} field${list.length === 1 ? '' : 's'} changed: ${list.map(c => c.field).join(', ')}`;
    const d = el('details', inRange && Number(v.version_no) > 1 ? { open: '' } : {},
      el('summary', {}, `${fmtTime(at)} - version ${String(v.version_no)} - ${what}`));
    if (list.length) {
      d.append(grid(list.map(c => ({ field: c.field, old: c.old ?? '(none)', new: c.new ?? '(none)' })), [
        { key: 'field' },
        { key: 'old', label: 'before', fmt: x => el('pre', { class: 'sql' }, String(x)) },
        { key: 'new', label: 'after', fmt: x => el('pre', { class: 'sql' }, String(x)) },
      ]));
    } else {
      d.append(el('pre', { class: 'sql' }, JSON.stringify(typeof v.definition === 'string' ? JSON.parse(v.definition) : v.definition, null, 2)));
    }
    box.append(d);
  }
  return box;
}

// jobsPanel: the one-line-per-job grid and, under it, the picked job's History and Changes. extra = the engine's own
// columns after the shared ones (the PostgreSQL page's database, user and command).
export async function jobsPanel(ctx: Ctx, engine: 'pg' | 'mssql', extra: Col[] = []): Promise<HTMLElement> {
  const w = window_(ctx);
  const box = el('div');
  const d = await get<Record<'jobs', Table | null>>('jobs/history', { engine, instance: ctx.instance, ...w });
  const jobs = rowsOf(d.jobs);
  const detail = el('div', { class: 'jobdetail' });
  const pick = async (j: Row) => {
    detail.replaceChildren(el('h3', {}, `${String(j.name)}: history (${rangeLabel(ctx)})`), el('p', { class: 'meta' }, 'Reading...'));
    try {
      const x = await get<Record<'runs' | 'counts' | 'changes', Table | null>>('jobs/history',
        { engine, instance: ctx.instance, ...w, scheduler: String(j.scheduler), job: String(j.job_id), part: undefined });
      const runs = rowsOf(x.runs), c = rowsOf(x.counts)[0] ?? {};
      detail.replaceChildren(el('h3', {}, `${String(j.name)}: history (${rangeLabel(ctx)})`),
        el('div', { class: 'tiles' },
          tile('succeeded', fmtNum(c.succeeded ?? 0)),
          tile('failed', fmtNum(c.failed ?? 0), Number(c.failed) > 0 ? 'crit' : ''),
          tile('cancelled', fmtNum(c.cancelled ?? 0), Number(c.cancelled) > 0 ? 'warn' : ''),
          tile('running long (over 2x the median)', fmtNum(c.running_long ?? 0), Number(c.running_long) > 0 ? 'warn' : ''),
          tile('median good run', c.median_s == null ? 'n/a' : dur(c.median_s))),
        strip(runs),
        grid(runs, runCols, 'No run of this job started in this range.'),
        el('h3', {}, `${String(j.name)}: changes`),
        changes(rowsOf(x.changes), new Date(w.from).toISOString(), new Date(w.to).toISOString()));
    } catch (e) { detail.replaceChildren(errorBox(e)); }
  };
  const cols: Col[] = [
    { key: 'name', label: 'job', fmt: (v, r) => {
      const b = el('button', { class: 'link', type: 'button' }, String(v ?? ''));
      b.addEventListener('click', () => { void pick(r); });
      return b;
    } },
    { key: 'enabled', fmt: v => v == null ? '' : v ? 'yes' : badge('no', 'warn') },
    { key: 'schedule', fmt: oneLine },
    { key: 'last_run_at', label: 'last run', fmt: fmtTime },
    { key: 'last_outcome', label: 'outcome', fmt: outcomeBadge },
    { key: 'last_failure', label: 'last failure', fmt: (v, r) => v == null ? '' : el('span', {}, `${fmtTime(r.last_failed_at)}${r.failed_step ? ` step ${String(r.failed_step)}` : ''}: `, oneLine(v)) },
    { key: 'next_run', label: 'next run', fmt: fmtTime },
    { key: 'runs', num: true },
    { key: 'failures', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'crit') : '0' },
    { key: 'changes', label: 'changed', num: true, fmt: (v, r) => Number(v) > 0 ? `${fmtNum(v)} (${fmtTime(r.last_change_at)})` : '' },
    { key: 'dropped_at', label: 'dropped', fmt: v => v ? badge(`dropped ${fmtTime(v)}`, 'warn') : '' },
    ...extra,
  ];
  box.append(grid(jobs, cols, 'No job on this server.'), detail);
  if (jobs.length) detail.append(el('p', { class: 'meta' }, 'Pick a job for its history and changes.'));
  return box;
}

const runningCols: Col[] = [
  { key: 'name', label: 'job' }, { key: 'running_since', label: 'started', fmt: fmtTime },
  { key: 'running_s', label: 'running for (at the read)', num: true, fmt: fmtSecs },
  { key: 'avg_duration_s', label: 'average of its good runs', num: true, fmt: fmtSecs },
  { key: 'running_after_step', label: 'last step finished', num: true },
];

export async function mssqlJobs(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Agent jobs (${rangeLabel(ctx)})`));
  try {
    const d = await get<Record<'jobs' | 'running' | 'failed' | 'findings' | 'read', Table | null>>('mssql/jobs', { instance: ctx.instance, ...window_(ctx) });
    const jobs = rowsOf(d.jobs), running = rowsOf(d.running), failed = rowsOf(d.failed), read = rowsOf(d.read)[0];
    if (!read) {
      sec.append(el('p', { class: 'empty' }, 'mssql_jobs has not run on this server yet. It needs a user in msdb with db_datareader.'));
      return sec;
    }
    if (read.status && read.status !== 'ok') sec.append(el('p', { class: 'meta' }, badge(String(read.status), 'warn'),
      ` mssql_jobs: ${String(read.note ?? '')}${read.snapshot_at ? `. Last read ${fmtTime(read.snapshot_at)}.` : ''}`));
    if (!read.snapshot_at) return sec;   // never read: only the reason above
    sec.append(el('div', { class: 'tiles' },
      tile('jobs', fmtNum(jobs.length)),
      tile('last outcome failed', fmtNum(jobs.filter(j => j.last_outcome === 0).length), jobs.some(j => j.last_outcome === 0) ? 'crit' : ''),
      tile('failed runs in the range', fmtNum(failed.length), failed.length ? 'warn' : ''),
      tile('running now', fmtNum(running.length)),
      tile('disabled', fmtNum(jobs.filter(j => j.enabled === false).length)),
    ));
    const findings = rowsOf(d.findings);
    if (findings.length) sec.append(el('h3', {}, 'Findings'), grid(findings, mssqlFindingCols));
    if (running.length) sec.append(el('h3', {}, 'Running now'), grid(running, runningCols));
    sec.append(el('h3', {}, `Jobs (read ${fmtTime(read.snapshot_at)})`), await jobsPanel(ctx, 'mssql'));
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
