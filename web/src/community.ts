// Community tools (task 170, task 93 (a); DBA Dash's Community Tools): run a community procedure a DBA installed on a
// SQL Server instance (sp_WhoIsActive, the First Responder Kit, Erik Darling's procedures) with its own parameters as
// a form, Glenn Berry's diagnostic queries from the DBA's own copy of his script, or on a PostgreSQL instance pgvigil's
// own diagnostic reads; each result set in pgvigil's grid (its menus, the export, the grid tools). pgvigil never
// installs a procedure: a missing one says where to get it. Every run is read-only on the instance's read login,
// under a timeout, and audited (the log below).
// Data: GET /api/community?instance=N&database=D, POST /api/community/params, /api/community/run and
// /api/community/glenn/parse (internal/web/q_community.go).
// The shell mounts communityView(ctx): an instance tab 'community' (ctx.instance) and a root tab with an instance picker
// (the lead wires the route and the tabs).
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';
import { InstanceRun, resultView, ResultSet, setGrid } from './customreports';

// a need: what the tool lacks here before it can run and the way to get it (hard = the tool cannot run without it)
interface Need { what: string; how?: string; hard: boolean }
interface Tool { id: string; name: string; group: string; engine: string; kind: string; url?: string; description: string; help?: string; installed: boolean | null; where?: string; params?: { name: string; type: string; label?: string; default?: string }[]; needs?: Need[] }
interface Tools { enabled: boolean; reason?: string; instance: string; engine: string; database?: string; error?: string; tools: Tool[]; log: Table | null; needs?: Need[] }
interface ProcParam { name: string; type: string; max_length: number; help?: string }
interface Params { installed: boolean; params: ProcParam[]; left_out: string[]; help_sets: ResultSet[]; help_error?: string; static_params?: { name: string; type: string; label?: string; default?: string }[] }
interface GlennQuery { n: number; name: string; about: string; text: string }

const logCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'ui_user', label: 'who' },
  { key: 'op', label: 'what', fmt: v => v === 'community_help' ? 'help' : 'run' },
  { key: 'tool' },
  { key: 'outcome', fmt: v => badge(String(v ?? ''), v === 'done' ? 'ok' : v === 'refused' ? 'warn' : 'crit') },
  { key: 'rows', num: true },
  { key: 'duration_ms', label: 'took (ms)', num: true },
  { key: 'detail', wide: true },
  { key: 'statement', wide: true },
];

export async function communityView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Community tools'));
  const body = el('div', {});
  if (ctx.instance) {
    body.append(await instanceTools(ctx.instance));
    sec.append(body);
    return sec;
  }
  // the root: pick the instance
  const t = await get<Table>('instances');
  const insts = rowsOf(t);
  const pick = el('select', { 'aria-label': 'Instance' }) as HTMLSelectElement;
  pick.append(el('option', { value: '' }, 'pick an instance'));
  for (const r of insts) pick.append(el('option', { value: String(r.instance_id) }, `${String(r.name)} (${r.engine === 'sqlserver' ? 'SQL Server' : 'PostgreSQL'})`));
  pick.addEventListener('change', async () => {
    body.replaceChildren(el('p', { class: 'meta' }, 'Loading...'));
    try { body.replaceChildren(pick.value ? await instanceTools(Number(pick.value)) : el('span')); } catch (e) { body.replaceChildren(errorBox(e)); }
  });
  sec.append(el('div', { class: 'toolbar' }, el('label', {}, 'Instance ', pick)), body);
  return sec;
}

async function instanceTools(instance: number, database = ''): Promise<HTMLElement> {
  const d = await get<Tools>('community', { instance, database });
  const box = el('div', {});
  const out = el('div', {});
  box.append(el('p', { class: 'meta' }, `On ${d.instance}. `
    + (d.engine === 'sqlserver'
      ? 'Each procedure runs as the instance\'s read login (never a sysadmin) with the parameters you give, under the timeout; pgvigil never installs one and never passes a parameter that writes a table.'
      : 'Each read runs on the instance\'s monitoring login in a read-only transaction, under the timeout and a 2 s lock timeout.')
    + ' Every run is audited.'));
  // what every tool here lacks, said before any click: each need and the way to get it (the server's own state)
  const all = d.needs ?? [];
  if (all.length) box.append(needsBox(`Before a tool can run on ${d.instance}:`, all));
  else if (!d.enabled) box.append(el('p', { class: 'meta' }, 'Running is off here: ' + (d.reason ?? '')));
  // an error the server did not turn into a need (the procedures' list could not be read)
  if (d.error && !all.some(n => n.what.includes(d.error ?? ''))) box.append(errorBox(d.error));
  if (d.engine === 'sqlserver') {
    const db = el('input', { type: 'text', value: d.database ?? 'master', 'aria-label': 'Database the procedures are installed in', size: '16' }) as HTMLInputElement;
    const again = el('button', { type: 'button' }, 'Look again');
    again.addEventListener('click', async () => { box.replaceWith(await instanceTools(instance, db.value)); });
    box.append(el('div', { class: 'toolbar' }, el('label', {}, 'Procedures installed in the database ', db), again));
  }
  const groups = [...new Set(d.tools.map(t => t.group))];
  for (const g of groups) {
    const tools = d.tools.filter(t => t.group === g);
    box.append(el('h3', {}, g));
    box.append(grid(tools as unknown as Row[], [
      { key: 'name', label: 'tool', fmt: (_v, r) => openButton(r as unknown as Tool, instance, d, out) },
      { key: 'description', wide: true },
      { key: 'installed', fmt: (v, r) => v === true ? badge('installed in ' + String(r.where ?? ''), 'ok') : v === false ? notInstalled(r as unknown as Tool) : r.kind === 'proc' ? 'not read' : '' },
      { key: 'needs', label: 'before it runs', wide: true, fmt: (_v, r) => needsCell(r as unknown as Tool, d) },
    ]));
  }
  box.append(out, el('h3', {}, 'Runs on this instance'), grid(rowsOf(d.log), logCols, 'No community tool ran here yet.'));
  return box;
}

