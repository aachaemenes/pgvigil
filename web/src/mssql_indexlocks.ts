// The Index locks tab of a SQL Server instance (task 130; Darling's FinOps, Locking & Contention): where sessions
// waited for locks over the range, per index, from the differences of sys.dm_db_index_operational_stats between two
// reads five minutes apart: row and page lock waits with their time, and lock escalations. A database filter, the
// lock wait over time and one row per index. These are waits that ended on an index: where sessions collided, never
// who held the lock. Data from /api/mssql/indexlocks; the route and the tab's entry are the shell's.
import { get, rowsOf, Table } from './api';
import { lineChart } from './chart';
import { Ctx, href, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtNum, fmtSecs, fmtTime, grid, tile } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlIndexLocksTab = 'mssqlindexlocks';

type Parts = Record<'state' | 'reads' | 'databases' | 'totals' | 'indexes' | 'series', Table | null>;
const LIMIT = 2000;   // the grid's rows, as the API cuts them
const ms = (v: unknown) => v == null ? '' : fmtNum(v);
const msSecs = (v: unknown) => fmtSecs(Math.round(Number(v ?? 0) / 1000)) || '0s';

export async function mssqlIndexLocksView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, `Index locks (${rangeLabel(ctx)})`));
  sec.append(el('p', { class: 'meta' }, 'Source: sys.dm_db_index_operational_stats, read every five minutes; a figure is what was waited between two reads. '
    + 'A lock wait is counted on the index when it ends. This is where sessions collided, not why: the session that held the lock, '
    + 'its transaction and its last statement are on ',
    el('a', { href: href(ctx, { tab: 'mssql_running' }) }, 'Running queries'), ' and ', el('a', { href: href(ctx, { tab: 'mssql_blocked' }) }, 'Blocked reports'),
    '. An escalation is the server trading an index\'s row and page locks for one lock on the whole table. An attempt is one of the engine\'s checks '
    + 'as a statement\'s locks grow: attempts without an escalation are a statement that ended first, or a conflicting lock held by another session.'));
  // the filter is a database of THIS instance: remembered per instance, by the database's id
  const store = `pgvigil.mssql.indexlocks.db.${String(ctx.instance)}`;
  let database = (() => { try { return sessionStorage.getItem(store) ?? ''; } catch { return ''; } })();
  const sel = el('select', { 'aria-label': 'Database' }, el('option', { value: '' }, 'every database'));
  const body = el('div');
  let seq = 0;

  async function draw() {
    const mine = ++seq;
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    let d: Parts;
    try {
      d = await get<Parts>('mssql/indexlocks', { instance: ctx.instance, ...window_(ctx), db: database || undefined });
    } catch (e) {
      if (mine === seq) body.replaceChildren(errorBox(e));
      return;
    }
    if (mine !== seq) return;
    const rows = rowsOf(d.indexes), dbs = rowsOf(d.databases), reads = rowsOf(d.reads)[0], st = rowsOf(d.state)[0], tot = rowsOf(d.totals)[0] ?? {};
    const opts = dbs.map(r => [String(r.database_id), String(r.database)] as [string, string]);
    if (database && !opts.some(o => o[0] === database)) opts.push([database, `database ${database} (nothing in this range)`]);
    const picked = opts.find(o => o[0] === database)?.[1] ?? '';
    sel.replaceChildren(el('option', { value: '' }, 'every database'), ...opts.map(([id, name]) => {
      const o = el('option', { value: id }, name);
      if (id === database) o.selected = true;
      return o;
    }));
    const out: (Node | string)[] = [];
    if (st && st.status !== 'ok') out.push(el('p', { class: 'meta' }, `The mssql_indexlocks collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.`));
    const nReads = Number(reads?.reads ?? 0);
    if (nReads === 0) {
      out.push(el('p', { class: 'empty' }, 'No read took a difference in this range: the mssql_indexlocks collection runs every five minutes, needs VIEW SERVER STATE, and its first read only sets the starting counters.'));
      body.replaceChildren(...out);
      return;
    }
    const cut = rows.length >= LIMIT;
    // Darling's banner: the list is complete for what was read (and says so when the grid is cut)
    out.push(el('p', { class: 'meta counts' }, rows.length
      ? `Over the ${fmtNum(nReads)} reads of the range, ${fmtNum(tot.indexes)} index(es)${picked ? ' in ' + picked : ''} had a lock wait or an escalation attempt; `
        + (cut ? `the grid lists the ${fmtNum(LIMIT)} with the most lock wait.` : 'every one is listed.')
      : `No index${picked ? ' in ' + picked : ''} had a lock wait or an escalation attempt between the ${fmtNum(nReads)} reads of the range.`));
    if (rows.length === 0) { body.replaceChildren(...out); return; }
    // the tiles are the range's sums over every index, not only the rows the grid lists
    const esc = Number(tot.escalations ?? 0);
    out.push(el('div', { class: 'tiles' },
      tile('indexes with a lock wait or an escalation attempt', fmtNum(tot.indexes)),
      tile('row lock waits', fmtNum(tot.row_lock_waits)),
      tile('row lock wait time', msSecs(tot.row_lock_wait_ms)),
      tile('page lock waits', fmtNum(tot.page_lock_waits)),
      tile('page lock wait time', msSecs(tot.page_lock_wait_ms)),
      tile('escalation attempts', fmtNum(tot.escalation_attempts)),
      tile('lock escalations', fmtNum(esc))));
    out.push(el('div', { class: 'charts' },
      lineChart('Lock wait on indexes, ms per second', rowsOf(d.series), [{ key: 'row_lock_ms_s', label: 'row locks' }, { key: 'page_lock_ms_s', label: 'page locks' }])));
    const cols: Col[] = [
      { key: 'database' },
      { key: 'schema_name', label: 'schema' },
      { key: 'table_name', label: 'table' },
      { key: 'index_name', label: 'index' },
      { key: 'index_type', label: 'type', fmt: v => String(v ?? '').toLowerCase() },
      { key: 'row_lock_waits', label: 'row lock waits', num: true },
      { key: 'row_lock_wait_ms', label: 'row lock wait (ms)', num: true, fmt: ms },
      { key: 'avg_row_lock_wait_ms', label: 'avg row lock wait (ms)', num: true, fmt: ms },
      { key: 'page_lock_waits', label: 'page lock waits', num: true },
      { key: 'page_lock_wait_ms', label: 'page lock wait (ms)', num: true, fmt: ms },
      { key: 'avg_page_lock_wait_ms', label: 'avg page lock wait (ms)', num: true, fmt: ms },
      { key: 'escalation_attempts', label: 'escalation attempts', num: true },
      { key: 'escalations', num: true, fmt: v => Number(v) > 0 ? badge(fmtNum(v), 'warn') : '0' },
      { key: 'last_seen', label: 'last waited before', fmt: fmtTime },
    ];
    out.push(el('h3', {}, 'Indexes, the most lock wait first'),
      el('p', { class: 'meta' }, '"object <id>" and "index <id>": the names were not read (the login cannot enter the database, or the object is gone). '
        + 'The page latch counters of the same view are not collected: a latch is not a lock, and the Waits tab has PAGELATCH and PAGEIOLATCH.'),
      grid(rows, cols));
    body.replaceChildren(...out);
  }

  sel.addEventListener('change', () => {
    database = sel.value;
    try { sessionStorage.setItem(store, database); } catch { /* private window */ }
    void draw();
  });
  sec.append(el('div', { class: 'toolbar' }, el('label', {}, 'Database ', sel)), body);
  await draw();
  return sec;
}
