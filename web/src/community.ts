// Community tools (task 170, task 93 (a); DBA Dash's Community Tools): run a community procedure a DBA installed on a
// SQL Server instance (sp_WhoIsActive, the First Responder Kit, Erik Darling's procedures) with its own parameters as
// a form, Glenn Berry's diagnostic queries from the DBA's own copy of his script, or on a PostgreSQL instance pgvigil's
// own diagnostic reads; each result set in pgvigil's grid (its menus, the export, the grid tools). pgvigil never
// installs a procedure: a missing one says where to get it. Every run is read-only on the instance's read login,
// under a timeout, and audited (the log below).
// Data: GET /api/community?instance=N&database=D, POST /api/community/params, /api/community/run and
// /api/community/glenn/parse (internal/web/q_community.go).
// The shell mounts communityView(ctx): an instance tab 'community' (ctx.instance) and a root tab with an instance picker
// (the shell wires the route and the tabs). On a demo instance (pgvigil demo invented it: no server behind it) each tool
// opens its stored sample (GET /api/community/sample: what the tool returned on a test server built for the capture,
// marked as that, with a link to this instance's own page on the subject) and its Run stays off with the demo's line.
// The address's tool=<id> opens that tool's panel as the page loads (a mailed page carries it).
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, tabsFor } from './router';
import { badge, Col, copyText, el, errorBox, fmtNum, fmtTime, grid, offControl } from './ui';
import { needControl } from './needs';
import { InstanceRun, logOutcome, resultView, ResultSet, setGrid } from './customreports';
import { folderWords, inTagScope, tagWords } from './fleet';
import { cutWords, endView, isQueued, Queued, waitRequest } from './request';

// a need: what the tool lacks here before it can run and the way to get it (hard = the tool is off without it);
// state: needs | note | not_checked | demo; source: where the server read it (server, configuration, repository, live)
interface Need { what: string; how?: string; hard: boolean; state: string; source?: string; read_at?: string }
interface Tool {
  id: string; name: string; group: string; engine: string; kind: string; url?: string; description: string; help?: string;
  installed: boolean | null; where?: string; params?: { name: string; type: string; label?: string; default?: string }[];
  state: string; on: boolean; needs?: Need[]; preset?: Record<string, string>; sample?: SampleMark;
  // a procedure's version from its own text against the one pgvigil was tested with (q_community.go, community_versions.go)
  version?: string | null; version_date?: string; tested?: string; version_word?: string;
  // KITWATCH K4.3: the version installed here (the server's definition, read daily) beside the one pgvigil was checked against
  // (its own key: 'version' above is the page-time read, community_versions.go)
  kit_version?: { installed?: string; installed_date?: string; database?: string; readable: boolean; present?: boolean; read_at?: string; checked: string; checked_date: string; newer?: boolean };
}
// a stored sample's mark (q_community.go sampleMark): line = the words above it, mark = what an export carries (a demo
// serve mails nothing)
interface SampleMark { kit: string; version: string; version_date?: string; captured_at: string; server: string; page?: string; line: string; mark: string }
interface SampleAnswer extends SampleMark {
  tool: string; name: string; instance: string; database?: string; params: Record<string, string>;
  param_doc: { name: string; type: string; help?: string }[] | null; dropped: string[] | null; cut: string[] | null; scrubbed: string[] | null; sets: ResultSet[];
}
// via 'queue': this serve sends the runs through the repository to the collector named (actions.via queue)
interface Tools { enabled: boolean; reason?: string; instance: string; engine: string; database?: string; demo: boolean; tools: Tool[]; log: Table | null; needs?: Need[]; checked_at?: string; install_script?: string; version_notes?: string[]; kit_fleet?: string[]; via?: string; collector?: string }
interface ProcParam { name: string; type: string; max_length: number; help?: string }
// help_via 'queue': the procedure's @help is its own request (POST community/run?help=1), not part of the form
interface Params { installed: boolean; params: ProcParam[]; left_out: string[]; help_sets: ResultSet[]; help_error?: string; static_params?: { name: string; type: string; label?: string; default?: string }[]; help_via?: string }
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
  // under a tag folder (TAGALL) the heading names it and the picker lists its instances only
  const tag = ctx.tag && !ctx.instance ? ctx.tag : undefined;
  const sec = el('section', {}, el('h2', {}, 'Community tools' + (tag ? ` - ${tagWords(tag)}` : '')));
  const body = el('div', {});
  if (ctx.instance) {
    const open = new URLSearchParams(location.hash.split('?')[1] ?? '').get('tool') ?? '';
    body.append(await instanceTools(ctx.instance, '', false, open));
    sec.append(body);
    return sec;
  }
  // the root: pick the instance
  const t = await get<Table>('instances');
  const insts = rowsOf(t).filter(r => !tag || inTagScope(tag, r));
  if (tag && insts.length === 0) {
    sec.append(el('p', { class: 'empty' }, `No instance is in ${folderWords(tag)}.`));
    return sec;
  }
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

