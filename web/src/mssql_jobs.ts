// The Jobs tab of a SQL Server instance in DBA Dash's shape (task 110; DBA Dash 4.24.1's Agent Jobs grid, Job
// History and Job DDL History): one line per job (name | enabled | schedule | last run and outcome | the last failure's
// message | next run | runs / failures in the range | changed in the range), then for the picked job its runs over the
// range with a duration strip and the counts, and the versions of its definition.
// Above: the tiles, the job findings and what runs now (task 98). Data from /api/jobs/history?engine=mssql and
// /api/mssql/jobs. jobsPanel is shared with the PostgreSQL page (jobs_pg.ts).
// Task 154 (DBA Dash's Job DDL History, Agent Job Thresholds and Start / Stop Job):
//   versions    every version kept of the job with its valid from / to; for the one picked the whole script under
//               three views (code, side by side against the version before, inline), the copies of either side,
//               the version as the job's page (Info), two versions' pages side by side with the changed cells
//               marked (Compare info), and the changed fields old against new (Fields)
//   status      each job judged against its thresholds (the job's own, else the instance's, else the root's);
//               Thresholds opens the three levels with inherit. Data: /api/jobs/thresholds
//   Start, Stop a SQL Server job through the actions door (mssql_actions.ts)
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { jsonRows, mssqlFindingCols } from './mssql_hadr';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, offControl, tile } from './ui';
import { AckData, ackOn, ackWhy, jobAckCell, jobAcks, loadAckSafe, onDoor, seatWhy } from './ack';
import { fleet } from './fleet';
import { jobChartSection } from './jobs_chart';
import { definitionCompare, definitionView, diffCounts, lineDiff, textDiffView } from './diff';
import { mssqlJobCol } from './mssql_actions';

const CUT = 200;

// oneLine: the first CUT characters of a text on one line; the whole text opens below it on a click
export function oneLine(v: unknown): string | Node {
  const s = String(v ?? '').replace(/\s+/g, ' ').trim();
  if (s.length <= CUT) return s;
  // inline, so the cell stays one line until the reader opens it
  return el('details', { class: 'cut', style: 'display:inline' }, el('summary', { style: 'display:inline;cursor:pointer' }, s.slice(0, CUT) + '...'),
    el('pre', { class: 'sql' }, String(v)));
}

// the outcome as a word; a fill only where it is not ok (Few's rule: an OK cell carries no fill)
const outcomeBadge = (v: unknown): string | Node => {
  const s = String(v ?? '');
  if (s === 'failed') return badge('failed', 'crit');
  if (s === 'cancelled' || s === 'retry') return badge(s, 'warn');
  return s;
};
// the level of an outcome by outcomeBadge's own rule, as a status cell's class ('' = not judged)
const outcomeCls = (v: unknown): string => {
  const s = String(v ?? '');
  return s === 'failed' ? 'status crit' : s === 'cancelled' || s === 'retry' ? 'status warn' : s === 'succeeded' ? 'status ok' : '';
};
const dur = (v: unknown) => v == null ? '' : Number(v) < 60 ? fmtNum(Math.round(Number(v) * 10) / 10) + ' s' : fmtSecs(v);

