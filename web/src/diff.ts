// The Diff page (task 132; DBA Dash's Diff menu: Database Schema Diff and Agent Job Diff). Two sides, A and B, side by
// side for settings, jobs and schema objects, the differences only unless 'show identical rows' is ticked:
//   two instances            as each was last read (one engine on both sides)
//   one instance, two times  from the change histories the repository keeps (settings, job versions, schema changes)
//   two databases            of one instance: their schema objects as last read
// Settings and jobs compare on both engines; schema objects on PostgreSQL only (the repository holds none of a SQL
// Server instance), and the page says which sections it compared and how far back each store reaches. The picks ride
// in the hash (m, a, b, dba, dbb, ta, tb, all), so a diff is a link, and the last ones are kept in this browser.
// Data: /api/diff (part=databases: the databases behind the two pickers).
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { href, window_ } from './router';
import { fleet } from './fleet';
import { hashParam } from './dbinfo';
import { badge, Col, el, errorBox, fmtNum, fmtTime, grid } from './ui';

type Mode = 'i' | 't' | 'd';
interface Picks { m: Mode; a?: number; b?: number; dba?: string; dbb?: string; ta?: string; tb?: string; all: boolean }
const keys = ['m', 'a', 'b', 'dba', 'dbb', 'ta', 'tb', 'all'];
const modes: [Mode, string][] = [['i', 'Two instances'], ['t', 'One instance at two times'], ['d', 'Two databases of one instance']];
const lsKey = 'pgvigil.diff';
let focusResult = false;   // the Compare button asked for this render: the result takes the focus

const isoOrUndef = (v?: string) => v && !isNaN(Date.parse(v)) ? new Date(v).toISOString() : undefined;
function toLocalInput(iso?: string): string {
  if (!iso || isNaN(Date.parse(iso))) return '';
  const d = new Date(iso);
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}

// the picks of the hash; without any, the ones this browser used last; else two times from the page's range
function loadPicks(ctx: Ctx): Picks {
  const read = (g: (k: string) => string | undefined): Picks => ({
    m: (['i', 't', 'd'] as Mode[]).includes(g('m') as Mode) ? g('m') as Mode : 'i',
    a: Number(g('a')) || undefined, b: Number(g('b')) || undefined,
    dba: g('dba')?.slice(0, 128), dbb: g('dbb')?.slice(0, 128),
    ta: isoOrUndef(g('ta')), tb: isoOrUndef(g('tb')), all: g('all') === '1',
  });
  if (keys.some(k => hashParam(k) !== undefined)) return read(hashParam);
  let saved: Record<string, string> = {};
  try { saved = JSON.parse(localStorage.getItem(lsKey) ?? '{}') as Record<string, string>; } catch { /* private window, or not JSON */ }
  const p = read(k => typeof saved[k] === 'string' && saved[k] !== '' ? saved[k] : undefined);
  // a remembered pair of times is of another day's question: the two times start from the page's range
  const w = window_(ctx);
  p.ta = w.from; p.tb = ctx.range.preset ? undefined : w.to;
  return p;
}

function diffHref(ctx: Ctx, p: Picks): string {
  const base = href(ctx, { tab: 'diff', instance: undefined });
  const q = new URLSearchParams(base.split('?')[1] ?? '');
  for (const k of keys) q.delete(k);
  q.set('m', p.m);
  if (p.a) q.set('a', String(p.a));
  if (p.m === 'i' && p.b) q.set('b', String(p.b));
  if (p.dba) q.set('dba', p.dba);
  if (p.m !== 't' && p.dbb) q.set('dbb', p.dbb);
  if (p.m === 't' && p.ta) q.set('ta', p.ta);
  if (p.m === 't' && p.tb) q.set('tb', p.tb);
  if (p.all) q.set('all', '1');
  return `#/diff?${q}`;
}

