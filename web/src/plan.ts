// The Plan page (task 40): an instance's captured plans (pg_store_plans, auto_explain from the log, the on-demand
// EXPLAIN, EXPLAIN ANALYZE through the actions door), one plan drawn by pev2 with its rule hits and why each
// matters, and the two EXPLAIN buttons. The page reads its own hash parameters, so a link from another tab only
// builds one with planHref:
//   plan=<plan_id>   one plan
//   qid=<queryid>    the plans of a pg_stat_statements statement (Statements)
//   shape=<key>      the plans of a statement shape (Slow queries: shape_key)
//   stmt=<text>      the statement to EXPLAIN (prefilled; Running queries and Slow queries pass it), db=<datname>
// pev2 (PostgreSQL licence, Dalibo) and Vue are a separate bundle under dist/pev2/, loaded only when a plan is
// drawn; it renders inside a shadow root with bootstrap's and pev2's styles, so neither reaches the rest of the UI.
import { get, post, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, props } from './ui';

interface Buttons { explain: boolean; explain_reason?: string; analyze: boolean; analyze_reason?: string }
interface PlansList { buttons: Buttons; shape: string | null; plans: Table | null }
interface PlanOne { plan: Table | null; hits: Table | null; buttons: Buttons }
interface Done { plan_id?: number; note?: string; plan_note?: string; outcome?: string; detail?: string }

const stmtMax = 4000;

// planHref is the link other tabs put beside a statement: the instance's Plans tab for that statement.
export function planHref(instance: number, o: { queryid?: unknown; shape?: unknown; stmt?: unknown; db?: unknown; plan?: unknown } = {}): string {
  const q = new URLSearchParams({ i: String(instance) });
  if (o.plan != null) q.set('plan', String(o.plan));
  if (o.queryid != null && o.queryid !== '') q.set('qid', String(o.queryid));
  if (o.shape != null && o.shape !== '') q.set('shape', String(o.shape));
  if (o.db != null && o.db !== '') q.set('db', String(o.db));
  if (o.stmt != null && o.stmt !== '') q.set('stmt', String(o.stmt).slice(0, stmtMax));
  return '#/plans?' + q.toString();
}

// planLink is the cell other grids use: "plan" linking to the statement's plans.
export function planLink(instance: number, o: Parameters<typeof planHref>[1]): HTMLElement {
  return el('a', { href: planHref(instance, o), title: 'Plans of this statement, and EXPLAIN' }, 'plan');
}

function hashParams(): URLSearchParams {
  return new URLSearchParams(location.hash.split('?')[1] ?? '');
}

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const msTxt = (v: unknown) => v == null || v === '' ? '' : Number(v) >= 1000 ? fmtNum(Number(v) / 1000) + ' s' : fmtNum(v) + ' ms';
const clip = (v: unknown, n = 200) => { const s = v == null ? '' : String(v).replace(/\s+/g, ' '); return s.length > n ? s.slice(0, n) + '...' : s; };
const sources: Record<string, string> = { pg_store_plans: 'pg_store_plans', auto_explain: 'auto_explain (log)', explain: 'EXPLAIN', explain_analyze: 'EXPLAIN ANALYZE' };

// plansView: the instance's Plans tab, or one plan with plan=<id>.
export async function plansView(ctx: Ctx): Promise<HTMLElement> {
  const p = hashParams();
  const id = Number(p.get('plan'));
  if (id > 0) return planView(ctx, id);
  const w = window_(ctx);
  const qid = p.get('qid') ?? undefined, shape = p.get('shape') ?? undefined, stmt = p.get('stmt') ?? undefined;
  const d = await get<PlansList>('plans', { instance: ctx.instance, from: w.from, to: w.to, queryid: qid, shape, q: !qid && !shape ? stmt : undefined });
  const rows = rowsOf(d.plans);
  const out = el('div', { class: 'plans' });
  const scope = qid ? `the plans of queryid ${qid} (any age)` : shape || stmt ? 'the plans of this statement shape (any age)' : 'the plans captured in the window';
  out.append(el('h3', {}, 'Plans'), el('p', { class: 'meta' }, `Showing ${scope}. Sources: pg_store_plans where installed, auto_explain lines in the server log, `
    + 'and the EXPLAIN buttons below. A rule names what went wrong in a plan and why it matters; a scan or a nested loop alone is never one.'));
  const cols: Col[] = [
    { key: 'plan_id', label: 'plan', fmt: v => el('a', { href: planHref(ctx.instance!, { plan: v }) }, String(v)) },
    { key: 'captured_at', label: 'captured', fmt: fmtTime },
    { key: 'source', fmt: v => sources[String(v)] ?? String(v ?? '') },
    { key: 'datname', label: 'database' },
    { key: 'usename', label: 'role' },
    { key: 'duration_ms', label: 'duration', num: true, fmt: msTxt },
    { key: 'calls', num: true },
    { key: 'total_ms', label: 'total time', num: true, fmt: msTxt },
    { key: 'analyzed', label: 'actual', fmt: v => v ? 'yes' : 'estimate' },
    { key: 'hits', label: 'rule hits', num: true, fmt: (v, r) => Number(v) > 0 ? badge(String(v), 'warn') : el('span', { class: 'meta', title: String(r.plan_note ?? '') }, '0') },
    { key: 'rules', wide: true },
    { key: 'query', label: 'statement', wide: true, fmt: v => clip(v) },
  ];
  out.append(grid(rows, cols, 'No plan captured yet: pg_store_plans is not installed, auto_explain wrote nothing in the window, and no EXPLAIN was run here.'));
  out.append(explainForm(ctx, d.buttons, stmt ?? '', p.get('db') ?? ''));
  return out;
}