// strip: the runs' durations over time as bars (oldest left); a failed or cancelled run is a hollow bar with a mark,
// so the outcome never rides on colour alone
function strip(runs: Row[]): HTMLElement {
  const rs = runs.filter(r => r.start_time && r.duration_s != null).reverse();
  if (rs.length < 2) return el('p', { class: 'empty' }, 'Too few runs in this range for a duration strip.');
  const W = 640, H = 60, max = Math.max(...rs.map(r => Number(r.duration_s))) || 1;
  const bw = Math.max(1, Math.min(12, W / rs.length - 1));
  const step = Math.min(W / rs.length, bw + 4);   // a few runs sit together like a sparkline, never spread over the width
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('viewBox', `0 0 ${W} ${H + 10}`);
  // its own size, never larger (with only a viewBox it stretched to the page: twice the scale, bars 140 px tall)
  svg.setAttribute('width', String(W)); svg.setAttribute('height', String(H + 10)); svg.setAttribute('style', 'max-width:100%;height:auto');
  svg.setAttribute('class', 'jobstrip');
  svg.setAttribute('role', 'img');
  svg.setAttribute('aria-label', `durations of ${rs.length} runs, longest ${dur(max)}`);
  rs.forEach((r, i) => {
    const h = Math.max(1, Number(r.duration_s) / max * H), x = i * step;
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
type View = 'script' | 'info' | 'compare' | 'fields';
const viewTitle: Record<View, string> = { script: 'Script', info: 'Info', compare: 'Compare info', fields: 'Fields' };
const changeList = (v: Row): Change[] => (Array.isArray(v.changes) ? v.changes : typeof v.changes === 'string' ? JSON.parse(v.changes) : []) as Change[];
const defOf = (v: Row): unknown => typeof v.definition === 'string' ? JSON.parse(v.definition) : v.definition;
// the version's script; a version kept before scripts were (or read from a server that sends none) has its
// definition as text in its place, and the view says so
const scriptOf = (v: Row): { text: string; kept: boolean } => typeof v.script === 'string' && v.script !== ''
  ? { text: v.script, kept: true } : { text: JSON.stringify(defOf(v), null, 2), kept: false };

// versions: every version kept of a job, newest first (rows as the API lists them), and under the list the picked
// version in the picked view; the newest version's script opens by itself
function versions(rows: Row[], jobName: string): HTMLElement {
  const box = el('div', { class: 'jobversions' });
  if (!rows.length) { box.append(el('p', { class: 'empty' }, 'No version of this job is kept yet.')); return box; }
  const detail = el('div', { class: 'versiondetail', tabindex: '-1' });
  const label = (v: Row) => `version ${String(v.version_no)} of ${fmtTime(v.valid_from)}`;
  const what = (v: Row): string => {
    const list = changeList(v);
    return Number(v.version_no) === 1 ? 'first seen' : v.dropped ? 'dropped'
      : list.length ? `${list.length} field${list.length === 1 ? '' : 's'} changed: ${list.map(c => c.field).join(', ')}`
        : 'the script changed (no field of the definition)';
  };
  const show = (i: number, view: View, focus = true) => {
    const v = rows[i], prev = rows[i + 1];
    const parts: (Node | string)[] = [el('h4', {}, `${jobName}, ${label(v)}: ${viewTitle[view]}`)];
    if (view === 'script') {
      const cur = scriptOf(v), before = prev ? scriptOf(prev) : undefined;
      if (!cur.kept || (before && !before.kept)) parts.push(el('p', { class: 'meta' },
        'No script is kept for ' + (!cur.kept ? 'this version' : 'the version before') + ' (it was stored before scripts were): its definition is shown as text in its place.'));
      if (v.dropped) parts.push(el('p', { class: 'meta' }, 'The read of this time no longer listed the job: the script is the last one seen.'));
      // the list holds the newest 200 versions: the oldest listed may have one before it that is not listed
      if (!prev && Number(v.version_no) > 1) parts.push(el('p', { class: 'meta' }, `Version ${String(Number(v.version_no) - 1)} is past the newest ${fmtNum(rows.length)} listed: this version is shown alone.`));
      parts.push(textDiffView(before?.text, cur.text, prev ? label(prev) : 'nothing listed before', label(v)));
    } else if (view === 'info') {
      parts.push(el('p', { class: 'meta' }, `The job as it was from ${fmtTime(v.valid_from)}` + (rows[i - 1] ? ` to ${fmtTime(rows[i - 1].valid_from)}.` : v.dropped ? ' (dropped then).' : ' (in force).')),
        definitionView(defOf(v)));
    } else if (view === 'compare') {
      parts.push(prev ? definitionCompare(defOf(prev), defOf(v), `${jobName} previous, ${label(prev)}`, `${jobName}, ${label(v)}`)
        : el('p', { class: 'empty' }, Number(v.version_no) > 1 ? 'The version before this one is past the versions listed.' : 'The first version has nothing before it.'));
      if (prev) parts.push(el('p', { class: 'meta' }, 'A cell marked * differs from the other side.'));
    } else {
      const list = changeList(v);
      parts.push(list.length ? grid(list.map(c => ({ field: c.field, old: c.old ?? '(none)', new: c.new ?? '(none)' })), [
        { key: 'field' },
        { key: 'old', label: 'before', fmt: x => el('pre', { class: 'sql' }, String(x)) },
        { key: 'new', label: 'after', fmt: x => el('pre', { class: 'sql' }, String(x)) },
      ]) : el('p', { class: 'empty' }, Number(v.version_no) === 1 ? 'The first version: nothing changed yet.' : 'No field of the definition changed at this version.'));
    }
    detail.replaceChildren(...parts);
    if (focus) detail.focus();
  };
  const list = rows.map((v, i) => {
    const prev = rows[i + 1];
    // a count only between two kept scripts: against a definition shown as text it would count the format, not a change
    const n = prev && !v.dropped && scriptOf(prev).kept && scriptOf(v).kept ? diffCounts(lineDiff(scriptOf(prev).text, scriptOf(v).text)) : undefined;
    return { _i: i, version_no: v.version_no, valid_from: v.valid_from, valid_to: rows[i - 1]?.valid_from ?? null, dropped: v.dropped,
      what: what(v), lines: n ? `+${n.added} -${n.removed}` : '' };
  });
  const cols: Col[] = [
    { key: 'version_no', label: 'version', num: true },
    { key: 'valid_from', label: 'valid from', fmt: fmtTime },
    { key: 'valid_to', label: 'valid to', fmt: (v, r) => v ? fmtTime(v) : r.dropped ? 'dropped' : 'in force' },
    { key: 'what', label: 'what changed' },
    { key: 'lines', label: 'script lines' },
    { key: '_i', label: 'open', fmt: v => el('span', { style: 'white-space:nowrap' }, ...(['script', 'info', 'compare', 'fields'] as View[]).map(view => {
      const b = el('button', { class: 'link', type: 'button', style: 'margin-right:.6rem', 'aria-label': `${viewTitle[view]} of version ${String(rows[Number(v)].version_no)}` }, viewTitle[view]);
      b.addEventListener('click', () => show(Number(v), view));
      return b;
    })) },
  ];
  box.append(el('p', { class: 'meta' }, `${fmtNum(rows.length)} version(s) kept. Script: the whole job as a script, alone or against the version before `
    + '(side by side or inline). Info: the job as it was at that version. Compare info: that version beside the one before, the changed cells marked. '
    + 'Fields: the changed fields, old against new.'), grid(list, cols), detail);
  show(0, 'script', false);
  return box;
}

// ---- thresholds at three levels (DBA Dash's Agent Job Thresholds: Job Level, Instance Level, Root Level, Inherit)
export interface Thresholds { writable: boolean; reason?: string; demo?: boolean; levels?: Table | null; status?: Table | null }
// a server without the route (an older one, or the demo) has no thresholds: the grid then has no status column
export async function loadThresholds(instance: number): Promise<Thresholds | null> {
  if (!instance) return null;
  try { return await get<Thresholds>('jobs/thresholds', { instance }); } catch { return null; }
}
const statusWords: Record<string, string> = { crit: 'critical', warn: 'warning', ok: 'OK', none: 'not judged', excluded: 'not checked' };
const statusWord = (x: Row): string => statusWords[String(x.status)] ?? '';
type Level = 'job' | 'instance' | 'root';
// label, the warning's key, the critical's key
const thresholdRows: [string, string, string][] = [
  ['Failed runs in the last 24 hours (this many or more)', 'fail_24h_warn', 'fail_24h_crit'],
  ['Failed runs in the last 7 days (this many or more)', 'fail_7d_warn', 'fail_7d_crit'],
  ['Failed steps in the last 24 hours (SQL Server Agent, pgAgent; this many or more)', 'step_fail_24h_warn', 'step_fail_24h_crit'],
  ['Failed steps in the last 7 days (SQL Server Agent, pgAgent; this many or more)', 'step_fail_7d_warn', 'step_fail_7d_crit'],
  ['Minutes since the last failure (this few or fewer)', 'since_fail_warn_min', 'since_fail_crit_min'],
  ['Minutes since the last success (more than this)', 'since_ok_warn_min', 'since_ok_crit_min'],
];

// thresholdsDialog: one job's thresholds at its three levels. A level with a row of its own applies whole; a level
// without one inherits the level above (the root inherits the built-in rule: the last run failed = critical).
// Save writes the level's row (the old one is ended and kept), Inherit ends it. Nothing is written on a bare click.
// ad, instName: the acknowledgement seat (GET /api/ack) and the instance as the page names it - on a demo serve the door
// writes this instance's own levels (job, instance) for one of its instances, never the root (B7 DONE-3); a level it
// does not carry is off in words before any request, the fields too
let thOffSeq = 0;
export function thresholdsDialog(instance: number, jobName: string, th: Thresholds, after: () => void, ad?: AckData, instName?: string) {
  const levelWhy = (lv: Level): string | null => th.writable ? null
    : ad && onDoor(ad) ? seatWhy(ad, 'thresholds', lv === 'root' ? undefined : instance, instName)
    // a demo serve whose door was not read (GET /api/ack failed): that is the reason, never the door's own words
    : th.demo ? `the demo door's instances were not read: ${ad?.reason || 'the acknowledgement read did not answer'}`
    : th.reason ?? 'thresholds cannot be written on this server';
  const offP = el('p', { class: 'meta', id: `th-off-${++thOffSeq}` });
  const levels = rowsOf(th.levels);
  const rowAt = (lv: Level) => levels.find(r => r.level === lv && (lv !== 'job' || r.job_name === jobName));
  let level: Level = 'job';
  const inputs = new Map<string, HTMLInputElement>();
  const table = el('table', { class: 'props' }, el('tr', {}, el('th', { scope: 'col' }, 'threshold'), el('th', { scope: 'col' }, 'warning'), el('th', { scope: 'col' }, 'critical')));
  for (const [label, wk, ck] of thresholdRows) {
    const mk = (k: string, sev: string) => { const i = el('input', { type: 'number', min: '1', step: '1', style: 'width:7rem', 'aria-label': `${label}: ${sev}` }); inputs.set(k, i); return i; };
    table.append(el('tr', {}, el('th', { scope: 'row' }, label), el('td', {}, mk(wk, 'warning')), el('td', {}, mk(ck, 'critical'))));
  }
  const lastFail = el('select', { id: 'th-lastfail' }, el('option', { value: '' }, 'not judged'), el('option', { value: 'warn' }, 'warning'), el('option', { value: 'crit' }, 'critical'));
  table.append(el('tr', {}, el('th', { scope: 'row' }, el('label', { for: 'th-lastfail' }, 'The last run failed')), el('td', { colspan: '2' }, lastFail)));
  const state = el('p', { class: 'meta' });
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const save = el('button', { type: 'submit' }, 'Save this level');
  const inherit = el('button', { type: 'button' }, 'Inherit');
  const no = el('button', { type: 'button' }, 'Close');
  const names: Record<Level, string> = { job: `This job (${jobName})`, instance: 'This instance (every job on it)', root: 'Root (every instance)' };
  const fill = () => {
    const r = rowAt(level);
    for (const [k, i] of inputs) i.value = r?.[k] == null ? '' : String(r[k]);
    lastFail.value = r?.last_fail_is == null ? '' : String(r.last_fail_is);
    const above = level === 'job' ? (rowAt('instance') ? "the instance's thresholds" : rowAt('root') ? "the root's thresholds" : 'the built-in rule (the last run failed = critical)')
      : level === 'instance' ? (rowAt('root') ? "the root's thresholds" : 'the built-in rule (the last run failed = critical)') : 'the built-in rule (the last run failed = critical)';
    state.textContent = r ? `This level has thresholds of its own, set by ${String(r.created_by)} on ${fmtTime(r.created_at)}; they apply whole.`
      : `This level has none of its own: it inherits ${above}.`;
    // every control of the level that is off says why: the level's own reason in the dialog's one sentence (Save, the
    // fields), Inherit with no row of its own by the line that says it inherits
    const w = levelWhy(level);
    offP.hidden = !w;
    offP.replaceChildren(...(w ? [badge('read only', 'warn'), ' ', `${names[level]}: ${w}`] : []));
    offControl(save, w, offP);
    offControl(inherit, w ?? (r ? null : 'this level has no thresholds of its own: it already inherits the level above'), w ? offP : state);
    for (const i of [...inputs.values(), lastFail]) {
      i.disabled = !!w;
      if (w) i.setAttribute('aria-describedby', offP.id); else i.removeAttribute('aria-describedby');
    }
  };
  const seg = el('fieldset', { class: 'filters' }, el('legend', {}, 'Level'), ...(['job', 'instance', 'root'] as Level[]).map(lv => {
    const rb = el('input', { type: 'radio', name: 'th-level', id: 'th-level-' + lv, value: lv });
    rb.checked = lv === level;
    rb.addEventListener('change', () => { if (rb.checked) { level = lv; fill(); } });
    return el('label', { for: 'th-level-' + lv, style: 'margin-right:1rem;white-space:nowrap' }, rb, ' ' + names[lv]);
  }));
  const form = el('form', { method: 'dialog' }, el('h3', {}, `Job thresholds: ${jobName}`),
    el('p', {}, 'A job is judged by the most specific level that has thresholds: its own, else the instance\'s, else the root\'s. An empty box is not judged.'),
    seg, state, table, offP,
    msg, el('div', { style: 'margin-top:.6rem' }, save, ' ', inherit, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:46rem', 'aria-label': `Job thresholds: ${jobName}` }, form);
  let done = false;
  dlg.addEventListener('close', () => { dlg.remove(); if (done) after(); });
  no.addEventListener('click', () => dlg.close());
  const send = async (op: 'set' | 'inherit') => {
    const body: Record<string, unknown> = { op, level, instance_id: level === 'root' ? undefined : instance, job_name: level === 'job' ? jobName : undefined };
    if (op === 'set') {
      for (const [k, i] of inputs) body[k] = i.value.trim() === '' ? null : Number(i.value);
      body.last_fail_is = lastFail.value === '' ? null : lastFail.value;
    }
    save.disabled = inherit.disabled = true;
    msg.textContent = 'Saving...';
    try {
      const r = await post<{ outcome: string; detail: string }>('jobs/thresholds', body);
      done = true;
      msg.replaceChildren(badge(r.outcome, 'ok'), ` ${r.detail}. Close to see the jobs judged again.`);
    } catch (e) {
      msg.replaceChildren(badge('not saved', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      save.disabled = false; inherit.disabled = false;   // a level that is off stays off the B7 way (fill set it)
    }
  };
  // off is off: Enter in a field submits the form too
  form.addEventListener('submit', ev => { ev.preventDefault(); if (!levelWhy(level)) void send('set'); });
  inherit.addEventListener('click', () => { void send('inherit'); });
  document.body.append(dlg);
  fill();
  dlg.showModal();
}

// jobsPanel: the one-line-per-job grid and, under it, the picked job's History and Changes. extra = the engine's own
// columns after the shared ones (the PostgreSQL page's database, user and command).
export async function jobsPanel(ctx: Ctx, engine: 'pg' | 'mssql', extra: Col[] = []): Promise<HTMLElement> {
  const w = window_(ctx);
  const box = el('div');
  const d = await get<Record<'jobs', Table | null>>('jobs/history', { engine, instance: ctx.instance, ...w });
  const jobs = rowsOf(d.jobs);
  // a column that decides something from the page's rows (the PostgreSQL page's Run now: is its sentence needed) gets
  // them before the grid draws - a long grid draws its first page only
  for (const c of extra) (c as Col & { rows?: (all: Row[]) => void }).rows?.(jobs);
  const ad = await loadAckSafe(['acks']);
  // the grid's Acknowledge buttons share one reason when they are off - a server that writes nothing at all, or on a
  // demo serve an instance that is not the demo's: said once above the grid, and every button points at that sentence
  // (given to each cell: where a door stands the page's note is not a control's default)
  // (drawn where a button will point at it: a failed job not yet acknowledged for that failure)
  const ackIsOff = !ackOn(ad, Number(ctx.instance)) && jobs.some(j => {
    if (j.last_failed_at == null || j.last_failed_at === '') return false;
    const a = jobAcks(ad).get(`${String(ctx.instance)}|${String(j.name)}`);
    return !(a && String(a.seen_state) === String(j.last_failed_at));
  });
  // the instance's name is read only where the sentence names it (a demo serve, an instance that is not the demo's);
  // a failed read of the instance list leaves the sentence with 'this instance', never the page without its grid
  const ackName = ackIsOff && ad.door
    ? await fleet().then(f => String(f.instances.find(r => Number(r.instance_id) === Number(ctx.instance))?.name ?? 'this instance'), () => undefined) : undefined;
  const ackWhyNot = ackIsOff ? ackWhy(ad, Number(ctx.instance), ackName) : null;
  // the instance's name for the thresholds dialog on a demo serve (its words name the instance)
  const doorName = ad.door ? ackName ?? await fleet().then(f => String(f.instances.find(r => Number(r.instance_id) === Number(ctx.instance))?.name ?? 'this instance'), () => undefined) : undefined;
  const ackOffP = ackWhyNot ? el('p', { class: 'meta' }, `Acknowledge is off: ${ackWhyNot}`) : null;
  if (ackOffP && !ad.door) ad.note = ackOffP;
  const ackRedraw = () => window.dispatchEvent(new HashChangeEvent('hashchange'));
  const th = await loadThresholds(Number(ctx.instance));
  const statusOf = new Map(rowsOf(th?.status).map(r => [`${String(r.scheduler)}|${String(r.job_id)}`, r]));
  const st = (r: Row) => statusOf.get(`${String(r.scheduler)}|${String(r.job_id)}`);
  const jobAcked = (r: Row) => { const a = jobAcks(ad).get(`${String(ctx.instance)}|${String(r.name)}`); return !!a && String(a.seen_state) === String(r.last_failed_at); };
  const detail = el('div', { class: 'jobdetail' });
  // a picked job's history and changes reach back a week at least: a daily job has no run in the default hour, and
  // DBA Dash's history lists a job's newest runs, not the last hour's; the jobs grid above keeps the page's range
  const week = 7 * 24 * 3600 * 1000, toMs = Date.parse(w.to);
  const widened = toMs - Date.parse(w.from) < week;
  const hw = widened ? { from: new Date(toMs - week).toISOString(), to: w.to } : w;
  // a preset reads 'last 7 days'; a custom range names the week that ends at its own 'to'
  const hLabel = !widened ? rangeLabel(ctx) : ctx.range.preset ? 'last 7 days' : `the 7 days to ${fmtTime(w.to)}`;
  // step: the step the history is cut to (SQL Server; jobs_chart.ts's step grid asks for it), unset = the job's own runs.
  // refocus: the pick came from a button inside the detail, which this redraw replaces: the new heading takes the focus
  let pickSeq = 0;
  const pick = async (j: Row, step?: number, refocus = false) => {
    const mine = ++pickSeq;   // a later pick wins over a slower earlier one
    const title = `${String(j.name)}${step != null ? `, step ${step}` : ''}: history (${hLabel})`;
    const head = () => { const h = el('h3', { tabindex: '-1' }, title); if (refocus) requestAnimationFrame(() => { if (h.isConnected) h.focus(); }); return h; };
    detail.replaceChildren(el('h3', {}, title), el('p', { class: 'meta' }, 'Reading...'));
    try {
      const x = await get<Record<'runs' | 'counts' | 'changes' | 'stats' | 'series' | 'series_meta', Table | null>>('jobs/history',
        { engine, instance: ctx.instance, ...hw, scheduler: String(j.scheduler), job: String(j.job_id), step, part: undefined });
      if (mine !== pickSeq) return;
      const runs = rowsOf(x.runs), c = rowsOf(x.counts)[0] ?? {};
      detail.replaceChildren(head(),
        el('div', { class: 'tiles' },
          tile('succeeded', fmtNum(c.succeeded ?? 0)),
          tile('failed', fmtNum(c.failed ?? 0), Number(c.failed) > 0 ? 'crit' : ''),
          tile('cancelled', fmtNum(c.cancelled ?? 0), Number(c.cancelled) > 0 ? 'warn' : ''),
          tile('running long (over 2x the median)', fmtNum(c.running_long ?? 0), Number(c.running_long) > 0 ? 'warn' : ''),
          tile('median good run', c.median_s == null ? 'n/a' : dur(c.median_s))),
        jobChartSection(x, { engine, step, onStep: s => { void pick(j, s, true); } }),
        strip(runs),
        Number(c.runs ?? 0) > runs.length ? el('p', { class: 'meta' }, `The newest ${fmtNum(runs.length)} of ${fmtNum(c.runs)} runs; the counts cover all of them.`) : '',
        grid(runs, runCols, j.last_run_at ? `No run of this job started in this window; its last start was ${fmtTime(j.last_run_at)} (the grid above).` : 'No run of this job started in this window.'),
        el('h3', {}, `${String(j.name)}: versions`),   // every kept version; the newest one's script opens
        versions(rowsOf(x.changes), String(j.name)));
    } catch (e) { if (mine === pickSeq) detail.replaceChildren(errorBox(e)); }
  };
  // status: the job against the thresholds in force for it, and the door to its three levels
  const statusCol = (t: Thresholds): Col => ({
    key: '_status', label: 'status',
    cls: (_v, r) => { const x = st(r); return x && !r.dropped_at ? `status ${String(x.status)}` : ''; },
    fmt: (_v, r) => {
      const x = st(r);
      if (r.dropped_at || !x) return '';
      const b = el('button', { class: 'link', type: 'button', 'aria-label': `Thresholds of ${String(r.name)}` }, 'Thresholds');
      b.addEventListener('click', () => thresholdsDialog(Number(ctx.instance), String(r.name), t, ackRedraw, ad, doorName));
      return el('span', { style: 'white-space:nowrap' },
        el('span', { title: x.reason ? String(x.reason) : `judged by the ${String(x.level)} level` }, statusWord(x) + (x.reason ? `: ${String(x.reason)}` : '')), ' ', b);
    },
  });
  const cols: Col[] = [
    { key: 'name', label: 'job', fmt: (v, r) => {
      const b = el('button', { class: 'link', type: 'button' }, String(v ?? ''));
      b.addEventListener('click', () => { void pick(r); });
      return b;
    } },
    { key: 'enabled', fmt: v => v == null ? '' : v ? 'yes' : badge('no', 'warn') },
    { key: 'schedule', fmt: oneLine },
    // the value cells carry the outcome's level, so the screen and the export show one colour
    { key: 'last_run_at', label: 'last run', fmt: fmtTime, cls: (v, r) => v == null || r.dropped_at ? '' : outcomeCls(r.last_outcome) },
    { key: 'last_duration_s', label: 'took', num: true, fmt: dur },
    { key: 'last_outcome', label: 'outcome', cls: (v, r) => r.dropped_at ? '' : outcomeCls(v),
      fmt: (v, r) => r.dropped_at ? el('span', {}, badge(`dropped ${fmtTime(r.dropped_at)}`, 'warn'), v ? ` (last run ${String(v)})` : '') : outcomeBadge(v) },
    ...(th ? [statusCol(th)] : []),
    { key: 'last_failure', label: 'last failure', fmt: (v, r) => v == null ? '' : el('span', {}, `${fmtTime(r.last_failed_at)}${r.failed_step ? ` step ${String(r.failed_step)}` : ''}: `, oneLine(v)) },
    { key: '_ack', label: 'acknowledged', fmt: (_v, r) => jobAckCell(ad, Number(ctx.instance), String(r.name), r.last_failed_at, ackRedraw, ackOffP ?? undefined, ackName) },
    { key: 'next_run', label: 'next run', fmt: (v, r) => v ? fmtTime(v) : r.dropped_at || r.enabled === false ? '' : !r.schedule ? 'no schedule' : '' },
    { key: 'runs', num: true },
    { key: 'failures', num: true, cls: (v, r) => Number(v) > 0 ? (jobAcked(r) ? '' : 'status crit') : 'status ok',
      fmt: (v, r) => Number(v) > 0 ? (jobAcked(r) ? `${fmtNum(v)} (acknowledged)` : badge(fmtNum(v), 'crit')) : '0' },
    { key: 'avg_s', label: 'average (good runs)', num: true, fmt: dur },
    { key: 'max_s', label: 'longest', num: true, fmt: dur },
    { key: 'changes', label: 'changed', num: true, fmt: (v, r) => Number(v) > 0 ? `${fmtNum(v)} (${fmtTime(r.last_change_at)})` : '' },
    ...extra,
  ];
  box.append(...(ackOffP ? [ackOffP] : []), grid(jobs, cols, 'No job on this server.'), detail);
  if (jobs.length) detail.append(el('p', { class: 'meta' }, 'Pick a job for its history and its versions (the script, the diff, the job as it was).'));
  return box;
}

const outcomeText = (v: unknown) => v === 0 ? 'failed' : v === 1 ? 'succeeded' : v === 2 ? 'retry' : v === 3 ? 'cancelled' : v === 4 ? 'in progress' : v === 5 ? 'never run' : '';

const failedCols: Col[] = [
  { key: 'run_at', label: 'run', fmt: fmtTime }, { key: 'job' },
  { key: 'step_id', label: 'step', num: true }, { key: 'step_name', label: 'step name' },
  { key: 'duration_s', label: 'took', num: true, fmt: fmtSecs },
  { key: 'sql_message_id', label: 'error', num: true, fmt: v => v == null || Number(v) === 0 ? '' : String(v) },
  { key: 'message', fmt: oneLine },
];

const stepCols: Col[] = [
  { key: 'step_id', label: 'step', num: true }, { key: 'step_name', label: 'name' }, { key: 'subsystem' },
  { key: 'database_name', label: 'database' },
  { key: 'last_outcome', label: 'last outcome', cls: v => v === 0 ? 'status crit' : v === 1 ? 'status ok' : '', fmt: v => v === 0 ? badge('failed', 'crit') : outcomeText(v) },
  { key: 'last_run_utc', label: 'last run', fmt: fmtTime, cls: (v, r) => v == null ? '' : r.last_outcome === 0 ? 'status crit' : r.last_outcome === 1 ? 'status ok' : '' },
  { key: 'last_duration_s', label: 'took', num: true, fmt: fmtSecs },
  { key: 'on_success', label: 'on success' }, { key: 'on_fail', label: 'on failure' },
  { key: 'command', fmt: oneLine },
];

const runningCols: Col[] = [
  { key: 'name', label: 'job' }, { key: 'running_since', label: 'started', fmt: fmtTime },
  { key: 'running_s', label: 'running for (at the read)', num: true, fmt: fmtSecs },
  { key: 'avg_duration_s', label: 'average of its good runs', num: true, fmt: fmtSecs },
  // task 177 D14: PerformanceMonitor's Running Jobs columns (the 95th percentile of the good runs, the run so far
  // against the average)
  { key: 'p95_duration_s', label: 'p95 of its good runs', num: true, fmt: fmtSecs },
  { key: 'pct_of_avg', label: '% of average', num: true, fmt: v => v == null ? '' : `${fmtNum(v)} %` },
  { key: 'good_runs', label: 'good runs (31 days)', num: true },
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
    // Start and Stop ride the actions door: where the instance has none they are off, with the reason said once above
    // the grid (the column's offNote) and each button pointing at it
    const act = await mssqlJobCol(ctx, () => window.dispatchEvent(new HashChangeEvent('hashchange')));
    // the panel hands the column its rows before it draws: the sentence is read after it, so it stands only where a
    // job's Start and Stop point at it
    const jobsBox = await jobsPanel(ctx, 'mssql', [{ key: 'owner' }, { key: 'category' }, act]);
    sec.append(el('h3', {}, `Jobs (read ${fmtTime(read.snapshot_at)})`), ...(act.offNote ? [act.offNote] : []), jobsBox);
    sec.append(el('h3', {}, 'Failed runs in this range'), grid(failed, failedCols, 'No job failed in this range.'));
    // the steps of each job as last read, one disclosure per job: reachable by keyboard, named by the job
    const withSteps = jobs.filter(j => jsonRows(j.steps).length);
    if (withSteps.length) {
      sec.append(el('h3', {}, 'Steps'));
      for (const j of withSteps) {
        const steps = jsonRows(j.steps);
        sec.append(el('details', {}, el('summary', {}, `${String(j.name)} (${steps.length} step${steps.length === 1 ? '' : 's'})`), grid(steps, stepCols)));
      }
    }
  } catch (e) {
    sec.append(errorBox(e));
  }
  return sec;
}
