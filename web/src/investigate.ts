// The agent door's pages (docs/agents.md): the Investigate button beside a finding, the Ask box and the Investigations
// page. pgvigil holds no agent: the site's own agent claims these requests through `pgvigil mcp` and reports; the page
// shows a report as the agent's own unreviewed words (plain text, never markup), and an answered ask's one SELECT runs
// on Run as the custom reports' store login, so the rows shown are pgvigil's own read. Off (agents.enabled not set),
// GET /api/investigations answers 404 with the words: the findings draw no button and this page says the words.
import { get, post } from './api';
import { hashParam } from './dbinfo';
import type { Ctx } from './router';
import { badge, Col, el, fmtTime, grid, offControl } from './ui';

export interface InvRow {
  id: number; kind: string; instance_id?: number | null; instance?: string | null; setting?: string | null; severity?: string | null;
  state: string; asked_by: string; asked_at: string; claimed_by?: string | null; verdict?: string | null; reported_at?: string | null;
  [k: string]: unknown;
}
interface RunState { enabled: boolean; said: string }
export interface InvList { enabled: boolean; rows: InvRow[]; run: RunState; writable: boolean; said: string }
interface Journal { id: number; at: string; event: string; login?: string | null; rows?: number | null; ms?: number | null; outcome?: string | null; text?: string | null }
interface Detail {
  row: InvRow;
  request: { snapshot?: Record<string, unknown> | null; note?: string | null; question?: string | null };
  report?: { verdict: string; reported_at: string; summary?: string | null; body?: string | null; evidence?: Record<string, unknown>[] | null;
    queries_run?: string[] | null; sql?: string | null } | null;
  journal: Journal[];
  run: RunState;
}
interface RunAnswer { columns: string[]; rows: unknown[][]; cut: boolean; ms: number }

export const reportWords = 'A report is the agent\'s own words: unreviewed. pgvigil holds no agent; the site\'s own agent claims these requests through pgvigil mcp (docs/agents.md).';

// investigations: the door's list, or null when it is off (404) or cannot be read
export async function investigations(instance?: number): Promise<InvList | null> {
  try { return await get<InvList>('investigations', { instance }); } catch { return null; }
}

const live = (s: string) => s === 'open' || s === 'claimed' || s === 'reported';

function stateBadge(r: InvRow): HTMLElement {
  if (r.state === 'claimed') return badge(`claimed by ${r.claimed_by ?? 'an agent'}`, 'warn');
  if (r.state === 'reported') return badge('report ready', 'ok');
  if (r.state === 'open') return badge('open', 'info');
  return badge(r.state, '');
}

function invLink(id: number, text: string | Node): HTMLAnchorElement {
  return el('a', { href: `#/investigations?id=${id}` }, text);
}

// a modal that asks for one text and posts it; the server's answer in place
function askDialog(title: string, what: string, label: string, max: number, required: boolean, send: (text: string) => Promise<{ id?: number | null }>) {
  const ta = el('textarea', { rows: '4', maxlength: String(max), 'aria-label': label, style: 'width:100%' });
  const ok = el('button', { type: 'submit' }, 'Send');
  const no = el('button', { type: 'button' }, 'Back');
  const msg = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const form = el('form', { method: 'dialog' }, el('h3', {}, title), el('p', {}, what),
    el('label', {}, label, el('br'), ta), msg, el('div', { style: 'margin-top:.6rem' }, ok, ' ', no));
  const dlg = el('dialog', { class: 'act-dialog', style: 'max-width:36rem', 'aria-label': title }, form);
  const close = () => { dlg.close(); dlg.remove(); };
  no.addEventListener('click', close);
  dlg.addEventListener('cancel', () => dlg.remove());
  form.addEventListener('submit', async ev => {
    ev.preventDefault();
    if (required && !ta.value.trim()) { msg.textContent = `${label} is empty.`; return; }
    ok.disabled = true;
    msg.textContent = 'Sending...';
    try {
      const r = await send(ta.value.trim());
      msg.replaceChildren(badge('asked', 'ok'), ' ', r.id ? invLink(r.id, `investigation ${r.id}`) : '', ': an agent the site runs claims it.');
      no.textContent = 'Close';
    } catch (e) {
      msg.replaceChildren(badge('not asked', 'crit'), ' ', e instanceof Error ? e.message : String(e));
      ok.disabled = false;
      no.textContent = 'Close';
    }
  });
  document.body.append(dlg);
  dlg.showModal();
  ta.focus();
}

