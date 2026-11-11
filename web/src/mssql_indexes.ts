// The Indexes tab of a SQL Server instance (task 150; sp_IndexCleanup's and sp_BlitzIndex's reads): per database the
// usage window and its guard (no index is called unused before seven days of counters), the indexes a rule names
// with the text a DBA would review (pgvigil runs none of it), the whole inventory, the optimizer's missing-index
// requests as hints (never as DDL), and the statistics' health. Data from /api/mssql/indexes; the route and the tab's
// entry are the shell's.
import { get, rowsOf, Table } from './api';
import { Ctx } from './router';
import { badge, Col, copyText, el, errorBox, fmtNum, fmtTime, grid } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlIndexesTab = 'mssqlindexes';

type Parts = Record<'state' | 'databases' | 'indexes' | 'verdicts' | 'missing' | 'statsdbs' | 'stats' | 'findings', Table | null>;
const sev = (v: unknown) => v ? badge(String(v), v === 'warning' ? 'warn' : 'info') : '';
const yes = (v: unknown) => v ? 'yes' : '';
// the review text: shown whole in a code block with a copy button; never run from here
const script = (v: unknown) => {
  const s = String(v ?? '');
  if (!s) return '';
  const b = el('button', { type: 'button', class: 'link', title: 'Copy the text to review it; pgvigil does not run it' }, 'copy');
  b.addEventListener('click', () => { void copyText(s).then(ok => { b.textContent = ok ? 'copied' : 'not copied'; }); });
  return el('span', { 'data-full': s }, el('code', { class: 'sql' }, s), ' ', b);
};

