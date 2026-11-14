// Admin > Instances: 'Move from DBA Dash' (task 206). The servers a DBA Dash repository of pgvigil.yaml (dbadash:)
// collects, moved to pgvigil one by one: tick servers and give them one sign-in (Add: each becomes an instance this
// page manages, collected within 15 seconds); per moved server Count (a dry run of its DBA Dash history up to pgvigil's
// first read of it), Import (in pgvigil serve when the repository's import: true is set, else the exact command to run
// on the pgvigil host), the state, DBA Dash's Extended Events sessions on it with the DROP lines for its DBA, and the
// checklist; DBA Dash's services, with 'stop' once every server they collect is ready. Nothing here writes to DBA Dash
// or to a monitored server. Data from GET /api/admin/dbadash_moves, writes POST /api/admin/dbadash_moves
// (internal/web/q_migrate.go). The section is mounted by admin_instances.ts.
import { get } from './api';
import { addChunks, rowAddress } from './move_address';
import { badge, el, fmtTime, offControl } from './ui';

type Obj = Record<string, unknown>;
interface Repos { repositories: { name: string; import: boolean }[]; off: string; windows_off: string; gmsa: string; max_add: number; steps: string[] }
interface MoveData extends Repos {
  repository: string; import: boolean; import_off?: string; servers: Obj[];
  agents?: { agent_id: number; host: string; service: string; waiting: string[]; stop?: string }[]; agents_note?: string;
}

const STEP_WORDS: Record<string, string> = {
  dbadash_stopped: 'DBA Dash no longer collects this server (its service configuration: the DBA\'s step)',
  xe_dropped: 'DBA Dash\'s Extended Events sessions dropped on the server (the DBA ran the lines above)',
  service_stopped: 'the DBA Dash service that collected it is stopped (once all its servers moved)',
};
// a state's badge kind: the steps of a move in their colours
const STATE_KIND: Record<string, string> = {
  'not yet': '', 'imported only': 'info', 'collected by pgvigil': 'info', moving: 'info', collecting: 'info', importing: 'info',
  partial: 'warn', 'import failed': 'warn', 'import interrupted': 'warn', 'ready to switch': '', disabled: 'warn',
};
const MOVABLE = new Set(['not yet', 'imported only']);

// the instance name a server is offered under: its @@SERVERNAME made name-safe (the server's own rule, nameFor)
const safeName = (s: string) => s.replace(/[^A-Za-z0-9_.@-]+/g, '-').replace(/^[-._@]+|[-._@]+$/g, '').slice(0, 63);

async function post(data: Obj): Promise<{ ok: boolean; code: number; body: Obj }> {
  const res = await fetch('/api/admin/dbadash_moves', {
    method: 'POST', credentials: 'same-origin',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
    body: JSON.stringify(data),
  });
  let body: Obj = {};
  try { body = await res.json(); } catch { /* an empty answer */ }
  return { ok: res.ok, code: res.status, body };
}
const words = (b: Obj) => String(b.detail ?? b.error ?? b.outcome ?? 'refused');

function labelled(label: string, control: HTMLElement): HTMLElement {
  return el('label', { class: 'admin-field', style: 'display:inline-flex;flex-direction:column;margin:.25rem .6rem .25rem 0;font-size:.9em' }, label, control);
}

