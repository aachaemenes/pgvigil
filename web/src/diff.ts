// The Diff page (task 132; DBA Dash's Diff menu: Database Schema Diff and Agent Job Diff). Two sides, A and B, side by
// side for settings, jobs and schema objects, the differences only unless 'show identical rows' is ticked:
//   two instances            as each was last read (one engine on both sides)
//   one instance, two times  from the change histories the repository keeps (settings, job versions, schema changes)
//   two databases            of one instance: their schema objects as last read
// Settings and jobs compare on both engines; schema objects on PostgreSQL only (the repository holds none of a SQL
// Server instance), and the page says which sections it compared and how far back each store reaches. The picks ride
// in the hash (m, a, b, dba, dbb, ta, tb, all), so a diff is a link, and the last ones are kept in this browser.
// Data: /api/diff (part=databases: the databases behind the two pickers).
// The file also holds the text diff (lineDiff, textDiffView: code view, side by side, inline) and the structured compare of
// two job definitions (definitionView, definitionCompare) that the Jobs and Configuration pages draw (task 154): its second half.
import { get, Row, rowsOf, Table } from './api';
import type { Ctx } from './router';
import { href, window_ } from './router';
import { fleet } from './fleet';
import { hashParam } from './dbinfo';
import { badge, Col, copyText, el, errorBox, fmtNum, fmtTime, grid } from './ui';

type Mode = 'i' | 't' | 'd';
interface Picks { m: Mode; a?: number; b?: number; dba?: string; dbb?: string; ta?: string; tb?: string; all: boolean }
const keys = ['m', 'a', 'b', 'dba', 'dbb', 'ta', 'tb', 'all'];
const modes: [Mode, string][] = [['i', 'Two instances'], ['t', 'One instance at two times'], ['d', 'Two databases of one instance (PostgreSQL)']];
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

// incomplete: why the picks are not enough for a diff ('' = they are); engine = instance A's
function incomplete(p: Picks, engine?: string): string {
  if (!p.a) return p.m === 'i' ? 'Pick instance A.' : 'Pick the instance.';
  if (p.m === 'd' && engine === 'sqlserver') return 'Two databases are compared by their schema objects, which the repository holds for PostgreSQL only: pick a PostgreSQL instance.';
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
  // a store's newest read, and under it how far back it reaches
  const two = (top: string, under: string): string | Node => under ? el('span', {}, top, el('br'), el('span', { class: 'meta' }, under)) : top;
  const cols: Col[] = [
    { key: 'side', label: 'side', fmt: v => String(v ?? '').toUpperCase() },
    { key: 'instance' },
    { key: 'engine', fmt: v => v === 'sqlserver' ? 'SQL Server' : 'PostgreSQL' },
    { key: 'at', label: 'as of', fmt: v => v == null ? 'the newest read' : fmtTime(v) },
    { key: 'settings_read', label: 'settings read', fmt: (v, r) => two(t(v), v == null ? '' : r.settings_from ? `history from ${fmtTime(r.settings_from)}` : r.engine === 'sqlserver' ? 'one earlier value per setting' : '') },
    { key: 'jobs_read', label: 'newest job version', fmt: (v, r) => two(t(v), r.jobs_from ? `versions from ${fmtTime(r.jobs_from)}` : '') },
    { key: 'schema_read', label: 'schema read', fmt: (v, r) => r.engine === 'sqlserver' ? 'not collected' : two(t(v),
      v == null ? '' : `${fmtNum(r.schema_databases)} database(s), first read ${fmtTime(r.schema_from)}`
        + (mode === 'snapshots' ? `; changes held from ${r.schema_changes_from ? fmtTime(r.schema_changes_from) : 'none yet'}` : '')) },
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

// narrow: the picks leave a database to pick (the cap's sentence then says so)
function schemaBlock(d: Record<string, Table | null>, cap: number, note: string, narrow: boolean): HTMLElement {
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
      // a database on one side only: why (one instance at two times), and its object count
      : r.kind === 'database' ? `the database${Number(r.children) > 0 ? ` (${fmtNum(r.children)} objects)` : ''}${v ? ': ' + String(v) : ''}`
        : Number(r.children) > 0 ? `with its ${fmtNum(r.children)} dependent object(s) (columns, indexes, constraints, triggers, owned sequences)` : '' },
    { key: 'a_definition', label: 'A', fmt: side('a') },
    { key: 'b_definition', label: 'B', fmt: side('b') },
  ];
  return el('div', {}, el('h3', {}, 'Schema objects'),
    el('p', { class: 'meta' }, `${countsText(d.schema_counts)}. Compared: ${note}.`
      + (total > rows.length ? ` The first ${fmtNum(rows.length)} of ${fmtNum(total)} rows (the cap is ${fmtNum(cap)})`
        + (narrow ? ': pick a database on each side to narrow it.' : '; the counts cover every row.') : '')),
    grid(rows, cols, 'No schema object differs.'));
}

