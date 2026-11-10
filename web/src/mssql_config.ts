// The Configuration tab of a SQL Server instance: the values that changed between two reads on top, then every value
// of sys.configurations (a value set and not yet in use is marked: it waits for RECONFIGURE or a restart), then the
// services the server lists. Data from /api/mssql/config (mssql_instance, read hourly; mssql_services, every 5 minutes).
import { get, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid } from './ui';

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
  sec.append(el('p', { class: 'meta counts' }, `${values.filter(r => r.is_present !== false).length} values, read ${fmtTime(values[0].snapshot_at)}; `,
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
    { key: 'value', label: 'set', fmt: (v, r) => r.pending === true ? el('span', {}, num(v), ' ', badge('not in use yet', 'warn')) : num(v) },
    { key: 'minimum', fmt: num }, { key: 'maximum', fmt: num },
    { key: 'is_dynamic', label: 'dynamic', fmt: yn }, { key: 'is_advanced', label: 'advanced', fmt: yn },
    { key: 'is_present', label: 'listed', fmt: v => v === false ? 'no longer' : 'yes' },
  ];
  sec.append(el('h3', {}, 'Values'), grid(values, valueCols));
  const svcCols: Col[] = [
    { key: 'service_name', label: 'service' },
    { key: 'status', fmt: (v, r) => r.is_present === false ? 'no longer listed' : v === 'Running' ? String(v) : badge(String(v ?? ''), 'warn') },
    { key: 'startup_type', label: 'start mode' }, { key: 'service_account', label: 'account' },
    { key: 'last_startup_at', label: 'started', fmt: fmtTime },
    { key: 'ifi_enabled', label: 'instant file initialization', fmt: yn }, { key: 'is_clustered', label: 'clustered', fmt: yn },
  ];
  sec.append(el('h3', {}, 'Services'), grid(services, svcCols, 'The server lists no service (a managed instance), or the mssql_services collection has not run yet.'));
  return sec;
}
