// The Indexes tab (task 41): per database the indexes that cost writes and give nothing back - invalid, duplicate,
// redundant and unused - each with its DROP line and the undo, shown as text (pgvigil runs neither); the index advisor
// on demand where pg_qualstats and HypoPG are installed (a hypothetical index tested in the planner, never a CREATE);
// and the fleet root, per server the counts and the bytes. Data from /api/indexes and POST /api/indexes/advise; the
// routes and the tree entry are the shell's.
import { indexLink } from './drill';
import type { Ctx } from './router';
import { get, post, Row, rowsOf, Table } from './api';
import { badge, Col, el, fmtBytes, fmtNum, fmtTime, grid, props, tile } from './ui';
import { whatIsThis } from './sqlview';
import { depthError } from './statements';

interface IndexesData { state: Table | null; databases: Table | null; indexes: Table | null; findings: Table | null }
interface InventoryData { inventory: Table | null; inventory_total: Table | null }
interface IndexesFleetData { fleet: Table | null; unused: Table | null; duplicates: Table | null }

interface AdvQuery { queryid: number; query?: string; cost_before?: number; cost_after?: number; gain_pct?: number; uses_index: boolean; note?: string }
interface AdvSuggestion { ddl: string; hypothetical_index?: string; estimated_bytes?: number; best_gain_pct?: number; queries: AdvQuery[]; note?: string }
interface AdvReport { database: string; at: string; skipped?: string; suggestions: AdvSuggestion[]; unoptimised: unknown[]; note: string; cut?: string }

const problemText: Record<string, string> = {
  invalid: 'Invalid: a failed CREATE INDEX CONCURRENTLY or REINDEX. Never read, still written on every change.',
  duplicate: 'Duplicate: exactly the columns, operator classes, expressions and predicate of another index. Only one is read.',
  redundant: 'Redundant: its columns lead another index on the same table, which serves the same lookups.',
  unused: 'Unused: no index scan since the usage counters started (see the databases above). Check replicas and rare jobs before dropping: each server counts only its own reads.',
};
const problemKind: Record<string, string> = { invalid: 'warn', duplicate: 'warn', redundant: '', unused: '' };

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');

const indexCols: Col[] = [
  { key: 'datname', label: 'database' },
  { key: 'schema_name', label: 'schema' },
  { key: 'table_name', label: 'table' },
  { key: 'index_name', label: 'index' },
  { key: 'index_bytes', label: 'size', num: true, fmt: fmtBytes },
  { key: 'table_bytes', label: 'table size', num: true, fmt: fmtBytes },
  { key: 'idx_scan', label: 'scans', num: true },
  { key: 'covered_by', label: 'covered by', fmt: (v, r) => v == null ? '' : String(v) + (r.supports_fk ? ' (may serve a foreign key)' : '') },
  { key: 'drop_sql', label: 'DO (not run by pgvigil)', wide: true },
  { key: 'undo_sql', label: 'UNDO (the definition)', wide: true },
  { key: 'first_seen', label: 'since', fmt: fmtTime },
];

// the inventory (0056, task 71): every index of the instance, one database at a time, a name filter, 500 rows at most
const kindText = (r: Row) => [r.is_primary ? 'primary key' : r.is_unique ? 'unique' : '', r.is_valid === false ? 'INVALID' : '', r.is_partition ? 'a partition\'s' : '']
  .filter(Boolean).join(', ');