// navs: this tab's navigations (a hash change: a link, Back); a redraw of the same page is none
let navs = 0;
addEventListener('hashchange', () => { navs++; });
// shownTool: the tool whose panel was last brought into view ('<navs>:<instance>:<tool>'): the address's tool= does it once
// per navigation, so a redraw of the same page (the system's colours under the 'auto' theme) never moves the view, and
// Back to the page brings it into view again
let shownTool = '';

// inView: a tool's panel at the top of the view (html's scroll-padding keeps it under the sticky header and tabs) with the
// focus on its heading - or on its error or note when it has none (a failed read, an unknown tool) - so a click on a tool
// changes what a person sees (it drew under every table, ~1,450 px down); drawn before the page is on the screen (the
// address's tool=), it waits for the page, about 2 s at most
function inView(panel: HTMLElement, tries = 120): void {
  const h = panel.querySelector<HTMLElement>('h3') ?? panel.querySelector<HTMLElement>('.error, [role=note]');
  const at = h ?? panel;
  if (!at.isConnected) { if (tries > 0) requestAnimationFrame(() => inView(panel, tries - 1)); return; }
  at.scrollIntoView({ block: 'start' });
  if (h) { h.tabIndex = -1; h.focus({ preventScroll: true }); }
}

// readAt: when a fact was read, for a fact the server took from the repository or a check it keeps
function readAt(n: Need): string {
  return n.read_at ? ` (read ${fmtTime(n.read_at)})` : '';
}