function notInstalled(t: Tool): HTMLElement {
  return el('span', {}, badge('not installed', 'warn'), ' get it from ', el('a', { href: t.url ?? '#', rel: 'noopener noreferrer', target: '_blank' }, t.url ?? ''));
}

// blockers: the words of what keeps a tool from running here (the instance's needs, then the tool's own hard ones)
function blockers(t: Tool, d: Tools): string[] {
  const hard = [...(d.needs ?? []), ...(t.needs ?? [])].filter(n => n.hard).map(n => n.what + (n.how ? ' - ' + n.how : ''));
  if (!hard.length && !d.enabled) hard.push(d.reason || 'running is off on this server');
  return hard;
}

function needsBox(title: string, needs: Need[]): HTMLElement {
  return el('div', { class: 'needs', role: 'note' }, el('p', {}, title),
    el('ul', {}, ...needs.map(n => el('li', {}, n.what, ...(n.how ? [el('br'), 'How: ' + n.how] : [])))));
}

// needsCell: the tool's own needs beside it ('ready' when nothing stops it); the instance's are said above the list
function needsCell(t: Tool, d: Tools): HTMLElement | string {
  const own = t.needs ?? [];
  if (!own.length) return (d.needs ?? []).some(n => n.hard) || !d.enabled ? 'see above the list' : badge('ready', 'ok');
  return el('span', {}, ...own.flatMap((n, i) => [...(i ? [el('br')] : []), badge(n.hard ? 'needs' : 'note', n.hard ? 'warn' : ''), ' ' + n.what + (n.how ? '. How: ' + n.how : '')]));
}

function openButton(t: Tool, instance: number, d: Tools, out: HTMLElement): HTMLElement {
  const b = el('button', { type: 'button', class: 'link' }, t.name);
  const why = blockers(t, d);
  // off: the reason on hover and, for a screen reader, in its name; the same words stand beside it (needs)
  if (why.length) { b.setAttribute('disabled', ''); b.title = why.join('; '); b.setAttribute('aria-label', `${t.name} (off: ${why[0]})`); }
  b.addEventListener('click', async () => {
    out.replaceChildren(el('p', { class: 'meta' }, 'Loading...'));
    try { out.replaceChildren(t.kind === 'script' ? glennPanel(t, instance, d.database ?? '') : await toolPanel(t, instance, d)); } catch (e) { out.replaceChildren(errorBox(e)); }
  });
  return b;
}