// complete: the picks are enough for a diff; the reason when they are not
function incomplete(p: Picks): string {
  if (!p.a) return 'Pick instance A.';
  if (p.m === 'i') {
    if (!p.b) return 'Pick instance B.';
    if (p.b === p.a) return 'A and B are the same instance: pick another B, or compare it at two times.';
    if (!p.dba !== !p.dbb) return 'Pick a database on both sides, or on neither (the databases are then paired by name).';
  }
  if (p.m === 't') {
    if (!p.ta) return 'Pick the earlier time (A).';
    if (Date.parse(p.ta) >= (p.tb ? Date.parse(p.tb) : Date.now())) return 'The earlier time (A) must be before the later one (B).';
  }
  if (p.m === 'd') {
    if (!p.dba || !p.dbb) return 'Pick the two databases.';
    if (p.dba === p.dbb) return 'A and B are the same database: pick two.';
  }
  return '';
}

const statusWords: Record<string, string> = { same: 'same', different: 'different', 'only a': 'only in A', 'only b': 'only in B' };
const statusCell = (v: unknown) => v === 'same' ? 'same' : badge(statusWords[String(v)] ?? String(v ?? ''), 'warn');
// the counts of a section in words: the differences by status, and the identical rows when they were asked for
const countsText = (t: Table | null | undefined): string => {
  const rows = rowsOf(t), n = (s: string) => rows.filter(r => r.status === s).reduce((a, r) => a + Number(r.n ?? 0), 0);
  const diff = n('different') + n('only a') + n('only b');
  return `${fmtNum(diff)} difference(s)`
    + (diff ? ` (${fmtNum(n('different'))} different, ${fmtNum(n('only a'))} only in A, ${fmtNum(n('only b'))} only in B)` : '')
    + (n('same') ? `; ${fmtNum(n('same'))} the same` : '');
};
// a long text behind a one-line summary (a definition, a command)
function longText(v: unknown): string | Node {
  if (v == null || v === '') return '';
  const s = String(v), line = s.replace(/\s+/g, ' ').trim();
  if (line.length <= 90 && !s.includes('\n')) return el('code', {}, s);
  return el('details', { class: 'cut' }, el('summary', {}, line.slice(0, 90) + '...'), el('pre', { class: 'sql' }, s));
}

function sidesBlock(sides: Row[], mode: string): HTMLElement {
  const t = (v: unknown) => v == null ? 'none' : fmtTime(v);
  const cols: Col[] = [
    { key: 'side', label: 'side', fmt: v => String(v ?? '').toUpperCase() },
    { key: 'instance' },
    { key: 'engine', fmt: v => v === 'sqlserver' ? 'SQL Server' : 'PostgreSQL' },
    { key: 'at', label: 'as of', fmt: v => v == null ? 'the newest read' : fmtTime(v) },
    { key: 'settings_read', label: 'settings read', fmt: (v, r) => t(v) + (r.settings_from ? ` (history from ${fmtTime(r.settings_from)})` : r.engine === 'sqlserver' ? ' (one earlier value per setting)' : '') },
    { key: 'jobs_read', label: 'newest job version', fmt: (v, r) => t(v) + (r.jobs_from ? ` (versions from ${fmtTime(r.jobs_from)})` : '') },
    { key: 'schema_read', label: 'schema read', fmt: (v, r) => r.engine === 'sqlserver' ? 'not collected' : t(v)
      + (v != null ? ` (${fmtNum(r.schema_databases)} database(s), first read ${fmtTime(r.schema_from)}` + (mode === 'snapshots' ? `, changes held from ${r.schema_changes_from ? fmtTime(r.schema_changes_from) : 'none yet'}` : '') + ')' : '') },
  ];
  return grid(sides, cols, 'No such instance.');
}

function settingsBlock(d: Record<string, Table | null>, engine: string, note: string): HTMLElement {
  const missing = engine === 'sqlserver' ? '(not listed)' : '(default)';
  const cols: Col[] = [
    { key: 'name', label: 'setting' },
    { key: 'a_value', label: 'A', wide: true, fmt: v => v == null ? missing : String(v) },
    { key: 'b_value', label: 'B', wide: true, fmt: v => v == null ? missing : String(v) },
    { key: 'status', fmt: statusCell },
  ];
  return el('div', {}, el('h3', {}, 'Settings'),
    el('p', { class: 'meta' }, `${countsText(d.settings_counts)}. Compared: ${note}.`),
    grid(rowsOf(d.settings), cols, 'No setting differs.'));
}

