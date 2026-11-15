// The Security tab of a SQL Server instance (task 408): dbachecks' security checks and SQLMonitor's password-expiry
// notice, judged over what the mssql_security collection read (migration 0159). Every rule is shown, on or off, with
// what it sees, so a DBA can turn one on knowing what it will say; each is on or off at the fleet, a tag or this
// instance, and the day thresholds and owner lists are set the same way. The rules that need the Windows host or Active
// Directory (the site profile's D5 door) are listed as not enabled, with why. SQL Server Audit is the Audit tab's,
// the SQL logins' password age and the server roles are the Reports': linked, not copied. Data from
// /api/mssql/security; the route and the tab's entry are the shell's.
import { get, post, Row, rowsOf, Table } from './api';
import { Ctx, href } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid, offControl, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlSecurityTab = 'mssqlsecurity';

type Part = 'state' | 'read' | 'context' | 'rules' | 'findings' | 'hits' | 'settings' | 'logins' | 'server' | 'proxies' | 'databases' | 'objects' | 'config' | 'tags';
type Parts = Record<Part, Table | null> & { writable?: boolean; reason?: string };

const text = (v: unknown) => v == null ? '' : String(v);
const sevBadge = (v: unknown) => badge(text(v), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const PROSE = 'display:inline-block;min-width:22rem;max-width:40rem;white-space:normal';
const prose = (v: unknown) => v == null || v === '' ? '' : el('span', { style: PROSE }, text(v));
const yes = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';

// a rule's verdict in words and a colour; the word carries the meaning
function verdictBadge(v: unknown, r: Row): HTMLElement {
  switch (text(v)) {
    case 'hit': return badge(`${fmtNum(r.hits)} found`, r.is_on === true ? (r.default_severity === 'critical' ? 'crit' : 'warn') : '');
    case 'ok': return badge('nothing found', 'ok');
    case 'not read': return badge('not read', '');
    case 'n/a': return badge('does not apply here', '');
    case 'not enabled': return badge('not enabled', '');
  }
  return badge(text(v), '');
}

function whereSet(r: Row): string {
  const at = text(r.set_at);
  return at === 'default' ? 'the default' : at === 'tag' ? `the tag ${text(r.set_tag)}` : at === 'fleet' ? 'the fleet' : 'this instance';
}

const partWords: Record<string, string> = {
  logins: 'logins', server_perms: 'public\'s server permissions', registry: 'login auditing and HideInstance',
  auth: 'the collector\'s sign-in', proxies: 'Agent proxies', databases: 'databases',
};

function partBadge(status: unknown): HTMLElement {
  const s = text(status);
  return badge(s === 'off' ? 'not read: its rules are off' : s, s === 'read' ? 'ok' : s === 'failed' ? 'crit' : s === 'no right' ? 'warn' : '');
}

const readCols: Col[] = [
  { key: 'part', fmt: v => partWords[text(v)] ?? text(v) },
  { key: 'status', fmt: partBadge },
  { key: 'read_at', label: 'last read', fmt: fmtTime },
  { key: 'note', label: 'why, or what the admin may grant', fmt: prose },
];

const findingCols: Col[] = [
  { key: 'severity', fmt: sevBadge }, { key: 'check_name', label: 'finding' }, { key: 'object' },
  { key: 'detail', fmt: prose }, { key: 'at', label: 'read', fmt: fmtTime },
];

const hitCols: Col[] = [
  { key: 'label', label: 'rule' }, { key: 'severity', fmt: sevBadge }, { key: 'object' }, { key: 'detail', fmt: prose },
  { key: 'at', label: 'read', fmt: fmtTime },
];

const loginCols: Col[] = [
  { key: 'login_name', label: 'login' },
  { key: 'login_type', label: 'type', fmt: v => ({ S: 'SQL', U: 'Windows user', G: 'Windows group', E: 'Entra user', X: 'Entra group', C: 'certificate', K: 'asymmetric key' } as Record<string, string>)[text(v)] ?? text(v) },
  { key: 'is_original_sa', label: 'original sa', fmt: v => v === true ? 'yes (principal 1)' : '' },
  { key: 'is_disabled', label: 'state', fmt: v => v === true ? badge('disabled', '') : 'enabled' },
  { key: 'is_sysadmin', label: 'sysadmin', fmt: yes },
  { key: 'is_policy_checked', label: 'CHECK_POLICY', fmt: yes },
  { key: 'is_expiration_checked', label: 'CHECK_EXPIRATION', fmt: yes },
  { key: 'must_change', label: 'must change', fmt: yes },
  { key: 'days_until_expiration', label: 'password expires in', num: true,
    fmt: v => v == null ? '' : Number(v) === -1 ? 'never' : Number(v) === 0 ? badge('expired', 'crit') : `${fmtNum(v)} days` },
  { key: 'has_session', label: 'signed in now', fmt: v => v == null ? 'not read' : yes(v) },
  { key: 'modified_at', label: 'modified', fmt: fmtTime },
];

const serverCols: Col[] = [
  { key: 'kind', label: 'what', fmt: v => ({ registry: 'setting', auth: 'the collector\'s sign-in', perm: 'public holds', conn: 'connections by scheme / transport' } as Record<string, string>)[text(v)] ?? text(v) },
  { key: 'name', fmt: v => text(v) === 'AuditLevel' ? 'login auditing (AuditLevel)' : text(v) },
  { key: 'value', fmt: (v, r) => r.applies === false ? 'does not apply on Linux'
    : r.name === 'AuditLevel' ? ({ '0': 'none', '1': 'successful logins only', '2': 'failed logins only', '3': 'failed and successful logins' } as Record<string, string>)[text(v)] ?? text(v)
    : r.name === 'HideInstance' ? (text(v) === '1' ? 'hidden' : 'not hidden') : text(v) },
  { key: 'detail', fmt: prose },
  { key: 'snapshot_at', label: 'read', fmt: fmtTime },
];

const dbCols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'containment', fmt: v => Number(v) > 0 ? 'partial' : 'none' },
  { key: 'entered', label: 'last run', fmt: v => v === true ? 'read' : badge('not read: no access', '') },
  { key: 'read_at', label: 'its objects last read', fmt: fmtTime },
  { key: 'note', fmt: prose },
];