async function instanceTools(instance: number, database = '', fresh = false, open = ''): Promise<HTMLElement> {
  const d = await get<Tools>('community', { instance, database, ...(fresh ? { fresh: '1' } : {}) });
  const box = el('div', {});
  const out = el('div', {});
  box.append(el('p', { class: 'meta community-intro' }, `On ${d.instance}. `
    + (d.demo
      // a demo instance: what the page gives, before any row's refusal (Glenn Berry's script has no sample: its row says so)
      ? 'Each tool with a stored sample opens it: its real output, captured on a test server; nothing runs on a demo instance.'
      : (d.engine === 'sqlserver'
        ? 'Each procedure runs as the instance\'s read login (never a sysadmin) with the parameters you give, under the timeout; pgvigil never installs one and never passes a parameter that writes a table.'
        : 'Each read runs on the instance\'s monitoring login in a read-only transaction, under the timeout and a 2 s lock timeout.')
        + ' Every run is audited.')));
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
  // the runs grid (CQ-RUNSGRID: never a run that seems to do nothing) is drawn again whenever a run, a help ask or a
  // direct form's read ends on this page - a queued run is followed to its end even when another tool's panel
  // replaced its own (the waits' alive element is this grid) - from the page's own read once more, not fresh (the
  // checks' answer is kept 60 s, after that the same read-only check the page's open makes; in queue mode the
  // collector's published list), and only this grid is replaced: the open panel and its result stay. A newer answer
  // is never replaced by an older one; a read that fails says so above the grid as last drawn, never silently; a page
  // already left reads nothing. A 'lost' end can have its audit row written after it (a late finish keeps it): the
  // grid shows that row at the next end or look.
  const logGrid = (t: Table | null) => grid(rowsOf(t), logCols, 'No community tool ran here yet.');
  let shown = logGrid(d.log), shownAt = new Date().toISOString(), shownSeq = 0, relogs = 0;
  const runs = el('div', { class: 'community-runs' }, shown);
  const relog = async (): Promise<void> => {
    if (d.demo || !runs.isConnected) return;   // nothing runs on a demo instance; a page left reads nothing
    const mine = ++relogs;
    try {
      const n = await get<Tools>('community', { instance, database });
      if (!runs.isConnected || mine < shownSeq) return;
      shown = logGrid(n.log); shownAt = new Date().toISOString(); shownSeq = mine;
      runs.replaceChildren(shown);
    } catch (e) {
      if (!runs.isConnected || mine !== relogs) return;
      runs.replaceChildren(errorBox(new Error(`the runs could not be read again (${e instanceof Error ? e.message : String(e)}); the grid below is as drawn at ${fmtTime(shownAt)}`)), shown);
    }
  };
  const page: PanelPage = { ended: relog, alive: runs };
  // a tool's panel opens directly under the tool's own table, in view (inView); a click on another tool moves it there
  const tables = new Map<string, HTMLElement>();
  let firstGroup: HTMLElement | undefined;
  // a later click wins: a panel whose answer comes after another click's never replaces it nor moves the view
  let seq = 0;
  const openTool = async (t: Tool) => {
    const mine = ++seq;
    tables.get(t.id)?.after(out);
    out.replaceChildren(el('p', { class: 'meta', role: 'status' }, 'Loading...'));
    out.scrollIntoView({ block: 'nearest' });
    // a demo sample's own address (tool=): a schedule or a link of this page then opens it again
    if (d.demo) {
      const [path, q] = location.hash.split('?');
      const qs = new URLSearchParams(q ?? '');
      if (qs.get('i') === String(instance)) { qs.set('tool', t.id); history.replaceState(null, '', `${path}?${qs}`); }
    }
    shownTool = `${navs}:${instance}:${t.id}`;
    let panel: HTMLElement;
    try { panel = await panelOf(t, instance, d, page); } catch (e) { panel = errorBox(e); }
    // a procedure's form read on the direct path is audited (its @help run, or the refusal): the grid shows it; queue
    // mode's form read and the other kinds' audit nothing, so nothing is read again
    if (d.via !== 'queue' && t.kind === 'proc') void relog();
    if (mine !== seq) return;
    out.replaceChildren(panel);
    inView(out);
  };
  // KITWATCH K4.3: the fleet's procedures newer than pgvigil was checked against, one line per version
  if (d.kit_fleet?.length) box.append(el('ul', { class: 'meta' }, ...d.kit_fleet.map(l => el('li', {}, l))));
  const versionCell = (t: Tool): HTMLElement | string => {
    const v = t.kit_version;
    if (!v) return '';
    const checked = `checked ${v.checked}`;
    // never read (mssql_kits reads each day) and read but not found are two things, each said
    if (!v.read_at) return `not read yet (mssql_kits reads each day); ${checked}`;
    if (!v.present) return `not found at the last read; ${checked}`;
    if (!v.readable) return el('span', {}, `not readable here (no VIEW DEFINITION); ${checked}`);
    if (!v.installed) return `no version line; ${checked}`;
    const here = `${v.installed}${v.database ? ` in ${v.database}` : ''}`;
    return v.newer ? el('span', {}, `${here}; ${checked} `, badge('newer than checked', 'warn')) : `${here}; ${checked}`;
  };
  // X18: an installed version not newer than checked is OK; never read, not found, not readable or no version line is
  // N/A; a newer one carries its warning badge
  const versionCls = (t: Tool): string => {
    const v = t.kit_version;
    if (!v) return '';
    if (!v.read_at || !v.present || !v.readable || !v.installed) return 'status none';
    return v.newer ? '' : 'status ok';
  };
  const groups = [...new Set(d.tools.map(t => t.group))];
  for (const g of groups) {
    const tools = d.tools.filter(t => t.group === g);
    // each tool's state cell first: its button names it as its description when the tool is off; on a demo instance a
    // tool with a stored sample leads with its way in, 'Open sample'
    const cells = new Map<string, HTMLElement>(tools.map(t => [t.id, d.demo && t.sample ? sampleCell(t, d, () => void openTool(t)) : needsCell(t, d)]));
    const table = grid(tools as unknown as Row[], [
      { key: 'name', label: 'tool', fmt: (_v, r) => openButton(r as unknown as Tool, d, () => void openTool(r as unknown as Tool), cells.get(String(r.id)), above) },
      { key: 'description', wide: true },
      // KITWATCH's read: the installed version as mssql_kits last read it (daily) and the version pgvigil was checked against
      { key: 'kit_version', label: 'installed (daily read) / pgvigil checked', fmt: (_v, r) => versionCell(r as unknown as Tool),
        cls: (_v, r) => versionCls(r as unknown as Tool) },
      { key: 'state', label: 'before it runs', wide: true, fmt: (_v, r) => cells.get(String(r.id)) ?? '' },
    ]);
    for (const t of tools) tables.set(t.id, table);
    const head = el('h3', {}, g);
    firstGroup ??= head;
    box.append(head, table);
  }
  // the community procedures' versions against the ones pgvigil was tested with (DBA Dash's Check Versions): read from
  // each one's own text, nothing run; the install script printed for the DBA, never run by pgvigil
  const procs = d.tools.filter(t => t.kind === 'proc' && t.version_word);
  if (procs.length) {
    const wordCls = (w: string) => w === 'the tested version' ? 'ok' : w === 'older than tested' || w === 'version not read' ? 'warn' : '';
    box.append(el('h3', {}, 'Installed community tools'),
      ...(d.version_notes ?? []).map(n => el('p', { class: 'meta' }, badge('mixed versions', 'warn'), ' ', n)),
      grid(procs as unknown as Row[], [
        { key: 'name', label: 'procedure' }, { key: 'group', label: 'kit' }, { key: 'where', label: 'database', fmt: v => String(v ?? '') },
        // ST3's read: the version installed on this instance, read from the procedure's own text when this page is drawn
        { key: 'version', label: 'installed here (its text, read now)', fmt: v => v == null ? '' : String(v) }, { key: 'version_date', label: 'its date', fmt: v => String(v ?? '') },
        { key: 'tested', label: 'tested by pgvigil', fmt: v => String(v ?? '') },
        { key: 'version_word', label: 'status', fmt: v => badge(String(v ?? ''), wordCls(String(v ?? ''))) },
      ]));
    if (d.install_script) {
      const script = d.install_script;
      const copy = el('button', { type: 'button' }, 'Copy');
      // the clipboard's async API exists on a secure origin only: copyText falls back to a hidden textarea, and the
      // status line says what happened (on a refusal: select the text below)
      const said = el('span', { role: 'status', class: 'meta' });
      copy.addEventListener('click', () => {
        void copyText(script).then(ok => { said.textContent = ok ? 'Copied' : 'Not copied: select the text below and copy it'; });
      });
      box.append(el('details', { class: 'install-script' }, el('summary', {}, 'Print the install script'),
        el('p', { class: 'meta' }, 'pgvigil prints this script and runs none of it: with dbatools it installs what is missing, older than tested or of no readable version here.'),
        copy, ' ', said, el('pre', { class: 'mono' }, script)));
    }
  }
  box.append(out, el('h3', {}, 'Runs on this instance'), runs);
  // the address named a tool: on a demo instance its sample is open when the page has drawn (a linked page opens it
  // again); on a real instance the address opens nothing - a tool's form runs its help on the server, which only a
  // click asks
  if (open && d.demo) {
    const t = d.tools.find(x => x.id === open);
    if (t) {
      tables.get(t.id)?.after(out);
      try { out.replaceChildren(await panelOf(t, instance, d, page)); } catch (e) { out.replaceChildren(errorBox(e)); }
      // in view once per navigation and tool: a redraw of the same page stays where the person is
      if (shownTool !== `${navs}:${instance}:${t.id}`) { shownTool = `${navs}:${instance}:${t.id}`; inView(out); }
    } else {
      // an address naming no tool here (a renamed one in an old link): said above the tools, in view
      firstGroup?.before(out);
      out.replaceChildren(el('p', { class: 'meta', role: 'note' }, `No tool '${open}' on ${d.instance}: pick one below.`));
      inView(out);
    }
  }
  return box;
}

