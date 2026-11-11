// The Configuration tab of a SQL Server instance: the values that changed between two reads on top, then every value
// of sys.configurations (a value set and not yet in use is marked: it waits for RECONFIGURE or a restart), then the
// services the server lists. Data from /api/mssql/config (mssql_instance, read hourly; mssql_services, every 5 minutes).
import { get, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';
import { changedText } from './diff';

// task 154: every change with valid from / to (/api/config/changes), the fleet pivot with the odd value marked
// (/api/mssql/config/fleet) and the trace flags with their history (/api/mssql/traceflags). Each part that its
// route does not answer (an older server) says so and the rest of the page stands.
async function safe<T>(f: () => Promise<T>): Promise<T | Error> { try { return await f(); } catch (e) { return e instanceof Error ? e : new Error(String(e)); } }

type Parts = Record<'values' | 'services', Table | null>;
const yn = (v: unknown) => v === true ? 'yes' : v === false ? 'no' : '';
const num = (v: unknown) => v == null ? '' : fmtNum(v);

export async function mssqlConfigView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Parts>('mssql/config', { instance: ctx.instance });
  const values = rowsOf(d.values), services = rowsOf(d.services);
  const sec = el('section', {}, el('h2', {}, 'Configuration'));
  if (values.length === 0) {
    sec.append(el('p', { class: 'empty' }, 'No read yet: the mssql_instance collection reads sys.configurations every hour.'));
    return sec;
  }
  const changed = values.filter(r => r.changed_at != null).sort((a, b) => String(b.changed_at).localeCompare(String(a.changed_at)));
  const pending = values.filter(r => r.pending === true && r.is_present !== false);
  // the newest read: a value no longer listed keeps the time of the last read that saw it
  const lastRead = values.map(r => String(r.snapshot_at ?? '')).reduce((a, b) => b > a ? b : a, '');
  sec.append(el('p', { class: 'meta counts' }, `${values.filter(r => r.is_present !== false).length} values, read ${fmtTime(lastRead)}; `,
    `${changed.length} changed since pgvigil first read them; `,
    pending.length ? el('span', { class: 'warn' }, `${pending.length} set and not in use yet`) : 'none waiting to take effect', '.'));
  const changeCols: Col[] = [
    { key: 'name' }, { key: 'previous_in_use', label: 'was', fmt: num }, { key: 'value_in_use', label: 'now in use', fmt: num },
    { key: 'changed_at', label: 'seen changed', fmt: fmtTime },
  ];
  sec.append(el('h3', {}, 'Changes'), el('p', { class: 'meta' }, 'A value whose value in use differed from the read before. The time is the read that saw it, within the hour of the change; the last change of each value is kept.'),
    grid(changed, changeCols, 'No value has changed between two reads.'));
  const valueCols: Col[] = [
    { key: 'name' },
    { key: 'value_in_use', label: 'in use', fmt: num },
    // a dynamic option waits for RECONFIGURE, any other for a restart of the service; a value no longer listed waits for nothing
    { key: 'value', label: 'set', fmt: (v, r) => r.pending === true && r.is_present !== false
      ? el('span', {}, num(v), ' ', badge(r.is_dynamic === true ? 'needs RECONFIGURE' : r.is_dynamic === false ? 'needs a restart' : 'not in use yet', 'warn')) : num(v) },
    { key: 'minimum', fmt: num }, { key: 'maximum', fmt: num },
    { key: 'is_dynamic', label: 'dynamic', fmt: yn }, { key: 'is_advanced', label: 'advanced', fmt: yn },
    { key: 'is_present', label: 'listed', fmt: v => v === false ? 'no longer' : 'yes' },
  ];
  sec.append(el('h3', {}, 'Values'), grid(values, valueCols));
  const [log, fleet, tf] = await Promise.all([
    safe(() => get<Record<'changes', Table | null>>('config/changes', { instance: ctx.instance })),
    safe(() => get<Record<'pivot', Table | null>>('mssql/config/fleet')),
    safe(() => get<Record<'flags' | 'history' | 'read', Table | null>>('mssql/traceflags', { instance: ctx.instance }))]);
  sec.append(el('h3', {}, 'Configuration change log'), el('p', { class: 'meta' }, 'Every value that was replaced, with the time it was in force: valid from the read that first saw it to the read that saw the next one. "first read": the value was there when pgvigil first read the server, so it began earlier.'));
  sec.append(log instanceof Error ? errorBox(log) : grid(rowsOf(log.changes), [
    { key: 'name' },
    { key: 'value_in_use', label: 'value in use', fmt: (v, r) => changedText(String(v ?? ''), r.removed ? '(no longer listed)' : String(r.new_value_in_use ?? '')) },
    { key: 'value', label: 'value set', fmt: num }, { key: 'new_value', label: 'new value set', fmt: num },
    { key: 'valid_from', label: 'valid from', fmt: (v, r) => v == null ? '(before pgvigil kept it)' : fmtTime(v) + (r.first_read ? ' (first read)' : '') },
    { key: 'valid_to', label: 'valid to', fmt: fmtTime },
    { key: 'is_dynamic', label: 'dynamic', fmt: yn }, { key: 'is_advanced', label: 'advanced', fmt: yn },
    { key: 'minimum', fmt: num }, { key: 'maximum', fmt: num },
  ], 'No value has changed since pgvigil first read it.'));
  sec.append(el('h3', {}, 'The fleet'));
  if (fleet instanceof Error) sec.append(errorBox(fleet)); else sec.append(...fleetPivot(rowsOf(fleet.pivot), Number(ctx.instance)));
  sec.append(el('h3', {}, 'Trace flags'));
  if (tf instanceof Error) sec.append(errorBox(tf));
  else if (!rowsOf(tf.read).length) sec.append(el('p', { class: 'empty' }, 'Not read yet: the mssql_traceflags collection reads DBCC TRACESTATUS(-1) every hour.'));
  else sec.append(grid(rowsOf(tf.flags), [
      { key: 'trace_flag', label: 'trace flag', num: true },
      { key: 'is_global', label: 'scope', fmt: v => v ? 'global' : 'the collector\'s session only' },
      { key: 'first_seen', label: 'on since', fmt: (v, r) => r.first_read ? `on at the first read (${fmtTime(v)})` : fmtTime(v) },
    ], `No trace flag is on (read ${fmtTime(rowsOf(tf.read)[0].snapshot_at)}).`),
    el('h4', {}, 'History'),
    grid(rowsOf(tf.history), [{ key: 'changed_at', label: 'change date', fmt: fmtTime }, { key: 'trace_flag', label: 'trace flag', num: true },
      { key: 'change', fmt: v => v === 'removed' ? badge('removed', 'warn') : 'added' }], 'No flag was added or removed since the first read.'));
  const svcCols: Col[] = [
    { key: 'service_name', label: 'service' },
    { key: 'status', fmt: (v, r) => r.is_present === false ? 'no longer listed' : v === 'Running' ? String(v) : badge(String(v ?? ''), 'warn') },
    { key: 'startup_type', label: 'start mode' }, { key: 'service_account', label: 'account' },
    { key: 'last_startup_at', label: 'started', fmt: fmtTime },
    { key: 'ifi_enabled', label: 'instant file initialization', fmt: yn }, { key: 'is_clustered', label: 'clustered', fmt: yn },
  ];
  sec.append(el('h3', {}, 'Services'), grid(services, svcCols, 'No service listed: an Azure SQL Database or a managed instance lists none, a login without the right to read sys.dm_server_services sees none (see Collection on the Summary), or the mssql_services collection has not run yet.'));
  return sec;
}

