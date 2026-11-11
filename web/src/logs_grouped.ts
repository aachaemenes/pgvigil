// The Logs page's grouped view (parity3 task 126; pgBadger's Events tab, Most Frequent Errors/Events, and its Temp
// Files tab's largest files): the server log's events of one instance grouped by kind, level and message shape (a
// quoted name, a literal or a number as ...), the most frequent first, each with its count, first and last seen and
// the raw rows under it on a click; the events per level; and the largest single temporary files with their time,
// database and user. Data from /api/logs/groups and /api/logs/groups/rows (q_log_groups.go). The shell mounts
// logsGroupedView(ctx) (the lead's wiring: a 'grouped' sub-tab of Logs); the level filter lives in the panel.
import { get, Row, rowsOf, Table } from './api';
import { Ctx, rangeLabel, window_ } from './router';
import { badge, Col, el, errorBox, fmtBytes, fmtNum, fmtTime, grid, tile } from './ui';
import { sqlCell, whatIsThis } from './sqlview';

const levelKind = (v: unknown) => v === 'PANIC' || v === 'FATAL' ? 'crit' : v === 'ERROR' || v === 'WARNING' ? 'warn' : '';
const levelBadge = (v: unknown) => v == null ? badge('unknown', '') : badge(String(v), levelKind(v));
const levels = ['', 'PANIC', 'FATAL', 'ERROR', 'WARNING', 'LOG'];

// the kinds as the Logs page names them (pages.ts logKinds; repeated here so this view stands alone)
const kindLabel: Record<string, string> = {
  lock_wait: 'lock wait', deadlock: 'deadlock', auth_fail: 'failed login', corruption: 'corruption', error: 'error',
  connection_limit: 'connection limit', connection_lost: 'connection lost', timeout: 'timeout', canceled: 'cancellation',
  autovacuum_cancel: 'autovacuum cancelled', vacuum_skipped: 'vacuum skipped', wraparound: 'wraparound',
  checkpoint_frequent: 'frequent checkpoints', crash: 'crash', out_of_memory: 'out of memory', archive_failed: 'archiving failed',
  standby_conflict: 'standby conflict', serialization_failure: 'serialization failure',
};

const messageCell = (v: unknown, r: Row): string | Node => {
  if (v != null) return el('code', {}, String(v));
  return el('span', { class: 'meta' }, `(no message stored: ${kindLabel[String(r.kind)] ?? String(r.kind)} events read before the message was kept)`);
};

const rowCols: Col[] = [
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'level', fmt: levelBadge },
  { key: 'pid', num: true }, { key: 'datname', label: 'db' }, { key: 'usename', label: 'user' }, { key: 'client' },
  { key: 'duration_ms', label: 'ms', num: true },
  { key: 'detail', label: 'message and detail', wide: true },
  { key: 'statement', fmt: v => v == null ? '' : sqlCell(v) },
];

const tempCols: Col[] = [
  { key: 'size_bytes', label: 'size', num: true, fmt: fmtBytes },
  { key: 'at', label: 'when', fmt: fmtTime },
  { key: 'datname', label: 'database' }, { key: 'usename', label: 'user' }, { key: 'client' }, { key: 'pid', num: true },
  { key: 'statement', fmt: v => v == null ? el('span', { class: 'meta' }, '(the log line has no statement)') : sqlCell(v) },
  { key: 'path', wide: true },
];

