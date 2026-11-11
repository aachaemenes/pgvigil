// The Properties tab of a SQL Server instance (task 130; DBA Dash's Info page): what the instance is, one row per
// property as the mssql_properties collection last read it (hourly): the server, its processors, its memory,
// tempdb's layout and the host; and under it every value that differed between two reads. A property the server
// did not give says 'not read' and why. Data from /api/mssql/properties; the route and the tab's entry are the shell's.
import { get, Row, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, el, fmtNum, fmtTime, grid, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlPropertiesTab = 'mssqlproperties';

type Parts = Record<'state' | 'properties' | 'changes', Table | null>;

// a whole number is written with the browser's grouping; any other value as it was read
const shown = (v: unknown): string => v == null || v === '' ? '' : /^\d+$/.test(String(v)) ? fmtNum(v) : String(v);

export async function mssqlPropertiesView(ctx: Ctx): Promise<HTMLElement> {
  const d = await get<Parts>('mssql/properties', { instance: ctx.instance });
  const props = rowsOf(d.properties), changes = rowsOf(d.changes), st = rowsOf(d.state)[0];
  const sec = el('section', {}, el('h2', {}, 'Properties'));
  const stateNote = st && st.status !== 'ok' ? ` The mssql_properties collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.` : '';
  if (props.length === 0) {
    sec.append(el('p', { class: 'empty' }, 'No read yet: the mssql_properties collection reads the instance every hour (the processor, memory and host rows need VIEW SERVER STATE).' + stateNote));
    return sec;
  }
  const by = new Map(props.map(r => [String(r.name), r] as [string, Row]));
  const val = (name: string) => shown(by.get(name)?.value) || 'not read';
  const lastRead = props.map(r => String(r.snapshot_at ?? '')).reduce((a, b) => b > a ? b : a, '');
  const unread = props.filter(r => r.value == null).length;
  sec.append(el('p', { class: 'meta counts' }, `${props.length} properties, read ${fmtTime(lastRead)}; `,
    unread ? el('span', { class: 'warn' }, `${unread} not read (each row says why)`) : 'every one read',
    changes.length >= 500 ? '; the newest 500 changes are listed.' : `; ${changes.length} change(s) logged.`, stateNote));
  const maxPct = by.get('max_memory_pct')?.value;
  const plan = String(by.get('power_plan')?.value ?? '');
  const fastPlan = plan === 'High performance' || plan === 'Ultimate Performance';
  const uneven = by.get('tempdb_even_size')?.value === 'no';
  sec.append(el('div', { class: 'tiles' },
    tile('logical CPUs', val('cpu_count')),
    tile('sockets x cores per socket', by.get('socket_count')?.value != null ? `${val('socket_count')} x ${val('cores_per_socket')}` : 'not read'),
    tile('physical memory (MB)', val('physical_memory_mb')),
    // a tile that marks something to look at says it in words too, never by its colour alone
    tile('max server memory, % of the machine', maxPct == null ? 'not read' : /^[\d.]+$/.test(String(maxPct)) ? `${String(maxPct)} %` : String(maxPct), maxPct === 'no limit' ? 'warn' : ''),
    tile('tempdb data files', val('tempdb_data_files') + (uneven ? ', not one size' : ''), uneven ? 'warn' : ''),
    tile('power plan', !plan ? 'not read' : fastPlan ? plan : `${plan} (not High performance)`, plan && !fastPlan ? 'warn' : '')));

  const cols: Col[] = [
    { key: 'grp', label: 'group' },
    { key: 'label', label: 'property' },
    { key: 'value', fmt: v => v == null ? el('span', { class: 'meta' }, 'not read') : shown(v) },
    { key: 'note', wide: true },
    { key: 'since', label: 'has this value since', fmt: (v, r) => r.value == null ? '' : fmtTime(v) },
  ];
  sec.append(grid(props, cols));
  sec.append(el('h3', {}, 'Changes'), el('p', { class: 'meta' },
    'A value that differed from the read before. The time is the read that saw it: the change happened within the hour before. '
    + 'The first read of a property sets it and logs nothing; tempdb\'s sizes move by themselves and are not logged.'),
    grid(changes, [
      { key: 'changed_at', label: 'seen changed', fmt: fmtTime },
      { key: 'label', label: 'property' },
      { key: 'old_value', label: 'was', fmt: v => v == null ? el('span', { class: 'meta' }, 'not read') : shown(v) },
      { key: 'new_value', label: 'now', fmt: v => badge(shown(v), 'info') },
    ], 'No value has changed between two reads.'));
  return sec;
}