// toolPanel: one procedure's (or read's) form, Run and its result
async function toolPanel(t: Tool, instance: number, d: Tools): Promise<HTMLElement> {
  const p = await post<Params>('community/params', { instance_id: instance, tool: t.id, database: d.database ?? '' });
  const sec = el('section', {}, el('h3', {}, t.name), el('p', {}, t.description));
  if (t.url) sec.append(el('p', { class: 'meta' }, 'Its documentation: ', el('a', { href: t.url, rel: 'noopener noreferrer', target: '_blank' }, t.url)));
  const inputs: [string, HTMLInputElement][] = [];
  const fields = el('div', { class: 'toolbar' });
  if (p.static_params) {
    for (const x of p.static_params) {
      const i = el('input', { type: 'text', value: x.default ?? '', 'aria-label': x.label ?? x.name, size: '8' }) as HTMLInputElement;
      inputs.push([x.name, i]); fields.append(el('label', {}, `${x.label ?? x.name} `, i));
    }
  }
  const table = el('tbody');
  for (const x of p.params) {
    const i = el('input', { type: 'text', 'aria-label': `${x.name} (${x.type})`, size: '24' }) as HTMLInputElement;
    if (x.help) i.title = x.help;
    inputs.push([x.name, i]);
    table.append(el('tr', {}, el('td', {}, x.name), el('td', {}, x.type + (x.max_length > 0 && /char/i.test(x.type) ? `(${x.max_length < 0 ? 'max' : x.max_length})` : '')), el('td', {}, i), el('td', {}, x.help ?? '')));
  }
  if (p.params.length) {
    sec.append(el('p', { class: 'meta' }, 'Leave a parameter empty to take the procedure\'s own default.'),
      el('div', { class: 'grid-wrap', tabindex: '0' }, el('table', { class: 'props' }, el('thead', {}, el('tr', {}, el('th', {}, 'parameter'), el('th', {}, 'type'), el('th', {}, 'value'), el('th', {}, 'what it does'))), table)));
  }
  if (p.left_out.length) sec.append(el('p', { class: 'meta' }, 'Left out (pgvigil never writes through a procedure, and OUTPUT parameters are not shown): ' + p.left_out.join(', ')));
  const timeout = el('input', { type: 'text', value: '60', size: '3', inputmode: 'numeric', 'aria-label': 'Timeout in seconds (1 to 60)' }) as HTMLInputElement;
  const run = el('button', { type: 'button' }, 'Run ' + t.name);
  fields.append(el('label', {}, 'Timeout (s) ', timeout), run);
  sec.append(fields);
  const status = el('p', { class: 'meta', role: 'status' }), res = el('div', {});
  sec.append(status, res);
  run.addEventListener('click', async () => {
    status.textContent = 'Running...'; run.setAttribute('disabled', '');
    const params: Record<string, string> = {};
    for (const [n, i] of inputs) if (i.value.trim() !== '') params[n] = i.value;
    try {
      const r = await post<{ runs: InstanceRun[]; ran_at: string }>('community/run', { instance_id: instance, tool: t.id, database: d.database ?? '', params, timeout_secs: Number(timeout.value || 60) });
      res.replaceChildren(resultView(r.runs, undefined, t.name));
      status.textContent = `Ran at ${fmtTime(r.ran_at)}.`;
    } catch (e) { res.replaceChildren(errorBox(e)); status.textContent = ''; }
    finally { run.removeAttribute('disabled'); }
  });
  if (p.help_sets.length || p.help_error) {
    const det = el('details', {}, el('summary', {}, `${t.name}'s own help`));
    if (p.help_error) det.append(errorBox(p.help_error));
    p.help_sets.forEach((s, i) => det.append(el('h3', {}, `${t.name} help, part ${i + 1}`), setGrid(s, i)));
    sec.append(det);
  }
  return sec;
}

// glennPanel: the DBA's own copy of Glenn Berry's script, cut into its queries; pick one, run it
function glennPanel(t: Tool, instance: number, database: string): HTMLElement {
  const sec = el('section', {}, el('h3', {}, t.name), el('p', {}, t.description));
  sec.append(el('p', { class: 'meta' }, 'pgvigil ships none of these queries: download the script for the server\'s version from ',
    el('a', { href: t.url ?? '#', rel: 'noopener noreferrer', target: '_blank' }, t.url ?? ''), ' and pick it here. The file is cut into its queries on the server and kept nowhere; '
    + 'the query you run is sent to the instance as written, in a transaction that is rolled back, and audited.'));
  const file = el('input', { type: 'file', accept: '.sql,text/plain', 'aria-label': 'Your copy of the diagnostic queries script' }) as HTMLInputElement;
  const db = el('input', { type: 'text', value: database === 'master' ? '' : database, size: '16', 'aria-label': 'Database to run a database-level query in (empty = the login\'s own)' }) as HTMLInputElement;
  const status = el('p', { class: 'meta', role: 'status' }), list = el('div', {}), res = el('div', {});
  sec.append(el('div', { class: 'toolbar' }, el('label', {}, 'Script ', file), el('label', {}, 'Database ', db)), status, list, res);
  file.addEventListener('change', async () => {
    const f = file.files?.[0];
    if (!f) return;
    status.textContent = 'Reading...';
    try {
      const r = await post<{ queries: GlennQuery[] }>('community/glenn/parse', { text: await f.text() });
      status.textContent = `${fmtNum(r.queries.length)} queries in ${f.name}.`;
      list.replaceChildren(grid(r.queries as unknown as Row[], [
        { key: 'n', label: 'query', num: true },
        { key: 'name', fmt: (_v, q) => runButton(q as unknown as GlennQuery) },
        { key: 'about', wide: true },
      ]));
    } catch (e) { status.textContent = ''; list.replaceChildren(errorBox(e)); }
  });
  const runButton = (q: GlennQuery) => {
    const b = el('button', { type: 'button', class: 'link' }, q.name);
    b.addEventListener('click', async () => {
      res.replaceChildren(el('p', { class: 'meta' }, `Running query ${q.n} (${q.name})...`));
      try {
        const r = await post<{ runs: InstanceRun[] }>('community/run', { instance_id: instance, tool: t.id, database: db.value, text: q.text, query_name: `${q.n} ${q.name}` });
        res.replaceChildren(el('details', {}, el('summary', {}, `Query ${q.n}: the text sent`), el('pre', { class: 'sql', tabindex: '0' }, q.text)),
          resultView(r.runs, undefined, `Query ${q.n} ${q.name}`));
      } catch (e) { res.replaceChildren(errorBox(e)); }
    });
    return b;
  };
  return sec;
}