function daysLeft(v: unknown): string | HTMLElement {
  if (v == null) return '';
  const d = Math.ceil((new Date(text(v)).getTime() - Date.now()) / 86400000);
  return d <= 0 ? badge(`expired ${fmtTime(v)}`, 'crit') : `${fmtNum(d)} days (${fmtTime(v)})`;
}

const objectCols: Col[] = [
  { key: 'database_name', label: 'database' },
  { key: 'object_kind', label: 'kind', fmt: v => ({ user: 'user', guest_connect: 'guest CONNECT', assembly: 'CLR assembly', certificate: 'certificate', asym_key: 'asymmetric key', sym_key: 'symmetric key' } as Record<string, string>)[text(v)] ?? text(v) },
  { key: 'object_name', label: 'name' },
  { key: 'object_type', label: 'type' },
  { key: 'has_login', label: 'login with its SID', fmt: (v, r) => r.object_kind !== 'user' ? '' : v == null ? 'not testable' : v === true ? 'yes' : badge('none', 'warn') },
  { key: 'detail', label: 'permission set / algorithm / key protection' },
  { key: 'key_length', label: 'bits', num: true },
  { key: 'expires_at', label: 'expires', fmt: daysLeft },
  { key: 'cert_use', label: 'used for' },
];

const proxyCols: Col[] = [
  { key: 'proxy_name', label: 'proxy' }, { key: 'enabled', fmt: yes }, { key: 'credential_name', label: 'credential' },
  { key: 'public_granted', label: 'msdb public may use it', fmt: v => v === true ? badge('yes', 'warn') : 'no' },
];

const logCols: Col[] = [
  { key: 'created_at', label: 'when', fmt: fmtTime }, { key: 'created_by', label: 'who' }, { key: 'outcome' },
  { key: 'key' }, { key: 'value', fmt: prose }, { key: 'scope', fmt: (v, r) => v === 'tag' ? `tag ${text(r.tag)}` : text(v) },
  { key: 'detail', fmt: prose },
];

interface Scope { scope: 'instance' | 'tag' | 'fleet'; tag: string }

// the scope an edit goes to: this instance (the default), one of its tags, or the fleet
function scopeChooser(tags: string[], current: Scope, onChange: (s: Scope) => void): HTMLElement {
  const sel = el('select', { 'aria-label': 'Where an edit applies' },
    el('option', { value: 'instance' }, 'this instance'),
    ...tags.map(t => el('option', { value: 'tag:' + t }, `every instance tagged ${t}`)),
    el('option', { value: 'fleet' }, 'the whole fleet'));
  sel.value = current.scope === 'tag' ? 'tag:' + current.tag : current.scope;
  sel.addEventListener('change', () => {
    const v = sel.value;
    onChange(v.startsWith('tag:') ? { scope: 'tag', tag: v.slice(4) } : { scope: v as 'instance' | 'fleet', tag: '' });
  });
  return el('label', {}, 'Edits apply to ', sel);
}