// investigateCol: the findings grid's column - the latest live request of the finding as a badge (a link to it), else
// the Investigate button (off with its words where requests cannot be written here)
export function investigateCol(list: InvList): Col {
  const latest = new Map<string, InvRow>();
  for (const r of list.rows) {
    const k = `${r.instance_id}|${r.setting}`;
    if (r.kind === 'finding' && live(r.state) && !latest.has(k)) latest.set(k, r);   // the list is newest first
  }
  return {
    key: 'investigate', label: 'agent',
    fmt: (_v, row) => {
      const r = latest.get(`${row.instance_id}|${row.setting}`);
      if (r) return invLink(r.id, stateBadge(r));
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `Investigate ${String(row.setting)} on ${String(row.instance ?? 'this instance')}` }, 'Investigate');
      if (!list.writable) { offControl(b, list.said); return b; }
      b.addEventListener('click', () => askDialog(`Investigate ${String(row.setting)}`,
        'Opens a request an agent the site runs claims through pgvigil mcp; pgvigil keeps the finding as this page shows it now.',
        'Note for the agent (optional)', 1000, false,
        note => post('investigations', { kind: 'finding', instance_id: Number(row.instance_id), setting: String(row.setting), note })));
      return b;
    },
  };
}

function pre(text: string | null | undefined): HTMLElement {
  return el('pre', { class: 'report-text' }, text ?? '');
}

async function detail(id: number, after: () => void): Promise<HTMLElement> {
  const d = await get<Detail>('investigations', { id });
  const r = d.row;
  const what = r.kind === 'ask' ? `the question of ${r.asked_by}` : `${r.setting ?? ''} on ${r.instance ?? 'a removed instance'}`;
  const box = el('section', { class: 'inv-detail', 'aria-label': `Investigation ${id}` },
    el('h3', {}, `Investigation ${id}: ${what} `, stateBadge(r)),
    el('p', { class: 'meta' }, `Asked by ${r.asked_by} at ${fmtTime(r.asked_at)}` + (r.claimed_by ? `; claimed by ${r.claimed_by}` : '') + '.'));
  if (d.request.question) box.append(el('h4', {}, 'Question'), pre(d.request.question));
  if (d.request.note) box.append(el('h4', {}, 'Note for the agent'), pre(d.request.note));
  if (d.request.snapshot) {
    const s = d.request.snapshot;
    box.append(el('h4', {}, 'The finding when it was asked'),
      el('p', {}, `${String(s.severity ?? '')} ${String(s.setting ?? '')}: ${String(s.value ?? '')}` + (s.suggested ? ` (suggested ${String(s.suggested)})` : '')),
      ...(s.detail ? [pre(String(s.detail))] : []));
  }
  if (d.report) {
    const rep = d.report;
    box.append(el('h4', {}, 'Report'),
      el('p', { class: 'said' }, `${reportWords} Verdict: ${rep.verdict}, reported ${fmtTime(rep.reported_at)}.`),
      pre(rep.summary));
    if (rep.body) box.append(el('h4', {}, 'Reasoning'), pre(rep.body));
    if (rep.evidence?.length) {
      box.append(el('h4', {}, 'Evidence'), grid(rep.evidence.map(e => ({ tool: e.tool, arguments: JSON.stringify(e.arguments ?? {}), key_numbers: e.key_numbers, basis: e.basis })),
        [{ key: 'tool' }, { key: 'arguments', wide: true }, { key: 'key_numbers', label: 'key numbers', wide: true }, { key: 'basis' }]));
    }
    if (rep.queries_run?.length) box.append(el('h4', {}, 'Queries the agent ran'), ...rep.queries_run.map(q => pre(q)));
    if (rep.sql) {
      const out = el('div', {});
      const run = el('button', { type: 'button' }, 'Run');
      const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
      if (!d.run.enabled) offControl(run, d.run.said, said);
      else run.addEventListener('click', async () => {
        run.disabled = true;
        said.textContent = 'Running...';
        try {
          const a = await post<RunAnswer>('investigations/run', { id });
          said.textContent = `${a.rows.length} row(s) in ${a.ms} ms` + (a.cut ? ', cut at 1,000' : '') + ': pgvigil\'s own read, as the reports login.';
          out.replaceChildren(grid(a.rows.map(row => Object.fromEntries(a.columns.map((c, i) => [c, row[i]]))), a.columns.map(c => ({ key: c }))));
        } catch (e) {
          said.textContent = e instanceof Error ? e.message : String(e);
        }
        run.disabled = false;
      });
      box.append(el('h4', {}, 'The answer\'s SELECT'), pre(rep.sql), el('div', {}, run), said, out);
    }
  }
  box.append(el('h4', {}, 'Record'), grid(d.journal as unknown as Record<string, unknown>[], [
    { key: 'at', fmt: fmtTime }, { key: 'event' }, { key: 'login' }, { key: 'rows', num: true }, { key: 'ms', num: true },
    { key: 'outcome', wide: true }, { key: 'text', label: 'statement or reason', wide: true }]));
  if (r.state !== 'closed') {
    const close = el('button', { type: 'button' }, 'Close the request');
    close.addEventListener('click', () => {
      const why = window.prompt('Why is it closed? (kept in its record)') ?? '';
      void post('investigations/close', { id, reason: why }).then(after, e => window.alert(e instanceof Error ? e.message : String(e)));
    });
    box.append(el('div', { style: 'margin-top:.6rem' }, close));
  }
  return box;
}

