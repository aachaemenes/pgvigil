// The Indexes tab of a SQL Server instance (task 150; sp_IndexCleanup's and sp_BlitzIndex's reads): per database the
// usage window and its guard (no index is called unused before seven days of counters), the indexes a rule names
// with the text a DBA would review (pgvigil runs none of it), the whole inventory, the optimizer's missing-index
// requests as hints (never as DDL), and the statistics' health. Data from /api/mssql/indexes; the route and the tab's
// entry are the shell's.
// Task 414 (B23; /api/mssql/indexes/depth and the on-demand routes): what each read added to the usage counters and
// to the missing-index requests over the range (seeks, scans, lookups and updates apart), the top requests and their
// scatter, the untrusted keys and constraints, a statistic's histogram on demand (off unless an admin turns it on:
// it shows the column's real values) and a fragmentation read on demand (a job of serve's: off unless an admin turns
// it on, one at a time per instance, with Cancel).
// Darling slice 3, task D404 (sp_BlitzIndex 8.34's and sp_IndexCleanup 2.11's sources): the inventory says which rows are
// an indexed view's, names an index's partition scheme and column, and gives the table's create date; a Heaps block lists
// the heaps of user tables (size, rows, reads, writes, forwarded fetches, deletes); a database's row says which part of
// the read was not stored and why.
import { get, post, rowsOf, Row, Table } from './api';
import { lineChart, seriesColors } from './chart';
import { Ctx, window_ } from './router';
import { badge, Col, copyText, el, errorBox, fmtNum, fmtTime, grid, offControl } from './ui';

// The tab key of the page (the router's entry carries the same key).
export const mssqlIndexesTab = 'mssqlindexes';

type Parts = Record<'state' | 'databases' | 'indexes' | 'heaps' | 'verdicts' | 'missing' | 'statsdbs' | 'stats' | 'findings', Table | null>;
type Depth = Record<'state' | 'usage_series' | 'missing_series' | 'missing_top' | 'untrusted' | 'constraint_dbs' | 'fragmentation' | 'switches', Table | null>;
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
// a ratio of two counters, one decimal; '' when both are 0, 'no seek' / 'no read' when only the divisor is
const ratio = (a: unknown, b: unknown, none: string) => {
  const x = Number(a ?? 0), y = Number(b ?? 0);
  if (!x && !y) return '';
  return y ? (x / y).toFixed(1) : none;
};
// the index types with no histogram to draw (the server says the same: internal/mssql/stats.go noHistogramIndex)
const noHistogram = (t: unknown) => {
  const s = String(t ?? '').toUpperCase();
  if (s.includes('COLUMNSTORE')) return 'no histogram: a columnstore index keeps none of its own';
  if (s.includes('XML')) return 'no histogram: an XML index';
  if (s.includes('SPATIAL')) return 'no histogram: a spatial index';
  return '';
};
const q = (s: unknown) => '[' + String(s ?? '').replace(/]/g, ']]') + ']';
// the Heaps grid's empty words: 'no heap' only where every database shown had its heaps read (review S6)
const heapsEmpty = (dbs: Row[]) => {
  const unread = dbs.filter(r => !(Array.isArray(r.parts_read) && r.parts_read.includes('heaps'))).map(r => String(r.database));
  return unread.length ? `No heap stored. The heaps were not read in ${unread.length === dbs.length ? 'any database shown' : unread.join(', ')}: see the read notes above.`
    : 'No heap: every user table of the databases shown has a clustered index.';
};

