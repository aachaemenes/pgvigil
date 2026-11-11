// New and dropped databases (task 127; DBA Dash's New Databases and Deleted Databases), both engines, newest first.
// PostgreSQL keeps no creation time: a new database is one the databases collection first saw after the instance's
// first read, created between that read and the one before. Data: /api/dbchanges (instance or the fleet).
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { href } from './router';
import { badge, Col, el, fmtBytes, fmtTime, grid } from './ui';

const dayChoices = [7, 30, 90, 365];

// dbChangesView: one instance's (ctx.instance) or the fleet's changes; keep narrows the fleet to a tag folder.
export async function dbChangesView(ctx: Ctx, keep?: (r: Row) => boolean): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'New and dropped databases'));
  let days = 30;
  try { const v = Number(localStorage.getItem('pgvigil.dbChangesDays')); if (dayChoices.includes(v)) days = v; } catch { /* private window */ }
  const sel = el('select', { 'aria-label': 'Days' }, ...dayChoices.map(d => el('option', { value: String(d) }, `last ${d} days`)));
  sel.value = String(days);
  const body = el('div');
  async function draw() {
    const d = await get<{ changes: Table | null }>('dbchanges', { instance: ctx.instance, days });
    let rows = rowsOf(d.changes);
    if (keep) rows = rows.filter(keep);
    const created = rows.filter(r => r.change === 'new'), dropped = rows.filter(r => r.change === 'dropped');
    const inst: Col[] = ctx.instance ? [] : [{ key: 'instance', fmt: (v, r) => el('a', { href: href(ctx, { tab: 'dbinfo', instance: Number(r.instance_id), tag: undefined }) }, String(v ?? '')) },
      { key: 'engine', fmt: v => v === 'sqlserver' ? 'SQL Server' : 'PostgreSQL' }];
    const gone = new Set(dropped.map(r => `${String(r.instance_id)}/${String(r.datname)}`));
    const newCols: Col[] = [...inst,
      { key: 'datname', label: 'database', fmt: (v, r) => gone.has(`${String(r.instance_id)}/${String(v)}`)
        ? el('span', {}, String(v ?? ''), ' ', badge('dropped since', 'warn')) : String(v ?? '') },
      { key: 'at', label: 'created', fmt: (_v, r) => r.created_at != null ? fmtTime(r.created_at)
        : el('span', { title: 'PostgreSQL keeps no creation time: created between these two reads' },
          `${r.created_after ? fmtTime(r.created_after) : 'before'} to ${fmtTime(r.first_seen)}`) },
      { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
      { key: 'owner' },
      { key: 'last_seen', label: 'last read', fmt: fmtTime },
    ];
    const dropCols: Col[] = [...inst,
      { key: 'datname', label: 'database' },
      { key: 'created_at', label: 'created', fmt: (v, r) => v != null ? fmtTime(v) : r.first_seen ? 'first read ' + fmtTime(r.first_seen) : '' },
      { key: 'at', label: 'dropped', fmt: (v, r) => el('span', { title: 'between the last read that listed it and the next read' },
        `${fmtTime(v)} to ${r.dropped_by ? fmtTime(r.dropped_by) : 'the next read'}`) },
      { key: 'size_bytes', label: 'last size', num: true, fmt: fmtBytes },
      { key: 'owner' },
    ];
    body.replaceChildren(
      el('p', { class: 'meta' }, `${created.length} created and ${dropped.length} dropped in the last ${days} days. `
        + 'SQL Server: the creation time is the server\'s own (sys.databases); PostgreSQL keeps none, so a new database shows '
        + 'the two hourly reads it was created between. Dropped: between the last read that listed it and the next; '
        + 'the size is its last read.'),
      el('h3', {}, 'New databases'), grid(created, newCols, `No database created in the last ${days} days.`),
      el('h3', {}, 'Dropped databases'), grid(dropped, dropCols, `No database dropped in the last ${days} days.`));
  }
  sel.addEventListener('change', () => {
    days = Number(sel.value);
    try { localStorage.setItem('pgvigil.dbChangesDays', String(days)); } catch { /* private window */ }
    void draw();
  });
  sec.append(el('div', { class: 'toolbar' }, sel), body);
  await draw();
  return sec;
}
