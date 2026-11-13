// Community tools (task 170, task 93 (a); DBA Dash's Community Tools): run a community procedure a DBA installed on a
// SQL Server instance (sp_WhoIsActive, the First Responder Kit, Erik Darling's procedures) with its own parameters as
// a form, Glenn Berry's diagnostic queries from the DBA's own copy of his script, or on a PostgreSQL instance pgvigil's
// own diagnostic reads; each result set in pgvigil's grid (its menus, the export, the grid tools). pgvigil never
// installs a procedure: a missing one says where to get it. Every run is read-only on the instance's read login,
// under a timeout, and audited (the log below).
// Data: GET /api/community?instance=N&database=D, POST /api/community/params, /api/community/run and
// /api/community/glenn/parse (internal/web/q_community.go).
// The shell mounts communityView(ctx): an instance tab 'community' (ctx.instance) and a root tab with an instance picker
// (the lead wires the route and the tabs). On a demo instance (pgvigil demo invented it: no server behind it) each tool
// opens its stored sample (GET /api/community/sample: what the tool returned on a test server built for the capture,
// marked as that, with a link to this instance's own page on the subject) and its Run stays off with the demo's line.
// The address's tool=<id> opens that tool's panel as the page loads (a mailed page carries it).
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, tabsFor } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, offControl } from './ui';
import { InstanceRun, logOutcome, resultView, ResultSet, setGrid } from './customreports';

// a need: what the tool lacks here before it can run and the way to get it (hard = the tool is off without it);
// state: needs | note | not_checked | demo; source: where the server read it (server, configuration, repository, live)
interface Need { what: string; how?: string; hard: boolean; state: string; source?: string; read_at?: string }
interface Tool {
  id: string; name: string; group: string; engine: string; kind: string; url?: string; description: string; help?: string;
  installed: boolean | null; where?: string; params?: { name: string; type: string; label?: string; default?: string }[];
  state: string; on: boolean; needs?: Need[]; preset?: Record<string, string>; sample?: SampleMark;
}
// a stored sample's mark (q_community.go sampleMark): line = the words above it, mark = what an export carries (a demo
// serve mails nothing)
interface SampleMark { kit: string; version: string; version_date?: string; captured_at: string; server: string; page?: string; line: string; mark: string }
interface SampleAnswer extends SampleMark {
  tool: string; name: string; instance: string; database?: string; params: Record<string, string>;
  param_doc: { name: string; type: string; help?: string }[] | null; dropped: string[] | null; cut: string[] | null; scrubbed: string[] | null; sets: ResultSet[];
}
interface Tools { enabled: boolean; reason?: string; instance: string; engine: string; database?: string; demo: boolean; tools: Tool[]; log: Table | null; needs?: Need[]; checked_at?: string }
interface ProcParam { name: string; type: string; max_length: number; help?: string }
interface Params { installed: boolean; params: ProcParam[]; left_out: string[]; help_sets: ResultSet[]; help_error?: string; static_params?: { name: string; type: string; label?: string; default?: string }[] }
interface GlennQuery { n: number; name: string; about: string; text: string }

const logCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'ui_user', label: 'who' },
  { key: 'op', label: 'what', fmt: v => v === 'community_help' ? 'help' : 'run' },
  { key: 'tool' },
  // a run the procedure declined in its own words is stored failed (it reached the server) and shown as declined
  { key: 'outcome', fmt: logOutcome },
  { key: 'rows', num: true },
  { key: 'duration_ms', label: 'took (ms)', num: true },
  { key: 'detail', wide: true },
  { key: 'statement', wide: true },
];