export async function diffView(ctx: Ctx): Promise<HTMLElement> {
  const sec = el('section', {}, el('h2', {}, 'Diff'));
  // the Compare button's wish holds for this render alone, however it ends
  const wantFocus = focusResult; focusResult = false;
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
  const field = (forId: string, label: string, control: HTMLElement) => el('label', { for: forId, style: 'white-space: nowrap' }, el('span', {}, label + ' '), control);
  const fA = field('diff-a', 'A', selA.s), fB = field('diff-b', 'B', selB.s);
  const fDbA = field('diff-dba', 'Database of A', dbA), fDbB = field('diff-dbb', 'Database of B', dbB);
  const fTA = field('diff-ta', 'A: as of', tA), fTB = field('diff-tb', 'B: as of (empty: the newest read)', tB);
  const form = el('div', { class: 'toolbar' }, fA, fB, fDbA, fDbB, fTA, fTB, field('diff-all', 'Show identical rows', allBox), go, hint);

  // the databases behind the two pickers: each side's databases with a schema snapshot
  let dbSeq = 0;
  async function fillDatabases() {
    const mine = ++dbSeq, a = p.a, b = p.m === 'i' ? p.b : p.a;
    // a pick the list does not hold (a database no longer read, a list that could not be read) stays a pick and is
    // marked: it is never dropped for a wider comparison than the one asked for
    const set = (s: HTMLSelectElement, names: string[], cur: string | undefined, none: string) => {
      s.replaceChildren(el('option', { value: '' }, none), ...names.map(n => el('option', { value: n }, n)),
        ...(cur && !names.includes(cur) ? [el('option', { value: cur }, `${cur} (no schema snapshot now)`)] : []));
      s.value = cur ?? '';
    };
    let rows: Row[] = [], failed = '';
    if (a && b && engineOf(a) !== 'sqlserver') {
      try { rows = rowsOf((await get<{ databases: Table | null }>('diff', { a, b, part: 'databases' })).databases); }
      catch (e) { failed = `The databases could not be listed (${e instanceof Error ? e.message : String(e)}). `; }
    }
    if (mine !== dbSeq) return;
    const namesOf = (id?: number) => rows.filter(r => Number(r.instance_id) === id).map(r => String(r.datname));
    const none = p.m === 'i' ? '(all, paired by name)' : p.m === 't' ? '(all databases)' : '(pick a database)';
    set(dbA, namesOf(a), p.dba, none); set(dbB, namesOf(b), p.dbb, none);
    hint.textContent = failed + incomplete(p, engineOf(p.a));
  }
  // sync: the form shows the fields its mode uses; the picks are remembered
  function sync(refill = true) {
    selA.fill(); selB.fill();
    (fA.firstChild as HTMLElement).textContent = p.m === 'i' ? 'A ' : 'Instance ';
    (fDbA.firstChild as HTMLElement).textContent = p.m === 't' ? 'Database ' : 'Database of A ';
    fB.hidden = p.m !== 'i';
    fDbB.hidden = p.m === 't';
    fTA.hidden = fTB.hidden = p.m !== 't';
    const sql = engineOf(p.a) === 'sqlserver';
    fDbA.hidden = sql && p.m !== 'd'; if (sql && p.m !== 'd') fDbB.hidden = true;
    hint.textContent = incomplete(p, engineOf(p.a));
    try { localStorage.setItem(lsKey, JSON.stringify({ m: p.m, a: String(p.a ?? ''), b: String(p.b ?? ''), dba: p.dba ?? '', dbb: p.dbb ?? '', all: p.all ? '1' : '' })); } catch { /* private window */ }
    if (refill) void fillDatabases();
  }
  go.addEventListener('click', () => {
    const why = incomplete(p, engineOf(p.a));
    if (why) { hint.textContent = why; return; }
    focusResult = true;
    const to = diffHref(ctx, p);
    // the same picks again: the hash does not change, so the page is asked to draw itself
    if (to === location.hash) window.dispatchEvent(new HashChangeEvent('hashchange')); else location.hash = to;
  });
  sec.append(modeBox, form,
    el('p', { class: 'meta' }, 'Two instances are compared as each was last read; one instance at two times from its change histories; '
      + 'two databases of one instance by their schema objects. Settings and jobs compare on PostgreSQL and on SQL Server; schema '
      + 'objects on PostgreSQL only (the repository holds none of a SQL Server instance). Differences only, unless identical rows are asked for.'));
  sync(false);
  await fillDatabases();

  // ---- the result of the picks in the hash
  const result = el('div', { tabindex: '-1', role: 'region', 'aria-label': 'Diff result' });
  sec.append(result);
  const asked = keys.some(k => hashParam(k) !== undefined);
  const why = incomplete(p, engineOf(p.a));
  if (!asked || why) {
    result.append(el('p', { class: 'empty' }, asked ? why : 'Pick the two sides and press Compare.'));
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
    if (compared('schema')) result.append(schemaBlock(d, Number(meta.schema_cap ?? 1000), note('schema'), p.m !== 'd' && !p.dba));
  } catch (e) {
    result.append(errorBox(e));
  }
  if (wantFocus) requestAnimationFrame(() => { if (result.isConnected) result.focus(); });
  return sec;
}

