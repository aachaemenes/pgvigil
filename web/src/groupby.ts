// The Group By dialog's result (DBA Dash's GroupByDialog, task PGRID B10): the rows the grid's filters leave, grouped by
// one or more columns' words, with the row count, its share of all rows, and per column Count Distinct, Sum, Sum % (of
// the column's sum over every row), Avg, Min and Max - named as DBA Dash names them ('<column> | Sum'). DOM-free; the
// grid tools draw it and format each number in its unit (gridtools.ts show); its unit rows: groupby.test.mjs.

export type AggKind = 'distinct' | 'sum' | 'sumpct' | 'avg' | 'min' | 'max';
export const AGG_ORDER: AggKind[] = ['distinct', 'sum', 'sumpct', 'avg', 'min', 'max'];
export const AGG_NAMES: Record<AggKind, string> = { distinct: 'Count Distinct', sum: 'Sum', sumpct: 'Sum %', avg: 'Avg', min: 'Min', max: 'Max' };

// keys: the columns grouped by, in order; count: Include Count; pct: Count % of Total; aggs: per column, its aggregates
export interface GroupSpec { keys: string[]; count: boolean; pct: boolean; aggs: { col: string; kinds: AggKind[] }[] }
// a cell as the grid shows it: its words, and its number in its unit's base with that unit when it is one
export interface GCell { text: string; n?: number; kind?: string }
// a result cell: a number (pct: a percent figure), words (a Min / Max of words, or 'mixed units'), or none
export type GValue = { n: number; kind?: string; pct?: boolean } | { text: string } | null;
export interface Grouped { cols: string[]; rows: { key: string[]; vals: GValue[] }[] }

// groupBy: cols - the grid's column names; rows - its rows as shown, a cell per column. A key the grid does not have
// leaves no groups. The groups: the largest first, then by their keys column by column (the empty one first, numbers
// in numeric order).
export function groupBy(cols: string[], rows: GCell[][], spec: GroupSpec): Grouped {
  const keyAt = spec.keys.map(k => cols.indexOf(k));
  if (!keyAt.length || keyAt.some(j => j < 0)) return { cols: [], rows: [] };
  const aggs = spec.aggs.map(a => ({ name: a.col, j: cols.indexOf(a.col), kinds: AGG_ORDER.filter(k => a.kinds.includes(k)) })).filter(a => a.j >= 0 && a.kinds.length);
  const nums = (rs: GCell[][], j: number) => rs.map(r => r[j]).filter((x): x is GCell & { n: number } => !!x && typeof x.n === 'number' && Number.isFinite(x.n));
  const grand = new Map(aggs.map(a => [a.j, nums(rows, a.j).reduce((s, x) => s + x.n, 0)]));
  const groups = new Map<string, { key: string[]; rows: GCell[][] }>();
  for (const r of rows) {
    const key = keyAt.map(j => r[j]?.text ?? '');
    const id = JSON.stringify(key);
    let g = groups.get(id);
    if (!g) { g = { key, rows: [] }; groups.set(id, g); }
    g.rows.push(r);
  }
  const one = (rs: GCell[][], j: number, k: AggKind): GValue => {
    if (k === 'distinct') return { n: new Set(rs.map(r => r[j]?.text ?? '')).size };
    const xs = nums(rs, j);
    if (k === 'min' || k === 'max') {
      if (!xs.length) {   // a column of words (a time, a name): the least or the greatest of its words
        const ws = rs.map(r => r[j]?.text ?? '').filter(w => w !== '').sort((a, b) => a.localeCompare(b, undefined, { numeric: true }));
        return ws.length ? { text: k === 'min' ? ws[0] : ws[ws.length - 1] } : null;
      }
    }
    if (!xs.length) return null;
    const kinds = new Set(xs.map(x => x.kind));
    if (kinds.size > 1) return { text: 'mixed units' };
    const kind = xs[0].kind, sum = xs.reduce((s, x) => s + x.n, 0);
    const withKind = (v: number): GValue => kind === undefined ? { n: v } : { n: v, kind };
    if (k === 'sum') return withKind(sum);
    if (k === 'sumpct') { const all = grand.get(j) ?? 0; return all ? { n: sum / all * 100, pct: true } : null; }
    if (k === 'avg') return withKind(sum / xs.length);
    return withKind(k === 'min' ? Math.min(...xs.map(x => x.n)) : Math.max(...xs.map(x => x.n)));
  };
  const byKey = (a: string[], b: string[]) => { for (let i = 0; i < a.length; i++) { const c = a[i].localeCompare(b[i], undefined, { numeric: true }); if (c) return c; } return 0; };
  const out = [...groups.values()].sort((a, b) => b.rows.length - a.rows.length || byKey(a.key, b.key)).map(g => ({
    key: g.key,
    vals: [
      ...(spec.count ? [{ n: g.rows.length } as GValue] : []),
      ...(spec.pct ? [(rows.length ? { n: g.rows.length / rows.length * 100, pct: true } : null) as GValue] : []),
      ...aggs.flatMap(a => a.kinds.map(k => one(g.rows, a.j, k))),
    ],
  }));
  return {
    cols: [...spec.keys, ...(spec.count ? ['Count'] : []), ...(spec.pct ? ['Count %'] : []), ...aggs.flatMap(a => a.kinds.map(k => `${a.name} | ${AGG_NAMES[k]}`))],
    rows: out,
  };
}
