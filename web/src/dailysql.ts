// DAILY-SQL: the Daily checks rows of a SQL Server instance are the cells of its Summary (one reader: the cells
// /api/mssql/summary gives and fleet.ts cells() judges - the same level rule, the same words, the same landing, the same
// acknowledgement). DOM-free (dailysql.test.mjs runs it in Node); pages.ts checks() gives it the cells and draws.
// - cellRows: one row per cell at warning (level 1) or critical (level 2) - one row per cell however many jobs or
//   databases it counts (its detail names them) - except the groups left out: blocking (the Activity cell: the state
//   of one minute, not of a day; PostgreSQL's lock waits are a tile there, not a row) and Snapshot Age (its rows are the
//   overview's 'collection stale' already, for both engines). Collection Errors (24hrs) is a row at warning only - a
//   collection that failed in the last 24 hours and runs well now, a state no overview row holds; at critical its
//   collection is failing now, the overview's 'collection failing' row (review-28 code S6, the lead 11-16 20:01; it is
//   given for either engine's instance). A cell with no count (stale, read failed, not yet, n/a) adds no row.
// - failedRow / failedRows: the read of the cells failed - one row naming no instance, as the overview's own 'check could
//   not run', where the fleet holds a SQL Server instance (review-28 code S4: a PostgreSQL-only fleet loses nothing).
// - emptyWords: the open grid's words when it is empty - 'All checks pass' only when nothing is acknowledged either
//   (review-28 code S2).
// - readerOrder: the reader's order of the overview (web.go): critical first, then instance, check, object - so an
//   instance's own rows keep it under worstFirst (checksorder.ts).
// - splitAcked: the rows whose cell is acknowledged (ackOf says by whom and until when) apart from the open ones; the
//   open rows alone are counted (the tiles, the mail's counts, the post), as the Summary counts an acknowledged cell
//   under Acknowledged only.

export interface CellIn { key: string; label: string; level: number; none?: boolean; text: string; detail: string[]; at?: unknown }
export interface DailyRow {
  severity: string; instance: unknown; instance_id: unknown; check_name: unknown; object: unknown; at: unknown; detail: unknown;
  check_group?: unknown; cell?: string; [k: string]: unknown;
}

export const leftOut = new Set(['activity', 'snapshot']);

export function cellRows(inst: { id: number; name: string }, cells: CellIn[]): DailyRow[] {
  return cells.filter(c => !c.none && (c.level === 1 || c.level === 2) && !leftOut.has(c.key) && !(c.key === 'errors' && c.level !== 1)).map(c => ({
    severity: c.level === 2 ? 'critical' : 'warning', instance: inst.name, instance_id: inst.id, check_name: c.label,
    object: c.text, at: c.at ?? null, detail: c.detail.slice(0, 12).join('; ') + (c.detail.length > 12 ? `; ... ${c.detail.length - 12} more` : ''),
    check_group: 'summary cell', cell: c.key,
  }));
}

export const failedRow = (why: string): DailyRow => ({
  severity: 'critical', instance: '', instance_id: null, check_name: 'check could not run', object: 'SQL Server status cells',
  at: new Date().toISOString(), detail: `GET /api/mssql/summary failed (${why}): the SQL Server instances' Summary cells are not among these rows`,
  check_group: 'summary cell',
});

export const failedRows = (failed: boolean, fleetEngines: unknown[], why: string): DailyRow[] =>
  failed && fleetEngines.some(e => e === 'sqlserver') ? [failedRow(why)] : [];

export const emptyWords = (acked: number): string => acked > 0 ? `No open check: ${acked} acknowledged, listed below.`
  : 'All checks pass: no failing or stale collections, replication problems, failed jobs, deadlocks or checksum failures, and no SQL Server status cell at warning or critical.';

const txt = (v: unknown) => String(v ?? '');
export function readerOrder<R extends DailyRow>(rows: R[]): R[] {
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  return [...rows].sort((a, b) => Number(b.severity === 'critical') - Number(a.severity === 'critical')
    || cmp(txt(a.instance), txt(b.instance)) || cmp(txt(a.check_name), txt(b.check_name)) || cmp(txt(a.object), txt(b.object)));
}

export function splitAcked<R extends DailyRow>(rows: R[], ackOf: (r: R) => string | null): { open: R[]; acked: (R & { acknowledged: string })[] } {
  const open: R[] = [], acked: (R & { acknowledged: string })[] = [];
  for (const r of rows) {
    const a = ackOf(r);
    if (a == null) open.push(r); else acked.push({ ...r, acknowledged: a });
  }
  return { open, acked };
}