// ---- The text diff and the structured compare (task 154; DBA Dash's Job DDL History: Code View, Side by Side Diff,
// Inline Diff, Copy Left / Right, and its 'Compare Info' window). Two texts are compared line by line (the longest
// common run of lines stays, the rest is removed on the left and added on the right); inside a changed pair of
// lines the words that differ are boxed. A removed line carries '-' and an added one '+', so the change never rides
// on colour alone. The views' styles travel with this file (one <style> element, the page's own colour variables).
// Used by the Jobs pages (mssql_jobs.ts: a job's versions) and the configuration pages.

export interface DiffLine { op: ' ' | '-' | '+'; a?: number; b?: number; text: string; other?: string }

// lcs: for two lists, which items of a stay (keepA[i] = the index in b it pairs with, -1 = removed). Past
// LCS_CELLS cells the common head and tail alone are kept (a job script is hundreds of lines, never that large).
const LCS_CELLS = 4_000_000;
function lcs<T>(a: T[], b: T[]): Int32Array {
  const keep = new Int32Array(a.length).fill(-1);
  let head = 0;
  while (head < a.length && head < b.length && a[head] === b[head]) { keep[head] = head; head++; }
  let ta = a.length - 1, tb = b.length - 1;
  while (ta >= head && tb >= head && a[ta] === b[tb]) { keep[ta] = tb; ta--; tb--; }
  const n = ta - head + 1, m = tb - head + 1;
  if (n <= 0 || m <= 0 || n * m > LCS_CELLS) return keep;
  // len[i][j] = the longest common run of a[head+i..] and b[head+j..]
  const w = m + 1, len = new Uint32Array((n + 1) * w);
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--) {
    len[i * w + j] = a[head + i] === b[head + j] ? len[(i + 1) * w + j + 1] + 1 : Math.max(len[(i + 1) * w + j], len[i * w + j + 1]);
  }
  for (let i = 0, j = 0; i < n && j < m;) {
    if (a[head + i] === b[head + j]) { keep[head + i] = head + j; i++; j++; }
    else if (len[(i + 1) * w + j] >= len[i * w + j + 1]) i++; else j++;
  }
  return keep;
}