export async function mssqlSecurityView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Security'));
  const scope: Scope = { scope: 'instance', tag: '' };
  const body = el('div', { 'aria-live': 'polite' });
  sec.append(body);

  const render = async () => {
    try {
      const d = await get<Parts>('mssql/security', { instance: ctx.instance });
      body.replaceChildren(...build(d));
    } catch (e) {
      body.replaceChildren(errorBox(e));
    }
  };

  // one edit, then the page again; a refusal says why where the edit was made
  const send = async (payload: Record<string, unknown>, where: HTMLElement) => {
    try {
      await post('mssql/security/config', payload);
      await render();
    } catch (e) {
      where.replaceChildren(errorBox(e));
    }
  };

  const build = (d: Parts): Node[] => {
    const out: Node[] = [];
    const state = rowsOf(d.state).find(r => r.collection === 'mssql_security');
    const read = rowsOf(d.read), rules = rowsOf(d.rules), findings = rowsOf(d.findings), context = rowsOf(d.context)[0];
    const why = d.writable ? '' : text(d.reason) || 'the settings cannot be edited on this server';

    out.push(el('p', { class: 'meta' },
      'dbachecks\' security checks and SQLMonitor\'s password-expiry notice, read every hour (mssql_security). ',
      'SQL Server Audit is on the ', el('a', { href: href(ctx, { tab: 'mssqlaudit' }) }, 'Audit tab'), '; the SQL logins\' password age and the server roles are the reports ',
      el('a', { href: href(ctx, { tab: 'rp_pwage' }) }, 'SQL Login Password Age'), ' and ',
      el('a', { href: href(ctx, { tab: 'rp_roles' }) }, 'Server Role Members'), '.'));
    if (!read.length) {
      out.push(el('p', { class: 'meta' }, badge('not read yet', ''),
        state?.status === 'skipped' ? ` The security read is skipped on this instance: ${text(state.note)}.`
          : ' The security read (mssql_security, hourly) has not read this instance yet. It needs VIEW ANY DEFINITION for the logins and every database\'s objects, VIEW SERVER STATE for the sessions and connections.'));
      return out;
    }
    if (context) {
      out.push(el('p', { class: 'meta' }, `Read as ${text(context.login_name)} on ${text(context.machine_name)}${context.linux === true ? ' (Linux)' : ''}, ${fmtTime(context.snapshot_at)}.`
        + (state && state.status !== 'ok' ? ` The last run: ${text(state.status)}${state.note ? ` - ${text(state.note)}` : ''}.` : '')));
    }
    if (findings.length) out.push(el('h3', {}, 'Findings'), grid(findings, findingCols));
    const on = rules.filter(r => r.is_on === true).length;
    const notRead = rules.filter(r => r.is_on === true && r.verdict === 'not read').length;
    out.push(el('div', { class: 'tiles' },
      tile('rules on', `${fmtNum(on)} of ${fmtNum(rules.filter(r => r.verdict !== 'not enabled').length)}`),
      tile('findings', findings.length ? `${fmtNum(findings.length)} found` : 'none', findings.some(f => f.severity === 'critical') ? 'crit' : findings.length ? 'warn' : ''),
      tile('rules on and not read', notRead ? `${fmtNum(notRead)} not read` : 'none', notRead ? 'warn' : ''),
      tile('not enabled (need the D5 door)', fmtNum(rules.filter(r => r.verdict === 'not enabled').length))));

    out.push(el('h3', {}, 'What was read'), grid(read, readCols));

    // the rules, each with its switch at the chosen scope
    const editNote = el('div', { 'aria-live': 'polite' });
    const tags = rowsOf(d.tags).map(t => text(t.tag)).filter(Boolean);
    const chooser = scopeChooser(tags, scope, s => { Object.assign(scope, s); });
    const target = () => ({ scope: scope.scope, tag: scope.scope === 'tag' ? scope.tag : '', instance_id: Number(ctx.instance) });
    const switchCell = (_: unknown, r: Row): Node => {
      if (r.verdict === 'not enabled') return el('span', { class: 'meta' }, text(r.departure));
      const box = el('span', {});
      const turn = el('button', { type: 'button', class: 'link' }, r.is_on === true ? 'Turn off' : 'Turn on');
      if (why) offControl(turn, why, undefined);
      else turn.addEventListener('click', () => send({ op: 'add', ...target(), key: 'rule:' + text(r.rule_key), value: r.is_on === true ? 'off' : 'on' }, editNote));
      box.append(turn);
      if (r.config_id != null && r.set_at !== 'default') {
        const clear = el('button', { type: 'button', class: 'link' }, `Clear ${whereSet(r)}'s setting`);
        if (why) offControl(clear, why, undefined);
        else clear.addEventListener('click', () => send({ op: 'end', config_id: Number(r.config_id) }, editNote));
        box.append(' ', clear);
      }
      if (why) box.append(' ', el('span', { class: 'off-reason' }, why));
      return box;
    };
    const ruleCols: Col[] = [
      { key: 'label', label: 'rule', fmt: (v, r) => r.departure && r.verdict !== 'not enabled' ? el('span', {}, text(v), ' ', el('abbr', { title: text(r.departure) }, '*')) : text(v) },
      { key: 'source' },
      { key: 'is_on', label: 'state', fmt: (v, r) => r.verdict === 'not enabled' ? badge('not enabled', '') : el('span', {}, v === true ? badge('on', 'ok') : badge('off', ''), ` (${whereSet(r)})`) },
      { key: 'verdict', label: 'what it sees', fmt: verdictBadge },
      { key: 'default_severity', label: 'severity', fmt: sevBadge },
      { key: 'part_note', label: 'read', fmt: (v, r) => r.verdict === 'not read' ? prose(v || 'its part has not been read') : '' },
      { key: 'rule_key', label: 'switch', fmt: switchCell },
    ];
    out.push(el('h3', {}, 'Rules'),
      el('p', { class: 'meta' }, 'A rule that is off still shows what it would find. ', el('abbr', { title: 'pgvigil departs from the source here: hover the star' }, '*'),
        ' marks a departure from the source tool (hover it). A rule that is off at every scope stops the read of its part.'),
      el('p', { class: 'meta' }, chooser), editNote, grid(rules, ruleCols));

    // the settings: day thresholds, the owner lists, the expected scheme
    const settings = rowsOf(d.settings).filter(s => s.value_kind !== 'rule');
    const settingCols: Col[] = [
      { key: 'label', label: 'setting' },
      { key: 'value', fmt: (v, r) => r.value_kind === 'list' ? (v == null ? 'the original sa login (on RDS the master user)' : text(v).replace(/[[\]"]/g, '').replace(/,/g, ', ') || 'empty') : text(v) },
      { key: 'set_at', label: 'set at', fmt: (_, r) => whereSet(r) },
      { key: 'key', label: 'change', fmt: (_, r) => {
        const input = el('input', { type: 'text', 'aria-label': `New value of ${text(r.label)}`, size: '24',
          placeholder: r.value_kind === 'list' ? 'login, login, ...' : r.value_kind === 'days' ? 'days' : 'KERBEROS or NTLM' });
        const save = el('button', { type: 'button', class: 'link' }, 'Save');
        const box = el('span', {}, input, ' ', save);
        if (why) { offControl(save, why, undefined); offControl(input, why, undefined); box.append(' ', el('span', { class: 'off-reason' }, why)); return box; }
        save.addEventListener('click', () => {
          const raw = input.value.trim();
          const value = r.value_kind === 'list' ? JSON.stringify(raw ? raw.split(',').map(x => x.trim()).filter(Boolean) : []) : raw;
          send({ op: 'add', ...target(), key: text(r.key), value }, editNote);
        });
        if (r.config_id != null && r.set_at !== 'default') {
          const clear = el('button', { type: 'button', class: 'link' }, 'Clear');
          clear.addEventListener('click', () => send({ op: 'end', config_id: Number(r.config_id) }, editNote));
          box.append(' ', clear);
        }
        return box;
      } },
    ];
    out.push(el('h3', {}, 'Settings'), grid(settings, settingCols));

    out.push(el('h3', {}, 'What every rule sees, on or off'), grid(rowsOf(d.hits), hitCols, 'No rule finds anything here.'));
    out.push(el('h3', {}, 'Logins'), grid(rowsOf(d.logins), loginCols, 'No login read (the logins part above says why).'));
    out.push(el('h3', {}, 'Server'), grid(rowsOf(d.server), serverCols, 'Nothing read at the server level yet.'));
    out.push(el('h3', {}, 'Agent proxies'), grid(rowsOf(d.proxies), proxyCols, 'No Agent proxy read (none, or the proxies part above says why).'));
    out.push(el('h3', {}, 'Databases'), grid(rowsOf(d.databases), dbCols, 'No database read yet.'));
    out.push(el('h3', {}, 'Database objects'),
      el('p', { class: 'meta' }, 'Users, guest\'s CONNECT, user CLR assemblies, certificates with their expiry and use, asymmetric and symmetric keys of every database read. master\'s certificates are read too (TDE\'s and backup encryption\'s live there), a departure from dbachecks.'),
      grid(rowsOf(d.objects), objectCols, 'No database object read yet.'));
    const cfg = rowsOf(d.config);
    out.push(el('details', {}, el('summary', {}, 'Settings rows and recent edits'),
      grid(cfg.filter(c => c.kind === 'row'), logCols, 'No setting is set: every rule and setting is at its default.'),
      grid(cfg.filter(c => c.kind === 'log'), logCols, 'No edit yet.')));
    return out;
  };

  await render();
  return sec;
}