export async function mssqlIndexesView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Indexes and statistics'));
  sec.append(el('p', { class: 'meta' }, 'Source: each user database\'s catalog with sys.dm_db_index_usage_stats and sys.dm_db_partition_stats, and sys.dm_db_stats_properties, read every six hours. '
    + 'The usage counters begin again when the server starts and when a database is restored or created: no index is called unused before seven days of counters. '
    + 'The DISABLE and merge lines are text to review and test; pgvigil runs none of them. A disabled index comes back with ALTER INDEX ... REBUILD.'));
  const store = `pgvigil.mssql.indexes.db.${String(ctx.instance)}`;
  let database = (() => { try { return sessionStorage.getItem(store) ?? ''; } catch { return ''; } })();
  const sel = el('select', { 'aria-label': 'Database' }, el('option', { value: '' }, 'every database'));
  const histBox = el('div');
  const body = el('div');
  let seq = 0;
  // one index's trend (a row's 'trend' link): object and index ids, and the words of the chart's heading
  let trend: { object: string; index: string; name: string } | null = null;

  async function draw() {
    const mine = ++seq;
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    const w = window_(ctx);
    let d: Parts;
    let dp: Depth | null = null, dpErr: unknown = null;
    try {
      [d, dp] = await Promise.all([
        get<Parts>('mssql/indexes', { instance: ctx.instance, db: database || undefined }),
        get<Depth>('mssql/indexes/depth', { instance: ctx.instance, db: database || undefined, from: w.from, to: w.to,
          object: trend?.object, index: trend?.index }).catch((e: unknown) => { dpErr = e; return null; }),
      ]);
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
    const dbName = (opts.find(o => o[0] === database) ?? ['', ''])[1];
    const sw = dp ? (rowsOf(dp.switches)[0] ?? {}) : {};
    const histOff = dp ? String(sw.histogram_off ?? '') : 'the on-demand reads were not answered';
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
      { key: 'guard', wide: true }, { key: 'indexes', num: true }, { key: 'note', wide: true },
      { key: 'parts_note', label: 'read notes', wide: true }, { key: 'read_at', label: 'read', fmt: fmtTime }]));
    if (dp) out.push(...usageOverTime(dp));
    else out.push(el('h3', {}, 'User actions over time'), errorBox(dpErr));
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
    if (dp) out.push(...missingOverTime(dp));
    if (dp) out.push(...untrusted(dp));
    const histBtn = (r: Row, statsKey: string, typeKey?: string) => {
      const none = typeKey ? noHistogram(r[typeKey]) : '';
      if (none) return none;
      const b = el('button', { type: 'button', class: 'link' }, 'histogram');
      b.addEventListener('click', () => { void showHistogram(String(r.database), String(r.schema_name), String(r.table_name), String(r[statsKey])); });
      return b;
    };
    out.push(el('h3', {}, 'Statistics'), grid(rowsOf(d.statsdbs), [
      { key: 'database' }, { key: 'statistics', num: true }, { key: 'statistics_with_props', label: 'with properties', num: true },
      { key: 'never_updated', label: 'never updated', num: true }, { key: 'oldest_update', label: 'oldest update', fmt: fmtTime },
      { key: 'avg_modified_pct', label: 'avg modified %', num: true }, { key: 'note', wide: true }, { key: 'read_at', label: 'read', fmt: fmtTime }]));
    const statCols: Col[] = [
      { key: 'severity', fmt: sev }, { key: 'flags' }, { key: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
      { key: 'stats_name', label: 'statistic' }, { key: 'columns' }, { key: 'last_updated', label: 'last updated', fmt: fmtTime },
      { key: 'row_count', label: 'rows', num: true }, { key: 'modifications', num: true }, { key: 'modified_pct', label: 'modified %', num: true },
      { key: 'sampled_pct', label: 'sampled %', num: true }, { key: 'persisted_sample_pct', label: 'persisted %', num: true }, { key: 'filter_definition', label: 'filter' }];
    if (!histOff) statCols.push({ key: 'stats_name', label: 'histogram', fmt: (_v, r) => histBtn(r, 'stats_name') });
    out.push(el('h4', {}, 'Statistics with a flag'));
    if (histOff) out.push(el('p', { class: 'meta' }, 'Histogram: ' + histOff + '.'));
    out.push(grid(rowsOf(d.stats), statCols, 'No statistic is flagged.'));
    if (dp) out.push(...fragmentation(dp, dbName));
    const cols: Col[] = [
      { key: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' }, { key: 'index_name', label: 'index' },
      { key: 'index_type', label: 'type', fmt: v => String(v ?? '').toLowerCase() },
      { key: 'object_type', label: 'view', fmt: v => v === 'V' ? 'indexed view' : '' },
      { key: 'data_space_name', label: 'partition scheme', fmt: (v, r) => r.data_space_type === 'PARTITION_SCHEME' ? `${String(v)}${r.partition_column ? ' (' + String(r.partition_column) + ')' : ''}` : '' },
      { key: 'rule', fmt: (v, r) => v ? badge(String(v), r.severity === 'warning' ? 'warn' : 'info') : '' },
      { key: 'is_disabled', label: 'disabled', fmt: v => v ? badge('disabled', 'warn') : '' },
      { key: 'keys' }, { key: 'includes' }, { key: 'filter_definition', label: 'filter' },
      { key: 'is_unique', label: 'unique', fmt: yes }, { key: 'is_primary_key', label: 'PK', fmt: yes }, { key: 'ignore_dup_key', label: 'IGNORE_DUP_KEY', fmt: yes },
      { key: 'size_mb', label: 'size (MB)', num: true }, { key: 'row_count', label: 'rows', num: true },
      { key: 'user_seeks', label: 'seeks', num: true }, { key: 'user_scans', label: 'scans', num: true }, { key: 'user_lookups', label: 'lookups', num: true },
      { key: 'writes', label: 'updates', num: true },
      { key: 'scans_per_seek', label: 'scans per seek', num: true, fmt: (_v, r) => ratio(r.user_scans, r.user_seeks, 'no seek') },
      { key: 'updates_per_read', label: 'updates per read', num: true, fmt: (_v, r) => ratio(r.writes, r.reads, 'no read') },
      { key: 'last_read', label: 'last read', fmt: fmtTime }, { key: 'table_created', label: 'table created', fmt: fmtTime },
      { key: 'compression' }, { key: 'fill_factor', label: 'fill factor', num: true }, { key: 'definition', fmt: script, wide: true },
      { key: 'index_id', label: 'trend', fmt: (_v, r) => {
        const b = el('button', { type: 'button', class: 'link' }, 'trend');
        b.addEventListener('click', () => { trend = { object: String(r.object_id), index: String(r.index_id), name: `${q(r.schema_name)}.${q(r.table_name)}.${q(r.index_name)}` }; void draw(); });
        return b;
      } },
    ];
    if (!histOff) cols.push({ key: 'index_name', label: 'histogram', fmt: (_v, r) => histBtn(r, 'index_name', 'index_type') });
    const ix = rowsOf(d.indexes);
    out.push(el('h3', {}, `Inventory (${fmtNum(ix.length)}${ix.length >= 5000 ? ', the largest' : ''})`));
    if (histOff) out.push(el('p', { class: 'meta' }, 'Histogram: ' + histOff + '.'));
    out.push(grid(ix, cols));
    const heaps = rowsOf(d.heaps);
    out.push(el('h3', {}, `Heaps (${fmtNum(heaps.length)}${heaps.length >= 5000 ? ', the largest' : ''})`),
      el('p', { class: 'meta' }, 'Tables with no clustered index. Reads and writes count since the usage window began; forwarded fetches and deletes come from '
        + 'sys.dm_db_index_operational_stats and count only since the table\'s metadata entered the server\'s cache, which can be later than the server\'s start.'),
      grid(heaps, [
        { key: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
        { key: 'size_mb', label: 'size (MB)', num: true }, { key: 'row_count', label: 'rows', num: true },
        { key: 'reads', num: true }, { key: 'writes', label: 'updates', num: true },
        { key: 'forwarded_fetch_count', label: 'forwarded fetches', num: true }, { key: 'leaf_delete_count', label: 'deletes', num: true },
        { key: 'data_space_name', label: 'partition scheme', fmt: (v, r) => r.data_space_type === 'PARTITION_SCHEME' ? `${String(v)}${r.partition_column ? ' (' + String(r.partition_column) + ')' : ''}` : '' },
        { key: 'compression' }, { key: 'last_read', label: 'last read', fmt: fmtTime }, { key: 'table_created', label: 'table created', fmt: fmtTime }],
        heapsEmpty(shown)));
    body.replaceChildren(...out);
  }

  // ---- what each read added: the usage counters, the missing-index requests ----
  function usageOverTime(dp: Depth): Node[] {
    const rows = rowsOf(dp.usage_series);
    const resets = rows.reduce((n, r) => n + Number(r.reset_rows ?? 0), 0);
    const head = el('h3', {}, 'User actions over time' + (trend ? ` (${trend.name})` : ''));
    const out: Node[] = [head];
    if (trend) {
      const b = el('button', { type: 'button', class: 'link' }, 'every index');
      b.addEventListener('click', () => { trend = null; void draw(); });
      head.append(' ', b);
    }
    out.push(el('p', { class: 'meta' }, 'What each six-hourly read of sys.dm_db_index_usage_stats added since the read before, seeks, scans, lookups and updates apart. '
      + 'An index read for the first time adds nothing (its counters start the line); an index that did not move keeps no row.'
      + (resets ? ` ${fmtNum(resets)} index row(s) began counting again in this range (a restart, a restore, the database taken offline or closed): those reads add the whole count.` : '')));
    out.push(lineChart('Seeks, scans, lookups and updates per read', rows,
      [{ key: 'seeks', label: 'seeks' }, { key: 'scans', label: 'scans' }, { key: 'lookups', label: 'lookups' }, { key: 'updates', label: 'updates' }],
      v => v.toLocaleString(), { bars: true }));
    return out;
  }

  function missingOverTime(dp: Depth): Node[] {
    const series = rowsOf(dp.missing_series);
    const top = rowsOf(dp.missing_top);
    const label = (r: Row) => `${String(r.table_ref ?? '')} (${[r.equality_columns, r.inequality_columns].filter(Boolean).map(String).join(' / ')})`;
    const idents = [...new Set(series.map(r => String(r.ident)))];
    const byAt = new Map<string, Row>();
    for (const r of series) {
      const k = String(r.snapshot_at);
      const row = byAt.get(k) ?? { snapshot_at: r.snapshot_at };
      row['i' + String(idents.indexOf(String(r.ident)))] = r.seeks_delta == null ? null : Number(r.seeks_delta) + Number(r.scans_delta ?? 0);
      byAt.set(k, row);
    }
    const rows = [...byAt.values()].sort((a, b) => String(a.snapshot_at).localeCompare(String(b.snapshot_at)));
    const names = idents.map(id => label(series.find(r => String(r.ident) === id) ?? {}));
    const out: Node[] = [el('h3', {}, 'Missing-index requests over time'),
      el('p', { class: 'meta' }, 'The ten requests with the most benefit in this range: the seeks and scans each read added. A request\'s identity is its table and columns (the server\'s handle changes at a restart).'),
      lineChart('Seeks and scans added per read', rows, idents.map((_, i) => ({ key: 'i' + String(i), label: names[i] })), v => v.toLocaleString(), { bars: true })];
    const ten = top.slice().sort((a, b) => Number(b.benefit ?? 0) - Number(a.benefit ?? 0)).slice(0, 10);
    out.push(el('h4', {}, 'Top 10 requests by benefit (the newest read)'), grid(ten, [
      { key: 'database' }, { key: 'table_ref', label: 'table' }, { key: 'equality_columns', label: 'equality' }, { key: 'inequality_columns', label: 'inequality' },
      { key: 'included_columns', label: 'included' }, { key: 'requests', label: 'seeks + scans', num: true }, { key: 'avg_impact', label: 'impact %', num: true },
      { key: 'benefit', num: true }], 'No missing-index request.'));
    if (top.length) out.push(scatter(top));
    return out;
  }

  // impact against seeks + scans for the newest read's requests (SQLWATCH PBI#13's scatter); the grid above is its twin
  function scatter(rows: Row[]): HTMLElement {
    const W = 600, H = 260, P = 40;
    const xs = rows.map(r => Math.log10(1 + Number(r.requests ?? 0))), ys = rows.map(r => Number(r.avg_impact ?? 0));
    const xMax = Math.max(1, ...xs);
    const ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('role', 'img'); svg.setAttribute('class', 'scatter');
    svg.setAttribute('aria-label', `Impact against seeks and scans for ${rows.length} missing-index request(s); the grid above lists the ten with the most benefit`);
    const color = seriesColors()[0] ?? 'currentColor';
    const line = (x1: number, y1: number, x2: number, y2: number) => { const l = document.createElementNS(ns, 'line'); for (const [k, v] of [['x1', x1], ['y1', y1], ['x2', x2], ['y2', y2]] as [string, number][]) l.setAttribute(k, String(v)); l.setAttribute('stroke', 'currentColor'); l.setAttribute('stroke-opacity', '0.4'); return l; };
    const text = (x: number, y: number, s: string, anchor = 'start') => { const t = document.createElementNS(ns, 'text'); t.setAttribute('x', String(x)); t.setAttribute('y', String(y)); t.setAttribute('font-size', '11'); t.setAttribute('fill', 'currentColor'); t.setAttribute('text-anchor', anchor); t.textContent = s; return t; };
    svg.append(line(P, H - P, W - 10, H - P), line(P, 10, P, H - P), text(W / 2, H - 8, 'seeks + scans (log scale)', 'middle'), text(4, 14, 'impact %'));
    rows.forEach((r, i) => {
      const c = document.createElementNS(ns, 'circle');
      c.setAttribute('cx', String(P + (W - P - 10) * xs[i] / xMax)); c.setAttribute('cy', String(H - P - (H - P - 10) * Math.min(100, ys[i]) / 100));
      c.setAttribute('r', '4'); c.setAttribute('fill', color); c.setAttribute('fill-opacity', '0.7');
      const t = document.createElementNS(ns, 'title'); t.textContent = `${String(r.table_ref ?? '')}: ${fmtNum(r.requests)} seeks + scans, impact ${String(r.avg_impact ?? '')} %`;
      c.append(t); svg.append(c);
    });
    return el('figure', { class: 'svg-figure' }, el('h4', {}, 'Impact against seeks and scans (the newest read)'), svg as unknown as HTMLElement);
  }

  function untrusted(dp: Depth): Node[] {
    const rows = rowsOf(dp.untrusted);
    const dbsRead = rowsOf(dp.constraint_dbs);
    const out: Node[] = [el('h3', {}, 'Untrusted keys and constraints'),
      el('p', { class: 'meta' }, 'Foreign keys and check constraints enabled again without WITH CHECK, or disabled: the rows written while they were off were never checked, and the optimizer does not use them. '
        + 'NOT FOR REPLICATION ones are left out, and disabled check constraints are counted, not named (dbachecks\' rules). The mssql_constraints collection reads them every six hours; '
        + 'WITH CHECK CHECK CONSTRAINT reads the whole table, so it is text to review.')];
    if (!dbsRead.length) { out.push(el('p', { class: 'empty' }, 'Not read yet: the mssql_constraints collection runs every six hours and needs VIEW ANY DEFINITION and a way into each database.')); return out; }
    out.push(grid(rows, [
      { key: 'database' }, { key: 'kind' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' }, { key: 'constraint_name', label: 'constraint' },
      { key: 'is_disabled', label: 'disabled', fmt: yes }, { key: 'ref_table', label: 'references', fmt: (v, r) => v ? `${q(r.ref_schema)}.${q(v)}` : '' },
      { key: 'read_at', label: 'read', fmt: fmtTime }, { key: 'script', label: 'to review (never run)', fmt: script, wide: true }], 'No untrusted foreign key or check constraint.'));
    const notes = dbsRead.filter(r => r.note);
    if (notes.length) out.push(grid(notes, [{ key: 'database' }, { key: 'note', wide: true }, { key: 'read_at', label: 'read', fmt: fmtTime }]));
    return out;
  }

  // ---- a statistic's histogram, on demand ----
  async function showHistogram(db: string, schema: string, table: string, stats: string) {
    const title = `Histogram of ${q(schema)}.${q(table)}.${q(stats)} in ${db}`;
    histBox.replaceChildren(el('h3', {}, title), el('p', { class: 'meta' }, 'Reading...'));
    histBox.scrollIntoView({ block: 'nearest' });
    let h: { state: string; words?: string; header?: Row; steps?: Row[]; login?: string; error?: string };
    try {
      h = await post('mssql/stats/histogram', { instance_id: ctx.instance, database: db, schema, table, stats });
    } catch (e) { histBox.replaceChildren(el('h3', {}, title), errorBox(e)); return; }
    const close = el('button', { type: 'button', class: 'link' }, 'close');
    close.addEventListener('click', () => histBox.replaceChildren());
    const head = el('h3', {}, title, ' ', close);
    if (h.state !== 'ok') { histBox.replaceChildren(head, el('p', { class: 'meta' }, String(h.words || h.error || h.state))); return; }
    const hd = h.header ?? {};
    const steps = h.steps ?? [];
    histBox.replaceChildren(head,
      el('p', { class: 'meta' }, `${fmtNum(hd.rows)} rows, ${fmtNum(hd.rows_sampled)} sampled, ${fmtNum(hd.steps)} steps, updated ${fmtTime(hd.last_updated)}; `
        + `read now through the ${h.login ?? 'read'} login, never stored. The keys are the column's real values.`),
      bars(steps), stepsTable(steps));
  }

  // the steps as a plain table, never a grid: a grid has Export Excel in its menu and the page's export takes every grid,
  // and a histogram's keys are the column's real values (task 414's FOLD: never an export)
  function stepsTable(steps: Row[]): HTMLElement {
    const cols: [string, string, boolean][] = [['step', 'step', true], ['range_high_key', 'RANGE_HI_KEY', false], ['key_type', 'type', false],
      ['equal_rows', 'EQ_ROWS', true], ['range_rows', 'RANGE_ROWS', true], ['distinct_range_rows', 'DISTINCT_RANGE_ROWS', true],
      ['average_range_rows', 'AVG_RANGE_ROWS', true]];
    return el('table', { class: 'steps', 'aria-label': 'The histogram\'s steps (not exported)' },
      el('thead', {}, el('tr', {}, ...cols.map(([, l]) => el('th', { scope: 'col' }, l)))),
      el('tbody', {}, ...steps.map(r => el('tr', {}, ...cols.map(([k, , num]) => el('td', num ? { class: 'num' } : {}, num ? fmtNum(r[k]) : String(r[k] ?? '')))))));
  }

  // the steps as bars: EQ_ROWS and RANGE_ROWS per step (the grid below is the twin)
  function bars(steps: Row[]): HTMLElement {
    const W = 600, H = 180, ns = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(ns, 'svg');
    svg.setAttribute('viewBox', `0 0 ${W} ${H}`); svg.setAttribute('role', 'img');
    svg.setAttribute('aria-label', `EQ_ROWS and RANGE_ROWS of ${steps.length} step(s); the grid below lists each step`);
    const max = Math.max(1, ...steps.map(s => Math.max(Number(s.equal_rows ?? 0), Number(s.range_rows ?? 0))));
    const bw = W / Math.max(1, steps.length);
    const [c1, c2] = [seriesColors()[0] ?? 'currentColor', seriesColors()[1] ?? 'currentColor'];
    steps.forEach((s, i) => {
      for (const [k, c, off] of [['range_rows', c2, 0], ['equal_rows', c1, 0.5]] as [string, string, number][]) {
        const v = Number(s[k] ?? 0), r = document.createElementNS(ns, 'rect');
        const h = (H - 10) * v / max;
        r.setAttribute('x', String(i * bw + off * bw)); r.setAttribute('width', String(Math.max(0.5, bw / 2 - 0.5)));
        r.setAttribute('y', String(H - h)); r.setAttribute('height', String(h)); r.setAttribute('fill', c);
        const t = document.createElementNS(ns, 'title'); t.textContent = `step ${String(s.step)}: ${k === 'equal_rows' ? 'EQ_ROWS' : 'RANGE_ROWS'} ${fmtNum(v)}`;
        r.append(t); svg.append(r);
      }
    });
    return el('figure', { class: 'svg-figure' }, el('p', { class: 'meta' }, 'Bars: RANGE_ROWS (left) and EQ_ROWS (right) of each step.'), svg as unknown as HTMLElement);
  }

  // ---- fragmentation, on demand: a job of serve's ----
  function fragmentation(dp: Depth, dbName: string): Node[] {
    const drawn = seq; // a later draw ends this one's pollers (it starts its own for a running read)
    const sw = rowsOf(dp.switches)[0] ?? {};
    const off = String(sw.fragmentation_off ?? '');
    const reads = rowsOf(dp.fragmentation);
    const box = el('div');
    const status = el('div');
    const out: Node[] = [el('h3', {}, 'Fragmentation (on demand)'),
      el('p', { class: 'meta' }, 'A read of sys.dm_db_index_physical_stats for one database, when asked, never on a schedule: it ' + String(sw.cost_words ?? '')
        + ' Indexes over 30 % fragmented and over 1,000 pages are marked; pgvigil offers no rebuild.')];
    const why = off || (dbName ? '' : 'choose a database above first');
    const lim = el('button', { type: 'button' }, 'Read LIMITED');
    const smp = el('button', { type: 'button' }, 'Read SAMPLED');
    const cost = el('button', { type: 'button' }, 'Show the heap size');
    const note = offControl(lim, why || null);
    offControl(smp, why || null, note);
    offControl(cost, (off.startsWith('off: a fragmentation read runs only') || !dbName) ? (why || null) : null, note);
    const costOut = el('span', { class: 'meta' });
    cost.addEventListener('click', () => {
      costOut.textContent = 'Reading...';
      post<Row>('mssql/indexes/fragmentation/cost', { instance_id: ctx.instance, database: dbName }).then(c => {
        costOut.textContent = c.state === 'ok' ? `${dbName}: heaps ${fmtNum(c.heap_mb)} MB (${fmtNum(c.heaps)} heap(s)), every index and heap ${fmtNum(c.all_mb)} MB.` : String(c.words ?? '');
      }).catch((e: unknown) => { costOut.textContent = String(e instanceof Error ? e.message : e); });
    });
    const start = (mode: string) => {
      status.replaceChildren(el('p', { class: 'meta' }, 'Starting...'));
      post<Row>('mssql/indexes/fragmentation', { instance_id: ctx.instance, database: dbName, mode }).then(r => {
        if (r.state === 'running') void follow(Number(r.read_id));
        else status.replaceChildren(el('p', { class: 'meta' }, String(r.words ?? r.state)));
      }).catch((e: unknown) => status.replaceChildren(errorBox(e)));
    };
    lim.addEventListener('click', () => start('LIMITED'));
    smp.addEventListener('click', () => start('SAMPLED'));
    out.push(el('div', { class: 'toolbar' }, lim, ' ', smp, ' ', cost, ' ', note, ' ', costOut), status, box);
    if (reads.length) out.push(el('h4', {}, 'The last reads'), grid(reads, [
      { key: 'database' }, { key: 'mode' }, { key: 'state', fmt: v => badge(String(v), v === 'done' ? 'ok' : v === 'running' ? 'info' : 'warn') },
      { key: 'ui_user', label: 'asked by' }, { key: 'started_at', label: 'started', fmt: fmtTime }, { key: 'ended_at', label: 'ended', fmt: fmtTime },
      { key: 'objects_read', label: 'rows read', num: true }, { key: 'rows_kept', label: 'kept', num: true }, { key: 'note', wide: true },
      { key: 'read_id', label: 'rows', fmt: (v, r) => { if (r.state === 'running') return ''; const b = el('button', { type: 'button', class: 'link' }, 'show'); b.addEventListener('click', () => { void follow(Number(v)); }); return b; } }]));
    const running = reads.find(r => r.state === 'running');
    if (running) void follow(Number(running.read_id));

    // follow: poll one read every 3 s while it runs (and this page is shown); then its rows
    async function follow(id: number) {
      let seen = false;
      for (let turn = 0; turn < 400; turn++) {
        if (drawn !== seq) return;
        if (sec.isConnected) seen = true; else if (seen) return;
        let f: { read: Table | null; rows: Table | null };
        try { f = await get('mssql/indexes/fragmentation', { instance: ctx.instance, id }); } catch (e) { status.replaceChildren(errorBox(e)); return; }
        const r = rowsOf(f.read)[0];
        if (!r) { status.replaceChildren(el('p', { class: 'meta' }, 'No such read.')); return; }
        if (r.state === 'running') {
          const cancel = el('button', { type: 'button' }, 'Cancel');
          cancel.addEventListener('click', () => {
            post<Row>('mssql/indexes/fragmentation/cancel', { instance_id: ctx.instance, read_id: id })
              .then(c => status.append(el('p', { class: 'meta' }, String(c.words ?? c.state)))).catch((e: unknown) => status.append(errorBox(e)));
          });
          status.replaceChildren(el('p', { class: 'meta' }, `Reading ${String(r.database)} (${String(r.mode)}), asked by ${String(r.ui_user)}: ${fmtNum(r.secs)} s so far, ${fmtNum(r.objects_read ?? 0)} rows read. `), cancel);
          await new Promise(res => setTimeout(res, 3000));
          continue;
        }
        status.replaceChildren(el('p', { class: 'meta' }, `${String(r.database)} (${String(r.mode)}): ${String(r.state)} after ${fmtNum(r.secs)} s, ${fmtNum(r.rows_kept ?? 0)} of ${fmtNum(r.objects_read ?? 0)} rows kept${r.note ? '; ' + String(r.note) : ''}.`));
        box.replaceChildren(grid(rowsOf(f.rows), [
          { key: 'marked', label: 'over 30 %', fmt: v => v ? badge('fragmented', 'warn') : '' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
          { key: 'index_name', label: 'index', fmt: v => v == null ? '(heap)' : String(v) }, { key: 'index_type', label: 'type' }, { key: 'partition_number', label: 'partition', num: true },
          { key: 'alloc_unit', label: 'allocation unit' }, { key: 'page_count', label: 'pages', num: true }, { key: 'fragment_pct', label: 'fragmentation %', num: true },
          { key: 'fragment_count', label: 'fragments', num: true }, { key: 'page_density', label: 'page density % (SAMPLED)', num: true },
          { key: 'record_count', label: 'records (SAMPLED)', num: true }, { key: 'forwarded', label: 'forwarded (SAMPLED)', num: true }], 'No index or heap of 1,000 pages or more.'));
        return;
      }
    }
    return out;
  }

  sel.addEventListener('change', () => {
    database = sel.value;
    trend = null;
    try { sessionStorage.setItem(store, database); } catch { /* private window */ }
    void draw();
  });
  sec.append(el('div', { class: 'toolbar' }, el('label', {}, 'Database ', sel)), histBox, body);
  await draw();
  return sec;
}