// moveSection is the section; it reads its own data and redraws itself after each write. refresh redraws it (the page
// calls it after its own writes); onAdded is the page's redraw, called after an add made instances. What the DBA has
// ticked and typed in the add form is kept across redraws (a poll during an import, another write), and the last add's
// results stay listed until the repository changes.
export function moveSection(onAdded: () => void = () => {}): { node: HTMLElement; refresh: () => void } {
  const root = el('section', { class: 'admin-moves', 'aria-labelledby': 'admin-moves-h' });
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const say = (text: string, bad = false) => { status.textContent = text; status.className = bad ? 'meta error' : 'meta'; };
  const body = el('div', {});
  const picker = el('select', { name: 'repository' });
  const results = el('ul', { class: 'meta', 'aria-label': 'The last add, server by server' });
  const draft = new Map<string, { tick: boolean; host: string; port: string; name: string }>();
  const sign = { auth: '', login: '', pw: '' };
  let repo = '';
  let poll = 0;
  let seq = 0; // the newest draw: an older GET landing after it draws nothing
  root.append(el('h3', { id: 'admin-moves-h' }, 'Move from DBA Dash'), status, body);

  async function start(): Promise<void> {
    let r: Repos;
    try { r = await get<Repos>('admin/dbadash_moves'); } catch (e) { say(`Not read: ${(e as Error).message}`, true); return; }
    if (!r.repositories.length) {
      body.replaceChildren(el('p', { class: 'meta' }, 'pgvigil.yaml names no DBA Dash repository (dbadash:): there is nothing to move from.'));
      return;
    }
    picker.replaceChildren(...r.repositories.map(x => el('option', { value: x.name }, x.name)));
    picker.addEventListener('change', () => { repo = picker.value; draft.clear(); results.replaceChildren(); void draw(); });
    repo = r.repositories[0].name;
    // the picker stays when a repository's read fails, so another can be picked
    root.insertBefore(labelled('DBA Dash repository', picker), body);
    await draw();
  }

  // the next poll: not once the page is left; not while the DBA types or ticks in the section (its focus would go)
  function schedule(): void {
    window.clearTimeout(poll);
    poll = window.setTimeout(() => {
      if (!root.isConnected) return;
      const a = document.activeElement;
      if (a && body.contains(a) && (a instanceof HTMLInputElement || a instanceof HTMLSelectElement)) { schedule(); return; }
      void draw();
    }, 5000);
  }

  async function draw(): Promise<void> {
    window.clearTimeout(poll);
    const my = ++seq;
    let d: MoveData;
    try { d = await get<MoveData>('admin/dbadash_moves', { repo }); } catch (e) { if (my === seq) say(`Not read: ${(e as Error).message}`, true); return; }
    if (my !== seq) return;
    const ro = d.off !== '';
    // the page's one read-only sentence describes every control that cannot write here (admin_instances.ts' way); a
    // button off for its own reason gets that reason as text beside it (offControl's note)
    const roNote = el('p', { class: 'meta', role: 'note', id: 'admin-moves-read-only' }, `Read only: ${d.off}.`);
    const off = (c: HTMLElement, why: string): HTMLElement | null => {
      const ref = why === d.off ? roNote : undefined;
      if (c instanceof HTMLButtonElement) { const n = offControl(c, why, ref); return ref ? null : n; }
      (c as HTMLInputElement).disabled = true; c.title = why;
      if (ref) c.setAttribute('aria-describedby', ref.id);
      return null;
    };
    const servers = d.servers ?? [];
    const ticked = new Map<string, { box: HTMLInputElement; host: HTMLInputElement; port: HTMLInputElement; name: HTMLInputElement; row: Obj }>();
    let rowN = 0;

    // the list: one row per server (@@SERVERNAME), a tick for the servers that can move
    const table = el('table', { class: 'grid' });
    table.append(el('caption', {}, `DBA Dash repository ${d.repository}: ${servers.length} server(s)`));
    table.append(el('thead', {}, el('tr', {}, ...['Move', 'Server', 'DBA Dash InstanceIDs', 'DBA Dash connects as', 'Host (pgvigil connects to)', 'Port', 'pgvigil name', 'State', 'pgvigil instance', 'pgvigil first read', 'History'].map(h => el('th', { scope: 'col' }, h)))));
    const tb = el('tbody', {});
    for (const s of servers) {
      const srv = String(s.server), state = String(s.state);
      const conns = (s.connection_ids as string[] | null) ?? [];
      const cells: (HTMLElement | string)[] = ['', '', '', ''];
      if (MOVABLE.has(state)) {
        const at = rowAddress(srv, conns);
        // the DBA's own ticks and edits come back on every redraw (a poll, another write)
        const dr = draft.get(srv) ?? { tick: false, host: at.host, port: at.port, name: safeName(srv) };
        draft.set(srv, dr);
        const box = el('input', { type: 'checkbox', 'aria-label': `Move ${srv}` });
        box.checked = dr.tick;
        const host = el('input', { name: 'host', type: 'text', autocomplete: 'off', value: dr.host, size: '22', 'aria-label': `Host of ${srv} (as pgvigil connects to it)` });
        const port = el('input', { name: 'port', type: 'text', inputmode: 'numeric', autocomplete: 'off', value: dr.port, size: '6', 'aria-label': `Port of ${srv} (empty: 1433, or the SQL Browser's for a named instance)` });
        const name = el('input', { name: 'name', type: 'text', autocomplete: 'off', value: dr.name, maxlength: '63', size: '22', 'aria-label': `pgvigil name of ${srv}` });
        box.addEventListener('change', () => { dr.tick = box.checked; });
        host.addEventListener('input', () => { dr.host = host.value; });
        port.addEventListener('input', () => { dr.port = port.value; });
        name.addEventListener('input', () => { dr.name = name.value; });
        ticked.set(srv, { box, host, port, name, row: s });
        const why = at.why ? el('span', { class: 'meta', id: `admin-move-why-${++rowN}` }, at.why) : null;
        if (why) { host.setAttribute('aria-describedby', why.id); port.setAttribute('aria-describedby', why.id); }
        if (ro) { off(box, d.off); off(host, d.off); off(port, d.off); off(name, d.off); }
        cells.splice(0, 4, box, el('span', {}, host, ...(why ? [el('br', {}), why] : [])), port, name);
      }
      tb.append(el('tr', {},
        el('td', {}, cells[0]), el('th', { scope: 'row' }, srv), el('td', {}, ((s.dbadash_ids as number[]) ?? []).join(', ')), el('td', {}, conns.join(', ')),
        el('td', {}, cells[1]), el('td', {}, cells[2]), el('td', {}, cells[3]),
        el('td', {}, badge(state, STATE_KIND[state] ?? '')), el('td', {}, String(s.instance_name ?? s.collected_as ?? s.imported_as ?? '')),
        el('td', {}, fmtTime(s.collect_from)), el('td', {}, historyWords(s))));
    }
    table.append(tb);

    // the add: one sign-in for every ticked server
    const auth = el('select', { name: 'auth' });
    for (const [v, t] of [['sql', 'SQL login'], ['entra', 'Entra service principal'], ['entra-identity', 'Entra managed identity (this host\'s own, no secret)'], ['windows', d.gmsa ? `Windows: the gMSA ${d.gmsa}` : 'Windows (the gMSA the service runs as)']]) {
      const o = el('option', { value: v }, t);
      if (v === 'windows' && d.windows_off) { o.disabled = true; o.textContent = `${t}: ${d.windows_off}`; }
      auth.append(o);
    }
    if (sign.auth && [...auth.options].some(o => o.value === sign.auth && !o.disabled)) auth.value = sign.auth;
    const login = el('input', { name: 'login', type: 'text', autocomplete: 'off', value: sign.login });
    const pw = el('input', { name: 'password', type: 'password', autocomplete: 'new-password' });
    pw.value = sign.pw;
    auth.addEventListener('change', () => { sign.auth = auth.value; });
    login.addEventListener('input', () => { sign.login = login.value; });
    pw.addEventListener('input', () => { sign.pw = pw.value; });
    const add = el('button', { type: 'button' }, 'Add the ticked servers');
    add.addEventListener('click', async () => {
      const pick = [...ticked.values()].filter(t => t.box.checked);
      if (!pick.length) { say('Tick the servers to move first.', true); return; }
      if (pick.length > d.max_add) { say(`At most ${d.max_add} servers in one add: untick ${pick.length - d.max_add}.`, true); return; }
      add.disabled = true; say('Working…');
      try {
        // one post per part under the server's 16 KB body (review 206d 13: 50 long names pass it in one)
        const base = { op: 'add', repo, auth: auth.value, login: login.value.trim(), password: pw.value };
        const all = pick.map(t => ({ server: String(t.row.server), dbadash_ids: t.row.dbadash_ids, host: t.host.value.trim(), port: t.port.value.trim(), name: t.name.value.trim() }));
        const res: Obj[] = [];
        for (const part of addChunks(base, all)) {
          const r = await post({ ...base, servers: part });
          if (!r.ok) {
            say(`Not added: ${words(r.body)}${res.length ? ` (the ${res.length} server(s) of the parts before were sent: the list shows them)` : ''}`, true);
            add.disabled = false;
            if (res.length) await draw();
            return;
          }
          res.push(...((r.body.results as Obj[]) ?? []));
        }
        const done = res.filter(x => x.outcome === 'done').length;
        // each server's answer stays listed (the list is the section's, kept across the redraw); an added server's draft
        // and the password go
        results.replaceChildren(...res.map(x => el('li', {}, `${String(x.server)} as ${String(x.name)}: ${String(x.outcome)}${x.detail ? ` - ${String(x.detail)}` : ''}`)));
        for (const x of res) if (x.outcome === 'done') draft.delete(String(x.server));
        sign.pw = '';
        await draw();
        if (done) onAdded();
        say(done === res.length ? `${done} of ${res.length} added: the collector starts on each within 15 seconds.`
          : `${done} of ${res.length} added; each refusal's reason is listed below${done ? ': the collector starts on the added within 15 seconds' : ''}.`, done < res.length);
      } catch (e) { say(`Not added: ${(e as Error).message}`, true); add.disabled = false; }
    });
    if (ro) for (const c of [auth, login, pw, add]) off(c, d.off);
    const form = el('fieldset', {}, el('legend', {}, 'Add the ticked servers to pgvigil'),
      el('p', { class: 'meta' }, 'Each ticked server becomes an instance of this page with this sign-in (its host and port as DBA Dash connects to it when that is a network address, else DBA Dash\'s Instance name with why - both editable in its row); its DBA Dash history can be imported once pgvigil has read it.'),
      el('div', {}, labelled('Authentication', auth), labelled('Login', login), labelled('Password', pw), ' ', add), results);

    // each moved server: Count, Import, XE, checklist
    const moved = servers.filter(s => s.instance_id != null);
    const cards = moved.map(s => movedCard(s, d, ro, off));

    const agents = d.agents ? el('ul', {}, ...d.agents.map(a => el('li', {}, `DBA Dash service ${a.service} on ${a.host}: `,
      a.stop ? el('strong', {}, a.stop) : `waiting for ${a.waiting.join(', ')} to be ready to switch`)))
      : el('p', { class: 'meta' }, d.agents_note ?? '');

    body.replaceChildren(
      ro ? roNote : '',
      d.import_off ? el('p', { class: 'meta', role: 'note' }, d.import_off + '.') : '',
      table, form,
      el('h4', {}, `Moved servers (${moved.length})`), ...(cards.length ? cards : [el('p', { class: 'meta' }, 'No server of this repository was moved yet.')]),
      el('h4', {}, 'DBA Dash\'s services'), agents,
    );
    // a running import: the list again in 5 seconds
    if (servers.some(s => s.state === 'importing' || (s.job && !(s.job as Obj).ended))) schedule();
  }

  function movedCard(s: Obj, d: MoveData, ro: boolean, off: (c: HTMLElement, why: string) => HTMLElement | null): HTMLElement {
    const name = String(s.instance_name), srv = String(s.server);
    const count = el('button', { type: 'button', 'aria-label': `Count the DBA Dash history of ${name}` }, 'Count');
    count.addEventListener('click', async () => {
      count.disabled = true; say(`Counting the DBA Dash history of ${name}…`);
      try {
        const r = await post({ op: 'count', repo, name });
        await draw();
        say(r.ok ? `${name}: ${countWords(r.body.counts as Obj)}` : `Not counted: ${words(r.body)}`, !r.ok);
      } catch (e) { count.disabled = false; say(`Not counted: ${(e as Error).message}`, true); }
    });
    const parts: (HTMLElement | string)[] = [count, ' '];
    if (d.import) {
      const imp = el('button', { type: 'button', 'aria-label': `Import the DBA Dash history of ${name}` }, 'Import');
      imp.addEventListener('click', async () => {
        imp.disabled = true; say(`Starting the import of ${name}…`);
        try {
          const r = await post({ op: 'import', repo, name });
          await draw();
          say(r.ok ? words(r.body) : `Not started: ${words(r.body)}`, !r.ok);
        } catch (e) { imp.disabled = false; say(`Not started: ${(e as Error).message}`, true); }
      });
      parts.push(imp);
      const why = ro ? d.off : s.collect_from == null ? `pgvigil has not read ${name} yet: its history is imported up to that first read, after it` : '';
      const note = why ? off(imp, why) : null;
      if (note) parts.push(' ', note);
    } else {
      parts.push(el('span', { class: 'meta' }, 'Import here is off for this repository; on the pgvigil host run: '), el('code', {}, String(s.command ?? '')));
    }
    if (ro) off(count, d.off);
    const xe = (s.xe ?? {}) as Obj;
    const sessions = (xe.sessions as Obj[]) ?? [];
    const xeBox = el('div', {},
      el('p', { class: 'meta' }, xe.read_at ? `DBA Dash's Extended Events sessions on ${srv}, as pgvigil listed them ${fmtTime(xe.read_at)}: ${sessions.length || 'none'}` : `DBA Dash's Extended Events sessions on ${srv}: not listed by pgvigil yet.`),
      sessions.length ? el('ul', {}, ...sessions.map(x => el('li', {}, `${String(x.name)} (${x.running ? 'running' : 'stopped'}; ${((x.targets as string[]) ?? []).join(', ')})${x.note ? ` - ${String(x.note)}` : ''}`))) : '',
      xe.note ? el('p', { class: 'meta' }, String(xe.note)) : '',
      xe.read ? el('p', { class: 'meta' }, `The read to run on ${srv}:`) : '',
      xe.read ? el('pre', {}, String(xe.read)) : '',
      ((xe.drop as string[]) ?? []).length ? el('p', { class: 'meta' }, `The DROP lines for ${srv}'s DBA:`) : '',
      ((xe.drop as string[]) ?? []).length ? el('pre', {}, ((xe.drop as string[]) ?? []).join('\n')) : '');
    const ticks = (s.ticks ?? {}) as Record<string, { done: boolean; at: string; by: string }>;
    const list = el('ul', { class: 'admin-checklist' }, ...d.steps.map(step => {
      const t = ticks[step];
      const box = el('input', { type: 'checkbox', 'aria-label': `${name}: ${STEP_WORDS[step] ?? step}` });
      box.checked = !!t?.done;
      box.addEventListener('change', async () => {
        box.disabled = true;
        try {
          const r = await post({ op: 'tick', repo, name, step, done: box.checked });
          if (!r.ok) { box.checked = !box.checked; box.disabled = false; say(`Not kept: ${words(r.body)}`, true); return; }
          await draw();
          say(`${name}: kept.`);
        } catch (e) { box.checked = !box.checked; box.disabled = false; say(`Not kept: ${(e as Error).message}`, true); }
      });
      if (ro) off(box, d.off);
      return el('li', {}, el('label', {}, box, ' ', STEP_WORDS[step] ?? step), t ? el('span', { class: 'meta' }, ` (${t.by}, ${fmtTime(t.at)})`) : '');
    }));
    return el('article', { class: 'admin-move', 'aria-label': `${srv} moved as ${name}` },
      el('h5', {}, `${srv} as ${name} `, badge(String(s.state), STATE_KIND[String(s.state)] ?? '')),
      el('p', { class: 'meta' }, s.collect_from ? `pgvigil collects it since ${fmtTime(s.collect_from)}.` : 'pgvigil has not read it yet.',
        s.counted_at ? ` Counted ${fmtTime(s.counted_at)}: ${countWords(s.counts as Obj)}.` : '',
        s.run_outcome ? ` The last import: ${String(s.run_outcome)} ${fmtTime(s.run_ended)}.` : ''),
      el('div', { class: 'actions' }, ...parts), xeBox, list);
  }

  void start();
  return { node: root, refresh: () => { if (repo) void draw(); } };
}

