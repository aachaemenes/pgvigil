// The Extensions tab (task 30): per instance what the server can install, what each database has installed
// (outdated ones marked), what the server preloads with the libraries' own settings, the change history and
// the extension findings; and the fleet root, "which servers have X". Each view reads the API itself, so the
// shell only mounts it (the routes and the tree entry are the shell's).
import { get, Row, rowsOf, Table } from './api';
import { badge, Col, el, fmtTime, grid } from './ui';

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const yes = (v: unknown) => v ? 'yes' : '';

interface ExtInstance { available: Table | null; installed: Table | null; preloaded: Table | null; history: Table | null; findings: Table | null }

// extensionsView: one instance (available / installed per database / preloaded / outdated / history).
export async function extensionsView(instance: number): Promise<HTMLElement> {
  const d = await get<ExtInstance>('extensions', { instance });
  const avail = rowsOf(d.available), inst = rowsOf(d.installed), pre = rowsOf(d.preloaded);
  const sec = el('section', {}, el('h2', {}, 'Extensions'));
  if (avail.length === 0 && inst.length === 0) {
    sec.append(el('p', { class: 'empty' }, 'No extensions read yet: the extensions collection runs hourly.'));
    return sec;
  }
  const outdated = inst.filter(r => r.outdated);
  const inUse = avail.filter(r => Number(r.installed_dbs) > 0 || r.preloaded);
  const dbs = new Set(inst.map(r => String(r.datname)));
  sec.append(el('p', { class: 'meta' },
    `${inUse.length} in use (installed or preloaded), ${avail.filter(r => r.available).length} available on the server, ` +
    `${dbs.size} database(s) read, ${outdated.length} installed below the server's version.` +
    (avail[0]?.snapshot_at ? ` Read ${fmtTime(avail[0].snapshot_at)}.` : '')));

  const findings = rowsOf(d.findings);
  if (findings.length) {
    sec.append(el('h3', {}, 'Findings'), grid(findings, [
      { key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'extension' }, { key: 'value' },
      { key: 'suggested' }, { key: 'detail', wide: true },
    ]));
  }
  if (outdated.length) {
    sec.append(el('h3', {}, 'Outdated (ALTER EXTENSION ... UPDATE due)'), grid(outdated, [
      { key: 'datname', label: 'database' }, { key: 'name', label: 'extension' },
      { key: 'version', label: 'installed' }, { key: 'default_version', label: 'server offers' },
    ]));
  }
  sec.append(el('h3', {}, 'Installed per database'), grid(inst, [
    { key: 'datname', label: 'database' }, { key: 'name', label: 'extension' },
    { key: 'version', label: 'version', fmt: (v, r) => r.outdated ? badge(String(v ?? ''), 'warn') : String(v ?? '') },
    { key: 'default_version', label: 'server offers' }, { key: 'schema_name', label: 'schema' },
  ], 'No extension installed in any database read.'));

  const two = el('div', { class: 'two' });
  two.append(el('div', {}, el('h3', {}, 'Preloaded and library settings'),
    el('p', { class: 'meta' }, 'A library\'s own settings appear only while it is loaded.'),
    grid(pre, [{ key: 'name', label: 'setting' }, { key: 'setting', label: 'value', wide: true }, { key: 'unit' }],
      'The preload lists are not readable by the monitoring login (pg_read_all_settings, part of pg_monitor).')));
  two.append(el('div', {}, el('h3', {}, 'Change history'), grid(rowsOf(d.history), [
    { key: 'changed_at', label: 'changed', fmt: fmtTime }, { key: 'datname', label: 'database', fmt: v => v == null ? '(server)' : String(v) },
    { key: 'name', label: 'extension' }, { key: 'change' },
    { key: 'old_value', label: 'old' }, { key: 'new_value', label: 'new' },
  ], 'No change recorded since the first read.')));
  sec.append(two);

  sec.append(el('h3', {}, 'Available on the server'), grid(avail, [
    { key: 'name', label: 'extension' }, { key: 'available', label: 'package', fmt: v => v ? 'yes' : badge('library only', '') },
    { key: 'default_version', label: 'version' }, { key: 'preloaded', label: 'preloaded' },
    { key: 'installed_dbs', label: 'databases', num: true }, { key: 'versions', label: 'installed versions' },
    { key: 'outdated_dbs', label: 'outdated in', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : '' },
    { key: 'comment', wide: true },
  ]));
  return sec;
}

// extensionsFleetView: the fleet root, "which servers have X". keep narrows it to a tag folder; instLink
// turns an instance name into a link to that instance's Extensions tab.
export async function extensionsFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const d = await get<{ fleet: Table | null }>('extensions', {});
  let rows = rowsOf(d.fleet);
  if (keep) rows = rows.filter(keep);
  const names = [...new Set(rows.map(r => String(r.extension)))].sort();
  const instances = new Set(rows.map(r => String(r.instance_id)));
  const cols: Col[] = [
    { key: 'extension' },
    { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
    { key: 'platform' },
    { key: 'preloaded' },
    { key: 'installed_dbs', label: 'databases', num: true },
    { key: 'versions', label: 'installed versions' },
    { key: 'default_version', label: 'server offers' },
    { key: 'outdated_dbs', label: 'outdated in', num: true, fmt: v => Number(v) > 0 ? badge(String(v), 'warn') : '' },
    { key: 'available', label: 'package', fmt: yes },
    { key: 'databases', wide: true },
  ];
  const pick = el('select', { 'aria-label': 'extension' }, el('option', { value: '' }, `every extension (${names.length})`),
    ...names.map(n => el('option', { value: n }, n)));
  const out = el('div');
  const draw = () => {
    const sel = (pick as HTMLSelectElement).value;
    const shown = sel ? rows.filter(r => r.extension === sel) : rows;
    const n = new Set(shown.map(r => String(r.instance_id))).size;
    out.replaceChildren(
      el('p', { class: 'meta' }, sel ? `${sel}: on ${n} of ${instances.size} instance(s).` : `${names.length} extension(s) in use on ${instances.size} instance(s).`),
      grid(shown, cols, 'No extension is installed or preloaded on any instance read yet.'));
  };
  pick.addEventListener('change', draw);
  draw();
  return el('section', {}, el('h2', {}, 'Extensions'),
    el('p', { class: 'meta' }, 'Which servers have an extension: installed in a database or preloaded. Read hourly.'),
    el('label', {}, 'Extension ', pick), out);
}
