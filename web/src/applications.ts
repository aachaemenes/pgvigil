// Admin > Applications (task 310, migration 0136): which application each server and database serves, and who owns
// it. An application is set on a whole server (its databases inherit it) or on one database (its own beats the
// server's); every server it is on carries the tag application:<name>. The page: the list; one application opened
// below it (its fields with each one's source, Edit, Rename, Remove, its contacts on a click, its servers and
// databases - own or inherited, absent since, renamed to - and Assign); the databases with no application, ticked and
// assigned or marked 'not an application' in one request; the marks; the changes. Data from /api/applications,
// /api/applications/{id}, /{id}/contacts and /unassigned; the writes POST /api/admin/applications, /contacts and
// /assign (internal/web/q_applications.go), each refused in the store's own words. Contacts are personal data: read
// only when asked, so an export or a mail of this page carries them only while they are shown. The route and the
// tab's entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { Col, el, fmtTime, grid, gridModel, offControl } from './ui';

// the page's one sentence where this server cannot write ('Read only: ...'): every control that is off for it is
// described by that sentence (admin_instances.ts's way: a button aria-disabled with its reason, a field disabled)
const READ_ONLY_ID = 'admin-applications-read-only';
const roRef = el('span', { id: READ_ONLY_ID });
function offRead(c: Element, why: string): void {
  if (c instanceof HTMLButtonElement) { offControl(c, why, roRef); return; }
  (c as HTMLInputElement).disabled = true;
  (c as HTMLElement).title = why;
  c.setAttribute('aria-describedby', READ_ONLY_ID);
}

interface ListData { can_edit: boolean; why_not: string; applications: Table | null; audit: Table | null; file_tags?: Table | null }
interface OneData { can_edit: boolean; why_not: string; application: Table | null; databases: Table | null }
interface UnData { can_edit: boolean; why_not: string; unassigned: Table | null; marked: Table | null }
interface Source { source?: string; set_at?: string; set_by?: string }

const TIERS: [string, string][] = [['', '(none)'], ['1', '1 (most critical)'], ['2', '2'], ['3', '3'], ['4', '4 (least critical)']];
const ENVS: [string, string][] = [['production', 'production'], ['staging', 'staging'], ['test', 'test'], ['development', 'development'], ['DR', 'DR']];
const ROLES: [string, string][] = [['business owner', 'business owner'], ['technical owner', 'technical owner'], ['support', 'support'], ['escalation', 'escalation']];
const KINDS: [string, string][] = [['team', 'a team (its group address)'], ['person', 'a person']];

async function send(path: string, data: Record<string, unknown>): Promise<{ ok: boolean; body: Record<string, unknown> }> {
  const res = await fetch('/api/' + path, {
    method: 'POST', credentials: 'same-origin',
    headers: { Accept: 'application/json', 'Content-Type': 'application/json', 'X-Pgvigil': '1' },
    body: JSON.stringify(data),
  });
  let body: Record<string, unknown> = {};
  try { body = await res.json(); } catch { /* an empty answer */ }
  return { ok: res.ok, body };
}
const why = (b: Record<string, unknown>) => String(b.detail ?? b.error ?? b.outcome ?? 'refused');

function field(label: string, control: HTMLElement): HTMLElement {
  return el('label', { class: 'admin-field', style: 'display:inline-flex;flex-direction:column;margin:.25rem .6rem .25rem 0;font-size:.9em' }, label, control);
}
function tick(label: string, control: HTMLInputElement): HTMLElement {
  return el('label', { class: 'admin-field', style: 'display:inline-flex;align-items:center;gap:.3rem;margin:.25rem .6rem .25rem 0;font-size:.9em' }, control, label);
}
const input = (name: string, attrs: Record<string, string> = {}) => el('input', { name, type: 'text', autocomplete: 'off', ...attrs });
const checkbox = (name: string) => el('input', { name, type: 'checkbox' }) as HTMLInputElement;
function select(name: string, opts: [string, string][], value = ''): HTMLSelectElement {
  const s = el('select', { name });
  for (const [v, t] of opts) { const o = el('option', { value: v }, t); if (v === value) o.selected = true; s.append(o); }
  return s;
}
const str = (v: unknown) => v == null ? '' : String(v);
const tierOf = (v: string) => v === '' ? null : Number(v);
const where = (r: Row) => r.database_name == null ? `the whole server ${str(r.instance)}` : `${str(r.database_name)} on ${str(r.instance)}`;
const pickKey = (r: Row) => `${str(r.instance_id)}\t${str(r.database_name)}`;