// PanelPage: what a panel's runs tell the page - ended when each run or help ask of the panel ends, however it ended
// (the runs grid is drawn again), and alive, the element whose leaving the page ends a queued run's wait (the grid:
// a panel another tool replaced still follows its run to its end)
interface PanelPage { ended: () => Promise<void>; alive: HTMLElement }

// panelOf: the tool's panel - on a demo instance its stored sample, else its form (Glenn's: the file step)
function panelOf(t: Tool, instance: number, d: Tools, page: PanelPage): Promise<HTMLElement> {
  if (d.demo) return demoPanel(t, instance, d);
  return t.kind === 'script' ? Promise.resolve(glennPanel(t, instance, d.database ?? '', page)) : toolPanel(t, instance, d, page);
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

// sampleCell: a demo row's way in first - 'Open sample' - then its state (the demo line); the state's words in data-full,
// so the export, the copies and a mail read the cell as before ('demo <line>'), never the button's word
function sampleCell(t: Tool, d: Tools, open: () => void): HTMLElement {
  const state = needsCell(t, d);
  state.setAttribute('data-full', (state.textContent ?? '').replace(/\s+/g, ' ').trim());
  const b = el('button', { type: 'button', 'aria-label': `Open sample: ${t.name}` }, 'Open sample');
  b.addEventListener('click', open);
  return el('span', {}, b, ' ', state);
}

function openButton(t: Tool, d: Tools, open: () => void, cell: HTMLElement | undefined, above: HTMLElement | null): HTMLElement {
  const b = el('button', { type: 'button', class: 'link' }, t.name);
  const dec = decider(t, d);
  // off: in the tab order, the reason beside it (its state cell) as its description, on hover too; on a demo instance
  // the name opens the tool's stored sample (its Run is the control that stays off there)
  if (!t.on && !d.demo) offControl(b, dec ? dec.what + (dec.how ? ' How: ' + dec.how : '') : 'off here', cell ?? above ?? undefined);
  b.addEventListener('click', open);
  return b;
}

// toolPanel: one procedure's (or read's) form, Run and its result
async function toolPanel(t: Tool, instance: number, d: Tools, page: PanelPage): Promise<HTMLElement> {
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
  const helpCells = new Map<string, [HTMLElement, HTMLInputElement]>();   // queue mode: filled by the help run below
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
    const helpCell = el('td', {}, x.help ?? '');
    helpCells.set(x.name.toLowerCase().replace(/^@/, ''), [helpCell, i]);
    table.append(el('tr', {}, el('td', {}, x.name), el('td', {}, x.type + (x.max_length !== 0 && /char/i.test(x.type) ? `(${x.max_length < 0 ? 'max' : /^n/i.test(x.type) ? x.max_length / 2 : x.max_length})` : '')), el('td', {}, i), helpCell));
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
  // the role (B24f): a tool's run needs operator - the form above reads (@help: every role)
  const run = needControl(el('button', { type: 'button' }, 'Run ' + t.name), 'community/run');
  fields.append(el('label', {}, 'Timeout (s) ', timeout), run);
  sec.append(fields);
  const status = el('p', { class: 'meta', role: 'status' }), res = el('div', {});
  sec.append(status, res);
  run.addEventListener('click', async () => {
    status.textContent = 'Running...'; offControl(run, 'running', status);
    const params: Record<string, string> = {};
    for (const [n, i] of inputs) if (i.value.trim() !== '') params[n] = i.value;
    try {
      const r = await post<{ runs: InstanceRun[]; ran_at: string } | Queued>('community/run', { instance_id: instance, tool: t.id, database: d.database ?? '', params, timeout_secs: Number(timeout.value || 60) });
      if (isQueued(r)) {
        res.replaceChildren();
        const e = await waitRequest(r, status, page.alive);   // the collector runs it; status says each state
        res.replaceChildren(...cutWords(e), endView(e, d.instance, d.engine, t.name));
      } else {
        res.replaceChildren(resultView(r.runs, undefined, t.name));
        status.textContent = `Ran at ${fmtTime(r.ran_at)}.`;
      }
    } catch (e) { res.replaceChildren(errorBox(e)); status.textContent = ''; }
    finally { offControl(run, null, status); void page.ended(); }
  });
  if (p.help_via === 'queue' && t.help) {
    // queue mode: the procedure's own help is a request of its own, run by the collector
    const det = el('details', {}, el('summary', {}, `${t.name}'s own help`));
    const hs = el('p', { class: 'meta', role: 'status' }), hb = el('div', {});
    const ask = needControl(el('button', { type: 'button' }, `Run ${t.name} ${t.help} = 1`), 'community/run');   // a request: operator (B24f)
    ask.addEventListener('click', async () => {
      offControl(ask, 'running', hs);
      try {
        const q = await post<Queued>('community/run?help=1', { instance_id: instance, tool: t.id, database: d.database ?? '' });
        const e = await waitRequest(q, hs, page.alive);
        if (e.state !== 'done') hb.replaceChildren(errorBox(e.refusal || e.outcome || e.state));   // '' in a row written before CQ-LIVEMASK
        else {
          hb.replaceChildren(...(e.result?.sets ?? []).flatMap((s, i) => [el('h3', {}, `${t.name} help, part ${i + 1}`), setGrid(s, i)]));
          // the procedure's own words per parameter, into the form's 'what it does' column (direct mode fills it at once)
          for (const [k, v] of Object.entries(e.result?.help ?? {})) {
            const c = helpCells.get(k.toLowerCase().replace(/^@/, ''));
            if (c && v && !c[0].textContent) { c[0].textContent = v; c[1].title = v; }
          }
        }
      } catch (e) { hb.replaceChildren(errorBox(e)); hs.textContent = ''; } finally { offControl(ask, null, hs); void page.ended(); }
    });
    det.append(ask, hs, hb);
    sec.append(det);
  }
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
  needControl(run, 'community/run');
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
function glennPanel(t: Tool, instance: number, database: string, page: PanelPage): HTMLElement {
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
    // the role (B24f): a run needs operator (the file's text is run as the read login)
    const b = needControl(el('button', { type: 'button', class: 'link' }, q.name), 'community/run');
    b.addEventListener('click', async () => {
      const busy = el('p', { class: 'meta' }, `Running query ${q.n} (${q.name})...`);
      res.replaceChildren(busy);
      offControl(b, 'running', busy);   // one run at a time from this button
      try {
        const r = await post<{ runs: InstanceRun[] } | Queued>('community/run', { instance_id: instance, tool: t.id, database: db.value, text: q.text, query_name: `${q.n} ${q.name}` });
        const title = `Query ${q.n} ${q.name}`;
        let view: HTMLElement;
        let cut: HTMLElement[] = [];
        if (isQueued(r)) {
          const e = await waitRequest(r, busy, page.alive);   // queue mode: the collector runs the query
          view = endView(e, e.instance ?? '', 'sqlserver', title);
          cut = cutWords(e);
        } else view = resultView(r.runs, undefined, title);
        res.replaceChildren(el('details', {}, el('summary', {}, `Query ${q.n}: the text sent`), el('pre', { class: 'sql', tabindex: '0' }, q.text)),
          ...cut, view);
      } catch (e) { res.replaceChildren(errorBox(e)); } finally { offControl(b, null, busy); void page.ended(); }
    });
    return b;
  };
  return sec;
}