function jobsBlock(d: Record<string, Table | null>, note: string): HTMLElement {
  const fields = (v: unknown): string | Node => {
    const list = (Array.isArray(v) ? v : typeof v === 'string' ? JSON.parse(v) : []) as { field: string; a: unknown; b: unknown }[];
    if (!list.length) return '';
    const t = el('table', { class: 'props' });
    t.append(el('tr', {}, el('th', { scope: 'col' }, 'field'), el('th', { scope: 'col' }, 'A'), el('th', { scope: 'col' }, 'B')));
    for (const f of list) t.append(el('tr', {}, el('th', { scope: 'row' }, f.field), el('td', {}, f.a == null ? '(none)' : longText(f.a)), el('td', {}, f.b == null ? '(none)' : longText(f.b))));
    return t;
  };
  const cols: Col[] = [
    { key: 'scheduler' },
    { key: 'job_name', label: 'job', fmt: (v, r) => String(v ?? r.a_job_id ?? r.b_job_id ?? '') },
    { key: 'status', fmt: statusCell },
    { key: 'fields', label: 'what differs', fmt: fields },
    { key: 'a_valid_from', label: 'A: version from', fmt: fmtTime },
    { key: 'b_valid_from', label: 'B: version from', fmt: fmtTime },
  ];
  return el('div', {}, el('h3', {}, 'Jobs'),
    el('p', { class: 'meta' }, `${countsText(d.jobs_counts)}. Compared: ${note}.`),
    grid(rowsOf(d.jobs), cols, 'No job differs.'));
}

function schemaBlock(d: Record<string, Table | null>, cap: number, note: string): HTMLElement {
  const rows = rowsOf(d.schema);
  const total = rowsOf(d.schema_counts).reduce((a, r) => a + Number(r.n ?? 0), 0);
  // one side of an object: what differs there, or the whole definition of an object only that side has
  const side = (s: 'a' | 'b') => (_v: unknown, r: Row): string | Node => {
    if (r.kind === 'database' || r.status === 'same') return '';
    const box = el('div');
    const differs = String(r.differs ?? '').split(', ').filter(Boolean);
    const whole = r.status !== 'different';
    if (whole || differs.includes('definition')) box.append(longText(r[s + '_definition']) || '(none)');
    if (!whole && differs.includes('owner')) box.append(el('div', {}, `owner: ${String(r[s + '_owner'] ?? '(none)')}`));
    if (!whole && differs.includes('acl')) box.append(el('div', {}, `acl: ${String(r[s + '_acl'] ?? '(none)')}`));
    return box;
  };
  const cols: Col[] = [
    { key: 'datname_a', label: 'database', fmt: (v, r) => v != null && r.datname_b != null && v !== r.datname_b ? `${String(v)} / ${String(r.datname_b)}` : String(v ?? r.datname_b ?? '') },
    { key: 'kind' },
    { key: 'identity', label: 'object' },
    { key: 'status', fmt: statusCell },
    { key: 'differs', label: 'what differs', fmt: (v, r) => r.status === 'different' ? String(v ?? '')
      : Number(r.children) > 0 ? (r.kind === 'database' ? `the database (${fmtNum(r.children)} objects)` : `with its ${fmtNum(r.children)} columns, indexes, constraints and triggers`)
        : r.kind === 'database' ? 'the database' : '' },
    { key: 'a_definition', label: 'A', fmt: side('a') },
    { key: 'b_definition', label: 'B', fmt: side('b') },
  ];
  return el('div', {}, el('h3', {}, 'Schema objects'),
    el('p', { class: 'meta' }, `${countsText(d.schema_counts)}. Compared: ${note}.`
      + (total > rows.length ? ` The first ${fmtNum(rows.length)} of ${fmtNum(total)} rows (the cap is ${fmtNum(cap)}): pick one database to narrow it.` : '')),
    grid(rows, cols, 'No schema object differs.'));
}