// explainForm: the statement, its database, and the two buttons (each disabled with its reason).
function explainForm(ctx: Ctx, b: Buttons, stmt: string, db: string): HTMLElement {
  const box = el('div', { class: 'card' });
  const text = el('textarea', { rows: '6', style: 'width:100%;font-family:monospace', 'aria-label': 'Statement to explain' }) as HTMLTextAreaElement;
  text.value = stmt;
  const dbIn = el('input', { type: 'text', value: db, placeholder: 'database (empty: the dsn\'s)', 'aria-label': 'Database', style: 'width:16em' }) as HTMLInputElement;
  const reason = el('input', { type: 'text', placeholder: 'reason (for the actions log)', 'aria-label': 'Reason for EXPLAIN ANALYZE', style: 'width:24em' }) as HTMLInputElement;
  const msg = el('p', { class: 'meta', role: 'status' });
  const go = (path: string, body: Record<string, unknown>) => async () => {
    msg.textContent = 'Working...';
    try {
      const r = await post<Done>(path, { instance_id: ctx.instance, datname: dbIn.value.trim(), statement: text.value, ...body });
      if (r.plan_id) location.hash = planHref(ctx.instance!, { plan: r.plan_id }).slice(1);
      else msg.textContent = [r.detail, r.note].filter(Boolean).join(' ');
    } catch (e) { msg.replaceChildren(errorBox(e)); }
  };
  const btnExplain = el('button', { type: 'button' }, 'EXPLAIN (no execution)') as HTMLButtonElement;
  btnExplain.disabled = !b.explain;
  btnExplain.title = b.explain ? 'Plans the statement through the monitoring login without running it; a statement with $n parameters gets its generic plan' : b.explain_reason ?? '';
  btnExplain.addEventListener('click', go('plans/explain', {}));
  const btnAnalyze = el('button', { type: 'button', class: 'danger' }, 'EXPLAIN ANALYZE (runs it)') as HTMLButtonElement;
  btnAnalyze.disabled = !b.analyze;
  btnAnalyze.title = b.analyze ? 'Runs the SELECT through the actions login in a read-only transaction, rolled back, under a timeout; audited' : b.analyze_reason ?? '';
  btnAnalyze.addEventListener('click', () => {
    const typed = prompt('EXPLAIN ANALYZE executes the statement on the server. Type analyze to run it.');
    if (typed == null) return;
    void go('plans/analyze', { reason: reason.value, confirm: typed })();
  });
  box.append(el('h3', {}, 'EXPLAIN'), text, el('div', { class: 'row' }, dbIn, ' ', btnExplain, ' ', reason, ' ', btnAnalyze));
  if (!b.explain) box.append(el('p', { class: 'meta' }, 'EXPLAIN is off: ' + (b.explain_reason ?? '')));
  else if (!b.analyze) box.append(el('p', { class: 'meta' }, 'EXPLAIN ANALYZE is off: ' + (b.analyze_reason ?? '')));
  box.append(msg);
  return box;
}

const hitCols: Col[] = [
  { key: 'severity', fmt: sevBadge },
  { key: 'rule' },
  { key: 'node_type', label: 'node', fmt: (v, r) => `${String(v ?? '')} (${String(r.node_path ?? '')})` },
  { key: 'object' },
  { key: 'value', label: 'what', wide: true },
  { key: 'why', label: 'why it matters', wide: true },
  { key: 'suggested', label: 'what to try', wide: true },
];