const linesOf = (s: string): string[] => s === '' ? [] : s.replace(/\r\n?/g, '\n').replace(/\n$/, '').split('\n');

// lineDiff: the lines of a and b in the order a reader meets them; within a change the removed lines come before
// the added ones, and the i-th removed line names the i-th added one as its 'other' (the pair whose words are compared)
export function lineDiff(a: string, b: string): DiffLine[] {
  const la = linesOf(a), lb = linesOf(b), keep = lcs(la, lb), out: DiffLine[] = [];
  let j = 0;
  const flush = (dels: DiffLine[], adds: DiffLine[]) => {
    dels.forEach((d, k) => { if (adds[k]) { d.other = adds[k].text; adds[k].other = d.text; } });
    out.push(...dels, ...adds);
  };
  let dels: DiffLine[] = [], adds: DiffLine[] = [];
  for (let i = 0; i <= la.length; i++) {
    const to = i < la.length ? keep[i] : lb.length;
    if (to < 0) { dels.push({ op: '-', a: i + 1, text: la[i] }); continue; }
    for (; j < to; j++) adds.push({ op: '+', b: j + 1, text: lb[j] });
    flush(dels, adds); dels = []; adds = [];
    if (i < la.length) { out.push({ op: ' ', a: i + 1, b: j + 1, text: la[i] }); j++; }
  }
  return out;
}

// words: a line as its words, the spaces between them and its signs, each a token
const words = (s: string): string[] => s.match(/\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]/gu) ?? [];

// marked: one side of a changed pair of lines, its tokens that the other side lacks boxed (<del> on the removed
// side, <ins> on the added one). A line of over 2,000 tokens is shown plain.
function marked(text: string, other: string | undefined, side: '-' | '+'): (string | Node)[] {
  if (other === undefined) return [text];
  const mine = words(text), theirs = words(other);
  if (mine.length > 2000 || theirs.length > 2000) return [text];
  const keep = side === '-' ? lcs(mine, theirs) : (() => { const k = lcs(theirs, mine), back = new Int32Array(mine.length).fill(-1); k.forEach((v, i) => { if (v >= 0) back[v] = i; }); return back; })();
  const out: (string | Node)[] = [];
  let run = '', runChanged = false;
  const push = () => { if (run !== '') out.push(runChanged ? el(side === '-' ? 'del' : 'ins', { class: 'w' }, run) : run); run = ''; };
  mine.forEach((t, i) => {
    const changed = keep[i] < 0;
    if (changed !== runChanged) { push(); runChanged = changed; }
    run += t;
  });
  push();
  return out;
}

const DIFF_CSS = `
.tdiff { border: 1px solid var(--line); overflow: auto; max-height: 36rem; background: var(--card); }
.tdiff table { border-collapse: collapse; width: 100%; font-family: ui-monospace, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace; font-size: 12px; }
.tdiff td { padding: 0 .4rem; vertical-align: top; white-space: pre-wrap; word-break: break-word; }
.tdiff td.ln { width: 1%; text-align: right; color: var(--muted); white-space: nowrap; user-select: none; border-right: 1px solid var(--line); }
.tdiff td.mk { width: 1%; white-space: nowrap; user-select: none; font-weight: 600; }
.tdiff td.del { background: var(--crit-bg); } .tdiff td.add { background: var(--ok-bg); }
.tdiff td.del.mk { color: var(--crit); } .tdiff td.add.mk { color: var(--ok); }
.tdiff td.gap { background: var(--bg); }
.tdiff .w { text-decoration: none; outline: 1px solid currentColor; outline-offset: -1px; border-radius: 2px; }
.tdiff del.w { color: var(--crit); } .tdiff ins.w { color: var(--ok); }
.tdiff.side td.tx { width: 49%; }
.defcmp { display: flex; gap: 1rem; flex-wrap: wrap; align-items: flex-start; }
.defcmp > div { flex: 1 1 26rem; min-width: 0; }
.defview table { border-collapse: collapse; width: 100%; margin-bottom: .6rem; }
.defview th, .defview td { text-align: left; vertical-align: top; padding: .2rem .5rem; border-bottom: 1px solid var(--line); }
.defview td.chg { background: var(--crit-bg); }
.defview td.chg::after { content: " *"; color: var(--crit); font-weight: 600; }
.defview pre.sql { margin: 0; }
.seg label { margin-right: 1rem; white-space: nowrap; }
`;
function diffStyles() {
  if (document.getElementById('pgvigil-tdiff-css')) return;
  const st = el('style', { id: 'pgvigil-tdiff-css' }, DIFF_CSS);
  document.head.append(st);
}

