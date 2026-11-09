// The Roles tab (task 31): per instance the roles with their attributes, the memberships, the ACL grids per
// database (the database ACL, the schema ACLs, the default privileges), the hba rules or why they were not read,
// the change history and the role findings; and the fleet root, every server's superusers and login roles. Each
// view reads /api/roles itself, so the shell only mounts it (the routes and the tree entry are the shell's).
import { get, Row, rowsOf, Table } from './api';
import { badge, Col, el, fmtTime, grid, tile } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const yes = (v: unknown) => v ? 'yes' : '';
const flag = (kind: string) => (v: unknown) => v ? badge('yes', kind) : '';
const never = (v: unknown) => v == null ? '' : fmtTime(v);
const opt = (v: unknown) => v == null ? '' : v ? 'yes' : 'no';
const privs = (v: unknown, r: Row) => String(v ?? '') + (r.grantable ? ` (grant option: ${String(r.grantable)})` : '');
const dflt = (v: unknown) => v ? badge('default', '') : '';

// roleName marks the server's and the platform's own roles, so an application role stands out.
const roleName = (v: unknown, r: Row) => r.is_platform ? el('span', { class: 'meta' }, String(v ?? '') + ' (platform)') : String(v ?? '');

const roleCols: Col[] = [
  { key: 'rolname', label: 'role', fmt: roleName },
  { key: 'super', label: 'superuser', fmt: (v, r) => v ? badge('yes', r.is_platform ? '' : 'warn') : '' },
  { key: 'canlogin', label: 'login', fmt: yes },
  { key: 'createrole', label: 'createrole', fmt: (v, r) => v ? badge('yes', r.super || r.is_platform ? '' : 'warn') : '' },
  { key: 'createdb', label: 'createdb', fmt: yes },
  { key: 'replication', fmt: yes },
  { key: 'bypassrls', label: 'bypassrls', fmt: (v, r) => v ? badge('yes', r.super || r.is_platform ? '' : 'warn') : '' },
  { key: 'inherit', fmt: v => v ? '' : 'noinherit' },
  { key: 'connlimit', label: 'conn. limit', num: true, fmt: v => v == null || Number(v) === -1 ? '' : String(v) },
  { key: 'valid_until', label: 'password valid until', fmt: (v) => v == null ? '' : new Date(String(v)) < new Date() ? badge(fmtTime(v) + ' (expired)', 'warn') : fmtTime(v) },
  { key: 'member_of', label: 'member of', wide: true },
  { key: 'config', label: 'ALTER ROLE SET', wide: true },
];

interface RolesInstance {
  state: Table | null; roles: Table | null; members: Table | null; dbacl: Table | null; schemaacl: Table | null;
  defacl: Table | null; hba: Table | null; history: Table | null; findings: Table | null;
}

