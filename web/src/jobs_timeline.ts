// The jobs timeline on both engines (parity2 task 121; DBA Dash 71 and 90): one row per job with its runs as bars
// on the page's time axis, a failed run in red and a red count beside the job, a 'Running at once' lane with its
// peak, and a time cursor that follows the pointer (or the arrow keys) and says how many jobs run at that moment.
// A job's name cuts the timeline to that job (DBA Dash 90): a SQL Server job then shows its steps as lanes. An
// Outcome filter and a job name filter; the same runs as a table under the drawing. On an instance (pg_cron,
// pgAgent or SQL Server Agent) or the fleet (both engines, grouped by instance). Data from /api/jobs/timeline.
// The lead mounts jobsTimelineView(ctx) as its own page reached from the Jobs folder.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { fmt, offsetMin } from './tz';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid } from './ui';

const NS = 'http://www.w3.org/2000/svg';
function svg<K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number> = {}, ...kids: (Node | string)[]): SVGElementTagNameMap[K] {
  const e = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
  for (const k of kids) e.append(k);
  return e;
}

const LABEL = 240, ROW = 22, LANE = 34, AXIS = 22;
const colorOf = (outcome: unknown) => outcome === 'failed' ? 'var(--crit)' : outcome === 'running' ? 'var(--accent)'
  : outcome === 'succeeded' ? 'var(--ok)' : outcome === 'unknown' ? 'var(--muted)' : 'var(--warn)';
const outcomeBadge = (v: unknown) => {
  const s = String(v ?? '');
  return s === 'failed' ? badge(s, 'crit') : s === 'succeeded' ? badge(s, 'ok') : s ? badge(s, 'warn') : '';
};
const timeOf = (v: unknown) => v == null ? NaN : new Date(String(v)).getTime();

interface Run { r: Row; s: number; e: number }
interface Lane { key: string; label: string; instance: string; instanceId: number; scheduler: string; jobId: string; runs: Run[]; failed: number }

// atOnce: the number of runs going on over time as steps [t, n] (a sweep over starts and ends), and its peak
export function atOnce(runs: { s: number; e: number }[]): { steps: [number, number][]; peak: number } {
  const ev: [number, number][] = [];
  // a run of no length (SQL Agent counts whole seconds: a job under a second ends where it starts) lasts 1 ms, as the
  // cursor counts it: never a negative count, never a peak of 0 under a drawn bar
  for (const x of runs) { ev.push([x.s, 1]); ev.push([Math.max(x.e, x.s + 1), -1]); }
  ev.sort((a, b) => a[0] - b[0] || a[1] - b[1]);   // an end before a start at the same instant: back to back is not at once
  const steps: [number, number][] = [];
  let n = 0, peak = 0;
  for (const [t, d] of ev) { n += d; peak = Math.max(peak, n); steps.push([t, n]); }
  return { steps, peak };
}
const runningAt = (runs: Run[], t: number) => runs.filter(x => x.s <= t && t < Math.max(x.e, x.s + 1)).length;

// the axis ticks: a step from a fixed ladder giving about eight ticks
const ladder = [60, 300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400, 172800, 604800, 1209600, 2592000, 7776000].map(s => s * 1000);
function ticks(t0: number, t1: number): number[] {
  const step = ladder.find(s => (t1 - t0) / s <= 9) ?? ladder[ladder.length - 1];
  const off = -offsetMin(new Date(t0)) * 60000;   // ticks on the display zone's round times
  const out: number[] = [];
  for (let t = Math.ceil((t0 - off) / step) * step + off; t <= t1; t += step) out.push(t);
  return out;
}
const tickLabel = (t: number, span: number) => fmt(new Date(t), span > 2 * 86400000
  ? { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false } : { hour: '2-digit', minute: '2-digit', hour12: false });

function lanesOf(runs: Row[], now: number): Lane[] {
  const by = new Map<string, Lane>();
  for (const r of runs) {
    const key = `${String(r.instance_id)}|${String(r.scheduler)}|${String(r.job_id)}`;
    let l = by.get(key);
    if (!l) {
      l = { key, label: String(r.job ?? r.job_id), instance: String(r.instance ?? ''), instanceId: Number(r.instance_id), scheduler: String(r.scheduler),
            jobId: String(r.job_id), runs: [], failed: 0 };
      by.set(key, l);
    }
    const s = timeOf(r.start_time);
    if (!isFinite(s)) continue;
    const e = r.end_time == null ? now : timeOf(r.end_time);
    l.runs.push({ r, s, e: isFinite(e) ? e : s });
    if (r.outcome === 'failed') l.failed++;
  }
  return [...by.values()].sort((a, b) => a.instance.localeCompare(b.instance) || (b.failed - a.failed) || a.label.localeCompare(b.label));
}