export async function mssqlIndexesView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Indexes and statistics'));
  sec.append(el('p', { class: 'meta' }, 'Source: each user database\'s catalog with sys.dm_db_index_usage_stats and sys.dm_db_partition_stats, and sys.dm_db_stats_properties, read every six hours. '
    + 'The usage counters begin again when the server starts and when a database is restored or created: no index is called unused before seven days of counters. '
    + 'The DISABLE and merge lines are text to review and test; pgvigil runs none of them. A disabled index comes back with ALTER INDEX ... REBUILD.'));
  const store = `pgvigil.mssql.indexes.db.${String(ctx.instance)}`;
  let database = (() => { try { return sessionStorage.getItem(store) ?? ''; } catch { return ''; } })();
  const sel = el('select', { 'aria-label': 'Database' }, el('option', { value: '' }, 'every database'));
  const body = el('div');
  let seq = 0;

  async function draw() {
    const mine = ++seq;
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    let d: Parts;
    try {
      d = await get<Parts>('mssql/indexes', { instance: ctx.instance, db: database || undefined });
    } catch (e) {
      if (mine === seq) body.replaceChildren(errorBox(e));
      return;
    }
    if (mine !== seq) return;
    const dbs = rowsOf(d.databases);
    const opts = dbs.filter(r => r.database_id != null).map(r => [String(r.database_id), String(r.database)] as [string, string]);
    if (database && !opts.some(o => o[0] === database)) opts.push([database, `database ${database} (not listed now)`]);
    sel.replaceChildren(el('option', { value: '' }, 'every database'), ...opts.map(([id, name]) => {
      const o = el('option', { value: id }, name);
      if (id === database) o.selected = true;
      return o;
    }));
    const out: (Node | string)[] = [];
    for (const st of rowsOf(d.state)) if (st.status !== 'ok') out.push(el('p', { class: 'meta' }, `The ${String(st.collection)} collection's last run: ${String(st.status)}${st.note ? ' (' + String(st.note) + ')' : ''}.`));
    if (!dbs.length) {
      out.push(el('p', { class: 'empty' }, 'Not read yet: the mssql_indexes collection runs every six hours and needs VIEW SERVER STATE, VIEW ANY DEFINITION and a way into each database (CONNECT ANY DATABASE).'));
      body.replaceChildren(...out);
      return;
    }
    const findings = rowsOf(d.findings);
    if (findings.length) out.push(el('h3', {}, 'Findings'), grid(findings, [
      { key: 'severity', fmt: sev }, { key: 'check_name', label: 'check' }, { key: 'object', label: 'database' }, { key: 'detail', wide: true }, { key: 'at', label: 'read', fmt: fmtTime }]));
    const shown = dbs.filter(r => !database || String(r.database_id) === database);
    out.push(el('h3', {}, 'Usage window'), grid(shown, [
      { key: 'database' },
      { key: 'usage_days', label: 'days of counters', num: true, cls: (_v, r) => r.judged ? 'ok' : 'warn' },
      { key: 'usage_reason', label: 'since' }, { key: 'usage_since', label: 'at', fmt: fmtTime },
      { key: 'guard', wide: true }, { key: 'indexes', num: true }, { key: 'note', wide: true }, { key: 'read_at', label: 'read', fmt: fmtTime }]));
    out.push(el('h3', {}, 'Indexes a rule names'), grid(rowsOf(d.verdicts), [
      { key: 'severity', fmt: sev }, { key: 'rule' }, { key: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
      { key: 'index_name', label: 'index' }, { key: 'keeper', label: 'kept instead' }, { key: 'size_mb', label: 'size (MB)', num: true },
      { key: 'reads', num: true }, { key: 'writes', num: true }, { key: 'detail', wide: true }, { key: 'script', label: 'to review (never run)', fmt: script, wide: true }],
      'No index is named by a rule.'));
    const missing = rowsOf(d.missing);
    out.push(el('h3', {}, 'Missing-index requests (hints)'),
      el('p', { class: 'meta' }, 'What the optimizer asked for, one query shape at a time, since the server started: it does not know the indexes that exist or the other requests. '
        + 'Read them beside the inventory; they are never an index to create as they stand.'),
      grid(missing, [
        { key: 'database' }, { key: 'table_ref', label: 'table' }, { key: 'equality_columns', label: 'equality' }, { key: 'inequality_columns', label: 'inequality' },
        { key: 'included_columns', label: 'included' }, { key: 'user_seeks', label: 'seeks', num: true }, { key: 'user_scans', label: 'scans', num: true },
        { key: 'avg_impact', label: 'impact %', num: true }, { key: 'benefit_per_day', label: 'benefit / day', num: true, cls: v => Number(v) >= 100000 ? 'warn' : '' },
        { key: 'last_request', label: 'last asked', fmt: fmtTime }], 'No missing-index request.'));
    out.push(el('h3', {}, 'Statistics'), grid(rowsOf(d.statsdbs), [
      { key: 'database' }, { key: 'statistics', num: true }, { key: 'statistics_with_props', label: 'with properties', num: true },
      { key: 'never_updated', label: 'never updated', num: true }, { key: 'oldest_update', label: 'oldest update', fmt: fmtTime },
      { key: 'avg_modified_pct', label: 'avg modified %', num: true }, { key: 'note', wide: true }, { key: 'read_at', label: 'read', fmt: fmtTime }]));
    out.push(el('h4', {}, 'Statistics with a flag'), grid(rowsOf(d.stats), [
      { key: 'severity', fmt: sev }, { key: 'flags' }, { key: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
      { key: 'stats_name', label: 'statistic' }, { key: 'columns' }, { key: 'last_updated', label: 'last updated', fmt: fmtTime },
      { key: 'row_count', label: 'rows', num: true }, { key: 'modifications', num: true }, { key: 'modified_pct', label: 'modified %', num: true },
      { key: 'sampled_pct', label: 'sampled %', num: true }, { key: 'persisted_sample_pct', label: 'persisted %', num: true }, { key: 'filter_definition', label: 'filter' }],
      'No statistic is flagged.'));
    const cols: Col[] = [
      { key: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' }, { key: 'index_name', label: 'index' },
      { key: 'index_type', label: 'type', fmt: v => String(v ?? '').toLowerCase() }, { key: 'rule', fmt: (v, r) => v ? badge(String(v), r.severity === 'warning' ? 'warn' : 'info') : '' },
      { key: 'keys' }, { key: 'includes' }, { key: 'filter_definition', label: 'filter' },
      { key: 'is_unique', label: 'unique', fmt: yes }, { key: 'is_primary_key', label: 'PK', fmt: yes }, { key: 'ignore_dup_key', label: 'IGNORE_DUP_KEY', fmt: yes },
      { key: 'size_mb', label: 'size (MB)', num: true }, { key: 'row_count', label: 'rows', num: true },
      { key: 'reads', num: true }, { key: 'writes', num: true }, { key: 'last_read', label: 'last read', fmt: fmtTime },
      { key: 'compression' }, { key: 'fill_factor', label: 'fill factor', num: true }, { key: 'definition', fmt: script, wide: true },
    ];
    const ix = rowsOf(d.indexes);
    out.push(el('h3', {}, `Inventory (${fmtNum(ix.length)}${ix.length >= 5000 ? ', the largest' : ''})`), grid(ix, cols));
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