// investigationsView: the Investigations page - the Ask box, the requests, one request's report (?id=)
export async function investigationsView(_c: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Investigations'));
  let list: InvList;
  try { list = await get<InvList>('investigations'); } catch (e) {
    sec.append(el('p', { class: 'said' }, e instanceof Error ? e.message : String(e)));
    return sec;
  }
  const redraw = () => { window.dispatchEvent(new HashChangeEvent('hashchange')); };
  const ask = el('textarea', { rows: '3', maxlength: '2000', 'aria-label': 'Ask', name: 'ask', style: 'width:100%',
    placeholder: 'A question about the fleet: the agent answers it with one SELECT over the repository, which Run then runs here' });
  const go = el('button', { type: 'button' }, 'Ask');
  const said = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  if (!list.writable) offControl(go, list.said, said);
  else go.addEventListener('click', async () => {
    const q = ask.value.trim();
    if (!q) { said.textContent = 'The question is empty.'; return; }
    go.disabled = true;
    try {
      const r = await post<{ id: number }>('investigations', { kind: 'ask', question: q });
      location.hash = `#/investigations?id=${r.id}`;
    } catch (e) {
      said.textContent = e instanceof Error ? e.message : String(e);
      go.disabled = false;
    }
  });
  sec.append(el('div', { class: 'askbox' }, el('label', {}, 'Ask a question', el('br'), ask), el('div', {}, go), said),
    el('p', { class: 'meta' }, reportWords));
  const cols: Col[] = [
    { key: 'id', num: true, fmt: v => invLink(Number(v), String(v)) },
    { key: 'state', fmt: (_v, row) => stateBadge(row as InvRow) },
    { key: 'kind' }, { key: 'instance' }, { key: 'setting', label: 'finding' },
    { key: 'asked_by', label: 'asked by' }, { key: 'asked_at', label: 'asked', fmt: fmtTime },
    { key: 'claimed_by', label: 'agent' }, { key: 'verdict' }, { key: 'reported_at', label: 'reported', fmt: fmtTime },
  ];
  sec.append(grid(list.rows, cols, 'No investigations yet: press Investigate beside a finding, or ask a question above.'));
  const id = Number(hashParam('id'));
  if (id > 0) {
    try { sec.append(await detail(id, redraw)); } catch (e) { sec.append(el('p', { class: 'said' }, e instanceof Error ? e.message : String(e))); }
  }
  return sec;
}
