// Admin > Instances: 'Move from DBA Dash' (task 206). The servers a DBA Dash repository of pgvigil.yaml (dbadash:)
// collects, moved to pgvigil one by one: tick servers and give them one sign-in (Add: each becomes an instance this
// page manages, collected within 15 seconds); per moved server Count (a dry run of its DBA Dash history up to pgvigil's
// first read of it), Import (in pgvigil serve when the repository's import: true is set, else the exact command to run
// on the pgvigil host), the state, DBA Dash's Extended Events sessions on it with the DROP lines for its DBA, and the
// checklist; DBA Dash's services, with 'stop' once every server they collect is ready. Nothing here writes to DBA Dash
// or to a monitored server. Data from GET /api/admin/dbadash_moves, writes POST /api/admin/dbadash_moves
// (internal/web/q_migrate.go). The section is mounted by admin_instances.ts.
import { get } from './api';
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
  partial: 'warn', 'import failed': 'warn', 'ready to switch': '', disabled: 'warn',
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

// moveSection is the section; it reads its own data and redraws itself after each write.
export function moveSection(): HTMLElement {
  const root = el('section', { class: 'admin-moves', 'aria-labelledby': 'admin-moves-h' });
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const say = (text: string, bad = false) => { status.textContent = text; status.className = bad ? 'meta error' : 'meta'; };
  const body = el('div', {});
  const picker = el('select', { name: 'repository' });
  let repo = '';
  let poll = 0;
  root.append(el('h3', { id: 'admin-moves-h' }, 'Move from DBA Dash'), status, body);

  async function start(): Promise<void> {
    let r: Repos;
    try { r = await get<Repos>('admin/dbadash_moves'); } catch (e) { say(`Not read: ${(e as Error).message}`, true); return; }
    if (!r.repositories.length) {
      body.replaceChildren(el('p', { class: 'meta' }, 'pgvigil.yaml names no DBA Dash repository (dbadash:): there is nothing to move from.'));
      return;
    }
    picker.replaceChildren(...r.repositories.map(x => el('option', { value: x.name }, x.name)));
    picker.addEventListener('change', () => { repo = picker.value; void draw(); });
    repo = r.repositories[0].name;
    await draw();
  }

  async function draw(): Promise<void> {
    window.clearTimeout(poll);
    let d: MoveData;
    try { d = await get<MoveData>('admin/dbadash_moves', { repo }); } catch (e) { say(`Not read: ${(e as Error).message}`, true); return; }
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
    const ticked = new Map<string, { box: HTMLInputElement; host: HTMLInputElement; name: HTMLInputElement; row: Obj }>();

    // the list: one row per server (@@SERVERNAME), a tick for the servers that can move
    const table = el('table', { class: 'grid' });
    table.append(el('caption', {}, `DBA Dash repository ${d.repository}: ${servers.length} server(s)`));
    table.append(el('thead', {}, el('tr', {}, ...['Move', 'Server', 'DBA Dash InstanceIDs', 'Connects as', 'State', 'pgvigil instance', 'pgvigil first read', 'History'].map(h => el('th', { scope: 'col' }, h)))));
    const tb = el('tbody', {});
    for (const s of servers) {
      const srv = String(s.server), state = String(s.state);
      const conns = (s.connection_ids as string[] | null) ?? [];
      let tick: HTMLElement | string = '';
      if (MOVABLE.has(state)) {
        const box = el('input', { type: 'checkbox', 'aria-label': `Move ${srv}` });
        const host = el('input', { name: 'host', type: 'text', autocomplete: 'off', value: conns[0] ?? '', size: '22', 'aria-label': `Host of ${srv} (as pgvigil connects to it)` });
        const name = el('input', { name: 'name', type: 'text', autocomplete: 'off', value: safeName(srv), maxlength: '63', size: '22', 'aria-label': `pgvigil instance name of ${srv}` });
        ticked.set(srv, { box, host, name, row: s });
        if (ro) { off(box, d.off); off(host, d.off); off(name, d.off); }
        tick = el('span', {}, box, ' ', host, ' ', name);
      }
      const hist = s.job ? jobWords(s.job as Obj) : s.imported_at ? `imported ${fmtTime(s.imported_at)}` : s.counted_at ? `counted ${fmtTime(s.counted_at)}: ${countWords(s.counts as Obj)}` : '';
      tb.append(el('tr', {},
        el('td', {}, tick), el('th', { scope: 'row' }, srv), el('td', {}, ((s.dbadash_ids as number[]) ?? []).join(', ')), el('td', {}, conns.join(', ')),
        el('td', {}, badge(state, STATE_KIND[state] ?? '')), el('td', {}, String(s.instance_name ?? s.collected_as ?? s.imported_as ?? '')),
        el('td', {}, fmtTime(s.collect_from)), el('td', {}, hist)));
    }
    table.append(tb);

    // the add: one sign-in for every ticked server
    const auth = el('select', { name: 'auth' });
    for (const [v, t] of [['sql', 'SQL login'], ['entra', 'Entra service principal'], ['entra-identity', 'Entra managed identity (this host\'s own, no secret)'], ['windows', d.gmsa ? `Windows: the gMSA ${d.gmsa}` : 'Windows (the gMSA the service runs as)']]) {
      const o = el('option', { value: v }, t);
      if (v === 'windows' && d.windows_off) { o.disabled = true; o.textContent = `${t}: ${d.windows_off}`; }
      auth.append(o);
    }
    const login = el('input', { name: 'login', type: 'text', autocomplete: 'off' });
    const pw = el('input', { name: 'password', type: 'password', autocomplete: 'new-password' });
    const add = el('button', { type: 'button' }, 'Add the ticked servers');
    const results = el('ul', { class: 'meta' });
    add.addEventListener('click', async () => {
      const pick = [...ticked.values()].filter(t => t.box.checked);
      if (!pick.length) { say('Tick the servers to move first.', true); return; }
      if (pick.length > d.max_add) { say(`At most ${d.max_add} servers in one add: untick ${pick.length - d.max_add}.`, true); return; }
      add.disabled = true; say('Working…');
      try {
        const r = await post({ op: 'add', repo, auth: auth.value, login: login.value.trim(), password: pw.value,
          servers: pick.map(t => ({ server: String(t.row.server), dbadash_ids: t.row.dbadash_ids, host: t.host.value.trim(), name: t.name.value.trim() })) });
        if (!r.ok) { say(`Not added: ${words(r.body)}`, true); add.disabled = false; return; }
        const res = (r.body.results as Obj[]) ?? [];
        const done = res.filter(x => x.outcome === 'done').length;
        await draw();
        results.replaceChildren(...res.map(x => el('li', {}, `${String(x.server)} as ${String(x.name)}: ${String(x.outcome)}${x.detail ? ` - ${String(x.detail)}` : ''}`)));
        say(`${done} of ${res.length} added: the collector starts on each within 15 seconds.`, done < res.length);
      } catch (e) { say(`Not added: ${(e as Error).message}`, true); add.disabled = false; }
    });
    if (ro) for (const c of [auth, login, pw, add]) off(c, d.off);
    const form = el('fieldset', {}, el('legend', {}, 'Add the ticked servers to pgvigil'),
      el('p', { class: 'meta' }, 'Each ticked server becomes an instance of this page with this sign-in (its host as DBA Dash connects to it, editable in its row); its DBA Dash history can be imported once pgvigil has read it.'),
      el('div', {}, labelled('Authentication', auth), labelled('Login', login), labelled('Password', pw), ' ', add), results);

    // each moved server: Count, Import, XE, checklist
    const moved = servers.filter(s => s.instance_id != null);
    const cards = moved.map(s => movedCard(s, d, ro, off));

    const agents = d.agents ? el('ul', {}, ...d.agents.map(a => el('li', {}, `DBA Dash service ${a.service} on ${a.host}: `,
      a.stop ? el('strong', {}, a.stop) : `waiting for ${a.waiting.join(', ')} to be ready to switch`)))
      : el('p', { class: 'meta' }, d.agents_note ?? '');

    body.replaceChildren(
      labelled('DBA Dash repository', picker),
      ro ? roNote : '',
      d.import_off ? el('p', { class: 'meta', role: 'note' }, d.import_off + '.') : '',
      table, form,
      el('h4', {}, `Moved servers (${moved.length})`), ...(cards.length ? cards : [el('p', { class: 'meta' }, 'No server of this repository was moved yet.')]),
      el('h4', {}, 'DBA Dash\'s services'), agents,
    );
    // a running import: the list again in 5 seconds
    if (servers.some(s => s.state === 'importing' || (s.job && !(s.job as Obj).ended))) poll = window.setTimeout(() => { void draw(); }, 5000);
  }

  function movedCard(s: Obj, d: MoveData, ro: boolean, off: (c: HTMLElement, why: string) => HTMLElement | null): HTMLElement {
    const name = String(s.instance_name), srv = String(s.server);
    const count = el('button', { type: 'button', 'aria-label': `Count the DBA Dash history of ${name}` }, 'Count');
    count.addEventListener('click', async () => {
      count.disabled = true; say(`Counting the DBA Dash history of ${name}…`);
      const r = await post({ op: 'count', repo, name });
      await draw();
      say(r.ok ? `${name}: ${countWords(r.body.counts as Obj)}` : `Not counted: ${words(r.body)}`, !r.ok);
    });
    const parts: (HTMLElement | string)[] = [count, ' '];
    if (d.import) {
      const imp = el('button', { type: 'button', 'aria-label': `Import the DBA Dash history of ${name}` }, 'Import');
      imp.addEventListener('click', async () => {
        imp.disabled = true; say(`Starting the import of ${name}…`);
        const r = await post({ op: 'import', repo, name });
        await draw();
        say(r.ok ? words(r.body) : `Not started: ${words(r.body)}`, !r.ok);
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
      xe.read ? el('pre', { 'aria-label': `The read to run on ${srv}` }, String(xe.read)) : '',
      ((xe.drop as string[]) ?? []).length ? el('pre', { 'aria-label': `The DROP lines for ${srv}'s DBA` }, ((xe.drop as string[]) ?? []).join('\n')) : '');
    const ticks = (s.ticks ?? {}) as Record<string, { done: boolean; at: string; by: string }>;
    const list = el('ul', { class: 'admin-checklist' }, ...d.steps.map(step => {
      const t = ticks[step];
      const box = el('input', { type: 'checkbox', 'aria-label': `${name}: ${STEP_WORDS[step] ?? step}` });
      box.checked = !!t?.done;
      box.addEventListener('change', async () => {
        box.disabled = true;
        const r = await post({ op: 'tick', repo, name, step, done: box.checked });
        if (!r.ok) { box.checked = !box.checked; box.disabled = false; say(`Not kept: ${words(r.body)}`, true); return; }
        await draw();
        say(`${name}: kept.`);
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
  return root;
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
  return j.ended ? `import ${String(j.outcome)} ${fmtTime(j.ended)}${rows ? `: ${rows}` : ''}` : `importing since ${fmtTime(j.started)}${rows ? `: ${rows} so far` : ''}`;
}