export async function adminApplicationsView(_ctx: Ctx): Promise<HTMLElement> {
  const root = el('section', { class: 'applications' });
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const say = (text: string, bad = false) => { status.textContent = text; status.className = bad ? 'meta error' : 'meta'; };
  let whyNot = '';          // why this server takes no write ('' = it does)
  let openId = 0;           // the application opened below the list
  let contactsOf = 0;       // the application whose contacts were asked for (read on a click only: personal data)
  let seq = 0;              // the latest draw: an older one that ends later is dropped
  let busy = false;         // a write in flight: no second write, no Open, until its redraw (review C, MINOR 2)
  const picked = new Set<string>();   // the Unassigned rows ticked (instance_id TAB database)

  // a grid draws its rows again at each sort, filter and 'Show more' through the columns' formats: each actions cell
  // locks its own controls, so a redraw never brings a write control back on a read-only server
  function lock(cell: HTMLElement): HTMLElement {
    if (whyNot) for (const c of cell.querySelectorAll('button, input')) offRead(c, whyNot);
    return cell;
  }
  function readOnly(): void {
    if (!whyNot) return;
    for (const c of root.querySelectorAll('form button, form input, form select, form textarea, .actions button, .actions input')) offRead(c, whyNot);
  }

  async function draw(): Promise<void> {
    const mine = ++seq;
    const [d, u] = await Promise.all([get<ListData>('applications'), get<UnData>('applications/unassigned')]);
    if (mine !== seq) return;
    whyNot = d.can_edit ? '' : str(d.why_not);
    const apps = rowsOf(d.applications), un = rowsOf(u.unassigned), marked = rowsOf(u.marked), audit = rowsOf(d.audit), fileTags = rowsOf(d.file_tags);
    const onList = new Set(un.map(pickKey));
    for (const k of [...picked]) if (!onList.has(k)) picked.delete(k);
    if (openId && !apps.some(a => Number(a.app_id) === openId)) openId = 0;
    const one = openId ? await oneSection(openId) : null;
    if (mine !== seq) return;
    root.replaceChildren(
      el('h2', {}, 'Applications'),
      el('p', { class: 'meta' }, `${apps.length} application(s); ${un.length} database(s) with none. `,
        'An application is set on a whole server (its databases inherit it) or on one database (its own beats the server\'s); every server it is on carries the tag application:<name>, ',
        'which thresholds, acknowledgements and alert rules may be scoped by. Until the viewer / operator / admin roles exist, any signed-in user may change applications.'),
      whyNot ? el('p', { class: 'meta', role: 'note', id: READ_ONLY_ID }, `Read only: ${whyNot}.`) : '',
      status,
      // decision E5: an application: tag from pgvigil.yaml (or an older override) is not taken - named, never dropped silently
      fileTags.length ? el('p', { class: 'meta', role: 'note', 'data-part': 'file-tags' },
        'Not taken (an application is set on this page): ', fileTags.map(r => `${str(r.instance)} has ${str(r.tag)} from ${str(r.source)}`).join('; '), '.') : '',
      addForm(),
      el('h3', {}, 'Applications'),
      grid(apps, listCols, 'No application yet: add one above.'),
      one ?? '',
      el('h3', {}, `Databases with no application (${un.length})`),
      el('p', { class: 'meta' }, 'Every present database of a monitored server with no application of its own or of its server\'s; system databases (template0, template1, rdsadmin, master, model, msdb, tempdb) are left out. Tick rows, then assign them or mark them not an application.'),
      unGrid(un),
      selectedForm(apps),
      el('h3', {}, `Marked not an application (${marked.length})`),
      grid(marked, markedCols, 'No database is marked.'),
      el('h3', {}, 'Changes (the last 200)'),
      grid(audit, [{ key: 'at', fmt: fmtTime }, { key: 'ui_user', label: 'by' }, { key: 'client' }, { key: 'op' }, { key: 'target' },
        { key: 'outcome' }, { key: 'detail', wide: true }], 'No change yet.'),
    );
    readOnly();
  }

  // after a redraw the control that had the focus is gone: the opened application's heading takes it, else the page's
  const refocus = () => (root.querySelector<HTMLElement>('section.app-one h3') ?? root.querySelector<HTMLElement>('h2'))?.focus();
  // a read after Open, Close, Show or Hide that fails says so (a removed application, an expired session)
  const redraw = () => draw().then(refocus, (e: unknown) => say(`The page could not be read again: ${(e as Error).message}`, true));

  async function act(path: string, data: Record<string, unknown>, done: (b: Record<string, unknown>) => string): Promise<boolean> {
    if (busy) { say('Another change is still being written: try again when it is done.', true); return false; }
    busy = true;
    say('Working…');
    // one request at a time: every button off until the redraw (a grid redrawn meanwhile draws new ones: busy holds them)
    const off = [...root.querySelectorAll('button')].filter(b => !(b as HTMLButtonElement).disabled) as HTMLButtonElement[];
    for (const b of off) b.disabled = true;
    let r: { ok: boolean; body: Record<string, unknown> };
    try { r = await send(path, data); } catch (e) {
      busy = false; for (const b of off) b.disabled = false; say(`Not done: ${(e as Error).message}`, true); return false;
    }
    if (!r.ok) { busy = false; for (const b of off) b.disabled = false; say(`Not done: ${why(r.body)}`, true); return false; }
    // done: its words and the state it sets come before the redraw, so the redraw shows what they set (review C, MINOR 1)
    const msg = done(r.body);
    try { await draw(); } catch (e) {
      busy = false; say(`${msg} The page could not be read again: ${(e as Error).message}`, true); return true;
    }
    busy = false;
    say(msg);
    refocus();
    return true;
  }

  // a remove asks twice: the first click arms the row's own confirm (no browser dialog); a refusal brings the first back
  function removeButton(label: string, what: string, onConfirm: () => Promise<boolean>): HTMLElement {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `Remove ${label}` }, 'Remove');
    b.addEventListener('click', () => {
      const yes = el('button', { type: 'button', class: 'link danger', 'aria-label': `Confirm: remove ${label}` }, `Remove ${what}: confirm`);
      const no = el('button', { type: 'button', class: 'link', 'aria-label': `Keep ${label}` }, 'Keep');
      const box = el('span', {}, yes, ' ', no);
      yes.addEventListener('click', () => { void onConfirm().then(ok => { if (!ok && box.isConnected) { box.replaceWith(b); b.focus(); } }); });
      no.addEventListener('click', () => { box.replaceWith(b); b.focus(); });
      b.replaceWith(box);
      yes.focus();
    });
    return b;
  }

  const open = (id: number) => {
    if (busy) return;
    if (id !== openId) contactsOf = 0;
    openId = id; say('');   // the status words of another application never stay under this one (review C, M3)
    void redraw();
  };

  const listCols: Col[] = [
    { key: 'name', fmt: (v, r) => {
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `Open ${str(v)}` }, str(v));
      b.addEventListener('click', () => open(Number(r.app_id)));
      return b;
    } },
    { key: 'tier', num: true }, { key: 'environment' }, { key: 'owner_team', label: 'owner team' },
    { key: 'servers', num: true }, { key: 'databases', num: true },
  ];

  // add: the fields an application starts with (its name is a tag value: no comma, at most 100 bytes)
  function addForm(): HTMLElement {
    const f = el('form', { class: 'admin-form', 'aria-label': 'Add an application' });
    const name = input('name', { required: '', maxlength: '100' }), tier = select('tier', TIERS), env = select('environment', [['', '(none)'], ...ENVS]);
    const desc = el('textarea', { name: 'description', rows: '2', cols: '40', maxlength: '2000' }), cmdb = input('cmdb_url', { placeholder: 'https://...', size: '30' });
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      const n = name.value.trim();
      // only the fields given: each one gets its source ('entered'), an empty one none
      const data: Record<string, unknown> = { op: 'add', name: n };
      if (tier.value) data.tier = tierOf(tier.value);
      if (env.value) data.environment = env.value;
      if (desc.value.trim()) data.description = desc.value.trim();
      if (cmdb.value.trim()) data.cmdb_url = cmdb.value.trim();
      await act('admin/applications', data, b => { openId = Number(b.app_id) || openId; contactsOf = 0; return `Added ${n}.`; });
    });
    f.append(el('fieldset', {}, el('legend', {}, 'Add an application'),
      el('div', {}, field('Name', name), field('Tier', tier), field('Environment (its default)', env), field('Description', desc), field('CMDB link', cmdb)),
      el('div', {}, el('button', { type: 'submit' }, 'Add'))));
    return f;
  }

  // one application: its fields and their sources, Edit, Rename, Remove, contacts, servers and databases, Assign
  async function oneSection(id: number): Promise<HTMLElement> {
    const d = await get<OneData>(`applications/${id}`);
    const a = rowsOf(d.application)[0] ?? {};
    const dbs = rowsOf(d.databases);
    const name = str(a.name), version = Number(a.version);
    const sources = (a.sources ?? {}) as Record<string, Source>;
    const src = (f: string) => { const s = sources[f]; return s ? `${str(s.source)} by ${str(s.set_by) || 'unknown'}, ${fmtTime(s.set_at)}` : ''; };
    const fields = [
      { field: 'name', value: name, source: src('name') },
      { field: 'tier', value: str(a.tier), source: src('tier') },
      { field: 'environment (default)', value: str(a.environment), source: src('environment') },
      { field: 'description', value: str(a.description), source: src('description') },
      { field: 'CMDB link', value: str(a.cmdb_url), source: src('cmdb_url') },
      { field: 'created', value: `${fmtTime(a.created_at)}${a.created_by ? ` by ${str(a.created_by)}` : ''}`, source: '' },
    ];
    const sec = el('section', { class: 'app-one', 'aria-label': `Application ${name}` });
    const close = el('button', { type: 'button', class: 'link', 'aria-label': `Close ${name}` }, 'Close');
    close.addEventListener('click', () => { openId = 0; contactsOf = 0; say(''); void redraw(); });
    const dbGrid = grid(dbs.map(r => ({ ...r, database: r.database_name == null ? '(the whole server)' : str(r.database_name), assigned: r.own ? 'own' : 'inherited' })), dbCols(id, name), 'Not assigned to any server or database yet: assign it below, or tick its databases under Databases with no application.');
    dbGrid.querySelector('table.grid')?.setAttribute('data-part', 'databases');
    sec.append(
      el('div', { class: 'app-one-head' }, el('h3', { tabindex: '-1', style: 'display:inline-block;margin-right:.6rem' }, name), close),
      grid(fields, [{ key: 'field' }, { key: 'value', wide: true, fmt: (v, r) => r.field === 'CMDB link' && v ? el('a', { href: str(v), rel: 'noopener noreferrer', target: '_blank' }, str(v)) : str(v) }, { key: 'source', label: 'set by' }], ''),
      editForm(a, id, name, version),
      renameForm(id, name, version),
      removeForm(id, name, version, dbs.filter(r => r.own).length),
      el('h4', {}, 'Contacts'),
      await contactsPart(id, name),
      el('h4', {}, 'Servers and databases'),
      el('p', { class: 'meta' }, 'Own: assigned here. Inherited: a database of a server this application is set on, with no application of its own. A database dropped on its server keeps its assignment, shown absent since its last read; one renamed on its server (the same id) is offered under its new name.'),
      dbGrid,
      assignForm(id, name),
    );
    return sec;
  }

  // Edit sends only the fields changed, so an imported field left alone keeps its source
  function editForm(a: Row, id: number, name: string, version: number): HTMLElement {
    const f = el('form', { class: 'admin-form', 'aria-label': `Edit ${name}` });
    const tier = select('tier', TIERS, str(a.tier)), env = select('environment', [['', '(none)'], ...ENVS], str(a.environment));
    const desc = el('textarea', { name: 'description', rows: '2', cols: '40', maxlength: '2000' }); desc.value = str(a.description);
    const cmdb = input('cmdb_url', { value: str(a.cmdb_url), size: '30', placeholder: 'https://...' });
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      const data: Record<string, unknown> = { op: 'edit', app_id: id, version };
      if (tier.value !== str(a.tier)) data.tier = tierOf(tier.value);
      if (env.value !== str(a.environment)) data.environment = env.value;
      const norm = (t: string) => t.replace(/\r\n?/g, '\n').trim();   // a textarea reads CR LF as LF (review C, MINOR 11)
      if (norm(desc.value) !== norm(str(a.description))) data.description = desc.value.trim();
      if (cmdb.value.trim() !== str(a.cmdb_url)) data.cmdb_url = cmdb.value.trim();
      if (Object.keys(data).length === 3) { say('Nothing changed.'); return; }
      await act('admin/applications', data, () => `Saved ${name}.`);
    });
    f.append(el('fieldset', {}, el('legend', {}, `Edit ${name}`),
      el('div', {}, field('Tier', tier), field('Environment (its default)', env), field('Description', desc), field('CMDB link', cmdb)),
      el('div', {}, el('button', { type: 'submit', 'aria-label': `Save ${name}` }, 'Save'))));
    return f;
  }

  function renameForm(id: number, name: string, version: number): HTMLElement {
    const f = el('form', { class: 'admin-form', 'aria-label': `Rename ${name}` });
    const nn = input('new_name', { required: '', maxlength: '100', value: name }), retag = checkbox('retag');
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      const n = nn.value.trim();
      await act('admin/applications', { op: 'rename', app_id: id, version, name: n, retag: retag.checked }, () => `Renamed ${name} to ${n}: its servers carry application:${n} from the next read.`);
    });
    f.append(el('fieldset', {}, el('legend', {}, `Rename ${name}`),
      el('div', {}, field('New name', nn), tick('also rewrite the thresholds, acknowledgements and alert rules scoped by its tag', retag)),
      el('div', {}, el('button', { type: 'submit', 'aria-label': `Rename ${name}` }, 'Rename'))));
    return f;
  }

  function removeForm(id: number, name: string, version: number, own: number): HTMLElement {
    const f = el('form', { class: 'admin-form', 'aria-label': `Remove ${name}` });
    const withA = checkbox('with_assignments'), retag = checkbox('retag');
    f.addEventListener('submit', ev => ev.preventDefault());
    const rm = removeButton(name, name, () => act('admin/applications', { op: 'remove', app_id: id, version, with_assignments: withA.checked, retag: retag.checked },
      () => { openId = 0; contactsOf = 0; return `Removed ${name}.`; }));
    f.append(el('fieldset', {}, el('legend', {}, `Remove ${name}`),
      el('div', {}, tick(`with its assignments (${own})`, withA), tick('and end the thresholds, acknowledgements and alert rules scoped by its tag', retag)),
      el('div', {}, rm)));
    return f;
  }

  // contacts: read only when asked; the add / edit form beside them
  async function contactsPart(id: number, name: string): Promise<HTMLElement> {
    const box = el('div', { class: 'app-contacts' });
    if (contactsOf !== id) {
      const show = el('button', { type: 'button', 'aria-label': `Show contacts of ${name}` }, 'Show contacts');
      show.addEventListener('click', () => { contactsOf = id; void redraw(); });
      box.append(el('p', { class: 'meta' }, 'Contacts are personal data: they are read only when you ask, so an export or a mail of this page carries them only while they are shown. '), show);
      return box;
    }
    let rows: Row[], routes: Row[], channels: Row[];
    try {
      const d = await get<{ contacts: Table | null; routes: Table | null; channels: Table | null }>(`applications/${id}/contacts`);
      rows = rowsOf(d.contacts); routes = rowsOf(d.routes); channels = rowsOf(d.channels);
    } catch (e) {
      box.append(el('p', { class: 'meta' }, (e as Error).message));
      return box;
    }
    const hide = el('button', { type: 'button', 'aria-label': `Hide contacts of ${name}` }, 'Hide contacts');
    hide.addEventListener('click', () => { contactsOf = 0; say(''); void redraw(); });
    const form = contactForm(id, name);
    box.append(grid(rows, [{ key: 'role' }, { key: 'kind' }, { key: 'name' }, { key: 'email', label: 'e-mail' }, { key: 'phone' },
      { key: 'cmdb_url', label: 'CMDB link' },
      { key: 'actions', fmt: (_v, r) => {
        const cn = str(r.name);
        const edit = el('button', { type: 'button', class: 'link', 'aria-label': `Edit contact ${cn} of ${name}` }, 'Edit');
        edit.addEventListener('click', () => form.fill?.(r));
        const rm = removeButton(`contact ${cn} of ${name}`, cn, () => act('admin/applications/contacts', { op: 'remove', app_id: id, contact_id: Number(r.contact_id) }, () => `Contact ${str(r.contact_id)} removed.`));
        return lock(el('span', { class: 'actions' }, edit, ' ', rm));
      } }], 'No contact yet.'), form, routesPart(name, rows, routes, channels), hide);
    return box;
  }

  // owner-routed alerts: a contact's alerts of this application's servers through a configured smtp channel, its
  // repeat, quiet hours and cap the channel's (counted as the route's own); a route turned off or removed closes its
  // open alerts with no message
  function routesPart(name: string, contacts: Row[], routes: Row[], channels: Row[]): HTMLElement {
    const part = el('div', { class: 'app-routes' });
    const label = (r: Row) => `${str(r.contact)} via ${str(r.channel_name)}`;
    // the status words name a contact by its id only: they stay on the page (and in its export) after Hide (review C, M3)
    const said = (r: Row) => `contact ${str(r.contact_id)} via ${str(r.channel_name)}`;
    part.append(el('h5', {}, 'Alerts to contacts'),
      el('p', { class: 'meta' }, 'A route mails a contact the alerts of this application\'s servers through a channel of the configuration (its relay); the channel\'s repeat, quiet hours and hourly cap hold the route as its own. The channel\'s own recipients and scope are unchanged; repository-wide alerts (the collector, purge) never go to a route. A person on two contact rows gets two copies.'),
      grid(routes, [{ key: 'contact' }, { key: 'channel_name', label: 'channel' },
        { key: 'min_severity', label: 'from', fmt: v => v ? str(v) : 'the channel\'s severity' },
        { key: 'enabled', label: 'state', fmt: v => v ? 'on' : 'off' },
        { key: 'set_by', label: 'set by', fmt: (v, r) => `${str(v) || 'unknown'}, ${fmtTime(r.set_at)}` },
        { key: 'actions', fmt: (_v, r) => {
          const on = !!r.enabled, l = label(r);
          const t = el('button', { type: 'button', class: 'link', 'aria-label': `${on ? 'Turn off' : 'Turn on'} the route of ${l}` }, on ? 'Turn off' : 'Turn on');
          t.addEventListener('click', () => { void act('admin/applications/routes', { op: 'set', route_id: Number(r.route_id), enabled: !on }, () => `The route of ${said(r)} is ${on ? 'off: its open alerts close with no message' : 'on'}.`); });
          const rm = removeButton(`the route of ${l}`, `the route of ${l}`, () => act('admin/applications/routes', { op: 'remove', route_id: Number(r.route_id) }, () => `The route of ${said(r)} is removed.`));
          return lock(el('span', { class: 'actions' }, t, ' ', rm));
        } }], 'No route: no contact of this application receives its alerts yet.'));
    const f = el('form', { class: 'admin-form', 'aria-label': `Route alerts of ${name}` });
    const who = select('contact_id', contacts.filter(c => str(c.email)).map(c => [str(c.contact_id), str(c.name)] as [string, string]));
    const via = select('channel', channels.map(c => [str(c.name), str(c.name)] as [string, string]));
    const from = select('min_severity', [['', 'the channel\'s severity'], ['info', 'info'], ['warning', 'warning'], ['critical', 'critical']]);
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      if (!who.value) { say('A route mails a contact: add a contact with an e-mail address first.', true); return; }
      if (!via.value) { say('No smtp channel is configured (the alerts: list of the configuration): a route needs one to mail through.', true); return; }
      // the severity always sent (empty: the channel's own) and the route on: an existing route takes both (review C, M1)
      const data: Record<string, unknown> = { op: 'set', contact_id: Number(who.value), channel: via.value, min_severity: from.value, enabled: true };
      await act('admin/applications/routes', data, () => `The route of contact ${who.value} via ${via.value} is on, from ${from.value || 'the channel\'s severity'}: the next alert pass mails it.`);
    });
    f.append(el('fieldset', {}, el('legend', {}, `Route alerts of ${name}`),
      el('div', {}, field('Contact', who), field('Channel', via), field('From severity', from)),
      channels.length ? '' : el('p', { class: 'meta' }, 'No smtp channel is configured yet (or the alert sender has not run since): a route needs one.'),
      el('div', {}, el('button', { type: 'submit', 'aria-label': `Add the route for ${name}` }, 'Add the route'))));
    part.append(f);
    return part;
  }

  function contactForm(id: number, name: string): HTMLFormElement & { fill?: (r: Row) => void } {
    const addLabel = `Add a contact to ${name}`;
    const f = el('form', { class: 'admin-form', 'aria-label': addLabel }) as HTMLFormElement & { fill?: (r: Row) => void };
    const role = select('role', ROLES), kind = select('kind', KINDS), cname = input('name', { required: '', maxlength: '200' });
    const email = input('email', { type: 'email', maxlength: '254', size: '28' }), phone = input('phone', { maxlength: '40', placeholder: 'a person only' }), cmdb = input('cmdb_url', { placeholder: 'https://...' });
    const legend = el('legend', {}, addLabel), submit = el('button', { type: 'submit' }, 'Add the contact'), cancel = el('button', { type: 'button', hidden: '' }, 'Cancel the edit');
    let editing = 0, was: Row = {};
    const reset = () => { editing = 0; was = {}; f.reset(); legend.textContent = addLabel; f.setAttribute('aria-label', addLabel); submit.textContent = 'Add the contact'; cancel.hidden = true; };
    cancel.addEventListener('click', reset);
    f.fill = (r: Row) => {
      editing = Number(r.contact_id); was = r; const lbl = `Edit contact ${str(r.name)} of ${name}`;
      legend.textContent = lbl; f.setAttribute('aria-label', lbl); submit.textContent = 'Save the contact'; cancel.hidden = false;
      role.value = str(r.role); kind.value = str(r.kind); cname.value = str(r.name); email.value = str(r.email); phone.value = str(r.phone); cmdb.value = str(r.cmdb_url);
      cname.focus();
    };
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      const now: Record<string, string> = { role: role.value, kind: kind.value, name: cname.value.trim(), email: email.value.trim(),
        phone: phone.value.trim(), cmdb_url: cmdb.value.trim() };
      const data: Record<string, unknown> = { op: editing ? 'edit' : 'add', app_id: id };
      // an edit sends only the fields changed: its audit row and each field's source name those alone (review C, M2)
      for (const [k, v] of Object.entries(now)) if (!editing || v !== str(was[k])) data[k] = v;
      if (editing) {
        if (Object.keys(data).length === 2) { say('Nothing changed.'); return; }
        data.contact_id = editing;
      }
      const e = editing;
      if (await act('admin/applications/contacts', data, b => e ? `Contact ${e} saved.` : `Contact ${str(b.contact_id) || ''} added.`.replace('  ', ' '))) reset();
    });
    f.append(el('fieldset', {}, legend,
      el('div', {}, field('Role', role), field('Kind', kind), field('Name', cname), field('E-mail', email), field('Phone', phone), field('CMDB link', cmdb)),
      el('div', {}, submit, ' ', cancel)));
    return f;
  }

  function dbCols(id: number, name: string): Col[] {
    return [
      { key: 'instance' }, { key: 'engine' }, { key: 'database' }, { key: 'assigned' }, { key: 'environment' },
      { key: 'absent_since', label: 'absent since', fmt: fmtTime },
      { key: 'renamed_to', label: 'renamed to', fmt: (v, r) => {
        if (!v) return '';
        const b = el('button', { type: 'button', class: 'link', 'aria-label': `Assign ${str(v)} to ${name} instead` }, 'Assign instead');
        b.addEventListener('click', async () => {
          const target = { instance_id: Number(r.instance_id) };
          const ok = await act('admin/applications/assign', { op: 'assign', app_id: id, environment: str(r.environment), targets: [{ ...target, database: str(v) }] }, () => `${str(v)} assigned to ${name}.`);
          if (ok && !await act('admin/applications/assign', { op: 'unassign', app_id: id, targets: [{ ...target, database: str(r.database_name) }] }, () => `${str(v)} assigned to ${name} instead of ${str(r.database_name)}.`)) {
            say(`${str(v)} is assigned to ${name}, and ${str(r.database_name)} is still assigned too: ${(status.textContent ?? '').replace(/^Not done: /, '')}`, true);
          }
        });
        return el('span', {}, str(v), ' ', lock(el('span', { class: 'actions' }, b)));
      } },
      { key: 'set_by', label: 'set by', fmt: (v, r) => r.own ? `${str(r.source)} by ${str(v) || 'unknown'}, ${fmtTime(r.set_at)}` : '' },
      { key: 'actions', fmt: (_v, r) => {
        if (!r.own) return '';
        const b = el('button', { type: 'button', class: 'link', 'aria-label': `Unassign ${where(r)} from ${name}` }, 'Unassign');
        b.addEventListener('click', () => { void act('admin/applications/assign', { op: 'unassign', app_id: id, targets: [{ instance_id: Number(r.instance_id), database: r.database_name ?? null }] }, () => `${where(r)} unassigned from ${name}.`); });
        return lock(el('span', { class: 'actions' }, b));
      } },
    ];
  }

  // Assign: a whole server, or one of its databases by name (a database it lists now)
  function assignForm(id: number, name: string): HTMLElement {
    const f = el('form', { class: 'admin-form', 'aria-label': `Assign to ${name}` });
    const inst = select('instance_id', [['', '(loading the servers)']]), db = input('database', { placeholder: 'empty: the whole server', size: '24' }), env = select('environment', [['', '(the application\'s)'], ...ENVS]);
    void get('instances').then(t => {
      inst.replaceChildren(...rowsOf(t).sort((x, y) => str(x.name).localeCompare(str(y.name))).map(r => el('option', { value: str(r.instance_id) }, `${str(r.name)} (${r.engine === 'sqlserver' ? 'SQL Server' : 'PostgreSQL'})`)));
    }, (e: unknown) => { inst.replaceChildren(el('option', { value: '' }, `the servers could not be read: ${(e as Error).message}`)); });
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      if (!inst.value) { say('Choose a server first.', true); return; }
      const d = db.value.trim(), what = d ? `${d} on ${inst.selectedOptions[0]?.textContent ?? ''}` : `the whole server ${inst.selectedOptions[0]?.textContent ?? ''}`;
      await act('admin/applications/assign', { op: 'assign', app_id: id, environment: env.value, targets: [{ instance_id: Number(inst.value), database: d || null }] }, () => `${what} assigned to ${name}.`);
    });
    f.append(el('fieldset', {}, el('legend', {}, `Assign to ${name}`),
      el('div', {}, field('Server', inst), field('Database', db), field('Environment', env)),
      el('div', {}, el('button', { type: 'submit', 'aria-label': `Assign to ${name}` }, 'Assign'))));
    return f;
  }

  const unCols: Col[] = [
    { key: 'pick', label: 'tick', fmt: (_v, r) => {
      const k = pickKey(r);
      const c = el('input', { type: 'checkbox', 'data-pick': '1', 'aria-label': `Select ${str(r.database_name)} on ${str(r.instance)}` }) as HTMLInputElement;
      c.checked = picked.has(k);
      c.addEventListener('change', () => { if (c.checked) picked.add(k); else picked.delete(k); count(); });
      return lock(el('span', { class: 'actions' }, c));
    } },
    { key: 'instance', label: 'server' }, { key: 'engine' }, { key: 'database_name', label: 'database' },
  ];
  const unGrid = (un: Row[]) => { const g = grid(un, unCols, 'Every database has an application or is marked not one.'); g.querySelector('table.grid')?.setAttribute('data-part', 'unassigned'); return g; };
  let countEl: HTMLElement | null = null;
  const count = () => { if (countEl) countEl.textContent = `${picked.size} ticked`; };
  const targets = () => [...picked].map(k => { const [i, db] = k.split('\t'); return { instance_id: Number(i), database: db }; });

  // the ticked rows: assigned to one application, or marked not an application - each one request
  function selectedForm(apps: Row[]): HTMLElement {
    const f = el('form', { class: 'admin-form', 'aria-label': 'Assign the selected databases' });
    const app = select('app_id', apps.map(a => [str(a.app_id), str(a.name)] as [string, string])), env = select('environment', [['', '(the application\'s)'], ...ENVS]);
    const all = el('button', { type: 'button', 'aria-label': 'Tick every row shown' }, 'Tick every row shown');
    all.addEventListener('click', () => {
      // every row the grid holds under its filter, drawn or past its first page (review C, MINOR 6)
      const t = root.querySelector<HTMLTableElement>('table.grid[data-part=unassigned]'), m = t ? gridModel(t) : undefined;
      for (const r of m ? m.rows() : []) picked.add(pickKey(r));
      for (const c of root.querySelectorAll<HTMLInputElement>('input[data-pick]')) c.checked = true;
      count();
    });
    const mark = el('button', { type: 'button', 'aria-label': 'Mark the selected not an application' }, 'Mark the selected not an application');
    const need = () => {
      if (!picked.size) { say('Tick at least one database first.', true); return false; }
      if (picked.size > 500) { say(`${picked.size} ticked: at most 500 in one request.`, true); return false; }
      // the server takes a body of 64 KB: long database names may pass it under 500 (review C, MINOR 7)
      if (JSON.stringify({ op: 'assign', app_id: 0, environment: 'development', targets: targets() }).length > 60000) { say(`${picked.size} ticked with long names: too many for one request (64 KB); assign them in two.`, true); return false; }
      return true;
    };
    mark.addEventListener('click', () => {
      if (!need()) return;
      const n = picked.size;
      void act('admin/applications/assign', { op: 'mark', targets: targets() }, () => { picked.clear(); return `${n} database(s) marked not an application.`; });
    });
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      if (!need()) return;
      if (!app.value) { say('Add an application first.', true); return; }
      const n = picked.size, an = app.selectedOptions[0]?.textContent ?? '';
      await act('admin/applications/assign', { op: 'assign', app_id: Number(app.value), environment: env.value, targets: targets() }, () => { picked.clear(); return `${n} database(s) assigned to ${an}.`; });
    });
    countEl = el('span', { class: 'meta', 'aria-live': 'polite' }); count();
    f.append(el('fieldset', {}, el('legend', {}, 'The ticked databases'),
      el('div', {}, field('Application', app), field('Environment', env)),
      el('div', {}, el('button', { type: 'submit', 'aria-label': 'Assign the selected' }, 'Assign the selected'), ' ', mark, ' ', all, ' ', countEl)));
    return f;
  }

  const markedCols: Col[] = [
    { key: 'instance', label: 'server' }, { key: 'engine' }, { key: 'database_name', label: 'database' },
    { key: 'set_by', label: 'marked by' }, { key: 'set_at', label: 'marked', fmt: fmtTime },
    { key: 'actions', fmt: (_v, r) => {
      const b = el('button', { type: 'button', class: 'link', 'aria-label': `Unmark ${str(r.database_name)} on ${str(r.instance)}` }, 'Unmark');
      b.addEventListener('click', () => { void act('admin/applications/assign', { op: 'unmark', targets: [{ instance_id: Number(r.instance_id), database: str(r.database_name) }] }, () => `${str(r.database_name)} is back among the databases with no application.`); });
      return lock(el('span', { class: 'actions' }, b));
    } },
  ];

  try { await draw(); } catch (e) { root.replaceChildren(el('h2', {}, 'Applications'), el('p', { class: 'error' }, (e as Error).message)); }
  return root;
}