// drawTimeline: the SVG for the lanes over [t0, t1]; onJob makes a job name a button (null = names stay text).
function drawTimeline(lanes: Lane[], t0: number, t1: number, width: number, fleet: boolean, onJob: ((l: Lane) => void) | null): HTMLElement {
  const all = lanes.flatMap(l => l.runs.map(x => ({ s: Math.max(x.s, t0), e: Math.min(x.e, t1) })));
  const { steps, peak } = atOnce(all);
  const W = Math.max(LABEL + 200, width), plotW = W - LABEL - 8;
  const X = (t: number) => LABEL + Math.max(0, Math.min(plotW, (t - t0) / (t1 - t0) * plotW));
  // rows: the lane, then per instance (fleet) a heading row, then its jobs
  type Line = { kind: 'inst'; text: string } | { kind: 'job'; lane: Lane };
  const lines: Line[] = [];
  let lastInst = '';
  for (const l of lanes) {
    if (fleet && l.instance !== lastInst) { lines.push({ kind: 'inst', text: l.instance }); lastInst = l.instance; }
    lines.push({ kind: 'job', lane: l });
  }
  const H = AXIS + LANE + lines.length * ROW + 6;
  // a group, not an img: an img's children are presentational, and the job names are buttons (axe nested-interactive)
  const root = svg('svg', { width: W, height: H, viewBox: `0 0 ${W} ${H}`, role: 'group', 'aria-label': `Jobs timeline: ${lanes.length} jobs, ${all.length} runs, at most ${peak} at once` });
  root.style.display = 'block';
  // the axis and its grid lines
  const span = t1 - t0;
  for (const t of ticks(t0, t1)) {
    root.append(svg('line', { x1: X(t), x2: X(t), y1: AXIS - 4, y2: H, stroke: 'var(--line)', 'stroke-width': 1 }),
      svg('text', { x: X(t), y: AXIS - 8, 'text-anchor': 'middle', 'font-size': 11, fill: 'var(--muted)' }, tickLabel(t, span)));
  }
  // the running-at-once lane: a step area, its peak in the label
  const laneY = AXIS, laneH = LANE - 8;
  root.append(svg('text', { x: 4, y: laneY + 13, 'font-size': 12, fill: 'var(--muted)' }, 'Running at once'),
    svg('text', { x: 4, y: laneY + 27, 'font-size': 12, fill: 'var(--fg)' }, `peak ${peak}`));
  if (peak > 0) {
    let d = `M ${X(t0)} ${laneY + laneH}`, n = 0;
    for (const [t, c] of steps) { d += ` L ${X(t)} ${laneY + laneH - n / peak * laneH} L ${X(t)} ${laneY + laneH - c / peak * laneH}`; n = c; }
    d += ` L ${X(t1)} ${laneY + laneH - n / peak * laneH} L ${X(t1)} ${laneY + laneH} Z`;
    root.append(svg('path', { d, fill: 'var(--accent)', 'fill-opacity': 0.35, stroke: 'var(--accent)', 'stroke-width': 1 }));
  }
  root.append(svg('line', { x1: 0, x2: W, y1: AXIS + LANE - 2, y2: AXIS + LANE - 2, stroke: 'var(--line)' }));
  // the rows
  lines.forEach((ln, i) => {
    const y = AXIS + LANE + i * ROW;
    if (ln.kind === 'inst') {
      root.append(svg('text', { x: 4, y: y + 15, 'font-size': 12, 'font-weight': 700, fill: 'var(--fg)' }, ln.text));
      return;
    }
    const l = ln.lane;
    const name = svg('text', { x: fleet ? 14 : 4, y: y + 15, 'font-size': 12, fill: onJob ? 'var(--accent)' : 'var(--fg)' },
      l.label.length > 30 ? l.label.slice(0, 29) + '...' : l.label);
    name.append(svg('title', {}, `${l.label} (${l.scheduler})${onJob ? ': show only this job' : ''}`));
    if (onJob) {
      name.setAttribute('tabindex', '0'); name.setAttribute('role', 'button'); name.style.cursor = 'pointer';
      name.addEventListener('click', () => onJob(l));
      name.addEventListener('keydown', ev => { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); onJob(l); } });
    }
    root.append(name);
    if (l.failed) {
      root.append(svg('circle', { cx: LABEL - 14, cy: y + 11, r: 8, fill: 'var(--crit)' }),
        svg('text', { x: LABEL - 14, y: y + 15, 'text-anchor': 'middle', 'font-size': 10, 'font-weight': 700, fill: '#fff' }, String(l.failed)));
    }
    for (const x of l.runs) {
      const a = X(Math.max(x.s, t0)), b = X(Math.min(x.e, t1));
      const rect = svg('rect', { x: a, y: y + 4, width: Math.max(3, b - a), height: ROW - 8, rx: 1, fill: colorOf(x.r.outcome) });
      rect.append(svg('title', {}, `${l.label}: ${String(x.r.outcome)} - started ${fmtTime(x.r.start_time)}, took ${fmtSecs(x.r.duration_s)}`
        + (x.r.failed_step ? `, failed step ${String(x.r.failed_step)}` : '') + (x.r.message ? `\n${String(x.r.message)}` : '')));
      root.append(rect);
    }
  });
  // the time cursor: a line and a label that follow the pointer, or the arrow keys when the drawing has the focus
  const all2 = lanes.flatMap(l => l.runs);
  const cur = svg('line', { y1: AXIS - 2, y2: H, stroke: 'var(--accent)', 'stroke-dasharray': '3 3', visibility: 'hidden' });
  // read aloud only on a keyboard move: a pointer crossing the drawing would flood a screen reader
  const tag = el('div', { class: 'meta', 'aria-live': 'off' }, 'Point at the timeline (or focus it and use the arrow keys) for the time cursor.');
  let at = t0 + span / 2;
  const move = (t: number, keyboard = false) => {
    tag.setAttribute('aria-live', keyboard ? 'polite' : 'off');
    at = Math.max(t0, Math.min(t1, t));
    cur.setAttribute('x1', String(X(at))); cur.setAttribute('x2', String(X(at))); cur.setAttribute('visibility', 'visible');
    const n = runningAt(all2, at);
    tag.textContent = `${fmt(new Date(at))}: ${n} job${n === 1 ? '' : 's'} running`;
  };
  root.append(cur);
  root.addEventListener('mousemove', ev => {
    const box = root.getBoundingClientRect();
    const px = (ev.clientX - box.left) * (W / box.width);
    if (px >= LABEL) move(t0 + (px - LABEL) / plotW * span);
  });
  root.setAttribute('tabindex', '0');
  root.addEventListener('keydown', ev => {
    if (ev.key === 'ArrowLeft' || ev.key === 'ArrowRight') { ev.preventDefault(); move(at + (ev.key === 'ArrowLeft' ? -1 : 1) * span / 100, true); }
  });
  root.addEventListener('focus', () => move(at, true));
  return el('div', {}, tag, el('div', { class: 'grid-wrap', style: 'overflow-x:auto' }, root));
}