export type DiffMode = 'code' | 'side' | 'inline';
const modeKey = 'pgvigil.diffview';
const modeLabels: [DiffMode, string][] = [['code', 'Code view'], ['side', 'Side by side diff'], ['inline', 'Inline diff']];
let diffSeq = 0;

// diffCounts: the lines a diff adds and removes
export function diffCounts(d: DiffLine[]): { added: number; removed: number } {
  return { added: d.filter(x => x.op === '+').length, removed: d.filter(x => x.op === '-').length };
}

function codeTable(text: string): HTMLElement {
  const t = el('table', { 'aria-label': 'the script' });
  linesOf(text).forEach((l, i) => t.append(el('tr', {}, el('td', { class: 'ln' }, String(i + 1)), el('td', { class: 'tx' }, l))));
  return el('div', { class: 'tdiff code', tabindex: '0' }, t);
}

function inlineTable(d: DiffLine[], left: string, right: string): HTMLElement {
  const t = el('table', { 'aria-label': `inline diff: lines of ${left} marked -, lines of ${right} marked +` });
  for (const x of d) {
    const k = x.op === '-' ? 'del' : x.op === '+' ? 'add' : '';
    const tx = el('td', { class: `tx ${k}`.trim() });
    tx.append(...(x.op === ' ' ? [x.text] : marked(x.text, x.other, x.op)));
    t.append(el('tr', { 'data-op': x.op }, el('td', { class: 'ln' }, x.a ? String(x.a) : ''), el('td', { class: 'ln' }, x.b ? String(x.b) : ''),
      el('td', { class: `mk ${k}`.trim() }, x.op === ' ' ? '' : x.op), tx));
  }
  return el('div', { class: 'tdiff inline', tabindex: '0' }, t);
}

function sideTable(d: DiffLine[], left: string, right: string): HTMLElement {
  const t = el('table', { 'aria-label': `side by side diff: ${left} on the left, ${right} on the right` });
  t.append(el('tr', {}, el('th', { colspan: '3', scope: 'col', style: 'text-align:left;padding:.2rem .4rem' }, left),
    el('th', { colspan: '3', scope: 'col', style: 'text-align:left;padding:.2rem .4rem' }, right)));
  const cell = (x: DiffLine | undefined, side: '-' | '+'): HTMLElement[] => {
    if (!x) return [el('td', { class: 'ln gap' }), el('td', { class: 'mk gap' }), el('td', { class: 'tx gap' })];
    const k = x.op === '-' ? 'del' : x.op === '+' ? 'add' : '';
    const tx = el('td', { class: `tx ${k}`.trim() });
    tx.append(...(x.op === ' ' ? [x.text] : marked(x.text, x.other, side)));
    return [el('td', { class: 'ln' }, String(side === '-' ? x.a ?? '' : x.b ?? '')), el('td', { class: `mk ${k}`.trim() }, x.op === ' ' ? '' : x.op), tx];
  };
  for (let i = 0; i < d.length;) {
    if (d[i].op === ' ') { t.append(el('tr', { 'data-op': ' ' }, ...cell(d[i], '-'), ...cell(d[i], '+'))); i++; continue; }
    const dels: DiffLine[] = [], adds: DiffLine[] = [];
    while (i < d.length && d[i].op === '-') dels.push(d[i++]);
    while (i < d.length && d[i].op === '+') adds.push(d[i++]);
    for (let k = 0; k < Math.max(dels.length, adds.length); k++) t.append(el('tr', { 'data-op': dels[k] && adds[k] ? '~' : dels[k] ? '-' : '+' }, ...cell(dels[k], '-'), ...cell(adds[k], '+')));
  }
  return el('div', { class: 'tdiff side', tabindex: '0' }, t);
}

