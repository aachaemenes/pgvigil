// Custom tools (parity set 3, task 8; DBA Dash's Custom Tools folder, L169): an instance's own functions (PostgreSQL)
// or procedures (SQL Server) in the schema pgvigil_tools of the database its read login connects to, listed and run
// as tools - read-only, as that login, each run audited (internal/web/q_customtools.go).
// Data: GET /api/customtools?instance=N; POST /api/customtools/run {instance_id, tool, params}.
// The page: #/customtools?i=N (the instance's tab), &tool=<name> one tool's form and its run.
import { get, post, Row } from './api';
import { Ctx } from './router';
import { el, errorBox, grid, offControl } from './ui';
import { InstanceRun, resultView } from './customreports';
import { Can, routeWhy } from './needs';

interface ToolParam { name: string; type: string }
interface Tool { name: string; arguments: string; result: string; description: string; params: ToolParam[] }
interface Reply { instance: string; engine: string; tools: Tool[]; off?: string; none?: string; run_off?: string; can?: Can | null }

// a parameter's key in the run's body: its name (SQL Server's without its '@'), or $<n> for an unnamed argument
const keyOf = (p: ToolParam, i: number) => p.name ? p.name.replace(/^@/, '') : `$${i + 1}`;

export async function customToolsView(ctx: Ctx): Promise<HTMLElement> {
  const q = new URLSearchParams(location.hash.split('?')[1] ?? '');
  const sec = el('section', {}, el('h2', {}, 'Custom tools'));
  if (!ctx.instance) { sec.append(el('p', { class: 'empty' }, 'Custom tools are an instance\'s own: open them under an instance.')); return sec; }
  let d: Reply;
  try { d = await get<Reply>('customtools', { instance: ctx.instance }); } catch (e) { sec.append(errorBox(e)); return sec; }
  const db = d.engine === 'sqlserver' ? 'procedures (SQL Server)' : 'functions (PostgreSQL)';
  sec.append(el('p', { class: 'meta' }, `The ${db} in the schema pgvigil_tools of the database ${d.instance}'s read login connects to: `
    + 'a DBA makes the schema and its tools. Each runs read-only, as the read login, at most 60 s, and each run is audited (the custom reports\' log). '
    + 'Who runs them: every role that runs a community tool (an operator or an admin); there is no role per tool.'));
  if (d.off) { sec.append(el('p', { class: 'meta off-reason said' }, d.off)); return sec; }
  const want = q.get('tool');
  const t = want ? d.tools.find(x => x.name === want) : undefined;
  if (!t) {
    if (want) sec.append(el('p', { class: 'meta' }, `${d.instance} has no tool ${want} its read login may execute.`));
    sec.append(grid(d.tools as unknown as Row[], [
      { key: 'name', label: 'tool', fmt: v => el('a', { href: `#/customtools?i=${ctx.instance}&tool=${encodeURIComponent(String(v))}` }, String(v)) },
      { key: 'arguments', fmt: (v, r) => String(v || (r.params as ToolParam[]).map(p => `${p.name} ${p.type}`.trim()).join(', ')) },
      { key: 'result', wide: true }, { key: 'description', wide: true },
    ], d.none ?? 'No tool.'));
    return sec;
  }
  // one tool: its parameters (empty = the tool's own default, or NULL for an unnamed argument), Run, the result
  sec.append(el('p', {}, el('a', { href: `#/customtools?i=${ctx.instance}` }, 'Custom tools'), ` / ${t.name}`));
  if (t.description) sec.append(el('p', {}, t.description));
  const inputs = t.params.map((p, i) => el('input', { type: 'text', name: keyOf(p, i), 'aria-label': keyOf(p, i), placeholder: p.type }) as HTMLInputElement);
  const runBtn = el('button', { type: 'button' }, 'Run');
  const why = d.run_off || routeWhy('customtools/run', d.can) || '';
  const runOff = el('p', { class: 'meta off-reason' }, why);
  if (why) offControl(runBtn, why, runOff);
  const status = el('p', { class: 'meta', role: 'status' }), out = el('div', {});
  sec.append(el('div', { class: 'toolbar' }, ...t.params.map((p, i) => el('label', {}, `${keyOf(p, i)} (${p.type}) `, inputs[i])), runBtn),
    ...(why ? [runOff] : []), status, out);
  runBtn.addEventListener('click', async () => {
    if (runBtn.getAttribute('aria-disabled') === 'true') return;
    const params: Record<string, string> = {};
    t.params.forEach((p, i) => { params[keyOf(p, i)] = inputs[i].value; });
    status.textContent = 'Running...';
    offControl(runBtn, 'running', status);
    try {
      const r = await post<{ runs: InstanceRun[] }>('customtools/run', { instance_id: ctx.instance, tool: t.name, params });
      out.replaceChildren(resultView(r.runs, undefined, t.name));
      status.textContent = '';
    } catch (e) { out.replaceChildren(errorBox(e)); status.textContent = ''; }
    finally { offControl(runBtn, why || null, why ? runOff : status); }
  });
  return sec;
}