export async function logsGroupedView(ctx: Ctx): Promise<HTMLElement> {
  if (!ctx.instance) return el('p', { class: 'empty' }, 'Pick an instance in the tree on the left.');
  const sec = el('section', {}, el('h2', {}, `Log events grouped (${rangeLabel(ctx)}) `, whatIsThis(
    'The events pgvigil\'s log readers stored, grouped by kind, level and message: a quoted name, a literal, a tuple id, an LSN and every '
    + 'number become ..., so "relation \\"a\\" does not exist" and "relation \\"b\\" does not exist" are one group (pgBadger\'s normalized events). '
    + 'An unquoted name stays. Slow statements, plans, checkpoint lines and temporary files are not grouped here: the Slow queries page, '
    + 'the IO page and the list below carry them. A LOG line no rule knows is not stored; every WARNING, ERROR, FATAL and PANIC is.', 'Grouped log events')));
  const body = el('div'), drill = el('div', { 'aria-live': 'polite' });
  let level = '', drawSeq = 0, drillSeq = 0;
  const win = window_(ctx);
  const base = () => ({ instance: ctx.instance, ...win, level: level || undefined });

  async function rows(g: Row) {
    const seq = ++drillSeq;
    drill.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    try {
      const d = await get<Record<'events' | 'meta', Table | null>>('logs/groups/rows', { ...base(), key: String(g.group_key) });
      if (seq !== drillSeq) return;
      const m = rowsOf(d.meta)[0] ?? {};
      const n = `${fmtNum(m.matched ?? 0)}${Number(m.matched) > Number(m.shown) ? ', the newest ' + fmtNum(m.shown) + ' listed' : ''}`;
      drill.replaceChildren(el('h4', {}, `Events: ${String(g.message ?? kindLabel[String(g.kind)] ?? g.kind)} (${n})`),
        grid(rowsOf(d.events), rowCols, 'No event of this group in the window.'));
    } catch (e) {
      if (seq === drillSeq) drill.replaceChildren(errorBox(e));
    }
  }

  const countBtn = (v: unknown, r: Row) => {
    const what = String(r.message ?? kindLabel[String(r.kind)] ?? r.kind);
    const b = el('button', { type: 'button', class: 'link', 'aria-label': `${fmtNum(v)} ${String(r.level ?? '')} events, ${what}: list them` }, fmtNum(v));
    b.addEventListener('click', () => { void rows(r); });
    return b;
  };

  // the level filter stays in place across redraws (a replaced select would drop the keyboard focus)
  const sel = el('select', { 'aria-label': 'Level' });
  for (const l of levels) sel.append(el('option', { value: l }, l || 'every level'));
  sel.addEventListener('change', () => { level = sel.value; void draw(); });
  const toolbar = el('div', { class: 'toolbar' }, el('label', {}, 'Level ', sel));

  async function draw() {
    const seq = ++drawSeq;
    drillSeq++;   // a group's rows still on the way belong to the list being replaced
    body.replaceChildren(el('p', { class: 'meta' }, 'Reading...'));
    drill.replaceChildren();
    try {
      const d = await get<Record<'groups' | 'totals' | 'levels' | 'temp_files' | 'temp_total', Table | null>>('logs/groups', base());
      if (seq !== drawSeq) return;
      const tot = rowsOf(d.totals)[0] ?? {}, tt = rowsOf(d.temp_total)[0] ?? {};
      const lv = rowsOf(d.levels);
      const cols: Col[] = [
        { key: 'events', label: 'times', num: true, fmt: countBtn },
        { key: 'level', fmt: levelBadge },
        { key: 'kind', fmt: v => kindLabel[String(v)] ?? String(v) },
        { key: 'message', fmt: messageCell },
        { key: 'first_at', label: 'first', fmt: fmtTime },
        { key: 'last_at', label: 'last', fmt: fmtTime },
        { key: 'databases', label: 'db' }, { key: 'users', label: 'user' },
      ];
      body.replaceChildren(
        el('div', { class: 'tiles' },
          tile('events', fmtNum(tot.events ?? 0)),
          tile('groups', fmtNum(tot.groups ?? 0)),
          tile('most in one group', fmtNum(tot.max_per_group ?? 0)),
          ...lv.map(r => tile(String(r.level), fmtNum(r.events), levelKind(r.level)))),
        grid(rowsOf(d.groups), cols, 'No log event in this window (the logs collection reads the server log where it is configured).'),
        drill,
        el('h3', {}, 'Largest temporary files ', whatIsThis('One row per temporary file the log recorded (log_temp_files: a file at or over it is logged when it is '
          + 'deleted; -1 logs none), the largest first. The statement is the log line\'s STATEMENT where the server wrote one.', 'Largest temporary files')),
        el('p', { class: 'meta' }, Number(tt.files) ? `${fmtNum(tt.files)} file(s) logged in this window, ${fmtBytes(tt.bytes)} in all; the largest ${fmtBytes(tt.largest)}.`
          : 'No temporary file logged in this window.'),
        grid(rowsOf(d.temp_files), tempCols, 'No temporary file logged in this window.'));
    } catch (e) {
      if (seq === drawSeq) body.replaceChildren(errorBox(e));
    }
  }
  sec.append(toolbar, body);
  void draw();
  return sec;
}