// planView: one plan: its facts, its rule hits, the plan drawn by pev2 (the text below it as a fallback).
async function planView(ctx: Ctx, id: number): Promise<HTMLElement> {
  const d = await get<PlanOne>('plan', { id });
  const p: Row = rowsOf(d.plan)[0] ?? {};
  const hits = rowsOf(d.hits);
  const out = el('div', { class: 'plan' });
  out.append(el('p', {}, el('a', { href: planHref(ctx.instance!, { queryid: p.queryid ?? undefined, db: p.datname ?? undefined, stmt: p.query ?? undefined }) }, 'All plans of this statement, and EXPLAIN')));
  out.append(el('h3', {}, `Plan ${id}`), props([
    ['source', sources[String(p.source)] ?? String(p.source ?? '')],
    ['captured', fmtTime(p.captured_at) + (p.first_seen && p.first_seen !== p.captured_at ? ` (first ${fmtTime(p.first_seen)})` : '')],
    ['database / role', [p.datname, p.usename].filter(Boolean).join(' / ')],
    ['queryid / planid', [p.queryid, p.planid].filter(v => v != null).join(' / ')],
    ['duration', msTxt(p.duration_ms ?? p.execution_ms)],
    ['planning', msTxt(p.planning_ms)],
    ['calls / total', p.calls != null ? `${fmtNum(p.calls)} / ${msTxt(p.total_ms)}` : ''],
    ['actual numbers', p.analyzed ? 'yes (ANALYZE)' : 'no: an estimate only; the rules that need actual rows and times are silent'],
    ['note', String(p.plan_note ?? '')],
  ]));
  out.append(el('h3', {}, 'Rule hits'), grid(hits, hitCols, p.plan_note && String(p.plan_note).startsWith('the plan could not')
    ? 'The plan could not be read, so no rule ran.' : 'No rule hit: nothing in this plan matches the ten rules.'));
  const viewer = el('div', { class: 'pev2-host', style: 'height:70vh;min-height:420px;border:1px solid var(--line);background:#fff' });
  const raw = el('details', {}, el('summary', {}, 'The plan as captured'), el('pre', { style: 'white-space:pre;overflow:auto;max-height:50vh' }, String(p.plan_text ?? '')));
  out.append(el('h3', {}, 'Plan'), viewer, raw, el('p', { class: 'meta' }, 'Plan viewer: pev2 (Dalibo, PostgreSQL licence).'));
  void mountPev2(viewer, String(p.plan_text ?? ''), String(p.query ?? '')).catch(e => viewer.replaceChildren(errorBox(e)));
  return out;
}

interface Vue { createApp(root: unknown): { mount(el: Element): unknown }; h(c: unknown, props: Record<string, unknown>): unknown }
interface Pev2 { Plan: unknown }

let sheets: Promise<CSSStyleSheet[]> | null = null;

// styles: bootstrap's, pev2's and fontawesome's sheets, their :root rules moved to the shadow host.
function styles(): Promise<CSSStyleSheet[]> {
  sheets ??= Promise.all(['pev2/bootstrap.min.css', 'pev2/pev2.css', 'pev2/fontawesome.css'].map(async u => {
    const res = await fetch(u, { credentials: 'same-origin' });
    if (!res.ok) throw new Error(`${u}: ${res.status}`);
    const s = new CSSStyleSheet();
    s.replaceSync((await res.text()).replace(/:root/g, ':host'));
    return s;
  }));
  return sheets;
}

// frame: the viewer fills its host (pev2 sizes itself to its parent's height)
function frame(): CSSStyleSheet {
  const s = new CSSStyleSheet();
  // the container is styled by the attribute Vue sets on it at mount (it keeps neither a class nor every inline rule)
  s.replaceSync(':host { display: block; } [data-v-app] { display: flex; flex-direction: column; height: 100%; color: #212529; } '
    + '.plan-container { flex: 1 1 auto; min-height: 0; }');
  return s;
}

// mountPev2 loads the viewer bundle (once) and draws the plan inside a shadow root of host.
async function mountPev2(host: HTMLElement, planText: string, query: string): Promise<void> {
  if (!planText) { host.replaceChildren(el('p', { class: 'empty' }, 'No plan text.')); return; }
  const base = document.baseURI;
  const [vue, pev2, css] = await Promise.all([
    import(/* the viewer bundle, not bundled into app.js */ new URL('pev2/vue.js', base).href) as Promise<Vue>,
    import(new URL('pev2/pev2.js', base).href) as Promise<Pev2>,
    styles(),
  ]);
  const root = host.shadowRoot ?? host.attachShadow({ mode: 'open' });
  root.adoptedStyleSheets = [...css, frame()];
  const mount = document.createElement('div');
  mount.style.height = '100%';
  root.replaceChildren(mount);
  vue.createApp({ render: () => vue.h(pev2.Plan, { planSource: planText, planQuery: query }) }).mount(mount);
}