// historyWords is a row's History: serve's own job while it runs, or when it is this move's latest run (a later run -
// from the CLI, another serve - is the store's, and its words win); else the store's last run, import or count.
function historyWords(s: Obj): string {
  const job = s.job as Obj | undefined;
  const runAt = s.run_started ? Date.parse(String(s.run_started)) : NaN;
  if (job && (!job.ended || Number.isNaN(runAt) || Date.parse(String(job.started)) >= runAt - 60_000)) return jobWords(job);
  if (s.run_outcome && s.run_ended) return `import ${String(s.run_outcome)} ${fmtTime(s.run_ended)}`;
  if (s.imported_at) return `imported ${fmtTime(s.imported_at)}`;
  return s.counted_at ? `counted ${fmtTime(s.counted_at)}: ${countWords(s.counts as Obj)}` : '';
}

function countWords(c: Obj | null | undefined): string {
  if (!c) return '';
  return Object.entries(c).map(([k, v]) => {
    const x = (v ?? {}) as Obj;
    return `${k} ${String(x.source ?? 0)} in DBA Dash, ${String(x.stored ?? 0)} in pgvigil${x.skipped ? ` (${String(x.skipped)})` : ''}`;
  }).join('; ');
}

function jobWords(j: Obj): string {
  const rows = Object.entries((j.inserted ?? {}) as Obj).map(([k, v]) => `${k} ${String(v)}`).join(', ');
  const notes = Array.isArray(j.notes) && j.notes.length ? ` (${(j.notes as string[]).join('; ')})` : '';
  return j.ended ? `import ${String(j.outcome)} ${fmtTime(j.ended)}${rows ? `: ${rows}` : ''}${notes}` : `importing since ${fmtTime(j.started)}${rows ? `: ${rows} so far` : ''}`;
}
