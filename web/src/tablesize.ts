// The fleet Table size page (task 132; DBA Dash's Table Size at the root of the tree): the largest tables across the
// PostgreSQL instances with their growth over the page's range, the Top and order choices of DBA Dash's toolbar, and
// a line that says which instances have no table read in the range. PostgreSQL only: the repository holds no table
// sizes of a SQL Server instance, and the page says so. Data: /api/tablesize.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { href, rangeLabel, window_ } from './router';
import { tableLink } from './dbinfo';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtTime, grid } from './ui';

const tops = [20, 50, 100, 500];
const orders: [string, string][] = [['size', 'largest first'], ['growth', 'fastest growing first']];
const lsGet = (k: string) => { try { return localStorage.getItem(k); } catch { return null; } };
const lsSet = (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* private window */ } };

// a growth with its sign, so a table that shrank reads as one
const signed = (fmt: (v: unknown) => string) => (v: unknown) => v == null ? '' : (Number(v) > 0 ? '+' : '') + fmt(v);

// tableSizeView: the fleet's tables; keep narrows them to a tag folder's instances.
export async function tableSizeView(ctx: Ctx, keep?: (r: Row) => boolean): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Table size (${rangeLabel(ctx)})`));
  let top = Number(lsGet('pgvigil.tableSizeTop')); if (!tops.includes(top)) top = 100;
  let order = lsGet('pgvigil.tableSizeOrder') ?? 'size'; if (!orders.some(o => o[0] === order)) order = 'size';
  const topSel = el('select', { id: 'ts-top' }, ...tops.map(n => el('option', { value: String(n) }, `top ${n}`)));
  topSel.value = String(top);
  const orderSel = el('select', { id: 'ts-order' }, ...orders.map(([k, label]) => el('option', { value: k }, label)));
  orderSel.value = order;
  const body = el('div');
  let seq = 0;
  async function draw() {
    const mine = ++seq, wantTop = top;
    let d: { tables: Table | null; meta: Table | null };
    // under a tag folder the fleet's largest are read wide and cut here, so the folder still gets its own top rows
    try { d = await get<{ tables: Table | null; meta: Table | null }>('tablesize', { ...window_(ctx), top: keep ? 500 : wantTop, order }); }
    catch (e) { if (mine === seq) body.replaceChildren(errorBox(e)); return; }
    if (mine !== seq) return;
    let rows = rowsOf(d.tables);
    if (keep) rows = rows.filter(keep).slice(0, wantTop);
    const m = rowsOf(d.meta)[0] ?? {};
    const pg = Number(m.pg_instances ?? 0), read = Number(m.instances_read ?? 0), ms = Number(m.mssql_instances ?? 0);
    const cols: Col[] = [
      { key: 'instance', fmt: (v, r) => el('a', { href: href(ctx, { tab: 'tables', instance: Number(r.instance_id), tag: undefined }) }, String(v ?? '')) },
      { key: 'datname', label: 'database' },
      { key: 'schema_name', label: 'schema' },
      { key: 'table_name', label: 'table', fmt: (v, r) => tableLink(ctx, String(v ?? ''), r.dbid, r.relid, Number(r.instance_id)) },
      { key: 'total_bytes', label: 'size', num: true, fmt: fmtBytes },
      { key: 'heap_bytes', label: 'heap', num: true, fmt: fmtBytes },
      { key: 'toast_bytes', label: 'TOAST', num: true, fmt: fmtBytes },
      { key: 'index_bytes', label: 'indexes', num: true, fmt: fmtBytes },
      { key: 'n_live_tup', label: 'rows (estimate)', num: true },
      { key: 'growth_bytes', label: 'growth', num: true, fmt: signed(fmtBytes) },
      { key: 'growth_rows', label: 'rows growth', num: true, fmt: signed(fmtNum) },
      { key: 'bytes_per_day', label: 'growth per day', num: true, fmt: signed(fmtBytes) },
      { key: 'rows_per_day', label: 'rows per day', num: true, fmt: signed(fmtNum) },
      { key: 'base_at', label: 'growth since', fmt: (v, r) => v == null ? 'one read only'
        : r.in_window === true ? el('span', { title: 'first read inside the range: the growth covers less than the range' }, fmtTime(v) + ' (inside the range)') : fmtTime(v) },
      { key: 'read_at', label: 'read', fmt: fmtTime },
    ];
    body.replaceChildren(
      read < pg ? el('p', { class: 'meta' }, badge(`No table read in this range on ${fmtNum(pg - read)} of ${fmtNum(pg)} PostgreSQL instance(s)`, 'warn'),
        ': the tables collection runs hourly; a shorter range than an hour can fall between two reads.') : '',
      el('p', { class: 'meta' }, `${fmtNum(rows.length)} table(s) of ${fmtNum(read)} PostgreSQL instance(s)`
        + (keep ? ' in this folder' : '') + `, each at its newest read of the range (the newest of all: ${fmtTime(m.newest_read) || 'none'}). `
        + 'Size: the table with its TOAST and indexes. Growth: against the read at the start of the range (a table or an instance first read inside it: from that read on). '
        + 'The repository holds the largest tables of each database (the tables collection\'s top N), so a smaller table is not here. '
        + (ms > 0 ? `PostgreSQL only: the ${fmtNum(ms)} SQL Server instance(s) are not covered (the repository holds no table sizes of a SQL Server instance; its Storage page has the database and file sizes).` : 'PostgreSQL only.')),
      grid(rows, cols, 'No table read in this range.'));
  }
  topSel.addEventListener('change', () => { top = Number(topSel.value); lsSet('pgvigil.tableSizeTop', String(top)); void draw(); });
  orderSel.addEventListener('change', () => { order = orderSel.value; lsSet('pgvigil.tableSizeOrder', order); void draw(); });
  sec.append(el('div', { class: 'toolbar' },
    el('label', { for: 'ts-top' }, 'Rows ', topSel), el('label', { for: 'ts-order' }, 'Order ', orderSel)), body);
  await draw();
  return sec;
}