// textDiffView: two texts under the three views and the two copies. prev undefined = nothing to compare with (a
// first version): the code view, and an inline diff in which every line is added. The view picked is kept in this
// browser. left / right name the two sides (a version and the one before it).
export function textDiffView(prev: string | undefined, cur: string, left: string, right: string): HTMLElement {
  diffStyles();
  const box = el('div', { class: 'textdiff' });
  const d = lineDiff(prev ?? '', cur), n = diffCounts(d);
  let mode: DiffMode = 'side';
  try { const m = localStorage.getItem(modeKey); if (m === 'code' || m === 'side' || m === 'inline') mode = m; } catch { /* private window */ }
  if (prev === undefined && mode === 'side') mode = 'code';
  const body = el('div');
  const draw = () => body.replaceChildren(mode === 'code' ? codeTable(cur) : mode === 'inline' ? inlineTable(d, left, right) : sideTable(d, left, right));
  const name = `tdiff-mode-${++diffSeq}`;
  const seg = el('fieldset', { class: 'filters seg' }, el('legend', {}, 'View'), ...modeLabels.map(([k, label]) => {
    const id = `${name}-${k}`, rb = el('input', { type: 'radio', name, id, value: k });
    rb.checked = mode === k;
    if (k === 'side' && prev === undefined) { rb.disabled = true; rb.title = 'the first version has nothing before it'; }
    rb.addEventListener('change', () => { if (!rb.checked) return; mode = k; try { localStorage.setItem(modeKey, k); } catch { /* private window */ } draw(); });
    return el('label', { for: id }, rb, ' ' + label);
  }));
  const said = el('span', { class: 'meta', role: 'status' });
  const copy = (label: string, text: string | undefined) => {
    const b = el('button', { type: 'button' }, label);
    if (text === undefined) { b.disabled = true; b.title = 'the first version has nothing before it'; }
    else b.addEventListener('click', () => { void copyText(text).then(ok => { said.textContent = ok ? `${label}: copied.` : `${label}: the browser refused the copy.`; }); });
    return b;
  };
  box.append(el('div', { class: 'toolbar' }, seg, copy('Copy left', prev), copy('Copy right', cur),
    el('span', { class: 'meta' }, prev === undefined ? `${fmtNum(n.added)} line(s)` : n.added + n.removed === 0 ? 'the two scripts are the same'
      : `${fmtNum(n.added)} line(s) added, ${fmtNum(n.removed)} removed`), said), body);
  draw();
  return box;
}

// ---- a job's definition as its page, and two definitions side by side (DBA Dash's job Info window and Compare Info)

type Def = Record<string, unknown>;
const isObj = (v: unknown): v is Def => typeof v === 'object' && v !== null && !Array.isArray(v);
const asDef = (v: unknown): Def => { if (typeof v === 'string') { try { v = JSON.parse(v); } catch { return {}; } } return isObj(v) ? v : {}; };
// a key holds a table when every value under it is an object (steps, schedules)
const isTable = (v: unknown) => isObj(v) && Object.keys(v).length > 0 && Object.values(v).every(isObj);
const show = (v: unknown): string => v == null ? '' : typeof v === 'boolean' ? (v ? 'yes' : 'no') : String(v);
const valueNode = (v: unknown): string | Node => { const s = show(v); return s.includes('\n') || s.length > 80 ? el('pre', { class: 'sql' }, s) : s; };
// info: the scalar fields of a definition, a nested object of scalars under 'key / field'
function info(d: Def): [string, unknown][] {
  const out: [string, unknown][] = [];
  for (const [k, v] of Object.entries(d)) {
    if (isTable(v)) continue;
    if (isObj(v)) for (const [k2, v2] of Object.entries(v)) out.push([`${k} / ${k2}`, v2]); else out.push([k, v]);
  }
  return out;
}