const blankNum = (v: unknown) => v == null ? '' : fmtNum(v);
function inventoryCols(ctx?: Ctx): Col[] {
  return [
    { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
    { key: 'index_name', label: 'index', fmt: (v, r) => {
      const name = document.createTextNode(String(v ?? ''));
      if (!ctx) return name;
      const a = indexLink(ctx, '', r.dbid, r.indexrelid); a.append(name); return a;
    } },
    { key: 'access_method', label: 'type', fmt: (v, r) => { const k = kindText(r); return String(v ?? '') + (k ? ` (${k})` : ''); } },
    { key: 'columns', wide: true },
    { key: 'index_bytes', label: 'size', num: true, fmt: fmtBytes },
    { key: 'idx_scan', label: 'scans', num: true },
    { key: 'scans_7d', label: '7 d', num: true, fmt: blankNum },
    { key: 'scans_30d', label: '30 d', num: true, fmt: blankNum },
    { key: 'idx_tup_fetch', label: 'rows fetched', num: true },
    { key: 'last_idx_scan', label: 'last scan', fmt: v => v ? fmtTime(v) : '' },
    { key: 'problems', fmt: v => v ? badge(String(v), /invalid|duplicate/.test(String(v)) ? 'warn' : '') : '' },
  ];
}
// one database at a time: /api/indexes?instance=&db= returns that database's 2,000 largest indexes and its total
function inventorySection(instance: number, dbs: Row[], ctx?: Ctx): HTMLElement {
  const sec = el('div', {}, el('h3', {}, 'Inventory'),
    el('p', { class: 'meta' }, 'Every index the monitoring login can see, read hourly: its size, its scans since the counters started and over the '
      + 'last 7 and 30 days (one row per index and day; blank until the day rows are that old, or after a counter reset), the rows it returned '
      + 'and, on PostgreSQL 16 and later, its last scan. The largest first, one database at a time; a problem index is marked; every name opens the index page.'));
  if (dbs.length === 0) {
    sec.append(el('p', { class: 'empty' }, 'No inventory read yet: it comes with the hourly indexes collection.'));
    return sec;
  }
  const pick = el('select', { 'aria-label': 'database of the inventory' }, ...dbs.map(d => el('option', { value: String(d.dbid) }, String(d.datname)))) as HTMLSelectElement;
  const filter = el('input', { type: 'search', placeholder: 'table or index name', 'aria-label': 'filter the inventory by table or index name' }) as HTMLInputElement;
  const out = el('div');
  let rows: Row[] = [], total = 0;
  const draw = () => {
    const f = filter.value.trim().toLowerCase();
    const all = rows.filter(r => !f || String(r.table_name ?? '').toLowerCase().includes(f) || String(r.index_name ?? '').toLowerCase().includes(f));
    const shown = all.slice(0, 500);
    const note = shown.length < total ? `${shown.length} of ${total} indexes shown, the largest first${all.length > shown.length ? ': narrow the filter' : (rows.length < total ? ' (the 2,000 largest were read)' : '')}.` : `${total} indexes.`;
    out.replaceChildren(el('p', { class: 'meta' }, note), grid(shown, inventoryCols(ctx), 'No index matches.'));
  };
  const load = async () => {
    out.replaceChildren(el('p', { class: 'meta' }, 'Loading...'));
    try {
      const d = await get<InventoryData>('indexes', { instance, db: pick.value });
      rows = rowsOf(d.inventory); total = Number(rowsOf(d.inventory_total)[0]?.total ?? rows.length);
      draw();
    } catch (e) {
      out.replaceChildren(el('p', { class: 'error' }, 'Error: ' + (e instanceof Error ? e.message : String(e))));
    }
  };
  pick.addEventListener('change', () => { void load(); });
  filter.addEventListener('input', draw);
  sec.append(el('p', {}, 'Database ', pick, ' filter ', filter), out);
  void load();
  return sec;
}

// adviseBox: the advisor button for one database and its report.
function adviseBox(instance: number, dbs: string[]): HTMLElement {
  const pick = el('select', { 'aria-label': 'database to advise on' }, ...dbs.map(d => el('option', { value: d }, d)));
  const run = el('button', { type: 'button' }, 'Test the suggested indexes');
  const out = el('div');
  run.addEventListener('click', async () => {
    run.setAttribute('disabled', '');
    out.replaceChildren(el('p', { class: 'meta' }, 'Planning... (EXPLAIN only: no statement is executed, no index is created)'));
    try {
      const rep = await post<AdvReport>('indexes/advise', { instance_id: instance, database: (pick as HTMLSelectElement).value });
      out.replaceChildren(adviceView(rep));
    } catch (e) {
      out.replaceChildren(el('p', { class: 'error' }, 'Error: ' + (e instanceof Error ? e.message : String(e))));
    } finally {
      run.removeAttribute('disabled');
    }
  });
  return el('div', {}, el('h3', {}, 'Index advisor'),
    el('p', { class: 'meta' }, 'Where pg_qualstats and HypoPG are installed in the database: pg_qualstats proposes indexes from the '
      + 'predicates it sampled; each is created as a HYPOTHETICAL index in the advisor\'s own session (HypoPG: the planner sees it, '
      + 'nothing is written), the statements that would use it are planned with EXPLAIN (not executed) before and after, and the cost difference is the gain. '
      + 'No index is created: a suggestion is for a person to review. EXPLAIN needs SELECT on the tables (pg_read_all_data or a grant).'),
    el('p', {}, 'Database ', pick, ' ', run), out);
}

export function adviceView(rep: AdvReport): HTMLElement {
  if (rep.skipped) return el('p', { class: 'empty' }, `Not run in ${rep.database}: ${rep.skipped}.`);
  const box = el('div', {}, el('p', { class: 'meta' }, `${rep.database}, ${fmtTime(rep.at)}: ${rep.note}.`));
  if (rep.cut) box.append(el('p', { class: 'error' }, `Stopped early: ${rep.cut}.`));
  if (rep.suggestions.length === 0) {
    box.append(el('p', { class: 'empty' }, 'pg_qualstats proposes no index: no sampled predicate filters enough rows often enough.'));
  }
  for (const s of rep.suggestions) {
    box.append(el('h4', {}, el('code', {}, s.ddl)),
      props([
        ['best gain', s.best_gain_pct == null ? 'not used by any tested statement' : fmtNum(Math.round(s.best_gain_pct)) + ' % lower plan cost'],
        ['estimated size', s.estimated_bytes == null ? '' : fmtBytes(s.estimated_bytes)],
        ['hypothetical name', s.hypothetical_index ?? ''],
        ...(s.note ? [['note', s.note] as [string, string]] : []),
      ]),
      grid(s.queries as unknown as Row[], [
        { key: 'queryid', label: 'query id' },
        { key: 'cost_before', label: 'cost before', num: true },
        { key: 'cost_after', label: 'cost with the index', num: true },
        { key: 'gain_pct', label: 'gain', num: true, fmt: v => v == null ? '' : fmtNum(Math.round(Number(v))) + ' %' },
        { key: 'uses_index', label: 'plan uses it', fmt: v => v ? badge('yes', 'ok') : 'no' },
        { key: 'note', wide: true },
        { key: 'query', wide: true },
      ], 'No statement to test.'));
  }
  return box;
}

// ---- btree bloat, sequences and the catalog checks (task 155, GET /api/pgdepth) --------------------------------

const pctTxt = (v: unknown) => v == null ? '' : fmtNum(v) + ' %';

const bloatCols: Col[] = [
  { key: 'datname', label: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'table_name', label: 'table' },
  { key: 'index_name', label: 'index' },
  { key: 'index_bytes', label: 'size', num: true, fmt: fmtBytes },
  { key: 'est_bytes', label: 'its rows need', num: true, fmt: fmtBytes },
  { key: 'bloat_bytes', label: 'bloat', num: true, fmt: fmtBytes },
  { key: 'bloat_pct', label: 'bloat share', num: true, fmt: pctTxt, cls: v => Number(v) >= 50 ? 'warn' : '' },
  { key: 'fillfactor', num: true }, { key: 'tuples', label: 'rows', num: true, fmt: fmtNum },
  { key: 'est_note', label: 'not estimated', wide: true },
  { key: 'reindex_sql', label: 'rebuild (run it yourself)', wide: true },
];

const seqCols: Col[] = [
  { key: 'datname', label: 'database' }, { key: 'schema_name', label: 'schema' }, { key: 'seq_name', label: 'sequence' },
  { key: 'data_type', label: 'type' },
  { key: 'last_value', label: 'last value', num: true, fmt: fmtNum },
  { key: 'max_value', label: 'its maximum', num: true, fmt: fmtNum },
  { key: 'col_table', label: 'feeds', fmt: (v, r) => v == null ? '' : `${String(v)}.${String(r.col_name ?? '')} (${String(r.col_type ?? '')})` },
  { key: 'pct_used', label: 'used', num: true, fmt: pctTxt, cls: v => Number(v) >= 98 ? 'crit' : Number(v) >= 90 ? 'warn' : '' },
  { key: 'readable', label: 'readable', fmt: v => v === false ? badge('no: the login may not read it', 'warn') : '' },
  { key: 'blks_read', label: 'blocks read', num: true, fmt: fmtNum }, { key: 'blks_hit', label: 'blocks hit', num: true, fmt: fmtNum },
];

const checkKind: Record<string, string> = {
  secdef: 'SECURITY DEFINER without search_path', notvalid: 'NOT VALID constraint', defpart: 'rows in a DEFAULT partition',
  public_create: 'CREATE on schema public', md5: 'MD5 password',
};

const checkCols: Col[] = [
  { key: 'check_kind', label: 'check', fmt: v => checkKind[String(v)] ?? String(v ?? '') },
  { key: 'datname', label: 'database' }, { key: 'object' }, { key: 'detail', wide: true },
  { key: 'fix_sql', label: 'the fix (run it yourself)', wide: true },
];

// depthSections: the btree bloat estimates, every sequence's headroom and the catalog checks of the dbchecks collection,
// with the PostgreSQL depth findings of the instance on top. Each part reads on its own; a failure shows in its place.
async function depthSections(instance: number): Promise<HTMLElement[]> {
  const read = (part: string) => get<Record<string, Table>>('pgdepth', { instance, part, limit: 500 });
  const [f, b, q, k] = await Promise.allSettled([read('findings'), read('bloat'), read('sequences'), read('checks')]);
  const rows = (r: PromiseSettledResult<Record<string, Table>>, what: string, show: (t: Row[]) => HTMLElement): HTMLElement =>
    r.status === 'fulfilled' ? show(rowsOf(r.value.rows)) : depthError(what, r.reason);
  return [
    el('h3', {}, 'PostgreSQL depth findings ', whatIsThis('The findings of the PostgreSQL depth reads (migration 0095): checkpoints, '
      + 'the archive backlog, the timeline, connections, standbys, the SLRU caches, sequences, the catalog checks and '
      + 'btree bloat. Each names the line that fixes it; pgvigil runs none of them.', 'PostgreSQL depth findings')),
    rows(f, 'The depth findings', t => grid(t, [
      { key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'finding' }, { key: 'value', label: 'object' },
      { key: 'suggested', wide: true }, { key: 'detail', wide: true },
    ], 'No PostgreSQL depth finding.')),
    el('h3', {}, 'Btree bloat ', whatIsThis('An estimate from the catalog, every hour, for each valid btree index of 10 MB or more: '
      + 'the pages its rows would fill at its fillfactor against the pages it has. A variable-width column needs the table\'s '
      + 'statistics and the login\'s right to read them (pg_read_all_data from 14), else the row says why it is not estimated. '
      + 'Deduplication (13+) is not modelled: an index of many equal keys reads as less bloated than it is, never as more. '
      + 'REINDEX INDEX CONCURRENTLY (12+) rebuilds it without blocking writes; run it alone, outside a transaction.', 'Btree bloat')),
    rows(b, 'The bloat estimates', t => grid(t, bloatCols, 'No btree index of 10 MB or more read yet (the index_bloat collection runs hourly).')),
    el('h3', {}, 'Sequences ', whatIsThis('Every sequence the dbchecks collection read (hourly), the fullest first: its last value against the '
      + 'smaller of its own maximum and the maximum of the column it feeds - a bigint sequence behind an integer column runs out '
      + 'at 2,147,483,647. Reading a sequence\'s value needs SELECT or USAGE on it (pg_read_all_data from 14).', 'Sequences')),
    rows(q, 'The sequences', t => grid(t, seqCols, 'No sequence read yet (the dbchecks collection runs hourly).')),
    el('h3', {}, 'Catalog checks'),
    rows(k, 'The catalog checks', t => grid(t, checkCols, 'No SECURITY DEFINER function without search_path, NOT VALID constraint, filled DEFAULT partition, CREATE on public or MD5 password.')),
  ];
}

// indexesView: one instance's Indexes tab.
export async function indexesView(instance: number, ctx?: Ctx): Promise<HTMLElement> {
  const depth = depthSections(instance);
  const d = await get<IndexesData>('indexes', { instance });
  const dbs = rowsOf(d.databases), idx = rowsOf(d.indexes), st = rowsOf(d.state)[0];
  const sec = el('section', {}, el('h2', {}, 'Indexes'));
  if (dbs.length === 0) {
    sec.append(el('p', { class: 'empty' }, st?.status === 'error' ? `The indexes collection failed: ${String(st.note ?? '')}.`
      : 'No indexes read yet: the indexes collection runs hourly, on every database the monitoring login can connect to.'));
    return sec;
  }
  const count = (p: string) => idx.filter(r => r.problem === p).length;
  const waste = idx.filter(r => r.problem !== 'unused').reduce((a, r) => a + Number(r.index_bytes ?? 0), 0);
  sec.append(el('div', { class: 'tiles' },
    tile('invalid', String(count('invalid')), count('invalid') ? 'warn' : 'ok'),
    tile('duplicate', String(count('duplicate')), count('duplicate') ? 'warn' : 'ok'),
    tile('redundant', String(count('redundant'))),
    tile('unused', String(count('unused'))),
    tile('invalid, duplicate and redundant size', fmtBytes(waste) || '0 B')));
  sec.append(el('h3', {}, 'Databases'), grid(dbs, [
    { key: 'datname', label: 'database' }, { key: 'indexes', num: true }, { key: 'index_bytes', label: 'index size', num: true, fmt: fmtBytes },
    { key: 'stats_since', label: 'usage counted since', fmt: fmtTime },
    { key: 'is_replica', label: 'replica', fmt: v => v ? badge('replica: its own reads only', 'warn') : '' },
    { key: 'findings', num: true }, { key: 'snapshot_at', label: 'read', fmt: fmtTime },
  ]));
  const findings = rowsOf(d.findings);
  if (findings.length) {
    sec.append(el('h3', {}, 'Findings'), grid(findings, [
      { key: 'severity', fmt: sevBadge }, { key: 'setting', label: 'finding' }, { key: 'value', label: 'index' },
      { key: 'suggested' }, { key: 'detail', wide: true },
    ]));
  }
  for (const p of ['invalid', 'duplicate', 'redundant', 'unused']) {
    const rows = idx.filter(r => r.problem === p);
    sec.append(el('h3', {}, `${p[0].toUpperCase()}${p.slice(1)} (${rows.length})`),
      el('p', { class: 'meta' }, problemText[p]),
      grid(rows, indexCols.map(c => c.key !== 'index_name' ? c : { ...c, fmt: (v: unknown, r: Row) => {
        const name: Node = problemKind[p] ? badge(String(v ?? ''), problemKind[p]) : document.createTextNode(String(v ?? ''));
        if (!ctx) return name;
        const a = indexLink(ctx, '', r.dbid, r.indexrelid); a.append(name); return a;
      } }),
        `No ${p} index.`));
  }
  sec.append(inventorySection(instance, dbs, ctx));
  sec.append(...await depth);
  sec.append(el('p', { class: 'meta' }, 'The redundant and invalid reads are postgres_dba\'s (BSD-3, Nikolay Samokhvalov); the DO / UNDO lines are '
    + 'its i5 pattern. Run a DO line alone, outside a transaction, in a session where lock_timeout and statement_timeout are 0 '
    + '(DROP INDEX CONCURRENTLY waits for every older transaction). An unused index that covers a redundant or duplicate one is '
    + 'not listed as unused: drop one of a pair, never both.'));
  sec.append(adviseBox(instance, dbs.map(r => String(r.datname))));
  return sec;
}

// indexesFleetView: the fleet root, per server the counts and the bytes. keep narrows it to a tag folder; instLink makes
// the instance name a link to its Indexes tab.
export async function indexesFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  const d = await get<IndexesFleetData>('indexes', {});
  let rows = rowsOf(d.fleet), unused = rowsOf(d.unused), dups = rowsOf(d.duplicates);
  if (keep) { rows = rows.filter(keep); unused = unused.filter(keep); dups = dups.filter(keep); }
  const inst = (v: unknown, r: Row) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '');
  const sum = (k: string) => rows.reduce((a, r) => a + Number(r[k] ?? 0), 0);
  const warnNum = (v: unknown) => Number(v) > 0 ? badge(String(v), 'warn') : '0';
  return el('section', {}, el('h2', {}, 'Indexes'),
    el('div', { class: 'tiles' },
      tile('servers read', String(rows.length)),
      tile('invalid', String(sum('invalid')), sum('invalid') ? 'warn' : 'ok'),
      tile('duplicate', String(sum('duplicate')), sum('duplicate') ? 'warn' : 'ok'),
      tile('redundant', String(sum('redundant'))), tile('unused', String(sum('unused'))),
      tile('their size', fmtBytes(sum('bytes')) || '0 B')),
    el('p', { class: 'meta' }, 'Per server: the indexes that cost writes and give nothing back, read hourly on every database.'),
    grid(rows, [
      { key: 'instance', fmt: inst },
      { key: 'platform' },
      { key: 'inventory', label: 'indexes', num: true }, { key: 'inventory_bytes', label: 'their size', num: true, fmt: fmtBytes },
      { key: 'invalid', num: true, fmt: warnNum }, { key: 'duplicate', num: true, fmt: warnNum },
      { key: 'redundant', num: true }, { key: 'unused', num: true },
      { key: 'bytes', label: 'problem size', num: true, fmt: fmtBytes },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], 'No indexes read yet: the indexes collection runs hourly.'),
    el('h3', {}, `Largest indexes nobody reads (${unused.length})`),
    el('p', { class: 'meta' }, 'Across the fleet, from the inventory: no scan since the counters started, counted for 7 days at least, on a primary, '
      + 'not behind a constraint and not a partition\'s; the 50 largest. Each server counts only its own reads: check the replicas and rare jobs before dropping.'),
    grid(unused, [
      { key: 'instance', fmt: inst }, { key: 'datname', label: 'database' }, { key: 'schema_name', label: 'schema' },
      { key: 'table_name', label: 'table' }, { key: 'index_name', label: 'index' },
      { key: 'index_bytes', label: 'size', num: true, fmt: fmtBytes },
      { key: 'stats_since', label: 'usage counted since', fmt: fmtTime }, { key: 'index_def', label: 'definition', wide: true },
    ], 'No unread index of a week or more.'),
    el('h3', {}, `Duplicate indexes (${dups.length})`),
    el('p', { class: 'meta' }, 'Across the fleet: exactly the columns, operator classes, expressions and predicate of another index on the same table; the 50 largest.'),
    grid(dups, [
      { key: 'instance', fmt: inst }, { key: 'datname', label: 'database' }, { key: 'schema_name', label: 'schema' },
      { key: 'table_name', label: 'table' }, { key: 'index_name', label: 'index' },
      { key: 'index_bytes', label: 'size', num: true, fmt: fmtBytes }, { key: 'idx_scan', label: 'scans', num: true },
      { key: 'covered_by', label: 'duplicate of' },
    ], 'No duplicate index.'));
}
