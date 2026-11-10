// The Indexes tab (task 41): per database the indexes that cost writes and give nothing back - invalid, duplicate,
// redundant and unused - each with its DROP line and the undo, shown as text (pgvigil runs neither); the index advisor
// on demand where pg_qualstats and HypoPG are installed (a hypothetical index tested in the planner, never a CREATE);
// and the fleet root, per server the counts and the bytes. Data from /api/indexes and POST /api/indexes/advise; the
// routes and the tree entry are the shell's.
import { get, post, Row, rowsOf, Table } from './api';
import { badge, Col, el, fmtBytes, fmtNum, fmtTime, grid, props, tile } from './ui';

interface IndexesData { state: Table | null; databases: Table | null; indexes: Table | null; findings: Table | null }

interface AdvQuery { queryid: number; query?: string; cost_before?: number; cost_after?: number; gain_pct?: number; uses_index: boolean; note?: string }
interface AdvSuggestion { ddl: string; hypothetical_index?: string; estimated_bytes?: number; best_gain_pct?: number; queries: AdvQuery[]; note?: string }
interface AdvReport { database: string; at: string; skipped?: string; suggestions: AdvSuggestion[]; unoptimised: unknown[]; note: string }

const problemText: Record<string, string> = {
  invalid: 'Invalid: a failed CREATE INDEX CONCURRENTLY or REINDEX. Never read, still written on every change.',
  duplicate: 'Duplicate: exactly the columns, operator classes, expressions and predicate of another index. Only one is read.',
  redundant: 'Redundant: its columns lead another index on the same table, which serves the same lookups.',
  unused: 'Unused: no index scan since the usage counters started (see the databases above). Check replicas and rare jobs before dropping: each server counts only its own reads.',
};
const problemKind: Record<string, string> = { invalid: 'warn', duplicate: 'warn', redundant: '', unused: '' };

const sevBadge = (v: unknown) => badge(String(v ?? ''), v === 'critical' ? 'crit' : v === 'warning' ? 'warn' : '');
const code = (v: unknown) => v == null ? '' : el('code', {}, String(v));

const indexCols: Col[] = [
  { key: 'datname', label: 'database' },
  { key: 'schema_name', label: 'schema' },
  { key: 'table_name', label: 'table' },
  { key: 'index_name', label: 'index' },
  { key: 'index_bytes', label: 'size', num: true, fmt: fmtBytes },
  { key: 'table_bytes', label: 'table size', num: true, fmt: fmtBytes },
  { key: 'idx_scan', label: 'scans', num: true },
  { key: 'covered_by', label: 'covered by', fmt: (v, r) => v == null ? '' : String(v) + (r.supports_fk ? ' (may serve a foreign key)' : '') },
  { key: 'index_def', label: 'definition', wide: true },
  { key: 'drop_sql', label: 'DO (not run by pgvigil)', fmt: code },
  { key: 'undo_sql', label: 'UNDO', fmt: code },
  { key: 'first_seen', label: 'since', fmt: fmtTime },
];

// adviseBox: the advisor button for one database and its report.
function adviseBox(instance: number, dbs: string[]): HTMLElement {
  const pick = el('select', {}, ...dbs.map(d => el('option', { value: d }, d)));
  const run = el('button', { type: 'button' }, 'Test the suggested indexes');
  const out = el('div');
  run.addEventListener('click', async () => {
    run.setAttribute('disabled', '');
    out.replaceChildren(el('p', { class: 'meta' }, 'Planning... (EXPLAIN only, nothing is executed or created)'));
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
      + 'nothing is written), the statements that would use it are EXPLAINed before and after, and the cost difference is the gain. '
      + 'No index is created: a suggestion is for a person to review. EXPLAIN needs SELECT on the tables (pg_read_all_data or a grant).'),
    el('p', {}, 'Database ', pick, ' ', run), out);
}

export function adviceView(rep: AdvReport): HTMLElement {
  if (rep.skipped) return el('p', { class: 'empty' }, `Not run in ${rep.database}: ${rep.skipped}.`);
  const box = el('div', {}, el('p', { class: 'meta' }, `${rep.database}, ${fmtTime(rep.at)}: ${rep.note}.`));
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

// indexesView: one instance's Indexes tab.
export async function indexesView(instance: number): Promise<HTMLElement> {
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
      grid(rows, indexCols.map(c => c.key === 'index_name' && problemKind[p] ? { ...c, fmt: (v: unknown) => badge(String(v ?? ''), problemKind[p]) } : c),
        `No ${p} index.`));
  }
  sec.append(el('p', { class: 'meta' }, 'The redundant and invalid reads are postgres_dba\'s (BSD-3, Nikolay Samokhvalov); the DO / UNDO lines are '
    + 'its i5 pattern. DROP INDEX CONCURRENTLY runs alone, outside a transaction, with lock_timeout and statement_timeout at 0.'));
  sec.append(adviseBox(instance, dbs.map(r => String(r.datname))));
  return sec;
}

// indexesFleetView: the fleet root, per server the counts and the bytes. keep narrows it to a tag folder; instLink makes
// the instance name a link to its Indexes tab.
export async function indexesFleetView(keep?: (r: Row) => boolean, instLink?: (name: string, id: unknown) => Node): Promise<HTMLElement> {
  let rows = rowsOf((await get<{ fleet: Table | null }>('indexes', {})).fleet);
  if (keep) rows = rows.filter(keep);
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
      { key: 'instance', fmt: (v, r) => instLink ? instLink(String(v), r.instance_id) : String(v ?? '') },
      { key: 'platform' },
      { key: 'invalid', num: true, fmt: warnNum }, { key: 'duplicate', num: true, fmt: warnNum },
      { key: 'redundant', num: true }, { key: 'unused', num: true },
      { key: 'bytes', label: 'size', num: true, fmt: fmtBytes },
      { key: 'snapshot_at', label: 'read', fmt: fmtTime },
    ], 'No indexes read yet: the indexes collection runs hourly.'));
}