// fleetPivot: sys.configurations across the fleet, an instance a row and an option a column (DBA Dash's
// Configuration grid). The odd value out (not the one most instances run) is amber and says so in its title and
// with a '*'; only the options whose values differ are columns unless every option is asked for.
function fleetPivot(rows: Row[], here: number): HTMLElement[] {
  if (!rows.length) return [el('p', { class: 'empty' }, 'No SQL Server instance has been read yet.')];
  const insts = [...new Map(rows.map(r => [Number(r.instance_id), String(r.instance)])).entries()].sort((a, b) => a[1].localeCompare(b[1]));
  const byKey = new Map(rows.map(r => [`${String(r.instance_id)}|${String(r.name)}`, r]));
  const all = [...new Set(rows.map(r => String(r.name)))].sort();
  const differ = all.filter(n => rows.some(r => r.name === n && Number(r.distinct_values) > 1));
  const box = el('div');
  const draw = (showAll: boolean) => {
    const names = showAll ? all : differ;
    const cols: Col[] = [{ key: 'instance', fmt: (v, r) => Number(r.id) === here ? el('b', {}, String(v)) : String(v) },
      ...names.map(n => ({ key: n, num: true,
        cls: (_v: unknown, r: Row) => byKey.get(`${String(r.id)}|${n}`)?.is_odd ? 'status warn' : '',
        fmt: (v: unknown, r: Row) => { const x = byKey.get(`${String(r.id)}|${n}`); if (!x) return '(not listed)';
          return x.is_odd ? el('span', { title: `differs from the fleet: most instances run ${x.common_in_use ?? '(no single value: a tie)'}` }, `${fmtNum(v)} *`) : fmtNum(v); } }))];
    const data = insts.map(([id, name]) => Object.fromEntries([['id', id], ['instance', name], ...names.map(n => [n, byKey.get(`${id}|${n}`)?.value_in_use ?? null])]));
    box.replaceChildren(grid(data, cols, 'Every instance runs the same values.'));
  };
  const cb = el('input', { type: 'checkbox', id: 'cfg-pivot-all' });
  cb.addEventListener('change', () => draw(cb.checked));
  draw(false);
  return [el('p', { class: 'meta' }, `${insts.length} instance(s); ${differ.length} of ${all.length} options differ across them. A value marked * (amber) is not the one most instances run; where two values tie, every value is marked.`),
    el('label', { for: 'cfg-pivot-all' }, cb, ' Show every option'), box];
}
