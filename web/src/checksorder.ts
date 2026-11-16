// The Daily checks page's order and the post's numbers (B20-4), DOM-free (checksorder.test.mjs runs it in Node).
// worstFirst: the rows naming no instance first (a check that could not run), then each instance's rows together, the
// instances by critical count, then warning count, then name (and id, for two of one name); an instance's own rows
// keep the reader's order (critical first, then check and object). The mail draws the page, so it has this order too.
// dailyPost: what the mail's post says - every row's counts, the page's instance count, the worst three instances.

export interface CheckRow { severity?: unknown; instance?: unknown; instance_id?: unknown; [k: string]: unknown }
export interface DailyWorst { name: string; critical: number; warnings: number }
export interface DailyPost { instances: number; critical: number; warnings: number; worst: DailyWorst[] }

interface Group { id: number; name: string; critical: number; warnings: number; rows: CheckRow[] }

function groupsOf(rows: CheckRow[]): { none: CheckRow[]; groups: Group[] } {
  const none: CheckRow[] = [];
  const by = new Map<number, Group>();
  for (const r of rows) {
    if (r.instance_id == null) { none.push(r); continue; }
    const id = Number(r.instance_id);
    let g = by.get(id);
    if (!g) { g = { id, name: String(r.instance ?? ''), critical: 0, warnings: 0, rows: [] }; by.set(id, g); }
    if (r.severity === 'critical') g.critical++; else g.warnings++;
    g.rows.push(r);
  }
  const cmp = (a: string, b: string) => (a < b ? -1 : a > b ? 1 : 0);
  const groups = [...by.values()].sort((a, b) => b.critical - a.critical || b.warnings - a.warnings || cmp(a.name, b.name) || a.id - b.id);
  return { none, groups };
}

export function worstFirst<R extends CheckRow>(rows: R[]): R[] {
  const { none, groups } = groupsOf(rows);
  return [...none, ...groups.flatMap(g => g.rows)] as R[];
}

export function dailyPost(rows: CheckRow[], instances: number): DailyPost {
  const critical = rows.filter(r => r.severity === 'critical').length;
  return {
    instances, critical, warnings: rows.length - critical,
    worst: groupsOf(rows).groups.slice(0, 3).map(g => ({ name: g.name, critical: g.critical, warnings: g.warnings })),
  };
}