// rolesView: one instance's Roles tab.
export async function rolesView(instance: number): Promise<HTMLElement> {
  const d = await get<RolesInstance>('roles', { instance });
  const st = rowsOf(d.state)[0];
  const roles = rowsOf(d.roles);
  const sec = el('section', {}, el('h2', {}, 'Roles'));
  if (!st || roles.length === 0) {
    sec.append(el('p', { class: 'empty' }, 'No roles read yet: the roles collection runs hourly.'));
    return sec;
  }
  const supers = roles.filter(r => r.super && !r.is_platform), logins = roles.filter(r => r.canlogin);
  const findings = rowsOf(d.findings), hba = rowsOf(d.hba), history = rowsOf(d.history);
  const warn = findings.filter(f => f.severity !== 'info').length;
  sec.append(el('div', { class: 'tiles' },
    tile('roles', String(roles.length)),
    tile('superusers (not the platform\'s)', String(supers.length), supers.length ? 'warn' : 'ok'),
    tile('login roles', String(logins.length)),
    tile('findings', String(findings.length), warn ? 'warn' : 'ok'),
    tile('hba rules', st.hba_status === 'read' ? String(st.hba_rules ?? hba.length) : 'not read', st.hba_status === 'read' ? '' : 'warn')));
  sec.append(el('p', { class: 'meta' },
    `Read as ${String(st.login_name ?? '?')}${st.login_is_super ? ' (a superuser)' : ''}` +
    `${st.login_has_pg_monitor === false ? ', which is NOT a member of pg_monitor' : ''}, ${fmtTime(st.snapshot_at)}. ` +
    'A password is never read: pg_roles shows it masked, and pgvigil does not read pg_authid.'));

  if (findings.length) {
    sec.append(el('h3', {}, 'Findings'), grid(findings, [
      { key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'rule' }, { key: 'value', label: 'role' },
      { key: 'suggested' }, { key: 'detail', wide: true },
    ]));
  }

  sec.append(el('h3', {}, 'Roles'), grid(roles, roleCols));
  sec.append(el('h3', {}, 'Memberships'), grid(rowsOf(d.members), [
    { key: 'role_name', label: 'role' }, { key: 'member_name', label: 'member' }, { key: 'grantor' },
    { key: 'admin_option', label: 'admin option', fmt: flag('') },
    { key: 'inherit_option', label: 'inherit', fmt: opt }, { key: 'set_option', label: 'set role', fmt: opt },
  ], 'No role is a member of another.'));

  // the ACL grids: one database at a time, picked from the databases read
  const dbacl = rowsOf(d.dbacl), schemaacl = rowsOf(d.schemaacl), defacl = rowsOf(d.defacl);
  const dbs = [...new Set([...dbacl, ...schemaacl, ...defacl].map(r => String(r.datname)))].sort();
  const pick = el('select', {}, el('option', { value: '' }, `every database (${dbs.length})`), ...dbs.map(n => el('option', { value: n }, n)));
  const acl = el('div');
  const draw = () => {
    const sel = (pick as HTMLSelectElement).value;
    const only = (rows: Row[]) => sel ? rows.filter(r => r.datname === sel) : rows;
    acl.replaceChildren(
      el('h4', {}, 'Database privileges'),
      grid(only(dbacl), [
        { key: 'datname', label: 'database' }, { key: 'owner' }, { key: 'grantee' },
        { key: 'privileges', fmt: privs }, { key: 'grantor' }, { key: 'is_default', label: '', fmt: dflt },
      ], 'No database ACL read.'),
      el('h4', {}, 'Schema privileges'),
      grid(only(schemaacl), [
        { key: 'datname', label: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'owner' }, { key: 'grantee' },
        { key: 'privileges', fmt: privs }, { key: 'grantor' }, { key: 'is_default', label: '', fmt: dflt },
      ], 'No schema ACL read for this database (it could not be read, or it is past the databases cap).'),
      el('h4', {}, 'Default privileges (ALTER DEFAULT PRIVILEGES)'),
      grid(only(defacl), [
        { key: 'datname', label: 'database' }, { key: 'owner', label: 'for objects of' },
        { key: 'schema_name', label: 'in schema', fmt: v => v == null ? 'every schema' : String(v) },
        { key: 'objtype', label: 'on' }, { key: 'grantee' }, { key: 'privileges', fmt: privs }, { key: 'grantor' },
      ], 'No default privileges set.'));
  };
  pick.addEventListener('change', draw);
  draw();
  sec.append(el('h3', {}, 'Privileges per database'), el('label', {}, 'Database ', pick), acl);

  sec.append(el('h3', {}, 'pg_hba.conf rules'));
  if (st.hba_status !== 'read') {
    sec.append(el('p', { class: 'meta' }, `Not read: ${String(st.hba_note ?? 'the read was skipped')}` +
      (st.hba_read_at ? ` The rules below are from the last read that could, ${fmtTime(st.hba_read_at)}.` : '')));
  } else {
    sec.append(el('p', { class: 'meta' }, `${String(st.hba_rules ?? hba.length)} rule(s), checksum ${String(st.hba_checksum ?? '')}: ` +
      'a change of the file between two reads is in the history below.'));
  }
  if (hba.length || st.hba_status === 'read') {
    sec.append(grid(hba, [
      { key: 'rule_number', label: '#', num: true }, { key: 'line_number', label: 'line', num: true },
      { key: 'type' }, { key: 'databases' }, { key: 'users' },
      { key: 'address', fmt: (v, r) => v == null ? '' : String(v) + (r.netmask ? '/' + String(r.netmask) : '') },
      { key: 'auth_method', label: 'method', fmt: v => v === 'trust' ? badge('trust', 'warn') : String(v ?? '') },
      { key: 'options', wide: true }, { key: 'error', fmt: v => v ? badge(String(v), 'crit') : '' },
    ], 'The file has no rules.'));
  }

  sec.append(el('h3', {}, 'Change history'), grid(history, [
    { key: 'changed_at', label: 'changed', fmt: fmtTime }, { key: 'object_kind', label: 'what' },
    { key: 'datname', label: 'database', fmt: v => v == null ? '' : String(v) }, { key: 'object', wide: true },
    { key: 'change' }, { key: 'old_value', label: 'old' }, { key: 'new_value', label: 'new' },
  ], 'No change recorded since the first read.'));
  return sec;
}