export async function diffView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Diff'));
  const p = loadPicks(ctx);
  const insts = (await fleet()).instances.map(r => ({ id: Number(r.instance_id), name: String(r.name ?? ''), engine: String(r.engine ?? 'postgres') }))
    .sort((x, y) => x.name.localeCompare(y.name));
  const engineOf = (id?: number) => insts.find(i => i.id === id)?.engine;

  // ---- the form: nothing is read until Compare
  const modeBox = el('fieldset', { class: 'filters' }, el('legend', {}, 'Compare'),
    ...modes.map(([k, label]) => {
      const rb = el('input', { type: 'radio', name: 'diff-mode', id: 'diff-mode-' + k, value: k });
      rb.checked = p.m === k;
      rb.addEventListener('change', () => { if (rb.checked) { p.m = k; sync(); } });
      return el('label', { for: 'diff-mode-' + k, style: 'margin-right: 1.2rem; white-space: nowrap' }, rb, ' ' + label);
    }));
  const instSel = (id: string, pick: (v?: number) => void, cur: () => number | undefined, only?: () => string | undefined) => {
    const s = el('select', { id });
    const fill = () => {
      const eng = only?.();
      s.replaceChildren(el('option', { value: '' }, '(pick an instance)'),
        ...insts.filter(i => !eng || i.engine === eng).map(i => el('option', { value: String(i.id) }, i.name + (i.engine === 'sqlserver' ? ' (SQL Server)' : ''))));
      s.value = cur() && [...s.options].some(o => o.value === String(cur())) ? String(cur()) : '';
      if (s.value === '' && cur()) pick(undefined);
    };
    s.addEventListener('change', () => { pick(Number(s.value) || undefined); sync(); });
    return { s, fill };
  };
  const selA = instSel('diff-a', v => { p.a = v; p.dba = undefined; if (p.m !== 'i') p.dbb = undefined; }, () => p.a);
  const selB = instSel('diff-b', v => { p.b = v; p.dbb = undefined; }, () => p.b, () => engineOf(p.a));
  const dbSel = (id: string, pick: (v?: string) => void) => {
    const s = el('select', { id });
    s.addEventListener('change', () => { pick(s.value || undefined); sync(false); });
    return s;
  };
  const dbA = dbSel('diff-dba', v => { p.dba = v; }), dbB = dbSel('diff-dbb', v => { p.dbb = v; });
  const timeIn = (id: string, pick: (v?: string) => void) => {
    const i = el('input', { type: 'datetime-local', id });
    i.addEventListener('change', () => { pick(i.value ? new Date(i.value).toISOString() : undefined); sync(false); });
    return i;
  };
  const tA = timeIn('diff-ta', v => { p.ta = v; }), tB = timeIn('diff-tb', v => { p.tb = v; });
  tA.value = toLocalInput(p.ta); tB.value = toLocalInput(p.tb);
  const allBox = el('input', { type: 'checkbox', id: 'diff-all' });
  allBox.checked = p.all;
  allBox.addEventListener('change', () => { p.all = allBox.checked; sync(false); });
  const go = el('button', { type: 'button' }, 'Compare');
  const hint = el('span', { class: 'meta', role: 'status' });
  const field = (forId: string, label: string, control: HTMLElement) => el('label', { for: forId, style: 'white-space: nowrap' }, label + ' ', control);
  const fA = field('diff-a', 'A', selA.s), fB = field('diff-b', 'B', selB.s);
  const fDbA = field('diff-dba', 'Database of A', dbA), fDbB = field('diff-dbb', 'Database of B', dbB);
  const fTA = field('diff-ta', 'A: as of', tA), fTB = field('diff-tb', 'B: as of (empty: the newest read)', tB);
  const form = el('div', { class: 'toolbar' }, fA, fB, fDbA, fDbB, fTA, fTB, field('diff-all', 'Show identical rows', allBox), go, hint);

  // the databases behind the two pickers: each side's databases with a schema snapshot
  let dbSeq = 0;
  async function fillDatabases() {
    const mine = ++dbSeq, a = p.a, b = p.m === 'i' ? p.b : p.a;
    const set = (s: HTMLSelectElement, names: string[], cur: string | undefined, none: string) => {
      s.replaceChildren(el('option', { value: '' }, none), ...names.map(n => el('option', { value: n }, n)));
      s.value = cur && names.includes(cur) ? cur : '';
    };
    let rows: Row[] = [];
    if (a && b && engineOf(a) !== 'sqlserver') {
      try { rows = rowsOf((await get<{ databases: Table | null }>('diff', { a, b, part: 'databases' })).databases); } catch { rows = []; }
    }
    if (mine !== dbSeq) return;
    const namesOf = (id?: number) => rows.filter(r => Number(r.instance_id) === id).map(r => String(r.datname));
    const none = p.m === 'i' ? '(all, paired by name)' : p.m === 't' ? '(all databases)' : '(pick a database)';
    set(dbA, namesOf(a), p.dba, none); set(dbB, namesOf(b), p.dbb, none);
    if (dbA.value === '') p.dba = undefined;
    if (dbB.value === '') p.dbb = undefined;
    hint.textContent = incomplete(p);
  }
  // sync: the form shows the fields its mode uses; the picks are remembered
  function sync(refill = true) {
    selA.fill(); selB.fill();
    fB.hidden = p.m !== 'i';
    fDbB.hidden = p.m === 't';
    fTA.hidden = fTB.hidden = p.m !== 't';
    const sql = engineOf(p.a) === 'sqlserver';
    fDbA.hidden = sql && p.m !== 'd'; if (sql && p.m !== 'd') fDbB.hidden = true;
    hint.textContent = incomplete(p);
    try { localStorage.setItem(lsKey, JSON.stringify({ m: p.m, a: String(p.a ?? ''), b: String(p.b ?? ''), dba: p.dba ?? '', dbb: p.dbb ?? '', all: p.all ? '1' : '' })); } catch { /* private window */ }
    if (refill) void fillDatabases();
  }
  go.addEventListener('click', () => {
    const why = incomplete(p);
    if (why) { hint.textContent = why; return; }
    focusResult = true;
    const to = diffHref(ctx, p);
    // the same picks again: the hash does not change, so the page is asked to draw itself
    if (to === location.hash) window.dispatchEvent(new HashChangeEvent('hashchange')); else location.hash = to;
  });
  sec.append(modeBox, form,
    el('p', { class: 'meta' }, 'Two instances are compared as each was last read; one instance at two times from its change histories; '
      + 'two databases of one instance by their schema objects. Differences only, unless identical rows are asked for.'));
  sync(false);
  await fillDatabases();

  // ---- the result of the picks in the hash
  const result = el('div', { tabindex: '-1', role: 'region', 'aria-label': 'Diff result' });
  sec.append(result);
  const asked = keys.some(k => hashParam(k) !== undefined);
  if (!asked || incomplete(p)) {
    result.append(el('p', { class: 'empty' }, asked ? incomplete(p) : 'Pick the two sides and press Compare.'));
    return sec;
  }
  try {
    const d = await get<Record<string, Table | null>>('diff', {
      a: p.a, b: p.m === 'i' ? p.b : p.a,
      at_a: p.m === 't' ? p.ta : undefined, at_b: p.m === 't' ? p.tb : undefined,
      db_a: p.dba, db_b: p.m === 't' ? undefined : p.dbb, all: p.all ? 1 : undefined,
    });
    const meta = rowsOf(d.meta)[0] ?? {}, cov = rowsOf(d.coverage);
    const note = (s: string) => String(cov.find(r => r.section === s)?.note ?? '');
    const compared = (s: string) => cov.find(r => r.section === s)?.compared === true;
    result.append(el('h3', {}, 'The two sides'), sidesBlock(rowsOf(d.sides), String(meta.mode ?? '')));
    const skipped = cov.filter(r => r.compared !== true);
    if (skipped.length) result.append(el('p', { class: 'meta' }, 'Not compared: ',
      ...skipped.map((r, i) => el('span', {}, (i ? '; ' : '') + `${String(r.section)} (${String(r.note)})`)), '.'));
    if (compared('settings')) result.append(settingsBlock(d, String(meta.engine ?? 'postgres'), note('settings')));
    if (compared('jobs')) result.append(jobsBlock(d, note('jobs')));
    if (compared('schema')) result.append(schemaBlock(d, Number(meta.schema_cap ?? 1000), note('schema')));
  } catch (e) {
    result.append(errorBox(e));
  }
  if (focusResult) { focusResult = false; requestAnimationFrame(() => { if (result.isConnected) result.focus(); }); }
  return sec;
}