const runCols = (fleet: boolean): Col[] => [
  ...(fleet ? [{ key: 'instance' } as Col] : []),
  { key: 'job' }, { key: 'scheduler' }, { key: 'start_time', label: 'start', fmt: fmtTime },
  { key: 'end_time', label: 'end', fmt: v => v == null ? 'running' : fmtTime(v) },
  { key: 'duration_s', label: 'took', num: true, fmt: fmtSecs }, { key: 'outcome', fmt: outcomeBadge },
  { key: 'failed_step', label: 'failed step' }, { key: 'message', wide: true },
];
const stepCols: Col[] = [
  { key: 'step_id', label: 'step', num: true }, { key: 'step_name', label: 'name' }, { key: 'start_time', label: 'start', fmt: fmtTime },
  { key: 'duration_s', label: 'took', num: true, fmt: fmtSecs }, { key: 'outcome', fmt: outcomeBadge }, { key: 'message', wide: true },
];

// keep: under a tag folder of the fleet, only these instances' runs (the lead's wiring passes the folder's filter)
export async function jobsTimelineView(ctx: Ctx, keep?: (r: Row) => boolean): Promise<HTMLElement> {
  const fleet = !ctx.instance;
  const sec = el('section', {}, el('h2', {}, `Jobs timeline (${rangeLabel(ctx)})`));
  const body = el('div', {}, el('p', { class: 'meta' }, 'Reading...'));
  let outcome = '', filter = '';
  let picked: Lane | null = null;
  const w = window_(ctx), t0 = timeOf(w.from), t1 = timeOf(w.to);

  let seq = 0;   // a reply that arrives after a newer request (a quick filter change) is dropped
  async function draw() {
    const mine = ++seq;
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    try {
      const p: Record<string, string | number | undefined> = { instance: ctx.instance, ...w };
      if (picked) { p.scheduler = picked.scheduler; p.job = picked.jobId; }
      const d = await get<Record<'runs' | 'meta' | 'steps', Table | null>>('jobs/timeline', p);
      if (mine !== seq) return;
      const now = Math.min(Date.now(), t1);
      let runs = rowsOf(d.runs);
      if (keep) runs = runs.filter(keep);
      const meta = rowsOf(d.meta)[0] ?? {};
      if (outcome) runs = runs.filter(r => outcome === 'other' ? !['succeeded', 'failed', 'running'].includes(String(r.outcome)) : r.outcome === outcome);
      if (filter) { const f = filter.toLowerCase(); runs = runs.filter(r => String(r.job ?? '').toLowerCase().includes(f)); }
      const lanes = lanesOf(runs, now);
      const failed = lanes.reduce((a, l) => a + l.failed, 0);
      const width = Math.max(600, (sec.clientWidth || body.clientWidth || 1100) - 4);
      const tools = el('div', { class: 'toolbar' });
      const oc = el('select', { 'aria-label': 'Outcome' });
      for (const [v, l] of [['', 'all outcomes'], ['failed', 'failed'], ['succeeded', 'succeeded'], ['running', 'running'], ['other', 'cancelled, retry or unknown']]) {
        const o = el('option', { value: v }, l); if (v === outcome) o.selected = true; oc.append(o);
      }
      oc.addEventListener('change', () => { outcome = oc.value; void draw(); });
      const fi = el('input', { type: 'search', placeholder: 'Filter jobs', 'aria-label': 'Filter jobs', value: filter });
      fi.addEventListener('change', () => { filter = fi.value; void draw(); });
      tools.append(el('label', {}, 'Outcome ', oc), fi);
      if (picked) {
        const back = el('button', { type: 'button' }, 'All jobs');
        back.addEventListener('click', () => { picked = null; void draw(); });
        tools.append(el('span', {}, `Job: ${picked.label} `), back);
      }
      const head = el('p', { class: 'meta' }, `${fmtNum(lanes.length)} job${lanes.length === 1 ? '' : 's'}, ${fmtNum(runs.length)} runs, `,
        failed ? badge(`${failed} failed`, 'crit') : '0 failed',
        Number(meta.matched) > Number(meta.listed) ? `; the newest ${fmtNum(meta.listed)} of ${fmtNum(meta.matched)} runs drawn` : '');
      const parts: (Node | string)[] = [tools, head];
      if (!lanes.length) parts.push(el('p', { class: 'empty' }, picked ? 'This job has no run in this window.' : 'No job run in this window.'));
      else parts.push(drawTimeline(lanes, t0, t1, width, fleet, fleet ? null : l => { picked = l; void draw(); }));
      // one SQL Server job: its steps as lanes (DBA Dash 90's '1 : step 1 ok', '2 : step 2 fails')
      const steps = rowsOf(d.steps);
      if (picked && steps.length) {
        const sl = lanesOf(steps.map(s => ({ ...s, instance_id: picked!.instanceId, scheduler: 'step', job_id: s.step_id,
          job: `${String(s.step_id)} : ${String(s.step_name ?? '')}` })), now).sort((a, b) => Number(a.jobId) - Number(b.jobId));
        parts.push(el('h3', {}, 'Steps'), drawTimeline(sl, t0, t1, width, false, null),
          el('details', {}, el('summary', {}, 'The steps as a table'), grid(steps, stepCols, 'No step rows.')));
      } else if (picked && picked.scheduler !== 'sqlagent') {
        parts.push(el('p', { class: 'meta' }, 'pg_cron has no steps, and pgAgent\'s step log is not kept per run: the failed step is on the run.'));
      }
      parts.push(el('details', {}, el('summary', {}, 'The runs as a table'), grid(runs, runCols(fleet), 'No job run in this window.')));
      if (fleet) parts.push(el('p', { class: 'meta' }, 'Open an instance\'s timeline to cut it to one job.'));
      body.replaceChildren(...parts);
    } catch (e) {
      if (mine === seq) body.replaceChildren(errorBox(e));
    }
  }
  sec.append(body);
  // drawn once the section is on the page, so the drawing takes its width
  requestAnimationFrame(() => { void draw(); });
  return sec;
}