// rolesFleetView: the fleet root, every server's superusers and login roles, with a summary row per server. keep
// narrows it to a tag folder; instLink turns an instance name into a link to that instance's Roles tab.
export async function rolesFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const d = await get<{ summary: Table | null; roles: Table | null }>('roles', {});
  let sum = rowsOf(d.summary), roles = rowsOf(d.roles);
  if (keep) { sum = sum.filter(keep); roles = roles.filter(keep); }
  const link = (v: unknown, r: Row) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '');
  const supers = roles.filter(r => r.super && !r.is_platform);
  const noMon = sum.filter(r => r.login_has_pg_monitor === false).length;
  const which = el('select', {}, el('option', { value: 'super' }, 'superusers'), el('option', { value: 'login' }, 'login roles'),
    el('option', { value: 'all' }, 'superusers and login roles'));
  const out = el('div');
  const draw = () => {
    const w = (which as HTMLSelectElement).value;
    const shown = w === 'super' ? roles.filter(r => r.super) : w === 'login' ? roles.filter(r => r.canlogin) : roles;
    out.replaceChildren(grid(shown, [
      { key: 'instance', fmt: link }, { key: 'platform' }, { key: 'rolname', label: 'role', fmt: roleName },
      { key: 'super', label: 'superuser', fmt: (v, r) => v ? badge('yes', r.is_platform ? '' : 'warn') : '' },
      { key: 'canlogin', label: 'login', fmt: yes }, { key: 'createrole', fmt: yes }, { key: 'createdb', fmt: yes },
      { key: 'replication', fmt: yes }, { key: 'bypassrls', fmt: yes },
      { key: 'valid_until', label: 'password valid until', fmt: never }, { key: 'member_of', label: 'member of', wide: true },
    ], 'No role read on any instance yet.'));
  };
  which.addEventListener('change', draw);
  draw();
  return el('section', {}, el('h2', {}, 'Roles'),
    el('div', { class: 'tiles' },
      tile('instances read', String(sum.length)),
      tile('superusers beyond the platform\'s', String(supers.length), supers.length ? 'warn' : 'ok'),
      tile('login roles', String(roles.filter(r => r.canlogin).length)),
      tile('monitoring login without pg_monitor', String(noMon), noMon ? 'warn' : 'ok')),
    el('p', { class: 'meta' }, 'Per server: who is superuser and who can log in. Read hourly; a password is never read.'),
    grid(sum, [
      { key: 'instance', fmt: link }, { key: 'platform' },
      { key: 'superusers', label: 'superusers', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : '0' },
      { key: 'login_roles', label: 'login roles', num: true },
      { key: 'warnings', label: 'warnings', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : '0' },
      { key: 'changes_7d', label: 'changes (7 d)', num: true },
      { key: 'hba_status', label: 'hba rules', fmt: v => v === 'read' ? 'read' : badge(String(v ?? 'not read'), '') },
      { key: 'login_name', label: 'read as', fmt: (v, r) => r.login_has_pg_monitor === false ? badge(String(v) + ' (no pg_monitor)', 'warn') : String(v ?? '') },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], 'No roles read yet: the roles collection runs hourly.'),
    el('h3', {}, 'Roles'), el('label', {}, 'Show ', which), out);
}