// definitionView: one definition as the job's page: its fields, then a table per part (steps, schedules). With
// other (the definition it is compared with) every cell whose value differs from the other side's, and every cell
// of a row the other side lacks, is marked: tinted, with a '*'.
export function definitionView(def: unknown, other?: unknown): HTMLElement {
  diffStyles();
  const d = asDef(def), o = other === undefined ? undefined : asDef(other);
  const box = el('div', { class: 'defview' });
  const oInfo = new Map(o ? info(o) : []);
  const mark = (changed: boolean): Record<string, string> => changed ? { class: 'chg', title: 'differs from the other side' } : {};
  const it = el('table', { 'aria-label': 'the job' });
  for (const [k, v] of info(d)) it.append(el('tr', {}, el('th', { scope: 'row' }, k), el('td', mark(!!o && show(oInfo.get(k)) !== show(v)), valueNode(v))));
  // a field only the other side has: an empty, marked row here, so the two panes line up
  if (o) for (const [k] of oInfo) if (!info(d).some(([x]) => x === k)) it.append(el('tr', {}, el('th', { scope: 'row' }, k), el('td', mark(true), '')));
  box.append(el('h4', {}, 'Info'), el('div', { class: 'grid-wrap', tabindex: '0' }, it));
  const parts = new Set([...Object.keys(d).filter(k => isTable(d[k])), ...(o ? Object.keys(o).filter(k => isTable(o[k])) : [])]);
  for (const part of parts) {
    const rows = isObj(d[part]) ? d[part] as Record<string, Def> : {}, oRows = o && isObj(o[part]) ? o[part] as Record<string, Def> : {};
    const keys = [...new Set([...Object.keys(rows), ...(o ? Object.keys(oRows) : [])])].sort();
    const fields = [...new Set(keys.flatMap(k => [...Object.keys(rows[k] ?? {}), ...Object.keys(oRows[k] ?? {})]))];
    const t = el('table', { 'aria-label': part });
    t.append(el('tr', {}, el('th', { scope: 'col' }, part.replace(/s$/, '')), ...fields.map(f => el('th', { scope: 'col' }, f))));
    for (const k of keys) {
      const r = rows[k], x = oRows[k];
      if (!r) { t.append(el('tr', {}, el('th', { scope: 'row' }, ''), ...fields.map(() => el('td', mark(true), '')))); continue; }
      t.append(el('tr', {}, el('th', { scope: 'row' }, k), ...fields.map(f => el('td', mark(!!o && (!x || show(x[f]) !== show(r[f]))), valueNode(r[f])))));
    }
    box.append(el('h4', {}, part.charAt(0).toUpperCase() + part.slice(1)), el('div', { class: 'grid-wrap', tabindex: '0' }, t));
  }
  return box;
}

// definitionCompare: two definitions in two panes, the changed cells marked on both sides
export function definitionCompare(prev: unknown, cur: unknown, left: string, right: string): HTMLElement {
  diffStyles();
  return el('div', { class: 'defcmp' },
    el('div', {}, el('h4', {}, left), definitionView(prev, cur)),
    el('div', {}, el('h4', {}, right), definitionView(cur, prev)));
}

// changedText: an old and a new value on one line, the words that differ boxed (a setting's change)
export function changedText(oldV: string, newV: string): HTMLElement {
  diffStyles();
  const s = el('span', { class: 'tdiff', style: 'border:0;background:none;display:inline' });
  s.append(el('span', {}, ...marked(oldV, newV, '-')), ' -> ', el('span', {}, ...marked(newV, oldV, '+')));
  return s;
}
