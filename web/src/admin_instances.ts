// Admin > Instances (task 204; task 103 part 1): add, edit, disable, remove and test an instance; the instances of
// pgvigil.yaml shown read-only ('from the file'); the sync sources (a SQL Server Central Management Server, a DBA Dash
// repository, a server list, a pg_service.conf, a CSV) and the servers they propose, each approved or ignored by a
// click; the audit of every change. Data from /api/admin/instances; the writes POST /api/admin/instances, /sources and
// /proposals (internal/web/q_instances_admin.go). A password goes to the server once and is never shown again: the
// server writes it to a credential file of its own and the repository keeps only the file's name. The collector
// takes a change within 15 s, without a restart. The route and the tab's entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, el, fmtTime, grid } from './ui';

interface AdminData {
  file: Table | null; page: Table | null; sources: Table | null; proposals: Table | null; audit: Table | null;
  generation: number; secret_dir: string; dbadash: string[]; writable: boolean; why_not: string;
}

// send POSTs and answers the server's outcome: a refusal (409) carries its reason, which the status line shows
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

// a labelled form field: the label wraps its control (one name for a screen reader, one click target)
function field(label: string, control: HTMLElement): HTMLElement {
  return el('label', { class: 'admin-field', style: 'display:inline-flex;flex-direction:column;margin:.25rem .6rem .25rem 0;font-size:.9em' }, label, control);
}
const input = (name: string, attrs: Record<string, string> = {}) => el('input', { name, type: 'text', autocomplete: 'off', ...attrs });
function select(name: string, opts: [string, string][], value = ''): HTMLSelectElement {
  const s = el('select', { name });
  for (const [v, t] of opts) { const o = el('option', { value: v }, t); if (v === value) o.selected = true; s.append(o); }
  return s;
}
const authOpts = (engine: string): [string, string][] => engine === 'sqlserver'
  ? [['sql', 'SQL login'], ['windows', 'Windows account (the service\'s own)'], ['entra', 'Entra service principal']]
  : [['password', 'login and password'], ['pgpass', 'the service account\'s .pgpass']];
const platOpts = (engine: string): [string, string][] => engine === 'sqlserver'
  ? [['auto', 'auto'], ['onprem', 'on premises'], ['rds', 'Amazon RDS'], ['azuresqldb', 'Azure SQL Database'], ['azuresqlmi', 'Azure SQL Managed Instance']]
  : [['auto', 'auto'], ['onprem', 'on premises'], ['rds', 'Amazon RDS'], ['aurora', 'Aurora'], ['azure', 'Azure'], ['cloudsql', 'Cloud SQL'], ['alloydb', 'AlloyDB']];