export async function communityView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Community tools'));
  const body = el('div', {});
  if (ctx.instance) {
    const open = new URLSearchParams(location.hash.split('?')[1] ?? '').get('tool') ?? '';
    body.append(await instanceTools(ctx.instance, '', false, open));
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

const stateWord: Record<string, [string, string]> = {
  ready: ['ready', 'ok'], note: ['note', 'warn'], needs: ['off', 'warn'], not_checked: ['not checked', 'crit'], demo: ['demo', 'none'],
};

// readAt: when a fact was read, for a fact the server took from the repository or a check it keeps
function readAt(n: Need): string {
  return n.read_at ? ` (read ${fmtTime(n.read_at)})` : '';
}

async function instanceTools(instance: number, database = '', fresh = false, open = ''): Promise<HTMLElement> {
  const d = await get<Tools>('community', { instance, database, ...(fresh ? { fresh: '1' } : {}) });
  const box = el('div', {});
  const out = el('div', {});
  box.append(el('p', { class: 'meta' }, `On ${d.instance}. `
    + (d.engine === 'sqlserver'
      ? 'Each procedure runs as the instance\'s read login (never a sysadmin) with the parameters you give, under the timeout; pgvigil never installs one and never passes a parameter that writes a table.'
      : 'Each read runs on the instance\'s monitoring login in a read-only transaction, under the timeout and a 2 s lock timeout.')
    + ' Every run is audited.'));
  // what every tool here lacks, said before any click: each need and the way to get it
  const all = d.needs ?? [];
  const above = all.length ? needsBox(`Before a tool can run on ${d.instance}:`, all) : null;
  if (above) box.append(above);
  const again = el('button', { type: 'button' }, 'Look again');
  const checked = el('span', { class: 'meta' }, d.checked_at ? `Checked ${fmtTime(d.checked_at)}.` : '');
  const db = el('input', { type: 'text', value: d.database ?? '', 'aria-label': d.engine === 'sqlserver' ? 'Database the procedures are installed in' : 'Database the reads run in', size: '16' }) as HTMLInputElement;
  again.addEventListener('click', async () => {
    offControl(again, 'looking...', checked); checked.textContent = 'Looking again...';
    try {
      // the database as the page was opened ('' = the default) while the box still names the one the server answered
      // with: the default and that database named are one check, never two answers side by side
      const nb = await instanceTools(instance, db.value.trim() === (d.database ?? '') ? database : db.value, true);
      box.replaceWith(nb);
      // the keyboard stays where it was: on the new box's Look again
      [...nb.querySelectorAll('button')].find(x => x.textContent === 'Look again')?.focus();
    } catch (e) { checked.replaceChildren(errorBox(e)); offControl(again, null, checked); }
  });
  if (!d.demo) box.append(el('div', { class: 'toolbar' }, el('label', {}, d.engine === 'sqlserver' ? 'Procedures installed in the database ' : 'Reads run in the database ', db), again, checked));
  const groups = [...new Set(d.tools.map(t => t.group))];
  for (const g of groups) {
    const tools = d.tools.filter(t => t.group === g);
    // each tool's state cell first: its button names it as its description when the tool is off
    const cells = new Map<string, HTMLElement>(tools.map(t => [t.id, needsCell(t, d)]));
    box.append(el('h3', {}, g));
    box.append(grid(tools as unknown as Row[], [
      { key: 'name', label: 'tool', fmt: (_v, r) => openButton(r as unknown as Tool, instance, d, out, cells.get(String(r.id)), above) },
      { key: 'description', wide: true },
      { key: 'state', label: 'before it runs', wide: true, fmt: (_v, r) => cells.get(String(r.id)) ?? '' },
    ]));
  }
  box.append(out, el('h3', {}, 'Runs on this instance'), grid(rowsOf(d.log), logCols, 'No community tool ran here yet.'));
  // the address named a tool: on a demo instance its sample is open when the page has drawn (a linked page opens it
  // again); on a real instance the address opens nothing - a tool's form runs its help on the server, which only a
  // click asks
  if (open && d.demo) {
    const t = d.tools.find(x => x.id === open);
    if (t) { try { out.replaceChildren(await panelOf(t, instance, d)); } catch (e) { out.replaceChildren(errorBox(e)); } }
    else out.replaceChildren(el('p', { class: 'meta', role: 'note' }, `No tool '${open}' on ${d.instance}: pick one above.`));
  }
  return box;
}

// panelOf: the tool's panel - on a demo instance its stored sample, else its form (Glenn's: the file step)
function panelOf(t: Tool, instance: number, d: Tools): Promise<HTMLElement> {
  if (d.demo) return demoPanel(t, instance, d);
  return t.kind === 'script' ? Promise.resolve(glennPanel(t, instance, d.database ?? '')) : toolPanel(t, instance, d);
}

function needLine(n: Need): (Node | string)[] {
  return [n.what + readAt(n), ...(n.how ? [el('br'), 'How: ' + n.how] : [])];
}

function needsBox(title: string, needs: Need[]): HTMLElement {
  return el('div', { class: 'needs', role: 'note', id: 'community-needs' }, el('p', {}, title),
    el('ul', {}, ...needs.map(n => el('li', {}, ...needLine(n)))));
}

// the deciding need: the first hard one (the instance's, then the tool's own)
function decider(t: Tool, d: Tools): Need | undefined {
  return [...(d.needs ?? []), ...(t.needs ?? [])].find(n => n.hard);
}

// needsCell: the tool's state in words beside it - ready (and where it is installed), or why it is off, then its own
// needs and notes with the way to get each
function needsCell(t: Tool, d: Tools): HTMLElement {
  const [word, kind] = stateWord[t.state] ?? [t.state, 'none'];
  const cell = el('span', { class: 'tool-state' }, badge(word, kind));
  const dec = decider(t, d);
  const own = t.needs ?? [];
  if (dec && !own.includes(dec)) cell.append(' ' + dec.what);
  else if (t.state === 'ready') cell.append(t.where ? ` in ${t.where}` : '');
  own.forEach((n, i) => cell.append(...(i || (dec && !own.includes(dec)) ? [el('br')] : [' ']), ...(n.hard ? [] : [badge('note', 'warn'), ' ']), ...needLine(n)));
  return cell;
}

function openButton(t: Tool, instance: number, d: Tools, out: HTMLElement, cell: HTMLElement | undefined, above: HTMLElement | null): HTMLElement {
  const b = el('button', { type: 'button', class: 'link' }, t.name);
  const dec = decider(t, d);
  // off: in the tab order, the reason beside it (its state cell) as its description, on hover too; on a demo instance
  // the name opens the tool's stored sample (its Run is the control that stays off there)
  if (!t.on && !d.demo) offControl(b, dec ? dec.what + (dec.how ? ' How: ' + dec.how : '') : 'off here', cell ?? above ?? undefined);
  b.addEventListener('click', async () => {
    out.replaceChildren(el('p', { class: 'meta' }, 'Loading...'));
    // a demo sample's own address (tool=): a schedule or a link of this page then opens it again
    if (d.demo) {
      const [path, q] = location.hash.split('?');
      const qs = new URLSearchParams(q ?? '');
      if (qs.get('i') === String(instance)) { qs.set('tool', t.id); history.replaceState(null, '', `${path}?${qs}`); }
    }
    try { out.replaceChildren(await panelOf(t, instance, d)); } catch (e) { out.replaceChildren(errorBox(e)); }
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
  // the values the server presets for this instance (a default the procedure would decline here, or one that reads
  // nothing): filled in and said, the note beside the tool says why
  const preset = new Map(Object.entries(t.preset ?? {}).map(([k, v]) => [k.toLowerCase(), v]));
  const filled: string[] = [];
  for (const x of p.params) {
    const i = el('input', { type: 'text', 'aria-label': `${x.name} (${x.type})`, size: '24' }) as HTMLInputElement;
    if (x.help) i.title = x.help;
    const v = preset.get(x.name.toLowerCase());
    if (v !== undefined) { i.value = v; filled.push(`${x.name} = ${v}`); }
    inputs.push([x.name, i]);
    table.append(el('tr', {}, el('td', {}, x.name), el('td', {}, x.type + (x.max_length !== 0 && /char/i.test(x.type) ? `(${x.max_length < 0 ? 'max' : /^n/i.test(x.type) ? x.max_length / 2 : x.max_length})` : '')), el('td', {}, i), el('td', {}, x.help ?? '')));
  }
  if (p.params.length) {
    sec.append(el('p', { class: 'meta' }, 'Leave a parameter empty to take the procedure\'s own default.'),
      el('div', { class: 'grid-wrap', tabindex: '0' }, el('table', { class: 'props' }, el('thead', {}, el('tr', {}, el('th', {}, 'parameter'), el('th', {}, 'type'), el('th', {}, 'value'), el('th', {}, 'what it does'))), table)));
  }
  if (filled.length) {
    const why = (t.needs ?? []).filter(n => n.state === 'note').map(n => n.what).join(' ');
    sec.append(el('p', { class: 'meta preset', role: 'note' }, `Filled in for ${d.instance}: ${filled.join(', ')}.` + (why ? ' ' + why : '')));
  }
  if (p.left_out.length) sec.append(el('p', { class: 'meta' }, 'Left out (pgvigil never writes through a procedure, and OUTPUT parameters are not shown): ' + p.left_out.join(', ')));
  const timeout = el('input', { type: 'text', value: '60', size: '3', inputmode: 'numeric', 'aria-label': 'Timeout in seconds (1 to 60)' }) as HTMLInputElement;
  const run = el('button', { type: 'button' }, 'Run ' + t.name);
  fields.append(el('label', {}, 'Timeout (s) ', timeout), run);
  sec.append(fields);
  const status = el('p', { class: 'meta', role: 'status' }), res = el('div', {});
  sec.append(status, res);
  run.addEventListener('click', async () => {
    status.textContent = 'Running...'; offControl(run, 'running', status);
    const params: Record<string, string> = {};
    for (const [n, i] of inputs) if (i.value.trim() !== '') params[n] = i.value;
    try {
      const r = await post<{ runs: InstanceRun[]; ran_at: string }>('community/run', { instance_id: instance, tool: t.id, database: d.database ?? '', params, timeout_secs: Number(timeout.value || 60) });
      res.replaceChildren(resultView(r.runs, undefined, t.name));
      status.textContent = `Ran at ${fmtTime(r.ran_at)}.`;
    } catch (e) { res.replaceChildren(errorBox(e)); status.textContent = ''; }
    finally { offControl(run, null, status); }
  });
  if (p.help_sets.length || p.help_error) {
    const det = el('details', {}, el('summary', {}, `${t.name}'s own help`));
    if (p.help_error) det.append(errorBox(p.help_error));
    p.help_sets.forEach((s, i) => det.append(el('h3', {}, `${t.name} help, part ${i + 1}`), setGrid(s, i)));
    sec.append(det);
  }
  return sec;
}

// demoPanel: a demo instance's tool - what it does, its stored sample marked as a test server's (never this
// instance's), the link to this instance's own page on the subject, and Run off with the demo's line beside it
async function demoPanel(t: Tool, instance: number, d: Tools): Promise<HTMLElement> {
  const sec = el('section', {}, el('h3', {}, t.name), el('p', {}, t.description));
  if (t.url && t.kind !== 'script') sec.append(el('p', { class: 'meta' }, 'Its documentation: ', el('a', { href: t.url, rel: 'noopener noreferrer', target: '_blank' }, t.url)));
  const demoWhy = (d.needs ?? []).find(n => n.state === 'demo')?.what ?? `${d.instance} is a demo instance: no server stands behind it, so no tool runs here.`;
  const why = el('p', { class: 'meta demo-why' }, demoWhy);
  const run = el('button', { type: 'button' }, 'Run ' + t.name);
  offControl(run, demoWhy, why);
  if (!t.sample) {
    const none = (t.needs ?? []).find(n => n.state === 'note')?.what ?? 'no stored sample for this tool';
    sec.append(el('p', { class: 'meta', role: 'note' }, none.charAt(0).toUpperCase() + none.slice(1) + '.'));
    if (t.kind === 'script' && t.url) sec.append(el('p', { class: 'meta' }, 'The script for the server\'s version: ', el('a', { href: t.url, rel: 'noopener noreferrer', target: '_blank' }, t.url), '.'));
    sec.append(el('div', { class: 'toolbar' }, run), why);
    return sec;
  }
  const s = await get<SampleAnswer>('community/sample', { instance, tool: t.id });
  // every grid of the panel is the test server's (the stored run's parameters too): an export or a mail carries the mark
  sec.setAttribute('data-sample', s.mark);
  sec.append(el('p', { class: 'meta sample-line', role: 'note' }, badge('stored sample', 'none'), ' ', s.line));
  if (s.page) {
    const label = tabsFor(d.engine)[s.page] ?? s.page;
    sec.append(el('p', { class: 'meta' }, `${d.instance}'s own data on this subject: `, el('a', { href: `#/${s.page}?i=${instance}` }, `the ${label} page`), '.'));
  }
  const used = Object.entries(s.params ?? {});
  if (s.param_doc?.length) {
    // a grid (an export or a mail reads its four columns as they are), under a heading of its own
    const byName = new Map(used.map(([k, v]) => [k.toLowerCase(), v]));
    sec.append(el('h4', {}, `${t.name} parameters`), grid(s.param_doc.map(x => ({ name: x.name, type: x.type, used: byName.get(x.name.toLowerCase()) ?? '', help: x.help ?? '' })), [
      { key: 'name', label: 'parameter' }, { key: 'type' }, { key: 'used', label: 'in the stored run' }, { key: 'help', label: 'what it does', wide: true },
    ]));
    // the help text is the kit's own words, stored with the sample (MIT kits only; THIRD-PARTY-NOTICES.md says so)
    if (s.param_doc.some(x => x.help)) sec.append(el('p', { class: 'meta' }, `'what it does' is ${s.kit}'s own help text for ${t.name}, stored with the sample (MIT).`));
  } else if (used.length) {
    sec.append(el('p', { class: 'meta' }, 'The stored run passed ' + used.map(([k, v]) => `${k} = ${v}`).join(', ') + '.'));
  }
  const left = [...(s.dropped ?? []), ...(s.cut ?? [])];
  if (left.length) sec.append(el('p', { class: 'meta' }, 'Left out of the stored copy: ' + left.join('; ') + '.'));
  // the test server's own names (its data folder, its socket) replaced by fixed words: said, never passed off as its own
  if (s.scrubbed?.length) sec.append(el('p', { class: 'meta' }, 'The test server\'s own names replaced in the stored copy by the fixed words ' + s.scrubbed.join('; ') + '.'));
  sec.append(el('div', { class: 'toolbar' }, run), why);
  // the grids inside the mark: an export of them carries it (export.ts reads data-sample)
  const box = el('div', { class: 'sample', 'data-sample': s.mark });
  s.sets.forEach((set, i) => {
    box.append(el('h3', {}, s.sets.length > 1 ? `${t.name} sample, result set ${i + 1}` : `${t.name} sample`));
    if (set.truncated) box.append(el('p', { class: 'meta' }, `The first ${fmtNum(set.rows.length)} rows of the stored run.`));
    box.append(setGrid(set, i));
  });
  sec.append(box);
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
      const busy = el('p', { class: 'meta' }, `Running query ${q.n} (${q.name})...`);
      res.replaceChildren(busy);
      offControl(b, 'running', busy);   // one run at a time from this button
      try {
        const r = await post<{ runs: InstanceRun[] }>('community/run', { instance_id: instance, tool: t.id, database: db.value, text: q.text, query_name: `${q.n} ${q.name}` });
        res.replaceChildren(el('details', {}, el('summary', {}, `Query ${q.n}: the text sent`), el('pre', { class: 'sql', tabindex: '0' }, q.text)),
          resultView(r.runs, undefined, `Query ${q.n} ${q.name}`));
      } catch (e) { res.replaceChildren(errorBox(e)); } finally { offControl(b, null, busy); }
    });
    return b;
  };
  return sec;
}