export async function adminInstancesView(_ctx: Ctx): Promise<HTMLElement> {
  const root = el('section', { class: 'admin-instances' });
  const status = el('p', { class: 'meta', role: 'status', 'aria-live': 'polite' });
  const say = (text: string, bad = false) => { status.textContent = text; status.className = bad ? 'meta error' : 'meta'; status.setAttribute('role', 'status'); };

  async function draw(): Promise<void> {
    editing = ''; // a redraw builds a fresh 'Add' form: no edit may outlive it
    const d = await get<AdminData>('admin/instances');
    const page = rowsOf(d.page), file = rowsOf(d.file), sources = rowsOf(d.sources), props = rowsOf(d.proposals), audit = rowsOf(d.audit);
    root.replaceChildren(
      el('h2', {}, 'Instances'),
      el('p', { class: 'meta' }, `${file.length} from pgvigil.yaml (read-only), ${page.length} added here, ${props.filter(p => p.state === 'proposed' && !p.gone).length} proposed by the sync sources. `,
        'A change reaches the collector within 15 seconds, without a restart (inventory generation ', String(d.generation), '). ',
        d.secret_dir ? `Credentials are written to their own files in ${d.secret_dir}; the repository keeps only each file's name.` : ''),
      // read only on this server: a note, not an error (the page works; the join's w9c)
      d.writable ? '' : el('p', { class: 'meta', role: 'note' }, `Read only: ${d.why_not}.`),
      status,
      instanceForm(d),
      el('h3', {}, 'Instances added here'),
      grid(page, pageCols, 'No instance was added here yet.'),
      el('h3', {}, 'Instances from pgvigil.yaml'),
      el('p', { class: 'meta' }, 'Changed in the file, not here; the collector reads the file when it starts.'),
      grid(file, [{ key: 'name' }, { key: 'engine' }, { key: 'platform' }, { key: 'tags', wide: true }, { key: 'source' }], 'pgvigil.yaml lists no instance.'),
      el('h3', {}, 'Sync sources'),
      el('p', { class: 'meta' }, 'A source never adds or removes an instance by itself: its new servers are proposed below, a server gone from it is marked gone.'),
      grid(sources, sourceCols, 'No sync source yet.'),
      sourceForm(d),
      el('h3', {}, `Proposed servers (${props.length})`),
      grid(props, proposalCols, 'No source has proposed a server yet.'),
      el('h3', {}, 'Changes (the last 200)'),
      grid(audit, [{ key: 'at', fmt: fmtTime }, { key: 'ui_user', label: 'by' }, { key: 'client' }, { key: 'op' }, { key: 'target' },
        { key: 'outcome', fmt: v => badge(String(v), v === 'done' ? '' : 'warn') }, { key: 'detail', wide: true }], 'No change yet.'),
    );
    readOnly(d);
  }

  // read only: every control that would write (the forms', the rows' actions) is disabled and says why on hover; the
  // grids' own filters and 'Show more' only read, and stay as they are (as ack.ts and alert_rules.ts do)
  function readOnly(d: AdminData): void {
    if (d.writable) return;
    for (const c of root.querySelectorAll('form button, form input, form select, form textarea, .actions button')) {
      (c as HTMLButtonElement).disabled = true;
      (c as HTMLElement).title = d.why_not;
    }
  }

  async function act(path: string, data: Record<string, unknown>, done: string): Promise<boolean> {
    say('Working…');
    // one request at a time: a second click (a double Approve) waits for the redraw
    for (const b of root.querySelectorAll('button')) (b as HTMLButtonElement).disabled = true;
    try {
      const r = await send(path, data);
      if (!r.ok) { for (const b of root.querySelectorAll('button')) (b as HTMLButtonElement).disabled = false; say(`Not done: ${why(r.body)}`, true); return false; }
      await draw();
      say(done + (r.body.sync_error ? ` The first read failed: ${String(r.body.sync_error)}` : ''));
      return true;
    } catch (e) { for (const b of root.querySelectorAll('button')) (b as HTMLButtonElement).disabled = false; say(`Not done: ${(e as Error).message}`, true); return false; }
  }

  // the add / edit form; edit fills it from a row (the password is asked again when the connection changes)
  let editing = '';
  function instanceForm(d: AdminData): HTMLElement {
    const f = el('form', { class: 'admin-form', 'aria-label': 'Add or edit an instance' });
    const engine = select('engine', [['postgres', 'PostgreSQL'], ['sqlserver', 'SQL Server']]);
    const name = input('name', { required: '', maxlength: '63', pattern: '[A-Za-z0-9][A-Za-z0-9_.@-]{0,62}' });
    const host = input('host', { required: '' }), port = input('port', { inputmode: 'numeric', size: '6' }), dbname = input('dbname');
    const auth = select('auth', authOpts('postgres')), platform = select('platform', platOpts('postgres'));
    const login = input('login'), password = el('input', { name: 'password', type: 'password', autocomplete: 'new-password' });
    const options = input('options', { placeholder: 'e.g. TrustServerCertificate=true or sslmode=require' }), tags = input('tags', { placeholder: 'env:prod team:billing' });
    const legend = el('legend', {}, 'Add an instance');
    const submit = el('button', { type: 'submit' }, 'Add'), test = el('button', { type: 'button' }, 'Test the connection'), cancel = el('button', { type: 'button', hidden: '' }, 'Cancel the edit');
    engine.addEventListener('change', () => { auth.replaceChildren(...authOpts(engine.value).map(([v, t]) => el('option', { value: v }, t))); platform.replaceChildren(...platOpts(engine.value).map(([v, t]) => el('option', { value: v }, t))); });
    const values = () => ({ engine: engine.value, name: name.value.trim(), host: host.value.trim(), port: port.value.trim(), dbname: dbname.value.trim(), auth: auth.value,
      platform: platform.value, login: login.value.trim(), password: password.value, options: options.value.trim(), tags: tags.value.trim() });
    const reset = () => { editing = ''; f.reset(); legend.textContent = 'Add an instance'; submit.textContent = 'Add'; cancel.hidden = true; name.disabled = false; engine.disabled = false; };
    cancel.addEventListener('click', reset);
    test.addEventListener('click', async () => {
      say('Connecting…');
      const v = values();
      const r = await send('admin/instances', editing && !v.password ? { op: 'test', name: editing } : { op: 'test', ...v });
      say(r.ok ? (r.body.ok ? String(r.body.detail) : `The connection failed: ${String(r.body.detail)}`) : `Not tested: ${why(r.body)}`, !(r.ok && r.body.ok));
    });
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      const v = values();
      const ok = await act('admin/instances', { op: editing ? 'edit' : 'add', ...v, name: editing || v.name }, editing ? `Saved ${editing}.` : `Added ${v.name}: the collector starts on it within 15 seconds.`);
      if (ok) reset();
    });
    (f as HTMLFormElement & { fill?: (r: Row) => void }).fill = (r: Row) => {
      editing = String(r.name); legend.textContent = `Edit ${editing}`; submit.textContent = 'Save'; cancel.hidden = false;
      engine.value = String(r.engine); engine.dispatchEvent(new Event('change')); engine.disabled = true;
      name.value = editing; name.disabled = true; host.value = String(r.host ?? ''); port.value = r.port == null ? '' : String(r.port);
      dbname.value = String(r.dbname ?? ''); auth.value = String(r.auth); platform.value = String(r.platform ?? 'auto'); login.value = String(r.login ?? '');
      password.value = ''; options.value = String(r.options ?? ''); tags.value = String(r.tags ?? ''); name.focus();
      say(`Editing ${editing}: a change of the host, port, database, login or authentication asks for the password again.`);
    };
    formRef = f as HTMLFormElement & { fill?: (r: Row) => void };
    f.append(el('fieldset', {}, legend,
      el('div', {}, field('Engine', engine), field('Name', name), field('Host', host), field('Port', port), field('Database', dbname), field('Platform', platform)),
      el('div', {}, field('Authentication', auth), field('Login', login), field('Password', password), field('Driver options', options), field('Tags (space-separated)', tags)),
      el('div', {}, submit, ' ', test, ' ', cancel)));
    if (!d.writable) for (const c of f.querySelectorAll('input, select, button')) (c as HTMLInputElement).disabled = true;
    return f;
  }
  let formRef: (HTMLFormElement & { fill?: (r: Row) => void }) | null = null;

  // a remove asks twice: the first click arms the row's own confirm button (no browser dialog)
  function removeButton(label: string, onConfirm: () => void): HTMLElement {
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `Remove ${label}` }, 'Remove');
    b.addEventListener('click', () => {
      const yes = el('button', { type: 'button', class: 'link danger', 'aria-label': `Confirm: remove ${label}` }, `Remove ${label}: confirm`);
      const no = el('button', { type: 'button', class: 'link', 'aria-label': `Keep ${label}` }, 'Keep');
      yes.addEventListener('click', onConfirm);
      no.addEventListener('click', () => { void draw(); });
      b.replaceWith(el('span', {}, yes, ' ', no));
      yes.focus();
    });
    return b;
  }

  const pageCols: Col[] = [
    { key: 'name' }, { key: 'engine' }, { key: 'host' }, { key: 'port', num: true }, { key: 'auth' }, { key: 'tags', wide: true },
    { key: 'disabled', label: 'state', fmt: v => badge(v ? 'disabled' : 'collected', v ? 'warn' : '') },
    { key: 'tested_ok', label: 'last test', fmt: (v, r) => r.tested_at == null ? 'not tested' : `${v ? 'connected' : 'failed'} ${fmtTime(r.tested_at)}` },
    { key: 'last_collected', label: 'last collected', fmt: fmtTime },
    { key: 'source' },
    { key: 'actions', fmt: (_v, r) => {
      const n = String(r.name);
      const test = el('button', { type: 'button', class: 'link', 'aria-label': `Test ${n}` }, 'Test');
      test.addEventListener('click', async () => {
        say(`Connecting to ${n}…`);
        const res = await send('admin/instances', { op: 'test', name: n });
        if (res.ok) { await draw(); say(res.body.ok ? `${n}: ${String(res.body.detail)}` : `${n}: the connection failed: ${String(res.body.detail)}`, !res.body.ok); } else say(`Not tested: ${why(res.body)}`, true);
      });
      const edit = el('button', { type: 'button', class: 'link', 'aria-label': `Edit ${n}` }, 'Edit');
      edit.addEventListener('click', () => formRef?.fill?.(r));
      const toggle = el('button', { type: 'button', class: 'link', 'aria-label': `${r.disabled ? 'Enable' : 'Disable'} ${n}` }, r.disabled ? 'Enable' : 'Disable');
      toggle.addEventListener('click', () => { void act('admin/instances', { op: r.disabled ? 'enable' : 'disable', name: n }, r.disabled ? `${n} enabled: collected again within 15 seconds.` : `${n} disabled: its collections stop within 15 seconds.`); });
      const rm = removeButton(n, () => { void act('admin/instances', { op: 'remove', name: n }, `${n} removed: its collections stop within 15 seconds; its history stays.`); });
      return el('span', { class: 'actions' }, test, ' ', edit, ' ', toggle, ' ', rm);
    } },
  ];

  const sourceCols: Col[] = [
    { key: 'name' }, { key: 'kind' }, { key: 'ref', label: 'reads', wide: true }, { key: 'every_s', label: 'every (min)', num: true, fmt: v => String(Math.round(Number(v) / 60)) },
    { key: 'enabled', fmt: v => badge(v ? 'on' : 'off', v ? '' : 'warn') }, { key: 'last_ok', label: 'last read', fmt: fmtTime }, { key: 'last_count', label: 'servers', num: true },
    { key: 'last_error', label: 'last error', wide: true },
    { key: 'actions', fmt: (_v, r) => {
      const n = String(r.name);
      const sync = el('button', { type: 'button', class: 'link', 'aria-label': `Read ${n} now` }, 'Read now');
      sync.addEventListener('click', () => { void act('admin/sources', { op: 'sync', name: n }, `${n} read.`); });
      const toggle = el('button', { type: 'button', class: 'link', 'aria-label': `${r.enabled ? 'Turn off' : 'Turn on'} ${n}` }, r.enabled ? 'Turn off' : 'Turn on');
      toggle.addEventListener('click', () => { void act('admin/sources', { op: r.enabled ? 'disable' : 'enable', name: n }, `${n} turned ${r.enabled ? 'off' : 'on'}.`); });
      const rm = removeButton(`source ${n}`, () => { void act('admin/sources', { op: 'remove', name: n }, `Source ${n} removed with its proposals; the instances approved from it stay.`); });
      return el('span', { class: 'actions' }, sync, ' ', toggle, ' ', rm);
    } },
  ];

  const proposalCols: Col[] = [
    { key: 'source' }, { key: 'server' }, { key: 'display_name', label: 'name' }, { key: 'engine' }, { key: 'tags', wide: true },
    { key: 'state', fmt: (v, r) => r.gone ? badge('gone from the source', 'warn') : badge(String(v), v === 'proposed' ? 'info' : '') },
    { key: 'instance_name', label: 'instance' }, { key: 'last_seen', label: 'last seen', fmt: fmtTime }, { key: 'gone_at', label: 'gone since', fmt: fmtTime },
    { key: 'actions', fmt: (_v, r) => {
      const id = String(r.proposal_id), s = String(r.server);
      const out = el('span', { class: 'actions' });
      if (r.state === 'proposed' && !r.gone) {
        const ap = el('button', { type: 'button', class: 'link', 'aria-label': `Approve ${s}` }, 'Approve');
        ap.addEventListener('click', () => { void act('admin/proposals', { op: 'approve', proposal_id: id }, `${s} approved: collected within 15 seconds.`); });
        const ig = el('button', { type: 'button', class: 'link', 'aria-label': `Ignore ${s}` }, 'Ignore');
        ig.addEventListener('click', () => { void act('admin/proposals', { op: 'ignore', proposal_id: id }, `${s} ignored.`); });
        out.append(ap, ' ', ig);
      } else if (r.state === 'ignored') {
        const un = el('button', { type: 'button', class: 'link', 'aria-label': `Propose ${s} again` }, 'Propose again');
        un.addEventListener('click', () => { void act('admin/proposals', { op: 'unignore', proposal_id: id }, `${s} proposed again.`); });
        out.append(un);
      } else if (r.state === 'approved' && r.gone && r.instance_name) {
        const n = String(r.instance_name);
        out.append(removeButton(n, () => { void act('admin/instances', { op: 'remove', name: n }, `${n} removed: its collections stop within 15 seconds; its history stays.`); }));
      }
      return out;
    } },
  ];

  function sourceForm(d: AdminData): HTMLElement {
    const f = el('form', { class: 'admin-form', 'aria-label': 'Add a sync source' });
    const kind = select('kind', [['cms', 'SQL Server Central Management Server'], ['dbadash', 'a DBA Dash repository (pgvigil.yaml dbadash:)'], ['sqlserver_list', 'a SQL Server list file (CSV or one server per line)'],
      ['pg_service', 'a pg_service.conf'], ['pg_csv', 'a PostgreSQL list file (CSV or one server per line)']]);
    const name = input('name', { required: '', maxlength: '51' }), every = input('every_min', { inputmode: 'numeric', size: '6', value: '60' });
    const cmsHost = input('cms_host'), cmsPort = input('cms_port', { inputmode: 'numeric', size: '6' }), cmsAuth = select('cms_auth', authOpts('sqlserver'));
    const cmsLogin = input('cms_login'), cmsPw = el('input', { name: 'cms_password', type: 'password', autocomplete: 'new-password' }), cmsOpt = input('cms_options', { placeholder: 'TrustServerCertificate=true' });
    const ref = input('ref', { placeholder: '/etc/pgvigil/servers.csv' });
    const repo = select('repo', d.dbadash.map(n => [n, n] as [string, string]));
    const credAuth = select('auth', [['sql', 'SQL login'], ['windows', 'Windows account'], ['entra', 'Entra service principal'], ['password', 'PostgreSQL login'], ['pgpass', '.pgpass']]);
    const credLogin = input('cred_login'), credPw = el('input', { name: 'cred_password', type: 'password', autocomplete: 'new-password' }), credOpt = input('cred_options');
    const cms = el('div', {}, field('CMS host', cmsHost), field('Port', cmsPort), field('Authentication', cmsAuth), field('Login', cmsLogin), field('Password', cmsPw), field('Driver options', cmsOpt));
    const fileRow = el('div', { hidden: '' }, field('The file\'s path on this server', ref));
    const repoRow = el('div', { hidden: '' }, field('Repository', repo));
    const show = () => { cms.hidden = kind.value !== 'cms'; fileRow.hidden = !['sqlserver_list', 'pg_service', 'pg_csv'].includes(kind.value); repoRow.hidden = kind.value !== 'dbadash';
      credAuth.value = kind.value.startsWith('pg') ? 'password' : 'sql'; };
    kind.addEventListener('change', show);
    f.addEventListener('submit', async ev => {
      ev.preventDefault();
      const ok = await act('admin/sources', { op: 'add', kind: kind.value, name: name.value.trim(), every_s: String(Math.round(Number(every.value || '60') * 60)),
        cms_host: cmsHost.value.trim(), cms_port: cmsPort.value.trim(), cms_auth: cmsAuth.value, cms_login: cmsLogin.value.trim(), cms_password: cmsPw.value, cms_options: cmsOpt.value.trim(),
        ref: kind.value === 'dbadash' ? repo.value : ref.value.trim(), auth: credAuth.value, cred_login: credLogin.value.trim(), cred_password: credPw.value, cred_options: credOpt.value.trim() },
        `Source ${name.value.trim()} added and read.`);
      if (ok) f.reset();
    });
    f.append(el('fieldset', {}, el('legend', {}, 'Add a sync source'),
      el('div', {}, field('Kind', kind), field('Name', name), field('Read every (minutes)', every)),
      cms, fileRow, repoRow,
      el('div', {}, el('span', { class: 'meta' }, 'The login an approved server is read with: '), field('Authentication', credAuth), field('Login', credLogin), field('Password', credPw), field('Driver options', credOpt)),
      el('div', {}, el('button', { type: 'submit' }, 'Add the source'))));
    if (!d.writable) for (const c of f.querySelectorAll('input, select, button')) (c as HTMLInputElement).disabled = true;
    return f;
  }

  try { await draw(); } catch (e) { root.replaceChildren(el('h2', {}, 'Instances'), el('p', { class: 'error' }, (e as Error).message)); }
  return root;
}
